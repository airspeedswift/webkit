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

#include "config.h"
#include "NetworkCacheTestSupport.h"

#include "NetworkCache.h"
#include "NetworkCacheBlobStorage.h"
#include "NetworkCacheCoders.h"
#include "NetworkCacheCompressionDictionaryEntry.h"
#include "NetworkCacheEntry.h"
#include "NetworkCacheKey.h"
#include "NetworkCacheSubresourcesEntry.h"
#include "NetworkProcess.h"
#include "NetworkSession.h"
#include "PrefetchCache.h"
#include "WebsiteDataStoreParameters.h"
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/SharedBuffer.h>
#include <pal/SessionID.h>
#include <wtf/FileSystem.h>
#include <wtf/HashMap.h>
#include <wtf/RunLoop.h>
#include <wtf/RuntimeApplicationChecks.h>
#include <wtf/persistence/PersistentDecoder.h>
#include <wtf/persistence/PersistentEncoder.h>
#include <wtf/Threading.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringToIntegerConversion.h>

// The facade calls the cache's own entry points and nothing else: Cache::open, retrieve, store, storeRedirect, update, remove,
// traverseRecords, clear; Key's constructor and stringToHash; Entry::encodeAsStorageRecord and decodeStorageRecord;
// SubresourcesEntry's encode and decode; BlobStorage::add and get. It names no implementation of them: both arms of the
// netcache island link the same file. It runs on the main thread, awaiting each asynchronous operation by spinning the
// main RunLoop; it is a test aid, never called by the product.

namespace WebKit {

// The one access the facade needs to production state: the network process's cache model, which sizes the cache (the default,
// DocumentViewer, gives capacity 0 and a cache that stores nothing); the product sets it when the network process initialises.
struct NetworkCacheTestSupportAccess {
    static void setCacheModel(NetworkProcess& process, CacheModel model) { process.setCacheModel(model); }
};

}

// The access the facade needs to the cache's storage and its record coding (friend of Cache and Storage).
namespace WebKit::NetworkCache {

struct TestSupportAccess {
    static Storage& storage(Cache& cache) { return cache.m_storage.get(); }
    static Data encodeRecord(Storage& storage, const Storage::Record& record, std::optional<BlobStorage::Blob>&& blob) { return storage.encodeRecord(record, WTF::move(blob)); }
    static Storage::Record readRecord(Storage& storage, const Data& data) { return storage.readRecord(data); }
    static bool isIdle(Storage& storage) { return storage.m_pendingWriteOperations.isEmpty() && storage.m_activeWriteOperations.isEmpty() && !storage.m_synchronizationInProgress && !storage.m_shrinkInProgress; }
};

}

namespace WebKit::NetworkCache::NCTSSupport {

using TestSupportCacheMap = HashMap<uint64_t, RefPtr<Cache>>;

static TestSupportCacheMap& caches()
{
    static NeverDestroyed<TestSupportCacheMap> map;
    return map.get();
}

static uint64_t nextHandle { 1 };

static RefPtr<Cache> cacheForHandle(uint64_t handle)
{
    if (!RunLoop::isMain())
        return nullptr;
    return caches().get(handle);
}

static void spinUntil(const bool& done)
{
    while (!done)
        RunLoop::cycle();
}

static String stringFromUTF8(const char* s)
{
    return s ? String::fromUTF8(unsafeSpan(s)) : String();
}

static Vector<std::pair<String, String>> parseHeaders(const char* headers)
{
    Vector<std::pair<String, String>> result;
    if (!headers)
        return result;
    for (auto line : StringView::fromLatin1(headers).split('\n')) {
        auto colon = line.find(':');
        if (colon == notFound)
            continue;
        result.append({ line.left(colon).toString(), line.substring(colon + 1).trim(isASCIIWhitespace<char16_t>).toString() });
    }
    return result;
}

static WebCore::ResourceRequest makeRequest(const NCTSRequest& spec)
{
    WebCore::ResourceRequest request { URL { stringFromUTF8(spec.url) } };
    if (spec.method)
        request.setHTTPMethod(stringFromUTF8(spec.method));
    for (auto& [name, value] : parseHeaders(spec.headers))
        request.setHTTPHeaderField(name, value);
    if (spec.firstPartyURL)
        request.setFirstPartyForCookies(URL { stringFromUTF8(spec.firstPartyURL) });
    request.setCachePolicy(static_cast<WebCore::ResourceRequestCachePolicy>(spec.cachePolicy));
    if (spec.priority >= 0)
        request.setPriority(static_cast<WebCore::ResourceLoadPriority>(spec.priority));
    request.setShouldBlockThirdPartyStorage(!!spec.blockThirdPartyStorage);
    request.setAllowCookies(!!spec.allowCookies);
    return request;
}

static WebCore::ResourceResponse makeResponse(const NCTSResponse& spec, long long expectedLength)
{
    WebCore::ResourceResponse response { URL { stringFromUTF8(spec.url) }, stringFromUTF8(spec.mimeType), expectedLength, String() };
    response.setHTTPStatusCode(spec.status);
    for (auto& [name, value] : parseHeaders(spec.headers))
        response.setHTTPHeaderField(name, value);
    return response;
}

static RefPtr<WebCore::FragmentedSharedBuffer> makeBuffer(const uint8_t* body, size_t length)
{
    return WebCore::SharedBuffer::create(std::span { body, length });
}

static Salt makeSalt(const uint8_t* salt)
{
    Salt result;
    memcpy(result.data(), salt, result.size());
    return result;
}

static const uint8_t* testSalt()
{
    static const uint8_t salt[8] = { 0, 0, 0, 0, 0, 0, 0, 0 };
    return salt;
}

static Key makeKey(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt)
{
    return { stringFromUTF8(partition), stringFromUTF8(type), stringFromUTF8(range), stringFromUTF8(identifier), makeSalt(salt) };
}

static const char* rawChars(const CStringBase& string)
{
    return string.span().data();
}

static size_t copyOut(const CStringBase& source, char* destination, size_t capacity)
{
    if (auto count = std::min(capacity, source.length()); count && destination)
        memcpy(destination, rawChars(source), count);
    return source.length();
}

// A byte range a caller gave: a null pointer is a range of length 0 only.
static bool validRange(const void* pointer, size_t length)
{
    return pointer || !length;
}

// A time printed as whole milliseconds: NaN prints 0 and out-of-range values (infinities included) clamp to the long long range, so the
// conversion is defined for every double a caller can make a time of (a bare static_cast of those is undefined behaviour).
static long long millisecondsOut(WallTime time)
{
    double milliseconds = time.secondsSinceEpoch().milliseconds();
    if (std::isnan(milliseconds))
        return 0;
    if (milliseconds >= 9223372036854775808.0)
        return std::numeric_limits<long long>::max();
    if (milliseconds <= -9223372036854775808.0)
        return std::numeric_limits<long long>::min();
    return static_cast<long long>(milliseconds);
}

static String hexString(std::span<const uint8_t> bytes)
{
    static constexpr char digits[] = "0123456789abcdef";
    StringBuilder builder;
    for (auto byte : bytes) {
        builder.append(digits[byte >> 4]);
        builder.append(digits[byte & 15]);
    }
    return builder.toString();
}

static size_t textOut(const String& string, char* text, size_t capacity)
{
    return copyOut(string.utf8(), text, capacity);
}

static String describeKey(const Key& key)
{
    return makeString("partition="_s, key.partition(), "\ntype="_s, key.type(), "\nrange="_s, key.range(), "\nidentifier="_s, key.identifier(), "\nhash="_s, key.hashAsString(), "\npartitionHash="_s, key.partitionHashAsString(), "\nisNull="_s, key.isNull() ? 1 : 0, "\nwtfHash="_s, WTF::NetworkCacheKeyHash::hash(key), '\n');
}

static PrefetchCache& prefetchCache()
{
    static NeverDestroyed<PrefetchCache> cache;
    return cache.get();
}

template<typename T> static long long coderRoundTrip(std::span<const uint8_t> input, uint8_t* out, size_t capacity)
{
    WTF::Persistence::Decoder decoder(input);
    std::optional<T> value;
    decoder >> value;
    if (!value)
        return -1;
    if (decoder.currentOffset() != input.size())
        return -2;
    WTF::Persistence::Encoder encoder;
    encoder << *value;
    auto encoded = encoder.span();
    if (encoded.size() <= capacity && !encoded.empty() && out)
        memcpy(out, encoded.data(), encoded.size());
    return encoded.size();
}

static String describeEntry(const Entry& entry)
{
    StringBuilder builder;
    auto& response = entry.response();
    builder.append("status="_s, response.httpStatusCode(), "\nurl="_s, response.url().string(), "\nmime="_s, response.mimeType(), "\ntimestampMs="_s, millisecondsOut(entry.timeStamp()), "\nneedsValidation="_s, entry.needsValidation() ? 1 : 0, "\nprivateRelayed="_s, static_cast<int>(entry.privateRelayed()), "\nredirect="_s);
    if (entry.redirectRequest())
        builder.append(entry.redirectRequest()->url().string());
    builder.append("\nkeyHash="_s, entry.key().hashAsString(), "\nvary:\n"_s);
    for (auto& [name, value] : entry.varyingRequestHeaders())
        builder.append(name, ": "_s, value, '\n');
    builder.append("headers:\n"_s);
    for (auto& header : response.httpHeaderFields())
        builder.append(header.key, ": "_s, header.value, '\n');
    return builder.toString();
}

static void describeAndCopy(const Entry& entry, char* text, size_t textCapacity, size_t* textLength, uint8_t* body, size_t bodyCapacity, size_t* bodyLength)
{
    *textLength = copyOut(describeEntry(entry).utf8(), text, textCapacity);
    auto* buffer = entry.buffer();
    size_t length = buffer ? buffer->size() : 0;
    *bodyLength = length;
    if (buffer && body)
        buffer->copyTo(std::span { body, std::min(length, bodyCapacity) });
}

} // namespace WebKit::NetworkCache::NCTSSupport

using namespace WebKit;
using namespace WebKit::NetworkCache;
using namespace WebKit::NetworkCache::NCTSSupport;

extern "C" {

int NCTS_InstallSession(uint64_t sessionID, int withNetworkSession)
{
    if (!RunLoop::isMain())
        return 0;
    auto id = PAL::SessionID { sessionID };
    if (!id.isValid())
        return 0;
    // NetworkProcess::singleton() (its constructor's message receivers) asserts it runs in a Network process: the host is that process's stand-in, in Release and Debug alike.
    WTF::setAuxiliaryProcessType(WTF::AuxiliaryProcessType::Network);
    NetworkCacheTestSupportAccess::setCacheModel(NetworkProcess::singleton(), CacheModel::PrimaryWebBrowser);
    WebsiteDataStoreParameters parameters;
    parameters.networkSessionParameters.sessionID = id;
#if ENABLE(WEB_PUSH_NOTIFICATIONS)
    // NetworkSession::create reads the parent process connection, which a host process does not have.
    if (withNetworkSession)
        return 0;
#endif
    if (withNetworkSession)
        NetworkProcess::singleton().addWebsiteDataStore(WTF::move(parameters));
    else
        NetworkProcess::singleton().addStorageSession(id, parameters);
    return 1;
}

uint64_t NCTS_CacheOpen(const char* path, unsigned options, uint64_t sessionID)
{
    if (!RunLoop::isMain() || !path)
        return 0;
    auto id = PAL::SessionID { sessionID };
    if (!id.isValid())
        return 0;
    OptionSet<CacheOption> cacheOptions;
    if (options & 1)
        cacheOptions.add(CacheOption::TestingMode);
    // RegisterNotify registers a notification handler that holds the cache's raw pointer beyond its life (a use after free once the cache is closed).
    if (options & 2)
        return 0;
    if (options & 4)
        cacheOptions.add(CacheOption::SpeculativeRevalidation);
    RefPtr cache = Cache::open(stringFromUTF8(path), cacheOptions, id);
    if (!cache)
        return 0;
    auto handle = nextHandle++;
    caches().add(handle, WTF::move(cache));
    return handle;
}

void NCTS_CacheClose(uint64_t handle)
{
    if (RunLoop::isMain())
        caches().remove(handle);
}

int NCTS_CacheStore(uint64_t handle, const NCTSRequest* requestSpec, const NCTSResponse* responseSpec, const uint8_t* body, size_t bodyLength)
{
    RefPtr cache = cacheForHandle(handle);
    if (!cache || !requestSpec || !responseSpec || !body)
        return 0;
    // With capacity 0 the storage drops the write.
    if (!cache->capacity())
        return -1;
    // The write is not awaited: the storage calls the completion handler only for a body stored as a blob, and answers
    // retrieves from its pending and active writes, so a retrieve after the store sees it. NCTS_CacheFlush waits for dispatch.
    return !!cache->store(makeRequest(*requestSpec), makeResponse(*responseSpec, bodyLength), PrivateRelayed::No, makeBuffer(body, bodyLength));
}

int NCTS_CacheStoreRedirect(uint64_t handle, const NCTSRequest* requestSpec, const NCTSResponse* responseSpec, const NCTSRequest* redirectSpec)
{
    RefPtr cache = cacheForHandle(handle);
    if (!cache || !requestSpec || !responseSpec || !redirectSpec)
        return 0;
    return !!cache->storeRedirect(makeRequest(*requestSpec), makeResponse(*responseSpec, 0), makeRequest(*redirectSpec), std::nullopt);
}

// A retrieve whose use decision reads the NetworkSession (every policy but the two that allow expired entries) needs the session installed.
static bool canRetrieve(const WebCore::ResourceRequest& request, PAL::SessionID sessionID)
{
    if (!request.url().protocolIsInHTTPFamily())
        return false;
    if (request.cachePolicy() == WebCore::ResourceRequestCachePolicy::DoNotUseAnyCache)
        return false;
    auto policy = request.cachePolicy();
    bool allowsExpired = policy == WebCore::ResourceRequestCachePolicy::ReturnCacheDataElseLoad || policy == WebCore::ResourceRequestCachePolicy::ReturnCacheDataDontLoad;
    return allowsExpired || NetworkProcess::singleton().networkSession(sessionID);
}

int NCTS_CacheRetrieve(uint64_t handle, const NCTSRequest* requestSpec, NCTSRetrieveResult* result, char* text, size_t textCapacity, size_t* textLength, uint8_t* body, size_t bodyCapacity)
{
    RefPtr cache = cacheForHandle(handle);
    if (!cache || !requestSpec || !result || !textLength || !requestSpec->url)
        return -1;
    auto request = makeRequest(*requestSpec);
    if (!canRetrieve(request, cache->sessionID()))
        return -1;
    *result = { 0, -1, -1, -1, 0, 0 };
    *textLength = 0;
    bool done = false;
    cache->retrieve(request, std::nullopt, std::nullopt, false, { }, [&](std::unique_ptr<Entry> entry, const Cache::RetrieveInfo& info) {
        result->retrieveDecision = info.retrieveDecision ? static_cast<int>(*info.retrieveDecision) : -1;
        result->speculativeLoadDecision = info.speculativeLoadDecision ? static_cast<int>(*info.speculativeLoadDecision) : -1;
        result->useDecision = info.useDecision ? static_cast<int>(*info.useDecision) : -1;
        if (entry) {
            result->found = 1;
            result->needsValidation = entry->needsValidation();
            describeAndCopy(*entry, text, textCapacity, textLength, body, bodyCapacity, &result->bodyLength);
        }
        done = true;
    });
    spinUntil(done);
    return 0;
}

int NCTS_CacheUpdate(uint64_t handle, const NCTSRequest* requestSpec, const NCTSResponse* responseSpec)
{
    RefPtr cache = cacheForHandle(handle);
    if (!cache || !requestSpec || !responseSpec || !requestSpec->url)
        return 0;
    auto request = makeRequest(*requestSpec);
    request.setCachePolicy(WebCore::ResourceRequestCachePolicy::ReturnCacheDataElseLoad);
    std::unique_ptr<Entry> existing;
    bool done = false;
    cache->retrieve(request, std::nullopt, std::nullopt, false, { }, [&](std::unique_ptr<Entry> entry, const Cache::RetrieveInfo&) {
        existing = WTF::move(entry);
        done = true;
    });
    spinUntil(done);
    if (!existing)
        return 0;
    return !!cache->update(request, *existing, makeResponse(*responseSpec, 0), PrivateRelayed::No);
}

void NCTS_CacheFlush(uint64_t handle)
{
    RefPtr cache = cacheForHandle(handle);
    if (!cache)
        return;
    // Until no write is pending (each pending write becomes active, on the IO queue). The production API has no
    // completion for a write in flight; callers needing the files on disk poll NCTS_CacheTraverse.
    while (!cache->pendingKeys({ RecordType::Resource, RecordType::CompressionDictionary }).isEmpty())
        RunLoop::cycle();
}

void NCTS_CacheRemove(uint64_t handle, const NCTSRequest* requestSpec)
{
    if (RefPtr cache = cacheForHandle(handle); cache && requestSpec && requestSpec->url)
        cache->remove(makeRequest(*requestSpec));
}

size_t NCTS_CacheTraverse(uint64_t handle, NCTSTraverseCallback callback, void* context)
{
    RefPtr cache = cacheForHandle(handle);
    if (!cache || !callback)
        return 0;
    size_t count = 0;
    bool done = false;
    cache->traverseRecords([&](const Cache::TraversalRecord* traversal) {
        if (!traversal) {
            done = true;
            return;
        }
        auto& record = traversal->record;
        auto url = traversal->url();
        ++count;
        auto urlString = url ? url->string().utf8() : UTF8CString { };
        callback(context, url ? rawChars(urlString) : "", record.key.hash().data(), record.header.size(), record.body.size());
    });
    spinUntil(done);
    return count;
}

void NCTS_CacheClear(uint64_t handle)
{
    RefPtr cache = cacheForHandle(handle);
    if (!cache)
        return;
    bool done = false;
    cache->clear(-WallTime::infinity(), [&done] {
        done = true;
    });
    spinUntil(done);
}

int NCTS_StoreDecision(const NCTSRequest* requestSpec, const NCTSResponse* responseSpec, size_t bodySize)
{
    if (!requestSpec || !responseSpec || !requestSpec->url || !responseSpec->url)
        return -1;
    return static_cast<int>(makeStoreDecision(makeRequest(*requestSpec), makeResponse(*responseSpec, bodySize), bodySize));
}

int NCTS_RetrieveDecision(const NCTSRequest* requestSpec)
{
    if (!requestSpec || !requestSpec->url)
        return -1;
    auto request = makeRequest(*requestSpec);
    // The decision asserts the policy is not DoNotUseAnyCache (Cache::retrieve is never called with it).
    if (request.cachePolicy() == WebCore::ResourceRequestCachePolicy::DoNotUseAnyCache)
        return -1;
    return static_cast<int>(makeRetrieveDecision(request));
}

int NCTS_UseDecision(uint64_t sessionID, const NCTSRequest* requestSpec, const NCTSResponse* responseSpec, const char* varyingHeaders, double timestampMs, double nowMs, int hasRedirect)
{
    if (!RunLoop::isMain() || !requestSpec || !responseSpec || !requestSpec->url || !responseSpec->url)
        return -1;
    if (!std::isfinite(timestampMs) || !std::isfinite(nowMs))
        return -1;
    auto id = PAL::SessionID { sessionID };
    if (!id.isValid())
        return -1;
    auto request = makeRequest(*requestSpec);
    if (!request.url().protocolIsInHTTPFamily() || request.cachePolicy() == WebCore::ResourceRequestCachePolicy::DoNotUseAnyCache)
        return -1;
    // makeUseDecision reads the storage session (vary check) and, unless the policy allows expired entries, the network session.
    auto policy = request.cachePolicy();
    bool allowsExpired = policy == WebCore::ResourceRequestCachePolicy::ReturnCacheDataElseLoad || policy == WebCore::ResourceRequestCachePolicy::ReturnCacheDataDontLoad;
    if (!NetworkProcess::singleton().storageSession(id) || (!allowsExpired && !NetworkProcess::singleton().networkSession(id)))
        return -1;
    auto response = makeResponse(*responseSpec, 0);
    auto key = makeKey("", "Resource", "", rawChars(response.url().string().utf8()), testSalt());
    auto varying = parseHeaders(varyingHeaders);
    // The entry goes through its record, so its timestamp is the one given, moved so that the age the decision reads
    // (the wall clock at the call minus the timestamp) is nowMs - timestampMs; nowMs 0 is the real clock.
    std::unique_ptr<Entry> built;
    if (hasRedirect)
        built = makeUnique<Entry>(key, response, request, varying);
    else
        built = makeUnique<Entry>(key, response, PrivateRelayed::No, makeBuffer(nullptr, 0), varying);
    auto record = built->encodeAsStorageRecord();
    auto ageSeconds = (nowMs - timestampMs) / 1000;
    if (!std::isfinite(ageSeconds))
        return -1;
    record.timeStamp = nowMs ? WallTime::now() - Seconds { ageSeconds } : WallTime::fromRawSeconds(timestampMs / 1000);
    auto entry = Entry::decodeStorageRecord(record);
    if (!entry)
        return -1;
    return static_cast<int>(makeUseDecision(id, *entry, request));
}

size_t NCTS_KeyHash(const char16_t* partition, size_t partitionLength, const char16_t* type, size_t typeLength, const char16_t* range, size_t rangeLength, const char16_t* identifier, size_t identifierLength, const uint8_t* salt, int includesCredentials, uint8_t* hash, uint8_t* partitionHash, char* hashString)
{
    if (!salt || !hash || !partitionHash || !hashString || !validRange(partition, partitionLength) || !validRange(type, typeLength) || !validRange(range, rangeLength) || !validRange(identifier, identifierLength))
        return 0;
    Key key { String(std::span { partition, partitionLength }), String(std::span { type, typeLength }), String(std::span { range, rangeLength }), String(std::span { identifier, identifierLength }), makeSalt(salt), includesCredentials ? Key::IncludesCredentials::Yes : Key::IncludesCredentials::No };
    memcpy(hash, key.hash().data(), key.hash().size());
    memcpy(partitionHash, key.partitionHash().data(), key.partitionHash().size());
    return copyOut(key.hashAsString().utf8(), hashString, 40);
}

int NCTS_KeyStringToHash(const char16_t* string, size_t length, uint8_t* hash)
{
    if (!hash || !validRange(string, length))
        return 0;
    Key::HashType result;
    if (!Key::stringToHash(String(std::span { string, length }), result))
        return 0;
    memcpy(hash, result.data(), result.size());
    return 1;
}

long long NCTS_EntryEncode(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, const NCTSResponse* responseSpec, const char* varyingHeaders, const uint8_t* body, size_t bodyLength, uint8_t* out, size_t outCapacity, size_t* headerLength, uint8_t* bodyHash, int* hasBodyHash)
{
    if (!salt || !responseSpec || !body || !headerLength || !bodyHash || !hasBodyHash || !validRange(out, outCapacity))
        return -1;
    Entry entry { makeKey(partition, type, range, identifier, salt), makeResponse(*responseSpec, bodyLength), PrivateRelayed::No, makeBuffer(body, bodyLength), parseHeaders(varyingHeaders) };
    auto record = entry.encodeAsStorageRecord();
    *headerLength = record.header.size();
    *hasBodyHash = !!record.bodyHash;
    if (record.bodyHash)
        memcpy(bodyHash, record.bodyHash->data(), record.bodyHash->size());
    size_t total = record.header.size() + record.body.size();
    if (total <= outCapacity) {
        memcpy(out, record.header.span().data(), record.header.size());
        memcpy(out + record.header.size(), record.body.span().data(), record.body.size());
    }
    return total;
}

int NCTS_EntryDecode(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, double timestampMs, const uint8_t* header, size_t headerLength, const uint8_t* body, size_t bodyLength, const uint8_t* bodyHash, char* text, size_t textCapacity, size_t* textLength, uint8_t* bodyOut, size_t bodyOutCapacity, size_t* bodyOutLength)
{
    if (!salt || !textLength || !bodyOutLength || !validRange(header, headerLength) || !validRange(body, bodyLength))
        return -1;
    std::optional<SHA1::Digest> digest;
    if (bodyHash) {
        SHA1::Digest value;
        memcpy(value.data(), bodyHash, value.size());
        digest = value;
    }
    Storage::Record record { makeKey(partition, type, range, identifier, salt), WallTime::fromRawSeconds(timestampMs / 1000), Data { std::span { header, headerLength } }, Data { std::span { body, bodyLength } }, digest };
    auto entry = Entry::decodeStorageRecord(record);
    if (!entry)
        return -1;
    describeAndCopy(*entry, text, textCapacity, textLength, bodyOut, bodyOutCapacity, bodyOutLength);
    return 0;
}

long long NCTS_SubresourcesDecode(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, double timestampMs, const uint8_t* header, size_t headerLength, char* text, size_t textCapacity)
{
    if (!salt || !validRange(header, headerLength))
        return -1;
    Storage::Record record { makeKey(partition, type, range, identifier, salt), WallTime::fromRawSeconds(timestampMs / 1000), Data { std::span { header, headerLength } }, Data { }, std::nullopt };
    auto entry = SubresourcesEntry::decodeStorageRecord(record);
    if (!entry)
        return -1;
    StringBuilder builder;
    builder.append("count="_s, entry->subresources().size(), '\n');
    for (auto& info : entry->subresources()) {
        builder.append(info.key().hashAsString(), " transient="_s, info.isTransient() ? 1 : 0, " lastSeenMs="_s, millisecondsOut(info.lastSeen()), " firstSeenMs="_s, millisecondsOut(info.firstSeen()), '\n');
        if (!info.isTransient()) {
            builder.append(" firstParty="_s, info.firstPartyForCookies().string(), " sameSite="_s, info.isSameSite() ? 1 : 0, " appInitiated="_s, info.isAppInitiated() ? 1 : 0, " priority="_s, static_cast<int>(info.priority()), '\n');
            for (auto& header : info.requestHeaders())
                builder.append("  "_s, header.key, ": "_s, header.value, '\n');
        }
    }
    return copyOut(builder.toString().utf8(), text, textCapacity);
}

long long NCTS_SubresourcesEncode(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, const char* urls, uint8_t* out, size_t outCapacity, size_t* headerLength)
{
    if (!salt || !urls || !headerLength || !validRange(out, outCapacity))
        return -1;
    Vector<std::unique_ptr<SubresourceLoad>> loads;
    for (auto line : StringView::fromLatin1(urls).split('\n')) {
        auto request = WebCore::ResourceRequest { URL { line.toString() } };
        loads.append(makeUnique<SubresourceLoad>(request, makeKey("", "Resource", "", rawChars(line.toString().utf8()), salt)));
    }
    SubresourcesEntry entry { makeKey(partition, type, range, identifier, salt), loads };
    auto record = entry.encodeAsStorageRecord();
    *headerLength = record.header.size();
    size_t total = record.header.size() + record.body.size();
    if (total <= outCapacity) {
        memcpy(out, record.header.span().data(), record.header.size());
        memcpy(out + record.header.size(), record.body.span().data(), record.body.size());
    }
    return total;
}

int NCTS_CacheSync(uint64_t handle)
{
    RefPtr cache = cacheForHandle(handle);
    if (!cache)
        return -1;
    auto& storage = TestSupportAccess::storage(*cache);
    auto deadline = MonotonicTime::now() + 60_s;
    while (!TestSupportAccess::isIdle(storage)) {
        if (MonotonicTime::now() > deadline)
            return -1;
        RunLoop::cycle();
    }
    return 0;
}

long long NCTS_CacheRecordsPath(uint64_t handle, char* out, size_t capacity)
{
    RefPtr cache = cacheForHandle(handle);
    if (!cache)
        return -1;
    return textOut(cache->recordsPathIsolatedCopy(), out, capacity);
}

size_t NCTS_CacheTraverseEx(uint64_t handle, unsigned flags, NCTSTraverseExCallback callback, void* context)
{
    RefPtr cache = cacheForHandle(handle);
    if (!cache || !callback)
        return 0;
    OptionSet<Storage::TraverseFlag> traverseFlags;
    if (flags & 1)
        traverseFlags.add(Storage::TraverseFlag::ComputeWorth);
    if (flags & 2)
        traverseFlags.add(Storage::TraverseFlag::ShareCount);
    size_t count = 0;
    bool done = false;
    TestSupportAccess::storage(*cache).traverse(emptyString(), traverseFlags, [&](const Storage::Record* record, const Storage::RecordInfo& info) {
        if (!record) {
            done = true;
            return;
        }
        ++count;
        auto type = record->key.type().utf8();
        auto partition = record->key.partition().utf8();
        auto identifier = record->key.identifier().utf8();
        auto bodyHash = info.bodyHash.utf8();
        callback(context, rawChars(type), rawChars(partition), rawChars(identifier), record->key.hash().data(), record->timeStamp.secondsSinceEpoch().milliseconds(), record->header.size(), record->body.size(), rawChars(bodyHash), info.bodyShareCount, info.worth, info.lastAccessTime.secondsSinceEpoch().milliseconds());
    });
    spinUntil(done);
    return count;
}

int NCTS_CacheStoreCompressionDictionary(uint64_t handle, const NCTSRequest* requestSpec, const NCTSResponse* responseSpec, const uint8_t* body, size_t bodyLength, const char* match, const char* id, uint32_t destinationBits, double expirationMs)
{
    RefPtr cache = cacheForHandle(handle);
    if (!cache || !requestSpec || !responseSpec || !requestSpec->url || !responseSpec->url || !body || !std::isfinite(expirationMs))
        return 0;
    if (!cache->capacity())
        return -1;
    cache->storeCompressionDictionary(makeRequest(*requestSpec), makeResponse(*responseSpec, bodyLength), makeBuffer(body, bodyLength), { stringFromUTF8(match), stringFromUTF8(id), CompressionDictionaryEntry::DestinationSet::fromRaw(destinationBits), WallTime::fromRawSeconds(expirationMs / 1000) });
    return 1;
}

int NCTS_CacheCompressionDictionaryMatch(uint64_t handle, const NCTSRequest* requestSpec, unsigned destination, char* text, size_t textCapacity, size_t* textLength, uint8_t* body, size_t bodyCapacity, size_t* bodyLength)
{
    RefPtr cache = cacheForHandle(handle);
    if (!cache || !requestSpec || !requestSpec->url || !textLength || !bodyLength || destination > 255 || !WTF::isValidEnum<WebCore::FetchOptions::Destination>(static_cast<uint8_t>(destination)))
        return -1;
    *textLength = 0;
    *bodyLength = 0;
    auto match = cache->bestCompressionDictionaryMatch(makeRequest(*requestSpec), static_cast<WebCore::FetchOptions::Destination>(destination));
    if (!match)
        return 0;
    *textLength = textOut(makeString("key:\n"_s, describeKey(match->key), "dictionaryHash="_s, hexString(match->hash), "\nid="_s, match->id, '\n'), text, textCapacity);
    bool done = false;
    cache->retrieveCompressionDictionary(match->key, match->hash, [&](RefPtr<WebCore::SharedBuffer>&& buffer) {
        if (buffer) {
            *bodyLength = buffer->size();
            if (body)
                buffer->copyTo(std::span { body, std::min(buffer->size(), bodyCapacity) });
        }
        done = true;
    });
    spinUntil(done);
    return 1;
}

int NCTS_PrefetchStore(const NCTSRequest* requestSpec, const NCTSResponse* responseSpec, const uint8_t* body, size_t bodyLength)
{
    if (!RunLoop::isMain() || !requestSpec || !responseSpec || !requestSpec->url || !responseSpec->url || !body)
        return 0;
    prefetchCache().store(URL { stringFromUTF8(requestSpec->url) }, makeResponse(*responseSpec, bodyLength), PrivateRelayed::No, makeBuffer(body, bodyLength));
    return 1;
}

int NCTS_PrefetchTake(const char* url, char* text, size_t textCapacity, size_t* textLength, uint8_t* body, size_t bodyCapacity, size_t* bodyLength)
{
    if (!RunLoop::isMain() || !url || !textLength || !bodyLength)
        return -1;
    *textLength = 0;
    *bodyLength = 0;
    auto entry = prefetchCache().take(URL { stringFromUTF8(url) });
    if (!entry)
        return 0;
    StringBuilder builder;
    builder.append("status="_s, entry->response.httpStatusCode(), "\nurl="_s, entry->response.url().string(), "\nmime="_s, entry->response.mimeType(), "\nprivateRelayed="_s, static_cast<int>(entry->privateRelayed), "\nheaders:\n"_s);
    for (auto& header : entry->response.httpHeaderFields())
        builder.append(header.key, ": "_s, header.value, '\n');
    *textLength = textOut(builder.toString(), text, textCapacity);
    if (RefPtr buffer = entry->buffer) {
        *bodyLength = buffer->size();
        if (body)
            buffer->copyTo(std::span { body, std::min(buffer->size(), bodyCapacity) });
    }
    return 1;
}

long long NCTS_KeyEncode(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, int includesCredentials, uint8_t* out, size_t outCapacity)
{
    if (!salt)
        return -1;
    Key key { stringFromUTF8(partition), stringFromUTF8(type), stringFromUTF8(range), stringFromUTF8(identifier), makeSalt(salt), includesCredentials ? Key::IncludesCredentials::Yes : Key::IncludesCredentials::No };
    WTF::Persistence::Encoder encoder;
    encoder << key;
    auto encoded = encoder.span();
    if (encoded.size() <= outCapacity && out)
        memcpy(out, encoded.data(), encoded.size());
    return encoded.size();
}

long long NCTS_KeyDecode(const uint8_t* bytes, size_t length, char* text, size_t textCapacity)
{
    if (!bytes || !validRange(bytes, length))
        return -1;
    WTF::Persistence::Decoder decoder(std::span { bytes, length });
    std::optional<Key> key;
    decoder >> key;
    if (!key)
        return -1;
    return textOut(describeKey(*key), text, textCapacity);
}

long long NCTS_CoderRoundTrip(int kind, const uint8_t* bytes, size_t length, uint8_t* out, size_t outCapacity)
{
    if (!bytes || !validRange(bytes, length))
        return -1;
    std::span input { bytes, length };
    switch (kind) {
    case 0:
        return coderRoundTrip<Key>(input, out, outCapacity);
    case 1:
        return coderRoundTrip<SHA1::Digest>(input, out, outCapacity);
    case 2:
        return coderRoundTrip<Vector<uint8_t>>(input, out, outCapacity);
    case 3:
        return coderRoundTrip<SubresourceInfo>(input, out, outCapacity);
    case 4:
        return coderRoundTrip<Vector<std::pair<String, String>>>(input, out, outCapacity);
    }
    return -1;
}

long long NCTS_RecordEncode(uint64_t handle, const char* partition, const char* type, const char* range, const char* identifier, double timestampMs, const uint8_t* header, size_t headerLength, const uint8_t* body, size_t bodyLength, const uint8_t* blobHash, uint8_t* out, size_t outCapacity)
{
    RefPtr cache = cacheForHandle(handle);
    if (!cache || !header || !body || !std::isfinite(timestampMs))
        return -1;
    auto& storage = TestSupportAccess::storage(*cache);
    Storage::Record record { makeKey(partition, type, range, identifier, storage.salt().data()), WallTime::fromRawSeconds(timestampMs / 1000), Data { std::span { header, headerLength } }, Data { std::span { body, bodyLength } }, std::nullopt };
    std::optional<BlobStorage::Blob> blob;
    if (blobHash) {
        SHA1::Digest digest;
        memcpy(digest.data(), blobHash, digest.size());
        blob = BlobStorage::Blob { record.body, digest };
    }
    auto encoded = TestSupportAccess::encodeRecord(storage, record, WTF::move(blob));
    if (encoded.size() <= outCapacity && !encoded.isEmpty() && out)
        memcpy(out, encoded.span().data(), encoded.size());
    return encoded.size();
}

long long NCTS_RecordRead(uint64_t handle, const uint8_t* file, size_t length, char* text, size_t textCapacity)
{
    RefPtr cache = cacheForHandle(handle);
    if (!cache || !file || !validRange(file, length))
        return -1;
    auto& storage = TestSupportAccess::storage(*cache);
    Storage::Record record;
    // Storage::readRecord is for the IO queue, not the main thread.
    Thread::create("NCTS record"_s, [&] {
        record = TestSupportAccess::readRecord(storage, Data { std::span { file, length } });
    })->waitForCompletion();
    if (record.isNull())
        return -1;
    StringBuilder builder;
    builder.append(describeKey(record.key), "timestampMs="_s, millisecondsOut(record.timeStamp), "\nheaderLength="_s, record.header.size(), "\nheader="_s, hexString(record.header.span()), "\nbodyLength="_s, record.body.size(), "\nbody="_s, hexString(record.body.span()), "\nbodyHash="_s);
    if (record.bodyHash)
        builder.append(hexString(*record.bodyHash));
    builder.append('\n');
    return textOut(builder.toString(), text, textCapacity);
}

long long NCTS_EntryDecodeResponseURL(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, double timestampMs, const uint8_t* header, size_t headerLength, char* text, size_t textCapacity)
{
    if (!salt || !validRange(header, headerLength) || !std::isfinite(timestampMs))
        return -1;
    Storage::Record record { makeKey(partition, type, range, identifier, salt), WallTime::fromRawSeconds(timestampMs / 1000), Data { std::span { header, headerLength } }, Data { }, std::nullopt };
    auto url = Entry::decodeStorageRecordResponseURL(record);
    if (!url)
        return -1;
    return textOut(url->string(), text, textCapacity);
}

long long NCTS_CompressionDictionaryDecode(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, double timestampMs, const uint8_t* header, size_t headerLength, const uint8_t* body, size_t bodyLength, char* text, size_t textCapacity)
{
    if (!salt || !validRange(header, headerLength) || !validRange(body, bodyLength) || !std::isfinite(timestampMs))
        return -1;
    Storage::Record record { makeKey(partition, type, range, identifier, salt), WallTime::fromRawSeconds(timestampMs / 1000), Data { std::span { header, headerLength } }, Data { std::span { body, bodyLength } }, std::nullopt };
    auto entry = CompressionDictionaryEntry::decodeStorageRecord(record);
    if (!entry)
        return -1;
    auto& info = entry->info();
    RefPtr buffer = entry->buffer();
    return textOut(makeString(describeKey(entry->key()), "timestampMs="_s, millisecondsOut(entry->timeStamp()), "\nmatch="_s, info.match, "\nid="_s, info.id, "\ndestinations="_s, info.matchDest.toRaw(), "\nexpirationMs="_s, millisecondsOut(info.expirationTime), "\nhash="_s, hexString(entry->hash()), "\nbodyLength="_s, buffer ? buffer->size() : 0, '\n'), text, textCapacity);
}

long long NCTS_CompressionDictionaryEncode(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, const char* match, const char* id, uint32_t destinationBits, double expirationMs, const uint8_t* body, size_t bodyLength, uint8_t* out, size_t outCapacity, size_t* headerLength)
{
    if (!salt || !body || !headerLength || !std::isfinite(expirationMs))
        return -1;
    CompressionDictionaryEntry entry { makeKey(partition, type, range, identifier, salt), { stringFromUTF8(match), stringFromUTF8(id), CompressionDictionaryEntry::DestinationSet::fromRaw(destinationBits), WallTime::fromRawSeconds(expirationMs / 1000) }, makeBuffer(body, bodyLength) };
    auto record = entry.encodeAsStorageRecord();
    *headerLength = record.header.size();
    size_t total = record.header.size() + record.body.size();
    if (total <= outCapacity && out) {
        memcpy(out, record.header.span().data(), record.header.size());
        if (!record.body.isEmpty())
            memcpy(out + record.header.size(), record.body.span().data(), record.body.size());
    }
    return total;
}

long long NCTS_SubresourcesEncodeEx(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, const char* loadLines, int rounds, uint8_t* out, size_t outCapacity, size_t* headerLength)
{
    if (!salt || !loadLines || !headerLength || rounds < 1)
        return -1;
    Vector<std::unique_ptr<SubresourceLoad>> loads;
    for (auto line : StringView::fromLatin1(loadLines).split('\n')) {
        Vector<String> fields;
        for (auto field : line.split('|'))
            fields.append(field.toString());
        if (fields.isEmpty())
            continue;
        WebCore::ResourceRequest request { URL { fields[0] } };
        if (fields.size() > 1 && !fields[1].isEmpty())
            request.setFirstPartyForCookies(URL { fields[1] });
        if (fields.size() > 2) {
            if (auto priority = parseInteger<int>(fields[2]))
                request.setPriority(static_cast<WebCore::ResourceLoadPriority>(*priority));
        }
        for (size_t i = 3; i < fields.size(); ++i) {
            auto colon = fields[i].find(':');
            if (colon != notFound)
                request.setHTTPHeaderField(fields[i].left(colon), StringView(fields[i]).substring(colon + 1).trim(isASCIIWhitespace<char16_t>).toString());
        }
        loads.append(makeUnique<SubresourceLoad>(request, makeKey("", "Resource", "", rawChars(fields[0].utf8()), salt)));
    }
    SubresourcesEntry entry { makeKey(partition, type, range, identifier, salt), loads };
    // Each further round sees the infos of the one before: they become non-transient.
    for (int round = 1; round < std::min(rounds, 2); ++round)
        entry.updateSubresourceLoads(loads);
    auto record = entry.encodeAsStorageRecord();
    *headerLength = record.header.size();
    size_t total = record.header.size() + record.body.size();
    if (total <= outCapacity && out) {
        memcpy(out, record.header.span().data(), record.header.size());
        if (!record.body.isEmpty())
            memcpy(out + record.header.size(), record.body.span().data(), record.body.size());
    }
    return total;
}

long long NCTS_BlobAddGet(const char* directory, const uint8_t* salt, const uint8_t* data, size_t length, uint8_t* hash, uint8_t* out, size_t outCapacity, unsigned* shareCount)
{
    if (!directory || !salt || !hash || !shareCount || !validRange(data, length) || !validRange(out, outCapacity))
        return -1;
    auto blobDirectory = FileSystem::pathByAppendingComponent(stringFromUTF8(directory), "Blobs"_s);
    auto recordPath = FileSystem::pathByAppendingComponent(stringFromUTF8(directory), "record"_s);
    FileSystem::makeAllDirectories(blobDirectory);
    long long result = -1;
    // BlobStorage is synchronous and not for the main thread.
    Thread::create("NCTS blob"_s, [&] {
        BlobStorage storage { blobDirectory, makeSalt(salt) };
        auto added = storage.add(recordPath, Data { std::span { data, length } });
        memcpy(hash, added.hash.data(), added.hash.size());
        *shareCount = storage.shareCount(recordPath);
        auto got = storage.get(recordPath);
        result = got.data.size();
        if (got.data.size() <= outCapacity && !got.data.isEmpty())
            memcpy(out, got.data.span().data(), got.data.size());
    })->waitForCompletion();
    return result;
}

} // extern "C"
