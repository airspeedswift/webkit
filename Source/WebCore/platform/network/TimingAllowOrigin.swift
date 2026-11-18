// Copyright (C) 2021 Apple Inc. All rights reserved.
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
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

/// `passesTimingAllowOriginCheck()` for a resource of another scheme, host or port than `origin`, the initiator's
/// serialization: whether an item of the `Timing-Allow-Origin` value `header`, split at commas and trimmed of ASCII
/// whitespace other than form feed, is `*` or `origin`.
@_expose(Cxx)
func timingAllowOriginAllows(_ header: consuming WTF.String, _ origin: consuming WTF.String) -> Bool {
    // An empty value has no item.
    if header.isEmpty() {
        return false
    }
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(header)
    if !bytes.isEmpty {
        return timingAllowOriginAllows(bytes, origin)
    }
    let units: Span<UInt16> = header.checkedSpan16()
    return timingAllowOriginAllows(units, origin)
}

/// `passesNavigationTAOCheck()`: whether every list of `Timing-Allow-Origin` values in `list` has `*` or `origin`, the
/// destination's serialization.
///
/// `list` is the caller's list of values, which it passes by reference and does not change during the call. This
/// function reads it through its subscripts. The C++ functions it calls are `Vector`'s `size()` and `operator[]`,
/// `securityPoliciesSpan8()` and `String`'s `isNull()` and `checkedSpan16()`, and none reaches the list.
@_expose(Cxx)
func timingAllowOriginNavigationListAllows(
    _ list: borrowing WebCore.SecurityPoliciesStringVectorVector,
    _ origin: consuming WTF.String
) -> Bool {
    let count = list.size()
    if count == 0 {
        return true
    }
    // A list without values fails whatever the other lists hold, so the origin's code units are read once a list has
    // values.
    let first = list[0]
    let firstCount = first.size()
    if firstCount == 0 {
        return false
    }
    let originBytes: Span<UInt8> = WebCore.securityPoliciesSpan8(origin)
    if !originBytes.isEmpty {
        return timingAllowOriginNavigationListAllows(list, count, first, firstCount, originBytes, origin)
    }
    let originUnits: Span<UInt16> = origin.checkedSpan16()
    return timingAllowOriginNavigationListAllows(list, count, first, firstCount, originUnits, origin)
}

private func timingAllowOriginAllows<CodeUnit: HTTPHeaderStringCodeUnit>(_ header: Span<CodeUnit>, _ origin: borrowing WTF.String) -> Bool {
    typealias Units = HTTPHeaderCodeUnits
    var start = 0
    while start < header.count {
        let end = Units.find(0x2C, in: header, from: start)
        // StringView::split() skips an empty item before it would be trimmed.
        if end > start {
            let item = header.extracting(Units.trim(header, start..<end, Units.isASCIIWhitespaceWithoutFF))
            if crossOriginAccessControlEquals(item, "*") {
                return true
            }
            if crossOriginAccessControlEquals(item, origin) {
                return true
            }
        }
        start = end + 1
    }
    return false
}

// Whether each of the `count` lists of `list`, `first` being its first one, of `firstCount` values, has a value that is
// `*` or the origin, whose code units are `originCharacters`.
private func timingAllowOriginNavigationListAllows<OriginCodeUnit: HTTPHeaderStringCodeUnit>(
    _ list: borrowing WebCore.SecurityPoliciesStringVectorVector,
    _ count: Int,
    _ first: borrowing WebCore.SecurityPoliciesStringVector,
    _ firstCount: Int,
    _ originCharacters: Span<OriginCodeUnit>,
    _ origin: borrowing WTF.String
) -> Bool {
    if !timingAllowOriginValuesAllow(first, firstCount, originCharacters, origin) {
        return false
    }
    var index = 1
    while index < count {
        let values = list[index]
        let valueCount = values.size()
        if valueCount == 0 {
            return false
        }
        if !timingAllowOriginValuesAllow(values, valueCount, originCharacters, origin) {
            return false
        }
        index += 1
    }
    return true
}

// Whether one of the `count` values of `values` is `*` or the origin, whose code units are `originCharacters`. Each value
// is read once.
private func timingAllowOriginValuesAllow<OriginCodeUnit: HTTPHeaderStringCodeUnit>(
    _ values: borrowing WebCore.SecurityPoliciesStringVector,
    _ count: Int,
    _ originCharacters: Span<OriginCodeUnit>,
    _ origin: borrowing WTF.String
) -> Bool {
    var index = 0
    while index < count {
        let value = values[index]
        index += 1
        let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(value)
        if !bytes.isEmpty {
            if crossOriginAccessControlEquals(bytes, "*") || crossOriginAccessControlEquals(bytes, originCharacters) {
                return true
            }
            continue
        }
        let units: Span<UInt16> = value.checkedSpan16()
        if !units.isEmpty {
            if crossOriginAccessControlEquals(units, "*") || crossOriginAccessControlEquals(units, originCharacters) {
                return true
            }
            continue
        }
        // An empty value equals an empty origin when both or neither are null.
        if originCharacters.isEmpty {
            if value.isNull() == origin.isNull() {
                return true
            }
        }
    }
    return false
}
