# Getting started

## What you need

| | `kcu116` (100G) | `zcu106` (40G; 10G option) | `vck190_fmcp1` (100G) |
|---|---|---|---|
| Board | [KCU116](https://www.xilinx.com/kcu116) evaluation board | [ZCU106](https://www.xilinx.com/zcu106) evaluation board | [VCK190](https://www.xilinx.com/vck190) evaluation board |
| FMC | Opsero [2x QSFP28 FMC] (OP120) on the HPC connector; the KCU116 routes the lanes of **QSFP28 port 0** only | Opsero [2x QSFP28 FMC] (OP120) on **HPC0**; the design uses **QSFP28 port 0** | Opsero [2x QSFP28 FMC] (OP120) on **FMCP1**; the design uses **QSFP28 port 0** |
| Self-test | nothing else (the GT near-end loopback is used), or a QSFP28 loopback plug in port 0 | the same | the same |
| RDMA with a host | a 100G QSFP28 cable (DAC or AOC) from port 0 to a RoCE v2 NIC | a QSFP28 or QSFP+ direct-attach cable from port 0 to a RoCE v2 NIC that does **40GBASE-CR4** (validated: NVIDIA ConnectX-6 Dx) | a 100G QSFP28 cable (DAC or AOC) from port 0 to a RoCE v2 NIC with RS-FEC |
| Board I/O | USB-UART and USB-JTAG | USB-UART; an SD card of 16 GB or more (the image is 8 GiB + 16 KiB, more than an 8 GB card holds); the board's RJ45 on your LAN for SSH and the web UI; USB-JTAG for the JTAG boot | the board's USB port (UART and JTAG through one FT4232H); a microSD card of 16 GB or more; GEM0's RJ45 (next to the USB connectors) on your LAN for SSH and the web UI |
| Tools | Vivado and Vitis 2025.2 on Linux or Windows, with the no-cost license of the CMAC IP | Vivado and Vitis 2025.2 (no IP license); for the Linux image a Linux build host (AMD EDF Yocto 2025.2, about 60 GB of disk) | Vivado **Enterprise** and Vitis 2025.2, with the no-cost license of the MRMAC IP ([licensing](index.md#licensing)); for the Linux image a Linux build host (AMD EDF Yocto 2025.2, about 60 GB of disk) |

For the host side, the host helper `rocelet_host` (rocelet repository) and, for the
[beamforming demo](beam_demo.md), an NVIDIA GPU, Docker with NVIDIA's Holoscan Sensor Bridge
container and a monitor ([](host_setup.md)).

## Get the sources

The rocelet engine and the omac Ethernet MACs are git submodules:

```
git clone --recursive https://github.com/fpgadeveloper/qsfp28-fmc-rocelet.git
cd qsfp28-fmc-rocelet
```

In an existing clone without the submodules: `git submodule update --init --recursive`.

## KCU116

### Build

```
./build.sh all --target kcu116          # Linux, or git bash on Windows
build.bat all --target kcu116           # Windows command prompt
```

This creates the Vivado project (`Vivado/kcu116/`), runs synthesis, implementation and the
bitstream in one Vivado process, exports the hardware (`Vivado/kcu116/rocelet_wrapper.xsa`),
builds the MicroBlaze console application in Vitis, combines it with the bitstream
(`Vitis/boot/kcu116/rocelet_boot.bit`), writes the configuration-flash image from it
(`rocelet_boot.mcs` + `.prm`, stage `cfgmem`, next to the bitstream) and zips the contents of
`Vitis/boot/kcu116/` into `bootimages/qsfp28-fmc-rocelet_kcu116_standalone-2025-2.zip`
(stage `package`). Single stages: `xsa`, `standalone`, `cfgmem`, `package`;
`./build.sh status --target kcu116` shows what is built.

The build reports (utilisation, timing) are in `Vivado/kcu116/reports/`.

### Run

1. Fit the FMC on the HPC connector, connect the USB-UART (the second port of the CP2105,
   `Enhanced COM port`) and the USB-JTAG, and power the board.
2. Program `rocelet_boot.bit` over JTAG (Vivado Hardware Manager, or
   `program_ftdi`/`xsdb`), or write `rocelet_boot.mcs` to the configuration flash so that the
   board boots the design at power-on. A build puts both in `Vitis/boot/kcu116/` (the `.mcs`
   once the `cfgmem` stage has run, which `all` does), and `package` zips whatever that
   directory holds; the MicroBlaze application is embedded in the bitstream.
3. Open the console at **115200 baud, 8N1**. The banner reports the GT reference clock, the
   link state and the engine's build parameters, then the prompt `rl>` appears.

## ZCU106

The ZCU106 target has two ways to run: the **Linux image** (the product: daemon, command line,
web UI, the `rl0` network interface) and a **bare-metal console** on the Cortex-A53 (the same
commands on the UART, no Linux). Both run the same bitstream. The design is built for the 40G
MAC; the [10G option](zynqmp_hw.md#omac_10g-10gbase-r-one-lane) is a one-line manifest change.

### Build

```
./build.sh all --target zcu106          # Linux build host: bitstream, bare-metal console, Linux image
./build.sh xsa --target zcu106          # the hardware only (Linux or Windows)
./build.sh standalone --target zcu106   # the bare-metal console BOOT.BIN (Linux or Windows)
./build.sh yocto --target zcu106        # the Linux image (Linux only; builds the XSA first if needed)
```

The Vivado stage generates the transceiver IP from the omac submodule, builds the block design
and the bitstream (`Vivado/zcu106/`); `standalone` builds the A53 console and
`Vitis/boot/zcu106/BOOT.BIN` (FSBL, PMU firmware, bitstream, console); `yocto` builds the AMD
EDF image in `Yocto/zcu106/images/linux/`. A first Yocto build takes a few hours and needs
about 60 GB of disk. The boot files are zipped into
`bootimages/qsfp28-fmc-rocelet_zcu106_standalone-2025-2.zip` and
`bootimages/qsfp28-fmc-rocelet_zcu106_yocto-2025-2.zip`.

### Run Linux (SD card)

1. Write the image to the SD card's raw device (not a partition), then copy `BOOT.BIN` to its
   first (FAT) partition; the image alone does not boot:

   ```
   bmaptool copy rootfs.wic.xz /dev/sdX            # or: xzcat rootfs.wic.xz | sudo dd of=/dev/sdX bs=4M conv=fsync
   sudo mount /dev/sdX1 /mnt && sudo cp BOOT.BIN /mnt/ && sudo umount /mnt
   ```

2. Fit the FMC on HPC0, set the ZCU106 to SD boot (DIP switch **SW6 = 1000**: 1 ON, 2-4 OFF),
   connect the USB-UART (115200 8N1; the first port of the CP2108) and the board's RJ45 to
   your LAN, insert the card and power on.
3. Log in as `amd-edf` on the UART (a password is set at the first login), or over SSH once
   the board has its LAN address (DHCP on the RJ45).
4. At boot the daemon `roceletd` programs the FMC's clock, brings up the 40G MAC and waits for
   the link; `journalctl -u roceletd` shows the bring-up and `rl st` the status. The web UI is
   at `http://<board>/`.

[](zynqmp_linux.md) describes the Linux stack: `rl`, `rl0`, the web UI, the PS DDR window and
access from your own applications (PYNQ included).

### Run the bare-metal console

* **From SD:** copy `BOOT.BIN` of the standalone zip (or `Vitis/boot/zcu106/`) to the first
  (FAT) partition of an SD card (nothing else is needed), set SW6 = 1000 and power on.
* **Over JTAG:** set the ZCU106 to JTAG boot mode (SW6 = 1111), open the
  `Vitis/zcu106_workspace` workspace in the Vitis IDE and run the `rocelet_console`
  application on the hardware (the run configuration programs the bitstream, then loads and
  starts the console). JTAG needs the AMD cable drivers
  ([installing the cable drivers](https://docs.amd.com/r/en-US/ug973-vivado-release-notes-install-license/Installing-Cable-Drivers)).

Open the console on the USB-UART at **115200 baud, 8N1**; the banner shows the MAC
(`omac_40g 40 Gb/s`), the clock bring-up and the link, then the prompt `rl>`. The commands are
those of [](console.md) (ZCU106 differences in its last section).

## VCK190

The VCK190 target has the same two ways to run as the ZCU106: the **Linux image** (daemon,
command line, web UI, the `rl0` network interface) on the Cortex-A72, and a **bare-metal
console** on the Cortex-A72. Both run the same device image. Building it needs Vivado
Enterprise and the MRMAC license ([licensing](index.md#licensing)).

### Build

```
./build.sh all --target vck190_fmcp1          # Linux build host: device image, bare-metal console, Linux image
./build.sh xsa --target vck190_fmcp1          # the hardware only (Linux or Windows)
./build.sh standalone --target vck190_fmcp1   # the bare-metal console BOOT.BIN (Linux or Windows)
./build.sh yocto --target vck190_fmcp1        # the Linux image (Linux only; builds the XSA first if needed)
```

The Vivado stage builds the block design and the device image (`Vivado/vck190_fmcp1/`, the
XSA with the PDI); `standalone` builds the A72 console and `Vitis/boot/vck190_fmcp1/BOOT.BIN`
(the device image with the PLM, then the console; Versal has no FSBL); `yocto` builds the AMD
EDF image in `Yocto/vck190_fmcp1/images/linux/`. The boot files are zipped into
`bootimages/qsfp28-fmc-rocelet_vck190_fmcp1_standalone-2025-2.zip` and
`bootimages/qsfp28-fmc-rocelet_vck190_fmcp1_yocto-2025-2.zip`.

### Run Linux (SD card)

1. Write the image to the microSD card's raw device, then copy `BOOT.BIN` to its first (FAT)
   partition and `BOOTAA64.EFI` (in the Yocto zip) to `EFI/BOOT/` on the same partition; the
   image alone does not boot ([details](versal_linux.md#build-and-boot)):

   ```
   bmaptool copy rootfs.wic.xz /dev/sdX
   sudo mount /dev/sdX1 /mnt && sudo cp BOOT.BIN /mnt/ \
     && sudo mkdir -p /mnt/EFI/BOOT && sudo cp BOOTAA64.EFI /mnt/EFI/BOOT/ && sudo umount /mnt
   ```

2. Fit the FMC on FMCP1, set the VCK190 to SD boot (boot-mode switch **SW1 = 1000**: 1 ON,
   2-4 OFF), insert the card into the Versal's boot microSD slot (the other microSD slot
   belongs to the system controller), connect the USB port (the console is the second serial
   port of the FT4232H, 115200 8N1) and GEM0's RJ45 to your LAN, and power on.
3. Log in as `amd-edf` on the UART (a password is set at the first login), or over SSH once the
   board has its LAN address (DHCP on GEM0).
4. U-Boot switches the FMC's VADJ rail on; at boot the daemon `roceletd` programs the FMC's
   clock, brings up the MRMAC with RS-FEC and waits for the link; `journalctl -u roceletd` shows
   the bring-up and `rl st` the status. The web UI is at `http://<board>/`.

[](versal_linux.md) lists what is specific to the Versal image; the Linux stack itself is
described on [](zynqmp_linux.md).

### Run the bare-metal console

* **From SD:** copy `BOOT.BIN` of the standalone zip (or `Vitis/boot/vck190_fmcp1/`) to the
  first (FAT) partition of a microSD card (nothing else is needed), set SW1 = 1000 and power on.
* **Over JTAG:** set SW1 to JTAG boot (SW1 = 1111) and load the device image and the console
  with `xsdb` (part of Vitis). The device image (PDI) carries the PLM and the PSM, which set up
  the processing system, the NoC and the DDR (Versal has no FSBL); the console then goes to
  Cortex-A72 #0:

  ```
  xsdb% connect
  xsdb% targets -set -filter {name =~ "Versal*"}
  xsdb% device program Vivado/vck190_fmcp1/vck190_fmcp1.runs/impl_1/rocelet_wrapper.pdi
  xsdb% targets -set -filter {name =~ "Cortex-A72 #0"}
  xsdb% rst -processor -clear-registers
  xsdb% dow Vitis/vck190_fmcp1_workspace/rocelet_console/build/rocelet_console.elf
  xsdb% con
  ```

  `rst -processor` may warn that it cannot activate the default subsystem; the warning is
  harmless. `device program Vitis/boot/vck190_fmcp1/BOOT.BIN` loads the device image and the
  console in one step instead, and the Vitis IDE can run the `rocelet_console` application of
  the `Vitis/vck190_fmcp1_workspace` workspace on the hardware.

The console switches the FMC's VADJ rail on itself, so the bare-metal boot needs no U-Boot.
Open the console at **115200 baud, 8N1**; the banner shows VADJ, the Si5328 at 322.265625 MHz,
the GT quad and the engine clock, the MRMAC link with RS-FEC and its lane line, the PAUSE
state and the versions, then the prompt `rl>`:

```
VADJ_FMC enabled: 1500 mV (IR38164 0x1E behind TCA9548 0x74, LPD I2C0)
Si5328 programmed: GT reference clock 322.265625 MHz
GTY quad ready: engine clock 300000 kHz
Port 0: link up, 100 Gb/s, RS-FEC on, loopback off (external) (2800 ms)
  PCS lanes 0-19 block lock 0xFFFFF | RS-FEC lane lock 0-3 1111 aligned 1 mapping 0 | ...
PAUSE TX on (802.3x from the RX FIFO level; 'pause tx 0' turns it off)
PAUSE RX on (the host's 802.3x PAUSE holds the engine's sending; 'pause rx 0' turns it off)
```

The commands are those of [](console.md) (VCK190 differences in
[its own section](console.md#versal-cortex-a72-bare-metal-console)).

## Self-test

The built-in self-test needs no cable, no plug and no host: it runs in the GT near-end
loopback and puts the link back afterwards (a cable to a NIC may stay connected; the NIC sees
two short link drops). On the KCU116 and the ZCU106 / VCK190 bare-metal consoles type `t pma`
at the `rl>` prompt; on the ZCU106 and VCK190 Linux images run `rl t pma` (also over SSH: the
exit status is 0 on PASS):

```
rl> t pma
=== self-test: rocelet 0.3.0, 16 QPs, RING, READ depth 16, self-test logic built in, RS-FEC on, loopback GT near-end PMA
TEST link up: PASS
TEST loopback path (the FPGA's frames come back): PASS
...
SELFTEST PASS 19/19 loop=pma fec=1 selftest_logic=1
```

(`fec=0` on the ZCU106: its 40G and 10G links have no FEC; `fec=1` on the KCU116 and the
VCK190.) `t full pma` adds throughput and
latency through the engine's own responder. Every test prints a `TEST <name>: PASS|FAIL` line,
and the run ends with one `SELFTEST PASS|FAIL <passed>/<run>` line. With a QSFP28 loopback plug
in port 0, plain `t` works as well. In the GT loopback the frames are still transmitted on the
cable, addressed to the FPGA itself.

## Set up the host

Everything beyond the self-test needs a host with a RoCE v2 NIC on QSFP28 port 0, forced to the
board's speed:

| Target | Host port |
|---|---|
| `kcu116`, `vck190_fmcp1` | 100G, auto-negotiation off, RS-FEC (the ConnectX-6 Dx's FEC `Auto` resolves to RS) |
| `zcu106` | **40G, auto-negotiation off, FEC off**: `sudo ethtool -s <if> speed 40000 duplex full autoneg off` and `sudo ethtool --set-fec <if> encoding off` |
| `zcu106`, 10G option | 10G, auto-negotiation off, FEC off (`speed 10000`) |

In every case: MTU 4200 for a path MTU of 4096, the address 192.168.20.1/24 (the board is
192.168.20.2), point to point (no switch). For the [beamforming demo](beam_demo.md) the host also
needs an NVIDIA GPU, Docker with NVIDIA's Holoscan Sensor Bridge container, and a monitor with an
X session for the window. [](host_setup.md) takes a bare PC through all of it, from the drivers
and the port to starting the demo; the RDMA tests below need only the port of that page and the
host helper `rocelet_host`.

## Connect a host

Point-to-point link as above. The host helper `rocelet_host` (in the rocelet submodule,
`submodules/rocelet/host`) creates the host QP and exchanges one-line records with the console
(validated with an NVIDIA ConnectX-6 Dx; its RDMA device is `rocep179s0f0` below):

```
rl> setup
rl> qp 0                                  # prints RLF / RLFM: give them to rocelet_host
$ rocelet_host run --dev rocep179s0f0 --role sink --op write_imm --len 65536 --count 100000 \
      --rq-depth 4000 --verify sample:16 --peer 'RLF qp=0 ...' --peer 'RLFM mr=0 ...'
                                          # prints RLH / RLHM: paste both into the console
rl> wg write_imm 65536 100000             # line-rate WRITE with immediate into host memory
```

On the ZCU106 and VCK190 Linux images the same lines go through SSH (`ssh amd-edf@<board> rl qp 0`,
`ssh amd-edf@<board> rl RLH ...`) or the web UI; see
[](zynqmp_linux.md#connecting-a-host-qp-records).

[](hardware_test.md) has the host preparation, the transfer recipes in both directions, notes
for a ConnectX-6 Dx host, fault injection, frame capture, the Holoscan Sensor Bridge mode and
the results measured with the KCU116; the 40G and 10G results of the ZCU106 are on
[](resources.md#measured-zcu106-40g-and-10g).

[2x QSFP28 FMC]: https://docs.opsero.com/op120/datasheet/overview/
