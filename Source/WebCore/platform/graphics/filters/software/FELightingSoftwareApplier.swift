// Copyright (C) 2010 University of Szeged
// Copyright (C) 2010 Zoltan Herczeg
// Copyright (C) 2018-2026 Apple Inc. All rights reserved.
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

// The safe Span overload Swift synthesizes for PixelBufferAccess.mutableSpan() calls Cxx's MutableSpan(_unsafeCxxSpan:).
// Xcode builds don't find it unless this file imports Cxx.
private import Cxx
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import ucrt
#endif
import WebCore_Private.Core.AlphaPremultiplication
import WebCore_Private.Core.FELightingParameters
import WebCore_Private.Core.FilterGraphicsBridge
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.IntSize
import WebCore_Private.Core.LightSourceParameters
import WebCore_Private.Core.PixelBuffer
import WebCore_Private.Core.PixelBufferSwiftBridge

// FEDiffuseLighting and FESpecularLighting in software: the light that `lightSource` (its positions resolved for the
// filter) casts on the surface whose height is the input's alpha, as seen from straight above (diffuse) or as a
// reflection (specular). The pixels on the image's edges use the normals of the SVG spec's edge kernels.
func feLightingApplySoftware(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FELightingParameters,
    _ lightSource: borrowing WebCore.LightSourceParameters,
    _ lightingColor: WebCore.FilterColorComponents,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let destination = result.pixelBuffer(.Premultiplied).get() else {
        return false
    }
    // An input that can't be copied (one outside the result) is lit as transparent black.
    if !input.copyPixelBuffer(into: destination, sourceRect: result.absoluteImageRect(relativeTo: input)) {
        destination.zeroFill()
    }

    // FIXME: support kernelUnitLengths other than (1,1). The issue here is that the W3 standard has no test case for them,
    // and other browsers (like Firefox) has strange output for various kernelUnitLengths, and I am not sure they are
    // reliable. Anyway, feConvolveMatrix should also use the implementation

    // FIXME: do something if width or height (or both) is 1 pixel. The W3 spec does not define this case. Now the
    // filter just returns.
    let size = result.absoluteImageRect.size()
    let width = Int(size.width())
    let height = Int(size.height())
    if width <= 2 || height <= 2 {
        return true
    }

    let surface = LightingSurface(parameters)
    let model = LightingModel(lightSource, lightingColor: lightingColor, context: context, result: result)

    var destinationAccess = WebCore.PixelBufferAccess(destination)
    var pixels: MutableSpan<UInt8> = destinationAccess.mutableSpan()
    // A pixel's light depends on its neighbors' alpha, which the rows written before it have replaced: read a copy.
    let alphaPlane = lightingAlphaPlane(pixels.bytes, count: width * height)
    let alpha = alphaPlane.span

    let jobs = feLightingJobCount(width: width, height: height)
    let painted = parallelRows(height: height, jobs: jobs, rowBytes: 4 * width, into: &pixels) { rows, output in
        paintLightingRows(rows, into: &output, alpha: alpha, width: width, height: height, model: model, surface: surface)
    }
    // The alpha plane's reads have checked that each pixel is in the buffer.
    precondition(painted)
    return true
}

// The alpha of the first `count` RGBA pixels of `pixels`, four pixels per load. Traps if `pixels` is shorter.
private func lightingAlphaPlane(_ pixels: RawSpan, count: Int) -> ContiguousArray<UInt8> {
    var alphaPlane = ContiguousArray<UInt8>(repeating: 0, count: count)
    var alpha = alphaPlane.mutableSpan
    var alphaBytes = alpha.mutableBytes
    var index = 0
    while index + 4 <= count {
        let quad = pixels.load(fromByteOffset: 4 * index, as: SIMD16<UInt8>.self)
        alphaBytes.storeBytes(of: SIMD4<UInt8>(quad[3], quad[7], quad[11], quad[15]), toByteOffset: index, as: SIMD4<UInt8>.self)
        index += 4
    }
    while index < count {
        alphaBytes.storeBytes(of: pixels.load(fromByteOffset: 4 * index + 3, as: UInt8.self), toByteOffset: index, as: UInt8.self)
        index += 1
    }
    return alphaPlane
}

// What the lighting of a surface pixel needs from the effect's parameters.
private struct LightingSurface: Sendable {
    let isDiffuse: Bool
    // The surface height per unit of alpha.
    let surfaceScale: Float
    let diffuseConstant: Float
    let specularConstant: Float
    let specularExponent: Float

    init(_ parameters: borrowing WebCore.FELightingParameters) {
        isDiffuse = parameters.type == .Diffuse
        surfaceScale = parameters.surfaceScale / 255
        diffuseConstant = parameters.diffuseConstant
        specularConstant = parameters.specularConstant
        specularExponent = parameters.specularExponent
    }
}

// The factors of the normals of https://www.w3.org/TR/SVG/filters.html#feDiffuseLightingElement: at the corners, on the
// top and bottom rows, on the left and right columns, and inside.
private var cornerFactors: (Float, Float) { (-2 / 3, -2 / 3) }
private var rowFactors: (Float, Float) { (-1 / 3, -1 / 2) }
private var columnFactors: (Float, Float) { (-1 / 2, -1 / 3) }
private var interiorFactors: (Float, Float) { (-1 / 4, -1 / 4) }

// Lights the rows `rows` of the image into `output`, which holds just those rows, from the image's alpha plane. (While
// loops: Debug builds don't optimize Swift, and a range loop there costs generic calls per pixel.)
private func paintLightingRows(
    _ rows: Range<Int>,
    into output: inout MutableSpan<UInt8>,
    alpha: Span<UInt8>,
    width: Int,
    height: Int,
    model: LightingModel,
    surface: LightingSurface
) {
    var out = output.mutableBytes
    var y = rows.lowerBound
    while y < rows.upperBound {
        paintLightingRow(
            y,
            into: &out,
            at: (y - rows.lowerBound) * 4 * width,
            alpha: alpha,
            width: width,
            height: height,
            model: model,
            surface: surface
        )
        y += 1
    }
}

private func paintLightingRow(
    _ y: Int,
    into out: inout MutableRawSpan,
    at start: Int,
    alpha: Span<UInt8>,
    width: Int,
    height: Int,
    model: LightingModel,
    surface: LightingSurface
) {
    let last = width - 1
    let row = alpha.extracting(y * width..<(y + 1) * width)
    if y == 0 {
        let bottom = alpha.extracting(width..<2 * width)
        store(edgePixel(model, surface, 0, y, cornerFactors, topLeftNormal(row, bottom), row[0]), &out, start)
        var x = 1
        while x < last {
            store(edgePixel(model, surface, x, y, rowFactors, topRowNormal(x, row, bottom), row[x]), &out, start + 4 * x)
            x += 1
        }
        store(edgePixel(model, surface, last, y, cornerFactors, topRightNormal(last, row, bottom), row[last]), &out, start + 4 * last)
        return
    }

    let top = alpha.extracting((y - 1) * width..<y * width)
    if y == height - 1 {
        store(edgePixel(model, surface, 0, y, cornerFactors, bottomLeftNormal(top, row), row[0]), &out, start)
        var x = 1
        while x < last {
            store(edgePixel(model, surface, x, y, rowFactors, bottomRowNormal(x, top, row), row[x]), &out, start + 4 * x)
            x += 1
        }
        store(edgePixel(model, surface, last, y, cornerFactors, bottomRightNormal(last, top, row), row[last]), &out, start + 4 * last)
        return
    }

    let bottom = alpha.extracting((y + 1) * width..<(y + 2) * width)
    store(edgePixel(model, surface, 0, y, columnFactors, leftColumnNormal(top, row, bottom), row[0]), &out, start)
    // Inside, the 3x3 alpha window around the pixel moves one column at a time.
    var (topLeft, topCenter) = (a(top, 0), a(top, 1))
    var (left, center) = (a(row, 0), a(row, 1))
    var (bottomLeft, bottomCenter) = (a(bottom, 0), a(bottom, 1))
    var x = 1
    while x < last {
        let (topRight, right, bottomRight) = (a(top, x + 1), a(row, x + 1), a(bottom, x + 1))
        let normal = (
            -topLeft + topRight - 2 * left + 2 * right - bottomLeft + bottomRight,
            -topLeft - 2 * topCenter - topRight + bottomLeft + 2 * bottomCenter + bottomRight
        )
        store(litPixel(model, surface, x, y, interiorFactors, normal, UInt8(truncatingIfNeeded: center)), &out, start + 4 * x)
        (topLeft, topCenter) = (topCenter, topRight)
        (left, center) = (center, right)
        (bottomLeft, bottomCenter) = (bottomCenter, bottomRight)
        x += 1
    }
    store(edgePixel(model, surface, last, y, columnFactors, rightColumnNormal(last, top, row, bottom), row[last]), &out, start + 4 * last)
}

// The 2D normals of the SVG spec's edge kernels at column x, from the alpha of the pixel's row (`row`) and of the rows
// above (`top`) and below (`bottom`) it.
@inline(__always)
private func topLeftNormal(_ row: Span<UInt8>, _ bottom: Span<UInt8>) -> (Int, Int) {
    let (center, right, below, belowRight) = (a(row, 0), a(row, 1), a(bottom, 0), a(bottom, 1))
    return (-2 * center + 2 * right - below + belowRight, -2 * center - right + 2 * below + belowRight)
}

@inline(__always)
private func topRowNormal(_ x: Int, _ row: Span<UInt8>, _ bottom: Span<UInt8>) -> (Int, Int) {
    let (left, center, right) = (a(row, x - 1), a(row, x), a(row, x + 1))
    let (belowLeft, below, belowRight) = (a(bottom, x - 1), a(bottom, x), a(bottom, x + 1))
    return (-2 * left + 2 * right - belowLeft + belowRight, -left - 2 * center - right + belowLeft + 2 * below + belowRight)
}

@inline(__always)
private func topRightNormal(_ x: Int, _ row: Span<UInt8>, _ bottom: Span<UInt8>) -> (Int, Int) {
    let (left, center, belowLeft, below) = (a(row, x - 1), a(row, x), a(bottom, x - 1), a(bottom, x))
    return (-2 * left + 2 * center - belowLeft + below, -left - 2 * center + belowLeft + 2 * below)
}

@inline(__always)
private func leftColumnNormal(_ top: Span<UInt8>, _ row: Span<UInt8>, _ bottom: Span<UInt8>) -> (Int, Int) {
    let (above, aboveRight, center, right) = (a(top, 0), a(top, 1), a(row, 0), a(row, 1))
    let (below, belowRight) = (a(bottom, 0), a(bottom, 1))
    return (-above + aboveRight - 2 * center + 2 * right - below + belowRight, -2 * above - aboveRight + 2 * below + belowRight)
}

@inline(__always)
private func rightColumnNormal(_ x: Int, _ top: Span<UInt8>, _ row: Span<UInt8>, _ bottom: Span<UInt8>) -> (Int, Int) {
    let (aboveLeft, above, left, center) = (a(top, x - 1), a(top, x), a(row, x - 1), a(row, x))
    let (belowLeft, below) = (a(bottom, x - 1), a(bottom, x))
    return (-aboveLeft + above - 2 * left + 2 * center - belowLeft + below, -aboveLeft - 2 * above + belowLeft + 2 * below)
}

@inline(__always)
private func bottomLeftNormal(_ top: Span<UInt8>, _ row: Span<UInt8>) -> (Int, Int) {
    let (above, aboveRight, center, right) = (a(top, 0), a(top, 1), a(row, 0), a(row, 1))
    return (-above + aboveRight - 2 * center + 2 * right, -2 * above - aboveRight + 2 * center + right)
}

@inline(__always)
private func bottomRowNormal(_ x: Int, _ top: Span<UInt8>, _ row: Span<UInt8>) -> (Int, Int) {
    let (aboveLeft, above, aboveRight) = (a(top, x - 1), a(top, x), a(top, x + 1))
    let (left, center, right) = (a(row, x - 1), a(row, x), a(row, x + 1))
    return (-aboveLeft + aboveRight - 2 * left + 2 * right, -aboveLeft - 2 * above - aboveRight + left + 2 * center + right)
}

@inline(__always)
private func bottomRightNormal(_ x: Int, _ top: Span<UInt8>, _ row: Span<UInt8>) -> (Int, Int) {
    let (aboveLeft, above, left, center) = (a(top, x - 1), a(top, x), a(row, x - 1), a(row, x))
    return (-aboveLeft + above - 2 * left + 2 * center, -aboveLeft - 2 * above + left + 2 * center)
}

@inline(__always)
private func a(_ row: Span<UInt8>, _ x: Int) -> Int {
    Int(row[x])
}

@inline(__always)
private func store(_ pixel: UInt32, _ bytes: inout MutableRawSpan, _ offset: Int) {
    bytes.storeBytes(of: pixel.littleEndian, toByteOffset: offset, as: UInt32.self)
}

// litPixel() for the pixels on the image's edges, kept out of line so that the interior loop, the only other caller,
// inlines it.
@inline(never)
private func edgePixel(
    _ model: LightingModel,
    _ surface: LightingSurface,
    _ x: Int,
    _ y: Int,
    _ factors: (Float, Float),
    _ normal: (Int, Int),
    _ alpha: UInt8
) -> UInt32 {
    litPixel(model, surface, x, y, factors, normal, alpha)
}

// The lit pixel at (x, y), RGBA packed little-endian (FELightingSoftwareApplier::setPixelInternal() and its alpha pass):
// `alpha` is its alpha, and `normal` times `factors` its 2D normal.
@inline(__always)
private func litPixel(
    _ model: LightingModel,
    _ surface: LightingSurface,
    _ x: Int,
    _ y: Int,
    _ factors: (Float, Float),
    _ normal: (Int, Int),
    _ alpha: UInt8
) -> UInt32 {
    let light = model.pixelLight(x: x, y: y, z: Float(alpha) * surface.surfaceScale)
    var lightStrength: Float
    if normal.0 == 0 && normal.1 == 0 {
        // The normal is (0, 0, 1): a frequent case.
        if surface.isDiffuse {
            lightStrength = surface.diffuseConstant * light.z / light.length
        } else {
            let halfwayZ = light.z + light.length
            let halfwayLength = LightingModel.length(light.x, light.y, halfwayZ)
            if surface.specularExponent == 1 {
                lightStrength = surface.specularConstant * halfwayZ / halfwayLength
            } else {
                lightStrength = surface.specularConstant * powf(halfwayZ / halfwayLength, surface.specularExponent)
            }
        }
    } else {
        let normalX = factors.0 * Float(normal.0) * surface.surfaceScale
        let normalY = factors.1 * Float(normal.1) * surface.surfaceScale
        let normalLength = LightingModel.length(normalX, normalY, 1)
        if surface.isDiffuse {
            let normalDotLight = LightingModel.dot(normalX, normalY, 1, light.x, light.y, light.z)
            lightStrength = surface.diffuseConstant * normalDotLight / (normalLength * light.length)
        } else {
            let halfwayZ = light.z + light.length
            let halfwayLength = LightingModel.length(light.x, light.y, halfwayZ)
            let normalDotHalfway = LightingModel.dot(normalX, normalY, 1, light.x, light.y, halfwayZ)
            if surface.specularExponent == 1 {
                lightStrength = surface.specularConstant * normalDotHalfway / (normalLength * halfwayLength)
            } else {
                lightStrength = surface.specularConstant * powf(normalDotHalfway / (normalLength * halfwayLength), surface.specularExponent)
            }
        }
    }
    if lightStrength > 1 {
        lightStrength = 1
    }
    if lightStrength < 0 {
        lightStrength = 0
    }
    // static_cast<uint8_t>: arm64 converts to a 32-bit integer and stores the low byte.
    let red = UInt8(truncatingIfNeeded: Int32(arm64Truncating: lightStrength * light.red * 255))
    let green = UInt8(truncatingIfNeeded: Int32(arm64Truncating: lightStrength * light.green * 255))
    let blue = UInt8(truncatingIfNeeded: Int32(arm64Truncating: lightStrength * light.blue * 255))
    // Diffuse lighting is opaque; specular lighting's alpha is its largest component.
    let resultAlpha = surface.isDiffuse ? 255 : (red >= green ? (red >= blue ? red : blue) : (green >= blue ? green : blue))
    return UInt32(red) | UInt32(green) << 8 | UInt32(blue) << 16 | UInt32(resultAlpha) << 24
}

#endif // ENABLE_WEBCORE_SWIFT
