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

// In-tree benchmark for the WebCore audio DSP kernels.
// Each TEST runs one pass by default and compares its checksum.
// With WEBKIT_RUN_BENCHMARKS=1 it runs for ~1 second and prints MB/s + checksum.

#include "config.h"

#include "AudioDSPBenchSupport.h"
#include <WebCore/AudioBus.h>
#include <WebCore/AudioChannel.h>
#include <WebCore/DynamicsCompressor.h>
#include <WebCore/SincResampler.h>
#include <WebCore/StereoPanner.h>
#include <WebCore/VectorMath.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <new>
#include <span>
#include <vector>
#include <wtf/Vector.h>

#if ENABLE(WEB_AUDIO)

namespace TestWebKitAPI {

using namespace WebCore;


static constexpr float    kPi         = 3.14159265358979323846f;

// LCG white noise.
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

static std::vector<float> makeSine(unsigned n, float freq = 440.0f, float sr = sampleRate)
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

// Returns seconds elapsed.
static double wallClock()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<double>(ts.tv_sec) + static_cast<double>(ts.tv_nsec) * 1e-9;
}


// The four filter shapes drive BiquadProcessor and IIRProcessor, the entry points that WebCore's callers use
// (BiquadDelayNode, BiquadFilterNode and IIRFilterNode create them). One pass is 341 quanta of 128 frames.

// Checksums of the output bits, recorded with the Swift audio settings off. They depend on the results of libm and
// Accelerate, so they are checked only on ARM64 Cocoa platforms, which they were recorded on.
static constexpr uint64_t expectedBiquadLowpass = 0xecceada2290dd086ULL;
static constexpr uint64_t expectedBiquadHighpass = 0x9c5b336e3311b9b8ULL;
static constexpr uint64_t expectedBiquadSampleAccurate = 0xea70fc76325b62b6ULL;
static constexpr uint64_t expectedIIRFilter4 = 0xe5d00e44c8e973eaULL;

// Timed passes after the checksummed one, fixed so that every build does the same work.
static constexpr unsigned iterationsBiquadLowpass = 12000;
static constexpr unsigned iterationsBiquadHighpass = 12000;
static constexpr unsigned iterationsBiquadSampleAccurate = 2700;
static constexpr unsigned iterationsIIRFilter4 = 5000;

// Lowpass at 440 Hz, Q 1, parameters not automated (k-rate).
TEST(AudioDSPBench, BiquadLowpass)
{
    Context fixture;
    auto processorStorage = makeUnique<BiquadProcessor>(fixture.context, sampleRate, 1, true);
    BiquadProcessor& processor = *processorStorage;
    processor.setType(BiquadFilterType::Lowpass);
    processor.parameter1().setValue(440);
    processor.parameter2().setValue(1);
    benchProcessor("BiquadLowpass", processor, { .channels = 1, .inputSalt = 1 }, iterationsBiquadLowpass, expectedBiquadLowpass);
    EXPECT_FALSE(processor.hasSampleAccurateValues());
}

TEST(AudioDSPBench, BiquadHighpass)
{
    Context fixture;
    auto processorStorage = makeUnique<BiquadProcessor>(fixture.context, sampleRate, 1, true);
    BiquadProcessor& processor = *processorStorage;
    processor.setType(BiquadFilterType::Highpass);
    processor.parameter1().setValue(440);
    processor.parameter2().setValue(1);
    benchProcessor("BiquadHighpass", processor, { .channels = 1, .inputSalt = 1 }, iterationsBiquadHighpass, expectedBiquadHighpass);
    EXPECT_FALSE(processor.hasSampleAccurateValues());
}

// Per-frame coefficients: the lowpass cutoff ramps from 440 Hz to 876 Hz.
TEST(AudioDSPBench, BiquadSampleAccurate)
{
    Context fixture;
    auto processorStorage = makeUnique<BiquadProcessor>(fixture.context, sampleRate, 1, true);
    BiquadProcessor& processor = *processorStorage;
    processor.setType(BiquadFilterType::Lowpass);
    setParameterRamp(processor.parameter1(), 440, 876);
    benchProcessor("BiquadSampleAccurate", processor, { .channels = 1, .inputSalt = 1 }, iterationsBiquadSampleAccurate, expectedBiquadSampleAccurate);
    EXPECT_TRUE(processor.hasSampleAccurateValues());
}

// A fourth-order Butterworth lowpass.
TEST(AudioDSPBench, IIRFilter4)
{
    Vector<double> feedforward { 0.00482434, 0.01929736, 0.02894604, 0.01929736, 0.00482434 };
    Vector<double> feedback { 1.0, -2.36951301, 2.31398841, -1.05472877, 0.18737949 };
    auto processorStorage = makeUnique<IIRProcessor>(sampleRate, 1, feedforward, feedback, true);
    IIRProcessor& processor = *processorStorage;
    processor.initialize();
    benchProcessor("IIRFilter4", processor, { .channels = 1, .inputSalt = 1 }, iterationsIIRFilter4, expectedIIRFilter4);
}


// DynamicsCompress
// 341 quanta of stereo white noise through DynamicsCompressor at -24 dB, ratio 4.
TEST(AudioDSPBench, DynamicsCompress)
{
    initCRC32();
    constexpr unsigned kQuanta = 341;
    [[maybe_unused]] constexpr uint32_t kExpectedCRC = 0x92C7814Cu; // The first pass on a fresh compressor.

    auto noiseL = makeNoise(kQuanta * quantumSize, 42);
    auto noiseR = makeNoise(kQuanta * quantumSize, 99);

    // No exported WebCore entry builds a DynamicsCompressor, and its layout depends on a WebCore build setting that
    // this binary does not see. WebCore's constructor therefore runs in storage sized for the largest layout, and the
    // object is never destroyed. The test touches no member directly.
    alignas(DynamicsCompressor) static char dcStorage[sizeof(DynamicsCompressor)];
    static DynamicsCompressor* dcInstance = ::new (dcStorage) DynamicsCompressor(sampleRate, 2);

    auto runOnce = [&](BenchCRC& crc) {
        DynamicsCompressor& dc = *dcInstance;
        dc.reset();
        dc.setParameterValue(DynamicsCompressor::ParamThreshold, -24.0f);
        dc.setParameterValue(DynamicsCompressor::ParamRatio,     4.0f);
        dc.setParameterValue(DynamicsCompressor::ParamAttack,    0.003f);
        dc.setParameterValue(DynamicsCompressor::ParamRelease,   0.25f);

        for (unsigned q = 0; q < kQuanta; ++q) {
            auto src = AudioBus::create(2, quantumSize);
            auto dst = AudioBus::create(2, quantumSize);
            memcpySpan(src->channel(0)->mutableSpan(), std::span<const float>(noiseL).subspan(q * quantumSize, quantumSize));
            memcpySpan(src->channel(1)->mutableSpan(), std::span<const float>(noiseR).subspan(q * quantumSize, quantumSize));
            dc.process(src.get(), dst.get(), quantumSize);
            crc.feedFloats(std::span<const float>(dst->channel(0)->data(), quantumSize));
            crc.feedFloats(std::span<const float>(dst->channel(1)->data(), quantumSize));
        }
    };

    if (runFullBenchmark()) {
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
        double mb = static_cast<double>(kQuanta * quantumSize * 2) * sizeof(float) * iters / (1024.0 * 1024.0);
        SAFE_PRINTF("DynamicsCompress: %.1f ms %.0f MB/s checksum=0x%08X\n",
                    elapsed * 1000.0 / iters, mb / elapsed, crc.result());
    } else {
        BenchCRC crc;
        runOnce(crc);
#if CPU(ARM64) && PLATFORM(COCOA)
        EXPECT_EQ(kExpectedCRC, crc.result());
#endif
    }
}

// SincResample441to480
// 44100-sample 440 Hz sine resampled from 44100 Hz to 48000 Hz.
TEST(AudioDSPBench, SincResample441to480)
{
    initCRC32();
    constexpr unsigned kInputFrames = 44100;
    constexpr double   kScaleFactor = 44100.0 / 48000.0;
    [[maybe_unused]] constexpr uint32_t kExpectedCRC = 0xC8A3A1BAu;

    auto sine = makeSine(kInputFrames);
    unsigned outFrames = static_cast<unsigned>(std::round(kInputFrames / kScaleFactor));
    std::vector<float> out(outFrames);

    auto runOnce = [&](BenchCRC& crc) {
        std::fill(out.begin(), out.end(), 0.0f);
        SincResampler::processBuffer(sine, out, kScaleFactor);
        crc.feedFloats(out);
    };

    if (runFullBenchmark()) {
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
        SAFE_PRINTF("SincResample441to480: %.1f ms %.0f MB/s checksum=0x%08X\n",
                    elapsed * 1000.0 / iters, mb / elapsed, crc.result());
    } else {
        BenchCRC crc;
        runOnce(crc);
#if CPU(ARM64) && PLATFORM(COCOA)
        EXPECT_EQ(kExpectedCRC, crc.result());
#endif
    }
}

// SincResample441to220
// 44100-sample 440 Hz sine resampled from 44100 Hz to 22050 Hz (scale 2.0).
TEST(AudioDSPBench, SincResample441to220)
{
    initCRC32();
    constexpr unsigned kInputFrames = 44100;
    constexpr double   kScaleFactor = 2.0;
    [[maybe_unused]] constexpr uint32_t kExpectedCRC = 0x0C7D1906u;

    auto sine = makeSine(kInputFrames);
    unsigned outFrames = static_cast<unsigned>(std::round(kInputFrames / kScaleFactor));
    std::vector<float> out(outFrames);

    auto runOnce = [&](BenchCRC& crc) {
        std::fill(out.begin(), out.end(), 0.0f);
        SincResampler::processBuffer(sine, out, kScaleFactor);
        crc.feedFloats(out);
    };

    if (runFullBenchmark()) {
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
        SAFE_PRINTF("SincResample441to220: %.1f ms %.0f MB/s checksum=0x%08X\n",
                    elapsed * 1000.0 / iters, mb / elapsed, crc.result());
    } else {
        BenchCRC crc;
        runOnce(crc);
#if CPU(ARM64) && PLATFORM(COCOA)
        EXPECT_EQ(kExpectedCRC, crc.result());
#endif
    }
}

// StereoPan
// 341 quanta of mono white noise through StereoPanner at pan=0.5.
TEST(AudioDSPBench, StereoPan)
{
    initCRC32();
    constexpr unsigned kQuanta  = 341;
    constexpr unsigned kFrames  = kQuanta * quantumSize;
    constexpr float    kPanVal  = 0.5f;
    [[maybe_unused]] constexpr uint32_t kExpectedCRC = 0xF39FEB7Cu;

    auto noise = makeNoise(kFrames, 42);

    auto runOnce = [&](BenchCRC& crc) {
        for (unsigned q = 0; q < kQuanta; ++q) {
            auto src = AudioBus::create(1, quantumSize);
            auto dst = AudioBus::create(2, quantumSize);
            memcpySpan(src->channel(0)->mutableSpan(), std::span<const float>(noise).subspan(q * quantumSize, quantumSize));
            StereoPanner::panToTargetValue(src.get(), dst.get(), kPanVal, quantumSize);
            crc.feedFloats(std::span<const float>(dst->channel(0)->data(), quantumSize));
            crc.feedFloats(std::span<const float>(dst->channel(1)->data(), quantumSize));
        }
    };

    if (runFullBenchmark()) {
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
        SAFE_PRINTF("StereoPan: %.1f ms %.0f MB/s checksum=0x%08X\n",
                    elapsed * 1000.0 / iters, mb / elapsed, crc.result());
    } else {
        BenchCRC crc;
        runOnce(crc);
#if CPU(ARM64) && PLATFORM(COCOA)
        EXPECT_EQ(kExpectedCRC, crc.result());
#endif
    }
}

// VectorMathMixed
// 1000 calls each to multiply, add, multiplyByScalarThenAddToOutput, and dotProduct
// on 128-element float arrays.
TEST(AudioDSPBench, VectorMathMixed)
{
    initCRC32();
    constexpr unsigned kN      = quantumSize; // 128
    constexpr unsigned kCalls  = 1000;
    [[maybe_unused]] constexpr uint32_t kExpectedCRC = 0x1503EA36u;

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
            memcpySpan(std::span<uint8_t> { dpBytes }, asByteSpan(dp));
            crc.feed(dpBytes, 4);
        }
    };

    if (runFullBenchmark()) {
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
        SAFE_PRINTF("VectorMathMixed: %.1f ms %.0f MB/s checksum=0x%08X\n",
                    elapsed * 1000.0 / iters, mb / elapsed, crc.result());
    } else {
        BenchCRC crc;
        runOnce(crc);
#if CPU(ARM64) && PLATFORM(COCOA)
        EXPECT_EQ(kExpectedCRC, crc.result());
#endif
    }
}

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUDIO)
