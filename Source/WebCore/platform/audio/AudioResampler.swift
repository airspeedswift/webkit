// Copyright (C) 2010 Google Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//
// 1.  Redistributions of source code must retain the above copyright
//     notice, this list of conditions and the following disclaimer.
// 2.  Redistributions in binary form must reproduce the above copyright
//     notice, this list of conditions and the following disclaimer in the
//     documentation and/or other materials provided with the distribution.
// 3.  Neither the name of Apple Inc. ("Apple") nor the names of
//     its contributors may be used to endorse or promote products derived
//     from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY APPLE AND ITS CONTRIBUTORS "AS IS" AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL APPLE OR ITS CONTRIBUTORS BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
// THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// AudioResampler's state and its per-channel linear interpolation: the rate and each kernel's read position and carried
// frames. The AudioResampler class keeps the provider call, the source bus and one source buffer per channel.
// Multiply-adds are fused where Clang's -ffp-contract=on fuses them (addingContractedProduct).
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

// AudioResampler::MaxRate. AudioResampler.cpp checks it with a static_assert.
private let audioResamplerMaxRate: Double = 8

// Minimum and maximum that return the first argument when the comparison is false (NaN, or equal zeros of
// either sign); Swift.min and Swift.max differ for equal values.
@inline(always)
internal func audioCxxMinDouble(_ a: Double, _ b: Double) -> Double { b < a ? b : a }

@inline(always)
internal func audioCxxMaxDouble(_ a: Double, _ b: Double) -> Double { a < b ? b : a }

// WTF's truncateDoubleToInt32: the hardware's conversion. arm64's fcvtzs saturates and gives 0 for NaN; x86_64's
// cvttsd2si gives INT32_MIN for NaN and for every value out of range.
@inline(always)
private func audioResamplerTruncateDoubleToInt32(_ value: Double) -> Int32 {
    #if arch(arm64)
    if value.isNaN { return 0 }
    if value >= 2147483648.0 { return .max }
    if value <= -2147483649.0 { return .min }
    return audioResamplerTruncateInRange(value)
    #else
    if value > -2147483649.0 && value < 2147483648.0 { return audioResamplerTruncateInRange(value) }
    return .min
    #endif
}

// Int32(value) for a value in (-2^31 - 1, 2^31), without Int32(_:)'s range check: the whole part w has |w| <= 2^31, so
// w + 1.5 * 2^52 is exact, in [2^52, 2^53), and its bit pattern is 0x4338_0000_0000_0000 + w.
@inline(always)
private func audioResamplerTruncateInRange(_ value: Double) -> Int32 {
    let whole = value.rounded(.towardZero)
    return Int32(truncatingIfNeeded: Int64(bitPattern: (whole + 0x1.8p52).bitPattern) &- 0x4338_0000_0000_0000)
}

/// One channel's resampler: linear interpolation over a source buffer the caller fills.
struct AudioResamplerKernelState {
    private var virtualReadIndex: Double = 0
    // The last two source frames of the previous call, copied to the front of the source buffer by the next call.
    private var lastValues: InlineArray<2, Float> = [0, 0]
    // How many frames at the front of the source buffer are carried from the previous call: 0 or 2.
    private var fillIndex = 0

    /// Where in a source buffer of `bufferSize` frames the next `framesToProcess` frames of input go, and how many
    /// are needed; nil when they do not fit.
    func sourceRange(framesToProcess: Int, rate: Double, bufferSize: Int) -> (offset: Int, count: Int)? {
        // The position after process() has run.
        let nextFractionalIndex = virtualReadIndex.addingContractedProduct(Double(framesToProcess), rate)
        // Interpolation reads the frame after the last position, so round up.
        let endIndex = Int(audioResamplerTruncateDoubleToInt32(nextFractionalIndex + 1.0))
        // Fill up to and including endIndex, less what is carried.
        let end = 1 + endIndex
        guard end >= fillIndex else { return nil }
        let framesNeeded = end - fillIndex
        guard fillIndex < bufferSize && fillIndex + framesNeeded <= bufferSize else { return nil }
        return (fillIndex, framesNeeded)
    }

    /// Resamples `framesToProcess` frames from `source`, the whole source buffer, into `destination`.
    mutating func process(
        source: inout MutableSpan<Float>,
        destination: inout MutableSpan<Float>,
        framesToProcess: Int,
        rate: Double
    ) {
        let rate = audioCxxMinDouble(audioResamplerMaxRate, audioCxxMaxDouble(0.0, rate))

        if fillIndex > 0 {
            source[0] = lastValues[0]
            source[1] = lastValues[1]
        }

        var virtualReadIndex = self.virtualReadIndex
        // Frames are counted in an int. A count past the destination, or a negative one, traps here, before the loop,
        // so the loop needs no destination check.
        let frames = Int(Int32(truncatingIfNeeded: framesToProcess))
        precondition(frames >= 0 && frames <= destination.count)
        // Each read position's whole part is converted without a range check: for 0 <= whole < 2^52, whole + 2^52 is exact
        // and its bit pattern is 0x4330_0000_0000_0000 + whole. The position is always >= +0; any other value gives an
        // index below 0 or at least 2^52, which the source's check rejects.
        //
        // Two frames per step: the positions accumulate one rate at a time, so each is the one-frame loop's value, and
        // the conversion, the factors and the interpolation run two lanes at once. The pair is stored as one
        // SIMD2<Float>, since two element stores make LLVM scalarize the step. destinationIndex <= frames <= Int32.max,
        // so these cannot overflow.
        var destinationIndex = 0
        var destinationBytes = destination.mutableBytes
        while destinationIndex &+ 1 < frames {
            let nextReadIndex = virtualReadIndex + rate
            let position = SIMD2(virtualReadIndex, nextReadIndex)
            virtualReadIndex = nextReadIndex + rate
            let biased = position.rounded(.towardZero) + 0x1p52
            let readIndex0 = Int(truncatingIfNeeded: biased.x.bitPattern) &- 0x4330_0000_0000_0000
            let readIndex1 = Int(truncatingIfNeeded: biased.y.bitPattern) &- 0x4330_0000_0000_0000
            let interpolationFactor = position - (biased - 0x1p52)
            let frames0 = SIMD2<Float>(source[readIndex0], source[readIndex0 &+ 1])
            let frames1 = SIMD2<Float>(source[readIndex1], source[readIndex1 &+ 1])
            let sample1 = SIMD2<Double>(SIMD2(frames0.x, frames1.x))
            let sample2 = SIMD2<Double>(SIMD2(frames0.y, frames1.y))
            let sample = (interpolationFactor * sample2).addingContractedProduct(1.0 - interpolationFactor, sample1)
            destinationBytes.storeBytes(
                of: SIMD2<Float>(sample),
                toByteOffset: destinationIndex &* 4,
                as: SIMD2<Float>.self
            )
            destinationIndex &+= 2
        }
        if destinationIndex < frames {
            // The last frame of an odd count, one frame at a time.
            let whole = virtualReadIndex.rounded(.towardZero)
            let readIndex = Int(truncatingIfNeeded: (whole + 0x1p52).bitPattern) &- 0x4330_0000_0000_0000
            let interpolationFactor = virtualReadIndex - whole
            let sample1 = Double(source[readIndex])
            let sample2 = Double(source[readIndex &+ 1])
            let sample = (interpolationFactor * sample2).addingContractedProduct(1.0 - interpolationFactor, sample1)
            destinationBytes.storeBytes(of: Float(sample), toByteOffset: destinationIndex &* 4, as: Float.self)
            virtualReadIndex += rate
        }

        // Keep the last two frames for the next call, and move the read position back to the front.
        let whole = virtualReadIndex.rounded(.towardZero)
        let readIndex = Int(truncatingIfNeeded: (whole + 0x1p52).bitPattern) &- 0x4330_0000_0000_0000
        lastValues[0] = source[readIndex]
        lastValues[1] = source[readIndex &+ 1]
        fillIndex = 2
        virtualReadIndex -= Double(readIndex)
        self.virtualReadIndex = virtualReadIndex
    }

    mutating func reset() {
        self = AudioResamplerKernelState()
    }
}

/// AudioResampler's Swift state, held by the AudioResampler class: the rate and the kernels, one per channel.
@_expose(Cxx)
public struct AudioResamplerState {
    private(set) var rate: Double = 1
    private var kernels: [AudioResamplerKernelState]

    init(numberOfChannels: Int) {
        kernels = Array(repeating: AudioResamplerKernelState(), count: numberOfChannels)
    }

    /// Adds fresh kernels or removes the last ones; the others keep their state.
    mutating func configureChannels(_ numberOfChannels: Int) {
        let currentSize = kernels.count
        if numberOfChannels == currentSize { return }
        if numberOfChannels > currentSize {
            kernels.append(contentsOf: repeatElement(AudioResamplerKernelState(), count: numberOfChannels - currentSize))
        } else {
            kernels.removeLast(currentSize - numberOfChannels)
        }
    }

    /// 0 < rate <= MaxRate; other values are ignored.
    mutating func setRate(_ rate: Double) {
        if rate.isNaN || rate.isInfinite || rate <= 0.0 { return }
        self.rate = audioCxxMinDouble(audioResamplerMaxRate, rate)
    }

    mutating func reset() {
        for i in kernels.indices { kernels[i].reset() }
    }

    func sourceRange(channel: Int, framesToProcess: Int, bufferSize: Int) -> (offset: Int, count: Int)? {
        kernels[channel].sourceRange(framesToProcess: framesToProcess, rate: rate, bufferSize: bufferSize)
    }

    mutating func process(
        channel: Int,
        source: inout MutableSpan<Float>,
        destination: inout MutableSpan<Float>,
        framesToProcess: Int
    ) {
        kernels[channel].process(source: &source, destination: &destination, framesToProcess: framesToProcess, rate: rate)
    }
}

// MARK: AudioResampler entries

/// The state of an AudioResampler of `numberOfChannels` channels, at rate 1.
@_expose(Cxx)
public func makeAudioResamplerState(_ numberOfChannels: Int) -> AudioResamplerState {
    AudioResamplerState(numberOfChannels: numberOfChannels)
}

/// Adds fresh kernels or removes the last ones, so that `state` has `numberOfChannels`; the others keep their state.
@_expose(Cxx)
public func audioResamplerConfigureChannels(_ state: inout AudioResamplerState, _ numberOfChannels: Int) {
    state.configureChannels(numberOfChannels)
}

/// Sets the rate of `state`: 0 < rate <= MaxRate; other values are ignored.
@_expose(Cxx)
public func audioResamplerSetRate(_ state: inout AudioResamplerState, _ rate: Double) {
    state.setRate(rate)
}

/// Resets every channel's kernel to its initial state; the rate is kept.
@_expose(Cxx)
public func audioResamplerReset(_ state: inout AudioResamplerState) {
    state.reset()
}

/// The number of frames to fill in the source buffer of `channel` before the next process.
@_expose(Cxx)
public func audioResamplerSourceRange(
    _ state: borrowing AudioResamplerState,
    _ channel: Int,
    _ framesToProcess: Int,
    _ bufferSize: Int
) -> AudioResamplerSourceRange {
    guard let range = state.sourceRange(channel: channel, framesToProcess: framesToProcess, bufferSize: bufferSize) else {
        return AudioResamplerSourceRange(offset: 0, count: -1)
    }
    return AudioResamplerSourceRange(offset: range.offset, count: range.count)
}

/// Resamples `framesToProcess` frames of `channel` from `sourceBuffer`, the channel's whole source buffer, into
/// `destination`.
@_expose(Cxx)
public func audioResamplerProcess(
    _ state: inout AudioResamplerState,
    _ channel: Int,
    _ sourceBuffer: AudioDSPSpanFloat,
    _ destination: AudioDSPSpanFloat,
    _ framesToProcess: Int
) {
    var source = unsafe MutableSpan<Float>(_unsafeCxxSpan: sourceBuffer)
    var destinationSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    state.process(channel: channel, source: &source, destination: &destinationSpan, framesToProcess: framesToProcess)
}
