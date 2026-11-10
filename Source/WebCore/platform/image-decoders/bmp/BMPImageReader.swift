/*
 * Copyright (c) 2008-2015 Google Inc. All rights reserved.
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *     * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *     * Neither the name of Google Inc. nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// BMPImageReader (BMPImageReader.{h,cpp}) and BMPImageDecoder::processFileHeader.
//
// The reader holds no data: each decodeBMP() call takes the current data as a
// Span. It does not call setFailed() on its owner; where the C++ returns
// m_parent->setFailed() it returns .failed, and the owner fails and drops the
// reader. The owner and its frame cache are reached through BMPPixelSink.
// Coordinates are bounded by isInfoHeaderValid (sides < 65536), so Int gives
// the C++ int results.

/// Mirrors WebCore::IntSize.
struct BMPIntSize: Equatable, Sendable {
    var width: Int32
    var height: Int32

    init(width: Int32, height: Int32) {
        self.width = width
        self.height = height
    }
}

/// The parent decoder plus its frame cache, as seen by the reader. C++:
/// `ScalableImageDecoder* m_parent`, and `ScalableImageDecoderFrame* m_buffer`
/// as frame `index` of the cache. The decoders' frame cache
/// (ScalableImageDecoderFrames) conforms, so the requirements are named apart
/// from its members and read `mutating`.
protocol BMPPixelSink: ~Copyable {
    /// m_parent->ScalableImageDecoder::size().
    var decoderSize: BMPIntSize { mutating get }
    /// m_parent->ScalableImageDecoder::setSize(). Returns false if the parent
    /// rejected the size (the parent has then already marked itself failed).
    mutating func setDecoderSize(_ size: BMPIntSize) -> Bool
    /// m_parent->setFailed().
    mutating func setFailed() -> Bool

    /// m_buffer->isInvalid().
    mutating func frameIsInvalid(_ index: Int) -> Bool
    /// m_buffer->initialize(size, premultiplyAlpha). False if allocation failed.
    mutating func initializeFrame(_ index: Int, size: BMPIntSize, premultiplyAlpha: Bool) -> Bool
    /// m_buffer->setDecodingStatus(DecodingStatus::Partial).
    mutating func setStatusPartial(_ index: Int)
    /// m_buffer->setDecodingStatus(DecodingStatus::Complete).
    mutating func setStatusComplete(_ index: Int)
    /// m_buffer->hasAlpha() / setHasAlpha().
    mutating func frameHasAlpha(_ index: Int) -> Bool
    mutating func setFrameHasAlpha(_ index: Int, _ hasAlpha: Bool)
    /// The indices of row `y` of m_buffer's backing store in framePixels().
    /// Traps unless `y` is a row of the store.
    mutating func frameRow(_ index: Int, _ y: Int) -> Range<Int>
    /// m_buffer->backingStore()'s pixels, row by row: the reader writes a row
    /// through it (only in-bounds pixels, same invariants as the C++), where
    /// the C++ calls setPixel(x, y, r, g, b, a) and clear().
    @_lifetime(&self)
    mutating func framePixels(_ index: Int) -> MutableSpan<UInt32>
    /// m_buffer->backingStore()->fillRect(IntRect(x, y, width, height), r, g, b, a).
    mutating func fillRect(
        _ index: Int, x: Int, y: Int, width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8,
        a: UInt8, premultiplyAlpha: Bool)
}

/// Outcome of one decodeBMP() call. C++ returns bool; `false` is split by
/// whether the C++ would have called m_parent->setFailed().
enum BMPDecodeResult: Equatable, Sendable {
    /// C++ `return true`.
    case success
    /// C++ `return false` without setFailed(): more data needed.
    case insufficientData
    /// C++ `return m_parent->setFailed()`: the owner must mark itself failed
    /// and must not call this reader again.
    case failed
    /// C++ `if (!m_parent->setSize(...)) return false;`: the sink's setSize
    /// returned false (and the parent has already handled the failure).
    case sizeRejected
}

/// Outcome of BMPImageReader.bmpFileHeader().
enum BMPFileHeaderResult: Equatable, Sendable {
    /// Fewer than 14 bytes (C++ `return false` without setFailed()).
    case needMoreData
    /// Not "BM" (C++ `setFailed()`).
    case notBMP
    /// The file header was read; the info header starts at offset 14.
    case ok(imgDataOffset: Int)
}

struct BMPImageReader {
    // MARK: Little-endian reads (byte composition)

    /// BMPImageReader::readUint16(const SharedBuffer&, int), little-endian.
    /// Out-of-range offsets trap.
    static func readUint16(_ data: Span<UInt8>, _ offset: Int) -> UInt16 {
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    /// C++ BMPImageReader::readUint32(const SharedBuffer&, int).
    static func readUint32(_ data: Span<UInt8>, _ offset: Int) -> UInt32 {
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    // Number of bytes in a .BMP file header (BMPImageDecoder.cpp sizeOfFileHeader).
    static let sizeOfFileHeader = 14

    /// BMPImageDecoder::processFileHeader(), for the BMP decoder, which then
    /// creates a reader with decodedAndHeaderOffset = sizeOfFileHeader.
    static func bmpFileHeader(_ data: Span<UInt8>) -> BMPFileHeaderResult {
        // Read file header.
        if data.count < sizeOfFileHeader {
            return .needMoreData
        }
        let fileType = (UInt16(data[0]) << 8) | UInt16(data[1])
        let imgDataOffset = readUint32(data, 10)

        // See if this is a bitmap filetype we understand. Only "BM"; the OS/2
        // 2.x types (IC, PT, CI, CP, BA) are not decoded.
        let bmap: UInt16 = 0x424D  // "BM"
        if fileType != bmap {
            return .notBMP
        }
        return .ok(imgDataOffset: Int(imgDataOffset))
    }

    // MARK: Types

    // FIXME: CompressionType, AndMaskState, BitmapInfoHeader and RGBTriple are internal rather than private until
    // private types link under ThinLTO on Windows ("Invalid weak external"; see HTMLFastPathParser.swift).

    // The various BMP compression types. We don't currently decode all these.
    enum CompressionType {
        // Universal types
        case rgb  // 0
        case rle8  // 1
        case rle4  // 2
        // Windows V3+ only
        case bitfields  // 3
        case jpeg  // 4
        case png  // 5
        // OS/2 2.x-only
        case huffman1D  // Stored in file as 3
        case rle24  // Stored in file as 4

        init?(fileValue: UInt32) {
            switch fileValue {
            case 0: self = .rgb
            case 1: self = .rle8
            case 2: self = .rle4
            case 3: self = .bitfields
            case 4: self = .jpeg
            case 5: self = .png
            default: return nil
            }
        }
    }

    enum AndMaskState {
        case none
        case notYetDecoded
        case decoding
    }

    private enum ProcessingResult {
        case success
        case failure
        case insufficientData
    }

    // Based on the Windows BITMAPINFOHEADER, with unnecessary entries removed.
    // biSize == 0 means "not yet read" (C++ zeroBytes(m_infoHeader)).
    struct BitmapInfoHeader {
        var biSize: UInt32 = 0
        var biWidth: Int32 = 0
        var biHeight: Int32 = 0
        var biBitCount: UInt16 = 0
        var biCompression: CompressionType = .rgb
        var biClrUsed: UInt32 = 0
    }

    struct RGBTriple {
        var rgbBlue: UInt8
        var rgbGreen: UInt8
        var rgbRed: UInt8
    }

    // MARK: State

    // An index into the data representing how much we've already decoded.
    private var decodedOffset: Int
    // The file offset at which the BMP info header starts.
    private let headerOffset: Int
    // The file offset at which the actual image bits start. 0 for ICO, where
    // the image data immediately follows the header and color table.
    private let imgDataOffset: Int

    // The index of m_buffer in the parent's frame cache: 0 for BMP, the
    // entry's index for ICO.
    var frameIndex = 0
    // For an ICO entry, the entry's size, which ICOImageDecoder::size() and
    // setSize() answer while the entry is decoded (m_frameSize); nil for BMP.
    var entrySize: BMPIntSize?
    // m_parent->premultiplyAlpha(), which the parent's constructor sets.
    private let premultiplyAlpha: Bool

    private var infoHeader = BitmapInfoHeader()
    // OS/2 1.x (aka Windows 2.x) BMP.
    private var isOS21x = false
    // OS/2 2.x BMP (falsely negative in cases where it does not matter).
    private var isOS22x = false
    // The first line of raster data is the top line of the image.
    private var isTopDown = false
    private var needToProcessBitmasks = false
    private var needToProcessColorTable = false

    // Masks/shifts for R, G, B, A (indices 0...3) for non-palette formats.
    // C++ leaves these uninitialized until processBitmasks()/readInfoHeader()
    // set them; they are never read before then.
    private var bitMasks = [4 of UInt32](repeating: 0)
    private var bitShiftsRight = [4 of UInt32](repeating: 0)
    private var bitShiftsLeft = [4 of UInt32](repeating: 0)

    // The color palette, for paletted formats.
    private var colorTable: [RGBTriple] = []

    // The coordinate to which we've decoded the image (C++ IntPoint m_coord).
    private var coordX = 0
    private var coordY = 0

    // Whether we've seen pixels with alpha != 0 and == 0; see processNonRLEData().
    private var seenNonZeroAlphaPixel = false
    private var seenZeroAlphaPixel = false

    // ICO 1bpp AND mask following the image data.
    private var andMaskState: AndMaskState

    // MARK: Init

    /// `decodedAndHeaderOffset` points to the start of the BMP info header in
    /// the data; `imgDataOffset` is the file offset of the pixel data (0 for
    /// ICO); `usesAndMask` is true for ICO entries.
    init(decodedAndHeaderOffset: Int, imgDataOffset: Int, usesAndMask: Bool, premultiplyAlpha: Bool)
    {
        self.premultiplyAlpha = premultiplyAlpha
        // C++ takes size_t; negative values are a caller bug.
        precondition(decodedAndHeaderOffset >= 0 && imgDataOffset >= 0)
        self.decodedOffset = decodedAndHeaderOffset
        self.headerOffset = decodedAndHeaderOffset
        self.imgDataOffset = imgDataOffset
        self.andMaskState = usesAndMask ? .notYetDecoded : .none
    }

    // MARK: Helpers

    // `(m_data->size() - m_decodedOffset) < n` with size_t operands, which is
    // false when the data has shrunk below decodedOffset; the read that
    // follows then traps.
    private func remainingIsLessThan(_ data: Span<UInt8>, _ n: Int) -> Bool {
        if decodedOffset > data.count {
            return false
        }
        return (data.count - decodedOffset) < n
    }

    private func readUint16(_ data: Span<UInt8>, _ offset: Int) -> UInt16 {
        return Self.readUint16(data, decodedOffset + offset)
    }

    private func readUint32(_ data: Span<UInt8>, _ offset: Int) -> UInt32 {
        return Self.readUint32(data, decodedOffset + offset)
    }

    // Windows V4 info header is 108 bytes. V5 is 124 bytes.
    private var isWindowsV4Plus: Bool {
        return infoHeader.biSize == 108 || infoHeader.biSize == 124
    }

    // m_parent->size().
    private func parentSize(_ sink: inout some BMPPixelSink & ~Copyable) -> BMPIntSize {
        if let entrySize {
            return entrySize
        }
        return sink.decoderSize
    }

    // m_parent->setSize(). ICOImageDecoder::setSize while an entry is decoded:
    // the size calculated inside the BMPImageReader had better match the one
    // in the icon directory.
    private func setParentSize(_ size: BMPIntSize, _ sink: inout some BMPPixelSink & ~Copyable)
        -> Bool
    {
        if let entrySize {
            return size == entrySize || sink.setFailed()
        }
        return sink.setDecoderSize(size)
    }

    // Returns true if the current y-coordinate plus |numRows| would be past
    // the end of the image ("plus" is downwards for top-down images).
    private func pastEndOfImage(_ numRows: Int, _ sink: inout some BMPPixelSink & ~Copyable) -> Bool
    {
        return isTopDown
            ? ((coordY + numRows) >= Int(parentSize(&sink).height)) : ((coordY - numRows) < 0)
    }

    // Returns the value of the desired component (0, 1, 2, 3 == R, G, B, A),
    // which is <= 255: the shifts processBitmasks() sets keep at most 8 bits of each mask.
    // The shifts are in 0...31, where the masking shifts equal the C++ shifts.
    private func getComponent(_ pixel: UInt32, _ component: Int) -> UInt32 {
        return ((pixel & bitMasks[component]) &>> bitShiftsRight[component])
            &<< bitShiftsLeft[component]
    }

    // Whether the masks are the ones processBitmasks() synthesizes for 24-bit
    // pixels: R, G and B in the low three bytes, and no alpha.
    private func hasDefaultMasksWithoutAlpha() -> Bool {
        return bitMasks[0] == 0x00ff_0000 && bitMasks[1] == 0x0000_ff00
            && bitMasks[2] == 0x0000_00ff && bitMasks[3] == 0
            && bitShiftsRight[0] == 16 && bitShiftsRight[1] == 8 && bitShiftsRight[2] == 0
            && bitShiftsLeft[0] == 0 && bitShiftsLeft[1] == 0 && bitShiftsLeft[2] == 0
    }

    private func getAlpha(_ pixel: UInt32) -> UInt32 {
        // For images without alpha, return alpha of 0xff.
        return bitMasks[3] != 0 ? getComponent(pixel, 3) : 0xff
    }

    // The pixel value of the color given by |colorIndex| (the C++ setI()).
    private func colorValue(_ colorIndex: Int, premultiplyAlpha: Bool) -> UInt32 {
        let entry = colorTable[colorIndex]
        return ImageBackingStorePixels.pixelValue(
            premultiplyAlpha: premultiplyAlpha, r: entry.rgbRed, g: entry.rgbGreen,
            b: entry.rgbBlue, a: 0xff)
    }

    // Fills pixels from the current x up to, but not including, |endCoord|.
    private mutating func fillRGBA(
        _ endCoord: Int, _ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8,
        _ sink: inout some BMPPixelSink & ~Copyable
    ) {
        if endCoord <= coordX {
            return
        }
        sink.fillRect(
            frameIndex, x: coordX, y: coordY, width: endCoord - coordX, height: 1, r: red, g: green,
            b: blue, a: alpha, premultiplyAlpha: premultiplyAlpha)
        coordX = endCoord
    }

    // Moves to the left edge of the "next" row (above or below, depending on
    // isTopDown).
    private mutating func moveBufferToNextRow() {
        coordX = 0
        coordY += isTopDown ? 1 : -1
    }

    // MARK: Decoding

    /// Does the actual decoding. If `onlySize` is true, decoding only
    /// progresses as far as necessary to get the image size.
    mutating func decodeBMP(
        _ data: Span<UInt8>, onlySize: Bool, sink: inout some BMPPixelSink & ~Copyable
    ) -> BMPDecodeResult {
        // Calculate size of info header.
        if infoHeader.biSize == 0 {
            let result = readInfoHeaderSize(data)
            if result != .success {
                return result
            }
        }

        // Read and process info header.
        let (headerEnd, headerEndOverflow) = UInt(headerOffset).addingReportingOverflow(
            UInt(infoHeader.biSize))
        if headerEndOverflow || UInt(decodedOffset) < headerEnd {
            let result = processInfoHeader(data, &sink)
            if result != .success {
                return result
            }
        }

        // processInfoHeader() set the size, so if that's all we needed, we're done.
        if onlySize {
            return .success
        }

        // Read and process the bitmasks, if needed.
        if needToProcessBitmasks {
            let result = processBitmasks(data)
            if result != .success {
                return result
            }
        }

        // Read and process the color table, if needed.
        if needToProcessColorTable {
            let result = processColorTable(data)
            if result != .success {
                return result
            }
        }

        // Initialize the framebuffer if needed.
        if sink.frameIsInvalid(frameIndex) {
            let size = parentSize(&sink)
            if !sink.initializeFrame(frameIndex, size: size, premultiplyAlpha: premultiplyAlpha) {
                return .failed  // Unable to allocate.
            }

            sink.setStatusPartial(frameIndex)
            sink.setFrameHasAlpha(frameIndex, false)

            if !isTopDown {
                coordY = Int(size.height) - 1
            }
        }

        // Decode the data.
        if andMaskState != .decoding && !pastEndOfImage(0, &sink) {
            if infoHeader.biCompression != .rle4 && infoHeader.biCompression != .rle8
                && infoHeader.biCompression != .rle24
            {
                switch processNonRLEData(data, inRLE: false, numPixels: 0, &sink) {
                case .success:
                    break
                case .failure:
                    return .failed
                case .insufficientData:
                    return .insufficientData
                }
            } else {
                let result = processRLEData(data, &sink)
                if result != .success {
                    return result
                }
            }
        }

        // If the image has an AND mask and there was no alpha data, process the mask.
        if andMaskState == .notYetDecoded && !sink.frameHasAlpha(frameIndex) {
            // Reset decoding coordinates to start of image.
            coordX = 0
            coordY = isTopDown ? 0 : (Int(parentSize(&sink).height) - 1)

            // The AND mask is stored as 1-bit data.
            infoHeader.biBitCount = 1

            andMaskState = .decoding
        }
        if andMaskState == .decoding {
            switch processNonRLEData(data, inRLE: false, numPixels: 0, &sink) {
            case .success:
                break
            case .failure:
                return .failed
            case .insufficientData:
                return .insufficientData
            }
        }

        // Done!
        sink.setStatusComplete(frameIndex)
        return .success
    }

    // Determines the size of the BMP info header.
    private mutating func readInfoHeaderSize(_ data: Span<UInt8>) -> BMPDecodeResult {
        // Get size of info header.
        if decodedOffset > data.count || (data.count - decodedOffset) < 4 {
            return .insufficientData
        }
        infoHeader.biSize = readUint32(data, 0)
        // Don't increment decodedOffset here, it just makes the code in
        // processInfoHeader() more confusing.

        // Don't allow the header to overflow, or to overrun the image data.
        let (headerEnd, overflow) = headerOffset.addingReportingOverflow(Int(infoHeader.biSize))
        if overflow || (imgDataOffset != 0 && imgDataOffset < headerEnd) {
            return .failed
        }

        // See if this is a header size we understand:
        let biSize = infoHeader.biSize
        if biSize == 12 {
            // OS/2 1.x: 12
            isOS21x = true
        } else if biSize == 40 || isWindowsV4Plus {
            // Windows V3: 40
        } else if biSize >= 16 && biSize <= 64
            && ((biSize & 3) == 0 || biSize == 42 || biSize == 46)
        {
            // OS/2 2.x: any multiple of 4 between 16 and 64, inclusive, or 42 or 46
            isOS22x = true
        } else {
            return .failed
        }

        return .success
    }

    // Processes the BMP info header.
    private mutating func processInfoHeader(
        _ data: Span<UInt8>, _ sink: inout some BMPPixelSink & ~Copyable
    ) -> BMPDecodeResult {
        // Read info header.
        let biSizeAsInt = Int(infoHeader.biSize)
        guard decodedOffset <= data.count, (data.count - decodedOffset) >= biSizeAsInt else {
            return .insufficientData
        }
        if !readInfoHeader(data) {
            return .failed
        }
        decodedOffset += biSizeAsInt

        // Sanity-check header values.
        if !isInfoHeaderValid() {
            return .failed
        }

        // Set our size.
        if !setParentSize(BMPIntSize(width: infoHeader.biWidth, height: infoHeader.biHeight), &sink)
        {
            return .sizeRejected
        }

        // For paletted images, biClrUsed 0 means "all colors"; also clamp
        // too-large values. biBitCount < 16 here, so the shift is in range.
        if infoHeader.biBitCount < 16 {
            let maxColors = UInt32(1) << Int(infoHeader.biBitCount)
            if infoHeader.biClrUsed == 0 || infoHeader.biClrUsed > maxColors {
                infoHeader.biClrUsed = maxColors
            }
        }

        // Reset bit counts for RLE bitmaps that set the wrong value.
        if infoHeader.biCompression == .rle8 {
            infoHeader.biBitCount = 8
        } else if infoHeader.biCompression == .rle4 {
            infoHeader.biBitCount = 4
        }

        // Tell caller what still needs to be processed.
        if infoHeader.biBitCount >= 16 {
            needToProcessBitmasks = true
        } else if infoHeader.biBitCount != 0 {
            needToProcessColorTable = true
        }

        return .success
    }

    // Reads header values from the data. Returns false where the C++ calls
    // setFailed(). The caller has checked that biSize bytes are available at
    // decodedOffset, and biSize >= 12 (OS/2 1.x) or >= 16 (all others).
    private mutating func readInfoHeader(_ data: Span<UInt8>) -> Bool {
        // Pre-initialize some fields that not all headers set.
        infoHeader.biCompression = .rgb
        infoHeader.biClrUsed = 0

        if isOS21x {
            infoHeader.biWidth = Int32(readUint16(data, 4))
            infoHeader.biHeight = Int32(readUint16(data, 6))
            // (C++ ASSERTs andMaskState == None here; release builds continue.)
            infoHeader.biBitCount = readUint16(data, 10)
            return true
        }

        infoHeader.biWidth = Int32(bitPattern: readUint32(data, 4))
        infoHeader.biHeight = Int32(bitPattern: readUint32(data, 8))
        if andMaskState != .none {
            // C++ int division truncates toward zero, as Swift's does; cannot overflow for divisor 2.
            infoHeader.biHeight /= 2
        }
        infoHeader.biBitCount = readUint16(data, 14)

        // Read compression type, if present.
        if infoHeader.biSize >= 20 {
            let biCompression = readUint32(data, 16)

            // Detect OS/2 2.x-specific compression types.
            if biCompression == 3 && infoHeader.biBitCount == 1 {
                infoHeader.biCompression = .huffman1D
                isOS22x = true
            } else if biCompression == 4 && infoHeader.biBitCount == 24 {
                infoHeader.biCompression = .rle24
                isOS22x = true
            } else if let type = CompressionType(fileValue: biCompression) {
                infoHeader.biCompression = type
            } else {
                return false  // Some type we don't understand (> 5).
            }
        }

        // Read colors used, if present.
        if infoHeader.biSize >= 36 {
            infoHeader.biClrUsed = readUint32(data, 32)
        }

        // Windows V4+ can safely read the four bitmasks from 40-56 bytes in.
        // See the C++ comment: non-BITFIELDS overwrite all but alpha later.
        if isWindowsV4Plus {
            bitMasks[0] = readUint32(data, 40)
            bitMasks[1] = readUint32(data, 44)
            bitMasks[2] = readUint32(data, 48)
            bitMasks[3] = readUint32(data, 52)
        }

        // Detect top-down BMPs.
        if infoHeader.biHeight < 0 {
            // We can't negate Int32.min; reject before negating.
            if infoHeader.biHeight == Int32.min {
                return false
            }
            isTopDown = true
            infoHeader.biHeight = -infoHeader.biHeight
        }

        return true
    }

    // Returns false if consistency errors are found in the info header.
    private func isInfoHeaderValid() -> Bool {
        let bitCount = infoHeader.biBitCount

        // Non-positive widths/heights are invalid. (Top-down heights are already flipped.)
        if infoHeader.biWidth <= 0 || infoHeader.biHeight == 0 {
            return false
        }

        // Only Windows V3+ has top-down bitmaps.
        if isTopDown && (isOS21x || isOS22x) {
            return false
        }

        // Only bit depths of 1, 4, 8, or 24 are universally supported.
        if bitCount != 1 && bitCount != 4 && bitCount != 8 && bitCount != 24 {
            // Windows V3+ additionally supports 0 (embedded JPEG/PNG), 16 and 32.
            if isOS21x || isOS22x || (bitCount != 0 && bitCount != 16 && bitCount != 32) {
                return false
            }
        }

        // Each compression type is only valid with certain bit depths.
        switch infoHeader.biCompression {
        case .rgb:
            if bitCount == 0 {
                return false
            }
        case .rle8:
            // Allow too low a bit count; corrected later.
            if bitCount == 0 || bitCount > 8 {
                return false
            }
        case .rle4:
            if bitCount == 0 || bitCount > 4 {
                return false
            }
        case .bitfields:
            // Only valid for Windows V3+.
            if isOS21x || isOS22x || (bitCount != 16 && bitCount != 32) {
                return false
            }
        case .jpeg, .png:
            // Only valid for Windows V3+.
            if isOS21x || isOS22x || bitCount != 0 {
                return false
            }
        case .huffman1D:
            // Only valid for OS/2 2.x.
            if !isOS22x || bitCount != 1 {
                return false
            }
        case .rle24:
            // Only valid for OS/2 2.x.
            if !isOS22x || bitCount != 24 {
                return false
            }
        }

        // Top-down bitmaps cannot be compressed; they must be RGB or BITFIELDS.
        if isTopDown && infoHeader.biCompression != .rgb && infoHeader.biCompression != .bitfields {
            return false
        }

        // Reject valid types we don't decode: dimensions >= 2^16,
        // JPEG/PNG-in-BMP, OS/2 Huffman 1D.
        if infoHeader.biWidth >= (1 << 16) || infoHeader.biHeight >= (1 << 16) {
            return false
        }
        if infoHeader.biCompression == .jpeg || infoHeader.biCompression == .png {
            return false
        }
        if infoHeader.biCompression == .huffman1D {
            return false
        }

        return true
    }

    // Initializes bitMasks/bitShifts for 16/24/32-bit images.
    private mutating func processBitmasks(_ data: Span<UInt8>) -> BMPDecodeResult {
        // Create bitMasks[] values.
        if infoHeader.biCompression != .bitfields {
            // The format doesn't use bitmasks; synthesize them.
            // 16 bits:    MSB <-                     xRRRRRGG GGGBBBBB -> LSB
            // 24/32 bits: MSB <- [AAAAAAAA] RRRRRRRR GGGGGGGG BBBBBBBB -> LSB
            let numBits = (infoHeader.biBitCount == 16) ? 5 : 8
            for i in 0...2 {
                // Shift amounts are at most 24, so no bit is shifted out.
                bitMasks[i] =
                    ((UInt32(1) << (numBits * (3 - i))) - 1)
                    ^ ((UInt32(1) << (numBits * (2 - i))) - 1)
            }

            // For Windows V4+ 32-bit RGB, don't overwrite the alpha mask from the header.
            if infoHeader.biBitCount < 32 {
                bitMasks[3] = 0
            } else if !isWindowsV4Plus {
                bitMasks[3] = 0xff00_0000
            }
        } else if !isWindowsV4Plus {
            // For Windows V4+ BITFIELDS this was done when reading the info header.

            // Fail if we don't have enough file space for the bitmasks.
            let headerEnd = headerOffset + Int(infoHeader.biSize)
            let bitmasksSize = 12
            let (bitmasksEnd, overflow) = headerEnd.addingReportingOverflow(bitmasksSize)
            if overflow || (imgDataOffset != 0 && imgDataOffset < bitmasksEnd) {
                return .failed
            }

            // Read bitmasks.
            if remainingIsLessThan(data, bitmasksSize) {
                return .insufficientData
            }
            bitMasks[0] = readUint32(data, 0)
            bitMasks[1] = readUint32(data, 4)
            bitMasks[2] = readUint32(data, 8)
            // No alpha in anything other than Windows V4+.
            bitMasks[3] = 0

            decodedOffset += bitmasksSize
        }

        // Skip anything else before the actual raster data.
        if imgDataOffset != 0 {
            decodedOffset = imgDataOffset
        }
        needToProcessBitmasks = false

        // Check masks and set shift values.
        for i in 0..<4 {
            // Trim the mask to the allowed bit depth (biBitCount is 16, 24 or
            // 32 here, so the shift is in range).
            if infoHeader.biBitCount < 32 {
                bitMasks[i] &= (UInt32(1) << Int(infoHeader.biBitCount)) - 1
            }

            // Empty masks: clear the shifts, avoiding an infinite loop below.
            var tempMask = bitMasks[i]
            if tempMask == 0 {
                bitShiftsRight[i] = 0
                bitShiftsLeft[i] = 0
                continue
            }

            // Make sure bitmask does not overlap any other bitmasks.
            for j in 0..<i {
                if (tempMask & bitMasks[j]) != 0 {
                    return .failed
                }
            }

            // Count offset into pixel data.
            var shiftRight = 0
            while (tempMask & 1) == 0 {
                shiftRight += 1
                tempMask >>= 1
            }

            // Count size of mask.
            var shiftLeft = 8
            while (tempMask & 1) != 0 {
                shiftLeft -= 1
                tempMask >>= 1
            }

            // Make sure bitmask is contiguous.
            if tempMask != 0 {
                return .failed
            }

            // Use the most significant 8 bits of wider channels.
            if shiftLeft < 0 {
                shiftRight -= shiftLeft
                shiftLeft = 0
            }
            // A nonzero 32-bit mask: shiftRight is in 0...31 and shiftLeft in 0...8.
            bitShiftsRight[i] = UInt32(shiftRight)
            bitShiftsLeft[i] = UInt32(shiftLeft)
        }

        return .success
    }

    // For paletted images, reads the color table.
    private mutating func processColorTable(_ data: Span<UInt8>) -> BMPDecodeResult {
        // Fail if we don't have enough file space for the color table.
        // biClrUsed <= 256 here (clamped in processInfoHeader()).
        let headerEnd = headerOffset + Int(infoHeader.biSize)
        let tableSizeInBytes = Int(infoHeader.biClrUsed) * (isOS21x ? 3 : 4)
        let (tableEnd, overflow) = headerEnd.addingReportingOverflow(tableSizeInBytes)
        if overflow || (imgDataOffset != 0 && imgDataOffset < tableEnd) {
            return .failed
        }

        // Read color table.
        if decodedOffset > data.count || (data.count - decodedOffset) < tableSizeInBytes {
            return .insufficientData
        }
        var table: [RGBTriple] = []
        table.reserveCapacity(Int(infoHeader.biClrUsed))
        for _ in 0..<Int(infoHeader.biClrUsed) {
            let triple = RGBTriple(
                rgbBlue: data[decodedOffset], rgbGreen: data[decodedOffset + 1],
                rgbRed: data[decodedOffset + 2])
            decodedOffset += 3
            // Skip padding byte (not present on OS/2 1.x).
            if !isOS21x {
                decodedOffset += 1
            }
            table.append(triple)
        }
        colorTable = table

        // Skip anything else before the actual raster data.
        if imgDataOffset != 0 {
            decodedOffset = imgDataOffset
        }
        needToProcessColorTable = false

        return .success
    }

    // Processes an RLE-encoded image. Returns .success if the entire image was decoded.
    //
    // RLE is poorly specified (see the C++ comment): we only change lines on
    // EOL or Delta, ignore excess pixels in encoded runs, and leave skipped
    // pixels transparent (noting hasAlpha).
    private mutating func processRLEData(
        _ data: Span<UInt8>, _ sink: inout some BMPPixelSink & ~Copyable
    ) -> BMPDecodeResult {
        if decodedOffset > data.count {
            return .insufficientData
        }

        // Impossible to decode row-at-a-time, so just do things as a stream of bytes.
        while true {
            // Every entry takes at least two bytes.
            if remainingIsLessThan(data, 2) {
                return .insufficientData
            }

            // For every entry except EOF, we'd better not have reached the end of the image.
            let count = data[decodedOffset]
            let code = data[decodedOffset + 1]
            if (count != 0 || code != 1) && pastEndOfImage(0, &sink) {
                return .failed
            }

            let size = parentSize(&sink)
            let width = Int(size.width)
            let height = Int(size.height)

            // Decode.
            if count == 0 {
                switch code {
                case 0:  // Magic token: EOL
                    // Skip any remaining pixels in this row.
                    if coordX < width {
                        sink.setFrameHasAlpha(frameIndex, true)
                    }
                    moveBufferToNextRow()

                    decodedOffset += 2

                case 1:  // Magic token: EOF
                    // Skip any remaining pixels in the image.
                    if coordX < width || (isTopDown ? (coordY < (height - 1)) : (coordY > 0)) {
                        sink.setFrameHasAlpha(frameIndex, true)
                    }
                    return .success

                case 2:  // Magic token: Delta
                    // The next two bytes specify dx and dy.
                    if remainingIsLessThan(data, 4) {
                        return .insufficientData
                    }

                    // Fail if this takes us past the end of the desired row or the image.
                    let dx = Int(data[decodedOffset + 2])
                    let dy = Int(data[decodedOffset + 3])
                    if dx != 0 || dy != 0 {
                        sink.setFrameHasAlpha(frameIndex, true)
                    }
                    if (coordX + dx) > width || pastEndOfImage(dy, &sink) {
                        return .failed
                    }

                    // Skip intervening pixels.
                    coordX += dx
                    coordY += isTopDown ? dy : -dy

                    decodedOffset += 4

                default:  // Absolute mode
                    // |code| pixels as in BI_RGB, zero-padded to 16 bits.
                    // processNonRLEData() expects decodedOffset at the pixel
                    // data, so bump past the escape and rewind if more data is needed.
                    decodedOffset += 2
                    switch processNonRLEData(data, inRLE: true, numPixels: Int(code), &sink) {
                    case .success:
                        break
                    case .failure:
                        return .failed
                    case .insufficientData:
                        decodedOffset -= 2
                        return .insufficientData
                    }
                }
            } else {  // Encoded mode
                // Repeat the following color for |count| pixels, ignoring
                // pixels past the end of the row.
                let endX = min(coordX + Int(count), width)

                if infoHeader.biCompression == .rle24 {
                    if remainingIsLessThan(data, 4) {
                        return .insufficientData
                    }

                    // One BGR triple that we copy |count| times.
                    fillRGBA(
                        endX, data[decodedOffset + 3], data[decodedOffset + 2], code, 0xff, &sink)
                    decodedOffset += 4
                } else {
                    // RLE8 repeats one color index; RLE4 alternates the two
                    // indexes in the upper and lower 4 bits of the byte.
                    var firstColorIndex = Int(code)
                    var secondColorIndex = Int(code)
                    if infoHeader.biCompression == .rle4 {
                        firstColorIndex = (firstColorIndex >> 4) & 0xf
                        secondColorIndex &= 0xf
                    }
                    if firstColorIndex >= Int(infoHeader.biClrUsed)
                        || secondColorIndex >= Int(infoHeader.biClrUsed)
                    {
                        return .failed
                    }
                    if coordX < endX {
                        // The run is written through one view of the frame's pixels.
                        let row = sink.frameRow(frameIndex, coordY)
                        precondition(endX <= row.count)
                        let firstValue = colorValue(
                            firstColorIndex, premultiplyAlpha: premultiplyAlpha)
                        let secondValue = colorValue(
                            secondColorIndex, premultiplyAlpha: premultiplyAlpha)
                        var pixels = sink.framePixels(frameIndex)
                        var useFirst = true
                        while coordX < endX {
                            pixels[row.lowerBound + coordX] = useFirst ? firstValue : secondValue
                            coordX += 1
                            useFirst.toggle()
                        }
                    }

                    decodedOffset += 2
                }
            }
        }
    }

    // Decodes the pixels from startX up to endX of the current row (processNonRLEData's
    // loop body) into |pixels|, whose index rowStart is (0, coordY). Notes in |sawAlpha|
    // when the frame gets alpha. Returns false on a color index outside the table.
    // rowStart + coordX cannot overflow: coordX < endX, and the caller checks endX
    // against the row.
    private mutating func decodeRowPixels(
        _ data: Span<UInt8>, startX: Int, endX: Int, bitCount: Int, pixelsPerByte: Int,
        bytesPerPixel: Int, unpaddedNumBytes: Int,
        _ pixels: inout MutableSpan<UInt32>, rowStart: Int, premultiplyAlpha: Bool,
        sawAlpha: inout Bool
    ) -> Bool {
        if bitCount < 16 {
            // Paletted data, most significant bits first within each byte.
            // bitCount is 1, 4 or 8, so the mask is 1, 15 or 255.
            let mask = UInt8((1 << bitCount) - 1)
            for byte in 0..<unpaddedNumBytes {
                var pixelData = data[decodedOffset + byte]
                var pixel = 0
                while pixel < pixelsPerByte && coordX < endX {
                    // bitCount is 1, 4 or 8, so the shift is in 0...7.
                    let colorIndex = Int((pixelData &>> (8 - bitCount)) & mask)
                    if andMaskState == .decoding {
                        // AND mask: where the AND value is 1, make the
                        // pixel fully transparent.
                        if colorIndex != 0 {
                            pixels[rowStart &+ coordX] = ImageBackingStorePixels.pixelValue(
                                premultiplyAlpha: premultiplyAlpha, r: 0, g: 0, b: 0, a: 0)
                            coordX += 1
                            sawAlpha = true
                        } else {
                            coordX += 1
                        }
                    } else {
                        if colorIndex >= Int(infoHeader.biClrUsed) {
                            return false
                        }
                        pixels[rowStart &+ coordX] = colorValue(
                            colorIndex, premultiplyAlpha: premultiplyAlpha)
                        coordX += 1
                    }
                    // Smart shift: bits shifted out are discarded, as in
                    // the C++ uint8_t <<= (promote, shift, truncate).
                    pixelData <<= bitCount
                    pixel += 1
                }
            }
        } else if bytesPerPixel == 3 {
            // 24-bit images have the default masks (BITFIELDS needs 16 or 32 bits), so no alpha.
            assert(hasDefaultMasksWithoutAlpha() && !seenZeroAlphaPixel)
            decodeOpaqueBGRRowPixels(data, startX: startX, endX: endX, &pixels, rowStart: rowStart)
        } else {
            // RGB data. Decode pixels one at a time, left to right. decodedOffset
            // is at startX, which an RLE absolute-mode run may put mid-row.
            while coordX < endX {
                // Cannot overflow: (coordX - startX) * bytesPerPixel < unpaddedNumBytes,
                // and decodedOffset is an offset into the data.
                let offset = decodedOffset &+ (coordX &- startX) &* bytesPerPixel
                let pixel: UInt32
                switch bytesPerPixel {
                case 2:
                    pixel = UInt32(Self.readUint16(data, offset))
                case 4:
                    pixel = Self.readUint32(data, offset)
                default:
                    // Unreachable: bitCount is 16 or 32 here.
                    pixel = 0
                }

                // Some BMPs specify an alpha channel but don't use it (all
                // 0s). Decode as opaque until a non-zero alpha is seen;
                // then clear previously-decoded pixels to transparent and
                // use the real alpha. Avoid hasAlpha for all-255 images.
                var alpha = getAlpha(pixel)
                if !seenNonZeroAlphaPixel && alpha == 0 {
                    seenZeroAlphaPixel = true
                    alpha = 255
                } else {
                    seenNonZeroAlphaPixel = true
                    if seenZeroAlphaPixel {
                        ImageBackingStorePixels.clear(&pixels)
                        sawAlpha = true
                        seenZeroAlphaPixel = false
                    } else if alpha != 255 {
                        sawAlpha = true
                    }
                }

                // getComponent() and getAlpha() are <= 255.
                pixels[rowStart &+ coordX] = ImageBackingStorePixels.pixelValue(
                    premultiplyAlpha: premultiplyAlpha,
                    r: UInt8(truncatingIfNeeded: getComponent(pixel, 0)),
                    g: UInt8(truncatingIfNeeded: getComponent(pixel, 1)),
                    b: UInt8(truncatingIfNeeded: getComponent(pixel, 2)),
                    a: UInt8(truncatingIfNeeded: alpha))
                coordX += 1
            }
        }
        return true
    }

    // decodeRowPixels() for 24-bit pixels, which have no alpha mask: each pixel
    // is opaque B, G, R bytes. Out of line so that decodeRowPixels() stays
    // inline in processNonRLEData().
    @inline(never)
    private mutating func decodeOpaqueBGRRowPixels(
        _ data: Span<UInt8>, startX: Int, endX: Int, _ pixels: inout MutableSpan<UInt32>,
        rowStart: Int
    ) {
        if coordX < endX {
            seenNonZeroAlphaPixel = true
        }
        let first = coordX
        let bytes = data.extracting(
            (decodedOffset + (first - startX) * 3)..<(decodedOffset + (endX - startX) * 3))
        var offset = 0
        for x in first..<endX {
            // Cannot overflow: rowStart + x < rowStart + endX, within the
            // frame's pixels (checked by the caller), and offset + 2 <
            // bytes.count. The compiler keeps the checks of `+` here.
            pixels[rowStart &+ x] =
                0xff00_0000 | UInt32(bytes[offset]) | (UInt32(bytes[offset &+ 1]) << 8)
                | (UInt32(bytes[offset &+ 2]) << 16)
            offset &+= 3
        }
        coordX = endX
    }

    // Processes non-RLE-compressed pixels:
    //  - inRLE: an absolute-mode run of |numPixels| pixels on the current row.
    //  - !inRLE: as many complete rows as possible; |numPixels| is ignored and
    //    the current coordinate is at the start of a row.
    private mutating func processNonRLEData(
        _ data: Span<UInt8>, inRLE: Bool, numPixels requestedPixels: Int,
        _ sink: inout some BMPPixelSink & ~Copyable
    ) -> ProcessingResult {
        if decodedOffset > data.count {
            return .insufficientData
        }

        let width = Int(parentSize(&sink).width)
        let numPixels = inRLE ? requestedPixels : width

        // An RLE absolute-mode run can start partway into a row.
        let startX = coordX

        // Fail if we're being asked to decode more pixels than remain in the row.
        let endX = startX + numPixels
        if endX > width {
            return .failure
        }

        // Bytes needed for the requested pixels. biBitCount is 1, 4, 8, 16, 24
        // or 32 here (isInfoHeaderValid()).
        let bitCount = Int(infoHeader.biBitCount)
        let pixelsPerByte = 8 / bitCount
        let bytesPerPixel = bitCount / 8
        let unpaddedNumBytes =
            (bitCount < 16)
            ? ((numPixels + pixelsPerByte - 1) / pixelsPerByte) : (numPixels * bytesPerPixel)
        // RLE runs are zero-padded to 16 bits; non-RLE rows to 32 bits.
        let alignBits = inRLE ? 1 : 3
        let paddedNumBytes = (unpaddedNumBytes + alignBits) & ~alignBits

        // Decode as many rows as we can. (For RLE, the caller has checked
        // that we are not past the end of the image.)
        while !pastEndOfImage(0, &sink) {
            // Bail if we don't have enough data for the desired number of pixels.
            if remainingIsLessThan(data, paddedNumBytes) {
                return .insufficientData
            }

            // The row is written through one view of the frame's pixels, and
            // hasAlpha is set once the row is done.
            let row = sink.frameRow(frameIndex, coordY)
            precondition(endX <= row.count)
            var sawAlpha = false
            let rowDecoded: Bool
            do {
                var pixels = sink.framePixels(frameIndex)
                rowDecoded = decodeRowPixels(
                    data, startX: startX, endX: endX, bitCount: bitCount,
                    pixelsPerByte: pixelsPerByte, bytesPerPixel: bytesPerPixel,
                    unpaddedNumBytes: unpaddedNumBytes,
                    &pixels, rowStart: row.lowerBound, premultiplyAlpha: premultiplyAlpha,
                    sawAlpha: &sawAlpha)
            }
            if sawAlpha {
                sink.setFrameHasAlpha(frameIndex, true)
            }
            if !rowDecoded {
                return .failure
            }

            // Success, keep going.
            decodedOffset += paddedNumBytes
            if inRLE {
                return .success
            }
            moveBufferToNextRow()
        }

        // Finished decoding whole image.
        return .success
    }
}
