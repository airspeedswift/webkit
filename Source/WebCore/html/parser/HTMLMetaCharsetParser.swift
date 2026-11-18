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

// WebCore_Private.Core's headers use types defined in these JavaScriptCore_Private.Cxx submodules and in
// wtf.Core.Stopwatch.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch
internal import wtf.Core.StdLibExtras
internal import WebCore_Private.Core.HTMLMicrosyntaxesSwiftTypes

// The functions exposed to C++ only make Spans of their arguments and call a function marked @inline(never). That
// keeps them small enough for link-time optimization to inline them into their C++ caller, where the std::span
// accessors they call are inlined too.

/// Reads one attribute of a <meta> tag for the tag's character encoding, as encodingFromMetaAttributes() does in
/// its loop, and returns false when the attribute ends the loop.
///
/// `scan` starts zeroed and holds what the attributes before it gave, and `index` is the attribute's index. There is
/// one function for each width of the name and of the value; this one takes an 8-bit name and an 8-bit value. `name`
/// and `value` are the characters of the caller's views of the attribute's name and value. The views point into an
/// HTMLToken's attribute vectors, or into PageSerializer's strings, which stay allocated and unchanged for the call,
/// since the caller holds them and this function only reads them and passes them to no C++, and every value of a
/// Latin-1 or UTF-16 code unit is a valid character.
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxScanMetaCharsetAttributeName8Value8(
    _ scan: inout WebCore.HTMLMicrosyntaxMetaCharsetScan,
    _ index: UInt32,
    _ name: WebCore.HTMLMicrosyntaxSpan8,
    _ value: WebCore.HTMLMicrosyntaxSpan8
) -> Bool {
    let nameSpan = unsafe Span<WTF.Latin1Character>(_unsafeCxxSpan: name)
    let valueSpan = unsafe Span<WTF.Latin1Character>(_unsafeCxxSpan: value)
    return scanMetaCharsetAttribute(&scan, index, nameSpan, valueSpan)
}

/// htmlMicrosyntaxScanMetaCharsetAttributeName8Value8() for an 8-bit name and a 16-bit value, whose name and value hold
/// for the call in the same way.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxScanMetaCharsetAttributeName8Value16(
    _ scan: inout WebCore.HTMLMicrosyntaxMetaCharsetScan,
    _ index: UInt32,
    _ name: WebCore.HTMLMicrosyntaxSpan8,
    _ value: WebCore.HTMLMicrosyntaxSpan16
) -> Bool {
    let nameSpan = unsafe Span<WTF.Latin1Character>(_unsafeCxxSpan: name)
    let valueSpan = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return scanMetaCharsetAttribute(&scan, index, nameSpan, valueSpan)
}

/// htmlMicrosyntaxScanMetaCharsetAttributeName8Value8() for a 16-bit name and an 8-bit value, whose name and value hold
/// for the call in the same way.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxScanMetaCharsetAttributeName16Value8(
    _ scan: inout WebCore.HTMLMicrosyntaxMetaCharsetScan,
    _ index: UInt32,
    _ name: WebCore.HTMLMicrosyntaxSpan16,
    _ value: WebCore.HTMLMicrosyntaxSpan8
) -> Bool {
    let nameSpan = unsafe Span<UInt16>(_unsafeCxxSpan: name)
    let valueSpan = unsafe Span<WTF.Latin1Character>(_unsafeCxxSpan: value)
    return scanMetaCharsetAttribute(&scan, index, nameSpan, valueSpan)
}

/// htmlMicrosyntaxScanMetaCharsetAttributeName8Value8() for a 16-bit name and a 16-bit value, whose name and value hold
/// for the call in the same way.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxScanMetaCharsetAttributeName16Value16(
    _ scan: inout WebCore.HTMLMicrosyntaxMetaCharsetScan,
    _ index: UInt32,
    _ name: WebCore.HTMLMicrosyntaxSpan16,
    _ value: WebCore.HTMLMicrosyntaxSpan16
) -> Bool {
    let nameSpan = unsafe Span<UInt16>(_unsafeCxxSpan: name)
    let valueSpan = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return scanMetaCharsetAttribute(&scan, index, nameSpan, valueSpan)
}

@inline(never)
private func scanMetaCharsetAttribute<NameCodeUnit: HTMLMicrosyntaxCodeUnit, ValueCodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ scan: inout WebCore.HTMLMicrosyntaxMetaCharsetScan,
    _ index: UInt32,
    _ name: Span<NameCodeUnit>,
    _ value: Span<ValueCodeUnit>
) -> Bool {
    scan.read(MetaCharsetAttributeName(name), index, value)
}

/// The names of the attributes encodingFromMetaAttributes() reads.
///
/// They are compared exactly, since the tokenizer lowercases attribute names.
private enum MetaCharsetAttributeName {
    case httpEquiv
    case charset
    case content
    case other

    @inline(always)
    init<CodeUnit: HTMLMicrosyntaxCodeUnit>(_ name: Span<CodeUnit>) {
        switch name.count {
        case 7:
            if name[0].htmlMicrosyntaxMatches("c"), name[1].htmlMicrosyntaxMatches("h"), name[2].htmlMicrosyntaxMatches("a"),
                name[3].htmlMicrosyntaxMatches("r"), name[4].htmlMicrosyntaxMatches("s"), name[5].htmlMicrosyntaxMatches("e"),
                name[6].htmlMicrosyntaxMatches("t")
            {
                self = .charset
            } else if name[0].htmlMicrosyntaxMatches("c"), name[1].htmlMicrosyntaxMatches("o"), name[2].htmlMicrosyntaxMatches("n"),
                name[3].htmlMicrosyntaxMatches("t"), name[4].htmlMicrosyntaxMatches("e"), name[5].htmlMicrosyntaxMatches("n"),
                name[6].htmlMicrosyntaxMatches("t")
            {
                self = .content
            } else {
                self = .other
            }
        case 10:
            if name[0].htmlMicrosyntaxMatches("h"), name[1].htmlMicrosyntaxMatches("t"), name[2].htmlMicrosyntaxMatches("t"),
                name[3].htmlMicrosyntaxMatches("p"), name[4].htmlMicrosyntaxMatches("-"), name[5].htmlMicrosyntaxMatches("e"),
                name[6].htmlMicrosyntaxMatches("q"), name[7].htmlMicrosyntaxMatches("u"), name[8].htmlMicrosyntaxMatches("i"),
                name[9].htmlMicrosyntaxMatches("v")
            {
                self = .httpEquiv
            } else {
                self = .other
            }
        default:
            self = .other
        }
    }
}

/// encodingFromMetaAttributes()'s modes, as HTMLMicrosyntaxMetaCharsetScan's mode holds them.
private enum MetaCharsetMode: UInt8 {
    case none = 0
    case charset
    case pragma
}

extension WebCore.HTMLMicrosyntaxMetaCharsetScan {
    @inline(always)
    fileprivate mutating func read<CodeUnit: HTMLMicrosyntaxCodeUnit>(
        _ name: MetaCharsetAttributeName,
        _ index: UInt32,
        _ value: Span<CodeUnit>
    ) -> Bool {
        switch name {
        case .httpEquiv:
            if value.isContentTypeIgnoringCaseOfLetters {
                gotPragma = true
            }
        case .charset:
            setCharset(index, value.trimmingASCIIWhitespace(0..<value.count))
            mode = MetaCharsetMode.charset.rawValue
            // Charset attribute takes precedence
            hasEncoding = true
            return false
        case .content:
            let charset = value.charsetInContentType()
            setCharset(index, value.trimmingASCIIWhitespace(charset))
            if !charset.isEmpty {
                mode = MetaCharsetMode.pragma.rawValue
            }
        case .other:
            break
        }
        hasEncoding = mode == MetaCharsetMode.charset.rawValue || (mode == MetaCharsetMode.pragma.rawValue && gotPragma)
        return true
    }

    private mutating func setCharset(_ index: UInt32, _ range: Range<Int>) {
        attribute = index
        // A value's length, and so every index into it, fits in 32 bits.
        start = UInt32(truncatingIfNeeded: range.lowerBound)
        // Cannot overflow: both bounds index the value.
        length = UInt32(truncatingIfNeeded: range.upperBound &- range.lowerBound)
    }
}

extension HTMLMicrosyntaxCodeUnit {
    /// Whether this is `lowercaseCharacter` once the 0x20 bit is set, which for a letter is ignoring ASCII case.
    @inline(always)
    fileprivate func matchesWithBit0x20(_ lowercaseCharacter: Unicode.Scalar) -> Bool {
        htmlMicrosyntaxCodeUnit | 0x20 == UInt16(truncatingIfNeeded: lowercaseCharacter.value)
    }
}

extension Span where Element: HTMLMicrosyntaxCodeUnit {
    /// Whether the characters are "content-type" as equalLettersIgnoringASCIICase() compares them: each character
    /// with the 0x20 bit set is the literal's character.
    @inline(always)
    fileprivate var isContentTypeIgnoringCaseOfLetters: Bool {
        count == 12 && self[0].matchesWithBit0x20("c") && self[1].matchesWithBit0x20("o") && self[2].matchesWithBit0x20("n")
            && self[3].matchesWithBit0x20("t") && self[4].matchesWithBit0x20("e") && self[5].matchesWithBit0x20("n")
            && self[6].matchesWithBit0x20("t") && self[7].matchesWithBit0x20("-") && self[8].matchesWithBit0x20("t")
            && self[9].matchesWithBit0x20("y") && self[10].matchesWithBit0x20("p") && self[11].matchesWithBit0x20("e")
    }

    /// Whether the seven characters at `index` are "charset" in any ASCII case.
    @inline(always)
    private func isCharsetIgnoringASCIICase(at index: Int) -> Bool {
        guard self[index].matchesWithBit0x20("c") else {
            return false
        }
        let characters = extracting(index + 1..<index + 7)
        return characters[0].matchesWithBit0x20("h") && characters[1].matchesWithBit0x20("a") && characters[2].matchesWithBit0x20("r")
            && characters[3].matchesWithBit0x20("s") && characters[4].matchesWithBit0x20("e") && characters[5].matchesWithBit0x20("t")
    }

    /// The characters in `range` without the ASCII whitespace at either end, as StringView::trim() leaves them.
    @inline(always)
    fileprivate func trimmingASCIIWhitespace(_ range: Range<Int>) -> Range<Int> {
        var start = range.lowerBound
        var end = range.upperBound
        while start < end, self[start].htmlMicrosyntaxIsASCIIWhitespace {
            start += 1
        }
        while end > start, self[end - 1].htmlMicrosyntaxIsASCIIWhitespace {
            end -= 1
        }
        return start..<end
    }

    /// The characters of the encoding name in the content of a <meta http-equiv="content-type">, as
    /// extractCharset() finds them: after "charset", in any ASCII case, and an equals sign, with every
    /// character up to U+0020 skipped before and after it.
    ///
    /// A quoted name ends at the closing quote, and one without quotes at a character up to U+0020, a quote or a ';'.
    /// The range is empty when there is no name, or no closing quote.
    fileprivate func charsetInContentType() -> Range<Int> {
        let charsetLength = 7
        var position = 0
        while position < count {
            while position <= count - charsetLength, !isCharsetIgnoringASCIICase(at: position) {
                position += 1
            }
            guard position <= count - charsetLength else {
                break
            }
            position += charsetLength

            position = indexAfterControlsAndSpaces(from: position)
            // Ensure we're in bounds before checking for '='.
            guard position < count else {
                break
            }
            guard self[position].htmlMicrosyntaxMatches("=") else {
                continue
            }
            position = indexAfterControlsAndSpaces(from: position + 1)

            var quoteMark: UInt16 = 0
            if position < count {
                let character = self[position]
                if character.htmlMicrosyntaxMatches("\"") || character.htmlMicrosyntaxMatches("'") {
                    quoteMark = character.htmlMicrosyntaxCodeUnit
                    position += 1
                }
            }
            guard position < count else {
                break
            }

            var end = position
            while end < count, !Self.endsCharset(self[end], quoteMark) {
                end += 1
            }
            // Close quote not found.
            guard quoteMark == 0 || end < count else {
                break
            }
            return position..<end
        }
        return 0..<0
    }

    @inline(always)
    private func indexAfterControlsAndSpaces(from index: Int) -> Int {
        var index = index
        while index < count, self[index].htmlMicrosyntaxCodeUnit <= 0x20 {
            index += 1
        }
        return index
    }

    @inline(always)
    private static func endsCharset(_ character: Element, _ quoteMark: UInt16) -> Bool {
        if quoteMark != 0 {
            return character.htmlMicrosyntaxCodeUnit == quoteMark
        }
        return character.htmlMicrosyntaxCodeUnit <= 0x20 || character.htmlMicrosyntaxMatches("\"") || character.htmlMicrosyntaxMatches("'")
            || character.htmlMicrosyntaxMatches(";")
    }
}
