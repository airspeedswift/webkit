// Copyright (C) 2014-2017 Apple Inc. All rights reserved.
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
internal import WebCore_Private.Core.CacheValidation
internal import WebCore_Private.Core.ResourceResponse
internal import WebCore_Private.Core.ResourceResponseBase
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import wtf.Core.Function
internal import wtf.Core.Markable
internal import wtf.Core.Seconds
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.Vector
internal import wtf.Core.WallTime
internal import wtf.Core.text.WTFString

extension WebCore {
    /// Whether a response with `statusCode` is cacheable by default (http://tools.ietf.org/html/rfc7231#page-48).
    @cxx
    @implementation
    public static func isStatusCodeCacheableByDefault(_ statusCode: Int32) -> Bool {
        switch statusCode {
        case 200, // OK
            203, // Non-Authoritative Information
            204, // No Content
            206, // Partial Content
            300, // Multiple Choices
            301, // Moved Permanently
            404, // Not Found
            405, // Method Not Allowed
            410, // Gone
            414, // URI Too Long
            501: // Not Implemented
            return true
        default:
            return false
        }
    }

    /// Whether a redirect chain with the cache status `redirectChainCacheStatus` allows reuse, an expired one only with
    /// `reuseExpiredRedirection`.
    @cxx
    @implementation
    public static func redirectChainAllowsReuse(
        _ redirectChainCacheStatus: WebCore.RedirectChainCacheStatus,
        _ reuseExpiredRedirection: WebCore.ReuseExpiredRedirectionOrNot
    ) -> Bool {
        switch redirectChainCacheStatus.status {
        case .NoRedirection:
            return true
        case .NotCachedRedirection:
            return false
        case .CachedRedirection:
            return reuseExpiredRedirection.rawValue != 0
                || WTF.WallTime.now().secondsSinceEpoch().value() <= redirectChainCacheStatus.endOfValidity.secondsSinceEpoch().value()
        default:
            assertionFailure()
            return false
        }
    }
}

// MARK: Freshness and age

/// `computeFreshnessLifetimeForHTTPFamily()` (http://tools.ietf.org/html/rfc7234#section-4.2.1).
///
/// `response` is the caller's response, passed by `const` reference. While it is borrowed this calls only its
/// `isInHTTPFamily()`, `cacheControlMaxAge()`, `date()`, `expires()`, then cacheResponseHasExpiresHeader() on it, then
/// its `httpStatusCode()` and `lastModified()`, in that order and only where the result is needed; they write nothing
/// but the response's own cache of parsed header values and the fields `lazyInit()` fills from its platform response,
/// and none of them runs script or reaches the response another way.
@_expose(Cxx)
func cacheFreshnessLifetime(_ response: borrowing WebCore.ResourceResponse, _ responseTimestamp: WTF.WallTime) -> WTF.Seconds {
    if !response.isInHTTPFamily() {
        return WTF.Seconds(0)
    }

    if let maxAge = Optional(fromCxx: response.cacheControlMaxAge()) {
        return maxAge
    }

    let effectiveDate = (Optional(fromCxx: response.date()) ?? responseTimestamp).secondsSinceEpoch().value()
    if let expires = Optional(fromCxx: response.expires()) {
        return WTF.Seconds(expires.secondsSinceEpoch().value() - effectiveDate)
    }

    // An Expires header that is present but invalid.
    if WebCore.cacheResponseHasExpiresHeader(response) {
        return WTF.Seconds(0)
    }

    // Implicit lifetime.
    switch response.httpStatusCode() {
    case 301, // Moved Permanently
        410: // Gone
        // These are semantically permanent and so get a long implicit lifetime.
        return WTF.Seconds(24 * 60 * 60 * 365)
    default:
        // Heuristic freshness: http://tools.ietf.org/html/rfc7234#section-4.2.2
        if let lastModified = Optional(fromCxx: response.lastModified()) {
            return WTF.Seconds((effectiveDate - lastModified.secondsSinceEpoch().value()) * 0.1)
        }
        return WTF.Seconds(0)
    }
}

/// `computeCurrentAge()` (http://tools.ietf.org/html/rfc7234#section-4.2.3), with no compensation for latency, from
/// the response's `date()` and `age()`.
@_expose(Cxx)
func cacheCurrentAge(
    _ date: WebCore.SecurityPoliciesOptionalWallTime,
    _ age: WebCore.SecurityPoliciesOptionalSeconds,
    _ responseTimestamp: WTF.WallTime
) -> WTF.Seconds {
    cacheCurrentAgeValue(Optional(fromCxx: date), Optional(fromCxx: age), responseTimestamp)
}

private func cacheCurrentAgeValue(_ date: WTF.WallTime?, _ age: WTF.Seconds?, _ responseTimestamp: WTF.WallTime) -> WTF.Seconds {
    let responseTime = responseTimestamp.secondsSinceEpoch().value()
    // std::max(a, b) is (a < b) ? b : a, which keeps the first of two zeros.
    var apparentAge = 0.0
    if let date {
        let sinceDate = responseTime - date.secondsSinceEpoch().value()
        apparentAge = 0.0 < sinceDate ? sinceDate : 0.0
    }
    let ageValue = age?.value() ?? 0.0
    let correctedInitialAge = apparentAge < ageValue ? ageValue : apparentAge
    let residentTime = WTF.WallTime.now().secondsSinceEpoch().value() - responseTime
    return WTF.Seconds(correctedInitialAge + residentTime)
}

/// `updateRedirectChainStatus()`. `isPrefetch` is whether the load's caching policy allows caching a main resource
/// prefetch.
///
/// `status` is the caller's `RedirectChainCacheStatus`, plain data. `response` is the caller's response, passed by
/// `const` reference. While it is borrowed this calls only its `cacheControlContainsNoStore()`,
/// `cacheControlContainsNoCache()` and `cacheControlContainsMustRevalidate()`, then cacheFreshnessLifetime()'s calls,
/// `date()` and `age()`, in that order and only where the result is needed; they write nothing but the response's own
/// cache of parsed header values and the fields `lazyInit()` fills from its platform response, and none of them runs
/// script or reaches the response another way.
@_expose(Cxx)
func updateCacheRedirectChainStatus(
    _ status: inout WebCore.RedirectChainCacheStatus,
    _ response: borrowing WebCore.ResourceResponse,
    _ isPrefetch: Bool
) {
    if status.status == .NotCachedRedirection {
        return
    }
    if !isPrefetch, cacheControlContainsNoStoreNoCacheOrMustRevalidate(response) {
        status.status = .NotCachedRedirection
        return
    }

    status.status = .CachedRedirection
    let responseTimestamp = WTF.WallTime.now()
    // Store the nearest end of cache validity date.
    let freshnessLifetime = cacheFreshnessLifetime(response, responseTimestamp).value()
    let currentAge = cacheCurrentAgeValue(Optional(fromCxx: response.date()), Optional(fromCxx: response.age()), responseTimestamp).value()
    let endOfValidity = responseTimestamp.secondsSinceEpoch().value() + freshnessLifetime - currentAge
    // std::min(a, b) is (b < a) ? b : a.
    if endOfValidity < status.endOfValidity.secondsSinceEpoch().value() {
        status.endOfValidity = WTF.WallTime.fromSecondsSinceEpoch(WTF.Seconds(endOfValidity))
    }
}

/// `cacheControlContainsNoStore() || cacheControlContainsNoCache() || cacheControlContainsMustRevalidate()`.
private func cacheControlContainsNoStoreNoCacheOrMustRevalidate(_ response: borrowing WebCore.ResourceResponse) -> Bool {
    if response.cacheControlContainsNoStore() {
        return true
    }
    if response.cacheControlContainsNoCache() {
        return true
    }
    return response.cacheControlContainsMustRevalidate()
}

// MARK: Cache-Control and Pragma

/// `parseCacheControlDirectives()`: the directives of a `Cache-Control` value, parsed with its control characters and
/// spaces removed, and `noCache` also from a `Pragma` value containing `no-cache`, which is deprecated and equivalent
/// to `Cache-Control: no-cache`.
///
/// Pragma is not tokenized; handling it exactly right is not important.
@_expose(Cxx)
func cacheControlDirectives(_ cacheControl: consuming WTF.String, _ pragma: consuming WTF.String) -> WebCore.CacheControlDirectives {
    var directives = HTTPCacheControlDirectiveValues()
    if !cacheControl.isEmpty() {
        let cacheControlBytes: Span<UInt8> = WebCore.securityPoliciesSpan8(cacheControl)
        if !cacheControlBytes.isEmpty {
            directives = cacheControlDirectiveValuesWithoutControlCharacters(cacheControlBytes)
        } else {
            let cacheControlUnits: Span<UInt16> = cacheControl.checkedSpan16()
            directives = cacheControlDirectiveValuesWithoutControlCharacters(cacheControlUnits)
        }
    }

    if !directives.noCache && !pragma.isEmpty() {
        let pragmaBytes: Span<UInt8> = WebCore.securityPoliciesSpan8(pragma)
        if !pragmaBytes.isEmpty {
            directives.noCache = containsNoCacheIgnoringASCIICase(pragmaBytes)
        } else {
            let pragmaUnits: Span<UInt16> = pragma.checkedSpan16()
            directives.noCache = containsNoCacheIgnoringASCIICase(pragmaUnits)
        }
    }

    return cacheControlDirectivesFromValues(directives)
}

// A Cache-Control value without its control characters and spaces, of at most this many code units, is put together on
// the stack, and a longer one in an Array.
private typealias CacheControlStackBuffer<CodeUnit> = InlineArray<64, CodeUnit>

/// String::removeCharacters() of the control characters and spaces, in the value's width, then the parse.
private func cacheControlDirectiveValuesWithoutControlCharacters<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ value: Span<CodeUnit>
) -> HTTPCacheControlDirectiveValues {
    var index = 0
    while index < value.count && !isControlCharacterOrSpace(value[index]) {
        // Below the count.
        index &+= 1
    }
    if index == value.count {
        return httpCacheControlDirectiveValues(value)
    }
    // The value has at least one character to remove.
    let count = value.count &- 1
    if count <= CacheControlStackBuffer<CodeUnit>.count {
        var buffer = CacheControlStackBuffer<CodeUnit>(repeating: 0)
        var output = buffer.mutableSpan
        let safeCount = removeControlCharactersAndSpaces(value, from: index, into: &output)
        return httpCacheControlDirectiveValues(buffer.span.extracting(0..<safeCount))
    }
    var safeHeader = [CodeUnit](repeating: 0, count: count)
    var output = safeHeader.mutableSpan
    let safeCount = removeControlCharactersAndSpaces(value, from: index, into: &output)
    return httpCacheControlDirectiveValues(safeHeader.span.extracting(0..<safeCount))
}

// Writes the code units of `value` that are not control characters or spaces to the start of `output`, which has room
// for all but one of them, and returns how many there are. `firstRemoved` is the first one that is.
private func removeControlCharactersAndSpaces<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ value: Span<CodeUnit>,
    from firstRemoved: Int,
    into output: inout MutableSpan<CodeUnit>
) -> Int {
    for position in 0..<firstRemoved {
        output[position] = value[position]
    }
    var count = firstRemoved
    // firstRemoved is below the value's count.
    for position in (firstRemoved &+ 1)..<value.count where !isControlCharacterOrSpace(value[position]) {
        output[count] = value[position]
        // Below the position, which is below the value's count.
        count &+= 1
    }
    return count
}

@inline(always)
private func isControlCharacterOrSpace<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ character: CodeUnit) -> Bool {
    let c = HTTPHeaderCodeUnits.value(character)
    return c <= 0x20 || c == 0x7F
}

/// `String::containsIgnoringASCIICase("no-cache")`.
private func containsNoCacheIgnoringASCIICase<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ value: Span<CodeUnit>) -> Bool {
    let noCache = cacheControlNoCache.span
    if value.count < noCache.count {
        return false
    }
    // The value is at least as long as "no-cache", so each window lies within it.
    for start in 0...(value.count &- noCache.count) {
        if HTTPHeaderCodeUnits.equalIgnoringASCIICase(value.extracting(start..<(start &+ noCache.count)), noCache) {
            return true
        }
    }
    return false
}

private let cacheControlNoCache: [UInt8] = Array("no-cache".utf8)

// MARK: Vary

/// `verifyVaryingRequestHeaders()`: whether each varying request header's stored value equals the value `headerValue`
/// gives for its name, the null string unequal to the empty one.
///
/// `Vary: *` never matches; ideally it would trigger a cache delete instead of a store.
///
/// `headers` is the caller's list (`CachedResource`'s varying header values, or a network cache entry's), passed by
/// `const` reference, and `headerValue` the caller's function, also by reference. While they are borrowed this calls
/// only the list's `size()` and subscript, which copies each pair out before `headerValue` runs, `headerValue`, whose
/// cookie jar query may be a synchronous message to another process, and String functions; none of them changes the
/// list or reassigns the function.
@_expose(Cxx)
func cacheVaryingRequestHeadersMatch(
    _ headers: borrowing WebCore.SecurityPoliciesVaryingHeaders,
    _ headerValue: borrowing WebCore.SecurityPoliciesHeaderValueFunction
) -> Bool {
    for index in 0..<headers.size() {
        let varyingRequestHeader = headers[index]
        if isVaryStar(varyingRequestHeader.first) {
            return false
        }
        if !stringsAreEqual(headerValue(varyingRequestHeader.first), varyingRequestHeader.second) {
            return false
        }
    }
    return true
}

/// `name == "*"_s`.
private func isVaryStar(_ name: borrowing WTF.String) -> Bool {
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    if !bytes.isEmpty {
        return bytes.count == 1 && bytes[0] == 0x2A
    }
    let units: Span<UInt16> = name.checkedSpan16()
    return units.count == 1 && units[0] == 0x2A
}

/// WTF's `String` `==`: the same code units, and both null or neither.
private func stringsAreEqual(_ a: borrowing WTF.String, _ b: borrowing WTF.String) -> Bool {
    if a.isNull() {
        return b.isNull()
    }
    if b.isNull() {
        return false
    }
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(a)
    if !bytes.isEmpty {
        return crossOriginAccessControlEquals(bytes, b)
    }
    let units: Span<UInt16> = a.checkedSpan16()
    return crossOriginAccessControlEquals(units, b)
}

// MARK: Revalidation

/// Whether a header of a revalidated (304) response is copied to the cached response.
///
/// Entity headers should not be sent in a 304 response, though misconfigured servers send them; these, and the ones
/// under the prefixes below, are not copied. For compatibility, both lists are based on Chromium's
/// net/http/http_response_headers.cc.
@_expose(Cxx)
func shouldUpdateHeaderAfterRevalidation(_ header: consuming WTF.String) -> Bool {
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(header)
    if !bytes.isEmpty {
        return headerShouldUpdateAfterRevalidation(bytes)
    }
    let units: Span<UInt16> = header.checkedSpan16()
    return headerShouldUpdateAfterRevalidation(units)
}

private func headerShouldUpdateAfterRevalidation<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ header: Span<CodeUnit>) -> Bool {
    if startsWithIgnoringASCIICase(header, headerPrefixToUpdateAfterRevalidation.span) {
        return true
    }
    for name in headersToIgnoreAfterRevalidation {
        if HTTPHeaderCodeUnits.equalIgnoringASCIICase(header, name.span) {
            return false
        }
    }
    for prefix in headerPrefixesToIgnoreAfterRevalidation {
        if startsWithIgnoringASCIICase(header, prefix.span) {
            return false
        }
    }
    return true
}

private func startsWithIgnoringASCIICase<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ prefix: Span<UInt8>
) -> Bool {
    characters.count >= prefix.count && HTTPHeaderCodeUnits.equalIgnoringASCIICase(characters.extracting(0..<prefix.count), prefix)
}

private let headerPrefixToUpdateAfterRevalidation: [UInt8] = Array("content-security-".utf8)

private let headersToIgnoreAfterRevalidation: [[UInt8]] = [
    Array("allow".utf8),
    Array("connection".utf8),
    Array("content-disposition".utf8),
    Array("content-encoding".utf8),
    Array("content-language".utf8),
    Array("content-length".utf8),
    Array("content-location".utf8),
    Array("content-range".utf8),
    Array("content-type".utf8),
    Array("etag".utf8),
    Array("keep-alive".utf8),
    Array("last-modified".utf8),
    Array("proxy-authenticate".utf8),
    Array("proxy-connection".utf8),
    Array("trailer".utf8),
    Array("transfer-encoding".utf8),
    Array("upgrade".utf8),
    Array("www-authenticate".utf8),
    Array("x-frame-options".utf8),
    Array("x-xss-protection".utf8),
]

/// Some header prefixes mean "Don't copy this header from a 304 response"; they stand for all the headers under them.
private let headerPrefixesToIgnoreAfterRevalidation: [[UInt8]] = [
    Array("x-content-".utf8),
    Array("x-webkit-".utf8),
]

// The C++ directives that `directives` give. A new CacheControlDirectives has every flag false and no value, so only
// the flags that are true and the values that are present are set.
private func cacheControlDirectivesFromValues(_ directives: HTTPCacheControlDirectiveValues) -> WebCore.CacheControlDirectives {
    var result = WebCore.CacheControlDirectives()
    if directives.noCache {
        result.noCache = true
    }
    if directives.noStore {
        result.noStore = true
    }
    if directives.isPublic {
        result.isPublic = true
    }
    if directives.mustRevalidate {
        result.mustRevalidate = true
    }
    if directives.immutable {
        result.immutable = true
    }
    if let maxAge = directives.maxAge {
        result.maxAge = .init(WTF.Seconds(maxAge))
    }
    switch directives.maxStale {
    case .none:
        break
    case .infinity:
        result.maxStale = .init(WTF.Seconds.infinity())
    case .value(let maxStale):
        result.maxStale = .init(WTF.Seconds(maxStale))
    }
    if let minFresh = directives.minFresh {
        result.minFresh = .init(WTF.Seconds(minFresh))
    }
    if let staleWhileRevalidate = directives.staleWhileRevalidate {
        result.staleWhileRevalidate = .init(WTF.Seconds(staleWhileRevalidate))
    }
    return result
}

// Cache-Control: the header's directives and their values, for parseCacheControlDirectives.

enum HTTPCacheControlMaxStale: Equatable {
    case none
    /// max-stale without a value: Seconds::infinity().
    case infinity
    /// The first max-stale value that `StringView::toDouble` parses.
    case value(Double)
}

/// The directives, over the Cache-Control value once its control characters and spaces are removed. Each number is the
/// first value of its directive that `StringView::toDouble` parses, nil when none does. The Pragma fallback for
/// `noCache` is the caller's.
struct HTTPCacheControlDirectiveValues: Equatable {
    var noCache = false
    var noStore = false
    var isPublic = false
    var mustRevalidate = false
    var immutable = false
    var maxAge: Double?
    var maxStale = HTTPCacheControlMaxStale.none
    var minFresh: Double?
    var staleWhileRevalidate: Double?
}

func httpCacheControlDirectiveValues<CodeUnit: HTTPHeaderStringCodeUnit>(_ safeHeader: Span<CodeUnit>) -> HTTPCacheControlDirectiveValues {
    // Positions here are at most `max`: wrapping arithmetic cannot wrap.
    var result = HTTPCacheControlDirectiveValues()
    let max = safeHeader.count
    var position = 0
    let noValue = HTTPHeaderSubstringExtent(start: max, length: 0)
    while position < max {
        // The directive ends at its first separator. ',' and '=' are separators, so the first ',' or '=' is there or
        // after it.
        let directive = trimToNextCacheHeaderSeparator(safeHeader, HTTPHeaderSubstringExtent(start: position, length: max &- position))
        let next = findCacheHeaderCommaOrEqualSign(safeHeader, from: directive.end)
        if next == max {
            // The last directive, with an empty value.
            applyCacheControlDirective(&result, safeHeader, directive, noValue)
            return result
        }
        position = next &+ 1
        if HTTPHeaderCodeUnits.value(safeHeader[next]) == 0x2C {
            // A directive with an empty value.
            applyCacheControlDirective(&result, safeHeader, directive, noValue)
            continue
        }
        if position < max && HTTPHeaderCodeUnits.value(safeHeader[position]) == 0x22 {
            // A quoted string.
            guard let nextDoubleQuote = findCacheHeaderCharacter(safeHeader, 0x22, from: position + 1) else {
                // Unterminated: the rest, to the next separator.
                applyCacheControlDirective(
                    &result,
                    safeHeader,
                    directive,
                    trimToNextCacheHeaderSeparator(safeHeader, HTTPHeaderSubstringExtent(start: position + 1, length: max - (position + 1)))
                )
                return result
            }
            // Without its quotes.
            applyCacheControlDirective(
                &result,
                safeHeader,
                directive,
                HTTPHeaderSubstringExtent(start: position + 1, length: nextDoubleQuote - (position + 1))
            )
            position = nextDoubleQuote + 1
            // Past the next comma; anything left with no comma is ignored.
            guard let nextComma = findCacheHeaderCharacter(safeHeader, 0x2C, from: position) else {
                return result
            }
            position = nextComma + 1
            continue
        }
        // A token, up to the next comma, which is at its first separator or after it.
        let value = trimToNextCacheHeaderSeparator(safeHeader, HTTPHeaderSubstringExtent(start: position, length: max &- position))
        applyCacheControlDirective(&result, safeHeader, directive, value)
        guard let nextComma = findCacheHeaderCharacter(safeHeader, 0x2C, from: value.end) else {
            return result
        }
        position = nextComma + 1
    }
    return result
}

private func applyCacheControlDirective<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ result: inout HTTPCacheControlDirectiveValues,
    _ header: Span<CodeUnit>,
    _ directive: HTTPHeaderSubstringExtent,
    _ value: HTTPHeaderSubstringExtent
) {
    guard directive.length > 0 else {
        return
    }
    // The directives with this length and first letter, in either case: no-cache and no-store share both, as do
    // max-stale and min-fresh.
    switch directive.length << 8 | Int(HTTPHeaderCodeUnits.value(header[directive.start]) | 0x20) {
    case 6 << 8 | 0x70: // 'p'
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "public") {
            result.isPublic = true
        }
    case 7 << 8 | 0x6D: // 'm'
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "max-age") && result.maxAge == nil {
            result.maxAge = wholeDouble(header, value)
        }
    case 8 << 8 | 0x6E: // 'n'
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "no-cache") {
            // A no-cache directive with a value is only meaningful for proxy caches.
            if value.length == 0 {
                result.noCache = true
            }
        } else if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "no-store") {
            result.noStore = true
        }
    case 9 << 8 | 0x69: // 'i'
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "immutable") {
            result.immutable = true
        }
    case 9 << 8 | 0x6D: // 'm'
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "max-stale") {
            if result.maxStale != .none {
                return
            }
            if value.length == 0 {
                result.maxStale = .infinity
            } else if let maxStale = wholeDouble(header, value) {
                result.maxStale = .value(maxStale)
            }
        } else if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "min-fresh") && result.minFresh == nil {
            result.minFresh = wholeDouble(header, value)
        }
    case 15 << 8 | 0x6D: // 'm'
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "must-revalidate") {
            result.mustRevalidate = true
        }
    case 22 << 8 | 0x73: // 's'
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(header, directive, "stale-while-revalidate")
            && result.staleWhileRevalidate == nil
        {
            result.staleWhileRevalidate = wholeDouble(header, value)
        }
    default:
        break
    }
}

/// `StringView::toDouble(bool&)` of the value: the number when it takes every character after the leading whitespace.
private func wholeDouble<CodeUnit: HTTPHeaderStringCodeUnit>(_ header: Span<CodeUnit>, _ value: HTTPHeaderSubstringExtent) -> Double? {
    guard let number = httpHeaderToDouble(header.extracting(value.start..<value.end)), number.isWhole else {
        return nil
    }
    return number.value
}

private func findCacheHeaderCharacter<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ header: Span<CodeUnit>,
    _ character: UInt32,
    from start: Int
) -> Int? {
    var index = start
    while index < header.count {
        if HTTPHeaderCodeUnits.value(header[index]) == character {
            return index
        }
        index += 1
    }
    return nil
}

/// The index of the first ',' or '=' at or after `start`, or the count when there is none.
private func findCacheHeaderCommaOrEqualSign<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ header: Span<CodeUnit>,
    from start: Int
) -> Int {
    var index = start
    while index < header.count {
        let c = HTTPHeaderCodeUnits.value(header[index])
        if c == 0x2C || c == 0x3D {
            return index
        }
        index += 1
    }
    return index
}

/// The view up to its first separator.
private func trimToNextCacheHeaderSeparator<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ header: Span<CodeUnit>,
    _ view: HTTPHeaderSubstringExtent
) -> HTTPHeaderSubstringExtent {
    HTTPHeaderCodeUnits.extent(upToFirstOf: HTTPCacheHeaderSeparators.self, in: header, from: view.start, to: view.end)
}

/// RFC 7230's separators (section 3.2.6): the delimiters, space and tab.
private enum HTTPCacheHeaderSeparators: HTTPHeaderCharacterClass {
    /// Bit `c` of a 128-bit mask of tab, space and `"(),/:;<=>?@[\]{}`, whose first word holds 0x00 to 0x3F and second
    /// 0x40 to 0x7F.
    @inline(always)
    static func contains(_ c: UInt32) -> Bool {
        let word: UInt64 = c < 0x40 ? 0xFC00_9305_0000_0200 : 0x2800_0000_3800_0001
        return c < 0x80 && (word &>> UInt64(c & 0x3F)) & 1 != 0
    }

    @inline(always)
    static func lanes(in codeUnits: SIMD16<UInt8>) -> SIMD16<UInt8> {
        HTTPHeaderLanes.delimiters(codeUnits) | HTTPHeaderLanes.equal(codeUnits, 0x20) | HTTPHeaderLanes.equal(codeUnits, 0x09)
    }
}
