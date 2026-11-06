# Revision history

## 2025.2 — version 0.5.0 (2026-11-05), ZCU106 target

A second target, **`zcu106`**: the ZCU106 with the 2x QSFP28 FMC (OP120) on HPC0, QSFP28 port 0
at **40 Gb/s**, entirely license-free. The Zynq UltraScale+ has no hard 100G MAC, so the link
runs on the new open-source Ethernet MACs of
[opsero-ethernet-mac](https://omac.ethernetfmc.com) v0.1.0 (`omac_40g`, 40GBASE-R4; `omac_10g`,
10GBASE-R, as a build option), and the engine is rocelet v0.3.0, whose MAC side now takes
256-bit and 64-bit MACs. The design is built for the Zynq UltraScale+ processing system: Linux
on the Cortex-A53 runs the control plane (or a bare-metal A53 console), so that it also serves
as the starting point for the RFSoC boards ([](porting.md)). The kcu116 target keeps its
function; its CMAC now sits behind the same generic MAC boundary. Validated on hardware
against an NVIDIA ConnectX-6 Dx forced to 40G (and 10G) with FEC off, in the same test host
as 0.4.0.

### Changes

* **zcu106 hardware** ([](zynqmp_hw.md)): `mac0` = omac_40g on the four GTH transceivers of
  QSFP28 port 0 (the free transceiver wizard, generated from the omac submodule at build time),
  256-bit AXI-Streams at 156.25 MHz; the engine at 512 bits with rocelet's width converters at
  the MAC boundary. An **always-on register block with a clock guard** (`rsys_aon`): GT / MAC
  resets, link and lane status, QSFP module lines, the measured MAC clock, one aggregated
  interrupt, and a guard that completes every CPU access to the MAC clock domain (poison value
  `0xDEADC10C` while the clock is stopped) so the A53 can never hang or take an SError there.
  A **PS DDR window** next to the 256 KB URAM window: one region given at run time
  (`C_DDR_BASE` / `C_DDR_SIZE`, a null target outside it), spread over **two HP ports per
  direction** (`rsys_axi_ilv`, 512-byte granules) to carry 40G. A **netdev DMA channel**
  (`rsys_odma` + AXI DMA in scatter-gather mode) carries every non-RoCE frame to and from Linux.
  A **streaming source boundary** for the HSB producer (`s_axis_src` + `rsys_src_mux`, input 3
  reserved for a design source such as an RF-ADC stream). Port 1's lanes are reserved.
* **10G option**: the same label builds with omac_10g on QSFP lane 0
  (`python3 config/update.py --mac zcu106=omac_10g`; constraints `zcu106_omac_10g*.xdc`).
* **Generic MAC boundary** in `rocelet_sys` (`mac_ctl`, `mac_pz`, `mac_addr`, `mac_stat`,
  `mac_ev`, `mac_pause`, AXI-Streams at `MAC_WIDTH`); the kcu116's CMAC connects through
  `mac_cmac_adapt`, the ZCU106's omac through `mac_omac40g` / `mac_omac10g`. `rsys_ptime` takes
  the clock frequency as a parameter.
* **Firmware**: one source tree for the KCU116 MicroBlaze console, the ZCU106 A53 bare-metal
  console and the Linux daemon (a platform layer `plat.c`, MAC backends in `mac.c`); one ZCU106
  binary for both MACs (MAC type and rate from the always-on `CAPS`); the 40G lane line in `st`;
  the engine's `PAUSE_RX_LEVEL` and `PAUSE_QCLK` for omac; **PAUSE TX on after boot on the
  ZCU106** (point-to-point link; the KCU116 default stays off); memory window `mr=3` over PS DDR
  with `ddr`, `ddr fill`, `ddr check`; the Opsero HSB register **`LINK_GBPS`** (0x7F000018: 100,
  40 or 10).
* **Linux** ([](zynqmp_linux.md)): an AMD EDF (Yocto 2025.2) image with the daemon `roceletd`
  (owns the hardware through UIO and i2c-dev, runs the console sources), the command line `rl`,
  the network driver `rl_net.ko` (interface `rl0`: Linux owns the port's IP address, RoCE v2
  stays in hardware), a web UI on port 80, a 256 MB `reserved-memory` region for the PS DDR
  window (UIO, PYNQ-compatible), the HSB control plane on UDP sockets over `rl0`, QP records over
  SSH. `rl0` takes an MTU up to 9578 and reports its statistics through `ethtool -S`. The web UI
  has an optional access token (`token` in `/etc/rocelet/rocelet-web.conf`; empty by default,
  and the page then warns that anybody on the network can control the design).
* **Host software**: the beamforming demo reads `LINK_GBPS` and limits its rate range to the
  link (1-40 Gb/s on the ZCU106); its window header and page name the board and link from it
  (`ZCU106 -> 40G RoCE -> GPU`, `KCU116 -> 100G RoCE -> GPU`; `--board` for a ported board).
* **Fixes**: the console's counter-name table had 48 of 56 entries (a NULL read when the new
  netdev / PS DDR counters were non-zero; a crash in the daemon); the Si5328 reset write is no
  longer reported as a failure under the Linux I2C driver; the A53 console writes its PS DDR
  buffer's cache lines back at start-up (a dirty line could overwrite the first beat of the
  first host WRITE).
* **GT placement in data.json**: the transceiver channels of the QSFP28 port (`gt_channels`,
  QSFP lane order), the omac reference clock (`gt_refclk`) and the CMAC site (`cmac_core`) are
  target attributes instead of literals in `build.tcl` / `bd_microblaze.tcl`; the
  `mac_omac40g` lane map `CH_OF_LANE` is derived from the same list. A new board is a data.json
  entry and its constraints ([](porting.md#gt-placement-in-datajson)). Both targets build
  to the same transceiver configuration as before.
* **Simulation**: the system testbench (`run_xsim.sh`) also runs through a narrow MAC
  (`MAC_WIDTH=64` or `256`: rocelet's width converters, as on the ZCU106) and with the Zynq
  UltraScale+ options (`ZU=1`: PS DDR window over two ports per direction and netdev DMA channel,
  tests `ddr` and `odma`; `DDRP=1` for a one-port window); new testbenches `tb_aon` (always-on
  block and clock guard, `run_xsim_aon.sh`) and `tb_axi_ilv` (the two-port PS DDR interleave,
  ordering and throughput, `run_xsim_ilv.sh`).
* **Build**: `Vivado/scripts/xsa.tcl` puts the bitstream into the XSA (exported from the routed
  checkpoint when the project-mode export cannot see it); `build.py` updated to the common
  build runner of the Opsero reference designs, with the `yocto` stage (the zcu106 Linux image)
  and `package` gathering the standalone and Yocto zips.
* **Submodules**: rocelet v0.3.0 (generic MAC side, `MAC_WIDTH`, `LINK_GBPS`, `CLK_KHZ`,
  `PAUSE_QCLK`, capability registers), opsero-ethernet-mac v0.1.0 (new).
* **Docs**: getting started and host setup per target; the hardware pages organised by design
  family, named after the build flow's family token: [](hardware.md) (a per-target table
  generated from data.json), [](microblaze_hw.md), [](zynqmp_hw.md) and [](zynqmp_linux.md),
  each written board-agnostically with a **Board specifics** subsection per board (the template
  for a new board, [](porting.md)); [](description.md) now covers the shared `rocelet_sys`; a
  generated block diagram of the Zynq UltraScale+ design (`rocelet-zynqmp-block.png`), the
  MicroBlaze diagram updated (`cmac_adapt`, `u_smux`); the ZCU106 measurements on
  [](resources.md).

### Measured (2026-11-04)

ZCU106 + OP120 port 0, 3 m DAC to the ConnectX-6 Dx forced to 40000, FEC off, MTU 4200; the
Linux image unless stated. Every figure: [](resources.md#measured-zcu106-40g-and-10g).

* Link on the first attempt (4.8-5.7 s), lanes in order, 0 BIP errors; `rl t pma` SELFTEST PASS
  19/19 (also with the 10G option).
* RDMA payload at 40G: FPGA WRITE with immediate 38.83 Gb/s, host WRITE 38.74, host SEND 39.20,
  host READ 38.73 (line rate also at PMTU 1024 and 512), host WRITE into the PS DDR window 38.75
  and READ of it 38.74, lossless without PAUSE frames.
* PAUSE both ways: 174,494 PAUSE frames sent by the FPGA (one-port PS DDR layout) all honoured
  by the ConnectX-6 Dx; the host's PAUSE frames held the FPGA's stream (38.78 → 23.89 Gb/s,
  0 lost).
* `rl0`: flood ping 20000 x 1400 B with 0 % loss; HSB IQ16 / counter frames into GPU memory at
  39.0 / 38.96 Gb/s, every frame checked, 0 lost; beamforming demo at the 40 Gb/s cap; web UI.
* 10G option: RDMA 9.44-9.80 Gb/s, PS DDR window 9.13-9.80 Gb/s.

### Resources and timing

zcu106: **96,973 LUT (42.1 %)**, 87 BRAM36, 16 URAM, 1,116 DSP on the XCZU7EV-2, WNS +0.304 ns,
WHS +0.007 ns, no critical warnings; the 10G option 84,198 LUT, WNS +0.345 ns. kcu116 after the
MAC-boundary refactor: 69,178 LUT, WNS +0.023 ns. See [](resources.md).

### Limitations

* **kcu116**: rebuilt with rocelet v0.3.0 and the generic MAC boundary (the simulation regression
  passes at 512 bits and the build closes timing), but this release was validated on hardware
  with the ZCU106 only; the KCU116 measurements are those of 0.3.0 / 0.4.0. Its MicroBlaze
  console has 328 bytes of local memory left.
* **zcu106**: the host port must be forced to 40G (10G) with auto-negotiation and FEC off.
  OP120 port 1 is not used.
* omac_40g: back-to-back frames whose length without FCS is 1-7 bytes past a multiple of 32
  cannot run at the full 40.0 Gb/s (RoCE traffic is not affected; the always-on `RX_OVF`
  counter shows cut or dropped frames).
* The PS DDR window carries 40G with two HP ports per direction; at 100G (a future RFSoC CMAC
  target) it would need more ports or keep line-rate traffic in URAM.
* `rl0` is a control and convenience interface, not a fast NIC: TCP into the board measured
  2.2 Gb/s with an untuned receiver, and frames arriving while Linux has no free receive buffer
  are dropped by the PL (counted; TCP recovers).
* The 10G option is a manifest option: no prebuilt image is published for it.
* PAUSE TX is on by default on the ZCU106: the host must honour 802.3x PAUSE (the ConnectX-6 Dx
  does by default) or `pause tx 0` must be set.

## 2025.2 — version 0.4.0 (2026-11-03), beamforming demo

A phased-array **beamforming demo** on top of the Holoscan Sensor Bridge device mode: an 8 x 8
antenna array generator in the FPGA streams every element's samples over rocelet into GPU
memory, a CuPy beamformer draws the sky (conventional and MVDR) in a Holoviz window, and the
person at the monitor moves the sources, which writes the new scene back to the FPGA over the
HSB register protocol. See [](beam_demo.md). The rocelet engine (v0.2.2), the IQ16 and counter
sources and the rest of the HSB device mode are unchanged, apart from the stream rate, which now
changes while the data plane runs (below). Validated on the same hardware as
0.3.0 (KCU116 + OP120 port 0, ConnectX-6 Dx, RTX PRO 4000 Blackwell, Lenovo P520), with a
monitor on the GPU.

### Changes

* **Beam array generator** (RTL `rsys_beam_src`, instance `u_bms`): Opsero SOURCE 2 of the
  frame producer. 64 elements of an 8 x 8 half-wavelength array, up to four sources (CW tone,
  LFM pulse, QPSK, pulsed tone) with directions in Q2.30, per-element complex gains, an element
  enable mask and element noise, bit-exact with `sw/beam/beam_model.py`; atomic scene changes
  (shadow registers, APPLY, active at the next frame boundary, ~1.5 us to compute); 200 MHz
  generator clock, up to 102 Gb/s. Specification: [](beam_contract.md).
* **Registers**: Opsero 0x7F000100-0x7F0002FF (scene words, APPLY, gain table) and
  0x7F000300-0x7F000318 (status, CAPS 0x01440808), mapped by the firmware onto the system
  registers `C_BM_*` / `S_BM_*`; the system register file has 256 configuration words
  (`rsys_pkg::NCFG`, was 128); `C_HP_CTRL[2:1]` selects the source (0 IQ16, 1 counter, 2 beam
  array).
* **Metadata**: for SOURCE 2 the frame's metadata record carries scene_id, scene_frame, a 32-bit
  frame index and the tag 0x424D0001 in bytes 48-63 (HSB reads bytes 0-47 only).
* **Firmware and console 0.4.0**: the beam register mapping (a block write is executed pair by
  pair, APPLY last), SOURCE 0-2, `hsb src iq|count|beam`, the beam generator line in `hsb st`
  (active scene id, its first frame, applies, pending / running / clipped, and "APPLY pending
  (scene N)", "scene N staged without APPLY" or "nothing staged").
* **Stream rate while running**: the frame producer (`rsys_hsb_prod`) samples `C_HP_PERIOD` at
  every frame start instead of latching it at the data-plane enable, and the firmware rewrites
  it whenever RATE_MBPS is written (register protocol or `hsb rate`), so the rate of a running
  stream changes from the next frame on, for every source. Source, page ring and frame size
  stay latched for the run. In the demo: keys - / + (1, 2, 5, 10, 20, 40, 64, 80 Gb/s) and the
  page's rate buttons / `rate` command (1-80 Gb/s).
* **Host software** (`sw/beam/`, HSB 3.0.0 container, Holoscan 4.4, CuPy): the Holoscan
  application `rocelet_beam_app.py` (HSB `RoceReceiverOp` into GPU memory, CuPy beamformer:
  covariance in complex128, Bartlett and MVDR sky on a 128 x 128 grid, steered beam pattern and
  cuFFT spectrum, calibration; Holoviz window with mouse, wheel and key control, presets 1-5,
  attract mode, latency tiles; `--verify` against a bit-exact CUDA generator; headless PNG
  mode; synthetic sources without the board), the register path `beam_regs.py` (one block
  write per scene change), the reference model `beam_model.py` / `beam_scene.py` and tests. A tablet / phone web page (`beam_web.py`, `--web 8090`: Server-Sent
  Events with the sky map at 10 Hz, the same controls as the window, `/state` and `/control`
  endpoints), the MVDR map on an absolute scale (-10 to -40 dB re the mean element power,
  `--mvdr-top-db`), and the hint "array uncalibrated: press C".
* **Simulation**: `Vivado/src/hdl/tb/run_xsim_beam.sh` (the generator against the model,
  114,688 beats bit-exact), `run_xsim.sh hsbbm` (the producer with the beam generator) and
  `run_xsim_prod.sh` (the producer alone: every frame interval against the period sampled at its
  start, ten period changes mid-stream, back to back and with back-pressure).
* **Docs site**: new pages [](beam_demo.md) and [](beam_contract.md); the beam generator in the
  [design description](description.md#beam-array-generator), the block diagram and the
  [resources](resources.md); the HSB page links the demo.

### Measured (hardware session B5, 2026-11-03)

Board: KCU116 + OP120 port 0, 3 m DAC to the ConnectX-6 Dx; 1 MiB frames. Results marked
**(P520)** belong to the test host.

* Every frame the application took compared with the bit-exact CUDA generator for the scene in
  its own metadata: 24,000-27,000 frames per 60 s run at 10, 40, 64 and 80 Gb/s, about 1,100
  scene changes per run, **0 mismatches**, 0 frames lost after the first 2 s.
* Window on the monitor: 45-47 frames beamformed and shown per second at every rate, GPU
  3.2-3.3 ms per shown frame, mouse to data 1.5-2.7 ms (p50), mouse to pixel about 23 ms (60 Hz
  vsync; 44 ms at 10 Gb/s), board activation 0-1 frames after the APPLY reply.
* Register path: a full scene (102 words) 0.6 ms, a 4-word drag write 0.09 ms.
* 20-minute soak at 64 Gb/s (window, attract mode, verify): 9.24 M frames into GPU memory,
  0 lost, 0 NIC discards, 19,128 frames verified with 0 mismatches, 20,053 scene changes, GPU
  memory flat at 933 MiB. SIGTERM / SIGINT stop the data plane; the next run starts without a
  power cycle.
* Release bitstream (`42cf7df`, console 0.4.0-dev, FWTEST PASS): verify 0 mismatches in 22,755
  frames at 64 Gb/s and 9,014 at 80 Gb/s; a final 10-minute run at 64 Gb/s with the tablet page
  open: 4.56 M frames into GPU memory, 0 lost, 5,444 verified with 0 mismatches, 10,934 scene
  changes, GPU 3.48 ms per shown frame, 42.8 shown per second, mouse to data 1.55 ms, mouse to
  pixel 28 ms. A jammer drag from the page: mouse to data 2.97 ms.

### Resources and timing

Routed design `f75b487` (with the live frame period; `88981d6` / `42cf7df` before it: 68.4k
LUT, WNS +0.040 / +0.330 ns): **68.6k LUT (31.6 %)**, 1,118 DSP (61 %), 98 BRAM36, 16 URAM; the
beam array generator 12.1k LUT, 535 DSP, 2.5 BRAM36. Timing met: CMAC user clock (322 MHz) WNS
+0.002 ns (after post-route physical optimisation), generator clock (200 MHz) +0.371 ns, all hold
slacks positive. Console 0.4.0-dev: 1,560 bytes of local memory free. See [](resources.md).

### Limitations

* The P520's NIC-to-GPU path ends at about 81 Gb/s **(P520)**, as in 0.3.0.
* Occasional start-up loss at a 40-80 Gb/s data-plane start into GPU memory (0-6 frames in
  the first 2 s in one session, 0 in 12 starts in the next; ConnectX-6 `rx_discards_phy` while
  the NIC-to-GPU path warms up) **(P520)**; the application reports it apart from the run.
* MVDR costs about 6 ms GPU per shown frame (conventional about 3.5 ms).
* Failed elements are removed from the steering vectors (the maps, weights and patterns use the
  enabled elements only), so MVDR keeps its peak on the source in preset 4 (-7.8 dB re element
  power, from -23.7 dB before the fix).
* The tablet page has no authentication and has not yet been opened on a real tablet.
* Mouse to pixel is dominated by the display (vsync), not by the data path.
* The window needs a monitor on the GPU, the full NVIDIA display driver and an X session on
  the host; without them the application runs headless (PNG files). On the test host the X
  configuration must leave the forced 1920 x 1080 mode as the only 1080p mode **(P520)**.
* The array geometry is fixed at 8 x 8; narrowband (phase-shift) beamforming only.

## 2025.2 — version 0.3.0 (2026-10-31), first release

The first release of the design: the KCU116 with the 2x QSFP28 FMC (OP120) port 0 as a 100G
RoCE v2 endpoint built around the open-source rocelet engine (v0.2.2), and as a **Holoscan
Sensor Bridge (HSB) device** for NVIDIA's HSB 3.0.0 host software. Validated on hardware
against an NVIDIA ConnectX-6 Dx (firmware 22.43.2566, inbox mlx5) with an RTX PRO 4000
Blackwell GPU, test host Lenovo P520.

### RoCE v2 endpoint (rocelet v0.2.2, console)

* rocelet submodule v0.2.2: READ depth fix for the ConnectX-6's READ re-issue, requester ACK
  timeouts held while the link is down and for `LINK_GRACE` after it returns, defaults ACK
  timeout 5 ms and grace 2 s, `link_up` = `stat_rx_aligned & ~stat_rx_local_fault &
  ~stat_rx_remote_fault` (details in the development entries below and rocelet's CHANGELOG).
* Measured against the ConnectX-6 Dx (3 m DAC, RS-FEC, MTU 4200): FPGA WRITE with immediate
  into host memory 98.01 Gb/s, host WRITE 96.79 Gb/s and host READ 96.59 Gb/s of the FPGA's
  memory window, go-back-N after a dropped last packet 5.0 ms, `t pma` self-test 19/19 in
  2.8 s. Link loss at the defaults: a real cable pull (14.9 s outage during a 40 Gb/s stream)
  resumed 1.9 s after the ConnectX-6 carrier returned with 1 timeout and 8.85 M messages, 0
  lost / duplicate / corrupt; forced 5 s / 30 s drops resumed 1.8 / 2.0 s after the carrier.

### Holoscan Sensor Bridge device mode (new)

* **Enumeration** (console `hsb on`): BOOTP v2 once a second from UDP 12268 to 12267 with the
  Opsero UUID 98183d0f-18ee-4719-a3b4-ca69e9b94c97, compat-id and HSB IP version 0x2603, and a
  serial number from the device DNA; `hololink-enumerate` lists the board.
* **Register protocol**: the HSB Ethernet Control Bus on UDP 8192 (read / write, dword /
  block, sequence check, status 0x03 for unmapped addresses) with the register file a stock
  HSB 3.0.0 host programs; the HSB reset; Opsero registers at 0x7F000000 (frame source, rate,
  scene, frame count, status, producer watchdog).
* **Data plane**: the host's DP_* registers are translated into rocelet **QP 13, type UC-HSB**
  (PSN 0, UDP source 12288, PMTU from DP_PACKET_SIZE: MTU 1500 gives 1024-byte packets, 4200
  gives 4096) and the producer's page ring, frame size and pacing; the data plane starts only
  after the reply to the host's DP_VP_MASK write.
* **Control-plane receive FIFO** (RTL `rsys_crx`, 16 x 2 KB): the HSB frames of the engine's
  other-traffic port, queued for the firmware.
* **Frame producer** (RTL `rsys_hsb_prod`): per frame, data WRITEs and one metadata WRITE with
  immediate in HSB's format; sources: the **IQ16 test signal** (the IQ16 test-signal generator
  in a 200 MHz clock behind an asynchronous FIFO: four tones, a chirp and noise; the sample rate follows the frame rate the host sets, 2.5 GS/s at
  80 Gb/s) or a counter pattern.
* **Opsero `hololink_module`** (`sw/hsb/module/`):
  `hololink_98183d0f-18ee-4719-a3b4-ca69e9b94c97_2603.so` for HSB's module API (one sensor, data
  plane 0, one SIF), built against a holoscan-sensor-bridge 3.0.0 checkout. The classic API
  needs no module.
* **Producer watchdog**: an optional keepalive timeout (KEEPALIVE_TIMEOUT_MS / KEEPALIVE /
  WATCHDOG_COUNT at 0x7F000020-0x7F000028, off by default and one-shot, so stock HSB
  applications keep the stock behaviour) stops the data plane when the host application dies
  without stopping it; **link pause** (default on, LINKPAUSE_COUNT 0x7F00002C) stops the
  producer while the link is down and resumes it when the link is back and the ACK hold has
  ended.
* **Console**: `hsb on|off`, `hsb st` (identity, protocol counters, receive FIFO, registers,
  data plane, producer and its QP, watchdog), `hsb serial`, `hsb src iq|count`, `hsb rate`,
  `hsb scene`, `hsb wd <ms>`, `hsb lpause on|off`; `qp 13` shows the UC-HSB data plane.
* **Host software** (`sw/hsb/`, HSB 3.0.0 container, Holoscan SDK 4.4):
  * `rocelet_hsb.py`: classic-API example with the Linux-UDP receiver (enumerate, register
    read / write, checked counter or IQ16 frames).
  * `rocelet_hsb_app.py`: Holoscan application with HSB's `RoceReceiverOp` into GPU memory, a
    **C++ checker operator** (`sw/hsb/cpp/`, default) or the Python one (counter word by word,
    IQ16 sample by sample against the bit-exact model `rocelet_iq.py`, metadata PSN,
    bytes_written, lost frames), and a **demo mode**: cuFFT spectrogram of the IQ16 signal as a
    Holoviz waterfall (window or headless PNG). Classic API (default) or module API
    (`--api module`). Start gate (the board's data plane starts only when the whole graph is
    up), keepalive for the producer watchdog (default 2 s), resync after a link-pause restart,
    blocking receiver scheduling (no frame-rate decay), synthetic sources with fault injection
    for tests without the board.
  * Changes from the release validation (hardware session G): `--start-delay` default 0 also
    in demo mode (an idle GPU drops to its lowest PCIe link speed during a delay and the
    line-rate start then overflows the NIC), `--queue-size` default 32 (absorbs host stalls),
    the verdict FAILs when the producer watchdog stopped the data plane or no frame arrived at
    the end of a run, module API: the start gate waits for the receiver's device start and the
    16-bit frame number is extended (no false resync at every wrap).

### Measured (hardware sessions E, F and G, 2026-10-31)

Board: KCU116 + OP120 port 0, 3 m DAC to the ConnectX-6 Dx. Results marked **(P520)** belong to
the test host (Lenovo P520, Xeon Skylake-SP, PCIe Gen3, RTX PRO 4000 Blackwell), not to the
design.

* Enumeration, register protocol and reset: ~20 host tool runs with 0 sequence errors and 0
  receive FIFO drops; `Hololink.reset()` in 0.15 s, the next announcement 1.0 s later.
* The board sends 97.6 Gb/s (counter) / 97.4 Gb/s (IQ16) of frame payload unpaced.
* RoCE receiver into GPU memory clean to 80 Gb/s (79.98 Gb/s measured); the NIC-to-GPU path
  ends at about 81 Gb/s **(P520)**. Linux-UDP receiver clean to 8 Gb/s, drops at 16 Gb/s
  **(P520)**. MTU 1500 (1024-byte packets, 1025 packets per 1 MiB frame) and odd frame sizes
  clean.
* Check mode clean at 10, 40 and 80 Gb/s for the counter pattern and the IQ16 signal (the first
  bit-exact IQ16 check on hardware at rate, ~2.3 M frames in session F): 0 errors, 0 lost, 0
  PSN errors, 0 NIC discards.
* Frames checked at 80 Gb/s with 1 MiB frames (~9,500 frames/s) **(P520)**: C++ checker 99.87 %
  (counter, 5 min) and 99.97 % (IQ16, 3 min) with the default queue of 32 on 0.86-0.87 CPU
  cores (99.36-99.68 % with a queue of 8); Python checker 96.4 % on 1.24 cores; module API
  91.5 % (asynchronous only, 2 cores) and 100 % at 40 Gb/s; demo (checker, spectrogram,
  Holoviz) 91-95 % on 1.2 cores. Frames the application cannot take are counted as
  consumer-dropped, not as errors.
* Start gate: 0 start-up drops, the first frame at the checker 1 ms after the data-plane
  enable, 0 NIC discards and 0 pause frames at the 80 Gb/s demo start.
* Producer watchdog: with a 2 s keepalive, a SIGKILLed application stops the board 1-2 s after
  the kill and the next run passes without any manual register write; `hsb wd 3000` stops it
  ~3 s after the arm.
* Link pause (console `link` during a 40 Gb/s run): producer paused ~7 s (relink, partner
  link-up, 2 s grace), 0 frames lost, 0 errors, 1 resync in the checker, no watchdog stop.
* Demo waterfall at 80 Gb/s: the four tones and the chirp at 2.494 GS/s, 0 errors.

### Limitations

* A producer resumed after a link pause restarts at frame number 0, the first page and IQ16
  sample 0 (the producer RTL has no hold input); the checkers recognise it as a resync with no
  data errors. (0.4.0 uses `C_HP_CTRL[2:1]` for the source select; a hold input that continues
  the frame numbering remains future work.)
* HSB's module API receiver has no completion count and no blocking mode: lost and
  consumer-dropped frames are not separable and it checks 91.5 % of the frames at 80 Gb/s. Use
  the classic API (default) at 40 Gb/s and above.
* With 1 MiB frames at 80 Gb/s the application checks about 99.9 % of the frames, not every
  frame: host stalls drop bursts of 60-500 frames at the receiver. Larger frames lower the
  frame rate: with 4 MiB frames (16 pages, 2,400 frames/s) session F checked 99.76 % at
  79.99 Gb/s (before the start gate; the misses were start-up drops plus 10-15 frames in
  5 min).
* The P520's NIC-to-GPU path ends at about 81 Gb/s **(P520)**: above it the NIC drops packets of
  every kind, including the board's register replies. Do not leave the GPU idle between
  configure and start at line rate (keep `--start-delay 0`).
* PTP is a stub (SYNC_STAT 0, metadata timestamps from a free-running clock); one data plane,
  one sensor; no I2C / SPI / GPIO sensor access; frame CRC 0.
* Without the keepalive (stock HSB applications) a killed application leaves the board
  streaming, as NVIDIA's devices do: stop it with `hololink-write 0x0200030C 0`.
* MicroBlaze firmware: 128,680 of the 130,992 bytes of local memory used (2.3 KB headroom).
* Not tested: a real cable pull with link pause (the console `link` relink covers the firmware
  path), `hololink-set-ip`, VLANs, frames above 16 MiB, RoCE into host memory.

### Resources and timing

Routed design `7f1ff2c` (the release bitstream; later commits change only the firmware, the
host software and the docs), Vivado 2025.2, kcu116 with the self-test logic: **54,705 LUT
(25.2 %)**, 75,891 FF, 95.5 BRAM36, 16 URAM, 583 DSP; rocelet 21,330 LUT, HSB IQ16 source
14,129 LUT / 577 DSP / 10.5 BRAM36, other HSB logic 2,024 LUT / 7.5 BRAM36. Timing met: CMAC
user clock (322 MHz) WNS +0.006 ns / WHS +0.010 ns, generator clock (200 MHz) +0.172 /
+0.011 ns, CMAC RX clock +1.376 ns, system clock +2.146 ns; the only CRITICAL WARNING is the
evaluation-license notice [Vivado 12-1790]. See [](resources.md).

### Development versions before the release

* First target: KCU116 + 2x QSFP28 FMC (OP120) port 0, 100G CMAC with RS-FEC, rocelet engine
  (submodule), 256 KB on-chip memory window, MicroBlaze console with the host parameter
  records, Holoscan Sensor Bridge QP mode, and a built-in self-test.
* Tested on hardware (KCU116 + OP120, QSFP28 AOC to the development host's RoCE v2 NIC): link with the static
  CMAC configuration (RS-FEC, no auto-negotiation), ARP/ICMP, RDMA WRITE / WRITE-imm / SEND /
  SEND-imm to the host at line rate, host WRITE / SEND / READ, go-back-N under injected loss,
  READ continuation after lost READ responses, decoded RNR timer, 802.3x PAUSE both ways,
  Holoscan Sensor Bridge frame format, 30-minute soak (see Testing with a host).
* Console: `t [full] [pma]` (self-test in the GT loopback with a cable connected),
  loopback-path check, CNP / 802.1Q test, `injset`, `lp`, `rnrt`, `rcont`; HSB QPs start at
  PSN 0 from UDP port 12288; `setup` and the tests forget the host peers.
* Self-test logic: the fault injectors classify 802.1Q-tagged frames.
* rocelet submodule `d2b2d83` (rate limiter, timing fixes); console `pace`. Routed: 37.7k LUT,
  WNS +0.016 ns at 322 MHz.
* rocelet submodule `91e08fb` (v0.2.0-dev): READ_DEPTH counts new READs only (ConnectX-6 READ
  re-issue), requester ACK timeouts held while the link is down and for `LINK_GRACE` after it
  returns; the engine's `link_up` is the CMAC's `stat_rx_aligned`. Console 0.2.0-dev: `setup`
  restores READ continuation and the other engine defaults (ACK timeout now 1 ms, was 200 us),
  `st` shows the link / hold state, `LINK_GRACE` and the engine's link drops, new `grace`
  command, the self-test waits for the hold to end after a relink. Notes for a ConnectX-6 Dx
  host. Routed: 37.8k LUT, WNS +0.031 ns at 322 MHz. Re-validated on hardware against the
  ConnectX-6 Dx: READ depth fix (max_rd_atomic 16 with READ-response loss), a 35.6 s cable pull
  survived at the default budget, GPU ring.
* rocelet submodule `a262db9` (v0.2.1-dev; reset values ACK_TIMEOUT 5 ms, LINK_GRACE 6 s). The engine's
  `link_up` is now `stat_rx_aligned & ~stat_rx_local_fault & ~stat_rx_remote_fault`. Console
  0.2.1-dev: defaults ACK timeout 5 ms (was 1 ms; a host-side port reconfiguration on a
  ConnectX-6 went silent 15-25 ms before the FPGA lost alignment and killed the QP at 1 ms x 8)
  and `grace` 6 s (was 3 s; the ConnectX-6 links up 5.1-5.4 s after an FPGA-side relink); `grace`
  refuses values above 16,777,215 with a message instead of clamping silently. Checked on
  hardware against the ConnectX-6 Dx (forced 5 s / 30 s drops at the defaults, 1 timeout each). Routed: 38.0k LUT (rocelet 21.4k), WNS +0.030 ns at 322 MHz.
* rocelet submodule `aa93c99` (v0.2.2; reset value LINK_GRACE 2 s instead of 6 s). Console 0.2.2-dev:
  `grace` default 2 s (the remote fault in `link_up` keeps the hold on until the link partner is
  up, so the grace starts at the partner's link-up; on the ConnectX-6 Dx grace 0 / 1 / 3 s all
  survived 5 s forced drops; `t pma` back to about 3 s); `to` refuses values above 1,048,575 us
  (20-bit register) with a message; `mac` turns the rate limit off again (as before console
  0.2.0); `lp` marks the generator average as a lower bound (`avg >=`) when a WR took longer
  than 203.4 us (the sum adds at most 65,535 clocks per WR). Checked on hardware against the
  ConnectX-6 Dx including a real cable pull (see the release entry). Routed:
  37.9k LUT (rocelet 21.3k), WNS +0.097 ns at 322 MHz.
