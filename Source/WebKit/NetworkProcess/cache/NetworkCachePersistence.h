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

#include "NetworkCacheCoders.h"
#include "NetworkCacheData.h"
#include "NetworkCacheKey.h"
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/WebCorePersistentCoders.h>
#include <wtf/SHA1.h>
#include <wtf/Seconds.h>
#include <wtf/URL.h>
#include <wtf/WallTime.h>
#include <wtf/persistence/PersistentCoders.h>
#include <wtf/persistence/PersistentDecoder.h>
#include <wtf/persistence/PersistentEncoder.h>

// One field of a network cache record read or written through WTF::Persistence's coder for its type, so that each
// field feeds its type salt and bytes into the checksum. Swift cannot call the Decoder's >> and the Encoder's <<: they
// take std::optional<T>& and return a reference. A read writes `result` only when it succeeds and returns whether it did.

namespace WebKit::NetworkCache {

template<typename T>
bool networkCacheDecode(WTF::Persistence::Decoder& decoder, T& result)
{
    std::optional<T> value;
    decoder >> value;
    if (!value)
        return false;
    result = WTF::move(*value);
    return true;
}

// A response read into the value returned, so that a decoded entry moves it once more, into the entry, with no
// default response made first and no move assignment. `decoded` says whether the read succeeded.
inline WebCore::ResourceResponse decodeResponse(WTF::Persistence::Decoder& decoder, bool& decoded)
{
    auto value = WTF::Persistence::Coder<WebCore::ResourceResponse>::decodeForPersistence(decoder);
    decoded = !!value;
    return value ? WTF::move(*value) : WebCore::ResourceResponse { };
}

template<typename T>
void networkCacheEncode(WTF::Persistence::Encoder& encoder, const T& value)
{
    encoder << value;
}

template<typename Array>
void networkCacheEncodeFixedLengthData(WTF::Persistence::Encoder& encoder, const Array& data)
{
    encoder.encodeFixedLengthData(std::span { data });
}

template<typename Array>
bool networkCacheDecodeFixedLengthData(WTF::Persistence::Decoder& decoder, Array& data)
{
    return decoder.decodeFixedLengthData(std::span { data });
}

// Data's span constructor imports as unsafe.
inline Data dataFromEncoder(const WTF::Persistence::Encoder& encoder) { return Data(encoder.span()); }

}
