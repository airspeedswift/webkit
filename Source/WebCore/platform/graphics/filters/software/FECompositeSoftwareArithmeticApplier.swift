// Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
// Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
// Copyright (C) 2005 Eric Seidel <eric@webkit.org>
// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
// Copyright (C) Research In Motion Limited 2010. All rights reserved.
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

#if ENABLE_WEBCORE_SWIFT

#if arch(arm64)
import _Builtin_intrinsics.arm.neon
#endif
// The safe Span overloads Swift synthesizes for PixelBufferAccess call Cxx's Span(_unsafeCxxSpan:). Xcode builds don't
// find it unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.AlphaPremultiplication
import WebCore_Private.Core.ColorSpace
import WebCore_Private.Core.FECompositeParameters
import WebCore_Private.Core.FilterGraphicsBridge
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.PixelBuffer
import WebCore_Private.Core.PixelBufferSwiftBridge

// FECompositeSoftwareArithmeticApplier::apply(): the arithmetic operator, k1 * i1 * i2 + k2 * i1 + k3 * i2 + k4 for each
// premultiplied component, with i1 from the first input and i2 from the second.
func feCompositeApplySoftwareArithmetic(
    _ parameters: borrowing WebCore.FECompositeParameters,
    _ operatingColorSpace: borrowing WebCore.ColorSpace,
    _ input: inout FilterImageImpl,
    _ input2: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let destination = result.pixelBuffer(.Premultiplied).get() else {
        return false
    }

    let effectADrawingRect = result.absoluteImageRect(relativeTo: input)
    guard let source = input.getPixelBuffer(.Premultiplied, sourceRect: effectADrawingRect, colorSpace: operatingColorSpace).get() else {
        return false
    }

    let effectBDrawingRect = result.absoluteImageRect(relativeTo: input2)
    let copied = input2.copyPixelBuffer(into: destination, sourceRect: effectBDrawingRect)
    compositeArithmeticInputs(parameters, source, destination, copied)
    return true
}

// feCompositeApplySoftwareArithmetic() with both inputs the same image, which can't be passed `inout` twice.
func feCompositeApplySoftwareArithmeticWithSameInputs(
    _ parameters: borrowing WebCore.FECompositeParameters,
    _ operatingColorSpace: borrowing WebCore.ColorSpace,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let destination = result.pixelBuffer(.Premultiplied).get() else {
        return false
    }

    let effectDrawingRect = result.absoluteImageRect(relativeTo: input)
    guard let source = input.getPixelBuffer(.Premultiplied, sourceRect: effectDrawingRect, colorSpace: operatingColorSpace).get() else {
        return false
    }

    let copied = input.copyPixelBuffer(into: destination, sourceRect: effectDrawingRect)
    compositeArithmeticInputs(parameters, source, destination, copied)
    return true
}

// Composites `source` (the first input) with `destination`, which holds the second input if `copied`.
private func compositeArithmeticInputs(
    _ parameters: borrowing WebCore.FECompositeParameters,
    _ source: WebCore.PixelBuffer,
    _ destination: WebCore.PixelBuffer,
    _ copied: Bool
) {
    if !copied {
        // Without the second input's pixels (an input outside the result), the first composites with transparent
        // black.
        destination.zeroFill()
    }

    let sourceAccess = WebCore.PixelBufferAccess(source)
    var destinationAccess = WebCore.PixelBufferAccess(destination)
    let sourceBytes: Span<UInt8> = sourceAccess.span()
    var destinationBytes: MutableSpan<UInt8> = destinationAccess.mutableSpan()
    let byteCount = sourceBytes.count
    assert(byteCount == destinationBytes.count)
    var destinationPixels = destinationBytes.mutableBytes
    compositeArithmetic(sourceBytes.bytes, &destinationPixels, byteCount, parameters.k1, parameters.k2, parameters.k3, parameters.k4)
}

// FECompositeSoftwareArithmeticApplier::applyPlatform(): replaces each byte i2 of `destination` with
// k1 * i1 * i2 + k2 * i1 + k3 * i2 + k4 in 0...255 units, i1 being the byte of `source`. As in the C++, a loop leaves out
// the k1 or k4 term when it is zero (NaN is not), and doesn't clamp when the k values keep every result in (-1, 256).
private func compositeArithmetic(
    _ source: RawSpan,
    _ destination: inout MutableRawSpan,
    _ byteCount: Int,
    _ k1: Float,
    _ k2: Float,
    _ k3: Float,
    _ k4: Float
) {
    precondition(byteCount <= destination.byteCount)

    // std::max(0.0f, k) and std::min(0.0f, k), spelled out: NaN gives 0.
    let upperLimit = (0 < k1 ? k1 : 0) + (0 < k2 ? k2 : 0) + (0 < k3 ? k3 : 0) + k4
    let lowerLimit = (k1 < 0 ? k1 : 0) + (k2 < 0 ? k2 : 0) + (k3 < 0 ? k3 : 0) + k4
    let clamping = !((k4 >= 0 && k4 <= 1) && (upperLimit >= 0 && upperLimit <= 1) && (lowerLimit >= 0 && lowerLimit <= 1))

    switch (k1 != 0, k4 != 0, clamping) {
    case (true, true, true):
        compositeArithmetic(source, &destination, byteCount, k1, k2, k3, k4, Included.self, Included.self, Included.self)
    case (false, true, true):
        compositeArithmetic(source, &destination, byteCount, k1, k2, k3, k4, Excluded.self, Included.self, Included.self)
    case (true, false, true):
        compositeArithmetic(source, &destination, byteCount, k1, k2, k3, k4, Included.self, Excluded.self, Included.self)
    case (false, false, true):
        compositeArithmetic(source, &destination, byteCount, k1, k2, k3, k4, Excluded.self, Excluded.self, Included.self)
    case (true, true, false):
        compositeArithmetic(source, &destination, byteCount, k1, k2, k3, k4, Included.self, Included.self, Excluded.self)
    case (false, true, false):
        compositeArithmetic(source, &destination, byteCount, k1, k2, k3, k4, Excluded.self, Included.self, Excluded.self)
    case (true, false, false):
        compositeArithmetic(source, &destination, byteCount, k1, k2, k3, k4, Included.self, Excluded.self, Excluded.self)
    case (false, false, false):
        compositeArithmetic(source, &destination, byteCount, k1, k2, k3, k4, Excluded.self, Excluded.self, Excluded.self)
    }
}

// The loops' compile-time options, as the C++ template parameters were.
// FIXME: Make this private once a private type links under ThinLTO on Windows ("Invalid weak external").
protocol ArithmeticLoopOption {
    static var isIncluded: Bool { get }
}

private enum Included: ArithmeticLoopOption {
    static var isIncluded: Bool { true }
}

private enum Excluded: ArithmeticLoopOption {
    static var isIncluded: Bool { false }
}

private struct ArithmeticCoefficients {
    let scaledK1: Float
    let k2: Float
    let k3: Float
    let scaledK4: Float
    let includesK1: Bool
    let includesK4: Bool
    #if arch(arm64)
    // Table lookup indices that zero-extend bytes 0-3, 4-7, 8-11 and 12-15 to UInt32 (255 is out of range, which reads 0).
    let wideningIndices: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>)
    #endif

    init(_ k1: Float, _ k2: Float, _ k3: Float, _ k4: Float, includesK1: Bool, includesK4: Bool) {
        scaledK1 = k1 / 255
        self.k2 = k2
        self.k3 = k3
        scaledK4 = k4 * 255
        self.includesK1 = includesK1
        self.includesK4 = includesK4
        #if arch(arm64)
        wideningIndices = (
            SIMD16<UInt8>(0, 255, 255, 255, 1, 255, 255, 255, 2, 255, 255, 255, 3, 255, 255, 255),
            SIMD16<UInt8>(4, 255, 255, 255, 5, 255, 255, 255, 6, 255, 255, 255, 7, 255, 255, 255),
            SIMD16<UInt8>(8, 255, 255, 255, 9, 255, 255, 255, 10, 255, 255, 255, 11, 255, 255, 255),
            SIMD16<UInt8>(12, 255, 255, 255, 13, 255, 255, 255, 14, 255, 255, 255, 15, 255, 255, 255)
        )
        #endif
    }

    // The C++ expression, operation by operation: (k2 * i1 + k3 * i2), then + (k1 / 255) * i1 * i2, then + k4 * 255.
    @inline(__always)
    func result(_ i1: Float, _ i2: Float) -> Float {
        var result = k2 * i1 + k3 * i2
        if includesK1 {
            result += scaledK1 * i1 * i2
        }
        if includesK4 {
            result += scaledK4
        }
        return result
    }

    #if arch(arm64)
    // The same with NEON operations, which unoptimized builds call directly, unlike the generic SIMD operators.
    @inline(__always)
    func result(_ i1: SIMD4<Float>, _ i2: SIMD4<Float>) -> SIMD4<Float> {
        var result = vaddq_f32(vmulq_n_f32(i1, k2), vmulq_n_f32(i2, k3))
        if includesK1 {
            result = vaddq_f32(result, vmulq_f32(vmulq_n_f32(i1, scaledK1), i2))
        }
        if includesK4 {
            result = vaddq_f32(result, vdupq_n_f32(scaledK4))
        }
        return result
    }
    #endif
}

private func compositeArithmetic<K1Term: ArithmeticLoopOption, K4Term: ArithmeticLoopOption, Clamping: ArithmeticLoopOption>(
    _ source: RawSpan,
    _ destination: inout MutableRawSpan,
    _ byteCount: Int,
    _ k1: Float,
    _ k2: Float,
    _ k3: Float,
    _ k4: Float,
    _: K1Term.Type,
    _: K4Term.Type,
    _: Clamping.Type
) {
    let k = ArithmeticCoefficients(k1, k2, k3, k4, includesK1: K1Term.isIncluded, includesK4: K4Term.isIncluded)
    let clamping = Clamping.isIncluded
    var offset = 0
    #if arch(arm64)
    while byteCount - offset >= 16 {
        let i1 = source.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)
        let i2 = destination.load(fromByteOffset: offset, as: SIMD16<UInt8>.self)
        destination.storeBytes(of: compositeArithmeticBytes(i1, i2, k, clamping: clamping), toByteOffset: offset, as: SIMD16<UInt8>.self)
        offset += 16
    }
    #endif
    while offset < byteCount {
        let i1 = Float(source.load(fromByteOffset: offset, as: UInt8.self))
        let i2 = Float(destination.load(fromByteOffset: offset, as: UInt8.self))
        let result = k.result(i1, i2)
        destination.storeBytes(of: clamping ? clampedByte(result) : truncatedByte(result), toByteOffset: offset, as: UInt8.self)
        offset += 1
    }
}

// clampByte(result): the float converted to int first, as arm64 converts it: saturating, with NaN as 0.
@inline(__always)
private func clampedByte(_ value: Float) -> UInt8 {
    let integer = Int32(arm64Truncating: value)
    return integer < 0 ? 0 : integer > 255 ? 255 : UInt8(truncatingIfNeeded: integer)
}

// The C++ conversion of a float to unsigned char, as arm64 does it: to int, then the low byte.
@inline(__always)
private func truncatedByte(_ value: Float) -> UInt8 {
    UInt8(truncatingIfNeeded: Int32(arm64Truncating: value))
}

#if arch(arm64)
@inline(__always)
private func compositeArithmeticBytes(
    _ i1: SIMD16<UInt8>,
    _ i2: SIMD16<UInt8>,
    _ k: ArithmeticCoefficients,
    clamping: Bool
) -> SIMD16<UInt8> {
    let components1 = floatComponents(i1, k.wideningIndices)
    let components2 = floatComponents(i2, k.wideningIndices)
    let results = (
        k.result(components1.0, components2.0), k.result(components1.1, components2.1),
        k.result(components1.2, components2.2), k.result(components1.3, components2.3)
    )
    return clamping ? clampedBytes(results) : truncatedBytes(results)
}

private typealias FloatComponents = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

// Each byte as a Float, exactly.
@inline(__always)
private func floatComponents(
    _ bytes: SIMD16<UInt8>,
    _ indices: (SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>, SIMD16<UInt8>)
) -> FloatComponents {
    (
        vcvtq_f32_u32(vreinterpretq_u32_u8(vqtbl1q_u8(bytes, indices.0))),
        vcvtq_f32_u32(vreinterpretq_u32_u8(vqtbl1q_u8(bytes, indices.1))),
        vcvtq_f32_u32(vreinterpretq_u32_u8(vqtbl1q_u8(bytes, indices.2))),
        vcvtq_f32_u32(vreinterpretq_u32_u8(vqtbl1q_u8(bytes, indices.3)))
    )
}

// truncatedByte() of 16 values in (-1, 256), where it is the same as FCVTZU (round toward zero, negative values to 0),
// then the low byte of each.
@inline(__always)
private func truncatedBytes(_ values: FloatComponents) -> SIMD16<UInt8> {
    lowBytes(vcvtq_u32_f32(values.0), vcvtq_u32_f32(values.1), vcvtq_u32_f32(values.2), vcvtq_u32_f32(values.3))
}

// clampedByte() of 16 values: FMIN keeps NaN, which FCVTZU turns into 0 as it does negative values, so each is 0...255.
@inline(__always)
private func clampedBytes(_ values: FloatComponents) -> SIMD16<UInt8> {
    let maximum = vdupq_n_f32(255)
    return lowBytes(
        vcvtq_u32_f32(vminq_f32(values.0, maximum)),
        vcvtq_u32_f32(vminq_f32(values.1, maximum)),
        vcvtq_u32_f32(vminq_f32(values.2, maximum)),
        vcvtq_u32_f32(vminq_f32(values.3, maximum))
    )
}

@inline(__always)
private func lowBytes(
    _ values0: SIMD4<UInt32>,
    _ values1: SIMD4<UInt32>,
    _ values2: SIMD4<UInt32>,
    _ values3: SIMD4<UInt32>
) -> SIMD16<UInt8> {
    let low = vuzp1q_u16(vreinterpretq_u16_u32(values0), vreinterpretq_u16_u32(values1))
    let high = vuzp1q_u16(vreinterpretq_u16_u32(values2), vreinterpretq_u16_u32(values3))
    return vuzp1q_u8(vreinterpretq_u8_u16(low), vreinterpretq_u8_u16(high))
}
#endif

#endif // ENABLE_WEBCORE_SWIFT
