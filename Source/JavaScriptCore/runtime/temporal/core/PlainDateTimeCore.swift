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

// JSC Temporal Core — PlainDateTime algorithms
// temporal_rs reference: src/builtins/core/plain_date_time.rs
// Last synced: v0.2.3

extension TemporalOperations {
    // CompareISODateTime — temporal_rs: PlainDateTime::compare_iso (pure)
    // https://tc39.es/proposal-temporal/#sec-temporal-compareisodatetime
    static func compareISODateTime(
        _ d1: JSC.ISO8601.PlainDate,
        _ t1: JSC.ISO8601.PlainTime,
        _ d2: JSC.ISO8601.PlainDate,
        _ t2: JSC.ISO8601.PlainTime
    ) -> Int32 {
        // Step 1: Let dateResult be CompareISODate(isoDateTime1.[[ISODate]], isoDateTime2.[[ISODate]]).
        // Step 2: If dateResult ≠ 0, return dateResult.
        let r = isoDateCompare(d1, d2)
        if r != 0 {
            return r
        }
        // Step 3: Return CompareTimeRecord(isoDateTime1.[[Time]], isoDateTime2.[[Time]]).
        return isoTimeCompare(t1, t2)
    }

    // DifferencePlainDateTimeWithRounding — temporal_rs: PlainDateTime::diff inner path
    // https://tc39.es/proposal-temporal/#sec-temporal-differenceplaindatetimewithrounding
    static func differencePlainDateTimeWithRounding(
        _ thisDate: JSC.ISO8601.PlainDate,
        _ thisTime: JSC.ISO8601.PlainTime,
        _ otherDate: JSC.ISO8601.PlainDate,
        _ otherTime: JSC.ISO8601.PlainTime,
        _ calendarId: JSC.CalendarID,
        _ largestUnit: JSC.TemporalUnit,
        _ smallestUnit: JSC.TemporalUnit,
        _ roundingMode: JSC.RoundingMode,
        _ increment: Double
    ) -> TemporalOutcome<JSC.ISO8601.InternalDuration> {
        // Step 1: If CompareISODateTime(isoDateTime1, isoDateTime2) = 0, return zero InternalDuration.
        if thisDate == otherDate && thisTime == otherTime {
            return .success(JSC.ISO8601.InternalDuration())
        }

        // Step 2: If ISODateTimeWithinLimits is false for either endpoint, throw a RangeError.
        if !TemporalISO8601.isDateTimeWithinLimits(
            thisDate.year(),
            thisDate.month(),
            thisDate.day(),
            thisTime.hour(),
            thisTime.minute(),
            thisTime.second(),
            thisTime.millisecond(),
            thisTime.microsecond(),
            thisTime.nanosecond()
        )
            || !TemporalISO8601.isDateTimeWithinLimits(
                otherDate.year(),
                otherDate.month(),
                otherDate.day(),
                otherTime.hour(),
                otherTime.minute(),
                otherTime.second(),
                otherTime.millisecond(),
                otherTime.microsecond(),
                otherTime.nanosecond()
            )
        {
            return .failure(.range("date-time is outside the representable range for Temporal"))
        }

        // Step 3: diff = DifferenceISODateTime(isoDateTime1, isoDateTime2, calendar, largestUnit).
        var diff: JSC.ISO8601.InternalDuration
        if calendarId != JSC.iso8601CalendarID() {
            var timeDiff = TemporalOperations.timeDurationFromComponents(
                Double(otherTime.hour()) - Double(thisTime.hour()),
                Double(otherTime.minute()) - Double(thisTime.minute()),
                Double(otherTime.second()) - Double(thisTime.second()),
                Double(otherTime.millisecond()) - Double(thisTime.millisecond()),
                Double(otherTime.microsecond()) - Double(thisTime.microsecond()),
                Double(otherTime.nanosecond()) - Double(thisTime.nanosecond())
            )
            let timeSign: Int32 = timeDiff < 0 ? -1 : timeDiff > 0 ? 1 : 0
            let dateSign = isoDateCompare(thisDate, otherDate)
            var adjustedD2 = otherDate
            if dateSign != 0 && timeSign != 0 && dateSign == timeSign {
                adjustedD2 = addDaysToISODate(adjustedD2, Int64(dateSign))
                // Cannot overflow: a difference of two PlainTimes is under 2^76 ns.
                timeDiff &-= Int128(dateSign) &* TemporalExactTime.nsPerDay
            }
            let dateLargestUnit: JSC.TemporalUnit = largestUnit.rawValue > JSC.TemporalUnit.Day.rawValue ? .Day : largestUnit
            let dateDiffResult = JSC.TemporalCore.calendarDateUntil(calendarId, thisDate, adjustedD2, dateLargestUnit)
            guard dateDiffResult.has_value() else {
                return .failure(TemporalFailure(JSC.temporalErrorOf(dateDiffResult)))
            }
            let dateDiff = (JSC.temporalValueOf(dateDiffResult) as JSC.ISO8601.Duration)
            if largestUnit.rawValue > JSC.TemporalUnit.Day.rawValue {
                // Wraps only for a days count near 2^64; the bridge's are below 2^31.
                timeDiff &+= Int128(dateDiff.days()) &* TemporalExactTime.nsPerDay
            }
            diff = TemporalISO8601.combineDateAndTimeDuration(
                JSC.ISO8601.Duration(
                    dateDiff.years(),
                    dateDiff.months(),
                    dateDiff.weeks(),
                    largestUnit.rawValue > JSC.TemporalUnit.Day.rawValue ? 0 : dateDiff.days(),
                    0,
                    0,
                    0,
                    0,
                    0,
                    0
                ),
                timeDiff
            )
        } else {
            diff = diffISODateTime(thisDate, thisTime, otherDate, otherTime, largestUnit)
        }

        // Step 4: If smallestUnit=nanosecond and increment=1, return diff.
        if smallestUnit == .Nanosecond && increment == 1 {
            return .success(diff)
        }

        // Step 5: originEpochNs = GetUTCEpochNanoseconds(isoDateTime1).
        let originEpochNs = TemporalOperations.getUTCEpochNanoseconds(thisDate, thisTime)
        // Step 6: destEpochNs = GetUTCEpochNanoseconds(isoDateTime2).
        let destEpochNs = TemporalOperations.getUTCEpochNanoseconds(otherDate, otherTime)
        // Step 7: Return ? RoundRelativeDuration(diff, originEpochNs, destEpochNs, isoDateTime1, unset, ...).
        if case .failure(let failure) = TemporalOperations.roundRelativeDuration(
            &diff,
            originEpochNs,
            destEpochNs,
            thisDate,
            thisTime,
            largestUnit,
            increment,
            smallestUnit,
            roundingMode,
            nil,
            calendarId
        ) {
            return .failure(failure)
        }
        return .success(diff)
    }

    // DifferenceTemporalPlainDateTime — temporal_rs: PlainDateTime::diff (src/builtins/core/plain_date_time.rs; until/since call this)
    // https://tc39.es/proposal-temporal/#sec-temporal-differencetemporalplaindatetime
    // Steps 1-4 (ToTemporalDateTime, CalendarEquals, GetOptionsObject, GetDifferenceSettings)
    // are handled by the JS layer before calling this function.
    static func differenceTemporalPlainDateTime(
        _ op: JSC.DifferenceOperation,
        _ thisDate: JSC.ISO8601.PlainDate,
        _ thisTime: JSC.ISO8601.PlainTime,
        _ otherDate: JSC.ISO8601.PlainDate,
        _ otherTime: JSC.ISO8601.PlainTime,
        _ calendarId: JSC.CalendarID,
        _ smallestUnit: JSC.TemporalUnit,
        _ largestUnit: JSC.TemporalUnit,
        _ roundingMode: JSC.RoundingMode,
        _ increment: Double
    ) -> TemporalOutcome<JSC.ISO8601.Duration> {
        assert(largestUnit.rawValue <= smallestUnit.rawValue)
        assert(increment >= 1)
        // Step 5: If CompareISODateTime = 0, return zero duration.
        if thisDate == otherDate && thisTime == otherTime {
            return .success(JSC.ISO8601.Duration())
        }

        // Step 6: internalDuration = DifferencePlainDateTimeWithRounding(...).
        let internalDuration: JSC.ISO8601.InternalDuration
        switch differencePlainDateTimeWithRounding(
            thisDate,
            thisTime,
            otherDate,
            otherTime,
            calendarId,
            largestUnit,
            smallestUnit,
            roundingMode,
            increment
        ) {
        case .success(let value):
            internalDuration = value
        case .failure(let failure):
            return .failure(failure)
        }

        // Step 7: result = TemporalDurationFromInternal(internalDuration, largestUnit).
        let result: JSC.ISO8601.Duration
        switch TemporalOperations.temporalDurationFromInternal(internalDuration, largestUnit) {
        case .success(let value): result = value
        case .failure(let failure): return .failure(failure)
        }
        // Step 8: If operation is since, set result to CreateNegatedTemporalDuration(result).
        // Duration's operator-; an INT64_MIN field wraps to itself.
        if op == .Since {
            return .success(-result)
        }
        // Step 9: Return result.
        return .success(result)
    }
}

// MARK: - Implementations of C++ declarations
//
// Each is the definition of the `JS_EXPORT_PRIVATE` declaration it names, under its C++ symbol: `public`, so that
// JavaScriptCore exports it, with the C++ type names spelled out. Every parameter is a value.

extension JSC.TemporalCore {
    /// `TemporalCore::compareISODateTime`.
    @cxx
    @implementation
    public static func compareISODateTime(
        _ d1: JSC.ISO8601.PlainDate,
        _ t1: JSC.ISO8601.PlainTime,
        _ d2: JSC.ISO8601.PlainDate,
        _ t2: JSC.ISO8601.PlainTime
    ) -> Int32 {
        TemporalOperations.compareISODateTime(d1, t1, d2, t2)
    }
}

// MARK: - Functions the C++ calls

// Exclusivity of their parameters: see TemporalSupport.swift.

/// `TemporalCore::differencePlainDateTimeWithRounding`.
@_expose(Cxx)
func temporalDifferencePlainDateTimeWithRounding(
    _ thisDate: JSC.ISO8601.PlainDate,
    _ thisTime: JSC.ISO8601.PlainTime,
    _ otherDate: JSC.ISO8601.PlainDate,
    _ otherTime: JSC.ISO8601.PlainTime,
    _ calendarId: UInt32,
    _ largestUnit: JSC.TemporalUnit,
    _ smallestUnit: JSC.TemporalUnit,
    _ roundingMode: JSC.RoundingMode,
    _ increment: Double,
    _ value: inout JSC.ISO8601.InternalDuration,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.differencePlainDateTimeWithRounding(
        thisDate,
        thisTime,
        otherDate,
        otherTime,
        calendarId,
        largestUnit,
        smallestUnit,
        roundingMode,
        increment
    )
    .store(&value, &kind)
}

/// `TemporalCore::differenceTemporalPlainDateTime`.
@_expose(Cxx)
func temporalDifferenceTemporalPlainDateTime(
    _ op: JSC.DifferenceOperation,
    _ thisDate: JSC.ISO8601.PlainDate,
    _ thisTime: JSC.ISO8601.PlainTime,
    _ otherDate: JSC.ISO8601.PlainDate,
    _ otherTime: JSC.ISO8601.PlainTime,
    _ calendarId: UInt32,
    _ smallestUnit: JSC.TemporalUnit,
    _ largestUnit: JSC.TemporalUnit,
    _ roundingMode: JSC.RoundingMode,
    _ increment: Double,
    _ value: inout JSC.ISO8601.Duration,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.differenceTemporalPlainDateTime(
        op,
        thisDate,
        thisTime,
        otherDate,
        otherTime,
        calendarId,
        smallestUnit,
        largestUnit,
        roundingMode,
        increment
    )
    .store(&value, &kind)
}
