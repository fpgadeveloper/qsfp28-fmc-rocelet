#!/bin/bash
# SPDX-License-Identifier: MIT
# Build the Opsero hololink_module inside NVIDIA's HSB container (hololink-demo:3.0.0).
#   ./build.sh [HSB_SOURCE_DIR] [BUILD_DIR]
# HSB_SOURCE_DIR: the holoscan-sensor-bridge 3.0.0 checkout the container was built from
# (default $HSB_SOURCE_DIR, else /hsb). BUILD_DIR default: ./build next to this script.
# Result: $BUILD_DIR/lib/hololink/modules/hololink_<uuid>_2603.so; point HOLOLINK_MODULE_DIR
# at that directory (or copy the file to <site-packages>/lib/hololink/modules).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
hsb=${1:-${HSB_SOURCE_DIR:-/hsb}}
build=${2:-$here/build}
cmake -S "$here" -B "$build" -DHSB_SOURCE_DIR="$hsb"
cmake --build "$build" -j"$(nproc)"
ls -l "$build"/lib/hololink/modules/
