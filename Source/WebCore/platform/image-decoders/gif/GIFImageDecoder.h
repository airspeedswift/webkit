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

#pragma once

#include "ScalableImageDecoder.h"
#include <wtf/Lock.h>

#include "ImageDecoderSwiftTypes.h"

namespace WebCore {

class GIFImageDecoderState;

// This class decodes the GIF image format.
class GIFImageDecoder final : public ScalableImageDecoder {
public:
    static Ref<ScalableImageDecoder> create(AlphaOption alphaOption, GammaAndColorProfileOption gammaAndColorProfileOption)
    {
        return adoptRef(*new GIFImageDecoder(alphaOption, gammaAndColorProfileOption));
    }

    virtual ~GIFImageDecoder();

    enum GIFQuery { GIFFullQuery, GIFSizeQuery, GIFFrameCountQuery };

    // ScalableImageDecoder
    String filenameExtension() const final { return "gif"_s; }
    void setData(const FragmentedSharedBuffer& data, bool allDataReceived) final;
    size_t decodeIfNeededAndGetFrameCount() const final;
    RepetitionCount repetitionCount() const final;
    ScalableImageDecoderFrame* frameBufferAtIndex(size_t index) final;
    void clearDecodedPixelDataIfNeeded(size_t clearBeforeFrame) final;

private:
    GIFImageDecoder(AlphaOption, GammaAndColorProfileOption);
    void tryDecodeSize(bool allDataReceived) final { decode(0, GIFSizeQuery, allDataReceived); }

    // If the query is GIFFullQuery, decodes the image up to (but not
    // including) |haltAtFrame|. Otherwise, decodes as much as is needed to
    // answer the query, ignoring bitmap data. If decoding fails but there
    // is no more data coming, sets the "decode failure" flag.
    void decode(unsigned haltAtFrame, GIFQuery, bool allDataReceived);

    bool decodeInSwift(ImageDecoderRequest, size_t index, bool allDataReceived);

    mutable RepetitionCount m_repetitionCount { RepetitionCountOnce };
    std::unique_ptr<GIFImageDecoderState> m_swift;
    RefPtr<const SharedBuffer> m_readerData;
    bool m_hasReader { false };
    RepetitionCount m_readerRepetitionCount { 0 };
};

} // namespace WebCore
