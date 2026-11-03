// SPDX-License-Identifier: MIT
//
// rocelet_cuda.cu - host launchers for the kernels of ../rocelet_hsb_kernels.cu (the same file
// the Python application compiles with NVRTC), for the C++ operators in rocelet_ops.cpp.
// stream: a cudaStream_t (the operator's own stream, or cudaStreamLegacy).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

#include <cstdint>

#include <cuda_runtime.h>

#include "../rocelet_hsb_kernels.cu"

#include "rocelet_cuda.hpp"

namespace rocelet {

static unsigned blocks(uint64_t n, unsigned cap)
{
    uint64_t b = (n + 255) / 256;
    if (b < 1)
        b = 1;
    return (unsigned)(b > cap ? cap : b);
}

int launch_check(int mode, uint64_t frame, uint64_t n, uint32_t fn16, uint64_t n_first, uint64_t later_step,
                 uint64_t cfg, uint64_t rec, uint64_t res, void *stream)
{
    unsigned g = mode == 1 ? blocks(n, 1024) : (mode == 2 ? blocks(n, 2048) : 1);
    unsigned b = mode == 0 ? 32 : 256;
    chk_frame<<<g, b, 0, (cudaStream_t)stream>>>(mode, (const unsigned char *)frame, n, fn16, n_first, later_step,
                                              (const i64 *)cfg, (const unsigned char *)rec, (u64 *)res);
    return (int)cudaGetLastError();
}

int launch_gen(int mode, uint64_t frame, uint64_t n, uint32_t fn16, uint64_t n_first, uint64_t cfg, void *stream)
{
    if (mode == 1)
        gen_counter<<<blocks(n, 1024), 256, 0, (cudaStream_t)stream>>>((u64 *)frame, n, fn16);
    else
        gen_iq<<<blocks(n, 2048), 256, 0, (cudaStream_t)stream>>>((u32 *)frame, n, n_first, (const i64 *)cfg);
    return (int)cudaGetLastError();
}

int launch_record(uint64_t rec, uint32_t psn, uint32_t fn16, uint64_t bytes, uint64_t ts_s, uint32_t ts_ns, void *stream)
{
    wr_record<<<1, 128, 0, (cudaStream_t)stream>>>((unsigned char *)rec, psn, fn16, bytes, ts_s, ts_ns, ts_s, ts_ns);
    return (int)cudaGetLastError();
}

} // namespace rocelet
