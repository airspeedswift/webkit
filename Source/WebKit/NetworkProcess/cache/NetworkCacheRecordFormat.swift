// Copyright (C) 2014-2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

import WebKit_Internal.NetworkCacheCxx
import wtf

// The record file: the metadata (each field through its own typed coder call, so each keeps its type salt in the
// checksum), then the header, then the body unless it is stored as a blob.

/// The metadata's fields, decoded over the first segment of `fileData`; nil at the first field that fails or at a bad
/// checksum.
private func decodeRecordMetaData(_ fileData: borrowing WebKit.NetworkCache.Data) -> WebKit.NetworkCache.StorageRecordMetaData? {
    // Before span(), which makes a Cocoa dispatch_data contiguous.
    let segmentSize = WebKit.NetworkCache.firstSegmentSize(fileData)
    if segmentSize == 0 {
        return nil
    }
    let fileBytes: Span<UInt8> = fileData.span()
    let segment = fileBytes.extracting(0..<segmentSize)
    var decoder = WTF.Persistence.makeDecoder(segment)

    var metaData = WebKit.NetworkCache.StorageRecordMetaData()
    guard WebKit.NetworkCache.networkCacheDecode(&decoder, &metaData.cacheStorageVersion),
        WebKit.NetworkCache.networkCacheDecode(&decoder, &metaData.key),
        WebKit.NetworkCache.networkCacheDecode(&decoder, &metaData.timeStamp),
        WebKit.NetworkCache.networkCacheDecode(&decoder, &metaData.headerHash),
        WebKit.NetworkCache.networkCacheDecode(&decoder, &metaData.headerSize),
        WebKit.NetworkCache.networkCacheDecode(&decoder, &metaData.bodyHash),
        WebKit.NetworkCache.networkCacheDecode(&decoder, &metaData.bodySize),
        WebKit.NetworkCache.networkCacheDecode(&decoder, &metaData.isBodyInline),
        decoder.verifyChecksum()
    else {
        return nil
    }

    metaData.headerOffset = UInt64(decoder.currentOffset())
    return metaData
}

private func digestsEqual(_ a: borrowing WTF.SHA1.Digest, _ b: borrowing WTF.SHA1.Digest) -> Bool {
    a.elementsEqual(b)
}

extension WebKit.NetworkCache.RecordFormat {
    @cxx
    @implementation
    static func decodeRecordHeader(
        _ fileData: WebKit.NetworkCache.Data,
        _ salt: WebKit.NetworkCache.Salt
    ) -> WebKit.NetworkCache.OptionalDecodedRecordHeader {
        WebKit.NetworkCache.OptionalDecodedRecordHeader(optional: decodeRecordFileHeader(fileData, salt))
    }

    private static func decodeRecordFileHeader(
        _ fileData: borrowing WebKit.NetworkCache.Data,
        _ salt: borrowing WebKit.NetworkCache.Salt
    ) -> WebKit.NetworkCache.DecodedRecordHeader? {
        guard let metaData = decodeRecordMetaData(fileData) else {
            return nil
        }
        if metaData.cacheStorageVersion != WebKit.NetworkCache.Storage.version {
            return nil
        }
        // headerSize comes from the file and may exceed it. headerOffset is at most the size, so &- cannot wrap.
        let remaining = UInt64(fileData.size()) &- metaData.headerOffset
        let headerSize = min(metaData.headerSize, remaining)
        let headerData = fileData.subrange(Int(metaData.headerOffset), Int(headerSize))
        if !digestsEqual(metaData.headerHash, WebKit.NetworkCache.computeSHA1(headerData, salt)) {
            return nil
        }
        var result = WebKit.NetworkCache.DecodedRecordHeader()
        result.metaData = metaData
        result.headerData = headerData
        return result
    }

    @cxx
    @implementation
    static func readRecord(
        _ recordData: WebKit.NetworkCache.Data,
        _ salt: WebKit.NetworkCache.Salt
    ) -> WebKit.NetworkCache.OptionalDecodedRecord {
        WebKit.NetworkCache.OptionalDecodedRecord(optional: readRecordFile(recordData, salt))
    }

    private static func readRecordFile(
        _ recordData: borrowing WebKit.NetworkCache.Data,
        _ salt: WebKit.NetworkCache.Salt
    ) -> WebKit.NetworkCache.DecodedRecord? {
        guard let header = decodeRecordFileHeader(recordData, salt) else {
            return nil
        }

        // Sanity check against time stamps in future.
        if header.metaData.timeStamp.seconds > WTF.WallTime.nowSeconds {
            return nil
        }

        var result = WebKit.NetworkCache.DecodedRecord()
        if header.metaData.isBodyInline {
            // bodySize comes from the file, so the sum wraps; equality keeps the slice below inside the file.
            let bodyOffset = header.metaData.headerOffset &+ UInt64(header.headerData.size())
            if bodyOffset &+ header.metaData.bodySize != UInt64(recordData.size()) {
                return nil
            }
            let bodyData = recordData.subrange(Int(bodyOffset), Int(header.metaData.bodySize))
            if !digestsEqual(header.metaData.bodyHash, WebKit.NetworkCache.computeSHA1(bodyData, salt)) {
                return nil
            }
            result.bodyData = bodyData
        }
        result.header = header
        return result
    }

    @cxx
    @implementation
    static func encodeRecord(
        _ key: WebKit.NetworkCache.Key,
        _ timeStamp: WTF.WallTime,
        _ header: WebKit.NetworkCache.Data,
        _ body: WebKit.NetworkCache.Data,
        _ salt: WebKit.NetworkCache.Salt,
        _ hasBlob: Bool,
        _ blobHash: WTF.SHA1.Digest
    ) -> WebKit.NetworkCache.Data {
        let isBodyInline = !hasBlob
        let headerHash = WebKit.NetworkCache.computeSHA1(header, salt)
        let bodyHash = hasBlob ? blobHash : WebKit.NetworkCache.computeSHA1(body, salt)

        var encoder = WTF.Persistence.Encoder()
        WebKit.NetworkCache.networkCacheEncode(&encoder, UInt32(WebKit.NetworkCache.Storage.version))
        WebKit.NetworkCache.networkCacheEncode(&encoder, key)
        WebKit.NetworkCache.networkCacheEncode(&encoder, timeStamp)
        WebKit.NetworkCache.networkCacheEncode(&encoder, headerHash)
        WebKit.NetworkCache.networkCacheEncode(&encoder, UInt64(header.size()))
        WebKit.NetworkCache.networkCacheEncode(&encoder, bodyHash)
        WebKit.NetworkCache.networkCacheEncode(&encoder, UInt64(body.size()))
        WebKit.NetworkCache.networkCacheEncode(&encoder, isBodyInline)
        encoder.encodeChecksum()

        let encodedMetaData = WebKit.NetworkCache.dataFromEncoder(encoder)
        let headerData = WebKit.NetworkCache.concatenate(encodedMetaData, header)
        if isBodyInline {
            return WebKit.NetworkCache.concatenate(headerData, body)
        }
        return headerData
    }
}
