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

// Without these, no operator in this file type-checks: WebCore's C++ operators name types these modules define.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch

internal import WebCore_Private.Core.CSSParserFastPathsSwiftTypes

// For lroundf.
#if canImport(Darwin)
internal import Darwin
#elseif canImport(ucrt)
internal import ucrt
#elseif canImport(Glibc)
internal import Glibc
#endif

// The fast paths of CSSParserFastPaths.cpp: hex, named, rgb() and hsl() colors, lengths, opacity and simple
// transform lists. A color is returned as a PackedColor::ARGB in the low 32 bits, or -1 when the input is not one
// the fast path takes; a length or an opacity as a CSSFastPathNumber; a transform list through the
// CSSFastPathTransformSink, which makes the values. Every input the fast paths do not take goes to the full
// parser.

/// The color result for an input that is not a color the fast path takes.
private let notAColor: Int64 = -1

/// The number result for an input that is not a number the fast path takes.
private var notANumber: WebCore.CSSFastPathNumber {
    WebCore.CSSFastPathNumber(value: 0, unit: WebCore.CSSUnitType.Number, ok: false)
}

/// A code unit of 8-bit or 16-bit input, with the width's `charactersToDouble`.
///
/// FIXME: Make this private once a private protocol links under ThinLTO on Windows.
protocol CSSFastPathCodeUnit: FixedWidthInteger & UnsignedInteger {
    /// `charactersToDouble` over the whole of `characters`, which is not empty.
    static func parseNumber(_ characters: Span<Self>) -> WebCore.CSSFastPathNumber
}

extension UInt8: CSSFastPathCodeUnit {
    @inline(always)
    static func parseNumber(_ characters: Span<UInt8>) -> WebCore.CSSFastPathNumber {
        WebCore.cssFastPathParseNumber8(characters)
    }
}

extension UInt16: CSSFastPathCodeUnit {
    @inline(always)
    static func parseNumber(_ characters: Span<UInt16>) -> WebCore.CSSFastPathNumber {
        WebCore.cssFastPathParseNumber16(characters)
    }
}

@inline(always)
private func widen(_ unit: some CSSFastPathCodeUnit) -> UInt32 { UInt32(truncatingIfNeeded: unit) }

// MARK: - Character predicates
//
// Each is the ASCIICType.h or CSSParserIdioms.h function of the same name, over a whole code unit, so that no
// 16-bit code unit matches an ASCII character by its low byte.

@inline(always)
private func isASCII(_ unit: UInt32) -> Bool { unit & ~0x7F == 0 }

@inline(always)
private func isASCIIDigit(_ unit: UInt32) -> Bool {
    // Wraps below '0' on purpose, so one compare tests both ends.
    unit &- 0x30 < 10
}

/// `isCSSSpace`: space, tab and newline.
@inline(always)
private func isCSSSpace(_ unit: UInt32) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0A }

/// `isASCIIWhitespace`: space, newline, tab, carriage return and form feed.
@inline(always)
private func isASCIIWhitespace(_ unit: UInt32) -> Bool {
    unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D || unit == 0x0C
}

/// `isUnicodeCompatibleASCIIWhitespace`: `isASCIIWhitespace` and vertical tab, which `charactersToDouble` skips.
@inline(always)
private func isUnicodeCompatibleASCIIWhitespace(_ unit: UInt32) -> Bool {
    isASCIIWhitespace(unit) || unit == 0x0B
}

/// `isUnicodeCompatibleASCIIWhitespace` as 1 or 0, computed without a branch: space, or tab through carriage return.
@inline(always)
private func unicodeCompatibleASCIIWhitespaceCount(_ unit: UInt32) -> Int {
    let isSpace = unit == 0x20 ? 1 : 0
    // Wraps below tab on purpose, so one compare tests both ends.
    let isTabThroughCarriageReturn = unit &- 0x09 < 5 ? 1 : 0
    return isSpace | isTabThroughCarriageReturn
}

/// `isASCIIAlphaCaselessEqual(unit, letter)` for a lowercase `letter`.
@inline(always)
private func isASCIIAlphaCaselessEqual(_ unit: UInt32, _ letter: UInt32) -> Bool {
    unit | 0x20 == letter
}

// MARK: - Hex colors

/// `finishParsingHexColor`, as a `PackedColor::ARGB`.
@inline(always)
private func finishParsingHexColor(_ value: UInt32, _ length: Int) -> Int64 {
    switch length {
    case 3:
        // #234 converts to #223344.
        let r = (value & 0x0F00) >> 8
        let g = (value & 0x00F0) >> 4
        let b = value & 0x000F
        return Int64(0xFF00_0000 | (r << 4 | r) << 16 | (g << 4 | g) << 8 | (b << 4 | b))
    case 4:
        // #234a converts to #223344aa.
        let r = (value & 0xF000) >> 12
        let g = (value & 0x0F00) >> 8
        let b = (value & 0x00F0) >> 4
        let a = value & 0x000F
        return Int64((a << 4 | a) << 24 | (r << 4 | r) << 16 | (g << 4 | g) << 8 | (b << 4 | b))
    case 6:
        return Int64(0xFF00_0000 | value)
    case 8:
        // The digits are RGBA; ARGB has the alpha byte first.
        return Int64((value & 0xFF) << 24 | value >> 8)
    default:
        return notAColor
    }
}

/// `parseHexColorInternal`: 3, 4, 6 or 8 hex digits, without a "#".
@inline(always)
private func scanHexColor<Unit: CSSFastPathCodeUnit>(_ characters: Span<Unit>) -> Int64 {
    let count = characters.count
    guard count == 3 || count == 4 || count == 6 || count == 8 else {
        return notAColor
    }

    // Every unit is read and its validity collected, so that the loop has no branch on the digits themselves; the value
    // is used only when all of them are hex digits.
    var value: UInt32 = 0
    var valid: UInt32 = 1
    for index in 0..<count {
        let unit = widen(characters[index])
        // Each subtraction wraps below its range on purpose, so one compare tests both ends.
        let isDigit: UInt32 = unit &- 0x30 < 10 ? 1 : 0
        let isLetter: UInt32 = (unit | 0x20) &- 0x61 < 6 ? 1 : 0
        valid &= isDigit | isLetter
        // A digit's low four bits, or a letter's (bit 6 set, in either case) plus 9.
        value = value << 4 | ((unit & 0xF) + 9 * (unit >> 6 & 1))
    }
    guard valid != 0 else {
        return notAColor
    }
    return finishParsingHexColor(value, count)
}

// MARK: - Named colors

/// Code units `start..<start + count` of 8-bit input, `count` at most 8, as the bytes of a word, the first in the low byte.
@inline(always)
private func wordOfBytes<Unit: CSSFastPathCodeUnit>(_ characters: Span<Unit>, _ start: Int, _ count: Int) -> UInt64 {
    // Cannot overflow: start + count is at most characters.count, which the extraction checks.
    let units = characters.extracting(start..<start &+ count)
    var word: UInt64 = 0
    for i in 0..<count {
        word |= UInt64(widen(units[i])) << (8 * i)
    }
    return word
}

/// `parseNamedColorInternal`: an ASCII name of up to 63 characters, in any case.
@inline(always)
private func scanNamedColor<Unit: CSSFastPathCodeUnit>(_ characters: Span<Unit>) -> Int64 {
    let count = characters.count
    // As big as the C++'s buffer, which keeps one byte for a terminator findColor does not read.
    var folded = InlineArray<64, UInt8>(repeating: 0)
    guard count <= folded.count - 1 else {
        return notAColor
    }

    // Every name in ColorData.gperf is lowercase ASCII letters. Setting 0x20 makes the lowercase letter of an
    // uppercase one and makes no letter of a code unit that is not one, so the names this finds are those
    // toASCIILower would.
    if MemoryLayout<Unit>.size == 1, count >= 4 {
        // Eight or four code units at a time, the last group overlapping the one before it: a 0 byte or a byte of
        // 0x80 or more sets a high bit in `rejected` (a borrow only crosses a byte above a 0 byte).
        var rejected: UInt64 = 0
        var span = folded.mutableSpan
        var bytes = span.mutableBytes
        if count >= 8 {
            var offset = 0
            while true {
                // Cannot overflow: count is at least 8.
                let start = min(offset, count &- 8)
                let word = wordOfBytes(characters, start, 8)
                rejected |= ((word &- 0x0101_0101_0101_0101) | word) & 0x8080_8080_8080_8080
                bytes.storeBytes(of: (word | 0x2020_2020_2020_2020).littleEndian, toByteOffset: start, as: UInt64.self)
                // Cannot overflow: below 64.
                offset &+= 8
                if offset >= count {
                    break
                }
            }
        } else {
            // Bytes 0-3 in the low half, the last four in the high half. Cannot overflow: count is at least 4.
            let word = wordOfBytes(characters, 0, 4) | wordOfBytes(characters, count &- 4, 4) << 32
            rejected = ((word &- 0x0101_0101_0101_0101) | word) & 0x8080_8080_8080_8080
            let lowered = word | 0x2020_2020_2020_2020
            bytes.storeBytes(of: UInt32(truncatingIfNeeded: lowered).littleEndian, toByteOffset: 0, as: UInt32.self)
            // Cannot overflow: count is at least 4.
            bytes.storeBytes(of: UInt32(truncatingIfNeeded: lowered >> 32).littleEndian, toByteOffset: count &- 4, as: UInt32.self)
        }
        guard rejected == 0 else {
            return notAColor
        }
    } else {
        for index in 0..<count {
            let value = widen(characters[index])
            guard value != 0, isASCII(value) else {
                return notAColor
            }
            folded[index] = UInt8(truncatingIfNeeded: value) | 0x20
        }
    }
    return WebCore.cssFastPathFindNamedColor(folded.span.extracting(0..<count))
}

// MARK: - A position in the input

/// The input and a position in it, for the C++'s `std::span` that ParsingUtilities.h's `skip`, `skipExactly` and
/// `consume` advance.
///
/// Offsets stay within the input, whose count is below 2^31, so sums and differences of two offsets cannot
/// overflow.
private struct Cursor<Unit: CSSFastPathCodeUnit>: ~Escapable {
    let characters: Span<Unit>
    /// How much of the input has been consumed.
    var offset: Int = 0

    @inline(always)
    @_lifetime(copy characters)
    init(_ characters: Span<Unit>) {
        self.characters = characters
    }

    /// The length of the whole input, not of what remains.
    var count: Int {
        @inline(always)
        get { characters.count }
    }

    /// The code unit at `index` of the whole input.
    @inline(always)
    func unit(_ index: Int) -> UInt32 { widen(characters[index]) }

    /// The 8 code units from `index` of 8-bit input as the bytes of a word, the first in the low byte.
    @inline(always)
    func word(_ index: Int) -> UInt64 { wordOfBytes(characters, index, 8) }

    /// `charactersToDouble` over `start..<end` of the whole input.
    @inline(always)
    func parseNumber(_ start: Int, _ end: Int) -> WebCore.CSSFastPathNumber {
        Unit.parseNumber(characters.extracting(start..<end))
    }

    var isEmpty: Bool {
        @inline(always)
        get { offset >= count }
    }

    /// The number of code units that remain.
    var remaining: Int {
        @inline(always)
        get {
            // Cannot overflow: an offset within the input.
            count &- offset
        }
    }

    /// The first code unit that remains, or nil.
    @inline(always)
    func front() -> UInt32? { offset < count ? unit(offset) : nil }

    /// The code unit at `index` of what remains.
    @inline(always)
    func at(_ index: Int) -> UInt32 {
        // Cannot overflow: an offset within the input.
        unit(offset &+ index)
    }

    @inline(always)
    mutating func skip(_ n: Int) {
        // Cannot overflow: an offset within the input.
        offset &+= n
    }

    @inline(always)
    mutating func skipExactly(_ expected: UInt32) -> Bool {
        guard offset < count, unit(offset) == expected else {
            return false
        }
        // Cannot overflow: an offset within the input.
        offset &+= 1
        return true
    }

    @inline(always)
    mutating func skipASCIIWhitespace() {
        while offset < count, isASCIIWhitespace(unit(offset)) {
            // Cannot overflow: an offset within the input.
            offset &+= 1
        }
    }

    @inline(always)
    mutating func skipCSSSpace() {
        while offset < count, isCSSSpace(unit(offset)) {
            // Cannot overflow: an offset within the input.
            offset &+= 1
        }
    }

    @inline(always)
    mutating func skipASCIIDigits() {
        while offset < count, isASCIIDigit(unit(offset)) {
            // Cannot overflow: an offset within the input.
            offset &+= 1
        }
    }
}

// MARK: - CSSParserFastPaths.cpp's own decimal parser

/// `checkForValidDouble`: the length of the digits, with at most one ".", before `terminator`, or 0, which is also
/// the answer when there is no terminator.
@inline(always)
private func checkForValidDouble<Unit>(_ cursor: borrowing Cursor<Unit>, _ terminator: UInt32) -> Int {
    let length = cursor.remaining
    if length < 1 {
        return 0
    }

    var decimalMarkOffset: Int? = nil
    var processedLength = 0

    var index = 0
    while index < length {
        let value = cursor.at(index)
        if value == terminator {
            processedLength = index
            break
        }
        if !isASCIIDigit(value) {
            guard decimalMarkOffset == nil, value == 0x2E else {
                return 0
            }
            decimalMarkOffset = index
        }
        // Cannot overflow: an offset within the input.
        index &+= 1
    }

    // CSS disallows a period without a subsequent digit. Without a terminator processedLength is 0, and no offset
    // is -1.
    if let mark = decimalMarkOffset, mark == processedLength - 1 {
        return 0
    }

    return processedLength
}

/// `parseDouble` of CSSParserFastPaths.cpp, not WTF's: the length consumed and the value, or nil.
@inline(always)
private func parseDouble<Unit>(_ cursor: borrowing Cursor<Unit>, _ terminator: UInt32) -> (length: Int, value: Double)? {
    let length = checkForValidDouble(cursor, terminator)
    if length == 0 {
        return nil
    }

    // These are ASCII digits and at most one '.'.
    var position = 0
    var localValue: Double = 0
    while position < length {
        let value = cursor.at(position)
        if value == 0x2E {
            break
        }
        localValue = localValue * 10 + Double(value) - 0x30
        position += 1
    }

    // Cannot overflow: an offset within the input.
    position &+= 1
    if position == length {
        return (length, localValue)
    }

    var fraction: Double = 0
    var scale: Double = 1
    let maxScale: Double = 1_000_000
    while position < length, scale < maxScale {
        fraction = fraction * 10 + Double(cursor.at(position)) - 0x30
        position += 1
        scale *= 10
    }

    return (length, localValue + fraction / scale)
}

// MARK: - charactersToDouble

/// The explicit exponent from which `parseCSSNumber` stops accumulating exponent digits.
private let explicitExponentLimit = 1_000_000

/// The powers of ten a `Double` holds exactly.
private let exactPowersOfTen: InlineArray<23, Double> = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
    1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
]

/// `parseCSSNumber` over `start..<end` of the input: `charactersToDouble`, which skips leading whitespace, takes an
/// optional sign, digits with an optional fraction and exponent, and no trailing characters, and here no trailing
/// ".".
///
/// A number with at most 19 significant digits, a significand up to 2^53 and a decimal exponent in -22...22 is one
/// correctly rounded multiplication or division of two exact doubles, so the value is `charactersToDouble`'s. One
/// with at most 19 significant digits that is at least 10^309 is infinite, as `charactersToDouble` rounds it. Any
/// other number, and any number whose explicit exponent is `explicitExponentLimit` or more, is converted by
/// `charactersToDouble` itself.
@inline(always)
private func parseCSSNumber<Unit>(_ cursor: borrowing Cursor<Unit>, _ start: Int, _ end: Int) -> Double? {
    // A number ends in a digit of its integer, its fraction or its exponent, so this also rejects a trailing ".".
    guard end > start, isASCIIDigit(cursor.unit(end - 1)) else {
        return nil
    }
    return parseCSSNumberEndingInDigit(cursor, start, end)
}

/// `parseCSSNumber`, inlined into the length and opacity scans.
@inline(always)
private func parseCSSNumberInCaller<Unit>(_ cursor: borrowing Cursor<Unit>, _ start: Int, _ end: Int) -> Double? {
    guard end > start, isASCIIDigit(cursor.unit(end - 1)) else {
        return nil
    }
    var stop = end
    var unit: WebCore.CSSUnitType? = nil
    return scanCSSNumber(cursor, start, end, nil, &unit, &stop, withoutEdgeBranches: false, digitWords: false)
}

/// `parseCSSNumber` over `start..<end`, whose last code unit is an ASCII digit.
///
/// Out of line, for hsl(), where size matters more than the call.
private func parseCSSNumberEndingInDigit<Unit>(_ cursor: borrowing Cursor<Unit>, _ start: Int, _ end: Int) -> Double? {
    var stop = end
    var unit: WebCore.CSSUnitType? = nil
    return scanCSSNumber(cursor, start, end, nil, &unit, &stop, withoutEdgeBranches: false, digitWords: false)
}

/// `parseCSSNumber` over the input from `start` to the first `delimiter`, without finding the delimiter first.
///
/// No character of a number is a delimiter, so the characters before the first one are a number exactly when the scan
/// of a number stops at it. Returns the number and the delimiter's offset.
@inline(always)
private func parseCSSNumber<Unit>(
    _ cursor: borrowing Cursor<Unit>,
    from start: Int,
    to delimiter: UInt32
) -> (value: Double, delimiter: Int)? {
    var stop = start
    var unit: WebCore.CSSUnitType? = nil
    guard let value = scanCSSNumber(cursor, start, cursor.count, delimiter, &unit, &stop, withoutEdgeBranches: true, digitWords: true)
    else {
        return nil
    }
    return (value, stop)
}

/// `parseSimpleLength` over the input from `start` to the first `delimiter`, without finding the delimiter first.
///
/// A number, then "px" in any case or "%", then the delimiter. No character of a number or of those units is a
/// delimiter, and a number ends in a digit, so this accepts what `parseSimpleLength` accepts before the first
/// delimiter. Returns the number, its unit and the delimiter's offset.
private func parseCSSLength<Unit>(
    _ cursor: borrowing Cursor<Unit>,
    from start: Int,
    to delimiter: UInt32
) -> (value: Double, unit: WebCore.CSSUnitType, delimiter: Int)? {
    var stop = start
    var unit: WebCore.CSSUnitType? = WebCore.CSSUnitType.Number
    guard let value = scanCSSNumber(cursor, start, cursor.count, delimiter, &unit, &stop, withoutEdgeBranches: true, digitWords: true),
        let unit
    else {
        return nil
    }
    return (value, unit, stop)
}

/// The run of ASCII digits at the start of `word` (8 code units, the first in the low byte).
///
/// Its length, 8 when every byte is a digit; its value, when shorter than 8; and how many of its digits are leading
/// zeros of a number whose digits so far are zeros (none when `afterNonZeroDigit`).
@inline(always)
private func digitRun(_ word: UInt64, afterNonZeroDigit: Bool) -> (count: Int, value: UInt64, leadingZeros: Int) {
    // The high bit of each byte below '0' (the subtraction wraps) or above '9' (the addition passes 0x80). A borrow or
    // a carry only crosses a byte above a non-digit byte, so the bytes up to the first non-digit are exact.
    let nonDigits = ((word &- 0x3030_3030_3030_3030) | (word &+ 0x4646_4646_4646_4646)) & 0x8080_8080_8080_8080
    let count = nonDigits.trailingZeroBitCount >> 3
    // The digits' values, in the low count bytes (none for 8 digits, whose result is not used). Cannot overflow: count
    // is at most 8.
    let values = (word &- 0x3030_3030_3030_3030) & ((1 &<< (count &* 8)) &- 1)
    // After a non-zero digit, a 1 in the first byte stops the count of leading zeros at 0.
    let leadingZeros = min((values | (afterNonZeroDigit ? 1 : 0)).trailingZeroBitCount >> 3, count)
    // The digits in the high count bytes, below them as many zeros: the last digit is the lowest decimal digit. With
    // no digits, values is 0 and the shift by 64 is a shift by 0. Cannot overflow: count is at most 8.
    var value = values &<< (64 &- count &* 8)
    // Pairs of bytes, then of 16-bit and of 32-bit halves, combined as tens, hundreds and ten thousands; each product
    // drops on purpose what overflows past the half it builds.
    value = (value &* ((10 << 8) | 1)) >> 8 & 0x00FF_00FF_00FF_00FF
    value = (value &* ((100 << 16) | 1)) >> 16 & 0x0000_FFFF_0000_FFFF
    value = (value &* ((10000 << 32) | 1)) >> 32
    return (count, value, leadingZeros)
}

/// The powers of ten below 10^8, for adding a run of up to 7 digits to a significand.
private let smallPowersOfTen: InlineArray<8, UInt64> = [1, 10, 100, 1000, 10000, 100000, 1_000_000, 10_000_000]

/// Adds the digits from `index` to `significand` and `digits` as the per-digit loop of `scanCSSNumber` does.
///
/// It does so in one step on the 8 code units from `index` of 8-bit input, when 8 remain before `end`, fewer than 8 of
/// them are digits, and the significand stays within 19 digits. Returns the number of digits, with `index` after them,
/// or nil when it takes no step.
@inline(always)
private func addDigitRun<Unit>(
    _ cursor: borrowing Cursor<Unit>,
    _ index: inout Int,
    _ end: Int,
    _ significand: inout UInt64,
    _ digits: inout Int
) -> Int? {
    // Cannot overflow: index is at most end.
    guard MemoryLayout<Unit>.size == 1, end &- index >= 8 else {
        return nil
    }
    let run = digitRun(cursor.word(index), afterNonZeroDigit: significand != 0)
    // Cannot overflow: digits is at most 19 and run.count at most 8.
    guard run.count < 8, digits &+ run.count <= 19 else {
        return nil
    }
    // Leading zeros of the number are not significant digits. Cannot overflow: leadingZeros is at most run.count.
    digits &+= run.count &- run.leadingZeros
    // Cannot overflow: below 10^19, as digits stays within 19.
    significand = significand &* smallPowersOfTen[run.count] &+ run.value
    // Cannot overflow: fewer than 8 units, and 8 remain before end.
    index &+= run.count
    return run.count
}

/// `parseCSSNumber` from `start`.
///
/// Without `delimiter`, over `start..<end`, whose last code unit is a digit. With one, over what precedes the first
/// `delimiter`, whose offset goes in `stop`; with a `unit` of `.Number`, "px" in any case or "%" may follow the number
/// and sets `unit`.
///
/// `withoutEdgeBranches` steps over the first whitespace unit and the sign, and scales, without branches (for transform
/// arguments). `digitWords` reads an 8-bit fraction's digits a word at a time (`addDigitRun`).
@inline(always)
private func scanCSSNumber<Unit>(
    _ cursor: borrowing Cursor<Unit>,
    _ start: Int,
    _ end: Int,
    _ delimiter: UInt32?,
    _ unit: inout WebCore.CSSUnitType?,
    _ stop: inout Int,
    withoutEdgeBranches: Bool,
    digitWords: Bool
) -> Double? {
    var index = start
    if withoutEdgeBranches, index < end {
        index += unicodeCompatibleASCIIWhitespaceCount(cursor.unit(index))
    }
    while index < end, isUnicodeCompatibleASCIIWhitespace(cursor.unit(index)) {
        index += 1
    }

    var negative = false
    if withoutEdgeBranches {
        if index < end {
            let unit = cursor.unit(index)
            negative = unit == 0x2D
            // '+' or '-', 2 apart; wraps below '+' on purpose, so one compare tests both.
            index += (unit &- 0x2B) | 2 == 2 ? 1 : 0
        }
    } else if index < end, cursor.unit(index) == 0x2D {
        negative = true
        index += 1
    } else if index < end, cursor.unit(index) == 0x2B {
        index += 1
    }

    // The digits as an integer significand and a decimal exponent. Leading zeros are not significant digits.
    var significand: UInt64 = 0
    var digits = 0
    var exponent = 0
    var sawDigit = false
    var outsideExactDomain = false

    while index < end, isASCIIDigit(cursor.unit(index)) {
        sawDigit = true
        // A digit, so it cannot wrap.
        let digit = UInt64(cursor.unit(index) &- 0x30)
        if digits < 19 {
            // A leading zero leaves the significand at 0 and is not counted.
            digits += (significand | digit) != 0 ? 1 : 0
            // Cannot overflow: below 10^19 after 19 digits.
            significand = significand &* 10 &+ digit
        } else {
            // After 19 significant digits, every digit is significant.
            outsideExactDomain = true
        }
        index += 1
    }

    if index < end, cursor.unit(index) == 0x2E {
        index += 1
        if digitWords, let count = addDigitRun(cursor, &index, end, &significand, &digits) {
            sawDigit = sawDigit || count > 0
            // Cannot overflow: below 8.
            exponent &-= count
        } else {
            while index < end, isASCIIDigit(cursor.unit(index)) {
                sawDigit = true
                // A digit, so it cannot wrap.
                let digit = UInt64(cursor.unit(index) &- 0x30)
                if digits < 19 {
                    digits += (significand | digit) != 0 ? 1 : 0
                    // Cannot overflow: below 10^19 after 19 digits.
                    significand = significand &* 10 &+ digit
                } else {
                    outsideExactDomain = true
                }
                // Cannot overflow: one per code unit, and a string has fewer than 2^31.
                exponent &-= 1
                index += 1
            }
        }
    }

    if !sawDigit {
        return nil
    }

    if index < end, cursor.unit(index) | 0x20 == 0x65 {
        var exponentIndex = index + 1
        var exponentNegative = false
        if exponentIndex < end, cursor.unit(exponentIndex) == 0x2D {
            exponentNegative = true
            exponentIndex += 1
        } else if exponentIndex < end, cursor.unit(exponentIndex) == 0x2B {
            exponentIndex += 1
        }
        // Without exponent digits, the "e" is a trailing character.
        if exponentIndex < end, isASCIIDigit(cursor.unit(exponentIndex)) {
            var explicitExponent = 0
            while exponentIndex < end, isASCIIDigit(cursor.unit(exponentIndex)) {
                if explicitExponent < explicitExponentLimit {
                    // Cannot overflow or wrap: below 10 times the limit, and a digit.
                    explicitExponent = explicitExponent &* 10 &+ Int(cursor.unit(exponentIndex) &- 0x30)
                }
                exponentIndex += 1
            }
            // A larger exponent is not accumulated in full, so the sum below would be wrong for it.
            if explicitExponent >= explicitExponentLimit {
                outsideExactDomain = true
            }
            // Cannot overflow: both are below 2^31 in magnitude.
            exponent = exponentNegative ? exponent &- explicitExponent : exponent &+ explicitExponent
            index = exponentIndex
        }
    }

    if let delimiter {
        // A digit precedes index, so index - 1 is in the number.
        guard cursor.unit(index &- 1) != 0x2E else {
            return nil
        }
        var next = index
        if unit != nil {
            // Cannot overflow: next is at most end.
            if next &+ 1 < end, isASCIIAlphaCaselessEqual(cursor.unit(next), 0x70), isASCIIAlphaCaselessEqual(cursor.unit(next + 1), 0x78) {
                unit = WebCore.CSSUnitType.Px
                next += 2
            } else if next < end, cursor.unit(next) == 0x25 {
                unit = WebCore.CSSUnitType.Percentage
                next += 1
            }
        }
        guard next < end, cursor.unit(next) == delimiter else {
            return nil
        }
        stop = next
    } else if index != end {
        return nil
    }

    if outsideExactDomain || significand > 1 << 53 || exponent < -22 || exponent > 22 {
        // At least 10^(digits - 1 + exponent), so from 10^309 on, above the largest finite double: charactersToDouble
        // rounds it to infinity. Cannot overflow: digits is at most 19 and exponent below 2^31 in magnitude.
        if !outsideExactDomain, significand != 0, digits &+ exponent > 309 {
            return negative ? -.infinity : .infinity
        }
        let number = cursor.parseNumber(start, delimiter == nil ? end : index)
        return number.ok ? number.value : nil
    }

    if withoutEdgeBranches {
        // One of the two factors is 1, so the result is the one correctly rounded multiplication or division by an
        // exact power of ten.
        let value = Double(significand) * exactPowersOfTen[max(exponent, 0)] / exactPowersOfTen[max(-exponent, 0)]
        // The value is +0 or more, so setting the sign bit negates it, -0 included.
        return Double(bitPattern: value.bitPattern | (negative ? 1 as UInt64 : 0) << 63)
    }
    var value = Double(significand)
    if exponent < 0 {
        value /= exactPowersOfTen[-exponent]
    } else {
        value *= exactPowersOfTen[exponent]
    }
    return negative ? -value : value
}

// MARK: - rgb() and rgba()

/// Whether the components so far are numbers or percentages; the first decides for all three.
private enum ColorUnitType { case unknown, number, percentage }

/// `convertPrescaledSRGBAFloatToSRGBAByte`, for a value in 0...255, where `std::lround` is rounding half away from
/// zero.
@inline(always)
private func convertPrescaledSRGBAFloatToSRGBAByte(_ value: Double) -> UInt8 {
    let rounded = Float(value).rounded(.toNearestOrAwayFromZero)
    if !(rounded > 0) {
        return 0
    }
    if rounded >= 255 {
        return 255
    }
    return UInt8(rounded)
}

/// `convertFloatAlphaTo<uint8_t>`, with the C library's `lroundf`, which the C++ calls, so that an alpha too large
/// for a `long` gives the same byte.
@inline(always)
private func convertFloatAlphaToByte(_ value: Double) -> UInt8 {
    let rounded = lroundf(Float(value) * 255)
    if rounded <= 0 {
        return 0
    }
    if rounded >= 255 {
        return 255
    }
    return UInt8(truncatingIfNeeded: rounded)
}

/// `parseColorIntOrPercentage`: one component, past which `cursor` advances only when it is one.
@inline(always)
private func parseColorIntOrPercentage<Unit>(
    _ cursor: inout Cursor<Unit>,
    _ consumableTerminator: UInt32?,
    _ expectedUnitType: inout ColorUnitType
) -> UInt8? {
    var current = cursor

    var localValue: Double = 0
    var negative = false
    current.skipASCIIWhitespace()

    if current.skipExactly(0x2D) {
        negative = true
    }

    guard let first = current.front(), isASCIIDigit(first) else {
        return nil
    }

    while let value = current.front(), isASCIIDigit(value) {
        current.skip(1)
        let newValue = localValue * 10 + Double(value) - 0x30
        if newValue >= 255 {
            // Clamp values at 255.
            localValue = 255
            current.skipASCIIDigits()
            break
        }
        localValue = newValue
    }

    guard let afterDigits = current.front() else {
        return nil
    }

    if expectedUnitType == .number, afterDigits == 0x2E || afterDigits == 0x25 {
        return nil
    }

    if afterDigits == 0x2E {
        // We already parsed the integral part, try to parse the fraction part of the percentage value.
        guard let percentage = parseDouble(current, 0x25) else {
            return nil
        }
        current.skip(percentage.length)
        guard current.front() == 0x25 else {
            return nil
        }
        localValue += percentage.value
    }

    if expectedUnitType == .percentage, current.front() != 0x25 {
        return nil
    }

    if current.skipExactly(0x25) {
        expectedUnitType = .percentage
        localValue = localValue / 100.0 * 255.0
        // Clamp values at 255 for percentages over 100%.
        if localValue > 255 {
            localValue = 255
        }
    } else {
        expectedUnitType = .number
    }

    current.skipASCIIWhitespace()

    if let terminator = consumableTerminator, !current.skipExactly(terminator) {
        return nil
    }

    cursor.offset = current.offset

    // Clamp negative values at zero.
    return negative ? 0 : convertPrescaledSRGBAFloatToSRGBAByte(localValue)
}

/// `isTenthAlpha` over the first `length` code units that remain: "0.X" or ".X".
@inline(always)
private func isTenthAlpha<Unit>(_ cursor: borrowing Cursor<Unit>, _ length: Int) -> Bool {
    if length == 3, cursor.at(0) == 0x30, cursor.at(1) == 0x2E, isASCIIDigit(cursor.at(2)) {
        return true
    }
    if length == 2, cursor.at(0) == 0x2E, isASCIIDigit(cursor.at(1)) {
        return true
    }
    return false
}

/// `parseRGBAlphaValue`, which consumes the rest of the input when it succeeds.
@inline(always)
private func parseRGBAlphaValue<Unit>(_ cursor: inout Cursor<Unit>, _ terminator: UInt32) -> UInt8? {
    cursor.skipASCIIWhitespace()

    var negative = false
    if cursor.skipExactly(0x2D) {
        negative = true
    }

    let length = cursor.remaining
    if length < 2 {
        return nil
    }

    guard cursor.at(length - 1) == terminator, isASCIIDigit(cursor.at(length - 2)) else {
        return nil
    }

    let first = cursor.at(0)
    if first != 0x30, first != 0x31, first != 0x2E {
        if checkForValidDouble(cursor, terminator) != 0 {
            cursor.offset = cursor.count
            return negative ? 0 : 255
        }
        return nil
    }

    if length == 2, first != 0x2E {
        let result: UInt8 = !negative && first == 0x31 ? 255 : 0
        cursor.offset = cursor.count
        return result
    }

    if isTenthAlpha(cursor, length - 1) {
        let tenthAlphaValues: InlineArray<10, UInt8> = [0, 26, 51, 77, 102, 128, 153, 179, 204, 230]
        // A digit, so it cannot wrap.
        let result: UInt8 = negative ? 0 : tenthAlphaValues[Int(cursor.at(length - 2) &- 0x30)]
        cursor.offset = cursor.count
        return result
    }

    guard let alpha = parseDouble(cursor, terminator) else {
        return nil
    }

    cursor.offset = cursor.count
    return negative ? 0 : convertFloatAlphaToByte(alpha.value)
}

// MARK: - hsl() and hsla()

/// `fmod(fmod(hue, 360) + 360, 360)` in `double`, as `normalizeHue` computes it for the `double` a
/// `Style::Angle` holds.
@inline(always)
private func normalizeHue(_ hue: Double) -> Double {
    // A hue in 0..<360 is its own remainder, and the second remainder of hue + 360 in 360..<720 is an exact
    // subtraction. -0 gives +0, as the remainders do; NaN fails both tests.
    if hue >= 0.0, hue < 360.0 {
        let shifted = hue + 360.0
        if shifted < 720.0 {
            return shifted - 360.0
        }
    }
    return (hue.truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0)
}

/// `ColorConversion<ExtendedSRGBA<float>, HSLA<float>>::convert`, then `clipToGamut` and the conversion to bytes,
/// as a `PackedColor::ARGB`, for components with no NaN and inside the sRGB gamut.
@inline(always)
private func convertHSLAToARGB(hue: Float, saturation: Float, lightness: Float, alpha: Float) -> UInt32 {
    let scaledHue = hue / 30.0
    let scaledSaturation = saturation * (1.0 / 100.0 as Float)
    let scaledLightness = lightness * (1.0 / 100.0 as Float)

    let a = scaledSaturation * min(scaledLightness, 1.0 - scaledLightness)

    @inline(always)
    func hueToRGB(_ n: Float) -> Float {
        // fmodf by 12: a value in 0..<12 is its own remainder, and one in 12..<24 loses 12 exactly. -0 stays -0, as
        // fmodf keeps it; NaN fails the first test.
        let sum = n + scaledHue
        let k = sum >= 0.0 && sum < 24.0 ? (sum < 12.0 ? sum : sum - 12.0) : sum.truncatingRemainder(dividingBy: 12.0)
        let term = max(-1.0, min(min(k - 3.0, 9.0 - k), 1.0))
        #if arch(arm64)
        // The C++ multiply and subtract are one fused operation on arm64, where the compiler contracts them.
        return scaledLightness.addingProduct(-a, term)
        #else
        return scaledLightness - a * term
        #endif
    }

    @inline(always)
    func toByte(_ value: Float) -> UInt32 {
        let clamped = min(max(value, 0.0), 1.0)
        // std::lround of a value in 0...255: rounding half away from zero.
        return UInt32((clamped * 255.0).rounded(.toNearestOrAwayFromZero))
    }

    return toByte(alpha) << 24 | toByte(hueToRGB(0)) << 16 | toByte(hueToRGB(8)) << 8 | toByte(hueToRGB(4))
}

/// The `parsePercentage` lambda of `parseHSL`.
@inline(always)
private func parseHSLPercentage<Unit>(_ cursor: inout Cursor<Unit>) -> Double? {
    cursor.skipCSSSpace()
    guard let parsed = parseDouble(cursor, 0x25) else {
        return nil
    }
    cursor.skip(parsed.length)
    guard cursor.skipExactly(0x25) else {
        return nil
    }
    return parsed.value
}

/// `parseHSL`, over the input after "hsl" or "hsla" and the parenthesis.
private func scanHSL<Unit>(_ cursor: inout Cursor<Unit>) -> Int64 {
    // Find the end of the hue token (terminated by comma or whitespace). A comma means legacy syntax
    // (comma-separated), whitespace means modern (space-separated).
    var hueEnd = 0
    var isLegacy = false
    while hueEnd < cursor.remaining {
        let value = cursor.at(hueEnd)
        if value == 0x2C {
            isLegacy = true
            break
        }
        if isCSSSpace(value) {
            break
        }
        hueEnd += 1
    }
    if hueEnd == 0 || hueEnd == cursor.remaining {
        return notAColor
    }

    // parseSimpleAngle with RequireUnits::No: "deg" or "rad", any other ending part of the number.
    let numberStart = cursor.offset
    // Cannot overflow: an offset within the input.
    var numberEnd = cursor.offset &+ hueEnd
    var isRadians = false
    // Cannot overflow: with hueEnd at least 4, numberEnd - 3 stays after numberStart.
    if hueEnd >= 4 {
        let c3 = cursor.at(hueEnd - 3)
        let c2 = cursor.at(hueEnd - 2)
        let c1 = cursor.at(hueEnd - 1)
        if isASCIIAlphaCaselessEqual(c3, 0x64), isASCIIAlphaCaselessEqual(c2, 0x65), isASCIIAlphaCaselessEqual(c1, 0x67) {
            numberEnd &-= 3
        } else if isASCIIAlphaCaselessEqual(c3, 0x72), isASCIIAlphaCaselessEqual(c2, 0x61), isASCIIAlphaCaselessEqual(c1, 0x64) {
            numberEnd &-= 3
            isRadians = true
        }
    }
    guard let hue = parseCSSNumber(cursor, numberStart, numberEnd) else {
        return notAColor
    }

    cursor.skip(hueEnd)

    // In legacy syntax, components are separated by commas.
    if isLegacy, !cursor.skipExactly(0x2C) {
        return notAColor
    }

    guard let saturation = parseHSLPercentage(&cursor) else {
        return notAColor
    }

    if isLegacy, !cursor.skipExactly(0x2C) {
        return notAColor
    }

    guard let lightness = parseHSLPercentage(&cursor) else {
        return notAColor
    }

    cursor.skipCSSSpace()

    // Alpha is optional. Legacy uses comma separator, modern uses slash.
    var alpha: Double = 1.0
    if cursor.front() == (isLegacy ? 0x2C : 0x2F) {
        cursor.skip(1)
        cursor.skipCSSSpace()

        if let parsed = parseDouble(cursor, 0x29) {
            cursor.skip(parsed.length)
            alpha = parsed.value
        } else if let parsed = parseDouble(cursor, 0x25) {
            cursor.skip(parsed.length)
            guard cursor.skipExactly(0x25) else {
                return notAColor
            }
            alpha = parsed.value / 100.0
        } else {
            return notAColor
        }

        cursor.skipCSSSpace()
    }

    // Only the next code unit is checked, so text after the ")" is ignored.
    guard cursor.front() == 0x29 else {
        return notAColor
    }

    // The typed color convertToTypedColor<HSLFunctionModern> makes from the components narrowed to float: the hue in
    // degrees normalized, the saturation at least 0, and the alpha in 0...1, each computed in double.
    let degrees = isRadians ? hue * (180.0 / Double.pi) : hue
    let normalizedHue = Float(normalizeHue(Double(Float(degrees))))
    let clampedSaturation = Float(max(Double(Float(saturation)), 0.0))
    let narrowedLightness = Float(lightness)
    let clampedAlpha = Float(min(max(Double(Float(alpha)), 0.0), 1.0))

    // convertToColor keeps a color with a NaN component or outside the sRGB gamut out of line, so that
    // tryGetAsSRGBABytes() has no bytes for it.
    if normalizedHue.isNaN || clampedSaturation.isNaN || narrowedLightness.isNaN || clampedAlpha.isNaN {
        return notAColor
    }
    if clampedSaturation > 100.0 || narrowedLightness < 0.0 || narrowedLightness > 100.0 {
        return notAColor
    }

    return Int64(convertHSLAToARGB(hue: normalizedHue, saturation: clampedSaturation, lightness: narrowedLightness, alpha: clampedAlpha))
}

// MARK: - Numeric colors

/// `mightBeRGB`, `mightBeRGBA`, `mightBeHSL` and `mightBeHSLA`: three or four letters in any case, then a
/// parenthesis.
@inline(always)
private func hasColorFunctionPrefix<Unit: CSSFastPathCodeUnit>(
    _ characters: Span<Unit>,
    _ c0: UInt32,
    _ c1: UInt32,
    _ c2: UInt32,
    _ c3: UInt32?
) -> Bool {
    let parenthesis = c3 == nil ? 3 : 4
    guard characters.count > parenthesis, widen(characters[parenthesis]) == 0x28 else {
        return false
    }
    guard isASCIIAlphaCaselessEqual(widen(characters[0]), c0),
        isASCIIAlphaCaselessEqual(widen(characters[1]), c1),
        isASCIIAlphaCaselessEqual(widen(characters[2]), c2)
    else {
        return false
    }
    guard let c3 else {
        return true
    }
    return isASCIIAlphaCaselessEqual(widen(characters[3]), c3)
}

/// The hex color after "#" of `characters`, which starts with "#".
///
/// No other color starts with "#".
@inline(always)
private func scanHashHexColor<Unit: CSSFastPathCodeUnit>(_ characters: Span<Unit>) -> Int64 {
    let count = characters.count
    guard count >= 4 else {
        return notAColor
    }
    return scanHexColor(characters.extracting(1..<count))
}

/// `parseNumericColor`: a hex color after "#", a hex color without one in quirks mode, `rgb()`, `rgba()`, `hsl()` or
/// `hsla()`.
@inline(always)
private func scanNumericColor<Unit: CSSFastPathCodeUnit>(_ characters: Span<Unit>, quirksMode: Bool) -> Int64 {
    let count = characters.count
    if count > 0, widen(characters[0]) == 0x23 {
        return scanHashHexColor(characters)
    }

    if quirksMode, count == 3 || count == 6 {
        let color = scanHexColor(characters)
        if color != notAColor {
            return color
        }
    }

    return scanColorFunction(characters)
}

/// `rgb()`, `rgba()`, `hsl()` or `hsla()`.
///
/// Out of line, so that the hex colors do not pay for its frame.
@inline(never)
private func scanColorFunction<Unit: CSSFastPathCodeUnit>(_ characters: Span<Unit>) -> Int64 {
    var cursor = Cursor(characters)

    let isRGBA = hasColorFunctionPrefix(characters, 0x72, 0x67, 0x62, 0x61)
    if isRGBA || hasColorFunctionPrefix(characters, 0x72, 0x67, 0x62, nil) {
        cursor.skip(isRGBA ? 5 : 4)

        var expectedUnitType = ColorUnitType.unknown

        // Red and green will both terminate with ','.
        guard let red = parseColorIntOrPercentage(&cursor, 0x2C, &expectedUnitType),
            let green = parseColorIntOrPercentage(&cursor, 0x2C, &expectedUnitType)
        else {
            return notAColor
        }

        // Blue may terminate with ',' or ')', but do not consume either terminator.
        guard let blue = parseColorIntOrPercentage(&cursor, nil, &expectedUnitType),
            let afterBlue = cursor.front()
        else {
            return notAColor
        }
        let rgb = UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)

        // Finish parsing rgb if no alpha value.
        if afterBlue == 0x29 {
            cursor.skip(1)
            guard cursor.isEmpty else {
                return notAColor
            }
            return Int64(0xFF00_0000 | rgb)
        }

        // Parse alpha value if present.
        if afterBlue == 0x2C {
            cursor.skip(1)
            guard let alpha = parseRGBAlphaValue(&cursor, 0x29), cursor.isEmpty else {
                return notAColor
            }
            return Int64(UInt32(alpha) << 24 | rgb)
        }

        return notAColor
    }

    // hsl() and hsla() are synonyms.
    if hasColorFunctionPrefix(characters, 0x68, 0x73, 0x6C, 0x61) {
        cursor.skip(5)
        return scanHSL(&cursor)
    }

    if hasColorFunctionPrefix(characters, 0x68, 0x73, 0x6C, nil) {
        cursor.skip(4)
        return scanHSL(&cursor)
    }

    return notAColor
}

/// `parseSimpleColorInternal`: a numeric color, else a named one.
private func scanSimpleColor<Unit: CSSFastPathCodeUnit>(_ characters: Span<Unit>, quirksMode: Bool) -> Int64 {
    // Every color scanNumericColor takes starts with "#", "r" or "h", in any case, or is a quirks mode hex color of
    // 3 or 6 digits.
    let count = characters.count
    if count > 0 {
        let first = widen(characters[0])
        if first == 0x23 {
            return scanHashHexColor(characters)
        }
        if isASCIIAlphaCaselessEqual(first, 0x72) || isASCIIAlphaCaselessEqual(first, 0x68)
            || (quirksMode && (count == 3 || count == 6))
        {
            let color = scanNumericColor(characters, quirksMode: quirksMode)
            if color != notAColor {
                return color
            }
        }
    }
    return scanNamedColor(characters)
}

// MARK: - Lengths and opacity

/// `parseSimpleLength` over `start..<end`: a number, with an optional "px" in any case or "%".
@inline(always)
private func parseSimpleLength<Unit>(
    _ cursor: borrowing Cursor<Unit>,
    _ start: Int,
    _ end: Int
) -> (value: Double, unit: WebCore.CSSUnitType)? {
    var end = end
    var unit = WebCore.CSSUnitType.Number
    if end - start > 2, isASCIIAlphaCaselessEqual(cursor.unit(end - 2), 0x70), isASCIIAlphaCaselessEqual(cursor.unit(end - 1), 0x78) {
        end -= 2
        unit = WebCore.CSSUnitType.Px
    } else if end > start, cursor.unit(end - 1) == 0x25 {
        end -= 1
        unit = WebCore.CSSUnitType.Percentage
    }
    guard let value = parseCSSNumberInCaller(cursor, start, end) else {
        return nil
    }
    return (value, unit)
}

/// `parseSimpleLengthValue`.
@inline(always)
private func scanLength<Unit: CSSFastPathCodeUnit>(
    _ characters: Span<Unit>,
    svgAttributeMode: Bool,
    minimum: Double,
    maximum: Double
) -> WebCore.CSSFastPathNumber {
    let cursor = Cursor(characters)
    guard let (number, parsedUnit) = parseSimpleLength(cursor, 0, cursor.count) else {
        return notANumber
    }
    var unit = parsedUnit

    if unit == WebCore.CSSUnitType.Number {
        if number != 0, !svgAttributeMode {
            return notANumber
        }
        unit = WebCore.CSSUnitType.Px
    }

    if number < minimum || number > maximum {
        return notANumber
    }

    if number.isInfinite {
        return notANumber
    }

    return WebCore.CSSFastPathNumber(value: number, unit: unit, ok: true)
}

/// `parseSimpleNumberOrPercentageDividedBy100`.
@inline(always)
private func scanOpacity<Unit: CSSFastPathCodeUnit>(_ characters: Span<Unit>) -> WebCore.CSSFastPathNumber {
    let cursor = Cursor(characters)
    var end = cursor.count
    var isPercentage = false
    if end > 0, cursor.unit(end - 1) == 0x25 {
        end -= 1
        isPercentage = true
    }

    guard let number = parseCSSNumberInCaller(cursor, 0, end), !number.isInfinite else {
        return notANumber
    }

    return WebCore.CSSFastPathNumber(value: isPercentage ? number / 100.0 : number, unit: WebCore.CSSUnitType.Number, ok: true)
}

// MARK: - Transforms

/// The arguments of one transform function: up to 16, the count of `matrix3d()`.
private struct TransformArguments {
    var values = InlineArray<16, Double>(repeating: 0)
    var units = InlineArray<16, UInt8>(repeating: 0)
    var count = 0

    @inline(always)
    mutating func append(_ value: Double, _ unit: WebCore.CSSUnitType) {
        values[count] = value
        units[count] = unit.rawValue
        count += 1
    }

    /// Appends the function `name` with these arguments to `sink`.
    ///
    /// Mutating, so that the spans borrow the arguments where they are stored rather than a copy.
    @inline(always)
    mutating func appendFunction(_ name: WebCore.CSSValueID, to sink: inout WebCore.CSSFastPathTransformSink) {
        sink.append(name.rawValue, values.span.extracting(0..<count), units.span.extracting(0..<count))
    }
}

/// `find(buffer.span(), character)`: the distance from the cursor to the first `character`, or nil.
@inline(always)
private func find<Unit>(_ cursor: borrowing Cursor<Unit>, _ character: UInt32) -> Int? {
    var index = cursor.offset
    while index < cursor.count {
        if cursor.unit(index) == character {
            // Cannot overflow: an offset within the input.
            return index &- cursor.offset
        }
        // Cannot overflow: an offset within the input.
        index &+= 1
    }
    return nil
}

/// `parseSimpleAngle` with RequireUnits::Yes over `start..<end`: a number then "deg" or "rad", in any case.
@inline(always)
private func parseSimpleAngle<Unit>(
    _ cursor: borrowing Cursor<Unit>,
    _ start: Int,
    _ end: Int
) -> (value: Double, unit: WebCore.CSSUnitType)? {
    guard end - start >= 4 else {
        return nil
    }
    let c3 = cursor.unit(end - 3)
    let c2 = cursor.unit(end - 2)
    let c1 = cursor.unit(end - 1)
    let unit: WebCore.CSSUnitType
    if isASCIIAlphaCaselessEqual(c3, 0x64), isASCIIAlphaCaselessEqual(c2, 0x65), isASCIIAlphaCaselessEqual(c1, 0x67) {
        unit = WebCore.CSSUnitType.Deg
    } else if isASCIIAlphaCaselessEqual(c3, 0x72), isASCIIAlphaCaselessEqual(c2, 0x61), isASCIIAlphaCaselessEqual(c1, 0x64) {
        unit = WebCore.CSSUnitType.Rad
    } else {
        return nil
    }
    guard let value = parseCSSNumber(cursor, start, end - 3) else {
        return nil
    }
    return (value, unit)
}

/// `parseTransformTranslateArguments`.
@inline(always)
private func parseTransformTranslateArguments<Unit>(
    _ cursor: inout Cursor<Unit>,
    _ expectedCount: Int,
    _ transformType: WebCore.CSSValueID,
    _ arguments: inout TransformArguments
) -> Bool {
    var expectedCount = expectedCount
    while expectedCount > 0 {
        guard let (number, parsedUnit, delimiter) = parseCSSLength(cursor, from: cursor.offset, to: expectedCount == 1 ? 0x29 : 0x2C) else {
            return false
        }
        var unit = parsedUnit
        if number == 0, unit == WebCore.CSSUnitType.Number {
            unit = WebCore.CSSUnitType.Px
        }
        if unit == WebCore.CSSUnitType.Number
            || (unit == WebCore.CSSUnitType.Percentage
                && (transformType == WebCore.CSSValueID.TranslateZ
                    || (transformType == WebCore.CSSValueID.Translate3d && expectedCount == 1)))
        {
            return false
        }
        arguments.append(number, unit)
        // Cannot overflow: an offset within the input.
        cursor.offset = delimiter &+ 1
        expectedCount -= 1
    }
    return true
}

/// `parseTransformNumberArguments`.
///
/// Out of line, so that matrix3d() and scale3d() share it with its number scan.
@inline(never)
private func parseTransformNumberArguments<Unit>(
    _ cursor: inout Cursor<Unit>,
    _ expectedCount: Int,
    _ arguments: inout TransformArguments
) -> Bool {
    var expectedCount = expectedCount
    while expectedCount > 0 {
        guard let (number, delimiter) = parseCSSNumber(cursor, from: cursor.offset, to: expectedCount == 1 ? 0x29 : 0x2C) else {
            return false
        }
        arguments.append(number, WebCore.CSSUnitType.Number)
        // Cannot overflow: an offset within the input.
        cursor.offset = delimiter &+ 1
        expectedCount -= 1
    }
    return true
}

/// Whether `characters[index]` is the lowercase `letter`, in either case.
@inline(always)
private func isCaselessLetter<Unit: CSSFastPathCodeUnit>(_ characters: Span<Unit>, _ index: Int, _ letter: UInt32) -> Bool {
    isASCIIAlphaCaselessEqual(widen(characters[index]), letter)
}

/// Whether `characters[index]` is `character`.
@inline(always)
private func isCharacter<Unit: CSSFastPathCodeUnit>(_ characters: Span<Unit>, _ index: Int, _ character: UInt32) -> Bool {
    widen(characters[index]) == character
}

/// `parseSimpleTransformValue`: one function, appended to `sink`.
private func parseSimpleTransformValue<Unit>(
    _ cursor: inout Cursor<Unit>,
    _ sink: inout WebCore.CSSFastPathTransformSink
) -> Bool {
    // "rotate(0)". Also guarantees that the first 9 code units are there.
    guard cursor.remaining >= 9 else {
        return false
    }
    // A view whose count is a constant, so that its reads need no further check.
    let name = cursor.characters.extracting(droppingFirst: cursor.offset).extracting(0..<9)

    switch widen(name[0]) | 0x20 {
    case 0x74:
        guard isCaselessLetter(name, 1, 0x72), isCaselessLetter(name, 2, 0x61), isCaselessLetter(name, 3, 0x6E),
            isCaselessLetter(name, 4, 0x73), isCaselessLetter(name, 5, 0x6C), isCaselessLetter(name, 6, 0x61),
            isCaselessLetter(name, 7, 0x74), isCaselessLetter(name, 8, 0x65)
        else {
            return false
        }
        // "translate(0)". Also guarantees that the first 12 code units are there.
        guard cursor.remaining >= 12 else {
            return false
        }
        let suffix = cursor.characters.extracting(droppingFirst: cursor.offset).extracting(9..<12)
        let c9 = widen(suffix[0])
        let c10 = widen(suffix[1])
        let transformType: WebCore.CSSValueID
        var expectedArgumentCount = 1
        var argumentStart = 11
        if isASCIIAlphaCaselessEqual(c9, 0x78), c10 == 0x28 {
            transformType = WebCore.CSSValueID.TranslateX
        } else if isASCIIAlphaCaselessEqual(c9, 0x79), c10 == 0x28 {
            transformType = WebCore.CSSValueID.TranslateY
        } else if isASCIIAlphaCaselessEqual(c9, 0x7A), c10 == 0x28 {
            transformType = WebCore.CSSValueID.TranslateZ
        } else if c9 == 0x28 {
            transformType = WebCore.CSSValueID.Translate
            expectedArgumentCount = 2
            argumentStart = 10
        } else if c9 == 0x33, isASCIIAlphaCaselessEqual(c10, 0x64), widen(suffix[2]) == 0x28 {
            transformType = WebCore.CSSValueID.Translate3d
            expectedArgumentCount = 3
            argumentStart = 12
        } else {
            return false
        }
        cursor.skip(argumentStart)
        var arguments = TransformArguments()
        guard parseTransformTranslateArguments(&cursor, expectedArgumentCount, transformType, &arguments) else {
            return false
        }
        arguments.appendFunction(transformType, to: &sink)
        return true

    case 0x6D:
        guard isCaselessLetter(name, 1, 0x61), isCaselessLetter(name, 2, 0x74), isCaselessLetter(name, 3, 0x72),
            isCaselessLetter(name, 4, 0x69), isCaselessLetter(name, 5, 0x78), isCharacter(name, 6, 0x33),
            isCaselessLetter(name, 7, 0x64), isCharacter(name, 8, 0x28)
        else {
            return false
        }
        cursor.skip(9)
        var arguments = TransformArguments()
        guard parseTransformNumberArguments(&cursor, 16, &arguments) else {
            return false
        }
        arguments.appendFunction(WebCore.CSSValueID.Matrix3d, to: &sink)
        return true

    case 0x73:
        guard isCaselessLetter(name, 1, 0x63), isCaselessLetter(name, 2, 0x61), isCaselessLetter(name, 3, 0x6C),
            isCaselessLetter(name, 4, 0x65), isCharacter(name, 5, 0x33), isCaselessLetter(name, 6, 0x64),
            isCharacter(name, 7, 0x28)
        else {
            return false
        }
        cursor.skip(8)
        var arguments = TransformArguments()
        guard parseTransformNumberArguments(&cursor, 3, &arguments) else {
            return false
        }
        arguments.appendFunction(WebCore.CSSValueID.Scale3d, to: &sink)
        return true

    case 0x72:
        guard isCaselessLetter(name, 1, 0x6F), isCaselessLetter(name, 2, 0x74), isCaselessLetter(name, 3, 0x61),
            isCaselessLetter(name, 4, 0x74), isCaselessLetter(name, 5, 0x65)
        else {
            return false
        }
        let transformType: WebCore.CSSValueID
        var argumentStart = 7
        if isCharacter(name, 6, 0x28) {
            transformType = WebCore.CSSValueID.Rotate
        } else if isCaselessLetter(name, 6, 0x7A), isCharacter(name, 7, 0x28) {
            transformType = WebCore.CSSValueID.RotateZ
            argumentStart = 8
        } else {
            return false
        }
        cursor.skip(argumentStart)
        // parseTransformAngleArgument. Cannot overflow: an offset within the input.
        guard let argumentLength = find(cursor, 0x29),
            let (number, unit) = parseSimpleAngle(cursor, cursor.offset, cursor.offset &+ argumentLength)
        else {
            return false
        }
        cursor.skip(argumentLength &+ 1)
        var arguments = TransformArguments()
        arguments.append(number, unit)
        arguments.appendFunction(transformType, to: &sink)
        return true

    default:
        return false
    }
}

/// `parseSimpleTransformList`: one or more functions, separated by `isCSSSpace`.
private func scanTransformList<Unit: CSSFastPathCodeUnit>(
    _ characters: Span<Unit>,
    _ sink: inout WebCore.CSSFastPathTransformSink
) -> Bool {
    var cursor = Cursor(characters)
    var appendedAny = false
    while !cursor.isEmpty {
        cursor.skipCSSSpace()
        if cursor.isEmpty {
            break
        }
        guard parseSimpleTransformValue(&cursor, &sink) else {
            return false
        }
        appendedAny = true
    }
    return appendedAny
}

// MARK: - Entry points
//
// Each entry receives the characters of a StringView, span8() as bytes or span16(), and converts them to a Span
// once. The C++ caller is a CSSParserFastPaths function whose own caller holds the string for the call, so the
// characters stay allocated, at their length, until the entry returns. A StringImpl's characters never change after
// it is created, and the C++ the scans call (cssFastPathParseNumber8/16 on a sub-range of the characters,
// cssFastPathFindNamedColor on a Swift buffer, and CSSFastPathTransformSink::append) writes no characters, makes no
// string and calls no Swift. The elements are bytes or char16_t, which have no invalid bit patterns. No entry has an
// output buffer.

/// The hex, rgb() and hsl() colors of 8-bit `characters`, with quirks mode's hex colors without "#" when
/// `quirksMode`.
///
/// `characters` meets the conditions above. FIXME: Receive it as a `Span` once an exposed function can
/// (rdar://186723514).
@_expose(Cxx)
func cssFastPathNumericColor8(_ characters: WebCore.CSSFastPathSpan8, _ quirksMode: Bool) -> Int64 {
    scanNumericColor(unsafe Span<UInt8>(_unsafeCxxSpan: characters), quirksMode: quirksMode)
}

/// `cssFastPathNumericColor8` for 16-bit `characters`.
///
/// `characters` meets the conditions above. FIXME: Receive it as a `Span` once an exposed function can
/// (rdar://186723514).
@_expose(Cxx)
func cssFastPathNumericColor16(_ characters: WebCore.CSSFastPathSpan16, _ quirksMode: Bool) -> Int64 {
    scanNumericColor(unsafe Span<UInt16>(_unsafeCxxSpan: characters), quirksMode: quirksMode)
}

/// The numeric or named color of 8-bit `characters`.
///
/// `characters` meets the conditions above. FIXME: Receive it as a `Span` once an exposed function can
/// (rdar://186723514).
@_expose(Cxx)
func cssFastPathSimpleColor8(_ characters: WebCore.CSSFastPathSpan8, _ quirksMode: Bool) -> Int64 {
    scanSimpleColor(unsafe Span<UInt8>(_unsafeCxxSpan: characters), quirksMode: quirksMode)
}

/// `cssFastPathSimpleColor8` for 16-bit `characters`.
///
/// `characters` meets the conditions above. FIXME: Receive it as a `Span` once an exposed function can
/// (rdar://186723514).
@_expose(Cxx)
func cssFastPathSimpleColor16(_ characters: WebCore.CSSFastPathSpan16, _ quirksMode: Bool) -> Int64 {
    scanSimpleColor(unsafe Span<UInt16>(_unsafeCxxSpan: characters), quirksMode: quirksMode)
}

/// The hex color of 8-bit `characters`, without "#".
///
/// `characters` meets the conditions above. FIXME: Receive it as a `Span` once an exposed function can
/// (rdar://186723514).
@_expose(Cxx)
func cssFastPathHexColor8(_ characters: WebCore.CSSFastPathSpan8) -> Int64 {
    scanHexColor(unsafe Span<UInt8>(_unsafeCxxSpan: characters))
}

/// `cssFastPathHexColor8` for 16-bit `characters`.
///
/// `characters` meets the conditions above. FIXME: Receive it as a `Span` once an exposed function can
/// (rdar://186723514).
@_expose(Cxx)
func cssFastPathHexColor16(_ characters: WebCore.CSSFastPathSpan16) -> Int64 {
    scanHexColor(unsafe Span<UInt16>(_unsafeCxxSpan: characters))
}

/// The named color of 8-bit `characters`, in any ASCII case.
///
/// `characters` meets the conditions above. FIXME: Receive it as a `Span` once an exposed function can
/// (rdar://186723514).
@_expose(Cxx)
func cssFastPathNamedColor8(_ characters: WebCore.CSSFastPathSpan8) -> Int64 {
    scanNamedColor(unsafe Span<UInt8>(_unsafeCxxSpan: characters))
}

/// `cssFastPathNamedColor8` for 16-bit `characters`.
///
/// `characters` meets the conditions above. FIXME: Receive it as a `Span` once an exposed function can
/// (rdar://186723514).
@_expose(Cxx)
func cssFastPathNamedColor16(_ characters: WebCore.CSSFastPathSpan16) -> Int64 {
    scanNamedColor(unsafe Span<UInt16>(_unsafeCxxSpan: characters))
}

/// The length of 8-bit `characters`: a number in px or %, or 0 without a unit, or any number without a unit when
/// `svgAttributeMode`, in px; declined outside `minimum`...`maximum` and when infinite.
///
/// `characters` meets the conditions above. FIXME: Receive it as a `Span` once an exposed function can
/// (rdar://186723514).
@_expose(Cxx)
func cssFastPathLength8(
    _ characters: WebCore.CSSFastPathSpan8,
    _ svgAttributeMode: Bool,
    _ minimum: Double,
    _ maximum: Double
) -> WebCore.CSSFastPathNumber {
    scanLength(unsafe Span<UInt8>(_unsafeCxxSpan: characters), svgAttributeMode: svgAttributeMode, minimum: minimum, maximum: maximum)
}

/// `cssFastPathLength8` for 16-bit `characters`.
///
/// `characters` meets the conditions above. FIXME: Receive it as a `Span` once an exposed function can
/// (rdar://186723514).
@_expose(Cxx)
func cssFastPathLength16(
    _ characters: WebCore.CSSFastPathSpan16,
    _ svgAttributeMode: Bool,
    _ minimum: Double,
    _ maximum: Double
) -> WebCore.CSSFastPathNumber {
    scanLength(unsafe Span<UInt16>(_unsafeCxxSpan: characters), svgAttributeMode: svgAttributeMode, minimum: minimum, maximum: maximum)
}

/// The opacity of 8-bit `characters`: a number, or a percentage divided by 100; declined when infinite.
///
/// `characters` meets the conditions above. FIXME: Receive it as a `Span` once an exposed function can
/// (rdar://186723514).
@_expose(Cxx)
func cssFastPathOpacity8(_ characters: WebCore.CSSFastPathSpan8) -> WebCore.CSSFastPathNumber {
    scanOpacity(unsafe Span<UInt8>(_unsafeCxxSpan: characters))
}

/// `cssFastPathOpacity8` for 16-bit `characters`.
///
/// `characters` meets the conditions above. FIXME: Receive it as a `Span` once an exposed function can
/// (rdar://186723514).
@_expose(Cxx)
func cssFastPathOpacity16(_ characters: WebCore.CSSFastPathSpan16) -> WebCore.CSSFastPathNumber {
    scanOpacity(unsafe Span<UInt16>(_unsafeCxxSpan: characters))
}

/// Appends each function of the transform list in 8-bit `characters` to `sink`.
///
/// Returns false, having appended any number of functions, when the list is not one the fast path takes.
///
/// - `characters` meets the conditions above.
/// - `sink` is on the stack of `parseSimpleTransform`, the only place one is made (its constructor is unavailable in
///   Swift). While it is live, Swift calls only its `append`, which makes `CSSPrimitiveValue`s and a
///   `CSSFunctionValue` and appends them to the sink's list, and `cssFastPathParseNumber8`; neither reaches the
///   sink by another path, calls back into Swift, runs script or uses another thread.
///
/// FIXME: Receive `characters` as a `Span` once an exposed function can (rdar://186723514).
@_expose(Cxx)
func cssFastPathTransform8(_ characters: WebCore.CSSFastPathSpan8, _ sink: inout WebCore.CSSFastPathTransformSink) -> Bool {
    scanTransformList(unsafe Span<UInt8>(_unsafeCxxSpan: characters), &sink)
}

/// `cssFastPathTransform8` for 16-bit `characters`, with `cssFastPathParseNumber16`.
///
/// `characters` and `sink` meet the conditions of `cssFastPathTransform8`.
///
/// FIXME: Receive `characters` as a `Span` once an exposed function can (rdar://186723514).
@_expose(Cxx)
func cssFastPathTransform16(_ characters: WebCore.CSSFastPathSpan16, _ sink: inout WebCore.CSSFastPathTransformSink) -> Bool {
    scanTransformList(unsafe Span<UInt16>(_unsafeCxxSpan: characters), &sink)
}
