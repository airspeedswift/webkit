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
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

// The pixel and colour arithmetic of WebCore::ImageBackingStore
// (graphics/ImageBackingStore.h) that the GIF and BMP decoders' Swift does on
// a frame's pixels, and the frame cache those decoders write into.
//
//  * A frame's pixels are its ImageBackingStore's, one ARGB word per pixel,
//    reached as a MutableSpan<UInt32> (framePixels) for the duration of a
//    write. Every subscript is bounds-checked.
//  * Sizes are WebCore's `int` (Int32).
//  * The colour arithmetic (fastDivideBy255, premultipliedFlooring,
//    PackedColor::ARGB) is copied from the Color headers.

internal import WebCore_Private.ImageDecoderSwiftTypes

// MARK: - IntSize, IntRect

/// WebCore::IntSize.
struct PixelSize: Equatable {
    var width: Int32
    var height: Int32

    init(width: Int32, height: Int32) {
        self.width = width
        self.height = height
    }

    init(_ size: WebCore.ImageDecoderSize) {
        self.init(width: size.width, height: size.height)
    }

    var imageDecoderSize: WebCore.ImageDecoderSize {
        WebCore.ImageDecoderSize(width: width, height: height)
    }

    /// IntSize::isEmpty.
    var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// WebCore::IntRect, for the operations ImageBackingStore uses. maxX and maxY
/// are Int64, so they do not overflow where IntRect's int sums would.
struct PixelRect {
    var x: Int32
    var y: Int32
    var width: Int32
    var height: Int32

    init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(size: PixelSize) {
        self.init(x: 0, y: 0, width: size.width, height: size.height)
    }

    init(_ rect: WebCore.ImageDecoderRect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    var imageDecoderRect: WebCore.ImageDecoderRect {
        WebCore.ImageDecoderRect(x: x, y: y, width: width, height: height)
    }

    var maxX: Int64 { Int64(x) + Int64(width) }
    var maxY: Int64 { Int64(y) + Int64(height) }

    /// IntSize::isEmpty: handles negative widths too.
    var isEmpty: Bool { width <= 0 || height <= 0 }

    /// IntRect::contains(const IntRect&).
    func contains(_ other: PixelRect) -> Bool {
        Int64(x) <= Int64(other.x) && maxX >= other.maxX && Int64(y) <= Int64(other.y)
            && maxY >= other.maxY
    }

    /// IntRect::contains(int, int).
    func contains(x px: Int32, y py: Int32) -> Bool {
        Int64(px) >= Int64(x) && Int64(px) < maxX && Int64(py) >= Int64(y) && Int64(py) < maxY
    }
}

// MARK: - Colour arithmetic

/// SRGBA<uint8_t>.
struct SRGBA8 {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8
}

enum ImageBackingStoreColor {
    /// fastDivideBy255 (ColorUtilities.h). Exact for every 16-bit input;
    /// no intermediate can overflow: approximation*255 <= value, remainder + 1 <= 511.
    static func fastDivideBy255(_ value: UInt16) -> UInt16 {
        let approximation = value >> 8
        let remainder = value - (approximation * 255) + 1
        return approximation + (remainder >> 8)
    }

    /// clampedComponent for SRGBA<uint8_t>, componentInfo [0, 255].
    private static func clampedComponent(_ value: UInt16) -> UInt8 {
        UInt8(min(value, 255))
    }

    /// premultipliedFlooring(SRGBA<uint8_t>).
    static func premultipliedFlooring(_ color: SRGBA8) -> SRGBA8 {
        let a = color.alpha
        if a == 0 {
            return SRGBA8(red: 0, green: 0, blue: 0, alpha: 0)
        }
        if a == 255 {
            return color
        }
        func premultiply(_ c: UInt8) -> UInt8 {
            clampedComponent(fastDivideBy255(UInt16(c) * UInt16(a)))
        }
        return SRGBA8(
            red: premultiply(color.red), green: premultiply(color.green),
            blue: premultiply(color.blue), alpha: a)
    }

    /// PackedColor::ARGB(ResolvedColorType<SRGBA<uint8_t>>).
    static func packARGB(_ color: SRGBA8) -> UInt32 {
        UInt32(color.alpha) << 24 | UInt32(color.red) << 16 | UInt32(color.green) << 8
            | UInt32(color.blue)
    }
}

// MARK: - ImageBackingStore's pixel operations

/// ImageBackingStore's operations on its pixels, for a store of `size` whose
/// pixels are `pixels` (the store's m_pixelsSpan, row by row).
enum ImageBackingStorePixels {
    /// ImageBackingStore::pixelValue.
    static func pixelValue(premultiplyAlpha: Bool, r: UInt8, g: UInt8, b: UInt8, a: UInt8) -> UInt32
    {
        if premultiplyAlpha && a == 0 {
            return 0
        }

        var result = SRGBA8(red: r, green: g, blue: b, alpha: a)

        if premultiplyAlpha && a < 255 {
            result = ImageBackingStoreColor.premultipliedFlooring(result)
        }

        return ImageBackingStoreColor.packARGB(result)
    }

    /// inBounds(const IntRect&).
    static func inBounds(_ rect: PixelRect, size: PixelSize) -> Bool {
        PixelRect(size: size).contains(rect)
    }

    /// The index of (x, y): pixelsStartingAt / pixelAt.
    /// The C++ ASSERT(inBounds) is a precondition.
    static func pixelIndex(x: Int32, y: Int32, size: PixelSize) -> Int {
        precondition(PixelRect(size: size).contains(x: x, y: y))
        return Int(y) * Int(size.width) + Int(x)
    }

    /// ImageBackingStore::clear.
    static func clear(_ pixels: inout MutableSpan<UInt32>) {
        for i in pixels.indices {
            pixels[i] = 0
        }
    }

    /// ImageBackingStore::clearRect, and fillRect with `value` its pixelValue.
    /// No-op for an empty or out-of-bounds rect.
    static func fill(
        _ pixels: inout MutableSpan<UInt32>, size: PixelSize, _ rect: PixelRect, with value: UInt32
    ) {
        guard !rect.isEmpty, inBounds(rect, size: size) else { return }
        // In bounds: every index below is < width*height, which fits in Int.
        let rowWidth = Int(size.width)
        let rectWidth = Int(rect.width)
        for row in 0..<Int(rect.height) {
            let start = (Int(rect.y) + row) * rowWidth + Int(rect.x)
            for i in start..<(start + rectWidth) {
                pixels[i] = value
            }
        }
    }

    /// ImageBackingStore::repeatFirstRow: copies the rect's first row into each
    /// following row of the rect. A one-row rect copies nothing.
    static func repeatFirstRow(
        _ pixels: inout MutableSpan<UInt32>, size: PixelSize, _ rect: PixelRect
    ) {
        guard !rect.isEmpty, inBounds(rect, size: size) else { return }
        let rowWidth = Int(size.width)
        let rectWidth = Int(rect.width)
        let source = Int(rect.y) * rowWidth + Int(rect.x)
        var destination = source
        for _ in 1..<Int(rect.height) {  // height >= 1: the rect is not empty
            destination += rowWidth
            // The row's last pixel is the last one read or written, so one check
            // per row covers the copy, which then needs none per pixel.
            precondition(destination + rectWidth <= pixels.count)
            for j in 0..<rectWidth {
                // Cannot overflow: source + j < destination + j < destination + rectWidth,
                // which is checked above. The compiler keeps the checks of `+` here.
                pixels[destination &+ j] = pixels[source &+ j]
            }
        }
    }
}

// MARK: - The frame cache

extension WebCore.ScalableImageDecoderFrames {
    /// framePixels(): the pixels of frame `index`, which must have a backing store.
    @_lifetime(&self)
    mutating func pixels(_ index: Int) -> MutableSpan<UInt32> {
        WebCore.framePixels(&self, index)
    }

    /// ScalableImageDecoder::failed().
    func failed() -> Bool {
        encodedDataStatus == DecoderStatus.error
    }

    /// ScalableImageDecoder::isSizeAvailable().
    func isSizeAvailable() -> Bool {
        encodedDataStatus >= DecoderStatus.sizeAvailable
    }

    /// ScalableImageDecoder::isAllDataReceived().
    func isAllDataReceived() -> Bool {
        encodedDataStatus == DecoderStatus.complete
    }
}

/// EncodedDataStatus, as raw values (ImageDecoderSwiftFrames.cpp pins them).
enum DecoderStatus {
    static let error: UInt8 = 0
    static let sizeAvailable: UInt8 = 3
    static let complete: UInt8 = 4
}

/// DecodingStatus and ScalableImageDecoderFrame::DisposalMethod, as raw values
/// (ImageDecoderSwiftFrames.cpp pins them).
enum FrameStatus {
    static let invalid: UInt8 = 0
    static let partial: UInt8 = 1
    static let complete: UInt8 = 2
}

enum FrameDisposalMethod {
    static let unspecified: UInt8 = 0
    static let doNotDispose: UInt8 = 1
    static let restoreToBackground: UInt8 = 2
    static let restoreToPrevious: UInt8 = 3
}
