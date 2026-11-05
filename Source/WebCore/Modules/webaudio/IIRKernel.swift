// Swift port of IIRFilter.cpp and the state and maths of IIRDSPKernel.cpp.
// Statements keep the C++'s evaluation order and precision, and contract the multiply-adds as the C++ compiler does
// (see addingContractedProduct).

#if USE_SWIFT_WEBAUDIO_KERNELS

import Accelerate
import Darwin
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

// The length of the memory buffers of the IIR filter: a power of two, greater than the filter order
// (IIRFilter::maxOrder, 20). IIRDSPKernel.cpp checks both with a static_assert.
private let iirBufferLength = 32

// addingContractedProduct and webAudioSizeFromDouble are used by the biquad, delay and IIR kernels.
extension FloatingPoint {
    // self + lhs * rhs, contracted into one fused multiply-add on arm64, where the C++ compiler fuses `a * b + c`.
    // Elsewhere it is two operations, as the C++ compiles it there.
    @inline(always)
    func addingContractedProduct(_ lhs: Self, _ rhs: Self) -> Self {
        #if arch(arm64)
        return addingProduct(lhs, rhs)
        #else
        return self + lhs * rhs
        #endif
    }
}

@inline(always)
private func copySign(_ magnitude: Double, _ sign: Double) -> Double {
    Double(signOf: sign, magnitudeOf: magnitude)
}

// copysign(isinf(x) ? 1.0 : 0.0, x)
@inline(always)
private func infinityToUnit(_ x: Double) -> Double {
    copySign(x.isInfinite ? 1.0 : 0.0, x)
}

// if (isnan(x)) x = copysign(0.0, x)
@inline(always)
private func nanToZero(_ x: Double) -> Double {
    x.isNaN ? copySign(0.0, x) : x
}

/// A std::complex<double> with the arithmetic the C++ gets from the compiler and the system library: the product is
/// clang's inline product with __muldc3's recovery, the quotient is compiler-rt's __divdc3 as the system library
/// builds it (contraction on), `abs` is hypot.
private struct IIRComplex {
    var re: Double
    var im: Double

    @inline(always)
    static func + (lhs: IIRComplex, rhs: IIRComplex) -> IIRComplex {
        IIRComplex(re: lhs.re + rhs.re, im: lhs.im + rhs.im)
    }

    @inline(always)
    static func * (z: IIRComplex, w: IIRComplex) -> IIRComplex {
        let ac = z.re * w.re
        let bd = z.im * w.im
        let ad = z.re * w.im
        let bc = z.im * w.re
        let x = ac - bd
        let y = ad + bc
        if x.isNaN && y.isNaN {
            return recoverProduct(z, w, ac, bd, ad, bc)
        }
        return IIRComplex(re: x, im: y)
    }

    // __muldc3: the recovery when both parts of the product are NaN.
    @inline(never)
    private static func recoverProduct(
        _ z: IIRComplex,
        _ w: IIRComplex,
        _ ac: Double,
        _ bd: Double,
        _ ad: Double,
        _ bc: Double
    ) -> IIRComplex {
        var a = z.re
        var b = z.im
        var c = w.re
        var d = w.im
        var recalc = false
        if a.isInfinite || b.isInfinite {
            a = infinityToUnit(a)
            b = infinityToUnit(b)
            c = nanToZero(c)
            d = nanToZero(d)
            recalc = true
        }
        if c.isInfinite || d.isInfinite {
            c = infinityToUnit(c)
            d = infinityToUnit(d)
            a = nanToZero(a)
            b = nanToZero(b)
            recalc = true
        }
        if !recalc && (ac.isInfinite || bd.isInfinite || ad.isInfinite || bc.isInfinite) {
            a = nanToZero(a)
            b = nanToZero(b)
            c = nanToZero(c)
            d = nanToZero(d)
            recalc = true
        }
        if recalc {
            return IIRComplex(re: Double.infinity * (a * c - b * d), im: Double.infinity * (a * d + b * c))
        }
        return IIRComplex(re: ac - bd, im: ad + bc)
    }

    // __divdc3 as the system library builds it: denominator = fma(c, c, d * d), real = fma(a, c, b * d),
    // imaginary = fma(b, c, -(a * d)).
    @inline(always)
    static func / (z: IIRComplex, w: IIRComplex) -> IIRComplex {
        var a = z.re
        var b = z.im
        var c = w.re
        var d = w.im
        var ilogbw: Int32 = 0
        let logbw = logb(fmax(abs(c), abs(d)))
        if logbw.isFinite {
            ilogbw = Int32(logbw)
            c = scalbn(c, -ilogbw)
            d = scalbn(d, -ilogbw)
        }
        let denominator = (d * d).addingContractedProduct(c, c)
        var x = scalbn((b * d).addingContractedProduct(a, c) / denominator, -ilogbw)
        var y = scalbn((-(a * d)).addingContractedProduct(b, c) / denominator, -ilogbw)
        if x.isNaN && y.isNaN {
            if denominator == 0.0 && (!a.isNaN || !b.isNaN) {
                x = copySign(Double.infinity, c) * a
                y = copySign(Double.infinity, c) * b
            } else if (a.isInfinite || b.isInfinite) && c.isFinite && d.isFinite {
                a = infinityToUnit(a)
                b = infinityToUnit(b)
                x = Double.infinity * (b * d).addingContractedProduct(a, c)
                y = Double.infinity * (-(a * d)).addingContractedProduct(b, c)
            } else if logbw.isInfinite && logbw > 0.0 && a.isFinite && b.isFinite {
                c = infinityToUnit(c)
                d = infinityToUnit(d)
                x = 0.0 * (b * d).addingContractedProduct(a, c)
                y = 0.0 * (-(a * d)).addingContractedProduct(b, c)
            }
        }
        return IIRComplex(re: x, im: y)
    }
}

// Horner's method to evaluate the polynomial P(z) = sum(coef[k]*z^k, k, 0, order).
@inline(always)
private func evaluatePolynomial(_ coefficients: Span<Double>, _ z: IIRComplex, _ order: Int) -> IIRComplex {
    var result = IIRComplex(re: 0, im: 0)
    var k = order
    while k >= 0 {
        result = result * z + IIRComplex(re: coefficients[k], im: 0)
        k -= 1
    }
    return result
}

// size_t(double) as arm64 computes it where the C++ leaves it undefined: NaN and negative give 0, large values
// saturate.
@inline(always)
func webAudioSizeFromDouble(_ value: Double) -> Int {
    if !(value > 0) { return 0 }
    if value >= 9.2e18 { return Int.max }
    return Int(value)
}

// int(double) as arm64 computes it where the C++ leaves it undefined: NaN gives 0, out of range saturates.
@inline(always)
private func int32FromDouble(_ value: Double) -> Int32 {
    if value.isNaN { return 0 }
    if value >= 2147483647.0 { return Int32.max }
    if value <= -2147483648.0 { return Int32.min }
    return Int32(value)
}

@inline(always)
private func copyOf(_ span: Span<Double>) -> [Double] {
    span.indices.map { span[$0] }
}

@_expose(Cxx)
public struct IIRKernel {
    // The old input and output values, as doubles to minimise roundoff. yBuffer[bufferIndex] is the most recent output.
    private var xBuffer: [32 of Double] = .init(repeating: 0)
    private var yBuffer: [32 of Double] = .init(repeating: 0)
    private var bufferIndex = 0
    // Copies of the processor's coefficient vectors, which never change after construction.
    private let feedforward: [Double]
    private let feedback: [Double]
    private(set) var tailTime = 0.0

    init(feedforward: Span<Double>, feedback: Span<Double>, sampleRate: Float, isFilterStable: Bool) {
        self.feedforward = copyOf(feedforward)
        self.feedback = copyOf(feedback)
        tailTime = computeTailTime(sampleRate: Double(sampleRate), isFilterStable: isFilterStable)
    }

    @inline(always)
    mutating func reset() {
        xBuffer = .init(repeating: 0)
        yBuffer = .init(repeating: 0)
        bufferIndex = 0
    }

    // Filters the first `count` frames of `buffer` in place. A frame is read before it is written.
    // y[n] = sum(b[k] * x[n - k], k = 0, M) - sum(a[k] * y[n - k], k = 1, N), Direct Form I.
    @inline(always)
    mutating func process(_ buffer: inout MutableSpan<Float>, _ count: Int) {
        let feedforward = self.feedforward.span
        let feedback = self.feedback.span
        let feedbackLength = feedback.count
        let feedforwardLength = feedforward.count
        let minLength = min(feedbackLength, feedforwardLength)

        // The previous frame's input and output, which the k == 1 terms read. They are also in the buffers, but a load
        // that follows the store of the previous frame would sit on the dependency chain.
        var previousInput = xBuffer[(bufferIndex &- 1) & (iirBufferLength - 1)] // wraps on purpose, then masked
        var previousOutput = yBuffer[(bufferIndex &- 1) & (iirBufferLength - 1)]

        for n in 0..<count {
            // The sums are computed in doubles, though the coefficients have single precision values.
            let input = Double(buffer[n])
            var yn = feedforward[0] * input

            // Run both the feedforward and feedback terms together, when possible.
            var k = 1
            if minLength > 1 {
                yn = yn.addingContractedProduct(feedforward[1], previousInput)
                yn = yn.addingContractedProduct(-feedback[1], previousOutput)
                k = 2
            }
            while k < minLength {
                let m = (bufferIndex &- k) & (iirBufferLength - 1) // wraps on purpose, then masked
                yn = yn.addingContractedProduct(feedforward[k], xBuffer[m])
                yn = yn.addingContractedProduct(-feedback[k], yBuffer[m])
                k += 1
            }

            // Handle any remaining feedforward or feedback terms.
            k = minLength
            while k < feedforwardLength {
                yn = yn.addingContractedProduct(feedforward[k], xBuffer[(bufferIndex &- k) & (iirBufferLength - 1)])
                k += 1
            }
            k = minLength
            while k < feedbackLength {
                yn = yn.addingContractedProduct(-feedback[k], yBuffer[(bufferIndex &- k) & (iirBufferLength - 1)])
                k += 1
            }

            // Save the current input and output values for the next output.
            xBuffer[bufferIndex] = input
            yBuffer[bufferIndex] = yn
            bufferIndex = (bufferIndex + 1) & (iirBufferLength - 1)
            previousInput = input
            previousOutput = yn

            buffer[n] = Float(yn)
        }
    }

    // Filters an impulse and finds the last render quantum whose peak is above one 16-bit PCM bit.
    private mutating func computeTailTime(sampleRate: Double, isFilterStable: Bool) -> Double {
        let renderQuantumSize = 128
        // The maximum tail time. Somewhat arbitrary: nobody expects output this long after the inputs have stopped.
        let maxTailTime = 10.0
        let maxTailAmplitude = Float(1 / 32768.0)

        // An unstable filter's impulse response does not converge to zero.
        if !isFilterStable || sampleRate == 0 {
            return maxTailTime
        }

        let numberOfBlocks = Int(int32FromDouble((sampleRate * maxTailTime / Double(renderQuantumSize)).rounded(.up)))
        precondition(numberOfBlocks != 0)

        var block = [Float](repeating: 0, count: renderQuantumSize)
        var magnitudes = [Float](repeating: 0, count: numberOfBlocks)

        block[0] = 1
        do {
            var blockSpan = block.mutableSpan
            process(&blockSpan, renderQuantumSize)
        }
        magnitudes[0] = vDSP.maximumMagnitude(block)

        for k in 1..<max(numberOfBlocks, 1) {
            do {
                var blockSpan = block.mutableSpan
                blockSpan.update(repeating: 0)
                process(&blockSpan, renderQuantumSize)
            }
            magnitudes[k] = vDSP.maximumMagnitude(block)
        }

        // Done computing the impulse response; the actual node starts in the initial state.
        reset()

        var index = numberOfBlocks - 1
        var k = index
        while k >= 0 {
            if magnitudes[k] > maxTailAmplitude {
                index = k
                break
            }
            k -= 1
        }

        // The magnitude first becomes lower than the threshold at the next block.
        return Double((index + 1) * renderQuantumSize) / sampleRate
    }

    // Magnitude and phase of the z-transform H(z) = sum(b[k]*z^(-k)) / sum(a[k]*z^(-k)) at the given frequencies.
    func frequencyResponse(
        _ frequencyHz: Span<Float>,
        _ magResponse: inout MutableSpan<Float>,
        _ phaseResponse: inout MutableSpan<Float>,
        _ nyquist: Double
    ) {
        let feedforward = self.feedforward.span
        let feedback = self.feedback.span
        for k in 0..<frequencyHz.count {
            // Frequency in Hz to normalized frequency, with 1 equal to the Nyquist frequency.
            let frequency = Float(Double(frequencyHz[k]) / nyquist)

            if frequency < 0 || frequency > 1 {
                // Out-of-bounds frequencies return NaN.
                magResponse[k] = Float.nan
                phaseResponse[k] = Float.nan
            } else {
                // zRecip = 1/z = exp(-j*frequency)
                let omega = -Double.pi * Double(frequency)
                let zRecip = IIRComplex(re: cos(omega), im: sin(omega))

                let numerator = evaluatePolynomial(feedforward, zRecip, feedforward.count - 1)
                let denominator = evaluatePolynomial(feedback, zRecip, feedback.count - 1)
                let response = numerator / denominator
                magResponse[k] = Float(hypot(response.re, response.im))
                phaseResponse[k] = Float(atan2(response.im, response.re))
            }
        }
    }
}

/// Builds the state of an IIR kernel and computes its tail time.
///
/// `feedforward` and `feedback` are the processor's coefficient vectors; each is copied during the call. The caller
/// owns their storage, which stays allocated at its length, and unwritten by anything else, for the call. Their
/// elements are doubles, with no invalid bit patterns. FIXME: rdar://186723514 (receiving a std::span safely).
@_expose(Cxx)
public func makeIIRKernel(_ feedforward: DoubleSpan, _ feedback: DoubleSpan, _ sampleRate: Float, _ isFilterStable: Bool) -> IIRKernel {
    let feedforwardSpan = unsafe Span<Double>(_unsafeCxxSpan: feedforward)
    let feedbackSpan = unsafe Span<Double>(_unsafeCxxSpan: feedback)
    return IIRKernel(feedforward: feedforwardSpan, feedback: feedbackSpan, sampleRate: sampleRate, isFilterStable: isFilterStable)
}

/// Filters `source` into `destination`, frame by frame, where they are different buffers.
///
/// The caller owns both buffers, each stays allocated at its length for the call and nothing else reads or writes
/// them meanwhile, and `source` and `destination` do not overlap. Floats have no invalid bit patterns.
/// FIXME: rdar://186723514 (receiving a std::span safely).
@_expose(Cxx)
public func iirProcess(_ kernel: inout IIRKernel, _ source: FloatSpan, _ destination: MutableFloatSpan) {
    let sourceSpan = unsafe Span<Float>(_unsafeCxxSpan: source)
    var destinationSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    // The filter works in place, so the input goes to the destination first.
    for i in 0..<sourceSpan.count {
        destinationSpan[i] = sourceSpan[i]
    }
    kernel.process(&destinationSpan, sourceSpan.count)
}

/// Filters `buffer` in place, frame by frame.
///
/// The caller owns the buffer, which stays allocated at its length for the call, and nothing else reads or writes it
/// meanwhile. Floats have no invalid bit patterns. FIXME: rdar://186723514 (receiving a std::span safely).
@_expose(Cxx)
public func iirProcessInPlace(_ kernel: inout IIRKernel, _ buffer: MutableFloatSpan) {
    var bufferSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: buffer)
    kernel.process(&bufferSpan, bufferSpan.count)
}

@_expose(Cxx)
public func iirReset(_ kernel: inout IIRKernel) {
    kernel.reset()
}

@_expose(Cxx)
public func iirTailTime(_ kernel: borrowing IIRKernel) -> Double {
    kernel.tailTime
}

/// Writes the magnitude and phase response at `frequencyHz`, one value per frequency.
///
/// The caller owns the three buffers, each stays allocated at its length for the call and nothing else reads or
/// writes them meanwhile, and `magResponse` and `phaseResponse` do not overlap each other or `frequencyHz`. Floats
/// have no invalid bit patterns. FIXME: rdar://186723514 (receiving a std::span safely).
@_expose(Cxx)
public func iirFrequencyResponse(
    _ kernel: borrowing IIRKernel,
    _ frequencyHz: FloatSpan,
    _ magResponse: MutableFloatSpan,
    _ phaseResponse: MutableFloatSpan,
    _ nyquist: Double
) {
    let frequencySpan = unsafe Span<Float>(_unsafeCxxSpan: frequencyHz)
    var magSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: magResponse)
    var phaseSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: phaseResponse)
    kernel.frequencyResponse(frequencySpan, &magSpan, &phaseSpan, nyquist)
}

#endif // USE_SWIFT_WEBAUDIO_KERNELS
