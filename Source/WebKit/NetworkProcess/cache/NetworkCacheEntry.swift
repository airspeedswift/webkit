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

private struct EntryFlags: OptionSet {
    let rawValue: UInt8

    static let isRedirect = EntryFlags(rawValue: 1 << 0)
    static let privateRelayed = EntryFlags(rawValue: 1 << 1)
}

/// The network cache's entry: a response, its body and what the cache keeps with them.
@_expose(Cxx)
public final class NetworkCacheEntry {
    private let entryKey: WebKit.NetworkCache.Key
    private let entryTimeStamp: WTF.WallTime
    private var entryResponse: WebCore.ResourceResponse
    // Whether the response's source is DiskCacheAfterValidation, so reading it does not copy the response.
    private var entryNeedsValidation: Bool
    // Internal: the cache's decisions read them in place.
    let entryVaryingRequestHeaders: WebKit.NetworkCache.HeaderPairs
    let entryRedirectRequest: WebKit.NetworkCache.OptionalRequest
    // Made from `sourceBody` on first use when the entry came from storage.
    private var entryBuffer: WebKit.NetworkCache.FragmentedBufferPtr
    private var entryShareableResource: WebKit.NetworkCache.ShareableResourcePtr
    // The body of the storage record the entry was decoded from.
    private let sourceBody: WebKit.NetworkCache.Data
    private var maxAgeCap: WebKit.NetworkCache.OptionalSeconds
    private let entryPrivateRelayed: Bool

    private init(
        key: consuming WebKit.NetworkCache.Key,
        timeStamp: WTF.WallTime,
        response: consuming WebCore.ResourceResponse,
        varyingRequestHeaders: consuming WebKit.NetworkCache.HeaderPairs,
        redirectRequest: consuming WebKit.NetworkCache.OptionalRequest,
        buffer: consuming WebKit.NetworkCache.FragmentedBufferPtr,
        sourceBody: consuming WebKit.NetworkCache.Data,
        maxAgeCap: WebKit.NetworkCache.OptionalSeconds,
        privateRelayed: Bool
    ) {
        self.entryKey = consume key
        self.entryTimeStamp = timeStamp
        self.entryNeedsValidation = response.source() == .DiskCacheAfterValidation
        self.entryResponse = consume response
        self.entryVaryingRequestHeaders = consume varyingRequestHeaders
        self.entryRedirectRequest = consume redirectRequest
        self.entryBuffer = consume buffer
        self.entryShareableResource = WebKit.NetworkCache.ShareableResourcePtr()
        self.sourceBody = consume sourceBody
        self.maxAgeCap = maxAgeCap
        self.entryPrivateRelayed = privateRelayed
        assert(entryKey.recordType == .Resource)
    }

    /// An entry for a response and its body, stamped now.
    public static func make(
        key: consuming WebKit.NetworkCache.Key,
        response: consuming WebCore.ResourceResponse,
        privateRelayed: Bool,
        buffer: consuming WebKit.NetworkCache.FragmentedBufferPtr,
        varyingRequestHeaders: consuming WebKit.NetworkCache.HeaderPairs
    ) -> NetworkCacheEntry {
        NetworkCacheEntry(
            key: consume key,
            timeStamp: WTF.WallTime.now(),
            response: consume response,
            varyingRequestHeaders: consume varyingRequestHeaders,
            redirectRequest: WebKit.NetworkCache.OptionalRequest(),
            buffer: consume buffer,
            sourceBody: WebKit.NetworkCache.Data(),
            maxAgeCap: nil,
            privateRelayed: privateRelayed
        )
    }

    /// An entry for a redirect, stamped now, with an isolated copy of the request without its body.
    public static func makeRedirect(
        key: consuming WebKit.NetworkCache.Key,
        response: consuming WebCore.ResourceResponse,
        redirectRequest: consuming WebCore.ResourceRequest,
        varyingRequestHeaders: consuming WebKit.NetworkCache.HeaderPairs
    ) -> NetworkCacheEntry {
        NetworkCacheEntry(
            key: consume key,
            timeStamp: WTF.WallTime.now(),
            response: consume response,
            varyingRequestHeaders: consume varyingRequestHeaders,
            redirectRequest: WebKit.NetworkCache.redirectRequestForEntry(redirectRequest),
            buffer: WebKit.NetworkCache.FragmentedBufferPtr(),
            sourceBody: WebKit.NetworkCache.Data(),
            maxAgeCap: nil,
            privateRelayed: false
        )
    }

    /// A copy without the max-age cap, the private-relayed flag or the shareable resource.
    func copy() -> NetworkCacheEntry {
        NetworkCacheEntry(
            key: entryKey,
            timeStamp: entryTimeStamp,
            response: entryResponse,
            varyingRequestHeaders: entryVaryingRequestHeaders,
            redirectRequest: entryRedirectRequest,
            buffer: entryBuffer,
            sourceBody: sourceBody,
            maxAgeCap: nil,
            privateRelayed: false
        )
    }

    // MARK: Getters

    /// The key the entry is stored under.
    public func key() -> WebKit.NetworkCache.Key { entryKey }
    /// When the entry was stored.
    public func timeStamp() -> WTF.WallTime { entryTimeStamp }
    /// The stored response.
    public func response() -> WebCore.ResourceResponse { entryResponse }
    /// The request headers the response varies on, with their values.
    public func varyingRequestHeaders() -> WebKit.NetworkCache.HeaderPairs { entryVaryingRequestHeaders }
    /// The redirect's request, for a redirect entry.
    public func redirectRequest() -> WebKit.NetworkCache.OptionalRequest { entryRedirectRequest }
    /// Whether the response came through a private relay.
    public func privateRelayed() -> WebKit.PrivateRelayed { entryPrivateRelayed ? .Yes : .No }

    /// Calls `body` with the stored response read in place, which `response()` would copy, and `argument`.
    ///
    /// `body` must not reach the entry's response another way: it runs inside an access to it.
    func withResponse<Argument, Result>(
        _ argument: borrowing Argument,
        _ body: (borrowing WebCore.ResourceResponse, borrowing Argument) -> Result
    ) -> Result {
        Self.withResponse(&entryResponse, argument, body)
    }

    // The response is passed `inout` so that `body` borrows the stored response rather than a copy of it.
    private static func withResponse<Argument, Result>(
        _ response: inout WebCore.ResourceResponse,
        _ argument: borrowing Argument,
        _ body: (borrowing WebCore.ResourceResponse, borrowing Argument) -> Result
    ) -> Result {
        body(response, argument)
    }

    /// The entry as the network cache's test support prints it, built from the fields read in place.
    public func descriptionForTesting() -> WTF.String {
        Self.describeForTesting(&entryResponse, self)
    }

    // The response is passed `inout` so that the description reads the stored response rather than a copy of it.
    private static func describeForTesting(_ response: inout WebCore.ResourceResponse, _ entry: NetworkCacheEntry) -> WTF.String {
        WebKit.NetworkCache.TestSupport.describeEntry(
            response,
            entry.entryTimeStamp,
            entry.entryNeedsValidation,
            entry.entryPrivateRelayed,
            entry.entryRedirectRequest,
            entry.entryKey,
            entry.entryVaryingRequestHeaders
        )
    }

    /// The body: the buffer the entry was made with, or one made from the stored body on first use.
    public func buffer() -> WebKit.NetworkCache.FragmentedBufferPtr {
        if !Bool(fromCxx: entryBuffer) {
            entryBuffer = WebKit.NetworkCache.bufferFromStorageBody(shareableResource(), sourceBody)
        }
        return entryBuffer
    }

    /// The shareable resource over the stored body's shared memory, made once.
    ///
    /// Null where the platform has none or the body has no shared memory, and made again on the next call then.
    public func shareableResource() -> WebKit.NetworkCache.ShareableResourcePtr {
        if !Bool(fromCxx: entryShareableResource) {
            entryShareableResource = WebKit.NetworkCache.shareableResourceFromBody(sourceBody)
        }
        return entryShareableResource
    }

    /// Whether the entry must be validated before it is used.
    public func needsValidation() -> Bool {
        entryNeedsValidation
    }

    func setNeedsValidation(_ value: Bool) {
        entryResponse.setSource(value ? .DiskCacheAfterValidation : .DiskCache)
        entryNeedsValidation = value
    }

    /// Whether the response is older than the max-age cap for prevalent resources.
    public func hasReachedPrevalentResourceAgeCap() -> Bool {
        guard let maxAgeCap = maxAgeCap.value else {
            return false
        }
        return WebCore.computeCurrentAge(entryResponse, entryTimeStamp).value() > maxAgeCap.value()
    }

    func capMaxAge(_ maxAgeCap: WTF.Seconds) {
        self.maxAgeCap = WebKit.NetworkCache.OptionalSeconds(maxAgeCap)
    }

    // MARK: The storage record

    /// The storage record: the entry's key and time stamp, its header and its body, with no body hash.
    public func encodeAsStorageRecord() -> WebKit.NetworkCache.Storage.Record {
        let header = encodeStorageRecordHeader()
        let body = Self.contiguousBody(&entryBuffer)
        return WebKit.NetworkCache.Storage.Record(entryKey, entryTimeStamp, header, body, .init())
    }

    private func encodeStorageRecordHeader() -> WebKit.NetworkCache.Data {
        var encoder = WTF.Persistence.Encoder()
        Self.encodeResponse(&entryResponse, to: &encoder)

        let hasVaryingRequestHeaders = !entryVaryingRequestHeaders.isEmpty()
        WebKit.NetworkCache.networkCacheEncode(&encoder, hasVaryingRequestHeaders)
        if hasVaryingRequestHeaders {
            WebKit.NetworkCache.networkCacheEncode(&encoder, entryVaryingRequestHeaders)
        }

        let isRedirect = entryRedirectRequest.hasValue
        var flags: EntryFlags = []
        if isRedirect {
            flags.insert(.isRedirect)
        }
        if entryPrivateRelayed {
            flags.insert(.privateRelayed)
        }
        WebKit.NetworkCache.networkCacheEncode(&encoder, flags.rawValue)
        if isRedirect {
            WebKit.NetworkCache.networkCacheEncode(&encoder, entryRedirectRequest)
        }

        // One read of the stored cap into a local, which the encoder reads by reference.
        let maxAgeCap = self.maxAgeCap
        WebKit.NetworkCache.networkCacheEncode(&encoder, maxAgeCap)

        encoder.encodeChecksum()
        return WebKit.NetworkCache.dataFromEncoder(encoder)
    }

    // The response is passed `inout` so that the encoder reads the stored response rather than a copy of it.
    private static func encodeResponse(
        _ response: inout WebCore.ResourceResponse,
        to encoder: inout WTF.Persistence.Encoder
    ) {
        WebKit.NetworkCache.networkCacheEncode(&encoder, response)
    }

    /// The buffer made contiguous, which the entry keeps from then on; empty without a buffer.
    ///
    /// Passed `inout` so the null test and the replacement are one access to the stored property.
    private static func contiguousBody(_ buffer: inout WebKit.NetworkCache.FragmentedBufferPtr) -> WebKit.NetworkCache.Data {
        if !Bool(fromCxx: buffer) {
            return WebKit.NetworkCache.Data()
        }
        return WebKit.NetworkCache.makeContiguousData(&buffer)
    }

    /// An entry from a storage record; nil at the first field that fails and at a bad checksum.
    ///
    /// The header span is read only by the decoders called here.
    public static func decodeStorageRecord(_ record: borrowing WebKit.NetworkCache.Storage.Record) -> NetworkCacheEntry? {
        let headerBytes: Span<UInt8> = record.header.span()
        var decoder = WTF.Persistence.makeDecoder(headerBytes)

        var responseDecoded = false
        var response = WebKit.NetworkCache.decodeResponse(&decoder, &responseDecoded)
        guard responseDecoded else {
            return nil
        }
        response.setSource(.DiskCache)

        var hasVaryingRequestHeaders = false
        guard WebKit.NetworkCache.networkCacheDecode(&decoder, &hasVaryingRequestHeaders) else {
            return nil
        }
        var varyingRequestHeaders = WebKit.NetworkCache.HeaderPairs()
        if hasVaryingRequestHeaders {
            guard WebKit.NetworkCache.networkCacheDecode(&decoder, &varyingRequestHeaders) else {
                return nil
            }
        }

        var rawFlags: UInt8 = 0
        guard WebKit.NetworkCache.networkCacheDecode(&decoder, &rawFlags) else {
            return nil
        }
        // Flag bits other than redirect and private relayed are ignored.
        let flags = EntryFlags(rawValue: rawFlags)
        let isRedirect = flags.contains(.isRedirect)
        let privateRelayed = flags.contains(.privateRelayed)

        var redirectRequest = WebKit.NetworkCache.OptionalRequest()
        if isRedirect {
            guard WebKit.NetworkCache.networkCacheDecode(&decoder, &redirectRequest) else {
                return nil
            }
        }

        var maxAgeCap = WebKit.NetworkCache.OptionalSeconds()
        guard WebKit.NetworkCache.networkCacheDecode(&decoder, &maxAgeCap) else {
            return nil
        }

        guard decoder.verifyChecksum() else {
            WebKit.LogChannel.NetworkCache().debugLog.log("(NetworkProcess) checksum verification failure\n")
            return nil
        }

        return NetworkCacheEntry(
            key: record.key,
            timeStamp: record.timeStamp,
            response: consume response,
            varyingRequestHeaders: consume varyingRequestHeaders,
            redirectRequest: consume redirectRequest,
            buffer: WebKit.NetworkCache.FragmentedBufferPtr(),
            sourceBody: record.body,
            maxAgeCap: maxAgeCap,
            privateRelayed: privateRelayed
        )
    }

    /// `decodeStorageRecord` for the test support's `NCTS_EntryDecode`, which tests the result and takes the entry as
    /// the retrieve's completion does with `takeRetrievedEntry`: C++ sees no generic `Optional`.
    ///
    /// `record` is borrowed for the call. The only caller is NetworkCacheTestSupport's `NCTS_EntryDecode`, which
    /// passes a local it owns for the whole call. The C++ called with `record` is the decoders `decodeStorageRecord`
    /// calls, on a span of its header that lives only while it decodes, and the key, time stamp and body copies. None
    /// holds a pointer back to the caller or calls out.
    public static func decodeStorageRecordForTesting(
        _ record: borrowing WebKit.NetworkCache.Storage.Record
    ) -> NetworkCacheDecodedEntry {
        NetworkCacheDecodedEntry(decodeStorageRecord(record))
    }

    /// The response's URL from a stored header without decoding the rest: a null flag, then the URL; no checksum.
    public static func decodeStorageRecordResponseURL(header: borrowing WebKit.NetworkCache.Data) -> WTF.URL? {
        let headerBytes: Span<UInt8> = header.span()
        var decoder = WTF.Persistence.makeDecoder(headerBytes)

        var responseIsNull = false
        guard WebKit.NetworkCache.networkCacheDecode(&decoder, &responseIsNull), !responseIsNull else {
            return nil
        }
        var url = WTF.URL()
        guard WebKit.NetworkCache.networkCacheDecode(&decoder, &url) else {
            return nil
        }
        return url
    }
}

/// What `decodeStorageRecordForTesting` returns: the decoded entry, if any, which C++ tests and then takes.
@_expose(Cxx)
public struct NetworkCacheDecodedEntry {
    private var entry: NetworkCacheEntry?

    fileprivate init(_ entry: consuming NetworkCacheEntry?) {
        self.entry = entry
    }

    /// Whether the record decoded.
    public var isDecoded: Bool { entry != nil }

    /// Moves the entry out; a record that did not decode, or an entry taken twice, traps.
    public mutating func take() -> NetworkCacheEntry {
        guard let entry = entry.take() else {
            fatalError("A decoded entry was taken twice or the record did not decode")
        }
        return entry
    }
}
