#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# Tests of the beamforming demo model (sw/beam): python3 -m unittest discover -s sw/beam/tests -v
# (pytest also collects them). Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import sys
import unittest

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "hsb"))

import beam_model as bm  # noqa: E402
import beam_scene as bs  # noqa: E402

G = 128
CELL = 2.0 / G


def frame_R(scene, f=0, sf=0):
    return bm.covariance(bm.to_complex(bm.generate_frame(scene, f, scene_frame=sf)))


class TestIntegerModel(unittest.TestCase):
    def test_determinism(self):
        s = bs.preset(2)
        a = bm.generate_frame(s, 7)
        b = bm.generate_frame(bs.preset(2), 7)
        self.assertTrue(np.array_equal(a, b))
        s2 = bs.preset(2)
        s2.noise_seed ^= 1
        self.assertFalse(np.array_equal(a, bm.generate_frame(s2, 7)))

    def test_int16_and_shape(self):
        for p in bs.PRESETS:
            x, clip = bm.generate_frame(bs.preset(p), 3, return_clip=True)
            self.assertEqual(x.dtype, np.int16)
            self.assertEqual(x.shape, (4096, 64, 2))
            self.assertEqual(len(bm.frame_bytes(x)), 1 << 20)
            self.assertFalse(clip, f"preset {p} clips")

    def test_saturation(self):
        s = bs.Scene(noise_amp=0)
        for i in range(4):
            s.sources[i] = bs.Source(type=bs.T_CW, amp=32767, inc=0)
        x, clip = bm.generate_frame(s, 0, return_clip=True)
        self.assertTrue(clip)
        self.assertEqual(int(x[:, :, 0].max()), 32767)

    def test_frames_continuous(self):
        """frame f = time samples [4096 f, 4096 f + 4096): frames 2 + 3 == samples from 8192."""
        s = bs.preset(1)
        both = bm.samples(s, 2 * 4096, 8192)
        self.assertTrue(np.array_equal(both[:4096], bm.generate_frame(s, 2)))
        self.assertTrue(np.array_equal(both[4096:], bm.generate_frame(s, 3)))

    def test_packing(self):
        """beat b lane L = element 16 (b mod 4) + L of time sample b // 4, I low half."""
        x = bm.generate_frame(bs.preset(2), 0)
        bw = bm.beat_words(x)
        raw = np.frombuffer(bm.frame_bytes(x), dtype="<u4").reshape(-1, 16)
        self.assertTrue(np.array_equal(bw, raw))
        for b, lane in ((0, 0), (5, 3), (4095, 15), (16383, 7)):
            t, k = b // 4, 16 * (b % 4) + lane
            w = int(raw[b, lane])
            self.assertEqual(np.uint16(w & 0xFFFF).astype(np.int16), x[t, k, 0])
            self.assertEqual(np.uint16((w >> 16) & 0xFFFF).astype(np.int16), x[t, k, 1])

    def test_scene_relative_waveform(self):
        """tones restart at n0 (scene applied at frame 5): frame 5 of a scene applied at 5 ==
        frame 0 of a scene applied at 0, apart from the noise (absolute n)."""
        s = bs.preset(1)
        s.noise_amp = 0
        s.sources[0].inc = bs.freq_inc(0.0123)       # not periodic in a frame
        self.assertTrue(np.array_equal(bm.generate_frame(s, 5, scene_frame=5), bm.generate_frame(s, 0)))
        self.assertFalse(np.array_equal(bm.generate_frame(s, 5, scene_frame=0), bm.generate_frame(s, 0)))

    def test_disabled_element_noise_only(self):
        s = bs.preset(4)
        x = bm.generate_frame(s, 0)
        sn = bs.preset(4)
        sn.sources = [bs.Source() for _ in range(4)]
        xn = bm.generate_frame(sn, 0)
        for k in bs.FAILED_ELEMENTS:
            self.assertTrue(np.array_equal(x[:, k], xn[:, k]))
        self.assertFalse(np.array_equal(x[:, 0], xn[:, 0]))

    def test_matches_iq16_primitives(self):
        """E() table and the noise are the IQ16 ones (sw/hsb/rocelet_iq.py): beam noise of
        element k at time n == IQ16 noise of sample 64 n + k, so the RTL can reuse both."""
        try:
            import rocelet_iq as iq
        except ImportError:
            self.skipTest("sw/hsb/rocelet_iq.py not found")
        self.assertTrue(np.array_equal(bm.SIN_TAB, iq.SIN_TAB))
        phi = np.random.default_rng(1).integers(0, 2 ** 32, 5000, dtype=np.uint64)
        for a, b in zip(bm.exp_phi(phi), iq.exp_phi(phi)):
            self.assertTrue(np.array_equal(a, b))
        scene = bs.Scene(noise_amp=4000, noise_seed=0x5EED0004)
        nf = (1 << 26) - 10                       # crosses m[63:32] = 0 -> 1 (64 n + k >= 2^32)
        x = bm.samples(scene, nf, 20)
        ref = iq.samples(4, nf * 64, 20 * 64).view(np.int16).reshape(20, 64, 2)   # IQ16 scene 4
        self.assertTrue(np.array_equal(x, ref))

    def test_waveform_types(self):
        """CW peaks on its FFT bin; pulse / LFM gates follow width within the PRI; QPSK |w| ~ A."""
        s = bs.Scene()
        s.sources[0] = bs.Source(type=bs.T_CW, amp=10000, inc=bs.bin_inc(300))
        s.sources[1] = bs.Source(type=bs.T_PULSE, amp=10000, inc=bs.bin_inc(100), pri_log2=8, width=64)
        st, sp = bs.freq_inc(-0.25), bs.freq_inc(0.25)
        s.sources[2] = bs.Source(type=bs.T_LFM, amp=10000, inc=st, rate=bs.chirp_rate(st, sp, 128), pri_log2=9,
                                 width=128)
        s.sources[3] = bs.Source(type=bs.T_QPSK, amp=10000, inc=0, sym_log2=2)
        w = bm.waveforms(s, np.arange(4096, dtype=np.uint64))
        c = w[:, :, 0] + 1j * w[:, :, 1]
        self.assertEqual(int(np.argmax(np.abs(np.fft.fft(c[:, 0])))), 300)
        m = np.arange(4096) % 256
        self.assertTrue(np.all(c[m >= 64, 1] == 0) and np.all(np.abs(c[m < 64, 1]) > 9900))
        m = np.arange(4096) % 512
        self.assertTrue(np.all(c[m >= 128, 2] == 0) and np.all(np.abs(c[m < 128, 2]) > 9900))
        f = np.diff(np.unwrap(np.angle(c[:128, 2]))) / (2 * np.pi)
        self.assertAlmostEqual(f[0], -0.25, delta=0.01)
        self.assertAlmostEqual(f[-1], 0.25, delta=0.01)
        q = c[:, 3]
        self.assertTrue(np.all(np.abs(np.abs(q) - 10000) < 3))
        self.assertTrue(np.all(q[0::4] == q[3::4]))           # symbols last 4 samples (inc = 0)
        self.assertGreaterEqual(len(set(np.floor(np.angle(q) * 2 / np.pi).astype(int) % 4)), 4)


class TestRegisters(unittest.TestCase):
    def test_round_trip(self):
        for p in bs.PRESETS:
            s = bs.preset(p, scene_id=1000 + p)
            regs = s.to_registers()
            self.assertEqual(regs[-1], (bs.OPS_BM_APPLY, 1))
            self.assertEqual(regs[-2], (bs.OPS_BM_SCENE_ID, 1000 + p))
            s2 = bs.Scene.from_registers(dict(regs))
            self.assertEqual(s2.to_registers(), regs)
            self.assertTrue(np.array_equal(bm.generate_frame(s, 1), bm.generate_frame(s2, 1)))
            for a, _ in regs:
                self.assertTrue(0x0200 <= bs.sys_addr(a) < 0x0400)

    def test_layout(self):
        self.assertEqual(bs.sys_addr(bs.OPS_BM_SRC(3) + bs.SRC_V), 0x027C)
        self.assertEqual(bs.sys_addr(bs.OPS_BM_APPLY), 0x0294)
        self.assertEqual(bs.sys_addr(bs.OPS_BM_GAIN(63)), 0x03FC)
        self.assertEqual(bs.sys_addr(bs.OPS_BM_CAPS), 0x04F4)
        self.assertEqual(bs.CAPS_VALUE, 0x01440808)
        self.assertEqual(len(bs.preset(5).to_registers()), 32 + 4 + 64 + 2)

    def test_reset_scene(self):
        r = bs.reset_scene()
        self.assertEqual(r.sources[0].type, bs.T_CW)
        self.assertEqual(r.gain_words(), [0x4000] * 64)
        self.assertEqual(r.enable, (1 << 64) - 1)

    def test_encodings(self):
        self.assertEqual(bs.q230(1.0), 1 << 30)
        self.assertEqual(bs.q230(-0.5) & 0xFFFFFFFF, 0xE0000000)
        self.assertEqual(bs.gain_word(1 + 0j), 0x00004000)
        self.assertEqual(bs.gain_word(-1j), 0xC0000000)
        self.assertEqual(bs.chirp_rate(0, 0x10000, 2), 1 << 31)

    def test_changed_registers(self):
        a = bs.preset(2, scene_id=1)
        b = bs.preset(2, scene_id=2)
        b.sources[0].u = 0.1
        ch = b.changed_registers(a)
        self.assertEqual([x for x, _ in ch], [bs.OPS_BM_SRC(0) + bs.SRC_U, bs.OPS_BM_SCENE_ID, bs.OPS_BM_APPLY])

    def test_metadata(self):
        rec = bytearray(128)
        rec[34:36] = (7).to_bytes(2, "big")
        rec[48:64] = b"".join(v.to_bytes(4, "big") for v in (42, 5, 7, bs.MD_TAG_BEAM))
        md = bs.parse_metadata(rec)
        self.assertEqual((md["scene_id"], md["scene_frame"], md["frame_index"], md["frame_number"], md["beam"]),
                         (42, 5, 7, 7, True))


class TestBeamformers(unittest.TestCase):
    def test_source_peaks_where_placed(self):
        for u, v in ((0.30, 0.20), (-0.55, 0.40), (0.0, -0.8), (0.7, 0.1)):
            s = bs.Scene(noise_amp=300, noise_seed=9)
            s.sources[0] = bs.Source(type=bs.T_CW, amp=4000, inc=bs.bin_inc(200), u=u, v=v)
            pu, pv = bm.peak_uv(bm.conventional_map(frame_R(s), G))
            self.assertLessEqual(abs(pu - u), CELL, (u, v, pu, pv))
            self.assertLessEqual(abs(pv - v), CELL, (u, v, pu, pv))

    def test_mvdr_nulls_jammer(self):
        s = bs.preset(2)
        R = frame_R(s)
        e, j = s.sources[0], s.sources[2]
        aj = bm.steering_vector(j.u, j.v)
        conv = abs(np.vdot(bm.conventional_weights(e.u, e.v), aj)) ** 2
        mvdr = abs(np.vdot(bm.mvdr_weights(R, e.u, e.v), aj)) ** 2
        null_db = 10 * np.log10(mvdr / conv)
        self.assertLess(null_db, -20.0, f"null depth {null_db:.1f} dB")
        ae = bm.steering_vector(e.u, e.v)              # distortionless toward the emitter
        self.assertAlmostEqual(abs(np.vdot(bm.mvdr_weights(R, e.u, e.v), ae)), 1.0, places=9)

    def test_mvdr_resolves_two_emitters(self):
        s = bs.preset(3)
        R = frame_R(s)
        U, V, _ = bm.sky_grid(G)
        row = np.argmin(np.abs(V[:, 0] - 0.10))       # the cut through both emitters
        def dip(P):                                    # dB of the midpoint below the weaker emitter
            p = P[row]
            pe = [p[np.argmin(np.abs(U[0] - x))] for x in (-0.11, 0.11)]
            return 10 * np.log10(min(pe) / p[np.argmin(np.abs(U[0]))])
        self.assertLess(dip(bm.conventional_map(R, G)), 1.0)   # one blob
        self.assertGreater(dip(bm.mvdr_map(R, G)), 3.0)        # two peaks

    def test_calibration(self):
        s = bs.preset(5)
        R = frame_R(s)
        g = bm.calibrate(R, s.sources[0].u, s.sources[0].v, s.enable)
        gt = np.array([complex(x) for x in s.gains])
        gt /= gt.mean()
        err = np.max(np.abs(g - gt))
        self.assertLess(err, 0.02, f"max gain error {err:.4f}")
        # after correction a source elsewhere is where it should be, sidelobes back to normal
        s2 = bs.preset(5)
        s2.sources[0].u, s2.sources[0].v = 0.45, -0.3
        X = bm.to_complex(bm.generate_frame(s2, 0))
        pu, pv = bm.peak_uv(bm.conventional_map(bm.covariance(bm.apply_calibration(X, g)), G))
        self.assertLessEqual(abs(pu - 0.45), CELL)
        self.assertLessEqual(abs(pv + 0.3), CELL)

    def test_calibration_with_failed_elements(self):
        s = bs.preset(5)
        for k in bs.FAILED_ELEMENTS:
            s.enable &= ~(1 << k)
        g = bm.calibrate(frame_R(s), 0.0, 0.0, s.enable)
        en = np.array([(s.enable >> k) & 1 for k in range(64)], dtype=bool)
        gt = np.array([complex(x) for x in s.gains])
        gt = gt / gt[en].mean()
        self.assertLess(np.max(np.abs(g[en] - gt[en])), 0.02)
        self.assertTrue(np.all(g[~en] == 1))


if __name__ == "__main__":
    unittest.main()
