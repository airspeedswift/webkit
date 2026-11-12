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

// The C++ that the Temporal Swift in libJavaScriptCore imports (JSCSwiftBoundary.modulemap), and the helpers with
// which the C++ calls it.

#pragma once

#include "CalendarArithmetic.h"
#include "CalendarFields.h"
#include "CalendarICUBridge.h"
#include "DateConstructor.h" // makeDay, makeDate and makeTime, which the Swift calls.
#include "DurationArithmetic.h"
#include "FractionToDouble.h"
#include "ISO8601.h"
#include "ISOArithmetic.h"
#include "InstantCore.h"
#include "IntlObject.h"
#include "JSCTimeZone.h"
#include "PlainDateTimeCore.h"
#include "Rounding.h"
#include "TemporalCoreTypes.h"
#include "TemporalEnums.h"
#include "TimeZoneICUBridge.h"
#include "ZonedDateTimeCore.h"
#include <optional>
#include <span>
#include <type_traits>
#include <utility>
#include <wtf/DateMath.h>
#include <wtf/Vector.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

namespace JSC {

// Names for instantiations that Swift cannot spell.
// FIXME: The Swift functions that take these spans should receive the characters as a `Span` once Swift can take a
// `std::span` safely (rdar://186723514).
using TemporalLatin1Span = std::span<const Latin1Character>;
using TemporalUTF16Span = std::span<const char16_t>;
using TemporalLatin1Vector = Vector<Latin1Character>;

// Optional types that cross the boundary by value.
using TemporalOptionalDouble = std::optional<double>;
using TemporalOptionalInt64 = std::optional<int64_t>;
using TemporalOptionalExactTime = std::optional<ISO8601::ExactTime>;
using TemporalOptionalTimeZone = std::optional<TimeZone>;
using TemporalOptionalTimeZoneIdentifierParseRecord = std::optional<ISO8601::TimeZoneIdentifierParseRecord>;
using TemporalOptionalUnsigned = std::optional<unsigned>;

// The result of TemporalCore::splitTimeDuration, which Swift implements.
using TemporalTimeDurationSplit = std::pair<int64_t, Int128>;

// Moves `value` into `destination`, leaving it empty: a calendar or time zone name can be as long as the string parsed.
template<typename Destination, typename Value>
inline void temporalMove(Destination& destination, Value& value)
{
    destination = WTF::move(value);
}

// Calls a Swift function that writes its value through its last parameter, which starts as T { }.
template<typename T, typename Function, typename... Arguments>
T temporalOutput(Function function, Arguments&&... arguments)
{
    T value { };
    function(std::forward<Arguments>(arguments)..., value);
    return value;
}

// Calls a Swift function that returns whether it has a value and writes the value through its last parameter.
template<typename T, typename Function, typename... Arguments>
std::optional<T> temporalOptionalOutput(Function function, Arguments&&... arguments)
{
    T value { };
    if (!function(std::forward<Arguments>(arguments)..., value))
        return std::nullopt;
    return value;
}

// Calls the function for the string's width, with the string's characters first.
template<typename Function8, typename Function16, typename... Arguments>
auto temporalParse(StringView string, Function8 function8, Function16 function16, Arguments&&... arguments)
{
    if (string.is8Bit())
        return function8(string.span8(), std::forward<Arguments>(arguments)...);
    return function16(string.span16(), std::forward<Arguments>(arguments)...);
}

// Calls the function for the string's width, which returns whether it has a value and writes the value last.
template<typename T, typename Function8, typename Function16, typename... Arguments>
std::optional<T> temporalOptionalParse(StringView string, Function8 function8, Function16 function16, Arguments&&... arguments)
{
    return temporalOptionalOutput<T>([&](auto&&... rest) { return temporalParse(string, function8, function16, rest...); }, std::forward<Arguments>(arguments)...);
}

// Calls a Swift function that writes a value and then an error kind through its last two parameters, and returns the
// error's message, which is null when the function succeeds.
template<typename T, typename Function, typename... Arguments>
TemporalResult<T> temporalResult(Function function, Arguments&&... arguments)
{
    T value { };
    auto kind = TemporalErrorKind::RangeError;
    String message = function(std::forward<Arguments>(arguments)..., value, kind);
    if (!message.isNull()) [[unlikely]]
        return makeUnexpected(TemporalError { kind, WTF::move(message) });
    return value;
}

template<typename Function, typename... Arguments>
TemporalResult<void> temporalVoidResult(Function function, Arguments&&... arguments)
{
    auto kind = TemporalErrorKind::RangeError;
    String message = function(std::forward<Arguments>(arguments)..., kind);
    if (!message.isNull()) [[unlikely]]
        return makeUnexpected(TemporalError { kind, WTF::move(message) });
    return { };
}

// The value of a successful result, for Swift, which can read std::expected's value only without a check. Swift
// infers T from the call's context, so it must be the result's own value type.
template<typename Result, typename T = typename Result::value_type>
T temporalValueOf(const Result& result)
{
    static_assert(std::is_same_v<T, typename Result::value_type>);
    RELEASE_ASSERT(result.has_value());
    return *result;
}

// The error of a failed result, for Swift, which cannot call std::expected::error(). Swift infers E from the call's
// context, so it must be the result's own error type.
template<typename Result, typename E = typename Result::error_type>
E temporalErrorOf(const Result& result)
{
    static_assert(std::is_same_v<E, typename Result::error_type>);
    return result.error();
}

// A nullable `const T*` argument as a `std::optional<T>` for Swift, which can read a C++ pointer only unsafely.
template<typename T>
std::optional<T> temporalOptional(const T* pointer)
{
    if (!pointer)
        return std::nullopt;
    return *pointer;
}

// WTF::yearMonthDayFromDays's result, which Swift cannot read as a std::tuple.
struct TemporalYearMonthDay {
    int32_t year;
    int32_t month;
    int32_t day;
};

// What ISO8601::parseISODateTime read from a string it accepts, from which the record is then built. A time zone name
// and a calendar are the positions of their characters in the string; a field whose flag is false is absent.
struct TemporalISODateTimeTokens {
    ISO8601::PlainTime time;
    int64_t utcOffset { 0 };
    int64_t timeZoneOffset { 0 };
    size_t timeZoneNameStart { 0 }, timeZoneNameEnd { 0 };
    size_t calendarStart { 0 }, calendarEnd { 0 };
    int32_t year { 0 };
    uint32_t month { 0 }, day { 0 };
    ISO8601::TemporalProduction matched { };
    bool hasYear { false }, hasMonth { false }, hasDay { false }, hasTime { false }, hasUTCDesignator { false }, hasUTCOffset { false };
    bool offsetHasSubMinutePrecision { false }, hasTimeZoneName { false }, hasTimeZoneOffset { false }, hasCalendar { false }, isShortForm { false };
};

inline TemporalYearMonthDay temporalYearMonthDayFromDays(int32_t days)
{
    auto [year, month, day] = WTF::yearMonthDayFromDays(days);
    return { year, month, day };
}

// The builder's string by value: StringBuilder::toString() returns a const String&, which imports as UnsafePointer.
inline String temporalStringOf(StringBuilder& builder)
{
    return builder.toString();
}

namespace TemporalCore {

// Bridge functions that take a StringView, which Swift can only build unsafely. The era is returned as a String:
// an ASCIILiteral holds a pointer, which Swift reads only unsafely.
inline std::optional<String> temporalCanonicalizeEraInCalendar(CalendarID calendarId, const String& era)
{
    if (auto canonical = canonicalizeEraInCalendar(calendarId, StringView(era)))
        return String(*canonical);
    return std::nullopt;
}

inline std::optional<std::pair<String, int32_t>> temporalRemapNonPositiveEraYear(CalendarID calendarId, const String& era, int32_t eraYear)
{
    if (auto remapped = remapNonPositiveEraYear(calendarId, StringView(era), eraYear))
        return std::pair<String, int32_t> { String(remapped->first), remapped->second };
    return std::nullopt;
}

inline std::optional<int32_t> temporalCalendarDateArithmeticYearForEraYear(CalendarID calendarId, const String& era, int32_t eraYear)
{
    return calendarDateArithmeticYearForEraYear(calendarId, StringView(era), eraYear);
}

inline String temporalCalendarIDString(CalendarID calendarId)
{
    return intlAvailableCalendars()[calendarId];
}

// Calendar fields and an error, which a Swift function returns together. The error's message is null on success.
struct TemporalCalendarFieldsOutcome {
    CalendarFieldsIn fields;
    TemporalError error { TemporalErrorKind::RangeError, { } };
};

inline TemporalResult<CalendarFieldsIn> temporalCalendarFieldsResult(TemporalCalendarFieldsOutcome&& outcome)
{
    if (!outcome.error.message.isNull()) [[unlikely]]
        return makeUnexpected(WTF::move(outcome.error));
    return WTF::move(outcome.fields);
}

// Stores the fields in `fields` whether or not resolution failed, as nonISOResolveFields leaves them.
inline TemporalResult<void> temporalCalendarFieldsResult(CalendarFieldsIn& fields, TemporalCalendarFieldsOutcome&& outcome)
{
    fields = WTF::move(outcome.fields);
    if (!outcome.error.message.isNull()) [[unlikely]]
        return makeUnexpected(WTF::move(outcome.error));
    return { };
}

} // namespace TemporalCore

} // namespace JSC
