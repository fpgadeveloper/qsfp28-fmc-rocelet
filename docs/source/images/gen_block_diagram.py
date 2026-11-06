#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""
Generate the diagrams for the qsfp28-fmc-rocelet docs.

    rocelet-block.png        the MicroBlaze design (kcu116): MicroBlaze system,
                             clocking, rocelet_sys (engine, memory window,
                             work-request sources, control-plane FIFO, raw TX /
                             capture, system registers, self-test logic, HSB
                             device side with its source multiplexer), the CMAC
                             behind cmac_adapt and its GTY quad, the 2x QSFP28
                             FMC (OP120)
                             (Vivado/src/bd/bd_microblaze.tcl,
                             Vivado/src/hdl/rocelet_sys.sv,
                             Vivado/src/constraints/kcu116.xdc)
    rocelet-zynqmp-block.png the Zynq UltraScale+ design (zcu106; board-agnostic
                             except the labelled ZCU106 example values): the PS
                             and its ports (HPM0_LPD control, HP0 + HPC0 PS DDR
                             writes, HP1 + HP3 reads, HP2 netdev DMA), the
                             always-on block with the clock guard, rocelet_sys
                             (engine, URAM window, decoder + two-port DDR
                             interleave, netdev DMA channel, self-test logic,
                             HSB producer with the s_axis_src multiplexer), the
                             AXI DMA, the swappable MAC block (omac_40g / omac_10g)
                             and its GTH channels, the AXI IIC controllers and
                             the 2x QSFP28 FMC (OP120)
                             (Vivado/src/bd/bd_zynqmp.tcl,
                             Vivado/src/hdl/rocelet_sys.sv, rsys_aon.sv,
                             Vivado/src/constraints/zcu106.xdc)
    hsb-device-flow.png      Holoscan Sensor Bridge device mode, end to end:
                             enumeration, register protocol, data plane on QP 13,
                             frame producer, ConnectX NIC, GPU memory
                             (Vitis/common/src/hsb.c, rocelet_sys.sv, docs/source/hsb.md)
    hsb-app-pipeline.png     the operator graph of the Holoscan application
                             sw/hsb/rocelet_hsb_app.py (RoceletHsbApp.compose())
    beam-demo-flow.png       the beamforming demo: array generator, HSB data
                             plane, ConnectX NIC, GPU memory, CuPy beamformer,
                             Holoviz window and tablet page, and the control
                             path back over the HSB register protocol
                             (sw/beam/, docs/source/beam_demo.md)

Conventions shared with the other Opsero reference-design diagrams
(fpga-drive-nvme-offload/docs/source/images/gen_block_diagram.py and
2x-qsfp28-fmc): same palette, helpers and fonts, left-to-right layout with the
processor and its memory on the left and the FMC card on the right;
grey = processor and memory, lavender = soft logic, cream = hard blocks (CMAC,
GT; in the host diagrams: NVIDIA / AMD components used as they are),
blue-grey = the FMC card and other hardware outside the FPGA, peach = clocking;
blue arrows = register / control access, green arrows = memory traffic
(AXI4, RDMA WRITE into memory), pale green arrows = AXI4-Stream (and frame
messages between Holoscan operators), orange = clocks, thin grey = sideband.
Dashed boxes = optional logic (the self-test logic, SELFTEST = 1).

The PNGs are written next to this script (i.e. into docs/source/images/).

Usage (from anywhere):
    python3 docs/source/images/gen_block_diagram.py
"""

import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon, FancyArrowPatch, Circle
from matplotlib.lines import Line2D

# ---- palette (shared with the other Opsero reference-design block diagrams) --
C_PS_FILL      = "#D9D9D9"; C_PS_EDGE      = "#7F7F7F"   # processor / DDR column
C_FAB_FILL     = "#F2F2F2"; C_FAB_EDGE     = "#BFBFBF"   # FPGA fabric container
C_MAC_FILL     = "#E8E8F2"; C_MAC_EDGE     = "#8C8CC0"   # soft logic (lavender)
C_GT_FILL      = "#F3EFE2"; C_GT_EDGE      = "#BFB585"   # hard blocks: PCIe, GT (cream)
C_FMC_FILL     = "#DCE6F2"; C_FMC_EDGE     = "#9DB7D4"   # external FMC (blue-grey)
C_SLOT_FILL    = "#FFFFFF"                                # M.2 slots (white on FMC)
C_CLK_FILL     = "#FDE9D9"; C_CLK_EDGE     = "#E0B090"   # clocking (peach)
C_CTRL_FILL    = "#ECECEC"; C_CTRL_EDGE    = "#BFBFBF"   # notes / control caption
C_AXARR_FILL   = "#EDF3D4"; C_AXARR_EDGE   = "#A6B85A"   # DMA arrows (pale green)
C_LINKARR_FILL = "#DAE8F5"; C_LINKARR_EDGE = "#6F9FCF"   # host access + link arrows
C_REFCLK_LINE  = "#C8823C"                                # clocks (orange)
C_THIN         = "#8C8C8C"                                # sideband / interrupts
C_MUTED        = "#6E6E6E"
TXT = "#1A1A1A"
# recorder additions (same family of tints)
C_USER_FILL    = "#E2F0E4"; C_USER_EDGE    = "#7FB08A"   # user insertion points
C_DATA_LINE    = "#6E8F1E"                                # zero-copy data path (dark green)
C_CTRL_LINE    = "#4A7DB5"                                # control path (dark blue)
C_WARN         = "#A0522D"                                # contract annotations


def box(ax, x, y, w, h, fc, ec, label, fs=10, lw=1.2, weight="normal",
        txtcolor=None, ls="-", z=2):
    ax.add_patch(plt.Rectangle((x, y), w, h, fc=fc, ec=ec, lw=lw, ls=ls,
                               zorder=z))
    if label:
        ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
                fontsize=fs, color=txtcolor or TXT, weight=weight,
                zorder=z + 1, linespacing=1.25)


def titled_box(ax, x, y, w, h, fc, ec, title, body, title_fs=9.5, body_fs=7.6,
               lw=1.2, txtcolor=None, title_dy=2.4, ls="-", z=2):
    """A box() with a bold title line at the top and a smaller body below it."""
    box(ax, x, y, w, h, fc, ec, "", lw=lw, ls=ls, z=z)
    cx = x + w / 2
    ax.text(cx, y + h - title_dy, title, ha="center", va="center",
            fontsize=title_fs, weight="bold", color=txtcolor or TXT, zorder=z + 1,
            linespacing=1.15)
    ax.text(cx, y + (h - title_dy * 1.9) / 2, body, ha="center", va="center",
            fontsize=body_fs, color=txtcolor or TXT, zorder=z + 1, linespacing=1.3)


def harrow(ax, x0, x1, yc, label, fc, ec, double=False, bh=1.1, hh=2.0,
           hl=1.6, fs=7.4, lw=1.0, lab_dy=2.9, lab_color=None, z=2):
    """Horizontal block arrow from x0 to x1 (head at x1; both ends if double)."""
    if double:
        lo, hi = min(x0, x1), max(x0, x1)
        pts = [(lo, yc), (lo + hl, yc + hh), (lo + hl, yc + bh),
               (hi - hl, yc + bh), (hi - hl, yc + hh), (hi, yc),
               (hi - hl, yc - hh), (hi - hl, yc - bh),
               (lo + hl, yc - bh), (lo + hl, yc - hh)]
    else:
        s = 1.0 if x1 >= x0 else -1.0
        neck = x1 - s * hl
        pts = [(x0, yc + bh), (neck, yc + bh), (neck, yc + hh),
               (x1, yc), (neck, yc - hh), (neck, yc - bh), (x0, yc - bh)]
    ax.add_patch(Polygon(pts, closed=True, fc=fc, ec=ec, lw=lw, zorder=z))
    if label:
        ax.text((x0 + x1) / 2, yc + lab_dy, label, ha="center", va="center",
                fontsize=fs, color=lab_color or TXT, zorder=z + 1, linespacing=1.15)


def vblock(ax, xc, y0, y1, fc, ec, bw=1.0, hw=1.9, hl=1.5, lw=1.0, double=True,
           z=2):
    """Vertical block arrow from y0 to y1 (head at y1; both ends if double)."""
    if double:
        lo, hi = min(y0, y1), max(y0, y1)
        pts = [(xc, lo), (xc + hw, lo + hl), (xc + bw, lo + hl),
               (xc + bw, hi - hl), (xc + hw, hi - hl), (xc, hi),
               (xc - hw, hi - hl), (xc - bw, hi - hl),
               (xc - bw, lo + hl), (xc - hw, lo + hl)]
    else:
        s = 1.0 if y1 >= y0 else -1.0
        neck = y1 - s * hl
        pts = [(xc + bw, y0), (xc + bw, neck), (xc + hw, neck), (xc, y1),
               (xc - hw, neck), (xc - bw, neck), (xc - bw, y0)]
    ax.add_patch(Polygon(pts, closed=True, fc=fc, ec=ec, lw=lw, zorder=z))


def route(ax, pts, color, lw=1.3, ls="-", z=3, ms=9):
    """Thin elbow arrow through the points in pts (head at the last point)."""
    xs, ys = zip(*pts[:-1])
    ax.add_line(Line2D(list(xs) + [pts[-2][0]], list(ys) + [pts[-2][1]],
                       color=color, lw=lw, ls=ls, zorder=z,
                       solid_capstyle="butt", solid_joinstyle="miter"))
    ax.add_patch(FancyArrowPatch(pts[-2], pts[-1], arrowstyle="-|>",
                                 mutation_scale=ms, lw=lw, color=color,
                                 zorder=z, shrinkA=0, shrinkB=0))


def line(ax, pts, color, lw=1.1, ls="-", z=3):
    xs, ys = zip(*pts)
    ax.add_line(Line2D(xs, ys, color=color, lw=lw, ls=ls, zorder=z,
                       solid_capstyle="butt"))


def clk_tag(ax, x, y, text, fs=7.2, ha="center"):
    """An orange clock-domain label."""
    ax.text(x, y, text, ha=ha, va="center", fontsize=fs, color=C_REFCLK_LINE,
            weight="bold", zorder=6, linespacing=1.15)


def marker(ax, x, y, n, color=C_CTRL_LINE, r=1.25, fs=7.5):
    """A numbered circle (step marker)."""
    ax.add_patch(Circle((x, y), r, fc="white", ec=color, lw=1.3, zorder=7))
    ax.text(x, y, str(n), ha="center", va="center", fontsize=fs, weight="bold",
            color=color, zorder=8)


def new_fig(w=17.0, h=10.6, xmax=170, ymax=106):
    fig, ax = plt.subplots(figsize=(w, h), dpi=120)
    ax.set_xlim(0, xmax)
    ax.set_ylim(0, ymax)
    ax.axis("off")
    return fig, ax


def save(fig, name):
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    fig.savefig(out, bbox_inches="tight", pad_inches=0.15, facecolor="white")
    plt.close(fig)
    print("wrote", out)



def legend(ax, x, y, items, fs=7.2, dy=3.6):
    """Arrow-colour key: items = [(fill, edge, text), ...]; a None fill draws a line."""
    for i, (fc, ec, text) in enumerate(items):
        yy = y - i * dy
        if fc is None:
            line(ax, [(x, yy), (x + 6.0, yy)], ec, lw=1.6)
        else:
            harrow(ax, x, x + 6.0, yy, "", fc, ec, bh=0.8, hh=1.5, hl=1.2)
        ax.text(x + 7.5, yy, text, ha="left", va="center", fontsize=fs, color=TXT)


def dashed_group(ax, x, y, w, h, label, ec=C_MAC_EDGE, fs=7.4, lab_dx=1.2,
                 lab_dy=-1.6, z=1.5, fc="none"):
    """A dashed frame around a group of blocks, its label at the top left."""
    ax.add_patch(plt.Rectangle((x, y), w, h, fc=fc, ec=ec, lw=1.1, ls=(0, (4, 2)),
                               zorder=z))
    if label:
        ax.text(x + lab_dx, y + h + lab_dy, label, ha="left", va="center",
                fontsize=fs, weight="bold", color=ec, zorder=z + 1)


# -----------------------------------------------------------------------------
# 1. Whole design (kcu116).
#
# Cells, clocks and connections from Vivado/src/bd/bd_microblaze.tcl; the
# rocelet_sys instances and their connections from Vivado/src/hdl/rocelet_sys.sv;
# FMC pins and the GT reference clock from Vivado/src/constraints/kcu116.xdc;
# addresses from docs/source/description.md ("Address map").
# -----------------------------------------------------------------------------
def draw_block():
    fig, ax = new_fig(22.0, 15.2, 182, 126)

    # ---- processor column -----------------------------------------------------
    ps_x0, ps_w = 2.0, 18.0
    ps_r = ps_x0 + ps_w
    titled_box(ax, ps_x0, 97.0, ps_w, 13.0, C_PS_FILL, C_PS_EDGE, "Local memory",
               "128 KB block RAM\n(LMB), firmware\ncode and data",
               title_fs=9.4, body_fs=7.2, title_dy=2.6, lw=1.3)
    vblock(ax, ps_x0 + ps_w / 2, 93.0, 97.0, C_AXARR_FILL, C_AXARR_EDGE,
           bw=0.9, hw=1.7, hl=1.2)
    box(ax, ps_x0, 15.0, ps_w, 78.0, C_PS_FILL, C_PS_EDGE, "", lw=1.3)
    ax.text(ps_x0 + ps_w / 2, 87.5, "MicroBlaze", ha="center", va="center",
            fontsize=11.0, weight="bold", color=TXT)
    ax.text(ps_x0 + ps_w / 2, 52.0,
            "microblaze_0\nclk_out1  100 MHz\n\nbare-metal firmware\n(Vitis/common/src)\n\n"
            "console on the UART\nCMAC + QSFP28 bring-up\nQP set-up, transfers\n"
            "self-test\n\nHSB device mode:\nenumeration, register\nprotocol, data plane\n\n"
            "no interrupt controller:\nthe engine's irq is a\nGPIO input (polled)",
            ha="center", va="center", fontsize=7.2, color=TXT, linespacing=1.35)

    # ---- fabric container -----------------------------------------------------
    fab_x0, fab_x1 = 23.0, 150.0
    ax.add_patch(plt.Rectangle((fab_x0, 13.0), fab_x1 - fab_x0, 101.0,
                               fc=C_FAB_FILL, ec=C_FAB_EDGE, lw=1.3, zorder=1))
    ax.text((fab_x0 + fab_x1) / 2, 115.2, "Kintex UltraScale+ FPGA  (XCKU5P, KCU116)",
            ha="center", va="bottom", fontsize=11.5, weight="bold", color=TXT)

    # ---- AXI SmartConnect + peripherals (sys clock 100 MHz) -------------------
    smc_x, smc_w, smc_y0, smc_y1 = 25.0, 4.5, 35.0, 99.0
    box(ax, smc_x, smc_y0, smc_w, smc_y1 - smc_y0, C_MAC_FILL, C_MAC_EDGE, "", lw=1.2)
    ax.text(smc_x + smc_w / 2, (smc_y0 + smc_y1) / 2,
            "microblaze_0_axi_periph  (SmartConnect: aclk 100 MHz, aclk1 322.27 MHz)",
            ha="center", va="center", fontsize=7.2, weight="bold", color=TXT,
            rotation=90)
    harrow(ax, ps_r, smc_x, 90.0, "", C_LINKARR_FILL, C_LINKARR_EDGE,
           bh=0.8, hh=1.5, hl=1.1)
    ax.text(ps_r - 0.6, 91.6, "M_AXI_DP", ha="right", va="center", fontsize=7.0,
            color=C_CTRL_LINE, zorder=4)
    per_x, per_w = 32.0, 17.0
    periph = [
        (76.0, 8.0, "axi_uart16550_0", "console, 115200\nto the board USB-UART"),
        (66.5, 8.0, "axi_timer_0", "free-running 100 MHz\n(HSB intervals)"),
        (57.0, 8.0, "axi_iic_clk", "Si5328 I2C\n(FMC LA02)"),
        (47.5, 8.0, "axi_iic_qsfp0", "QSFP28 module I2C\n(FMC LA03)"),
        (35.0, 11.0, "axi_gpio_qsfp0", "out: ModSelL, ResetL,\nLPMode, CMAC reset\n"
                                        "in: ModPrsL, IntL, CMAC\nresets, RX aligned, irq"),
    ]
    for (y0, h, t, b) in periph:
        titled_box(ax, per_x, y0, per_w, h, C_MAC_FILL, C_MAC_EDGE, t, b,
                   title_fs=7.6, body_fs=7.0, title_dy=1.8)
        harrow(ax, smc_x + smc_w, per_x, y0 + h / 2, "", C_LINKARR_FILL,
               C_LINKARR_EDGE, bh=0.6, hh=1.2, hl=0.8)

    # ---- clocking ---------------------------------------------------------------
    titled_box(ax, 25.0, 15.5, 24.0, 15.0, C_CLK_FILL, C_CLK_EDGE, "clk_wiz_0",
               "in: 300 MHz board clock\nclk_out1 100 MHz: MicroBlaze,\n"
               "peripherals, CMAC init / DRP\nclk_out2 200 MHz: gen_clk",
               title_fs=8.4, body_fs=7.0, title_dy=2.0)

    # ---- rocelet_sys --------------------------------------------------------------
    rs_x0, rs_x1, rs_y0, rs_y1 = 52.0, 122.0, 19.0, 106.0
    box(ax, rs_x0, rs_y0, rs_x1 - rs_x0, rs_y1 - rs_y0, "#FAFAFD", C_MAC_EDGE, "", lw=1.4)
    ax.text(rs_x0 + 1.5, rs_y1 - 2.6, "rocelet_sys_0  (Vivado/src/hdl/rocelet_sys.sv)",
            ha="left", va="center", fontsize=9.6, weight="bold", color=TXT)
    clk_tag(ax, rs_x1 - 1.5, rs_y1 - 2.6, "clk: CMAC gt_txusrclk2, 322.27 MHz", ha="right")

    # AXI-Lite from the SmartConnect (M05) into the decoder
    top_y0, top_h = 86.0, 12.0
    harrow(ax, smc_x + smc_w, rs_x0, 92.0, "", C_LINKARR_FILL, C_LINKARR_EDGE,
           bh=0.8, hh=1.5, hl=1.1)
    ax.text(40.5, 95.6, "M05_AXI → S_AXIL\n0x4480_0000, 512 KB", ha="center",
            va="center", fontsize=7.0, color=C_CTRL_LINE, linespacing=1.15)
    titled_box(ax, 54.0, top_y0, 11.0, top_h, C_CTRL_FILL, C_CTRL_EDGE, "u_split",
               "AXI-Lite decoder\n+0x00000 engine\n+0x10000 u_regs\n+0x40000 u_mem",
               title_fs=8.0, body_fs=7.0, title_dy=1.8, z=3)
    titled_box(ax, 66.5, top_y0, 11.5, top_h, C_CTRL_FILL, C_CTRL_EDGE, "u_regs",
               "system registers:\nCMAC control,\ncounters, queues,\nproducer, sources",
               title_fs=8.0, body_fs=7.0, title_dy=1.8, z=3)
    harrow(ax, 65.0, 66.5, 92.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, bh=0.5, hh=1.0,
           hl=0.6, z=4)
    titled_box(ax, 79.0, top_y0, 11.5, top_h, C_MAC_FILL, C_MAC_EDGE, "u_crx",
               "control-plane\nRX FIFO: UDP\n8192 / 12268\n16 x 2 KB",
               title_fs=8.0, body_fs=7.0, title_dy=1.8, z=3)
    titled_box(ax, 91.5, top_y0, 11.5, top_h, C_MAC_FILL, C_MAC_EDGE, "u_raw",
               "raw TX frames\n(2 KB), capture\nbuffer at the\nCMAC",
               title_fs=8.0, body_fs=7.0, title_dy=1.8, z=3)
    titled_box(ax, 104.5, top_y0, 16.0, top_h, C_MAC_FILL, C_MAC_EDGE,
               "self-test checkers",
               "u_wchk: memory writes\nu_schk: SEND payload\nu_lat: latency probe\n(taps, no data path)",
               title_fs=8.0, body_fs=7.0, title_dy=1.8, ls=(0, (4, 2)), z=3)

    # memory window, WR queue, engine
    lft_x, lft_w = 54.0, 16.0
    eng_x0, eng_x1, eng_y0, eng_y1 = 79.0, 103.0, 54.0, 82.0
    titled_box(ax, lft_x, 66.0, lft_w, 16.0, C_MAC_FILL, C_MAC_EDGE, "u_mem",
               "memory window\n256 KB UltraRAM\n\nhost WRITE target,\nhost READ source,\nfirmware WR payload",
               title_fs=8.4, body_fs=7.0, title_dy=1.9, z=3)
    titled_box(ax, lft_x, 46.0, lft_w, 15.0, C_MAC_FILL, C_MAC_EDGE, "u_wrq",
               "firmware WR queue,\npayload reader,\nwork / receive\ncompletion queues",
               title_fs=8.4, body_fs=7.0, title_dy=1.9, z=3)
    titled_box(ax, eng_x0, eng_y0, eng_x1 - eng_x0, eng_y1 - eng_y0, C_MAC_FILL,
               C_MAC_EDGE, "u_rl  rocelet_top",
               "RoCE v2 engine (submodules/rocelet)\n\nRC requester + responder,\nUC-HSB (Holoscan frames)\n"
               "MAC glue: frame FIFOs,\n802.3x PAUSE, 802.1Q VID 0,\nclassifier, ARP / ICMP\n"
               "register file, counters\n\n16 QPs, 128 WRs in flight,\n256 KB URAM retransmit ring",
               title_fs=9.4, body_fs=7.0, title_dy=2.2, lw=2.0, z=3)
    # engine AXI4 master <-> memory window (green)
    harrow(ax, lft_x + lft_w, eng_x0, 74.0, "", C_AXARR_FILL, C_AXARR_EDGE, double=True,
           bh=0.9, hh=1.7, hl=1.1)
    ax.text((lft_x + lft_w + eng_x0) / 2, 77.0, "AXI4\n512 bit", ha="center", va="center",
            fontsize=7.0, color=C_DATA_LINE, linespacing=1.1)
    # payload reader: u_mem -> u_wrq (green)
    vblock(ax, 59.0, 66.0, 61.0, C_AXARR_FILL, C_AXARR_EDGE, bw=0.8, hw=1.5, hl=1.0,
           double=False)
    ax.text(60.8, 63.5, "payload", ha="left", va="center", fontsize=7.0,
            color=C_DATA_LINE)
    # u_split -> u_mem, u_split -> engine registers (blue)
    route(ax, [(57.0, top_y0), (57.0, 82.0)], C_CTRL_LINE, lw=1.2, ms=7)
    route(ax, [(62.0, top_y0), (62.0, 84.0), (81.0, 84.0), (81.0, eng_y1)], C_CTRL_LINE,
          lw=1.2, ms=7)
    # other-traffic port <-> u_crx / u_raw (pale green)
    vblock(ax, 85.0, eng_y1, top_y0, C_USER_FILL, C_USER_EDGE, bw=0.8, hw=1.5, hl=1.0,
           double=False, z=4)
    vblock(ax, 97.5, top_y0, eng_y1, C_USER_FILL, C_USER_EDGE, bw=0.8, hw=1.5, hl=1.0,
           double=False, z=4)
    ax.text(91.25, 84.0, "other traffic", ha="center", va="center", fontsize=7.0,
            color=TXT)

    # WR mux + work-request sources
    mux_y0, mux_y1 = 47.0, 51.5
    box(ax, eng_x0, mux_y0, eng_x1 - eng_x0, mux_y1 - mux_y0, C_CTRL_FILL, C_CTRL_EDGE,
        "WR mux: u_wg > u_hp > u_wrq", fs=7.2, z=3)
    vblock(ax, 91.0, mux_y1, eng_y0, C_USER_FILL, C_USER_EDGE, bw=0.8, hw=1.5, hl=0.9,
           double=False)
    harrow(ax, lft_x + lft_w, eng_x0, 49.25, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5,
           hl=1.0)
    ax.text((lft_x + lft_w + eng_x0) / 2, 52.4, "WRs", ha="center", va="center",
            fontsize=7.0, color=TXT)
    harrow(ax, eng_x0, lft_x + lft_w, 58.0, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5,
           hl=1.0)
    ax.text((lft_x + lft_w + eng_x0) / 2, 61.2, "completions", ha="center",
            va="center", fontsize=7.0, color=TXT, linespacing=1.05)

    # RX / TX path and the fault injectors (self-test, dashed)
    inj_x, inj_w = 106.0, 14.0
    titled_box(ax, inj_x, 70.0, inj_w, 10.0, C_MAC_FILL, C_MAC_EDGE, "u_rinj",
               "RX fault injector", title_fs=8.0, body_fs=7.0, title_dy=1.8,
               ls=(0, (4, 2)), z=3)
    titled_box(ax, inj_x, 54.0, inj_w, 10.0, C_MAC_FILL, C_MAC_EDGE, "u_inj + skid",
               "TX fault injector,\nregister slice", title_fs=8.0, body_fs=7.0,
               title_dy=1.8, ls=(0, (4, 2)), z=3)
    rx_y, tx_y = 75.0, 59.0
    cm_x0, cm_x1 = 127.0, 138.0
    harrow(ax, cm_x0, inj_x + inj_w, rx_y, "", C_USER_FILL, C_USER_EDGE, bh=1.0, hh=1.9,
           hl=1.2)
    harrow(ax, inj_x, eng_x1, rx_y, "", C_USER_FILL, C_USER_EDGE, bh=1.0, hh=1.9, hl=1.0)
    harrow(ax, eng_x1, inj_x, tx_y, "", C_USER_FILL, C_USER_EDGE, bh=1.0, hh=1.9, hl=1.0)
    harrow(ax, inj_x + inj_w, cm_x0, tx_y, "", C_USER_FILL, C_USER_EDGE, bh=1.0, hh=1.9,
           hl=1.2)
    ax.text((inj_x + inj_w + cm_x0) / 2, rx_y + 3.0, "RX", ha="center", va="center",
            fontsize=7.2, weight="bold", color=TXT)
    ax.text((inj_x + inj_w + cm_x0) / 2, tx_y + 3.0, "TX", ha="center", va="center",
            fontsize=7.2, weight="bold", color=TXT)

    # self-test WR generator (dashed)
    titled_box(ax, 106.0, 30.0, 14.0, 11.0, C_MAC_FILL, C_MAC_EDGE, "u_wg",
               "WR generator,\npattern payload", title_fs=8.0, body_fs=7.0, title_dy=1.8,
               ls=(0, (4, 2)), z=3)
    route(ax, [(113.0, 41.0), (113.0, 49.25), (eng_x1, 49.25)], C_USER_EDGE, lw=1.6, ms=9)

    # HSB device side
    dashed_group(ax, 54.0, 21.0, 49.5, 23.5, "Holoscan Sensor Bridge device side",
                 ec=C_MAC_EDGE)
    box(ax, 56.0, 36.0, 17.0, 5.0, C_MAC_FILL, C_MAC_EDGE, "u_iqs  IQ16 generator", fs=7.2,
        z=3)
    box(ax, 56.0, 30.0, 17.0, 5.0, C_MAC_FILL, C_MAC_EDGE, "u_bms  8 x 8 array gen.", fs=7.2,
        z=3)
    titled_box(ax, 79.0, 30.0, 22.5, 11.0, C_MAC_FILL, C_MAC_EDGE, "u_hp  frame producer",
               "data WRITEs + metadata\nWRITE-imm, page ring, pacing", title_fs=8.0,
               body_fs=7.0, title_dy=1.8, z=3)
    box(ax, 56.0, 22.5, 17.0, 5.0, C_MAC_FILL, C_MAC_EDGE, "u_dna  device DNA", fs=7.2, z=3)
    box(ax, 79.0, 22.5, 22.5, 5.0, C_MAC_FILL, C_MAC_EDGE, "u_ptime  seconds / ns", fs=7.2,
        z=3)
    # u_smux: the producer's source multiplexer (s_axis_src: IQ16, counter, beam; input 3
    # reserved for a design source, tied off on this target)
    box(ax, 74.4, 30.0, 2.4, 11.0, C_CTRL_FILL, C_CTRL_EDGE, "", z=3)
    ax.text(75.6, 35.5, "u_smux", ha="center", va="center", fontsize=6.6, rotation=90,
            color=TXT, zorder=4)
    harrow(ax, 73.0, 74.4, 38.5, "", C_USER_FILL, C_USER_EDGE, bh=0.6, hh=1.1, hl=0.6)
    harrow(ax, 73.0, 74.4, 32.5, "", C_USER_FILL, C_USER_EDGE, bh=0.6, hh=1.1, hl=0.6)
    harrow(ax, 76.8, 79.0, 35.5, "", C_USER_FILL, C_USER_EDGE, bh=0.7, hh=1.3, hl=0.8)

    route(ax, [(90.25, 27.5), (90.25, 30.0)], C_THIN, lw=1.1, ms=7)
    vblock(ax, 91.0, 41.0, mux_y0, C_USER_FILL, C_USER_EDGE, bw=0.8, hw=1.5, hl=0.9,
           double=False)
    # gen_clk (orange) from clk_wiz_0 clk_out2
    route(ax, [(49.0, 25.0), (56.0, 25.0)], C_REFCLK_LINE, lw=1.3, ms=8)
    route(ax, [(53.5, 25.0), (53.5, 38.5), (56.0, 38.5)], C_REFCLK_LINE, lw=1.3, ms=8)
    route(ax, [(53.5, 32.5), (56.0, 32.5)], C_REFCLK_LINE, lw=1.3, ms=8)
    clk_tag(ax, 54.3, 28.75, "gen_clk  200 MHz", fs=7.0, ha="left")

    # generic MAC boundary (u_regs) -> cmac_adapt -> CMAC ctl_* / stat_* sideband
    line(ax, [(72.25, top_y0 + top_h), (72.25, 100.5), (124.0, 100.5)], C_THIN, lw=1.1)
    box(ax, 124.0, 98.4, 9.0, 4.2, C_MAC_FILL, C_MAC_EDGE, "cmac_adapt", fs=6.8, z=3)
    line(ax, [(133.0, 100.5), (135.0, 100.5)], C_THIN, lw=1.1)
    route(ax, [(135.0, 100.5), (135.0, 87.0), (135.0, 86.0)], C_THIN, lw=1.1, ms=7)
    ax.text(124.0, 105.0, "mac_ctl / mac_stat / ...\n(generic MAC boundary)", ha="left",
            va="center", fontsize=6.6, color=C_MUTED, linespacing=1.1)
    ax.text(136.0, 94.0, "ctl_* / stat_*\n(enables, RS-FEC,\nPAUSE, loopback;\nalignment, faults,\ncounters)",
            ha="left", va="center", fontsize=7.0, color=C_MUTED, linespacing=1.15)

    # ---- CMAC and GT --------------------------------------------------------------
    titled_box(ax, cm_x0, 50.0, cm_x1 - cm_x0, 36.0, C_GT_FILL, C_GT_EDGE, "cmac",
               "cmac_usplus\nCMACE4_X0Y0\n\nCAUI-4\nRS-FEC (CL91)\n802.3x PAUSE\n\n"
               "512-bit\nAXI4-Stream\n\nno AXI-Lite,\nno statistics\nblock",
               title_fs=9.0, body_fs=7.0, title_dy=2.2, lw=1.3)
    gt_x0, gt_x1 = 140.0, 148.0
    titled_box(ax, gt_x0, 59.0, gt_x1 - gt_x0, 20.0, C_GT_FILL, C_GT_EDGE, "GTY",
               "x4\nquad\nX0Y12\n-X0Y15\n\nbank\n227", title_fs=8.6, body_fs=7.0,
               title_dy=2.0)
    harrow(ax, cm_x1, gt_x0, 69.0, "", C_GT_FILL, C_GT_EDGE, double=True, bh=0.8, hh=1.5,
           hl=0.8)
    clk_tag(ax, (cm_x0 + cm_x1) / 2, 45.6, "gt_txusrclk2\n322.27 MHz\n= rocelet_sys clk\n"
            "= CMAC rx_clk", fs=7.0)

    # ---- FMC card -----------------------------------------------------------------
    fmc_x0, fmc_x1 = 153.0, 180.0
    ax.add_patch(plt.Rectangle((fmc_x0, 13.0), fmc_x1 - fmc_x0, 84.0,
                               fc=C_FMC_FILL, ec=C_FMC_EDGE, lw=1.3, zorder=1))
    ax.text((fmc_x0 + fmc_x1) / 2, 92.5, "2x QSFP28 FMC (OP120)\non the KCU116 FMC HPC",
            ha="center", va="center", fontsize=8.6, weight="bold", color=TXT,
            linespacing=1.2)
    cg_x0, cg_w = 155.5, 22.0
    titled_box(ax, cg_x0, 55.0, cg_w, 32.0, C_SLOT_FILL, C_FMC_EDGE, "QSFP28 port 0",
               "100G QSFP28 cable to\nthe host NIC, or a\nQSFP28 loopback plug\n\n"
               "module I2C (LA03):\naxi_iic_qsfp0\nModSelL, ResetL, LPMode,\n"
               "ModPrsL, IntL:\naxi_gpio_qsfp0\ngreen LED = RX aligned",
               title_fs=8.6, body_fs=7.0, title_dy=2.2)
    harrow(ax, gt_x1, cg_x0, 69.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, double=True,
           bh=1.0, hh=1.9, hl=1.1)
    ax.text((gt_x1 + cg_x0) / 2, 73.4, "FMC\nDP0-3", ha="center", va="center",
            fontsize=7.0, color=TXT, linespacing=1.1)
    titled_box(ax, cg_x0, 33.0, cg_w, 17.0, C_CLK_FILL, C_CLK_EDGE, "Si5328",
               "322.265625 MHz\nGT reference clock\n(GBTCLK0_M2C)\nI2C (LA02): axi_iic_clk",
               title_fs=8.6, body_fs=7.0, title_dy=2.0)
    route(ax, [(cg_x0, 41.5), (144.0, 41.5), (144.0, 59.0)], C_REFCLK_LINE, lw=1.4, ms=9)
    titled_box(ax, cg_x0, 15.0, cg_w, 14.0, C_SLOT_FILL, C_FMC_EDGE, "QSFP28 port 1",
               "not routed on the\nKCU116 (DP4-7):\nheld deselected,\nin reset",
               title_fs=8.4, body_fs=7.0, title_dy=2.0, ls=(0, (4, 2)))

    legend(ax, 153.0, 110.0, [
        (C_LINKARR_FILL, C_LINKARR_EDGE, "register access (AXI-Lite)"),
        (C_AXARR_FILL, C_AXARR_EDGE, "memory (AXI4, 512 bit)"),
        (C_USER_FILL, C_USER_EDGE, "AXI4-Stream (512 bit)"),
        (None, C_REFCLK_LINE, "clocks"),
    ], dy=3.4)

    # ---- notes strip ----------------------------------------------------------------
    titled_box(ax, 2.0, 0.0, 178.0, 11.0, C_CTRL_FILL, C_CTRL_EDGE,
               "MicroBlaze address map: GPIO 0x4000_0000, I2C Si5328 0x4080_0000, I2C QSFP28 0x4081_0000, "
               "timer 0x41C0_0000, UART 0x44A0_0000, rocelet_sys 0x4480_0000\n(engine registers; "
               "system registers +0x10000; memory window +0x40000)",
               "Dashed: self-test logic (SELFTEST = 1, \"selftest\" in config/data.json; a product sets it to 0).  "
               "One work-request source at a time: the payload always follows the WR order.\n"
               "The engine's internals (MAC glue, requester, responder, retransmit ring) are documented in "
               "submodules/rocelet/docs.  Everything in rocelet_sys runs in the CMAC user clock, except the "
               "IQ16 and beam array generators and the DNA read-out (gen_clk 200 MHz).",
               title_fs=7.4, body_fs=7.0, title_dy=2.6)
    ax.text(91.0, 122.5, "qsfp28-fmc-rocelet  —  KCU116 + 2x QSFP28 FMC (OP120), QSFP28 port 0, 100G",
            ha="center", va="center", fontsize=13.0, weight="bold", color=TXT)
    save(fig, "rocelet-block.png")


# -----------------------------------------------------------------------------
# 1b. Whole design, Zynq UltraScale+ (zcu106; the page that shows it is
#     board-agnostic, so ZCU106 values are labelled as the example).
#
# Cells, ports, clocks and interrupts from Vivado/src/bd/bd_zynqmp.tcl; the
# rocelet_sys instances from Vivado/src/hdl/rocelet_sys.sv (DDR_EN, DDR_PORTS 2,
# ODMA_EN, SELFTEST); the always-on block from rsys_aon.sv; FMC pins and the GT
# reference clock from Vivado/src/constraints/zcu106.xdc; addresses from
# docs/source/zynqmp_hw.md ("Address map").
# -----------------------------------------------------------------------------
def draw_zynqmp():
    fig, ax = new_fig(24.0, 18.0, 205, 152)
    dash = (0, (4, 2))

    # ---- processing system column --------------------------------------------------
    ps_x0, ps_x1 = 2.0, 26.0
    box(ax, ps_x0, 14.0, ps_x1 - ps_x0, 125.0, C_PS_FILL, C_PS_EDGE, "", lw=1.3)
    ax.text((ps_x0 + ps_x1) / 2, 135.5, "Zynq UltraScale+ PS", ha="center", va="center",
            fontsize=10.6, weight="bold", color=TXT)
    ib_x0, ib_x1 = 3.5, 18.5
    titled_box(ax, ib_x0, 99.0, ib_x1 - ib_x0, 32.0, "#ECECEC", C_PS_EDGE, "APU  Cortex-A53",
               "Linux (AMD EDF\nYocto):\nroceletd, rl,\nweb UI,\nrl_net.ko → rl0\n\nor the bare-metal\n"
               "console (same\nVitis/common/src)", title_fs=7.8, body_fs=6.9, title_dy=2.0)
    titled_box(ax, ib_x0, 89.0, ib_x1 - ib_x0, 7.5, "#ECECEC", C_PS_EDGE, "GEM",
               "board RJ45:\nSSH, web UI", title_fs=7.4, body_fs=6.7, title_dy=1.6)
    titled_box(ax, ib_x0, 80.0, ib_x1 - ib_x0, 6.5, "#ECECEC", C_PS_EDGE, "UART",
               "console 115200", title_fs=7.4, body_fs=6.7, title_dy=1.6)
    titled_box(ax, ib_x0, 40.0, ib_x1 - ib_x0, 37.0, "#ECECEC", C_PS_EDGE, "PS DDR",
               "PS DDR window:\none region given\nat run time\n(Linux: 256 MB\nreserved-memory,\n"
               "UIO rocelet-ddr)\n\nnetdev buffers\n(rl_net, DMA\ndescriptors)", title_fs=8.2,
               body_fs=6.9, title_dy=2.0)
    ax.text((ps_x0 + ps_x1) / 2, 27.0,
            "pl_clk0  100 MHz\npl_clk1  250 MHz\npl_clk2  200 MHz\n\npl_ps_irq0[4:0]:\nrsys_aon, DMA x2,\nIIC x2",
            ha="center", va="center", fontsize=6.9, color=C_REFCLK_LINE, weight="bold",
            linespacing=1.3)

    def ps_port(y, name):
        ax.text(ps_x1 - 0.5, y, name, ha="right", va="center", fontsize=6.6,
                color=C_CTRL_LINE, weight="bold", zorder=4)

    # ---- fabric container ---------------------------------------------------------
    fab_x0, fab_x1 = 29.0, 165.0
    ax.add_patch(plt.Rectangle((fab_x0, 14.0), fab_x1 - fab_x0, 125.0,
                               fc=C_FAB_FILL, ec=C_FAB_EDGE, lw=1.3, zorder=1))
    ax.text((fab_x0 + fab_x1) / 2, 140.3,
            "Zynq UltraScale+ PL  (ZCU106: XCZU7EV)", ha="center", va="bottom",
            fontsize=11.5, weight="bold", color=TXT)

    # ---- control plane: SmartConnect, always-on block, IIC --------------------------
    smc_x, smc_w, smc_y0, smc_y1 = 30.5, 4.0, 100.0, 130.0
    box(ax, smc_x, smc_y0, smc_w, smc_y1 - smc_y0, C_MAC_FILL, C_MAC_EDGE, "", lw=1.2)
    ax.text(smc_x + smc_w / 2, (smc_y0 + smc_y1) / 2, "axi_smc  (pl_clk0 100 MHz)",
            ha="center", va="center", fontsize=7.0, weight="bold", color=TXT, rotation=90)
    harrow(ax, ps_x1, smc_x, 124.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, bh=0.8, hh=1.5,
           hl=1.0)
    ps_port(126.8, "HPM0_LPD")
    aon_x0, aon_x1, aon_y0, aon_y1 = 37.0, 58.5, 108.0, 134.0
    titled_box(ax, aon_x0, aon_y0, aon_x1 - aon_x0, aon_y1 - aon_y0, C_MAC_FILL, C_MAC_EDGE,
               "rsys_aon_0",
               "always-on registers\n(pl_clk0): GT / MAC\nresets, link + lane\nstatus, MAC clock,"
               "\nQSFP lines, CAPS,\none aggregated IRQ\n\nclock guard: every\naccess completes"
               "\n(0xDEADC10C while\nthe MAC clock stops)", title_fs=8.2, body_fs=6.8,
               title_dy=1.9, z=3)
    harrow(ax, smc_x + smc_w, aon_x0, 124.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, bh=0.7,
           hh=1.3, hl=0.8)
    # IIC controllers next to the FMC, reached by a register line over the top
    iic_x0, iic_x1 = 147.0, 163.5
    titled_box(ax, iic_x0, 127.0, iic_x1 - iic_x0, 6.0, C_MAC_FILL, C_MAC_EDGE, "axi_iic_clk",
               "Si5328", title_fs=7.2, body_fs=6.7, title_dy=1.5, z=3)
    titled_box(ax, iic_x0, 119.0, iic_x1 - iic_x0, 6.0, C_MAC_FILL, C_MAC_EDGE,
               "axi_iic_qsfp0", "QSFP28 module", title_fs=7.2, body_fs=6.7, title_dy=1.5, z=3)
    line(ax, [(smc_x + smc_w / 2, smc_y1), (smc_x + smc_w / 2, 136.8), (144.5, 136.8),
              (144.5, 122.0)], C_CTRL_LINE, lw=1.1)
    route(ax, [(144.5, 130.0), (iic_x0, 130.0)], C_CTRL_LINE, lw=1.1, ms=7)
    route(ax, [(144.5, 122.0), (iic_x0, 122.0)], C_CTRL_LINE, lw=1.1, ms=7)

    # ---- rocelet_sys ------------------------------------------------------------------
    rs_x0, rs_x1, rs_y0, rs_y1 = 62.0, 131.0, 17.0, 133.0
    box(ax, rs_x0, rs_y0, rs_x1 - rs_x0, rs_y1 - rs_y0, "#FAFAFD", C_MAC_EDGE, "", lw=1.4)
    ax.text(rs_x0 + 1.5, rs_y1 - 2.6, "rocelet_sys_0  (Vivado/src/hdl/rocelet_sys.sv)",
            ha="left", va="center", fontsize=9.4, weight="bold", color=TXT)
    clk_tag(ax, rs_x1 - 1.5, rs_y1 - 2.6, "clk: MAC user clock (156.25 MHz)", ha="right")

    # guarded register window from the always-on block into u_split
    top_y0, top_h = 113.0, 13.0
    harrow(ax, aon_x1, 64.0, 119.5, "", C_LINKARR_FILL, C_LINKARR_EDGE, bh=0.8, hh=1.5,
           hl=1.0)
    ax.text(60.5, 114.6, "1 MB\nguarded", ha="center", va="center", fontsize=6.6,
            color=C_CTRL_LINE, linespacing=1.1)
    titled_box(ax, 64.0, top_y0, 10.5, top_h, C_CTRL_FILL, C_CTRL_EDGE, "u_split",
               "AXI-Lite\ndecoder\n+0x00000 eng.\n+0x10000 regs\n+0x40000 URAM",
               title_fs=7.8, body_fs=6.6, title_dy=1.8, z=3)
    titled_box(ax, 76.0, top_y0, 10.5, top_h, C_CTRL_FILL, C_CTRL_EDGE, "u_regs",
               "system regs:\nMAC control,\nDDR window,\ncounters,\nqueues, sources",
               title_fs=7.8, body_fs=6.6, title_dy=1.8, z=3)
    titled_box(ax, 88.0, top_y0, 11.0, top_h, C_MAC_FILL, C_MAC_EDGE, "u_crx",
               "control-plane\nRX FIFO\n(bare-metal\nHSB path)", title_fs=7.8, body_fs=6.6,
               title_dy=1.8, z=3)
    titled_box(ax, 100.5, top_y0, 11.0, top_h, C_MAC_FILL, C_MAC_EDGE, "u_raw",
               "raw TX frames,\ncapture buffer\nat the MAC", title_fs=7.8, body_fs=6.6,
               title_dy=1.8, z=3)
    titled_box(ax, 113.0, top_y0, 16.0, top_h, C_MAC_FILL, C_MAC_EDGE, "self-test checkers",
               "u_wchk: memory writes\nu_schk: SEND payload\nu_lat: latency probe",
               title_fs=7.6, body_fs=6.6, title_dy=1.8, ls=dash, z=3)
    harrow(ax, 74.5, 76.0, 119.5, "", C_LINKARR_FILL, C_LINKARR_EDGE, bh=0.5, hh=1.0,
           hl=0.6, z=4)

    # left column: memory windows, interleave, netdev DMA channel, WR queue
    lc_x0, lc_x1 = 64.0, 84.0
    eng_x0, eng_x1, eng_y0, eng_y1 = 92.0, 115.0, 78.0, 109.0
    titled_box(ax, lc_x0, 99.0, lc_x1 - lc_x0, 10.0, C_MAC_FILL, C_MAC_EDGE, "u_mem",
               "URAM window 256 KB\n(also the CPU's view)", title_fs=8.0, body_fs=6.8,
               title_dy=1.8, z=3)
    titled_box(ax, lc_x0, 87.5, lc_x1 - lc_x0, 8.0, C_MAC_FILL, C_MAC_EDGE, "u_dec  rsys_axi_dec",
               "bit 40: pattern  bit 39: PS DDR\nelse URAM; outside: null", title_fs=7.4,
               body_fs=6.5, title_dy=1.6, z=3)
    titled_box(ax, lc_x0, 71.5, lc_x1 - lc_x0, 12.5, C_MAC_FILL, C_MAC_EDGE,
               "u_ilv  rsys_axi_ilv",
               "PS DDR window over\n2 ports per direction:\n512-byte granules\n(PA bit 9), order kept",
               title_fs=7.4, body_fs=6.5, title_dy=1.6, z=3)
    titled_box(ax, lc_x0, 56.0, lc_x1 - lc_x0, 11.5, C_MAC_FILL, C_MAC_EDGE, "u_odma",
               "netdev DMA channel:\nnon-RoCE frames to /\nfrom Linux, 32 KB FIFOs",
               title_fs=7.8, body_fs=6.6, title_dy=1.7, z=3)
    titled_box(ax, lc_x0, 42.0, lc_x1 - lc_x0, 10.5, C_MAC_FILL, C_MAC_EDGE, "u_wrq",
               "firmware WR queue\n(payload from u_mem),\ncompletion queues",
               title_fs=7.8, body_fs=6.6, title_dy=1.7, z=3)
    # engine
    titled_box(ax, eng_x0, eng_y0, eng_x1 - eng_x0, eng_y1 - eng_y0, C_MAC_FILL, C_MAC_EDGE,
               "u_rl  rocelet_top",
               "RoCE v2 engine\n(submodules/rocelet,\nv0.3, built at 512 bit)\n\n"
               "RC requester + responder,\nUC-HSB, ARP / ICMP,\n802.3x PAUSE, counters\n\n"
               "16 QPs, 128 WRs,\n256 KB URAM\nretransmit ring", title_fs=8.8, body_fs=6.8,
               title_dy=2.1, lw=2.0, z=3)
    # register paths (blue): u_split -> u_mem, u_split -> engine
    route(ax, [(67.0, top_y0), (67.0, 109.0)], C_CTRL_LINE, lw=1.2, ms=7)
    route(ax, [(71.5, top_y0), (71.5, 111.0), (94.0, 111.0), (94.0, eng_y1)], C_CTRL_LINE,
          lw=1.2, ms=7)
    # engine AXI4 master -> decoder -> URAM / interleave (green)
    harrow(ax, lc_x1, eng_x0, 91.5, "", C_AXARR_FILL, C_AXARR_EDGE, double=True, bh=0.9,
           hh=1.7, hl=1.1)
    ax.text(88.0, 95.6, "AXI4\n512 b", ha="center", va="center", fontsize=6.6,
            color=C_DATA_LINE, linespacing=1.05)
    vblock(ax, 74.0, 95.5, 99.0, C_AXARR_FILL, C_AXARR_EDGE, bw=0.8, hw=1.5, hl=1.0)
    vblock(ax, 74.0, 84.0, 87.5, C_AXARR_FILL, C_AXARR_EDGE, bw=0.8, hw=1.5, hl=1.0)
    # other-traffic port <-> u_crx / u_raw (top) and u_odma (left)
    vblock(ax, 97.0, eng_y1, top_y0, C_USER_FILL, C_USER_EDGE, bw=0.8, hw=1.5, hl=1.0,
           double=False, z=4)
    vblock(ax, 106.0, top_y0, eng_y1, C_USER_FILL, C_USER_EDGE, bw=0.8, hw=1.5, hl=1.0,
           double=False, z=4)
    ax.text(101.5, 111.2, "other traffic", ha="center", va="center", fontsize=6.6,
            color=TXT)
    line(ax, [(eng_x0, 80.0), (88.0, 80.0), (88.0, 61.75)], C_USER_EDGE, lw=1.6)
    route(ax, [(88.0, 61.75), (lc_x1, 61.75)], C_USER_EDGE, lw=1.6, ms=9)
    route(ax, [(lc_x1, 59.0), (95.5, 59.0), (95.5, eng_y0)], C_USER_EDGE, lw=1.6, ms=9)
    ax.text(85.3, 66.2, "other\ntraffic", ha="left", va="center", fontsize=6.4, color=TXT,
            linespacing=1.05)

    # WR mux and sources
    mux_y0, mux_y1 = 45.0, 49.5
    box(ax, eng_x0, mux_y0, eng_x1 - eng_x0, mux_y1 - mux_y0, C_CTRL_FILL, C_CTRL_EDGE,
        "WR mux: u_wg > u_hp > u_wrq", fs=6.9, z=3)
    vblock(ax, 108.0, mux_y1, eng_y0, C_USER_FILL, C_USER_EDGE, bw=0.8, hw=1.5, hl=0.9,
           double=False)
    harrow(ax, lc_x1, eng_x0, 47.25, "", C_USER_FILL, C_USER_EDGE, bh=0.7, hh=1.3, hl=0.9)
    ax.text(86.5, 44.2, "WRs", ha="center", va="center", fontsize=6.6, color=TXT)
    route(ax, [(100.0, eng_y0), (100.0, 53.0), (lc_x1, 53.0)], C_USER_EDGE, lw=1.6, ms=9)
    ax.text(101.0, 55.0, "completions", ha="left", va="center", fontsize=6.6, color=TXT)

    # RX / TX path: width converters at the MAC ports, fault injectors (dashed)
    inj_x0, inj_x1 = 117.0, 124.8
    cv_x0, cv_x1 = 125.8, 129.6
    rx_y, tx_y = 98.5, 85.5
    titled_box(ax, inj_x0, 94.0, inj_x1 - inj_x0, 9.0, C_MAC_FILL, C_MAC_EDGE, "u_rinj",
               "RX fault\ninjector", title_fs=7.2, body_fs=6.4, title_dy=1.6, ls=dash, z=3)
    titled_box(ax, inj_x0, 81.0, inj_x1 - inj_x0, 9.0, C_MAC_FILL, C_MAC_EDGE, "u_inj",
               "TX fault inj.\n+ skid", title_fs=7.2, body_fs=6.4, title_dy=1.6, ls=dash, z=3)
    box(ax, cv_x0, 94.0, cv_x1 - cv_x0, 9.0, C_CTRL_FILL, C_CTRL_EDGE, "", z=3)
    box(ax, cv_x0, 81.0, cv_x1 - cv_x0, 9.0, C_CTRL_FILL, C_CTRL_EDGE, "", z=3)
    ax.text((cv_x0 + cv_x1) / 2, 98.5, "256→512", ha="center", va="center", fontsize=6.3,
            rotation=90, color=TXT, zorder=4)
    ax.text((cv_x0 + cv_x1) / 2, 85.5, "512→256", ha="center", va="center", fontsize=6.3,
            rotation=90, color=TXT, zorder=4)
    ax.text(127.7, 105.0, "rocelet width\nconverters", ha="center", va="center",
            fontsize=6.2, color=C_MUTED, linespacing=1.05)
    harrow(ax, inj_x0, eng_x1, rx_y, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=0.8)
    harrow(ax, cv_x0, inj_x1, rx_y, "", C_USER_FILL, C_USER_EDGE, bh=0.6, hh=1.1, hl=0.5)
    harrow(ax, eng_x1, inj_x0, tx_y, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=0.8)
    harrow(ax, inj_x1, cv_x0, tx_y, "", C_USER_FILL, C_USER_EDGE, bh=0.6, hh=1.1, hl=0.5)

    # self-test WR generator (dashed)
    titled_box(ax, 117.0, 55.0, 12.5, 10.0, C_MAC_FILL, C_MAC_EDGE, "u_wg",
               "WR generator,\npattern payload", title_fs=7.6, body_fs=6.5, title_dy=1.7,
               ls=dash, z=3)
    route(ax, [(123.0, 55.0), (123.0, 47.25), (eng_x1, 47.25)], C_USER_EDGE, lw=1.6, ms=9)

    # HSB device side with the streaming source boundary
    dashed_group(ax, 63.5, 19.0, 66.5, 20.5, "Holoscan Sensor Bridge device side",
                 ec=C_MAC_EDGE, fs=7.0)
    box(ax, 66.0, 31.5, 15.0, 4.2, C_MAC_FILL, C_MAC_EDGE, "u_iqs  IQ16 generator", fs=6.6,
        z=3)
    box(ax, 66.0, 26.3, 15.0, 4.2, C_MAC_FILL, C_MAC_EDGE, "u_bms  8 x 8 array gen.", fs=6.6,
        z=3)
    box(ax, 66.0, 21.1, 15.0, 4.2, "#FFFFFF", C_USER_EDGE,
        "input 3: a design source\n(e.g. RF-ADC stream)", fs=6.0, ls=dash, z=3)
    box(ax, 83.5, 21.1, 3.2, 14.6, C_CTRL_FILL, C_CTRL_EDGE, "", z=3)
    ax.text(85.1, 28.4, "u_smux  (s_axis_src)", ha="center", va="center", fontsize=6.4,
            rotation=90, color=TXT, zorder=4)
    for yy in (33.6, 28.4, 23.2):
        harrow(ax, 81.0, 83.5, yy, "", C_USER_FILL, C_USER_EDGE, bh=0.55, hh=1.0, hl=0.6)
    titled_box(ax, 90.0, 27.0, 22.0, 9.0, C_MAC_FILL, C_MAC_EDGE, "u_hp  frame producer",
               "data WRITEs + metadata WRITE-imm,\npage ring, pacing; counter source",
               title_fs=7.6, body_fs=6.4, title_dy=1.7, z=3)
    harrow(ax, 86.7, 90.0, 31.5, "", C_USER_FILL, C_USER_EDGE, bh=0.7, hh=1.3, hl=0.8)
    box(ax, 90.0, 21.1, 22.0, 4.2, C_MAC_FILL, C_MAC_EDGE, "u_ptime  seconds / ns", fs=6.6,
        z=3)
    box(ax, 114.5, 21.1, 14.5, 4.2, C_MAC_FILL, C_MAC_EDGE, "u_dna  device DNA", fs=6.6, z=3)
    route(ax, [(101.0, 25.3), (101.0, 27.0)], C_THIN, lw=1.1, ms=6)
    vblock(ax, 108.0, 36.0, mux_y0, C_USER_FILL, C_USER_EDGE, bw=0.8, hw=1.5, hl=0.9,
           double=False)
    # gen_clk (orange) = pl_clk2
    route(ax, [(ps_x1, 19.5), (64.5, 19.5), (64.5, 33.6), (66.0, 33.6)], C_REFCLK_LINE,
          lw=1.3, ms=7)
    route(ax, [(64.5, 28.4), (66.0, 28.4)], C_REFCLK_LINE, lw=1.3, ms=7)
    route(ax, [(64.5, 19.5), (121.75, 19.5), (121.75, 21.1)], C_REFCLK_LINE, lw=1.3, ms=7)
    clk_tag(ax, 31.0, 21.3, "pl_clk2 200 MHz = gen_clk", fs=6.8, ha="left")

    # ---- PS DDR window: interleave -> 4 SmartConnects -> HP0 / HPC0 / HP1 / HP3 -------
    sd_x0, sd_x1 = 38.0, 56.0
    titled_box(ax, sd_x0, 70.5, sd_x1 - sd_x0, 15.5, C_MAC_FILL, C_MAC_EDGE,
               "smc_ddrw / w1 / r / r1",
               "4 SmartConnects:\n512 b MAC clock →\n128 b pl_clk1 250 MHz", title_fs=7.0,
               body_fs=6.5, title_dy=1.6, z=3)
    for yy, port in ((82.5, "HP0  wr"), (80.0, "HPC0 wr"), (77.5, "HP1  rd"), (75.0, "HP3  rd")):
        harrow(ax, ps_x1, sd_x0, yy, "", C_AXARR_FILL, C_AXARR_EDGE, double=True, bh=0.45,
               hh=0.95, hl=0.7)
        harrow(ax, sd_x1, lc_x0, yy, "", C_AXARR_FILL, C_AXARR_EDGE, double=True, bh=0.45,
               hh=0.95, hl=0.7)
        ps_port(yy, port)
    ax.text(60.0, 87.8, "even / odd\n512 B", ha="center", va="center", fontsize=6.3,
            color=C_DATA_LINE, linespacing=1.05)

    # ---- netdev DMA: u_odma <-> width converters + AXI DMA -> HP2 ----------------------
    dm_x0, dm_x1 = 37.0, 56.0
    titled_box(ax, dm_x0, 50.0, dm_x1 - dm_x0, 17.0, C_MAC_FILL, C_MAC_EDGE, "axi_dma_0",
               "AXI DMA, scatter-gather\n64 b @ pl_clk1 250 MHz\n+ 512↔64 converters\n"
               "(odma_rx_dw / tx_dw)\nregisters: axi_smc M03\nLinux: rl_net.ko",
               title_fs=7.8, body_fs=6.5, title_dy=1.8, z=3)
    harrow(ax, lc_x0, dm_x1, 63.0, "", C_USER_FILL, C_USER_EDGE, bh=0.6, hh=1.1, hl=0.7)
    harrow(ax, dm_x1, lc_x0, 59.5, "", C_USER_FILL, C_USER_EDGE, bh=0.6, hh=1.1, hl=0.7)
    ax.text(60.0, 66.6, "S2MM / MM2S", ha="center", va="center", fontsize=6.0, color=TXT)
    harrow(ax, ps_x1, dm_x0, 58.0, "", C_AXARR_FILL, C_AXARR_EDGE, double=True, bh=0.6,
           hh=1.1, hl=0.8)
    ps_port(60.4, "HP2  DMA")

    # ---- MAC block and GTH ----------------------------------------------------------------
    mac_x0, mac_x1, mac_y0, mac_y1 = 135.5, 148.5, 74.0, 109.0
    titled_box(ax, mac_x0, mac_y0, mac_x1 - mac_x0, mac_y1 - mac_y0, C_MAC_FILL, C_MAC_EDGE,
               "mac0",
               "mac_omac40g:\nomac_40g\n40GBASE-R4\n256 b\n\n10G option:\nmac_omac10g,\n"
               "omac_10g, 64 b\n\nopen source\n(submodules/\nopsero-ethernet-\nmac)",
               title_fs=8.6, body_fs=6.6, title_dy=2.0, lw=1.3, z=3)
    harrow(ax, mac_x0, cv_x1, rx_y, "", C_USER_FILL, C_USER_EDGE, bh=0.9, hh=1.7, hl=1.0)
    harrow(ax, cv_x1, mac_x0, tx_y, "", C_USER_FILL, C_USER_EDGE, bh=0.9, hh=1.7, hl=1.0)
    ax.text((cv_x1 + mac_x0) / 2, rx_y + 2.8, "RX", ha="center", va="center", fontsize=6.8,
            weight="bold", color=TXT)
    ax.text((cv_x1 + mac_x0) / 2, tx_y + 2.8, "TX", ha="center", va="center", fontsize=6.8,
            weight="bold", color=TXT)
    gt_x0, gt_x1 = 151.0, 161.5
    titled_box(ax, gt_x0, 80.0, gt_x1 - gt_x0, 23.0, C_GT_FILL, C_GT_EDGE, "GTH",
               "x4 (10G: x1)\n10.3125 Gb/s\nper lane\n\ngtwizard\n(free IP,\ngenerated\nat build)",
               title_fs=8.4, body_fs=6.5, title_dy=1.9)
    harrow(ax, mac_x1, gt_x0, 91.5, "", C_GT_FILL, C_GT_EDGE, double=True, bh=0.8, hh=1.5,
           hl=0.8)
    clk_tag(ax, (mac_x0 + mac_x1) / 2, 67.0, "clk_out = GT\nTXUSRCLK2\n156.25 MHz\n"
            "= rocelet_sys clk\n(+ 1 RX clock\nper lane)", fs=6.7)
    # generic MAC boundary sideband: u_regs <-> mac0 (and the status into rsys_aon)
    line(ax, [(81.25, top_y0 + top_h), (81.25, 128.0), (133.5, 128.0)], C_THIN, lw=1.1)
    route(ax, [(133.5, 128.0), (133.5, 112.0), (139.0, 112.0), (139.0, mac_y1)], C_THIN,
          lw=1.1, ms=7)
    ax.text(140.2, 115.8, "generic MAC\nboundary:\nmac_ctl / pz /\naddr, mac_stat /\nev / pause",
            ha="left", va="center", fontsize=6.2, color=C_MUTED, linespacing=1.08)

    # ---- FMC card -----------------------------------------------------------------------
    fmc_x0, fmc_x1 = 168.5, 203.0
    ax.add_patch(plt.Rectangle((fmc_x0, 14.0), fmc_x1 - fmc_x0, 125.0,
                               fc=C_FMC_FILL, ec=C_FMC_EDGE, lw=1.3, zorder=1))
    ax.text((fmc_x0 + fmc_x1) / 2, 134.0, "2x QSFP28 FMC (OP120)\non the board's FMC\n(ZCU106: HPC0)",
            ha="center", va="center", fontsize=8.4, weight="bold", color=TXT, linespacing=1.2)
    cg_x0, cg_x1 = 171.0, 201.0
    titled_box(ax, cg_x0, 108.0, cg_x1 - cg_x0, 18.0, C_CLK_FILL, C_CLK_EDGE, "Si5328",
               "156.25 MHz GT reference clock\n(GBTCLK0_M2C), programmed\nby software before the\n"
               "GT reset is released\nI2C (LA02); LOS (LA06_P)", title_fs=8.4, body_fs=6.6,
               title_dy=1.9)
    titled_box(ax, cg_x0, 62.0, cg_x1 - cg_x0, 40.0, C_SLOT_FILL, C_FMC_EDGE, "QSFP28 port 0",
               "40G: QSFP28 / QSFP+ DAC to the\nhost NIC (40GBASE-CR4, no FEC)\n"
               "10G option: lane 0 only\n\nmodule I2C (LA03):\naxi_iic_qsfp0\n\n"
               "ModSelL, ResetL, LPMode,\nModPrsL, IntL, LEDs:\nrsys_aon", title_fs=8.4,
               body_fs=6.6, title_dy=2.0)
    titled_box(ax, cg_x0, 18.0, cg_x1 - cg_x0, 18.0, C_SLOT_FILL, C_FMC_EDGE, "QSFP28 port 1",
               "not used: held deselected,\nin reset, low power;\nits lanes (DP4-7) reserved",
               title_fs=8.2, body_fs=6.6, title_dy=1.9, ls=dash)
    harrow(ax, gt_x1, cg_x0, 91.5, "", C_LINKARR_FILL, C_LINKARR_EDGE, double=True,
           bh=1.0, hh=1.9, hl=1.1)
    ax.text((gt_x1 + cg_x0) / 2, 96.6, "FMC\nDP0-3", ha="center", va="center", fontsize=6.6,
            color=TXT, linespacing=1.05)
    # I2C (thin blue) and reference clock (orange)
    route(ax, [(iic_x1, 130.0), (186.0, 130.0), (186.0, 126.0)], C_CTRL_LINE, lw=1.1, ms=7)
    route(ax, [(iic_x1, 122.0), (166.5, 122.0), (166.5, 99.0), (cg_x0, 99.0)], C_CTRL_LINE,
          lw=1.1, ms=7)
    route(ax, [(cg_x0, 111.0), (156.25, 111.0), (156.25, 103.0)], C_REFCLK_LINE, lw=1.4, ms=8)

    legend(ax, 31.0, 46.0, [
        (C_LINKARR_FILL, C_LINKARR_EDGE, "register access (AXI-Lite)"),
        (C_AXARR_FILL, C_AXARR_EDGE, "memory (AXI4)"),
        (C_USER_FILL, C_USER_EDGE, "AXI4-Stream"),
        (None, C_REFCLK_LINE, "clocks"),
        (None, C_THIN, "sideband"),
    ], fs=6.6, dy=3.2)

    # ---- notes strip -----------------------------------------------------------------------
    titled_box(ax, 2.0, 0.0, 201.0, 11.0, C_CTRL_FILL, C_CTRL_EDGE,
               "Address map (M_AXI_HPM0_LPD): rsys_aon_0 + rocelet_sys 0x8000_0000 (1 MB: engine +0x0, "
               "system registers +0x1_0000, URAM +0x4_0000, always-on +0x8_0000), axi_iic_clk "
               "0x8010_0000, axi_iic_qsfp0 0x8011_0000, axi_dma_0 0x8012_0000",
               "Dashed: self-test logic (\"selftest\" in config/data.json).  Board specific (the values "
               "shown are the ZCU106's): the FMC slot, the GT channels and reference-clock pin, the PS "
               "preset (DDR, GEM, UART).\nThe MAC is the swappable block behind the generic MAC "
               "boundary (data.json \"mac\"); a CMAC target (RFSoC) puts the CMAC there through "
               "cmac_adapt, as the MicroBlaze design does.",
               title_fs=7.2, body_fs=6.8, title_dy=2.6)
    ax.text(102.5, 148.5,
            "qsfp28-fmc-rocelet  —  Zynq UltraScale+ design (zcu106: ZCU106 + 2x QSFP28 FMC, "
            "QSFP28 port 0, 40G)",
            ha="center", va="center", fontsize=13.0, weight="bold", color=TXT)
    save(fig, "rocelet-zynqmp-block.png")


# -----------------------------------------------------------------------------
# 2. HSB device mode, end to end.
#
# Firmware side from Vitis/common/src/hsb.c (bootp_send, rx_frame, dp_start:
# QP 13 = NUM_QP - 3, C_HP_* / C_IQ_* writes); RTL from rocelet_sys.sv (u_crx on
# the engine's other-traffic RX port, u_raw on its other-traffic TX port, u_hp as
# a work-request source fed by u_iqs and u_ptime, u_dna in gen_clk); host side
# from docs/source/hsb.md and sw/hsb/.
# -----------------------------------------------------------------------------
def draw_device_flow():
    fig, ax = new_fig(21.5, 12.4, 176, 101)

    # ---- processor column -----------------------------------------------------
    ps_x0, ps_w = 2.0, 20.0
    ps_r = ps_x0 + ps_w
    box(ax, ps_x0, 15.0, ps_w, 75.0, C_PS_FILL, C_PS_EDGE, "", lw=1.3)
    ax.text(ps_x0 + ps_w / 2, 85.0, "CPU", ha="center", va="center",
            fontsize=11.0, weight="bold", color=TXT)
    ax.text(ps_x0 + ps_w / 2, 52.0,
            "MicroBlaze or A53\nbare-metal console\nVitis/common/src/hsb.c\n(console: hsb on)\n\n"
            "BOOTP announcement\nonce a second\n\nUDP 8192 server:\nHSB register file,\n"
            "Opsero registers\n\nDP_* registers →\nQP 13 + producer\n\n"
            "keepalive watchdog,\nlink pause",
            ha="center", va="center", fontsize=7.4, color=TXT, linespacing=1.35)

    # ---- fabric -----------------------------------------------------------------
    fab_x0, fab_x1 = 26.0, 123.0
    ax.add_patch(plt.Rectangle((fab_x0, 15.0), fab_x1 - fab_x0, 77.0,
                               fc=C_FAB_FILL, ec=C_FAB_EDGE, lw=1.3, zorder=1))
    ax.text((fab_x0 + fab_x1) / 2, 93.0, "FPGA: rocelet_sys and the MAC  (MAC user clock)",
            ha="center", va="bottom", fontsize=10.5, weight="bold", color=TXT)

    blk_x, blk_w = 47.0, 24.0
    titled_box(ax, blk_x, 70.0, blk_w, 13.0, C_MAC_FILL, C_MAC_EDGE, "u_crx",
               "control-plane RX FIFO\nkeeps UDP 8192 and 12268\n16 frames x 2 KB",
               title_fs=8.6, body_fs=7.2, title_dy=2.0, z=3)
    titled_box(ax, blk_x, 54.0, blk_w, 12.0, C_MAC_FILL, C_MAC_EDGE, "u_raw",
               "raw TX buffer (2 KB):\nBOOTP, register replies",
               title_fs=8.6, body_fs=7.2, title_dy=2.0, z=3)
    titled_box(ax, blk_x, 39.0, blk_w, 11.0, C_CTRL_FILL, C_CTRL_EDGE, "u_regs",
               "C_HP_* producer set-up\nC_IQ_* IQ16 scene, COMMIT",
               title_fs=8.6, body_fs=7.2, title_dy=2.0, z=3)
    titled_box(ax, blk_x, 18.0, blk_w, 16.0, C_MAC_FILL, C_MAC_EDGE, "u_hp  frame producer",
               "per frame: data WRITEs,\nthen a 128-byte metadata\nWRITE-with-immediate;\npage ring, pacing",
               title_fs=8.6, body_fs=7.2, title_dy=2.0, z=3)
    sm_x, sm_w = 28.5, 14.5
    titled_box(ax, sm_x, 24.5, sm_w, 9.5, C_MAC_FILL, C_MAC_EDGE, "u_iqs",
               "IQ16 generator\n(gen_clk 200 MHz)", title_fs=8.0, body_fs=7.0,
               title_dy=1.8, z=3)
    box(ax, sm_x, 17.0, sm_w, 5.0, C_MAC_FILL, C_MAC_EDGE, "u_ptime  s / ns", fs=7.2, z=3)
    box(ax, sm_x, 37.0, sm_w, 5.0, C_MAC_FILL, C_MAC_EDGE, "u_dna  device DNA", fs=7.2, z=3)
    harrow(ax, sm_x + sm_w, blk_x, 29.0, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=1.0)
    route(ax, [(sm_x + sm_w, 19.5), (blk_x, 19.5)], C_THIN, lw=1.1, ms=7)
    route(ax, [(59.0, 39.0), (59.0, 34.0)], C_THIN, lw=1.1, ms=7)
    route(ax, [(sm_x, 39.5), (ps_r, 39.5)], C_THIN, lw=1.1, ms=7)
    ax.text(ps_r + 0.6, 41.2, "serial no.", ha="left", va="center", fontsize=7.0,
            color=C_MUTED)

    eng_x0, eng_x1 = 82.0, 105.0
    titled_box(ax, eng_x0, 18.0, eng_x1 - eng_x0, 66.0, C_MAC_FILL, C_MAC_EDGE,
               "u_rl  rocelet_top",
               "RX classifier:\nRoCE (UDP 4791) → engine\nARP / ICMP → responder\n"
               "anything else →\nother-traffic port\n\nTX: other traffic is\nserved before RoCE\n\n"
               "QP 13, type UC-HSB:\nWRITE Only packets,\nthe metadata WRITE-imm\ncarries the PSN in the\n"
               "record and the immediate",
               title_fs=9.4, body_fs=7.2, title_dy=2.4, lw=2.0, z=3)
    harrow(ax, eng_x0, blk_x + blk_w, 76.5, "other traffic in", C_USER_FILL, C_USER_EDGE,
           bh=1.0, hh=1.9, hl=1.2, fs=7.0, lab_dy=3.0)
    harrow(ax, blk_x + blk_w, eng_x0, 60.0, "other traffic out", C_USER_FILL, C_USER_EDGE,
           bh=1.0, hh=1.9, hl=1.2, fs=7.0, lab_dy=3.0)
    harrow(ax, blk_x + blk_w, eng_x0, 26.0, "WRs + payload", C_USER_FILL, C_USER_EDGE,
           bh=1.0, hh=1.9, hl=1.2, fs=7.0, lab_dy=3.0)

    # firmware register access (blue)
    harrow(ax, ps_r, blk_x, 76.5, "read the head frame, pop", C_LINKARR_FILL,
           C_LINKARR_EDGE, bh=0.8, hh=1.5, hl=1.1, fs=7.0, lab_dy=2.7,
           lab_color=C_CTRL_LINE)
    harrow(ax, ps_r, blk_x, 60.0, "write a frame, send", C_LINKARR_FILL, C_LINKARR_EDGE,
           bh=0.8, hh=1.5, hl=1.1, fs=7.0, lab_dy=2.7, lab_color=C_CTRL_LINE)
    harrow(ax, ps_r, blk_x, 44.5, "start / stop", C_LINKARR_FILL, C_LINKARR_EDGE,
           bh=0.8, hh=1.5, hl=1.1, fs=7.0, lab_dy=2.7, lab_color=C_CTRL_LINE)
    harrow(ax, ps_r, 28.0, 87.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, bh=0.8, hh=1.5, hl=1.1)
    route(ax, [(28.0, 87.0), (93.5, 87.0), (93.5, 84.0)], C_CTRL_LINE, lw=1.3, ms=8)
    ax.text(60.0, 88.6, "engine registers: QP 13 = host QPN, MAC, IP, UDP ports, PMTU, R_Key",
            ha="center", va="center", fontsize=7.0, color=C_CTRL_LINE)

    # MAC (the target's: CMAC on the kcu116, omac_40g on the zcu106)
    titled_box(ax, 108.5, 34.0, 12.0, 32.0, C_GT_FILL, C_GT_EDGE, "MAC",
               "+ GT x4\n\nkcu116:\nCMAC 100G\n\nzcu106:\nomac_40g\n40G", title_fs=8.8,
               body_fs=7.2, title_dy=2.2, lw=1.3)
    harrow(ax, eng_x1, 108.5, 50.0, "", C_USER_FILL, C_USER_EDGE, double=True, bh=1.0,
           hh=1.9, hl=1.0)

    # ---- FMC + cable ------------------------------------------------------------
    titled_box(ax, 126.0, 40.0, 10.0, 20.0, C_FMC_FILL, C_FMC_EDGE, "OP120",
               "QSFP28\nport 0", title_fs=8.4, body_fs=7.2, title_dy=2.0, lw=1.3)
    harrow(ax, 120.5, 126.0, 50.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, double=True,
           bh=0.9, hh=1.7, hl=1.0)
    harrow(ax, 136.0, 143.5, 50.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, double=True,
           bh=0.9, hh=1.7, hl=1.0)
    ax.text(139.75, 54.4, "QSFP\ncable", ha="center", va="center", fontsize=7.0,
            color=TXT, linespacing=1.1)

    # ---- host -------------------------------------------------------------------
    hx0, hx1 = 141.5, 175.0
    ax.add_patch(plt.Rectangle((hx0, 15.0), hx1 - hx0, 77.0, fc=C_FMC_FILL,
                               ec=C_FMC_EDGE, lw=1.3, zorder=1))
    ax.text((hx0 + hx1) / 2, 88.0, "Host: Linux, NVIDIA HSB 3.0.0\ncontainer, ConnectX + GPU",
            ha="center", va="center", fontsize=8.4, weight="bold", color=TXT, linespacing=1.2)
    ix0, iw = 143.5, 29.5
    titled_box(ax, ix0, 63.0, iw, 19.0, C_SLOT_FILL, C_FMC_EDGE, "HSB host software",
               "hololink-enumerate: BOOTP\nregister protocol, UDP 8192\n"
               "DataChannel.configure_roce:\nDP_* registers, DP_VP_MASK",
               title_fs=8.4, body_fs=7.2, title_dy=2.0)
    titled_box(ax, ix0, 44.0, iw, 13.0, C_GT_FILL, C_GT_EDGE, "ConnectX-6 Dx",
               "RoCE v2\nUC QP (the host side of QP 13)",
               title_fs=8.4, body_fs=7.2, title_dy=2.0)
    titled_box(ax, ix0, 29.0, iw, 11.0, C_PS_FILL, C_PS_EDGE, "GPU memory",
               "page ring: frame +\n128-byte metadata record",
               title_fs=8.4, body_fs=7.2, title_dy=2.0)
    titled_box(ax, ix0, 17.0, iw, 9.0, C_SLOT_FILL, C_FMC_EDGE, "Holoscan application",
               "RoceReceiverOp → CheckerOp → ...", title_fs=8.0, body_fs=7.2, title_dy=1.9)
    vblock(ax, 158.25, 57.0, 63.0, C_LINKARR_FILL, C_LINKARR_EDGE, bw=0.9, hw=1.7, hl=1.1)
    vblock(ax, 158.25, 44.0, 40.0, C_AXARR_FILL, C_AXARR_EDGE, bw=0.9, hw=1.7, hl=1.0,
           double=False)
    vblock(ax, 158.25, 29.0, 26.0, C_USER_FILL, C_USER_EDGE, bw=0.9, hw=1.7, hl=0.9,
           double=False)
    ax.text(160.6, 42.0, "RDMA WRITE", ha="left", va="center", fontsize=7.0,
            color=C_DATA_LINE)

    # ---- steps --------------------------------------------------------------------
    marker(ax, 76.5, 64.8, 1)
    marker(ax, 76.5, 81.3, 2)
    marker(ax, 25.0, 84.0, 3)
    marker(ax, 76.5, 30.8, 4)
    marker(ax, 156.0, 42.0, 5)

    titled_box(ax, 2.0, 0.0, 173.0, 13.0, C_CTRL_FILL, C_CTRL_EDGE,
               "Holoscan Sensor Bridge device mode, step by step  (docs/source/hsb.md)",
               "1  Enumeration: once a second the firmware writes a 342-byte BOOTP request (UDP 12268 → 12267, broadcast) "
               "into u_raw; the engine sends it ahead of its RoCE traffic.\n"
               "2  Register protocol: the engine passes every frame that is not RoCE and not ARP / ICMP to its other-traffic port; "
               "u_crx keeps UDP 8192 and 12268; the firmware executes the request and answers through u_raw.\n"
               "3  DP_VP_MASK 0 → 1: the firmware configures QP 13 (UC-HSB) from the host's DP_* registers and starts u_hp "
               "(C_HP_*; C_IQ_* commits the IQ16 scene).\n"
               "4  Per frame, u_hp issues the data WRITE work requests and one metadata WRITE-with-immediate; u_iqs supplies "
               "the IQ16 samples (or u_hp makes a counter pattern), u_ptime the timestamps.\n"
               "5  The ConnectX writes the frames into the GPU page ring; RoceReceiverOp hands each completed page to the "
               "Holoscan application (see the application diagram).",
               title_fs=7.6, body_fs=7.0, title_dy=1.8)
    ax.text(88.0, 98.5, "Holoscan Sensor Bridge device mode  —  control plane and data plane",
            ha="center", va="center", fontsize=13.0, weight="bold", color=TXT)
    save(fig, "hsb-device-flow.png")


# -----------------------------------------------------------------------------
# 3. The Holoscan application's operator graph (sw/hsb/rocelet_hsb_app.py,
# RoceletHsbApp.compose(); board control in sw/hsb/rocelet_hsb.py).
# -----------------------------------------------------------------------------
def draw_app_pipeline():
    fig, ax = new_fig(21.5, 9.6, 176, 78)

    # ---- top row: GPU memory <- NIC <- board ----------------------------------------
    titled_box(ax, 2.0, 50.0, 96.0, 15.0, C_PS_FILL, C_PS_EDGE, "GPU memory",
               "page ring: --pages x (frame + 128-byte HSB metadata record), registered with the NIC\n"
               "the board's frame producer writes page after page; the receiver's queue (--queue-size) "
               "holds completed pages",
               title_fs=9.4, body_fs=7.2, title_dy=2.4, lw=1.3)
    titled_box(ax, 106.0, 50.0, 26.0, 15.0, C_GT_FILL, C_GT_EDGE, "ConnectX-6 Dx",
               "UC QP, RoCE v2:\nRDMA WRITE straight\ninto GPU memory",
               title_fs=8.8, body_fs=7.2, title_dy=2.2, lw=1.3)
    titled_box(ax, 140.0, 50.0, 31.0, 15.0, C_FMC_FILL, C_FMC_EDGE,
               "KCU116 + 2x QSFP28 FMC",
               "rocelet, console hsb on\nframe producer: IQ16 or\ncounter frames, QP 13 UC-HSB",
               title_fs=8.8, body_fs=7.2, title_dy=2.2, lw=1.3)
    harrow(ax, 106.0, 98.0, 57.5, "", C_AXARR_FILL, C_AXARR_EDGE, bh=1.0, hh=1.9, hl=1.2)
    harrow(ax, 140.0, 132.0, 57.5, "", C_LINKARR_FILL, C_LINKARR_EDGE, bh=1.0, hh=1.9, hl=1.2)
    ax.text(136.0, 61.8, "100G", ha="center", va="center", fontsize=7.0, color=TXT)

    # ---- middle row: operators ------------------------------------------------------
    op_y0, op_h = 23.0, 18.0
    op_yc = op_y0 + op_h / 2
    titled_box(ax, 2.0, op_y0, 36.0, op_h, C_GT_FILL, C_GT_EDGE, "source  (--source, --api)",
               "RoceReceiverOp (HSB classic API, default)\nor RoceReceiverOp of hololink_module\n"
               "(--api module, the Opsero module)\nor a synthetic source without board / NIC:\n"
               "SyntheticFrameOp (Python), SourceOp (C++)",
               title_fs=8.4, body_fs=7.0, title_dy=2.2)
    titled_box(ax, 44.0, op_y0, 26.0, op_h, C_MAC_FILL, C_MAC_EDGE, "CheckerOp",
               "C++ (cpp/, default) or Python\nevery frame: counter word\nby word, IQ16 sample by\n"
               "sample vs the model; PSN,\nbytes_written, lost frames",
               title_fs=8.8, body_fs=7.0, title_dy=2.2)
    titled_box(ax, 77.0, op_y0, 25.0, op_h, C_MAC_FILL, C_MAC_EDGE, "SpectrogramOp",
               "cuFFT, 4096-point rows\n(Hann), 30 rows a second\n512-row waterfall,\n"
               "newest-row trace, stats", title_fs=8.8, body_fs=7.0, title_dy=2.2)
    titled_box(ax, 108.0, op_y0, 23.0, op_h, C_GT_FILL, C_GT_EDGE, "HolovizOp",
               "a window, or\nwith --headless\nrendered off screen", title_fs=8.8,
               body_fs=7.0, title_dy=2.2)
    titled_box(ax, 138.0, op_y0, 15.0, op_h, C_GT_FILL, C_GT_EDGE, "Format\nConverterOp",
               "RGBA → RGB", title_fs=8.0, body_fs=7.0, title_dy=3.2)
    titled_box(ax, 156.5, op_y0, 15.0, op_h, C_MAC_FILL, C_MAC_EDGE, "PngSinkOp",
               "a PNG every\n--png-every\nrows", title_fs=8.0, body_fs=7.0, title_dy=2.2)
    for x0, x1 in ((38.0, 44.0), (70.0, 77.0), (102.0, 108.0), (131.0, 138.0), (153.0, 156.5)):
        harrow(ax, x0, x1, op_yc, "", C_USER_FILL, C_USER_EDGE, bh=1.0, hh=1.9, hl=1.1)
    vblock(ax, 20.0, 50.0, op_y0 + op_h, C_AXARR_FILL, C_AXARR_EDGE, bw=0.9, hw=1.7,
           hl=1.1, double=False)
    ax.text(22.0, 45.5, "completed page:\nframe tensor + metadata", ha="left", va="center",
            fontsize=7.0, color=C_DATA_LINE, linespacing=1.15)
    vblock(ax, 57.0, 50.0, op_y0 + op_h, C_AXARR_FILL, C_AXARR_EDGE, bw=0.9, hw=1.7,
           hl=1.1, double=False)
    ax.text(59.0, 45.5, "CUDA kernels read\nthe frame in place", ha="left", va="center",
            fontsize=7.0, color=C_DATA_LINE, linespacing=1.15)
    dashed_group(ax, 74.5, 17.5, 98.5, 26.5, "--mode demo (check mode: source and checker only)",
                 ec=C_MAC_EDGE, lab_dy=1.6)
    dashed_group(ax, 135.5, 19.0, 37.0, 24.0, "", ec=C_MAC_EDGE)
    ax.text(154.0, 20.9, "--headless --png-every N", ha="center", va="center", fontsize=7.2,
            weight="bold", color=C_MAC_EDGE)

    # ---- bottom row: start gate + keepalive (register protocol) ----------------------
    titled_box(ax, 2.0, 3.0, 50.0, 13.0, C_MAC_FILL, C_MAC_EDGE, "StartGateOp  (no ports, one tick)",
               "runs after every operator's start() (CUDA kernels, cuFFT\nplans, Holoviz): writes DP_VP_MASK = 1, "
               "the board\nstarts sending (the receiver configured the data plane\nwith DP_VP_MASK clear)",
               title_fs=8.4, body_fs=7.0, title_dy=2.0)
    titled_box(ax, 58.0, 3.0, 40.0, 13.0, C_MAC_FILL, C_MAC_EDGE, "KeepAlive thread  (rocelet_hsb.py)",
               "KEEPALIVE_TIMEOUT_MS (--keepalive,\ndefault 2000 ms), then KEEPALIVE\nevery timeout / 4",
               title_fs=8.4, body_fs=7.0, title_dy=2.0, ls=(0, (4, 2)))
    line(ax, [(27.0, 3.0), (27.0, 1.0), (174.0, 1.0)], C_CTRL_LINE, lw=1.4)
    line(ax, [(78.0, 3.0), (78.0, 1.0)], C_CTRL_LINE, lw=1.4)
    route(ax, [(174.0, 1.0), (174.0, 57.5), (171.0, 57.5)], C_CTRL_LINE, lw=1.4, ms=9)
    ax.text(102.0, 3.2, "HSB register protocol (UDP 8192, through the NIC): DP_VP_MASK, "
            "KEEPALIVE; DP_VP_MASK = 0 at the end", ha="left", va="center", fontsize=7.0,
            color=C_CTRL_LINE)

    legend(ax, 104.0, 75.0, [
        (C_AXARR_FILL, C_AXARR_EDGE, "GPU memory: RDMA WRITE, kernels reading frames"),
        (C_USER_FILL, C_USER_EDGE, "operator messages (frame tensor + metadata)"),
        (None, C_CTRL_LINE, "register writes to the board"),
    ], dy=3.4)
    ax.text(2.0, 74.5, "rocelet_hsb_app.py  —  Holoscan operator graph", ha="left",
            va="center", fontsize=13.0, weight="bold", color=TXT)
    ax.text(2.0, 70.2, "lavender: operators of this repository   cream: NVIDIA HSB / Holoscan "
            "operators (the default source is HSB's RoceReceiverOp) and hardware   dashed: not an operator", ha="left", va="center",
            fontsize=7.2, color=C_MUTED)
    save(fig, "hsb-app-pipeline.png")


# -----------------------------------------------------------------------------
# 4. Beamforming demo, signal chain and control path.
#
# Board side from Vivado/src/hdl/rocelet_sys.sv (u_bms -> u_hp -> rocelet) and
# Vitis/common/src/hsb.c (0x7F000100.. -> C_BM_*); host side from
# sw/beam/rocelet_beam_app.py, beam_gpu.py, beam_ui.py, beam_regs.py;
# definitions in docs/source/beam_contract.md.
# -----------------------------------------------------------------------------
def draw_beam_demo():
    fig, ax = new_fig(21.5, 10.4, 176, 84)

    # ---- groups -----------------------------------------------------------------------
    dashed_group(ax, 2.0, 6.0, 62.0, 64.0, "KCU116 + 2x QSFP28 FMC  (console: hsb on, hsb src beam)",
                 ec=C_FMC_EDGE, fc=C_FMC_FILL, z=1)
    dashed_group(ax, 68.0, 6.0, 107.0, 64.0,
                 "test host (P520): ConnectX-6 Dx, RTX PRO 4000, HSB 3.0.0 container, X session",
                 ec=C_PS_EDGE, z=1)

    # ---- board ------------------------------------------------------------------------
    titled_box(ax, 4.0, 46.0, 26.0, 18.0, C_MAC_FILL, C_MAC_EDGE, "u_bms  array generator",
               "8 x 8 elements, 4 sources\n(CW, LFM pulse, QPSK, pulsed tone)\nsteering + gains + mask:\n"
               "table G[k][s] per APPLY\nnoise per element, gen_clk 200 MHz",
               title_fs=8.6, body_fs=7.0, title_dy=2.2, z=3)
    titled_box(ax, 36.0, 46.0, 26.0, 18.0, C_MAC_FILL, C_MAC_EDGE, "u_hp + rocelet",
               "frame producer: 1 MiB frames\n(4096 time samples x 64 elements)\n+ metadata: scene_id,\n"
               "scene_frame, frame_index\nUC-HSB QP 13, RDMA WRITE",
               title_fs=8.6, body_fs=7.0, title_dy=2.2, z=3)
    harrow(ax, 30.0, 36.0, 55.0, "", C_USER_FILL, C_USER_EDGE, bh=0.9, hh=1.7, hl=1.0)
    ax.text(33.0, 58.6, "beats", ha="center", va="center", fontsize=7.0, color=TXT)
    titled_box(ax, 36.0, 10.0, 26.0, 16.0, C_MAC_FILL, C_MAC_EDGE, "MicroBlaze  hsb.c",
               "HSB register protocol, UDP 8192\n0x7F000100.. → C_BM_* shadow\n"
               "block write pair by pair,\nAPPLY last",
               title_fs=8.6, body_fs=7.0, title_dy=2.2, z=3)
    route(ax, [(36.0, 18.0), (17.0, 18.0), (17.0, 46.0)], C_CTRL_LINE, lw=1.4, ms=9)
    ax.text(18.5, 33.0, "scene words,\nAPPLY: active at\nthe next frame\nboundary (~1.5 us\nto compute)",
            ha="left", va="center", fontsize=7.0, color=C_CTRL_LINE, linespacing=1.15)

    # ---- link -------------------------------------------------------------------------
    harrow(ax, 62.0, 72.0, 55.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, bh=1.0, hh=1.9, hl=1.2)
    ax.text(67.0, 59.2, "100G", ha="center", va="center", fontsize=7.2, weight="bold", color=TXT)

    # ---- host, top row: NIC -> GPU memory, tablet page --------------------------------
    titled_box(ax, 72.0, 46.0, 20.0, 18.0, C_GT_FILL, C_GT_EDGE, "ConnectX-6 Dx",
               "RoCE v2, UC QP\nRDMA WRITE straight\ninto GPU memory\n(no CPU copy)",
               title_fs=8.6, body_fs=7.0, title_dy=2.2, z=3)
    titled_box(ax, 98.0, 46.0, 32.0, 18.0, C_PS_FILL, C_PS_EDGE, "GPU memory",
               "page ring: 64 x (1 MiB frame +\n128-byte metadata record)\n"
               "~7,600 frames/s at 64 Gb/s;\nthe app takes the newest one",
               title_fs=8.6, body_fs=7.0, title_dy=2.2, z=3)
    harrow(ax, 92.0, 98.0, 55.0, "", C_AXARR_FILL, C_AXARR_EDGE, bh=1.0, hh=1.9, hl=1.2)
    titled_box(ax, 136.0, 46.0, 36.0, 18.0, C_MAC_FILL, C_MAC_EDGE, "tablet / phone page",
               "web page served by the app\n(--web 8090): the sky picture\nat a low rate + the same controls",
               title_fs=8.6, body_fs=7.0, title_dy=2.2, ls=(0, (4, 2)), z=3)

    # ---- host, middle row: operators ----------------------------------------------------
    op_y0, op_h = 30.0, 12.0
    op_yc = op_y0 + op_h / 2
    titled_box(ax, 72.0, op_y0, 20.0, op_h, C_GT_FILL, C_GT_EDGE, "RoceReceiverOp",
               "HSB classic API;\ncompleted page →\nframe + metadata",
               title_fs=8.2, body_fs=7.0, title_dy=2.0, z=3)
    titled_box(ax, 98.0, op_y0, 32.0, op_h, C_MAC_FILL, C_MAC_EDGE, "beamformer  (CuPy)",
               "R = X X^H / T; Bartlett or MVDR sky (128 x 128)\nsteered beam: pattern + cuFFT "
               "spectrum\ncalibration, --verify, latency",
               title_fs=8.2, body_fs=7.0, title_dy=2.0, z=3)
    titled_box(ax, 136.0, op_y0, 14.0, op_h, C_MAC_FILL, C_MAC_EDGE, "VizRelayOp",
               "newest image\nwins", title_fs=8.2, body_fs=7.0, title_dy=2.0, z=3)
    titled_box(ax, 154.0, op_y0, 18.0, op_h, C_GT_FILL, C_GT_EDGE, "HolovizOp",
               "window on the\nmonitor (60 Hz)", title_fs=8.2, body_fs=7.0, title_dy=2.0, z=3)
    for x0, x1 in ((92.0, 98.0), (130.0, 136.0), (150.0, 154.0)):
        harrow(ax, x0, x1, op_yc, "", C_USER_FILL, C_USER_EDGE, bh=0.9, hh=1.7, hl=1.0)
    vblock(ax, 82.0, 46.0, op_y0 + op_h, C_AXARR_FILL, C_AXARR_EDGE, bw=0.8, hw=1.5, hl=1.0,
           double=False)
    vblock(ax, 114.0, 46.0, op_y0 + op_h, C_AXARR_FILL, C_AXARR_EDGE, bw=0.8, hw=1.5, hl=1.0,
           double=False)
    ax.text(112.0, 44.0, "kernels read the\nframe in place", ha="right", va="center",
            fontsize=7.0, color=C_DATA_LINE, linespacing=1.1)
    route(ax, [(127.0, op_y0 + op_h), (127.0, 44.0), (150.0, 44.0), (150.0, 46.0)],
          C_USER_EDGE, lw=1.3, ms=8)

    # ---- host, bottom row: input -> scene writer -> board -------------------------------
    titled_box(ax, 136.0, 10.0, 36.0, 14.0, C_MAC_FILL, C_MAC_EDGE, "interaction  (beam_ui.py)",
               "mouse, wheel, keys (Holoviz callbacks),\ntablet input, attract mode;\n"
               "coalesced to 20 scene writes/s",
               title_fs=8.2, body_fs=7.0, title_dy=2.0, z=3)
    titled_box(ax, 98.0, 10.0, 32.0, 14.0, C_MAC_FILL, C_MAC_EDGE, "scene writer  (beam_regs.py)",
               "one WR_BLOCK per change: changed\nwords, SCENE_ID, APPLY last\n"
               "(drag = 4 words, 0.09 ms)",
               title_fs=8.2, body_fs=7.0, title_dy=2.0, z=3)
    route(ax, [(163.0, op_y0), (163.0, 24.0)], C_CTRL_LINE, lw=1.3, ms=8)
    route(ax, [(172.0, 55.0), (173.3, 55.0), (173.3, 17.0), (172.0, 17.0)], C_CTRL_LINE, lw=1.3,
          ms=8, ls=(0, (4, 2)))
    route(ax, [(136.0, 17.0), (130.0, 17.0)], C_CTRL_LINE, lw=1.4, ms=9)
    route(ax, [(98.0, 17.0), (62.0, 17.0)], C_CTRL_LINE, lw=1.6, ms=10)
    ax.text(80.0, 20.6, "HSB register protocol\n(UDP 8192, same 100G link)", ha="center",
            va="center", fontsize=7.0, color=C_CTRL_LINE, linespacing=1.15)
    ax.text(80.0, 12.6, "scene_id comes back in\nthe frames' metadata:\nmouse-to-data measured",
            ha="center", va="center", fontsize=7.0, color=C_MUTED, linespacing=1.15)

    legend(ax, 118.0, 82.0, [
        (C_LINKARR_FILL, C_LINKARR_EDGE, "100G link (RoCE v2 frames and register protocol)"),
        (C_AXARR_FILL, C_AXARR_EDGE, "GPU memory: RDMA WRITE, kernels reading frames"),
        (C_USER_FILL, C_USER_EDGE, "samples / operator messages"),
        (None, C_CTRL_LINE, "control path: scene changes back to the FPGA"),
    ], dy=3.1)
    ax.text(2.0, 80.5, "Beamforming demo  —  signal chain and control path", ha="left",
            va="center", fontsize=13.0, weight="bold", color=TXT)
    ax.text(2.0, 76.2, "lavender: logic and software of this repository   cream: AMD / NVIDIA "
            "components used as they are   dashed box: the tablet page", ha="left", va="center",
            fontsize=7.2, color=C_MUTED)
    save(fig, "beam-demo-flow.png")


def main():
    draw_block()
    draw_zynqmp()
    draw_device_flow()
    draw_app_pipeline()
    draw_beam_demo()


if __name__ == "__main__":
    main()
