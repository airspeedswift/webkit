// Copyright (C) 2026 Igalia S.L. All rights reserved.
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

/// A dictionary registered by Use-As-Dictionary, stored beside the regular cache entry for the same URL.
///
/// A dictionary is found by matching its pattern against an outbound request rather than by retrieving its own URL, so
/// the record holds neither the response it arrived with nor anything else that only applies to a resource retrieved
/// by a request.
///
/// See https://www.rfc-editor.org/rfc/rfc9842#name-use-as-dictionary.
@_expose(Cxx)
public final class NetworkCacheCompressionDictionaryEntry {
    // Incrementing this discards only the stored dictionaries, not the whole cache like Storage::version does.
    private static let version: UInt8 = 1

    private let entryKey: WebKit.NetworkCache.Key
    private let entryTimeStamp: WTF.WallTime
    private let entryInfo: WebKit.NetworkCache.CompressionDictionaryInfo
    private let entryHash: WebKit.NetworkCache.CompressionDictionaryHash
    // Made from `sourceBody` on first use when the entry came from storage.
    private var entryBuffer: WebKit.NetworkCache.SharedBufferPtr
    private let sourceBody: WebKit.NetworkCache.Data

    private init(
        key: consuming WebKit.NetworkCache.Key,
        timeStamp: WTF.WallTime,
        info: consuming WebKit.NetworkCache.CompressionDictionaryInfo,
        hash: WebKit.NetworkCache.CompressionDictionaryHash,
        buffer: consuming WebKit.NetworkCache.SharedBufferPtr,
        sourceBody: consuming WebKit.NetworkCache.Data
    ) {
        self.entryKey = consume key
        self.entryTimeStamp = timeStamp
        self.entryInfo = consume info
        self.entryHash = hash
        self.entryBuffer = consume buffer
        self.sourceBody = consume sourceBody
    }

    /// A dictionary for a response body, stamped now, with the SHA-256 of the body.
    public static func make(
        key: consuming WebKit.NetworkCache.Key,
        info: consuming WebKit.NetworkCache.CompressionDictionaryInfo,
        buffer: borrowing WebKit.NetworkCache.FragmentedBufferPtr
    ) -> NetworkCacheCompressionDictionaryEntry {
        let contiguousBuffer = WebKit.NetworkCache.contiguousSharedBuffer(buffer)
        let hash = WebKit.NetworkCache.networkCacheSHA256(contiguousBuffer)
        return NetworkCacheCompressionDictionaryEntry(
            key: consume key,
            timeStamp: WTF.WallTime.now(),
            info: consume info,
            hash: hash,
            buffer: contiguousBuffer,
            sourceBody: WebKit.NetworkCache.Data()
        )
    }

    /// The key the dictionary is stored under.
    public func key() -> WebKit.NetworkCache.Key { entryKey }
    /// When the dictionary was stored.
    public func timeStamp() -> WTF.WallTime { entryTimeStamp }
    /// The dictionary's match pattern, identifier, destinations and expiration time.
    public func info() -> WebKit.NetworkCache.CompressionDictionaryInfo { entryInfo }
    /// The SHA-256 hash of the dictionary's contents.
    public func hash() -> WebKit.NetworkCache.CompressionDictionaryHash { entryHash }

    /// The dictionary's contents.
    public func buffer() -> WebKit.NetworkCache.SharedBufferPtr {
        if !Bool(fromCxx: entryBuffer) {
            entryBuffer = WebKit.NetworkCache.sharedBufferFromData(sourceBody)
        }
        return entryBuffer
    }

    /// The storage record: the key and time stamp, the header and the body, with no body hash.
    public func encodeAsStorageRecord() -> WebKit.NetworkCache.Storage.Record {
        var encoder = WTF.Persistence.Encoder()
        WebKit.NetworkCache.networkCacheEncode(&encoder, Self.version)
        WebKit.NetworkCache.networkCacheEncode(&encoder, entryInfo.match)
        WebKit.NetworkCache.networkCacheEncode(&encoder, entryInfo.id)
        WebKit.NetworkCache.networkCacheEncode(&encoder, entryInfo.matchDest.toRaw())
        WebKit.NetworkCache.networkCacheEncode(&encoder, entryInfo.expirationTime)
        WebKit.NetworkCache.networkCacheEncodeFixedLengthData(&encoder, entryHash)
        encoder.encodeChecksum()

        let header = WebKit.NetworkCache.dataFromEncoder(encoder)
        let body = WebKit.NetworkCache.dataFromSharedBuffer(entryBuffer)
        return WebKit.NetworkCache.Storage.Record(entryKey, entryTimeStamp, header, body, .init())
    }

    /// A dictionary from a storage record; nil for another version, at the first field that fails and at a bad
    /// checksum.
    ///
    /// The header span is read only by the decoders called here.
    public static func decodeStorageRecord(
        _ record: borrowing WebKit.NetworkCache.Storage.Record
    ) -> NetworkCacheCompressionDictionaryEntry? {
        let headerBytes: Span<UInt8> = record.header.span()
        var decoder = WTF.Persistence.makeDecoder(headerBytes)

        var recordVersion: UInt8 = 0
        guard WebKit.NetworkCache.networkCacheDecode(&decoder, &recordVersion), recordVersion == Self.version else {
            return nil
        }
        var info = WebKit.NetworkCache.CompressionDictionaryInfo()
        guard WebKit.NetworkCache.networkCacheDecode(&decoder, &info.match),
            WebKit.NetworkCache.networkCacheDecode(&decoder, &info.id)
        else {
            return nil
        }
        var matchDest: UInt32 = 0
        guard WebKit.NetworkCache.networkCacheDecode(&decoder, &matchDest) else {
            return nil
        }
        info.matchDest = WebKit.NetworkCache.CompressionDictionaryDestinationSet.fromRaw(matchDest)
        guard WebKit.NetworkCache.networkCacheDecode(&decoder, &info.expirationTime) else {
            return nil
        }
        var hash = WebKit.NetworkCache.CompressionDictionaryHash()
        guard WebKit.NetworkCache.networkCacheDecodeFixedLengthData(&decoder, &hash) else {
            return nil
        }
        guard decoder.verifyChecksum() else {
            WebKit.LogChannel.NetworkCache().debugLog.log("(NetworkProcess) compression dictionary checksum verification failure\n")
            return nil
        }

        return NetworkCacheCompressionDictionaryEntry(
            key: record.key,
            timeStamp: record.timeStamp,
            info: consume info,
            hash: hash,
            buffer: WebKit.NetworkCache.SharedBufferPtr(),
            sourceBody: record.body
        )
    }
}
