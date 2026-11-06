# Hardware overview

The design comes in three families, named after the build flow's family token (data.json
`bdscript`, which selects `Vivado/src/bd/bd_<bdscript>.tcl`). Both are built around the same
`rocelet_sys` ([](description.md)); each family page describes its system generically and ends
with a **Board specifics** subsection per board.

{% set family = {"microblaze": "MicroBlaze", "zynqmp": "Zynq UltraScale+", "versal": "Versal"} %}
{% set mac_name = {"cmac": "CMAC (hard, 100G)", "omac_40g": "omac_40g (open source)", "omac_10g": "omac_10g (open source)", "mrmac": "MRMAC (hard, 100G)"} %}
{% set mac_lanes = {"cmac": 4, "omac_40g": 4, "omac_10g": 1, "mrmac": 4} %}
| Board | Target | Family | MAC | Lanes | GT channels (QSFP lane 0-3) or quad | Link | Flows | Docs |
|---|---|---|---|---|---|---|---|---|
{% for design in data.designs %}{% if design.publish %}| [{{ design.board }}]({{ design.link }}) | `{{ design.label }}` | {{ family[design.bdscript] }} | {{ mac_name[design.mac] }}{% if design.mac_options %}{% for m in design.mac_options %}{% if m != design.mac %}; option: {{ mac_name[m] }}{% endif %}{% endfor %}{% endif %} | {{ mac_lanes[design.mac] }}{% if design.mac_options %}{% for m in design.mac_options %}{% if m != design.mac %} ({{ mac_lanes[m] }} with {{ m }}){% endif %}{% endfor %}{% endif %}, QSFP28 port {{ design.port }} | {% if design.gt_channels %}{{ design.gt_channels | join(", ") }}{% else %}{{ design.gt_quad }}{% endif %}{% if design.cmac_core %} ({{ design.cmac_core }}){% endif %}{% if design.mrmac_core %} ({{ design.mrmac_core }}){% endif %} | {{ design.linkspeed }} Gb/s{% if design.fec == "rs" %}, RS-FEC{% else %}, no FEC{% endif %} | {{ "bare metal" if design.baremetal else "" }}{{ ", Linux (Yocto)" if design.yocto else "" }} | [{{ family[design.bdscript] }}]({{ design.bdscript }}_hw.md){% if design.yocto %}, [Linux]({{ design.bdscript }}_linux.md){% endif %} |
{% endif %}{% endfor %}

The table is generated from `config/data.json` when the documentation is built.

* **[MicroBlaze design](microblaze_hw.md)**: a MicroBlaze runs the console on the UART; the 100G
  CMAC hard block sits behind the generic MAC boundary through a small adapter. For FPGA boards
  without a processing system.
* **[Zynq UltraScale+ design](zynqmp_hw.md)** and **[its Linux stack](zynqmp_linux.md)**: the PS
  runs Linux (daemon, command line, web UI, a network interface on the port) or a bare-metal
  console; an always-on block with a clock guard, a PS DDR window and a netdev DMA channel; the
  open-source omac MACs (or, on an RFSoC, the CMAC behind the same boundary).
* **[Versal design](versal_hw.md)** and **[its Linux stack](versal_linux.md)**: the same system
  shell and software as the Zynq UltraScale+ design, with the Versal hard blocks: the MRMAC
  (100G, RS-FEC) behind a small adapter, the engine on a free-running clock of its own, and the
  PS DDR window over one NoC port per direction; Linux or a bare-metal console on the
  Cortex-A72.
* **[Porting](porting.md)**: adding a board means one data.json entry, constraints, a
  `BOARD_<NAME>` firmware block and, for Linux, a BSP directory; the Board specifics subsections
  of the family pages are the template.

```{toctree}
:maxdepth: 2

microblaze_hw
zynqmp_hw
zynqmp_linux
versal_hw
versal_linux
porting
```
