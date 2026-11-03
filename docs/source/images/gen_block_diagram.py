#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""
Generate the diagrams for the qsfp28-fmc-rocelet docs.

    rocelet-block.png        the whole kcu116 design: MicroBlaze system, clocking,
                             rocelet_sys (engine, memory window, work-request
                             sources, control-plane FIFO, raw TX / capture, system
                             registers, self-test logic, HSB device side), the CMAC
                             and its GTY quad, the 2x QSFP28 FMC (OP120)
                             (Vivado/src/bd/bd_microblaze.tcl,
                             Vivado/src/hdl/rocelet_sys.sv,
                             Vivado/src/constraints/kcu116.xdc)
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
    harrow(ax, 73.0, 79.0, 38.5, "", C_USER_FILL, C_USER_EDGE, bh=0.7, hh=1.3, hl=0.9)
    harrow(ax, 73.0, 79.0, 32.5, "", C_USER_FILL, C_USER_EDGE, bh=0.7, hh=1.3, hl=0.9)
    ax.text(76.0, 41.2, "IQ16", ha="center", va="center", fontsize=7.0, color=TXT)
    ax.text(76.0, 29.6, "beam", ha="center", va="center", fontsize=7.0, color=TXT)
    route(ax, [(90.25, 27.5), (90.25, 30.0)], C_THIN, lw=1.1, ms=7)
    vblock(ax, 91.0, 41.0, mux_y0, C_USER_FILL, C_USER_EDGE, bw=0.8, hw=1.5, hl=0.9,
           double=False)
    # gen_clk (orange) from clk_wiz_0 clk_out2
    route(ax, [(49.0, 25.0), (56.0, 25.0)], C_REFCLK_LINE, lw=1.3, ms=8)
    route(ax, [(53.5, 25.0), (53.5, 38.5), (56.0, 38.5)], C_REFCLK_LINE, lw=1.3, ms=8)
    route(ax, [(53.5, 32.5), (56.0, 32.5)], C_REFCLK_LINE, lw=1.3, ms=8)
    clk_tag(ax, 54.3, 28.75, "gen_clk  200 MHz", fs=7.0, ha="left")

    # CMAC <-> u_regs sideband (ctl_* / stat_*)
    line(ax, [(72.25, top_y0 + top_h), (72.25, 100.5), (132.5, 100.5)], C_THIN, lw=1.1)
    route(ax, [(132.5, 100.5), (132.5, 87.0), (132.5, 86.0)], C_THIN, lw=1.1, ms=7)
    ax.text(133.5, 94.0, "ctl_* / stat_*\n(enables, RS-FEC,\nPAUSE, loopback;\nalignment, faults,\ncounters)",
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
    ax.text(ps_x0 + ps_w / 2, 85.0, "MicroBlaze", ha="center", va="center",
            fontsize=11.0, weight="bold", color=TXT)
    ax.text(ps_x0 + ps_w / 2, 52.0,
            "firmware\nVitis/common/src/hsb.c\n(console: hsb on)\n\n"
            "BOOTP announcement\nonce a second\n\nUDP 8192 server:\nHSB register file,\n"
            "Opsero registers\n\nDP_* registers →\nQP 13 + producer\n\n"
            "keepalive watchdog,\nlink pause",
            ha="center", va="center", fontsize=7.4, color=TXT, linespacing=1.35)

    # ---- fabric -----------------------------------------------------------------
    fab_x0, fab_x1 = 26.0, 123.0
    ax.add_patch(plt.Rectangle((fab_x0, 15.0), fab_x1 - fab_x0, 77.0,
                               fc=C_FAB_FILL, ec=C_FAB_EDGE, lw=1.3, zorder=1))
    ax.text((fab_x0 + fab_x1) / 2, 93.0, "FPGA: rocelet_sys and the CMAC  (CMAC user clock 322.27 MHz)",
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

    # CMAC
    titled_box(ax, 108.5, 34.0, 12.0, 32.0, C_GT_FILL, C_GT_EDGE, "CMAC",
               "+ GTY x4\n\n100G\nCAUI-4\nRS-FEC", title_fs=8.8, body_fs=7.2,
               title_dy=2.2, lw=1.3)
    harrow(ax, eng_x1, 108.5, 50.0, "", C_USER_FILL, C_USER_EDGE, double=True, bh=1.0,
           hh=1.9, hl=1.0)

    # ---- FMC + cable ------------------------------------------------------------
    titled_box(ax, 126.0, 40.0, 10.0, 20.0, C_FMC_FILL, C_FMC_EDGE, "OP120",
               "QSFP28\nport 0", title_fs=8.4, body_fs=7.2, title_dy=2.0, lw=1.3)
    harrow(ax, 120.5, 126.0, 50.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, double=True,
           bh=0.9, hh=1.7, hl=1.0)
    harrow(ax, 136.0, 143.5, 50.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, double=True,
           bh=0.9, hh=1.7, hl=1.0)
    ax.text(139.75, 54.4, "100G\ncable", ha="center", va="center", fontsize=7.0,
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
               "100G, RoCE v2\nUC QP (the host side of QP 13)",
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
    draw_device_flow()
    draw_app_pipeline()
    draw_beam_demo()


if __name__ == "__main__":
    main()
