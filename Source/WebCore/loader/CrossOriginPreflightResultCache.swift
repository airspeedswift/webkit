// Copyright (C) 2008, 2009 Apple Inc. All rights reserved.
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
//

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
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import WebCore_Private.Core.StoredCredentialsPolicy
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

/// `CrossOriginPreflightResultCacheItem::create()`: the null string when the preflight response's
/// `Access-Control-Allow-Methods` and `Access-Control-Allow-Headers` values are valid lists, with the time the entry
/// stays valid, in seconds, in `expiryDelta`; otherwise the error message. `maxAge` is the `Access-Control-Max-Age`
/// value.
@_expose(Cxx)
func crossOriginPreflightResultCacheItemFailure(
    _ allowMethods: consuming WTF.String,
    _ allowHeaders: consuming WTF.String,
    _ maxAge: consuming WTF.String,
    _ expiryDelta: inout Double
) -> WTF.String {
    if !crossOriginPreflightResultCacheIsValidList(allowMethods) {
        return crossOriginAccessControlMessage(crossOriginPreflightResultCacheInvalidMethodsPrefix.span, allowMethods, Span())
    }
    if !crossOriginPreflightResultCacheIsValidList(allowHeaders) {
        return crossOriginAccessControlMessage(crossOriginPreflightResultCacheInvalidHeadersPrefix.span, allowHeaders, Span())
    }

    // These values are at the discretion of the user agent. The maximum should be short enough to minimize the risk of
    // using a poisoned cache after switching to a secure network.
    let defaultPreflightCacheTimeout = 5.0
    let maxPreflightCacheTimeout = 600.0
    if let maxAgeValue = crossOriginPreflightResultCacheParseMaxAge(maxAge) {
        let delta = Double(maxAgeValue)
        expiryDelta = delta > maxPreflightCacheTimeout ? maxPreflightCacheTimeout : delta
    } else {
        expiryDelta = defaultPreflightCacheTimeout
    }
    return WTF.String()
}

/// `CrossOriginPreflightResultCacheItem::validateMethodAndHeaders()`: no message when the entry made from the
/// `Access-Control-Allow-Methods` value `allowMethods` and the `Access-Control-Allow-Headers` value `allowHeaders`,
/// under its own stored credentials policy `entryPolicy`, allows `method` and every header in `headers`; otherwise the
/// error message.
///
/// `headers` is the request's header map, which the caller passes by reference and does not change during the call.
/// This function reads it through its header spans and holds nothing of it past the call. The C++ functions it calls
/// are `HTTPHeaderMap::commonHeadersSpan()` and `uncommonHeadersSpan()`, `securityPoliciesHTTPHeaderNameString()`,
/// `securityPoliciesSpan8()`, `String`'s `checkedSpan16()` and `is8Bit()`, `makeStringFromLatin1Characters()`,
/// `makeStringFromUTF16Characters()` and the `SecurityPoliciesOptionalString` constructors, and none reaches the
/// request or the cache.
@_expose(Cxx)
func crossOriginPreflightResultCacheItemValidate(
    _ allowMethods: consuming WTF.String,
    _ allowHeaders: consuming WTF.String,
    _ entryPolicy: WebCore.StoredCredentialsPolicy,
    _ method: consuming WTF.String,
    _ headers: borrowing WebCore.HTTPHeaderMap
) -> WebCore.SecurityPoliciesOptionalString {
    if !crossOriginPreflightResultCacheAllowsMethod(allowMethods, method, entryPolicy) {
        return WebCore.SecurityPoliciesOptionalString(
            crossOriginAccessControlMessage(
                crossOriginPreflightResultCacheMethodPrefix.span,
                method,
                crossOriginPreflightResultCacheMethodSuffix.span
            )
        )
    }
    if let index = crossOriginPreflightResultCacheFirstDisallowedHeader(allowHeaders, headers, entryPolicy) {
        return WebCore.SecurityPoliciesOptionalString(crossOriginPreflightResultCacheHeaderMessage(headers, index))
    }
    return WebCore.SecurityPoliciesOptionalString()
}

/// `CrossOriginPreflightResultCacheItem::allowsRequest()` once the entry is known not to have expired: whether the entry
/// made from `allowMethods` and `allowHeaders` under `entryPolicy` allows a request with the stored credentials policy
/// `requestPolicy`, `method` and `headers`.
///
/// `headers` is the request's header map, which the caller passes by reference and does not change during the call.
/// This function reads it through its header spans and holds nothing of it past the call. The C++ functions it calls
/// are `HTTPHeaderMap::commonHeadersSpan()` and `uncommonHeadersSpan()`, `securityPoliciesHTTPHeaderNameString()`,
/// `securityPoliciesSpan8()` and `String::checkedSpan16()`, and none reaches the request or the cache.
@_expose(Cxx)
func crossOriginPreflightResultCacheItemAllowsRequest(
    _ allowMethods: consuming WTF.String,
    _ allowHeaders: consuming WTF.String,
    _ entryPolicy: WebCore.StoredCredentialsPolicy,
    _ requestPolicy: WebCore.StoredCredentialsPolicy,
    _ method: consuming WTF.String,
    _ headers: borrowing WebCore.HTTPHeaderMap
) -> Bool {
    if requestPolicy == .Use && entryPolicy == .DoNotUse {
        return false
    }
    if !crossOriginPreflightResultCacheAllowsMethod(allowMethods, method, requestPolicy) {
        return false
    }
    return crossOriginPreflightResultCacheFirstDisallowedHeader(allowHeaders, headers, requestPolicy) == nil
}

/// `"Header Access-Control-Allow-Methods has an invalid value: "`.
private let crossOriginPreflightResultCacheInvalidMethodsPrefix: [UInt8] = [
    0x48, 0x65, 0x61, 0x64, 0x65, 0x72, 0x20, 0x41, 0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x43, 0x6F, 0x6E, 0x74, 0x72, 0x6F,
    0x6C, 0x2D, 0x41, 0x6C, 0x6C, 0x6F, 0x77, 0x2D, 0x4D, 0x65, 0x74, 0x68, 0x6F, 0x64, 0x73, 0x20, 0x68, 0x61, 0x73, 0x20,
    0x61, 0x6E, 0x20, 0x69, 0x6E, 0x76, 0x61, 0x6C, 0x69, 0x64, 0x20, 0x76, 0x61, 0x6C, 0x75, 0x65, 0x3A, 0x20,
]

/// `"Header Access-Control-Allow-Headers has an invalid value: "`.
private let crossOriginPreflightResultCacheInvalidHeadersPrefix: [UInt8] = [
    0x48, 0x65, 0x61, 0x64, 0x65, 0x72, 0x20, 0x41, 0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x43, 0x6F, 0x6E, 0x74, 0x72, 0x6F,
    0x6C, 0x2D, 0x41, 0x6C, 0x6C, 0x6F, 0x77, 0x2D, 0x48, 0x65, 0x61, 0x64, 0x65, 0x72, 0x73, 0x20, 0x68, 0x61, 0x73, 0x20,
    0x61, 0x6E, 0x20, 0x69, 0x6E, 0x76, 0x61, 0x6C, 0x69, 0x64, 0x20, 0x76, 0x61, 0x6C, 0x75, 0x65, 0x3A, 0x20,
]

/// `"Method "`.
private let crossOriginPreflightResultCacheMethodPrefix: [UInt8] = [0x4D, 0x65, 0x74, 0x68, 0x6F, 0x64, 0x20]

/// `" is not allowed by Access-Control-Allow-Methods."`.
private let crossOriginPreflightResultCacheMethodSuffix: [UInt8] = [
    0x20, 0x69, 0x73, 0x20, 0x6E, 0x6F, 0x74, 0x20, 0x61, 0x6C, 0x6C, 0x6F, 0x77, 0x65, 0x64, 0x20, 0x62, 0x79, 0x20, 0x41,
    0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x43, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C, 0x2D, 0x41, 0x6C, 0x6C, 0x6F, 0x77, 0x2D,
    0x4D, 0x65, 0x74, 0x68, 0x6F, 0x64, 0x73, 0x2E,
]

/// `"Request header field "`.
private let crossOriginPreflightResultCacheHeaderPrefix: [UInt8] = [
    0x52, 0x65, 0x71, 0x75, 0x65, 0x73, 0x74, 0x20, 0x68, 0x65, 0x61, 0x64, 0x65, 0x72, 0x20, 0x66, 0x69, 0x65, 0x6C, 0x64,
    0x20,
]

/// `" is not allowed by Access-Control-Allow-Headers."`.
private let crossOriginPreflightResultCacheHeaderSuffix: [UInt8] = [
    0x20, 0x69, 0x73, 0x20, 0x6E, 0x6F, 0x74, 0x20, 0x61, 0x6C, 0x6C, 0x6F, 0x77, 0x65, 0x64, 0x20, 0x62, 0x79, 0x20, 0x41,
    0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x43, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C, 0x2D, 0x41, 0x6C, 0x6C, 0x6F, 0x77, 0x2D,
    0x48, 0x65, 0x61, 0x64, 0x65, 0x72, 0x73, 0x2E,
]

/// Whether `method` is in the list `allowMethods`, or the list has `*` and `policy` is not `Use`, or `method` is a
/// CORS-safelisted method.
private func crossOriginPreflightResultCacheAllowsMethod(
    _ allowMethods: borrowing WTF.String,
    _ method: borrowing WTF.String,
    _ policy: WebCore.StoredCredentialsPolicy
) -> Bool {
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(method)
    if !bytes.isEmpty {
        return crossOriginPreflightResultCacheAllowsMethod(allowMethods, bytes, policy)
    }
    let units: Span<UInt16> = method.checkedSpan16()
    return crossOriginPreflightResultCacheAllowsMethod(allowMethods, units, policy)
}

private func crossOriginPreflightResultCacheAllowsMethod<MethodCodeUnit: HTTPHeaderStringCodeUnit>(
    _ allowMethods: borrowing WTF.String,
    _ method: Span<MethodCodeUnit>,
    _ policy: WebCore.StoredCredentialsPolicy
) -> Bool {
    let wildcardAllowed = policy != .Use
    // An empty list has no token in either width.
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(allowMethods)
    if !bytes.isEmpty {
        if crossOriginPreflightResultCacheListAllows(bytes, method, ignoringASCIICase: false, wildcardAllowed) {
            return true
        }
    } else {
        let list: Span<UInt16> = allowMethods.checkedSpan16()
        if crossOriginPreflightResultCacheListAllows(list, method, ignoringASCIICase: false, wildcardAllowed) {
            return true
        }
    }
    return crossOriginAccessControlIsSimpleMethod(method)
}

/// The index of the first header in `headers`, counting its common headers first, that is neither a CORS-safelisted
/// request header nor in the list `allowHeaders` (ASCII case-insensitively), when the list does not have `*` or
/// `policy` is `Use`.
private func crossOriginPreflightResultCacheFirstDisallowedHeader(
    _ allowHeaders: borrowing WTF.String,
    _ headers: borrowing WebCore.HTTPHeaderMap,
    _ policy: WebCore.StoredCredentialsPolicy
) -> Int? {
    // An empty list has no token in either width.
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(allowHeaders)
    if !bytes.isEmpty {
        return crossOriginPreflightResultCacheFirstDisallowedHeader(bytes, headers, policy)
    }
    let units: Span<UInt16> = allowHeaders.checkedSpan16()
    return crossOriginPreflightResultCacheFirstDisallowedHeader(units, headers, policy)
}

private func crossOriginPreflightResultCacheFirstDisallowedHeader<ListCodeUnit: HTTPHeaderStringCodeUnit>(
    _ allowHeaders: Span<ListCodeUnit>,
    _ headers: borrowing WebCore.HTTPHeaderMap,
    _ policy: WebCore.StoredCredentialsPolicy
) -> Int? {
    let wildcardAllowed = policy != .Use
    let commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader> = headers.commonHeadersSpan()
    for index in commonHeaders.indices {
        if crossOriginAccessControlIsSafeRequestHeader(commonHeaders[index]) {
            continue
        }
        let key = WebCore.securityPoliciesHTTPHeaderNameString(commonHeaders[index].key)
        if !crossOriginPreflightResultCacheAllowsHeader(allowHeaders, key, wildcardAllowed: wildcardAllowed) {
            return index
        }
    }
    let uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader> = headers.uncommonHeadersSpan()
    for index in uncommonHeaders.indices {
        if !crossOriginPreflightResultCacheAllowsHeader(allowHeaders, uncommonHeaders[index].key, wildcardAllowed: wildcardAllowed) {
            // Two Vector sizes, each below 2^32: far from overflowing.
            return commonHeaders.count &+ index
        }
    }
    return nil
}

/// The message for the header at `index` of `headers`, counted as crossOriginPreflightResultCacheFirstDisallowedHeader()
/// counts them.
private func crossOriginPreflightResultCacheHeaderMessage(_ headers: borrowing WebCore.HTTPHeaderMap, _ index: Int) -> WTF.String {
    let prefix = crossOriginPreflightResultCacheHeaderPrefix.span
    let suffix = crossOriginPreflightResultCacheHeaderSuffix.span
    let commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader> = headers.commonHeadersSpan()
    if index < commonHeaders.count {
        let key = WebCore.securityPoliciesHTTPHeaderNameString(commonHeaders[index].key)
        return crossOriginAccessControlMessage(prefix, key, suffix)
    }
    let uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader> = headers.uncommonHeadersSpan()
    // At or after the common headers' count.
    return crossOriginAccessControlMessage(prefix, uncommonHeaders[index &- commonHeaders.count].key, suffix)
}

/// Whether the list `allowHeaders` has `key`, ASCII case-insensitively, or has `*` and `wildcardAllowed`.
private func crossOriginPreflightResultCacheAllowsHeader<ListCodeUnit: HTTPHeaderStringCodeUnit>(
    _ allowHeaders: Span<ListCodeUnit>,
    _ key: borrowing WTF.String,
    wildcardAllowed: Bool
) -> Bool {
    let characters: Span<UInt8> = WebCore.securityPoliciesSpan8(key)
    if !characters.isEmpty {
        return crossOriginPreflightResultCacheListAllows(allowHeaders, characters, ignoringASCIICase: true, wildcardAllowed)
    }
    let units: Span<UInt16> = key.checkedSpan16()
    return crossOriginPreflightResultCacheListAllows(allowHeaders, units, ignoringASCIICase: true, wildcardAllowed)
}

/// Whether the list `list` has a token equal to `string`, ASCII case-insensitively when `ignoringASCIICase`, or has the
/// token `*` when `wildcardAllowed`.
///
/// The list was validated when the entry was made, so its items are split at commas and trimmed without checking them
/// again: an item left empty is skipped, and every other is a token.
private func crossOriginPreflightResultCacheListAllows<
    ListCodeUnit: HTTPHeaderStringCodeUnit,
    StringCodeUnit: HTTPHeaderStringCodeUnit
>(
    _ list: Span<ListCodeUnit>,
    _ string: Span<StringCodeUnit>,
    ignoringASCIICase: Bool,
    _ wildcardAllowed: Bool
) -> Bool {
    typealias Units = HTTPHeaderCodeUnits
    var start = 0
    while start < list.count {
        let end = crossOriginAccessControlFindComma(list, from: start)
        let token = list.extracting(Units.trim(list, start..<end, Units.isASCIIWhitespaceWithoutFF))
        if !token.isEmpty {
            if ignoringASCIICase {
                if crossOriginAccessControlEqualsIgnoringASCIICase(token, string) {
                    return true
                }
            } else if crossOriginAccessControlEquals(token, string) {
                return true
            }
            if wildcardAllowed, token.count == 1, Units.value(token[0]) == 0x2A {
                return true
            }
        }
        // At most the list's count.
        start = end &+ 1
    }
    return false
}

/// The validity check of `parseAccessControlAllowList()`: whether every item of `list` is an HTTP token.
private func crossOriginPreflightResultCacheIsValidList(_ list: borrowing WTF.String) -> Bool {
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(list)
    if !bytes.isEmpty {
        return crossOriginPreflightResultCacheIsValidList(bytes)
    }
    let units: Span<UInt16> = list.checkedSpan16()
    return crossOriginPreflightResultCacheIsValidList(units)
}

private func crossOriginPreflightResultCacheIsValidList<CodeUnit: HTTPHeaderStringCodeUnit>(_ list: Span<CodeUnit>) -> Bool {
    var cursor = 0
    while true {
        switch AccessControlAllowListParsing.nextToken(list, from: cursor) {
        case .token(_, _, let next):
            cursor = next
        case .end:
            return true
        case .invalid:
            return false
        }
    }
}

/// `parseInteger<int64_t>()` of the `Access-Control-Max-Age` value: decimal digits after an optional `-` or `+`, with
/// Unicode-compatible ASCII whitespace before and after them. Nil when there are no digits, when anything else follows
/// them, or when the value does not fit.
// FIXME: This should probably reject strings that have a leading "+".
private func crossOriginPreflightResultCacheParseMaxAge(_ maxAge: borrowing WTF.String) -> Int64? {
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(maxAge)
    if !bytes.isEmpty {
        return crossOriginPreflightResultCacheParseMaxAge(bytes)
    }
    let units: Span<UInt16> = maxAge.checkedSpan16()
    return crossOriginPreflightResultCacheParseMaxAge(units)
}

private func crossOriginPreflightResultCacheParseMaxAge<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>
) -> Int64? {
    typealias Units = HTTPHeaderCodeUnits
    var index = 0
    while index < characters.count && Units.isUnicodeCompatibleASCIIWhitespace(Units.value(characters[index])) {
        index += 1
    }
    var isNegative = false
    if index < characters.count && Units.value(characters[index]) == 0x2D {
        isNegative = true
        index += 1
    } else if index < characters.count && Units.value(characters[index]) == 0x2B {
        index += 1
    }
    guard index < characters.count && Units.isASCIIDigit(Units.value(characters[index])) else {
        return nil
    }
    // Checked<int64_t, RecordOverflow>: once the value overflows, it stays invalid.
    var value: Int64 = 0
    var hasOverflowed = false
    repeat {
        let digit = Int64(Units.value(characters[index]) - 0x30)
        index += 1
        let (product, productOverflowed) = value.multipliedReportingOverflow(by: 10)
        let (sum, sumOverflowed) = isNegative ? product.subtractingReportingOverflow(digit) : product.addingReportingOverflow(digit)
        hasOverflowed = hasOverflowed || productOverflowed || sumOverflowed
        value = sum
    } while index < characters.count && Units.isASCIIDigit(Units.value(characters[index]))
    if hasOverflowed {
        return nil
    }
    while index < characters.count && Units.isUnicodeCompatibleASCIIWhitespace(Units.value(characters[index])) {
        index += 1
    }
    return index == characters.count ? value : nil
}
