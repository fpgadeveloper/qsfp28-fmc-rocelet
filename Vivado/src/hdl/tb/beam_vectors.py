#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# beam_vectors.py OUTDIR [--t T] - expected beats for the xsim testbenches of the beam array
# generator (rsys_beam_src), from the bit-exact reference model sw/beam/beam_model.py:
#
#   beam_regs.hex   the 128 shadow words cfg[128..255] of presets 1, 2, 3, 5 (in that order,
#                   SCENE_ID = preset number), one 32-bit word per line ($readmemh)
#   beam_exp.hex    tb_beam_src, run 1: frames 0-1 preset 1 (applied while idle, n0 = 0),
#                   frames 2-3 preset 2 (mid-run APPLY, active at frame 2: n0 = 2T),
#                   frames 4-5 preset 5 (active at frame 4: n0 = 4T); T time samples per frame
#   beam_seek.hex   tb_beam_src, run 2: one frame of preset 5 from the noise index of
#                   n = 2^26 - 512 (crosses m[63:32] = 0 -> 1), waveforms from j = 0
#   beam_reset.hex  tb_rocelet_sys 'hsbbm': the reset scene (no BM write) from n = 0, 384 beats
# Beats are $readmemh lines of 128 hex digits (byte 63 first), as beam_model.py --dump-beats.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "..", "..", "sw", "beam")))
import numpy as np  # noqa: E402
from beam_model import beat_words, samples  # noqa: E402
from beam_scene import OPS_BM_BASE, preset, reset_scene  # noqa: E402

SEEK_N = (1 << 26) - 512


def write_beats(path, x):
    bw = beat_words(x)
    with open(path, "w") as f:
        for row in bw:
            f.write("".join(f"{int(w):08x}" for w in row[::-1]) + "\n")
    return len(bw)


def shadow_words(scene):
    w = [0] * 128
    reset = dict((a, v) for a, v in reset_scene().to_registers(apply=False))
    for a, v in reset.items():
        w[(a - OPS_BM_BASE) // 4] = v
    for a, v in scene.to_registers(apply=False):
        w[(a - OPS_BM_BASE) // 4] = v
    return w


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--t", type=int, default=4096, help="time samples per frame (frame bytes / 256)")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    t = a.t
    p = {n: preset(n, scene_id=n) for n in (1, 2, 3, 5)}
    with open(os.path.join(a.out, "beam_regs.hex"), "w") as f:
        for n in (1, 2, 3, 5):
            for w in shadow_words(p[n]):
                f.write(f"{w:08x}\n")
    plan = [(1, 0), (1, 0), (2, 2), (2, 2), (5, 4), (5, 4)]          # (preset, activation frame) per frame
    x = np.concatenate([samples(p[n], fi * t, t, n0=af * t) for fi, (n, af) in enumerate(plan)])
    nb = write_beats(os.path.join(a.out, "beam_exp.hex"), x)
    ns = write_beats(os.path.join(a.out, "beam_seek.hex"), samples(p[5], SEEK_N, t, n0=SEEK_N))
    nr = write_beats(os.path.join(a.out, "beam_reset.hex"), samples(reset_scene(), 0, 96, n0=0))
    print(f"{a.out}: T {t}, beam_exp {nb} beats, beam_seek {ns}, beam_reset {nr}, beam_regs 4 x 128 words")
    return 0


if __name__ == "__main__":
    sys.exit(main())
