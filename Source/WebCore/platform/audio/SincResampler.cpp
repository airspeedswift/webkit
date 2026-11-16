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

#include "SincResampler.h"

#include "AudioUtilities.h"
#include "WebCore-Swift.h"
#include <wtf/TZoneMallocInlines.h>

// The resampling is in Swift (AudioDSP.swift, SincResamplerKernel), which owns the kernels and the position in the
// source. The input buffer is m_inputBuffer: when the Swift needs more input it returns, and process() reads the next
// request into the buffer at the offset the Swift names (see the buffer layout there), then calls it again.

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(SincResampler);

constexpr unsigned kernelSize { 32 };
// The Swift lays out m_inputBuffer with its own kernel size.
static_assert(kernelSize == 32, "sincKernelSize in AudioDSP.swift");

// The Swift audio DSP's render quantum: processBuffer's request size, the biquad's per-frame coefficient arrays, the
// delay's guard region, the IIR filter's tail time blocks and the wave shaper's oversampling buffers.
static_assert(AudioUtilities::renderQuantumSize == 128);

SincResampler::SincResampler(double scaleFactor, unsigned requestFrames, Function<void(std::span<float> buffer, size_t framesToProcess)>&& provideInput)
    : m_requestFrames(requestFrames)
    , m_provideInput(WTF::move(provideInput))
    , m_inputBuffer(m_requestFrames + kernelSize)
    , m_swift(makeUnique<AudioDSPSwiftState<SincResamplerKernel>>(makeSincResamplerKernel(scaleFactor, requestFrames)))
{
    ASSERT(m_provideInput);
    ASSERT(m_requestFrames > 0);
}

SincResampler::~SincResampler() = default;

size_t SincResampler::chunkSize() const
{
    return sincResamplerChunkSize(m_swift->kernel);
}

void SincResampler::processBuffer(std::span<const float> source, std::span<float> destination, double scaleFactor)
{
    sincResamplerProcessBuffer(source, destination, scaleFactor);
}

void SincResampler::process(std::span<float> destination, size_t framesToProcess)
{
    auto frames = destination.first(framesToProcess);
    while (sincResamplerProcess(m_swift->kernel, m_inputBuffer.span(), frames))
        m_provideInput(m_inputBuffer.span().subspan(sincResamplerInputOffset(m_swift->kernel)), m_requestFrames);
}

} // namespace WebCore

#endif // ENABLE(WEB_AUDIO)
