/*
 * Copyright (C) 2011 Google Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1.  Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 * 3.  Neither the name of Apple Inc. ("Apple") nor the names of
 *     its contributors may be used to endorse or promote products derived
 *     from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE AND ITS CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
 * THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"

#if ENABLE(WEB_AUDIO)

#include "DynamicsCompressorKernel.h"

#include "WebCore-Swift.h"
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(DynamicsCompressorKernel);

// Metering hits peaks instantly, but releases this fast (in seconds).
constexpr float meteringReleaseTimeConstant = 0.325f;

// CompressorKernel.swift repeats this value.
static_assert(meteringReleaseTimeConstant == 0.325f);

DynamicsCompressorKernel::DynamicsCompressorKernel(float sampleRate, unsigned numberOfChannels)
    : m_sampleRate(sampleRate)
    , m_swift(makeUnique<AudioDSPSwiftState<CompressorKernel>>(makeCompressorKernel(sampleRate, numberOfChannels)))
{
}

DynamicsCompressorKernel::~DynamicsCompressorKernel() = default;

void DynamicsCompressorKernel::setNumberOfChannels(unsigned numberOfChannels)
{
    compressorSetNumberOfChannels(m_swift->kernel, numberOfChannels);
}

void DynamicsCompressorKernel::process(std::span<const std::span<const float>> sourceChannels,
                                       std::span<std::span<float>> destinationChannels,
                                       unsigned framesToProcess,
                                       float dbThreshold,
                                       float dbKnee,
                                       float ratio,
                                       float attackTime,
                                       float releaseTime,
                                       float preDelayTime,
                                       float dbPostGain,
                                       float effectBlend, /* equal power crossfade */

                                       float releaseZone1,
                                       float releaseZone2,
                                       float releaseZone3,
                                       float releaseZone4
                                       )
{
    m_meteringGain = compressorProcess(m_swift->kernel, sourceChannels[0], sourceChannels[1], destinationChannels[0], destinationChannels[1], framesToProcess,
        dbThreshold, dbKnee, ratio, attackTime, releaseTime, preDelayTime, dbPostGain, effectBlend, releaseZone1, releaseZone2, releaseZone3, releaseZone4);
}

void DynamicsCompressorKernel::reset()
{
    compressorReset(m_swift->kernel);
    m_meteringGain = 1;
}

unsigned DynamicsCompressorKernel::latencyFrames() const
{
    return compressorLatencyFrames(m_swift->kernel);
}

double DynamicsCompressorKernel::tailTime() const
{
    // The reduction value of the compressor is computed from the gain using an exponential filter
    // with a time constant of |meteringReleaseTimeConstant|. We need to keep he compressor running
    // for some time after the inputs go away so that the reduction value approaches 0. This is a
    // tradeoff between how long we keep the node alive and how close we approach the final value.
    // A value of 5 to 10 times the time constant is a reasonable trade-off.
    return 5 * meteringReleaseTimeConstant;
}

} // namespace WebCore

#endif // ENABLE(WEB_AUDIO)
