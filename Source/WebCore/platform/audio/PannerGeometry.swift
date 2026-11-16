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

// The panner's distance and cone gains (OpenAL's models): DistanceEffect::gain and ConeEffect::gain. Multiply-adds
// are fused where Clang's -ffp-contract=on fuses them (addingContractedProduct).

internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
// These imports make the operators JavaScriptCore declares visible before WebCore's C++ operators are
// (rdar://192229293).
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import WebCore_Private.Core.FloatPoint3D
internal import wtf.Core.Stopwatch

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// DistanceModelType's raw values. Distance.cpp checks them with static_asserts.
private let distanceModelLinear = 0
private let distanceModelInverse = 1
private let distanceModelExponential = 2

/// DistanceEffect::gain. `model` is DistanceModelType's raw value; another value gives 0.
@_expose(Cxx)
public func distanceEffectGain(
    _ model: Int,
    _ isClamped: Bool,
    _ refDistance: Double,
    _ maxDistance: Double,
    _ rolloffFactor: Double,
    _ distance: Double
) -> Double {
    // Not beyond the maximum distance; if clamped, not closer than the reference distance.
    var distance = audioCxxMinDouble(distance, maxDistance)
    if isClamped { distance = audioCxxMaxDouble(distance, refDistance) }

    switch model {
    case distanceModelLinear:
        // Clamp the rolloff to [0, 1].
        let clampedRolloffFactor = rolloffFactor < 0.0 ? 0.0 : (1.0 < rolloffFactor ? 1.0 : rolloffFactor)
        // The spec permits refDistance == maxDistance; avoid the division by zero.
        if refDistance == maxDistance { return 1.0 - clampedRolloffFactor }
        // A gain that decreases linearly from 1 at refDistance to maxDistance.
        return 1.0 - clampedRolloffFactor * (distance - refDistance) / (maxDistance - refDistance)
    case distanceModelInverse:
        // The spec clamps distance to at least refDistance for this model, so the only division by zero left is
        // both being 0.
        if refDistance == 0 && distance == 0 { return 0 }
        return refDistance / refDistance.addingContractedProduct(rolloffFactor, audioCxxMaxDouble(distance, refDistance) - refDistance)
    case distanceModelExponential:
        if refDistance == 0 && distance == 0 { return 0 }
        return pow(audioCxxMaxDouble(distance, refDistance) / refDistance, -rolloffFactor)
    default:
        return 0.0
    }
}

/// Normalizes as FloatPoint3D::normalize does; the length is hypot from the port's math library.
@inline(always)
private func coneNormalized(_ x: Float, _ y: Float, _ z: Float) -> (Float, Float, Float) {
    var v = WebCore.FloatPoint3D(x, y, z)
    v.normalize()
    return (v.x(), v.y(), v.z())
}

/// The cone gain of a source, with the positions and the orientation as their coordinates; angles are in degrees.
@_expose(Cxx)
public func coneEffectGain(
    _ innerAngle: Double,
    _ outerAngle: Double,
    _ outerGain: Double,
    _ sourceX: Float,
    _ sourceY: Float,
    _ sourceZ: Float,
    _ orientationX: Float,
    _ orientationY: Float,
    _ orientationZ: Float,
    _ listenerX: Float,
    _ listenerY: Float,
    _ listenerZ: Float
) -> Double {
    // No cone: unity gain.
    if (orientationX == 0 && orientationY == 0 && orientationZ == 0) || (innerAngle == 360.0 && outerAngle == 360.0) {
        return 1.0
    }

    // The normalized source-listener vector, and the normalized orientation.
    let toListener = coneNormalized(listenerX - sourceX, listenerY - sourceY, listenerZ - sourceZ)
    let orientation = coneNormalized(orientationX, orientationY, orientationZ)

    // FloatPoint3D::dot: x * x' + y * y' + z * z', in float, contracted as fma(z, z', fma(x, x', y * y')).
    let dot = (toListener.1 * orientation.1).addingContractedProduct(toListener.0, orientation.0)
        .addingContractedProduct(toListener.2, orientation.2)
    // clampTo<double>(dot, -1, 1): rounding can put the dot product just outside [-1, 1], where acos is NaN.
    let value = Double(dot)
    let dotProduct = value >= 1.0 ? 1.0 : (value <= -1.0 ? -1.0 : value)

    // The angle between the orientation and the source-listener vector; the API's angles are whole, not half.
    let absAngle = abs(acos(dotProduct) * (180.0 / Double.pi))
    let absInnerAngle = abs(innerAngle) / 2.0
    let absOuterAngle = abs(outerAngle) / 2.0

    if absAngle <= absInnerAngle { return 1.0 }
    if absAngle >= absOuterAngle { return outerGain }
    // Between the cones, x goes from 0 to 1.
    let x = (absAngle - absInnerAngle) / (absOuterAngle - absInnerAngle)
    return (1.0 - x).addingContractedProduct(outerGain, x)
}
