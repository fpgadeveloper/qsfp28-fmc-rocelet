// SPDX-License-Identifier: MIT
//
// module_entry.cpp - Opsero hololink_module for the qsfp28-fmc-rocelet design's Holoscan Sensor
// Bridge (HSB) device mode (KCU116 + OP120 Quad SFP28 / 2x QSFP28 FMC, rocelet RoCEv2 engine).
//
// NVIDIA's HSB 3.0.0 host software ("module API", hololink_module/) loads this file for an
// enumeration announcement with FPGA UUID 98183d0f-18ee-4719-a3b4-ca69e9b94c97 and compat-id
// 0x2603 (hololink_98183d0f-18ee-4719-a3b4-ca69e9b94c97_2603.so, from $HOLOLINK_MODULE_DIR or
// <prefix>/lib/hololink/modules). It states the board's shape:
//   * one sensor (the frame producer: IQ16 test signal or counter pattern), one SIF;
//   * one data plane (0): the OP120 port the host is cabled to;
//   * no I2C, no camera, no clock synthesiser, no MIPI D-PHY: update_board_metadata stamps
//     nothing and accepts the device.
// Everything else (control plane, register protocol, RoCE and Linux data channels, receivers,
// frame metadata) is NVIDIA's canonical HSB-IP implementation (module_core::HsbIpPublisher).
//
// The HSB headers are included from NVIDIA's holoscan-sensor-bridge source tree (Apache-2.0),
// not copied; see CMakeLists.txt and README.md in this directory.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>

#include "hololink/module/publisher.hpp"
#include "hololink/module/service.hpp"
#include "hololink/module/status.h"

#include "hsb_ip_publisher.hpp"

using namespace hololink::module;
using namespace hololink::module::module_core;

namespace {

// The rocelet HSB device: one sensor on data plane 0, one SIF.
class RoceletChannelConfigurationV1 : public HsbIpChannelConfigurationV1 {
public:
    static constexpr int64_t TOTAL_SENSORS = 1;

    bool is_sensor_valid(int64_t sensor_number) const override
    {
        return sensor_number >= 0 && sensor_number < TOTAL_SENSORS;
    }

    void use_sensor(EnumerationMetadata& metadata, int64_t sensor_number) override
    {
        if (!is_sensor_valid(sensor_number)) {
            throw std::runtime_error(
                "While selecting a qsfp28-fmc-rocelet sensor: sensor_number "
                + std::to_string(sensor_number)
                + " is out of range (the board has one sensor, 0)");
        }
        // Sensor 0 on data plane 0 with one SIF: vp_mask 1, sif 0x01000000, vp 0x1000,
        // hif 0x02000300 (the addresses the rocelet firmware answers).
        hsb_ip_sensor_metadata(metadata, sensor_number, /*data_plane=*/0, /*sifs_per_sensor=*/1);
    }
};

class RoceletPublisher : public HsbIpPublisher {
protected:
    std::string module_name() const override { return "opsero_rocelet"; }

    void publish_channel_configuration() override
    {
        auto impl = std::make_shared<RoceletChannelConfigurationV1>();
        ServicePublisher<HsbIpChannelConfigurationV1>(shared_from_this()).publish("", impl);
    }

    // No D-PHY, no board-specific resources: nothing to stamp, accept the device.
    hololink_module_status_t update_board_metadata(EnumerationMetadata& /*metadata*/) override
    {
        return HOLOLINK_MODULE_OK;
    }
};

std::shared_ptr<Publisher> g_publisher; // alive while the module is loaded

} // namespace

extern "C" hololink_module_services_t hololink_module_init(const hololink_module_init_t* init)
{
    auto publisher = std::make_shared<RoceletPublisher>();
    g_publisher = publisher;
    return publisher->setup(init);
}
