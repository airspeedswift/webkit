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

// The cache's decisions on requests and responses (NetworkCache.swift).

extension WebCore.ResourceRequestCachePolicy {
    fileprivate var allowsExpired: Bool {
        switch self {
        case .ReturnCacheDataElseLoad, .ReturnCacheDataDontLoad:
            return true
        case .UseProtocolCachePolicy, .ReloadIgnoringCacheData, .RefreshAnyCacheData:
            return false
        case .DoNotUseAnyCache:
            assertionFailure()
            return false
        @unknown default:
            return false
        }
    }
}

extension WebCore.ResourceResponse {
    /// The response's current age and freshness lifetime at `timestamp`, in seconds.
    func ageAndFreshnessLifetime(at timestamp: WTF.WallTime) -> (age: Double, freshnessLifetime: Double) {
        (
            WebCore.computeCurrentAge(self, timestamp).value(),
            WebCore.computeFreshnessLifetimeForHTTPFamily(self, timestamp).value()
        )
    }
}

private func useDecision(
    _ sessionID: PAL.SessionID,
    _ response: borrowing WebCore.ResourceResponse,
    _ timestamp: WTF.WallTime,
    _ requestDirectives: WebKit.NetworkCache.RequestDirectives
) -> WebKit.NetworkCache.UseDecision {
    if response.cacheControlContainsNoCache() {
        return .Validate
    }

    let (age, lifetime) = response.ageAndFreshnessLifetime(at: timestamp)

    let maxAge = requestDirectives.maxAge.value?.value()
    // Request max-age=0 (like no-cache) always forces revalidation.
    if maxAge == 0 {
        return .Validate
    }

    if age <= lifetime {
        if let maxAge, age > maxAge {
            return .Validate
        }
        if let minFresh = requestDirectives.minFresh.value?.value(), age + minFresh > lifetime {
            return .Validate
        }
    }

    let maxStale = requestDirectives.maxStale.value?.value()
    var maximumStaleness = maxStale ?? 0
    let hasExpired = age - lifetime > maximumStaleness
    if hasExpired && maxStale == nil && WebKit.NetworkCache.isStaleWhileRevalidateEnabled(sessionID) {
        maximumStaleness += response.cacheControlStaleWhileRevalidate().value?.value() ?? 0
        let inResponseStaleness = age - lifetime < maximumStaleness
        if inResponseStaleness {
            return .AsyncRevalidate
        }
    }

    if hasExpired {
        WebKit.LogChannel.NetworkCache().debugLog
            .log(
                "(NetworkProcess) needsRevalidation hasExpired age=\(age) lifetime=\(lifetime) max-staleness=\(maximumStaleness)"
            )
        return .Validate
    }
    return .Use
}

private func needsRevalidation(
    _ sessionID: PAL.SessionID,
    _ response: borrowing WebCore.ResourceResponse,
    _ request: borrowing WebCore.ResourceRequest,
    _ timestamp: WTF.WallTime
) -> WebKit.NetworkCache.UseDecision {
    let requestDirectives = WebKit.NetworkCache.parseRequestDirectives(request)
    if requestDirectives.noCache {
        return .Validate
    }
    // A request carrying no-store must not be satisfied from cache.
    if requestDirectives.noStore {
        return .Validate
    }
    return useDecision(sessionID, response, timestamp, requestDirectives)
}

extension NetworkDiskCache {
    /// Whether a retrieved entry can be used for a request as it is, after validation, or not at all.
    ///
    /// `request` is borrowed for the call. The callers are `useDecisionForTesting` and the retrieve completion
    /// (NetworkCacheRetrieve.swift, a request that completion owns). The C++ called with it is `isConditional`, `cachePolicy`,
    /// `urlCopy`, the Vary check (`networkCacheVerifyVaryingRequestHeaders`, which can read the session's cookies) and
    /// the freshness helpers. None holds a pointer back to a request's owner or calls out.
    static func makeUseDecision(
        _ sessionID: PAL.SessionID,
        _ entry: NetworkCacheEntry,
        _ request: borrowing WebCore.ResourceRequest
    ) -> WebKit.NetworkCache.UseDecision {
        let hasRedirectRequest = entry.entryRedirectRequest.hasValue
        // The request is conditional so we force revalidation from the network. We merely check the disk cache
        // so we can update the cache entry.
        if request.isConditional() && !hasRedirectRequest {
            return .Validate
        }

        if !WebKit.NetworkCache.networkCacheVerifyVaryingRequestHeaders(sessionID, entry.entryVaryingRequestHeaders, request) {
            return .NoDueToVaryingHeaderMismatch
        }

        // We never revalidate in the case of a history navigation.
        if request.cachePolicy().allowsExpired {
            return .Use
        }

        // We could have cached a redirect without a fragment and now may have
        // a fragment in the URL.
        // A condition list rather than &&, whose right side is an autoclosure that cannot capture the borrowed request.
        if hasRedirectRequest, request.urlCopy().hasFragmentIdentifier() {
            return .NoDueToRequestContainingFragments
        }

        let timeStamp = entry.timeStamp()
        return entry.withResponse(request) { response, request in
            let decision = needsRevalidation(sessionID, response, request, timeStamp)
            if decision != .Validate {
                return decision
            }

            if !response.hasCacheValidatorFields() {
                return .NoDueToMissingValidatorFields
            }

            return hasRedirectRequest ? .NoDueToExpiredRedirect : .Validate
        }
    }
}

extension WebCore.ResourceRequest {
    mutating func setCacheValidatorHeaders(from response: borrowing WebCore.ResourceResponse) {
        let eTag = response.httpHeaderField(WebCore.HTTPHeaderName.ETag)
        if !eTag.isEmpty() {
            setHTTPHeaderField(WebCore.HTTPHeaderName.IfNoneMatch, eTag)
        }
        let lastModified = response.httpHeaderField(WebCore.HTTPHeaderName.LastModified)
        if !lastModified.isEmpty() {
            setHTTPHeaderField(WebCore.HTTPHeaderName.IfModifiedSince, lastModified)
        }
    }

    var canUseSpeculativeRevalidation: Bool {
        if isConditional() {
            return false
        }
        if !allowCookies() {
            return false
        }
        let requester = self.requester()
        if requester == .XHR || requester == .Fetch {
            return false
        }
        switch cachePolicy() {
        case .ReturnCacheDataElseLoad, .ReturnCacheDataDontLoad, .ReloadIgnoringCacheData:
            return false
        case .UseProtocolCachePolicy, .RefreshAnyCacheData:
            return true
        case .DoNotUseAnyCache:
            assertionFailure()
            return false
        @unknown default:
            return false
        }
    }
}
