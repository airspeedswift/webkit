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

/// A prefetched response with its body, or a redirect response with its redirect request.
@_expose(Cxx)
public final class PrefetchCacheEntry {
    private enum Kind {
        case response(privateRelayed: WebKit.PrivateRelayed, buffer: WebKit.NetworkCache.FragmentedBufferPtr)
        case redirect(WebCore.ResourceRequest)
    }

    /// The response, or for a redirect the redirect response.
    public let response: WebCore.ResourceResponse
    private let kind: Kind

    init(
        response: consuming WebCore.ResourceResponse,
        privateRelayed: WebKit.PrivateRelayed,
        buffer: consuming WebKit.NetworkCache.FragmentedBufferPtr
    ) {
        self.response = response
        kind = .response(privateRelayed: privateRelayed, buffer: buffer)
    }

    init(redirectResponse: consuming WebCore.ResourceResponse, redirectRequest: consuming WebCore.ResourceRequest) {
        response = redirectResponse
        kind = .redirect(redirectRequest)
    }

    /// Whether the response came through a private relay; never for a redirect.
    public func privateRelayed() -> WebKit.PrivateRelayed {
        switch kind {
        case .response(let privateRelayed, _):
            privateRelayed
        case .redirect:
            .No
        }
    }

    /// The prefetched body; null for a redirect.
    public func buffer() -> WebKit.NetworkCache.FragmentedBufferPtr {
        switch kind {
        case .response(_, let buffer):
            buffer
        case .redirect:
            WebKit.NetworkCache.FragmentedBufferPtr()
        }
    }

    /// The redirect's request; a null request unless the entry is a redirect.
    public func redirectRequest() -> WebCore.ResourceRequest {
        switch kind {
        case .response:
            WebCore.ResourceRequest()
        case .redirect(let request):
            request
        }
    }
}

/// The session's cross-origin prefetches, each kept until the navigation that takes it or the expiration timeout.
@_expose(Cxx)
public final class PrefetchCache {
    private static let expirationTimeout: Double = 5

    // Keyed by the URL's string, which is what URL equality compares.
    private var sessionPrefetches: [NetworkCacheIsolatedString: PrefetchCacheEntry] = [:]
    private var sessionExpirationList: [(url: NetworkCacheIsolatedString, timestamp: Double)] = []
    private let expirationTimer = WebKit.NetworkCache.OneShotTimer.create().get()

    /// An empty cache.
    public init() {
    }

    deinit {
        // A timer destroyed with its handler set calls it. This handler is weak, so stopping the timer is enough.
        expirationTimer.stop()
    }

    /// Removes every prefetch.
    public func clear() {
        expirationTimer.stop()
        sessionExpirationList.removeAll()
        sessionPrefetches.removeAll()
    }

    /// Removes and returns the prefetch for a URL.
    public func take(_ url: WTF.URL) -> PrefetchCacheEntry? {
        let key = NetworkCacheIsolatedString(url.stringCopy())
        sessionExpirationList.removeAll { $0.url == key }
        let entry = sessionPrefetches.removeValue(forKey: key)
        assert(!(entry?.response.httpHeaderField(WebCore.HTTPHeaderName.Vary).description.contains("Cookie") ?? false))
        return entry
    }

    /// Keeps a prefetched response and its body for a URL, unless one is already kept.
    public func store(
        _ requestURL: consuming WTF.URL,
        _ response: consuming WebCore.ResourceResponse,
        _ privateRelayed: WebKit.PrivateRelayed,
        _ buffer: consuming WebKit.NetworkCache.FragmentedBufferPtr
    ) {
        let key = NetworkCacheIsolatedString(requestURL.stringCopy())
        // Limit prefetches for same url to 1.
        if sessionPrefetches[key] != nil {
            return
        }
        sessionPrefetches[key] = PrefetchCacheEntry(response: response, privateRelayed: privateRelayed, buffer: buffer)
        addToExpirationList(key)
    }

    /// Keeps a prefetched redirect for a URL, replacing any kept one.
    public func storeRedirect(
        _ requestURL: consuming WTF.URL,
        _ redirectResponse: consuming WebCore.ResourceResponse,
        _ redirectRequest: consuming WebCore.ResourceRequest
    ) {
        let key = NetworkCacheIsolatedString(requestURL.stringCopy())
        redirectRequest.clearPurpose()
        sessionPrefetches[key] = PrefetchCacheEntry(redirectResponse: redirectResponse, redirectRequest: redirectRequest)
        addToExpirationList(key)
    }

    private func addToExpirationList(_ key: NetworkCacheIsolatedString) {
        sessionExpirationList.append((url: key, timestamp: WTF.WallTime.nowSeconds))
        if !expirationTimer.isActive() {
            startExpirationTimer(Self.expirationTimeout)
        }
    }

    private func clearExpiredEntries() {
        let now = WTF.WallTime.nowSeconds
        while let first = sessionExpirationList.first {
            assert(sessionPrefetches[first.url] != nil)
            let elapsed = now - first.timestamp
            guard elapsed > Self.expirationTimeout else {
                startExpirationTimer(Self.expirationTimeout - elapsed)
                break
            }
            sessionPrefetches.removeValue(forKey: first.url)
            sessionExpirationList.removeFirst()
        }
    }

    // The timer's handler is cleared when it fires, so a start after a fire sets a new one.
    private func startExpirationTimer(_ delay: Double) {
        if !expirationTimer.hasHandler() {
            expirationTimer.setHandler(
                consuming: .init { [weak self] in
                    self?.clearExpiredEntries()
                }
            )
        }
        expirationTimer.startOneShot(delay)
    }
}
