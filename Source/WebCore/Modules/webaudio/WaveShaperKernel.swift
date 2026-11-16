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

// WaveShaperDSPKernel's processing, with the up- and down-samplers its oversampling uses. WaveShaperProcessor owns the
// curve and holds its lock while a kernel processes, so each call receives the curve as a span. The samplers and their
// buffers are allocated when oversampling is first enabled and kept from then on. Multiply-adds are fused where
// Clang's -ffp-contract=on fuses them (addingContractedProduct).
//
// FIXME: (rdar://186723514) Receiving a std::span safely.
// Each @_expose(Cxx) function views its std::span parameters through Span(_unsafeCxxSpan:). The C++ caller owns every
// buffer, allocated at its length for the call; nothing else writes one during it (the Swift calls no C++) or reads an
// output; the elements have no invalid bit patterns; and no input overlaps an output (an input that is the output comes
// as an empty span, see inputUnlessOutput).

internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
// These imports make the operators JavaScriptCore declares visible before WebCore's C++ operators are
// (rdar://192229293).
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
public import WebCore_Private.AudioDSPBoundaryTypes
internal import wtf.Core.Stopwatch

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - Convolution

/// DirectConvolver, holding its history in place: convolves each block of `blockSize` frames with a kernel of at most
/// `blockSize` taps. `bufferSize` is `2 * blockSize`.
struct WaveShaperBlockConvolver<let blockSize: Int, let bufferSize: Int>: ~Copyable {
    private var buffer = [bufferSize of Float](repeating: 0)

    init() {
        precondition(bufferSize == 2 * blockSize)
    }

    /// `destination` holds `source.count` frames; a source that is not one block, or a kernel longer than one, does
    /// nothing.
    @inline(always)
    mutating func process(kernel: Span<Float>, source: Span<Float>, destination: inout MutableSpan<Float>) {
        guard source.count == blockSize, kernel.count <= blockSize else {
            return
        }
        var history = buffer.mutableSpan
        directConvolve(kernel, &history, source, &destination)
    }

    mutating func reset() {
        buffer = [bufferSize of Float](repeating: 0)
    }
}

/// Blackman window parameters, as both samplers compute them.
private let blackmanAlpha = 0.16
private let blackmanA0 = 0.5 * (1.0 - blackmanAlpha)
private let blackmanA1 = 0.5
private let blackmanA2 = 0.5 * blackmanAlpha

/// a0 - a1 * cos(2 pi x) + a2 * cos(4 pi x), contracted as Clang contracts it.
@inline(always)
private func blackmanWindow(_ x: Double) -> Double {
    let c2 = cos(4.0 * Double.pi * x)
    let c1 = cos(2.0 * Double.pi * x)
    return blackmanA0.addingContractedProduct(-blackmanA1, c1).addingContractedProduct(blackmanA2, c2)
}

// MARK: - Up-sampler

/// The windowed-sinc kernel size of the up-sampler.
private let waveShaperUpSamplerKernelSize = 128

/// Up-samples by 2x; the even output frames are the source delayed by half the kernel; the odd ones are the source
/// convolved with a sinc offset by half a frame. `bufferSize` is `2 * blockSize`.
struct WaveShaperUpSampler<let blockSize: Int, let bufferSize: Int>: ~Copyable {
    private var kernel = [128 of Float](repeating: 0)
    private var convolver = WaveShaperBlockConvolver<blockSize, bufferSize>()
    private var tempBuffer = [blockSize of Float](repeating: 0)
    // Delay line for the even output frames, matching the linear phase delay of the kernel.
    private var inputBuffer = [bufferSize of Float](repeating: 0)

    init() {
        precondition(bufferSize == 2 * blockSize && kernel.count == waveShaperUpSamplerKernelSize)
        let n = kernel.count
        let halfSize = n / 2
        let subsampleOffset = -0.5
        var kernelSpan = kernel.mutableSpan
        for i in 0..<n {
            // Compute the sinc() with offset.
            let s = Double.pi * (Double(i - halfSize) - subsampleOffset)
            let sinc = s == 0 ? 1.0 : sin(s) / s
            // Window the sinc() function, the window matching its offset.
            kernelSpan[i] = Float(sinc * blackmanWindow((Double(i) - subsampleOffset) / Double(n)))
        }
    }

    /// `destination` has room for `2 * source.count` frames; a source that is not one block does nothing.
    @inline(always)
    mutating func process(_ source: Span<Float>, _ destination: inout MutableSpan<Float>) {
        guard source.count == blockSize else {
            return
        }
        let halfSize = waveShaperUpSamplerKernelSize / 2
        guard halfSize <= blockSize else {
            return
        }
        var input = inputBuffer.mutableSpan

        for i in 0..<blockSize {
            input[blockSize + i] = source[i]
        }

        // Copy even sample-frames 0,2,4,6... (delayed by the linear phase delay) directly into destination.
        for i in 0..<blockSize {
            destination[i * 2] = input[blockSize - halfSize + i]
        }

        // Compute odd sample-frames 1,3,5,7...
        var oddSamples = tempBuffer.mutableSpan
        convolver.process(kernel: kernel.span, source: source, destination: &oddSamples)
        for i in 0..<blockSize {
            destination[i * 2 + 1] = oddSamples[i]
        }

        for i in 0..<blockSize {
            input[i] = input[blockSize + i]
        }
    }

    mutating func reset() {
        convolver.reset()
        inputBuffer = [bufferSize of Float](repeating: 0)
    }

    /// The kernel is linear phase, so its delay is at its centre.
    static var latencyFrames: Int { waveShaperUpSamplerKernelSize / 2 }
}

// MARK: - Down-sampler

/// The half-band kernel size of the down-sampler; only its odd taps, half of them, are stored.
private let waveShaperDownSamplerKernelSize = 256

/// Down-samples by 2x through a half-band filter. `halfBlockSize` is `blockSize / 2` and `bufferSize` `2 * blockSize`.
struct WaveShaperDownSampler<let halfBlockSize: Int, let blockSize: Int, let bufferSize: Int>: ~Copyable {
    // The odd taps. The even ones are zero except the centre, 0.5, which `process` applies as a delay line.
    private var reducedKernel = [128 of Float](repeating: 0)
    // Runs at half the source sample-rate.
    private var convolver = WaveShaperBlockConvolver<halfBlockSize, blockSize>()
    private var tempBuffer = [halfBlockSize of Float](repeating: 0)
    // The convolver's output, before the centre tap is added.
    private var convolved = [halfBlockSize of Float](repeating: 0)
    // Delay line (FIR filter history) for the centre tap.
    private var inputBuffer = [bufferSize of Float](repeating: 0)

    init() {
        precondition(2 * halfBlockSize == blockSize && bufferSize == 2 * blockSize)
        precondition(2 * reducedKernel.count == waveShaperDownSamplerKernelSize)
        let n = waveShaperDownSamplerKernelSize
        let halfSize = n / 2
        // Half-band filter.
        let sincScaleFactor = 0.5
        var kernelSpan = reducedKernel.mutableSpan
        // Compute only the odd terms because the even ones are zero, except right in the middle at halfSize.
        for i in stride(from: 1, to: n, by: 2) {
            // Compute the sinc() with offset.
            let s = sincScaleFactor * Double.pi * Double(i - halfSize)
            var sinc = s == 0 ? 1.0 : sin(s) / s
            sinc *= sincScaleFactor
            // Window the sinc() function, storing only the odd terms: shifted forward in time by one frame at the
            // destination sample-rate.
            kernelSpan[(i - 1) / 2] = Float(sinc * blackmanWindow(Double(i) / Double(n)))
        }
    }

    /// `destination` has room for `source.count / 2` frames; a source that is not one block does nothing.
    @inline(always)
    mutating func process(_ source: Span<Float>, _ destination: inout MutableSpan<Float>) {
        guard source.count == blockSize else {
            return
        }
        let halfSize = waveShaperDownSamplerKernelSize / 2
        guard halfSize <= blockSize else {
            return
        }
        var input = inputBuffer.mutableSpan

        for i in 0..<blockSize {
            input[blockSize + i] = source[i]
        }

        // Copy the odd sample-frames from source, delayed by one sample-frame (destination sample-rate) to match
        // shifting forward in time in reducedKernel.
        var oddSamples = tempBuffer.mutableSpan
        for i in 0..<halfBlockSize {
            oddSamples[i] = input[blockSize - 1 + i * 2]
        }

        // Actually process oddSamples with reducedKernel for efficiency. The theoretical kernel is double this size
        // with 0 values for even terms (except center).
        var output = convolved.mutableSpan
        convolver.process(kernel: reducedKernel.span, source: oddSamples.span, destination: &output)

        // Now, account for the 0.5 term right in the middle of the kernel: a delay line of halfSize source frames,
        // scaled by 0.5, computed in double.
        for i in 0..<halfBlockSize {
            let delayed = Double(input[blockSize - halfSize + i * 2])
            destination[i] = Float(Double(output[i]).addingContractedProduct(0.5, delayed))
        }

        for i in 0..<blockSize {
            input[i] = input[blockSize + i]
        }
    }

    mutating func reset() {
        convolver.reset()
        inputBuffer = [bufferSize of Float](repeating: 0)
    }

    /// Half the reduced kernel, at the destination sample-rate.
    static var latencyFrames: Int { waveShaperDownSamplerKernelSize / 2 / 2 }
}

// MARK: - Wave shaping

/// The frames of one render quantum (AudioUtilities::renderQuantumSize), which oversampling requires.
private let waveShaperRenderQuantumSize = 128

/// The oversampling modes, with the values of WaveShaperProcessor::OverSampleType (a static_assert checks them).
private enum WaveShaperOverSample: UInt8 {
    case none = 0
    case twice = 1
    case fourTimes = 2
}

/// The curve value for one input frame.
@inline(always)
private func waveShaperCurveValue(_ input: Float, _ curve: Span<Float>) -> Float {
    if !input.isFinite {
        return 0
    }
    // Clamp the input to [-1, 1].
    let clampedInput: Float = input < -1 ? -1 : (1 < input ? 1 : input)
    // The size less one is converted to float, also in the comparisons below.
    let last = Float(curve.count - 1)
    let v = last * 0.5 * (clampedInput + 1)
    if v < 0 {
        return curve[0]
    }
    if v >= last {
        return curve[curve.count - 1]
    }
    let k = v.rounded(.down)
    let f = v - k
    // v is in [0, last) and last is below 2^52 for any curve that can exist, so Double(k) + 2^52 is exact and its low 52
    // bits are k: kIndex == Int(k) without Int(_:)'s range check. The mask also bounds kIndex, so kIndex + 1 cannot overflow.
    let kIndex = Int(truncatingIfNeeded: (Double(k) + 0x1p52).bitPattern & 0xF_FFFF_FFFF_FFFF)
    return (f * curve[kIndex + 1]).addingContractedProduct(1 - f, curve[kIndex])
}

/// The constants of the four-frame curve stage, for a curve of 2 to 2^23 + 1 points.
private struct WaveShaperCurve4 {
    // The size less one, converted to float as in waveShaperCurveValue, and its half.
    let last: SIMD4<Float>
    let halfLast: SIMD4<Float>
    // The last index k may take, so that k + 1 is in the curve: the size less two.
    let maxIndex: SIMD4<UInt32>
    let lastValue: SIMD4<Float>

    init(_ curve: Span<Float>) {
        let last = Float(curve.count - 1)
        self.last = SIMD4(repeating: last)
        halfLast = SIMD4(repeating: last * 0.5)
        maxIndex = SIMD4(repeating: UInt32(truncatingIfNeeded: curve.count - 2))
        lastValue = SIMD4(repeating: curve[curve.count - 1])
    }

    /// Whether the stage computes what waveShaperCurveValue computes for this curve: its whole indices are below 2^23.
    static func applies(_ curve: Span<Float>) -> Bool {
        curve.count >= 2 && curve.count <= (1 << 23) + 1
    }

    /// waveShaperCurveValue for four frames, lane by lane, without branches.
    ///
    /// A non-finite lane gives 0 and v >= last the last point; the rest
    /// interpolate with the scalar arithmetic in its order. Every lane reads the curve at an index clamped to the size
    /// less two, so a replaced lane reads in bounds.
    @inline(always)
    func values(_ x: SIMD4<Float>, _ curve: Span<Float>) -> SIMD4<Float> {
        // Clamp the input to [-1, 1], NaN kept.
        var clamped = x.replacing(with: -1, where: x .< -1)
        clamped = clamped.replacing(with: 1, where: 1 .< x)
        let v = halfLast * (clamped + 1)
        let k = v.rounded(.down)
        let f = v - k
        let biased = bitCast(k + SIMD4(repeating: 0x1p23), to: SIMD4<UInt32>.self) & 0x7F_FFFF
        let index = pointwiseMin(biased, maxIndex)
        let p0 = curve.bytes.load(fromByteOffset: Int(index[0]) &* 4, as: SIMD2<Float>.self)
        let p1 = curve.bytes.load(fromByteOffset: Int(index[1]) &* 4, as: SIMD2<Float>.self)
        let p2 = curve.bytes.load(fromByteOffset: Int(index[2]) &* 4, as: SIMD2<Float>.self)
        let p3 = curve.bytes.load(fromByteOffset: Int(index[3]) &* 4, as: SIMD2<Float>.self)
        let c0 = SIMD4(p0[0], p1[0], p2[0], p3[0])
        let c1 = SIMD4(p0[1], p1[1], p2[1], p3[1])
        // (f * curve[k + 1]).addingContractedProduct(1 - f, curve[k]), lane by lane, operands in the same order so that
        // a NaN propagates as it does there: fused on arm64, two roundings elsewhere.
        #if arch(arm64)
        var result = (f * c1).addingProduct(1 - f, c0)
        #else
        var result = f * c1 + (1 - f) * c0
        #endif
        result = result.replacing(with: lastValue, where: v .>= last)
        // Not finite: every exponent bit set.
        let finite = bitCast(x, to: SIMD4<UInt32>.self) & 0x7FFF_FFFF .< 0x7F80_0000
        return result.replacing(with: 0, where: .!finite)
    }
}

/// The curve over the first `frames` frames of `source` into `destination`, four at a time; returns how many frames it
/// did (a multiple of 4), which waveShaperCurveValue finishes.
@inline(never)
private func waveShaperApplyCurve4(
    _ source: Span<Float>,
    _ destination: inout MutableSpan<Float>,
    frames: Int,
    _ curve: Span<Float>
) -> Int {
    guard WaveShaperCurve4.applies(curve) else { return 0 }
    let stage = WaveShaperCurve4(curve)
    // i < frames, a span's count, so i * 4 and i + 4 cannot overflow.
    var i = 0
    while frames - i >= 4 {
        let x = source.bytes.load(fromByteOffset: i &* 4, as: SIMD4<Float>.self)
        var bytes = destination.mutableBytes
        bytes.storeBytes(of: stage.values(x, curve), toByteOffset: i &* 4, as: SIMD4<Float>.self)
        i &+= 4
    }
    return i
}

/// waveShaperApplyCurve4 in place.
@inline(never)
private func waveShaperApplyCurve4InPlace(_ buffer: inout MutableSpan<Float>, frames: Int, _ curve: Span<Float>) -> Int {
    guard WaveShaperCurve4.applies(curve) else { return 0 }
    let stage = WaveShaperCurve4(curve)
    // i < frames, a span's count, so i * 4 and i + 4 cannot overflow.
    var i = 0
    while frames - i >= 4 {
        var bytes = buffer.mutableBytes
        let x = bytes.load(fromByteOffset: i &* 4, as: SIMD4<Float>.self)
        bytes.storeBytes(of: stage.values(x, curve), toByteOffset: i &* 4, as: SIMD4<Float>.self)
        i &+= 4
    }
    return i
}

/// Copies `source` into the front of `destination`, which must have room for it: thirty-two frames at a time, then
/// the rest: MutableSpan has no bulk copy yet, so this is the widest copy the public API offers without unsafe.
@inline(always)
private func waveShaperCopy(_ source: Span<Float>, _ destination: inout MutableSpan<Float>) {
    let count = source.count
    precondition(destination.count >= count)
    // 0 <= i <= count, a span's count, so count - i, i * 4 and i + 32 cannot overflow.
    var i = 0
    while count &- i >= 32 {
        let x = source.bytes.load(fromByteOffset: i &* 4, as: SIMD32<Float>.self)
        var bytes = destination.mutableBytes
        bytes.storeBytes(of: x, toByteOffset: i &* 4, as: SIMD32<Float>.self)
        i &+= 32
    }
    while i < count {
        destination[i] = source[i]
        i &+= 1
    }
}

/// Applies the curve to the first `min(source.count, destination.count)` frames; an empty curve copies `source`,
/// which `destination` must have room for.
@inline(always)
private func waveShaperApplyCurve(_ source: Span<Float>, _ destination: inout MutableSpan<Float>, _ curve: Span<Float>) {
    if curve.isEmpty {
        waveShaperCopy(source, &destination)
        return
    }
    let frames = min(source.count, destination.count)
    for i in waveShaperApplyCurve4(source, &destination, frames: frames, curve)..<frames {
        destination[i] = waveShaperCurveValue(source[i], curve)
    }
}

/// Applies the curve in place to the first `frames` frames of `buffer`; an empty curve leaves them as they are.
@inline(always)
private func waveShaperApplyCurveInPlace(_ buffer: inout MutableSpan<Float>, frames: Int, _ curve: Span<Float>) {
    precondition(frames >= 0 && frames <= buffer.count)
    if curve.isEmpty {
        return
    }
    for i in waveShaperApplyCurve4InPlace(&buffer, frames: frames, curve)..<frames {
        buffer[i] = waveShaperCurveValue(buffer[i], curve)
    }
}

/// The samplers and buffers that oversampling uses.
struct WaveShaperOversampling: ~Copyable {
    private var tempBuffer = [256 of Float](repeating: 0)
    private var tempBuffer2 = [512 of Float](repeating: 0)
    private var upSampler = WaveShaperUpSampler<128, 256>()
    private var downSampler = WaveShaperDownSampler<128, 256, 512>()
    private var upSampler2 = WaveShaperUpSampler<256, 512>()
    private var downSampler2 = WaveShaperDownSampler<256, 512, 1024>()

    init() {}

    static var latencyFrames2x: Int {
        WaveShaperUpSampler<128, 256>.latencyFrames + WaveShaperDownSampler<128, 256, 512>.latencyFrames
    }

    static var latencyFrames4x: Int {
        // The second stage runs at twice the rate: divide by 2 to get back down to the regular sample-rate.
        let secondStage = WaveShaperUpSampler<256, 512>.latencyFrames + WaveShaperDownSampler<256, 512, 1024>.latencyFrames
        return latencyFrames2x + secondStage / 2
    }

    /// Up-samples, applies the curve at 2x and down-samples; a source that is not one render quantum does nothing.
    mutating func process2x(_ source: Span<Float>, _ destination: inout MutableSpan<Float>, _ curve: Span<Float>) {
        guard source.count == waveShaperRenderQuantumSize else {
            return
        }
        var temp = tempBuffer.mutableSpan
        upSampler.process(source, &temp)
        waveShaperApplyCurveInPlace(&temp, frames: temp.count, curve)
        downSampler.process(temp.span, &destination)
    }

    /// The same at 4x, through two stages each way.
    mutating func process4x(_ source: Span<Float>, _ destination: inout MutableSpan<Float>, _ curve: Span<Float>) {
        guard source.count == waveShaperRenderQuantumSize else {
            return
        }
        var temp = tempBuffer.mutableSpan
        var temp2 = tempBuffer2.mutableSpan
        upSampler.process(source, &temp)
        upSampler2.process(temp.span, &temp2)
        waveShaperApplyCurveInPlace(&temp2, frames: temp2.count, curve)
        downSampler2.process(temp2.span, &temp)
        downSampler.process(temp.span, &destination)
    }

    /// `process2x` with the source the first `frames` frames of `buffer`, the destination; the up-sampler reads the
    /// source before the down-sampler writes the destination.
    mutating func process2xInPlace(_ buffer: inout MutableSpan<Float>, frames: Int, _ curve: Span<Float>) {
        guard frames == waveShaperRenderQuantumSize else {
            return
        }
        var temp = tempBuffer.mutableSpan
        upSampler.process(buffer.span.extracting(first: frames), &temp)
        waveShaperApplyCurveInPlace(&temp, frames: temp.count, curve)
        downSampler.process(temp.span, &buffer)
    }

    /// `process4x` with the source the first `frames` frames of `buffer`, the destination.
    mutating func process4xInPlace(_ buffer: inout MutableSpan<Float>, frames: Int, _ curve: Span<Float>) {
        guard frames == waveShaperRenderQuantumSize else {
            return
        }
        var temp = tempBuffer.mutableSpan
        var temp2 = tempBuffer2.mutableSpan
        upSampler.process(buffer.span.extracting(first: frames), &temp)
        upSampler2.process(temp.span, &temp2)
        waveShaperApplyCurveInPlace(&temp2, frames: temp2.count, curve)
        downSampler2.process(temp2.span, &temp)
        downSampler.process(temp.span, &buffer)
    }

    mutating func reset() {
        upSampler.reset()
        downSampler.reset()
        upSampler2.reset()
        downSampler2.reset()
    }
}

/// Holds the oversampling state, once it is allocated, at a fixed address.
final class WaveShaperOversamplingStorage {
    var state = WaveShaperOversampling()
}

/// The state of one channel of WaveShaperDSPKernel: the oversampling state, allocated by
/// `waveShaperEnableOversampling`.
@_expose(Cxx)
public struct WaveShaperKernel {
    private var oversampling: WaveShaperOversamplingStorage?

    init() {}

    /// Allocates the samplers if they do not exist yet.
    mutating func enableOversampling() {
        if oversampling == nil {
            oversampling = WaveShaperOversamplingStorage()
        }
    }

    /// `source` is the input's first frames, `destination` the output channel; they are different buffers; an
    /// oversample value that is not an OverSampleType does nothing.
    mutating func process(_ curve: Span<Float>, _ oversample: UInt8, _ source: Span<Float>, _ destination: inout MutableSpan<Float>) {
        switch WaveShaperOverSample(rawValue: oversample) {
        case .none?:
            waveShaperApplyCurve(source, &destination, curve)
        case .twice?:
            oversampling!.state.process2x(source, &destination, curve)
        case .fourTimes?:
            oversampling!.state.process4x(source, &destination, curve)
        case nil:
            break
        }
    }

    /// `process`, or `processInPlace` for the first `count` frames when `source` is the destination (an empty span);
    /// no oversampling and no curve is a copy, or nothing in place, without a call into `process`.
    @inline(always)
    mutating func processSpans(
        _ curve: Span<Float>, _ oversample: UInt8, _ source: Span<Float>, _ destination: inout MutableSpan<Float>,
        _ count: Int
    ) {
        let inPlace = audioInputIsOutput(source, count)
        if oversample == WaveShaperOverSample.none.rawValue && curve.isEmpty {
            if inPlace {
                precondition(count >= 0 && count <= destination.count)
            } else {
                waveShaperCopy(source, &destination)
            }
            return
        }
        if inPlace {
            processInPlace(curve, oversample, &destination, frames: count)
        } else {
            process(curve, oversample, source, &destination)
        }
    }

    /// `process` with the source the first `frames` frames of `buffer`, the destination.
    mutating func processInPlace(_ curve: Span<Float>, _ oversample: UInt8, _ buffer: inout MutableSpan<Float>, frames: Int) {
        precondition(frames >= 0 && frames <= buffer.count)
        switch WaveShaperOverSample(rawValue: oversample) {
        case .none?:
            waveShaperApplyCurveInPlace(&buffer, frames: frames, curve)
        case .twice?:
            oversampling!.state.process2xInPlace(&buffer, frames: frames, curve)
        case .fourTimes?:
            oversampling!.state.process4xInPlace(&buffer, frames: frames, curve)
        case nil:
            break
        }
    }

    /// Resets the samplers if they exist.
    mutating func reset() {
        oversampling?.state.reset()
    }

    /// The latency of `oversample` in frames; the samplers exist whenever oversampling is on, and their latency does
    /// not depend on their state, so this does not read them.
    static func latencyFrames(_ oversample: UInt8) -> Int {
        switch WaveShaperOverSample(rawValue: oversample) {
        case .none?, nil:
            0
        case .twice?:
            WaveShaperOversampling.latencyFrames2x
        case .fourTimes?:
            WaveShaperOversampling.latencyFrames4x
        }
    }
}

/// Creates the state of one channel, without the samplers.
@_expose(Cxx)
public func makeWaveShaperKernel() -> WaveShaperKernel {
    WaveShaperKernel()
}

/// Allocates the samplers that oversampling uses, if they do not exist yet.
@_expose(Cxx)
public func waveShaperEnableOversampling(_ kernel: inout WaveShaperKernel) {
    kernel.enableOversampling()
}

/// Shapes the `count` frames of `source` into `destination` with `curve` and WaveShaperProcessor's OverSampleType value
/// `oversample`; a source that is the destination comes as an empty span (inputUnlessOutput), and the destination's
/// first `count` frames are shaped in place.
@_expose(Cxx)
public func waveShaperProcess(
    _ kernel: inout WaveShaperKernel,
    _ curve: AudioDSPSpanConstFloat,
    _ oversample: UInt8,
    _ source: AudioDSPSpanConstFloat,
    _ destination: AudioDSPSpanFloat,
    _ count: Int
) {
    let curveSpan = unsafe Span<Float>(_unsafeCxxSpan: curve)
    let sourceSpan = unsafe Span<Float>(_unsafeCxxSpan: source)
    var destinationSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    kernel.processSpans(curveSpan, oversample, sourceSpan, &destinationSpan, count)
}

/// Resets the samplers if they exist.
@_expose(Cxx)
public func waveShaperReset(_ kernel: inout WaveShaperKernel) {
    kernel.reset()
}

/// The latency of WaveShaperProcessor's OverSampleType value `oversample`, in frames.
@_expose(Cxx)
public func waveShaperLatencyFrames(_ oversample: UInt8) -> Int {
    WaveShaperKernel.latencyFrames(oversample)
}

/// Applies `curve` to the first `min(source.size(), destination.size())` frames of `source`; an empty curve copies
/// `source`, which `destination` must have room for.
@_expose(Cxx)
public func waveShaperProcessCurve(_ source: AudioDSPSpanConstFloat, _ destination: AudioDSPSpanFloat, _ curve: AudioDSPSpanConstFloat) {
    let sourceSpan = unsafe Span<Float>(_unsafeCxxSpan: source)
    var destinationSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    let curveSpan = unsafe Span<Float>(_unsafeCxxSpan: curve)
    waveShaperApplyCurve(sourceSpan, &destinationSpan, curveSpan)
}
