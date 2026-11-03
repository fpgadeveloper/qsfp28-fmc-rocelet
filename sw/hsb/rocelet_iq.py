#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# rocelet_iq.py - the IQ16 test signal of the qsfp28-fmc-rocelet HSB producer as a bit-exact
# numpy model, the four scenes as the firmware programs them (Vitis/common/src/hsb.c SCENE[]),
# and a sample-level check of a saved frame.
#
# This model is the bit-exact specification of the IQ16 signal (the RTL generator
# Vivado/src/hdl/iq16_gen.sv and the CUDA port in rocelet_hsb_kernels.cu follow it): tones by
# 16-lane decomposition, a sawtooth chirp, a stateless noise hash, saturation to int16; a
# sample is the little-endian u32 (uint16)I | (uint16)Q << 16. In the HSB producer the sample index n counts from 0 at the
# data-plane start (the scene is committed while the source is idle, so n0 = 0) and runs on
# across frames: frame number f (extended past 16 bits) holds samples [f S, f S + S), with
# S = frame bytes / 4.
#
#   python3 rocelet_iq.py --check frame.bin --frame-number 600 --scene 1
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import argparse
import sys

import numpy as np

LANES = 16
MASK48 = (1 << 48) - 1

# IQ16_SIN_TAB: TAB[i] = round(131071 sin(2 pi (i + 0.5) / 1024)), i = 0..255
SIN_TAB = np.array([
    402, 1206, 2011, 2815, 3619, 4422, 5226, 6030, 6833, 7636, 8439, 9241, 10043, 10845, 11646, 12447,
    13247, 14047, 14847, 15645, 16444, 17241, 18038, 18834, 19630, 20425, 21219, 22012, 22804, 23596, 24386, 25176,
    25965, 26753, 27540, 28325, 29110, 29894, 30676, 31457, 32238, 33016, 33794, 34571, 35346, 36119, 36892, 37663,
    38433, 39201, 39967, 40733, 41496, 42258, 43019, 43778, 44535, 45290, 46044, 46796, 47547, 48295, 49042, 49787,
    50530, 51271, 52010, 52748, 53483, 54216, 54947, 55676, 56403, 57128, 57851, 58572, 59290, 60006, 60720, 61432,
    62141, 62848, 63552, 64254, 64954, 65652, 66346, 67039, 67729, 68416, 69101, 69783, 70462, 71139, 71813, 72484,
    73153, 73819, 74482, 75143, 75800, 76455, 77107, 77756, 78402, 79045, 79685, 80322, 80956, 81587, 82215, 82839,
    83461, 84080, 84695, 85307, 85916, 86522, 87124, 87724, 88319, 88912, 89501, 90087, 90670, 91249, 91824, 92396,
    92965, 93530, 94092, 94650, 95205, 95756, 96303, 96847, 97387, 97923, 98456, 98985, 99510, 100032, 100550, 101064,
    101574, 102080, 102583, 103081, 103576, 104067, 104554, 105037, 105516, 105991, 106462, 106930, 107393, 107852,
    108307, 108758, 109204, 109647, 110086, 110520, 110950, 111377, 111798, 112216, 112630, 113039, 113444, 113844,
    114241, 114633, 115021, 115404, 115783, 116158, 116528, 116894, 117256, 117613, 117966, 118314, 118658, 118998,
    119332, 119663, 119989, 120310, 120627, 120939, 121247, 121550, 121849, 122143, 122432, 122717, 122997, 123273,
    123544, 123810, 124072, 124329, 124581, 124829, 125072, 125310, 125543, 125772, 125996, 126215, 126430, 126639,
    126844, 127045, 127240, 127431, 127617, 127798, 127974, 128145, 128312, 128473, 128630, 128782, 128930, 129072,
    129209, 129342, 129470, 129593, 129711, 129824, 129932, 130035, 130134, 130227, 130316, 130400, 130479, 130553,
    130622, 130686, 130745, 130799, 130848, 130893, 130932, 130967, 130996, 131021, 131041, 131056, 131065, 131070,
], dtype=np.int64)

# The scenes as the firmware commits them (hsb.c SCENE[]):
# tone phase increments (u32), tone amplitudes, chirp start increment (u32), chirp rate
# (signed, 2^-16 phase units per sample^2), chirp period (samples, 0 = off), chirp amplitude,
# noise amplitude, noise seed.
SCENES = {
    1: dict(name="survey", inc=[0xB3400000, 0xE1400000, 0x11E00000, 0x40000000], amp=[6000, 3000, 1500, 750],
            cstart=0x8CD00000, rate=105541, per=2400000000, camp=3000, namp=200, seed=0x5EED0001),
    2: dict(name="radar", inc=[0, 0, 0, 0], amp=[0, 0, 0, 0],
            cstart=0x99A00000, rate=93802085, per=2400000, camp=16000, namp=300, seed=0x5EED0002),
    3: dict(name="tones", inc=[0xA0000000, 0xE0000000, 0x20000000, 0x60000000], amp=[16000, 8000, 4000, 2000],
            cstart=0, rate=0, per=0, camp=0, namp=0, seed=0),
    4: dict(name="noise", inc=[0, 0, 0, 0], amp=[0, 0, 0, 0], cstart=0, rate=0, per=0, camp=0, namp=4000,
            seed=0x5EED0004),
}


def _rnd(x, s):
    """round(x / 2^s), ties toward +infinity (numpy >> on int64 is arithmetic = floor)."""
    return (x + (1 << (s - 1))) >> s


def exp_phi(phi):
    """E(phi), the IQ16 complex exponential (18-bit, scale 131071), for a uint64 array of 32-bit phases -> (re, im) int64."""
    phi = np.asarray(phi, dtype=np.uint64) & np.uint64(0xFFFFFFFF)
    p = (phi >> np.uint64(22)).astype(np.int64)
    quad, i = p >> 8, p & 255
    sb, cb = SIN_TAB[i], SIN_TAB[255 - i]
    c = np.select([quad == 0, quad == 1, quad == 2], [cb, -sb, -cb], sb)
    s = np.select([quad == 0, quad == 1, quad == 2], [sb, cb, -sb], -cb)
    d = (phi & np.uint64(0x3FFFFF)).astype(np.int64) - 0x200000
    th = (d * 411775) >> 18
    return c - _rnd(s * th, 30), s + _rnd(c * th, 30)


def plan(scene):
    """The per-lane tone coefficients C_t,k (computed by the generator at COMMIT) of a scene: int64 [4][16][2]."""
    cfg = SCENES[scene]
    ck = np.zeros((4, LANES, 2), dtype=np.int64)
    k = np.arange(LANES, dtype=np.uint64)
    for t in range(4):
        re, im = exp_phi(k * np.uint64(cfg["inc"][t]))
        ck[t, :, 0] = _rnd(cfg["amp"][t] * re, 9)
        ck[t, :, 1] = _rnd(cfg["amp"][t] * im, 9)
    return ck


def _hash(x):
    x = x.astype(np.uint32)
    x ^= x >> np.uint32(16)
    x *= np.uint32(0x7FEB352D)
    x ^= x >> np.uint32(15)
    x *= np.uint32(0x846CA68B)
    x ^= x >> np.uint32(16)
    return x


def _noise1(h, amp):
    h = h.astype(np.int64)
    u = (h & 255) + ((h >> 8) & 255) + ((h >> 16) & 255) + ((h >> 24) & 255) - 510
    return _rnd(u * amp, 7)


def samples(scene, n_first, count, ck=None):
    """Samples n_first .. n_first + count - 1 (n0 = 0) as little-endian u32 words (numpy uint32)."""
    cfg = SCENES[scene]
    if ck is None:
        ck = plan(scene)
    n = np.uint64(n_first) + np.arange(count, dtype=np.uint64)
    q = n >> np.uint64(4)
    k = (n & np.uint64(15)).astype(np.int64)
    si = np.zeros(count, dtype=np.int64)
    sq = np.zeros(count, dtype=np.int64)
    with np.errstate(over="ignore"):
        for t in range(4):
            if cfg["amp"][t] == 0:
                continue
            base = ((np.uint64(cfg["inc"][t]) << np.uint64(4)) & np.uint64(0xFFFFFFFF)) * q
            bc, bs = exp_phi(base)
            cr, cim = ck[t, k, 0], ck[t, k, 1]
            si += _rnd(bc * cr - bs * cim, 25)
            sq += _rnd(bc * cim + bs * cr, 25)
        if cfg["per"] and cfg["camp"]:
            m = n % np.uint64(cfg["per"])
            odd = (m & np.uint64(1)) == np.uint64(1)
            tm = np.where(odd, m * ((m - np.uint64(1)) >> np.uint64(1)), (m >> np.uint64(1)) * (m - np.uint64(1)))
            rate = np.uint64(cfg["rate"] & 0xFFFFFFFFFFFFFFFF)
            acc = ((np.uint64(cfg["cstart"]) << np.uint64(16)) * m + rate * tm) & np.uint64(MASK48)
            er, ei = exp_phi(acc >> np.uint64(16))
            si += _rnd(cfg["camp"] * er, 17)
            sq += _rnd(cfg["camp"] * ei, 17)
        if cfg["namp"]:
            key = (np.uint64(cfg["seed"]) ^ (((n >> np.uint64(32)) * np.uint64(0x9E3779B9)) & np.uint64(0xFFFFFFFF)))
            lo = ((n & np.uint64(0xFFFFFFFF)) ^ key).astype(np.uint32)
            si += _noise1(_hash(lo), cfg["namp"])
            sq += _noise1(_hash(lo ^ np.uint32(0x68E31DA4)), cfg["namp"])
    i16 = np.clip(si, -32768, 32767).astype(np.int64) & 0xFFFF
    q16 = np.clip(sq, -32768, 32767).astype(np.int64) & 0xFFFF
    return (i16 | (q16 << 16)).astype(np.uint32)


def check_frame(data, frame_number, scene, chunk=1 << 16):
    """Compare a frame's bytes with the model; returns (mismatching samples, first index or -1)."""
    w = np.frombuffer(data, dtype="<u4")
    s = len(w)
    ck = plan(scene)
    bad, first = 0, -1
    for o in range(0, s, chunk):
        ref = samples(scene, frame_number * s + o, min(chunk, s - o), ck)
        d = np.nonzero(w[o:o + len(ref)] != ref)[0]
        if len(d):
            bad += len(d)
            if first < 0:
                first = o + int(d[0])
    return bad, first


def main():
    ap = argparse.ArgumentParser(description="IQ16 model check of a saved HSB frame")
    ap.add_argument("--check", required=True, help="frame file (frame bytes, no metadata)")
    ap.add_argument("--frame-number", type=int, required=True, help="frame number since the data-plane start")
    ap.add_argument("--scene", type=int, default=1, choices=sorted(SCENES))
    ap.add_argument("--search", type=int, default=0, help="if no match, also try frame numbers +-N")
    a = ap.parse_args()
    data = open(a.check, "rb").read()
    s = len(data) // 4
    i = np.frombuffer(data, dtype="<i2")[0::2]
    q = np.frombuffer(data, dtype="<i2")[1::2]
    print(f"{a.check}: {len(data)} B = {s} samples, I {i.min()}..{i.max()} rms {np.sqrt(np.mean(i.astype(float) ** 2)):.0f}, "
          f"Q {q.min()}..{q.max()} rms {np.sqrt(np.mean(q.astype(float) ** 2)):.0f}")
    for f in [a.frame_number] + [a.frame_number + d for r in range(1, a.search + 1) for d in (-r, r)]:
        bad, first = check_frame(data, f, a.scene)
        print(f"scene {a.scene} ({SCENES[a.scene]['name']}), frame {f} = samples {f * s}..{f * s + s - 1}: "
              f"{s - bad} of {s} samples match the model" + (f", first mismatch at {first}" if bad else " (bit-exact)"))
        if not bad:
            return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
