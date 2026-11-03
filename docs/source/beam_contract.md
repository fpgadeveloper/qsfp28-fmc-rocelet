# Beamforming demo: data and register contract

The interface between the array generator in the FPGA (`rsys_beam_src`, instance `u_bms`) and the
GPU application of the [beamforming demo](beam_demo.md): array geometry, frame and sample
packing, the metadata fields, the registers and the semantics of a scene change, the
integer-exact source model, the GPU-side definitions (beamformers, calibration, latency,
attract mode), the presets and the verification hooks.

Model version 1 (reported in `S_BM_CAPS` and `S_BM_STATUS`), design version 0.4.0. The two sides
are built against this text only; the executable form of it is the reference model
`sw/beam/beam_model.py` (integer generator + float beamformers) with `sw/beam/beam_scene.py`
(scene, register encoding, presets, metadata parser) and the tests in `sw/beam/tests/`
(`python3 -m unittest discover -s sw/beam/tests -v`). Where this text and the model disagree the
model is wrong and gets fixed. The frames the FPGA sends are compared bit for bit with
`generate_frame()` on hardware ([Measured](beam_demo.md#measured)).

The rocelet IP is not touched. Nothing here changes SOURCE 0 (IQ16) or 1 (counter).

Notation (the same as the IQ16 model `sw/hsb/rocelet_iq.py`): `asr(x, s)` = floor(x / 2^s); `rnd(x, s)` = asr(x + 2^(s-1), s)
(round to nearest, ties toward +infinity); `[a]_w` = a mod 2^w (two's complement wrap);
`sat16(v)` = min(max(v, -32768), 32767). All arithmetic below is on exact integers; every
intermediate width is given so the RTL can mirror it bit for bit.

---------------------------------------------------------------------------------------------

## 1. Array geometry

* **Fixed 8 x 8 planar array**, N = 64 elements, half-wavelength spacing. Not a build
  parameter: the beat packing (section 2) relies on 64 elements = 4 beats of 16 lanes, and the
  per-lane element pattern (ix = lane mod 8) is what keeps the RTL cheap. A different size would
  change the packing, the steering-table layout and the GPU code; it is not free, so it is not
  offered. `S_BM_CAPS` reports NX = NY = 8 so a future variant can be detected.
* Element **k = 8 iy + ix**, ix, iy = 0..7. Position in half wavelengths:
  **x_k = ix - 3.5, y_k = iy - 3.5** (array centred on the origin).
* Direction cosines **(u, v)**: u = sin(theta) cos(phi) along +x (ix increasing),
  v = sin(theta) sin(phi) along +y (iy increasing); visible region u^2 + v^2 <= 1;
  boresight (0, 0).
* Element k receives a plane wave from (u, v) with phase **+pi (x_k u + y_k v)** (radians). So
  the steering vector is a_k(u, v) = exp(+j pi (x_k u + y_k v)) (section 6) and the
  conventional beam steered at a source peaks on it.
* Null-to-null beamwidth 2 / 8 = 0.25 in u (or v) at boresight; half-power beamwidth about
  0.22.

## 2. Frames: sample packing

Opsero SOURCE = 2 selects the array generator. Everything about frames that is not stated here
is unchanged from SOURCE 0 (page ring, WR sizes, pacing, link pause, watchdog, metadata bytes
0-47).

* A **sample** is a complex int16: the 32-bit little-endian word `(uint16)I | (uint16)Q << 16`
  (I in bytes 0-1, Q in bytes 2-3), as IQ16 today.
* A 64-byte **beat** holds 16 samples, lane L = 0..15 in bytes 4L .. 4L+3.
* **Beat b** (counted from 0 at the producer's run start, continuous across frames) carries
  **time sample n = floor(b / 4)**, and in lane L **element k = 16 (b mod 4) + L**. So the four
  beats of time sample n carry elements 0-15, 16-31, 32-47, 48-63 in order.
  Equivalently the stream is **time-major, element-interleaved**: byte offset in the stream
  = 256 n + 4 k.
* **Frame** f (f = 0 for the first frame of a run) of F bytes holds T = F / 256 time samples,
  **n = f T .. f T + T - 1**; within the frame, time sample t (= n - f T) of element k is at byte
  offset **256 t + 4 k**. The frame is the array `int16[T][64][2]` (C order), i.e. the 64 x T
  complex matrix X with leading dimension 64 (column-major, cuBLAS layout), X[k, t].
* **F must be a multiple of 256** for SOURCE 2 (the frame then starts on a time sample and a
  scene change, section 4.4, falls on a time-sample boundary). The demo uses F = 1 MiB
  (`DP_BUFFER_LENGTH` = 1048576): **T = 4096**, 16384 beats per frame. Other F: not tested;
  F not a multiple of 256 is unsupported (no check in firmware or RTL).
* Frames are continuous: the time index runs on across frames exactly as IQ16's does, from 0 at
  every producer run start (data-plane enable, link-pause resume).
* Rate: one frame per `C_HP_PERIOD`, sampled at every frame start (RATE_MBPS written while the
  stream runs takes effect from the next frame; frame size and page ring stay fixed for the run). Per-element sample rate
  Fs = T x frame rate = RATE_MBPS x 1e6 x T / (8 (F + 128)); 1 MiB frames at 64 Gb/s: 7628
  frames/s, Fs = 31.24 MS/s. The generator delivers at most one beat per 200 MHz clock
  (50 MS/s per element, 102 Gb/s); the picture does not depend on Fs.

## 3. Metadata record

The 128-byte record is unchanged in bytes 0-47 (HSB 3.0.0 `frame_metadata_parser.hpp` reads
exactly bytes 0-47: flags, psn, crc, timestamp_s/ns, bytes_written, pad, frame_number,
metadata_s/ns; checked in the HSB 3.0.0 source on the P520). Bytes 48-127 are zero today and
are ignored by HSB. For **SOURCE 2 only**, bytes 48-63 (still in the record's first beat,
`meta0` in `rsys_hsb_prod`) carry, **big-endian** like the rest of the record:

| Byte | Field | Value |
|---|---|---|
| 48 | `scene_id` u32 | SCENE_ID of the scene that generated **every** sample of this frame |
| 52 | `scene_frame` u32 | frame index at which that scene became active (= `S_BM_APPLIED_FRAME` for it) |
| 56 | `frame_index` u32 | this frame's index since the run start, 32 bits (frame_number at byte 34 = its low 16 bits) |
| 60 | `tag` u32 | 0x424D0001 ("BM", layout 1): identifies the beam fields |
| 64-127 | | 0 |

For SOURCE 0 and 1 bytes 48-127 stay zero (no change). The GPU reads the raw record in the page
at byte offset roundup(F, 128) (= F for 1 MiB) of the frame's page; HSB's metadata dictionary
does not contain the new fields. `beam_scene.parse_metadata()` decodes a record.

Requirements on the FPGA: a frame never mixes two scenes (scene changes happen only at a frame's
first beat); the fields describe the scene of that frame's samples, not the scene current when
the record is written. Implementation: the generator carries {scene_id, scene_frame} as a
side-band of every beat through the asynchronous FIFO, the producer latches them at the frame's
first beat, and `frame_index` is the producer's frame counter.

## 4. Registers

### 4.1 Address map and firmware mapping

| Opsero address (HSB register protocol) | System window (rsys) | Access |
|---|---|---|
| 0x7F000004 SOURCE | (firmware `r_ops[1]` -> `C_HP_CTRL[2:1]`) | RW |
| 0x7F000100 .. 0x7F0002FF | 0x0200 .. 0x03FF = cfg[128..255] (`C_BM_*`) | RW, plain storage |
| 0x7F000300 .. 0x7F000318 | 0x04E4 .. 0x04FC = sv[57..63] (`S_BM_*`) | RO |

The firmware **only maps addresses**, no computation:

```c
/* reg_rd / reg_wr of hsb.c, in front of the existing Opsero range check */
if (a >= 0x7F000100u && a < 0x7F000300u) { /* RW: write -> sys_wr, read -> sys_rd */
        sys_addr = 0x0200u + (a - 0x7F000100u); ... return ST_OK; }
if (a >= 0x7F000300u && a < 0x7F00031Cu) { /* RO: read -> sys_rd, write ignored (status 0) */
        sys_addr = 0x04E4u + (a - 0x7F000300u); ... return ST_OK; }
```

plus SOURCE: `src = (r_ops[1] <= 2) ? r_ops[1] : 0;` and `C_HP_CTRL = (src << 1) | run`
`iq_commit()` only for src 0; console `hsb src iq|count|beam`.
Unaligned addresses keep status 0x03. A block write (command 0x09) is executed pair by pair in
order (the host relies on APPLY being executed after the other pairs of the same request).

**RTL register file.** `rsys_pkg::NCFG` is 256 (cfg window 0x0000-0x03FF: write decode
`aw_a[15:10] == 0`, index `aw_a[9:2]`); `Vitis/common/src/rsys_regs.h` is generated from it
(`gen_regs_h.py`). The addresses above are the interface; the bank layout behind them is not.

`C_HP_CTRL` (cfg 84): [0] run, **[2:1] source: 0 IQ16, 1 counter, 2 beam array**, 3 reserved
(behaves as 0). The firmware never writes 3.

### 4.2 Source registers (s = 0..3)

Opsero `0x7F000100 + 0x20 s + offset` = system `0x0200 + 0x20 s + offset` = cfg `128 + 8 s + offset/4`.

| Offset | Name (`C_BM_Ss_*`) | Bits | Meaning | Reset (s = 0 / s = 1..3) |
|---|---|---|---|---|
| 0x00 | CTRL | [2:0] TYPE, [12:8] PRI_LOG2 p, [19:16] SYM_LOG2 L, others 0 | TYPE: 0 off, 1 CW tone, 2 LFM pulse (radar), 3 QPSK (comms / noise-like), 4 pulsed tone; 5-7 = off | 0x00000001 / 0 |
| 0x04 | AMP | [15:0] A (unsigned) | amplitude, full scale 32768 (Q0.15); use <= 32767 | 8000 / 0 |
| 0x08 | INC | [31:0] | phase increment per time sample, 2^32 = Fs (tone / carrier / LFM start frequency) | 0x10000000 / 0 |
| 0x0C | RATE_LO | [31:0] | LFM rate r[31:0] | 0 |
| 0x10 | RATE_HI | [15:0] | r[47:32]; r = 48-bit two's complement, 2^-16 phase units per sample^2 | 0 |
| 0x14 | WIDTH | [31:0] | pulse width W in samples: the gate is open while m < W (types 2, 4) | 0 |
| 0x18 | U | [31:0] int32 | **u in Q2.30**: U = round(u 2^30) | 0 |
| 0x1C | V | [31:0] int32 | **v in Q2.30**: V = round(v 2^30) | 0 |

Direction range: the host keeps |u|, |v| <= 1 and u^2 + v^2 <= 1 (|U|, |V| <= 2^30); the FPGA
accepts any int32 (the phase wraps, section 5.2). U and V are also the steering
"phase-increment words": (2 ix - 7) U is the phase of column ix in 2^32-per-turn units, so moving
a source is **two words** (U, V).

Helpers (`beam_scene.py`): `q230(u)`, `freq_inc(f/Fs)`, `bin_inc(b, T)` (exact FFT bin),
`chirp_rate(start_inc, stop_inc, W)` = trunc((stop - start) 2^16 / W) with start / stop as
signed int32 (the IQ16 rule; the sweep runs from start to stop over the pulse width).

### 4.3 Array registers

| Opsero | System | cfg | Name (`C_BM_*`) | Meaning | Reset |
|---|---|---|---|---|---|
| 0x7F000180 | 0x0280 | 160 | NOISE_AMP | [15:0] A_n, element noise amplitude (section 5.4) | 128 |
| 0x7F000184 | 0x0284 | 161 | NOISE_SEED | [31:0] noise seed (also keys the QPSK symbols) | 0x5EED0000 |
| 0x7F000188 | 0x0288 | 162 | EN_LO | bit k = element k (0-31) enabled | 0xFFFFFFFF |
| 0x7F00018C | 0x028C | 163 | EN_HI | bit k - 32 = element k (32-63) enabled | 0xFFFFFFFF |
| 0x7F000190 | 0x0290 | 164 | SCENE_ID | [31:0] the id of the scene being written (host's choice; 0 = the reset scene) | 0 |
| 0x7F000194 | 0x0294 | 165 | APPLY | write (any value): apply, section 4.4. Reads back the last value written (no meaning) | 0 |
| 0x7F000198-0x7F0001FC | 0x0298-0x02FC | 166-191 | reserved | host writes nothing; reads undefined | |
| 0x7F000200 + 4k | 0x0300 + 4k | 192 + k | GAIN[k] | [15:0] g_I, [31:16] g_Q, int16 **Q2.14** each (16384 = 1.0) | 0x00004000 (1 + 0j) |

A **disabled element outputs noise only** (its steering-table entries are 0, section 5.2):
a failed channel whose ADC still digitises receiver noise. GAIN models the analogue channel
errors (the calibration scene writes random errors; the FPGA applies them, the GPU estimates
and removes them, section 6.6). Gains apply to the signal, not to the noise.

### 4.4 APPLY semantics (atomic scene change)

* Writes to `C_BM_*` change **shadow** registers only; nothing the generator produces changes.
  Reads return the shadow values.
* **APPLY** copies all shadow words (sources, array words, SCENE_ID, the 64 gains) into the
  **staged** scene in one step: words written after the APPLY write belong to the next scene,
  even within the same block request. (RTL: a clk-domain snapshot register set loaded by
  `cfg_wr[C_BM_APPLY]`, or an equivalent that cannot be torn by the next AXI write.)
  `S_BM_STATUS.PENDING` is set.
* The generator computes the staged scene's per-scene constants (section 5.2; one E() unit,
  as built 256 entries + 13 pipeline + 16 settle = about 290 generator clocks = 1.45 us after
  the APPLY write; the contract bound is 10 us) into the inactive bank and
  makes the scene **active at the first frame boundary (first beat of a frame) its head reaches
  after the computation is complete**. With the head at most ~100 beats ahead of the producer
  this is the frame after the one being sent when APPLY arrived, rarely the one after that. The
  host never predicts it: it reads `scene_frame` / `S_BM_APPLIED_FRAME`.
* At activation: `S_BM_APPLIED_ID` = the scene's SCENE_ID, `S_BM_APPLIED_FRAME` = that frame's
  index f, `S_BM_APPLIES` + 1, PENDING = 0, CLIPPED = 0, and the waveform time base restarts:
  **n0 = f T** (section 5.3). The noise does not restart.
* **APPLY while a scene is pending** replaces it: the newer staged scene wins, the older one
  never becomes active (its SCENE_ID never appears in a frame). Host rule: at most one APPLY per
  frame period (the app coalesces to the display rate, <= 60 Hz).
* **APPLY while the generator is idle** (no run with source 2): the scene becomes active at
  once with `S_BM_APPLIED_FRAME` = 0, and it is in force from sample 0 of the next run.
* **Run start** (producer run 0 -> 1 with source 2, including a link-pause resume): n = 0,
  frame index 0; a pending scene is completed and activated first; the active scene continues
  with n0 = 0, `S_BM_APPLIED_FRAME` := 0 (its metadata `scene_frame` = 0).
* **Atomicity requirement:** every frame's samples come from exactly one completely computed
  scene, and its metadata names that scene. A torn scene (half old, half new constants) is a bug.
* After an FPGA reset the generator computes the reset scene (the reset values above: one CW
  emitter at boresight, A = 8000, Fs / 16, noise 128) as if APPLY had been written:
  `S_BM_APPLIED_ID` = 0. So SOURCE = 2 without any BM write shows a picture.

### 4.5 Status registers (read only)

| Opsero | System | sv | Name (`S_BM_*`) | Meaning |
|---|---|---|---|---|
| 0x7F000300 | 0x04E4 | 57 | STATUS | [0] PENDING (an APPLY not yet active; set from the APPLY write itself, so a read after the write's reply sees it) [1] RUNNING (the producer runs with source 2) [2] CLIPPED (a sample of the active scene saturated; cleared at activation and run start) [15:8] model version (1) |
| 0x7F000304 | 0x04E8 | 58 | APPLIED_ID | SCENE_ID of the active scene |
| 0x7F000308 | 0x04EC | 59 | APPLIED_FRAME | frame index (since the run start) of the active scene's first frame |
| 0x7F00030C | 0x04F0 | 60 | APPLIES | scenes activated since the FPGA reset (wraps); the reset scene counts, so it reads 1 after configuration |
| 0x7F000310 | 0x04F4 | 61 | CAPS | **0x01440808** = [31:24] model version 1, [23:20] sources 4, [19:16] log2 lanes 4, [15:8] NY 8, [7:0] NX 8 |
| 0x7F000314, 0x7F000318 | 0x04F8, 0x04FC | 62, 63 | reserved | 0 |

Feature detection by the host: read CAPS. Status 0x03 = firmware without the mapping;
0 = firmware maps it but the bitstream has no generator; 0x01440808 = present.
`B_IQ_CLIP` (0x0C00 + 8 x 14) counts saturated beats of whichever generator the producer takes.

### 4.6 What survives what

| Event | BM shadow registers | Active scene | SOURCE |
|---|---|---|---|
| HSB reset (0x0004 bit 3), `hsb on` / `hsb off`, DP_VP_MASK 0 / 1 | kept | kept (time base restarts at the next run start) | kept (as today) |
| Link pause / resume | kept | kept, n0 = 0 at the resume (a new run) | kept |
| System reset / FPGA configuration | reset values | reset scene | 0 |

### 4.7 Host write sequence (one scene change)

One **block-write request** (command 0x09, <= 183 pairs) per scene change, in this order: the
changed source / array / gain words, SCENE_ID, **APPLY last**
(`Scene.to_registers()` gives the full list, 102 pairs with the gain table;
`Scene.changed_registers(old)` only the changed words: a drag is U, V, SCENE_ID, APPLY = 4 pairs).
SCENE_ID: the app uses a counter starting at 1, +1 per change, never 0. The FPGA does not check
uniqueness.

## 5. The source model (integer-exact)

Every output sample is an exact integer function of (n, k, the active scene, n0). The RTL
must match `beam_model.samples()` bit for bit.

### 5.1 The complex exponential E(phi)

Exactly IQ16's E() (`exp_phi` in `sw/hsb/rocelet_iq.py`; `iq16_exp` in `iq16_gen.sv` can be reused
as is): 32-bit phase, 2^32 = one turn; result (c, s) ~ 131071 (cos, sin), 18-bit signed,
|c|, |s| <= 131071, error < 1.6 LSB (-98 dBc):

```
p = phi[31:22]; quad = p[9:8]; i = p[7:0]
sb = TAB[i]; cb = TAB[255 - i]    TAB[i] = round(131071 sin(2 pi (i + 0.5) / 1024)), i = 0..255
(c, s) = quad 0: (cb, sb)  1: (-sb, cb)  2: (-cb, -sb)  3: (sb, -cb)
d  = phi[21:0] - 2^21                 (signed)
th = asr(d * 411775, 18)              (23-bit signed)
E(phi) = (c - rnd(s * th, 30), s + rnd(c * th, 30))
```

TAB is `IQ16_SIN_TAB` (`SIN_TAB` in `sw/hsb/rocelet_iq.py`; the test checks the model's table and E() against
`sw/hsb/rocelet_iq.py` on random phases).

(Decision: this 18-bit E() instead of a 16-bit LUT: it exists, is verified bit-exact, costs one
RAMB18 + 3 DSP per unit, and the generator needs only a few units, see 5.5.)

### 5.2 Per-scene constants (computed once per APPLY)

For every element k (ix = k mod 8, iy = k div 8) and source s:

```
phi[k,s] = [ (2 ix - 7) * U_s + (2 iy - 7) * V_s ]_32        U_s, V_s signed int32; products / sum mod 2^32
(ec, es) = E(phi[k,s])                                        18-bit
(gI, gQ) = GAIN[k]                                            int16 Q2.14
G[k,s]   = EN_k ? ( rnd(ec*gI - es*gQ, 14), rnd(ec*gQ + es*gI, 14) ) : (0, 0)
```

ec*gI etc. are 18 x 16 = 34-bit products, the sums 35 bits; G components are **20-bit signed**
(|G| <= 524284). phi in radians = pi (x_k u + y_k v) with u = U / 2^30 (since (2 ix - 7) U
= 2 x_k u 2^30 = x_k u 2^31 phase units = x_k u pi). 256 complex entries per scene; lane L of
beat phase q = b mod 4 needs entries k = 16 q + L (ix = L mod 8 is fixed per lane).

QPSK amplitude, per source: `A2_s = rnd(A_s * 46341, 16)` (46341 = round(2^16 / sqrt 2)).

### 5.3 Source waveforms w_s(n) (one complex value per time sample, shared by all elements)

```
j  = [n - n0]_32                time since the scene became active (32-bit, wraps)
m  = j mod 2^p                  p = PRI_LOG2 (0..31); position in the PRI
gate = (m < W)                  W = WIDTH
```

| TYPE | Phase / value | w_s(n) = (wI, wQ) |
|---|---|---|
| 0, 5, 6, 7 off | | (0, 0) |
| 1 CW | theta = [INC * j]_32; (c, s) = E(theta) | (rnd(A c, 17), rnd(A s, 17)) |
| 2 LFM pulse | T(m) = m (m - 1) / 2 (exact); acc = [INC * 2^16 * m + r * T(m)]_48; (c, s) = E(acc[47:16]) | gate ? (rnd(A c, 17), rnd(A s, 17)) : (0, 0) |
| 3 QPSK | sym = j >> L (L = SYM_LOG2); h = H(sym ^ NOISE_SEED ^ SALT_s); a = 1 - 2 h[0]; b = 1 - 2 h[1]; theta = [INC * j]_32; (c, s) = E(theta) | (rnd(A2 (a c - b s), 17), rnd(A2 (a s + b c), 17)) |
| 4 pulsed tone | theta = [INC * j]_32; (c, s) = E(theta) | gate ? (rnd(A c, 17), rnd(A s, 17)) : (0, 0) |

* H = lowbias32 (5.4), SALT = {0xB5297A4D, 0x1B56C4E9, 0x7F4A7C15, 0xD1B54A33} for s = 0..3.
* CW / LFM / pulse: |w| <= A; QPSK: |w| = A within 1.3 LSB (|wI|, |wQ| <= A + 1), the
  symbol (a + jb) / sqrt 2 rotated by the carrier E(theta). For any 16-bit A the components fit
  17-bit signed.
* LFM incremental form (identical mod 2^48, as IQ16's chirp): acc(0) = 0,
  acc(m + 1) = acc(m) + inc48(m), inc48(m) = INC 2^16 + r m; at m = 0 (j a multiple of 2^p,
  and at activation since j = 0) both restart. The instantaneous frequency runs from INC to
  INC + r W / 2^16 over the pulse; the accumulator keeps running (output gated) to the PRI end.
* The PRI is a power of two so that m is the low p bits of the 32-bit time counter j (no divider,
  any p works at any n). Waveforms restart at every activation (IQ16 convention "tones and chirp
  from n0, noise from 0"): a scene change re-starts the tone phase, the PRI and the QPSK symbol
  sequence. With 1 MiB frames and p <= 12 the PRI grid is the same before and after (n0 is a
  multiple of 4096).
* The RTL needs w_s only once per time sample = once per 4 clocks: the four sources can share
  one E() unit and one amplitude multiplier pair (time-multiplexed, s = q).

### 5.4 Element noise n_k(n)

Exactly IQ16's noise (`_hash` and `_noise1` in `sw/hsb/rocelet_iq.py`) evaluated at the **element-sample index
m = 64 n + k** (u64; equal to 16 b + L: the IQ16 noise path with its 16-lane head is reused
unchanged, the beam stream has the same lane count):

```
key = NOISE_SEED ^ [ m[63:32] * 0x9E3779B9 ]_32
hI  = H(m[31:0] ^ key);   hQ = H(m[31:0] ^ key ^ 0x68E31DA4)
H(x): x ^= x >> 16; x = [x * 0x7FEB352D]_32; x ^= x >> 15; x = [x * 0x846CA68B]_32; x ^= x >> 16
u   = h[7:0] + h[15:8] + h[23:16] + h[31:24] - 510          (Irwin-Hall 4, -510..510, RMS 147.8)
n_k = ( rnd(uI * A_n, 7), rnd(uQ * A_n, 7) )                 RMS 1.155 A_n per component
```

The noise runs from n = 0 of the run (not from n0): it does not restart at APPLY. A test checks
beam noise against `rocelet_iq.samples()` of IQ16 scene 4 (noise only) across m[63:32] = 0 -> 1.

### 5.5 Element sample and order of operations

For time sample n, element k:

```
SI = sum_{s=0..3} ( wI_s * GI[k,s] - wQ_s * GQ[k,s] )        products 17 x 20 bits; sum <= 2^38 (40-bit signed)
SQ = sum_{s=0..3} ( wI_s * GQ[k,s] + wQ_s * GI[k,s] )
xI = sat16( rnd(SI, 17) + nI_k(n) )
xQ = sat16( rnd(SQ, 17) + nQ_k(n) )
```

The sum is exact (any DSP arrangement, 4 or 3 multipliers per complex product, cascade order,
gives the same SI / SQ). One rounding (17) before the noise add, one saturation at the end. A
beat whose sample saturated sets CLIPPED and counts in `B_IQ_CLIP`.

Implementation notes (the design as built; not part of the interface): per lane 4 complex MACs
(12-16 DSP48E2, w on the 18-bit port, G on the 27-bit port) = 192-256 DSP; noise 32 lowbias32 =
192 DSP (as IQ16); one shared E() + amplitude for the waveforms; one E() + 4 DSP for the
per-scene table engine; G in a double-buffered 32 x 40-bit LUTRAM per lane (bank swap at
activation). 535 DSP in the routed design next to IQ16's 577 (KU5P: 1824; [](resources.md)).
One sample per lane per 200 MHz clock.

### 5.6 Reference functions

| Spec item | Model function |
|---|---|
| E(), H, Irwin-Hall | `exp_phi`, `lowbias32`, `irwin_hall` |
| phi, G (5.2) | `steering_phase(scene)`, `steering_table(scene)` -> int64 [64][4][2] |
| w (5.3) | `waveforms(scene, n, n0)` -> int64 [len(n)][4][2] |
| noise (5.4) | `noise(scene, n)` |
| samples (5.5) | `samples(scene, n_first, count, n0)` -> int16 [count][64][2] |
| frame | `generate_frame(scene, frame_index, T=4096, scene_frame=0)`; `frame_bytes(x)` = the 1 MiB as received |
| beats | `beat_words(x)` (16 u32 per beat); CLI `--dump-beats FILE --preset P --frame F --scene-frame S --beats B` writes `$readmemh` lines (128 hex digits, byte 63 first) for xsim |
| registers | `Scene.to_registers()`, `Scene.from_registers()`, `--dump-regs`, `--dump-table` |

A mid-run APPLY in xsim: frames before the activation frame A from scene 1 with
`scene_frame = 0`, frames from A on from scene 2 with `scene_frame = A` (the noise follows n
in both).

## 6. GPU application definitions

### 6.1 Data

Per frame: X = the 64 x T complex matrix of section 2, X[k, t] = (xI + j xQ) / 32768 (float32 on
the GPU; `beam_model.to_complex()` in float64). The reference functions are in `beam_model.py`;
the GPU results must agree with them to float tolerance (the application's synthetic source
fills the page ring with `generate_frame()` output, about 22 ms per frame in numpy).

### 6.2 Covariance and steering

* R = X X^H / T (64 x 64 Hermitian; one CGEMM / CHERK per frame; averaging over several frames
  is allowed and must be stated in the UI).
* a(u, v)_k = exp(+j pi (x_k u + y_k v)), x_k = (k mod 8) - 3.5, y_k = (k div 8) - 3.5.

### 6.3 Sky scan (G = 128)

* Grid cell centres u_i = -1 + (2 i + 1) / G, v_j = -1 + (2 j + 1) / G, i, j = 0..G-1. Image
  column = i (u to the right), **row r = G - 1 - j (v up)**. Cells with u^2 + v^2 > 1 are
  outside the visible region: drawn black, excluded from maxima. (`sky_grid()`)
* **Conventional (Bartlett):** P_c(u, v) = a^H R a / N^2 (N = 64; a unit-power source at
  (u, v) gives 1 + sigma^2 / N). (`conventional_map()`)
* **MVDR (Capon):** P_m(u, v) = 1 / (a^H (R + delta I)^-1 a), **delta = 1e-3 x trace(R) / N**
  (diagonal loading, a UI knob; `mvdr_map(R, G, loading)`).
* Display: conventional 10 log10(P / max P) clipped to [-40, 0] dB; MVDR on an absolute scale,
  -10 to -40 dB re the mean element power tr(R) / N (`--mvdr-top-db`); with the true source
  positions as markers (emitters s = 0, 1 circles; jammers s = 2, 3 squares, another colour).

### 6.4 Steered beam

* Conventional weights w_c = a(u0, v0) / N; MVDR weights w_m = (R + delta I)^-1 a / (a^H (R +
  delta I)^-1 a) (distortionless: w_m^H a = 1).
* Beam pattern over the sky: B(u, v) = |w^H a(u, v)|^2 (`beam_pattern()`); the MVDR pattern shows
  the nulls on the jammers.
* Beam output y = w^H X (length T); spectrum |FFT(y)|^2 / T^2, fftshifted (`beam_spectrum()`);
  bin b corresponds to INC = b 2^32 / T (a CW source with INC = `bin_inc(b)` lands exactly on
  bin b; positive INC = positive frequency).

### 6.5 Element failures

The app knows the mask it wrote. A disabled element carries noise only; the GPU may keep it (the
picture degrades: higher sidelobes, and MVDR nulls its own source) or exclude it (rows/columns
removed / zeroed in R and a). The demo excludes it (`BeamGpu.set_mask`: the steering entries of
disabled elements are zeroed, the conventional map is normalised by the enabled count); the
calibration excludes disabled elements too.

### 6.6 Calibration (key C)

Scene: one CW source at a known direction (u_c, v_c) (preset 5: boresight), no other source,
gains with errors. Estimator (`calibrate(R, u_c, v_c, enable)`):

```
v0 = a(u_c, v_c) with disabled elements set to 0;  R' = R with disabled rows/columns set to 0
repeat 8 times: v = R' v; v = v / |v|                 (power iteration: the dominant eigenvector ~ g . a)
g_k = v_k / a_k(u_c, v_c) for enabled k;  g = g / mean_enabled(g);   g_k = 1 for disabled k
```

Correction: X'[k, t] = X[k, t] / g_k (equivalently R' = D^-1 R D^-H, D = diag(g)), for every
following frame until R(eset). The overall complex scale of g is unobservable (mean 1 by
definition). Test tolerance: |g_k - g_true,k / mean(g_true)| < 0.02 at the preset 5 SNR, also
with failed elements. Without calibration MVDR self-nulls the source (steering mismatch); after
it, both maps sharpen.

### 6.7 Latency measurement

Host monotonic clock only (the metadata timestamps are FPGA time, not synchronised):

* t_input: the GUI event (mouse / key) that changed the scene.
* t_apply: the reply to the block write containing APPLY arrived (the scene is staged on the
  board).
* t_data: the app first processes a frame whose metadata `scene_id` equals the new SCENE_ID
  (its `scene_frame` = `frame_index` of that frame, unless an intermediate frame was skipped).
* t_pixel: the image computed from that frame has been submitted to Holoviz.
* Report **mouse-to-data = t_data - t_input**, **data-to-pixel = t_pixel - t_data**, and the
  board's part in frames = scene_frame - (frame_index of the newest frame received at t_apply).
  Expected: write ~100 us, activation in the next frame (131 us at 64 Gb/s), measured 1.5-2.7 ms p50 on the bench ([Measured](beam_demo.md#measured))
  mouse-to-data.

### 6.8 Attract mode (host only)

When no input for 10 s, the app moves the sources itself at ~20 Hz (one block write with U, V,
SCENE_ID, APPLY per update; nothing in the FPGA): source s on a circle
u = r_s cos(2 pi t / P_s + ph_s), v = r_s sin(...), r = (0.45, 0.6, 0.3, 0.7), P = (20, 27, 33,
41) s, ph = (0, 1.3, 2.6, 3.9) rad, only for sources whose TYPE != 0. Pointer input, a preset or reset
stops it; B, C and N (beamformer, calibration, noise) do not.

## 7. Presets (`beam_scene.preset(n)`; keys 1-5)

Frequencies on exact bins of 4096 unless noted; SNR per element = A^2 / (2.667 A_n^2) (pulse:
peak). Noise seed 0x5EED0B00 + n; all gains 1, all elements on unless noted.

| # | Name | Sources | A_n | Notes |
|---|---|---|---|---|
| 1 | single emitter | s0 CW, A 4000, INC 0x0C800000 (bin 200), (u, v) = (0.30, 0.20) | 400 | SNR 15.7 dB per element |
| 2 | emitter + jammer | s0 LFM pulse, A 3000, PRI 2^10, W 512, INC 0xCCCCCCCD (-0.2 Fs) to +0.2 Fs: r = 219902325504, (-0.35, 0.20); s2 QPSK jammer, A 24000, L 1 (2 samples / symbol), INC 0x19A00000 (bin 410), (0.275, 0.10) | 300 | J/S +18 dB; the jammer's conventional sidelobe toward the emitter is -18.8 dB, so the conventional map hides the emitter and MVDR shows it (null depth vs conventional -36 dB) |
| 3 | two emitters 1 beamwidth apart | s0 CW A 4000 bin 200 (-0.11, 0.10); s1 CW A 4000 bin 337 (0.11, 0.10) | 300 | du = 0.22 = one half-power beamwidth: conventional = one blob, MVDR = two peaks (incoherent: different frequencies) |
| 4 | failed elements | as preset 1 | 400 | elements 3, 12, 21, 30, 46, 57 disabled (EN = 0xFDFFBFFFBFDFEFF7) |
| 5 | uncalibrated array | s0 CW A 4000 bin 200 at boresight (0, 0) | 300 | gains `random_gain_errors(seed 1, +-30 deg, +-1.5 dB)` (PCG64, quantised Q2.14); the calibration scene |

Peak element amplitude: no preset clips (checked by the tests for frame 3; preset 2 peaks at
28006).

## 8. Verification hooks

* `python3 -m unittest discover -s sw/beam/tests -v`: determinism, int16 / no-clip of the
  presets, saturation, frame continuity, packing (beat / lane / element), n0 semantics, disabled
  element = noise only, E() and noise = the IQ16 primitives, waveform types (CW bin, pulse and
  LFM gates and sweep, QPSK constellation / symbol hold), register round trip and layout, reset
  scene, metadata parse, source peak within one grid cell (4 directions), MVDR null > 20 dB vs
  conventional, MVDR resolves preset 3 where conventional cannot, calibration < 0.02 (also with
  failed elements) and a source correctly placed after calibration.
* FPGA: xsim against `--dump-beats` (several presets, a frame near n = 2^26 (m[63:32] = 1) and a
  mid-run APPLY), then on the bench: frames at 64 Gb/s with SOURCE 2, the GPU or a host script
  comparing whole frames with `generate_frame(scene, f, scene_frame)`.
* GPU application: the synthetic source from `generate_frame()`; sky maps against `conventional_map()` /
  `mvdr_map()`; peaks where `beam_scene` puts the sources.
