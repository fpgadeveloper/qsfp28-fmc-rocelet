#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# run.sh - build and run the host-side test of the HSB firmware (hsb.c) with gcc; prints
# "FWTEST PASS" or the failing checks. Copyright (c) 2026 Opsero Electronic Design Inc.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../../common/src"
B="$HERE/build"; mkdir -p "$B"
gcc -O1 -Wall -Wno-unused-function -I "$HERE/mock" -I "$SRC" -I "$HERE/../../../submodules/rocelet/sw" \
    -o "$B/test_hsb" "$HERE/test_hsb.c" "$SRC/hsb.c"
"$B/test_hsb"
