# Beamforming demo: GPU application (`rocelet_beam_app.py`)

An 8 x 8 phased-array receiver. The KCU116 array generator (Opsero SOURCE = 2) streams every
element's complex samples over RoCE (rocelet, Holoscan Sensor Bridge data plane) into GPU memory.
The GPU beamforms them and draws a "radio camera" in a Holoviz window. The window is also the
control surface: drag a source and the app writes the new scene to the FPGA (HSB register
protocol, Opsero BM registers, APPLY). The picture follows within a frame or two, and the app
measures the round trip.

The interface between FPGA and GPU is `docs/source/beam_contract.md` (frame packing, metadata
bytes 48-63, registers, APPLY semantics, beamformer definitions, presets). The reference model is
`beam_model.py` / `beam_scene.py`.

| File | What |
|---|---|
| `rocelet_beam_app.py` | the Holoscan application: sources, beamformer operator, Holoviz, scene writer, latency, verdict + JSON summary |
| `beam_gpu.py` | CuPy beamformer (`BeamGpu`): unpack + calibration, R (complex128), Bartlett / MVDR sky, weights, pattern, spectrum, calibration; `GpuGenerator`: the array generator as a CUDA kernel, bit-exact with `beam_model` |
| `beam_ui.py` | layout (1920 x 1080), GPU compositor (colour-mapped maps, panels, element layout), interaction state machine (mouse, wheel, keys, attract mode), `--script` events |
| `beam_regs.py` | all register traffic: `BoardRegs` (ECB WR_BLOCK on its own socket, or one `write_uint32` per word) and `SimRegs` (the BM register file with the contract's APPLY semantics, for the synthetic sources) |
| `beam_synth.py` | the reference-model generator process of `--source synthetic` |
| `beam_web.py`, `web/index.html` | the tablet / phone page (`--web 8090`): threaded standard-library HTTP server, Server-Sent Events, one plain HTML / JS page |
| `tests/test_beam_web.py` | the web server with a real `beam_ui.Ui`: page, `/state`, SSE, every control command (pure Python, no GPU) |
| `tests/test_beam_gpu.py` | GPU beamformer vs `beam_model` float beamformers; CUDA generator vs `generate_frame()` bit for bit |
| `tests/script_60s.txt` | the scripted 60 s session of the headless test |

## Running it

Inside NVIDIA's HSB container (`hololink-demo:3.0.0`: Holoscan 4.4, hololink 3.0.0, CuPy). It
needs no packages beyond the image. `sw/hsb/` must sit next to `sw/beam/`, because the app reuses
`rocelet_hsb_app.py` (frame accounting, start gate, PNG sink) and `rocelet_hsb.py` (connection,
keepalive). `run.sh` (this directory) starts the container with the repository mounted at `/beam`
(`ROCELET_DIR`, default two levels above the script) and the working directory `/beam/sw/beam`
(`RL_WIN=1` adds the X display for a window on the monitor). The host set-up (drivers, the
container, the 100G port, the X session) is in `docs/source/host_setup.md`. The application's
default RDMA device is the test host's `rocep179s0f0`: add `--ibv-name <rdma-dev>` on another host.

```
# no board: frames from the bit-exact numpy model (~10 frames/s), window on the monitor
RL_WIN=1 sw/beam/run.sh python3 rocelet_beam_app.py --source synthetic --preset 2
# no board: the same generator as a CUDA kernel (~50-60 frames/s shown)
RL_WIN=1 sw/beam/run.sh python3 rocelet_beam_app.py --source csynthetic --preset 2
# the board (KCU116 + OP120, console 'hsb on', bitstream + firmware with the array generator)
RL_WIN=1 sw/beam/run.sh python3 rocelet_beam_app.py --source roce --preset 2 --rate 64
# headless, PNG every 25 shown frames, scripted input, verdict at the end
sw/beam/run.sh python3 rocelet_beam_app.py --source synthetic --headless --duration 66 \
    --attract-idle 0 --png-every 25 --min-peak-ok 0.9 --script @tests/script_60s.txt --outdir /beam/out/t60
# tests (GPU)
sw/beam/run.sh python3 -m unittest -v tests/test_beam_gpu.py
```

Every run ends with a `PASS:` / `FAIL:` line and writes a JSON summary (`--outdir`, `--tag`).

`--source roce` follows `rocelet_hsb_app.py`. It finds the board by IP, runs `hl.reset()`, reads
`S_BM_CAPS` (it refuses to run unless the value is 0x01440808; `--force` overrides), reads
`LINK_GBPS` (the rate cap) and `TARGET` (0x7F00001C: the window / page header names the board,
`KCU116 -> 100G RoCE -> GPU`, `ZCU106 -> 40G RoCE -> GPU`, `VCK190 -> 100G RoCE -> GPU`; with a
console before 0.6.0, which reads 0 there, the name follows `LINK_GBPS` as before; `--board`
overrides it, `FPGA -> RoCE -> GPU` when neither register can be read), writes SOURCE = 2
and RATE_MBPS (`--rate` Gb/s), then the start scene (all 102 words, APPLY while the generator is
idle). It arms the keepalive. `RoceReceiverOp` writes 1 MiB frames into GPU memory, and the start
gate enables DP_VP_MASK once the graph is up. At the end the data plane is switched off.

## What it computes (per shown frame, contract section 6)

* X = the 64 x 4096 complex matrix of the frame (int16 / 32768), corrected X <- diag(1/g) X once
  calibrated.
* R = X X^H / T, accumulated in complex128 (0.3 ms). A complex64 CGEMM has a 2e-6 relative error,
  which the MVDR inverse turns into 0.4 % weight errors and > 1 dB errors in the deep pattern
  regions.
* Sky (G = 128, the unit disc): Bartlett a^H R a / N^2 or MVDR 1 / a^H (R + d I)^-1 a, with
  d = 1e-3 tr(R) / N. Shown: Bartlett as 10 log10(P / max P), 0 .. -40 dB of its own peak;
  MVDR on an absolute scale, -10 .. -40 dB re the frame's mean element power tr(R) / N (within 0.6 dB
  of the Bartlett peak in presets 1, 2, 4, 5; `--mvdr-top-db`, higher values clip to white). The top
  sits 10 dB below the element power because MVDR peaks are narrower than the 128 x 128 grid: the
  peak cell of a calibrated source is 8-14 dB below it. With the per-map scale an MVDR map that nulls
  its own source (preset 5 before calibration: the steering vectors do not match the array) was a
  flat bright disc; on the absolute scale its floor is dark (~-36 dB), the self-nulled source a dim
  blob (~-26 dB) and, once calibrated (C), a white peak.
* Failed elements (ELEM_EN of the frame's scene): every map, weight and pattern uses the enabled
  sub-array (`BeamGpu.set_mask`: the steering rows of disabled elements are zeroed, rebuilt only when
  the mask changes). A disabled element carries only noise; with the full 64-element steering vectors
  MVDR nulled its own source (preset 4: peak -23.7 dB re element power, now -7.8 dB, a sharp peak on
  the emitter), and the conventional sidelobes now are those of the real array.
* Steered beam at the cursor (or locked on a source): conventional or MVDR weights, the pattern
  |w^H a|^2, y = w^H X, and the 4096-point cuFFT power spectrum in dBFS per bin. The display
  smooths the spectrum (`--spec-avg 0.6`); the maps are not averaged (R from one frame).
* Calibration (key C): `beam_model.calibrate()` on the raw R of the next frame, with the scene's
  single source as the reference. The tile shows the max error against the gains the app wrote.
* Self-check: the strongest sky cell must lie within 0.05 of a true source of the frame's scene
  (`peak on source`; `--min-peak-ok` makes it part of the verdict).

Frames arriving faster than `--fps` (default 60) are counted, not processed. The beamformer does not
wait for Holoviz's queue: its image goes through `VizRelayOp` (queue of 1, newest wins). The scheduler is
the greedy one (one thread): an event-based scheduler with 3 threads fed the beamformer only ~26 frames/s
on the board. The first frame of a
new scene is always processed, because that frame is where mouse-to-data is measured.

## The window

Sky map (left), beam pattern (top right), beam output spectrum (middle right), the 8 x 8 element
layout (bottom right), and tiles: stream Gb/s, frames received / shown per second, lost / dropped,
record errors, GPU ms per frame, scene id + its first frame, mouse-to-data, mouse-to-pixel, elements
on, calibration. While calibration is off and the scene has element gain errors (preset 5), the sky
shows "array uncalibrated: press C". Markers sit at the true source positions of the frame's scene: green circles are
emitters (sources 0, 1), red squares are jammers (2, 3), and a white ring follows a source while it
is dragged. The yellow crosshair marks the steered beam; its pattern and spectrum use the same
yellow.

| Input | Action |
|---|---|
| left-drag on the sky | moves the nearest emitter (adds one if the scene has none) |
| right-drag on the sky | moves the nearest jammer (adds one if the scene has none) |
| wheel | amplitude of the grabbed / nearest source, 1 dB per notch (sum of amplitudes <= 30000: no clipping) |
| middle click | locks the steered beam on the nearest source (again: back to the cursor) |
| click on an element | fails / restores it (EN_LO / EN_HI) |
| 1-5 | presets (contract section 7) |
| B / C / N / A / R | beamformer / calibration on-off / element noise 100, 300, 1000, 3000 / attract mode / reset the preset |
| - / + (also keypad) | stream rate down / up through 1, 2, 5, 10, 20, 40, 64, 80 Gb/s (`--source roce`) |
| Esc | quit |

Mouse moves are coalesced to `--update-hz` (20) scene writes per second. Each write is
`Scene.changed_registers()` + SCENE_ID + APPLY (a drag is U, V, SCENE_ID, APPLY = 4 words), and a
preset sends all 102 words. Attract mode starts after `--attract-idle` s (10) without input, orbits
the sources as in contract 6.8; pointer input, a preset or reset stops it (B, C and N do not).

`--script "t cmd args; ..."` (or `@file`) replays input through the same handlers. Commands:
`key NAME` (`key -` / `key +`: rate), `move u v`, `press|release L|R|M`, `drag L|R u0 v0 u1 v1 secs`, `scroll dy`,
`elem ix iy`, `quit`. Times count from the first frame shown.

## Tablet / phone page (`beam_web.py`)

The app serves a page on `--web PORT` (default 8090, `--web 0` = off; `--web-bind`, default 0.0.0.0).
At **http://\<gpu-host\>:8090/** (the GPU host's LAN address). Open it on a tablet or phone on the same LAN. It shows
what the monitor shows: the sky map (128 x 128, the same colour scale, about 10 updates per second,
`--web-hz`), the true source markers, the steered beam, the tiles (stream Gb/s, frames per second in /
shown, lost, errors, GPU ms, mouse-to-data, mouse-to-pixel, beamformer, calibration, scene id, the rate
set) and the 8 x 8 element layout. Controls:

| Page | Action (the same handlers as the window, so monitor and page stay in sync) |
|---|---|
| touch / drag on the sky | moves the nearest emitter, or the nearest jammer with the "jammer" toggle (adds one if the scene has none); a white ring follows the finger |
| preset buttons 1-5 | presets |
| beamformer / calibrate / noise / attract / reset | the keys B / C / N / A / R |
| rate - / rate + | the keys - / + |
| tap an element | fails / restores it |

Page input goes into the same `beam_ui.Ui` state as the mouse, so it is coalesced to `--update-hz`
scene writes like a mouse drag; the page sends one request at a time and keeps only the newest
queued move. A page drag whose finger-up never arrives is released after 3 s. The page needs no
external resources (no CDN). There is no authentication: anyone who reaches the port can change the
scene (`--web-bind 127.0.0.1` keeps it local).

Endpoints (for scripts and tests):

```
curl -N http://<gpu-host>:8090/events          # SSE: 'hello', then 'frame' events (JSON, map = base64 uint8)
curl http://<gpu-host>:8090/state              # the latest frame state as one JSON object
curl -X POST -d '{"cmd":"preset","n":2}' http://<gpu-host>:8090/control
curl 'http://<gpu-host>:8090/control?cmd=drag&phase=down&u=0.3&v=0.1&cls=jammer'
curl -X POST -d '{"cmd":"rate","gbps":40}' http://<gpu-host>:8090/control    # stream rate while running
```

Commands: `preset n`, `beamformer`, `calibrate`, `noise`, `attract`, `reset`, `element k` (0-63,
k = 8 iy + ix), `drag phase=down|move|up u v [cls=emitter|jammer]`, `rate gbps=<Gb/s>` or `rate step=1|-1`
(see below).

## Stream rate while running

`--rate` sets the start rate. The keys - / + and the page (`rate step=1|-1`, or `rate gbps=<x>`
clamped to 1-80 Gb/s, `beam_ui.RATE_MIN_GBPS` / `RATE_MAX_GBPS`) request a new rate; the control
thread writes RATE_MBPS (one register write), the firmware recomputes C_HP_PERIOD at once and the
FPGA producer samples it at its next frame start (`rsys_hsb_prod.sv`), so the stream changes rate
from the next frame on, without a restart. The window's stream tile shows "measured of set Gb/s".
On a change the app restarts its 1 s rate window, takes the latency frame period (mouse-to-data)
from the new rate until the next measurement, and for `--verify` uses the shorter page age of the
two rates for 1 s. The JSON summary lists every change (`rate_changes`: time, Gb/s, write ms) and
the rate at the end. Without the board (`--source synthetic|csynthetic`) the keys only say so; the
page's `rate` answers 409.

## The monitor on the P520

The framebuffer is right (a screenshot shows the sky disc 959 x 959 pixels), but in fullscreen the
monitor shows the picture squeezed to about half its width (the disc looks like an upright ellipse).
Holoviz's fullscreen window (GLFW) picks the highest-refresh 1920 x 1080 mode, and the X server
offers five: the forced 148.5 MHz 1920x1080_60 of `/etc/X11/xorg.conf.d/20-rocelet-monitor.conf`
plus driver-generated ones (the config's `AllowNonEdidModes`), among them a 60.01 Hz DoubleScan mode
(356.375 MHz). In that mode the monitor receives 2160 lines and shows a 1920 x 2160 picture at its
aspect (8:9). GLFW restores the 60.00 Hz mode when the app exits. The X configuration now keeps
only the forced 1080p mode (`NoXServerModes, NoPredefinedModes, NoVesaModes` in `ModeValidation`,
see `docs/source/host_setup.md`); a window (`--windowed`) does not change the mode.

## Latency (contract 6.7, host monotonic clock)

The app looks at a frame only when its loop comes round (the receiver hands it the newest completed
frame, queue of 2; at 10-80 Gb/s nearly all frames are counted, not looked at). So:

* **mouse-to-data**: the GUI event to the activation frame (metadata `scene_frame`) completed in GPU
  memory: the receiver's completion time of the first new-scene frame the app sees (metadata
  `received_s/ns`) minus (frame_index - scene_frame) frame periods.
* **mouse-to-app**: the GUI event to the app's first look at a new-scene frame (contract 6.7 t_data).
* **mouse-to-pixel** (tile): mouse-to-app + that frame's data-to-pixel (arrival at the beamformer to
  the image handed to Holoviz by `VizRelayOp`; Holoviz presents it at the next 60 Hz refresh).
* The summary also has input-to-APPLY reply and the board's part in frames: `scene_frame` minus
  `OPS_FRAMES` read right after the APPLY reply (0 or 1: activation at the next frame start).

Scene writes are coalesced to `--update-hz` (20): during a drag, input-to-APPLY includes up to 50 ms
of coalescing (p99), a single key or click is written at once.

## Register path

All BM register I/O goes through `beam_regs.BoardRegs`. The classic hololink Python API has no
block write (`Hololink::WriteData` is not bound), so `--reg-mode block` (default) sends the
contract's single WR_BLOCK request (command 0x09, APPLY last) from its own UDP socket. The
app's Hololink object is then created without sequence checking (`beam_regs.connect_classic`),
because our requests move the board's latched sequence number. `--reg-mode single` writes word by
word through the Hololink object, with sequence checking kept. That is also atomic, since the words
land in shadow registers and only APPLY, written last, stages them; it just costs one round trip
per word. With `--api module`, block mode uses `HololinkInterfaceV1.write_uint32` with lists.

## Checks on the board

* `--verify N`: up to N received frames per second (-1 = every frame the loop takes) are compared word
  for word with `beam_gpu.GpuGenerator` for the scene / `frame_index` / `scene_frame` of the frame's
  own metadata record (the strongest end-to-end check: packing, time index, scene activation,
  metadata). Any mismatching sample fails the run; the first mismatching frames are saved as `.npz`.
* `tests/board_regs_probe.py [--mode block|single]` (in the container, board on with `hsb on`): CAPS,
  a preset written + APPLY while idle, APPLIED_ID / APPLIES, every word read back, drag-sized writes
  timed, replies to a second socket, status 0x03 for an unaligned address.
* Losses in the first 2 s of the stream are reported apart (`lost_start`): the P520's ConnectX-6 Dx
  discards ~1k packets (0-6 frames) at a 40-80 Gb/s data-plane start into GPU memory
  (`rx_discards_phy`); the verdict uses the losses after that.

## Measured on the board (KCU116 + OP120 -> CX-6 Dx -> RTX PRO 4000, 2026-11-03, B5)

* Verify, 60 s each, headless (`--viz none --fps 10 --verify -1`), attract mode moving the sources
  (~1,100 scene changes per run): 10 / 40 / 64 / 80 Gb/s, 24-27 k frames (6.3-7.1 G samples) compared
  per run, **0 mismatches**; 0 frames lost after the start window.
* Window on the monitor (60 Hz vsync): 45-47 frames shown per second at every rate, GPU 3.2-3.3 ms
  per shown frame (p99 4.1-5.3), data-to-pixel 19-21 ms, mouse-to-data 1.5-2.7 ms p50,
  mouse-to-pixel ~23 ms p50 (44 ms at 10 Gb/s, where the 0.84 ms frame period puts the first
  new-scene frame one loop later), board activation 0-1 frames after the APPLY reply.
* Register path: WR_BLOCK of 102 words 0.6 ms, a 4-word drag write 0.09 ms (ECB round trip 73 us);
  `--reg-mode single` 6.6 ms / 0.31 ms.

## Measured (P520, RTX PRO 4000, synthetic sources, 2026-11-02)

* `tests/test_beam_gpu.py`: 8/8. The maps match `beam_model` within 0.01 dB (Bartlett) and
  0.05 dB (MVDR) over cells above -40 dB, the peak cell is identical, and the CUDA generator is
  bit-exact on 8 cases (including across m[63:32] = 0 -> 1).
* GPU time per shown frame (CUDA events around everything, including the canvas): 3.2 ms p50 at
  53 shown/s (csynthetic) and 8.4 ms at 10/s. At low frame rates the GPU idles between frames and
  the same work takes longer, so on the board (7,600 frames/s into GPU memory) expect the first
  number.
* Mouse-to-data: 4.0 ms p50 (csynthetic, frames every 8 ms), 69 ms (synthetic: the numpy model
  takes ~25 ms per frame). On the board: 1.5-2.7 ms p50 (previous section).
