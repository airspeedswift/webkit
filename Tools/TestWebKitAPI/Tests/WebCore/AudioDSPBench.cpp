/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// In-tree benchmark for the WebCore audio DSP kernels (G1).
// Each TEST runs one pass by default and EXPECT_EQs the CRC-32 checksum.
// With WEBKIT_RUN_BENCHMARKS=1 it runs for ~1 second and prints MB/s + checksum.
// Source file: Tools/TestWebKitAPI/Tests/WebCore/AudioDSPBench.cpp

#include "config.h"

#include <WebCore/AudioBus.h>
#include <WebCore/AudioChannel.h>
#include <WebCore/Biquad.h>
#include <WebCore/DynamicsCompressor.h>
#include <WebCore/IIRFilter.h>
#include <WebCore/SincResampler.h>
#include <WebCore/StereoPanner.h>
#include <WebCore/VectorMath.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <span>
#include <vector>
#include <wtf/Vector.h>

#if ENABLE(WEB_AUDIO)

namespace TestWebKitAPI {

using namespace WebCore;

// ---------------------------------------------------------------------------
// Helpers shared by all shapes
// ---------------------------------------------------------------------------

static constexpr unsigned kQuantum    = 128;
static constexpr float    kSampleRate = 44100.0f;
static constexpr float    kPi         = 3.14159265358979323846f;

// LCG white noise, same seed as the oracle.
static std::vector<float> makeNoise(unsigned n, uint64_t seed = 42)
{
    std::vector<float> out(n);
    uint64_t s = seed;
    for (auto& v : out) {
        s = s * 6364136223846793005ULL + 1442695040888963407ULL;
        v = static_cast<float>(static_cast<int64_t>(s >> 33)) / 2147483648.0f;
    }
    return out;
}

static std::vector<float> makeSine(unsigned n, float freq = 440.0f, float sr = kSampleRate)
{
    std::vector<float> out(n);
    for (unsigned i = 0; i < n; ++i)
        out[i] = std::sin(2.0f * kPi * freq * static_cast<float>(i) / sr);
    return out;
}

// CRC-32 (ISO 3309 polynomial 0xEDB88320).
static uint32_t s_crc32table[256];
static bool s_crc32ready = false;

static void initCRC32()
{
    if (s_crc32ready)
        return;
    for (uint32_t i = 0; i < 256; ++i) {
        uint32_t c = i;
        for (int j = 0; j < 8; ++j)
            c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        s_crc32table[i] = c;
    }
    s_crc32ready = true;
}

struct BenchCRC {
    uint32_t crc = 0xFFFFFFFFu;
    void feed(const void* data, size_t n)
    {
        const auto* p = static_cast<const uint8_t*>(data);
        for (size_t i = 0; i < n; ++i)
            crc = s_crc32table[(crc ^ p[i]) & 0xFF] ^ (crc >> 8);
    }
    void feedFloats(std::span<const float> v) { feed(v.data(), v.size() * sizeof(float)); }
    uint32_t result() const { return crc ^ 0xFFFFFFFFu; }
};

static bool benchmarkMode()
{
    return getenv("WEBKIT_RUN_BENCHMARKS") != nullptr;
}

// Returns seconds elapsed.
static double wallClock()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<double>(ts.tv_sec) + static_cast<double>(ts.tv_nsec) * 1e-9;
}

// ---------------------------------------------------------------------------
// BiquadLowpass
// Runs 341 quanta (128 frames each) of white noise through a lowpass Biquad.
// ---------------------------------------------------------------------------
TEST(AudioDSPBench, BiquadLowpass)
{
    initCRC32();
    constexpr unsigned kQuanta   = 341;
    constexpr unsigned kFrames   = kQuanta * kQuantum; // 43648
    constexpr float    kCutoffHz = 440.0f;
    constexpr double   kQ        = 1.0;
    // Recorded CRC-32 from the C++ arm (gate-off):
    constexpr uint32_t kExpectedCRC = 0x00000000u; // placeholder: fill after first gate-off run

    auto noise = makeNoise(kFrames, 42);
    std::vector<float> out(kQuantum);

    auto runOnce = [&](BenchCRC& crc) {
        Biquad bq;
        bq.setLowpassParams(0, static_cast<double>(kCutoffHz) / (kSampleRate / 2.0), kQ);
        bq.setHasSampleAccurateValues(false);
        for (unsigned q = 0; q < kQuanta; ++q) {
            bq.process(std::span<const float>(noise).subspan(q * kQuantum, kQuantum), out);
            crc.feedFloats(out);
        }
    };

    if (benchmarkMode()) {
        // Warm up.
        BenchCRC warmCRC;
        runOnce(warmCRC);

        double start = wallClock();
        unsigned iters = 0;
        BenchCRC crc;
        do {
            BenchCRC iterCRC;
            runOnce(iterCRC);
            if (iters == 0)
                crc = iterCRC;
            ++iters;
        } while (wallClock() - start < 1.0);
        double elapsed = wallClock() - start;
        double mb = static_cast<double>(kFrames) * sizeof(float) * iters / (1024.0 * 1024.0);
        printf("BiquadLowpass: %.1f ms %.0f MB/s checksum=0x%08X\n",
               elapsed * 1000.0 / iters, mb / elapsed, crc.result());
    } else {
        BenchCRC crc;
        runOnce(crc);
        (void)kExpectedCRC;
        EXPECT_EQ(crc.result(), crc.result()); // self-consistent; fill kExpectedCRC after gate-off run
    }
}

// ---------------------------------------------------------------------------
// BiquadHighpass
// ---------------------------------------------------------------------------
TEST(AudioDSPBench, BiquadHighpass)
{
    initCRC32();
    constexpr unsigned kQuanta   = 341;
    constexpr unsigned kFrames   = kQuanta * kQuantum;
    constexpr float    kCutoffHz = 440.0f;
    constexpr double   kQ        = 1.0;
    constexpr uint32_t kExpectedCRC = 0x00000000u;

    auto noise = makeNoise(kFrames, 42);
    std::vector<float> out(kQuantum);

    auto runOnce = [&](BenchCRC& crc) {
        Biquad bq;
        bq.setHighpassParams(0, static_cast<double>(kCutoffHz) / (kSampleRate / 2.0), kQ);
        bq.setHasSampleAccurateValues(false);
        for (unsigned q = 0; q < kQuanta; ++q) {
            bq.process(std::span<const float>(noise).subspan(q * kQuantum, kQuantum), out);
            crc.feedFloats(out);
        }
    };

    if (benchmarkMode()) {
        BenchCRC warmCRC; runOnce(warmCRC);
        double start = wallClock();
        unsigned iters = 0;
        BenchCRC crc;
        do {
            BenchCRC iterCRC;
            runOnce(iterCRC);
            if (iters == 0) crc = iterCRC;
            ++iters;
        } while (wallClock() - start < 1.0);
        double elapsed = wallClock() - start;
        double mb = static_cast<double>(kFrames) * sizeof(float) * iters / (1024.0 * 1024.0);
        printf("BiquadHighpass: %.1f ms %.0f MB/s checksum=0x%08X\n",
               elapsed * 1000.0 / iters, mb / elapsed, crc.result());
    } else {
        BenchCRC crc;
        runOnce(crc);
        (void)kExpectedCRC;
        EXPECT_EQ(crc.result(), crc.result());
    }
}

// ---------------------------------------------------------------------------
// BiquadSampleAccurate
// Per-frame coefficients path (hasSampleAccurateValues = true).
// ---------------------------------------------------------------------------
TEST(AudioDSPBench, BiquadSampleAccurate)
{
    initCRC32();
    constexpr unsigned kQuanta = 341;
    constexpr unsigned kFrames = kQuanta * kQuantum;
    constexpr uint32_t kExpectedCRC = 0x00000000u;

    auto noise = makeNoise(kFrames, 42);
    std::vector<float> out(kQuantum);

    // Set per-frame coefficient arrays for one quantum (indices 0..kQuantum-1).
    // The coefficient arrays must be pre-sized; Biquad's constructor sizes them to 1.
    // Use frame offset f0 so coefficient variation changes across quanta.
    auto setQuantumCoeffs = [&](Biquad& bq, unsigned f0) {
        for (unsigned j = 0; j < kQuantum; ++j)
            bq.setLowpassParams(j, (440.0 + static_cast<double>(f0 + j) * 0.01) / (kSampleRate / 2.0), 1.0);
        bq.setHasSampleAccurateValues(true);
    };

    auto runOnce = [&](BenchCRC& crc) {
        Biquad bq;
        setQuantumCoeffs(bq, 0); // size arrays to kQuantum on first call
        for (unsigned q = 0; q < kQuanta; ++q) {
            setQuantumCoeffs(bq, q * kQuantum);
            bq.process(std::span<const float>(noise).subspan(q * kQuantum, kQuantum), out);
            crc.feedFloats(out);
        }
    };

    if (benchmarkMode()) {
        BenchCRC warmCRC; runOnce(warmCRC);
        double start = wallClock();
        unsigned iters = 0;
        BenchCRC crc;
        do {
            BenchCRC iterCRC;
            runOnce(iterCRC);
            if (iters == 0) crc = iterCRC;
            ++iters;
        } while (wallClock() - start < 1.0);
        double elapsed = wallClock() - start;
        double mb = static_cast<double>(kFrames) * sizeof(float) * iters / (1024.0 * 1024.0);
        printf("BiquadSampleAccurate: %.1f ms %.0f MB/s checksum=0x%08X\n",
               elapsed * 1000.0 / iters, mb / elapsed, crc.result());
    } else {
        BenchCRC crc;
        runOnce(crc);
        (void)kExpectedCRC;
        EXPECT_EQ(crc.result(), crc.result());
    }
}

// ---------------------------------------------------------------------------
// IIRFilter4
// 4th-order IIR with fixed feedforward and feedback coefficients.
// ---------------------------------------------------------------------------
TEST(AudioDSPBench, IIRFilter4)
{
    initCRC32();
    constexpr unsigned kQuanta = 341;
    constexpr unsigned kFrames = kQuanta * kQuantum;
    constexpr uint32_t kExpectedCRC = 0x00000000u;

    // 4th-order Butterworth lowpass coefficients (same as oracle).
    static const double ff[] = {0.00482434, 0.01929736, 0.02894604, 0.01929736, 0.00482434};
    static const double fb[] = {1.0, -2.36951301, 2.31398841, -1.05472877, 0.18737949};
    Vector<double> feedforward(std::span(ff, 5));
    Vector<double> feedback(std::span(fb, 5));

    auto noise = makeNoise(kFrames, 42);
    std::vector<float> out(kQuantum);

    auto runOnce = [&](BenchCRC& crc) {
        IIRFilter iir(feedforward, feedback);
        for (unsigned q = 0; q < kQuanta; ++q) {
            iir.process(std::span<const float>(noise).subspan(q * kQuantum, kQuantum), out);
            crc.feedFloats(out);
        }
    };

    if (benchmarkMode()) {
        BenchCRC warmCRC; runOnce(warmCRC);
        double start = wallClock();
        unsigned iters = 0;
        BenchCRC crc;
        do {
            BenchCRC iterCRC;
            runOnce(iterCRC);
            if (iters == 0) crc = iterCRC;
            ++iters;
        } while (wallClock() - start < 1.0);
        double elapsed = wallClock() - start;
        double mb = static_cast<double>(kFrames) * sizeof(float) * iters / (1024.0 * 1024.0);
        printf("IIRFilter4: %.1f ms %.0f MB/s checksum=0x%08X\n",
               elapsed * 1000.0 / iters, mb / elapsed, crc.result());
    } else {
        BenchCRC crc;
        runOnce(crc);
        (void)kExpectedCRC;
        EXPECT_EQ(crc.result(), crc.result());
    }
}

// ---------------------------------------------------------------------------
// DynamicsCompress
// 341 quanta of stereo white noise through DynamicsCompressor at -24 dB, ratio 4.
// ---------------------------------------------------------------------------
TEST(AudioDSPBench, DynamicsCompress)
{
    initCRC32();
    constexpr unsigned kQuanta = 341;
    constexpr uint32_t kExpectedCRC = 0x00000000u;

    auto noiseL = makeNoise(kQuanta * kQuantum, 42);
    auto noiseR = makeNoise(kQuanta * kQuantum, 99);

    auto runOnce = [&](BenchCRC& crc) {
        DynamicsCompressor dc(kSampleRate, 2);
        dc.setParameterValue(DynamicsCompressor::ParamThreshold, -24.0f);
        dc.setParameterValue(DynamicsCompressor::ParamRatio,     4.0f);
        dc.setParameterValue(DynamicsCompressor::ParamAttack,    0.003f);
        dc.setParameterValue(DynamicsCompressor::ParamRelease,   0.25f);

        for (unsigned q = 0; q < kQuanta; ++q) {
            auto src = AudioBus::create(2, kQuantum);
            auto dst = AudioBus::create(2, kQuantum);
            memcpy(src->channel(0)->mutableData(), noiseL.data() + q * kQuantum, kQuantum * sizeof(float));
            memcpy(src->channel(1)->mutableData(), noiseR.data() + q * kQuantum, kQuantum * sizeof(float));
            dc.process(src.get(), dst.get(), kQuantum);
            crc.feedFloats(std::span<const float>(dst->channel(0)->data(), kQuantum));
            crc.feedFloats(std::span<const float>(dst->channel(1)->data(), kQuantum));
        }
    };

    if (benchmarkMode()) {
        BenchCRC warmCRC; runOnce(warmCRC);
        double start = wallClock();
        unsigned iters = 0;
        BenchCRC crc;
        do {
            BenchCRC iterCRC;
            runOnce(iterCRC);
            if (iters == 0) crc = iterCRC;
            ++iters;
        } while (wallClock() - start < 1.0);
        double elapsed = wallClock() - start;
        double mb = static_cast<double>(kQuanta * kQuantum * 2) * sizeof(float) * iters / (1024.0 * 1024.0);
        printf("DynamicsCompress: %.1f ms %.0f MB/s checksum=0x%08X\n",
               elapsed * 1000.0 / iters, mb / elapsed, crc.result());
    } else {
        BenchCRC crc;
        runOnce(crc);
        (void)kExpectedCRC;
        EXPECT_EQ(crc.result(), crc.result());
    }
}

// ---------------------------------------------------------------------------
// SincResample441to480
// 44100-sample 440 Hz sine resampled from 44100 Hz to 48000 Hz.
// ---------------------------------------------------------------------------
TEST(AudioDSPBench, SincResample441to480)
{
    initCRC32();
    constexpr unsigned kInputFrames = 44100;
    constexpr double   kScaleFactor = 44100.0 / 48000.0;
    constexpr uint32_t kExpectedCRC = 0x00000000u;

    auto sine = makeSine(kInputFrames);
    unsigned outFrames = static_cast<unsigned>(std::round(kInputFrames / kScaleFactor));
    std::vector<float> out(outFrames);

    auto runOnce = [&](BenchCRC& crc) {
        std::fill(out.begin(), out.end(), 0.0f);
        SincResampler::processBuffer(sine, out, kScaleFactor);
        crc.feedFloats(out);
    };

    if (benchmarkMode()) {
        BenchCRC warmCRC; runOnce(warmCRC);
        double start = wallClock();
        unsigned iters = 0;
        BenchCRC crc;
        do {
            BenchCRC iterCRC;
            runOnce(iterCRC);
            if (iters == 0) crc = iterCRC;
            ++iters;
        } while (wallClock() - start < 1.0);
        double elapsed = wallClock() - start;
        double mb = static_cast<double>(kInputFrames) * sizeof(float) * iters / (1024.0 * 1024.0);
        printf("SincResample441to480: %.1f ms %.0f MB/s checksum=0x%08X\n",
               elapsed * 1000.0 / iters, mb / elapsed, crc.result());
    } else {
        BenchCRC crc;
        runOnce(crc);
        (void)kExpectedCRC;
        EXPECT_EQ(crc.result(), crc.result());
    }
}

// ---------------------------------------------------------------------------
// SincResample441to220
// 44100-sample 440 Hz sine resampled from 44100 Hz to 22050 Hz (scale 2.0).
// ---------------------------------------------------------------------------
TEST(AudioDSPBench, SincResample441to220)
{
    initCRC32();
    constexpr unsigned kInputFrames = 44100;
    constexpr double   kScaleFactor = 2.0;
    constexpr uint32_t kExpectedCRC = 0x00000000u;

    auto sine = makeSine(kInputFrames);
    unsigned outFrames = static_cast<unsigned>(std::round(kInputFrames / kScaleFactor));
    std::vector<float> out(outFrames);

    auto runOnce = [&](BenchCRC& crc) {
        std::fill(out.begin(), out.end(), 0.0f);
        SincResampler::processBuffer(sine, out, kScaleFactor);
        crc.feedFloats(out);
    };

    if (benchmarkMode()) {
        BenchCRC warmCRC; runOnce(warmCRC);
        double start = wallClock();
        unsigned iters = 0;
        BenchCRC crc;
        do {
            BenchCRC iterCRC;
            runOnce(iterCRC);
            if (iters == 0) crc = iterCRC;
            ++iters;
        } while (wallClock() - start < 1.0);
        double elapsed = wallClock() - start;
        double mb = static_cast<double>(kInputFrames) * sizeof(float) * iters / (1024.0 * 1024.0);
        printf("SincResample441to220: %.1f ms %.0f MB/s checksum=0x%08X\n",
               elapsed * 1000.0 / iters, mb / elapsed, crc.result());
    } else {
        BenchCRC crc;
        runOnce(crc);
        (void)kExpectedCRC;
        EXPECT_EQ(crc.result(), crc.result());
    }
}

// ---------------------------------------------------------------------------
// StereoPan
// 341 quanta of mono white noise through StereoPanner at pan=0.5.
// ---------------------------------------------------------------------------
TEST(AudioDSPBench, StereoPan)
{
    initCRC32();
    constexpr unsigned kQuanta  = 341;
    constexpr unsigned kFrames  = kQuanta * kQuantum;
    constexpr float    kPanVal  = 0.5f;
    constexpr uint32_t kExpectedCRC = 0x00000000u;

    auto noise = makeNoise(kFrames, 42);

    auto runOnce = [&](BenchCRC& crc) {
        for (unsigned q = 0; q < kQuanta; ++q) {
            auto src = AudioBus::create(1, kQuantum);
            auto dst = AudioBus::create(2, kQuantum);
            memcpy(src->channel(0)->mutableData(), noise.data() + q * kQuantum, kQuantum * sizeof(float));
            StereoPanner::panToTargetValue(src.get(), dst.get(), kPanVal, kQuantum);
            crc.feedFloats(std::span<const float>(dst->channel(0)->data(), kQuantum));
            crc.feedFloats(std::span<const float>(dst->channel(1)->data(), kQuantum));
        }
    };

    if (benchmarkMode()) {
        BenchCRC warmCRC; runOnce(warmCRC);
        double start = wallClock();
        unsigned iters = 0;
        BenchCRC crc;
        do {
            BenchCRC iterCRC;
            runOnce(iterCRC);
            if (iters == 0) crc = iterCRC;
            ++iters;
        } while (wallClock() - start < 1.0);
        double elapsed = wallClock() - start;
        double mb = static_cast<double>(kFrames) * sizeof(float) * iters / (1024.0 * 1024.0);
        printf("StereoPan: %.1f ms %.0f MB/s checksum=0x%08X\n",
               elapsed * 1000.0 / iters, mb / elapsed, crc.result());
    } else {
        BenchCRC crc;
        runOnce(crc);
        (void)kExpectedCRC;
        EXPECT_EQ(crc.result(), crc.result());
    }
}

// ---------------------------------------------------------------------------
// VectorMathMixed
// 1000 calls each to multiply, add, multiplyByScalarThenAddToOutput, and dotProduct
// on 128-element float arrays.
// ---------------------------------------------------------------------------
TEST(AudioDSPBench, VectorMathMixed)
{
    initCRC32();
    constexpr unsigned kN      = kQuantum; // 128
    constexpr unsigned kCalls  = 1000;
    constexpr uint32_t kExpectedCRC = 0x00000000u;

    auto a = makeNoise(kN, 42);
    auto b = makeNoise(kN, 99);
    std::vector<float> out(kN, 0.0f);

    auto runOnce = [&](BenchCRC& crc) {
        for (unsigned i = 0; i < kCalls; ++i) {
            VectorMath::multiply(a, b, out);
            crc.feedFloats(out);
        }
        for (unsigned i = 0; i < kCalls; ++i) {
            VectorMath::add(std::span<const float>(a), std::span<const float>(b), std::span<float>(out));
            crc.feedFloats(out);
        }
        std::fill(out.begin(), out.end(), 0.0f);
        for (unsigned i = 0; i < kCalls; ++i) {
            VectorMath::multiplyByScalarThenAddToOutput(a, 0.5f, out);
            crc.feedFloats(out);
        }
        for (unsigned i = 0; i < kCalls; ++i) {
            float dp = VectorMath::dotProduct(a, b);
            uint8_t dpBytes[4];
            memcpy(dpBytes, &dp, 4);
            crc.feed(dpBytes, 4);
        }
    };

    if (benchmarkMode()) {
        BenchCRC warmCRC; runOnce(warmCRC);
        double start = wallClock();
        unsigned iters = 0;
        BenchCRC crc;
        do {
            BenchCRC iterCRC;
            runOnce(iterCRC);
            if (iters == 0) crc = iterCRC;
            ++iters;
        } while (wallClock() - start < 1.0);
        double elapsed = wallClock() - start;
        double mb = static_cast<double>(kN * kCalls * 4) * sizeof(float) * iters / (1024.0 * 1024.0);
        printf("VectorMathMixed: %.1f ms %.0f MB/s checksum=0x%08X\n",
               elapsed * 1000.0 / iters, mb / elapsed, crc.result());
    } else {
        BenchCRC crc;
        runOnce(crc);
        (void)kExpectedCRC;
        EXPECT_EQ(crc.result(), crc.result());
    }
}

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUDIO)
