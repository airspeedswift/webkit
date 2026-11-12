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

// JSC Temporal Core — Instant algorithms
// temporal_rs reference: src/builtins/core/instant.rs
// Last synced: v0.2.3

extension TemporalOperations {
    // TemporalInstantToString — temporal_rs: Instant::to_ixdtf_string_with_provider (src/builtins/core/instant.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-temporalinstanttostring
    static func instantToString(_ exactTime: JSC.ISO8601.ExactTime, _ offsetNs: Int64?, _ precision: JSC.PrecisionData) -> WTF.String {
        // 1. Let outputTimeZone be timeZone.
        // 2. If outputTimeZone is undefined, set outputTimeZone to "UTC".
        // NOTE: steps 1-2 and step 7.a (GetOffsetNanosecondsFor) are resolved by the caller;
        // offsetNs is undefined when timeZone is undefined, otherwise the pre-resolved offset.
        // 3. Let epochNs be instant.[[EpochNanoseconds]].  (exactTime carries epochNs)
        // 4. Let isoDateTime be GetISODateTimeFor(outputTimeZone, epochNs).
        // Add the UTC offset to get local epoch-milliseconds, then decompose into date/time fields.
        let epochMs: Int64
        if let offsetNs {
            // Wraps only for an offset near Int64's limits: offsets are under a day.
            epochMs = exactTime.floorEpochMilliseconds() &+ offsetNs / TemporalISO8601.nsPerMillisecond
        } else {
            epochMs = exactTime.floorEpochMilliseconds()
        }

        let gregorianDateTime = WTF.PlainGregorianDateTime.fromMilliseconds(Double(epochMs))

        // 5. Let dateTimeString be ISODateTimeToString(isoDateTime, "iso8601", precision, ~never~).
        // NOTE: Inlined here: the fields come from an offset-adjusted time value rather than from a
        // PlainDate/PlainTime, so temporalDateTimeToString() cannot be called directly.
        // 5.1. Let yearString be PadISOYear(year).
        // At most 1 + 10 + 4 × 3 = 23 characters (a year has at most 10 digits).
        var dateTime = TemporalStringBuilder()
        let year = gregorianDateTime.year()
        var yearLength = 4
        if year > 9999 || year < 0 {
            dateTime.append(year < 0 ? UInt8(ascii: "-") : UInt8(ascii: "+"))
            yearLength = 6
        }
        // 5.2-5.3. month and day strings.
        // 5.5. Let timeString be FormatTimeString(...).
        // INT32_MIN wraps to itself. Years from a double time value are
        // within ±2^28.
        dateTime.append(decimal: year < 0 ? 0 &- year : year, paddedTo: yearLength)
        dateTime.append(UInt8(ascii: "-"))
        dateTime.append(decimal: gregorianDateTime.month() &+ 1, paddedTo: 2) // Cannot overflow: a month index is 0-11.
        dateTime.append(UInt8(ascii: "-"))
        dateTime.append(decimal: gregorianDateTime.monthDay(), paddedTo: 2)
        dateTime.append(UInt8(ascii: "T"))
        dateTime.append(decimal: gregorianDateTime.hour(), paddedTo: 2)
        dateTime.append(UInt8(ascii: ":"))
        dateTime.append(decimal: gregorianDateTime.minute(), paddedTo: 2)
        var builder = WTF.StringBuilder()
        builder.append(dateTime.makeString())

        // 5.4. subSecondNanoseconds = nanosecondsFraction() (sub-second ns of the instant).
        // NOTE: negative for pre-epoch instants; correction maps to the [0, nsPerSecond) range.
        var fraction = exactTime.nanosecondsFraction()
        if fraction < 0 {
            fraction += Int32(TemporalISO8601.nsPerSecond)
        }

        // The second and fraction are passed as unsigned.
        JSC.formatSecondsStringPart(&builder, UInt32(bitPattern: gregorianDateTime.second()), UInt32(bitPattern: fraction), precision)

        // 6. If timeZone is undefined, let timeZoneString be "Z".
        // 7. Else, let timeZoneString be FormatDateTimeUTCOffsetRounded(offsetNanoseconds).
        if let offsetNs {
            let nsPerMinute = TemporalISO8601.nsPerMinute
            let rawOffset = offsetNs
            let sign: Int64 = rawOffset < 0 ? -1 : 1
            // The negation and sums below wrap only for an offset near Int64's limits. Offsets are under a day.
            let absNs = rawOffset < 0 ? 0 &- rawOffset : rawOffset
            let minutes = (absNs &+ nsPerMinute / 2) / nsPerMinute
            let roundedNs = sign &* minutes &* nsPerMinute
            builder.append(TemporalISO8601.formatTimeZoneOffsetString(roundedNs))
        } else {
            var zulu = WTF.Latin1Character()
            zulu.value = UInt8(ascii: "Z")
            builder.append(zulu)
        }

        // 8. Return the string-concatenation of dateTimeString and timeZoneString.
        return JSC.temporalStringOf(&builder)
    }
}

// MARK: - Implementations of C++ declarations
//
// Each is the definition of the `JS_EXPORT_PRIVATE` declaration it names, under its C++ symbol: `public`, so that
// JavaScriptCore exports it, with the C++ type names spelled out. Every parameter is a value.

extension JSC.TemporalCore {
    /// `TemporalCore::instantToString`.
    @cxx
    @implementation
    public static func instantToString(
        _ exactTime: JSC.ISO8601.ExactTime,
        _ offsetNs: JSC.TemporalOptionalInt64,
        _ precision: JSC.PrecisionData
    ) -> WTF.String {
        TemporalOperations.instantToString(exactTime, offsetNs.value, precision)
    }
}
