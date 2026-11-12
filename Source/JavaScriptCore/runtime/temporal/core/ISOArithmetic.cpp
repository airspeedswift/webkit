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
#include "ISOArithmetic.h"

#include "TemporalSwiftBoundary.h"

#include "JSCSwift-Swift.h"

namespace JSC {
namespace TemporalCore {

ISO8601::PlainDate addDaysToISODate(const ISO8601::PlainDate& date, int64_t days)
{
    return temporalOutput<ISO8601::PlainDate>(JSCSwift::temporalAddDaysToISODate, date, days);
}

TemporalResult<ISO8601::PlainDate> regulateISODate(int32_t year, int32_t month, int64_t day, TemporalOverflow overflow)
{
    return temporalResult<ISO8601::PlainDate>(JSCSwift::temporalRegulateISODate, year, month, day, overflow);
}

TemporalResult<ISO8601::PlainDate> isoDateAdd(const ISO8601::PlainDate& plainDate, const ISO8601::Duration& duration, TemporalOverflow overflow)
{
    return temporalResult<ISO8601::PlainDate>(JSCSwift::temporalIsoDateAdd, plainDate, duration, overflow);
}

int32_t LEGACY_NODELETE isoDateCompare(const ISO8601::PlainDate& d1, const ISO8601::PlainDate& d2)
{
    return JSCSwift::temporalIsoDateCompare(d1, d2);
}

int32_t LEGACY_NODELETE isoTimeCompare(const ISO8601::PlainTime& t1, const ISO8601::PlainTime& t2)
{
    return JSCSwift::temporalIsoTimeCompare(t1, t2);
}

ISO8601::Duration diffISODate(const ISO8601::PlainDate& one, const ISO8601::PlainDate& two, TemporalUnit largestUnit)
{
    return temporalOutput<ISO8601::Duration>(JSCSwift::temporalDiffISODate, one, two, largestUnit);
}

ISO8601::InternalDuration diffISODateTime(const ISO8601::PlainDate& d1, const ISO8601::PlainTime& t1, const ISO8601::PlainDate& d2, const ISO8601::PlainTime& t2, TemporalUnit largestUnit)
{
    return temporalOutput<ISO8601::InternalDuration>(JSCSwift::temporalDiffISODateTime, d1, t1, d2, t2, largestUnit);
}

} // namespace TemporalCore
} // namespace JSC
