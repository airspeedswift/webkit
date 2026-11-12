/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "DurationArithmetic.h"

#include "TemporalSwiftBoundary.h"

#include "JSCSwift-Swift.h"

namespace JSC {
namespace TemporalCore {

int durationSign(const ISO8601::Duration& d)
{
    return JSCSwift::temporalDurationSign(d);
}

ISO8601::Duration negateDuration(const ISO8601::Duration& d)
{
    return temporalOutput<ISO8601::Duration>(JSCSwift::temporalNegateDuration, d);
}

ISO8601::Duration absDuration(const ISO8601::Duration& d)
{
    return temporalOutput<ISO8601::Duration>(JSCSwift::temporalAbsDuration, d);
}

TemporalUnit LEGACY_NODELETE largestSubduration(const ISO8601::Duration& d)
{
    return JSCSwift::temporalLargestSubduration(d);
}

TemporalResult<ISO8601::Duration> temporalDurationFromInternal(ISO8601::InternalDuration internalDuration, TemporalUnit largestUnit)
{
    return temporalResult<ISO8601::Duration>(JSCSwift::temporalTemporalDurationFromInternal, internalDuration, largestUnit);
}

TemporalResult<Int128> add24HourDaysToTimeDuration(Int128 d, double days)
{
    return temporalResult<Int128>(JSCSwift::temporalAdd24HourDaysToTimeDuration, d, days);
}

TemporalResult<ISO8601::InternalDuration> toInternalDurationRecordWith24HourDays(ISO8601::Duration d)
{
    return temporalResult<ISO8601::InternalDuration>(JSCSwift::temporalToInternalDurationRecordWith24HourDays, d);
}

TemporalResult<ISO8601::Duration> toDateDurationRecordWithoutTime(ISO8601::Duration duration)
{
    return temporalResult<ISO8601::Duration>(JSCSwift::temporalToDateDurationRecordWithoutTime, duration);
}

TemporalResult<ISO8601::Duration> adjustDateDurationRecord(const ISO8601::Duration& dateDuration, int64_t days, std::optional<int64_t> weeks, std::optional<int64_t> months)
{
    return temporalResult<ISO8601::Duration>(JSCSwift::temporalAdjustDateDurationRecord, dateDuration, days, weeks, months);
}

TemporalResult<Nudged> nudgeToCalendarUnit(int32_t sign,
    const ISO8601::InternalDuration& duration, Int128 originEpochNs, Int128 destEpochNs,
    ISO8601::PlainDate isoDate, ISO8601::PlainTime isoTime, double increment,
    TemporalUnit unit, RoundingMode roundingMode, const TimeZone* timeZone, CalendarID calendarId)
{
    return temporalResult<Nudged>(JSCSwift::temporalNudgeToCalendarUnit, sign, duration, originEpochNs, destEpochNs, isoDate, isoTime, increment, unit, roundingMode, temporalOptional(timeZone), calendarId);
}

TemporalResult<NudgeResult> nudgeToZonedTime(int32_t sign,
    const ISO8601::InternalDuration& duration, ISO8601::PlainDate isoDate,
    ISO8601::PlainTime isoTime, const TimeZone& timeZone, double increment,
    TemporalUnit unit, RoundingMode roundingMode, CalendarID calendarId)
{
    return temporalResult<NudgeResult>(JSCSwift::temporalNudgeToZonedTime, sign, duration, isoDate, isoTime, timeZone, increment, unit, roundingMode, calendarId);
}

TemporalResult<NudgeResult> nudgeToDayOrTime(ISO8601::InternalDuration duration,
    Int128 destEpochNs, TemporalUnit largestUnit, double increment,
    TemporalUnit smallestUnit, RoundingMode roundingMode)
{
    static_assert(lengthInNanoseconds(TemporalUnit::Day) == ISO8601::ExactTime::nsPerDay, "DurationArithmetic.swift's nudgeToDayOrTime takes a day's length as ExactTime::nsPerDay");
    return temporalResult<NudgeResult>(JSCSwift::temporalNudgeToDayOrTime, duration, destEpochNs, largestUnit, increment, smallestUnit, roundingMode);
}

TemporalResult<ISO8601::InternalDuration> bubbleRelativeDuration(
    int32_t sign, ISO8601::InternalDuration duration, Int128 nudgedEpochNs,
    ISO8601::PlainDate isoDate, ISO8601::PlainTime isoTime,
    TemporalUnit largestUnit, TemporalUnit smallestUnit,
    const TimeZone* timeZone, CalendarID calendarId)
{
    return temporalResult<ISO8601::InternalDuration>(JSCSwift::temporalBubbleRelativeDuration, sign, duration, nudgedEpochNs, isoDate, isoTime, largestUnit, smallestUnit, temporalOptional(timeZone), calendarId);
}

TemporalResult<void> roundRelativeDuration(ISO8601::InternalDuration& duration,
    Int128 originEpochNs, Int128 destEpochNs, ISO8601::PlainDate isoDate, ISO8601::PlainTime isoTime,
    TemporalUnit largestUnit, double increment, TemporalUnit smallestUnit, RoundingMode roundingMode,
    const TimeZone* timeZone, CalendarID calendarId)
{
    return temporalVoidResult(JSCSwift::temporalRoundRelativeDuration, duration, originEpochNs, destEpochNs, isoDate, isoTime, largestUnit, increment, smallestUnit, roundingMode, temporalOptional(timeZone), calendarId);
}

} // namespace TemporalCore
} // namespace JSC
