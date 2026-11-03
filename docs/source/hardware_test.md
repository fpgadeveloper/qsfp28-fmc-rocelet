# Testing with a host

This page takes the design from a programmed board to RDMA traffic with a Linux host, and
lists what was measured on the bench: a KCU116 with the 2x QSFP28 FMC, QSFP28 port 0 cabled
point to point with a 3 m passive QSFP28 DAC to an NVIDIA ConnectX-6 Dx (firmware 22.43.2566,
inbox `mlx5` driver and rdma-core 50, Ubuntu 24.04, Linux 6.8) in a Lenovo P520 test host,
forced 100G with RS-FEC on at both ends; the same link was also checked over a 3 m 100G QSFP28
active optical cable (AOC), see section 4.

## 1. The host

The host tools are part of the rocelet repository (the design's submodule):

```
sudo apt install build-essential libibverbs-dev rdma-core ibverbs-utils python3-scapy numactl
make -C submodules/rocelet/host            # rocelet_host
make -C submodules/rocelet/host test       # self-tests, no RDMA device needed
```

* `rocelet_host`: a libibverbs program (no rdma_cm). It creates the host QP, prints and reads
  the one-line parameter records, moves the QP to RTS and runs one role: `sink` (the FPGA
  WRITEs or SENDs into host memory, every message checked), `source` (the host WRITEs or SENDs
  into the FPGA), `reader` (the host READs FPGA memory, checked) or `idle`.
* `roce_check.py`: an independent referee for RoCE v2 frames (headers, ICRC computed twice,
  PSN / opcode sequences, payload pattern) from a pcap or from the FPGA's capture dump.

Prepare the port that faces the FPGA. The commands below are for a ConnectX-6 Dx; on the bench
host its netdev is `enp179s0f0np0` and its RDMA device `rocep179s0f0` (`ibv_devices` lists
yours). Every change is limited to that port and reversible. The full list of host rules, with
the reasons, is in the rocelet docs, [Host setup and host rules](https://rocelet.ethernetfmc.com/host-setup.html)
(`submodules/rocelet/docs/host-setup.md`).

| What | Command |
|------|---------|
| Forced 100G, auto-negotiation off (the FPGA's CMAC does not auto-negotiate; a ConnectX-6 Dx starts with auto-negotiation on and reports "No partner detected" until it is off) | `sudo ethtool -s enp179s0f0np0 speed 100000 duplex full autoneg off` (make it persistent in the network configuration, for example a systemd `.link` file) |
| RS-FEC, the same at both ends (the FPGA default) | nothing to do: the ConnectX-6's FEC setting `Auto` resolves to RS against the FPGA; check with `ethtool --show-fec enp179s0f0np0` (active FEC encoding RS) |
| MTU 4200 for a path MTU of 4096 | `sudo ip link set dev enp179s0f0np0 mtu 4200` |
| An address on the link (the FPGA is 192.168.20.2) | `sudo ip addr add 192.168.20.1/24 dev enp179s0f0np0` (or a netplan / NetworkManager profile) |
| Check | `ethtool enp179s0f0np0` (`Speed: 100000Mb/s`, `Auto-negotiation: off`), `rdma link show` (`ACTIVE`), `ibv_devinfo -d rocep179s0f0` (`active_mtu 4096`), `ping 192.168.20.2` |

On the ConnectX-6 Dx no static neighbour entry is needed (a 2 h 15 min soak ran with the kernel's
dynamic entry), link pause (802.3x) is on by default, and the RoCE v2 IPv4 GID was index 3 on
the bench (`rocelet_host` picks the GID by type, not by index).

Use an isolated point-to-point link: never put the 100G link on a LAN or behind a router.
Run `rocelet_host` on the NIC's NUMA node (`numactl --cpunodebind=<n> --membind=<n>`), and
watch the kernel log between tests (`journalctl -k | grep -i mlx5`).

## 2. The board

Program `Vitis/boot/kcu116/rocelet_boot.bit` over JTAG (the MicroBlaze application is in the
bitstream), or write `rocelet_boot.mcs` to the configuration flash. The console (115200 8N1)
reports the GT reference clock, the link and the engine:

```
Si5328 programmed: GT reference clock 322.265625 MHz
Port 0: link up, 100 Gb/s, RS-FEC on, loopback off (external) (2600 ms)
qsfp28-fmc-rocelet 0.4.0 | rocelet 0.2.2: 16 QPs, 16 MRs, RING 256 KB, 128 WRs, READ depth 16, ...
rl>
```

On the host, `ethtool <if>` reports `Speed: 100000Mb/s` and `rdma link show` the port
`ACTIVE` (the ConnectX-6 Dx's carrier came up 1.9-2.2 s after the JTAG programming ended).
Then the self-test, with the cable to the host still connected:

```
rl> t pma
...
SELFTEST PASS 19/19 loop=pma fec=1 selftest_logic=1
```

`t pma` runs the suite in the GT near-end loopback and restores the link (the host loses the
link meanwhile: the ConnectX-6 Dx's carrier was back about 5 s after each run). Plain `t`
needs a QSFP28 loopback plug; on a NIC link it stops after
`TEST loopback path ...: FAIL` (the partner does not return the FPGA's frames).

## 3. RDMA with the host

Each transfer is set up the same way: start `rocelet_host` with the FPGA's records, paste its
records into the console, start the traffic.

1. Print the FPGA's records (`setup` first resets every QP and counter):

   ```
   rl> setup
   rl> qp 0
   RLF qp=0 qpn=0x100 psn=0x10123 ip=192.168.20.2 mac=020a35726c01 mtu=4096 rd=16 seed=0x5EED1234
   RLFM mr=0 rkey=0x1000 va=0x10000000000 len=0x40000000 pat=0x10000000000 acc=rw
   RLFM mr=1 rkey=0x2001 va=0x0 len=0x40000 acc=rw
   RLFM mr=2 rkey=0x3002 va=0x0 len=0x40000 acc=r
   ```

   `mr=0` is the self-test pattern region (reads return a known pattern, writes are checked
   against it), `mr=1` the 256 KB memory window, `mr=2` the same window read-only.

2. Start the host side with the RLF line and the RLFM line of the window it uses. Examples:

   ```
   # FPGA -> host: 100,000 RDMA WRITE with immediate of 64 KB into host memory
   rocelet_host run --dev rocep179s0f0 --role sink --op write_imm --len 65536 --count 100000 \
       --rq-depth 4000 --verify sample:16 --peer 'RLF qp=0 ...' --peer 'RLFM mr=0 ...'
   # host -> FPGA: RDMA WRITE into the pattern region (checked by the FPGA), at full rate
   rocelet_host run --dev rocep179s0f0 --role source --op write --len 65536 --count 100000 \
       --rate max --depth 64 --fpga-mr 0 --peer 'RLF qp=0 ...' --peer 'RLFM mr=0 ...'
   # host READ of the FPGA memory window ('fill' on the console first)
   rocelet_host run --dev rocep179s0f0 --role reader --len 65536 --count 100000 --rate max \
       --fpga-mr 1 --peer 'RLF qp=0 ...' --peer 'RLFM mr=1 ...'
   ```

   It prints its own records (`RLH ...`, `RLHM ...`, also written to `--record-out FILE`).

3. Paste both lines into the console: `RLH` configures FPGA QP 0 towards the host QP, `RLHM`
   sets the host buffer the FPGA writes into.

4. Start the traffic: for a sink, from the FPGA (`wg write_imm 65536 100000` - the self-test
   generator, line rate, payload pattern the host verifies; a gap argument lowers the rate:
   `gap = len x 8 / rate x 322.27e6` clocks); for a source or reader, type `go` into
   `rocelet_host`'s control input.

5. Judge: `rocelet_host` ends with `result: PASS (exit 0)` (every message checked, no loss,
   duplicate, sequence or completion error); the console's `dump` shows the FPGA side
   (`req_wc` completions, `rx_nak_seq` / `req_rtx` recoveries, `wc_mism` / `sc_mism`
   data checker mismatches, which must stay absent).

The console commands are described in [](console.md). Useful extras for a host session:
`injset` (fault injection, see section 5), `lp arm` / `lp` (latency probe), `rnrt` (RNR wait
clamp), `pause` (802.3x), `cap` / `capd` (capture a frame for `roce_check.py --hex`).

## 4. Notes for an NVIDIA ConnectX-6 Dx host

The ConnectX-6 Dx is the release's validation partner (3 m DAC, RS-FEC, MTU 4200). The first
session ran rocelet v0.1 with the console's former 200 us ACK timeout; the READ, link-loss and
throughput items were re-checked with v0.2.0, v0.2.1 and the release v0.2.2 (section 7).

* **DAC or AOC, no setting changes.** All measurements on this page were taken over a 3 m passive
  QSFP28 DAC. With design 0.4.0 the DAC was swapped for a 3 m 100G QSFP28 AOC (module class "100G
  AOC, worst BER 5e-5", no separable connector): the link came up at both ends as it was (FPGA
  RS-FEC on; the ConnectX-6 at forced 100G, auto-negotiation off, FEC Auto resolving to RS, port
  type FIBRE) and a 60 s run of the beamforming demo's bit-exact check with the stream rate stepped
  through 64, 40, 20, 40, 64 and 80 Gb/s passed with 30,627 frames compared, 0 lost and 0
  uncorrected FEC blocks during the run. The swap itself cost one link drop and 21 uncorrected
  blocks while the cable was out, which the link-pause logic absorbed.

* **No host workarounds needed.** Multi-packet WRITE with immediate recovers from RNR (38,230
  RNR NAKs in one run, all recovered), VID-0 tagged frames are accepted, the host's
  `min_rnr_timer` is sent in its RNR NAKs (12: rocelet retried after 0.64 ms), link pause is on
  by default and no static neighbour entry is needed. The ConnectX-6 sends one ACK per AckReq
  (one per 16-packet 64 KB message).
* **READ continuation is required here too.** A ConnectX-6 re-issues a partial READ from the
  lost PSN (a lost MIDDLE response after about 5 us, a lost LAST after its adaptive timeout,
  21.6-96.6 ms in two runs) and rejects
  a FIRST ... LAST answer to it (work completion "bad response", host QP error): keep
  `rcont 1`, the default (restored by `setup`).
* **READs in flight.** With READ-response loss and `max_rd_atomic` 16 the ConnectX-6 re-issues
  READs within microseconds; rocelet v0.1 counted the re-issues against `READ_DEPTH` and NAKed
  a legitimate READ (invalid request, the host QP failed; `--max-rd 8` avoided it). rocelet
  v0.2 counts only new READs: give the host `READ_DEPTH` (16).
* **Wrong R_Key.** The ConnectX-6 answers an RDMA WRITE or WRITE with immediate to a wrong
  R_Key with a NAK (remote access error, AETH 0x62) about 1.3-1.8 ms after the request (well
  inside the default budget of 8 x 5 ms); the FPGA QP then reports requester error 0x62, the
  host a receive completion error (local access error) with its QP in error. With the v0.1
  console's 8 x 200 us budget the NAK came too late and the FPGA QP ended with retry exceeded
  (0xFF).
* **Counters.** mlx5 counts RoCE transport events in
  `/sys/class/infiniband/<dev>/ports/1/hw_counters/` (`out_of_sequence`, `packet_seq_err`,
  `implied_nak_seq_err`, `out_of_buffer`, `roce_adp_retrans`, ...); `rocelet_host` watches them.
  A frame with a bad ICRC is dropped without a counter (`rx_icrc_encapsulated` stayed 0): only
  the NAK-seq it sends for the next packet (`out_of_sequence`) shows it. The bench host's inbox
  stack listed no RDMA capture device (`tcpdump -D`): judge frames with the FPGA's capture
  (section 5).
* **GPU memory.** Into GPU memory (dma-buf, RTX PRO 4000 Blackwell) the rate was 81.4 Gb/s on
  the Lenovo P520 (Xeon Skylake-SP, PCIe Gen3): the limit is that host's NIC-to-GPU peer-write
  path (the NIC stalled on posted writes 72 % of the time, 0 retransmissions).
* **Message size and the retransmit ring.** A WRITE-with-immediate message as large as the
  256 KB retransmit ring (`RING_BYTES`) fills it, so only one message is in flight: 58.5 Gb/s
  with 256 KB messages, against 97.7 Gb/s with 128 KB messages. For line rate keep messages at
  or below `RING_BYTES` / 2 (or build a larger ring).
* **READ at PMTU 1024** reaches 81 Gb/s against the ConnectX-6 (about 9.9 M READ responses
  per second); at PMTU 2048 95.1 Gb/s.
* **Link drops.** `t pma` takes the link away from the ConnectX-6 for about 5 s (the
  link goes down twice; a ConnectX-6 needs 2.3-3 s per link-up). rocelet v0.2 holds its ACK timeouts while the link is down
  (CMAC not aligned, or a local / remote fault) and for `grace` (2 s) after it returns, so FPGA
  QPs with data in flight survive this and cable pulls of any length (v0.2.0 on the bench: a
  35.6 s DAC pull and forced drops of 5-60 s, 0 lost messages); the host QP's survival depends
  on its own `timeout` / `retry_cnt` ([Host setup and host rules](https://rocelet.ethernetfmc.com/host-setup.html),
  "Link flaps and cable pulls"). A host-side port reconfiguration (`ethtool -s <if> speed 50000` with
  `KEEP_ETH_LINK_UP`) is the hard case: the ConnectX-6 stops answering 15-25 ms before the FPGA
  loses alignment. With the v0.2.0 defaults (ACK timeout 1 ms x 8) the FPGA QP died at the start
  of such a drop; with `to 5000` it survived 5-60 s drops, hence the 5 ms default since console
  0.2.1. With the fault terms in `link_up` (since 0.2.1) the hold engages within one 5 ms
  timeout of such a drop (5 s and 30 s forced drops at the defaults: 1 timeout each, 0 lost),
  and the grace starts only at the ConnectX-6's own link-up (its carrier returned 4.4-5.6 s
  after a CMAC reset, the engine's link within 0.22 s of it). Console 0.2.1 used a 6 s grace
  (chosen when the grace started at alignment: the ConnectX-6 reports its link 2.4-2.9 s after
  the FPGA, 5.1-5.4 s after an FPGA-side relink), which then stalled every link loss ~6 s
  after the partner was back; grace 0, 1 s and 3 s all survived 5 s forced drops, hence 2 s
  since console 0.2.2 (margin for a partner whose port is up before it answers). `t pma` takes
  about 3 s with the 2 s grace (6.8 s with 6 s). Checked on hardware at the defaults: a real
  cable pull (14.9 s outage during a 40 Gb/s stream) resumed 1.9 s after the ConnectX-6
  carrier returned with 1 timeout and nothing lost; forced 5 s / 30 s drops resumed 1.8 / 2.0 s
  after the carrier; `t pma` 2.8 s.

## 5. Fault injection and frame capture

`injset <rx 0|1> <0 off|1 drop|2 corrupt> [mode 0 once|1 periodic|2 random] [class] [skip]
[count] [period] [ppm] [byte]` arms the TX (engine to CMAC) or RX (CMAC to engine) injector;
class bits: 1 request, 2 ACK, 4 NAK, 8 READ response, 16 other.

| Test | Console | What the host must see |
|------|---------|------------------------|
| drop 1 in 1000 FPGA requests | `injset 0 1 1 1 0 0 1000` | one NAK-seq and one go-back-N per gap, no loss |
| drop the last packet of a message (ACK timeout) | `injset 0 1 0 1 15 1` (64 KB WR, 16 packets) | the FPGA retransmits after its ACK timeout (`to`, 5 ms by default) |
| corrupt 1 in 1000 requests after the ICRC | `injset 0 2 1 1 0 0 1000 0 256` | the NIC drops each (ICRC check), NAK-seq, retransmission |
| drop 1 in 100 FPGA ACKs (host WRITE) | `injset 0 1 1 2 0 0 100` | later ACKs cover them, no host error |
| drop 1 in 1000 host requests at the FPGA | `injset 1 1 1 1 0 0 1000` | the FPGA NAKs each gap, the host goes back |
| drop one READ response | `injset 0 1 0 8 <skip> 1` | the host re-issues the READ, the READ completes |
| random drops, 10 ppm | `injset 0 1 2 1 0 0 1 10` | as the first row, over a long run |

**Frame capture.** A host NIC's RDMA engine consumes the RoCE frames it handles, and the
bench host could not record them with `tcpdump` (the ConnectX-6 Dx's inbox stack lists no RDMA
capture device). The FPGA captures frames itself, in both
directions: `cap 1 <opcode>` arms the capture, `capd` dumps the frame, `roce_check.py --hex
dump.txt` checks it; this was the referee on the ConnectX-6 Dx.


## 6. Holoscan Sensor Bridge mode

`hsb 0 [port]` turns FPGA QP 0 into a UC QP in the HSB packet format: every packet an RDMA
WRITE Only with its own RETH, the end of a frame a WRITE Only with Immediate carrying a
128-byte metadata record, immediate = {PSN[19:0], page[11:0]}, metadata bytes 4..7 = the PSN;
first PSN 0, UDP source port 12288, MigReq 0. A frame is a few WRITE work requests into the
page plus one 128-byte WRITE-with-immediate work request with op flag `0x20` (HSB metadata)
and the page number in the immediate (`post 0x21 128 ...` or `wg 0x21 128 <n>`; the
generator's immediates count the page up).

The format can be checked with any host: with a UDP destination port other than 4791
(`hsb 0 4792`, HSB's Linux-UDP receiver path) the frames reach the host's network stack and a
plain capture records them; on port 4791 the FPGA's own capture (section 5) is the referee. Both
passed `roce_check.py` and a check of the HSB conventions (per packet RETH, immediate,
metadata PSN, BTH and IP fields), and the HSB stream ran at 99.4 Gb/s on the wire (97.6 Gb/s
payload). A Holoscan host additionally needs a ConnectX NIC (UC), CUDA and the
holoscan-sensor-bridge software. For a stock HSB host, the design's
[Holoscan Sensor Bridge device mode](hsb.md) adds the HSB control plane (enumeration, register
protocol) on top of this format; its measurements against the ConnectX-6 Dx are on that page.

## 7. Measured on the bench: ConnectX-6 Dx (release)

KCU116 + OP120 port 0, 3 m passive QSFP28 DAC to an NVIDIA ConnectX-6 Dx (firmware 22.43.2566,
inbox mlx5 and rdma-core 50, Ubuntu 24.04, Linux 6.8) in a Lenovo P520 (Xeon Skylake-SP,
PCIe Gen3), forced 100G, RS-FEC, MTU 4200. The column "rocelet" gives the engine version of
each row: **v0.2.2** rows come from the release validation (2026-10-31, the release RTL); the
other rows from the ConnectX-6 Dx sessions of 2026-10-30 (v0.1, v0.2.0, v0.2.1) and were not
repeated on v0.2.2. The three rows repeated in every session (FPGA WRITE with immediate, host
WRITE, host READ at full rate) gave 98.01, 96.71-96.79 and 96.59-96.79 Gb/s from v0.1 to
v0.2.2. One QP, 64 KB messages unless stated, payload throughput as measured by the receiving
side. Rows marked **(P520)** depend on that host.

| Direction / operation | PMTU | Gb/s | Notes | rocelet |
|-----------------------|------|-----:|-------|---------|
| FPGA to host, WRITE with immediate | 4096 | 98.01 | line rate; 0 retransmissions | v0.2.2 |
| FPGA to host, WRITE with immediate | 2048 / 1024 | 96.12 / 92.56 | line rate | v0.1 |
| FPGA to host, SEND (16 KB) / SEND with immediate | 4096 | 96.29 / 97.27 | 113 / 97 RNR NAKs from the host, all recovered | v0.1 |
| FPGA to host, WRITE with immediate, 128 KB / 256 KB messages | 4096 | 97.69 / 58.50 | a 256 KB message fills the 256 KB retransmit ring: one message in flight (section 4) | v0.1 |
| FPGA to host, WRITE with immediate into GPU memory (dma-buf, RTX PRO 4000) | 4096 | 81.41 | **(P520)** the host's NIC-to-GPU path; every byte checked on the GPU | v0.2.0 |
| FPGA to host, WRITE with immediate, rate limiter `pace 50` | 4096 | 49.99 | the limiter | v0.2.2 |
| Host to FPGA, WRITE (64 in flight) | 4096 | 96.79 | line rate; the FPGA's RX FIFO peaked at 67 of 512 beats (v0.1 session) | v0.2.2 |
| Host to FPGA, WRITE with immediate / SEND with immediate (16 KB) | 4096 | 96.70 / 96.68 | line rate | v0.1 |
| Host READ of FPGA memory (`max_rd_atomic` 16) | 4096 | 96.59 | line rate | v0.2.2 |
| Host READ of FPGA memory | 2048 / 1024 | 95.10 / 81.15 | at PMTU 1024 about 9.9 M READ responses per second ; not investigated | v0.1 |
| Host READ, 200 ppm random READ-response loss, `max_rd_atomic` 16 | 4096 | 92.56-94.22 | continuation answers plus the duplicate READs the ConnectX-6 re-issues; every READ checked | v0.2.0 |

Latency (FPGA timestamps at the CMAC interface, 322 MHz clock):

| Measurement | Result | rocelet |
|-------------|--------|---------|
| FPGA WR to first data byte on the wire | 121 ns (64 B), 512 ns (4 KB) | v0.1 |
| ConnectX-6 ACK to FPGA completion | 127-133 ns | v0.1 |
| FPGA WRITE with immediate to completion (ACK from the ConnectX-6), 1000 unloaded WRs | 1.16 us min / 1.17 us avg (64 B); 2.02 / 2.03 us (4 KB) | v0.1 |
| FPGA WRITE with immediate to completion at full rate, 64 KB, average | 5.08 us into host memory; 9.35 us into GPU memory **(P520)** | v0.2.0 |
| Host READ request to the first READ response (FPGA responder) | 230 ns (64 B), 425 ns (4 KB) | v0.1 |

Reliability, against the ConnectX-6 Dx:

| Test | Result | rocelet |
|------|--------|---------|
| last packet of a 64 KB WRITE with immediate dropped | recovered by the ACK timeout: 1 timeout, 1 retransmission, WR to completion 5.0066 ms (the 5 ms default), data checked | v0.2.2 |
| 1/1000 FPGA requests dropped (WRITE with immediate 64 KB, 10 / 50 Gb/s) | 3,064 / 15,387 NAK-seq go-back-N recoveries (the ConnectX-6's `out_of_sequence` counted exactly the injected drops), no loss, data checked | v0.1 |
| 1/1000 requests corrupted after the ICRC (3 / 50 Gb/s) | 919 / 15,387 recoveries: the ConnectX-6 drops each without a counter (`rx_icrc_encapsulated` 0) and NAKs the next packet, no loss | v0.1 |
| 1/100 FPGA ACKs dropped (host WRITE, 10 / 50 Gb/s) | 1,906 / 11,004 dropped ACKs covered by later ACKs, no ConnectX-6 retransmission | v0.1 |
| 1/1000 host requests dropped at the FPGA (10 / 50 Gb/s / full rate) | one NAK-seq per gap (3,064 / 15,289 / 24,129 = the ConnectX-6's `packet_seq_err`), no duplicates; 42.3 Gb/s at full rate with the drops | v0.1 |
| one READ response dropped (FIRST, MIDDLE or LAST) | the ConnectX-6 re-issues from the lost PSN: FIRST after 2.8 us, MIDDLE after 4.85-4.90 us, LAST after its adaptive timeout (96.6 ms, 21.6 ms in a later run); rocelet answers with a continuation, READ data checked. With `rcont 0` the host fails the READ ("bad response") | v0.1, v0.2.0 |
| random READ-response loss, 10-200 ppm, `max_rd_atomic` 16 / 12 / 10 | 13.0 M READs with 15.4 k lost responses: every READ completed and checked, no NAK, host QP alive (v0.1 NAKed a new READ here, fixed in v0.2.0) | v0.2.0 |
| RNR (slow host receiver) | rocelet waits the decoded RNR time: the host's `min_rnr_timer` 12 = 0.64 ms; 300,000 multi-packet WRITEs with immediate into a 64-entry host receive queue: 38,230 RNR NAKs, all recovered, no loss | v0.1 |
| wrong R_Key (4 KB WRITE with immediate) | NAK remote access error (AETH 0x62) 1.83 ms after the first send, FPGA QP requester error 0x62, host QP in error | v0.2.0 |
| VID-0 priority-tagged frames from the FPGA (`vlan tx 1 3 0`) | accepted on an untagged QP: WRITE with immediate at 10 Gb/s and READ responses at 96.61 Gb/s | v0.1 |
| 802.3x PAUSE, FPGA to ConnectX-6 (`pause tx 1 xoff 32 xon 16`; host WRITE at full rate; no host change) | 24,000,193 PAUSE frames sent, all counted by the ConnectX-6 (`rx_pause_ctrl_phy`); 53.92 Gb/s, no drop | v0.1 |
| soak: FPGA to host WRITE with immediate, 50 Gb/s, 10 ppm random request drops, dynamic neighbour entry | 2 h 15 min, 772,472,700 messages (50.62 TB) at 49.99 Gb/s; 123,509 random drops recovered in 61,791 go-back-N episodes and 3 ACK timeouts; no loss, duplicate or data error, QP in service at the end | v0.1 |
| soak: FPGA to host WRITE with immediate at full rate | 10 min, 112,000,000 messages (7.34 TB) at 98.01 Gb/s; 0 retransmissions, 0 timeouts, no host error | v0.2.1 |

Link loss at the release defaults (ACK timeout 5 ms x 8, grace 2 s), FPGA WRITE with immediate
64 KB at 40 Gb/s into host memory:

| Event | Outage at the ConnectX-6 | Stream resumed after its carrier | FPGA | Host | rocelet |
|-------|-------------------------:|---------------------------------:|------|------|---------|
| real DAC pull (OP120 end, about 12 s unplugged) | 14.90 s | 1.9 s | 1 timeout, 1 retransmission | 8,853,647 messages, 0 lost / duplicate / corrupt, both QPs alive | v0.2.2 |
| forced drop, 5 s (`ethtool -s <if> speed 50000`, then back to 100G) | 8.06 s | 1.8 s | 1 timeout | 2,000,000 messages clean | v0.2.2 |
| forced drop, 30 s | 32.65 s | 2.0 s | 1 timeout | 3,000,000 messages clean | v0.2.2 |
| console `link` (CMAC reset), no traffic | 5.4-6.0 s | - | engine link within one poll of the carrier, ACK timeouts held for 1.6-2.2 s after it | - | v0.2.2 |
| `t pma` / `t full pma` with the cable connected | - | - | PASS 19/19 in 2.8 s / 23/23 in 5.1 s | link back by itself | v0.2.2 |

rocelet v0.2.0 (1 ms ACK timeout, 3 s grace from alignment) also survived a 35.6 s DAC pull
with 1 timeout and nothing lost. Link: RS-FEC uncorrectable blocks 0 on a quiet link at both
ends; the FPGA corrected about one RS-FEC codeword per second from the ConnectX-6 (566 in the
10 min soak), the ConnectX-6 none. The host's kernel log stayed clean apart from link up /
down lines.
