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

internal import JSCSwiftBoundary

// JSC Temporal Core — ISO 8601 date arithmetic
// temporal_rs reference: src/iso.rs
// Last synced: v0.2.3

extension TemporalOperations {
    // BalanceISOYearMonth — temporal_rs: balance_iso_year_month_with_clamp — uses i64 + div_euclid/rem_euclid
    // https://tc39.es/proposal-temporal/#sec-temporal-balanceisoyearmonth
    static func balanceISOYearMonth(_ year: Int64, _ month: Int64) -> JSC.ISO8601.PlainYearMonth {
        // 1. Set year to year + floor((month - 1) / 12).
        // NOTE: integer division truncates toward zero; apply floor correction for negative month-1.
        // Wraps for month = Int64.min.
        let m0 = month &- 1
        var yearAdd = m0 / Int64(JSC.ISO8601.monthsPerYear)
        var newM0 = m0 % Int64(JSC.ISO8601.monthsPerYear)
        if newM0 < 0 {
            yearAdd -= 1
            newM0 += Int64(JSC.ISO8601.monthsPerYear) // adjust for truncation toward zero; newM0 is in [-11, -1].
        }
        // Wraps for a year near the Int64 limits.
        let balancedYear = year &+ yearAdd
        // 2. Set month to ((month - 1) modulo 12) + 1.
        let balancedMonth = newM0 + 1
        // 3. Return ISO Year-Month Record { [[Year]]: year, [[Month]]: month }.
        return JSC.ISO8601.PlainYearMonth(
            consuming: JSC.ISO8601.PlainDate(balancedYear, UInt32(truncatingIfNeeded: balancedMonth), 1)
        )
    }

    // AddDaysToISODate — temporal_rs: IsoDate::balance (with implicit day fold-in)
    // https://tc39.es/proposal-temporal/#sec-temporal-adddaystoisodate
    static func addDaysToISODate(_ date: JSC.ISO8601.PlainDate, _ days: Int64) -> JSC.ISO8601.PlainDate {
        let year = date.year()
        let month = Int32(date.month())
        if year == JSC.ISO8601.outOfRangeYear {
            return JSC.ISO8601.PlainDate.sentinel()
        }

        // PlainDate's month invariant (set by regulateISODate / balanceISOYearMonth at every
        // construction site reachable from public Temporal entry points) is [1, 12]. We rely
        // on it for the daysInMonth bound below and for the makeDay(month-1) slow-path math.
        assert(month >= 1 && month <= 12)

        // Wraps for days near Int64.max.
        let newDay = Int64(date.day()) &+ days

        // The new day-of-month already lands in [1, daysInMonth(year, month)] - no overflow into
        // adjacent months/years, so skip the days-from-1970 + yearMonthDayFromDays roundtrip.
        if newDay >= 1 && (newDay <= 31 && newDay <= Int64(TemporalISO8601.daysInMonth(year, UInt8(truncatingIfNeeded: month)))) {
            return JSC.ISO8601.PlainDate(year, UInt32(truncatingIfNeeded: month), UInt32(truncatingIfNeeded: newDay))
        }

        // 1. Let epochDays be ISODateToEpochDays(year, month - 1, day).
        // (WTF makeDay takes 0-based month, matching ISODateToEpochDays(year, month-1, day))
        let epochDays = JSC.makeDay(Double(year), Double(month - 1), Double(newDay))
        // 2. Let ms be EpochDaysToEpochMs(epochDays, 0).
        let ms = JSC.makeDate(epochDays, 0)
        let daysToUse = WTF.msToDays(ms)
        // yearMonthDayFromDays adds a ~1.47e8 day offset internally, so its domain is narrower than its
        // int32_t parameter. Real dates are within 1e8 days of the epoch, so this excludes nothing.
        let maxSafeEpochDays = 1e9
        if abs(daysToUse) > maxSafeEpochDays {
            return JSC.ISO8601.PlainDate.sentinel()
        }
        // 3. Return CreateISODateRecord(EpochTimeToEpochYear(ms), EpochTimeToMonthInYear(ms) + 1, EpochTimeToDate(ms)).
        // |daysToUse| <= 1e9 here, and it is never NaN: year and month - 1 are integers, so makeDay is finite.
        let ymd = JSC.temporalYearMonthDayFromDays(Int32(daysToUse))
        if !JSC.ISO8601.isYearWithinLimits(ymd.year) {
            return JSC.ISO8601.PlainDate.sentinel()
        }
        // Cannot overflow: ymd.month is a month index in [0, 11].
        return JSC.ISO8601.PlainDate(ymd.year, UInt32(truncatingIfNeeded: ymd.month &+ 1), UInt32(truncatingIfNeeded: ymd.day))
    }

    /// RegulateISODate's ~constrain~ branch (steps 1.a-1.c and 3), which cannot fail. `diffISODate` uses it in place
    /// of `regulateISODate(…, Constrain)`.
    private static func constrainISODate(_ year: Int32, _ month: Int32, _ day: Int64) -> JSC.ISO8601.PlainDate {
        var month = month
        var day = day
        // a. Set month to the result of clamping month between 1 and 12.
        if month < 1 {
            month = 1
        } else if month > 12 {
            month = 12
        }
        // b. Let daysInMonth be ISODaysInMonth(year, month).
        let maxDay = Int64(TemporalISO8601.daysInMonth(year, UInt8(truncatingIfNeeded: month)))
        // c. Set day to the result of clamping day between 1 and daysInMonth.
        if day < 1 {
            day = 1
        } else if day > maxDay {
            day = maxDay
        }
        // 3. Return CreateISODateRecord(year, month, day).
        return JSC.ISO8601.PlainDate(year, UInt32(truncatingIfNeeded: month), UInt32(truncatingIfNeeded: day))
    }

    // RegulateISODate — temporal_rs: IsoDate::regulate (overflow constrain/reject)
    // https://tc39.es/proposal-temporal/#sec-temporal-regulateisodate
    @inline(always)
    static func regulateISODate(
        _ year: Int32,
        _ month: Int32,
        _ day: Int64,
        _ overflow: JSC.TemporalOverflow
    ) -> TemporalOutcome<JSC.ISO8601.PlainDate> {
        // 1. If overflow is ~constrain~, then
        if overflow == .Constrain {
            return .success(constrainISODate(year, month, day))
        }
        // 2.a. Assert: overflow is ~reject~.
        // 2.b. If IsValidISODate(year, month, day) is false, throw a RangeError exception.
        if month < 1 || month > 12
            || day < 1 || day > Int64(TemporalISO8601.daysInMonth(year, UInt8(truncatingIfNeeded: month)))
        {
            return .failure(.range("date time is out of range of ECMAScript representation"))
        }
        // 3. Return CreateISODateRecord(year, month, day).
        return .success(JSC.ISO8601.PlainDate(year, UInt32(truncatingIfNeeded: month), UInt32(truncatingIfNeeded: day)))
    }

    // AddISODate (ISO8601 path of CalendarDateAdd) — temporal_rs: IsoDate::add_date_duration — uses i64 arithmetic throughout
    // https://tc39.es/proposal-temporal/#sec-temporal-calendardateadd
    @inline(always)
    static func isoDateAdd(
        _ plainDate: JSC.ISO8601.PlainDate,
        _ duration: JSC.ISO8601.Duration,
        _ overflow: JSC.TemporalOverflow
    ) -> TemporalOutcome<JSC.ISO8601.PlainDate> {
        // 1.a. Let intermediate be BalanceISOYearMonth(isoDate.[[Year]] + duration.[[Years]], isoDate.[[Month]] + duration.[[Months]]).
        // Both sums wrap for a duration field near the Int64 limits.
        let years = Int64(plainDate.year()) &+ duration.years()
        let months = Int64(plainDate.month()) &+ duration.months()
        let intermediate = balanceISOYearMonth(years, months)
        // 1.b. Set intermediate to ? RegulateISODate(intermediate.[[Year]], intermediate.[[Month]], isoDate.[[Day]], overflow).
        guard
            case .success(let intermediate1) = regulateISODate(
                intermediate.year(),
                Int32(intermediate.month()),
                Int64(plainDate.day()),
                overflow
            )
        else {
            return .failure(.range("date time is out of range of ECMAScript representation"))
        }
        // 1.c. Let days be duration.[[Days]] + 7 × duration.[[Weeks]].
        // 1.d. Let result be AddDaysToISODate(intermediate, days).
        // Wraps for large weeks/days.
        let days = duration.days() &+ Int64(JSC.ISO8601.daysPerWeek) &* duration.weeks()
        let result = addDaysToISODate(intermediate1, days)
        // 3. If ISODateWithinLimits(result) is false, throw a RangeError exception.
        if !TemporalISO8601.isDateTimeWithinLimits(result.year(), result.month(), result.day(), 12, 0, 0, 0, 0, 0) {
            return .failure(.range("date time is out of range of ECMAScript representation"))
        }
        // 4. Return result.
        return .success(result)
    }

    /// `TemporalCore::calendarDateAdd(CalendarID, …)`. The ISO 8601 calendar, and a duration without years or
    /// months, give `isoDateAdd`'s result; every other case calls `TemporalCore::calendarDateAdd`.
    @inline(never)
    static func calendarDateAdd(
        _ calendarId: JSC.CalendarID,
        _ date: JSC.ISO8601.PlainDate,
        _ duration: JSC.ISO8601.Duration,
        _ overflow: JSC.TemporalOverflow
    ) -> TemporalOutcome<JSC.ISO8601.PlainDate> {
        if calendarId == JSC.iso8601CalendarID() || (duration.years() == 0 && duration.months() == 0) {
            return isoDateAdd(date, duration, overflow)
        }
        let result = JSC.TemporalCore.calendarDateAdd(calendarId, date, duration, overflow)
        if !result.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(result)))
        }
        return .success(JSC.temporalValueOf(result) as JSC.ISO8601.PlainDate)
    }

    /// `TemporalCore::calendarDateUntil(CalendarID, …)`. Equal dates give the zero duration, and the ISO 8601
    /// calendar or a largest unit of day or week give `diffISODate`'s result; every other case calls
    /// `TemporalCore::calendarDateUntil`.
    @inline(never)
    static func calendarDateUntil(
        _ calendarId: JSC.CalendarID,
        _ one: JSC.ISO8601.PlainDate,
        _ two: JSC.ISO8601.PlainDate,
        _ largestUnit: JSC.TemporalUnit
    ) -> TemporalOutcome<JSC.ISO8601.Duration> {
        assert(largestUnit == .Year || largestUnit == .Month || largestUnit == .Week || largestUnit == .Day)
        // Steps 1-2: sign = -CompareISODate(one, two); if sign = 0, return the zero duration.
        if isoDateCompare(one, two) == 0 {
            return .success(JSC.ISO8601.Duration())
        }
        if calendarId == JSC.iso8601CalendarID() || largestUnit == .Day || largestUnit == .Week {
            return .success(diffISODate(one, two, largestUnit))
        }
        let result = JSC.TemporalCore.calendarDateUntil(calendarId, one, two, largestUnit)
        if !result.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(result)))
        }
        return .success(JSC.temporalValueOf(result) as JSC.ISO8601.Duration)
    }

    // CompareISODate — temporal_rs: IsoDate::cmp
    // https://tc39.es/proposal-temporal/#sec-temporal-compareisodate
    static func isoDateCompare(_ d1: JSC.ISO8601.PlainDate, _ d2: JSC.ISO8601.PlainDate) -> Int32 {
        if d1.year() > d2.year() {
            return 1
        }
        if d1.year() < d2.year() {
            return -1
        }
        if d1.month() > d2.month() {
            return 1
        }
        if d1.month() < d2.month() {
            return -1
        }
        if d1.day() > d2.day() {
            return 1
        }
        if d1.day() < d2.day() {
            return -1
        }
        return 0
    }

    // CompareTimeRecord — temporal_rs: IsoTime::cmp (derived Ord, src/iso.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-comparetimerecord
    static func isoTimeCompare(_ t1: JSC.ISO8601.PlainTime, _ t2: JSC.ISO8601.PlainTime) -> Int32 {
        if t1.hour() != t2.hour() {
            return t1.hour() > t2.hour() ? 1 : -1
        }
        if t1.minute() != t2.minute() {
            return t1.minute() > t2.minute() ? 1 : -1
        }
        if t1.second() != t2.second() {
            return t1.second() > t2.second() ? 1 : -1
        }
        if t1.millisecond() != t2.millisecond() {
            return t1.millisecond() > t2.millisecond() ? 1 : -1
        }
        if t1.microsecond() != t2.microsecond() {
            return t1.microsecond() > t2.microsecond() ? 1 : -1
        }
        if t1.nanosecond() != t2.nanosecond() {
            return t1.nanosecond() > t2.nanosecond() ? 1 : -1
        }
        return 0
    }

    // ISODateSurpasses — temporal_rs: iso_date_surpasses (src/iso.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-isodatesurpasses
    // The `&-`/`&*` cannot overflow: years are within ±2^22 (a PlainDate's 21-bit year plus a difference of two),
    // months and days are below 256, and sign is -1 or 1.
    private static func isoDateSurpasses(_ sign: Int32, _ y1: Int32, _ m1: Int32, _ d1: Int32, _ isoDate2: JSC.ISO8601.PlainDate) -> Bool {
        if y1 != isoDate2.year() {
            return sign &* (y1 &- isoDate2.year()) > 0
        }
        if m1 != Int32(isoDate2.month()) {
            return sign &* (m1 &- Int32(isoDate2.month())) > 0
        }
        if d1 != Int32(isoDate2.day()) {
            return sign &* (d1 &- Int32(isoDate2.day())) > 0
        }
        return false
    }

    // DiffISODate — temporal_rs: IsoDate::diff_iso_date
    // https://tc39.es/proposal-temporal/#sec-temporal-calendardateuntil step 3, the iso8601 branch.
    // Int32 `&+`/`&-`/`&*` below cannot overflow: years and their differences are within ±2^22, month counts within
    // ±2^27, and sign is -1 or 1 (as for isoDateSurpasses).
    static func diffISODate(
        _ one: JSC.ISO8601.PlainDate,
        _ two: JSC.ISO8601.PlainDate,
        _ largestUnit: JSC.TemporalUnit
    ) -> JSC.ISO8601.Duration {
        // 1. Let sign be CompareISODate(one, two).
        // 3.a. Set sign to -sign.  (combined: negate upfront, zero check is equivalent since -0 = 0)
        let sign = 0 &- isoDateCompare(one, two) // Cannot overflow: the comparison is -1, 0 or 1.
        // 2. If sign = 0, return ZeroDateDuration().
        if sign == 0 {
            return JSC.ISO8601.Duration()
        }

        // 3.b. Let years be 0.
        var years: Int32 = 0
        // 3.d. Let months be 0.
        var months: Int32 = 0

        // 3.c. If largestUnit is ~year~, then
        // 3.e. If largestUnit is either ~year~ or ~month~, then
        // NOTE: polyfill optimization runs year loop for both ~year~ and ~month~, then folds into months below.
        if largestUnit == .Year || largestUnit == .Month {
            // NOTE: candidateYears starts at two.year()-one.year() instead of sign (polyfill optimization, saves iterations).
            // 3.c.i. Let candidateYears be sign.
            var candidateYears = two.year() &- one.year()
            if candidateYears != 0 {
                candidateYears &-= sign
            }
            // 3.c.ii. Repeat, while ISODateSurpasses(sign, one, two, candidateYears, 0, 0, 0) is false,
            while !isoDateSurpasses(sign, one.year() &+ candidateYears, Int32(one.month()), Int32(one.day()), two) {
                // 1. Set years to candidateYears.
                years = candidateYears
                // 2. Set candidateYears to candidateYears + sign.
                candidateYears &+= sign
            }

            // 3.e.i. Let candidateMonths be sign.
            var candidateMonths = sign
            // 3.e.ii. Repeat, while ISODateSurpasses(sign, one, two, years, candidateMonths, 0, 0) is false,
            var intermediate = balanceISOYearMonth(Int64(one.year() &+ years), Int64(one.month()) + Int64(candidateMonths))
            while !isoDateSurpasses(sign, intermediate.year(), Int32(intermediate.month()), Int32(one.day()), two) {
                // 1. Set months to candidateMonths.
                months = candidateMonths
                // 2. Set candidateMonths to candidateMonths + sign.
                candidateMonths &+= sign
                // 3. Set intermediate to BalanceISOYearMonth(intermediate.[[Year]], intermediate.[[Month]] + sign).
                intermediate = balanceISOYearMonth(Int64(intermediate.year()), Int64(intermediate.month()) + Int64(sign))
            }

            // Fold years into months when largestUnit is ~month~ (polyfill optimization result).
            if largestUnit == .Month {
                months &+= years &* JSC.ISO8601.monthsPerYear
                years = 0
            }
        }

        // NOTE: steps 3.f–3.j (weeks/days via ISODateSurpasses loops) are replaced by epoch-day
        // subtraction (polyfill optimization). Compute the base date after adding years+months first.
        let intermediate = balanceISOYearMonth(Int64(one.year() &+ years), Int64(one.month()) + Int64(months))
        // Constrain mode cannot fail.
        let constrained = constrainISODate(intermediate.year(), Int32(intermediate.month()), Int64(one.day()))

        // 3.f. Let weeks be 0.
        var weeks: Double = 0
        var days =
            JSC.makeDay(Double(two.year()), Double(Int32(two.month()) - 1), Double(two.day()))
            - JSC.makeDay(Double(constrained.year()), Double(Int32(constrained.month()) - 1), Double(constrained.day()))

        // 3.g. If largestUnit is ~week~, then
        if largestUnit == .Week {
            weeks = (abs(days) / Double(JSC.ISO8601.daysPerWeek)).rounded(.towardZero)
            // `days` is a difference of two makeDay values: the PlainDate constructor
            // clamps a year to the limits or outOfRangeYear and a month is a uint8_t, so each is finite and below 2^28
            // in magnitude, and Int64 holds it exactly.
            days = Double(Int64(days.rounded(.towardZero)) % Int64(JSC.ISO8601.daysPerWeek)).rounded(.towardZero)
            if weeks != 0 {
                weeks *= Double(sign) // Avoid -0
            }
        }

        // 3.k. Return ! CreateDateDurationRecord(years, months, weeks, days).
        // weeks and days are integers below 2^31 here (the PlainDate constructor's clamp, above), so the conversions are exact.
        return JSC.ISO8601.Duration(Int64(years), Int64(months), Int64(weeks), Int64(days), 0, 0, 0, 0, 0, 0)
    }

    // DiffISODateTime — ISO8601 path of DifferenceISODateTime (combines diffISODate + DifferenceTime).
    // temporal_rs: IsoDateTime::diff (src/iso.rs) — no single fn; uses IsoDate::diff_iso_date + IsoTime::diff
    // https://tc39.es/proposal-temporal/#sec-temporal-differenceisodatetime
    static func diffISODateTime(
        _ d1: JSC.ISO8601.PlainDate,
        _ t1: JSC.ISO8601.PlainTime,
        _ d2: JSC.ISO8601.PlainDate,
        _ t2: JSC.ISO8601.PlainTime,
        _ largestUnit: JSC.TemporalUnit
    ) -> JSC.ISO8601.InternalDuration {
        // 1. Assert: ISODateTimeWithinLimits(d1, t1) is true.
        // 2. Assert: ISODateTimeWithinLimits(d2, t2) is true.
        // 3. Let timeDuration be DifferenceTime(t1, t2).
        let h = Int128(t2.hour()) - Int128(t1.hour())
        let m = (Int128(t2.minute()) - Int128(t1.minute())) + h * 60
        let s = (Int128(t2.second()) - Int128(t1.second())) + m * 60
        let ms = (Int128(t2.millisecond()) - Int128(t1.millisecond())) + s * 1000
        let us = (Int128(t2.microsecond()) - Int128(t1.microsecond())) + ms * 1000
        var timeDiff = (Int128(t2.nanosecond()) - Int128(t1.nanosecond())) + us * 1000

        // 4. Let timeSign be TimeDurationSign(timeDuration).
        let timeSign: Int32 = timeDiff < 0 ? -1 : timeDiff > 0 ? 1 : 0
        // 5. Let dateSign be CompareISODate(d1, d2).
        let dateSign = isoDateCompare(d1, d2)
        // 6. Let adjustedDate be d2.
        var adjustedD2 = d2

        // 7. If timeSign = dateSign, then
        if dateSign != 0 && timeSign != 0 && dateSign == timeSign {
            // a. Set adjustedDate to AddDaysToISODate(adjustedDate, timeSign).
            adjustedD2 = addDaysToISODate(adjustedD2, Int64(timeSign))
            // b. Set timeDuration to ! Add24HourDaysToTimeDuration(timeDuration, -timeSign).
            timeDiff &-= Int128(timeSign) &* TemporalExactTime.nsPerDay // Cannot overflow: |timeDiff| < 2^76.
        }

        // 8. Let dateLargestUnit be LargerOfTwoTemporalUnits(~day~, largestUnit).
        let dateLargestUnit: JSC.TemporalUnit = largestUnit.rawValue > JSC.TemporalUnit.Day.rawValue ? .Day : largestUnit

        // 9. Let dateDifference be CalendarDateUntil(calendar, d1, adjustedDate, dateLargestUnit).
        let dateDiff = diffISODate(d1, adjustedD2, dateLargestUnit)

        // 10. If largestUnit is not dateLargestUnit, then
        var remainingDays = dateDiff.days()
        var timeDuration = timeDiff
        if largestUnit != dateLargestUnit {
            // a. Set timeDuration to ! Add24HourDaysToTimeDuration(timeDuration, dateDifference.[[Days]]).
            timeDuration = timeDiff + Int128(dateDiff.days()) * TemporalExactTime.nsPerDay
            // b. Set dateDifference.[[Days]] to 0.
            remainingDays = 0
        }

        // 11. Return CombineDateAndTimeDuration(dateDifference, timeDuration).
        // Each field converts exactly: diffISODate's fields are below 2^31.
        let datePart = JSC.ISO8601.Duration(dateDiff.years(), dateDiff.months(), dateDiff.weeks(), remainingDays, 0, 0, 0, 0, 0, 0)
        return TemporalISO8601.combineDateAndTimeDuration(datePart, timeDuration)
    }

    // RoundTime steps 1–6 (quantity only) — temporal_rs: IsoTime::round (src/iso.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-roundtime
    private static func roundTime(_ t: JSC.ISO8601.PlainTime, _ unit: JSC.TemporalUnit) -> (quantity: Int128, baseOffset: Int128) {
        let lH = Int128(t.hour())
        let lMi = Int128(t.minute())
        let lS = Int128(t.second())
        let lMs = Int128(t.millisecond())
        let lUs = Int128(t.microsecond())
        let lNs = Int128(t.nanosecond())
        switch unit {
        // Step 1: If unit is ~day~ or ~hour~, quantity = full time from midnight in nanoseconds.
        case .Day, .Hour:
            return (
                lH * TemporalExactTime.nsPerHour + lMi * TemporalExactTime.nsPerMinute + lS * TemporalExactTime.nsPerSecond + lMs
                    * TemporalExactTime.nsPerMillisecond + lUs
                    * TemporalExactTime.nsPerMicrosecond + lNs, 0
            )
        // Step 2: If unit is ~minute~, quantity = time within the current hour.
        case .Minute:
            return (
                lMi * TemporalExactTime.nsPerMinute + lS * TemporalExactTime.nsPerSecond + lMs * TemporalExactTime.nsPerMillisecond + lUs
                    * TemporalExactTime.nsPerMicrosecond + lNs,
                lH * TemporalExactTime.nsPerHour
            )
        // Step 3: If unit is ~second~, quantity = time within the current minute.
        case .Second:
            return (
                lS * TemporalExactTime.nsPerSecond + lMs * TemporalExactTime.nsPerMillisecond + lUs * TemporalExactTime.nsPerMicrosecond
                    + lNs,
                lH * TemporalExactTime.nsPerHour + lMi * TemporalExactTime.nsPerMinute
            )
        // Step 4: If unit is ~millisecond~, quantity = time within the current second.
        case .Millisecond:
            return (
                lMs * TemporalExactTime.nsPerMillisecond + lUs * TemporalExactTime.nsPerMicrosecond + lNs,
                lH * TemporalExactTime.nsPerHour + lMi * TemporalExactTime.nsPerMinute + lS * TemporalExactTime.nsPerSecond
            )
        // Step 5: If unit is ~microsecond~, quantity = time within the current millisecond.
        case .Microsecond:
            return (
                lUs * TemporalExactTime.nsPerMicrosecond + lNs,
                lH * TemporalExactTime.nsPerHour + lMi * TemporalExactTime.nsPerMinute + lS * TemporalExactTime.nsPerSecond + lMs
                    * TemporalExactTime.nsPerMillisecond
            )
        // Step 6: Assert unit is ~nanosecond~. quantity = nanosecond value.
        default:
            return (
                lNs,
                lH * TemporalExactTime.nsPerHour + lMi * TemporalExactTime.nsPerMinute + lS * TemporalExactTime.nsPerSecond + lMs
                    * TemporalExactTime.nsPerMillisecond + lUs
                    * TemporalExactTime.nsPerMicrosecond
            )
        }
    }

    /// The date a day before or after `date`, as roundISODateTime's step 3 computes it through WTF's day numbers.
    ///
    /// The `&+` cannot overflow: daysFromYearMonth is within ±2^28 for a 21-bit year, and day and month are below 256.
    private static func roundingDayStep(_ date: JSC.ISO8601.PlainDate, _ step: Int32) -> JSC.ISO8601.PlainDate {
        let days = WTF.daysFromYearMonth(date.year(), Int32(date.month()) - 1) &+ (Int32(date.day()) - 1) &+ step
        let ymd = JSC.temporalYearMonthDayFromDays(days)
        // month + 1 and day are narrowed to uint8_t before the constructor widens them to unsigned.
        return JSC.ISO8601.PlainDate(
            ymd.year,
            UInt32(UInt8(truncatingIfNeeded: ymd.month &+ 1)),
            UInt32(UInt8(truncatingIfNeeded: ymd.day))
        )
    }

    // RoundISODateTime — temporal_rs: IsoDateTime::round (src/iso.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-roundisodatetime
    static func roundISODateTime(
        _ date: JSC.ISO8601.PlainDate,
        _ time: JSC.ISO8601.PlainTime,
        _ incrementNs: Int128,
        _ unit: JSC.TemporalUnit,
        _ mode: JSC.RoundingMode
    ) -> JSC.TemporalCore.RoundedISODateTime {
        var date = date

        // Step 1: Assert ISODateTimeWithinLimits(isoDateTime).

        // Step 2: roundedTime = RoundTime(time, increment, unit, roundingMode).
        let (quantity, baseOffset) = roundTime(time, unit)
        // Wraps only for an increment near 2^127: callers pass at most a day.
        var roundedLocalNs = baseOffset &+ roundNumberToIncrementInt128(quantity, incrementNs, mode)

        // Step 3: balanceResult = AddDaysToISODate(isoDate, roundedTime.[[Days]]).
        if roundedLocalNs < 0 {
            roundedLocalNs += TemporalExactTime.nsPerDay
            date = roundingDayStep(date, -1)
        } else if roundedLocalNs >= TemporalExactTime.nsPerDay {
            roundedLocalNs -= TemporalExactTime.nsPerDay
            date = roundingDayStep(date, 1)
        }

        // Step 4: CombineISODateAndTimeRecord(balanceResult, roundedTime).
        var rem = roundedLocalNs
        let h = UInt32(truncatingIfNeeded: rem / TemporalExactTime.nsPerHour)
        rem %= TemporalExactTime.nsPerHour
        let mi = UInt32(truncatingIfNeeded: rem / TemporalExactTime.nsPerMinute)
        rem %= TemporalExactTime.nsPerMinute
        let s = UInt32(truncatingIfNeeded: rem / TemporalExactTime.nsPerSecond)
        rem %= TemporalExactTime.nsPerSecond
        let ms = UInt32(truncatingIfNeeded: rem / TemporalExactTime.nsPerMillisecond)
        rem %= TemporalExactTime.nsPerMillisecond
        let us = UInt32(truncatingIfNeeded: rem / TemporalExactTime.nsPerMicrosecond)
        let ns = UInt32(truncatingIfNeeded: rem % TemporalExactTime.nsPerMicrosecond)
        return JSC.TemporalCore.RoundedISODateTime(date: date, time: JSC.ISO8601.PlainTime(h, mi, s, ms, us, ns))
    }
}

// MARK: - Implementations of C++ declarations
//
// Each is the definition of the `JS_EXPORT_PRIVATE` declaration it names, under its C++ symbol: `public`, so that
// JavaScriptCore exports it, with the C++ type names spelled out. Every parameter is a value.

extension JSC.TemporalCore {
    /// `TemporalCore::balanceISOYearMonth`.
    @cxx
    @implementation
    public static func balanceISOYearMonth(_ year: Int64, _ month: Int64) -> JSC.ISO8601.PlainYearMonth {
        TemporalOperations.balanceISOYearMonth(year, month)
    }

    /// `TemporalCore::roundISODateTime`.
    @cxx
    @implementation
    public static func roundISODateTime(
        _ date: JSC.ISO8601.PlainDate,
        _ time: JSC.ISO8601.PlainTime,
        _ incrementNs: Int128,
        _ unit: JSC.TemporalUnit,
        _ mode: JSC.RoundingMode
    ) -> JSC.TemporalCore.RoundedISODateTime {
        TemporalOperations.roundISODateTime(date, time, incrementNs, unit, mode)
    }
}

// MARK: - Functions the C++ calls

// Exclusivity of their parameters: see TemporalSupport.swift.

/// `TemporalCore::addDaysToISODate`.
@_expose(Cxx)
func temporalAddDaysToISODate(_ date: JSC.ISO8601.PlainDate, _ days: Int64, _ value: inout JSC.ISO8601.PlainDate) {
    value = TemporalOperations.addDaysToISODate(date, days)
}

/// `TemporalCore::regulateISODate`.
@_expose(Cxx)
func temporalRegulateISODate(
    _ year: Int32,
    _ month: Int32,
    _ day: Int64,
    _ overflow: JSC.TemporalOverflow,
    _ value: inout JSC.ISO8601.PlainDate,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.regulateISODate(year, month, day, overflow).store(&value, &kind)
}

/// `TemporalCore::isoDateAdd`.
@_expose(Cxx)
func temporalIsoDateAdd(
    _ plainDate: JSC.ISO8601.PlainDate,
    _ duration: JSC.ISO8601.Duration,
    _ overflow: JSC.TemporalOverflow,
    _ value: inout JSC.ISO8601.PlainDate,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.isoDateAdd(plainDate, duration, overflow).store(&value, &kind)
}

/// `TemporalCore::isoDateCompare`.
@_expose(Cxx)
func temporalIsoDateCompare(_ d1: JSC.ISO8601.PlainDate, _ d2: JSC.ISO8601.PlainDate) -> Int32 {
    TemporalOperations.isoDateCompare(d1, d2)
}

/// `TemporalCore::isoTimeCompare`.
@_expose(Cxx)
func temporalIsoTimeCompare(_ t1: JSC.ISO8601.PlainTime, _ t2: JSC.ISO8601.PlainTime) -> Int32 {
    TemporalOperations.isoTimeCompare(t1, t2)
}

/// `TemporalCore::diffISODate`.
@_expose(Cxx)
func temporalDiffISODate(
    _ one: JSC.ISO8601.PlainDate,
    _ two: JSC.ISO8601.PlainDate,
    _ largestUnit: JSC.TemporalUnit,
    _ value: inout JSC.ISO8601.Duration
) {
    value = TemporalOperations.diffISODate(one, two, largestUnit)
}

/// `TemporalCore::diffISODateTime`.
@_expose(Cxx)
func temporalDiffISODateTime(
    _ d1: JSC.ISO8601.PlainDate,
    _ t1: JSC.ISO8601.PlainTime,
    _ d2: JSC.ISO8601.PlainDate,
    _ t2: JSC.ISO8601.PlainTime,
    _ largestUnit: JSC.TemporalUnit,
    _ value: inout JSC.ISO8601.InternalDuration
) {
    value = TemporalOperations.diffISODateTime(d1, t1, d2, t2, largestUnit)
}
