/*
 * Copyright (C) 2021 Sony Interactive Entertainment Inc.
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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
#include "ISO8601.h"

#include "Error.h"
#include "FractionToDouble.h"
#include "IntlObject.h"
#include "JSGlobalObject.h"
#include "ParseInt.h"
#include "Rounding.h"
#include "TemporalObject.h"
#include "TemporalSwiftBoundary.h"
#include <wtf/DateMath.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/WallTime.h>

#include "JSCSwift-Swift.h"

namespace JSC {
namespace ISO8601 {

WTF_MAKE_TZONE_ALLOCATED_IMPL(Duration);
WTF_MAKE_TZONE_ALLOCATED_IMPL(ExactTime);
WTF_MAKE_TZONE_ALLOCATED_IMPL(PlainTime);
WTF_MAKE_TZONE_ALLOCATED_IMPL(PlainDate);
WTF_MAKE_TZONE_ALLOCATED_IMPL(PlainDateTime);
WTF_MAKE_TZONE_ALLOCATED_IMPL(PlainYearMonth);
WTF_MAKE_TZONE_ALLOCATED_IMPL(PlainMonthDay);

// Constants that TemporalSupport.swift and ISO8601Parser.swift repeat.
static_assert(ExactTime::dayRangeSeconds == 8'640'000'000'000, "TemporalSupport.swift repeats ExactTime::dayRangeSeconds");
static_assert(ExactTime::nsPerMicrosecond == 1'000, "TemporalSupport.swift repeats ExactTime::nsPerMicrosecond");
static_assert(ExactTime::nsPerMillisecond == 1'000'000, "TemporalSupport.swift repeats ExactTime::nsPerMillisecond");
static_assert(ExactTime::nsPerSecond == 1'000'000'000, "TemporalSupport.swift repeats ExactTime::nsPerSecond");
static_assert(InternalDuration::maxTimeDuration == (Int128 { 1 } << 53) * 1'000'000'000 - 1, "TemporalSupport.swift repeats InternalDuration::maxTimeDuration");
static_assert(numberOfDigitsForSafeInt32 == 9, "ISO8601Parser.swift repeats ParseInt.h's numberOfDigitsForSafeInt32");
static_assert(mantissaOverflowLowerBound == 9007199254740992.0, "ISO8601Parser.swift repeats ParseInt.h's mantissaOverflowLowerBound");

std::optional<TimeZoneID> parseTimeZoneName(StringView string)
{
    return intlResolveTimeZoneID(string);
}

std::optional<Duration> parseDuration(StringView string)
{
    return temporalOptionalParse<Duration>(string, JSCSwift::temporalParseDuration8, JSCSwift::temporalParseDuration16);
}

std::optional<int64_t> parseUTCOffset(StringView string, SubMinutePrecision subMinutePrecision)
{
    return temporalOptionalParse<int64_t>(string, JSCSwift::temporalParseUTCOffset8, JSCSwift::temporalParseUTCOffset16, subMinutePrecision);
}

std::optional<int64_t> parseUTCOffsetInMinutes(StringView string)
{
    return temporalOptionalParse<int64_t>(string, JSCSwift::temporalParseUTCOffsetInMinutes8, JSCSwift::temporalParseUTCOffsetInMinutes16);
}

std::optional<TimeZoneIdentifierParseRecord> parseTimeZoneIdentifier(StringView identifier)
{
    return temporalParse(identifier, JSCSwift::temporalParseTimeZoneIdentifier8, JSCSwift::temporalParseTimeZoneIdentifier16);
}

std::optional<ParsedISODateTime> parseISODateTime(StringView string, TemporalProductionSet allowed)
{
    TemporalISODateTimeTokens tokens { };
    if (!temporalParse(string, JSCSwift::temporalParseISODateTimeTokens8, JSCSwift::temporalParseISODateTimeTokens16, allowed.toRaw(), tokens))
        return std::nullopt;
    // The optional's value is initialized from the conversion's result, so the record is written in place.
    struct Build {
        StringView string;
        const TemporalISODateTimeTokens& tokens;
        operator ParsedISODateTime() const { return temporalParse(string, JSCSwift::temporalParsedISODateTime8, JSCSwift::temporalParsedISODateTime16, tokens); }
    };
    return std::optional<ParsedISODateTime> { std::in_place, Build { string, tokens } };
}

String temporalTimeToString(PlainTime plainTime, std::tuple<Precision, unsigned> precision)
{
    return JSCSwift::temporalTemporalTimeToString(plainTime, std::get<0>(precision), std::get<1>(precision));
}

String temporalDateTimeToString(PlainDate plainDate, PlainTime plainTime, std::tuple<Precision, unsigned> precision)
{
    return JSCSwift::temporalTemporalDateTimeToString(plainDate, plainTime, std::get<0>(precision), std::get<1>(precision));
}

String temporalYearMonthToString(PlainYearMonth plainYearMonth, StringView calendarName, unsigned calendarId)
{
    return temporalParse(calendarName, JSCSwift::temporalTemporalYearMonthToString8, JSCSwift::temporalTemporalYearMonthToString16, plainYearMonth.isoPlainDate(), calendarId);
}

String temporalMonthDayToString(PlainMonthDay plainMonthDay, StringView calendarName, unsigned calendarId)
{
    return temporalParse(calendarName, JSCSwift::temporalTemporalMonthDayToString8, JSCSwift::temporalTemporalMonthDayToString16, plainMonthDay.isoPlainDate(), calendarId);
}

std::optional<ParsedMonthCode> parseMonthCode(StringView monthCode)
{
    return temporalOptionalParse<ParsedMonthCode>(monthCode, JSCSwift::temporalParseMonthCode8, JSCSwift::temporalParseMonthCode16);
}

void Duration::setField(TemporalUnit u, double v)
{
    JSCSwift::temporalDurationSetField(u, v, *this);
}

template<TemporalUnit unit>
std::optional<Int128> Duration::totalNanoseconds() const
{
    return temporalOptionalOutput<Int128>(JSCSwift::temporalDurationTotalNanoseconds, *this, unit);
}
template std::optional<Int128> Duration::totalNanoseconds<TemporalUnit::Day>() const;
template std::optional<Int128> Duration::totalNanoseconds<TemporalUnit::Second>() const;
template std::optional<Int128> Duration::totalNanoseconds<TemporalUnit::Millisecond>() const;
template std::optional<Int128> Duration::totalNanoseconds<TemporalUnit::Microsecond>() const;

bool isValidDuration(const Duration& duration)
{
    return JSCSwift::temporalIsValidDuration(duration);
}

std::optional<ExactTime> ExactTime::add(Duration duration) const
{
    return temporalOptionalOutput<ExactTime>(JSCSwift::temporalExactTimeAdd, *this, duration);
}

int32_t ISO8601::InternalDuration::sign() const
{
    return JSCSwift::temporalInternalDurationSign(*this);
}

// https://tc39.es/proposal-temporal/#sec-temporal-roundtemporalinstant
static Int128 roundTemporalInstant(Int128 ns, unsigned increment, TemporalUnit unit, RoundingMode roundingMode)
{
    auto unitLength = lengthInNanoseconds(unit);
    auto incrementNs = increment * unitLength;
    return TemporalCore::roundNumberToIncrementAsIfPositive(ns, incrementNs, roundingMode);
}

// https://tc39.es/proposal-temporal/#sec-temporal.instant.prototype.round
// (Steps 10-17 only)
ExactTime ExactTime::round(JSGlobalObject* globalObject, unsigned increment,
    TemporalUnit unit, RoundingMode roundingMode) const
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    Int128 maximum = 0;
    switch (unit) {
    case TemporalUnit::Hour: maximum = static_cast<Int128>(WTF::hoursPerDay); break;
    case TemporalUnit::Minute: maximum = static_cast<Int128>(minutesPerHour * WTF::hoursPerDay); break;
    case TemporalUnit::Second: maximum = static_cast<Int128>(secondsPerMinute * minutesPerHour * WTF::hoursPerDay); break;
    case TemporalUnit::Millisecond: maximum = static_cast<Int128>(msPerDay); break;
    case TemporalUnit::Microsecond: maximum = static_cast<Int128>(msPerDay * 1000); break;
    case TemporalUnit::Nanosecond: maximum = nsPerDay; break;
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }
    validateTemporalRoundingIncrement(globalObject, static_cast<double>(increment), static_cast<double>(maximum), Inclusivity::Inclusive);
    RETURN_IF_EXCEPTION(scope, { });
    auto roundedNs = roundTemporalInstant(m_epochNanoseconds, increment, unit, roundingMode);
    return ExactTime { roundedNs };
}

// https://tc39.es/proposal-temporal/#sec-temporal-roundtimedurationtoincrement
static Int128 roundTimeDurationToIncrement(JSGlobalObject* globalObject, Int128 d, Int128 increment,
    RoundingMode roundingMode)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    Int128 rounded = TemporalCore::roundNumberToIncrementInt128(d, increment, roundingMode);
    if (absInt128(rounded) > InternalDuration::maxTimeDuration) [[unlikely]] {
        throwRangeError(globalObject, scope, "Rounded time duration exceeds maximum"_s);
        return 0;
    }
    return rounded;
}

// https://tc39.es/proposal-temporal/#sec-temporal-roundtimeduration
Int128 roundTimeDuration(JSGlobalObject* globalObject, Int128 timeDuration, unsigned increment, TemporalUnit unit, RoundingMode roundingMode)
{
    auto divisor = lengthInNanoseconds(unit);

    return roundTimeDurationToIncrement(globalObject, timeDuration,
        (divisor * increment), roundingMode);
}

// DifferenceInstant ( ns1, ns2, roundingIncrement, smallestUnit, roundingMode )
// https://tc39.es/proposal-temporal/#sec-temporal-differenceinstant
InternalDuration ExactTime::difference(JSGlobalObject* globalObject, ExactTime other, unsigned roundingIncrement, TemporalUnit smallestUnit, RoundingMode roundingMode) const
{
    Int128 timeDuration = other.m_epochNanoseconds - m_epochNanoseconds;
    timeDuration = roundTimeDuration(globalObject, timeDuration, roundingIncrement, smallestUnit, roundingMode);
    return InternalDuration::combineDateAndTimeDuration(ISO8601::Duration(), timeDuration);
}

ExactTime ExactTime::now()
{
    return ExactTime { WTF::currentTimeInNanoseconds() };
}

std::optional<TimeZoneIdentifierParseRecord> parseTemporalTimeZoneString(StringView string)
{
    return temporalParse(string, JSCSwift::temporalParseTemporalTimeZoneString8, JSCSwift::temporalParseTemporalTimeZoneString16);
}

} // namespace ISO8601
} // namespace JSC
