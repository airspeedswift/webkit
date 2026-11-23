/*
 * Copyright (C) 2015-2026 Apple Inc. All rights reserved.
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

#include "NetworkCacheData.h"
#include "NetworkCacheForward.h"
#include "NetworkCacheStorage.h"
#include "PrivateRelayed.h"
#include <WebCore/CacheValidation.h>
#include <WebCore/HTTPStatusCodes.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ShareableResource.h>
#include <WebCore/SharedBuffer.h>
#include <memory>
#include <optional>
#include <wtf/Seconds.h>
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

// C++ holds a network cache entry (NetworkCacheEntry.swift) or compression dictionary entry
// (NetworkCacheCompressionDictionaryEntry.swift) by std::unique_ptr of the class in WebKit-Swift.h, which
// only a .cpp in WebKit_SWIFT_INTEROP_SOURCES includes; a header names it through NetworkCacheForward.h. The aliases
// name the template types the entries store, and the helpers are templates so that they compile before WebKit-Swift.h.

namespace WebKit::NetworkCache {

using HeaderPairs = Vector<std::pair<String, String>>;
using OptionalRequest = std::optional<WebCore::ResourceRequest>;
using FragmentedBufferPtr = RefPtr<WebCore::FragmentedSharedBuffer>;
using ShareableResourcePtr = RefPtr<WebCore::ShareableResource>;
using SharedBufferPtr = RefPtr<WebCore::SharedBuffer>;

template<typename EntryType>
std::unique_ptr<EntryType> decodeNetworkCacheEntry(const Storage::Record& record)
{
    auto entry = EntryType::decodeStorageRecord(record);
    if (!entry)
        return nullptr;
    return makeUniqueWithoutFastMallocCheck<EntryType>(entry.get());
}

// An isolated copy of the request without its body: the redirect body is not needed even if it exists.
inline OptionalRequest redirectRequestForEntry(const WebCore::ResourceRequest& redirectRequest)
{
    OptionalRequest result;
    result.emplace();
    result->setAsIsolatedCopy(redirectRequest);
    result->setHTTPBody(nullptr);
    return result;
}

// Makes `buffer` contiguous and returns its bytes.
inline Data makeContiguousData(FragmentedBufferPtr& buffer)
{
    buffer = buffer->makeContiguous();
    return { downcast<WebCore::SharedBuffer>(*buffer).span() };
}

// The shareable resource's memory where there is one, else a copy of the body.
inline FragmentedBufferPtr bufferFromStorageBody(const ShareableResourcePtr& shareableResource, const Data& body)
{
#if ENABLE(SHAREABLE_RESOURCE)
    if (shareableResource) {
        if (auto handle = shareableResource->createHandle()) {
            if (RefPtr buffer = WTF::move(*handle).tryWrapInSharedBuffer())
                return buffer;
        }
    }
#else
    UNUSED_PARAM(shareableResource);
#endif
    return WebCore::SharedBuffer::create(body.span());
}

inline SharedBufferPtr contiguousSharedBuffer(const FragmentedBufferPtr& buffer)
{
    return buffer ? RefPtr { buffer->makeContiguous() } : nullptr;
}

inline Data dataFromSharedBuffer(const SharedBufferPtr& buffer)
{
    if (!buffer)
        return { };
    return { buffer->span() };
}

inline SharedBufferPtr sharedBufferFromData(const Data& body)
{
    return WebCore::SharedBuffer::create(body.span());
}

// A shareable resource over the body's shared memory; null where there is none.
inline ShareableResourcePtr shareableResourceFromBody(const Data& body)
{
#if ENABLE(SHAREABLE_RESOURCE)
    auto sharedMemory = body.tryCreateSharedMemory();
    if (!sharedMemory)
        return nullptr;
    return WebCore::ShareableResource::create(sharedMemory.releaseNonNull(), 0, body.size());
#else
    UNUSED_PARAM(body);
    return nullptr;
#endif
}

#ifndef __swift__
// A C++ caller's unique_ptr to an entry the Swift cache returned (in files that include WebKit-Swift.h).
// A template, so that it compiles before WebKit-Swift.h completes Entry.
template<typename EntryType>
requires std::same_as<EntryType, Entry>
std::unique_ptr<EntryType> entryPointer(EntryType&& entry) { return makeUniqueWithoutFastMallocCheck<EntryType>(WTF::move(entry)); }
#endif

} // namespace WebKit::NetworkCache
