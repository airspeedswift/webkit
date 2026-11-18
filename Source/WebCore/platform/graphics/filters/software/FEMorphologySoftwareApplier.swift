// Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
// Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
// Copyright (C) 2005 Eric Seidel <eric@webkit.org>
// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
// Copyright (C) Research In Motion Limited 2010. All rights reserved.
// Copyright (C) 2017-2026 Apple Inc. All rights reserved.
// Copyright (C) 2015 Google Inc. All rights reserved.
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
import WebCore_Private.Core.FEMorphologyParameters
import WebCore_Private.Core.FilterGraphicsBridge
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.FloatSize
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.IntSize
import WebCore_Private.Core.PixelBuffer
import WebCore_Private.Core.PixelBufferSwiftBridge

// FEMorphology::calculateImageRect().
func feMorphologyImageRect(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEMorphologyParameters,
    _ inputImageRect: WebCore.FloatRect,
    _ primitiveSubregion: WebCore.FloatRect
) -> WebCore.FloatRect {
    var imageRect = inputImageRect
    imageRect.inflate(context.resolvedSize(WebCore.FloatSize(parameters.radiusX, parameters.radiusY)))
    return context.clipToMaxEffectRect(imageRect, primitiveSubregion)
}

func feMorphologyApplySoftware(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FEMorphologyParameters,
    _ operatingColorSpace: borrowing WebCore.ColorSpace,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let destination = result.pixelBuffer(.Premultiplied).get() else {
        return false
    }

    let effectDrawingRect = result.absoluteImageRect(relativeTo: input)
    let radius = context.resolvedSize(WebCore.FloatSize(parameters.radiusX, parameters.radiusY))
    let absoluteRadius = WebCore.flooredIntSize(context.scaledByFilterScale(radius))
    if isDegenerateMorphologyRadius(absoluteRadius.width(), absoluteRadius.height()) {
        copyMorphologyInput(&input, into: destination, sourceRect: effectDrawingRect)
        return true
    }

    let radiusX = min(effectDrawingRect.width() - 1, absoluteRadius.width())
    let radiusY = min(effectDrawingRect.height() - 1, absoluteRadius.height())
    if isDegenerateMorphologyRadius(radiusX, radiusY) {
        copyMorphologyInput(&input, into: destination, sourceRect: effectDrawingRect)
        return true
    }

    guard let source = input.getPixelBuffer(.Premultiplied, sourceRect: effectDrawingRect, colorSpace: operatingColorSpace).get() else {
        return false
    }

    // The source has the size of the destination: both are the result's absolute image rect.
    let size = WebCore.FilterGraphicsBridge.size(source)
    let jobs = morphologyJobCount(width: size.width(), height: size.height(), radiusX: radiusX, radiusY: radiusY)
    let width = Int(size.width())
    let height = Int(size.height())
    let horizontalRadius = Int(radiusX)
    let verticalRadius = Int(radiusY)
    // MorphologyOperatorType.Unknown dilates, as in C++.
    let erode = parameters.type == .Erode

    let sourceAccess = WebCore.PixelBufferAccess(source)
    let sourceBytes: Span<UInt8> = sourceAccess.span()
    var destinationAccess = WebCore.PixelBufferAccess(destination)
    var destinationBytes: MutableSpan<UInt8> = destinationAccess.mutableSpan()
    return parallelRows(height: height, jobs: jobs, rowBytes: width * 4, into: &destinationBytes) { rows, output in
        let size = MorphologySize(width: width, height: height, radiusX: horizontalRadius, radiusY: verticalRadius)
        if erode {
            morphologyRows(MorphologyMinimum.self, sourceBytes, size, rows: rows, into: &output)
        } else {
            morphologyRows(MorphologyMaximum.self, sourceBytes, size, rows: rows, into: &output)
        }
    }
}

private func isDegenerateMorphologyRadius(_ width: Int32, _ height: Int32) -> Bool {
    width < 0 || height < 0 || (width == 0 && height == 0)
}

// The input, unchanged, or transparent black if it can't be copied.
private func copyMorphologyInput(_ input: inout FilterImageImpl, into destination: WebCore.PixelBuffer, sourceRect: WebCore.IntRect) {
    if !input.copyPixelBuffer(into: destination, sourceRect: sourceRect) {
        destination.zeroFill()
    }
}

// The number of jobs that compute the rows: the estimated cost over that of 160 x 160 pixels per job, at most one job per
// 8 rows, and one job if the blocks of rows would be no taller than the margin of 3 radiusY rows above and below them.
private func morphologyJobCount(width: Int32, height: Int32, radiusX: Int32, radiusY: Int32) -> Int {
    // Empirically, runtime is approximately linear over reasonable kernel sizes with a slope of about 0.65.
    let kernelFactor = Float(Double(radiusX &* radiusY).squareRoot() * 0.65)
    let kernelSizeY = 2 &* radiusY
    let extraHeight = Int32(arm64Truncating: Float(3 &* kernelSizeY) * 0.5)
    // Empirical data limit for parallel jobs.
    let minimalArea: Int32 = 160 * 160
    let maxNumThreads = UInt32(truncatingIfNeeded: height / 8)
    let area = Float((Int64(width) * Int64(height)).magnitude) * kernelFactor
    let jobs = min(UInt32(arm64Truncating: area / Float(minimalArea &+ extraHeight &* width)), maxNumThreads)
    if jobs <= 1 || height / Int32(bitPattern: jobs) <= extraHeight {
        return 1
    }
    return Int(jobs)
}

// The two operators, as the extremum of two vectors and the value that leaves the other unchanged. (NEON because the
// generic pointwiseMin and pointwiseMax are lane-by-lane calls in unoptimized builds, 35 times slower here.)
// FIXME: Make this private once a private type links under ThinLTO on Windows ("Invalid weak external").
protocol MorphologyExtremum {
    static var identity: UInt8 { get }
    static func extremum(_ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>) -> SIMD16<UInt8>
    static func extremum(_ a: SIMD4<UInt8>, _ b: SIMD4<UInt8>) -> SIMD4<UInt8>
}

// FIXME: Make this private once a private type links under ThinLTO on Windows ("Invalid weak external").
enum MorphologyMinimum: MorphologyExtremum {
    static var identity: UInt8 { .max }

    @inline(__always)
    static func extremum(_ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>) -> SIMD16<UInt8> {
        #if arch(arm64)
        vminq_u8(a, b)
        #else
        pointwiseMin(a, b)
        #endif
    }

    @inline(__always)
    static func extremum(_ a: SIMD4<UInt8>, _ b: SIMD4<UInt8>) -> SIMD4<UInt8> {
        pointwiseMin(a, b)
    }
}

// FIXME: Make this private once a private type links under ThinLTO on Windows ("Invalid weak external").
enum MorphologyMaximum: MorphologyExtremum {
    static var identity: UInt8 { .min }

    @inline(__always)
    static func extremum(_ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>) -> SIMD16<UInt8> {
        #if arch(arm64)
        vmaxq_u8(a, b)
        #else
        pointwiseMax(a, b)
        #endif
    }

    @inline(__always)
    static func extremum(_ a: SIMD4<UInt8>, _ b: SIMD4<UInt8>) -> SIMD4<UInt8> {
        pointwiseMax(a, b)
    }
}

// A tightly packed image of width x height 4-byte pixels, and the radii of the morphology.
private struct MorphologySize {
    var width: Int
    var height: Int
    var radiusX: Int
    var radiusY: Int
}

// The rows `rows` of the morphology of `source`, into `output`, which holds exactly those rows: each byte becomes the
// extremum of that byte over the pixels at most radiusX columns and radiusY rows away that are inside the image. A row
// takes the extremum of each column over the rows first, then of those column extrema over the columns. The column
// extrema of a row are kept with radiusX identity pixels on each side, so that every pixel's window has the same size.
private func morphologyRows<Extremum: MorphologyExtremum>(
    _ extremum: Extremum.Type,
    _ source: Span<UInt8>,
    _ size: MorphologySize,
    rows: Range<Int>,
    into output: inout MutableSpan<UInt8>
) {
    let rowBytes = size.width * 4
    let padding = size.radiusX * 4
    var columnExtrema = ContiguousArray<UInt8>(repeating: Extremum.identity, count: rowBytes + 2 * padding)
    let sourceBytes = source.bytes
    var outputBytes = output.mutableBytes
    for y in rows {
        let windowRows = max(0, y - size.radiusY)..<min(size.height, y + size.radiusY + 1)
        do {
            var columns = columnExtrema.mutableSpan
            var columnBytes = columns.mutableBytes
            storeRowExtrema(
                Extremum.self,
                sourceBytes,
                rowBytes: rowBytes,
                at: windowRows.lowerBound * rowBytes,
                step: rowBytes,
                count: windowRows.count,
                into: &columnBytes,
                at: padding
            )
        }
        storeRowExtrema(
            Extremum.self,
            columnExtrema.span.bytes,
            rowBytes: rowBytes,
            at: 0,
            step: 4,
            count: 2 * size.radiusX + 1,
            into: &outputBytes,
            at: (y - rows.lowerBound) * rowBytes
        )
    }
}

// Stores at destinationOffset the row of rowBytes bytes whose bytes are each the extremum of the bytes at the same place
// in the `count` rows of `source` that start at sourceOffset, `step` bytes apart: the column extrema of a row (`step` is
// a row) or the window extrema of the column extrema (`step` is a pixel).
@inline(__always)
private func storeRowExtrema<Extremum: MorphologyExtremum>(
    _ extremum: Extremum.Type,
    _ source: RawSpan,
    rowBytes: Int,
    at sourceOffset: Int,
    step: Int,
    count: Int,
    into destination: inout MutableRawSpan,
    at destinationOffset: Int
) {
    if rowBytes < 16 {
        var column = 0
        while column < rowBytes {
            var start = sourceOffset + column
            let end = start + count * step
            var a = source.load(fromByteOffset: start, as: SIMD4<UInt8>.self)
            start += step
            while start < end {
                a = Extremum.extremum(a, source.load(fromByteOffset: start, as: SIMD4<UInt8>.self))
                start += step
            }
            destination.storeBytes(of: a, toByteOffset: destinationOffset + column, as: SIMD4<UInt8>.self)
            column += 4
        }
        return
    }
    var column = 0
    while column + 64 <= rowBytes {
        var start = sourceOffset + column
        let end = start + count * step
        var block = source.extracting(start..<start + 64)
        var a0 = block.load(fromByteOffset: 0, as: SIMD16<UInt8>.self)
        var a1 = block.load(fromByteOffset: 16, as: SIMD16<UInt8>.self)
        var a2 = block.load(fromByteOffset: 32, as: SIMD16<UInt8>.self)
        var a3 = block.load(fromByteOffset: 48, as: SIMD16<UInt8>.self)
        start += step
        while start < end {
            block = source.extracting(start..<start + 64)
            a0 = Extremum.extremum(a0, block.load(fromByteOffset: 0, as: SIMD16<UInt8>.self))
            a1 = Extremum.extremum(a1, block.load(fromByteOffset: 16, as: SIMD16<UInt8>.self))
            a2 = Extremum.extremum(a2, block.load(fromByteOffset: 32, as: SIMD16<UInt8>.self))
            a3 = Extremum.extremum(a3, block.load(fromByteOffset: 48, as: SIMD16<UInt8>.self))
            start += step
        }
        withMutableSubspan(of: &destination, destinationOffset + column..<destinationOffset + column + 64) { output in
            output.storeBytes(of: a0, toByteOffset: 0, as: SIMD16<UInt8>.self)
            output.storeBytes(of: a1, toByteOffset: 16, as: SIMD16<UInt8>.self)
            output.storeBytes(of: a2, toByteOffset: 32, as: SIMD16<UInt8>.self)
            output.storeBytes(of: a3, toByteOffset: 48, as: SIMD16<UInt8>.self)
        }
        column += 64
    }
    while column < rowBytes {
        // The last 16 bytes of a row that isn't a multiple of 16 overlap bytes already stored, with the same values.
        if column > rowBytes - 16 {
            column = rowBytes - 16
        }
        var start = sourceOffset + column
        let end = start + count * step
        var a = source.load(fromByteOffset: start, as: SIMD16<UInt8>.self)
        start += step
        while start < end {
            a = Extremum.extremum(a, source.load(fromByteOffset: start, as: SIMD16<UInt8>.self))
            start += step
        }
        destination.storeBytes(of: a, toByteOffset: destinationOffset + column, as: SIMD16<UInt8>.self)
        column += 16
    }
}

#endif // ENABLE_WEBCORE_SWIFT
