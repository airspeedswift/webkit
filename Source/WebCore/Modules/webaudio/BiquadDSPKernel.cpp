/*
 * Copyright (C) 2010 Google Inc. All rights reserved.
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

#include "BiquadDSPKernel.h"

#include "WebCore-Swift.h"

#include "AudioArray.h"
#include "AudioUtilities.h"
#include "BiquadProcessor.h"
#include "FloatConversion.h"
#include <limits.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/Vector.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(BiquadDSPKernel);

BiquadDSPKernel::BiquadDSPKernel(BiquadProcessor* processor)
    : AudioDSPKernel(processor)
    , m_swift(makeUnique<AudioDSPSwiftState<BiquadKernel>>(makeBiquadKernel(sampleRate())))
{
}

BiquadDSPKernel::~BiquadDSPKernel() = default;

void BiquadDSPKernel::reset()
{
    biquadReset(m_swift->kernel);
}

void BiquadDSPKernel::updateCoefficientsIfNecessary(size_t framesToProcess)
{
    if (biquadProcessor()->filterCoefficientsDirty()) {
        if (biquadProcessor()->hasSampleAccurateValues() && biquadProcessor()->shouldUseARate()) {
            // Use float arrays instead of AudioFloatArray to avoid heap allocations on the audio thread.
            std::array<float, AudioUtilities::renderQuantumSize> cutoffFrequency;
            std::array<float, AudioUtilities::renderQuantumSize> q;
            std::array<float, AudioUtilities::renderQuantumSize> gain;
            std::array<float, AudioUtilities::renderQuantumSize> detune; // in Cents

            RELEASE_ASSERT(framesToProcess <= AudioUtilities::renderQuantumSize);

            auto cutoffFrequencySpan = std::span { cutoffFrequency }.first(framesToProcess);
            auto qSpan = std::span { q }.first(framesToProcess);
            auto gainSpan = std::span { gain }.first(framesToProcess);
            auto detuneSpan = std::span { detune }.first(framesToProcess);

            protect(biquadProcessor()->parameter1())->calculateSampleAccurateValues(cutoffFrequencySpan);
            protect(biquadProcessor()->parameter2())->calculateSampleAccurateValues(qSpan);
            protect(biquadProcessor()->parameter3())->calculateSampleAccurateValues(gainSpan);
            protect(biquadProcessor()->parameter4())->calculateSampleAccurateValues(detuneSpan);

            // If all the values are actually constant for this render (or the
            // automation rate is "k-rate" for all of the AudioParams), we don't need
            // to compute filter coefficients for each frame since they would be the
            // same as the first.
            biquadUpdateCoefficients(m_swift->kernel, framesToProcess, biquadProcessor()->type(), cutoffFrequencySpan, qSpan, gainSpan, detuneSpan, true);
        } else {
            float cutoffFrequency = protect(biquadProcessor()->parameter1())->finalValue();
            float q = protect(biquadProcessor()->parameter2())->finalValue();
            float gain = protect(biquadProcessor()->parameter3())->finalValue();
            float detune = protect(biquadProcessor()->parameter4())->finalValue();
            updateCoefficients(1, singleElementSpan(cutoffFrequency), singleElementSpan(q), singleElementSpan(gain), singleElementSpan(detune));
        }
    }
}

void BiquadDSPKernel::updateCoefficients(size_t numberOfFrames, std::span<const float> cutoffFrequency, std::span<const float> q, std::span<const float> gain, std::span<const float> detune)
{
    biquadUpdateCoefficients(m_swift->kernel, numberOfFrames, biquadProcessor()->type(), cutoffFrequency, q, gain, detune, false);
}

void BiquadDSPKernel::process(std::span<const float> source, std::span<float> destination)
{
    ASSERT(source.data() && destination.data() && biquadProcessor());
    
    // Recompute filter coefficients if any of the parameters have changed.
    // FIXME: as an optimization, implement a way that a Biquad object can simply copy its internal filter coefficients from another Biquad object.
    // Then re-factor this code to only run for the first BiquadDSPKernel of each BiquadProcessor.

    updateCoefficientsIfNecessary(source.size());

    biquadProcess(m_swift->kernel, inputUnlessOutput(source, destination), destination, source.size());
}

void BiquadDSPKernel::getFrequencyResponse(std::span<const float> frequencyHz, std::span<float> magResponse, std::span<float> phaseResponse)
{
    bool isGood = !frequencyHz.empty() && frequencyHz.data() && magResponse.data() && phaseResponse.data();
    ASSERT(isGood);
    if (!isGood)
        return;

    biquadFrequencyResponse(m_swift->kernel, frequencyHz, magResponse, phaseResponse);
}

double BiquadDSPKernel::tailTime() const
{
    return biquadTailTime(m_swift->kernel);
}

double BiquadDSPKernel::latencyTime() const
{
    return 0;
}

bool BiquadDSPKernel::requiresTailProcessing() const
{
    // Always return true even if the tail time and latency might both
    // be zero. This is for simplicity and because TailTime() is 0
    // basically only when the filter response H(z) = 0 or H(z) = 1. And
    // it's ok to return true. It just means the node lives a little
    // longer than strictly necessary.
    return true;
}

} // namespace WebCore

#endif // ENABLE(WEB_AUDIO)
