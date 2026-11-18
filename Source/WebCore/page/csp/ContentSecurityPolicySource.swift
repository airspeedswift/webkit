// Copyright (C) 2011 Google, Inc. All rights reserved.
// Copyright (C) 2016-2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY GOOGLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// The JavaScriptCore_Private and Stopwatch imports define types that WebCore_Private's headers name, which the importer needs.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.ContentSecurityPolicySwift
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

private enum SchemeMatchResult {
    case noMatch
    case match
    case insecureUpgradeMatch
}

private enum ShouldUpgradePorts {
    case no
    case yes
}

// The schemes the matching rules name, compared exactly (String's operator== with a literal).
enum ContentSecurityPolicySchemeName {
    case http
    case https
    case ws
    case wss
    case data
    case blob
    case about
    case other

    init<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) {
        self = .other
        switch characters.count {
        case 2:
            if characters[0].cspCodeUnit == 0x77 && characters[1].cspCodeUnit == 0x73 {
                self = .ws
            }
        case 3:
            if characters[0].cspCodeUnit == 0x77 && characters[1].cspCodeUnit == 0x73 && characters[2].cspCodeUnit == 0x73 {
                self = .wss
            }
        case 4:
            let c0 = characters[0].cspCodeUnit
            let c1 = characters[1].cspCodeUnit
            let c2 = characters[2].cspCodeUnit
            let c3 = characters[3].cspCodeUnit
            if c0 == 0x68 && c1 == 0x74 && c2 == 0x74 && c3 == 0x70 {
                self = .http
            } else if c0 == 0x64 && c1 == 0x61 && c2 == 0x74 && c3 == 0x61 {
                self = .data
            } else if c0 == 0x62 && c1 == 0x6C && c2 == 0x6F && c3 == 0x62 {
                self = .blob
            }
        case 5:
            let c0 = characters[0].cspCodeUnit
            let c1 = characters[1].cspCodeUnit
            let c2 = characters[2].cspCodeUnit
            let c3 = characters[3].cspCodeUnit
            let c4 = characters[4].cspCodeUnit
            if c0 == 0x68 && c1 == 0x74 && c2 == 0x74 && c3 == 0x70 && c4 == 0x73 {
                self = .https
            } else if c0 == 0x61 && c1 == 0x62 && c2 == 0x6F && c3 == 0x75 && c4 == 0x74 {
                self = .about
            }
        default:
            break
        }
    }
}

private func cspEqualIgnoringASCIICase<A: ContentSecurityPolicyCharacter, B: ContentSecurityPolicyCharacter>(
    _ a: Span<A>,
    _ b: Span<B>
) -> Bool {
    if a.count != b.count {
        return false
    }
    for index in 0..<a.count where cspToASCIILower(a[index].cspCodeUnit) != cspToASCIILower(b[index].cspCodeUnit) {
        return false
    }
    return true
}

// StringView::endsWithIgnoringASCIICase, then the '.' before the suffix.
private func cspWildcardMatches<A: ContentSecurityPolicyCharacter, B: ContentSecurityPolicyCharacter>(
    _ host: Span<A>,
    _ hostWithWildcard: Span<B>
) -> Bool {
    let hostLength = host.count
    let hostWithWildcardLength = hostWithWildcard.count
    if hostLength < hostWithWildcardLength {
        return false
    }
    let start = hostLength - hostWithWildcardLength
    for index in 0..<hostWithWildcardLength
    where cspToASCIILower(host[start + index].cspCodeUnit) != cspToASCIILower(hostWithWildcard[index].cspCodeUnit) {
        return false
    }
    return hostLength > hostWithWildcardLength && host[hostLength - hostWithWildcardLength - 1].cspCodeUnit == 0x2E
}

// The policy's own origin, which 'self' stands for, and its scheme, which a source without a scheme is matched with.
struct ContentSecurityPolicySelfOrigin {
    // The scheme's characters, then the host's.
    let characters: [UInt16]
    let protocolLength: Int
    let scheme: ContentSecurityPolicySchemeName
    let source: ContentSecurityPolicySource?

    init() {
        characters = []
        protocolLength = 0
        scheme = .other
        source = nil
    }

    init(_ scheme: borrowing WTF.String, _ host: borrowing WTF.String, _ port: UInt16?) {
        var characters: [UInt16] = []
        characters.reserveCapacity(Int(scheme.length()) + Int(host.length()))
        ContentSecurityPolicySelfOrigin.append(&characters, scheme)
        let hostStart = characters.count
        ContentSecurityPolicySelfOrigin.append(&characters, host)
        let schemeName = ContentSecurityPolicySchemeName(characters.span.extracting(0..<hostStart))
        // Both are a String's characters, so they number fewer than 2^32.
        let end = UInt32(truncatingIfNeeded: characters.count)
        self.source = ContentSecurityPolicySource(0, UInt32(truncatingIfNeeded: hostStart), end, end, schemeName, port, false, false, true)
        self.characters = characters
        self.protocolLength = hostStart
        self.scheme = schemeName
    }

    private static func append(_ characters: inout [UInt16], _ string: borrowing WTF.String) {
        if string.is8Bit() {
            let span: Span<WTF.Latin1Character> = string.span8()
            for index in 0..<span.count {
                characters.append(span[index].cspCodeUnit)
            }
        } else {
            let span: Span<UInt16> = string.checkedSpan16()
            for index in 0..<span.count {
                characters.append(span[index])
            }
        }
    }
}

// The parts of a URL a source is matched with, and what its bounds say of it.
struct ContentSecurityPolicyURLParts<C: ContentSecurityPolicyCharacter>: ~Escapable {
    let protocolCharacters: Span<C>
    let host: Span<C>
    let path: Span<C>
    let scheme: ContentSecurityPolicySchemeName
    let port: UInt16?
    // isDefaultPortForProtocol(port, protocol()) is hasDefaultPort && defaultPort == port.
    let defaultPort: UInt16
    let hasDefaultPort: Bool

    @_lifetime(copy characters)
    init(_ characters: Span<C>, _ bounds: WebCore.ContentSecurityPolicyURLBounds) {
        protocolCharacters = characters.extracting(0..<Int(bounds.protocolEnd))
        host = characters.extracting(Int(bounds.hostStart)..<Int(bounds.hostEnd))
        path = characters.extracting(Int(bounds.pathStart)..<Int(bounds.pathEnd))
        scheme = ContentSecurityPolicySchemeName(protocolCharacters)
        port = bounds.hasPort ? bounds.port : nil
        defaultPort = bounds.defaultPort
        hasDefaultPort = bounds.hasDefaultPort
    }
}

// The default ports of https and http, which WTF lets tests override, asked once per source list a check matches.
struct ContentSecurityPolicyDefaultPorts {
    private var secure: UInt16 = 0
    private var insecure: UInt16 = 0
    private var isKnown = false

    mutating func get() -> (secure: UInt16, insecure: UInt16) {
        if !isKnown {
            secure = WebCore.ContentSecurityPolicyCallbacks.defaultPort(true)
            insecure = WebCore.ContentSecurityPolicyCallbacks.defaultPort(false)
            isKnown = true
        }
        return (secure, insecure)
    }
}

// One source of a source list, or the policy's own origin: scheme, host, port and path matching (CSP3 6.7.2). Its
// scheme, host and path are the characters of its list from `start` to `hostStart`, `pathStart` and `end`.
struct ContentSecurityPolicySource {
    let start: UInt32
    let hostStart: UInt32
    let pathStart: UInt32
    let end: UInt32
    let scheme: ContentSecurityPolicySchemeName
    let port: UInt16?

    let hostHasWildcard: Bool
    let portHasWildcard: Bool
    let isSelfSource: Bool

    init(
        _ start: UInt32,
        _ hostStart: UInt32,
        _ pathStart: UInt32,
        _ end: UInt32,
        _ scheme: ContentSecurityPolicySchemeName,
        _ port: UInt16?,
        _ hostHasWildcard: Bool,
        _ portHasWildcard: Bool,
        _ isSelfSource: Bool
    ) {
        self.start = start
        self.hostStart = hostStart
        self.pathStart = pathStart
        self.end = end
        self.scheme = scheme
        self.port = port
        self.hostHasWildcard = hostHasWildcard
        self.portHasWildcard = portHasWildcard
        self.isSelfSource = isSelfSource
    }

    // `url` has the URL's scheme, host and path, `characters` are the source's list's, and `selfProtocol` is the
    // policy's own scheme.
    func matches<C: ContentSecurityPolicyCharacter, S: ContentSecurityPolicyCharacter>(
        _ url: ContentSecurityPolicyURLParts<C>,
        _ characters: Span<S>,
        _ selfProtocol: Span<UInt16>,
        _ selfScheme: ContentSecurityPolicySchemeName,
        _ defaultPorts: inout ContentSecurityPolicyDefaultPorts,
        _ didReceiveRedirectResponse: Bool
    ) -> Bool {
        // https://www.w3.org/TR/CSP3/#match-url-to-source-expression.
        let schemeMatch: SchemeMatchResult
        if start == hostStart {
            schemeMatch = schemeMatches(url.protocolCharacters, url.scheme, selfProtocol, selfScheme)
        } else {
            schemeMatch = schemeMatches(url.protocolCharacters, url.scheme, characters.extracting(Int(start)..<Int(hostStart)), scheme)
        }
        if schemeMatch == .noMatch {
            return false
        }
        if isSchemeOnly() {
            return true
        }
        let shouldUpgradePorts: ShouldUpgradePorts = schemeMatch == .insecureUpgradeMatch ? .yes : .no
        return hostMatches(url.host, characters) && portMatches(url, shouldUpgradePorts, &defaultPorts)
            && (didReceiveRedirectResponse || pathMatches(url.path, characters))
    }

    // `scheme` is the source's scheme, or the policy's own when the source has none, and `schemeName` its kind.
    private func schemeMatches<C: ContentSecurityPolicyCharacter, T: ContentSecurityPolicyCharacter>(
        _ urlProtocol: Span<C>,
        _ urlSchemeName: ContentSecurityPolicySchemeName,
        _ scheme: Span<T>,
        _ schemeName: ContentSecurityPolicySchemeName
    ) -> SchemeMatchResult {
        // https://www.w3.org/TR/CSP3/#match-schemes.

        // Step 1.1: A matches B. Two schemes of a named kind are equal when their kinds are.
        if schemeName == .other ? urlSchemeName == .other && cspEqualCodeUnits(scheme, urlProtocol) : schemeName == urlSchemeName {
            return .match
        }

        // Step 1.2: A is "http" and B is "https".
        if schemeName == .http && urlSchemeName == .https {
            return .insecureUpgradeMatch
        }

        // Step 1.3: A is "ws" and B is "wss", "http", or "https".
        if schemeName == .ws {
            if urlSchemeName == .wss || urlSchemeName == .https {
                return .insecureUpgradeMatch
            }
            if urlSchemeName == .http {
                return .match
            }
        }

        // Step 1.4: A is "wss" and B is "https".
        if schemeName == .wss && urlSchemeName == .https {
            return .match
        }

        // self-sources can always upgrade to secure protocols and side-grade insecure protocols. (§6.7.2.8 step 4 NOTE)
        if isSelfSource && !scheme.isEmpty {
            if urlSchemeName == .https || urlSchemeName == .wss {
                if schemeName == .http || schemeName == .ws {
                    return .insecureUpgradeMatch
                }
                return .match
            }
            if schemeName == .http && urlSchemeName == .ws {
                return .match
            }
        }

        // Step 2: return "Does Not Match".
        return .noMatch
    }

    private func hostMatches<C: ContentSecurityPolicyCharacter, S: ContentSecurityPolicyCharacter>(
        _ urlHost: Span<C>,
        _ characters: Span<S>
    ) -> Bool {
        let host = characters.extracting(Int(hostStart)..<Int(pathStart))
        if hostHasWildcard {
            if host.isEmpty {
                return true
            }
            return cspWildcardMatches(urlHost, host)
        }
        return cspEqualIgnoringASCIICase(urlHost, host)
    }

    private func pathMatches<C: ContentSecurityPolicyCharacter, S: ContentSecurityPolicyCharacter>(
        _ pathB: Span<C>,
        _ characters: Span<S>
    ) -> Bool {
        // https://www.w3.org/TR/CSP3/#match-paths
        // Path A is the source expression's path (from the CSP directive).
        // Path B is the URL's path being checked against the policy.

        // Step 1: empty path automatically matches.
        if pathStart == end {
            return true
        }
        let pathA = characters.extracting(Int(pathStart)..<Int(end))

        // Step 2: "/" matches empty path.
        if pathA.count == 1 && pathA[0].cspCodeUnit == 0x2F && pathB.isEmpty {
            return true
        }

        // Step 3: directory match if path A ends with '/'.
        let exactMatch = pathA[pathA.count - 1].cspCodeUnit != 0x2F

        // Step 4: strictly split both on '/'. Both are split as String::splitAllowingEmptyEntries does: n
        // separators give n + 1 segments, so the segments are counted and walked in place.
        var segmentCountA = 1
        for index in 0..<pathA.count where pathA[index].cspCodeUnit == 0x2F {
            segmentCountA += 1
        }
        var segmentCountB = 1
        for index in 0..<pathB.count where pathB[index].cspCodeUnit == 0x2F {
            segmentCountB += 1
        }

        // Step 5: path A must not have more segments than path B.
        if segmentCountA > segmentCountB {
            return false
        }

        // Step 6: exact match requires same number of segments.
        if exactMatch && segmentCountA != segmentCountB {
            return false
        }

        // Step 7: for directory match, remove trailing empty segment from A.
        if !exactMatch {
            segmentCountA -= 1
        }

        // Step 8: compare each segment after percent-decoding. A segment without '%' decodes to itself, so
        // only a pair where either has one is decoded.
        var startA = 0
        var startB = 0
        for _ in 0..<segmentCountA {
            var endA = startA
            var hasEscapeA = false
            while endA < pathA.count && pathA[endA].cspCodeUnit != 0x2F {
                if pathA[endA].cspCodeUnit == 0x25 {
                    hasEscapeA = true
                }
                endA += 1
            }
            var endB = startB
            var hasEscapeB = false
            while endB < pathB.count && pathB[endB].cspCodeUnit != 0x2F {
                if pathB[endB].cspCodeUnit == 0x25 {
                    hasEscapeB = true
                }
                endB += 1
            }
            let segmentA = pathA.extracting(startA..<endA)
            let segmentB = pathB.extracting(startB..<endB)
            if hasEscapeA || hasEscapeB {
                if !WebCore.ContentSecurityPolicyCallbacks.decodedPathSegmentsMatch(S.cspMakeString(segmentA), C.cspMakeString(segmentB)) {
                    return false
                }
            } else if !cspEqualCodeUnits(segmentA, segmentB) {
                return false
            }
            startA = endA + 1
            startB = endB + 1
        }

        return true
    }

    private func portMatches<C: ContentSecurityPolicyCharacter>(
        _ url: ContentSecurityPolicyURLParts<C>,
        _ shouldUpgradePorts: ShouldUpgradePorts,
        _ defaultPorts: inout ContentSecurityPolicyDefaultPorts
    ) -> Bool {
        // https://www.w3.org/TR/CSP3/#match-ports
        // input is the source expression's port-part (port).
        // url is the URL being checked against the policy.

        // Step 1: Assert input is null, "*", or a sequence of one or more ASCII digits.
        assert(!(portHasWildcard && port != nil))

        // Step 2: wildcard port matches any URL.
        if portHasWildcard {
            return true
        }

        let urlPort = url.port

        // Steps 3-4: if normalizedInput equals url's port (including null), return "Matches".
        if urlPort == port {
            return true
        }

        // When upgrading from an insecure to secure scheme, treat default
        // ports as equivalent since they differ across schemes (80 vs 443).
        if shouldUpgradePorts == .yes {
            let ports = defaultPorts.get()
            let urlOnSecureDefaultPort = urlPort == ports.secure || (urlPort == nil && (url.scheme == .https || url.scheme == .wss))
            let sourcePortIsUpgradable = port == nil || port == ports.insecure || port == ports.secure
            if urlOnSecureDefaultPort && sourcePortIsUpgradable {
                return true
            }
        }

        // Step 5: if url's port is null, check if source port is the default for url's scheme.
        // port is not null there, since a null port equals a null urlPort above.
        guard let urlPort else {
            // swift-format-ignore: NeverForceUnwrap
            return url.hasDefaultPort && url.defaultPort == port!
        }

        if port == nil {
            return url.hasDefaultPort && url.defaultPort == urlPort
        }

        // Step 6: return "Does Not Match".
        return false
    }

    private func isSchemeOnly() -> Bool {
        hostStart == pathStart && !hostHasWildcard
    }
}
