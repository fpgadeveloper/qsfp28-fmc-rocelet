# Versal design: Linux

The Linux flow of the Versal targets (data.json `yocto` = true; today `vck190_fmcp1`, 100G with
the MRMAC): an AMD EDF (Yocto 2025.2) SD-card image in which a daemon owns the hardware and
Linux owns the port's IP address, running on the Cortex-A72. The software is the
[Zynq UltraScale+ design's Linux stack](zynqmp_linux.md) (`roceletd`, `rl`, `rl_net.ko`, the web
UI, the same settings and the same QP-record exchange); this page lists what is specific to
Versal and to the VCK190. The register map, the clock guard and the DMA frame convention it
relies on are in [](versal_hw.md).

## Per-board defaults

| Item | `vck190_fmcp1` |
|---|---|
| Board BSP | `Yocto/bsp/vck190_fmcp1/` (device tree fixups `meta-user/recipes-bsp/device-tree/files/system-user.dtsi`, U-Boot fragment `meta-user/recipes-bsp/u-boot/files/vck190-vadj-bootcmd.cfg`, `conf/local.conf.append`); MACHINE `rocelet-vck190_fmcp1` (generated from the XSA) |
| Host name | `rocelet-v190` |
| Console UART | PS UART0 on the VCK190's FT4232H (its second port; `ttyAMA0` on the board), 115200 8N1 |
| Board Ethernet (SSH, web UI) | GEM0 on the RJ45 next to the USB connectors (TI DP83867 PHY at MDIO address 1, RGMII delays in the device tree), DHCP, fixed MAC **00:0a:35:06:21:90**; GEM1 (PHY address 2) **00:0a:35:06:21:91**. Do not use the third RJ45: it belongs to the system controller |
| `rl0` (QSFP28 port 0) | **192.168.20.2/24** (host 192.168.20.1/24), MAC **00:0a:35:06:21:92** (the GEM0 address + 2) |
| PS DDR window | `reserved-memory` **256 MB at `0x6000_0000`** (`no-map`, in the DDR4's low 2 GB, clear of every boot-loader load address), UIO `rocelet-ddr` |
| MRMAC registers | UIO `rocelet-mrmac` (64 KB at `0x8013_0000`): the MRMAC belongs to `roceletd`, so the stock AMD Ethernet driver (axienet) does not bind it |
| FMC VADJ | 1.5 V, switched on by U-Boot before every boot and again by `roceletd` at start-up ([](versal_hw.md#vck190-vck190_fmcp1)) |
| Device DNA (HSB serial number) | the PMC's eFUSE cache: through the `xilinx-secure-config` nvmem device, or, where that read is not supported (as on the 2025.2 image), read-only through `/dev/mem` (`0xF125_0020`, the words the bare-metal console reads) |
| SD boot | boot-mode switch SW1 = 1000 (1 ON, 2-4 OFF); the card goes into the Versal's boot microSD slot (the board's other microSD slot belongs to the system controller) |

The rl0 address is common to every target; the MAC addresses, the PHYs and the reserved-memory
base are in the board's device tree. Change the MAC addresses for boards on your own network.

## What runs where

As on the [Zynq UltraScale+ design](zynqmp_linux.md#what-runs-where), with the MRMAC in the PL
and, in `roceletd`, two more duties at start-up: switching the FMC's VADJ rail on (over the PS
I2C, through i2c-dev) and configuring the MRMAC through its registers (UIO `rocelet-mrmac`).
`rl st` shows the MRMAC's receive state (PCS lane lock, RS-FEC lane lock and alignment) and the
RS-FEC codeword counters.

## Build and boot

```
./build.sh all --target vck190_fmcp1       # Linux build host: XSA, bare-metal console, Linux image, zips
./build.sh yocto --target vck190_fmcp1     # the Linux image only (builds the XSA first if needed)
./build.sh package --target vck190_fmcp1   # bootimages/qsfp28-fmc-rocelet_vck190_fmcp1_yocto-2025-2.zip
```

Outputs in `Yocto/vck190_fmcp1/images/linux/`: `BOOT.BIN` (the device image with the PLM,
the NoC / DDR configuration and the PL, then TF-A and U-Boot; Versal has no FSBL), `Image`,
`system.dtb`, `u-boot.elf`, `rootfs.wic.xz` + `rootfs.wic.bmap`, `rootfs.tar.gz`. The zip holds
what the SD card needs: `BOOT.BIN`, `rootfs.wic.xz`, `rootfs.wic.bmap`, `BOOTAA64.EFI`
(systemd-boot) and a `readme.txt`. The Versal wic needs **two files added to its first (FAT) partition**: `BOOT.BIN`
at the top and `BOOTAA64.EFI` in `EFI/BOOT/` (the wic carries neither where the boot ROM and
U-Boot look for them):

```
bmaptool copy rootfs.wic.xz /dev/sdX            # or: xzcat rootfs.wic.xz | sudo dd of=/dev/sdX bs=4M conv=fsync
sudo mount /dev/sdX1 /mnt
sudo cp BOOT.BIN /mnt/
sudo mkdir -p /mnt/EFI/BOOT && sudo cp BOOTAA64.EFI /mnt/EFI/BOOT/
sudo umount /mnt
```

Set SW1 to SD boot ([per-board defaults](#per-board-defaults)) and power on. Log in on the UART
(115200, user `amd-edf`, a password is set at the first login) or over SSH on GEM0's RJ45 (DHCP).
A first Yocto build takes a few hours and about 60 GB of disk; later builds reuse the
shared-state cache.

The boot: the PLM loads the device image (CIPS, NoC, DDR controller, PL), U-Boot switches the
FMC's VADJ rail on and starts systemd-boot, which starts Linux. At boot `roceletd` checks VADJ,
programs the Si5328 (322.265625 MHz), releases the GT, configures and releases the MRMAC with
RS-FEC on, configures the engine with PAUSE TX and PAUSE RX on and waits for the link (the host NIC forced to
100 Gb/s, auto-negotiation off, RS-FEC). `journalctl -u roceletd` shows the same bring-up text as
the bare-metal console.

Boot time, measured on the VCK190 with the host NIC up: power on to the login prompt 42-46 s,
to `rl0` answering the host's ping about 45 s (U-Boot's 5 s autoboot delay and systemd-boot's 5 s
menu included); `roceletd` has the 100G link up 4-7 s after it starts. A warm reboot
(`systemctl reboot`) is back on `rl0` after about 45 s as well.

```{note}
U-Boot saves its environment (`uboot.env`, `uboot-redund.env`) to the card's FAT partition at
the first boot and uses the saved boot command from then on. When you replace only `BOOT.BIN` on
a card that has already booted, delete those two files too, so that the new `BOOT.BIN`'s boot
command (the VADJ enable included) takes effect. A freshly written wic has neither file.
```

## Settings, web UI, rl0, QP records, HSB, PYNQ

These work exactly as on the Zynq UltraScale+ design; the links go to its Linux page:

* [Settings](zynqmp_linux.md#settings) (`/etc/rocelet/rocelet.conf`, `rocelet-web.conf`, and
  their copies on the SD card's FAT partition) and the [web UI access token](zynqmp_linux.md#web-ui-access).
  The `extra_uio` key's default, `rocelet-mrmac`, is the MRMAC's UIO device.
* [rl0 and the engine share one address](zynqmp_linux.md#rl0-and-the-engine-share-one-address):
  192.168.20.2/24, MTU up to 9578, Linux answers ARP / ICMP, `ethtool rl0` reports 100000 Mb/s.
* [Connecting a host](zynqmp_linux.md#connecting-a-host-qp-records): `ssh amd-edf@<board> rl qp 0`,
  `rl RLH ...`, or the web UI.
* [Holoscan Sensor Bridge](zynqmp_linux.md#holoscan-sensor-bridge): `rl hsb on`; the Opsero
  register `LINK_GBPS` reads 100, the same as on the KCU116, and `TARGET` reads "VCK1".
* [The PS DDR window](zynqmp_linux.md#ps-ddr-window-and-the-reserved-memory): memory window
  **MR 3** (R_Key 0x4003) over the 256 MB region, `rl ddr`, `rl ddr fill`, `rl ddr check`;
  `pynq.MMIO(0x60000000, 0x10000000)` or the UIO device `rocelet-ddr`.
* [PYNQ and other user-space access](zynqmp_linux.md#pynq-and-other-user-space-access): the
  register window at `0x8000_0000` (UIO `rocelet-regs`).

`rl0` on the A72 is, as on the A53, a control and convenience interface (ARP, ICMP, SSH, the HSB
control plane), not a fast NIC: line-rate traffic is RDMA in the engine.

Measured on the VCK190 against a ConnectX-6 Dx at 100G with RS-FEC (all figures:
[](resources.md#linux-image)):

* `rl0`: ping in both directions, a flood ping of 20000 x 1400 B with 0 % loss, 4000-byte pings
  after `ip link set rl0 mtu 4200` (rl0 comes up with MTU 1500); SSH and the web UI over rl0.
  TCP with iperf3 on the A72, MTU 4200: host to board 2.41 Gb/s (one stream) / 2.67 Gb/s (four
  streams), board to host 2.69 / 3.50 Gb/s; at MTU 1500 about 1.7 Gb/s each way. The network
  stack's DMA buffers lie anywhere in Linux's memory, also above 4 GB (64-bit addressing).
* RDMA with the QP records over SSH, PMTU 4096: host WRITE 97.93 Gb/s, FPGA WRITE with immediate
  92.30, host READ 96.54, host SEND 85.85; into the PS DDR window (the 256 MB region, `mr=3`)
  host WRITE 97.85 Gb/s with every beat checked and host READ 88.94 Gb/s; a 60 s host WRITE at
  96.62 Gb/s with 0 uncorrectable RS-FEC codewords.
* `rl t pma` SELFTEST PASS 19/19 (exit status 0), `rl t full pma` 23/23.
* HSB: enumerated by NVIDIA's HSB 3.0.0 software, counter and IQ16 frames into GPU memory at
  72-76 Gb/s with every frame checked ([](hsb.md)); the [beamforming demo](beam_demo.md) names
  the board VCK190 by itself.
* Web UI: the status page shows target VCK190, MAC MRMAC, link 100 Gb/s; the page title is the
  host name, `rocelet-v190`.

## Porting to another Versal board

The Linux stack carries over unchanged; what changes per board is the
[per-board defaults](#per-board-defaults) table (device tree: the Ethernet PHYs and MAC
addresses, the reserved-memory base inside the DDR range that the engine's 40-bit DDR masters
reach, the VADJ enable of the board in U-Boot and in `vadj.c`) and the checklist on
[](porting.md).

## Files

| Path | Content |
|---|---|
| `sw/linux/roceletd/` | daemon, CLI, Linux platform layer (`plat_linux.c`: UIO, i2c-dev, the eFUSE DNA through nvmem or `/dev/mem`) |
| `sw/linux/rl-net/` | `rl_net.ko` (the same driver as on the ZCU106) |
| `sw/linux/web/` | web UI |
| `Yocto/bsp/vck190_fmcp1/` | board: device tree fixups (GEM0 / GEM1 PHYs + MACs, LPD I2C0, eFUSE nvmem, UIO nodes for the register window, the MRMAC and the reserved memory, rl0 node, 64-bit DMA addressing), the U-Boot VADJ fragment, the kernel command line (`clk_ignore_unused`) and configuration |
| `Yocto/meta-rocelet/` | recipes: `rl-net-mod`, `rocelet-tools` (roceletd, rl, rl0 network, udev rules incl. `/dev/rocelet-mrmac`), `rocelet-web`, image additions; `BOARD` and `LINE_RATE` from data.json |
