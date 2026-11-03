#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""util_split.py <util_hier.rpt> [...] - split a Vivado hierarchical utilisation
report of the qsfp28-fmc-rocelet design (Vivado/<target>/reports/util_hier.rpt,
written by scripts/xsa.tcl) into reporting categories:

  rocelet    the rocelet IP (rocelet_top: engine, MAC glue = RX/TX frame FIFOs,
             classifier, arbiter, PAUSE and VLAN handling, ARP/ICMP responder,
             AXI memory master, register file and counters) = the RoCE function
  memory     the on-chip memory window (URAM) with its AXI slave and firmware port
  fw_access  firmware work-request queue + payload reader, completion queues,
             raw frames / capture, the AXI-Lite decoder, system registers, CMAC
             control and counters
  selftest   self-test logic: WR generator, data checkers, TX/RX fault injectors,
             latency probe
  hsb_iq16   HSB producer's IQ16 source (iq16_gen in gen_clk + async FIFO)
  hsb_beam   HSB producer's beam array generator (rsys_beam_src in gen_clk + async FIFO)
  hsb_other  HSB frame producer, control-plane receive FIFO, time, device DNA
  cmac       cmac_usplus (GTs, CMAC hard block wrapper)
  system     MicroBlaze, local memory, debug, interconnect, UART, timer, I2C, GPIO,
             clocking, resets
Prints a markdown table per report (LUT, LUTRAM, FF, BRAM36-eq, URAM, DSP).
"""
import re
import sys

COLS = ["lut", "logic", "lutram", "srl", "ff", "ramb36", "ramb18", "uram", "dsp"]


def parse(path):
    rows = []
    stack = []
    for line in open(path):
        if not line.startswith("|") or "Instance" in line:
            continue
        cells = [c for c in line.rstrip("\n").split("|")[1:-1]]
        if len(cells) < 11:
            continue
        name = cells[0]
        indent = len(name) - len(name.lstrip(" "))
        name = name.strip()
        try:
            vals = [float(c.strip()) for c in cells[2:11]]
        except ValueError:
            continue
        level = (indent - 1) // 2
        stack = stack[:level]
        path_ = "/".join(stack + [name])
        stack.append(name)
        rows.append((path_, level, dict(zip(COLS, vals))))
    return rows


def find(rows, suffix):
    for p, lvl, v in rows:
        if p.endswith(suffix):
            return v
    return None


def add(a, b):
    return {k: a.get(k, 0) + b.get(k, 0) for k in COLS}


def sub(a, b):
    return {k: a.get(k, 0) - b.get(k, 0) for k in COLS}


def split(rows):
    zero = {k: 0 for k in COLS}
    top = rows[0][2]
    base = "rocelet_sys_0/inst/u_sys/"

    def grp(names):
        t = dict(zero)
        for n in names:
            v = find(rows, base + n)
            if v:
                t = add(t, v)
        return t

    cats = {}
    cats["rocelet"] = grp(["u_rl"])
    cats["memory"] = grp(["u_mem"])
    cats["selftest"] = grp(["g_wg.u_wg", "g_chk.u_wchk", "g_chk.u_schk", "g_inj.u_inj", "g_inj.u_txskid",
                            "g_rinj.u_rinj", "g_lat.u_lat"])
    cats["hsb_iq16"] = grp(["u_iqs"])
    cats["hsb_beam"] = grp(["u_bms"])
    cats["hsb_other"] = grp(["u_hp", "u_crx", "u_ptime", "u_dna"])
    sysi = find(rows, "rocelet_sys_0") or zero
    cats["fw_access"] = sub(sysi, add(add(add(cats["rocelet"], cats["memory"]), cats["selftest"]),
                                      add(add(cats["hsb_iq16"], cats["hsb_beam"]), cats["hsb_other"])))
    cats["cmac"] = find(rows, "/cmac") or zero
    cats["system"] = sub(top, add(sysi, cats["cmac"]))
    cats["TOTAL"] = top
    return cats


def bram(v):
    return v["ramb36"] + v["ramb18"] / 2


def main():
    for path in sys.argv[1:]:
        cats = split(parse(path))
        tot = cats["TOTAL"]
        print(f"\n{path}\n")
        print("| Group | LUT | % of design | LUTRAM | FF | BRAM36 | URAM | DSP |")
        print("|---|---:|---:|---:|---:|---:|---:|---:|")
        for k, v in cats.items():
            pct = 100.0 * v["lut"] / tot["lut"] if tot["lut"] else 0
            print(f"| {k} | {v['lut']:,.0f} | {pct:.1f} % | {v['lutram']:,.0f} | {v['ff']:,.0f} | "
                  f"{bram(v):g} | {v['uram']:g} | {v['dsp']:g} |")


if __name__ == "__main__":
    main()
