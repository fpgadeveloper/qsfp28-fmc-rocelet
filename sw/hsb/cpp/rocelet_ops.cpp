// SPDX-License-Identifier: MIT
//
// rocelet_ops.cpp - CheckerOp and SourceOp (see rocelet_ops.hpp). The accounting follows
// rocelet_hsb_app.py's CheckerOp line by line, so the Python and the C++ checker report the same
// numbers for the same stream.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

#include "rocelet_ops.hpp"

#include <algorithm>
#include <chrono>
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <pthread.h>
#include <stdexcept>

#include <cuda_runtime.h>

#include <gxf/std/tensor.hpp>

#include "rocelet_cuda.hpp"

namespace rocelet {

namespace {

constexpr int64_t RES_SLOTS = 16384;   // result slots between two harvests
constexpr int SLOT_WORDS = 8;          // [0] error words [1] overrun words [2] first error [3] psn [4] fn
                                       // [5] bytes [6] blocks done [7] fn after the check
constexpr uint64_t METADATA_SIZE = 128;
constexpr uint64_t PAGE_ALIGN = 128;

void ck(cudaError_t e, const char* what)
{
    if (e != cudaSuccess) {
        throw std::runtime_error(std::string(what) + ": " + cudaGetErrorString(e));
    }
}

double wall()
{
    return std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
}

int64_t mono_ns()
{
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

uint64_t round_up(uint64_t x, uint64_t a) { return (x + a - 1) / a * a; }

// An integer metadata value whatever integer type the producer stored (C++ receivers: int64_t;
// Python operators must set cast_to_cpp=True). Missing or not an integer: dflt.
int64_t md_int(const std::shared_ptr<holoscan::MetadataDictionary>& md, const char* key, int64_t dflt)
{
    auto it = md->find(key);
    if (it == md->end()) {
        return dflt;
    }
    const std::any& v = it->second->value();
    if (auto p = std::any_cast<int64_t>(&v))
        return *p;
    if (auto p = std::any_cast<uint64_t>(&v))
        return (int64_t)*p;
    if (auto p = std::any_cast<int32_t>(&v))
        return *p;
    if (auto p = std::any_cast<uint32_t>(&v))
        return *p;
    if (auto p = std::any_cast<bool>(&v))
        return *p;
    static bool warned = false;
    if (!warned) {
        warned = true;
        std::fprintf(stderr, "rocelet CheckerOp: metadata '%s' is not a C++ integer (a Python operator must "
                             "set it with cast_to_cpp=True); using %" PRId64 "\n", key, dflt);
    }
    return dflt;
}

std::vector<double> summarize(std::vector<float> v)
{
    if (v.empty())
        return {};
    double sum = 0;
    for (float x : v)
        sum += x;
    std::sort(v.begin(), v.end());
    auto pct = [&](double q) { return (double)v[std::min(v.size() - 1, (size_t)(q * (v.size() - 1) + 0.5))]; };
    return { sum / v.size(), pct(0.5), pct(0.99) };
}

uint64_t iq_stride(uint64_t frame_size) { return round_up(frame_size / 4, 16); }

} // namespace

int64_t CheckerStats::lost() const
{
    if (!have_rfn)
        return -1;
    if (first_fn < 0 || seg_first_rfn < 0)
        return 0;
    return lost_closed + (last_fn - seg_first_fn) - (last_rfn - seg_first_rfn) - fn_span_replay;
}

int64_t CheckerStats::consumer_dropped() const
{
    int64_t l = lost();
    return l < 0 ? -1 : gaps - (l - resync_frames);    // frames lost across a resync are not gaps
}

// ------------------------------------------------------------------------------------------
// CheckerOp
// ------------------------------------------------------------------------------------------
void CheckerOp::setup(holoscan::OperatorSpec& spec)
{
    spec.input<holoscan::gxf::Entity>("input");
    spec.output<holoscan::gxf::Entity>("output").condition(holoscan::ConditionType::kNone);
    spec.param(frame_size_, "frame_size", "FrameSize", "frame bytes", uint64_t { 1 << 20 });
    spec.param(pages_, "pages", "Pages", "receive ring pages", uint32_t { 64 });
    spec.param(packets_per_frame_, "packets_per_frame", "PacketsPerFrame", "data packets + 1", uint32_t { 257 });
    spec.param(mode_, "mode", "Mode", "0 none, 1 counter, 2 IQ16", int32_t { 1 });
    spec.param(check_every_, "check_every", "CheckEvery", "check the data of every Nth frame", int32_t { 1 });
    spec.param(iq_cfg_, "iq_cfg", "IqCfg", "IQ16 configuration (int64[142])", std::vector<int64_t> {});
    spec.param(passthrough_, "passthrough", "Passthrough", "emit every frame on 'output'", false);
    spec.param(harvest_interval_, "harvest_interval", "HarvestInterval", "s between result harvests", 1.0);
    spec.param(resync_window_, "resync_window", "ResyncWindow",
        "a frame number that falls back below this after a gap is a producer restart", uint32_t { 4096 });
    spec.param(max_messages_, "max_messages", "MaxMessages", "error lines printed", int32_t { 20 });
    spec.param(legacy_stream_, "legacy_stream", "LegacyStream",
        "launch on the legacy default stream (ordered after a Python source's CuPy writes)", false);
}

void CheckerOp::start()
{
    fs_ = frame_size_.get();
    md_off_ = round_up(fs_, PAGE_ALIGN);
    ppf_ = packets_per_frame_.get();
    stride_ = iq_stride(fs_);
    if (check_every_.get() < 1) {
        throw std::runtime_error("CheckerOp: check_every must be >= 1");
    }
    const size_t bytes = RES_SLOTS * SLOT_WORDS * sizeof(uint64_t);
    ck(cudaMallocHost((void**)&res_init_, bytes), "cudaMallocHost results init");
    std::memset(res_init_, 0, bytes);
    for (int64_t i = 0; i < RES_SLOTS; i++) {
        res_init_[i * SLOT_WORDS + 2] = ~0ull;
    }
    for (int b = 0; b < 2; b++) {
        ck(cudaMalloc((void**)&res_dev_[b], bytes), "cudaMalloc results");
        ck(cudaMallocHost((void**)&res_host_[b], bytes), "cudaMallocHost results");
        ck(cudaMemcpy(res_dev_[b], res_init_, bytes, cudaMemcpyHostToDevice), "results init");
        cudaEvent_t e;
        ck(cudaEventCreateWithFlags(&e, cudaEventDisableTiming), "event");
        copied_[b] = (void*)e;
        pend_[b].assign(RES_SLOTS, Pend {});
        pending_n_[b] = 0;
    }
    active_ = 0;
    if (mode_.get() == 2) {
        const auto& cfg = iq_cfg_.get();
        if (cfg.size() != 142) {
            throw std::runtime_error("CheckerOp: iq_cfg needs 142 values for the IQ16 check");
        }
        ck(cudaMalloc((void**)&cfg_dev_, cfg.size() * 8), "cudaMalloc iq cfg");
        ck(cudaMemcpy(cfg_dev_, cfg.data(), cfg.size() * 8, cudaMemcpyHostToDevice), "iq cfg");
    }
    host_us_samples_.reserve(1 << 16);
    gpu_us_samples_.reserve(1 << 14);
    t_harvest_ = wall();
    if (legacy_stream_.get()) {
        stream_ = (void*)cudaStreamLegacy;
    } else {
        cudaStream_t s;
        ck(cudaStreamCreateWithFlags(&s, cudaStreamNonBlocking), "checker stream");
        stream_ = (void*)s;
    }
    // load the module's kernels now (first launch costs ~ms), not with the first frame
    ck((cudaError_t)launch_check(0, 0, 0, 0, 0, 0, 0, (uint64_t)(uintptr_t)(res_dev_[0] + 64),
                                (uint64_t)(uintptr_t)res_dev_[0], stream_), "kernel warm-up");
    ck(cudaStreamSynchronize((cudaStream_t)stream_), "kernel warm-up");
    ck(cudaMemcpy(res_dev_[0], res_init_, SLOT_WORDS * 8, cudaMemcpyHostToDevice), "results init");
}

void CheckerOp::stop()
{
    {
        std::lock_guard<std::mutex> lock(mutex_);
        harvest();
        process(0, true);
        process(1, true);
    }
    for (auto& e : ev_free_) {
        cudaEventDestroy((cudaEvent_t)e.first);
        cudaEventDestroy((cudaEvent_t)e.second);
    }
    ev_free_.clear();
    for (int b = 0; b < 2; b++) {
        cudaEventDestroy((cudaEvent_t)copied_[b]);
        cudaFree(res_dev_[b]);
        cudaFreeHost(res_host_[b]);
        copied_[b] = nullptr;
        res_dev_[b] = nullptr;
        res_host_[b] = nullptr;
    }
    if (stream_ && stream_ != (void*)cudaStreamLegacy) {
        cudaStreamDestroy((cudaStream_t)stream_);
    }
    stream_ = nullptr;
    cudaFreeHost(res_init_);
    cudaFree(cfg_dev_);
    res_init_ = nullptr;
    cfg_dev_ = nullptr;
}

void CheckerOp::show(const std::string& s)
{
    if (shown_ < max_messages_.get()) {
        std::printf("%s\n", s.c_str());
        std::fflush(stdout);
    }
    shown_++;
}

void CheckerOp::compute(holoscan::InputContext& op_input, holoscan::OutputContext& op_output,
    holoscan::ExecutionContext& /*context*/)
{
    const int64_t t_in = mono_ns();
    auto msg = op_input.receive<holoscan::gxf::Entity>("input");
    if (!msg) {
        return;
    }
    auto md = metadata();
    int64_t fn = md_int(md, "frame_number", 0);
    const int64_t dropped = md_int(md, "dropped", 0);
    const int64_t imm = md_int(md, "imm_data", -1);
    int64_t mem = md_int(md, "frame_memory", 0);
    const int64_t bw = md_int(md, "bytes_written", (int64_t)fs_);
    const bool replay = md_int(md, "rocelet_replay", 0) != 0;
    const int64_t rfn_md = md_int(md, "received_frame_number", -1);
    if (mem == 0) {
        auto t = msg.value().get<holoscan::Tensor>("");
        if (!t) {
            throw std::runtime_error("CheckerOp: no frame_memory metadata and no tensor named \"\"");
        }
        mem = (int64_t)(uintptr_t)t->data();
    }
    std::lock_guard<std::mutex> lock(mutex_);
    CheckerStats& st = st_;
    if (rfn_md < 0 && fn >= 0 && fn <= 0xFFFF && !replay) {
        // the module API receiver passes the board's 16-bit frame number as is (the classic one
        // extends it): a forward step of < 32768 across 0 is a wrap, anything else a restart
        if (raw_last16_ >= 0 && fn < raw_last16_ && ((fn - raw_last16_) & 0xFFFF) < 0x8000) {
            wrap_base_ += 0x10000;
        }
        raw_last16_ = fn;
        fn += wrap_base_;
    }
    const double now = wall();
    if (st.t0 == 0) {
        st.t0 = now;
    }
    st.t_last = now;
    st.rx += 1;
    st.rx_bytes += (int64_t)(fs_ + METADATA_SIZE);
    if (st.first_fn < 0) {
        st.first_fn = fn;
        st.seg_first_fn = fn;
    }
    if (dropped0_ < 0) {
        dropped0_ = dropped;
    }
    st.hsb_dropped = dropped - dropped0_;
    if (rfn_md < 0) {
        st.have_rfn = false;
    }
    const int64_t rfn = rfn_md >= 0 ? rfn_md : st.rx;
    if (st.first_rfn < 0) {
        st.first_rfn = rfn;
        st.seg_first_rfn = rfn;
    }
    const uint32_t fn16 = (uint32_t)(fn & 0xFFFF);
    const uint32_t ipsn = (uint32_t)((imm >> 12) & 0xFFFFF);
    bool resync = false;
    if (have_last_ && !replay) {
        const int64_t d = fn - st.last_fn;
        const uint32_t last16 = (uint32_t)(st.last_fn & 0xFFFF);
        // the producer restarted at frame 0 (a link pause on the board: frame number, page and
        // IQ16 sample count start again): the 16-bit frame number fell back to a small value and the
        // PSN (which the board keeps counting) does not match the frame-number step
        if ((fn16 < last16 || d < 1) && fn16 < resync_window_.get()) {
            const uint32_t exp = (uint32_t)(((uint64_t)last_imm_ + (uint64_t)d * ppf_) & 0xFFFFF);
            // without imm_data (module API receiver) the PSN cannot confirm a natural 16-bit wrap:
            // accept the receiver's extended frame number stepping by exactly 1 (session G: false
            // resync at every wrap)
            const bool no_psn = imm < 0 || last_imm_ < 0;
            if (d < 1 || (no_psn && d != 1) || (!no_psn && ipsn != exp)) {
                resync = true;
            }
        }
        if (resync) {
            st.lost_closed += (st.last_fn - st.seg_first_fn) - (st.last_rfn - st.seg_first_rfn);
            if (imm >= 0 && last_imm_ >= 0) {
                // frames the board sent across the restart (PSN step) - frames the receiver completed
                const int64_t gone = (int64_t)((ipsn - (uint32_t)last_imm_) & 0xFFFFF) / ppf_ - (rfn - st.last_rfn);
                if (gone > 0 && gone < (1 << 19) / (int64_t)ppf_) {
                    st.lost_closed += gone;
                    st.resync_frames += gone;
                }
            }
            st.seg_first_fn = fn;
            st.seg_first_rfn = rfn;
            epoch_base_ = fn - fn16;
            st.resyncs += 1;
            char b[200];
            std::snprintf(b, sizeof(b), "resync: frame number restarted at %u after frame %" PRId64
                " (%" PRId64 " frames since the last frame by the receiver count): producer restart, "
                "e.g. a link pause", fn16, st.last_fn, rfn - st.last_rfn);
            show(b);
        } else if (d > 1) {
            st.gaps += d - 1;
        } else if (d < 1) {
            st.fn_back += 1;
        }
    }
    if (have_last_ && replay) {
        st.fn_span_replay += fn - st.last_fn - 1;
    }
    st.last_rfn = rfn;
    st.last_fn = fn;
    last_imm_ = imm < 0 ? -1 : ipsn;
    have_last_ = true;

    const int mode = mode_.get();
    const bool do_check = mode != 0 && (n_ % check_every_.get() == 0);
    n_ += 1;
    process(active_ ^ 1, false);                 // the other buffer, if its copy has landed
    const uint64_t slot_ptr = (uint64_t)(uintptr_t)(res_dev_[active_] + slot_ * SLOT_WORDS);
    const uint64_t rec = (uint64_t)mem + md_off_;
    const bool timed = do_check && (n_ % 64 == 1);
    std::pair<void*, void*> ev { nullptr, nullptr };
    if (timed) {
        if (!ev_free_.empty()) {
            ev = ev_free_.back();
            ev_free_.pop_back();
        } else {
            cudaEvent_t a, b;
            ck(cudaEventCreate(&a), "event");
            ck(cudaEventCreate(&b), "event");
            ev = { (void*)a, (void*)b };
        }
        cudaEventRecord((cudaEvent_t)ev.first, (cudaStream_t)stream_);
    }
    int r;
    if (!do_check) {
        r = launch_check(0, (uint64_t)mem, 0, fn16, 0, 0, 0, rec, slot_ptr, stream_);
    } else if (mode == 1) {
        r = launch_check(1, (uint64_t)mem, fs_ / 8, fn16, 0, 0, 0, rec, slot_ptr, stream_);
    } else {
        r = launch_check(2, (uint64_t)mem, fs_ / 4, fn16, (uint64_t)(fn - epoch_base_) * stride_,
            (uint64_t)pages_.get() * stride_, (uint64_t)(uintptr_t)cfg_dev_, rec, slot_ptr, stream_);
    }
    if (r != 0) {
        throw std::runtime_error(std::string("CheckerOp: kernel launch: ") + cudaGetErrorString((cudaError_t)r));
    }
    if (timed) {
        cudaEventRecord((cudaEvent_t)ev.second, (cudaStream_t)stream_);
        ev_pending_[active_].push_back(ev);
    }
    pend_[active_][slot_] = Pend { fn, imm, bw, do_check, replay, resync };
    slot_ += 1;
    if (passthrough_.get()) {
        op_output.emit(msg.value(), "output");
    }
    if (slot_ == RES_SLOTS || now - t_harvest_ >= harvest_interval_.get()) {
        harvest();
        t_harvest_ = now;
    }
    if (n_ % 16 == 0 && host_us_samples_.size() < (1u << 20)) {
        host_us_samples_.push_back((float)((mono_ns() - t_in) / 1e3));
    }
}

// called with mutex_ held: copy the active buffer back on the checker's stream (after its
// kernels), reset it, and switch to the other buffer (evaluated first if still pending)
void CheckerOp::harvest()
{
    if (slot_ == 0 || !res_dev_[0]) {
        return;
    }
    const int a = active_;
    process(a ^ 1, true);                         // normally long done (a second ago)
    const size_t bytes = slot_ * SLOT_WORDS * sizeof(uint64_t);
    cudaStream_t s = (cudaStream_t)stream_;
    ck(cudaMemcpyAsync(res_host_[a], res_dev_[a], bytes, cudaMemcpyDeviceToHost, s), "harvest copy");
    ck(cudaMemcpyAsync(res_dev_[a], res_init_, bytes, cudaMemcpyHostToDevice, s), "harvest reset");
    ck(cudaEventRecord((cudaEvent_t)copied_[a], s), "harvest event");
    pending_n_[a] = slot_;
    active_ = a ^ 1;
    slot_ = 0;
}

// called with mutex_ held: evaluate buffer b once its copy has landed
void CheckerOp::process(int bi, bool wait)
{
    const int64_t n = pending_n_[bi];
    if (n == 0) {
        return;
    }
    if (wait) {
        ck(cudaEventSynchronize((cudaEvent_t)copied_[bi]), "harvest wait");
    } else if (cudaEventQuery((cudaEvent_t)copied_[bi]) != cudaSuccess) {
        return;
    }
    CheckerStats& st = st_;
    for (auto& e : ev_pending_[bi]) {
        float ms = 0;
        if (cudaEventElapsedTime(&ms, (cudaEvent_t)e.first, (cudaEvent_t)e.second) == cudaSuccess
            && gpu_us_samples_.size() < (1u << 20)) {
            gpu_us_samples_.push_back(ms * 1e3f);
        }
        ev_free_.push_back(e);
    }
    ev_pending_[bi].clear();
    const uint64_t* res = res_host_[bi];
    const std::vector<Pend>& pend = pend_[bi];
    char b[256];
    for (int64_t k = 0; k < n; k++) {
        const uint64_t* r = res + k * SLOT_WORDS;
        const Pend& p = pend[k];
        const uint32_t fn16 = (uint32_t)(p.fn & 0xFFFF);
        const bool rec_ok = r[4] == fn16;
        const int64_t psn = (int64_t)(r[3] & 0xFFFFF);
        const int64_t ipsn = (p.imm >> 12) & 0xFFFFF;
        if (rec_ok && p.imm >= 0 && psn != ipsn) {
            st.psn_bad++;
            std::snprintf(b, sizeof(b), "frame %" PRId64 ": record PSN 0x%05" PRIx64 " != immediate PSN 0x%05" PRIx64,
                p.fn, psn, ipsn);
            show(b);
        }
        if (rec_ok && ((int64_t)r[5] != (int64_t)fs_ || p.bw != (int64_t)fs_)) {
            st.bw_bad++;
            std::snprintf(b, sizeof(b), "frame %" PRId64 ": bytes_written %" PRIu64 " (metadata %" PRId64 "), frame %" PRIu64,
                p.fn, r[5], p.bw, fs_);
            show(b);
        }
        if (rec_ok) {
            if (have_prev_rec_ && !p.replay && !p.resync) {
                const int64_t exp = (prev_rec_psn_ + (p.fn - prev_rec_fn_) * (int64_t)ppf_) & 0xFFFFF;
                if (psn != exp) {
                    st.psn_seq_bad++;
                    std::snprintf(b, sizeof(b), "frame %" PRId64 ": PSN 0x%05" PRIx64 ", expected 0x%05" PRIx64
                        " after frame %" PRId64 " (%u packets per frame)", p.fn, psn, exp, prev_rec_fn_, ppf_);
                    show(b);
                }
            }
            have_prev_rec_ = true;
            prev_rec_fn_ = p.fn;
            prev_rec_psn_ = psn;
        }
        const bool reused = !rec_ok || r[7] != fn16;
        if (p.checked) {
            st.checked++;
            if (r[0] != 0 && !reused) {
                st.err_frames++;
                st.err_words += (int64_t)r[0];
                std::snprintf(b, sizeof(b), "frame %" PRId64 ": %" PRIu64 " words differ (first at %" PRIu64 "), %"
                    PRIu64 " from a later frame", p.fn, r[0], r[2], r[1]);
                show(b);
            }
            if (r[1] != 0 || reused) {
                st.ovr_frames++;
                st.ovr_words += (int64_t)r[1];
            }
        }
    }
    st.harvested += n;
    pending_n_[bi] = 0;
}

CheckerStats CheckerOp::stats()
{
    std::lock_guard<std::mutex> lock(mutex_);
    return st_;
}

std::vector<double> CheckerOp::host_us()
{
    std::vector<float> v;
    {
        std::lock_guard<std::mutex> lock(mutex_);   // copy only: compute() must not wait for a sort
        v = host_us_samples_;
    }
    return summarize(std::move(v));
}

std::vector<double> CheckerOp::gpu_us()
{
    std::vector<float> v;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        v = gpu_us_samples_;
    }
    return summarize(std::move(v));
}

// ------------------------------------------------------------------------------------------
// SourceOp
// ------------------------------------------------------------------------------------------
void SourceOp::setup(holoscan::OperatorSpec& spec)
{
    spec.output<holoscan::gxf::Entity>("output");
    spec.param(frame_size_, "frame_size", "FrameSize", "frame bytes", uint64_t { 1 << 20 });
    spec.param(pages_, "pages", "Pages", "ring pages", uint32_t { 64 });
    spec.param(packets_per_frame_, "packets_per_frame", "PacketsPerFrame", "data packets + 1", uint32_t { 257 });
    spec.param(data_, "data", "Data", "1 counter, 2 IQ16", int32_t { 1 });
    spec.param(iq_cfg_, "iq_cfg", "IqCfg", "IQ16 configuration (int64[142])", std::vector<int64_t> {});
    spec.param(period_ns_, "period_ns", "PeriodNs", "board frame period (0 = keep queue_size frames ready)", uint64_t { 0 });
    spec.param(queue_size_, "queue_size", "QueueSize", "receive queue", uint32_t { 8 });
    spec.param(gated_, "gated", "Gated", "wait for enable()", false);
    spec.param(restart_every_, "restart_every", "RestartEvery", "producer restart every N frames (0 = never)", int64_t { 0 });
    spec.param(restart_lost_, "restart_lost", "RestartLost", "frames lost at each restart", int64_t { 3 });
    spec.param(use_frame_ready_condition_, "use_frame_ready_condition", "UseFrameReadyCondition",
        "AsynchronousCondition set by the producer (HSB's default); false: compute() waits for a frame", true);
    // as HSB's receivers: an asynchronous condition the producer thread sets when a frame is ready,
    // or (use_frame_ready_condition false, as HSB's classic RoceReceiverOp offers) none: the
    // operator is always ready and compute() waits up to 100 ms for the next frame
    bool use_cond = true;
    for (auto& arg : args()) {
        if (arg.name() == "use_frame_ready_condition") {
            use_cond = std::any_cast<bool>(arg.value());
        }
    }
    if (use_cond) {
        ready_ = fragment()->make_condition<holoscan::AsynchronousCondition>("frame_ready");
        add_arg(ready_);
    }
}

void SourceOp::start()
{
    fs_ = frame_size_.get();
    md_off_ = round_up(fs_, PAGE_ALIGN);
    ps_ = md_off_ + METADATA_SIZE;
    stride_ = iq_stride(fs_);
    if (queue_size_.get() < 1 || queue_size_.get() > pages_.get()) {
        throw std::runtime_error("SourceOp: queue_size must be 1..pages");
    }
    ck(cudaMalloc((void**)&ring_, ps_ * pages_.get()), "cudaMalloc ring");
    ck(cudaMemset(ring_, 0, ps_ * pages_.get()), "ring clear");
    if (data_.get() == 2) {
        const auto& cfg = iq_cfg_.get();
        if (cfg.size() != 142) {
            throw std::runtime_error("SourceOp: iq_cfg needs 142 values for IQ16 data");
        }
        ck(cudaMalloc((void**)&cfg_dev_, cfg.size() * 8), "cudaMalloc iq cfg");
        ck(cudaMemcpy(cfg_dev_, cfg.data(), cfg.size() * 8, cudaMemcpyHostToDevice), "iq cfg");
    }
    cudaStream_t s;
    ck(cudaStreamCreateWithFlags(&s, cudaStreamNonBlocking), "source stream");
    stream_ = (void*)s;
    cudaEvent_t e;
    ck(cudaEventCreateWithFlags(&e, cudaEventBlockingSync | cudaEventDisableTiming), "source event");
    done_ = (void*)e;
    ck(cudaDeviceSynchronize(), "source init");
    if (ready_) {
        ready_->event_state(holoscan::AsynchronousEventState::EVENT_WAITING);
    }
    int dev = 0;
    cudaGetDevice(&dev);
    running_ = true;
    thread_ = std::thread([this, dev]() {
        pthread_setname_np(pthread_self(), "rl-producer");   // the synthetic board + NIC
        cudaSetDevice(dev);
        producer();
    });
    std::printf("C++ synthetic data plane: %s frames of %" PRIu64 " B, %u pages, queue %u, %s%s\n",
        data_.get() == 2 ? "IQ16" : "counter", fs_, pages_.get(), queue_size_.get(),
        period_ns_.get() ? "board timeline" : "pull (keeps the queue full)",
        gated_.get() ? ", waits for the start gate" : "");
    std::fflush(stdout);
    if (!gated_.get()) {
        enable();
    }
}

void SourceOp::stop()
{
    running_ = false;
    cv_.notify_all();
    if (thread_.joinable()) {
        thread_.join();
    }
    if (ready_) {
        ready_->event_state(holoscan::AsynchronousEventState::EVENT_NEVER);
    }
    std::printf("C++ synthetic data plane off after %" PRId64 " frames emitted (%" PRId64 " completed, %" PRId64
                " dropped from the receive queue)\n", st_.emitted, completed_, st_.queue_dropped);
    std::fflush(stdout);
    // the ring stays allocated until the operator is destroyed: tensors downstream may still point into it
}

void SourceOp::enable()
{
    if (enabled_.exchange(true)) {
        return;
    }
    t_enable_ns_ = mono_ns();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        st_.enabled = true;
        st_.t_enable = wall();
    }
    cv_.notify_all();
}

SourceStats SourceOp::stats()
{
    std::lock_guard<std::mutex> lock(mutex_);
    SourceStats s = st_;
    s.completed = completed_;
    return s;
}

// the next frame the producer completes (board frame number, extended frame number as HSB's
// receiver reports it, PSN of its metadata packet, page, receiver completion count)
SourceOp::Desc SourceOp::next_desc()
{
    const int64_t every = restart_every_.get();
    const uint32_t ppf = packets_per_frame_.get();
    if (every > 0 && k_ > 0 && k_ % every == 0) {
        // link pause: the frames in flight are lost, the producer resumes at frame 0 / first page /
        // IQ16 sample 0; the engine keeps its PSN
        psn_next_ += (uint64_t)restart_lost_.get() * ppf;
        board_fn_ = 0;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            st_.restarts++;
            st_.lost_injected += restart_lost_.get();
        }
        // a short outage (the board pauses for seconds): the frames before it get consumed before the
        // restarted producer rewrites their pages from the first page on
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    k_++;
    Desc d;
    d.board_fn = board_fn_++;
    const int64_t fn16 = d.board_fn & 0xFFFF;
    ext_ = ext_ < 0 ? fn16 : ext_ + ((fn16 - ext_) & 0xFFFF);       // HSB's frame-number extension
    d.ext_fn = ext_;
    psn_next_ += ppf;
    d.psn = (uint32_t)((psn_next_ - 1) & 0xFFFFFF);
    d.page = d.board_fn % pages_.get();
    return d;
}

void SourceOp::produce(Desc& d)
{
    const uint64_t ptr = (uint64_t)(uintptr_t)(ring_ + d.page * ps_);
    const uint32_t fn16 = (uint32_t)(d.board_fn & 0xFFFF);
    int r;
    if (data_.get() == 2) {
        r = launch_gen(2, ptr, fs_ / 4, fn16, (uint64_t)d.board_fn * stride_, (uint64_t)(uintptr_t)cfg_dev_, stream_);
    } else {
        r = launch_gen(1, ptr, fs_ / 8, fn16, 0, 0, stream_);
    }
    const double now = wall();
    d.ts_s = (int64_t)now;
    d.ts_ns = (int64_t)((now - (double)d.ts_s) * 1e9);
    if (r == 0) {
        r = launch_record(ptr + md_off_, d.psn, fn16, fs_, (uint64_t)d.ts_s, (uint32_t)d.ts_ns, stream_);
    }
    if (r == 0) {
        // the frame is in memory: "complete". A blocking-sync event: the thread sleeps instead of
        // spinning (a spinning wait burns a core and contends with the checker's launches)
        r = (int)cudaEventRecord((cudaEvent_t)done_, (cudaStream_t)stream_);
        if (r == 0) {
            r = (int)cudaEventSynchronize((cudaEvent_t)done_);
        }
    }
    if (r != 0) {
        std::fprintf(stderr, "SourceOp: %s\n", cudaGetErrorString((cudaError_t)r));
        running_ = false;
    }
}

void SourceOp::signal()
{
    if (ready_) {
        ready_->event_state(holoscan::AsynchronousEventState::EVENT_DONE);
    } else {
        cv_.notify_all();
    }
}

void SourceOp::producer()
{
    const uint64_t period = period_ns_.get();
    const size_t qmax = queue_size_.get();
    while (running_) {
        if (!enabled_) {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait_for(lock, std::chrono::milliseconds(1));
            continue;
        }
        if (period == 0) {
            {
                std::unique_lock<std::mutex> lock(mutex_);
                cv_.wait_for(lock, std::chrono::milliseconds(1), [&] { return queue_.size() < qmax || !running_; });
                if (queue_.size() >= qmax) {
                    continue;
                }
            }
            Desc d = next_desc();
            produce(d);
            std::lock_guard<std::mutex> lock(mutex_);
            d.rfn = ++rcount_;
            completed_++;
            queue_.push_back(d);
        } else {
            // board timeline: frame i completes at enable + (i + 1) x period
            const int64_t t_next = t_enable_ns_ + (completed_ + 1) * (int64_t)period;
            const int64_t wait = t_next - mono_ns();
            if (wait > 0) {
                std::this_thread::sleep_for(std::chrono::nanoseconds(std::min<int64_t>(wait, 1000000)));
                continue;
            }
            Desc d = next_desc();
            produce(d);
            std::lock_guard<std::mutex> lock(mutex_);
            d.rfn = ++rcount_;
            completed_++;
            queue_.push_back(d);
            if (queue_.size() > qmax) {
                queue_.pop_front();             // the receiver recycles its oldest ready frame
                st_.queue_dropped++;
            }
        }
        signal();
    }
}

void SourceOp::compute(holoscan::InputContext& /*op_input*/, holoscan::OutputContext& op_output,
    holoscan::ExecutionContext& context)
{
    Desc d;
    {
        std::unique_lock<std::mutex> lock(mutex_);
        if (ready_) {
            ready_->event_state(holoscan::AsynchronousEventState::EVENT_WAITING);
        } else {
            cv_.wait_for(lock, std::chrono::milliseconds(100), [&] { return !queue_.empty() || !running_; });
        }
        if (queue_.empty()) {
            return;
        }
        d = queue_.front();
        queue_.pop_front();
        if (ready_ && !queue_.empty()) {
            ready_->event_state(holoscan::AsynchronousEventState::EVENT_DONE);
        }
    }
    cv_.notify_all();
    uint8_t* page = ring_ + d.page * ps_;
    auto out = nvidia::gxf::Entity::New(context.context());
    if (!out) {
        throw std::runtime_error("SourceOp: Entity::New failed");
    }
    auto t = out.value().add<nvidia::gxf::Tensor>("");
    if (!t) {
        throw std::runtime_error("SourceOp: add tensor failed");
    }
    const nvidia::gxf::Shape shape { (int32_t)fs_ };
    if (!t.value()->wrapMemory(shape, nvidia::gxf::PrimitiveType::kUnsigned8, 1,
            nvidia::gxf::ComputeTrivialStrides(shape, 1), nvidia::gxf::MemoryStorageType::kDevice, page,
            [](void*) { return nvidia::gxf::Success; })) {
        throw std::runtime_error("SourceOp: wrapMemory failed");
    }
    auto md = metadata();
    md->set("frame_number", d.ext_fn);
    md->set("imm_data", (int64_t)((((int64_t)d.psn & 0xFFFFF) << 12) | d.page));
    md->set("page_number", (int64_t)d.page);
    md->set("frame_memory", (int64_t)(uintptr_t)page);
    md->set("dropped", st_.queue_dropped);
    md->set("bytes_written", (int64_t)fs_);
    md->set("received_frame_number", d.rfn);
    md->set("timestamp_s", d.ts_s);
    md->set("timestamp_ns", d.ts_ns);
    md->set("received_s", d.ts_s);
    md->set("received_ns", d.ts_ns);
    md->set("crc", int64_t { 0 });
    op_output.emit(out.value(), "output");
    std::lock_guard<std::mutex> lock(mutex_);
    st_.emitted++;
    if (st_.t_first == 0) {
        st_.t_first = wall();
    }
}

} // namespace rocelet
