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

#include "config.h"
#include "NetworkCacheWebsiteData.h"

#include "NetworkCache.h"
#include "WebKit-Swift.h"
#include "WebsiteDataType.h"
#include <WebCore/ClientOrigin.h>
#include <WebCore/RegistrableDomain.h>
#include <WebCore/SecurityOriginData.h>
#include <wtf/CallbackAggregator.h>

// The website data entries over the cache's traversal.

namespace WebKit::NetworkCache {

void fetchData(Cache& cache, bool shouldComputeSize, CompletionHandler<void(Vector<WebsiteData::Entry>&&)>&& completionHandler)
{
    HashMap<WebCore::SecurityOriginData, uint64_t> originsAndSizes;
    cache.traverseRecords(NetworkCache::TraversalHandlerBox::create([shouldComputeSize, completionHandler = WTF::move(completionHandler), originsAndSizes = WTF::move(originsAndSizes)](auto* traversalRecord) mutable {
        if (traversalRecord) {
            auto url = traversalRecord->url();
            if (!url)
                return;

            auto origin = WebCore::SecurityOriginData::fromURLWithoutStrictOpaqueness(*url);
            if (origin.isNull() || origin.isOpaque())
                return;

            auto result = originsAndSizes.add(WTF::move(origin), 0);
            if (shouldComputeSize)
                result.iterator->value += traversalRecord->record.header.size() + traversalRecord->recordInfo.bodySize;
            return;
        }

        auto entries = WTF::map(originsAndSizes, [](auto& originAndSize) {
            return WebsiteData::Entry { originAndSize.key, WebsiteDataType::DiskCache, originAndSize.value };
        });
        completionHandler(WTF::move(entries));
    }).ptr());
}

void fetchOriginAccessTimes(Cache& cache, CompletionHandler<void(HashMap<WebCore::RegistrableDomain, WallTime>&&)>&& completionHandler)
{
    HashMap<WebCore::RegistrableDomain, WallTime> originAccessTimes;
    cache.getStorage().traverse(recordTypeName(RecordType::Resource), OptionSet<Storage::TraverseFlag> { Storage::TraverseFlag::LastAccessedRecordPerPartition }.toRaw(), NetworkCache::StorageTraverseHandlerBox::create([completionHandler = WTF::move(completionHandler), originAccessTimes = WTF::move(originAccessTimes)](const Storage::Record* record, const Storage::RecordInfo& recordInfo) mutable {
        if (!record) {
            completionHandler(WTF::move(originAccessTimes));
            return;
        }

        auto partition = record->key.partition();
        if (partition.isEmpty())
            return;

        auto domain = WebCore::RegistrableDomain::uncheckedCreateFromRegistrableDomainString(partition);
        originAccessTimes.set(WTF::move(domain), recordInfo.lastAccessTime);
    }).ptr());
}

static Vector<Key> allPendingKeys(Cache& cache)
{
    return cache.pendingKeys(OptionSet<RecordType> { RecordType::Resource, RecordType::CompressionDictionary }.toRaw(), false, String());
}

void deleteData(Cache& cache, const Vector<WebCore::SecurityOriginData>& origins, CompletionHandler<void()>&& completionHandler)
{
    HashSet<WebCore::SecurityOriginData> originSet;
    for (auto& origin : borrow(origins))
        originSet.add(origin);

    auto matches = [originSet = WTF::move(originSet)](const URL& url) {
        return originSet.contains(WebCore::SecurityOriginData::fromURLWithoutStrictOpaqueness(url));
    };

    Vector<NetworkCache::Key> keysToDelete;
    for (auto& key : allPendingKeys(cache)) {
        if (matches(URL { key.identifier() }))
            keysToDelete.append(key);
    }

    cache.traverseRecords(NetworkCache::TraversalHandlerBox::create([cache = Cache { cache }, matches = WTF::move(matches), completionHandler = WTF::move(completionHandler), keysToDelete = WTF::move(keysToDelete)](auto* traversalRecord) mutable {
        if (traversalRecord) {
            auto url = traversalRecord->url();
            if (url && matches(*url))
                keysToDelete.append(traversalRecord->record.key);
            return;
        }

        cache.removeKeys(keysToDelete, NetworkCache::VoidHandlerBox::create(WTF::move(completionHandler)).ptr(), WallTime::infinity());
    }).ptr());
}

void deleteDataForRegistrableDomains(Cache& cache, const Vector<WebCore::RegistrableDomain>& domains, CompletionHandler<void(HashSet<WebCore::RegistrableDomain>&&)>&& completionHandler)
{
    HashSet<WebCore::RegistrableDomain> domainSet;
    for (auto& domain : borrow(domains))
        domainSet.add(domain);

    auto matchingDomain = [domainSet = WTF::move(domainSet)](const URL& url) -> std::optional<WebCore::RegistrableDomain> {
        WebCore::RegistrableDomain domain { url };
        if (!domainSet.contains(domain))
            return std::nullopt;
        return domain;
    };

    Vector<NetworkCache::Key> keysToDelete;
    HashSet<WebCore::RegistrableDomain> domainsDeleted;
    for (auto& key : allPendingKeys(cache)) {
        if (auto domain = matchingDomain(URL { key.identifier() })) {
            keysToDelete.append(key);
            domainsDeleted.add(WTF::move(*domain));
        }
    }

    cache.traverseRecords(NetworkCache::TraversalHandlerBox::create([cache = Cache { cache }, matchingDomain = WTF::move(matchingDomain), completionHandler = WTF::move(completionHandler), keysToDelete = WTF::move(keysToDelete), domainsDeleted = WTF::move(domainsDeleted)](auto* traversalRecord) mutable {
        if (traversalRecord) {
            auto url = traversalRecord->url();
            if (!url)
                return;

            if (auto domain = matchingDomain(*url)) {
                keysToDelete.append(traversalRecord->record.key);
                domainsDeleted.add(WTF::move(*domain));
            }
            return;
        }

        cache.removeKeys(keysToDelete, NetworkCache::VoidHandlerBox::create([completionHandler = WTF::move(completionHandler), domainsDeleted = WTF::move(domainsDeleted)] mutable {
            completionHandler(WTF::move(domainsDeleted));
        }).ptr(), WallTime::infinity());
    }).ptr());
}

void deleteRecordsForOrigin(Cache& cache, const WebCore::ClientOrigin& origin, CacheRecordsToDelete recordsToDelete, Ref<WTF::CallbackAggregator>&& clearTasksHandler)
{
    Vector<NetworkCache::Key> cacheKeysToDelete;
    auto topDomain = WebCore::RegistrableDomain::uncheckedCreateFromHost(origin.topOrigin.host());
    String cachePartition = origin.clientOrigin == origin.topOrigin ? emptyString() : (topDomain.isEmpty() ? emptyString() : topDomain.string());
    // A first-party origin has no partition of its own, so its traversal sees every origin's
    // records; only whole-disk-cache removal is allowed to take them all.
    bool shouldClearAllEntriesInPartition = origin.clientOrigin == origin.topOrigin && recordsToDelete == CacheRecordsToDelete::AllTypes;
    auto matches = [shouldClearAllEntriesInPartition, clientOrigin = origin.clientOrigin](const std::optional<URL>& url) {
        return shouldClearAllEntriesInPartition || (url && WebCore::SecurityOriginData::fromURLWithoutStrictOpaqueness(*url) == clientOrigin);
    };
    // A dictionary is indexed when it is registered, before its record has been written, so the
    // traversal below cannot see one that was registered moments ago. Take those now, and remove
    // only what was registered by this point, since the same key is reused when a dictionary is
    // registered again.
    auto deletionTime = WallTime::now();
    for (auto& key : cache.compressionDictionaryKeys(cachePartition)) {
        if (matches(URL { key.identifier() }))
            cacheKeysToDelete.append(key);
    }
    // Likewise, a resource stored moments ago may still be waiting to be written.
    if (recordsToDelete == CacheRecordsToDelete::AllTypes) {
        for (auto& key : cache.pendingKeys(OptionSet<RecordType> { RecordType::Resource }.toRaw(), true, cachePartition)) {
            if (matches(URL { key.identifier() }))
                cacheKeysToDelete.append(key);
        }
    }

    TraversalHandler recordHandler = [cache = Cache { cache }, clearTasksHandler = WTF::move(clearTasksHandler), shouldClearAllEntriesInPartition, matches = WTF::move(matches), cachePartition, deletionTime, cacheKeysToDelete = WTF::move(cacheKeysToDelete)](auto* traversalRecord) mutable {
        if (traversalRecord) {
            ASSERT_UNUSED(cachePartition, equalIgnoringNullity(traversalRecord->record.key.partition(), cachePartition));
            if (shouldClearAllEntriesInPartition || matches(traversalRecord->url()))
                cacheKeysToDelete.append(traversalRecord->record.key);
            return;
        }

        cache.removeKeys(cacheKeysToDelete, NetworkCache::VoidHandlerBox::create([clearTasksHandler] { }).ptr(), deletionTime);
    };

    if (recordsToDelete == CacheRecordsToDelete::CompressionDictionariesOnly)
        cache.traverseCompressionDictionaryRecords(cachePartition, NetworkCache::TraversalHandlerBox::create(WTF::move(recordHandler)).ptr());
    else
        cache.traverseRecordsInPartition(cachePartition, NetworkCache::TraversalHandlerBox::create(WTF::move(recordHandler)).ptr());
}

} // namespace WebKit::NetworkCache
