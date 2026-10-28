/*
 * Copyright (C) 2006 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// GIFImageDecoder (gif/GIFImageDecoder.{h,cpp}) on the Swift GIFImageReader
// (GIFImageReader.swift). The C++ GIFImageDecoder calls these entries once per
// decode request, with m_lock held.
//
//  * GIFImageDecoderState is the decoder's own state: the reader and the alpha
//    tracker. The frame cache, size and status stay in ScalableImageDecoder,
//    reached through ScalableImageDecoderFrames.
//  * The reader's client is the state, with the frame cache passed beside it.
//    While a reader call runs, the reader is out of the state, in a local.
//    setFailed() and gifComplete(), which destroy m_reader in the C++, set
//    flags that are applied when the reader returns; the C++ does not touch
//    the reader after either.
//  * The reader decodes m_readerData, so a tryDecodeSize from setData decodes
//    the reader's previous data, as in the C++.
//  * Coordinates come from 16-bit GIF fields, so Int arithmetic on them is
//    exact.

internal import WebCore_Private.ImageDecoderSwiftTypes

let gifRepetitionCountOnce: Int32 = 1  // WebCore::RepetitionCountOnce

// MARK: - The entries

/// GIFImageDecoder::decode (`request` Size or FrameCount, with `index` as
/// haltAtFrame) and GIFImageDecoder::frameBufferAtIndex (`request` Frame).
/// `repetitionCount` is m_repetitionCount, which the call may update (as
/// gifComplete() does) and returns.
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
func gifImageDecoderDecode(
    _ state: GIFImageDecoderState,
    _ frames: inout WebCore.ScalableImageDecoderFrames,
    _ readerData: WTF.SpanUInt8,
    _ request: WebCore.ImageDecoderRequest,
    _ index: UInt,
    _ allDataReceived: Bool,
    _ repetitionCount: Int32
) -> WebCore.GIFImageDecoderResult {
    let data = unsafe Span<UInt8>(_unsafeCxxSpan: readerData)
    state.repetitionCount = repetitionCount
    state.colorTableKey = nil
    state.rowFrameIndex = -1
    var frameAvailable = false
    if request == .Size {
        state.decode(
            &frames, data, haltAtFrame: UInt32(truncatingIfNeeded: index), query: .size,
            allDataReceived: allDataReceived)
    } else if request == .FrameCount {
        state.decode(
            &frames, data, haltAtFrame: UInt32(truncatingIfNeeded: index), query: .frameCount,
            allDataReceived: allDataReceived)
    } else {
        // A size_t index past Int.max is past every frame, as it is in the C++.
        frameAvailable = state.frameBufferAtIndex(&frames, data, Int(clamping: index))
    }
    return WebCore.GIFImageDecoderResult(
        frameAvailable: frameAvailable,
        hasReader: state.reader != nil,
        repetitionCount: state.repetitionCount,
        readerRepetitionCount: state.readerRepetitionCount)
}

/// GIFImageDecoder::clearDecodedPixelDataIfNeeded.
///
/// `frames` is as for gifImageDecoderDecode.
@_expose(Cxx)
func gifImageDecoderClearFrameBufferCache(
    _ state: GIFImageDecoderState,
    _ frames: inout WebCore.ScalableImageDecoderFrames,
    _ clearBeforeFrame: UInt
) {
    state.rowFrameIndex = -1
    state.clearDecodedPixelDataIfNeeded(&frames, Int(clamping: clearBeforeFrame))
}

// MARK: - The decoder's state

/// GIFImageDecoder's members other than the frame cache. Reached only from the
/// entries above, with the C++ decoder's m_lock held.
@_expose(Cxx)
final class GIFImageDecoderState {
    /// m_reader. nil while a reader call is in progress (the reader is then a
    /// local of runReader) and after setFailed()/gifComplete().
    var reader: GIFImageReader?
    /// m_currentBufferSawAlpha. The C++ member has no initializer, but every read
    /// (frameComplete) follows a write by initFrameBuffer on the same decoder.
    var currentBufferSawAlpha = false
    /// m_repetitionCount, for the duration of an entry.
    var repetitionCount: Int32 = gifRepetitionCountOnce
    /// The frame rects (xOffset, yOffset, width, height) of the reader's frames
    /// with a defined header, i.e. what initFrameBuffer() reads through
    /// m_reader->frameContext() when it is reached from frameComplete(), where
    /// the Swift reader cannot be read (it is the callee). Header fields never
    /// change once defined; the list goes with the reader.
    var frameRects: [GIFFrameRect] = []
    /// Set by setFailed()/gifComplete() while the reader is moved out.
    var readerDestroyed = false
    var gifCompleted = false
    /// m_premultiplyAlpha, which the decoder's constructor sets and nothing changes.
    let premultiplyAlpha: Bool
    /// haveDecodedRow's colours for the colour indices 0...255 under one colour map
    /// and transparent index: the pixel value of each index the colour map holds,
    /// and 0 for the transparent index and the indices past the colour map. An
    /// opaque pixel value is never 0. The colour map is read from the data of one
    /// entry call, so gifImageDecoderDecode clears the key on every call.
    private var colorTable = [256 of UInt32](repeating: 0)
    var colorTableKey: GIFColorTableKey?
    /// The entries of colorTable past this one are 0.
    private var colorTableFilledCount = 0
    /// The frame haveDecodedRow last wrote, which is not Invalid and has a
    /// backing store of size rowStoreSize, or -1. Only clear() and setFrameCount()
    /// can make a frame Invalid or drop its store within an entry call, so it is
    /// reset beside each and at every entry.
    var rowFrameIndex = -1
    private var rowStoreSize = PixelSize(width: 0, height: 0)

    @_expose(Cxx)
    init(premultiplyAlpha: Bool) {
        self.premultiplyAlpha = premultiplyAlpha
    }

    /// What repetitionCount() takes from m_reader: RepetitionCountOnce when it
    /// has no frames, its loop count when it has seen one, and 0 otherwise.
    var readerRepetitionCount: Int32 {
        guard let imagesCount = reader?.imagesCount, let loopCount = reader?.loopCount else {
            return 0
        }
        if imagesCount == 0 {
            return gifRepetitionCountOnce
        }
        if loopCount != gifLoopCountNotSeen {
            // loopCount is a 16-bit stream field or RepetitionCountInfinite (-1).
            return Int32(clamping: loopCount > 0 ? loopCount + 1 : loopCount)
        }
        return 0
    }

    /// The body of repetitionCount() with m_reader's two values, as
    /// gifComplete() runs it.
    func updateRepetitionCount(
        _ frames: inout WebCore.ScalableImageDecoderFrames, imagesCount: Int, loopCount: Int
    ) {
        if frames.failed() || imagesCount == 0 {
            repetitionCount = gifRepetitionCountOnce
        } else if loopCount != gifLoopCountNotSeen {
            repetitionCount = Int32(clamping: loopCount > 0 ? loopCount + 1 : loopCount)
        }
    }

    @inline(never)
    private func buildColorTable(_ key: GIFColorTableKey, data: Span<UInt8>) {
        colorTableFilledCount = Self.fillColorTable(
            &colorTable, filledCount: colorTableFilledCount,
            colorMap: data.extracting(key.colorMap),
            transparentIndex: key.transparentIndex, premultiplyAlpha: premultiplyAlpha)
        colorTableKey = key
    }

    /// The colorTable entries for `colorMap` and `transparentIndex`, given that the
    /// entries past `filledCount` are 0. Returns the new filled count. The table is
    /// inout, here and in writeRow, so that it is accessed in place in the state.
    private static func fillColorTable(
        _ table: inout [256 of UInt32], filledCount: Int, colorMap: Span<UInt8>,
        transparentIndex: Int, premultiplyAlpha: Bool
    ) -> Int {
        var entries = table.mutableSpan
        // An index is in the colour map when index * 3 + 2 < colorMap.count.
        let colorCount = min(colorMap.count / 3, 256)
        for index in 0..<colorCount {
            if index != transparentIndex {
                entries[index] = ImageBackingStorePixels.pixelValue(
                    premultiplyAlpha: premultiplyAlpha,
                    r: colorMap[index * 3], g: colorMap[index * 3 + 1], b: colorMap[index * 3 + 2],
                    a: 255)
            } else {
                entries[index] = 0
            }
        }
        // Only the entries a previous, larger colour map wrote can be non-zero past this one.
        if filledCount > colorCount {
            for index in colorCount..<filledCount {
                entries[index] = 0
            }
        }
        return colorCount
    }

    /// GIFImageDecoder::setSize.
    func setSize(_ frames: inout WebCore.ScalableImageDecoderFrames, _ size: PixelSize) -> Bool {
        if frames.isSizeAvailable() && PixelSize(frames.size) == size {
            return true
        }
        return frames.setSize(size.imageDecoderSize)
    }

    /// GIFImageDecoder::setFailed.
    @discardableResult
    func setFailed(_ frames: inout WebCore.ScalableImageDecoderFrames) -> Bool {
        reader = nil
        readerDestroyed = true
        return frames.setFailed()
    }

    /// GIFImageDecoder::decodeIfNeededAndGetFrameCount.
    func decodeIfNeededAndGetFrameCount(
        _ frames: inout WebCore.ScalableImageDecoderFrames, _ data: Span<UInt8>
    ) -> Int {
        decode(
            &frames, data, haltAtFrame: UInt32.max, query: .frameCount,
            allDataReceived: frames.isAllDataReceived())
        return frames.frameCount()
    }

    /// GIFImageDecoder::findFirstRequiredFrameToDecode.
    func findFirstRequiredFrameToDecode(
        _ frames: inout WebCore.ScalableImageDecoderFrames, _ frameIndex: Int
    ) -> Int {
        // The first frame doesn't depend on any other.
        if frameIndex == 0 {
            return 0
        }

        var i = frameIndex
        while i > 0 {
            defer { i -= 1 }
            let info = frames.frameInfo(i - 1)
            let disposalMethod = info.disposalMethod

            // Frames with disposal method RestoreToPrevious are useless, skip them.
            if disposalMethod == FrameDisposalMethod.restoreToPrevious {
                continue
            }

            // At this point the disposal method can be Unspecified, DoNotDispose or RestoreToBackground.
            // In every case, if the frame is complete we can start decoding the next one.
            if info.status == FrameStatus.complete {
                return i
            }

            // If the disposal method of this frame is RestoreToBackground and it fills the whole area,
            // the next frame's backing store is initialized to transparent, so we start decoding with it.
            if disposalMethod == FrameDisposalMethod.restoreToBackground {
                // The values come from the reader context (the frame's backing store
                // was cleared when the frame was removed from the cache). Without a
                // reader the frame is treated as not covering the image.
                if let frameContext = reader?.frameContext(at: i - 1) {
                    let frameRect = GIFFrameRect(frameContext).pixelRect
                    if frameRect.contains(PixelRect(size: PixelSize(frames.size))) {
                        return i
                    }
                }
            }
        }

        return 0
    }

    /// GIFImageDecoder::frameBufferAtIndex: whether the C++ returns
    /// &m_frameBufferCache[index].
    func frameBufferAtIndex(
        _ frames: inout WebCore.ScalableImageDecoderFrames, _ data: Span<UInt8>, _ index: Int
    ) -> Bool {
        if index >= decodeIfNeededAndGetFrameCount(&frames, data) {
            return false
        }

        if frames.frameInfo(index).status != FrameStatus.complete {
            var i = findFirstRequiredFrameToDecode(&frames, index)
            while i <= index {
                // The C++ passes i + 1 to decode()'s unsigned haltAtFrame, modulo 2^32.
                decode(
                    &frames, data, haltAtFrame: UInt32(truncatingIfNeeded: i + 1), query: .full,
                    allDataReceived: frames.isAllDataReceived())
                i += 1
            }
        }

        // The decodes above set the cache's size only to the frame count it already
        // has, so this is the frame the C++ returns.
        return index < frames.frameCount()
    }

    /// GIFImageDecoder::clearDecodedPixelDataIfNeeded, with indices instead of
    /// iterators.
    func clearDecodedPixelDataIfNeeded(
        _ frames: inout WebCore.ScalableImageDecoderFrames, _ clearBeforeFrame: Int
    ) {
        // In some cases, like if the decoder was destroyed while animating, we
        // can be asked to clear more frames than we currently have.
        let count = frames.frameCount()
        if count == 0 {
            return  // Nothing to do.
        }

        // We never want to clear the very last frame in the cache: it's empty,
        // partial, or could be needed to construct the next frame after a future
        // setData(). count >= 1 here.
        let end = min(clearBeforeFrame, count - 1)

        // Scan backwards from |end| past empty frames and RestoreToPrevious frames
        // (clearing the complete ones other than |end|); stop at the first frame
        // that a future initFrameBuffer() may copy from.
        var i = end
        while i != 0 {
            let info = frames.frameInfo(i)
            if info.status != FrameStatus.invalid
                && info.disposalMethod != FrameDisposalMethod.restoreToPrevious
            {
                break
            }
            if info.status == FrameStatus.complete && i != end {
                rowFrameIndex = -1
                frames.clear(i)
            }
            i -= 1
        }

        // Now |i| holds the last frame we need to preserve; clear prior frames.
        // (C++ ASSERT(!j->isPartial()) is debug-only; release clears a partial
        // frame like any other non-empty one, and so does this.)
        for j in 0..<i where frames.frameInfo(j).status != FrameStatus.invalid {
            rowFrameIndex = -1
            frames.clear(j)
        }
    }

    /// GIFImageDecoder::decode.
    func decode(
        _ frames: inout WebCore.ScalableImageDecoderFrames, _ data: Span<UInt8>,
        haltAtFrame: UInt32, query: GIFQuery, allDataReceived: Bool
    ) {
        if frames.failed() {
            return
        }
        // The frame rects go with the reader, which setFailed() and gifComplete()
        // destroy.
        defer {
            if reader == nil {
                frameRects = []
            }
        }

        if reader == nil {
            reader = GIFImageReader()
            frameRects = []
        }

        if query == .size {
            if !runReader(&frames, data, query: .size, haltAtFrame: haltAtFrame) {
                setFailed(&frames)
            }
            return
        }

        if !runReader(&frames, data, query: .frameCount, haltAtFrame: haltAtFrame) {
            setFailed(&frames)
            return
        }

        // A successful frame-count query cannot destroy the reader (only
        // setFailed(), which makes it return false, and gifComplete(), which only
        // a full query reaches, do). C++ dereferences m_reader here unchecked.
        guard let imagesCount = reader?.imagesCount else {
            return
        }
        // Record the rects of the newly header-defined frames (see frameRects).
        while frameRects.count < imagesCount,
            let frameContext = reader?.frameContext(at: frameRects.count)
        {
            frameRects.append(GIFFrameRect(frameContext))
        }

        // m_frameBufferCache.resize(m_reader->imagesCount()).
        rowFrameIndex = -1
        frames.setFrameCount(imagesCount)

        if query == .frameCount {
            return
        }

        if !runReader(&frames, data, query: .full, haltAtFrame: haltAtFrame) {
            setFailed(&frames)
            return
        }

        // It is also a fatal error if all data is received but we failed to decode
        // all frames completely. (C++ compares unsigned with size_t.)
        if allDataReceived && UInt64(haltAtFrame) >= UInt64(frames.frameCount()) && reader != nil {
            setFailed(&frames)
        }
    }

    /// One `m_reader->decode(query, haltAtFrame)` call, with the reader moved out
    /// of the state for its duration (the state is the reader's client).
    private func runReader(
        _ frames: inout WebCore.ScalableImageDecoderFrames, _ data: Span<UInt8>, query: GIFQuery,
        haltAtFrame: UInt32
    ) -> Bool {
        guard var reader else {
            return false  // Unreachable: decode() creates the reader first.
        }
        self.reader = nil
        readerDestroyed = false
        gifCompleted = false

        var client = self
        let result = reader.decode(
            data, query: query, haltAtFrame: haltAtFrame, client: &client, frameCache: &frames)

        if gifCompleted {
            // GIFImageDecoder::gifComplete, the reader's last statement: cache the
            // repetition count, which is now as authoritative as it's ever going
            // to be, and destroy the reader.
            gifCompleted = false
            updateRepetitionCount(
                &frames, imagesCount: reader.imagesCount, loopCount: reader.loopCount)
        } else if !readerDestroyed {
            self.reader = reader
        }
        readerDestroyed = false
        return result
    }
}

/// The colour map (a range of the reader's data) and transparent index (-1 for
/// none) that GIFImageDecoderState's colour table was built for.
struct GIFColorTableKey: Equatable {
    let colorMap: Range<Int>
    let transparentIndex: Int
}

/// IntRect(frameContext->xOffset, frameContext->yOffset, frameContext->width,
/// frameContext->height). Every field is a 16-bit stream value (<= 65535).
struct GIFFrameRect {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(_ frame: GIFFrameContext) {
        x = frame.xOffset
        y = frame.yOffset
        width = frame.width
        height = frame.height
    }

    /// Each field is <= 65535, so the conversions are exact.
    var pixelRect: PixelRect {
        PixelRect(
            x: Int32(truncatingIfNeeded: x), y: Int32(truncatingIfNeeded: y),
            width: Int32(truncatingIfNeeded: width), height: Int32(truncatingIfNeeded: height))
    }

    /// IntRect::intersect with IntRect(IntPoint(), size).
    /// The sums are <= 131070.
    func intersected(with size: PixelSize) -> PixelRect {
        var l = max(x, 0)
        var t = max(y, 0)
        var r = min(x + width, Int(size.width))
        var b = min(y + height, Int(size.height))

        // Return a clean empty rectangle for non-intersecting cases.
        if l >= r || t >= b {
            l = 0
            t = 0
            r = 0
            b = 0
        }

        // 0 <= l < r <= size.width, and likewise vertically.
        return PixelRect(
            x: Int32(truncatingIfNeeded: l), y: Int32(truncatingIfNeeded: t),
            width: Int32(truncatingIfNeeded: r - l), height: Int32(truncatingIfNeeded: b - t))
    }
}

// MARK: - The reader callbacks

extension GIFImageDecoderState: GIFReaderClient {
    /// GIFImageReader's `m_client->setSize(IntSize(m_screenWidth, m_screenHeight))`.
    func setSize(
        width: Int, height: Int, frameCache frames: inout WebCore.ScalableImageDecoderFrames
    ) -> Bool {
        // 16-bit stream values: always representable.
        guard let width = Int32(exactly: width), let height = Int32(exactly: height) else {
            return setFailed(&frames)
        }
        return setSize(&frames, PixelSize(width: width, height: height))
    }

    /// GIFImageDecoder::haveDecodedRow. `frame` is m_reader->frameContext() and
    /// `globalColormap` m_reader->globalColormap(), as a range into `data`.
    func haveDecodedRow(
        frameIndex: Int, row: Span<UInt8>, width: Int, rowNumber: Int, repeatCount: Int,
        writeTransparentPixels: Bool, frame: GIFFrameContext, globalColormap: Range<Int>,
        data: Span<UInt8>,
        frameCache frames: inout WebCore.ScalableImageDecoderFrames
    ) -> Bool {
        // The pixel data and coordinates supplied to us are relative to the frame's
        // origin within the entire image size, i.e. (xOffset, yOffset). There is no
        // guarantee that width == (size().width() - xOffset), so we must ensure we
        // don't run off the end of either the source data or the row's X-coordinates.
        // (offsets, width, rowNumber < 65536 and repeatCount <= 8: no overflow.)
        let size = PixelSize(frames.size)
        let xBegin = frame.xOffset
        let yBegin = frame.yOffset + rowNumber
        let xEnd = min(frame.xOffset + width, Int(size.width))
        let yEnd = min(frame.yOffset + rowNumber + repeatCount, Int(size.height))
        if row.isEmpty || xEnd <= xBegin || yEnd <= yBegin {
            return true
        }

        // Get the colormap.
        let colorMap = frame.isLocalColormapDefined ? frame.localColormapRange : globalColormap
        if colorMap.isEmpty {
            return true
        }
        // The colormap was parsed out of this data, so the range is in bounds
        // unless the data has shrunk; the decode then fails.
        guard colorMap.lowerBound >= 0, colorMap.upperBound <= data.count else {
            return false
        }

        // Initialize the frame if necessary.
        if frameIndex != rowFrameIndex && !prepareRowFrame(&frames, frameIndex, GIFFrameRect(frame))
        {
            return false
        }

        // 0 <= xBegin < xEnd <= size.width and 0 <= yBegin < yEnd <= size.height.
        let x0 = Int32(truncatingIfNeeded: xBegin)
        let y0 = Int32(truncatingIfNeeded: yBegin)
        let rect = PixelRect(
            x: x0, y: y0, width: Int32(truncatingIfNeeded: xEnd - xBegin),
            height: Int32(truncatingIfNeeded: yEnd - yBegin))
        let colorTableKey = GIFColorTableKey(
            colorMap: colorMap, transparentIndex: frame.isTransparent ? frame.tpixel : -1)
        if self.colorTableKey != colorTableKey {
            buildColorTable(colorTableKey, data: data)
        }
        let storeSize = rowStoreSize
        let transparentPixel = ImageBackingStorePixels.pixelValue(
            premultiplyAlpha: premultiplyAlpha, r: 0, g: 0, b: 0, a: 0)

        var pixels = frames.pixels(frameIndex)
        let start = ImageBackingStorePixels.pixelIndex(x: x0, y: y0, size: storeSize)
        // xBegin == xOffset and xEnd <= xOffset + width == xOffset + row.count, so the
        // pixels written are the row's first xEnd - xBegin.
        let count = xEnd - xBegin
        let sawAlpha = Self.writeRow(
            &colorTable, row.extracting(0..<count), to: &pixels, at: start,
            writeTransparentPixels: writeTransparentPixels, transparentPixel: transparentPixel)

        // Tell the frame to copy the row data if need be.
        if repeatCount > 1 {
            ImageBackingStorePixels.repeatFirstRow(&pixels, size: storeSize, rect)
        }
        if sawAlpha {
            currentBufferSawAlpha = true
        }

        return true
    }

    /// Write one row's worth of data into the frame: the colours of `source`'s
    /// indices to `pixels` from `start`. Returns whether any was transparent.
    @inline(always)
    private static func writeRow(
        _ colorTable: inout [256 of UInt32], _ source: Span<UInt8>,
        to pixels: inout MutableSpan<UInt32>, at start: Int,
        writeTransparentPixels: Bool, transparentPixel: UInt32
    ) -> Bool {
        let colors = colorTable.span
        var sawAlpha = false
        for i in source.indices {
            let color = colors[Int(source[i])]
            if color != 0 {
                pixels[start + i] = color
            } else {
                sawAlpha = true
                // We may or may not need to write transparent pixels to the buffer.
                // If we're compositing against a previous image, it's wrong, and if
                // we're writing atop a cleared, fully transparent buffer, it's
                // unnecessary; but if we're decoding an interlaced gif and
                // displaying it "Haeberli"-style, we must write these for passes
                // beyond the first, or the initial passes will "show through" the
                // later ones.
                if writeTransparentPixels {
                    pixels[start + i] = transparentPixel
                }
            }
        }
        return sawAlpha
    }

    /// The start of haveDecodedRow for a frame other than rowFrameIndex: initialize
    /// the frame if it is Invalid, and fail when it has no backing store.
    @inline(never)
    private func prepareRowFrame(
        _ frames: inout WebCore.ScalableImageDecoderFrames, _ frameIndex: Int,
        _ frameRect: GIFFrameRect
    ) -> Bool {
        var info = frames.frameInfo(frameIndex)
        if info.status == FrameStatus.invalid {
            if !initFrameBuffer(&frames, frameIndex, frameRect) {
                return false
            }
            info = frames.frameInfo(frameIndex)
        }
        if !info.hasBackingStore {
            return false
        }
        rowFrameIndex = frameIndex
        rowStoreSize = PixelSize(info.storeSize)
        return true
    }

    /// GIFImageDecoder::frameComplete.
    func frameComplete(
        frameIndex: Int, delayTime: Int, disposal: GIFDisposalMethod,
        frameCache frames: inout WebCore.ScalableImageDecoderFrames
    ) -> Bool {
        // Initialize the frame if necessary. Some GIFs insert do-nothing frames,
        // in which case we never reach haveDecodedRow() before getting here.
        if frames.frameInfo(frameIndex).status == FrameStatus.invalid {
            // The frame being completed was header-defined when this decode began,
            // so its rect is recorded (see frameRects).
            guard frameIndex < frameRects.count else {
                return setFailed(&frames)
            }
            if !initFrameBuffer(&frames, frameIndex, frameRects[frameIndex]) {
                return false  // initFrameBuffer() has already called setFailed().
            }
        }

        // The C++ delay time is unsigned, and 16-bit GIF delays times 10 fit.
        // GIFImageReader passes the GIF disposal method as
        // ScalableImageDecoderFrame::DisposalMethod (same values, 0...3).
        frames.completeFrame(
            frameIndex, UInt32(truncatingIfNeeded: delayTime),
            UInt8(truncatingIfNeeded: disposal.rawValue))

        if !currentBufferSawAlpha {
            // initFrameBuffer gave the frame a backing store.
            let info = frames.frameInfo(frameIndex)
            guard info.hasBackingStore else {
                return true
            }
            let rect = PixelRect(info.rect)

            // The whole frame was non-transparent, so it's possible that the entire
            // resulting buffer was non-transparent, and we can setHasAlpha(false).
            if rect.contains(PixelRect(size: PixelSize(frames.size))) {
                frames.setHasAlpha(frameIndex, false)
            } else if frameIndex != 0 {
                // Tricky case. This frame does not have alpha only if everywhere
                // outside its rect doesn't have alpha. To know whether this is
                // true, we check the start state of the frame -- if it doesn't have
                // alpha, we're safe.
                //
                // First skip over prior RestoreToPrevious frames (since they don't
                // affect the start state of this frame) the same way we do in
                // initFrameBuffer().
                var previousIndex = frameIndex - 1
                var previousInfo = frames.frameInfo(previousIndex)
                while previousIndex != 0
                    && previousInfo.disposalMethod == FrameDisposalMethod.restoreToPrevious
                {
                    previousIndex -= 1
                    previousInfo = frames.frameInfo(previousIndex)
                }

                // Now, if we're at an Unspecified or DoNotDispose frame, then we can
                // say we have no alpha if that frame had no alpha. But since in
                // initFrameBuffer() we already copied that frame's alpha state into
                // the current frame's, we need do nothing at all here.
                //
                // The only remaining case is a RestoreToBackground frame. If it had
                // no alpha, and its rect is contained in the current frame's rect, we
                // know the current frame has no alpha.
                //
                // A frame evicted from the cache has no backing store, so its rect is
                // unknown and this frame's opacity cannot be established from it.
                if previousInfo.hasBackingStore {
                    let previousRect = PixelRect(previousInfo.rect)
                    if previousInfo.disposalMethod == FrameDisposalMethod.restoreToBackground
                        && !previousInfo.hasAlpha && rect.contains(previousRect)
                    {
                        frames.setHasAlpha(frameIndex, false)
                    }
                }
            }
        }

        return true
    }

    /// GIFImageDecoder::gifComplete. Its body runs in runReader when the reader
    /// returns.
    func gifComplete() {
        gifCompleted = true
    }

    /// GIFImageDecoder::initFrameBuffer. `frameRect` is m_reader->frameContext()'s
    /// rect.
    func initFrameBuffer(
        _ frames: inout WebCore.ScalableImageDecoderFrames, _ frameIndex: Int,
        _ frameRect: GIFFrameRect
    ) -> Bool {
        let size = PixelSize(frames.size)

        if frameIndex == 0 {
            // This is the first frame, so we're not relying on any previous data.
            if !frames.initialize(frameIndex, size.imageDecoderSize) {
                return setFailed(&frames)
            }
        } else {
            // The starting state for this frame depends on the previous frame's
            // disposal method.
            //
            // Frames that use the RestoreToPrevious method are effectively no-ops in
            // terms of changing the starting state of a frame compared to the
            // starting state of the previous frame, so skip over them. (If the first
            // frame specifies this method, it will get treated like
            // RestoreToBackground below and reset to a completely empty image.)
            var previousIndex = frameIndex - 1
            var previousInfo = frames.frameInfo(previousIndex)
            while previousIndex != 0
                && previousInfo.disposalMethod == FrameDisposalMethod.restoreToPrevious
            {
                previousIndex -= 1
                previousInfo = frames.frameInfo(previousIndex)
            }
            let previousMethod = previousInfo.disposalMethod

            if !previousInfo.hasBackingStore {
                return setFailed(&frames)
            }

            if previousMethod == FrameDisposalMethod.unspecified
                || previousMethod == FrameDisposalMethod.doNotDispose
            {
                // Preserve the last frame as the starting state for this frame.
                if !frames.initializeFromFrame(frameIndex, previousIndex) {
                    return setFailed(&frames)
                }
            } else {
                // We want to clear the previous frame to transparent, without
                // affecting pixels in the image outside of the frame.
                let previousRect = PixelRect(previousInfo.rect)
                if previousIndex == 0 || previousRect.contains(PixelRect(size: size)) {
                    // Clearing the first frame, or a frame the size of the whole
                    // image, results in a completely empty image.
                    if !frames.initialize(frameIndex, size.imageDecoderSize) {
                        return setFailed(&frames)
                    }
                } else {
                    // Copy the whole previous buffer, then clear just its frame.
                    if !frames.initializeFromFrame(frameIndex, previousIndex) {
                        return setFailed(&frames)
                    }
                    let info = frames.frameInfo(frameIndex)
                    precondition(info.hasBackingStore)
                    let storeSize = PixelSize(info.storeSize)
                    var pixels = frames.pixels(frameIndex)
                    ImageBackingStorePixels.fill(&pixels, size: storeSize, previousRect, with: 0)
                    frames.setHasAlpha(frameIndex, true)
                }
            }
        }

        // A frame offset can exceed the canvas, since the logical screen size is only
        // published for the first frame. A subtracted extent would be negative there.
        frames.setFrameRect(frameIndex, frameRect.intersected(with: size).imageDecoderRect)

        // Update our status to be partially complete.
        frames.setDecodingStatus(frameIndex, FrameStatus.partial)

        // Reset the alpha pixel tracker for this frame.
        currentBufferSawAlpha = false
        return true
    }
}
