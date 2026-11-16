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

#ifndef DynamicsCompressorKernel_h
#define DynamicsCompressorKernel_h

#include "AudioArray.h"
#include "AudioDSPBoundaryTypes.h"
#include <WebCore/PlatformExportMacros.h>
#include <memory>
#include <wtf/TZoneMalloc.h>
#include <wtf/Vector.h>

namespace WebCore {

class CompressorKernel;

class DynamicsCompressorKernel final {
    WTF_MAKE_TZONE_ALLOCATED(DynamicsCompressorKernel);
public:
    explicit DynamicsCompressorKernel(float sampleRate, unsigned numberOfChannels);
    WEBCORE_EXPORT ~DynamicsCompressorKernel();

    void setNumberOfChannels(unsigned);

    // Performs stereo-linked compression.
    void process(std::span<const std::span<const float>> sourceChannels,
                 std::span<std::span<float>> destinationChannels,
                 unsigned framesToProcess,
                 float dbThreshold,
                 float dbKnee,
                 float ratio,
                 float attackTime,
                 float releaseTime,
                 float preDelayTime,
                 float dbPostGain,
                 float effectBlend,

                 float releaseZone1,
                 float releaseZone2,
                 float releaseZone3,
                 float releaseZone4
                 );

    void reset();

    unsigned latencyFrames() const;

    float sampleRate() const { return m_sampleRate; }

    float meteringGain() const { return m_meteringGain; }

    NODELETE double tailTime() const;

protected:
    static constexpr float uninitializedValue = -1;
    float m_sampleRate;

    std::unique_ptr<AudioDSPSwiftState<CompressorKernel>> m_swift;
    float m_meteringGain { 1 };
};

} // namespace WebCore

#endif // DynamicsCompressorKernel_h
