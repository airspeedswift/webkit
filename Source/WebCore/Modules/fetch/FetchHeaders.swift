// Copyright (C) 2016 Canon Inc.
// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted, provided that the following conditions
// are required to be met:
//
// 1.  Redistributions of source code must retain the above copyright
//     notice, this list of conditions and the following disclaimer.
// 2.  Redistributions in binary form must reproduce the above copyright
//     notice, this list of conditions and the following disclaimer in the
//     documentation and/or other materials provided with the distribution.
// 3.  Neither the name of Canon Inc. nor the names of
//     its contributors may be used to endorse or promote products derived
//     from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY CANON INC. AND ITS CONTRIBUTORS "AS IS" AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL CANON INC. AND ITS CONTRIBUTORS BE LIABLE FOR
// ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
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
internal import WebCore_Private.Core.Exception
internal import WebCore_Private.Core.ExceptionCode
internal import WebCore_Private.Core.FetchHeadersGuard
internal import WebCore_Private.Core.HTTPHeaderMap
internal import WebCore_Private.Core.HTTPHeaderNames
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

// MARK: - Headers: append, delete, set, get, has

/// `FetchHeaders::append()` after its update counter is raised: appends `value`, trimmed of HTTP whitespace, to the
/// header named `name` (https://fetch.spec.whatwg.org/#concept-headers-append), or to the Set-Cookie values.
/// `FetchHeaders::fill(const Init&)` and `create()` apply each pair of their init with it.
///
/// `headers` and `setCookieValues` are the `FetchHeaders`' `m_headers` and `m_setCookieValues`, passed by its member,
/// or `create()`'s two locals before the object exists. Only this function changes them during the call, through
/// their own members (`HTTPHeaderMap`'s `set()` and `remove()`, `Vector`'s `append()`; it reads the map with
/// `valueForName()`); the other C++ it calls (`findHTTPHeaderName()`, String functions) does not reach the
/// `FetchHeaders` or the init being read.
@_expose(Cxx)
func appendToHeaderMap(
    _ name: consuming WTF.String,
    _ value: consuming WTF.String,
    _ headers: inout WebCore.HTTPHeaderMap,
    _ setCookieValues: inout WebCore.SecurityPoliciesStringVector,
    _ headersGuard: WebCore.FetchHeadersGuard
) -> WebCore.SecurityPoliciesExceptionOrVoid {
    let nameCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    if fetchHeadersIsSetCookie(name, nameCharacters) {
        let trimmedValue = fetchHeadersTrim(value)
        let decision = fetchHeadersSetCookieDecision(trimmedValue.isValid, headersGuard)
        guard case .write = decision else {
            return fetchHeadersSetCookieResult(decision, value, trimmedValue.range)
        }
        setCookieValues.append(consuming: fetchHeadersTrimmedString(value, trimmedValue))
        return WebCore.SecurityPoliciesExceptionOrVoid()
    }

    // The value the header would have is the trimmed value itself when the map has no such header yet.
    let existingValue = headers.valueForName(name)
    if existingValue.isNull() {
        let trimmedValue: FetchHeadersTrimmedValue
        let decision: FetchHeadersDecision
        do {
            let valueCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
            trimmedValue = fetchHeadersTrim(value, valueCharacters)
            decision = fetchHeadersCanWriteHeader(
                name,
                nameCharacters,
                value,
                valueCharacters,
                trimmedValue,
                value,
                trimmedValue.range,
                headersGuard
            )
        }
        guard case .write = decision else {
            return fetchHeadersResult(decision, name, value, trimmedValue.range)
        }
        headers.set(name, fetchHeadersTrimmedString(value, trimmedValue))
    } else {
        let valueCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
        let trimmedValue = fetchHeadersTrim(value, valueCharacters)
        let combinedValue = fetchHeadersMakeString(
            fetchHeadersNoCharacters,
            existingValue,
            WebCore.securityPoliciesSpan8(existingValue),
            nil,
            fetchHeadersCommaSpace,
            value,
            valueCharacters,
            trimmedValue.range,
            fetchHeadersNoCharacters
        )
        let decision = fetchHeadersCanWriteHeader(
            name,
            nameCharacters,
            value,
            valueCharacters,
            trimmedValue,
            combinedValue,
            nil,
            headersGuard
        )
        guard case .write = decision else {
            return fetchHeadersResult(decision, name, value, trimmedValue.range)
        }
        headers.set(name, combinedValue)
    }

    if headersGuard == .RequestNoCors {
        // https://fetch.spec.whatwg.org/#concept-headers-remove-privileged-no-cors-request-headers
        headers.remove(WebCore.HTTPHeaderName.Range)
    }
    return WebCore.SecurityPoliciesExceptionOrVoid()
}

/// `FetchHeaders::remove()`: https://fetch.spec.whatwg.org/#dom-headers-delete. `updateCounter` is raised once the
/// checks pass.
///
/// `headers`, `setCookieValues` and `updateCounter` are the `FetchHeaders`' `m_headers`, `m_setCookieValues` and
/// `m_updateCounter`, passed by its member. Only this function changes them during the call, through their own
/// members (`HTTPHeaderMap`'s `remove()`, `Vector`'s `clear()`); the other C++ it calls (`findHTTPHeaderName()`)
/// does not reach the `FetchHeaders`.
@_expose(Cxx)
func fetchHeadersRemove(
    _ headers: inout WebCore.HTTPHeaderMap,
    _ setCookieValues: inout WebCore.SecurityPoliciesStringVector,
    _ headersGuard: WebCore.FetchHeadersGuard,
    _ updateCounter: inout UInt64,
    _ name: consuming WTF.String
) -> WebCore.SecurityPoliciesExceptionOrVoid {
    let nameCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    if !fetchHeadersIsValidHTTPToken(name, nameCharacters) {
        return WebCore.SecurityPoliciesExceptionOrVoid(consuming: fetchHeadersTypeError(fetchHeadersInvalidNameMessage(name)))
    }
    if headersGuard == .Immutable {
        return WebCore.SecurityPoliciesExceptionOrVoid(consuming: fetchHeadersTypeError(fetchHeadersImmutableMessage()))
    }
    if headersGuard == .Request, fetchHeadersIsForbiddenHeaderName(name, nameCharacters) {
        return WebCore.SecurityPoliciesExceptionOrVoid()
    }
    if headersGuard == .RequestNoCors, !fetchHeadersIsNoCORSSafelistedRequestHeaderName(name),
        !fetchHeadersIsPriviledgedNoCORSRequestHeaderName(name, nameCharacters)
    {
        return WebCore.SecurityPoliciesExceptionOrVoid()
    }
    if headersGuard == .Response, fetchHeadersIsForbiddenResponseHeaderName(name, nameCharacters) {
        return WebCore.SecurityPoliciesExceptionOrVoid()
    }

    // A uint64_t counter, which wraps as the C++'s would; it cannot reach 2^64 in practice.
    updateCounter &+= 1
    if fetchHeadersIsSetCookie(name, nameCharacters) {
        setCookieValues.clear()
    } else {
        headers.remove(name)
    }

    if headersGuard == .RequestNoCors {
        // https://fetch.spec.whatwg.org/#concept-headers-remove-privileged-no-cors-request-headers
        headers.remove(WebCore.HTTPHeaderName.Range)
    }
    return WebCore.SecurityPoliciesExceptionOrVoid()
}

/// `FetchHeaders::set()`: sets the header named `name` to `value`, trimmed of HTTP whitespace, or makes it the only
/// Set-Cookie value. `updateCounter` is raised once the checks pass.
///
/// `headers`, `setCookieValues` and `updateCounter` are the `FetchHeaders`' `m_headers`, `m_setCookieValues` and
/// `m_updateCounter`, passed by its member. Only this function changes them during the call, through their own
/// members (`HTTPHeaderMap`'s `set()` and `remove()`, `Vector`'s `clear()` and `append()`); the other C++ it calls
/// (`findHTTPHeaderName()`, String functions) does not reach the `FetchHeaders`.
@_expose(Cxx)
func fetchHeadersSet(
    _ headers: inout WebCore.HTTPHeaderMap,
    _ setCookieValues: inout WebCore.SecurityPoliciesStringVector,
    _ headersGuard: WebCore.FetchHeadersGuard,
    _ updateCounter: inout UInt64,
    _ name: consuming WTF.String,
    _ value: consuming WTF.String
) -> WebCore.SecurityPoliciesExceptionOrVoid {
    let nameCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    let trimmedValue: FetchHeadersTrimmedValue
    let decision: FetchHeadersDecision
    do {
        let valueCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
        trimmedValue = fetchHeadersTrim(value, valueCharacters)
        decision = fetchHeadersCanWriteHeader(
            name,
            nameCharacters,
            value,
            valueCharacters,
            trimmedValue,
            value,
            trimmedValue.range,
            headersGuard
        )
    }
    guard case .write = decision else {
        return fetchHeadersResult(decision, name, value, trimmedValue.range)
    }

    // A uint64_t counter, which wraps as the C++'s would; it cannot reach 2^64 in practice.
    updateCounter &+= 1
    if fetchHeadersIsSetCookie(name, nameCharacters) {
        setCookieValues.clear()
        setCookieValues.append(consuming: fetchHeadersTrimmedString(value, trimmedValue))
    } else {
        headers.set(name, fetchHeadersTrimmedString(value, trimmedValue))
    }

    if headersGuard == .RequestNoCors {
        // https://fetch.spec.whatwg.org/#concept-headers-remove-privileged-no-cors-request-headers
        headers.remove(WebCore.HTTPHeaderName.Range)
    }
    return WebCore.SecurityPoliciesExceptionOrVoid()
}

/// `FetchHeaders::get()` and `has()` of `name` read the map only when this is true: when `name` is a valid header name
/// other than `set-cookie`.
///
/// Otherwise fetchHeadersGet() and fetchHeadersHas() decide.
@_expose(Cxx)
func fetchHeadersNeedsLookup(_ name: consuming WTF.String) -> Bool {
    let nameCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    if !fetchHeadersIsValidHTTPToken(name, nameCharacters) {
        return false
    }
    return !fetchHeadersIsSetCookie(name, nameCharacters)
}

/// `FetchHeaders::get()` of a `name` for which fetchHeadersNeedsLookup() is false: the `TypeError` for an invalid name,
/// else the Set-Cookie values joined with `", "` (the null String when there are none).
///
/// `setCookieValues` is the `FetchHeaders`' `m_setCookieValues`, passed by its `const` member, which this function only
/// reads (`isEmpty()`, `size()`, the subscript). Nothing changes it during the call: the other C++ this function calls
/// (String functions, `Exception`'s constructor) does not reach the `FetchHeaders`.
@_expose(Cxx)
func fetchHeadersGet(
    _ name: consuming WTF.String,
    _ setCookieValues: borrowing WebCore.SecurityPoliciesStringVector
) -> WebCore.SecurityPoliciesExceptionOrString {
    let nameCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    if !fetchHeadersIsValidHTTPToken(name, nameCharacters) {
        return WebCore.SecurityPoliciesExceptionOrString(consuming: fetchHeadersTypeError(fetchHeadersInvalidNameMessage(name)))
    }

    if setCookieValues.isEmpty() {
        return WebCore.SecurityPoliciesExceptionOrString(consuming: WTF.String())
    }
    return WebCore.SecurityPoliciesExceptionOrString(consuming: fetchHeadersJoinedSetCookieValues(setCookieValues))
}

/// `FetchHeaders::has()` of a `name` for which fetchHeadersNeedsLookup() is false: the `TypeError` for an invalid name,
/// else `hasSetCookie`.
@_expose(Cxx)
func fetchHeadersHas(_ name: consuming WTF.String, _ hasSetCookie: Bool) -> WebCore.SecurityPoliciesExceptionOrBool {
    let nameCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    if !fetchHeadersIsValidHTTPToken(name, nameCharacters) {
        return WebCore.SecurityPoliciesExceptionOrBool(consuming: fetchHeadersTypeError(fetchHeadersInvalidNameMessage(name)))
    }
    return WebCore.SecurityPoliciesExceptionOrBool(consuming: hasSetCookie)
}

// MARK: - Filling from other headers

/// `FetchHeaders::fill(const FetchHeaders&)`: appends each of the other object's headers, then each of its Set-Cookie
/// values, stopping at the first exception.
///
/// A header's value is checked trimmed of HTTP whitespace and added as it is.
///
/// `headers` and `setCookieValues` are the `FetchHeaders`' `m_headers` and `m_setCookieValues`, passed by its member;
/// only this function changes them during the call, through their own members (`HTTPHeaderMap`'s `add()`,
/// `addUncommonHeader()` and `remove()`, `Vector`'s `append()`). `source` is the other object's `m_headers`, and
/// `sourceSetCookieValues` its `m_setCookieValues`, which this function only reads (`commonHeadersSpan()`,
/// `uncommonHeadersSpan()`, `size()`, the subscript); the member passes a copy of itself as the other object when it is
/// filled from itself, so neither aliases what this function changes. The other C++ this function calls
/// (`findHTTPHeaderName()`, String functions) reaches neither object.
@_expose(Cxx)
func fetchHeadersFill(
    _ headers: inout WebCore.HTTPHeaderMap,
    _ setCookieValues: inout WebCore.SecurityPoliciesStringVector,
    _ headersGuard: WebCore.FetchHeadersGuard,
    _ source: borrowing WebCore.HTTPHeaderMap,
    _ sourceSetCookieValues: borrowing WebCore.SecurityPoliciesStringVector
) -> WebCore.SecurityPoliciesExceptionOrVoid {
    let commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader> = source.commonHeadersSpan()
    for index in commonHeaders.indices {
        let decision = fetchHeadersCanAddCommonHeader(commonHeaders[index].key, commonHeaders[index].value, headersGuard)
        switch decision {
        case .write:
            break
        case .skip:
            continue
        default:
            return fetchHeadersResult(
                decision,
                WebCore.securityPoliciesHTTPHeaderNameString(commonHeaders[index].key),
                commonHeaders[index].value,
                fetchHeadersTrim(commonHeaders[index].value).range
            )
        }
        headers.add(commonHeaders[index].key, commonHeaders[index].value)
        if headersGuard == .RequestNoCors {
            // https://fetch.spec.whatwg.org/#concept-headers-remove-privileged-no-cors-request-headers
            headers.remove(WebCore.HTTPHeaderName.Range)
        }
    }
    let uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader> = source.uncommonHeadersSpan()
    for index in uncommonHeaders.indices {
        let decision = fetchHeadersCanAddHeader(uncommonHeaders[index].key, uncommonHeaders[index].value, headersGuard)
        switch decision {
        case .write:
            break
        case .skip:
            continue
        default:
            return fetchHeadersResult(
                decision,
                uncommonHeaders[index].key,
                uncommonHeaders[index].value,
                fetchHeadersTrim(uncommonHeaders[index].value).range
            )
        }
        headers.addUncommonHeader(uncommonHeaders[index].key, uncommonHeaders[index].value)
        if headersGuard == .RequestNoCors {
            // https://fetch.spec.whatwg.org/#concept-headers-remove-privileged-no-cors-request-headers
            headers.remove(WebCore.HTTPHeaderName.Range)
        }
    }

    for index in 0..<sourceSetCookieValues.size() {
        let value = sourceSetCookieValues[index]
        let decision = fetchHeadersSetCookieDecision(fetchHeadersIsValidHTTPHeaderValue(value), headersGuard)
        switch decision {
        case .write:
            setCookieValues.append(consuming: value)
        case .skip:
            break
        default:
            return fetchHeadersSetCookieResult(decision, value, nil)
        }
    }
    return WebCore.SecurityPoliciesExceptionOrVoid()
}

/// `FetchHeaders::filterAndFill()`: adds each header of `source` that `headersGuard` lets a script write, as it is,
/// skipping the others and any that would throw.
///
/// `headers` is the `FetchHeaders`' `m_headers`, passed by its member; only this function changes it during the call,
/// through its own members (`HTTPHeaderMap`'s `add()` and `addUncommonHeader()`). `source` is the caller's map (a
/// response's or a WebTransport session's headers), never `headers`. The other C++ this function calls
/// (`findHTTPHeaderName()`, String functions) reaches neither map.
@_expose(Cxx)
func fetchHeadersFilterAndFill(
    _ headers: inout WebCore.HTTPHeaderMap,
    _ source: borrowing WebCore.HTTPHeaderMap,
    _ headersGuard: WebCore.FetchHeadersGuard
) {
    let commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader> = source.commonHeadersSpan()
    for index in commonHeaders.indices {
        guard case .write = fetchHeadersCanAddCommonHeader(commonHeaders[index].key, commonHeaders[index].value, headersGuard) else {
            continue
        }
        headers.add(commonHeaders[index].key, commonHeaders[index].value)
    }
    let uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader> = source.uncommonHeadersSpan()
    for index in uncommonHeaders.indices {
        guard case .write = fetchHeadersCanAddHeader(uncommonHeaders[index].key, uncommonHeaders[index].value, headersGuard) else {
            continue
        }
        headers.addUncommonHeader(uncommonHeaders[index].key, uncommonHeaders[index].value)
    }
}

// MARK: - Iteration

/// `FetchHeaders::Iterator::next()`: the next header, by name lowercased and sorted by code point, with one pair per
/// Set-Cookie value under `set-cookie`.
///
/// When `headersUpdateCounter` differs from the iterator's `updateCounter`, the names are gathered and sorted again and
/// the position moved to the same place among them.
///
/// `headers` is the iterated `FetchHeaders`' `m_headers`, and `setCookieValues` its `m_setCookieValues`, passed through
/// the iterator's reference to the object, which keeps the object alive for the call; this function only reads them
/// (`commonHeadersSpan()`, `uncommonHeadersSpan()`, `valueForName()`, `isEmpty()`, `size()`, the subscript). `keys` is
/// the iterator's `m_keys`, passed by its member: only this function changes it during the call, through its own
/// members (`shrink()`, `append()`). No script runs, and the other C++ this function calls (String functions,
/// `securityPoliciesSpan8()`, `lowercaseHTTPHeaderNameString()` and `securityPoliciesOptionalStringPair()`) reaches
/// neither the `FetchHeaders` nor the iterator.
@_expose(Cxx)
func fetchHeadersIteratorNext(
    _ headers: borrowing WebCore.HTTPHeaderMap,
    _ setCookieValues: borrowing WebCore.SecurityPoliciesStringVector,
    _ headersUpdateCounter: UInt64,
    _ keys: inout WebCore.SecurityPoliciesStringVector,
    _ currentIndex: inout UInt,
    _ setCookieIndex: inout UInt,
    _ updateCounter: inout UInt
) -> WebCore.SecurityPoliciesOptionalStringPair {
    // The iterator's counter is a size_t and the object's a uint64_t, compared and assigned as the C++ does.
    if keys.isEmpty() || UInt64(updateCounter) != headersUpdateCounter {
        let hasSetCookie = !setCookieValues.isEmpty()
        let commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader> = headers.commonHeadersSpan()
        let uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader> = headers.uncommonHeadersSpan()
        keys.shrink(0)
        let setCookieKeyIndex = UInt(fetchHeadersAppendSortedKeys(commonHeaders, uncommonHeaders, hasSetCookie, &keys))

        // Adjust the current index to work with Set-Cookie headers. This relies on the fact that
        // `currentIndex + setCookieIndex` gives you the current total index into the iteration.
        // Both are below the number of pairs already returned, so the sum cannot overflow.
        currentIndex &+= setCookieIndex
        if hasSetCookie {
            if currentIndex < setCookieKeyIndex {
                setCookieIndex = 0
            } else {
                setCookieIndex = min(currentIndex - setCookieKeyIndex, UInt(setCookieValues.size()))
                // setCookieIndex is at most currentIndex - setCookieKeyIndex.
                currentIndex &-= setCookieIndex
            }
        } else {
            setCookieIndex = 0
        }

        updateCounter = UInt(truncatingIfNeeded: headersUpdateCounter)
    }

    while currentIndex < UInt(keys.size()) {
        let key = keys[Int(currentIndex)]
        if key.isNull() {
            if setCookieIndex < UInt(setCookieValues.size()) {
                let value = setCookieValues[Int(setCookieIndex)]
                // Below the number of Set-Cookie values.
                setCookieIndex &+= 1
                return WebCore.securityPoliciesOptionalStringPair(
                    consuming: WTF.makeStringFromLatin1Characters(fetchHeadersSetCookieName.span),
                    consuming: value
                )
            }
            // Below keys.size().
            currentIndex &+= 1
            continue
        }
        // Below keys.size().
        currentIndex &+= 1
        let value = headers.valueForName(key)
        if !value.isNull() {
            return WebCore.securityPoliciesOptionalStringPair(consuming: key, consuming: value)
        }
    }
    return WebCore.SecurityPoliciesOptionalStringPair()
}

/// One of the names the iterator sorts: its code units, lowercased, are `start..<end` of the names' code units, and
/// `source` is its position in map order (common headers, uncommon headers, then the null String standing for the
/// Set-Cookie values).
private struct FetchHeadersIteratorName {
    var start = 0
    var end = 0
    var source = 0
}

/// Appends the iterator's keys to `keys`, sorted as `compareIteratorKeys()` sorts them.
///
/// The keys are the names of `commonHeaders` and `uncommonHeaders` lowercased and, with `hasSetCookie`, the null String
/// standing for the Set-Cookie values, which sorts as `set-cookie`; equal names keep their map order. Returns the number
/// of keys below `set-cookie`, as `std::ranges::lower_bound` finds it, when there are Set-Cookie values, else 0.
private func fetchHeadersAppendSortedKeys(
    _ commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader>,
    _ uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader>,
    _ hasSetCookie: Bool,
    _ keys: inout WebCore.SecurityPoliciesStringVector
) -> Int {
    // A map holds fewer than 2^32 headers, each name shorter than 2^31, so none of these sums can overflow.
    let count = commonHeaders.count &+ uncommonHeaders.count &+ (hasSetCookie ? 1 : 0)
    var codeUnitCount = hasSetCookie ? fetchHeadersSetCookieName.count : 0
    for index in commonHeaders.indices {
        // Likewise.
        codeUnitCount &+= Int(WebCore.lowercaseHTTPHeaderNameString(commonHeaders[index].key).length())
    }
    for index in uncommonHeaders.indices {
        // Likewise.
        codeUnitCount &+= Int(uncommonHeaders[index].key.length())
    }
    return crossOriginAccessControlWithNames(FetchHeadersIteratorName(), count, codeUnitCount) { names, codeUnits in
        fetchHeadersAppendSortedKeys(commonHeaders, uncommonHeaders, hasSetCookie, &names, &codeUnits, &keys)
    }
}

/// fetchHeadersAppendSortedKeys() with room in `names` for every name, and in `codeUnits` for their code units.
private func fetchHeadersAppendSortedKeys(
    _ commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader>,
    _ uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader>,
    _ hasSetCookie: Bool,
    _ names: inout MutableSpan<FetchHeadersIteratorName>,
    _ codeUnits: inout MutableSpan<UInt16>,
    _ keys: inout WebCore.SecurityPoliciesStringVector
) -> Int {
    var count = 0
    var end = 0
    for index in commonHeaders.indices {
        let start = end
        end = crossOriginAccessControlWriteLowercased(WebCore.lowercaseHTTPHeaderNameString(commonHeaders[index].key), &codeUnits, start)
        names[count] = FetchHeadersIteratorName(start: start, end: end, source: count)
        count += 1
    }
    for index in uncommonHeaders.indices {
        let start = end
        end = crossOriginAccessControlWriteLowercased(uncommonHeaders[index].key, &codeUnits, start)
        names[count] = FetchHeadersIteratorName(start: start, end: end, source: count)
        count += 1
    }
    if hasSetCookie {
        let start = end
        end = crossOriginAccessControlCopy(fetchHeadersSetCookieName.span, to: &codeUnits, at: start)
        names[count] = FetchHeadersIteratorName(start: start, end: end, source: count)
        count += 1
    }

    let pool = codeUnits.span
    crossOriginAccessControlSortNames(&names, count, pool) { $0.start..<$0.end }

    for position in 0..<count {
        keys.append(consuming: fetchHeadersIteratorKey(names[position], commonHeaders, uncommonHeaders))
    }
    var setCookieKeyIndex = 0
    if hasSetCookie {
        while setCookieKeyIndex < count,
            crossOriginAccessControlCodePointLessThan(
                pool.extracting(names[setCookieKeyIndex].start..<names[setCookieKeyIndex].end),
                fetchHeadersSetCookieName.span
            )
        {
            setCookieKeyIndex += 1
        }
    }
    return setCookieKeyIndex
}

/// The key of `name` among the sorted names: a common header's name lowercased, an uncommon header's name lowercased, or
/// the null String standing for the Set-Cookie values.
private func fetchHeadersIteratorKey(
    _ name: FetchHeadersIteratorName,
    _ commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader>,
    _ uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader>
) -> WTF.String {
    if name.source < commonHeaders.count {
        // What convertToASCIILowercase() makes of httpHeaderNameString().
        return WebCore.lowercaseHTTPHeaderNameString(commonHeaders[name.source].key)
    }
    // source is at least commonHeaders.count here.
    let uncommonIndex = name.source &- commonHeaders.count
    if uncommonIndex < uncommonHeaders.count {
        return uncommonHeaders[uncommonIndex].key.convertToASCIILowercase()
    }
    return WTF.String()
}

// MARK: - The checks

/// What `canWriteHeader()` and `appendSetCookie()` decide.
///
/// The last three are a `TypeError`, whose message names the header and its value as the C++ does
/// (fetchHeadersResult(), fetchHeadersSetCookieResult()).
private enum FetchHeadersDecision {
    case write
    case skip
    case invalidName
    case invalidValue
    case immutable
}

/// A header value trimmed of HTTP whitespace, as `String::trim(isASCIIWhitespaceWithoutFF)` trims it: the trimmed value
/// is the value's code units `range`, of `length`.
private struct FetchHeadersTrimmedValue {
    var range: Range<Int>
    var length: Int
    /// Whether the trimmed value is a valid header value.
    var isValid: Bool
}

/// `canWriteHeader()`: the checks a header passes before a script may write it under `headersGuard`, in the order
/// the C++ makes them. `value` is checked trimmed; the RequestNoCors check reads the value's code units
/// `combinedValueRange` when there is one, else `combinedValue`. `nameCharacters` and `valueCharacters` are what
/// securityPoliciesSpan8() reads of `name` and `value`.
private func fetchHeadersCanWriteHeader(
    _ name: borrowing WTF.String,
    _ nameCharacters: Span<UInt8>,
    _ value: borrowing WTF.String,
    _ valueCharacters: Span<UInt8>,
    _ trimmedValue: FetchHeadersTrimmedValue,
    _ combinedValue: borrowing WTF.String,
    _ combinedValueRange: Range<Int>?,
    _ headersGuard: WebCore.FetchHeadersGuard
) -> FetchHeadersDecision {
    if !fetchHeadersIsValidHTTPToken(name, nameCharacters) {
        return .invalidName
    }
    if !trimmedValue.isValid {
        return .invalidValue
    }
    if headersGuard == .Immutable {
        return .immutable
    }
    if headersGuard == .Request, fetchHeadersIsForbiddenHeader(name, nameCharacters, value, valueCharacters, trimmedValue.range) {
        return .skip
    }
    if headersGuard == .RequestNoCors {
        let isSimpleHeader =
            if let combinedValueRange {
                fetchHeadersIsSimpleHeader(name, value, valueCharacters, combinedValueRange)
            } else {
                fetchHeadersIsSimpleHeader(name, combinedValue, WebCore.securityPoliciesSpan8(combinedValue), nil)
            }
        if !isSimpleHeader {
            return .skip
        }
    }
    if headersGuard == .Response, fetchHeadersIsForbiddenResponseHeaderName(name, nameCharacters) {
        return .skip
    }
    return .write
}

/// canWriteHeader() of an uncommon header of another map, `name` with `value`: the value is checked trimmed and, under
/// RequestNoCors, as it is.
private func fetchHeadersCanAddHeader(
    _ name: borrowing WTF.String,
    _ value: borrowing WTF.String,
    _ headersGuard: WebCore.FetchHeadersGuard
) -> FetchHeadersDecision {
    let nameCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(name)
    let valueCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
    let trimmedValue = fetchHeadersTrim(value, valueCharacters)
    return fetchHeadersCanWriteHeader(
        name,
        nameCharacters,
        value,
        valueCharacters,
        trimmedValue,
        value,
        0..<trimmedValue.length,
        headersGuard
    )
}

/// fetchHeadersCanAddHeader() of a common header of another map, named `name`, with `value`.
///
/// A known name is a valid token, and the checks of a name ignore ASCII case, so they read its lowercased name.
private func fetchHeadersCanAddCommonHeader(
    _ name: WebCore.HTTPHeaderName,
    _ value: borrowing WTF.String,
    _ headersGuard: WebCore.FetchHeadersGuard
) -> FetchHeadersDecision {
    let valueCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
    let trimmedValue = fetchHeadersTrim(value, valueCharacters)
    if !trimmedValue.isValid {
        return .invalidValue
    }
    if headersGuard == .Immutable {
        return .immutable
    }
    let lowercaseName = WebCore.lowercaseHTTPHeaderNameString(name)
    let nameCharacters: Span<UInt8> = WebCore.securityPoliciesSpan8(lowercaseName)
    if headersGuard == .Request {
        let isForbidden: Bool
        if !valueCharacters.isEmpty {
            isForbidden = FetchHeaderChecks.isForbiddenHeader(
                isKnown: true,
                headerName: name,
                nameCharacters,
                valueCharacters.extracting(trimmedValue.range)
            )
        } else {
            let valueUnits: Span<UInt16> = value.checkedSpan16()
            isForbidden = FetchHeaderChecks.isForbiddenHeader(
                isKnown: true,
                headerName: name,
                nameCharacters,
                valueUnits.extracting(trimmedValue.range)
            )
        }
        if isForbidden {
            return .skip
        }
    }
    if headersGuard == .RequestNoCors {
        let isSimpleHeader: Bool
        if !valueCharacters.isEmpty {
            isSimpleHeader = isCrossOriginSafeRequestHeaderBody(name, valueCharacters)
        } else {
            let valueUnits: Span<UInt16> = value.checkedSpan16()
            isSimpleHeader = isCrossOriginSafeRequestHeaderBody(name, valueUnits)
        }
        if !isSimpleHeader {
            return .skip
        }
    }
    if headersGuard == .Response, FetchHeaderChecks.isForbiddenResponseHeaderName(nameCharacters) {
        return .skip
    }
    return .write
}

/// The checks `appendSetCookie()` makes of a value: `.write` to append it, which only the None guard keeps.
private func fetchHeadersSetCookieDecision(_ isValidValue: Bool, _ headersGuard: WebCore.FetchHeadersGuard) -> FetchHeadersDecision {
    if !isValidValue {
        return .invalidValue
    }
    if headersGuard == .Immutable {
        return .immutable
    }
    return headersGuard == .None ? .write : .skip
}

/// What canWriteHeader() returns for a decision other than `.write`: nothing for `.skip`, else the `TypeError` for the
/// header `name` with `value`, checked as its code units `valueRange`.
private func fetchHeadersResult(
    _ decision: FetchHeadersDecision,
    _ name: borrowing WTF.String,
    _ value: borrowing WTF.String,
    _ valueRange: Range<Int>
) -> WebCore.SecurityPoliciesExceptionOrVoid {
    switch decision {
    case .write, .skip:
        return WebCore.SecurityPoliciesExceptionOrVoid()
    case .invalidName:
        return WebCore.SecurityPoliciesExceptionOrVoid(consuming: fetchHeadersTypeError(fetchHeadersInvalidNameMessage(name)))
    case .invalidValue:
        // An invalid value is not empty, so its trimmed String has its width.
        let message = fetchHeadersMakeString(
            fetchHeadersInvalidValuePrefix,
            name,
            WebCore.securityPoliciesSpan8(name),
            nil,
            fetchHeadersInvalidValueMiddle,
            value,
            WebCore.securityPoliciesSpan8(value),
            valueRange,
            fetchHeadersQuote
        )
        return WebCore.SecurityPoliciesExceptionOrVoid(consuming: fetchHeadersTypeError(message))
    case .immutable:
        return WebCore.SecurityPoliciesExceptionOrVoid(consuming: fetchHeadersTypeError(fetchHeadersImmutableMessage()))
    }
}

/// What appendSetCookie() returns for a decision other than `.write`: nothing for `.skip`, else a `TypeError`, whose
/// message for `.invalidValue` names `value`, or its code units `valueRange` when there is one.
private func fetchHeadersSetCookieResult(
    _ decision: FetchHeadersDecision,
    _ value: borrowing WTF.String,
    _ valueRange: Range<Int>?
) -> WebCore.SecurityPoliciesExceptionOrVoid {
    switch decision {
    case .write, .skip:
        return WebCore.SecurityPoliciesExceptionOrVoid()
    case .invalidValue:
        let message = fetchHeadersMakeString(
            fetchHeadersInvalidSetCookieValuePrefix,
            value,
            WebCore.securityPoliciesSpan8(value),
            valueRange,
            fetchHeadersQuote,
            WTF.String(),
            Span(),
            nil,
            fetchHeadersNoCharacters
        )
        return WebCore.SecurityPoliciesExceptionOrVoid(consuming: fetchHeadersTypeError(message))
    case .invalidName, .immutable:
        return WebCore.SecurityPoliciesExceptionOrVoid(consuming: fetchHeadersTypeError(fetchHeadersImmutableMessage()))
    }
}

/// `findHTTPHeaderName()` of `name`.
private func fetchHeadersHeaderName(_ name: borrowing WTF.String) -> WebCore.HTTPHeaderName? {
    // What `HTTPHeaderName headerName { }` holds; findHTTPHeaderName() writes it only when it finds the name.
    var headerName = WebCore.HTTPHeaderName.Accept
    if WebCore.securityPoliciesFindHTTPHeaderName(name, &headerName) {
        return headerName
    }
    return nil
}

/// `isValidHTTPToken(const String&)` of `name`, whose 8-bit characters are `characters`.
private func fetchHeadersIsValidHTTPToken(_ name: borrowing WTF.String, _ characters: Span<UInt8>) -> Bool {
    if !characters.isEmpty {
        return HTTPHeaderValueValidation.isValidHTTPToken(characters)
    }
    return HTTPHeaderValueValidation.isValidHTTPToken(name.checkedSpan16())
}

/// `isValidHTTPHeaderValue()`.
private func fetchHeadersIsValidHTTPHeaderValue(_ value: borrowing WTF.String) -> Bool {
    let characters: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
    if !characters.isEmpty {
        return HTTPHeaderValueValidation.isValidHTTPHeaderValue(characters)
    }
    return HTTPHeaderValueValidation.isValidHTTPHeaderValue(value.checkedSpan16())
}

/// `isForbiddenHeader()` of `name` and the code units `valueRange` of `value`, whose 8-bit characters are
/// `nameCharacters` and `valueCharacters`.
private func fetchHeadersIsForbiddenHeader(
    _ name: borrowing WTF.String,
    _ nameCharacters: Span<UInt8>,
    _ value: borrowing WTF.String,
    _ valueCharacters: Span<UInt8>,
    _ valueRange: Range<Int>
) -> Bool {
    let headerName = fetchHeadersHeaderName(name)
    let isKnown = headerName != nil
    let knownName = headerName ?? WebCore.HTTPHeaderName.Accept
    if !nameCharacters.isEmpty {
        if !valueCharacters.isEmpty {
            return FetchHeaderChecks.isForbiddenHeader(
                isKnown: isKnown,
                headerName: knownName,
                nameCharacters,
                valueCharacters.extracting(valueRange)
            )
        }
        let valueUnits: Span<UInt16> = value.checkedSpan16()
        return FetchHeaderChecks.isForbiddenHeader(
            isKnown: isKnown,
            headerName: knownName,
            nameCharacters,
            valueUnits.extracting(valueRange)
        )
    }
    let nameUnits: Span<UInt16> = name.checkedSpan16()
    if !valueCharacters.isEmpty {
        return FetchHeaderChecks.isForbiddenHeader(
            isKnown: isKnown,
            headerName: knownName,
            nameUnits,
            valueCharacters.extracting(valueRange)
        )
    }
    let valueUnits: Span<UInt16> = value.checkedSpan16()
    return FetchHeaderChecks.isForbiddenHeader(isKnown: isKnown, headerName: knownName, nameUnits, valueUnits.extracting(valueRange))
}

/// `isSimpleHeader()` of `name` and `value`, or its code units `valueRange` when there is one; `characters` are the value's
/// 8-bit characters.
private func fetchHeadersIsSimpleHeader(
    _ name: borrowing WTF.String,
    _ value: borrowing WTF.String,
    _ characters: Span<UInt8>,
    _ valueRange: Range<Int>?
) -> Bool {
    guard let headerName = fetchHeadersHeaderName(name) else {
        return false
    }
    if !characters.isEmpty {
        return isCrossOriginSafeRequestHeaderBody(headerName, characters.extracting(valueRange ?? characters.indices))
    }
    let units: Span<UInt16> = value.checkedSpan16()
    return isCrossOriginSafeRequestHeaderBody(headerName, units.extracting(valueRange ?? units.indices))
}

/// `isForbiddenHeaderName()` of `name`, whose 8-bit characters are `characters`.
private func fetchHeadersIsForbiddenHeaderName(_ name: borrowing WTF.String, _ characters: Span<UInt8>) -> Bool {
    let headerName = fetchHeadersHeaderName(name)
    let isKnown = headerName != nil
    let knownName = headerName ?? WebCore.HTTPHeaderName.Accept
    if !characters.isEmpty {
        return FetchHeaderChecks.isForbiddenHeaderName(isKnown: isKnown, headerName: knownName, characters)
    }
    return FetchHeaderChecks.isForbiddenHeaderName(isKnown: isKnown, headerName: knownName, name.checkedSpan16())
}

/// `isNoCORSSafelistedRequestHeaderName()`.
private func fetchHeadersIsNoCORSSafelistedRequestHeaderName(_ name: borrowing WTF.String) -> Bool {
    let headerName = fetchHeadersHeaderName(name)
    return FetchHeaderChecks.isNoCORSSafelistedRequestHeaderName(
        isKnown: headerName != nil,
        headerName: headerName ?? WebCore.HTTPHeaderName.Accept
    )
}

/// `isPriviledgedNoCORSRequestHeaderName()` of `name`, whose 8-bit characters are `characters`.
private func fetchHeadersIsPriviledgedNoCORSRequestHeaderName(_ name: borrowing WTF.String, _ characters: Span<UInt8>) -> Bool {
    if !characters.isEmpty {
        return FetchHeaderChecks.isPriviledgedNoCORSRequestHeaderName(characters)
    }
    return FetchHeaderChecks.isPriviledgedNoCORSRequestHeaderName(name.checkedSpan16())
}

/// `isForbiddenResponseHeaderName()` of `name`, whose 8-bit characters are `characters`.
private func fetchHeadersIsForbiddenResponseHeaderName(_ name: borrowing WTF.String, _ characters: Span<UInt8>) -> Bool {
    if !characters.isEmpty {
        return FetchHeaderChecks.isForbiddenResponseHeaderName(characters)
    }
    return FetchHeaderChecks.isForbiddenResponseHeaderName(name.checkedSpan16())
}

/// `equalIgnoringASCIICase(name, "set-cookie"_s)` of `name`, whose 8-bit characters are `characters`.
private func fetchHeadersIsSetCookie(_ name: borrowing WTF.String, _ characters: Span<UInt8>) -> Bool {
    if !characters.isEmpty {
        return HTTPHeaderCodeUnits.equalIgnoringASCIICase(characters, fetchHeadersSetCookieName.span)
    }
    return HTTPHeaderCodeUnits.equalIgnoringASCIICase(name.checkedSpan16(), fetchHeadersSetCookieName.span)
}

private let fetchHeadersSetCookieName: [UInt8] = Array("set-cookie".utf8)

// MARK: - Strings

/// `value` trimmed of HTTP whitespace, and whether what remains is a valid header value.
private func fetchHeadersTrim(_ value: borrowing WTF.String) -> FetchHeadersTrimmedValue {
    fetchHeadersTrim(value, WebCore.securityPoliciesSpan8(value))
}

/// fetchHeadersTrim() of `value`, whose 8-bit characters are `characters`.
private func fetchHeadersTrim(_ value: borrowing WTF.String, _ characters: Span<UInt8>) -> FetchHeadersTrimmedValue {
    if !characters.isEmpty {
        return fetchHeadersTrim(characters)
    }
    return fetchHeadersTrim(value.checkedSpan16())
}

private func fetchHeadersTrim<CodeUnit: HTTPHeaderStringCodeUnit>(_ characters: Span<CodeUnit>) -> FetchHeadersTrimmedValue {
    let range = HTTPHeaderCodeUnits.trim(characters, characters.indices, HTTPHeaderCodeUnits.isASCIIWhitespaceWithoutFF)
    return FetchHeadersTrimmedValue(
        range: range,
        length: characters.count,
        isValid: HTTPHeaderValueValidation.isValidHTTPHeaderValue(characters.extracting(range))
    )
}

/// The String `String::trim(isASCIIWhitespaceWithoutFF)` makes: `value` itself when there is nothing to trim, the empty
/// String when only whitespace remains, else a new String of the same width.
private func fetchHeadersTrimmedString(_ value: consuming WTF.String, _ trimmedValue: FetchHeadersTrimmedValue) -> WTF.String {
    if trimmedValue.range.count == trimmedValue.length {
        return value
    }
    let characters: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
    if !characters.isEmpty {
        return WTF.makeStringFromLatin1Characters(characters.extracting(trimmedValue.range))
    }
    let units: Span<UInt16> = value.checkedSpan16()
    return WTF.makeStringFromUTF16Characters(units.extracting(trimmedValue.range))
}

/// `makeString(prefix, first, middle, second, suffix)` of ASCII text and two Strings, as WTF makes it: one String of
/// their length, 8-bit when both Strings are (the null String counts as 8-bit).
///
/// A String given with a range stands for the String `String::trim()` makes of those code units, which is the empty
/// String, 8-bit, when only whitespace remains. `firstCharacters` and `secondCharacters` are the Strings' 8-bit
/// characters.
private func fetchHeadersMakeString(
    _ prefix: borrowing [UInt8],
    _ first: borrowing WTF.String,
    _ firstCharacters: Span<UInt8>,
    _ firstRange: Range<Int>?,
    _ middle: borrowing [UInt8],
    _ second: borrowing WTF.String,
    _ secondCharacters: Span<UInt8>,
    _ secondRange: Range<Int>?,
    _ suffix: borrowing [UInt8]
) -> WTF.String {
    // checkedSpan16() is read only for a String with no 8-bit characters.
    let firstUnits: Span<UInt16> = firstCharacters.isEmpty ? first.checkedSpan16() : Span()
    let secondUnits: Span<UInt16> = secondCharacters.isEmpty ? second.checkedSpan16() : Span()
    // Each String is shorter than 2^31, so the sum cannot overflow.
    let length =
        prefix.count &+ (firstRange?.count ?? firstCharacters.count &+ firstUnits.count) &+ middle.count
        &+ (secondRange?.count ?? secondCharacters.count &+ secondUnits.count) &+ suffix.count
    if fetchHeadersIs8Bit(first, firstCharacters, firstUnits, firstRange),
        fetchHeadersIs8Bit(second, secondCharacters, secondUnits, secondRange)
    {
        return fetchHeadersConcatenation(
            UInt8.self,
            length,
            prefix.span,
            firstCharacters,
            firstUnits,
            firstRange,
            middle.span,
            secondCharacters,
            secondUnits,
            secondRange,
            suffix.span
        )
    }
    return fetchHeadersConcatenation(
        UInt16.self,
        length,
        prefix.span,
        firstCharacters,
        firstUnits,
        firstRange,
        middle.span,
        secondCharacters,
        secondUnits,
        secondRange,
        suffix.span
    )
}

/// Whether the String whose code units are `characters` or `units` is 8-bit or, with `range`, the String
/// `String::trim()` makes of those code units.
private func fetchHeadersIs8Bit(
    _ string: borrowing WTF.String,
    _ characters: Span<UInt8>,
    _ units: Span<UInt16>,
    _ range: Range<Int>?
) -> Bool {
    if !characters.isEmpty {
        return true
    }
    if units.isEmpty {
        return string.is8Bit()
    }
    if let range {
        return range.isEmpty
    }
    return false
}

private func fetchHeadersConcatenation<CodeUnit: HTTPHeaderStringCodeUnit & ConvertibleFromBytes>(
    _ codeUnit: CodeUnit.Type,
    _ length: Int,
    _ prefix: Span<UInt8>,
    _ firstCharacters: Span<UInt8>,
    _ firstUnits: Span<UInt16>,
    _ firstRange: Range<Int>?,
    _ middle: Span<UInt8>,
    _ secondCharacters: Span<UInt8>,
    _ secondUnits: Span<UInt16>,
    _ secondRange: Range<Int>?,
    _ suffix: Span<UInt8>
) -> WTF.String {
    crossOriginAccessControlMakeString(CodeUnit.self, length) { output in
        var offset = crossOriginAccessControlCopy(prefix, to: &output, at: 0)
        offset = fetchHeadersStoreString(firstCharacters, firstUnits, firstRange, &output, offset)
        offset = crossOriginAccessControlCopy(middle, to: &output, at: offset)
        offset = fetchHeadersStoreString(secondCharacters, secondUnits, secondRange, &output, offset)
        _ = crossOriginAccessControlCopy(suffix, to: &output, at: offset)
    }
}

/// Stores the code units of a String, `characters` or else `units`, all of them or those in `range`, in `output` from
/// `offset` on, and returns the offset after them.
private func fetchHeadersStoreString<CodeUnit: HTTPHeaderStringCodeUnit & ConvertibleFromBytes>(
    _ characters: Span<UInt8>,
    _ units: Span<UInt16>,
    _ range: Range<Int>?,
    _ output: inout MutableSpan<CodeUnit>,
    _ offset: Int
) -> Int {
    if !characters.isEmpty {
        return crossOriginAccessControlCopy(characters.extracting(range ?? characters.indices), to: &output, at: offset)
    }
    return crossOriginAccessControlCopy(units.extracting(range ?? units.indices), to: &output, at: offset)
}

/// `makeString(interleave(values, ", "_s))`, which StringBuilder makes: the only value itself (the empty String for
/// the null one), else the values joined with `", "`, 16-bit when the first value is, or when a later one is 16-bit
/// and neither empty nor a single Latin-1 character.
///
/// `values` is not empty.
private func fetchHeadersJoinedSetCookieValues(_ values: borrowing WebCore.SecurityPoliciesStringVector) -> WTF.String {
    let count = values.size()
    if count == 1 {
        if values[0].isNull() {
            return WTF.makeStringFromLatin1Characters(fetchHeadersNoCharacters.span)
        }
        return values[0]
    }

    // A Vector holds fewer than 2^32 Strings, each shorter than 2^31, so none of these sums can overflow.
    var length = 2 &* (count &- 1)
    var is8Bit = values[0].is8Bit()
    for index in 0..<count {
        let valueLength = Int(values[index].length())
        length &+= valueLength
        if index > 0, is8Bit, !values[index].is8Bit() {
            // StringBuilder stays 8-bit for an empty 16-bit String, and for one Latin-1 character.
            if valueLength > 1 {
                is8Bit = false
            } else if valueLength == 1 {
                let value = values[index]
                let characters: Span<UInt16> = value.checkedSpan16()
                if characters[0] > 0xFF {
                    is8Bit = false
                }
            }
        }
    }
    if is8Bit {
        return fetchHeadersJoinedSetCookieValues(UInt8.self, length, values)
    }
    return fetchHeadersJoinedSetCookieValues(UInt16.self, length, values)
}

private func fetchHeadersJoinedSetCookieValues<CodeUnit: HTTPHeaderStringCodeUnit & ConvertibleFromBytes>(
    _ codeUnit: CodeUnit.Type,
    _ length: Int,
    _ values: borrowing WebCore.SecurityPoliciesStringVector
) -> WTF.String {
    if length <= 256 {
        var buffer = InlineArray<256, CodeUnit>(repeating: 0)
        var output = buffer.mutableSpan
        fetchHeadersStoreJoinedValues(values, &output)
        return CodeUnit.httpHeaderString(output.span.extracting(first: length))
    }
    var buffer = UniqueArray<CodeUnit>(repeating: 0, count: length)
    var output = buffer.mutableSpan
    fetchHeadersStoreJoinedValues(values, &output)
    return CodeUnit.httpHeaderString(output.span)
}

private func fetchHeadersStoreJoinedValues<CodeUnit: HTTPHeaderStringCodeUnit & ConvertibleFromBytes>(
    _ values: borrowing WebCore.SecurityPoliciesStringVector,
    _ output: inout MutableSpan<CodeUnit>
) {
    var offset = 0
    for index in 0..<values.size() {
        if index > 0 {
            offset = crossOriginAccessControlCopy(fetchHeadersCommaSpace.span, to: &output, at: offset)
        }
        offset = fetchHeadersStoreValue(values[index], &output, offset)
    }
}

/// Stores the code units of `string` in `output` from `offset` on, and returns the offset after them.
private func fetchHeadersStoreValue<CodeUnit: HTTPHeaderStringCodeUnit & ConvertibleFromBytes>(
    _ string: borrowing WTF.String,
    _ output: inout MutableSpan<CodeUnit>,
    _ offset: Int
) -> Int {
    let characters: Span<UInt8> = WebCore.securityPoliciesSpan8(string)
    if !characters.isEmpty {
        return crossOriginAccessControlCopy(characters, to: &output, at: offset)
    }
    return crossOriginAccessControlCopy(string.checkedSpan16(), to: &output, at: offset)
}

private func fetchHeadersTypeError(_ message: consuming WTF.String) -> WebCore.Exception {
    WebCore.Exception(WebCore.ExceptionCode.TypeError, message)
}

private func fetchHeadersInvalidNameMessage(_ name: borrowing WTF.String) -> WTF.String {
    fetchHeadersMakeString(
        fetchHeadersInvalidNamePrefix,
        name,
        WebCore.securityPoliciesSpan8(name),
        nil,
        fetchHeadersQuote,
        WTF.String(),
        Span(),
        nil,
        fetchHeadersNoCharacters
    )
}

private func fetchHeadersImmutableMessage() -> WTF.String {
    WTF.makeStringFromLatin1Characters(fetchHeadersImmutableMessageCharacters.span)
}

private let fetchHeadersNoCharacters: [UInt8] = []
private let fetchHeadersCommaSpace: [UInt8] = Array(", ".utf8)
private let fetchHeadersQuote: [UInt8] = Array("'".utf8)
private let fetchHeadersInvalidNamePrefix: [UInt8] = Array("Invalid header name: '".utf8)
private let fetchHeadersInvalidValuePrefix: [UInt8] = Array("Header '".utf8)
private let fetchHeadersInvalidValueMiddle: [UInt8] = Array("' has invalid value: '".utf8)
private let fetchHeadersInvalidSetCookieValuePrefix: [UInt8] = Array("Header 'Set-Cookie' has invalid value: '".utf8)
private let fetchHeadersImmutableMessageCharacters: [UInt8] = Array("Headers object's guard is 'immutable'".utf8)
