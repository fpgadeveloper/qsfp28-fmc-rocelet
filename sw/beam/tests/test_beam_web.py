#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# beam_web.py without the app or a GPU: the server on a free localhost port with a real beam_ui.Ui,
# a published frame state, then the page, /state, the SSE stream and every control command (POST
# JSON and GET query) checked against the Ui state. Pure Python:
#   python3 -m unittest -v tests/test_beam_web.py
# Copyright (c) 2026 Opsero Electronic Design Inc.

import argparse
import json
import os
import socket
import sys
import time
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import beam_scene as bs  # noqa: E402
import beam_ui as ui_mod  # noqa: E402
import beam_web  # noqa: E402


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class WebTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cfg = argparse.Namespace(preset=2, beamformer="conv", attract_idle=0.0, headless=True)
        cls.ui = ui_mod.Ui(cfg, lambda reason: None)
        cls.port = free_port()
        cls.web = beam_web.BeamWeb(cls.port, cls.ui, bind="127.0.0.1", hello=dict(source="csynthetic", grid=128)).start()
        cls.base = f"http://127.0.0.1:{cls.port}"
        cls.web.hub.publish(dict(g=128, map=beam_web.encode_map(bytes(range(256)) * 64), sources=[], steer=[0, 0],
                                 tiles={}, enable="1" * 64))

    @classmethod
    def tearDownClass(cls):
        cls.web.stop()

    def get(self, path):
        with urllib.request.urlopen(self.base + path, timeout=3) as r:
            return r.status, r.headers.get("Content-Type"), r.read()

    def post(self, obj):
        req = urllib.request.Request(self.base + "/control", data=json.dumps(obj).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=3) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_page(self):
        code, ctype, body = self.get("/")
        self.assertEqual(code, 200)
        self.assertIn("text/html", ctype)
        self.assertIn(b"EventSource", body)
        self.assertNotIn(b"http://", body.replace(b"http://www.w3.org", b""))   # no external resources
        self.assertNotIn(b"https://", body)

    def test_state(self):
        self.web.hub.publish(dict(g=128, map=beam_web.encode_map(bytes(128 * 128)), sources=[], tiles={}))
        code, _, body = self.get("/state")
        st = json.loads(body)
        self.assertEqual(st["hello"]["source"], "csynthetic")
        self.assertEqual(len(st["frame"]["map"]), 21848)            # base64 of 128 x 128 bytes
        self.assertTrue(self.web.hub.wanted())

    def test_sse(self):
        s = socket.create_connection(("127.0.0.1", self.port), timeout=3)
        s.sendall(b"GET /events HTTP/1.1\r\nHost: x\r\n\r\n")
        buf = b""
        t0 = time.time()
        while b"event: frame" not in buf and time.time() - t0 < 3:
            buf += s.recv(65536)
        self.assertIn(b"text/event-stream", buf)
        self.assertIn(b"event: hello", buf)
        self.assertIn(b"event: frame", buf)
        self.assertEqual(self.web.hub.n_clients(), 1)
        self.web.hub.publish(dict(g=128, map="", sources=[], tiles={}, marker=12345))
        buf = b""
        t0 = time.time()
        while b"12345" not in buf and time.time() - t0 < 3:
            buf += s.recv(65536)
        self.assertIn(b'"marker":12345', buf)
        s.close()

    def test_controls(self):
        ui = self.ui
        self.assertEqual(self.post({"cmd": "preset", "n": 5})[0], 200)
        self.assertEqual(ui.preset_n, 5)
        with urllib.request.urlopen(self.base + "/control?cmd=preset&n=2", timeout=3) as r:
            self.assertEqual(r.status, 200)
        self.assertEqual(ui.preset_n, 2)
        bf = ui.beamformer
        self.post({"cmd": "beamformer"})
        self.assertNotEqual(ui.beamformer, bf)
        self.post({"cmd": "calibrate"})
        self.assertTrue(ui.cal_want)
        self.post({"cmd": "calibrate"})
        self.assertFalse(ui.cal_want)
        n0 = ui.scene.noise_amp
        self.post({"cmd": "noise"})
        self.assertNotEqual(ui.scene.noise_amp, n0)
        self.post({"cmd": "attract"})
        self.assertTrue(ui.attract)
        en = ui.scene.enable
        self.post({"cmd": "element", "k": 9})
        self.assertEqual(ui.scene.enable, en ^ (1 << 9))
        # drag: preset 2 = emitter 0 + jammer 2; any input stops attract mode, as the mouse
        ui.take_change()
        self.assertEqual(self.post({"cmd": "drag", "phase": "down", "u": 0.5, "v": -0.2, "cls": "jammer"})[0], 200)
        self.assertFalse(ui.attract)
        self.assertEqual(ui.drag, ("W", 2))
        self.post({"cmd": "drag", "phase": "move", "u": 0.6, "v": -0.3})
        self.assertAlmostEqual(ui.scene.sources[2].u, 0.6)
        self.assertAlmostEqual(ui.scene.sources[2].v, -0.3)
        ui.on_cursor(100, 100)                          # the monitor's mouse does not move a page drag
        self.assertAlmostEqual(ui.scene.sources[2].u, 0.6)
        ch = ui.take_change()
        self.assertIsNotNone(ch)
        self.assertAlmostEqual(ch[0].sources[2].u, 0.6)
        self.post({"cmd": "drag", "phase": "up"})
        self.assertIsNone(ui.drag)
        self.post({"cmd": "drag", "phase": "down", "u": 3.0, "v": 0.0})   # clamped into the visible disc
        self.assertLessEqual(ui.scene.sources[0].u, 0.97 + 1e-9)
        self.post({"cmd": "drag", "phase": "up"})
        self.post({"cmd": "reset"})
        self.assertEqual(ui.scene.sources[0].u, bs.preset(2).sources[0].u)
        code, j = self.post({"cmd": "rate", "gbps": 80})      # synthetic source: no board rate
        self.assertEqual(code, 409)
        self.assertFalse(j["ok"])
        self.assertIsNone(ui.take_rate())
        self.assertEqual(self.post({"cmd": "preset", "n": 9})[0], 400)
        self.assertEqual(self.post({"cmd": "bogus"})[0], 400)
        self.assertEqual(self.post({"cmd": "element", "k": "x"})[0], 400)

    def test_stale_drag_released(self):
        ui = self.ui
        self.post({"cmd": "drag", "phase": "down", "u": 0.1, "v": 0.1})
        self.assertIsNotNone(ui.drag)
        ui.attract_step(time.monotonic() + ui.WEB_DRAG_TIMEOUT + 1)
        self.assertIsNone(ui.drag)


class RateTest(unittest.TestCase):
    """The live stream rate (board source): page rate commands and the - / + keys request a RATE_MBPS change,
    clamped to RATE_MIN_GBPS..RATE_MAX_GBPS; the app's Control thread takes it (take_rate) and confirms it
    (rate_applied)."""

    @classmethod
    def setUpClass(cls):
        cfg = argparse.Namespace(preset=2, beamformer="conv", attract_idle=0.0, headless=True, source="roce", rate=64.0)
        cls.ui = ui_mod.Ui(cfg, lambda reason: None)
        cls.port = free_port()
        cls.web = beam_web.BeamWeb(cls.port, cls.ui, bind="127.0.0.1", hello=dict(source="roce", grid=128)).start()
        cls.base = f"http://127.0.0.1:{cls.port}"

    @classmethod
    def tearDownClass(cls):
        cls.web.stop()

    post = WebTest.post

    def get(self, path):
        try:
            with urllib.request.urlopen(self.base + path, timeout=3) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def setUp(self):
        self.ui.rate_applied(64.0)
        self.ui.take_rate()

    def test_page_commands(self):
        ui = self.ui
        self.assertEqual(ui.snapshot()["rate"], 64.0)
        code, j = self.post({"cmd": "rate", "gbps": 40})
        self.assertEqual((code, j["ok"]), (200, True))
        self.assertEqual(ui.take_rate(), 40.0)
        self.assertIsNone(ui.take_rate())
        ui.rate_applied(40.0)
        self.assertEqual(ui.snapshot()["rate"], 40.0)
        code, j = self.post({"cmd": "rate", "gbps": 200})       # clamped
        self.assertEqual(code, 200)
        self.assertIn("clamped", j["msg"])
        self.assertEqual(ui.take_rate(), ui_mod.RATE_MAX_GBPS)
        self.post({"cmd": "rate", "gbps": 0.2})
        self.assertEqual(ui.take_rate(), ui_mod.RATE_MIN_GBPS)
        self.post({"cmd": "rate", "step": 1})                   # from 40 (applied): the next step up
        self.assertEqual(ui.take_rate(), 64.0)
        self.post({"cmd": "rate", "step": -1})
        self.post({"cmd": "rate", "step": -1})                  # the second steps from the pending 20: 10
        self.assertEqual(ui.take_rate(), 10.0)
        code, j = self.get("/control?cmd=rate&gbps=5")
        self.assertEqual(code, 200)
        self.assertEqual(ui.take_rate(), 5.0)
        self.assertEqual(self.post({"cmd": "rate", "step": 2})[0], 400)
        self.assertEqual(self.post({"cmd": "rate", "gbps": 0})[0], 400)
        self.assertEqual(self.post({"cmd": "rate", "gbps": "x"})[0], 400)
        self.assertEqual(self.post({"cmd": "rate"})[0], 400)

    def test_keys(self):
        ui = self.ui
        ui.on_key("EQUAL")
        self.assertEqual(ui.take_rate(), 80.0)
        ui.rate_applied(80.0)
        ui.on_key("KP_ADD")                                     # at the top: no request
        self.assertIsNone(ui.take_rate())
        for want in (64.0, 40.0, 20.0, 10.0, 5.0, 2.0, 1.0):
            ui.on_key("MINUS")
            g = ui.take_rate()
            self.assertEqual(g, want)
            ui.rate_applied(g)
        ui.on_key("KP_SUBTRACT")
        self.assertIsNone(ui.take_rate())
        ui.rate_applied(0.0)                                    # --rate 0 (unpaced): - steps to the maximum
        ui.on_key("MINUS")
        self.assertEqual(ui.take_rate(), 80.0)
        ui.rate_applied(33.0)                                   # between steps
        ui.on_key("EQUAL")
        self.assertEqual(ui.take_rate(), 40.0)
        ui_mod.run_event(ui, "key", ["-"])                      # --script: key - / key +
        self.assertEqual(ui.take_rate(), 20.0)


if __name__ == "__main__":
    unittest.main()
