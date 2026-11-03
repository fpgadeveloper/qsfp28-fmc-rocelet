# qsfp28-fmc-rocelet

An open-source, lightweight **RoCE v2** (RDMA over Converged Ethernet) engine for AMD FPGAs,
with a 100G reference design for the [Opsero Quad SFP28 / 2x QSFP28 FMC](https://docs.opsero.com)
cards on AMD development boards. First target: KCU116 + 2x QSFP28 FMC (OP120).

> **Status: version 0.4.0** (2026-11-03), rocelet v0.2.2. The kcu116 target is validated on
> hardware against an NVIDIA ConnectX-6 Dx (100G DAC, RS-FEC): RDMA at line rate in both
> directions, loss recovery, link loss including a real cable pull, the built-in self-test, the
> Holoscan Sensor Bridge device mode with NVIDIA's HSB 3.0.0 host software (RoCE into GPU memory
> up to 80 Gb/s on the test host), and the beamforming demo (new in 0.4.0). See the
> [revision history](https://qsfp28-rocelet.ethernetfmc.com/revision_history.html) in the docs
> for the measurements and the known limitations.

Important links:

* The user guide for this reference design is hosted here: [rocelet RoCE v2 reference design docs](https://qsfp28-rocelet.ethernetfmc.com "rocelet RoCE v2 reference design docs")
* The engine's own documentation (architecture, interface, register map, integration, host rules): [rocelet docs](https://rocelet.ethernetfmc.com "rocelet docs")
* Datasheet of the [2x QSFP28 FMC]
* The engine's source code: [rocelet on GitHub](https://github.com/fpgadeveloper/rocelet "rocelet on GitHub")
* To report a bug: [Report an issue](https://github.com/fpgadeveloper/qsfp28-fmc-rocelet/issues "Report an issue").
* For technical support: [Contact Opsero](https://opsero.com/contact-us "Contact Opsero").
* To purchase the mezzanine card: [2x QSFP28 FMC order page](https://opsero.com/product/2x-qsfp28-fmc "2x QSFP28 FMC order page").

## Beamforming demo

![Beamforming demo: preset 2 (emitter + jammer) with the MVDR beamformer, the jammer nulled](docs/source/images/beam-p2-mvdr.jpg)

The KCU116 plays the digitiser of an 8 x 8 phased-array receiver: an array generator in the
FPGA streams the samples of all 64 antenna elements over rocelet (Holoscan Sensor Bridge data
plane) into GPU memory, at up to 80 Gb/s on the test host. A CuPy beamformer on the GPU draws a
"radio camera" picture of the sky (conventional and MVDR), the steered beam's pattern and its
spectrum in a Holoviz window. Dragging the emitter or the jammer writes the new scene back to
the FPGA over the HSB register protocol; the picture follows within a frame or two (mouse to
data 1.5-2.7 ms, every frame checked bit-exact at 10-80 Gb/s). The keys - / + change the stream
rate while it runs.

```
rl> hsb on                                                                      # on the board's console
RL_WIN=1 sw/beam/run.sh python3 rocelet_beam_app.py --source roce --preset 2 --rate 64 --ibv-name <rdma-dev>   # on the GPU host
```

Details, presets and measurements: [Beamforming demo](https://qsfp28-rocelet.ethernetfmc.com/beam_demo.html);
the GPU host from a bare PC to the demo: [Host setup](https://qsfp28-rocelet.ethernetfmc.com/host_setup.html).

## Why

AMD's ERNIC IP implements a full RoCE v2 stack, but it is large (about 42k LUTs plus the
interconnect, buffers and queues it needs on a Kintex UltraScale+) and it is paid, licensed IP.
Most FPGA RoCE applications stream data between an FPGA and a host or GPU over a point-to-point
link and need only a small part of the protocol. [rocelet](https://github.com/fpgadeveloper/rocelet), the open-source RoCE v2 engine this design is built around, implements that part:

- RC (reliable connection) transport as **requester**: RDMA WRITE, WRITE with immediate, SEND,
  SEND with immediate, multi-packet messages, go-back-N retransmission with an on-chip
  retransmit ring (zero loss, interoperable with standard NICs).
- RC **responder**: RDMA WRITE and SEND from the host into FPGA memory, RDMA READ of FPGA
  memory by the host, full duplicate and NAK handling.
- IPv4/UDP framing, TX and RX ICRC, PMTU 256-4096, 802.3x pause honoured and generated,
  out-of-band QP setup (a host helper based on libibverbs exchanges QPN, PSN, rkey and buffer
  addresses; no in-band connection manager).
- Written in SystemVerilog, 512-bit AXI-Stream at the CMAC user clock (100 GbE).

## Description

The reference design puts the rocelet engine between the Kintex UltraScale+ integrated 100G
Ethernet MAC (CMAC, with RS-FEC) on QSFP28 port 0 of the 2x QSFP28 FMC and an on-chip memory
window (256 KB of UltraRAM), with a MicroBlaze that sets up the link and the queue pairs:

![Block diagram](docs/source/images/rocelet-block.png)

* **rocelet** (git submodule `submodules/rocelet`, MIT): RoCE v2 engine, MAC glue (frame FIFOs,
  802.3x PAUSE, 802.1Q priority tags), ARP/ICMP responder, AXI4 memory master.
* **Memory window**: the target of host RDMA WRITEs, the source of host RDMA READs and of the
  payload of the FPGA's own WRITEs/SENDs; also mapped into the MicroBlaze address space.
* **Console** (UART, 115200 baud): link status, QP setup through the same one-line parameter
  records as the host helper (`RLH`/`RLHM` in, `RLF`/`RLFM` out), transfers, counters, fault
  injection, and a built-in **self-test** (`t pma`: no plug or cable needed) that ends with
  one machine-readable `SELFTEST PASS|FAIL <passed>/<run> ...` line.
* **Self-test logic** (optional, `selftest` in `config/data.json`): line-rate work-request
  generator with a verifiable payload pattern, data checkers, TX/RX fault injectors and a
  latency probe, outside the engine. With a QSFP28 loopback plug the engine's requester talks to
  its own responder.
* **Holoscan Sensor Bridge device mode** (console `hsb on`): the board enumerates as an HSB
  device (Opsero UUID) and is configured by NVIDIA's HSB 3.0.0 host software; an RTL frame
  producer sends frames of the IQ16 test signal (four tones, a chirp and noise), a counter
  pattern or the 8 x 8 antenna array of the beamforming demo (`sw/beam/`), with an optional
  producer watchdog and a link pause. Host software in `sw/hsb/`: an
  example script, a Holoscan application (C++ or Python checker, Holoviz spectrogram demo) and
  the Opsero `hololink_module`; details in the docs, "Holoscan Sensor Bridge device mode".

### Hardware

* [KCU116] Kintex UltraScale+ evaluation board
* Opsero [2x QSFP28 FMC] (OP120) on the KCU116 HPC connector (port 0)
* A QSFP28 100G cable (DAC or AOC) to a RoCE v2 NIC (validated with an NVIDIA ConnectX-6 Dx), or a QSFP28 loopback plug for the self-test
* For the beamforming demo: a Linux host with that NIC, an NVIDIA GPU and a monitor (see [Host setup](docs/source/host_setup.md))

## Requirements

This project is designed for version 2025.2 of the AMD tools (Vivado and Vitis).

* Vivado 2025.2
* Vitis 2025.2
* [2x QSFP28 FMC]
* One of the target platforms listed below
* The no-cost license of the [UltraScale+ Integrated 100G Ethernet (CMAC)] IP (add it to your
  account on the [AMD licensing site](https://www.xilinx.com/getlicense))

Clone with the submodule:

```
git clone --recursive https://github.com/fpgadeveloper/qsfp28-fmc-rocelet.git
```

## Target designs

<!-- updater start -->
### FPGA designs

| Target board          | Target design      | Ports       | FEC         | FMC Slot(s) | Standalone<br> console | Built-in<br> self-test | Vivado<br> Edition |
|-----------------------|--------------------|-------------|-------------|-------------|-------|-------|-------|
| [KCU116]              | `kcu116`           | 1x 100G     | RS-FEC (CL91) | HPC         | :white_check_mark: | :white_check_mark: | Standard :free: |

[KCU116]: https://www.xilinx.com/kcu116
<!-- updater end -->

## Build

```
./build.sh all --target kcu116          # Linux / git bash
build.bat all --target kcu116           # Windows command prompt
```

`all` builds the Vivado project and the bitstream (`xsa`), the MicroBlaze application
(`standalone`), the configuration-flash image (`cfgmem`) and gathers the boot files in
`bootimages/`. Single stages: `xsa`, `standalone`, `cfgmem`; state of the build: `status`.

System simulation of the design's RTL with the engine (xsim, QSFP28 loopback model):

```
Vivado/src/hdl/tb/run_xsim.sh all
```

## Run

**1. Board.** Program `rocelet_boot.bit` (in `bootimages/`, or `Vitis/boot/kcu116/` after a
build) over JTAG, open the console (115200 8N1) and run the self-test, which needs no host (a
QSFP28 loopback plug, or the cable to the host):

```
rl> t pma
...
SELFTEST PASS 19/19 loop=pma fec=1 selftest_logic=1
```

**2. Host.** Prepare the GPU host once, following [Host setup](docs/source/host_setup.md): the
NVIDIA driver, Docker with the NVIDIA Container Toolkit and the Holoscan Sensor Bridge 3.0.0
container, the 100G port (forced 100G, auto-negotiation off, RS-FEC, MTU 4200, 192.168.20.1/24,
point to point to the board), and a display session for the window. Copy or clone this
repository onto the host; `sw/beam/run.sh` runs the demo software in the container.

**3. Demo.** On the console switch the Holoscan Sensor Bridge device mode on (after every
power-up), then start the application on the host:

```
rl> hsb on
RL_WIN=1 sw/beam/run.sh python3 rocelet_beam_app.py --source roce --preset 2 --rate 64 --ibv-name <rdma-dev>
```

The window opens on the host's monitor and the tablet page at `http://<gpu-host>:8090/`; Esc
or Ctrl-C stops the stream. Keys, presets, the page and the measurements are in
[Beamforming demo](docs/source/beam_demo.md); the other HSB applications (IQ16 and counter
frames, a waterfall) in [Holoscan Sensor Bridge device mode](docs/source/hsb.md).

**4. RDMA tests.** For RDMA transfers driven from the console with the engine's host tool
(`make -C submodules/rocelet/host`), follow [Testing with a host](docs/source/hardware_test.md).

Measured against an NVIDIA ConnectX-6 Dx (3 m DAC, RS-FEC, MTU 4200; one QP, 64 KB
messages, PMTU 4096):

| Direction | Result |
|-----------|-------:|
| FPGA to host, RDMA WRITE with immediate | 98.01 Gb/s |
| Host to FPGA, RDMA WRITE | 96.79 Gb/s |
| Host READ of FPGA memory | 96.59 Gb/s |
| FPGA WRITE-with-immediate to completion, unloaded (64 B / 4 KB) | 1.17 us / 2.03 us |
| Host READ request to first response (FPGA responder, 4 KB) | 425 ns |
| Real cable pull with a 40 Gb/s stream in flight (14.9 s outage) | resumed 1.9 s after the NIC's link returned, 0 lost |

The two latency rows come from the first ConnectX-6 Dx session (rocelet v0.1; the completion
times are averages), the others from the release validation (rocelet v0.2.2). See
[Testing with a host](docs/source/hardware_test.md) for all results.

## Contribute

We strongly encourage community contribution to these projects. Please make a pull request if you
would like to share your work:
* if you've spotted and fixed any issues
* if you've added designs for other target platforms
* if you've added host software for other NICs, GPUs or frameworks

Thank you to everyone who supports us!

## About us

This project was developed by [Opsero Inc.](https://opsero.com "Opsero Inc."),
a tight-knit team of FPGA experts delivering FPGA products and design services to start-ups and tech companies.
Follow our blog, [FPGA Developer](https://www.fpgadeveloper.com "FPGA Developer"), for news, tutorials and
updates on the awesome projects we work on.

## License

The sources of this repository are released under the MIT license, see
[LICENSE](LICENSE). The rocelet engine (`submodules/rocelet`) is MIT as well.

[2x QSFP28 FMC]: https://docs.opsero.com/op120/datasheet/overview/
[UltraScale+ Integrated 100G Ethernet (CMAC)]: https://www.amd.com/en/products/adaptive-socs-and-fpgas/intellectual-property/cmac_usplus.html
