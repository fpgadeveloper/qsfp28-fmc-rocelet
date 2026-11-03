# SPDX-License-Identifier: MIT
#
# rocelet_hsb_ops: the C++ CheckerOp / SourceOp of the qsfp28-fmc-rocelet HSB host application
# as a Python module, built inside NVIDIA's HSB container (hololink-demo:3.0.0: Holoscan SDK 4.4,
# CUDA 13). pybind11 2.13.6 (the version HSB 3.0.0 uses) is fetched unless one is installed.
#
#   cmake -S sw/hsb/cpp -B build/cpp && cmake --build build/cpp
#   -> build/cpp/rocelet_hsb_ops.cpython-312-x86_64-linux-gnu.so   (rocelet_hsb_app.py --cpp-dir)
#
# CMAKE_CUDA_ARCHITECTURES defaults to the GPU of the build machine ("native"); set it for
# another GPU, e.g. -DCMAKE_CUDA_ARCHITECTURES=89 (Ada) or "80;90;120".
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

cmake_minimum_required(VERSION 3.24)
if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
    set(CMAKE_CUDA_ARCHITECTURES native)
endif()
project(rocelet_hsb_ops LANGUAGES C CXX CUDA)
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)

find_package(holoscan 4.4 REQUIRED CONFIG PATHS /opt/nvidia/holoscan)
find_package(CUDAToolkit REQUIRED)
find_package(Python3 REQUIRED COMPONENTS Interpreter Development.Module)

find_package(pybind11 2.13.6 QUIET CONFIG)
if(NOT pybind11_FOUND)
    include(FetchContent)
    FetchContent_Declare(pybind11
        GIT_REPOSITORY https://github.com/pybind/pybind11
        GIT_TAG v2.13.6
        GIT_SHALLOW TRUE)
    FetchContent_MakeAvailable(pybind11)
endif()

pybind11_add_module(rocelet_hsb_ops MODULE
    rocelet_ops.cpp
    rocelet_ops_py.cpp
    rocelet_cuda.cu)
target_link_libraries(rocelet_hsb_ops PRIVATE holoscan::core holoscan::pybind11 CUDA::cudart)
set_target_properties(rocelet_hsb_ops PROPERTIES
    CUDA_SEPARABLE_COMPILATION OFF
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
