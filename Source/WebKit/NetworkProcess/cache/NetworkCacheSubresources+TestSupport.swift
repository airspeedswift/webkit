// Copyright (C) 2026 Apple Inc. All rights reserved.
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

extension NetworkCacheSubresourceInfo {
    /// The info's lines of the test support's description (NetworkCacheTestSupport.cpp), from its fields in place.
    func describeForTesting(_ builder: inout WTF.StringBuilder) {
        // Ignored by the description for a transient info; the defaults are the C++ fields'.
        let request =
            self.request
            ?? Request(
                isSameSite: false,
                isAppInitiated: true,
                firstPartyForCookies: WTF.URL(),
                headers: WebCore.HTTPHeaderMap(),
                priority: .VeryLow
            )
        WebKit.NetworkCache.TestSupport.describeSubresource(
            &builder,
            key,
            lastSeen,
            firstSeen,
            isTransient,
            request.isSameSite,
            request.isAppInitiated,
            request.firstPartyForCookies,
            request.headers,
            request.priority
        )
    }
}

/// The loads the test support passes to `makeForTesting`, appended one by one from C++.
@_expose(Cxx)
public final class NetworkCacheSubresourceLoadList {
    fileprivate(set) var loads: [NetworkCacheSubresourceLoad] = []
    /// An empty list.
    public init() {}
    /// Appends a load of a request under a key; the load keeps both, so they are taken `consuming`.
    public func append(_ request: consuming WebCore.ResourceRequest, _ key: consuming WebKit.NetworkCache.Key) {
        loads.append(NetworkCacheSubresourceLoad(request, key))
    }
}

/// What `infoCoderRoundTrip` returns: the info encoded again, and whether its decode read all of the input.
@_expose(Cxx)
public struct NetworkCacheSubresourceInfoRoundTrip {
    /// The info encoded again; null when the input does not decode.
    public let data: WebKit.NetworkCache.Data
    /// Whether the decode read all of the input.
    public let consumedAll: Bool
}
