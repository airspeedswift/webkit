// Copyright (C) 2006-2025 Apple Inc. All rights reserved.
// Copyright (C) 2009 Google Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
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

// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// them name (rdar://192229293).
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.Core.HTTPHeaderMap
internal import WebCore_Private.Core.HTTPHeaderNames
internal import WebCore_Private.Core.ParsedContentRange
internal import WebCore_Private.Core.ResourceResponseBase
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import wtf.Core.Markable
internal import wtf.Core.Seconds
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.Vector
internal import wtf.Core.WallTime
internal import wtf.Core.text.WTFString

// MARK: Filtering and sanitizing header fields

/// The headers `ResourceResponseBase::filter()` keeps in a CORS response: the CORS-safelisted headers and those
/// `exposeHeaders` exposes, as SecurityPoliciesKeepMask holds them, and every header when `allowsStar` and
/// `exposeHeaders` holds a `*`. `exposeHeaders` is the response's `Access-Control-Expose-Headers` value.
///
/// `headers` is the filtered copy's header map, which `filter()` owns on its stack and passes by reference. While it
/// is borrowed this calls only `HTTPHeaderMap`'s `commonHeadersSpan()` and `uncommonHeadersSpan()` on it, and String
/// functions; none of them changes it, and nothing here reaches the response or calls back into script. `filter()`
/// removes the headers only after this returns.
@_expose(Cxx)
func resourceResponseCORSHeadersToKeep(
    _ headers: borrowing WebCore.HTTPHeaderMap,
    _ exposeHeaders: consuming WTF.String,
    _ allowsStar: Bool
) -> WebCore.SecurityPoliciesKeepMask {
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(exposeHeaders)
    if !bytes.isEmpty {
        return resourceResponseCORSHeadersToKeep(headers, bytes, allowsStar)
    }
    let units: Span<UInt16> = exposeHeaders.checkedSpan16()
    return resourceResponseCORSHeadersToKeep(headers, units, allowsStar)
}

private func resourceResponseCORSHeadersToKeep<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ headers: borrowing WebCore.HTTPHeaderMap,
    _ exposeHeaders: Span<CodeUnit>,
    _ allowsStar: Bool
) -> WebCore.SecurityPoliciesKeepMask {
    let exposedHeaders = resourceResponseExposedHeaders(exposeHeaders)
    var keep = WebCore.SecurityPoliciesKeepMask()
    if allowsStar && exposedHeaders.exposesStar {
        return keep
    }
    let commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader> = headers.commonHeadersSpan()
    var commonNames = ResourceResponseHeaderNameSet()
    var removesHeaders = false
    for index in commonHeaders.indices {
        let name = commonHeaders[index].key
        let isKept: Bool
        switch FetchHeaderChecks.crossOriginSafeHeaderNameDecision(name) {
        case .safe:
            isKept = true
        case .notSafe:
            isKept = false
        case .safeIfExposed:
            isKept = exposedHeaders.commonNames.contains(name)
        }
        commonNames.insert(name, if: isKept)
        if !isKept {
            removesHeaders = true
        }
    }
    keepExposedHeaders(&keep, commonNames, removesHeaders, headers.uncommonHeadersSpan(), exposedHeaders, exposeHeaders)
    return keep
}

/// The headers `ResourceResponseBase::sanitizeHTTPHeaderFields()` keeps for `type` and `tainting`, as
/// SecurityPoliciesKeepMask holds them. `exposeHeaders` is the response's `Access-Control-Expose-Headers` value.
///
/// `headers` is the response's own `m_httpHeaderFields`, which `sanitizeHTTPHeaderFields()` passes by reference. While it
/// is borrowed this calls only `HTTPHeaderMap`'s `commonHeadersSpan()` and `uncommonHeadersSpan()` on it, and String
/// functions; none of them changes it, and nothing here reaches the response or calls back into script. The caller
/// removes the headers only after this returns.
@_expose(Cxx)
func resourceResponseSanitizedHeadersToKeep(
    _ headers: borrowing WebCore.HTTPHeaderMap,
    _ type: WebCore.ResourceResponseBase.SanitizationType,
    _ tainting: WebCore.ResourceResponseBaseTainting,
    _ exposeHeaders: consuming WTF.String
) -> WebCore.SecurityPoliciesKeepMask {
    var keep = WebCore.SecurityPoliciesKeepMask()
    switch type {
    case .Redirection:
        keepSafeCommonHeaders(&keep, headers.commonHeadersSpan(), isSafeRedirectionResponseHeader)
    case .CrossOriginSafe:
        switch tainting {
        case .Cors:
            let commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader> = headers.commonHeadersSpan()
            let uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader> = headers.uncommonHeadersSpan()
            let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(exposeHeaders)
            if !bytes.isEmpty {
                keepCrossOriginSafeHeaders(&keep, commonHeaders, uncommonHeaders, bytes)
            } else {
                let units: Span<UInt16> = exposeHeaders.checkedSpan16()
                keepCrossOriginSafeHeaders(&keep, commonHeaders, uncommonHeaders, units)
            }
        case .Opaque, .Opaqueredirect:
            keepSafeCommonHeaders(&keep, headers.commonHeadersSpan(), isSafeCrossOriginResponseHeader)
        default:
            break
        }
    default:
        break
    }
    return keep
}

/// Sets `keep` to the common headers whose name `isSafe` holds for, and no uncommon header.
@inline(always)
private func keepSafeCommonHeaders(
    _ keep: inout WebCore.SecurityPoliciesKeepMask,
    _ commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader>,
    _ isSafe: (WebCore.HTTPHeaderName) -> Bool
) {
    var commonNames = ResourceResponseHeaderNameSet()
    for index in commonHeaders.indices {
        let name = commonHeaders[index].key
        commonNames.insert(name, if: isSafe(name))
    }
    keep.commonNamesLow = commonNames.low
    keep.commonNamesHigh = commonNames.high
    keep.removesHeaders = true
}

/// The CORS-tainted case of resourceResponseSanitizedHeadersToKeep(): the safe headers and those `exposeHeaders` exposes,
/// all of them when it holds a `*`.
private func keepCrossOriginSafeHeaders<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ keep: inout WebCore.SecurityPoliciesKeepMask,
    _ commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader>,
    _ uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader>,
    _ exposeHeaders: Span<CodeUnit>
) {
    let exposedHeaders = resourceResponseExposedHeaders(exposeHeaders)
    if exposedHeaders.exposesStar {
        return
    }
    var commonNames = ResourceResponseHeaderNameSet()
    var removesHeaders = false
    for index in commonHeaders.indices {
        let name = commonHeaders[index].key
        let isKept = isSafeCrossOriginResponseHeader(name) || exposedHeaders.commonNames.contains(name)
        commonNames.insert(name, if: isKept)
        if !isKept {
            removesHeaders = true
        }
    }
    keepExposedHeaders(&keep, commonNames, removesHeaders, uncommonHeaders, exposedHeaders, exposeHeaders)
}

/// Sets `keep` to the common headers named in `commonNames` and the uncommon headers `exposedHeaders` exposes: a bit for
/// each of the first 64 and a byte for each later one. `removesCommonHeaders` is whether a common header is removed.
private func keepExposedHeaders<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ keep: inout WebCore.SecurityPoliciesKeepMask,
    _ commonNames: ResourceResponseHeaderNameSet,
    _ removesCommonHeaders: Bool,
    _ uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader>,
    _ exposedHeaders: borrowing ResourceResponseExposedHeaders,
    _ exposeHeaders: Span<CodeUnit>
) {
    var removesHeaders = removesCommonHeaders
    var uncommonPositions: UInt64 = 0
    let firstUncommonHeaders = uncommonHeaders.extracting(..<min(uncommonHeaders.count, 64))
    for index in firstUncommonHeaders.indices {
        let isKept = exposedHeaders.containsUncommonName(firstUncommonHeaders[index].key, exposeHeaders)
        if !isKept {
            removesHeaders = true
        }
        // A shift by a position below 64.
        uncommonPositions |= UInt64(isKept ? 1 : 0) &<< UInt64(truncatingIfNeeded: index)
    }
    if uncommonHeaders.count > 64 {
        let laterUncommonHeaders = uncommonHeaders.extracting(64...)
        keep.laterUncommonPositions.reserveCapacity(laterUncommonHeaders.count)
        for index in laterUncommonHeaders.indices {
            let isKept = exposedHeaders.containsUncommonName(laterUncommonHeaders[index].key, exposeHeaders)
            if !isKept {
                removesHeaders = true
            }
            keep.laterUncommonPositions.append(consuming: isKept ? 1 : 0)
        }
    }
    keep.commonNamesLow = commonNames.low
    keep.commonNamesHigh = commonNames.high
    keep.uncommonPositions = uncommonPositions
    keep.removesHeaders = removesHeaders
}

/// `parseAccessControlAllowList<ASCIICaseInsensitiveHash>()` of an `Access-Control-Expose-Headers` value, the empty set
/// when the list is invalid, and whether it holds an exact `*`.
///
/// The set matches a name ignoring ASCII case. The tokens that are known header names are kept as `HTTPHeaderName`s, so
/// that a common header is matched by its name; any other name is matched against the list's tokens, whose extents are
/// kept in list order.
private struct ResourceResponseExposedHeaders: ~Copyable {
    var commonNames = ResourceResponseHeaderNameSet()
    var exposesStar = false
    /// The first tokens' extents, and any past them in `heapTokens`.
    var stackTokens = ResourceResponseExposedTokensStackBuffer(repeating: 0..<0)
    var stackTokenCount = 0
    var heapTokens = UniqueArray<Range<Int>>()

    mutating func appendToken(_ token: Range<Int>) {
        if stackTokenCount < stackTokens.count {
            var tokens = stackTokens.mutableSpan
            tokens[stackTokenCount] = token
            stackTokenCount += 1
        } else {
            heapTokens.append(token)
        }
    }

    /// Whether the set holds `name`, an uncommon header's name, which no header name lookup needs: the tokens are
    /// matched as they are.
    func containsUncommonName<CodeUnit: HTTPHeaderStringCodeUnit>(_ name: borrowing WTF.String, _ list: Span<CodeUnit>) -> Bool {
        if stackTokenCount == 0 {
            return false
        }
        let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
        if !bytes.isEmpty {
            return containsToken(list, bytes)
        }
        let units: Span<UInt16> = name.checkedSpan16()
        return containsToken(list, units)
    }

    /// Whether a token of `list` equals `name` ignoring ASCII case.
    private func containsToken<CodeUnit: HTTPHeaderStringCodeUnit, NameCodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ list: Span<CodeUnit>,
        _ name: Span<NameCodeUnit>
    ) -> Bool {
        let tokens = stackTokens.span.extracting(0..<stackTokenCount)
        for index in tokens.indices {
            if crossOriginAccessControlEqualsIgnoringASCIICase(list.extracting(tokens[index]), name) {
                return true
            }
        }
        let moreTokens = heapTokens.span
        for index in moreTokens.indices {
            if crossOriginAccessControlEqualsIgnoringASCIICase(list.extracting(moreTokens[index]), name) {
                return true
            }
        }
        return false
    }
}

// The extents of an Access-Control-Expose-Headers list's first tokens are kept on the stack, and any past them on the heap.
private typealias ResourceResponseExposedTokensStackBuffer = InlineArray<8, Range<Int>>

/// A set of `HTTPHeaderName`s, one bit for each.
///
/// ResourceResponseBase.cpp asserts that every name's value is below 128.
private struct ResourceResponseHeaderNameSet {
    var low: UInt64 = 0
    var high: UInt64 = 0

    mutating func insert(_ name: WebCore.HTTPHeaderName) {
        let value = UInt64(name.rawValue)
        // A shift by the value's low six bits, in the word its seventh bit picks.
        if value < 64 {
            low |= 1 &<< value
        } else {
            high |= 1 &<< value
        }
    }

    /// Adds `name` when `isIncluded`, with no branch on either.
    mutating func insert(_ name: WebCore.HTTPHeaderName, if isIncluded: Bool) {
        let value = UInt64(name.rawValue)
        // A shift by the value's low six bits.
        let bit = UInt64(isIncluded ? 1 : 0) &<< value
        let isHigh = value >> 6
        // All ones for the word the value's seventh bit picks, by wrapping below zero, and zero for the other.
        low |= bit & (isHigh &- 1)
        high |= bit & (0 &- isHigh)
    }

    func contains(_ name: WebCore.HTTPHeaderName) -> Bool {
        let value = UInt64(name.rawValue)
        // A shift by the value's low six bits, of the word its seventh bit picks.
        return ((value < 64 ? low : high) &>> value) & 1 != 0
    }
}

private func resourceResponseExposedHeaders<CodeUnit: HTTPHeaderStringCodeUnit>(_ list: Span<CodeUnit>) -> ResourceResponseExposedHeaders {
    var exposedHeaders = ResourceResponseExposedHeaders()
    var cursor = 0
    while true {
        switch AccessControlAllowListParsing.nextToken(list, from: cursor) {
        case .token(let start, let length, let next):
            // A token lies within the list.
            let extent = start..<(start &+ length)
            let token = list.extracting(extent)
            if token.count == 1 && HTTPHeaderCodeUnits.value(token[0]) == 0x2A {
                exposedHeaders.exposesStar = true
            }
            // What `HTTPHeaderName headerName { }` holds; findHTTPHeaderName() writes it only when it finds the name.
            var headerName = WebCore.HTTPHeaderName.Accept
            if WebCore.securityPoliciesFindHTTPHeaderName(CodeUnit.httpHeaderString(token), &headerName) {
                exposedHeaders.commonNames.insert(headerName)
            }
            exposedHeaders.appendToken(extent)
            cursor = next
        case .end:
            return exposedHeaders
        case .invalid:
            return ResourceResponseExposedHeaders()
        }
    }
}

/// WebCore keeps location and cache related headers, as it does caching.
///
/// It also keeps the CORS and Referrer-Policy headers until the CORS checks and the referrer computation are done in
/// the network process.
private func isSafeRedirectionResponseHeader(_ name: WebCore.HTTPHeaderName) -> Bool {
    switch name {
    case .Location,
        .ReferrerPolicy,
        .CacheControl,
        .Date,
        .Expires,
        .ETag,
        .LastModified,
        .Age,
        .Pragma,
        .Refresh,
        .Vary,
        .CrossOriginOpenerPolicy,
        .CrossOriginOpenerPolicyReportOnly,
        .CrossOriginEmbedderPolicy,
        .CrossOriginEmbedderPolicyReportOnly,
        .AccessControlAllowCredentials,
        .AccessControlAllowHeaders,
        .AccessControlAllowMethods,
        .AccessControlAllowOrigin,
        .AccessControlExposeHeaders,
        .AccessControlMaxAge,
        .CrossOriginResourcePolicy,
        .TimingAllowOrigin:
        true
    default:
        false
    }
}

/// All known response headers used in web processes.
private func isSafeCrossOriginResponseHeader(_ name: WebCore.HTTPHeaderName) -> Bool {
    switch name {
    case .AcceptRanges,
        .AccessControlAllowCredentials,
        .AccessControlAllowHeaders,
        .AccessControlAllowMethods,
        .AccessControlAllowOrigin,
        .AccessControlExposeHeaders,
        .AccessControlMaxAge,
        .AccessControlRequestHeaders,
        .AccessControlRequestMethod,
        .Age,
        .CacheControl,
        .ContentDisposition,
        .ContentEncoding,
        .ContentLanguage,
        .ContentLength,
        .ContentRange,
        .ContentSecurityPolicy,
        .ContentSecurityPolicyReportOnly,
        .ContentType,
        .CrossOriginResourcePolicy,
        .Date,
        .ETag,
        .Expires,
        .IcyMetaInt,
        .IcyMetadata,
        .LastEventID,
        .LastModified,
        .Link,
        .Location,
        .Pragma,
        .Range,
        .ReferrerPolicy,
        .Refresh,
        .ServerTiming,
        .SourceMap,
        .XSourceMap,
        .TimingAllowOrigin,
        .Trailer,
        .Vary,
        .XContentTypeOptions,
        .XFrameOptions,
        .XXSSProtection:
        true
    default:
        false
    }
}

/// `containsInvalidHTTPHeaders()`: whether a value of `headers`, trimmed of HTTP whitespace, is not a valid header
/// value.
///
/// Common headers are checked first.
///
/// `headers` is the response's own map, which `containsInvalidHTTPHeaders()` passes from `httpHeaderFields()` by
/// reference, a `const` member. While it is borrowed this reads it only through `commonHeadersSpan()` and
/// `uncommonHeadersSpan()`, and calls nothing that changes it or reaches the response.
@_expose(Cxx)
func resourceResponseContainsInvalidHTTPHeaders(_ headers: borrowing WebCore.HTTPHeaderMap) -> Bool {
    let commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader> = headers.commonHeadersSpan()
    for index in commonHeaders.indices {
        if !isValidTrimmedHTTPHeaderValue(commonHeaders[index].value) {
            return true
        }
    }
    let uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader> = headers.uncommonHeadersSpan()
    for index in uncommonHeaders.indices {
        if !isValidTrimmedHTTPHeaderValue(uncommonHeaders[index].value) {
            return true
        }
    }
    return false
}

private func isValidTrimmedHTTPHeaderValue(_ value: borrowing WTF.String) -> Bool {
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
    if !bytes.isEmpty {
        return isValidTrimmedHTTPHeaderValue(bytes)
    }
    let units: Span<UInt16> = value.checkedSpan16()
    return isValidTrimmedHTTPHeaderValue(units)
}

private func isValidTrimmedHTTPHeaderValue<CodeUnit: HTTPHeaderStringCodeUnit>(_ value: Span<CodeUnit>) -> Bool {
    let trimmed = HTTPHeaderCodeUnits.trim(value, value.indices, HTTPHeaderCodeUnits.isASCIIWhitespaceWithoutFF)
    return HTTPHeaderValueValidation.isValidHTTPHeaderValue(value.extracting(trimmed))
}

// MARK: Parsed header fields

/// The `Date`, `Expires` or `Last-Modified` value `ResourceResponseBase` caches: empty for an empty value or one
/// `parseHTTPDate()` does not parse.
///
/// It parses the date formats RFC 2616 requires: RFC 1123's (`Sun, 06 Nov 1994 08:49:37 GMT`), RFC 850's
/// (`Sunday, 06-Nov-94 08:49:37 GMT`) and asctime()'s (`Sun Nov  6 08:49:37 1994`).
@_expose(Cxx)
func parseDateValueInHeader(_ value: consuming WTF.String) -> WebCore.SecurityPoliciesMarkableWallTime {
    if value.isEmpty() {
        return WebCore.SecurityPoliciesMarkableWallTime()
    }
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
    let milliseconds: Double
    if !bytes.isEmpty {
        milliseconds = parseHTTPDateBody(bytes)
    } else {
        let units: Span<UInt16> = value.checkedSpan16()
        milliseconds = parseHTTPDateBody(units)
    }
    guard milliseconds.isFinite else {
        return WebCore.SecurityPoliciesMarkableWallTime()
    }
    return WebCore.SecurityPoliciesMarkableWallTime(WTF.WallTime.fromSecondsSinceEpoch(WTF.Seconds(milliseconds / 1000.0)))
}

/// The `Age` value `ResourceResponseBase::age()` caches. `age` changes only when `value` parses as `String::toDouble()`
/// parses it, so a value that does not parse leaves the previous one.
@_expose(Cxx)
func parseAgeValueInHeader(_ value: consuming WTF.String, _ age: inout WebCore.SecurityPoliciesMarkableSeconds) {
    if value.isEmpty() {
        return
    }
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
    let number: (value: Double, isWhole: Bool)?
    if !bytes.isEmpty {
        number = httpHeaderToDouble(bytes)
    } else {
        let units: Span<UInt16> = value.checkedSpan16()
        number = httpHeaderToDouble(units)
    }
    guard let number, number.isWhole else {
        return
    }
    age = WebCore.SecurityPoliciesMarkableSeconds(WTF.Seconds(number.value))
}

/// The `Content-Range` value `ResourceResponseBase::contentRange()` caches: an invalid range for an empty value.
@_expose(Cxx)
func parseContentRangeInHeader(_ value: consuming WTF.String) -> WebCore.ParsedContentRange {
    if value.isEmpty() {
        return WebCore.ParsedContentRange()
    }
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
    if !bytes.isEmpty {
        return parseContentRangeBody(bytes)
    }
    let units: Span<UInt16> = value.checkedSpan16()
    return parseContentRangeBody(units)
}

/// `isAttachment()`: whether the `Content-Disposition` value's type, before its first `;` and trimmed of whitespace,
/// is `attachment`, ignoring ASCII case.
@_expose(Cxx)
func resourceResponseIsAttachment(_ contentDisposition: consuming WTF.String) -> Bool {
    if contentDisposition.isEmpty() {
        return false
    }
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(contentDisposition)
    if !bytes.isEmpty {
        return isAttachmentDisposition(bytes)
    }
    let units: Span<UInt16> = contentDisposition.checkedSpan16()
    return isAttachmentDisposition(units)
}

/// `isAttachmentWithFilename()`: whether the `Content-Disposition` value is an attachment with a filename.
@_expose(Cxx)
func resourceResponseIsAttachmentWithFilename(_ contentDisposition: consuming WTF.String) -> Bool {
    if contentDisposition.isEmpty() {
        return false
    }
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(contentDisposition)
    if !bytes.isEmpty {
        return isAttachmentDispositionWithFilename(bytes)
    }
    let units: Span<UInt16> = contentDisposition.checkedSpan16()
    return isAttachmentDispositionWithFilename(units)
}

private func isAttachmentDisposition<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ value: Span<CodeUnit>) -> Bool {
    let typeEnd = HTTPHeaderCodeUnits.find(0x3B, in: value, from: 0)
    let type = HTTPHeaderCodeUnits.trim(value, 0..<typeEnd, HTTPHeaderCodeUnits.isUnicodeCompatibleASCIIWhitespace)
    // "attachment"
    let attachment: [10 of UInt8] = [0x61, 0x74, 0x74, 0x61, 0x63, 0x68, 0x6D, 0x65, 0x6E, 0x74]
    return HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(value.extracting(type), attachment.span)
}

private func isAttachmentDispositionWithFilename<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ value: Span<CodeUnit>) -> Bool {
    isAttachmentDisposition(value) && httpContentDispositionFilenameExtent(value) != nil
}
