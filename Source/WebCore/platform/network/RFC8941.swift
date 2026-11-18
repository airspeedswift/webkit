// Copyright (C) 2021-2022 Apple Inc. All rights reserved.
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

/// RFC 8941's item, list and dictionary parsers: writes the value's steps to `buffer` and returns their count, the
/// count needed when it is larger than `buffer`, or -1 when the value does not parse.
///
/// `header` is the characters of the caller's `StringView`, whose `String` the caller holds unchanged for the call.
/// `buffer` is the caller's, which it owns, value-initializes and does not read or write until the call returns,
/// and which does not overlap `header`. Nothing this function calls writes either, and every bit pattern of a code
/// unit and of a step is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters and the buffer as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseStructuredField8(
    _ header: WebCore.HTTPHeaderLatin1Span,
    _ type: WebCore.HTTPHeaderStructuredFieldType,
    _ buffer: WebCore.HTTPHeaderStructuredFieldStepSpan
) -> Int64 {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(header))
    var steps = unsafe MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>(_unsafeCxxSpan: buffer)
    return parseStructuredFieldBody(characters, type, &steps)
}

/// parseStructuredField8() for 16-bit characters, which hold for the call in the same way, as does `buffer`.
///
/// FIXME: Take the characters and the buffer as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseStructuredField16(
    _ header: WebCore.HTTPHeaderUTF16Span,
    _ type: WebCore.HTTPHeaderStructuredFieldType,
    _ buffer: WebCore.HTTPHeaderStructuredFieldStepSpan
) -> Int64 {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: header)
    var steps = unsafe MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>(_unsafeCxxSpan: buffer)
    return parseStructuredFieldBody(characters, type, &steps)
}

/// The string item whose quoted text is at `start`, `length` in a structured field value, unescaped. `escapesAndWidth`
/// is its step's `integer`.
///
/// `header` is the characters of the caller's `StringView`, whose `String` or buffer the caller keeps allocated and
/// unchanged, at their length, for the call. Nothing this function calls writes them, and every Latin-1 or UTF-16 code
/// unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func structuredFieldString8(
    _ header: WebCore.HTTPHeaderLatin1Span,
    _ start: UInt32,
    _ length: UInt32,
    _ escapesAndWidth: Int64
) -> WTF.String {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(header))
    return structuredFieldStringBody(characters, start, length, escapesAndWidth)
}

/// structuredFieldString8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func structuredFieldString16(
    _ header: WebCore.HTTPHeaderUTF16Span,
    _ start: UInt32,
    _ length: UInt32,
    _ escapesAndWidth: Int64
) -> WTF.String {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: header)
    return structuredFieldStringBody(characters, start, length, escapesAndWidth)
}

/// `RFC8941::escapeString()`: the value as an RFC 8941 string, or the null string when it cannot be one.
///
/// `input` is the characters of the caller's `StringView`, whose `String` or buffer the caller keeps allocated and
/// unchanged, at their length, for the call. Nothing this function calls writes them, and every Latin-1 or UTF-16 code
/// unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func escapeStructuredFieldString8(_ input: WebCore.HTTPHeaderLatin1Span) -> WTF.String {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(input))
    return escapeStructuredFieldStringBody(characters)
}

/// escapeStructuredFieldString8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func escapeStructuredFieldString16(_ input: WebCore.HTTPHeaderUTF16Span) -> WTF.String {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: input)
    return escapeStructuredFieldStringBody(characters)
}

@inline(never)
func parseStructuredFieldBody<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ type: WebCore.HTTPHeaderStructuredFieldType,
    _ steps: inout MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>
) -> Int64 {
    guard !characters.isEmpty else {
        return -1
    }
    // https://datatracker.ietf.org/doc/html/rfc8941#section-4.2
    var parser = RFC8941Parser()
    parser.skipSpaces(characters)
    let isValid: Bool
    switch type {
    case .Item:
        isValid = parser.parseItem(characters, &steps)
    case .List:
        isValid = parser.parseList(characters, &steps)
    case .Dictionary:
        isValid = parser.parseDictionary(characters, &steps)
    @unknown default:
        isValid = false
    }
    guard isValid else {
        return -1
    }
    parser.skipSpaces(characters)
    guard parser.position == characters.count else {
        return -1
    }
    return Int64(parser.stepCount)
}

@inline(never)
func structuredFieldStringBody<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ start: UInt32,
    _ length: UInt32,
    _ escapesAndWidth: Int64
) -> WTF.String {
    let content = characters.extracting(Int(start)..<(Int(start) + Int(length)))
    // What parseString() counted: the escapes, which rfc8941Unescape() checks, and a code unit above U+00FF, which only
    // a 16-bit value has.
    let escapes = Int(truncatingIfNeeded: UInt64(bitPattern: escapesAndWidth) >> 1)
    let isWide = CodeUnit.bitWidth == 16 && escapesAndWidth & 1 != 0
    // A string item's String is 16-bit only when it has a code unit above U+00FF.
    if escapes == 0 && (CodeUnit.bitWidth == 8 || isWide) {
        return CodeUnit.httpHeaderString(content)
    }
    if isWide {
        return rfc8941UnescapedString(content, escapes: escapes, as: UInt16.self)
    }
    return rfc8941UnescapedString(content, escapes: escapes, as: UInt8.self)
}

@inline(never)
func escapeStructuredFieldStringBody<CodeUnit: HTTPHeaderStringCodeUnit>(_ characters: Span<CodeUnit>) -> WTF.String {
    // https://datatracker.ietf.org/doc/html/rfc8941#section-3.3.3: the null string when a code unit is outside
    // U+0020-U+007E.
    var escapes = 0
    for index in characters.indices {
        let codeUnit = characters[index]
        if codeUnit < 0x20 || codeUnit > 0x7E {
            return WTF.String()
        }
        if codeUnit == 0x22 || codeUnit == 0x5C { // '"' or '\'
            // At most one per code unit, so neither this count nor the result's length can overflow.
            escapes &+= 1
        }
    }
    // The result is 8-bit.
    if escapes == 0 && CodeUnit.bitWidth == 8 {
        return CodeUnit.httpHeaderString(characters)
    }
    let count = characters.count &+ escapes
    if count <= RFC8941StackBuffer<UInt8>.count {
        var buffer = RFC8941StackBuffer<UInt8>(repeating: 0)
        var output = buffer.mutableSpan
        rfc8941Escape(characters, into: &output)
        return UInt8.httpHeaderString(buffer.span.extracting(0..<count))
    }
    var escaped = [UInt8](repeating: 0, count: count)
    var output = escaped.mutableSpan
    rfc8941Escape(characters, into: &output)
    return UInt8.httpHeaderString(escaped.span)
}

// What Cross-Origin-Opener-Policy, Cross-Origin-Embedder-Policy, Document-Isolation-Policy and Origin-Agent-Cluster
// read of an item, as RFC8941::parseItemStructuredFieldValue() gives it: the step of its bare item, and the step of its
// "report-to" parameter's value when that value is a string. A parameter given twice keeps its last value.
struct RFC8941PolicyItem {
    var bareItem: WebCore.HTTPHeaderStructuredFieldStep
    var reportTo: WebCore.HTTPHeaderStructuredFieldStep?
}

// RFC8941::parseItemStructuredFieldValue() of `characters`: nil when they are not an item, or when one of its byte
// sequences, the bare item's or a parameter's, is not base64 that WTF's base64Decode() decodes. Each bare item is read
// as soon as it is parsed, so the item needs no buffer of its steps.
func rfc8941PolicyItem<CodeUnit: HTTPHeaderStringCodeUnit>(_ characters: Span<CodeUnit>) -> RFC8941PolicyItem? {
    guard !characters.isEmpty else {
        return nil
    }
    // The parser writes each bare item's step here: the item's, then each parameter value's.
    var stepStorage = [1 of WebCore.HTTPHeaderStructuredFieldStep](repeating: WebCore.HTTPHeaderStructuredFieldStep())
    var step = stepStorage.mutableSpan
    var parser = RFC8941Parser()
    parser.skipSpaces(characters)
    guard parser.parseBareItem(characters, &step) else {
        return nil
    }
    let bareItem = step[0]
    guard rfc8941BareItemDecodes(characters, bareItem) else {
        return nil
    }
    // RFC8941Parser.parseParameters(), reading each parameter as it is parsed.
    var reportTo: WebCore.HTTPHeaderStructuredFieldStep? = nil
    while parser.skipExactly(characters, 0x3B) { // ';'
        parser.skipSpaces(characters)
        guard let key = parser.parseKey(characters) else {
            return nil
        }
        let isReportTo = crossOriginAccessControlEquals(characters.extracting(key.start..<parser.position), "report-to")
        guard parser.skipExactly(characters, 0x3D) else { // '='
            // A parameter with no value is a Boolean true, which is not a string.
            if isReportTo {
                reportTo = nil
            }
            continue
        }
        parser.stepCount = 0
        guard parser.parseBareItem(characters, &step), rfc8941BareItemDecodes(characters, step[0]) else {
            return nil
        }
        if isReportTo {
            reportTo = step[0].kind == .String ? step[0] : nil
        }
    }
    parser.skipSpaces(characters)
    guard parser.position == characters.count else {
        return nil
    }
    return RFC8941PolicyItem(bareItem: bareItem, reportTo: reportTo)
}

// Whether the step makes a bare item: all of them do but a byte sequence that does not decode.
private func rfc8941BareItemDecodes<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ step: WebCore.HTTPHeaderStructuredFieldStep
) -> Bool {
    switch step.kind {
    case .Integer, .Decimal, .String, .Token, .Boolean:
        return true
    case .ByteSequence:
        return structuredFieldBase64Decodes(rfc8941Text(characters, step), url: false)
    default:
        // The parser writes a bare item first and after each parameter key.
        fatalError()
    }
}

// The text of a step: a token's, a key's or a byte sequence's.
private func rfc8941Text<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ step: WebCore.HTTPHeaderStructuredFieldStep
) -> Span<CodeUnit> {
    characters.extracting(Int(step.start)..<(Int(step.start) + Int(step.length)))
}

// Whether the text of a token or key step is `literal`.
func rfc8941TextEquals<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ step: WebCore.HTTPHeaderStructuredFieldStep,
    _ literal: Swift.String
) -> Bool {
    crossOriginAccessControlEquals(rfc8941Text(characters, step), literal)
}

// Calls `body8` with the Latin-1 characters of `string` as bytes, or `body16` with its UTF-16 code units. An empty or
// null String has no characters in either width, and goes to `body16`.
func rfc8941WithCharacters<Result>(
    _ string: borrowing WTF.String,
    _ body8: (Span<UInt8>) -> Result,
    _ body16: (Span<UInt16>) -> Result
) -> Result {
    if string.isEmpty() {
        return body16(Span<UInt16>())
    }
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(string)
    if !bytes.isEmpty {
        return body8(bytes)
    }
    return body16(string.checkedSpan16())
}

// The 8-bit String of the ASCII `token`.
func rfc8941TokenString(_ token: Swift.String) -> WTF.String {
    let utf8 = token.utf8
    return WTF.makeStringFromLatin1Characters(utf8.span)
}

// makeString(token, "; report-to=\"", reportTo, '"'): a policy header's value that is the ASCII token with a report-to
// parameter, `reportTo` written between the quotes as it is. It is 8-bit unless `reportTo` is 16-bit.
func rfc8941TokenWithReportToHeaderValue(_ token: Swift.String, _ reportTo: borrowing WTF.String) -> WTF.String {
    let tokenUTF8 = token.utf8
    let characters: Span<UInt8> = WebCore.securityPoliciesSpan8(reportTo)
    if characters.isEmpty, !reportTo.is8Bit() {
        return rfc8941TokenWithReportToHeaderValue(UInt16.self, tokenUTF8.span, reportTo.checkedSpan16())
    }
    return rfc8941TokenWithReportToHeaderValue(UInt8.self, tokenUTF8.span, characters)
}

private func rfc8941TokenWithReportToHeaderValue<CodeUnit: HTTPHeaderStringCodeUnit & ConvertibleFromBytes, Source: HTTPHeaderStringCodeUnit>(
    _: CodeUnit.Type,
    _ token: Span<UInt8>,
    _ reportTo: Span<Source>
) -> WTF.String {
    let separatorUTF8 = "; report-to=\"".utf8
    let separator = separatorUTF8.span
    // A String's length and two short literals': far from overflowing.
    let length = token.count &+ separator.count &+ reportTo.count &+ 1
    return crossOriginAccessControlMakeString(CodeUnit.self, length) { output in
        var position = crossOriginAccessControlCopy(token, to: &output, at: 0)
        position = crossOriginAccessControlCopy(separator, to: &output, at: position)
        position = crossOriginAccessControlCopy(reportTo, to: &output, at: position)
        output[position] = 0x22
    }
}

// Structured field values (https://datatracker.ietf.org/doc/html/rfc8941#section-4.2), over Latin-1 (UInt8) or
// UTF-16 (UInt16) code units.

// A string item's content without its escapes, or escapeString()'s result, of at most this many code units is put
// together on the stack, and a longer one in an Array.
private typealias RFC8941StackBuffer<CodeUnit> = InlineArray<64, CodeUnit>

// The String of a string item's content without its `escapes` escapes, in D's width.
private func rfc8941UnescapedString<C: FixedWidthInteger & UnsignedInteger, D: HTTPHeaderStringCodeUnit>(
    _ content: Span<C>,
    escapes: Int,
    as _: D.Type
) -> WTF.String {
    // A count below 0 traps in rfc8941Unescape().
    let count = content.count - escapes
    if count <= RFC8941StackBuffer<D>.count {
        var buffer = RFC8941StackBuffer<D>(repeating: 0)
        var output = buffer.mutableSpan
        rfc8941Unescape(content, escapes: escapes, into: &output)
        return D.httpHeaderString(buffer.span.extracting(0..<count))
    }
    var codeUnits = [D](repeating: 0, count: count)
    var output = codeUnits.mutableSpan
    rfc8941Unescape(content, escapes: escapes, into: &output)
    return D.httpHeaderString(codeUnits.span)
}

// Writes a string item's content without its escapes to the start of `output`. With `escapes` at 0 it copies the
// content; otherwise it traps unless the content has that many.
private func rfc8941Unescape<C: FixedWidthInteger & UnsignedInteger, D: FixedWidthInteger & UnsignedInteger>(
    _ content: Span<C>,
    escapes: Int,
    into output: inout MutableSpan<D>
) {
    if escapes == 0 {
        for index in content.indices {
            output[index] = D(truncatingIfNeeded: content[index])
        }
        return
    }
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
    precondition(content.count - count == escapes)
}

// Writes escapeString()'s result for code units it accepts to the start of `output`.
private func rfc8941Escape<C: FixedWidthInteger & UnsignedInteger>(_ input: Span<C>, into output: inout MutableSpan<UInt8>) {
    var count = 0
    for index in input.indices {
        let codeUnit = UInt8(truncatingIfNeeded: input[index])
        if codeUnit == 0x22 || codeUnit == 0x5C { // '"' or '\'
            output[count] = 0x5C
            count += 1
        }
        output[count] = codeUnit
        count += 1
    }
}

@inline(always)
private func rfc8941IsEndOfToken<C: FixedWidthInteger & UnsignedInteger>(_ character: C) -> Bool {
    !HTTPHeaderCodeUnits.isTokenCharacter(HTTPHeaderCodeUnits.value(character)) && character != 0x3A && character != 0x2F // ':' and '/'
}

@inline(always)
private func rfc8941IsEndOfKey<C: FixedWidthInteger & UnsignedInteger>(_ character: C) -> Bool {
    switch UInt32(truncatingIfNeeded: character) {
    case 0x61...0x7A, 0x30...0x39, 0x5F, 0x2D, 0x2E, 0x2A: // '_', '-', '.', '*'
        false
    default:
        true
    }
}

// Writes the steps of a value, in the order of its text, to the caller's buffer: a dictionary member's key before it, an
// inner list's start, items and end, and each item's or inner list's parameters after it, each key before its value.
// A member or parameter with no value is a Boolean true. stepCount counts every step, also those past the buffer.
private struct RFC8941Parser {
    var position = 0
    var stepCount = 0

    mutating func emit(
        _ kind: WebCore.HTTPHeaderStructuredFieldStepKind,
        start: Int = 0,
        length: Int = 0,
        integer: Int64 = 0,
        decimal: Double = 0,
        _ steps: inout MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>
    ) {
        if stepCount < steps.count {
            // Positions lie within a String, whose length is a 32-bit unsigned.
            steps[stepCount] = WebCore.HTTPHeaderStructuredFieldStep(
                decimal: decimal,
                integer: integer,
                start: UInt32(truncatingIfNeeded: start),
                length: UInt32(truncatingIfNeeded: length),
                kind: kind
            )
        }
        // At most two steps per code unit of the input, so the count cannot overflow.
        stepCount &+= 1
    }

    mutating func skipSpaces<C: FixedWidthInteger & UnsignedInteger>(_ input: Span<C>) {
        while position < input.count && input[position] == 0x20 {
            position += 1
        }
    }

    mutating func skipTabsAndSpaces<C: FixedWidthInteger & UnsignedInteger>(_ input: Span<C>) {
        while position < input.count && (input[position] == 0x20 || input[position] == 0x09) {
            position += 1
        }
    }

    mutating func skipExactly<C: FixedWidthInteger & UnsignedInteger>(_ input: Span<C>, _ character: C) -> Bool {
        guard position < input.count && input[position] == character else {
            return false
        }
        position += 1
        return true
    }

    // Parsing a key (https://datatracker.ietf.org/doc/html/rfc8941#section-4.2.3.3). A key is never empty.
    mutating func parseKey<C: FixedWidthInteger & UnsignedInteger>(_ input: Span<C>) -> (start: Int, length: Int)? {
        guard position < input.count, input[position] == 0x2A || (input[position] >= 0x61 && input[position] <= 0x7A) else { // '*'
            return nil
        }
        let start = position
        position += 1
        while position < input.count && !rfc8941IsEndOfKey(input[position]) {
            position += 1
        }
        return (start, position - start)
    }

    // Parsing a String (https://datatracker.ietf.org/doc/html/rfc8941#section-4.2.5). The step holds the content
    // between the quotes, which structuredFieldStringBody() unescapes, and in `integer` twice the number of its
    // escapes, plus 1 when it has a code unit above U+00FF.
    mutating func parseString<C: FixedWidthInteger & UnsignedInteger>(
        _ input: Span<C>,
        _ steps: inout MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>
    ) -> Bool {
        guard skipExactly(input, 0x22) else { // '"'
            return false
        }
        let start = position
        var escapes: Int64 = 0
        // The code units of the content outside its escapes, or'ed together.
        var codeUnits: C = 0
        while position < input.count {
            let character = input[position]
            if character == 0x5C { // '\'
                position += 1
                guard position < input.count else {
                    return false
                }
                let next = input[position]
                guard next == 0x22 || next == 0x5C else {
                    return false
                }
                // At most one per two code units of the input, so neither this count nor twice it can overflow.
                escapes &+= 1
                position += 1
                continue
            }
            if character == 0x22 {
                emit(.String, start: start, length: position - start, integer: escapes &* 2 + (codeUnits > 0xFF ? 1 : 0), &steps)
                position += 1
                return true
            }
            // 0x00-0x1F and 0x7F-0xFF fail; 16-bit code units above 0xFF are kept.
            if character <= 0x1F || (character >= 0x7F && character <= 0xFF) {
                return false
            }
            codeUnits |= character
            position += 1
        }
        return false
    }

    // Parsing an Integer or Decimal (https://datatracker.ietf.org/doc/html/rfc8941#section-4.2.4).
    mutating func parseNumber<C: FixedWidthInteger & UnsignedInteger>(
        _ input: Span<C>,
        _ steps: inout MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>
    ) -> Bool {
        let isNegative = skipExactly(input, 0x2D) // '-'

        var integerValue: Int64 = 0
        var integerDigits = 0
        let maxIntegerDigits = 15
        while position < input.count && HTTPHeaderCodeUnits.isASCIIDigit(HTTPHeaderCodeUnits.value(input[position])) {
            integerDigits += 1
            if integerDigits > maxIntegerDigits {
                return false
            }
            // An ASCII digit, and at most 15 of them, so the value stays below 10^15.
            integerValue = integerValue &* 10 &+ (Int64(truncatingIfNeeded: input[position]) - 0x30)
            position += 1
        }
        if integerDigits == 0 {
            return false
        }
        if !skipExactly(input, 0x2E) { // '.'
            // Below 10^15, so the negation cannot overflow.
            emit(.Integer, integer: isNegative ? 0 &- integerValue : integerValue, &steps)
            return true
        }

        let maxDecimalIntegerDigits = 12
        if integerDigits > maxDecimalIntegerDigits {
            return false
        }
        var fractionalValue = 0.0
        var fractionalDigits = 0
        let maxFractionalDigits = 3
        var divisor = 1.0
        while position < input.count && HTTPHeaderCodeUnits.isASCIIDigit(HTTPHeaderCodeUnits.value(input[position])) {
            fractionalDigits += 1
            if fractionalDigits > maxFractionalDigits {
                return false
            }
            divisor *= 10.0
            fractionalValue = fractionalValue * 10.0 + Double(Int64(truncatingIfNeeded: input[position]) - 0x30)
            position += 1
        }
        if fractionalDigits == 0 {
            return false
        }
        let decimalValue = Double(integerValue) + (fractionalValue / divisor)
        emit(.Decimal, decimal: isNegative ? -decimalValue : decimalValue, &steps)
        return true
    }

    // Parsing a Token (https://datatracker.ietf.org/doc/html/rfc8941#section-4.2.6).
    mutating func parseToken<C: FixedWidthInteger & UnsignedInteger>(
        _ input: Span<C>,
        _ steps: inout MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>
    ) -> Bool {
        guard position < input.count,
            HTTPHeaderCodeUnits.isASCIIAlpha(HTTPHeaderCodeUnits.value(input[position])) || input[position] == 0x2A // '*'
        else {
            return false
        }
        let start = position
        while position < input.count && !rfc8941IsEndOfToken(input[position]) {
            position += 1
        }
        emit(.Token, start: start, length: position - start, &steps)
        return true
    }

    // Parsing a Byte Sequence (https://datatracker.ietf.org/doc/html/rfc8941#section-4.2.7). The base64 text is
    // decoded by the caller: an empty text is an empty byte sequence, and one that does not decode fails the value.
    mutating func parseByteSequence<C: FixedWidthInteger & UnsignedInteger>(
        _ input: Span<C>,
        _ steps: inout MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>
    ) -> Bool {
        guard skipExactly(input, 0x3A) else { // ':'
            return false
        }
        let start = position
        while position < input.count && input[position] != 0x3A {
            position += 1
        }
        let length = position - start
        guard skipExactly(input, 0x3A) else {
            return false
        }
        emit(.ByteSequence, start: start, length: length, &steps)
        return true
    }

    // Parsing a Boolean (https://datatracker.ietf.org/doc/html/rfc8941#section-4.2.8).
    mutating func parseBoolean<C: FixedWidthInteger & UnsignedInteger>(
        _ input: Span<C>,
        _ steps: inout MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>
    ) -> Bool {
        guard skipExactly(input, 0x3F) else { // '?'
            return false
        }
        if skipExactly(input, 0x31) { // '1'
            emit(.Boolean, integer: 1, &steps)
            return true
        }
        if skipExactly(input, 0x30) { // '0'
            emit(.Boolean, &steps)
            return true
        }
        return false
    }

    // Parsing a Bare Item (https://datatracker.ietf.org/doc/html/rfc8941#section-4.2.3.1).
    mutating func parseBareItem<C: FixedWidthInteger & UnsignedInteger>(
        _ input: Span<C>,
        _ steps: inout MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>
    ) -> Bool {
        guard position < input.count else {
            return false
        }
        let character = input[position]
        if character == 0x3A { // ':'
            return parseByteSequence(input, &steps)
        }
        if character == 0x22 { // '"'
            return parseString(input, &steps)
        }
        if HTTPHeaderCodeUnits.isASCIIAlpha(HTTPHeaderCodeUnits.value(character)) || character == 0x2A { // '*'
            return parseToken(input, &steps)
        }
        if character == 0x3F { // '?'
            return parseBoolean(input, &steps)
        }
        if character == 0x2D || HTTPHeaderCodeUnits.isASCIIDigit(HTTPHeaderCodeUnits.value(character)) { // '-'
            return parseNumber(input, &steps)
        }
        return false
    }

    // Parsing Parameters (https://datatracker.ietf.org/doc/html/rfc8941#section-4.2.3.2). A key given twice keeps the
    // last value: the caller sets each in order.
    mutating func parseParameters<C: FixedWidthInteger & UnsignedInteger>(
        _ input: Span<C>,
        _ steps: inout MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>
    ) -> Bool {
        while position < input.count {
            if !skipExactly(input, 0x3B) { // ';'
                break
            }
            skipSpaces(input)
            guard let key = parseKey(input) else {
                return false
            }
            emit(.ParameterKey, start: key.start, length: key.length, &steps)
            if skipExactly(input, 0x3D) { // '='
                guard parseBareItem(input, &steps) else {
                    return false
                }
            } else {
                emit(.Boolean, integer: 1, &steps)
            }
        }
        return true
    }

    // Parsing an item (https://datatracker.ietf.org/doc/html/rfc8941#section-4.2.3).
    mutating func parseItem<C: FixedWidthInteger & UnsignedInteger>(
        _ input: Span<C>,
        _ steps: inout MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>
    ) -> Bool {
        guard parseBareItem(input, &steps) else {
            return false
        }
        return parseParameters(input, &steps)
    }

    // Parsing an Inner List (https://datatracker.ietf.org/doc/html/rfc8941#section-4.2.1.2).
    mutating func parseInnerList<C: FixedWidthInteger & UnsignedInteger>(
        _ input: Span<C>,
        _ steps: inout MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>
    ) -> Bool {
        guard skipExactly(input, 0x28) else { // '('
            return false
        }
        emit(.InnerListStart, &steps)
        while position < input.count {
            skipSpaces(input)
            if skipExactly(input, 0x29) { // ')'
                emit(.InnerListEnd, &steps)
                return parseParameters(input, &steps)
            }
            guard parseItem(input, &steps) else {
                return false
            }
            if position == input.count || (input[position] != 0x29 && input[position] != 0x20) {
                break
            }
        }
        return false
    }

    // Parsing an item or inner list (https://datatracker.ietf.org/doc/html/rfc8941#section-4.2.1.1).
    mutating func parseItemOrInnerList<C: FixedWidthInteger & UnsignedInteger>(
        _ input: Span<C>,
        _ steps: inout MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>
    ) -> Bool {
        if position < input.count && input[position] == 0x28 { // '('
            return parseInnerList(input, &steps)
        }
        return parseItem(input, &steps)
    }

    // Parsing a dictionary (https://datatracker.ietf.org/doc/html/rfc8941#section-4.2.2). A key given twice keeps
    // the last member: the caller sets each in order.
    mutating func parseDictionary<C: FixedWidthInteger & UnsignedInteger>(
        _ input: Span<C>,
        _ steps: inout MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>
    ) -> Bool {
        while position < input.count {
            guard let key = parseKey(input) else {
                return false
            }
            emit(.MemberKey, start: key.start, length: key.length, &steps)
            if skipExactly(input, 0x3D) { // '='
                guard parseItemOrInnerList(input, &steps) else {
                    return false
                }
            } else {
                emit(.Boolean, integer: 1, &steps)
                guard parseParameters(input, &steps) else {
                    return false
                }
            }
            skipTabsAndSpaces(input)
            if position == input.count {
                return true
            }
            guard skipExactly(input, 0x2C) else { // ','
                return false
            }
            skipTabsAndSpaces(input)
            if position == input.count {
                return false
            }
        }
        return true
    }

    // Parsing a list (https://datatracker.ietf.org/doc/html/rfc8941#section-4.2.1).
    mutating func parseList<C: FixedWidthInteger & UnsignedInteger>(
        _ input: Span<C>,
        _ steps: inout MutableSpan<WebCore.HTTPHeaderStructuredFieldStep>
    ) -> Bool {
        while position < input.count {
            guard parseItemOrInnerList(input, &steps) else {
                return false
            }
            skipTabsAndSpaces(input)
            if position == input.count {
                return true
            }
            guard skipExactly(input, 0x2C) else { // ','
                return false
            }
            skipTabsAndSpaces(input)
            if position == input.count {
                return false
            }
        }
        return true
    }
}
