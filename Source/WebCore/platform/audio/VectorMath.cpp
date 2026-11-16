/*
 * Copyright (C) 2010 Google Inc. All rights reserved.
 * Copyright (C) 2020 Apple Inc. All rights reserved.
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


#include "AudioUtilities.h"
#include "VectorMath.h"

#include "WebCore-Swift.h"

#include <bit>
#include <wtf/StdLibExtras.h>

namespace WebCore {

namespace VectorMath {

// Each port's arithmetic is in the Swift (AudioDSP.swift, VectorMathPlatform), which chooses the platform's.

// The span's offset from a 16-byte boundary, in floats: where the SSE2 order of a reduction starts its groups of four.
static intptr_t alignmentInFloats(std::span<const float> span)
{
    return (std::bit_cast<uintptr_t>(span.data()) / sizeof(float)) % 4;
}

static bool is16ByteAligned(std::span<const float> span)
{
    return !alignmentInFloats(span);
}

void multiplyByScalar(std::span<const float> inputVector, float scalar, std::span<float> outputVector)
{
    vmMultiplyByScalar(inputUnlessOutput(inputVector, outputVector), inputVector.size(), scalar, outputVector);
}

void substract(std::span<const float> inputVector1, std::span<const float> inputVector2, std::span<float> outputVector)
{
    vmSubstract(inputUnlessOutput(inputVector1, outputVector), inputUnlessOutput(inputVector2, outputVector), outputVector, inputVector1.size(), inputVector2.size());
}

void addScalar(std::span<const float> inputVector, float scalar, std::span<float> outputVector)
{
    vmAddScalar(inputUnlessOutput(inputVector, outputVector), inputVector.size(), scalar, outputVector);
}

void multiply(std::span<const float> inputVector1, std::span<const float> inputVector2, std::span<float> outputVector)
{
    vmMultiply(inputUnlessOutput(inputVector1, outputVector), inputUnlessOutput(inputVector2, outputVector), outputVector, inputVector1.size(), inputVector2.size());
}

void multiplyComplex(std::span<const float> realVector1, std::span<const float> imagVector1, std::span<const float> realVector2, std::span<const float> imagVector2, std::span<float> realOutputVector, std::span<float> imagOutputVector)
{
    bool simdAligned = is16ByteAligned(realVector1) && is16ByteAligned(imagVector1) && is16ByteAligned(realVector2) && is16ByteAligned(imagVector2) && is16ByteAligned(realOutputVector) && is16ByteAligned(imagOutputVector);
    vmMultiplyComplex(inputUnlessOutput(realVector1, realOutputVector), inputUnlessOutput(imagVector1, imagOutputVector), inputUnlessOutput(realVector2, realOutputVector), inputUnlessOutput(imagVector2, imagOutputVector), realOutputVector, imagOutputVector, realVector1.size(), imagVector1.size(), realVector2.size(), imagVector2.size(), simdAligned);
}

void multiplyByScalarThenAddToOutput(std::span<const float> inputVector, float scalar, std::span<float> outputVector)
{
    vmMultiplyByScalarThenAddToOutput(inputUnlessOutput(inputVector, outputVector), inputVector.size(), scalar, outputVector);
}

void addVectorsThenMultiplyByScalar(std::span<const float> inputVector1, std::span<const float> inputVector2, float scalar, std::span<float> outputVector)
{
    vmAddVectorsThenMultiplyByScalar(inputUnlessOutput(inputVector1, outputVector), inputUnlessOutput(inputVector2, outputVector), scalar, outputVector, inputVector1.size(), inputVector2.size());
}

float maximumMagnitude(std::span<const float> inputVector)
{
    return vmMaximumMagnitude(inputVector, alignmentInFloats(inputVector));
}

void clamp(std::span<const float> inputVector, float minimum, float maximum, std::span<float> outputVector)
{
    vmClamp(inputUnlessOutput(inputVector, outputVector), inputVector.size(), minimum, maximum, outputVector);
}

void add(std::span<const int> inputVector1, std::span<const int> inputVector2, std::span<int> outputVector)
{
    vmAddInt(inputUnlessOutput(inputVector1, outputVector), inputUnlessOutput(inputVector2, outputVector), outputVector, inputVector1.size(), inputVector2.size());
}

void add(std::span<const float> inputVector1, std::span<const float> inputVector2, std::span<float> outputVector)
{
    vmAddFloat(inputUnlessOutput(inputVector1, outputVector), inputUnlessOutput(inputVector2, outputVector), outputVector, inputVector1.size(), inputVector2.size());
}

void add(std::span<const double> inputVector1, std::span<const double> inputVector2, std::span<double> outputVector)
{
    vmAddDouble(inputUnlessOutput(inputVector1, outputVector), inputUnlessOutput(inputVector2, outputVector), outputVector, inputVector1.size(), inputVector2.size());
}

float sumOfSquares(std::span<const float> inputVector)
{
    return vmSumOfSquares(inputVector, alignmentInFloats(inputVector));
}

void linearToDecibels(std::span<const float> inputVector, std::span<float> outputVector)
{
    vmLinearToDecibels(inputUnlessOutput(inputVector, outputVector), inputVector.size(), outputVector);
}

float dotProduct(std::span<const float> inputVector1, std::span<const float> inputVector2)
{
    return vmDotProduct(inputVector1, inputVector2);
}

void convolve(std::span<const float> signal, std::span<const float> filter, std::span<float> output)
{
    vmConvolve(signal, filter, output);
}

} // namespace VectorMath

} // namespace WebCore



#endif // ENABLE(WEB_AUDIO)
