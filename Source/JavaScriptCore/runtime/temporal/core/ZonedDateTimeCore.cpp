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
#include "ZonedDateTimeCore.h"

#include "TemporalSwiftBoundary.h"

#include "JSCSwift-Swift.h"

namespace JSC {
namespace TemporalCore {

TemporalResult<ISO8601::ExactTime> interpretISODateTimeOffset(
    const ISO8601::PlainDate& date,
    const ISO8601::PlainTime& time,
    UseStartOfDay useStartOfDay,
    OffsetBehaviour offsetBehaviour,
    TemporalOffsetDisambiguation offsetOpt,
    int64_t inlineOffsetNs,
    MatchBehaviour matchBehaviour,
    const TimeZone& timeZone,
    TemporalDisambiguation disambiguation)
{
    return temporalResult<ISO8601::ExactTime>(JSCSwift::temporalInterpretISODateTimeOffset, date, time, useStartOfDay, offsetBehaviour, offsetOpt, inlineOffsetNs, matchBehaviour, timeZone, disambiguation);
}

TemporalResult<ISO8601::ExactTime> getStartOfDay(const TimeZone& tz, ISO8601::PlainDate date)
{
    return temporalResult<ISO8601::ExactTime>(JSCSwift::temporalGetStartOfDay, tz, date);
}

TemporalResult<ISO8601::InternalDuration> differenceZonedDateTimeWithRounding(
    ISO8601::ExactTime ns1,
    ISO8601::ExactTime ns2,
    const TimeZone& timeZone,
    TemporalUnit largestUnit,
    TemporalUnit smallestUnit,
    RoundingMode roundingMode,
    double increment,
    CalendarID calendarId)
{
    return temporalResult<ISO8601::InternalDuration>(JSCSwift::temporalDifferenceZonedDateTimeWithRounding, ns1, ns2, timeZone, largestUnit, smallestUnit, roundingMode, increment, calendarId);
}

} // namespace TemporalCore
} // namespace JSC
