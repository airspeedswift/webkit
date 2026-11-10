/*
 * Copyright (c) 2008-2009 Google Inc. All rights reserved.
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

// BMPImageDecoder (bmp/BMPImageDecoder.{h,cpp}) on the Swift BMPImageReader
// (BMPImageReader.swift). The C++ BMPImageDecoder calls the entry once per
// decode request, with m_lock held.
//
// Also the pieces ICOImageDecoder.swift shares with this file:
//  * BMPPixelSink on ScalableImageDecoderFrames: the frame cache a
//    BMPImageReader decodes into (the reader's m_parent and m_buffer).
//  * runBMPReader: one decodeBMP() call into one of them.
//
// The reader is taken out of the decoder's state while it runs and put back
// only if the decoder has not failed, so setFailed() never destroys a running
// reader. The reader decodes m_readerData, which BMPImageDecoder::setData
// updates after ScalableImageDecoder::setData, so the tryDecodeSize() call
// inside setData decodes the previous data, as the C++ reader does.

internal import WebCore_Private.ImageDecoderSwiftTypes

// MARK: - The frame cache a BMPImageReader decodes into

extension WebCore.ScalableImageDecoderFrames: BMPPixelSink {
    var decoderSize: BMPIntSize {
        mutating get {
            let decoderSize = self.size
            return BMPIntSize(width: decoderSize.width, height: decoderSize.height)
        }
    }

    mutating func setDecoderSize(_ size: BMPIntSize) -> Bool {
        setSize(WebCore.ImageDecoderSize(width: size.width, height: size.height))
    }

    mutating func frameIsInvalid(_ index: Int) -> Bool {
        frameInfo(index).status == FrameStatus.invalid
    }

    /// The C++ passes m_parent->premultiplyAlpha(), which is what
    /// ScalableImageDecoderFrames::initialize uses.
    mutating func initializeFrame(_ index: Int, size: BMPIntSize, premultiplyAlpha: Bool) -> Bool {
        initialize(index, WebCore.ImageDecoderSize(width: size.width, height: size.height))
    }

    mutating func setStatusPartial(_ index: Int) {
        setDecodingStatus(index, FrameStatus.partial)
    }

    mutating func setStatusComplete(_ index: Int) {
        setDecodingStatus(index, FrameStatus.complete)
    }

    mutating func frameHasAlpha(_ index: Int) -> Bool {
        frameInfo(index).hasAlpha
    }

    mutating func setFrameHasAlpha(_ index: Int, _ hasAlpha: Bool) {
        setHasAlpha(index, hasAlpha)
    }

    // The reader passes rows of the frame, whose sides are < 65536. An
    // out-of-bounds row traps in pixelIndex.
    mutating func frameRow(_ index: Int, _ y: Int) -> Range<Int> {
        let info = frameInfo(index)
        precondition(info.hasBackingStore)
        let storeSize = PixelSize(info.storeSize)
        let start = ImageBackingStorePixels.pixelIndex(x: 0, y: Int32(clamping: y), size: storeSize)
        return start..<(start + Int(storeSize.width))
    }

    @_lifetime(&self)
    mutating func framePixels(_ index: Int) -> MutableSpan<UInt32> {
        pixels(index)
    }

    mutating func fillRect(
        _ index: Int, x: Int, y: Int, width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8,
        a: UInt8, premultiplyAlpha: Bool
    ) {
        let info = frameInfo(index)
        precondition(info.hasBackingStore)
        let storeSize = PixelSize(info.storeSize)
        // A rect that does not fit in IntRect is not in bounds, which fill() ignores.
        guard let x = Int32(exactly: x), let y = Int32(exactly: y),
            let width = Int32(exactly: width), let height = Int32(exactly: height)
        else {
            return
        }
        let rect = PixelRect(x: x, y: y, width: width, height: height)
        let value = ImageBackingStorePixels.pixelValue(
            premultiplyAlpha: premultiplyAlpha, r: r, g: g, b: b, a: a)
        var pixels = self.pixels(index)
        ImageBackingStorePixels.fill(&pixels, size: storeSize, rect, with: value)
    }
}

/// `m_reader->decodeBMP(onlySize)` into `frames`. Returns the C++ bool:
/// `.failed` is C++ `return m_parent->setFailed()`, run here once the reader
/// has returned (the reader never touches the sink after deciding to fail);
/// `.sizeRejected` means the sink's setSize already failed the decoder.
func runBMPReader(
    _ reader: inout BMPImageReader, _ frames: inout WebCore.ScalableImageDecoderFrames,
    _ data: Span<UInt8>, onlySize: Bool
) -> Bool {
    switch reader.decodeBMP(data, onlySize: onlySize, sink: &frames) {
    case .success:
        return true
    case .insufficientData, .sizeRejected:
        return false
    case .failed:
        return frames.setFailed()
    }
}

// MARK: - BMPImageDecoder

/// BMPImageDecoder::decode. Returns whether the decoder still has a reader
/// (m_reader).
///
/// `readerData` is the reader's data, m_readerData: a SharedBuffer the C++
/// decoder owns, which stays allocated and unchanged for the call (setData
/// replaces it only with m_lock held, which the caller holds), and which
/// nothing writes. Any byte is a valid UInt8.
///
/// `frames` is the decoder's ImageDecoderFramesState, on the C++ caller's
/// stack and constructed only by it. The Swift reaches the decoder only
/// through it, and what it calls (ScalableImageDecoder, ScalableImageDecoderFrame
/// and ImageBackingStore) reaches no Swift, runs no script and calls back into
/// nothing.
///
/// FIXME: Take a Span once a std::span can cross safely (rdar://186723514).
@_expose(Cxx)
func bmpImageDecoderDecode(
    _ state: BMPImageDecoderState,
    _ frames: inout WebCore.ScalableImageDecoderFrames,
    _ readerData: WTF.SpanUInt8,
    _ onlySize: Bool,
    _ allDataReceived: Bool
) -> Bool {
    let data = unsafe Span<UInt8>(_unsafeCxxSpan: readerData)
    state.decode(&frames, data, onlySize: onlySize, allDataReceived: allDataReceived)
    return state.reader != nil
}

/// BMPImageDecoder's members. Reached only from the entry above, with the C++
/// decoder's m_lock held.
@_expose(Cxx)
final class BMPImageDecoderState {
    /// m_decodedOffset: how much of the data this class has decoded (only the
    /// file header; the reader tracks the rest).
    var decodedOffset = 0
    /// m_reader.
    var reader: BMPImageReader?
    /// m_premultiplyAlpha, which the decoder's constructor sets and nothing changes.
    let premultiplyAlpha: Bool

    @_expose(Cxx)
    init(premultiplyAlpha: Bool) {
        self.premultiplyAlpha = premultiplyAlpha
    }

    /// BMPImageDecoder::setFailed.
    @discardableResult
    func setFailed(_ frames: inout WebCore.ScalableImageDecoderFrames) -> Bool {
        reader = nil
        return frames.setFailed()
    }

    /// BMPImageDecoder::decode.
    func decode(
        _ frames: inout WebCore.ScalableImageDecoderFrames, _ data: Span<UInt8>, onlySize: Bool,
        allDataReceived: Bool
    ) {
        if frames.failed() {
            return
        }

        // If we couldn't decode the image but we've received all the data, decoding
        // has failed.
        if !decodeHelper(&frames, data, onlySize: onlySize) && allDataReceived {
            setFailed(&frames)
        } else if frames.frameCount() != 0 && frames.frameInfo(0).status == FrameStatus.complete {
            // If we're done decoding the image, we don't need the BMPImageReader
            // anymore. (If we failed, the reader has already been cleared.)
            reader = nil
        }
    }

    /// BMPImageDecoder::decodeHelper.
    private func decodeHelper(
        _ frames: inout WebCore.ScalableImageDecoderFrames, _ data: Span<UInt8>, onlySize: Bool
    ) -> Bool {
        var imgDataOffset = 0
        if decodedOffset < BMPImageReader.sizeOfFileHeader {
            // processFileHeader.
            switch BMPImageReader.bmpFileHeader(data) {
            case .needMoreData:
                return false
            case .notBMP:
                decodedOffset = BMPImageReader.sizeOfFileHeader
                return setFailed(&frames)
            case .ok(let offset):
                imgDataOffset = offset
                decodedOffset = BMPImageReader.sizeOfFileHeader
            }
        }

        if reader == nil {
            reader = BMPImageReader(
                decodedAndHeaderOffset: decodedOffset, imgDataOffset: imgDataOffset,
                usesAndMask: false, premultiplyAlpha: premultiplyAlpha)
        }

        // The reader's m_buffer is &m_frameBufferCache.first() once the cache
        // has a frame (the C++ sets it only then; with an empty cache only a
        // size-only decode runs, which never reaches the frame).
        guard var reader else {
            return false
        }
        self.reader = nil
        let result = runBMPReader(&reader, &frames, data, onlySize: onlySize)
        if !frames.failed() {
            self.reader = reader
        }
        return result
    }
}
