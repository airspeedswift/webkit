// Copyright (C) 2019 Igalia S.L.
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

/// A revalidation in the stale-while-revalidate window: a speculative load of the stale entry's resource that times
/// out when the window ends.
///
/// Main thread only; the cache owns it until it completes.
final class NetworkCacheAsyncRevalidation {
    enum Outcome {
        case failure
        case timeout
        case success
    }

    private var load: NetworkCacheSpeculativeLoad?
    private let timer = WebKit.NetworkCache.OneShotTimer.create().get()
    private var completionHandler: ((Outcome) -> Void)?

    init(
        cache: NetworkDiskCache,
        frameID: WebKit.NetworkCache.GlobalFrameID,
        request: borrowing WebCore.ResourceRequest,
        entry: NetworkCacheEntry,
        loadOptions: NetworkCacheLoadOptions,
        completionHandler: @escaping (Outcome) -> Void
    ) {
        self.completionHandler = completionHandler

        let key = entry.key()
        assert(key.rangeCopy().isEmpty(), "range is not supported")
        let revalidationRequest = Self.makeRevalidationRequest(request, entry)
        let response = entry.response()
        let (age, lifetime) = response.ageAndFreshnessLifetime(at: entry.timeStamp())
        let responseMaxStaleness = response.cacheControlStaleWhileRevalidate()
        guard let maxStaleness = responseMaxStaleness.value else {
            fatalError("A revalidation while stale without a maximum staleness")
        }
        timer.setHandler(
            consuming: .init { [weak self] in
                self?.staleWhileRevalidateEnding()
            }
        )
        timer.startOneShot(maxStaleness.value() + (lifetime - age))

        load = NetworkCacheSpeculativeLoad(
            cache: cache,
            frameID: frameID,
            request: revalidationRequest,
            entryForValidation: entry,
            loadOptions: loadOptions
        ) { [weak self] revalidatedEntry in
            assert(!(revalidatedEntry?.needsValidation() ?? false))
            assert(revalidatedEntry.map { $0.key() == key } ?? true)
            guard let self, let handler = self.completionHandler.take() else {
                return
            }
            handler(revalidatedEntry != nil ? .success : .failure)
        }
    }

    deinit {
        // A timer destroyed with its handler set calls it. This handler is weak, so stopping the timer is enough.
        timer.stop()
    }

    func cancel() {
        load?.cancel()
    }

    private func staleWhileRevalidateEnding() {
        // Take the handler before cancelling: the load's cancel would otherwise re-enter it and report a failure
        // before the timeout.
        let handler = completionHandler.take()
        load?.cancel()
        handler?(.timeout)
    }

    private static func makeRevalidationRequest(
        _ request: borrowing WebCore.ResourceRequest,
        _ entry: NetworkCacheEntry
    ) -> WebCore.ResourceRequest {
        var revalidationRequest = copy request

        revalidationRequest.makeUnconditional()
        revalidationRequest.setCacheValidatorHeaders(from: entry.response())
        revalidationRequest.setPriority(.Low)
        return revalidationRequest
    }
}

struct WeakAsyncRevalidation {
    weak var value: NetworkCacheAsyncRevalidation?
    init(_ value: NetworkCacheAsyncRevalidation) { self.value = value }
}
