# Resources and timing

Target `kcu116` (XCKU5P-FFVB676-2E: 216,960 LUT, 433,920 FF, 480 BRAM36, 64 URAM, 1,824 DSP),
Vivado 2025.2, self-test logic built in.

## Version 0.4.0 (beamforming demo)

Routed design `f75b487` (the frame producer samples its period at every frame start, so the
stream rate can change while it runs; earlier builds `88981d6` / `42cf7df`: 68.4k LUT, WNS
+0.040 / +0.330 ns) (the version 0.4.0 hardware: the 0.3.0 design plus the
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
injector, WR generator, raw capture), not in the frame producer: its new period register has
+1.99 ns of setup slack.

The first build failed at -2.46 ns on a clock-crossing path (a DSP had absorbed the CMAC-clock
snapshot registers of the QPSK amplitude, which took them out of the false path to the
generator clock); the product is now computed in the generator clock's fabric. The only
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
registers in `kcu116.xdc`). Before the HSB build (design `abde102`, +0.097 ns) the worst path was inside the engine (the
requester's WR length into the retransmit descriptor queue's metadata RAM, `u_req` to
`u_desc`); with rocelet `a262db9` (+0.030 ns) it was the self-test TX fault injector (`u_inj`
period counter to its output-register enable), with rocelet `91e08fb` (+0.031 ns) it was the write-data fan-out of the design's system registers (`u_regs`) and the
engine reset replicas, with rocelet `d2b2d83` (+0.016 ns) inside the engine (the retransmit
descriptor queue's RAM enable, then the RX ICRC check). rocelet v0.2's link-loss hold and
READ-depth fix add about 90 LUT and 80 FF; v0.2.1 changes only two register reset values and
the design's `link_up` gains the CMAC fault terms (the +173 LUT against the `91e08fb` build, all
in `rocelet_top`, are synthesis / implementation variation, not new logic); v0.2.2 changes one
register reset value (`LINK_GRACE` 2 s; -87 LUT in `rocelet_top` against the `a262db9` build,
again implementation variation).
The self-test fault
injectors decode the frame class in a register stage of their own, outside the decision
path. The implementation uses `place_design -directive ExtraTimingOpt`, `phys_opt_design`
and `route_design -directive AggressiveExplore` (`Vivado/scripts/xsa.tcl`). The only
CRITICAL WARNING is the evaluation-license notice `[Vivado 12-1790]` (the CMAC license is
free of charge; nothing in the design is time-limited).

### MicroBlaze application

`rocelet_console.elf` (0.3.0): 89.8 KB code, 1.6 KB data, 37.3 KB bss (including the stack,
the heap and the 4 KB HSB APB RAM): 128,680 of the 130,992 bytes of local memory (2.3 KB free).
0.3.0-dev (HSB device mode without the producer watchdog): 86.9 KB code, 125.7 KB in all. Before the
HSB device mode: 76.0 KB code, 32.5 KB bss.
