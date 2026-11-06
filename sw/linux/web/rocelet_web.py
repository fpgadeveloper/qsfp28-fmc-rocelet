#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""qsfp28-fmc-rocelet browser UI on the board (ZCU106, Linux on the PS): a small web server (Python
standard library only) in front of roceletd's console socket. It never touches the hardware
itself: every value and every action is a console command (the same text as 'rl <command>').

  rocelet_web.py [--listen ADDR] [--port N] [--config FILE]... [--token SECRET] [--socket PATH]

  config file: key = value lines (listen, port, token, title, socket); later files override.
  token: empty = anybody on the network can control the design (the page says so); set one for a
  shared network (header X-Rocelet-Token or cookie rocelet_token).

HTTP API (JSON):
  GET  /api/status                 roceletd 'json' (link, rl0, engine / MAC / channel counters, QPs)
  GET  /api/text?cmd=<name>        read-only text: st | hsb | net | log | dump | ddr | qp<N> | grace | pause | vlan
  POST /api/cmd   {"line": "..."}  any console line (self-test 't pma', RLH / RLHM records, hsb on|off|src|
                                   rate|scene, clr, ...); answer {"rc": n, "out": "..."}
"""
import argparse
import http.server
import json
import os
import re
import socket
import socketserver
import sys
import urllib.parse

WEB_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")
VERSION = "1.0"

READ_ONLY = {"st": "st", "hsb": "hsb st", "net": "net", "log": "log 60", "dump": "dump", "ddr": "ddr",
             "grace": "grace", "pause": "pause", "vlan": "vlan", "help": "help", "version": "version"}


class Daemon:
    """One console command over roceletd's Unix socket: (status, output text)."""

    def __init__(self, path):
        self.path = path

    def run(self, line, timeout):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(self.path)
            s.sendall(line.strip().encode() + b"\n")
            buf = b""
            while True:
                chunk = s.recv(65536)
                if not chunk:
                    raise ConnectionError("roceletd closed the connection")
                buf += chunk
                z = buf.find(b"\0")
                if z >= 0 and buf.endswith(b"\n") and z < len(buf) - 1:
                    out, st = buf[:z], buf[z + 1:].strip()
                    return int(st or b"0"), out.decode(errors="replace")
        finally:
            s.close()


def load_config(paths):
    cfg = {"listen": "0.0.0.0", "port": "80", "token": "", "title": socket.gethostname() or "rocelet",
           "socket": "/run/rocelet/roceletd.sock"}
    for p in paths:
        try:
            with open(p) as f:
                for raw in f:
                    line = raw.split("#", 1)[0].strip()
                    if "=" in line:
                        k, v = (x.strip() for x in line.split("=", 1))
                        cfg[k] = v
        except OSError as e:
            print(f"rocelet_web: {p}: {e}", file=sys.stderr)
    return cfg


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "rocelet-web/" + VERSION
    cfg = {}
    daemon = None

    def log_message(self, fmt, *args):     # keep the journal quiet (status polls)
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj))

    def _authorised(self):
        tok = self.cfg.get("token", "")
        if not tok:
            return True
        if self.headers.get("X-Rocelet-Token", "") == tok:
            return True
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == "rocelet_token" and urllib.parse.unquote(v) == tok:
                return True
        return False

    def _static(self, name):
        path = os.path.join(WEB_DIR, name)
        types = {".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css"}
        try:
            with open(path, "rb") as f:
                self._send(200, f.read(), types.get(os.path.splitext(name)[1], "application/octet-stream"))
        except OSError:
            self._send(404, "not found", "text/plain")

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path in ("/", "/index.html"):
            return self._static("index.html")
        if u.path in ("/app.js", "/style.css"):
            return self._static(u.path[1:])
        if not self._authorised():
            return self._json(403, {"error": "token required"})
        if u.path == "/api/info":
            return self._json(200, {"title": self.cfg.get("title"), "token": bool(self.cfg.get("token")),
                                    "version": VERSION})
        if u.path == "/api/status":
            try:
                rc, out = self.daemon.run("json", 3.0)
                return self._send(200, out.strip() or "{}")
            except socket.timeout:
                return self._json(503, {"busy": True, "error": "roceletd is running a command"})
            except OSError as e:
                return self._json(503, {"error": f"roceletd: {e}"})
        if u.path == "/api/text":
            q = urllib.parse.parse_qs(u.query)
            name = q.get("cmd", ["st"])[0]
            m = re.fullmatch(r"qp(\d{1,2})", name)
            line = f"qp {m.group(1)}" if m else READ_ONLY.get(name)
            if not line:
                return self._json(400, {"error": "unknown read-only command"})
            try:
                rc, out = self.daemon.run(line, 10.0)
                return self._json(200, {"rc": rc, "out": out})
            except socket.timeout:
                return self._json(503, {"busy": True, "error": "roceletd is running a command"})
            except OSError as e:
                return self._json(503, {"error": f"roceletd: {e}"})
        self._send(404, "not found", "text/plain")

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        if not self._authorised():
            return self._json(403, {"error": "token required"})
        if u.path != "/api/cmd":
            return self._json(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(n) or b"{}")
            lines = [l for l in str(req.get("line", "")).splitlines() if l.strip()]
        except (ValueError, json.JSONDecodeError):
            return self._json(400, {"error": "bad request"})
        if not lines:
            return self._json(400, {"error": "empty command"})
        rc_all, outs = 0, []
        try:
            for line in lines[:16]:          # a pasted RLH + RLHM block is several lines
                rc, out = self.daemon.run(line[:1000], 600.0)
                rc_all = rc_all or rc
                outs.append(out)
        except OSError as e:
            return self._json(503, {"error": f"roceletd: {e}"})
        self._json(200, {"rc": rc_all, "out": "".join(outs)})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    ap = argparse.ArgumentParser(description="qsfp28-fmc-rocelet web UI (talks to roceletd)")
    ap.add_argument("--config", action="append", default=[])
    ap.add_argument("--listen")
    ap.add_argument("--port", type=int)
    ap.add_argument("--token")
    ap.add_argument("--socket")
    a = ap.parse_args()
    cfg = load_config(a.config)
    for k in ("listen", "port", "token", "socket"):
        if getattr(a, k) is not None:
            cfg[k] = str(getattr(a, k))
    Handler.cfg = cfg
    Handler.daemon = Daemon(cfg["socket"])
    srv = Server((cfg["listen"], int(cfg["port"])), Handler)
    print(f"rocelet_web {VERSION}: http://{cfg['listen']}:{cfg['port']}/ (roceletd {cfg['socket']}, "
          f"token {'set' if cfg['token'] else 'none'})", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
