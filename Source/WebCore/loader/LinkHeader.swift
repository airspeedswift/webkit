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

/// `LinkHeaderSet(const String&)`: the link-value at `start`, with `start` moved to where the next starts.
///
/// `header` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseLinkHeader8(_ header: WebCore.HTTPHeaderLatin1Span, _ start: inout UInt32) -> WebCore.LinkHeader {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(header))
    return WebCore.LinkHeader.parsed(characters, &start)
}

/// parseLinkHeader8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseLinkHeader16(_ header: WebCore.HTTPHeaderUTF16Span, _ start: inout UInt32) -> WebCore.LinkHeader {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: header)
    return WebCore.LinkHeader.parsed(characters, &start)
}

extension WebCore.LinkHeader {
    /// The members a link-value sets; the others stay the null string.
    @inline(always)
    fileprivate static func parsed<CodeUnit: HTTPHeaderStringCodeUnit>(
        _ characters: Span<CodeUnit>,
        _ start: inout UInt32
    ) -> WebCore.LinkHeader {
        var header = WebCore.LinkHeader()
        start = UInt32(truncatingIfNeeded: linkHeaderParse(characters, from: Int(start), into: &header))
        return header
    }
}

// The Link header (https://tools.ietf.org/html/rfc8288#section-3), one link-value per call, over Latin-1 (UInt8)
// or UTF-16 (UInt16) code units.

// Parses the link-value at position into header, valid or not, and returns where the next one starts. Each call
// consumes at least one code unit.
@inline(never)
func linkHeaderParse<C: HTTPHeaderStringCodeUnit>(_ input: Span<C>, from position: Int, into header: inout WebCore.LinkHeader) -> Int {
    var parser = LinkHeaderParser(position: position)
    header.parse(input, &parser)
    parser.findNextHeader(input)
    return parser.position
}

private enum LinkHeaderParameterName: UInt8 {
    case rel
    case anchor
    case title
    case media
    case type
    case rev
    case hreflang
    // Beyond this point, only link-extension parameters, which need no value.
    case unknown
    case crossOrigin
    case `as`
    case imageSrcSet
    case imageSizes
    case nonce
    case referrerPolicy
    case fetchPriority

    var isExtension: Bool { rawValue >= LinkHeaderParameterName.unknown.rawValue }
}

@inline(always)
private func linkHeaderIsParameterValueEnd<C: FixedWidthInteger & UnsignedInteger>(_ character: C) -> Bool {
    character == 0x3B || character == 0x2C // ';' or ','
}

// attr-char (https://tools.ietf.org/html/rfc5987) as tested here: '^' to 'z', 'A' to 'Z', '0' to '9', '!' to '$', '&',
// '+', '-' and '.', so '"' is accepted and '|' and '~' are not. Bit c % 64 of the first mask is set for each such c below
// 0x40, and of the second for each from 0x40 to 0x7F.
@inline(always)
private func linkHeaderIsValidParameterNameCharacter<C: FixedWidthInteger & UnsignedInteger>(_ character: C) -> Bool {
    let c = UInt64(truncatingIfNeeded: character)
    let mask: UInt64 = c < 0x40 ? 0x03FF_685E_0000_0000 : 0x07FF_FFFF_C7FF_FFFE
    return c < 0x80 && (mask >> (c & 0x3F)) & 1 != 0
}

// A word is the 8 Latin-1 or 4 UTF-16 code units at a position, read as one little-endian UInt64, so the first is in its
// low bits. Each code unit is compared whole: a UTF-16 one whose low byte is a delimiter is not that delimiter.

// The lowest bit of each code unit of a word.
@inline(always)
private func linkHeaderWordLowBits<C: FixedWidthInteger & UnsignedInteger>(_: C.Type) -> UInt64 {
    C.bitWidth == 8 ? 0x0101_0101_0101_0101 : 0x0001_0001_0001_0001
}

// The highest bit of each code unit of word that is character. Code units after the first such one may have it set too,
// so only the lowest bit set is exact.
@inline(always)
private func linkHeaderWordMatches<C: FixedWidthInteger & UnsignedInteger>(_ word: UInt64, _ character: C) -> UInt64 {
    let lowBits = linkHeaderWordLowBits(C.self)
    let difference = word ^ (lowBits * UInt64(truncatingIfNeeded: character))
    // The subtraction borrows out of each code unit of difference that is zero, and out of the word when the last one
    // is, which wraps on purpose.
    return (difference &- lowBits) & ~difference & (lowBits << (C.bitWidth - 1))
}

private func linkHeaderParameterName<C: FixedWidthInteger & UnsignedInteger>(
    _ input: Span<C>,
    _ start: Int,
    _ length: Int
) -> LinkHeaderParameterName {
    guard length > 0 else {
        return .unknown
    }
    let name = HTTPHeaderSubstringExtent(start: start, length: length)
    // The one name with this length and first letter, in either case; rel and rev share both.
    switch length << 8 | Int(HTTPHeaderCodeUnits.value(input[start]) | 0x20) {
    case 2 << 8 | 0x61: // 'a'
        return HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(input, name, "as") ? .as : .unknown
    case 3 << 8 | 0x72: // 'r'
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(input, name, "rel") {
            return .rel
        }
        return HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(input, name, "rev") ? .rev : .unknown
    case 4 << 8 | 0x74: // 't'
        return HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(input, name, "type") ? .type : .unknown
    case 5 << 8 | 0x74: // 't'
        return HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(input, name, "title") ? .title : .unknown
    case 5 << 8 | 0x6D: // 'm'
        return HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(input, name, "media") ? .media : .unknown
    case 5 << 8 | 0x6E: // 'n'
        return HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(input, name, "nonce") ? .nonce : .unknown
    case 6 << 8 | 0x61: // 'a'
        return HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(input, name, "anchor") ? .anchor : .unknown
    case 8 << 8 | 0x68: // 'h'
        return HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(input, name, "hreflang") ? .hreflang : .unknown
    case 10 << 8 | 0x69: // 'i'
        return HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(input, name, "imagesizes") ? .imageSizes : .unknown
    case 11 << 8 | 0x63: // 'c'
        return HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(input, name, "crossorigin") ? .crossOrigin : .unknown
    case 11 << 8 | 0x69: // 'i'
        return HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(input, name, "imagesrcset") ? .imageSrcSet : .unknown
    case 13 << 8 | 0x66: // 'f'
        return HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(input, name, "fetchpriority") ? .fetchPriority : .unknown
    case 14 << 8 | 0x72: // 'r'
        return HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(input, name, "referrerpolicy") ? .referrerPolicy : .unknown
    default:
        return .unknown
    }
}

private struct LinkHeaderParser {
    var position: Int

    // Whether the position is within the input: the comparison the span's subscript makes, so the compiler can drop
    // the subscript's own check.
    @inline(always)
    func hasCharacter<C: FixedWidthInteger & UnsignedInteger>(_ input: Span<C>) -> Bool {
        UInt(bitPattern: position) < UInt(bitPattern: input.count)
    }

    mutating func skipTabsAndSpaces<C: FixedWidthInteger & UnsignedInteger>(_ input: Span<C>) {
        while hasCharacter(input) && HTTPHeaderCodeUnits.isTabOrSpace(HTTPHeaderCodeUnits.value(input[position])) {
            position += 1
        }
    }

    mutating func skipUntil<C: HTTPHeaderStringCodeUnit>(_ input: Span<C>, _ character: C) {
        skipUntilMatch(input, { linkHeaderWordMatches($0, character) }, { $0 == character })
    }

    // An unquoted parameter value's end: a tab, a space, ';' or ','.
    mutating func skipUntilUnquotedValueEnd<C: HTTPHeaderStringCodeUnit>(_ input: Span<C>) {
        skipUntilMatch(
            input,
            { word in
                linkHeaderWordMatches(word, 0x09 as C) | linkHeaderWordMatches(word, 0x20 as C) | linkHeaderWordMatches(word, 0x3B as C)
                    | linkHeaderWordMatches(word, 0x2C as C)
            },
            { HTTPHeaderCodeUnits.isTabOrSpace(HTTPHeaderCodeUnits.value($0)) || linkHeaderIsParameterValueEnd($0) }
        )
    }

    // Moves to the first code unit at or after the position that isMatch accepts, or to the end: a word at a time, where
    // wordMatches marks the code units of a word that isMatch accepts as linkHeaderWordMatches() does, then one at a time
    // for the last ones, fewer than a word.
    @inline(always)
    mutating func skipUntilMatch<C: HTTPHeaderStringCodeUnit>(_ input: Span<C>, _ wordMatches: (UInt64) -> UInt64, _ isMatch: (C) -> Bool) {
        let bytes = input.bytes
        let codeUnitsPerWord = 8 / MemoryLayout<C>.size
        // Positions here are at most a String's length, below 2^32, so wrapping arithmetic cannot wrap.
        while position &+ codeUnitsPerWord <= input.count {
            // The position is within the span, whose bytes fit in an Int, so this cannot overflow.
            let matches = wordMatches(UInt64(littleEndian: bytes.load(fromByteOffset: position &* MemoryLayout<C>.size, as: UInt64.self)))
            if matches != 0 {
                position &+= matches.trailingZeroBitCount / C.bitWidth
                return
            }
            position &+= codeUnitsPerWord
        }
        while hasCharacter(input) && !isMatch(input[position]) {
            position += 1
        }
    }

    mutating func skipExactly<C: FixedWidthInteger & UnsignedInteger>(_ input: Span<C>, _ character: C) -> Bool {
        guard hasCharacter(input) && input[position] == character else {
            return false
        }
        position += 1
        return true
    }

    // Skips to the next ',' with no regard for quotes, and over it.
    mutating func findNextHeader<C: HTTPHeaderStringCodeUnit>(_ input: Span<C>) {
        skipUntil(input, 0x2C) // ','
        _ = skipExactly(input, 0x2C)
    }

    // The URL between '<' and '>', after any tabs and spaces that follow the '<'.
    mutating func findURLBoundaries<C: HTTPHeaderStringCodeUnit>(_ input: Span<C>) -> Range<Int>? {
        skipTabsAndSpaces(input)
        guard skipExactly(input, 0x3C) else { // '<'
            return nil
        }
        skipTabsAndSpaces(input)
        let urlStart = position
        skipUntil(input, 0x3E) // '>'
        let urlEnd = position
        guard skipExactly(input, 0x3E) else {
            return nil
        }
        return urlStart..<urlEnd
    }

    // The quoted part of a parameter value: whether one starts here, and whether a quote that no backslash
    // precedes ends it.
    mutating func skipQuotesIfNeeded<C: HTTPHeaderStringCodeUnit>(_ input: Span<C>, _ completeQuotes: inout Bool) -> Bool {
        let quote: C
        if skipExactly(input, 0x27) { // '''
            quote = 0x27
        } else if skipExactly(input, 0x22) { // '"'
            quote = 0x22
        } else {
            return false
        }
        while !completeQuotes && hasCharacter(input) {
            skipUntil(input, quote)
            // The opening quote is before the position, so this cannot overflow.
            if input[position &- 1] != 0x5C { // '\'
                completeQuotes = true
            }
            completeQuotes = skipExactly(input, quote) && completeQuotes
        }
        return true
    }

    // The value is the raw text, without unescaping; an unquoted value ends at a tab, a space, ';' or ','. Returns
    // false for a malformed value, which is then the empty string, and for an unterminated quoted one, which is then
    // the text after the quote.
    mutating func parseParameterValue<C: HTTPHeaderStringCodeUnit>(_ input: Span<C>, _ value: inout Range<Int>) -> Bool {
        var valueStart = position
        var completeQuotes = false
        let hasQuotes = skipQuotesIfNeeded(input, &completeQuotes)
        if !hasQuotes {
            skipUntilUnquotedValueEnd(input)
        }
        // The position only advances from valueStart.
        var valueLength = position &- valueStart
        skipTabsAndSpaces(input)
        if (!completeQuotes && valueLength == 0) || (hasCharacter(input) && !linkHeaderIsParameterValueEnd(input[position])) {
            value = valueStart..<valueStart
            return false
        }
        // A quoted value has its opening quote, and a complete one its closing quote too, in the text, so these
        // cannot overflow.
        if hasQuotes {
            valueStart &+= 1
            valueLength &-= 1
        }
        if completeQuotes {
            valueLength &-= 1
        }
        // The value ends at or before the position.
        value = valueStart..<valueStart &+ valueLength
        return !hasQuotes || completeQuotes
    }
}

extension WebCore.LinkHeader {
    // Sets each member as its parameter is read: the first rel, and the last of each other one. A member starts as
    // the null string and is never null once set, so hasRel is whether m_rel is set.
    fileprivate mutating func parse<C: HTTPHeaderStringCodeUnit>(_ input: Span<C>, _ parser: inout LinkHeaderParser) {
        guard let url = parser.findURLBoundaries(input) else {
            m_isValid = false
            return
        }
        C.httpHeaderAssignString(&m_url, input.extracting(url))

        var hasRel = false
        while m_isValid && parser.hasCharacter(input) {
            // The parameter delimiter: a ';', or the end of the link-value, which ends it validly.
            parser.skipTabsAndSpaces(input)
            if !parser.skipExactly(input, 0x3B) && parser.hasCharacter(input) && input[parser.position] != 0x2C { // ';' and ','
                m_isValid = false
                return
            }
            parser.skipTabsAndSpaces(input)
            if !parser.hasCharacter(input) || input[parser.position] == 0x2C {
                return
            }

            let nameStart = parser.position
            while parser.hasCharacter(input) && linkHeaderIsValidParameterNameCharacter(input[parser.position]) {
                parser.position += 1
            }
            let nameEnd = parser.position
            parser.skipTabsAndSpaces(input)
            let hasEqual = parser.skipExactly(input, 0x3D) // '='
            parser.skipTabsAndSpaces(input)
            let name = linkHeaderParameterName(input, nameStart, nameEnd - nameStart)
            if !hasEqual {
                let validParameterValueEnd = !parser.hasCharacter(input) || linkHeaderIsParameterValueEnd(input[parser.position])
                if !(validParameterValueEnd && name.isExtension) {
                    m_isValid = false
                    return
                }
            }

            var value = 0..<0
            if !parser.parseParameterValue(input, &value) && !name.isExtension {
                m_isValid = false
                return
            }

            switch name {
            case .rel:
                if !hasRel {
                    C.httpHeaderAssignString(&m_rel, input.extracting(value))
                    hasRel = true
                }
            case .anchor:
                m_isValid = false
            case .crossOrigin:
                C.httpHeaderAssignString(&m_crossOrigin, input.extracting(value))
            case .as:
                C.httpHeaderAssignString(&m_as, input.extracting(value))
            case .type:
                C.httpHeaderAssignString(&m_mimeType, input.extracting(value))
            case .media:
                C.httpHeaderAssignString(&m_media, input.extracting(value))
            case .imageSrcSet:
                C.httpHeaderAssignString(&m_imageSrcSet, input.extracting(value))
            case .imageSizes:
                C.httpHeaderAssignString(&m_imageSizes, input.extracting(value))
            case .nonce:
                C.httpHeaderAssignString(&m_nonce, input.extracting(value))
            case .referrerPolicy:
                C.httpHeaderAssignString(&m_referrerPolicy, input.extracting(value))
            case .fetchPriority:
                C.httpHeaderAssignString(&m_fetchPriority, input.extracting(value))
            case .title, .rev, .hreflang, .unknown:
                break
            }
        }
    }
}
