#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# board_regs_probe.py - the beam register path against the real board (KCU116, console 'hsb on'):
# CAPS / STATUS read, a preset written with BoardRegs (mode block = WR_BLOCK on our own socket, or
# mode single = one write_uint32 per word through the Hololink object), APPLY while the generator is
# idle, read back APPLIED_ID / APPLIED_FRAME / APPLIES, a read-back of every written word, and a
# request from a foreign source port (the reply must come back to that port). Run in the HSB
# container: python3 tests/board_regs_probe.py [--mode block|single] [--preset N] [--scene-id ID]
# Copyright (c) 2026 Opsero Electronic Design Inc.

import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(1, os.path.join(os.path.dirname(os.path.dirname(HERE)), "hsb"))

import beam_regs as br  # noqa: E402
import beam_scene as bs  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.20.2")
    ap.add_argument("--mode", choices=["block", "single"], default="block")
    ap.add_argument("--preset", type=int, default=1)
    ap.add_argument("--scene-id", type=int, default=1000)
    ap.add_argument("--repeat", type=int, default=20, help="timed drag-sized writes (U, V, SCENE_ID, APPLY)")
    a = ap.parse_args()
    dc, hl = br.connect_classic(a.ip, 4200, deferred_start=True, sequence_check=(a.mode != "block"))
    regs = br.BoardRegs(a.ip, hl, mode=a.mode)
    bad = 0
    try:
        caps = regs.caps()
        print(f"CAPS 0x{caps:08x} ({'OK' if caps == bs.CAPS_VALUE else 'WRONG'})" if caps is not None else "CAPS: no mapping")
        bad += caps != bs.CAPS_VALUE
        st0 = regs.status()
        print("status before:", {k: (hex(v) if isinstance(v, int) and not isinstance(v, bool) else v) for k, v in st0.items()})
        sc = bs.preset(a.preset, scene_id=a.scene_id)
        pairs = sc.to_registers()
        t0 = time.monotonic()
        t1 = regs.write_block(pairs)
        print(f"wrote preset {a.preset} scene {a.scene_id}: {len(pairs)} pairs, mode {a.mode}, {1e3 * (t1 - t0):.2f} ms")
        st1 = regs.status()
        print("status after:", {k: (hex(v) if isinstance(v, int) and not isinstance(v, bool) else v) for k, v in st1.items()})
        if st1["applied_id"] != a.scene_id or st1["applies"] != (st0["applies"] + 1) & 0xFFFFFFFF or st1["pending"]:
            print("FAIL: APPLY while idle did not activate the scene at once")
            bad += 1
        # read back every written word (APPLY reads back the last value written)
        addrs = [p[0] for p in pairs]
        got = []
        for i in range(0, len(addrs), 50):
            got += regs.read(addrs[i:i + 50])
        mism = [(hex(ad), hex(v), hex(g)) for (ad, v), g in zip(pairs, got) if (v & 0xFFFFFFFF) != g]
        print(f"read back {len(got)} words: {len(mism)} mismatches {mism[:6]}")
        bad += bool(mism)
        rt = bs.Scene.from_registers({ad: g for ad, g in zip(addrs, got)})
        print(f"Scene.from_registers(read back) == written: {rt.to_registers() == pairs}")
        # drag-sized writes, timed
        sid = a.scene_id
        dt = []
        for i in range(a.repeat):
            sid += 1
            u, v = 0.3 * ((i % 7) - 3) / 3, 0.2
            p = [(bs.OPS_BM_SRC(0) + bs.SRC_U, bs.q230(u)), (bs.OPS_BM_SRC(0) + bs.SRC_V, bs.q230(v)),
                 (bs.OPS_BM_SCENE_ID, sid), (bs.OPS_BM_APPLY, 1)]
            t0 = time.monotonic()
            regs.write_block(p)
            dt.append(1e3 * (time.monotonic() - t0))
        st2 = regs.status()
        print(f"{a.repeat} drag writes: {sorted(dt)[len(dt) // 2]:.3f} ms p50, {max(dt):.3f} max; applied_id {st2['applied_id']}"
              f" (expect {sid}), applies {st2['applies']}")
        bad += st2["applied_id"] != sid
        # restore the preset written above (U/V of source 0 changed)
        regs.write_block(bs.preset(a.preset, scene_id=sid + 1).to_registers())
        if a.mode == "block":
            # a second socket = a foreign source port: the reply must come back to it
            r2 = br.BoardRegs(a.ip, hl, mode="block")
            ok = r2.read([bs.OPS_BM_CAPS])[0] == bs.CAPS_VALUE
            print(f"second socket (port {r2.sock.getsockname()[1]}, first {regs.sock.getsockname()[1]}): reply {'OK' if ok else 'WRONG'}")
            bad += not ok
            r2.close()
            # bad address -> status 0x03 as RegError
            try:
                regs.read([0x7F000102])
                print("FAIL: unaligned BM read accepted")
                bad += 1
            except br.RegError as e:
                print(f"unaligned read -> {e}")
            # hololink's own (unsequenced) API still works next to our socket
            v = hl.read_uint32(bs.OPS_BM_CAPS)
            print(f"hl.read_uint32(CAPS) after block traffic: 0x{v:08x}")
            bad += v != bs.CAPS_VALUE
        print(f"requests {regs.requests}, retried {regs.retried}, rtt p50 "
              f"{sorted(regs.rtt_us)[len(regs.rtt_us) // 2]:.0f} us" if regs.rtt_us else f"requests {regs.requests}")
    finally:
        regs.close()
        hl.stop()
    print("PASS" if not bad else f"FAIL ({bad})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
