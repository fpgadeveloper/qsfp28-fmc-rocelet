// SPDX-License-Identifier: MIT
//
// rocelet_ops.hpp - C++ Holoscan operators of the qsfp28-fmc-rocelet HSB host application
// (rocelet_hsb_app.py --checker cpp / --source csynthetic):
//
//   CheckerOp  the frame checker of rocelet_hsb_app.py's CheckerOp in C++: one chk_frame kernel
//              launch per frame (counter word check or bit-exact IQ16 model check, the metadata
//              record's PSN / frame number / bytes_written read on the GPU), the accounting per
//              frame (frame-number gaps, lost = frame-number span - receiver completion span,
//              consumer-dropped, frame number backwards, resync after a producer restart) and the
//              PSN / bytes_written / error / overrun evaluation once per harvest (results copied
//              back once a second). No Python, no GIL in compute().
//   SourceOp   a synthetic frame source in C++ built like HSB's RoceReceiverOp (the fast path for
//              measuring the checker): a producer thread (the board + NIC) writes frames into the
//              HSB page-ring layout (frame + 128-byte record) on its own CUDA stream and queues
//              them as complete; an AsynchronousCondition wakes the operator, whose compute()
//              only emits the next queued frame (a GXF tensor named "" wrapping the page + int64
//              metadata, RoceReceiverOp's keys). Pull mode (period 0): the producer keeps
//              queue_size frames ready (no drops: measures the consumer's ceiling). Board mode
//              (period > 0): frames complete on a wall-clock timeline from enable() on, like the
//              board's producer, and the queue drops its oldest frame when full (HSB RoceReceiver's
//              behaviour), so start-up and steady consumer drops show up as on hardware.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <holoscan/holoscan.hpp>

namespace rocelet {

// Counters of a CheckerOp (snapshot); field meanings as in rocelet_hsb_app.py Stats.
struct CheckerStats {
    double t0 = 0;                 // wall time of the first frame (s since the epoch), 0 = none yet
    double t_last = 0;             // wall time of the latest frame
    int64_t rx = 0, rx_bytes = 0, checked = 0, gaps = 0, hsb_dropped = 0;
    int64_t first_fn = -1, last_fn = -1, first_rfn = -1, last_rfn = -1;
    int64_t seg_first_fn = -1, seg_first_rfn = -1, lost_closed = 0;
    int64_t fn_back = 0, fn_span_replay = 0, resyncs = 0, resync_frames = 0;   // resync_frames: lost across resyncs
    int64_t err_frames = 0, err_words = 0, ovr_frames = 0, ovr_words = 0;
    int64_t psn_bad = 0, psn_seq_bad = 0, bw_bad = 0, harvested = 0;
    bool have_rfn = true;          // the receiver stamps received_frame_number (classic RoceReceiverOp)
    int64_t lost() const;          // -1 when unknown (no received_frame_number)
    int64_t consumer_dropped() const;
};

class CheckerOp : public holoscan::Operator {
public:
    HOLOSCAN_OPERATOR_FORWARD_ARGS(CheckerOp)
    CheckerOp() = default;

    void setup(holoscan::OperatorSpec& spec) override;
    void start() override;
    void stop() override;
    void compute(holoscan::InputContext& op_input, holoscan::OutputContext& op_output,
                 holoscan::ExecutionContext& context) override;

    CheckerStats stats();                       // thread-safe snapshot
    // host / GPU time per frame (us): mean, p50, p99 of the samples
    std::vector<double> host_us();
    std::vector<double> gpu_us();

protected:
    holoscan::Parameter<uint64_t> frame_size_;
    holoscan::Parameter<uint32_t> pages_;
    holoscan::Parameter<uint32_t> packets_per_frame_;
    holoscan::Parameter<int32_t> mode_;              // 0 none, 1 counter, 2 IQ16
    holoscan::Parameter<int32_t> check_every_;
    holoscan::Parameter<std::vector<int64_t>> iq_cfg_;
    holoscan::Parameter<bool> passthrough_;
    holoscan::Parameter<double> harvest_interval_;
    holoscan::Parameter<uint32_t> resync_window_;
    holoscan::Parameter<int32_t> max_messages_;
    holoscan::Parameter<bool> legacy_stream_;        // launch on the legacy default stream (Python source)

private:
    struct Pend {
        int64_t fn, imm, bw;
        bool checked, replay, resync;
    };
    void harvest();                             // start copying the active result buffer back (async)
    void process(int b, bool wait);             // evaluate a copied buffer (wait: block for its copy)
    void show(const std::string& s);

    std::mutex mutex_;
    CheckerStats st_;
    uint64_t fs_ = 0, md_off_ = 0, stride_ = 0;
    uint32_t ppf_ = 1;
    int64_t n_ = 0, slot_ = 0, dropped0_ = -1, last_imm_ = 0, epoch_base_ = 0;
    bool have_last_ = false;
    int64_t wrap_base_ = 0, raw_last16_ = -1;   // module API receiver: 16-bit frame numbers, extended here
    bool have_prev_rec_ = false;
    int64_t prev_rec_fn_ = 0, prev_rec_psn_ = 0;
    // two result buffers: the checker fills one while the other is copied back and evaluated
    uint64_t *res_dev_[2] = { nullptr, nullptr }, *res_host_[2] = { nullptr, nullptr }, *res_init_ = nullptr;
    void* copied_[2] = { nullptr, nullptr };    // cudaEvent_t: copy-back done
    int64_t pending_n_[2] = { 0, 0 };           // rows waiting in buffer b's copy (0 = none)
    int active_ = 0;
    int64_t *cfg_dev_ = nullptr;
    std::vector<Pend> pend_[2];
    double t_harvest_ = 0;
    int shown_ = 0;
    void* stream_ = nullptr;                         // cudaStream_t
    std::vector<float> host_us_samples_, gpu_us_samples_;
    std::vector<std::pair<void*, void*>> ev_pending_[2], ev_free_;
};

struct SourceStats {
    int64_t emitted = 0, completed = 0, queue_dropped = 0, lost_injected = 0, restarts = 0;
    double t_enable = 0, t_first = 0;  // wall times (s since the epoch), 0 = not yet
    bool enabled = false;
};

class SourceOp : public holoscan::Operator {
public:
    HOLOSCAN_OPERATOR_FORWARD_ARGS(SourceOp)
    SourceOp() = default;

    void setup(holoscan::OperatorSpec& spec) override;
    void start() override;
    void stop() override;
    void compute(holoscan::InputContext& op_input, holoscan::OutputContext& op_output,
                 holoscan::ExecutionContext& context) override;

    void enable();                              // the board's data plane starts (thread-safe)
    SourceStats stats();

protected:
    holoscan::Parameter<uint64_t> frame_size_;
    holoscan::Parameter<uint32_t> pages_;
    holoscan::Parameter<uint32_t> packets_per_frame_;
    holoscan::Parameter<int32_t> data_;               // 1 counter, 2 IQ16
    holoscan::Parameter<std::vector<int64_t>> iq_cfg_;
    holoscan::Parameter<uint64_t> period_ns_;         // 0 = pull mode (one frame per tick)
    holoscan::Parameter<uint32_t> queue_size_;
    holoscan::Parameter<bool> gated_;                 // wait for enable() (else enabled at start())
    holoscan::Parameter<int64_t> restart_every_;      // > 0: the producer restarts at frame 0 every N frames
    holoscan::Parameter<int64_t> restart_lost_;       // frames lost at each restart (outage)
    holoscan::Parameter<bool> use_frame_ready_condition_;  // true: AsynchronousCondition; false: compute() waits

private:
    struct Desc {
        int64_t ext_fn, rfn, page, board_fn, ts_s, ts_ns;
        uint32_t psn;
    };
    Desc next_desc();
    void produce(Desc& d);                      // write the frame + record, wait for the GPU
    void producer();                            // the producer thread
    void signal();

    std::mutex mutex_;
    std::condition_variable cv_;
    SourceStats st_;
    std::atomic<bool> enabled_ { false }, running_ { false };
    std::atomic<int64_t> t_enable_ns_ { 0 };
    uint64_t fs_ = 0, md_off_ = 0, ps_ = 0, stride_ = 0;
    uint8_t* ring_ = nullptr;
    int64_t* cfg_dev_ = nullptr;
    void* stream_ = nullptr;
    void* done_ = nullptr;                      // cudaEvent_t (blocking sync)
    int64_t k_ = 0, board_fn_ = 0, ext_ = -1, rcount_ = 0, completed_ = 0;
    uint64_t psn_next_ = 0;
    std::deque<Desc> queue_;
    std::thread thread_;
    std::shared_ptr<holoscan::AsynchronousCondition> ready_;
};

} // namespace rocelet
