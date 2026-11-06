#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# beam_regs.py without a board: BoardRegs (mode block) against a fake HSB device on localhost that
# answers like the firmware's ecb() (Vitis/common/src/hsb.c: reply = command | 0x80, flags, sequence,
# status, 0, the pairs, latched sequence, 0, 0; BM window mapped, other addresses status 0x03), and
# SimRegs' APPLY semantics (contract 4.4). Pure Python: python3 -m unittest -v tests/test_beam_regs.py
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import socket
import struct
import sys
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import beam_regs as br  # noqa: E402
import beam_scene as bs  # noqa: E402


class FakeBoard(threading.Thread):
    """The firmware's register protocol: shadow BM registers, APPLY = snapshot, CAPS / status."""

    def __init__(self, drop_first=0):
        super().__init__(daemon=True)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]
        self.regs = dict(bs.RESET_SCENE_REGS)
        self.applied = []                 # snapshots at each APPLY
        self.requests = []
        self.drop = drop_first
        self.latched = 0
        self.stop = False
        self.ops = {}                     # Opsero read-only registers (OPS_LINK_GBPS, OPS_TARGET), when a test sets them

    def rd(self, a):
        if bs.OPS_BM_BASE <= a < bs.OPS_BM_BASE + 0x200:
            return 0, self.regs.get(a, 0)
        if a == bs.OPS_BM_CAPS:
            return 0, bs.CAPS_VALUE
        if a == bs.OPS_BM_APPLIED_ID:
            return 0, self.applied[-1][bs.OPS_BM_SCENE_ID] if self.applied else 0
        if bs.OPS_BM_STAT_BASE <= a < bs.OPS_BM_STAT_BASE + 0x1C:
            return 0, 0
        if a in self.ops:
            return 0, self.ops[a]
        return 3, 0

    def wr(self, a, v):
        if bs.OPS_BM_BASE <= a < bs.OPS_BM_BASE + 0x200:
            self.regs[a] = v
            if a == bs.OPS_BM_APPLY:
                self.applied.append(dict(self.regs))
            return 0
        if a == bs.OPS_SOURCE:
            self.regs[a] = v
            return 0
        return 3

    def run(self):
        self.sock.settimeout(0.2)
        while not self.stop:
            try:
                q, peer = self.sock.recvfrom(2048)
            except socket.timeout:
                continue
            self.requests.append(q)
            if self.drop:
                self.drop -= 1
                continue
            cmd, fl, seq = q[0], q[1], struct.unpack_from(">H", q, 2)[0]
            self.latched = seq
            blk, rd = cmd in (0x09, 0x19), cmd in (0x14, 0x19)
            np_ = (len(q) - 6) // 8 if blk else 1
            st, out = 0, b""
            for i in range(np_):
                a = struct.unpack_from(">I", q, 6 + 8 * i)[0]
                if rd:
                    s, v = self.rd(a)
                else:
                    v = struct.unpack_from(">I", q, 10 + 8 * i)[0]
                    s = self.wr(a, v)
                st = st or s
                out += struct.pack(">II", a, v)
            rep = bytes([cmd | 0x80, fl, q[2], q[3], st, 0]) + out + struct.pack(">HBB", self.latched, 0, 0)
            if fl & 1:
                self.sock.sendto(rep, peer)


class TestBoardName(unittest.TestCase):
    """The beam demo's board name: --board, OPS_TARGET, then OPS_LINK_GBPS (consoles before 0.6.0)."""

    def test_targets(self):
        self.assertEqual(br.board_name(None, 0x4B435531, 100), "KCU116")
        self.assertEqual(br.board_name(None, 0x5A313036, 40), "ZCU106")
        self.assertEqual(br.board_name(None, 0x5A313036, 10), "ZCU106")
        self.assertEqual(br.board_name(None, 0x56434B31, 100), "VCK190")

    def test_override(self):
        self.assertEqual(br.board_name("ZCU111", 0x56434B31, 100), "ZCU111")

    def test_old_console_falls_back_to_the_link(self):
        self.assertEqual(br.board_name(None, None, 100), "KCU116")
        self.assertEqual(br.board_name(None, 0, 40), "ZCU106")
        self.assertEqual(br.board_name(None, None, None), "FPGA")

    def test_unknown_target_shows_its_characters(self):
        self.assertEqual(br.board_name(None, 0x5A313131, 100), "Z111")
        self.assertEqual(br.board_name(None, 0xFFFFFFFF, 40), "ZCU106")   # not ASCII: the link rule


class TestBoardRegs(unittest.TestCase):
    def setUp(self):
        self.fb = FakeBoard()
        self.fb.start()
        self.r = br.BoardRegs("127.0.0.1", hl=None, mode="block", port=self.fb.port, timeout_s=0.1)

    def tearDown(self):
        self.fb.stop = True
        self.fb.join()
        self.fb.sock.close()
        self.r.close()

    def test_scene_is_one_request_apply_last(self):
        sc = bs.preset(2, scene_id=7)
        self.r.write_block(sc.to_registers())
        self.assertEqual(len(self.fb.requests), 1)
        q = self.fb.requests[0]
        self.assertEqual(q[0], 0x09)
        self.assertEqual(q[1], 0x01)                                   # ACK, no sequence check
        pairs = [struct.unpack_from(">II", q, 6 + 8 * i) for i in range((len(q) - 6) // 8)]
        self.assertEqual(len(pairs), 102)
        self.assertEqual(pairs[-1][0], bs.OPS_BM_APPLY)
        self.assertEqual(pairs[-2], (bs.OPS_BM_SCENE_ID, 7))
        got = bs.Scene.from_registers(self.fb.applied[-1])
        self.assertEqual(got.to_registers(), sc.to_registers())

    def test_drag_is_four_words(self):
        a = bs.preset(2, scene_id=1)
        self.r.write_block(a.to_registers())
        b = bs.preset(2, scene_id=2)
        b.sources[0].u, b.sources[0].v = 0.1, -0.2
        p = b.changed_registers(a)
        self.assertEqual([x for x, _ in p], [bs.OPS_BM_SRC(0) + bs.SRC_U, bs.OPS_BM_SRC(0) + bs.SRC_V,
                                             bs.OPS_BM_SCENE_ID, bs.OPS_BM_APPLY])
        self.r.write_block(p)
        self.assertEqual(bs.Scene.from_registers(self.fb.applied[-1]).to_registers(), b.to_registers())

    def test_read_caps_status_and_bad_address(self):
        self.assertEqual(self.r.caps(), bs.CAPS_VALUE)
        self.r.write_block(bs.preset(1, scene_id=5).to_registers())
        self.assertEqual(self.r.status()["applied_id"], 5)
        with self.assertRaises(br.RegError):
            self.r.write_block([(0x7F000400, 1)])

    def test_target_id_and_link(self):
        self.assertIsNone(self.r.target_id())                          # not answered (status 0x03): unknown
        self.assertIsNone(self.r.link_gbps())
        self.fb.ops = {bs.OPS_TARGET: 0, bs.OPS_LINK_GBPS: 100}        # a console before 0.6.0
        self.assertIsNone(self.r.target_id())
        self.assertEqual(br.board_name(None, self.r.target_id(), self.r.link_gbps()), "KCU116")
        self.fb.ops = {bs.OPS_TARGET: 0x56434B31, bs.OPS_LINK_GBPS: 100}
        self.assertEqual(self.r.target_id(), 0x56434B31)
        self.assertEqual(br.board_name(None, self.r.target_id(), self.r.link_gbps()), "VCK190")

    def test_retry_after_lost_request(self):
        self.fb.drop = 1
        self.r.write_block([(bs.OPS_BM_NOISE_AMP, 77)])
        self.assertEqual(self.fb.regs[bs.OPS_BM_NOISE_AMP], 77)
        self.assertEqual(self.r.retried, 1)


class TestSimRegs(unittest.TestCase):
    def test_apply_semantics(self):
        s = br.SimRegs()
        self.assertEqual(s.frame_start(0)[0].scene_id, 0)               # reset scene, running
        s.write_block(bs.preset(1, scene_id=1).to_registers())
        s.write_block(bs.preset(2, scene_id=2).to_registers())          # replaces the pending one
        self.assertTrue(s.status()["pending"])
        sc, sf = s.frame_start(1)
        self.assertEqual((sc.scene_id, sf), (2, 1))
        self.assertEqual(sc.to_registers(), bs.preset(2, scene_id=2).to_registers())
        self.assertEqual(s.frame_start(2), (sc, 1))
        st = s.status()
        self.assertEqual((st["applied_id"], st["applied_frame"], st["pending"]), (2, 1, False))

    def test_idle_apply_is_immediate(self):
        s = br.SimRegs()
        s.write_block(bs.preset(3, scene_id=9).to_registers())
        self.assertEqual(s.status()["applied_id"], 9)
        self.assertEqual(s.frame_start(0)[1], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
