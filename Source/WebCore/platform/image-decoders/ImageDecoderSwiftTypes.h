/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

// Declarations for the GIF, BMP and ICO decoders' Swift, which imports this header as
// WebCore_Private.ImageDecoderSwiftTypes, so it includes nothing beyond the standard library and WTF.

#include <cstddef>
#include <cstdint>
#include <span>
#include <wtf/EscapableByteSpan.h>

namespace WebCore {

enum class ImageDecoderRequest : uint8_t { Size, FrameCount, Frame };

struct ImageDecoderSize {
    int32_t width;
    int32_t height;
};

struct ImageDecoderRect {
    int32_t x;
    int32_t y;
    int32_t width;
    int32_t height;
};

// A cached frame: its DecodingStatus and DisposalMethod raw values, its alpha, and its backing store's size and
// frame rect, which are zero when it has no backing store.
struct ImageDecoderCachedFrame {
    uint8_t status;
    uint8_t disposalMethod;
    bool hasAlpha;
    bool hasBackingStore;
    ImageDecoderSize storeSize;
    ImageDecoderRect rect;
};

struct ImageDecoderOptionalPoint {
    bool hasValue;
    int32_t x;
    int32_t y;
};

// readerRepetitionCount is what repetitionCount() takes from the GIF reader: RepetitionCountOnce when it has
// no frames, the loop count when it has seen one, and 0 when there is no reader or no loop count yet.
struct GIFImageDecoderResult {
    bool frameAvailable;
    bool hasReader;
    int32_t repetitionCount;
    int32_t readerRepetitionCount;
};

// The frame cache and size of the GIF, BMP or ICO decoder that calls into Swift, for the duration of the call.
// Only the decoder constructs one, on its stack (ImageDecoderSwiftFrames.h). Statuses and disposal methods are
// the raw values of EncodedDataStatus, DecodingStatus and ScalableImageDecoderFrame::DisposalMethod.
class __attribute__((swift_attr("~Sendable"))) ScalableImageDecoderFrames {
public:
    ScalableImageDecoderFrames(const ScalableImageDecoderFrames&) = delete;
    ScalableImageDecoderFrames& operator=(const ScalableImageDecoderFrames&) = delete;
    [[noreturn]] ScalableImageDecoderFrames(ScalableImageDecoderFrames&&);
    ~ScalableImageDecoderFrames();

    // The decoder's encodedDataStatus() and size(), which setFailed and setSize keep up to date.
    uint8_t encodedDataStatus;
    ImageDecoderSize size;
    bool setFailed();
    bool setSize(ImageDecoderSize);

    size_t frameCount();
    void setFrameCount(size_t);
    ImageDecoderCachedFrame frameInfo(size_t index);
    void setDecodingStatus(size_t index, uint8_t);
    // Sets the status to Complete, the duration and the disposal method.
    void completeFrame(size_t index, uint32_t durationInMilliseconds, uint8_t disposalMethod);
    void setHasAlpha(size_t index, bool);
    void setFrameRect(size_t index, ImageDecoderRect);
    bool initialize(size_t index, ImageDecoderSize);
    bool initializeFromFrame(size_t index, size_t sourceIndex);
    void clear(size_t index);

    // ICOImageDecoder only: its PNG entries, which PNGImageDecoder decodes.
    void setPNGDecoderCount(size_t);
    void clearPNGDecoder(size_t index);
    bool decodePNGEntry(size_t index, uint32_t imageOffset, ImageDecoderSize entrySize);
    // ICOImageDecoder only: the directory entries in ICOImageDecoder::compareEntries order. Swift appends each
    // entry (sides 1 to 256), sorts them, then reads back each one's original index. The entries are cleared when
    // the decode call returns.
    void appendDirectoryEntry(ImageDecoderSize, uint16_t bitCount);
    void sortDirectoryEntries();
    uint32_t sortedDirectoryEntryIndex(size_t);

protected:
    ScalableImageDecoderFrames() = default;
};

// The pixels of frame `index`, which must have a backing store.
std::span<uint32_t> framePixels(ScalableImageDecoderFrames& frames LIFETIME_BOUND, size_t index);

} // namespace WebCore
