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
//
// Copyright (C) 2024 Igalia S.L.
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

#if ENABLE_WEBCORE_SWIFT

// The safe Span overloads Swift synthesizes for C++ span accessors call Cxx's Span(_unsafeCxxSpan:). Xcode builds don't
// find it unless this file imports Cxx.
private import Cxx
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import ucrt
#endif
import WebCore_Private.Core.AlphaPremultiplication
import WebCore_Private.Core.FEComponentTransferParameters
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.PixelBuffer
import WebCore_Private.Core.PixelBufferSwiftBridge
#if USE_SKIA
import WebCore_Private.Core.FilterSkiaBridge
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntPoint
#endif

// FEComponentTransferSoftwareApplier::apply().
func feComponentTransferApplySoftware(
    _ parameters: FEComponentTransferValues,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let destination = result.pixelBuffer(.Unpremultiplied).get() else {
        return false
    }

    let drawingRect = result.absoluteImageRect(relativeTo: input)
    if !input.copyPixelBuffer(into: destination, sourceRect: drawingRect) {
        // Without the input's pixels, the tables apply to transparent black.
        destination.zeroFill()
    }

    let tables = componentTransferLookupTables(parameters)
    var access = WebCore.PixelBufferAccess(destination)
    var bytes: MutableSpan<UInt8> = access.mutableSpan()
    var pixels = bytes.mutableBytes
    applyComponentTransferLookupTables(tables.span, to: &pixels)
    return true
}

#if USE_SKIA
// FEComponentTransferSkiaApplier::apply(): Skia draws the input through the tables (FilterSkiaBridge.cpp).
func feComponentTransferApplySkia(
    _ parameters: FEComponentTransferValues,
    _ input: inout FilterImageImpl,
    _ result: inout FilterImageImpl
) -> Bool {
    let resultImage = result.imageBuffer()
    let sourceImage = input.imageBuffer()
    guard let resultImage = resultImage.get(), let sourceImage = sourceImage.get() else {
        return false
    }
    let tables = componentTransferLookupTables(parameters)
    let inputOffsetWithinResult = input.absoluteImageRect(relativeTo: result).location()
    return WebCore.FilterSkiaBridge.drawTables(resultImage, sourceImage, tables.span, inputOffsetWithinResult)
}
#endif

private let componentTransferTableSize = 256

// FEComponentTransfer::computeLookupTable() of the red, green, blue and alpha functions, one table after the other.
private func componentTransferLookupTables(_ parameters: FEComponentTransferValues) -> ContiguousArray<UInt8> {
    var tables = ContiguousArray<UInt8>(repeating: 0, count: 4 * componentTransferTableSize)
    var span = tables.mutableSpan
    fillComponentTransferLookupTable(&span, base: 0, parameters.red)
    fillComponentTransferLookupTable(&span, base: componentTransferTableSize, parameters.green)
    fillComponentTransferLookupTable(&span, base: 2 * componentTransferTableSize, parameters.blue)
    fillComponentTransferLookupTable(&span, base: 3 * componentTransferTableSize, parameters.alpha)
    return tables
}

// Every float to integer conversion below is in range, so none can trap: table indices are at most the table size, and
// the values are clamped to 0 ... 255 first.
private func fillComponentTransferLookupTable(
    _ tables: inout MutableSpan<UInt8>,
    base: Int,
    _ function: ComponentTransferFunctionValues
) {
    switch function.type {
    case .FECOMPONENTTRANSFER_TYPE_UNKNOWN, .FECOMPONENTTRANSFER_TYPE_IDENTITY:
        fillIdentityLookupTable(&tables, base: base)

    case .FECOMPONENTTRANSFER_TYPE_TABLE:
        let tableValues: Span<Float> = function.tableValues.span
        // Vector's size_t count in a C++ unsigned.
        let n = UInt32(truncatingIfNeeded: tableValues.count)
        if n < 1 {
            fillIdentityLookupTable(&tables, base: base)
            break
        }
        let last = n - 1
        for i in 0..<componentTransferTableSize {
            let c = Double(i) / 255.0
            let k = UInt32(c * Double(last))
            let v1 = Double(tableValues[Int(k)])
            let v2 = Double(tableValues[Int(min(k + 1, last))])
            let value = 255.0 * (v1 + (c * Double(last) - Double(k)) * (v2 - v1))
            tables[base + i] = componentTransferByte(value)
        }

    case .FECOMPONENTTRANSFER_TYPE_DISCRETE:
        let tableValues: Span<Float> = function.tableValues.span
        let n = UInt32(truncatingIfNeeded: tableValues.count)
        if n < 1 {
            fillIdentityLookupTable(&tables, base: base)
            break
        }
        for i in 0..<componentTransferTableSize {
            // Multiplied in unsigned, which wraps for more than 16.8M table values.
            let k = min(UInt32(Double(UInt32(i) &* n) / 255.0), n - 1)
            // An int times a float is a float multiplication.
            let value = Double(255 * tableValues[Int(k)])
            tables[base + i] = componentTransferByte(value)
        }

    case .FECOMPONENTTRANSFER_TYPE_LINEAR:
        let slope = function.slope
        let intercept = function.intercept
        for i in 0..<componentTransferTableSize {
            // Float arithmetic, as in C++.
            let value = Double(slope * Float(i) + 255 * intercept)
            tables[base + i] = componentTransferByte(value)
        }

    case .FECOMPONENTTRANSFER_TYPE_GAMMA:
        let amplitude = Double(function.amplitude)
        let exponent = Double(function.exponent)
        let offset = Double(function.offset)
        for i in 0..<componentTransferTableSize {
            let value = 255.0 * (amplitude * pow(Double(i) / 255.0, exponent) + offset)
            tables[base + i] = componentTransferByte(value)
        }

    @unknown default:
        preconditionFailure()
    }
}

private func fillIdentityLookupTable(_ tables: inout MutableSpan<UInt8>, base: Int) {
    for i in 0..<componentTransferTableSize {
        tables[base + i] = UInt8(truncatingIfNeeded: i)
    }
}

// std::max(0.0, std::min(255.0, value)), then a uint8_t: NaN becomes 255, as the argument order made it in C++.
private func componentTransferByte(_ value: Double) -> UInt8 {
    let atMost255 = value < 255 ? value : 255
    let clamped = 0 < atMost255 ? atMost255 : 0
    return UInt8(clamped)
}

// Replaces each byte of each RGBA pixel by its entry in the table of its channel.
private func applyComponentTransferLookupTables(_ tables: Span<UInt8>, to pixels: inout MutableRawSpan) {
    let red = tables.extracting(0..<256)
    let green = tables.extracting(256..<512)
    let blue = tables.extracting(512..<768)
    let alpha = tables.extracting(768..<1024)
    let byteCount = pixels.byteCount & ~3
    var offset = 0
    while offset < byteCount {
        let pixel = UInt32(littleEndian: pixels.load(fromByteOffset: offset, as: UInt32.self))
        let transformedRed = UInt32(red[Int(pixel & 0xff)])
        let transformedGreen = UInt32(green[Int((pixel >> 8) & 0xff)])
        let transformedBlue = UInt32(blue[Int((pixel >> 16) & 0xff)])
        let transformedAlpha = UInt32(alpha[Int(pixel >> 24)])
        let transformed = transformedRed | transformedGreen << 8 | transformedBlue << 16 | transformedAlpha << 24
        pixels.storeBytes(of: transformed.littleEndian, toByteOffset: offset, as: UInt32.self)
        offset &+= 4
    }
}

#endif // ENABLE_WEBCORE_SWIFT
