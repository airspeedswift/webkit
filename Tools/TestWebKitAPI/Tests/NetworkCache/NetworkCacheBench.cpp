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
#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>
#include <wtf/FileSystem.h>
#include <wtf/MonotonicTime.h>
#include <wtf/StdLibExtras.h>
#include <wtf/text/ASCIILiteral.h>
#include <wtf/text/CString.h>
#include <wtf/text/WTFString.h>

// The network cache's speed and pass/fail checksums, through the test support WebKit2.dll exports (NetworkCacheTestSupport.h),
// which calls the production entry points: Key, Entry::encodeAsStorageRecord / decodeStorageRecord, SubresourcesEntry, the cache's
// store, retrieve, update, remove, traverseRecords and clear, BlobStorage, and the cache's store, retrieve and use decisions.
// One shape per test. Each test runs one pass over its fixed input and checks the checksum of that pass's results (an FNV-1a hash of
// every result, its text and bytes; timestamps taken from the wall clock are left out of it), the recorded value. With
// WEBKIT_RUN_BENCHMARKS=1 it repeats the pass a fixed number of times (100; WEBKIT_BENCH_PASSES sets another) and prints
// <Shape>: <ms> ms <MB/s> MB/s passes=<n> checksum=<hex>, where the rate is the bytes the pass hands the cache (records, bodies, key strings).
// The checksums of the decision shapes assume the wall clock is later than 2020 and before 2090: the generated responses are
// dated 2020 and are either far inside their lifetime (max-age of 10^10 seconds, Expires in 2100) or far outside it.

namespace TestWebKitAPI {

namespace NetworkCacheBench {

static constexpr uint64_t sessionID = 4343;
static constexpr uint8_t salt[8] = { 1, 2, 3, 4, 5, 6, 7, 8 };
static constexpr double recordTimestampMs = 1700000000000.0;

class Digest {
public:
    void add(uint64_t value)
    {
        m_hash ^= value;
        m_hash *= 0x100000001b3ull;
        m_hash ^= m_hash >> 29;
    }
    void add(const void* data, size_t length) { add(std::span { static_cast<const uint8_t*>(data), length }); }
    void add(std::span<const uint8_t> bytes)
    {
        add(static_cast<uint64_t>(bytes.size()));
        for (; bytes.size() >= 8; bytes = bytes.subspan(8)) {
            uint64_t word;
            memcpySpan(asMutableByteSpan(word), bytes.first(8));
            m_hash ^= word;
            m_hash *= 0x100000001b3ull;
            m_hash ^= m_hash >> 29;
        }
        for (auto byte : bytes) {
            m_hash ^= byte;
            m_hash *= 0x100000001b3ull;
        }
    }
    void add(const std::string& string) { add(string.data(), string.size()); }
    // Description text of an entry: the lines and fields that carry the wall clock (timestampMs, lastSeenMs, firstSeenMs) are left out.
    void addText(const char* text, size_t length)
    {
        std::string kept;
        kept.reserve(length);
        static constexpr const char* skipped[] = { "timestampMs=", " lastSeenMs=", " firstSeenMs=" };
        static_assert(sizeof(skipped) / sizeof(skipped[0]) == 3);
        for (size_t i = 0; i < length;) {
            bool matched = false;
            for (auto* prefix : skipped) {
                std::string_view prefixView { prefix };
                if (std::string_view { text + i, length - i }.starts_with(prefixView)) {
                    i += prefixView.size();
                    while (i < length && text[i] >= '0' && text[i] <= '9')
                        ++i;
                    matched = true;
                    break;
                }
            }
            if (!matched)
                kept += text[i++];
        }
        add(kept);
    }
    uint64_t value() const { return m_hash; }

private:
    uint64_t m_hash { 0xcbf29ce484222325ull };
};

class Lcg {
public:
    explicit Lcg(uint64_t seed)
        : m_state(seed * 6364136223846793005ull + 1442695040888963407ull)
    {
    }
    uint32_t next()
    {
        m_state = m_state * 6364136223846793005ull + 1442695040888963407ull;
        return static_cast<uint32_t>(m_state >> 33);
    }
    unsigned range(unsigned low, unsigned high)
    {
        unsigned span = high - low + 1;
        return low + next() % span;
    }

private:
    uint64_t m_state;
};

// WEBKIT_BENCH_NOTES=1 prints what a pass observed (decision classes, hit counts), to check a shape reaches what it names.
static void note(const char* format, ...)
{
    if (!getenv("WEBKIT_BENCH_NOTES"))
        return;
    va_list arguments;
    va_start(arguments, format);
    vfprintf(stdout, format, arguments);
    va_end(arguments);
    fputc('\n', stdout);
}

static bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && std::string_view { value } != "0";
}

// The number of timed passes of every shape: the same work on every build (WEBKIT_BENCH_PASSES sets another).
static unsigned benchmarkPassCount()
{
    static constexpr unsigned defaultPassCount = 100;
    auto* value = getenv("WEBKIT_BENCH_PASSES");
    if (!value || !*value)
        return defaultPassCount;
    auto count = strtoul(value, nullptr, 10);
    return count ? static_cast<unsigned>(count) : defaultPassCount;
}

struct PassResult {
    uint64_t checksum;
    uint64_t bytes;
};

// One pass, its checksum against the recorded one; with WEBKIT_RUN_BENCHMARKS=1 benchmarkPassCount() passes, then the line.
template<typename Pass>
static void runShape(ASCIILiteral name, uint64_t expectedChecksum, Pass&& pass)
{
    auto first = pass();
    EXPECT_EQ(first.checksum, expectedChecksum);
    if (!runsBenchmarks())
        return;
    uint64_t totalBytes = 0;
    unsigned passes = benchmarkPassCount();
    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < passes; ++i) {
        auto result = pass();
        EXPECT_EQ(result.checksum, first.checksum);
        totalBytes += result.bytes;
    }
    double elapsed = (MonotonicTime::now() - start).seconds();
    SAFE_PRINTF("%s: %.1f ms %.2f MB/s passes=%u checksum=%016llx\n", name, elapsed * 1000, totalBytes / 1e6 / elapsed, passes, static_cast<unsigned long long>(first.checksum));
    fflush(stdout);
}

// ---- generators ----

static std::string textBody(Lcg& random, size_t size)
{
    static constexpr const char* words[] = { "function", "return", "var", "const", "this", "document", "window", "length", "prototype", "undefined", "if", "else", "for", "while", "{", "}", "(", ")", ";", "=", "==", "\n", "    ", "0", "1", "e", "t", "a", "o", "i", "n" };
    std::string body;
    body.reserve(size + 16);
    while (body.size() < size) {
        body += words[random.next() % (sizeof(words) / sizeof(words[0]))];
        if (!(random.next() % 4))
            body += ' ';
        if (!(random.next() % 29))
            body += static_cast<char>('a' + random.next() % 26);
    }
    body.resize(size);
    return body;
}

static std::string typicalHeaders(unsigned i, size_t bodySize)
{
    std::string headers;
    headers += "Content-Type: text/javascript; charset=utf-8\n";
    headers += "Cache-Control: public, max-age=31536000\n";
    headers += "Date: Mon, 02 Mar 2020 10:00:00 GMT\n";
    headers += "Last-Modified: Tue, 03 Dec 2019 08:00:00 GMT\n";
    headers += "ETag: \"5d2f" + std::to_string(i) + "\"\n";
    headers += "Server: nginx\n";
    headers += "Content-Length: " + std::to_string(bodySize) + "\n";
    headers += "Vary: Accept-Encoding, Accept-Language\n";
    headers += "Access-Control-Allow-Origin: *\n";
    headers += "X-Content-Type-Options: nosniff\n";
    headers += "Strict-Transport-Security: max-age=63072000; includeSubDomains\n";
    headers += "Connection: keep-alive\n";
    return headers;
}

static const char* const typicalVary = "Accept-Encoding: gzip, deflate, br\nAccept-Language: en-US,en;q=0.9\n";

static std::string urlFor(unsigned i)
{
    return "https://cdn" + std::to_string(i % 7) + ".example.com/assets/v" + std::to_string(i % 13) + "/chunk-" + std::to_string(i) + ".js?x=" + std::to_string(i * 2654435761u % 100000);
}

// ---- session and temporary directories ----

static bool hasNetworkSession = false;

static void ensureSession()
{
    static bool installed = false;
    if (installed)
        return;
    installed = true;
    hasNetworkSession = NCTS_InstallSession(sessionID, 1);
    if (!hasNetworkSession)
        ASSERT_TRUE(NCTS_InstallSession(sessionID, 0));
}

static String makeTemporaryDirectory()
{
    auto path = FileSystem::createTemporaryFile("NetworkCacheBench"_s);
    FileSystem::deleteFile(path);
    return path;
}

// The storage's salt is random per directory and every key's hash derives from it; the file is made first, with a fixed salt, so
// the keys' hashes and the traversal are the same in every run. (Storage::version is 18.)
static uint64_t openCache(const String& directory)
{
    auto versionDirectory = FileSystem::pathByAppendingComponent(directory, "Version 18"_s);
    auto saltPath = FileSystem::pathByAppendingComponent(versionDirectory, "salt"_s);
    if (!FileSystem::fileExists(saltPath)) {
        FileSystem::makeAllDirectories(versionDirectory);
        FileSystem::overwriteEntireFile(saltPath, std::span<const uint8_t> { salt, 8 });
    }
    return NCTS_CacheOpen(reinterpret_cast<const char*>(directory.utf8().span().data()), 1, sessionID);
}

static NCTSRequest requestFor(const std::string& url, int policy = 2)
{
    return { url.c_str(), nullptr, nullptr, nullptr, policy, -1, 0, 1 };
}

// Polls the traversal until it sees `expected` records (a write finishes on the IO queue, unobservably; the traversal sees only the files).
static size_t waitForRecords(uint64_t cache, size_t expected)
{
    NCTS_CacheFlush(cache);
    size_t count = 0;
    for (unsigned attempt = 0; attempt < 20000; ++attempt) {
        count = NCTS_CacheTraverse(cache, [](void*, const char*, const uint8_t*, size_t, size_t) { }, nullptr);
        if (count == expected)
            break;
    }
    if (count != expected)
        note("waitForRecords: expected %zu, saw %zu", expected, count);
    return count;
}

struct RetrieveBuffers {
    std::vector<char> text = std::vector<char>(8192);
    std::vector<uint8_t> body = std::vector<uint8_t>(512 * 1024);
};

static unsigned retrievesFound, retrievesMissed;

// Retrieves `url` and digests the whole result; returns whether an entry was found.
static bool retrieveAndDigest(uint64_t cache, const std::string& url, int policy, RetrieveBuffers& buffers, Digest& digest, uint64_t& bytes)
{
    auto request = requestFor(url, policy);
    NCTSRetrieveResult result;
    size_t textLength = 0;
    int status = NCTS_CacheRetrieve(cache, &request, &result, buffers.text.data(), buffers.text.size(), &textLength, buffers.body.data(), buffers.body.size());
    digest.add(static_cast<uint64_t>(status + 1));
    digest.add(static_cast<uint64_t>(result.found) | static_cast<uint64_t>(result.retrieveDecision + 1) << 8 | static_cast<uint64_t>(result.speculativeLoadDecision + 1) << 16 | static_cast<uint64_t>(result.useDecision + 1) << 24 | static_cast<uint64_t>(result.needsValidation) << 32);
    if (status || !result.found) {
        ++retrievesMissed;
        return false;
    }
    ++retrievesFound;
    digest.addText(buffers.text.data(), std::min(textLength, buffers.text.size()));
    digest.add(buffers.body.data(), std::min(result.bodyLength, buffers.body.size()));
    bytes += textLength + result.bodyLength;
    return true;
}

// ---- KeyHash ----

static std::u16string toUTF16(const std::string& string) { return std::u16string(string.begin(), string.end()); }

struct KeyHashInput {
    std::u16string partition;
    std::u16string identifier;
    bool includesCredentials;
};

static std::vector<KeyHashInput> makeKeyHashInputs()
{
    Lcg random(11);
    std::vector<KeyHashInput> inputs;
    for (unsigned i = 0; i < 10000; ++i) {
        KeyHashInput input;
        input.identifier = toUTF16(urlFor(i));
        input.includesCredentials = !!(i % 3);
        if (!(i % 5))
            input.partition = toUTF16("site" + std::to_string(i % 50) + ".example.org");
        if (i % 10 == 7) {
            // 10% non-ASCII: a Latin-1 letter, a BMP letter, an emoji's surrogate pair, a lone surrogate in turn.
            switch ((i / 10) % 4) {
            case 0: input.identifier += u"/caf\u00e9"; break;
            case 1: input.identifier += u"/\u4e2d\u6587/\u0416"; break;
            case 2: input.identifier += u"/\U0001F600x"; break;
            default: input.identifier += u"/\xd800z"; break;
            }
            if (i % 20 == 7)
                input.partition += u"\u00e9\u4e2d";
        }
        inputs.push_back(WTF::move(input));
    }
    return inputs;
}

static const char* const stringToHashCases[] = {
    "0123456789ABCDEF0123456789ABCDEF01234567", "0123456789abcdef0123456789abcdef01234567", "0123456789ABCDEF0123456789ABCDEF0123456",
    "0123456789ABCDEF0123456789ABCDEF012345678", "0123456789ABCDEF0123456789ABCDEF0123456G", "", "0123456789ABCDEF0123456789ABCDEF0123456 ",
};

TEST(NetworkCacheBench, StartUp)
{
}

TEST(NetworkCacheBench, KeyHash)
{
    auto inputs = makeKeyHashInputs();
    runShape("KeyHash"_s, 0xf0ce6ab12f11ced6ull, [&] {
        Digest digest;
        uint64_t bytes = 0;
        uint8_t hash[20], partitionHash[20], parsed[20];
        char hashString[40];
        static const char16_t empty[] = u"";
        static const char16_t type[] = u"Resource";
        for (auto& input : inputs) {
            auto length = NCTS_KeyHash(input.partition.data(), input.partition.size(), type, 8, empty, 0, input.identifier.data(), input.identifier.size(), salt, input.includesCredentials, hash, partitionHash, hashString);
            digest.add(hash, 20);
            digest.add(partitionHash, 20);
            digest.add(hashString, length);
            auto string = toUTF16(std::string(hashString, length));
            int ok = NCTS_KeyStringToHash(string.data(), string.size(), parsed);
            digest.add(static_cast<uint64_t>(ok));
            digest.add(parsed, ok ? 20 : 0);
            bytes += (input.partition.size() + input.identifier.size()) * 2 + 40;
        }
        for (auto* text : stringToHashCases) {
            auto string = toUTF16(text);
            int ok = NCTS_KeyStringToHash(string.data(), string.size(), parsed);
            digest.add(static_cast<uint64_t>(ok));
            digest.add(parsed, ok ? 20 : 0);
        }
        return PassResult { digest.value(), bytes };
    });
}

// ---- EncodeEntry, DecodeEntry ----

struct EntryRecord {
    std::string identifier;
    std::string responseHeaders;
    std::string body;
    std::vector<uint8_t> record; // header || body
    size_t headerLength { 0 };
    uint8_t bodyHash[20] { };
    int hasBodyHash { 0 };
};

static std::vector<EntryRecord> makeEntries(size_t bodySize, size_t totalBytes)
{
    Lcg random(bodySize);
    std::vector<EntryRecord> entries(std::max<size_t>(1, totalBytes / bodySize));
    unsigned i = 0;
    for (auto& entry : entries) {
        entry.identifier = urlFor(i);
        entry.body = textBody(random, bodySize);
        entry.responseHeaders = typicalHeaders(i, bodySize);
        ++i;
    }
    return entries;
}

static long long encodeEntry(EntryRecord& entry, std::vector<uint8_t>& out)
{
    NCTSResponse response { entry.identifier.c_str(), "text/javascript", 200, entry.responseHeaders.c_str() };
    return NCTS_EntryEncode("", "Resource", "", entry.identifier.c_str(), salt, &response, typicalVary, reinterpret_cast<const uint8_t*>(entry.body.data()), entry.body.size(), out.data(), out.size(), &entry.headerLength, entry.bodyHash, &entry.hasBodyHash);
}

static void runEncodeEntry(ASCIILiteral name, uint64_t expected, size_t bodySize)
{
    auto entries = makeEntries(bodySize, 4 << 20);
    std::vector<uint8_t> out(bodySize + 8192);
    runShape(name, expected, [&] {
        Digest digest;
        uint64_t bytes = 0;
        for (auto& entry : entries) {
            auto total = encodeEntry(entry, out);
            digest.add(static_cast<uint64_t>(total));
            if (total > 0 && static_cast<size_t>(total) <= out.size())
                digest.add(out.data(), total);
            digest.add(static_cast<uint64_t>(entry.headerLength) | static_cast<uint64_t>(entry.hasBodyHash) << 40);
            digest.add(entry.bodyHash, entry.hasBodyHash ? 20 : 0);
            bytes += total;
        }
        return PassResult { digest.value(), bytes };
    });
}

static void runDecodeEntry(ASCIILiteral name, uint64_t expected, size_t bodySize)
{
    auto entries = makeEntries(bodySize, 4 << 20);
    std::vector<uint8_t> out(bodySize + 8192);
    for (auto& entry : entries) {
        auto total = encodeEntry(entry, out);
        ASSERT_GT(total, 0);
        entry.record.assign(out.begin(), out.begin() + total);
    }
    RetrieveBuffers buffers;
    runShape(name, expected, [&] {
        Digest digest;
        uint64_t bytes = 0;
        for (auto& entry : entries) {
            size_t textLength = 0, bodyLength = 0;
            int status = NCTS_EntryDecode("", "Resource", "", entry.identifier.c_str(), salt, recordTimestampMs, entry.record.data(), entry.headerLength, entry.record.data() + entry.headerLength, entry.record.size() - entry.headerLength, entry.hasBodyHash ? entry.bodyHash : nullptr, buffers.text.data(), buffers.text.size(), &textLength, buffers.body.data(), buffers.body.size(), &bodyLength);
            digest.add(static_cast<uint64_t>(status + 1));
            digest.addText(buffers.text.data(), std::min(textLength, buffers.text.size()));
            digest.add(buffers.body.data(), std::min(bodyLength, buffers.body.size()));
            bytes += entry.record.size();
        }
        return PassResult { digest.value(), bytes };
    });
}

TEST(NetworkCacheBench, EncodeEntry1K) { runEncodeEntry("EncodeEntry1K"_s, 0x59c860b0dbe65d04ull, 1 << 10); }
TEST(NetworkCacheBench, EncodeEntry16K) { runEncodeEntry("EncodeEntry16K"_s, 0xaae94f22c22d13e8ull, 16 << 10); }
TEST(NetworkCacheBench, EncodeEntry256K) { runEncodeEntry("EncodeEntry256K"_s, 0x559e39b014841819ull, 256 << 10); }
TEST(NetworkCacheBench, DecodeEntry1K) { runDecodeEntry("DecodeEntry1K"_s, 0x008ae58c2635c14eull, 1 << 10); }
TEST(NetworkCacheBench, DecodeEntry16K) { runDecodeEntry("DecodeEntry16K"_s, 0x7190c83770054926ull, 16 << 10); }
TEST(NetworkCacheBench, DecodeEntry256K) { runDecodeEntry("DecodeEntry256K"_s, 0xe413eb57d4f7c68aull, 256 << 10); }

// ---- DecodeSubresources ----

struct SubresourcesRecord {
    std::vector<uint8_t> record;
    size_t headerLength { 0 };
};

static SubresourcesRecord makeSubresourcesRecord(unsigned count)
{
    std::string urls;
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            urls += '\n';
        urls += "https://static" + std::to_string(i % 5) + ".example.com/res/" + std::to_string(i) + (i % 3 ? ".js" : ".css");
    }
    SubresourcesRecord result;
    std::vector<uint8_t> out(1 << 20);
    auto total = NCTS_SubresourcesEncode("", "SubResources", "", "https://example.com/page", salt, urls.c_str(), out.data(), out.size(), &result.headerLength);
    EXPECT_GT(total, 0);
    result.record.assign(out.begin(), out.begin() + total);
    return result;
}

static long long decodeSubresources(const SubresourcesRecord& record, size_t headerLength, std::vector<char>& text)
{
    return NCTS_SubresourcesDecode("", "SubResources", "", "https://example.com/page", salt, recordTimestampMs, record.record.data(), headerLength, text.data(), text.size());
}

TEST(NetworkCacheBench, DecodeSubresources)
{
    auto record = makeSubresourcesRecord(64);
    ASSERT_GT(record.record.size(), 0u);
    std::vector<char> text(1 << 20);
    runShape("DecodeSubresources"_s, 0xf0d4c449ff9879f2ull, [&] {
        Digest digest;
        uint64_t bytes = 0;
        for (unsigned i = 0; i < 100; ++i) {
            auto length = decodeSubresources(record, record.headerLength, text);
            digest.add(static_cast<uint64_t>(length + 1));
            if (length > 0)
                digest.addText(text.data(), std::min<size_t>(length, text.size()));
            bytes += record.headerLength;
        }
        return PassResult { digest.value(), bytes };
    });
}

// ---- DecodeFailure: corrupt records, the decoders' error paths ----

TEST(NetworkCacheBench, DecodeFailure)
{
    auto entries = makeEntries(1 << 10, 8 << 10);
    std::vector<uint8_t> out(1 << 20);
    for (auto& entry : entries) {
        auto total = encodeEntry(entry, out);
        ASSERT_GT(total, 0);
        entry.record.assign(out.begin(), out.begin() + total);
    }
    auto subresources = makeSubresourcesRecord(64);
    RetrieveBuffers buffers;
    std::vector<char> subresourcesText(1 << 20);
    runShape("DecodeFailure"_s, 0x64e1b4716ee20886ull, [&] {
        Digest digest;
        uint64_t bytes = 0;
        Lcg random(5);
        std::vector<uint8_t> header;
        unsigned entryDecodes = 0, entryFailures = 0, subresourceDecodes = 0, subresourceFailures = 0;
        for (unsigned round = 0; round < 4; ++round) {
            for (auto& entry : entries) {
                for (unsigned variant = 0; variant < 24; ++variant) {
                    header.assign(entry.record.begin(), entry.record.begin() + entry.headerLength);
                    switch (variant % 8) {
                    case 0: header[variant * 7 % header.size()] ^= 0xff; break; // a flipped byte
                    case 1: header.resize(header.size() / 2); break; // truncated
                    case 2: header.resize(3); break; // shorter than the first field
                    case 3: header.clear(); break; // empty
                    case 4: header[0] = header[1] = header[2] = header[3] = 0xff; break; // a huge length prefix
                    case 5: // noise
                        for (auto& byte : header)
                            byte = random.next();
                        break;
                    case 6: header.resize(header.size() - 1); break;
                    default: break; // unchanged: decodes
                    }
                    size_t textLength = 0, bodyLength = 0;
                    int status = NCTS_EntryDecode("", "Resource", "", entry.identifier.c_str(), salt, recordTimestampMs, header.data(), header.size(), entry.record.data() + entry.headerLength, entry.record.size() - entry.headerLength, nullptr, buffers.text.data(), buffers.text.size(), &textLength, buffers.body.data(), buffers.body.size(), &bodyLength);
                    digest.add(static_cast<uint64_t>(status + 1));
                    ++(status ? entryFailures : entryDecodes);
                    if (!status)
                        digest.addText(buffers.text.data(), std::min(textLength, buffers.text.size()));
                    bytes += header.size();
                }
            }
            for (unsigned variant = 0; variant < 64; ++variant) {
                header.assign(subresources.record.begin(), subresources.record.begin() + subresources.headerLength);
                switch (variant % 5) {
                case 0: header[variant * 11 % header.size()] ^= 0xff; break;
                case 1: header.resize(header.size() - 1 - variant % 40); break;
                case 2: header.resize(variant % 9); break;
                case 3:
                    for (auto& byte : header)
                        byte = random.next();
                    break;
                default: break; // unchanged: decodes
                }
                SubresourcesRecord copy;
                copy.record = header;
                auto length = decodeSubresources(copy, header.size(), subresourcesText);
                digest.add(static_cast<uint64_t>(length + 1));
                ++(length < 0 ? subresourceFailures : subresourceDecodes);
                if (length > 0 && !(variant % 5))
                    digest.add(static_cast<uint64_t>(length));
                bytes += header.size();
            }
        }
        EXPECT_GT(entryDecodes, 0u);
        EXPECT_GT(entryFailures, 0u);
        EXPECT_GT(subresourceDecodes, 0u);
        EXPECT_GT(subresourceFailures, 0u);
        note("DecodeFailure: entries decoded %u failed %u, subresources decoded %u failed %u", entryDecodes, entryFailures, subresourceDecodes, subresourceFailures);
        return PassResult { digest.value(), bytes };
    });
}

// ---- ValidationDecisions: the store, retrieve and use decisions on 10,000 generated request and response pairs ----

struct DecisionPair {
    std::string url, method, requestHeaders, firstParty, responseHeaders, vary, mime;
    int policy, status;
    bool redirect;
    double timestampMs;
};

static std::vector<DecisionPair> makeDecisionPairs(unsigned count)
{
    Lcg random(77);
    static constexpr const char* requestCacheControl[] = { "", "", "", "", "Cache-Control: no-cache\n", "Cache-Control: max-age=0\n", "Cache-Control: max-stale=100000000000\n", "Cache-Control: max-stale\n", "Cache-Control: min-fresh=60\n", "Cache-Control: no-store\n", "Cache-Control: max-age=10000000000\n", "Pragma: no-cache\n", "If-None-Match: \"abc\"\n", "If-Modified-Since: Tue, 03 Dec 2019 08:00:00 GMT\n", "Range: bytes=0-99\n" };
    static constexpr const char* responseCacheControl[] = { "", "", "Cache-Control: max-age=0\n", "Cache-Control: max-age=3600\n", "Cache-Control: max-age=10000000000\n", "Cache-Control: public, max-age=10000000000\n", "Cache-Control: no-cache\n", "Cache-Control: no-store\n", "Cache-Control: max-age=60, stale-while-revalidate=10000000000\n", "Cache-Control: max-age=3600, stale-while-revalidate=60\n", "Cache-Control: private, max-age=10000000000\n", "Cache-Control: s-maxage=10000000000\n", "Cache-Control: public\n", "Cache-Control: immutable, max-age=10000000000\n", "Cache-Control: max-age=-1\n", "Cache-Control: max-age=2147483648\n", "Cache-Control: must-revalidate, max-age=10000000000\n", "Expires: Thu, 01 Jan 2100 00:00:00 GMT\n", "Expires: Wed, 01 Apr 2020 00:00:00 GMT\n", "Expires: 0\n" };
    static constexpr const char* validators[] = { "", "ETag: \"v1\"\n", "Last-Modified: Sat, 01 Jan 2000 00:00:00 GMT\n", "ETag: \"v1\"\nLast-Modified: Sat, 01 Jan 2000 00:00:00 GMT\n" };
    static constexpr const char* varyHeaders[] = { "", "", "Vary: Accept-Encoding\n", "Vary: Accept-Encoding, Accept-Language\n", "Vary: Cookie\n", "Vary: *\n", "Vary: Origin\n" };
    static constexpr int statuses[] = { 200, 200, 200, 200, 200, 203, 204, 206, 300, 301, 302, 303, 304, 307, 308, 404, 405, 410, 414, 500, 503, 100 };
    static constexpr const char* methods[] = { "GET", "GET", "GET", "GET", "GET", "GET", "POST", "HEAD", "PUT", "OPTIONS" };
    static constexpr const char* mimes[] = { "text/javascript", "text/html", "image/png", "application/json", "video/mp4", "audio/mpeg", "text/css" };
    static constexpr int policies[] = { 0, 0, 0, 0, 1, 2, 3, 5 };
    std::vector<DecisionPair> pairs;
    for (unsigned i = 0; i < count; ++i) {
        DecisionPair pair;
        unsigned r1 = random.next(), r2 = random.next(), r3 = random.next(), r4 = random.next(), r5 = random.next(), r6 = random.next();
        pair.url = (!(r1 % 40) ? "ftp://example.com/f" : !(r1 % 9) ? "http://example.com/p" : "https://example.com/p") + std::to_string(i) + (r1 % 17 == 1 ? "#frag" : "");
        pair.method = methods[r1 % 10];
        pair.requestHeaders = requestCacheControl[r2 % 15];
        if (!(r2 % 11))
            pair.requestHeaders += "Cookie: a=b\n";
        pair.policy = policies[r3 % 8];
        pair.status = statuses[r4 % 22];
        pair.mime = mimes[r4 / 22 % 7];
        pair.responseHeaders = "Date: Mon, 02 Mar 2020 10:00:00 GMT\n";
        pair.responseHeaders += responseCacheControl[r5 % 20];
        pair.responseHeaders += validators[r5 / 20 % 4];
        pair.responseHeaders += varyHeaders[r6 % 7];
        if (!(r6 % 13))
            pair.responseHeaders += "Age: 100\n";
        if (pair.status >= 300 && pair.status < 400 && pair.status != 304)
            pair.responseHeaders += "Location: https://example.com/next\n";
        if (!(r6 % 5))
            pair.vary = "Accept-Encoding: gzip\nAccept-Language: en\n";
        else if (r6 % 5 == 1)
            pair.vary = "Cookie: a=b\n";
        pair.redirect = pair.status >= 300 && pair.status < 400 && !(r6 % 3);
        // The entry's record timestamp: the response's date, plus a second.
        pair.timestampMs = 1583143201000.0;
        pairs.push_back(WTF::move(pair));
    }
    return pairs;
}

TEST(NetworkCacheBench, ValidationDecisions)
{
    ensureSession();
    auto pairs = makeDecisionPairs(10000);
    runShape("ValidationDecisions"_s, 0xb98fd6ecee73facfull, [&] {
        Digest digest;
        uint64_t bytes = 0;
        unsigned storeSeen[16] = { }, retrieveSeen[16] = { }, useSeen[16] = { };
        for (auto& pair : pairs) {
            NCTSRequest request { pair.url.c_str(), pair.method.c_str(), pair.requestHeaders.c_str(), "https://example.com/", pair.policy, -1, 0, 1 };
            NCTSResponse response { pair.url.c_str(), pair.mime.c_str(), pair.status, pair.responseHeaders.c_str() };
            int store = NCTS_StoreDecision(&request, &response, 1000);
            int retrieve = NCTS_RetrieveDecision(&request);
            int use = NCTS_UseDecision(sessionID, &request, &response, pair.vary.c_str(), pair.timestampMs, 0, pair.redirect);
            digest.add(static_cast<uint64_t>(store + 2) | static_cast<uint64_t>(retrieve + 2) << 8 | static_cast<uint64_t>(use + 2) << 16);
            bytes += pair.url.size() + pair.requestHeaders.size() + pair.responseHeaders.size() + pair.vary.size();
            ++storeSeen[(store + 2) & 15];
            ++retrieveSeen[(retrieve + 2) & 15];
            ++useSeen[(use + 2) & 15];
        }
        // Every decision class the generator is meant to reach.
        auto distinct = [](unsigned (&seen)[16]) {
            return std::count_if(std::begin(seen), std::end(seen), [](unsigned n) {
                return n;
            });
        };
        EXPECT_GE(distinct(storeSeen), 9);
        EXPECT_GE(distinct(retrieveSeen), 3);
        EXPECT_GE(distinct(useSeen), hasNetworkSession ? 6 : 1);
        for (unsigned d = 0; d < 12; ++d)
            note("ValidationDecisions decision %d: store %u retrieve %u use %u", static_cast<int>(d) - 2, storeSeen[d], retrieveSeen[d], useSeen[d]);
        return PassResult { digest.value(), bytes };
    });
}

// ---- StoreRetrieve: small records through Cache::store and retrieve, update, remove, a reopened cache ----

TEST(NetworkCacheBench, StoreRetrieve)
{
    ensureSession();
    constexpr unsigned count = 300;
    Lcg random(21);
    std::vector<std::string> urls, bodies, headers;
    for (unsigned i = 0; i < count; ++i) {
        urls.push_back(urlFor(i));
        bodies.push_back(textBody(random, random.range(200, 3500)));
        headers.push_back(typicalHeaders(i, bodies.back().size()));
    }
    RetrieveBuffers buffers;
    runShape("StoreRetrieve"_s, 0x31fcbac61367f70cull, [&] {
        Digest digest;
        uint64_t bytes = 0;
        retrievesFound = retrievesMissed = 0;
        auto directory = makeTemporaryDirectory();
        auto cache = openCache(directory);
        EXPECT_NE(cache, 0u);
        for (unsigned i = 0; i < count; ++i) {
            auto request = requestFor(urls[i]);
            NCTSResponse response { urls[i].c_str(), "text/javascript", 200, headers[i].c_str() };
            digest.add(static_cast<uint64_t>(NCTS_CacheStore(cache, &request, &response, reinterpret_cast<const uint8_t*>(bodies[i].data()), bodies[i].size()) + 1));
            bytes += bodies[i].size();
        }
        // Retrieves see the pending and active writes, then the files.
        for (unsigned i = 0; i < count; ++i)
            digest.add(static_cast<uint64_t>(retrieveAndDigest(cache, urls[i], 2, buffers, digest, bytes)));
        for (unsigned i = 0; i < 60; ++i)
            digest.add(static_cast<uint64_t>(retrieveAndDigest(cache, "https://miss.example.com/" + std::to_string(i), 2, buffers, digest, bytes)));
        EXPECT_EQ(waitForRecords(cache, count), count);
        // Update 40 with a validating response; remove 40 others.
        for (unsigned i = 0; i < 40; ++i) {
            auto request = requestFor(urls[i]);
            NCTSResponse response { urls[i].c_str(), "text/javascript", 304, "Cache-Control: max-age=7200\nX-Updated: yes\n" };
            digest.add(static_cast<uint64_t>(NCTS_CacheUpdate(cache, &request, &response) + 1));
        }
        for (unsigned i = 100; i < 140; ++i) {
            auto request = requestFor(urls[i]);
            NCTS_CacheRemove(cache, &request);
        }
        // The removes delete their files in the background: wait for them before a retrieve of a removed key,
        // which would otherwise find the file or miss by timing.
        EXPECT_EQ(waitForRecords(cache, count - 40), count - 40);
        for (unsigned i = 0; i < 160; ++i)
            retrieveAndDigest(cache, urls[i], 2, buffers, digest, bytes);
        EXPECT_EQ(waitForRecords(cache, count - 40), count - 40);
        // A reopened cache: the files, the bloom filter and the size counted afresh.
        NCTS_CacheClose(cache);
        cache = openCache(directory);
        EXPECT_NE(cache, 0u);
        for (unsigned i = 0; i < count; i += 3)
            digest.add(static_cast<uint64_t>(retrieveAndDigest(cache, urls[i], 2, buffers, digest, bytes)));
        NCTS_CacheClear(cache);
        digest.add(static_cast<uint64_t>(retrieveAndDigest(cache, urls[1], 2, buffers, digest, bytes)));
        NCTS_CacheClose(cache);
        FileSystem::deleteNonEmptyDirectory(directory);
        note("%s: retrieves found %u missed %u", "StoreRetrieve", retrievesFound, retrievesMissed);
        return PassResult { digest.value(), bytes };
    });
}

// ---- RedirectEntry: redirect records through storeRedirect and retrieve ----

TEST(NetworkCacheBench, RedirectEntry)
{
    ensureSession();
    constexpr unsigned count = 150;
    RetrieveBuffers buffers;
    runShape("RedirectEntry"_s, 0xbd5e88b8a4c32ddfull, [&] {
        Digest digest;
        uint64_t bytes = 0;
        retrievesFound = retrievesMissed = 0;
        auto directory = makeTemporaryDirectory();
        auto cache = openCache(directory);
        EXPECT_NE(cache, 0u);
        std::vector<std::string> urls, targets, headers;
        for (unsigned i = 0; i < count; ++i) {
            urls.push_back("https://example.com/old/" + std::to_string(i));
            targets.push_back("https://example.com/new/" + std::to_string(i) + (!(i % 4) ? "#section" : ""));
            headers.push_back("Location: " + targets.back() + "\nCache-Control: max-age=10000000000\nDate: Mon, 02 Mar 2020 10:00:00 GMT\n");
        }
        for (unsigned i = 0; i < count; ++i) {
            auto request = requestFor(urls[i]);
            auto redirect = requestFor(targets[i]);
            NCTSResponse response { urls[i].c_str(), "text/html", i % 3 ? 301 : 302, headers[i].c_str() };
            digest.add(static_cast<uint64_t>(NCTS_CacheStoreRedirect(cache, &request, &response, &redirect) + 1));
        }
        for (unsigned i = 0; i < count; ++i) {
            digest.add(static_cast<uint64_t>(retrieveAndDigest(cache, urls[i], 2, buffers, digest, bytes)));
            // With a fragment on the request, and (where there is a network session) through the use decision.
            digest.add(static_cast<uint64_t>(retrieveAndDigest(cache, urls[i] + "#frag", 2, buffers, digest, bytes)));
            if (hasNetworkSession)
                digest.add(static_cast<uint64_t>(retrieveAndDigest(cache, urls[i] + (i % 2 ? "#frag" : ""), 0, buffers, digest, bytes)));
        }
        EXPECT_EQ(waitForRecords(cache, count), count);
        NCTS_CacheClose(cache);
        cache = openCache(directory);
        for (unsigned i = 0; i < count; i += 2)
            retrieveAndDigest(cache, urls[i], 2, buffers, digest, bytes);
        NCTS_CacheClose(cache);
        FileSystem::deleteNonEmptyDirectory(directory);
        note("%s: retrieves found %u missed %u", "RedirectEntry", retrievesFound, retrievesMissed);
        return PassResult { digest.value(), bytes };
    });
}

// ---- Traverse: a cache of 5,000 records ----

struct TraverseState {
    uint64_t sum { 0 };
    uint64_t count { 0 };
    uint64_t bytes { 0 };
};

TEST(NetworkCacheBench, Traverse)
{
    ensureSession();
    constexpr unsigned count = 5000;
    Lcg random(31);
    auto directory = makeTemporaryDirectory();
    auto cache = openCache(directory);
    ASSERT_NE(cache, 0u);
    for (unsigned i = 0; i < count; ++i) {
        auto url = urlFor(i);
        auto body = textBody(random, 700 + i % 600);
        auto responseHeaders = typicalHeaders(i, body.size());
        auto request = requestFor(url);
        NCTSResponse response { url.c_str(), "text/javascript", 200, responseHeaders.c_str() };
        NCTS_CacheStore(cache, &request, &response, reinterpret_cast<const uint8_t*>(body.data()), body.size());
        if (!(i % 256))
            NCTS_CacheFlush(cache);
    }
    ASSERT_EQ(waitForRecords(cache, count), count);
    runShape("Traverse"_s, 0xe1f2e2be0dd0b0bcull, [&] {
        TraverseState state;
        // The traversal's order is the directory's: the digest sums over the records.
        NCTS_CacheTraverse(cache, [](void* context, const char* url, const uint8_t* keyHash, size_t headerLength, size_t bodyLength) {
            auto& state = *static_cast<TraverseState*>(context);
            Digest digest;
            digest.add(url, strlen(url));
            digest.add(keyHash, 20);
            digest.add(static_cast<uint64_t>(headerLength) << 32 | bodyLength);
            state.sum += digest.value();
            ++state.count;
            state.bytes += headerLength + bodyLength;
        }, &state);
        note("Traverse: %llu records", static_cast<unsigned long long>(state.count));
        Digest digest;
        digest.add(state.sum);
        digest.add(state.count);
        return PassResult { digest.value(), state.bytes };
    });
    NCTS_CacheClose(cache);
    FileSystem::deleteNonEmptyDirectory(directory);
}

// ---- BlobStore: bodies over the blob threshold (a page), through BlobStorage and through the cache ----

TEST(NetworkCacheBench, BlobStore)
{
    ensureSession();
    Lcg random(41);
    constexpr unsigned blobCount = 24, recordCount = 40;
    std::vector<std::string> blobs, urls, bodies, headers;
    for (unsigned i = 0; i < blobCount; ++i)
        blobs.push_back(textBody(random, random.range(5000, 200000)));
    for (unsigned i = 0; i < recordCount; ++i) {
        urls.push_back(urlFor(1000 + i));
        bodies.push_back(textBody(random, random.range(6000, 120000)));
        headers.push_back(typicalHeaders(i, bodies.back().size()));
    }
    RetrieveBuffers buffers;
    std::vector<uint8_t> out(256 << 10);
    runShape("BlobStore"_s, 0x3a51999a36c944bcull, [&] {
        Digest digest;
        uint64_t bytes = 0;
        retrievesFound = retrievesMissed = 0;
        auto directory = makeTemporaryDirectory();
        // BlobStorage directly: add, share count, get; the same data added again to the same record path.
        for (unsigned i = 0; i < blobCount; ++i) {
            auto blobDirectory = FileSystem::pathByAppendingComponent(directory, String::number(i));
            uint8_t hash[20];
            unsigned shareCount = 0;
            for (unsigned again = 0; again < 2; ++again) {
                auto length = NCTS_BlobAddGet(reinterpret_cast<const char*>(blobDirectory.utf8().span().data()), salt, reinterpret_cast<const uint8_t*>(blobs[i].data()), blobs[i].size(), hash, out.data(), out.size(), &shareCount);
                digest.add(static_cast<uint64_t>(length + 1) | static_cast<uint64_t>(shareCount) << 40);
                digest.add(hash, 20);
                if (length > 0)
                    digest.add(out.data(), length);
                bytes += blobs[i].size();
            }
        }
        // Through the cache: bodies over the threshold are stored as blobs and read back mapped.
        auto cacheDirectory = FileSystem::pathByAppendingComponent(directory, "cache"_s);
        auto cache = openCache(cacheDirectory);
        EXPECT_NE(cache, 0u);
        for (unsigned i = 0; i < recordCount; ++i) {
            auto request = requestFor(urls[i]);
            NCTSResponse response { urls[i].c_str(), "text/javascript", 200, headers[i].c_str() };
            digest.add(static_cast<uint64_t>(NCTS_CacheStore(cache, &request, &response, reinterpret_cast<const uint8_t*>(bodies[i].data()), bodies[i].size()) + 1));
            bytes += bodies[i].size();
        }
        EXPECT_EQ(waitForRecords(cache, recordCount), recordCount);
        for (unsigned i = 0; i < recordCount; ++i)
            retrieveAndDigest(cache, urls[i], 2, buffers, digest, bytes);
        NCTS_CacheClose(cache);
        cache = openCache(cacheDirectory);
        for (unsigned i = 0; i < recordCount; i += 2)
            retrieveAndDigest(cache, urls[i], 2, buffers, digest, bytes);
        NCTS_CacheClose(cache);
        FileSystem::deleteNonEmptyDirectory(directory);
        note("%s: retrieves found %u missed %u", "BlobStore", retrievesFound, retrievesMissed);
        return PassResult { digest.value(), bytes };
    });
}

// ---- RetrieveCorrupt: records on disk damaged in five ways, read back (the storage's error path) ----

static void collectFiles(const String& path, Vector<String>& files)
{
    for (auto& name : FileSystem::listDirectory(path)) {
        auto full = FileSystem::pathByAppendingComponent(path, name);
        auto type = FileSystem::fileType(full);
        if (type && *type == FileSystem::FileType::Directory)
            collectFiles(full, files);
        else if (type && full.contains("Records"_s))
            files.append(full);
    }
}

TEST(NetworkCacheBench, RetrieveCorrupt)
{
    ensureSession();
    constexpr unsigned count = 60;
    Lcg random(51);
    std::vector<std::string> urls, bodies, headers;
    for (unsigned i = 0; i < count; ++i) {
        urls.push_back(urlFor(2000 + i));
        bodies.push_back(textBody(random, random.range(300, 3000)));
        headers.push_back(typicalHeaders(i, bodies.back().size()));
    }
    RetrieveBuffers buffers;
    runShape("RetrieveCorrupt"_s, 0x2023b24131a012bbull, [&] {
        Digest digest;
        uint64_t bytes = 0;
        retrievesFound = retrievesMissed = 0;
        auto directory = makeTemporaryDirectory();
        auto cache = openCache(directory);
        EXPECT_NE(cache, 0u);
        for (unsigned i = 0; i < count; ++i) {
            auto request = requestFor(urls[i]);
            NCTSResponse response { urls[i].c_str(), "text/javascript", 200, headers[i].c_str() };
            NCTS_CacheStore(cache, &request, &response, reinterpret_cast<const uint8_t*>(bodies[i].data()), bodies[i].size());
        }
        EXPECT_EQ(waitForRecords(cache, count), count);
        NCTS_CacheClose(cache);
        Vector<String> files;
        collectFiles(directory, files);
        EXPECT_EQ(files.size(), count);
        std::sort(files.begin(), files.end(), [](auto& a, auto& b) {
            return codePointCompareLessThan(a, b);
        });
        unsigned damaged = 0;
        for (unsigned i = 0; i < files.size(); ++i) {
            auto contents = FileSystem::readEntireFile(files[i]);
            if (!contents || contents->size() < 64)
                continue;
            auto& bytesOfFile = *contents;
            switch (i % 5) {
            case 0: bytesOfFile[0] ^= 0xff; break; // the metadata (the version: byte 8 is a bool, and the persistence decoder's read of a bool other than 0 or 1 is undefined, so Debug and Release answer differently)
            case 1: bytesOfFile[bytesOfFile.size() / 2] ^= 0x10; break; // the middle
            case 2: bytesOfFile.shrink(20); break; // cut inside the metadata
            case 3: bytesOfFile.shrink(bytesOfFile.size() / 2); break; // cut in the header or body
            default: bytesOfFile.append(std::span<const uint8_t> { reinterpret_cast<const uint8_t*>("garbage"), 7 }); break; // longer than its record
            }
            FileSystem::overwriteEntireFile(files[i], bytesOfFile.span());
            ++damaged;
            bytes += bytesOfFile.size();
        }
        digest.add(static_cast<uint64_t>(damaged));
        cache = openCache(directory);
        EXPECT_NE(cache, 0u);
        for (unsigned i = 0; i < count; ++i)
            retrieveAndDigest(cache, urls[i], 2, buffers, digest, bytes);
        NCTS_CacheClose(cache);
        FileSystem::deleteNonEmptyDirectory(directory);
        note("%s: retrieves found %u missed %u", "RetrieveCorrupt", retrievesFound, retrievesMissed);
        return PassResult { digest.value(), bytes };
    });
}

} // namespace NetworkCacheBench

} // namespace TestWebKitAPI

#endif // OS(WINDOWS)
