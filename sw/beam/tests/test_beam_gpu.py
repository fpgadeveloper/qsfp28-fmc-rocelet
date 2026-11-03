#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# GPU beamformer (beam_gpu.py) against the float reference of beam_model.py on model frames, and
# the CUDA generator against beam_model.generate_frame() bit for bit. Needs a GPU + CuPy (run in
# the hololink-demo container):
#   python3 -m unittest -v tests/test_beam_gpu.py          (from sw/beam)
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import sys
import time
import unittest

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import cupy as cp  # noqa: E402

import beam_gpu as bg  # noqa: E402
import beam_model as bm  # noqa: E402
import beam_scene as bs  # noqa: E402

G = 128


def db(P, ref):
    return 10 * np.log10(np.maximum(P, 1e-30) / ref)


class Frames:
    cache = {}

    @classmethod
    def get(cls, p, f=0):
        if (p, f) not in cls.cache:
            cls.cache[(p, f)] = bm.generate_frame(bs.preset(p, scene_id=p), f)
        return cls.cache[(p, f)]


class TestBeamGpu(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bf = bg.BeamGpu(g=G)

    def load(self, p, f=0, calibrated=False):
        x = Frames.get(p, f)
        d = cp.asarray(np.frombuffer(bm.frame_bytes(x), dtype=np.uint8))
        self.bf.unpack(d, calibrated=calibrated)
        self.bf.covariance()
        return bm.to_complex(x)

    def assert_map(self, Pg, Pm, tol_db, floor_db=-40, what=""):
        Pg = cp.asnumpy(Pg).astype(np.float64)
        vis = ~np.isnan(Pm)
        self.assertTrue(np.array_equal(vis, ~np.isnan(Pg)), f"{what}: visible masks differ")
        mg, mm = np.nanmax(Pg), np.nanmax(Pm)
        self.assertLess(abs(10 * np.log10(mg / mm)), tol_db, f"{what}: peak level")
        dm, dg = db(Pm, mm), db(Pg, mm)
        sel = vis & (dm > floor_db)
        err = np.max(np.abs(dm[sel] - dg[sel]))
        self.assertLess(err, tol_db, f"{what}: max dB error {err:.4f} over {sel.sum()} cells")
        self.assertEqual(np.nanargmax(Pg), np.nanargmax(Pm), f"{what}: peak cell differs")
        return err

    def test_unpack_and_covariance(self):
        for p in (1, 2, 5):
            X = self.load(p)
            Xt = cp.asnumpy(self.bf.Xt)
            self.assertLess(np.max(np.abs(Xt.T - X)), 1e-6)
            R = bm.covariance(X)
            Rg = cp.asnumpy(self.bf.R)
            self.assertLess(np.max(np.abs(Rg - R)) / np.max(np.abs(R)), 1e-12, f"preset {p}")

    def test_conventional_map(self):
        for p in bs.PRESETS:
            X = self.load(p)
            self.assert_map(self.bf.conventional_map(), bm.conventional_map(bm.covariance(X), G), 0.01,
                            what=f"conventional preset {p}")

    def test_mvdr_map(self):
        for p in bs.PRESETS:
            X = self.load(p)
            self.assert_map(self.bf.mvdr_map(), bm.mvdr_map(bm.covariance(X), G), 0.05, what=f"mvdr preset {p}")

    def test_pattern_and_spectrum(self):
        X = self.load(2)
        R = bm.covariance(X)
        for (u, v) in ((-0.35, 0.20), (0.275, 0.10), (0.0, 0.0), (0.5, -0.4)):
            for bf_name in ("conv", "mvdr"):
                w = self.bf.weights(u, v, bf_name)
                wm = bm.mvdr_weights(R, u, v) if bf_name == "mvdr" else bm.conventional_weights(u, v)
                tol = 1e-5
                self.assertLess(np.max(np.abs(cp.asnumpy(w) - wm)) / np.max(np.abs(wm)), tol)
                self.assert_map(self.bf.pattern(w), bm.beam_pattern(wm, G), 0.05, floor_db=-50,
                                what=f"pattern {bf_name} ({u}, {v})")
                S = cp.asnumpy(self.bf.spectrum(w)).astype(np.float64)
                Sm = bm.beam_spectrum(X, wm)
                sel = db(Sm, Sm.max()) > -60
                err = np.max(np.abs(db(S[sel], Sm.max()) - db(Sm[sel], Sm.max())))
                self.assertLess(err, 0.05, f"spectrum {bf_name} ({u}, {v}): {err:.4f} dB")
                self.assertEqual(int(np.argmax(S)), int(np.argmax(Sm)))

    def test_element_mask(self):
        """Preset 4 (6 failed elements): with set_mask the maps are the enabled sub-array's (numpy reference
        with the disabled rows of A zeroed), and MVDR shows the emitter instead of nulling it."""
        sc = bs.preset(4)
        X = self.load(4)
        R = bm.covariance(X)
        en = np.array([(sc.enable >> k) & 1 for k in range(bs.N_EL)], dtype=bool)
        U, V, vis = bm.sky_grid(G)
        A = bm.steering_vector(U.ravel(), V.ravel()) * en[:, None]
        Pc = np.real(np.sum(A.conj() * (R @ A), axis=0)).reshape(G, G) / en.sum() ** 2
        Pm = 1.0 / np.real(np.sum(A.conj() * (np.linalg.inv(bm.loaded(R)) @ A), axis=0)).reshape(G, G)
        Pc[~vis] = np.nan
        Pm[~vis] = np.nan
        try:
            self.bf.set_mask(sc.enable)
            self.assert_map(self.bf.conventional_map(), Pc, 0.01, what="masked conventional preset 4")
            self.assert_map(self.bf.mvdr_map(), Pm, 0.05, what="masked mvdr preset 4")
            ref = float(self.bf.element_power())
            P = cp.asnumpy(self.bf.mvdr_map())
            i = np.nanargmax(P)
            self.assertGreater(db(np.nanmax(P), ref), -12.0, "MVDR peak re element power (unmasked: -23.7 dB)")
            s0 = sc.sources[0]
            self.assertLess(bg.uv_dist((U.ravel()[i], V.ravel()[i]), (s0.u, s0.v)), 0.05)
        finally:
            self.bf.set_mask((1 << bs.N_EL) - 1)

    def test_mvdr_nulls_jammer(self):
        self.load(2)
        wc, wm = self.bf.weights(-0.35, 0.20, "conv"), self.bf.weights(-0.35, 0.20, "mvdr")
        a_j = cp.asarray(bm.steering_vector(0.275, 0.10))
        gc = float(cp.abs(cp.vdot(wc, a_j)) ** 2)
        gm = float(cp.abs(cp.vdot(wm, a_j)) ** 2)
        self.assertLess(10 * np.log10(gm / gc), -20, "MVDR null on the jammer < 20 dB below conventional")

    def test_calibration(self):
        sc = bs.preset(5)
        gt = np.array(sc.gains)
        gt = gt / gt.mean()
        self.load(5, calibrated=False)
        g = self.bf.calibrate(0.0, 0.0, sc.enable)
        self.assertLess(np.max(np.abs(g - gt)), 0.02)
        self.bf.set_calibration(g)
        self.load(5, calibrated=True)
        P = cp.asnumpy(self.bf.mvdr_map())
        u, v = bm.peak_uv(P)
        self.assertLess(np.hypot(u, v), 2 * 2.0 / G, "source at boresight after calibration")
        self.bf.set_calibration(None)

    def test_gpu_generator_bit_exact(self):
        gen = bg.GpuGenerator()
        buf = cp.zeros(1 << 20, dtype=np.uint8)
        cases = [(1, 0, 0), (2, 3, 0), (2, 17, 12), (3, 5, 5), (4, 1, 0), (5, 2, 1),
                 (2, (1 << 26) // 4096 - 1, 3), (2, (1 << 26) // 4096, 3)]   # across m[63:32] = 0 -> 1
        for p, f, sf in cases:
            sc = bs.preset(p, scene_id=p)
            ref = bm.frame_bytes(bm.generate_frame(sc, f, scene_frame=sf))
            gen.frame(buf.data.ptr, sc, f, sf)
            got = cp.asnumpy(buf).tobytes()
            self.assertEqual(got, ref, f"preset {p} frame {f} scene_frame {sf}")

    def test_timing(self):
        """Not a pass/fail test: GPU time of the beamformer per frame (printed)."""
        self.load(2)
        bf = self.bf
        x = Frames.get(2)
        d = cp.asarray(np.frombuffer(bm.frame_bytes(x), dtype=np.uint8))
        for name in ("conv", "mvdr"):
            e0, e1 = cp.cuda.Event(), cp.cuda.Event()
            for it in range(30):
                if it == 10:
                    e0.record()
                bf.unpack(d)
                bf.covariance()
                P = bf.sky(name)
                q, i = bg.db_norm(P)
                w = bf.weights(-0.35, 0.2, name)
                bg.db_norm(bf.pattern(w))
                bf.spectrum(w)
            e1.record()
            e1.synchronize()
            print(f"\n  {name}: {cp.cuda.get_elapsed_time(e0, e1) / 20:.3f} ms GPU+host per frame (20 frames)")


if __name__ == "__main__":
    unittest.main(verbosity=2)
