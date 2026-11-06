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

#pragma once

#if ENABLE(WEB_AUDIO)

#include "Helpers/Test.h"
#include <WebCore/AudioBus.h>
#include <WebCore/AudioChannel.h>
#include <WebCore/AudioParam.h>
#include <WebCore/AudioProcessor.h>
#include <WebCore/BiquadFilterType.h>
#include <WebCore/BiquadProcessor.h>
#include <WebCore/CommonAtomStrings.h>
#include <WebCore/DelayProcessor.h>
#include <WebCore/DocumentInlines.h>
#include <WebCore/HTMLBodyElement.h>
#include <WebCore/HTMLHtmlElement.h>
#include <WebCore/IIRProcessor.h>
#include <WebCore/OfflineAudioContext.h>
#include <WebCore/ProcessWarming.h>
#include <WebCore/Settings.h>
#include <algorithm>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <wtf/CurrentThread.h>
#include <wtf/Function.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

// Helpers shared by AudioDSPBench.cpp and AudioDSPKernelBench.cpp: both drive the audio processors through
// AudioProcessor's virtual interface and the processors' own constructors, so they do not depend on the layout of the
// kernels the processors create. Processors are heap-allocated: they use checked pointers, whose Debug assertion
// needs the class operator delete.

namespace TestWebKitAPI {

static constexpr unsigned quantumSize = 128;
static constexpr unsigned quantaPerPass = 341; // about one second at 44.1 kHz.
static constexpr float sampleRate = 44100;
static constexpr double automationEnd = 10; // seconds; the ramps below never finish within a benchmark.

static bool runFullBenchmark()
{
    const char* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && *value != '0';
}

// FNV-1a over the bits of what one pass produced.
class Digest {
public:
    void add(float value) { add(static_cast<uint64_t>(std::bit_cast<uint32_t>(value))); }
    void add(double value) { add(std::bit_cast<uint64_t>(value)); }
    void add(uint64_t value) { m_hash = (m_hash ^ value) * prime; }
    uint64_t checksum() const { return m_hash; }

private:
    static constexpr uint64_t prime = 0x100000001b3ULL;
    uint64_t m_hash { 0xcbf29ce484222325ULL };
};

static Ref<WebCore::Document> createDocument()
{
    WebCore::ProcessWarming::initializeNames();

    auto settings = WebCore::Settings::create(nullptr);
    auto document = WebCore::Document::create(settings.get(), aboutBlankURL());
    auto documentElement = WebCore::HTMLHtmlElement::create(document);
    document->appendChild(documentElement);
    auto body = WebCore::HTMLBodyElement::create(document);
    documentElement->appendChild(body);
    return document;
}

// An offline context on the test thread, which stands in for the audio thread: AudioParam only produces
// sample-accurate values there.
struct Context {
    Context()
        : document(createDocument())
        , context(WebCore::OfflineAudioContext::create(document, 2, quantumSize, sampleRate).releaseReturnValue())
    {
        context->setAudioThread(currentThreadID());
    }

    Ref<WebCore::Document> document;
    Ref<WebCore::OfflineAudioContext> context;
};

// Deterministic input: a sine plus a little noise, different per channel.
static Vector<float> makeInput(unsigned channel, size_t frames, unsigned salt = 0)
{
    Vector<float> input(frames);
    uint32_t state = 12345 + channel * 7919 + salt * 104729;
    for (size_t i = 0; i < frames; ++i) {
        state = state * 1664525 + 1013904223;
        float noise = (static_cast<float>(state >> 8) / 16777216.0f - 0.5f) * 0.2f;
        input[i] = 0.4f * std::sin(static_cast<float>(i) * (0.03f + 0.01f * channel)) + noise;
    }
    return input;
}

static void reportOrCheck(const char* shape, [[maybe_unused]] uint64_t expected, const Digest& digest, double seconds, size_t bytes)
{
    if (!runFullBenchmark()) {
#if CPU(ARM64) && PLATFORM(COCOA)
        EXPECT_EQ(expected, digest.checksum()) << shape;
#endif
        return;
    }
    double ms = seconds * 1000;
    double mbPerSecond = seconds > 0 ? bytes / seconds / 1e6 : 0;
    SAFE_PRINTF("%s: %.2f ms %.1f MB/s checksum=%016llx\n", String::fromLatin1(shape).utf8(), ms, mbPerSecond, static_cast<unsigned long long>(digest.checksum()));
    fflush(stdout);
}

struct ProcessorRun {
    unsigned channels { 1 };
    unsigned quanta { quantaPerPass };
    bool inPlace { false };
    // Selects a different deterministic input, so that shapes of the two benchmarks do not repeat each other.
    unsigned inputSalt { 0 };
    // Called before each quantum of every pass.
    Function<void(unsigned quantum)> beforeQuantum;
    // Called after each pass with its digest, if it is the checksummed pass.
    Function<void(Digest&)> afterPass;
};

// One pass over the input through `processor`. State persists between passes only through what reset() keeps.
static void runPass(WebCore::AudioProcessor& processor, WebCore::AudioBus& source, WebCore::AudioBus& destination, const Vector<Vector<float>>& input, ProcessorRun& run, Digest* digest)
{
    processor.reset();
    for (unsigned q = 0; q < run.quanta; ++q) {
        if (run.beforeQuantum)
            run.beforeQuantum(q);
        for (unsigned c = 0; c < run.channels; ++c) {
            auto channel = source.channel(c)->mutableSpan();
            for (unsigned i = 0; i < quantumSize; ++i)
                channel[i] = input[c][q * quantumSize + i];
        }
        WebCore::AudioBus& out = run.inPlace ? source : destination;
        processor.process(source, out, quantumSize);
        if (digest) {
            for (unsigned c = 0; c < run.channels; ++c) {
                for (float sample : out.channel(c)->span())
                    digest->add(sample);
            }
        }
    }
    if (digest && run.afterPass)
        run.afterPass(*digest);
}

static void benchProcessor(const char* shape, WebCore::AudioProcessor& processor, ProcessorRun run, unsigned iterations, uint64_t expected)
{
    Vector<Vector<float>> input;
    for (unsigned c = 0; c < run.channels; ++c)
        input.append(makeInput(c, static_cast<size_t>(run.quanta) * quantumSize, run.inputSalt));
    Ref source = WebCore::AudioBus::create(run.channels, quantumSize);
    Ref destination = WebCore::AudioBus::create(run.channels, quantumSize);

    Digest digest;
    runPass(processor, source, destination, input, run, &digest);

    double seconds = 0;
    size_t bytes = 0;
    if (runFullBenchmark()) {
        auto start = std::chrono::steady_clock::now();
        for (unsigned i = 0; i < iterations; ++i)
            runPass(processor, source, destination, input, run, nullptr);
        seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        bytes = static_cast<size_t>(iterations) * run.channels * run.quanta * quantumSize * sizeof(float);
    }
    reportOrCheck(shape, expected, digest, seconds, bytes);
}

static void setParameterRamp(WebCore::AudioParam& parameter, float from, float to)
{
    parameter.setValueAtTime(from, 0);
    parameter.linearRampToValueAtTime(to, automationEnd);
}

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUDIO)
