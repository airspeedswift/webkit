// Copyright (C) 2008 Alex Mathews <possessedpenguinbob@gmail.com>
// Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
// Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
// Copyright (C) 2005 Eric Seidel <eric@webkit.org>
// Copyright (C) 2010 Zoltan Herczeg <zherczeg@webkit.org>
// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
// Copyright (C) 2014 Google Inc. All rights reserved.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
//
// You should have received a copy of the GNU Library General Public License
// along with this library; see the file COPYING.LIB.  If not, write to
// the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
// Boston, MA 02110-1301, USA.
//
// Copyright (C) 2008 Alex Mathews <possessedpenguinbob@gmail.com>
// Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
// Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
// Copyright (C) 2005 Eric Seidel <eric@webkit.org>
// Copyright (C) 2010 Zoltan Herczeg <zherczeg@webkit.org>
// Copyright (C) 2011 University of Szeged
// Copyright (C) 2011 Renata Hodovan <reni@webkit.org>
// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
// Copyright (C) 2014 Google Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY UNIVERSITY OF SZEGED ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL UNIVERSITY OF SZEGED OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import ucrt
#endif
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatPoint
import WebCore_Private.Core.FloatPoint3D
import WebCore_Private.Core.LightSourceParameters

// The light that a light source casts on each pixel of a lighting result (LightSource::initPaintingData() and
// computePixelLightingData() in C++). The float operations are the C++ ones, in the same order.
struct LightingModel: Sendable {
    // The vector from a surface point to the light, its length, and the light's color at the point.
    struct PixelLight {
        var x: Float
        var y: Float
        var z: Float
        var length: Float
        var red: Float
        var green: Float
        var blue: Float
    }

    private enum Kind {
        case distant
        case point
        case spot
    }

    private let kind: Kind
    // A distant light's light vector, or a point or spot light's position in the result's pixel coordinates.
    private let lightX: Float
    private let lightY: Float
    private let lightZ: Float
    private let red: Float
    private let green: Float
    private let blue: Float
    // A spot light's normalized direction, cone and exponent.
    private let directionX: Float
    private let directionY: Float
    private let directionZ: Float
    private let coneCutOffLimit: Float
    private let coneFullLight: Float
    private let specularExponent: Float

    // `lightSource` has its positions resolved for the filter; `result` is the lighting result.
    init(
        _ lightSource: borrowing WebCore.LightSourceParameters,
        lightingColor: WebCore.FilterColorComponents,
        context: borrowing WebCore.FilterApplyContext,
        result: borrowing FilterImageImpl
    ) {
        red = lightingColor.red
        green = lightingColor.green
        blue = lightingColor.blue
        specularExponent = lightSource.specularExponent
        switch lightSource.type {
        case .Point, .Spot:
            let position = lightSource.position
            let positionX = position.x()
            let positionY = position.y()
            let positionZ = position.z()
            let bufferPosition = result.mappedAbsolutePoint(context.scaledByFilterScale(WebCore.FloatPoint(positionX, positionY)))
            lightX = bufferPosition.x()
            lightY = bufferPosition.y()
            // To scale Z, map a point offset from position in the x direction by z.
            let absoluteMappedZ = context.scaledByFilterScale(WebCore.FloatPoint(positionX + positionZ, positionY))
            lightZ = result.mappedAbsolutePoint(absoluteMappedZ).x() - lightX
            guard lightSource.type == .Spot else {
                kind = .point
                (directionX, directionY, directionZ) = (0, 0, 0)
                (coneCutOffLimit, coneFullLight) = (0, 0)
                return
            }
            kind = .spot
            let pointsAt = lightSource.pointsAt
            // FloatPoint3D::normalize() is WebCore's C++, as for the C++ light source.
            var direction = WebCore.FloatPoint3D(pointsAt.x() - positionX, pointsAt.y() - positionY, pointsAt.z() - positionZ)
            direction.normalize()
            directionX = direction.x()
            directionY = direction.y()
            directionZ = direction.z()
            (coneCutOffLimit, coneFullLight) = Self.spotCone(lightSource.limitingConeAngle)
        default:
            kind = .distant
            let azimuth = Self.deg2rad(lightSource.azimuth)
            let elevation = Self.deg2rad(lightSource.elevation)
            lightX = cosf(azimuth) * cosf(elevation)
            lightY = sinf(azimuth) * cosf(elevation)
            lightZ = sinf(elevation)
            (directionX, directionY, directionZ) = (0, 0, 0)
            (coneCutOffLimit, coneFullLight) = (0, 0)
        }
    }

    // A spot light's cone: the cosine of the angle beyond which it casts no light, and the one beyond which its light
    // fades out. Spot light edge darkening depends on an absolute threshold, according to the SVG 1.1 SE light
    // regression tests.
    private static func spotCone(_ limitingConeAngle: Float) -> (cutOffLimit: Float, fullLight: Float) {
        let antialiasThreshold: Float = 0.016
        if limitingConeAngle == 0 {
            return (0, -antialiasThreshold)
        }
        var angle = limitingConeAngle
        if angle < 0 {
            angle = -angle
        }
        if angle > 90 {
            angle = 90
        }
        let cutOffLimit = cosf(deg2rad(180 - angle))
        return (cutOffLimit, cutOffLimit - antialiasThreshold)
    }

    // The light at the surface point (x, y, z), x and y in the result's pixel coordinates.
    @inline(__always)
    func pixelLight(x: Int, y: Int, z: Float) -> PixelLight {
        if kind == .distant {
            return PixelLight(x: lightX, y: lightY, z: lightZ, length: 1, red: red, green: green, blue: blue)
        }
        let vectorX = lightX - Float(x)
        let vectorY = lightY - Float(y)
        let vectorZ = lightZ - z
        let length = Self.length(vectorX, vectorY, vectorZ)
        if kind == .point {
            return PixelLight(x: vectorX, y: vectorY, z: vectorZ, length: length, red: red, green: green, blue: blue)
        }
        let cosineOfAngle = Self.dot(vectorX, vectorY, vectorZ, directionX, directionY, directionZ) / length
        if cosineOfAngle > coneCutOffLimit {
            // No light is produced.
            return PixelLight(x: vectorX, y: vectorY, z: vectorZ, length: length, red: 0, green: 0, blue: 0)
        }
        var lightStrength = specularExponent == 1 ? -cosineOfAngle : powf(-cosineOfAngle, specularExponent)
        if cosineOfAngle > coneFullLight {
            lightStrength *= (coneCutOffLimit - cosineOfAngle) / (coneCutOffLimit - coneFullLight)
        }
        if lightStrength > 1 {
            lightStrength = 1
        }
        return PixelLight(
            x: vectorX,
            y: vectorY,
            z: vectorZ,
            length: length,
            red: lightStrength * red,
            green: lightStrength * green,
            blue: lightStrength * blue
        )
    }

    // deg2rad(float) (WTF): pi rounded to float (Swift's Float.pi is rounded down), over 180, in float.
    @inline(__always)
    static func deg2rad(_ degrees: Float) -> Float {
        degrees * (Float(Double.pi) / 180)
    }

    // FloatPoint3D::dot().
    @inline(__always)
    static func dot(_ ax: Float, _ ay: Float, _ az: Float, _ bx: Float, _ by: Float, _ bz: Float) -> Float {
        ax * bx + ay * by + az * bz
    }

    // FloatPoint3D::length().
    @inline(__always)
    static func length(_ x: Float, _ y: Float, _ z: Float) -> Float {
        filterHypot(x, y, z)
    }
}

// A light source's parameters with its positions resolved for the filter.
func resolvedLightSourceParameters(
    _ parameters: WebCore.LightSourceParameters,
    _ renderer: borrowing WebCore.FilterRendererParameters
) -> WebCore.LightSourceParameters {
    var resolved = parameters
    if resolved.type != .Distant {
        resolved.position = svgFilterResolvedPoint3D(resolved.position, renderer.referenceBox, renderer.primitiveUnitsAreObjectBoundingBox)
    }
    if resolved.type == .Spot {
        resolved.pointsAt = svgFilterResolvedPoint3D(resolved.pointsAt, renderer.referenceBox, renderer.primitiveUnitsAreObjectBoundingBox)
    }
    return resolved
}

#endif // ENABLE_WEBCORE_SWIFT
