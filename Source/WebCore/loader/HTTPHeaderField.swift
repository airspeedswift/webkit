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
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

/// `HTTPHeaderField::create()`: the extents of the name and the value with tabs and spaces trimmed, or a null extent for
/// one that is not valid (RFC 7230, section 3.2).
///
/// `name` and `value` are the characters of the caller's `String`s, which keep them allocated, at their length, for the
/// call; a `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and
/// every Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit name and value characters.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseHTTPHeaderField8And8(
    _ name: WebCore.HTTPHeaderLatin1Span,
    _ value: WebCore.HTTPHeaderLatin1Span
) -> WebCore.HTTPHeaderFieldExtents {
    let nameCharacters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(name))
    let valueCharacters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return httpHeaderFieldExtents(nameCharacters, valueCharacters)
}

/// parseHTTPHeaderField8And8() for 16-bit value characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseHTTPHeaderField8And16(
    _ name: WebCore.HTTPHeaderLatin1Span,
    _ value: WebCore.HTTPHeaderUTF16Span
) -> WebCore.HTTPHeaderFieldExtents {
    let nameCharacters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(name))
    let valueCharacters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return httpHeaderFieldExtents(nameCharacters, valueCharacters)
}

/// parseHTTPHeaderField8And8() for 16-bit name characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseHTTPHeaderField16And8(
    _ name: WebCore.HTTPHeaderUTF16Span,
    _ value: WebCore.HTTPHeaderLatin1Span
) -> WebCore.HTTPHeaderFieldExtents {
    let nameCharacters = unsafe Span<UInt16>(_unsafeCxxSpan: name)
    let valueCharacters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return httpHeaderFieldExtents(nameCharacters, valueCharacters)
}

/// parseHTTPHeaderField8And8() for 16-bit name and value characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseHTTPHeaderField16And16(
    _ name: WebCore.HTTPHeaderUTF16Span,
    _ value: WebCore.HTTPHeaderUTF16Span
) -> WebCore.HTTPHeaderFieldExtents {
    let nameCharacters = unsafe Span<UInt16>(_unsafeCxxSpan: name)
    let valueCharacters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return httpHeaderFieldExtents(nameCharacters, valueCharacters)
}

private func httpHeaderFieldExtents<NameCodeUnit: HTTPHeaderStringCodeUnit, ValueCodeUnit: HTTPHeaderStringCodeUnit>(
    _ name: Span<NameCodeUnit>,
    _ value: Span<ValueCodeUnit>
) -> WebCore.HTTPHeaderFieldExtents {
    guard let field = HTTPHeaderFieldParsing.create(name: name, value: value) else {
        let null = WebCore.HTTPHeaderExtent(start: 0, length: 0, isNull: true)
        return WebCore.HTTPHeaderFieldExtents(name: null, value: null)
    }
    return WebCore.HTTPHeaderFieldExtents(
        name: httpHeaderExtent(HTTPHeaderSubstringExtent(start: field.name.start, length: field.name.length)),
        value: httpHeaderExtent(HTTPHeaderSubstringExtent(start: field.value.start, length: field.value.length))
    )
}

/// `HTTPHeaderField::create` and the RFC 7230 grammar it checks names and values against.
enum HTTPHeaderFieldParsing {
    private typealias Units = HTTPHeaderCodeUnits

    /// `HTTPHeaderField::create`: the name and the value trimmed of tabs and spaces, as extents of their arguments,
    /// or nil when the name is not a token or the value is not a valid field value.
    static func create<NameCodeUnit: HTTPHeaderStringCodeUnit, ValueCodeUnit: HTTPHeaderStringCodeUnit>(
        name: Span<NameCodeUnit>,
        value: Span<ValueCodeUnit>
    ) -> (name: (start: Int, length: Int), value: (start: Int, length: Int))? {
        let trimmedName = Units.trim(name, name.indices, Units.isTabOrSpace)
        let trimmedValue = Units.trim(value, value.indices, Units.isTabOrSpace)
        guard isValidName(name.extracting(trimmedName)), isValidValue(value.extracting(trimmedValue)) else {
            return nil
        }
        return ((trimmedName.lowerBound, trimmedName.count), (trimmedValue.lowerBound, trimmedValue.count))
    }

    /// A non-empty token.
    static func isValidName<CodeUnit: HTTPHeaderStringCodeUnit>(_ name: Span<CodeUnit>) -> Bool {
        if name.isEmpty {
            return false
        }
        return Units.containsOnly(HTTPHeaderTokenCharacters.self, in: name, from: 0, to: name.count)
    }

    private enum State {
        case optionalWhitespace
        case token
        case quotedString
        case comment
    }

    /// A field value: RFC 7230, sections 3.2 and 3.2.6.
    static func isValidValue<CodeUnit: HTTPHeaderStringCodeUnit>(_ value: Span<CodeUnit>) -> Bool {
        // From 16 code units, isValidLongValue() looks at a token's code units after its first 16, 16 at a time.
        if value.count >= 16 {
            return isValidLongValue(value)
        }
        return isValidValue(value, skippingTokenRuns: false)
    }

    @inline(never)
    private static func isValidLongValue<CodeUnit: HTTPHeaderStringCodeUnit>(_ value: Span<CodeUnit>) -> Bool {
        isValidValue(value, skippingTokenRuns: true)
    }

    /// The index of the first code unit after the token that starts at `start`, or the count. The token's first 16 code
    /// units are looked at one at a time, and any after them 16 at a time.
    @inline(always)
    private static func tokenEnd<CodeUnit: HTTPHeaderStringCodeUnit>(_ value: Span<CodeUnit>, from start: Int) -> Int {
        // Cannot overflow: `start` is below the count, which is below 2^32.
        let firstCodeUnitsEnd = min(start &+ 16, value.count)
        var index = start + 1
        while index < firstCodeUnitsEnd {
            if !Units.isTokenCharacter(Units.value(value[index])) {
                return index
            }
            index += 1
        }
        return Units.firstIndex(notOf: HTTPHeaderTokenCharacters.self, in: value, from: index, to: value.count)
    }

    @inline(always)
    private static func isValidValue<CodeUnit: HTTPHeaderStringCodeUnit>(_ value: Span<CodeUnit>, skippingTokenRuns: Bool) -> Bool {
        var state = State.optionalWhitespace
        var commentDepth = 0
        var hadNonWhitespace = false
        // A backslash in a quoted string or a comment takes the next code unit as the second octet of a quoted pair.
        var inQuotedPair = false

        var index = 0
        while index < value.count {
            let c = Units.value(value[index])
            index += 1
            if inQuotedPair {
                if !Units.isQuotedPairSecondOctet(c) {
                    return false
                }
                inQuotedPair = false
                continue
            }
            switch state {
            case .optionalWhitespace:
                if Units.isTabOrSpace(c) {
                    continue
                }
                hadNonWhitespace = true
                if Units.isTokenCharacter(c) {
                    state = .token
                    if skippingTokenRuns {
                        // The token's other code units leave the state as it is.
                        index = tokenEnd(value, from: index - 1)
                    }
                    continue
                }
                if c == 0x22 {
                    state = .quotedString
                    continue
                }
                if c == 0x28 {
                    assert(commentDepth == 0)
                    commentDepth = 1
                    state = .comment
                    continue
                }
                return false
            case .token:
                if Units.isTokenCharacter(c) {
                    continue
                }
                if !Units.isTabOrSpace(c) && !Units.isVisibleCharacter(c) && !Units.isOBSText(c) {
                    return false
                }
                state = .optionalWhitespace
            case .quotedString:
                if c == 0x22 {
                    state = .optionalWhitespace
                    continue
                }
                if c == 0x5C {
                    inQuotedPair = true
                    continue
                }
                if !Units.isQuotedTextCharacter(c) {
                    return false
                }
            case .comment:
                if c == 0x28 {
                    // Cannot overflow: the depth is at most the number of code units read.
                    commentDepth &+= 1
                    continue
                }
                if c == 0x29 {
                    // Cannot overflow: the depth is at least 1 in a comment.
                    commentDepth &-= 1
                    if commentDepth == 0 {
                        state = .optionalWhitespace
                    }
                    continue
                }
                if c == 0x5C {
                    inQuotedPair = true
                    continue
                }
                if !Units.isCommentText(c) {
                    return false
                }
            }
        }
        // A backslash at the end has no second octet.
        if inQuotedPair {
            return false
        }

        switch state {
        case .optionalWhitespace, .token:
            return hadNonWhitespace
        case .quotedString, .comment:
            // Unclosed comments or quotes are invalid values.
            return false
        }
    }
}
