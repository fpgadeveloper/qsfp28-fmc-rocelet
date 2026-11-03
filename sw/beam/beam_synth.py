#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# beam_synth.py - the reference-model frame generator of rocelet_beam_app.py --source synthetic,
# run in a separate (spawned) process so that numpy's ~25 ms per frame does not hold the
# application's GIL (in a thread it delayed the beamformer's kernel launches: 14 ms instead of
# 3 ms of GPU timeline per frame). Behaves like the FPGA generator (contract 4.4): a scene staged by
# an APPLY becomes active at the first frame the generator starts after it arrived (scene_frame =
# that frame), a newer staged scene replaces an older one that is still waiting.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import queue
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import beam_model as bm  # noqa: E402


def model_worker(scene, q_scene, q_req, q_frame, stop_ev):
    """scene: the active scene at frame 0. q_scene: staged scenes (from APPLY). q_req: one item per
    frame wanted (the frame starts when the request arrives: no frames generated ahead, so a scene
    change shows in the next frame). q_frame: puts (frame index, scene, scene_frame, frame bytes)."""
    f, sf = 0, 0
    while not stop_ev.is_set():
        try:
            q_req.get(timeout=0.2)
        except queue.Empty:
            continue
        staged = None
        while True:
            try:
                staged = q_scene.get_nowait()
            except queue.Empty:
                break
        if staged is not None:
            scene, sf = staged, f
        item = (f, scene, sf, bm.frame_bytes(bm.generate_frame(scene, f, scene_frame=sf)))
        while not stop_ev.is_set():
            try:
                q_frame.put(item, timeout=0.2)
                break
            except queue.Full:
                pass
        f += 1
