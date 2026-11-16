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

internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
// These imports make the operators JavaScriptCore declares visible before WebCore's C++ operators are
// (rdar://192229293).
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import WebCore_Private.AudioDSPBoundaryTypes
internal import wtf.Core.Stopwatch

#if canImport(simd)
internal import func simd.fma
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// FIXME: (rdar://186723514) Receiving a std::span safely.
// Each entry point views its std::span parameters through Span(_unsafeCxxSpan:). The C++ caller owns every buffer,
// allocated at its length for the call; nothing else writes one during it (the Swift calls no C++) or reads an output;
// the elements (floats, doubles or Int32) have no invalid bit patterns; and no input overlaps an output.

// Plain adds and multiplies are written as fma(x, 1, y) and fma(x, y, -0), which pin the operand order that decides a
// NaN result's payload.
private let negativeZero: Float = -0.0

// MARK: - VectorMath

// Each port's arithmetic is a VectorMathArithmetic type, chosen by VectorMathPlatform. Cocoa matches vDSP bit for bit
// on arm64; ARM64 and SSE2 match the GStreamer ports' loops (SSE2 takes the input's alignment where a sum depends on it).
enum VectorMathArithmetic {
    enum Cocoa {}
    enum ARM64 {}
    enum SSE2 {}
}

#if canImport(Accelerate)
typealias VectorMathPlatform = VectorMathArithmetic.Cocoa
#elseif arch(x86_64) || arch(i386)
typealias VectorMathPlatform = VectorMathArithmetic.SSE2
#else
typealias VectorMathPlatform = VectorMathArithmetic.ARM64
#endif

// An output that is also an input (add(a, b, a)) arrives as an empty input span with its frame count beside it
// (inputUnlessOutput); the operand here is nil and is read through the output, so no Span and MutableSpan alias.

/// Whether the output stands in for the input: an empty span with a nonzero `count`.
@inline(always)
func audioInputIsOutput<T: BitwiseCopyable>(_ input: Span<T>, _ count: Int) -> Bool {
    if input.isEmpty && count != 0 {
        return true
    }
    precondition(input.count == count)
    return false
}

@inline(always)
private func mapElements<T: BitwiseCopyable>(
    _ input: Span<T>?,
    _ n: Int,
    _ output: inout MutableSpan<T>,
    _ transform: (T) -> T
) {
    precondition(output.count >= n)
    if let input {
        for i in 0..<n { output[i] = transform(input[i]) }
    } else {
        for i in 0..<n { output[i] = transform(output[i]) }
    }
}

@inline(always)
private func combineElements<T: BitwiseCopyable>(
    _ input1: Span<T>?,
    _ n1: Int,
    _ input2: Span<T>?,
    _ n2: Int,
    _ output: inout MutableSpan<T>,
    _ combine: (T, T) -> T
) {
    let n = n1
    precondition(n2 == n)
    precondition(output.count >= n)
    if let input1 {
        if let input2 {
            for i in 0..<n { output[i] = combine(input1[i], input2[i]) }
        } else {
            for i in 0..<n { output[i] = combine(input1[i], output[i]) }
        }
    } else if let input2 {
        for i in 0..<n { output[i] = combine(output[i], input2[i]) }
    } else {
        for i in 0..<n { output[i] = combine(output[i], output[i]) }
    }
}

@inline(always)
private func accumulateElements(
    _ input: Span<Float>?,
    _ n: Int,
    _ output: inout MutableSpan<Float>,
    _ combine: (Float, Float) -> Float
) {
    precondition(output.count >= n)
    if let input {
        for i in 0..<n { output[i] = combine(output[i], input[i]) }
    } else {
        for i in 0..<n { output[i] = combine(output[i], output[i]) }
    }
}

// Where the SSE2 arithmetic starts its aligned groups of four: after the frames before the first 16-byte boundary.
// alignment & 3 is 0 to 3, so 4 &- (alignment & 3) cannot overflow.
@inline(always)
private func sse2Head(_ alignment: Int, _ n: Int) -> Int {
    min((4 &- (alignment & 3)) & 3, n)
}

@inline(always)
private func four(_ span: Span<Float>, _ i: Int) -> SIMD4<Float> {
    SIMD4(span[i], span[i + 1], span[i + 2], span[i + 3])
}

// The complex product's operands at frame i, read through the output where an input is it (nil): the real inputs
// can be the real output and the imaginary inputs the imaginary output.
private struct ComplexOperandAliasing {
    let real1IsRealOut: Bool
    let imag1IsImagOut: Bool
    let real2IsRealOut: Bool
    let imag2IsImagOut: Bool

    init(_ real1: Span<Float>?, _ imag1: Span<Float>?, _ real2: Span<Float>?, _ imag2: Span<Float>?) {
        real1IsRealOut = real1 == nil
        imag1IsImagOut = imag1 == nil
        real2IsRealOut = real2 == nil
        imag2IsImagOut = imag2 == nil
    }
}

// The frame counts of multiplyComplex's four inputs, an input that is an output included.
extension VectorMathArithmetic {
    struct ComplexCounts {
        let real1: Int
        let imag1: Int
        let real2: Int
        let imag2: Int
    }
}

// The size checks of the GStreamer ports. They compare the first imaginary span's size with itself, so a short second
// one is read past its end; here the index traps.
@inline(always)
private func checkComplexSizes(
    _ counts: VectorMathArithmetic.ComplexCounts,
    _ realOut: borrowing MutableSpan<Float>,
    _ imagOut: borrowing MutableSpan<Float>
) -> Int {
    let n = counts.real1
    precondition(counts.imag1 == n)
    precondition(counts.real2 == n)
    precondition(counts.imag2 >= n)
    precondition(realOut.count >= n)
    precondition(imagOut.count >= n)
    return n
}

// The plain loop of multiplyComplex: the real part is stored before the imaginary part reads the first and second real
// inputs, so where one of them is the real output the imaginary part takes the new real value.
@inline(always)
private func complexProductFrame(
    _ i: Int,
    _ alias: ComplexOperandAliasing,
    _ real1: Span<Float>?,
    _ imag1: Span<Float>?,
    _ real2: Span<Float>?,
    _ imag2: Span<Float>?,
    _ realOut: inout MutableSpan<Float>,
    _ imagOut: inout MutableSpan<Float>,
    _ realPart: (Float, Float, Float, Float) -> Float,
    _ imagPart: (Float, Float, Float, Float) -> Float
) {
    let (a, b, c, d) = complexOperands(i, real1, imag1, real2, imag2, realOut, imagOut)
    let re = realPart(a, b, c, d)
    realOut[i] = re
    let a2 = alias.real1IsRealOut ? re : a
    let c2 = alias.real2IsRealOut ? re : c
    imagOut[i] = imagPart(a2, b, c2, d)
}

@inline(always)
private func complexOperands(
    _ i: Int,
    _ real1: Span<Float>?,
    _ imag1: Span<Float>?,
    _ real2: Span<Float>?,
    _ imag2: Span<Float>?,
    _ realOut: borrowing MutableSpan<Float>,
    _ imagOut: borrowing MutableSpan<Float>
) -> (Float, Float, Float, Float) {
    let a: Float
    let b: Float
    let c: Float
    let d: Float
    if let real1 { a = real1[i] } else { a = realOut[i] }
    if let imag1 { b = imag1[i] } else { b = imagOut[i] }
    if let real2 { c = real2[i] } else { c = realOut[i] }
    if let imag2 { d = imag2[i] } else { d = imagOut[i] }
    return (a, b, c, d)
}

// Clamp to [minimum, maximum] by two compares; NaN passes through, and a NaN bound is ignored.
@inline(always)
private func cppClampFloat(_ x: Float, _ minimum: Float, _ maximum: Float) -> Float {
    x < minimum ? minimum : (maximum < x ? maximum : x)
}

// The larger of the two, taking value only when maximum < value, so a NaN value never wins.
@inline(always)
private func cppMaxFloat(_ maximum: Float, _ value: Float) -> Float {
    maximum < value ? value : maximum
}

// MARK: VectorMathArithmetic.Cocoa

extension VectorMathArithmetic.Cocoa {
    /// out[i] += in[i] * scalar, fused (vDSP_vsma).
    @inline(always)
    static func multiplyByScalarThenAddToOutput(
        _ input: Span<Float>?,
        _ n: Int,
        _ scalar: Float,
        _ output: inout MutableSpan<Float>
    ) {
        accumulateElements(input, n, &output) { $0.addingProduct($1, scalar) }
    }

    /// out[i] = (in1[i] + in2[i]) * scalar (vDSP_vasm).
    @inline(always)
    static func addVectorsThenMultiplyByScalar(
        _ input1: Span<Float>?,
        _ n1: Int,
        _ input2: Span<Float>?,
        _ n2: Int,
        _ scalar: Float,
        _ output: inout MutableSpan<Float>
    ) {
        combineElements(input1, n1, input2, n2, &output) { negativeZero.addingProduct($0.addingProduct($1, 1), scalar) }
    }

    /// out[i] = in[i] * scalar (vDSP_vsmul).
    @inline(always)
    static func multiplyByScalar(_ input: Span<Float>?, _ n: Int, _ scalar: Float, _ output: inout MutableSpan<Float>) {
        mapElements(input, n, &output) { negativeZero.addingProduct($0, scalar) }
    }

    /// out[i] = in[i] + scalar (vDSP_vsadd).
    @inline(always)
    static func addScalar(_ input: Span<Float>?, _ n: Int, _ scalar: Float, _ output: inout MutableSpan<Float>) {
        mapElements(input, n, &output) { $0.addingProduct(scalar, 1) }
    }

    /// out[i] = in2[i] - in1[i]: in1 is vDSP_vsub's subtrahend.
    @inline(always)
    static func substract(
        _ input1: Span<Float>?,
        _ n1: Int,
        _ input2: Span<Float>?,
        _ n2: Int,
        _ output: inout MutableSpan<Float>
    ) {
        combineElements(input1, n1, input2, n2, &output) { $1 - $0 }
    }

    /// out[i] = in1[i] + in2[i] (vDSP_vadd).
    @inline(always)
    static func add(
        _ input1: Span<Float>?,
        _ n1: Int,
        _ input2: Span<Float>?,
        _ n2: Int,
        _ output: inout MutableSpan<Float>
    ) {
        combineElements(input1, n1, input2, n2, &output) { $1.addingProduct($0, 1) }
    }

    /// out[i] = in1[i] + in2[i] (vDSP_vaddD).
    @inline(always)
    static func add(
        _ input1: Span<Double>?,
        _ n1: Int,
        _ input2: Span<Double>?,
        _ n2: Int,
        _ output: inout MutableSpan<Double>
    ) {
        combineElements(input1, n1, input2, n2, &output) { $0.addingProduct($1, 1) }
    }

    /// out[i] = in1[i] * in2[i] (vDSP_vmul).
    @inline(always)
    static func multiply(
        _ input1: Span<Float>?,
        _ n1: Int,
        _ input2: Span<Float>?,
        _ n2: Int,
        _ output: inout MutableSpan<Float>
    ) {
        combineElements(input1, n1, input2, n2, &output) { negativeZero.addingProduct($1, $0) }
    }

    /// The largest magnitude in the input, as vDSP_maxmgv does.
    ///
    /// A NaN input gives the default NaN, not the library's payload; `alignment` does not change the result.
    @inline(always)
    static func maximumMagnitude(_ input: Span<Float>, _ alignment: Int) -> Float {
        var maximum: Float = 0
        var sawNaN = false
        for i in 0..<input.count {
            let magnitude = input[i].magnitude
            maximum = magnitude > maximum ? magnitude : maximum
            sawNaN = sawNaN || magnitude.isNaN
        }
        return sawNaN ? Float.nan : maximum
    }

    /// (realOut, imagOut) = (real1, imag1) * (real2, imag2), as vDSP_zvmul: both parts are computed before either is
    /// stored. `simdAligned` does not change the library's result.
    @inline(always)
    static func multiplyComplex(
        _ real1: Span<Float>?,
        _ imag1: Span<Float>?,
        _ real2: Span<Float>?,
        _ imag2: Span<Float>?,
        _ counts: VectorMathArithmetic.ComplexCounts,
        _ realOut: inout MutableSpan<Float>,
        _ imagOut: inout MutableSpan<Float>,
        _ simdAligned: Bool
    ) {
        let n = checkComplexSizes(counts, realOut, imagOut)
        for i in 0..<n {
            let (a, b, c, d) = complexOperands(i, real1, imag1, real2, imag2, realOut, imagOut)
            let re = (a * c).addingProduct(-b, d)
            let im = (a * d).addingProduct(b, c)
            realOut[i] = re
            imagOut[i] = im
        }
    }

    /// out[i] = min(max(in[i], minimum), maximum), as vDSP_vclip.
    @inline(always)
    static func clamp(_ input: Span<Float>?, _ n: Int, _ minimum: Float, _ maximum: Float, _ output: inout MutableSpan<Float>) {
        precondition(output.count >= n)
        clampBlocks(input, n, minimum, maximum, &output)
    }

    /// The panners' dst = other + src * gain over n frames, fused (vDSP_vsma).
    @inline(always)
    static func multiplyByScalarThenAddToVector(
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
}

// MARK: VectorMathArithmetic.ARM64

extension VectorMathArithmetic.ARM64 {
    @inline(always)
    static func multiplyByScalarThenAddToOutput(
        _ input: Span<Float>?,
        _ n: Int,
        _ scalar: Float,
        _ output: inout MutableSpan<Float>
    ) {
        accumulateElements(input, n, &output) { $0.addingProduct($1, scalar) }
    }

    /// add(in1, in2, out), then multiplyByScalar(out, scalar, out): two roundings.
    @inline(always)
    static func addVectorsThenMultiplyByScalar(
        _ input1: Span<Float>?,
        _ n1: Int,
        _ input2: Span<Float>?,
        _ n2: Int,
        _ scalar: Float,
        _ output: inout MutableSpan<Float>
    ) {
        combineElements(input1, n1, input2, n2, &output) { scalar * ($0 + $1) }
    }

    @inline(always)
    static func multiplyByScalar(_ input: Span<Float>?, _ n: Int, _ scalar: Float, _ output: inout MutableSpan<Float>) {
        mapElements(input, n, &output) { scalar * $0 }
    }

    @inline(always)
    static func addScalar(_ input: Span<Float>?, _ n: Int, _ scalar: Float, _ output: inout MutableSpan<Float>) {
        mapElements(input, n, &output) { $0 + scalar }
    }

    /// `*out = *in1 - *in2` (the reverse of the Cocoa operand order).
    @inline(always)
    static func substract(
        _ input1: Span<Float>?,
        _ n1: Int,
        _ input2: Span<Float>?,
        _ n2: Int,
        _ output: inout MutableSpan<Float>
    ) {
        combineElements(input1, n1, input2, n2, &output) { $0 - $1 }
    }

    @inline(always)
    static func add(
        _ input1: Span<Float>?,
        _ n1: Int,
        _ input2: Span<Float>?,
        _ n2: Int,
        _ output: inout MutableSpan<Float>
    ) {
        combineElements(input1, n1, input2, n2, &output) { $0 + $1 }
    }

    @inline(always)
    static func add(
        _ input1: Span<Double>?,
        _ n1: Int,
        _ input2: Span<Double>?,
        _ n2: Int,
        _ output: inout MutableSpan<Double>
    ) {
        combineElements(input1, n1, input2, n2, &output) { $0 + $1 }
    }

    @inline(always)
    static func multiply(
        _ input1: Span<Float>?,
        _ n1: Int,
        _ input2: Span<Float>?,
        _ n2: Int,
        _ output: inout MutableSpan<Float>
    ) {
        combineElements(input1, n1, input2, n2, &output) { $0 * $1 }
    }

    /// The largest magnitude over the input, from 0: a NaN magnitude never replaces the maximum.
    @inline(always)
    static func maximumMagnitude(_ input: Span<Float>, _ alignment: Int) -> Float {
        var maximum: Float = 0
        for i in 0..<input.count { maximum = cppMaxFloat(maximum, input[i].magnitude) }
        return maximum
    }

    /// The plain loop, contracted: re = fma(a, c, -(b * d)), im = fma(a, d, b * c) (the left product fuses).
    @inline(always)
    static func multiplyComplex(
        _ real1: Span<Float>?,
        _ imag1: Span<Float>?,
        _ real2: Span<Float>?,
        _ imag2: Span<Float>?,
        _ counts: VectorMathArithmetic.ComplexCounts,
        _ realOut: inout MutableSpan<Float>,
        _ imagOut: inout MutableSpan<Float>,
        _ simdAligned: Bool
    ) {
        let n = checkComplexSizes(counts, realOut, imagOut)
        let alias = ComplexOperandAliasing(real1, imag1, real2, imag2)
        for i in 0..<n {
            complexProductFrame(
                i,
                alias,
                real1,
                imag1,
                real2,
                imag2,
                &realOut,
                &imagOut,
                { a, b, c, d in (-(b * d)).addingProduct(a, c) },
                { a, b, c, d in (b * c).addingProduct(a, d) }
            )
        }
    }

    /// Clamps each frame to [minimum, maximum].
    @inline(always)
    static func clamp(_ input: Span<Float>?, _ n: Int, _ minimum: Float, _ maximum: Float, _ output: inout MutableSpan<Float>) {
        // Stops when maximum < minimum (the string is the message the clamp's bounds check has always given).
        precondition(n == 0 || !(maximum < minimum), "Bad bounds passed to std::clamp")
        mapElements(input, n, &output) { cppClampFloat($0, minimum, maximum) }
    }

    /// `sum += x * x` from 0: whole groups of four take a vector multiply (product rounded) and in-order adds, the rest the contracted loop.
    @inline(always)
    static func sumOfSquares(_ input: Span<Float>, _ alignment: Int) -> Float {
        let n = input.count
        let vectorEnd = n - n % 4
        var sum: Float = 0
        for i in 0..<vectorEnd {
            let x = input[i]
            sum = sum + x * x
        }
        for i in vectorEnd..<n {
            let x = input[i]
            sum = sum.addingProduct(x, x)
        }
        return sum
    }

    /// `result += in1[i] * in2[i]` from 0, vectorized as sumOfSquares is.
    @inline(always)
    static func dotProduct(_ input1: Span<Float>, _ input2: Span<Float>) -> Float {
        let n = input1.count
        precondition(input2.count == n)
        let vectorEnd = n - n % 4
        var sum: Float = 0
        for i in 0..<vectorEnd { sum = sum + input1[i] * input2[i] }
        for i in vectorEnd..<n { sum = sum.addingProduct(input1[i], input2[i]) }
        return sum
    }

    /// output[i] = sum(signal[i + filterSize - 1 - j] * filter[j]) in order of j from 0, every step contracted, the order of
    /// the GStreamer ports' unrolled 32, 64 and 128 tap filters as well.
    @inline(always)
    static func convolve(_ signal: Span<Float>, _ filter: Span<Float>, _ output: inout MutableSpan<Float>) {
        let filterSize = filter.count
        precondition(filterSize > 0)
        precondition(signal.count >= output.count + filterSize - 1)
        for i in 0..<output.count {
            var sum: Float = 0
            let window = signal.extracting(i..<i + filterSize)
            for j in 0..<filterSize { sum = sum.addingProduct(window[filterSize - 1 - j], filter[j]) }
            output[i] = sum
        }
    }

    @inline(always)
    static func linearToDecibels(_ input: Span<Float>?, _ n: Int, _ output: inout MutableSpan<Float>) {
        mapElements(input, n, &output) { 20 * log10($0) }
    }

    /// multiplyByScalar then add: two roundings, on both architectures.
    @inline(always)
    static func multiplyByScalarThenAddToVector(
        _ source: Span<Float>,
        _ gain: Float,
        _ other: Span<Float>,
        _ destination: inout MutableSpan<Float>,
        _ n: Int
    ) {
        precondition(destination.count == other.count)
        precondition(source.count >= n)
        precondition(other.count >= n)
        precondition(destination.count >= n)
        for i in 0..<n {
            destination[i] = gain * source[i] + other[i]
        }
    }
}

// MARK: VectorMathArithmetic.SSE2

extension VectorMathArithmetic.SSE2 {
    /// The SSE2 block and the scalar frames both compute `out + scalar * in`, rounded twice.
    @inline(always)
    static func multiplyByScalarThenAddToOutput(
        _ input: Span<Float>?,
        _ n: Int,
        _ scalar: Float,
        _ output: inout MutableSpan<Float>
    ) {
        accumulateElements(input, n, &output) { $0 + scalar * $1 }
    }

    // The element-wise operations below compute each frame as the plain loop does, in the SSE2 block too: nothing is
    // contracted on x86_64, so the result does not depend on the alignment.
    @inline(always)
    static func addVectorsThenMultiplyByScalar(
        _ input1: Span<Float>?,
        _ n1: Int,
        _ input2: Span<Float>?,
        _ n2: Int,
        _ scalar: Float,
        _ output: inout MutableSpan<Float>
    ) {
        combineElements(input1, n1, input2, n2, &output) { scalar * ($0 + $1) }
    }

    @inline(always)
    static func multiplyByScalar(_ input: Span<Float>?, _ n: Int, _ scalar: Float, _ output: inout MutableSpan<Float>) {
        mapElements(input, n, &output) { scalar * $0 }
    }

    @inline(always)
    static func addScalar(_ input: Span<Float>?, _ n: Int, _ scalar: Float, _ output: inout MutableSpan<Float>) {
        mapElements(input, n, &output) { $0 + scalar }
    }

    @inline(always)
    static func substract(
        _ input1: Span<Float>?,
        _ n1: Int,
        _ input2: Span<Float>?,
        _ n2: Int,
        _ output: inout MutableSpan<Float>
    ) {
        combineElements(input1, n1, input2, n2, &output) { $0 - $1 }
    }

    @inline(always)
    static func add(
        _ input1: Span<Float>?,
        _ n1: Int,
        _ input2: Span<Float>?,
        _ n2: Int,
        _ output: inout MutableSpan<Float>
    ) {
        combineElements(input1, n1, input2, n2, &output) { $0 + $1 }
    }

    @inline(always)
    static func add(
        _ input1: Span<Double>?,
        _ n1: Int,
        _ input2: Span<Double>?,
        _ n2: Int,
        _ output: inout MutableSpan<Double>
    ) {
        combineElements(input1, n1, input2, n2, &output) { $0 + $1 }
    }

    @inline(always)
    static func multiply(
        _ input1: Span<Float>?,
        _ n1: Int,
        _ input2: Span<Float>?,
        _ n2: Int,
        _ output: inout MutableSpan<Float>
    ) {
        combineElements(input1, n1, input2, n2, &output) { $0 * $1 }
    }

    /// The frames before the first 16-byte boundary, four lanes of `_mm_max_ps(lane, |x|)`, the lanes in order, then the rest.
    @inline(always)
    static func maximumMagnitude(_ input: Span<Float>, _ alignment: Int) -> Float {
        let n = input.count
        let head = sse2Head(alignment, n)
        let groupsEnd = head + (n - head) / 4 * 4
        var maximum: Float = 0
        for i in 0..<head { maximum = cppMaxFloat(maximum, input[i].magnitude) }
        var lanes = SIMD4<Float>(repeating: 0)
        var i = head
        while i < groupsEnd {
            let v = four(input, i)
            let magnitudes = SIMD4(v[0].magnitude, v[1].magnitude, v[2].magnitude, v[3].magnitude)
            lanes.replace(with: magnitudes, where: .!(lanes .> magnitudes))
            i += 4
        }
        for lane in 0..<4 { maximum = cppMaxFloat(maximum, lanes[lane]) }
        for j in groupsEnd..<n { maximum = cppMaxFloat(maximum, input[j].magnitude) }
        return maximum
    }

    /// The SSE2 block when all six spans are 16-byte aligned (`simdAligned`), else the plain loop, with the same arithmetic: nothing fuses.
    @inline(always)
    static func multiplyComplex(
        _ real1: Span<Float>?,
        _ imag1: Span<Float>?,
        _ real2: Span<Float>?,
        _ imag2: Span<Float>?,
        _ counts: VectorMathArithmetic.ComplexCounts,
        _ realOut: inout MutableSpan<Float>,
        _ imagOut: inout MutableSpan<Float>,
        _ simdAligned: Bool
    ) {
        let n = checkComplexSizes(counts, realOut, imagOut)
        let alias = ComplexOperandAliasing(real1, imag1, real2, imag2)
        let groupsEnd = simdAligned ? n - n % 4 : 0
        for i in 0..<groupsEnd {
            let (a, b, c, d) = complexOperands(i, real1, imag1, real2, imag2, realOut, imagOut)
            let re = a * c - b * d
            let im = a * d + b * c
            realOut[i] = re
            imagOut[i] = im
        }
        for i in groupsEnd..<n {
            complexProductFrame(
                i,
                alias,
                real1,
                imag1,
                real2,
                imag2,
                &realOut,
                &imagOut,
                { a, b, c, d in a * c - b * d },
                { a, b, c, d in a * d + b * c }
            )
        }
    }

    /// Clamps each frame to [minimum, maximum] (there is no SSE2 block for it).
    @inline(always)
    static func clamp(_ input: Span<Float>?, _ n: Int, _ minimum: Float, _ maximum: Float, _ output: inout MutableSpan<Float>) {
        precondition(n == 0 || !(maximum < minimum), "Bad bounds passed to std::clamp")
        mapElements(input, n, &output) { cppClampFloat($0, minimum, maximum) }
    }

    /// The frames before the first 16-byte boundary into `sum`; then four lane sums from 0; then
    /// sum += ((l0 + l1) + l2) + l3; then the remaining frames; nothing fuses.
    @inline(always)
    static func sumOfSquares(_ input: Span<Float>, _ alignment: Int) -> Float {
        let n = input.count
        let head = sse2Head(alignment, n)
        let groupsEnd = head + (n - head) / 4 * 4
        var sum: Float = 0
        for i in 0..<head {
            let x = input[i]
            sum = sum + x * x
        }
        var lanes = SIMD4<Float>(repeating: 0)
        var i = head
        while i < groupsEnd {
            let v = four(input, i)
            lanes = lanes + v * v
            i += 4
        }
        sum = sum + (((lanes[0] + lanes[1]) + lanes[2]) + lanes[3])
        for j in groupsEnd..<n {
            let x = input[j]
            sum = sum + x * x
        }
        return sum
    }

    /// `result += in1[i] * in2[i]` from 0, in order, rounded at each step.
    @inline(always)
    static func dotProduct(_ input1: Span<Float>, _ input2: Span<Float>) -> Float {
        let n = input1.count
        precondition(input2.count == n)
        var sum: Float = 0
        for i in 0..<n { sum = sum + input1[i] * input2[i] }
        return sum
    }

    /// As VectorMathArithmetic.ARM64.convolve, rounded at each step.
    @inline(always)
    static func convolve(_ signal: Span<Float>, _ filter: Span<Float>, _ output: inout MutableSpan<Float>) {
        let filterSize = filter.count
        precondition(filterSize > 0)
        precondition(signal.count >= output.count + filterSize - 1)
        for i in 0..<output.count {
            var sum: Float = 0
            let window = signal.extracting(i..<i + filterSize)
            for j in 0..<filterSize { sum = sum + window[filterSize - 1 - j] * filter[j] }
            output[i] = sum
        }
    }

    @inline(always)
    static func linearToDecibels(_ input: Span<Float>?, _ n: Int, _ output: inout MutableSpan<Float>) {
        mapElements(input, n, &output) { 20 * log10($0) }
    }

    /// As VectorMathArithmetic.ARM64.multiplyByScalarThenAddToVector: nothing fused there either.
    @inline(always)
    static func multiplyByScalarThenAddToVector(
        _ source: Span<Float>,
        _ gain: Float,
        _ other: Span<Float>,
        _ destination: inout MutableSpan<Float>,
        _ n: Int
    ) {
        precondition(destination.count == other.count)
        precondition(source.count >= n)
        precondition(other.count >= n)
        precondition(destination.count >= n)
        for i in 0..<n {
            destination[i] = gain * source[i] + other[i]
        }
    }
}

// MARK: VectorMathArithmetic.Cocoa reductions

// What the vDSP reductions (dotProduct, sumOfSquares, linearToDecibels, convolve) return on arm64, bit for bit, in safe
// Swift. None depends on the input's alignment; a NaN result is some NaN, and zeros keep the library's signs.

private typealias V4 = SIMD4<Float>

// Four floats from `i` as one unaligned vector load; the check folds away for a view of literal count.
@inline(always)
private func load4(_ span: Span<Float>, _ i: Int) -> V4 {
    span.bytes.load(fromByteOffset: i * 4, as: V4.self)
}

// Four floats stored from `i` as one vector, bounds-checked once.
@inline(always)
private func store4(_ span: inout MutableSpan<Float>, _ i: Int, _ v: V4) {
    var bytes = span.mutableBytes
    bytes.storeBytes(of: v, toByteOffset: i * 4, as: V4.self)
}

// fmla: a + b * c, fused; simd's fma is one vector fma where addingProduct is a loop over lanes.
@inline(always)
private func fused(_ a: V4, _ b: V4, _ c: V4) -> V4 {
    #if canImport(simd)
    simd.fma(b, c, a)
    #else
    a.addingProduct(b, c)
    #endif
}

// A vector times a broadcast scalar; lowers to fmla by element, about 5% faster in conv than simd.fma with a splat.
@inline(always)
private func fused(_ a: V4, _ b: V4, _ c: Float) -> V4 {
    a.addingProduct(b, V4(repeating: c))
}

// faddp then faddp: (l0 + l1) + (l2 + l3).
@inline(always)
private func pairwiseSum(_ v: V4) -> Float {
    (v[0] + v[1]) + (v[2] + v[3])
}

enum VDSPReductions {
    /// vDSP_dotpr(a, 1, b, 1, &r, n), in the library's accumulation order.
    @inline(always)
    static func dotProduct(_ a: Span<Float>, _ b: Span<Float>) -> Float {
        let n = a.count
        precondition(b.count == n)
        if n < 4 {
            var sum: Float = 0
            for i in 0..<n { sum = sum.addingProduct(a[i], b[i]) }
            return sum
        }
        var v0 = V4()
        var v1 = V4()
        var i = 0
        if n >= 32 {
            var g0 = V4()
            var g1 = V4()
            var g2 = V4()
            var g3 = V4()
            var g4 = V4()
            var g5 = V4()
            var g6 = V4()
            var g7 = V4()
            while n - i >= 32 {
                let wa = a.extracting(droppingFirst: i).extracting(0..<32)
                let wb = b.extracting(droppingFirst: i).extracting(0..<32)
                g0 = fused(g0, load4(wa, 0), load4(wb, 0))
                g1 = fused(g1, load4(wa, 4), load4(wb, 4))
                g2 = fused(g2, load4(wa, 8), load4(wb, 8))
                g3 = fused(g3, load4(wa, 12), load4(wb, 12))
                g4 = fused(g4, load4(wa, 16), load4(wb, 16))
                g5 = fused(g5, load4(wa, 20), load4(wb, 20))
                g6 = fused(g6, load4(wa, 24), load4(wb, 24))
                g7 = fused(g7, load4(wa, 28), load4(wb, 28))
                i += 32
            }
            v0 = (g2 + g3) + (g4 + g5)
            v1 = (g6 + g7) + (g1 + g0)
        }
        while n - i >= 8 {
            let wa = a.extracting(droppingFirst: i).extracting(0..<8)
            let wb = b.extracting(droppingFirst: i).extracting(0..<8)
            v0 = fused(v0, load4(wa, 0), load4(wb, 0))
            v1 = fused(v1, load4(wa, 4), load4(wb, 4))
            i += 8
        }
        v0 = v0 + v1
        if n - i >= 4 {
            v0 = fused(v0, load4(a, i), load4(b, i))
            i += 4
        }
        var p0 = v0[0] + v0[1]
        var p1 = v0[2] + v0[3]
        if n - i >= 2 {
            p0 = p0.addingProduct(a[i], b[i])
            p1 = p1.addingProduct(a[i + 1], b[i + 1])
            i += 2
        }
        var sum = p0 + p1
        if i < n { sum = sum.addingProduct(a[i], b[i]) }
        return sum
    }

    /// vDSP_svesq(x, 1, &r, n), in the library's accumulation order.
    @inline(always)
    static func sumOfSquares(_ x: Span<Float>) -> Float {
        let n = x.count
        if n == 0 { return 0 }
        var v0 = V4()
        var i = 0
        @inline(always)
        func sq(_ g: V4) -> V4 { g * g }
        if n >= 32 {
            let w = x.extracting(0..<32)
            var v1: V4
            var v2: V4
            var v3: V4
            v0 = sq(load4(w, 0))
            v1 = sq(load4(w, 4))
            v2 = sq(load4(w, 8))
            v3 = sq(load4(w, 12))
            let blocks = n / 32
            if blocks == 1 {
                v0 = fused(v0, load4(w, 16), load4(w, 16))
                v1 = fused(v1, load4(w, 20), load4(w, 20))
                v2 = fused(v2, load4(w, 24), load4(w, 24))
                v3 = fused(v3, load4(w, 28), load4(w, 28))
            } else {
                var u0 = sq(load4(w, 16))
                var u1 = sq(load4(w, 20))
                var u2 = sq(load4(w, 24))
                var u3 = sq(load4(w, 28))
                var rest = x.extracting(32..<32 * blocks)
                var b = rest.extracting(0..<32)
                var g0 = load4(b, 0)
                var g1 = load4(b, 4)
                var g2 = load4(b, 8)
                var g3 = load4(b, 12)
                var h0 = load4(b, 16)
                var h1 = load4(b, 20)
                var h2 = load4(b, 24)
                var h3 = load4(b, 28)
                while rest.count > 32 {
                    rest = rest.extracting(droppingFirst: 32)
                    b = rest.extracting(0..<32)
                    let n0 = load4(b, 0)
                    let n1 = load4(b, 4)
                    let n2 = load4(b, 8)
                    let n3 = load4(b, 12)
                    v0 = fused(v0, g0, g0)
                    v1 = fused(v1, g1, g1)
                    v2 = fused(v2, g2, g2)
                    v3 = fused(v3, g3, g3)
                    let m0 = load4(b, 16)
                    let m1 = load4(b, 20)
                    let m2 = load4(b, 24)
                    let m3 = load4(b, 28)
                    u0 = fused(u0, h0, h0)
                    u1 = fused(u1, h1, h1)
                    u2 = fused(u2, h2, h2)
                    u3 = fused(u3, h3, h3)
                    g0 = n0
                    g1 = n1
                    g2 = n2
                    g3 = n3
                    h0 = m0
                    h1 = m1
                    h2 = m2
                    h3 = m3
                }
                v0 = fused(v0, g0, g0)
                v1 = fused(v1, g1, g1)
                v2 = fused(v2, g2, g2)
                v3 = fused(v3, g3, g3)
                v0 = v0 + u0
                v1 = v1 + u1
                v2 = v2 + u2
                v3 = v3 + u3
                v0 = fused(v0, h0, h0)
                v1 = fused(v1, h1, h1)
                v2 = fused(v2, h2, h2)
                v3 = fused(v3, h3, h3)
            }
            i = 32 * blocks
            v0 = (v0 + v2) + (v1 + v3)
        } else if n >= 16 {
            let w = x.extracting(0..<16)
            v0 = sq(load4(w, 0))
            let v1 = sq(load4(w, 4))
            let v2 = sq(load4(w, 8))
            let v3 = sq(load4(w, 12))
            v0 = (v0 + v2) + (v1 + v3)
            i = 16
        } else if n >= 8 {
            let w = x.extracting(0..<8)
            v0 = sq(load4(w, 0)) + sq(load4(w, 4))
            i = 8
        } else if n >= 4 {
            v0 = sq(load4(x, 0))
            i = 4
        }
        while n - i >= 4 {
            let g = load4(x.extracting(droppingFirst: i).extracting(0..<4), 0)
            v0 = fused(v0, g, g)
            i += 4
        }
        let r = n - i
        if r != 0 {
            var pair = V4()
            if r & 2 != 0 {
                pair[0] = x[i]
                pair[1] = x[i + 1]
                i += 2
            }
            var single = V4()
            if r & 1 != 0 { single[0] = x[i] }
            v0 = fused(v0, pair, pair)
            v0 = fused(v0, single, single)
        }
        return pairwiseSum(v0)
    }

    /// vDSP_conv(signal, 1, &filter[filter.count - 1], -1, output, 1, output.count, filter.count): output[o] is the sum
    /// over k of signal[o + k] * filter[filter.count - 1 - k], in the library's accumulation order.
    @inline(always)
    static func convolve(_ signal: Span<Float>, _ filter: Span<Float>, _ output: inout MutableSpan<Float>) {
        let taps = filter.count
        let n = output.count
        precondition(taps > 0)
        precondition(signal.count >= n + taps - 1)
        let last = taps - 1
        if taps <= 3 {
            let f0 = filter[last]
            for o in 0..<n {
                var s = signal[o] * f0
                if taps >= 2 { s = s.addingProduct(signal[o + 1], filter[last - 1]) }
                if taps == 3 { s = s.addingProduct(signal[o + 2], filter[0]) }
                output[o] = s
            }
            return
        }
        var o = 0
        while n - o >= 16 {
            let (v0, v1, v2, v3) = convolveBlock16(signal, filter, o)
            var bytes = output.mutableBytes
            bytes.storeBytes(of: v0, toByteOffset: o * 4, as: V4.self)
            bytes.storeBytes(of: v1, toByteOffset: o * 4 + 16, as: V4.self)
            bytes.storeBytes(of: v2, toByteOffset: o * 4 + 32, as: V4.self)
            bytes.storeBytes(of: v3, toByteOffset: o * 4 + 48, as: V4.self)
            o += 16
        }
        while n - o >= 4 {
            store4(&output, o, convolveVector4(signal, filter, o))
            o += 4
        }
        while o < n {
            output[o] = convolveSingle(signal, filter, o)
            o += 1
        }
    }
}

// vvlog2f's table, indexed by the input's top three mantissa bits rounded: a reciprocal of the mantissa and the log2
// offset, padded to 16 entries so any index masked to four bits is in it.
private let log2Table: [UInt64] = [
    0x0000_0000_3f80_0000,
    0x3e29_ecac_3f64_2f47,
    0x3ea3_5c65_3f4d_34fa,
    0x3ee9_c09e_3f3a_8deb,
    0xbed5_2af4_3f2a_d23b,
    0xbe98_f5dc_3f1d_7339,
    0xbe4a_3655_3f12_c6ac,
    0xbdb6_8248_3f08_27e9,
    0x0000_0000_3f00_0000,
    0, 0, 0, 0, 0, 0, 0,
]

private typealias U4 = SIMD4<UInt32>
private typealias I4 = SIMD4<Int32>

// All-ones lanes where the lane's sign bit is set.
@inline(always)
private func signMask(_ v: U4) -> U4 {
    U4(truncatingIfNeeded: I4(truncatingIfNeeded: v) &>> 31)
}

// Sign bit set in the lanes that are not positive normal floats: bits - 0x0080_0000 >= 0x7f00_0000 as unsigned.
@inline(always)
private func outsideNormal(_ bits: U4) -> U4 {
    let u = bits &- 0x0080_0000
    return u | (u &+ 0x0100_0000)
}

// vForceLog2 with the special cases as lane masks. `general: false` is for lanes known to be positive normal floats: it
// skips the subnormal scaling and the fix-ups.
private struct Log2Lanes {
    var bits: U4, mantissa: U4, exponent: V4

    @inline(always)
    init(_ x: V4, general: Bool) {
        bits = bitCast(x, to: U4.self)
        let normal: U4
        if general {
            // bits < 0x0080_0000 as unsigned: positive subnormals and +0.
            let subnormal = signMask((bits &- 0x0080_0000) & ~bits)
            let scaled = bitCast(x * V4(repeating: Float(bitPattern: 0x4b00_0000)), to: U4.self)
            normal = (scaled & subnormal) | (bits & ~subnormal)
            let biased = I4(truncatingIfNeeded: normal &+ 0xc0c8_0000) &>> 23
            exponent = V4(biased &- (I4(truncatingIfNeeded: subnormal) & 23))
        } else {
            normal = bits
            exponent = V4(I4(truncatingIfNeeded: bits &+ 0xc0c8_0000) &>> 23)
        }
        mantissa = normal & 0x007f_ffff
    }

    // The table index, 0...8: the top three mantissa bits rounded.
    @inline(always)
    var index: U4 { (mantissa &+ 0x0008_0000) &>> 20 }

    @inline(always)
    func finish(_ c: V4, _ t: V4, general: Bool) -> V4 {
        let m = bitCast(mantissa | 0x3f80_0000, to: V4.self)
        let r = fused(V4(repeating: -1), c, m)
        let r2 = r * r
        var p = fused(V4(repeating: Float(bitPattern: 0x3fb8_aa3b)), V4(repeating: Float(bitPattern: 0xbf38_aa2d)), r)
        let q = fused(V4(repeating: Float(bitPattern: 0x3ef6_3993)), V4(repeating: Float(bitPattern: 0xbeb9_2e1d)), r)
        p = fused(p, r2, q)
        let r4 = r2 * r2
        var sum = exponent + t
        sum = fused(sum, r4, r * Float(bitPattern: 0x3e92_0aa5))
        let result = r * p + sum
        if !general { return result }
        let value = bitCast(result, to: U4.self)
        // Special lanes: bits == 0 or bits >= 0x7f80_0000 (unsigned: +Inf, NaN, every negative).
        // (bits - 1 >= 0x7f7f_ffff unsigned: the sign bit of u, or of u + 2^31 - 0x7f7f_ffff when u < 2^31.)
        let u = bits &- 1
        let special = signMask(u | (u &+ 0x0080_0001))
        // Their results: ±0 -> -Inf, +Inf -> +Inf, the rest NaN.
        let zero = signMask((bits & 0x7fff_ffff) &- 1)
        let infinity = signMask(((bits ^ 0x7f80_0000) &- 1) & ~bits)
        let fix = (zero & 0xff80_0000) | (infinity & 0x7f80_0000) | (~(zero | infinity) & 0x7fc0_0000)
        return bitCast((value & ~special) | (fix & special), to: V4.self)
    }
}

// The table entries of four lanes, from the indexes packed at byte `shift / 8` of `word` (lanes 0, 1) and `high` (2, 3).
@inline(always)
private func lookup(_ table: Span<UInt64>, _ low: UInt64, _ high: UInt64, _ shift: UInt64) -> (V4, V4) {
    let a = SIMD2(table[Int((low &>> shift) & 15)], table[Int((low &>> (shift + 32)) & 15)])
    let b = SIMD2(table[Int((high &>> shift) & 15)], table[Int((high &>> (shift + 32)) & 15)])
    let fa = bitCast(a, to: V4.self)
    let fb = bitCast(b, to: V4.self)
    return (V4(fa[0], fa[2], fb[0], fb[2]), V4(fa[1], fa[3], fb[1], fb[3]))
}

// log2 of 16 lanes, the four vectors' indexes packed into one vector's bytes.
@inline(always)
private func vForceLog2(
    _ x0: V4,
    _ x1: V4,
    _ x2: V4,
    _ x3: V4,
    _ table: Span<UInt64>,
    general: Bool
) -> (V4, V4, V4, V4) {
    let l0 = Log2Lanes(x0, general: general)
    let l1 = Log2Lanes(x1, general: general)
    let l2 = Log2Lanes(x2, general: general)
    let l3 = Log2Lanes(x3, general: general)
    let packed = l0.index | (l1.index &<< 8) | (l2.index &<< 16) | (l3.index &<< 24)
    let words = bitCast(packed, to: SIMD2<UInt64>.self)
    let w0 = words[0]
    let w1 = words[1]
    let (c0, t0) = lookup(table, w0, w1, 0)
    let (c1, t1) = lookup(table, w0, w1, 8)
    let (c2, t2) = lookup(table, w0, w1, 16)
    let (c3, t3) = lookup(table, w0, w1, 24)
    return (
        l0.finish(c0, t0, general: general), l1.finish(c1, t1, general: general),
        l2.finish(c2, t2, general: general), l3.finish(c3, t3, general: general)
    )
}

extension VDSPReductions {
    /// vDSP_vdbcon(x, 1, &one, out, 1, n, 1): x times 1, vvlog10f (vvlog2f times log10(2) as float), then times 20, each
    /// rounded; 16 lanes at a time, then four, then one; a nil input is the output, in place.
    @inline(always)
    static func linearToDecibels(_ input: Span<Float>?, _ n: Int, _ output: inout MutableSpan<Float>) {
        precondition(output.count >= n)
        let log10Of2 = Float(bitPattern: 0x3e9a_209b)
        let table = log2Table.span
        @inline(always)
        func db(_ y: V4) -> V4 { 20 * (y * log10Of2) }
        var i = 0
        while n - i >= 16 {
            let x0: V4
            let x1: V4
            let x2: V4
            let x3: V4
            if let input {
                let w = input.extracting(droppingFirst: i).extracting(0..<16)
                x0 = load4(w, 0)
                x1 = load4(w, 4)
                x2 = load4(w, 8)
                x3 = load4(w, 12)
            } else {
                let w = output.span.extracting(droppingFirst: i).extracting(0..<16)
                x0 = load4(w, 0)
                x1 = load4(w, 4)
                x2 = load4(w, 8)
                x3 = load4(w, 12)
            }
            // One test per 16 lanes for zeros, subnormals, negatives, infinities and NaNs.
            let outside =
                outsideNormal(bitCast(x0, to: U4.self)) | outsideNormal(bitCast(x1, to: U4.self))
                | outsideNormal(bitCast(x2, to: U4.self)) | outsideNormal(bitCast(x3, to: U4.self))
            let words = bitCast(outside, to: SIMD2<UInt64>.self)
            var y0: V4
            var y1: V4
            var y2: V4
            var y3: V4
            if (words[0] | words[1]) & 0x8000_0000_8000_0000 == 0 {
                (y0, y1, y2, y3) = vForceLog2(x0, x1, x2, x3, table, general: false)
            } else {
                (y0, y1, y2, y3) = vForceLog2(x0, x1, x2, x3, table, general: true)
            }
            y0 = db(y0)
            y1 = db(y1)
            y2 = db(y2)
            y3 = db(y3)
            var bytes = output.mutableBytes
            bytes.storeBytes(of: y0, toByteOffset: i * 4, as: V4.self)
            bytes.storeBytes(of: y1, toByteOffset: i * 4 + 16, as: V4.self)
            bytes.storeBytes(of: y2, toByteOffset: i * 4 + 32, as: V4.self)
            bytes.storeBytes(of: y3, toByteOffset: i * 4 + 48, as: V4.self)
            i += 16
        }
        // The last 1...15: padded to 16 with ones (any positive normal float would do), the real lanes stored.
        if i < n {
            var x = (V4(repeating: 1), V4(repeating: 1), V4(repeating: 1), V4(repeating: 1))
            for k in 0..<(n - i) {
                let value: Float
                if let input { value = input[i + k] } else { value = output[i + k] }
                switch k >> 2 {
                case 0: x.0[k & 3] = value
                case 1: x.1[k & 3] = value
                case 2: x.2[k & 3] = value
                default: x.3[k & 3] = value
                }
            }
            var (y0, y1, y2, y3) = vForceLog2(x.0, x.1, x.2, x.3, table, general: true)
            y0 = db(y0)
            y1 = db(y1)
            y2 = db(y2)
            y3 = db(y3)
            for k in 0..<(n - i) {
                switch k >> 2 {
                case 0: output[i + k] = y0[k & 3]
                case 1: output[i + k] = y1[k & 3]
                case 2: output[i + k] = y2[k & 3]
                default: output[i + k] = y3[k & 3]
                }
            }
        }
    }
}

// Taps k...k + 7 of the reversed filter (tap k is filter[count - 1 - k]) as two vectors read once.
private struct Taps8 {
    var low: V4, high: V4
    @inline(always)
    init(_ filter: Span<Float>, _ k: Int) {
        let w = filter.extracting(droppingFirst: filter.count - k - 8).extracting(0..<8)
        low = load4(w, 0)
        high = load4(w, 4)
    }
    @inline(always)
    var t0: Float { high[3] }
    @inline(always)
    var t1: Float { high[2] }
    @inline(always)
    var t2: Float { high[1] }
    @inline(always)
    var t3: Float { high[0] }
    @inline(always)
    var t4: Float { low[3] }
    @inline(always)
    var t5: Float { low[2] }
    @inline(always)
    var t6: Float { low[1] }
    @inline(always)
    var t7: Float { low[0] }
}

// Taps k...k + 3 of the reversed filter: tap k + m is v[3 - m].
@inline(always)
private func taps4(_ filter: Span<Float>, _ k: Int) -> V4 {
    load4(filter.extracting(droppingFirst: filter.count - k - 4).extracting(0..<4), 0)
}

// The three accumulators of one output vector of a 16-output block.
private struct Acc3 {
    var a = V4(), b = V4(), c = V4()
    @inline(always)
    var sum: V4 { (a + b) + c }
}

// Eight taps into one output vector of a 16-output block, `s(m)` the signal at the vector's output plus tap m.
@inline(always)
private func eightTaps(
    _ x: inout V4,
    _ y: inout V4,
    _ z: inout V4,
    _ w: Span<Float>,
    _ base: Int,
    _ t: Taps8,
    first: Bool,
    second: Bool
) {
    @inline(always)
    func s(_ m: Int) -> V4 { load4(w, base + m) }
    if first {
        x = s(0) * t.t0
        y = s(1) * t.t1
        z = s(2) * t.t2
    } else {
        x = fused(x, s(0), t.t0)
        y = fused(y, s(1), t.t1)
        z = fused(z, s(2), t.t2)
    }
    if second {
        x = fused(x, s(4), t.t4)
        y = fused(y, s(5), t.t5)
        z = fused(z, s(6), t.t6)
        x = fused(x, s(7), t.t7)
        y = fused(y, s(3), t.t3)
    } else {
        x = fused(x, s(3), t.t3)
        y = fused(y, s(4), t.t4)
        z = fused(z, s(5), t.t5)
        x = fused(x, s(6), t.t6)
        y = fused(y, s(7), t.t7)
    }
}

// One block of 16 outputs, all four output vectors in one pass over the taps (vDSP's register blocking: 12 accumulators).
@inline(always)
private func convolveBlock16(_ signal: Span<Float>, _ filter: Span<Float>, _ o: Int) -> (V4, V4, V4, V4) {
    let taps = filter.count
    var r0 = Acc3()
    var r1 = Acc3()
    var r2 = Acc3()
    var r3 = Acc3()
    var k = 0
    if taps >= 8 {
        do {
            let w = signal.extracting(droppingFirst: o).extracting(0..<23)
            let t = Taps8(filter, 0)
            eightTaps(&r0.c, &r0.a, &r0.b, w, 0, t, first: true, second: false)
            eightTaps(&r1.c, &r1.a, &r1.b, w, 4, t, first: true, second: true)
            eightTaps(&r2.c, &r2.a, &r2.b, w, 8, t, first: true, second: false)
            eightTaps(&r3.c, &r3.a, &r3.b, w, 12, t, first: true, second: false)
        }
        k = 8
        while taps - k >= 8 {
            let w = signal.extracting(droppingFirst: o + k).extracting(0..<23)
            let t = Taps8(filter, k)
            eightTaps(&r0.b, &r0.c, &r0.a, w, 0, t, first: false, second: false)
            eightTaps(&r1.b, &r1.c, &r1.a, w, 4, t, first: false, second: true)
            eightTaps(&r2.b, &r2.c, &r2.a, w, 8, t, first: false, second: false)
            eightTaps(&r3.b, &r3.c, &r3.a, w, 12, t, first: false, second: false)
            k += 8
        }
        if taps - k >= 4 {
            let w = signal.extracting(droppingFirst: o + k).extracting(0..<19)
            let t = taps4(filter, k)
            @inline(always)
            func four(_ r: inout Acc3, _ base: Int) {
                r.a = fused(r.a, load4(w, base), t[3])
                r.b = fused(r.b, load4(w, base + 1), t[2])
                r.a = fused(r.a, load4(w, base + 2), t[1])
                r.c = fused(r.c, load4(w, base + 3), t[0])
            }
            four(&r0, 0)
            four(&r1, 4)
            four(&r2, 8)
            four(&r3, 12)
            k += 4
        }
    } else if taps >= 4 {
        let w = signal.extracting(droppingFirst: o).extracting(0..<19)
        let t = taps4(filter, 0)
        @inline(always)
        func four(_ r: inout Acc3, _ base: Int) {
            r.a = load4(w, base) * t[3]
            r.b = load4(w, base + 1) * t[2]
            r.a = fused(r.a, load4(w, base + 2), t[1])
            r.c = load4(w, base + 3) * t[0]
        }
        four(&r0, 0)
        four(&r1, 4)
        four(&r2, 8)
        four(&r3, 12)
        k = 4
    }
    while k < taps {
        let w = signal.extracting(droppingFirst: o + k).extracting(0..<16)
        let t = filter[taps - 1 - k]
        r0.c = fused(r0.c, load4(w, 0), t)
        r1.c = fused(r1.c, load4(w, 4), t)
        r2.c = fused(r2.c, load4(w, 8), t)
        r3.c = fused(r3.c, load4(w, 12), t)
        k += 1
    }
    return (r0.sum, r1.sum, r2.sum, r3.sum)
}

// A 4-output block: tap i of each block of eight into accumulator i, the remaining taps after them; the output is
// (u0 + u1) + (u2 + u3).
@inline(always)
private func convolveVector4(_ signal: Span<Float>, _ filter: Span<Float>, _ o: Int) -> V4 {
    let taps = filter.count
    var u0 = V4()
    var u1 = V4()
    var u2 = V4()
    var u3 = V4()
    var k = 0
    if taps >= 8 {
        var w0: V4
        var w1: V4
        var w2: V4
        var w3: V4
        do {
            let w = signal.extracting(droppingFirst: o).extracting(0..<11)
            let t = Taps8(filter, 0)
            u0 = load4(w, 0) * t.t0
            u1 = load4(w, 1) * t.t1
            u2 = load4(w, 2) * t.t2
            u3 = load4(w, 3) * t.t3
            w0 = load4(w, 4) * t.t4
            w1 = load4(w, 5) * t.t5
            w2 = load4(w, 6) * t.t6
            w3 = load4(w, 7) * t.t7
        }
        k = 8
        while taps - k >= 8 {
            let w = signal.extracting(droppingFirst: o + k).extracting(0..<11)
            let t = Taps8(filter, k)
            u0 = fused(u0, load4(w, 0), t.t0)
            u1 = fused(u1, load4(w, 1), t.t1)
            u2 = fused(u2, load4(w, 2), t.t2)
            u3 = fused(u3, load4(w, 3), t.t3)
            w0 = fused(w0, load4(w, 4), t.t4)
            w1 = fused(w1, load4(w, 5), t.t5)
            w2 = fused(w2, load4(w, 6), t.t6)
            w3 = fused(w3, load4(w, 7), t.t7)
            k += 8
        }
        u0 = u0 + w0
        u1 = u1 + w1
        u2 = u2 + w2
        u3 = u3 + w3
        if taps - k >= 4 {
            let w = signal.extracting(droppingFirst: o + k).extracting(0..<7)
            let t = taps4(filter, k)
            u0 = fused(u0, load4(w, 0), t[3])
            u1 = fused(u1, load4(w, 1), t[2])
            u2 = fused(u2, load4(w, 2), t[1])
            u3 = fused(u3, load4(w, 3), t[0])
            k += 4
        }
    } else if taps >= 4 {
        let w = signal.extracting(droppingFirst: o).extracting(0..<7)
        let t = taps4(filter, 0)
        u0 = load4(w, 0) * t[3]
        u1 = load4(w, 1) * t[2]
        u2 = load4(w, 2) * t[1]
        u3 = load4(w, 3) * t[0]
        k = 4
    }
    while k < taps {
        u0 = fused(u0, load4(signal, o + k), filter[taps - 1 - k])
        k += 1
    }
    return (u0 + u1) + (u2 + u3)
}

// One output: two lane accumulators over each eight taps, then the remaining taps fused in one by one.
@inline(always)
private func convolveSingle(_ signal: Span<Float>, _ filter: Span<Float>, _ o: Int) -> Float {
    let taps = filter.count
    var sum: Float = 0
    var k = 0
    if taps >= 8 {
        var v0 = V4()
        var v1 = V4()
        while taps - k >= 8 {
            let w = signal.extracting(droppingFirst: o + k).extracting(0..<8)
            let t = Taps8(filter, k)
            v0 = fused(v0, load4(w, 0), V4(t.t0, t.t1, t.t2, t.t3))
            v1 = fused(v1, load4(w, 4), V4(t.t4, t.t5, t.t6, t.t7))
            k += 8
        }
        sum = pairwiseSum(v0 + v1)
    }
    while k < taps {
        sum = sum.addingProduct(signal[o + k], filter[taps - 1 - k])
        k += 1
    }
    return sum
}

extension VectorMathArithmetic.Cocoa {
    /// vDSP_svesq: its order does not depend on the input's alignment.
    @inline(always)
    static func sumOfSquares(_ input: Span<Float>, _ alignment: Int) -> Float {
        VDSPReductions.sumOfSquares(input)
    }

    /// vDSP_dotpr.
    @inline(always)
    static func dotProduct(_ input1: Span<Float>, _ input2: Span<Float>) -> Float {
        VDSPReductions.dotProduct(input1, input2)
    }

    /// vDSP_conv with the filter read backwards.
    @inline(always)
    static func convolve(_ signal: Span<Float>, _ filter: Span<Float>, _ output: inout MutableSpan<Float>) {
        VDSPReductions.convolve(signal, filter, &output)
    }

    /// vDSP_vdbcon with a reference of 1.
    @inline(always)
    static func linearToDecibels(_ input: Span<Float>?, _ n: Int, _ output: inout MutableSpan<Float>) {
        VDSPReductions.linearToDecibels(input, n, &output)
    }
}

// MARK: VectorMath entries

// Each function checks the sizes VectorMath's RELEASE_ASSERTs require; the loops' own bounds checks cover the rest.

@_expose(Cxx)
internal func vmMultiplyByScalarThenAddToOutput(_ input: AudioDSPSpanConstFloat, _ count: Int, _ scalar: Float, _ output: AudioDSPSpanFloat)
{
    let input = unsafe Span<Float>(_unsafeCxxSpan: input)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    VectorMathPlatform.multiplyByScalarThenAddToOutput(audioInputIsOutput(input, count) ? nil : input, count, scalar, &output)
}

@_expose(Cxx)
internal func vmAddVectorsThenMultiplyByScalar(
    _ input1: AudioDSPSpanConstFloat,
    _ input2: AudioDSPSpanConstFloat,
    _ scalar: Float,
    _ output: AudioDSPSpanFloat,
    _ count1: Int,
    _ count2: Int
) {
    let input1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let input2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    VectorMathPlatform.addVectorsThenMultiplyByScalar(
        audioInputIsOutput(input1, count1) ? nil : input1,
        count1,
        audioInputIsOutput(input2, count2) ? nil : input2,
        count2,
        scalar,
        &output
    )
}

@_expose(Cxx)
internal func vmMultiplyByScalar(_ input: AudioDSPSpanConstFloat, _ count: Int, _ scalar: Float, _ output: AudioDSPSpanFloat) {
    let input = unsafe Span<Float>(_unsafeCxxSpan: input)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    VectorMathPlatform.multiplyByScalar(audioInputIsOutput(input, count) ? nil : input, count, scalar, &output)
}

@_expose(Cxx)
internal func vmAddScalar(_ input: AudioDSPSpanConstFloat, _ count: Int, _ scalar: Float, _ output: AudioDSPSpanFloat) {
    let input = unsafe Span<Float>(_unsafeCxxSpan: input)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    VectorMathPlatform.addScalar(audioInputIsOutput(input, count) ? nil : input, count, scalar, &output)
}

/// VectorMath::substract: in2 - in1 on Cocoa, in1 - in2 elsewhere.
@_expose(Cxx)
internal func vmSubstract(
    _ input1: AudioDSPSpanConstFloat,
    _ input2: AudioDSPSpanConstFloat,
    _ output: AudioDSPSpanFloat,
    _ count1: Int,
    _ count2: Int
) {
    let input1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let input2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    VectorMathPlatform.substract(
        audioInputIsOutput(input1, count1) ? nil : input1,
        count1,
        audioInputIsOutput(input2, count2) ? nil : input2,
        count2,
        &output
    )
}

@_expose(Cxx)
internal func vmAddFloat(
    _ input1: AudioDSPSpanConstFloat,
    _ input2: AudioDSPSpanConstFloat,
    _ output: AudioDSPSpanFloat,
    _ count1: Int,
    _ count2: Int
) {
    let input1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let input2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    VectorMathPlatform.add(
        audioInputIsOutput(input1, count1) ? nil : input1,
        count1,
        audioInputIsOutput(input2, count2) ? nil : input2,
        count2,
        &output
    )
}

@_expose(Cxx)
internal func vmAddDouble(
    _ input1: AudioDSPSpanConstDouble,
    _ input2: AudioDSPSpanConstDouble,
    _ output: AudioDSPSpanDouble,
    _ count1: Int,
    _ count2: Int
) {
    let input1 = unsafe Span<Double>(_unsafeCxxSpan: input1)
    let input2 = unsafe Span<Double>(_unsafeCxxSpan: input2)
    var output = unsafe MutableSpan<Double>(_unsafeCxxSpan: output)
    VectorMathPlatform.add(
        audioInputIsOutput(input1, count1) ? nil : input1,
        count1,
        audioInputIsOutput(input2, count2) ? nil : input2,
        count2,
        &output
    )
}

@_expose(Cxx)
internal func vmMultiply(
    _ input1: AudioDSPSpanConstFloat,
    _ input2: AudioDSPSpanConstFloat,
    _ output: AudioDSPSpanFloat,
    _ count1: Int,
    _ count2: Int
) {
    let input1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let input2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    VectorMathPlatform.multiply(
        audioInputIsOutput(input1, count1) ? nil : input1,
        count1,
        audioInputIsOutput(input2, count2) ? nil : input2,
        count2,
        &output
    )
}

/// The largest magnitude in the input. `alignment` is the input's offset from a 16-byte boundary, in floats.
@_expose(Cxx)
internal func vmMaximumMagnitude(_ input: AudioDSPSpanConstFloat, _ alignment: Int) -> Float {
    let input = unsafe Span<Float>(_unsafeCxxSpan: input)
    return VectorMathPlatform.maximumMagnitude(input, alignment)
}

/// (realOut, imagOut) = (real1, imag1) * (real2, imag2). `simdAligned`: all six spans start on a 16-byte boundary.
///
/// `realOut` and `imagOut` overlap neither each other nor the other part's inputs.
@_expose(Cxx)
internal func vmMultiplyComplex(
    _ real1: AudioDSPSpanConstFloat,
    _ imag1: AudioDSPSpanConstFloat,
    _ real2: AudioDSPSpanConstFloat,
    _ imag2: AudioDSPSpanConstFloat,
    _ realOut: AudioDSPSpanFloat,
    _ imagOut: AudioDSPSpanFloat,
    _ real1Count: Int,
    _ imag1Count: Int,
    _ real2Count: Int,
    _ imag2Count: Int,
    _ simdAligned: Bool
) {
    let real1 = unsafe Span<Float>(_unsafeCxxSpan: real1)
    let imag1 = unsafe Span<Float>(_unsafeCxxSpan: imag1)
    let real2 = unsafe Span<Float>(_unsafeCxxSpan: real2)
    let imag2 = unsafe Span<Float>(_unsafeCxxSpan: imag2)
    var realOut = unsafe MutableSpan<Float>(_unsafeCxxSpan: realOut)
    var imagOut = unsafe MutableSpan<Float>(_unsafeCxxSpan: imagOut)
    let counts = VectorMathArithmetic.ComplexCounts(real1: real1Count, imag1: imag1Count, real2: real2Count, imag2: imag2Count)
    VectorMathPlatform.multiplyComplex(
        audioInputIsOutput(real1, real1Count) ? nil : real1,
        audioInputIsOutput(imag1, imag1Count) ? nil : imag1,
        audioInputIsOutput(real2, real2Count) ? nil : real2,
        audioInputIsOutput(imag2, imag2Count) ? nil : imag2,
        counts,
        &realOut,
        &imagOut,
        simdAligned
    )
}

@_expose(Cxx)
internal func vmClamp(_ input: AudioDSPSpanConstFloat, _ count: Int, _ minimum: Float, _ maximum: Float, _ output: AudioDSPSpanFloat) {
    let input = unsafe Span<Float>(_unsafeCxxSpan: input)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    VectorMathPlatform.clamp(audioInputIsOutput(input, count) ? nil : input, count, minimum, maximum, &output)
}

/// The sum of the squares of the input. `alignment` as vmMaximumMagnitude's.
@_expose(Cxx)
internal func vmSumOfSquares(_ input: AudioDSPSpanConstFloat, _ alignment: Int) -> Float {
    let input = unsafe Span<Float>(_unsafeCxxSpan: input)
    return VectorMathPlatform.sumOfSquares(input, alignment)
}

@_expose(Cxx)
internal func vmDotProduct(_ input1: AudioDSPSpanConstFloat, _ input2: AudioDSPSpanConstFloat) -> Float {
    let input1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let input2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    return VectorMathPlatform.dotProduct(input1, input2)
}

@_expose(Cxx)
internal func vmConvolve(_ signal: AudioDSPSpanConstFloat, _ filter: AudioDSPSpanConstFloat, _ output: AudioDSPSpanFloat) {
    let signal = unsafe Span<Float>(_unsafeCxxSpan: signal)
    let filter = unsafe Span<Float>(_unsafeCxxSpan: filter)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    VectorMathPlatform.convolve(signal, filter, &output)
}

/// out[i] = 20 * log10(in[i]), each port's log10.
@_expose(Cxx)
internal func vmLinearToDecibels(_ input: AudioDSPSpanConstFloat, _ count: Int, _ output: AudioDSPSpanFloat) {
    let input = unsafe Span<Float>(_unsafeCxxSpan: input)
    var output = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    VectorMathPlatform.linearToDecibels(audioInputIsOutput(input, count) ? nil : input, count, &output)
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

/// Clamps `input` (nil: the output, in place) into `output`, as clampExact does for every input; one pass of `x <= minimum`
/// then `> maximum` is exact unless a bound is NaN or -0; a block of 16 with a zero result takes clampExact.
@inline(always)
private func clampBlocks(
    _ input: Span<Float>?,
    _ n: Int,
    _ minimum: Float,
    _ maximum: Float,
    _ output: inout MutableSpan<Float>
) {
    var i = 0
    if !minimum.isNaN && !maximum.isNaN && !(minimum == 0 && minimum.sign == .minus) && !(maximum == 0 && maximum.sign == .minus) {
        precondition(output.count >= n)
        if let input {
            for j in 0..<n {
                let x = input[j]
                let lowered = x <= minimum ? minimum : x
                output[j] = lowered > maximum ? maximum : lowered
            }
        } else {
            for j in 0..<n {
                let x = output[j]
                let lowered = x <= minimum ? minimum : x
                output[j] = lowered > maximum ? maximum : lowered
            }
        }
        return
    }
    if !minimum.isNaN && !maximum.isNaN {
        while i + 16 <= n {
            let smallest: UInt32
            if let input {
                smallest = smallestMagnitude(input, i, minimum, maximum)
            } else {
                smallest = smallestMagnitude(output.span, i, minimum, maximum)
            }
            if smallest != 0 {
                precondition(output.count >= i + 16)
                if let input {
                    let block = input.extracting(i..<i + 16)
                    precondition(block.count == 16)
                    for j in 0..<16 {
                        let x = block[j]
                        let lowered = x < minimum ? minimum : x
                        output[i + j] = lowered > maximum ? maximum : lowered
                    }
                } else {
                    for j in 0..<16 {
                        let x = output[i + j]
                        let lowered = x < minimum ? minimum : x
                        output[i + j] = lowered > maximum ? maximum : lowered
                    }
                }
            } else {
                precondition(output.count >= i + 16)
                if let input {
                    let block = input.extracting(i..<i + 16)
                    precondition(block.count == 16)
                    for j in 0..<16 { output[i + j] = clampExact(block[j], minimum, maximum) }
                } else {
                    for j in 0..<16 { output[i + j] = clampExact(output[i + j], minimum, maximum) }
                }
            }
            i += 16
        }
    }
    while i < n {
        let x: Float
        if let input { x = input[i] } else { x = output[i] }
        let lowered = x < minimum ? minimum : x
        let result = lowered > maximum ? maximum : lowered
        let comparisonFormIsExact = !minimum.isNaN && !maximum.isNaN && result != 0
        output[i] = comparisonFormIsExact ? result : clampExact(x, minimum, maximum)
        i += 1
    }
}

/// out[i] = in1[i] + in2[i], wrapping as vDSP_vaddi does.
@_expose(Cxx)
internal func vmAddInt(
    _ input1: AudioDSPSpanConstInt,
    _ input2: AudioDSPSpanConstInt,
    _ output: AudioDSPSpanInt,
    _ count1: Int,
    _ count2: Int
) {
    let input1 = unsafe Span<Int32>(_unsafeCxxSpan: input1)
    let input2 = unsafe Span<Int32>(_unsafeCxxSpan: input2)
    var output = unsafe MutableSpan<Int32>(_unsafeCxxSpan: output)
    combineElements(
        audioInputIsOutput(input1, count1) ? nil : input1,
        count1,
        audioInputIsOutput(input2, count2) ? nil : input2,
        count2,
        &output
    ) { $0 &+ $1 }
}

// MARK: - ZeroPole

// First-order filter with a zero and a pole and a gain that makes 0 dB at 0 Hz, over the first n frames of `source`
// (nil: of the destination, in place). The state goes in as scalars and comes back through the inout parameters.
@inline(always)
private func zeroPoleFilter(
    _ source: Span<Float>?,
    _ destination: inout MutableSpan<Float>,
    _ n: Int,
    _ zero: Float,
    _ pole: Float,
    _ lastX: Float,
    _ lastY: Float,
    _ outLastX: inout Float,
    _ outLastY: inout Float
) {
    precondition(destination.count >= n)
    let k1 = 1.0 / (1.0 - zero)
    let k2 = 1.0 - pole
    var lx = lastX
    var ly = lastY
    @inline(always)
    func step(_ inp: Float) -> Float {
        // k1 * (inp - zero * lx) and k2 * out1 + pole * ly, contracted as Clang contracts them.
        let out1 = k1 * inp.addingContractedProduct(-zero, lx)
        lx = inp
        let out2 = (pole * ly).addingContractedProduct(k2, out1)
        ly = out2
        return out2
    }
    if let source {
        precondition(source.count >= n)
        for i in 0..<n { destination[i] = step(source[i]) }
    } else {
        for i in 0..<n { destination[i] = step(destination[i]) }
    }
    outLastX = flushDenormalFloat(lx)
    outLastY = flushDenormalFloat(ly)
}

/// ZeroPole::process where `source` and `destination` are different buffers.
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
    zeroPoleFilter(
        audioInputIsOutput(source, n) ? nil : source,
        &destination,
        n,
        zero,
        pole,
        lastX,
        lastY,
        &outLastX,
        &outLastY
    )
}

// MARK: - EqualPowerPanner

private let kPiOverTwo = Double.pi / 2.0

// dst = src * gain (multiplyByScalar) and dst = other + src * gain (multiplyByScalarThenAddToVector), each run to the end
// of the block before the next starts. The sources are the input bus and the destinations the output bus: separate storage.
@inline(always)
private func scale(_ source: Span<Float>, _ gain: Float, _ destination: inout MutableSpan<Float>, _ n: Int) {
    precondition(source.count >= n)
    precondition(destination.count >= n)
    VectorMathPlatform.multiplyByScalar(source.extracting(0..<n), n, gain, &destination)
}

@inline(always)
private func scaleAndAdd(
    _ source: Span<Float>,
    _ gain: Float,
    _ other: Span<Float>,
    _ destination: inout MutableSpan<Float>,
    _ n: Int
) {
    VectorMathPlatform.multiplyByScalarThenAddToVector(source, gain, other, &destination, n)
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
    // n = 0 still reaches the variants' length checks.
    guard n >= 0 else { return }
    // Lower bound -180 then upper bound 180; a NaN becomes -180.
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
    // Every span is indexed up to n; the second source only for a stereo source.
    precondition(n <= azimuths.count && n <= srcL.count && n <= dstL.count && n <= dstR.count)
    precondition(nCh == 1 || n <= srcR.count)
    for k in 0..<n {
        let raw = azimuths[k]
        // Clamp to [-180, 180]; a NaN stays a NaN.
        var az = raw < -180 ? -180 : (180 < raw ? 180 : raw)
        if az < -90 { az = -180 - az } else if az > 90 { az = 180 - az }
        let pos = nCh == 1 ? (az + 90) / 180 : (az <= 0 ? (az + 90) / 90 : az / 90)
        let gLD = cos(kPiOverTwo * pos)
        let gRD = sin(kPiOverTwo * pos)
        if nCh == 1 {
            let l = Double(srcL[k])
            dstL[k] = Float(l * gLD)
            dstR[k] = Float(l * gRD)
        } else if raw <= 0 { // branches on the unclamped azimuth
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
        // Double gains: Float(Double(input) * gain).
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
    // n = 0 still reaches the variants' length checks.
    guard n >= 0 else { return }
    let srcL = unsafe Span<Float>(_unsafeCxxSpan: srcL)
    let srcR = unsafe Span<Float>(_unsafeCxxSpan: srcR)
    var dstL = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstL)
    var dstR = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstR)
    let nCh = Int(nInputChannels)
    // The clamped value is narrowed to float, so `pan + 1` is a float addition.
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

// Clang's -ffp-contract=on fuses `a * b + c` where the target's baseline has an FMA (arm64, not WebCore's x86_64).
// Used where the arithmetic must match what Clang compiles on every port.
extension FloatingPoint {
    // self + lhs * rhs: one fused multiply-add on arm64, two roundings elsewhere, as Clang compiles `c + a * b`.
    @inline(always)
    func addingContractedProduct(_ lhs: Self, _ rhs: Self) -> Self {
        #if arch(arm64)
        return addingProduct(lhs, rhs)
        #else
        return self + lhs * rhs
        #endif
    }
}

extension Swift.SIMD where Scalar: FloatingPoint {
    // Lane-wise self + lhs * rhs, fused where Clang's -ffp-contract=on fuses the scalar form: arm64 only. Spelled
    // Swift.SIMD because WTF's SIMD namespace is in scope.
    @inline(always)
    func addingContractedProduct(_ lhs: Self, _ rhs: Self) -> Self {
        #if arch(arm64)
        return addingProduct(lhs, rhs)
        #else
        return self + lhs * rhs
        #endif
    }
}

// AudioUtilities::flushDenormalFloatToZero: the value as is on x86 (SSE), else subnormals (abs < FLT_MIN) become zero.
@inline(always)
internal func flushDenormalFloat(_ x: Float) -> Float {
    #if arch(x86_64) || arch(i386)
    x
    #else
    x.magnitude < Float.leastNormalMagnitude ? 0 : x
    #endif
}

// MARK: - SincResampler

// SincResampler's kernel size, and the number of sub-sample offsets it has kernels for.
private let sincKernelSize = 32
private let sincNumberOfKernelOffsets = 32

// The render quantum size, the request size of processBuffer.
private let sincProcessBufferRequestFrames = 128

extension VectorMathArithmetic.Cocoa {
    /// Two dot products of the kernel size (vDSP_dotpr), interpolated as clang contracts
    /// `(1 - f) * sum1 + f * sum2`: the second product rounded, the first fused into it.
    @inline(always)
    static func sincConvolve(_ input: Span<Float>, _ k1: Span<Float>, _ k2: Span<Float>, _ f: Float) -> Float {
        let sum1 = VDSPReductions.dotProduct(input, k1)
        let sum2 = VDSPReductions.dotProduct(input, k2)
        return (f * sum2).addingProduct(1 - f, sum1)
    }
}

extension VectorMathArithmetic.ARM64 {
    /// The plain loop's two sums, each as dotProduct's, interpolated as on Cocoa.
    @inline(always)
    static func sincConvolve(_ input: Span<Float>, _ k1: Span<Float>, _ k2: Span<Float>, _ f: Float) -> Float {
        let sum1 = dotProduct(input, k1)
        let sum2 = dotProduct(input, k2)
        return (f * sum2).addingProduct(1 - f, sum1)
    }
}

extension VectorMathArithmetic.SSE2 {
    /// Four lane sums of each kernel from 0, scaled by 1 - f and f and added, then
    /// (l0 + l2) + (l1 + l3); nothing fuses.
    @inline(always)
    static func sincConvolve(_ input: Span<Float>, _ k1: Span<Float>, _ k2: Span<Float>, _ f: Float) -> Float {
        var sums1 = SIMD4<Float>(repeating: 0)
        var sums2 = SIMD4<Float>(repeating: 0)
        var i = 0
        while i < sincKernelSize {
            let x = four(input, i)
            sums1 = sums1 + x * four(k1, i)
            sums2 = sums2 + x * four(k2, i)
            i += 4
        }
        sums1 = sums1 * SIMD4(repeating: 1 - f)
        sums2 = sums2 * SIMD4(repeating: f)
        sums1 = sums1 + sums2
        return (sums1[2] + sums1[0]) + (sums1[3] + sums1[1])
    }
}

/// The state of a SincResampler: its windowed-sinc kernels, its position in the source and the regions of its input
/// buffer (requestFrames + kernel size frames): r1 and r2 the first and next half kernels, r0 where each request is
/// read (sincKernelSize / 2, then sincKernelSize), r3 a kernel's width before r0's end.
@_expose(Cxx)
public struct SincResamplerKernel {
    private var kernelStorage: [Float]
    private let scaleFactor: Double
    private let requestFrames: Int
    private var virtualSourceIndex: Double = 0
    private var r0 = 0
    private var r3 = 0
    private var blockSize = 0
    private(set) var chunkSize: UInt = 0
    private var isBufferPrimed = false
    // Where a call that stopped for input resumes in its destination.
    private var resumeIndex = 0

    init(scaleFactor: Double, requestFrames: Int) {
        // The regions below need a request of at least a kernel.
        precondition(requestFrames >= sincKernelSize)
        self.scaleFactor = scaleFactor
        self.requestFrames = requestFrames
        kernelStorage = sincKernels(scaleFactor)
        updateRegions(isSecondLoad: false)
    }

    var inputOffset: Int { r0 }

    private mutating func updateRegions(isSecondLoad: Bool) {
        // On the second load r0 slides right by half a kernel.
        r0 = isSecondLoad ? sincKernelSize : sincKernelSize / 2
        r3 = r0 + requestFrames - sincKernelSize
        let r4 = r0 + requestFrames - sincKernelSize / 2
        blockSize = r4 - sincKernelSize / 2
        chunkSize = sincChunkSize(Double(blockSize) / scaleFactor)
    }

    /// Fills `destination`; returns true when it needs the next request read into the buffer at inputOffset, to be
    /// called again with the same destination; false when the destination is full.
    mutating func process(_ buffer: inout MutableSpan<Float>, _ destination: inout MutableSpan<Float>) -> Bool {
        precondition(buffer.count == requestFrames + sincKernelSize)
        if !isBufferPrimed {
            isBufferPrimed = true
            return true
        }
        let count = destination.count
        var index = resumeIndex
        resumeIndex = 0
        if index == count { return false }
        // The position is a local while the loop reads the kernels, which are part of self.
        var position = virtualSourceIndex
        let filled = Self.resample(kernelStorage.span, scaleFactor, Double(blockSize), &position, buffer.span, &destination, index)
        virtualSourceIndex = position
        if filled == count { return false }
        index = filled
        virtualSourceIndex -= Double(blockSize)
        // Copy r3 to r1: the last input frames wrap to the start of the buffer.
        for j in 0..<sincKernelSize { buffer[j] = buffer[r3 + j] }
        if r0 == sincKernelSize / 2 { updateRegions(isSecondLoad: true) }
        resumeIndex = index
        return true
    }

    /// Output frames from `index` while the position is inside the block; returns the index it stopped at: the
    /// destination's count, or where the position left the block.
    @inline(always)
    private static func resample(
        _ kernels: Span<Float>,
        _ scaleFactor: Double,
        _ blockSize: Double,
        _ virtualSourceIndex: inout Double,
        _ buffer: Span<Float>,
        _ destination: inout MutableSpan<Float>,
        _ start: Int
    ) -> Int {
        let count = destination.count
        var index = start
        while virtualSourceIndex < blockSize {
            // virtualSourceIndex lies between two kernel offsets.
            let sourceIndex = Int(virtualSourceIndex)
            let subsampleRemainder = virtualSourceIndex - Double(sourceIndex)
            let virtualOffsetIndex = subsampleRemainder * Double(sincNumberOfKernelOffsets)
            let offsetIndex = Int(virtualOffsetIndex)
            let k1 = kernels.extracting(droppingFirst: offsetIndex * sincKernelSize).extracting(0..<sincKernelSize)
            let k2 = kernels.extracting(droppingFirst: (offsetIndex + 1) * sincKernelSize).extracting(0..<sincKernelSize)
            let input = buffer.extracting(droppingFirst: sourceIndex).extracting(0..<sincKernelSize)
            let kernelInterpolationFactor = Float(virtualOffsetIndex - Double(offsetIndex))
            destination[index] = VectorMathPlatform.sincConvolve(input, k1, k2, kernelInterpolationFactor)
            index += 1
            virtualSourceIndex += scaleFactor
            if index == count { break }
        }
        return index
    }
}

// The quotient as a size_t, converted as arm64 converts it where the conversion is undefined: a scale factor of 0 (a
// media element paused at playback rate 0) gives infinity, which saturates; NaN and negative quotients give 0.
@inline(always)
private func sincChunkSize(_ quotient: Double) -> UInt {
    if !(quotient > 0) { return 0 }
    return quotient >= 0x1p64 ? UInt.max : UInt(quotient)
}

/// The windowed-sinc kernels for sub-sample offsets 0 to 1, back to back: sincNumberOfKernelOffsets + 1 kernels of
/// sincKernelSize; in double, then rounded to float; Clang contracts the window's last
/// product on arm64.
private func sincKernels(_ scaleFactor: Double) -> [Float] {
    let alpha = 0.16
    let a0 = 0.5 * (1.0 - alpha)
    let a1 = 0.5
    let a2 = 0.5 * alpha
    // The normalized cutoff frequency of the low-pass filter, lowered slightly to avoid aliasing at the very high end.
    var sincScaleFactor = scaleFactor > 1.0 ? 1.0 / scaleFactor : 1.0
    sincScaleFactor *= 0.9
    let n = sincKernelSize
    let halfSize = n / 2
    var storage = [Float](repeating: 0, count: n * (sincNumberOfKernelOffsets + 1))
    var span = storage.mutableSpan
    for offsetIndex in 0...sincNumberOfKernelOffsets {
        let subsampleOffset = Double(offsetIndex) / Double(sincNumberOfKernelOffsets)
        for i in 0..<n {
            let s = sincScaleFactor * Double.pi * (Double(i - halfSize) - subsampleOffset)
            var sinc = s == 0 ? 1.0 : sin(s) / s
            sinc *= sincScaleFactor
            let x = (Double(i) - subsampleOffset) / Double(n)
            let window = (a0 - a1 * cos(2.0 * Double.pi * x)).addingContractedProduct(a2, cos(4.0 * Double.pi * x))
            span[i + offsetIndex * n] = Float(sinc * window)
        }
    }
    return storage
}

/// Creates the state of a SincResampler with the given scale factor (source rate over destination rate) and request
/// size.
@_expose(Cxx)
public func makeSincResamplerKernel(_ scaleFactor: Double, _ requestFrames: Int) -> SincResamplerKernel {
    SincResamplerKernel(scaleFactor: scaleFactor, requestFrames: requestFrames)
}

/// The number of destination frames one request of input produces.
@_expose(Cxx)
public func sincResamplerChunkSize(_ kernel: borrowing SincResamplerKernel) -> UInt {
    kernel.chunkSize
}

/// Where in the input buffer the next request is read.
@_expose(Cxx)
public func sincResamplerInputOffset(_ kernel: borrowing SincResamplerKernel) -> Int {
    kernel.inputOffset
}

/// Resamples into `destination`; returns true when the caller must read the next request into `inputBuffer` at
/// sincResamplerInputOffset and call again with the same destination.
@_expose(Cxx)
internal func sincResamplerProcess(
    _ kernel: inout SincResamplerKernel,
    _ inputBuffer: AudioDSPSpanFloat,
    _ destination: AudioDSPSpanFloat
) -> Bool {
    var buffer = unsafe MutableSpan<Float>(_unsafeCxxSpan: inputBuffer)
    var destination = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    return kernel.process(&buffer, &destination)
}

/// Resamples all of `source` into `destination`, which holds source.count / scaleFactor frames, reading it a render
/// quantum at a time and zero-padding past its end.
@_expose(Cxx)
internal func sincResamplerProcessBuffer(_ source: AudioDSPSpanConstFloat, _ destination: AudioDSPSpanFloat, _ scaleFactor: Double) {
    let source = unsafe Span<Float>(_unsafeCxxSpan: source)
    var destination = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    precondition(destination.count == Int(Double(source.count) / scaleFactor))
    let requestFrames = sincProcessBufferRequestFrames
    var kernel = SincResamplerKernel(scaleFactor: scaleFactor, requestFrames: requestFrames)
    var storage = [Float](repeating: 0, count: requestFrames + sincKernelSize)
    var buffer = storage.mutableSpan
    var consumed = 0
    while kernel.process(&buffer, &destination) {
        // Copy what is left of the source, up to a request, and zero-pad the rest of the request.
        let offset = kernel.inputOffset
        let framesToCopy = min(source.count - consumed, requestFrames)
        for j in 0..<framesToCopy { buffer[offset + j] = source[consumed + j] }
        for j in framesToCopy..<requestFrames { buffer[offset + j] = 0 }
        consumed += framesToCopy
    }
}

// MARK: - DirectConvolver

/// DirectConvolver::process: convolves `source` with `kernel`, the previous block as history. `buffer` holds two
/// blocks, the previous one first; `destination` holds a block.
@_expose(Cxx)
internal func directConvolverProcess(
    _ kernel: AudioDSPSpanConstFloat,
    _ buffer: AudioDSPSpanFloat,
    _ source: AudioDSPSpanConstFloat,
    _ destination: AudioDSPSpanFloat
) {
    let kernel = unsafe Span<Float>(_unsafeCxxSpan: kernel)
    var buffer = unsafe MutableSpan<Float>(_unsafeCxxSpan: buffer)
    let source = unsafe Span<Float>(_unsafeCxxSpan: source)
    var destination = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    directConvolve(kernel, &buffer, source, &destination)
}

/// DirectConvolver's block: convolves `source` with `kernel`, the previous block as history. `buffer` holds two
/// blocks, the previous one first; `destination` holds a block: DirectConvolver and WaveShaper's samplers use it.
@inline(always)
internal func directConvolve(
    _ kernel: Span<Float>,
    _ buffer: inout MutableSpan<Float>,
    _ source: Span<Float>,
    _ destination: inout MutableSpan<Float>
) {
    let blockSize = source.count
    precondition(buffer.count == 2 * blockSize)
    precondition(kernel.count <= blockSize)
    for i in 0..<blockSize { buffer[blockSize + i] = source[i] }
    VectorMathPlatform.convolve(buffer.span.extracting(droppingFirst: blockSize - kernel.count + 1), kernel, &destination)
    for i in 0..<blockSize { buffer[i] = buffer[blockSize + i] }
}
