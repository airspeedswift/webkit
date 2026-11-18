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
internal import wtf.Core.FastFloat
internal import wtf.Core.StdLibExtras

/// A character of an 8-bit or a 16-bit string, which the HTML microsyntax and date parsers read through one
/// generic body for both widths.
protocol HTMLMicrosyntaxCodeUnit {
    /// The character as a UTF-16 code unit. A Latin-1 character keeps its value.
    var htmlMicrosyntaxCodeUnit: UInt16 { get }

    /// The number WTF::parseDouble() reads from the start of `characters`, and how many characters it read: 0 when
    /// they do not start with a number.
    static func htmlMicrosyntaxParseDouble(_ characters: Span<Self>) -> (number: Double, length: Int)

    /// The index of the first ASCII whitespace character in `characters` at or after `index`, or their count.
    static func htmlMicrosyntaxIndexOfASCIIWhitespace(_ characters: Span<Self>, from index: Int) -> Int

    /// The index of the first Latin-1 character `character` in `characters` at or after `index`, or their count.
    static func htmlMicrosyntaxIndex(of character: UInt8, in characters: Span<Self>, from index: Int) -> Int

    /// How many of the characters in `characters` are the Latin-1 character `character`.
    static func htmlMicrosyntaxCount(of character: UInt8, in characters: Span<Self>) -> UInt32
}

extension HTMLMicrosyntaxCodeUnit {
    /// Whether this is the ASCII character `character`.
    @inline(always)
    func htmlMicrosyntaxMatches(_ character: Unicode.Scalar) -> Bool {
        htmlMicrosyntaxCodeUnit == UInt16(truncatingIfNeeded: character.value)
    }

    /// Space, tab, line feed, form feed or carriage return, as isASCIIWhitespace(); not vertical tab.
    @inline(always)
    var htmlMicrosyntaxIsASCIIWhitespace: Bool {
        let character = htmlMicrosyntaxCodeUnit
        return character == 0x20 || character == 0x0A || character == 0x09 || character == 0x0D || character == 0x0C
    }

    @inline(always)
    var htmlMicrosyntaxIsASCIIDigit: Bool {
        htmlMicrosyntaxCodeUnit >= 0x30 && htmlMicrosyntaxCodeUnit <= 0x39
    }

    /// The value of an ASCII digit, or nil for any other character.
    @inline(always)
    var htmlMicrosyntaxASCIIDigitValue: UInt32? {
        htmlMicrosyntaxIsASCIIDigit ? UInt32(htmlMicrosyntaxCodeUnit - 0x30) : nil
    }
}

extension WTF.Latin1Character: HTMLMicrosyntaxCodeUnit {
    @inline(always)
    var htmlMicrosyntaxCodeUnit: UInt16 { UInt16(value) }

    static func htmlMicrosyntaxParseDouble(_ characters: Span<WTF.Latin1Character>) -> (number: Double, length: Int) {
        // Never nil for an empty span, which may have no address to make a std::span from.
        if let result = characters.htmlMicrosyntaxParseShortDecimal() {
            return result
        }
        var length = 0
        let number = WTF.parseDouble(characters, &length)
        return (number, length)
    }

    /// Skips 16 characters at a time while none of them is at or below U+0020, then one at a time, testing only the
    /// characters at or below U+0020 for ASCII whitespace.
    @inline(always)
    static func htmlMicrosyntaxIndexOfASCIIWhitespace(_ characters: Span<WTF.Latin1Character>, from index: Int) -> Int {
        var index = index
        while true {
            while characters.count - index >= 16 {
                let codeUnits = characters.htmlMicrosyntaxBlock(from: index)
                // The high bit is set in each code unit below 0x21, and in no other.
                let atOrBelowSpace = bitCast((codeUnits &- 0x21) & ~codeUnits, to: SIMD2<UInt64>.self)
                guard (atOrBelowSpace[0] | atOrBelowSpace[1]) & 0x8080_8080_8080_8080 == 0 else {
                    break
                }
                // Cannot overflow: the block's 16 characters are within the count.
                index &+= 16
            }
            while index < characters.count, characters[index].value > 0x20 {
                index += 1
            }
            guard index < characters.count, !characters[index].htmlMicrosyntaxIsASCIIWhitespace else {
                return index
            }
            index += 1
        }
    }

    /// Skips 16 characters at a time while none of them is `character`, then one at a time up to it.
    @inline(always)
    static func htmlMicrosyntaxIndex(of character: UInt8, in characters: Span<WTF.Latin1Character>, from index: Int) -> Int {
        let characterInEachLane = SIMD16<UInt8>(repeating: character)
        var index = index
        while characters.count - index >= 16 {
            let matches = bitCast(
                (characters.htmlMicrosyntaxBlock(from: index) ^ characterInEachLane).htmlMicrosyntaxZeroLanes,
                to: SIMD2<UInt64>.self
            )
            guard matches[0] | matches[1] == 0 else {
                break
            }
            // Cannot overflow: the block's 16 characters are within the count.
            index &+= 16
        }
        while index < characters.count, characters[index].value != character {
            index += 1
        }
        return index
    }

    /// Counts 16 characters at a time, then one at a time.
    ///
    /// No sum overflows: there is at most one per character, and a StringView has fewer than 2^32.
    @inline(never)
    static func htmlMicrosyntaxCount(of character: UInt8, in characters: Span<WTF.Latin1Character>) -> UInt32 {
        let characterInEachLane = SIMD16<UInt8>(repeating: character)
        var count: UInt32 = 0
        var index = 0
        while characters.count - index >= 16 {
            let matches = bitCast(
                (characters.htmlMicrosyntaxBlock(from: index) ^ characterInEachLane).htmlMicrosyntaxZeroLanes,
                to: SIMD2<UInt64>.self
            )
            // Each byte of the sum of the two words is at most 2, so the multiplication adds all 8 into the top byte.
            count &+= UInt32(truncatingIfNeeded: ((matches[0] + matches[1]) &* 0x0101_0101_0101_0101) &>> 56)
            // Cannot overflow: the block's 16 characters are within the count.
            index &+= 16
        }
        while index < characters.count {
            count &+= characters[index].value == character ? 1 : 0
            index += 1
        }
        return count
    }
}

extension UInt16: HTMLMicrosyntaxCodeUnit {
    @inline(always)
    var htmlMicrosyntaxCodeUnit: UInt16 { self }

    static func htmlMicrosyntaxParseDouble(_ characters: Span<UInt16>) -> (number: Double, length: Int) {
        // Never nil for an empty span, which may have no address to make a std::span from.
        if let result = characters.htmlMicrosyntaxParseShortDecimal() {
            return result
        }
        var length = 0
        let number = WTF.parseDouble(characters, &length)
        return (number, length)
    }

    /// Tests only the characters at or below U+0020 for ASCII whitespace.
    @inline(always)
    static func htmlMicrosyntaxIndexOfASCIIWhitespace(_ characters: Span<UInt16>, from index: Int) -> Int {
        var index = index
        while true {
            index = characters.htmlMicrosyntaxIndexOfCodeUnitAtOrBelowSpace(from: index)
            guard index < characters.count, !characters[index].htmlMicrosyntaxIsASCIIWhitespace else {
                return index
            }
            index += 1
        }
    }

    /// Skips 16 characters at a time while none of them is `character`, then one at a time up to it.
    @inline(always)
    static func htmlMicrosyntaxIndex(of character: UInt8, in characters: Span<UInt16>, from index: Int) -> Int {
        let characterInEachLane = SIMD8<UInt16>(repeating: UInt16(character))
        var index = index
        while characters.count - index >= 16 {
            let (first, second) = characters.htmlMicrosyntaxBlock(from: index)
            // Not 0 in each lane where either half holds the character.
            let matches = bitCast(
                (first ^ characterInEachLane).htmlMicrosyntaxZeroLanes &+ (second ^ characterInEachLane).htmlMicrosyntaxZeroLanes,
                to: SIMD2<UInt64>.self
            )
            guard matches[0] | matches[1] == 0 else {
                break
            }
            // Cannot overflow: the block's 16 characters are within the count.
            index &+= 16
        }
        while index < characters.count, characters[index] != UInt16(character) {
            index += 1
        }
        return index
    }

    /// Counts 16 characters at a time, then one at a time.
    ///
    /// No sum overflows: there is at most one per character, and a StringView has fewer than 2^32.
    @inline(never)
    static func htmlMicrosyntaxCount(of character: UInt8, in characters: Span<UInt16>) -> UInt32 {
        let characterInEachLane = SIMD8<UInt16>(repeating: UInt16(character))
        var count: UInt32 = 0
        var index = 0
        while characters.count - index >= 16 {
            let (first, second) = characters.htmlMicrosyntaxBlock(from: index)
            let matches = bitCast(
                (first ^ characterInEachLane).htmlMicrosyntaxZeroLanes &+ (second ^ characterInEachLane).htmlMicrosyntaxZeroLanes,
                to: SIMD2<UInt64>.self
            )
            // Each 16-bit lane of the sum of the two words is at most 4, so the multiplication adds all 4 into the top
            // 16 bits.
            count &+= UInt32(truncatingIfNeeded: ((matches[0] + matches[1]) &* 0x0001_0001_0001_0001) &>> 48)
            // Cannot overflow: the block's 16 characters are within the count.
            index &+= 16
        }
        while index < characters.count {
            count &+= characters[index] == UInt16(character) ? 1 : 0
            index += 1
        }
        return count
    }
}

extension Span where Element == WTF.Latin1Character {
    /// The code units of the 16 characters from `index`.
    @inline(always)
    fileprivate func htmlMicrosyntaxBlock(from index: Int) -> SIMD16<UInt8> {
        // Cannot overflow: every caller has at least 16 characters from index.
        let block = extracting(index..<index &+ 16)
        return SIMD16<UInt8>(
            block[0].value,
            block[1].value,
            block[2].value,
            block[3].value,
            block[4].value,
            block[5].value,
            block[6].value,
            block[7].value,
            block[8].value,
            block[9].value,
            block[10].value,
            block[11].value,
            block[12].value,
            block[13].value,
            block[14].value,
            block[15].value
        )
    }
}

extension Span where Element == UInt16 {
    /// The 16 code units from `index`, 8 in each vector.
    @inline(always)
    fileprivate func htmlMicrosyntaxBlock(from index: Int) -> (SIMD8<UInt16>, SIMD8<UInt16>) {
        // Cannot overflow: every caller has at least 16 characters from index.
        let block = extracting(index..<index &+ 16)
        return (
            SIMD8<UInt16>(block[0], block[1], block[2], block[3], block[4], block[5], block[6], block[7]),
            SIMD8<UInt16>(block[8], block[9], block[10], block[11], block[12], block[13], block[14], block[15])
        )
    }
}

extension SIMD16 where Scalar == UInt8 {
    /// 1 in each lane that is 0, and 0 in every other.
    @inline(always)
    fileprivate var htmlMicrosyntaxZeroLanes: SIMD16<UInt8> {
        ((self &- 1) & ~self) &>> 7
    }
}

extension SIMD8 where Scalar == UInt16 {
    /// 1 in each lane that is 0, and 0 in every other.
    @inline(always)
    fileprivate var htmlMicrosyntaxZeroLanes: SIMD8<UInt16> {
        ((self &- 1) & ~self) &>> 15
    }
}

extension Span where Element: HTMLMicrosyntaxCodeUnit {
    /// The index of the first character at or after `index` that is ASCII whitespace, or `count`.
    @inline(always)
    func htmlMicrosyntaxIndexOfASCIIWhitespace(from index: Int) -> Int {
        Element.htmlMicrosyntaxIndexOfASCIIWhitespace(self, from: index)
    }

    /// The index of the first Latin-1 character `character` at or after `index`, or `count`.
    @inline(always)
    func htmlMicrosyntaxIndex(of character: UInt8, from index: Int) -> Int {
        Element.htmlMicrosyntaxIndex(of: character, in: self, from: index)
    }

    /// The index of the first character at or after `index` that is at or below U+0020, or `count`.
    ///
    /// It is not inlined, so that its loop takes one branch per character.
    @inline(never)
    func htmlMicrosyntaxIndexOfCodeUnitAtOrBelowSpace(from index: Int) -> Int {
        var index = index
        while index < count, self[index].htmlMicrosyntaxCodeUnit > 0x20 {
            index += 1
        }
        return index
    }

    /// The index of the first character at or after `index` that is not ASCII whitespace, or `count`.
    @inline(always)
    func htmlMicrosyntaxIndexAfterASCIIWhitespace(from index: Int) -> Int {
        var index = index
        while index < count, self[index].htmlMicrosyntaxIsASCIIWhitespace {
            index += 1
        }
        return index
    }

    /// The index of the first character at or after `index` that is not an ASCII digit, or `count`.
    @inline(always)
    func htmlMicrosyntaxIndexAfterASCIIDigits(from index: Int) -> Int {
        var index = index
        while index < count, self[index].htmlMicrosyntaxIsASCIIDigit {
            index += 1
        }
        return index
    }

    /// The number WTF::parseDouble() reads from the start of the characters, and how many it read, when one
    /// correctly rounded operation gives it; nil for any other number.
    ///
    /// WTF::parseDouble() reads an optional '+' or '-', then digits with an optional '.', at least one digit, then an
    /// exponent only when it has a digit; without a number it returns 0 and a length of 0. When the digits make an
    /// integer of at most 2^53, which a double holds exactly, and the power of ten is from -22 to 22, which a double
    /// also holds exactly, the number is one multiplication or division of the two, the correctly rounded result
    /// WTF::parseDouble() also returns. Like WTF::parseDouble(), this assumes the default rounding mode, to nearest.
    @inline(always)
    func htmlMicrosyntaxParseShortDecimal() -> (number: Double, length: Int)? {
        guard !isEmpty else {
            return (0, 0)
        }
        // Without a digit after it, or a '.' and a digit, a sign gives no number below, as in WTF::parseDouble().
        let isNegative = self[0].htmlMicrosyntaxMatches("-")
        var index = isNegative || self[0].htmlMicrosyntaxMatches("+") ? 1 : 0

        // 2^53. Digits only make the significand larger, so one above this stays above it.
        let maximumSignificand: UInt64 = 1 << (Double.significandBitCount + 1)
        var significand: UInt64 = 0
        let integerStart = index
        integerDigits: do {
            // The first four digits are read without a loop. They make at most 9999, which is below 2^53.
            for _ in 0..<4 {
                guard index < count, let digit = self[index].htmlMicrosyntaxASCIIDigitValue else {
                    break integerDigits
                }
                significand = significand * 10 + UInt64(digit)
                index += 1
            }
            while index < count, let digit = self[index].htmlMicrosyntaxASCIIDigitValue {
                // Cannot overflow: the significand is at most 2^53 before each digit.
                significand = significand &* 10 &+ UInt64(digit)
                guard significand <= maximumSignificand else {
                    return nil
                }
                index += 1
            }
        }
        let hasIntegerDigits = index > integerStart
        var fractionDigitCount = 0
        if index < count, self[index].htmlMicrosyntaxMatches(".") {
            index += 1
            let fractionStart = index
            while index < count, let digit = self[index].htmlMicrosyntaxASCIIDigitValue {
                significand = significand * 10 + UInt64(digit)
                guard significand <= maximumSignificand else {
                    return nil
                }
                index += 1
            }
            fractionDigitCount = index - fractionStart
        }
        guard hasIntegerDigits || fractionDigitCount > 0 else {
            return (0, 0)
        }

        // 10^22 = 5^22 * 2^22 is the largest power of ten a double holds exactly: 5^22 < 2^53 < 5^23.
        let maximumExactPowerOfTen = 22
        guard fractionDigitCount <= maximumExactPowerOfTen else {
            return nil
        }
        // Without an exponent, the number is the significand divided by 10^fractionDigitCount, which is exact when
        // there is no fraction, since the significand is a whole number of at most 2^53.
        guard index < count, self[index].htmlMicrosyntaxMatches("e") || self[index].htmlMicrosyntaxMatches("E") else {
            let number = Double(significand) / htmlMicrosyntaxExactPowersOfTen[fractionDigitCount]
            return (isNegative ? -number : number, index)
        }
        var exponent = -fractionDigitCount
        var exponentIndex = index + 1
        let isExponentNegative = exponentIndex < count && self[exponentIndex].htmlMicrosyntaxMatches("-")
        if isExponentNegative || (exponentIndex < count && self[exponentIndex].htmlMicrosyntaxMatches("+")) {
            exponentIndex += 1
        }
        // Without a digit after it, the 'e' is not part of the number.
        if exponentIndex < count, self[exponentIndex].htmlMicrosyntaxIsASCIIDigit {
            var exponentValue = 0
            while exponentIndex < count, let digit = self[exponentIndex].htmlMicrosyntaxASCIIDigitValue {
                exponentValue = exponentValue * 10 + Int(digit)
                // Beyond 44, no fraction of at most 22 digits brings the power of ten back to -22...22.
                guard exponentValue <= 2 * maximumExactPowerOfTen else {
                    return nil
                }
                exponentIndex += 1
            }
            // Cannot overflow: the exponent is from -22 to 0 and the value at most 44.
            exponent &+= isExponentNegative ? -exponentValue : exponentValue
            index = exponentIndex
        }
        guard exponent >= -maximumExactPowerOfTen, exponent <= maximumExactPowerOfTen else {
            return nil
        }

        // A multiplication by 10^0 is exact.
        var number = Double(significand)
        if exponent < 0 {
            number /= htmlMicrosyntaxExactPowersOfTen[-exponent]
        } else {
            number *= htmlMicrosyntaxExactPowersOfTen[exponent]
        }
        return (isNegative ? -number : number, index)
    }

    /// The number WTF::parseDouble() reads from the start of the characters in `range`, and how many it read.
    @inline(always)
    func htmlMicrosyntaxParseDouble(_ range: Range<Int>) -> (number: Double, length: Int) {
        Element.htmlMicrosyntaxParseDouble(extracting(range))
    }
}

/// 10^0 to 10^22, each of which a double holds exactly.
private let htmlMicrosyntaxExactPowersOfTen: [23 of Double] = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
    1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22,
]
