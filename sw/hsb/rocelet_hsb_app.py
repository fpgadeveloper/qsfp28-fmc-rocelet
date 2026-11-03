#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# rocelet_hsb_app.py - Holoscan application for the qsfp28-fmc-rocelet design's Holoscan Sensor
# Bridge (HSB) device mode: frames arrive through HSB's RoceReceiverOp (a UC QP on a ConnectX
# NIC, frames written straight into GPU memory), a CUDA checker verifies every frame it gets
# (counter pattern word by word, or the IQ16 test signal sample by sample against its
# bit-exact model; metadata PSN, PSN sequence, bytes_written, frame accounting), and in demo
# mode a cuFFT spectrogram shows the IQ16 signal as a waterfall in Holoviz.
#
#   --mode check   checker only, headless; a stats line every second, a JSON summary at the end
#   --mode demo    checker + spectrogram (4096-point FFT rows, 30 rows/s) + Holoviz window,
#                  or --headless with PNG snapshots (--png-every N rows)
#   --source roce       the board (KCU116 + OP120, console 'hsb on'), container --net host
#                       --privileged; needs a ConnectX NIC (RDMA) and a GPU
#   --source synthetic  no board, no NIC: a generator operator writes frames in the same page
#                       ring layout (frame + 128-byte HSB metadata record) into GPU memory and
#                       emits them with the same metadata as RoceReceiverOp (Python; fault injection)
#   --source csynthetic the C++ synthetic source (cpp/): a producer thread fills the ring like the
#                       board + NIC, an asynchronous condition wakes the operator like
#                       RoceReceiverOp; --rate > 0 runs the board's timeline with HSB's receive
#                       queue (drops when the application is slow), --rate 0 measures the ceiling
#   --checker cpp|py    the C++ checker operator (cpp/, default when built) or the Python one
#   --api classic|module  HSB's classic hololink API, or the module API (hololink_module) with
#                       the Opsero module (module/; HOLOLINK_MODULE_DIR or --module-dir)
#
# The board's data plane starts only when the graph is up (--start-gate, default on): the
# receiver configures it with DP_VP_MASK left clear, an operator enables it after every operator
# has started (+ --start-delay). --keepalive (default 2000 ms) arms the board's producer watchdog
# and refreshes it from a thread: a killed or hung application stops the board within that time.
#
# Runs inside NVIDIA's HSB container (hololink-demo:3.0.0: Holoscan 4.4, CuPy, hololink).
# See README.md in this directory ("Holoscan application").
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import argparse
import ctypes
import datetime
import json
import logging
import glob
import math
import os
import resource
import signal
import sys
import threading
import time

import cupy as cp
import numpy as np
from holoscan.conditions import BooleanCondition, CountCondition, PeriodicCondition
from holoscan.core import Application, ConditionType, MetadataPolicy, Operator
from holoscan.schedulers import EventBasedScheduler, GreedyScheduler

import rocelet_iq

HERE = os.path.dirname(os.path.abspath(__file__))
METADATA_SIZE = 128          # hololink.METADATA_SIZE
PAGE_ALIGN = 128             # hololink.PAGE_SIZE: the record follows the frame at this alignment
RES_SLOTS = 16384            # checker result slots between two harvests
SLOT_WORDS = 8               # [0] error words [1] overrun words [2] first error [3] psn [4] fn [5] bytes [6] flags [7] fn after
GBIT = 1e9


def round_up(x, a):
    return (x + a - 1) // a * a


def pmtu_of(mtu):
    """Payload bytes per packet: the HSB host programs DP_PACKET_SIZE = (mtu - 74) // 128
    (x 128 bytes); the rocelet firmware rounds that down to a power of two, 256..4096."""
    b = max((mtu - 74) // 128 * 128, 256)
    return min(1 << (b.bit_length() - 1), 4096)


def packets_per_frame(frame_size, mtu):
    return -(-frame_size // pmtu_of(mtu)) + 1          # data packets + the metadata WRITE-with-imm


class Kernels:
    """The CUDA kernels of rocelet_hsb_kernels.cu, compiled once per process (NVRTC)."""
    _mod = None

    @classmethod
    def get(cls, name):
        if cls._mod is None:
            src = open(os.path.join(HERE, "rocelet_hsb_kernels.cu")).read()
            cls._mod = cp.RawModule(code=src, options=("--std=c++17",))
        return cls._mod.get_function(name)


class FastKernel:
    """A kernel of rocelet_hsb_kernels.cu launched with cuLaunchKernel through ctypes, with
    argument storage built once. Inside a Holoscan operator a CuPy kernel call costs ~20 us
    (measured on the test host: 21 us vs 3.9 us in plain Python); this costs ~6 us, which is
    what lets one Python operator check ~10k frames/s. Launches go to the legacy default
    stream, like CuPy's default, so they stay ordered with the CuPy work of the application."""
    _cu = None
    _ctx = ctypes.c_void_p()
    _cur = ctypes.c_void_p()

    def __init__(self, name, types):
        if FastKernel._cu is None:
            cu = ctypes.CDLL("libcuda.so.1")
            cu.cuLaunchKernel.argtypes = [ctypes.c_void_p] + [ctypes.c_uint] * 7 + [
                ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p]
            cp.cuda.Device(0).use()
            if cu.cuDevicePrimaryCtxRetain(ctypes.byref(FastKernel._ctx), 0) != 0:
                raise RuntimeError("cuDevicePrimaryCtxRetain failed")
            FastKernel._cu = cu
        self.f = ctypes.c_void_p(Kernels.get(name).kernel.ptr)
        self.vals = [t() for t in types]
        self.params = (ctypes.c_void_p * len(types))(*[ctypes.cast(ctypes.pointer(v), ctypes.c_void_p)
                                                         for v in self.vals])
        self.name = name

    def __call__(self, grid, block, *args):
        for v, a in zip(self.vals, args):
            v.value = a
        cu = FastKernel._cu
        cu.cuCtxGetCurrent(ctypes.byref(FastKernel._cur))
        if FastKernel._cur.value != FastKernel._ctx.value:
            cu.cuCtxSetCurrent(FastKernel._ctx)
        g = grid if isinstance(grid, tuple) else (grid,)
        g = g + (1,) * (3 - len(g))
        r = cu.cuLaunchKernel(self.f, g[0], g[1], g[2], block, 1, 1, 0, None, self.params, None)
        if r != 0:
            raise RuntimeError(f"cuLaunchKernel({self.name}) = CUresult {r}")


U8, U32, I32 = ctypes.c_uint64, ctypes.c_uint32, ctypes.c_int32
CHK_ARGS = [I32, U8, U8, U32, U8, U8, U8, U8, U8]        # mode frame n fn16 n_first later_step cfg rec res


def iq_cfg(scene):
    """The kernels' IQ16 configuration array (int64[142]) of a scene."""
    c = rocelet_iq.SCENES[scene]
    v = list(c["inc"]) + list(c["amp"]) + [c["cstart"], c["rate"], c["per"], c["camp"], c["namp"], c["seed"]]
    v += [int(x) for x in rocelet_iq.plan(scene).reshape(-1)]
    return cp.asarray(np.array(v, dtype=np.int64))


def u64(x):
    return np.uint64(x)


def iq_cfg_list(scene):
    """The IQ16 configuration of a scene as a list of 142 ints (for the C++ operators)."""
    c = rocelet_iq.SCENES[scene]
    v = list(c["inc"]) + list(c["amp"]) + [c["cstart"], c["rate"], c["per"], c["camp"], c["namp"], c["seed"]]
    return [int(x) for x in v] + [int(x) for x in rocelet_iq.plan(scene).reshape(-1)]


_cpp_ops = None


def cpp_ops(c=None):
    """The C++ operator module rocelet_hsb_ops (cpp/build.sh), from --cpp-dir / $ROCELET_CPP_DIR /
    cpp/build next to this file; None if it is not built."""
    global _cpp_ops
    if _cpp_ops is None:
        dirs = [d for d in (getattr(c, "cpp_dir", None), os.environ.get("ROCELET_CPP_DIR"),
                            os.path.join(HERE, "cpp", "build")) if d]
        for d in dirs:
            if glob.glob(os.path.join(d, "rocelet_hsb_ops*.so")):
                sys.path.insert(0, os.path.abspath(d))
                break
        try:
            import holoscan.core  # noqa: F401  (the operator base classes first)
            import rocelet_hsb_ops
            _cpp_ops = rocelet_hsb_ops
        except ImportError:
            _cpp_ops = False
    return _cpp_ops or None


def grid(n, block=256, cap=4096):
    return (min(max(-(-n // block), 1), cap),)


def blocks(n, block=256, cap=4096):
    return min(max(-(-n // block), 1), cap)


class Stats:
    """Counters shared by the operators (one Python process, GIL-protected)."""

    def __init__(self):
        self.t0 = None
        self.rx = 0                  # frames delivered to the application
        self.rx_bytes = 0
        self.checked = 0             # frames whose data went through a check kernel
        self.gaps = 0                # frame numbers skipped (consumer drops + network losses)
        self.consumer_dropped = 0    # frames the receiver took but did not hand to the application (busy)
        self.hsb_dropped = 0         # HSB metadata "dropped" delta (stamped on the NEWEST frame: up to
                                     # queue-size - 1 ahead of the gaps; informative only)
        self.first_rfn = None        # receiver CQE count (received_frame_number) at the first / last frame
        self.last_rfn = None
        self.fn_back = 0             # frame number not increasing
        self.err_frames = 0
        self.err_words = 0
        self.ovr_frames = 0          # page reused by the board before / while the checker read it
        self.ovr_words = 0
        self.psn_bad = 0             # record PSN != immediate PSN
        self.psn_seq_bad = 0         # record PSN not advancing by packets-per-frame x frame-number step
        self.bw_bad = 0              # bytes_written != frame size
        self.harvested = 0
        self.first_fn = None
        self.last_fn = None
        self.fn_span_replay = 0
        self.check_us = []           # host time per checker compute (sampled)
        self.source_us = []          # host time per synthetic-source compute (sampled)
        self.gpu_us = []             # GPU time of the check kernels per frame (sampled)
        self.injected = dict(corrupt=0, drop=0, psn=0, overrun=0, restart=0, restart_lost=0)
        self.spectro_rows = 0
        self.spectro_frames = 0
        self.spectro_us = []
        self.pngs = []
        self.png_t = []              # time.monotonic() of each PNG's frame
        self.errors_shown = 0
        self.resyncs = 0             # producer restarts (frame number back to 0 after a link pause)
        self.resync_lost = 0         # frames the board sent but the receiver never completed across them
        self.lost_closed = 0         # lost in the segments before the last resync
        self.seg_first_fn = None     # first frame number / receiver count of the current segment
        self.seg_first_rfn = None
        self.have_rfn = True         # the receiver stamps received_frame_number (not the module API's)
        self.cpp_lost = None         # the C++ checker's lost / consumer-dropped (synced)
        self.cpp_host_us = []
        self.cpp_gpu_us = []
        self.t_run = None            # app.run() called
        self.t_graph_up = None       # every operator started (start gate)
        self.t_dp_enable = None      # board / synthetic data plane enabled
        self.t_first_frame = None    # first frame at the checker

    @property
    def lost(self):
        """Frames the board numbered that never completed at the receiver (network loss): the frame
        number span minus the receiver's CQE-count span, both stamped when the frame arrived. HSB's
        "dropped" counter cannot be used for this: RoceReceiver stamps it on the newly arriving frame
        when it recycles the OLDEST ready one, so it runs up to queue-size - 1 ahead of the frame
        number gaps (a constant -7 with --queue-size 8 from the pre-attach backlog)."""
        if self.cpp_lost is not None:
            return self.cpp_lost
        if not self.have_rfn:
            return -1                                  # unknown (no receiver completion count)
        if self.seg_first_rfn is None or self.last_fn is None or self.seg_first_fn is None:
            return 0
        return (self.lost_closed + (self.last_fn - self.seg_first_fn) - (self.last_rfn - self.seg_first_rfn)
                - self.fn_span_replay)

    def sync_cpp(self, d):
        """Copy a C++ CheckerOp.stats() snapshot into this object (main thread, a few times a second)."""
        for k in ("rx", "rx_bytes", "checked", "gaps", "hsb_dropped", "first_fn", "last_fn", "first_rfn", "last_rfn",
                  "fn_back", "fn_span_replay", "resyncs", "resync_lost", "err_frames", "err_words", "ovr_frames",
                  "ovr_words", "psn_bad", "psn_seq_bad", "bw_bad", "harvested", "have_rfn"):
            setattr(self, k, d[k])
        if d["t0"] and self.t0 is None:
            self.t0 = d["t0"]
            self.t_first_frame = d["t0"]
        self.cpp_lost = d["lost"]
        self.consumer_dropped = d["consumer_dropped"]
        self.cpp_host_us, self.cpp_gpu_us = d["host_us"], d["gpu_us"]

    def elapsed(self):
        return time.time() - self.t0 if self.t0 else 0.0

    def line(self, frame_size):
        dt = self.elapsed()
        fps = self.rx / dt if dt > 0 else 0
        gbps = self.rx_bytes * 8 / dt / GBIT if dt > 0 else 0
        cov = 100.0 * self.checked / self.rx if self.rx else 0
        lost = self.lost
        acct = (f"consumer-dropped {self.consumer_dropped} lost {lost}" if lost >= 0
                else f"gaps {self.gaps} (lost + consumer-dropped)")
        rs = f" | resync {self.resyncs} (lost {self.resync_lost})" if self.resyncs else ""
        return (f"t {dt:6.1f} s | rx {self.rx} frames {fps:8.1f}/s {gbps:6.2f} Gb/s | checked {self.checked} ({cov:.0f} %) "
                f"| {acct} | errors {self.err_frames} frames "
                f"{self.err_words} words | overrun {self.ovr_frames} | psn {self.psn_bad}/{self.psn_seq_bad} "
                f"bytes {self.bw_bad}{rs}")


# ------------------------------------------------------------------------------------------
# Source: synthetic frames in the HSB page-ring layout
# ------------------------------------------------------------------------------------------
class SyntheticFrameOp(Operator):
    """Writes frames into a GPU page ring like the board does over RoCE (page p = frame number
    mod pages: frame bytes, then the 128-byte big-endian HSB metadata record at roundup(frame,
    128)) and emits each one as RoceReceiverOp does: a uint8 tensor named "" and the metadata
    frame_number (extended), imm_data (PSN << 12 | page), page_number, frame_memory, dropped,
    bytes_written, received_frame_number, timestamps. Data: counter pattern, the IQ16 model
    (scene, continuous across frames like the board) or a saved frame (--synthetic-file,
    replayed with its own frame number). Fault injection: --corrupt-every, --drop-every,
    --psn-bad-every, --overrun-every, --restart-every (the board's link-pause resume: frame
    number, page and IQ16 sample count restart at 0, --restart-lost frames lost, PSN kept; the
    frame number in the metadata is extended over 16 bits as HSB's receiver does).
    It only produces when ticked (after every operator started), so the start gate does not hold it."""

    def __init__(self, fragment, *args, cfg, stats, **kwargs):
        self.c = cfg
        self.stats = stats
        super().__init__(fragment, *args, **kwargs)

    def setup(self, spec):
        spec.output("output")

    def start(self):
        c = self.c
        self.fs = c.frame_size
        self.md_off = round_up(self.fs, PAGE_ALIGN)
        self.ps = self.md_off + METADATA_SIZE
        self.ring = cp.zeros(self.c.pages * self.ps, dtype=cp.uint8)
        self.base = self.ring.data.ptr
        self.ppf = packets_per_frame(self.fs, c.mtu)
        self.bfn = 0                 # the board's frame number (restarts at 0 on --restart-every)
        self.k = 0                   # frames the board sent (PSN), incl. lost ones
        self.ext = None              # extended frame number (HSB receiver)
        self.sent = 0
        self.restarted_at = 0
        self.enabled = True          # ticks only once the graph runs: the start gate has nothing to hold back
        self.cpp = c.checker == "cpp"     # metadata as C++ values for the C++ checker
        self.k_cnt = FastKernel("gen_counter", [U8, U8, U32])
        self.k_iq = FastKernel("gen_iq", [U8, U8, U8, U8])
        self.k_rec = FastKernel("wr_record", [U8, U32, U32, U8, U8, U32, U8, U32])
        self.k_flip = FastKernel("flip_bit", [U8, U8, U32])
        self.cfg = iq_cfg(c.scene) if c.data == "iq" else None
        self.file = None
        if c.data == "file":
            raw = np.fromfile(c.synthetic_file, dtype=np.uint8)
            if len(raw) != self.fs:
                raise ValueError(f"{c.synthetic_file}: {len(raw)} B, --frame-size is {self.fs}")
            self.file = cp.asarray(raw)
        self.rng = np.random.default_rng(1)
        self.t_start = time.time()
        print(f"synthetic data plane on: {c.data} frames of {self.fs} B, {c.pages} pages, "
              f"{self.ppf} packets per frame (PMTU {pmtu_of(c.mtu)})", flush=True)

    def stop(self):
        print(f"synthetic data plane off after {self.sent} frames", flush=True)

    def enable(self):
        self.enabled = True

    def compute(self, op_input, op_output, context):
        if not self.enabled:
            return
        t_in = time.perf_counter()
        c, st = self.c, self.stats
        if c.restart_every and self.sent and self.sent % c.restart_every == 0 and self.restarted_at != self.sent:
            self.restarted_at = self.sent                 # link pause: frames in flight lost, restart at 0
            self.k += c.restart_lost
            self.bfn = 0
            st.injected["restart"] += 1
            st.injected["restart_lost"] += c.restart_lost
        if c.drop_every and (self.k + 1) % c.drop_every == 0:
            self.k += 1                                   # this frame "is lost on the network"
            self.bfn += 1
            st.injected["drop"] += 1
        fn, k = self.bfn, self.k
        self.bfn, self.k = fn + 1, k + 1
        rfn = fn if c.data != "file" else c.file_frame_number
        f16 = rfn & 0xFFFF
        self.ext = f16 if self.ext is None else self.ext + ((f16 - self.ext) & 0xFFFF)
        page = fn % c.pages
        ptr = self.base + page * self.ps
        if c.data == "counter":
            w = self.fs // 8
            self.k_cnt(blocks(w, cap=1024), 256, ptr, w, rfn & 0xFFFF)
        elif c.data == "iq":
            s = self.fs // 4
            self.k_iq(blocks(s, cap=2048), 256, ptr, s, rfn * iq_stride(self.fs), self.cfg.data.ptr)
        else:
            self.ring[page * self.ps:page * self.ps + self.fs] = self.file
        if c.overrun_every and c.data != "file" and (self.sent + 1) % c.overrun_every == 0:
            # the board already reused this page: its first half holds frame fn + pages
            later = rfn + c.pages
            if c.data == "counter":
                self.k_cnt(blocks(self.fs // 16, cap=1024), 256, ptr, self.fs // 16, later & 0xFFFF)
            else:
                self.k_iq(blocks(self.fs // 8, cap=2048), 256, ptr, self.fs // 8, later * iq_stride(self.fs),
                          self.cfg.data.ptr)
            st.injected["overrun"] += 1
        if c.corrupt_every and (self.sent + 1) % c.corrupt_every == 0:
            off = int(self.rng.integers(0, self.fs // 8)) * 8 + int(self.rng.integers(0, 4))   # not the frame-number bytes
            self.k_flip(1, 1, ptr, off, int(self.rng.integers(0, 8)))
            st.injected["corrupt"] += 1
        psn = ((k + 1) * self.ppf - 1) & 0xFFFFFF        # PSN of the metadata packet (PSN 0 at start)
        rec_psn = psn
        if c.psn_bad_every and (self.sent + 1) % c.psn_bad_every == 0:
            rec_psn = (psn + 1) & 0xFFFFFF
            st.injected["psn"] += 1
        now = time.time() - self.t_start
        ts_s, ts_ns = int(now), int((now % 1) * 1e9)
        self.k_rec(1, 128, ptr + self.md_off, rec_psn, rfn & 0xFFFF, self.fs, ts_s, ts_ns, ts_s, ts_ns)
        self.sent += 1
        md = self.metadata
        vals = dict(frame_number=rfn if c.data == "file" else self.ext, imm_data=((psn & 0xFFFFF) << 12) | page,
                    page_number=page, frame_memory=ptr, dropped=0, bytes_written=self.fs,
                    received_frame_number=self.sent, timestamp_s=ts_s, timestamp_ns=ts_ns, metadata_s=ts_s,
                    metadata_ns=ts_ns, received_s=ts_s, received_ns=ts_ns, crc=0)
        if c.data == "file":
            vals["rocelet_replay"] = 1
        for key, v in vals.items():
            if self.cpp:
                md.set(key, int(v), cast_to_cpp=True)     # int64 for the C++ checker
            else:
                md[key] = v
        op_output.emit({"": self.ring[page * self.ps:page * self.ps + self.fs]}, "output")
        if self.sent % 16 == 0:
            st.source_us.append((time.perf_counter() - t_in) * 1e6)


def iq_stride(frame_size):
    """Samples per frame in the IQ16 sample count: the producer takes whole 64-byte beats
    (16 samples), so a frame of S samples advances the count by S rounded up to 16."""
    return round_up(frame_size // 4, 16)


# ------------------------------------------------------------------------------------------
# Checker
# ------------------------------------------------------------------------------------------
class CheckerOp(Operator):
    """Verifies the frames it receives on the GPU, without a host synchronisation per frame:
    per frame a kernel reads the metadata record from GPU memory (PSN, frame number,
    bytes_written), a check kernel compares the data with the counter pattern or the IQ16
    model (mismatches equal to a LATER frame of the same page = overrun, else error), and a
    third reads the record's frame number again (page reused during the check). Results go to
    a GPU slot array that the host collects once a second: then the PSN rules (record PSN =
    immediate PSN, PSN step = packets per frame x frame-number step), bytes_written and the
    frame accounting (gaps = consumer drops reported by the receiver + network losses).
    --check-every N checks the data of every Nth frame (the record of every frame).
    A producer restart (the board resumes after a link pause at frame 0 / first page / IQ16 sample
    0, PSN kept) is a "resync": the 16-bit frame number falls back below --resync-window and the
    PSN does not follow the frame-number step. It is counted and logged, starts a new accounting
    segment (no gap, no data error), and the frames lost across it are taken from the PSN step.
    rocelet_ops.CheckerOp (cpp/) is the same checker in C++."""

    def __init__(self, fragment, *args, cfg, stats, passthrough, **kwargs):
        self.c = cfg
        self.stats = stats
        self.passthrough = passthrough
        super().__init__(fragment, *args, **kwargs)

    def setup(self, spec):
        spec.input("input")
        if self.passthrough:
            spec.output("output").condition(ConditionType.NONE)

    def start(self):
        c = self.c
        self.fs = c.frame_size
        self.md_off = round_up(self.fs, PAGE_ALIGN)
        self.ppf = packets_per_frame(self.fs, c.mtu)
        self.res = cp.zeros((RES_SLOTS, SLOT_WORDS), dtype=cp.uint64)
        self.res[:, 2] = cp.uint64(0xFFFFFFFFFFFFFFFF)
        self.res_ptr = self.res.data.ptr
        self.slot = 0
        self.pend = np.zeros((RES_SLOTS, 6), dtype=np.int64)   # per slot: fn, imm, bw, checked, replay, resync
        self.epoch = 0                # extended frame number of the board's frame 0 (moves at a resync)
        self.wrap_base, self.raw_last16 = 0, -1   # module API receiver: own 16-bit frame number extension
        self.last_ipsn = None
        self.k_chk = FastKernel("chk_frame", CHK_ARGS)
        self.cfg = iq_cfg(c.scene) if c.check == "iq" else None
        self.cfg_ptr = self.cfg.data.ptr if self.cfg is not None else 0
        self.ev = None
        self.ev_pairs = []
        self.last_fn = None
        self.dropped0 = None
        self.prev_rec = None          # (fn, psn) of the last frame with a valid record
        self.t_line = time.time()
        self.n = 0
        self.summary = None

    def compute(self, op_input, op_output, context):
        t_in = time.perf_counter()
        msg = op_input.receive("input")
        st, c = self.stats, self.c
        md = self.metadata
        if st.t0 is None:
            st.t0 = time.time()
        fn = int(md.get("frame_number", 0))
        if md.get("received_frame_number", None) is None and 0 <= fn <= 0xFFFF and not int(md.get("rocelet_replay", 0)):
            # module API receiver: 16-bit frame number as sent (the classic receiver extends it);
            # a forward step of < 32768 across 0 is a wrap, anything else a restart
            if self.raw_last16 >= 0 and fn < self.raw_last16 and ((fn - self.raw_last16) & 0xFFFF) < 0x8000:
                self.wrap_base += 0x10000
            self.raw_last16 = fn
            fn += self.wrap_base
        dropped = int(md.get("dropped", 0))
        imm = int(md.get("imm_data", -1))
        no_psn = imm < 0                                   # module API receiver: no imm_data
        imm = max(imm, 0)
        mem = int(md.get("frame_memory", 0))
        bw = int(md.get("bytes_written", self.fs))
        replay = int(md.get("rocelet_replay", 0))
        if mem == 0:                                       # no metadata: take the tensor's address
            mem = cp.asarray(msg[""]).data.ptr
        st.rx += 1
        st.rx_bytes += self.fs + METADATA_SIZE
        if st.first_fn is None:
            st.first_fn = fn
        if self.dropped0 is None:
            self.dropped0 = dropped
        st.hsb_dropped = dropped - self.dropped0
        rfn = md.get("received_frame_number", None)
        if rfn is None:
            st.have_rfn = False                            # module API receiver: no completion count
            rfn = st.rx
        rfn = int(rfn)
        if st.first_rfn is None:
            st.first_rfn = st.seg_first_rfn = rfn
            st.seg_first_fn = fn
        if st.t_first_frame is None:
            st.t_first_frame = time.time()
        fn16 = fn & 0xFFFF
        ipsn = (imm >> 12) & 0xFFFFF
        resync = False
        if self.last_fn is not None and not replay:
            d = fn - self.last_fn
            last16 = self.last_fn & 0xFFFF
            if (fn16 < last16 or d < 1) and fn16 < c.resync_window:
                exp = (self.last_ipsn + d * self.ppf) & 0xFFFFF if self.last_ipsn is not None else None
                # no imm_data (module API): a natural wrap is the extended frame number stepping by 1
                resync = d < 1 or (d != 1 if no_psn else (exp is None or ipsn != exp))
            if resync:
                # the board restarted at frame 0: close the segment; frames sent but never completed
                # across the restart = PSN step / packets per frame - receiver completions
                st.lost_closed += (self.last_fn - st.seg_first_fn) - (st.last_rfn - st.seg_first_rfn)
                if self.last_ipsn is not None:
                    gone = ((ipsn - self.last_ipsn) & 0xFFFFF) // self.ppf - (rfn - st.last_rfn)
                    if 0 < gone < (1 << 19) // self.ppf:
                        st.lost_closed += gone
                        st.resync_lost += gone
                st.seg_first_fn, st.seg_first_rfn = fn, rfn
                self.epoch = fn - fn16
                st.resyncs += 1
                self._show(f"resync: frame number restarted at {fn16} after frame {self.last_fn} "
                           f"({rfn - st.last_rfn} frames by the receiver count): producer restart, e.g. a link pause")
            elif d > 1:
                st.gaps += d - 1
            elif d < 1:
                st.fn_back += 1
        if self.last_fn is not None and replay:
            st.fn_span_replay += fn - self.last_fn - 1     # replayed file: frame number does not advance
        st.last_rfn = rfn
        self.last_fn = fn
        self.last_ipsn = ipsn
        st.last_fn = fn
        st.consumer_dropped = st.gaps - (st.lost - st.resync_lost) if not replay and st.lost >= 0 else (0 if replay else -1)

        do_check = c.check != "none" and (self.n % c.check_every == 0)
        self.n += 1
        slot_ptr = self.res_ptr + self.slot * SLOT_WORDS * 8
        rec = mem + self.md_off
        timed = do_check and (self.n % 64 == 1)
        if timed:
            e0, e1 = cp.cuda.Event(), cp.cuda.Event()
            e0.record()
        if not do_check:
            self.k_chk(1, 32, 0, mem, 0, fn & 0xFFFF, 0, 0, self.cfg_ptr, rec, slot_ptr)
        elif c.check == "counter":
            w = self.fs // 8
            self.k_chk(blocks(w, cap=1024), 256, 1, mem, w, fn & 0xFFFF, 0, 0, self.cfg_ptr, rec, slot_ptr)
        else:
            s = self.fs // 4
            stride = iq_stride(self.fs)
            self.k_chk(blocks(s, cap=2048), 256, 2, mem, s, fn & 0xFFFF, (fn - self.epoch) * stride,
                       c.pages * stride, self.cfg_ptr, rec, slot_ptr)
        if timed:
            e1.record()
            self.ev_pairs.append((e0, e1))
        self.pend[self.slot] = (fn, imm, bw, do_check, replay, resync)
        self.slot += 1
        if self.passthrough:
            op_output.emit(msg, "output")
        now = time.time()
        if self.slot == RES_SLOTS or now - self.t_line >= c.stats_interval:
            self.harvest()
            if now - self.t_line >= c.stats_interval:
                self.t_line = now
                print(st.line(self.fs), flush=True)
        if self.n % 16 == 0:
            st.check_us.append((time.perf_counter() - t_in) * 1e6)

    def harvest(self):
        if self.slot == 0:
            return
        st, c = self.stats, self.c
        cp.cuda.get_current_stream().synchronize()
        n = self.slot
        r = self.res[:n].get().astype(np.int64)
        self.res[:n, :] = 0
        self.res[:n, 2] = cp.uint64(0xFFFFFFFFFFFFFFFF)
        for e0, e1 in self.ev_pairs:
            st.gpu_us.append(cp.cuda.get_elapsed_time(e0, e1) * 1e3)
        self.ev_pairs = []
        # vectorised over the n frames since the last harvest (a Python loop here cost ~10 us per
        # frame: ~12 ms per harvest at 10 Gb/s, ~100 ms at 80 Gb/s -> the receiver queue overflowed)
        p = self.pend[:n]
        fn, imm, bw, checked, replay, resync = p[:, 0], p[:, 1], p[:, 2], p[:, 3] != 0, p[:, 4] != 0, p[:, 5] != 0
        fn16 = fn & 0xFFFF
        rec_ok = r[:, 4] == fn16
        psn = r[:, 3] & 0xFFFFF
        ipsn = (imm >> 12) & 0xFFFFF
        bad = rec_ok & (psn != ipsn)
        st.psn_bad += int(bad.sum())
        for k in np.flatnonzero(bad)[:20]:
            self._show(f"frame {fn[k]}: record PSN 0x{psn[k]:05x} != immediate PSN 0x{ipsn[k]:05x}")
        bad = rec_ok & ((r[:, 5] != self.fs) | (bw != self.fs))
        st.bw_bad += int(bad.sum())
        for k in np.flatnonzero(bad)[:20]:
            self._show(f"frame {fn[k]}: bytes_written {r[k, 5]} (metadata {bw[k]}), frame {self.fs}")
        ok = np.flatnonzero(rec_ok)
        if len(ok):
            pfn = np.empty(len(ok), dtype=np.int64)
            ppsn = np.empty(len(ok), dtype=np.int64)
            pfn[1:], ppsn[1:] = fn[ok[:-1]], psn[ok[:-1]]
            have = np.ones(len(ok), dtype=bool)
            if self.prev_rec is not None:
                pfn[0], ppsn[0] = self.prev_rec
            else:
                pfn[0], ppsn[0], have[0] = 0, 0, False
            exp = (ppsn + (fn[ok] - pfn) * self.ppf) & 0xFFFFF
            bad = have & ~replay[ok] & ~resync[ok] & (psn[ok] != exp)
            st.psn_seq_bad += int(bad.sum())
            for k in np.flatnonzero(bad)[:20]:
                self._show(f"frame {fn[ok][k]}: PSN 0x{psn[ok][k]:05x}, expected 0x{exp[k]:05x} after frame "
                           f"{pfn[k]} ({self.ppf} packets per frame)")
            self.prev_rec = (int(fn[ok[-1]]), int(psn[ok[-1]]))
        ew, ow = r[:, 0], r[:, 1]
        reused = ~rec_ok | (r[:, 7] != fn16)
        st.checked += int(checked.sum())
        # a page whose record no longer carries this frame number (before or after the check) was
        # rewritten by a later frame: its data cannot be judged -> overrun, not error. Hardware
        # session F: the first frame of a run reached the checker ~0.7 s late (start-up), its
        # page rewritten many times over; the counter pattern showed it as a later frame, the
        # IQ16 check (which only knows frame + pages) counted it as 262,143 words in error.
        err = checked & (ew != 0) & ~reused
        st.err_frames += int(err.sum())
        st.err_words += int(ew[err].sum())
        for k in np.flatnonzero(err)[:20]:
            self._show(f"frame {fn[k]}: {ew[k]} words differ (first at {r[k, 2]}), {ow[k]} from a later frame")
        ovr = checked & ((ow != 0) | reused)
        st.ovr_frames += int(ovr.sum())
        st.ovr_words += int(ow[ovr].sum())
        st.harvested += n
        self.slot = 0

    def _show(self, s):
        st = self.stats
        if st.errors_shown < 20:
            print(s, flush=True)
        st.errors_shown += 1

    def stop(self):
        self.harvest()
        st = self.stats
        print(st.line(self.fs), flush=True)


# ------------------------------------------------------------------------------------------
# Spectrogram -> Holoviz
# ------------------------------------------------------------------------------------------
def colormap_lut():
    """256-entry RGBA colour map (black - dark blue - purple - red - yellow - white), uint8."""
    pts = [(0.0, (0, 0, 0)), (0.3, (10, 10, 70)), (0.5, (110, 20, 150)), (0.7, (235, 60, 40)),
           (0.85, (250, 200, 50)), (1.0, (255, 255, 235))]
    x = np.linspace(0, 1, 256)
    lut = np.zeros((256, 4), dtype=np.uint8)
    for ch in range(3):
        lut[:, ch] = np.interp(x, [p[0] for p in pts], [p[1][ch] for p in pts]).round()
    lut[:, 3] = 255
    return lut


class SpectrogramOp(Operator):
    """IQ16 frames -> rows of a waterfall: per row (rows_per_s, default 30) the first
    --fft-frames frames that arrive are transformed (each frame of S samples = S / nfft
    Hann-windowed 4096-point cuFFT transforms, complex float), |X|^2 is summed into the row,
    the row is FFT-shifted (-Fs/2 left), reduced to 1024 columns (power per column, so a tone
    reads its power: 0 dBFS = a full-scale complex tone) and scaled to 8 bits over
    [db_top - db_range, db_top]. The waterfall (rows x 1024, newest on top) gets a colour map
    on the GPU and goes to Holoviz with a spectrum trace of the newest row and a text overlay.
    Frames between rows pass without GPU work."""

    def __init__(self, fragment, *args, cfg, stats, **kwargs):
        self.c = cfg
        self.stats = stats
        super().__init__(fragment, *args, **kwargs)

    def setup(self, spec):
        spec.input("input")
        # no Holoviz (--viz none): outputs unconnected, so they must not gate the operator
        cond = ConditionType.NONE if self.c.viz == "none" else ConditionType.DOWNSTREAM_MESSAGE_AFFORDABLE
        spec.output("output").condition(cond)
        spec.output("output_specs").condition(cond)

    def start(self):
        from cupy.cuda import cufft
        c = self.c
        self.nfft = c.nfft
        self.cols = 1024
        self.H = c.rows
        s = c.frame_size // 4
        self.nt = s // self.nfft                           # transforms per frame
        if self.nt == 0:
            raise ValueError(f"frame of {s} samples < nfft {self.nfft}")
        n = np.arange(self.nfft)
        win = 0.5 - 0.5 * np.cos(2 * np.pi * n / self.nfft)
        self.win = cp.asarray(win.astype(np.float32))
        self.wsum2 = float(np.sum(win ** 2))
        self.buf = cp.zeros(self.nt * self.nfft, dtype=cp.complex64)
        self.X = cp.zeros_like(self.buf)
        # one batched C2C plan, executed in place of cp.fft.fft (no per-call plan lookup / allocation)
        self.plan = cufft.Plan1d(self.nfft, cufft.CUFFT_C2C, self.nt)
        self.fwd = cufft.CUFFT_FORWARD
        self.acc = cp.zeros(self.nfft, dtype=cp.float32)
        self.rows = cp.zeros((self.H, self.cols), dtype=cp.uint8)
        self.row_db = cp.full(self.cols, -200.0, dtype=cp.float32)
        # canvas: text + spectrum trace in the top 30 %, the waterfall in 30-94 %, axis labels below
        self.Htot = int(round(self.H / 0.64))
        self.y0 = int(round(0.30 * self.Htot))
        self.img = cp.zeros((self.Htot, self.cols, 4), dtype=cp.uint8)
        self.lut = cp.asarray(colormap_lut())
        self.head = 0
        self.row_frames = 0
        self.row_t0 = None
        self.period = 1.0 / c.rows_per_s
        self.k_c64 = FastKernel("iq_to_c64", [U8, U8, U8, U32, U8])
        self.k_pow = FastKernel("pow_accum", [U8, U8, U32, U32])
        self.k_row = Kernels.get("row_close")
        self.k_img = Kernels.get("waterfall_rgba")
        self.xs = cp.asarray(((np.arange(self.cols) + 0.5) / self.cols).astype(np.float32))
        self.fps_t = (time.time(), 0)
        self.fs_est = 0.0
        self.stream_gbps = 0.0

    def compute(self, op_input, op_output, context):
        msg = op_input.receive("input")
        c, st = self.c, self.stats
        now = time.time()
        if self.row_t0 is None:
            self.row_t0 = now
        if self.row_frames < c.fft_frames:
            t0 = time.perf_counter()
            mem = int(self.metadata.get("frame_memory", 0)) or cp.asarray(msg[""]).data.ptr
            n = self.nt * self.nfft
            self.k_c64(blocks(n, cap=2048), 256, mem, self.buf.data.ptr, self.win.data.ptr, self.nfft, n)
            self.plan.fft(self.buf, self.X, self.fwd)
            self.k_pow(blocks(self.nfft), 256, self.X.data.ptr, self.acc.data.ptr, self.nfft, self.nt)
            self.row_frames += 1
            st.spectro_frames += 1
            if st.spectro_frames % 16 == 1:
                st.spectro_us.append((time.perf_counter() - t0) * 1e6)
        if now - self.row_t0 < self.period:
            return
        self.row_t0 += self.period
        if now - self.row_t0 > 5 * self.period:            # fell behind (e.g. start-up): resync
            self.row_t0 = now
        if self.row_frames == 0:
            return
        scale = 1.0 / (self.row_frames * self.nt * self.nfft * self.wsum2 * 32767.0 ** 2)
        self.head = (self.head + 1) % self.H
        self.k_row(grid(self.cols), (256,), (self.acc, self.row_db, self.rows[self.head], np.uint32(self.nfft),
                                             np.uint32(self.cols), np.float32(scale), np.float32(c.db_top),
                                             np.float32(c.db_range)))
        self.acc.fill(0)
        self.row_frames = 0
        st.spectro_rows += 1
        self.k_img((-(-self.cols // 256), self.Htot), (256,), (self.rows, np.uint32(self.H), np.uint32(self.cols),
                                                               np.uint32(self.head), self.lut, self.img,
                                                               np.uint32(self.y0), np.uint32(self.Htot)))
        self.emit_view(op_output, now)

    def emit_view(self, op_output, now):
        from holoscan.operators import HolovizOp
        c, st = self.c, self.stats
        t, n = self.fps_t
        if now - t >= 1.0:
            dt = st.elapsed()
            # the board's sample rate: frames it numbered (incl. those the application skipped),
            # not the frames delivered (session F: 80 Gb/s read 0.77 GS/s instead of 2.45)
            board = (st.last_fn - st.first_fn + 1) if st.first_fn is not None and c.data != "file" else st.rx
            self.fs_est = board * iq_stride(c.frame_size) / dt if dt > 0 else 0.0
            self.stream_gbps = board * (c.frame_size + METADATA_SIZE) * 8 / dt / GBIT if dt > 0 else 0.0
            self.fps_t = (now, st.rx)
        # spectrum trace of the newest row: y = SPEC_Y0 (db_top) .. SPEC_Y1 (db_top - db_range)
        y0, y1 = 0.075, 0.285
        f = cp.clip((c.db_top - self.row_db) / c.db_range, 0.0, 1.0)
        trace = cp.stack([self.xs, y0 + (y1 - y0) * f], axis=1).astype(cp.float32)
        dt = st.elapsed()
        gbps = st.rx_bytes * 8 / dt / GBIT if dt > 0 else 0
        line1 = (f"qsfp28-fmc-rocelet HSB  {c.source}  {c.data_desc}  |  stream {self.stream_gbps:5.2f} Gb/s  "
                 f"Fs {self.fs_est / 1e9:5.3f} GS/s  |  app {gbps:5.2f} Gb/s {st.rx / dt if dt else 0:6.0f} frames/s")
        line2 = (f"frames {st.rx}  checked {st.checked}  errors {st.err_frames}  lost {st.lost}  "
                 f"psn {st.psn_bad}/{st.psn_seq_bad}  overrun {st.ovr_frames}  |  {self.nfft}-pt FFT, "
                 f"{c.rows_per_s:.0f} rows/s, {c.db_top - c.db_range:.0f}..{c.db_top:.0f} dBFS")
        txt = HolovizOp.InputSpec("stats", HolovizOp.InputType.TEXT)
        txt.text = [line1, line2]
        txt.color = [1.0, 1.0, 1.0, 1.0]
        axis = HolovizOp.InputSpec("axis", HolovizOp.InputType.TEXT)
        axis.text = ["-Fs/2", "0", "+Fs/2", f"{c.db_top:.0f} dBFS", f"{c.db_top - c.db_range:.0f} dBFS",
                     f"{self.H / c.rows_per_s:.0f} s"]
        axis.color = [0.8, 0.8, 0.8, 1.0]
        spec = HolovizOp.InputSpec("spectrum", HolovizOp.InputType.LINE_STRIP)
        spec.color = [0.3, 1.0, 0.4, 1.0]
        spec.line_width = 1.5
        wf = HolovizOp.InputSpec("waterfall", HolovizOp.InputType.COLOR)   # the whole canvas (views of
        # dynamic specs were ignored by Holoviz 4.4 in our test, so the layout is in the image)
        coords_txt = cp.asarray([[0.005, 0.005, 0.03], [0.005, 0.038, 0.03]], dtype=cp.float32)
        coords_axis = cp.asarray([[0.003, 0.95, 0.03], [0.495, 0.95, 0.03], [0.955, 0.95, 0.03],
                                  [0.005, 0.075, 0.025], [0.005, 0.265, 0.025], [0.005, 0.915, 0.025]],
                                 dtype=cp.float32)
        op_output.emit({"waterfall": self.img, "spectrum": trace, "stats": coords_txt, "axis": coords_axis}, "output")
        op_output.emit([wf, spec, txt, axis], "output_specs")


class PngSinkOp(Operator):
    """Saves every Nth Holoviz render buffer (after the format converter: H x W x 3 uint8) as PNG;
    the PNG encoding runs in a background thread so the pipeline does not stall."""

    def __init__(self, fragment, *args, cfg, stats, **kwargs):
        self.c = cfg
        self.stats = stats
        self.n = 0
        self.threads = []
        super().__init__(fragment, *args, **kwargs)

    def setup(self, spec):
        spec.input("input")

    def compute(self, op_input, op_output, context):
        msg = op_input.receive("input")
        self.n += 1
        if self.c.png_every <= 0 or self.n % self.c.png_every:
            return
        from PIL import Image
        a = cp.asarray(msg["frame"]).get()
        path = os.path.join(self.c.outdir, f"{self.c.tag}_{len(self.stats.pngs):03d}.png")
        self.stats.pngs.append(path)
        self.stats.png_t.append(time.monotonic())
        th = threading.Thread(target=lambda: Image.fromarray(a).save(path), daemon=True)
        th.start()
        self.threads = [t for t in self.threads if t.is_alive()] + [th]

    def stop(self):
        for t in self.threads:
            t.join(timeout=10)
        print(f"{len(self.stats.pngs)} PNGs in {self.c.outdir}", flush=True)


# ------------------------------------------------------------------------------------------
# Application
# ------------------------------------------------------------------------------------------
class RoceletDevice:
    """The 'device' of RoceReceiverOp: start() runs after the receiver configured the data plane
    (configure_roce; with the start gate the board waits for DP_VP_MASK), stop() before it
    unconfigures it."""

    def __init__(self, gated, ready=None):
        self.gated = gated
        self.ready = ready                 # threading.Event for StartGateOp: the data plane is configured

    def start(self):
        if self.ready is not None:
            self.ready.set()
        print("data plane configured: " + ("waiting for the start gate" if self.gated else "the board is sending"),
              flush=True)

    def stop(self):
        if self.ready is not None:
            self.ready.clear()
        print("receiver stopping: data plane will be unconfigured", flush=True)


class StartGateOp(Operator):
    """Starts the data plane once the pipeline is ready. Holoscan calls start() of every operator
    (receiver set-up, kernel loading, cuFFT plans, Holoviz / Vulkan) before the first compute() of
    any of them, but the receiver's start() configures the board, which then streams into a graph
    still initialising (hardware session F: the first frame reached the checker ~0.7 s late, 800-3,500
    frames recycled at start-up, 881-1,269 CX-6 PHY discards at the 80 Gb/s demo start). This
    operator (no ports, one tick) runs after every start(); it enables the data plane --start-delay
    seconds later (default 0). Do not idle the GPU first: hardware session G measured 420-550 k CX-6
    PHY discards + 1,300-1,700 pause frames and frames with holes at an 80 Gb/s demo start after a
    1-3 s delay (the idle GPU had dropped to P8 / PCIe Gen1), none with 0 s."""

    def __init__(self, fragment, *args, enable, delay, stats, stopping, ready=None, **kwargs):
        self.enable_fn, self.delay, self.stats, self.stopping = enable, delay, stats, stopping
        self.ready = ready
        super().__init__(fragment, *args, **kwargs)

    def setup(self, spec):
        pass

    def fire(self):
        if self.stopping():
            return
        self.enable_fn()
        st = self.stats
        st.t_dp_enable = time.time()
        print(f"start gate: data plane enabled {st.t_dp_enable - st.t_run:.3f} s after app.run() "
              f"(graph up at {st.t_graph_up - st.t_run:.3f} s)", flush=True)

    def wait_fire(self):
        # the module API's RoceReceiverOp configures the data plane on its own thread after start()
        # (hardware session G: the gate fired 0.4 s before the configure, which then left DP_VP_MASK
        # clear: no frames); wait for the receiver's device_start callback
        if self.ready is not None and not self.ready.wait(10.0):
            print("start gate: the receiver did not report a configured data plane within 10 s; enabling anyway",
                  flush=True)
        if self.delay > 0:
            time.sleep(self.delay)
        self.fire()

    def compute(self, op_input, op_output, context):
        self.stats.t_graph_up = time.time()
        if self.delay > 0 or (self.ready is not None and not self.ready.is_set()):
            threading.Thread(target=self.wait_fire, name="start-gate", daemon=True).start()
        else:
            self.fire()


class RoceletHsbApp(Application):
    def __init__(self, cfg, stats, hsb=None):
        super().__init__()
        self.c = cfg
        self.stats = stats
        self.hsb = hsb                     # (DataChannel or module metadata, CUcontext) for --source roce
        self.run_cond = None
        self.src = self.chk = None
        self.gate_enable = None            # set by main(): starts the data plane
        self.dp_ready = threading.Event() if cfg.source == "roce" else None
        self.stopping = lambda: False
        self.enable_metadata(True)

    def compose(self):
        c = self.c
        threads = c.threads if c.threads >= 0 else (c.default_threads if c.source in ("roce", "csynthetic") else 0)
        if threads > 0:
            # RoceReceiverOp: the receiver signals every completion through an asynchronous
            # condition; under the greedy scheduler the delivered frame rate then DECAYS once the
            # stream outruns the application (KCU116 at 40 Gb/s: 2000 -> 160 frames/s within 20 s),
            # the event-based scheduler holds ~4500-5000 frames/s (hardware session F).
            self.scheduler(EventBasedScheduler(self, name="sched", worker_thread_number=threads))
        else:
            # never sleep between ticks (the default recession period idled ~8 ms per frame in demo mode)
            self.scheduler(GreedyScheduler(self, name="sched", check_recession_period_ms=0.0))
        if c.start_gate:
            # created before the source: the greedy scheduler then ticks it before a blocking receiver's
            # first compute() (which would otherwise wait for a frame that the gate has not enabled yet)
            self.add_operator(StartGateOp(self, CountCondition(self, name="gate_once", count=1), name="start_gate",
                                          enable=lambda: self.gate_enable(), delay=c.start_delay, stats=self.stats,
                                          stopping=lambda: self.stopping(), ready=self.dp_ready))
        conds = []
        self.run_cond = BooleanCondition(self, name="run", enable_tick=True)
        conds.append(self.run_cond)
        if c.frames:
            conds.append(CountCondition(self, name="frames", count=c.frames))
        if c.source == "synthetic":
            if c.rate > 0:
                period_ns = int((c.frame_size + METADATA_SIZE) * 8 / (c.rate * GBIT) * 1e9)
                conds.append(PeriodicCondition(self, name="pace", recess_period=max(period_ns, 1)))
            src = SyntheticFrameOp(self, *conds, name="source", cfg=c, stats=self.stats)
        elif c.source == "csynthetic":
            ops = cpp_ops(c)
            period_ns = int((c.frame_size + METADATA_SIZE) * 8 / (c.rate * GBIT) * 1e9) if c.rate > 0 else 0
            src = ops.SourceOp(self, *conds, name="source", frame_size=c.frame_size, pages=c.pages,
                               packets_per_frame=packets_per_frame(c.frame_size, c.mtu),
                               data=2 if c.data == "iq" else 1, iq_cfg=iq_cfg_list(c.scene), period_ns=period_ns,
                               queue_size=c.queue_size, gated=c.start_gate, restart_every=c.restart_every,
                               restart_lost=c.restart_lost, use_frame_ready_condition=c.frame_ready == "async")
        elif c.api == "module":
            import hololink_module
            import hololink_module.operators
            md, ctx = self.hsb
            dev = RoceletDevice(c.start_gate, self.dp_ready)
            src = hololink_module.operators.RoceReceiverOp(
                self, *conds, name="receiver", enumeration_metadata=md, frame_context=int(ctx),
                frame_size=c.frame_size, pages=c.pages, queue_size=c.queue_size, device_start=dev.start,
                device_stop=dev.stop)
        else:
            import hololink as hololink_module
            dc, ctx = self.hsb
            src = hololink_module.operators.RoceReceiverOp(
                self, *conds, name="receiver", hololink_channel=dc, device=RoceletDevice(c.start_gate, self.dp_ready),
                frame_context=ctx, frame_size=c.frame_size, ibv_name=c.ibv_name, ibv_port=c.ibv_port,
                pages=c.pages, queue_size=c.queue_size, trim=False,
                use_frame_ready_condition=c.frame_ready == "async")
        self.src = src
        demo = c.mode == "demo"
        if c.checker == "cpp":
            ops = cpp_ops(c)
            chk = ops.CheckerOp(self, name="checker", frame_size=c.frame_size, pages=c.pages,
                                packets_per_frame=packets_per_frame(c.frame_size, c.mtu),
                                mode={"none": 0, "counter": 1, "iq": 2}[c.check], check_every=c.check_every,
                                iq_cfg=iq_cfg_list(c.scene) if c.check == "iq" else [], passthrough=demo,
                                harvest_interval=1.0, resync_window=c.resync_window,
                                legacy_stream=c.source == "synthetic")
        else:
            chk = CheckerOp(self, name="checker", cfg=c, stats=self.stats, passthrough=demo)
        self.chk = chk
        self.add_flow(src, chk, {("output", "input")})
        if not demo:
            return
        sp = SpectrogramOp(self, name="spectrogram", cfg=c, stats=self.stats)
        self.add_flow(chk, sp, {("output", "input")})
        if c.viz == "none":
            return
        from holoscan.operators import FormatConverterOp, HolovizOp
        from holoscan.resources import BlockMemoryPool, MemoryStorageType
        W, H = c.width, c.height
        want_png = c.png_every > 0
        kw = {}
        if want_png:
            kw = dict(enable_render_buffer_output=True,
                      allocator=BlockMemoryPool(self, name="hv_pool", storage_type=MemoryStorageType.DEVICE,
                                                block_size=W * H * 4, num_blocks=4))
        hv = HolovizOp(self, name="holoviz", headless=c.headless, width=W, height=H,
                       window_title="qsfp28-fmc-rocelet HSB spectrogram",
                       tensors=[dict(name="waterfall", type="color")], **kw)
        # the spectrogram's two outputs carry the same frame metadata: let the second one win
        hv.metadata_policy = MetadataPolicy.UPDATE
        self.add_flow(sp, hv, {("output", "receivers"), ("output_specs", "input_specs")})
        if want_png:
            fc = FormatConverterOp(self, name="to_rgb", in_dtype="rgba8888", out_dtype="rgb888", out_tensor_name="frame",
                                   pool=BlockMemoryPool(self, name="fc_pool", storage_type=MemoryStorageType.DEVICE,
                                                        block_size=W * H * 4, num_blocks=4))
            png = PngSinkOp(self, name="png", cfg=c, stats=self.stats)
            self.add_flow(hv, fc, {("render_buffer_output", "source_video")})
            self.add_flow(fc, png, {("tensor", "input")})


def summary(c, st, verdict_reason):
    def avg(v):
        return round(float(np.mean(v)), 1) if v else None

    def pct(v, q):
        return round(float(np.percentile(v, q)), 1) if v else None
    dt = st.elapsed()
    s = dict(
        app="rocelet_hsb_app.py", time=datetime.datetime.now().isoformat(timespec="seconds"),
        args={k: v for k, v in vars(c).items() if not k.startswith("_")},
        seconds=round(dt, 3), frames=st.rx, frames_per_s=round(st.rx / dt, 1) if dt else 0,
        gbps=round(st.rx_bytes * 8 / dt / GBIT, 3) if dt else 0, first_frame=st.first_fn, last_frame=st.last_fn,
        checked=st.checked, check_coverage=round(st.checked / st.rx, 4) if st.rx else 0,
        gaps=st.gaps, consumer_dropped=st.consumer_dropped, hsb_dropped=st.hsb_dropped, lost=st.lost,
        receiver_cqes=(st.last_rfn - st.first_rfn + 1) if st.first_rfn is not None else 0, frame_number_backwards=st.fn_back,
        error_frames=st.err_frames, error_words=st.err_words, overrun_frames=st.ovr_frames,
        overrun_words=st.ovr_words, psn_mismatch=st.psn_bad, psn_sequence_errors=st.psn_seq_bad,
        bytes_written_errors=st.bw_bad, injected=st.injected,
        resyncs=st.resyncs, resync_lost=st.resync_lost, checker=c.checker, api=c.api, source=c.source,
        start=dict(gate=c.start_gate, delay_s=c.start_delay,
                   graph_up_s=round(st.t_graph_up - st.t_run, 3) if st.t_graph_up and st.t_run else None,
                   dp_enable_s=round(st.t_dp_enable - st.t_run, 3) if st.t_dp_enable and st.t_run else None,
                   first_frame_s=round(st.t_first_frame - st.t_run, 3) if st.t_first_frame and st.t_run else None,
                   # frames the receiver completed before the first one reached the checker (recycled
                   # while the graph was starting): received_frame_number of the first frame - 1
                   startup_dropped=(st.first_rfn - 1) if st.have_rfn and st.first_rfn is not None else None),
        checker_host_us_per_frame=(dict(mean=avg(st.check_us), p50=pct(st.check_us, 50), p99=pct(st.check_us, 99))
                                   if c.checker == "py" else dict(zip(("mean", "p50", "p99"),
                                                                      [round(x, 1) for x in st.cpp_host_us]))),
        checker_gpu_us_per_frame=(dict(mean=avg(st.gpu_us), p50=pct(st.gpu_us, 50), p99=pct(st.gpu_us, 99))
                                  if c.checker == "py" else dict(zip(("mean", "p50", "p99"),
                                                                     [round(x, 1) for x in st.cpp_gpu_us]))),
        source_host_us_per_frame=dict(mean=avg(st.source_us), p50=pct(st.source_us, 50)),
        spectrogram=dict(rows=st.spectro_rows, fft_frames=st.spectro_frames,
                         host_us_per_fft_frame=avg(st.spectro_us)),
        pngs=st.pngs, png_t=[round(t, 4) for t in st.png_t], verdict=verdict_reason[0], reason=verdict_reason[1])
    return s


def verdict(c, st):
    inj = st.injected
    if c.source in ("synthetic", "csynthetic") and any(inj.values()):
        ok = (st.err_frames == inj["corrupt"] and st.lost == inj["drop"] + inj["restart_lost"]
              and st.psn_bad == inj["psn"] and st.psn_seq_bad == inj["psn"] * 2 and st.ovr_frames == inj["overrun"]
              and st.resyncs == inj["restart"] and st.resync_lost == inj["restart_lost"] and st.bw_bad == 0
              and st.fn_back == 0 and st.rx > 0)
        return ("PASS" if ok else "FAIL",
                f"self-test: injected {inj}, detected corrupt {st.err_frames} lost {st.lost} psn {st.psn_bad} "
                f"(sequence {st.psn_seq_bad}, 2 per bad record) overrun {st.ovr_frames} resync {st.resyncs} "
                f"(lost {st.resync_lost}) backwards {st.fn_back}")
    bad = []
    if st.rx == 0:
        bad.append("no frames")
    if c.frames and st.rx < c.frames:
        bad.append(f"{st.rx} of {c.frames} frames")
    for k, v in (("error frames", st.err_frames), ("lost", max(st.lost, 0)), ("psn mismatch", st.psn_bad),
                 ("psn sequence", st.psn_seq_bad), ("bytes_written", st.bw_bad), ("frame number backwards", st.fn_back)):
        if v:
            bad.append(f"{k} {v}")
    if c.check != "none" and st.checked == 0:
        bad.append("nothing checked")
    note = f"; {st.ovr_frames} frames overrun (page reused before the check: more --pages or a lower rate)" \
        if st.ovr_frames else ""
    if st.resyncs:
        note += f"; {st.resyncs} producer restart(s) (resync, {st.resync_lost} frames lost across them)"
    if st.lost < 0:
        note += f"; lost not known (the receiver gives no completion count): {st.gaps} frame-number gaps"

    return ("FAIL", ", ".join(bad) + note) if bad else ("PASS", "0 errors, 0 lost, 0 PSN errors" + note)


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description="qsfp28-fmc-rocelet HSB Holoscan application (check / spectrogram demo)")
    ap.add_argument("--mode", choices=["check", "demo"], default="check")
    ap.add_argument("--source", choices=["roce", "synthetic", "csynthetic"], default="roce",
                    help="roce: the board; synthetic: Python generator (fault injection, file replay); "
                         "csynthetic: C++ board + receiver model (cpp/)")
    ap.add_argument("--api", choices=["classic", "module"], default="classic",
                    help="HSB host API for --source roce: classic hololink, or hololink_module with the Opsero module")
    ap.add_argument("--module-dir", default=None, help="directory of hololink_<uuid>_2603.so (else $HOLOLINK_MODULE_DIR)")
    ap.add_argument("--checker", choices=["auto", "cpp", "py"], default="auto",
                    help="frame checker: C++ operator (cpp/build.sh) or Python; auto = cpp when built")
    ap.add_argument("--cpp-dir", default=None, help="directory of rocelet_hsb_ops*.so (default cpp/build)")
    ap.add_argument("--start-gate", choices=["on", "off"], default="on",
                    help="start the data plane only after every operator has started (default on)")
    ap.add_argument("--start-delay", type=float, default=None,
                    help="s between the graph being up and the data plane start (default 0; an idle GPU drops its PCIe link "
                         "to a low-power state within ~1 s, and a line-rate start into it overflows the NIC)")
    ap.add_argument("--frame-ready", choices=["auto", "blocking", "async"], default="auto",
                    help="receiver scheduling: async = HSB's frame-ready AsynchronousCondition (event-based "
                         "scheduler), blocking = compute() waits for the next frame (greedy scheduler); auto = "
                         "blocking for the classic API and csynthetic, async for the module API (no other choice)")
    ap.add_argument("--keepalive", type=int, default=2000,
                    help="ms: the board's producer watchdog; a thread refreshes it every keepalive/4; 0 = off")
    ap.add_argument("--resync-window", type=int, default=4096,
                    help="a 16-bit frame number falling back below this (PSN not following) = producer restart")
    ap.add_argument("--restart-every", type=int, default=0,
                    help="synthetic: producer restart (link-pause resume) every N frames")
    ap.add_argument("--restart-lost", type=int, default=3, help="synthetic: frames lost at each restart")
    ap.add_argument("--data", choices=["iq", "counter", "file"], default=None,
                    help="what the board / generator sends: IQ16 (default in demo), counter pattern (default in "
                         "check), file = replay --synthetic-file (synthetic only)")
    ap.add_argument("--rate", type=float, default=10.0,
                    help="Gb/s (frame + 128-byte record); the board's RATE_MBPS, the generator's pace; 0 = unpaced "
                         "(test host: <= 80 into GPU memory)")
    ap.add_argument("--frames", type=int, default=0, help="stop after N frames (0 = until --duration / Ctrl-C)")
    ap.add_argument("--duration", type=float, default=0, help="stop after N seconds (0 = until --frames / Ctrl-C)")
    ap.add_argument("--frame-size", type=int, default=1 << 20, help="frame bytes (default 1 MiB)")
    ap.add_argument("--pages", type=int, default=64, help="receive ring pages (GPU memory = pages x (frame + 128))")
    ap.add_argument("--queue-size", type=int, default=None,
                    help="RoceReceiverOp queue (<= pages; default min(32, pages / 2): 32 absorbs host stalls, "
                         "99.87 %% vs 99.4-99.7 %% of the frames with 8 at 80 Gb/s)")
    ap.add_argument("--mtu", type=int, default=4200, help="DataChannel.use_mtu (4200 -> 4096-byte packets)")
    ap.add_argument("--scene", type=int, default=1, choices=[1, 2, 3, 4], help="IQ16 scene 1 survey 2 radar 3 tones 4 noise")
    ap.add_argument("--check", choices=["auto", "counter", "iq", "none"], default="auto",
                    help="data check (auto: by --data; file replay checks IQ16 at --file-frame-number)")
    ap.add_argument("--check-every", type=int, default=1, help="check the data of every Nth frame")
    ap.add_argument("--stats-interval", type=float, default=1.0)
    ap.add_argument("--threads", type=int, default=-1,
                    help="-1 (default): event-based scheduler with 2 worker threads for --source roce / csynthetic, "
                         "greedy for synthetic; "
                         "0: Holoscan's greedy scheduler (one thread); N: event-based scheduler, N worker threads")
    ap.add_argument("--ip", default="192.168.20.2", help="board IP (roce)")
    ap.add_argument("--ibv-name", default="rocep179s0f0")
    ap.add_argument("--ibv-port", type=int, default=1)
    ap.add_argument("--synthetic-file", default=None, help="frame file for --data file (frame bytes only)")
    ap.add_argument("--file-frame-number", type=int, default=600, help="the file's frame number (IQ16 check)")
    ap.add_argument("--corrupt-every", type=int, default=0, help="synthetic: flip one bit in every Nth frame")
    ap.add_argument("--drop-every", type=int, default=0, help="synthetic: skip every Nth frame number (a lost frame)")
    ap.add_argument("--psn-bad-every", type=int, default=0, help="synthetic: wrong record PSN in every Nth frame")
    ap.add_argument("--overrun-every", type=int, default=0,
                    help="synthetic: every Nth frame half overwritten by frame + pages (page reused early)")
    ap.add_argument("--viz", choices=["holoviz", "none"], default="holoviz", help="demo: Holoviz or spectrogram only")
    ap.add_argument("--headless", action="store_true", help="Holoviz without a window (render to PNG)")
    ap.add_argument("--png-every", type=int, default=None,
                    help="save every Nth rendered row as PNG (0 = none; default 30 with --headless, else 0)")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--nfft", type=int, default=4096)
    ap.add_argument("--rows", type=int, default=512, help="waterfall rows")
    ap.add_argument("--rows-per-s", type=float, default=30.0)
    ap.add_argument("--fft-frames", type=int, default=8, help="frames transformed per row (the others pass)")
    ap.add_argument("--db-top", type=float, default=0.0)
    ap.add_argument("--db-range", type=float, default=100.0)
    ap.add_argument("--outdir", default=".", help="PNG and JSON directory")
    ap.add_argument("--tag", default=None, help="file name prefix (default: mode_source_data_time)")
    ap.add_argument("--json", default=None, help="summary file (default <outdir>/<tag>.json)")
    a = ap.parse_args(argv)
    if a.data is None:
        a.data = "iq" if a.mode == "demo" else "counter"
    if a.data == "file" and a.source != "synthetic":
        ap.error("--data file needs --source synthetic")
    if a.check == "auto":
        a.check = {"iq": "iq", "counter": "counter", "file": "iq"}[a.data]
    if a.data == "file" and not a.synthetic_file:
        ap.error("--data file needs --synthetic-file")
    if a.queue_size is None:
        a.queue_size = max(1, min(32, a.pages // 2))
    if a.queue_size > a.pages:
        ap.error("--queue-size must be <= --pages")
    if a.frame_size % 8:
        ap.error("--frame-size must be a multiple of 8")
    if a.png_every is None:
        a.png_every = 30 if a.headless else 0
    if a.checker == "auto":
        a.checker = "cpp" if cpp_ops(a) else "py"
    if (a.checker == "cpp" or a.source == "csynthetic") and not cpp_ops(a):
        ap.error("the C++ operators are not built: run cpp/build.sh (or --checker py --source synthetic)")
    if a.source == "csynthetic" and a.data == "file":
        ap.error("--data file needs --source synthetic")
    if a.source == "csynthetic" and any((a.corrupt_every, a.drop_every, a.psn_bad_every, a.overrun_every)):
        ap.error("fault injection (--corrupt/drop/psn-bad/overrun-every) needs --source synthetic")
    a.start_gate = a.start_gate == "on"
    if a.start_delay is None:
        a.start_delay = 0.0
    # Receiver scheduling. HSB's receivers wake the graph through an AsynchronousCondition per frame;
    # once the stream outruns the application the delivered rate decays: under the greedy scheduler
    # always (session F: 2,000 -> 160 frames/s at 40 Gb/s), under the event-based one with 2 workers
    # in most runs of the C++ board model at 80 Gb/s (20-50 % of the frames, 1 run in 6 at 99 %).
    # Without the condition (classic RoceReceiverOp use_frame_ready_condition=False) compute() waits
    # for the next frame and the greedy scheduler simply alternates receiver and checker.
    if a.frame_ready == "auto":
        a.frame_ready = "async" if (a.source == "roce" and a.api == "module") else "blocking"
    if a.frame_ready == "blocking" and a.source == "roce" and a.api == "module":
        ap.error("--frame-ready blocking: the module API's RoceReceiverOp has no such option")
    a.default_threads = 2 if a.frame_ready == "async" else 0
    a.tag = a.tag or f"{a.mode}_{a.source}_{a.data}_{time.strftime('%Y%m%d_%H%M%S')}"
    a.json = a.json or os.path.join(a.outdir, a.tag + ".json")
    a.data_desc = {"iq": f"IQ16 scene {a.scene} ({rocelet_iq.SCENES[a.scene]['name']})", "counter": "counter",
                   "file": f"replay {os.path.basename(a.synthetic_file or '')}"}[a.data]
    return a


def thread_cpu():
    """{tid: (name, cpu seconds)} of this process's threads."""
    out = {}
    tck = os.sysconf("SC_CLK_TCK")
    for d in glob.glob("/proc/self/task/*"):
        try:
            f = open(d + "/stat").read().rsplit(")", 1)[1].split()
            out[d] = (open(d + "/comm").read().strip(), (int(f[11]) + int(f[12])) / tck)
        except (OSError, IndexError, ValueError):
            pass
    return out


def cpu_window(stats, out, wait_s=3.0, window_s=3.0):
    """Per-thread CPU over window_s, wait_s after the first frame (steady state); into out."""
    t_end = time.time() + 120
    while stats.t_first_frame is None and time.time() < t_end:
        time.sleep(0.1)
    time.sleep(wait_s)
    a, t0 = thread_cpu(), time.time()
    time.sleep(window_s)
    b, dt = thread_cpu(), time.time() - t0
    rows = {}
    for k, (name, c1) in b.items():
        c0 = a.get(k, (name, 0.0))[1]
        rows[name] = rows.get(name, 0.0) + (c1 - c0) / dt
    total = sum(rows.values())
    model = sum(v for k, v in rows.items() if k in ("rl-producer", "cuda-EvtHandlr"))
    out.update(total_cores=round(total, 2), synthetic_board_cores=round(model, 2),
               app_cores=round(total - model, 2),
               threads={k: round(v, 2) for k, v in sorted(rows.items(), key=lambda x: -x[1]) if v >= 0.01})


def main(argv=None):
    c = parse_args(argv)
    os.makedirs(c.outdir, exist_ok=True)
    logging.basicConfig(level=logging.INFO)
    stats = Stats()
    hsb = None
    dc = hl = None
    ka = None
    board0 = {}
    stop_reason = []

    if c.source == "roce":
        import cuda.bindings.driver as cuda   # noqa: F401  (the HSB container's CUDA bindings)
        import holoscan.core                   # noqa: F401  (before hololink: registers the operator types)
        import rocelet_hsb
        try:
            if c.api == "module":
                md, hl = rocelet_hsb.connect_module(c.ip, c.mtu, c.module_dir, deferred_start=c.start_gate)
                print(f"module API: {md['module_filename']} ({md['module_name']})", flush=True)
            else:
                dc, hl = rocelet_hsb.connect(c.ip, c.mtu, deferred_start=c.start_gate)
        except RuntimeError as e:
            print(f"{e}: is the board on with 'hsb on' on its console, the container run with --net host, "
                  f"the host interface on the board's subnet?", flush=True)
            return 2
        try:
            hl.reset()
            print(f"HSB IP version 0x{hl.get_hsb_ip_version():04x}, FPGA date 0x{hl.get_fpga_date():08x}", flush=True)
            rocelet_hsb.select_source(hl, "counter" if c.data == "counter" else "iq", int(round(c.rate * 1000)),
                                      c.scene)
            if c.keepalive:
                # after reset() (which clears it) and before the data plane starts
                rocelet_hsb.set_keepalive(hl, c.keepalive)
                ka = rocelet_hsb.KeepAlive(hl, c.keepalive).start()
            board0 = rocelet_hsb.board_counters(hl)
            hsb = (md if c.api == "module" else dc, rocelet_hsb.primary_context())
        except Exception:
            rocelet_hsb.stop_data_plane(hl)
            if ka:
                ka.stop()
            hl.stop()
            raise

    app = RoceletHsbApp(c, stats, hsb)
    app.stopping = lambda: bool(stop_reason)
    if c.source == "roce":
        app.gate_enable = lambda: rocelet_hsb.start_data_plane(hl)
    else:
        app.gate_enable = lambda: app.src.enable()

    def request_stop(reason):
        if not stop_reason:
            stop_reason.append(reason)
            print(f"stopping: {reason}", flush=True)
            if hl is not None:
                # stop the board first: while it streams, the receiver raises an asynchronous event
                # per frame and the event-based scheduler, asked to stop, spins on them ("Deadlock
                # detected after dispatch due to external event", ~900k warnings and a 3-minute
                # shutdown at 40 Gb/s in hardware session F); RoceReceiverOp.stop() unconfigures again
                try:
                    import rocelet_hsb
                    rocelet_hsb.stop_data_plane(hl)
                except Exception as e:
                    print(f"could not stop the data plane yet: {e}", flush=True)
        try:
            if app.run_cond is not None:
                app.run_cond.disable_tick()
            app.stop_execution()
        except Exception as e:              # the graph may already be finishing
            print(f"stop_execution: {e}", flush=True)

    err = []

    def run():
        try:
            app.run()
        except Exception as e:
            err.append(e)

    cpu = {}
    old = {s: signal.signal(s, lambda n, f: request_stop(signal.Signals(n).name)) for s in (signal.SIGINT, signal.SIGTERM)}
    th = threading.Thread(target=run, name="holoscan", daemon=True)
    threading.Thread(target=cpu_window, args=(stats, cpu), name="cpu-sampler", daemon=True).start()
    t_start = time.time()
    stats.t_run = t_start
    r0 = resource.getrusage(resource.RUSAGE_SELF)
    t_line = time.time()
    # stream stall at the end of a --duration run: frames lost at the tail have no later frame to
    # show the gap (hardware session G: watchdog stop during a link outage with lpause off -> PASS)
    rx_last, t_rx, stall_end = -1, time.time(), None
    try:
        th.start()
        while th.is_alive():
            th.join(timeout=0.2)
            if c.checker == "cpp" and app.chk is not None:
                stats.sync_cpp(app.chk.stats())
                if stats.t0 and time.time() - t_line >= c.stats_interval:
                    t_line = time.time()
                    print(stats.line(c.frame_size), flush=True)
            if stats.rx != rx_last:
                rx_last, t_rx = stats.rx, time.time()
            if c.duration and time.time() - t_start >= c.duration and not stop_reason:
                stall_end = time.time() - t_rx if stats.rx else None
                request_stop(f"--duration {c.duration:g} s")
        if err:
            print(f"application error: {err[0]}", flush=True)
    finally:
        for s, h in old.items():
            signal.signal(s, h)
        if hl is not None:
            # RoceReceiverOp.stop() unconfigures the data plane; do it again in case the graph
            # never got there (an exception, a failed start); with the start gate unconfigure()
            # leaves DP_VP_MASK alone, so this write is what stops the board.
            try:
                import rocelet_hsb
                rocelet_hsb.stop_data_plane(hl)
                print("data plane off (DP_VP_MASK 0)", flush=True)
            except Exception as e:
                print(f"could not stop the data plane: {e} ('hsb off' on the console or "
                      f"hololink-write 0x0200030C 0 stops it)", flush=True)
            if ka:
                ka.stop()
            board1 = rocelet_hsb.board_counters(hl)
            try:
                hl.stop()
            except Exception:
                pass
    wall = time.time() - t_start
    r1 = resource.getrusage(resource.RUSAGE_SELF)
    if c.checker == "cpp" and app.chk is not None:
        stats.sync_cpp(app.chk.stats())
        print(stats.line(c.frame_size), flush=True)
    if c.source == "csynthetic" and app.src is not None:
        ss = app.src.stats()
        stats.injected["restart"] = ss["restarts"]
        stats.injected["restart_lost"] = ss["lost_injected"]

    v = verdict(c, stats)
    if stall_end is not None and stall_end > 3.0 and c.source == "roce":
        v = ("FAIL", f"no frames in the last {stall_end:.1f} s of the run (the board stopped streaming); " + v[1])
    if (hl is not None and "watchdog_count" in board0 and "watchdog_count" in board1
            and board1["watchdog_count"] != board0["watchdog_count"]):
        v = ("FAIL", f"the board's producer watchdog stopped the data plane (WATCHDOG_COUNT "
                     f"{board0.get('watchdog_count')} -> {board1.get('watchdog_count')}); " + v[1])
    if err:
        v = ("FAIL", f"application error: {err[0]}; " + v[1])
    s = summary(c, stats, v)
    s["stop"] = stop_reason[0] if stop_reason else "frames done"
    s["stall_at_end_s"] = round(stall_end, 2) if stall_end is not None else None
    s["cpu"] = dict(process_cores=round(((r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime)) / wall, 2),
                    wall_s=round(wall, 2), steady_window=cpu)
    if c.source == "csynthetic" and app.src is not None:
        s["synthetic_source"] = app.src.stats()
    if hl is not None:
        s["board"] = dict(before=board0, after=board1, keepalive_ms=c.keepalive,
                          keepalive_writes=ka.writes if ka else 0, keepalive_errors=ka.errors if ka else 0)
        if board1.get("watchdog_count", 0) != board0.get("watchdog_count", 0):
            print(f"note: the board's producer watchdog fired during the run "
                  f"({board0.get('watchdog_count')} -> {board1.get('watchdog_count')})", flush=True)
    with open(c.json, "w") as f:
        json.dump(s, f, indent=1, default=str)
    print(json.dumps({k: s[k] for k in ("frames", "gbps", "checked", "error_frames", "lost", "psn_mismatch",
                                         "psn_sequence_errors", "overrun_frames", "resyncs", "checker_host_us_per_frame",
                                         "checker_gpu_us_per_frame", "start", "cpu")}, default=str))
    print(f"summary {c.json}")
    print(f"{v[0]}: {v[1]}", flush=True)
    return 0 if v[0] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
