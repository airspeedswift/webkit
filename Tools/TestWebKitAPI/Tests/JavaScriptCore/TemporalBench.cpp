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

#include <JavaScriptCore/CalendarArithmetic.h>
#include <JavaScriptCore/CalendarICUBridge.h>
#include <JavaScriptCore/DurationArithmetic.h>
#include <JavaScriptCore/ISO8601.h>
#include <JavaScriptCore/ISOArithmetic.h>
#include <JavaScriptCore/InitializeThreading.h>
#include <JavaScriptCore/InstantCore.h>
#include <JavaScriptCore/JSCTimeZone.h>
#include <JavaScriptCore/PlainDateTimeCore.h>
#include <JavaScriptCore/Rounding.h>
#include <JavaScriptCore/TemporalCoreTypes.h>
#include <JavaScriptCore/TemporalEnums.h>
#include <JavaScriptCore/TimeZoneICUBridge.h>
#include <JavaScriptCore/ZonedDateTimeCore.h>
#include <bit>
#include <cstdio>
#include <cstdlib>
#include <wtf/Int128.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Vector.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

// Each test runs its inputs once through Temporal's parsers, formatters and ISO arithmetic and checks a checksum of
// every result, error included. With WEBKIT_RUN_BENCHMARKS set, it then runs them a fixed number of times and prints
// the time taken.

namespace TestWebKitAPI {

namespace TemporalBenchmark {

namespace ISO = JSC::ISO8601;
namespace Core = JSC::TemporalCore;

class Random {
public:
    explicit Random(uint64_t seed)
        : m_state(seed)
    {
    }

    unsigned below(unsigned bound)
    {
        m_state = m_state * 6364136223846793005ULL + 1442695040888963407ULL;
        return static_cast<unsigned>(m_state >> 33) % bound;
    }

    int range(int low, int high) { return low + static_cast<int>(below(static_cast<unsigned>(high - low + 1))); }

    bool percent(unsigned chance) { return below(100) < chance; }

    // Epoch nanoseconds within about 63 years of 1970.
    WTF::Int128 epochNanoseconds()
    {
        WTF::Int128 seconds = range(-2'000'000, 2'000'000) * WTF::Int128(1000);
        return seconds * 1'000'000'000LL + range(0, 999'999'999);
    }

    template<typename T, size_t size>
    const T& pick(const T (&values)[size]) { return values[below(size)]; }

private:
    uint64_t m_state;
};

class Digest {
public:
    void addInteger(uint64_t value)
    {
        m_state = (m_state ^ value) * 0x100000001b3ULL;
        m_state ^= m_state >> 29;
    }

    void add(WTF::Int128 value)
    {
        auto bits = static_cast<WTF::UInt128>(value);
        addInteger(static_cast<uint64_t>(bits));
        addInteger(static_cast<uint64_t>(bits >> 64));
    }

    void add(double value) { addInteger(std::bit_cast<uint64_t>(value)); }

    void add(WTF::StringView string)
    {
        if (string.isNull()) {
            addInteger(0xfeed);
            return;
        }
        addInteger(static_cast<uint64_t>(string.length()));
        for (unsigned i = 0; i < string.length(); ++i)
            addInteger(static_cast<uint64_t>(string[i]));
    }

    void add(const WTF::String& string) { add(WTF::StringView(string)); }

    void missing() { addInteger(0xdead); }

    void add(const JSC::TemporalError& error)
    {
        addInteger(0xe7707 + static_cast<uint64_t>(error.kind));
        add(error.message);
    }

    // Mixes the error and returns false when the result is one.
    template<typename T>
    bool add(const JSC::TemporalResult<T>& result)
    {
        if (result)
            return true;
        add(result.error());
        return false;
    }

    void add(const ISO::PlainDate& date)
    {
        addInteger(static_cast<uint64_t>(static_cast<int64_t>(date.year())));
        addInteger(static_cast<uint64_t>(date.month()) << 8 | date.day());
    }

    void add(const ISO::PlainTime& time)
    {
        addInteger(static_cast<uint64_t>(time.hour()) << 16 | static_cast<uint64_t>(time.minute()) << 8 | time.second());
        addInteger(static_cast<uint64_t>(time.millisecond()) << 20 | static_cast<uint64_t>(time.microsecond()) << 10 | time.nanosecond());
    }

    void add(const ISO::Duration& duration)
    {
        addInteger(static_cast<uint64_t>(duration.years()));
        addInteger(static_cast<uint64_t>(duration.months()));
        addInteger(static_cast<uint64_t>(duration.weeks()));
        addInteger(static_cast<uint64_t>(duration.days()));
        addInteger(static_cast<uint64_t>(duration.hours()));
        addInteger(static_cast<uint64_t>(duration.minutes()));
        addInteger(static_cast<uint64_t>(duration.seconds()));
        addInteger(static_cast<uint64_t>(duration.milliseconds()));
        add(duration.microseconds());
        add(duration.nanoseconds());
    }

    void add(const ISO::InternalDuration& duration)
    {
        add(duration.dateDuration());
        add(duration.time());
    }

    void add(const ISO::ExactTime& exactTime) { add(exactTime.epochNanoseconds()); }

    void add(std::span<const Latin1Character> characters)
    {
        addInteger(static_cast<uint64_t>(characters.size()));
        for (auto character : characters)
            addInteger(static_cast<uint64_t>(character));
    }

    uint64_t value() const { return m_state; }

private:
    uint64_t m_state { 0xcbf29ce484222325ULL };
};

static constexpr unsigned inputCount = 4096;

static WTF::String make16Bit(const WTF::String& string)
{
    WTF::Vector<char16_t> characters;
    characters.reserveInitialCapacity(string.length());
    for (unsigned i = 0; i < string.length(); ++i)
        characters.append(string[i]);
    return WTF::String(characters.span());
}

// Replaces the first occurrence of `from` with a character outside Latin-1, so the string is 16-bit and fails to parse.
static WTF::String withWideCharacter(const WTF::String& string, char16_t from, char16_t to)
{
    WTF::Vector<char16_t> characters;
    characters.reserveInitialCapacity(string.length());
    bool replaced = false;
    for (unsigned i = 0; i < string.length(); ++i) {
        char16_t character = string[i];
        if (!replaced && character == from) {
            character = to;
            replaced = true;
        }
        characters.append(character);
    }
    if (!replaced)
        characters.append(to);
    return WTF::String(characters.span());
}

struct TextInput {
    WTF::String text;
    uint8_t kind { 0 };
};

// Every fourth string is a 16-bit copy, so each test parses both widths; strings already 16-bit stay so.
static WTF::Vector<TextInput> finishText(WTF::Vector<TextInput>&& inputs)
{
    for (size_t i = 0; i < inputs.size(); ++i) {
        if (i % 4 == 3 && inputs[i].text.is8Bit())
            inputs[i].text = make16Bit(inputs[i].text);
    }
    return WTF::move(inputs);
}

// One input in eight that parses becomes an error input: truncated, extended with garbage, given a Latin-1 or a
// wide character, or emptied.
static WTF::String damage(Random& random, const WTF::String& string)
{
    switch (random.below(7)) {
    case 0:
        return string.left(random.below(std::max(1u, string.length())));
    case 1:
        return WTF::makeString(string, "x"_s);
    case 2: {
        WTF::StringBuilder builder;
        builder.append(string.left(string.length() / 2));
        builder.append(static_cast<char16_t>(0xE9)); // LATIN SMALL LETTER E WITH ACUTE
        builder.append(string.substring(string.length() / 2));
        return builder.toString();
    }
    case 3:
        return withWideCharacter(string, '-', 0x2212); // MINUS SIGN
    case 4:
        return withWideCharacter(string, ':', 0xFF1A); // FULLWIDTH COLON
    case 5:
        return WTF::makeString(" "_s, string);
    default:
        return random.percent(50) ? WTF::emptyString() : "Z"_s;
    }
}

static void appendPadded(WTF::StringBuilder& builder, unsigned value, unsigned width)
{
    unsigned digits = 1;
    for (unsigned rest = value / 10; rest; rest /= 10)
        ++digits;
    for (; digits < width; ++digits)
        builder.append('0');
    builder.append(value);
}

static void appendDigits(WTF::StringBuilder& builder, Random& random, unsigned count)
{
    for (unsigned i = 0; i < count; ++i)
        builder.append(static_cast<char>('0' + random.below(10)));
}

static unsigned daysIn(int year, unsigned month)
{
    static constexpr unsigned days[] = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    bool leap = (!(year % 4) && (year % 100)) || !(year % 400);
    return month == 2 && leap ? 29 : days[month - 1];
}

// DateYear: mostly four digits near the present, sometimes any four digits or a sign and six digits, rarely the
// rejected -000000 or a year past the limits.
static int appendYear(WTF::StringBuilder& builder, Random& random)
{
    unsigned kind = random.below(100);
    if (kind < 75) {
        int year = random.range(1900, 2100);
        appendPadded(builder, year, 4);
        return year;
    }
    if (kind < 87) {
        int year = random.range(0, 9999);
        appendPadded(builder, year, 4);
        return year;
    }
    if (kind < 98) {
        int year = random.range(-271821, 275760);
        builder.append(year < 0 ? '-' : '+');
        appendPadded(builder, std::abs(year), 6);
        return year;
    }
    if (random.percent(50)) {
        builder.append("-000000"_s);
        return 0;
    }
    builder.append('+');
    appendPadded(builder, random.range(275761, 999999), 6);
    return 2000;
}

// A date in extended (YYYY-MM-DD) or basic (YYYYMMDD) form, with an invalid month or day one time in twenty.
static void appendDate(WTF::StringBuilder& builder, Random& random)
{
    int year = appendYear(builder, random);
    bool extended = random.percent(80);
    unsigned month = random.range(1, 12);
    unsigned day = random.range(1, daysIn(year, month));
    if (random.percent(5)) {
        switch (random.below(4)) {
        case 0: month = 0; break;
        case 1: month = 13; break;
        case 2: day = 0; break;
        default: day = daysIn(year, month) + 1; break;
        }
    }
    if (extended)
        builder.append('-');
    appendPadded(builder, month, 2);
    if (extended)
        builder.append('-');
    appendPadded(builder, day, 2);
}

// TimeSpec in each of its forms: hh, hh:mm, hhmm, hh:mm:ss, hhmmss, a leap second, and a fraction of one to nine
// digits after '.' or ','.
static void appendTime(WTF::StringBuilder& builder, Random& random)
{
    unsigned hour = random.percent(2) ? 24 : random.range(0, 23);
    appendPadded(builder, hour, 2);
    unsigned form = random.below(10);
    if (!form)
        return;
    bool colon = form >= 3;
    if (colon)
        builder.append(':');
    appendPadded(builder, random.range(0, 59), 2);
    if (form == 1 || form == 3)
        return;
    if (colon)
        builder.append(':');
    appendPadded(builder, random.percent(3) ? 60 : random.range(0, 59), 2);
    if (random.percent(55)) {
        builder.append(random.percent(85) ? '.' : ',');
        appendDigits(builder, random, random.range(1, 9));
    }
}

// UTCOffset: ±hh, ±hhmm, ±hh:mm, and with sub-minute precision ±hh:mm:ss and a fraction.
static void appendOffset(WTF::StringBuilder& builder, Random& random, bool subMinute = true)
{
    builder.append(random.percent(50) ? '+' : '-');
    appendPadded(builder, random.range(0, 23), 2);
    unsigned form = random.below(subMinute ? 6 : 4);
    if (!form)
        return;
    bool colon = form != 1;
    if (colon)
        builder.append(':');
    appendPadded(builder, random.pick({ 0u, 0u, 30u, 45u, 15u, 59u }), 2);
    if (form < 4)
        return;
    if (colon)
        builder.append(':');
    appendPadded(builder, random.range(0, 59), 2);
    if (form == 5) {
        builder.append('.');
        appendDigits(builder, random, random.range(1, 9));
    }
}

static constexpr ASCIILiteral timeZoneNames[] = {
    "UTC"_s, "America/New_York"_s, "Europe/London"_s, "Europe/Rome"_s, "Asia/Tokyo"_s, "Asia/Kolkata"_s,
    "Australia/Lord_Howe"_s, "America/Argentina/Buenos_Aires"_s, "Etc/GMT+5"_s, "Etc/GMT-14"_s, "Pacific/Chatham"_s,
    "America/Port-au-Prince"_s, "EST5EDT"_s, "Asia/Ho_Chi_Minh"_s, "europe/paris"_s, "America/Los_Angeles"_s,
    "Pacific/Apia"_s, "Africa/Casablanca"_s, "Mars/Olympus_Mons"_s, "Etc/Unknown"_s,
};

// TimeZoneIdentifier names that do not parse: an empty component, a leading digit or sign, a bad character.
static constexpr ASCIILiteral malformedTimeZoneNames[] = {
    "America//New_York"_s, "/UTC"_s, "UTC/"_s, "1America"_s, "-UTC"_s, "Europe/Lon don"_s, "Asia/Tok*yo"_s,
    "Europe/9Rome"_s,
};

static void appendTimeZoneAnnotation(WTF::StringBuilder& builder, Random& random)
{
    builder.append('[');
    if (random.percent(10))
        builder.append('!');
    if (random.percent(75))
        builder.append(random.pick(timeZoneNames));
    else if (random.percent(90))
        appendOffset(builder, random, false);
    else
        builder.append(random.pick(malformedTimeZoneNames));
    builder.append(']');
}

static constexpr ASCIILiteral calendarAnnotations[] = {
    "[u-ca=iso8601]"_s, "[u-ca=iso8601]"_s, "[!u-ca=iso8601]"_s, "[u-ca=gregory]"_s, "[u-ca=japanese]"_s,
    "[u-ca=islamic-umalqura]"_s, "[u-ca=ISO8601]"_s, "[u-ca=iso8601][u-ca=gregory]"_s, "[foo=bar]"_s,
    "[_x=y-z]"_s, "[foo=bar][u-ca=iso8601]"_s, "[u-ca=hebrew][!u-ca=iso8601]"_s,
    // Errors: a critical unknown key, a critical calendar after another, a component too long or too short, an
    // empty value, a bad character, an unterminated annotation.
    "[!foo=bar]"_s, "[!u-ca=iso8601][u-ca=gregory]"_s, "[u-ca=abcdefghij]"_s, "[u-ca=ab]"_s, "[u-ca=]"_s,
    "[u-ca=iso_8601]"_s, "[u-ca=iso8601"_s,
};

static WTF::String instantString(Random& random)
{
    WTF::StringBuilder builder;
    appendDate(builder, random);
    builder.append(random.pick({ 'T', 'T', 'T', 't', ' ' }));
    appendTime(builder, random);
    unsigned designator = random.below(100);
    if (designator < 45)
        builder.append(random.percent(90) ? 'Z' : 'z');
    else if (designator < 97)
        appendOffset(builder, random);
    if (random.percent(20))
        appendTimeZoneAnnotation(builder, random);
    if (random.percent(15))
        builder.append(random.pick(calendarAnnotations));
    return builder.toString();
}

static WTF::Vector<TextInput> parseInstantsInputs()
{
    Random random(1);
    WTF::Vector<TextInput> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        auto text = instantString(random);
        inputs.append({ random.percent(12) ? damage(random, text) : WTF::move(text) });
    }
    return finishText(WTF::move(inputs));
}

static WTF::String zonedDateTimeString(Random& random)
{
    WTF::StringBuilder builder;
    appendDate(builder, random);
    if (random.percent(92)) {
        builder.append(random.pick({ 'T', 'T', 't', ' ' }));
        appendTime(builder, random);
        unsigned designator = random.below(100);
        if (designator < 30)
            appendOffset(builder, random);
        else if (designator < 40)
            builder.append('Z');
    }
    // The time zone annotation is required; one in fifty strings leaves it out.
    if (!random.percent(2))
        appendTimeZoneAnnotation(builder, random);
    if (random.percent(35))
        builder.append(random.pick(calendarAnnotations));
    return builder.toString();
}

static WTF::Vector<TextInput> parseZonedDateTimesInputs()
{
    Random random(2);
    WTF::Vector<TextInput> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        auto text = zonedDateTimeString(random);
        inputs.append({ random.percent(12) ? damage(random, text) : WTF::move(text) });
    }
    return finishText(WTF::move(inputs));
}

enum class PlainKind : uint8_t { Date, YearMonth, MonthDay, Time };

static WTF::String plainDateString(Random& random, bool timeRequired)
{
    WTF::StringBuilder builder;
    appendDate(builder, random);
    if (timeRequired || random.percent(25)) {
        builder.append(random.pick({ 'T', 'T', 't', ' ' }));
        appendTime(builder, random);
        unsigned designator = random.below(100);
        if (designator < 10)
            appendOffset(builder, random);
        else if (designator < 13)
            builder.append('Z'); // TemporalDateTimeString[~Zoned] rejects Z.
    }
    if (random.percent(8))
        appendTimeZoneAnnotation(builder, random);
    if (random.percent(25))
        builder.append(random.pick(calendarAnnotations));
    return builder.toString();
}

static WTF::String yearMonthString(Random& random)
{
    if (random.percent(30))
        return plainDateString(random, false);
    WTF::StringBuilder builder;
    appendYear(builder, random);
    if (random.percent(75))
        builder.append('-');
    appendPadded(builder, random.percent(4) ? 13 : random.range(1, 12), 2);
    if (random.percent(25)) // A non-ISO calendar on the short form is rejected.
        builder.append(random.pick(calendarAnnotations));
    return builder.toString();
}

static WTF::String monthDayString(Random& random)
{
    if (random.percent(30))
        return plainDateString(random, false);
    WTF::StringBuilder builder;
    if (random.percent(30))
        builder.append("--"_s);
    unsigned month = random.range(1, 12);
    appendPadded(builder, month, 2);
    if (random.percent(70))
        builder.append('-');
    unsigned day = random.range(1, daysIn(2000, month));
    if (random.percent(4))
        day = daysIn(2000, month) + 1;
    appendPadded(builder, day, 2);
    if (random.percent(25))
        builder.append(random.pick(calendarAnnotations));
    return builder.toString();
}

// TemporalTimeString, with and without the T: four-digit times that also read as a month-day or a year-month are
// ambiguous without it and rejected.
static WTF::String timeString(Random& random)
{
    if (random.percent(15))
        return plainDateString(random, true);
    WTF::StringBuilder builder;
    if (random.percent(40))
        builder.append(random.percent(80) ? 'T' : 't');
    if (random.percent(15)) {
        appendPadded(builder, random.range(1, 12), 2);
        appendPadded(builder, random.range(1, 31), 2);
    } else
        appendTime(builder, random);
    unsigned designator = random.below(100);
    if (designator < 15)
        appendOffset(builder, random);
    else if (designator < 18)
        builder.append('Z'); // Rejected: a time has no UTC designator.
    if (random.percent(8))
        appendTimeZoneAnnotation(builder, random);
    if (random.percent(10))
        builder.append(random.pick(calendarAnnotations));
    return builder.toString();
}

// Plain date and date-time strings are most of the inputs; year-month, month-day and time strings, which share
// the same parser through other productions, are the rest.
static WTF::Vector<TextInput> parsePlainDatesInputs()
{
    Random random(3);
    WTF::Vector<TextInput> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        unsigned kind = random.below(100);
        PlainKind plainKind = kind < 55 ? PlainKind::Date : kind < 70 ? PlainKind::YearMonth : kind < 85 ? PlainKind::MonthDay : PlainKind::Time;
        WTF::String text;
        switch (plainKind) {
        case PlainKind::Date:
            text = plainDateString(random, random.percent(30));
            break;
        case PlainKind::YearMonth:
            text = yearMonthString(random);
            break;
        case PlainKind::MonthDay:
            text = monthDayString(random);
            break;
        case PlainKind::Time:
            text = timeString(random);
            break;
        }
        if (random.percent(10))
            text = damage(random, text);
        inputs.append({ WTF::move(text), static_cast<uint8_t>(plainKind) });
    }
    return finishText(WTF::move(inputs));
}

// Durations: a sign, P in either case, date parts in order, then T and time parts, the last of which may have a
// fraction. Large integers reach the duration limits.
static WTF::String durationString(Random& random)
{
    WTF::StringBuilder builder;
    unsigned sign = random.below(10);
    if (!sign)
        builder.append('-');
    else if (sign == 1)
        builder.append('+');
    builder.append(random.percent(90) ? 'P' : 'p');
    auto appendInteger = [&] {
        unsigned size = random.below(100);
        if (size < 80)
            builder.append(random.range(0, 99));
        else if (size < 95)
            appendDigits(builder, random, random.range(3, 8));
        else
            appendDigits(builder, random, random.range(9, 22));
    };
    static constexpr char dateUnits[] = { 'Y', 'M', 'W', 'D' };
    bool anyDate = false;
    for (unsigned i = 0; i < 4; ++i) {
        if (random.percent(30)) {
            appendInteger();
            builder.append(random.percent(90) ? dateUnits[i] : WTF::toASCIILower(dateUnits[i]));
            anyDate = true;
        }
    }
    bool time = !anyDate || random.percent(55);
    if (time) {
        builder.append(random.percent(92) ? 'T' : 't');
        static constexpr char timeUnits[] = { 'H', 'M', 'S' };
        unsigned first = random.below(3);
        unsigned last = random.range(first, 2);
        for (unsigned i = first; i <= last; ++i) {
            if (i != first && i != last && random.percent(40))
                continue;
            appendInteger();
            if (i == last && random.percent(40)) {
                builder.append(random.percent(85) ? '.' : ',');
                appendDigits(builder, random, random.range(1, 9));
            }
            builder.append(timeUnits[i]);
        }
    }
    return builder.toString();
}

static constexpr ASCIILiteral malformedDurations[] = {
    "P"_s, "PT"_s, "P1"_s, "PT1"_s, "P1D T1H"_s, "P1M1Y"_s, "PT1M1H"_s, "PT1.5H2M"_s, "PT0.1234567891S"_s, "PT.5S"_s,
    "P1.5D"_s, "1D"_s, "-P"_s, "P1DT"_s, "P1W1M"_s, "PT1S1S"_s, "P--1D"_s, "PT1,S"_s,
};

static WTF::Vector<TextInput> parseDurationsInputs()
{
    Random random(4);
    WTF::Vector<TextInput> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        unsigned kind = random.below(100);
        WTF::String text;
        if (kind < 86)
            text = durationString(random);
        else if (kind < 94)
            text = random.pick(malformedDurations);
        else
            text = damage(random, durationString(random));
        inputs.append({ WTF::move(text) });
    }
    return finishText(WTF::move(inputs));
}

enum class TimeZoneKind : uint8_t { Identifier, TimeZoneString, Offset };

// Time zone identifiers as Temporal.TimeZone-like strings take them: an IANA name or an offset, and, for the
// time zone string production, also any date-time string with a time zone in it.
static WTF::Vector<TextInput> parseTimeZoneIdentifiersInputs()
{
    Random random(5);
    WTF::Vector<TextInput> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        unsigned kind = random.below(100);
        TimeZoneKind timeZoneKind;
        WTF::StringBuilder builder;
        if (kind < 40) {
            timeZoneKind = TimeZoneKind::Identifier;
            unsigned form = random.below(100);
            if (form < 60)
                builder.append(random.pick(timeZoneNames));
            else if (form < 85)
                appendOffset(builder, random, random.percent(20));
            else
                builder.append(random.pick(malformedTimeZoneNames));
        } else if (kind < 70) {
            timeZoneKind = TimeZoneKind::TimeZoneString;
            unsigned form = random.below(100);
            if (form < 30)
                builder.append(random.pick(timeZoneNames));
            else if (form < 45)
                appendOffset(builder, random, random.percent(20));
            else if (form < 75)
                builder.append(zonedDateTimeString(random));
            else if (form < 95)
                builder.append(instantString(random));
            else
                builder.append(plainDateString(random, false));
        } else {
            timeZoneKind = TimeZoneKind::Offset;
            appendOffset(builder, random, random.percent(50));
        }
        auto text = builder.toString();
        if (random.percent(8))
            text = damage(random, text);
        inputs.append({ WTF::move(text), static_cast<uint8_t>(timeZoneKind) });
    }
    return finishText(WTF::move(inputs));
}

static void addParsed(Digest& digest, const std::optional<ISO::ParsedISODateTime>& parsed)
{
    if (!parsed) {
        digest.missing();
        return;
    }
    digest.addInteger(static_cast<uint64_t>(parsed->matched) << 1 | parsed->isShortForm);
    if (parsed->date)
        digest.add(*parsed->date);
    else
        digest.missing();
    if (parsed->time)
        digest.add(*parsed->time);
    else
        digest.missing();
    if (parsed->timeZone) {
        auto& timeZone = *parsed->timeZone;
        digest.addInteger(static_cast<uint64_t>(timeZone.m_z) << 1 | timeZone.m_offsetHasSubMinutePrecision);
        if (timeZone.m_offset)
            digest.addInteger(static_cast<uint64_t>(*timeZone.m_offset));
        else
            digest.missing();
        if (auto* name = std::get_if<WTF::Vector<Latin1Character>>(&timeZone.m_nameOrOffset))
            digest.add(name->span());
        else
            digest.addInteger(static_cast<uint64_t>(std::get<int64_t>(timeZone.m_nameOrOffset)));
    } else
        digest.missing();
    if (parsed->calendar)
        digest.add(parsed->calendar->span());
    else
        digest.missing();
}

static void addTimeZoneName(Digest& digest, std::span<const Latin1Character> name)
{
    if (auto id = ISO::parseTimeZoneName(WTF::StringView(name)))
        digest.addInteger(static_cast<uint64_t>(*id));
    else
        digest.missing();
}

static void addIdentifier(Digest& digest, const std::optional<ISO::TimeZoneIdentifierParseRecord>& record)
{
    if (!record) {
        digest.missing();
        return;
    }
    if (record->offsetMinutes)
        digest.addInteger(static_cast<uint64_t>(*record->offsetMinutes));
    else {
        digest.add(record->name.span());
        addTimeZoneName(digest, record->name.span());
    }
}

// Temporal.Instant.from: parse, check the limits, and convert to epoch nanoseconds.
static void runInstant(Digest& digest, WTF::StringView text)
{
    auto parsed = ISO::parseISODateTime(text, ISO::TemporalProduction::Instant);
    addParsed(digest, parsed);
    if (!parsed || !parsed->date || !parsed->time || !parsed->timeZone)
        return;
    auto& date = *parsed->date;
    auto& time = *parsed->time;
    int64_t offset = parsed->timeZone->m_z ? 0 : parsed->timeZone->m_offset.value_or(0);
    bool inRange = ISO::isDateTimeWithinLimits(date.year(), date.month(), date.day(), time.hour(), time.minute(), time.second(), time.millisecond(), time.microsecond(), time.nanosecond());
    digest.addInteger(static_cast<uint64_t>(inRange));
    if (!inRange)
        return;
    digest.add(ISO::ExactTime::fromISOPartsAndOffset(date.year(), date.month(), date.day(), time.hour(), time.minute(), time.second(), time.millisecond(), time.microsecond(), time.nanosecond(), offset));
}

// Temporal.ZonedDateTime.from's parse and its time zone name's resolution.
static void runZonedDateTime(Digest& digest, WTF::StringView text)
{
    auto parsed = ISO::parseISODateTime(text, ISO::TemporalProduction::DateTimeZoned);
    addParsed(digest, parsed);
    if (!parsed || !parsed->timeZone)
        return;
    if (auto* name = std::get_if<WTF::Vector<Latin1Character>>(&parsed->timeZone->m_nameOrOffset); name && !name->isEmpty())
        addTimeZoneName(digest, name->span());
}

static void runPlain(Digest& digest, WTF::StringView text, PlainKind kind)
{
    switch (kind) {
    case PlainKind::Date:
        addParsed(digest, ISO::parseISODateTime(text, ISO::TemporalProduction::DateTimeUnzoned));
        return;
    case PlainKind::YearMonth:
        addParsed(digest, ISO::parseISODateTime(text, ISO::TemporalProduction::YearMonth));
        return;
    case PlainKind::MonthDay:
        addParsed(digest, ISO::parseISODateTime(text, ISO::TemporalProduction::MonthDay));
        return;
    case PlainKind::Time:
        addParsed(digest, ISO::parseISODateTime(text, ISO::TemporalProduction::Time));
        return;
    }
}

static void runDuration(Digest& digest, WTF::StringView text)
{
    auto duration = ISO::parseDuration(text);
    if (!duration) {
        digest.missing();
        return;
    }
    digest.add(*duration);
    digest.addInteger(static_cast<uint64_t>(ISO::isValidDuration(*duration)));
}

static void runTimeZone(Digest& digest, WTF::StringView text, TimeZoneKind kind)
{
    switch (kind) {
    case TimeZoneKind::Identifier:
        addIdentifier(digest, ISO::parseTimeZoneIdentifier(text));
        return;
    case TimeZoneKind::TimeZoneString:
        addIdentifier(digest, ISO::parseTemporalTimeZoneString(text));
        return;
    case TimeZoneKind::Offset: {
        auto offset = ISO::parseUTCOffset(text);
        digest.addInteger(offset ? static_cast<uint64_t>(*offset) : 0xdead);
        auto minuteOffset = ISO::parseUTCOffset(text, ISO::SubMinutePrecision::No);
        digest.addInteger(minuteOffset ? static_cast<uint64_t>(*minuteOffset) : 0xdead);
        auto minutes = ISO::parseUTCOffsetInMinutes(text);
        digest.addInteger(minutes ? static_cast<uint64_t>(*minutes) : 0xdead);
        return;
    }
    }
}

// A date and time within the representable range, mostly near the present, sometimes at the range's ends.
static ISO::PlainDate randomDate(Random& random)
{
    unsigned kind = random.below(100);
    int year;
    if (kind < 85)
        year = random.range(1900, 2100);
    else if (kind < 97)
        year = random.range(-9999, 99999);
    else
        year = random.percent(50) ? -271821 : 275760;
    unsigned month = random.range(1, 12);
    if (year == -271821)
        month = random.range(4, 12);
    else if (year == 275760)
        month = random.range(1, 9);
    unsigned day = random.range(1, daysIn(year, month));
    if (year == -271821 && month == 4)
        day = random.range(19, 30);
    else if (year == 275760 && month == 9)
        day = random.range(1, 13);
    return ISO::PlainDate(year, month, day);
}

static ISO::PlainTime randomTime(Random& random)
{
    if (random.percent(20))
        return ISO::PlainTime();
    bool fraction = random.percent(40);
    unsigned hour = random.range(0, 23);
    unsigned minute = random.range(0, 59);
    unsigned second = random.range(0, 59);
    unsigned millisecond = fraction ? random.range(0, 999) : 0;
    unsigned microsecond = fraction ? random.range(0, 999) : 0;
    unsigned nanosecond = fraction ? random.range(0, 999) : 0;
    return ISO::PlainTime(hour, minute, second, millisecond, microsecond, nanosecond);
}

static constexpr JSC::RoundingMode roundingModes[] = {
    JSC::RoundingMode::Ceil, JSC::RoundingMode::Floor, JSC::RoundingMode::Expand, JSC::RoundingMode::Trunc,
    JSC::RoundingMode::HalfCeil, JSC::RoundingMode::HalfFloor, JSC::RoundingMode::HalfExpand,
    JSC::RoundingMode::HalfTrunc, JSC::RoundingMode::HalfEven,
};

static JSC::TemporalUnit unitBetween(Random& random, JSC::TemporalUnit first, JSC::TemporalUnit last)
{
    return static_cast<JSC::TemporalUnit>(random.range(static_cast<int>(first), static_cast<int>(last)));
}

// An increment for a unit: usually one the unit allows, sometimes one that does not divide it.
static unsigned randomIncrement(Random& random, JSC::TemporalUnit unit)
{
    if (random.percent(55))
        return 1;
    switch (unit) {
    case JSC::TemporalUnit::Hour:
        return random.pick({ 2u, 3u, 4u, 6u, 8u, 12u, 5u, 24u });
    case JSC::TemporalUnit::Minute:
    case JSC::TemporalUnit::Second:
        return random.pick({ 2u, 5u, 10u, 15u, 30u, 7u, 60u });
    case JSC::TemporalUnit::Millisecond:
    case JSC::TemporalUnit::Microsecond:
    case JSC::TemporalUnit::Nanosecond:
        return random.pick({ 2u, 5u, 10u, 20u, 50u, 100u, 250u, 500u, 3u, 1000u });
    default:
        return random.pick({ 2u, 3u, 7u });
    }
}

enum class FormatKind : uint8_t { DateTime, Time, Date, YearMonth, MonthDay, Offset, Instant, MonthCode };

struct FormatInput {
    FormatKind kind;
    ISO::PlainDate date;
    ISO::PlainTime time;
    JSC::Precision precision;
    unsigned digits;
    int64_t offset;
    bool hasOffset;
    WTF::Int128 epochNanoseconds;
    ASCIILiteral calendarName;
    JSC::CalendarID calendar;
};

static WTF::Vector<FormatInput> formatDateTimesInputs()
{
    Random random(6);
    JSC::CalendarID calendars[] = { JSC::iso8601CalendarID(), JSC::iso8601CalendarID(), Core::calendarIDFromString("gregory"_s), Core::calendarIDFromString("japanese"_s) };
    static constexpr ASCIILiteral calendarNames[] = { "auto"_s, "always"_s, "never"_s, "critical"_s };
    WTF::Vector<FormatInput> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        unsigned kind = random.below(100);
        FormatKind formatKind = kind < 30 ? FormatKind::DateTime : kind < 42 ? FormatKind::Time : kind < 54 ? FormatKind::Date
            : kind < 62 ? FormatKind::YearMonth : kind < 70 ? FormatKind::MonthDay : kind < 78 ? FormatKind::Offset
            : kind < 96 ? FormatKind::Instant : FormatKind::MonthCode;
        unsigned precisionKind = random.below(10);
        JSC::Precision precision = precisionKind < 5 ? JSC::Precision::Auto : precisionKind < 7 ? JSC::Precision::Minute : JSC::Precision::Fixed;
        int64_t offset = static_cast<int64_t>(random.range(-23, 23)) * 3600'000'000'000LL;
        if (random.percent(40))
            offset += static_cast<int64_t>(random.pick({ 30, 45, 15 })) * 60'000'000'000LL;
        if (random.percent(15))
            offset += static_cast<int64_t>(random.range(1, 59)) * 1'000'000'000LL;
        if (random.percent(10))
            offset += random.range(1, 999'999'999);
        if (offset < 0 && random.percent(50))
            offset = -offset;
        WTF::Int128 epoch = random.range(-2'000'000, 2'000'000) * WTF::Int128(1'000'000'000'000LL);
        WTF::Int128 fraction = random.range(0, 999'999'999);
        epoch += fraction * random.pick({ 1, 1000, 1'000'000 });
        if (random.percent(3))
            epoch = random.percent(50) ? ISO::ExactTime::maxValue : ISO::ExactTime::minValue;
        inputs.append({
            formatKind,
            randomDate(random),
            randomTime(random),
            precision,
            static_cast<unsigned>(random.range(0, 9)),
            offset,
            random.percent(60),
            epoch,
            random.pick(calendarNames),
            random.pick(calendars),
        });
        if (formatKind == FormatKind::MonthCode)
            inputs.last().digits = random.range(1, 13);
    }
    return inputs;
}

static size_t runFormat(Digest& digest, const FormatInput& input)
{
    WTF::String result;
    switch (input.kind) {
    case FormatKind::DateTime:
        result = ISO::temporalDateTimeToString(input.date, input.time, { input.precision, input.digits });
        break;
    case FormatKind::Time:
        result = ISO::temporalTimeToString(input.time, { input.precision, input.digits });
        break;
    case FormatKind::Date:
        result = ISO::temporalDateToString(input.date);
        break;
    case FormatKind::YearMonth: {
        ISO::PlainYearMonth yearMonth = input.calendar == JSC::iso8601CalendarID() ? ISO::PlainYearMonth(input.date.year(), input.date.month()) : ISO::PlainYearMonth(ISO::PlainDate(input.date));
        result = ISO::temporalYearMonthToString(yearMonth, input.calendarName, input.calendar);
        break;
    }
    case FormatKind::MonthDay: {
        ISO::PlainMonthDay monthDay = input.calendar == JSC::iso8601CalendarID() ? ISO::PlainMonthDay(input.date.month(), input.date.day()) : ISO::PlainMonthDay(ISO::PlainDate(input.date));
        result = ISO::temporalMonthDayToString(monthDay, input.calendarName, input.calendar);
        break;
    }
    case FormatKind::Offset:
        result = ISO::formatTimeZoneOffsetString(input.offset);
        break;
    case FormatKind::Instant: {
        std::optional<int64_t> offset;
        if (input.hasOffset)
            offset = input.offset;
        result = Core::instantToString(ISO::ExactTime(input.epochNanoseconds), offset, JSC::PrecisionData { { input.precision, input.digits }, JSC::TemporalUnit::Nanosecond, 1 });
        break;
    }
    case FormatKind::MonthCode:
        result = ISO::monthCode(input.digits);
        break;
    }
    digest.add(result);
    return result.length();
}

enum class CalendarKind : uint8_t { Week, Validity, BalanceYearMonth, AddDays, Regulate, DateAdd, Compare, Difference, MonthCode, RoundDateTime };

struct CalendarInput {
    CalendarKind kind;
    ISO::PlainDate date;
    ISO::PlainDate other;
    ISO::PlainTime time;
    ISO::PlainTime otherTime;
    int64_t first;
    int64_t second;
    int64_t third;
    ISO::Duration duration;
    JSC::TemporalOverflow overflow;
    JSC::TemporalUnit unit;
    JSC::RoundingMode mode;
    unsigned increment;
    WTF::String text;
};

static constexpr ASCIILiteral monthCodes[] = {
    "M01"_s, "M02"_s, "M03"_s, "M04"_s, "M05"_s, "M06"_s, "M07"_s, "M08"_s, "M09"_s, "M10"_s, "M11"_s, "M12"_s,
    "M13"_s, "M05L"_s, "M00L"_s, "M00"_s, "M1"_s, "m01"_s, "M01X"_s, "M123"_s, "MAB"_s, ""_s, "M99"_s,
};

static ISO::Duration randomDateDuration(Random& random)
{
    int64_t sign = random.percent(70) ? 1 : -1;
    unsigned size = random.below(100);
    auto field = [&](unsigned chance, int maximum) -> int64_t {
        if (!random.percent(chance))
            return 0;
        if (size >= 95) {
            int64_t magnitude = random.range(0, 1'000'000);
            return sign * magnitude * random.range(1, 300);
        }
        return sign * random.range(0, maximum);
    };
    int64_t years = field(30, 30);
    int64_t months = field(40, 30);
    int64_t weeks = field(20, 60);
    int64_t days = field(60, 400);
    return ISO::Duration(years, months, weeks, days, 0, 0, 0, 0, 0, 0);
}

static WTF::Vector<CalendarInput> calendarMathInputs()
{
    Random random(7);
    WTF::Vector<CalendarInput> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        unsigned kind = random.below(100);
        CalendarKind calendarKind = kind < 25 ? CalendarKind::Week : kind < 33 ? CalendarKind::Validity : kind < 40 ? CalendarKind::BalanceYearMonth
            : kind < 50 ? CalendarKind::AddDays : kind < 58 ? CalendarKind::Regulate : kind < 72 ? CalendarKind::DateAdd
            : kind < 78 ? CalendarKind::Compare : kind < 88 ? CalendarKind::Difference : kind < 93 ? CalendarKind::MonthCode
            : CalendarKind::RoundDateTime;
        CalendarInput input {
            calendarKind,
            randomDate(random),
            randomDate(random),
            randomTime(random),
            randomTime(random),
            0, 0, 0,
            randomDateDuration(random),
            random.percent(60) ? JSC::TemporalOverflow::Constrain : JSC::TemporalOverflow::Reject,
            JSC::TemporalUnit::Day,
            random.pick(roundingModes),
            1,
            WTF::String(),
        };
        switch (calendarKind) {
        case CalendarKind::Validity:
            input.first = random.range(-300000, 300000);
            input.second = random.range(-1, 14);
            input.third = random.range(-1, 33);
            break;
        case CalendarKind::BalanceYearMonth:
            input.first = random.range(-271821, 275760);
            input.second = random.percent(70) ? random.range(-30, 40) : random.range(-3'000'000, 3'000'000);
            break;
        case CalendarKind::AddDays:
            input.first = random.percent(70) ? random.range(-40, 40) : random.range(-100'000'000, 100'000'000);
            break;
        case CalendarKind::Regulate:
            input.first = input.date.year();
            input.second = random.percent(80) ? random.range(1, 12) : random.range(-2, 15);
            input.third = random.percent(70) ? random.range(1, 31) : random.range(-5, 40);
            break;
        case CalendarKind::Compare:
            if (random.percent(30))
                input.other = input.date;
            if (random.percent(30))
                input.otherTime = input.time;
            break;
        case CalendarKind::Difference:
            input.unit = random.pick({ JSC::TemporalUnit::Year, JSC::TemporalUnit::Month, JSC::TemporalUnit::Week, JSC::TemporalUnit::Day });
            break;
        case CalendarKind::MonthCode:
            input.text = random.pick(monthCodes);
            if (random.percent(25))
                input.text = make16Bit(input.text);
            break;
        case CalendarKind::RoundDateTime:
            input.unit = unitBetween(random, JSC::TemporalUnit::Day, JSC::TemporalUnit::Nanosecond);
            input.increment = randomIncrement(random, input.unit);
            break;
        default:
            break;
        }
        inputs.append(WTF::move(input));
    }
    return inputs;
}

static bool withinLimits(const ISO::PlainDate& date, const ISO::PlainTime& time)
{
    return ISO::isDateTimeWithinLimits(date.year(), date.month(), date.day(), time.hour(), time.minute(), time.second(), time.millisecond(), time.microsecond(), time.nanosecond());
}

static void runCalendar(Digest& digest, const CalendarInput& input)
{
    switch (input.kind) {
    case CalendarKind::Week:
        digest.addInteger(static_cast<uint64_t>(ISO::dayOfWeek(input.date)) << 48 | static_cast<uint64_t>(ISO::dayOfYear(input.date)) << 32
            | static_cast<uint64_t>(ISO::weekOfYear(input.date)) << 24 | static_cast<uint64_t>(ISO::daysInMonth(input.date.year(), input.date.month())) << 16
            | ISO::daysInMonth(input.date.month()));
        digest.addInteger(static_cast<uint64_t>(static_cast<int64_t>(ISO::yearOfWeek(input.date))));
        return;
    case CalendarKind::Validity:
        digest.addInteger(static_cast<uint64_t>(ISO::isValidISODate(static_cast<double>(input.first), static_cast<double>(input.second), static_cast<double>(input.third))));
        digest.addInteger(static_cast<uint64_t>(withinLimits(input.date, input.time)));
        return;
    case CalendarKind::BalanceYearMonth: {
        auto yearMonth = Core::balanceISOYearMonth(input.first, input.second);
        digest.add(yearMonth.isoPlainDate());
        return;
    }
    case CalendarKind::AddDays:
        digest.add(Core::addDaysToISODate(input.date, input.first));
        return;
    case CalendarKind::Regulate: {
        auto result = Core::regulateISODate(static_cast<int32_t>(input.first), static_cast<int32_t>(input.second), input.third, input.overflow);
        if (digest.add(result))
            digest.add(*result);
        return;
    }
    case CalendarKind::DateAdd: {
        auto result = Core::calendarDateAdd(input.date, input.duration, input.overflow);
        if (digest.add(result))
            digest.add(*result);
        return;
    }
    case CalendarKind::Compare:
        digest.addInteger(static_cast<uint64_t>(static_cast<int64_t>(Core::isoDateCompare(input.date, input.other))));
        digest.addInteger(static_cast<uint64_t>(static_cast<int64_t>(Core::isoTimeCompare(input.time, input.otherTime))));
        digest.addInteger(static_cast<uint64_t>(static_cast<int64_t>(Core::compareISODateTime(input.date, input.time, input.other, input.otherTime))));
        return;
    case CalendarKind::Difference:
        digest.add(Core::diffISODate(input.date, input.other, input.unit));
        if (withinLimits(input.date, input.time) && withinLimits(input.other, input.otherTime))
            digest.add(Core::diffISODateTime(input.date, input.time, input.other, input.otherTime, input.unit));
        return;
    case CalendarKind::MonthCode:
        if (auto parsed = ISO::parseMonthCode(input.text))
            digest.addInteger(static_cast<uint64_t>(parsed->monthNumber) << 1 | parsed->isLeapMonth);
        else
            digest.missing();
        return;
    case CalendarKind::RoundDateTime: {
        if (!withinLimits(input.date, input.time)) {
            digest.missing();
            return;
        }
        auto rounded = Core::roundISODateTime(input.date, input.time, JSC::lengthInNanoseconds(input.unit) * input.increment, input.unit, input.mode);
        digest.add(rounded.date);
        digest.add(rounded.time);
        digest.add(Core::getUTCEpochNanoseconds(input.date, input.time));
        return;
    }
    }
}

enum class DurationKind : uint8_t { Add, Round, RoundRelative, Total, Balance, InstantAdd, Fields };

struct DurationInput {
    DurationKind kind;
    ISO::Duration duration;
    ISO::Duration other;
    ISO::PlainDate relativeTo;
    WTF::Int128 epochNanoseconds;
    JSC::TemporalUnit largestUnit;
    JSC::TemporalUnit smallestUnit;
    JSC::RoundingMode mode;
    unsigned increment;
    JSC::CalendarID calendar;
    double fieldValue;
};

// A time duration (with days for some), of one sign; one in twenty-five has mixed signs or passes the limits.
static ISO::Duration randomTimeDuration(Random& random, bool withDays)
{
    int64_t sign = random.percent(65) ? 1 : -1;
    unsigned size = random.below(100);
    auto field = [&](unsigned chance, int maximum) -> int64_t {
        if (!random.percent(chance))
            return 0;
        if (size >= 92) {
            int64_t magnitude = random.range(0, 2'000'000'000);
            return sign * magnitude * random.range(1, 2000);
        }
        return sign * random.range(0, maximum);
    };
    int64_t days = withDays ? field(50, 500) : 0;
    int64_t hours = field(60, 100);
    int64_t minutes = field(50, 200);
    int64_t seconds = field(60, 5000);
    int64_t milliseconds = field(35, 2000);
    WTF::Int128 microseconds = field(25, 2000);
    WTF::Int128 nanoseconds = field(25, 2000);
    if (random.percent(2))
        hours = -hours - 1;
    if (random.percent(2))
        seconds = sign * 9'007'199'254'740'991LL;
    return ISO::Duration(0, 0, 0, days, hours, minutes, seconds, milliseconds, microseconds, nanoseconds);
}

static WTF::Vector<DurationInput> durationArithmeticInputs()
{
    Random random(8);
    JSC::CalendarID gregory = Core::calendarIDFromString("gregory"_s);
    WTF::Vector<DurationInput> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        unsigned kind = random.below(100);
        DurationKind durationKind = kind < 22 ? DurationKind::Add : kind < 44 ? DurationKind::Round : kind < 60 ? DurationKind::RoundRelative
            : kind < 70 ? DurationKind::Total : kind < 82 ? DurationKind::Balance : kind < 92 ? DurationKind::InstantAdd : DurationKind::Fields;
        DurationInput input {
            durationKind,
            randomTimeDuration(random, durationKind != DurationKind::InstantAdd),
            randomTimeDuration(random, true),
            randomDate(random),
            random.epochNanoseconds(),
            JSC::TemporalUnit::Day,
            JSC::TemporalUnit::Nanosecond,
            random.pick(roundingModes),
            1,
            JSC::iso8601CalendarID(),
            0,
        };
        switch (durationKind) {
        case DurationKind::Round:
        case DurationKind::Balance:
            input.smallestUnit = unitBetween(random, JSC::TemporalUnit::Day, JSC::TemporalUnit::Nanosecond);
            input.largestUnit = unitBetween(random, JSC::TemporalUnit::Day, input.smallestUnit);
            input.increment = randomIncrement(random, input.smallestUnit);
            break;
        case DurationKind::RoundRelative: {
            auto dateDuration = randomDateDuration(random);
            auto timeDuration = randomTimeDuration(random, false);
            if ((dateDuration.days() < 0) == (timeDuration.hours() < 0) || !timeDuration.hours())
                input.duration = ISO::Duration(dateDuration.years(), dateDuration.months(), dateDuration.weeks(), dateDuration.days(), timeDuration.hours(), timeDuration.minutes(), timeDuration.seconds(), timeDuration.milliseconds(), timeDuration.microseconds(), timeDuration.nanoseconds());
            else
                input.duration = dateDuration;
            input.largestUnit = unitBetween(random, JSC::TemporalUnit::Year, JSC::TemporalUnit::Day);
            input.smallestUnit = unitBetween(random, input.largestUnit, JSC::TemporalUnit::Nanosecond);
            input.increment = input.smallestUnit == input.largestUnit || input.smallestUnit > JSC::TemporalUnit::Day ? randomIncrement(random, input.smallestUnit) : 1;
            if (random.percent(10))
                input.calendar = gregory;
            break;
        }
        case DurationKind::Total:
            input.smallestUnit = unitBetween(random, JSC::TemporalUnit::Day, JSC::TemporalUnit::Nanosecond);
            break;
        case DurationKind::Fields:
            input.smallestUnit = unitBetween(random, JSC::TemporalUnit::Year, JSC::TemporalUnit::Nanosecond);
            input.fieldValue = random.pick({ 0.0, 1.0, -1.0, 123456789.0, 9007199254740991.0, -9007199254740991.0, 1e19, -1e19, 1e40, -1e40, 0.5 });
            break;
        default:
            break;
        }
        inputs.append(WTF::move(input));
    }
    return inputs;
}

static void runDurationArithmetic(Digest& digest, const DurationInput& input)
{
    bool valid = ISO::isValidDuration(input.duration);
    digest.addInteger(static_cast<uint64_t>(valid));
    switch (input.kind) {
    case DurationKind::Add: {
        // Temporal.Duration.prototype.add with no relativeTo.
        if (!valid || !ISO::isValidDuration(input.other))
            return;
        auto largest = std::min(Core::largestSubduration(input.duration), Core::largestSubduration(input.other));
        auto one = Core::toInternalDurationRecordWith24HourDays(input.duration);
        auto two = Core::toInternalDurationRecordWith24HourDays(input.other);
        if (!digest.add(one) || !digest.add(two))
            return;
        WTF::Int128 sum = one->time() + two->time();
        if (sum > ISO::InternalDuration::maxTimeDuration || sum < -ISO::InternalDuration::maxTimeDuration) {
            digest.missing();
            return;
        }
        auto result = Core::temporalDurationFromInternal(ISO::InternalDuration::combineDateAndTimeDuration(ISO::Duration(), sum), largest);
        if (digest.add(result))
            digest.add(*result);
        return;
    }
    case DurationKind::Round: {
        // Temporal.Duration.prototype.round with no relativeTo: a day or time unit.
        if (!valid)
            return;
        auto maximum = Core::maximumRoundingIncrement(input.smallestUnit);
        auto incrementCheck = Core::validateTemporalRoundingIncrement(input.increment, maximum ? std::optional<double>(*maximum) : std::nullopt, JSC::Inclusivity::Exclusive);
        if (!digest.add(incrementCheck))
            return;
        auto internal = Core::toInternalDurationRecordWith24HourDays(input.duration);
        if (!digest.add(internal))
            return;
        WTF::Int128 increment = JSC::lengthInNanoseconds(input.smallestUnit) * input.increment;
        WTF::Int128 rounded = Core::roundNumberToIncrementInt128(internal->time(), increment, input.mode);
        digest.add(rounded);
        if (rounded > ISO::InternalDuration::maxTimeDuration || rounded < -ISO::InternalDuration::maxTimeDuration) {
            digest.missing();
            return;
        }
        auto result = Core::temporalDurationFromInternal(ISO::InternalDuration::combineDateAndTimeDuration(ISO::Duration(), rounded), input.largestUnit);
        if (digest.add(result))
            digest.add(*result);
        digest.addInteger(static_cast<uint64_t>(Core::negateTemporalRoundingMode(input.mode)));
        return;
    }
    case DurationKind::RoundRelative: {
        // Temporal.Duration.prototype.round relative to a plain date.
        if (!valid)
            return;
        auto maximum = Core::maximumRoundingIncrement(input.smallestUnit);
        auto incrementCheck = Core::validateTemporalRoundingIncrement(input.increment, maximum ? std::optional<double>(*maximum) : std::nullopt, JSC::Inclusivity::Exclusive);
        if (!digest.add(incrementCheck))
            return;
        auto internal = Core::toInternalDurationRecordWith24HourDays(input.duration);
        if (!digest.add(internal))
            return;
        auto intermediate = Core::calendarDateAdd(input.relativeTo, internal->dateDuration(), JSC::TemporalOverflow::Constrain);
        if (!digest.add(intermediate))
            return;
        auto [overflowDays, subdayNanoseconds] = Core::splitTimeDuration(internal->time());
        auto target = Core::calendarDateAdd(*intermediate, ISO::Duration(0, 0, 0, overflowDays, 0, 0, 0, 0, 0, 0), JSC::TemporalOverflow::Constrain);
        if (!digest.add(target))
            return;
        auto targetTime = Core::plainTimeFromSubdayNs(subdayNanoseconds);
        auto difference = Core::differencePlainDateTimeWithRounding(input.relativeTo, ISO::PlainTime(), *target, targetTime,
            input.calendar, input.largestUnit, input.smallestUnit, input.mode, input.increment);
        if (!digest.add(difference))
            return;
        digest.add(*difference);
        digest.addInteger(static_cast<uint64_t>(static_cast<int64_t>(difference->sign())));
        auto result = Core::temporalDurationFromInternal(*difference, input.largestUnit);
        if (digest.add(result))
            digest.add(*result);
        return;
    }
    case DurationKind::Total: {
        // Temporal.Duration.prototype.total with no relativeTo.
        if (!valid)
            return;
        auto internal = Core::toInternalDurationRecordWith24HourDays(input.duration);
        if (!digest.add(internal))
            return;
        digest.add(Core::totalTimeDuration(internal->time(), input.smallestUnit));
        digest.add(Core::roundNumberToIncrementDouble(static_cast<double>(input.duration.hours()), 5, input.mode));
        return;
    }
    case DurationKind::Balance: {
        // The time duration from components, balanced up to a largest unit, and its normalized forms.
        if (!valid)
            return;
        digest.addInteger(static_cast<uint64_t>(static_cast<int64_t>(Core::durationSign(input.duration))));
        digest.add(Core::negateDuration(input.duration));
        digest.add(Core::absDuration(input.duration));
        auto internal = Core::toInternalDurationRecord(input.duration);
        digest.add(internal);
        digest.add(Core::toInternalDuration(input.duration));
        WTF::Int128 time = Core::timeDurationFromComponents(static_cast<double>(input.duration.hours()), static_cast<double>(input.duration.minutes()),
            static_cast<double>(input.duration.seconds()), static_cast<double>(input.duration.milliseconds()),
            static_cast<double>(input.duration.microseconds()), static_cast<double>(input.duration.nanoseconds()));
        digest.add(time);
        auto withDays = Core::add24HourDaysToTimeDuration(time, static_cast<double>(input.duration.days()));
        if (digest.add(withDays)) {
            auto result = Core::temporalDurationFromInternal(ISO::InternalDuration::combineDateAndTimeDuration(ISO::Duration(), *withDays), input.largestUnit);
            if (digest.add(result))
                digest.add(*result);
        }
        auto dateOnly = Core::toDateDurationRecordWithoutTime(input.duration);
        if (digest.add(dateOnly))
            digest.add(*dateOnly);
        auto adjusted = Core::adjustDateDurationRecord(input.duration, input.duration.days() / 2, std::nullopt, std::nullopt);
        if (digest.add(adjusted))
            digest.add(*adjusted);
        return;
    }
    case DurationKind::InstantAdd: {
        // Temporal.Instant.prototype.add.
        if (!valid)
            return;
        if (auto result = ISO::ExactTime(input.epochNanoseconds).add(input.duration))
            digest.add(*result);
        else
            digest.missing();
        return;
    }
    case DurationKind::Fields: {
        // Duration fields set from JavaScript numbers, and the totals the validity check uses.
        ISO::Duration duration = input.duration;
        duration.setField(input.smallestUnit, input.fieldValue);
        digest.add(duration);
        bool fieldsValid = ISO::isValidDuration(duration);
        digest.addInteger(static_cast<uint64_t>(fieldsValid));
        // The totals, through the exported core: the time part alone, then with the days folded in. Both are in
        // range only for a valid duration (timeDurationFromComponents asserts it).
        if (!fieldsValid) {
            digest.missing();
            digest.missing();
        } else {
            digest.add(Core::timeDurationFromComponents(static_cast<double>(duration.hours()), static_cast<double>(duration.minutes()),
                static_cast<double>(duration.seconds()), static_cast<double>(duration.milliseconds()),
                static_cast<double>(duration.microseconds()), static_cast<double>(duration.nanoseconds())));
            auto withDays = Core::toInternalDurationRecordWith24HourDays(duration);
            if (digest.add(withDays))
                digest.add(withDays->time());
        }
        auto checked = JSC::checkedCastDoubleToInt128(input.fieldValue);
        digest.add(checked.hasOverflowed() ? WTF::Int128(-1) : checked.value());
        return;
    }
    }
}

enum class ZonedKind : uint8_t { EpochFor, OffsetFor, Possible, Add, Difference, StartOfDay, Interpret, Transition, Equals };

struct ZonedInput {
    ZonedKind kind;
    unsigned zone;
    unsigned otherZone;
    ISO::PlainDate date;
    ISO::PlainTime time;
    WTF::Int128 epochNanoseconds;
    WTF::Int128 otherEpochNanoseconds;
    ISO::Duration duration;
    JSC::TemporalDisambiguation disambiguation;
    JSC::OffsetBehaviour offsetBehaviour;
    JSC::TemporalOffsetDisambiguation offsetOption;
    int64_t inlineOffset;
    bool startOfDay;
    bool matchMinutes;
    JSC::TemporalOverflow overflow;
    JSC::TemporalUnit largestUnit;
    JSC::TemporalUnit smallestUnit;
    JSC::RoundingMode mode;
    unsigned increment;
    JSC::TransitionDirection direction;
};

static constexpr ASCIILiteral zonedTimeZones[] = {
    "UTC"_s, "America/New_York"_s, "Europe/London"_s, "Europe/Rome"_s, "Australia/Lord_Howe"_s, "Asia/Kolkata"_s,
    "Pacific/Apia"_s, "America/Sao_Paulo"_s, "Asia/Tokyo"_s, "Africa/Casablanca"_s, "+05:30"_s, "-08:00"_s,
    "2020-01-01T00:00+01:00[Europe/Paris]"_s, "2020-01-01T00:00Z"_s,
};

// Wall-clock times that fall in a skipped or a repeated hour in one of the zones above.
struct WallTime {
    int year;
    unsigned month;
    unsigned day;
    unsigned hour;
    unsigned minute;
};
static constexpr WallTime transitionWallTimes[] = {
    { 2021, 3, 14, 2, 30 }, { 2021, 11, 7, 1, 30 }, { 2021, 3, 28, 1, 30 }, { 2021, 10, 31, 1, 30 },
    { 2021, 3, 28, 2, 30 }, { 2021, 10, 31, 2, 30 }, { 2021, 4, 4, 1, 45 }, { 2021, 10, 3, 2, 15 },
    { 2011, 12, 30, 12, 0 }, { 2018, 11, 4, 0, 30 }, { 2019, 2, 17, 0, 30 }, { 2022, 3, 27, 2, 0 },
};

static WTF::Vector<JSC::TimeZone> resolveTimeZones()
{
    WTF::Vector<JSC::TimeZone> timeZones;
    for (auto identifier : zonedTimeZones) {
        auto record = ISO::parseTemporalTimeZoneString(identifier);
        if (!record)
            continue;
        if (record->offsetMinutes) {
            timeZones.append(JSC::TimeZone::fromUTCOffset(*record->offsetMinutes * static_cast<int64_t>(ISO::ExactTime::nsPerMinute)));
            continue;
        }
        if (auto id = ISO::parseTimeZoneName(WTF::StringView(record->name.span())))
            timeZones.append(JSC::TimeZone::fromID(*id));
    }
    return timeZones;
}

static WTF::Vector<ZonedInput> zonedArithmeticInputs(unsigned zoneCount)
{
    Random random(9);
    WTF::Vector<ZonedInput> inputs;
    if (!zoneCount)
        return inputs;
    for (unsigned i = 0; i < inputCount / 4; ++i) {
        unsigned kind = random.below(100);
        ZonedKind zonedKind = kind < 18 ? ZonedKind::EpochFor : kind < 32 ? ZonedKind::OffsetFor : kind < 40 ? ZonedKind::Possible
            : kind < 58 ? ZonedKind::Add : kind < 70 ? ZonedKind::Difference : kind < 76 ? ZonedKind::StartOfDay
            : kind < 92 ? ZonedKind::Interpret : kind < 97 ? ZonedKind::Transition : ZonedKind::Equals;
        ISO::PlainDate date = randomDate(random);
        ISO::PlainTime time = randomTime(random);
        if (random.percent(35)) {
            auto& wall = random.pick(transitionWallTimes);
            date = ISO::PlainDate(wall.year, wall.month, wall.day);
            time = ISO::PlainTime(wall.hour, wall.minute, 0, 0, 0, 0);
        }
        WTF::Int128 epoch = random.epochNanoseconds();
        if (random.percent(3))
            epoch = random.percent(50) ? ISO::ExactTime::maxValue : ISO::ExactTime::minValue;
        WTF::Int128 distance = random.range(-400'000, 400'000);
        WTF::Int128 otherEpoch = epoch + distance * random.pick({ 1'000'000'000LL, 60'000'000'000LL, 3600'000'000'000LL });
        if (otherEpoch > ISO::ExactTime::maxValue || otherEpoch < ISO::ExactTime::minValue)
            otherEpoch = epoch;
        ISO::Duration duration = random.percent(50) ? randomDateDuration(random) : randomTimeDuration(random, true);
        unsigned behaviour = random.below(3);
        ZonedInput input {
            zonedKind,
            random.below(zoneCount),
            random.below(zoneCount),
            date,
            time,
            epoch,
            otherEpoch,
            duration,
            random.pick({ JSC::TemporalDisambiguation::Compatible, JSC::TemporalDisambiguation::Compatible, JSC::TemporalDisambiguation::Earlier, JSC::TemporalDisambiguation::Later, JSC::TemporalDisambiguation::Reject }),
            behaviour == 0 ? JSC::OffsetBehaviour::Wall : behaviour == 1 ? JSC::OffsetBehaviour::Exact : JSC::OffsetBehaviour::Option,
            random.pick({ JSC::TemporalOffsetDisambiguation::Use, JSC::TemporalOffsetDisambiguation::Prefer, JSC::TemporalOffsetDisambiguation::Ignore, JSC::TemporalOffsetDisambiguation::Reject }),
            0,
            random.percent(10),
            random.percent(50),
            random.percent(70) ? JSC::TemporalOverflow::Constrain : JSC::TemporalOverflow::Reject,
            JSC::TemporalUnit::Day,
            JSC::TemporalUnit::Nanosecond,
            random.pick(roundingModes),
            1,
            random.percent(50) ? JSC::TransitionDirection::Next : JSC::TransitionDirection::Previous,
        };
        if (input.offsetBehaviour == JSC::OffsetBehaviour::Option) {
            int64_t quarterHours = random.range(-14 * 4, 14 * 4);
            input.inlineOffset = quarterHours * 15 * 60'000'000'000LL + (random.percent(10) ? random.range(1, 59) * 1'000'000'000LL : 0);
        }
        if (input.offsetBehaviour != JSC::OffsetBehaviour::Wall)
            input.startOfDay = false;
        if (zonedKind == ZonedKind::Difference) {
            input.largestUnit = unitBetween(random, JSC::TemporalUnit::Year, JSC::TemporalUnit::Day);
            input.smallestUnit = unitBetween(random, input.largestUnit, JSC::TemporalUnit::Nanosecond);
            input.increment = input.smallestUnit > JSC::TemporalUnit::Day ? randomIncrement(random, input.smallestUnit) : 1;
            auto maximum = Core::maximumRoundingIncrement(input.smallestUnit);
            if (maximum && (input.increment >= *maximum || *maximum % input.increment))
                input.increment = 1;
        }
        inputs.append(WTF::move(input));
    }
    return inputs;
}

static void runZoned(Digest& digest, const WTF::Vector<JSC::TimeZone>& timeZones, const ZonedInput& input)
{
    auto& timeZone = timeZones[input.zone];
    ISO::ExactTime exactTime(input.epochNanoseconds);
    switch (input.kind) {
    case ZonedKind::EpochFor: {
        auto result = Core::getEpochNanosecondsFor(timeZone, input.date, input.time, input.disambiguation);
        if (digest.add(result))
            digest.add(*result);
        return;
    }
    case ZonedKind::OffsetFor: {
        auto offset = Core::getOffsetNanosecondsFor(timeZone, exactTime);
        if (!digest.add(offset))
            return;
        digest.addInteger(static_cast<uint64_t>(*offset));
        auto local = Core::getISODateTimeFor(timeZone, exactTime);
        if (digest.add(local)) {
            digest.add(local->date);
            digest.add(local->time);
        }
        auto fromOffset = Core::exactTimeToLocalDateAndTime(exactTime, *offset);
        digest.add(fromOffset.date);
        digest.add(fromOffset.time);
        return;
    }
    case ZonedKind::Possible: {
        auto possible = Core::getPossibleEpochNanosecondsFor(timeZone, input.date, input.time);
        if (!digest.add(possible))
            return;
        if (auto* gap = std::get_if<Core::GapOffsets>(&*possible)) {
            digest.addInteger(static_cast<uint64_t>(gap->beforeNs));
            digest.addInteger(static_cast<uint64_t>(gap->afterNs));
            return;
        }
        for (auto& candidate : Core::epochCandidates(*possible))
            digest.add(candidate);
        return;
    }
    case ZonedKind::Add: {
        // Temporal.ZonedDateTime.prototype.add.
        if (!ISO::isValidDuration(input.duration)) {
            digest.missing();
            return;
        }
        auto result = Core::addZonedDateTime(exactTime, timeZone, input.duration, input.overflow);
        if (digest.add(result))
            digest.add(*result);
        return;
    }
    case ZonedKind::Difference: {
        // Temporal.ZonedDateTime.prototype.until with a calendar largest unit.
        auto result = Core::differenceZonedDateTimeWithRounding(exactTime, ISO::ExactTime(input.otherEpochNanoseconds), timeZone,
            input.largestUnit, input.smallestUnit, input.mode, input.increment);
        if (digest.add(result))
            digest.add(*result);
        return;
    }
    case ZonedKind::StartOfDay: {
        auto result = Core::getStartOfDay(timeZone, input.date);
        if (digest.add(result))
            digest.add(*result);
        return;
    }
    case ZonedKind::Interpret: {
        // Temporal.ZonedDateTime.from's resolution of a parsed date, time and offset.
        auto result = Core::interpretISODateTimeOffset(input.date, input.time,
            input.startOfDay ? Core::UseStartOfDay::Yes : Core::UseStartOfDay::No, input.offsetBehaviour, input.offsetOption,
            input.inlineOffset, input.matchMinutes ? Core::MatchBehaviour::MatchMinutes : Core::MatchBehaviour::MatchExactly,
            timeZone, input.disambiguation);
        if (digest.add(result))
            digest.add(*result);
        return;
    }
    case ZonedKind::Transition: {
        auto result = Core::getTimeZoneTransition(timeZone, exactTime, input.direction);
        if (!digest.add(result))
            return;
        if (*result)
            digest.add(**result);
        else
            digest.missing();
        return;
    }
    case ZonedKind::Equals:
        digest.addInteger(static_cast<uint64_t>(Core::timeZoneEquals(timeZone, timeZones[input.otherZone])));
        return;
    }
}

enum class MixKind : uint8_t { InstantRoundTrip, PlainDateAdd, DurationTotal, ZonedFrom, Compare, TimeZoneLookup };

// A script's mix: parse a string, do arithmetic on the value, and format the result.
static WTF::Vector<TextInput> mixInputs()
{
    Random random(10);
    WTF::Vector<TextInput> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        unsigned kind = random.below(100);
        MixKind mixKind = kind < 25 ? MixKind::InstantRoundTrip : kind < 45 ? MixKind::PlainDateAdd : kind < 60 ? MixKind::DurationTotal
            : kind < 80 ? MixKind::ZonedFrom : kind < 92 ? MixKind::Compare : MixKind::TimeZoneLookup;
        WTF::String text;
        switch (mixKind) {
        case MixKind::InstantRoundTrip:
            text = instantString(random);
            break;
        case MixKind::PlainDateAdd:
        case MixKind::Compare:
            text = plainDateString(random, random.percent(40));
            break;
        case MixKind::DurationTotal:
            text = durationString(random);
            break;
        case MixKind::ZonedFrom: {
            WTF::StringBuilder builder;
            appendDate(builder, random);
            builder.append('T');
            appendTime(builder, random);
            if (random.percent(40))
                appendOffset(builder, random, false);
            builder.append('[');
            builder.append(random.pick({ "UTC"_s, "America/New_York"_s, "Europe/London"_s, "Asia/Tokyo"_s, "+05:30"_s }));
            builder.append(']');
            text = builder.toString();
            break;
        }
        case MixKind::TimeZoneLookup:
            text = random.pick(timeZoneNames);
            break;
        }
        if (random.percent(6))
            text = damage(random, text);
        inputs.append({ WTF::move(text), static_cast<uint8_t>(mixKind) });
    }
    return finishText(WTF::move(inputs));
}

static constexpr std::tuple<JSC::Precision, unsigned> autoPrecision { JSC::Precision::Auto, 0 };

static void runMix(Digest& digest, WTF::StringView text, MixKind kind)
{
    switch (kind) {
    case MixKind::InstantRoundTrip: {
        // Temporal.Instant.from(string).add({ hours: 1 }).toString()
        auto parsed = ISO::parseISODateTime(text, ISO::TemporalProduction::Instant);
        if (!parsed || !parsed->date || !parsed->time || !parsed->timeZone) {
            digest.missing();
            return;
        }
        auto& date = *parsed->date;
        auto& time = *parsed->time;
        if (!ISO::isDateTimeWithinLimits(date.year(), date.month(), date.day(), time.hour(), time.minute(), time.second(), time.millisecond(), time.microsecond(), time.nanosecond())) {
            digest.missing();
            return;
        }
        int64_t offset = parsed->timeZone->m_z ? 0 : parsed->timeZone->m_offset.value_or(0);
        auto exactTime = ISO::ExactTime::fromISOPartsAndOffset(date.year(), date.month(), date.day(), time.hour(), time.minute(), time.second(), time.millisecond(), time.microsecond(), time.nanosecond(), offset);
        auto later = exactTime.add(ISO::Duration(0, 0, 0, 0, 1, 0, 0, 0, 0, 0));
        if (!later) {
            digest.missing();
            return;
        }
        digest.add(Core::instantToString(*later, std::nullopt, JSC::PrecisionData { autoPrecision, JSC::TemporalUnit::Nanosecond, 1 }));
        return;
    }
    case MixKind::PlainDateAdd: {
        // Temporal.PlainDate.from(string).add({ months: 1, days: 10 }).toString()
        auto parsed = ISO::parseISODateTime(text, ISO::TemporalProduction::DateTimeUnzoned);
        if (!parsed || !parsed->date) {
            digest.missing();
            return;
        }
        auto result = Core::calendarDateAdd(*parsed->date, ISO::Duration(0, 1, 0, 10, 0, 0, 0, 0, 0, 0), JSC::TemporalOverflow::Constrain);
        if (!digest.add(result))
            return;
        digest.add(ISO::temporalDateToString(*result));
        if (parsed->time)
            digest.add(ISO::temporalDateTimeToString(*result, *parsed->time, autoPrecision));
        return;
    }
    case MixKind::DurationTotal: {
        // Temporal.Duration.from(string).total("seconds")
        auto duration = ISO::parseDuration(text);
        if (!duration || !ISO::isValidDuration(*duration)) {
            digest.missing();
            return;
        }
        if (duration->years() || duration->months() || duration->weeks()) {
            digest.addInteger(Core::largestSubduration(*duration) == JSC::TemporalUnit::Year ? 1 : 2);
            return;
        }
        auto internal = Core::toInternalDurationRecordWith24HourDays(*duration);
        if (digest.add(internal))
            digest.add(Core::totalTimeDuration(internal->time(), JSC::TemporalUnit::Second));
        return;
    }
    case MixKind::ZonedFrom: {
        // Temporal.ZonedDateTime.from(string).toString()
        auto parsed = ISO::parseISODateTime(text, ISO::TemporalProduction::DateTimeZoned);
        if (!parsed || !parsed->date || !parsed->timeZone) {
            digest.missing();
            return;
        }
        auto& annotation = parsed->timeZone->m_nameOrOffset;
        std::optional<JSC::TimeZone> timeZone;
        if (auto* name = std::get_if<WTF::Vector<Latin1Character>>(&annotation)) {
            if (auto id = ISO::parseTimeZoneName(WTF::StringView(name->span())))
                timeZone = JSC::TimeZone::fromID(*id);
        } else
            timeZone = JSC::TimeZone::fromUTCOffset(std::get<int64_t>(annotation));
        if (!timeZone) {
            digest.missing();
            return;
        }
        auto time = parsed->time.value_or(ISO::PlainTime());
        bool hasOffset = parsed->timeZone->m_offset.has_value();
        auto exactTime = Core::interpretISODateTimeOffset(*parsed->date, time, Core::UseStartOfDay::No,
            hasOffset ? JSC::OffsetBehaviour::Option : JSC::OffsetBehaviour::Wall, JSC::TemporalOffsetDisambiguation::Reject,
            parsed->timeZone->m_offset.value_or(0), Core::MatchBehaviour::MatchMinutes, *timeZone, JSC::TemporalDisambiguation::Compatible);
        if (!digest.add(exactTime))
            return;
        auto offset = Core::getOffsetNanosecondsFor(*timeZone, *exactTime);
        if (!digest.add(offset))
            return;
        auto local = Core::exactTimeToLocalDateAndTime(*exactTime, *offset);
        digest.add(ISO::temporalDateTimeToString(local.date, local.time, autoPrecision));
        digest.add(ISO::formatTimeZoneOffsetString(*offset));
        return;
    }
    case MixKind::Compare: {
        // Temporal.PlainDateTime.compare(string, a fixed date-time) and until() in days.
        auto parsed = ISO::parseISODateTime(text, ISO::TemporalProduction::DateTimeUnzoned);
        if (!parsed || !parsed->date) {
            digest.missing();
            return;
        }
        ISO::PlainDate reference(2020, 2, 29);
        auto time = parsed->time.value_or(ISO::PlainTime());
        digest.addInteger(static_cast<uint64_t>(static_cast<int64_t>(Core::compareISODateTime(*parsed->date, time, reference, ISO::PlainTime()))));
        auto difference = Core::differenceTemporalPlainDateTime(JSC::DifferenceOperation::Until, reference, ISO::PlainTime(), *parsed->date, time,
            JSC::iso8601CalendarID(), JSC::TemporalUnit::Nanosecond, JSC::TemporalUnit::Day, JSC::RoundingMode::Trunc, 1);
        if (digest.add(difference))
            digest.add(*difference);
        return;
    }
    case MixKind::TimeZoneLookup: {
        // new Temporal.ZonedDateTime(0n, name)
        auto record = ISO::parseTimeZoneIdentifier(text);
        addIdentifier(digest, record);
        return;
    }
    }
}

// The production sets the callers pass to parseISODateTime.
static constexpr ISO::TemporalProductionSet rejectShortStringsProductions[] = {
    ISO::TemporalProduction::Instant,
    ISO::TemporalProduction::DateTimeZoned,
    ISO::TemporalProduction::DateTimeUnzoned,
    { ISO::TemporalProduction::DateTimeZoned, ISO::TemporalProduction::DateTimeUnzoned },
    ISO::TemporalProduction::YearMonth,
    ISO::TemporalProduction::MonthDay,
    ISO::TemporalProduction::Time,
    { ISO::TemporalProduction::Instant, ISO::TemporalProduction::DateTimeZoned, ISO::TemporalProduction::DateTimeUnzoned,
        ISO::TemporalProduction::YearMonth, ISO::TemporalProduction::MonthDay, ISO::TemporalProduction::Time },
};

static constexpr uint8_t rejectShortStringsTimeZoneString = 1 << 3;

// Short strings, nearly all rejected early: random strings of up to six of the characters that steer the grammar,
// and short strings a script passes. Each goes through one production set; one in eight also through the time zone
// string production.
static WTF::Vector<TextInput> rejectShortStringsInputs()
{
    static constexpr char alphabet[] = "01256 9-+:.,TtZ[]!=/PDHMSWYua";
    static constexpr ASCIILiteral scriptStrings[] = {
        ""_s, "2024"_s, "12:"_s, "T"_s, "--12"_s, "P1"_s, "Z"_s, "[UTC]"_s, "1-1"_s, "2024-1"_s,
    };
    Random random(11);
    WTF::Vector<TextInput> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        WTF::String text;
        if (random.percent(85)) {
            WTF::StringBuilder builder;
            unsigned length = random.below(7);
            for (unsigned j = 0; j < length; ++j)
                builder.append(alphabet[random.below(sizeof(alphabet) - 1)]);
            text = builder.toString();
        } else
            text = random.pick(scriptStrings);
        uint8_t kind = static_cast<uint8_t>(random.below(std::size(rejectShortStringsProductions)));
        if (i % 8 == 7)
            kind |= rejectShortStringsTimeZoneString;
        inputs.append({ WTF::move(text), kind });
    }
    return finishText(WTF::move(inputs));
}

static void runRejectShortString(Digest& digest, WTF::StringView text, uint8_t kind)
{
    auto parsed = ISO::parseISODateTime(text, rejectShortStringsProductions[kind & 7]);
    digest.addInteger(static_cast<uint64_t>(parsed.has_value()));
    if (parsed)
        addParsed(digest, parsed);
    if (kind & rejectShortStringsTimeZoneString)
        addIdentifier(digest, ISO::parseTemporalTimeZoneString(text));
}

template<typename Input, typename Function>
static void run(ASCIILiteral name, const WTF::Vector<Input>& inputs, uint64_t expectedChecksum, unsigned passes, const Function& runOne)
{
    ASSERT_FALSE(inputs.isEmpty());
    auto runPass = [&](Digest& digest) {
        size_t bytes = 0;
        for (auto& input : inputs)
            bytes += runOne(digest, input);
        return bytes;
    };

    Digest digest;
    size_t bytes = runPass(digest);
    auto checksum = digest.value();
    EXPECT_EQ(expectedChecksum, checksum);
    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    size_t mismatches = 0;
    auto start = WTF::MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass) {
        Digest passDigest;
        runPass(passDigest);
        mismatches += passDigest.value() != checksum;
    }
    auto elapsed = WTF::MonotonicTime::now() - start;
    EXPECT_EQ(0u, mismatches);
    SAFE_PRINTF("%s: %.1f ms %.3f MB/s checksum=%016llx\n", name, elapsed.milliseconds(),
        static_cast<double>(bytes) * passes / elapsed.microseconds(), static_cast<unsigned long long>(checksum));
}

// The parse tests count the characters parsed; FormatDateTimes counts the characters written; the arithmetic
// tests count the size of the records they read.
static void runText(ASCIILiteral name, const WTF::Vector<TextInput>& inputs, uint64_t expectedChecksum, unsigned passes, void (*runOne)(Digest&, WTF::StringView, uint8_t))
{
    run(name, inputs, expectedChecksum, passes, [&](Digest& digest, const TextInput& input) -> size_t {
        runOne(digest, input.text, input.kind);
        return input.text.length();
    });
}

// Checksums of a Release build. The pass counts make each test's timed run about 1.5 s.
static constexpr uint64_t parseInstantsChecksum = 0x7cbc17b0eb3cd536ULL;
static constexpr uint64_t parseZonedDateTimesChecksum = 0x2b443accfed270ecULL;
static constexpr uint64_t parsePlainDatesChecksum = 0x934a556c95e29b56ULL;
static constexpr uint64_t parseDurationsChecksum = 0xf8c62145fa8dd046ULL;
static constexpr uint64_t parseTimeZoneIdentifiersChecksum = 0x7b77d84add820bf3ULL;
static constexpr uint64_t formatDateTimesChecksum = 0xf783ae3c11303653ULL;
static constexpr uint64_t calendarMathChecksum = 0xec7363fe7f45e44dULL;
static constexpr uint64_t durationArithmeticChecksum = 0x86f797047b366c80ULL;
static constexpr uint64_t zonedArithmeticChecksum = 0x07da0c301c078fa7ULL;
static constexpr uint64_t mixChecksum = 0x656a0a3c6743c30bULL;
static constexpr uint64_t rejectShortStringsChecksum = 0x944fe30a9c96a572ULL;

} // namespace TemporalBenchmark

using namespace TemporalBenchmark;

TEST(TemporalBench, ParseInstants)
{
    JSC::initialize();
    runText("ParseInstants"_s, parseInstantsInputs(), parseInstantsChecksum, 5700, [](Digest& digest, WTF::StringView text, uint8_t) {
        runInstant(digest, text);
    });
}

TEST(TemporalBench, ParseZonedDateTimes)
{
    JSC::initialize();
    runText("ParseZonedDateTimes"_s, parseZonedDateTimesInputs(), parseZonedDateTimesChecksum, 3200, [](Digest& digest, WTF::StringView text, uint8_t) {
        runZonedDateTime(digest, text);
    });
}

TEST(TemporalBench, ParsePlainDates)
{
    JSC::initialize();
    runText("ParsePlainDates"_s, parsePlainDatesInputs(), parsePlainDatesChecksum, 7100, [](Digest& digest, WTF::StringView text, uint8_t kind) {
        runPlain(digest, text, static_cast<PlainKind>(kind));
    });
}

TEST(TemporalBench, ParseDurations)
{
    JSC::initialize();
    runText("ParseDurations"_s, parseDurationsInputs(), parseDurationsChecksum, 10900, [](Digest& digest, WTF::StringView text, uint8_t) {
        runDuration(digest, text);
    });
}

TEST(TemporalBench, ParseTimeZoneIdentifiers)
{
    JSC::initialize();
    runText("ParseTimeZoneIdentifiers"_s, parseTimeZoneIdentifiersInputs(), parseTimeZoneIdentifiersChecksum, 5600, [](Digest& digest, WTF::StringView text, uint8_t kind) {
        runTimeZone(digest, text, static_cast<TimeZoneKind>(kind));
    });
}

TEST(TemporalBench, FormatDateTimes)
{
    JSC::initialize();
    run("FormatDateTimes"_s, formatDateTimesInputs(), formatDateTimesChecksum, 3300, [](Digest& digest, const FormatInput& input) -> size_t {
        return runFormat(digest, input);
    });
}

TEST(TemporalBench, CalendarMath)
{
    JSC::initialize();
    run("CalendarMath"_s, calendarMathInputs(), calendarMathChecksum, 12200, [](Digest& digest, const CalendarInput& input) -> size_t {
        runCalendar(digest, input);
        return sizeof(input);
    });
}

TEST(TemporalBench, DurationArithmetic)
{
    JSC::initialize();
    run("DurationArithmetic"_s, durationArithmeticInputs(), durationArithmeticChecksum, 3100, [](Digest& digest, const DurationInput& input) -> size_t {
        runDurationArithmetic(digest, input);
        return sizeof(input);
    });
}

TEST(TemporalBench, ZonedArithmetic)
{
    JSC::initialize();
    auto timeZones = resolveTimeZones();
    run("ZonedArithmetic"_s, zonedArithmeticInputs(static_cast<unsigned>(timeZones.size())), zonedArithmeticChecksum, 4000, [&](Digest& digest, const ZonedInput& input) -> size_t {
        runZoned(digest, timeZones, input);
        return sizeof(input);
    });
}

TEST(TemporalBench, Mix)
{
    JSC::initialize();
    runText("Mix"_s, mixInputs(), mixChecksum, 1700, [](Digest& digest, WTF::StringView text, uint8_t kind) {
        runMix(digest, text, static_cast<MixKind>(kind));
    });
}

TEST(TemporalBench, RejectShortStrings)
{
    JSC::initialize();
    runText("RejectShortStrings"_s, rejectShortStringsInputs(), rejectShortStringsChecksum, 6800, [](Digest& digest, WTF::StringView text, uint8_t kind) {
        runRejectShortString(digest, text, kind);
    });
}

} // namespace TestWebKitAPI
