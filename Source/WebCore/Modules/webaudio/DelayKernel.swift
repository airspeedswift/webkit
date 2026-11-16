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

// The delay's circular buffer and interpolation. The AudioParam traffic (which path, the sample-accurate delay times,
// the final value) stays in DelayDSPKernel.cpp.
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

// Returns (a - b) if a is greater than b, 0 otherwise. The operands are indices and counts, which are not negative, so
// the difference does not overflow.
@inline(always)
private func positiveSubtract(_ a: Int, _ b: Int) -> Int {
    a <= b ? 0 : a &- b
}

// Clamp to [low, high]; a NaN value passes through.
@inline(always)
private func clamped(_ value: Double, _ low: Double, _ high: Double) -> Double {
    value < low ? low : (high < value ? high : value)
}

// Copies `count` floats between two spans, checking each range once so that the loop compiles to a vector copy. A range
// outside either span traps unless it is empty; a wrapped sum is negative and fails the check.
@inline(always)
private func copyFloats(
    _ source: Span<Float>,
    _ sourceOffset: Int,
    _ destination: inout MutableSpan<Float>,
    _ destinationOffset: Int,
    _ count: Int
) {
    if count <= 0 { return }
    let destinationEnd = destinationOffset &+ count
    precondition(destinationOffset >= 0 && destinationOffset < destinationEnd && destinationEnd <= destination.count)
    let sourceRange = source.extracting(sourceOffset..<sourceOffset &+ count)
    for i in 0..<count {
        destination[destinationOffset &+ i] = sourceRange[i]
    }
}

// AudioUtilities::renderQuantumSize, the most frames one call processes and the size of the guard region after the
// circular buffer.
private let delayRenderQuantumSize = 128

/// The state of a delay line.
@_expose(Cxx)
public struct DelayKernel {
    // The circular buffer of `length` frames, followed by a copy of its first delayRenderQuantumSize frames:
    // buffer[length + j] == buffer[j] for j < delayRenderQuantumSize. A read of at most a render quantum that starts
    // inside the circular buffer is then one contiguous range, even when it passes the end.
    private var buffer: [Float]
    private let length: Int
    private var writeIndex = 0
    private let maxDelayTime: Double
    private let sampleRate: Float
    var hasBuffer: Bool { length != 0 }

    init(bufferLength: Int, maxDelayTime: Double, sampleRate: Float) {
        length = bufferLength
        buffer = [Float](repeating: 0, count: bufferLength == 0 ? 0 : bufferLength + delayRenderQuantumSize)
        self.maxDelayTime = maxDelayTime
        self.sampleRate = sampleRate
    }

    var tailTime: Double { maxDelayTime }

    mutating func reset() {
        var span = buffer.mutableSpan
        span.update(repeating: 0)
    }

    // Copies `source` into the circular buffer starting at writeIndex, wrapping around at the end, and into the copy of
    // the buffer's first frames after its end.
    @inline(always)
    private mutating func copyToCircularBuffer(_ source: Span<Float>) {
        let count = source.count
        // The algorithm depends on this: the entire buffer is not filled more than once.
        precondition(length >= count)
        let length = self.length
        let writeIndex = self.writeIndex
        let guardSize = delayRenderQuantumSize
        var span = buffer.mutableSpan
        let remainder = positiveSubtract(length, writeIndex)
        let wrapped = positiveSubtract(count, remainder)
        if wrapped == 0 {
            copyFloats(source, 0, &span, writeIndex, count)
        } else if wrapped <= guardSize {
            // One copy runs on into the copy of the buffer's start, which the wrapped frames belong in.
            copyFloats(source, 0, &span, writeIndex, count)
            copyFloats(source, remainder, &span, 0, wrapped)
        } else {
            copyFloats(source, 0, &span, writeIndex, remainder)
            copyFloats(source, remainder, &span, 0, wrapped)
            copyFloats(source, remainder, &span, length, guardSize)
        }
        // Frames written to the buffer's first guardSize positions are also written after its end. writeIndex is less
        // than guardSize, and length + guardSize is the buffer's size, so length &+ writeIndex cannot overflow.
        if writeIndex < guardSize {
            copyFloats(source, 0, &span, length &+ writeIndex, min(min(count, remainder), guardSize - writeIndex))
        }
    }

    // Copies `count` frames starting at `start` out of the circular buffer, wrapping around at the end.
    @inline(always)
    private static func copyFromCircularBuffer(_ buffer: Span<Float>, _ start: Int, _ count: Int, _ destination: inout MutableSpan<Float>) {
        precondition(start <= buffer.count)
        precondition(destination.count >= count)
        let remainder = positiveSubtract(buffer.count, start)
        copyFloats(buffer, start, &destination, 0, min(count, remainder))
        copyFloats(buffer, 0, &destination, remainder, positiveSubtract(count, remainder))
    }

    // `source` and `destination` are different buffers.
    @inline(always)
    mutating func processARate(_ source: Span<Float>, _ destination: inout MutableSpan<Float>, _ delayTimes: Span<Float>) {
        if length == 0 { return }
        copyToCircularBuffer(source)
        renderARate(source.count, &destination, delayTimes)
    }

    @inline(always)
    mutating func processARateInPlace(_ block: inout MutableSpan<Float>, _ count: Int, _ delayTimes: Span<Float>) {
        if length == 0 { return }
        copyToCircularBuffer(block.span.extracting(0..<count))
        renderARate(count, &block, delayTimes)
    }

    // Writes the delayed frames, once the input is in the circular buffer.
    @inline(always)
    private mutating func renderARate(_ count: Int, _ destination: inout MutableSpan<Float>, _ delayTimes: Span<Float>) {
        let bufferLength = length
        let maxDelayTime = self.maxDelayTime
        let sampleRate = Double(self.sampleRate)
        let bufferLengthValue = Double(bufferLength)
        let bufferSpan = buffer.span.extracting(0..<bufferLength)
        // A span shorter than count traps.
        precondition(delayTimes.count >= count)
        precondition(destination.count >= count)
        // writeIndex is less than bufferLength, so incrementing it with a wrap at the end is `% bufferLength`.
        var writeIndex = self.writeIndex
        for i in 0..<count {
            var delayTime = Double(delayTimes[i])
            if delayTime.isNaN {
                delayTime = maxDelayTime
            } else {
                delayTime = clamped(delayTime, 0.0, maxDelayTime)
            }

            let desiredDelayFrames = delayTime * sampleRate

            // writeIndex and bufferLength are in memory, so their sum does not overflow.
            var readPosition = Double(writeIndex &+ bufferLength) - desiredDelayFrames
            if readPosition >= bufferLengthValue {
                readPosition -= bufferLengthValue
            }

            // Linearly interpolate in-between delay times.
            let readIndex1 = webAudioSizeFromDouble(readPosition)
            // This wraps for a saturated readIndex1, as size_t arithmetic does. The read of sample1 then traps, since
            // readIndex1 is out of range. For a readIndex1 in range, the next index is readIndex1 + 1 or 0 at the end.
            let next = readIndex1 &+ 1
            let readIndex2 = next == bufferLength ? 0 : next
            let interpolationFactor = Float(readPosition - Double(readIndex1))

            // writeIndex is less than bufferLength, so incrementing it cannot overflow.
            writeIndex = writeIndex &+ 1 == bufferLength ? 0 : writeIndex &+ 1

            let sample1 = bufferSpan[readIndex1]
            let sample2 = bufferSpan[readIndex2]
            destination[i] = sample1.addingContractedProduct(interpolationFactor, sample2 - sample1)
        }
        self.writeIndex = writeIndex
    }

    // `destinationAlignment` is the destination's offset from a 16-byte boundary, in floats, which the Cocoa
    // interpolation's result depends on (DelayInterpolation.cocoa).
    // `source` and `destination` are different buffers.
    @inline(always)
    mutating func processKRate(
        _ source: Span<Float>,
        _ destination: inout MutableSpan<Float>,
        _ delayTime: Double,
        _ destinationAlignment: Int
    ) {
        if length == 0 { return }
        copyToCircularBuffer(source)
        renderKRate(source.count, &destination, delayTime, destinationAlignment)
    }

    @inline(always)
    mutating func processKRateInPlace(_ block: inout MutableSpan<Float>, _ count: Int, _ delayTime: Double, _ destinationAlignment: Int) {
        if length == 0 { return }
        copyToCircularBuffer(block.span.extracting(0..<count))
        renderKRate(count, &block, delayTime, destinationAlignment)
    }

    // Writes the delayed frames, once the input is in the circular buffer.
    @inline(always)
    private mutating func renderKRate(
        _ count: Int,
        _ destination: inout MutableSpan<Float>,
        _ delayTime: Double,
        _ destinationAlignment: Int
    ) {
        let bufferLength = length

        // Make sure the delay time is in a valid range.
        let delayTime = clamped(delayTime, 0.0, maxDelayTime)
        let desiredDelayFrames = delayTime * Double(sampleRate)

        // writeIndex and bufferLength are in memory, so their sum does not overflow.
        var readPosition = Double(writeIndex &+ bufferLength) - desiredDelayFrames
        if readPosition >= Double(bufferLength) {
            readPosition -= Double(bufferLength)
        }

        // Linearly interpolate in-between delay times. readIndex1 and readIndex2 are the indices of the frames to be
        // used for interpolation.
        let readIndex1 = webAudioSizeFromDouble(readPosition)
        let interpolationFactor = Float(readPosition - Double(readIndex1))

        // The destination must hold every frame (it is copied into before interpolating).
        precondition(destination.count >= count)

        // writeIndex is less than bufferLength and count is at most the destination's size, both in memory, so their
        // sum cannot overflow.
        writeIndex = (writeIndex &+ count) % bufferLength

        // Without a fraction the frames at the read position are the result.
        if interpolationFactor == 0 {
            Self.copyFromCircularBuffer(buffer.span.extracting(0..<bufferLength), readIndex1, count, &destination)
            return
        }

        // The frames at readIndex1 and readIndex2 are each one range of the buffer, through the copy of its start where
        // the read passes the end. readIndex1 is below the length, since the read position is.
        precondition(count <= delayRenderQuantumSize)
        precondition(readIndex1 < bufferLength)
        let readIndex2 = readIndex1 &+ 1

        // Interpolates the two runs into the destination with the platform's arithmetic. readIndex1 is below the buffer
        // length and count is at most the guard size, so the sums do not overflow.
        let first = buffer.span.extracting(readIndex1..<readIndex1 &+ count)
        let second = buffer.span.extracting(readIndex2..<readIndex2 &+ count)
        #if canImport(Accelerate)
        DelayInterpolation.cocoa(first, second, interpolationFactor, &destination, destinationAlignment)
        #elseif arch(x86_64) || arch(i386)
        DelayInterpolation.sse2(first, second, interpolationFactor, &destination, destinationAlignment)
        #else
        DelayInterpolation.arm64(first, second, interpolationFactor, &destination, destinationAlignment)
        #endif
    }
}

// The k-rate delay's interpolation between the frames at the read position (`first`) and the next (`second`), one
// function per platform, all compiled everywhere (see VectorMathArithmetic). `destinationAlignment`, the destination's
// offset from a 16-byte boundary in floats, matters only to vDSP's result.
enum DelayInterpolation {
    // vDSP_vintb, with the destination as its first input: with t the interpolation factor, whole groups of four from the
    // first 16-byte boundary are fma(b, t, a * (1 - t)), and the others are fma(a, 1 - t, b * t).
    @inline(always)
    static func cocoa(
        _ first: Span<Float>,
        _ second: Span<Float>,
        _ interpolationFactor: Float,
        _ result: inout MutableSpan<Float>,
        _ destinationAlignment: Int
    ) {
        let count = first.count
        precondition(second.count == count)
        precondition(result.count >= count)
        let complement = 1 - interpolationFactor
        let phase = destinationAlignment & 3
        let head = min((4 - phase) & 3, count)
        let groupsEnd = head + (count - head) / 4 * 4
        for i in 0..<head {
            result[i] = (second[i] * interpolationFactor).addingProduct(first[i], complement)
        }
        for i in head..<groupsEnd {
            result[i] = (first[i] * complement).addingProduct(second[i], interpolationFactor)
        }
        for i in groupsEnd..<count {
            result[i] = (second[i] * interpolationFactor).addingProduct(first[i], complement)
        }
    }

    // Without Accelerate: the destination takes `first`, `second` becomes second - first (VectorMath::substract), and
    // multiplyByScalarThenAddToOutput adds t times it: out = first + (second - first) * t, contracted on arm64.
    @inline(always)
    static func arm64(
        _ first: Span<Float>,
        _ second: Span<Float>,
        _ interpolationFactor: Float,
        _ result: inout MutableSpan<Float>,
        _ destinationAlignment: Int
    ) {
        let count = first.count
        precondition(second.count == count)
        precondition(result.count >= count)
        for i in 0..<count {
            result[i] = first[i].addingProduct(second[i] - first[i], interpolationFactor)
        }
    }

    // As arm64, rounded at each step (x86_64 has no FMA in its baseline).
    @inline(always)
    static func sse2(
        _ first: Span<Float>,
        _ second: Span<Float>,
        _ interpolationFactor: Float,
        _ result: inout MutableSpan<Float>,
        _ destinationAlignment: Int
    ) {
        let count = first.count
        precondition(second.count == count)
        precondition(result.count >= count)
        for i in 0..<count {
            result[i] = first[i] + interpolationFactor * (second[i] - first[i])
        }
    }
}

// The frames of the circular buffer for a delay of `maxDelayFrames` frames: a render quantum more, so that processing
// a render quantum at a time does not overlap the writes to the buffer with the reads from it.
private func delayBufferLength(_ maxDelayFrames: UInt) -> Int {
    // The sum wraps, as size_t arithmetic does.
    Int(truncatingIfNeeded: UInt(delayRenderQuantumSize) &+ maxDelayFrames)
}

/// Creates the delay kernel of a DelayProcessor with `maxDelayTime` and `sampleRate`; without a positive sample rate,
/// the delay is 0 and has no buffer; a negative or NaN `maxDelayTime` has none either. `maxDelayFrames` is the delay
/// in frames, rounded up, when there is a buffer.
@_expose(Cxx)
public func makeDelayKernel(_ maxDelayTime: Double, _ sampleRate: Float, _ maxDelayFrames: UInt) -> DelayKernel {
    guard sampleRate > 0 else {
        return DelayKernel(bufferLength: 0, maxDelayTime: 0, sampleRate: sampleRate)
    }
    assert(maxDelayTime >= 0 && !maxDelayTime.isNaN)
    let hasBuffer = maxDelayTime >= 0 && !maxDelayTime.isNaN
    return DelayKernel(bufferLength: hasBuffer ? delayBufferLength(maxDelayFrames) : 0, maxDelayTime: maxDelayTime, sampleRate: sampleRate)
}

/// Creates a delay kernel for delays of up to `maxDelayTime` seconds; one of 0 or less has no buffer. `maxDelayFrames`
/// is the delay in frames, rounded up, when there is a buffer.
@_expose(Cxx)
public func makeDelayKernelWithMaxDelayTime(_ maxDelayTime: Double, _ sampleRate: Float, _ maxDelayFrames: UInt) -> DelayKernel {
    let hasBuffer = !(maxDelayTime <= 0)
    return DelayKernel(bufferLength: hasBuffer ? delayBufferLength(maxDelayFrames) : 0, maxDelayTime: maxDelayTime, sampleRate: sampleRate)
}

/// Whether the kernel has a circular buffer, without which DelayDSPKernel::process does nothing.
@_expose(Cxx)
public func delayHasBuffer(_ kernel: borrowing DelayKernel) -> Bool {
    kernel.hasBuffer
}

/// Delays the `count` frames of `source` into `destination` by `delayTime` seconds, one delay for the whole call.
///
/// `destinationAlignment` is the offset of `destination` from a 16-byte boundary, in floats. A source that is the
/// destination comes as an empty span (inputUnlessOutput), and the destination's first `count` frames are delayed in
/// place.
@_expose(Cxx)
public func delayProcessKRate(
    _ kernel: inout DelayKernel,
    _ source: AudioDSPSpanConstFloat,
    _ destination: AudioDSPSpanFloat,
    _ count: Int,
    _ delayTime: Double,
    _ destinationAlignment: Int
) {
    let sourceSpan = unsafe Span<Float>(_unsafeCxxSpan: source)
    var destinationSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    if audioInputIsOutput(sourceSpan, count) {
        kernel.processKRateInPlace(&destinationSpan, count, delayTime, destinationAlignment)
    } else {
        kernel.processKRate(sourceSpan, &destinationSpan, delayTime, destinationAlignment)
    }
}

/// Delays the `count` frames of `source` into `destination` by one delay time per frame, in seconds; a source that is
/// the destination comes as an empty span (inputUnlessOutput), and the destination's first `count` frames are delayed
/// in place.
@_expose(Cxx)
public func delayProcessARate(
    _ kernel: inout DelayKernel,
    _ source: AudioDSPSpanConstFloat,
    _ destination: AudioDSPSpanFloat,
    _ count: Int,
    _ delayTimes: AudioDSPSpanConstFloat
) {
    let sourceSpan = unsafe Span<Float>(_unsafeCxxSpan: source)
    var destinationSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    let delayTimesSpan = unsafe Span<Float>(_unsafeCxxSpan: delayTimes)
    if audioInputIsOutput(sourceSpan, count) {
        kernel.processARateInPlace(&destinationSpan, count, delayTimesSpan)
    } else {
        kernel.processARate(sourceSpan, &destinationSpan, delayTimesSpan)
    }
}

/// Clears the delay line.
@_expose(Cxx)
public func delayReset(_ kernel: inout DelayKernel) {
    kernel.reset()
}

/// The tail time in seconds.
@_expose(Cxx)
public func delayTailTime(_ kernel: borrowing DelayKernel) -> Double {
    kernel.tailTime
}
