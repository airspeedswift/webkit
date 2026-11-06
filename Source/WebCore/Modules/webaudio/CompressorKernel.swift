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

// Swift implementation of DynamicsCompressorKernel's processing, with the C++'s evaluation order and precision.

#if USE_SWIFT_AUDIO_DSP

public import WebCore_Private.AudioDSPBoundaryTypes
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
import Darwin

private let maxPreDelayFrames = 1024
private let maxPreDelayFramesMask = maxPreDelayFrames - 1
private let defaultPreDelayFrames = 256

// Metering hits peaks instantly, but releases this fast (in seconds).
private let meteringReleaseTimeConstant: Float = 0.325

// AudioUtilities::linearToDecibels and decibelsToLinear. The C++ compiler turns powf(10, y) into exp10f, and so does
// the Swift one.
@inline(always)
private func linearToDecibels(_ linear: Float) -> Float {
    20 * log10(linear)
}

@inline(always)
private func decibelsToLinear(_ decibels: Float) -> Float {
    pow(10, 0.05 * decibels)
}

// A float converted to unsigned as arm64 converts it: NaN and negative values give 0, large values saturate.
@inline(always)
private func saturatingUnsigned(_ value: Float) -> UInt32 {
    if !(value > 0) { return 0 }
    return value >= 4294967296.0 ? UInt32.max : UInt32(value)
}

// c1*y1 + c2*y2 + c3*y3 + c4*y4 as the C++ compiler contracts it: the second product is rounded, the other three are
// fused into the running sum. The signs of the constants are the ones in the C++ expression.
@inline(always)
private func polynomialCoefficient(
    _ y1: Float,
    _ y2: Float,
    _ y3: Float,
    _ y4: Float,
    _ c1: Float,
    _ c2: Float,
    _ c3: Float,
    _ c4: Float
) -> Float {
    (y2 * c2).addingProduct(y1, c1).addingProduct(y3, c3).addingProduct(y4, c4)
}

/// The state of a dynamics compressor kernel.
@_expose(Cxx)
public struct CompressorKernel {
    private let sampleRate: Float
    private var numberOfChannels: UInt32

    private var detectorAverage: Float = 0
    private var compressorGain: Float = 1

    // Metering
    private let meteringReleaseK: Float
    private var meteringGain: Float = 1

    // Lookahead section: the pre-delay line of each of the two channels.
    private var lastPreDelayFrames: UInt32 = UInt32(defaultPreDelayFrames)
    private var leftPreDelay = InlineArray<1024, Float>(repeating: 0)
    private var rightPreDelay = InlineArray<1024, Float>(repeating: 0)
    private var preDelayReadIndex = 0
    private var preDelayWriteIndex = defaultPreDelayFrames
    private var maxAttackCompressionDiffDb: Float = -1

    // Static compression curve.
    private var ratio: Float = -1
    private var slope: Float = -1
    private var linearThreshold: Float = -1
    private var dbThreshold: Float = -1
    private var dbKnee: Float = -1
    private var kneeThreshold: Float = -1
    private var kneeThresholdDb: Float = -1
    private var ykneeThresholdDb: Float = -1
    private var kneeK: Float = -1

    init(sampleRate: Float, numberOfChannels: UInt32) {
        self.sampleRate = sampleRate
        self.numberOfChannels = numberOfChannels
        // AudioUtilities::discreteTimeConstantForSampleRate, in double precision.
        let timeConstant = Double(meteringReleaseTimeConstant)
        meteringReleaseK = Float(1 - exp(-1 / (Double(sampleRate) * timeConstant)))
    }

    var latencyFrames: UInt32 { lastPreDelayFrames }
    var currentMeteringGain: Float { meteringGain }

    mutating func setNumberOfChannels(_ count: UInt32) {
        if numberOfChannels == count { return }
        numberOfChannels = count
        zeroPreDelay()
    }

    mutating func reset() {
        detectorAverage = 0
        compressorGain = 1
        meteringGain = 1
        zeroPreDelay()
        preDelayReadIndex = 0
        preDelayWriteIndex = defaultPreDelayFrames
        maxAttackCompressionDiffDb = -1 // uninitialized state
    }

    private mutating func zeroPreDelay() {
        leftPreDelay = InlineArray<1024, Float>(repeating: 0)
        rightPreDelay = InlineArray<1024, Float>(repeating: 0)
    }

    // Re-configure look-ahead section pre-delay if delay time has changed.
    private mutating func setPreDelayTime(_ preDelayTime: Float) {
        var preDelayFrames = saturatingUnsigned(preDelayTime * sampleRate)
        if preDelayFrames > UInt32(maxPreDelayFrames - 1) {
            preDelayFrames = UInt32(maxPreDelayFrames - 1)
        }
        if lastPreDelayFrames != preDelayFrames {
            lastPreDelayFrames = preDelayFrames
            zeroPreDelay()
            preDelayReadIndex = 0
            preDelayWriteIndex = Int(preDelayFrames)
        }
    }

    // Exponential curve for the knee.
    // It is 1st derivative matched at linearThreshold and asymptotically approaches the value linearThreshold + 1 / k.
    @inline(always)
    private func kneeCurve(_ x: Float, _ k: Float) -> Float {
        // Linear up to threshold.
        if x < linearThreshold { return x }
        return linearThreshold + (1 - exp(-k * (x - linearThreshold))) / k
    }

    // Full compression curve with constant ratio after knee.
    @inline(always)
    private func saturate(_ x: Float, _ k: Float) -> Float {
        if x < kneeThreshold { return kneeCurve(x, k) }
        // Constant ratio after knee.
        let xDb = linearToDecibels(x)
        let yDb = ykneeThresholdDb.addingProduct(slope, xDb - kneeThresholdDb)
        return decibelsToLinear(yDb)
    }

    // Approximate 1st derivative with input and output expressed in dB.
    private func slopeAt(_ x: Float, _ k: Float) -> Float {
        if x < linearThreshold { return 1 }
        let x2 = Float(Double(x) * 1.001)
        let xDb = linearToDecibels(x)
        let x2Db = linearToDecibels(x2)
        let yDb = linearToDecibels(kneeCurve(x, k))
        let y2Db = linearToDecibels(kneeCurve(x2, k))
        return (y2Db - yDb) / (x2Db - xDb)
    }

    private func kAtSlope(_ desiredSlope: Float) -> Float {
        let xDb = dbThreshold + dbKnee
        let x = decibelsToLinear(xDb)
        // Approximate k given initial values.
        var minK: Float = 0.1
        var maxK: Float = 10000
        var k: Float = 5
        for _ in 0..<15 {
            // A high value for k will more quickly asymptotically approach a slope of 0.
            let slope = slopeAt(x, k)
            if slope < desiredSlope {
                // k is too high.
                maxK = k
            } else {
                // k is too low.
                minK = k
            }
            // Re-calculate based on geometric mean.
            k = (minK * maxK).squareRoot()
        }
        return k
    }

    private mutating func updateStaticCurveParameters(_ dbThreshold: Float, _ dbKnee: Float, _ ratio: Float) -> Float {
        if dbThreshold != self.dbThreshold || dbKnee != self.dbKnee || ratio != self.ratio {
            // Threshold and knee.
            self.dbThreshold = dbThreshold
            linearThreshold = decibelsToLinear(dbThreshold)
            self.dbKnee = dbKnee
            // Compute knee parameters.
            self.ratio = ratio
            slope = 1 / ratio
            let k = kAtSlope(1 / ratio)
            kneeThresholdDb = dbThreshold + dbKnee
            kneeThreshold = decibelsToLinear(kneeThresholdDb)
            ykneeThresholdDb = linearToDecibels(kneeCurve(kneeThreshold, k))
            kneeK = k
        }
        return kneeK
    }

    // The sources do not overlap the destinations; the two sources may be the same buffer (a duplicated mono input).
    mutating func process(
        _ sourceLeft: Span<Float>,
        _ sourceRight: Span<Float>,
        _ destinationLeft: inout MutableSpan<Float>,
        _ destinationRight: inout MutableSpan<Float>,
        _ framesToProcess: Int,
        _ dbThreshold: Float,
        _ dbKnee: Float,
        _ ratio: Float,
        _ attackTime: Float,
        _ releaseTime: Float,
        _ preDelayTime: Float,
        _ dbPostGain: Float,
        _ effectBlend: Float,
        _ releaseZone1: Float,
        _ releaseZone2: Float,
        _ releaseZone3: Float,
        _ releaseZone4: Float
    ) {
        // The C++ indexes one pre-delay line per channel and traps on a missing one.
        precondition(numberOfChannels >= 2)

        let sampleRate = self.sampleRate

        let dryMix = 1 - effectBlend
        let wetMix = effectBlend

        let k = updateStaticCurveParameters(dbThreshold, dbKnee, ratio)

        // Makeup gain.
        let fullRangeGain = saturate(1, k)
        var fullRangeMakeupGain = 1 / fullRangeGain

        // Empirical/perceptual tuning.
        fullRangeMakeupGain = pow(fullRangeMakeupGain, 0.6)

        let masterLinearGain = decibelsToLinear(dbPostGain) * fullRangeMakeupGain

        // Attack parameters.
        let attackTime = 0.001 < attackTime ? attackTime : 0.001
        let attackFrames = attackTime * sampleRate

        // Release parameters.
        let releaseFrames = sampleRate * releaseTime

        // Detector release time.
        let satReleaseTime: Float = 0.0025
        let satReleaseFrames = satReleaseTime * sampleRate

        // Create a smooth function which passes through four points: a polynomial of the form
        // y = a + b*x + c*x^2 + d*x^3 + e*x^4.
        let y1 = releaseFrames * releaseZone1
        let y2 = releaseFrames * releaseZone2
        let y3 = releaseFrames * releaseZone3
        let y4 = releaseFrames * releaseZone4

        // All of these coefficients were derived for 4th order polynomial curve fitting where the y values
        // match the evenly spaced x values as follows: (y1 : x == 0, y2 : x == 1, y3 : x == 2, y4 : x == 3)
        let kA = polynomialCoefficient(
            y1,
            y2,
            y3,
            y4,
            0.9999999999999998,
            1.8432219684323923e-16,
            -1.9373394351676423e-16,
            8.824516011816245e-18
        )
        let kB = polynomialCoefficient(
            y1,
            y2,
            y3,
            y4,
            -1.5788320352845888,
            2.3305837032074286,
            -0.9141194204840429,
            0.1623677525612032
        )
        let kC = polynomialCoefficient(
            y1,
            y2,
            y3,
            y4,
            0.5334142869106424,
            -1.272736789213631,
            0.9258856042207512,
            -0.18656310191776226
        )
        let kD = polynomialCoefficient(
            y1,
            y2,
            y3,
            y4,
            0.08783463138207234,
            -0.1694162967925622,
            0.08588057951595272,
            -0.00429891410546283
        )
        let kE = polynomialCoefficient(
            y1,
            y2,
            y3,
            y4,
            -0.042416883008123074,
            0.1115693827987602,
            -0.09764676325265872,
            0.028494263462021576
        )

        // x ranges from 0 -> 3       0    1    2   3
        //                           -15  -10  -5   0db

        // y calculates adaptive release frames depending on the amount of compression.

        setPreDelayTime(preDelayTime)

        let nDivisionFrames = 32
        let nDivisions = framesToProcess / nDivisionFrames

        var frameIndex = 0
        for _ in 0..<nDivisions {
            // Calculate desired gain

            // Fix gremlins.
            if detectorAverage.isNaN { detectorAverage = 1 }
            if detectorAverage.isInfinite { detectorAverage = 1 }

            let desiredGain = detectorAverage

            // Pre-warp so we get desiredGain after sin() warp below.
            let scaledDesiredGain = asin(desiredGain) / (0.5 * Float.pi)

            // Deal with envelopes

            // envelopeRate is the rate we slew from current compressor level to the desired level.
            // The exact rate depends on if we're attacking or releasing and by how much.
            let envelopeRate: Float

            let isReleasing = scaledDesiredGain > compressorGain

            // compressionDiffDb is the difference between current compression level and the desired level.
            var compressionDiffDb = linearToDecibels(compressorGain / scaledDesiredGain)

            if isReleasing {
                // Release mode - compressionDiffDb should be negative dB
                maxAttackCompressionDiffDb = -1

                // Fix gremlins.
                if compressionDiffDb.isNaN { compressionDiffDb = -1 }
                if compressionDiffDb.isInfinite { compressionDiffDb = -1 }

                // Adaptive release - higher compression (lower compressionDiffDb) releases faster.

                // Contain within range: -12 -> 0 then scale to go from 0 -> 3
                var x = compressionDiffDb
                x = -12 < x ? x : -12
                x = x < 0 ? x : 0
                x = 0.25 * (x + 12)

                // Compute adaptive release curve using 4th order polynomial.
                let x2 = x * x
                let x3 = x2 * x
                let x4 = x2 * x2
                let adaptiveReleaseFrames = kA.addingProduct(kB, x).addingProduct(kC, x2).addingProduct(kD, x3)
                    .addingProduct(kE, x4)

                let kSpacingDb: Float = 5
                let dbPerFrame = kSpacingDb / adaptiveReleaseFrames

                envelopeRate = decibelsToLinear(dbPerFrame)
            } else {
                // Attack mode - compressionDiffDb should be positive dB

                // Fix gremlins.
                if compressionDiffDb.isNaN { compressionDiffDb = 1 }
                if compressionDiffDb.isInfinite { compressionDiffDb = 1 }

                // As long as we're still in attack mode, use a rate based off
                // the largest compressionDiffDb we've encountered so far.
                if maxAttackCompressionDiffDb == -1 || maxAttackCompressionDiffDb < compressionDiffDb {
                    maxAttackCompressionDiffDb = compressionDiffDb
                }

                let effAttenDiffDb = 0.5 < maxAttackCompressionDiffDb ? maxAttackCompressionDiffDb : 0.5

                let x = 0.25 / effAttenDiffDb
                envelopeRate = 1 - pow(x, 1 / attackFrames)
            }

            // Inner loop - calculate shaped power average - apply compression.
            var preDelayReadIndex = self.preDelayReadIndex
            var preDelayWriteIndex = self.preDelayWriteIndex
            var detectorAverage = self.detectorAverage
            var compressorGain = self.compressorGain
            var meteringGain = self.meteringGain

            for _ in 0..<nDivisionFrames {
                var compressorInput: Float = 0

                // Predelay signal, computing compression amount from un-delayed version.
                let undelayedLeft = sourceLeft[frameIndex]
                leftPreDelay[preDelayWriteIndex & maxPreDelayFramesMask] = undelayedLeft
                let absUndelayedLeft = undelayedLeft > 0 ? undelayedLeft : -undelayedLeft
                if compressorInput < absUndelayedLeft { compressorInput = absUndelayedLeft }

                let undelayedRight = sourceRight[frameIndex]
                rightPreDelay[preDelayWriteIndex & maxPreDelayFramesMask] = undelayedRight
                let absUndelayedRight = undelayedRight > 0 ? undelayedRight : -undelayedRight
                if compressorInput < absUndelayedRight { compressorInput = absUndelayedRight }

                // Calculate shaped power on undelayed input.

                let scaledInput = compressorInput
                let absInput = scaledInput > 0 ? scaledInput : -scaledInput

                // Put through shaping curve.
                // This is linear up to the threshold, then enters a "knee" portion followed by the "ratio" portion.
                // The transition from the threshold to the knee is smooth (1st derivative matched).
                // The transition from the knee to the ratio portion is smooth (1st derivative matched).
                let shapedInput = saturate(absInput, k)

                let attenuation = absInput <= 0.0001 ? 1 : shapedInput / absInput

                var attenuationDb = -linearToDecibels(attenuation)
                attenuationDb = 2 < attenuationDb ? attenuationDb : 2

                let dbPerFrame = attenuationDb / satReleaseFrames

                let satReleaseRate = decibelsToLinear(dbPerFrame) - 1

                let isRelease = attenuation > detectorAverage
                let rate = isRelease ? satReleaseRate : 1

                detectorAverage = detectorAverage.addingProduct(attenuation - detectorAverage, rate)
                detectorAverage = detectorAverage < 1 ? detectorAverage : 1

                // Fix gremlins.
                if detectorAverage.isNaN { detectorAverage = 1 }
                if detectorAverage.isInfinite { detectorAverage = 1 }

                // Exponential approach to desired gain.
                if envelopeRate < 1 {
                    // Attack - reduce gain to desired.
                    compressorGain = compressorGain.addingProduct(scaledDesiredGain - compressorGain, envelopeRate)
                } else {
                    // Release - exponentially increase gain to 1.0
                    compressorGain *= envelopeRate
                    compressorGain = compressorGain < 1 ? compressorGain : 1
                }

                // Warp pre-compression gain to smooth out sharp exponential transition points.
                let postWarpCompressorGain = sin(0.5 * Float.pi * compressorGain)

                // Calculate total gain using master gain and effect blend.
                let totalGain = dryMix.addingProduct(wetMix * masterLinearGain, postWarpCompressorGain)

                // Calculate metering.
                let dbRealGain = 20 * log10(postWarpCompressorGain)
                if dbRealGain < meteringGain {
                    meteringGain = dbRealGain
                } else {
                    meteringGain = meteringGain.addingProduct(dbRealGain - meteringGain, meteringReleaseK)
                }

                // Apply final gain.
                destinationLeft[frameIndex] = leftPreDelay[preDelayReadIndex & maxPreDelayFramesMask] * totalGain
                destinationRight[frameIndex] = rightPreDelay[preDelayReadIndex & maxPreDelayFramesMask] * totalGain

                // The frame index is below a span's count, and the delay indices are masked to the line's size.
                frameIndex &+= 1
                preDelayReadIndex = (preDelayReadIndex &+ 1) & maxPreDelayFramesMask
                preDelayWriteIndex = (preDelayWriteIndex &+ 1) & maxPreDelayFramesMask
            }

            // Locals back to member variables.
            self.preDelayReadIndex = preDelayReadIndex
            self.preDelayWriteIndex = preDelayWriteIndex
            self.meteringGain = meteringGain
            // DenormalDisabler::flushDenormalFloatToZero
            self.detectorAverage = abs(detectorAverage) < Float.leastNormalMagnitude ? 0 : detectorAverage
            self.compressorGain = abs(compressorGain) < Float.leastNormalMagnitude ? 0 : compressorGain
        }
    }
}

/// Creates a compressor kernel for `numberOfChannels` channels at `sampleRate`.
@_expose(Cxx)
public func makeCompressorKernel(_ sampleRate: Float, _ numberOfChannels: UInt32) -> CompressorKernel {
    CompressorKernel(sampleRate: sampleRate, numberOfChannels: numberOfChannels)
}

/// Compresses the first `framesToProcess` frames (rounded down to a multiple of 32) of two channels and returns the
/// metering gain.
///
/// The caller owns the four buffers, each stays allocated at its length for the call and nothing else reads or writes
/// them meanwhile. The sources do not overlap the destinations; the two sources may be the same buffer. Floats have no
/// invalid bit patterns. FIXME: rdar://186723514 (receiving a std::span safely).
@_expose(Cxx)
public func compressorProcess(
    _ kernel: inout CompressorKernel,
    _ sourceLeft: AudioDSPSpanConstFloat,
    _ sourceRight: AudioDSPSpanConstFloat,
    _ destinationLeft: AudioDSPSpanFloat,
    _ destinationRight: AudioDSPSpanFloat,
    _ framesToProcess: UInt32,
    _ dbThreshold: Float,
    _ dbKnee: Float,
    _ ratio: Float,
    _ attackTime: Float,
    _ releaseTime: Float,
    _ preDelayTime: Float,
    _ dbPostGain: Float,
    _ effectBlend: Float,
    _ releaseZone1: Float,
    _ releaseZone2: Float,
    _ releaseZone3: Float,
    _ releaseZone4: Float
) -> Float {
    let sourceLeftSpan = unsafe Span<Float>(_unsafeCxxSpan: sourceLeft)
    let sourceRightSpan = unsafe Span<Float>(_unsafeCxxSpan: sourceRight)
    var destinationLeftSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: destinationLeft)
    var destinationRightSpan = unsafe MutableSpan<Float>(_unsafeCxxSpan: destinationRight)
    kernel.process(
        sourceLeftSpan,
        sourceRightSpan,
        &destinationLeftSpan,
        &destinationRightSpan,
        Int(framesToProcess),
        dbThreshold,
        dbKnee,
        ratio,
        attackTime,
        releaseTime,
        preDelayTime,
        dbPostGain,
        effectBlend,
        releaseZone1,
        releaseZone2,
        releaseZone3,
        releaseZone4
    )
    return kernel.currentMeteringGain
}

/// Resets the kernel to its initial state.
@_expose(Cxx)
public func compressorReset(_ kernel: inout CompressorKernel) {
    kernel.reset()
}

/// Sets the channel count; a change clears the pre-delay lines.
@_expose(Cxx)
public func compressorSetNumberOfChannels(_ kernel: inout CompressorKernel, _ numberOfChannels: UInt32) {
    kernel.setNumberOfChannels(numberOfChannels)
}

/// The look-ahead delay in frames.
@_expose(Cxx)
public func compressorLatencyFrames(_ kernel: borrowing CompressorKernel) -> UInt32 {
    kernel.latencyFrames
}

#endif // USE_SWIFT_AUDIO_DSP
