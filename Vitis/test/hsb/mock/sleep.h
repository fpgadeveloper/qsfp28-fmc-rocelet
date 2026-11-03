/* mock of the standalone BSP header for Vitis/test/hsb (host build). SPDX-License-Identifier: MIT */
#pragma once
static inline int usleep_mock(unsigned x){(void)x;return 0;}
#define usleep usleep_mock
