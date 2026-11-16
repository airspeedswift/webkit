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

#ifndef SincResampler_h
#define SincResampler_h

#include "AudioArray.h"
#include "AudioDSPBoundaryTypes.h"
#include "AudioSourceProvider.h"
#include <memory>
#include <span>
#include <wtf/Function.h>
#include <wtf/RefPtr.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class SincResamplerKernel;

// SincResampler is a high-quality sample-rate converter.

class SincResampler final {
    WTF_MAKE_TZONE_ALLOCATED(SincResampler);
public:
    // scaleFactor == sourceSampleRate / destinationSampleRate
    // requestFrames controls the size in frames of the buffer requested by each provideInput() call.
    SincResampler(double scaleFactor, unsigned requestFrames, Function<void(std::span<float> buffer, size_t framesToProcess)>&& provideInput);
    ~SincResampler();

    size_t chunkSize() const;

    // Processes samples in `source` to produce source.size() / scaleFactor frames in `destination`.
    WEBCORE_EXPORT static void processBuffer(std::span<const float> source, std::span<float> destination, double scaleFactor);

    // Process with provideInput callback function for streaming applications.
    void process(std::span<float> destination, size_t framesToProcess);

private:
    // This is the number of destination frames we generate per processing pass on the buffer.
    unsigned m_requestFrames;

    Function<void(std::span<float> buffer, size_t framesToProcess)> m_provideInput;

    // Source is copied into this buffer for each processing pass.
    AudioFloatArray m_inputBuffer;

    std::unique_ptr<AudioDSPSwiftState<SincResamplerKernel>> m_swift;
};

} // namespace WebCore

#endif // SincResampler_h
