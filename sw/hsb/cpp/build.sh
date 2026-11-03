#!/bin/bash
# SPDX-License-Identifier: MIT
# Build the C++ operators (rocelet_hsb_ops Python module) inside NVIDIA's HSB container.
#   ./build.sh [BUILD_DIR]        (default ./build next to this script; needs network for pybind11)
# Then: python3 ../rocelet_hsb_app.py --checker cpp --cpp-dir BUILD_DIR ...
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
build=${1:-$here/build}
cmake -S "$here" -B "$build"
cmake --build "$build" -j"$(nproc)"
ls -l "$build"/rocelet_hsb_ops*.so
