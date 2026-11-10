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

#pragma once

#include "ImageDecoderSwiftTypes.h"
#include "ScalableImageDecoder.h"

namespace WebCore {

class ICOImageDecoderState;

// This class decodes the ICO and CUR image formats.
class ICOImageDecoder final : public ScalableImageDecoder {
public:
    static Ref<ScalableImageDecoder> create(AlphaOption alphaOption, GammaAndColorProfileOption gammaAndColorProfileOption)
    {
        return adoptRef(*new ICOImageDecoder(alphaOption, gammaAndColorProfileOption));
    }

    virtual ~ICOImageDecoder();

    // ScalableImageDecoder
    String filenameExtension() const final { return "ico"_s; }
    void setData(const FragmentedSharedBuffer&, bool allDataReceived) final;
    IntSize frameSizeAtIndex(size_t, SubsamplingLevel) const final;
    size_t decodeIfNeededAndGetFrameCount() const final;
    ScalableImageDecoderFrame* frameBufferAtIndex(size_t) final;
    // CAUTION: setFailed() deletes all readers and decoders. Be careful to
    // avoid accessing deleted memory, especially when calling this from
    // inside BMPImageReader!
    bool setFailed() final;
    std::optional<IntPoint> hotSpot() const final;

private:

    struct IconDirectoryEntry {
        IntSize m_size;
        uint16_t m_bitCount;
        IntPoint m_hotSpot;
        uint32_t m_imageOffset;
    };

    ICOImageDecoder(AlphaOption, GammaAndColorProfileOption);
    void tryDecodeSize(bool allDataReceived) final { decode(0, true, allDataReceived); }

    // Returns true if |a| is a preferable icon entry to |b|.
    // Larger sizes, or greater bitdepths at the same size, are preferable.
    static bool compareEntries(const IconDirectoryEntry& a, const IconDirectoryEntry& b);

    // If the desired PNGImageDecoder exists, gives it the appropriate data.
    void setDataForPNGDecoderAtIndex(size_t);

    // Decodes the entry at |index|. If |onlySize| is true, stops decoding
    // after calculating the image size. If decoding fails but there is no
    // more data coming, sets the "decode failure" flag.
    void decode(size_t index, bool onlySize, bool allDataReceived);

    typedef Vector<RefPtr<ScalableImageDecoder>> PNGDecoders;
    PNGDecoders m_pngDecoders;

    Vector<uint32_t> m_pngImageOffsets;
    Vector<std::pair<IconDirectoryEntry, uint32_t>> m_sortedDirEntries;
    std::unique_ptr<ICOImageDecoderState> m_swift;

    friend class ScalableImageDecoderFrames;
};

} // namespace WebCore
