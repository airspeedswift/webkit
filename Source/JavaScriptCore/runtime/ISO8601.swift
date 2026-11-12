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

// MARK: - Calendar math

extension TemporalISO8601 {
    static func dayOfWeek(_ plainDate: JSC.ISO8601.PlainDate) -> UInt8 {
        // Cannot overflow: a PlainDate's year has 21 bits, so the day count is within ±1e9.
        let days = WTF.daysFromYearMonth(plainDate.year(), Int32(plainDate.month()) - 1) &+ (Int32(plainDate.day()) - 1)
        let weekDay = WTF.weekDay(days)
        return UInt8(truncatingIfNeeded: weekDay == 0 ? 7 : weekDay)
    }

    static func dayOfYear(_ plainDate: JSC.ISO8601.PlainDate) -> UInt16 {
        // Always start with 1 (1/1 is 1). Cannot overflow: dayInYear is at most 366 plus a 6-bit day.
        UInt16(truncatingIfNeeded: WTF.dayInYear(plainDate.year(), Int32(plainDate.month()) - 1, Int32(plainDate.day())) &+ 1)
    }

    static func weekOfYear(_ plainDate: JSC.ISO8601.PlainDate) -> UInt8 {
        let dayOfYear = Int32(TemporalISO8601.dayOfYear(plainDate))
        let dayOfWeek = Int32(TemporalISO8601.dayOfWeek(plainDate))

        // ISO week 1 is the week containing the first Thursday (4) of the year.
        // https://en.wikipedia.org/wiki/ISO_week_date#Algorithms
        let week = (dayOfYear - dayOfWeek + 10) / 7
        if week <= 0 {
            // Previous year's last week. Thus, 52 or 53 weeks. Getting weeks in the previous year.
            //
            // https://en.wikipedia.org/wiki/ISO_week_date#Weeks_per_year
            // > The long years, with 53 weeks in them, can be described by any of the following equivalent definitions:
            // >  - any year ending on Thursday (D, ED) and any leap year ending on Friday (DC)

            let dayOfWeekForJanuaryFirst = TemporalISO8601.dayOfWeek(JSC.ISO8601.PlainDate(plainDate.year(), 1, 1))

            // Any year ending on Thursday (D, ED) -> this year's 1/1 is Friday.
            if dayOfWeekForJanuaryFirst == 5 {
                return 53
            }

            // Any leap year ending on Friday (DC) -> this year's 1/1 is Saturday and previous year is a leap year.
            if dayOfWeekForJanuaryFirst == 6 && WTF.isLeapYear(plainDate.year() - 1) {
                return 53
            }

            return 52
        }

        if week == 53 {
            // Check whether this is in next year's week 1.
            if (WTF.daysInYear(plainDate.year()) - dayOfYear) < (4 - dayOfWeek) {
                return 1
            }
        }

        return UInt8(truncatingIfNeeded: week)
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-isoweekofyear
    // Returns the [[Year]] field of ISOWeekOfYear — the ISO week-calendar year.
    static func yearOfWeek(_ plainDate: JSC.ISO8601.PlainDate) -> Int32 {
        let dayOfYear = Int32(TemporalISO8601.dayOfYear(plainDate))
        let dayOfWeek = Int32(TemporalISO8601.dayOfWeek(plainDate))

        let week = (dayOfYear - dayOfWeek + 10) / 7
        if week < 1 {
            return plainDate.year() - 1
        }

        if week == 53 {
            if (WTF.daysInYear(plainDate.year()) - dayOfYear) < (4 - dayOfWeek) {
                return plainDate.year() + 1
            }
        }

        return plainDate.year()
    }

    private static let daysInMonths: [2 of [12 of UInt8]] = [
        [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31],
        [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31],
    ]

    // https://tc39.es/proposal-temporal/#sec-temporal-isodaysinmonth
    // A month outside 1-12 traps.
    @inline(always)
    static func daysInMonth(_ year: Int32, _ month: UInt8) -> UInt8 {
        daysInMonths[WTF.isLeapYear(year) ? 1 : 0][Int(month) - 1]
    }

    @inline(always)
    static func daysInMonth(_ month: UInt8) -> UInt8 {
        daysInMonths[1][Int(month) - 1]
    }
}

// MARK: - Formatting

/// The characters of `numberToStringUnsigned<Vector<Latin1Character, 9>>(number)` for an `int64_t`: each digit is
/// `static_cast<unsigned>(number % 10) + '0'` truncated to a byte.
///
/// A negative number, which only `formatTimeZoneOffsetString(INT64_MIN)` reaches, gives those non-digit bytes. At most
/// 19.
struct TemporalDecimalDigits {
    private(set) var bytes: [20 of UInt8]
    private(set) var count: Int

    init(_ number: Int64) {
        bytes = .init(repeating: 0)
        var reversed: [20 of UInt8] = .init(repeating: 0)
        var length = 0
        var number = number
        repeat {
            reversed[length] = UInt8(truncatingIfNeeded: UInt32(truncatingIfNeeded: number % 10) &+ 48)
            length += 1
            number /= 10
        } while number != 0
        count = length
        for index in 0..<length {
            bytes[index] = reversed[length - 1 - index]
        }
    }

    /// Removes trailing `0`s.
    mutating func removeTrailingZeros() {
        while count > 0 && bytes[count - 1] == UInt8(ascii: "0") {
            count -= 1
        }
    }

    /// Sets the length, appending `0`s when it grows.
    mutating func resize(_ length: Int) {
        var index = count
        while index < length {
            bytes[index] = UInt8(ascii: "0")
            index += 1
        }
        count = length
    }
}

extension TemporalStringBuilder {
    mutating func append(_ digits: borrowing TemporalDecimalDigits) {
        for index in 0..<digits.count {
            append(digits.bytes[index])
        }
    }

    /// `pad('0', length, emptyString())`.
    mutating func appendZeros(_ length: UInt32) {
        var remaining = length
        while remaining > 0 {
            append(UInt8(ascii: "0"))
            remaining -= 1
        }
    }

    /// `'.', pad('0', paddingLength, emptyString()), fraction`, for a fraction with its trailing zeros removed
    /// (the Auto precision of `temporalTimeToString` and `formatTimeZoneOffsetString`).
    ///
    /// More than 9 digits only come from a `PlainTime` with fields over 999, and trap.
    mutating func appendTrimmedFraction(_ nanoseconds: Int64) {
        var fraction = TemporalDecimalDigits(nanoseconds)
        precondition(fraction.count <= 9, "makeString overflow")
        let paddingLength = UInt32(9 - fraction.count)
        fraction.removeTrailingZeros()
        append(UInt8(ascii: "."))
        appendZeros(paddingLength)
        append(fraction)
    }
}

extension TemporalISO8601 {
    // https://tc39.es/proposal-temporal/#sec-temporal-formattimezoneoffsetstring
    // At most 30 characters (INT64_MIN: 8 hour characters).
    static func formatTimeZoneOffsetString(_ offset: Int64) -> WTF.String {
        var offset = offset
        var negative = false
        if offset < 0 {
            negative = true
            // The offset range is much narrower than int64_t's. INT64_MIN wraps to itself.
            offset = 0 &- offset
        }
        let nanoseconds = offset % nsPerSecond
        let seconds = (offset / nsPerSecond) % 60
        let minutes = (offset / nsPerMinute) % 60
        let hours = offset / nsPerHour

        var string = TemporalStringBuilder()
        string.append(negative ? UInt8(ascii: "-") : UInt8(ascii: "+"))
        string.append(decimal: hours, paddedTo: 2)
        string.append(UInt8(ascii: ":"))
        string.append(decimal: minutes, paddedTo: 2)
        if nanoseconds != 0 {
            string.append(UInt8(ascii: ":"))
            string.append(decimal: seconds, paddedTo: 2)
            string.appendTrimmedFraction(nanoseconds)
        } else if seconds != 0 {
            string.append(UInt8(ascii: ":"))
            string.append(decimal: seconds, paddedTo: 2)
        }
        return string.makeString()
    }

    /// Appends `temporalTimeToString(plainTime, precision)`: at most 18 characters while `precisionValue` < 10,
    /// which callers assert.
    static func appendTime(
        _ string: inout TemporalStringBuilder,
        _ plainTime: JSC.ISO8601.PlainTime,
        _ precisionType: JSC.Precision,
        _ precisionValue: UInt32
    ) {
        string.append(decimal: plainTime.hour(), paddedTo: 2)
        string.append(UInt8(ascii: ":"))
        string.append(decimal: plainTime.minute(), paddedTo: 2)
        if precisionType == .Minute {
            return
        }

        let milliseconds = Int64(plainTime.millisecond())
        let microseconds = Int64(plainTime.microsecond())
        let nanoseconds = Int64(plainTime.nanosecond())
        let fractionNanoseconds = milliseconds * nsPerMillisecond + microseconds * nsPerMicrosecond + nanoseconds
        string.append(UInt8(ascii: ":"))
        string.append(decimal: plainTime.second(), paddedTo: 2)
        if precisionType == .Auto {
            if fractionNanoseconds != 0 {
                string.appendTrimmedFraction(fractionNanoseconds)
            }
            return
        }
        if precisionValue == 0 {
            return
        }
        var fraction = TemporalDecimalDigits(fractionNanoseconds)
        // Unsigned: a 10-digit fraction (fields over 999) wraps, and the minimum is then precisionValue.
        let paddingLength = min(UInt32(9) &- UInt32(fraction.count), precisionValue)
        // A resize past 9 digits needs precisionValue >= 10, which callers assert against: this writes zeros there
        // and traps past 20.
        fraction.resize(Int(precisionValue - paddingLength))
        string.append(UInt8(ascii: "."))
        string.appendZeros(paddingLength)
        string.append(fraction)
    }

    static func temporalTimeToString(
        _ plainTime: JSC.ISO8601.PlainTime,
        _ precisionType: JSC.Precision,
        _ precisionValue: UInt32
    ) -> WTF.String {
        assert(precisionType == .Auto || precisionValue < 10)
        var string = TemporalStringBuilder()
        appendTime(&string, plainTime, precisionType, precisionValue)
        return string.makeString()
    }

    /// Appends `temporalDateToString(year, month)`: at most 15 characters.
    static func appendDate(_ string: inout TemporalStringBuilder, _ year: Int32, _ month: Int32) {
        // If we're printing a date, it should be within range
        assert(JSC.ISO8601.isYearWithinLimits(year))

        var year = year
        var yearDigits = 4
        if year < 0 || year > 9999 {
            string.append(year < 0 ? UInt8(ascii: "-") : UInt8(ascii: "+"))
            yearDigits = 6
            // std::abs. INT32_MIN wraps to itself; a PlainDate's 21-bit year never reaches it.
            year = year < 0 ? 0 &- year : year
        }

        string.append(decimal: year, paddedTo: yearDigits)
        string.append(UInt8(ascii: "-"))
        string.append(decimal: month, paddedTo: 2)
    }

    /// Appends `temporalDateToString(year, month, day)`: at most 18 characters.
    static func appendDate(_ string: inout TemporalStringBuilder, _ year: Int32, _ month: Int32, _ day: Int32) {
        appendDate(&string, year, month)
        string.append(UInt8(ascii: "-"))
        string.append(decimal: day, paddedTo: 2)
    }

    static func appendDate(_ string: inout TemporalStringBuilder, _ plainDate: JSC.ISO8601.PlainDate) {
        appendDate(&string, plainDate.year(), Int32(plainDate.month()), Int32(plainDate.day()))
    }

    /// At most 37 characters.
    static func temporalDateTimeToString(
        _ plainDate: JSC.ISO8601.PlainDate,
        _ plainTime: JSC.ISO8601.PlainTime,
        _ precisionType: JSC.Precision,
        _ precisionValue: UInt32
    ) -> WTF.String {
        var string = TemporalStringBuilder()
        appendDate(&string, plainDate)
        string.append(UInt8(ascii: "T"))
        assert(precisionType == .Auto || precisionValue < 10)
        appendTime(&string, plainTime, precisionType, precisionValue)
        return string.makeString()
    }

    static func temporalDateToString(_ plainDate: JSC.ISO8601.PlainDate) -> WTF.String {
        var string = TemporalStringBuilder()
        appendDate(&string, plainDate)
        return string.makeString()
    }

    /// Appends `"[u-ca="_s, calId, ']'`, or `"[!u-ca="_s` when critical.
    ///
    /// Calendar identifiers are 8-bit literals (`intlAvailableCalendars`) of at most 16 characters.
    private static func appendCalendarAnnotation(_ string: inout TemporalStringBuilder, _ calId: borrowing WTF.String, critical: Bool) {
        string.append(ascii: critical ? "[!u-ca=" : "[u-ca=")
        string.append(characters: calId.span8())
        string.append(UInt8(ascii: "]"))
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-temporalyearmonthtostring
    // `isoPlainDate` is the PlainYearMonth's isoPlainDate(), whose year() and month() it forwards.
    // At most 18 + 25 characters.
    static func temporalYearMonthToString<Unit: TemporalCodeUnit>(
        _ isoPlainDate: JSC.ISO8601.PlainDate,
        _ calendarName: Span<Unit>,
        _ calendarId: UInt32
    ) -> WTF.String {
        let calId = JSC.TemporalCore.temporalCalendarIDString(calendarId)
        let isNonISO = calendarId != JSC.iso8601CalendarID()
        var string = TemporalStringBuilder()
        if temporalEquals(calendarName, ascii: "never") {
            if isNonISO {
                appendDate(&string, isoPlainDate)
            } else {
                appendDate(&string, isoPlainDate.year(), Int32(isoPlainDate.month()))
            }
        } else if temporalEquals(calendarName, ascii: "always") {
            appendDate(&string, isoPlainDate)
            appendCalendarAnnotation(&string, calId, critical: false)
        } else if temporalEquals(calendarName, ascii: "critical") {
            appendDate(&string, isoPlainDate)
            appendCalendarAnnotation(&string, calId, critical: true)
        } else if isNonISO {
            appendDate(&string, isoPlainDate)
            appendCalendarAnnotation(&string, calId, critical: false)
        } else {
            appendDate(&string, isoPlainDate.year(), Int32(isoPlainDate.month()))
        }
        return string.makeString()
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-temporalmonthdaytostring
    // `isoPlainDate` is the PlainMonthDay's isoPlainDate(), whose month() and day() it forwards.
    // At most 18 + 25 characters.
    static func temporalMonthDayToString<Unit: TemporalCodeUnit>(
        _ isoPlainDate: JSC.ISO8601.PlainDate,
        _ calendarName: Span<Unit>,
        _ calendarId: UInt32
    ) -> WTF.String {
        let calId = JSC.TemporalCore.temporalCalendarIDString(calendarId)
        let isNonISO = calendarId != JSC.iso8601CalendarID()
        var string = TemporalStringBuilder()
        if temporalEquals(calendarName, ascii: "never") {
            if isNonISO {
                appendDate(&string, isoPlainDate)
            } else {
                appendMonthDay(&string, isoPlainDate)
            }
        } else if temporalEquals(calendarName, ascii: "always") {
            appendDate(&string, isoPlainDate)
            appendCalendarAnnotation(&string, calId, critical: false)
        } else if temporalEquals(calendarName, ascii: "critical") {
            appendDate(&string, isoPlainDate)
            appendCalendarAnnotation(&string, calId, critical: true)
        } else if isNonISO {
            appendDate(&string, isoPlainDate)
            appendCalendarAnnotation(&string, calId, critical: false)
        } else {
            appendMonthDay(&string, isoPlainDate)
        }
        return string.makeString()
    }

    /// `pad('0', 2, month), '-', pad('0', 2, day)`: at most 13 characters.
    private static func appendMonthDay(_ string: inout TemporalStringBuilder, _ isoPlainDate: JSC.ISO8601.PlainDate) {
        string.append(decimal: isoPlainDate.month(), paddedTo: 2)
        string.append(UInt8(ascii: "-"))
        string.append(decimal: isoPlainDate.day(), paddedTo: 2)
    }
}

// MARK: - Month codes

extension TemporalISO8601 {
    /// `monthCode(uint32_t)`: `M` and the month, zero-padded to two digits.
    ///
    /// At most 11 characters.
    static func monthCode(_ month: UInt32) -> WTF.String {
        var string = TemporalStringBuilder()
        string.append(UInt8(ascii: "M"))
        string.append(decimal: month, paddedTo: 2)
        return string.makeString()
    }

    // Parses the MonthCode grammar from https://tc39.es/proposal-temporal/#sec-temporal-parsemonthcode:
    //   MonthCode :::
    //       M00L
    //       M0 NonZeroDigit L?
    //       M NonZeroDigit DecimalDigit L?
    static func parseMonthCode<Unit: TemporalCodeUnit>(_ monthCode: Span<Unit>) -> JSC.ParsedMonthCode? {
        let length = monthCode.count
        if length < 3 || length > 4
            || !temporalIs(monthCode[0], UInt8(ascii: "M"))
            || !temporalIsASCIIDigit(monthCode[1]) || !temporalIsASCIIDigit(monthCode[2])
        {
            return nil
        }
        if length == 4 && !temporalIs(monthCode[3], UInt8(ascii: "L")) {
            return nil
        }
        // M00 is only valid as M00L — bare `M00` matches none of the three grammar alternatives.
        if temporalIs(monthCode[1], UInt8(ascii: "0")) && temporalIs(monthCode[2], UInt8(ascii: "0")) && length == 3 {
            return nil
        }

        let isLeapMonth = length == 4
        let monthNumber = UInt8(truncatingIfNeeded: temporalDigitValue(monthCode[1]) * 10 + temporalDigitValue(monthCode[2]))
        return JSC.ParsedMonthCode(monthNumber: monthNumber, isLeapMonth: isLeapMonth)
    }

    /// `parseMonthCode` on a `String`'s characters.
    ///
    /// A month code is at most 4 characters, so the 8-bit characters are copied into a fixed buffer of code units.
    static func parseMonthCode(_ monthCode: borrowing WTF.String) -> JSC.ParsedMonthCode? {
        if !monthCode.is8Bit() {
            let characters: Span<UInt16> = monthCode.span16()
            return parseMonthCode(characters)
        }
        let characters: Span<WTF.Latin1Character> = monthCode.span8()
        guard characters.count <= 4 else {
            return nil
        }
        var units: [4 of UInt8] = .init(repeating: 0)
        for index in characters.indices {
            units[index] = characters[index].value
        }
        return parseMonthCode(units.span.extracting(0..<characters.count))
    }
}

// MARK: - ExactTime, Duration, InternalDuration

extension TemporalISO8601 {
    /// `ExactTime::fromISOPartsAndOffset`.
    static func exactTimeFromISOPartsAndOffset(
        _ year: Int32,
        _ month: UInt8,
        _ day: UInt8,
        _ hour: UInt32,
        _ minute: UInt32,
        _ second: UInt32,
        _ millisecond: UInt32,
        _ microsecond: UInt32,
        _ nanosecond: UInt32,
        _ offset: Int64
    ) -> JSC.ISO8601.ExactTime {
        assert(month >= 1 && month <= 12)
        assert(day >= 1 && day <= 31)
        assert(hour <= 23)
        assert(minute <= 59)
        assert(second <= 59)
        assert(millisecond <= 999)
        assert(microsecond <= 999)
        assert(nanosecond <= 999)

        typealias ExactTime = JSC.ISO8601.ExactTime
        // An integral day count of at most about 8e11 in magnitude for any int32_t year: the conversion is exact,
        // and in Int64's range.
        let dateDays = Int128(Int64(WTF.dateToDaysFrom1970(year, Int32(month) - 1, Int32(day))))
        let utcNanoseconds =
            dateDays * TemporalExactTime.nsPerDay + Int128(hour) * TemporalExactTime.nsPerHour + Int128(minute)
            * TemporalExactTime.nsPerMinute
            + Int128(second) * TemporalExactTime.nsPerSecond + Int128(millisecond) * TemporalExactTime.nsPerMillisecond
            + Int128(microsecond) * TemporalExactTime.nsPerMicrosecond + Int128(nanosecond)
        return ExactTime(utcNanoseconds &- Int128(offset))
    }

    /// `checkedCastDoubleToInt128(Double(n))`: n itself where its conversion to a double is exact.
    @inline(always)
    static func checkedCastDoubleToInt128(converting n: Int64) -> Int128? {
        if n.magnitude <= 1 << 53 {
            return Int128(n)
        }
        return checkedCastDoubleToInt128(Double(n))
    }

    /// `checkedCastDoubleToInt128(temporalDouble(n))`: n itself where its conversion to a double is exact.
    @inline(always)
    static func checkedCastDoubleToInt128(converting n: Int128) -> Int128? {
        if n.magnitude <= 1 << 53 {
            return n
        }
        return checkedCastDoubleToInt128(temporalDouble(n))
    }

    /// `JSC::checkedCastDoubleToInt128`: nil where it returns an overflowed `CheckedInt128`.
    static func checkedCastDoubleToInt128(_ n: Double) -> Int128? {
        // Based on __fixdfti() and __fixunsdfti() from compiler_rt:
        // https://github.com/llvm/llvm-project/blob/f3671de5500ff1f8210419226a9603a7d83b1a31/compiler-rt/lib/builtins/fp_fixint_impl.inc
        // https://github.com/llvm/llvm-project/blob/f3671de5500ff1f8210419226a9603a7d83b1a31/compiler-rt/lib/builtins/fp_fixuint_impl.inc

        let significandBits = 52
        let exponentBias = 1023
        let implicitBit: UInt64 = 1 << 52
        let significandMask: UInt64 = implicitBit - 1
        let signMask: UInt64 = 1 << 63
        let absMask: UInt64 = signMask - 1

        // Break n into sign, exponent, significand parts.
        let bits = n.bitPattern
        let nAbs = bits & absMask
        let sign: Int128 = bits & signMask != 0 ? -1 : 1
        let exponent = Int(nAbs >> 52) - exponentBias
        let significand = (nAbs & significandMask) | implicitBit

        // If exponent is negative, the result is zero.
        if exponent < 0 {
            return 0
        }

        // If the value is too large for the integer type, overflow.
        if exponent >= 128 {
            return nil
        }

        // If 0 <= exponent < significandBits, right shift to get the result.
        // Otherwise, shift left. For 2^127 <= |n| < 2^128 the shift reaches the sign bit and wraps, and -2^127 times -1 wraps to itself.
        var result = Int128(significand)
        if exponent < significandBits {
            result &>>= significandBits - exponent
        } else {
            result &<<= exponent - significandBits
        }
        result = result &* sign
        return result
    }

    // IsValidDuration step 8 bound: abs(normalizedNanoseconds) < 2^53 × 10^9 nanoseconds.
    private static var durationNanosecondsLimit: Int128 { 9_007_199_254_740_992_000_000_000 }

    // Sentinel for Duration::setField — stored when checkedCastDoubleToInt128 overflows
    // (input double >= 2^127). Any value >= durationNanosecondsLimit causes
    // isValidDuration() to return false via the totalNanoseconds overflow check.
    private static var subsecondOutOfRangeSentinel: Int128 { durationNanosecondsLimit }

    // Converts a JS Number (double) to the Duration's typed storage.
    // int64_t fields (years–milliseconds): doubleToInt64Saturating avoids UB for out-of-range values.
    // Int128 fields (microseconds, nanoseconds): checkedCastDoubleToInt128 handles values >= 2^127
    // by returning a sentinel >= durationNanosecondsLimit so isValidDuration rejects the Duration.
    /// `Duration::setField(TemporalUnit, double)`.
    static func durationSetField(_ duration: inout JSC.ISO8601.Duration, _ unit: JSC.TemporalUnit, _ v: Double) {
        typealias Duration = JSC.ISO8601.Duration
        switch unit {
        case .Year:
            duration.setYears(Duration.doubleToInt64Saturating(v))
        case .Month:
            duration.setMonths(Duration.doubleToInt64Saturating(v))
        case .Week:
            duration.setWeeks(Duration.doubleToInt64Saturating(v))
        case .Day:
            duration.setDays(Duration.doubleToInt64Saturating(v))
        case .Hour:
            duration.setHours(Duration.doubleToInt64Saturating(v))
        case .Minute:
            duration.setMinutes(Duration.doubleToInt64Saturating(v))
        case .Second:
            duration.setSeconds(Duration.doubleToInt64Saturating(v))
        case .Millisecond:
            duration.setMilliseconds(Duration.doubleToInt64Saturating(v))
        case .Microsecond:
            duration.setMicroseconds(checkedCastDoubleToInt128(v) ?? subsecondOutOfRangeSentinel)
        case .Nanosecond:
            duration.setNanoseconds(checkedCastDoubleToInt128(v) ?? subsecondOutOfRangeSentinel)
        @unknown default:
            break
        }
    }

    /// `Duration::totalNanoseconds<unit>()`, with the template's unit as an argument: `Day`,
    /// `Second`, `Millisecond` or `Microsecond`.
    static func durationTotalNanoseconds(_ duration: JSC.ISO8601.Duration, _ unit: JSC.TemporalUnit) -> Int128? {
        assert(unit.rawValue >= JSC.TemporalUnit.Day.rawValue)

        var resultNs = TemporalCheckedInt128(0)
        let unit = unit.rawValue

        if unit <= JSC.TemporalUnit.Day.rawValue {
            resultNs += TemporalCheckedInt128(Int128(duration.days())) * TemporalExactTime.nsPerDay
        }
        if unit <= JSC.TemporalUnit.Hour.rawValue {
            resultNs += TemporalCheckedInt128(Int128(duration.hours())) * TemporalExactTime.nsPerHour
        }
        if unit <= JSC.TemporalUnit.Minute.rawValue {
            resultNs += TemporalCheckedInt128(Int128(duration.minutes())) * TemporalExactTime.nsPerMinute
        }
        if unit <= JSC.TemporalUnit.Second.rawValue {
            resultNs += TemporalCheckedInt128(Int128(duration.seconds())) * TemporalExactTime.nsPerSecond
        }
        if unit <= JSC.TemporalUnit.Millisecond.rawValue {
            resultNs += TemporalCheckedInt128(Int128(duration.milliseconds())) * TemporalExactTime.nsPerMillisecond
        }
        if unit <= JSC.TemporalUnit.Microsecond.rawValue {
            resultNs += TemporalCheckedInt128(duration.microseconds()) * TemporalExactTime.nsPerMicrosecond
        }
        if unit <= JSC.TemporalUnit.Nanosecond.rawValue {
            resultNs += TemporalCheckedInt128(duration.nanoseconds())
        }

        if resultNs.hasOverflowed {
            return nil
        }

        return resultNs.value
    }

    // IsValidDuration ( years, months, weeks, days, hours, minutes, seconds, milliseconds, microseconds, nanoseconds )
    // https://tc39.es/proposal-temporal/#sec-temporal-isvalidduration
    static func isValidDuration(_ duration: JSC.ISO8601.Duration) -> Bool {
        // Check sign consistency: all non-zero fields must have the same sign.
        let fields: [10 of Int128] = [
            Int128(duration.years()), Int128(duration.months()), Int128(duration.weeks()), Int128(duration.days()),
            Int128(duration.hours()), Int128(duration.minutes()), Int128(duration.seconds()),
            Int128(duration.milliseconds()), duration.microseconds(), duration.nanoseconds(),
        ]
        var sign = 0
        for index in fields.indices {
            let v = fields[index]
            if v < 0 && sign > 0 {
                return false
            }
            if v > 0 && sign < 0 {
                return false
            }
            if sign == 0 && v != 0 {
                sign = v > 0 ? 1 : -1
            }
        }

        // 3. If abs(years) ≥ 2^32, return false.
        // 4. If abs(months) ≥ 2^32, return false.
        // 5. If abs(weeks) ≥ 2^32, return false.
        // Use range comparisons to avoid UB from std::abs(INT64_MIN).
        let limit: Int64 = 1 << 32
        if duration.years() >= limit || duration.years() <= -limit
            || duration.months() >= limit || duration.months() <= -limit
            || duration.weeks() >= limit || duration.weeks() <= -limit
        {
            return false
        }

        // 6. Let normalizedSeconds be days × 86,400 + hours × 3600 + minutes × 60 + seconds + ℝ(𝔽(milliseconds)) × 10^-3 + ℝ(𝔽(microseconds)) × 10^-6 + ℝ(𝔽(nanoseconds)) × 10^-9.
        let normalizedNanoseconds = durationTotalNanoseconds(duration, .Day)
        // 8. If abs(normalizedSeconds) ≥ 2^53, return false.
        // nil from totalNanoseconds is Int128 overflow, far past 2^53.
        guard let normalizedNanoseconds, normalizedNanoseconds < durationNanosecondsLimit, normalizedNanoseconds > -durationNanosecondsLimit
        else {
            return false
        }

        return true
    }

    /// `ExactTime::add(Duration)`.
    static func exactTimeAdd(_ exactTime: JSC.ISO8601.ExactTime, _ duration: JSC.ISO8601.Duration) -> JSC.ISO8601.ExactTime? {
        typealias ExactTime = JSC.ISO8601.ExactTime
        assert(duration.years() == 0)
        assert(duration.months() == 0)
        assert(duration.weeks() == 0)
        assert(duration.days() == 0)

        var resultNs = TemporalCheckedInt128(exactTime.epochNanoseconds())

        // The duration's hours, minutes, seconds, and milliseconds should be
        // able to be cast into a 64-bit int. 2*1e8 24-hour days is the maximum
        // time span for exact time, so if we already know that the duration exceeds
        // that, then we can bail out.

        let hours = TemporalCheckedInt128(Int128(duration.hours()))
        resultNs += hours * TemporalExactTime.nsPerHour
        let minutes = TemporalCheckedInt128(Int128(duration.minutes()))
        resultNs += minutes * TemporalExactTime.nsPerMinute
        let seconds = TemporalCheckedInt128(Int128(duration.seconds()))
        resultNs += seconds * TemporalExactTime.nsPerSecond
        let milliseconds = TemporalCheckedInt128(Int128(duration.milliseconds()))
        resultNs += milliseconds * TemporalExactTime.nsPerMillisecond
        let microseconds = TemporalCheckedInt128(duration.microseconds())
        resultNs += microseconds * TemporalExactTime.nsPerMicrosecond
        resultNs += TemporalCheckedInt128(duration.nanoseconds())
        if resultNs.hasOverflowed {
            return nil
        }

        let result = ExactTime(resultNs.value)
        if !result.isValid() {
            return nil
        }
        return result
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-datedurationsign
    static func dateDurationSign(_ d: JSC.ISO8601.Duration) -> Int32 {
        if d.years() > 0 {
            return 1
        }
        if d.years() < 0 {
            return -1
        }
        if d.months() > 0 {
            return 1
        }
        if d.months() < 0 {
            return -1
        }
        if d.weeks() > 0 {
            return 1
        }
        if d.weeks() < 0 {
            return -1
        }
        if d.days() > 0 {
            return 1
        }
        if d.days() < 0 {
            return -1
        }
        return 0
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-internaldurationsign
    /// `InternalDuration::sign()`.
    static func internalDurationSign(_ internalDuration: JSC.ISO8601.InternalDuration) -> Int32 {
        let sign = dateDurationSign(internalDuration.dateDuration())
        if sign != 0 {
            return sign
        }
        return internalDuration.timeDurationSign()
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-combinedateandtimeduration
    /// `InternalDuration::combineDateAndTimeDuration`.
    ///
    /// The two signs agree.
    static func combineDateAndTimeDuration(_ dateDuration: JSC.ISO8601.Duration, _ timeDuration: Int128) -> JSC.ISO8601.InternalDuration {
        JSC.ISO8601.InternalDuration(dateDuration, timeDuration)
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-isodatetimewithinlimits
    static func isDateTimeWithinLimits(
        _ year: Int32,
        _ month: UInt8,
        _ day: UInt8,
        _ hour: UInt32,
        _ minute: UInt32,
        _ second: UInt32,
        _ millisecond: UInt32,
        _ microsecond: UInt32,
        _ nanosecond: UInt32
    ) -> Bool {
        // The year strictly inside the valid range is unconditionally OK regardless of the
        // time-of-day or day-of-month. The absolute min/max epoch instants Temporal admits
        // are -271821-04-20T00:00:00Z and +275760-09-13T00:00:00Z. isDateTimeWithinLimits
        // adds a +-1-day slack to those bounds, so the only years where some (month, day, time)
        // combination can land outside the representable range are the boundary years themselves.
        // Years strictly inside (-271821, +275760) always pass.
        if year > JSC.ISO8601.minYear && year < JSC.ISO8601.maxYear {
            return true
        }

        let nanoseconds = exactTimeFromISOPartsAndOffset(year, month, day, hour, minute, second, millisecond, microsecond, nanosecond, 0)
            .epochNanoseconds()
        if nanoseconds <= (TemporalExactTime.minValue - TemporalExactTime.nsPerDay) {
            return false
        }
        if nanoseconds >= (TemporalExactTime.maxValue + TemporalExactTime.nsPerDay) {
            return false
        }
        return true
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-isvalidisodate
    static func isValidISODate(_ year: Double, _ month: Double, _ day: Double) -> Bool {
        if month < 1 || month > 12 {
            return false
        }
        // A NaN month is not a valid date. The year converts as arm64's fcvtzs does: NaN to 0,
        // out-of-range values saturated.
        if month.isNaN {
            return false
        }
        let daysInMonth1 = daysInMonth(temporalSaturatingInt32(year), UInt8(month))
        // A NaN day passes both tests.
        if day < 1 || day > Double(daysInMonth1) {
            return false
        }
        return true
    }
}

/// `static_cast<int32_t>(double)` as arm64 computes it (fcvtzs): toward zero, NaN to 0, out of range saturated.
func temporalSaturatingInt32(_ value: Double) -> Int32 {
    if value.isNaN {
        return 0
    }
    if value >= 2_147_483_647 {
        return Int32.max
    }
    if value <= -2_147_483_648 {
        return Int32.min
    }
    return Int32(value)
}

// MARK: - Implementations of C++ declarations
//
// Each is the definition of the `JS_EXPORT_PRIVATE` declaration it names, under its C++ symbol: `public`, so that
// JavaScriptCore exports it, with the C++ type names spelled out. Every parameter is a value.

extension JSC.ISO8601 {
    /// `ISO8601::dayOfWeek`.
    @cxx
    @implementation
    public static func dayOfWeek(_ plainDate: JSC.ISO8601.PlainDate) -> UInt8 {
        TemporalISO8601.dayOfWeek(plainDate)
    }

    /// `ISO8601::dayOfYear`.
    @cxx
    @implementation
    public static func dayOfYear(_ plainDate: JSC.ISO8601.PlainDate) -> UInt16 {
        TemporalISO8601.dayOfYear(plainDate)
    }

    /// `ISO8601::weekOfYear`.
    @cxx
    @implementation
    public static func weekOfYear(_ plainDate: JSC.ISO8601.PlainDate) -> UInt8 {
        TemporalISO8601.weekOfYear(plainDate)
    }

    /// `ISO8601::yearOfWeek`.
    @cxx
    @implementation
    public static func yearOfWeek(_ plainDate: JSC.ISO8601.PlainDate) -> Int32 {
        TemporalISO8601.yearOfWeek(plainDate)
    }

    /// `ISO8601::daysInMonth(int32_t year, uint8_t month)`.
    @cxx
    @implementation
    public static func daysInMonth(_ year: Int32, _ month: UInt8) -> UInt8 {
        TemporalISO8601.daysInMonth(year, month)
    }

    /// `ISO8601::daysInMonth(uint8_t month)`.
    @cxx
    @implementation
    public static func daysInMonth(_ month: UInt8) -> UInt8 {
        TemporalISO8601.daysInMonth(month)
    }

    /// `ISO8601::formatTimeZoneOffsetString`.
    @cxx
    @implementation
    public static func formatTimeZoneOffsetString(_ offset: Int64) -> WTF.String {
        TemporalISO8601.formatTimeZoneOffsetString(offset)
    }

    /// `ISO8601::temporalDateToString(PlainDate)`.
    @cxx
    @implementation
    public static func temporalDateToString(_ plainDate: JSC.ISO8601.PlainDate) -> WTF.String {
        TemporalISO8601.temporalDateToString(plainDate)
    }

    /// `ISO8601::monthCode`.
    @cxx
    @implementation
    public static func monthCode(_ month: UInt32) -> WTF.String {
        TemporalISO8601.monthCode(month)
    }

    /// `ISO8601::isDateTimeWithinLimits`.
    @cxx
    @implementation
    public static func isDateTimeWithinLimits(
        _ year: Int32,
        _ month: UInt8,
        _ day: UInt8,
        _ hour: UInt32,
        _ minute: UInt32,
        _ second: UInt32,
        _ millisecond: UInt32,
        _ microsecond: UInt32,
        _ nanosecond: UInt32
    ) -> Bool {
        TemporalISO8601.isDateTimeWithinLimits(year, month, day, hour, minute, second, millisecond, microsecond, nanosecond)
    }

    /// `ISO8601::isValidISODate`.
    @cxx
    @implementation
    public static func isValidISODate(_ year: Double, _ month: Double, _ day: Double) -> Bool {
        TemporalISO8601.isValidISODate(year, month, day)
    }
}

extension JSC.ISO8601.ExactTime {
    /// `ISO8601::ExactTime::fromISOPartsAndOffset`.
    @cxx
    @implementation
    public static func fromISOPartsAndOffset(
        _ year: Int32,
        _ month: UInt8,
        _ day: UInt8,
        _ hour: UInt32,
        _ minute: UInt32,
        _ second: UInt32,
        _ millisecond: UInt32,
        _ microsecond: UInt32,
        _ nanosecond: UInt32,
        _ offset: Int64
    ) -> JSC.ISO8601.ExactTime {
        TemporalISO8601.exactTimeFromISOPartsAndOffset(
            year,
            month,
            day,
            hour,
            minute,
            second,
            millisecond,
            microsecond,
            nanosecond,
            offset
        )
    }
}

extension JSC.ISO8601.InternalDuration {
    /// `ISO8601::InternalDuration::combineDateAndTimeDuration`.
    @cxx
    @implementation
    public static func combineDateAndTimeDuration(
        _ dateDuration: JSC.ISO8601.Duration,
        _ timeDuration: Int128
    ) -> JSC.ISO8601.InternalDuration {
        TemporalISO8601.combineDateAndTimeDuration(dateDuration, timeDuration)
    }
}

extension JSC {
    /// `JSC::checkedCastDoubleToInt128`: overflowed where the double is not in `Int128`'s range.
    @cxx
    @implementation
    public static func checkedCastDoubleToInt128(_ n: Double) -> JSC.CheckedInt128 {
        guard let value = TemporalISO8601.checkedCastDoubleToInt128(n) else {
            return JSC.CheckedInt128(WTF.ResultOverflowed)
        }
        return JSC.CheckedInt128(value)
    }
}

// MARK: - Functions the C++ calls

// Exclusivity of their parameters: see TemporalSupport.swift.

/// `ISO8601::temporalTimeToString`, with the precision tuple's two members.
@_expose(Cxx)
func temporalTemporalTimeToString(
    _ plainTime: JSC.ISO8601.PlainTime,
    _ precisionType: JSC.Precision,
    _ precisionValue: UInt32
) -> WTF.String {
    TemporalISO8601.temporalTimeToString(plainTime, precisionType, precisionValue)
}

/// `ISO8601::temporalDateTimeToString`, with the precision tuple's two members.
@_expose(Cxx)
func temporalTemporalDateTimeToString(
    _ plainDate: JSC.ISO8601.PlainDate,
    _ plainTime: JSC.ISO8601.PlainTime,
    _ precisionType: JSC.Precision,
    _ precisionValue: UInt32
) -> WTF.String {
    TemporalISO8601.temporalDateTimeToString(plainDate, plainTime, precisionType, precisionValue)
}

/// `ISO8601::temporalYearMonthToString` for an 8-bit calendar name.
///
/// `calendarName` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every byte is a valid `Latin1Character`.
@_expose(Cxx)
func temporalTemporalYearMonthToString8(
    _ calendarName: JSC.TemporalLatin1Span,
    _ isoPlainDate: JSC.ISO8601.PlainDate,
    _ calendarId: UInt32
) -> WTF.String {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(calendarName))
    return TemporalISO8601.temporalYearMonthToString(isoPlainDate, characters, calendarId)
}

/// `ISO8601::temporalYearMonthToString` for a 16-bit calendar name.
///
/// `calendarName` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every value is a valid `char16_t`.
@_expose(Cxx)
func temporalTemporalYearMonthToString16(
    _ calendarName: JSC.TemporalUTF16Span,
    _ isoPlainDate: JSC.ISO8601.PlainDate,
    _ calendarId: UInt32
) -> WTF.String {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: calendarName)
    return TemporalISO8601.temporalYearMonthToString(isoPlainDate, characters, calendarId)
}

/// `ISO8601::temporalMonthDayToString` for an 8-bit calendar name.
///
/// `calendarName` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every byte is a valid `Latin1Character`.
@_expose(Cxx)
func temporalTemporalMonthDayToString8(
    _ calendarName: JSC.TemporalLatin1Span,
    _ isoPlainDate: JSC.ISO8601.PlainDate,
    _ calendarId: UInt32
) -> WTF.String {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(calendarName))
    return TemporalISO8601.temporalMonthDayToString(isoPlainDate, characters, calendarId)
}

/// `ISO8601::temporalMonthDayToString` for a 16-bit calendar name.
///
/// `calendarName` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every value is a valid `char16_t`.
@_expose(Cxx)
func temporalTemporalMonthDayToString16(
    _ calendarName: JSC.TemporalUTF16Span,
    _ isoPlainDate: JSC.ISO8601.PlainDate,
    _ calendarId: UInt32
) -> WTF.String {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: calendarName)
    return TemporalISO8601.temporalMonthDayToString(isoPlainDate, characters, calendarId)
}

/// `ISO8601::parseMonthCode` for an 8-bit string.
///
/// `monthCode` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every byte is a valid `Latin1Character`.
@_expose(Cxx)
func temporalParseMonthCode8(_ monthCode: JSC.TemporalLatin1Span, _ parsed: inout JSC.ParsedMonthCode) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(monthCode))
    return temporalStore(TemporalISO8601.parseMonthCode(characters), &parsed)
}

/// `ISO8601::parseMonthCode` for a 16-bit string.
///
/// `monthCode` is the characters that the caller's `StringView` views. They stay allocated and unwritten for the call:
/// nothing this function calls writes them. Every value is a valid `char16_t`.
@_expose(Cxx)
func temporalParseMonthCode16(_ monthCode: JSC.TemporalUTF16Span, _ parsed: inout JSC.ParsedMonthCode) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: monthCode)
    return temporalStore(TemporalISO8601.parseMonthCode(characters), &parsed)
}

/// `ISO8601::Duration::setField(TemporalUnit, double)`, on the `Duration` the member is called on.
///
/// `duration` is that `Duration`, which this function treats as exclusive for the call. The only C++ the body calls are
/// the static `doubleToInt64Saturating` and a setter on `duration` itself, so nothing else can reach the `Duration`
/// while it runs.
@_expose(Cxx)
func temporalDurationSetField(_ unit: JSC.TemporalUnit, _ v: Double, _ duration: inout JSC.ISO8601.Duration) {
    TemporalISO8601.durationSetField(&duration, unit, v)
}

/// `ISO8601::Duration::totalNanoseconds<unit>()`, every instantiation.
@_expose(Cxx)
func temporalDurationTotalNanoseconds(_ duration: JSC.ISO8601.Duration, _ unit: JSC.TemporalUnit, _ value: inout Int128) -> Bool {
    temporalStore(TemporalISO8601.durationTotalNanoseconds(duration, unit), &value)
}

/// `ISO8601::isValidDuration`.
@_expose(Cxx)
func temporalIsValidDuration(_ duration: JSC.ISO8601.Duration) -> Bool {
    TemporalISO8601.isValidDuration(duration)
}

/// `ISO8601::ExactTime::add(Duration)`.
@_expose(Cxx)
func temporalExactTimeAdd(
    _ exactTime: JSC.ISO8601.ExactTime,
    _ duration: JSC.ISO8601.Duration,
    _ value: inout JSC.ISO8601.ExactTime
) -> Bool {
    temporalStore(TemporalISO8601.exactTimeAdd(exactTime, duration), &value)
}

/// `ISO8601::InternalDuration::sign()`.
@_expose(Cxx)
func temporalInternalDurationSign(_ internalDuration: JSC.ISO8601.InternalDuration) -> Int32 {
    TemporalISO8601.internalDurationSign(internalDuration)
}
