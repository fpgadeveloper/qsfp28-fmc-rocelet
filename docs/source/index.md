# rocelet RoCE v2 reference design for the 2x QSFP28 FMC

An open-source, lightweight **RoCE v2** (RDMA over Converged Ethernet) engine,
[rocelet](https://github.com/fpgadeveloper/rocelet), on the Opsero [2x QSFP28 FMC] (OP120) at
100 Gb/s. The engine has its own documentation (architecture, interface, register map,
integration and host rules) at [rocelet.ethernetfmc.com](https://rocelet.ethernetfmc.com);
this guide covers the reference design built around it.

```{important}
**Status: version 0.4.0** (2026-11-03), rocelet v0.2.2. The kcu116 target is validated on
hardware against an NVIDIA ConnectX-6 Dx: line-rate RDMA in both directions, loss recovery,
link loss including a real cable pull and the built-in self-test (see [](hardware_test.md)),
and the [Holoscan Sensor Bridge device mode](hsb.md) with NVIDIA's HSB 3.0.0 host software.
New in 0.4.0: the [beamforming demo](beam_demo.md), in which an 8 x 8 antenna array generated
in the FPGA streams into GPU memory, the GPU beamforms it live on a monitor, and moving a
source in the window re-steers the FPGA within a frame or two. Measurements and known
limitations: [](revision_history.md).
```

![The test bench: KCU116 with the 2x QSFP28 FMC, a 100G AOC to the ConnectX-6 Dx in the GPU host, the beamforming demo on the host's monitor](images/setup-bench.jpg)

The design connects a RoCE v2 capable host NIC (validated with an NVIDIA ConnectX-6 Dx) point-to-point to QSFP28 port 0 of the FMC. The host and the FPGA exchange RDMA
traffic in both directions:

* **FPGA to host:** RDMA WRITE (with or without immediate) and SEND into host memory, reliable
  (RC, go-back-N retransmission from an on-chip ring) or unreliable (UC, including the
  Holoscan Sensor Bridge packet format).
* **Host to FPGA:** RDMA WRITE and SEND into the FPGA's memory window, and RDMA READ of it.

The connection is set up out of band: the host helper `rocelet_host` (libibverbs) and the FPGA
console exchange one-line parameter records (QPN, PSN, addresses, keys); there is no RDMA
connection manager on the FPGA.

## Supported boards

{% for group in data.groups %}
{% set designs_in_group = [] %}
{% for design in data.designs %}{% if design.group == group.label and design.publish %}{% set _ = designs_in_group.append(design.label) %}{% endif %}{% endfor %}
{% if designs_in_group | length > 0 %}
### {{ group.name }} boards

| Carrier board | Target design | FMC slot | QSFP28 ports | FEC | Self-test logic |
|---------------|---------------|----------|--------------|-----|-----------------|
{% for design in data.designs %}{% if design.group == group.label and design.publish %}| [{{ design.board }}]({{ design.link }}) | `{{ design.label }}` | {{ design.connector }} | {{ design.ports }}x {{ design.linkspeed }}G | {{ "RS-FEC (CL91)" if design.fec == "rs" else "none" }} | {{ "yes" if design.selftest else "no" }} |
{% endif %}{% endfor %}
{% endif %}
{% endfor %}

## Licensing

The design and the rocelet engine are released under the MIT license. The 100G Ethernet MAC is
AMD's UltraScale+ Integrated 100G Ethernet (CMAC) hard block, whose IP license is free of
charge (add it to your account on the [AMD licensing site](https://www.xilinx.com/getlicense)).

## Contents

```{toctree}
:maxdepth: 2
:caption: User Guide

getting_started
host_setup
hardware_test
description
console
hsb
beam_demo
resources
revision_history
```

[2x QSFP28 FMC]: https://docs.opsero.com/op120/datasheet/overview/
