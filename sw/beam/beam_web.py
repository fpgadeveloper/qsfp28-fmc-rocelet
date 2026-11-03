#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# beam_web.py - the tablet / phone page of the beamforming demo: a Python standard-library HTTP
# server (threaded) inside rocelet_beam_app.py (--web PORT, default 8090, 0 = off) that serves one
# page (web/index.html: plain HTML / JS / CSS, no external resources) and
#
#   GET  /events    Server-Sent Events: 'hello' (static facts), then 'frame' about 10 times a second:
#                   the sky map the monitor shows (G x G uint8, base64, row 0 = v max), the true
#                   source positions of that frame's scene, the steered beam, the element mask and
#                   the tiles (rates, lost / errors, latency, beamformer, calibration, scene id)
#   GET  /state     the latest 'frame' as one JSON object (curl, tests)
#   POST /control   {"cmd": ...} -> the app's scene / control code (beam_ui.Ui: the same state, the
#   GET  /control?cmd=...&...     same coalescing writer as the mouse), so the monitor and the page
#                   show the same scene. Commands: preset n | beamformer | calibrate | noise |
#                   attract | reset | element k | drag phase=down|move|up u v [cls=emitter|jammer] |
#                   rate gbps=<Gb/s> | rate step=+1|-1 (the board's RATE_MBPS while the stream runs:
#                   the producer applies it from its next frame start; 1-80 Gb/s, board source only)
#
# No authentication: anyone who reaches the port can change the scene (a demo booth LAN, not the
# internet). --web-bind 127.0.0.1 keeps it on the P520.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import base64
import json
import os
import queue
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WEB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")
STATIC = {"/": "index.html", "/index.html": "index.html"}


def sse(event, data):
    """One Server-Sent Event, data as compact JSON on one line."""
    return ("event: %s\ndata: %s\n\n" % (event, json.dumps(data, separators=(",", ":")))).encode()


def encode_map(q_u8):
    """bytes (G x G uint8, row 0 = top) -> base64 text."""
    return base64.b64encode(bytes(q_u8)).decode("ascii")


class Hub:
    """The latest frame state + fan-out to the SSE clients (a queue each; a slow client loses frames,
    never the app)."""

    def __init__(self):
        self.lock = threading.Lock()
        self.clients = []
        self.hello = {}
        self.latest = None
        self.t_state = 0.0          # last /state request (keeps the app publishing for a few s)
        self.published = 0
        self.dropped = 0
        self.controls = 0

    def subscribe(self):
        q = queue.Queue(maxsize=8)
        with self.lock:
            self.clients.append(q)
        return q

    def unsubscribe(self, q):
        with self.lock:
            if q in self.clients:
                self.clients.remove(q)

    def n_clients(self):
        with self.lock:
            return len(self.clients)

    def wanted(self):
        """True when someone looks: an SSE client, or a /state request in the last 5 s."""
        return self.n_clients() > 0 or time.monotonic() - self.t_state < 5.0

    def publish(self, state):
        msg = sse("frame", state)
        with self.lock:
            self.latest = state
            clients = list(self.clients)
            self.published += 1
        for q in clients:
            try:
                q.put_nowait(msg)
            except queue.Full:
                self.dropped += 1


def _num(v, kind=float):
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return kind(v)
    return kind(str(v))


def make_handler(hub, control):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "rocelet_beam_web"

        def log_message(self, fmt, *args):      # quiet
            pass

        def _send(self, code, body, ctype="application/json"):
            if isinstance(body, (dict, list)):
                body = json.dumps(body, separators=(",", ":")).encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            url = urllib.parse.urlsplit(self.path)
            path = url.path
            if path in STATIC:
                try:
                    with open(os.path.join(WEB, STATIC[path]), "rb") as f:
                        self._send(200, f.read(), "text/html; charset=utf-8")
                except OSError:
                    self._send(404, {"error": "missing " + STATIC[path]})
                return
            if path == "/events":
                self._events()
                return
            if path == "/state":
                hub.t_state = time.monotonic()
                with hub.lock:
                    st = hub.latest
                self._send(200, dict(hello=hub.hello, frame=st, clients=hub.n_clients(), published=hub.published))
                return
            if path == "/control":
                obj = {k: v[-1] for k, v in urllib.parse.parse_qs(url.query).items()}
                self._control(obj)
                return
            self._send(404, {"error": "not found"})

        def do_POST(self):
            if urllib.parse.urlsplit(self.path).path != "/control":
                self._send(404, {"error": "not found"})
                return
            try:
                n = int(self.headers.get("Content-Length") or 0)
                if n > 4096:
                    raise ValueError("body too large")
                obj = json.loads(self.rfile.read(n) or b"{}")
                if not isinstance(obj, dict):
                    raise ValueError("expected a JSON object")
            except ValueError as e:
                self._send(400, {"ok": False, "error": str(e)})
                return
            self._control(obj)

        def _control(self, obj):
            try:
                ok, msg = control(obj)
            except (KeyError, ValueError, TypeError) as e:
                ok, msg = False, f"bad request: {e}"
            hub.controls += 1
            self._send(200 if ok else (409 if msg.startswith("refused") else 400), {"ok": ok, "msg": msg})

        def _events(self):
            q = hub.subscribe()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.end_headers()
            try:
                self.wfile.write(b"retry: 2000\n\n")
                self.wfile.write(sse("hello", hub.hello))
                with hub.lock:
                    st = hub.latest
                if st is not None:
                    self.wfile.write(sse("frame", st))
                self.wfile.flush()
                while True:
                    try:
                        msg = q.get(timeout=10)
                    except queue.Empty:
                        msg = b": keepalive\n\n"
                    self.wfile.write(msg)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                hub.unsubscribe(q)
                self.close_connection = True

    return Handler


def ui_control(ui, obj):
    """A page request -> beam_ui.Ui (the same handlers / state as the Holoviz mouse and keys, so the
    register writer coalesces page and mouse input alike). Returns (ok, message)."""
    cmd = str(obj.get("cmd", "")).lower()
    if cmd == "preset":
        n = _num(obj.get("n"), int)
        if not 1 <= n <= 5:
            raise ValueError("preset n: 1..5")
        ui.web_key({1: "ONE", 2: "TWO", 3: "THREE", 4: "FOUR", 5: "FIVE"}[n])
        return True, f"preset {n}"
    keys = dict(beamformer="B", calibrate="C", noise="N", attract="A", reset="R")
    if cmd in keys:
        ui.web_key(keys[cmd])
        return True, cmd
    if cmd == "element":
        k = _num(obj.get("k"), int)
        if not 0 <= k < 64:
            raise ValueError("element k: 0..63")
        return True, ui.web_element(k)
    if cmd == "drag":
        phase = str(obj.get("phase", "move"))
        if phase not in ("down", "move", "up"):
            raise ValueError("drag phase: down, move or up")
        u, v = (_num(obj.get("u", 0.0)), _num(obj.get("v", 0.0))) if phase != "up" else (0.0, 0.0)
        cls = str(obj.get("cls", "emitter"))
        if cls not in ("emitter", "jammer"):
            raise ValueError("drag cls: emitter or jammer")
        return True, ui.web_drag(phase, u, v, cls)
    if cmd == "rate":
        if obj.get("step") is not None:
            st = _num(obj.get("step"), int)
            if st not in (-1, 1):
                raise ValueError("rate step: -1 or 1")
            return ui.rate_step(st)
        g = _num(obj.get("gbps"))
        if not g > 0:
            raise ValueError("rate gbps: > 0")
        return ui.set_rate(g)
    raise ValueError(f"unknown cmd {cmd!r}")


class BeamWeb:
    """The server thread. hello: static facts for the page (dict)."""

    def __init__(self, port, ui, bind="0.0.0.0", hello=None):
        self.hub = Hub()
        self.hub.hello = dict(hello or {})
        self.ui = ui
        self.srv = ThreadingHTTPServer((bind, port), make_handler(self.hub, lambda o: ui_control(ui, o)))
        self.srv.daemon_threads = True
        self.th = threading.Thread(target=self.srv.serve_forever, name="beam-web", daemon=True)
        self.bind, self.port = bind, port

    def start(self):
        self.th.start()
        print(f"web page on http://{self.bind}:{self.port}/ (SSE /events, /state, /control)", flush=True)
        return self

    def stop(self):
        try:
            self.srv.shutdown()
            self.srv.server_close()
        except Exception:
            pass

    def summary(self):
        h = self.hub
        return dict(port=self.port, published=h.published, dropped=h.dropped, controls=h.controls,
                    clients_at_end=h.n_clients())
