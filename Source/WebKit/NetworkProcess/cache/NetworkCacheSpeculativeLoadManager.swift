// Copyright (C) 2015-2025 Apple Inc. All rights reserved.
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

extension Dictionary {
    fileprivate mutating func addIfAbsent(_ key: Key, _ value: Value) {
        // A key already present keeps its value; the new one is dropped.
        if self[key] == nil {
            self[key] = value
        }
    }
}

private func makeRevalidationRequest(
    _ info: NetworkCacheSubresourceInfo,
    _ context: SpeculativeLoadContext,
    _ entry: NetworkCacheEntry?
) -> WebCore.ResourceRequest {
    var revalidationRequest = WebCore.ResourceRequest(consuming: WebKit.NetworkCache.networkCacheURL(info.key.identifierCopy()))
    revalidationRequest.setShouldBlockThirdPartyStorage(!info.key.partitionCopy().isEmpty())
    revalidationRequest.setHTTPHeaderFields(info.requestHeaders)
    revalidationRequest.setFirstPartyForCookies(info.firstPartyForCookies)
    revalidationRequest.setIsSameSite(info.isSameSite)
    revalidationRequest.setIsTopSite(info.isTopSite)
    revalidationRequest.setIsAppInitiated(context.isAppInitiated)

    assert(info.key.rangeCopy().isEmpty(), "range is not supported")

    revalidationRequest.makeUnconditional()
    if let entry {
        revalidationRequest.setCacheValidatorHeaders(from: entry.response())
    }

    revalidationRequest.setPriority(info.priority)
    return revalidationRequest
}

private func isStaleOrNoCache(_ response: borrowing WebCore.ResourceResponse, _ timestamp: WTF.WallTime) -> Bool {
    if response.cacheControlContainsNoCache() {
        return true
    }
    let (age, lifetime) = response.ageAndFreshnessLifetime(at: timestamp)
    return age - lifetime > 0
}

// Not borrowing: an assert's autoclosure cannot capture a borrowed C++ value.
private func canRevalidate(_ info: NetworkCacheSubresourceInfo, _ entry: NetworkCacheEntry?) -> Bool {
    assert(!info.isTransient)
    assert(entry?.needsValidation() ?? true)

    if let entry, entry.response().hasCacheValidatorFields() {
        return true
    }

    let seenAge = info.lastSeen.seconds - info.firstSeen.seconds
    if seenAge == 0 {
        WebKit.LogChannel.NetworkCacheSpeculativePreloading().debugLog.log("Speculative load: Seen only once")
        return false
    }

    let now = WTF.WallTime.nowSeconds
    let firstSeenAge = now - info.firstSeen.seconds
    let lastSeenAge = now - info.lastSeen.seconds
    // Sanity check.
    if seenAge <= 0 || firstSeenAge <= 0 || lastSeenAge <= 0 {
        return false
    }

    // Load full resources speculatively if they seem to stay the same.
    let minimumAgeRatioToLoad = 2.0 / 3
    let recentMinimumAgeRatioToLoad = 1.0 / 3
    let recentThreshold = 5.0 * 60

    let ageRatio = seenAge / firstSeenAge
    let minimumAgeRatio = lastSeenAge > recentThreshold ? minimumAgeRatioToLoad : recentMinimumAgeRatioToLoad

    WebKit.LogChannel.NetworkCacheSpeculativePreloading().debugLog
        .log("Speculative load: ok=\(ageRatio > minimumAgeRatio) ageRatio=\(ageRatio) entry=\(entry != nil)")

    return ageRatio > minimumAgeRatio
}

/// An entry that runs `expirationHandler` once its lifetime ends, unless it is destroyed first.
private class ExpiringEntry {
    private static let lifetime = 10.0

    private let lifetimeTimer = WebKit.NetworkCache.OneShotTimer.create().get()

    init(_ expirationHandler: @escaping () -> Void) {
        lifetimeTimer.setHandler(consuming: .init(expirationHandler))
        lifetimeTimer.startOneShot(Self.lifetime)
    }

    deinit {
        // A timer destroyed with its handler set calls it. This handler is strong, so an empty one replaces it.
        lifetimeTimer.stop()
        lifetimeTimer.setHandler(consuming: .init {})
    }
}

private final class PreloadedEntry: ExpiringEntry {
    private var entry: NetworkCacheEntry?
    let revalidationRequest: WebCore.ResourceRequest?

    init(_ entry: NetworkCacheEntry, revalidationRequest: consuming WebCore.ResourceRequest?, lifetimeReachedHandler: @escaping () -> Void)
    {
        self.entry = entry
        self.revalidationRequest = revalidationRequest
        super.init(lifetimeReachedHandler)
    }

    func takeCacheEntry() -> NetworkCacheEntry? {
        assert(entry != nil)
        return entry.take()
    }

    var wasRevalidated: Bool { revalidationRequest != nil }

    var wastedDiagnostic: NetworkCacheSpeculativeLoadDiagnostic {
        wasRevalidated ? .wastedWarmupWithRevalidation : .wastedWarmupWithoutRevalidation
    }

    var usedDiagnostic: NetworkCacheSpeculativeLoadDiagnostic {
        wasRevalidated ? .successfulWarmupWithRevalidation : .successfulWarmupWithoutRevalidation
    }

    func canSatisfy(_ actualRequest: borrowing WebCore.ResourceRequest) -> Bool {
        guard let revalidationRequest else {
            return true
        }
        return requestsHeadersMatch(revalidationRequest, actualRequest)
    }
}

/// What the speculative loads started for one main resource load share.
private struct SpeculativeLoadContext {
    let isAppInitiated: Bool
    let frameID: WebKit.NetworkCache.GlobalFrameID
    let loadOptions: NetworkCacheLoadOptions
}

private enum PendingPreload {
    case lookingInStorage
    case revalidating(NetworkCacheSpeculativeLoad)

    fileprivate var isLookingInStorage: Bool {
        if case .lookingInStorage = self { true } else { false }
    }
}

extension WebCore.ResourceRequest {
    fileprivate var shouldRegisterLoad: Bool {
        if !WebKit.NetworkCache.isGETRequest(self) {
            return false
        }
        if !httpHeaderField(WebCore.HTTPHeaderName.Range).isEmpty() {
            return false
        }
        return true
    }
}

/// The speculative load manager: records the subresources each main resource loads, and on the next load of that main
/// resource preloads or revalidates them ahead of their requests.
///
/// Main thread only; owned by the cache (NetworkDiskCache), which it does not retain.
final class NetworkCacheSpeculativeLoadManager {
    typealias RetrieveCompletionHandler = (NetworkCacheEntry?) -> Void

    private unowned let cache: NetworkDiskCache
    // The cache's storage, which the cache owns as it owns this manager.
    private let storage: NetworkCacheStorage

    private var pendingFrameLoads: [NetworkCacheHashableFrameID: NetworkCachePendingFrameLoad] = [:]
    private var pendingPreloads: [NetworkCacheHashableKey: PendingPreload] = [:]
    private var pendingRetrieveRequests: [NetworkCacheHashableKey: [RetrieveCompletionHandler]] = [:]
    private var preloadedEntries: [NetworkCacheHashableKey: PreloadedEntry] = [:]
    // For logging.
    private var notPreloadedEntries: [NetworkCacheHashableKey: ExpiringEntry] = [:]

    init(cache: NetworkDiskCache, storage: NetworkCacheStorage) {
        self.cache = cache
        self.storage = storage
    }

    private func pendingFrameLoad(_ frameID: WebKit.NetworkCache.GlobalFrameID) -> NetworkCachePendingFrameLoad? {
        pendingFrameLoads[NetworkCacheHashableFrameID(frameID)]
    }

    private func removePendingFrameLoad(_ frameID: WebKit.NetworkCache.GlobalFrameID) -> Bool {
        pendingFrameLoads.removeValue(forKey: NetworkCacheHashableFrameID(frameID)) != nil
    }

    func canRetrieve(
        _ storageKey: borrowing WebKit.NetworkCache.Key,
        _ request: borrowing WebCore.ResourceRequest,
        _ frameID: borrowing WebKit.NetworkCache.GlobalFrameID
    ) -> Bool {
        let hashableKey = NetworkCacheHashableKey(storageKey)

        // Check already preloaded entries.
        if let preloadedEntry = preloadedEntries[hashableKey] {
            if !preloadedEntry.canSatisfy(request) {
                logRetrieval(storageKey, "Could not use preloaded entry to satisfy request", " due to HTTP headers mismatch")
                logSpeculativeLoadingDiagnosticMessage(frameID, preloadedEntry.wastedDiagnostic)
                return false
            }
            logRetrieval(storageKey, "Using preloaded entry to satisfy request")
            logSpeculativeLoadingDiagnosticMessage(frameID, preloadedEntry.usedDiagnostic)
            return true
        }

        // Check pending speculative revalidations.
        guard case .revalidating(let pendingPreload)? = pendingPreloads[hashableKey] else {
            if notPreloadedEntries[hashableKey] != nil {
                logSpeculativeLoadingDiagnosticMessage(frameID, .entryWronglyNotWarmedUp)
            } else {
                logSpeculativeLoadingDiagnosticMessage(frameID, .unknownEntryRequest)
            }
            return false
        }

        if !requestsHeadersMatch(pendingPreload.originalRequest, request) {
            logRetrieval(storageKey, "revalidation already in progress", " but unusable due to HTTP headers mismatch")
            logSpeculativeLoadingDiagnosticMessage(frameID, .wastedWarmupWithRevalidation)
            return false
        }

        logRetrieval(storageKey, "revalidation already in progress")
        return true
    }

    private func logRetrieval(_ storageKey: borrowing WebKit.NetworkCache.Key, _ text: String, _ reason: String = "") {
        // os.Logger's interpolation arguments escape, and the borrowed `storageKey` cannot be captured, so a guarded local.
        let channel = WebKit.LogChannel.NetworkCacheSpeculativePreloading()
        guard channel.state != .Off else {
            return
        }
        let storageKeyDescription = storageKey.identifierCopy().description
        channel.debugLog.log(
            "(NetworkProcess) Retrieval: \(text, privacy: .public) for '\(storageKeyDescription, privacy: .public)'\(reason, privacy: .public):"
        )
    }

    func retrieve(_ storageKey: WebKit.NetworkCache.Key, _ completionHandler: @escaping RetrieveCompletionHandler) {
        let hashableKey = NetworkCacheHashableKey(storageKey)
        if let preloadedEntry = preloadedEntries.removeValue(forKey: hashableKey) {
            let cacheEntry = preloadedEntry.takeCacheEntry()
            WebKit.NetworkCache.dispatchOnMain(
                consuming: .init {
                    completionHandler(cacheEntry)
                }
            )
            return
        }
        assert(pendingPreloads[hashableKey] != nil)
        // FIXME: This breaks incremental loading when the revalidation is not successful.
        pendingRetrieveRequests[hashableKey, default: []].append(completionHandler)
    }

    func registerLoad(
        _ frameID: WebKit.NetworkCache.GlobalFrameID,
        _ request: WebCore.ResourceRequest,
        _ resourceKey: borrowing WebKit.NetworkCache.Key,
        _ loadOptions: NetworkCacheLoadOptions
    ) {
        assert(WTF.RunLoop.isMain())
        assert(request.urlCopy().protocolIsInHTTPFamily())

        if !request.shouldRegisterLoad {
            return
        }

        let isMainResource = request.requester() == .Main
        if isMainResource {
            // Mark previous load in this frame as completed if necessary.
            pendingFrameLoad(frameID)?.markLoadAsCompleted()

            assert(pendingFrameLoad(frameID) == nil)

            // Start tracking loads in this frame.
            let load = NetworkCachePendingFrameLoad(storage: storage, mainResourceKey: resourceKey) { [weak self] in
                guard let self else {
                    return
                }
                let wasRemoved = self.removePendingFrameLoad(frameID)
                assert(wasRemoved)
            }
            pendingFrameLoads[NetworkCacheHashableFrameID(frameID)] = load

            // Retrieve the subresources entry if it exists to start speculative revalidation and to update it.
            let context = SpeculativeLoadContext(isAppInitiated: request.isAppInitiated(), frameID: frameID, loadOptions: loadOptions)
            retrieveSubresourcesEntry(resourceKey) { [weak self] entry in
                guard let self else {
                    return
                }
                if let entry {
                    self.startSpeculativeRevalidation(entry, context)
                }
                load.setExistingSubresourcesEntry(entry)
            }
            return
        }

        pendingFrameLoad(frameID)?.registerSubresourceLoad(request, resourceKey)
    }

    func registerMainResourceLoadResponse(
        _ frameID: borrowing WebKit.NetworkCache.GlobalFrameID,
        _ request: borrowing WebCore.ResourceRequest,
        _ response: borrowing WebCore.ResourceResponse
    ) {
        if !request.shouldRegisterLoad {
            return
        }
        if response.isRedirection() {
            return
        }
        pendingFrameLoad(frameID)?.markMainResourceResponseAsReceived()
    }

    private func addPreloadedEntry(
        _ entry: NetworkCacheEntry,
        _ frameID: WebKit.NetworkCache.GlobalFrameID,
        _ revalidationRequest: consuming WebCore.ResourceRequest? = nil
    ) {
        assert(!entry.needsValidation())
        let key = entry.key()
        let preloaded = PreloadedEntry(entry, revalidationRequest: revalidationRequest) { [weak self] in
            guard let self, let preloadedEntry = self.preloadedEntries.removeValue(forKey: NetworkCacheHashableKey(key)) else {
                return
            }
            logSpeculativeLoadingDiagnosticMessage(frameID, preloadedEntry.wastedDiagnostic)
        }
        preloadedEntries.addIfAbsent(NetworkCacheHashableKey(key), preloaded)
    }

    private func retrieveEntryFromStorage(
        _ info: borrowing NetworkCacheSubresourceInfo,
        _ completionHandler: @escaping RetrieveCompletionHandler
    ) {
        storage.retrieve(info.key, priority: UInt32(info.priority.rawValue)) { record, _ in
            let (entry, keepsRecord) = Self.decodeRetrievedEntry(record)
            completionHandler(entry)
            return keepsRecord
        }
    }

    private static func decodeRetrievedEntry(
        _ record: borrowing WebKit.NetworkCache.Storage.Record
    ) -> (entry: NetworkCacheEntry?, keepsRecord: Bool) {
        guard !record.isNull(), let entry = NetworkCacheEntry.decodeStorageRecord(record) else {
            return (nil, false)
        }
        // FIXME: This is a workaround for rdar://181130091, which we can drop after a release.
        if entry.response().httpStatusCode() == WebCore.httpStatus304NotModified {
            return (nil, false)
        }
        if isStaleOrNoCache(entry.response(), entry.timeStamp()) {
            // Do not use cached redirects that have expired.
            if entry.redirectRequest().hasValue {
                return (nil, true)
            }
            entry.setNeedsValidation(true)
        }
        return (entry, true)
    }

    private func satisfyPendingRequests(_ key: borrowing WebKit.NetworkCache.Key, _ entry: NetworkCacheEntry?) -> Bool {
        guard let completionHandlers = pendingRetrieveRequests.removeValue(forKey: NetworkCacheHashableKey(key)) else {
            return false
        }
        for completionHandler in completionHandlers {
            completionHandler(entry?.copy())
        }
        return true
    }

    private func preconnectForSubresource(
        _ info: borrowing NetworkCacheSubresourceInfo,
        _ entry: NetworkCacheEntry?,
        _ context: SpeculativeLoadContext
    ) {
        if WebKit.NetworkCache.dryRunSpeculativeLoad(.Preconnect, info.key.identifierCopy()) {
            return
        }
        WebKit.NetworkCache.SpeculativeLoad.preconnect(
            context.frameID,
            makeRevalidationRequest(info, context, entry),
            context.loadOptions.isNavigatingToAppBoundDomain,
            context.loadOptions.allowPrivacyProxy,
            context.loadOptions.advancedPrivacyProtections,
            cache.sessionID
        )
    }

    private func revalidateSubresource(
        _ info: NetworkCacheSubresourceInfo,
        _ entry: NetworkCacheEntry?,
        _ context: SpeculativeLoadContext
    ) {
        let frameID = context.frameID
        assert(entry?.needsValidation() ?? true)

        let key = info.key

        // Range is not supported.
        if !key.rangeCopy().isEmpty() {
            return
        }

        // Delay first-party speculative loads until we've received the response for the main resource, in case the
        // main resource response sets cookies that are needed for subsequent loads.
        if let pendingLoad = pendingFrameLoad(frameID), !pendingLoad.didReceiveMainResourceResponse, info.isFirstParty {
            preconnectForSubresource(info, entry, context)
            // The task hands the entry over once.
            var entryForRetry = entry
            pendingLoad.addPostMainResourceResponseTask { [weak self] in
                guard let self, self.pendingPreloads[NetworkCacheHashableKey(key)] == nil else {
                    return
                }
                self.revalidateSubresource(info, entryForRetry.take(), context)
            }
            return
        }

        let revalidationRequest = makeRevalidationRequest(info, context, entry)

        WebKit.LogChannel.NetworkCacheSpeculativePreloading().debugLog
            .log("(NetworkProcess) Speculatively revalidating '\(key.identifierCopy().description, privacy: .public)':")

        // A dry run starts no load: the revalidation ends at once, with no response.
        if WebKit.NetworkCache.dryRunSpeculativeRevalidation(revalidationRequest) {
            return
        }

        let revalidator = NetworkCacheSpeculativeLoad(
            cache: cache,
            frameID: frameID,
            request: revalidationRequest,
            entryForValidation: entry,
            loadOptions: context.loadOptions
        ) { [weak self] revalidatedEntry in
            assert(!(revalidatedEntry?.needsValidation() ?? false))
            assert(revalidatedEntry.map { $0.key() == key } ?? true)
            guard let self else {
                return
            }
            let protectRevalidator = self.pendingPreloads.removeValue(forKey: NetworkCacheHashableKey(key))
            // The load being completed is destroyed when this returns.
            defer { withExtendedLifetime(protectRevalidator) {} }
            WebKit.LogChannel.NetworkCacheSpeculativePreloading().debugLog
                .log(
                    "(NetworkProcess) Speculative revalidation completed for '\(key.identifierCopy().description, privacy: .public)':"
                )

            if self.satisfyPendingRequests(key, revalidatedEntry) {
                if revalidatedEntry != nil {
                    logSpeculativeLoadingDiagnosticMessage(frameID, .successfulWarmupWithRevalidation)
                }
                return
            }

            if let revalidatedEntry {
                self.addPreloadedEntry(revalidatedEntry, frameID, revalidationRequest)
            }
        }
        pendingPreloads.addIfAbsent(NetworkCacheHashableKey(key), .revalidating(revalidator))
    }

    private func preloadEntry(_ info: NetworkCacheSubresourceInfo, _ context: SpeculativeLoadContext) {
        let hashableKey = NetworkCacheHashableKey(info.key)
        if pendingPreloads[hashableKey] != nil {
            return
        }
        pendingPreloads[hashableKey] = .lookingInStorage

        let key = info.key
        retrieveEntryFromStorage(info) { [weak self] entry in
            guard let self else {
                return
            }
            let removed = self.pendingPreloads.removeValue(forKey: hashableKey)
            assert(removed?.isLookingInStorage ?? false)

            if self.satisfyPendingRequests(key, entry) {
                if entry != nil {
                    logSpeculativeLoadingDiagnosticMessage(context.frameID, .successfulWarmupWithoutRevalidation)
                }
                return
            }

            if let entry, !entry.needsValidation() {
                self.addPreloadedEntry(entry, context.frameID)
                return
            }

            if canRevalidate(info, entry) {
                self.revalidateSubresource(info, entry, context)
            }
        }
    }

    private func startSpeculativeRevalidation(_ entry: NetworkCacheSubresourcesEntry, _ context: SpeculativeLoadContext) {
        for info in entry.subresources {
            if !info.isTransient {
                preloadEntry(info, context)
            } else {
                let key = info.key
                WebKit.LogChannel.NetworkCacheSpeculativePreloading().debugLog
                    .log(
                        "(NetworkProcess) Not preloading '\(key.identifierCopy().description, privacy: .public)' because it is marked as transient"
                    )
                let notPreloaded = ExpiringEntry { [weak self] in
                    guard let self else {
                        return
                    }
                    logSpeculativeLoadingDiagnosticMessage(context.frameID, .entryRightlyNotWarmedUp)
                    self.notPreloadedEntries.removeValue(forKey: NetworkCacheHashableKey(key))
                }
                notPreloadedEntries.addIfAbsent(NetworkCacheHashableKey(key), notPreloaded)
            }
        }
    }

    private func retrieveSubresourcesEntry(
        _ storageKey: WebKit.NetworkCache.Key,
        _ completionHandler: @escaping (NetworkCacheSubresourcesEntry?) -> Void
    ) {
        assert(storageKey.recordType == .Resource)
        let subresourcesStorageKey = storageKey.subresourcesKey(salt: storage.salt)
        storage.retrieve(subresourcesStorageKey, priority: UInt32(WebCore.ResourceLoadPriority.Medium.rawValue)) { record, _ in
            guard !record.isNull(), let subresourcesEntry = NetworkCacheSubresourcesEntry.decodeStorageRecord(record) else {
                completionHandler(nil)
                return false
            }
            completionHandler(subresourcesEntry)
            return true
        }
    }
}
