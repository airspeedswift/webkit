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

// ResourceCryptographicDigest::Algorithm's values, which are also the bits of a HashAlgorithmSet.
let contentSecurityPolicyHashAlgorithmSHA256: UInt8 = 1 << 0
let contentSecurityPolicyHashAlgorithmSHA384: UInt8 = 1 << 1
let contentSecurityPolicyHashAlgorithmSHA512: UInt8 = 1 << 2

// ResourceCryptographicDigest::maximumDigestLength, the bytes of a SHA-512 digest.
let contentSecurityPolicyMaximumDigestLength: UInt8 = 64

// ContentSecurityPolicyModeForExtension's values.
let contentSecurityPolicyModeForExtensionNone: UInt8 = 0
let contentSecurityPolicyModeForExtensionManifestV2: UInt8 = 1
let contentSecurityPolicyModeForExtensionManifestV3: UInt8 = 2

// A ContentSecurityPolicyHash (a ResourceCryptographicDigest): its algorithm and the digest's bytes, at most
// ResourceCryptographicDigest::maximumDigestLength of them, in eight words whose bytes past the length are zero.
struct ContentSecurityPolicyHashValue: Hashable {
    var algorithm: UInt8
    var length: UInt8
    var w0: UInt64
    var w1: UInt64
    var w2: UInt64
    var w3: UInt64
    var w4: UInt64
    var w5: UInt64
    var w6: UInt64
    var w7: UInt64

    init(_ digest: WebCore.ContentSecurityPolicyDigest) {
        algorithm = digest.algorithm
        length = digest.length
        w0 = digest.words.0
        w1 = digest.words.1
        w2 = digest.words.2
        w3 = digest.words.3
        w4 = digest.words.4
        w5 = digest.words.5
        w6 = digest.words.6
        w7 = digest.words.7
    }
}

// A script's integrity digests, parsed from its integrity attribute when a source list with hashes first needs them:
// each digest of its metadata that decodes, of every algorithm.
struct ContentSecurityPolicyIntegrityDigests {
    private let integrity: WTF.String
    private var digests: [ContentSecurityPolicyHashValue] = []
    private var isParsed = false

    init(_ integrity: consuming WTF.String) {
        self.integrity = integrity
    }

    // Whether there are digests and `hashes` contains every one.
    mutating func areAllContained(_ hashes: borrowing Set<ContentSecurityPolicyHashValue>) -> Bool {
        if hashes.isEmpty {
            return false
        }
        if !isParsed {
            isParsed = true
            let decodedDigests = subresourceIntegrityDecodedDigests(integrity)
            digests.reserveCapacity(decodedDigests.count)
            for digest in decodedDigests {
                digests.append(ContentSecurityPolicyHashValue(makeContentSecurityPolicyDigest(digest.algorithm, digest.value.span)))
            }
        }
        let digests = self.digests.span
        if digests.isEmpty {
            return false
        }
        for index in 0..<digests.count where !hashes.contains(digests[index]) {
            return false
        }
        return true
    }
}

// The text between a hash-source's quotes: hash-algorithm "-" base64-value, whose value is at most maximumDigestLength
// bytes. Anything else gives a digest with no algorithm.
func contentSecurityPolicyHashSourceDigest<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ source: Span<CodeUnit>
) -> WebCore.ContentSecurityPolicyDigest {
    guard let extent = resourceCryptographicDigestExtent(source, from: 0), extent.value.upperBound == source.count,
        let value = resourceCryptographicDigestValue(source.extracting(extent.value)),
        value.count <= Int(contentSecurityPolicyMaximumDigestLength)
    else {
        return WebCore.ContentSecurityPolicyDigest()
    }
    return makeContentSecurityPolicyDigest(extent.algorithm, value.span)
}

// A digest with its bytes in the words' memory order, or with a length of 0xFF, which matches no hash source, when it
// has more than maximumDigestLength bytes.
func makeContentSecurityPolicyDigest(_ algorithm: UInt8, _ value: Span<UInt8>) -> WebCore.ContentSecurityPolicyDigest {
    var digest = WebCore.ContentSecurityPolicyDigest()
    digest.algorithm = algorithm
    digest.length = 0xFF
    if value.count > Int(contentSecurityPolicyMaximumDigestLength) {
        return digest
    }
    // At most maximumDigestLength bytes.
    digest.length = UInt8(truncatingIfNeeded: value.count)
    digest.words = (
        contentSecurityPolicyDigestWord(value, 0), contentSecurityPolicyDigestWord(value, 1),
        contentSecurityPolicyDigestWord(value, 2), contentSecurityPolicyDigestWord(value, 3),
        contentSecurityPolicyDigestWord(value, 4), contentSecurityPolicyDigestWord(value, 5),
        contentSecurityPolicyDigestWord(value, 6), contentSecurityPolicyDigestWord(value, 7)
    )
    return digest
}

// The digest's bytes 8 * index to 8 * index + 7 in the word's memory order, zero past its length.
private func contentSecurityPolicyDigestWord(_ value: Span<UInt8>, _ index: Int) -> UInt64 {
    var word: UInt64 = 0
    var byteIndex = index * 8
    let end = Swift.min(byteIndex + 8, value.count)
    var shift: UInt64 = 0
    while byteIndex < end {
        word |= UInt64(value[byteIndex]) &<< shift
        shift += 8
        byteIndex += 1
    }
    return UInt64(littleEndian: word)
}

private let noneKeyword: [UInt8] = Array("'none'".utf8)
private let strictDynamicKeyword: [UInt8] = Array("'strict-dynamic'".utf8)
private let selfKeyword: [UInt8] = Array("'self'".utf8)
private let unsafeInlineKeyword: [UInt8] = Array("'unsafe-inline'".utf8)
private let unsafeEvalKeyword: [UInt8] = Array("'unsafe-eval'".utf8)
private let trustedTypesEvalKeyword: [UInt8] = Array("'trusted-types-eval'".utf8)
private let wasmUnsafeEvalKeyword: [UInt8] = Array("'wasm-unsafe-eval'".utf8)
private let unsafeHashesKeyword: [UInt8] = Array("'unsafe-hashes'".utf8)
private let reportSampleKeyword: [UInt8] = Array("'report-sample'".utf8)
private let reportSHA256Keyword: [UInt8] = Array("'report-sha256'".utf8)
private let reportSHA384Keyword: [UInt8] = Array("'report-sha384'".utf8)
private let reportSHA512Keyword: [UInt8] = Array("'report-sha512'".utf8)
private let noncePrefix: [UInt8] = Array("'nonce-".utf8)
private let sha256Prefix: [UInt8] = Array("sha256".utf8)
private let sha384Prefix: [UInt8] = Array("sha384".utf8)
private let sha512Prefix: [UInt8] = Array("sha512".utf8)
private let blobScheme: [UInt8] = Array("blob".utf8)
private let httpsScheme: [UInt8] = Array("https".utf8)
private let httpScheme: [UInt8] = Array("http".utf8)

private let directiveNamesReportedAsSourceExpressions: [ContentSecurityPolicyDirectiveNames] = [
    .baseURI, .connectSrc, .defaultSrc, .fontSrc, .formAction, .frameSrc, .imgSrc, .mediaSrc, .objectSrc,
    .pluginTypes, .reportTo, .reportURI, .sandbox, .scriptSrc, .styleSrc,
]

private func isCSPDirectiveName<C: ContentSecurityPolicyCharacter>(_ name: Span<C>) -> Bool {
    // Called with a source-expression token, not a parsed directive name, so it is not lowercased.
    for directiveName in directiveNamesReportedAsSourceExpressions where cspEqualLettersIgnoringASCIICase(name, directiveName.spelling.span)
    {
        return true
    }
    return false
}

@inline(always)
private func isHostCharacter(_ c: UInt16) -> Bool {
    cspIsASCIIAlphanumeric(c) || c == 0x2D
}

@inline(always)
private func isPathComponentCharacter(_ c: UInt16) -> Bool {
    c != 0x3F && c != 0x23
}

@inline(always)
private func isSchemeContinuationCharacter(_ c: UInt16) -> Bool {
    cspIsASCIIAlphanumeric(c) || c == 0x2B || c == 0x2D || c == 0x2E
}

@inline(always)
private func isNotColonOrSlash(_ c: UInt16) -> Bool {
    c != 0x3A && c != 0x2F
}

// Match Blink's behavior of allowing an equal sign to appear anywhere in the value of the nonce
// even though this does not match the behavior of Content Security Policy Level 3 spec.,
// <https://w3c.github.io/webappsec-csp/> (29 February 2016).
@inline(always)
private func isNonceCharacter(_ c: UInt16) -> Bool {
    // isBase64OrBase64URLCharacter, or '='.
    cspIsASCIIAlphanumeric(c) || c == 0x2B || c == 0x2F || c == 0x2D || c == 0x5F || c == 0x3D
}

private func isSourceListNone<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) -> Bool {
    var position = 0
    while position < characters.count && cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
        position += 1
    }

    if !cspStartsWithLettersIgnoringASCIICase(characters.extracting(position..<characters.count), noneKeyword.span) {
        return false
    }
    position += noneKeyword.count

    while position < characters.count && cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
        position += 1
    }

    return position == characters.count
}

private func isRestrictedDirectiveForMode(_ directive: ContentSecurityPolicyDirectiveNames, _ mode: UInt8) -> Bool {
    switch mode {
    case contentSecurityPolicyModeForExtensionNone:
        return false
    // FIXME: If the script-src directive is strict enough, we should allow default-src to have more values.
    case contentSecurityPolicyModeForExtensionManifestV2:
        return directive == .scriptSrc || directive == .defaultSrc
    case contentSecurityPolicyModeForExtensionManifestV3:
        return directive == .scriptSrc || directive == .objectSrc || directive == .workerSrc || directive == .defaultSrc
    default:
        return false
    }
}

private func extensionModeAllowsKeywordsForDirective(_ mode: UInt8, _ directiveName: ContentSecurityPolicyDirectiveNames) -> Bool {
    mode != contentSecurityPolicyModeForExtensionManifestV3 || !isRestrictedDirectiveForMode(directiveName, mode)
}

// URL::protocolIs with a String, as isProtocolAllowedByStar asks for the policy's own protocol: the URL's scheme
// compared with isASCIIAlphaCaselessEqual, whose expected character is a char.
private func urlProtocolIs<C: ContentSecurityPolicyCharacter>(
    _ url: ContentSecurityPolicyURL,
    _ urlProtocol: Span<C>,
    _ protocolName: Span<UInt16>
) -> Bool {
    if !url.isValid {
        return false
    }
    if urlProtocol.count != protocolName.count {
        return false
    }
    for index in 0..<urlProtocol.count {
        // The expected character is narrowed to a char, which is signed.
        let expected = Int8(truncatingIfNeeded: protocolName[index])
        if Int(urlProtocol[index].cspCodeUnit | 0x20) != Int(expected) {
            return false
        }
    }
    return true
}

// Writes the low byte of each character, lowercased for a scheme, to `output` from `offset`, which the caller has
// checked `output` holds. The bounds check is made once, before the loop, so the loop has none.
@inline(always)
private func cspStoreLowBytes<C: ContentSecurityPolicyCharacter>(
    _ characters: Span<C>,
    _ output: inout MutableSpan<UInt8>,
    _ offset: Int,
    lowercased: Bool
) {
    for index in 0..<characters.count {
        let c = characters[index].cspCodeUnit
        // Below the end the caller checked.
        output[offset &+ index] = UInt8(truncatingIfNeeded: lowercased ? cspToASCIILower(c) : c)
    }
}

// A source list: the value of a fetch directive, with its keywords, and where its nonces, hashes and sources are in
// its policy's store.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct ContentSecurityPolicySourceList {
    private struct Source {
        var scheme: Range<Int> = 0..<0
        var host: Range<Int> = 0..<0
        var hostHasWildcard = false
        var port: UInt16? = nil
        var portHasWildcard = false
        var path: Range<Int> = 0..<0
    }

    // The list's sources in its policy's store, from m_sourceStart to m_sourceEnd, and the indices plus one of its
    // nonces' and its hashes' sets there, or 0 for none.
    private var m_sourceStart: UInt32 = 0
    private var m_sourceEnd: UInt32 = 0
    private var m_nonces: UInt32 = 0
    private var m_hashes: UInt32 = 0
    private var m_hashAlgorithmsUsed: UInt8 = 0
    let m_directiveName: ContentSecurityPolicyDirectiveNames
    let m_contentSecurityPolicyModeForExtension: UInt8
    private var m_allowSelf = false
    private var m_allowStar = false
    private var m_allowInline = false
    private var m_allowEval = false
    private var m_allowTrustedEval = false
    private var m_allowWasmEval = false
    private var m_allowNonParserInsertedScripts = false
    private var m_allowUnsafeHashes = false
    private var m_reportSample = false
    private var m_reportHash: UInt8 = 0

    init(_ directiveName: ContentSecurityPolicyDirectiveNames, _ contentSecurityPolicyModeForExtension: UInt8) {
        m_directiveName = directiveName
        m_contentSecurityPolicyModeForExtension = contentSecurityPolicyModeForExtension
    }

    func matches(_ url: ContentSecurityPolicyURL, _ didReceiveRedirectResponse: Bool, _ store: ContentSecurityPolicySourceStore) -> Bool {
        if url.is8Bit {
            return matches(url, url.string.span8(), didReceiveRedirectResponse, store)
        }
        return matches(url, url.string.checkedSpan16(), didReceiveRedirectResponse, store)
    }

    private func matches<C: ContentSecurityPolicyCharacter>(
        _ url: ContentSecurityPolicyURL,
        _ urlCharacters: Span<C>,
        _ didReceiveRedirectResponse: Bool,
        _ store: ContentSecurityPolicySourceStore
    ) -> Bool {
        let parts = ContentSecurityPolicyURLParts(urlCharacters, url.bounds)
        let selfCharacters = url.selfOrigin.characters.span
        let selfProtocol = selfCharacters.extracting(0..<url.selfOrigin.protocolLength)
        let selfScheme = url.selfOrigin.scheme

        if m_allowStar && isProtocolAllowedByStar(url, parts, selfProtocol) {
            return true
        }

        var defaultPorts = ContentSecurityPolicyDefaultPorts()
        if m_allowSelf, let selfSource = url.selfOrigin.source,
            selfSource.matches(parts, selfCharacters, selfProtocol, selfScheme, &defaultPorts, false)
        {
            return true
        }

        let characters = store.characters.span
        let sources = store.sources.span
        for index in Int(m_sourceStart)..<Int(m_sourceEnd)
        where sources[index].matches(parts, characters, selfProtocol, selfScheme, &defaultPorts, didReceiveRedirectResponse) {
            return true
        }

        return false
    }

    func matches(_ hashes: WebCore.ContentSecurityPolicyContentHashes, _ store: ContentSecurityPolicySourceStore) -> Bool {
        if m_hashes == 0 {
            return false
        }
        let hashSets = store.hashSets.span
        let index = Int(m_hashes) - 1
        let count = hashes.count
        return (count > 0 && hashSets[index].contains(ContentSecurityPolicyHashValue(hashes.digests.0)))
            || (count > 1 && hashSets[index].contains(ContentSecurityPolicyHashValue(hashes.digests.1)))
            || (count > 2 && hashSets[index].contains(ContentSecurityPolicyHashValue(hashes.digests.2)))
    }

    // Whether there are digests and the list's hashes contain every one; without hashes, the digests are not read.
    func matchesAll(_ digests: inout ContentSecurityPolicyIntegrityDigests, _ store: ContentSecurityPolicySourceStore) -> Bool {
        if m_hashes == 0 {
            return false
        }
        let hashSets = store.hashSets.span
        return digests.areAllContained(hashSets[Int(m_hashes) - 1])
    }

    func matches(_ nonce: borrowing WTF.String, _ store: ContentSecurityPolicySourceStore) -> Bool {
        if nonce.isEmpty() {
            return false
        }

        if m_nonces == 0 {
            return false
        }
        let nameSets = store.nameSets.span
        return nameSets[Int(m_nonces) - 1].contains(nonce)
    }

    func hashAlgorithmsUsed() -> UInt8 { m_hashAlgorithmsUsed }

    func allowInline() -> Bool { m_allowInline && m_hashes == 0 && m_nonces == 0 }
    func allowEval() -> Bool { m_allowEval }
    func allowTrustedEval() -> Bool { m_allowTrustedEval }
    func allowWasmEval() -> Bool { m_allowWasmEval }
    func allowNonParserInsertedScripts() -> Bool { m_allowNonParserInsertedScripts }
    func allowUnsafeHashes() -> Bool { m_allowUnsafeHashes }
    func shouldReportSample() -> Bool { m_reportSample }

    func reportHash() -> UInt8 { m_reportHash }

    private func isProtocolAllowedByStar<C: ContentSecurityPolicyCharacter>(
        _ url: ContentSecurityPolicyURL,
        _ parts: ContentSecurityPolicyURLParts<C>,
        _ selfProtocol: Span<UInt16>
    ) -> Bool {
        if url.allowContentSecurityPolicySourceStarToMatchAnyProtocol {
            return true
        }

        // This is counter to the CSP3 spec which only allows HTTPS but Chromium also allows it.
        let urlScheme = parts.scheme
        var isAllowed =
            url.protocolIsInHTTPFamily || urlScheme == .ws || urlScheme == .wss
            || urlProtocolIs(url, parts.protocolCharacters, selfProtocol)
        // Also not allowed by the Content Security Policy Level 3 spec., we allow a data URL to match
        // "img-src *" and either a data URL or blob URL to match "media-src *" for web compatibility.
        if m_directiveName == .imgSrc {
            isAllowed = isAllowed || urlScheme == .data
        } else if m_directiveName == .mediaSrc {
            isAllowed = isAllowed || urlScheme == .data || urlScheme == .blob
        }
        return isAllowed
    }

    private func isValidSourceForExtensionMode<C: ContentSecurityPolicyCharacter>(
        _ parsedSource: Source,
        _ token: Span<C>,
        _ policy: ContentSecurityPolicyDirectiveListVector
    ) -> Bool {
        switch m_contentSecurityPolicyModeForExtension {
        case contentSecurityPolicyModeForExtensionManifestV2:
            if !isRestrictedDirectiveForMode(m_directiveName, contentSecurityPolicyModeForExtensionManifestV2) {
                return true
            }

            if parsedSource.hostHasWildcard && policy.isPublicSuffix(C.cspMakeString(token.extracting(parsedSource.host))) {
                return false
            }

            let scheme = token.extracting(parsedSource.scheme)
            if cspEqualLettersIgnoringASCIICase(scheme, blobScheme.span) {
                return true
            }

            if !cspEqualLettersIgnoringASCIICase(scheme, httpsScheme.span) || parsedSource.host.isEmpty {
                return false
            }
        case contentSecurityPolicyModeForExtensionManifestV3:
            if !isRestrictedDirectiveForMode(m_directiveName, contentSecurityPolicyModeForExtensionManifestV3) {
                return true
            }

            let scheme = token.extracting(parsedSource.scheme)
            let schemeIsInHTTPFamily =
                cspEqualLettersIgnoringASCIICase(scheme, httpsScheme.span) || cspEqualLettersIgnoringASCIICase(scheme, httpScheme.span)
            if !schemeIsInHTTPFamily || !policy.isLocalHostOrLoopbackIPAddress(C.cspMakeString(token.extracting(parsedSource.host))) {
                return false
            }
        default:
            return true
        }
        return true
    }

    // source-list       = *WSP [ source *( 1*WSP source ) *WSP ]
    //                   / *WSP "'none'" *WSP
    //
    // The sources, nonces and hashes go in `store`; `charactersAfterValue` is how many of the policy's characters follow
    // `characters`.
    mutating func parse<C: ContentSecurityPolicyCharacter>(
        _ characters: Span<C>,
        _ policy: ContentSecurityPolicyDirectiveListVector,
        _ store: inout ContentSecurityPolicySourceStore,
        _ charactersAfterValue: Int
    ) {
        // A directive's sources are the store's from its first on; the store holds a policy's sources, which number
        // fewer than 2^32.
        m_sourceStart = UInt32(truncatingIfNeeded: store.sources.count)
        m_sourceEnd = m_sourceStart
        if isSourceListNone(characters) {
            return
        }

        var position = 0
        while position < characters.count {
            while position < characters.count && cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
                position += 1
            }
            if position == characters.count {
                return
            }

            let beginSource = position
            while position < characters.count && !cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
                position += 1
            }

            let token = characters.extracting(beginSource..<position)

            if parseNonceSource(token, &store) {
                continue
            }

            if parseHashSource(token, &store) {
                continue
            }

            if let source = parseSource(token, policy) {
                // Wildcard hosts and keyword sources ('self', 'unsafe-inline', etc.) aren't stored as sources, but as
                // attributes on the source list itself.
                if source.scheme.isEmpty && source.host.isEmpty && source.port == nil && source.path.isEmpty {
                    continue
                }
                let host = token.extracting(source.host)
                if isCSPDirectiveName(host) {
                    policy.reportDirectiveAsSourceExpression(m_directiveName.string(), C.cspMakeString(host))
                }
                if isValidSourceForExtensionMode(source, token, policy) {
                    ContentSecurityPolicySourceList.reserveSourceCharacters(
                        &store,
                        token.count,
                        characters.count - beginSource + charactersAfterValue
                    )
                    appendSource(source, token, &store)
                }
            } else {
                policy.reportInvalidSourceExpression(m_directiveName.string(), C.cspMakeString(token))
            }
        }
    }

    // Room for a source of at most `length` characters. The sources' characters are at most the policy's from the first
    // source on, `remaining` from this one; past the first kilobyte the capacity doubles, so a policy full of hashes and
    // nonces holds about as much as its sources need.
    private static func reserveSourceCharacters(_ store: inout ContentSecurityPolicySourceStore, _ length: Int, _ remaining: Int) {
        let count = store.characters.count
        if store.characters.capacity - count >= length {
            return
        }
        store.characters.reserveCapacity(count + Swift.min(remaining, Swift.max(length, count, 1024)))
    }

    // The scheme is stored lowercased, the host and the path as written.
    private mutating func appendSource<C: ContentSecurityPolicyCharacter>(
        _ source: Source,
        _ token: Span<C>,
        _ store: inout ContentSecurityPolicySourceStore
    ) {
        let scheme = token.extracting(source.scheme)
        let host = token.extracting(source.host)
        let path = token.extracting(source.path)
        let start = store.characters.count
        let hostStart = start + scheme.count
        let pathStart = hostStart + host.count
        let end = pathStart + path.count
        store.characters.append(contentsOf: repeatElement(0, count: end - start))
        do {
            var characters = store.characters.mutableSpan
            cspStoreLowBytes(scheme, &characters, start, lowercased: true)
            cspStoreLowBytes(host, &characters, hostStart, lowercased: false)
            cspStoreLowBytes(path, &characters, pathStart, lowercased: false)
        }
        let schemeName = ContentSecurityPolicySchemeName(store.characters.span.extracting(start..<hostStart))
        // Offsets into a policy's characters, which number fewer than 2^32.
        store.sources.append(
            ContentSecurityPolicySource(
                UInt32(truncatingIfNeeded: start),
                UInt32(truncatingIfNeeded: hostStart),
                UInt32(truncatingIfNeeded: pathStart),
                UInt32(truncatingIfNeeded: end),
                schemeName,
                source.port,
                source.hostHasWildcard,
                source.portHasWildcard,
                false
            )
        )
        m_sourceEnd = UInt32(truncatingIfNeeded: store.sources.count)
    }

    // source            = scheme ":"
    //                   / ( [ scheme "://" ] host [ port ] [ path ] )
    //                   / "'self'"
    //
    // The ranges of the result are into `token`.
    private mutating func parseSource<C: ContentSecurityPolicyCharacter>(
        _ token: Span<C>,
        _ policy: ContentSecurityPolicyDirectiveListVector
    ) -> Source? {
        let end = token.count
        if end == 0 {
            return nil
        }

        if cspEqualLettersIgnoringASCIICase(token, noneKeyword.span) {
            return nil
        }

        let source = Source()

        if end == 1 && token[0].cspCodeUnit == 0x2A
            && !isRestrictedDirectiveForMode(m_directiveName, m_contentSecurityPolicyModeForExtension)
        {
            m_allowStar = true
            return source
        }

        let mode = m_contentSecurityPolicyModeForExtension
        if cspEqualLettersIgnoringASCIICase(token, strictDynamicKeyword.span)
            && extensionModeAllowsKeywordsForDirective(mode, m_directiveName)
            && (m_directiveName == .scriptSrc || m_directiveName == .scriptSrcElem || m_directiveName == .defaultSrc)
        {
            m_allowNonParserInsertedScripts = true
            m_allowSelf = false
            m_allowInline = false
            return source
        }

        if cspEqualLettersIgnoringASCIICase(token, selfKeyword.span) {
            m_allowSelf = !m_allowNonParserInsertedScripts
            return source
        }

        if cspEqualLettersIgnoringASCIICase(token, unsafeInlineKeyword.span) && !isRestrictedDirectiveForMode(m_directiveName, mode) {
            m_allowInline = !m_allowNonParserInsertedScripts
            return source
        }

        if cspEqualLettersIgnoringASCIICase(token, unsafeEvalKeyword.span) && extensionModeAllowsKeywordsForDirective(mode, m_directiveName)
        {
            m_allowEval = true
            m_allowWasmEval = true
            return source
        }

        if cspEqualLettersIgnoringASCIICase(token, trustedTypesEvalKeyword.span)
            && extensionModeAllowsKeywordsForDirective(mode, m_directiveName)
        {
            m_allowTrustedEval = true
            return source
        }

        if cspEqualLettersIgnoringASCIICase(token, wasmUnsafeEvalKeyword.span) {
            m_allowWasmEval = true
            return source
        }

        if cspEqualLettersIgnoringASCIICase(token, unsafeHashesKeyword.span)
            && extensionModeAllowsKeywordsForDirective(mode, m_directiveName)
        {
            m_allowUnsafeHashes = true
            return source
        }

        if cspEqualLettersIgnoringASCIICase(token, reportSampleKeyword.span)
            && extensionModeAllowsKeywordsForDirective(mode, m_directiveName)
        {
            m_reportSample = true
            return source
        }

        if cspEqualLettersIgnoringASCIICase(token, reportSHA256Keyword.span)
            && extensionModeAllowsKeywordsForDirective(mode, m_directiveName)
        {
            m_reportHash |= contentSecurityPolicyHashAlgorithmSHA256
            return source
        }

        if cspEqualLettersIgnoringASCIICase(token, reportSHA384Keyword.span)
            && extensionModeAllowsKeywordsForDirective(mode, m_directiveName)
        {
            m_reportHash |= contentSecurityPolicyHashAlgorithmSHA384
            return source
        }

        if cspEqualLettersIgnoringASCIICase(token, reportSHA512Keyword.span)
            && extensionModeAllowsKeywordsForDirective(mode, m_directiveName)
        {
            m_reportHash |= contentSecurityPolicyHashAlgorithmSHA512
            return source
        }

        if m_allowNonParserInsertedScripts {
            return source
        }

        return parseHostSource(token, policy)
    }

    private func parseHostSource<C: ContentSecurityPolicyCharacter>(
        _ token: Span<C>,
        _ policy: ContentSecurityPolicyDirectiveListVector
    ) -> Source? {
        var source = Source()
        let end = token.count
        var position = 0
        var beginHost = 0
        var beginPath = end
        var beginPort: Int? = nil

        while position < end && isNotColonOrSlash(token[position].cspCodeUnit) {
            position += 1
        }

        if position == end {
            // host
            //     ^
            guard let host = parseHost(token, beginHost..<position) else {
                return nil
            }

            source.host = host.value
            source.hostHasWildcard = host.hasWildcard
            return source
        }

        if token[position].cspCodeUnit == 0x2F {
            // host/path || host/ || /
            //     ^            ^    ^
            guard let host = parseHost(token, beginHost..<position) else {
                return nil
            }

            let path = parsePath(token, position..<end, policy)

            source.host = host.value
            source.hostHasWildcard = host.hasWildcard
            source.path = path
            return source
        }

        if token[position].cspCodeUnit == 0x3A {
            if end - position == 1 {
                // scheme:
                //       ^
                guard let scheme = parseScheme(token, 0..<position) else {
                    return nil
                }

                source.scheme = scheme
                return source
            }

            if token[position + 1].cspCodeUnit == 0x2F {
                // scheme://host || scheme://
                //       ^                ^
                guard let scheme = parseScheme(token, 0..<position) else {
                    return nil
                }
                // ':' is at position and '/' after it.
                position += 2
                if position == end || token[position].cspCodeUnit != 0x2F {
                    return nil
                }
                position += 1
                if position == end {
                    return nil
                }

                source.scheme = scheme

                beginHost = position
                while position < end && isNotColonOrSlash(token[position].cspCodeUnit) {
                    position += 1
                }
            }

            if position < end && token[position].cspCodeUnit == 0x3A {
                // host:port || scheme://host:port
                //     ^                     ^
                beginPort = position
                while position < end && token[position].cspCodeUnit != 0x2F {
                    position += 1
                }
            }
        }

        if position < end && token[position].cspCodeUnit == 0x2F {
            // scheme://host/path || scheme://host:port/path
            //              ^                          ^
            if position == beginHost {
                return nil
            }

            beginPath = position
        }

        guard let host = parseHost(token, beginHost..<(beginPort ?? beginPath)) else {
            return nil
        }

        if let beginPort {
            guard let port = parsePort(token, beginPort..<beginPath) else {
                return nil
            }

            source.port = port.value
            source.portHasWildcard = port.hasWildcard
        }

        if beginPath < end {
            source.path = parsePath(token, beginPath..<end, policy)
        }

        source.host = host.value
        source.hostHasWildcard = host.hasWildcard
        return source
    }

    //                     ; <scheme> production from RFC 3986
    // scheme      = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
    //
    private func parseScheme<C: ContentSecurityPolicyCharacter>(_ token: Span<C>, _ range: Range<Int>) -> Range<Int>? {
        if range.isEmpty {
            return nil
        }

        var position = range.lowerBound
        if !cspIsASCIIAlpha(token[position].cspCodeUnit) {
            return nil
        }
        position += 1

        while position < range.upperBound && isSchemeContinuationCharacter(token[position].cspCodeUnit) {
            position += 1
        }

        if position != range.upperBound {
            return nil
        }

        return range
    }

    // https://w3c.github.io/webappsec-csp/#grammardef-host-char
    // host-part = "*" / [ "*." ] 1*host-char *( "." 1*host-char ) [ "." ]
    // host-char = ALPHA / DIGIT / "-"
    //
    private func parseHost<C: ContentSecurityPolicyCharacter>(
        _ token: Span<C>,
        _ range: Range<Int>
    ) -> (value: Range<Int>, hasWildcard: Bool)? {
        if range.isEmpty {
            return nil
        }

        var position = range.lowerBound
        let end = range.upperBound
        var hasWildcard = false

        if token[position].cspCodeUnit == 0x2A {
            position += 1
            hasWildcard = true

            if position == end {
                return (0..<0, true)
            }

            if token[position].cspCodeUnit != 0x2E {
                return nil
            }
            position += 1

            if position == end {
                return nil
            }
        }

        let hostBegin = position

        while position < end {
            if !isHostCharacter(token[position].cspCodeUnit) {
                return nil
            }
            position += 1

            while position < end && isHostCharacter(token[position].cspCodeUnit) {
                position += 1
            }

            if position < end {
                if token[position].cspCodeUnit != 0x2E {
                    return nil
                }
                position += 1
            }
        }

        return (hostBegin..<position, hasWildcard)
    }

    private func parsePath<C: ContentSecurityPolicyCharacter>(
        _ token: Span<C>,
        _ range: Range<Int>,
        _ policy: ContentSecurityPolicyDirectiveListVector
    ) -> Range<Int> {
        var position = range.lowerBound
        while position < range.upperBound && isPathComponentCharacter(token[position].cspCodeUnit) {
            position += 1
        }
        // path/to/file.js?query=string || path/to/file.js#anchor
        //                ^                               ^
        if position < range.upperBound {
            policy.reportInvalidPathCharacter(
                m_directiveName.string(),
                C.cspMakeString(token.extracting(range)),
                UInt8(truncatingIfNeeded: token[position].cspCodeUnit)
            )
        }

        return range.lowerBound..<position
    }

    // port              = ":" ( 1*DIGIT / "*" )
    //
    private func parsePort<C: ContentSecurityPolicyCharacter>(_ token: Span<C>, _ range: Range<Int>) -> (value: UInt16?, hasWildcard: Bool)?
    {
        // range starts at the ':'.
        let begin = range.lowerBound + 1
        let end = range.upperBound

        if begin == end {
            return nil
        }

        if end - begin == 1 && token[begin].cspCodeUnit == 0x2A {
            return (nil, true)
        }

        // parseInteger<uint16_t>: an overflow is no port, like 0.
        var portInteger: UInt32 = 0
        for position in begin..<end {
            let c = token[position].cspCodeUnit
            if !cspIsASCIIDigit(c) {
                return nil
            }
            if portInteger <= 0xFFFF {
                // Cannot overflow: portInteger is at most 0xFFFF before the step, and c is a digit.
                portInteger = portInteger * 10 + UInt32(c - 0x30)
            }
        }
        if portInteger == 0 || portInteger > 0xFFFF {
            return nil
        }

        return (UInt16(truncatingIfNeeded: portInteger), false)
    }

    // nonce-source    = "'nonce-" nonce-value "'"
    // nonce-value     = base64-value
    private mutating func parseNonceSource<C: ContentSecurityPolicyCharacter>(
        _ token: Span<C>,
        _ store: inout ContentSecurityPolicySourceStore
    ) -> Bool {
        if !cspStartsWithLettersIgnoringASCIICase(token, noncePrefix.span) {
            return false
        }

        let beginNonceValue = noncePrefix.count
        var position = beginNonceValue
        while position < token.count && isNonceCharacter(token[position].cspCodeUnit) {
            position += 1
        }
        if position == beginNonceValue {
            return false
        }
        let nonceValue = beginNonceValue..<position
        // The closing quote must be the last character of the source expression;
        // any trailing characters make this an invalid nonce-source.
        if position == token.count || token[position].cspCodeUnit != 0x27 || position + 1 != token.count {
            return false
        }
        if extensionModeAllowsKeywordsForDirective(m_contentSecurityPolicyModeForExtension, m_directiveName) {
            if m_nonces == 0 {
                store.nameSets.append(ContentSecurityPolicyNameSet())
                // A policy has fewer than 2^32 source lists.
                m_nonces = UInt32(truncatingIfNeeded: store.nameSets.count)
            }
            store.nameSets[Int(m_nonces) - 1].add(token.extracting(nonceValue))
        }
        return true
    }

    // hash-source    = "'" hash-algorithm "-" base64-value "'"
    // hash-algorithm = "sha256" / "sha384" / "sha512"
    // base64-value  = 1*( ALPHA / DIGIT / "+" / "/" / "-" / "_" )*2( "=" )
    private mutating func parseHashSource<C: ContentSecurityPolicyCharacter>(
        _ token: Span<C>,
        _ store: inout ContentSecurityPolicySourceStore
    ) -> Bool {
        // The quotes, the algorithm and the '-' are checked here, so only a token that could be a hash-source is parsed
        // as a digest, without its quotes, which checks the rest: the digest's characters and decoding.
        if token.count < 8 || token[0].cspCodeUnit != 0x27 || token[7].cspCodeUnit != 0x2D {
            return false
        }
        let algorithm = token.extracting(1..<7)
        if !cspEqualLettersIgnoringASCIICase(algorithm, sha256Prefix.span)
            && !cspEqualLettersIgnoringASCIICase(algorithm, sha384Prefix.span)
            && !cspEqualLettersIgnoringASCIICase(algorithm, sha512Prefix.span)
        {
            return false
        }

        if token[token.count - 1].cspCodeUnit != 0x27 {
            return false
        }

        // No algorithm when the rest is not a hash-source; a length above maximumDigestLength is not one either.
        let digest = C.cspHashSourceDigest(token.extracting(1..<(token.count - 1)))
        if digest.algorithm == 0 || digest.length > contentSecurityPolicyMaximumDigestLength {
            return false
        }

        if extensionModeAllowsKeywordsForDirective(m_contentSecurityPolicyModeForExtension, m_directiveName) {
            m_hashAlgorithmsUsed |= digest.algorithm
            if m_hashes == 0 {
                store.hashSets.append([])
                // A policy has fewer than 2^32 source lists.
                m_hashes = UInt32(truncatingIfNeeded: store.hashSets.count)
            }
            store.hashSets[Int(m_hashes) - 1].insert(ContentSecurityPolicyHashValue(digest))
        }
        return true
    }
}
