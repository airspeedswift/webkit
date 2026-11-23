// Copyright (C) 2014-2025 Apple Inc. All rights reserved.
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

// The network process's HTTP disk cache (NetworkCache::Cache). Main thread only: every entry point is called on the
// main thread, and no hop to another thread captures the cache.

// MARK: - The cache

/// A session's disk cache: the decisions, the entries and the storage under them.
@_expose(Cxx)
public final class NetworkDiskCache {
    /// The cache's records on disk.
    public let storage: NetworkCacheStorage
    /// The session the cache belongs to.
    public let sessionID: PAL.SessionID
    /// The directory the cache was opened at.
    public let storageDirectory: WTF.String
    // Set once, with the SpeculativeRevalidation option.
    private var speculationNotifiers: WebKit.NetworkCache.SpeculationNotifiers?
    private var speculativeLoadManager: NetworkCacheSpeculativeLoadManager?
    // The async revalidations by key, and by frame (weakly).
    // Internal, with retrievedEntries: used by NetworkCacheRetrieve.swift.
    var pendingAsyncRevalidations: [NetworkCacheHashableKey: NetworkCacheAsyncRevalidation] = [:]
    var pendingAsyncRevalidationByPage: [NetworkCacheHashableFrameID: [WeakAsyncRevalidation]] = [:]
    private var traverseCount: UInt32 = 0
    private static let maximumTraverseCount: UInt32 = 3

    private var compressionDictionaryIndex = NetworkCacheCompressionDictionaryIndex()

    var retrievedEntries = NetworkCacheRetrievedEntries()

    private init(storageDirectory: WTF.String, storage: NetworkCacheStorage, sessionID: PAL.SessionID) {
        self.storage = storage
        self.sessionID = sessionID
        self.storageDirectory = storageDirectory
    }

    deinit {
        precondition(retrievedEntries.isEmpty, "A retrieved entry was never taken by its completion")
    }

    /// Opens the cache.
    ///
    /// `options` is an `OptionSet<CacheOption>`'s bits: Swift cannot spell the instantiation.
    public static func open(_ cachePath: consuming WTF.String, _ options: UInt8, _ sessionID: PAL.SessionID) -> NetworkDiskCache? {
        if !WTF.FileSystemImpl.makeAllDirectories(cachePath) {
            return nil
        }

        let capacity = WebKit.NetworkCache.computeCapacity(cachePath)

        // Cache a small number of recently used memory mapped main resource blobs to speed up hot loads of
        // recently visited websites.
        let mainResourceBlobMemoryCacheFileLimit = WebKit.NetworkCache.isPrimaryWebBrowser() ? 32 : 0

        let testingMode = options & WebKit.NetworkCache.CacheOption.TestingMode.rawValue != 0
        guard
            let storage = NetworkCacheStorage.open(
                at: cachePath,
                mode: testingMode ? .AvoidRandomness : .Normal,
                capacity: capacity,
                mainResourceBlobMemoryCacheFileLimit: mainResourceBlobMemoryCacheFileLimit
            )
        else {
            return nil
        }

        let cache = NetworkDiskCache(storageDirectory: cachePath, storage: storage, sessionID: sessionID)
        cache.populateCompressionDictionaryIndex()
        return cache
    }

    /// Called once, with the SpeculativeRevalidation option.
    ///
    /// The notifiers report each power state change.
    public func enableSpeculativeRevalidation(_ notifiers: WebKit.NetworkCache.SpeculationNotifiers) {
        speculationNotifiers = notifiers
        if notifiers.shouldUseSpeculativeLoadManager() {
            speculativeLoadManager = NetworkCacheSpeculativeLoadManager(cache: self, storage: storage)
        }
    }

    /// Starts or stops speculative loading to match the session's setting.
    public func updateSpeculativeLoadManagerEnabledState() {
        assert(WTF.RunLoop.isMain())
        guard let notifiers = speculationNotifiers else {
            return
        }
        let shouldEnable = notifiers.shouldUseSpeculativeLoadManager()
        let log = WebKit.LogChannel.NetworkCacheSpeculativePreloading().releaseLog
        if !shouldEnable && speculativeLoadManager != nil {
            speculativeLoadManager = nil
            log.log("Cache::updateSpeculativeLoadManagerEnabledState: disabling speculative loads due to low power mode or thermal change")
        } else if shouldEnable && speculativeLoadManager == nil {
            speculativeLoadManager = NetworkCacheSpeculativeLoadManager(cache: self, storage: storage)
            log.log("Cache::updateSpeculativeLoadManagerEnabledState: enabling speculative loads due to low power mode or thermal change")
        }
    }

    /// Cancels the frame's async revalidations.
    public func browsingContextRemoved(_ frameID: WebKit.NetworkCache.GlobalFrameID) {
        guard let revalidations = pendingAsyncRevalidationByPage.removeValue(forKey: NetworkCacheHashableFrameID(frameID)) else {
            return
        }
        for revalidation in revalidations {
            revalidation.value?.cancel()
        }
    }

    /// A weak reference to this cache, for C++ objects that must not keep it alive.
    public func makeWeakReference() -> NetworkDiskCacheWeakReference {
        NetworkDiskCacheWeakReference(self)
    }

    /// The storage's capacity in bytes.
    public func capacity() -> Int { storage.capacity }

    /// Sets the storage's capacity from the free space of the volume it is on.
    public func updateCapacity() {
        storage.setCapacity(WebKit.NetworkCache.computeCapacity(storage.basePathIsolatedCopy()))
    }

    /// The records directory, as a copy safe to hand to another thread.
    public func recordsPathIsolatedCopy() -> WTF.String { storage.recordsPathIsolatedCopy() }

    /// Registers a main resource's response with the speculative load manager, if there is one.
    ///
    /// `request` and `response` are borrowed from the C++ caller for the call. NetworkResourceLoader passes its
    /// `originalRequest()` and the response it received, and does not touch either until this returns. The manager
    /// calls `shouldRegisterLoad` and `isRedirection()` first, then marks the frame load's main resource response as
    /// received, which can run tasks waiting on that load. Both arguments are read before that, and the tasks do not
    /// reach either.
    public func registerMainResourceLoadResponse(
        _ frameID: WebKit.NetworkCache.GlobalFrameID,
        _ request: borrowing WebCore.ResourceRequest,
        _ response: borrowing WebCore.ResourceResponse
    ) {
        speculativeLoadManager?.registerMainResourceLoadResponse(frameID, request, response)
    }

    private func makeCacheKey(_ recordType: WebKit.NetworkCache.RecordType, _ request: WebCore.ResourceRequest) -> WebKit.NetworkCache.Key {
        // FIXME: This implements minimal Range header disk cache support. We don't parse
        // ranges so only the same exact range request will be served from the cache.
        let range = request.httpHeaderField(WebCore.HTTPHeaderName.Range)
        let includesCredentials: WebKit.NetworkCache.Key.IncludesCredentials =
            recordType == .Resource && !request.allowCookies() ? .No : .Yes
        return WebKit.NetworkCache.Key(
            request.cachePartition(),
            WebKit.NetworkCache.recordTypeNameString(recordType),
            range,
            request.urlCopy().stringWithoutFragmentIdentifier(),
            storage.salt,
            includesCredentials
        )
    }

    // MARK: Decisions

    /// The use decision for an entry decoded from `record`, as the retrieve completion makes it, for the test
    /// support's `NCTS_UseDecision`; -1 when the record does not decode.
    ///
    /// `record` and `request` are borrowed for the call. The only caller is NetworkCacheTestSupport, which passes
    /// two locals it owns (the record its entry encoded and the request it built). The C++ called with `record` is
    /// the decoders `decodeStorageRecord` calls, on a span of its header that lives only while it decodes, and the
    /// key, time stamp and body copies; with `request`, what `makeUseDecision` calls. None holds a pointer back to
    /// the caller or calls out.
    public static func useDecisionForTesting(
        _ sessionID: PAL.SessionID,
        _ record: borrowing WebKit.NetworkCache.Storage.Record,
        _ request: borrowing WebCore.ResourceRequest
    ) -> Int32 {
        guard let entry = NetworkCacheEntry.decodeStorageRecord(record) else {
            return -1
        }
        return makeUseDecision(sessionID, entry, request).rawValue
    }

    /// Whether a request may be answered from the cache.
    ///
    /// `request` is borrowed for the call. The callers are NetworkCacheTestSupport (a local) and retrieve, with the
    /// request it owns. The C++ called with it is `cachePolicy`, `isGETRequest` and `isConditional`, all getters.
    public static func makeRetrieveDecision(_ request: WebCore.ResourceRequest) -> WebKit.NetworkCache.RetrieveDecision {
        assert(request.cachePolicy() != .DoNotUseAnyCache)

        // FIXME: Support HEAD requests.
        if !WebKit.NetworkCache.isGETRequest(request) {
            return .NoDueToHTTPMethod
        }
        if request.cachePolicy() == .ReloadIgnoringCacheData && !request.isConditional() {
            return .NoDueToReloadIgnoringCache
        }
        return .Yes
    }

    /// Whether a response may be stored in the cache.
    ///
    /// `originalRequest` and `response` are borrowed for the call. NetworkCacheTestSupport passes temporaries, and
    /// store, storeRedirect and storeCompressionDictionary pass their own borrowed parameters. The C++ called with
    /// them is getters, `parseRequestDirectives` and `computeFreshnessLifetimeForHTTPFamily`, which are free functions
    /// that read and return values.
    public static func makeStoreDecision(
        _ originalRequest: WebCore.ResourceRequest,
        _ response: WebCore.ResourceResponse,
        _ bodySize: Int
    ) -> WebKit.NetworkCache.StoreDecision {
        if !originalRequest.urlCopy().protocolIsInHTTPFamily() || !response.isInHTTPFamily() {
            return .NoDueToProtocol
        }

        if !WebKit.NetworkCache.isGETRequest(originalRequest) {
            return .NoDueToHTTPMethod
        }

        let requestDirectives = WebKit.NetworkCache.parseRequestDirectives(originalRequest)
        if requestDirectives.noStore {
            return .NoDueToNoStoreRequest
        }

        if response.cacheControlContainsNoStore() {
            return .NoDueToNoStoreResponse
        }

        let statusCode = response.httpStatusCode()
        if statusCode == WebCore.httpStatus304NotModified {
            return .NoDueToHTTPStatusCode
        }

        if !WebCore.isStatusCodeCacheableByDefault(Int32(statusCode)) {
            // http://tools.ietf.org/html/rfc7234#section-4.3.2
            let hasExpirationHeaders = response.expires().hasValue || response.cacheControlMaxAge().hasValue
            if !hasExpirationHeaders && !response.cacheControlContainsPublic() {
                return .NoDueToMissingExpirationHeaders
            }
        }

        // FIXME: We are not correctly computing the redirected request URL in case original request
        // has a fragment identifier and response location URL does not have one. Let's not store it for now.
        if (response.isRedirection() || response.isRedirected()) && originalRequest.urlCopy().hasFragmentIdentifier() {
            return .NoDueToRequestContainingFragments
        }

        let requester = originalRequest.requester()
        let isMainResource = requester == .Main
        let storeUnconditionallyForHistoryNavigation = isMainResource || originalRequest.priority() == .VeryHigh
        if !storeUnconditionallyForHistoryNavigation {
            let now = WTF.WallTime.now()
            let allowedStale = response.cacheControlStaleWhileRevalidate().value?.value() ?? 0
            let hasNonZeroLifetime =
                !response.cacheControlContainsNoCache()
                && (WebCore.computeFreshnessLifetimeForHTTPFamily(response, now).value() > 0 || allowedStale > 0)
            let possiblyReusable = response.hasCacheValidatorFields() || hasNonZeroLifetime
            if !possiblyReusable {
                return .NoDueToUnlikelyToReuse
            }
        }

        // Media loaded via XHR is likely being used for MSE streaming (YouTube and Netflix for example).
        // Streaming media fills the cache quickly and is unlikely to be reused.
        // FIXME: We should introduce a separate media cache partition that doesn't affect other resources.
        // FIXME: We should also make sure make the MSE paths are copy-free so we can use mapped buffers from disk effectively.
        let isDefinitelyStreamingMedia = requester == .Media
        let isLikelyStreamingMedia = requester == .XHR && WebKit.NetworkCache.isMediaMIMEType(response.mimeTypeCopy())
        if isLikelyStreamingMedia || isDefinitelyStreamingMedia {
            return .NoDueToStreamingMedia
        }

        return .Yes
    }

    // MARK: Entries

    /// An entry for a response and its body, keyed by the request.
    ///
    /// `request` is borrowed for the call. NetworkResourceLoader passes its own argument, and store and the
    /// speculative load pass theirs. The C++ called with it is `makeCacheKey` (getters and the `Key` constructor) and
    /// the Vary collection (`networkCacheCollectVaryingRequestHeaders`, which can read the session's cookies), and
    /// neither reaches the request's owner.
    public func makeEntry(
        _ request: borrowing WebCore.ResourceRequest,
        _ response: consuming WebCore.ResourceResponse,
        _ privateRelayed: WebKit.PrivateRelayed,
        _ responseData: consuming WebKit.NetworkCache.FragmentedBufferPtr
    ) -> NetworkCacheEntry {
        let key = makeCacheKey(.Resource, request)
        let varyingRequestHeaders = WebKit.NetworkCache.networkCacheCollectVaryingRequestHeaders(sessionID, request, response)
        return NetworkCacheEntry.make(
            key: key,
            response: response,
            privateRelayed: privateRelayed == .Yes,
            buffer: responseData,
            varyingRequestHeaders: varyingRequestHeaders
        )
    }

    /// An entry for a redirect, keyed by the request.
    ///
    /// `request` is borrowed for the call, as in makeEntry: NetworkResourceLoader, storeRedirect and the speculative
    /// load pass their own, and the C++ called with it is the same `makeCacheKey` and Vary collection.
    public func makeRedirectEntry(
        _ request: borrowing WebCore.ResourceRequest,
        _ response: consuming WebCore.ResourceResponse,
        _ redirectRequest: consuming WebCore.ResourceRequest
    ) -> NetworkCacheEntry {
        redirectRequest.clearHTTPAuthorization()
        let key = makeCacheKey(.Resource, request)
        let varyingRequestHeaders = WebKit.NetworkCache.networkCacheCollectVaryingRequestHeaders(sessionID, request, response)
        return NetworkCacheEntry.makeRedirect(
            key: key,
            response: response,
            redirectRequest: redirectRequest,
            varyingRequestHeaders: varyingRequestHeaders
        )
    }

    /// Stores a response and its body, keyed by the request.
    ///
    /// `request` and `response` are borrowed for the call. The callers are NetworkResourceLoader (the request of
    /// `retrieveCacheEntry`, and `m_networkLoad->currentRequest()` with `m_response`, both owned by the loader),
    /// NetworkCacheTestSupport, and the speculative load. The C++ called with them is makeStoreDecision, makeEntry
    /// (which gets `copy response`), `isTopSite` and the Vary collection; the storage gets only the encoded record.
    ///
    /// The completion handler can hold a reference to the loader that owns both arguments. The storage drops it
    /// when its capacity is zero, and removeKey on the not-stored path drops the handlers of other pending writes.
    /// Either can release the loader, and both happen after the last read of `request` and `response`
    /// (`isTopSite` and `httpStatusCode` come first).
    public func store(
        _ request: borrowing WebCore.ResourceRequest,
        _ response: borrowing WebCore.ResourceResponse,
        _ privateRelayed: WebKit.PrivateRelayed,
        _ responseData: consuming WebKit.NetworkCache.FragmentedBufferPtr,
        _ completionHandler: WebKit.NetworkCache.MappedBodyHandlerBox
    ) -> NetworkCacheEntry? {
        store(request, response, privateRelayed, responseData, WebKit.NetworkCache.takeMappedBodyHandler(completionHandler))
    }

    // The C++ entry boxes the mapped body handler and this one takes it, so store has two overloads.
    func store(
        _ request: borrowing WebCore.ResourceRequest,
        _ response: borrowing WebCore.ResourceResponse,
        _ privateRelayed: WebKit.PrivateRelayed,
        _ responseData: consuming WebKit.NetworkCache.FragmentedBufferPtr,
        _ completionHandler: consuming WebKit.NetworkCache.MappedBodyHandler
    ) -> NetworkCacheEntry? {
        assert(!WebKit.NetworkCache.bufferIsNull(responseData))

        let log = WebKit.LogChannel.NetworkCache()
        // os.Logger's interpolation arguments escape, and a borrowed parameter cannot be captured, so the reads are guarded.
        if log.state != .Off {
            let url = request.urlCopy().stringCopy()
            let partition = makeCacheKey(.Resource, request).partitionCopy()
            log.debugLog.log(
                "(NetworkProcess) storing \(url.description, privacy: .public), partition \(partition.description, privacy: .public)"
            )
        }

        let storeDecision = Self.makeStoreDecision(request, response, WebKit.NetworkCache.networkCacheBufferSize(responseData))
        if storeDecision != .Yes {
            log.debugLog.log("(NetworkProcess) didn't store, storeDecision=\(storeDecision.rawValue)")
            let key = makeCacheKey(.Resource, request)
            let isSuccessfulRevalidation = response.httpStatusCode() == WebCore.httpStatus304NotModified
            if !isSuccessfulRevalidation {
                // Make sure we don't keep a stale entry in the cache.
                removeKey(key)
            }
            return nil
        }

        let cacheEntry = makeEntry(request, copy response, privateRelayed, responseData)
        let record = cacheEntry.encodeAsStorageRecord()
        let storeBlobInMemoryCache = request.isTopSite()

        let box = NetworkCacheHandlerBox(completionHandler)
        storage.store(record, storeBlobInMemoryCache: storeBlobInMemoryCache) { [self] bodyData in
            _ = self // Keeps the cache alive until the body is stored.
            WebKit.NetworkCache.invokeMappedBodyHandler(&box.handler, bodyData)
            WebKit.LogChannel.NetworkCache().debugLog.log("(NetworkProcess) stored")
        }
        return cacheEntry
    }

    /// Stores a redirect response, keyed by the request.
    ///
    /// `request`, `response` and `redirectRequest` are borrowed for the call. NetworkResourceLoader passes locals and
    /// its parameters, NetworkCacheTestSupport passes temporaries, and the speculative load passes its own. The C++
    /// called with them is makeStoreDecision and the URL getters; makeRedirectEntry gets copies of `response` and
    /// `redirectRequest`. Everything is read and copied before `storage.store`, which gets only the record and no
    /// completion handler.
    public func storeRedirect(
        _ request: borrowing WebCore.ResourceRequest,
        _ response: borrowing WebCore.ResourceResponse,
        _ redirectRequest: borrowing WebCore.ResourceRequest,
        _ maxAgeCap: WebKit.NetworkCache.OptionalSeconds
    ) -> NetworkCacheEntry? {
        let log = WebKit.LogChannel.NetworkCache()
        // As in store: the borrowed parameters cannot be captured by the log's arguments.
        if log.state != .Off {
            let url = request.urlCopy().stringCopy()
            let redirectURL = redirectRequest.urlCopy().stringCopy()
            log.debugLog.log(
                "(NetworkProcess) storing redirect \(url.description, privacy: .public) -> \(redirectURL.description, privacy: .public)"
            )
        }

        let storeDecision = Self.makeStoreDecision(request, response, 0)
        if storeDecision != .Yes {
            log.debugLog.log("(NetworkProcess) didn't store redirect, storeDecision=\(storeDecision.rawValue)")
            return nil
        }

        let cacheEntry = makeRedirectEntry(request, copy response, copy redirectRequest)
        if let cap = maxAgeCap.value {
            log.debugLog.log("(NetworkProcess) capping max age for redirect")
            cacheEntry.capMaxAge(cap)
        }

        let record = cacheEntry.encodeAsStorageRecord()
        storage.store(record, storeBlobInMemoryCache: false, nil)
        return cacheEntry
    }

    /// Stores a response body as a compression dictionary.
    ///
    /// `request` and `response` are borrowed for the call. NetworkResourceLoader passes the loader's current or
    /// original request with a response it holds, and NetworkCacheTestSupport passes temporaries. The C++ called with
    /// them is `makeCacheKey` and makeStoreDecision. Both are last read before removeKey or `storage.store`, which
    /// has no completion handler, and the index is Swift.
    public func storeCompressionDictionary(
        _ request: borrowing WebCore.ResourceRequest,
        _ response: borrowing WebCore.ResourceResponse,
        _ responseData: consuming WebKit.NetworkCache.FragmentedBufferPtr,
        _ info: consuming WebKit.NetworkCache.CompressionDictionaryInfo
    ) {
        assert(!WebKit.NetworkCache.bufferIsNull(responseData))

        let key = makeCacheKey(.CompressionDictionary, request)
        let log = WebKit.LogChannel.NetworkCache()
        if log.state != .Off {
            let url = request.urlCopy().stringCopy()
            let partition = key.partitionCopy()
            log.debugLog.log(
                "(NetworkProcess) storing compression dictionary \(url.description, privacy: .public), partition \(partition.description, privacy: .public)"
            )
        }

        let storeDecision = Self.makeStoreDecision(request, response, WebKit.NetworkCache.networkCacheBufferSize(responseData))
        if storeDecision != .Yes {
            log.debugLog.log("(NetworkProcess) didn't store compression dictionary, storeDecision=\(storeDecision.rawValue)")
            // Make sure we don't keep a stale dictionary in the cache.
            removeKey(key)
            return
        }

        let cacheEntry = NetworkCacheCompressionDictionaryEntry.make(key: key, info: info, buffer: responseData)
        let record = cacheEntry.encodeAsStorageRecord()
        storage.store(record, storeBlobInMemoryCache: false, nil)

        addToCompressionDictionaryIndex(cacheEntry)
    }

    /// Updates an entry's stored response after a successful revalidation.
    ///
    /// `originalRequest` and `validatingResponse` are borrowed for the call. NetworkResourceLoader passes its
    /// `originalRequest()` and `m_response`, NetworkCacheTestSupport passes a local and a temporary, and the
    /// speculative load passes its own. The C++ called with them is `updateResponseHeadersAfterRevalidation` (into a
    /// copy of the entry's response), `ipAddressSpace`, the Vary collection and `isTopSite`. `originalRequest` is
    /// last read before `storage.store`, which has no completion handler.
    public func update(
        _ originalRequest: borrowing WebCore.ResourceRequest,
        _ existingEntry: NetworkCacheEntry,
        _ validatingResponse: borrowing WebCore.ResourceResponse,
        _ privateRelayed: WebKit.PrivateRelayed
    ) -> NetworkCacheEntry {
        let log = WebKit.LogChannel.NetworkCache()
        if log.state != .Off {
            let url = originalRequest.urlCopy().stringCopy()
            log.debugLog.log("(NetworkProcess) updating \(url.description, privacy: .public)")
        }
        var response = existingEntry.response()
        WebCore.updateResponseHeadersAfterRevalidation(&response, validatingResponse)
        response.setIPAddressSpace(validatingResponse.ipAddressSpace())

        let updateEntry = NetworkCacheEntry.make(
            key: existingEntry.key(),
            response: response,
            privateRelayed: privateRelayed == .Yes,
            buffer: existingEntry.buffer(),
            varyingRequestHeaders: WebKit.NetworkCache.networkCacheCollectVaryingRequestHeaders(
                sessionID,
                originalRequest,
                response
            )
        )
        let updateRecord = updateEntry.encodeAsStorageRecord()
        let storeBlobInMemoryCache = originalRequest.isTopSite()

        storage.store(updateRecord, storeBlobInMemoryCache: storeBlobInMemoryCache, nil)
        return updateEntry
    }

    // MARK: Compression dictionaries

    /// The keys of the compression dictionaries registered in a partition.
    ///
    /// `partition` is borrowed from a local of the C++ caller (NetworkCacheWebsiteData). It is copied into an
    /// isolated string first, and the rest is Swift.
    public func compressionDictionaryKeys(_ partition: borrowing WTF.String) -> WebKit.NetworkCache.KeyVector {
        var keys = WebKit.NetworkCache.KeyVector()
        for entry in compressionDictionaryIndex.entries(inPartition: NetworkCacheIsolatedString(partition)) {
            keys.append(consuming: entry.key)
        }
        return keys
    }

    /// The keys of the records of the given types still waiting to be written.
    ///
    /// `partition` is borrowed for the call. The C++ callers pass `String()` or a local (NetworkCacheWebsiteData,
    /// NetworkCacheTestSupport). The storage compares it in place with the pending records' partitions, and no C++
    /// other than the string comparison and the `Key` copies runs.
    public func pendingKeys(
        _ types: UInt8,
        _ hasPartition: Bool,
        _ partition: borrowing WTF.String
    ) -> WebKit.NetworkCache.KeyVector {
        var keys = WebKit.NetworkCache.KeyVector()
        for type in [WebKit.NetworkCache.RecordType.Resource, .CompressionDictionary] where types & type.rawValue != 0 {
            let typeKeys = storage.pendingWriteKeys(
                ofType: WebKit.NetworkCache.recordTypeNameString(type),
                hasPartition: hasPartition,
                partition: partition
            )
            for index in 0..<typeKeys.size() {
                keys.append(consuming: typeKeys[index])
            }
        }
        return keys
    }

    /// The best matching dictionary for a request.
    ///
    /// https://fetch.spec.whatwg.org/#find-the-best-matching-dictionary
    ///
    /// `request` is borrowed for the call. NetworkResourceLoader passes a local, the Cocoa and Soup data tasks pass
    /// the redirect's request, and NetworkCacheTestSupport passes a temporary. The C++ called with it is
    /// `cachePartition`, `urlCopy` and the pattern's `test` on the URL copy.
    ///
    /// `request` is read again after `storage.remove`, which destroys pending write operations. The only write with a
    /// completion handler is store's, under a resource key. Every dictionary write passes none, so what is destroyed
    /// here holds only records, and no destructor that runs reaches the request.
    public func bestCompressionDictionaryMatch(
        _ request: borrowing WebCore.ResourceRequest,
        _ destination: WebCore.FetchOptions.Destination
    ) -> WebKit.NetworkCache.OptionalDictionaryMatch {
        if compressionDictionaryIndex.isEmpty {
            return .init()
        }

        // https://www.rfc-editor.org/rfc/rfc9842#name-dictionary-freshness-requir
        // Removing an expired entry also removes its record.
        let entries = compressionDictionaryIndex.unexpiredEntries(
            inPartition: NetworkCacheIsolatedString(request.cachePartition()),
            now: WTF.WallTime.nowSeconds
        ) { storage.remove($0.key) }
        if entries.isEmpty {
            return .init()
        }

        let url = request.urlCopy()
        var best: NetworkCacheCompressionDictionaryIndex.Entry?
        for entry in entries {
            // https://www.rfc-editor.org/rfc/rfc9842#name-match-dest
            if !entry.matchDest.isEmpty()
                && !entry.matchDest.contains(destination)
            {
                continue
            }
            if let best, !entry.isBetterMatch(than: best) {
                continue
            }
            if !storage.mayContain(entry.key) {
                continue
            }
            if !entry.pattern.test(url) {
                continue
            }
            best = entry
        }

        guard let best else {
            return .init()
        }
        return WebKit.NetworkCache.makeDictionaryMatch(best.key, best.hash, best.id)
    }

    /// Retrieves the compression dictionary stored under a key, if its hash matches.
    public func retrieveCompressionDictionary(
        _ key: consuming WebKit.NetworkCache.Key,
        _ hash: WebKit.NetworkCache.CompressionDictionaryHash,
        _ completionHandler: WebKit.NetworkCache.SharedBufferHandlerBox
    ) {
        let key = key // A consuming parameter cannot be captured by the escaping closure.
        let retrieveStartTime = WTF.WallTime.nowSeconds
        let box = NetworkCacheHandlerBox(Optional(WebKit.NetworkCache.takeSharedBufferHandler(completionHandler)))
        storage.retrieve(key, priority: 1) { [self] record, _ in
            let entry = record.isNull() ? nil : NetworkCacheCompressionDictionaryEntry.decodeStorageRecord(record)
            guard let entry else {
                // A storage shrink can evict a record without telling the cache, so the index outlives it.
                compressionDictionaryIndex.remove(key, registeredNotAfter: retrieveStartTime)
                box.complete(WebKit.NetworkCache.SharedBufferPtr())
                return false
            }
            var buffer = WebKit.NetworkCache.SharedBufferPtr()
            if WebKit.NetworkCache.dictionaryHashEquals(entry.hash(), hash) {
                buffer = entry.buffer()
            }
            box.complete(buffer)
            return true
        }
    }

    private func addToCompressionDictionaryIndex(_ entry: NetworkCacheCompressionDictionaryEntry) {
        let key = entry.key()
        compressionDictionaryIndex.remove(key, registeredNotAfter: .infinity)

        let info = entry.info()
        let expirationTime = info.expirationTime.seconds
        if expirationTime <= WTF.WallTime.nowSeconds {
            storage.remove(key)
            return
        }

        let pattern = WebKit.NetworkCache.makeDictionaryPattern(info.match, key.identifierCopy())
        if pattern.isNull() {
            return
        }

        compressionDictionaryIndex.add(
            NetworkCacheCompressionDictionaryIndex.Entry(
                key: key,
                hash: entry.hash(),
                id: info.id,
                pattern: pattern,
                matchDest: info.matchDest,
                matchLength: info.match.length(),
                expirationTime: expirationTime,
                timeStamp: entry.timeStamp().seconds
            )
        )
    }

    private func populateCompressionDictionaryIndex() {
        compressionDictionaryIndex.beginPopulation()
        traverseRecordsOfTypes([.CompressionDictionary], partition: nil) { [self] record, _ in
            guard let record else {
                compressionDictionaryIndex.endPopulation()
                return
            }
            guard let entry = NetworkCacheCompressionDictionaryEntry.decodeStorageRecord(record) else {
                return
            }
            if compressionDictionaryIndex.shouldPopulate(entry.key(), timeStamp: entry.timeStamp().seconds) {
                addToCompressionDictionaryIndex(entry)
            }
        }
    }

    // MARK: Remove, clear

    /// Removes the record stored under a key.
    ///
    /// `key` is borrowed for the call. NetworkResourceLoader passes the by-value result of `entry->key()`, a
    /// temporary on its stack, and the Swift callers pass locals. The index and `storage.remove` are Swift, and the
    /// storage copies the key for its IO, so destroying pending writes cannot free the argument.
    public func removeKey(_ key: borrowing WebKit.NetworkCache.Key) {
        compressionDictionaryIndex.remove(key, registeredNotAfter: .infinity)
        storage.remove(key)
    }

    /// Removes the record stored for a request.
    ///
    /// `request` is borrowed for the call. NetworkResourceLoader passes `networkLoad->currentRequest()` (the load is
    /// held by a local `RefPtr`) and NetworkCacheTestSupport a temporary. The only C++ called with it is
    /// `makeCacheKey`, which finishes before removeKey runs.
    public func removeRequest(_ request: borrowing WebCore.ResourceRequest) {
        removeKey(makeCacheKey(.Resource, request))
    }

    /// Removes the records stored under the keys, then calls the completion handler.
    ///
    /// `keys` is borrowed for the call. The callers in NetworkCacheWebsiteData pass `keysToDelete` or
    /// `cacheKeysToDelete`, which are captures of the traversal lambda that is running. The loop copies each key
    /// into `keysToRemove` and reads `keys` for the last time before `storage.remove`. Until then only Swift
    /// (the compression dictionary index) runs.
    public func removeKeys(
        _ keys: borrowing WebKit.NetworkCache.KeyVector,
        _ completionHandler: WebKit.NetworkCache.VoidHandlerBox,
        _ dictionariesRegisteredNotAfter: WTF.WallTime
    ) {
        let notAfter = dictionariesRegisteredNotAfter.seconds
        var keysToRemove = WebKit.NetworkCache.KeyVector()
        for index in 0..<keys.size() where compressionDictionaryIndex.remove(keys[index], registeredNotAfter: notAfter) {
            keysToRemove.append(consuming: keys[index])
        }
        storage.remove(keysToRemove, WebKit.NetworkCache.takeVoidHandler(completionHandler))
    }

    /// Removes the records modified since a time, then calls the completion handler.
    public func clear(_ modifiedSince: WTF.WallTime, _ completionHandler: WebKit.NetworkCache.VoidHandlerBox) {
        clear(modifiedSince, WebKit.NetworkCache.takeVoidHandler(completionHandler))
    }

    private func clear(_ modifiedSince: WTF.WallTime, _ completionHandler: consuming WTF.VoidCompletionHandler) {
        WebKit.LogChannel.NetworkCache().debugLog.log("(NetworkProcess) clearing cache")

        compressionDictionaryIndex.clear(since: modifiedSince.seconds)

        storage.clear(ofType: WTF.String(), modifiedSince: modifiedSince, completionHandler)

        deleteDumpFile()
    }

    // MARK: Traversal

    /// Calls the handler with each stored resource record, then once with none.
    public func traverseRecords(_ traverseHandler: WebKit.NetworkCache.TraversalHandlerBox) {
        // Protect against clients making excessive traversal requests.
        if traverseCount >= Self.maximumTraverseCount {
            WebKit.LogChannel.NetworkCache().releaseLog.error("Maximum parallel cache traverse count exceeded. Ignoring traversal request.")
            WebKit.NetworkCache.dispatchOnMain(
                consuming: .init {
                    WebKit.NetworkCache.invokeTraversalHandlerAtEnd(traverseHandler)
                }
            )
            return
        }

        traverseCount += 1

        traverseRecordsOfTypes([.Resource, .CompressionDictionary], partition: nil) { [self] record, info in
            guard let record else {
                traverseCount -= 1
                WebKit.NetworkCache.invokeTraversalHandlerAtEnd(traverseHandler)
                return
            }
            WebKit.NetworkCache.invokeTraversalHandler(traverseHandler, record, info)
        }
    }

    /// Calls the handler with each stored resource and dictionary record in a partition, then once with none.
    public func traverseRecordsInPartition(
        _ partition: consuming WTF.String,
        _ traverseHandler: WebKit.NetworkCache.TraversalHandlerBox
    ) {
        traverseRecordsOfTypes([.Resource, .CompressionDictionary], partition: consume partition, traverseHandler)
    }

    /// Calls the handler with each stored compression dictionary record in a partition, then once with none.
    public func traverseCompressionDictionaryRecords(
        _ partition: consuming WTF.String,
        _ traverseHandler: WebKit.NetworkCache.TraversalHandlerBox
    ) {
        traverseRecordsOfTypes([.CompressionDictionary], partition: consume partition, traverseHandler)
    }

    private func traverseRecordsOfTypes(
        _ types: [WebKit.NetworkCache.RecordType],
        partition: WTF.String?,
        flags: UInt8 = 0,
        _ traverseHandler: WebKit.NetworkCache.TraversalHandlerBox
    ) {
        traverseRecordsOfTypes(types, partition: partition, flags: flags) { record, info in
            guard let record else {
                WebKit.NetworkCache.invokeTraversalHandlerAtEnd(traverseHandler)
                return
            }
            WebKit.NetworkCache.invokeTraversalHandler(traverseHandler, record, info)
        }
    }

    /// Records whose type is one of `types`, then none.
    private func traverseRecordsOfTypes(
        _ types: [WebKit.NetworkCache.RecordType],
        partition: WTF.String?,
        flags: UInt8 = 0,
        _ handler: @escaping (WebKit.NetworkCache.Storage.Record?, WebKit.NetworkCache.Storage.RecordInfo) -> Void
    ) {
        assert(!types.isEmpty)

        // Storage takes one type name, or an empty one to walk every type.
        let typeName = types.count == 1 ? WebKit.NetworkCache.recordTypeNameString(types[0]) : WTF.String()
        storage.traverse(typeName, partition: partition, flags) { record, info in
            guard let record else {
                handler(nil, info)
                return
            }
            if let type = record.key.recordType, types.contains(type) {
                handler(record, info)
            }
        }
    }

    // MARK: Dump

    /// Writes the cache's records as JSON to `dump.json`.
    public func dumpContentsToFile() {
        let dumpFile = WebKit.NetworkCache.DumpFile.create().get()
        if !dumpFile.open(dumpFilePath()) {
            return
        }
        let file = NetworkCacheDumpJSON(dumpFile)
        file.appendPrologue()
        file.write()

        var totals = (count: UInt64(0), worth: 0.0, bodySize: UInt64(0))
        let capacity = UInt64(storage.capacity)
        let flags =
            WebKit.NetworkCache.Storage.TraverseFlag.ComputeWorth.rawValue | WebKit.NetworkCache.Storage.TraverseFlag.ShareCount.rawValue
        traverseRecordsOfTypes([.Resource, .CompressionDictionary], partition: nil, flags: flags) { record, info in
            guard let record else {
                file.appendTotals(
                    capacity: capacity,
                    count: totals.count,
                    bodySize: totals.bodySize,
                    averageWorth: totals.count != 0 ? totals.worth / Double(totals.count) : 0
                )
                file.write()
                file.close()
                return
            }
            if record.key.recordType == .CompressionDictionary {
                guard let entry = NetworkCacheCompressionDictionaryEntry.decodeStorageRecord(record) else {
                    return
                }
                file.append(entry, info)
            } else {
                guard let entry = NetworkCacheEntry.decodeStorageRecord(record) else {
                    return
                }
                file.append(entry, info)
            }

            totals.count += 1
            totals.worth += info.worth
            totals.bodySize += UInt64(info.bodySize)

            file.appendEntrySeparator()
            file.write()
        }
    }

    // MARK: Retrieve

    /// The storage's or the speculative load's completion keeps `request`, so it is taken `consuming`.
    public func retrieve(
        _ request: consuming WebCore.ResourceRequest,
        _ frameID: WebKit.NetworkCache.OptionalFrameID,
        _ isNavigatingToAppBoundDomain: WebKit.NetworkCache.OptionalAppBoundDomain,
        _ allowPrivacyProxy: Bool,
        _ advancedPrivacyProtections: WebKit.NetworkCache.NetworkCacheAdvancedPrivacyProtections,
        _ completionHandler: WebKit.NetworkCache.RetrieveHandlerBox
    ) {
        assert(request.urlCopy().protocolIsInHTTPFamily())
        let loadOptions = NetworkCacheLoadOptions(
            isNavigatingToAppBoundDomain: isNavigatingToAppBoundDomain,
            allowPrivacyProxy: allowPrivacyProxy,
            advancedPrivacyProtections: advancedPrivacyProtections
        )

        let storageKey = makeCacheKey(.Resource, request)
        let priority = UInt32(request.priority().rawValue)
        WebKit.LogChannel.NetworkCache().debugLog
            .log("(NetworkProcess) retrieving \(request.urlCopy().stringCopy().description, privacy: .public) priority \(priority)")

        var info = WebKit.NetworkCache.RetrieveInfo()
        info.url = request.urlCopy()
        info.startTime = WTF.MonotonicTime.now()
        info.priority = priority

        let box = NetworkCacheHandlerBox(Optional(WebKit.NetworkCache.takeRetrieveHandler(completionHandler)))

        // Speculative revalidation needs a frame, a speculative load manager, and a request that can use it.
        let canUseSpeculativeRevalidation =
            frameID.hasValue && speculativeLoadManager != nil
            && request.canUseSpeculativeRevalidation
        if canUseSpeculativeRevalidation, let speculativeLoadManager, let globalFrameID = frameID.value {
            speculativeLoadManager.registerLoad(globalFrameID, request, storageKey, loadOptions)
        }

        let retrieveDecision = Self.makeRetrieveDecision(request)
        info.setRetrieveDecision(retrieveDecision)
        if retrieveDecision != .Yes {
            completeRetrieve(box, nil, &info)
            return
        }

        info.setSpeculativeLoadDecision(.NoDueToCannotUse)
        if canUseSpeculativeRevalidation, let speculativeLoadManager, let globalFrameID = frameID.value,
            speculativeLoadManager.canRetrieve(storageKey, request, globalFrameID)
        {
            retrieveSpeculatively(speculativeLoadManager, storageKey, request, info, box)
            return
        }

        storage.retrieve(storageKey, priority: priority) { [self, request] record, timings in
            var info = info
            info.storageTimings = timings
            return finishRetrieve(
                record,
                request,
                storageKey,
                frameID,
                loadOptions,
                box,
                &info
            )
        }
    }

    /// Takes the entry a token names.
    ///
    /// A token 0 is a miss, which the C++ caller tests first. A token taken twice, never parked or 0 traps.
    public func takeRetrievedEntry(_ token: UInt64) -> NetworkCacheEntry {
        guard let entry = retrievedEntries.take(token) else {
            fatalError("A retrieved entry's token was taken twice or never parked")
        }
        return entry
    }
}

// MARK: - Weak reference and handler boxes

/// A weak reference to the cache, for C++ code that refers to it without owning it.
@_expose(Cxx)
public final class NetworkDiskCacheWeakReference {
    private weak var cache: NetworkDiskCache?

    init(_ cache: NetworkDiskCache) {
        self.cache = cache
    }

    /// The cache, if it still exists.
    public func get() -> NetworkDiskCache? { cache }
}

extension NetworkCacheHandlerBox where Handler == WebKit.NetworkCache.SharedBufferCompletionHandler? {
    fileprivate func complete(_ buffer: consuming WebKit.NetworkCache.SharedBufferPtr) {
        guard let handler = handler.take() else {
            fatalError("A dictionary retrieve completes once")
        }
        WebKit.NetworkCache.invokeSharedBufferCompletionHandler(consuming: handler, buffer)
    }
}
