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
#include "PlainDateTimeCore.h"

#include "TemporalSwiftBoundary.h"

#include "JSCSwift-Swift.h"

namespace JSC {
namespace TemporalCore {

TemporalResult<ISO8601::InternalDuration> differencePlainDateTimeWithRounding(
    ISO8601::PlainDate thisDate, ISO8601::PlainTime thisTime,
    ISO8601::PlainDate otherDate, ISO8601::PlainTime otherTime,
    CalendarID calendarId,
    TemporalUnit largestUnit, TemporalUnit smallestUnit,
    RoundingMode roundingMode, double increment)
{
    return temporalResult<ISO8601::InternalDuration>(JSCSwift::temporalDifferencePlainDateTimeWithRounding, thisDate, thisTime, otherDate, otherTime, calendarId, largestUnit, smallestUnit, roundingMode, increment);
}

TemporalResult<ISO8601::Duration> differenceTemporalPlainDateTime(
    DifferenceOperation op,
    ISO8601::PlainDate thisDate, ISO8601::PlainTime thisTime,
    ISO8601::PlainDate otherDate, ISO8601::PlainTime otherTime,
    CalendarID calendarId,
    TemporalUnit smallestUnit, TemporalUnit largestUnit,
    RoundingMode roundingMode, double increment)
{
    return temporalResult<ISO8601::Duration>(JSCSwift::temporalDifferenceTemporalPlainDateTime, op, thisDate, thisTime, otherDate, otherTime, calendarId, smallestUnit, largestUnit, roundingMode, increment);
}

} // namespace TemporalCore
} // namespace JSC
