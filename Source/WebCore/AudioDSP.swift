// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

// swift-format-ignore: AllPublicDeclarationsHaveDocumentation

#if USE_SWIFT_AUDIO_DSP

// These imports make the operators JavaScriptCore declares visible before WebCore's C++ operators are.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import wtf.Core.Stopwatch

internal import WebCore_Private.AudioDSPBoundaryTypes
import Darwin

// Every entry point below receives C++ std::span parameters. The caller owns each buffer, which stays allocated at its
// length for the call, and nothing else reads or writes the buffers meanwhile, so each converted span is used only
// inside its entry. Floats, doubles and Int32 have no invalid bit patterns. Where an entry has an output, its inputs
// are the output or do not overlap it, and its outputs do not overlap each other.
// FIXME: rdar://186723514 (receiving a std::span safely).

// A NaN result carries the payload of one of its operands, and which one depends on the order the instruction takes
// them in. The compiler may swap the operands of a plain add or multiply, so those are written as fused multiply-adds
// with the operand order the library's results show: x + y is fma(x, 1, y), and x * y is fma(x, y, -0), exact for every
// non-NaN value.
private let negativeZero: Float = -0.0

// Each operation computes what the vDSP call it replaces returns, bit for bit, on arm64: a correctly rounded
// element-wise operation, or a fused multiply-add where the library fuses. Apple does not document the fusing: it was
// found by comparing the library's output with this arithmetic for every count, alignment and special value tried.
// The reductions (dot product, sum of squares, convolution) and the library's approximations (decibels,
// interpolation) are not here, because their results depend on the order the library sums in: they stay in C++.
// The size checks are the C++'s RELEASE_ASSERTs; the loops' own bounds checks cover what the C++ leaves unchecked.

// The element-wise callers pass an output that is also an input (add(a, b, a), scaling a buffer in place), as the
// library allows. Such an input is read through the output span, so that no Span and MutableSpan are read and written
// over the same memory in one loop. Any other input is disjoint from the output.
@inline(always)
private func isOutput<T: BitwiseCopyable>(_ input: Span<T>, _ output: borrowing MutableSpan<T>) -> Bool {
    output.span.extracting(first: input.count).isIdentical(to: input)
}

@inline(always)
private func mapElements<T: BitwiseCopyable>(
    _ input: Span<T>,
    _ output: inout MutableSpan<T>,
    _ transform: (T) -> T
) {
    let n = input.count
    precondition(output.count >= n)
    if isOutput(input, output) {
        for i in 0..<n { output[i] = transform(output[i]) }
    } else {
        for i in 0..<n { output[i] = transform(input[i]) }
    }
}

@inline(always)
private func combineElements<T: BitwiseCopyable>(
    _ input1: Span<T>,
    _ input2: Span<T>,
    _ output: inout MutableSpan<T>,
    _ combine: (T, T) -> T
) {
    let n = input1.count
    precondition(input2.count == n)
    precondition(output.count >= n)
    let in1IsOutput = isOutput(input1, output)
    let in2IsOutput = isOutput(input2, output)
    if in1IsOutput && in2IsOutput {
        for i in 0..<n { output[i] = combine(output[i], output[i]) }
    } else if in1IsOutput {
        for i in 0..<n { output[i] = combine(output[i], input2[i]) }
    } else if in2IsOutput {
        for i in 0..<n { output[i] = combine(input1[i], output[i]) }
    } else {
        for i in 0..<n { output[i] = combine(input1[i], input2[i]) }
    }
}

/// out[i] += in[i] * scalar.
@_expose(Cxx)
internal func vmMultiplyByScalarThenAddToOutput(
    _ input: AudioDSPSpanConstFloat,
    _ scalar: Float,
    _ output: AudioDSPSpanFloat
) {
    let input = unsafe Span<Float>(_unsafeCxxSpan: input)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    let n = input.count
    precondition(output.count >= n)
    if isOutput(input, output) {
        for i in 0..<n { output[i] = output[i].addingProduct(output[i], scalar) }
    } else {
        for i in 0..<n { output[i] = output[i].addingProduct(input[i], scalar) }
    }
}

/// out[i] = in1[i] * scalar + in2[i].
@_expose(Cxx)
internal func vmMultiplyByScalarThenAddToVector(
    _ input1: AudioDSPSpanConstFloat,
    _ scalar: Float,
    _ input2: AudioDSPSpanConstFloat,
    _ output: AudioDSPSpanFloat
) {
    let input1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let input2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    combineElements(input1, input2, &output) { $1.addingProduct($0, scalar) }
}

/// out[i] = (in1[i] + in2[i]) * scalar.
@_expose(Cxx)
internal func vmAddVectorsThenMultiplyByScalar(
    _ input1: AudioDSPSpanConstFloat,
    _ input2: AudioDSPSpanConstFloat,
    _ scalar: Float,
    _ output: AudioDSPSpanFloat
) {
    let input1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let input2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    combineElements(input1, input2, &output) { negativeZero.addingProduct($0.addingProduct($1, 1), scalar) }
}

/// out[i] = in[i] * scalar.
@_expose(Cxx)
internal func vmMultiplyByScalar(
    _ input: AudioDSPSpanConstFloat,
    _ scalar: Float,
    _ output: AudioDSPSpanFloat
) {
    let input = unsafe Span<Float>(_unsafeCxxSpan: input)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    mapElements(input, &output) { negativeZero.addingProduct($0, scalar) }
}

/// out[i] = in[i] + scalar.
@_expose(Cxx)
internal func vmAddScalar(
    _ input: AudioDSPSpanConstFloat,
    _ scalar: Float,
    _ output: AudioDSPSpanFloat
) {
    let input = unsafe Span<Float>(_unsafeCxxSpan: input)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    mapElements(input, &output) { $0.addingProduct(scalar, 1) }
}

/// out[i] = in2[i] - in1[i], as vDSP_vsub, which VectorMath::substract calls.
@_expose(Cxx)
internal func vmSubstract(
    _ input1: AudioDSPSpanConstFloat,
    _ input2: AudioDSPSpanConstFloat,
    _ output: AudioDSPSpanFloat
) {
    let input1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let input2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    combineElements(input1, input2, &output) { $1 - $0 }
}

/// out[i] = in1[i] + in2[i].
@_expose(Cxx)
internal func vmAddFloat(
    _ input1: AudioDSPSpanConstFloat,
    _ input2: AudioDSPSpanConstFloat,
    _ output: AudioDSPSpanFloat
) {
    let input1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let input2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    combineElements(input1, input2, &output) { $1.addingProduct($0, 1) }
}

/// out[i] = in1[i] + in2[i].
@_expose(Cxx)
internal func vmAddDouble(
    _ input1: AudioDSPSpanConstDouble,
    _ input2: AudioDSPSpanConstDouble,
    _ output: AudioDSPSpanDouble
) {
    let input1 = unsafe Span<Double>(_unsafeCxxSpan: input1)
    let input2 = unsafe Span<Double>(_unsafeCxxSpan: input2)
    var output = unsafe MutableSpan<Double>(_unsafeCxxSpan: output)
    combineElements(input1, input2, &output) { $0.addingProduct($1, 1) }
}

/// out[i] = in1[i] * in2[i].
@_expose(Cxx)
internal func vmMultiply(
    _ input1: AudioDSPSpanConstFloat,
    _ input2: AudioDSPSpanConstFloat,
    _ output: AudioDSPSpanFloat
) {
    let input1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let input2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    combineElements(input1, input2, &output) { negativeZero.addingProduct($1, $0) }
}

/// The largest magnitude in the input, as vDSP_maxmgv.
///
/// A NaN input gives the default NaN, not the library's payload.
@_expose(Cxx)
internal func vmMaximumMagnitude(_ input: AudioDSPSpanConstFloat) -> Float {
    let input = unsafe Span<Float>(_unsafeCxxSpan: input)
    var maximum: Float = 0
    var sawNaN = false
    for i in 0..<input.count {
        let magnitude = input[i].magnitude
        maximum = magnitude > maximum ? magnitude : maximum
        sawNaN = sawNaN || magnitude.isNaN
    }
    return sawNaN ? Float.nan : maximum
}

/// (realOut, imagOut) = (real1, imag1) * (real2, imag2).
///
/// The C++ compares the first imaginary span's size with itself, so a short second one is read out of bounds. Here it
/// traps.
@_expose(Cxx)
internal func vmMultiplyComplex(
    _ real1: AudioDSPSpanConstFloat,
    _ imag1: AudioDSPSpanConstFloat,
    _ real2: AudioDSPSpanConstFloat,
    _ imag2: AudioDSPSpanConstFloat,
    _ realOut: AudioDSPSpanFloat,
    _ imagOut: AudioDSPSpanFloat
) {
    let real1 = unsafe Span<Float>(_unsafeCxxSpan: real1)
    let imag1 = unsafe Span<Float>(_unsafeCxxSpan: imag1)
    let real2 = unsafe Span<Float>(_unsafeCxxSpan: real2)
    let imag2 = unsafe Span<Float>(_unsafeCxxSpan: imag2)
    var realOut = unsafe MutableSpan<Float>(_unsafeCxxSpan: realOut)
    var imagOut = unsafe MutableSpan<Float>(_unsafeCxxSpan: imagOut)
    let n = real1.count
    precondition(imag1.count == n)
    precondition(real2.count == n)
    precondition(imag2.count >= n)
    precondition(realOut.count >= n)
    precondition(imagOut.count >= n)
    let a1 = isOutput(real1, realOut)
    let b1 = isOutput(imag1, imagOut)
    let c1 = isOutput(real2, realOut)
    let d1 = isOutput(imag2.extracting(first: n), imagOut)
    // Both results are computed before either is stored, so the outputs may be the first operand.
    if !a1 && !b1 && !c1 && !d1 {
        for i in 0..<n {
            let a = real1[i]
            let b = imag1[i]
            let c = real2[i]
            let d = imag2[i]
            let re = (a * c).addingProduct(-b, d)
            let im = (a * d).addingProduct(b, c)
            realOut[i] = re
            imagOut[i] = im
        }
    } else if a1 && b1 && !c1 && !d1 {
        for i in 0..<n {
            let a = realOut[i]
            let b = imagOut[i]
            let c = real2[i]
            let d = imag2[i]
            let re = (a * c).addingProduct(-b, d)
            let im = (a * d).addingProduct(b, c)
            realOut[i] = re
            imagOut[i] = im
        }
    } else {
        for i in 0..<n {
            let a = a1 ? realOut[i] : real1[i]
            let b = b1 ? imagOut[i] : imag1[i]
            let c = c1 ? realOut[i] : real2[i]
            let d = d1 ? imagOut[i] : imag2[i]
            let re = (a * c).addingProduct(-b, d)
            let im = (a * d).addingProduct(b, c)
            realOut[i] = re
            imagOut[i] = im
        }
    }
}

/// out[i] = min(max(in[i], minimum), maximum).
@_expose(Cxx)
internal func vmClamp(
    _ input: AudioDSPSpanConstFloat,
    _ minimum: Float,
    _ maximum: Float,
    _ output: AudioDSPSpanFloat
) {
    let input = unsafe Span<Float>(_unsafeCxxSpan: input)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    let n = input.count
    precondition(output.count >= n)
    if isOutput(input, output) {
        clampBlocks(input, true, minimum, maximum, &output)
    } else {
        clampBlocks(input, false, minimum, maximum, &output)
    }
}

/// Clamps one element as vDSP_vclip does: NaN propagates from x or either bound, and on a tie between zeros of opposite
/// sign the maximum is +0 and the minimum is -0.
@inline(always)
private func clampExact(_ x: Float, _ minimum: Float, _ maximum: Float) -> Float {
    var lowered = x < minimum ? minimum : x
    if x == minimum && x.sign == .minus { lowered = minimum }
    if minimum.isNaN { lowered = minimum }
    var clipped = lowered > maximum ? maximum : lowered
    if lowered == maximum && lowered.sign == .plus { clipped = maximum }
    if maximum.isNaN { clipped = maximum }
    return clipped
}

/// The smallest magnitude, as bits, among the plain-comparison results for the 16 elements at i.
@inline(always)
private func smallestMagnitude(_ source: Span<Float>, _ i: Int, _ minimum: Float, _ maximum: Float) -> UInt32 {
    let block = source.extracting(i..<i + 16)
    precondition(block.count == 16)
    var smallest: UInt32 = .max
    for j in 0..<16 {
        let x = block[j]
        let lowered = x < minimum ? minimum : x
        smallest = min(smallest, (lowered > maximum ? maximum : lowered).bitPattern & 0x7fff_ffff)
    }
    return smallest
}

/// Clamps `input` into `output`, element by element, as clampExact does for every input.
///
/// When neither bound is NaN or -0, one pass of `x <= minimum` then `> maximum` is exact: a zero of either sign takes a
/// zero minimum. Otherwise a tie between zeros of different signs gives a zero result, so a block of 16 takes the
/// plain comparisons when none of its results is zero, and clampExact when one is. The zero test is a minimum over
/// the magnitude bits, which vectorises where an early-exit OR does not.
@inline(always)
private func clampBlocks(
    _ input: Span<Float>,
    _ inPlace: Bool,
    _ minimum: Float,
    _ maximum: Float,
    _ output: inout MutableSpan<Float>
) {
    let n = input.count
    var i = 0
    if !minimum.isNaN && !maximum.isNaN && !(minimum == 0 && minimum.sign == .minus) && !(maximum == 0 && maximum.sign == .minus) {
        precondition(output.count >= n)
        if inPlace {
            for j in 0..<n {
                let x = output[j]
                let lowered = x <= minimum ? minimum : x
                output[j] = lowered > maximum ? maximum : lowered
            }
        } else {
            for j in 0..<n {
                let x = input[j]
                let lowered = x <= minimum ? minimum : x
                output[j] = lowered > maximum ? maximum : lowered
            }
        }
        return
    }
    if !minimum.isNaN && !maximum.isNaN {
        while i + 16 <= n {
            let smallest = inPlace ? smallestMagnitude(output.span, i, minimum, maximum) : smallestMagnitude(input, i, minimum, maximum)
            if smallest != 0 {
                precondition(output.count >= i + 16)
                if inPlace {
                    for j in 0..<16 {
                        let x = output[i + j]
                        let lowered = x < minimum ? minimum : x
                        output[i + j] = lowered > maximum ? maximum : lowered
                    }
                } else {
                    let block = input.extracting(i..<i + 16)
                    precondition(block.count == 16)
                    for j in 0..<16 {
                        let x = block[j]
                        let lowered = x < minimum ? minimum : x
                        output[i + j] = lowered > maximum ? maximum : lowered
                    }
                }
            } else {
                precondition(output.count >= i + 16)
                if inPlace {
                    for j in 0..<16 { output[i + j] = clampExact(output[i + j], minimum, maximum) }
                } else {
                    let block = input.extracting(i..<i + 16)
                    precondition(block.count == 16)
                    for j in 0..<16 { output[i + j] = clampExact(block[j], minimum, maximum) }
                }
            }
            i += 16
        }
    }
    while i < n {
        let x = inPlace ? output[i] : input[i]
        let lowered = x < minimum ? minimum : x
        let result = lowered > maximum ? maximum : lowered
        let comparisonFormIsExact = !minimum.isNaN && !maximum.isNaN && result != 0
        output[i] = comparisonFormIsExact ? result : clampExact(x, minimum, maximum)
        i += 1
    }
}

/// The two-pole two-zero filter of vDSP_deq22D. The source and destination each start with two history samples.
@_expose(Cxx)
internal func vmFilterBiquad(
    _ source: AudioDSPSpanConstDouble,
    _ coef: AudioDSPSpanConstDouble,
    _ destination: AudioDSPSpanDouble,
    _ framesToProcess: Int
) {
    let frames = framesToProcess
    let source = unsafe Span<Double>(_unsafeCxxSpan: source)
    let coef = unsafe Span<Double>(_unsafeCxxSpan: coef)
    var destination = unsafe MutableSpan<Double>(_unsafeCxxSpan: destination)
    precondition(frames >= 0)
    precondition(source.count >= frames + 2)
    precondition(destination.count >= frames + 2)
    precondition(coef.count >= 5)
    guard frames > 0 else { return }
    let b0 = coef[0]
    let b1 = coef[1]
    let b2 = coef[2]
    let a1 = coef[3]
    let a2 = coef[4]
    var x2 = source[0]
    var x1 = source[1]
    var y2 = destination[0]
    var y1 = destination[1]
    for i in 0..<frames {
        let x = source[i + 2]
        // The order and the fusing of vDSP_deq22D, found as for the element-wise operations above.
        var sum = (b1 * x1).addingProduct(b2, x2)
        sum = sum.addingProduct(b0, x)
        sum = sum.addingProduct(-a1, y1)
        sum = sum.addingProduct(-a2, y2)
        destination[i + 2] = sum
        x2 = x1
        x1 = x
        y2 = y1
        y1 = sum
    }
}

/// out[i] = in1[i] + in2[i], wrapping as vDSP_vaddi does.
@_expose(Cxx)
internal func vmAddInt(
    _ input1: AudioDSPSpanConstInt,
    _ input2: AudioDSPSpanConstInt,
    _ output: AudioDSPSpanInt
) {
    let input1 = unsafe Span<Int32>(_unsafeCxxSpan: input1)
    let input2 = unsafe Span<Int32>(_unsafeCxxSpan: input2)
    var output = unsafe MutableSpan<Int32>(_unsafeCxxSpan: output)
    combineElements(input1, input2, &output) { $0 &+ $1 }
}

// MARK: - ZeroPole

/// First-order filter with a zero and a pole and a gain that makes 0 dB at 0 Hz. The state goes in as scalars and comes
/// back through the inout parameters.
@_expose(Cxx)
internal func zeroPoleProcess(
    _ source: AudioDSPSpanConstFloat,
    _ destination: AudioDSPSpanFloat,
    _ nFrames: UInt32,
    _ zero: Float,
    _ pole: Float,
    _ lastX: Float,
    _ lastY: Float,
    _ outLastX: inout Float,
    _ outLastY: inout Float
) {
    let n = Int(nFrames)
    guard n > 0 else { return }
    let source = unsafe Span<Float>(_unsafeCxxSpan: source)
    var destination = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    precondition(source.count >= n)
    precondition(destination.count >= n)
    let k1 = 1.0 / (1.0 - zero)
    let k2 = 1.0 - pole
    var lx = lastX
    var ly = lastY
    @inline(always)
    func step(_ inp: Float) -> Float {
        var numer = inp
        numer.addProduct(-zero, lx)
        let out1 = k1 * numer
        lx = inp
        var out2 = pole * ly
        out2.addProduct(k2, out1)
        ly = out2
        return out2
    }
    if isOutput(source.extracting(first: n), destination) {
        for i in 0..<n { destination[i] = step(destination[i]) }
    } else {
        for i in 0..<n { destination[i] = step(source[i]) }
    }
    outLastX = flushDenormalFloat(lx)
    outLastY = flushDenormalFloat(ly)
}

// MARK: - EqualPowerPanner

private let kPiOverTwo = Double.pi / 2.0

// The gains applied to a block of frames, with the library's two operations: dst = src * gain, and
// dst = other + src * gain (fused). Each runs to the end of the block before the next starts. The panners' source is
// the node's input bus and the destination its output bus, which are separate storage, so the sources do not overlap
// the destinations.
@inline(always)
private func scale(_ source: Span<Float>, _ gain: Float, _ destination: inout MutableSpan<Float>, _ n: Int) {
    precondition(source.count >= n)
    precondition(destination.count >= n)
    for i in 0..<n {
        destination[i] = negativeZero.addingProduct(source[i], gain)
    }
}

@inline(always)
private func scaleAndAdd(
    _ source: Span<Float>,
    _ gain: Float,
    _ other: Span<Float>,
    _ destination: inout MutableSpan<Float>,
    _ n: Int
) {
    precondition(source.count >= n)
    precondition(other.count >= n)
    precondition(destination.count >= n)
    for i in 0..<n {
        destination[i] = other[i].addingProduct(source[i], gain)
    }
}

/// Pans a block with the equal-power gains for `azimuth` (degrees; -180...-90 mirrors to -90...0 and 90...180 to
/// 90...0).
///
/// A mono source scales one channel into both outputs; a stereo source at azimuth <= 0 crossfades left into
/// right, and above 0 right into left.
@_expose(Cxx)
internal func eppPan(
    _ azimuth: Double,
    _ nInputChannels: UInt32,
    _ srcL: AudioDSPSpanConstFloat,
    _ srcR: AudioDSPSpanConstFloat,
    _ dstL: AudioDSPSpanFloat,
    _ dstR: AudioDSPSpanFloat,
    _ nFrames: Int32
) {
    let n = Int(nFrames)
    guard n > 0 else { return }
    // std::max(-180.0, azimuth), then std::min(180.0, ...): a NaN becomes -180.
    var az = -180.0 < azimuth ? azimuth : -180.0
    az = az < 180.0 ? az : 180.0
    if az < -90 { az = -180 - az } else if az > 90 { az = 180 - az }
    let nCh = Int(nInputChannels)
    let pos = nCh == 1 ? (az + 90) / 180 : (az <= 0 ? (az + 90) / 90 : az / 90)
    let gainL = Float(cos(kPiOverTwo * pos))
    let gainR = Float(sin(kPiOverTwo * pos))
    let srcL = unsafe Span<Float>(_unsafeCxxSpan: srcL)
    let srcR = unsafe Span<Float>(_unsafeCxxSpan: srcR)
    var dstL = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstL)
    var dstR = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstR)
    if nCh == 1 {
        scale(srcL, gainL, &dstL, n)
        scale(srcL, gainR, &dstR, n)
    } else if az <= 0 {
        scaleAndAdd(srcR, gainL, srcL, &dstL, n)
        scale(srcR, gainR, &dstR, n)
    } else {
        scale(srcL, gainL, &dstL, n)
        scaleAndAdd(srcL, gainR, srcR, &dstR, n)
    }
}

/// As eppPan, with one azimuth per frame and double gains.
@_expose(Cxx)
internal func eppPanSampleAccurate(
    _ azimuthSpan: AudioDSPSpanConstDouble,
    _ nInputChannels: UInt32,
    _ srcL: AudioDSPSpanConstFloat,
    _ srcR: AudioDSPSpanConstFloat,
    _ dstL: AudioDSPSpanFloat,
    _ dstR: AudioDSPSpanFloat,
    _ nFrames: Int32
) {
    let n = Int(nFrames)
    guard n > 0 else { return }
    let azimuths = unsafe Span<Double>(_unsafeCxxSpan: azimuthSpan)
    let srcL = unsafe Span<Float>(_unsafeCxxSpan: srcL)
    let srcR = unsafe Span<Float>(_unsafeCxxSpan: srcR)
    var dstL = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstL)
    var dstR = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstR)
    let nCh = Int(nInputChannels)
    // The C++ indexes every span up to n; the second source span only for a stereo source.
    precondition(n <= azimuths.count && n <= srcL.count && n <= dstL.count && n <= dstR.count)
    precondition(nCh == 1 || n <= srcR.count)
    for k in 0..<n {
        let raw = azimuths[k]
        // std::clamp: a NaN stays a NaN.
        var az = raw < -180 ? -180 : (180 < raw ? 180 : raw)
        if az < -90 { az = -180 - az } else if az > 90 { az = 180 - az }
        let pos = nCh == 1 ? (az + 90) / 180 : (az <= 0 ? (az + 90) / 90 : az / 90)
        let gLD = cos(kPiOverTwo * pos)
        let gRD = sin(kPiOverTwo * pos)
        if nCh == 1 {
            let l = Double(srcL[k])
            dstL[k] = Float(l * gLD)
            dstR[k] = Float(l * gRD)
        } else if raw <= 0 { // the C++ branches on the unclamped azimuth
            let l = Double(srcL[k])
            let r = Double(srcR[k])
            dstL[k] = Float(l.addingContractedProduct(r, gLD))
            dstR[k] = Float(r * gRD)
        } else {
            let l = Double(srcL[k])
            let r = Double(srcR[k])
            dstL[k] = Float(l * gLD)
            dstR[k] = Float(r.addingContractedProduct(l, gRD))
        }
    }
}

// MARK: - StereoPanner

// clampTo(value, -1.0, 1.0): NaN passes through.
@inline(always)
private func stereoPannerClamp(_ value: Double) -> Double {
    if value >= 1 { return 1 }
    if value <= -1 { return -1 }
    return value
}

/// Equal-power panning with one pan value per frame, -1...1 mapping to 0...pi/2.
@_expose(Cxx)
internal func spPanWithSampleAccurateValues(
    _ srcL: AudioDSPSpanConstFloat,
    _ srcR: AudioDSPSpanConstFloat,
    _ nInputChannels: UInt32,
    _ dstL: AudioDSPSpanFloat,
    _ dstR: AudioDSPSpanFloat,
    _ panValues: AudioDSPSpanConstFloat,
    _ nFrames: Int32
) {
    let n = Int(nFrames)
    guard n > 0 else { return }
    let srcL = unsafe Span<Float>(_unsafeCxxSpan: srcL)
    let srcR = unsafe Span<Float>(_unsafeCxxSpan: srcR)
    var dstL = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstL)
    var dstR = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstR)
    let panValues = unsafe Span<Float>(_unsafeCxxSpan: panValues)
    let nCh = Int(nInputChannels)
    for i in 0..<n {
        let pan = stereoPannerClamp(Double(panValues[i]))
        let panRadian = (nCh == 1 ? (pan * 0.5 + 0.5) : (pan <= 0 ? pan + 1 : pan)) * kPiOverTwo
        // The C++ uses double gains: float(float_input * double_gain).
        let gLD = cos(panRadian)
        let gRD = sin(panRadian)
        let l = Double(srcL[i])
        let r = Double(srcR[i])
        if nCh == 1 {
            dstL[i] = Float(l * gLD)
            dstR[i] = Float(l * gRD)
        } else if pan <= 0 {
            dstL[i] = Float(l.addingContractedProduct(r, gLD))
            dstR[i] = Float(r * gRD)
        } else {
            dstL[i] = Float(l * gLD)
            dstR[i] = Float(r.addingContractedProduct(l, gRD))
        }
    }
}

/// Equal-power panning with one pan value for the block.
@_expose(Cxx)
internal func spPanToTargetValue(
    _ srcL: AudioDSPSpanConstFloat,
    _ srcR: AudioDSPSpanConstFloat,
    _ nInputChannels: UInt32,
    _ dstL: AudioDSPSpanFloat,
    _ dstR: AudioDSPSpanFloat,
    _ panValue: Float,
    _ nFrames: Int32
) {
    let n = Int(nFrames)
    guard n > 0 else { return }
    let srcL = unsafe Span<Float>(_unsafeCxxSpan: srcL)
    let srcR = unsafe Span<Float>(_unsafeCxxSpan: srcR)
    var dstL = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstL)
    var dstR = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstR)
    let nCh = Int(nInputChannels)
    // The C++ narrows the clamped value to float, so `targetPan + 1` is a float addition.
    let pan = Float(stereoPannerClamp(Double(panValue)))
    let panRadian = (nCh == 1 ? (Double(pan) * 0.5 + 0.5) : Double(pan <= 0 ? pan + 1 : pan)) * kPiOverTwo
    let gainL = Float(cos(panRadian))
    let gainR = Float(sin(panRadian))
    if nCh == 1 {
        scale(srcL, gainL, &dstL, n)
        scale(srcL, gainR, &dstR, n)
    } else if pan <= 0 {
        scaleAndAdd(srcR, gainL, srcL, &dstL, n)
        scale(srcR, gainR, &dstR, n)
    } else {
        scale(srcL, gainL, &dstL, n)
        scaleAndAdd(srcL, gainR, srcR, &dstR, n)
    }
}

// Zeroes subnormals (magnitude below FLT_MIN), as DenormalDisabler::flushDenormalFloatToZero does.
@inline(always)
private func flushDenormalFloat(_ x: Float) -> Float {
    x.magnitude < Float.leastNormalMagnitude ? 0 : x
}

#endif // USE_SWIFT_AUDIO_DSP
