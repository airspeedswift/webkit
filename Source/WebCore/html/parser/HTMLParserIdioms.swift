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
internal import WebCore_Private.Core.HTMLParserIdioms
#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#elseif os(Windows)
internal import ucrt
#endif
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
internal import wtf.Core.cocoa.RuntimeApplicationChecksCocoa
#endif

// The functions exposed to C++ are kept small enough for link-time optimization to inline them into their C++
// callers, where the std::span accessors they call are inlined too: each makes Spans of its arguments and calls a
// parser marked @inline(never), or, to count the values of a list of dimensions, counts its commas.

// MARK: Integers

/// The rules for parsing integers, as parseHTMLInteger(), for an 8-bit StringView.
///
/// `characters` are the characters of the caller's StringView. They stay allocated and unchanged for the call, since
/// the caller holds their string and this function only reads them and passes them to no C++, and every value of a
/// Latin-1 code unit is a valid character.
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxParseInteger8(_ characters: WebCore.HTMLMicrosyntaxSpan8) -> WebCore.HTMLMicrosyntaxIntegerResult {
    let span = unsafe Span<WTF.Latin1Character>(_unsafeCxxSpan: characters)
    return htmlMicrosyntaxParseHTMLInteger(span)
}

/// htmlMicrosyntaxParseInteger8() for a 16-bit StringView, whose characters stay allocated and unchanged for the
/// call in the same way, and every value of a UTF-16 code unit is a valid character.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxParseInteger16(_ characters: WebCore.HTMLMicrosyntaxSpan16) -> WebCore.HTMLMicrosyntaxIntegerResult {
    let span = unsafe Span<UInt16>(_unsafeCxxSpan: characters)
    return htmlMicrosyntaxParseHTMLInteger(span)
}

private func htmlIntegerError(_ error: WebCore.HTMLIntegerParsingError) -> WebCore.HTMLMicrosyntaxIntegerResult {
    WebCore.HTMLMicrosyntaxIntegerResult(value: 0, error: error, isValid: false)
}

// https://html.spec.whatwg.org/multipage/infrastructure.html#rules-for-parsing-integers
@inline(never)
func htmlMicrosyntaxParseHTMLInteger<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>
) -> WebCore.HTMLMicrosyntaxIntegerResult {
    var index = characters.htmlMicrosyntaxIndexAfterASCIIWhitespace(from: 0)
    guard index < characters.count else {
        return htmlIntegerError(.Other)
    }

    var isNegative = false
    if characters[index].htmlMicrosyntaxMatches("-") {
        isNegative = true
        index += 1
    } else if characters[index].htmlMicrosyntaxMatches("+") {
        index += 1
    }

    guard index < characters.count, characters[index].htmlMicrosyntaxIsASCIIDigit else {
        return htmlIntegerError(.Other)
    }

    let maxMultiplier = UInt32(Int32.max / 10)
    let maxLastDigit = UInt32(Int32.max % 10) + (isNegative ? 1 : 0)
    var result: UInt32 = 0
    while index < characters.count, let digitValue = characters[index].htmlMicrosyntaxASCIIDigitValue {
        if result > maxMultiplier || (result == maxMultiplier && digitValue > maxLastDigit) {
            return htmlIntegerError(isNegative ? .NegativeOverflow : .PositiveOverflow)
        }
        result = result * 10 + digitValue
        index += 1
    }

    // Negation wraps, so 2147483648 becomes -2147483648.
    let value = Int32(truncatingIfNeeded: isNegative ? 0 &- result : result)
    return WebCore.HTMLMicrosyntaxIntegerResult(value: value, error: .Other, isValid: true)
}

// https://html.spec.whatwg.org/#valid-non-negative-integer
func htmlMicrosyntaxParseValidHTMLNonNegativeInteger<CodeUnit: HTMLMicrosyntaxCodeUnit>(_ characters: Span<CodeUnit>) -> Int32? {
    guard !characters.isEmpty else {
        return nil
    }
    for index in characters.indices where !characters[index].htmlMicrosyntaxIsASCIIDigit {
        return nil
    }
    let result = htmlMicrosyntaxParseHTMLInteger(characters)
    guard result.isValid, result.value >= 0 else {
        return nil
    }
    return result.value
}

// MARK: Floating-point numbers

// https://html.spec.whatwg.org/#valid-floating-point-number
func htmlMicrosyntaxParseValidHTMLFloatingPointNumber<CodeUnit: HTMLMicrosyntaxCodeUnit>(_ characters: Span<CodeUnit>) -> Double? {
    guard !characters.isEmpty else {
        return nil
    }
    // WTF::parseDouble() accepts a leading '+' and a trailing '.', which a valid floating-point number does not have.
    if characters[0].htmlMicrosyntaxMatches("+") {
        return nil
    }
    if characters[characters.count - 1].htmlMicrosyntaxMatches(".") {
        return nil
    }
    let (number, length) = CodeUnit.htmlMicrosyntaxParseDouble(characters)
    guard length == characters.count, number.isFinite else {
        return nil
    }
    return number
}

/// The rules for parsing floating-point number values, as parseHTMLFloatingPointNumberValue(), or, when
/// `isNumberType` is set, the value of a number input, as parseToDoubleForNumberType(), for an 8-bit StringView.
///
/// `characters` are the characters of the caller's StringView. They stay allocated and unchanged for the call, since
/// the caller holds their string and this function only reads them, as does WTF::parseDouble(), the only C++ it passes
/// them to, and every value of a Latin-1 code unit is a valid character.
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxParseFloatingPointNumberValue8(
    _ characters: WebCore.HTMLMicrosyntaxSpan8,
    _ fallbackValue: Double,
    _ isNumberType: Bool
) -> Double {
    let span = unsafe Span<WTF.Latin1Character>(_unsafeCxxSpan: characters)
    return isNumberType ? parseToDoubleForNumberType(span, fallbackValue) : parseHTMLFloatingPointNumberValue(span, fallbackValue)
}

/// htmlMicrosyntaxParseFloatingPointNumberValue8() for a 16-bit StringView, whose characters stay allocated and
/// unchanged for the call in the same way, and every value of a UTF-16 code unit is a valid character.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxParseFloatingPointNumberValue16(
    _ characters: WebCore.HTMLMicrosyntaxSpan16,
    _ fallbackValue: Double,
    _ isNumberType: Bool
) -> Double {
    let span = unsafe Span<UInt16>(_unsafeCxxSpan: characters)
    return isNumberType ? parseToDoubleForNumberType(span, fallbackValue) : parseHTMLFloatingPointNumberValue(span, fallbackValue)
}

extension HTMLMicrosyntaxCodeUnit {
    /// Whether this is '+', '-', '.' or an ASCII digit, which a floating-point number value starts with.
    @inline(always)
    fileprivate var isHTMLFloatingPointNumberValueStart: Bool {
        // Bit n of the mask is set when the character n after '+' is one, so that one shift tests them all. Characters
        // below '+' wrap to large offsets.
        let offset = UInt32(htmlMicrosyntaxCodeUnit) &- 0x2B
        return offset < 15 && (0b111_1111_1110_1101 &>> offset) & 1 != 0
    }
}

// https://html.spec.whatwg.org/#rules-for-parsing-floating-point-number-values
@inline(never)
private func parseHTMLFloatingPointNumberValue<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ fallbackValue: Double
) -> Double {
    guard !characters.isEmpty else {
        return fallbackValue
    }
    // The number usually starts at the first character, which is tested before any whitespace is skipped.
    var start = 0
    if !characters[0].isHTMLFloatingPointNumberValueStart {
        start = characters.htmlMicrosyntaxIndexAfterASCIIWhitespace(from: 0)
        guard start < characters.count, characters[start].isHTMLFloatingPointNumberValueStart else {
            return fallbackValue
        }
    }

    let (number, length) = characters.htmlMicrosyntaxParseDouble(start..<characters.count)
    guard length > 0 else {
        return fallbackValue
    }

    // -0 becomes +0.
    return number == 0 ? 0 : number
}

// https://html.spec.whatwg.org/#floating-point-numbers
@inline(never)
private func parseToDoubleForNumberType<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ fallbackValue: Double
) -> Double {
    guard !characters.isEmpty else {
        return fallbackValue
    }

    // WTF::parseDouble() accepts a leading '+', which is not valid here, and leading whitespace never reaches it.
    let first = characters[0]
    guard first.htmlMicrosyntaxMatches("-") || first.htmlMicrosyntaxMatches(".") || first.htmlMicrosyntaxIsASCIIDigit else {
        return fallbackValue
    }

    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    let allowsStringsThatEndWithFullStop = !WTF.linkedOnOrAfterSDKWithBehavior(
        WTF.SDKAlignedBehavior.DoesNotParseStringEndingWithFullStopAsFloatingPointNumber
    )
    #else
    let allowsStringsThatEndWithFullStop = false
    #endif
    if characters[characters.count - 1].htmlMicrosyntaxMatches("."), !allowsStringsThatEndWithFullStop {
        return fallbackValue
    }

    let (value, length) = CodeUnit.htmlMicrosyntaxParseDouble(characters)
    guard length == characters.count, value.isFinite else {
        return fallbackValue
    }

    // -0 becomes +0.
    return value == 0 ? 0 : value
}

// MARK: Lists of floating-point numbers

extension HTMLMicrosyntaxCodeUnit {
    @inline(always)
    fileprivate var isHTMLSpaceOrDelimiter: Bool {
        htmlMicrosyntaxIsASCIIWhitespace || htmlMicrosyntaxMatches(",") || htmlMicrosyntaxMatches(";")
    }

    @inline(always)
    fileprivate var isHTMLSpaceOrDelimiterOrNumberStart: Bool {
        isHTMLSpaceOrDelimiter || htmlMicrosyntaxIsASCIIDigit || htmlMicrosyntaxMatches(".") || htmlMicrosyntaxMatches("-")
    }
}

extension Span where Element: HTMLMicrosyntaxCodeUnit {
    @inline(always)
    fileprivate func indexAfterHTMLSpacesOrDelimiters(from index: Int) -> Int {
        var index = index
        while index < count, self[index].isHTMLSpaceOrDelimiter {
            index += 1
        }
        return index
    }

    /// The characters of the number of a list that starts at `index`, past any delimiters, and the index after
    /// the delimiters that follow it.
    ///
    /// Garbage before the number is skipped, and the number goes to the next delimiter.
    fileprivate func nextHTMLFloatingPointNumber(from index: Int) -> (number: Range<Int>, next: Int) {
        var start = index
        while start < count, !self[start].isHTMLSpaceOrDelimiterOrNumberStart {
            start += 1
        }
        var end = start
        while end < count, !self[end].isHTMLSpaceOrDelimiter {
            end += 1
        }
        return (start..<end, indexAfterHTMLSpacesOrDelimiters(from: end))
    }
}

/// Writes the values parseHTMLListOfOfFloatingPointNumberValues() returns for the characters of an 8-bit StringView
/// into `numbers`, and returns how many it wrote.
///
/// `numbers` has room for (length + 1) / 2 values, the most a list of that length has, since each value takes at least
/// one character and the next one starts after at least one delimiter. `numbers` is storage the caller owns for the
/// call; nothing else reads or writes it while this function fills it, and it does not overlap the characters. This
/// function only stores whole doubles into it and reads none, so the doubles the caller leaves uninitialized are never
/// read.
/// `characters` are the characters of the caller's StringView. They stay allocated and unchanged for the call, since
/// the caller holds their string and this function only reads them, as does WTF::parseDouble(), the only C++ it passes
/// them to, and every value of a Latin-1 code unit is a valid character.
/// FIXME: Take the characters and the numbers as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxParseListOfFloatingPointNumbers8(
    _ characters: WebCore.HTMLMicrosyntaxSpan8,
    _ numbers: WebCore.HTMLMicrosyntaxDoubles
) -> UInt32 {
    let span = unsafe Span<WTF.Latin1Character>(_unsafeCxxSpan: characters)
    let output = unsafe MutableSpan<Double>(_unsafeCxxSpan: numbers)
    return parseHTMLListOfFloatingPointNumbers(span, output)
}

/// htmlMicrosyntaxParseListOfFloatingPointNumbers8() for a 16-bit StringView.
///
/// `numbers`, with room for (length + 1) / 2 values, and the characters hold for the call in the same way, and every
/// value of a UTF-16 code unit is a valid character.
/// FIXME: Take the characters and the numbers as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxParseListOfFloatingPointNumbers16(
    _ characters: WebCore.HTMLMicrosyntaxSpan16,
    _ numbers: WebCore.HTMLMicrosyntaxDoubles
) -> UInt32 {
    let span = unsafe Span<UInt16>(_unsafeCxxSpan: characters)
    let output = unsafe MutableSpan<Double>(_unsafeCxxSpan: numbers)
    return parseHTMLListOfFloatingPointNumbers(span, output)
}

// https://html.spec.whatwg.org/multipage/infrastructure.html#rules-for-parsing-floating-point-number-values
@inline(never)
private func parseHTMLListOfFloatingPointNumbers<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ numbers: consuming MutableSpan<Double>
) -> UInt32 {
    var count = 0
    var index = characters.indexAfterHTMLSpacesOrDelimiters(from: 0)
    // numbers has room for every value, so the loop ends at the end of the characters.
    while index < characters.count, count < numbers.count {
        let token = characters.nextHTMLFloatingPointNumber(from: index)
        // A number that does not parse, or is not finite, is 0.
        let (number, length) = characters.htmlMicrosyntaxParseDouble(token.number)
        numbers[count] = length > 0 && number.isFinite ? number : 0
        count += 1
        index = token.next
    }
    // At most the number of characters, which a StringView keeps in 32 bits.
    return UInt32(truncatingIfNeeded: count)
}

// MARK: Refresh

/// The URL of a <meta http-equiv="refresh"> value, as parseMetaHTTPEquivRefresh(), which sets `delay` to its time
/// when the value is valid, for an 8-bit StringView.
///
/// `characters` are the characters of the caller's StringView. They stay allocated and unchanged for the call, since
/// the caller holds their string and this function only reads them and passes them to no C++, and every value of a
/// Latin-1 code unit is a valid character.
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxParseMetaRefresh8(
    _ characters: WebCore.HTMLMicrosyntaxSpan8,
    _ delay: inout Double
) -> WebCore.HTMLMicrosyntaxRefreshResult {
    let span = unsafe Span<WTF.Latin1Character>(_unsafeCxxSpan: characters)
    return parseHTMLRefresh(span, &delay)
}

/// htmlMicrosyntaxParseMetaRefresh8() for a 16-bit StringView, whose characters stay allocated and unchanged for
/// the call in the same way, and every value of a UTF-16 code unit is a valid character.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxParseMetaRefresh16(
    _ characters: WebCore.HTMLMicrosyntaxSpan16,
    _ delay: inout Double
) -> WebCore.HTMLMicrosyntaxRefreshResult {
    let span = unsafe Span<UInt16>(_unsafeCxxSpan: characters)
    return parseHTMLRefresh(span, &delay)
}

extension HTMLMicrosyntaxCodeUnit {
    @inline(always)
    fileprivate var isASCIIDigitOrPeriod: Bool {
        htmlMicrosyntaxIsASCIIDigit || htmlMicrosyntaxMatches(".")
    }

    @inline(always)
    fileprivate var isSemicolonOrComma: Bool {
        htmlMicrosyntaxMatches(";") || htmlMicrosyntaxMatches(",")
    }

    /// Whether this is the ASCII letter `lowercaseLetter` or its upper-case form, which differs from it only in 0x20.
    @inline(always)
    fileprivate func matchesIgnoringASCIICase(_ lowercaseLetter: Unicode.Scalar) -> Bool {
        htmlMicrosyntaxCodeUnit | 0x20 == UInt16(truncatingIfNeeded: lowercaseLetter.value)
    }
}

// https://html.spec.whatwg.org/multipage/semantics.html#attr-meta-http-equiv-refresh
@inline(never)
private func parseHTMLRefresh<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ delay: inout Double
) -> WebCore.HTMLMicrosyntaxRefreshResult {
    let invalid = WebCore.HTMLMicrosyntaxRefreshResult(urlStart: 0, urlLength: 0, isValid: false, hasURL: false)

    var index = characters.htmlMicrosyntaxIndexAfterASCIIWhitespace(from: 0)
    let numberStart = index
    index = characters.htmlMicrosyntaxIndexAfterASCIIDigits(from: index)

    var time: UInt32 = 0
    if index == numberStart {
        guard index < characters.count, characters[index].htmlMicrosyntaxMatches(".") else {
            return invalid
        }
    } else {
        let number = htmlMicrosyntaxParseHTMLInteger(characters.extracting(numberStart..<index))
        guard number.isValid, number.value >= 0 else {
            return invalid
        }
        time = UInt32(truncatingIfNeeded: number.value)
    }

    // The fraction is ignored.
    while index < characters.count, characters[index].isASCIIDigitOrPeriod {
        index += 1
    }

    let withoutURL = WebCore.HTMLMicrosyntaxRefreshResult(urlStart: 0, urlLength: 0, isValid: true, hasURL: false)
    guard index < characters.count else {
        delay = Double(time)
        return withoutURL
    }

    let separator = characters[index]
    guard separator.isSemicolonOrComma || separator.htmlMicrosyntaxIsASCIIWhitespace else {
        return invalid
    }
    delay = Double(time)

    index = characters.htmlMicrosyntaxIndexAfterASCIIWhitespace(from: index)
    if index < characters.count, characters[index].isSemicolonOrComma {
        index += 1
    }
    index = characters.htmlMicrosyntaxIndexAfterASCIIWhitespace(from: index)
    guard index < characters.count else {
        return withoutURL
    }

    // Unless "url" and "=" follow it, the URL starts at the 'u'.
    let urlFromLetterU = WebCore.HTMLMicrosyntaxRefreshResult(
        urlStart: UInt32(truncatingIfNeeded: index),
        urlLength: UInt32(truncatingIfNeeded: characters.count - index),
        isValid: true,
        hasURL: true
    )
    if characters[index].matchesIgnoringASCIICase("u") {
        index += 1
        guard index < characters.count, characters[index].matchesIgnoringASCIICase("r") else {
            return urlFromLetterU
        }
        index += 1
        guard index < characters.count, characters[index].matchesIgnoringASCIICase("l") else {
            return urlFromLetterU
        }
        index = characters.htmlMicrosyntaxIndexAfterASCIIWhitespace(from: index + 1)
        guard index < characters.count, characters[index].htmlMicrosyntaxMatches("=") else {
            return urlFromLetterU
        }
        index = characters.htmlMicrosyntaxIndexAfterASCIIWhitespace(from: index + 1)
    }

    // A quoted URL ends at the matching quote, or at the end when there is none.
    var end = characters.count
    if index < characters.count {
        let quote = characters[index]
        if quote.htmlMicrosyntaxMatches("'") || quote.htmlMicrosyntaxMatches("\"") {
            index += 1
            // A quote is ASCII, so its code unit is its low byte.
            end = characters.htmlMicrosyntaxIndex(of: UInt8(truncatingIfNeeded: quote.htmlMicrosyntaxCodeUnit), from: index)
        }
    }

    return WebCore.HTMLMicrosyntaxRefreshResult(
        urlStart: UInt32(truncatingIfNeeded: index),
        urlLength: UInt32(truncatingIfNeeded: end - index),
        isValid: true,
        hasURL: true
    )
}

// MARK: Dimensions

/// A dimension value, as parseHTMLDimension() and parseHTMLMultiLength(), or a NaN number when there is none, for an
/// 8-bit StringView.
///
/// `characters` are the characters of the caller's StringView. They stay allocated and unchanged for the call, since
/// the caller holds their string and this function only reads them, as does WTF::parseDouble(), the only C++ it passes
/// them to, and every value of a Latin-1 code unit is a valid character.
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxParseDimension8(_ characters: WebCore.HTMLMicrosyntaxSpan8, _ isMultiLength: Bool) -> WebCore.HTMLDimension {
    let span = unsafe Span<WTF.Latin1Character>(_unsafeCxxSpan: characters)
    return parseHTMLDimension(span, isMultiLength)
}

/// htmlMicrosyntaxParseDimension8() for a 16-bit StringView, whose characters stay allocated and unchanged for the
/// call in the same way, and every value of a UTF-16 code unit is a valid character.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxParseDimension16(_ characters: WebCore.HTMLMicrosyntaxSpan16, _ isMultiLength: Bool) -> WebCore.HTMLDimension {
    let span = unsafe Span<UInt16>(_unsafeCxxSpan: characters)
    return parseHTMLDimension(span, isMultiLength)
}

// https://html.spec.whatwg.org/#rules-for-parsing-dimension-values
@inline(never)
private func parseHTMLDimension<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ isMultiLength: Bool
) -> WebCore.HTMLDimension {
    let noValue = WebCore.HTMLDimension(number: .nan, type: .Pixel)

    let start = characters.htmlMicrosyntaxIndexAfterASCIIWhitespace(from: 0)
    guard start < characters.count else {
        return noValue
    }
    var end = characters.htmlMicrosyntaxIndexAfterASCIIDigits(from: start)
    guard end > start else {
        return noValue
    }
    if end < characters.count, characters[end].htmlMicrosyntaxMatches(".") {
        end = characters.htmlMicrosyntaxIndexAfterASCIIDigits(from: end + 1)
    }

    let (number, length) = characters.htmlMicrosyntaxParseDouble(start..<end)
    guard length > 0, number.isFinite else {
        return noValue
    }

    // A relative length, a number followed by '*', is not a multi-length here.
    if isMultiLength, end < characters.count, characters[end].htmlMicrosyntaxMatches("*") {
        return noValue
    }

    var isPercentage = false
    if end < characters.count, characters[end].htmlMicrosyntaxMatches("%") {
        isPercentage = true
    }
    return WebCore.HTMLDimension(number: number, type: isPercentage ? .Percentage : .Pixel)
}

// MARK: Lists of dimensions

extension HTMLMicrosyntaxCodeUnit {
    @inline(always)
    fileprivate var isASCIIWhitespaceOrDigit: Bool {
        htmlMicrosyntaxIsASCIIWhitespace || htmlMicrosyntaxIsASCIIDigit
    }
}

extension Span where Element: HTMLMicrosyntaxCodeUnit {
    /// The number of characters of a list of dimensions without its last character when that is a comma.
    fileprivate var htmlDimensionsListLength: Int {
        if !isEmpty, self[count - 1].htmlMicrosyntaxMatches(",") {
            return count - 1
        }
        return count
    }

    /// The index after the next comma at or after `index`, or `count`.
    fileprivate func indexAfterComma(from index: Int) -> Int {
        var index = index
        while index < count, !self[index].htmlMicrosyntaxMatches(",") {
            index += 1
        }
        return index < count ? index + 1 : index
    }
}

/// The number of values parseHTMLDimensionsList() returns for the characters of an 8-bit StringView.
///
/// `characters` are the characters of the caller's StringView. They stay allocated and unchanged for the call, since
/// the caller holds their string and this function only reads them and passes them to no C++, and every value of a
/// Latin-1 code unit is a valid character.
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxCountDimensions8(_ characters: WebCore.HTMLMicrosyntaxSpan8) -> UInt32 {
    let span = unsafe Span<WTF.Latin1Character>(_unsafeCxxSpan: characters)
    return countHTMLDimensions(span)
}

/// htmlMicrosyntaxCountDimensions8() for a 16-bit StringView, whose characters stay allocated and unchanged for the
/// call in the same way, and every value of a UTF-16 code unit is a valid character.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxCountDimensions16(_ characters: WebCore.HTMLMicrosyntaxSpan16) -> UInt32 {
    let span = unsafe Span<UInt16>(_unsafeCxxSpan: characters)
    return countHTMLDimensions(span)
}

private func countHTMLDimensions<CodeUnit: HTMLMicrosyntaxCodeUnit>(_ characters: Span<CodeUnit>) -> UInt32 {
    guard !characters.isEmpty else {
        return 0
    }
    let list = characters.extracting(0..<characters.htmlDimensionsListLength)
    // One more than the commas, after a last comma is dropped. A list of 16 characters or more is counted out of line,
    // 16 at a time. No sum overflows: there is at most one comma per character, and a StringView has fewer than 2^32.
    guard list.count < 16 else {
        return 1 &+ CodeUnit.htmlMicrosyntaxCount(of: UInt8(ascii: ","), in: list)
    }
    var count: UInt32 = 1
    for index in 0..<list.count {
        count &+= list[index].htmlMicrosyntaxMatches(",") ? 1 : 0
    }
    return count
}

/// Writes the values parseHTMLDimensionsList() returns for the characters of an 8-bit StringView into `values`,
/// which has room for as many as htmlMicrosyntaxCountDimensions8() counts.
///
/// `values` is storage the caller owns for the call; nothing else reads or writes it while this function fills it, and
/// it does not overlap the characters. This function only stores whole values into it, each with a valid unit, and
/// reads none, so the elements the caller leaves uninitialized (any bits in their unit and padding) are never read.
/// `characters` are the characters of the caller's StringView. They stay allocated and unchanged for the call, since
/// the caller holds their string and this function only reads them and passes them to no C++, and every value of a
/// Latin-1 code unit is a valid character.
/// FIXME: Take the characters and the values as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxParseDimensionsList8(_ characters: WebCore.HTMLMicrosyntaxSpan8, _ values: WebCore.HTMLMicrosyntaxDimensions) {
    let span = unsafe Span<WTF.Latin1Character>(_unsafeCxxSpan: characters)
    let output = unsafe MutableSpan<WebCore.HTMLDimensionsListValue>(_unsafeCxxSpan: values)
    parseHTMLDimensionsList(span, output)
}

/// htmlMicrosyntaxParseDimensionsList8() for a 16-bit StringView, with room for as many as
/// htmlMicrosyntaxCountDimensions16() counts.
///
/// `values` and the characters hold for the call in the same way, and every value of a UTF-16 code unit is a valid
/// character.
/// FIXME: Take the characters and the values as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxParseDimensionsList16(_ characters: WebCore.HTMLMicrosyntaxSpan16, _ values: WebCore.HTMLMicrosyntaxDimensions) {
    let span = unsafe Span<UInt16>(_unsafeCxxSpan: characters)
    let output = unsafe MutableSpan<WebCore.HTMLDimensionsListValue>(_unsafeCxxSpan: values)
    parseHTMLDimensionsList(span, output)
}

// https://html.spec.whatwg.org/multipage/common-microsyntaxes.html#lists-of-dimensions
@inline(never)
private func parseHTMLDimensionsList<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ values: consuming MutableSpan<WebCore.HTMLDimensionsListValue>
) {
    guard !values.isEmpty else {
        return
    }
    // The tokens are split on commas as they are read, after a last comma is dropped.
    let list = characters.extracting(0..<characters.htmlDimensionsListLength)
    // The value of a token that is too large for an unsigned integer.
    let overflowValue = WebCore.HTMLDimensionsListValue(number: 1, unit: .Relative)

    var index = 0
    for token in 0..<values.count {
        index = list.htmlMicrosyntaxIndexAfterASCIIWhitespace(from: index)
        guard index < list.count else {
            values[token] = WebCore.HTMLDimensionsListValue(number: 0, unit: .Relative)
            continue
        }
        if list[index].htmlMicrosyntaxMatches(",") {
            index += 1
            values[token] = WebCore.HTMLDimensionsListValue(number: 0, unit: .Relative)
            continue
        }

        var unit: WebCore.HTMLDimensionsListValue.Unit = .Absolute

        var integer: UInt32 = 0
        var integerOverflowed = false
        while index < list.count, let digitValue = list[index].htmlMicrosyntaxASCIIDigitValue {
            let (product, productOverflowed) = integer.multipliedReportingOverflow(by: 10)
            let (sum, sumOverflowed) = product.addingReportingOverflow(digitValue)
            integer = sum
            integerOverflowed = integerOverflowed || productOverflowed || sumOverflowed
            index += 1
        }
        if integerOverflowed {
            values[token] = overflowValue
            index = list.indexAfterComma(from: index)
            continue
        }

        var value = Double(integer)

        if index < list.count, list[index].htmlMicrosyntaxMatches(".") {
            index += 1
            // Whitespace between the digits of the fraction is skipped.
            var length = 0
            var fraction: UInt32 = 0
            var fractionOverflowed = false
            while index < list.count, list[index].isASCIIWhitespaceOrDigit {
                if let digitValue = list[index].htmlMicrosyntaxASCIIDigitValue {
                    // Cannot overflow: at most one per character.
                    length &+= 1
                    let (product, productOverflowed) = fraction.multipliedReportingOverflow(by: 10)
                    let (sum, sumOverflowed) = product.addingReportingOverflow(digitValue)
                    fraction = sum
                    fractionOverflowed = fractionOverflowed || productOverflowed || sumOverflowed
                }
                index += 1
            }
            if fractionOverflowed {
                values[token] = overflowValue
                index = list.indexAfterComma(from: index)
                continue
            }
            if length > 0 {
                value += Double(fraction) / pow(10.0, Double(length))
            }
        }

        index = list.htmlMicrosyntaxIndexAfterASCIIWhitespace(from: index)

        if index < list.count {
            if list[index].htmlMicrosyntaxMatches("%") {
                index += 1
                unit = .Percentage
            } else if list[index].htmlMicrosyntaxMatches("*") {
                index += 1
                unit = .Relative
            }
        }

        values[token] = WebCore.HTMLDimensionsListValue(number: value, unit: unit)

        // Anything else up to the next comma is ignored.
        index = list.indexAfterComma(from: index)
    }
}
