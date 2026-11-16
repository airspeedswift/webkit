/*
 * Copyright (C) 2011 Google Inc. All rights reserved.
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

#include "WaveShaperDSPKernel.h"

#include "AudioUtilities.h"
#include "WaveShaperProcessor.h"
#include <wtf/MainThread.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/Threading.h>
#include "WebCore-Swift.h"

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(WaveShaperDSPKernel);

// The Swift receives OverSampleType's values.
static_assert(WaveShaperProcessor::OverSampleNone == 0 && WaveShaperProcessor::OverSample2x == 1 && WaveShaperProcessor::OverSample4x == 2);

WaveShaperDSPKernel::WaveShaperDSPKernel(WaveShaperProcessor* processor)
    : AudioDSPKernel(processor)
    , m_swift(makeUnique<AudioDSPSwiftState<WaveShaperKernel>>(makeWaveShaperKernel()))
{
    if (processor->oversample() != WaveShaperProcessor::OverSampleNone)
        lazyInitializeOversampling();
}

WaveShaperDSPKernel::~WaveShaperDSPKernel() = default;

void WaveShaperDSPKernel::lazyInitializeOversampling()
{
    ASSERT(isMainThread());
    waveShaperEnableOversampling(m_swift->kernel);
}

void WaveShaperDSPKernel::process(std::span<const float> source, std::span<float> destination)
{
    assertIsHeld(waveShaperProcessor()->processLock());
    auto curve = waveShaperProcessor()->curve().span();
    auto oversample = static_cast<uint8_t>(waveShaperProcessor()->oversample());
    waveShaperProcess(m_swift->kernel, curve, oversample, inputUnlessOutput(source, destination), destination, source.size());
}

void WaveShaperDSPKernel::processCurveWithData(std::span<const float> source, std::span<float> destination, std::span<const float> curveData)
{
    ASSERT(source.data() && destination.data());
    waveShaperProcessCurve(source, destination, curveData);
}

void WaveShaperDSPKernel::reset()
{
    waveShaperReset(m_swift->kernel);
}

double WaveShaperDSPKernel::latencyTime() const
{
    if (!waveShaperProcessor()->processLock().tryLock())
        return std::numeric_limits<double>::infinity();

    Locker locker { AdoptLock, waveShaperProcessor()->processLock() };

    auto latencyFrames = waveShaperLatencyFrames(static_cast<uint8_t>(waveShaperProcessor()->oversample()));
    return static_cast<double>(latencyFrames) / sampleRate();
}

bool WaveShaperDSPKernel::requiresTailProcessing() const
{
    // Always return true even if the tail time and latency might both be zero.
    return true;
}

} // namespace WebCore

#endif // ENABLE(WEB_AUDIO)
