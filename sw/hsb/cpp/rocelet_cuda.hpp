// SPDX-License-Identifier: MIT
// rocelet_cuda.hpp - launchers of rocelet_cuda.cu (device addresses as 64-bit integers).
// Copyright (c) 2026 Opsero Electronic Design Inc.
#pragma once
#include <cstdint>

namespace rocelet {
// chk_frame: mode 0 record only, 1 counter (n = 64-bit words), 2 IQ16 (n = samples); res = 8-word slot
int launch_check(int mode, uint64_t frame, uint64_t n, uint32_t fn16, uint64_t n_first, uint64_t later_step,
                 uint64_t cfg, uint64_t rec, uint64_t res, void* stream);
// gen_counter (mode 1, n words) / gen_iq (mode 2, n samples)
int launch_gen(int mode, uint64_t frame, uint64_t n, uint32_t fn16, uint64_t n_first, uint64_t cfg, void* stream);
// the 128-byte HSB metadata record
int launch_record(uint64_t rec, uint32_t psn, uint32_t fn16, uint64_t bytes, uint64_t ts_s, uint32_t ts_ns, void* stream);
} // namespace rocelet
