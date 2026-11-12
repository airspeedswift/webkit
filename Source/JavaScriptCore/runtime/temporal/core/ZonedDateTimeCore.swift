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

// JSC Temporal Core — ZonedDateTime algorithms
// temporal_rs reference: src/builtins/core/zoned_date_time.rs
// Last synced: v0.2.3

extension TemporalOperations {
    // InterpretISODateTimeOffset — temporal_rs: interpret_isodatetime_offset in zoned_date_time.rs
    // https://tc39.es/proposal-temporal/#sec-temporal-interpretisodatetimeoffset
    static func interpretISODateTimeOffset(
        _ date: JSC.ISO8601.PlainDate,
        _ time: JSC.ISO8601.PlainTime,
        _ useStartOfDay: JSC.TemporalCore.UseStartOfDay,
        _ offsetBehaviour: JSC.OffsetBehaviour,
        _ offsetOpt: JSC.TemporalOffsetDisambiguation,
        _ inlineOffsetNs: Int64,
        _ matchBehaviour: JSC.TemporalCore.MatchBehaviour,
        _ timeZone: JSC.TimeZone,
        _ disambiguation: JSC.TemporalDisambiguation
    ) -> TemporalOutcome<JSC.ISO8601.ExactTime> {
        // Step 1: If time is start-of-day, then
        if useStartOfDay == .Yes {
            // 1.a: Assert offsetBehaviour is wall. 1.b: Assert inlineOffsetNs is 0.
            return getStartOfDay(timeZone, date) // 1.c
        }

        // Step 2: isoDateTime = CombineISODateAndTimeRecord(isoDate, time). (implicit — date+time passed separately)
        // Step 3: If offsetBehaviour is wall, or offsetBehaviour is option and offsetOption is ignore.
        if offsetBehaviour == .Wall
            || (offsetBehaviour == .Option && offsetOpt == .Ignore)
        {
            let epochNs = JSC.TemporalCore.getEpochNanosecondsFor(timeZone, date, time, disambiguation)
            if !epochNs.has_value() {
                return .failure(TemporalFailure(JSC.temporalErrorOf(epochNs)))
            }
            return .success((JSC.temporalValueOf(epochNs) as JSC.ISO8601.ExactTime))
        }

        // Step 4: offsetBehaviour is exact or option+use: compute epoch ns = UTC(date,time) - offset.
        // Steps 4a-4d fused: GetUTCEpochNanoseconds(date,time) - offset ≡ BalanceISODateTime + GetUTCEpochNanoseconds
        // since both are linear; IsValidEpochNanoseconds ↔ CheckISODaysRange (same ±10^8 day bound).
        if offsetBehaviour == .Exact
            || (offsetBehaviour == .Option && offsetOpt == .Use)
        {
            let naiveNs = TemporalOperations.getUTCEpochNanoseconds(date, time)
            // Cannot overflow: a PlainDate's epoch nanoseconds are within ±2^90 and the offset is an Int64.
            let result = JSC.ISO8601.ExactTime(naiveNs &- Int128(inlineOffsetNs))
            if !result.isValid() {
                return .failure(.range("date/time offset combination is outside the supported range for Temporal.ZonedDateTime"))
            }
            return .success(result)
        }

        // Step 5: Assert offsetBehaviour is option.
        // Step 6: Assert offsetOption is prefer or reject.
        // Step 7: CheckISODaysRange(isoDate).
        if abs(WTF.dateToDaysFrom1970(date.year(), Int32(date.month()) - 1, Int32(date.day()))) > 1e8 {
            return .failure(.range("wall-clock date is outside the representable range for Temporal.ZonedDateTime"))
        }

        // Step 8: utcEpochNanoseconds = GetUTCEpochNanoseconds(isoDateTime).
        let utcEpochNs = TemporalOperations.getUTCEpochNanoseconds(date, time)

        // Step 9: possibleEpochNs = GetPossibleEpochNanoseconds(timeZone, isoDateTime).
        let possibleResult = JSC.TemporalCore.getPossibleEpochNanosecondsFor(timeZone, date, time)
        if !possibleResult.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(possibleResult)))
        }
        let possible = (JSC.temporalValueOf(possibleResult) as JSC.TemporalCore.PossibleEpochNanoseconds)

        // Step 10: For each element candidate of possibleEpochNs.
        // The candidates are a Span borrowed from `possible` (epochCandidates is LIFETIME_BOUND), so each read is
        // bounds-checked and none outlives `possible`.
        let matchMinutes = matchBehaviour == .minutes
        let candidates: Span<JSC.ISO8601.ExactTime> = JSC.TemporalCore.epochCandidates(possible)
        for index in candidates.indices {
            let candidate = candidates[index]
            // Step 10a: candidateOffset = utcEpochNanoseconds - candidate.
            // Cannot overflow: both are epoch nanoseconds of dates within ±1e8 days (step 7), well inside ±2^126.
            let candidateOffset = utcEpochNs &- candidate.epochNanoseconds()
            // Step 10b: If candidateOffset = offsetNanoseconds, return candidate.
            if candidateOffset == Int128(inlineOffsetNs) {
                return .success(candidate)
            }
            // Step 10c: If matchBehaviour is match-minutes, check rounded.
            if matchMinutes {
                if TemporalOperations.roundNumberToIncrementInt128(candidateOffset, TemporalExactTime.nsPerMinute, .HalfExpand)
                    == Int128(inlineOffsetNs)
                {
                    return .success(candidate)
                }
            }
        }

        // Step 11: If offsetOption is reject, throw RangeError.
        if offsetOpt == .Reject {
            return .failure(.range("offset does not agree with timezone for the given date/time"))
        }

        // Step 12: Return ? DisambiguatePossibleEpochNanoseconds(possibleEpochNs, timeZone, isoDateTime, disambiguation).
        // Note: getEpochNanosecondsFor recomputes possibleEpochNs; functionally equivalent.
        let epochNs = JSC.TemporalCore.getEpochNanosecondsFor(timeZone, date, time, disambiguation)
        if !epochNs.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(epochNs)))
        }
        return .success((JSC.temporalValueOf(epochNs) as JSC.ISO8601.ExactTime))
    }

    // GetStartOfDay — temporal_rs: TimeZone::get_start_of_day(iso_date, provider)
    // https://tc39.es/proposal-temporal/#sec-temporal-getstartofday
    static func getStartOfDay(_ tz: JSC.TimeZone, _ date: JSC.ISO8601.PlainDate) -> TemporalOutcome<JSC.ISO8601.ExactTime> {
        // Step 1: isoDateTime = CombineISODateAndTimeRecord(isoDate, MidnightTimeRecord()).
        let midnight = JSC.ISO8601.PlainTime()
        // Step 2: possibleEpochNs = GetPossibleEpochNanoseconds(timeZone, isoDateTime).
        let possibleResult = JSC.TemporalCore.getPossibleEpochNanosecondsFor(tz, date, midnight)
        if !possibleResult.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(possibleResult)))
        }
        let possible = (JSC.temporalValueOf(possibleResult) as JSC.TemporalCore.PossibleEpochNanoseconds)
        // Step 3: If possibleEpochNs is not empty, return possibleEpochNs[0].
        if !JSC.TemporalCore.isGap(possible) {
            // Not a gap, so at least one candidate; [0] traps on an empty span, as the hardened std::span does.
            let candidates: Span<JSC.ISO8601.ExactTime> = JSC.TemporalCore.epochCandidates(possible)
            let candidate = candidates[0]
            // Validate: the start-of-day epoch must be within Temporal range.
            // e.g. midnight of +275760-09-13 in America/Vancouver = UTC+7h > max epoch.
            if !candidate.isValid() {
                return .failure(.range("start of day is outside the representable range of Temporal.ZonedDateTime"))
            }
            return .success(candidate)
        }
        // Step 4: Assert IsOffsetTimeZoneIdentifier(timeZone) is false (gap is only possible for IANA zones).
        // Step 5: possibleEpochNsAfter = first instant after the gap transition.
        // We find it via: getEpochNanosecondsFor(Earlier) -> last instant before gap,
        // then getTimeZoneTransition(Next) -> first instant after gap.
        let beforeGap = JSC.TemporalCore.getEpochNanosecondsFor(tz, date, midnight, .Earlier)
        if !beforeGap.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(beforeGap)))
        }
        let transition = JSC.TemporalCore.getTimeZoneTransition(tz, (JSC.temporalValueOf(beforeGap) as JSC.ISO8601.ExactTime), .Next)
        if !transition.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(transition)))
        }
        guard let next = Optional(fromCxx: JSC.temporalValueOf(transition) as JSC.TemporalOptionalExactTime) else {
            return .failure(.range("no start of day: time zone has no future transitions"))
        }
        // Step 6: Assert: The number of elements in possibleEpochNsAfter = 1.
        // Step 7: Return the sole element of possibleEpochNsAfter.
        return .success(next)
    }

    // DifferenceZonedDateTime — temporal_rs: ZonedDateTime::diff_zoned_datetime inner path
    // https://tc39.es/proposal-temporal/#sec-temporal-differencezoneddatetime
    fileprivate static func differenceZonedDateTime(
        _ ns1: JSC.ISO8601.ExactTime,
        _ ns2: JSC.ISO8601.ExactTime,
        _ timeZone: JSC.TimeZone,
        _ calendarId: JSC.CalendarID,
        _ largestUnit: JSC.TemporalUnit
    ) -> TemporalOutcome<JSC.ISO8601.InternalDuration> {
        let nsA = ns1.epochNanoseconds()
        let nsB = ns2.epochNanoseconds()

        // Step 1: If ns1 = ns2, return zero.
        if nsA == nsB {
            return .success(TemporalISO8601.combineDateAndTimeDuration(JSC.ISO8601.Duration(), 0))
        }

        // Steps 2–3: GetISODateTimeFor(timeZone, ns1/ns2).
        let startResult = JSC.TemporalCore.getISODateTimeFor(timeZone, ns1)
        if !startResult.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(startResult)))
        }
        let endResult = JSC.TemporalCore.getISODateTimeFor(timeZone, ns2)
        if !endResult.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(endResult)))
        }
        let start = (JSC.temporalValueOf(startResult) as JSC.ISO8601.PlainDateTime)
        let end = (JSC.temporalValueOf(endResult) as JSC.ISO8601.PlainDateTime)
        let startDate = start.date
        let startTime = start.time
        let endDate = end.date
        let endTime = end.time

        // Epoch nanoseconds of two ExactTimes: the difference cannot overflow Int128.
        let difference = nsB &- nsA

        // Step 4: If startDate = endDate -> timeDuration = ns2 - ns1, return.
        if TemporalOperations.isoDateCompare(startDate, endDate) == 0 {
            return .success(TemporalISO8601.combineDateAndTimeDuration(JSC.ISO8601.Duration(), difference))
        }

        // Step 5: sign = (ns2 - ns1 < 0) ? 1 : -1.
        let sign: Int32 = difference < 0 ? 1 : -1
        // Step 6: maxDayCorrection = (sign=-1) ? 2 : 1.
        let maxDayCorrection: Int32 = sign == -1 ? 2 : 1
        // Step 7: dayCorrection = 0.
        var dayCorrection: Int32 = 0
        // Step 8: timeDuration = DifferenceTime(startTime, endTime).
        let timeDiff = TemporalOperations.timeDurationFromComponents(
            Double(endTime.hour()) - Double(startTime.hour()),
            Double(endTime.minute()) - Double(startTime.minute()),
            Double(endTime.second()) - Double(startTime.second()),
            Double(endTime.millisecond()) - Double(startTime.millisecond()),
            Double(endTime.microsecond()) - Double(startTime.microsecond()),
            Double(endTime.nanosecond()) - Double(startTime.nanosecond())
        )
        // Step 9: If TimeDurationSign(timeDuration) = sign -> dayCorrection++.
        let timeSign: Int32 = timeDiff < 0 ? -1 : timeDiff > 0 ? 1 : 0
        if timeSign == sign {
            dayCorrection += 1
        }

        // Step 10: success = false.
        // Step 11: Repeat while dayCorrection ≤ maxDayCorrection and success = false.
        var intermediateDate = endDate
        var adjustedTimeDiff = timeDiff
        var success = false
        while dayCorrection <= maxDayCorrection && !success {
            // Step 11.a: intermediateDate = AddDaysToISODate(endDate, dayCorrection × sign).
            intermediateDate = TemporalOperations.addDaysToISODate(endDate, Int64(dayCorrection) * Int64(sign))
            // Step 11.b: intermediateDateTime = CombineISODateAndTimeRecord(intermediateDate, startTime).
            // Step 11.c: intermediateNs = GetEpochNanosecondsFor(timeZone, intermediateDateTime, compatible). (11.b+11.c fused)
            let intermediateNsResult = JSC.TemporalCore.getEpochNanosecondsFor(timeZone, intermediateDate, startTime, .Compatible)
            if !intermediateNsResult.has_value() {
                return .failure(TemporalFailure(JSC.temporalErrorOf(intermediateNsResult)))
            }
            // Step 11.d: timeDuration = TimeDurationFromEpochNanosecondsDifference(ns2, intermediateNs).
            // Cannot overflow: both are epoch nanoseconds of ExactTimes.
            adjustedTimeDiff = nsB &- (JSC.temporalValueOf(intermediateNsResult) as JSC.ISO8601.ExactTime).epochNanoseconds()
            // Step 11.e: timeSign = TimeDurationSign(timeDuration).
            let adjTimeSign: Int32 = adjustedTimeDiff < 0 ? -1 : adjustedTimeDiff > 0 ? 1 : 0
            // Step 11.f: If sign ≠ timeSign, success = true.
            if sign != adjTimeSign {
                success = true
            }
            // Step 11.g: dayCorrection++.
            dayCorrection += 1
        }
        // Step 12: Assert: success is true.

        // Step 13: dateLargestUnit = LargerOfTwoTemporalUnits(largestUnit, day).
        let dateLargestUnit: JSC.TemporalUnit = largestUnit.rawValue > JSC.TemporalUnit.Day.rawValue ? .Day : largestUnit
        // Step 14: dateDifference = CalendarDateUntil(startDate, intermediateDate, dateLargestUnit).
        let dateDiff: JSC.ISO8601.Duration
        switch TemporalOperations.calendarDateUntil(calendarId, startDate, intermediateDate, dateLargestUnit) {
        case .success(let value):
            dateDiff = value
        case .failure(let failure):
            return .failure(failure)
        }

        // Step 15: Return CombineDateAndTimeDuration(dateDifference, timeDuration).
        // Each date field passes through `double` into Duration's int64_t parameters.
        let datePart = JSC.ISO8601.Duration(
            temporalTruncatingInt64(Double(dateDiff.years())),
            temporalTruncatingInt64(Double(dateDiff.months())),
            temporalTruncatingInt64(Double(dateDiff.weeks())),
            temporalTruncatingInt64(Double(dateDiff.days())),
            0,
            0,
            0,
            0,
            0,
            0
        )
        return .success(TemporalISO8601.combineDateAndTimeDuration(datePart, adjustedTimeDiff))
    }

    // DifferenceZonedDateTimeWithRounding — temporal_rs: ZonedDateTime::diff_zoned_datetime (src/builtins/core/zoned_date_time.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-differencezoneddatetimewithrounding
    static func differenceZonedDateTimeWithRounding(
        _ ns1: JSC.ISO8601.ExactTime,
        _ ns2: JSC.ISO8601.ExactTime,
        _ timeZone: JSC.TimeZone,
        _ largestUnit: JSC.TemporalUnit,
        _ smallestUnit: JSC.TemporalUnit,
        _ roundingMode: JSC.RoundingMode,
        _ increment: Double,
        _ calendarId: JSC.CalendarID
    ) -> TemporalOutcome<JSC.ISO8601.InternalDuration> {
        let nsA = ns1.epochNanoseconds()
        let nsB = ns2.epochNanoseconds()

        // Step 1: If largestUnit is time category -> DifferenceInstant (pure nanosecond arithmetic).
        if largestUnit.rawValue > JSC.TemporalUnit.Day.rawValue {
            // Cannot overflow: both are epoch nanoseconds of ExactTimes.
            let nsTotal = nsB &- nsA
            var internalDuration = TemporalISO8601.combineDateAndTimeDuration(JSC.ISO8601.Duration(), nsTotal)
            // Step 3: If smallestUnit=nanosecond and increment=1 -> return difference without rounding.
            if smallestUnit != .Nanosecond || increment != 1 {
                // Wraps on overflow. A validated increment (≤ 1e9) times a
                // unit (≤ 8.64e13 ns) is far inside Int128.
                let roundedTime = TemporalOperations.roundNumberToIncrementInt128(
                    internalDuration.time(),
                    JSC.lengthInNanoseconds(smallestUnit) &* temporalTruncatingInt128(increment.rounded(.towardZero)),
                    roundingMode
                )
                internalDuration = TemporalISO8601.combineDateAndTimeDuration(JSC.ISO8601.Duration(), roundedTime)
            }
            return .success(internalDuration)
        }

        // Step 2: difference = DifferenceZonedDateTime(ns1, ns2, timeZone, calendar, largestUnit).
        let differenceResult = differenceZonedDateTime(ns1, ns2, timeZone, calendarId, largestUnit)
        guard case .success(var internalDuration) = differenceResult else {
            return .failure(temporalValue(differenceResult.failure))
        }

        // Step 3: If smallestUnit=nanosecond and increment=1 -> return difference.
        if smallestUnit == .Nanosecond && increment == 1 {
            return .success(internalDuration)
        }

        // Step 4: dateTime = GetISODateTimeFor(timeZone, ns1).
        let startResult = JSC.TemporalCore.getISODateTimeFor(timeZone, ns1)
        if !startResult.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(startResult)))
        }
        let start = (JSC.temporalValueOf(startResult) as JSC.ISO8601.PlainDateTime)

        // Step 5: Return RoundRelativeDuration(difference, ns1, ns2, dateTime, ...).
        // roundRelativeDuration rounds internalDuration in place; it is what is returned.
        if case .failure(let failure) = TemporalOperations.roundRelativeDuration(
            &internalDuration,
            nsA,
            nsB,
            start.date,
            start.time,
            largestUnit,
            increment,
            smallestUnit,
            roundingMode,
            timeZone,
            calendarId
        ) {
            return .failure(failure)
        }
        return .success(internalDuration)
    }
}

// MARK: - Functions the C++ calls

// Exclusivity of their parameters: see TemporalSupport.swift.

/// `TemporalCore::interpretISODateTimeOffset`.
@_expose(Cxx)
func temporalInterpretISODateTimeOffset(
    _ date: JSC.ISO8601.PlainDate,
    _ time: JSC.ISO8601.PlainTime,
    _ useStartOfDay: JSC.TemporalCore.UseStartOfDay,
    _ offsetBehaviour: JSC.OffsetBehaviour,
    _ offsetOpt: JSC.TemporalOffsetDisambiguation,
    _ inlineOffsetNs: Int64,
    _ matchBehaviour: JSC.TemporalCore.MatchBehaviour,
    _ timeZone: JSC.TimeZone,
    _ disambiguation: JSC.TemporalDisambiguation,
    _ value: inout JSC.ISO8601.ExactTime,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.interpretISODateTimeOffset(
        date,
        time,
        useStartOfDay,
        offsetBehaviour,
        offsetOpt,
        inlineOffsetNs,
        matchBehaviour,
        timeZone,
        disambiguation
    )
    .store(&value, &kind)
}

/// `TemporalCore::getStartOfDay`.
@_expose(Cxx)
func temporalGetStartOfDay(
    _ timeZone: JSC.TimeZone,
    _ date: JSC.ISO8601.PlainDate,
    _ value: inout JSC.ISO8601.ExactTime,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.getStartOfDay(timeZone, date).store(&value, &kind)
}

/// `TemporalCore::differenceZonedDateTimeWithRounding`.
@_expose(Cxx)
func temporalDifferenceZonedDateTimeWithRounding(
    _ ns1: JSC.ISO8601.ExactTime,
    _ ns2: JSC.ISO8601.ExactTime,
    _ timeZone: JSC.TimeZone,
    _ largestUnit: JSC.TemporalUnit,
    _ smallestUnit: JSC.TemporalUnit,
    _ roundingMode: JSC.RoundingMode,
    _ increment: Double,
    _ calendarId: UInt32,
    _ value: inout JSC.ISO8601.InternalDuration,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.differenceZonedDateTimeWithRounding(
        ns1,
        ns2,
        timeZone,
        largestUnit,
        smallestUnit,
        roundingMode,
        increment,
        calendarId
    )
    .store(&value, &kind)
}
