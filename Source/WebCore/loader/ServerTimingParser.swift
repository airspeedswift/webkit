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
internal import WebCore_Private.Core.ServerTiming
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

/// `ServerTimingParser::parseServerTiming()`: the metric at `start`, with its first `dur` and `desc`, or a null name
/// when there is none. `start` moves to where the next metric starts, or past the end of the value after the last one.
///
/// `headerValue` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call;
/// a `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseServerTimingEntry8(_ headerValue: WebCore.HTTPHeaderLatin1Span, _ start: inout UInt32) -> WebCore.ServerTiming {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(headerValue))
    return parseServerTimingEntryBody(characters, &start)
}

/// parseServerTimingEntry8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseServerTimingEntry16(_ headerValue: WebCore.HTTPHeaderUTF16Span, _ start: inout UInt32) -> WebCore.ServerTiming {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: headerValue)
    return parseServerTimingEntryBody(characters, &start)
}

@inline(never)
private func parseServerTimingEntryBody<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ start: inout UInt32
) -> WebCore.ServerTiming {
    let metric = serverTimingParse(characters, from: Int(start))
    // A String's length is below UInt32.max, so one past it fits.
    start = UInt32(truncatingIfNeeded: metric.stop ? characters.count &+ 1 : metric.next)
    guard metric.hasEntry else {
        return WebCore.ServerTiming(consuming: WTF.String())
    }
    // The name lies within the characters, so its end cannot overflow.
    return WebCore.ServerTiming(
        consuming: CodeUnit.httpHeaderString(characters.extracting(metric.nameStart..<metric.nameStart &+ metric.nameLength)),
        metric.durationSet ? serverTimingDuration(characters, metric.duration) : 0,
        consuming: metric.descriptionSet ? serverTimingString(characters, metric.description) : WTF.String(),
        metric.durationSet,
        metric.descriptionSet
    )
}

/// `toDouble()` of the `dur` value's `String`: 0 when it does not start with a number.
private func serverTimingDuration<CodeUnit: HTTPHeaderStringCodeUnit>(_ characters: Span<CodeUnit>, _ value: ServerTimingValue) -> Double {
    if value.isNull {
        return 0
    }
    // The value lies within the characters, so its end cannot overflow.
    let content = characters.extracting(value.start..<value.start &+ value.length)
    if !value.isQuoted || (!value.hasEscapes && (CodeUnit.bitWidth == 8 || !value.isLatin1)) {
        return httpHeaderToDouble(content)?.value ?? 0
    }
    if CodeUnit.bitWidth == 8 || value.isLatin1 {
        return withServerTimingUnescapedContent(content, as: UInt8.self) { httpHeaderToDouble($0)?.value ?? 0 }
    }
    return withServerTimingUnescapedContent(content, as: UInt16.self) { httpHeaderToDouble($0)?.value ?? 0 }
}

/// A parameter's value: the null string, the empty one, a token in the header's width, or a quoted string's content
/// without its escapes, 8-bit when every character is Latin-1.
private func serverTimingString<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ value: ServerTimingValue
) -> WTF.String {
    if value.isNull {
        return WTF.String()
    }
    // The value lies within the characters, so its end cannot overflow.
    let content = characters.extracting(value.start..<value.start &+ value.length)
    if !value.isQuoted || (!value.hasEscapes && (CodeUnit.bitWidth == 8 || !value.isLatin1)) {
        return CodeUnit.httpHeaderString(content)
    }
    if CodeUnit.bitWidth == 8 || value.isLatin1 {
        return withServerTimingUnescapedContent(content, as: UInt8.self) { UInt8.httpHeaderString($0) }
    }
    return withServerTimingUnescapedContent(content, as: UInt16.self) { UInt16.httpHeaderString($0) }
}

// A quoted string's content of at most this many code units, with its escapes, is put together on the stack without
// them, and a longer one in an Array.
private typealias ServerTimingStackBuffer<CodeUnit> = InlineArray<64, CodeUnit>

// Calls `body` with a quoted string's content without the backslashes that escape a code unit, as D (UInt8 when the
// content is Latin-1).
@inline(always)
private func withServerTimingUnescapedContent<C: FixedWidthInteger & UnsignedInteger, D: FixedWidthInteger & UnsignedInteger, Result>(
    _ content: Span<C>,
    as _: D.Type,
    _ body: (Span<D>) -> Result
) -> Result {
    if content.count <= ServerTimingStackBuffer<D>.count {
        var buffer = ServerTimingStackBuffer<D>(repeating: 0)
        var output = buffer.mutableSpan
        let count = serverTimingUnescape(content, into: &output)
        return body(buffer.span.extracting(0..<count))
    }
    var codeUnits = [D](repeating: 0, count: content.count)
    var output = codeUnits.mutableSpan
    let count = serverTimingUnescape(content, into: &output)
    return body(codeUnits.span.extracting(0..<count))
}

// Writes a quoted string's content without the backslashes that escape a code unit to the start of `output`, and
// returns how many it wrote. The content never ends in a backslash that escapes nothing.
private func serverTimingUnescape<C: FixedWidthInteger & UnsignedInteger, D: FixedWidthInteger & UnsignedInteger>(
    _ content: Span<C>,
    into output: inout MutableSpan<D>
) -> Int {
    var count = 0
    var index = 0
    while index < content.count {
        if content[index] == 0x5C { // '\'
            index += 1
        }
        output[count] = D(truncatingIfNeeded: content[index])
        count += 1
        index += 1
    }
    return count
}

// The Server-Timing header (https://w3c.github.io/server-timing/#the-server-timing-header-field), one metric per
// call, over Latin-1 (UInt8) or UTF-16 (UInt16) code units.

// A parameter value: null, the empty string, a token input[start..<start + length], or a quoted string whose content
// between the quotes is input[start..<start + length].
struct ServerTimingValue {
    var start = 0
    var length = 0
    var isNull = false
    var isQuoted = false
    // A quoted string's content has a backslash, which escapes the code unit after it.
    var hasEscapes = false
    // No code unit of a quoted string, without its escapes, is above U+00FF, so the string is 8-bit.
    var isLatin1 = true
}

struct ServerTimingRecord {
    // False when there is no metric at the position: the header is consumed, or no token starts there.
    var hasEntry = false
    var nameStart = 0
    var nameLength = 0
    // The first dur and the first desc parameters win.
    var durationSet = false
    var duration = ServerTimingValue()
    var descriptionSet = false
    var description = ServerTimingValue()
    // True when no ',' follows the metric, so it is the last.
    var stop = true
    var next = 0
}

// Parses the metric at position. Start at 0, and continue at next while the record has an entry and does not stop.
func serverTimingParse<C: HTTPHeaderStringCodeUnit>(_ input: Span<C>, from position: Int) -> ServerTimingRecord {
    var tokenizer = ServerTimingTokenizer(position: position)
    var record = ServerTimingRecord()
    // The tokenizer starts after any tabs and spaces; after a ',' they are already skipped.
    tokenizer.skipSpaces(input)
    guard !tokenizer.isConsumed(input), let name = tokenizer.consumeToken(input) else {
        record.next = tokenizer.position
        return record
    }
    record.hasEntry = true
    record.nameStart = name.start
    record.nameLength = name.length

    while tokenizer.consume(input, 0x3B) { // ';'
        guard let parameterName = tokenizer.consumeToken(input) else {
            break
        }
        var value = ServerTimingValue()
        if tokenizer.consume(input, 0x3D) { // '='
            value = tokenizer.consumeTokenOrQuotedString(input)
            tokenizer.consumeBeforeCommaOrSemicolon(input)
        }
        if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(
            input,
            HTTPHeaderSubstringExtent(start: parameterName.start, length: parameterName.length),
            "dur"
        ) {
            if !record.durationSet {
                record.duration = value
                record.durationSet = true
            }
        } else if HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(
            input,
            HTTPHeaderSubstringExtent(start: parameterName.start, length: parameterName.length),
            "desc"
        ) {
            if !record.descriptionSet {
                record.description = value
                record.descriptionSet = true
            }
        }
    }

    record.stop = !tokenizer.consume(input, 0x2C) // ','
    record.next = tokenizer.position
    return record
}

// Tokens, quoted strings and separators, each followed by any tabs and spaces.
private struct ServerTimingTokenizer {
    var position: Int

    func isConsumed<C: FixedWidthInteger & UnsignedInteger>(_ input: Span<C>) -> Bool {
        position >= input.count
    }

    mutating func skipSpaces<C: FixedWidthInteger & UnsignedInteger>(_ input: Span<C>) {
        while position < input.count && (input[position] == 0x20 || input[position] == 0x09) {
            position += 1
        }
    }

    mutating func consume<C: FixedWidthInteger & UnsignedInteger>(_ input: Span<C>, _ character: C) -> Bool {
        guard position < input.count && input[position] == character else {
            return false
        }
        position += 1
        skipSpaces(input)
        return true
    }

    // Nil (the null string) when no token character is here. A metric's or a parameter's name and a duration are a few
    // code units long, so this looks at one at a time.
    mutating func consumeToken<C: HTTPHeaderStringCodeUnit>(_ input: Span<C>) -> (start: Int, length: Int)? {
        let start = position
        while position < input.count && HTTPHeaderCodeUnits.isTokenCharacter(HTTPHeaderCodeUnits.value(input[position])) {
            position += 1
        }
        if start == position {
            return nil
        }
        let length = position - start
        skipSpaces(input)
        return (start, length)
    }

    // A backslash escapes any code unit. Null when the closing quote is missing, or the input ends after a backslash.
    mutating func consumeQuotedString<C: FixedWidthInteger & UnsignedInteger>(_ input: Span<C>) -> ServerTimingValue {
        position += 1
        var value = ServerTimingValue(start: position, isQuoted: true)
        while position < input.count {
            var character = input[position]
            if character == 0x22 { // '"'
                value.length = position - value.start
                position += 1
                skipSpaces(input)
                return value
            }
            if character == 0x5C { // '\'
                position += 1
                if position == input.count {
                    return ServerTimingValue(isNull: true)
                }
                character = input[position]
                value.hasEscapes = true
            }
            if character > 0xFF {
                value.isLatin1 = false
            }
            position += 1
        }
        return ServerTimingValue(isNull: true)
    }

    mutating func consumeTokenOrQuotedString<C: HTTPHeaderStringCodeUnit>(_ input: Span<C>) -> ServerTimingValue {
        if isConsumed(input) {
            return ServerTimingValue(isNull: true)
        }
        if input[position] == 0x22 { // '"'
            return consumeQuotedString(input)
        }
        guard let token = consumeToken(input) else {
            return ServerTimingValue(isNull: true)
        }
        return ServerTimingValue(start: token.start, length: token.length)
    }

    mutating func consumeBeforeCommaOrSemicolon<C: FixedWidthInteger & UnsignedInteger>(_ input: Span<C>) {
        while position < input.count && input[position] != 0x2C && input[position] != 0x3B { // ',' and ';'
            position += 1
        }
    }
}
