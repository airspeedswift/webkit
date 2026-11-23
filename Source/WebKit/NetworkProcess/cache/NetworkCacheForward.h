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

#include <memory>
#include <wtf/Forward.h>

// The names a header needs to hold the cache, an entry or the prefetch cache by pointer without the cache's
// declarations (NetworkCache.h), which NetworkSession.h's includers do not need.

// Swift has the class itself, which an incomplete C++ class of the same name would shadow.
#ifndef __swift__
namespace WebKit {
class NetworkCacheCompressionDictionaryEntry;
class NetworkCacheEntry;
class NetworkCacheStorage;
class NetworkDiskCache;
class NetworkDiskCacheWeakReference;
class PrefetchCache;
}
#endif

namespace WebKit::NetworkCache {

enum class RecordType : uint8_t;
const AtomString& recordTypeName(RecordType);

#ifndef __swift__
using Cache = WebKit::NetworkDiskCache;
using CompressionDictionaryEntry = WebKit::NetworkCacheCompressionDictionaryEntry;
using Entry = WebKit::NetworkCacheEntry;
using PrefetchCache = WebKit::PrefetchCache;
#else
// Swift sees C++ headers that hold these by pointer and never reads the members; it declares them incomplete, since
// its own classes of the same names would conflict.
class Cache;
class CompressionDictionaryEntry;
class Entry;
class PrefetchCache;
#endif

// A retained reference to the Swift cache; released in NetworkCache.cpp.
struct NetworkCacheDeleter {
    void operator()(Cache*) const;
};
using NetworkCachePtr = std::unique_ptr<Cache, NetworkCacheDeleter>;

// The session's prefetch cache (PrefetchCache.swift), held the same way.
struct PrefetchCacheDeleter {
    void operator()(PrefetchCache*) const;
};
using PrefetchCachePtr = std::unique_ptr<PrefetchCache, PrefetchCacheDeleter>;

// Swift and C++ see different declarations of the held classes, so the holders must keep one layout.
static_assert(sizeof(NetworkCachePtr) == sizeof(void*));
static_assert(sizeof(PrefetchCachePtr) == sizeof(void*));

} // namespace WebKit::NetworkCache
