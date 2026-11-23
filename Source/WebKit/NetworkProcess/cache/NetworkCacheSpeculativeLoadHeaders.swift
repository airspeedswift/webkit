// Copyright (C) 2015 Apple Inc. All rights reserved.
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

func requestsHeadersMatch(
    _ speculativeValidationRequest: borrowing WebCore.ResourceRequest,
    _ actualRequest: borrowing WebCore.ResourceRequest
) -> Bool {
    // An assert's autoclosure cannot capture a borrowed C++ value.
    let actualRequestIsConditional = actualRequest.isConditional()
    assert(!actualRequestIsConditional)
    var speculativeRequest = copy speculativeValidationRequest
    speculativeRequest.makeUnconditional()

    let speculativeHeaders = speculativeRequest.httpHeaderFieldsCopy()
    let actualHeaders = actualRequest.httpHeaderFieldsCopy()
    guard speculativeHeaders == actualHeaders else {
        WebKit.LogChannel.NetworkCacheSpeculativePreloading().debugLog
            .log(
                "Cannot reuse speculatively validated entry because HTTP headers used for validation do not match"
            )
        dumpHTTPHeadersDiff(speculativeHeaders, actualHeaders)
        return false
    }
    return true
}

/// Calls `body` with each header's name and value, in the map's iteration order: the common headers, then the others.
private func forEachHTTPHeader(_ headers: WebCore.HTTPHeaderMap, _ body: (WTF.String, WTF.String) -> Void) {
    let commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader> = headers.commonHeadersSpan()
    for index in commonHeaders.indices {
        body(WebKit.NetworkCache.networkCacheHTTPHeaderNameString(commonHeaders[index].key), commonHeaders[index].value)
    }
    let uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader> = headers.uncommonHeadersSpan()
    for index in uncommonHeaders.indices {
        body(uncommonHeaders[index].key, uncommonHeaders[index].value)
    }
}

private func dumpHTTPHeadersDiff(_ headersA: WebCore.HTTPHeaderMap, _ headersB: WebCore.HTTPHeaderMap) {
    let channel = WebKit.LogChannel.NetworkCacheSpeculativePreloading()
    guard channel.state != .Off else {
        return
    }
    let log = channel.debugLog
    forEachHTTPHeader(headersA) { name, value in
        let valueB = headersB.valueForName(name)
        if valueB.isNull() {
            log.log(
                "* '\(name.description, privacy: .public)' HTTP header is only in first request (value: \(value.description, privacy: .public))"
            )
        } else if !(value == valueB) {
            log.log(
                "* '\(name.description, privacy: .public)' HTTP header differs in both requests: \(value.description, privacy: .public) != \(valueB.description, privacy: .public)"
            )
        }
    }
    forEachHTTPHeader(headersB) { name, value in
        if !headersA.contains(name) {
            log.log(
                "* '\(name.description, privacy: .public)' HTTP header is only in second request (value: \(value.description, privacy: .public))"
            )
        }
    }
}
