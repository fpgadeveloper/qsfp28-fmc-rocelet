/* compat/xil_cache.h - the PS DDR window is mapped uncached through UIO on Linux: no cache
 * maintenance is needed (plat_ddr_for_cpu / _for_dev are no-ops). SPDX-License-Identifier: MIT */
#ifndef XIL_CACHE_H
#define XIL_CACHE_H
#include "xil_types.h"
static inline void Xil_DCacheFlushRange(UINTPTR a, u32 n) { (void)a; (void)n; }
static inline void Xil_DCacheInvalidateRange(UINTPTR a, u32 n) { (void)a; (void)n; }
#endif
