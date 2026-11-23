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

// The cache's retrieve, after its entry point (NetworkDiskCache.retrieve): the speculative and stored paths, their
// completion, and the async revalidation a stale entry starts.
extension NetworkDiskCache {
    private func startAsyncRevalidationIfNeeded(
        _ request: borrowing WebCore.ResourceRequest,
        _ key: WebKit.NetworkCache.Key,
        _ entry: NetworkCacheEntry,
        _ frameID: WebKit.NetworkCache.GlobalFrameID,
        _ loadOptions: NetworkCacheLoadOptions
    ) {
        let pendingKey = NetworkCacheHashableKey(key)
        if pendingAsyncRevalidations[pendingKey] != nil {
            return
        }
        let revalidation = NetworkCacheAsyncRevalidation(
            cache: self,
            frameID: frameID,
            request: request,
            entry: entry,
            loadOptions: loadOptions
        ) { [weak self] result in
            guard let self else {
                return
            }
            guard self.pendingAsyncRevalidations.removeValue(forKey: pendingKey) != nil else {
                assertionFailure()
                return
            }
            WebKit.LogChannel.NetworkCache().debugLog
                .log(
                    "(NetworkProcess) revalidation completed for '\(pendingKey.key.identifierCopy().description, privacy: .public)' with result \(String(describing: result), privacy: .public)"
                )
        }
        let frameKey = NetworkCacheHashableFrameID(frameID)
        pendingAsyncRevalidationByPage[frameKey, default: []].removeAll(where: { $0.value == nil })
        pendingAsyncRevalidationByPage[frameKey, default: []].append(WeakAsyncRevalidation(revalidation))
        pendingAsyncRevalidations[pendingKey] = revalidation
    }

    func retrieveSpeculatively(
        _ speculativeLoadManager: NetworkCacheSpeculativeLoadManager,
        _ storageKey: WebKit.NetworkCache.Key,
        _ request: consuming WebCore.ResourceRequest,
        _ info: WebKit.NetworkCache.RetrieveInfo,
        _ box: NetworkCacheHandlerBox<WebKit.NetworkCache.RetrieveCompletionHandler?>
    ) {
        let sessionID = self.sessionID
        // Holds the cache, so a cache destroyed before the posted task runs still delivers the entry.
        speculativeLoadManager.retrieve(storageKey) { [self, request] entry in
            var info = info
            if let entry,
                WebKit.NetworkCache.networkCacheVerifyVaryingRequestHeaders(sessionID, entry.varyingRequestHeaders(), request)
            {
                info.setSpeculativeLoadDecision(.Yes)
                self.completeRetrieve(box, entry, &info)
            } else {
                info.setSpeculativeLoadDecision(.NoDueToVaryingHeaderMismatch)
                self.completeRetrieve(box, nil, &info)
            }
        }
    }

    /// Decodes the stored record, decides its use and completes the retrieve; returns whether the storage keeps the record.
    func finishRetrieve(
        _ record: WebKit.NetworkCache.Storage.Record,
        _ request: WebCore.ResourceRequest,
        _ storageKey: WebKit.NetworkCache.Key,
        _ frameID: WebKit.NetworkCache.OptionalFrameID,
        _ loadOptions: NetworkCacheLoadOptions,
        _ box: NetworkCacheHandlerBox<WebKit.NetworkCache.RetrieveCompletionHandler?>,
        _ info: inout WebKit.NetworkCache.RetrieveInfo
    ) -> Bool {
        if record.isNull() {
            WebKit.LogChannel.NetworkCache().debugLog.log("(NetworkProcess) not found in storage")
            completeRetrieve(box, nil, &info)
            return false
        }

        assert(record.key == storageKey)

        var entry = NetworkCacheEntry.decodeStorageRecord(record)

        // FIXME: This is a workaround for rdar://181130091, which we can drop after a release.
        if let decoded = entry, decoded.response().httpStatusCode() == WebCore.httpStatus304NotModified {
            WebKit.LogChannel.NetworkCache().debugLog
                .log("(NetworkProcess) discarding poisoned 304 entry from disk cache (rdar://181130091)")
            completeRetrieve(box, nil, &info)
            return false
        }

        let decision: WebKit.NetworkCache.UseDecision =
            entry.map { Self.makeUseDecision(sessionID, $0, request) } ?? .NoDueToDecodeFailure
        info.setUseDecision(decision)
        let priority = info.priority
        let startTime = info.startTime
        WebKit.LogChannel.NetworkCache().debugLog
            .log(
                "(NetworkProcess) retrieve complete useDecision=\(decision.rawValue) priority=\(priority) time=\(Int64((WTF.MonotonicTime.now().secondsSinceEpoch().value() - startTime.secondsSinceEpoch().value()) * 1000))ms"
            )

        switch decision {
        case .AsyncRevalidate:
            guard let entryCopy = entry?.copy() else {
                fatalError("An entry to revalidate that did not decode")
            }
            entryCopy.setNeedsValidation(true)
            // A load without a frame ID is not revalidated.
            if let globalFrameID = frameID.value {
                startAsyncRevalidationIfNeeded(
                    request,
                    storageKey,
                    entryCopy,
                    globalFrameID,
                    loadOptions
                )
            }
        case .Use:
            break
        case .Validate:
            guard let entry else {
                fatalError("An entry to validate that did not decode")
            }
            entry.setNeedsValidation(true)
        default:
            entry = nil
        }

        completeRetrieve(box, entry, &info)
        return decision != .NoDueToDecodeFailure
    }

    func completeRetrieve(
        _ box: NetworkCacheHandlerBox<WebKit.NetworkCache.RetrieveCompletionHandler?>,
        _ entry: NetworkCacheEntry?,
        _ info: inout WebKit.NetworkCache.RetrieveInfo
    ) {
        info.completionTime = WTF.MonotonicTime.now()
        WebKit.NetworkCache.signpostRetrieve(info, entry != nil)

        let token = entry.map { retrievedEntries.park($0) } ?? 0
        box.complete(token, info)
        // The completion takes its entry at its start, unconditionally.
        if token != 0 {
            let leftover = retrievedEntries.take(token)
            if leftover != nil {
                fatalError("A retrieved entry's completion did not take it")
            }
        }
    }
}

/// The retrieved entries that retrieve's C++ completions take by token (NetworkCache.h).
///
/// Tokens only increase.
struct NetworkCacheRetrievedEntries {
    private var entries: [UInt64: NetworkCacheEntry] = [:]
    private var lastToken: UInt64 = 0

    var isEmpty: Bool { entries.isEmpty }

    /// Parks `entry` for a C++ completion and returns its token, never 0 and never reused.
    mutating func park(_ entry: NetworkCacheEntry) -> UInt64 {
        lastToken += 1
        entries[lastToken] = entry
        return lastToken
    }

    mutating func take(_ token: UInt64) -> NetworkCacheEntry? {
        entries.removeValue(forKey: token)
    }
}

extension NetworkCacheHandlerBox where Handler == WebKit.NetworkCache.RetrieveCompletionHandler? {
    func complete(_ token: UInt64, _ info: borrowing WebKit.NetworkCache.RetrieveInfo) {
        guard var handler = handler.take() else {
            fatalError("A retrieve completes once")
        }
        WebKit.NetworkCache.invokeRetrieveCompletionHandler(&handler, token, info)
    }
}
