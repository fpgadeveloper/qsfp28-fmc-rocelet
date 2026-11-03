#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# rocelet_beam_app.py - the beamforming demo of qsfp28-fmc-rocelet: an 8 x 8 phased-array
# receiver whose element samples (Opsero SOURCE = 2, docs/source/beam_contract.md) arrive in GPU
# memory over RoCE (Holoscan Sensor Bridge data plane), beamformed on the GPU (CuPy: covariance,
# Bartlett / MVDR sky maps, steered beam pattern + spectrum, calibration) and shown in a Holoviz
# window that is also the control surface: dragging a source writes the new scene to the FPGA
# (HSB register protocol, Opsero BM registers, APPLY) and the picture follows.
#
#   --source roce        the board (KCU116 + OP120, 'hsb on'): enumeration, configure_roce,
#                        RoceReceiverOp into GPU memory, start gate, keepalive (as rocelet_hsb_app.py)
#   --source synthetic   no board: frames from beam_model.generate_frame() (the bit-exact reference,
#                        numpy, ~10 frames/s) for the scene the app writes into an in-process copy of
#                        the BM registers (beam_regs.SimRegs: same encoding, same APPLY semantics)
#   --source csynthetic  the same generator bit for bit as a CUDA kernel (beam_gpu.GpuGenerator):
#                        ~100+ frames/s, exercises frame dropping at the display rate
#
# Window: fullscreen 1920 x 1080 (--windowed), or --headless with --png-every N. Keys: 1-5 presets,
# B beamformer, C calibrate, N noise, A attract mode, R reset, - / + stream rate (board: RATE_MBPS
# while the stream runs, 1-80 Gb/s), Esc quit; left-drag emitter,
# right-drag jammer, wheel amplitude, middle click locks the beam on a source, click an element
# to fail / restore it. --script replays timed key / mouse events (tests, demos).
#
# Runs in NVIDIA's HSB container (hololink-demo:3.0.0). See README.md in this directory.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import argparse
import collections
import datetime
import json
import logging
import os
import queue
import signal
import struct
import sys
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(1, os.path.join(os.path.dirname(HERE), "hsb"))

import cupy as cp  # noqa: E402
import numpy as np  # noqa: E402
from holoscan.conditions import BooleanCondition, CountCondition, PeriodicCondition  # noqa: E402
from holoscan.core import Application, ConditionType, MetadataPolicy, Operator  # noqa: E402
from holoscan.schedulers import EventBasedScheduler, GreedyScheduler  # noqa: E402

import beam_gpu as bg  # noqa: E402
import beam_regs as br  # noqa: E402
import beam_scene as bs  # noqa: E402
import beam_ui as ui_mod  # noqa: E402
import beam_web  # noqa: E402
import rocelet_hsb_app as rh  # noqa: E402  (Stats, CheckerOp, PngSinkOp, StartGateOp, FastKernel, ...)
from beam_ui import H, W  # noqa: E402

FRAME_SIZE = 1 << 20              # contract 2: T = 4096 time samples x 64 elements x 4 bytes
MD_OFF = rh.round_up(FRAME_SIZE, rh.PAGE_ALIGN)
MARK_OUTLINE = [0.0, 0.0, 0.0, 0.85]   # dark outline under the source markers
START_WINDOW = 2.0                # s after the first frame: losses in it are reported apart (BeamStats.lost_start)
PEAK_TOL = 0.05                   # sky-map peak within this (u, v) distance of a true source = "on source"
WEB_G = 128                       # the web page's sky map: WEB_G x WEB_G uint8


def frame_period_s(gbps):
    """Board frame period at gbps (frame + metadata record on the wire), 0 = unknown / unpaced."""
    return (FRAME_SIZE + rh.METADATA_SIZE) * 8 / (gbps * 1e9) if gbps and gbps > 0 else 0.0


def pct(v, q):
    return round(float(np.percentile(v, q)), 3) if len(v) else None


class BeamStats:
    """Beam-side counters (the frame accounting is rocelet_hsb_app.Stats via its CheckerOp)."""

    def __init__(self):
        self.rx = 0                 # frames reaching the beamformer
        self.processed = 0
        self.gpu_ms = collections.deque(maxlen=2000)
        self.host_ms = collections.deque(maxlen=2000)
        self.d2p_ms = collections.deque(maxlen=2000)       # frame receive -> image submitted (every processed frame)
        self.m2d_ms = collections.deque(maxlen=500)        # mouse-to-data (contract 6.7)
        self.m2a_ms = collections.deque(maxlen=500)        # mouse-to-app: the app first looks at a new-scene frame
        self.skip_frames = collections.deque(maxlen=500)   # frame_index - scene_frame of that frame
        self.recv_age_ms = collections.deque(maxlen=2000)  # receiver completion -> BeamOp (processed frames)
        self.m2p_ms = collections.deque(maxlen=500)        # mouse-to-pixel (mouse-to-app + its frame's data-to-pixel)
        self.apply_ms = collections.deque(maxlen=500)      # input -> APPLY reply
        self.board_frames = collections.deque(maxlen=500)  # scene_frame - newest frame at t_apply
        self.peak_ok = 0
        self.peak_n = 0
        self.tag_bad = 0
        self.unknown_scene = 0
        self.exceptions = []
        self.writes = 0
        self.write_errors = 0
        self.scene_changes = 0
        self.rate_changes = []      # live stream-rate changes: dict(t, gbps, write_ms) (t from the first frame shown)
        self.t_first = None
        self.cal = []
        # --verify: received frames compared word for word with the bit-exact CUDA generator
        self.v_frames = 0           # frames compared
        self.v_bad_frames = 0       # frames with >= 1 mismatching 32-bit sample
        self.v_bad_words = 0        # mismatching samples in total
        self.v_skipped = 0          # due but not compared: page possibly reused (too old), unknown scene, no beam tag
        self.v_overrun = 0          # the record changed while the frame was copied (page reused): not compared
        self.v_fidx_bad = 0         # metadata frame_index low 16 bits != HSB frame_number
        self.v_dumps = []
        # frames lost in the first START_WINDOW s of the stream (the P520's CX-6 drops ~1k packets = 1-4 frames
        # at a 40-64 Gb/s data-plane start into GPU memory: rx_discards_phy, B5); the verdict uses the rest
        self.lost_start = None

    def lost_steady(self, st):
        lost = max(st.lost, 0)
        return lost - (self.lost_start or 0) if self.lost_start is not None else lost


class Latency:
    """Contract 6.7, host monotonic clock: t_input (GUI event) -> t_apply (block-write reply) ->
    t_data (first frame whose metadata scene_id is the new SCENE_ID) -> t_pixel (the image from that
    frame submitted to Holoviz).

    The app looks at a frame only when its loop comes round (the receiver hands it the newest frame; at
    10-80 Gb/s most frames are counted, not looked at), so the first frame it sees with the new scene can
    be a later one than the activation frame. Two numbers therefore:
      mouse->data  t_input -> the activation frame (metadata scene_frame) completed in GPU memory: the
                   receiver's completion time of the frame seen (metadata received_s/ns, CLOCK_REALTIME,
                   mapped to the monotonic clock) minus (frame_index - scene_frame) frame periods;
      mouse->app   t_input -> the app first looked at a frame of the new scene (contract 6.7 t_data).
    mouse->pixel = mouse->app + that frame's data->pixel. Board frames = scene_frame - OPS_FRAMES read
    right after the APPLY reply (frames completed in the run at that moment)."""

    def __init__(self, bstats):
        self.lock = threading.Lock()
        self.pending = collections.OrderedDict()
        self.newest_fn = 0
        self.wait_pixel = None
        self.bs = bstats
        self.frame_s = 0.0          # frame period (BeamOp's rate estimate)

    def expect(self, sid, t_input):
        with self.lock:
            self.pending[sid] = dict(t_input=t_input, t_apply=None, fn_apply=None)

    def applied(self, sid, t_apply, frames_done=None):
        with self.lock:
            if sid in self.pending:
                self.pending[sid].update(t_apply=t_apply, fn_apply=self.newest_fn if frames_done is None else frames_done)

    def has_pending(self):
        return bool(self.pending)

    def on_frame(self, sid, scene_frame, t_arr, frame_index=None, t_recv=None):
        with self.lock:
            if sid not in self.pending:
                return False
            e = self.pending[sid]
            for k in [k for k in self.pending if k <= sid]:   # older ids were replaced before activation
                del self.pending[k]
            self.bs.m2a_ms.append((t_arr - e["t_input"]) * 1e3)
            if t_recv is not None and frame_index is not None and t_recv > 0:
                t_land = t_recv - (time.time() - time.monotonic()) - max(frame_index - scene_frame, 0) * self.frame_s
                self.bs.m2d_ms.append((t_land - e["t_input"]) * 1e3)
                self.bs.skip_frames.append(frame_index - scene_frame)
            else:
                self.bs.m2d_ms.append((t_arr - e["t_input"]) * 1e3)
            if e["t_apply"] is not None:
                self.bs.apply_ms.append((e["t_apply"] - e["t_input"]) * 1e3)
                self.bs.board_frames.append(scene_frame - e["fn_apply"])
            self.wait_pixel = (t_arr, (t_arr - e["t_input"]) * 1e3)
            return True

    def on_pixel(self, t_pixel, t_arr_img=None):
        """The image computed from the frame that arrived at t_arr_img was handed to Holoviz at t_pixel; it
        closes the outstanding mouse-to-pixel if it is that frame or a newer one."""
        with self.lock:
            if self.wait_pixel is not None and (t_arr_img is None or t_arr_img >= self.wait_pixel[0]):
                t_arr, m2d = self.wait_pixel
                self.bs.m2p_ms.append(m2d + (t_pixel - t_arr) * 1e3)
                self.wait_pixel = None


MVDR_RANGE_DB = 30.0             # MVDR display: mvdr_top_db .. mvdr_top_db - 30 dB re the mean element power


def sky_q(bf, name, mvdr_top_db=-10.0):
    """The sky map for the display -> [0, 1]: conventional 0 .. -40 dB of its own peak; MVDR on an absolute scale,
    mvdr_top_db .. mvdr_top_db - MVDR_RANGE_DB re the frame's mean element power tr(R) / N (higher values clip to
    white). Per-map normalisation turned a self-nulled MVDR map (uncalibrated array, preset 5: peak ~-26 dB, the
    rest ~-36 dB re element power) into a flat bright disc (B5); on the absolute scale the floor is dark, the
    uncalibrated source a dim blob and the calibrated one a white peak. The top is 10 dB below the element
    power because MVDR peaks are narrower than the 128 x 128 grid: a calibrated source's peak cell is 8-14 dB
    below the element power (beam_model, presets 1, 2, 3, 5)."""
    P = bf.sky(name)
    if name == "mvdr":
        return bg.db_ref(P, bf.element_power() * np.float32(10 ** (mvdr_top_db / 10)), floor_db=-MVDR_RANGE_DB)
    return bg.db_norm(P)


def uncalibrated(scene, preset_n):
    """The scene has element gain errors (or is preset 5, the calibration scene): the hint 'press C' applies."""
    if preset_n == 5:
        return True
    return scene is not None and any(abs(complex(g) - 1) > 1e-3 for g in scene.gains)


def read_beam_fields(mem):
    """Bytes 48-63 of the frame's 128-byte metadata record in GPU memory (contract 3)."""
    um = cp.cuda.UnownedMemory(mem + MD_OFF + bs.MD_SCENE_ID, 16, owner=None)
    a = cp.ndarray((16,), dtype=cp.uint8, memptr=cp.cuda.MemoryPointer(um, 0)).get()
    return struct.unpack(">IIII", a.tobytes())


# ------------------------------------------------------------------------------------------
# synthetic sources
# ------------------------------------------------------------------------------------------
class BeamSyntheticOp(Operator):
    """Writes array frames into a GPU page ring like the board over RoCE (frame, then the 128-byte
    big-endian record at roundup(frame, 128) with the beam fields in bytes 48-63) and emits them with
    RoceReceiverOp's metadata. The scene comes from SimRegs: written by the app through the same
    register encoding as the board, activated at the next frame boundary (scene_frame = that frame).
    synthetic: beam_model.generate_frame in a thread (numpy); csynthetic: beam_gpu.GpuGenerator."""

    def __init__(self, fragment, *args, cfg, regs, **kwargs):
        self.c, self.regs = cfg, regs
        super().__init__(fragment, *args, **kwargs)

    def setup(self, spec):
        spec.output("output")

    def start(self):
        c = self.c
        self.ps = MD_OFF + rh.METADATA_SIZE
        self.ring = cp.zeros(c.pages * self.ps, dtype=cp.uint8)
        self.base = self.ring.data.ptr
        self.ppf = rh.packets_per_frame(FRAME_SIZE, c.mtu)
        self.f = 0
        self.sent = 0
        self.ext = None
        self.k_rec = rh.FastKernel("wr_record", [rh.U8, rh.U32, rh.U32, rh.U8, rh.U8, rh.U32, rh.U8, rh.U32])
        self.t0 = time.time()
        self.enabled = True
        self.stop_ev = threading.Event()
        if c.source == "csynthetic":
            self.gen = bg.GpuGenerator()
        else:
            # beam_model in a spawned process (not a thread: its numpy work would hold this process's GIL)
            import multiprocessing as mp
            import beam_synth
            ctx = mp.get_context("spawn")
            self.q_scene, self.q_req, self.q = ctx.Queue(), ctx.Queue(), ctx.Queue(maxsize=2)
            self.mp_stop = ctx.Event()
            self.proc = ctx.Process(target=beam_synth.model_worker, name="beam-model", daemon=True,
                                    args=(self.regs.active, self.q_scene, self.q_req, self.q, self.mp_stop))
            self.outstanding, self.next_due = False, time.monotonic()
            self.period = 1.0 / c.synth_fps if c.synth_fps > 0 else 0.0
            self.proc.start()
            self.regs.sink = self.q_scene.put
            self.regs.running = True
        print(f"synthetic array source on: {c.source}, {c.synth_fps:g} frames/s, {c.pages} pages", flush=True)

    def enable(self):
        self.enabled = True

    def stop(self):
        self.stop_ev.set()
        if self.c.source == "synthetic":
            self.regs.sink = None
            self.mp_stop.set()
            try:
                while True:
                    self.q.get_nowait()
            except Exception:
                pass
            self.proc.join(timeout=3)
            if self.proc.is_alive():
                self.proc.terminate()
        print(f"synthetic array source off after {self.sent} frames", flush=True)

    def compute(self, op_input, op_output, context):
        c = self.c
        if c.source == "csynthetic":
            f = self.f
            self.f += 1
            scene, sf = self.regs.frame_start(f)
            page = f % c.pages
            ptr = self.base + page * self.ps
            self.gen.frame(ptr, scene, f, sf)
        else:
            # the op ticks every 5 ms: request a frame when one is due, emit it as soon as it is ready
            now = time.monotonic()
            if not self.outstanding and now >= self.next_due:
                self.q_req.put(1)
                self.outstanding = True
                self.next_due = max(self.next_due + self.period, now - self.period)
            try:
                f, scene, sf, data = self.q.get_nowait()
            except queue.Empty:
                return
            self.outstanding = False
            if sf == f and scene.scene_id != self.regs.applied_id:
                self.regs.activated(scene, f)
            page = f % c.pages
            ptr = self.base + page * self.ps
            self.ring[page * self.ps:page * self.ps + FRAME_SIZE].set(np.frombuffer(data, dtype=np.uint8))
        f16 = f & 0xFFFF
        self.ext = f16 if self.ext is None else self.ext + ((f16 - self.ext) & 0xFFFF)
        psn = ((f + 1) * self.ppf - 1) & 0xFFFFFF
        now = time.time() - self.t0
        ts_s, ts_ns = int(now), int((now % 1) * 1e9)
        self.k_rec(1, 128, ptr + MD_OFF, psn, f16, FRAME_SIZE, ts_s, ts_ns, ts_s, ts_ns)
        cp.cuda.get_current_stream().synchronize()       # wr_record zeroes the record: beam fields after it
        beam = np.frombuffer(struct.pack(">IIII", scene.scene_id & 0xFFFFFFFF, sf, f & 0xFFFFFFFF, bs.MD_TAG_BEAM),
                             dtype=np.uint8)
        self.ring[page * self.ps + MD_OFF + 48:page * self.ps + MD_OFF + 64].set(beam)
        self.sent += 1
        t = time.time()
        md = self.metadata
        for k, v in dict(frame_number=self.ext, imm_data=((psn & 0xFFFFF) << 12) | page, page_number=page,
                         frame_memory=ptr, dropped=0, bytes_written=FRAME_SIZE, received_frame_number=self.sent,
                         timestamp_s=ts_s, timestamp_ns=ts_ns, metadata_s=ts_s, metadata_ns=ts_ns,
                         received_s=int(t), received_ns=int((t % 1) * 1e9), crc=0).items():
            md[k] = v
        op_output.emit({"": self.ring[page * self.ps:page * self.ps + FRAME_SIZE]}, "output")


# ------------------------------------------------------------------------------------------
# beamformer + view
# ------------------------------------------------------------------------------------------
class BeamOp(Operator):
    """Per frame: count it, and while a scene change is outstanding read its beam metadata (latency).
    At the display rate (--fps; frames in between are dropped) and on the first frame of a new scene:
    beamform (beam_gpu.BeamGpu), compose the canvas (beam_ui.Canvas) and emit it with the Holoviz
    layers (markers, crosshair, spectrum, text tiles)."""

    def __init__(self, fragment, *args, cfg, stats, bstats, ui, lat, history, web=None, **kwargs):
        self.c, self.st, self.bs, self.ui, self.lat, self.history = cfg, stats, bstats, ui, lat, history
        self.web = web
        super().__init__(fragment, *args, **kwargs)

    def setup(self, spec):
        spec.input("input")
        # never blocked by the display: the image goes to VizRelayOp (queue of 1, newest wins), so this
        # operator keeps taking every frame it can (rates, latency, verify) while Holoviz renders
        spec.output("output").condition(ConditionType.NONE)

    def start(self):
        c = self.c
        self.bf = bg.BeamGpu(g=c.grid, loading=c.loading)
        self.canvas = ui_mod.Canvas(cp)
        self.period = 1.0 / c.fps if c.fps > 0 else 0.0
        self.t_last = 0.0
        self.cal_on, self.cal_epoch, self.cal_resid = False, -1, None
        self.rate = dict(t=time.monotonic(), rx=0, proc=0, fn=None, rx_s=0.0, proc_s=0.0, gbps=0.0, fn_s=0.0)
        self.spec_ema = None
        self.t_web = 0.0
        self.web_idx = None
        if c.verify:
            self.vgen = bg.GpuGenerator()
            self.vref = cp.empty(FRAME_SIZE // 4, dtype=cp.uint32)
            self.vrx = cp.empty(MD_OFF + rh.METADATA_SIZE, dtype=cp.uint8)
            self.t_vlast = 0.0
        # the stream rate follows the board's RATE_MBPS (ui.rate_gbps: --rate, then the - / + keys and the
        # page): verify page age, latency frame period and the rate window are rebuilt on every change
        self.rate_seen = self.ui.rate_gbps
        self.v_max_age = self._max_age(self.rate_seen)
        self.t_rate_change, self.v_age_hold = 0.0, self.v_max_age
        if frame_period_s(self.rate_seen):
            self.lat.frame_s = frame_period_s(self.rate_seen)   # until the first 1 s measurement
        self._warm_up()

    def _max_age(self, gbps):
        """--verify: a page is rewritten pages x frame period after it was filled; compare only frames that
        reached us within half of that (else the copy could catch frame f + pages arriving)."""
        fp = frame_period_s(gbps) if self.c.source == "roce" else 0.0
        return 0.5 * self.c.pages * fp if fp else 1e9

    def _rate_follow(self, t, fn):
        """The commanded rate changed (Control wrote RATE_MBPS; the board applies it from its next frame start)."""
        old, g = self.rate_seen, self.ui.rate_gbps
        self.rate_seen = g
        # for 1 s keep the shorter page age of the two rates (frames in flight still at the old one when faster)
        self.v_age_hold = min(self._max_age(old), self._max_age(g))
        self.t_rate_change = t
        self.v_max_age = self._max_age(g)
        if frame_period_s(g):
            self.lat.frame_s = frame_period_s(g)          # until the next 1 s measurement at the new rate
        r = self.rate
        r.update(t=t, rx=self.bs.rx, proc=self.bs.processed, fn=fn)   # the next window starts at the new rate

    def compute(self, op_input, op_output, context):
        try:
            self._compute(op_input, op_output)
        except Exception:
            self.bs.exceptions.append(traceback.format_exc())
            print(self.bs.exceptions[-1], flush=True)
            raise

    def _compute(self, op_input, op_output):
        msg = op_input.receive("input")
        t_arr = time.monotonic()
        md = self.metadata
        mem = int(md.get("frame_memory", 0)) or cp.asarray(msg[""]).data.ptr
        fn = int(md.get("frame_number", 0))
        self.lat.newest_fn = fn
        b = self.bs
        b.rx += 1
        if self.ui.rate_gbps != self.rate_seen:
            self._rate_follow(t_arr, fn)
        beam = None
        force = False
        if self.c.verify and (self.c.verify < 0 or t_arr - self.t_vlast >= 1.0 / self.c.verify):
            self.t_vlast = t_arr
            self._verify(mem, fn, md)
        rs, rns = md.get("received_s", None), md.get("received_ns", None)
        t_recv = int(rs) + int(rns) * 1e-9 if rs is not None and rns is not None else None
        if self.lat.has_pending():
            beam = read_beam_fields(mem)
            force = self.lat.on_frame(beam[0], beam[1], t_arr, beam[2], t_recv)
        if not force and t_arr - self.t_last < self.period:
            self._rates(t_arr, fn)
            return
        self.t_last = t_arr
        if t_recv:
            b.recv_age_ms.append((time.time() - t_recv) * 1e3)
        if beam is None:
            beam = read_beam_fields(mem)
        sid, sframe, findex, tag = beam
        if tag != bs.MD_TAG_BEAM:
            b.tag_bad += 1
        scene = self.history.get(sid)
        if scene is None:
            b.unknown_scene += 1
        snap = self.ui.snapshot()
        h0 = time.perf_counter()
        e0, e1 = cp.cuda.Event(), cp.cuda.Event()
        e0.record()
        self._calibration(mem, snap, scene)
        bf = self.bf
        bf.set_mask(scene.enable if scene is not None else snap["enable"])   # the frame's ELEM_EN
        bf.unpack(mem, calibrated=self.cal_on)
        bf.covariance()
        name = snap["beamformer"]
        q_sky, i_sky = sky_q(bf, name, self.c.mvdr_top_db)
        u0, v0 = snap["steer"]
        w = bf.weights(u0, v0, name)
        q_pat, _ = bg.db_norm(bf.pattern(w))
        S = bf.spectrum(w)
        a = self.c.spec_avg
        self.spec_ema = S if (self.spec_ema is None or a <= 0) else (1 - a) * S + a * self.spec_ema
        spec_xy = ui_mod.spectrum_coords(cp, self.spec_ema)
        self.canvas.background(snap["enable"], self.cal_on)
        img = self.canvas.compose(q_sky, q_pat, bf.g)
        e1.record()
        i_peak = int(i_sky.get())                       # synchronises: the GPU work of this frame is done
        b.gpu_ms.append(cp.cuda.get_elapsed_time(e0, e1))
        b.processed += 1
        if b.t_first is None:
            b.t_first = time.monotonic()
        # end-to-end self-check: the strongest cell lies on a true source of the scene of this frame
        if scene is not None:
            pu, pv = bg.peak_uv(i_peak, bf.g)
            act = [s for s in scene.sources if s.type != bs.T_OFF]
            if act:
                b.peak_n += 1
                if min(bg.uv_dist((pu, pv), (s.u, s.v)) for s in act) <= PEAK_TOL:
                    b.peak_ok += 1
        self._rates(t_arr, fn)
        if self.web is not None and t_arr - self.t_web >= 1.0 / self.c.web_hz and self.web.hub.wanted():
            self.t_web = t_arr
            self._web_publish(q_sky, scene, snap, sid, sframe, (u0, v0))
        if self.c.viz != "none":
            self._emit(op_output, img, spec_xy, scene, snap, sid, sframe, findex, (u0, v0), t_arr)
        b.host_ms.append((time.perf_counter() - h0) * 1e3)
        if self.c.viz == "none":
            t_pix = time.monotonic()
            b.d2p_ms.append((t_pix - t_arr) * 1e3)
            if force:
                self.lat.on_pixel(t_pix)

    def _warm_up(self):
        """Run every kernel once on a generated frame before the start gate opens (start() of all operators
        precedes it): the first frame then takes ms, not the ~7 s of CuPy compilation / cuFFT plans, and the
        GPU is busy (not in P8 / PCIe Gen1) when the board starts streaming. B5: without it the 40 Gb/s start
        lost 2 frames while the first compute() compiled."""
        t0 = time.monotonic()
        buf = cp.zeros(MD_OFF + rh.METADATA_SIZE, dtype=cp.uint8)
        gen = bg.GpuGenerator()
        sc = bs.preset(2)
        gen.frame(buf.data.ptr, sc, 0, 0)
        bf = self.bf
        for cal in (False, True):
            bf.unpack(buf.data.ptr, calibrated=cal)
            bf.covariance()
            for name in ("conv", "mvdr"):
                q_sky, i_sky = sky_q(bf, name, self.c.mvdr_top_db)
                w = bf.weights(0.1, 0.1, name)
                q_pat, _ = bg.db_norm(bf.pattern(w))
                ui_mod.spectrum_coords(cp, bf.spectrum(w))
                self.canvas.background((1 << 64) - 1, False)
                self.canvas.compose(q_sky, q_pat, bf.g)
                int(i_sky.get())
        bf.set_mask(bs.preset(4).enable)                   # the masked steering matrix (an element click)
        bf.unpack(buf.data.ptr, calibrated=False)
        bf.covariance()
        sky_q(bf, "mvdr", self.c.mvdr_top_db)[1].get()
        bf.set_mask((1 << 64) - 1)
        try:
            bf.calibrate(0.0, 0.0, (1 << 64) - 1)
        except Exception as e:
            print(f"warm-up: calibrate: {e}", flush=True)
        read_beam_fields(buf.data.ptr)
        if self.c.verify:                                  # the comparison's elementwise / reduction kernels
            self.vrx[:] = buf
            self.vgen.frame(self.vref.data.ptr, sc, 0, 0)
            d = self.vref != self.vrx[:FRAME_SIZE].view(cp.uint32)
            int(cp.count_nonzero(d)), int(cp.argmax(d))
            self.vrx[MD_OFF + 48:MD_OFF + 64].get()
        cp.cuda.get_current_stream().synchronize()
        # compiling left the GPU idle for seconds (P8, PCIe link down-trained); the NIC's writes into GPU
        # memory then stall at the data-plane start (B5: 36 frames lost at a 40 Gb/s start). Load it for a
        # second so the start gate (right after the start() calls) opens on a GPU at full clocks.
        t1 = time.monotonic()
        while time.monotonic() - t1 < 1.0:
            bf.unpack(buf.data.ptr, calibrated=False)
            bf.covariance()
            bg.db_norm(bf.sky("mvdr"))[1].get()
        self.canvas.bg_key = None
        print(f"beamformer warm-up {time.monotonic() - t0:.2f} s", flush=True)

    def _verify(self, mem, fn, md):
        """--verify: compare this frame word for word with beam_gpu.GpuGenerator for the scene / frame_index /
        scene_frame of its own metadata record (contract 2, 3, 5): the strongest end-to-end check of packing,
        time index, scene activation and metadata."""
        b = self.bs
        rs, rns = md.get("received_s", None), md.get("received_ns", None)
        if rs is not None and rns is not None and int(rs) > 0:
            age = time.time() - (int(rs) + int(rns) * 1e-9)
            lim = self.v_max_age
            if time.monotonic() - self.t_rate_change < 1.0:
                lim = min(lim, self.v_age_hold)
            if age > lim:
                b.v_skipped += 1
                return
        um = cp.cuda.UnownedMemory(mem, MD_OFF + rh.METADATA_SIZE, owner=None)
        src = cp.ndarray((MD_OFF + rh.METADATA_SIZE,), dtype=cp.uint8, memptr=cp.cuda.MemoryPointer(um, 0))
        self.vrx[:] = src
        after = read_beam_fields(mem)                       # synchronises (the copy is done)
        sid, sframe, findex, tag = struct.unpack(">IIII", self.vrx[MD_OFF + 48:MD_OFF + 64].get().tobytes())
        if tuple(after) != (sid, sframe, findex, tag):
            b.v_overrun += 1
            return
        if tag != bs.MD_TAG_BEAM or sid not in self.history:
            b.v_skipped += 1
            return
        if (findex & 0xFFFF) != (fn & 0xFFFF):
            b.v_fidx_bad += 1
        self.vgen.frame(self.vref.data.ptr, self.history[sid], findex, sframe)
        rx = self.vrx[:FRAME_SIZE].view(cp.uint32)
        diff = self.vref != rx
        nbad = int(cp.count_nonzero(diff))
        b.v_frames += 1
        if nbad:
            b.v_bad_frames += 1
            b.v_bad_words += nbad
            if len(b.v_dumps) < 3:
                i = int(cp.argmax(diff))
                t, k = divmod(i, 64)
                d = dict(frame_number=fn, scene_id=sid, scene_frame=sframe, frame_index=findex, bad_words=nbad,
                         first_bad=dict(word=i, t=t, element=k, got=hex(int(rx[i])), want=hex(int(self.vref[i]))))
                path = os.path.join(self.c.outdir, f"{self.c.tag}_mismatch{len(b.v_dumps)}.npz")
                try:
                    np.savez_compressed(path, rx=self.vrx.get(), ref=self.vref.get())
                    d["file"] = path
                except Exception as e:
                    d["file_error"] = str(e)
                b.v_dumps.append(d)
                print(f"verify MISMATCH {d}", flush=True)

    def _calibration(self, mem, snap, scene):
        bf, ui = self.bf, self.ui
        if self.cal_on and (not snap["cal_want"] or snap["cal_epoch"] != self.cal_epoch):
            bf.set_calibration(None)
            self.cal_on, self.cal_resid = False, None
        if snap["cal_want"] and not self.cal_on:
            sc = scene or ui.scene
            act = [s for s in sc.sources if s.type != bs.T_OFF]
            if len(act) != 1:
                ui.say("calibration needs a scene with ONE source at a known direction (preset 5)")
                with ui.lock:
                    ui.cal_want = False
                return
            bf.unpack(mem, calibrated=False)
            bf.covariance()
            g = bf.calibrate(act[0].u, act[0].v, sc.enable)
            bf.set_calibration(g)
            en = np.array([(sc.enable >> k) & 1 for k in range(bs.N_EL)], dtype=bool)
            gt = np.array(sc.gains, dtype=complex)
            gt = gt / gt[en].mean()
            self.cal_resid = float(np.max(np.abs(g[en] - gt[en])))
            self.cal_on, self.cal_epoch = True, snap["cal_epoch"]
            self.bs.cal.append(dict(t=time.monotonic(), residual=self.cal_resid, u=act[0].u, v=act[0].v))
            ui.say(f"calibrated on the source at ({act[0].u:+.2f}, {act[0].v:+.2f}): max error {self.cal_resid * 100:.1f} %")

    def _rates(self, t, fn):
        r = self.rate
        if r["fn"] is None:
            r["fn"] = fn
        dt = t - r["t"]
        if dt >= 1.0:
            r["rx_s"] = (self.bs.rx - r["rx"]) / dt
            r["proc_s"] = (self.bs.processed - r["proc"]) / dt
            r["fn_s"] = max(fn - r["fn"], 0) / dt                     # frames the board sent (frame numbers)
            if r["fn_s"] > 0:
                self.lat.frame_s = 1.0 / r["fn_s"]
            r["gbps"] = r["fn_s"] * (FRAME_SIZE + rh.METADATA_SIZE) * 8 / 1e9
            r.update(t=t, rx=self.bs.rx, proc=self.bs.processed, fn=fn)

    def _scale_text(self, name):
        if name == "mvdr":
            t = self.c.mvdr_top_db
            return f"power {t:+.0f} .. {t - MVDR_RANGE_DB:+.0f} dB re element power"
        return "power 0 .. -40 dB re peak"

    def _tiles(self):
        b, st, r = self.bs, self.st, self.rate
        gpu = float(np.median(list(b.gpu_ms)[-60:])) if b.gpu_ms else 0.0
        return dict(gbps=round(r["gbps"], 2), rate_set=self.ui.rate_gbps, fps_in=round(r["fn_s"]),
                    shown=round(r["proc_s"], 1), lost=b.lost_steady(st),
                    lost_start=b.lost_start, errors=st.psn_bad + st.psn_seq_bad + st.bw_bad + b.tag_bad, gpu_ms=round(gpu, 2),
                    m2d_ms=round(b.m2d_ms[-1], 2) if b.m2d_ms else None, m2p_ms=round(b.m2p_ms[-1], 2) if b.m2p_ms else None)

    def _web_publish(self, q_sky, scene, snap, sid, sframe, steer):
        """The page's copy of what the monitor shows (beam_web.py): the sky map as WEB_G x WEB_G uint8, the true
        sources of this frame's scene, the steered beam, the element mask, the tiles."""
        g = self.bf.g
        q = q_sky
        if g != WEB_G:
            if self.web_idx is None:
                self.web_idx = cp.asarray((np.arange(WEB_G) * g) // WEB_G)
            q = q_sky[self.web_idx][:, self.web_idx]
        q8 = cp.clip(q * 255.0 + 0.5, 0, 255).astype(cp.uint8).get()
        sc = scene or self.ui.scene
        srcs = [dict(i=i, kind="emitter" if i in ui_mod.EMITTERS else "jammer", u=round(x.u, 4), v=round(x.v, 4), amp=x.amp)
                for i, x in enumerate(sc.sources) if x.type != bs.T_OFF]
        en = snap["enable"]
        state = dict(t=round(time.time(), 3), g=WEB_G, map=beam_web.encode_map(q8.tobytes()), sources=srcs,
                     steer=[round(steer[0], 4), round(steer[1], 4)], drag=snap["drag"][1] if snap["drag"] else None,
                     enable="".join(str((en >> k) & 1) for k in range(bs.N_EL)), beamformer=snap["beamformer"],
                     scale=self._scale_text(snap["beamformer"]),
                     cal=dict(on=self.cal_on, err_pct=round(self.cal_resid * 100, 1) if self.cal_on else None),
                     hint="array uncalibrated: press C" if (not self.cal_on and uncalibrated(sc, snap["preset"])) else "",
                     preset=snap["preset"], attract=snap["attract"], scene=dict(id=sid, frame=sframe, name=sc.name),
                     tiles=self._tiles(), msg=snap["msgs"][-1] if snap["msgs"] else "")
        self.web.hub.publish(state)

    # ---- Holoviz layers ----
    def _emit(self, op_output, img, spec_xy, scene, snap, sid, sframe, findex, steer, t_arr):
        from holoscan.operators import HolovizOp as HV
        c, b, st = self.c, self.bs, self.st
        sc = scene or self.ui.scene
        tensors = {"canvas": img, "spec": spec_xy}
        specs = []

        def spec(name, typ, color, lw=None, text=None):
            s = HV.InputSpec(name, typ)
            s.color = color
            if lw is not None:
                s.line_width = lw
            if text is not None:
                s.text = text
            specs.append(s)

        spec("canvas", HV.InputType.COLOR, [1, 1, 1, 1])
        spec("spec", HV.InputType.LINE_STRIP, ui_mod.COL_STEER, 2.5)
        # source markers on the sky (large) and on the pattern (small): truth of this frame's scene
        em, jm = [], []
        for s, src in enumerate(sc.sources):
            if src.type == bs.T_OFF:
                continue
            for r, size in ((ui_mod.SKY, 58), (ui_mod.PAT, 20)):
                x, y = r.from_uv(src.u, src.v)
                (em if s in ui_mod.EMITTERS else jm).append((x, y, size))
        # markers get a dark outline first: on the saturated (white) blob of their own source a green or red
        # 4 px line alone was hard to see on the monitor (B5 webcam)
        if em:
            t_em = cp.asarray(np.array([[x / W, y / H, sz / W, sz / H] for x, y, sz in em], np.float32))
            tensors["emit_o"], tensors["emit"] = t_em, t_em.copy()
            spec("emit_o", HV.InputType.OVALS, MARK_OUTLINE, 10.0)
            spec("emit", HV.InputType.OVALS, ui_mod.COL_EMIT, 5.0)
        if jm:
            t_jm = cp.asarray(np.array([[[(x - sz / 2) / W, (y - sz / 2) / H], [(x + sz / 2) / W, (y + sz / 2) / H]]
                                        for x, y, sz in jm], np.float32).reshape(-1, 2))
            tensors["jam_o"], tensors["jam"] = t_jm, t_jm.copy()
            spec("jam_o", HV.InputType.RECTANGLES, MARK_OUTLINE, 10.0)
            spec("jam", HV.InputType.RECTANGLES, ui_mod.COL_JAM, 5.0)
        # the steered beam: an open crosshair (four arms, a gap in the middle) so the peak it points at stays visible
        segs = []
        for r, half, gap in ((ui_mod.SKY, 26, 8), (ui_mod.PAT, 12, 4)):
            x, y = r.from_uv(*steer)
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                segs.append([(x + dx * gap) / W, (y + dy * gap) / H])
                segs.append([(x + dx * half) / W, (y + dy * half) / H])
        tensors["steer"] = cp.asarray(np.array(segs, np.float32))
        spec("steer", HV.InputType.LINES, ui_mod.COL_STEER, 3.0)
        if snap["grab_uv"] is not None:
            x, y = ui_mod.SKY.from_uv(*snap["grab_uv"])
            tensors["grab"] = cp.asarray(np.array([[x / W, y / H, 84 / W, 84 / H]], np.float32))
            spec("grab", HV.InputType.OVALS, ui_mod.COL_GRAB, 2.0)
        # text
        T = collections.defaultdict(lambda: ([], []))

        def txt(layer, x, y, s, size=ui_mod.TS):
            T[layer][0].append(s)
            T[layer][1].append([x / W, y / H, size])

        r = self.rate
        src_name = {"roce": "KCU116 -> 100G RoCE -> GPU", "synthetic": "synthetic (bit-exact model) -> GPU",
                    "csynthetic": "synthetic (CUDA model) -> GPU"}[c.source]
        txt("title", 28, 8, f"8 x 8 PHASED-ARRAY RECEIVER     {src_name}", ui_mod.TS_TITLE)
        txt("label", 28, 56, "L-drag emitter  R-drag jammer  wheel amplitude  M-click lock beam  1-5 presets  "
                             "B beamformer  C calibrate  N noise  A attract  R reset  -/+ rate  Esc quit",
            ui_mod.TS_SMALL)
        msgs = snap["msgs"]
        if msgs:
            txt("warn", ui_mod.RX, 14, msgs[-1][:62], 0.026)
        bfn = "MVDR" if snap["beamformer"] == "mvdr" else "CONVENTIONAL"
        txt("value", ui_mod.SKY.x + 14, ui_mod.SKY.y + 8, bfn, ui_mod.TS_BIG)
        txt("label", ui_mod.SKY.x + 14, ui_mod.SKY.y + 62,
            f"(Capon, loading {c.loading:g})" if snap["beamformer"] == "mvdr" else "(Bartlett)", ui_mod.TS_SMALL)
        txt("label", ui_mod.SKY.x + 14, ui_mod.SKY.y + 90,
            self._scale_text(snap["beamformer"]),
            ui_mod.TS_SMALL)
        if not self.cal_on and uncalibrated(sc, snap["preset"]):
            txt("warn", ui_mod.SKY.x + 14, ui_mod.SKY.y + 122, "array uncalibrated: press C", 0.030)
        xr = ui_mod.SKY.x + ui_mod.SKY.w - 14
        txt("emit", xr - 175, ui_mod.SKY.y + 12, "O emitter", 0.028)
        txt("jam", xr - 175, ui_mod.SKY.y + 48, "[] jammer", 0.028)
        txt("steer", xr - 175, ui_mod.SKY.y + 84, "+  beam", 0.028)
        yb = ui_mod.SKY.y + ui_mod.SKY.w - 40
        txt("label", ui_mod.SKY.x + 14, yb, f"u, v: direction cosines   G = {self.bf.g}", ui_mod.TS_SMALL)
        txt("label", xr - 250, yb, f"R from {bs.T_FRAME} samples", ui_mod.TS_SMALL)
        # panel titles
        txt("label", ui_mod.PAT.x, ui_mod.PAT.y - 40, f"BEAM PATTERN   u {steer[0]:+.2f}  v {steer[1]:+.2f}", 0.028)
        txt("label", ui_mod.SPEC.x - 76, ui_mod.SPEC.y - 46, "BEAM OUTPUT SPECTRUM   dBFS per bin", 0.028)
        for db in range(0, int(ui_mod.SPEC_RANGE) + 1, 20):
            y = ui_mod.SPEC.y + db / ui_mod.SPEC_RANGE * (ui_mod.SPEC.h - 1)
            txt("label", ui_mod.SPEC.x - 66, y - 10, f"{-db:4d}", 0.020)
        ylab = ui_mod.SPEC.y + ui_mod.SPEC.h + 8
        txt("label", ui_mod.SPEC.x, ylab, "-Fs/2", 0.022)
        txt("label", ui_mod.SPEC.x + ui_mod.SPEC.w / 2 - 6, ylab, "0", 0.022)
        txt("label", ui_mod.SPEC.x + ui_mod.SPEC.w - 62, ylab, "+Fs/2", 0.022)
        txt("label", ui_mod.EL.x, ui_mod.EL.y - 40, "ARRAY 8 x 8   (click: fail / restore)", 0.028)
        # tiles
        x1, y1 = ui_mod.TILES1
        gpu = np.median(list(b.gpu_ms)[-60:]) if b.gpu_ms else 0
        lost = b.lost_steady(st)
        recerr = st.psn_bad + st.psn_seq_bad + st.bw_bad + b.tag_bad
        rset = snap.get("rate")
        stream = f"{r['gbps']:5.1f} of {rset:g} Gb/s" if rset else f"{r['gbps']:6.2f} Gb/s"
        rows1 = [("stream", stream), ("frames", f"{r['fn_s']:6.0f} /s in"),
                 ("shown", f"{r['proc_s']:6.1f} /s"), ("lost", f"{lost}" + (f"   (+{b.lost_start} at start)" if b.lost_start else "")),
                 ("errors", f"{recerr}"), ("GPU", f"{gpu:5.2f} ms/frame")]
        for i, (k, v) in enumerate(rows1):
            txt("label", x1, y1 + 2 + 52 * i, k)
            txt("value" if not (k in ("errors", "lost") and v.split()[0] != "0") else "warn", x1 + 140, y1 - 3 + 52 * i, v,
                ui_mod.TS_VALUE)
        x2, y2 = ui_mod.TILES2

        def ms(dq):
            return f"{dq[-1]:6.2f} ms" if dq else "    -"
        n_on = bin(snap["enable"]).count("1")
        cal = "OFF" if not self.cal_on else f"ON  err {self.cal_resid * 100:.1f} %"
        rows2 = [("scene", f"#{sid}  frame {sframe}"), ("mouse->data", ms(b.m2d_ms)), ("mouse->pixel", ms(b.m2p_ms)),
                 ("elements", f"{n_on} / 64 on"), ("calibration", cal)]
        for i, (k, v) in enumerate(rows2):
            txt("label", x2, y2 + 2 + 48 * i, k)
            txt("value", x2 + 226, y2 - 3 + 48 * i, v, ui_mod.TS_VALUE)
        if snap["attract"]:
            txt("warn", ui_mod.SKY.x + 14, yb - 46, "ATTRACT MODE", 0.030)
        colours = dict(title=ui_mod.COL_TITLE, label=ui_mod.COL_LABEL, value=ui_mod.COL_VALUE, warn=ui_mod.COL_WARN,
                       emit=ui_mod.COL_EMIT, jam=ui_mod.COL_JAM, steer=ui_mod.COL_STEER)
        for layer, (strings, coords) in T.items():
            name = "t_" + layer
            tensors[name] = cp.asarray(np.array(coords, np.float32))
            spec(name, HV.InputType.TEXT, colours[layer], text=strings)
        op_output.emit((tensors, specs, t_arr), "output")


class VizRelayOp(Operator):
    """Between BeamOp and Holoviz: input queue of 1 with policy POP (a newer image replaces one Holoviz has
    not taken yet), outputs gated by Holoviz's queue. BeamOp is therefore never blocked by the display (vsync,
    rendering) and keeps up with the frames; this operator stamps data-to-pixel when it hands an image over."""

    def __init__(self, fragment, *args, bstats, lat, **kwargs):
        self.bs, self.lat = bstats, lat
        super().__init__(fragment, *args, **kwargs)

    def setup(self, spec):
        from holoscan.core import IOSpec
        spec.input("input", policy=IOSpec.QueuePolicy.POP)
        spec.output("output").condition(ConditionType.DOWNSTREAM_MESSAGE_AFFORDABLE)
        spec.output("output_specs").condition(ConditionType.DOWNSTREAM_MESSAGE_AFFORDABLE)

    def compute(self, op_input, op_output, context):
        tensors, specs, t_arr = op_input.receive("input")
        op_output.emit(tensors, "output")
        op_output.emit(specs, "output_specs")
        t_pix = time.monotonic()
        self.bs.d2p_ms.append((t_pix - t_arr) * 1e3)
        self.lat.on_pixel(t_pix, t_arr)


# ------------------------------------------------------------------------------------------
# control: scene writer (<= 20 Hz), attract mode, script
# ------------------------------------------------------------------------------------------
class Control(threading.Thread):
    def __init__(self, cfg, ui, regs, lat, history, bstats):
        super().__init__(name="beam-control", daemon=True)
        self.c, self.ui, self.regs, self.lat, self.history, self.bs = cfg, ui, regs, lat, history, bstats
        self.next_id = 1
        self.sent = None
        self.t_send = 0.0
        self.t_attract = 0.0
        self.ev = threading.Event()
        self.script = ui_mod.parse_script(cfg.script)
        self.si = 0

    def send_pending(self, initial=False):
        ch = self.ui.take_change()
        if ch is None:
            return False
        sc, full, t_in = ch
        sc.scene_id = self.next_id
        self.next_id += 1
        pairs = sc.to_registers() if (full or self.sent is None) else sc.changed_registers(self.sent)
        self.history[sc.scene_id] = sc
        for k in [k for k in self.history if k and k < sc.scene_id - 400]:
            del self.history[k]
        if not initial:                       # the start scene is written before the data plane runs
            self.lat.expect(sc.scene_id, t_in)
        try:
            t_apply = self.regs.write_block(pairs)
        except Exception as e:                # keep running: resend the whole scene next time
            self.bs.write_errors += 1
            self.ui.say(f"register write failed: {e}"[:70])
            print(f"scene {sc.scene_id}: register write failed: {e}", flush=True)
            with self.ui.lock:
                self.ui.dirty, self.ui.full = True, True
            self.sent = None
            return False
        fd = None
        if not initial and hasattr(self.regs, "frames_done"):
            try:
                fd = self.regs.frames_done()
            except Exception:
                fd = None
        self.lat.applied(sc.scene_id, t_apply, fd)
        self.bs.writes += len(pairs)
        self.bs.scene_changes += 1
        self.sent = sc
        return True

    def send_rate(self, gbps):
        """Write RATE_MBPS (the firmware recomputes C_HP_PERIOD at once; the producer samples it at its next
        frame start). On a failed write the board keeps the old rate."""
        t0 = time.monotonic()
        try:
            self.regs.write_block([(bs.OPS_RATE_MBPS, int(round(gbps * 1000)))])
        except Exception as e:
            self.bs.write_errors += 1
            self.ui.say(f"rate write failed: {e}"[:70])
            print(f"rate {gbps:g} Gb/s: register write failed: {e}", flush=True)
            return False
        self.ui.rate_applied(gbps)
        tf = self.bs.t_first
        self.bs.rate_changes.append(dict(t=round(t0 - tf, 3) if tf else None, gbps=gbps,
                                         write_ms=round((time.monotonic() - t0) * 1e3, 3)))
        print(f"stream rate {gbps:g} Gb/s (RATE_MBPS {int(round(gbps * 1000))})", flush=True)
        return True

    def run(self):
        while not self.ev.wait(0.005):
            g = self.ui.take_rate()
            if g is not None:          # always write: the console (hsb rate) may have changed the board behind our back
                self.send_rate(g)
            now = time.monotonic()
            t0 = self.bs.t_first
            while t0 is not None and self.si < len(self.script) and now - t0 >= self.script[self.si][0]:
                _, cmd, args = self.script[self.si]
                self.si += 1
                try:
                    ui_mod.run_event(self.ui, cmd, args)
                except Exception as e:
                    print(f"script event {cmd} {args}: {e}", flush=True)
            if now - self.t_attract >= 0.05:
                self.t_attract = now
                self.ui.attract_step(now)
            if now - self.t_send >= 1.0 / self.c.update_hz:
                if self.send_pending():
                    self.t_send = now

    def stop(self):
        self.ev.set()
        self.join(timeout=2)


# ------------------------------------------------------------------------------------------
# application
# ------------------------------------------------------------------------------------------
class BeamApp(Application):
    def __init__(self, cfg, stats, bstats, ui, lat, history, regs, hsb=None, web=None):
        super().__init__()
        self.web = web
        self.c, self.stats, self.bs, self.ui, self.lat, self.history, self.regs = cfg, stats, bstats, ui, lat, history, regs
        self.hsb = hsb
        self.run_cond = None
        self.src = self.chk = None
        self.gate_enable = None
        self.dp_ready = threading.Event() if cfg.source == "roce" else None
        self.stopping = lambda: False
        self.quit = lambda reason: None
        self.enable_metadata(True)

    def compose(self):
        c = self.c
        threads = c.threads
        if threads > 0:
            self.scheduler(EventBasedScheduler(self, name="sched", worker_thread_number=threads))
        else:
            self.scheduler(GreedyScheduler(self, name="sched", check_recession_period_ms=0.0))
        if c.source == "roce" and c.start_gate:
            self.add_operator(rh.StartGateOp(self, CountCondition(self, name="gate_once", count=1), name="start_gate",
                                             enable=lambda: self.gate_enable(), delay=c.start_delay, stats=self.stats,
                                             stopping=lambda: self.stopping(), ready=self.dp_ready))
        self.run_cond = BooleanCondition(self, name="run", enable_tick=True)
        conds = [self.run_cond]
        if c.frames:
            conds.append(CountCondition(self, name="frames", count=c.frames))
        if c.source in ("synthetic", "csynthetic"):
            if c.source == "synthetic":     # paced inside the operator (frames on request, see BeamSyntheticOp)
                conds.append(PeriodicCondition(self, name="pace", recess_period=5_000_000))
            elif c.synth_fps > 0:
                conds.append(PeriodicCondition(self, name="pace", recess_period=int(1e9 / c.synth_fps)))
            src = BeamSyntheticOp(self, *conds, name="source", cfg=c, regs=self.regs)
        elif c.api == "module":
            import hololink_module
            import hololink_module.operators
            md, ctx = self.hsb
            dev = rh.RoceletDevice(c.start_gate, self.dp_ready)
            src = hololink_module.operators.RoceReceiverOp(
                self, *conds, name="receiver", enumeration_metadata=md, frame_context=int(ctx), frame_size=FRAME_SIZE,
                pages=c.pages, queue_size=c.queue_size, device_start=dev.start, device_stop=dev.stop)
        else:
            import hololink as hololink_module
            dc, ctx = self.hsb
            src = hololink_module.operators.RoceReceiverOp(
                self, *conds, name="receiver", hololink_channel=dc, device=rh.RoceletDevice(c.start_gate, self.dp_ready),
                frame_context=ctx, frame_size=FRAME_SIZE, ibv_name=c.ibv_name, ibv_port=c.ibv_port, pages=c.pages,
                queue_size=c.queue_size, trim=False, use_frame_ready_condition=c.frame_ready == "async")
        self.src = src
        chk = rh.CheckerOp(self, name="checker", cfg=c, stats=self.stats, passthrough=True)   # record + accounting
        self.chk = chk
        self.add_flow(src, chk, {("output", "input")})
        beam = BeamOp(self, name="beam", cfg=c, stats=self.stats, bstats=self.bs, ui=self.ui, lat=self.lat,
                      history=self.history, web=self.web)
        self.add_flow(chk, beam, {("output", "input")})
        if c.viz == "none":
            return
        from holoscan.operators import FormatConverterOp, HolovizOp
        from holoscan.resources import BlockMemoryPool, MemoryStorageType
        want_png = c.png_every > 0
        kw = {}
        if want_png:
            kw = dict(enable_render_buffer_output=True,
                      allocator=BlockMemoryPool(self, name="hv_pool", storage_type=MemoryStorageType.DEVICE,
                                                block_size=W * H * 4, num_blocks=4))
        ui = self.ui
        btn = {"LEFT": "L", "RIGHT": "R", "MIDDLE": "M"}

        def on_key(key, action, mods):
            if action == HolovizOp.KeyAndButtonAction.PRESS:
                ui.on_key(key.name)

        def on_button(button, action, mods):
            if action in (HolovizOp.KeyAndButtonAction.PRESS, HolovizOp.KeyAndButtonAction.RELEASE):
                ui.on_button(btn.get(button.name, "L"), action == HolovizOp.KeyAndButtonAction.PRESS)

        if not c.headless:
            kw.update(key_callback=on_key, mouse_button_callback=on_button,
                      cursor_pos_callback=lambda x, y: ui.on_cursor(x, y),
                      scroll_callback=lambda x, y: ui.on_scroll(x, y),
                      window_size_callback=lambda w, h: ui.on_window_size(w, h),
                      window_close_callback=lambda: self.quit("window closed"))
        hv = HolovizOp(self, name="holoviz", headless=c.headless, width=W, height=H,
                       fullscreen=not (c.headless or c.windowed), vsync=not c.headless,
                       window_title="qsfp28-fmc-rocelet beamforming demo",
                       tensors=[dict(name="canvas", type="color")], **kw)
        hv.metadata_policy = MetadataPolicy.UPDATE
        relay = VizRelayOp(self, name="viz_relay", bstats=self.bs, lat=self.lat)
        self.add_flow(beam, relay, {("output", "input")})
        self.add_flow(relay, hv, {("output", "receivers"), ("output_specs", "input_specs")})
        if want_png:
            fc = FormatConverterOp(self, name="to_rgb", in_dtype="rgba8888", out_dtype="rgb888", out_tensor_name="frame",
                                   pool=BlockMemoryPool(self, name="fc_pool", storage_type=MemoryStorageType.DEVICE,
                                                        block_size=W * H * 4, num_blocks=4))
            png = rh.PngSinkOp(self, name="png", cfg=c, stats=self.stats)
            self.add_flow(hv, fc, {("render_buffer_output", "source_video")})
            self.add_flow(fc, png, {("tensor", "input")})


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="qsfp28-fmc-rocelet beamforming demo (8 x 8 array, GPU beamformer, Holoviz)")
    ap.add_argument("--source", choices=["roce", "synthetic", "csynthetic"], default="roce")
    ap.add_argument("--preset", type=int, choices=bs.PRESETS, default=2, help="scene at start (keys 1-5)")
    ap.add_argument("--beamformer", choices=["conv", "mvdr"], default="conv")
    ap.add_argument("--fps", type=float, default=60.0, help="frames beamformed + shown per second (the others drop)")
    ap.add_argument("--synth-fps", type=float, default=None,
                    help="synthetic frame rate (default 10 for synthetic: numpy model; 120 for csynthetic; 0 = unpaced)")
    ap.add_argument("--update-hz", type=float, default=20.0, help="max scene writes per second (input is coalesced)")
    ap.add_argument("--attract-idle", type=float, default=10.0, help="s without input before attract mode (0 = never)")
    ap.add_argument("--grid", type=int, default=128, help="sky grid G (contract: 128)")
    ap.add_argument("--loading", type=float, default=1e-3, help="MVDR diagonal loading x trace(R) / N")
    ap.add_argument("--mvdr-top-db", type=float, default=-10.0,
                    help="MVDR display: dB re the mean element power shown white (the scale spans 30 dB below it)")
    ap.add_argument("--spec-avg", type=float, default=0.6,
                    help="spectrum display smoothing: S = (1 - a) S_frame + a S_previous (0 = off; display only)")
    ap.add_argument("--script", default="", help="timed events 't cmd args; ...' (or @file), t from the first frame shown")
    ap.add_argument("--frames", type=int, default=0)
    ap.add_argument("--duration", type=float, default=0)
    ap.add_argument("--viz", choices=["holoviz", "none"], default="holoviz")
    ap.add_argument("--headless", action="store_true")
    ap.add_argument("--windowed", action="store_true", help="a 1920 x 1080 window instead of fullscreen")
    ap.add_argument("--png-every", type=int, default=None, help="PNG every N shown frames (default 60 headless, else 0)")
    ap.add_argument("--verify", type=float, default=0.0,
                    help="compare received frames word for word with the bit-exact CUDA generator: up to N frames per "
                         "second (-1 = every frame the app can take; 0 = off); any mismatch fails the run")
    ap.add_argument("--min-peak-ok", type=float, default=0.0,
                    help="verdict: fraction of shown frames whose sky peak lies on a true source (0 = not checked)")
    ap.add_argument("--web", type=int, default=8090, metavar="PORT",
                    help="tablet / phone page on this HTTP port (beam_web.py; 0 = off)")
    ap.add_argument("--web-bind", default="0.0.0.0", help="address of the web page (no authentication: a booth LAN)")
    ap.add_argument("--web-hz", type=float, default=10.0, help="sky-map updates per second to the web page")
    ap.add_argument("--outdir", default=".")
    ap.add_argument("--tag", default=None)
    ap.add_argument("--json", default=None)
    # board (as rocelet_hsb_app.py)
    ap.add_argument("--ip", default="192.168.20.2")
    ap.add_argument("--api", choices=["classic", "module"], default="classic")
    ap.add_argument("--module-dir", default=None)
    ap.add_argument("--reg-mode", choices=["block", "single"], default="block",
                    help="BM register writes: one ECB WR_BLOCK per scene change (own socket; the Hololink object then "
                         "runs without sequence checking) or one write_uint32 per word")
    ap.add_argument("--force", action="store_true", help="run even if S_BM_CAPS does not report the array generator")
    ap.add_argument("--rate", type=float, default=64.0,
                    help="board RATE_MBPS in Gb/s (frame + record) at the start; keys - / + and the page change it "
                         f"while the stream runs ({ui_mod.RATE_MIN_GBPS:g}-{ui_mod.RATE_MAX_GBPS:g} Gb/s)")
    ap.add_argument("--mtu", type=int, default=4200)
    ap.add_argument("--pages", type=int, default=64)
    ap.add_argument("--queue-size", type=int, default=None)
    ap.add_argument("--ibv-name", default="rocep179s0f0")
    ap.add_argument("--ibv-port", type=int, default=1)
    ap.add_argument("--keepalive", type=int, default=2000)
    ap.add_argument("--start-gate", choices=["on", "off"], default="on")
    ap.add_argument("--start-delay", type=float, default=0.0)
    ap.add_argument("--frame-ready", choices=["auto", "blocking", "async"], default="auto")
    ap.add_argument("--threads", type=int, default=-1)
    a = ap.parse_args(argv)
    if a.script.startswith("@"):
        a.script = open(a.script[1:]).read()
    if a.synth_fps is None:
        a.synth_fps = 10.0 if a.source == "synthetic" else 120.0
    if a.png_every is None:
        a.png_every = 60 if a.headless else 0
    if a.queue_size is None:
        # 2, not pages / 2: the receiver queues completed frames for the app, and the app must see the NEWEST frame
        # (a deep queue made every frame it looked at 32 frames old: +28 ms on every latency at 10 Gb/s, B5)
        a.queue_size = 2
    a.start_gate = a.start_gate == "on"
    if a.frame_ready == "auto":
        a.frame_ready = "async" if (a.source == "roce" and a.api == "module") else "blocking"
    if a.threads < 0:
        # greedy scheduler (one thread) by default: with the event-based scheduler (3 threads, async frame-ready)
        # the beamformer got only ~26 frames/s on the board (B5, 2026-11-03), the greedy loop 40-60
        a.threads = 2 if a.frame_ready == "async" else 0
    # fields rocelet_hsb_app's CheckerOp / PngSinkOp read
    a.frame_size, a.check, a.check_every, a.scene, a.checker = FRAME_SIZE, "none", 1, 1, "py"
    a.resync_window, a.stats_interval, a.data = 4096, 1.0, "beam"
    a.tag = a.tag or f"beam_{a.source}_p{a.preset}_{time.strftime('%Y%m%d_%H%M%S')}"
    a.json = a.json or os.path.join(a.outdir, a.tag + ".json")
    return a


def beam_line(b, st):
    g = list(b.gpu_ms)
    return (f"beam: shown {b.processed} of {b.rx} | GPU {pct(g, 50)} ms p50 {pct(g, 99)} p99 | host "
            f"{pct(list(b.host_ms), 50)} ms | data->pixel {pct(list(b.d2p_ms), 50)} ms | mouse->data "
            f"{pct(list(b.m2d_ms), 50)} ms ({len(b.m2d_ms)}) app {pct(list(b.m2a_ms), 50)} pixel {pct(list(b.m2p_ms), 50)} | "
            f"board frames {pct(list(b.board_frames), 50)} | peak on source {b.peak_ok}/{b.peak_n} | scenes "
            f"{b.scene_changes} ({b.writes} words, {b.write_errors} failed)" +
            (f" | verify {b.v_frames} frames, {b.v_bad_frames} bad ({b.v_bad_words} words), skipped {b.v_skipped}, "
             f"overrun {b.v_overrun}, fidx {b.v_fidx_bad}" if b.v_frames or b.v_skipped or b.v_overrun else ""))


def main(argv=None):
    c = parse_args(argv)
    # the control thread (scene writes, attract, script) must not wait the default 5 ms for the GIL that the
    # Holoscan operators hold: input-to-APPLY is part of mouse-to-data
    sys.setswitchinterval(0.0005)
    os.makedirs(c.outdir, exist_ok=True)
    logging.basicConfig(level=logging.INFO)
    stats, bstats = rh.Stats(), BeamStats()
    lat = Latency(bstats)
    history = {0: bs.reset_scene()}
    stop_reason = []
    hl = dc = ka = None
    hsb = None
    board0 = board1 = {}
    app_ref = []

    def request_stop(reason):
        if not stop_reason:
            stop_reason.append(reason)
            print(f"stopping: {reason}", flush=True)
            if hl is not None:
                try:
                    import rocelet_hsb
                    rocelet_hsb.stop_data_plane(hl)
                except Exception as e:
                    print(f"could not stop the data plane yet: {e}", flush=True)
        if app_ref:
            try:
                if app_ref[0].run_cond is not None:
                    app_ref[0].run_cond.disable_tick()
                app_ref[0].stop_execution()
            except Exception as e:
                print(f"stop_execution: {e}", flush=True)

    ui = ui_mod.Ui(c, request_stop)
    if c.source == "roce":
        import cuda.bindings.driver as cuda   # noqa: F401
        import holoscan.core                   # noqa: F401
        import rocelet_hsb
        try:
            if c.api == "module":
                md, hl = rocelet_hsb.connect_module(c.ip, c.mtu, c.module_dir, deferred_start=c.start_gate)
            else:
                dc, hl = br.connect_classic(c.ip, c.mtu, deferred_start=c.start_gate,
                                            sequence_check=(c.reg_mode != "block"))
        except RuntimeError as e:
            print(f"{e}: is the board on with 'hsb on', the container run with --net host?", flush=True)
            return 2
        regs = br.BoardRegs(c.ip, hl, mode=c.reg_mode)
        try:
            hl.reset()
            print(f"HSB IP version 0x{hl.get_hsb_ip_version():04x}, FPGA date 0x{hl.get_fpga_date():08x}", flush=True)
            caps = regs.caps()
            print(f"S_BM_CAPS = {('0x%08x' % caps) if caps is not None else 'not mapped (firmware without BM registers)'}",
                  flush=True)
            if caps != bs.CAPS_VALUE and not c.force:
                raise RuntimeError(f"the board does not report the 8 x 8 array generator (S_BM_CAPS "
                                   f"{caps if caps is None else hex(caps)}, expected 0x{bs.CAPS_VALUE:08x}); --force runs anyway")
            regs.write_block([(bs.OPS_SOURCE, bs.SOURCE_BEAM), (bs.OPS_RATE_MBPS, int(round(c.rate * 1000)))])
            if c.keepalive:
                rocelet_hsb.set_keepalive(hl, c.keepalive)
                ka = rocelet_hsb.KeepAlive(hl, c.keepalive).start()
            board0 = rocelet_hsb.board_counters(hl)
            hsb = (md if c.api == "module" else dc, rocelet_hsb.primary_context())
        except Exception as e:
            print(f"board set-up failed: {e}", flush=True)
            try:
                rocelet_hsb.stop_data_plane(hl)
            except Exception:
                pass
            if ka:
                ka.stop()
            regs.close()
            hl.stop()
            return 2
    else:
        regs = br.SimRegs()

    control = Control(c, ui, regs, lat, history, bstats)
    control.send_pending(initial=True)          # the start scene, APPLY while the generator is idle: active from frame 0
    web = None
    if c.web:
        try:
            web = beam_web.BeamWeb(c.web, ui, bind=c.web_bind, hello=dict(
                app="rocelet_beam_app.py", source=c.source, rate_gbps=c.rate if c.source == "roce" else None,
                grid=WEB_G, loading=c.loading, presets=list(bs.PRESETS),
                emitters=list(ui_mod.EMITTERS), jammers=list(ui_mod.JAMMERS))).start()
        except OSError as e:
            print(f"web page off: port {c.web}: {e}", flush=True)
            web = None
    app = BeamApp(c, stats, bstats, ui, lat, history, regs, hsb, web)
    app_ref.append(app)
    app.stopping = lambda: bool(stop_reason)
    app.quit = request_stop
    if c.source == "roce":
        import rocelet_hsb
        app.gate_enable = lambda: rocelet_hsb.start_data_plane(hl)
    err = []

    def run():
        try:
            app.run()
        except Exception as e:
            err.append(e)

    old = {s: signal.signal(s, lambda n, f: request_stop(signal.Signals(n).name)) for s in (signal.SIGINT, signal.SIGTERM)}
    th = threading.Thread(target=run, name="holoscan", daemon=True)
    t_start = time.time()
    stats.t_run = t_start
    t_line = time.time()
    control.start()
    try:
        th.start()
        while th.is_alive():
            th.join(timeout=0.2)
            if time.time() - t_line >= 1.0 and bstats.rx:
                t_line = time.time()
                print(beam_line(bstats, stats), flush=True)
            if bstats.lost_start is None and stats.t_first_frame and time.time() - stats.t_first_frame >= START_WINDOW:
                bstats.lost_start = max(stats.lost, 0)
                if bstats.lost_start:
                    print(f"{bstats.lost_start} frames lost in the first {START_WINDOW:g} s of the stream (reported apart)",
                          flush=True)
            if c.duration and time.time() - t_start >= c.duration and not stop_reason:
                request_stop(f"--duration {c.duration:g} s")
    finally:
        control.stop()
        if web is not None:
            web.stop()
        for s, h in old.items():
            signal.signal(s, h)
        bm_status = None
        try:
            bm_status = regs.status()
        except Exception as e:
            bm_status = dict(error=str(e))
        if hl is not None:
            import rocelet_hsb
            try:
                rocelet_hsb.stop_data_plane(hl)
                print("data plane off (DP_VP_MASK 0)", flush=True)
            except Exception as e:
                print(f"could not stop the data plane: {e} ('hsb off' on the console stops it)", flush=True)
            if ka:
                ka.stop()
            board1 = rocelet_hsb.board_counters(hl)
            try:
                hl.stop()
            except Exception:
                pass
        regs.close()
    wall = time.time() - t_start
    b = bstats
    print(beam_line(b, stats), flush=True)
    bad = []
    if err:
        bad.append(f"application error: {err[0]}")
    if b.exceptions:
        bad.append(f"{len(b.exceptions)} exceptions in the beamformer")
    if b.processed == 0:
        bad.append("no frame shown")
    for k, v in (("lost", b.lost_steady(stats)), ("psn mismatch", stats.psn_bad), ("psn sequence", stats.psn_seq_bad),
                 ("bytes_written", stats.bw_bad), ("frame number backwards", stats.fn_back), ("beam tag", b.tag_bad),
                 ("register writes failed", b.write_errors), ("verify: frames with mismatches", b.v_bad_frames),
                 ("verify: frame_index != frame_number", b.v_fidx_bad)):
        if v:
            bad.append(f"{k} {v}")
    peak_frac = b.peak_ok / b.peak_n if b.peak_n else 0.0
    if c.verify and b.v_frames == 0:
        bad.append("verify: no frame compared")
    if c.min_peak_ok > 0 and peak_frac < c.min_peak_ok:
        bad.append(f"sky peak on a true source in {peak_frac:.1%} of the frames (< {c.min_peak_ok:.0%})")
    g = list(b.gpu_ms)
    s = dict(app="rocelet_beam_app.py", time=datetime.datetime.now().isoformat(timespec="seconds"),
             args={k: v for k, v in vars(c).items() if not k.startswith("_")}, wall_s=round(wall, 2),
             frames_received=b.rx, frames_shown=b.processed, received_per_s=round(b.rx / wall, 1) if wall else 0,
             shown_per_s=round(b.processed / (time.monotonic() - b.t_first), 1) if b.t_first else 0,
             gpu_ms=dict(mean=round(float(np.mean(g)), 3) if g else None, p50=pct(g, 50), p99=pct(g, 99)),
             host_ms=dict(p50=pct(list(b.host_ms), 50), p99=pct(list(b.host_ms), 99)),
             data_to_pixel_ms=dict(p50=pct(list(b.d2p_ms), 50), p99=pct(list(b.d2p_ms), 99)),
             mouse_to_data_ms=dict(n=len(b.m2d_ms), p50=pct(list(b.m2d_ms), 50), p99=pct(list(b.m2d_ms), 99)),
             mouse_to_pixel_ms=dict(p50=pct(list(b.m2p_ms), 50), p99=pct(list(b.m2p_ms), 99)),
             mouse_to_app_ms=dict(p50=pct(list(b.m2a_ms), 50), p99=pct(list(b.m2a_ms), 99)),
             new_scene_frames_skipped=dict(p50=pct(list(b.skip_frames), 50), max=max(b.skip_frames) if b.skip_frames else None),
             receiver_to_app_ms=dict(p50=pct(list(b.recv_age_ms), 50), p99=pct(list(b.recv_age_ms), 99)),
             input_to_apply_ms=dict(p50=pct(list(b.apply_ms), 50), p99=pct(list(b.apply_ms), 99)),
             board_frames_to_activation=dict(p50=pct(list(b.board_frames), 50), max=max(b.board_frames) if b.board_frames else None),
             scene_changes=b.scene_changes, register_words=b.writes, register_write_errors=b.write_errors,
             rate_changes=b.rate_changes, rate_gbps_end=ui.rate_gbps,
             peak_on_source=dict(ok=b.peak_ok, n=b.peak_n, fraction=round(peak_frac, 4)),
             tag_bad=b.tag_bad, unknown_scene=b.unknown_scene, calibrations=b.cal,
             verify=dict(frames=b.v_frames, bad_frames=b.v_bad_frames, bad_words=b.v_bad_words, skipped=b.v_skipped,
                         overrun=b.v_overrun, frame_index_bad=b.v_fidx_bad, words_compared=b.v_frames * FRAME_SIZE // 4,
                         dumps=b.v_dumps) if c.verify else None,
             accounting=dict(rx=stats.rx, lost=stats.lost, lost_start=b.lost_start, lost_steady=b.lost_steady(stats), consumer_dropped=stats.consumer_dropped, psn_bad=stats.psn_bad,
                             psn_seq_bad=stats.psn_seq_bad, bw_bad=stats.bw_bad),
             exceptions=b.exceptions, bm_status=bm_status, board=dict(before=board0, after=board1) if hl else None,
             pngs=stats.pngs, png_t=[round(t - b.t_first, 4) for t in stats.png_t] if b.t_first else [],   # s from the first frame shown (the --script clock)
             stop=stop_reason[0] if stop_reason else "frames done",
             web=web.summary() if web is not None else None,
             verdict="FAIL" if bad else "PASS", reason="; ".join(bad))
    with open(c.json, "w") as f:
        json.dump(s, f, indent=1, default=str)
    print(f"summary {c.json}")
    v = (f"{s['verdict']}: {b.processed} frames shown of {b.rx} received in {wall:.1f} s, "
         f"{len(b.exceptions)} exceptions, GPU {pct(g, 50)} ms/frame p50, peak on source {peak_frac:.1%}, "
         f"mouse->data p50 {pct(list(b.m2d_ms), 50)} ms" + (f" | {s['reason']}" if bad else ""))
    print(v, flush=True)
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
