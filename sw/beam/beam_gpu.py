#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# beam_gpu.py - the GPU side of the beamforming demo (docs/source/beam_contract.md section 6) in
# CuPy, plus a bit-exact CUDA version of the array generator (contract section 5) for the app's
# fast synthetic source (--source csynthetic).
#
# Per frame (int16[4096][64][2] in GPU memory, the 1 MiB page as received):
#   X  = the 64 x T complex matrix, (I + jQ) / 32768, optionally calibrated X <- diag(1/g) X
#   R  = X X^H / T                                  (one CGEMM)
#   Bartlett P = a^H R a / N^2 over the G x G sky   (one CGEMM 64 x 64 x G^2 + a reduction)
#   MVDR     P = 1 / a^H (R + d I)^-1 a, d = loading tr(R) / N  (64 x 64 inverse in complex128)
#   steered beam at (u0, v0): w (conventional a / N or MVDR), pattern |w^H a|^2 over the sky,
#   y = w^H X, spectrum |FFT(y)|^2 / T^2 fftshifted
#   calibration: beam_model.calibrate() (power iteration, contract 6.6) on the raw R
# The reference is beam_model.py (float64 numpy); tests/test_beam_gpu.py compares.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import math

import cupy as cp
import numpy as np

import beam_model as bm
import beam_scene as bs

N_EL = bs.N_EL

_SRC = r"""
extern "C" __global__ void unpack(const short2* __restrict__ in, const float2* __restrict__ ginv,
                                  float2* __restrict__ out, int n)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    short2 s = in[i];
    float2 g = ginv[i & 63];
    float a = s.x * (1.0f / 32768.0f), b = s.y * (1.0f / 32768.0f);
    out[i] = make_float2(a * g.x - b * g.y, a * g.y + b * g.x);
}

__device__ __forceinline__ unsigned lowbias32(unsigned x)
{
    x ^= x >> 16; x *= 0x7FEB352Du; x ^= x >> 15; x *= 0x846CA68Bu; x ^= x >> 16;
    return x;
}

__device__ __forceinline__ int irwin_hall(unsigned h)
{
    return (int)(h & 255u) + (int)((h >> 8) & 255u) + (int)((h >> 16) & 255u) + (int)(h >> 24) - 510;
}

__device__ __forceinline__ short sat16(long long v)
{
    return (short)(v < -32768 ? -32768 : (v > 32767 ? 32767 : v));
}

// contract 5.4 / 5.5: one element sample per thread; w = waveforms [T][4] (I, Q), G = steering
// table [64][4] (I, Q) of the active scene; time sample n = n_first + t; noise at m = 64 n + k
extern "C" __global__ void beam_gen(short2* __restrict__ out, const int2* __restrict__ w,
                                    const int2* __restrict__ G, unsigned long long n_first,
                                    unsigned seed, int namp, int T)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= T * 64) return;
    int t = i >> 6, k = i & 63;
    long long si = 0, sq = 0;
#pragma unroll
    for (int s = 0; s < 4; s++) {
        int2 ws = w[t * 4 + s];
        int2 g = G[k * 4 + s];
        si += (long long)ws.x * g.x - (long long)ws.y * g.y;
        sq += (long long)ws.x * g.y + (long long)ws.y * g.x;
    }
    long long ri = (si + 65536) >> 17, rq = (sq + 65536) >> 17;
    unsigned long long m = (n_first + (unsigned long long)t) * 64ull + (unsigned long long)k;
    unsigned key = seed ^ (unsigned)((m >> 32) * 0x9E3779B9ull);
    unsigned lo = (unsigned)m ^ key;
    long long ni = ((long long)irwin_hall(lowbias32(lo)) * namp + 64) >> 7;
    long long nq = ((long long)irwin_hall(lowbias32(lo ^ 0x68E31DA4u)) * namp + 64) >> 7;
    out[i] = make_short2(sat16(ri + ni), sat16(rq + nq));
}
"""

_mod = None


def kernel(name):
    global _mod
    if _mod is None:
        _mod = cp.RawModule(code=_SRC, options=("--std=c++17",))
    return _mod.get_function(name)


class BeamGpu:
    """The per-frame beamformer. All maps are (g, g) float32 on the GPU, row 0 = top (v max),
    NaN outside the visible disc (contract 6.3)."""

    def __init__(self, g=128, t=bs.T_FRAME, loading=1e-3):
        self.g, self.t, self.loading = g, t, loading
        U, V, vis = bm.sky_grid(g)
        self.U, self.V, self.vis_np = U, V, vis
        A = bm.steering_vector(U.ravel(), V.ravel())            # (64, g^2) complex128
        self.A_full = cp.asarray(A.astype(np.complex64))
        self.A = self.A_full
        self.Ac = cp.conj(self.A)
        self.mask_key = (1 << N_EL) - 1                         # element-enable mask the steering matrix is built for
        self.en = np.ones(N_EL, dtype=bool)
        self.en_f = cp.ones(N_EL, dtype=cp.float32)
        self.n_en = N_EL
        self.vis = cp.asarray(vis)
        self.nan_out = cp.where(self.vis, cp.float32(0), cp.float32(np.nan)).reshape(g, g)
        self.Xt = cp.zeros((t, N_EL), dtype=cp.complex64)       # X^T: row t = time sample, col k = element
        self.ginv = cp.ones(N_EL, dtype=cp.complex64)
        self.ones = cp.ones(N_EL, dtype=cp.complex64)
        self.k_unpack = kernel("unpack")
        self.R = None
        self.Ri = None

    def set_mask(self, enable):
        """Restrict the beamformer to the enabled elements (the frame's ELEM_EN): a disabled element carries
        only noise, and steering vectors that still include it made MVDR null its own source (preset 4:
        peak -23.7 dB re element power instead of -7.8 dB). Rows of A for disabled elements are zeroed (the
        conventional and MVDR maps, weights and pattern then use the sub-array; R itself is unchanged:
        the zeroed steering entries drop its disabled rows and columns from every quadratic form).
        Rebuilt only when the mask changes."""
        enable &= (1 << N_EL) - 1
        if enable == self.mask_key:
            return
        en = np.array([(enable >> k) & 1 for k in range(N_EL)], dtype=bool)
        if not en.any():
            en[:] = True                                        # nothing enabled: keep the full model
        self.en, self.n_en, self.mask_key = en, int(en.sum()), enable
        self.en_f = cp.asarray(en.astype(np.float32))
        self.A = self.A_full if en.all() else self.A_full * self.en_f.astype(cp.complex64)[:, None]
        self.Ac = cp.conj(self.A)

    # ---- data ----
    def unpack(self, frame, calibrated=True):
        """frame: a device pointer (int) or a CuPy uint8/int16 array of the 1 MiB frame -> self.Xt."""
        if isinstance(frame, int):
            mem = cp.cuda.UnownedMemory(frame, self.t * N_EL * 4, owner=None)
            frame = cp.ndarray((self.t * N_EL * 2,), dtype=cp.int16, memptr=cp.cuda.MemoryPointer(mem, 0))
        n = self.t * N_EL
        g = self.ginv if calibrated else self.ones
        self.k_unpack(((n + 255) // 256,), (256,), (frame, g, self.Xt, np.int32(n)))
        return self.Xt

    def set_calibration(self, g):
        """g: 64 complex gains (None = off); the data is corrected X <- X / g."""
        self.ginv = cp.asarray((1.0 / np.asarray(g, dtype=np.complex128)).astype(np.complex64)) if g is not None \
            else cp.ones(N_EL, dtype=cp.complex64)

    def covariance(self):
        """R[k, l] = sum_t X[k, t] conj(X[l, t]) / T, accumulated in complex128 (0.3 ms on the RTX PRO
        4000; a complex64 CGEMM over 4096 samples has a 2e-6 relative error that the MVDR inverse
        amplifies to 0.4 % in the weights and > 1 dB in the deep pattern regions)."""
        X64 = self.Xt.astype(cp.complex128)
        self.R = cp.matmul(X64.T, cp.conj(X64)) / float(self.t)
        self.R32 = self.R.astype(cp.complex64)
        self.Ri = None
        return self.R

    def _loaded_inverse(self):
        if self.Ri is None:
            R = self.R
            d = self.loading * float(cp.real(cp.trace(R))) / N_EL
            R = R + d * cp.eye(N_EL, dtype=cp.complex128)
            self.Ri = cp.linalg.inv(R)
            self.Ri32 = self.Ri.astype(cp.complex64)
        return self.Ri

    # ---- sky maps ----
    def conventional_map(self):
        RA = cp.matmul(self.R32, self.A)
        P = cp.sum(self.Ac * RA, axis=0).real / np.float32(self.n_en ** 2)
        return P.reshape(self.g, self.g) + self.nan_out

    def mvdr_map(self):
        self._loaded_inverse()
        RiA = cp.matmul(self.Ri32, self.A)
        P = 1.0 / cp.sum(self.Ac * RiA, axis=0).real
        return P.reshape(self.g, self.g).astype(cp.float32) + self.nan_out

    def element_power(self):
        """Mean power of the enabled elements (0-d CuPy array, no host sync): the absolute reference of the
        MVDR display (db_ref)."""
        return (cp.sum(cp.real(cp.diagonal(self.R32)) * self.en_f) / np.float32(self.n_en)).astype(cp.float32)

    def sky(self, beamformer):
        return self.mvdr_map() if beamformer == "mvdr" else self.conventional_map()

    # ---- steered beam ----
    def weights(self, u, v, beamformer):
        a = bm.steering_vector(u, v) * self.en
        if beamformer == "mvdr":
            Ri = self._loaded_inverse()
            ag = cp.asarray(a)
            ria = Ri @ ag
            w = ria / cp.vdot(ag, ria)
            return w.astype(cp.complex64)
        return cp.asarray((a / self.n_en).astype(np.complex64))

    def pattern(self, w):
        B = cp.abs(cp.matmul(cp.conj(w), self.A)) ** 2
        return B.reshape(self.g, self.g).astype(cp.float32) + self.nan_out

    def spectrum(self, w):
        y = cp.matmul(self.Xt, cp.conj(w))                       # y[t] = sum_k conj(w_k) X[k, t]
        Y = cp.fft.fft(y)
        return cp.fft.fftshift((Y.real ** 2 + Y.imag ** 2) / np.float32(self.t) ** 2)

    def calibrate(self, u, v, enable):
        """Gain estimate (contract 6.6) from the RAW covariance of the current frame (call after
        unpack(calibrated=False) + covariance()); returns numpy complex128 (64,)."""
        return bm.calibrate(cp.asnumpy(self.R), u, v, enable)


def db_norm(P, floor_db=-40.0):
    """10 log10(P / max P) clipped to [floor, 0], scaled to [0, 1]; NaN (outside) -> 0. Returns
    (q map float32, index of the max in the flattened map)."""
    i = cp.nanargmax(P)
    m = P.ravel()[i]
    db = 10.0 * cp.log10(cp.maximum(P / m, 1e-12))
    q = cp.clip((db - floor_db) / -floor_db, 0.0, 1.0)
    q = cp.where(cp.isnan(P), cp.float32(0), q).astype(cp.float32)
    return q, i


def db_ref(P, ref, floor_db=-40.0):
    """As db_norm, but 10 log10(P / ref) for a given reference power (a CuPy 0-d array or a float):
    an absolute scale. The app shows the MVDR map against the frame's mean element power
    (element_power()), which is within ~0.5 dB of the conventional peak in presets 1, 2, 4, 5: a
    self-nulled MVDR map (uncalibrated array, preset 5) then shows dark with its residual structure
    instead of a per-map normalised flat bright disc (B5). Returns (q map float32, index of the max)."""
    i = cp.nanargmax(P)
    db = 10.0 * cp.log10(cp.maximum(P / ref, 1e-12))
    q = cp.clip((db - floor_db) / -floor_db, 0.0, 1.0)
    q = cp.where(cp.isnan(P), cp.float32(0), q).astype(cp.float32)
    return q, i


class GpuGenerator:
    """Bit-exact array generator on the GPU (contract 5): waveforms w_s(n) on the host (numpy,
    beam_model.waveforms: 4096 x 4 values), steering table G per scene, element samples + noise in
    one kernel straight into the frame buffer. Matches beam_model.generate_frame() bit for bit."""

    def __init__(self, t=bs.T_FRAME):
        self.t = t
        self.k = kernel("beam_gen")
        self.G_key = None
        self.G = None

    def frame(self, out_ptr, scene, frame_index, scene_frame):
        key = (id(scene), scene.scene_id)
        if key != self.G_key:
            self.G = cp.asarray(bm.steering_table(scene).astype(np.int32))      # (64, 4, 2)
            self.G_key = key
        n = np.uint64(frame_index * self.t) + np.arange(self.t, dtype=np.uint64)
        w = cp.asarray(bm.waveforms(scene, n, scene_frame * self.t).astype(np.int32))   # (T, 4, 2)
        mem = cp.cuda.UnownedMemory(out_ptr, self.t * N_EL * 4, owner=None)
        out = cp.ndarray((self.t * N_EL * 2,), dtype=cp.int16, memptr=cp.cuda.MemoryPointer(mem, 0))
        nt = self.t * N_EL
        self.k(((nt + 255) // 256,), (256,), (out, w, self.G, np.uint64(frame_index * self.t),
                                              np.uint32(scene.noise_seed & 0xFFFFFFFF),
                                              np.int32(scene.noise_amp & 0xFFFF), np.int32(self.t)))


def peak_uv(i, g):
    """(u, v) of the flattened sky-map index i (row 0 = top)."""
    r, c = divmod(int(i), g)
    return -1 + (2 * c + 1) / g, 1 - (2 * r + 1) / g


def uv_dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])
