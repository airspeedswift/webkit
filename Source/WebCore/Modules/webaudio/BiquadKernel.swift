// Swift port of Biquad.cpp and the coefficient, process and tail-time logic of BiquadDSPKernel.cpp. Every statement
// keeps the C++'s evaluation order and precision, and contracts the multiply-adds as the C++ compiler does
// (see addingContractedProduct).
//
// Accelerate path only (BiquadDSPKernel.cpp requires USE(ACCELERATE) with the Swift kernels on): the constant-coefficient
// filter computes each output as vDSP_deq22D does, in double precision with a fused multiply-add chain in its order.

#if USE_SWIFT_WEBAUDIO_KERNELS

public import WebCore_Private.WebAudioKernelTypes
internal import WebCore_Private.Core.BiquadFilterType
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

// AudioUtilities::renderQuantumSize: the length of the per-frame coefficient arrays. BiquadDSPKernel.cpp checks it with a static_assert.
private let biquadRenderQuantumSize = 128

// std::max(a, b) and std::min(a, b) as libc++ defines them. They differ from Swift's on NaN.
@inline(always)
private func cppMax(_ a: Double, _ b: Double) -> Double {
    a < b ? b : a
}

@inline(always)
private func cppMin(_ a: Double, _ b: Double) -> Double {
    b < a ? b : a
}

// std::clamp(v, lo, hi): NaN passes through.
@inline(always)
private func cppClamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    v < lo ? lo : (hi < v ? hi : v)
}

// clampTo(value, 0) with a double value and an int bound (WTF/MathExtras.h): truncates to int, saturates at INT_MAX,
// NaN gives 0.
@inline(always)
private func clampToIntFromZero(_ value: Double) -> Int32 {
    if value >= Double(Int32.max) {
        return Int32.max
    }
    if !(value > 0) {
        return 0
    }
    return Int32(value)
}

// DenormalDisabler::flushDenormalFloatToZero, applied to a double (the argument narrows to float). Without hardware
// flushing (every CPU but x86) it also turns -0 into +0.
@inline(always)
private func flushDenormalFloatToZero(_ value: Double) -> Double {
    #if arch(x86_64)
    return Double(Float(value))
    #else
    let f = Float(value)
    return abs(f) < Float.leastNormalMagnitude ? 0.0 : Double(f)
    #endif
}

// copysign(isinf(x) ? 1 : 0, x)
@inline(always)
private func unitIfInfinite(_ x: Double) -> Double {
    Double(signOf: x, magnitudeOf: x.isInfinite ? 1.0 : 0.0)
}

// copysign(0, x)
@inline(always)
private func signedZero(_ x: Double) -> Double {
    Double(signOf: x, magnitudeOf: 0.0)
}

// MARK: - std::complex<double>

/// A std::complex<double> with the arithmetic the C++ gets from libc++ and the compiler: `*` is the inline product with
/// __muldc3's NaN recovery, `/` is the system's __divdc3 (compiler-rt, built with contraction on), `abs` is hypot.
private struct BiquadComplex {
    var re: Double
    var im: Double

    @inline(always)
    init(_ re: Double, _ im: Double) {
        self.re = re
        self.im = im
    }

    // double * complex: libc++ scales both parts.
    @inline(always)
    static func * (s: Double, z: BiquadComplex) -> BiquadComplex {
        BiquadComplex(z.re * s, z.im * s)
    }

    // complex + double and double + complex: libc++ adds to the real part.
    @inline(always)
    static func + (z: BiquadComplex, s: Double) -> BiquadComplex {
        BiquadComplex(z.re + s, z.im)
    }

    @inline(always)
    static func + (s: Double, z: BiquadComplex) -> BiquadComplex {
        BiquadComplex(z.re + s, z.im)
    }

    @inline(always)
    static func + (z: BiquadComplex, w: BiquadComplex) -> BiquadComplex {
        BiquadComplex(z.re + w.re, z.im + w.im)
    }

    @inline(always)
    static func - (z: BiquadComplex, w: BiquadComplex) -> BiquadComplex {
        BiquadComplex(z.re - w.re, z.im - w.im)
    }

    @inline(always)
    static func * (z: BiquadComplex, w: BiquadComplex) -> BiquadComplex {
        let ac = z.re * w.re
        let bd = z.im * w.im
        let ad = z.re * w.im
        let bc = z.im * w.re
        let x = ac - bd
        let y = ad + bc
        if x.isNaN && y.isNaN {
            return recoverProduct(z, w, ac, bd, ad, bc)
        }
        return BiquadComplex(x, y)
    }

    // __muldc3, after the inline product gave NaN in both parts.
    @inline(never)
    private static func recoverProduct(
        _ z: BiquadComplex,
        _ w: BiquadComplex,
        _ ac: Double,
        _ bd: Double,
        _ ad: Double,
        _ bc: Double
    ) -> BiquadComplex {
        var a = z.re
        var b = z.im
        var c = w.re
        var d = w.im
        var recalc = false
        if a.isInfinite || b.isInfinite {
            a = unitIfInfinite(a)
            b = unitIfInfinite(b)
            if c.isNaN { c = signedZero(c) }
            if d.isNaN { d = signedZero(d) }
            recalc = true
        }
        if c.isInfinite || d.isInfinite {
            c = unitIfInfinite(c)
            d = unitIfInfinite(d)
            if a.isNaN { a = signedZero(a) }
            if b.isNaN { b = signedZero(b) }
            recalc = true
        }
        if !recalc && (ac.isInfinite || bd.isInfinite || ad.isInfinite || bc.isInfinite) {
            if a.isNaN { a = signedZero(a) }
            if b.isNaN { b = signedZero(b) }
            if c.isNaN { c = signedZero(c) }
            if d.isNaN { d = signedZero(d) }
            recalc = true
        }
        if recalc {
            return BiquadComplex(Double.infinity * (a * c - b * d), Double.infinity * (a * d + b * c))
        }
        return BiquadComplex(ac - bd, ad + bc)
    }

    // __divdc3 as the macOS system library builds it: the sums of products are fused (denominator = fma(c, c, d * d),
    // real = fma(a, c, b * d), imaginary = fma(b, c, -(a * d))).
    @inline(always)
    static func / (z: BiquadComplex, w: BiquadComplex) -> BiquadComplex {
        var a = z.re
        var b = z.im
        var c = w.re
        var d = w.im
        var ilogbw: Int32 = 0
        let logbw = logb(fmax(abs(c), abs(d)))
        if logbw.isFinite {
            ilogbw = Int32(logbw)
            // The libm functions (taking an Int32), not the standard library's scalbn: it rounds a subnormal result twice.
            c = scalbn(c, -ilogbw)
            d = scalbn(d, -ilogbw)
        }
        let denominator = (d * d).addingContractedProduct(c, c)
        var x = scalbn((b * d).addingContractedProduct(a, c) / denominator, -ilogbw)
        var y = scalbn((-(a * d)).addingContractedProduct(b, c) / denominator, -ilogbw)
        if x.isNaN && y.isNaN {
            if denominator == 0.0 && (!a.isNaN || !b.isNaN) {
                x = Double(signOf: c, magnitudeOf: Double.infinity) * a
                y = Double(signOf: c, magnitudeOf: Double.infinity) * b
            } else if (a.isInfinite || b.isInfinite) && c.isFinite && d.isFinite {
                a = unitIfInfinite(a)
                b = unitIfInfinite(b)
                x = Double.infinity * (b * d).addingContractedProduct(a, c)
                y = Double.infinity * (-(a * d)).addingContractedProduct(b, c)
            } else if logbw.isInfinite && logbw > 0.0 && a.isFinite && b.isFinite {
                c = unitIfInfinite(c)
                d = unitIfInfinite(d)
                x = 0.0 * (b * d).addingContractedProduct(a, c)
                y = 0.0 * (-(a * d)).addingContractedProduct(b, c)
            }
        }
        return BiquadComplex(x, y)
    }

    // std::abs(std::complex)
    @inline(always)
    var magnitude: Double {
        hypot(re, im)
    }
}

// MARK: - Biquad

// One normalized coefficient set (a0 divided out).
private struct BiquadCoefficients {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double
}

@inline(always)
private func normalizedCoefficients(
    _ b0: Double,
    _ b1: Double,
    _ b2: Double,
    _ a0: Double,
    _ a1: Double,
    _ a2: Double
) -> BiquadCoefficients {
    let a0Inverse = 1 / a0
    return BiquadCoefficients(b0: b0 * a0Inverse, b1: b1 * a0Inverse, b2: b2 * a0Inverse, a1: a1 * a0Inverse, a2: a2 * a0Inverse)
}

/// The state of one channel's biquad filter: Biquad plus the tail time and sample rate of BiquadDSPKernel.
@_expose(Cxx)
public struct BiquadKernel {
    // y[n] + a1*y[n-1] + a2*y[n-2] = b0*x[n] + b1*x[n-1] + b2*x[n-2], one coefficient set per frame of a rendering
    // quantum (index 0 serves k-rate processing). The five coefficients are consecutive runs of
    // biquadRenderQuantumSize elements in one array (one allocation): b0, b1, b2, a1, a2.
    var coefficients: [Double]

    // Filter memory.
    var x1: Double = 0
    var x2: Double = 0
    var y1: Double = 0
    var y2: Double = 0

    var hasSampleAccurateValues = false

    var tailTime = Double.infinity
    let sampleRate: Float

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        // Room for the a-rate filter coefficients of a rendering quantum.
        coefficients = [Double](repeating: 0, count: 5 * biquadRenderQuantumSize)
        // Initialize as pass-thru (straight-wire, no filter effect).
        coefficients[Self.b0Start] = 1
    }

    // Where each coefficient's run starts in `coefficients`.
    private static var b0Start: Int { 0 }
    private static var b1Start: Int { biquadRenderQuantumSize }
    private static var b2Start: Int { 2 * biquadRenderQuantumSize }
    private static var a1Start: Int { 3 * biquadRenderQuantumSize }
    private static var a2Start: Int { 4 * biquadRenderQuantumSize }

    // MARK: Processing

    // Filters the first `source.count` frames of `source` into `destination`, which does not overlap it.
    mutating func process(_ source: Span<Float>, _ destination: inout MutableSpan<Float>) {
        let n = source.count
        precondition(destination.count >= n)
        if hasSampleAccurateValues {
            processSampleAccurate(source, &destination)
            return
        }
        // The sample-accurate path does not update the history of this one, so it is rebuilt from the filter memory. This
        // is needed in case we're switching from filtering with variable coefficients (i.e., with automations) to fixed
        // coefficients (without automations). The outputs are kept in double precision within the call.
        let (b0, b1, b2, a1, a2) = coefficientsOfFirstFrame()
        var x1 = self.x1
        var x2 = self.x2
        var y1 = self.y1
        var y2 = self.y2
        for k in 0..<n {
            let x = Double(source[k])
            let y = Self.fastOutput(b0, b1, b2, a1, a2, x, x1, x2, y1, y2)
            destination[k] = Float(y)
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
        }
        finishFastPath(x1, x2, destination, n)
    }

    // Filters the first `n` frames of `buffer` in place. A frame is read before it is written.
    mutating func processInPlace(_ buffer: inout MutableSpan<Float>, _ n: Int) {
        if hasSampleAccurateValues {
            processSampleAccurateInPlace(&buffer, n)
            return
        }
        let (b0, b1, b2, a1, a2) = coefficientsOfFirstFrame()
        var x1 = self.x1
        var x2 = self.x2
        var y1 = self.y1
        var y2 = self.y2
        for k in 0..<n {
            let x = Double(buffer[k])
            let y = Self.fastOutput(b0, b1, b2, a1, a2, x, x1, x2, y1, y2)
            buffer[k] = Float(y)
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
        }
        finishFastPath(x1, x2, buffer, n)
    }

    // One output of vDSP_deq22D: b1*x[n-1], then b2*x[n-2], b0*x[n], -a1*y[n-1] and -a2*y[n-2] added in that order,
    // each step fused. Apple does not document this order: it was found by comparing the library's output with this
    // arithmetic on arm64 macOS, for every count, phase and special value tried. The C++ result is whatever the library
    // returns, so a change to the library changes it and not this code.
    @inline(always)
    private static func fastOutput(
        _ b0: Double,
        _ b1: Double,
        _ b2: Double,
        _ a1: Double,
        _ a2: Double,
        _ x: Double,
        _ x1: Double,
        _ x2: Double,
        _ y1: Double,
        _ y2: Double
    ) -> Double {
        var sum = (b1 * x1).addingContractedProduct(b2, x2)
        sum = sum.addingContractedProduct(b0, x)
        sum = sum.addingContractedProduct(-a1, y1)
        return sum.addingContractedProduct(-a2, y2)
    }

    // Keep the last inputs in the filter memory variables. The outputs come from the destination, which holds them
    // rounded to float.
    @inline(always)
    private mutating func finishFastPath(_ x1: Double, _ x2: Double, _ destination: borrowing MutableSpan<Float>, _ n: Int) {
        self.x1 = x1
        self.x2 = x2
        y1 = Double(destination[n &- 1]) // wraps for fewer than 1 frame: the index then traps
        y2 = Double(destination[n &- 2]) // wraps for fewer than 2 frames: the index then traps
    }

    // The sample-accurate path: a frame of `source` is read before the same frame of `destination` is written, and the
    // filter history stays in local variables. The Accelerate path's buffers are not used, and once there are sample
    // accurate values there is no going back (see Biquad::process), so their history is not updated.
    @inline(never)
    private mutating func processSampleAccurate(_ source: Span<Float>, _ destination: inout MutableSpan<Float>) {
        // Create local copies of member variables.
        var x1 = self.x1
        var x2 = self.x2
        var y1 = self.y1
        var y2 = self.y2
        let all = coefficients.span
        let b0 = all.extracting(Self.b0Start..<Self.b0Start + biquadRenderQuantumSize)
        let b1 = all.extracting(Self.b1Start..<Self.b1Start + biquadRenderQuantumSize)
        let b2 = all.extracting(Self.b2Start..<Self.b2Start + biquadRenderQuantumSize)
        let a1 = all.extracting(Self.a1Start..<Self.a1Start + biquadRenderQuantumSize)
        let a2 = all.extracting(Self.a2Start..<Self.a2Start + biquadRenderQuantumSize)

        for k in 0..<source.count {
            let x = Double(source[k])
            var sum = (b1[k] * x1).addingContractedProduct(b0[k], x)
            sum = sum.addingContractedProduct(b2[k], x2)
            sum = sum.addingContractedProduct(-a1[k], y1)
            sum = sum.addingContractedProduct(-a2[k], y2)
            let y = Float(sum)

            destination[k] = y

            // Update state variables.
            x2 = x1
            x1 = x
            y2 = y1
            y1 = Double(y)
        }

        // Local variables back to member. Flush denormals here so we don't slow down the inner loop above.
        self.x1 = flushDenormalFloatToZero(x1)
        self.x2 = flushDenormalFloatToZero(x2)
        self.y1 = flushDenormalFloatToZero(y1)
        self.y2 = flushDenormalFloatToZero(y2)
    }

    @inline(never)
    private mutating func processSampleAccurateInPlace(_ buffer: inout MutableSpan<Float>, _ n: Int) {
        var x1 = self.x1
        var x2 = self.x2
        var y1 = self.y1
        var y2 = self.y2
        let all = coefficients.span
        let b0 = all.extracting(Self.b0Start..<Self.b0Start + biquadRenderQuantumSize)
        let b1 = all.extracting(Self.b1Start..<Self.b1Start + biquadRenderQuantumSize)
        let b2 = all.extracting(Self.b2Start..<Self.b2Start + biquadRenderQuantumSize)
        let a1 = all.extracting(Self.a1Start..<Self.a1Start + biquadRenderQuantumSize)
        let a2 = all.extracting(Self.a2Start..<Self.a2Start + biquadRenderQuantumSize)

        for k in 0..<n {
            let x = Double(buffer[k])
            var sum = (b1[k] * x1).addingContractedProduct(b0[k], x)
            sum = sum.addingContractedProduct(b2[k], x2)
            sum = sum.addingContractedProduct(-a1[k], y1)
            sum = sum.addingContractedProduct(-a2[k], y2)
            let y = Float(sum)

            buffer[k] = y

            x2 = x1
            x1 = x
            y2 = y1
            y1 = Double(y)
        }

        self.x1 = flushDenormalFloatToZero(x1)
        self.x2 = flushDenormalFloatToZero(x2)
        self.y1 = flushDenormalFloatToZero(y1)
        self.y2 = flushDenormalFloatToZero(y2)
    }

    @inline(always)
    private func coefficientsOfFirstFrame() -> (Double, Double, Double, Double, Double) {
        let all = coefficients.span
        return (all[Self.b0Start], all[Self.b1Start], all[Self.b2Start], all[Self.a1Start], all[Self.a2Start])
    }

    mutating func reset() {
        x1 = 0
        x2 = 0
        y1 = 0
        y2 = 0
    }

    // MARK: Coefficients

    // frequency is 0 - 1 normalized, resonance and dbGain are in decibels. Q is a unitless quality factor.

    private static func lowpassCoefficients(_ frequency: Double, _ resonance: Double) -> BiquadCoefficients {
        // Limit cutoff to 0 to 1.
        let cutoff = cppMax(0.0, cppMin(frequency, 1.0))

        if cutoff == 1 {
            // When cutoff is 1, the z-transform is 1.
            return normalizedCoefficients(1, 0, 0, 1, 0, 0)
        } else if cutoff > 0 {
            // Compute biquad coefficients for lowpass filter.
            let resonance = pow(10.0, 0.05 * resonance)

            let theta = Double.pi * cutoff
            let alpha = sin(theta) / (2 * resonance)
            let cosw = cos(theta)
            let beta = (1 - cosw) / 2

            let b0 = beta
            let b1 = 2 * beta
            let b2 = beta

            let a0 = 1 + alpha
            let a1 = -2 * cosw
            let a2 = 1 - alpha

            return normalizedCoefficients(b0, b1, b2, a0, a1, a2)
        } else {
            // When cutoff is zero, nothing gets through the filter, so set coefficients up correctly.
            return normalizedCoefficients(0, 0, 0, 1, 0, 0)
        }
    }

    private static func highpassCoefficients(_ frequency: Double, _ resonance: Double) -> BiquadCoefficients {
        // Limit cutoff to 0 to 1.
        let cutoff = cppMax(0.0, cppMin(frequency, 1.0))

        if cutoff == 1 {
            // The z-transform is 0.
            return normalizedCoefficients(0, 0, 0, 1, 0, 0)
        } else if cutoff > 0 {
            // Compute biquad coefficients for highpass filter.
            let resonance = pow(10.0, 0.05 * resonance)

            let theta = Double.pi * cutoff
            let alpha = sin(theta) / (2 * resonance)
            let cosw = cos(theta)
            let beta = (1 + cosw) / 2

            let b0 = beta
            let b1 = -(2 * beta)
            let b2 = beta

            let a0 = 1 + alpha
            let a1 = -2 * cosw
            let a2 = 1 - alpha

            return normalizedCoefficients(b0, b1, b2, a0, a1, a2)
        } else {
            // When cutoff is zero, the z-transform is 1.
            return normalizedCoefficients(1, 0, 0, 1, 0, 0)
        }
    }

    private static func lowShelfCoefficients(_ frequency: Double, _ dbGain: Double) -> BiquadCoefficients {
        // Clip frequencies to between 0 and 1, inclusive.
        let frequency = cppMax(0.0, cppMin(frequency, 1.0))

        let A = pow(10.0, dbGain / 40)

        if frequency == 1 {
            // The z-transform is a constant gain.
            return normalizedCoefficients(A * A, 0, 0, 1, 0, 0)
        } else if frequency > 0 {
            let w0 = Double.pi * frequency
            let S = 1.0 // filter slope (1 is max value)
            let alpha = 0.5 * sin(w0) * (((A + 1 / A) * (1 / S - 1) + 2)).squareRoot()
            let k = cos(w0)
            let k2 = 2 * A.squareRoot() * alpha
            let aPlusOne = A + 1
            let aMinusOne = A - 1

            let b0 = A * (aPlusOne.addingContractedProduct(-aMinusOne, k) + k2)
            let b1 = 2 * A * aMinusOne.addingContractedProduct(-aPlusOne, k)
            let b2 = A * (aPlusOne.addingContractedProduct(-aMinusOne, k) - k2)
            let a0 = aPlusOne.addingContractedProduct(aMinusOne, k) + k2
            let a1 = -2 * aMinusOne.addingContractedProduct(aPlusOne, k)
            let a2 = aPlusOne.addingContractedProduct(aMinusOne, k) - k2

            return normalizedCoefficients(b0, b1, b2, a0, a1, a2)
        } else {
            // When frequency is 0, the z-transform is 1.
            return normalizedCoefficients(1, 0, 0, 1, 0, 0)
        }
    }

    private static func highShelfCoefficients(_ frequency: Double, _ dbGain: Double) -> BiquadCoefficients {
        // Clip frequencies to between 0 and 1, inclusive.
        let frequency = cppMax(0.0, cppMin(frequency, 1.0))

        let A = pow(10.0, dbGain / 40)

        if frequency == 1 {
            // The z-transform is 1.
            return normalizedCoefficients(1, 0, 0, 1, 0, 0)
        } else if frequency > 0 {
            let w0 = Double.pi * frequency
            let S = 1.0 // filter slope (1 is max value)
            let alpha = 0.5 * sin(w0) * (((A + 1 / A) * (1 / S - 1) + 2)).squareRoot()
            let k = cos(w0)
            let k2 = 2 * A.squareRoot() * alpha
            let aPlusOne = A + 1
            let aMinusOne = A - 1

            let b0 = A * (aPlusOne.addingContractedProduct(aMinusOne, k) + k2)
            let b1 = -2 * A * aMinusOne.addingContractedProduct(aPlusOne, k)
            let b2 = A * (aPlusOne.addingContractedProduct(aMinusOne, k) - k2)
            let a0 = aPlusOne.addingContractedProduct(-aMinusOne, k) + k2
            let a1 = 2 * aMinusOne.addingContractedProduct(-aPlusOne, k)
            let a2 = aPlusOne.addingContractedProduct(-aMinusOne, k) - k2

            return normalizedCoefficients(b0, b1, b2, a0, a1, a2)
        } else {
            // When frequency = 0, the filter is just a gain, A^2.
            return normalizedCoefficients(A * A, 0, 0, 1, 0, 0)
        }
    }

    private static func peakingCoefficients(_ frequency: Double, _ Q: Double, _ dbGain: Double) -> BiquadCoefficients {
        // Clip frequencies to between 0 and 1, inclusive.
        let frequency = cppMax(0.0, cppMin(frequency, 1.0))

        // Don't let Q go negative, which causes an unstable filter.
        let Q = cppMax(0.0, Q)

        let A = pow(10.0, dbGain / 40)

        guard frequency > 0 && frequency < 1 else {
            // When frequency is 0 or 1, the z-transform is 1.
            return normalizedCoefficients(1, 0, 0, 1, 0, 0)
        }
        guard Q > 0 else {
            // When Q = 0, the limit of the z-transform as Q->0 is A^2.
            return normalizedCoefficients(A * A, 0, 0, 1, 0, 0)
        }
        let w0 = Double.pi * frequency
        let alpha = sin(w0) / (2 * Q)
        let k = cos(w0)

        let b0 = (1.0).addingContractedProduct(alpha, A)
        let b1 = -2 * k
        let b2 = (1.0).addingContractedProduct(-alpha, A)
        let a0 = 1 + alpha / A
        let a1 = -2 * k
        let a2 = 1 - alpha / A

        return normalizedCoefficients(b0, b1, b2, a0, a1, a2)
    }

    private static func allpassCoefficients(_ frequency: Double, _ Q: Double) -> BiquadCoefficients {
        // Clip frequencies to between 0 and 1, inclusive.
        let frequency = cppMax(0.0, cppMin(frequency, 1.0))

        // Don't let Q go negative, which causes an unstable filter.
        let Q = cppMax(0.0, Q)

        guard frequency > 0 && frequency < 1 else {
            // When frequency is 0 or 1, the z-transform is 1.
            return normalizedCoefficients(1, 0, 0, 1, 0, 0)
        }
        guard Q > 0 else {
            // When Q = 0, the limit of the z-transform as Q->0 is -1.
            return normalizedCoefficients(-1, 0, 0, 1, 0, 0)
        }
        let w0 = Double.pi * frequency
        let alpha = sin(w0) / (2 * Q)
        let k = cos(w0)

        let b0 = 1 - alpha
        let b1 = -2 * k
        let b2 = 1 + alpha
        let a0 = 1 + alpha
        let a1 = -2 * k
        let a2 = 1 - alpha

        return normalizedCoefficients(b0, b1, b2, a0, a1, a2)
    }

    private static func notchCoefficients(_ frequency: Double, _ Q: Double) -> BiquadCoefficients {
        // Clip frequencies to between 0 and 1, inclusive.
        let frequency = cppMax(0.0, cppMin(frequency, 1.0))

        // Don't let Q go negative, which causes an unstable filter.
        let Q = cppMax(0.0, Q)

        guard frequency > 0 && frequency < 1 else {
            // When frequency is 0 or 1, the z-transform is 1.
            return normalizedCoefficients(1, 0, 0, 1, 0, 0)
        }
        guard Q > 0 else {
            // When Q = 0, the limit of the z-transform as Q->0 is 0.
            return normalizedCoefficients(0, 0, 0, 1, 0, 0)
        }
        let w0 = Double.pi * frequency
        let alpha = sin(w0) / (2 * Q)
        let k = cos(w0)

        let b0 = 1.0
        let b1 = -2 * k
        let b2 = 1.0
        let a0 = 1 + alpha
        let a1 = -2 * k
        let a2 = 1 - alpha

        return normalizedCoefficients(b0, b1, b2, a0, a1, a2)
    }

    private static func bandpassCoefficients(_ frequency: Double, _ Q: Double) -> BiquadCoefficients {
        // No negative frequencies allowed.
        let frequency = cppMax(0.0, frequency)

        // Don't let Q go negative, which causes an unstable filter.
        let Q = cppMax(0.0, Q)

        guard frequency > 0 && frequency < 1 else {
            // When the cutoff is zero or one the z-transform approaches 0 (and is undefined when Q is zero too), so
            // make the filter 0.
            return normalizedCoefficients(0, 0, 0, 1, 0, 0)
        }
        let w0 = Double.pi * frequency
        guard Q > 0 else {
            // When Q = 0, the limit of the z-transform as Q->0 is 1.
            return normalizedCoefficients(1, 0, 0, 1, 0, 0)
        }
        let alpha = sin(w0) / (2 * Q)
        let k = cos(w0)

        let b0 = alpha
        let b1 = 0.0
        let b2 = -alpha
        let a0 = 1 + alpha
        let a1 = -2 * k
        let a2 = 1 - alpha

        return normalizedCoefficients(b0, b1, b2, a0, a1, a2)
    }

    // MARK: Frequency response

    // Evaluates the z-transform at the given frequencies (Hz), normalized against nyquist.
    func getFrequencyResponse(
        _ frequencyHz: Span<Float>,
        _ magResponse: inout MutableSpan<Float>,
        _ phaseResponse: inout MutableSpan<Float>,
        _ nyquist: Double
    ) {
        // H(z) = (b0 + (b1 + b2*z1)*z1) / (1 + (a1 + a2*z1)*z1) with z1 = exp(-j*pi*frequency).

        // Make local copies of the coefficients as a micro-optimization.
        let (b0, b1, b2, a1, a2) = coefficientsOfFirstFrame()

        for k in 0..<frequencyHz.count {
            // Convert from frequency in Hz to normalized frequency (0 -> 1), with 1 equal to the Nyquist frequency.
            let frequency = Float(Double(frequencyHz[k]) / nyquist)

            if frequency < 0 || frequency > 1 {
                // Out-of-bounds frequencies should return NaN.
                magResponse[k] = Float.nan
                phaseResponse[k] = Float.nan
            } else {
                let omega = -Double.pi * Double(frequency)
                let z = BiquadComplex(cos(omega), sin(omega))
                let numerator = b0 + (b1 + b2 * z) * z
                let denominator = BiquadComplex(1, 0) + (a1 + a2 * z) * z
                let response = numerator / denominator
                magResponse[k] = Float(response.magnitude)
                phaseResponse[k] = Float(atan2(response.im, response.re))
            }
        }
    }

    // MARK: Tail frame

    // The frame number where the impulse response of the filter at coefficient index `coefIndex` falls below
    // 1/32768, at most maxFrame.
    func tailFrame(_ coefIndex: Int, _ maxFrame: Double) -> Double {
        // If the maximum amplitude of the impulse response is less than this, we assume that we've reached the tail of
        // the response: 1 bit of a 16-bit PCM value.
        let maxTailAmplitude = 1 / 32768.0

        // Find the roots of 1+a1/z+a2/z^2 = 0. Or equivalently, z^2+a1*z+a2 = 0.
        let all = coefficients.span
        precondition(coefIndex >= 0 && coefIndex < biquadRenderQuantumSize)
        let a1 = all[Self.a1Start + coefIndex]
        let a2 = all[Self.a2Start + coefIndex]
        let b0 = all[Self.b0Start + coefIndex]
        let b1 = all[Self.b1Start + coefIndex]
        let b2 = all[Self.b2Start + coefIndex]

        let discrim = (-(4 * a2)).addingContractedProduct(a1, a1)
        if discrim > 0 {
            // Compute the real roots so that r1 has the largest magnitude.
            let rplus = (-a1 + discrim.squareRoot()) / 2
            let rminus = (-a1 - discrim.squareRoot()) / 2
            let r1 = abs(rplus) >= abs(rminus) ? rplus : rminus
            // Use the fact that a2 = r1*r2.
            let r2 = a2 / r1

            let c1 = ((b1 * r1).addingContractedProduct(b0 * r1, r1) + b2) / (r2 - r1)
            let c2 = ((b1 * r2).addingContractedProduct(b0 * r2, r2) + b2) / (r2 - r1)

            // It's possible for maxTailAmplitude to be greater than c1 + c2. This may produce a negative tail frame.
            // Just clamp the tail frame to 0.
            return Double(clampToIntFromZero(1 + log(maxTailAmplitude / (abs(c1) + abs(c2))) / log(abs(r1))))
        }

        if discrim < 0 {
            // Two complex roots. One root is -a1/2 + i*sqrt(-discrim)/2.
            let x = -a1 / 2
            let y = (-discrim).squareRoot() / 2
            let r1 = BiquadComplex(x, y)
            let r2 = BiquadComplex(x, -y)
            let r = hypot(x, y)

            var tailFrame = 0.0
            // It's possible for r to be 1. (LPF with Q very large can cause this.)
            if r == 1 {
                tailFrame = maxFrame
            } else {
                let c1 = ((b0 * r1 * r1 + b1 * r1 + b2) / (r2 - r1)).magnitude
                let c2 = ((b0 * r2 * r2 + b1 * r2 + b2) / (r2 - r1)).magnitude

                tailFrame = 1 + log(maxTailAmplitude / (c1 + c2)) / log(r)
                if c1 == 0 && c2 == 0 {
                    // If c1 = c2 = 0, then H(z) = b0. Hence, there's no tail because this is just a wire from input to output.
                    tailFrame = 0
                }
            }
            return tailFrame
        }

        // Repeated roots. This should be pretty rare because all the coefficients need to be just the right values to
        // get a discriminant of exactly zero.
        let r = -a1 / 2

        var tailFrame = 0.0
        if r == 0 {
            // Double pole at 0. This just delays the signal by 2 frames, so set the tail frame to 2.
            tailFrame = 2
        } else {
            let c1 = ((b1 * r).addingContractedProduct(b0 * r, r) + b2) / (r * r)
            let c2 = (2 * b2).addingContractedProduct(b1, r)

            // It can happen that c1=c2=0. This basically means that H(z) = constant, which is the limiting case for
            // several of the biquad filters.
            if c1 == 0 && c2 == 0 {
                tailFrame = 0
            } else {
                // The function c*(n+1)*r^n is not monotonic, but its derivative c*r^n*(1+(n+1)*log(r)) has a root at
                // -(1+log(r))/log(r), so the search starts from there up to maxFrame.
                let low = cppClamp(-(1 + log(r)) / log(r), 1.0, maxFrame - 1)
                let high = maxFrame

                tailFrame = Self.rootFinder(low, high, log(maxTailAmplitude), c1, c2, r)
            }
        }

        return tailFrame
    }

    // The log of the impulse response of the repeated-root filter at frame n, relative to eps: its root is where the
    // response equals eps.
    private static func repeatedRootResponse(_ n: Double, _ c1: Double, _ c2: Double, _ r: Double, _ logEPS: Double) -> Double {
        // The response is h(n) = r^(n-2)*[c1*(n+1)*r^2+c2]; the log of it is approximately linear for large n.
        log(abs(c2.addingContractedProduct(c1 * (n + 1) * r, r))).addingContractedProduct(n - 2, log(r)) - logEPS
    }

    // Regula Falsi root finder, Illinois variant, for a root of the repeated root response between `low` and `high`.
    private static func rootFinder(_ low: Double, _ high: Double, _ logEPS: Double, _ c1: Double, _ c2: Double, _ r: Double) -> Double {
        var low = low
        var high = high

        // Desired accuracy of the root (in frames). Less than 1 because the algorithm may prematurely terminate.
        let accuracyThreshold = 0.5
        // Max number of iterations to do. If we haven't converged by now, just return whatever we've found.
        let maxIterations = 10

        var side = 0
        var root = 0.0
        var fLow = repeatedRootResponse(low, c1, c2, r, logEPS)
        var fHigh = repeatedRootResponse(high, c1, c2, r, logEPS)

        for _ in 0..<maxIterations {
            root = (-(fHigh * low)).addingContractedProduct(fLow, high) / (fLow - fHigh)
            if abs(high - low) < accuracyThreshold * abs(high + low) {
                break
            }
            let fr = repeatedRootResponse(root, c1, c2, r, logEPS)

            if fr * fHigh > 0 {
                // fr and fHigh have same sign. Copy root to fHigh.
                high = root
                fHigh = fr
                side = -1
            } else if fLow * fr > 0 {
                // fr and fLow have same sign. Copy root to fLow.
                low = root
                fLow = fr
                if side == 1 {
                    fHigh /= 2
                }
                side = 1
            } else {
                // fLow * fr looks like zero, so assume we've converged.
                break
            }
        }

        return root
    }

    // MARK: BiquadDSPKernel

    // BiquadDSPKernel::updateTailTime
    mutating func updateTailTime(_ coefIndex: Int) {
        // A reasonable upper limit for the tail time. While it's easy to create biquad filters whose tail time can be
        // much larger than this, limit the maximum to this value so that we don't keep such nodes alive "forever".
        let maxTailTime = 30.0

        let sampleRate = Double(self.sampleRate)
        let tail = tailFrame(coefIndex, maxTailTime * sampleRate) / sampleRate

        tailTime = cppClamp(tail, 0.0, maxTailTime)
    }

    // BiquadDSPKernel::updateCoefficients.
    mutating func updateCoefficients(
        _ numberOfFrames: Int,
        _ type: WebCore.BiquadFilterType,
        _ cutoffFrequency: Span<Float>,
        _ q: Span<Float>,
        _ gain: Span<Float>,
        _ detune: Span<Float>
    ) {
        // Convert from Hertz to normalized frequency 0 -> 1.
        let nyquist = 0.5 * Double(sampleRate)

        hasSampleAccurateValues = numberOfFrames > 1

        // The frames each of q and gain is read for, checked once (production passes arrays of at least numberOfFrames).
        precondition(numberOfFrames <= q.count && numberOfFrames <= gain.count)
        // The coefficient runs hold a rendering quantum.
        precondition(numberOfFrames <= biquadRenderQuantumSize)

        var all = coefficients.mutableSpan

        for k in 0..<numberOfFrames {
            var normalizedFrequency = Double(cutoffFrequency[k]) / nyquist

            // Offset frequency by detune.
            if detune[k] != 0 {
                // Detune multiplies the frequency by 2^(detune[k] / 1200).
                normalizedFrequency *= Double(exp2f(detune[k] / 1200))
            }

            // Configure the biquad with the new filter parameters for the appropriate type of filter.
            let c: BiquadCoefficients
            switch type {
            case .Lowpass:
                c = Self.lowpassCoefficients(normalizedFrequency, Double(q[k]))
            case .Highpass:
                c = Self.highpassCoefficients(normalizedFrequency, Double(q[k]))
            case .Bandpass:
                c = Self.bandpassCoefficients(normalizedFrequency, Double(q[k]))
            case .Lowshelf:
                c = Self.lowShelfCoefficients(normalizedFrequency, Double(gain[k]))
            case .Highshelf:
                c = Self.highShelfCoefficients(normalizedFrequency, Double(gain[k]))
            case .Peaking:
                c = Self.peakingCoefficients(normalizedFrequency, Double(q[k]), Double(gain[k]))
            case .Notch:
                c = Self.notchCoefficients(normalizedFrequency, Double(q[k]))
            case .Allpass:
                c = Self.allpassCoefficients(normalizedFrequency, Double(q[k]))
            @unknown default:
                continue
            }
            all[Self.b0Start + k] = c.b0
            all[Self.b1Start + k] = c.b1
            all[Self.b2Start + k] = c.b2
            all[Self.a1Start + k] = c.a1
            all[Self.a2Start + k] = c.a2
        }

        updateTailTime(numberOfFrames &- 1) // wraps for 0 frames: the coefficient index then traps
    }
}

// BiquadDSPKernel.cpp's hasConstantValue: whether every value equals the first. A NaN is never equal, the first
// included.
@inline(always)
private func hasConstantValue(_ values: Span<Float>) -> Bool {
    let value = values[0]
    for i in 0..<values.count where values[i] != value {
        return false
    }
    return true
}

// MARK: - Entries

/// Makes the state of one channel's filter, passing the audio through.
@_expose(Cxx)
public func makeBiquadKernel(_ sampleRate: Float) -> BiquadKernel {
    BiquadKernel(sampleRate: sampleRate)
}

/// Filters `source` into `destination`, where they are different buffers: Biquad::process.
///
/// - `source` and `destination`: the C++ caller's channel memory (an AudioChannel's span, owned by its bus), allocated
///   at its length for the whole call. Nothing else reads or writes either during the call, and they do not overlap.
///   The elements are floats, so every bit pattern is a value.
///
/// FIXME: rdar://186723514 (receive a std::span safely).
@_expose(Cxx)
public func biquadProcess(_ k: inout BiquadKernel, _ source: FloatSpan, _ destination: MutableFloatSpan) {
    let source = unsafe Span<Float>(_unsafeCxxSpan: source)
    var destination = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    k.process(source, &destination)
}

/// Filters `buffer` in place: Biquad::process with the same source and destination.
///
/// - `buffer`: the C++ caller's channel memory (an AudioChannel's span, owned by its bus), allocated at its length for
///   the whole call. Nothing else reads or writes it during the call. The elements are floats, so every bit pattern
///   is a value.
///
/// FIXME: rdar://186723514 (receive a std::span safely).
@_expose(Cxx)
public func biquadProcessInPlace(_ k: inout BiquadKernel, _ buffer: MutableFloatSpan) {
    var buffer = unsafe MutableSpan<Float>(_unsafeCxxSpan: buffer)
    k.processInPlace(&buffer, buffer.count)
}

/// Computes the coefficients for the first `frames` frames from the four parameter arrays, and the tail time from the
/// last of them: BiquadDSPKernel::updateCoefficients. When `detectConstant` is set, `frames` is the length of the
/// arrays, and one set of coefficients is computed instead if every array holds one value.
///
/// - `cutoff`, `q`, `gain`, `detune`: arrays of the C++ caller (stack arrays of the kernel's gather, or single
///   values), allocated at their length for the whole call. Nothing writes them during the call. They are never
///   written by the filter. The elements are floats.
///
/// FIXME: rdar://186723514 (receive a std::span safely).
@_expose(Cxx)
public func biquadUpdateCoefficients(
    _ k: inout BiquadKernel,
    _ frames: Int,
    _ type: WebCore.BiquadFilterType,
    _ cutoff: FloatSpan,
    _ q: FloatSpan,
    _ gain: FloatSpan,
    _ detune: FloatSpan,
    _ detectConstant: Bool
) {
    let cutoff = unsafe Span<Float>(_unsafeCxxSpan: cutoff)
    let q = unsafe Span<Float>(_unsafeCxxSpan: q)
    let gain = unsafe Span<Float>(_unsafeCxxSpan: gain)
    let detune = unsafe Span<Float>(_unsafeCxxSpan: detune)
    var numberOfFrames = frames
    if detectConstant {
        // If all the values are actually constant for this render (or the automation rate is "k-rate" for all of the
        // AudioParams), the coefficients for each frame would be the same as the first.
        let isConstant = hasConstantValue(cutoff) && hasConstantValue(q) && hasConstantValue(gain) && hasConstantValue(detune)
        numberOfFrames = isConstant ? 1 : frames
    }
    k.updateCoefficients(numberOfFrames, type, cutoff, q, gain, detune)
}

/// Clears the filter memory: Biquad::reset.
@_expose(Cxx)
public func biquadReset(_ k: inout BiquadKernel) {
    k.reset()
}

/// BiquadDSPKernel::tailTime.
@_expose(Cxx)
public func biquadTailTime(_ k: borrowing BiquadKernel) -> Double {
    k.tailTime
}

/// The magnitude and phase response at `frequencyHz`: Biquad::getFrequencyResponse.
///
/// - `frequencyHz`: the C++ caller's array, allocated at its length for the whole call, written by no one. Floats.
/// - `magResponse`, `phaseResponse`: the C++ caller's arrays, at their length for the whole call, read and written by
///   no one else, and not overlapping each other or `frequencyHz`. Floats.
///
/// FIXME: rdar://186723514 (receive a std::span safely).
@_expose(Cxx)
public func biquadFrequencyResponse(
    _ k: borrowing BiquadKernel,
    _ frequencyHz: FloatSpan,
    _ magResponse: MutableFloatSpan,
    _ phaseResponse: MutableFloatSpan
) {
    let frequencyHz = unsafe Span<Float>(_unsafeCxxSpan: frequencyHz)
    var magResponse = unsafe MutableSpan<Float>(_unsafeCxxSpan: magResponse)
    var phaseResponse = unsafe MutableSpan<Float>(_unsafeCxxSpan: phaseResponse)
    k.getFrequencyResponse(frequencyHz, &magResponse, &phaseResponse, 0.5 * Double(k.sampleRate))
}

#endif
