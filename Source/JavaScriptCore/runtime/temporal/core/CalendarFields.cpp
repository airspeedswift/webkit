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
#include "CalendarFields.h"

#include "TemporalSwiftBoundary.h"
#include <string_view>

#include "JSCSwift-Swift.h"

namespace JSC {
namespace TemporalCore {

TemporalResult<void> nonISOResolveFields(CalendarID calendarId, CalendarFieldsIn& fields, ResolveType type)
{
    return temporalCalendarFieldsResult(fields, JSCSwift::temporalNonISOResolveFields(calendarId, fields, type));
}

TemporalResult<ResolvedCalendarDate> dateFromFields(CalendarID calendarId, const CalendarFieldsIn& fields, TemporalOverflow overflow)
{
    return temporalResult<ResolvedCalendarDate>(JSCSwift::temporalDateFromFields, calendarId, fields, overflow);
}

TemporalResult<ResolvedCalendarDate> yearMonthFromFields(CalendarID calendarId, const CalendarFieldsIn& fields, TemporalOverflow overflow)
{
    return temporalResult<ResolvedCalendarDate>(JSCSwift::temporalYearMonthFromFields, calendarId, fields, overflow);
}

TemporalResult<ResolvedCalendarDate> monthDayFromFields(CalendarID calendarId, const CalendarFieldsIn& fields, TemporalOverflow overflow)
{
    static_assert(std::string_view(icuReadCalendarFailed.characters(), icuReadCalendarFailed.length()) == "Failed to read calendar fields from ICU", "TemporalCoreTypes.h's message, which CalendarFields.swift repeats");
    return temporalResult<ResolvedCalendarDate>(JSCSwift::temporalMonthDayFromFields, calendarId, fields, overflow);
}

TemporalResult<CalendarFieldsIn> isoDateToFields(CalendarID calendarId, const ISO8601::PlainDate& isoDate, ResolveType type)
{
    return temporalCalendarFieldsResult(JSCSwift::temporalIsoDateToFields(calendarId, isoDate, type));
}

CalendarFieldsIn calendarMergeFields(CalendarID calendarId, const CalendarFieldsIn& fields, const CalendarFieldsIn& additionalFields)
{
    return JSCSwift::temporalCalendarMergeFields(calendarId, fields, additionalFields);
}

TemporalResult<ResolvedCalendarDate> plainYearMonthWith(CalendarID calendarId, const ISO8601::PlainDate& currentISODate, const CalendarFieldsIn& partialFields, TemporalOverflow overflow)
{
    return temporalResult<ResolvedCalendarDate>(JSCSwift::temporalPlainYearMonthWith, calendarId, currentISODate, partialFields, overflow);
}

TemporalResult<ResolvedCalendarDate> plainDateWith(CalendarID calendarId, const ISO8601::PlainDate& currentISODate, const CalendarFieldsIn& partialFields, TemporalOverflow overflow)
{
    return temporalResult<ResolvedCalendarDate>(JSCSwift::temporalPlainDateWith, calendarId, currentISODate, partialFields, overflow);
}

TemporalResult<ResolvedCalendarDate> plainMonthDayWith(CalendarID calendarId, const ISO8601::PlainDate& currentISODate, const CalendarFieldsIn& partialFields, TemporalOverflow overflow)
{
    return temporalResult<ResolvedCalendarDate>(JSCSwift::temporalPlainMonthDayWith, calendarId, currentISODate, partialFields, overflow);
}

TemporalResult<ISO8601::Duration> differenceYearMonth(CalendarID calendarId, const ISO8601::PlainDate& thisISODate, const ISO8601::PlainDate& otherISODate, TemporalUnit largestUnit)
{
    return temporalResult<ISO8601::Duration>(JSCSwift::temporalDifferenceYearMonth, calendarId, thisISODate, otherISODate, largestUnit);
}

TemporalResult<ResolvedCalendarDate> plainYearMonthAdd(CalendarID calendarId, const ISO8601::PlainDate& currentISODate, const ISO8601::Duration& duration, TemporalOverflow overflow)
{
    return temporalResult<ResolvedCalendarDate>(JSCSwift::temporalPlainYearMonthAdd, calendarId, currentISODate, duration, overflow);
}

TemporalResult<ResolvedCalendarDate> plainYearMonthToPlainDate(CalendarID calendarId, const ISO8601::PlainDate& pymISODate, uint8_t day)
{
    return temporalResult<ResolvedCalendarDate>(JSCSwift::temporalPlainYearMonthToPlainDate, calendarId, pymISODate, day);
}

TemporalResult<ResolvedCalendarDate> plainYearMonthFromISODate(CalendarID calendarId, const ISO8601::PlainDate& fullISODate)
{
    return temporalResult<ResolvedCalendarDate>(JSCSwift::temporalPlainYearMonthFromISODate, calendarId, fullISODate);
}

TemporalResult<ResolvedCalendarDate> plainMonthDayFromISODate(CalendarID calendarId, const ISO8601::PlainDate& fullISODate, TemporalOverflow overflow)
{
    return temporalResult<ResolvedCalendarDate>(JSCSwift::temporalPlainMonthDayFromISODate, calendarId, fullISODate, overflow);
}

} // namespace TemporalCore
} // namespace JSC
