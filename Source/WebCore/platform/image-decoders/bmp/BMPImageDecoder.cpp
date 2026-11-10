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
#include "BMPImageDecoder.h"

#include "ImageDecoderSwiftFrames.h"
#include "WebCore-Swift.h"

namespace WebCore {

BMPImageDecoder::BMPImageDecoder(AlphaOption alphaOption, GammaAndColorProfileOption gammaAndColorProfileOption)
    : ScalableImageDecoder(alphaOption, gammaAndColorProfileOption)
    , m_swift(makeUniqueWithoutFastMallocCheck<BMPImageDecoderState>(BMPImageDecoderState::init(m_premultiplyAlpha)))
{
}

void BMPImageDecoder::setData(const FragmentedSharedBuffer& data, bool allDataReceived)
{
    if (failed())
        return;

    ScalableImageDecoder::setData(data, allDataReceived);
    Locker locker { m_lock };
    if (m_hasReader)
        m_readerData = m_data;
}

ScalableImageDecoderFrame* BMPImageDecoder::frameBufferAtIndex(size_t index)
{
    assertIsHeld(m_lock);
    if (index)
        return 0;

    if (m_frameBufferCache.isEmpty())
        m_frameBufferCache.grow(1);

    auto* buffer = &m_frameBufferCache.first();
    if (!buffer->isComplete())
        decode(false, isAllDataReceived());
    // The decode can resize m_frameBufferCache.
    buffer = &m_frameBufferCache.first();
    return buffer;
}

BMPImageDecoder::~BMPImageDecoder() = default;

void BMPImageDecoder::decode(bool onlySize, bool allDataReceived)
{
    assertIsHeld(m_lock);
    RefPtr readerData = m_hasReader ? m_readerData : m_data;
    ImageDecoderFramesState frames { *this, m_frameBufferCache };
    m_hasReader = bmpImageDecoderDecode(*m_swift, frames, readerData ? readerData->span() : std::span<const uint8_t> { }, onlySize, allDataReceived);
    m_readerData = m_hasReader ? std::move(readerData) : nullptr;
}

} // namespace WebCore
