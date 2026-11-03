#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# rocelet_hsb.py - receive frames from the qsfp28-fmc-rocelet design's Holoscan Sensor Bridge
# (HSB) device mode with the HSB 3.0.0 host software ("classic" hololink Python API) and a
# Linux-UDP receiver (no RDMA, no GPU registration; any NIC). Runs inside NVIDIA's HSB
# container (hololink-demo:3.0.0) with --net host. See README.md in this directory.
#
#   python3 rocelet_hsb.py --enumerate               # list HSB devices for 5 s
#   python3 rocelet_hsb.py --read 0x80               # one register read (HSB_IP_VERSION)
#   python3 rocelet_hsb.py --frames 100              # counter frames, checked word by word
#   python3 rocelet_hsb.py --source iq --frames 100  # IQ16 frames (size / sequence only)
#
# The board: console 'hsb on' (192.168.20.2 by default). The host interface must be on the
# board's subnet and run MTU >= 4200 for 4096-byte payloads (--mtu, DataChannel.use_mtu).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import argparse
import os
import signal
import socket
import sys
import threading
import time

import numpy as np

import cuda.bindings.driver as cuda
import hololink as hololink_module

UUID = "98183d0f-18ee-4719-a3b4-ca69e9b94c97"   # qsfp28-fmc-rocelet (KCU116 + OP120), compat 0x2603
OPS = 0x7F000000                                 # Opsero registers (firmware Vitis/common/src/hsb_regs.h):
OPS_SOURCE = OPS + 0x04                          #   0 IQ16, 1 counter (next data-plane enable)
OPS_RATE_MBPS = OPS + 0x08                       #   frame rate limit, Mb/s (frame + 128-B record), 0 = none
OPS_SCENE = OPS + 0x0C                           #   IQ16 scene 1-4
OPS_FRAMES = OPS + 0x10                          #   RO frames since the producer last started
OPS_STATUS = OPS + 0x14                          #   RO [0] running [1] DP on [2] link-paused [3] link pause on [4] keepalive armed
OPS_KEEPALIVE_TIMEOUT_MS = OPS + 0x20            #   RW 0 = off; one-shot producer watchdog (cleared by HSB reset)
OPS_KEEPALIVE = OPS + 0x24                       #   W restarts the timer; R ms since the last restart
OPS_WATCHDOG_COUNT = OPS + 0x28                  #   RO watchdog stops since 'hsb on'
OPS_LINKPAUSE_COUNT = OPS + 0x2C                 #   RO link pauses since 'hsb on'
DP_VP_MASK = 0x0200030C                          # data plane 0: bit 0 = sensor 0 enabled (0 stops the board)


def check(r):
    if r != 0:
        raise RuntimeError(f"CUDA error {r}")


def primary_context():
    (r,) = cuda.cuInit(0)
    check(r)
    r, dev = cuda.cuDeviceGet(0)
    check(r)
    r, ctx = cuda.cuDevicePrimaryCtxRetain(dev)
    check(r)
    cuda.cuCtxSetCurrent(ctx)
    return ctx


def set_strategy():
    """1 sensor, 1 data plane, 1 SIF per sensor (without this an unknown UUID gets 2/2/2)."""
    hololink_module.Enumerator.set_uuid_strategy(
        UUID, hololink_module.BasicEnumerationStrategy(total_sensors=1, total_dataplanes=1, sifs_per_sensor=1))


def connect(ip, mtu, timeout_s=10.0, deferred_start=False):
    """Find the board by its IP, select the packet size (use_mtu) and start the register
    protocol. Returns (DataChannel, Hololink); the caller calls hl.stop() at the end.
    deferred_start: the DataChannel gets vp_mask 0, so DataChannel.configure_roce (run by the
    receiver operator when the graph starts) programs the data plane but leaves DP_VP_MASK alone;
    the application enables the board with start_data_plane() once its pipeline is ready (and
    stops it with stop_data_plane(): unconfigure() no longer clears the bit)."""
    set_strategy()
    md = hololink_module.Enumerator.find_channel(channel_ip=ip, timeout=hololink_module.Timeout(timeout_s))
    hololink_module.DataChannel.use_mtu(md, mtu)
    if deferred_start:
        md.update(hololink_module.Metadata({"vp_mask": 0}))    # classic Metadata has no item assignment
    dc = hololink_module.DataChannel(md)
    hl = dc.hololink()
    hl.start()
    return dc, hl


class ModuleRegisters:
    """The register calls of the classic Hololink object (write_uint32 / read_uint32 / reset / stop)
    on top of the module API's HololinkInterfaceV1, so the helpers here work with both APIs."""

    def __init__(self, hl):
        self.hl = hl

    def write_uint32(self, addr, value):
        r = self.hl.write_uint32([addr], [value])
        if r not in (0, None):
            raise RuntimeError(f"write 0x{addr:08x}: status {r}")

    def read_uint32(self, addr):
        return self.hl.read_uint32([addr])[0]

    def reset(self):
        self.hl.reset()

    def start(self):
        self.hl.start()

    def stop(self):
        self.hl.stop()

    def get_hsb_ip_version(self):
        return self.read_uint32(0x80)

    def get_fpga_date(self):
        return self.read_uint32(0x84)


def connect_module(ip, mtu, module_dir=None, timeout_s=10.0, deferred_start=False):
    """Module API (hololink_module): wait for the board's announcement, which the Adapter hands to
    the Opsero module (hololink_<UUID>_2603.so from module_dir, $HOLOLINK_MODULE_DIR or
    <site-packages>/lib/hololink/modules), select the MTU, start the control plane. Returns
    (enumeration metadata, ModuleRegisters). Without the module the metadata comes back
    unenriched and the data channel services are missing: that is reported here."""
    import hololink_module as hm
    ad = hm.Adapter.get_adapter()
    if module_dir:
        ad.set_module_directory(module_dir)
    md = ad.wait_for_channel(ip, timeout_s)
    if "module_filename" not in md:
        raise RuntimeError(f"no hololink module for UUID {md.get('fpga_uuid')} compat 0x{md.get('compat_id', 0):04x}: "
                           f"build sw/hsb/module and set HOLOLINK_MODULE_DIR (or --module-dir)")
    ad.use_mtu(md, mtu)
    if deferred_start:
        md["vp_mask"] = 0           # the module's RoCE data channel leaves DP_VP_MASK alone (see connect)
    hl = hm.HololinkInterfaceV1.get_service(md)
    regs = ModuleRegisters(hl)
    regs.start()
    return md, regs


def start_data_plane(hl):
    """DP_VP_MASK bit 0 = 1: the board starts sending (after a deferred_start configure)."""
    hl.write_uint32(DP_VP_MASK, 1)


def set_keepalive(hl, timeout_ms):
    """Arm the board's producer watchdog: with the data plane enabled, the board stops sending when
    no keepalive arrived for timeout_ms (one-shot; cleared by an HSB reset, so write it after
    Hololink.reset() and before the data plane starts). 0 = off."""
    hl.write_uint32(OPS_KEEPALIVE_TIMEOUT_MS, int(timeout_ms))


class KeepAlive:
    """Writes the board's KEEPALIVE register every timeout/4 from a thread, so a killed or hung
    host lets the board stop by itself after timeout_ms."""

    def __init__(self, hl, timeout_ms):
        self.hl, self.period = hl, timeout_ms / 4000.0
        self.ev = threading.Event()
        self.writes = self.errors = 0
        self.th = threading.Thread(target=self.run, name="keepalive", daemon=True)

    def start(self):
        self.th.start()
        return self

    def run(self):
        while not self.ev.wait(self.period):
            try:
                self.hl.write_uint32(OPS_KEEPALIVE, 1)
                self.writes += 1
            except Exception as e:          # keep trying: one lost request is not fatal
                self.errors += 1
                if self.errors <= 3:
                    print(f"keepalive write failed: {e}", flush=True)

    def stop(self):
        self.ev.set()
        self.th.join(timeout=2)


def board_counters(hl):
    """STATUS, keepalive and the watchdog / link-pause counters (dict; empty if unreadable)."""
    try:
        st = hl.read_uint32(OPS_STATUS)
        return dict(status=st, running=bool(st & 1), dp_enabled=bool(st & 2), link_paused=bool(st & 4),
                    link_pause_on=bool(st & 8), keepalive_armed=bool(st & 16),
                    keepalive_timeout_ms=hl.read_uint32(OPS_KEEPALIVE_TIMEOUT_MS),
                    keepalive_age_ms=hl.read_uint32(OPS_KEEPALIVE),
                    watchdog_count=hl.read_uint32(OPS_WATCHDOG_COUNT),
                    linkpause_count=hl.read_uint32(OPS_LINKPAUSE_COUNT), frames=hl.read_uint32(OPS_FRAMES))
    except Exception as e:
        return dict(error=str(e))


def select_source(hl, source, rate_mbps, scene):
    """Opsero registers, applied at the next data-plane enable: source ("counter" or "iq"),
    frame rate limit in Mb/s (frame + 128-byte metadata; 0 = none), IQ16 scene 1-4."""
    hl.write_uint32(OPS_SOURCE, 1 if source == "counter" else 0)
    hl.write_uint32(OPS_RATE_MBPS, rate_mbps)
    hl.write_uint32(OPS_SCENE, scene)


def stop_data_plane(hl):
    """DP_VP_MASK 0: the board stops at the next frame boundary (what DataChannel.unconfigure
    does; also usable when the DataChannel is gone)."""
    hl.write_uint32(DP_VP_MASK, 0)


def main():
    ap = argparse.ArgumentParser(description="qsfp28-fmc-rocelet HSB host example (HSB 3.0.0 classic API)")
    ap.add_argument("--ip", default="192.168.20.2", help="board IP (console 'st' / 'hsb st')")
    ap.add_argument("--enumerate", action="store_true", help="print the BOOTP announcements for 5 s and exit")
    ap.add_argument("--read", type=lambda s: int(s, 0), help="read one register and exit")
    ap.add_argument("--write", nargs=2, type=lambda s: int(s, 0), metavar=("ADDR", "VALUE"),
                    help="write one register, read it back and exit")
    ap.add_argument("--frame-size", type=int, default=1 << 20, help="frame bytes (default 1 MiB)")
    ap.add_argument("--pages", type=int, default=4, help="receive buffers (pages)")
    ap.add_argument("--frames", type=int, default=100, help="frames to receive")
    ap.add_argument("--mtu", type=int, default=4200, help="DataChannel.use_mtu (4200 -> 4096-byte packets)")
    ap.add_argument("--source", choices=["counter", "iq"], default="counter")
    ap.add_argument("--rate-mbps", type=int, default=1000, help="board frame rate limit, Mb/s (0 = none)")
    ap.add_argument("--scene", type=int, default=1, help="IQ16 scene 1 survey 2 radar 3 tones 4 noise")
    ap.add_argument("--timeout-ms", type=int, default=2000)
    ap.add_argument("--keepalive", type=int, default=2000,
                    help="board watchdog, ms: the board stops sending when this script stops writing its keepalive "
                         "register (killed, hung); 0 = off")
    ap.add_argument("--rcvbuf", type=int, default=64 << 20,
                    help="socket receive buffer, bytes (SO_RCVBUFFORCE in the privileged container, else SO_RCVBUF)")
    a = ap.parse_args()
    # SIGTERM (docker stop, timeout) runs the finally blocks: the data plane is switched off
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))

    set_strategy()

    if a.enumerate:
        t_end = time.time() + 5

        def cb(md):
            print(md)      # peer_ip, mac_id, serial_number, fpga_uuid, hsb_ip_version, data_plane, interface, ...
            return time.time() < t_end
        hololink_module.Enumerator.enumerated(cb, hololink_module.Timeout(6.0))
        return 0

    dc, hl = connect(a.ip, a.mtu)
    try:
        if a.read is not None or a.write is not None:
            if a.write is not None:
                hl.write_uint32(a.write[0], a.write[1])
                print(f"write 0x{a.write[0]:08x} = 0x{a.write[1]:08x}")
            addr = a.read if a.read is not None else a.write[0]
            print(f"read 0x{addr:08x} = 0x{hl.read_uint32(addr):08x}")
            return 0
        hl.reset()
        print(f"HSB IP version 0x{hl.get_hsb_ip_version():04x}, FPGA date 0x{hl.get_fpga_date():08x}")
        select_source(hl, a.source, a.rate_mbps, a.scene)
        ka = None
        if a.keepalive:
            set_keepalive(hl, a.keepalive)       # after reset() (which clears it), before the data plane starts
            ka = KeepAlive(hl, a.keepalive).start()
        try:
            return receive(a, dc)
        finally:
            if ka:
                ka.stop()
            print(f"board: {board_counters(hl)}")
    finally:
        hl.stop()


def receive(a, dc):
    frame_size, pages = a.frame_size, a.pages
    md_off = hololink_module.round_up(frame_size, hololink_module.PAGE_SIZE)
    page_size = md_off + hololink_module.METADATA_SIZE
    buf_size = hololink_module.round_up(page_size * pages, os.sysconf("SC_PAGESIZE"))
    ctx = primary_context()
    mem = hololink_module.ReceiverMemoryDescriptor(ctx, buf_size)
    cu_buf = mem.get()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # A frame arrives as a line-rate burst (1 MiB in ~90 us), whatever the frame rate: the socket
    # must hold a few frames or the kernel drops packets (net.core.rmem_max is 208 KB by default).
    try:
        sock.setsockopt(socket.SOL_SOCKET, 33, a.rcvbuf)              # SO_RCVBUFFORCE (CAP_NET_ADMIN)
    except OSError:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, a.rcvbuf)  # capped by net.core.rmem_max
    got_buf = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    if got_buf < 2 * page_size:
        print(f"warning: socket receive buffer {got_buf} B < 2 frames; expect drops "
              f"(run the container --privileged or raise net.core.rmem_max)")
    dc.configure_socket(sock.fileno())
    rx = hololink_module.operators.LinuxReceiver(
        cu_buffer=cu_buf, cu_buffer_size=buf_size, cu_page_size=page_size, pages=pages,
        socket=sock.fileno(), received_address_offset=cu_buf, queue_size=1)

    def run():
        cuda.cuCtxSetCurrent(ctx)
        rx.run()
    th = threading.Thread(target=run, daemon=True)
    th.start()                       # the receiver runs before the board starts sending
    dc.authenticate(rx.get_qp_number(), rx.get_rkey())

    words = frame_size // 8
    ramp = np.arange(words, dtype=np.uint64) * np.uint64(8)
    host = bytearray(frame_size)
    got = bad = gaps = drops = psn_bad = size_bad = 0
    last_fn = drop0 = None
    t0 = None
    try:
        dc.configure_roce(0, frame_size, page_size, pages, sock.getsockname()[1])
        for i in range(a.frames):
            ok, m = rx.get_next_frame(a.timeout_ms, 0)
            if not ok:
                print(f"timeout waiting for frame {i}")
                break
            if t0 is None:
                t0 = time.time()
            got += 1
            # packets_dropped counts PSN gaps since the receiver started (cumulative)
            if drop0 is None:
                drop0 = m.packets_dropped
            drops = m.packets_dropped - drop0
            # the metadata record's PSN is the PSN of the packet that carried it (imm[31:12])
            if (m.psn & 0xFFFFF) != (m.imm_data >> 12) & 0xFFFFF:
                psn_bad += 1
            if m.bytes_written != frame_size:
                size_bad += 1
            if m.frame_bytes_received != frame_size + hololink_module.METADATA_SIZE and \
               m.frame_bytes_received != frame_size:
                print(f"frame {i}: {m.frame_bytes_received} bytes received")
            if a.source == "counter":
                (r,) = cuda.cuMemcpyDtoH(host, m.frame_memory, frame_size)
                check(r)
                w = np.frombuffer(host, dtype="<u8", count=words)
                fn = int(w[0] >> np.uint64(48))
                exp = (np.uint64(fn) << np.uint64(48)) | ramp
                n = int(np.count_nonzero(w != exp))
                if n:
                    bad += 1
                    print(f"frame {i} (number {fn}): {n} of {words} words differ")
                if last_fn is not None and fn != (last_fn + 1) & 0xFFFF:
                    gaps += 1
                last_fn = fn
    finally:
        dt = (time.time() - t0) if t0 else 0
        try:
            dc.unconfigure()             # DP_VP_MASK 0: the board stops at the next frame
        except Exception as e:
            print(f"unconfigure: {e} (the board may still send: 'hsb off' on the console stops it)")
        rx.close()
        th.join(timeout=5)
        sock.close()
    fps = (got - 1) / dt if dt > 0 and got > 1 else 0
    print(f"{got} frames of {frame_size} B ({a.source}): {bad} with pattern errors, {gaps} frame-number gaps, "
          f"{drops} packets dropped, {psn_bad} metadata PSN errors, {size_bad} bytes_written errors, "
          f"{fps:.1f} frames/s = {fps * frame_size * 8 / 1e9:.2f} Gb/s")
    ok = got == a.frames and bad == 0 and gaps == 0 and drops == 0 and psn_bad == 0 and size_bad == 0
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
