#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# beam_ui.py - the Holoviz window of the beamforming demo: layout (1920 x 1080 canvas), the GPU
# compositor (sky map / beam pattern with colour map, static panels, element layout), the
# Holoviz layer specs (markers, crosshair, spectrum trace, text tiles), and the interaction state
# machine (mouse / scroll / keys, attract mode, scripted events) that turns input into scene
# changes for the register writer.
#
# Coordinates: canvas pixels (x right, y down) = window pixels at 1920 x 1080; Holoviz layer
# coordinates are the canvas pixels / (W, H). Sky: u to the right, v up (contract 6.3).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import collections
import math
import threading
import time

import numpy as np

import beam_scene as bs

W, H = 1920, 1080


class Rect:
    def __init__(self, x, y, w, h=None):
        self.x, self.y, self.w, self.h = x, y, w, (w if h is None else h)

    def inside(self, px, py):
        return self.x <= px < self.x + self.w and self.y <= py < self.y + self.h

    def to_uv(self, px, py):
        return 2 * (px - self.x) / self.w - 1, 1 - 2 * (py - self.y) / self.h

    def from_uv(self, u, v):
        return self.x + (u + 1) / 2 * self.w, self.y + (1 - v) / 2 * self.h


# ---- layout (canvas pixels) ----
SKY = Rect(28, 92, 960)               # the G x G sky map, u in [-1, 1] left to right, v up
RX = 1024                             # right column
PAT = Rect(RX, 128, 308)              # beam pattern
TILES1 = (RX + 344, 128)              # text tiles right of the pattern
SPEC = Rect(RX + 76, 498, 780, 232)   # spectrum plot area
EL = Rect(RX, 812, 240)               # 8 x 8 element layout (cells of 30 px)
TILES2 = (RX + 276, 812)
SPEC_TOP, SPEC_RANGE = 0.0, 110.0     # dBFS at the top / range of the spectrum plot

# ---- colours ----
def hexc(s, a=1.0):
    s = s.lstrip("#")
    return [int(s[i:i + 2], 16) / 255 for i in (0, 2, 4)] + [a]


C_BG = "#0A0D13"
C_PANEL = "#111722"
C_BORDER = "#2B3446"
C_GRID = "#1F2838"
C_RING = "#5A6C8C"
COL_EMIT = hexc("#3CFF5A")            # emitters: green circles
COL_JAM = hexc("#FF3B3B")             # jammers: red squares
COL_STEER = hexc("#FFD21F")           # steered beam: yellow crosshair, its pattern marker and spectrum
COL_TITLE = hexc("#FFFFFF")
COL_LABEL = hexc("#8FA3C2")
COL_VALUE = hexc("#F2F5FA")
COL_WARN = hexc("#FF9F1C")
COL_GRAB = hexc("#FFFFFF", 0.9)
EL_ON, EL_OFF, EL_OFF_X = "#2C9C5A", "#5A1010", "#FF4A4A"

TS = 0.030                            # tile text size (x window height): ~32 px at 1080
TS_SMALL = 0.023
TS_TITLE = 0.036
TS_BIG = 0.048
TS_VALUE = 0.034                      # tile values: ~37 px


def rgb(s):
    s = s.lstrip("#")
    return [int(s[i:i + 2], 16) for i in (0, 2, 4)]


def sky_lut():
    """256 x RGBA: -40 dB (dark navy, distinct from the background) .. 0 dB (white)."""
    pts = [(0.0, "#071233"), (0.30, "#0E2F78"), (0.55, "#1A6FC4"), (0.75, "#36B4E8"), (0.88, "#9AE6FF"),
           (1.0, "#FFFFFF")]
    x = np.linspace(0, 1, 256)
    lut = np.zeros((256, 4), dtype=np.uint8)
    for ch in range(3):
        lut[:, ch] = np.interp(x, [p[0] for p in pts], [rgb(p[1])[ch] for p in pts]).round()
    lut[:, 3] = 255
    return lut


def pack(s):
    r, g, b = rgb(s)
    return r | (g << 8) | (b << 16) | (255 << 24)


_KSRC = r"""
extern "C" __global__ void render_map(uchar4* canvas, int Wc, int x0, int y0, int S, const float* q, int g,
                                      const uchar4* lut, unsigned bgc, unsigned ringc)
{
    int px = blockIdx.x * blockDim.x + threadIdx.x, py = blockIdx.y;
    if (px >= S || py >= S) return;
    float u = -1.f + 2.f * (px + 0.5f) / S, v = 1.f - 2.f * (py + 0.5f) / S;
    float r = sqrtf(u * u + v * v);
    unsigned c;
    if (fabsf(r - 1.f) < 2.2f / S) c = ringc;
    else if (r > 1.f) c = bgc;
    else {
        float fx = (px + 0.5f) * g / S - 0.5f, fy = (py + 0.5f) * g / S - 0.5f;
        int ix = (int)floorf(fx), iy = (int)floorf(fy);
        float ax = fx - ix, ay = fy - iy;
        int ix0 = max(ix, 0), ix1 = min(ix + 1, g - 1), iy0 = max(iy, 0), iy1 = min(iy + 1, g - 1);
        float val = (1.f - ay) * ((1.f - ax) * q[iy0 * g + ix0] + ax * q[iy0 * g + ix1])
                  + ay * ((1.f - ax) * q[iy1 * g + ix0] + ax * q[iy1 * g + ix1]);
        int li = min(max((int)(val * 255.f + 0.5f), 0), 255);
        uchar4 l = lut[li];
        c = l.x | (l.y << 8) | (l.z << 16) | (255u << 24);
    }
    ((unsigned*)canvas)[(y0 + py) * Wc + x0 + px] = c;
}
"""


NBUF = 4    # canvas buffers: Holoviz draws one, VizRelayOp holds one, BeamOp writes the next (rocelet_beam_app)


class Canvas:
    """GPU compositor: a static background (panels, grid, element layout; rebuilt on the host when
    the element mask changes) + the two maps rendered by a kernel, NBUF buffers in rotation for Holoviz."""

    def __init__(self, cp):
        self.cp = cp
        self.mod = cp.RawModule(code=_KSRC)
        self.k_map = self.mod.get_function("render_map")
        self.lut = cp.asarray(sky_lut())
        self.bufs = [cp.zeros((H, W, 4), dtype=cp.uint8) for _ in range(NBUF)]
        self.n = 0
        self.bg_key = None
        self.bg = None

    def background(self, enable, cal_on):
        """The static background (panels, spectrum grid) is uploaded once; an element-mask change re-uploads only
        the element panel (248 x 248 px). B5: re-uploading the whole 8 MB image from pageable host memory on every
        mask / calibration change coincided with 1-15 frames lost each at 40 Gb/s (the H2D copy and the NIC's
        writes share the GPU's PCIe link). cal_on does not change the image."""
        if self.bg is None:
            img = np.zeros((H, W, 4), dtype=np.uint8)
            img[:, :, :3] = rgb(C_BG)
            img[:, :, 3] = 255

            def box(r, fill=C_PANEL, border=C_BORDER, pad=0):
                x0, y0, x1, y1 = r.x - pad, r.y - pad, r.x + r.w + pad, r.y + r.h + pad
                img[y0:y1, x0:x1, :3] = rgb(border)
                img[y0 + 2:y1 - 2, x0 + 2:x1 - 2, :3] = rgb(fill)

            box(SKY, pad=4)
            box(PAT, pad=4)
            box(Rect(SPEC.x - 76, SPEC.y - 8, SPEC.w + 84, SPEC.h + 50))
            # spectrum grid: every 20 dB, and at -Fs/4, 0, +Fs/4
            for db in range(0, int(SPEC_RANGE) + 1, 20):
                y = SPEC.y + int(round(db / SPEC_RANGE * (SPEC.h - 1)))
                img[y:y + 1, SPEC.x:SPEC.x + SPEC.w, :3] = rgb(C_GRID)
            for f in (0.25, 0.5, 0.75):
                x = SPEC.x + int(round(f * (SPEC.w - 1)))
                img[SPEC.y:SPEC.y + SPEC.h, x:x + 1, :3] = rgb(C_GRID)
            self.bg = self.cp.asarray(img)
            self.bg_key = None
        if enable == self.bg_key:
            return
        # element layout: ix to the right, iy up (as the sky); disabled = dark red with a red X
        pad = 4
        x0e, y0e, n = EL.x - pad, EL.y - pad, EL.w + 2 * pad
        el = np.zeros((n, n, 4), dtype=np.uint8)
        el[:, :, 3] = 255
        el[:, :, :3] = rgb(C_BORDER)
        el[2:n - 2, 2:n - 2, :3] = rgb(C_BG)
        cs = EL.w // 8
        for k in range(bs.N_EL):
            ix, iy = k % 8, k // 8
            x0, y0 = pad + ix * cs, pad + (7 - iy) * cs
            on = (enable >> k) & 1
            el[y0 + 2:y0 + cs - 2, x0 + 2:x0 + cs - 2, :3] = rgb(EL_ON if on else EL_OFF)
            if not on:
                for d in range(3, cs - 3):
                    for t in (-1, 0, 1):
                        el[y0 + d, x0 + d + t, :3] = rgb(EL_OFF_X)
                        el[y0 + d, x0 + cs - 1 - d + t, :3] = rgb(EL_OFF_X)
        self.bg[y0e:y0e + n, x0e:x0e + n] = self.cp.asarray(el)
        self.bg_key = enable

    def compose(self, q_sky, q_pat, g):
        cp = self.cp
        buf = self.bufs[self.n % NBUF]
        self.n += 1
        cp.copyto(buf, self.bg)
        for r, q in ((SKY, q_sky), (PAT, q_pat)):
            self.k_map(((r.w + 127) // 128, r.w), (128,), (buf, np.int32(W), np.int32(r.x), np.int32(r.y),
                                                           np.int32(r.w), q, np.int32(g), self.lut,
                                                           np.uint32(pack(C_PANEL)), np.uint32(pack(C_RING))))
        return buf


def spectrum_coords(cp, S):
    """Spectrum (4096 bins, linear power, fftshifted) -> LINE_STRIP coordinates (1024 points, max
    over 4 bins so tones keep their height), normalised window coordinates."""
    n = S.shape[0]
    m = 1024
    p = S.reshape(m, n // m).max(axis=1)
    db = 10 * cp.log10(cp.maximum(p, 1e-30))
    f = cp.clip((SPEC_TOP - db) / SPEC_RANGE, 0.0, 1.0)
    x = (SPEC.x + (cp.arange(m, dtype=cp.float32) + 0.5) / m * SPEC.w) / W
    y = (SPEC.y + f * (SPEC.h - 1)) / H
    return cp.stack([x, y], axis=1).astype(cp.float32)


# ------------------------------------------------------------------------------------------
# interaction
# ------------------------------------------------------------------------------------------
EMITTERS, JAMMERS = (0, 1), (2, 3)
NOISE_LEVELS = (100, 300, 1000, 3000)
# stream rate at run time (keys - / +, the page's rate command): the board's RATE_MBPS, which the
# producer applies from its next frame start. Live changes stay inside the range the demo is
# documented for (the test host's NIC-to-GPU path is clean to 80 Gb/s); the keys walk RATE_STEPS.
RATE_MIN_GBPS, RATE_MAX_GBPS = 1.0, 80.0
RATE_STEPS = (1.0, 2.0, 5.0, 10.0, 20.0, 40.0, 64.0, 80.0)


def set_rate_max(gbps):
    """Lower the run-time rate range to the board's link (OPS_LINK_GBPS: 40 on the ZCU106 target): the
    keys - / + and the page's rate stay within RATE_MIN_GBPS..gbps, the top step is gbps itself."""
    global RATE_MAX_GBPS, RATE_STEPS
    g = float(gbps)
    if RATE_MIN_GBPS < g < RATE_MAX_GBPS:
        RATE_MAX_GBPS = g
        RATE_STEPS = tuple(x for x in RATE_STEPS if x < g) + (g,)
ORBIT_R = (0.45, 0.6, 0.3, 0.7)       # contract 6.8
ORBIT_P = (20.0, 27.0, 33.0, 41.0)
ORBIT_PH = (0.0, 1.3, 2.6, 3.9)
AMP_TOTAL_MAX = 30000                  # sum of source amplitudes the scroll wheel allows (no clipping)


def templates():
    """A source to spawn when the person drags a class that the scene does not have."""
    return {"emitter": bs.preset(1).sources[0], "jammer": bs.preset(2).sources[2]}


class Ui:
    """The interaction state. Holoviz callbacks, the script and the attract mode change the commanded
    scene (thread-safe); the writer (UiControl) turns changes into register writes at <= 20 Hz."""

    def __init__(self, cfg, quit_fn):
        self.c = cfg
        self.quit_fn = quit_fn
        self.lock = threading.RLock()
        self.preset_n = cfg.preset
        self.scene = bs.preset(cfg.preset)
        self.full = True                      # next write: the whole scene (to_registers)
        self.dirty = True
        self.t_input = None                   # earliest input not yet written
        self.win = (W, H)                     # window size (window_size_callback)
        self.cursor = (W / 2, H / 2)
        self.cursor_first = None              # the pointer steers only once it has moved (not where it rests)
        self.cursor_armed = bool(getattr(cfg, "headless", False))
        s0 = self._first_active(EMITTERS) or 0
        self.steer = (self.scene.sources[s0].u, self.scene.sources[s0].v)
        self.steer_lock = None                # source index the steered beam follows
        self.beamformer = cfg.beamformer
        self.drag = None                      # (button, source)
        self.cal_want = False                 # calibration requested on (BeamOp estimates on the next frame)
        self.cal_epoch = 0                    # bumped on reset / preset (invalidates an estimate)
        self.attract = False
        self.attract_t0 = time.monotonic()
        self.last_input = time.monotonic()
        self.msgs = collections.deque(maxlen=3)
        self.inputs = 0
        self.t_web_drag = 0.0
        # stream rate (board only): rate_gbps = the RATE_MBPS the board acknowledged (--rate at the start),
        # rate_want = a change not yet written (Control writes it, then rate_applied())
        self.rate_live = getattr(cfg, "source", None) == "roce"
        self.rate_gbps = float(getattr(cfg, "rate", 0.0)) if self.rate_live else None
        self.rate_want = None

    # ---- helpers ----
    def say(self, text, secs=4.0):
        self.msgs.append((time.monotonic() + secs, text))

    def messages(self):
        now = time.monotonic()
        return [t for (end, t) in list(self.msgs) if end > now]

    def _first_active(self, idx):
        for s in idx:
            if self.scene.sources[s].type != bs.T_OFF:
                return s
        return None

    def _nearest(self, idx, u, v):
        best, bd = None, 1e9
        for s in idx:
            src = self.scene.sources[s]
            if src.type == bs.T_OFF:
                continue
            d = math.hypot(src.u - u, src.v - v)
            if d < bd:
                best, bd = s, d
        return best, bd

    def _changed(self, full=False):
        self.dirty = True
        self.full = self.full or full
        if self.t_input is None:
            self.t_input = time.monotonic()

    def _input(self, stop_attract=True):
        self.last_input = time.monotonic()
        self.inputs += 1
        if self.attract and stop_attract:
            self.attract = False
            self.say("attract mode off")

    def _canvas_xy(self, x, y):
        return x * W / self.win[0], y * H / self.win[1]

    @staticmethod
    def _clamp_uv(u, v, rmax=0.97):
        r = math.hypot(u, v)
        return (u, v) if r <= rmax else (u * rmax / r, v * rmax / r)

    # ---- Holoviz callbacks (window pixels) ----
    def on_window_size(self, w, h):
        if w > 0 and h > 0:
            self.win = (w, h)

    def on_cursor(self, x, y):
        with self.lock:
            px, py = self._canvas_xy(x, y)
            self.cursor = (px, py)
            if not self.cursor_armed:
                # Holoviz reports the resting pointer when the window appears: ignore it until it moves
                if self.cursor_first is None:
                    self.cursor_first = (px, py)
                if math.hypot(px - self.cursor_first[0], py - self.cursor_first[1]) < 12:
                    return
                self.cursor_armed = True
            if self.drag is not None and self.drag[0] != "W":      # "W": a drag from the web page
                self._input()
                u, v = self._clamp_uv(*SKY.to_uv(px, py))
                src = self.scene.sources[self.drag[1]]
                src.u, src.v = u, v
                self._changed()
            elif SKY.inside(px, py) and self.steer_lock is None:
                u, v = SKY.to_uv(px, py)
                if math.hypot(u, v) <= 1.0:
                    self.steer = (u, v)

    def on_button(self, button, press):
        """button 'L' / 'R' / 'M', press True / False."""
        with self.lock:
            px, py = self.cursor
            if not press:
                if self.drag is not None and self.drag[0] == button:
                    self.drag = None
                return
            self._input()
            if SKY.inside(px, py):
                u, v = self._clamp_uv(*SKY.to_uv(px, py))
                if button == "M":
                    s, _ = self._nearest(range(4), u, v)
                    self.steer_lock = None if (self.steer_lock is not None or s is None) else s
                    self.say("steering follows " + (f"source {s}" if self.steer_lock is not None else "the cursor"))
                    return
                cls = EMITTERS if button == "L" else JAMMERS
                s, _ = self._nearest(cls, u, v)
                if s is None:                      # spawn one of that class
                    s = cls[0]
                    t = templates()["emitter" if button == "L" else "jammer"]
                    self.scene.sources[s] = bs.Source(**vars(t))
                    self.say(f"{'emitter' if button == 'L' else 'jammer'} {s} added")
                src = self.scene.sources[s]
                src.u, src.v = u, v
                self.drag = (button, s)
                self._changed()
            elif EL.inside(px, py) and button == "L":
                cs = EL.w // 8
                ix, iy = int((px - EL.x) // cs), 7 - int((py - EL.y) // cs)
                k = 8 * iy + ix
                self.scene.enable ^= (1 << k)
                on = (self.scene.enable >> k) & 1
                self.say(f"element {k} ({ix}, {iy}) {'on' if on else 'FAILED'}")
                self._changed()

    def on_scroll(self, dx, dy):
        with self.lock:
            self._input()
            s = self.drag[1] if self.drag else None
            if s is None:
                u, v = SKY.to_uv(*self.cursor)
                s, d = self._nearest(range(4), u, v)
                if s is None or d > 0.35:
                    return
            src = self.scene.sources[s]
            others = sum(x.amp for i, x in enumerate(self.scene.sources) if i != s and x.type != bs.T_OFF)
            cap = max(AMP_TOTAL_MAX - others, 100)
            src.amp = int(min(max(src.amp * 10 ** (dy / 20.0), 50), cap, 32767))
            self.say(f"source {s} amplitude {src.amp} ({20 * math.log10(src.amp / 32768):.1f} dBFS)", 2.0)
            self._changed()

    def on_key(self, name):
        """name: Holoviz Key name ('B', 'ONE', 'ESCAPE', ...)."""
        with self.lock:
            if name == "A":
                self.attract = not self.attract
                self.attract_t0 = time.monotonic()
                self.last_input = time.monotonic()
                self.say("attract mode " + ("on" if self.attract else "off"))
                return
            self._input(stop_attract=name not in ("B", "C", "N"))   # beamformer / calibration / noise keep the show running
            digits = {"ONE": 1, "TWO": 2, "THREE": 3, "FOUR": 4, "FIVE": 5,
                      "KP_1": 1, "KP_2": 2, "KP_3": 3, "KP_4": 4, "KP_5": 5}
            if name in digits:
                self.load_preset(digits[name])
            elif name == "B":
                self.beamformer = "mvdr" if self.beamformer == "conv" else "conv"
            elif name == "C":
                self.cal_want = not self.cal_want
                if not self.cal_want:
                    self.say("calibration off")
            elif name == "N":
                cur = self.scene.noise_amp
                nxt = next((x for x in NOISE_LEVELS if x > cur), NOISE_LEVELS[0])
                self.scene.noise_amp = nxt
                self.say(f"element noise {nxt} (amplitude)")
                self._changed()
            elif name == "R":
                self.load_preset(self.preset_n)
                self.say(f"reset: preset {self.preset_n}")
            elif name in ("MINUS", "KP_SUBTRACT"):
                self.rate_step(-1)
            elif name in ("EQUAL", "KP_ADD"):
                self.rate_step(+1)
            elif name == "F":
                self.say("fullscreen is a start option (--windowed); Holoviz 4.4 cannot toggle it at run time")
            elif name == "ESCAPE":
                self.quit_fn("Esc")

    # ---- stream rate ----
    def set_rate(self, gbps):
        """Request the stream rate gbps (clamped to RATE_MIN_GBPS..RATE_MAX_GBPS). -> (ok, message); the
        Control thread writes RATE_MBPS and the board applies it from its next frame start."""
        with self.lock:
            if not self.rate_live:
                return False, "refused: the stream rate is a board setting (--source roce)"
            g = min(max(float(gbps), RATE_MIN_GBPS), RATE_MAX_GBPS)
            g = round(g, 3)
            self.rate_want = g
            self.say(f"stream rate -> {g:g} Gb/s")
            clamp = "" if g == float(gbps) else f" (clamped to {RATE_MIN_GBPS:g}..{RATE_MAX_GBPS:g})"
            return True, f"rate {g:g} Gb/s{clamp}"

    def rate_step(self, d):
        """The next RATE_STEPS value above (d > 0) or below (d < 0) the current / pending rate."""
        with self.lock:
            if not self.rate_live:
                self.say("stream rate: a board setting (--source roce)")
                return False, "refused: the stream rate is a board setting (--source roce)"
            cur = self.rate_want if self.rate_want is not None else self.rate_gbps
            cur = cur if cur and cur > 0 else float("inf")         # 0 = unpaced: above every step
            nxt = [x for x in RATE_STEPS if x > cur + 1e-9] if d > 0 else [x for x in RATE_STEPS if x < cur - 1e-9]
            if not nxt:
                self.say(f"stream rate: {'maximum' if d > 0 else 'minimum'} {cur:g} Gb/s")
                return True, f"rate {cur:g} Gb/s (limit)"
            return self.set_rate(nxt[0] if d > 0 else nxt[-1])

    def take_rate(self):
        """-> the pending rate request (Gb/s) or None."""
        with self.lock:
            g, self.rate_want = self.rate_want, None
            return g

    def rate_applied(self, gbps):
        with self.lock:
            self.rate_gbps = gbps

    # ---- the web page (beam_web.py): the same state and handlers as the mouse / keys ----
    WEB_DRAG_TIMEOUT = 3.0                # s without a move: a page drag whose 'up' never came is released

    def web_key(self, name):
        """A page button = the Holoviz key of the same name ('ONE'..'FIVE', 'B', 'C', 'N', 'A', 'R')."""
        self.on_key(name)

    def web_element(self, k):
        with self.lock:
            self._input()
            self.scene.enable ^= (1 << k)
            on = (self.scene.enable >> k) & 1
            msg = f"element {k} ({k % 8}, {k // 8}) {'on' if on else 'FAILED'}"
            self.say(msg)
            self._changed()
            return msg

    def web_drag(self, phase, u, v, cls="emitter"):
        """Touch / drag on the page's sky: 'down' takes the nearest source of the class (spawns one if the scene
        has none), 'move' moves it, 'up' releases it."""
        with self.lock:
            if phase == "up":
                if self.drag is not None and self.drag[0] == "W":
                    self.drag = None
                return "released"
            self._input()
            u, v = self._clamp_uv(u, v)
            if phase == "down" or self.drag is None or self.drag[0] != "W":
                idx = EMITTERS if cls == "emitter" else JAMMERS
                s, _ = self._nearest(idx, u, v)
                if s is None:
                    s = idx[0]
                    self.scene.sources[s] = bs.Source(**vars(templates()[cls]))
                    self.say(f"{cls} {s} added")
                self.drag = ("W", s)
            s = self.drag[1]
            src = self.scene.sources[s]
            src.u, src.v = u, v
            self.t_web_drag = time.monotonic()
            self._changed()
            return f"source {s} at ({u:+.3f}, {v:+.3f})"

    def load_preset(self, n):
        with self.lock:
            self.preset_n = n
            self.scene = bs.preset(n)
            self.cal_want = False
            self.cal_epoch += 1
            self.steer_lock = None
            self.drag = None
            s0 = self._first_active(EMITTERS)
            if s0 is not None:
                self.steer = (self.scene.sources[s0].u, self.scene.sources[s0].v)
            self._changed(full=True)

    # ---- attract mode (contract 6.8) ----
    def attract_step(self, now):
        with self.lock:
            if self.drag is not None and self.drag[0] == "W" and now - self.t_web_drag > self.WEB_DRAG_TIMEOUT:
                self.drag = None
            idle = self.c.attract_idle
            if not self.attract and idle > 0 and now - self.last_input > idle:
                self.attract = True
                self.attract_t0 = now
                self.say("attract mode (any input stops it)")
            if not self.attract:
                return False
            t = now - self.attract_t0
            for s, src in enumerate(self.scene.sources):
                if src.type == bs.T_OFF:
                    continue
                a = 2 * math.pi * t / ORBIT_P[s] + ORBIT_PH[s]
                src.u, src.v = ORBIT_R[s] * math.cos(a), ORBIT_R[s] * math.sin(a)
            s0 = self._first_active(EMITTERS)
            if s0 is not None and self.steer_lock is None:
                self.steer = (self.scene.sources[s0].u, self.scene.sources[s0].v)
            self.dirty = True
            if self.t_input is None:
                self.t_input = now
            return True

    def snapshot(self):
        with self.lock:
            st = self.steer
            if self.steer_lock is not None:
                src = self.scene.sources[self.steer_lock]
                st = (src.u, src.v)
            elif self.attract:
                s0 = self._first_active(EMITTERS)
                if s0 is not None:
                    st = (self.scene.sources[s0].u, self.scene.sources[s0].v)
            return dict(steer=st, beamformer=self.beamformer, cal_want=self.cal_want, cal_epoch=self.cal_epoch,
                        enable=self.scene.enable, drag=self.drag, attract=self.attract, preset=self.preset_n,
                        rate=self.rate_gbps,
                        grab_uv=((self.scene.sources[self.drag[1]].u, self.scene.sources[self.drag[1]].v)
                                 if self.drag else None), msgs=self.messages())

    def take_change(self):
        """-> (scene copy, full, t_input) of a pending change, or None."""
        with self.lock:
            if not self.dirty:
                return None
            sc = bs.Scene(sources=[bs.Source(**vars(s)) for s in self.scene.sources], noise_amp=self.scene.noise_amp,
                          noise_seed=self.scene.noise_seed, enable=self.scene.enable, gains=list(self.scene.gains),
                          name=self.scene.name)
            r = (sc, self.full, self.t_input or time.monotonic())
            self.dirty, self.full, self.t_input = False, False, None
            return r


def parse_script(text):
    """'t cmd args; ...' -> sorted [(t, cmd, [args])]. Commands: key NAME (- / + = rate) | move u v |
    press L|R|M | release L|R|M | drag L|R u0 v0 u1 v1 secs | scroll dy | elem ix iy | quit."""
    ev = []
    lines = [ln.split("#", 1)[0] for ln in (text or "").splitlines()]
    for item in ";".join(lines).split(";"):
        p = item.split()
        if not p:
            continue
        t, cmd, args = float(p[0]), p[1].lower(), p[2:]
        if cmd == "drag":
            b, u0, v0, u1, v1, dur = args[0], *map(float, args[1:6])
            n = max(int(dur * 20), 1)
            ev.append((t, "move", [u0, v0]))
            ev.append((t + 0.001, "press", [b]))
            for i in range(1, n + 1):
                f = i / n
                ev.append((t + f * dur, "move", [u0 + f * (u1 - u0), v0 + f * (v1 - v0)]))
            ev.append((t + dur + 0.01, "release", [b]))
        else:
            ev.append((t, cmd, args))
    return sorted(ev, key=lambda e: e[0])


def run_event(ui, cmd, args):
    """Dispatch one scripted event through the same handlers as the Holoviz callbacks."""
    sx, sy = ui.win[0] / W, ui.win[1] / H
    ui.cursor_armed = True
    if cmd == "key":
        k = args[0].upper()
        k = {"1": "ONE", "2": "TWO", "3": "THREE", "4": "FOUR", "5": "FIVE", "ESC": "ESCAPE", "-": "MINUS",
             "+": "EQUAL", "=": "EQUAL"}.get(k, k)
        ui.on_key(k)
    elif cmd == "move":
        x, y = SKY.from_uv(float(args[0]), float(args[1]))
        ui.on_cursor(x * sx, y * sy)
    elif cmd in ("press", "release"):
        ui.on_button(args[0].upper(), cmd == "press")
    elif cmd == "scroll":
        ui.on_scroll(0.0, float(args[0]))
    elif cmd == "elem":
        ix, iy = int(args[0]), int(args[1])
        cs = EL.w // 8
        ui.on_cursor((EL.x + ix * cs + cs / 2) * sx, (EL.y + (7 - iy) * cs + cs / 2) * sy)
        ui.on_button("L", True)
        ui.on_button("L", False)
    elif cmd == "quit":
        ui.quit_fn("script")
    else:
        raise ValueError(f"script: unknown command {cmd}")
