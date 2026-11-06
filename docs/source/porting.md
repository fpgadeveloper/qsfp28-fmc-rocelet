# Porting to other boards

The ZCU106 target is built so that the Zynq UltraScale+ **RFSoC** boards (ZCU111, ZCU208,
ZCU216; also other Zynq UltraScale+ MPSoC boards with an FMC) can reuse almost all of it: the
processing system is the same, and the MAC sits behind one generic MAC boundary. The VCK190
target does the same for **Versal** boards with an MRMAC next to the FMC's transceivers
([below](#other-versal-boards)). This page lists what is board specific and what carries over,
and the steps to add a target. It is a checklist for a port, not a supported target: no RFSoC
target and no other Versal board is built or tested in this release.

## The template: Board specifics

The family pages describe the design without a particular board and collect everything a board
decides in one **Board specifics** subsection per board:
[ZCU106](zynqmp_hw.md#zcu106-zcu106) on the Zynq UltraScale+ page (FMC slot, VADJ, GT channels
and lane order, reference-clock pin, FMC I/O pins, PS preset and DDR map, always-on `TARGET` /
`CAPS`, firmware block, resources and timing), the Linux page's
[per-board defaults](zynqmp_linux.md#per-board-defaults) (BSP, host name, UART, MAC addresses,
reserved memory, boot switch), [VCK190](versal_hw.md#vck190-vck190_fmcp1) on the Versal page
with the Versal Linux page's [per-board defaults](versal_linux.md#per-board-defaults), and
[KCU116](microblaze_hw.md#kcu116-kcu116) on the MicroBlaze page. A port fills in the same rows for the new board: each row names the file that holds the
value, so the table is also the list of files to touch. Add the new board's subsection to the
family page (and a row to the per-board defaults) together with the target.

## What is generic and what is board specific

| Part | Generic (reuse as is) | Board specific |
|---|---|---|
| rocelet engine | the engine, its parameters, the width converters | `CLK_KHZ`, `LINK_GBPS`, `MAC_WIDTH` from the MAC (data.json) |
| System logic (`rocelet_sys`) | memory windows (URAM, PS DDR with the two-port interleave), self-test logic, HSB producer and sources, netdev DMA channel, system registers | `DDR_PORTS` (bandwidth of the PS DDR window, below) |
| Always-on block + clock guard (`rsys_aon`) | registers, guard, interrupts | nothing by hand: `bd_zynqmp.tcl` computes the `CAPS` constant (link rate, MAC width and type, port, options) from the data.json attributes and the `TARGET` id from the target label |
| MAC block (`Vivado/src/hdl/mac/`) | `mac_cmac_adapt` (100G CMAC), `mac_omac40g` / `mac_omac10g` (omac on GTH), `mac_mrmac100g` (Versal MRMAC) | which one, and its transceiver placement |
| Block design (`Vivado/src/bd/bd_zynqmp.tcl`; Versal: `bd_versal.tcl`) | the PL side: interconnect, address map, interrupts, HP-port use | the PS configuration of the board (DDR, MIO, the GEM of the board's Ethernet port, UART: the board preset), the GT reference clock ports |
| Build script (`Vivado/scripts/build.tcl`) | the flow, the MAC selection and the GT placement from data.json | nothing: the GT channels and reference clock are data.json attributes ([below](#gt-placement-in-datajson)) |
| Constraints (`Vivado/src/constraints/<target>.xdc`, `<target>_impl.xdc`) | the clock-crossing constraints of `rocelet_sys` and `rsys_aon` | GT reference clock pins, FMC I/O pins (I2C of the Si5328 and the QSFP28 module, module control lines), the MAC's clock constraints |
| Firmware (`Vitis/common/src`) | the console, the self-test, the HSB device mode, the MAC backends (`mac.c`: CMAC and omac) | a branch for the board in `hw.h` (target name, MAC, MAC clock, FEC, PAUSE default, base addresses; [below](#firmware-hwh)), the Si5328 frequency (`si5328.c` has 156.25 MHz and 322.265625 MHz plans) |
| Linux (`sw/linux`, `Yocto/meta-rocelet`) | `roceletd`, `rl`, `rl_net.ko`, the web UI, the recipes | `Yocto/bsp/<target>/`: device tree (Ethernet PHY, MAC addresses, reserved memory, interrupt numbers), kernel configuration |

## GT placement in data.json

The transceivers of the QSFP28 port are three attributes of the target's data.json entry; the
build script reads them (through the target list that `config/update.py` writes into it), checks
them and configures the MAC's transceiver from them. No Tcl or RTL changes for a new placement.

| Attribute | MAC | Meaning | ZCU106 / KCU116 |
|---|---|---|---|
| `gt_channels` | all | the transceiver channel sites (`X<x>Y<y>`, as the transceiver wizard and the CMAC name them) of QSFP lanes 0, 1, 2, 3, in that order. omac_10g uses lane 0 (the first entry); omac_40g and the CMAC use all four, which must be the four channels of one quad | `["X0Y14", "X0Y13", "X0Y15", "X0Y12"]` / `["X0Y12", "X0Y13", "X0Y14", "X0Y15"]` |
| `gt_refclk` | omac | the reference clock of the lane 0 channel as the transceiver wizard names it: `clk0` / `clk1` = `MGTREFCLK0` / `1` of its quad, `clk0+1`, `clk0-1`, `clk1+1`, `clk1-1` = of the quad above / below; default `clk0` | `clk0` (GBTCLK0 on `MGTREFCLK0` of quad 226) / – |
| `cmac_core` | cmac | the CMAC hard block site | – / `CMACE4_X0Y0` |

A Versal target with the MRMAC has its own three attributes instead of `gt_channels`:

| Attribute | Meaning | VCK190 |
|---|---|---|
| `gt_quad` | the GTY quad of the FMC's DP0-3 (QSFP lane *n* = channel *n* of the quad; the quad is placed by its pins in the XDC) | `GTY_QUAD_X1Y1` |
| `mrmac_core` | the MRMAC site next to that quad (`MRMAC_LOCATION_C0`) | `MRMAC_X0Y0` |
| `gt_refclk_hz` | the GT reference clock frequency (the Si5328 plan of the firmware must match) | 322265625 |

What the build makes of them:

* **omac_40g**: `omac_gen_gth_x4` (opsero-ethernet-mac `gen_gt.tcl`) enables the four channels,
  lane 0's channel is the master (its TX user clock is the MAC clock) and gives the reference
  clock; the lane map `CH_OF_LANE` of `mac_omac40g` (QSFP lane l → the wizard's channel index,
  which counts the quad's channels in ascending site order) is derived from the same list and set
  on the `mac0` cell by `bd_zynqmp.tcl`, so omac_40g PCS lane l goes out on QSFP lane l.
* **omac_10g**: `omac_gen_gth` on lane 0's channel.
* **cmac**: `CMAC_CORE_SELECT` = `cmac_core`, `GT_GROUP_SELECT` = the quad of `gt_channels`
  (lowest~highest site). The CMAC numbers its lanes in ascending site order (`qsfp0_gt[i]` =
  the quad's channel i), so the XDC's lane pins follow that order.

The reference clock **pins** stay in the target's XDC (`PACKAGE_PIN` of the reference clock
port), as do the lane polarities: a board with a P/N swap sets the polarity input of that
channel in `mac_omac40g` / `mac_omac10g`. The clock constraints of `<target>_impl.xdc` (with
omac_40g five clocks, the TX user clock and one RX user clock per channel, bounded pair by pair:
20 ordered pairs) name the wizard's channel indices (0-3 in ascending site order), which are the
same for every quad.

## Firmware: hw.h

`Vitis/common/src/hw.h` selects the target with the `BOARD_<NAME>` macro of the generated
`board.h` (`Vitis/py/build-vitis.py` writes it from the data.json board name). It has two
branches: `#if defined(BOARD_ZCU106) || defined(BOARD_VCK190)`, the PS targets (always-on
block, PS DDR window), with a ZCU106 part (Cortex-A53, omac) and a VCK190 part (Cortex-A72,
MRMAC, VADJ, eFUSE DNA); and `#else`, the KCU116 (MicroBlaze, CMAC, QSFP0 GPIO). Every board
that is neither therefore builds as a KCU116 unless `hw.h` learns about it. A new board adds
itself to the PS condition with a part of its own: for another omac board on the Zynq
UltraScale+, a copy of the ZCU106 part with its own `TARGET_NAME` (the register map, the MAC
detection from `CAPS` and the PS DDR window carry over); for another Versal board, a copy of
the VCK190 part; for a CMAC target the values of step 4 below. The platform layer
(`plat.c`) and the VADJ code (`vadj.c`) select the VCK190's A72 specifics with the same
macro.

## Which MAC

| Board | Device transceivers | MAC | Ports of the 2x QSFP28 FMC |
|---|---|---|---|
| ZCU106, ZCU102 (MPSoC) | GTH, up to 16.3 Gb/s per lane | omac_40g (40GBASE-R4) or omac_10g; no 100G | port 0 (ZCU106); the second port's lanes are wired but unused in this design |
| ZCU111 (ZU28DR) | GTY, 28 Gb/s | the 100G **CMAC** hard block (free license), 512 bits at 322.27 MHz, as on the KCU116; omac_40g works too (GTY wrapper needed) | ports 0 and 1 each reach a CMAC (CMACE4_X0Y0 on GT quad X0Y8-11, CMACE4_X0Y1 on X0Y12-15) |
| ZCU208 (ZU48DR), ZCU216 (ZU49DR) | GTY, 28 Gb/s | **CMAC** on port 0 (CMACE4_X0Y1, GT quad X0Y12-15) | port 0 only at 100G: port 1's quad cannot reach a CMAC |

The CMAC placements are the ones the Opsero 2x QSFP28 FMC reference design
([2x-qsfp28-fmc](https://github.com/fpgadeveloper/2x-qsfp28-fmc)) uses on these boards; take its
`bd_zynqmp.tcl` CMAC configuration (CAUI-4, RS-FEC, AXI-Stream user interface, 322.265625 MHz
reference clock) and its constraints as the starting point. Look the board's FMC pinout up in
the board's documentation or the [FPGA board catalog](https://boards.fpgadeveloper.com).

## Steps for a CMAC target (ZCU111 / ZCU208 / ZCU216)

1. **Manifest.** Add the target to `config/data.json` (copy the `zcu106` entry): `label`,
   `board`, `connector` (`FMCP` on the RFSoC boards), `mac` `cmac`, `link_gbps` 100,
   `mac_width` 512, `clk_khz` 322266, `fec` `rs`, `ddr_ports`, `yocto` true, `gt_channels`
   (the CMAC's quad in QSFP lane order) and `cmac_core`. Run
   `python3 config/update.py` to regenerate the README tables, the build script's target list
   and `.gitignore` (never edit those by hand).
2. **Block design.** In `bd_zynqmp.tcl` add the board's PS preset and, for `mac` = `cmac`, the
   CMAC IP with `mac_cmac_adapt` as the `mac0` block (as in the KCU116's `bd_microblaze.tcl`): the
   CMAC's `gt_txusrclk2` becomes the MAC / `rocelet_sys` clock, its AXI-Streams connect to
   `rocelet_sys` directly (512 bits), and `mac_cmac_adapt` maps the CMAC's static control and
   status onto `mac_ctl` / `mac_stat` / `mac_ev` / `mac_pause`. The always-on block's `CAPS`
   (MAC type 1 = CMAC, link rate 100) and `TARGET_ID` follow from data.json and the label
   without changes.
3. **Constraints.** `<target>.xdc` with the GT reference clock and the FMC pins of the board,
   `<target>_impl.xdc` with the `rocelet_sys` / `rsys_aon` crossings of `zcu106_impl.xdc` (the
   CMAC's RX clock is internal to the CMAC: no omac clock constraints).
4. **Firmware.** An `#elif defined(BOARD_<NAME>)` branch in `Vitis/common/src/hw.h`
   ([](#firmware-hwh)) with the ZCU106 branch's always-on block and PS DDR window definitions
   and `MAC_CMAC`, `F_CLK_HZ` 322265625, `HAS_FEC` 1, `PAUSE_TX_DEFAULT`, `PAUSE_RX_DEFAULT`; the Si5328 at
   322.265625 MHz. The CMAC backend of `mac.c` reads the KCU116's QSFP0 GPIO (clock running,
   alignment, CMAC reset); on the Zynq UltraScale+ the same signals are in the always-on block
   (`STATUS`, `CTRL`), so the backend needs an always-on variant, as the omac backend has.
   `Vitis/py/build-vitis.py` generates `board.h` from data.json.
5. **PS DDR bandwidth.** One 128-bit HP port at 250 MHz carries 32 Gb/s; the ZCU106's two ports
   per direction carry 64 Gb/s, enough for 40G but not for 100G. For RDMA into PS DDR at 100G
   use four ports per direction, a faster HP clock, or keep line-rate traffic in the URAM
   window (FPGA-to-host streams never touch PS DDR).
6. **Linux.** Copy `Yocto/bsp/zcu106` to `Yocto/bsp/<target>` and adjust
   `meta-user/recipes-bsp/device-tree/files/system-user.dtsi`: the Ethernet PHY node and the
   MAC address of the board's own Ethernet port, the `rocelet-net` MAC address, the
   `reserved-memory` base if the board's DDR map differs, the interrupt numbers if the
   `pl_ps_irq0` order changes, and the S2MM channel label (`dma_channel_<DMA base + 0x30>`) if
   the DMA moves. `rocelet-tools.bb` takes `BOARD` and `LINE_RATE` from data.json (the entry
   whose label is the MACHINE suffix).
7. **RF data converters.** The RFSoC's RF clocking (LMK / LMX chips) is a second clock owner:
   program it from user space (xrfclk, PYNQ) before the RF-ADC source starts; the FMC's Si5328
   stays `roceletd`'s.
8. **Streaming source.** Feed the RF-ADC samples into input 3 of `rsys_src_mux` (the HSB
   producer's source multiplexer) through an asynchronous FIFO from the RF data converter's
   fabric clock; a free-running ADC must drop whole frames on overflow rather than stall
   ([](zynqmp_hw.md#streaming-source-boundary-hsb-producer)).
9. **Validate.** Build (`./build.sh all --target <label>`), run `rl t pma` (self-test in the GT
   loopback), then link to the host NIC at 100G with RS-FEC and repeat the transfers of
   [](hardware_test.md).

## Steps for an omac target (another GTH board)

For example the ZCU102 (XCZU9EG, GTH): as above with `mac` `omac_40g` (or `omac_10g`, listed in
`mac_options`) and the Zynq UltraScale+ block design unchanged. In the data.json entry set
`gt_channels` to the board's four GTH channels of the FMC's DP0-3 in QSFP lane order (lane 0 =
the master) and `gt_refclk` to the `MGTREFCLK` that carries the FMC's GBTCLK0 (`clk0` when it is
`MGTREFCLK0` of the same quad); the transceiver wizard and the `mac_omac40g` lane map follow
from them ([](#gt-placement-in-datajson)). Write `<target>.xdc` (reference clock and FMC pins,
the lane pins in the comments for reference: the wizard places the channels) and
`<target>_impl.xdc` (the clock constraints of `zcu106_impl.xdc`: five clocks, 20 ordered
pairs; the channel indices 0-3 are the same in every quad), add the board's branch to `hw.h`
([](#firmware-hwh)), and set the polarity inputs of `mac_omac40g` if the board swaps a lane's
P/N ([omac GTH wrapper documentation](https://omac.ethernetfmc.com/en/latest/gt_usp_gth.html)).
On a GTY device (RFSoC) omac needs a GTY wrapper, which is planned in the omac repository.

## Other Versal boards

The VCK190 target's block design (`bd_versal.tcl`) is written for any Versal board whose FMC
carries the 2x QSFP28 FMC on four GTY channels of one quad next to an MRMAC. AMD's VMK180 has
the VCK190's FMC and VADJ arrangement; the FPGA board catalog also lists the OP120 as
mating with the VPK120, VHK158 and VEK280. Check the MRMAC next to the FMC's quad in the
device's documentation before starting: not every Versal device has MRMACs, and their sites
differ. Steps:

1. **Manifest.** Copy the `vck190_fmcp1` entry of `config/data.json`: `label`, `board`,
   `connector`, `gt_quad`, `mrmac_core`, `gt_refclk_hz` ([](#gt-placement-in-datajson)),
   `license` true if the device needs Vivado Enterprise, `ip_license` true (the MRMAC key); then
   `python3 config/update.py`.
2. **Block design.** The CIPS of `bd_versal.tcl` is configured for the VCK190 (board preset,
   MIO, the GEM of the board's RJ45, SD, I2C, the DDR4 controller on the NoC): give the new
   board its own CIPS and NoC configuration. The PL side (always-on block, rocelet_sys, the
   adapter, the NoC ports of the PS DDR window and the DMA, the address map) carries over.
3. **Constraints.** `<target>.xdc` with the GT reference clock pin, the lane pins (they place
   the quad) and the FMC pins at the board's VADJ I/O standard; `<target>_impl.xdc` from
   `vck190_fmcp1_impl.xdc` (clock names are those of the block design, no board values).
4. **VADJ.** If the board, like the VCK190, leaves the FMC's VADJ rail off, switch it on in
   U-Boot (a bootcmd fragment in the BSP) and in `vadj.c` for the bare-metal console and
   `roceletd`; the regulator and its I2C path are board specific.
5. **Firmware.** A part in `hw.h` ([](#firmware-hwh)) and the board's cases in `plat.c` /
   `vadj.c`.
6. **Linux.** Copy `Yocto/bsp/vck190_fmcp1` and adjust the device tree: the Ethernet PHYs and
   MAC addresses of the board, the reserved-memory region (inside the DDR range that the
   engine's 40-bit DDR masters reach), the I2C bus of the VADJ regulator.
7. **Validate.** Build, run `rl t pma`, then link to the host NIC at 100G with RS-FEC
   ([](hardware_test.md)).

The second QSFP28 port of the OP120 reaches its own MRMAC on the VCK190 (FMCP1 DP4-7 = quad
X1Y2, next to MRMAC_X0Y2): the design keeps those lanes free and the port's module lines held,
so a second 100G port is an extension of the same block design.
