/*
 * Copyright (C) 2014-2026 Apple Inc. All rights reserved.
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
#include "NetworkCacheKey.h"
#include "NetworkCacheRecordFormat.h"
#include <WebCore/Timer.h>
#include <wtf/BloomFilter.h>
#include <wtf/CompletionHandler.h>
#include <wtf/Function.h>
#include <wtf/HashSet.h>
#include <wtf/MonotonicTime.h>
#include <wtf/ObjectIdentifier.h>
#include <wtf/RefCounted.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/Vector.h>
#include <wtf/WallTime.h>
#include <wtf/text/WTFString.h>

// The value types, timer and hash table orders of the Swift storage (NetworkCacheStorage.swift).

namespace WebKit::NetworkCache {

struct Storage {
    enum class Mode { Normal, AvoidRandomness };

    enum class ReadOperationIdentifierType { };
    using ReadOperationIdentifier = ObjectIdentifier<ReadOperationIdentifierType>;
    enum class WriteOperationIdentifierType { };
    using WriteOperationIdentifier = ObjectIdentifier<WriteOperationIdentifierType>;

    struct Record {
        WTF_MAKE_STRUCT_TZONE_ALLOCATED(Record);

        Record() = default;
        Record(const Key& key, WallTime timeStamp, const Data& header, const Data& body, std::optional<SHA1::Digest> bodyHash)
            : key(key)
            , timeStamp(timeStamp)
            , header(header)
            , body(body)
            , bodyHash(bodyHash)
        {
        }
        Record isolatedCopy() const & { return { crossThreadCopy(key), timeStamp, header, body, bodyHash }; }
        Record isolatedCopy() && { return { crossThreadCopy(WTF::move(key)), timeStamp, WTF::move(header), WTF::move(body), WTF::move(bodyHash) }; }
        bool isNull() const { return key.isNull(); }

        Key key;
        WallTime timeStamp;
        Data header;
        Data body;
        std::optional<SHA1::Digest> bodyHash;
    };

    struct Timings {
        WTF_MAKE_STRUCT_TZONE_ALLOCATED(Timings);

        MonotonicTime startTime;
        MonotonicTime dispatchTime;
        MonotonicTime recordIOStartTime;
        MonotonicTime recordIOEndTime;
        MonotonicTime blobIOStartTime;
        MonotonicTime blobIOEndTime;
        MonotonicTime completionTime;
        size_t dispatchCountAtStart { 0 };
        size_t dispatchCountAtDispatch { 0 };
        bool synchronizationInProgressAtDispatch { false };
        bool shrinkInProgressAtDispatch { false };
        bool wasCanceled { false };
    };

    // This may call completion handler synchronously on failure.
    using RetrieveCompletionHandler = CompletionHandler<bool(Record&&, const Timings&)>;
    using MappedBodyHandler = Function<void (const Data& mappedBody)>;

    struct RecordInfo {
        size_t bodySize;
        double worth; // 0-1 where 1 is the most valuable.
        unsigned bodyShareCount;
        String bodyHash;
        WallTime lastAccessTime;
    };
    enum class TraverseFlag : uint8_t {
        ComputeWorth = 1 << 0,
        ShareCount = 1 << 1,
        LastAccessedRecordPerPartition = 1 << 2,
    };
    using TraverseHandler = Function<void (const Record*, const RecordInfo&)>;

    // Incrementing this number will delete all existing cache content for everyone. Do you really need to do it?
    static const unsigned version = 18;
};

// 2^18 bit filter can support up to 26000 entries with false positive rate < 1%.
using ContentsFilter = BloomFilter<18>;
// A heap-allocated filter (32 KB), moved and never copied; null before the first synchronization, when it adds nothing
// and may contain anything. Swift holds this owner because the importer drops std::unique_ptr<ContentsFilter>.
class ContentsFilterPointer {
public:
    ContentsFilterPointer() = default;
    static ContentsFilterPointer create() { return ContentsFilterPointer { makeUnique<ContentsFilter>() }; }

    // SHA1::Digest overloads of BloomFilter are templates, which Swift cannot call.
    void add(const SHA1::Digest& hash)
    {
        if (m_filter)
            m_filter->add(hash);
    }
    bool mayContain(const SHA1::Digest& hash) const { return !m_filter || m_filter->mayContain(hash); }
    void clear()
    {
        if (m_filter)
            m_filter->clear();
    }

private:
    explicit ContentsFilterPointer(std::unique_ptr<ContentsFilter>&& filter)
        : m_filter(WTF::move(filter))
    {
    }
    std::unique_ptr<ContentsFilter> m_filter;
};
using KeyVector = Vector<Key>;

// NetworkCacheRecordFormat.swift writes a 20-byte blob hash.
static_assert(std::tuple_size_v<SHA1::Digest> == 20);

inline bool optionalDigestEquals(const SHA1::Digest& digest, const std::optional<SHA1::Digest>& other) { return digest == other; }

// The identifiers of the storage's operations, from the process's ObjectIdentifier counter.
inline uint64_t generateReadOperationIdentifier() { return Storage::ReadOperationIdentifier::generate().toUInt64(); }
inline uint64_t generateWriteOperationIdentifier() { return Storage::WriteOperationIdentifier::generate().toUInt64(); }

// The active reads, in the order they are canceled in; reference-counted, since Swift cannot hold a HashSet safely.
class ReadOperationOrder : public RefCounted<ReadOperationOrder> {
public:
    // Out of line: inline, two create() functions merge into one unnamed function that the Windows Debug Swift
    // compile cannot emit.
    static Ref<ReadOperationOrder> create();
    void add(uint64_t identifier) { m_identifiers.add(Storage::ReadOperationIdentifier { identifier }); }
    void remove(uint64_t identifier) { m_identifiers.remove(Storage::ReadOperationIdentifier { identifier }); }
    Vector<uint64_t> inOrder() const { return WTF::map(m_identifiers, [](auto identifier) { return identifier.toUInt64(); }); }
private:
    ReadOperationOrder() = default;
    HashSet<Storage::ReadOperationIdentifier> m_identifiers;
};

// A traversal's record directories in a HashMap<String, PartitionEntry>'s iteration order.
class RecordDirectoryOrder : public RefCounted<RecordDirectoryOrder> {
public:
    static Ref<RecordDirectoryOrder> create();
    void add(const String& path) { m_paths.add(path); }
    Vector<String> inOrder() const { return copyToVector(m_paths); }
private:
    RecordDirectoryOrder() = default;
    HashSet<String> m_paths;
};

// The storage's timer. The handler runs once, when the timer fires or, if still set, when the timer is destroyed, since
// a CompletionHandler must be called.
class OneShotTimer : public RefCounted<OneShotTimer> {
public:
    static Ref<OneShotTimer> create() { return adoptRef(*new OneShotTimer); }
    ~OneShotTimer()
    {
        if (m_handler)
            m_handler();
    }
    bool hasHandler() const { return !!m_handler; }
    bool isActive() const { return m_timer.isActive(); }
    void setHandler(CompletionHandler<void()>&& handler) { m_handler = WTF::move(handler); }
    void startOneShot(double delay) { m_timer.startOneShot(Seconds { delay }); }
    void stop() { m_timer.stop(); }

private:
    OneShotTimer()
        : m_timer([this] { fired(); }) { }
    void fired()
    {
        if (auto handler = std::exchange(m_handler, { }))
            handler();
    }
    WebCore::Timer m_timer;
    CompletionHandler<void()> m_handler;
};

#if ENABLE(NETWORK_CACHE_BLOB_STORAGE_MEMORY_CACHE)
constexpr bool networkCacheBlobMemoryCacheEnabled = true;
#else
constexpr bool networkCacheBlobMemoryCacheEnabled = false;
#endif

// The hash WTF's HashMap<Key, ...> uses.
inline unsigned networkCacheKeyHash(const Key& key) { return WTF::NetworkCacheKeyHash::hash(key); }

} // namespace WebKit::NetworkCache
