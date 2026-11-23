// Copyright (C) 2015-2026 Apple Inc. All rights reserved.
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

// The subresources a main resource loaded, kept beside it in the cache for the speculative load manager
// (NetworkCacheSpeculativeLoadManager.swift). Main thread only.

/// One subresource load of a frame, recorded while the frame loads.
// Exposed so the generated header defines the type metadata C++ files need.
@_expose(Cxx)
final class NetworkCacheSubresourceLoad {
    let request: WebCore.ResourceRequest
    let key: WebKit.NetworkCache.Key

    init(_ request: consuming WebCore.ResourceRequest, _ key: consuming WebKit.NetworkCache.Key) {
        self.request = request
        self.key = key
    }
}

/// What the cache knows of one subresource of a main resource.
struct NetworkCacheSubresourceInfo {
    /// The fields of the subresource's request the cache records.
    struct Request {
        let isSameSite: Bool
        let isAppInitiated: Bool
        let firstPartyForCookies: WTF.URL
        let headers: WebCore.HTTPHeaderMap
        let priority: WebCore.ResourceLoadPriority
    }

    /// The subresource's key.
    let key: WebKit.NetworkCache.Key
    /// When the subresource was last seen loaded by the main resource.
    let lastSeen: WTF.WallTime
    /// When the subresource was first seen loaded by the main resource.
    let firstSeen: WTF.WallTime
    /// The subresource's request; nil while the subresource is transient.
    let request: Request?

    /// Whether the subresource has been seen only once, so its request is not recorded.
    var isTransient: Bool { request == nil }

    private init(key: consuming WebKit.NetworkCache.Key, lastSeen: WTF.WallTime, firstSeen: WTF.WallTime, request: consuming Request?) {
        self.key = consume key
        self.lastSeen = lastSeen
        self.firstSeen = firstSeen
        self.request = consume request
    }

    /// A load seen now, first seen when an earlier entry's info was; its request is recorded unless it is transient.
    init(
        _ key: consuming WebKit.NetworkCache.Key,
        _ request: borrowing WebCore.ResourceRequest,
        previousFirstSeen: WTF.WallTime?,
        isTransient: Bool
    ) {
        let now = WTF.WallTime.now()
        self.init(
            key: consume key,
            lastSeen: now,
            firstSeen: previousFirstSeen ?? now,
            request: isTransient
                ? nil
                : Request(
                    isSameSite: request.isSameSite(),
                    isAppInitiated: request.isAppInitiated(),
                    firstPartyForCookies: request.firstPartyForCookiesCopy(),
                    headers: request.httpHeaderFieldsCopy(),
                    priority: request.priority()
                )
        )
    }

    /// Whether the subresource's request was same-site.
    var isSameSite: Bool {
        assert(!isTransient)
        return request?.isSameSite ?? false
    }
    /// Always false: the cache does not record top-site loads.
    var isTopSite: Bool { false }
    /// The first-party URL of the subresource's request.
    var firstPartyForCookies: WTF.URL {
        assert(!isTransient)
        return request?.firstPartyForCookies ?? WTF.URL()
    }
    /// The headers of the subresource's request.
    var requestHeaders: WebCore.HTTPHeaderMap {
        assert(!isTransient)
        return request?.headers ?? WebCore.HTTPHeaderMap()
    }
    /// The priority of the subresource's request.
    var priority: WebCore.ResourceLoadPriority {
        assert(!isTransient)
        return request?.priority ?? .VeryLow
    }

    /// Whether the subresource's URL is in the registrable domain of its request's first-party URL.
    var isFirstParty: Bool {
        WebCore.RegistrableDomain(request?.firstPartyForCookies ?? WTF.URL())
            .matches(WebKit.NetworkCache.networkCacheURL(key.identifierCopy()))
    }

    /// Encodes the info; a transient one stops after its flag, as it has no request.
    func encode(_ encoder: inout WTF.Persistence.Encoder) {
        WebKit.NetworkCache.networkCacheEncode(&encoder, key)
        WebKit.NetworkCache.networkCacheEncode(&encoder, lastSeen)
        WebKit.NetworkCache.networkCacheEncode(&encoder, firstSeen)
        WebKit.NetworkCache.networkCacheEncode(&encoder, isTransient)
        guard let request else {
            return
        }
        WebKit.NetworkCache.networkCacheEncode(&encoder, request.isSameSite)
        WebKit.NetworkCache.networkCacheEncode(&encoder, request.isAppInitiated)
        WebKit.NetworkCache.networkCacheEncode(&encoder, request.firstPartyForCookies)
        WebKit.NetworkCache.networkCacheEncode(&encoder, request.headers)
        WebKit.NetworkCache.networkCacheEncode(&encoder, request.priority)
    }

    /// Decodes an info; nil at the first field that fails.
    static func decode(_ decoder: inout WTF.Persistence.Decoder) -> NetworkCacheSubresourceInfo? {
        var key = WebKit.NetworkCache.Key()
        var lastSeen = WTF.WallTime()
        var firstSeen = WTF.WallTime()
        var isTransient = false
        guard WebKit.NetworkCache.networkCacheDecode(&decoder, &key),
            WebKit.NetworkCache.networkCacheDecode(&decoder, &lastSeen),
            WebKit.NetworkCache.networkCacheDecode(&decoder, &firstSeen),
            WebKit.NetworkCache.networkCacheDecode(&decoder, &isTransient)
        else {
            return nil
        }
        if isTransient {
            return NetworkCacheSubresourceInfo(key: consume key, lastSeen: lastSeen, firstSeen: firstSeen, request: nil)
        }
        var isSameSite = false
        var isAppInitiated = false
        var firstPartyForCookies = WTF.URL()
        var requestHeaders = WebCore.HTTPHeaderMap()
        var priority = WebCore.ResourceLoadPriority.VeryLow
        guard WebKit.NetworkCache.networkCacheDecode(&decoder, &isSameSite),
            WebKit.NetworkCache.networkCacheDecode(&decoder, &isAppInitiated),
            WebKit.NetworkCache.networkCacheDecode(&decoder, &firstPartyForCookies),
            WebKit.NetworkCache.networkCacheDecode(&decoder, &requestHeaders),
            WebKit.NetworkCache.networkCacheDecode(&decoder, &priority)
        else {
            return nil
        }
        return NetworkCacheSubresourceInfo(
            key: consume key,
            lastSeen: lastSeen,
            firstSeen: firstSeen,
            request: Request(
                isSameSite: isSameSite,
                isAppInitiated: isAppInitiated,
                firstPartyForCookies: consume firstPartyForCookies,
                headers: consume requestHeaders,
                priority: priority
            )
        )
    }
}

/// The subresources entry of a main resource (type "SubResources").
@_expose(Cxx)
public final class NetworkCacheSubresourcesEntry {
    /// The record type of a subresources entry's key.
    static let typeName = "SubResources"

    private let entryKey: WebKit.NetworkCache.Key
    private let entryTimeStamp: WTF.WallTime
    let subresources: [NetworkCacheSubresourceInfo]

    private init(key: consuming WebKit.NetworkCache.Key, timeStamp: WTF.WallTime, subresources: [NetworkCacheSubresourceInfo]) {
        self.entryKey = consume key
        self.entryTimeStamp = timeStamp
        self.subresources = subresources
    }

    /// A new entry for the loads of a frame, stamped now.
    ///
    /// Every subresource of a first entry is non-transient.
    convenience init(_ key: consuming WebKit.NetworkCache.Key, _ loads: [NetworkCacheSubresourceLoad]) {
        assert(key.typeCopy() == WTF.String(Self.typeName))
        self.init(key: consume key, timeStamp: WTF.WallTime.now(), subresources: Self.makeInfos(loads, previous: nil))
    }

    /// The entry's storage key, of type "SubResources".
    func key() -> WebKit.NetworkCache.Key { entryKey }
    /// When the entry was first made; an update keeps it.
    func timeStamp() -> WTF.WallTime { entryTimeStamp }

    /// The entry with the subresources of a later load of its frame, under the same key and time stamp.
    func updatingSubresourceLoads(_ loads: [NetworkCacheSubresourceLoad]) -> NetworkCacheSubresourcesEntry {
        NetworkCacheSubresourcesEntry(key: entryKey, timeStamp: entryTimeStamp, subresources: Self.makeInfos(loads, previous: subresources))
    }

    /// The loads in order, without repeats; an info seen in `previous` keeps its first-seen time and is not transient.
    private static func makeInfos(
        _ loads: [NetworkCacheSubresourceLoad],
        previous: [NetworkCacheSubresourceInfo]?
    ) -> [NetworkCacheSubresourceInfo] {
        var result: [NetworkCacheSubresourceInfo] = []
        result.reserveCapacity(loads.count)
        // A key's first-seen time from the first previous info that has it.
        var firstSeenByKey: [NetworkCacheHashableKey: WTF.WallTime] = [:]
        if let previous {
            for info in previous {
                let key = NetworkCacheHashableKey(info.key)
                if firstSeenByKey[key] == nil {
                    firstSeenByKey[key] = info.firstSeen
                }
            }
        }
        var takenKeys: Set<NetworkCacheHashableKey> = []
        for load in loads {
            let key = NetworkCacheHashableKey(load.key)
            guard takenKeys.insert(key).inserted else {
                continue
            }
            let previousFirstSeen = firstSeenByKey[key]
            // FIXME: We should really consider all resources seen for the first time transient.
            let isTransient = previous != nil && previousFirstSeen == nil
            result.append(
                NetworkCacheSubresourceInfo(load.key, load.request, previousFirstSeen: previousFirstSeen, isTransient: isTransient)
            )
        }
        return result
    }

    /// The entry as a storage record.
    public func encodeAsStorageRecord() -> WebKit.NetworkCache.Storage.Record {
        var encoder = WTF.Persistence.Encoder()
        WebKit.NetworkCache.networkCacheEncode(&encoder, UInt64(subresources.count))
        for info in subresources {
            info.encode(&encoder)
        }
        encoder.encodeChecksum()
        let header = WebKit.NetworkCache.dataFromEncoder(encoder)
        return WebKit.NetworkCache.Storage.Record(entryKey, entryTimeStamp, header, WebKit.NetworkCache.Data(), .init())
    }

    /// An entry from its record; nil at the first field that fails and at a bad checksum.
    ///
    /// The header span is read only by the decoders called here.
    public static func decodeStorageRecord(_ record: WebKit.NetworkCache.Storage.Record) -> NetworkCacheSubresourcesEntry? {
        assert(record.key.typeCopy() == WTF.String(Self.typeName))
        let headerBytes: Span<UInt8> = record.header.span()
        var decoder = WTF.Persistence.makeDecoder(headerBytes)
        var count: UInt64 = 0
        guard WebKit.NetworkCache.networkCacheDecode(&decoder, &count) else {
            return nil
        }
        // Appended one by one, never reserved from the decoded count, which comes from disk.
        var subresources: [NetworkCacheSubresourceInfo] = []
        for _ in 0..<count {
            guard let info = NetworkCacheSubresourceInfo.decode(&decoder) else {
                return nil
            }
            subresources.append(info)
        }
        guard decoder.verifyChecksum() else {
            WebKit.LogChannel.NetworkCache().debugLog.log("(NetworkProcess) checksum verification failure\n")
            return nil
        }
        return NetworkCacheSubresourcesEntry(key: record.key, timeStamp: record.timeStamp, subresources: subresources)
    }

    /// The entry with the given loads as a later load of its frame.
    public func updatingSubresourceLoadsForTesting(_ loads: borrowing NetworkCacheSubresourceLoadList) -> NetworkCacheSubresourcesEntry {
        updatingSubresourceLoads(loads.loads)
    }

    /// The entry's description for the test: the count, then each info's lines.
    public func describeForTesting() -> WTF.String {
        var builder = WTF.StringBuilder()
        builder.append(WTF.String("count="))
        builder.append(WTF.String.number(UInt64(subresources.count)))
        builder.append(WTF.String("\n"))
        for info in subresources {
            info.describeForTesting(&builder)
        }
        return WebKit.NetworkCache.TestSupport.stringFromBuilder(&builder)
    }

    /// Decodes an info from `input` and encodes it again, for the coder test.
    ///
    /// The input span is read only by the decoder called here.
    public static func infoCoderRoundTrip(_ input: borrowing WebKit.NetworkCache.Data) -> NetworkCacheSubresourceInfoRoundTrip {
        let inputBytes: Span<UInt8> = input.span()
        var decoder = WTF.Persistence.makeDecoder(inputBytes)
        guard let info = NetworkCacheSubresourceInfo.decode(&decoder) else {
            return NetworkCacheSubresourceInfoRoundTrip(data: WebKit.NetworkCache.Data(), consumedAll: false)
        }
        let consumedAll = decoder.currentOffset() == input.size()
        var encoder = WTF.Persistence.Encoder()
        info.encode(&encoder)
        return NetworkCacheSubresourceInfoRoundTrip(data: WebKit.NetworkCache.dataFromEncoder(encoder), consumedAll: consumedAll)
    }

    /// A first entry for the given loads.
    public static func makeForTesting(
        _ key: consuming WebKit.NetworkCache.Key,
        _ loads: borrowing NetworkCacheSubresourceLoadList
    ) -> NetworkCacheSubresourcesEntry {
        NetworkCacheSubresourcesEntry(key, loads.loads)
    }
}

extension WebKit.NetworkCache.Key {
    /// The key of the subresources entry of the resource with this key.
    func subresourcesKey(salt: WebKit.NetworkCache.Salt) -> WebKit.NetworkCache.Key {
        WebKit.NetworkCache.Key(partitionCopy(), WTF.String(NetworkCacheSubresourcesEntry.typeName), rangeCopy(), identifierCopy(), salt)
    }
}
