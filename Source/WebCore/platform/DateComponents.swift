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
internal import wtf.Core.DateMath
internal import wtf.Core.text.WTFString
internal import WebCore_Private.Core.HTMLMicrosyntaxesSwiftTypes
internal import WebCore_Private.Core.DateComponents

// The parsers, conversions and serialization of DateComponents. They reach its private members, so they are in an
// extension in this file, which DateComponents.h names in SWIFT_PRIVATE_FILEID.
//
// Each parser and conversion from a number sets what it finds in `date`, a default DateComponents on its caller's
// stack, so that it calls no C++ constructor, and returns false where the C++ API returns std::nullopt.
// DateComponents is trivially copyable, and nothing else reaches `date` during the call.
//
// The parsers exposed to C++ only make a Span of their characters and call a function marked @inline(never). That
// keeps them small enough for link-time optimization to inline them into their C++ callers, where the std::span
// accessors they call are inlined too.

// MARK: Parsing

/// The rules for parsing a string of `type`, a month, date, week, time or local date and time, as
/// DateComponents::fromParsingMonth() and the others, for an 8-bit StringView.
///
/// `characters` are the characters of the caller's StringView. They stay allocated and unchanged for the call, since
/// the caller holds their string and this function only reads them and passes them to no C++, and every value of a
/// Latin-1 code unit is a valid character.
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func dateComponentsFromParsing8(
    _ characters: WebCore.HTMLMicrosyntaxSpan8,
    _ type: WebCore.DateComponentsType,
    _ date: inout WebCore.DateComponents
) -> Bool {
    let span = unsafe Span<WTF.Latin1Character>(_unsafeCxxSpan: characters)
    return date.parse(span, as: type)
}

/// dateComponentsFromParsing8() for a 16-bit StringView, whose characters stay allocated and unchanged for the call
/// in the same way, and every value of a UTF-16 code unit is a valid character.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func dateComponentsFromParsing16(
    _ characters: WebCore.HTMLMicrosyntaxSpan16,
    _ type: WebCore.DateComponentsType,
    _ date: inout WebCore.DateComponents
) -> Bool {
    let span = unsafe Span<UInt16>(_unsafeCxxSpan: characters)
    return date.parse(span, as: type)
}

// MARK: Conversions from numbers

/// Sets `date` to the date of `ms` milliseconds since 1970-01-01 00:00:00.000 UTC, as
/// DateComponents::fromMillisecondsSinceEpochForDate().
@_expose(Cxx)
func dateComponentsFromMillisecondsSinceEpochForDate(_ ms: Double, _ date: inout WebCore.DateComponents) -> Bool {
    date.setMillisecondsSinceEpochForDate(ms)
}

/// Sets `date` to the local date and time of `ms` milliseconds since 1970-01-01 00:00:00.000 UTC, as
/// DateComponents::fromMillisecondsSinceEpochForDateTimeLocal().
@_expose(Cxx)
func dateComponentsFromMillisecondsSinceEpochForDateTimeLocal(_ ms: Double, _ date: inout WebCore.DateComponents) -> Bool {
    date.setMillisecondsSinceEpochForDateTimeLocal(ms)
}

/// Sets `date` to the month of `ms` milliseconds since 1970-01-01 00:00:00.000 UTC, as
/// DateComponents::fromMillisecondsSinceEpochForMonth().
@_expose(Cxx)
func dateComponentsFromMillisecondsSinceEpochForMonth(_ ms: Double, _ date: inout WebCore.DateComponents) -> Bool {
    date.setMillisecondsSinceEpochForMonth(ms)
}

/// Sets `date` to the week of `ms` milliseconds since 1970-01-01 00:00:00.000 UTC, as
/// DateComponents::fromMillisecondsSinceEpochForWeek().
@_expose(Cxx)
func dateComponentsFromMillisecondsSinceEpochForWeek(_ ms: Double, _ date: inout WebCore.DateComponents) -> Bool {
    date.setMillisecondsSinceEpochForWeek(ms)
}

/// Sets `date` to the time of `ms` milliseconds since midnight, as DateComponents::fromMillisecondsSinceMidnight().
@_expose(Cxx)
func dateComponentsFromMillisecondsSinceMidnight(_ ms: Double, _ date: inout WebCore.DateComponents) -> Bool {
    date.setMillisecondsSinceMidnight(ms)
}

/// Sets `date` to the month `months` months after 1970-01, as DateComponents::fromMonthsSinceEpoch().
@_expose(Cxx)
func dateComponentsFromMonthsSinceEpoch(_ months: Double, _ date: inout WebCore.DateComponents) -> Bool {
    date.setMonthsSinceEpoch(months)
}

// MARK: Conversions to numbers and strings

/// DateComponents::millisecondsSinceEpoch() of `date`.
@_expose(Cxx)
func dateComponentsMillisecondsSinceEpoch(_ date: WebCore.DateComponents) -> Double {
    date.millisecondsSinceEpochForType()
}

/// DateComponents::monthsSinceEpoch() of `date`.
@_expose(Cxx)
func dateComponentsMonthsSinceEpoch(_ date: WebCore.DateComponents) -> Double {
    date.monthsSinceEpochForMonth()
}

/// DateComponents::toString() of `date`, where `format` is the value of a SecondFormat.
@_expose(Cxx)
func dateComponentsToString(_ date: WebCore.DateComponents, _ format: UInt8) -> WTF.String {
    var characters = DateComponentsCharacters()
    date.append(to: &characters, format)
    return characters.makeString()
}

// MARK: Limits

// DateComponents::minimumYear() and maximumYear(), which DateComponents.cpp checks these against.
private let minimumYearNumber: Int32 = 1
private let maximumYearNumber: Int32 = 275760

// HTML defines minimum week of year is one.
private let minimumWeekNumber: Int32 = 1

// HTML defines maximum week of year is 53.
private let maximumWeekNumber: Int32 = 53

private let maximumMonthInMaximumYear: Int32 = 8 // This is September, since months are 0 based.
private let maximumDayInMaximumMonth: Int32 = 13
private let maximumWeekInMaximumYear: Int32 = 37 // The week of 275760-09-13

private let daysInMonth: [12 of Int32] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

// The values of dayOfWeek().
private enum Weekday: Int32 {
    case sunday = 0
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
}

// 'month' is 0-based.
private func maxDayOfMonth(_ year: Int32, _ month: Int32) -> Int32 {
    if month != 1 { // February?
        return daysInMonth[Int(month)]
    }
    return isLeapYear(year) ? 29 : 28
}

// 'month' is 0-based.
private func dayOfWeek(_ year: Int32, _ month: Int32, _ day: Int32) -> Int32 {
    // Computed in Int, where no step overflows for any year.
    var year = Int(year)
    var shiftedMonth = Int(month) + 2
    // 2:January, 3:Feburuary, 4:March, ...

    // Zeller's congruence
    if shiftedMonth <= 3 {
        shiftedMonth += 12
        year -= 1
    }
    // 4:March, ..., 14:January, 15:February

    let highYear = year / 100
    let lowYear = year % 100
    // We add 6 to make the result Sunday-origin.
    let result = (Int(day) + 13 * shiftedMonth / 5 + lowYear + lowYear / 4 + highYear / 4 + 5 * highYear + 6) % 7
    return Int32(result)
}

// Returns the maximum week number in `year`.
// The result is either of 52 and 53.
private func maxWeekNumberInYear(_ year: Int32) -> Int32 {
    let day = dayOfWeek(year, 0, 1) // January 1.
    return day == Weekday.thursday.rawValue || (day == Weekday.wednesday.rawValue && isLeapYear(year))
        ? maximumWeekNumber : maximumWeekNumber - 1
}

// Offset from January 1st to Monday of the ISO 8601's first week.
//   ex. If January 1st is Friday, such Monday is 3 days later. Returns 3.
private func offsetTo1stWeekStart(_ year: Int32) -> Int32 {
    var offsetTo1stWeekStart = 1 - dayOfWeek(year, 0, 1)
    if offsetTo1stWeekStart <= -4 {
        offsetTo1stWeekStart += 7
    }
    return offsetTo1stWeekStart
}

private func withinHTMLDateLimits(_ year: Int32, _ month: Int32) -> Bool {
    if year < minimumYearNumber {
        return false
    }
    if year < maximumYearNumber {
        return true
    }
    return month <= maximumMonthInMaximumYear
}

private func withinHTMLDateLimits(_ year: Int32, _ month: Int32, _ monthDay: Int32) -> Bool {
    if year < minimumYearNumber {
        return false
    }
    if year < maximumYearNumber {
        return true
    }
    if month < maximumMonthInMaximumYear {
        return true
    }
    return monthDay <= maximumDayInMaximumMonth
}

private func withinHTMLDateLimits(
    _ year: Int32,
    _ month: Int32,
    _ monthDay: Int32,
    _ hour: Int32,
    _ minute: Int32,
    _ second: Int32,
    _ millisecond: Int32
) -> Bool {
    if year < minimumYearNumber {
        return false
    }
    if year < maximumYearNumber {
        return true
    }
    if month < maximumMonthInMaximumYear {
        return true
    }
    if monthDay < maximumDayInMaximumMonth {
        return true
    }
    if monthDay > maximumDayInMaximumMonth {
        return false
    }
    // (year, month, monthDay) = (maximumYear, maximumMonthInMaximumYear, maximumDayInMaximumMonth)
    return hour == 0 && minute == 0 && second == 0 && millisecond == 0
}

// MARK: Reading characters

// Gecko allows both 'T' and a space as datetime-local separator (see https://github.com/whatwg/html/issues/2276).
// WPT tests also expect this behavior.
@inline(always)
private func isDateTimeLocalSeparator<CodeUnit: HTMLMicrosyntaxCodeUnit>(_ character: CodeUnit) -> Bool {
    character.htmlMicrosyntaxMatches("T") || character.htmlMicrosyntaxMatches(" ")
}

// Advances `index` past the character there if it is `character`.
@inline(always)
private func skipExactly<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ index: inout Int,
    _ character: Unicode.Scalar
) -> Bool {
    guard index < characters.count, characters[index].htmlMicrosyntaxMatches(character) else {
        return false
    }
    index += 1
    return true
}

// The number of ASCII digits from characters[index].
@inline(always)
private func countDigits<CodeUnit: HTMLMicrosyntaxCodeUnit>(_ characters: Span<CodeUnit>, _ index: Int) -> Int {
    // Cannot overflow: the index after the digits is at least index.
    characters.htmlMicrosyntaxIndexAfterASCIIDigits(from: index) &- index
}

// The number in the `length` characters from characters[index], which leaves `isValid` true only if all of them are
// ASCII digits. A code unit below '0' wraps around to a value above 9, and the number is then not used.
@inline(always)
private func fixedLayoutNumber<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ index: Int,
    _ length: Int,
    _ isValid: inout Bool
) -> Int32 {
    var number: UInt32 = 0
    for position in index..<index + length {
        let digit = UInt32(characters[position].htmlMicrosyntaxCodeUnit) &- 0x30
        isValid = isValid && digit <= 9
        // Wraps only when a character is not a digit: the callers read at most 4 digits.
        number = number &* 10 &+ digit
    }
    return Int32(bitPattern: number)
}

// Leaves `isValid` true only if characters[index] is `character`.
@inline(always)
private func fixedLayoutSeparator<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ index: Int,
    _ character: Unicode.Scalar,
    _ isValid: inout Bool
) {
    let matches = characters[index].htmlMicrosyntaxMatches(character)
    isValid = isValid && matches
}

// The date 'YYYY-MM-DD' at characters[0...9], with a 1-based month.
@inline(always)
private func fixedLayoutDate<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ isValid: inout Bool
) -> (year: Int32, month: Int32, monthDay: Int32) {
    let year = fixedLayoutNumber(characters, 0, 4, &isValid)
    fixedLayoutSeparator(characters, 4, "-", &isValid)
    let month = fixedLayoutNumber(characters, 5, 2, &isValid)
    fixedLayoutSeparator(characters, 7, "-", &isValid)
    let monthDay = fixedLayoutNumber(characters, 8, 2, &isValid)
    return (year, month, monthDay)
}

// The time 'HH:MM' at characters[index...], followed by ':SS' if `hasSecond`.
@inline(always)
private func fixedLayoutTime<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ index: Int,
    hasSecond: Bool,
    _ isValid: inout Bool
) -> (hour: Int32, minute: Int32, second: Int32) {
    let hour = fixedLayoutNumber(characters, index, 2, &isValid)
    fixedLayoutSeparator(characters, index + 2, ":", &isValid)
    let minute = fixedLayoutNumber(characters, index + 3, 2, &isValid)
    guard hasSecond else {
        return (hour, minute, 0)
    }
    fixedLayoutSeparator(characters, index + 5, ":", &isValid)
    let second = fixedLayoutNumber(characters, index + 6, 2, &isValid)
    return (hour, minute, second)
}

// The limits parseDate() checks, for a 4-digit year and a 1-based month. Every such date, and every time on it, is
// within the HTML date limits, since the year is below maximumYearNumber.
@inline(always)
private func isValidFixedLayoutDate(_ year: Int32, _ month: Int32, _ monthDay: Int32) -> Bool {
    year >= minimumYearNumber && month >= 1 && month <= 12 && monthDay >= 1 && monthDay <= maxDayOfMonth(year, month - 1)
}

// The limits parseTime() checks.
@inline(always)
private func isValidFixedLayoutTime(_ hour: Int32, _ minute: Int32, _ second: Int32) -> Bool {
    hour <= 23 && minute <= 59 && second <= 59
}

// Differences from parseHTMLInteger(): reads exactly maximumNumberOfDigitsToParse digits. Does not allow leading or
// trailing spaces. Does not allow leading "+".
private func parseInt<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ index: inout Int,
    _ maximumNumberOfDigitsToParse: Int
) -> Int32? {
    // Cannot overflow: index is at most characters.count.
    if maximumNumberOfDigitsToParse > characters.count &- index || maximumNumberOfDigitsToParse == 0 {
        return nil
    }

    // We don't need to handle negative numbers for ISO 8601.

    var value: Int32 = 0
    var digitsRemaining = 0
    while digitsRemaining < maximumNumberOfDigitsToParse {
        guard let digitValue = characters[index].htmlMicrosyntaxASCIIDigitValue else {
            return nil
        }
        let digit = Int32(digitValue)
        if value > (Int32.max - digit) / 10 { // Check for overflow.
            return nil
        }
        // Cannot overflow: the check above keeps value * 10 + digit at most Int32.max.
        value = value &* 10 &+ digit
        digitsRemaining += 1
        index += 1
    }
    return value
}

private func parseIntWithinLimits<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ index: inout Int,
    _ maximumNumberOfDigitsToParse: Int,
    _ minimumValue: Int32,
    _ maximumValue: Int32
) -> Int32? {
    guard let value = parseInt(characters, &index, maximumNumberOfDigitsToParse), value >= minimumValue, value <= maximumValue else {
        return nil
    }
    return value
}

// MARK: DateComponents

extension WebCore.DateComponents {
    // Sets what parsing a string of `type` finds, and returns whether the whole string is valid.
    @inline(never)
    fileprivate mutating func parse<CodeUnit: HTMLMicrosyntaxCodeUnit>(
        _ characters: Span<CodeUnit>,
        as type: WebCore.DateComponentsType
    ) -> Bool {
        if parseFixedLayout(characters, as: type) {
            return true
        }
        return parseAnyLayout(characters, as: type)
    }

    // Parses the strings most values are: a 4-digit year, a 2-digit month, day, week, hour, minute and second, and no
    // fraction of a second. It reads each character at a fixed position below the count it checks first, and checks
    // the values against the parse functions' own limits. Any other string, and one out of those limits, it leaves to
    // parseAnyLayout(), with nothing set.
    @inline(always)
    private mutating func parseFixedLayout<CodeUnit: HTMLMicrosyntaxCodeUnit>(
        _ characters: Span<CodeUnit>,
        as type: WebCore.DateComponentsType
    ) -> Bool {
        var isValid = true
        switch type {
        case .Month:
            guard characters.count == 7 else {
                return false
            }
            let year = fixedLayoutNumber(characters, 0, 4, &isValid)
            fixedLayoutSeparator(characters, 4, "-", &isValid)
            let month = fixedLayoutNumber(characters, 5, 2, &isValid)
            // A 4-digit year is below maximumYearNumber, so every month of it is within the HTML date limits.
            guard isValid, year >= minimumYearNumber, month >= 1, month <= 12 else {
                return false
            }
            m_year = year
            m_month = month - 1
            m_type = .Month
            return true
        case .Date:
            guard characters.count == 10 else {
                return false
            }
            let date = fixedLayoutDate(characters, &isValid)
            guard isValid, isValidFixedLayoutDate(date.year, date.month, date.monthDay) else {
                return false
            }
            m_year = date.year
            m_month = date.month - 1
            m_monthDay = date.monthDay
            m_type = .Date
            return true
        case .Week:
            guard characters.count == 8 else {
                return false
            }
            let year = fixedLayoutNumber(characters, 0, 4, &isValid)
            fixedLayoutSeparator(characters, 4, "-", &isValid)
            fixedLayoutSeparator(characters, 5, "W", &isValid)
            let week = fixedLayoutNumber(characters, 6, 2, &isValid)
            // A 4-digit year is below maximumYearNumber, so every week of it is within the HTML date limits.
            guard isValid, year >= minimumYearNumber, week >= minimumWeekNumber, week <= maxWeekNumberInYear(year) else {
                return false
            }
            m_year = year
            m_week = week
            m_type = .Week
            return true
        case .Time:
            let hasSecond = characters.count == 8
            guard hasSecond || characters.count == 5 else {
                return false
            }
            let time = fixedLayoutTime(characters, 0, hasSecond: hasSecond, &isValid)
            guard isValid, isValidFixedLayoutTime(time.hour, time.minute, time.second) else {
                return false
            }
            m_hour = time.hour
            m_minute = time.minute
            m_second = time.second
            m_millisecond = 0
            m_type = .Time
            return true
        case .DateTimeLocal:
            let hasSecond = characters.count == 19
            guard hasSecond || characters.count == 16 else {
                return false
            }
            let date = fixedLayoutDate(characters, &isValid)
            let isSeparator = isDateTimeLocalSeparator(characters[10])
            isValid = isValid && isSeparator
            let time = fixedLayoutTime(characters, 11, hasSecond: hasSecond, &isValid)
            guard isValid, isValidFixedLayoutDate(date.year, date.month, date.monthDay),
                isValidFixedLayoutTime(time.hour, time.minute, time.second)
            else {
                return false
            }
            m_year = date.year
            m_month = date.month - 1
            m_monthDay = date.monthDay
            m_hour = time.hour
            m_minute = time.minute
            m_second = time.second
            m_millisecond = 0
            m_type = .DateTimeLocal
            return true
        default:
            return false
        }
    }

    // parse() for any string. The parse functions read from characters[index], and advance index past what they read.
    @inline(never)
    private mutating func parseAnyLayout<CodeUnit: HTMLMicrosyntaxCodeUnit>(
        _ characters: Span<CodeUnit>,
        as type: WebCore.DateComponentsType
    ) -> Bool {
        if characters.isEmpty {
            return false
        }
        var index = 0
        let parsed: Bool
        switch type {
        case .Month:
            parsed = parseMonth(characters, &index)
        case .Date:
            parsed = parseDate(characters, &index)
        case .Week:
            parsed = parseWeek(characters, &index)
        case .Time:
            parsed = parseTime(characters, &index)
        case .DateTimeLocal:
            parsed = parseDateTimeLocal(characters, &index)
        default:
            return false
        }
        return parsed && index == characters.count
    }

    // https://html.spec.whatwg.org/multipage/common-microsyntaxes.html#months
    private mutating func parseYear<CodeUnit: HTMLMicrosyntaxCodeUnit>(_ characters: Span<CodeUnit>, _ index: inout Int) -> Bool {
        let digitsLength = countDigits(characters, index)
        // Needs at least 4 digits according to the standard.
        if digitsLength < 4 {
            return false
        }

        guard let year = parseIntWithinLimits(characters, &index, digitsLength, minimumYearNumber, maximumYearNumber) else {
            return false
        }

        m_year = year
        return true
    }

    // https://html.spec.whatwg.org/multipage/common-microsyntaxes.html#months
    private mutating func parseMonth<CodeUnit: HTMLMicrosyntaxCodeUnit>(_ characters: Span<CodeUnit>, _ index: inout Int) -> Bool {
        if !parseYear(characters, &index) {
            return false
        }

        if !skipExactly(characters, &index, "-") {
            return false
        }

        guard var month = parseIntWithinLimits(characters, &index, 2, 1, 12) else {
            return false
        }
        month -= 1

        if !withinHTMLDateLimits(m_year, month) {
            return false
        }

        m_month = month
        m_type = .Month
        return true
    }

    // https://html.spec.whatwg.org/multipage/common-microsyntaxes.html#dates
    private mutating func parseDate<CodeUnit: HTMLMicrosyntaxCodeUnit>(_ characters: Span<CodeUnit>, _ index: inout Int) -> Bool {
        if !parseMonth(characters, &index) {
            return false
        }

        if !skipExactly(characters, &index, "-") {
            return false
        }

        guard let day = parseIntWithinLimits(characters, &index, 2, 1, maxDayOfMonth(m_year, m_month)) else {
            return false
        }

        if !withinHTMLDateLimits(m_year, m_month, day) {
            return false
        }

        m_monthDay = day
        m_type = .Date
        return true
    }

    // https://html.spec.whatwg.org/multipage/common-microsyntaxes.html#weeks
    private mutating func parseWeek<CodeUnit: HTMLMicrosyntaxCodeUnit>(_ characters: Span<CodeUnit>, _ index: inout Int) -> Bool {
        if !parseYear(characters, &index) {
            return false
        }

        if !skipExactly(characters, &index, "-") {
            return false
        }
        if !skipExactly(characters, &index, "W") {
            return false
        }

        guard let week = parseIntWithinLimits(characters, &index, 2, minimumWeekNumber, maxWeekNumberInYear(m_year)) else {
            return false
        }

        if m_year == maximumYearNumber && week > maximumWeekInMaximumYear {
            return false
        }

        m_week = week
        m_type = .Week
        return true
    }

    // https://html.spec.whatwg.org/multipage/common-microsyntaxes.html#times
    private mutating func parseTime<CodeUnit: HTMLMicrosyntaxCodeUnit>(_ characters: Span<CodeUnit>, _ index: inout Int) -> Bool {
        guard let hour = parseIntWithinLimits(characters, &index, 2, 0, 23) else {
            return false
        }

        if !skipExactly(characters, &index, ":") {
            return false
        }

        guard let minute = parseIntWithinLimits(characters, &index, 2, 0, 59) else {
            return false
        }

        // Optional second part.
        // Do not return with false because the part is optional.
        var second: Int32?
        var millisecond: Int32?

        var temporaryIndex = index
        if skipExactly(characters, &temporaryIndex, ":") {
            second = parseIntWithinLimits(characters, &temporaryIndex, 2, 0, 59)
            if second != nil {
                // Only after successfully parsing and validating 'second', do we increment the real index.
                index = temporaryIndex

                // Optional fractional second part.
                if skipExactly(characters, &temporaryIndex, ".") {
                    let digitsLength = countDigits(characters, temporaryIndex)
                    if digitsLength > 0 {
                        let scale: Int32
                        switch digitsLength {
                        case 1:
                            scale = 100
                        case 2:
                            scale = 10
                        case 3:
                            scale = 1
                        default:
                            return false
                        }

                        // Due to the digit count above, parsing them succeeds.
                        guard let fraction = parseInt(characters, &temporaryIndex, digitsLength) else {
                            return false
                        }
                        // Cannot overflow: the fraction has at most three digits.
                        millisecond = fraction &* scale

                        // Only after successfully parsing and validating 'millisecond', do we increment the real index.
                        index = temporaryIndex
                    }
                }
            }
        }

        m_hour = hour
        m_minute = minute
        m_second = second ?? 0
        m_millisecond = millisecond ?? 0
        m_type = .Time
        return true
    }

    // https://html.spec.whatwg.org/multipage/common-microsyntaxes.html#local-dates-and-times
    private mutating func parseDateTimeLocal<CodeUnit: HTMLMicrosyntaxCodeUnit>(_ characters: Span<CodeUnit>, _ index: inout Int) -> Bool {
        if !parseDate(characters, &index) {
            return false
        }

        guard index < characters.count, isDateTimeLocalSeparator(characters[index]) else {
            return false
        }
        index += 1

        if !parseTime(characters, &index) {
            return false
        }

        if !withinHTMLDateLimits(m_year, m_month, m_monthDay, m_hour, m_minute, m_second, m_millisecond) {
            return false
        }

        m_type = .DateTimeLocal
        return true
    }

    // `msInDay` is a whole number of milliseconds below msPerDay, on which integer division gives what
    // DateComponents.cpp's double arithmetic gives.
    private mutating func setMillisecondsSinceMidnightInternal(_ msInDay: UInt32) {
        assert(msInDay < UInt32(WTF.msPerDay))
        m_millisecond = Int32(msInDay % UInt32(WTF.msPerSecond))
        let seconds = msInDay / UInt32(WTF.msPerSecond)
        m_second = Int32(seconds % UInt32(WTF.secondsPerMinute))
        let minutes = seconds / UInt32(WTF.secondsPerMinute)
        m_minute = Int32(minutes % UInt32(WTF.minutesPerHour))
        m_hour = Int32(minutes / UInt32(WTF.minutesPerHour))
    }

    // The milliseconds since midnight of `ms`, a whole number. For a magnitude of 2^53 or more, it is positiveFmod()'s:
    // fmod() of a whole number is exact, and adding msPerDay to a negative remainder, a whole number above -msPerDay,
    // is exact too. A remainder of -0 converts to 0.
    private static func millisecondsInDay(_ ms: Double) -> UInt32 {
        if let day = daysAndMillisecondsInDay(ms) {
            return day.msInDay
        }
        return UInt32(positiveFmod(ms, WTF.msPerDay))
    }

    // `ms` is a whole number of milliseconds.
    private mutating func setMillisecondsSinceEpochForDateInternal(_ ms: Double) -> Bool {
        guard let day = daysAndMillisecondsInDay(ms) else {
            return setMillisecondsSinceEpochForDateInternalWithDoubles(ms)
        }
        (m_year, m_month, m_monthDay) = dateFromDaysFrom1970(day.days)
        return true
    }

    // setMillisecondsSinceEpochForDateInternal() for a whole `ms` of 2^53 or more in magnitude, in DateComponents.cpp's
    // double arithmetic.
    @inline(never)
    private mutating func setMillisecondsSinceEpochForDateInternalWithDoubles(_ ms: Double) -> Bool {
        guard let year = yearOfMillisecondsSinceEpoch(ms) else {
            return false
        }
        m_year = year
        let yearDay = dayInYear(ms, m_year)
        m_month = monthFromDayInYear(yearDay, isLeapYear(m_year))
        m_monthDay = dayInMonthFromDayInYear(yearDay, isLeapYear(m_year))
        return true
    }

    // For Date type. Updates m_year, m_month and m_monthDay.
    fileprivate mutating func setMillisecondsSinceEpochForDate(_ ms: Double) -> Bool {
        m_type = .Invalid
        if !ms.isFinite {
            return false
        }
        if !setMillisecondsSinceEpochForDateInternal(ms.rounded()) {
            return false
        }
        if !withinHTMLDateLimits(m_year, m_month, m_monthDay) {
            return false
        }
        m_type = .Date
        return true
    }

    // For DateTimeLocal type. Updates m_year, m_month, m_monthDay, m_hour, m_minute, m_second and m_millisecond.
    fileprivate mutating func setMillisecondsSinceEpochForDateTimeLocal(_ ms: Double) -> Bool {
        m_type = .Invalid
        if !ms.isFinite {
            return false
        }
        let ms = ms.rounded()
        if let day = daysAndMillisecondsInDay(ms) {
            setMillisecondsSinceMidnightInternal(day.msInDay)
            (m_year, m_month, m_monthDay) = dateFromDaysFrom1970(day.days)
        } else {
            setMillisecondsSinceMidnightInternal(Self.millisecondsInDay(ms))
            if !setMillisecondsSinceEpochForDateInternalWithDoubles(ms) {
                return false
            }
        }
        if !withinHTMLDateLimits(m_year, m_month, m_monthDay, m_hour, m_minute, m_second, m_millisecond) {
            return false
        }
        m_type = .DateTimeLocal
        return true
    }

    // For Month type. Updates m_year and m_month.
    fileprivate mutating func setMillisecondsSinceEpochForMonth(_ ms: Double) -> Bool {
        m_type = .Invalid
        if !ms.isFinite {
            return false
        }
        if !setMillisecondsSinceEpochForDateInternal(ms.rounded()) {
            return false
        }
        if !withinHTMLDateLimits(m_year, m_month) {
            return false
        }
        m_type = .Month
        return true
    }

    // For Time type. Updates m_hour, m_minute, m_second and m_millisecond.
    fileprivate mutating func setMillisecondsSinceMidnight(_ ms: Double) -> Bool {
        m_type = .Invalid
        if !ms.isFinite {
            return false
        }
        setMillisecondsSinceMidnightInternal(Self.millisecondsInDay(ms.rounded()))
        m_type = .Time
        return true
    }

    // Another initializer for Month type. Updates m_year and m_month.
    fileprivate mutating func setMonthsSinceEpoch(_ months: Double) -> Bool {
        if !months.isFinite {
            return false
        }
        let months = months.rounded()
        let doubleMonth = positiveFmod(months, 12)
        let doubleYear = 1970 + (months - doubleMonth) / 12
        if doubleYear < Double(minimumYearNumber) || Double(maximumYearNumber) < doubleYear {
            return false
        }
        let year = Int32(doubleYear)
        let month = Int32(doubleMonth)
        if !withinHTMLDateLimits(year, month) {
            return false
        }
        m_year = year
        m_month = month
        m_type = .Month
        return true
    }

    // For Week type. Updates m_year and m_week.
    fileprivate mutating func setMillisecondsSinceEpochForWeek(_ ms: Double) -> Bool {
        m_type = .Invalid
        if !ms.isFinite {
            return false
        }
        // A whole number of milliseconds of 2^53 or more in magnitude is in a year after 287000 or before -283000,
        // outside the limits below.
        guard let days = daysAndMillisecondsInDay(ms.rounded())?.days else {
            return false
        }

        m_year = dateFromDaysFrom1970(days).year
        if m_year < minimumYearNumber || m_year > maximumYearNumber {
            return false
        }

        // A day of the year, 0 to 365.
        let yearDay = Int32(days - daysFrom1970ToYear(m_year))
        let offset = offsetTo1stWeekStart(m_year)
        if yearDay < offset {
            // The day belongs to the last week of the previous year.
            m_year -= 1
            if m_year <= minimumYearNumber {
                return false
            }
            m_week = maxWeekNumberInYear(m_year)
        } else {
            // Cannot overflow: yearDay is a day of the year, 0 to 365, and offset is -3 to 3.
            m_week = ((yearDay &- offset) / 7) + 1
            if m_week > maxWeekNumberInYear(m_year) {
                m_year += 1
                m_week = 1
            }
            if m_year > maximumYearNumber || (m_year == maximumYearNumber && m_week > maximumWeekInMaximumYear) {
                return false
            }
        }
        m_type = .Week
        return true
    }

    // Helper for millisecondsSinceEpochForType().
    private func millisecondsSinceEpochForTime() -> Double {
        assert(m_type == .Time || m_type == .DateTimeLocal)
        return ((Double(m_hour) * WTF.minutesPerHour + Double(m_minute)) * WTF.secondsPerMinute + Double(m_second)) * WTF.msPerSecond
            + Double(m_millisecond)
    }

    // Returns the number of milliseconds from 1970-01-01 00:00:00 UTC. Inlined into
    // dateComponentsMillisecondsSinceEpoch(), so that DateComponents::millisecondsSinceEpoch() can tail-call it.
    @inline(always)
    fileprivate func millisecondsSinceEpochForType() -> Double {
        switch m_type {
        case .Date:
            return Double(dateToDaysFrom1970(m_year, m_month, m_monthDay)) * WTF.msPerDay
        case .DateTimeLocal:
            return Double(dateToDaysFrom1970(m_year, m_month, m_monthDay)) * WTF.msPerDay + millisecondsSinceEpochForTime()
        case .Month:
            return Double(dateToDaysFrom1970(m_year, m_month, 1)) * WTF.msPerDay
        case .Time:
            return millisecondsSinceEpochForTime()
        case .Week:
            // Cannot overflow: a week number is 1 to 53. The sum is below 2^42 in magnitude, which a double holds
            // exactly, as it holds each of DateComponents.cpp's double sums.
            return Double(dateToDaysFrom1970(m_year, 0, 1) + Int64(offsetTo1stWeekStart(m_year)) + Int64((m_week &- 1) &* 7)) * WTF.msPerDay
        case .Invalid:
            break
        @unknown default:
            break
        }
        assertionFailure()
        return Self.invalidMilliseconds()
    }

    // Returns the number of months from 1970-01.
    fileprivate func monthsSinceEpochForMonth() -> Double {
        assert(m_type == .Month)
        // Wraps from 178958940-09 on, as DateComponents.cpp's int arithmetic does, to a wrong, negative count:
        // fromMillisecondsSinceEpochForMonth() accepts years above maximumYear().
        return Double((m_year &- 1970) &* 12 &+ m_month)
    }

    private func appendYearAndMonth(to characters: inout DateComponentsCharacters) {
        characters.append(m_year, paddedTo: 4)
        characters.append("-")
        // Cannot overflow: a month is 0 to 11.
        characters.append(m_month &+ 1, paddedTo: 2)
    }

    private func appendTime(to characters: inout DateComponentsCharacters, _ format: UInt8) {
        assert(m_type == .DateTimeLocal || m_type == .Time)
        var effectiveFormat = format
        if m_millisecond != 0 {
            effectiveFormat = WebCore.SecondFormat.Millisecond.rawValue
        } else if format == WebCore.SecondFormat.None.rawValue && m_second != 0 {
            effectiveFormat = WebCore.SecondFormat.Second.rawValue
        }

        characters.append(m_hour, paddedTo: 2)
        characters.append(":")
        characters.append(m_minute, paddedTo: 2)
        if effectiveFormat == WebCore.SecondFormat.Second.rawValue {
            characters.append(":")
            characters.append(m_second, paddedTo: 2)
        } else if effectiveFormat == WebCore.SecondFormat.Millisecond.rawValue {
            characters.append(":")
            characters.append(m_second, paddedTo: 2)
            characters.append(".")
            if m_millisecond % 100 == 0 {
                characters.append(m_millisecond / 100)
            } else if m_millisecond % 10 == 0 {
                characters.append(m_millisecond / 10, paddedTo: 2)
            } else {
                characters.append(m_millisecond, paddedTo: 3)
            }
        } else if effectiveFormat != WebCore.SecondFormat.None.rawValue {
            // Any other value is written as None.
            assertionFailure()
        }
    }

    // Writes an ISO 8601 representation for this instance.
    // The format argument is valid for DateTimeLocal and Time types.
    fileprivate func append(to characters: inout DateComponentsCharacters, _ format: UInt8) {
        switch m_type {
        case .Date:
            appendYearAndMonth(to: &characters)
            characters.append("-")
            characters.append(m_monthDay, paddedTo: 2)
            return
        case .DateTimeLocal:
            appendYearAndMonth(to: &characters)
            characters.append("-")
            characters.append(m_monthDay, paddedTo: 2)
            characters.append("T")
            appendTime(to: &characters, format)
            return
        case .Month:
            appendYearAndMonth(to: &characters)
            return
        case .Time:
            appendTime(to: &characters, format)
            return
        case .Week:
            characters.append(m_year, paddedTo: 4)
            characters.append("-")
            characters.append("W")
            characters.append(m_week, paddedTo: 2)
            return
        case .Invalid:
            break
        @unknown default:
            break
        }
        assertionFailure()
        for character in "(Invalid DateComponents)".unicodeScalars {
            characters.append(character)
        }
    }
}

private func positiveFmod(_ value: Double, _ divider: Double) -> Double {
    let remainder = value.truncatingRemainder(dividingBy: divider)
    return remainder < 0 ? remainder + divider : remainder
}

// MARK: Date arithmetic

// The functions of WTF's DateMath.h that DateComponents uses, so that they inline here. Their literals are DateMath's.
// They keep its double and int arithmetic in the same order, except that a count of days is an Int64: DateMath's
// doubles hold the same whole numbers, below 2^42 in magnitude, exactly.

@inline(always)
private func isLeapYear(_ year: Int32) -> Bool {
    if year % 4 != 0 {
        return false
    }
    if year % 400 == 0 {
        return true
    }
    if year % 100 == 0 {
        return false
    }
    return true
}

@inline(always)
private func daysInYear(_ year: Int32) -> Int32 {
    365 + (isLeapYear(year) ? 1 : 0)
}

// `dividend / divisor` rounded down, for a positive divisor.
@inline(always)
private func flooredQuotient(_ dividend: Int64, _ divisor: Int64) -> Int64 {
    let quotient = dividend / divisor
    return dividend % divisor < 0 ? quotient - 1 : quotient
}

// DateMath's floor() of a quotient of a whole number below 2^32 in magnitude by 4, 100 or 400 is the floored quotient:
// a quotient that is not whole is at least 1/400 from a whole number, much more than its rounding error.
@inline(always)
private func daysFrom1970ToYear(_ year: Int32) -> Int64 {
    // The Gregorian Calendar rules for leap years:
    // Every fourth year is a leap year. 2004, 2008, and 2012 are leap years.
    // However, every hundredth year is not a leap year. 1900 and 2100 are not leap years.
    // Every four hundred years, there's a leap year after all. 2000 and 2400 are leap years.

    let leapDaysBefore1971By4Rule: Int64 = 1970 / 4
    let excludedLeapDaysBefore1971By100Rule: Int64 = 1970 / 100
    let leapDaysBefore1971By400Rule: Int64 = 1970 / 400

    let yearMinusOne = Int64(year) - 1
    let yearsToAddBy4Rule = flooredQuotient(yearMinusOne, 4) - leapDaysBefore1971By4Rule
    let yearsToExcludeBy100Rule = flooredQuotient(yearMinusOne, 100) - excludedLeapDaysBefore1971By100Rule
    let yearsToAddBy400Rule = flooredQuotient(yearMinusOne, 400) - leapDaysBefore1971By400Rule

    return 365 * (Int64(year) - 1970) + yearsToAddBy4Rule - yearsToExcludeBy100Rule + yearsToAddBy400Rule
}

@inline(always)
private func msToDays(_ ms: Double) -> Double {
    (ms / WTF.msPerDay).rounded(.down)
}

// WTF::firstDayOfMonth (DateMath.cpp): the day of the year each month starts on, in a common year and in a leap year.
private let firstDayOfMonth: [2 of [12 of Int32]] = [
    [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334],
    [0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335],
]

// 'month' is 0-based.
@inline(always)
private func dayInYear(_ year: Int32, _ month: Int32, _ day: Int32) -> Int32 {
    // Wraps as DateMath's int arithmetic does, though a DateComponents' day of the month, 1 to 31, never makes it.
    firstDayOfMonth[isLeapYear(year) ? 1 : 0][Int(month)] &+ day &- 1
}

// The day of its year that `ms` is in, where `year` is msToYear(ms): the result is 0 to 365, in Int32's range.
@inline(always)
private func dayInYear(_ ms: Double, _ year: Int32) -> Int32 {
    let result = msToDays(ms) - Double(daysFrom1970ToYear(year))
    return result.isNaN ? 0 : Int32(result)
}

// Returns the number of days from 1970-01-01 to the specified date.
@inline(always)
private func dateToDaysFrom1970(_ year: Int32, _ month: Int32, _ day: Int32) -> Int64 {
    var year = year
    var month = month
    // Wraps as DateMath's int arithmetic does, though a DateComponents' month, 0 to 11, never makes it.
    year &+= month / 12

    month %= 12
    if month < 0 {
        month += 12
        // Wraps as DateMath's int arithmetic does, though no DateComponents' month is negative.
        year &-= 1
    }

    // DateMath's floor() of this whole number is the same number.
    let yearday = daysFrom1970ToYear(year)
    assert((year >= 1970 && yearday >= 0) || (year < 1970 && yearday < 0))
    return yearday + Int64(dayInYear(year, month, day))
}

// The days from 1970-01-01 to the day that `ms`, a whole number of milliseconds, is in, and the milliseconds since that
// day's midnight, or nil where the magnitude of `ms` is 2^53 or more. Below 2^53, these are the day and time that the
// double arithmetic of DateComponents.cpp and DateMath finds.
@inline(always)
private func daysAndMillisecondsInDay(_ ms: Double) -> (days: Int64, msInDay: UInt32)? {
    guard let wholeMs = Int64(exactly: ms), wholeMs > -(1 << 53), wholeMs < 1 << 53 else {
        return nil
    }
    let msPerDay = Int64(WTF.msPerDay)
    let quotient = wholeMs / msPerDay
    let remainder = wholeMs % msPerDay
    if remainder < 0 {
        return (quotient - 1, UInt32(remainder + msPerDay))
    }
    return (quotient, UInt32(remainder))
}

// The year, 0-based month and day of the month of the day `days` days after 1970-01-01, for `days` of magnitude below
// 2^27, as msToYear(), dayInYear(), monthFromDayInYear() and dayInMonthFromDayInYear() find them. This is
// civil_from_days() of https://howardhinnant.github.io/date_algorithms.html, with 1000 cycles of 400 years added so
// that no dividend is negative.
@inline(always)
private func dateFromDaysFrom1970(_ days: Int64) -> (year: Int32, month: Int32, monthDay: Int32) {
    let daysIn400Years: Int64 = 146_097
    let shiftedDays = days + 719_468 + 1000 * daysIn400Years
    let cycle = shiftedDays / daysIn400Years
    let dayOfCycle = shiftedDays % daysIn400Years
    // The year of the cycle, 0 to 399, and its day, 0 to 365, of years that start on March 1.
    let yearOfCycle = (dayOfCycle - dayOfCycle / 1460 + dayOfCycle / 36_524 - dayOfCycle / (daysIn400Years - 1)) / 365
    let dayOfYear = dayOfCycle - (365 * yearOfCycle + yearOfCycle / 4 - yearOfCycle / 100)
    // 0 is March, and 11 February.
    let monthFromMarch = (5 * dayOfYear + 2) / 153
    let monthDay = dayOfYear - (153 * monthFromMarch + 2) / 5 + 1
    let month = monthFromMarch < 10 ? monthFromMarch + 2 : monthFromMarch - 10
    let year = 400 * (cycle - 1000) + yearOfCycle + (month < 2 ? 1 : 0)
    return (Int32(year), Int32(month), Int32(monthDay))
}

// WTF::msToYear() of `ms`, a finite whole number of milliseconds, or nil where msToYear() is undefined. It converts
// floor(ms / (msPerDay * 365.2425)) + 1970 to int, where msPerDay * 365.2425 is 31556952000, and that is out of
// int's range exactly for ms below -6.7768100567916339e19, where the quotient is below INT_MIN - 1970, and from
// 6.7767976233525453e19, where it reaches INT_MAX - 1969. Between them, the year it then steps to is in int's range
// too: year INT_MIN starts before the lower bound, and year INT_MAX ends after the upper one. msToYear()'s case of a
// NaN quotient does not arise.
@inline(always)
private func yearOfMillisecondsSinceEpoch(_ ms: Double) -> Int32? {
    if !(ms >= -6.7768100567916339e19 && ms < 6.7767976233525453e19) {
        return nil
    }
    let msAsYears = (ms / (WTF.msPerDay * 365.2425)).rounded(.down)
    let approxYear = Int32(msAsYears + 1970)
    let msFromApproxYearTo1970 = WTF.msPerDay * Double(daysFrom1970ToYear(approxYear))
    if msFromApproxYearTo1970 > ms {
        // Cannot overflow: year INT_MIN starts before the lower bound.
        return approxYear &- 1
    }
    if msFromApproxYearTo1970 + WTF.msPerDay * Double(daysInYear(approxYear)) <= ms {
        // Cannot overflow: year INT_MAX ends after the upper bound.
        return approxYear &+ 1
    }
    return approxYear
}

// 'dayInYear' is 0-based. Returns a 0-based month.
@inline(always)
private func monthFromDayInYear(_ dayInYear: Int32, _ leapYear: Bool) -> Int32 {
    let d = dayInYear
    var step: Int32 = 31

    if d < step {
        return 0
    }
    step += leapYear ? 29 : 28
    if d < step {
        return 1
    }
    step += 31
    if d < step {
        return 2
    }
    step += 30
    if d < step {
        return 3
    }
    step += 31
    if d < step {
        return 4
    }
    step += 30
    if d < step {
        return 5
    }
    step += 31
    if d < step {
        return 6
    }
    step += 31
    if d < step {
        return 7
    }
    step += 30
    if d < step {
        return 8
    }
    step += 31
    if d < step {
        return 9
    }
    if d < step + 30 {
        return 10
    }
    return 11
}

// 'dayInYear' is 0-based. Returns the 1-based day of the month.
@inline(always)
private func dayInMonthFromDayInYear(_ dayInYear: Int32, _ leapYear: Bool) -> Int32 {
    func checkMonth(
        _ dayInYear: Int32,
        _ startDayOfThisMonth: inout Int32,
        _ startDayOfNextMonth: inout Int32,
        _ daysInThisMonth: Int32
    ) -> Bool {
        startDayOfThisMonth = startDayOfNextMonth
        startDayOfNextMonth += daysInThisMonth
        return dayInYear <= startDayOfNextMonth
    }

    let d = dayInYear
    var step: Int32 = 0
    var next: Int32 = 30

    if d <= next {
        return d + 1
    }
    let daysInFeb: Int32 = leapYear ? 29 : 28
    if checkMonth(d, &step, &next, daysInFeb) {
        return d - step
    }
    if checkMonth(d, &step, &next, 31) {
        return d - step
    }
    if checkMonth(d, &step, &next, 30) {
        return d - step
    }
    if checkMonth(d, &step, &next, 31) {
        return d - step
    }
    if checkMonth(d, &step, &next, 30) {
        return d - step
    }
    if checkMonth(d, &step, &next, 31) {
        return d - step
    }
    if checkMonth(d, &step, &next, 31) {
        return d - step
    }
    if checkMonth(d, &step, &next, 30) {
        return d - step
    }
    if checkMonth(d, &step, &next, 31) {
        return d - step
    }
    if checkMonth(d, &step, &next, 30) {
        return d - step
    }
    step = next
    return d - step
}

// MARK: Serialization

// The ASCII characters of a date or time string. The longest DateComponents::toString() makes has 29, a local date
// and time with milliseconds in a 10-digit year ("2000000000-01-15T12:34:26.944"): the conversions from milliseconds
// accept years above maximumYear().
private struct DateComponentsCharacters {
    private var characters: [32 of UInt8] = .init(repeating: 0)
    private var length = 0

    @inline(always)
    mutating func append(_ character: Unicode.Scalar) {
        characters[length] = UInt8(ascii: character)
        length += 1
    }

    // Appends `number` in decimal, after as many zeros as make it `width` characters, as pad('0', width, number) in
    // makeString() does.
    mutating func append(_ number: Int32, paddedTo width: Int = 0) {
        let magnitude = number.magnitude
        var digitCount = 1
        var remaining = magnitude / 10
        while remaining != 0 {
            // Cannot overflow: an Int32 has at most 10 digits.
            digitCount &+= 1
            remaining /= 10
        }

        // Cannot overflow: width is at most 4, and an Int32 has at most 10 digits.
        var zeros = width &- digitCount &- (number < 0 ? 1 : 0)
        while zeros > 0 {
            append("0")
            zeros -= 1
        }
        if number < 0 {
            append("-")
        }

        // Cannot overflow: length is at most the capacity, 32.
        var position = length &+ digitCount
        length = position
        remaining = magnitude
        repeat {
            // Cannot overflow: position stays above the index of the first digit.
            position &-= 1
            characters[position] = UInt8(truncatingIfNeeded: remaining % 10) + 0x30
            remaining /= 10
        } while remaining != 0
    }

    func makeString() -> WTF.String {
        WTF.String(WTF.latin1CharactersOfBytes(characters.span.extracting(0..<length)))
    }
}
