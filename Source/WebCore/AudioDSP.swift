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

// Pull in JSC operator definitions before WebCore's C++ operators become visible (r02 trap).
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import wtf.Core.Stopwatch

internal import WebCore_Private.AudioDSPBoundaryTypes
import Accelerate

// MARK: - VectorMath
//
// Each @_expose(Cxx) entry point receives C++ std::span parameters.
// U1 conversion: the caller (C++ WebAudio nodes or VectorMath C++ wrappers) owns
// the underlying storage for the duration of the call; nothing else reads or writes
// the buffers concurrently; float/double have no invalid bit patterns.
// FIXME: rdar://186723514 tracks making these conversions safe.

/// out[i] += in[i] * scalar  (vDSP_vsma with output as addend)
@_expose(Cxx)
internal func vmMultiplyByScalarThenAddToOutput(
    _ input: AudioDSPSpanConstFloat, _ scalar: Float, _ output: AudioDSPSpanFloat
) {
    // FIXME: rdar://186723514
    let inSpan  = unsafe Span<Float>(_unsafeCxxSpan: input)
    var outSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    let n = inSpan.count
    guard n > 0 else { return }
    var s = scalar
    inSpan.withUnsafeBufferPointer { inp in
        outSpan.withUnsafeMutableBufferPointer { outp in
            unsafe vDSP_vsma(inp.baseAddress!, 1, &s,
                      outp.baseAddress!, 1,
                      outp.baseAddress!, 1, vDSP_Length(n))
        }
    }
}

/// out[i] = in1[i] * scalar + in2[i]
@_expose(Cxx)
internal func vmMultiplyByScalarThenAddToVector(
    _ input1: AudioDSPSpanConstFloat, _ scalar: Float,
    _ input2: AudioDSPSpanConstFloat, _ output: AudioDSPSpanFloat
) {
    let s1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let s2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    var so = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    let n = s1.count
    guard n > 0 else { return }
    var sc = scalar
    s1.withUnsafeBufferPointer { p1 in
        s2.withUnsafeBufferPointer { p2 in
            so.withUnsafeMutableBufferPointer { op in
                unsafe vDSP_vsma(p1.baseAddress!, 1, &sc,
                          p2.baseAddress!, 1,
                          op.baseAddress!, 1, vDSP_Length(n))
            }
        }
    }
}

/// out[i] = (in1[i] + in2[i]) * scalar
@_expose(Cxx)
internal func vmAddVectorsThenMultiplyByScalar(
    _ input1: AudioDSPSpanConstFloat, _ input2: AudioDSPSpanConstFloat,
    _ scalar: Float, _ output: AudioDSPSpanFloat
) {
    let s1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let s2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    var so = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    let n = s1.count
    guard n > 0 else { return }
    var sc = scalar
    s1.withUnsafeBufferPointer { p1 in
        s2.withUnsafeBufferPointer { p2 in
            so.withUnsafeMutableBufferPointer { op in
                unsafe vDSP_vasm(p1.baseAddress!, 1, p2.baseAddress!, 1, &sc,
                          op.baseAddress!, 1, vDSP_Length(n))
            }
        }
    }
}

@_expose(Cxx)
internal func vmMultiplyByScalar(
    _ input: AudioDSPSpanConstFloat, _ scalar: Float, _ output: AudioDSPSpanFloat
) {
    let si = unsafe Span<Float>(_unsafeCxxSpan: input)
    var so = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    let n = si.count
    guard n > 0 else { return }
    var sc = scalar
    si.withUnsafeBufferPointer { p in
        so.withUnsafeMutableBufferPointer { op in
            unsafe vDSP_vsmul(p.baseAddress!, 1, &sc, op.baseAddress!, 1, vDSP_Length(n))
        }
    }
}

@_expose(Cxx)
internal func vmAddScalar(
    _ input: AudioDSPSpanConstFloat, _ scalar: Float, _ output: AudioDSPSpanFloat
) {
    let si = unsafe Span<Float>(_unsafeCxxSpan: input)
    var so = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    let n = si.count
    guard n > 0 else { return }
    var sc = scalar
    si.withUnsafeBufferPointer { p in
        so.withUnsafeMutableBufferPointer { op in
            unsafe vDSP_vsadd(p.baseAddress!, 1, &sc, op.baseAddress!, 1, vDSP_Length(n))
        }
    }
}

/// "substract" — preserves C++ typo (R10).
@_expose(Cxx)
internal func vmSubstract(
    _ input1: AudioDSPSpanConstFloat, _ input2: AudioDSPSpanConstFloat, _ output: AudioDSPSpanFloat
) {
    let s1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let s2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    var so = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    let n = s1.count
    guard n > 0 else { return }
    s1.withUnsafeBufferPointer { p1 in
        s2.withUnsafeBufferPointer { p2 in
            so.withUnsafeMutableBufferPointer { op in
                unsafe vDSP_vsub(p1.baseAddress!, 1, p2.baseAddress!, 1, op.baseAddress!, 1, vDSP_Length(n))
            }
        }
    }
}

@_expose(Cxx)
internal func vmAddFloat(
    _ input1: AudioDSPSpanConstFloat, _ input2: AudioDSPSpanConstFloat, _ output: AudioDSPSpanFloat
) {
    let s1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let s2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    var so = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    let n = s1.count
    guard n > 0 else { return }
    s1.withUnsafeBufferPointer { p1 in
        s2.withUnsafeBufferPointer { p2 in
            so.withUnsafeMutableBufferPointer { op in
                unsafe vDSP_vadd(p1.baseAddress!, 1, p2.baseAddress!, 1, op.baseAddress!, 1, vDSP_Length(n))
            }
        }
    }
}

@_expose(Cxx)
internal func vmAddDouble(
    _ input1: AudioDSPSpanConstDouble, _ input2: AudioDSPSpanConstDouble, _ output: AudioDSPSpanDouble
) {
    let s1 = unsafe Span<Double>(_unsafeCxxSpan: input1)
    let s2 = unsafe Span<Double>(_unsafeCxxSpan: input2)
    var so = unsafe MutableSpan<Double>(_unsafeCxxSpan: output)
    let n = s1.count
    guard n > 0 else { return }
    s1.withUnsafeBufferPointer { p1 in
        s2.withUnsafeBufferPointer { p2 in
            so.withUnsafeMutableBufferPointer { op in
                unsafe vDSP_vaddD(p1.baseAddress!, 1, p2.baseAddress!, 1, op.baseAddress!, 1, vDSP_Length(n))
            }
        }
    }
}

@_expose(Cxx)
internal func vmMultiply(
    _ input1: AudioDSPSpanConstFloat, _ input2: AudioDSPSpanConstFloat, _ output: AudioDSPSpanFloat
) {
    let s1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let s2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    var so = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    let n = s1.count
    guard n > 0 else { return }
    s1.withUnsafeBufferPointer { p1 in
        s2.withUnsafeBufferPointer { p2 in
            so.withUnsafeMutableBufferPointer { op in
                unsafe vDSP_vmul(p1.baseAddress!, 1, p2.baseAddress!, 1, op.baseAddress!, 1, vDSP_Length(n))
            }
        }
    }
}

@_expose(Cxx)
internal func vmDotProduct(_ input1: AudioDSPSpanConstFloat, _ input2: AudioDSPSpanConstFloat) -> Float {
    let s1 = unsafe Span<Float>(_unsafeCxxSpan: input1)
    let s2 = unsafe Span<Float>(_unsafeCxxSpan: input2)
    let n = s1.count
    guard n > 0 else { return 0 }
    var result: Float = 0
    s1.withUnsafeBufferPointer { p1 in
        s2.withUnsafeBufferPointer { p2 in
            unsafe vDSP_dotpr(p1.baseAddress!, 1, p2.baseAddress!, 1, &result, vDSP_Length(n))
        }
    }
    return result
}

@_expose(Cxx)
internal func vmMaximumMagnitude(_ input: AudioDSPSpanConstFloat) -> Float {
    let si = unsafe Span<Float>(_unsafeCxxSpan: input)
    let n = si.count
    guard n > 0 else { return 0 }
    var result: Float = 0
    si.withUnsafeBufferPointer { p in
        unsafe vDSP_maxmgv(p.baseAddress!, 1, &result, vDSP_Length(n))
    }
    return result
}

@_expose(Cxx)
internal func vmSumOfSquares(_ input: AudioDSPSpanConstFloat) -> Float {
    let si = unsafe Span<Float>(_unsafeCxxSpan: input)
    let n = si.count
    guard n > 0 else { return 0 }
    var result: Float = 0
    // vDSP_svesq takes a non-const pointer; the C++ implementation const_casts similarly.
    si.withUnsafeBufferPointer { p in
        // Working around vDSP_svesq's non-const signature.
        var buf = unsafe Array<Float>(p)
        unsafe vDSP_svesq(&buf, 1, &result, vDSP_Length(n))
    }
    return result
}

@_expose(Cxx)
internal func vmMultiplyComplex(
    _ real1: AudioDSPSpanConstFloat, _ imag1: AudioDSPSpanConstFloat,
    _ real2: AudioDSPSpanConstFloat, _ imag2: AudioDSPSpanConstFloat,
    _ realOut: AudioDSPSpanFloat, _ imagOut: AudioDSPSpanFloat
) {
    let sr1 = unsafe Span<Float>(_unsafeCxxSpan: real1)
    let si1 = unsafe Span<Float>(_unsafeCxxSpan: imag1)
    let sr2 = unsafe Span<Float>(_unsafeCxxSpan: real2)
    let si2 = unsafe Span<Float>(_unsafeCxxSpan: imag2)
    var sro = unsafe MutableSpan<Float>(_unsafeCxxSpan: realOut)
    var sio = unsafe MutableSpan<Float>(_unsafeCxxSpan: imagOut)
    let n = sr1.count
    guard n > 0 else { return }
    _ = sr1.withUnsafeBufferPointer { pr1 in
        _ = si1.withUnsafeBufferPointer { pi1 in
            _ = sr2.withUnsafeBufferPointer { pr2 in
                _ = si2.withUnsafeBufferPointer { pi2 in
                    _ = sro.withUnsafeMutableBufferPointer { pro in
                        _ = sio.withUnsafeMutableBufferPointer { pio in
                            var sc1 = unsafe DSPSplitComplex(
                                realp: unsafe UnsafeMutablePointer(mutating: pr1.baseAddress!),
                                imagp: unsafe UnsafeMutablePointer(mutating: pi1.baseAddress!))
                            var sc2 = unsafe DSPSplitComplex(
                                realp: unsafe UnsafeMutablePointer(mutating: pr2.baseAddress!),
                                imagp: unsafe UnsafeMutablePointer(mutating: pi2.baseAddress!))
                            var dest = unsafe DSPSplitComplex(
                                realp: unsafe pro.baseAddress!, imagp: unsafe pio.baseAddress!)
                            unsafe vDSP_zvmul(&sc1, 1, &sc2, 1, &dest, 1, vDSP_Length(n), 1)
                        }
                    }
                }
            }
        }
    }
}

@_expose(Cxx)
internal func vmClamp(
    _ input: AudioDSPSpanConstFloat, _ minimum: Float, _ maximum: Float, _ output: AudioDSPSpanFloat
) {
    let si = unsafe Span<Float>(_unsafeCxxSpan: input)
    var so = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    let n = si.count
    guard n > 0 else { return }
    // vDSP_vclip takes non-const input.
    si.withUnsafeBufferPointer { p in
        so.withUnsafeMutableBufferPointer { op in
            var lo = minimum, hi = maximum
            var buf = unsafe Array<Float>(p)
            unsafe vDSP_vclip(&buf, 1, &lo, &hi, op.baseAddress!, 1, vDSP_Length(n))
        }
    }
}

@_expose(Cxx)
internal func vmLinearToDecibels(_ input: AudioDSPSpanConstFloat, _ output: AudioDSPSpanFloat) {
    let si = unsafe Span<Float>(_unsafeCxxSpan: input)
    var so = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    let n = si.count
    guard n > 0 else { return }
    var ref: Float = 1
    si.withUnsafeBufferPointer { p in
        so.withUnsafeMutableBufferPointer { op in
            unsafe vDSP_vdbcon(p.baseAddress!, 1, &ref, op.baseAddress!, 1, vDSP_Length(n), 1)
        }
    }
}

@_expose(Cxx)
internal func vmInterpolate(
    _ input1: AudioDSPSpanConstFloat, _ input2: AudioDSPSpanFloat,
    _ factor: Float, _ output: AudioDSPSpanFloat
) {
    let s1  = unsafe Span<Float>(_unsafeCxxSpan: input1)
    var s2  = unsafe MutableSpan<Float>(_unsafeCxxSpan: input2)
    var so  = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    let n = s1.count
    guard n > 0 else { return }
    var f = factor
    s1.withUnsafeBufferPointer { p1 in
        s2.withUnsafeMutableBufferPointer { p2 in
            so.withUnsafeMutableBufferPointer { op in
                unsafe vDSP_vintb(p1.baseAddress!, 1, p2.baseAddress!, 1, &f, op.baseAddress!, 1, vDSP_Length(n))
            }
        }
    }
}

/// filterBiquad: vDSP_deq22D; source and destination each start with 2 history samples.
@_expose(Cxx)
internal func vmFilterBiquad(
    _ source: AudioDSPSpanConstDouble, _ coef: AudioDSPSpanConstDouble,
    _ destination: AudioDSPSpanDouble, _ framesToProcess: Int32
) {
    let frames = Int(framesToProcess)
    guard frames > 0 else { return }
    let ssrc  = unsafe Span<Double>(_unsafeCxxSpan: source)
    let scoef = unsafe Span<Double>(_unsafeCxxSpan: coef)
    var sdst  = unsafe MutableSpan<Double>(_unsafeCxxSpan: destination)
    ssrc.withUnsafeBufferPointer { psrc in
        scoef.withUnsafeBufferPointer { pcoef in
            sdst.withUnsafeMutableBufferPointer { pdst in
                unsafe vDSP_deq22D(psrc.baseAddress!, 1, pcoef.baseAddress!, pdst.baseAddress!, 1, vDSP_Length(frames))
            }
        }
    }
}

/// convolve: output[n] = sum(signal[n+k] * filter[filter.size()-1-k])
@_expose(Cxx)
internal func vmConvolve(
    _ signal: AudioDSPSpanConstFloat, _ filter: AudioDSPSpanConstFloat, _ output: AudioDSPSpanFloat
) {
    let ssig = unsafe Span<Float>(_unsafeCxxSpan: signal)
    let sfil = unsafe Span<Float>(_unsafeCxxSpan: filter)
    var sout = unsafe MutableSpan<Float>(_unsafeCxxSpan: output)
    let outN = sout.count
    let filN = sfil.count
    guard outN > 0, filN > 0 else { return }
    ssig.withUnsafeBufferPointer { psig in
        sfil.withUnsafeBufferPointer { pfil in
            sout.withUnsafeMutableBufferPointer { pout in
                // Read filter backwards from its last element.
                let filterLast = unsafe (pfil.baseAddress! + (filN - 1))
                unsafe vDSP_conv(psig.baseAddress!, 1, filterLast, -1,
                          pout.baseAddress!, 1, vDSP_Length(outN), vDSP_Length(filN))
            }
        }
    }
}

// MARK: - Biquad
//
// The C++ Biquad class holds coefficient arrays and per-call filter history.
// The shim in Biquad.cpp passes:
//   - scalars b0..a2: the [0]-th entry (block path uses a single coefficient set)
//   - spans b0Buf..a2Buf: the coefficient arrays (sample-accurate path uses [k]-th entry per frame)
//   - scalars x1, x2, y1, y2: the history read in
//   - inout x1, x2, y1, y2: the history written out
//
// The caller (Biquad::process in Biquad.cpp) owns all storage for the call;
// nothing else writes it; Double has no invalid bit patterns.
// FIXME: rdar://186723514

private let kBiquadBufferSize = 512  // matches Biquad.cpp kBufferSize

@_expose(Cxx)
internal func biquadProcess(
    _ source: AudioDSPSpanConstFloat, _ destination: AudioDSPSpanFloat,
    _ b0: Double, _ b1: Double, _ b2: Double, _ a1: Double, _ a2: Double,
    _ x1In: Double, _ x2In: Double, _ y1In: Double, _ y2In: Double,
    _ hasSampleAccurateValues: Bool,
    _ b0Buf: AudioDSPSpanConstDouble, _ b1Buf: AudioDSPSpanConstDouble,
    _ b2Buf: AudioDSPSpanConstDouble, _ a1Buf: AudioDSPSpanConstDouble,
    _ a2Buf: AudioDSPSpanConstDouble,
    _ outX1: inout Double, _ outX2: inout Double,
    _ outY1: inout Double, _ outY2: inout Double
) {
    let ssrc = unsafe Span<Float>(_unsafeCxxSpan: source)
    var sdst = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    let n = ssrc.count
    guard n > 0 else { return }

    if hasSampleAccurateValues {
        // Per-sample DF1 using per-frame coefficient arrays.
        // Copy C++ spans into local Swift arrays.
        let sb0 = unsafe Span<Double>(_unsafeCxxSpan: b0Buf)
        let sb1 = unsafe Span<Double>(_unsafeCxxSpan: b1Buf)
        let sb2 = unsafe Span<Double>(_unsafeCxxSpan: b2Buf)
        let sa1 = unsafe Span<Double>(_unsafeCxxSpan: a1Buf)
        let sa2 = unsafe Span<Double>(_unsafeCxxSpan: a2Buf)
        let b0arr: [Double] = sb0.withUnsafeBufferPointer { buf in unsafe Array(buf) }
        let b1arr: [Double] = sb1.withUnsafeBufferPointer { buf in unsafe Array(buf) }
        let b2arr: [Double] = sb2.withUnsafeBufferPointer { buf in unsafe Array(buf) }
        let a1arr: [Double] = sa1.withUnsafeBufferPointer { buf in unsafe Array(buf) }
        let a2arr: [Double] = sa2.withUnsafeBufferPointer { buf in unsafe Array(buf) }
        var lx1 = x1In, lx2 = x2In, ly1 = y1In, ly2 = y2In
        _ = ssrc.withUnsafeBufferPointer { psrc in
            _ = sdst.withUnsafeMutableBufferPointer { pdst in
                for k in 0 ..< n {
                    let x = Double(unsafe psrc[k])
                    let y: Double = b0arr[k] * x + b1arr[k] * lx1 + b2arr[k] * lx2 - a1arr[k] * ly1 - a2arr[k] * ly2
                    let yFloat = Float(y)
                    unsafe pdst[k] = yFloat
                    lx2 = lx1; lx1 = x; ly2 = ly1; ly1 = Double(yFloat)
                }
            }
        }
        outX1 = flushDenormal(lx1); outX2 = flushDenormal(lx2)
        outY1 = flushDenormal(ly1); outY2 = flushDenormal(ly2)
    } else {
        // Block path: vDSP_deq22D via double-precision input/output buffers.
        // Each buffer holds [history0, history1, frame0, frame1, ...].
        var inputBuf  = [Double](repeating: 0, count: kBiquadBufferSize + 2)
        var outputBuf = [Double](repeating: 0, count: kBiquadBufferSize + 2)
        let coeff: [Double] = [b0, b1, b2, a1, a2]
        inputBuf[0] = x2In; inputBuf[1] = x1In
        outputBuf[0] = y2In; outputBuf[1] = y1In
        var lastY1Float: Float = Float(y1In)
        var lastY2Float: Float = Float(y2In)
        ssrc.withUnsafeBufferPointer { psrc in
            sdst.withUnsafeMutableBufferPointer { pdst in
                var remaining = n, srcOff = 0, dstOff = 0
                while remaining > 0 {
                    let chunk = min(remaining, kBiquadBufferSize)
                    for i in 0 ..< chunk { inputBuf[i + 2] = Double(unsafe psrc[srcOff + i]) }
                    unsafe vDSP_deq22D(inputBuf, 1, coeff, &outputBuf, 1, vDSP_Length(chunk))
                    for i in 0 ..< chunk { unsafe pdst[dstOff + i] = Float(outputBuf[i + 2]) }
                    // Save last two float outputs for history (C++ saves float-quantized history).
                    if chunk >= 2 {
                        lastY2Float = Float(outputBuf[chunk])
                        lastY1Float = Float(outputBuf[chunk + 1])
                    } else if chunk == 1 {
                        lastY2Float = lastY1Float
                        lastY1Float = Float(outputBuf[3])
                    }
                    inputBuf[0] = inputBuf[chunk]; inputBuf[1] = inputBuf[chunk + 1]
                    outputBuf[0] = outputBuf[chunk]; outputBuf[1] = outputBuf[chunk + 1]
                    srcOff += chunk; dstOff += chunk; remaining -= chunk
                }
            }
        }
        // X history from input buffer (double precision).
        // Y history from float-quantized destination (matching C++ Biquad::process behaviour, R10).
        outX2 = inputBuf[0];  outX1 = inputBuf[1]
        outY1 = Double(lastY1Float); outY2 = Double(lastY2Float)
    }
}

@_expose(Cxx)
internal func biquadReset(
    _ outX1: inout Double, _ outX2: inout Double,
    _ outY1: inout Double, _ outY2: inout Double
) {
    outX1 = 0; outX2 = 0; outY1 = 0; outY2 = 0
}

@_expose(Cxx)
internal func biquadSetNormalizedCoefficients(
    _ index: Int32,
    _ b0: Double, _ b1: Double, _ b2: Double, _ a1: Double, _ a2: Double,
    _ b0Buf: AudioDSPSpanDouble, _ b1Buf: AudioDSPSpanDouble, _ b2Buf: AudioDSPSpanDouble,
    _ a1Buf: AudioDSPSpanDouble, _ a2Buf: AudioDSPSpanDouble
) {
    let i = Int(index)
    // Direct write through MutableSpan subscript.
    var s0 = unsafe MutableSpan<Double>(_unsafeCxxSpan: b0Buf)
    var s1 = unsafe MutableSpan<Double>(_unsafeCxxSpan: b1Buf)
    var s2 = unsafe MutableSpan<Double>(_unsafeCxxSpan: b2Buf)
    var s3 = unsafe MutableSpan<Double>(_unsafeCxxSpan: a1Buf)
    var s4 = unsafe MutableSpan<Double>(_unsafeCxxSpan: a2Buf)
    s0[i] = b0
    s1[i] = b1
    s2[i] = b2
    s3[i] = a1
    s4[i] = a2
}

@_expose(Cxx)
internal func biquadGetFrequencyResponse(
    _ freqHz: AudioDSPSpanConstFloat, _ magResponse: AudioDSPSpanFloat,
    _ phaseResponse: AudioDSPSpanFloat, _ nyquist: Double,
    _ b0Buf: AudioDSPSpanConstDouble, _ b1Buf: AudioDSPSpanConstDouble,
    _ b2Buf: AudioDSPSpanConstDouble, _ a1Buf: AudioDSPSpanConstDouble,
    _ a2Buf: AudioDSPSpanConstDouble
) {
    let sfq  = unsafe Span<Float>(_unsafeCxxSpan: freqHz)
    var smag = unsafe MutableSpan<Float>(_unsafeCxxSpan: magResponse)
    var sph  = unsafe MutableSpan<Float>(_unsafeCxxSpan: phaseResponse)
    let count = sfq.count
    guard count > 0 else { return }
    let sb0 = unsafe Span<Double>(_unsafeCxxSpan: b0Buf)
    let sb1 = unsafe Span<Double>(_unsafeCxxSpan: b1Buf)
    let sb2 = unsafe Span<Double>(_unsafeCxxSpan: b2Buf)
    let sa1 = unsafe Span<Double>(_unsafeCxxSpan: a1Buf)
    let sa2 = unsafe Span<Double>(_unsafeCxxSpan: a2Buf)
    sfq.withUnsafeBufferPointer { pfq in
        smag.withUnsafeMutableBufferPointer { pmag in
            sph.withUnsafeMutableBufferPointer { pph in
                sb0.withUnsafeBufferPointer { pb0 in
                sb1.withUnsafeBufferPointer { pb1 in
                sb2.withUnsafeBufferPointer { pb2 in
                sa1.withUnsafeBufferPointer { pa1 in
                sa2.withUnsafeBufferPointer { pa2 in
                    let b0 = unsafe pb0[0], b1 = unsafe pb1[0], b2 = unsafe pb2[0]
                    let a1 = unsafe pa1[0], a2 = unsafe pa2[0]
                    for k in 0 ..< count {
                        // C++: float frequency = static_cast<float>(frequencyHz[k] / nyquist); — float truncation.
                        let freqF = Float(Double(unsafe pfq[k]) / nyquist)
                        if freqF < 0 || freqF > 1 { unsafe pmag[k] = .nan; unsafe pph[k] = .nan; continue }
                        let omega = -Double.pi * Double(freqF)
                        let zr = cos(omega), zi = sin(omega)
                        let nr = b0 + b1 * zr + b2 * (zr * zr - zi * zi)
                        let ni = b1 * zi + b2 * (2 * zr * zi)
                        let dr = 1 + a1 * zr + a2 * (zr * zr - zi * zi)
                        let di = a1 * zi + a2 * (2 * zr * zi)
                        let denom = dr * dr + di * di
                        let respR = (nr * dr + ni * di) / denom
                        let respI = (ni * dr - nr * di) / denom
                        // C++ computes biquadMagnitude before sqrt, replicating NaN on 0/0 (R10).
                        let biquadMagnitude = (nr * nr + ni * ni) / (dr * dr + di * di)
                        unsafe pmag[k] = Float(biquadMagnitude.squareRoot())
                        unsafe pph[k]  = Float(atan2(respI, respR))
                    }
                }}}}}
            }
        }
    }
}

@_expose(Cxx)
internal func biquadTailFrame(
    _ coefIndex: Int32, _ maxFrame: Double,
    _ b0Buf: AudioDSPSpanConstDouble, _ b1Buf: AudioDSPSpanConstDouble,
    _ b2Buf: AudioDSPSpanConstDouble, _ a1Buf: AudioDSPSpanConstDouble,
    _ a2Buf: AudioDSPSpanConstDouble
) -> Double {
    let idx = Int(coefIndex)
    let sb0 = unsafe Span<Double>(_unsafeCxxSpan: b0Buf)
    let sb1 = unsafe Span<Double>(_unsafeCxxSpan: b1Buf)
    let sb2 = unsafe Span<Double>(_unsafeCxxSpan: b2Buf)
    let sa1 = unsafe Span<Double>(_unsafeCxxSpan: a1Buf)
    let sa2 = unsafe Span<Double>(_unsafeCxxSpan: a2Buf)
    var result = 0.0
    sb0.withUnsafeBufferPointer { pb0 in sb1.withUnsafeBufferPointer { pb1 in
    sb2.withUnsafeBufferPointer { pb2 in sa1.withUnsafeBufferPointer { pa1 in
    sa2.withUnsafeBufferPointer { pa2 in
        let b0 = unsafe pb0[idx], b1 = unsafe pb1[idx], b2 = unsafe pb2[idx]
        let a1 = unsafe pa1[idx], a2 = unsafe pa2[idx]
        let threshold = 1.0 / 32768.0
        var lx1 = 0.0, lx2 = 0.0, ly1 = 0.0, ly2 = 0.0
        let maxF = Int(maxFrame)
        for f in 0 ..< maxF {
            let x = f == 0 ? 1.0 : 0.0
            var y = b0 * x; y.addProduct(b1, lx1); y.addProduct(b2, lx2)
            y.addProduct(-a1, ly1); y.addProduct(-a2, ly2)
            lx2 = lx1; lx1 = x; ly2 = ly1; ly1 = y
            if abs(y) >= threshold { result = Double(f) }
        }
    }}}}}
    return result
}

// MARK: - IIRFilter
//
// Direct Form I IIR filter. The C++ IIRProcessor calls IIRFilter::process() which
// now dispatches here. xBuf/yBuf are circular delay buffers (size = power of 2).
// outBufferIndex is the write index, passed by reference.
// Caller owns all buffers for the duration of the call.
// FIXME: rdar://186723514

@_expose(Cxx)
internal func iirProcess(
    _ source: AudioDSPSpanConstFloat, _ destination: AudioDSPSpanFloat,
    _ feedforward: AudioDSPSpanConstDouble, _ feedback: AudioDSPSpanConstDouble,
    _ xBuf: AudioDSPSpanDouble, _ yBuf: AudioDSPSpanDouble,
    _ bufferIndex: Int32, _ outBufferIndex: inout Int32
) {
    let ssrc = unsafe Span<Float>(_unsafeCxxSpan: source)
    var sdst = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    let sff  = unsafe Span<Double>(_unsafeCxxSpan: feedforward)
    let sfb  = unsafe Span<Double>(_unsafeCxxSpan: feedback)
    var sxb  = unsafe MutableSpan<Double>(_unsafeCxxSpan: xBuf)
    var syb  = unsafe MutableSpan<Double>(_unsafeCxxSpan: yBuf)
    let n = ssrc.count
    guard n > 0 else { return }
    ssrc.withUnsafeBufferPointer { psrc in
        sdst.withUnsafeMutableBufferPointer { pdst in
            sff.withUnsafeBufferPointer { pff in
                sfb.withUnsafeBufferPointer { pfb in
                    sxb.withUnsafeMutableBufferPointer { pxb in
                        syb.withUnsafeMutableBufferPointer { pyb in
                            let ffLen = pff.count, fbLen = pfb.count
                            let minLen = min(ffLen, fbLen)
                            let bufLen = pxb.count  // must be power-of-2
                            let mask = bufLen - 1
                            var idx = Int(bufferIndex)
                            for s in 0 ..< n {
                                var yn = unsafe pff[0] * Double(unsafe psrc[s])
                                for k in 1 ..< minLen {
                                    let m = (idx &- k) & mask
                                    // Use addProduct (FMA) to match C++ fmadd/fmsub.
                                    yn.addProduct(unsafe pff[k], unsafe pxb[m])
                                    yn.addProduct(-(unsafe pfb[k]), unsafe pyb[m])
                                }
                                for k in minLen ..< ffLen { yn.addProduct(unsafe pff[k], unsafe pxb[(idx &- k) & mask]) }
                                for k in minLen ..< fbLen { yn.addProduct(-(unsafe pfb[k]), unsafe pyb[(idx &- k) & mask]) }
                                unsafe pxb[idx] = Double(unsafe psrc[s])
                                unsafe pyb[idx] = yn
                                idx = (idx &+ 1) & mask
                                unsafe pdst[s] = Float(yn)
                            }
                            outBufferIndex = Int32(idx)
                        }
                    }
                }
            }
        }
    }
}

@_expose(Cxx)
internal func iirReset(
    _ xBuf: AudioDSPSpanDouble, _ yBuf: AudioDSPSpanDouble,
    _ outBufferIndex: inout Int32
) {
    var sxb = unsafe MutableSpan<Double>(_unsafeCxxSpan: xBuf)
    var syb = unsafe MutableSpan<Double>(_unsafeCxxSpan: yBuf)
    sxb.withUnsafeMutableBufferPointer { p in for i in 0 ..< p.count { unsafe p[i] = 0 } }
    syb.withUnsafeMutableBufferPointer { p in for i in 0 ..< p.count { unsafe p[i] = 0 } }
    outBufferIndex = 0
}

@_expose(Cxx)
internal func iirGetFrequencyResponse(
    _ freqHz: AudioDSPSpanConstFloat, _ magResponse: AudioDSPSpanFloat,
    _ phaseResponse: AudioDSPSpanFloat, _ nyquist: Double,
    _ feedforward: AudioDSPSpanConstDouble, _ feedback: AudioDSPSpanConstDouble
) {
    let sfq  = unsafe Span<Float>(_unsafeCxxSpan: freqHz)
    var smag = unsafe MutableSpan<Float>(_unsafeCxxSpan: magResponse)
    var sph  = unsafe MutableSpan<Float>(_unsafeCxxSpan: phaseResponse)
    let count = sfq.count
    guard count > 0 else { return }
    let sff = unsafe Span<Double>(_unsafeCxxSpan: feedforward)
    let sfb = unsafe Span<Double>(_unsafeCxxSpan: feedback)
    sfq.withUnsafeBufferPointer { pfq in
        smag.withUnsafeMutableBufferPointer { pmag in
            sph.withUnsafeMutableBufferPointer { pph in
                sff.withUnsafeBufferPointer { pff in
                    sfb.withUnsafeBufferPointer { pfb in
                        let ffLen = pff.count, fbLen = pfb.count
                        guard ffLen > 0 && fbLen > 0 else { return }
                        for k in 0 ..< count {
                            let freqF = Float(Double(unsafe pfq[k]) / nyquist)
                            if freqF < 0 || freqF > 1 {
                                unsafe pmag[k] = .nan; unsafe pph[k] = .nan; continue
                            }
                            let omega = -Double.pi * Double(freqF)
                            let zr = cos(omega), zi = sin(omega)
                            // Horner's method (matching C++ evaluatePolynomial, high-to-low).
                            var nr = unsafe pff[ffLen - 1]; var ni = 0.0
                            for j in stride(from: ffLen - 2, through: 0, by: -1) {
                                let coef = unsafe pff[j]
                                let newR = nr * zr - ni * zi + coef
                                ni = nr * zi + ni * zr
                                nr = newR
                            }
                            var dr = unsafe pfb[fbLen - 1]; var di = 0.0
                            for j in stride(from: fbLen - 2, through: 0, by: -1) {
                                let coef = unsafe pfb[j]
                                let newR = dr * zr - di * zi + coef
                                di = dr * zi + di * zr
                                dr = newR
                            }
                            let denom = dr * dr + di * di
                            let respR = (nr * dr + ni * di) / denom
                            let respI = (ni * dr - nr * di) / denom
                            unsafe pmag[k] = Float((respR * respR + respI * respI).squareRoot())
                            unsafe pph[k]  = Float(atan2(respI, respR))
                        }
                    }
                }
            }
        }
    }
}

@_expose(Cxx)
internal func iirTailTime(
    _ sampleRate: Double, _ isFilterStable: Bool,
    _ feedforward: AudioDSPSpanConstDouble, _ feedback: AudioDSPSpanConstDouble
) -> Double {
    guard isFilterStable else { return 10.0 }
    let sff = unsafe Span<Double>(_unsafeCxxSpan: feedforward)
    let sfb = unsafe Span<Double>(_unsafeCxxSpan: feedback)
    var tail = 0.0
    sff.withUnsafeBufferPointer { pff in
        sfb.withUnsafeBufferPointer { pfb in
            let ffLen = pff.count, fbLen = pfb.count, minLen = min(ffLen, fbLen)
            let bufLen = 16, mask = bufLen - 1
            var xBuf = [Double](repeating: 0, count: bufLen)
            var yBuf = [Double](repeating: 0, count: bufLen)
            var idx = 0
            let maxFrames = Int(10.0 * sampleRate)
            let amp = 1.0 / 32768.0
            for f in 0 ..< maxFrames {
                let inp = f == 0 ? 1.0 : 0.0
                let pff0 = unsafe pff[0]; var yn = pff0 * inp
                for k in 1 ..< minLen { let m = (idx &- k) & mask; let pK = unsafe pff[k]; let xM = unsafe xBuf[m]; let pfK = unsafe pfb[k]; let yM = unsafe yBuf[m]; yn += pK * xM; yn -= pfK * yM }
                for k in minLen ..< ffLen { let pK = unsafe pff[k]; let xM = unsafe xBuf[(idx &- k) & mask]; yn += pK * xM }
                for k in minLen ..< fbLen { let pfK = unsafe pfb[k]; let yM = unsafe yBuf[(idx &- k) & mask]; yn -= pfK * yM }
                xBuf[idx] = inp; yBuf[idx] = yn; idx = (idx &+ 1) & mask
                if abs(yn) >= amp { tail = Double(f) }
            }
        }
    }
    return tail / sampleRate
}

// MARK: - DynamicsCompressor
// DynamicsCompressorKernel.cpp handles the gate-on path entirely in C++.
// These stubs satisfy the linker but are never called.

@_expose(Cxx)
internal func dcProcess(
    _ srcL: AudioDSPSpanConstFloat, _ srcR: AudioDSPSpanConstFloat,
    _ dstL: AudioDSPSpanFloat, _ dstR: AudioDSPSpanFloat,
    _ nFrames: UInt32, _ dbThreshold: Float, _ dbKnee: Float,
    _ ratio: Float, _ attackTime: Float, _ releaseTime: Float,
    _ preDelayTime: Float, _ dbPostGain: Float, _ effectBlend: Float,
    _ releaseZone1: Float, _ releaseZone2: Float,
    _ releaseZone3: Float, _ releaseZone4: Float
) { }

@_expose(Cxx)
internal func dcReset() { }

// MARK: - ZeroPole
//
// First-order IIR: zero at `zero`, pole at `pole`, with gain normalisation.
// State (lastX, lastY) passes in as scalars, returns via inout.
// FIXME: rdar://186723514

@_expose(Cxx)
internal func zeroPoleProcess(
    _ source: AudioDSPSpanConstFloat, _ destination: AudioDSPSpanFloat,
    _ nFrames: UInt32, _ zero: Float, _ pole: Float,
    _ lastX: Float, _ lastY: Float,
    _ outLastX: inout Float, _ outLastY: inout Float
) {
    let n = Int(nFrames)
    guard n > 0 else { return }
    let ssrc = unsafe Span<Float>(_unsafeCxxSpan: source)
    var sdst = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    let k1 = 1.0 / (1.0 - zero)
    let k2 = 1.0 - pole
    var lx = lastX, ly = lastY
    ssrc.withUnsafeBufferPointer { psrc in
        sdst.withUnsafeMutableBufferPointer { pdst in
            for i in 0 ..< n {
                let inp = unsafe psrc[i]
                // Match C++ fmsub + fmul + fmul + fmadd instruction sequence.
                var numer = inp; numer.addProduct(-zero, lx)  // numer = inp - zero*lx (fmsub)
                let out1 = k1 * numer
                lx = inp
                var out2 = pole * ly; out2.addProduct(k2, out1)  // out2 = k2*out1 + pole*ly (fmul then fmadd)
                ly = out2
                unsafe pdst[i] = out2
            }
        }
    }
    outLastX = flushDenormalFloat(lx)
    outLastY = flushDenormalFloat(ly)
}

// MARK: - EqualPowerPanner
//
// Computes per-channel equal-power gains and scales channels.
// Azimuth aliasing: -180..-90 mirrors to -90..0; 90..180 mirrors to 90..0.
// Mono source: one channel scaled to both outputs.
// Stereo source: azimuth <= 0 crossfades left into right, az > 0 left into right.
// FIXME: rdar://186723514

private let kPiOverTwo = Double.pi / 2.0

@_expose(Cxx)
internal func eppPan(
    _ azimuth: Double, _ nInputChannels: UInt32,
    _ srcL: AudioDSPSpanConstFloat, _ srcR: AudioDSPSpanConstFloat,
    _ dstL: AudioDSPSpanFloat, _ dstR: AudioDSPSpanFloat,
    _ nFrames: Int32
) {
    let n = Int(nFrames)
    guard n > 0 else { return }
    var az = max(-180.0, min(180.0, azimuth))
    if az < -90 { az = -180 - az } else if az > 90 { az = 180 - az }
    let nCh = Int(nInputChannels)
    let pos = nCh == 1 ? (az + 90) / 180 : (az <= 0 ? (az + 90) / 90 : az / 90)
    let gainL = Float(cos(kPiOverTwo * pos))
    let gainR = Float(sin(kPiOverTwo * pos))
    let ssl = unsafe Span<Float>(_unsafeCxxSpan: srcL)
    let ssr = unsafe Span<Float>(_unsafeCxxSpan: srcR)
    var sdl = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstL)
    var sdr = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstR)
    ssl.withUnsafeBufferPointer { psl in ssr.withUnsafeBufferPointer { psr in
        sdl.withUnsafeMutableBufferPointer { pdl in sdr.withUnsafeMutableBufferPointer { pdr in
            var gL = gainL, gR = gainR
            if nCh == 1 {
                unsafe vDSP_vsmul(psl.baseAddress!, 1, &gL, pdl.baseAddress!, 1, vDSP_Length(n))
                unsafe vDSP_vsmul(psl.baseAddress!, 1, &gR, pdr.baseAddress!, 1, vDSP_Length(n))
            } else if az <= 0 {
                unsafe vDSP_vsma(psr.baseAddress!, 1, &gL, psl.baseAddress!, 1, pdl.baseAddress!, 1, vDSP_Length(n))
                unsafe vDSP_vsmul(psr.baseAddress!, 1, &gR, pdr.baseAddress!, 1, vDSP_Length(n))
            } else {
                unsafe vDSP_vsmul(psl.baseAddress!, 1, &gL, pdl.baseAddress!, 1, vDSP_Length(n))
                unsafe vDSP_vsma(psl.baseAddress!, 1, &gR, psr.baseAddress!, 1, pdr.baseAddress!, 1, vDSP_Length(n))
            }
        }}
    }}
}

@_expose(Cxx)
internal func eppPanSampleAccurate(
    _ azimuthSpan: AudioDSPSpanConstDouble, _ nInputChannels: UInt32,
    _ srcL: AudioDSPSpanConstFloat, _ srcR: AudioDSPSpanConstFloat,
    _ dstL: AudioDSPSpanFloat, _ dstR: AudioDSPSpanFloat,
    _ nFrames: Int32
) {
    let n = Int(nFrames)
    guard n > 0 else { return }
    let saz  = unsafe Span<Double>(_unsafeCxxSpan: azimuthSpan)
    let ssl  = unsafe Span<Float>(_unsafeCxxSpan: srcL)
    let ssr  = unsafe Span<Float>(_unsafeCxxSpan: srcR)
    var sdl  = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstL)
    var sdr  = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstR)
    let nCh = Int(nInputChannels)
    saz.withUnsafeBufferPointer { paz in ssl.withUnsafeBufferPointer { psl in
        ssr.withUnsafeBufferPointer { psr in sdl.withUnsafeMutableBufferPointer { pdl in
            sdr.withUnsafeMutableBufferPointer { pdr in
                for k in 0 ..< n {
                    var az = max(-180.0, min(180.0, unsafe paz[k]))
                    if az < -90 { az = -180 - az } else if az > 90 { az = 180 - az }
                    let pos = nCh == 1 ? (az + 90) / 180 : (az <= 0 ? (az + 90) / 90 : az / 90)
                    let gLD = cos(kPiOverTwo * pos)  // Double gain, matching C++ calculateDesiredGain
                    let gRD = sin(kPiOverTwo * pos)
                    if nCh == 1 {
                        let pslK = Double(unsafe psl[k])
                        unsafe pdl[k] = Float(pslK * gLD); unsafe pdr[k] = Float(pslK * gRD)
                    } else if az <= 0 {
                        let pslK = Double(unsafe psl[k]); let psrK = Double(unsafe psr[k])
                        unsafe pdl[k] = Float(pslK + psrK * gLD); unsafe pdr[k] = Float(psrK * gRD)
                    } else {
                        let pslK = Double(unsafe psl[k]); let psrK = Double(unsafe psr[k])
                        unsafe pdl[k] = Float(pslK * gLD); unsafe pdr[k] = Float(psrK + pslK * gRD)
                    }
                }
            }
        }}
    }}
}

// MARK: - StereoPanner
// Equal-power panning: pan [-1, 1] maps to [0, pi/2] for left/right gain.
// FIXME: rdar://186723514

@_expose(Cxx)
internal func spPanWithSampleAccurateValues(
    _ srcL: AudioDSPSpanConstFloat, _ srcR: AudioDSPSpanConstFloat,
    _ nInputChannels: UInt32,
    _ dstL: AudioDSPSpanFloat, _ dstR: AudioDSPSpanFloat,
    _ panValues: AudioDSPSpanConstFloat, _ nFrames: Int32
) {
    let n = Int(nFrames)
    guard n > 0 else { return }
    let ssl = unsafe Span<Float>(_unsafeCxxSpan: srcL)
    let ssr = unsafe Span<Float>(_unsafeCxxSpan: srcR)
    var sdl = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstL)
    var sdr = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstR)
    let spv = unsafe Span<Float>(_unsafeCxxSpan: panValues)
    let nCh = Int(nInputChannels)
    ssl.withUnsafeBufferPointer { psl in ssr.withUnsafeBufferPointer { psr in
        sdl.withUnsafeMutableBufferPointer { pdl in sdr.withUnsafeMutableBufferPointer { pdr in
            spv.withUnsafeBufferPointer { ppv in
                for i in 0 ..< n {
                    let ppvI = unsafe ppv[i]
                    let pan = Double(max(-1, min(1, ppvI)))
                    let panRadian = (nCh == 1 ? (pan * 0.5 + 0.5) : (pan <= 0 ? pan + 1 : pan)) * kPiOverTwo
                    // C++ uses double gains: float(float_input * double_gain).
                    let gLD = cos(panRadian), gRD = sin(panRadian)
                    let pslD = Double(unsafe psl[i]); let psrD = Double(unsafe psr[i])
                    if nCh == 1 {
                        unsafe pdl[i] = Float(pslD * gLD); unsafe pdr[i] = Float(pslD * gRD)
                    } else if pan <= 0 {
                        unsafe pdl[i] = Float(pslD + psrD * gLD); unsafe pdr[i] = Float(psrD * gRD)
                    } else {
                        unsafe pdl[i] = Float(pslD * gLD); unsafe pdr[i] = Float(psrD + pslD * gRD)
                    }
                }
            }
        }}
    }}
}

@_expose(Cxx)
internal func spPanToTargetValue(
    _ srcL: AudioDSPSpanConstFloat, _ srcR: AudioDSPSpanConstFloat,
    _ nInputChannels: UInt32,
    _ dstL: AudioDSPSpanFloat, _ dstR: AudioDSPSpanFloat,
    _ panValue: Float, _ nFrames: Int32
) {
    let n = Int(nFrames)
    guard n > 0 else { return }
    let ssl = unsafe Span<Float>(_unsafeCxxSpan: srcL)
    let ssr = unsafe Span<Float>(_unsafeCxxSpan: srcR)
    var sdl = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstL)
    var sdr = unsafe MutableSpan<Float>(_unsafeCxxSpan: dstR)
    let nCh = Int(nInputChannels)
    let pan = Double(max(-1, min(1, panValue)))
    let panRadian = (nCh == 1 ? (pan * 0.5 + 0.5) : (pan <= 0 ? pan + 1 : pan)) * kPiOverTwo
    let gainL = Float(cos(panRadian)), gainR = Float(sin(panRadian))
    ssl.withUnsafeBufferPointer { psl in ssr.withUnsafeBufferPointer { psr in
        sdl.withUnsafeMutableBufferPointer { pdl in sdr.withUnsafeMutableBufferPointer { pdr in
            var gL = gainL, gR = gainR
            if nCh == 1 {
                unsafe vDSP_vsmul(psl.baseAddress!, 1, &gL, pdl.baseAddress!, 1, vDSP_Length(n))
                unsafe vDSP_vsmul(psl.baseAddress!, 1, &gR, pdr.baseAddress!, 1, vDSP_Length(n))
            } else if pan <= 0 {
                unsafe vDSP_vsma(psr.baseAddress!, 1, &gL, psl.baseAddress!, 1, pdl.baseAddress!, 1, vDSP_Length(n))
                unsafe vDSP_vsmul(psr.baseAddress!, 1, &gR, pdr.baseAddress!, 1, vDSP_Length(n))
            } else {
                unsafe vDSP_vsmul(psl.baseAddress!, 1, &gL, pdl.baseAddress!, 1, vDSP_Length(n))
                unsafe vDSP_vsma(psl.baseAddress!, 1, &gR, psr.baseAddress!, 1, pdr.baseAddress!, 1, vDSP_Length(n))
            }
        }}
    }}
}

// MARK: - SincResampler
//
// Windowed-sinc resampler. processBuffer creates a SincResampler and pulls
// requestFrames at a time from source, resampled into destination.
// Uses vDSP_dotpr for the sinc kernel convolution (Accelerate path).
// FIXME: rdar://186723514

private let kSincKernelSize: Int = 32
private let kSincOffsetCount: Int = 32
// Note: kernel is now built by C++ SincResampler constructor and passed to Swift.

@_expose(Cxx)
internal func sincResamplerProcessBuffer(
    _ source: AudioDSPSpanConstFloat, _ destination: AudioDSPSpanFloat,
    _ scaleFactor: Double, _ kernelBuf: AudioDSPSpanConstFloat
) {
    let ssrc = unsafe Span<Float>(_unsafeCxxSpan: source)
    var sdst = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    let destN = sdst.count
    guard destN > 0 else { return }
    let sker = unsafe Span<Float>(_unsafeCxxSpan: kernelBuf)
    ssrc.withUnsafeBufferPointer { psrc in
        sdst.withUnsafeMutableBufferPointer { pdst in
            sker.withUnsafeBufferPointer { pker in
                // Replicates SincResampler exactly:
                // updateRegions(false): r0=16, r2=16, r3=112, r4=128, blockSize=112
                // updateRegions(true):  r0=32, r2=16, r3=128, r4=144, blockSize=128
                let n = kSincKernelSize
                let halfN = n / 2  // 16
                let requestFrames = 128
                let inputBufSize = requestFrames + n  // 160
                var inputBuf = [Float](repeating: 0, count: inputBufSize)

                var srcConsumed = 0
                let srcTotal = psrc.count

                // First load: r0 = halfN = 16
                let firstR0 = halfN
                let firstR3 = firstR0 + requestFrames - n  // = 16 + 128 - 32 = 112
                let firstBlockSize = halfN + (requestFrames - halfN - halfN)  // r2=16, r4=128 → 112
                // Actually blockSize = r4 - r2 where r2=halfN, r4=r0+(requestFrames-halfN)=16+112=128 → 112

                // Second+ load: r0 = n = 32
                let secondR0 = n
                let secondR3 = secondR0 + requestFrames - n  // = 32 + 128 - 32 = 128
                let secondBlockSize = 128  // r2=16, r4=144 → 128
                // r4 = r0 + requestFrames - halfN = 32 + 112 = 144, blockSize = r4 - r2 = 144 - 16 = 128

                // Prime first block
                let toCopy0 = min(requestFrames, srcTotal - srcConsumed)
                for i in 0 ..< toCopy0 { inputBuf[firstR0 + i] = unsafe psrc[srcConsumed + i] }
                srcConsumed += toCopy0

                var virtualIndex: Double = 0
                var dstIdx = 0
                var remaining = destN
                var blockSize = firstBlockSize
                var r3 = firstR3
                var loadR0 = secondR0

                while remaining > 0 {
                    while virtualIndex < Double(blockSize) && remaining > 0 {
                        let sourceI = Int(virtualIndex)
                        let subsample = virtualIndex - Double(sourceI)
                        let virtualOffset = subsample * Double(kSincOffsetCount)
                        let offsetI = Int(virtualOffset)
                        let interp = Float(virtualOffset - Double(offsetI))
                        let k1Base = n * offsetI
                        let k2Base = k1Base + n
                        var s1: Float = 0, s2: Float = 0
                        inputBuf.withUnsafeBufferPointer { pib in
                            unsafe vDSP_dotpr(pib.baseAddress! + sourceI, 1,
                                       pker.baseAddress! + k1Base, 1, &s1, vDSP_Length(n))
                            unsafe vDSP_dotpr(pib.baseAddress! + sourceI, 1,
                                       pker.baseAddress! + k2Base, 1, &s2, vDSP_Length(n))
                        }
                        // Match C++ convolve: fmul(interp,s2) then fmadd(1-interp, s1, result)
                        let oneMinusInterp = 1 - interp
                        var interpResult = interp * s2
                        interpResult.addProduct(oneMinusInterp, s1)
                        unsafe pdst[dstIdx] = interpResult
                        dstIdx += 1
                        remaining -= 1
                        virtualIndex += scaleFactor
                    }
                    if remaining == 0 { break }
                    virtualIndex -= Double(blockSize)
                    // Copy r3..r3+n-1 to 0..n-1
                    for i in 0 ..< n { inputBuf[i] = inputBuf[r3 + i] }
                    // Load next block at loadR0
                    let toCopy = min(requestFrames, srcTotal - srcConsumed)
                    for i in 0 ..< toCopy { inputBuf[loadR0 + i] = unsafe psrc[srcConsumed + i] }
                    for i in toCopy ..< requestFrames { inputBuf[loadR0 + i] = 0 }
                    srcConsumed += toCopy
                    // Switch to second+ block parameters
                    blockSize = secondBlockSize
                    r3 = secondR3
                    loadR0 = secondR0
                }
            }
        }
    }
}

// MARK: - DirectConvolver
//
// Direct-form convolution via VectorMath::convolve (vDSP_conv).
// buffer is the double-length delay buffer (size = 2 * inputBlockSize).
// FIXME: rdar://186723514

@_expose(Cxx)
internal func directConvolverProcess(
    _ source: AudioDSPSpanConstFloat, _ kernel: AudioDSPSpanConstFloat,
    _ buffer: AudioDSPSpanFloat, _ destination: AudioDSPSpanFloat,
    _ inputBlockSize: Int32
) {
    let blockSize = Int(inputBlockSize)
    let ssrc = unsafe Span<Float>(_unsafeCxxSpan: source)
    let sker = unsafe Span<Float>(_unsafeCxxSpan: kernel)
    var sbuf = unsafe MutableSpan<Float>(_unsafeCxxSpan: buffer)
    var sdst = unsafe MutableSpan<Float>(_unsafeCxxSpan: destination)
    let kernelSize = sker.count
    guard blockSize > 0, kernelSize > 0, kernelSize <= blockSize else { return }
    ssrc.withUnsafeBufferPointer { psrc in
        sker.withUnsafeBufferPointer { pker in
            sbuf.withUnsafeMutableBufferPointer { pbuf in
                sdst.withUnsafeMutableBufferPointer { pdst in
                    // Copy source into second half of buffer.
                    let inputP = unsafe (pbuf.baseAddress! + blockSize)
                    for i in 0 ..< blockSize { unsafe inputP[i] = unsafe psrc[i] }
                    // Convolve: signal starts at inputP - (kernelSize - 1), filter reads backwards.
                    let signalStart = unsafe (pbuf.baseAddress! + blockSize - (kernelSize - 1))
                    let filterLast = unsafe (pker.baseAddress! + (kernelSize - 1))
                    unsafe vDSP_conv(signalStart, 1, filterLast, -1,
                              pdst.baseAddress!, 1, vDSP_Length(blockSize), vDSP_Length(kernelSize))
                    // Copy second half to first half for next call.
                    for i in 0 ..< blockSize { unsafe pbuf[i] = unsafe pbuf[blockSize + i] }
                }
            }
        }
    }
}

@_expose(Cxx)
internal func directConvolverReset(_ buffer: AudioDSPSpanFloat) {
    var sbuf = unsafe MutableSpan<Float>(_unsafeCxxSpan: buffer)
    sbuf.withUnsafeMutableBufferPointer { p in for i in 0 ..< p.count { unsafe p[i] = 0 } }
}

// MARK: - Denormal helpers

@inline(always)
private func flushDenormal(_ x: Double) -> Double {
    // Replicates DenormalDisabler::flushDenormalFloatToZero: convert to float precision first,
    // then zero if sub-normal (< Float.leastNormalMagnitude = FLT_MIN). Exactly matches R10.
    let f = Float(x)
    return Double(f.magnitude < Float.leastNormalMagnitude ? 0 : f)
}

@inline(always)
private func flushDenormalFloat(_ x: Float) -> Float {
    // DenormalDisabler::flushDenormalFloatToZero: zero sub-normals (abs < FLT_MIN).
    x.magnitude < Float.leastNormalMagnitude ? 0 : x
}

#endif // USE_SWIFT_AUDIO_DSP
