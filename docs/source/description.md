# Design description

Both families of targets are built around one module, `rocelet_sys`
(`Vivado/src/hdl/rocelet_sys.sv`): the rocelet engine, its memory windows, the system registers,
the firmware's work-request queue, the self-test logic and the Holoscan Sensor Bridge (HSB)
producer with its sources. It runs in one clock (the MAC user clock on the KCU116 and the
ZCU106, a free-running engine clock on the VCK190) and talks to the MAC only through a generic
MAC boundary (`mac_ctl`, `mac_stat`, `mac_ev`, `mac_pause`, AXI-Streams at the MAC width), so
the same module serves the 100G CMAC, the open-source omac MACs and the Versal MRMAC. This page describes
what is common; the system around it is on the family pages ([](hardware.md)):

* [](microblaze_hw.md): the MicroBlaze design (`kcu116`): MicroBlaze console, CMAC behind the
  adapter `mac_cmac_adapt`, address map, block diagram;
* [](zynqmp_hw.md): the Zynq UltraScale+ design (`zcu106`): the PS (Linux or bare metal), the
  always-on block with the clock guard, the PS DDR window, the netdev DMA channel, the omac MACs,
  block diagram, register and address maps; [](zynqmp_linux.md) for its Linux stack;
* [](versal_hw.md): the Versal design (`vck190_fmcp1`): the Zynq UltraScale+ system shell on the
  Cortex-A72, the MRMAC behind the adapter `mac_mrmac100g`, the engine on its own 300 MHz clock,
  the PS DDR window over the NoC; [](versal_linux.md) for its Linux image.

## The rocelet engine

The engine is the git submodule `submodules/rocelet` (MIT). The design instantiates its top
level, `rocelet_top`; its port list is documented in the rocelet docs,
[top-level interface](https://rocelet.ethernetfmc.com/en/latest/interface.html), and its register map in
[register map](https://rocelet.ethernetfmc.com/en/latest/registers.html). The engine's build parameters
come from `config/data.json` (`engine`):

| Parameter | kcu116 | zcu106 | vck190_fmcp1 | Meaning |
|-----------|--------|--------|--------------|---------|
| `NUM_QP` | 16 | 16 | 16 | queue pairs |
| `NUM_MR` | 16 | 16 | 16 | memory windows (R_Key low bits select the window) |
| `READ_DEPTH` | 16 | 16 | 16 | outstanding RDMA READs per QP (responder) |
| `MAX_WR` | 128 | 128 | 128 | outstanding work requests |
| `RTX_MODE` | RING | RING | RING | requester retransmission from an on-chip payload ring |
| `RING_BYTES` | 262144 | 262144 | 262144 | retransmit ring: 256 KB of UltraRAM |
| `HSB_EN` | 1 | 1 | 1 | Holoscan Sensor Bridge packet format (QP type UC-HSB) |
| `CLK_KHZ` / `LINK_GBPS` | 322266 / 100 | 156250 / 40 (10G option: 10) | 300000 / 100 | engine clock and link speed (rocelet v0.3; PAUSE quantum, capability registers) |

## Data paths

* **Host RDMA WRITE / SEND to the FPGA:** the engine writes WRITE payload through its AXI4
  master into the memory window (memory windows `MR1`, read/write, and `MR2`, read-only, both
  at VA 0); SEND payload leaves on the engine's SEND stream (checked by the self-test logic; a
  product connects its own sink there). Receive completions (SEND, WRITE with immediate) are
  queued for the firmware (`cq`).
* **Host RDMA READ:** the engine reads the memory window through its AXI4 master.
* **FPGA RDMA WRITE / SEND to the host:** work requests come from the firmware queue (`post`:
  the payload is read from the memory window) or from the self-test generator (`wg`: a
  pattern payload that the host helper verifies). Work completions are queued for the
  firmware.
* **Holoscan Sensor Bridge frames to the host:** the HSB frame producer issues the data and
  metadata work requests of each frame (IQ16, beam array or counter payload) once a host has configured
  the data plane through the HSB register protocol; see [](hsb.md).
* **PS DDR (Zynq UltraScale+ and Versal):** local addresses with bit 39 set reach a region of PS
  DDR given at run time, over two HP ports per direction on the Zynq UltraScale+
  ([](zynqmp_hw.md#memory-windows-uram-and-ps-ddr)) and one NoC port per direction on Versal
  ([](versal_hw.md#memory-windows-uram-and-ps-ddr-over-the-noc));
  the consoles add memory window `MR3` over it. The MicroBlaze design has the URAM window only
  ([](microblaze_hw.md#rocelet_sys-in-this-design)).

## Beam array generator

`rsys_beam_src` (instance `u_bms`, new in version 0.4.0) is the 8 x 8 phased-array generator of
the [beamforming demo](beam_demo.md): **SOURCE 2** of the HSB frame producer, next to the IQ16
test signal (0) and the counter pattern (1). It produces the complex baseband samples of 64
antenna elements receiving up to four sources (CW tone, LFM pulse, QPSK, pulsed tone) from
directions (*u*, *v*), with per-element complex gains, an element enable mask and element
noise, bit-exact with the integer model `sw/beam/beam_model.py`. Its specification is
[](beam_contract.md); its registers are listed in
[Beam array generator registers](hsb.md#beam-array-generator-registers).

* **Interface**: the same as the IQ16 source's: the generator runs in the 200 MHz `gen_clk`,
  delivers at most one 64-byte beat of 16 complex int16 samples per clock (102 Gb/s), and
  crosses into the MAC user clock through an asynchronous FIFO. Beat *b* carries time sample
  *b* / 4 and, in lane *L*, element 16 (*b* mod 4) + *L* (time-major, element-interleaved).
  Every beat carries the scene id and activation frame of the scene that generated it as
  side-band; the producer writes them into bytes 48-63 of the frame's metadata record.
* **Scene engine**: the host writes shadow registers (system registers `C_BM_*`, cfg 128-255);
  APPLY snapshots them in the MAC clock, and one shared complex-exponential unit computes the
  per-scene steering table G[*k*][*s*] (steering phase x element gain x enable, 256 entries)
  into the inactive bank of the per-lane LUTRAM tables in about 1.45 us. The bank becomes
  active at the next frame boundary, so a frame never mixes two scenes. Moving a source is two
  words (U, V): the steering phases are computed in the FPGA.
* **Sample pipeline** (28 clocks): the four source waveforms per time sample (phase
  accumulators, the IQ16 generator's E() unit, QPSK symbols from a hash), then per lane two
  8-deep systolic DSP48E2 cascades for the four complex products w_s G[*k*, *s*], plus the IQ16
  generator's element noise path reused at the element-sample index, a rounding and a
  saturation.
* **Resources**: the generator's size and the size and timing of each target's design are on
  [](resources.md).
* **Simulation**: `Vivado/src/hdl/tb/run_xsim_beam.sh` runs `tb_beam_src` against vectors
  from the model (`beam_vectors.py`, python3 + numpy): 114,688 beats bit-exact, presets 1, 2
  and 5, an APPLY during a run and while idle, the noise index across m[63:32] = 0 to 1, and
  back-to-back beats at 102.4 Gb/s. In the system testbench, `run_xsim.sh hsbbm` runs the
  producer with the beam generator.

## Self-test logic

The self-test logic (`"selftest": true` in `config/data.json`) is outside the engine and
makes the loopback benchmarks and the console's self-test possible:

* a **pattern region** of the memory window (local address bit 40): reads return
  pattern(address), writes are checked and discarded, so a line-rate stream of any length can
  be verified;
* a **WR generator** issuing WRITE / WRITE-imm / SEND / SEND-imm work requests of a fixed length
  at line rate, with a self-describing payload pattern;
* **data checkers** for memory writes and SEND payload, and an immediate-sequence check;
* **fault injectors** on the engine's TX and RX streams (drop or corrupt frames of selected
  classes, once / periodic / random; 802.1Q-tagged frames are classified too), usable with a
  host as well (`injset`);
* a **latency probe** (WR to completion, split by the MAC interface timestamps).

A product built from this design sets `"selftest": false`.

## Simulation

`Vivado/src/hdl/tb/tb_rocelet_sys.sv` simulates `rocelet_sys` with the engine from the
submodule through a model of a QSFP28 loopback (TX back to RX after 120 clocks, TX throttled to
about 100 Gb/s, or random back-pressure with `+rndready`). It configures the engine and the
system registers over AXI-Lite exactly as the console does and checks the counters:

```
Vivado/src/hdl/tb/run_xsim.sh [all|arp|wrq|write|send|inject|vinject|read|icrc|access|crx|hsb|hsbiq|hsbbm] [+rndready]
```

`crx` sends HSB register-protocol and BOOTP-reply frames (and frames the filter must reject)
through the loopback into the control-plane receive FIFO and checks the queue, the contents,
the counters and the overflow; `hsb` runs the frame producer with the counter pattern
(several frame / work-request / path-MTU sizes) and with the IQ16 source, decodes every
packet at the MAC TX interface (opcode, PSN, VA per page, R_Key, length, immediate,
metadata record) and compares the payload with the counter model or with a second IQ16
generator in the testbench, and checks the device DNA read-out. The firmware's HSB protocol
code has a host-side test with the hardware mocked: `Vitis/test/hsb/run.sh`.

The same tests run through a narrow MAC and with the Zynq UltraScale+ options: `MAC_WIDTH=64`
or `MAC_WIDTH=256` in the environment puts rocelet's width converters at `rocelet_sys`'s MAC
ports (as with omac_10g / omac_40g), and `ZU=1` adds the PS DDR window (two ports per direction
through `rsys_axi_ilv`; `DDRP=1` for one) and the netdev DMA channel with their tests (`ddr`,
`odma`), e.g. `MAC_WIDTH=256 ZU=1 Vivado/src/hdl/tb/run_xsim.sh`. `run_xsim_aon.sh` tests the
always-on block and its clock guard (`tb_aon`), `run_xsim_ilv.sh` the PS DDR interleave
(`tb_axi_ilv`, throughput with each port modelled at 128 bits / 250 MHz), `run_xsim_mrmac.sh`
the Versal MRMAC adapter against a model of the MRMAC client interface (`tb_mrmac100g`).

`Vivado/src/hdl/tb/run_xsim_prod.sh` runs the frame producer alone (`tb_hsb_prod`, counter
source) for its live frame period: the period written while the stream runs (ten changes at
random clocks, back to back, with and without back-pressure) must set exactly the interval
that begins at the next frame start, and frame size and page stride written during a run must
not reach it.

The engine's own regression (unit and top-level tests against Python models) is in the
rocelet repository (`submodules/rocelet/sim`).
