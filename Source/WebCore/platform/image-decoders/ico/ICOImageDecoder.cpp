/*
 * Copyright (c) 2008-2009 Google Inc. All rights reserved.
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

#include "config.h"
#include "ICOImageDecoder.h"

#include <algorithm>

#include "ImageDecoderSwiftFrames.h"
#include "WebCore-Swift.h"
#include "PNGImageDecoder.h"
#include <wtf/StdLibExtras.h>

namespace WebCore {

ICOImageDecoder::ICOImageDecoder(AlphaOption alphaOption, GammaAndColorProfileOption gammaAndColorProfileOption)
    : ScalableImageDecoder(alphaOption, gammaAndColorProfileOption)
    , m_swift(makeUniqueWithoutFastMallocCheck<ICOImageDecoderState>(ICOImageDecoderState::init(m_premultiplyAlpha)))
{
}

ICOImageDecoder::~ICOImageDecoder() = default;

void ICOImageDecoder::setData(const FragmentedSharedBuffer& data, bool allDataReceived)
{
    if (failed())
        return;

    ScalableImageDecoder::setData(data, allDataReceived);

    for (size_t i = 0; i < m_pngDecoders.size(); ++i)
        setDataForPNGDecoderAtIndex(i);
}

IntSize ICOImageDecoder::frameSizeAtIndex(size_t index, SubsamplingLevel) const
{
    Locker locker { m_lock };
    auto size = icoImageDecoderFrameSizeAtIndex(*m_swift, index, { this->size().width(), this->size().height() });
    return { size.width, size.height };
}

size_t ICOImageDecoder::decodeIfNeededAndGetFrameCount() const
{
    assertIsHeld(m_lock);
    const_cast<ICOImageDecoder*>(this)->decode(0, true, isAllDataReceived());
    return m_frameBufferCache.size();
}

ScalableImageDecoderFrame* ICOImageDecoder::frameBufferAtIndex(size_t index)
{
    assertIsHeld(m_lock);
    // Ensure |index| is valid.
    if (index >= decodeIfNeededAndGetFrameCount())
        return 0;

    auto* buffer = &m_frameBufferCache[index];
    if (!buffer->isComplete())
        decode(index, false, isAllDataReceived());
    // The decode can resize m_frameBufferCache.
    buffer = &m_frameBufferCache[index];
    return buffer;
}

bool ICOImageDecoder::setFailed()
{
    m_pngDecoders.clear();
    return ScalableImageDecoder::setFailed();
}

std::optional<IntPoint> ICOImageDecoder::hotSpot() const
{
    // When unspecified, the default frame is always frame 0. This is consistent with
    // BitmapImage where currentFrame() starts at 0 and only increases when animation is
    // requested.
    Locker locker { m_lock };
    auto hotSpot = icoImageDecoderHotSpot(*m_swift);
    if (!hotSpot.hasValue)
        return std::nullopt;
    return IntPoint { hotSpot.x, hotSpot.y };
}

// static
bool ICOImageDecoder::compareEntries(const IconDirectoryEntry& a, const IconDirectoryEntry& b)
{
    // Larger icons are better.  After that, higher bit-depth icons are better.
    const int aEntryArea = a.m_size.width() * a.m_size.height();
    const int bEntryArea = b.m_size.width() * b.m_size.height();
    return (aEntryArea == bEntryArea) ? (a.m_bitCount > b.m_bitCount) : (aEntryArea > bEntryArea);
}

void ICOImageDecoder::setDataForPNGDecoderAtIndex(size_t index)
{
    if (!m_pngDecoders[index])
        return;

    auto data = m_data ? m_data->span() : std::span<const uint8_t> { };
    size_t imageOffset = m_pngImageOffsets[index];
    auto pngData = SharedBuffer::create(imageOffset <= data.size() ? data.subspan(imageOffset) : std::span<const uint8_t> { });
    m_pngDecoders[index]->setData(pngData.get(), isAllDataReceived());
}

void ICOImageDecoder::decode(size_t index, bool onlySize, bool allDataReceived)
{
    assertIsHeld(m_lock);
    ImageDecoderFramesState frames { *this, m_frameBufferCache };
    frames.ico = this;
    icoImageDecoderDecode(*m_swift, frames, m_data ? m_data->span() : std::span<const uint8_t> { }, index, onlySize, allDataReceived);
    m_sortedDirEntries.clear();
}

static ICOImageDecoder& icoImageDecoder(ScalableImageDecoderFrames& frames)
{
    auto* decoder = static_cast<ImageDecoderFramesState&>(frames).ico;
    RELEASE_ASSERT(decoder);
    return *decoder;
}

void ScalableImageDecoderFrames::setPNGDecoderCount(size_t count)
{
    auto& decoder = icoImageDecoder(*this);
    decoder.m_pngDecoders.resize(count);
    decoder.m_pngImageOffsets.resize(count);
}

void ScalableImageDecoderFrames::clearPNGDecoder(size_t index)
{
    icoImageDecoder(*this).m_pngDecoders[index] = nullptr;
}

bool ScalableImageDecoderFrames::decodePNGEntry(size_t index, uint32_t imageOffset, ImageDecoderSize entrySize)
{
    auto& decoder = icoImageDecoder(*this);
    if (!decoder.m_pngDecoders[index]) {
        decoder.m_pngDecoders[index] = PNGImageDecoder::create(decoder.m_premultiplyAlpha ? AlphaOption::Premultiplied : AlphaOption::NotPremultiplied, decoder.m_ignoreGammaAndColorProfile ? GammaAndColorProfileOption::Ignored : GammaAndColorProfileOption::Applied);
        decoder.m_pngImageOffsets[index] = imageOffset;
        decoder.setDataForPNGDecoderAtIndex(index);
    }
    Ref pngDecoder = *decoder.m_pngDecoders[index];
    if (pngDecoder->encodedDataStatus() >= EncodedDataStatus::SizeAvailable && pngDecoder->size() != IntSize { entrySize.width, entrySize.height })
        return setFailed();

    auto* frameBuffer = static_cast<PNGImageDecoder&>(pngDecoder.get()).firstFrameBuffer();
    if (!frameBuffer)
        return false;

    static_cast<ImageDecoderFramesState&>(*this).frames[index] = *frameBuffer;
    return !pngDecoder->failed() || setFailed();
}

void ScalableImageDecoderFrames::appendDirectoryEntry(ImageDecoderSize size, uint16_t bitCount)
{
    RELEASE_ASSERT(size.width > 0 && size.width <= 256 && size.height > 0 && size.height <= 256);
    auto& entries = icoImageDecoder(*this).m_sortedDirEntries;
    entries.append({ ICOImageDecoder::IconDirectoryEntry { IntSize { size.width, size.height }, bitCount, IntPoint { }, 0 }, static_cast<uint32_t>(entries.size()) });
}

void ScalableImageDecoderFrames::sortDirectoryEntries()
{
    auto& entries = icoImageDecoder(*this).m_sortedDirEntries;
    std::sort(entries.begin(), entries.end(), [](auto& a, auto& b) {
        return ICOImageDecoder::compareEntries(a.first, b.first);
    });
}

uint32_t ScalableImageDecoderFrames::sortedDirectoryEntryIndex(size_t index)
{
    return icoImageDecoder(*this).m_sortedDirEntries[index].second;
}

}
