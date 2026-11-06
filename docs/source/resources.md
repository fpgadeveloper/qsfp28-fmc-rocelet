# Resources, timing and measurements

Vivado 2025.2, self-test logic built in. Devices: `kcu116` XCKU5P-FFVB676-2E (216,960 LUT,
433,920 FF, 480 BRAM36, 64 URAM, 1,824 DSP); `zcu106` XCZU7EV-FFVC1156-2-E (230,400 LUT,
460,800 FF, 312 BRAM36, 96 URAM, 1,728 DSP). The rates measured with the ZCU106 are in
[the last section](#measured-zcu106-40g-and-10g); the KCU116's on [](hardware_test.md). The
current figures of each board are also in the Board specifics of its family page
([](microblaze_hw.md#board-specifics), [](zynqmp_hw.md#board-specifics)).

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
