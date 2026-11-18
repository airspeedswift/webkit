// Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
// Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
// Copyright (C) 2005 Eric Seidel <eric@webkit.org>
// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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
// Copyright (C) 2024 Igalia S.L.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// Copyright (C) 2020-2026 Apple Inc. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT

// The safe MutableSpan overload Swift synthesizes for PixelBufferAccess.mutableSpan() calls Cxx's
// MutableSpan(_unsafeCxxSpan:). Xcode builds don't find it unless this file imports Cxx.
private import Cxx
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import ucrt
#endif
#if arch(arm64)
import _Builtin_intrinsics.arm.neon
#endif
import WebCore_Private.Core.AlphaPremultiplication
import WebCore_Private.Core.ColorSpace
import WebCore_Private.Core.FEColorMatrixParameters
import WebCore_Private.Core.FilterGraphicsBridge
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntPoint
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.IntSize
import WebCore_Private.Core.PixelBuffer
import WebCore_Private.Core.PixelBufferFormat
import WebCore_Private.Core.PixelBufferSwiftBridge
import WebCore_Private.Core.PixelFormat
#if USE_SKIA
import WebCore_Private.Core.FilterSkiaBridge
#endif

// FEColorMatrixSoftwareApplier::apply(): draws the input into the result's image buffer, then applies the matrix to its
// unpremultiplied pixels.
func feColorMatrixApplySoftware(
    _ parameters: FEColorMatrixValues,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    let type = parameters.type
    let values: Span<Float> = parameters.values.span
    // Fails for a list with fewer values than the type reads, which the IPC decoder and the DOM reject.
    guard values.count >= feColorMatrixRequiredValueCount(type) else {
        return false
    }

    guard let resultImage = result.imageBuffer().get() else {
        return false
    }
    if let inputImage = input.imageBuffer().get() {
        filterDrawImageBuffer(resultImage, inputImage, input.absoluteImageRect(relativeTo: result))
    }

    let format = WebCore.PixelBufferFormat(alphaFormat: .Unpremultiplied, pixelFormat: .RGBA8, colorSpace: result.colorSpace)
    let imageRect = WebCore.IntRect(WebCore.IntPoint(), resultImage.truncatedLogicalSize())
    guard let pixelBuffer = WebCore.FEColorMatrixBridge.getPixelBuffer(resultImage, format, imageRect).get() else {
        return false
    }

    let size = WebCore.FilterGraphicsBridge.size(pixelBuffer)
    var access = WebCore.PixelBufferAccess(pixelBuffer)
    var pixels: MutableSpan<UInt8> = access.mutableSpan()
    applyColorMatrix(type, values, to: &pixels, width: Int(size.width()), height: Int(size.height()))

    WebCore.FilterGraphicsBridge.putPixelBuffer(resultImage, pixelBuffer, imageRect)
    return true
}

#if USE_SKIA
// FEColorMatrixSkiaApplier::apply(): Skia draws the input through the 5 x 4 matrix (FilterSkiaBridge.cpp).
func feColorMatrixApplySkia(
    _ parameters: FEColorMatrixValues,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    let type = parameters.type
    let values: Span<Float> = parameters.values.span
    // Fails for a list with fewer values than the type reads.
    guard values.count >= feColorMatrixRequiredValueCount(type) else {
        return false
    }

    let resultImage = result.imageBuffer()
    let sourceImage = input.imageBuffer()
    guard let resultImage = resultImage.get(), let sourceImage = sourceImage.get() else {
        return false
    }

    var matrix = ContiguousArray<Float>()
    switch type {
    case .FECOLORMATRIX_TYPE_MATRIX:
        // Skia reads the first 20 values.
        for index in 0..<20 {
            matrix.append(feColorMatrixNormalizedFloat(values[index]))
        }
    case .FECOLORMATRIX_TYPE_SATURATE, .FECOLORMATRIX_TYPE_HUEROTATE:
        let value = feColorMatrixNormalizedFloat(values[0])
        let c =
            type == .FECOLORMATRIX_TYPE_SATURATE ? feColorMatrixSaturateComponents(value) : feColorMatrixHueRotateComponents(value)
        matrix = [
            c.0, c.1, c.2, 0, 0,
            c.3, c.4, c.5, 0, 0,
            c.6, c.7, c.8, 0, 0,
            0, 0, 0, 1, 0,
        ]
    case .FECOLORMATRIX_TYPE_LUMINANCETOALPHA:
        matrix = [
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
            0.2125, 0.7154, 0.0721, 0, 0,
        ]
    case .FECOLORMATRIX_TYPE_UNKNOWN:
        return false
    @unknown default:
        return false
    }

    let inputOffsetWithinResult = input.absoluteImageRect(relativeTo: result).location()
    return WebCore.FilterSkiaBridge.drawColorMatrix(resultImage, sourceImage, matrix.span, inputOffsetWithinResult)
}
#endif

// The nine components of FEColorMatrix::calculateSaturateComponents() and calculateHueRotateComponents(): the red, green
// and blue rows of a 3 x 3 matrix, as the software, Core Image and Skia appliers use them.
typealias FEColorMatrixComponents = (Float, Float, Float, Float, Float, Float, Float, Float, Float)

// ColorMatrix.h's saturationColorMatrix().
func feColorMatrixSaturateComponents(_ amount: Float) -> FEColorMatrixComponents {
    let r0: Float = 0.213 + 0.787 * amount
    let r1: Float = 0.715 - 0.715 * amount
    let r2: Float = 0.072 - 0.072 * amount
    let g0: Float = 0.213 - 0.213 * amount
    let g1: Float = 0.715 + 0.285 * amount
    let g2: Float = 0.072 - 0.072 * amount
    let b0: Float = 0.213 - 0.213 * amount
    let b1: Float = 0.715 - 0.715 * amount
    let b2: Float = 0.072 + 0.928 * amount
    return (r0, r1, r2, g0, g1, g2, b0, b1, b2)
}

// ColorMatrix.h's hueRotateColorMatrix().
func feColorMatrixHueRotateComponents(_ angleInDegrees: Float) -> FEColorMatrixComponents {
    // deg2rad(float): radiansPerDegreeFloat is pi_v<float> / 180 in float (Float.pi is rounded down, pi_v<float> isn't).
    let angle = angleInDegrees * (Float(Double.pi) / 180)
    // cosf and sinf: Darwin's overlay has Float overloads of cos and sin, the C runtimes of the other ports do not.
    let cosHue = cosf(angle)
    let sinHue = sinf(angle)
    let r0: Float = 0.213 + cosHue * 0.787 - sinHue * 0.213
    let r1: Float = 0.715 - cosHue * 0.715 - sinHue * 0.715
    let r2: Float = 0.072 - cosHue * 0.072 + sinHue * 0.928
    let g0: Float = 0.213 - cosHue * 0.213 + sinHue * 0.143
    let g1: Float = 0.715 + cosHue * 0.285 + sinHue * 0.140
    let g2: Float = 0.072 - cosHue * 0.072 - sinHue * 0.283
    let b0: Float = 0.213 - cosHue * 0.213 - sinHue * 0.787
    let b1: Float = 0.715 - cosHue * 0.715 + sinHue * 0.715
    let b2: Float = 0.072 + cosHue * 0.928 + sinHue * 0.072
    return (r0, r1, r2, g0, g1, g2, b0, b1, b2)
}

// The values a type reads (FEColorMatrix::areValuesValidForType() asks for exactly this many, except that
// luminanceToAlpha takes any). Values past these are ignored, as in C++.
func feColorMatrixRequiredValueCount(_ type: WebCore.ColorMatrixType) -> Int {
    switch type {
    case .FECOLORMATRIX_TYPE_MATRIX:
        return 20
    case .FECOLORMATRIX_TYPE_SATURATE, .FECOLORMATRIX_TYPE_HUEROTATE:
        return 1
    case .FECOLORMATRIX_TYPE_LUMINANCETOALPHA, .FECOLORMATRIX_TYPE_UNKNOWN:
        return 0
    @unknown default:
        return 0
    }
}

// WTF::normalizedFloat() (FEColorMatrix::normalizedFloats()): denormals become the smallest normal float of the same
// sign.
func feColorMatrixNormalizedFloat(_ value: Float) -> Float {
    if value > 0 && value < Float.leastNormalMagnitude {
        return Float.leastNormalMagnitude
    }
    if value < 0 && value > -Float.leastNormalMagnitude {
        return -Float.leastNormalMagnitude
    }
    return value
}

// FEColorMatrixSoftwareApplier::applyPlatform(): `pixels` holds the width x height RGBA8 pixels of a pixel buffer.
private func applyColorMatrix(
    _ type: WebCore.ColorMatrixType,
    _ values: Span<Float>,
    to pixels: inout MutableSpan<UInt8>,
    width: Int,
    height: Int
) {
    #if USE_ACCELERATE
    // vImageMatrixMultiply_ARGB8888 takes a 4 x 4 matrix: a matrix with a nonzero offset (last column) takes the
    // floating-point path.
    if type != .FECOLORMATRIX_TYPE_MATRIX || (values[4] == 0 && values[9] == 0 && values[14] == 0 && values[19] == 0) {
        applyColorMatrixAccelerated(type, values, to: &pixels, width: width, height: height)
        return
    }
    #endif
    var bytes = pixels.mutableBytes
    applyColorMatrixUnaccelerated(type, values, to: &bytes)
}

#if USE_ACCELERATE
// FEColorMatrixSoftwareApplier::applyPlatformAccelerated(): the matrix in 8.8 fixed point, in place through vImage.
private func applyColorMatrixAccelerated(
    _ type: WebCore.ColorMatrixType,
    _ values: Span<Float>,
    to pixels: inout MutableSpan<UInt8>,
    width: Int,
    height: Int
) {
    let divisor: Int32 = 256
    let matrix: SIMD16<Int16>
    switch type {
    case .FECOLORMATRIX_TYPE_UNKNOWN:
        return
    case .FECOLORMATRIX_TYPE_MATRIX:
        matrix = SIMD16(
            vImageCoefficient(values[0], divisor),
            vImageCoefficient(values[5], divisor),
            vImageCoefficient(values[10], divisor),
            vImageCoefficient(values[15], divisor),

            vImageCoefficient(values[1], divisor),
            vImageCoefficient(values[6], divisor),
            vImageCoefficient(values[11], divisor),
            vImageCoefficient(values[16], divisor),

            vImageCoefficient(values[2], divisor),
            vImageCoefficient(values[7], divisor),
            vImageCoefficient(values[12], divisor),
            vImageCoefficient(values[17], divisor),

            vImageCoefficient(values[3], divisor),
            vImageCoefficient(values[8], divisor),
            vImageCoefficient(values[13], divisor),
            vImageCoefficient(values[18], divisor)
        )
    case .FECOLORMATRIX_TYPE_SATURATE, .FECOLORMATRIX_TYPE_HUEROTATE:
        let c =
            type == .FECOLORMATRIX_TYPE_SATURATE
            ? feColorMatrixSaturateComponents(values[0]) : feColorMatrixHueRotateComponents(values[0])
        matrix = SIMD16(
            vImageCoefficient(c.0, divisor),
            vImageCoefficient(c.3, divisor),
            vImageCoefficient(c.6, divisor),
            0,

            vImageCoefficient(c.1, divisor),
            vImageCoefficient(c.4, divisor),
            vImageCoefficient(c.7, divisor),
            0,

            vImageCoefficient(c.2, divisor),
            vImageCoefficient(c.5, divisor),
            vImageCoefficient(c.8, divisor),
            0,

            0,
            0,
            0,
            Int16(divisor)
        )
    case .FECOLORMATRIX_TYPE_LUMINANCETOALPHA:
        // Double products, as in C++.
        matrix = SIMD16(
            0,
            0,
            0,
            vImageCoefficient(Float(0.2125 * Double(divisor))),

            0,
            0,
            0,
            vImageCoefficient(Float(0.7154 * Double(divisor))),

            0,
            0,
            0,
            vImageCoefficient(Float(0.0721 * Double(divisor))),

            0,
            0,
            0,
            0
        )
    @unknown default:
        return
    }
    vImageColorMatrixMultiply(&pixels, width: width, height: height, matrix: matrix, divisor: divisor)
}

// static_cast<int16_t>(roundf(value * divisor)).
private func vImageCoefficient(_ value: Float, _ divisor: Int32) -> Int16 {
    vImageCoefficient(value * Float(divisor))
}

// static_cast<int16_t>(roundf(product)): arm64 converts to 32 bits and keeps the low 16, so values of 128 or more wrap.
private func vImageCoefficient(_ product: Float) -> Int16 {
    Int16(truncatingIfNeeded: Int32(arm64Truncating: product.rounded(.toNearestOrAwayFromZero)))
}
#endif

// FEColorMatrixSoftwareApplier::applyPlatformUnaccelerated(): in floating point, pixel by pixel.
private func applyColorMatrixUnaccelerated(_ type: WebCore.ColorMatrixType, _ values: Span<Float>, to pixels: inout MutableRawSpan) {
    let byteCount = pixels.byteCount & ~3
    switch type {
    case .FECOLORMATRIX_TYPE_UNKNOWN:
        break

    case .FECOLORMATRIX_TYPE_MATRIX:
        // Output channel i is values[5i] * r + values[5i + 1] * g + values[5i + 2] * b + values[5i + 3] * a
        // + values[5i + 4] * 255, in that order, in each lane.
        let red = SIMD4<Float>(values[0], values[5], values[10], values[15])
        let green = SIMD4<Float>(values[1], values[6], values[11], values[16])
        let blue = SIMD4<Float>(values[2], values[7], values[12], values[17])
        let alpha = SIMD4<Float>(values[3], values[8], values[13], values[18])
        let offset = SIMD4<Float>(values[4], values[9], values[14], values[19]) * 255
        var byteOffset = 0
        while byteOffset < byteCount {
            #if arch(arm64)
            // NEON and concrete integer operations only: Debug builds don't specialize generic SIMD code.
            let pixel = UInt32(littleEndian: pixels.load(fromByteOffset: byteOffset, as: UInt32.self))
            var result = vmulq_f32(red, vdupq_n_f32(Float(pixel & 0xff)))
            result = vaddq_f32(result, vmulq_f32(green, vdupq_n_f32(Float((pixel &>> 8) & 0xff))))
            result = vaddq_f32(result, vmulq_f32(blue, vdupq_n_f32(Float((pixel &>> 16) & 0xff))))
            result = vaddq_f32(result, vmulq_f32(alpha, vdupq_n_f32(Float(pixel &>> 24))))
            result = vaddq_f32(result, offset)
            // FCVTNU (to nearest, ties to even, saturating, NaN to 0) and saturating narrowing: PixelBuffer::set()'s
            // clamp and lrint() in each lane.
            let halfwords = vqmovn_u32(vcvtnq_u32_f32(result))
            let bytes = vreinterpret_u32_u8(vqmovn_u16(vcombine_u16(halfwords, halfwords)))
            pixels.storeBytes(of: UInt32(littleEndian: bytes[0]), toByteOffset: byteOffset, as: UInt32.self)
            #else
            let pixel = pixels.load(fromByteOffset: byteOffset, as: SIMD4<UInt8>.self)
            let result = red * Float(pixel[0]) + green * Float(pixel[1]) + blue * Float(pixel[2]) + alpha * Float(pixel[3]) + offset
            pixels.storeBytes(of: clampedPixel(result), toByteOffset: byteOffset, as: SIMD4<UInt8>.self)
            #endif
            byteOffset &+= 4
        }

    case .FECOLORMATRIX_TYPE_SATURATE, .FECOLORMATRIX_TYPE_HUEROTATE:
        let c =
            type == .FECOLORMATRIX_TYPE_SATURATE
            ? feColorMatrixSaturateComponents(values[0]) : feColorMatrixHueRotateComponents(values[0])
        var byteOffset = 0
        while byteOffset < byteCount {
            var pixel = pixels.load(fromByteOffset: byteOffset, as: SIMD4<UInt8>.self)
            let r = Float(pixel[0])
            let g = Float(pixel[1])
            let b = Float(pixel[2])
            pixel[0] = clampedByte(r * c.0 + g * c.1 + b * c.2)
            pixel[1] = clampedByte(r * c.3 + g * c.4 + b * c.5)
            pixel[2] = clampedByte(r * c.6 + g * c.7 + b * c.8)
            pixels.storeBytes(of: pixel, toByteOffset: byteOffset, as: SIMD4<UInt8>.self)
            byteOffset &+= 4
        }

    case .FECOLORMATRIX_TYPE_LUMINANCETOALPHA:
        var byteOffset = 0
        while byteOffset < byteCount {
            let pixel = pixels.load(fromByteOffset: byteOffset, as: SIMD4<UInt8>.self)
            // Double arithmetic, stored in a float.
            let alpha = Float(0.2125 * Double(pixel[0]) + 0.7154 * Double(pixel[1]) + 0.0721 * Double(pixel[2]))
            pixels.storeBytes(of: SIMD4<UInt8>(0, 0, 0, clampedByte(alpha)), toByteOffset: byteOffset, as: SIMD4<UInt8>.self)
            byteOffset &+= 4
        }

    @unknown default:
        break
    }
}

@inline(__always)
private func clampedPixel(_ value: SIMD4<Float>) -> SIMD4<UInt8> {
    SIMD4(clampedByte(value[0]), clampedByte(value[1]), clampedByte(value[2]), clampedByte(value[3]))
}

// PixelBuffer::set() (JSC::Uint8ClampedAdaptor::toNativeFromDouble()) of a float: NaN and negative values become 0,
// values above 255 become 255, the rest are rounded to the nearest integer, ties to even (lrint).
@inline(__always)
private func clampedByte(_ value: Float) -> UInt8 {
    let clamped = value > 0 ? (value < 255 ? value : 255) : 0
    return UInt8(clamped.rounded(.toNearestOrEven))
}

#endif // ENABLE_WEBCORE_SWIFT
