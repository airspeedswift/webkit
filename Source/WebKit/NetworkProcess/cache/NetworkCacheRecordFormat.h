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
#include <optional>
#include <wtf/SHA1.h>
#include <wtf/WallTime.h>

// The record file's format: its metadata, the header and the body that follow it. Defined in Swift
// (NetworkCacheRecordFormat.swift, @cxx @implementation).

namespace WebKit::NetworkCache {

struct StorageRecordMetaData {
    unsigned cacheStorageVersion { 0 };
    Key key;
    WallTime timeStamp;
    SHA1::Digest headerHash { };
    uint64_t headerSize { 0 };
    SHA1::Digest bodyHash { };
    uint64_t bodySize { 0 };
    bool isBodyInline { false };

    // Not encoded as a field. Header starts immediately after meta data.
    uint64_t headerOffset { 0 };
};

struct DecodedRecordHeader {
    StorageRecordMetaData metaData;
    Data headerData;
};

// bodyData is null for a blob record.
struct DecodedRecord {
    DecodedRecordHeader header;
    Data bodyData;
};

// Named for Swift, which cannot spell a std::optional (RecordFormat's @cxx @implementation).
using OptionalDecodedRecordHeader = std::optional<DecodedRecordHeader>;
using OptionalDecodedRecord = std::optional<DecodedRecord>;

struct RecordFormat {
    // The metadata, version and header hash of a record file.
    static std::optional<DecodedRecordHeader> decodeRecordHeader(Data fileData, Salt);
    // A whole record file read from disk: decodeRecordHeader, the time stamp, and the inline body and its hash.
    static std::optional<DecodedRecord> readRecord(Data recordData, Salt);
    // The record file for a record: the metadata, the header and, unless the body is in a blob, the body.
    static Data encodeRecord(Key, WallTime timeStamp, Data header, Data body, Salt, bool hasBlob, SHA1::Digest blobHash);
};

} // namespace WebKit::NetworkCache
