/*
 * Copyright (C) 2014-2025 Apple Inc. All rights reserved.
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
#include <WebCore/ShareableResource.h>
#include <WebCore/SharedBuffer.h>
#include <optional>
#include <wtf/CompletionHandler.h>
#include <wtf/Function.h>
#include <wtf/RefCountable.h>
#include <wtf/URL.h>

// The handlers the cache and its storage call when an operation completes, and the boxes C++ passes them to the Swift entry
// points in.

namespace WebKit::NetworkCache {

struct RetrieveInfo;

struct MappedBody {
#if ENABLE(SHAREABLE_RESOURCE)
    RefPtr<WebCore::ShareableResource> shareableResource;
    std::optional<WebCore::ShareableResource::Handle> shareableResourceHandle;
#endif
};

// The retrieve's completion: on a hit the cache parks the entry and passes its token, which the completion's first line
// takes with cache.takeRetrievedEntry(token); 0 is a miss, which it tests first.
using RetrieveCompletionHandler = Function<void(uint64_t token, const RetrieveInfo&)>;
inline void invokeRetrieveCompletionHandler(RetrieveCompletionHandler& handler, uint64_t token, const RetrieveInfo& info) { handler(token, info); }
// C++ callers pass move-only handlers to Swift entries in a reference-counted box (an exposed Swift entry cannot take one
// by value); the entry takes a completion handler out, which is called once. A traversal handler stays in its box and
// Swift calls it through the box (below).
// One function per box: Swift does not import a function template over RefCountable<Handler>&.
using RetrieveHandlerBox = WTF::RefCountable<RetrieveCompletionHandler>;
inline RetrieveCompletionHandler takeRetrieveHandler(RetrieveHandlerBox& box) { return WTF::move(*box); }
using VoidHandlerBox = WTF::RefCountable<CompletionHandler<void()>>;
inline CompletionHandler<void()> takeVoidHandler(VoidHandlerBox& box) { return WTF::move(*box); }

struct TraversalRecord {
    const Storage::Record& record;
    const Storage::RecordInfo& recordInfo;
    std::optional<RecordType> type() const;
    std::optional<URL> url() const;
};
using TraversalHandler = Function<void(const TraversalRecord*)>;
// A traversal calls its handler once per record and then once with none. The handler can run the main run loop, so the
// next record's call can start inside this one, as in the C++ traversal. Swift calls the handler where it lives, in its
// box, so no Swift access to it is open across the call; the last release of the box destroys the handler.
using TraversalHandlerBox = WTF::RefCountable<TraversalHandler>;
inline void invokeTraversalHandler(TraversalHandlerBox& box, const Storage::Record& record, const Storage::RecordInfo& info)
{
    TraversalRecord traversalRecord { record, info };
    (*box)(&traversalRecord);
}
inline void invokeTraversalHandlerAtEnd(TraversalHandlerBox& box) { (*box)(nullptr); }

using MappedBodyHandler = Function<void(MappedBody&&)>;
// A store with no mapped-body handler (Swift makes no empty Function).
inline MappedBodyHandler emptyMappedBodyHandler() { return { }; }
using MappedBodyHandlerBox = WTF::RefCountable<MappedBodyHandler>;
inline MappedBodyHandler takeMappedBodyHandler(MappedBodyHandlerBox& box) { return WTF::move(*box); }
// Maps the stored body into a shareable resource for the handler, if there is one (NetworkCache.cpp).
void invokeMappedBodyHandler(MappedBodyHandler&, const Data& bodyData);

using SharedBufferCompletionHandler = CompletionHandler<void(RefPtr<WebCore::SharedBuffer>&&)>;
inline void invokeSharedBufferCompletionHandler(SharedBufferCompletionHandler&& handler, RefPtr<WebCore::SharedBuffer> buffer) { handler(WTF::move(buffer)); }
using SharedBufferHandlerBox = WTF::RefCountable<SharedBufferCompletionHandler>;
inline SharedBufferCompletionHandler takeSharedBufferHandler(SharedBufferHandlerBox& box) { return WTF::move(*box); }

inline bool invokeStorageRetrieveCompletionHandler(Storage::RetrieveCompletionHandler&& handler, Storage::Record record, const Storage::Timings& timings) { return handler(WTF::move(record), timings); }
inline void invokeStorageMappedBodyHandler(Storage::MappedBodyHandler& handler, const Data& data)
{
    if (handler)
        handler(data);
}
// Called through its box, as the traversal handler above.
using StorageTraverseHandlerBox = WTF::RefCountable<Storage::TraverseHandler>;
inline void invokeStorageTraverseHandler(StorageTraverseHandlerBox& box, const Storage::Record& record, const Storage::RecordInfo& info) { (*box)(&record, info); }
// Invoke with nullptr to indicate this is the last record.
inline void invokeStorageTraverseHandlerAtEnd(StorageTraverseHandlerBox& box) { (*box)(nullptr, { }); }

} // namespace WebKit::NetworkCache
