# Getting started

## What you need

* A [KCU116](https://www.xilinx.com/kcu116) evaluation board
* An Opsero [2x QSFP28 FMC] (OP120) on the KCU116 HPC connector. The KCU116 routes the
  transceiver lanes of **QSFP28 port 0** only.
* For the built-in self-test: nothing else (the GT near-end loopback is used), or a QSFP28
  loopback plug in port 0.
* For RDMA with a host: a 100G QSFP28 cable (DAC or AOC) from port 0 to a RoCE v2 NIC in a
  Linux host, and the host helper `rocelet_host` from the rocelet repository.
* For the beamforming demo: that host with an NVIDIA GPU, Docker and NVIDIA's Holoscan Sensor
  Bridge container, and a monitor on the GPU ([](host_setup.md)).
* Vivado and Vitis 2025.2 on Linux or Windows, with the no-cost license of the CMAC IP.

## Get the sources

The rocelet engine is a git submodule:

```
git clone --recursive https://github.com/fpgadeveloper/qsfp28-fmc-rocelet.git
cd qsfp28-fmc-rocelet
```

In an existing clone without the submodule: `git submodule update --init --recursive`.

## Build

```
./build.sh all --target kcu116          # Linux, or git bash on Windows
build.bat all --target kcu116           # Windows command prompt
```

This creates the Vivado project (`Vivado/kcu116/`), runs synthesis, implementation and the
bitstream in one Vivado process, exports the hardware (`Vivado/kcu116/rocelet_wrapper.xsa`),
builds the MicroBlaze console application in Vitis, combines it with the bitstream
(`Vitis/boot/kcu116/rocelet_boot.bit`), writes the configuration-flash image
(`rocelet_boot.mcs`) and zips the result into `bootimages/`. Single stages: `xsa`,
`standalone`, `cfgmem`; `./build.sh status --target kcu116` shows what is built.

The build reports (utilisation, timing) are in `Vivado/kcu116/reports/`.

## Run

1. Fit the FMC on the HPC connector, connect the USB-UART (the second port of the CP2105,
   `Enhanced COM port`) and the USB-JTAG, and power the board.
2. Program `rocelet_boot.bit` over JTAG (Vivado Hardware Manager, or
   `program_ftdi`/`xsdb`), or write `rocelet_boot.mcs` to the configuration flash so that the
   board boots the design at power-on. Both are in `bootimages/` (zip) and, after a build, in
   `Vitis/boot/kcu116/`; the MicroBlaze application is embedded in the bitstream.
3. Open the console at **115200 baud, 8N1**. The banner reports the GT reference clock, the
   link state and the engine's build parameters, then the prompt `rl>` appears.

## Self-test

The built-in self-test needs no cable, no plug and no host: it runs in the GT near-end
loopback and puts the link back afterwards (a cable to a NIC may stay connected; the NIC sees
two short link drops):

```
rl> t pma
=== self-test: rocelet 0.2.2, 16 QPs, RING, READ depth 16, self-test logic built in, RS-FEC on, loopback GT near-end PMA
TEST link up: PASS
TEST loopback path (the FPGA's frames come back): PASS
...
SELFTEST PASS 19/19 loop=pma fec=1 selftest_logic=1
```

`t full pma` adds throughput and latency (about 96-98 Gb/s and 1.4 us WRITE-to-completion
through the engine's own responder). Every test prints a `TEST <name>: PASS|FAIL` line, and
the run ends with one `SELFTEST PASS|FAIL <passed>/<run>` line. With a QSFP28 loopback plug in
port 0, plain `t` works as well. In the GT loopback the frames are still transmitted on the
cable, addressed to the FPGA itself.

## Set up the host

Everything beyond the self-test needs a host with a 100G RoCE v2 NIC on QSFP28 port 0. For the
[beamforming demo](beam_demo.md) the host also needs an NVIDIA GPU, Docker with NVIDIA's
Holoscan Sensor Bridge container, and a monitor with an X session for the window.
[](host_setup.md) takes a bare PC through all of it, from the drivers and the 100G port to
starting the demo; the RDMA tests below need only the 100G port of that page and the host
helper `rocelet_host`.

## Connect a host

Point-to-point link, RS-FEC on at both ends (the FPGA default; `fec 0` turns it off), host
port forced to 100G with auto-negotiation off, host netdev MTU 4200 for a path MTU of 4096
(validated with an NVIDIA ConnectX-6 Dx; its RDMA device is `rocep179s0f0` below). The host helper `rocelet_host` (in the rocelet
submodule, `submodules/rocelet/host`) creates the host QP and exchanges one-line records with
the console:

```
rl> setup
rl> qp 0                                  # prints RLF / RLFM: give them to rocelet_host
$ rocelet_host run --dev rocep179s0f0 --role sink --op write_imm --len 65536 --count 100000 \
      --rq-depth 4000 --verify sample:16 --peer 'RLF qp=0 ...' --peer 'RLFM mr=0 ...'
                                          # prints RLH / RLHM: paste both into the console
rl> wg write_imm 65536 100000             # line-rate WRITE with immediate into host memory
```

[](hardware_test.md) has the host preparation, the transfer recipes in
both directions, notes for a ConnectX-6 Dx host, fault injection, frame capture, the Holoscan Sensor Bridge mode and the results
measured on the bench.

[2x QSFP28 FMC]: https://docs.opsero.com/op120/datasheet/overview/
