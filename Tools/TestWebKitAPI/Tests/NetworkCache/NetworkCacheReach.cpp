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

#if OS(WINDOWS)

#include "Helpers/Test.h"
#include "NetworkCacheTestSupport.h"
#include <string>
#include <vector>
#include <wtf/FileSystem.h>
#include <wtf/text/CString.h>
#include <wtf/text/WTFString.h>

// Proves the test-support layer exported by WebKit2.dll reaches the network cache's own entry points.

namespace TestWebKitAPI {

static constexpr uint64_t testSessionID = 4242;
static constexpr uint8_t testSalt[8] = { 1, 2, 3, 4, 5, 6, 7, 8 };

static String makeTemporaryDirectory()
{
    auto path = FileSystem::createTemporaryFile("NetworkCacheReach"_s);
    FileSystem::deleteFile(path);
    return path;
}

TEST(NetworkCacheReach, StoreAndRetrieve)
{
    auto directory = makeTemporaryDirectory();
    ASSERT_TRUE(NCTS_InstallSession(testSessionID, 0));
    auto cache = NCTS_CacheOpen(reinterpret_cast<const char*>(directory.utf8().span().data()), 1, testSessionID);
    ASSERT_NE(cache, 0u);

    NCTSRequest request { "http://example.com/a.js", nullptr, nullptr, nullptr, 2 /* ReturnCacheDataElseLoad */, -1, 0, 1 };
    NCTSResponse response { "http://example.com/a.js", "text/javascript", 200, "Cache-Control: max-age=3600\nContent-Type: text/javascript\n" };
    const uint8_t body[] = { 'h', 'e', 'l', 'l', 'o', ' ', 'c', 'a', 'c', 'h', 'e' };
    EXPECT_EQ(NCTS_CacheStore(cache, &request, &response, body, sizeof(body)), 1);

    NCTSRetrieveResult result;
    char text[4096];
    size_t textLength = 0;
    uint8_t out[64];
    EXPECT_EQ(NCTS_CacheRetrieve(cache, &request, &result, text, sizeof(text), &textLength, out, sizeof(out)), 0);
    EXPECT_EQ(result.found, 1);
    ASSERT_EQ(result.bodyLength, sizeof(body));
    EXPECT_EQ(memcmp(out, body, sizeof(body)), 0);
    EXPECT_GT(textLength, 0u);

    // The write finishes on the IO queue; a traverse sees the record on disk once it has.
    NCTS_CacheFlush(cache);
    size_t count = 0;
    for (unsigned attempt = 0; attempt < 100000 && !count; ++attempt)
        count = NCTS_CacheTraverse(cache, [](void*, const char*, const uint8_t*, size_t, size_t) { }, nullptr);
    EXPECT_EQ(count, 1u);

    NCTS_CacheClear(cache);
    EXPECT_EQ(NCTS_CacheRetrieve(cache, &request, &result, text, sizeof(text), &textLength, out, sizeof(out)), 0);
    EXPECT_EQ(result.found, 0);

    NCTS_CacheClose(cache);
    FileSystem::deleteNonEmptyDirectory(directory);
}

TEST(NetworkCacheReach, KeyHashAndEntryRoundTrip)
{
    const char16_t identifier[] = u"http://example.com/";
    const char16_t empty[] = u"";
    const char16_t type[] = u"Resource";
    uint8_t hash[20], partitionHash[20];
    char hashString[40];
    EXPECT_EQ(NCTS_KeyHash(empty, 0, type, 8, empty, 0, identifier, 19, testSalt, 1, hash, partitionHash, hashString), 40u);
    uint8_t parsed[20];
    EXPECT_EQ(NCTS_KeyStringToHash(u"0123456789ABCDEF0123456789ABCDEF01234567", 40, parsed), 1);
    EXPECT_EQ(NCTS_KeyStringToHash(u"0123", 4, parsed), 0);

    NCTSResponse response { "http://example.com/", "text/html", 200, "Cache-Control: max-age=60\n" };
    const uint8_t body[] = { 1, 2, 3, 4, 5 };
    uint8_t record[1024];
    size_t headerLength = 0;
    uint8_t bodyHash[20];
    int hasBodyHash = 0;
    auto total = NCTS_EntryEncode("", "Resource", "", "http://example.com/", testSalt, &response, "Accept: */*\n", body, sizeof(body), record, sizeof(record), &headerLength, bodyHash, &hasBodyHash);
    ASSERT_GT(total, 0);
    ASSERT_LE(static_cast<size_t>(total), sizeof(record));
    char text[4096];
    size_t textLength = 0, bodyLength = 0;
    uint8_t out[16];
    EXPECT_EQ(NCTS_EntryDecode("", "Resource", "", "http://example.com/", testSalt, 1000.0, record, headerLength, record + headerLength, total - headerLength, hasBodyHash ? bodyHash : nullptr, text, sizeof(text), &textLength, out, sizeof(out), &bodyLength), 0);
    EXPECT_EQ(bodyLength, sizeof(body));
    EXPECT_EQ(memcmp(out, body, sizeof(body)), 0);
    // A flipped header byte fails the decode.
    record[headerLength / 2] ^= 0xFF;
    EXPECT_EQ(NCTS_EntryDecode("", "Resource", "", "http://example.com/", testSalt, 1000.0, record, headerLength, record + headerLength, total - headerLength, hasBodyHash ? bodyHash : nullptr, text, sizeof(text), &textLength, out, sizeof(out), &bodyLength), -1);
}

struct TraverseExState {
    unsigned count { 0 };
    size_t bodyLength { 0 };
};

TEST(NetworkCacheReach, DiskStateKeysRecordsAndCoders)
{
    auto directory = makeTemporaryDirectory();
    ASSERT_TRUE(NCTS_InstallSession(testSessionID, 0));
    auto path = reinterpret_cast<const char*>(directory.utf8().span().data());
    // RegisterNotify is refused: the notification handler would keep the cache's raw pointer past its life.
    EXPECT_EQ(NCTS_CacheOpen(path, 2, testSessionID), 0u);
    auto cache = NCTS_CacheOpen(path, 1, testSessionID);
    ASSERT_NE(cache, 0u);

    char text[4096];
    EXPECT_GT(NCTS_CacheRecordsPath(cache, text, sizeof(text)), 0);

    // A body over the inline limit is stored as a blob; the barrier makes the files observable.
    std::vector<uint8_t> big(40000, 7);
    NCTSRequest request { "http://example.com/big.bin", nullptr, nullptr, nullptr, 2, -1, 0, 1 };
    NCTSResponse response { "http://example.com/big.bin", "application/octet-stream", 200, "Cache-Control: max-age=3600\n" };
    EXPECT_EQ(NCTS_CacheStore(cache, &request, &response, big.data(), big.size()), 1);
    EXPECT_EQ(NCTS_CacheSync(cache), 0);
    TraverseExState state;
    auto count = NCTS_CacheTraverseEx(cache, 3, [](void* context, const char* type, const char*, const char* identifier, const uint8_t*, double, size_t, size_t bodyLength, const char*, unsigned, double, double) {
        auto& state = *static_cast<TraverseExState*>(context);
        ++state.count;
        state.bodyLength = bodyLength;
        EXPECT_STREQ(type, "Resource");
        EXPECT_STREQ(identifier, "http://example.com/big.bin");
    }, &state);
    EXPECT_EQ(count, 1u);
    EXPECT_EQ(state.count, 1u);

    // A record encoded and read back with the cache's salt; a flipped byte is refused.
    const uint8_t header[] = { 9, 8, 7, 6 };
    const uint8_t body[] = { 1, 2, 3 };
    uint8_t file[1024];
    auto length = NCTS_RecordEncode(cache, "", "Resource", "", "http://example.com/r", 1000.0, header, sizeof(header), body, sizeof(body), nullptr, file, sizeof(file));
    ASSERT_GT(length, 0);
    ASSERT_LE(static_cast<size_t>(length), sizeof(file));
    EXPECT_GT(NCTS_RecordRead(cache, file, length, text, sizeof(text)), 0);
    EXPECT_NE(strstr(text, "timestampMs=1000\n"), nullptr);
    EXPECT_NE(strstr(text, "header=09080706\n"), nullptr);
    file[length - 1] ^= 0xFF;
    EXPECT_EQ(NCTS_RecordRead(cache, file, length, text, sizeof(text)), -1);

    // Key and coder round trips.
    uint8_t keyBytes[512];
    auto keyLength = NCTS_KeyEncode("", "Resource", "", "http://example.com/", testSalt, 1, keyBytes, sizeof(keyBytes));
    ASSERT_GT(keyLength, 0);
    EXPECT_GT(NCTS_KeyDecode(keyBytes, keyLength, text, sizeof(text)), 0);
    uint8_t again[512];
    EXPECT_EQ(NCTS_CoderRoundTrip(0, keyBytes, keyLength, again, sizeof(again)), keyLength);
    EXPECT_EQ(memcmp(again, keyBytes, keyLength), 0);
    EXPECT_EQ(NCTS_CoderRoundTrip(0, keyBytes, keyLength - 1, again, sizeof(again)), -1);

    // A subresources entry whose infos are non-transient, and a compression dictionary record.
    uint8_t record[4096];
    size_t headerLength = 0;
    auto subresources = NCTS_SubresourcesEncodeEx("", "SubResources", "", "http://example.com/", testSalt, "http://example.com/a.js|http://example.com/|2|Accept: */*", 2, record, sizeof(record), &headerLength);
    ASSERT_GT(subresources, 0);
    auto described = NCTS_SubresourcesDecode("", "SubResources", "", "http://example.com/", testSalt, 1000.0, record, headerLength, text, sizeof(text));
    ASSERT_GT(described, 0);
    EXPECT_NE(strstr(text, "transient=0"), nullptr);
    auto dictionary = NCTS_CompressionDictionaryEncode("", "CompressionDictionary", "", "http://example.com/d", testSalt, "/app/*", "id1", 1u << 1, 4102444800000.0, body, sizeof(body), record, sizeof(record), &headerLength);
    ASSERT_GT(dictionary, 0);
    EXPECT_GT(NCTS_CompressionDictionaryDecode("", "CompressionDictionary", "", "http://example.com/d", testSalt, 1000.0, record, headerLength, record + headerLength, dictionary - headerLength, text, sizeof(text)), 0);
    EXPECT_NE(strstr(text, "match=/app/*"), nullptr);

    // The prefetch cache keeps a response until taken.
    NCTSRequest prefetch { "http://example.com/p", nullptr, nullptr, nullptr, 0, -1, 0, 1 };
    NCTSResponse prefetchResponse { "http://example.com/p", "text/plain", 200, nullptr };
    EXPECT_EQ(NCTS_PrefetchStore(&prefetch, &prefetchResponse, body, sizeof(body)), 1);
    size_t textLength = 0, bodyLength = 0;
    uint8_t out[8];
    EXPECT_EQ(NCTS_PrefetchTake("http://example.com/p", text, sizeof(text), &textLength, out, sizeof(out), &bodyLength), 1);
    EXPECT_EQ(bodyLength, sizeof(body));
    EXPECT_EQ(NCTS_PrefetchTake("http://example.com/p", text, sizeof(text), &textLength, out, sizeof(out), &bodyLength), 0);

    NCTS_CacheClose(cache);
    FileSystem::deleteNonEmptyDirectory(directory);
}

TEST(NetworkCacheReach, UseDecisionAge)
{
    ASSERT_TRUE(NCTS_InstallSession(4343, 1));
    NCTSRequest request { "http://example.com/a.js", nullptr, nullptr, nullptr, 0, -1, 0, 1 };
    NCTSResponse response { "http://example.com/a.js", "text/javascript", 200, "Cache-Control: max-age=3600\n" };
    // The same decision at the same age whatever the clock: nowMs - timestampMs is the age, 100 s then 7200 s against max-age 3600.
    int fresh = NCTS_UseDecision(4343, &request, &response, nullptr, 1000000.0, 1100500.0, 0);
    int fresh2 = NCTS_UseDecision(4343, &request, &response, nullptr, 5000000.0, 5100500.0, 0);
    EXPECT_GE(fresh, 0);
    EXPECT_EQ(fresh, fresh2);
    // Fresh at 100 s, validated or refused at 7200 s: the age moves the decision.
    EXPECT_NE(fresh, NCTS_UseDecision(4343, &request, &response, nullptr, 1000000.0, 1000000.0 + 7200500.0, 0));
    EXPECT_EQ(NCTS_UseDecision(4343, &request, &response, nullptr, 1000000.0, 1000000.0 + 7200500.0, 0), NCTS_UseDecision(4343, &request, &response, nullptr, 9000000.0, 9000000.0 + 7200500.0, 0));
    EXPECT_EQ(NCTS_UseDecision(4343, &request, &response, nullptr, 1000.0, __builtin_nan(""), 0), -1);
}

// Every export survives nil pointers (safe Swift can pass nil without `unsafe`): the guards return 0/-1 where an unguarded export reads or writes at address 0.
TEST(NetworkCacheReach, NilPointersAreRefused)
{
    char entryText[64];
    size_t entryTextLength = 0, entryBodyLength = 0;
    EXPECT_EQ(NCTS_KeyHash(nullptr, 0, nullptr, 0, nullptr, 0, nullptr, 0, nullptr, 0, nullptr, nullptr, nullptr), 0u);
    EXPECT_EQ(NCTS_KeyStringToHash(nullptr, 40, nullptr), 0);
    EXPECT_EQ(NCTS_EntryDecode(nullptr, nullptr, nullptr, nullptr, nullptr, 0, nullptr, 0, nullptr, 0, nullptr, nullptr, 0, nullptr, nullptr, 0, nullptr), -1);
    EXPECT_EQ(NCTS_SubresourcesDecode(nullptr, nullptr, nullptr, nullptr, nullptr, 0, nullptr, 0, nullptr, 0), -1);
    // A null pointer with a length above 0 is refused by the decode functions.
    EXPECT_EQ(NCTS_EntryDecode("", "Resource", "", "http://example.com/", testSalt, 0, nullptr, 8, nullptr, 0, nullptr, entryText, sizeof(entryText), &entryTextLength, nullptr, 0, &entryBodyLength), -1);
    EXPECT_EQ(NCTS_EntryDecode("", "Resource", "", "http://example.com/", testSalt, 0, testSalt, 8, nullptr, 8, nullptr, entryText, sizeof(entryText), &entryTextLength, nullptr, 0, &entryBodyLength), -1);
    EXPECT_EQ(NCTS_SubresourcesDecode("", "SubResources", "", "http://example.com/", testSalt, 0, nullptr, 8, entryText, sizeof(entryText)), -1);
    // The three exports that build records, and the blob export, refuse all-nil arguments.
    EXPECT_EQ(NCTS_EntryEncode(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, 0, nullptr, 0, nullptr, nullptr, nullptr), -1);
    EXPECT_EQ(NCTS_SubresourcesEncode(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, 0, nullptr), -1);
    EXPECT_EQ(NCTS_BlobAddGet(nullptr, nullptr, nullptr, 0, nullptr, nullptr, 0, nullptr), -1);
    // A null pointer with length 0 is an empty range, as before.
    const char16_t type[] = u"Resource";
    uint8_t hash[20], partitionHash[20];
    char hashString[40];
    EXPECT_EQ(NCTS_KeyHash(nullptr, 0, type, 8, nullptr, 0, nullptr, 0, testSalt, 0, hash, partitionHash, hashString), 40u);
    // One nil among valid arguments.
    EXPECT_EQ(NCTS_KeyHash(nullptr, 0, type, 8, nullptr, 0, nullptr, 0, testSalt, 0, hash, nullptr, hashString), 0u);
    EXPECT_EQ(NCTS_KeyHash(nullptr, 3, type, 8, nullptr, 0, nullptr, 0, testSalt, 0, hash, partitionHash, hashString), 0u);
}

// The facade prints a time as whole milliseconds with a defined conversion: NaN prints 0 and infinities clamp to the long long range.
TEST(NetworkCacheReach, TimestampPrintingIsDefined)
{
    NCTSResponse response { "http://example.com/", "text/html", 200, "Cache-Control: max-age=60\n" };
    const uint8_t body[] = { 1, 2, 3 };
    uint8_t record[1024];
    size_t headerLength = 0;
    uint8_t bodyHash[20];
    int hasBodyHash = 0;
    auto total = NCTS_EntryEncode("", "Resource", "", "http://example.com/", testSalt, &response, nullptr, body, sizeof(body), record, sizeof(record), &headerLength, bodyHash, &hasBodyHash);
    ASSERT_GT(total, 0);
    // The decode takes the record's timestamp from the caller (the record's own timestamp is not in the entry's header).
    auto timestampLine = [&](double timestampMs) {
        char text[4096];
        size_t textLength = 0, bodyLength = 0;
        uint8_t out[16];
        EXPECT_EQ(NCTS_EntryDecode("", "Resource", "", "http://example.com/", testSalt, timestampMs, record, headerLength, record + headerLength, total - headerLength, hasBodyHash ? bodyHash : nullptr, text, sizeof(text), &textLength, out, sizeof(out), &bodyLength), 0);
        std::string all(text, std::min(textLength, sizeof(text)));
        auto start = all.find("timestampMs=");
        EXPECT_NE(start, std::string::npos);
        return all.substr(start, all.find('\n', start) - start);
    };
    EXPECT_EQ(timestampLine(1000.0), std::string("timestampMs=1000"));
    EXPECT_EQ(timestampLine(__builtin_nan("")), std::string("timestampMs=0"));
    EXPECT_EQ(timestampLine(__builtin_inf()), std::string("timestampMs=9223372036854775807"));
    EXPECT_EQ(timestampLine(-__builtin_inf()), std::string("timestampMs=-9223372036854775808"));
    EXPECT_EQ(timestampLine(1e300), std::string("timestampMs=9223372036854775807"));
}

} // namespace TestWebKitAPI

#endif // OS(WINDOWS)
