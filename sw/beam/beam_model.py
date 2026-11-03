#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# beam_model.py - the bit-exact integer model of the qsfp28-fmc-rocelet 8 x 8 array generator
# (Opsero SOURCE = 2) and the float reference beamformers of the beamforming demo.
#
# The specification is docs/source/beam_contract.md (sections 2-3: packing and source model,
# section 6: GPU definitions). This file implements it and is the reference both the RTL
# (xsim, bit for bit) and the GPU application are tested against.
#
#   python3 sw/beam/beam_model.py --demo [--preset 2] [--out beam_demo.png]
#   python3 sw/beam/beam_model.py --dump-beats beats.hex --preset 2 --frame 0 --beats 4096
#   python3 sw/beam/beam_model.py --dump-regs --preset 2
#
# Integer notation (as the IQ16 model sw/hsb/rocelet_iq.py): rnd(x, s) = floor((x + 2^(s-1)) / 2^s), [a]_w = a mod 2^w.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import argparse
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from beam_scene import (BEATS_PER_T, LANES, N_EL, N_SRC, NX, NY, T_CW, T_FRAME, T_LFM, T_PULSE,  # noqa: E402
                        T_QPSK, TYPE_NAMES, Scene, preset, s32)

M32 = np.uint64(0xFFFFFFFF)
M48 = np.uint64((1 << 48) - 1)
QPSK_SALT = (0xB5297A4D, 0x1B56C4E9, 0x7F4A7C15, 0xD1B54A33)   # per source, XORed with NOISE_SEED
INV_SQRT2_Q16 = 46341                                         # round(2^16 / sqrt(2))

# IQ16_SIN_TAB (the IQ16 quarter-wave table, SIN_TAB of sw/hsb/rocelet_iq.py): TAB[i] = round(131071 sin(2 pi (i + 0.5) / 1024))
SIN_TAB = np.floor(131071 * np.sin(2 * np.pi * (np.arange(256) + 0.5) / 1024) + 0.5).astype(np.int64)


def rnd(x, s):
    """round(x / 2^s), ties toward +infinity (numpy >> on int64 is arithmetic)."""
    return (x + (1 << (s - 1))) >> s


def exp_phi(phi):
    """E(phi) of IQ16 (exp_phi of sw/hsb/rocelet_iq.py; 18-bit, scale 131071) for 32-bit phases -> (re, im) int64."""
    phi = np.asarray(phi, dtype=np.uint64) & M32
    p = (phi >> np.uint64(22)).astype(np.int64)
    quad, i = p >> 8, p & 255
    sb, cb = SIN_TAB[i], SIN_TAB[255 - i]
    c = np.select([quad == 0, quad == 1, quad == 2], [cb, -sb, -cb], sb)
    s = np.select([quad == 0, quad == 1, quad == 2], [sb, cb, -sb], -cb)
    d = (phi & np.uint64(0x3FFFFF)).astype(np.int64) - 0x200000
    th = (d * 411775) >> 18
    return c - rnd(s * th, 30), s + rnd(c * th, 30)


def lowbias32(x):
    x = np.asarray(x, dtype=np.uint32).copy()
    with np.errstate(over="ignore"):
        x ^= x >> np.uint32(16)
        x *= np.uint32(0x7FEB352D)
        x ^= x >> np.uint32(15)
        x *= np.uint32(0x846CA68B)
        x ^= x >> np.uint32(16)
    return x


def irwin_hall(h):
    h = h.astype(np.int64)
    return (h & 255) + ((h >> 8) & 255) + ((h >> 16) & 255) + ((h >> 24) & 255) - 510


# ---------------------------------------------------------------------------------------
# Section 3.2: per-scene constants
# ---------------------------------------------------------------------------------------
def element_ix_iy():
    k = np.arange(N_EL)
    return k % NX, k // NX


def steering_phase(scene):
    """phi[k, s] = [(2 ix - 7) U_s + (2 iy - 7) V_s]_32 as uint64 (64, 4)."""
    ix, iy = element_ix_iy()
    phi = np.zeros((N_EL, N_SRC), dtype=np.uint64)
    for s, src in enumerate(scene.sources):
        v = (2 * ix - (NX - 1)).astype(np.int64) * src.U + (2 * iy - (NY - 1)).astype(np.int64) * src.V
        phi[:, s] = (v & 0xFFFFFFFF).astype(np.uint64)
    return phi


def gain_table_int(scene):
    """(gI, gQ) int64 (64, 2) as the FPGA holds them (int16 Q2.14)."""
    w = np.array(scene.gain_words(), dtype=np.int64)
    gi, gq = w & 0xFFFF, (w >> 16) & 0xFFFF
    gi -= (gi >= 0x8000) * 0x10000
    gq -= (gq >= 0x8000) * 0x10000
    return np.stack([gi, gq], axis=1)


def steering_table(scene):
    """G[k, s, 0/1] (int64 (64, 4, 2), 20-bit signed): EN_k ? rnd(E(phi_ks) g_k, 14) : 0."""
    ec, es = exp_phi(steering_phase(scene))
    g = gain_table_int(scene)
    gi, gq = g[:, 0:1], g[:, 1:2]
    G = np.zeros((N_EL, N_SRC, 2), dtype=np.int64)
    G[:, :, 0] = rnd(ec * gi - es * gq, 14)
    G[:, :, 1] = rnd(ec * gq + es * gi, 14)
    en = np.array([(scene.enable >> k) & 1 for k in range(N_EL)], dtype=bool)
    G[~en] = 0
    return G


# ---------------------------------------------------------------------------------------
# Section 3.3: source waveforms w_s(n)
# ---------------------------------------------------------------------------------------
def waveforms(scene, n, n0=0):
    """w[t, s, 0/1] int64 (len(n), 4, 2) for the time indices n (uint64 array), scene active
    since time sample n0."""
    n = np.asarray(n, dtype=np.uint64)
    j = (n - np.uint64(n0)) & M32                      # j = [n - n0]_32
    w = np.zeros((len(n), N_SRC, 2), dtype=np.int64)
    with np.errstate(over="ignore"):
        for s, src in enumerate(scene.sources):
            a = src.amp & 0xFFFF
            inc = np.uint64(src.inc & 0xFFFFFFFF)
            m = j & np.uint64((1 << (src.pri_log2 & 31)) - 1)   # m = j mod 2^p
            gate = m < np.uint64(src.width & 0xFFFFFFFF)
            if src.type in (T_CW, T_PULSE):
                c, sn = exp_phi((inc * j) & M32)
                wi, wq = rnd(a * c, 17), rnd(a * sn, 17)
                if src.type == T_PULSE:
                    wi, wq = wi * gate, wq * gate
            elif src.type == T_LFM:
                tm = (m * (m - np.uint64(1))) >> np.uint64(1)          # m (m - 1) / 2, exact (m < 2^31)
                rate = np.uint64(src.rate & 0xFFFFFFFFFFFFFFFF)
                acc = ((inc << np.uint64(16)) * m + rate * tm) & M48
                c, sn = exp_phi(acc >> np.uint64(16))
                wi, wq = rnd(a * c, 17) * gate, rnd(a * sn, 17) * gate
            elif src.type == T_QPSK:
                sym = (j >> np.uint64(src.sym_log2 & 15)).astype(np.uint32)
                h = lowbias32(sym ^ np.uint32((scene.noise_seed ^ QPSK_SALT[s]) & 0xFFFFFFFF))
                sa = 1 - 2 * (h & np.uint32(1)).astype(np.int64)
                sb = 1 - 2 * ((h >> np.uint32(1)) & np.uint32(1)).astype(np.int64)
                c, sn = exp_phi((inc * j) & M32)
                a2 = rnd(a * INV_SQRT2_Q16, 16)
                wi, wq = rnd(a2 * (sa * c - sb * sn), 17), rnd(a2 * (sa * sn + sb * c), 17)
            else:
                continue
            w[:, s, 0], w[:, s, 1] = wi, wq
    return w


# ---------------------------------------------------------------------------------------
# Section 3.4: element samples
# ---------------------------------------------------------------------------------------
def noise(scene, n):
    """(nI, nQ) int64 (len(n), 64) of element noise; index m = 64 n + k from the run start."""
    n = np.asarray(n, dtype=np.uint64)
    m = n[:, None] * np.uint64(N_EL) + np.arange(N_EL, dtype=np.uint64)[None, :]
    with np.errstate(over="ignore"):
        key = np.uint64(scene.noise_seed & 0xFFFFFFFF) ^ (((m >> np.uint64(32)) * np.uint64(0x9E3779B9)) & M32)
    lo = ((m & M32) ^ key).astype(np.uint32)
    a = scene.noise_amp & 0xFFFF
    return rnd(irwin_hall(lowbias32(lo)) * a, 7), rnd(irwin_hall(lowbias32(lo ^ np.uint32(0x68E31DA4))) * a, 7)


def samples(scene, n_first, count, n0=0, G=None, return_clip=False):
    """Time samples n_first .. n_first + count - 1 of all 64 elements: int16 (count, 64, 2)
    (I, Q). n counts from 0 at the producer's run start; the scene is active since n0."""
    if G is None:
        G = steering_table(scene)
    n = np.uint64(n_first) + np.arange(count, dtype=np.uint64)
    w = waveforms(scene, n, n0)
    wi, wq = w[:, :, 0], w[:, :, 1]                      # (count, 4)
    gi, gq = G[:, :, 0].T, G[:, :, 1].T                  # (4, 64)
    si = rnd(wi @ gi - wq @ gq, 17)
    sq = rnd(wi @ gq + wq @ gi, 17)
    ni, nq = noise(scene, n)
    vi, vq = si + ni, sq + nq
    clip = bool(np.any((vi < -32768) | (vi > 32767) | (vq < -32768) | (vq > 32767)))
    x = np.empty((count, N_EL, 2), dtype=np.int16)
    x[:, :, 0] = np.clip(vi, -32768, 32767)
    x[:, :, 1] = np.clip(vq, -32768, 32767)
    return (x, clip) if return_clip else x


def generate_frame(scene, frame_index, t=T_FRAME, scene_frame=0, return_clip=False):
    """Frame `frame_index` (since the run start) of t time samples (frame bytes = 256 t) with
    `scene` active since frame `scene_frame` (n0 = scene_frame t): int16 (t, 64, 2)."""
    return samples(scene, frame_index * t, t, n0=scene_frame * t, return_clip=return_clip)


def frame_bytes(x):
    """The frame as the GPU receives it: little-endian, time-major, element-interleaved, I then Q."""
    return np.ascontiguousarray(x, dtype="<i2").tobytes()


def to_complex(x):
    """int16 (t, 64, 2) -> the 64 x t complex data matrix X (float64, full scale = 1)."""
    return (x[:, :, 0].astype(np.float64) + 1j * x[:, :, 1].astype(np.float64)).T / 32768.0


def beat_words(x):
    """The 64-byte beats of a frame as rows of 16 little-endian u32 words: beat b, lane L =
    element 16 (b mod 4) + L of time sample b // 4."""
    w = (x[:, :, 0].astype(np.int64) & 0xFFFF) | ((x[:, :, 1].astype(np.int64) & 0xFFFF) << 16)
    return w.reshape(-1, LANES).astype(np.uint32)


# ---------------------------------------------------------------------------------------
# Section 6: float reference beamformers (what the GPU computes)
# ---------------------------------------------------------------------------------------
def element_xy():
    ix, iy = element_ix_iy()
    return ix - (NX - 1) / 2, iy - (NY - 1) / 2


def steering_vector(u, v):
    """a(u, v): (64,) or (64, len(u)) complex, a_k = exp(j pi (x_k u + y_k v))."""
    x, y = element_xy()
    u, v = np.asarray(u, dtype=np.float64), np.asarray(v, dtype=np.float64)
    if u.ndim == 0:
        return np.exp(1j * np.pi * (x * u + y * v))
    return np.exp(1j * np.pi * (x[:, None] * u[None, :] + y[:, None] * v[None, :]))


def covariance(X):
    """R = X X^H / T for the 64 x T data matrix X."""
    return (X @ X.conj().T) / X.shape[1]


def sky_grid(g=128):
    """Cell centres u_i = -1 + (2 i + 1) / g (i = column, u to the right) and v_j (j = 0 at the
    bottom); returns (U, V, visible) as (g, g) arrays indexed [row, col] with row 0 = top (v max)."""
    c = -1 + (2 * np.arange(g) + 1) / g
    U, V = np.meshgrid(c, c[::-1])
    return U, V, (U ** 2 + V ** 2) <= 1.0


def conventional_map(R, g=128):
    """P_conv = a^H R a / N^2 over the sky grid; NaN outside the visible disc."""
    U, V, vis = sky_grid(g)
    A = steering_vector(U.ravel(), V.ravel())
    P = np.real(np.sum(A.conj() * (R @ A), axis=0)).reshape(g, g) / N_EL ** 2
    P[~vis] = np.nan
    return P


def loaded(R, loading=1e-3):
    """R + delta I, delta = loading x trace(R) / N."""
    return R + loading * np.real(np.trace(R)) / N_EL * np.eye(N_EL)


def mvdr_map(R, g=128, loading=1e-3):
    """P_mvdr = 1 / (a^H (R + delta I)^-1 a) over the sky grid; NaN outside the visible disc."""
    U, V, vis = sky_grid(g)
    A = steering_vector(U.ravel(), V.ravel())
    Ri = np.linalg.inv(loaded(R, loading))
    P = 1.0 / np.real(np.sum(A.conj() * (Ri @ A), axis=0)).reshape(g, g)
    P[~vis] = np.nan
    return P


def conventional_weights(u, v):
    return steering_vector(u, v) / N_EL


def mvdr_weights(R, u, v, loading=1e-3):
    a = steering_vector(u, v)
    ria = np.linalg.solve(loaded(R, loading), a)
    return ria / np.vdot(a, ria)


def beam_pattern(w, g=128):
    """|w^H a(u, v)|^2 over the sky grid (NaN outside the visible disc)."""
    U, V, vis = sky_grid(g)
    A = steering_vector(U.ravel(), V.ravel())
    B = (np.abs(w.conj() @ A) ** 2).reshape(g, g)
    B[~vis] = np.nan
    return B


def beam_output(X, w):
    """y = w^H X (length T)."""
    return w.conj() @ X


def beam_spectrum(X, w):
    """|FFT(y)|^2 / T^2 (rectangular window), fftshifted; bin b <-> INC = b 2^32 / T."""
    y = beam_output(X, w)
    return np.fft.fftshift(np.abs(np.fft.fft(y)) ** 2) / len(y) ** 2


def calibrate(R, u, v, enable=(1 << N_EL) - 1, iters=8):
    """Gain estimate from a single known source at (u, v): power iteration v <- R v / |R v|
    from v0 = a(u, v) (disabled elements zeroed), g_k = v_k / a_k, normalised to mean 1 over
    the enabled elements; disabled elements get 1. Correct the data with x_k / g_k."""
    en = np.array([(enable >> k) & 1 for k in range(N_EL)], dtype=bool)
    a = steering_vector(u, v)
    vec = np.where(en, a, 0)
    Rm = R * np.outer(en, en)
    for _ in range(iters):
        vec = Rm @ vec
        vec /= np.linalg.norm(vec)
    g = np.ones(N_EL, dtype=complex)
    g[en] = vec[en] / a[en]
    g[en] /= np.mean(g[en])
    return g


def apply_calibration(X, g):
    return X / g[:, None]


def peak_uv(P):
    """(u, v) of the largest finite cell of a sky map."""
    U, V, _ = sky_grid(P.shape[0])
    i = np.nanargmax(P)
    return U.ravel()[i], V.ravel()[i]


# ---------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------
def render_demo(scene, out, frame_index=0, g=128, loading=1e-3):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import LinearSegmentedColormap

    x, clip = generate_frame(scene, frame_index, return_clip=True)
    X = to_complex(x)
    R = covariance(X)
    maps = [("Conventional (Bartlett)", conventional_map(R, g)), ("MVDR (Capon)", mvdr_map(R, g, loading))]
    cmap = LinearSegmentedColormap.from_list("sky", ["#0b1730", "#1f4e8c", "#5b9bd5", "#cfe3f7"])
    cmap.set_bad("#000000")
    fig, axs = plt.subplots(1, 2, figsize=(12, 6.2), facecolor="#ffffff")
    for ax, (title, P) in zip(axs, maps):
        db = 10 * np.log10(P / np.nanmax(P))
        im = ax.imshow(np.clip(db, -40, 0), extent=(-1, 1, -1, 1), cmap=cmap, vmin=-40, vmax=0)
        for s, src in enumerate(scene.sources):
            if src.type == 0:
                continue
            jam = s >= 2
            ax.plot(src.u, src.v, marker="s" if jam else "o", ms=26, mfc="none", mec="#ffffff", mew=1.2)
            ax.annotate(f"{'jammer' if jam else 'emitter'} {s} ({TYPE_NAMES[src.type]})", (src.u, src.v),
                        xytext=(14, 12) if s % 2 == 0 else (14, -20), textcoords="offset points", color="#ffffff", fontsize=9)
        ax.set_title(title, fontsize=12)
        ax.set_xlabel("u")
        ax.set_ylabel("v")
        fig.colorbar(im, ax=ax, fraction=0.046, pad=0.03, label="dB re peak")
    fig.suptitle(f"8 x 8 array, preset '{scene.name}', frame {frame_index} (4096 samples)"
                 + (" - CLIPPED" if clip else ""), fontsize=13)
    fig.tight_layout()
    fig.savefig(out, dpi=100)
    return out


def main():
    ap = argparse.ArgumentParser(description="beamforming demo: bit-exact array model + reference beamformers")
    ap.add_argument("--demo", action="store_true", help="render conventional + MVDR sky maps to a PNG")
    ap.add_argument("--preset", type=int, default=2)
    ap.add_argument("--frame", type=int, default=0, help="frame index since the run start")
    ap.add_argument("--scene-frame", type=int, default=0, help="frame at which the scene became active")
    ap.add_argument("--out", default="beam_demo.png")
    ap.add_argument("--loading", type=float, default=1e-3)
    ap.add_argument("--dump-beats", metavar="FILE", help="write beats as $readmemh lines (128 hex digits, byte 63 first)")
    ap.add_argument("--beats", type=int, default=16384, help="beats to dump (from the frame's first beat)")
    ap.add_argument("--dump-regs", action="store_true", help="print the preset's register writes")
    ap.add_argument("--dump-table", action="store_true", help="print the preset's G[k][s] steering table")
    a = ap.parse_args()
    scene = preset(a.preset, scene_id=a.preset)
    if a.dump_regs:
        for adr, v in scene.to_registers():
            print(f"0x{adr:08X} 0x{v:08X}")
    if a.dump_table:
        G = steering_table(scene)
        for k in range(N_EL):
            print(f"k {k:2d} " + " ".join(f"({G[k, s, 0]:7d},{G[k, s, 1]:7d})" for s in range(N_SRC)))
    if a.dump_beats:
        t = -(-a.beats // BEATS_PER_T)
        x = samples(scene, a.frame * T_FRAME, t, n0=a.scene_frame * T_FRAME)
        bw = beat_words(x)[:a.beats]
        with open(a.dump_beats, "w") as f:
            for row in bw:
                f.write("".join(f"{int(wd):08x}" for wd in row[::-1]) + "\n")
        print(f"{a.dump_beats}: {len(bw)} beats, preset {a.preset}, frame {a.frame}, scene frame {a.scene_frame}")
    if a.demo:
        print(render_demo(scene, a.out, a.frame, loading=a.loading))
    if not (a.demo or a.dump_regs or a.dump_beats or a.dump_table):
        ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
