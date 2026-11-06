# Zynq UltraScale+ design: Linux

The Linux flow of the Zynq UltraScale+ targets (data.json `yocto` = true; today `zcu106`, 40G
with omac_40g; the 10G option builds the same way): an AMD EDF (Yocto 2025.2) SD-card image in
which a daemon owns the hardware and Linux owns the port's IP address. The register map, the
clock guard and the DMA frame convention it relies on are in [](zynqmp_hw.md). Everything on this
page is common to the Zynq UltraScale+ targets except the [per-board defaults](#per-board-defaults).

## Per-board defaults

| Item | `zcu106` |
|---|---|
| Board BSP | `Yocto/bsp/zcu106/` (device tree fixups `meta-user/recipes-bsp/device-tree/files/system-user.dtsi`, `conf/local.conf.append`); MACHINE `rocelet-zcu106` (generated from the XSA) |
| Host name | `rocelet-z106` |
| Console UART | PS UART0 (the ZCU106's CP2108, first port), 115200 8N1 |
| Board Ethernet (SSH, web UI) | GEM3 on the RJ45 (TI DP83867 PHY at MDIO address 0xc, RGMII delays in the device tree), DHCP, fixed MAC **00:0a:35:06:21:07** |
| `rl0` (QSFP28 port 0) | **192.168.20.2/24** (host 192.168.20.1/24), MAC **00:0a:35:06:21:08** (the GEM3 address + 1) |
| PS DDR window | `reserved-memory` **256 MB at `0x6000_0000`** (`no-map`), UIO `rocelet-ddr` |
| SD boot | DIP switch SW6 = 1000 (1 ON, 2-4 OFF) |

The rl0 address is common to every target (`Yocto/meta-rocelet/recipes-apps/rocelet-tools/files/10-rl0.network`);
the MAC addresses, the PHY and the reserved-memory base are in the board's device tree. Change
the MAC addresses for boards on your own network.

## What runs where

| Part | Where | What it does |
|---|---|---|
| rocelet engine, MAC (omac_40g; omac_10g with the 10G option), self-test logic, HSB producer | PL | the RDMA data path at line rate; UDP 4791 (RoCE v2) is terminated in hardware |
| `roceletd` (systemd service) | PS, user space | owns the hardware: register window and PS DDR window through UIO, Si5328 + QSFP28 through i2c-dev; runs the **same console sources** as the bare-metal builds (`Vitis/common/src`: bring-up, engine setup, every console command, the self-test, the HSB device mode); serves the console on `/run/rocelet/roceletd.sock` |
| `rl` | PS, CLI | the console: `rl <command>` (one command; exit status 0, 1 when the command reported a failure such as a failed test, 2 when `roceletd` cannot be reached) or `rl` (interactive) |
| `rl0` (`rl_net.ko`) | PS, kernel | the Linux network interface of QSFP28 port 0: every frame the engine does not terminate (ARP, ICMP, IP, the HSB control plane) through the netdev DMA channel |
| web UI (`rocelet-web`, port 80) | PS, Python | status, link, counters, QP records, self-test, HSB mode / source / rate, a console line ([access token](#web-ui-access)) |

The console text is the MicroBlaze / bare-metal console's: [](console.md) applies unchanged (`rl st`,
`rl t pma`, `rl qp 0`, `rl RLH ...`, `rl hsb on`, ...). Linux-only commands: `rl net` (rl0 and the
engine's netdev mode), `rl log [n]` (daemon messages), `rl json` (the web UI's status), `rl version`.

## Build and boot

```
./build.sh yocto --target <label>      # Linux build host; builds the XSA first if needed
./build.sh package --target <label>    # bootimages/qsfp28-fmc-rocelet_<label>_yocto-2025-2.zip
```

Outputs in `Yocto/<label>/images/linux/`: `BOOT.BIN` (FSBL, PMU firmware, PL bitstream, TF-A,
U-Boot), `Image`, `system.dtb`, `boot.scr`, `rootfs.wic.xz` + `.bmap`. Write the wic to the SD
card's raw device and copy `BOOT.BIN` to its first (FAT) partition (the wic alone does not boot):

```
bmaptool copy rootfs.wic.xz /dev/sdX
sudo mount /dev/sdX1 /mnt && sudo cp BOOT.BIN /mnt/ && sudo umount /mnt
```

Set the board to SD boot ([per-board defaults](#per-board-defaults)) and power on. Log in on the
UART (115200, user `amd-edf`, a password is set at the first login) or over SSH on the board's
RJ45 (DHCP).
A first Yocto build takes a few hours and about 60 GB of disk; later builds reuse the
shared-state cache.

At boot `roceletd` programs the Si5328 (156.25 MHz), releases the GT and the MAC, configures the
engine with PAUSE TX on (see [](console.md), Zynq UltraScale+) and waits for the link (the host NIC forced to
40 Gb/s, 10 Gb/s with the 10G option; auto-negotiation off, FEC off).
`journalctl -u roceletd` shows the same bring-up text as the bare-metal console.

## Settings

`/etc/rocelet/rocelet.conf` (roceletd) and `/etc/rocelet/rocelet-web.conf` (web UI) hold
`key = value` lines; a file of the same name on the SD card's FAT partition (next to
`BOOT.BIN`) overrides them, so a setting can be changed without logging in. Restart the service
(`systemctl restart roceletd` / `rocelet-web`) or reboot after a change.

| `rocelet.conf` key | Default | Meaning |
|---|---|---|
| `iface` | `rl0` | the port's Linux interface; the engine takes its MAC and IPv4 address |
| `hsb` | `off` | `on`: start the Holoscan Sensor Bridge device mode at boot |
| `socket` | `/run/rocelet/roceletd.sock` | the console socket that `rl` and the web UI use (`rl -s <socket>` for another one) |
| `group` | `rocelet` | the group that owns the socket (mode 0660; without the group 0600, root only); the image puts `amd-edf` in it |
| `regs_uio` | `rocelet-regs,rsys_aon_bd` | the UIO device name(s) of the register window, comma separated, first match wins |
| `ddr_uio` | `rocelet-ddr` | the UIO device name of the PS DDR window |
| `extra_uio` | `rocelet-mrmac` | further register blocks to map, UIO device names, comma separated; a missing device is skipped (the Versal design's MRMAC registers; nothing on the ZCU106) |

### Web UI access

The web UI serves the page to anybody, and its API (everything that reads or changes the
design) is open as long as `token` in `rocelet-web.conf` is empty, which is how the image
ships: then anybody who reaches the board's port 80 can control the design, and the page shows
a warning. On a shared network set a token:

```
token = <secret>          # /etc/rocelet/rocelet-web.conf, or rocelet-web.conf on the FAT partition
```

With a token set, an API request without it is refused (HTTP 403); the page then asks for the
token, keeps it in the browser (local storage) and sends it with every request (header
`X-Rocelet-Token`, and the cookie `rocelet_token`). Scripts send the header, e.g.
`curl -H 'X-Rocelet-Token: <secret>' http://<board>/api/status`. The token protects the web UI
only: `rl` talks to the daemon's socket, which the `group` setting protects, and SSH has its own
login. The other keys of `rocelet-web.conf`: `listen` (default `0.0.0.0`), `port` (80), `title`
(the name on the page), `socket` (the daemon's socket).

## rl0 and the engine share one address

Linux owns QSFP28 port 0's IP address; the engine answers RoCE v2 for the same address:

* `rl0` is configured by systemd-networkd, `/etc/systemd/network/10-rl0.network`:
  **192.168.20.2/24** by default, no DHCP, no default route, no IPv6 autoconfiguration (the host NIC is
  192.168.20.1/24). Never bridge rl0 to another network.
* The MAC address is the device tree's (`local-mac-address` of the `rocelet-net` node in
  `Yocto/bsp/<board>/meta-user/recipes-bsp/device-tree/files/system-user.dtsi`): the Opsero
  default is the board Ethernet port's address + 1 ([per-board defaults](#per-board-defaults)).
  Change both for boards on your own network.
* `roceletd` keeps the engine's MAC and IPv4 equal to rl0's: `ip addr` / networkd changes reach
  the engine within a second; the console's `ip` / `mac` and HSB's hololink-set-ip change rl0.
* With rl0 up the engine passes ARP, ICMP and every non-RoCE frame to Linux (engine `CTRL.ARP_INT`
  = 0, `OTHER_RX_EN` = 1, `C_ODMA_CTRL` = 1): `ping`, `tcpdump -i rl0`, `iperf3`, SSH over the
  link all work. With rl0 down, or without `rl_net.ko`, the engine's own ARP / ICMP responder
  answers (as on the bare-metal console).
* While a loopback test runs (`rl t ...`, `arp`, `read`, `write`, ... the commands of the
  self-test) roceletd takes rl0 down and turns the engine's responder back on (the suite tests
  it), then restores both.
* rl0's MTU goes up to **9578** (omac `MAX_FRAME` 9600 with the FCS, room for a VLAN tag); the
  RoCE path MTU is independent (per QP, up to 4096; the host NIC needs MTU >= 4200).
* Throughput on rl0 itself (Linux networking, not RDMA): a TCP stream host -> board measured
  2.2 Gb/s with an untuned Python sink; frames the PL cannot hand over (no free RX buffer) are
  dropped and counted (`rl net`), the engine is never stalled.
* `ethtool rl0` (speed from the always-on block), `ethtool -S rl0` (copybreak, long frames, link
  events, MAC clock), `rl net` (channel counters: frames to Linux / dropped / from Linux).

## Connecting a host (QP records)

The out-of-band records are the console's (`RLF` / `RLFM` from the FPGA, `RLH` / `RLHM` from the
host helper). On Linux they travel over SSH instead of a serial console. On the host, for a host
RDMA WRITE into the FPGA's pattern window (the other roles work the same way):

```
ssh amd-edf@<board> rl qp 0                       # the FPGA's RLF + RLFM lines
mkfifo /tmp/rlctl
rocelet_host run --dev <rdma dev> --role source --op write --len 65536 --count 20000 --rate max \
    --fpga-mr 0 --peer 'RLF ...' --peer 'RLFM ...' --ctl /tmp/rlctl --record-out /tmp/rlh.txt &
ssh amd-edf@<board> rl RLH ...                    # each line of /tmp/rlh.txt (RLH, RLHM)
echo go > /tmp/rlctl                              # sink role: start the FPGA sender instead,
                                                  #   e.g. ssh amd-edf@<board> rl wg write_imm 65536 20000
```

Measured this way on the ZCU106 at 40G against a ConnectX-6 Dx: RDMA WRITE, WRITE with immediate, SEND and
READ at 38.7-39.2 Gb/s, into the URAM window and into the PS DDR window (data checked with
`rl ddr check` / `rl ddr fill`); rl0 flood ping 20000 x 1400 B with 0 % loss and 4000-byte
pings with MTU 4200. All figures: [](resources.md#measured-zcu106-40g-and-10g).

The web UI does the same in a browser (show the RLF of a QP, paste the RLH lines).

## Holoscan Sensor Bridge

`rl hsb on` (or `hsb = on` in `/etc/rocelet/rocelet.conf` to start it at boot): the enumeration
(BOOTP from UDP 12268 to the broadcast 12267 once a second) and the register protocol (UDP 8192)
run as ordinary UDP sockets bound to rl0 inside roceletd; the data plane, the UUID
(98183d0f-18ee-4719-a3b4-ca69e9b94c97) and the serial number scheme (from the device DNA) are
the MicroBlaze design's. [](hsb.md) applies unchanged, with the stream rate capped at the link
(`LINK_GBPS` register 0x7F000018 reads 40 with omac_40g): on the ZCU106, IQ16 and counter frames
into GPU memory were measured at 39.0 Gb/s with every frame checked, and the
[beamforming demo](beam_demo.md) runs at up to 40 Gb/s.

## PS DDR window and the reserved memory

The device tree reserves a region of PS DDR (`reserved-memory`, `no-map`; **256 MB at
0x6000_0000** on the ZCU106, [per-board defaults](#per-board-defaults)) and exposes it as the UIO
device `rocelet-ddr`. roceletd gives the engine that region (`C_DDR_BASE` / `C_DDR_SIZE`) and
memory window **MR 3** (R_Key 0x4003, VA 0, the size of the region) over it:
`rl qp 0` lists it as `RLFM mr=3`. `rl ddr`, `rl ddr fill [off] [n]`, `rl ddr check [off] [n]` work
on the whole region by default. The UIO mapping is uncached, so no cache maintenance is needed
(aligned 32/64-bit accesses only: no `memcpy` / `memset` on the mapping).

Applications reach the same bytes without the daemon: `/dev/uio<N>` with the name `rocelet-ddr`
(`/sys/class/uio/uio*/name`, udev link `/dev/rocelet-ddr`), map 0.

## PYNQ and other user-space access

Everything Linux-side is user space except `rl_net.ko`:

* register window: UIO `rocelet-regs` (`/dev/rocelet-regs`, 1 MB at 0x8000_0000; engine `+0x0`,
  system registers `+0x1_0000`, URAM `+0x4_0000`, always-on registers `+0x8_0000`). The clock
  guard answers every access, so a mapping can never hang the CPU or raise an SError
  (`0xDEADC10C` while the MAC clock is stopped). `pynq.MMIO(0x80000000, 0x100000)` works the
  same way; only one owner should write the engine at a time (stop roceletd, or go through
  `rl`).
* PS DDR window: `pynq.MMIO(<base>, <size>)` of the reserved region (ZCU106:
  `pynq.MMIO(0x60000000, 0x10000000)`) or the `rocelet-ddr` UIO device; a
  `pynq.allocate()` buffer also works (write its physical address to `C_DDR_BASE` / `C_DDR_SIZE`
  and flush / invalidate around the transfers).
* nothing requires the PL at boot except `rl_net.ko` (it probes the always-on block): a PYNQ
  overlay can load the bitstream, then `insmod rl_net.ko` and start roceletd.

## Porting to another Zynq UltraScale+ or RFSoC board

The Linux stack carries over unchanged; what changes per board (device tree, MAC addresses,
reserved-memory base, the recipe's board selection) is the [per-board defaults](#per-board-defaults)
table above and the checklist on [](porting.md).

## Files

| Path | Content |
|---|---|
| `sw/linux/roceletd/` | daemon, CLI, Linux platform layer (`plat_linux.c`, `compat/`), HSB UDP transport |
| `sw/linux/rl-net/` | `rl_net.ko` (dmaengine / xilinx_dma, NAPI, carrier from the always-on block) |
| `sw/linux/web/` | web UI (`rocelet_web.py` + `web/`) |
| `Yocto/bsp/<board>/` | board: device tree fixups (UART, GEM3 PHY + MAC, UIO nodes, reserved memory, rl0 node), kernel config |
| `Yocto/meta-rocelet/` | recipes: `rl-net-mod`, `rocelet-tools` (roceletd, rl, rl0 network, udev), `rocelet-web`, image additions |
| `/etc/rocelet/rocelet.conf`, `rocelet-web.conf` | settings ([](#settings)); a copy on the SD card's FAT partition overrides them |
