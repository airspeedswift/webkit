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

#include "config.h"

#if ENABLE(WEB_AUDIO)

#include "AudioDSPBenchSupport.h"

namespace TestWebKitAPI {

using namespace WebCore;


// Checksums of the output bits, recorded with USE_SWIFT_AUDIO_DSP off. They depend on the results of libm and
// Accelerate, so they are checked only on ARM64 Cocoa platforms, which they were recorded on.
static constexpr uint64_t expectedBiquadProcessorLowpass = 0x96e34d460d21d145ULL;
static constexpr uint64_t expectedBiquadProcessorInPlace = 0x7e9482fe69969d9bULL;
static constexpr uint64_t expectedBiquadProcessorAllTypes = 0xfd5249bf9eb74044ULL;
static constexpr uint64_t expectedBiquadProcessorSampleAccurate = 0xb5354e435efce6a7ULL;
static constexpr uint64_t expectedBiquadProcessorSampleAccurateConstant = 0x96e34d460d21d145ULL;
static constexpr uint64_t expectedBiquadProcessorResponse = 0x908afc0ce35e1392ULL;
static constexpr uint64_t expectedIIRProcessor4 = 0x1aa378e258510ca7ULL;
static constexpr uint64_t expectedIIRProcessor20 = 0xb2a22ee40cf3b840ULL;
static constexpr uint64_t expectedIIRProcessorResponse = 0x093bfbc370cc2f1cULL;
static constexpr uint64_t expectedIIRProcessorInit = 0x5de94c9a0908d560ULL;
static constexpr uint64_t expectedDelayKRate = 0x2c10fceb5cc7f6d9ULL;
static constexpr uint64_t expectedDelayKRateInteger = 0x229b6ea4614bbe70ULL;
static constexpr uint64_t expectedDelayARate = 0x3e2737efc59108a5ULL;
static constexpr uint64_t expectedDelayWrap = 0xf59f0a50e526e641ULL;
static constexpr uint64_t expectedKernelInit = 0x060c3da705c4d732ULL;

// Timed passes after the checksummed one. Chosen so a shape runs about a second with the setting off; fixed (not
// time-driven) so that every build does the same work.
static constexpr unsigned iterationsBiquadProcessorLowpass = 12800;
static constexpr unsigned iterationsBiquadProcessorInPlace = 6700;
static constexpr unsigned iterationsBiquadProcessorAllTypes = 6300;
static constexpr unsigned iterationsBiquadProcessorSampleAccurate = 2700;
static constexpr unsigned iterationsBiquadProcessorSampleAccurateConstant = 5800;
static constexpr unsigned iterationsBiquadProcessorResponse = 14600;
static constexpr unsigned iterationsIIRProcessor4 = 5200;
static constexpr unsigned iterationsIIRProcessor20 = 500;
static constexpr unsigned iterationsIIRProcessorResponse = 90000;
static constexpr unsigned iterationsIIRProcessorInit = 175;
static constexpr unsigned iterationsDelayKRate = 50000;
static constexpr unsigned iterationsDelayKRateInteger = 54000;
static constexpr unsigned iterationsDelayARate = 7100;
static constexpr unsigned iterationsDelayWrap = 24000;
static constexpr unsigned iterationsKernelInit = 790;

// ---- Biquad ----

// Processor-level: coefficient update (k-rate path, parameters not automated) and the block filter.
TEST(AudioDSPKernelBench, BiquadProcessorLowpass)
{
    Context fixture;
    auto processorStorage = makeUnique<BiquadProcessor>(fixture.context, sampleRate, 1, true);
    BiquadProcessor& processor = *processorStorage;
    processor.setType(BiquadFilterType::Lowpass);
    processor.parameter1().setValue(440);
    benchProcessor("BiquadProcessorLowpass", processor, { .channels = 1 }, iterationsBiquadProcessorLowpass, expectedBiquadProcessorLowpass);
    EXPECT_FALSE(processor.hasSampleAccurateValues());
}

// Source and destination are the same bus, the normal case in a graph.
TEST(AudioDSPKernelBench, BiquadProcessorInPlace)
{
    Context fixture;
    auto processorStorage = makeUnique<BiquadProcessor>(fixture.context, sampleRate, 2, true);
    BiquadProcessor& processor = *processorStorage;
    processor.setType(BiquadFilterType::Lowpass);
    processor.parameter1().setValue(1000);
    processor.parameter2().setValue(5);
    benchProcessor("BiquadProcessorInPlace", processor, { .channels = 2, .inPlace = true }, iterationsBiquadProcessorInPlace, expectedBiquadProcessorInPlace);
}

// Every filter type in turn, stereo, with non-default Q, gain and detune, so every coefficient setter runs.
TEST(AudioDSPKernelBench, BiquadProcessorAllTypes)
{
    Context fixture;
    auto processorStorage = makeUnique<BiquadProcessor>(fixture.context, sampleRate, 2, true);
    BiquadProcessor& processor = *processorStorage;
    processor.parameter1().setValue(2000);
    processor.parameter2().setValue(3);
    processor.parameter3().setValue(6);
    processor.parameter4().setValue(100);
    constexpr BiquadFilterType types[] = { BiquadFilterType::Lowpass, BiquadFilterType::Highpass, BiquadFilterType::Bandpass,
        BiquadFilterType::Lowshelf, BiquadFilterType::Highshelf, BiquadFilterType::Peaking, BiquadFilterType::Notch, BiquadFilterType::Allpass };
    ProcessorRun run { .channels = 2 };
    run.beforeQuantum = [&](unsigned quantum) {
        if (!(quantum % 40))
            processor.setType(types[(quantum / 40) % std::size(types)]);
    };
    benchProcessor("BiquadProcessorAllTypes", processor, WTF::move(run), iterationsBiquadProcessorAllTypes, expectedBiquadProcessorAllTypes);
}

// Per-frame coefficients: the cutoff ramps within every quantum.
TEST(AudioDSPKernelBench, BiquadProcessorSampleAccurate)
{
    Context fixture;
    auto processorStorage = makeUnique<BiquadProcessor>(fixture.context, sampleRate, 1, true);
    BiquadProcessor& processor = *processorStorage;
    processor.setType(BiquadFilterType::Lowpass);
    setParameterRamp(processor.parameter1(), 200, 8000);
    benchProcessor("BiquadProcessorSampleAccurate", processor, { .channels = 1 }, iterationsBiquadProcessorSampleAccurate, expectedBiquadProcessorSampleAccurate);
    EXPECT_TRUE(processor.hasSampleAccurateValues());
    EXPECT_TRUE(processor.shouldUseARate());
}

// Flagged sample-accurate, but every value is the same: the constant-value fold, then the block filter.
TEST(AudioDSPKernelBench, BiquadProcessorSampleAccurateConstant)
{
    Context fixture;
    auto processorStorage = makeUnique<BiquadProcessor>(fixture.context, sampleRate, 1, true);
    BiquadProcessor& processor = *processorStorage;
    processor.setType(BiquadFilterType::Lowpass);
    setParameterRamp(processor.parameter1(), 440, 440);
    benchProcessor("BiquadProcessorSampleAccurateConstant", processor, { .channels = 1 }, iterationsBiquadProcessorSampleAccurateConstant, expectedBiquadProcessorSampleAccurateConstant);
    EXPECT_TRUE(processor.hasSampleAccurateValues());
}

// getFrequencyResponse and tailTime for every type, over 512 frequencies including out-of-range ones.
TEST(AudioDSPKernelBench, BiquadProcessorResponse)
{
    Context fixture;
    auto processorStorage = makeUnique<BiquadProcessor>(fixture.context, sampleRate, 1, true);
    BiquadProcessor& processor = *processorStorage;
    processor.parameter1().setValue(3000);
    processor.parameter2().setValue(4);
    processor.parameter3().setValue(-6);
    constexpr BiquadFilterType types[] = { BiquadFilterType::Lowpass, BiquadFilterType::Highpass, BiquadFilterType::Bandpass,
        BiquadFilterType::Lowshelf, BiquadFilterType::Highshelf, BiquadFilterType::Peaking, BiquadFilterType::Notch, BiquadFilterType::Allpass };
    Vector<float> frequencies(512);
    for (unsigned i = 0; i < frequencies.size(); ++i)
        frequencies[i] = static_cast<float>(i) * (sampleRate * 0.55f / frequencies.size()); // up past Nyquist.
    Vector<float> magnitude(frequencies.size());
    Vector<float> phase(frequencies.size());

    // A quantum of input so that the kernels have computed their coefficients and tail time.
    Ref source = AudioBus::create(1, quantumSize);
    Ref destination = AudioBus::create(1, quantumSize);
    auto input = makeInput(0, quantumSize);
    for (unsigned i = 0; i < quantumSize; ++i)
        source->channel(0)->mutableSpan()[i] = input[i];

    auto pass = [&](Digest* digest) {
        for (auto type : types) {
            processor.setType(type);
            processor.process(source, destination, quantumSize);
            processor.getFrequencyResponse(frequencies.span(), magnitude.mutableSpan(), phase.mutableSpan());
            if (digest) {
                for (unsigned i = 0; i < frequencies.size(); ++i) {
                    digest->add(magnitude[i]);
                    digest->add(phase[i]);
                }
                digest->add(processor.tailTime());
            }
        }
    };

    Digest digest;
    pass(&digest);
    double seconds = 0;
    size_t bytes = 0;
    if (runFullBenchmark()) {
        auto start = std::chrono::steady_clock::now();
        for (unsigned i = 0; i < iterationsBiquadProcessorResponse; ++i)
            pass(nullptr);
        seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        bytes = static_cast<size_t>(iterationsBiquadProcessorResponse) * std::size(types) * frequencies.size() * 2 * sizeof(float);
    }
    reportOrCheck("BiquadProcessorResponse", expectedBiquadProcessorResponse, digest, seconds, bytes);
}

// ---- IIR ----

// Fourth-order Butterworth low-pass, cutoff 0.1 of Nyquist.
static const Vector<double>& iir4Feedforward()
{
    static NeverDestroyed<Vector<double>> coefficients(std::initializer_list<double> { 0.0004165992, 0.0016663969, 0.0024995954, 0.0016663969, 0.0004165992 });
    return coefficients;
}

static const Vector<double>& iir4Feedback()
{
    static NeverDestroyed<Vector<double>> coefficients(std::initializer_list<double> { 1.0, -3.1806385489, 3.8611943490, -2.1122553040, 0.4383265120 });
    return coefficients;
}

// Order 20 (the maximum), feedforward and feedback both full length: a cascade-free but stable choice, a moving
// average on the feedforward side and a mild damped feedback.
static Vector<double> iir20Feedforward()
{
    Vector<double> coefficients(21);
    for (unsigned i = 0; i < coefficients.size(); ++i)
        coefficients[i] = 1.0 / 21;
    return coefficients;
}

static Vector<double> iir20Feedback()
{
    Vector<double> coefficients(21);
    coefficients[0] = 1;
    for (unsigned i = 1; i < coefficients.size(); ++i)
        coefficients[i] = (i % 2 ? -1 : 1) * 0.02 / i;
    return coefficients;
}

TEST(AudioDSPKernelBench, IIRProcessor4)
{
    auto processorStorage = makeUnique<IIRProcessor>(sampleRate, 1, iir4Feedforward(), iir4Feedback(), true);
    IIRProcessor& processor = *processorStorage;
    processor.initialize();
    benchProcessor("IIRProcessor4", processor, { .channels = 1 }, iterationsIIRProcessor4, expectedIIRProcessor4);
}

TEST(AudioDSPKernelBench, IIRProcessor20)
{
    auto processorStorage = makeUnique<IIRProcessor>(sampleRate, 2, iir20Feedforward(), iir20Feedback(), true);
    IIRProcessor& processor = *processorStorage;
    processor.initialize();
    benchProcessor("IIRProcessor20", processor, { .channels = 2 }, iterationsIIRProcessor20, expectedIIRProcessor20);
}

TEST(AudioDSPKernelBench, IIRProcessorResponse)
{
    auto processorStorage = makeUnique<IIRProcessor>(sampleRate, 1, iir4Feedforward(), iir4Feedback(), true);
    IIRProcessor& processor = *processorStorage;
    processor.initialize();
    Vector<float> frequencies(512);
    for (unsigned i = 0; i < frequencies.size(); ++i)
        frequencies[i] = static_cast<float>(i) * (sampleRate * 0.55f / frequencies.size());
    Vector<float> magnitude(frequencies.size());
    Vector<float> phase(frequencies.size());

    Digest digest;
    processor.getFrequencyResponse(frequencies.span(), magnitude.mutableSpan(), phase.mutableSpan());
    for (unsigned i = 0; i < frequencies.size(); ++i) {
        digest.add(magnitude[i]);
        digest.add(phase[i]);
    }
    digest.add(processor.tailTime());

    double seconds = 0;
    size_t bytes = 0;
    if (runFullBenchmark()) {
        auto start = std::chrono::steady_clock::now();
        for (unsigned i = 0; i < iterationsIIRProcessorResponse; ++i)
            processor.getFrequencyResponse(frequencies.span(), magnitude.mutableSpan(), phase.mutableSpan());
        seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        bytes = static_cast<size_t>(iterationsIIRProcessorResponse) * frequencies.size() * 2 * sizeof(float);
    }
    reportOrCheck("IIRProcessorResponse", expectedIIRProcessorResponse, digest, seconds, bytes);
}

// Construction, which computes the tail time of the response kernel (an impulse run of about 3,400 quanta), and
// initialize() / uninitialize(), which build and drop a kernel per channel and do the same per kernel.
TEST(AudioDSPKernelBench, IIRProcessorInit)
{
    auto pass = [&](Digest* digest) {
        auto processorStorage = makeUnique<IIRProcessor>(sampleRate, 2, iir4Feedforward(), iir4Feedback(), true);
        IIRProcessor& processor = *processorStorage;
        processor.initialize();
        if (digest) {
            digest->add(processor.tailTime());
            digest->add(processor.latencyTime());
            digest->add(static_cast<uint64_t>(processor.numberOfChannels()));
        }
        processor.uninitialize();
    };

    Digest digest;
    pass(&digest);
    double seconds = 0;
    size_t bytes = 0;
    if (runFullBenchmark()) {
        auto start = std::chrono::steady_clock::now();
        for (unsigned i = 0; i < iterationsIIRProcessorInit; ++i)
            pass(nullptr);
        seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        // Each pass runs the impulse response for 3,446 quanta in each of 3 kernels (two channels and the response kernel).
        bytes = static_cast<size_t>(iterationsIIRProcessorInit) * 3 * 3446 * quantumSize * sizeof(float);
    }
    reportOrCheck("IIRProcessorInit", expectedIIRProcessorInit, digest, seconds, bytes);
}

// ---- Delay ----

// Constant, fractional delay (k-rate): the interpolating path.
TEST(AudioDSPKernelBench, DelayKRate)
{
    Context fixture;
    auto processorStorage = makeUnique<DelayProcessor>(fixture.context, sampleRate, 1, 1.0);
    DelayProcessor& processor = *processorStorage;
    processor.initialize();
    processor.delayTime().setValue(0.0123f);
    benchProcessor("DelayKRate", processor, { .channels = 1 }, iterationsDelayKRate, expectedDelayKRate);
    EXPECT_FALSE(processor.delayTime().hasSampleAccurateValues());
}

// Constant delay of exactly 22,050 frames: no interpolation.
TEST(AudioDSPKernelBench, DelayKRateInteger)
{
    Context fixture;
    auto processorStorage = makeUnique<DelayProcessor>(fixture.context, sampleRate, 1, 1.0);
    DelayProcessor& processor = *processorStorage;
    processor.initialize();
    processor.delayTime().setValue(0.5f);
    benchProcessor("DelayKRateInteger", processor, { .channels = 1 }, iterationsDelayKRateInteger, expectedDelayKRateInteger);
}

// Per-frame delay times: the delay ramps within every quantum.
TEST(AudioDSPKernelBench, DelayARate)
{
    Context fixture;
    auto processorStorage = makeUnique<DelayProcessor>(fixture.context, sampleRate, 1, 1.0);
    DelayProcessor& processor = *processorStorage;
    processor.initialize();
    setParameterRamp(processor.delayTime(), 0.005f, 0.05f);
    benchProcessor("DelayARate", processor, { .channels = 1 }, iterationsDelayARate, expectedDelayARate);
    EXPECT_TRUE(processor.delayTime().hasSampleAccurateValues());
    EXPECT_EQ(AutomationRate::ARate, processor.delayTime().automationRate());
}

// A buffer of about 90 + 128 frames, so that every quantum wraps the circular buffer, with a fractional delay.
TEST(AudioDSPKernelBench, DelayWrap)
{
    Context fixture;
    auto processorStorage = makeUnique<DelayProcessor>(fixture.context, sampleRate, 2, 0.002);
    DelayProcessor& processor = *processorStorage;
    processor.initialize();
    processor.delayTime().setValue(0.0015f);
    benchProcessor("DelayWrap", processor, { .channels = 2 }, iterationsDelayWrap, expectedDelayWrap);
}

// ---- Kernel creation ----

// initialize() and uninitialize() cycles that create and destroy the kernels, for the Biquad and Delay
// processors, at 1, 2 and 8 channels.
TEST(AudioDSPKernelBench, KernelInit)
{
    Context fixture;
    constexpr unsigned channelCounts[] = { 1, 2, 8 };
    constexpr unsigned cycles = 100;

    auto pass = [&](Digest* digest) {
        for (unsigned channels : channelCounts) {
            auto biquadStorage = makeUnique<BiquadProcessor>(fixture.context, sampleRate, channels, false);
            BiquadProcessor& biquad = *biquadStorage;
            auto delayStorage = makeUnique<DelayProcessor>(fixture.context, sampleRate, channels, 1.0);
            DelayProcessor& delay = *delayStorage;
            for (unsigned i = 0; i < cycles; ++i) {
                biquad.initialize();
                delay.initialize();
                if (digest && !i) {
                    digest->add(biquad.tailTime());
                    digest->add(delay.tailTime());
                    digest->add(biquad.latencyTime());
                    digest->add(static_cast<uint64_t>(biquad.isInitialized()));
                }
                biquad.uninitialize();
                delay.uninitialize();
            }
        }
    };

    Digest digest;
    pass(&digest);
    double seconds = 0;
    size_t bytes = 0;
    if (runFullBenchmark()) {
        auto start = std::chrono::steady_clock::now();
        for (unsigned i = 0; i < iterationsKernelInit; ++i)
            pass(nullptr);
        seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        // Bytes of kernel state built: Biquad ~18 KB and Delay ~(1 s of floats) per kernel.
        bytes = static_cast<size_t>(iterationsKernelInit) * cycles * (1 + 2 + 8) * (18 * 1024 + static_cast<size_t>(sampleRate) * sizeof(float));
    }
    reportOrCheck("KernelInit", expectedKernelInit, digest, seconds, bytes);
}

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUDIO)
