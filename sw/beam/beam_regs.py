#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# beam_regs.py - register I/O of the beamforming demo (docs/source/beam_contract.md section 4):
# the Opsero BM registers of the 8 x 8 array generator (SOURCE = 2), written as ONE block-write
# request per scene change (the changed words, SCENE_ID, APPLY last), and the status registers.
#
#   BoardRegs  the board over the HSB register protocol (UDP 8192):
#              mode "block"  : our own ECB socket, command 0x09 WR_BLOCK (all pairs of a scene
#                              change in one request, APPLY last) and 0x19 RD_BLOCK. The classic
#                              hololink Python API has no block write (Hololink::WriteData is not
#                              bound), so the request is built here; the app's Hololink object then
#                              runs WITHOUT sequence checking (connect_classic below), else our
#                              requests would move the board's latched sequence under it.
#              mode "single" : one hl.write_uint32 per pair through the Hololink object (sequence
#                              checking kept). Atomic all the same: the words land in shadow
#                              registers and only APPLY (written last) stages them (contract 4.4);
#                              costs one round trip per pair.
#              With the module API (hololink_module) "block" uses HololinkInterfaceV1.write_uint32
#              with address / value lists (one batch).
#   SimRegs    the same interface in-process for the synthetic sources: a shadow register file
#              with the contract's APPLY semantics (snapshot at APPLY, a newer APPLY replaces a
#              pending one, activation at the next frame boundary the generator reaches,
#              APPLIED_ID / APPLIED_FRAME / APPLIES / PENDING) so that the app exercises the very
#              register encoding the FPGA decodes (Scene.from_registers on the snapshot).
#
# Keep all register traffic of the beam app in this file (the hardware milestone fixes it here).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import socket
import struct
import threading
import time

import beam_scene as bs

WR_BLOCK, RD_BLOCK = 0x09, 0x19
FLAG_ACK = 0x01
MAX_PAIRS = 183                    # firmware limit per request (1472-byte control packet)
ST_NAMES = {0x00: "ok", 0x03: "bad address", 0x04: "bad command", 0x05: "bad length", 0x0B: "sequence"}


class RegError(RuntimeError):
    pass


class BoardRegs:
    """Opsero BM registers on the board. write_block(pairs) sends the pairs in order as one
    request (mode block) or pair by pair (mode single); returns the host monotonic time the
    reply arrived (t_apply of contract 6.7)."""

    def __init__(self, ip, hl, mode="block", port=8192, timeout_s=0.2, retries=3):
        self.ip, self.hl, self.mode = ip, hl, mode
        self.timeout_s, self.retries = timeout_s, retries
        self.module = hasattr(hl, "hl") and not hasattr(hl, "get_i2c")     # rocelet_hsb.ModuleRegisters
        self.lock = threading.Lock()
        self.sock = None
        self.seq = int(time.time()) & 0xFFFF
        self.requests = self.pairs = self.retried = 0
        self.rtt_us = []
        if mode == "block" and not self.module:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.sock.connect((ip, port))
            self.sock.settimeout(timeout_s)

    # ---- ECB transport (mode block, classic API) ----
    def _ecb(self, cmd, pairs):
        with self.lock:
            for attempt in range(self.retries + 1):
                self.seq = (self.seq + 1) & 0xFFFF
                req = struct.pack(">BBHBB", cmd, FLAG_ACK, self.seq, 0, 0) + b"".join(
                    struct.pack(">II", a, v & 0xFFFFFFFF) for a, v in pairs)
                t0 = time.monotonic()
                self.sock.send(req)
                try:
                    while True:
                        rep = self.sock.recv(2048)
                        if len(rep) >= 6 and rep[0] == (cmd | 0x80) and struct.unpack_from(">H", rep, 2)[0] == self.seq:
                            break                         # a late reply to an earlier attempt is skipped
                except socket.timeout:
                    self.retried += 1
                    continue
                t1 = time.monotonic()
                self.requests += 1
                self.rtt_us.append((t1 - t0) * 1e6)
                del self.rtt_us[:-200]
                st = rep[4]
                if st:
                    raise RegError(f"ECB 0x{cmd:02x} ({len(pairs)} pairs): status 0x{st:02x} ({ST_NAMES.get(st, '?')})")
                vals = [struct.unpack_from(">I", rep, 10 + 8 * i)[0] for i in range(len(pairs))]
                return t1, vals
        raise RegError(f"ECB 0x{cmd:02x} to {self.ip}: no reply after {self.retries + 1} attempts")

    def write_block(self, pairs):
        """Write (address, value) pairs in order; APPLY must be the last pair of a scene change."""
        pairs = [(int(a), int(v) & 0xFFFFFFFF) for a, v in pairs]
        if not pairs:
            return time.monotonic()
        self.pairs += len(pairs)
        t = time.monotonic()
        if self.mode == "block" and self.module:
            for i in range(0, len(pairs), MAX_PAIRS):
                chunk = pairs[i:i + MAX_PAIRS]
                r = self.hl.hl.write_uint32([a for a, _ in chunk], [v for _, v in chunk])
                if r not in (0, None):
                    raise RegError(f"module write_uint32 ({len(chunk)} pairs): status {r}")
            self.requests += 1
            return time.monotonic()
        if self.mode == "block":
            # one request per scene (102 pairs max); longer lists go in order, APPLY in the last chunk
            for i in range(0, len(pairs), MAX_PAIRS):
                t, _ = self._ecb(WR_BLOCK, pairs[i:i + MAX_PAIRS])
            return t
        for a, v in pairs:                  # mode single
            self.hl.write_uint32(a, v)
        self.requests += len(pairs)
        return time.monotonic()

    def read(self, addrs):
        addrs = list(addrs)
        if self.mode == "block" and not self.module:
            return self._ecb(RD_BLOCK, [(a, 0) for a in addrs])[1]
        return [self.hl.read_uint32(a) for a in addrs]

    def write(self, addr, value):
        return self.write_block([(addr, value)])

    def status(self):
        """S_BM_* (contract 4.5) as a dict."""
        st, aid, afr, n, caps = self.read([bs.OPS_BM_STATUS, bs.OPS_BM_APPLIED_ID, bs.OPS_BM_APPLIED_FRAME,
                                           bs.OPS_BM_APPLIES, bs.OPS_BM_CAPS])
        return dict(status=st, pending=bool(st & 1), running=bool(st & 2), clipped=bool(st & 4),
                    model_version=(st >> 8) & 0xFF, applied_id=aid, applied_frame=afr, applies=n, caps=caps)

    def frames_done(self):
        """OPS_FRAMES (0x7F000010): frames completed in the producer's current run (read right after an APPLY
        reply: the board's part of the scene-change latency in frames = scene_frame - this)."""
        return self.read([0x7F000010])[0]

    def caps(self):
        """S_BM_CAPS: 0x01440808 = generator present; 0 = mapped, no generator. A firmware without
        the mapping answers status 0x03 (RegError) - returned as None."""
        try:
            return self.read([bs.OPS_BM_CAPS])[0]
        except RegError:
            return None

    def link_gbps(self):
        """OPS_LINK_GBPS (0x7F000018): the board's link rate in Gb/s (100 KCU116, 40 ZCU106); None when the
        console predates the register (reads 0) or does not answer."""
        try:
            v = self.read([bs.OPS_LINK_GBPS])[0]
        except Exception:                     # RegError, or a module-API read error: treated as unknown
            return None
        return v if 0 < v <= 1000 else None

    def close(self):
        if self.sock is not None:
            self.sock.close()
            self.sock = None


class SimRegs:
    """In-process BM register file + the generator's APPLY / activation semantics (contract 4.4)
    for the synthetic sources. The generator calls frame_start(f) at the first beat of every frame:
    a staged scene becomes active there (scene_frame = f)."""

    def __init__(self):
        self.lock = threading.Lock()
        self.shadow = dict(bs.RESET_SCENE_REGS)
        self.staged = None
        self.active = bs.reset_scene()       # the reset scene, SCENE_ID 0 (as after an FPGA reset)
        self.applied_id, self.applied_frame, self.applies = 0, 0, 1
        self.running = False
        self.sink = None                     # callable(scene): hands a staged scene to an out-of-process generator
        self.requests = self.pairs = 0
        self.mode = "sim"

    def write_block(self, pairs):
        with self.lock:
            for a, v in pairs:
                a, v = int(a), int(v) & 0xFFFFFFFF
                if a == bs.OPS_BM_APPLY:
                    self.shadow[a] = v
                    self.staged = bs.Scene.from_registers(dict(self.shadow))   # snapshot at the APPLY write
                    if not self.running:                                      # idle: active at once
                        self._activate(0)
                    elif self.sink is not None:
                        self.sink(self.staged)
                elif bs.OPS_BM_BASE <= a < bs.OPS_BM_BASE + 0x200 and not a & 3:
                    self.shadow[a] = v
                elif a in (bs.OPS_SOURCE, bs.OPS_RATE_MBPS):    # no board pacing in the synthetic sources
                    pass
                else:
                    raise RegError(f"SimRegs: write to 0x{a:08x} (not a BM register)")
            self.requests += 1
            self.pairs += len(pairs)
        return time.monotonic()

    def _activate(self, f):
        self.active, self.staged = self.staged, None
        self.applied_id, self.applied_frame = self.active.scene_id, f
        self.applies += 1

    def frame_start(self, f):
        """-> (active scene, scene_frame) for frame f (activation of a staged scene happens here)."""
        with self.lock:
            if f == 0:
                self.running = True
                self.applied_frame = 0
            if self.staged is not None:
                self._activate(f)
            return self.active, self.applied_frame

    def activated(self, scene, f):
        """The out-of-process generator made `scene` active at frame f (seen in its first frame)."""
        with self.lock:
            if self.staged is not None and self.staged.scene_id <= scene.scene_id:
                self.staged = None
            self.active, self.applied_id, self.applied_frame = scene, scene.scene_id, f
            self.applies += 1

    def read(self, addrs):
        with self.lock:
            st = (1 if self.staged is not None else 0) | (2 if self.running else 0) | (bs.MODEL_VERSION << 8)
            m = {bs.OPS_BM_STATUS: st, bs.OPS_BM_APPLIED_ID: self.applied_id,
                 bs.OPS_BM_APPLIED_FRAME: self.applied_frame, bs.OPS_BM_APPLIES: self.applies,
                 bs.OPS_BM_CAPS: bs.CAPS_VALUE}
            return [m.get(a, self.shadow.get(a, 0)) for a in addrs]

    def write(self, addr, value):
        return self.write_block([(addr, value)])

    def status(self):
        st, aid, afr, n, caps = self.read([bs.OPS_BM_STATUS, bs.OPS_BM_APPLIED_ID, bs.OPS_BM_APPLIED_FRAME,
                                           bs.OPS_BM_APPLIES, bs.OPS_BM_CAPS])
        return dict(status=st, pending=bool(st & 1), running=bool(st & 2), clipped=False,
                    model_version=(st >> 8) & 0xFF, applied_id=aid, applied_frame=afr, applies=n, caps=caps)

    def caps(self):
        return bs.CAPS_VALUE

    def close(self):
        pass


def connect_classic(ip, mtu, deferred_start=True, sequence_check=True, timeout_s=10.0):
    """rocelet_hsb.connect() with one addition: sequence_check=False makes the Hololink object
    send its requests without the SEQUENCE_CHECK flag (needed when BoardRegs mode "block" talks
    to the board from its own socket). Returns (DataChannel, Hololink)."""
    import hololink as hololink_module
    import rocelet_hsb
    rocelet_hsb.set_strategy()
    md = hololink_module.Enumerator.find_channel(channel_ip=ip, timeout=hololink_module.Timeout(timeout_s))
    hololink_module.DataChannel.use_mtu(md, mtu)
    upd = {}
    if deferred_start:
        upd["vp_mask"] = 0
    if not sequence_check:
        upd["sequence_number_checking"] = 0
    if upd:
        md.update(hololink_module.Metadata(upd))
    dc = hololink_module.DataChannel(md)
    hl = dc.hololink()
    hl.start()
    return dc, hl
