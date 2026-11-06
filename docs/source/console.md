# Console

The console application (`Vitis/common/src/`) runs on the KCU116's MicroBlaze, built for the
Cortex-A53 on the ZCU106 and for the Cortex-A72 on the VCK190 (bare metal, or inside the Linux
daemon as `rl <command>`); the differences of the ZCU106 and the VCK190 are in the last two
sections ([ZCU106](#zynq-ultrascale-cortex-a53-bare-metal-console),
[VCK190](#versal-cortex-a72-bare-metal-console)). On
the KCU116 it offers a console on the board's USB-UART at **115200 baud, 8N1**. At power-up it programs the Si5328 (GT reference clock 322.265625 MHz),
brings up the CMAC (RS-FEC on), configures the engine for loopback (see below) and prints the
status. Commands that need the engine are refused while the CMAC user clock is stopped (only
`fec`, `loop`, `link`, `st`, `rd`, `wr` and the help work then). `help` or `?` (or any unknown
command) prints the command list.

## Status and link

| Command | Action |
|---------|--------|
| `st` | link, engine build parameters, errors, READ continuation, the requester's ACK timeout and retry limits, the engine's view of the link (`STATUS.LINK_UP`), whether the ACK timeouts are held (`STATUS.TIMER_HOLD`), `LINK_GRACE` and the engine's link-drop count (`CNT_LINK_DOWN`), all non-zero counters |
| `dump` / `clr` | counters / clear the counters and the engine's error latch |
| `fec 0\|1` | RS-FEC off / on, then relink (the host must use the same setting) |
| `loop off\|pcs\|pma` | GT near-end loopback (PCS or PMA) or none, then relink |
| `link` | reset the CMAC and wait for the link |
| `pause [rx 0\|1] [tx 0\|1] [xoff n] [xon n] [quanta n] [refresh n]` | 802.3x PAUSE: honour received PAUSE frames (rx), send PAUSE from the RX FIFO level (tx; XOFF / XON levels in 64-byte beats of the 512-beat RX FIFO, default 128 / 64); default off on the KCU116, **PAUSE TX on (rx off) on the ZCU106 and the VCK190**. The host's link pause must match (`ethtool -A <if> rx on tx on`) |
| `vlan rx 0\|1`, `vlan tx 0\|1 [pcp] [vid]` | accept 802.1Q VID-0 priority tags (default on); tag the frames sent (default off: only for a host whose QP is tagged too; a NIC may drop tagged RoCE frames on an untagged QP) |
| `ip <a.b.c.d>`, `mac <12 hex digits>` | the FPGA's address (the bare-metal consoles' defaults are 192.168.20.2 and 02:0a:35:72:6c:01; on the ZCU106 and VCK190 Linux images the engine takes the address and MAC of `rl0`, and `ip` / `mac` change `rl0`, [](zynqmp_linux.md#rl0-and-the-engine-share-one-address)). `mac` also clears the counters and the error latch and turns the requester rate limit off (`pace 0`, burst 16 KB); the other engine settings stay (`setup` restores them all) |
| `to <us>` | requester ACK timeout (default 5 ms, rocelet's reset value since v0.2.1; with the retry count 7 a QP gives up after 8 timeouts in a row = 40 ms without an ACK while the link is up, which covers a ConnectX-6 that goes silent 15-25 ms before the FPGA loses alignment when the host reconfigures its port). 0 to 1,048,575 us (20-bit register); a larger value is refused with an error message and the setting is not changed. `setup` and the tests put it back to 5 ms |
| `grace [us]` | how long the requester's ACK timeouts stay held after the link comes back (rocelet `LINK_GRACE`, timer ticks = microseconds; 0 to 16,777,215, i.e. up to 16.7 s; 0 = no grace; default 2,000,000 = 2 s; a larger value is refused with an error message and the setting is not changed). Without an argument: the value, the link and hold state, link drops and ACK timeouts. `setup` and the tests keep the value set here |
| `pace <Gb/s> [burst]` | requester rate limit over all QPs (rocelet `PACE_RATE` / `PACE_BURST`; wire bytes = payload + 98 per packet; 0 = off, the default) |

## Connecting a host

The host helper `rocelet_host` (rocelet repository, `host/`; see [](hardware_test.md)) creates
the host QP and exchanges one-line parameter records with the console:

```
host -> FPGA (paste into the console):
  RLH qpn=0x1b psn=0x3c2b1a ip=192.168.20.1 mac=6cfe549177f0 mtu=4096 ord=16
  RLHM rkey=0x12ab va=0x7f3e40000000 len=0x4000000
FPGA -> host (qp 0 prints them; paste into rocelet_host):
  RLF qp=0 qpn=0x100 psn=0x10123 ip=192.168.20.2 mac=020a35726c01 mtu=4096 rd=16 seed=0x5eed1234
  RLFM mr=0 rkey=0x1000 va=0x10000000000 len=0x40000000 pat=0x10000000000 acc=rw
  RLFM mr=1 rkey=0x2001 va=0x0 len=0x40000 acc=rw
  RLFM mr=2 rkey=0x3002 va=0x0 len=0x40000 acc=r
```

| Command | Action |
|---------|--------|
| `setup [pmtu_log2]` | reset every QP (loopback configuration), memory window, counters and the error latch, and forget the host peers: start here before a new host session. It also puts the engine settings back to their defaults: READ continuation on (`rcont 1`), loss recovery (not fatal), retry limits 7 / 7, RNR wait clamp 10 us .. 655 ms and RNR NAK timer, AckReq every 16 packets, no rate limit (`pace 0`), timer tick 1 us, ACK timeout 5 ms, `LINK_GRACE` = the `grace` value. `pause` and `vlan` settings are kept |
| `RLH qpn= psn= ip= mac= mtu= [qp=n]` | configure FPGA QP n (default 0) towards the host QP (RC, unless `qp <n> type` changed it since the last `setup`) |
| `RLHM rkey= va= len=` | the host buffer the FPGA writes into (`wg`, `post`) |
| `qp <n>` | print the FPGA's records for QP n, and the QP's state (QP 13 after a host enabled an HSB data plane: type "UC-HSB, HSB data plane", details in `hsb st`) |
| `qp <n> type rc\|uc\|hsb [dport]` | QP type: RC, UC, or UC in Holoscan Sensor Bridge mode (every packet a WRITE Only with its own RETH, the metadata WRITE-with-immediate carries {PSN, page}; first PSN 0, UDP source port 12288); `dport` = UDP destination port (omitted or 0 = 4791; another port for HSB's Linux-UDP receiver) |
| `hsb <n> [dport]` | short for `qp <n> type hsb [dport]` |

Holoscan Sensor Bridge device mode ([](hsb.md)): the board enumerates and is configured by an
HSB host instead of the parameter records.

| Command | Action |
|---------|--------|
| `hsb on` / `hsb off` | start / stop the HSB device mode: BOOTP enumeration once a second, the register protocol on UDP 8192, the control-plane receive FIFO; `off` also stops a running data plane. Off after power-up; `setup` keeps it |
| `hsb` / `hsb st` | identity (UUID, HSB IP version, serial), counters (BOOTP, requests, replies, errors, sequence errors, latched sequence, set-ip), the last host, the receive FIFO, the register file, the data-plane registers, the beam generator (active scene id, its first frame, applies, pending / running / clipped, then "APPLY pending (scene N)", "scene N staged without APPLY" or "nothing staged"), the producer and its QP (13), the watchdog and link-pause state and counters |
| `hsb serial` | the device DNA and the HSB serial number derived from it |
| `hsb src iq\|count\|beam` / `hsb rate <Mb/s>` / `hsb scene <1-4>` | frame source (IQ16, counter, beam array generator), frame rate limit (0 = none), IQ16 scene; source and scene apply when the host next enables the data plane, the rate at once (from the next frame) while it runs |
| `hsb wd <ms>` | keepalive timeout of the producer watchdog, 0 = off (default); the host application normally sets it (Opsero register KEEPALIVE_TIMEOUT_MS) |
| `hsb lpause on\|off` | pause the producer while the link is down (default on) |

Link loss: the engine holds its requester ACK timeouts while the CMAC is not aligned or reports
a local / remote fault, and for `grace` (default 2 s) after the link is back, so a QP with data in flight survives a cable
pull or a link-partner reset of any length on the FPGA side: when the hold ends, every QP whose
ACK became overdue retransmits its window once (go-back-N). Why 2 s: the remote fault keeps the
hold on until the link partner receives the FPGA's signal, so the grace starts at the partner's
own link-up (a ConnectX-6 Dx: 4.4-5.6 s after a CMAC reset, the engine's link within 0.22 s of
its carrier), and 2 s leaves margin for a partner whose port is up before its RDMA stack
answers.
The cost: after a link loss with data in flight a QP whose ACKs were lost waits up to the grace
after the partner is back before it retransmits (a NAK from the host ends the wait earlier).
The engine's link-drop counter (`st`, `grace`) counts every fault toggle, so one physical drop
usually counts 2-3 times (the CMAC's own counter: once). The host's side of the connection
is governed by the host QP's own `timeout` / `retry_cnt` ([Host setup and host rules](https://rocelet.ethernetfmc.com/en/latest/host-setup.html)
in the rocelet docs, "Link flaps and cable pulls").

Memory windows offered to the host: `mr=1` is the 256 KB on-chip memory window (read/write),
`mr=2` the same memory read-only, and, in builds with the self-test logic, `mr=0` the pattern
region (writes are checked against the pattern, reads return it).

## Transfers

| Command | Action |
|---------|--------|
| `post <op> <len> [count] [laddr] [qp]` | queue `count` work requests of `len` bytes, payload from the memory window at `laddr`, to consecutive addresses of the RLHM window; completions are queued |
| `wg <op> <len> <count> [gap] [qp]` / `wg stop` | self-test generator: line-rate WRs with a pattern payload into the RLHM window (`count` 0 = until stopped) |
| `cq` | print and remove the queued work completions and receive completions |
| `rnr <mask>` | QPs (bit mask) without receive buffers: SENDs to them are answered with RNR NAKs |
| `peek <addr> [n]`, `poke <addr> <val>` | read / write 32-bit words of the memory window (`peek` at most 64 words) |
| `fill [addr] [len]` | write the payload pattern (pattern(address), the seed of the `RLF` record) into the memory window from `addr` (rounded down to 64 bytes, default 0) for `len` bytes (default and limit: to the end of the window), so that a host reader (`rocelet_host --role reader`) can check what it READs |

`op` is `write`, `write_imm`, `send`, `send_imm`, or a number: bits [3:0] the opcode (0-3 as
listed), 0x10 the solicited event, 0x20 the HSB metadata flag.

## Self-test

The self-test needs the frames the FPGA sends to come back: a QSFP28 loopback plug in port 0
(`loop off`) or the GT near-end loopback (`loop pma`, or `t pma`; no plug needed). After
`link up` the suite checks that a frame it sends comes back (`loopback path`); on a link to a
NIC without a loopback it stops there (`SELFTEST FAIL 1/2`). The engine's
queue pairs are then connected to each other (QP q to QP q^1), and the firmware plays a remote
"host" QP (QPN 0x50) with hand-built frames sent through the engine's other-traffic port.

| Command | Action |
|---------|--------|
| `t` | the suite: link, loopback path, ARP/ICMP, firmware WRs through the memory window, READ (single and multi-packet, duplicate), ICRC (bad frames counted and dropped), CNP and 802.1Q tags in host frames, WRITE / SEND / WRITE-imm / SEND-imm streams, TX/RX fault injection (go-back-N recovery), access error |
| `t full` | the suite plus READ at PMTU 1024, throughput and latency |
| `t [full] pma`, `t [full] pcs` | the same in the GT near-end PMA (or PCS) loopback, then back to the previous loopback mode: no plug needed, a cable to a NIC may stay connected (on the ZCU106 and the VCK190 `pcs` selects the PMA loopback too) |
| `arp`, `wrq`, `read <len> <pmtu_log2>`, `icrc`, `cnpvlan`, `access` | single tests |
| `write <len> <pmtu_log2> <n> [op]`, `tput <len> <pmtu_log2> <ms> [nqp]`, `lat <n> <len> <pmtu_log2>` | streams, throughput, latency |
| `inj <rx> <1 drop\|2 corrupt> <class> <skip> <count> <nwr> <len> <pmtu_log2>` | fault injection run (class bits: 1 request, 2 ACK, 4 NAK, 8 READ response) |
| `soak <s> <len> <pmtu_log2> [ppm]` | long run, optionally with random drops |
| `setup [pmtu_log2]` | re-apply the loopback configuration |

Right after the link came up (`t pma`, `loop`, `link`, power-up) the engine holds its ACK
timeouts for `grace` (2 s); the tests wait for the hold to end before they start (one line
`(ACK timeouts held after the link came up (LINK_GRACE): waited <n> ms)`, at most the grace
plus 1 s), so the suite takes about 2 s longer after a relink (`t pma`: about 3 s in all, waited once after the switch
into the GT loopback; the switch back at the end is not waited for).

Each test prints `TEST <name>: PASS` or `FAIL` with its numbers; `t` ends with exactly one
line

```
SELFTEST PASS|FAIL <passed>/<run> loop=<external|pcs|pma> fec=<0|1> selftest_logic=<0|1>
```

for scripts. Builds without the self-test logic run the tests that need no generator (link,
loopback path, ARP/ICMP, firmware WRs, READ, ICRC, CNP / 802.1Q). With `vlan tx 1` the suite
runs with every engine frame tagged (VID 0).

## Debug

| Command | Action |
|---------|--------|
| `cap <mode> [op] [qpn] [tx] [other]`, `capd` | capture the next matching frame at the CMAC RX (or TX, or the engine's other-traffic output) and dump it as hex (`CAPF` ... `CAPE`, the format `roce_check.py --hex` reads); mode 0 any, 1 opcode, 2 destination QPN, 3 both |
| `injset <rx 0\|1> <0 off\|1 drop\|2 corrupt> [mode] [class] [skip] [count] [period] [ppm] [byte]` | arm the TX (engine to CMAC) or RX (CMAC to engine) fault injector for traffic with a host: mode 0 once (skip `skip` matching frames, then affect `count`), 1 periodic (every `period`-th), 2 random (`ppm`); class bits 1 request, 2 ACK, 4 NAK, 8 READ response, 16 other; `byte` = byte of the first beat to corrupt (untagged layout; 25 = IPv4 checksum: capture mode), 256 = byte 0 of the last beat. Examples in [](hardware_test.md) |
| `injoff` | switch the fault injectors off |
| `lp arm`, `lp` | latency probe: arm, then print the first WR of the generator, the first completion and the first four frames at the CMAC TX and RX (opcode, PSN, time), and the generator's WR-to-completion minimum / average / maximum. The average adds at most 203.4 us (65,535 clocks) per WR: when the maximum is longer it is printed as `avg >=` (a lower bound) with a note |
| `rnrt [min_us] [max_us]` | clamp of the RNR wait decoded from a received RNR NAK's timer code (default 10 us .. 655 ms) |
| `rcont [0\|1]` | answer a partial READ re-issue as a continuation of the original response (MIDDLE ... LAST, default, what the ConnectX-6 Dx expects) or with a new FIRST / ONLY response (IBTA style) |
| `rd <addr> [n]`, `wr <addr> <val>` | raw AXI access |

## Zynq UltraScale+ (Cortex-A53 bare-metal console)

The same sources (`Vitis/common/src`) build the KCU116 MicroBlaze console and a Cortex-A53
standalone console for the `zcu106` target (40G, omac_40g; and its 10G option with omac_10g);
the differences live in a thin platform layer (`plat.c`: console UART and time base) and in the
MAC backend (`mac.c`: CMAC or omac). **One ZCU106 console binary runs on both bitstreams**: it
reads the MAC type and the link speed from the always-on block's `CAPS`. The Linux daemon
`roceletd` runs the same console code ([](zynqmp_linux.md)), so every command below also works
as `rl <command>`.

| | MicroBlaze (`kcu116`) | Zynq UltraScale+ (`zcu106`) |
|---|---|---|
| CPU, console | MicroBlaze, AXI UART 16550 on the board's USB-UART | Cortex-A53 #0, PS UART0 (CP2108 port 0), 115200 8N1 |
| Boot | `rocelet_boot.bit` over JTAG or configuration flash | `BOOT.BIN` (FSBL + bitstream + console) from SD, or over JTAG from the Vitis workspace ([](getting_started.md#run-the-bare-metal-console)) |
| MAC, link | 100G CMAC, RS-FEC on by default | omac_40g 40GBASE-R4 on QSFP lanes 0-3 (10G option: omac_10g 10GBASE-R on QSFP lane 0); no FEC (`fec` has no effect) |
| GT reference clock | Si5328 322.265625 MHz | Si5328 156.25 MHz |
| Loopback | `loop pcs` / `loop pma` | `loop pma` (GTH near-end PMA; `pcs` selects PMA too) |
| MAC control and status | QSFP0 AXI GPIO | the always-on block ([](zynqmp_hw.md)): GT / MAC resets, link status, the measured MAC clock in `st`; at 40G also a lane line (block lock, marker lock, the partner's lane order, skew, BIP errors per lane, failed alignments, RX overflows) in `st` and after every link attempt |
| Engine settings | | `CTRL.PAUSE_RX_LEVEL` = 1 (omac reports a received PAUSE as a level), `PAUSE_QCLK` 512 (40G) / 2048 (10G), `TICK_DIV` 156 |
| PAUSE | off | **PAUSE TX on after boot** (802.3x frames from the engine's RX FIFO level: lossless into PS DDR; the host must honour PAUSE, the ConnectX-6 Dx does by default); PAUSE RX off; `pause tx 0` / `pause rx 1` change it |
| Extra memory window | | `mr=3`: a 1 MB buffer in PS DDR through the PS DDR window (R_Key `0x4003`, VA 0; under Linux the 256 MB reserved region); commands below |

PS DDR window commands (Zynq UltraScale+ only):

| Command | Action |
|---------|--------|
| `ddr` | the region (physical address, size, MR 3 R_Key), the DDR burst counters (writes, reads, outside the region) and the first eight words |
| `ddr fill [off] [n]` | write pattern(offset) into `n` bytes from offset `off`, for a host reader of `mr=3`, then clean the cache lines |
| `ddr check [off] [n]` | after a host WRITE into `mr=3`: invalidate the cache lines and compare `n` bytes from `off` with pattern(offset); prints the number of 64-byte beats that differ and the first one (`rl ddr check` exits with status 1 on a mismatch) |

`off` and `n` are rounded down to 64 bytes; `off` defaults to 0 and `n` to the rest of the
buffer, and both are clipped to it.

At power-up the console holds the GTH and the MAC in reset, programs the Si5328, releases the
GTH (prints "GTH ready: MAC clock 156250 kHz"), releases the MAC and waits for the link. The
host port must be forced to 40 Gb/s (10 Gb/s with the 10G option) with auto-negotiation and
FEC off (the console prints the `ethtool` lines for the speed of the bitstream). `wg` rates:
`gap = len x 8 / rate x 156.25e6` clocks at both speeds.

## Versal (Cortex-A72 bare-metal console)

The same sources build a Cortex-A72 standalone console for the `vck190_fmcp1` target (100G,
MRMAC), with the A72 case of the platform layer (`plat.c`: console UART, time base, the FMC VADJ
rail over the PS I2C, the device DNA from the eFUSE cache) and the MRMAC backend of `mac.c`.
`roceletd` runs the same code on the VCK190's Linux image ([](versal_linux.md)), so every
command below also works as `rl <command>`. The PS DDR window commands (`ddr`, `ddr fill`,
`ddr check`) are those of the Zynq UltraScale+ section.

| | Zynq UltraScale+ (`zcu106`) | Versal (`vck190_fmcp1`) |
|---|---|---|
| CPU, console | Cortex-A53 #0, PS UART0 (CP2108 port 0), 115200 8N1 | Cortex-A72 #0, PS UART0 (the FT4232H's second port), 115200 8N1 |
| Boot | `BOOT.BIN` (FSBL + bitstream + console) from SD, or over JTAG | `BOOT.BIN` (device image with the PLM + console) from SD, or over JTAG ([](getting_started.md#run-the-bare-metal-console-1)) |
| Before the MAC | | switches the FMC's VADJ rail on (1.5 V; prints `VADJ_FMC on`), as U-Boot does for Linux |
| MAC, link | omac_40g 40GBASE-R4 (10G option: omac_10g); no FEC | the hard MRMAC, 100GBASE-R4 with **RS-FEC on by default** (`fec 0` / `fec 1`, then relink; the host port must match) |
| GT reference clock | Si5328 156.25 MHz | Si5328 322.265625 MHz |
| Loopback | `loop pma` (`pcs` selects PMA too) | `loop pma` (GTY near-end PMA, applied with a GT reset; `pcs` selects PMA too, with a note: the GTY near-end PCS loopback does not hold the MRMAC link) |
| MAC control and status | the always-on block; at 40G a lane line | the always-on block for resets and link, the MRMAC's own registers for its configuration; `st` and every link attempt print the MRMAC line: PCS lanes 0-19 block lock, RS-FEC lane lock 0-3, alignment and lane mapping, the MRMAC's RX and FEC status, adapter RX overflows; the RS-FEC corrected / uncorrectable codeword counters |
| Clock in `st` | `MAC clock 156250 kHz` (the GT user clock, stops while the GT is in reset) | `engine clock 300000 kHz` (free-running) |
| Engine settings | `CTRL.PAUSE_RX_LEVEL` = 1, `PAUSE_QCLK` 512 / 2048, `TICK_DIV` 156 | `CTRL.PAUSE_RX_LEVEL` = 0 (the MRMAC reports a received PAUSE as a pulse with its quanta, as the CMAC), `PAUSE_QCLK` at its reset value for 100G, `TICK_DIV` 300 |
| PAUSE | **PAUSE TX on after boot**, PAUSE RX off | the same |
| Extra memory window | `mr=3`: a 1 MB buffer in PS DDR (Linux: the 256 MB reserved region) | the same; the buffer lies in the DDR4's low 2 GB, which the engine's DDR masters reach |
| HSB serial number | from the PL's device DNA (96 bits) | from the device DNA in the eFUSE cache (128 bits) |

At power-up the console holds the GT quad and the MRMAC in reset, switches VADJ on, programs
the Si5328, releases the GT (prints "GTY quad ready: engine clock 300000 kHz"), configures and
releases the MRMAC and waits for the link. It prints the host's `ethtool` lines: 100 Gb/s,
auto-negotiation off, FEC RS (`encoding off` on the host after `fec 0` here). `wg` rates:
`gap = len x 8 / rate x 300e6` clocks.
