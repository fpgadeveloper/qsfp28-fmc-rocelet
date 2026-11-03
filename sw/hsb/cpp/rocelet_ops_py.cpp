// SPDX-License-Identifier: MIT
//
// rocelet_ops_py.cpp - Python module rocelet_hsb_ops: the C++ CheckerOp and SourceOp as Holoscan
// operators a Python application composes like any other (positional conditions / resources,
// keyword parameters, name), plus stats() snapshots and SourceOp.enable(). Built against the
// Holoscan SDK's pybind11 settings (holoscan::pybind11) so the operator types interoperate with
// the holoscan Python package; import holoscan.core first.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

#include <pybind11/pybind11.h>
#include <pybind11/stl.h>

#include <memory>
#include <string>
#include <vector>

#include <holoscan/core/condition.hpp>
#include <holoscan/core/fragment.hpp>
#include <holoscan/core/operator.hpp>
#include <holoscan/core/operator_spec.hpp>
#include <holoscan/core/resource.hpp>

#include "rocelet_ops.hpp"

namespace py = pybind11;
using namespace pybind11::literals;

namespace {

void add_positional(holoscan::Operator* op, const py::args& args)
{
    for (auto it = args.begin(); it != args.end(); ++it) {
        if (py::isinstance<holoscan::Condition>(*it)) {
            op->add_arg(it->cast<std::shared_ptr<holoscan::Condition>>());
        } else if (py::isinstance<holoscan::Resource>(*it)) {
            op->add_arg(it->cast<std::shared_ptr<holoscan::Resource>>());
        } else {
            throw py::type_error("only Condition and Resource objects can be passed positionally");
        }
    }
}

class PyCheckerOp : public rocelet::CheckerOp {
public:
    using rocelet::CheckerOp::CheckerOp;
    PyCheckerOp(holoscan::Fragment* fragment, const py::args& args, uint64_t frame_size, uint32_t pages,
        uint32_t packets_per_frame, int32_t mode, int32_t check_every, std::vector<int64_t> iq_cfg,
        bool passthrough, double harvest_interval, uint32_t resync_window, int32_t max_messages,
        bool legacy_stream, const std::string& name)
        : rocelet::CheckerOp(holoscan::ArgList {
            holoscan::Arg { "frame_size", frame_size }, holoscan::Arg { "pages", pages },
            holoscan::Arg { "packets_per_frame", packets_per_frame }, holoscan::Arg { "mode", mode },
            holoscan::Arg { "check_every", check_every }, holoscan::Arg { "iq_cfg", iq_cfg },
            holoscan::Arg { "passthrough", passthrough }, holoscan::Arg { "harvest_interval", harvest_interval },
            holoscan::Arg { "resync_window", resync_window }, holoscan::Arg { "max_messages", max_messages },
            holoscan::Arg { "legacy_stream", legacy_stream } })
    {
        add_positional(this, args);
        name_ = name;
        fragment_ = fragment;
        spec_ = std::make_shared<holoscan::OperatorSpec>(fragment);
        setup(*spec_.get());
    }
};

class PySourceOp : public rocelet::SourceOp {
public:
    using rocelet::SourceOp::SourceOp;
    PySourceOp(holoscan::Fragment* fragment, const py::args& args, uint64_t frame_size, uint32_t pages,
        uint32_t packets_per_frame, int32_t data, std::vector<int64_t> iq_cfg, uint64_t period_ns,
        uint32_t queue_size, bool gated, int64_t restart_every, int64_t restart_lost, bool use_frame_ready_condition,
        const std::string& name)
        : rocelet::SourceOp(holoscan::ArgList {
            holoscan::Arg { "frame_size", frame_size }, holoscan::Arg { "pages", pages },
            holoscan::Arg { "packets_per_frame", packets_per_frame }, holoscan::Arg { "data", data },
            holoscan::Arg { "iq_cfg", iq_cfg }, holoscan::Arg { "period_ns", period_ns },
            holoscan::Arg { "queue_size", queue_size }, holoscan::Arg { "gated", gated },
            holoscan::Arg { "restart_every", restart_every }, holoscan::Arg { "restart_lost", restart_lost },
            holoscan::Arg { "use_frame_ready_condition", use_frame_ready_condition } })
    {
        add_positional(this, args);
        name_ = name;
        fragment_ = fragment;
        spec_ = std::make_shared<holoscan::OperatorSpec>(fragment);
        setup(*spec_.get());
    }
};

py::dict checker_stats(rocelet::CheckerOp& op)
{
    rocelet::CheckerStats s;
    std::vector<double> h, g;
    {
        py::gil_scoped_release nogil;      // compute() holds the operator's lock briefly
        s = op.stats();
        h = op.host_us();
        g = op.gpu_us();
    }
    py::dict d;
    d["t0"] = s.t0;
    d["t_last"] = s.t_last;
    d["rx"] = s.rx;
    d["rx_bytes"] = s.rx_bytes;
    d["checked"] = s.checked;
    d["gaps"] = s.gaps;
    d["hsb_dropped"] = s.hsb_dropped;
    d["first_fn"] = s.first_fn < 0 ? py::object(py::none()) : py::object(py::int_(s.first_fn));
    d["last_fn"] = s.last_fn < 0 ? py::object(py::none()) : py::object(py::int_(s.last_fn));
    d["first_rfn"] = s.first_rfn < 0 ? py::object(py::none()) : py::object(py::int_(s.first_rfn));
    d["last_rfn"] = s.last_rfn < 0 ? py::object(py::none()) : py::object(py::int_(s.last_rfn));
    d["fn_back"] = s.fn_back;
    d["fn_span_replay"] = s.fn_span_replay;
    d["resyncs"] = s.resyncs;
    d["resync_lost"] = s.resync_frames;
    d["err_frames"] = s.err_frames;
    d["err_words"] = s.err_words;
    d["ovr_frames"] = s.ovr_frames;
    d["ovr_words"] = s.ovr_words;
    d["psn_bad"] = s.psn_bad;
    d["psn_seq_bad"] = s.psn_seq_bad;
    d["bw_bad"] = s.bw_bad;
    d["harvested"] = s.harvested;
    d["have_rfn"] = s.have_rfn;
    d["lost"] = s.lost();
    d["consumer_dropped"] = s.consumer_dropped();
    d["host_us"] = h;          // [mean, p50, p99] or []
    d["gpu_us"] = g;
    return d;
}

py::dict source_stats(rocelet::SourceOp& op)
{
    rocelet::SourceStats s;
    {
        py::gil_scoped_release nogil;
        s = op.stats();
    }
    py::dict d;
    d["emitted"] = s.emitted;
    d["completed"] = s.completed;
    d["queue_dropped"] = s.queue_dropped;
    d["lost_injected"] = s.lost_injected;
    d["restarts"] = s.restarts;
    d["t_enable"] = s.t_enable;
    d["t_first"] = s.t_first;
    d["enabled"] = s.enabled;
    return d;
}

} // namespace

PYBIND11_MODULE(rocelet_hsb_ops, m)
{
    m.doc() = "qsfp28-fmc-rocelet HSB host application: C++ CheckerOp and SourceOp";
    py::module_::import("holoscan.core");

    py::class_<rocelet::CheckerOp, PyCheckerOp, holoscan::Operator, std::shared_ptr<rocelet::CheckerOp>>(m, "CheckerOp")
        .def(py::init<holoscan::Fragment*, const py::args&, uint64_t, uint32_t, uint32_t, int32_t, int32_t,
                 std::vector<int64_t>, bool, double, uint32_t, int32_t, bool, const std::string&>(),
            "fragment"_a, "frame_size"_a = uint64_t { 1 << 20 }, "pages"_a = uint32_t { 64 },
            "packets_per_frame"_a = uint32_t { 257 }, "mode"_a = int32_t { 1 }, "check_every"_a = int32_t { 1 },
            "iq_cfg"_a = std::vector<int64_t> {}, "passthrough"_a = false, "harvest_interval"_a = 1.0,
            "resync_window"_a = uint32_t { 4096 }, "max_messages"_a = int32_t { 20 }, "legacy_stream"_a = false,
            "name"_a = "checker")
        .def("stats", &checker_stats);

    py::class_<rocelet::SourceOp, PySourceOp, holoscan::Operator, std::shared_ptr<rocelet::SourceOp>>(m, "SourceOp")
        .def(py::init<holoscan::Fragment*, const py::args&, uint64_t, uint32_t, uint32_t, int32_t,
                 std::vector<int64_t>, uint64_t, uint32_t, bool, int64_t, int64_t, bool, const std::string&>(),
            "fragment"_a, "frame_size"_a = uint64_t { 1 << 20 }, "pages"_a = uint32_t { 64 },
            "packets_per_frame"_a = uint32_t { 257 }, "data"_a = int32_t { 1 }, "iq_cfg"_a = std::vector<int64_t> {},
            "period_ns"_a = uint64_t { 0 }, "queue_size"_a = uint32_t { 8 }, "gated"_a = false,
            "restart_every"_a = int64_t { 0 }, "restart_lost"_a = int64_t { 3 },
            "use_frame_ready_condition"_a = true, "name"_a = "source")
        .def("enable", &rocelet::SourceOp::enable, py::call_guard<py::gil_scoped_release>())
        .def("stats", &source_stats);
}
