# qsfp28-fmc-rocelet

An open-source, lightweight **RoCE v2** (RDMA over Converged Ethernet) engine for AMD FPGAs,
with a 100G reference design for the [Opsero Quad SFP28 / 2x QSFP28 FMC](https://docs.opsero.com)
cards on AMD development boards. First target: KCU116 + 2x QSFP28 FMC (OP120).

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

On the KCU116 the engine uses roughly one third of ERNIC's logic and a few percent of its
block RAM, and sustains line rate for messages of 2 KB and larger.

## Status

**Research phase.** The RoCE v2 subset was chosen by a measured study (feature decomposition,
prior art, ERNIC resource baseline, building-block costs, whole-design builds and bench tests).
The `research` branch holds the prototype RTL, the host-side helper and test tooling, and the
KCU116 test system. The reference design in the standard Opsero layout (`config/data.json`,
`Vivado/`, `Vitis/`, `PetaLinux/`, `build.py`) is being built on the `dev` branch, with the engine pulled in as the `rocelet` submodule.

## License

MIT.
