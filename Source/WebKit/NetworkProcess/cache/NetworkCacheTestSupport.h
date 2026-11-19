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

// A small test-support layer over the network cache's own entry points, for the TestNetworkCache
// tests. Plain C types only (no WebKit headers needed by the caller). Main thread only; every
// asynchronous operation is awaited by spinning the main RunLoop. See NetworkCacheTestSupport.cpp.

#pragma once

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#if defined(BUILDING_WebKit)
#define NCTS_EXPORT __declspec(dllexport)
#else
#define NCTS_EXPORT __declspec(dllimport)
#endif
#else
#define NCTS_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Headers are one string: "Name: value\n" per field. Strings are UTF-8, null terminated, unless a function says UTF-16.
typedef struct NCTSRequest {
    const char* url;
    const char* method; // null: GET
    const char* headers; // null: none
    const char* firstPartyURL; // null: none
    int cachePolicy; // WebCore::ResourceRequestCachePolicy value
    int priority; // WebCore::ResourceLoadPriority value, -1: default
    int blockThirdPartyStorage;
    int allowCookies;
} NCTSRequest;

typedef struct NCTSResponse {
    const char* url;
    const char* mimeType;
    int status;
    const char* headers; // null: none
} NCTSResponse;

typedef struct NCTSRetrieveResult {
    int found;
    int retrieveDecision; // -1: none
    int speculativeLoadDecision; // -1: none
    int useDecision; // -1: none
    int needsValidation;
    size_t bodyLength; // the body's full length, whatever the buffer capacity
} NCTSRetrieveResult;

typedef void (*NCTSTraverseCallback)(void* context, const char* url, const uint8_t* keyHash, size_t headerLength, size_t bodyLength);
// One record of NCTS_CacheTraverseEx: every record type. bodyHash is the record's body hash as text; shareCount is 0 unless flag 2; worth is 0 unless flag 1.
// timestampMs and lastAccessMs are wall clock times; worth reads the clock and the files' times.
typedef void (*NCTSTraverseExCallback)(void* context, const char* type, const char* partition, const char* identifier, const uint8_t* keyHash, double timestampMs, size_t headerLength, size_t bodyLength, const char* bodyHash, unsigned shareCount, double worth, double lastAccessMs);

// Session: installs the storage session for `sessionID` in the NetworkProcess singleton (what the cache's vary check needs).
// withNetworkSession != 0 also creates the NetworkSession (what a non-history use decision needs). Refused (returns 0) where ENABLE(WEB_PUSH_NOTIFICATIONS): creating it needs the parent process connection.
// Returns 1 on success.
NCTS_EXPORT int NCTS_InstallSession(uint64_t sessionID, int withNetworkSession);

// Cache. open: options bit 0 TestingMode (the storage avoids randomness: it never shrinks), bit 1 RegisterNotify (refused: 0 is returned,
// the cache's notification handler keeps a raw pointer to the cache), bit 2 SpeculativeRevalidation. Returns a handle, 0 on failure.
NCTS_EXPORT uint64_t NCTS_CacheOpen(const char* path, unsigned options, uint64_t sessionID);
NCTS_EXPORT void NCTS_CacheClose(uint64_t cache);
// Returns 1 if the cache stored the entry (its store decision was Yes), 0 if not; does not wait for the write (a retrieve after it sees it). -1: refused (the cache's capacity is 0).
NCTS_EXPORT int NCTS_CacheStore(uint64_t cache, const NCTSRequest*, const NCTSResponse*, const uint8_t* body, size_t bodyLength);
// Returns 1 if the cache stored a redirect entry.
NCTS_EXPORT int NCTS_CacheStoreRedirect(uint64_t cache, const NCTSRequest*, const NCTSResponse*, const NCTSRequest* redirectRequest);
// Retrieves and awaits. Writes the entry's description (UTF-8 text) to `text` and its body to `body`, up to the capacities;
// the lengths needed are in *textLength and result->bodyLength. Returns 0 on success, -1 on a refused call (see header).
NCTS_EXPORT int NCTS_CacheRetrieve(uint64_t cache, const NCTSRequest*, NCTSRetrieveResult*, char* text, size_t textCapacity, size_t* textLength, uint8_t* body, size_t bodyCapacity);
// Retrieves the stored entry (history policy), updates it with a validating response, awaits the write. 1 if updated.
NCTS_EXPORT int NCTS_CacheUpdate(uint64_t cache, const NCTSRequest*, const NCTSResponse* validatingResponse);
// Waits until no write of the cache is pending dispatch (a dispatched write finishes on the IO queue, unobservably).
NCTS_EXPORT void NCTS_CacheFlush(uint64_t cache);
NCTS_EXPORT void NCTS_CacheRemove(uint64_t cache, const NCTSRequest*);
// Traverses all resource records, awaits the end. Returns the number of records delivered.
NCTS_EXPORT size_t NCTS_CacheTraverse(uint64_t cache, NCTSTraverseCallback, void* context);
// Removes everything and awaits.
NCTS_EXPORT void NCTS_CacheClear(uint64_t cache);

// The cache's decisions, on their own (no storage). StoreDecision / RetrieveDecision / UseDecision enum values (NetworkCache.h), -1 when refused.
// StoreDecision reads the wall clock (the unlikely-to-reuse test): inputs near its edges depend on the time of the call.
NCTS_EXPORT int NCTS_StoreDecision(const NCTSRequest*, const NCTSResponse*, size_t bodySize);
NCTS_EXPORT int NCTS_RetrieveDecision(const NCTSRequest*);
// UseDecision for an entry made from the response (and `varyingHeaders` text, "Name: value\n" lines; hasRedirect: a redirect entry
// whose redirect request is the request itself) whose record timestamp is `timestampMs`, against the request. The session `sessionID`
// must be installed (NCTS_InstallSession, with a network session for any policy but ReturnCacheDataElseLoad/DontLoad); -1 if not.
// nowMs is the time of the decision on the clock of timestampMs: the entry is stamped so that its age at the call is nowMs - timestampMs
// (the facade moves the record's timestamp, the Date, Expires and Last-Modified headers stay as given), so a decision does not
// depend on the wall clock but for the microseconds between the stamp and the decision: give ages off the whole second.
// nowMs 0 is the real clock: the age is the wall clock at the call minus timestampMs. Not finite: -1.
NCTS_EXPORT int NCTS_UseDecision(uint64_t sessionID, const NCTSRequest*, const NCTSResponse*, const char* varyingHeaders, double timestampMs, double nowMs, int hasRedirect);

// Disk state. Waits until every write is on disk and no storage scan or shrink is running (stronger than NCTS_CacheFlush); -1 after 60 s.
NCTS_EXPORT int NCTS_CacheSync(uint64_t cache);
// The records directory in use ("<path>/Version N/Records"); writes UTF-8 up to capacity, returns the length needed, -1 for a bad handle.
NCTS_EXPORT long long NCTS_CacheRecordsPath(uint64_t cache, char* out, size_t capacity);
// Traverses every record of every type with the storage's flags (1 ComputeWorth, 2 ShareCount), awaits the end, returns the number delivered.
NCTS_EXPORT size_t NCTS_CacheTraverseEx(uint64_t cache, unsigned flags, NCTSTraverseExCallback, void* context);

// Compression dictionaries. Store: the cache's own store decision applies; destinationBits are the DestinationSet bits (1 << FetchOptions::Destination).
// Returns 1, 0 if refused, -1 if the cache's capacity is 0. Match: the best dictionary for the request and FetchOptions::Destination value,
// text lists its key, hash and id, body the dictionary bytes (up to the capacities, lengths needed in the outs). 1 found, 0 none, -1 refused.
NCTS_EXPORT int NCTS_CacheStoreCompressionDictionary(uint64_t cache, const NCTSRequest*, const NCTSResponse*, const uint8_t* body, size_t bodyLength, const char* match, const char* id, uint32_t destinationBits, double expirationMs);
NCTS_EXPORT int NCTS_CacheCompressionDictionaryMatch(uint64_t cache, const NCTSRequest*, unsigned destination, char* text, size_t textCapacity, size_t* textLength, uint8_t* body, size_t bodyCapacity, size_t* bodyLength);

// The prefetch cache (one per process). Take returns 1 and the response's description and body, 0 if none, -1 refused.
NCTS_EXPORT int NCTS_PrefetchStore(const NCTSRequest*, const NCTSResponse*, const uint8_t* body, size_t bodyLength);
NCTS_EXPORT int NCTS_PrefetchTake(const char* url, char* text, size_t textCapacity, size_t* textLength, uint8_t* body, size_t bodyCapacity, size_t* bodyLength);

// Key. Strings are UTF-16 (code units, so lone surrogates and non-ASCII reach the hash), salt is 8 bytes.
// Writes the hash and partition hash (20 bytes each) and returns the hash string's length written to hashString (40 chars, ASCII, uppercase hex; capacity >= 40).
NCTS_EXPORT size_t NCTS_KeyHash(const char16_t* partition, size_t partitionLength, const char16_t* type, size_t typeLength, const char16_t* range, size_t rangeLength, const char16_t* identifier, size_t identifierLength, const uint8_t* salt, int includesCredentials, uint8_t* hash, uint8_t* partitionHash, char* hashString);
// Key::stringToHash; returns 1 and the 20 bytes on success.
NCTS_EXPORT int NCTS_KeyStringToHash(const char16_t* string, size_t length, uint8_t* hash);

// Key coder: encode writes the key's persistent bytes (returns the length needed); decode describes a key from bytes (partition, type, range,
// identifier, hash, partition hash, isNull, the key's hash-table hash), returns the text length needed, -1 on failure.
NCTS_EXPORT long long NCTS_KeyEncode(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, int includesCredentials, uint8_t* out, size_t outCapacity);
NCTS_EXPORT long long NCTS_KeyDecode(const uint8_t* bytes, size_t length, char* text, size_t textCapacity);
// Decodes bytes as `kind` (0 Key, 1 SHA-1 digest, 2 byte vector, 3 SubresourceInfo, 4 vector of header name/value pairs) and encodes the value again.
// Returns the length needed, -1 if the decode fails, -2 if bytes are left over.
NCTS_EXPORT long long NCTS_CoderRoundTrip(int kind, const uint8_t* bytes, size_t length, uint8_t* out, size_t outCapacity);

// Storage record files, with the salt of the open cache. Encode writes what the storage writes: metadata || header [|| body]; blobHash non-null: the body is a
// blob with that hash and is left out. Returns the length needed. Read decodes file bytes as the storage does (both hashes, the version, a timestamp in the
// future fails) and describes the record (key, timestamp, header and body hex, body hash); returns the text length needed, -1 if the record is refused.
NCTS_EXPORT long long NCTS_RecordEncode(uint64_t cache, const char* partition, const char* type, const char* range, const char* identifier, double timestampMs, const uint8_t* header, size_t headerLength, const uint8_t* body, size_t bodyLength, const uint8_t* blobHash, uint8_t* out, size_t outCapacity);
NCTS_EXPORT long long NCTS_RecordRead(uint64_t cache, const uint8_t* file, size_t length, char* text, size_t textCapacity);
// The response URL of an entry record's header (as the storage's traversal reads it): text length needed, -1 if the decode fails.
NCTS_EXPORT long long NCTS_EntryDecodeResponseURL(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, double timestampMs, const uint8_t* header, size_t headerLength, char* text, size_t textCapacity);
// Compression dictionary record: decode describes every field (match, id, destination bits, expiration, SHA-256 hash, body length); encode writes header||body
// (the record's timestamp is the wall clock). Both return the length needed, -1 on failure.
NCTS_EXPORT long long NCTS_CompressionDictionaryDecode(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, double timestampMs, const uint8_t* header, size_t headerLength, const uint8_t* body, size_t bodyLength, char* text, size_t textCapacity);
NCTS_EXPORT long long NCTS_CompressionDictionaryEncode(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, const char* match, const char* id, uint32_t destinationBits, double expirationMs, const uint8_t* body, size_t bodyLength, uint8_t* out, size_t outCapacity, size_t* headerLength);

// Entry record: encode builds an Entry (key from the parts, varyingHeaders as headers text) and writes header||body to `out`.
// Returns header+body length needed (-1 on failure); *headerLength gets the header's length; bodyHash (20 bytes) and *hasBodyHash its blob hash.
NCTS_EXPORT long long NCTS_EntryEncode(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, const NCTSResponse*, const char* varyingHeaders, const uint8_t* body, size_t bodyLength, uint8_t* out, size_t outCapacity, size_t* headerLength, uint8_t* bodyHash, int* hasBodyHash);
// Decodes a record (key from the parts, timestamp in ms since the epoch). Description text and body as NCTS_CacheRetrieve. Returns 0, or -1 if decoding fails.
NCTS_EXPORT int NCTS_EntryDecode(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, double timestampMs, const uint8_t* header, size_t headerLength, const uint8_t* body, size_t bodyLength, const uint8_t* bodyHash, char* text, size_t textCapacity, size_t* textLength, uint8_t* bodyOut, size_t bodyOutCapacity, size_t* bodyOutLength);

// Subresources record: decode writes a description (UTF-8 text) of the entry; returns the text length needed, -1 if decoding fails.
NCTS_EXPORT long long NCTS_SubresourcesDecode(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, double timestampMs, const uint8_t* header, size_t headerLength, char* text, size_t textCapacity);
// Subresources record encode from loads (one URL per line in `urls`); writes header||body, returns length needed, -1 on failure.
NCTS_EXPORT long long NCTS_SubresourcesEncode(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, const char* urls, uint8_t* out, size_t outCapacity, size_t* headerLength);

// As NCTS_SubresourcesEncode, one load per line "url|firstPartyURL|priority|Name: value|...", all but the url optional; rounds >= 2 makes the infos
// non-transient (the entry sees the same loads again). Returns the length needed, -1 on failure.
NCTS_EXPORT long long NCTS_SubresourcesEncodeEx(const char* partition, const char* type, const char* range, const char* identifier, const uint8_t* salt, const char* loadLines, int rounds, uint8_t* out, size_t outCapacity, size_t* headerLength);

// Blob storage over a directory `path` (created if missing). Blob data is hashed with SHA-1 over salt then bytes.
// add returns the blob's hash (20 bytes) in `hash` and its share count; the blob data read back goes to `out`.
NCTS_EXPORT long long NCTS_BlobAddGet(const char* directory, const uint8_t* salt, const uint8_t* data, size_t length, uint8_t* hash, uint8_t* out, size_t outCapacity, unsigned* shareCount);

#ifdef __cplusplus
}
#endif
