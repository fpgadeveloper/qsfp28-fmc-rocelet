#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_module.py - tests of the Opsero hololink_module (qsfp28-fmc-rocelet) without the board,
# inside NVIDIA's HSB container (hololink-demo:3.0.0), default bridge network (no --net host).
#
#   pytest -v test_module.py --module-dir build/lib/hololink/modules
#   python3 test_module.py --module-dir build/lib/hololink/modules      (same, no pytest needed)
#
# 1. enumeration: an announcement with the board's UUID + compat-id 0x2603 handed to the module
#    API's Adapter loads hololink_98183d0f-..._2603.so and comes back enriched (module name,
#    sensor 0 on data plane 0: vp_mask, sif / vp / hif addresses, data_channel); sensor 1 is
#    refused; an announcement from data plane 1 is skipped; another UUID gets no module.
# 2. emulator (needs root in the container: raw sockets): NVIDIA's HSB emulator announces the board's UUID / compat-id over BOOTP on the
#    container's loopback; the module API finds it (wait_for_channel), the module's control
#    plane reads HSB_IP_VERSION, and the module's Linux data
#    channel + LinuxReceiverOp receive counter frames the emulator sends (no RDMA).
# 3. start gate (rocelet_hsb.connect[_module](deferred_start=True), module and classic API): the receiver's configure leaves
#    DP_VP_MASK clear, the application's start_data_plane() sets it, stop clears it.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import argparse
import os
import subprocess
import sys
import textwrap
import time

UUID = "98183d0f-18ee-4719-a3b4-ca69e9b94c97"
COMPAT = 0x2603
SO = f"hololink_{UUID}_{COMPAT:04x}.so"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DIR = os.path.join(HERE, "build", "lib", "hololink", "modules")
EMU_IP = "127.0.0.1"

_module_dir = os.environ.get("ROCELET_MODULE_DIR", DEFAULT_DIR)


def module_dir():
    return _module_dir


def adapter():
    import hololink_module
    ad = hololink_module.Adapter.get_adapter()
    ad.set_module_directory(module_dir())
    return ad


def announce(ad, uuid=UUID, compat=COMPAT, data_plane=0, peer_ip="192.168.20.2"):
    """Hand one decoded BOOTP announcement to the Adapter, return what subscribers see (or None)."""
    import hololink_module
    md = hololink_module.EnumerationMetadata()
    for k, v in dict(fpga_uuid=uuid, compat_id=compat, hsb_ip_version=compat, data_plane=data_plane,
                     serial_number="6067E71620A204", peer_ip=peer_ip, interface="lo",
                     mac_id="02:0A:35:72:6C:01", enumeration_version=2, fpga_crc=0,
                     transmitted_packet_count=1).items():
        md[k] = v
    got = []
    h = ad.register_ip(peer_ip, lambda m: got.append(hololink_module.EnumerationMetadata(m)))
    try:
        ad.enumerate(md)
    finally:
        ad.unregister(h)
    return got[0] if got else None


def test_module_file():
    p = os.path.join(module_dir(), SO)
    assert os.path.isfile(p), f"{p} missing: build it with build.sh"


def test_enumeration_enriched():
    ad = adapter()
    md = announce(ad)
    assert md is not None, "announcement not delivered"
    assert md["module_filename"].endswith(SO), md.get("module_filename")
    assert md["module_name"] == "opsero_rocelet"
    expect = dict(sensor_number=0, sensor=0, vp_mask=1, sif_address=0x01000000, vp_address=0x1000,
                  hif_address=0x02000300, data_channel=0, frame_end_event=16)
    for k, v in expect.items():
        assert md[k] == v, f"{k} = {md.get(k)}, expected {v}"
    print("enriched:", {k: md[k] for k in ("module_name", "module_filename", *expect)})


def test_sensor_range():
    import hololink_module
    ad = adapter()
    md = announce(ad)
    ad.use_sensor(md, 0)
    try:
        ad.use_sensor(md, 1)
    except Exception as e:                       # the module's ChannelConfiguration refuses
        assert "out of range" in str(e), e
    else:
        raise AssertionError("sensor 1 accepted")
    ad.use_mtu(md, 4200)
    assert md["mtu"] == 4200
    assert isinstance(md, hololink_module.EnumerationMetadata)


def test_data_plane_1_skipped():
    assert announce(adapter(), data_plane=1, peer_ip="192.168.20.3") is None


def test_other_uuid_unenriched():
    md = announce(adapter(), uuid="00000000-1111-2222-3333-444444444444", peer_ip="192.168.20.4")
    assert md is not None and "module_filename" not in md and "vp_mask" not in md


EMULATOR = textwrap.dedent("""
    import sys, time
    import numpy as np
    import hololink.emulation as hemu
    uuid, compat, ip, frame, n = sys.argv[1], int(sys.argv[2], 0), sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
    cfg = hemu.HSBConfiguration(hemu.HSB_EMULATOR_CONFIG) if hasattr(hemu.HSBConfiguration, "__copy__") else hemu.HSB_EMULATOR_CONFIG
    cfg.uuid = uuid
    cfg.board_id_lo, cfg.board_id_hi = compat & 0xFF, compat >> 8
    cfg.hsb_ip_version = compat
    cfg.serial_num = "ROCELET"
    hsb = hemu.HSBEmulator(cfg)
    dp = hemu.LinuxDataPlane(hsb, hemu.IPAddress(ip), 0, 0)
    hsb.start()
    words = frame // 8
    sent = 0
    t_end = time.time() + 60
    print("emulator up", flush=True)
    while time.time() < t_end and sent < n:
        f = (np.uint64(sent & 0xFFFF) << np.uint64(48)) | (np.arange(words, dtype=np.uint64) * np.uint64(8))
        if dp.send(f.view(np.uint8)) > 0:
            sent += 1
        time.sleep(0.01)
    print(f"emulator sent {sent}", flush=True)
    time.sleep(1)
    hsb.stop()
""")


def test_emulator_end_to_end(frames=20, frame_size=65536):
    import cuda.bindings.driver as cuda
    import holoscan
    import hololink_module
    import hololink_module.operators
    import numpy as np

    emu = subprocess.Popen([sys.executable, "-c", EMULATOR, UUID, hex(COMPAT), EMU_IP, str(frame_size),
                            str(frames * 50)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        ad = adapter()
        md = ad.wait_for_channel(EMU_IP, 15.0)
        assert md["module_filename"].endswith(SO), md.get("module_filename")
        assert md["module_name"] == "opsero_rocelet" and md["vp_mask"] == 1
        hl = hololink_module.HololinkInterfaceV1.get_service(md)
        hl.start()
        try:
            hl.reset()
            ver = hl.read_uint32([0x80])[0]
            assert ver == COMPAT, hex(ver)
            (r,) = cuda.cuInit(0)
            r, dev = cuda.cuDeviceGet(0)
            r, ctx = cuda.cuDevicePrimaryCtxRetain(dev)
            got = []

            class Sink(holoscan.core.Operator):
                def setup(self, spec):
                    spec.input("in")

                def compute(self, op_input, op_output, context):
                    import cupy as cp
                    t = op_input.receive("in")[""]
                    w = cp.asarray(t).view(cp.uint64).get()
                    fn = int(w[0] >> np.uint64(48))
                    exp = (np.uint64(fn) << np.uint64(48)) | (np.arange(len(w), dtype=np.uint64) * np.uint64(8))
                    got.append((fn, int(np.count_nonzero(w != exp)), int(self.metadata.get("frame_number", -1))))

            class App(holoscan.core.Application):
                def compose(self):
                    rx = hololink_module.operators.LinuxReceiverOp(
                        self, holoscan.conditions.CountCondition(self, count=frames), name="receiver",
                        enumeration_metadata=md, frame_context=int(ctx), frame_size=frame_size)
                    self.add_flow(rx, Sink(self, name="sink"), {("output", "in")})

            app = App()
            app.is_metadata_enabled = True
            app.run()
        finally:
            hl.stop()
        assert len(got) == frames, got
        assert all(bad == 0 for _, bad, _ in got), got
        print(f"emulator: HSB_IP_VERSION 0x{ver:04x}, {len(got)} frames of {frame_size} B through the module's "
              f"Linux data channel, 0 word errors, frame numbers {got[0][0]}..{got[-1][0]}")
    finally:
        emu.kill()
        out = emu.communicate(timeout=10)[0]
        if "Traceback" in out:
            print(out)


def test_emulator_deferred_start(frames=10, frame_size=65536):
    """The start gate on both host APIs: with vp_mask 0 in the metadata the receiver's configure
    leaves DP_VP_MASK clear (read back in device_start), the application sets it, frames flow."""
    import cuda.bindings.driver as cuda
    import holoscan
    import hololink_module
    import hololink_module.operators
    sys.path.insert(0, os.path.dirname(HERE))
    import rocelet_hsb

    emu = subprocess.Popen([sys.executable, "-c", EMULATOR, UUID, hex(COMPAT), EMU_IP, str(frame_size),
                            str(frames * 50)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        md, regs = rocelet_hsb.connect_module(EMU_IP, 1500, module_dir(), timeout_s=15.0, deferred_start=True)
        regs.reset()
        seen = {}
        (r,) = cuda.cuInit(0)
        r, dev = cuda.cuDeviceGet(0)
        r, ctx = cuda.cuDevicePrimaryCtxRetain(dev)
        n = []

        def device_start():
            seen["vp_mask_after_configure"] = regs.read_uint32(rocelet_hsb.DP_VP_MASK)
            rocelet_hsb.start_data_plane(regs)
            seen["vp_mask_after_start"] = regs.read_uint32(rocelet_hsb.DP_VP_MASK)

        class Sink(holoscan.core.Operator):
            def setup(self, spec):
                spec.input("in")

            def compute(self, op_input, op_output, context):
                op_input.receive("in")
                n.append(1)

        class App(holoscan.core.Application):
            def compose(self):
                rx = hololink_module.operators.LinuxReceiverOp(
                    self, holoscan.conditions.CountCondition(self, count=frames), name="receiver",
                    enumeration_metadata=md, frame_context=int(ctx), frame_size=frame_size,
                    device_start=device_start)
                self.add_flow(rx, Sink(self, name="sink"), {("output", "in")})

        App().run()
        rocelet_hsb.stop_data_plane(regs)
        seen["vp_mask_after_stop"] = regs.read_uint32(rocelet_hsb.DP_VP_MASK)
        regs.stop()
        assert seen["vp_mask_after_configure"] & 1 == 0, seen
        assert seen["vp_mask_after_start"] & 1 == 1, seen
        assert seen["vp_mask_after_stop"] & 1 == 0, seen
        assert len(n) == frames, n
        print(f"deferred start (module API): DP_VP_MASK {seen}, {len(n)} frames after the explicit start")
    finally:
        emu.kill()
        out = emu.communicate(timeout=10)[0]
        if "Traceback" in out:
            print(out)


def test_emulator_deferred_start_classic(frames=10, frame_size=65536):
    """The start gate on the classic API (what rocelet_hsb_app.py uses by default):
    DataChannel.configure_roce with vp_mask 0 leaves DP_VP_MASK clear; start_data_plane sets it."""
    import socket
    import threading
    import hololink as hl_classic
    sys.path.insert(0, os.path.dirname(HERE))
    import rocelet_hsb

    emu = subprocess.Popen([sys.executable, "-c", EMULATOR, UUID, hex(COMPAT), EMU_IP, str(frame_size),
                            str(frames * 50)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        dc, hl = rocelet_hsb.connect(EMU_IP, 1500, timeout_s=15.0, deferred_start=True)
        seen = {}
        try:
            hl.reset()
            md_off = hl_classic.round_up(frame_size, hl_classic.PAGE_SIZE)
            page_size = md_off + hl_classic.METADATA_SIZE
            pages = 4
            buf_size = hl_classic.round_up(page_size * pages, os.sysconf("SC_PAGESIZE"))
            ctx = rocelet_hsb.primary_context()
            mem = hl_classic.ReceiverMemoryDescriptor(ctx, buf_size)
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            dc.configure_socket(sock.fileno())
            rx = hl_classic.operators.LinuxReceiver(
                cu_buffer=mem.get(), cu_buffer_size=buf_size, cu_page_size=page_size, pages=pages,
                socket=sock.fileno(), received_address_offset=mem.get(), queue_size=1)

            def run():
                import cuda.bindings.driver as cuda
                cuda.cuCtxSetCurrent(ctx)
                rx.run()
            th = threading.Thread(target=run, daemon=True)
            th.start()
            dc.authenticate(rx.get_qp_number(), rx.get_rkey())
            dc.configure_roce(0, frame_size, page_size, pages, sock.getsockname()[1])
            seen["vp_mask_after_configure"] = hl.read_uint32(rocelet_hsb.DP_VP_MASK)
            # informational: NVIDIA's emulator sends once configured, whatever DP_VP_MASK says (the
            # rocelet firmware starts the producer only on DP_VP_MASK 0 -> 1)
            ok0, _ = rx.get_next_frame(500, 0)
            seen["emulator_frame_before_start"] = bool(ok0)
            rocelet_hsb.start_data_plane(hl)
            seen["vp_mask_after_start"] = hl.read_uint32(rocelet_hsb.DP_VP_MASK)
            got = sum(1 for _ in range(frames) if rx.get_next_frame(2000, 0)[0])
            rocelet_hsb.stop_data_plane(hl)
            seen["vp_mask_after_stop"] = hl.read_uint32(rocelet_hsb.DP_VP_MASK)
            dc.unconfigure()
            rx.close()
            th.join(timeout=5)
            sock.close()
        finally:
            hl.stop()
        assert seen["vp_mask_after_configure"] & 1 == 0, seen
        assert seen["vp_mask_after_start"] & 1 == 1, seen
        assert seen["vp_mask_after_stop"] & 1 == 0, seen
        assert got == frames, (got, seen)
        print(f"deferred start (classic API): {seen}, {got} frames after the explicit start")
    finally:
        emu.kill()
        out = emu.communicate(timeout=10)[0]
        if "Traceback" in out:
            print(out)


def main():
    global _module_dir
    ap = argparse.ArgumentParser()
    ap.add_argument("--module-dir", default=_module_dir)
    ap.add_argument("--skip-emulator", action="store_true")
    a = ap.parse_args()
    _module_dir = a.module_dir
    tests = [test_module_file, test_enumeration_enriched, test_sensor_range, test_data_plane_1_skipped,
             test_other_uuid_unenriched]
    if not a.skip_emulator:
        tests += [test_emulator_end_to_end, test_emulator_deferred_start, test_emulator_deferred_start_classic]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"PASS {t.__name__}", flush=True)
        except Exception as e:
            failed += 1
            print(f"FAIL {t.__name__}: {type(e).__name__}: {e}", flush=True)
    print("PASS" if not failed else f"FAIL ({failed})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
