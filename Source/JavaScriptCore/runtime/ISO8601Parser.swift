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

internal import CxxStdlib
internal import JSCSwiftBoundary

/// `parseInt(characters, 10)` from ParseInt.h, for what `parseDuration` gives it: at least one character, all ASCII
/// digits (so no white space, sign or `0x` prefix).
private func temporalParseIntDecimalDigits<Unit: TemporalCodeUnit>(_ characters: Span<Unit>) -> Double {
    // ParseInt.h's constants, pinned by a `static_assert` in ISO8601.cpp.
    let numberOfDigitsForSafeInt32 = 9
    let mantissaOverflowLowerBound = 9007199254740992.0
    let length = characters.count
    if length <= numberOfDigitsForSafeInt32 {
        let first = characters[0]
        if temporalIsInASCIIRange(first, UInt8(ascii: "1"), UInt8(ascii: "9")) {
            var intNumber = temporalDigitValue(first)
            for i in 1..<length {
                // Cannot overflow: at most 9 digits.
                intNumber = intNumber &* 10 &+ temporalDigitValue(characters[i])
            }
            return Double(intNumber)
        }
        if temporalIs(first, UInt8(ascii: "0")) && length == 1 {
            return 0
        }
    }

    // The digits' exact value, correctly rounded, which is what ParseInt.h gives: below 2^53 its double
    // accumulation is exact, and from 2^53 it calls parseDouble, which rounds the same integer correctly.
    if length <= 19 {
        // Cannot overflow: at most 19 digits, under 10^19 < 2^64.
        var value: UInt64 = 0
        for i in 0..<length {
            value = value &* 10 &+ UInt64(truncatingIfNeeded: temporalDigitValue(characters[i]))
        }
        return Double(value)
    }
    if length <= 38 {
        // Cannot overflow: at most 38 digits, under 10^38 < 2^127.
        var value: Int128 = 0
        for i in 0..<length {
            value = value &* 10 &+ Int128(temporalDigitValue(characters[i]))
        }
        return temporalDouble(value)
    }
    return temporalParseLongDecimalDigits(characters, mantissaOverflowLowerBound)
}

/// `temporalParseIntDecimalDigits` for more than 38 digits.
@inline(never)
private func temporalParseLongDecimalDigits<Unit: TemporalCodeUnit>(
    _ characters: Span<Unit>,
    _ mantissaOverflowLowerBound: Double
) -> Double {
    let length = characters.count
    var number: Double = 0
    for i in 0..<length {
        number = number * 10 + Double(temporalDigitValue(characters[i]))
    }
    if number >= mantissaOverflowLowerBound {
        // Double(_:) rounds correctly, as parseDouble does.
        var text = ""
        for i in 0..<length {
            text.unicodeScalars.append(Unicode.Scalar(UInt8(truncatingIfNeeded: characters[i])))
        }
        // Every character is a digit, so the conversion succeeds (to infinity past the largest double).
        number = Double(text) ?? .nan
    }
    return number
}

// MARK: - Parsers

extension TemporalISO8601 {
    static func parseDecimalInt32<Unit: TemporalCodeUnit>(_ characters: Span<Unit>) -> Int32 {
        var value: Int32 = 0
        for i in 0..<characters.count {
            assert(temporalIsASCIIDigit(characters[i]))
            // Cannot overflow: every caller passes at most 9 digits.
            value = (value &* 10) &+ temporalDigitValue(characters[i])
        }
        return value
    }

    // DurationHandleFractions ( fHours, minutes, fMinutes, seconds, fSeconds, milliseconds, fMilliseconds, microseconds, fMicroseconds, nanoseconds, fNanoseconds )
    // https://tc39.es/proposal-temporal/#sec-temporal-durationhandlefractions
    static func handleFraction<Unit: TemporalCodeUnit>(
        _ duration: inout JSC.ISO8601.Duration,
        _ factor: Int32,
        _ fractionString: Span<Unit>,
        _ fractionType: JSC.TemporalUnit
    ) {
        let fractionLength = fractionString.count
        assert(fractionLength > 0 && fractionLength <= 9)
        assert(fractionType == .Hour || fractionType == .Minute || fractionType == .Second)

        var padded: [9 of UInt8] = .init(repeating: UInt8(ascii: "0"))
        for i in 0..<fractionLength {
            padded[i] = UInt8(truncatingIfNeeded: fractionString[i])
        }

        var fraction = Int64(factor) * Int64(parseDecimalInt32(padded.span))
        if fraction == 0 {
            return
        }

        let divisor: Int64 = 1_000_000_000
        if fractionType == .Hour {
            // Cannot overflow: |fraction| < 10^9 here.
            fraction = fraction &* 60
            duration.setMinutes(fraction / divisor)
            fraction %= divisor
            if fraction == 0 {
                return
            }
        }

        if fractionType != .Second {
            // Cannot overflow: |fraction| < 10^9 here.
            fraction = fraction &* 60
            duration.setSeconds(fraction / divisor)
            fraction %= divisor
            if fraction == 0 {
                return
            }
        }

        duration.setMilliseconds(fraction / nsPerMillisecond)
        duration.setMicroseconds(Int128(fraction % nsPerMillisecond / nsPerMicrosecond))
        duration.setNanoseconds(Int128(fraction % nsPerMicrosecond))
    }

    // ParseTemporalDurationString ( isoString )
    // https://tc39.es/proposal-temporal/#sec-temporal-parsetemporaldurationstring
    static func parseDuration<Unit: TemporalCodeUnit>(_ buffer: inout TemporalCursor<Unit>) -> JSC.ISO8601.Duration? {
        // ISO 8601 duration strings are like "-P1Y2M3W4DT5H6M7.123456789S". Notes:
        // - case insensitive
        // - sign: + -
        // - separator: . ,
        // - T is present iff there is a time part
        // - integral parts can have any number of digits but fractional parts have at most 9
        // - hours and minutes can have fractional parts too, but only as the LAST part of the string
        if buffer.lengthRemaining < 3 {
            return nil
        }

        var result = JSC.ISO8601.Duration()

        var factor: Int32 = 1
        if temporalIs(buffer.current, UInt8(ascii: "+")) {
            buffer.advance()
        } else if temporalIs(buffer.current, UInt8(ascii: "-")) {
            factor = -1
            buffer.advance()
        }

        if !temporalIs(temporalToASCIIUpper(buffer.current), UInt8(ascii: "P")) {
            return nil
        }

        buffer.advance()
        var datePartIndex = 0
        while datePartIndex < 4 && buffer.hasCharactersRemaining && temporalIsASCIIDigit(buffer.current) {
            var digits = 1
            while digits < buffer.lengthRemaining && temporalIsASCIIDigit(buffer[digits]) {
                digits += 1
            }

            let integer = Double(factor) * temporalParseIntDecimalDigits(buffer.consume(digits))
            if buffer.atEnd {
                return nil
            }

            switch temporalToASCIIUpper(buffer.current) {
            case Unit(UInt8(ascii: "Y")):
                if datePartIndex != 0 {
                    return nil
                }
                TemporalISO8601.durationSetField(&result, JSC.TemporalUnit.Year, integer)
                datePartIndex = 1
            case Unit(UInt8(ascii: "M")):
                if datePartIndex >= 2 {
                    return nil
                }
                TemporalISO8601.durationSetField(&result, JSC.TemporalUnit.Month, integer)
                datePartIndex = 2
            case Unit(UInt8(ascii: "W")):
                if datePartIndex >= 3 {
                    return nil
                }
                TemporalISO8601.durationSetField(&result, JSC.TemporalUnit.Week, integer)
                datePartIndex = 3
            case Unit(UInt8(ascii: "D")):
                TemporalISO8601.durationSetField(&result, JSC.TemporalUnit.Day, integer)
                datePartIndex = 4
            default:
                return nil
            }
            buffer.advance()
        }

        if buffer.atEnd {
            return result
        }

        if buffer.lengthRemaining < 3 || !temporalIs(temporalToASCIIUpper(buffer.current), UInt8(ascii: "T")) {
            return nil
        }

        buffer.advance()
        var timePartIndex = 0
        while timePartIndex < 3 && buffer.hasCharactersRemaining && temporalIsASCIIDigit(buffer.current) {
            var digits = 1
            while digits < buffer.lengthRemaining && temporalIsASCIIDigit(buffer[digits]) {
                digits += 1
            }

            let integer = Double(factor) * temporalParseIntDecimalDigits(buffer.consume(digits))
            if buffer.atEnd {
                return nil
            }

            // The fractional part's position and length; a length of 0 is a null StringView.
            var fractionStart = 0
            var fractionLength = 0
            if temporalIs(buffer.current, UInt8(ascii: ".")) || temporalIs(buffer.current, UInt8(ascii: ",")) {
                buffer.advance()
                digits = 0
                while digits < buffer.lengthRemaining && temporalIsASCIIDigit(buffer[digits]) {
                    digits += 1
                }
                if digits == 0 || digits > 9 {
                    return nil
                }

                fractionStart = buffer.position
                fractionLength = digits
                buffer.advance(by: digits)
                if buffer.atEnd {
                    return nil
                }
            }
            let fractionalPart = buffer.characters.extracting(fractionStart..<fractionStart + fractionLength)

            switch temporalToASCIIUpper(buffer.current) {
            case Unit(UInt8(ascii: "H")):
                if timePartIndex != 0 {
                    return nil
                }
                TemporalISO8601.durationSetField(&result, JSC.TemporalUnit.Hour, integer)
                if fractionLength != 0 {
                    handleFraction(&result, factor, fractionalPart, .Hour)
                    timePartIndex = 3
                } else {
                    timePartIndex = 1
                }
            case Unit(UInt8(ascii: "M")):
                if timePartIndex >= 2 {
                    return nil
                }
                TemporalISO8601.durationSetField(&result, JSC.TemporalUnit.Minute, integer)
                if fractionLength != 0 {
                    handleFraction(&result, factor, fractionalPart, .Minute)
                    timePartIndex = 3
                } else {
                    timePartIndex = 2
                }
            case Unit(UInt8(ascii: "S")):
                TemporalISO8601.durationSetField(&result, JSC.TemporalUnit.Second, integer)
                if fractionLength != 0 {
                    handleFraction(&result, factor, fractionalPart, .Second)
                }
                timePartIndex = 3
            default:
                return nil
            }
            buffer.advance()
        }

        if buffer.hasCharactersRemaining {
            return nil
        }

        return result
    }

    static func parseDuration<Unit: TemporalCodeUnit>(_ string: Span<Unit>) -> JSC.ISO8601.Duration? {
        var buffer = TemporalCursor(string)
        return parseDuration(&buffer)
    }

    enum Second60Mode {
        case accept
        case reject
    }

    static func parseTimeSpec<Unit: TemporalCodeUnit>(
        _ buffer: inout TemporalCursor<Unit>,
        _ second60Mode: Second60Mode,
        _ subMinutePrecision: JSC.ISO8601.SubMinutePrecision,
        _ outHasSeconds: inout Bool
    ) -> JSC.ISO8601.PlainTime? {
        // https://tc39.es/proposal-temporal/#prod-TimeSpec
        // TimeSpec :
        //     TimeHour
        //     TimeHour : TimeMinute
        //     TimeHour TimeMinute
        //     TimeHour : TimeMinute : TimeSecond TimeFraction[opt]
        //     TimeHour TimeMinute TimeSecond TimeFraction[opt]
        //
        //  TimeSecond can be 60. And if it is 60, we interpret it as 59.
        //  https://tc39.es/proposal-temporal/#sec-temporal-parseisodatetime

        if buffer.lengthRemaining < 2 {
            return nil
        }

        let firstHourCharacter = buffer.current
        if !temporalIsInASCIIRange(firstHourCharacter, UInt8(ascii: "0"), UInt8(ascii: "2")) {
            return nil
        }

        buffer.advance()
        let secondHourCharacter = buffer.current
        if !temporalIsASCIIDigit(secondHourCharacter) {
            return nil
        }
        let hour = UInt32(temporalDigitValue(secondHourCharacter) + 10 * temporalDigitValue(firstHourCharacter))
        if hour >= 24 {
            return nil
        }
        buffer.advance()

        if buffer.atEnd {
            return JSC.ISO8601.PlainTime(hour, 0, 0, 0, 0, 0)
        }

        var splitByColon = false
        if temporalIs(buffer.current, UInt8(ascii: ":")) {
            splitByColon = true
            buffer.advance()
        } else if !temporalIsInASCIIRange(buffer.current, UInt8(ascii: "0"), UInt8(ascii: "5")) {
            return JSC.ISO8601.PlainTime(hour, 0, 0, 0, 0, 0)
        }

        if buffer.lengthRemaining < 2 {
            return nil
        }
        let firstMinuteCharacter = buffer.current
        if !temporalIsInASCIIRange(firstMinuteCharacter, UInt8(ascii: "0"), UInt8(ascii: "5")) {
            return nil
        }

        buffer.advance()
        let secondMinuteCharacter = buffer.current
        if !temporalIsASCIIDigit(secondMinuteCharacter) {
            return nil
        }
        let minute = UInt32(temporalDigitValue(secondMinuteCharacter) + 10 * temporalDigitValue(firstMinuteCharacter))
        assert(minute < 60)
        buffer.advance()

        if buffer.atEnd {
            return JSC.ISO8601.PlainTime(hour, minute, 0, 0, 0, 0)
        }

        if splitByColon {
            guard temporalIs(buffer.current, UInt8(ascii: ":")) else {
                return JSC.ISO8601.PlainTime(hour, minute, 0, 0, 0, 0)
            }
            buffer.advance()
        } else if !temporalIsInASCIIRange(
            buffer.current,
            UInt8(ascii: "0"),
            second60Mode == .accept ? UInt8(ascii: "6") : UInt8(ascii: "5")
        ) {
            return JSC.ISO8601.PlainTime(hour, minute, 0, 0, 0, 0)
        }

        if subMinutePrecision == .No {
            return nil
        }

        outHasSeconds = true
        var second: UInt32 = 0
        if buffer.lengthRemaining < 2 {
            return nil
        }
        let firstSecondCharacter = buffer.current
        if temporalIsInASCIIRange(firstSecondCharacter, UInt8(ascii: "0"), UInt8(ascii: "5")) {
            buffer.advance()
            let secondSecondCharacter = buffer.current
            if !temporalIsASCIIDigit(secondSecondCharacter) {
                return nil
            }
            second = UInt32(temporalDigitValue(secondSecondCharacter) + 10 * temporalDigitValue(firstSecondCharacter))
            assert(second < 60)
            buffer.advance()
        } else if second60Mode == .accept && temporalIs(firstSecondCharacter, UInt8(ascii: "6")) {
            buffer.advance()
            let secondSecondCharacter = buffer.current
            if !temporalIs(secondSecondCharacter, UInt8(ascii: "0")) {
                return nil
            }
            second = 59
            buffer.advance()
        } else {
            return nil
        }

        if buffer.atEnd {
            return JSC.ISO8601.PlainTime(hour, minute, second, 0, 0, 0)
        }

        if !temporalIs(buffer.current, UInt8(ascii: ".")) && !temporalIs(buffer.current, UInt8(ascii: ",")) {
            return JSC.ISO8601.PlainTime(hour, minute, second, 0, 0, 0)
        }
        buffer.advance()

        // The fraction's digits, padded with zeros to nine: below 10^9, so the arithmetic cannot overflow.
        var digits = 0
        var fraction: UInt32 = 0
        let maxCount = min(buffer.lengthRemaining, 9)
        while digits < maxCount {
            let character = buffer[digits]
            if !temporalIsASCIIDigit(character) {
                break
            }
            fraction = fraction &* 10 &+ UInt32(bitPattern: temporalDigitValue(character))
            digits += 1
        }
        if digits == 0 {
            return nil
        }
        for _ in digits..<9 {
            fraction &*= 10
        }
        buffer.advance(checkedCount: digits)

        let millisecond = fraction / 1_000_000
        let microsecond = fraction / 1000 % 1000
        let nanosecond = fraction % 1000

        return JSC.ISO8601.PlainTime(hour, minute, second, millisecond, microsecond, nanosecond)
    }

    static func parseUTCOffset<Unit: TemporalCodeUnit>(
        _ buffer: inout TemporalCursor<Unit>,
        _ subMinutePrecision: JSC.ISO8601.SubMinutePrecision
    ) -> (nanoseconds: Int64, hasSubMinutePrecision: Bool)? {
        // UTCOffset[SubMinutePrecision] :
        //     ASCIISign Hour
        //     ASCIISign Hour TimeSeparator[+Extended] MinuteSecond
        //     ASCIISign Hour TimeSeparator[~Extended] MinuteSecond
        //     [+SubMinutePrecision] ASCIISign Hour TimeSeparator[+Extended] MinuteSecond TimeSeparator[+Extended] MinuteSecond TemporalDecimalFractionopt
        //     [+SubMinutePrecision] ASCIISign Hour TimeSeparator[~Extended] MinuteSecond TimeSeparator[~Extended] MinuteSecond TemporalDecimalFractionopt
        //
        //  This is the same to
        //     ASCIISign TimeSpec
        //
        //  Maximum and minimum values are ±23:59:59.999999999 = ±86399999999999ns, which can be represented by int64_t / double's integer part.

        // sign and hour.
        if buffer.lengthRemaining < 3 {
            return nil
        }

        var factor: Int64 = 1
        if temporalIs(buffer.current, UInt8(ascii: "+")) {
            buffer.advance()
        } else if temporalIs(buffer.current, UInt8(ascii: "-")) {
            factor = -1
            buffer.advance()
        } else {
            return nil
        }

        var hasSeconds = false
        guard let plainTime = parseTimeSpec(&buffer, .reject, subMinutePrecision, &hasSeconds) else {
            return nil
        }

        let hour = Int64(plainTime.hour())
        let minute = Int64(plainTime.minute())
        let second = Int64(plainTime.second())
        let millisecond = Int64(plainTime.millisecond())
        let microsecond = Int64(plainTime.microsecond())
        let nanosecond = Int64(plainTime.nanosecond())

        let nanoseconds =
            (nsPerHour * hour + nsPerMinute * minute + nsPerSecond * second + nsPerMillisecond * millisecond
                + nsPerMicrosecond * microsecond + nanosecond) * factor
        return (nanoseconds, hasSeconds)
    }

    static func parseUTCOffset<Unit: TemporalCodeUnit>(_ string: Span<Unit>, _ subMinutePrecision: JSC.ISO8601.SubMinutePrecision) -> Int64?
    {
        var buffer = TemporalCursor(string)
        let result = parseUTCOffset(&buffer, subMinutePrecision)
        if !buffer.atEnd {
            return nil
        }
        return result?.nanoseconds
    }

    static func parseUTCOffsetInMinutes<Unit: TemporalCodeUnit>(_ buffer: inout TemporalCursor<Unit>) -> Int64? {
        // UTCOffset :::
        //     TemporalSign Hour
        //     TemporalSign Hour HourSubcomponents[+Extended]
        //     TemporalSign Hour HourSubcomponents[~Extended]
        //
        // TemporalSign :::
        //     ASCIISign
        //     <MINUS>
        //
        // ASCIISign ::: one of
        //     + -
        //
        // Hour :::
        //     0 DecimalDigit
        //     1 DecimalDigit
        //     20
        //     21
        //     22
        //     23
        //
        // HourSubcomponents[Extended] :::
        //     TimeSeparator[?Extended] MinuteSecond
        //
        // TimeSeparator[Extended] :::
        //     [+Extended] :
        //     [~Extended] [empty]
        //
        // MinuteSecond :::
        //     0 DecimalDigit
        //     1 DecimalDigit
        //     2 DecimalDigit
        //     3 DecimalDigit
        //     4 DecimalDigit
        //     5 DecimalDigit

        // sign and hour.
        if buffer.lengthRemaining < 3 {
            return nil
        }

        var factor: Int64 = 1
        if temporalIs(buffer.current, UInt8(ascii: "+")) {
            buffer.advance()
        } else if temporalIs(buffer.current, UInt8(ascii: "-")) {
            factor = -1
            buffer.advance()
        } else {
            return nil
        }

        let firstHourCharacter = buffer.current
        if !temporalIsInASCIIRange(firstHourCharacter, UInt8(ascii: "0"), UInt8(ascii: "2")) {
            return nil
        }

        buffer.advance()
        let secondHourCharacter = buffer.current
        if !temporalIsASCIIDigit(secondHourCharacter) {
            return nil
        }
        let hour = Int64(temporalDigitValue(secondHourCharacter) + 10 * temporalDigitValue(firstHourCharacter))
        if hour >= 24 {
            return nil
        }
        buffer.advance()

        if buffer.atEnd {
            return (hour * 60) * factor
        }

        if temporalIs(buffer.current, UInt8(ascii: ":")) {
            buffer.advance()
        } else if !temporalIsInASCIIRange(buffer.current, UInt8(ascii: "0"), UInt8(ascii: "5")) {
            return (hour * 60) * factor
        }

        if buffer.lengthRemaining < 2 {
            return nil
        }
        let firstMinuteCharacter = buffer.current
        if !temporalIsInASCIIRange(firstMinuteCharacter, UInt8(ascii: "0"), UInt8(ascii: "5")) {
            return nil
        }

        buffer.advance()
        let secondMinuteCharacter = buffer.current
        if !temporalIsASCIIDigit(secondMinuteCharacter) {
            return nil
        }
        let minute = Int64(temporalDigitValue(secondMinuteCharacter) + 10 * temporalDigitValue(firstMinuteCharacter))
        assert(minute < 60)
        buffer.advance()

        return (hour * 60 + minute) * factor
    }

    static func parseUTCOffsetInMinutes<Unit: TemporalCodeUnit>(_ string: Span<Unit>) -> Int64? {
        var buffer = TemporalCursor(string)
        let result = parseUTCOffsetInMinutes(&buffer)
        if !buffer.atEnd {
            return nil
        }
        return result
    }

    static func canBeRFC9557Annotation<Unit: TemporalCodeUnit>(_ buffer: borrowing TemporalCursor<Unit>) -> Bool {
        // https://tc39.es/proposal-temporal/#sec-temporal-parseisodatetime
        // Step 4(a)(ii)(2)(a):
        //  Let key be the source text matched by the AnnotationKey Parse Node contained within annotation
        //
        // https://tc39.es/proposal-temporal/#prod-Annotation
        // Annotation :::
        //     [ AnnotationCriticalFlag[opt] AnnotationKey = AnnotationValue ]
        //
        // AnnotationCriticalFlag :::
        //     !
        //
        // AnnotationKey :::
        //     AKeyLeadingChar
        //     AnnotationKey AKeyChar
        //
        // AKeyLeadingChar :::
        //     LowercaseAlpha
        //     _
        //
        // AKeyChar :::
        //     AKeyLeadingChar
        //     DecimalDigit
        //     -
        //
        // AnnotationValue :::
        //     AnnotationValueComponent
        //     AnnotationValueComponent - AnnotationValue
        //
        // AnnotationValueComponent :::
        //     Alpha AnnotationValueComponent[opt]
        //     DecimalDigit AnnotationValueComponent[opt]

        // This just checks for '[', followed by an optional '!' (critical flag),
        // followed by a valid key, followed by an '='.

        let length = buffer.lengthRemaining
        // Because of `[`, `=`, `]`, `AnnotationKey`, and `AnnotationValue`,
        // the annotation must have length >= 5.
        if length < 5 {
            return false
        }
        if !temporalIs(buffer.current, UInt8(ascii: "[")) {
            return false
        }
        var index = 1
        if temporalIs(buffer[index], UInt8(ascii: "!")) {
            index += 1
        }
        if !temporalIsASCIILower(buffer[index]) && !temporalIs(buffer[index], UInt8(ascii: "_")) {
            return false
        }
        index += 1
        while index < length {
            let character = buffer[index]
            if temporalIs(character, UInt8(ascii: "=")) {
                return true
            }
            guard
                temporalIsASCIILower(character) || temporalIsASCIIDigit(character) || temporalIs(character, UInt8(ascii: "-"))
                    || temporalIs(character, UInt8(ascii: "_"))
            else {
                return false
            }
            index += 1
        }
        return false
    }

    static func canBeTimeZone<Unit: TemporalCodeUnit>(_ buffer: borrowing TemporalCursor<Unit>, _ character: Unit) -> Bool {
        // UTCDesignator
        // https://tc39.es/proposal-temporal/#prod-UTCDesignator
        // TimeZoneUTCOffsetSign
        // https://tc39.es/proposal-temporal/#prod-TimeZoneUTCOffsetSign
        if temporalIs(character, UInt8(ascii: "z")) || temporalIs(character, UInt8(ascii: "Z"))
            || temporalIs(character, UInt8(ascii: "+")) || temporalIs(character, UInt8(ascii: "-"))
        {
            return true
        }
        // TimeZoneBracketedAnnotation
        // https://tc39.es/proposal-temporal/#prod-TimeZoneBracketedAnnotation
        if temporalIs(character, UInt8(ascii: "[")) {
            // We should reject calendar extension case.
            // For BNF, see comment in canBeRFC9557Annotation()
            if canBeRFC9557Annotation(buffer) {
                return false
            }
            return true
        }
        return false
    }

    static func isTZLeadingChar<Unit: TemporalCodeUnit>(_ character: Unit) -> Bool {
        // https://tc39.es/proposal-temporal/#prod-TZLeadingChar
        // TZLeadingChar :::
        //     Alpha
        //     .
        //     _
        temporalIsASCIIAlpha(character) || temporalIs(character, UInt8(ascii: ".")) || temporalIs(character, UInt8(ascii: "_"))
    }

    static func isTZChar<Unit: TemporalCodeUnit>(_ character: Unit) -> Bool {
        // https://tc39.es/proposal-temporal/#prod-TZChar
        // TZChar :::
        //     TZLeadingChar
        //     DecimalDigit
        //     -
        //     +
        isTZLeadingChar(character) || temporalIsASCIIDigit(character) || temporalIs(character, UInt8(ascii: "-"))
            || temporalIs(character, UInt8(ascii: "+"))
    }

    /// Consumes a TimeZoneIANAName and returns its positions in the buffer's characters.
    static func parseTimeZoneIANANamePositions<Unit: TemporalCodeUnit>(_ buffer: inout TemporalCursor<Unit>) -> Range<Int>? {
        // https://tc39.es/proposal-temporal/#prod-TimeZoneIANAName
        // TimeZoneIANAName :::
        //     TimeZoneIANANameComponent
        //     TimeZoneIANAName / TimeZoneIANANameComponent
        // TimeZoneIANANameComponent :::
        //     TZLeadingChar
        //     TimeZoneIANANameComponent TZChar
        //
        //  Both left recursions flatten: '/'-separated components, each a TZLeadingChar then any number
        //  of TZChars. atComponentStart still set at the end means empty or trailing '/'.
        var length = 0
        var atComponentStart = true
        while length < buffer.lengthRemaining {
            let character = buffer[length]
            if temporalIs(character, UInt8(ascii: "/")) {
                if atComponentStart {
                    break
                }
                atComponentStart = true
            } else if atComponentStart ? isTZLeadingChar(character) : isTZChar(character) {
                atComponentStart = false
            } else {
                break
            }
            length += 1
        }
        if atComponentStart {
            return nil
        }
        let start = buffer.position
        buffer.advance(by: length)
        return start..<buffer.position
    }

    /// A `TimeZoneIdentifierParseRecord`, with the name as its positions in the string parsed, or "UTC".
    enum TimeZoneIdentifier {
        case name(Range<Int>)
        case utc
        case offsetMinutes(Int64)
    }

    // https://tc39.es/proposal-temporal/#sec-parsetimezoneidentifier
    static func parseTimeZoneIdentifier<Unit: TemporalCodeUnit>(
        _ buffer: inout TemporalCursor<Unit>
    ) -> TimeZoneIdentifier? {
        // https://tc39.es/proposal-temporal/#prod-TimeZoneIdentifier
        // TimeZoneIdentifier :::
        //     UTCOffset[~SubMinutePrecision]
        //     TimeZoneIANAName
        //
        // Step 1: the two alternatives are the attempts below. They are disjoint, and
        // parseTimeZoneIANAName consumes nothing on failure, so either order gives the same answer.

        // Step 3: If parseResult contains a |TimeZoneIANAName| Parse Node, then
        if let name = parseTimeZoneIANANamePositions(&buffer) {
            // Steps 3.a-3.c: per 3.b's NOTE the name need not be available, so nothing is resolved here.
            return .name(name)
        }

        // Steps 4-6: parseUTCOffset matches |UTCOffset[~SubMinutePrecision]| and converts it in one call.
        let offsetNanoseconds = parseUTCOffset(&buffer, .No)?.nanoseconds

        // Step 2: If parseResult is a List of errors, throw a RangeError exception.
        guard let offsetNanoseconds else {
            return nil
        }

        // Step 7: offsetMinutes = offsetNanoseconds / (60 × 10**9); exact under ~SubMinutePrecision.
        // Step 8: Return the Record with [[Name]] ~empty~.
        return .offsetMinutes(offsetNanoseconds / nsPerMinute)
    }

    static func parseTimeZoneIdentifier<Unit: TemporalCodeUnit>(_ identifier: Span<Unit>) -> TimeZoneIdentifier? {
        var buffer = TemporalCursor(identifier)
        guard let result = parseTimeZoneIdentifier(&buffer), buffer.atEnd else {
            return nil
        }
        return result
    }

    /// A TimeZoneAnnotation: a `Variant<Vector<Latin1Character>, int64_t>`, with the name as its positions in the
    /// string parsed, and `none` for the `std::monostate` that `ISO8601ParseTokens` adds.
    enum TimeZoneAnnotation {
        case none
        case name(Range<Int>)
        case offset(Int64)
    }

    static func parseTimeZoneAnnotation<Unit: TemporalCodeUnit>(_ buffer: inout TemporalCursor<Unit>) -> TimeZoneAnnotation? {
        // https://tc39.es/proposal-temporal/#prod-TimeZoneAnnotation
        // TimeZoneAnnotation :::
        //     [ AnnotationCriticalFlag_opt TimeZoneIdentifier ]

        if buffer.lengthRemaining < 3 {
            return nil
        }

        if !temporalIs(buffer.current, UInt8(ascii: "[")) {
            return nil
        }
        buffer.advance()

        if temporalIs(buffer.current, UInt8(ascii: "!")) {
            buffer.advance()
        }

        // |TimeZoneIdentifier| stops at ']' on its own: ']' is neither a |TZChar| nor part of a
        // |UTCOffset|, so the follow-set check below is all this production adds. Its two
        // alternatives are tried as parseTimeZoneIdentifier tries them.
        let annotation: TimeZoneAnnotation
        if let name = parseTimeZoneIANANamePositions(&buffer) {
            annotation = .name(name)
        } else {
            guard let offsetNanoseconds = parseUTCOffset(&buffer, .No)?.nanoseconds else {
                return nil
            }
            // [[OffsetMinutes]] is minutes; m_nameOrOffset stores the offset in nanoseconds.
            annotation = .offset((offsetNanoseconds / nsPerMinute) * nsPerMinute)
        }

        if buffer.atEnd || !temporalIs(buffer.current, UInt8(ascii: "]")) {
            return nil
        }
        buffer.advance()
        return annotation
    }

    /// `RFC9557Annotation`, with the value as the positions of its characters, empty unless the key is `u-ca`.
    struct RFC9557Annotation {
        var flag: JSC.ISO8601.RFC9557Flag
        var key: JSC.ISO8601.RFC9557Key
        var value: Range<Int>
    }

    static func parseOneRFC9557Annotation<Unit: TemporalCodeUnit>(_ buffer: inout TemporalCursor<Unit>) -> RFC9557Annotation? {
        // For BNF, see comment in canBeRFC9557Annotation()

        if !canBeRFC9557Annotation(buffer) {
            return nil
        }
        let flag: JSC.ISO8601.RFC9557Flag = temporalIs(buffer[1], UInt8(ascii: "!")) ? .Critical : .None
        // Skip '[' or '[!'
        buffer.advance(by: flag == .Critical ? 2 : 1)

        // Parse the key
        var keyLength = 0
        while !temporalIs(buffer[keyLength], UInt8(ascii: "=")) {
            keyLength += 1
        }
        if keyLength == 0 {
            return nil
        }
        let key = buffer.consume(keyLength)

        if buffer.atEnd {
            return nil
        }

        // Consume the '='
        buffer.advance()

        var nameLength = 0
        do {
            var index = 0
            while index < buffer.lengthRemaining {
                let character = buffer[index]
                if temporalIs(character, UInt8(ascii: "]")) {
                    break
                }
                if !temporalIsASCIIAlpha(character) && !temporalIsASCIIDigit(character) && !temporalIs(character, UInt8(ascii: "-")) {
                    return nil
                }
                index += 1
            }
            if index == 0 {
                return nil
            }
            nameLength = index
        }

        // Check if the key is equal to "u-ca"
        if key.count != 4
            || !temporalIs(key[0], UInt8(ascii: "u")) || !temporalIs(key[1], UInt8(ascii: "-"))
            || !temporalIs(key[2], UInt8(ascii: "c")) || !temporalIs(key[3], UInt8(ascii: "a"))
        {
            // Annotation is unknown
            // Consume the rest of the annotation
            buffer.advance(by: nameLength)
            if buffer.atEnd || !temporalIs(buffer.current, UInt8(ascii: "]")) {
                // Parse error
                return nil
            }
            // Consume the ']'
            buffer.advance()
            return RFC9557Annotation(flag: flag, key: .Other, value: 0..<0)
        }

        func isValidComponent(_ start: Int, _ end: Int) -> Bool {
            let componentLength = end - start
            if componentLength < Int(JSC.ISO8601.minCalendarLength) {
                return false
            }
            if componentLength > Int(JSC.ISO8601.maxCalendarLength) {
                return false
            }
            return true
        }

        var currentNameComponentStartIndex = 0
        var isLeadingCharacterInNameComponent = true
        for index in 0..<nameLength {
            let character = buffer[index]
            if isLeadingCharacterInNameComponent {
                if !(temporalIsASCIIAlpha(character) || temporalIsASCIIDigit(character)) {
                    return nil
                }

                currentNameComponentStartIndex = index
                isLeadingCharacterInNameComponent = false
                continue
            }

            if temporalIs(character, UInt8(ascii: "-")) {
                if !isValidComponent(currentNameComponentStartIndex, index) {
                    return nil
                }
                isLeadingCharacterInNameComponent = true
                continue
            }

            if !(temporalIsASCIIAlpha(character) || temporalIsASCIIDigit(character)) {
                return nil
            }
        }
        if isLeadingCharacterInNameComponent {
            return nil
        }
        if !isValidComponent(currentNameComponentStartIndex, nameLength) {
            return nil
        }

        let result = buffer.position..<buffer.position + nameLength
        buffer.advance(by: nameLength)

        if buffer.atEnd {
            return nil
        }
        if !temporalIs(buffer.current, UInt8(ascii: "]")) {
            return nil
        }
        buffer.advance()
        return RFC9557Annotation(flag: flag, key: .Calendar, value: result)
    }

    /// What `parseCalendar`'s `Vector<CalendarID, 1>` is read for: its first element and its size.
    struct Calendars {
        var first: Range<Int>?
        var count: Int
    }

    static func parseCalendar<Unit: TemporalCodeUnit>(_ buffer: inout TemporalCursor<Unit>) -> Calendars? {
        // https://tc39.es/proposal-temporal/#prod-Annotations
        //  Annotations :::
        //      Annotation Annotations[opt]

        if !canBeRFC9557Annotation(buffer) {
            return nil
        }

        var result = Calendars(first: nil, count: 0)
        // https://tc39.es/proposal-temporal/#sec-temporal-parseisodatetime
        var calendarWasCritical = false
        while canBeRFC9557Annotation(buffer) {
            guard let annotation = parseOneRFC9557Annotation(&buffer) else {
                return nil
            }
            if annotation.key == .Calendar {
                if result.count == 0 {
                    result.first = annotation.value
                }
                result.count += 1
            }
            if annotation.flag == .Critical {
                // Check for unknown annotations with critical flag
                // step 4(a)(ii)(2)(d)(i)
                if annotation.key != .Calendar {
                    return nil
                }
                // Check for multiple calendars and critical flag
                // step 4(a)(ii)(2)(c)(ii)
                guard result.count == 1 else {
                    return nil
                }
                calendarWasCritical = true
            }
            if calendarWasCritical && result.count > 1 {
                return nil
            }
        }
        return result
    }

    // Date primitives — strict per-production parsers per spec grammar.
    // https://tc39.es/proposal-temporal/#prod-Date

    @inline(always)
    static func parseDateYear<Unit: TemporalCodeUnit>(_ buffer: inout TemporalCursor<Unit>) -> Int32? {
        if buffer.atEnd {
            return nil
        }
        var extended = false
        var factor: Int32 = 1
        if temporalIs(buffer.current, UInt8(ascii: "+")) {
            buffer.advance()
            extended = true
        } else if temporalIs(buffer.current, UInt8(ascii: "-")) {
            buffer.advance()
            extended = true
            factor = -1
        }
        let digits = extended ? 6 : 4
        // Checks the remaining length before the reads below, which are in bounds by it.
        let rest = buffer.characters.extracting(droppingFirst: buffer.position)
        if rest.count < digits {
            return nil
        }
        let yearDigits = rest.extracting(first: digits)
        for i in yearDigits.indices where !temporalIsASCIIDigit(yearDigits[i]) {
            return nil
        }
        // Cannot overflow: at most 6 digits.
        let year = parseDecimalInt32(yearDigits) &* factor
        // -000000 is not allowed per spec.
        if year == 0 && factor < 0 {
            return nil
        }
        buffer.advance(checkedCount: digits)
        return year
    }

    @inline(always)
    static func parseDateMonth<Unit: TemporalCodeUnit>(_ buffer: inout TemporalCursor<Unit>) -> UInt32? {
        // Checks the remaining length before the reads below, which are in bounds by it.
        let rest = buffer.characters.extracting(droppingFirst: buffer.position)
        if rest.count < 2 {
            return nil
        }
        let c1 = rest[0]
        if !temporalIs(c1, UInt8(ascii: "0")) && !temporalIs(c1, UInt8(ascii: "1")) {
            return nil
        }
        let c2 = rest[1]
        if !temporalIsASCIIDigit(c2) {
            return nil
        }
        let month = UInt32(temporalDigitValue(c2) + 10 * temporalDigitValue(c1))
        if month == 0 || month > 12 {
            return nil
        }
        buffer.advance(checkedCount: 2)
        return month
    }

    @inline(always)
    static func parseDateDay<Unit: TemporalCodeUnit>(_ buffer: inout TemporalCursor<Unit>, _ year: Int32, _ month: UInt32) -> UInt32? {
        // Checks the remaining length before the reads below, which are in bounds by it.
        let rest = buffer.characters.extracting(droppingFirst: buffer.position)
        if rest.count < 2 {
            return nil
        }
        let c1 = rest[0]
        if !temporalIsInASCIIRange(c1, UInt8(ascii: "0"), UInt8(ascii: "3")) {
            return nil
        }
        let c2 = rest[1]
        if !temporalIsASCIIDigit(c2) {
            return nil
        }
        let day = UInt32(temporalDigitValue(c2) + 10 * temporalDigitValue(c1))
        // Every month has at least 28 days.
        if day == 0 || (day > 28 && day > UInt32(TemporalISO8601.daysInMonth(year, UInt8(truncatingIfNeeded: month)))) {
            return nil
        }
        buffer.advance(checkedCount: 2)
        return day
    }

    // Date :::
    //   DateYear DateSeparator[+Extended] DateMonth DateSeparator[+Extended] DateDay   (YYYY-MM-DD)
    //   DateYear DateSeparator[~Extended] DateMonth DateSeparator[~Extended] DateDay   (YYYYMMDD)
    // Both separators must be the SAME mode (extended-with-hyphen or compact-no-hyphen).
    static func parseDate<Unit: TemporalCodeUnit>(_ buffer: inout TemporalCursor<Unit>) -> JSC.ISO8601.PlainDate? {
        guard let year = parseDateYear(&buffer) else {
            return nil
        }
        var extended = false
        if buffer.at(UInt8(ascii: "-")) {
            extended = true
            buffer.advance()
        }
        guard let month = parseDateMonth(&buffer) else {
            return nil
        }
        if extended {
            if !buffer.skip(UInt8(ascii: "-")) {
                return nil
            }
        } else if buffer.at(UInt8(ascii: "-")) {
            // Mixed compact/extended forbidden.
            return nil
        }
        guard let day = parseDateDay(&buffer, year, month) else {
            return nil
        }
        return JSC.ISO8601.PlainDate(year, month, day)
    }

    // DateSpecYearMonth ::: DateYear DateSeparator[?Extended] DateMonth   (YYYY-MM or YYYYMM)
    static func parseDateSpecYearMonth<Unit: TemporalCodeUnit>(_ buffer: inout TemporalCursor<Unit>) -> JSC.ISO8601.PlainDate? {
        guard let year = parseDateYear(&buffer) else {
            return nil
        }
        _ = buffer.skip(UInt8(ascii: "-"))
        guard let month = parseDateMonth(&buffer) else {
            return nil
        }
        return JSC.ISO8601.PlainDate(year, month, UInt32(1))
    }

    // DateSpecMonthDay :::
    //   `--`? DateMonth DateSeparator[+Extended] DateDay   (--MM-DD or MM-DD)
    //   `--`? DateMonth DateSeparator[~Extended] DateDay   (--MMDD or MMDD)
    static func parseDateSpecMonthDay<Unit: TemporalCodeUnit>(_ buffer: inout TemporalCursor<Unit>) -> JSC.ISO8601.PlainDate? {
        if buffer.lengthRemaining >= 2 && temporalIs(buffer[0], UInt8(ascii: "-")) && temporalIs(buffer[1], UInt8(ascii: "-")) {
            buffer.advance(by: 2)
        }
        guard let month = parseDateMonth(&buffer) else {
            return nil
        }
        _ = buffer.skip(UInt8(ascii: "-"))
        // 1972 is the reference year for daysInMonth.
        guard let day = parseDateDay(&buffer, 1972, month) else {
            return nil
        }
        return JSC.ISO8601.PlainDate(Int32(1972), month, day)
    }

    struct ISO8601ParseTokens {
        var year: Int32? // DateYear
        var month: UInt32? // DateMonth
        var day: UInt32? // DateDay
        var time: JSC.ISO8601.PlainTime? // Hour-bearing Time (already CreateTimeRecord'd)
        var hasUTCDesignator = false
        var utcOffsetNs: Int64?
        var offsetHasSubMinutePrecision = false
        var tzAnnotation: TimeZoneAnnotation = .none
        var calendar: Range<Int>? // The positions of the first calendar annotation's value.
        var matchedGoal: JSC.ISO8601.TemporalProduction = .Instant // Set by every tokenizer that returns tokens.
    }

    // Parse `TimeZoneAnnotation? Annotations?`. annotationRequired enforces [+Zoned].
    static func parseTrailingTokens<Unit: TemporalCodeUnit>(
        _ buffer: inout TemporalCursor<Unit>,
        _ tokens: inout ISO8601ParseTokens,
        _ annotationRequired: Bool
    ) -> Bool {
        if buffer.at(UInt8(ascii: "[")) && canBeTimeZone(buffer, buffer.current) {
            guard let annotation = parseTimeZoneAnnotation(&buffer) else {
                return false
            }
            tokens.tzAnnotation = annotation
        } else if annotationRequired {
            return false
        }

        if !buffer.atEnd && canBeRFC9557Annotation(buffer) {
            // Step 4.a.ii.(1)–(2): annotation loop + critical-flag rules.
            guard let calendars = parseCalendar(&buffer) else {
                return false
            }
            if calendars.count > 0 {
                tokens.calendar = calendars.first
            }
        }
        return true
    }

    /// The UTC designator or offset that follows a time.
    ///
    /// Returns false where there is none.
    private static func parseUTCOffsetToken<Unit: TemporalCodeUnit>(
        _ buffer: inout TemporalCursor<Unit>,
        _ tokens: inout ISO8601ParseTokens
    ) -> Bool {
        guard let offset = parseUTCOffset(&buffer, .Yes) else {
            return false
        }
        tokens.utcOffsetNs = offset.nanoseconds
        tokens.offsetHasSubMinutePrecision = offset.hasSubMinutePrecision
        return true
    }

    private static func isDateTimeSeparator<Unit: TemporalCodeUnit>(_ character: Unit) -> Bool {
        temporalIs(character, UInt8(ascii: "T")) || temporalIs(character, UInt8(ascii: "t")) || temporalIs(character, UInt8(ascii: " "))
    }

    // TemporalInstantString :::
    //   Date DateTimeSeparator Time DateTimeUTCOffset[+Z] TimeZoneAnnotation? Annotations?
    // Writes `tokens`, which starts as ISO8601ParseTokens().
    @inline(always)
    static func tokenizeTemporalInstantString<Unit: TemporalCodeUnit>(
        _ buffer: inout TemporalCursor<Unit>,
        _ tokens: inout ISO8601ParseTokens
    ) -> Bool {
        guard let date = parseDate(&buffer) else {
            return false
        }
        tokens.year = date.year()
        tokens.month = UInt32(date.month())
        tokens.day = UInt32(date.day())

        // DateTimeSeparator (required).
        if buffer.atEnd || !isDateTimeSeparator(buffer.current) {
            return false
        }
        buffer.advance()

        var hasSeconds = false
        guard let time = parseTimeSpec(&buffer, .accept, .Yes, &hasSeconds) else {
            return false
        }
        tokens.time = time

        // DateTimeUTCOffset[+Z] (required by grammar): UTCDesignator OR UTCOffset.
        if buffer.atEnd {
            return false
        }
        if temporalIs(buffer.current, UInt8(ascii: "Z")) || temporalIs(buffer.current, UInt8(ascii: "z")) {
            tokens.hasUTCDesignator = true
            buffer.advance()
        } else if temporalIs(buffer.current, UInt8(ascii: "+")) || temporalIs(buffer.current, UInt8(ascii: "-")) {
            if !parseUTCOffsetToken(&buffer, &tokens) {
                return false
            }
        } else {
            return false
        }

        if !parseTrailingTokens(&buffer, &tokens, false) {
            return false
        }
        tokens.matchedGoal = .Instant
        return true
    }

    // TemporalDateTimeString[Zoned] ::: AnnotatedDateTime[?Zoned, ~TimeRequired]
    // AnnotatedDateTime[+Zoned, _] ::: DateTime[+Z, _] TimeZoneAnnotation Annotations?
    // AnnotatedDateTime[~Zoned, _] ::: DateTime[~Z, _] TimeZoneAnnotation? Annotations?
    // DateTime[Z, ~TimeRequired] ::: Date | Date DateTimeSeparator Time DateTimeUTCOffset[?Z]?
    // (timeRequired=true forbids the bare-Date alternative.)
    // Writes `tokens`, which starts as ISO8601ParseTokens().
    static func tokenizeTemporalDateTimeString<Unit: TemporalCodeUnit>(
        _ buffer: inout TemporalCursor<Unit>,
        _ tokens: inout ISO8601ParseTokens,
        zoned: Bool,
        timeRequired: Bool
    ) -> Bool {
        guard let date = parseDate(&buffer) else {
            return false
        }
        tokens.year = date.year()
        tokens.month = UInt32(date.month())
        tokens.day = UInt32(date.day())

        if !buffer.atEnd && isDateTimeSeparator(buffer.current) {
            buffer.advance()
            var hasSeconds = false
            guard let time = parseTimeSpec(&buffer, .accept, .Yes, &hasSeconds) else {
                return false
            }
            tokens.time = time
            if !buffer.atEnd {
                if temporalIs(buffer.current, UInt8(ascii: "Z")) || temporalIs(buffer.current, UInt8(ascii: "z")) {
                    if !zoned { // [~Zoned] forbids Z
                        return false
                    }
                    tokens.hasUTCDesignator = true
                    buffer.advance()
                } else if temporalIs(buffer.current, UInt8(ascii: "+")) || temporalIs(buffer.current, UInt8(ascii: "-")) {
                    if !parseUTCOffsetToken(&buffer, &tokens) {
                        return false
                    }
                }
            }
        } else if timeRequired {
            return false
        }

        if !parseTrailingTokens(&buffer, &tokens, zoned) {
            return false
        }
        tokens.matchedGoal = zoned ? .DateTimeZoned : .DateTimeUnzoned
        return true
    }

    // TemporalYearMonthString ::: AnnotatedYearMonth | AnnotatedDateTime[~Zoned, ~TimeRequired]
    // AnnotatedYearMonth ::: DateSpecYearMonth TimeZoneAnnotation? Annotations?
    // Writes `tokens`, which starts as ISO8601ParseTokens().
    @inline(always)
    static func tokenizeTemporalYearMonthString<Unit: TemporalCodeUnit>(
        _ buffer: inout TemporalCursor<Unit>,
        _ tokens: inout ISO8601ParseTokens
    ) -> Bool {
        let restorePoint = buffer
        if let date = parseDateSpecYearMonth(&buffer) {
            tokens.year = date.year()
            tokens.month = UInt32(date.month())
            // Intentionally leave tokens.day as nullopt — DateSpecYearMonth has no DateDay Parse Node.
            if parseTrailingTokens(&buffer, &tokens, false) && buffer.atEnd {
                tokens.matchedGoal = .YearMonth
                return true
            }
            tokens = ISO8601ParseTokens()
        }
        // Fall back to AnnotatedDateTime[~Zoned, ~TimeRequired].
        buffer = restorePoint
        if !tokenizeTemporalDateTimeString(&buffer, &tokens, zoned: false, timeRequired: false) {
            return false
        }
        tokens.matchedGoal = .YearMonth
        return true
    }

    // TemporalMonthDayString ::: AnnotatedMonthDay | AnnotatedDateTime[~Zoned, ~TimeRequired]
    // AnnotatedMonthDay ::: DateSpecMonthDay TimeZoneAnnotation? Annotations?
    // Writes `tokens`, which starts as ISO8601ParseTokens().
    @inline(always)
    static func tokenizeTemporalMonthDayString<Unit: TemporalCodeUnit>(
        _ buffer: inout TemporalCursor<Unit>,
        _ tokens: inout ISO8601ParseTokens
    ) -> Bool {
        let restorePoint = buffer
        if let date = parseDateSpecMonthDay(&buffer) {
            // Intentionally leave tokens.year as nullopt — DateSpecMonthDay has no DateYear Parse Node.
            tokens.month = UInt32(date.month())
            tokens.day = UInt32(date.day())
            if parseTrailingTokens(&buffer, &tokens, false) && buffer.atEnd {
                tokens.matchedGoal = .MonthDay
                return true
            }
            tokens = ISO8601ParseTokens()
        }
        buffer = restorePoint
        if !tokenizeTemporalDateTimeString(&buffer, &tokens, zoned: false, timeRequired: false) {
            return false
        }
        tokens.matchedGoal = .MonthDay
        return true
    }

    // AnnotatedTime branch of TemporalTimeString:
    //   TimeDesignator? Time DateTimeUTCOffset[~Z]? TimeZoneAnnotation? Annotations?
    // (TemporalTimeString also matches AnnotatedDateTime[~Zoned, +TimeRequired]; tried as fallback.)
    // Writes `tokens`, which starts as ISO8601ParseTokens().
    @inline(always)
    static func tokenizeTemporalAnnotatedTime<Unit: TemporalCodeUnit>(
        _ buffer: inout TemporalCursor<Unit>,
        _ tokens: inout ISO8601ParseTokens
    ) -> Bool {
        if !buffer.atEnd && (temporalIs(buffer.current, UInt8(ascii: "T")) || temporalIs(buffer.current, UInt8(ascii: "t"))) {
            buffer.advance()
        }
        var hasSeconds = false
        guard let time = parseTimeSpec(&buffer, .accept, .Yes, &hasSeconds) else {
            return false
        }

        tokens.time = time

        if !buffer.atEnd {
            if temporalIs(buffer.current, UInt8(ascii: "Z")) || temporalIs(buffer.current, UInt8(ascii: "z")) {
                return false // DateTimeUTCOffset[~Z] forbids Z.
            }
            if temporalIs(buffer.current, UInt8(ascii: "+")) || temporalIs(buffer.current, UInt8(ascii: "-")) {
                if !parseUTCOffsetToken(&buffer, &tokens) {
                    return false
                }
            }
        }
        if !parseTrailingTokens(&buffer, &tokens, false) {
            return false
        }
        tokens.matchedGoal = .Time
        return true
    }

    // AnnotatedTime: Static Semantics: Early Errors
    // https://tc39.es/proposal-temporal/#sec-temporal-iso8601grammar-static-semantics-early-errors
    //
    // AnnotatedTime ::: Time DateTimeUTCOffset[~Z]? TimeZoneAnnotation? Annotations?
    static func isAmbiguousAnnotatedTime<Unit: TemporalCodeUnit>(_ buffer: borrowing TemporalCursor<Unit>) -> Bool {
        if !buffer.hasCharactersRemaining {
            return false
        }

        // The rules attach to the no-TimeDesignator alternative only.
        if temporalIs(temporalToASCIIUpper(buffer.current), UInt8(ascii: "T")) {
            return false
        }

        // Step 1. Extract the substring corresponding to `Time DateTimeUTCOffset[~Z]`: scan to
        // the optional TimeZoneAnnotation `[`. The `[~Z]` parameter forbids `Z`/`z` here, so `[`
        // is the only delimiter that can appear.
        let length = buffer.lengthRemaining
        var prefixLength = 0
        while prefixLength < length && !temporalIs(buffer[prefixLength], UInt8(ascii: "[")) {
            prefixLength += 1
        }
        let prefix = buffer.characters.extracting(buffer.position..<buffer.position + prefixLength)

        // Step 2. ParseText(prefix, DateSpecMonthDay) — Syntax Error if it is a Parse Node.
        do {
            var p = TemporalCursor(prefix)
            if parseDateSpecMonthDay(&p) != nil && p.atEnd {
                return true
            }
        }

        // Step 3. ParseText(prefix, DateSpecYearMonth) — Syntax Error if it is a Parse Node.
        do {
            var p = TemporalCursor(prefix)
            if parseDateSpecYearMonth(&p) != nil && p.atEnd {
                return true
            }
        }

        return false
    }

    /// The tokenizers `parseISODateTime` tries, as its lambdas.
    private enum Goal {
        case instant
        case dateTimeZoned
        case yearMonth
        case monthDay
        case annotatedTime
        case timeAsDateTime
        case dateTimeUnzoned
    }

    /// Tokenizes the whole string as `goal`, writing `tokens`, which starts empty.
    ///
    /// False unless all of it is consumed.
    @inline(always)
    private static func tokenize<Unit: TemporalCodeUnit>(_ string: Span<Unit>, _ goal: Goal, _ tokens: inout ISO8601ParseTokens) -> Bool {
        var buf = TemporalCursor(string)
        let matched: Bool
        switch goal {
        case .instant:
            matched = tokenizeTemporalInstantString(&buf, &tokens)
        case .dateTimeZoned:
            matched = tokenizeTemporalDateTimeString(&buf, &tokens, zoned: true, timeRequired: false)
        case .yearMonth:
            matched = tokenizeTemporalYearMonthString(&buf, &tokens)
        case .monthDay:
            matched = tokenizeTemporalMonthDayString(&buf, &tokens)
        case .annotatedTime:
            matched = tokenizeTemporalAnnotatedTime(&buf, &tokens)
        case .timeAsDateTime:
            matched = tokenizeTemporalDateTimeString(&buf, &tokens, zoned: false, timeRequired: true)
            tokens.matchedGoal = .Time
        case .dateTimeUnzoned:
            matched = tokenizeTemporalDateTimeString(&buf, &tokens, zoned: false, timeRequired: false)
        }
        return matched && buf.atEnd
    }

    /// Whether `string[calendar]` equals `iso8601` ignoring ASCII case, as `equalIgnoringASCIICase(StringView(calendar), "iso8601"_s)`.
    private static func isISO8601Calendar<Unit: TemporalCodeUnit>(_ string: Span<Unit>, _ calendar: Range<Int>) -> Bool {
        let iso8601: [7 of UInt8] = [0x69, 0x73, 0x6F, 0x38, 0x36, 0x30, 0x31] // "iso8601"
        if calendar.count != 7 {
            return false
        }
        for i in 0..<7 {
            let byte = temporalLatin1Character(string[calendar.lowerBound + i]).value
            let lower = byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte | 0x20 : byte
            if lower != iso8601[i] {
                return false
            }
        }
        return true
    }

    /// Steps 1-5 of `parseISODateTime`: whether a goal matched, writing its tokens to `tokens` (which starts as
    /// ISO8601ParseTokens()) and whether the goal was a short form to `isShortForm`.
    @inline(always)
    static func parseISODateTimeTokens<Unit: TemporalCodeUnit>(
        _ string: Span<Unit>,
        _ allowed: UInt8,
        _ tokens: inout ISO8601ParseTokens,
        _ isShortForm: inout Bool
    ) -> Bool {
        func contains(_ production: JSC.ISO8601.TemporalProduction) -> Bool {
            allowed & production.rawValue != 0
        }

        // Step 1. Let parseResult be ~empty~. (`matched` is false; the record is `tokens`.)
        var matched = false

        // Step 2. Let calendar be ~empty~. (Stored in tokens.calendar.)
        // Step 3. Let yearAbsent be false. (Encoded as isShortForm && matchedGoal == MonthDay.)

        // Step 4. For each goal: ParseText (Step 4.a.i) + annotation/short-form rules
        //   (Steps 4.a.ii.(1)-(4)). Goals tried most-specific to least so the matched tag
        //   reflects the narrowest production. Each goal tried starts from an empty record (Step 4.a guard:
        //   none is tried once one has matched), so a failed goal's partial writes do not survive.
        if contains(.Instant) {
            tokens = ISO8601ParseTokens()
            matched = tokenize(string, .instant, &tokens)
        }
        if contains(.DateTimeZoned) && !matched {
            tokens = ISO8601ParseTokens()
            matched = tokenize(string, .dateTimeZoned, &tokens)
        }
        if contains(.YearMonth) && !matched {
            tokens = ISO8601ParseTokens()
            matched = tokenize(string, .yearMonth, &tokens)
        }
        if contains(.MonthDay) && !matched {
            tokens = ISO8601ParseTokens()
            matched = tokenize(string, .monthDay, &tokens)
        }
        if contains(.Time) && !matched {
            // TemporalTimeString = AnnotatedTime | AnnotatedDateTime[~Zoned, +TimeRequired].
            tokens = ISO8601ParseTokens()
            matched = tokenize(string, .annotatedTime, &tokens)
            // AnnotatedTime: Static Semantics: Early Errors
            if matched && isAmbiguousAnnotatedTime(TemporalCursor(string)) {
                matched = false
            }
            if !matched {
                tokens = ISO8601ParseTokens()
                matched = tokenize(string, .timeAsDateTime, &tokens)
            }
        }
        if contains(.DateTimeUnzoned) && !matched {
            tokens = ISO8601ParseTokens()
            matched = tokenize(string, .dateTimeUnzoned, &tokens)
        }

        // Step 4.a.ii.(3): goal=YearMonth and no DateDay -> calendar must be iso8601 or empty.
        // Step 4.a.ii.(4): goal=MonthDay and no DateYear -> calendar must be iso8601 or empty.
        // Both rules: throw RangeError if calendar is non-iso8601 — surfaced as nullopt to the caller.
        // Step 5. If !parseResult, throw RangeError. (Caller wraps with type-specific message.)
        guard matched else {
            return false
        }
        isShortForm = false
        if tokens.matchedGoal == .YearMonth && tokens.day == nil {
            isShortForm = true
        }
        if tokens.matchedGoal == .MonthDay && tokens.year == nil {
            isShortForm = true
        }
        if isShortForm, let calendar = tokens.calendar, !isISO8601Calendar(string, calendar) {
            return false
        }
        return true
    }

    // ParseISODateTime ( isoString, allowedFormats ), steps 1-5: whether the string parses, writing what it read to
    // `out` when it does.
    // https://tc39.es/proposal-temporal/#sec-temporal-parseisodatetime
    //
    // FIXME: temporal_rs uses icu4x/utils/ixdtf (single-pass, ~3000 LoC) instead of
    // per-production tokenizers. ICU4C has no port; revisit if parsing profiles hot.
    @inline(always)
    static func tokenizeISODateTime<Unit: TemporalCodeUnit>(
        _ string: Span<Unit>,
        _ allowed: UInt8,
        _ out: inout JSC.TemporalISODateTimeTokens
    ) -> Bool {
        var parseResult = ISO8601ParseTokens()
        var isShortForm = false
        guard parseISODateTimeTokens(string, allowed, &parseResult, &isShortForm) else {
            return false
        }
        out.hasYear = parseResult.year != nil
        out.year = parseResult.year ?? 0
        out.hasMonth = parseResult.month != nil
        out.month = parseResult.month ?? 0
        out.hasDay = parseResult.day != nil
        out.day = parseResult.day ?? 0
        out.hasTime = parseResult.time != nil
        out.time = parseResult.time ?? JSC.ISO8601.PlainTime()
        out.hasUTCDesignator = parseResult.hasUTCDesignator
        out.hasUTCOffset = parseResult.utcOffsetNs != nil
        out.utcOffset = parseResult.utcOffsetNs ?? 0
        out.offsetHasSubMinutePrecision = parseResult.offsetHasSubMinutePrecision
        out.hasTimeZoneName = false
        out.hasTimeZoneOffset = false
        switch parseResult.tzAnnotation {
        case .none:
            break
        case .name(let positions):
            out.hasTimeZoneName = true
            out.timeZoneNameStart = positions.lowerBound
            out.timeZoneNameEnd = positions.upperBound
        case .offset(let offset):
            out.hasTimeZoneOffset = true
            out.timeZoneOffset = offset
        }
        out.hasCalendar = parseResult.calendar != nil
        if let calendar = parseResult.calendar {
            out.calendarStart = calendar.lowerBound
            out.calendarEnd = calendar.upperBound
        }
        out.matched = parseResult.matchedGoal
        out.isShortForm = isShortForm
        return true
    }

    // ParseISODateTime ( isoString, allowedFormats ), steps 6-29: the record of a string that parsed, from what
    // `tokenizeISODateTime` read from it.
    static func parsedISODateTime<Unit: TemporalCodeUnit>(
        _ string: Span<Unit>,
        _ parseResult: JSC.TemporalISODateTimeTokens
    ) -> JSC.ISO8601.ParsedISODateTime {
        // Every field this does not set stays ~empty~.
        var parsed = JSC.ISO8601.ParsedISODateTime()

        // Step 6. NOTE: short numeric strings — StringToNumber lossless.

        // Step 7. Extract source text per Parse Node (encoded in parseResult fields).

        // Step 8. yearMV = ℝ(StringToNumber(year)).
        let yearMV = parseResult.hasYear ? parseResult.year : 0
        // Steps 9-10. monthMV (default 1).
        let monthMV = parseResult.hasMonth ? parseResult.month : 1
        // Steps 11-12. dayMV (default 1).
        let dayMV = parseResult.hasDay ? parseResult.day : 1
        // Steps 13-20. hour/minute/second/fSeconds — already MV-extracted by parseTimeSpec
        //   (Step 18.b leap-clamp + Steps 19-20 fractional padding folded in there).

        // Step 21. Assert IsValidISODate. parseDate validated the day against the parsed
        // year before clamping out-of-range years to outOfRangeYear (see parseDate); the
        // sentinel year is not necessarily a leap year, so allow it.

        // Steps 22-23. time = ~start-of-day~ if hour absent; else CreateTimeRecord(...).
        if parseResult.hasTime {
            parsed.time.value = parseResult.time
        }

        // Step 24. timeZoneResult = { [[Z]]: false, [[OffsetString]]: ~empty~, [[TimeZoneAnnotation]]: ~empty~ }.
        if parseResult.hasUTCDesignator || parseResult.hasUTCOffset || parseResult.hasTimeZoneName || parseResult.hasTimeZoneOffset {
            var tz = JSC.ISO8601.ISOStringTimeZoneParseRecord()
            // Step 25. Set [[TimeZoneAnnotation]].
            // A name moves into the record, built once.
            if parseResult.hasTimeZoneName {
                var name = temporalLatin1Vector(string, parseResult.timeZoneNameStart..<parseResult.timeZoneNameEnd)
                JSC.temporalMove(&tz.m_nameOrOffset, &name)
            } else if parseResult.hasTimeZoneOffset {
                tz.m_nameOrOffset = .fromAlternative(parseResult.timeZoneOffset)
            } else {
                tz.m_nameOrOffset = .fromAlternative(JSC.TemporalLatin1Vector())
            }
            // Step 26. Set [[Z]].
            tz.m_z = parseResult.hasUTCDesignator
            // Step 27. Set [[OffsetString]].
            if parseResult.hasUTCOffset {
                tz.m_offset.value = parseResult.utcOffset
            }
            tz.m_offsetHasSubMinutePrecision = parseResult.offsetHasSubMinutePrecision
            JSC.temporalMove(&parsed.timeZone, &tz)
        }

        // Step 28. yearReturn = empty if yearAbsent (encoded via isShortForm + matchedGoal == MonthDay).

        // Step 29. Return ISO Date-Time Parse Record.
        let dateBearingGoal = parseResult.matched != .Time || parseResult.hasMonth
        if dateBearingGoal {
            parsed.date.value = JSC.ISO8601.PlainDate(yearMV, monthMV, dayMV)
        }
        if parseResult.hasCalendar {
            let source = string.extracting(parseResult.calendarStart..<parseResult.calendarEnd)
            var value = JSC.ISO8601.CalendarID(source.count)
            for i in source.indices {
                value[i] = temporalLatin1Character(source[i])
            }
            JSC.temporalMove(&parsed.calendar, &value)
        }
        parsed.matched = parseResult.matched
        parsed.isShortForm = parseResult.isShortForm
        return parsed
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-parsetemporaltimezonestring
    static func parseTemporalTimeZoneString<Unit: TemporalCodeUnit>(_ string: Span<Unit>) -> TimeZoneIdentifier? {
        // 1. Let parseResult be ParseText(StringToCodePoints(timeZoneString), TimeZoneIdentifier).
        // 2. If parseResult is a Parse Node, return ! ParseTimeZoneIdentifier(timeZoneString).
        if let parse = parseTimeZoneIdentifier(string) {
            return parse
        }

        // 3. Let result be ? ParseISODateTime(timeZoneString,
        //      « TemporalDateTimeString[+Zoned], TemporalDateTimeString[~Zoned], TemporalInstantString,
        //        TemporalTimeString, TemporalMonthDayString, TemporalYearMonthString »).
        let productions: [6 of JSC.ISO8601.TemporalProduction] = [.DateTimeZoned, .DateTimeUnzoned, .Instant, .Time, .MonthDay, .YearMonth]
        var allowed: UInt8 = 0
        for i in productions.indices {
            allowed |= productions[i].rawValue
        }
        var tz = ISO8601ParseTokens()
        var isShortForm = false
        guard parseISODateTimeTokens(string, allowed, &tz, &isShortForm) else {
            return nil
        }
        // parsed->timeZone is present when the tokens carry any time zone information.
        guard tz.hasUTCDesignator || tz.utcOffsetNs != nil || !tz.tzAnnotation.isNone else {
            return nil
        }

        // 4. Let timeZoneResult be result.[[TimeZone]].
        // 5. If timeZoneResult.[[TimeZoneAnnotation]] is not ~empty~, return ! ParseTimeZoneIdentifier(timeZoneResult.[[TimeZoneAnnotation]]).
        switch tz.tzAnnotation {
        case .offset(let offsetNanoseconds):
            return .offsetMinutes(offsetNanoseconds / nsPerMinute)
        case .name(let annotationName):
            if !annotationName.isEmpty {
                return .name(annotationName)
            }
        case .none:
            break
        }

        // 6. If timeZoneResult.[[Z]] is true, return ! ParseTimeZoneIdentifier("UTC").
        if tz.hasUTCDesignator {
            return .utc
        }

        // 7. If timeZoneResult.[[OffsetString]] is not ~empty~, return ? ParseTimeZoneIdentifier(timeZoneResult.[[OffsetString]]).
        if let offset = tz.utcOffsetNs {
            if tz.offsetHasSubMinutePrecision {
                return nil
            }
            return .offsetMinutes(offset / nsPerMinute)
        }

        // 8. Throw a RangeError exception.
        return nil
    }
}

extension TemporalISO8601.TimeZoneAnnotation {
    var isNone: Bool {
        if case .none = self {
            return true
        }
        return false
    }
}

// MARK: - Functions the C++ calls

// Exclusivity of their parameters: see TemporalSupport.swift.

/// `ISO8601::parseDuration` for an 8-bit string.
///
/// `string` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every byte is a valid `Latin1Character`.
@_expose(Cxx)
func temporalParseDuration8(_ string: JSC.TemporalLatin1Span, _ duration: inout JSC.ISO8601.Duration) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(string))
    return temporalStore(TemporalISO8601.parseDuration(characters), &duration)
}

/// `ISO8601::parseDuration` for a 16-bit string.
///
/// `string` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every value is a valid `char16_t`.
@_expose(Cxx)
func temporalParseDuration16(_ string: JSC.TemporalUTF16Span, _ duration: inout JSC.ISO8601.Duration) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: string)
    return temporalStore(TemporalISO8601.parseDuration(characters), &duration)
}

/// `ISO8601::parseUTCOffset` for an 8-bit string.
///
/// `string` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every byte is a valid `Latin1Character`.
@_expose(Cxx)
func temporalParseUTCOffset8(
    _ string: JSC.TemporalLatin1Span,
    _ subMinutePrecision: JSC.ISO8601.SubMinutePrecision,
    _ offset: inout Int64
) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(string))
    return temporalStore(TemporalISO8601.parseUTCOffset(characters, subMinutePrecision), &offset)
}

/// `ISO8601::parseUTCOffset` for a 16-bit string.
///
/// `string` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every value is a valid `char16_t`.
@_expose(Cxx)
func temporalParseUTCOffset16(
    _ string: JSC.TemporalUTF16Span,
    _ subMinutePrecision: JSC.ISO8601.SubMinutePrecision,
    _ offset: inout Int64
) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: string)
    return temporalStore(TemporalISO8601.parseUTCOffset(characters, subMinutePrecision), &offset)
}

/// `ISO8601::parseUTCOffsetInMinutes` for an 8-bit string.
///
/// `string` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every byte is a valid `Latin1Character`.
@_expose(Cxx)
func temporalParseUTCOffsetInMinutes8(_ string: JSC.TemporalLatin1Span, _ offset: inout Int64) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(string))
    return temporalStore(TemporalISO8601.parseUTCOffsetInMinutes(characters), &offset)
}

/// `ISO8601::parseUTCOffsetInMinutes` for a 16-bit string.
///
/// `string` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every value is a valid `char16_t`.
@_expose(Cxx)
func temporalParseUTCOffsetInMinutes16(_ string: JSC.TemporalUTF16Span, _ offset: inout Int64) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: string)
    return temporalStore(TemporalISO8601.parseUTCOffsetInMinutes(characters), &offset)
}

/// The `std::optional<TimeZoneIdentifierParseRecord>` that `identifier` gives, its name built once from `characters`.
private func temporalTimeZoneIdentifierRecord<Unit: TemporalCodeUnit>(
    _ characters: Span<Unit>,
    _ identifier: TemporalISO8601.TimeZoneIdentifier?
) -> JSC.TemporalOptionalTimeZoneIdentifierParseRecord {
    var record = JSC.TemporalOptionalTimeZoneIdentifierParseRecord()
    switch identifier {
    case .name(let positions):
        var name = temporalLatin1Vector(characters, positions)
        var value = JSC.ISO8601.TimeZoneIdentifierParseRecord()
        JSC.temporalMove(&value.name, &name)
        JSC.temporalMove(&record, &value)
    case .utc:
        var name = JSC.TemporalLatin1Vector()
        name.append(consuming: temporalLatin1Character(UInt8(ascii: "U")))
        name.append(consuming: temporalLatin1Character(UInt8(ascii: "T")))
        name.append(consuming: temporalLatin1Character(UInt8(ascii: "C")))
        var value = JSC.ISO8601.TimeZoneIdentifierParseRecord()
        JSC.temporalMove(&value.name, &name)
        JSC.temporalMove(&record, &value)
    case .offsetMinutes(let offsetMinutes):
        var value = JSC.ISO8601.TimeZoneIdentifierParseRecord()
        value.offsetMinutes.value = offsetMinutes
        record.value = value
    case nil:
        break
    }
    return record
}

/// `ISO8601::parseTimeZoneIdentifier` for an 8-bit string.
///
/// `identifier` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every byte is a valid `Latin1Character`.
/// The record is returned by value.
@_expose(Cxx)
func temporalParseTimeZoneIdentifier8(_ identifier: JSC.TemporalLatin1Span) -> JSC.TemporalOptionalTimeZoneIdentifierParseRecord {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(identifier))
    return temporalTimeZoneIdentifierRecord(characters, TemporalISO8601.parseTimeZoneIdentifier(characters))
}

/// `ISO8601::parseTimeZoneIdentifier` for a 16-bit string.
///
/// `identifier` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every value is a valid `char16_t`.
/// The record is returned by value.
@_expose(Cxx)
func temporalParseTimeZoneIdentifier16(_ identifier: JSC.TemporalUTF16Span) -> JSC.TemporalOptionalTimeZoneIdentifierParseRecord {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: identifier)
    return temporalTimeZoneIdentifierRecord(characters, TemporalISO8601.parseTimeZoneIdentifier(characters))
}

/// Whether `ISO8601::parseISODateTime` accepts an 8-bit string, writing what it read to `tokens` when it does.
///
/// `allowed` is the `TemporalProductionSet`'s `toRaw()`.
///
/// `string` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every byte is a valid `Latin1Character`.
@_expose(Cxx)
func temporalParseISODateTimeTokens8(
    _ string: JSC.TemporalLatin1Span,
    _ allowed: UInt8,
    _ tokens: inout JSC.TemporalISODateTimeTokens
) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(string))
    return TemporalISO8601.tokenizeISODateTime(characters, allowed, &tokens)
}

/// Whether `ISO8601::parseISODateTime` accepts a 16-bit string, writing what it read to `tokens` when it does.
///
/// `allowed` is the `TemporalProductionSet`'s `toRaw()`.
///
/// `string` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every value is a valid `char16_t`.
@_expose(Cxx)
func temporalParseISODateTimeTokens16(
    _ string: JSC.TemporalUTF16Span,
    _ allowed: UInt8,
    _ tokens: inout JSC.TemporalISODateTimeTokens
) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: string)
    return TemporalISO8601.tokenizeISODateTime(characters, allowed, &tokens)
}

/// `ISO8601::parseISODateTime`'s record of an 8-bit string it accepts, from the tokens that
/// `temporalParseISODateTimeTokens8` wrote.
///
/// A position out of the string's bounds traps.
///
/// `string` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every byte is a valid `Latin1Character`.
/// The record is returned by value, built once in the caller's storage.
@_expose(Cxx)
func temporalParsedISODateTime8(
    _ string: JSC.TemporalLatin1Span,
    _ tokens: JSC.TemporalISODateTimeTokens
) -> JSC.ISO8601.ParsedISODateTime {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(string))
    return TemporalISO8601.parsedISODateTime(characters, tokens)
}

/// `ISO8601::parseISODateTime`'s record of a 16-bit string it accepts, from the tokens that
/// `temporalParseISODateTimeTokens16` wrote.
///
/// A position out of the string's bounds traps.
///
/// `string` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every value is a valid `char16_t`.
/// The record is returned by value, built once in the caller's storage.
@_expose(Cxx)
func temporalParsedISODateTime16(
    _ string: JSC.TemporalUTF16Span,
    _ tokens: JSC.TemporalISODateTimeTokens
) -> JSC.ISO8601.ParsedISODateTime {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: string)
    return TemporalISO8601.parsedISODateTime(characters, tokens)
}

/// `ISO8601::parseTemporalTimeZoneString` for an 8-bit string.
///
/// `string` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every byte is a valid `Latin1Character`.
/// The record is returned by value.
@_expose(Cxx)
func temporalParseTemporalTimeZoneString8(_ string: JSC.TemporalLatin1Span) -> JSC.TemporalOptionalTimeZoneIdentifierParseRecord {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(string))
    return temporalTimeZoneIdentifierRecord(characters, TemporalISO8601.parseTemporalTimeZoneString(characters))
}

/// `ISO8601::parseTemporalTimeZoneString` for a 16-bit string.
///
/// `string` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every value is a valid `char16_t`.
/// The record is returned by value.
@_expose(Cxx)
func temporalParseTemporalTimeZoneString16(_ string: JSC.TemporalUTF16Span) -> JSC.TemporalOptionalTimeZoneIdentifierParseRecord {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: string)
    return temporalTimeZoneIdentifierRecord(characters, TemporalISO8601.parseTemporalTimeZoneString(characters))
}
