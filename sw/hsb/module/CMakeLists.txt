# SPDX-License-Identifier: MIT
#
# Opsero hololink_module for qsfp28-fmc-rocelet, built out of NVIDIA's tree against an
# installed HSB 3.0.0 (the hololink-demo container: hololink wheel in
# /usr/local/lib/python3.12/dist-packages) and the matching holoscan-sensor-bridge source
# checkout (HSB_SOURCE_DIR, for module_core and add_hololink_module(), which are not installed).
#
#   cmake -S sw/hsb/module -B build/module -DHSB_SOURCE_DIR=/path/to/holoscan-sensor-bridge
#   cmake --build build/module
#   -> build/module/lib/hololink/modules/hololink_98183d0f-18ee-4719-a3b4-ca69e9b94c97_2603.so
#
# build.sh in this directory runs the same inside the container.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

cmake_minimum_required(VERSION 3.24)
project(opsero_rocelet_hololink_module LANGUAGES C CXX)

set(ROCELET_HSB_UUID "98183d0f-18ee-4719-a3b4-ca69e9b94c97" CACHE STRING "FPGA UUID the board announces")
set(ROCELET_HSB_COMPAT "2603" CACHE STRING "compat-id (HSB IP version) the board announces, 4 hex digits")
set(HSB_SOURCE_DIR "" CACHE PATH "holoscan-sensor-bridge source tree of the installed HSB release")
if(NOT EXISTS "${HSB_SOURCE_DIR}/hololink_module/module/core/hsb_ip_publisher.hpp")
    message(FATAL_ERROR "HSB_SOURCE_DIR='${HSB_SOURCE_DIR}' is not a holoscan-sensor-bridge 3.0.0 checkout")
endif()

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# The installed HSB: hololink::core, hololink::module_headers, hololink::module_runtime,
# hololink::operators::roce_receiver (static libraries + headers of the wheel).
find_package(CUDAToolkit REQUIRED)
find_package(holoscan 4.4 REQUIRED CONFIG PATHS /opt/nvidia/holoscan)   # holoscan::core, fmt (HSB links them)
find_package(Hololink REQUIRED CONFIG
    HINTS /usr/local/lib/python3.12/dist-packages/lib/cmake/hololink)

# NVIDIA's module helpers and the module_core sources (V1 wrappers over the HSB core); every
# module .so absorbs its own private copy of module_core.
set(HOLOLINK_BUILD_ROCE ON)
list(APPEND CMAKE_MODULE_PATH "${HSB_SOURCE_DIR}/hololink_module/cmake")
include(HololinkModule)
add_subdirectory("${HSB_SOURCE_DIR}/hololink_module/module/core" hsb_module_core EXCLUDE_FROM_ALL)
# module_core compiles HSB's Linux receiver, which includes internal core headers that the wheel
# does not install: take them from the same source tree (after the installed include paths).
target_include_directories(hololink_module_core AFTER PRIVATE "${HSB_SOURCE_DIR}/src")

add_hololink_module(
    NAME opsero_rocelet
    UUID ${ROCELET_HSB_UUID}
    COMPAT ${ROCELET_HSB_COMPAT}
    SOURCES
        module_entry.cpp
)
target_include_directories(opsero_rocelet
    PRIVATE
        "${HSB_SOURCE_DIR}/hololink_module/module/hsb_lite/include"
        $<TARGET_PROPERTY:hololink::module_core,INCLUDE_DIRECTORIES>)
target_link_libraries(opsero_rocelet PRIVATE hololink::module_core)

include(GNUInstallDirs)
install(TARGETS opsero_rocelet LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}/hololink/modules")
