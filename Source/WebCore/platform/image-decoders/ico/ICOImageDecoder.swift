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

// ICOImageDecoder (ico/ICOImageDecoder.{h,cpp}, ICO and CUR) on the Swift
// ICODirectory (directory parsing, ico/ICODirectory.swift) and BMPImageReader
// (bmp/BMPImageReader.swift), through the BMP-family pieces in
// bmp/BMPImageDecoder.swift. The C++ ICOImageDecoder calls these entries once
// per request, with m_lock held.
//
//  * One BMPImageReader per directory entry, by index (m_bmpReaders), each run
//    with the entry's size as the parent's size() (m_frameSize) and failing the
//    decoder when the reader's size does not match the entry (setSize).
//  * PNG entries stay with the C++ PNGImageDecoder, which
//    ScalableImageDecoderFrames::decodePNGEntry runs and copies the frame of.
//  * The frame cache is sized once, to the number of directory entries, at the
//    end of the first decode() call that finds it empty.
//  * The frames are in the order ICODirectory gives the entries, which the C++
//    std::sort with ICOImageDecoder::compareEntries decides
//    (ScalableImageDecoderFrames::sortDirectoryEntries).

internal import WebCore_Private.ImageDecoderSwiftTypes

// MARK: - The entries

/// ICOImageDecoder::decode.
///
/// `data` is the decoder's data, m_data: a SharedBuffer the C++ decoder owns,
/// which stays allocated and unchanged for the call (setData replaces it only
/// with m_lock held, which the caller holds), and which nothing writes. Any
/// byte is a valid UInt8.
///
/// `frames` is the decoder's ImageDecoderFramesState, on the C++ caller's
/// stack and constructed only by it. The Swift reaches the decoder only
/// through it, and what it calls (ScalableImageDecoder, ScalableImageDecoderFrame,
/// ImageBackingStore and PNGImageDecoder) reaches no Swift, runs no script and
/// calls back into nothing.
///
/// FIXME: Take a Span once a std::span can cross safely (rdar://186723514).
@_expose(Cxx)
func icoImageDecoderDecode(
    _ state: ICOImageDecoderState,
    _ frames: inout WebCore.ScalableImageDecoderFrames,
    _ data: WTF.SpanUInt8,
    _ index: UInt,
    _ onlySize: Bool,
    _ allDataReceived: Bool
) {
    let data = unsafe Span<UInt8>(_unsafeCxxSpan: data)
    // A size_t index past Int.max is past every frame, as it is in the C++.
    state.decode(
        &frames, data, index: Int(clamping: index), onlySize: onlySize,
        allDataReceived: allDataReceived)
}

/// ICOImageDecoder::frameSizeAtIndex, with `size` its size().
@_expose(Cxx)
func icoImageDecoderFrameSizeAtIndex(
    _ state: ICOImageDecoderState, _ index: UInt, _ size: WebCore.ImageDecoderSize
) -> WebCore.ImageDecoderSize {
    let entries = state.directory.entries
    let index = Int(clamping: index)
    return (index != 0 && index < entries.count)
        ? ICOImageDecoderState.pixelSize(entries[index].size).imageDecoderSize : size
}

/// ICOImageDecoder::hotSpot: hotSpotAtIndex(0).
@_expose(Cxx)
func icoImageDecoderHotSpot(_ state: ICOImageDecoderState) -> WebCore.ImageDecoderOptionalPoint {
    // Hot spot coordinates are uint16_t.
    guard let point = state.directory.hotSpot(at: 0) else {
        return WebCore.ImageDecoderOptionalPoint(hasValue: false, x: 0, y: 0)
    }
    return WebCore.ImageDecoderOptionalPoint(
        hasValue: true, x: Int32(clamping: point.x), y: Int32(clamping: point.y))
}

// MARK: - The decoder's state

/// ICOImageDecoder's members other than m_pngDecoders. Reached only from the
/// entries above, with the C++ decoder's m_lock held.
@_expose(Cxx)
final class ICOImageDecoderState {
    /// m_decodedOffset, m_fileType, m_dirEntries.
    var directory = ICODirectory()
    /// Whether processDirectoryEntries() has run and called setSize().
    var directoryEntriesProcessed = false
    /// m_bmpReaders.
    var bmpReaders: [BMPImageReader?] = []
    /// m_premultiplyAlpha, which the decoder's constructor sets and nothing changes.
    let premultiplyAlpha: Bool

    @_expose(Cxx)
    init(premultiplyAlpha: Bool) {
        self.premultiplyAlpha = premultiplyAlpha
    }

    static func pixelSize(_ size: ICODirectory.IntSize) -> PixelSize {
        // Entry sides are 0 (not yet read) or 1...256: exact.
        PixelSize(width: Int32(clamping: size.width), height: Int32(clamping: size.height))
    }

    /// ICOImageDecoder::setFailed: m_bmpReaders here, m_pngDecoders in the C++.
    @discardableResult
    func setFailed(_ frames: inout WebCore.ScalableImageDecoderFrames) -> Bool {
        bmpReaders.removeAll()
        return frames.setFailed()
    }

    /// ICOImageDecoder::decode.
    func decode(
        _ frames: inout WebCore.ScalableImageDecoderFrames, _ data: Span<UInt8>, index: Int,
        onlySize: Bool, allDataReceived: Bool
    ) {
        if frames.failed() {
            return
        }

        // If we couldn't decode the image but we've received all the data, decoding
        // has failed.
        if (!decodeDirectory(&frames, data) || (!onlySize && !decodeAtIndex(&frames, data, index)))
            && allDataReceived
        {
            setFailed(&frames)
        } else if frames.frameCount() > index
            && frames.frameInfo(index).status == FrameStatus.complete
        {
            // If we're done decoding this frame, we don't need the BMPImageReader or
            // PNGImageDecoder anymore. If we failed, these have already been
            // cleared, and the index is out of range, which traps as the C++
            // Vector does.
            bmpReaders[index] = nil
            frames.clearPNGDecoder(index)
        }

        if frames.frameCount() == 0 {
            frames.setFrameCount(directory.entries.count)
        }
    }

    /// ICOImageDecoder::decodeDirectory, with processDirectory and
    /// processDirectoryEntries in ICODirectory and their setFailed() and
    /// setSize() calls made here.
    private func decodeDirectory(
        _ frames: inout WebCore.ScalableImageDecoderFrames, _ data: Span<UInt8>
    ) -> Bool {
        let status = directory.decodeDirectory(data) { entries in
            for entry in entries {
                frames.appendDirectoryEntry(
                    Self.pixelSize(entry.size).imageDecoderSize, entry.bitCount)
            }
            frames.sortDirectoryEntries()
            return entries.indices.map { Int(frames.sortedDirectoryEntryIndex($0)) }
        }

        // processDirectory: m_bmpReaders.resize(idCount), m_pngDecoders.resize(idCount),
        // once.
        let entryCount = directory.entries.count
        if status != .failed && bmpReaders.isEmpty && entryCount > 0 {
            bmpReaders = Array(repeating: nil, count: entryCount)
            frames.setPNGDecoderCount(entryCount)
        }

        switch status {
        case .needMoreData:
            return false
        case .failed:
            return setFailed(&frames)
        case .ok:
            if directoryEntriesProcessed {
                return true
            }
            // processDirectoryEntries: the image size is the size of the
            // largest entry.
            directoryEntriesProcessed = true
            guard let best = directory.entries.first else {
                return setFailed(&frames)  // unreachable: idCount >= 1
            }
            if !frames.setSize(Self.pixelSize(best.size).imageDecoderSize) {
                bmpReaders.removeAll()
                return false
            }
            return true
        }
    }

    /// ICOImageDecoder::decodeAtIndex.
    private func decodeAtIndex(
        _ frames: inout WebCore.ScalableImageDecoderFrames, _ data: Span<UInt8>, _ index: Int
    ) -> Bool {
        // C++ ASSERT_WITH_SECURITY_IMPLICATION(index < m_dirEntries.size()):
        // frameBufferAtIndex only passes index < frame count == entry count.
        let entries = directory.entries
        guard index >= 0, index < entries.count, index < bmpReaders.count,
            index < frames.frameCount()
        else {
            return false
        }
        let entry = entries[index]
        let result: Bool
        switch directory.imageType(at: index, in: data) {
        case .unknown:
            return false  // Not enough data to determine image type yet.
        case .bmp:
            result = decodeBMPEntry(&frames, data, index, entry: entry)
        case .png:
            result = frames.decodePNGEntry(
                index, entry.imageOffset, Self.pixelSize(entry.size).imageDecoderSize)
        }
        // Each failure above ran ICOImageDecoder::setFailed(), which also clears m_bmpReaders.
        if frames.failed() {
            bmpReaders.removeAll()
        }
        return result
    }

    private func decodeBMPEntry(
        _ frames: inout WebCore.ScalableImageDecoderFrames, _ data: Span<UInt8>, _ index: Int,
        entry: ICODirectory.Entry
    ) -> Bool {
        var reader: BMPImageReader
        if let existing = bmpReaders[index] {
            reader = existing
        } else {
            reader = BMPImageReader(
                decodedAndHeaderOffset: Int(entry.imageOffset), imgDataOffset: 0, usesAndMask: true,
                premultiplyAlpha: premultiplyAlpha)
        }
        // The reader is out of the array while it runs; it goes back only if
        // the decoder has not failed.
        bmpReaders[index] = nil

        let entrySize = Self.pixelSize(entry.size)
        reader.frameIndex = index
        reader.entrySize = BMPIntSize(width: entrySize.width, height: entrySize.height)
        let result = runBMPReader(&reader, &frames, data, onlySize: false)

        if !frames.failed() && index < bmpReaders.count {
            bmpReaders[index] = reader
        }
        return result
    }
}
