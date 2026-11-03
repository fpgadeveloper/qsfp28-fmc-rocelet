// SPDX-License-Identifier: MIT
//
// rocelet_hsb_kernels.cu - CUDA kernels of the qsfp28-fmc-rocelet HSB host application
// (rocelet_hsb_app.py, compiled at run time by CuPy / NVRTC; no includes):
//   * frame checkers: counter pattern (64-bit word w of frame f = f[15:0] << 48 | 8 w) and the
//     IQ16 test signal against its bit-exact model; mismatching words that belong to a LATER
//     frame of the same page ring are counted apart ("overrun": the board reused the page
//     before the checker read it), everything else is an error;
//   * the 128-byte HSB metadata record: read (big-endian) and write (synthetic source);
//   * synthetic frame generators (counter, IQ16 model);
//   * spectrogram helpers: IQ16 -> windowed complex float, |X|^2 accumulation, the dB row,
//     the waterfall colour image.
//
// The IQ16 model (iq_exp, iq_hash, iq_noise1, iq_sample) is a CUDA port of the bit-exact numpy
// model rocelet_iq.py (exp_phi, _hash, _noise1, samples; the lane coefficients C_t,k of plan()
// come in with cfg), with n0 = 0. Signed >> on long long is an arithmetic shift
// in NVRTC/nvcc, so asr(x, s) = x >> s.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

typedef unsigned long long u64;
typedef long long i64;
typedef unsigned int u32;

__constant__ int IQ_TAB[256] = {
    402, 1206, 2011, 2815, 3619, 4422, 5226, 6030, 6833, 7636, 8439, 9241, 10043, 10845, 11646, 12447,
    13247, 14047, 14847, 15645, 16444, 17241, 18038, 18834, 19630, 20425, 21219, 22012, 22804, 23596, 24386, 25176,
    25965, 26753, 27540, 28325, 29110, 29894, 30676, 31457, 32238, 33016, 33794, 34571, 35346, 36119, 36892, 37663,
    38433, 39201, 39967, 40733, 41496, 42258, 43019, 43778, 44535, 45290, 46044, 46796, 47547, 48295, 49042, 49787,
    50530, 51271, 52010, 52748, 53483, 54216, 54947, 55676, 56403, 57128, 57851, 58572, 59290, 60006, 60720, 61432,
    62141, 62848, 63552, 64254, 64954, 65652, 66346, 67039, 67729, 68416, 69101, 69783, 70462, 71139, 71813, 72484,
    73153, 73819, 74482, 75143, 75800, 76455, 77107, 77756, 78402, 79045, 79685, 80322, 80956, 81587, 82215, 82839,
    83461, 84080, 84695, 85307, 85916, 86522, 87124, 87724, 88319, 88912, 89501, 90087, 90670, 91249, 91824, 92396,
    92965, 93530, 94092, 94650, 95205, 95756, 96303, 96847, 97387, 97923, 98456, 98985, 99510, 100032, 100550, 101064,
    101574, 102080, 102583, 103081, 103576, 104067, 104554, 105037, 105516, 105991, 106462, 106930, 107393, 107852, 108307, 108758,
    109204, 109647, 110086, 110520, 110950, 111377, 111798, 112216, 112630, 113039, 113444, 113844, 114241, 114633, 115021, 115404,
    115783, 116158, 116528, 116894, 117256, 117613, 117966, 118314, 118658, 118998, 119332, 119663, 119989, 120310, 120627, 120939,
    121247, 121550, 121849, 122143, 122432, 122717, 122997, 123273, 123544, 123810, 124072, 124329, 124581, 124829, 125072, 125310,
    125543, 125772, 125996, 126215, 126430, 126639, 126844, 127045, 127240, 127431, 127617, 127798, 127974, 128145, 128312, 128473,
    128630, 128782, 128930, 129072, 129209, 129342, 129470, 129593, 129711, 129824, 129932, 130035, 130134, 130227, 130316, 130400,
    130479, 130553, 130622, 130686, 130745, 130799, 130848, 130893, 130932, 130967, 130996, 131021, 131041, 131056, 131065, 131070
};

// cfg (int64): 0-3 tone inc, 4-7 tone amp, 8 chirp start inc, 9 chirp rate (signed), 10 chirp
// period, 11 chirp amp, 12 noise amp, 13 noise seed, 14 + 32 t + 2 k + c: lane coefficient C_t,k
#define CFG_N 142

__device__ __forceinline__ i64 iq_rnd(i64 x, unsigned s) { return (x + (1LL << (s - 1))) >> s; }

__device__ __forceinline__ void iq_exp(u32 phi, i64 *re, i64 *im)
{
    u32 p = phi >> 22, quad = p >> 8, i = p & 255u;
    i64 sb = IQ_TAB[i], cb = IQ_TAB[255u - i], c, s;
    i64 d = (i64)(phi & 0x3FFFFFu) - 0x200000;
    i64 th = (d * 411775) >> 18;
    switch (quad) {
    case 0:  c = cb;  s = sb;  break;
    case 1:  c = -sb; s = cb;  break;
    case 2:  c = -cb; s = -sb; break;
    default: c = sb;  s = -cb; break;
    }
    *re = c - iq_rnd(s * th, 30);
    *im = s + iq_rnd(c * th, 30);
}

__device__ __forceinline__ u32 iq_hash(u32 x)
{
    x ^= x >> 16; x *= 0x7FEB352Du; x ^= x >> 15; x *= 0x846CA68Bu; x ^= x >> 16;
    return x;
}

__device__ __forceinline__ i64 iq_noise1(u32 h, i64 amp)
{
    i64 u = (i64)((h & 255u) + ((h >> 8) & 255u) + ((h >> 16) & 255u) + (h >> 24)) - 510;
    return iq_rnd(u * amp, 7);
}

// sample n (n0 = 0) as the little-endian word (uint16)I | (uint16)Q << 16; cfg in shared memory
__device__ u32 iq_sample(const i64 *cfg, u64 n)
{
    u64 q = n >> 4;
    unsigned k = (unsigned)(n & 15u);
    i64 si = 0, sq = 0;
    for (int t = 0; t < 4; t++) {
        if (cfg[4 + t] == 0)
            continue;
        i64 bc, bs;
        iq_exp((u32)(((u32)cfg[t] << 4) * (u32)q), &bc, &bs);
        i64 cr = cfg[14 + 32 * t + 2 * k], ci = cfg[14 + 32 * t + 2 * k + 1];
        si += iq_rnd(bc * cr - bs * ci, 25);
        sq += iq_rnd(bc * ci + bs * cr, 25);
    }
    if (cfg[10] != 0 && cfg[11] != 0) {
        u64 m = n % (u64)cfg[10];
        u64 tm = (m & 1u) ? m * ((m - 1u) >> 1) : (m >> 1) * (m - 1u);
        u64 acc = ((((u64)(u32)cfg[8]) << 16) * m + (u64)cfg[9] * tm) & ((1ull << 48) - 1u);
        i64 er, ei;
        iq_exp((u32)(acc >> 16), &er, &ei);
        si += iq_rnd(cfg[11] * er, 17);
        sq += iq_rnd(cfg[11] * ei, 17);
    }
    if (cfg[12] != 0) {
        u32 key = (u32)cfg[13] ^ ((u32)(n >> 32) * 0x9E3779B9u);
        u32 lo = (u32)n ^ key;
        si += iq_noise1(iq_hash(lo), cfg[12]);
        sq += iq_noise1(iq_hash(lo ^ 0x68E31DA4u), cfg[12]);
    }
    si = si > 32767 ? 32767 : (si < -32768 ? -32768 : si);
    sq = sq > 32767 ? 32767 : (sq < -32768 ? -32768 : sq);
    return (u32)(unsigned short)si | ((u32)(unsigned short)sq << 16);
}

__device__ __forceinline__ void load_cfg(i64 *s, const i64 *g)
{
    for (int i = threadIdx.x; i < CFG_N; i += blockDim.x)
        s[i] = g[i];
    __syncthreads();
}

// warp-aggregated counting of two flags + the first error index
__device__ __forceinline__ void tally(bool err, bool ovr, u64 idx, u64 *res)
{
    unsigned m = __activemask();
    unsigned be = __ballot_sync(m, err), bo = __ballot_sync(m, ovr);
    int lane = threadIdx.x & 31, leader = __ffs(m) - 1;
    if (lane == leader) {
        if (be) atomicAdd(&res[0], (u64)__popc(be));
        if (bo) atomicAdd(&res[1], (u64)__popc(bo));
    }
    if (err)
        atomicMin(&res[2], idx);
}

// ---------------- checkers: res = one 8-word result slot ----------------
// res[0] error words, [1] overrun words, [2] first error index (init ~0); [6] blocks done (chk_frame)
extern "C" __global__ void chk_counter(const u64 *src, u64 words, u32 fn16, u64 *res)
{
    for (u64 w = blockIdx.x * (u64)blockDim.x + threadIdx.x; w < words; w += (u64)gridDim.x * blockDim.x) {
        u64 v = src[w], e = ((u64)fn16 << 48) | (w << 3);
        bool ok = v == e;
        bool ovr = !ok && (v & 0xFFFFFFFFFFFFull) == (w << 3) && ((((u32)(v >> 48)) - fn16) & 0xFFFFu) - 1u < 32767u;
        if (__any_sync(__activemask(), !ok))
            tally(!ok && !ovr, ovr, w, res);
    }
}

// samples n_first + j; a mismatch that equals sample n + k later_step (k = 1..4) is an overrun
extern "C" __global__ void chk_iq(const u32 *src, u64 nsamp, u64 n_first, u64 later_step, const i64 *cfg_g, u64 *res)
{
    __shared__ i64 cfg[CFG_N];
    load_cfg(cfg, cfg_g);
    for (u64 j = blockIdx.x * (u64)blockDim.x + threadIdx.x; j < nsamp; j += (u64)gridDim.x * blockDim.x) {
        u32 v = src[j];
        bool ok = v == iq_sample(cfg, n_first + j), ovr = false;
        if (!ok)
            for (int k = 1; k <= 4 && !ovr; k++)
                ovr = v == iq_sample(cfg, n_first + j + k * later_step);
        if (__any_sync(__activemask(), !ok))
            tally(!ok && !ovr, ovr, j, res);
    }
}

__device__ __forceinline__ u64 be(const unsigned char *p, int n)
{
    u64 v = 0;
    for (int i = 0; i < n; i++)
        v = (v << 8) | p[i];
    return v;
}

// the record's fields into a result slot: [3] psn [4] frame number [5] bytes_written [6] flags
extern "C" __global__ void rd_record(const unsigned char *rec, u64 *res)
{
    if (threadIdx.x == 0 && blockIdx.x == 0) {
        res[3] = be(rec + 4, 4);
        res[4] = be(rec + 34, 2);
        res[5] = be(rec + 24, 8);
        res[6] = be(rec + 0, 4);
    }
}

// the record's frame number again after the check: [7]
extern "C" __global__ void rd_record_fn(const unsigned char *rec, u64 *res)
{
    if (threadIdx.x == 0 && blockIdx.x == 0)
        res[7] = be(rec + 34, 2);
}

// One launch per frame (the application's per-frame cost is the launch): block 0 reads the
// record first ([3] psn [4] frame number [5] bytes_written), every block checks its share of the
// data (mode 1 counter, 2 IQ16, 0 none), and the last block to finish (threadfence + counter in
// res[6]) reads the record's frame number again ([7]: the page was reused during the check).
extern "C" __global__ void chk_frame(int mode, const unsigned char *frame, u64 n, u32 fn16, u64 n_first,
                                     u64 later_step, const i64 *cfg_g, const unsigned char *rec, u64 *res)
{
    __shared__ i64 cfg[CFG_N];
    __shared__ bool last;
    if (blockIdx.x == 0 && threadIdx.x == 0) {
        res[3] = be(rec + 4, 4);
        res[4] = be(rec + 34, 2);
        res[5] = be(rec + 24, 8);
    }
    if (mode == 2)
        load_cfg(cfg, cfg_g);
    u64 stride = (u64)gridDim.x * blockDim.x;
    if (mode == 1) {
        const u64 *src = (const u64 *)frame;
        for (u64 w = blockIdx.x * (u64)blockDim.x + threadIdx.x; w < n; w += stride) {
            u64 v = src[w], e = ((u64)fn16 << 48) | (w << 3);
            bool ok = v == e;
            bool ovr = !ok && (v & 0xFFFFFFFFFFFFull) == (w << 3) && ((((u32)(v >> 48)) - fn16) & 0xFFFFu) - 1u < 32767u;
            if (__any_sync(__activemask(), !ok))
                tally(!ok && !ovr, ovr, w, res);
        }
    } else if (mode == 2) {
        const u32 *src = (const u32 *)frame;
        for (u64 j = blockIdx.x * (u64)blockDim.x + threadIdx.x; j < n; j += stride) {
            u32 v = src[j];
            bool ok = v == iq_sample(cfg, n_first + j), ovr = false;
            if (!ok)
                for (int k = 1; k <= 4 && !ovr; k++)
                    ovr = v == iq_sample(cfg, n_first + j + k * later_step);
            if (__any_sync(__activemask(), !ok))
                tally(!ok && !ovr, ovr, j, res);
        }
    }
    __threadfence();
    __syncthreads();
    if (threadIdx.x == 0)
        last = atomicAdd(&res[6], 1ull) == gridDim.x - 1;
    __syncthreads();
    if (last && threadIdx.x == 0)
        res[7] = be((const unsigned char *)(((volatile unsigned char *)rec) + 0) + 34, 2);
}

// ---------------- synthetic source ----------------
extern "C" __global__ void gen_counter(u64 *dst, u64 words, u32 fn16)
{
    for (u64 w = blockIdx.x * (u64)blockDim.x + threadIdx.x; w < words; w += (u64)gridDim.x * blockDim.x)
        dst[w] = ((u64)fn16 << 48) | (w << 3);
}

extern "C" __global__ void gen_iq(u32 *dst, u64 nsamp, u64 n_first, const i64 *cfg_g)
{
    __shared__ i64 cfg[CFG_N];
    load_cfg(cfg, cfg_g);
    for (u64 j = blockIdx.x * (u64)blockDim.x + threadIdx.x; j < nsamp; j += (u64)gridDim.x * blockDim.x)
        dst[j] = iq_sample(cfg, n_first + j);
}

__device__ __forceinline__ void put_be(unsigned char *p, u64 v, int n)
{
    for (int i = n - 1; i >= 0; i--, v >>= 8)
        p[i] = (unsigned char)v;
}

// a 128-byte HSB metadata record (frame_metadata_parser.hpp layout, big-endian)
extern "C" __global__ void wr_record(unsigned char *rec, u32 psn, u32 fn16, u64 bytes_written, u64 ts_s, u32 ts_ns,
                                     u64 md_s, u32 md_ns)
{
    int i = threadIdx.x;
    if (i < 128)
        rec[i] = 0;
    __syncthreads();
    if (i == 0) {
        put_be(rec + 4, psn, 4);
        put_be(rec + 12, ts_s, 8);
        put_be(rec + 20, ts_ns, 4);
        put_be(rec + 24, bytes_written, 8);
        put_be(rec + 34, fn16, 2);
        put_be(rec + 36, md_s, 8);
        put_be(rec + 44, md_ns, 4);
    }
}

// flip one bit of a frame (corruption injection)
extern "C" __global__ void flip_bit(unsigned char *p, u64 off, u32 bit)
{
    if (threadIdx.x == 0 && blockIdx.x == 0)
        p[off] ^= (unsigned char)(1u << bit);
}

// ---------------- spectrogram ----------------
// samples (int16 I, Q) -> windowed complex float, frames of nfft samples
extern "C" __global__ void iq_to_c64(const short2 *src, float2 *dst, const float *win, u32 nfft, u64 nsamp)
{
    for (u64 j = blockIdx.x * (u64)blockDim.x + threadIdx.x; j < nsamp; j += (u64)gridDim.x * blockDim.x) {
        short2 s = src[j];
        float w = win[j % nfft];
        dst[j] = make_float2(w * (float)s.x, w * (float)s.y);
    }
}

// acc[b] += sum over the transforms of |X[r][b]|^2
extern "C" __global__ void pow_accum(const float2 *X, float *acc, u32 nfft, u32 rows)
{
    u32 b = blockIdx.x * blockDim.x + threadIdx.x;
    if (b >= nfft)
        return;
    float s = 0.f;
    for (u32 r = 0; r < rows; r++) {
        float2 x = X[(u64)r * nfft + b];
        s += x.x * x.x + x.y * x.y;
    }
    acc[b] += s;
}

// close a row: column c = bins of -Fs/2 .. +Fs/2 (FFT shift), summed per column, scaled to dBFS
// (scale = 1 / (transforms x nfft x sum(w^2) x 32767^2): a full-scale tone reads 0 dBFS),
// row_db (float) and the 8-bit row (0 = db_top - db_range or below, 255 = db_top or above)
extern "C" __global__ void row_close(const float *acc, float *row_db, unsigned char *row_u8, u32 nfft, u32 cols,
                                     float scale, float db_top, float db_range)
{
    u32 c = blockIdx.x * blockDim.x + threadIdx.x;
    if (c >= cols)
        return;
    u32 per = nfft / cols;
    float s = 0.f;
    for (u32 i = 0; i < per; i++)
        s += acc[(c * per + i + nfft / 2) % nfft];
    float db = 10.f * log10f(s * scale + 1e-30f);
    row_db[c] = db;
    float v = (db - (db_top - db_range)) / db_range * 255.f;
    row_u8[c] = (unsigned char)(v < 0.f ? 0.f : (v > 255.f ? 255.f : v + 0.5f));
}

// waterfall image: a full-window canvas of Htot x W pixels (Holoviz stretches a colour image to
// the window); rows y0 .. y0 + H - 1 hold the waterfall (rows[H][W] ring, newest = index head, at
// the top), the rest is black for the text and the spectrum trace.
extern "C" __global__ void waterfall_rgba(const unsigned char *rows, u32 H, u32 W, u32 head, const uchar4 *lut,
                                          uchar4 *out, u32 y0, u32 Htot)
{
    u32 x = blockIdx.x * blockDim.x + threadIdx.x, y = blockIdx.y;
    if (x >= W || y >= Htot)
        return;
    if (y < y0 || y >= y0 + H) {
        out[(u64)y * W + x] = make_uchar4(0, 0, 0, 255);
        return;
    }
    u32 r = (head + H - (y - y0)) % H;
    out[(u64)y * W + x] = lut[rows[(u64)r * W + x]];
}
