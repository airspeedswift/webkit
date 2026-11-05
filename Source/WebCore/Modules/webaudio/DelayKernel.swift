// Swift port of DelayDSPKernel.cpp's circular buffer and interpolation.
// The AudioParam traffic (which path, the sample-accurate delay times, the final value) stays in DelayDSPKernel.cpp.

#if USE_SWIFT_WEBAUDIO_KERNELS

public import WebCore_Private.WebAudioKernelTypes
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.NativeCallee
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmBranchHints
internal import JavaScriptCore_Private.Cxx.WasmCallee
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import JavaScriptCore_Private.Cxx.WasmModuleInformation
internal import JavaScriptCore_Private.Cxx.WasmTypeDefinition
internal import wtf.Core.Stopwatch

// Returns (a - b) if a is greater than b, 0 otherwise. The operands are indices and counts, which are not negative, so
// the difference does not overflow.
@inline(always)
private func positiveSubtract(_ a: Int, _ b: Int) -> Int {
    a <= b ? 0 : a &- b
}

// std::clamp(value, low, high): a NaN value passes through.
@inline(always)
private func clamped(_ value: Double, _ low: Double, _ high: Double) -> Double {
    value < low ? low : (high < value ? high : value)
}

// Copies `count` floats from `source` at `sourceOffset` to `destination` at `destinationOffset`. The range of each side
// is checked once, so that the loop has no checks and compiles to a vector copy. A range outside either span traps,
// but only when it is not empty. The offsets and the count are indices into spans, so a sum that wraps is negative and
// its range traps like an out-of-range one.
@inline(always)
private func copyFloats(
    _ source: Span<Float>,
    _ sourceOffset: Int,
    _ destination: inout MutableSpan<Float>,
    _ destinationOffset: Int,
    _ count: Int
) {
    if count <= 0 { return }
    var destinationRange = destination._mutatingExtracting(destinationOffset..<destinationOffset &+ count)
    let sourceRange = source.extracting(sourceOffset..<sourceOffset &+ count)
    for i in 0..<count {
        destinationRange[i] = sourceRange[i]
    }
}

// AudioUtilities::renderQuantumSize, the most frames one call processes and the size of the guard region after the
// circular buffer. DelayDSPKernel.cpp checks it with a static_assert.
private let delayRenderQuantumSize = 128

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
        // Frames written to the buffer's first guardSize positions are also written after its end.
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

    // Delays the first `count` frames of `block` in place.
    @inline(always)
    mutating func processARateInPlace(_ block: inout MutableSpan<Float>, _ delayTimes: Span<Float>) {
        if length == 0 { return }
        copyToCircularBuffer(block.span)
        renderARate(block.count, &block, delayTimes)
    }

    // Writes the delayed frames, once the input is in the circular buffer.
    @inline(always)
    private mutating func renderARate(_ count: Int, _ destination: inout MutableSpan<Float>, _ delayTimes: Span<Float>) {
        let bufferLength = length
        let maxDelayTime = self.maxDelayTime
        let sampleRate = Double(self.sampleRate)
        let bufferLengthValue = Double(bufferLength)
        let bufferSpan = buffer.span.extracting(0..<bufferLength)
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
            // The C++ wraps here for a saturated readIndex1. This read of sample1 then traps, since readIndex1 is out of
            // range.
            let readIndex2 = (readIndex1 &+ 1) % bufferLength
            let interpolationFactor = Float(readPosition - Double(readIndex1))

            writeIndex = (writeIndex &+ 1) % bufferLength

            let sample1 = bufferSpan[readIndex1]
            let sample2 = bufferSpan[readIndex2]
            destination[i] = sample1.addingContractedProduct(interpolationFactor, sample2 - sample1)
        }
    }

    // `destinationAlignment` is the destination's offset from a 16-byte boundary, in floats. The C++ passes the destination
    // as the first input of vDSP_vintb, whose results for the frames before the first 16-byte boundary and after the last
    // whole group of four differ in the last bit from the others. Which of the first input and the output the library
    // reads the boundary from was not told apart: they are the same buffer there.
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

    // Delays the first `count` frames of `block` in place.
    @inline(always)
    mutating func processKRateInPlace(_ block: inout MutableSpan<Float>, _ delayTime: Double, _ destinationAlignment: Int) {
        if length == 0 { return }
        copyToCircularBuffer(block.span)
        renderKRate(block.count, &block, delayTime, destinationAlignment)
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

        // The destination must hold every frame (the C++ copies into it before interpolating).
        precondition(destination.count >= count)

        writeIndex = (writeIndex &+ count) % bufferLength

        // Without a fraction the frames at the read position are the result.
        if interpolationFactor == 0 {
            Self.copyFromCircularBuffer(buffer.span.extracting(0..<bufferLength), readIndex1, count, &destination)
            return
        }

        // The C++ interpolates in a render quantum sized temporary buffer. The frames at readIndex1 and readIndex2 are
        // each one range of the buffer, through the copy of its start where the read passes the end. readIndex1 is
        // below the length, since the read position is.
        precondition(count <= delayRenderQuantumSize)
        precondition(readIndex1 < bufferLength)
        let readIndex2 = readIndex1 &+ 1

        // The result of vDSP_vintb, computed here and written into the destination in one pass. With t the interpolation
        // factor, the frames in whole groups of four from the first 16-byte boundary are fma(b, t, a * (1 - t)), and the
        // others are fma(a, 1 - t, b * t). Apple does not document this: it was found by comparing the library's output
        // with this arithmetic on arm64 macOS, for every count, alignment and special value tried. The C++ result is
        // whatever the library returns, so a change to the library changes it and not this code.
        // readIndex1 is below the buffer length and count is at most the guard size, so the sums do not overflow.
        let first = buffer.span.extracting(readIndex1..<readIndex1 &+ count)
        let second = buffer.span.extracting(readIndex2..<readIndex2 &+ count)
        var result = destination._mutatingExtracting(0..<count)
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
}

@_expose(Cxx)
public func makeDelayKernel(_ bufferLength: Int, _ maxDelayTime: Double, _ sampleRate: Float) -> DelayKernel {
    DelayKernel(bufferLength: bufferLength, maxDelayTime: maxDelayTime, sampleRate: sampleRate)
}

/// Delays `source` into `destination` by `delayTime` seconds, one delay for the whole call, where they are
/// different buffers. `destinationAlignment` is the offset of `destination` from a 16-byte boundary, in floats.
///
/// The caller owns both buffers, each stays allocated at its length for the call and nothing else reads or writes
/// them meanwhile, and `source` and `destination` do not overlap. Floats have no invalid bit patterns.
/// FIXME: rdar://186723514 (receiving a std::span safely).
@_expose(Cxx)
public func delayProcessKRate(
    _ kernel: inout DelayKernel,
    _ source: FloatSpan,
    _ destination: MutableFloatSpan,
    _ delayTime: Double,
    _ destinationAlignment: Int
) {
    let sourceSpan = unsafe Span<Float>(_unsafeCxxSpan: source)
    var destinationSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    kernel.processKRate(sourceSpan, &destinationSpan, delayTime, destinationAlignment)
}

/// Delays `buffer` in place by `delayTime` seconds, one delay for the whole call. `destinationAlignment` is the
/// offset of `buffer` from a 16-byte boundary, in floats.
///
/// The caller owns the buffer, which stays allocated at its length for the call, and nothing else reads or writes it
/// meanwhile. Floats have no invalid bit patterns. FIXME: rdar://186723514 (receiving a std::span safely).
@_expose(Cxx)
public func delayProcessKRateInPlace(
    _ kernel: inout DelayKernel,
    _ buffer: MutableFloatSpan,
    _ delayTime: Double,
    _ destinationAlignment: Int
) {
    var bufferSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: buffer)
    kernel.processKRateInPlace(&bufferSpan, delayTime, destinationAlignment)
}

/// Delays `source` into `destination` by one delay time per frame, in seconds, where they are different buffers.
///
/// The caller owns the three buffers, each stays allocated at its length for the call and nothing else reads or
/// writes them meanwhile, and `destination` overlaps neither `source` nor `delayTimes`. Floats have no invalid bit
/// patterns. FIXME: rdar://186723514 (receiving a std::span safely).
@_expose(Cxx)
public func delayProcessARate(_ kernel: inout DelayKernel, _ source: FloatSpan, _ destination: MutableFloatSpan, _ delayTimes: FloatSpan) {
    let sourceSpan = unsafe Span<Float>(_unsafeCxxSpan: source)
    var destinationSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    let delayTimesSpan = unsafe Span<Float>(_unsafeCxxSpan: delayTimes)
    kernel.processARate(sourceSpan, &destinationSpan, delayTimesSpan)
}

/// Delays `buffer` in place by one delay time per frame, in seconds.
///
/// The caller owns the two buffers, each stays allocated at its length for the call and nothing else reads or writes
/// them meanwhile, and they do not overlap. Floats have no invalid bit patterns. FIXME: rdar://186723514 (receiving a
/// std::span safely).
@_expose(Cxx)
public func delayProcessARateInPlace(_ kernel: inout DelayKernel, _ buffer: MutableFloatSpan, _ delayTimes: FloatSpan) {
    var bufferSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: buffer)
    let delayTimesSpan = unsafe Span<Float>(_unsafeCxxSpan: delayTimes)
    kernel.processARateInPlace(&bufferSpan, delayTimesSpan)
}

@_expose(Cxx)
public func delayReset(_ kernel: inout DelayKernel) {
    kernel.reset()
}

@_expose(Cxx)
public func delayTailTime(_ kernel: borrowing DelayKernel) -> Double {
    kernel.tailTime
}

#endif // USE_SWIFT_WEBAUDIO_KERNELS
