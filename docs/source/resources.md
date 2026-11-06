# Resources, timing and measurements

Vivado 2025.2, self-test logic built in. Devices: `kcu116` XCKU5P-FFVB676-2E (216,960 LUT,
433,920 FF, 480 BRAM36, 64 URAM, 1,824 DSP); `zcu106` XCZU7EV-FFVC1156-2-E (230,400 LUT,
460,800 FF, 312 BRAM36, 96 URAM, 1,728 DSP); `vck190_fmcp1` XCVC1902-2MSEVSVA2197 (899,840
LUT, 1,799,680 FF, 967 BRAM36, 463 URAM, 1,968 DSP). The rates measured with the ZCU106 are in
[their section](#measured-zcu106-40g-and-10g), those of the VCK190 in
[the last section](#measured-vck190_fmcp1-100g); the KCU116's on [](hardware_test.md). The
current figures of each board are also in the Board specifics of its family page
([](microblaze_hw.md#board-specifics), [](zynqmp_hw.md#board-specifics),
[](versal_hw.md#board-specifics)).

## vck190_fmcp1 (Versal)

Rocelet v0.3.0, the MRMAC adapter `mac_mrmac100g`, the engine at 300 MHz, the PS DDR window on
one 512-bit NoC port per direction; the build of 2026-11-06, the device image measured below.

| Target | Device | LUT | FF | BRAM36 | URAM | DSP | WNS / WHS (ns) |
|--------|--------|----:|---:|-------:|-----:|----:|---------------:|
| `vck190_fmcp1` (MRMAC 100G RS-FEC, A72, always-on block + guard, PS DDR window on 1 + 1 NoC ports, netdev DMA channel) | XCVC1902-2 | 88,574 (9.8 %) | 119,805 (6.7 %) | 103 (10.7 %) | 16 (3.5 %) | 1,115 (56.7 %) | +0.043 / +0.012 |

| Block | LUT | FF | BRAM36 | URAM | DSP |
|---|---:|---:|---:|---:|---:|
| `rocelet_sys_0` (engine, URAM window, self-test logic, HSB producer and sources, netdev channel) | 70,491 | 93,977 | 84 (67 + 34 x 0.5) | 16 | 1,115 |
| `mac0` (`mac_mrmac100g`: RX packer, RX and TX FIFOs, downsizer, clock crossings) | 5,694 | 5,273 | 16 (15 + 2 x 0.5) | 0 | 0 |
| the rest (SmartConnects, AXI DMA, AXI IIC, always-on block, clocking, resets) | 12,389 | 20,555 | 3 | 0 | 0 |

| Clock | WNS (ns) | WHS (ns) |
|-------|---------:|---------:|
| engine clock (`clk_eng`, 300 MHz) | +0.043 | +0.015 |
| MRMAC client clock (`clk_axis`, 390.625 MHz) | +0.051 | +0.012 |
| `clk_gen` (200 MHz: IQ16 and beam-array generators) | +0.431 | +0.021 |
| `clk_dma` (250 MHz: netdev DMA) | +0.785 | +0.021 |
| `clk_sys` (100 MHz: control plane) | +4.269 | +0.030 |

* The MRMAC itself, the GT quad, the NoC and the DDR controller are hard blocks and use no
  fabric; the 100G MAC costs the 5.7k LUT of its adapter.
* The engine and the rest of `rocelet_sys` are the same as on the other targets. The margin at
  300 MHz is small, as on the KCU116 at 322 MHz; the implementation uses the same directives
  (`place_design -directive ExtraTimingOpt`, `phys_opt_design`, `route_design -directive
  AggressiveExplore`, a post-route `phys_opt_design` when needed). No critical warnings.
* NoC quality of service: the PS DDR window's ports request 12,500 MB/s each (write / read),
  the netdev DMA port 1,600 MB/s each way; the NoC compiler reports the requests as met.
* The Cortex-A72 console (`rocelet_console.elf`) and the Linux daemon run from DDR, so there is
  no local-memory limit: the console is 242 KB of code and 1.1 MB of bss, most of it the 1 MB
  PS DDR window buffer (`mr=3`).

## Version 0.5.0: zcu106 and the refactored kcu116

Builds with rocelet v0.3.0 and opsero-ethernet-mac v0.1.0, PS DDR window over two HP ports per
direction.

| Target | Device | LUT | FF | BRAM36 | URAM | DSP | WNS / WHS (ns) |
|--------|--------|----:|---:|-------:|-----:|----:|---------------:|
| `zcu106` (omac_40g 40G on four GTH lanes, A53, always-on block + guard, PS DDR window on 2 + 2 HP ports, netdev DMA channel) | XCZU7EV-2 | 96,973 (42.1 %) | 126,656 (27.5 %) | 87 (27.9 %) | 16 (16.7 %) | 1,116 (64.6 %) | +0.304 / +0.007 |
| `zcu106`, 10G option (`mac` omac_10g on one GTH lane, otherwise the same) | XCZU7EV-2 | 84,198 (36.5 %) | 119,950 (26.0 %) | 87 (27.9 %) | 16 (16.7 %) | 1,116 (64.6 %) | +0.345 / +0.010 |
| `kcu116` (CMAC 100G behind the generic MAC boundary, MicroBlaze) | XCKU5P-2 | 69,178 (31.9 %) | 99,975 (23.0 %) | 98 (20.4 %) | 16 (25 %) | 1,119 (61.3 %) | +0.023 / +0.006 |

* No critical warnings in the zcu106 builds; the kcu116 build has only the CMAC's
  evaluation-license notice `[Vivado 12-1790]` (the CMAC license is free of charge).
* zcu106 clocks: MAC / engine 156.25 MHz (GTH TXUSRCLK2), pl_clk0 100 MHz, pl_clk1 250 MHz
  (HP ports, DMA), pl_clk2 200 MHz (generators). The engine is the same 512-bit core as on the
  KCU116; rocelet's width converters sit between it and the 256-bit (64-bit) MAC.
* zcu106 (40G): the MAC block (`mac0`: omac_40g + the four-channel transceiver wizard) is
  16,800 LUT / 8,752 FF / 0 BRAM, rocelet_sys 66,669 LUT; 4 GTHE4_CHANNEL. The two-port PS DDR
  window costs 3.8k LUT over a one-port layout (93,206 LUT, WNS +0.382): `rsys_axi_ilv` 2,045 LUT
  (1,276 as LUTRAM: the W / R FIFOs) + two more SmartConnects (about 1.0-1.1k LUT each).
* The 10G option builds from the same sources with `python3 config/update.py --mac
  zcu106=omac_10g` (data.json), constraints `zcu106_omac_10g.xdc`.
* kcu116: the 0.5.0 MAC-boundary refactor and rocelet v0.3.0 change neither its function nor its
  size materially (no PS DDR window logic). MicroBlaze console: 130,664 of the 130,992 bytes of
  local memory (328 B free).
* The ZCU106 A53 console and the Linux daemon run from PS DDR (no local-memory limit).

## Version 0.4.0 (beamforming demo)

Routed design `f75b487` (the frame producer samples its period at every frame start, so the
stream rate can change while it runs) (the version 0.4.0 hardware: the 0.3.0 design plus the
[beam array generator](description.md#beam-array-generator), SOURCE 2 of the HSB frame
producer), rocelet `aa93c99` (v0.2.2, unchanged).

| Group | LUT | BRAM36 | URAM | DSP |
|-------|----:|-------:|-----:|----:|
| beam array generator (`u_bms`: scene engine, per-lane steering tables, four waveforms, 16 lanes x two 8-deep DSP cascades, element noise, FIFOs) | **12.1k** | 2.5 | 0 | 535 |
| rest of the design (as in version 0.3.0, below) | 56.5k | 95.5 | 16 | 583 |
| **Total** | **68.6k (31.6 %)** | 98 (20.4 %) | 16 (25 %) | 1,118 (61.3 %) |

* The rest of the design is 1.8k LUT larger than in 0.3.0 (54.7k): the system register file
  has 256 configuration words instead of 128 (the generator's shadow registers,
  `rsys_pkg::NCFG`), and the producer has a third source input with the scene side-band for the
  metadata.
* The generator's DSPs are the complex products of the four sources (16 lanes x 2 cascades x
  8 DSP48E2 = 256), the element noise path reused from the IQ16 generator, and the shared
  waveform and scene-table units. The IQ16 generator (577 DSP) stays in the design, so 61 % of
  the device's DSPs are used.

| Clock | WNS (ns) | WHS (ns) |
|-------|---------:|---------:|
| CMAC user clock (`txoutclk_out[0]`, 322.265625 MHz) | +0.002 | +0.007 |
| generator clock (`clk_out2`, 200 MHz: IQ16 and beam array generators, device DNA) | +0.371 | +0.013 |
| MicroBlaze clock (`clk_out1`, 100 MHz) | +3.890 | +0.017 |

The CMAC user clock closes after post-route physical optimisation (route_design ends at
-0.011 ns on the self-test fault injector `g_inj` and reports `[Route 35-39]`; the post-route
`phys_opt_design` of the build recovers it). The worst paths are in the self-test logic (fault
injector, WR generator, raw capture), not in the frame producer: its period register has
+1.99 ns of setup slack. The beam generator's QPSK amplitude product is computed in the
generator clock's fabric, so the clock crossing from the CMAC clock stays a false path. The only
CRITICAL WARNINGs are the evaluation-license notice `[Vivado 12-1790]` and the route-stage
timing notice above.

MicroBlaze application (console 0.4.0 at `959e143`, with the beam register mapping,
`hsb src beam`, the beam generator line of `hsb st` and RATE_MBPS live while the data plane
runs): 1,560 bytes of the 130,992-byte local memory free.

## Version 0.3.0

Routed design `7f1ff2c` (the version 0.3.0 hardware with the Holoscan Sensor Bridge device mode; later commits change only the firmware, the host software and the docs), self-test logic built in. Source:
`Vivado/kcu116/reports/util_hier.rpt`, split by `Vivado/scripts/util_split.py`.

| Group | LUT | LUTRAM | FF | BRAM36 | URAM | DSP |
|-------|----:|-------:|---:|-------:|-----:|----:|
| **rocelet** (`rocelet_top`: engine, MAC glue, ARP/ICMP, AXI4 memory master, registers and counters; 256 KB retransmit ring) | **21,330** | 2,332 | 25,017 | 37 | 8 | 0 |
| memory window (256 KB URAM, AXI4 slave, firmware port) | 1,647 | 672 | 2,820 | 0 | 8 | 0 |
| firmware access (WR queue, payload reader, completion queues, raw frames / capture, system registers, CMAC control and counters, AXI-Lite decoder) | 6,365 | 992 | 9,090 | 7.5 | 0 | 0 |
| self-test logic (WR generator, data checkers, TX/RX fault injectors, TX skid buffer, latency probe) | 3,868 | 102 | 9,693 | 1 | 0 | 0 |
| HSB IQ16 source (IQ16 test-signal generator in the 200 MHz clock, asynchronous FIFO) | 14,129 | 592 | 19,959 | 10.5 | 0 | 577 |
| HSB other (frame producer, control-plane receive FIFO, time, device DNA) | 2,024 | 8 | 2,653 | 7.5 | 0 | 2 |
| CMAC wrapper (without the AXI-Lite statistics block) | 1,645 | 320 | 2,778 | 0 | 0 | 0 |
| system (MicroBlaze with 128 KB local memory, interconnect, UART, timer, I2C, GPIO, clocking) | 3,697 | 64 | 3,881 | 32 | 0 | 4 |
| **Total** | **54,705 (25.2 %)** | 5,082 | 75,891 (17.5 %) | 95.5 (19.9 %) | 16 (25 %) | 583 (32.0 %) |

* The RoCE function (the rocelet IP with its MAC glue and ARP/ICMP responder) is 21.3k LUT,
  within the ~24k LUT budget set for the engine's first version. For comparison, AMD's ERNIC IP
  (v4.3, 8 QP) alone synthesizes to about 42k LUT out of context.
* Dropping the CMAC's optional AXI-Lite statistics block saves about 5.5k LUT and 26k FF
  against the configuration that includes it.
* The Holoscan Sensor Bridge device side adds 16.2k LUT, 18 BRAM36 and 579 DSP: the IQ16
  test-signal generator alone is 14.1k LUT and 577 DSP (four tones x 16 lanes of complex
  multipliers, 16 chirp lanes, 32 hash units); the producer, the receive FIFO (16 x 2 KB, 8
  BRAM36), the time and DNA readers 2.0k LUT. Without the HSB build (design `abde102`) the
  total was 37,865 LUT, 77.5 BRAM36, 4 DSP. The system registers grew by 0.9k LUT (128
  configuration words, the receive FIFO window).
* A product without the self-test logic (`"selftest": false`) saves about 3.9k LUT and 9.7k
  FF; part of the system registers (the self-test counters) could be trimmed as well.

### Timing

All clocks meet timing (setup and hold) after routing:

| Clock | WNS (ns) | WHS (ns) |
|-------|---------:|---------:|
| CMAC user clock (`txoutclk_out[0]`, 322.265625 MHz, 3.103 ns) | +0.006 | +0.010 |
| generator clock (`clk_out2`, 200 MHz: IQ16 generator, device DNA) | +0.172 | +0.011 |
| CMAC RX recovered clock (`rxoutclk_out[0]`) | +1.376 | +0.035 |
| system clock (100 MHz) | +2.146 | +0.012 |

With the HSB build the margin at the CMAC user clock is +0.006 ns: the worst paths are the
existing self-test SEND checker (`u_schk` expected-pattern adders) and the engine's
retransmit address (`u_rtx`), not new logic; the IQ16 generator runs in its own 200 MHz clock
and only the producer, the receive FIFO and the time counter are in the CMAC clock (the
placement is denser with 54.7k LUT). The clock crossings between the two clocks use XPM CDC
macros; the IQ16 configuration and the DNA are quasi-static (false paths to their capture
registers in `kcu116.xdc`). The self-test fault
injectors decode the frame class in a register stage of their own, outside the decision
path. The implementation uses `place_design -directive ExtraTimingOpt`, `phys_opt_design`
and `route_design -directive AggressiveExplore` (`Vivado/scripts/xsa.tcl`). The only
CRITICAL WARNING is the evaluation-license notice `[Vivado 12-1790]` (the CMAC license is
free of charge; nothing in the design is time-limited).

### MicroBlaze application

`rocelet_console.elf` (0.3.0): 89.8 KB code, 1.6 KB data, 37.3 KB bss (including the stack,
the heap and the 4 KB HSB APB RAM): 128,680 of the 130,992 bytes of local memory (2.3 KB free).

## Measured: zcu106 (40G and 10G)

ZCU106 + OP120 on HPC0, QSFP28 port 0, 3 m passive QSFP28 DAC to an NVIDIA ConnectX-6 Dx
(firmware 22.43.2566, inbox mlx5 and rdma-core 50, Ubuntu 24.04) in a Lenovo P520, forced to
40000 (or 10000), auto-negotiation off, FEC off, MTU 4200. Version 0.5.0, the Linux image
(`rl` over SSH) unless the row says "bare metal"; one QP, 64 KB messages unless stated, payload
throughput as measured by the receiving side, PAUSE TX on (the default) unless stated.

### Link

| Item | Result |
|---|---|
| 40G link up after the MAC reset release | 4.8-5.7 s (including the partner's own link-up); all four lanes block-locked and marker-locked on the first attempt, the ConnectX-6 Dx's lane order = identity, skew 0-1 block, 0 BIP errors |
| 10G link up | 3.3-5.6 s; the ConnectX-6 Dx forced to 10G uses QSFP lane 0 |
| Self-test `rl t pma` (and `t pma` bare metal) | SELFTEST PASS 19/19 at 40G and with the 10G option, with the host link connected |
| Error counters after the 40G sessions | 85.9 M frames sent: 0 bad FCS, 0 bad code, 0 BIP errors, 0 failed alignments, 0 receive overflows, 0 transmit underflows, 0 link drops; host: 0 CRC and 0 symbol errors |

### RDMA at 40G

| Direction / operation | Memory | PMTU | Gb/s |
|---|---|---|---:|
| FPGA to host, WRITE with immediate | host memory | 4096 | 38.83 |
| Host to FPGA, WRITE | URAM window | 4096 | 38.74 |
| Host to FPGA, SEND (8 KB) | - | 4096 | 39.20 |
| Host READ of FPGA memory | URAM window | 4096 | 38.73 (bare metal 39.17) |
| Host READ of FPGA memory, bare metal | URAM window | 1024 / 512 | 37.03 / 34.43 (line rate at each PMTU) |
| Host to FPGA, WRITE, PAUSE TX off / on | PS DDR window (256 MB) | 4096 | 38.75 / 38.73, lossless, data checked; the engine's receive FIFO peaked at 66 of 512 beats, so no PAUSE frame was needed |
| Host READ of the PS DDR window | PS DDR window | 4096 / 1024 | 38.74 / 37.02 (bare metal: 38.70 / 37.00, and 34.47 at PMTU 512) |

With one HP port per direction (`ddr_ports` 1) the PS DDR window was the limit at 40G: host
WRITE 26.3 Gb/s with go-back-N losses, 32.0 Gb/s lossless with PAUSE TX (174,494 PAUSE frames,
every one honoured by the ConnectX-6 Dx), READ 31.6 Gb/s. Two ports per direction remove that
limit.

### PAUSE, network interface, Holoscan Sensor Bridge, web UI

| Test | Result |
|---|---|
| PAUSE RX (`pause rx 1`), the host sending 802.3x PAUSE frames (quanta 0xFFFF every ~2.1 ms) during an FPGA WRITE with immediate stream, bare metal | 38.78 Gb/s without, 23.89 Gb/s with the PAUSE frames (3,679 honoured), 0 lost |
| `rl0` (Linux network interface on the 40G port) | ping and flood ping 20000 x 1400 B: 0 % loss; 4000-byte pings with MTU 4200; at 10G a TCP stream into an untuned Python sink on the board ran at 2.2 Gb/s |
| HSB device mode (`rl hsb on`): enumeration, `LINK_GBPS` register | enumerated by NVIDIA's HSB 3.0.0 software, `LINK_GBPS` = 40, 100 counter frames of 1 MiB |
| HSB data plane into GPU memory, IQ16 / counter source, 1 MiB frames, `rocelet_hsb_app.py --mode check` | 39.00 / 38.96 Gb/s, every frame checked (89,556 / 89,552), 0 lost, 0 errors |
| Beamforming demo at the link's cap | stream at about 38.8 Gb/s at the 40 Gb/s step; the rate keys 40 → 20 → 10 → 20 → 40 followed, `+` at 40 refused, a page request for 64 Gb/s clamped to 40; 0 frames lost, verify 0 bad |
| Web UI | page and `/api/status` served (MAC omac_40g, link 40 Gb/s, HSB state, netdev mode) |

### RDMA at 10G (10G option)

| Direction / operation | Memory | Gb/s |
|---|---|---:|
| FPGA to host, WRITE with immediate | host memory | 9.80 |
| Host to FPGA, WRITE | URAM window | 9.69-9.71 |
| Host to FPGA, SEND (8 KB) | - | 9.80 |
| Host READ of FPGA memory | URAM window | 9.44-9.57 |
| Host to FPGA, WRITE | PS DDR window | 9.69-9.80 |
| Host READ of the PS DDR window | PS DDR window | 9.13 |
| HSB IQ16 frames into GPU memory, unpaced | GPU memory | 9.77 |

## Measured: vck190_fmcp1 (100G)

VCK190 + OP120 on FMCP1, QSFP28 port 0, 3 m passive QSFP28 DAC to an NVIDIA ConnectX-6 Dx in the
same test host, forced to 100000, auto-negotiation off, FEC `Auto` (active: RS-FEC), MTU 4200.
Version 0.6.0, the bare-metal Cortex-A72 console loaded over JTAG unless the section says
[Linux image](#linux-image); `rocelet_host` 0.2.0 on the host, host memory (no GPU) except for
the HSB and beamforming rows; one QP, 64 KB messages unless stated, payload throughput as
measured by the receiving side, PAUSE TX on (the default) unless stated.

### Link

| Item | Result |
|---|---|
| 100G link up after the MAC reset release | 2.0-6.7 s with RS-FEC, on the first attempt (including the partner's own link-up): PCS lanes 0-19 block-locked, RS-FEC lanes 0-3 locked and aligned; the ConnectX-6 Dx reports 100000 Mb/s, FEC RS(528,514) |
| Self-test `t pma` (bare metal) | SELFTEST PASS 19/19, with the host link connected; `t full pma` 23/23: WRITE 4 KB one QP 95.70 Gb/s, 64 KB four QPs 97.89 Gb/s payload (100.00 Gb/s on the line with the ACKs); 1024-byte WRITE from the engine's transmit to its receive side through the MRMAC, RS-FEC and the PMA loopback 433 ns |
| Ping | from the host: flood ping 200,000 x 1400 B, 0 lost (8-9 µs average round trip); 1472 B with don't-fragment |
| Line-rate soak | host WRITE for 60 s: 96.62 Gb/s, 723.8 GB, 11.0 M messages |
| Error counters on a steady link | over the soak: FPGA RS-FEC 0 corrected / 0 uncorrectable codewords, 0 bad FCS; host: 0 CRC and 0 symbol errors, 3 corrected bits (raw BER about 2E-13), 0 errors after FEC |
| FEC off at run time | `fec 0` + host `encoding off`: link up in about 2.5 s without FEC, host WRITE 97.94 Gb/s, host 0 CRC / 0 symbol errors; `fec 1` + host `Auto`: RS-FEC again in about 2.5 s |

### RDMA at 100G

| Direction / operation | Memory | PMTU | Gb/s |
|---|---|---|---:|
| FPGA to host, WRITE with immediate | host memory | 4096 / 1024 | 93.49 / 88.20 |
| Host to FPGA, WRITE | self-test pattern region `mr=0` (every write checked) | 4096 / 1024 | 97.48 / 90.39 |
| Host to FPGA, SEND (8 KB) | - | 4096 | 91.75 |
| Host READ of FPGA memory | URAM window | 4096 / 1024 | 96.33 / 80.97 |
| Host to FPGA, WRITE, PAUSE TX on / off | PS DDR window (1 MB buffer, `mr=3`) | 4096 | 79.37 lossless, every beat checked / 47.46 with go-back-N recoveries |
| Host READ of the PS DDR window | PS DDR window | 4096 | 79.20 |
| Host WRITE into and READ of the PS DDR window at once | PS DDR window | - | not characterised |

* Host WRITE and host READ at PMTU 4096 are close to the 100G line rate. At PMTU 1024 the
  rates stay below that PMTU's line rate (about 92 Gb/s of payload).
* The FPGA's WRITE with immediate into host memory is paced by the host's receive queue: the
  host counted a few `out_of_buffer` events (RNR NAK and retry), 0 data errors.
* With the bare-metal console's 1 MB buffer the PS DDR window carries about 79 Gb/s each way
  through one 512-bit NoC port per direction at the 300 MHz engine clock; PAUSE TX keeps a host
  WRITE into it lossless ([](versal_hw.md#bandwidth-of-the-ps-ddr-window)). With the Linux
  image's 256 MB region the same ports carried 97.85 / 88.94 Gb/s ([below](#linux-image)).

### PAUSE

| Test | Result |
|---|---|
| PAUSE TX (the default): the FPGA's PAUSE frames during a host WRITE into the PS DDR window | the ConnectX-6 Dx counted every one (92,400) and honoured them: 79.37 Gb/s lossless with, 47.46 Gb/s with losses (recovered) without |
| PAUSE RX (`pause rx 1`), GT PMA loopback, WRITE 64 KB x 200 at PMTU 1024 | 287 PAUSE frames sent, received and honoured, 0 lost (with PAUSE RX off: go-back-N recoveries, test passed) |
| PAUSE RX, PAUSE frames from the host (Linux image, `rl pause rx 1`, HSB stream into GPU memory requested at 95 Gb/s, above the host's NIC-to-GPU limit) | the ConnectX-6 Dx sent 55,650 PAUSE frames and the FPGA honoured them: 77.6 Gb/s, 0 host discards, every frame checked |

### Linux image

The Linux image of version 0.6.0 from the SD card: `roceletd`, `rl` over SSH, the QP records
over SSH; same cable and host. The HSB and beamforming rows use the host's RTX PRO 4000
Blackwell GPU and NVIDIA's HSB 3.0.0 software.

| Test | Result |
|---|---|
| Boot | power on to the login prompt 42-46 s, `rl0` answering the host's ping at about 45 s; warm reboot about 45 s; 100G link up 4.0-7.0 s after `roceletd` starts |
| Self-test | `rl t pma` SELFTEST PASS 19/19 (exit status 0), `rl t full pma` 23/23 (WRITE 4 KB one QP 95.70 Gb/s, 64 KB four QPs 97.89 Gb/s) |
| RDMA, PMTU 4096 | host WRITE 97.93, FPGA WRITE with immediate 92.30, host READ of the URAM window 96.54, host SEND (8 KB) 85.85 Gb/s |
| RDMA, PMTU 1024 | host WRITE 90.39, FPGA WRITE with immediate 87.46, host READ 80.91, host SEND (8 KB) 91.66 Gb/s |
| PS DDR window (the 256 MB region at `0x6000_0000`, `mr=3`), PMTU 4096 | host WRITE 97.85 Gb/s, every beat checked (`rl ddr check`); host READ 88.94 Gb/s (`rl ddr fill`) |
| Line-rate soak | host WRITE for 60 s: 96.62 Gb/s, 723.8 GB, 11.0 M messages; afterwards 0 bad FCS, RS-FEC 0 corrected / 0 uncorrectable codewords, 0 link drops; host: 0 CRC and 0 symbol errors |
| `rl0` | ping both ways; flood ping 20000 x 1400 B, 0 lost; 4000-byte pings at MTU 4200 (rl0 comes up with MTU 1500); SSH and the web UI over rl0; the netdev DMA works with buffers above 4 GB |
| TCP over rl0 (iperf3 on the A72) | MTU 4200: host to board 2.41 Gb/s (one stream) / 2.67 (four streams), board to host 2.69 / 3.50; MTU 1500: 1.68 / 1.67 Gb/s |
| HSB device mode (`rl hsb on`): enumeration, registers | enumerated by NVIDIA's HSB 3.0.0 software, `LINK_GBPS` = 100, `TARGET` = "VCK1", 100 counter frames of 1 MiB |
| HSB data plane into GPU memory, 1 MiB frames, `rocelet_hsb_app.py --mode check` | counter source at 10, 50 and 80 Gb/s requested (72.2 Gb/s at 80); IQ16 at 80 requested: 76.1 Gb/s, 191,328 frames bit-exact, 0 lost; at 90 / 95 the host overruns, as on the KCU116 |
| Same at 95 Gb/s requested with `rl pause rx 1` | 77.6 Gb/s lossless, 0 host discards (55,650 PAUSE frames from the host honoured) |
| Beamforming demo | `--rate 64`: stream at about 63.9 Gb/s, the board named VCK190 from its `TARGET` register, all 855 frames shown, 85 verified bit-exact, 0 lost |
| Web UI | page and `/api/status` served (target VCK190, MAC MRMAC, link 100 Gb/s), commands through `/api/cmd`; page title `rocelet-v190` |

* The Linux figures of the URAM window and of host memory match the bare-metal console's. SEND of
  8 KB messages ran faster at PMTU 1024 than at PMTU 4096.
* The PS DDR window measured faster here (the 256 MB region at `0x6000_0000`) than with the
  bare-metal console's 1 MB buffer (97.85 / 88.94 against 79.37 / 79.20 Gb/s) over the same NoC
  ports; the difference is not characterised further.
