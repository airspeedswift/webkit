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

#include "AudioResampler.h"

#include "AudioBus.h"
#include "AudioUtilities.h"
#include <wtf/TZoneMallocInlines.h>
#include "WebCore-Swift.h"

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(AudioResampler);

static_assert(AudioResampler::MaxRate == 8, "AudioResampler.swift's audioResamplerMaxRate");

// Each channel's source buffer holds up to two extra frames for the linear interpolation.
static constexpr size_t sourceBufferSize = 2 + static_cast<int>(AudioUtilities::renderQuantumSize * AudioResampler::MaxRate);

AudioResampler::AudioResampler()
    : AudioResampler(1)
{
}

AudioResampler::AudioResampler(unsigned numberOfChannels)
    : m_swift(makeUnique<AudioDSPSwiftState<AudioResamplerState>>(makeAudioResamplerState(numberOfChannels)))
    , m_sourceBuffers(numberOfChannels, [](size_t) {
        return makeUnique<AudioFloatArray>(sourceBufferSize);
    })
    , m_sourceBus(AudioBus::create(numberOfChannels, 0, false))
{
}

std::unique_ptr<AudioResampler> AudioResampler::create(unsigned numberOfChannels)
{
    return makeUnique<AudioResampler>(numberOfChannels);
}

AudioResampler::~AudioResampler() = default;

void AudioResampler::configureChannels(unsigned numberOfChannels)
{
    unsigned currentSize = m_sourceBuffers.size();
    if (numberOfChannels == currentSize)
        return; // already setup

    // First deal with adding or removing kernels.
    if (numberOfChannels > currentSize) {
        for (unsigned i = currentSize; i < numberOfChannels; ++i)
            m_sourceBuffers.append(makeUnique<AudioFloatArray>(sourceBufferSize));
    } else
        m_sourceBuffers.shrink(numberOfChannels);
    audioResamplerConfigureChannels(m_swift->kernel, numberOfChannels);

    // Reconfigure our source bus to the new channel size.
    m_sourceBus = AudioBus::create(numberOfChannels, 0, false);
}

void AudioResampler::process(AudioSourceProvider* provider, AudioBus& destinationBus, size_t framesToProcess)
{
    ASSERT(provider);
    if (!provider)
        return;
        
    unsigned numberOfChannels = m_sourceBuffers.size();

    // Make sure our configuration matches the bus we're rendering to.
    bool channelsMatch = (destinationBus.numberOfChannels() == numberOfChannels);
    ASSERT(channelsMatch);
    if (!channelsMatch)
        return;

    Ref sourceBus = m_sourceBus;

    // Setup the source bus.
    for (unsigned i = 0; i < numberOfChannels; ++i) {
        // Figure out how many frames we need to get from the provider, and a pointer to the buffer.
        auto range = audioResamplerSourceRange(m_swift->kernel, i, framesToProcess, m_sourceBuffers[i]->size());
        ASSERT(range.count >= 0);
        if (range.count < 0)
            return;

        sourceBus->setChannelMemory(i, m_sourceBuffers[i]->span().subspan(range.offset, range.count));
    }

    // Ask the provider to supply the desired number of source frames.
    provider->provideInput(sourceBus, sourceBus->length());

    // Now that we have the source data, resample each channel into the destination bus.
    // FIXME: optimize for the common stereo case where it's faster to process both left/right channels in the same inner loop.
    for (unsigned i = 0; i < numberOfChannels; ++i) {
        auto destination = destinationBus.channel(i)->mutableSpan();
        audioResamplerProcess(m_swift->kernel, i, m_sourceBuffers[i]->span(), destination, framesToProcess);
    }
}

void AudioResampler::setRate(double rate)
{
    audioResamplerSetRate(m_swift->kernel, rate);
}

void AudioResampler::reset()
{
    audioResamplerReset(m_swift->kernel);
}

} // namespace WebCore

#endif // ENABLE(WEB_AUDIO)
