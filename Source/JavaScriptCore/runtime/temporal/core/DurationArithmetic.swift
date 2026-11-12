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

// MARK: - Constants and conversions

/// `static_cast<TemporalUnit>(index)` for an index of the units table.
private func temporalUnitInTable(_ index: Int32) -> JSC.TemporalUnit {
    switch index {
    case 0: .Year
    case 1: .Month
    case 2: .Week
    case 3: .Day
    case 4: .Hour
    case 5: .Minute
    case 6: .Second
    case 7: .Millisecond
    case 8: .Microsecond
    case 9: .Nanosecond
    default: fatalError()
    }
}

private func temporalUnitIndexInTable(_ unit: JSC.TemporalUnit) -> Int32 {
    switch unit {
    case .Year: 0
    case .Month: 1
    case .Week: 2
    case .Day: 3
    case .Hour: 4
    case .Minute: 5
    case .Second: 6
    case .Millisecond: 7
    case .Microsecond: 8
    case .Nanosecond: 9
    @unknown default: fatalError()
    }
}

/// `unit <= other` on `TemporalUnit`'s declaration order (larger units first).
@inline(always)
private func temporalUnitIsAtLeast(_ unit: JSC.TemporalUnit, _ other: JSC.TemporalUnit) -> Bool {
    unit.rawValue <= other.rawValue
}

// MARK: - Duration arithmetic

extension TemporalOperations {
    // durationSign — temporal_rs: Duration::sign()
    static func durationSign(_ d: JSC.ISO8601.Duration) -> Int32 {
        // The first nonzero field, in order, gives the sign.
        func sign<T: SignedInteger>(_ field: T) -> Int32 { field < 0 ? -1 : field > 0 ? 1 : 0 }
        var fieldSign = sign(d.years())
        if fieldSign == 0 { fieldSign = sign(d.months()) }
        if fieldSign == 0 { fieldSign = sign(d.weeks()) }
        if fieldSign == 0 { fieldSign = sign(d.days()) }
        if fieldSign == 0 { fieldSign = sign(d.hours()) }
        if fieldSign == 0 { fieldSign = sign(d.minutes()) }
        if fieldSign == 0 { fieldSign = sign(d.seconds()) }
        if fieldSign == 0 { fieldSign = sign(d.milliseconds()) }
        if fieldSign == 0 { fieldSign = sign(d.microseconds()) }
        if fieldSign == 0 { fieldSign = sign(d.nanoseconds()) }
        return fieldSign
    }

    // negateDuration — temporal_rs: Duration::negated()
    static func negateDuration(_ d: JSC.ISO8601.Duration) -> JSC.ISO8601.Duration {
        -d
    }

    // absDuration — temporal_rs: Duration::abs()
    static func absDuration(_ d: JSC.ISO8601.Duration) -> JSC.ISO8601.Duration {
        // std::abs(INT64_MIN) is undefined; it wraps to INT64_MIN, as clang compiles it.
        func abs(_ value: Int64) -> Int64 { value < 0 ? 0 &- value : value }
        return JSC.ISO8601.Duration(
            abs(d.years()),
            abs(d.months()),
            abs(d.weeks()),
            abs(d.days()),
            abs(d.hours()),
            abs(d.minutes()),
            abs(d.seconds()),
            abs(d.milliseconds()),
            temporalAbsInt128(d.microseconds()),
            temporalAbsInt128(d.nanoseconds())
        )
    }

    // largestSubduration — temporal_rs: Duration::default_largest_unit
    static func largestSubduration(_ d: JSC.ISO8601.Duration) -> JSC.TemporalUnit {
        var index: Int32 = 0
        while index < Int32(JSC.numberOfTemporalUnits) - 1 && d[Int(index)] == 0 {
            index += 1
        }
        return temporalUnitInTable(index)
    }

    // timeDurationFromComponents — temporal_rs: TimeDuration::from_components
    // Converts duration time fields to a total nanosecond Int128.
    static func timeDurationFromComponents(
        _ hours: Double,
        _ minutes: Double,
        _ seconds: Double,
        _ milliseconds: Double,
        _ microseconds: Double,
        _ nanoseconds: Double
    ) -> Int128 {
        timeDurationFromComponents(
            TemporalISO8601.checkedCastDoubleToInt128(hours),
            TemporalISO8601.checkedCastDoubleToInt128(minutes),
            TemporalISO8601.checkedCastDoubleToInt128(seconds),
            TemporalISO8601.checkedCastDoubleToInt128(milliseconds),
            TemporalISO8601.checkedCastDoubleToInt128(microseconds),
            TemporalISO8601.checkedCastDoubleToInt128(nanoseconds)
        )
    }

    /// `timeDurationFromComponents` of a Duration's time fields, each converted from `int64_t` to `double` and then to
    /// `Int128` by `checkedCastDoubleToInt128`.
    static func timeDurationFromComponents(_ d: JSC.ISO8601.Duration) -> Int128 {
        timeDurationFromComponents(
            TemporalISO8601.checkedCastDoubleToInt128(converting: d.hours()),
            TemporalISO8601.checkedCastDoubleToInt128(converting: d.minutes()),
            TemporalISO8601.checkedCastDoubleToInt128(converting: d.seconds()),
            TemporalISO8601.checkedCastDoubleToInt128(converting: d.milliseconds()),
            TemporalISO8601.checkedCastDoubleToInt128(converting: d.microseconds()),
            TemporalISO8601.checkedCastDoubleToInt128(converting: d.nanoseconds())
        )
    }

    /// `timeDurationFromComponents` from each component's `checkedCastDoubleToInt128`.
    @inline(always)
    private static func timeDurationFromComponents(
        _ hours: Int128?,
        _ minutes: Int128?,
        _ seconds: Int128?,
        _ milliseconds: Int128?,
        _ microseconds: Int128?,
        _ nanoseconds: Int128?
    ) -> Int128 {
        let minPerHour: Int128 = 60
        let secPerMin: Int128 = 60
        let msPerSec: Int128 = 1000
        let usPerMs: Int128 = 1000
        let nsPerUs: Int128 = 1000
        var min = TemporalCheckedInt128(minutes)
        min += TemporalCheckedInt128(hours) * minPerHour
        var sec = TemporalCheckedInt128(seconds)
        sec += min * secPerMin
        var millis = TemporalCheckedInt128(milliseconds)
        millis += sec * msPerSec
        var micros = TemporalCheckedInt128(microseconds)
        micros += millis * usPerMs
        var nanos = TemporalCheckedInt128(nanoseconds)
        nanos += micros * nsPerUs
        // Overflow traps, as converting an overflowed CheckedInt128 does.
        precondition(!nanos.hasOverflowed)
        assert(temporalAbsInt128(nanos.value) <= TemporalInternalDuration.maxTimeDuration)
        return nanos.value
    }

    // splitTimeDuration — internal; splits a timeDuration (ns) into (overflowDays, subdayNs) using floor division.
    static func splitTimeDuration(_ timeDuration: Int128) -> (Int64, Int128) {
        let (days, subdayRemainder) = temporalDivideInt128(timeDuration, TemporalExactTime.nsPerDay)
        var overflowDays = Int64(truncatingIfNeeded: days)
        var remainder = subdayRemainder
        if remainder < 0 {
            remainder += TemporalExactTime.nsPerDay
            // Wraps at INT64_MIN; only a timeDuration past ±2^63 days reaches it.
            overflowDays &-= 1
        }
        return (overflowDays, remainder)
    }

    // plainTimeFromSubdayNs — internal; decomposes sub-day nanoseconds into a PlainTime. ns must be in [0, nsPerDay).
    static func plainTimeFromSubdayNs(_ ns: Int128) -> JSC.ISO8601.PlainTime {
        assert(ns >= 0 && ns < TemporalExactTime.nsPerDay)
        // static_cast<int32_t> then the constructor's unsigned parameters: both truncate.
        let (microseconds, nanosecond) = temporalDivideInt128(ns, 1000)
        let (milliseconds, microsecond) = temporalDivideInt128(microseconds, 1000)
        let (seconds, millisecond) = temporalDivideInt128(milliseconds, 1000)
        let (minutes, second) = temporalDivideInt128(seconds, 60)
        let (hours, minute) = temporalDivideInt128(minutes, 60)
        return JSC.ISO8601.PlainTime(
            UInt32(truncatingIfNeeded: hours),
            UInt32(truncatingIfNeeded: minute),
            UInt32(truncatingIfNeeded: second),
            UInt32(truncatingIfNeeded: millisecond),
            UInt32(truncatingIfNeeded: microsecond),
            UInt32(truncatingIfNeeded: nanosecond)
        )
    }

    // totalTimeDuration — temporal_rs: TimeDuration::total (src/builtins/core/duration/normalized.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-totaltimeduration
    static func totalTimeDuration(_ timeDuration: Int128, _ unit: JSC.TemporalUnit) -> Double {
        let unitLength = JSC.lengthInNanoseconds(unit)
        // All "Length in Nanoseconds" values in spec Table 21 are ≤ nsPerDay = 8.64e13 < 2^53.
        // Spec NOTE: timeDuration may exceed safe integer range; fractionToDouble
        // implements the required software emulation (double-double arithmetic).
        return JSC.fractionToDouble(timeDuration, temporalDouble(unitLength))
    }

    // toInternalDuration — temporal_rs: Duration::to_internal_duration_record (src/builtins/core/duration.rs)
    // Builds an InternalDuration from a Duration (time fields only, no day normalization).
    static func toInternalDuration(_ d: JSC.ISO8601.Duration) -> JSC.ISO8601.InternalDuration {
        let timeDuration = timeDurationFromComponents(d)
        return TemporalISO8601.combineDateAndTimeDuration(d, timeDuration)
    }

    // temporalDurationFromInternal — temporal_rs: Duration::from_internal (src/builtins/core/duration.rs)
    // Converts an InternalDuration back to a Duration given largestUnit.
    static func temporalDurationFromInternal(
        _ internalDuration: JSC.ISO8601.InternalDuration,
        _ largestUnit: JSC.TemporalUnit
    ) -> TemporalOutcome<JSC.ISO8601.Duration> {
        var days: Int64 = 0
        var hours: Int64 = 0
        var minutes: Int64 = 0
        var seconds: Int64 = 0
        var milliseconds: Int128 = 0
        var microseconds: Int128 = 0

        let sign = internalDuration.timeDurationSign()
        var nanoseconds = temporalAbsInt128(internalDuration.time())

        if temporalUnitIsAtLeast(largestUnit, .Day) {
            (microseconds, nanoseconds) = temporalDivideInt128(nanoseconds, 1000)
            (milliseconds, microseconds) = temporalDivideInt128(microseconds, 1000)
            let wholeSeconds: Int128
            (wholeSeconds, milliseconds) = temporalDivideInt128(milliseconds, 1000)
            seconds = Int64(truncatingIfNeeded: wholeSeconds)
            minutes = seconds / 60
            seconds = seconds % 60
            hours = minutes / 60
            minutes = minutes % 60
            days = hours / 24
            hours = hours % 24
        } else if largestUnit == .Hour {
            (microseconds, nanoseconds) = temporalDivideInt128(nanoseconds, 1000)
            (milliseconds, microseconds) = temporalDivideInt128(microseconds, 1000)
            let wholeSeconds: Int128
            (wholeSeconds, milliseconds) = temporalDivideInt128(milliseconds, 1000)
            seconds = Int64(truncatingIfNeeded: wholeSeconds)
            minutes = seconds / 60
            seconds = seconds % 60
            hours = minutes / 60
            minutes = minutes % 60
        } else if largestUnit == .Minute {
            (microseconds, nanoseconds) = temporalDivideInt128(nanoseconds, 1000)
            (milliseconds, microseconds) = temporalDivideInt128(microseconds, 1000)
            let wholeSeconds: Int128
            (wholeSeconds, milliseconds) = temporalDivideInt128(milliseconds, 1000)
            seconds = Int64(truncatingIfNeeded: wholeSeconds)
            minutes = seconds / 60
            seconds = seconds % 60
        } else if largestUnit == .Second {
            (microseconds, nanoseconds) = temporalDivideInt128(nanoseconds, 1000)
            (milliseconds, microseconds) = temporalDivideInt128(microseconds, 1000)
            let wholeSeconds: Int128
            (wholeSeconds, milliseconds) = temporalDivideInt128(milliseconds, 1000)
            seconds = Int64(truncatingIfNeeded: wholeSeconds)
        } else if largestUnit == .Millisecond {
            (microseconds, nanoseconds) = temporalDivideInt128(nanoseconds, 1000)
            (milliseconds, microseconds) = temporalDivideInt128(microseconds, 1000)
        } else if largestUnit == .Microsecond {
            (microseconds, nanoseconds) = temporalDivideInt128(nanoseconds, 1000)
        }

        // sign is -1, 0 or 1. A field that the int64_t narrowing above wrapped to INT64_MIN wraps again
        // under negation.
        let sign64 = Int64(sign)
        let sign128 = Int128(sign)
        if hours != 0 {
            hours &*= sign64
        }
        if minutes != 0 {
            minutes &*= sign64
        }
        if seconds != 0 {
            seconds &*= sign64
        }
        if milliseconds != 0 {
            milliseconds &*= sign128
        }
        if microseconds != 0 {
            microseconds &*= sign128
        }
        if nanoseconds != 0 {
            nanoseconds &*= sign128
        }
        // Apply ℝ(𝔽(x)) per spec CreateTemporalDuration step 12: round through float64 so that
        // Int128 values not exactly representable round past nanosecondsLimit → isValidDuration rejects.
        // milliseconds uses doubleToInt64Saturating because Int128 → double can still exceed int64_t
        // (e.g. largestUnit=millisecond, out-of-range input: ms ≈ 9e21 > INT64_MAX ≈ 9.2e18).
        let dateDuration = internalDuration.dateDuration()
        // days + days * sign wraps on overflow.
        let result = JSC.ISO8601.Duration(
            dateDuration.years(),
            dateDuration.months(),
            dateDuration.weeks(),
            dateDuration.days() &+ days &* sign64,
            hours,
            minutes,
            seconds,
            JSC.ISO8601.Duration.doubleToInt64Saturating(temporalDouble(milliseconds)),
            temporalTruncatingInt128(temporalDouble(microseconds)),
            temporalTruncatingInt128(temporalDouble(nanoseconds))
        )
        // CreateTemporalDuration step: If IsValidDuration is false, return error.
        if !TemporalISO8601.isValidDuration(result) {
            return .failure(.range("Duration is outside the representable range"))
        }
        return .success(result)
    }

    // add24HourDaysToTimeDuration — temporal_rs: TimeDuration::add_days (src/builtins/core/duration/normalized.rs)
    // Adds 24-hour days to a timeDuration (ns). Returns error if result exceeds maxTimeDuration.
    static func add24HourDaysToTimeDuration(_ d: Int128, _ days: Double) -> TemporalOutcome<Int128> {
        add24HourDaysToTimeDuration(d, TemporalISO8601.checkedCastDoubleToInt128(days))
    }

    /// `add24HourDaysToTimeDuration(d, Double(days))`.
    static func add24HourDaysToTimeDuration(_ d: Int128, _ days: Int64) -> TemporalOutcome<Int128> {
        add24HourDaysToTimeDuration(d, TemporalISO8601.checkedCastDoubleToInt128(converting: days))
    }

    /// `add24HourDaysToTimeDuration` from the days' `checkedCastDoubleToInt128`.
    @inline(always)
    private static func add24HourDaysToTimeDuration(_ d: Int128, _ days: Int128?) -> TemporalOutcome<Int128> {
        var checkedResult = TemporalCheckedInt128(d)
        checkedResult += TemporalCheckedInt128(days) * TemporalExactTime.nsPerDay
        // Overflow traps, as converting an overflowed CheckedInt128 does.
        precondition(!checkedResult.hasOverflowed)
        let result = checkedResult.value
        if temporalAbsInt128(result) > TemporalInternalDuration.maxTimeDuration {
            return .failure(.range("Total time in duration is out of range"))
        }
        return .success(result)
    }

    // toInternalDurationRecord — temporal_rs: InternalDurationRecord::from_duration (src/builtins/core/duration/normalized.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-tointernaldurationrecord
    // Keeps days in [[Date]] and converts only time fields (hours..nanoseconds) to [[Time]] nanoseconds.
    static func toInternalDurationRecord(_ d: JSC.ISO8601.Duration) -> JSC.ISO8601.InternalDuration {
        let timeDuration = timeDurationFromComponents(d)
        let dateDuration = JSC.ISO8601.Duration(d.years(), d.months(), d.weeks(), d.days(), 0, 0, 0, 0, 0, 0)
        return TemporalISO8601.combineDateAndTimeDuration(dateDuration, timeDuration)
    }

    // toInternalDurationRecordWith24HourDays — temporal_rs: InternalDurationRecord::from_duration_with_24_hour_days (src/builtins/core/duration/normalized.rs)
    // Folds duration.days into timeDuration and returns InternalDuration with date-only datePart.
    static func toInternalDurationRecordWith24HourDays(_ d: JSC.ISO8601.Duration) -> TemporalOutcome<JSC.ISO8601.InternalDuration> {
        let timeDuration = timeDurationFromComponents(d)
        let result = add24HourDaysToTimeDuration(timeDuration, d.days())
        let time: Int128
        switch consume result {
        case .success(let value):
            time = value
        case .failure(let failure):
            return .failure(failure)
        }
        let dateDuration = JSC.ISO8601.Duration(d.years(), d.months(), d.weeks(), 0, 0, 0, 0, 0, 0, 0)
        return .success(TemporalISO8601.combineDateAndTimeDuration(dateDuration, time))
    }

    // toDateDurationRecordWithoutTime — temporal_rs: InternalDurationRecord::to_date_duration_record_without_time (src/builtins/core/duration/normalized.rs)
    // Strips time fields and folds days into the date part. Returns a date-only Duration.
    static func toDateDurationRecordWithoutTime(_ duration: JSC.ISO8601.Duration) -> TemporalOutcome<JSC.ISO8601.Duration> {
        let internalDurationResult = toInternalDurationRecordWith24HourDays(duration)
        let internalDuration: JSC.ISO8601.InternalDuration
        switch consume internalDurationResult {
        case .success(let value):
            internalDuration = value
        case .failure(let failure):
            return .failure(failure)
        }
        let days = temporalDivideInt128(internalDuration.time(), TemporalExactTime.nsPerDay).quotient
        let dateDuration = internalDuration.dateDuration()
        return .success(
            JSC.ISO8601.Duration(
                dateDuration.years(),
                dateDuration.months(),
                dateDuration.weeks(),
                Int64(truncatingIfNeeded: days),
                0,
                0,
                0,
                0,
                0,
                0
            )
        )
    }

    // getUTCEpochNanoseconds — temporal_rs: IsoDateTime::as_nanoseconds (UTC path)
    // Converts (PlainDate, PlainTime) to epoch nanoseconds as if the datetime were UTC.
    static func getUTCEpochNanoseconds(_ date: JSC.ISO8601.PlainDate, _ time: JSC.ISO8601.PlainTime) -> Int128 {
        let dayMs = JSC.makeDay(Double(date.year()), Double(Int32(date.month()) - 1), Double(date.day()))
        let timeMs = JSC.makeTime(Double(time.hour()), Double(time.minute()), Double(time.second()), Double(time.millisecond()))
        let ms = JSC.makeDate(dayMs, timeMs)
        // ms is an integer within ±8.64e18 for a date within limits, so nothing below overflows; outside them it
        // wraps.
        return temporalTruncatingInt128(ms) &* TemporalExactTime.nsPerMillisecond
            &+ Int128(time.microsecond()) &* TemporalExactTime.nsPerMicrosecond
            &+ Int128(time.nanosecond())
    }
}

// epochNanosecondsForDateAndTime — internal; computes epoch nanoseconds for (date, time): UTC if timeZone==nullptr, TZ-aware otherwise.
private func temporalEpochNanosecondsForDateAndTime(
    _ date: JSC.ISO8601.PlainDate,
    _ time: JSC.ISO8601.PlainTime,
    _ timeZone: JSC.TimeZone?
) -> TemporalOutcome<Int128> {
    guard let timeZone else {
        return .success(TemporalOperations.getUTCEpochNanoseconds(date, time))
    }
    let result = JSC.TemporalCore.getEpochNanosecondsFor(timeZone, date, time, .Compatible)
    if !result.has_value() {
        return .failure(TemporalFailure(JSC.temporalErrorOf(result)))
    }
    return .success((JSC.temporalValueOf(result) as JSC.ISO8601.ExactTime).epochNanoseconds())
}

extension TemporalOperations {
    // adjustDateDurationRecord — internal helper; builds a new date duration with overridden days/weeks/months fields.
    // https://tc39.es/proposal-temporal/#sec-temporal-adjustdatedurationrecord
    static func adjustDateDurationRecord(
        _ dateDuration: JSC.ISO8601.Duration,
        _ days: Int64,
        _ weeks: Int64?,
        _ months: Int64?
    ) -> TemporalOutcome<JSC.ISO8601.Duration> {
        // Step 1: If weeks is not present, set weeks to dateDuration.[[Weeks]].
        // Step 2: If months is not present, set months to dateDuration.[[Months]].
        // (Both handled implicitly by the optional parameters.)
        let y = dateDuration.years()
        let mo = months ?? dateDuration.months()
        let w = weeks ?? dateDuration.weeks()
        let d = days
        // Step 3: Return ? CreateDateDurationRecord(dateDuration.[[Years]], months, weeks, days).
        let result = JSC.ISO8601.Duration(y, mo, w, d, 0, 0, 0, 0, 0, 0)

        // Skip isValidDuration by filtering the most of legit cases via quick comparison of specified fields.
        let fieldLimit: Int64 = 1 << 32
        let maxDays: Int64 = (1 << 53) / 86400
        let fastPath =
            (y > -fieldLimit && y < fieldLimit)
            && (mo > -fieldLimit && mo < fieldLimit)
            && (w > -fieldLimit && w < fieldLimit)
            && (d > -maxDays && d < maxDays)
        if fastPath {
            // The first non-zero field gives the sign; every field must be zero or of that sign.
            let first = y != 0 ? y : (mo != 0 ? mo : (w != 0 ? w : d))
            let sign: Int64 = first > 0 ? 1 : (first < 0 ? -1 : 0)
            @inline(always)
            func agrees(_ v: Int64) -> Bool {
                !((v < 0 && sign > 0) || (v > 0 && sign < 0))
            }
            if agrees(y) && agrees(mo) && agrees(w) && agrees(d) {
                return .success(result)
            }
        }

        if !TemporalISO8601.isValidDuration(result) {
            return .failure(.range("Temporal.Duration properties must be valid and of consistent sign"))
        }
        return .success(result)
    }
}

// NudgeWindow — internal; holds the floor/ceiling epoch-ns bounds and durations for a single calendar nudge step.
private struct TemporalNudgeWindow {
    var r1: Int64
    var r2: Int64
    var startEpochNs: Int128
    var endEpochNs: Int128
    var startDuration: JSC.ISO8601.Duration
    var endDuration: JSC.ISO8601.Duration
}

// computeNudgeWindow — temporal_rs: InternalDurationRecord::compute_nudge_window (src/builtins/core/duration/normalized.rs)
// https://tc39.es/proposal-temporal/#sec-temporal-computenudgewindow
private func temporalComputeNudgeWindow(
    _ sign: Int32,
    _ duration: JSC.ISO8601.InternalDuration,
    _ originEpochNs: Int128,
    _ isoDate: JSC.ISO8601.PlainDate,
    _ isoTime: JSC.ISO8601.PlainTime,
    _ increment: Double,
    _ unit: JSC.TemporalUnit,
    _ additionalShift: Bool,
    _ timeZone: JSC.TimeZone?,
    _ calendarId: JSC.CalendarID
) -> TemporalOutcome<TemporalNudgeWindow> {
    var r1: Int64 = 0
    var r2: Int64 = 0
    // increment is an integer from 1 to 1e9 (validated by every caller), so the products and sums below are far
    // inside int64_t and Int128; past that they wrap.
    let shift = temporalTruncatingInt64(increment) &* Int64(sign)
    var startDuration = JSC.ISO8601.Duration()
    var endDuration = JSC.ISO8601.Duration()
    let dateDuration = duration.dateDuration()
    // Steps 1-4: compute r1, r2, startDuration, endDuration based on unit.
    switch unit {
    case .Year:
        // Step 1.a: years = RoundNumberToIncrement(duration.[[Date]].[[Years]], increment, trunc).
        let years = TemporalOperations.roundNumberToIncrementInt128(
            Int128(dateDuration.years()),
            temporalTruncatingInt128(increment),
            .Trunc
        )
        // Step 1.b-c: r1 = years; or if additionalShift, r1 = years + increment × sign.
        r1 = Int64(truncatingIfNeeded: years) &+ (additionalShift ? shift : 0)
        // Step 1.d: r2 = r1 + increment × sign.
        r2 = r1 &+ shift
        // Step 1.e: startDuration = CreateDateDurationRecord(r1, 0, 0, 0).
        startDuration = JSC.ISO8601.Duration(r1, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        // Step 1.f: endDuration = CreateDateDurationRecord(r2, 0, 0, 0).
        endDuration = JSC.ISO8601.Duration(r2, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    case .Month:
        // Step 2.a: months = RoundNumberToIncrement(duration.[[Date]].[[Months]], increment, trunc).
        let months = TemporalOperations.roundNumberToIncrementInt128(
            Int128(dateDuration.months()),
            temporalTruncatingInt128(increment),
            .Trunc
        )
        // Step 2.b-c: r1 = months; or if additionalShift, r1 = months + increment × sign.
        r1 = Int64(truncatingIfNeeded: months) &+ (additionalShift ? shift : 0)
        // Step 2.d: r2 = r1 + increment × sign.
        r2 = r1 &+ shift
        // Step 2.e: startDuration = AdjustDateDurationRecord(duration.[[Date]], 0, 0, r1).
        let sd = TemporalOperations.adjustDateDurationRecord(dateDuration, 0, 0, r1)
        let start: JSC.ISO8601.Duration
        switch consume sd {
        case .success(let value):
            start = value
        case .failure(let failure):
            return .failure(failure)
        }
        startDuration = start
        // Step 2.f: endDuration = AdjustDateDurationRecord(duration.[[Date]], 0, 0, r2).
        let ed = TemporalOperations.adjustDateDurationRecord(dateDuration, 0, 0, r2)
        let end: JSC.ISO8601.Duration
        switch consume ed {
        case .success(let value):
            end = value
        case .failure(let failure):
            return .failure(failure)
        }
        endDuration = end
    case .Week:
        // Step 3.a: yearsMonths = AdjustDateDurationRecord(duration.[[Date]], 0, 0).
        let yearsMonthsResult = TemporalOperations.adjustDateDurationRecord(dateDuration, 0, 0, nil)
        let yearsMonths: JSC.ISO8601.Duration
        switch consume yearsMonthsResult {
        case .success(let value):
            yearsMonths = value
        case .failure(let failure):
            return .failure(failure)
        }
        // Step 3.b: weeksStart = CalendarDateAdd(calendar, isoDateTime.[[ISODate]], yearsMonths, constrain).
        let weeksStart: JSC.ISO8601.PlainDate
        switch TemporalOperations.calendarDateAdd(calendarId, isoDate, yearsMonths, .Constrain) {
        case .success(let value):
            weeksStart = value
        case .failure(let failure):
            return .failure(failure)
        }
        // Step 3.c: weeksEnd = AddDaysToISODate(weeksStart, duration.[[Date]].[[Days]]).
        let weeksEnd = TemporalOperations.addDaysToISODate(weeksStart, dateDuration.days())
        // Step 3.d: untilResult = CalendarDateUntil(calendar, weeksStart, weeksEnd, week).
        let until: JSC.ISO8601.Duration
        switch TemporalOperations.calendarDateUntil(calendarId, weeksStart, weeksEnd, .Week) {
        case .success(let value):
            until = value
        case .failure(let failure):
            return .failure(failure)
        }
        // Step 3.e: weeks = RoundNumberToIncrement(duration.[[Date]].[[Weeks]] + untilResult.[[Weeks]], increment, trunc).
        let weeks = TemporalOperations.roundNumberToIncrementInt128(
            Int128(dateDuration.weeks() &+ until.weeks()),
            temporalTruncatingInt128(increment),
            .Trunc
        )
        // Step 3.f: r1 = weeks. Step 3.g: r2 = weeks + increment × sign.
        r1 = Int64(truncatingIfNeeded: weeks)
        r2 = r1 &+ shift
        // Step 3.h: startDuration = AdjustDateDurationRecord(duration.[[Date]], 0, r1).
        let sd = TemporalOperations.adjustDateDurationRecord(dateDuration, 0, r1, nil)
        let start: JSC.ISO8601.Duration
        switch consume sd {
        case .success(let value):
            start = value
        case .failure(let failure):
            return .failure(failure)
        }
        startDuration = start
        // Step 3.i: endDuration = AdjustDateDurationRecord(duration.[[Date]], 0, r2).
        let ed = TemporalOperations.adjustDateDurationRecord(dateDuration, 0, r2, nil)
        let end: JSC.ISO8601.Duration
        switch consume ed {
        case .success(let value):
            end = value
        case .failure(let failure):
            return .failure(failure)
        }
        endDuration = end
    default:
        // Step 4.a: Assert unit is day.
        assert(unit == .Day)
        // Step 4.b: days = RoundNumberToIncrement(duration.[[Date]].[[Days]], increment, trunc).
        let days = TemporalOperations.roundNumberToIncrementInt128(Int128(dateDuration.days()), temporalTruncatingInt128(increment), .Trunc)
        // Step 4.c: r1 = days. Step 4.d: r2 = days + increment × sign.
        r1 = Int64(truncatingIfNeeded: days)
        r2 = r1 &+ shift
        // Step 4.e: startDuration = AdjustDateDurationRecord(duration.[[Date]], r1).
        let sd = TemporalOperations.adjustDateDurationRecord(dateDuration, r1, nil, nil)
        let start: JSC.ISO8601.Duration
        switch consume sd {
        case .success(let value):
            start = value
        case .failure(let failure):
            return .failure(failure)
        }
        startDuration = start
        // Step 4.f: endDuration = AdjustDateDurationRecord(duration.[[Date]], r2).
        let ed = TemporalOperations.adjustDateDurationRecord(dateDuration, r2, nil, nil)
        let end: JSC.ISO8601.Duration
        switch consume ed {
        case .success(let value):
            end = value
        case .failure(let failure):
            return .failure(failure)
        }
        endDuration = end
    }

    // Step 5: Assert if sign=1, r1≥0 and r1<r2.
    assert(sign != 1 || (r1 >= 0 && r1 < r2))
    // Step 6: Assert if sign=-1, r1≤0 and r1>r2.
    assert(sign != -1 || (r1 <= 0 && r1 > r2))

    // Step 7: If r1=0, startEpochNs = originEpochNs.
    // Steps 7-8: startEpochNs. Use originEpochNs only when startDuration is entirely zero;
    // otherwise compute via CalendarDateAdd (fix for https://github.com/tc39/proposal-temporal/issues/3316).
    let startEpochNs: Int128
    if startDuration.years() == 0 && startDuration.months() == 0 && startDuration.weeks() == 0 && startDuration.days() == 0 {
        startEpochNs = originEpochNs
    } else {
        let start: JSC.ISO8601.PlainDate
        switch TemporalOperations.calendarDateAdd(calendarId, isoDate, startDuration, .Constrain) {
        case .success(let value):
            start = value
        case .failure(let failure):
            return .failure(failure)
        }
        let startDayCount = WTF.dateToDaysFrom1970(start.year(), Int32(start.month()) - 1, Int32(start.day()))
        if startDayCount.magnitude > 1e8 {
            return .failure(.range("date is outside the representable range"))
        }
        let startNsResult = temporalEpochNanosecondsForDateAndTime(start, isoTime, timeZone)
        let startNs: Int128
        switch consume startNsResult {
        case .success(let value):
            startNs = value
        case .failure(let failure):
            return .failure(failure)
        }
        startEpochNs = startNs
    }
    // Step 9: end = CalendarDateAdd(calendar, isoDateTime.[[ISODate]], endDuration, constrain).
    let end: JSC.ISO8601.PlainDate
    switch TemporalOperations.calendarDateAdd(calendarId, isoDate, endDuration, .Constrain) {
    case .success(let value):
        end = value
    case .failure(let failure):
        return .failure(failure)
    }
    let endDayCount = WTF.dateToDaysFrom1970(end.year(), Int32(end.month()) - 1, Int32(end.day()))
    if endDayCount.magnitude > 1e8 {
        return .failure(.range("date is outside the representable range"))
    }
    // Steps 10-12: CombineISODateAndTimeRecord (step 10) + GetUTCEpochNanoseconds/GetEpochNanosecondsFor
    //              (steps 11/12) fused into epochNanosecondsForDateAndTime — avoids an intermediate endDateTime record.
    let endNsResult = temporalEpochNanosecondsForDateAndTime(end, isoTime, timeZone)
    let endEpochNs: Int128
    switch consume endNsResult {
    case .success(let value):
        endEpochNs = value
    case .failure(let failure):
        return .failure(failure)
    }
    // Steps 13-14: startDuration/endDuration = CombineDateAndTimeDuration(dateDuration, 0).
    // Deferred to caller (nudgeToCalendarUnit) for efficiency — only the selected path needs the combine.
    // Step 15: Return the Record.
    return .success(
        TemporalNudgeWindow(
            r1: r1,
            r2: r2,
            startEpochNs: startEpochNs,
            endEpochNs: endEpochNs,
            startDuration: startDuration,
            endDuration: endDuration
        )
    )
}

extension TemporalOperations {
    // nudgeToCalendarUnit — temporal_rs: InternalDurationRecord::nudge_calendar_unit (internal step of round_relative_duration)
    // https://tc39.es/proposal-temporal/#sec-temporal-nudgetocalendarunit
    static func nudgeToCalendarUnit(
        _ sign: Int32,
        _ duration: JSC.ISO8601.InternalDuration,
        _ originEpochNs: Int128,
        _ destEpochNs: Int128,
        _ isoDate: JSC.ISO8601.PlainDate,
        _ isoTime: JSC.ISO8601.PlainTime,
        _ increment: Double,
        _ unit: JSC.TemporalUnit,
        _ roundingMode: JSC.RoundingMode,
        _ timeZone: JSC.TimeZone?,
        _ calendarId: JSC.CalendarID
    ) -> TemporalOutcome<JSC.Nudged> {
        // Step 1: Let didExpandCalendarUnit be false.
        // Step 2: Let nudgeWindow be ? ComputeNudgeWindow(sign, duration, originEpochNs, isoDateTime, timeZone, calendar, increment, unit, false).
        let nudgeWindowResult = temporalComputeNudgeWindow(
            sign,
            duration,
            originEpochNs,
            isoDate,
            isoTime,
            increment,
            unit,
            false,
            timeZone,
            calendarId
        )
        var nudgeWindow: TemporalNudgeWindow
        switch consume nudgeWindowResult {
        case .success(let value):
            nudgeWindow = value
        case .failure(let failure):
            return .failure(failure)
        }

        // Step 3-4: Let startEpochNs/endEpochNs be nudgeWindow.[[StartEpochNs]]/[[EndEpochNs]].
        var didExpandCalendarUnit = false
        // Step 5: If sign = 1, then / Step 6: Else, — check destEpochNs is in bounds; if not, retry with additionalShift=true.
        let inBounds =
            (sign == 1)
            ? (nudgeWindow.startEpochNs <= destEpochNs && destEpochNs <= nudgeWindow.endEpochNs)
            : (nudgeWindow.endEpochNs <= destEpochNs && destEpochNs <= nudgeWindow.startEpochNs)
        if !inBounds {
            // Step 5.a / 6.a: Set nudgeWindow to ? ComputeNudgeWindow(..., true).
            let retried = temporalComputeNudgeWindow(
                sign,
                duration,
                originEpochNs,
                isoDate,
                isoTime,
                increment,
                unit,
                true,
                timeZone,
                calendarId
            )
            let window: TemporalNudgeWindow
            switch consume retried {
            case .success(let value):
                window = value
            case .failure(let failure):
                return .failure(failure)
            }
            nudgeWindow = window
            // Step 5.a.iii / 6.a.iii: Set didExpandCalendarUnit to true. (The spec also asserts bounds
            // hold after retry, but the assertion is violable: https://github.com/tc39/proposal-temporal/issues/3310)
            didExpandCalendarUnit = true
        }

        // Steps 7-12: Extract r1, r2, startEpochNs, endEpochNs, startDuration, endDuration from nudgeWindow.
        // Step 13: Assert: startEpochNs ≠ endEpochNs. The assertion is violable when a time zone
        // transition skips the entire calendar day (https://github.com/tc39/proposal-temporal/issues/3310).
        // FIXME: RangeError matches the polyfill, not the spec; revisit once the issue above settles.
        if nudgeWindow.startEpochNs == nudgeWindow.endEpochNs {
            return .failure(.range("cannot round relative to a time zone transition that skips an entire day"))
        }
        // Step 14: Let progress be (destEpochNs - startEpochNs) / (endEpochNs - startEpochNs).
        // Epoch nanoseconds are within ±8.64e21 and increment at most 1e9, so these stay far inside Int128; past
        // that they wrap.
        let progressNumerator = destEpochNs &- nudgeWindow.startEpochNs
        let progressDenominator = nudgeWindow.endEpochNs &- nudgeWindow.startEpochNs
        // Step 15: Let total be r1 + progress × increment × sign.
        // (NOTE: computed via integer arithmetic before the final float division per spec note.)
        let totalNumerator =
            Int128(nudgeWindow.r1) &* progressDenominator &+ progressNumerator &* Int128(temporalTruncatingInt64(increment)) &* Int128(sign)
        let total = JSC.fractionToDouble(totalNumerator, temporalAbsInt128(progressDenominator)) * (progressDenominator < 0 ? -1.0 : 1.0)
        // The denominator is not zero (checked above); Int128.min / -1 wraps.
        let progress = progressNumerator.dividedReportingOverflow(by: progressDenominator).partialValue
        // Step 17: Assert: 0 ≤ progress ≤ 1.
        assert(0 <= progress && progress <= 1)
        // Steps 18-19: isNegative, then unsignedRoundingMode = GetUnsignedRoundingMode(roundingMode, isNegative).
        let unsignedRoundingMode = JSC.getUnsignedRoundingMode(roundingMode, sign < 0)
        // Steps 20-21: If progress = 1, roundedUnit = abs(r2); else apply unsigned rounding.
        // Passes the exact rational rather than the `total` double computed above, because
        // ApplyUnsignedRoundingMode compares for exact equality.
        let absR1 = temporalAbsInt128(Int128(nudgeWindow.r1))
        let absR2 = temporalAbsInt128(Int128(nudgeWindow.r2))
        var roundedToR2 = true
        if progress != 1 {
            roundedToR2 =
                TemporalOperations.applyUnsignedRoundingMode(
                    temporalAbsInt128(totalNumerator),
                    temporalAbsInt128(progressDenominator),
                    absR1,
                    absR2,
                    unsignedRoundingMode
                ) == absR2
        }
        // Steps 22-23: If roundedUnit = abs(r2), set didExpandCalendarUnit and use endDuration/endEpochNs; else start.
        didExpandCalendarUnit = didExpandCalendarUnit || roundedToR2
        let resultDuration = roundedToR2 ? nudgeWindow.endDuration : nudgeWindow.startDuration
        let nudgedEpochNs = roundedToR2 ? nudgeWindow.endEpochNs : nudgeWindow.startEpochNs
        // Step 24: Let nudgeResult be Duration Nudge Result Record { [[Duration]]: resultDuration, [[NudgedEpochNs]]: nudgedEpochNs, [[DidExpandCalendarUnit]]: didExpandCalendarUnit }.
        // (computeNudgeWindow steps 13-14 deferred here: CombineDateAndTimeDuration applied only to the selected path.)
        let resultDurationInternal = TemporalISO8601.combineDateAndTimeDuration(resultDuration, 0)
        // Step 25: Return the Record { [[NudgeResult]]: nudgeResult, [[Total]]: total }.
        return .success(JSC.Nudged(JSC.NudgeResult(resultDurationInternal, nudgedEpochNs, didExpandCalendarUnit), total))
    }

    // nudgeToZonedTime — temporal_rs: InternalDurationRecord::nudge_to_zoned_time (src/builtins/core/duration/normalized.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-nudgetozonedtime
    static func nudgeToZonedTime(
        _ sign: Int32,
        _ duration: JSC.ISO8601.InternalDuration,
        _ isoDate: JSC.ISO8601.PlainDate,
        _ isoTime: JSC.ISO8601.PlainTime,
        _ timeZone: JSC.TimeZone,
        _ increment: Double,
        _ unit: JSC.TemporalUnit,
        _ roundingMode: JSC.RoundingMode,
        _ calendarId: JSC.CalendarID
    ) -> TemporalOutcome<JSC.NudgeResult> {
        let dateDuration = duration.dateDuration()
        // Step 1: Let start be ? CalendarDateAdd(calendar, isoDateTime.[[ISODate]], duration.[[Date]], ~constrain~).
        let start: JSC.ISO8601.PlainDate
        switch TemporalOperations.calendarDateAdd(calendarId, isoDate, dateDuration, .Constrain) {
        case .success(let value):
            start = value
        case .failure(let failure):
            return .failure(failure)
        }
        // Step 2: startDateTime = CombineISODateAndTimeRecord(start, isoDateTime.[[Time]]).
        // Step 3: endDate = AddDaysToISODate(start, sign).
        // Step 4: endDateTime = CombineISODateAndTimeRecord(endDate, isoDateTime.[[Time]]).
        // (Steps 2/4 fused into epochNanosecondsForDateAndTime — no intermediate records.)
        let endDate = TemporalOperations.addDaysToISODate(start, Int64(sign))
        // Step 5: startEpochNs = GetEpochNanosecondsFor(timeZone, startDateTime, compatible). (steps 2+5 fused)
        let startNsResult = temporalEpochNanosecondsForDateAndTime(start, isoTime, timeZone)
        let startEpochNs: Int128
        switch consume startNsResult {
        case .success(let value):
            startEpochNs = value
        case .failure(let failure):
            return .failure(failure)
        }
        // Step 6: endEpochNs = GetEpochNanosecondsFor(timeZone, endDateTime, compatible). (steps 4+6 fused)
        let endNsResult = temporalEpochNanosecondsForDateAndTime(endDate, isoTime, timeZone)
        let endEpochNs: Int128
        switch consume endNsResult {
        case .success(let value):
            endEpochNs = value
        case .failure(let failure):
            return .failure(failure)
        }
        // Step 7: daySpan = TimeDurationFromEpochNanosecondsDifference(endEpochNs, startEpochNs).
        // Epoch nanoseconds, time durations and increment × unitLength are each far inside Int128, so the sums and
        // products below cannot overflow for valid inputs; past them they wrap.
        let daySpan = endEpochNs &- startEpochNs
        // Step 8's assert is violable: a zone that skips a whole calendar day makes daySpan zero
        // (tc39/proposal-temporal#3310). Only subtracted, never divided by, so zero needs no handling.
        assert(daySpan == 0 || (daySpan < 0 ? -1 : 1) == sign)
        // Step 9: Let unitLength be the nanoseconds length of unit.
        let unitLength = JSC.lengthInNanoseconds(unit)
        let incrementLength = unitLength &* temporalTruncatingInt128(increment.rounded(.towardZero))
        // Step 10: Let roundedTimeDuration be ? RoundTimeDurationToIncrement(duration.[[Time]], increment × unitLength, roundingMode).
        var roundedTimeDuration = TemporalOperations.roundNumberToIncrementInt128(duration.time(), incrementLength, roundingMode)
        // Step 11: Let beyondDaySpan be ! AddTimeDuration(roundedTimeDuration, -daySpan).
        let beyondDaySpan = roundedTimeDuration &- daySpan
        let beyondSign: Int32 = beyondDaySpan < 0 ? -1 : beyondDaySpan > 0 ? 1 : 0
        // Step 12: If TimeDurationSign(beyondDaySpan) ≠ -sign (didRoundBeyondDay already set above), then
        let didRoundBeyondDay = beyondSign != 0 &- sign
        var dayDelta: Int32 = 0
        let nudgedEpochNs: Int128
        if didRoundBeyondDay {
            // Step 12.b: dayDelta = sign.
            dayDelta = sign
            // Step 12.c: Set roundedTimeDuration to ? RoundTimeDurationToIncrement(beyondDaySpan, ...).
            roundedTimeDuration = TemporalOperations.roundNumberToIncrementInt128(
                beyondDaySpan,
                unitLength &* temporalTruncatingInt128(increment.rounded(.towardZero)),
                roundingMode
            )
            // Step 12.d: nudgedEpochNs = AddTimeDurationToEpochNanoseconds(roundedTimeDuration, endEpochNs).
            nudgedEpochNs = roundedTimeDuration &+ endEpochNs
        } else {
            // Step 13.b: dayDelta = 0. (already initialized)
            // Step 13.c: nudgedEpochNs = AddTimeDurationToEpochNanoseconds(roundedTimeDuration, startEpochNs).
            nudgedEpochNs = roundedTimeDuration &+ startEpochNs
        }
        // Step 14: Let dateDuration be ! AdjustDateDurationRecord(duration.[[Date]], duration.[[Date]].[[Days]] + dayDelta).
        let dateDurationResult = adjustDateDurationRecord(dateDuration, dateDuration.days() &+ Int64(dayDelta), nil, nil)
        let adjusted: JSC.ISO8601.Duration
        switch consume dateDurationResult {
        case .success(let value):
            adjusted = value
        case .failure(let failure):
            return .failure(failure)
        }
        // Step 15: Let resultDuration be CombineDateAndTimeDuration(dateDuration, roundedTimeDuration).
        let resultDuration = TemporalISO8601.combineDateAndTimeDuration(adjusted, roundedTimeDuration)
        // Step 16: Return Duration Nudge Result Record { [[Duration]]: resultDuration, [[NudgedEpochNs]]: nudgedEpochNs, [[DidExpandCalendarUnit]]: didRoundBeyondDay }.
        return .success(JSC.NudgeResult(resultDuration, nudgedEpochNs, didRoundBeyondDay))
    }

    // nudgeToDayOrTime — temporal_rs: InternalDurationRecord::nudge_to_day_or_time (src/builtins/core/duration/normalized.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-nudgetodayortime
    static func nudgeToDayOrTime(
        _ duration: JSC.ISO8601.InternalDuration,
        _ destEpochNs: Int128,
        _ largestUnit: JSC.TemporalUnit,
        _ increment: Double,
        _ smallestUnit: JSC.TemporalUnit,
        _ roundingMode: JSC.RoundingMode
    ) -> TemporalOutcome<JSC.NudgeResult> {
        // Step 1: Let timeDuration be ! Add24HourDaysToTimeDuration(duration.[[Time]], duration.[[Date]].[[Days]]).
        let timeDurationResult = add24HourDaysToTimeDuration(duration.time(), duration.dateDuration().days())
        let timeDuration: Int128
        switch consume timeDurationResult {
        case .success(let value):
            timeDuration = value
        case .failure(let failure):
            return .failure(failure)
        }
        // Step 2: Let unitLength be the nanoseconds length of smallestUnit.
        let unitLength = JSC.lengthInNanoseconds(smallestUnit)
        // Step 3: Let roundedTime be ? RoundTimeDurationToIncrement(timeDuration, unitLength × increment, roundingMode).
        // timeDuration is within maxTimeDuration and increment × unitLength at most 1e9 × 8.64e13, so the
        // arithmetic below stays far inside Int128; past that it wraps.
        let roundedTime = TemporalOperations.roundNumberToIncrementInt128(
            timeDuration,
            unitLength &* temporalTruncatingInt128(increment.rounded(.towardZero)),
            roundingMode
        )
        // Step 4: Let diffTime be ! AddTimeDuration(roundedTime, -timeDuration).
        let diffTime = roundedTime &- timeDuration
        // Steps 5-6: wholeDays/roundedWholeDays = truncate(TotalTimeDuration(..., day)).
        // Integer division truncates; a double would round, and past 128 days the distinctions steps 7-9
        // and 13 rest on are below one ULP.
        // lengthInNanoseconds(TemporalUnit::Day) is ExactTime::nsPerDay (static_assert in DurationArithmetic.cpp).
        let wholeDays = timeDuration / TemporalExactTime.nsPerDay
        let roundedWholeDays = roundedTime / TemporalExactTime.nsPerDay
        // Step 7: Let dayDelta be roundedWholeDays - wholeDays.
        let dayDelta = roundedWholeDays - wholeDays
        // Step 8: If dayDelta < 0, let dayDeltaSign be -1; else if dayDelta > 0, let dayDeltaSign be 1; else 0.
        let dayDeltaSign: Int32 = dayDelta < 0 ? -1 : dayDelta > 0 ? 1 : 0
        // Step 9: If dayDeltaSign = TimeDurationSign(timeDuration), let didExpandDays be true; else false.
        let didExpandDays = dayDeltaSign == (timeDuration < 0 ? -1 : timeDuration > 0 ? 1 : 0)
        // Step 10: Let nudgedEpochNs be AddTimeDurationToEpochNanoseconds(diffTime, destEpochNs).
        let nudgedEpochNs = diffTime &+ destEpochNs
        // Step 11: Let days be 0.
        // Step 12: Let remainder be roundedTime.
        var days: Int64 = 0
        var remainder = roundedTime
        // Step 13: If TemporalUnitCategory(largestUnit) is ~date~, then
        if temporalUnitIsAtLeast(largestUnit, .Day) {
            // Step 13.a: Set days to roundedWholeDays.
            days = Int64(truncatingIfNeeded: roundedWholeDays)
            // Step 13.b: Set remainder to roundedTime - (roundedWholeDays x nsPerDay).
            // Cannot overflow: roundedWholeDays × nsPerDay is roundedTime truncated toward zero to whole days.
            remainder = roundedTime &- roundedWholeDays &* TemporalExactTime.nsPerDay
        }
        // Step 14: Let dateDuration be ! AdjustDateDurationRecord(duration.[[Date]], days).
        let dateDurationResult = adjustDateDurationRecord(duration.dateDuration(), days, nil, nil)
        let dateDuration: JSC.ISO8601.Duration
        switch consume dateDurationResult {
        case .success(let value):
            dateDuration = value
        case .failure(let failure):
            return .failure(failure)
        }
        // Step 15: Let resultDuration be CombineDateAndTimeDuration(dateDuration, remainder).
        let resultDuration = TemporalISO8601.combineDateAndTimeDuration(dateDuration, remainder)
        // Step 16: Return Duration Nudge Result Record { [[Duration]]: resultDuration, [[NudgedEpochNs]]: nudgedEpochNs, [[DidExpandCalendarUnit]]: didExpandDays }.
        return .success(JSC.NudgeResult(resultDuration, nudgedEpochNs, didExpandDays))
    }

    // bubbleRelativeDuration — temporal_rs: InternalDurationRecord::bubble_relative_duration (src/builtins/core/duration/normalized.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-bubblerelativeduration
    static func bubbleRelativeDuration(
        _ sign: Int32,
        _ duration: JSC.ISO8601.InternalDuration,
        _ nudgedEpochNs: Int128,
        _ isoDate: JSC.ISO8601.PlainDate,
        _ isoTime: JSC.ISO8601.PlainTime,
        _ largestUnit: JSC.TemporalUnit,
        _ smallestUnit: JSC.TemporalUnit,
        _ timeZone: JSC.TimeZone?,
        _ calendarId: JSC.CalendarID
    ) -> TemporalOutcome<JSC.ISO8601.InternalDuration> {
        var duration = duration
        // Step 1: If smallestUnit is largestUnit, return duration.
        if smallestUnit == largestUnit {
            return .success(duration)
        }
        // Step 2: Let largestUnitIndex be the ordinal index of largestUnit in the units table.
        let largestUnitIndex = temporalUnitIndexInTable(largestUnit)
        // Step 3: Let smallestUnitIndex be the ordinal index of smallestUnit in the units table.
        let smallestUnitIndex = temporalUnitIndexInTable(smallestUnit)
        // Step 4: Let unitIndex be smallestUnitIndex - 1.
        var unitIndex = smallestUnitIndex - 1
        // Step 5: Let done be false.
        var done = false
        var endDuration = JSC.ISO8601.Duration()
        // Step 6: Repeat, while unitIndex ≥ largestUnitIndex and done is false,
        while unitIndex >= largestUnitIndex && !done {
            // Step 6.a: Let unit be the unit at ordinal unitIndex in the units table.
            let unit = temporalUnitInTable(unitIndex)
            // Step 6.b: If unit is not ~week~, or largestUnit is ~week~, then
            if unit != .Week || largestUnit == .Week {
                // A field ± sign wraps at the int64_t limits.
                let dateDuration = duration.dateDuration()
                // Step 6.b.i: If unit is ~year~, let endDuration be ? CreateDateDurationRecord(years + sign, 0, 0, 0).
                if unit == .Year {
                    endDuration = JSC.ISO8601.Duration(dateDuration.years() &+ Int64(sign), 0, 0, 0, 0, 0, 0, 0, 0, 0)
                } else if unit == .Month {
                    // Step 6.b.ii: Else if unit is ~month~, let endDuration be ? AdjustDateDurationRecord(duration.[[Date]], 0, 0, months + sign).
                    let r = adjustDateDurationRecord(dateDuration, 0, 0, dateDuration.months() &+ Int64(sign))
                    let adjusted: JSC.ISO8601.Duration
                    switch consume r {
                    case .success(let value):
                        adjusted = value
                    case .failure(let failure):
                        return .failure(failure)
                    }
                    endDuration = adjusted
                } else {
                    // Step 6.b.iii: Else (unit is ~week~), let endDuration be ? AdjustDateDurationRecord(duration.[[Date]], 0, weeks + sign).
                    let r = adjustDateDurationRecord(dateDuration, 0, dateDuration.weeks() &+ Int64(sign), nil)
                    let adjusted: JSC.ISO8601.Duration
                    switch consume r {
                    case .success(let value):
                        adjusted = value
                    case .failure(let failure):
                        return .failure(failure)
                    }
                    endDuration = adjusted
                }
                // Step 6.b.iv: Let end be ? CalendarDateAdd(calendar, isoDateTime.[[ISODate]], endDuration, ~constrain~).
                let end: JSC.ISO8601.PlainDate
                switch TemporalOperations.calendarDateAdd(calendarId, isoDate, endDuration, .Constrain) {
                case .success(let value):
                    end = value
                case .failure(let failure):
                    return .failure(failure)
                }
                // Step 6.b.v: endDateTime = CombineISODateAndTimeRecord(end, isoDateTime.[[Time]]).
                // Step 6.b.vi: endEpochNs = GetUTCEpochNanoseconds/GetEpochNanosecondsFor. (v+vi fused)
                let endNsResult = temporalEpochNanosecondsForDateAndTime(
                    end,
                    isoTime,
                    timeZone
                )
                let endEpochNs: Int128
                switch consume endNsResult {
                case .success(let value):
                    endEpochNs = value
                case .failure(let failure):
                    return .failure(failure)
                }
                // Step 6.b.vii: Let beyondEnd be nudgedEpochNs - endEpochNs.
                // Both are epoch nanoseconds within ±8.64e21; past that it wraps.
                let beyondEnd = nudgedEpochNs &- endEpochNs
                // Step 6.b.viii: If beyondEnd < 0, beyondEndSign = -1; > 0, = 1; else 0.
                let beyondEndSign: Int32 = beyondEnd < 0 ? -1 : beyondEnd > 0 ? 1 : 0
                // Step 6.b.ix: If beyondEndSign ≠ -sign, set duration to CombineDateAndTimeDuration(endDuration, 0).
                if beyondEndSign != 0 &- sign {
                    duration = TemporalISO8601.combineDateAndTimeDuration(endDuration, 0)
                } else {
                    // Step 6.b.x: Else, set done to true.
                    done = true
                }
            }
            // Step 6.c: Set unitIndex to unitIndex - 1.
            unitIndex -= 1
        }
        // Step 7: Return duration.
        return .success(duration)
    }

    // roundRelativeDuration — temporal_rs: InternalDurationRecord::round_relative_duration (src/builtins/core/duration/normalized.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-roundrelativeduration
    static func roundRelativeDuration(
        _ duration: inout JSC.ISO8601.InternalDuration,
        _ originEpochNs: Int128,
        _ destEpochNs: Int128,
        _ isoDate: JSC.ISO8601.PlainDate,
        _ isoTime: JSC.ISO8601.PlainTime,
        _ largestUnit: JSC.TemporalUnit,
        _ increment: Double,
        _ smallestUnit: JSC.TemporalUnit,
        _ roundingMode: JSC.RoundingMode,
        _ timeZone: JSC.TimeZone?,
        _ calendarId: JSC.CalendarID
    ) -> TemporalOutcome<Void> {
        // Step 1: Let irregularLengthUnit be false.
        // Step 2: If IsCalendarUnit(smallestUnit) is true, set irregularLengthUnit to true.
        // Step 3: If timeZone is not ~unset~ and smallestUnit is ~day~, set irregularLengthUnit to true.
        var irregularLengthUnit = JSC.isCalendarUnit(smallestUnit)
        if timeZone != nil && smallestUnit == .Day {
            irregularLengthUnit = true
        }
        // Step 4: If InternalDurationSign(duration) < 0, let sign be -1; else let sign be 1.
        let sign: Int32 = TemporalISO8601.internalDurationSign(duration) < 0 ? -1 : 1

        let nudgeResult: JSC.NudgeResult
        // Step 5: If irregularLengthUnit is true, then
        if irregularLengthUnit {
            // Step 5.a: Let record be ? NudgeToCalendarUnit(...).
            let record = nudgeToCalendarUnit(
                sign,
                duration,
                originEpochNs,
                destEpochNs,
                isoDate,
                isoTime,
                increment,
                smallestUnit,
                roundingMode,
                timeZone,
                calendarId
            )
            let nudged: JSC.Nudged
            switch consume record {
            case .success(let value):
                nudged = value
            case .failure(let failure):
                return .failure(failure)
            }
            // Step 5.b: Let nudgeResult be record.[[NudgeResult]].
            nudgeResult = nudged.nudgeResult
            // Step 5.c: Let total be record.[[Total]]. (total not needed by round/until/since callers; dropped)
        } else if let timeZone {
            // Step 6.a: Let nudgeResult be ? NudgeToZonedTime(...).
            let result = nudgeToZonedTime(sign, duration, isoDate, isoTime, timeZone, increment, smallestUnit, roundingMode, calendarId)
            let nudged: JSC.NudgeResult
            switch consume result {
            case .success(let value):
                nudged = value
            case .failure(let failure):
                return .failure(failure)
            }
            nudgeResult = nudged
        } else {
            // Step 7.a: Let nudgeResult be ? NudgeToDayOrTime(...).
            let result = nudgeToDayOrTime(duration, destEpochNs, largestUnit, increment, smallestUnit, roundingMode)
            let nudged: JSC.NudgeResult
            switch consume result {
            case .success(let value):
                nudged = value
            case .failure(let failure):
                return .failure(failure)
            }
            nudgeResult = nudged
        }
        // Step 8: Set duration to nudgeResult.[[Duration]].
        duration = nudgeResult.duration
        // Step 9: If nudgeResult.[[DidExpandCalendarUnit]] is true and smallestUnit is not ~week~, then
        if nudgeResult.didExpandCalendarUnit && smallestUnit != .Week {
            // Step 9.a: Let startUnit be LargerOfTwoTemporalUnits(smallestUnit, ~day~).
            let startUnit: JSC.TemporalUnit = temporalUnitIsAtLeast(smallestUnit, .Day) ? smallestUnit : .Day
            // Step 9.b: Set duration to ? BubbleRelativeDuration(sign, duration, nudgeResult.[[NudgedEpochNs]], isoDateTime, timeZone, calendar, largestUnit, startUnit).
            let bubbled = bubbleRelativeDuration(
                sign,
                duration,
                nudgeResult.nudgedEpochNs,
                isoDate,
                isoTime,
                largestUnit,
                startUnit,
                timeZone,
                calendarId
            )
            let bubbledDuration: JSC.ISO8601.InternalDuration
            switch consume bubbled {
            case .success(let value):
                bubbledDuration = value
            case .failure(let failure):
                return .failure(failure)
            }
            duration = bubbledDuration
        }
        // Step 10: Return duration.
        return .success(())
    }
}

// MARK: - Implementations of C++ declarations
//
// Each is the definition of the `JS_EXPORT_PRIVATE` declaration it names, under its C++ symbol: `public`, so that
// JavaScriptCore exports it, with the C++ type names spelled out. Every parameter is a value.

extension JSC.TemporalCore {
    /// `TemporalCore::timeDurationFromComponents`.
    @cxx
    @implementation
    public static func timeDurationFromComponents(
        _ hours: Double,
        _ minutes: Double,
        _ seconds: Double,
        _ milliseconds: Double,
        _ microseconds: Double,
        _ nanoseconds: Double
    ) -> Int128 {
        TemporalOperations.timeDurationFromComponents(hours, minutes, seconds, milliseconds, microseconds, nanoseconds)
    }

    /// `TemporalCore::splitTimeDuration`.
    @cxx
    @implementation
    public static func splitTimeDuration(_ timeDuration: Int128) -> JSC.TemporalTimeDurationSplit {
        let (overflowDays, subdayNs) = TemporalOperations.splitTimeDuration(timeDuration)
        return JSC.TemporalTimeDurationSplit(first: overflowDays, second: subdayNs)
    }

    /// `TemporalCore::plainTimeFromSubdayNs`.
    @cxx
    @implementation
    public static func plainTimeFromSubdayNs(_ ns: Int128) -> JSC.ISO8601.PlainTime {
        TemporalOperations.plainTimeFromSubdayNs(ns)
    }

    /// `TemporalCore::totalTimeDuration`.
    @cxx
    @implementation
    public static func totalTimeDuration(_ timeDuration: Int128, _ unit: JSC.TemporalUnit) -> Double {
        TemporalOperations.totalTimeDuration(timeDuration, unit)
    }

    /// `TemporalCore::toInternalDuration`.
    @cxx
    @implementation
    public static func toInternalDuration(_ d: JSC.ISO8601.Duration) -> JSC.ISO8601.InternalDuration {
        TemporalOperations.toInternalDuration(d)
    }

    /// `TemporalCore::toInternalDurationRecord`.
    @cxx
    @implementation
    public static func toInternalDurationRecord(_ d: JSC.ISO8601.Duration) -> JSC.ISO8601.InternalDuration {
        TemporalOperations.toInternalDurationRecord(d)
    }

    /// `TemporalCore::getUTCEpochNanoseconds`.
    @cxx
    @implementation
    public static func getUTCEpochNanoseconds(_ date: JSC.ISO8601.PlainDate, _ time: JSC.ISO8601.PlainTime) -> Int128 {
        TemporalOperations.getUTCEpochNanoseconds(date, time)
    }
}

// MARK: - Functions the C++ calls

// Exclusivity of their parameters: see TemporalSupport.swift.

/// `TemporalCore::durationSign`.
@_expose(Cxx)
func temporalDurationSign(_ d: JSC.ISO8601.Duration) -> Int32 {
    TemporalOperations.durationSign(d)
}

/// `TemporalCore::negateDuration`.
@_expose(Cxx)
func temporalNegateDuration(_ d: JSC.ISO8601.Duration, _ negated: inout JSC.ISO8601.Duration) {
    negated = TemporalOperations.negateDuration(d)
}

/// `TemporalCore::absDuration`.
@_expose(Cxx)
func temporalAbsDuration(_ d: JSC.ISO8601.Duration, _ absolute: inout JSC.ISO8601.Duration) {
    absolute = TemporalOperations.absDuration(d)
}

/// `TemporalCore::largestSubduration`.
@_expose(Cxx)
func temporalLargestSubduration(_ d: JSC.ISO8601.Duration) -> JSC.TemporalUnit {
    TemporalOperations.largestSubduration(d)
}

/// `TemporalCore::temporalDurationFromInternal`.
@_expose(Cxx)
func temporalTemporalDurationFromInternal(
    _ internalDuration: JSC.ISO8601.InternalDuration,
    _ largestUnit: JSC.TemporalUnit,
    _ duration: inout JSC.ISO8601.Duration,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.temporalDurationFromInternal(internalDuration, largestUnit).store(&duration, &kind)
}

/// `TemporalCore::add24HourDaysToTimeDuration`.
@_expose(Cxx)
func temporalAdd24HourDaysToTimeDuration(
    _ d: Int128,
    _ days: Double,
    _ timeDuration: inout Int128,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.add24HourDaysToTimeDuration(d, days).store(&timeDuration, &kind)
}

/// `TemporalCore::toInternalDurationRecordWith24HourDays`.
@_expose(Cxx)
func temporalToInternalDurationRecordWith24HourDays(
    _ d: JSC.ISO8601.Duration,
    _ internalDuration: inout JSC.ISO8601.InternalDuration,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.toInternalDurationRecordWith24HourDays(d).store(&internalDuration, &kind)
}

/// `TemporalCore::toDateDurationRecordWithoutTime`.
@_expose(Cxx)
func temporalToDateDurationRecordWithoutTime(
    _ d: JSC.ISO8601.Duration,
    _ dateDuration: inout JSC.ISO8601.Duration,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.toDateDurationRecordWithoutTime(d).store(&dateDuration, &kind)
}

/// `TemporalCore::adjustDateDurationRecord`.
@_expose(Cxx)
func temporalAdjustDateDurationRecord(
    _ dateDuration: JSC.ISO8601.Duration,
    _ days: Int64,
    _ weeks: consuming JSC.TemporalOptionalInt64,
    _ months: consuming JSC.TemporalOptionalInt64,
    _ adjusted: inout JSC.ISO8601.Duration,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.adjustDateDurationRecord(dateDuration, days, weeks.value, months.value).store(&adjusted, &kind)
}

/// `TemporalCore::nudgeToCalendarUnit`.
///
/// The time zone arrives as `temporalOptional(timeZone)`.
@_expose(Cxx)
func temporalNudgeToCalendarUnit(
    _ sign: Int32,
    _ duration: JSC.ISO8601.InternalDuration,
    _ originEpochNs: Int128,
    _ destEpochNs: Int128,
    _ isoDate: JSC.ISO8601.PlainDate,
    _ isoTime: JSC.ISO8601.PlainTime,
    _ increment: Double,
    _ unit: JSC.TemporalUnit,
    _ roundingMode: JSC.RoundingMode,
    _ timeZone: consuming JSC.TemporalOptionalTimeZone,
    _ calendarId: UInt32,
    _ nudged: inout JSC.Nudged,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.nudgeToCalendarUnit(
        sign,
        duration,
        originEpochNs,
        destEpochNs,
        isoDate,
        isoTime,
        increment,
        unit,
        roundingMode,
        timeZone.value,
        calendarId
    )
    .store(&nudged, &kind)
}

/// `TemporalCore::nudgeToZonedTime`.
@_expose(Cxx)
func temporalNudgeToZonedTime(
    _ sign: Int32,
    _ duration: JSC.ISO8601.InternalDuration,
    _ isoDate: JSC.ISO8601.PlainDate,
    _ isoTime: JSC.ISO8601.PlainTime,
    _ timeZone: JSC.TimeZone,
    _ increment: Double,
    _ unit: JSC.TemporalUnit,
    _ roundingMode: JSC.RoundingMode,
    _ calendarId: UInt32,
    _ nudgeResult: inout JSC.NudgeResult,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.nudgeToZonedTime(sign, duration, isoDate, isoTime, timeZone, increment, unit, roundingMode, calendarId)
        .store(&nudgeResult, &kind)
}

/// `TemporalCore::nudgeToDayOrTime`.
@_expose(Cxx)
func temporalNudgeToDayOrTime(
    _ duration: JSC.ISO8601.InternalDuration,
    _ destEpochNs: Int128,
    _ largestUnit: JSC.TemporalUnit,
    _ increment: Double,
    _ smallestUnit: JSC.TemporalUnit,
    _ roundingMode: JSC.RoundingMode,
    _ nudgeResult: inout JSC.NudgeResult,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.nudgeToDayOrTime(duration, destEpochNs, largestUnit, increment, smallestUnit, roundingMode)
        .store(&nudgeResult, &kind)
}

/// `TemporalCore::bubbleRelativeDuration`.
///
/// The time zone arrives as `temporalOptional(timeZone)`.
@_expose(Cxx)
func temporalBubbleRelativeDuration(
    _ sign: Int32,
    _ duration: JSC.ISO8601.InternalDuration,
    _ nudgedEpochNs: Int128,
    _ isoDate: JSC.ISO8601.PlainDate,
    _ isoTime: JSC.ISO8601.PlainTime,
    _ largestUnit: JSC.TemporalUnit,
    _ smallestUnit: JSC.TemporalUnit,
    _ timeZone: consuming JSC.TemporalOptionalTimeZone,
    _ calendarId: UInt32,
    _ bubbled: inout JSC.ISO8601.InternalDuration,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.bubbleRelativeDuration(
        sign,
        duration,
        nudgedEpochNs,
        isoDate,
        isoTime,
        largestUnit,
        smallestUnit,
        timeZone.value,
        calendarId
    )
    .store(&bubbled, &kind)
}

/// `TemporalCore::roundRelativeDuration`: `duration` is the caller's lvalue, rounded in place, and left as rounded so
/// far when a later step fails.
///
/// The time zone arrives as `temporalOptional(timeZone)`.
///
/// `duration` is treated as exclusive for the call. The caller's reference is the only one the call is given: the
/// C++ the body calls (the ICU bridge functions, `epochCandidates`) takes a time zone, dates and epoch nanoseconds by
/// value, and nothing it is given can reach the caller's `InternalDuration`.
@_expose(Cxx)
func temporalRoundRelativeDuration(
    _ duration: inout JSC.ISO8601.InternalDuration,
    _ originEpochNs: Int128,
    _ destEpochNs: Int128,
    _ isoDate: JSC.ISO8601.PlainDate,
    _ isoTime: JSC.ISO8601.PlainTime,
    _ largestUnit: JSC.TemporalUnit,
    _ increment: Double,
    _ smallestUnit: JSC.TemporalUnit,
    _ roundingMode: JSC.RoundingMode,
    _ timeZone: consuming JSC.TemporalOptionalTimeZone,
    _ calendarId: UInt32,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.roundRelativeDuration(
        &duration,
        originEpochNs,
        destEpochNs,
        isoDate,
        isoTime,
        largestUnit,
        increment,
        smallestUnit,
        roundingMode,
        timeZone.value,
        calendarId
    )
    .store(&kind)
}
