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

#include "config.h"
#include "GIFImageDecoder.h"

#include "ImageDecoderSwiftFrames.h"
#include "WebCore-Swift.h"
#include <limits>
#include <wtf/text/ParsingUtilities.h>

namespace WebCore {

// GIFImageDecoder.swift uses these values.
static_assert(RepetitionCountOnce == 1 && RepetitionCountInfinite == -1);

GIFImageDecoder::GIFImageDecoder(AlphaOption alphaOption, GammaAndColorProfileOption gammaAndColorProfileOption)
    : ScalableImageDecoder(alphaOption, gammaAndColorProfileOption)
    , m_swift(makeUniqueWithoutFastMallocCheck<GIFImageDecoderState>(GIFImageDecoderState::init(m_premultiplyAlpha)))
{
}

GIFImageDecoder::~GIFImageDecoder() = default;

void GIFImageDecoder::setData(const FragmentedSharedBuffer& data, bool allDataReceived)
{
    if (failed())
        return;

    ScalableImageDecoder::setData(data, allDataReceived);
    Locker locker { m_lock };
    if (m_hasReader)
        m_readerData = m_data;
}

size_t GIFImageDecoder::decodeIfNeededAndGetFrameCount() const
{
    assertIsHeld(m_lock);
    const_cast<GIFImageDecoder*>(this)->decode(std::numeric_limits<unsigned>::max(), GIFFrameCountQuery, isAllDataReceived());
    return m_frameBufferCache.size();
}

RepetitionCount GIFImageDecoder::repetitionCount() const
{
    // This value can arrive at any point in the image data stream.  Most GIFs
    // in the wild declare it near the beginning of the file, so it usually is
    // set by the time we've decoded the size, but (depending on the GIF and the
    // packets sent back by the webserver) not always.  If the reader hasn't
    // seen a loop count yet, it will return cLoopCountNotSeen, in which case we
    // should default to looping once (the initial value for
    // |m_repetitionCount|).
    //
    // There are some additional wrinkles here. First, ImageSource::clear()
    // may destroy the reader, making the result from the reader _less_
    // authoritative on future calls if the recreated reader hasn't seen the
    // loop count.  We don't need to special-case this because in this case the
    // new reader will once again return cLoopCountNotSeen, and we won't
    // overwrite the cached correct value.
    //
    // Second, a GIF might never set a loop count at all, in which case we
    // should continue to treat it as a "loop once" animation.  We don't need
    // special code here either, because in this case we'll never change
    // |m_repetitionCount| from its default value.
    //
    // Third, we use the same GIFImageReader for counting frames and we might
    // see the loop count and then encounter a decoding error which happens
    // later in the stream. It is also possible that no frames are in the
    // stream. In these cases we should just loop once.
    if (failed())
        m_repetitionCount = RepetitionCountOnce;
    else if (m_readerRepetitionCount)
        m_repetitionCount = m_readerRepetitionCount;
    return m_repetitionCount;
}

ScalableImageDecoderFrame* GIFImageDecoder::frameBufferAtIndex(size_t index)
{
    assertIsHeld(m_lock);
    if (!decodeInSwift(ImageDecoderRequest::Frame, index, isAllDataReceived()))
        return nullptr;
    return &m_frameBufferCache[index];
}

void GIFImageDecoder::clearDecodedPixelDataIfNeeded(size_t clearBeforeFrame)
{
    assertIsHeld(m_lock);
    ImageDecoderFramesState frames { *this, m_frameBufferCache };
    gifImageDecoderClearFrameBufferCache(*m_swift, frames, clearBeforeFrame);
}

void GIFImageDecoder::decode(unsigned haltAtFrame, GIFQuery query, bool allDataReceived)
{
    assertIsHeld(m_lock);
    decodeInSwift(query == GIFSizeQuery ? ImageDecoderRequest::Size : ImageDecoderRequest::FrameCount, haltAtFrame, allDataReceived);
}

bool GIFImageDecoder::decodeInSwift(ImageDecoderRequest request, size_t index, bool allDataReceived)
{
    assertIsHeld(m_lock);
    RefPtr readerData = m_hasReader ? m_readerData : m_data;
    ImageDecoderFramesState frames { *this, m_frameBufferCache };
    auto result = gifImageDecoderDecode(*m_swift, frames, readerData ? readerData->span() : std::span<const uint8_t> { }, request, index, allDataReceived, m_repetitionCount);
    m_hasReader = result.hasReader;
    m_readerData = m_hasReader ? std::move(readerData) : nullptr;
    m_repetitionCount = result.repetitionCount;
    m_readerRepetitionCount = result.readerRepetitionCount;
    return result.frameAvailable;
}

} // namespace WebCore
