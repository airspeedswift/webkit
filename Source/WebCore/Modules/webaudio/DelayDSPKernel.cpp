/*
 * Copyright (C) 2010-2016 Google Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1.  Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"

#if ENABLE(WEB_AUDIO)

#include "DelayDSPKernel.h"

#include "AudioUtilities.h"
#include <bit>
#include <wtf/TZoneMallocInlines.h>

#include "WebCore-Swift.h"

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(DelayDSPKernel);

// The frames of a delay of up to maxDelayTime seconds, for a kernel with a buffer; 0 for one without.
static size_t delayDSPKernelMaxDelayFrames(bool hasBuffer, double maxDelayTime, double sampleRate)
{
    return hasBuffer ? AudioUtilities::timeToSampleFrame(maxDelayTime, sampleRate, AudioUtilities::SampleFrameRounding::Up) : 0;
}

static std::unique_ptr<AudioDSPSwiftState<DelayKernel>> makeDelayKernelForProcessor(DelayProcessor* processor)
{
    double maxDelayTime = processor ? processor->maxDelayTime() : 0;
    float sampleRate = processor ? processor->sampleRate() : 0;
    bool hasBuffer = processor && sampleRate > 0 && maxDelayTime >= 0;
    return makeUnique<AudioDSPSwiftState<DelayKernel>>(makeDelayKernel(maxDelayTime, sampleRate, delayDSPKernelMaxDelayFrames(hasBuffer, maxDelayTime, sampleRate)));
}

DelayDSPKernel::DelayDSPKernel(DelayProcessor* processor)
    : AudioDSPKernel(processor)
    , m_swift(makeDelayKernelForProcessor(processor))
{
    ASSERT(processor && processor->sampleRate() > 0);
}

DelayDSPKernel::DelayDSPKernel(double maxDelayTime, float sampleRate)
    : AudioDSPKernel(sampleRate)
    , m_swift(makeUnique<AudioDSPSwiftState<DelayKernel>>(makeDelayKernelWithMaxDelayTime(maxDelayTime, sampleRate, delayDSPKernelMaxDelayFrames(!(maxDelayTime <= 0), maxDelayTime, sampleRate))))
{
    ASSERT(maxDelayTime > 0.0);
}

DelayDSPKernel::~DelayDSPKernel() = default;

void DelayDSPKernel::process(std::span<const float> source, std::span<float> destination)
{
    ASSERT(delayHasBuffer(m_swift->kernel));
    ASSERT(source.data() && destination.data());
    if (!delayHasBuffer(m_swift->kernel) || !source.data() || !destination.data()) [[unlikely]]
        return;

    RefPtr delayTime = delayProcessor() ? &delayProcessor()->delayTime() : nullptr;
    bool sampleAccurate = delayTime && delayTime->hasSampleAccurateValues();
    bool shouldUseARate = delayTime && delayTime->automationRate() == AutomationRate::ARate;
    if (sampleAccurate && shouldUseARate) {
        std::array<float, AudioUtilities::renderQuantumSize> delayTimes;
        auto delayTimesSpan = std::span { delayTimes }.first(source.size());
        delayTime->calculateSampleAccurateValues(delayTimesSpan);
        delayProcessARate(m_swift->kernel, inputUnlessOutput(source, destination), destination, source.size(), delayTimesSpan);
        return;
    }
    double delay = delayTime ? delayTime->finalValue() : m_desiredDelayFrames / sampleRate();
    // The interpolation result depends on the destination's offset from a 16-byte boundary; only the address value is read.
    auto destinationAlignment = (std::bit_cast<uintptr_t>(destination.data()) / sizeof(float)) % 4;
    delayProcessKRate(m_swift->kernel, inputUnlessOutput(source, destination), destination, source.size(), delay, destinationAlignment);
}

void DelayDSPKernel::processOnlyAudioParams(size_t framesToProcess)
{
    if (!delayProcessor())
        return;

    std::array<float, AudioUtilities::renderQuantumSize> values;
    ASSERT(framesToProcess <= AudioUtilities::renderQuantumSize);

    protect(delayProcessor()->delayTime())->calculateSampleAccurateValues(std::span { values }.first(framesToProcess));
}

void DelayDSPKernel::reset()
{
    delayReset(m_swift->kernel);
}

double DelayDSPKernel::tailTime() const
{
    return delayTailTime(m_swift->kernel);
}

double DelayDSPKernel::latencyTime() const
{
    return 0;
}

bool DelayDSPKernel::requiresTailProcessing() const
{
    // Always return true even if the tail time and latency might both
    // be zero. This is for simplicity; most interesting delay nodes
    // have non-zero delay times anyway. And it's ok to return true. It
    // just means the node lives a little longer than strictly
    // necessary.
    return true;
}

} // namespace WebCore

#endif // ENABLE(WEB_AUDIO)
