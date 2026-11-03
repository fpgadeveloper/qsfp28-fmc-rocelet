#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# beam_scene.py - the scene of the qsfp28-fmc-rocelet beamforming demo (8 x 8 array generator,
# Opsero SOURCE = 2) as a dataclass, its register encoding (the Opsero BM registers that the
# host writes with the HSB register protocol, docs/source/beam_contract.md section 4), the
# demo presets (contract section 7), the metadata fields (contract section 3) and the gain-error
# helper used by the calibration scene.
#
# The register encoding is the specification the FPGA implements: to_registers() gives the
# (address, value) pairs of one atomic scene change, SCENE_ID and APPLY last.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

from dataclasses import dataclass, field
import math
import struct

import numpy as np

# ---------------- array ----------------
NX, NY = 8, 8                    # fixed (the beat packing relies on 64 elements = 4 beats)
N_EL = NX * NY
N_SRC = 4
LANES = 16                       # complex int16 samples per 64-byte beat
BEATS_PER_T = N_EL // LANES      # 4 beats per time sample
MODEL_VERSION = 1                # S_BM_CAPS[31:24]

# ---------------- source types ----------------
T_OFF, T_CW, T_LFM, T_QPSK, T_PULSE = 0, 1, 2, 3, 4
TYPE_NAMES = {T_OFF: "off", T_CW: "cw", T_LFM: "lfm", T_QPSK: "qpsk", T_PULSE: "pulse"}

# ---------------- Opsero registers (host side, HSB register protocol) ----------------
OPS_SOURCE = 0x7F000004          # 0 IQ16, 1 counter, 2 beam array generator
SOURCE_BEAM = 2
OPS_RATE_MBPS = 0x7F000008       # stream rate, Mb/s of frame + record (0 = unpaced); live: from the next frame start
OPS_BM_BASE = 0x7F000100         # 0x7F000100..0x7F0002FF <-> system window 0x0200..0x03FF (cfg 128..255)
OPS_BM_STAT_BASE = 0x7F000300    # 0x7F000300..0x7F000318 <-> system window 0x04E4..0x04FC (sv 57..63)


def OPS_BM_SRC(s):
    return OPS_BM_BASE + 0x20 * s


SRC_CTRL, SRC_AMP, SRC_INC, SRC_RATE_LO, SRC_RATE_HI, SRC_WIDTH, SRC_U, SRC_V = (0x00, 0x04, 0x08, 0x0C, 0x10,
                                                                                0x14, 0x18, 0x1C)
OPS_BM_NOISE_AMP = 0x7F000180
OPS_BM_NOISE_SEED = 0x7F000184
OPS_BM_EN_LO = 0x7F000188
OPS_BM_EN_HI = 0x7F00018C
OPS_BM_SCENE_ID = 0x7F000190
OPS_BM_APPLY = 0x7F000194


def OPS_BM_GAIN(k):
    return 0x7F000200 + 4 * k


OPS_BM_STATUS = 0x7F000300       # [0] apply pending [1] generator running [2] clipped (sticky) [15:8] model version
OPS_BM_APPLIED_ID = 0x7F000304
OPS_BM_APPLIED_FRAME = 0x7F000308
OPS_BM_APPLIES = 0x7F00030C
OPS_BM_CAPS = 0x7F000310
CAPS_VALUE = (MODEL_VERSION << 24) | (N_SRC << 20) | (4 << 16) | (NY << 8) | NX   # 0x01440808

# the system-window counterpart of an Opsero BM address (what the firmware does, nothing else)


def sys_addr(ops_addr):
    if OPS_BM_BASE <= ops_addr < OPS_BM_BASE + 0x200:
        return 0x0200 + (ops_addr - OPS_BM_BASE)
    if OPS_BM_STAT_BASE <= ops_addr < OPS_BM_STAT_BASE + 0x1C:
        return 0x04E4 + (ops_addr - OPS_BM_STAT_BASE)
    raise ValueError(f"0x{ops_addr:08x} is not a BM register")


# ---------------- metadata (bytes 48..63 of the 128-byte record, big-endian) ----------------
MD_SCENE_ID, MD_SCENE_FRAME, MD_FRAME_INDEX, MD_TAG = 48, 52, 56, 60
MD_TAG_BEAM = 0x424D0001         # "BM", layout 1


def parse_metadata(rec):
    """The HSB fields and the beam fields of a 128-byte metadata record (bytes-like)."""
    rec = bytes(rec)
    flags, psn, crc, ts_s, ts_ns, bw, _pad, fn16, md_s, md_ns = struct.unpack_from(">IIIQIQHHQI", rec, 0)
    sid, sfr, fidx, tag = struct.unpack_from(">IIII", rec, 48)
    return dict(flags=flags, psn=psn, crc=crc, timestamp_s=ts_s, timestamp_ns=ts_ns, bytes_written=bw,
                frame_number=fn16, metadata_s=md_s, metadata_ns=md_ns, scene_id=sid, scene_frame=sfr,
                frame_index=fidx, tag=tag, beam=(tag == MD_TAG_BEAM))


# ---------------- encodings ----------------
def q230(x):
    """Direction cosine -> the int32 register value round(x 2^30) (saturated to int32)."""
    v = int(math.floor(x * (1 << 30) + 0.5))
    return max(-(1 << 31), min((1 << 31) - 1, v))


def freq_inc(f_over_fs):
    """Frequency as a fraction of the per-element sample rate -> u32 phase increment."""
    return int(math.floor(f_over_fs * 2 ** 32 + 0.5)) & 0xFFFFFFFF


def bin_inc(b, t=4096):
    """The phase increment that puts a tone exactly on FFT bin b of a t-point transform."""
    return (int(b) * (2 ** 32 // t)) & 0xFFFFFFFF


def s32(x):
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x & 0x80000000 else x


def chirp_rate(start_inc, stop_inc, width):
    """r = trunc((stop - start) 2^16 / width), start/stop as signed int32 (as the IQ16 scene rates in hsb.c)."""
    if width == 0:
        return 0
    num = (s32(stop_inc) - s32(start_inc)) * 65536
    q = abs(num) // width
    return q if num >= 0 else -q


def gain_word(g):
    """Complex gain -> [15:0] I, [31:16] Q, int16 Q2.14 each (round to nearest, saturated)."""
    def q(x):
        return max(-32768, min(32767, int(math.floor(x * 16384 + 0.5))))
    return (q(g.real) & 0xFFFF) | ((q(g.imag) & 0xFFFF) << 16)


def gain_from_word(w):
    i, q = w & 0xFFFF, (w >> 16) & 0xFFFF
    i -= 0x10000 if i & 0x8000 else 0
    q -= 0x10000 if q & 0x8000 else 0
    return complex(i / 16384, q / 16384)


def random_gain_errors(seed=1, phase_deg=30.0, amp_db=1.5):
    """Deterministic per-element gain errors (the calibration scene): phase uniform in
    +-phase_deg, amplitude uniform in +-amp_db, from numpy's PCG64 with the given seed.
    Returned already quantised to Q2.14 (what the FPGA applies)."""
    rng = np.random.Generator(np.random.PCG64(seed))
    ph = np.deg2rad(rng.uniform(-phase_deg, phase_deg, N_EL))
    am = 10 ** (rng.uniform(-amp_db, amp_db, N_EL) / 20)
    return [gain_from_word(gain_word(complex(a * math.cos(p), a * math.sin(p)))) for a, p in zip(am, ph)]


# ---------------- scene ----------------
@dataclass
class Source:
    type: int = T_OFF            # 0 off, 1 CW, 2 LFM pulse, 3 QPSK, 4 pulsed tone (3 bits)
    amp: int = 0                 # u16, recommended <= 32767 (Q0.15 of full scale)
    inc: int = 0                 # u32 phase increment per time sample (2^32 = Fs)
    rate: int = 0                # LFM rate, 48-bit two's complement, 2^-16 phase units / sample^2
    pri_log2: int = 0            # PRI = 2^p samples (types 2, 4), 5 bits
    width: int = 0               # gate open while m < width (types 2, 4), u32
    sym_log2: int = 0            # QPSK: 2^L samples per symbol (type 3), 4 bits
    u: float = 0.0               # direction cosines; register = round(u 2^30)
    v: float = 0.0

    @property
    def U(self):
        return q230(self.u)

    @property
    def V(self):
        return q230(self.v)

    def ctrl(self):
        return (self.type & 7) | ((self.pri_log2 & 31) << 8) | ((self.sym_log2 & 15) << 16)


def _default_gains():
    return [1 + 0j] * N_EL


@dataclass
class Scene:
    sources: list = field(default_factory=lambda: [Source() for _ in range(N_SRC)])
    noise_amp: int = 0           # u16
    noise_seed: int = 0          # u32
    enable: int = (1 << N_EL) - 1   # bit k = element k enabled
    gains: list = field(default_factory=_default_gains)   # 64 complex (quantised to Q2.14 by the encoding)
    scene_id: int = 0            # u32
    name: str = ""

    def gain_words(self):
        return [gain_word(complex(g)) for g in self.gains]

    def copy(self):
        return Scene.from_registers(dict(self.to_registers(apply=False)), name=self.name)

    def to_registers(self, apply=True, gains=True):
        """The (Opsero address, value) pairs of this scene in write order: sources, array
        words, the gain table (gains=True), SCENE_ID, and APPLY (apply=True) last. Send them
        as ONE block-write request (command 0x09) so the change is atomic."""
        r = []
        for s, src in enumerate(self.sources):
            b = OPS_BM_SRC(s)
            r += [(b + SRC_CTRL, src.ctrl()), (b + SRC_AMP, src.amp & 0xFFFF), (b + SRC_INC, src.inc & 0xFFFFFFFF),
                  (b + SRC_RATE_LO, src.rate & 0xFFFFFFFF), (b + SRC_RATE_HI, (src.rate >> 32) & 0xFFFF),
                  (b + SRC_WIDTH, src.width & 0xFFFFFFFF), (b + SRC_U, src.U & 0xFFFFFFFF),
                  (b + SRC_V, src.V & 0xFFFFFFFF)]
        r += [(OPS_BM_NOISE_AMP, self.noise_amp & 0xFFFF), (OPS_BM_NOISE_SEED, self.noise_seed & 0xFFFFFFFF),
              (OPS_BM_EN_LO, self.enable & 0xFFFFFFFF), (OPS_BM_EN_HI, (self.enable >> 32) & 0xFFFFFFFF)]
        if gains:
            r += [(OPS_BM_GAIN(k), w) for k, w in enumerate(self.gain_words())]
        r.append((OPS_BM_SCENE_ID, self.scene_id & 0xFFFFFFFF))
        if apply:
            r.append((OPS_BM_APPLY, 1))
        return r

    def changed_registers(self, old, apply=True):
        """Only the words that differ from scene `old` (+ SCENE_ID, APPLY): attract mode / drags."""
        prev = dict(old.to_registers(apply=False))
        r = [(a, v) for a, v in self.to_registers(apply=False) if a != OPS_BM_SCENE_ID and prev.get(a) != v]
        r.append((OPS_BM_SCENE_ID, self.scene_id & 0xFFFFFFFF))
        if apply:
            r.append((OPS_BM_APPLY, 1))
        return r

    @classmethod
    def from_registers(cls, regs, name=""):
        """Inverse of to_registers(): regs maps Opsero address -> value (missing = reset value)."""
        dflt = dict(RESET_SCENE_REGS)
        g = lambda a: regs.get(a, dflt.get(a, 0)) & 0xFFFFFFFF   # noqa: E731
        srcs = []
        for s in range(N_SRC):
            b = OPS_BM_SRC(s)
            c = g(b + SRC_CTRL)
            rate = g(b + SRC_RATE_LO) | ((g(b + SRC_RATE_HI) & 0xFFFF) << 32)
            rate -= (1 << 48) if rate & (1 << 47) else 0
            srcs.append(Source(type=c & 7, amp=g(b + SRC_AMP) & 0xFFFF, inc=g(b + SRC_INC), rate=rate,
                               pri_log2=(c >> 8) & 31, width=g(b + SRC_WIDTH), sym_log2=(c >> 16) & 15,
                               u=s32(g(b + SRC_U)) / (1 << 30), v=s32(g(b + SRC_V)) / (1 << 30)))
        return cls(sources=srcs, noise_amp=g(OPS_BM_NOISE_AMP) & 0xFFFF, noise_seed=g(OPS_BM_NOISE_SEED),
                   enable=g(OPS_BM_EN_LO) | (g(OPS_BM_EN_HI) << 32),
                   gains=[gain_from_word(g(OPS_BM_GAIN(k))) for k in range(N_EL)],
                   scene_id=g(OPS_BM_SCENE_ID), name=name)


# ---------------- reset scene (the register reset values, contract 4.5) ----------------
def _reset_regs():
    # one CW emitter at boresight (source 0, Fs/16, amplitude 8000), noise 128, all elements on, gains 1
    s = Scene(noise_amp=128, noise_seed=0x5EED0000, name="reset")
    s.sources[0] = Source(type=T_CW, amp=8000, inc=0x10000000)
    r = []
    for i, st in enumerate(s.sources):
        b = OPS_BM_SRC(i)
        r += [(b + SRC_CTRL, st.ctrl()), (b + SRC_AMP, st.amp), (b + SRC_INC, st.inc), (b + SRC_RATE_LO, 0),
              (b + SRC_RATE_HI, 0), (b + SRC_WIDTH, 0), (b + SRC_U, 0), (b + SRC_V, 0)]
    r += [(OPS_BM_NOISE_AMP, 128), (OPS_BM_NOISE_SEED, 0x5EED0000), (OPS_BM_EN_LO, 0xFFFFFFFF),
          (OPS_BM_EN_HI, 0xFFFFFFFF), (OPS_BM_SCENE_ID, 0)]
    r += [(OPS_BM_GAIN(k), 0x00004000) for k in range(N_EL)]
    return r


RESET_SCENE_REGS = _reset_regs()


def reset_scene():
    """The scene in force after an FPGA reset (SCENE_ID 0), without any APPLY."""
    return Scene.from_registers({}, name="reset")


# ---------------- presets (contract section 7) ----------------
T_FRAME = 4096                   # time samples per 1 MiB frame


def preset(n, scene_id=0):
    """Demo presets 1-5 (keys 1-5 of the app). Frequencies are on exact FFT bins of 4096."""
    s = Scene(noise_seed=0x5EED0B00 + n, scene_id=scene_id)
    if n == 1:      # single emitter: CW tone
        s.name = "single emitter"
        s.noise_amp = 400
        s.sources[0] = Source(type=T_CW, amp=4000, inc=bin_inc(200), u=0.30, v=0.20)
    elif n == 2:    # emitter (LFM radar pulse) + QPSK jammer 18 dB stronger, on the emitter's
                    # conventional sidelobe (-18.8 dB): conventional hides the emitter, MVDR shows it
        s.name = "emitter + jammer"
        s.noise_amp = 300
        st, sp = freq_inc(-0.20), freq_inc(0.20)
        s.sources[0] = Source(type=T_LFM, amp=3000, inc=st, rate=chirp_rate(st, sp, 512), pri_log2=10, width=512,
                              u=-0.35, v=0.20)
        s.sources[2] = Source(type=T_QPSK, amp=24000, inc=bin_inc(410), sym_log2=1, u=0.275, v=0.10)
    elif n == 3:    # two emitters one half-power beamwidth apart (du = 0.22)
        s.name = "two emitters 1 beamwidth apart"
        s.noise_amp = 300
        s.sources[0] = Source(type=T_CW, amp=4000, inc=bin_inc(200), u=-0.11, v=0.10)
        s.sources[1] = Source(type=T_CW, amp=4000, inc=bin_inc(337), u=0.11, v=0.10)
    elif n == 4:    # failed elements + emitter
        s.name = "failed elements"
        s.noise_amp = 400
        s.sources[0] = Source(type=T_CW, amp=4000, inc=bin_inc(200), u=0.30, v=0.20)
        for k in FAILED_ELEMENTS:
            s.enable &= ~(1 << k)
    elif n == 5:    # uncalibrated array: one CW reference source + gain errors (calibration)
        s.name = "uncalibrated array"
        s.noise_amp = 300
        s.sources[0] = Source(type=T_CW, amp=4000, inc=bin_inc(200), u=0.0, v=0.0)
        s.gains = random_gain_errors(seed=1, phase_deg=30.0, amp_db=1.5)
    else:
        raise ValueError(f"no preset {n}")
    return s


FAILED_ELEMENTS = (3, 12, 21, 30, 46, 57)
PRESETS = (1, 2, 3, 4, 5)
