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
 * CONTRACT, SUBSTITUTE LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

// C++ span aliases and value types for the WebCore audio DSP Swift boundary.
// Swift imports this module as WebCore_Private.AudioDSPBoundaryTypes.
// Each alias names a std::span instantiation Swift cannot spell directly.

#include <cstddef>
#include <span>
#include <utility>
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMallocInlines.h>

using AudioDSPSpanFloat       = std::span<float>;
using AudioDSPSpanConstFloat  = std::span<const float>;
using AudioDSPSpanDouble      = std::span<double>;
using AudioDSPSpanConstDouble = std::span<const double>;
using AudioDSPSpanInt         = std::span<int>;
using AudioDSPSpanConstInt    = std::span<const int>;

namespace WebCore {

// An input that starts where the output does, passed as an empty span so that Swift reads it through the output.
template<typename T> std::span<const T> inputUnlessOutput(std::span<const T> input, std::span<T> output)
{
    return input.data() == output.data() ? std::span<const T> { } : input;
}

// Script can pass one array, or views of one buffer, for any two arguments. Computes one frame at a time, writing
// magnitude then phase before the next frequency is read, as a single loop over the shared memory does.
template<typename Compute> void computeFrequencyResponseOnDisjointArrays(std::span<const float> frequencyHz, std::span<float> magResponse, std::span<float> phaseResponse, const Compute& compute)
{
    if (!spansOverlap(frequencyHz, magResponse) && !spansOverlap(frequencyHz, phaseResponse) && !spansOverlap(magResponse, phaseResponse)) {
        compute(frequencyHz, magResponse, phaseResponse);
        return;
    }
    for (size_t k = 0; k < frequencyHz.size(); ++k) {
        float frequency = frequencyHz[k];
        float magnitude = 0;
        float phase = 0;
        compute(singleElementSpan(std::as_const(frequency)), singleElementSpan(magnitude), singleElementSpan(phase));
        magResponse[k] = magnitude;
        phaseResponse[k] = phase;
    }
}

} // namespace WebCore

// The frames of an AudioResampler channel's source buffer to fill before the next process: their offset in the
// buffer, and their count, which is -1 when they do not fit. A Swift struct returned to C++ is boxed under library
// evolution, so this is defined here.
struct AudioResamplerSourceRange {
    ptrdiff_t offset;
    ptrdiff_t count;
};

// The Swift kernel a C++ class owns. The kernel's type is declared in WebCore-Swift.h, which only a .cpp includes, so the
// class's header forward-declares it and holds this behind a std::unique_ptr.
template<typename Kernel> struct AudioDSPSwiftState {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(AudioDSPSwiftState);
public:
    Kernel kernel;
};
