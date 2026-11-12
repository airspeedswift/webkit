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

// JSC Temporal Core — Calendar field resolution (dateFromFields, yearMonthFromFields, monthDayFromFields)
// temporal_rs reference: src/builtins/core/calendar.rs, types.rs, fields.rs

// temporal_rs: fields.rs ROUGH_YEAR_RANGE = -300000..300000
private let temporalSafeYearMin: Int32 = -300000
private let temporalSafeYearMax: Int32 = 300000
// ISO reference year for PlainMonthDay — spec: CalendarMonthDayToISOReferenceDate. A leap year (Feb 29 representable).
private let temporalISOMonthDayReferenceLeapYear: Int32 = 1972

/// `icuReadCalendarFailed` (TemporalCoreTypes.h), byte for byte: an `ASCIILiteral` holds a pointer, which Swift reads
/// only unsafely.
///
/// Pinned by a `static_assert` in CalendarFields.cpp.
private let temporalICUReadCalendarFailed = "Failed to read calendar fields from ICU"

// temporal_rs: types.rs ResolvedIsoFields::try_from_fields (ISO-only resolution)
private enum TemporalISOResolveType {
    case date
    case yearMonth
    case monthDay
}

private struct TemporalResolvedISOFields {
    var year: Int32
    var month: UInt8
    var day: UInt8
}

private struct TemporalReferenceYearResolution {
    var year: Int32 = 0
    var usedRegularMonthFallback = false
}

// The Calendar Fields Record table's Enumeration Key column, restricted to the six calendar-date
// keys CalendarFieldsIn carries; a bitset rather than the spec's List to stay allocation-free. No
// ignore rule names the time keys or ~offset~/~time-zone~, so for those the merge degenerates to
// "the partial wins, else the receiver", which the two .with callers do inline.
private struct TemporalCalendarFieldKeys {
    let rawValue: UInt8

    static let none = TemporalCalendarFieldKeys(rawValue: 0)
    static let era = TemporalCalendarFieldKeys(rawValue: 1 << 0)
    static let eraYear = TemporalCalendarFieldKeys(rawValue: 1 << 1)
    static let year = TemporalCalendarFieldKeys(rawValue: 1 << 2)
    static let month = TemporalCalendarFieldKeys(rawValue: 1 << 3)
    static let monthCode = TemporalCalendarFieldKeys(rawValue: 1 << 4)
    static let day = TemporalCalendarFieldKeys(rawValue: 1 << 5)

    static func | (lhs: TemporalCalendarFieldKeys, rhs: TemporalCalendarFieldKeys) -> TemporalCalendarFieldKeys {
        TemporalCalendarFieldKeys(rawValue: lhs.rawValue | rhs.rawValue)
    }

    /// `OptionSet::contains`: every key of `other`.
    func contains(_ other: TemporalCalendarFieldKeys) -> Bool {
        rawValue & other.rawValue == other.rawValue
    }

    /// `OptionSet::containsAny`.
    func containsAny(_ other: TemporalCalendarFieldKeys) -> Bool {
        rawValue & other.rawValue != 0
    }

    mutating func insert(_ other: TemporalCalendarFieldKeys) {
        self = self | other
    }
}

/// `clampTo<uint8_t>(uint32_t)`.
@inline(always)
private func temporalClampToUInt8(_ value: UInt32) -> UInt8 {
    UInt8(clamping: value)
}

/// `clampTo<int32_t>(uint32_t)`.
@inline(always)
private func temporalClampToInt32(_ value: UInt32) -> Int32 {
    Int32(clamping: value)
}

extension TemporalOperations {
    // temporal_rs: fields.rs check_year_in_safe_arithmetical_range
    fileprivate static func checkYearRange(_ fields: JSC.TemporalCore.CalendarFieldsIn) -> TemporalOutcome<Void> {
        if let year = Optional(fromCxx: fields.year), year < temporalSafeYearMin || year > temporalSafeYearMax {
            return .failure(.range("Date is not within representable range"))
        }
        if let eraYear = Optional(fromCxx: fields.eraYear), eraYear < temporalSafeYearMin || eraYear > temporalSafeYearMax {
            return .failure(.range("eraYear is not within representable range"))
        }
        return .success(())
    }

    fileprivate static func checkLunisolarMonthConsistency(
        _ calendarId: JSC.CalendarID,
        _ fields: JSC.TemporalCore.CalendarFieldsIn,
        _ resolvedDate: JSC.ISO8601.PlainDate
    ) -> TemporalOutcome<Void> {
        guard JSC.TemporalCore.calendarIsLunisolar(calendarId), let month = Optional(fromCxx: fields.month),
            Optional(fromCxx: fields.monthCode) != nil
        else {
            return .success(())
        }

        let resolvedFields = JSC.TemporalCore.isoToCalendarFields(calendarId, resolvedDate)
        if !resolvedFields.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(resolvedFields)))
        }
        let resolvedCalendarFields: JSC.TemporalCore.CalendarFields = JSC.temporalValueOf(resolvedFields)
        if month != UInt32(resolvedCalendarFields.month) {
            return .failure(.range("month does not match monthCode"))
        }
        return .success(())
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-calendarresolvefields
    fileprivate static func calendarResolveFields(
        _ calendarId: JSC.CalendarID,
        _ fields: inout JSC.TemporalCore.CalendarFieldsIn,
        _ type: JSC.TemporalCore.ResolveType
    ) -> TemporalOutcome<Void> {
        if JSC.TemporalCore.calendarIsISO(calendarId) {
            // Steps 1.a-1.d: needsYear/needsDay.
            let needsYear = type == .Date || type == .YearMonth
            let needsDay = type == .Date || type == .MonthDay
            // Step 1.e: needsYear + year unset.
            if needsYear && Optional(fromCxx: fields.year) == nil {
                return .failure(.type("year property must be present"))
            }
            // Step 1.f: needsDay + day unset.
            if needsDay && Optional(fromCxx: fields.day) == nil {
                return .failure(.type("day property must be present"))
            }
            // Step 1.g: month and monthCode both unset.
            if Optional(fromCxx: fields.month) == nil && Optional(fromCxx: fields.monthCode) == nil {
                return .failure(.type("month or monthCode property must be present"))
            }
            // Step 1.h: monthCode validation + consistency with month.
            if let mc = Optional(fromCxx: fields.monthCode) {
                if mc.isLeapMonth {
                    return .failure(.range("iso8601 calendar does not have leap months"))
                }
                if mc.monthNumber < 1 || mc.monthNumber > 12 {
                    return .failure(.range("month must be 1-12 for iso8601 calendar"))
                }
                let codeMonth = mc.monthNumber
                if let month = Optional(fromCxx: fields.month), month != UInt32(codeMonth) {
                    return .failure(.range("month does not match monthCode"))
                }
                fields.month = .init(UInt32(codeMonth))
            }
            return .success(())
        }
        // Step 2: NonISOResolveFields.
        return nonISOResolveFields(calendarId, &fields, type)
    }

    // https://tc39.es/proposal-intl-era-monthcode/#sup-temporal-nonisoresolvefields
    static func nonISOResolveFields(
        _ calendarId: JSC.CalendarID,
        _ fields: inout JSC.TemporalCore.CalendarFieldsIn,
        _ type: JSC.TemporalCore.ResolveType
    ) -> TemporalOutcome<Void> {
        let hasYear = Optional(fromCxx: fields.year) != nil
        let hasMonth = Optional(fromCxx: fields.month) != nil
        let hasMonthCode = Optional(fromCxx: fields.monthCode) != nil
        let hasDay = Optional(fromCxx: fields.day) != nil
        let hasEra = Optional(fromCxx: fields.era) != nil
        let hasEraYear = Optional(fromCxx: fields.eraYear) != nil

        // Steps 1-4: needsYear.
        let needsYear =
            type == .Date
            || type == .YearMonth
            || !hasMonthCode
            || hasMonth
        // Steps 8-9: needsDay.
        let needsDay = type == .Date || type == .MonthDay

        let hasEras = JSC.TemporalCore.calendarHasEras(calendarId)
        let hasEraYearPair = hasEra && hasEraYear

        // Step 10: needsYear + year unset → require era+eraYear on an era-supporting calendar.
        if needsYear && !hasYear {
            if !hasEras || !hasEra || !hasEraYear {
                return .failure(.type("year property must be present"))
            }
        }
        if hasEras && hasEra != hasEraYear {
            return .failure(.type("era and eraYear must both be present or both absent"))
        }
        // Step 12: needsDay + day unset.
        if needsDay && !hasDay {
            return .failure(.type("day property must be present"))
        }
        // Step 13: month and monthCode both unset.
        if !hasMonth && !hasMonthCode {
            return .failure(.type("month or monthCode property must be present"))
        }

        // MonthDay-only checks not in the spec emu-alg: NonISOMonthDayToISOReferenceDate needs a
        // year to resolve leap-month layout, so demand monthCode + (year OR era+eraYear).
        if type == .MonthDay && !hasMonthCode && !hasYear && !hasEraYearPair {
            return .failure(.type("monthCode is required for non-ISO calendar MonthDay"))
        }
        if type == .MonthDay && hasMonth && hasMonthCode && !hasYear && !hasEraYearPair {
            return .failure(.type("year is required when both month and monthCode are given"))
        }

        if case .failure(let failure) = checkYearRange(fields) {
            return .failure(failure)
        }

        // Step 14: CalendarDateArithmeticYearForEraYear = canonicalize + non-positive remap + math;
        //          then reconcile with fields.year and store the arithmetic year.
        if hasEras, var era = Optional(fromCxx: fields.era), var eraYear = Optional(fromCxx: fields.eraYear) {
            if let canonical = Optional(fromCxx: JSC.TemporalCore.temporalCanonicalizeEraInCalendar(calendarId, era)) {
                era = canonical
                fields.era = .init(era)
            }
            if let remapped = Optional(fromCxx: JSC.TemporalCore.temporalRemapNonPositiveEraYear(calendarId, era, eraYear)) {
                era = remapped.first
                eraYear = remapped.second
                fields.era = .init(era)
                fields.eraYear = .init(eraYear)
            }
            guard
                let arithmeticYear = Optional(
                    fromCxx: JSC.TemporalCore.temporalCalendarDateArithmeticYearForEraYear(calendarId, era, eraYear)
                )
            else {
                return .failure(.range("era is not valid for this calendar"))
            }
            if let year = Optional(fromCxx: fields.year), year != arithmeticYear {
                return .failure(.range("year is inconsistent with era and eraYear"))
            }
            fields.year = .init(arithmeticYear)
        }
        // Steps 15-17: erase era + eraYear.
        fields.era = .init()
        fields.eraYear = .init()

        // Step 18: monthCode validation + resolve fields.[[Month]] from monthCode ordinal.
        if let mc = Optional(fromCxx: fields.monthCode) {
            // Step 18.a: IsValidMonthCodeForCalendar.
            if !JSC.TemporalCore.isValidMonthCodeForCalendar(calendarId, mc) {
                return .failure(.range("monthCode is not valid for this calendar"))
            }

            // Step 18.b — if year is set, derive MonthCodeToOrdinal and set fields.[[Month]].
            if let year = Optional(fromCxx: fields.year) {
                var ordinal: UInt8?
                if !JSC.TemporalCore.calendarIsLunisolar(calendarId) {
                    ordinal = mc.monthNumber
                } else {
                    let contained = JSC.TemporalCore.yearContainsMonthCode(calendarId, year, mc)
                    if !contained.has_value() {
                        return .failure(TemporalFailure(JSC.temporalErrorOf(contained)))
                    }
                    var constrained = mc
                    let isContained: Bool = JSC.temporalValueOf(contained)
                    if !isContained {
                        let constrainResult = JSC.TemporalCore.constrainMonthCode(calendarId, year, mc, .Constrain)
                        if !constrainResult.has_value() {
                            return .failure(TemporalFailure(JSC.temporalErrorOf(constrainResult)))
                        }
                        constrained = JSC.temporalValueOf(constrainResult)
                    }
                    // Step 18.b.ii: MonthCodeToOrdinal (precondition guaranteed by constrain above).
                    let ordinalResult = JSC.TemporalCore.monthCodeOrdinalInYear(calendarId, constrained, year)
                    if !ordinalResult.has_value() {
                        return .failure(TemporalFailure(JSC.temporalErrorOf(ordinalResult)))
                    }
                    let ordinalInYear: Int32 = JSC.temporalValueOf(ordinalResult)
                    ordinal = UInt8(truncatingIfNeeded: ordinalInYear) // static_cast<uint8_t>
                }
                if let ordinal {
                    // Step 18.b.iii: consistency.
                    if let month = Optional(fromCxx: fields.month), temporalClampToUInt8(month) != ordinal {
                        return .failure(.range("month does not match monthCode"))
                    }
                    // Step 18.b.iv: Set fields.[[Month]] to month.
                    fields.month = .init(UInt32(ordinal))
                }
            }
        }

        // Steps 19-22: postconditions, checked in Debug only.
        // Assertion 21 (needsOrdinalMonth → month set) may be relaxed when the lunisolar ICU
        // ordinal probe fails; downstream nonISOCalendarDateToISO re-derives via the monthCode.

        return .success(())
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-calendardatetoiso
    fileprivate static func calendarDateToISO(
        _ calendarId: JSC.CalendarID,
        _ fields: JSC.TemporalCore.CalendarFieldsIn,
        _ overflow: JSC.TemporalOverflow,
        _ type: TemporalISOResolveType
    ) -> TemporalOutcome<TemporalResolvedISOFields> {
        // Step 1: If calendar is "iso8601", then
        if JSC.TemporalCore.calendarIsISO(calendarId) {
            // Step 1.a: Assert: fields.[[Year]], fields.[[Month]], and fields.[[Day]] are not unset.
            // (`temporalValue` traps on an empty optional; calendarResolveFields set them.)
            let year = temporalValue(Optional(fromCxx: fields.year))
            let day: UInt8 = type == .yearMonth ? 1 : temporalValue(Optional(fromCxx: fields.day))
            let month = temporalValue(Optional(fromCxx: fields.month))

            // Step 1.b: Return ? RegulateISODate(fields.[[Year]], fields.[[Month]], fields.[[Day]], overflow).
            let date: JSC.ISO8601.PlainDate
            switch TemporalOperations.regulateISODate(year, temporalClampToInt32(month), Int64(day), overflow) {
            case .success(let value): date = value
            case .failure(let failure): return .failure(failure)
            }
            return .success(TemporalResolvedISOFields(year: date.year(), month: date.month(), day: date.day()))
        }

        // Step 2: Return ? NonISOCalendarDateToISO(calendar, fields, overflow).
        // CalendarResolveFields guarantees one of the two; 0 means "resolve by the monthCode".
        let month: UInt8 = Optional(fromCxx: fields.month).map(temporalClampToUInt8) ?? 0
        let day: UInt8 = type == .yearMonth ? 1 : temporalValue(Optional(fromCxx: fields.day))
        let result = JSC.TemporalCore.nonISOCalendarDateToISO(calendarId, fields.year, month, day, fields.monthCode, overflow)
        if !result.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(result)))
        }
        let date: JSC.ISO8601.PlainDate = JSC.temporalValueOf(result)
        return .success(TemporalResolvedISOFields(year: date.year(), month: date.month(), day: date.day()))
    }

    // CalendarDateFromFields — temporal_rs: Calendar::date_from_fields (src/builtins/core/calendar.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-calendardatefromfields
    // Implements steps 1-4; PrepareCalendarFields done by JS-layer caller.
    static func dateFromFields(
        _ calendarId: JSC.CalendarID,
        _ fields: JSC.TemporalCore.CalendarFieldsIn,
        _ overflow: JSC.TemporalOverflow
    ) -> TemporalOutcome<JSC.TemporalCore.ResolvedCalendarDate> {
        let isISO = JSC.TemporalCore.calendarIsISO(calendarId)

        var resolved = fields
        if isISO {
            if case .failure(let failure) = checkYearRange(resolved) {
                return .failure(failure)
            }
        }
        // Step 1: CalendarResolveFields.
        if case .failure(let failure) = calendarResolveFields(calendarId, &resolved, .Date) {
            return .failure(failure)
        }

        // Step 2: CalendarDateToISO.
        let resolvedIsoResult = calendarDateToISO(calendarId, resolved, overflow, .date)
        guard case .success(let resolvedIso) = resolvedIsoResult else {
            return .failure(temporalValue(resolvedIsoResult.failure))
        }
        let isoDate = JSC.ISO8601.PlainDate(resolvedIso.year, UInt32(resolvedIso.month), UInt32(resolvedIso.day))
        if case .failure(let failure) = checkLunisolarMonthConsistency(calendarId, fields, isoDate) {
            return .failure(failure)
        }

        // Step 3: If ISODateWithinLimits(result) is false, throw RangeError.
        if !TemporalISO8601.isDateTimeWithinLimits(resolvedIso.year, resolvedIso.month, resolvedIso.day, 12, 0, 0, 0, 0, 0) {
            return .failure(.range("Date is not within representable range"))
        }

        // Step 4: Return result.
        return .success(JSC.TemporalCore.ResolvedCalendarDate(isoDate: isoDate, calendarId: isISO ? JSC.iso8601CalendarID() : calendarId))
    }

    // CalendarYearMonthFromFields — temporal_rs: Calendar::year_month_from_fields (src/builtins/core/calendar.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-calendaryearmonthfromfields
    static func yearMonthFromFields(
        _ calendarId: JSC.CalendarID,
        _ fields: JSC.TemporalCore.CalendarFieldsIn,
        _ overflow: JSC.TemporalOverflow
    ) -> TemporalOutcome<JSC.TemporalCore.ResolvedCalendarDate> {
        let isISO = JSC.TemporalCore.calendarIsISO(calendarId)

        // Step 1: Set fields.[[Day]] to 1.
        var resolved = fields
        resolved.day = .init(1)

        if isISO {
            if case .failure(let failure) = checkYearRange(resolved) {
                return .failure(failure)
            }
        }

        // Step 2: CalendarResolveFields. (non-ISO: nonISOResolveFields does its own checkYearRange
        // interleaved with its presence/consistency checks — do not range-check again here.)
        if case .failure(let failure) = calendarResolveFields(calendarId, &resolved, .YearMonth) {
            return .failure(failure)
        }

        // Step 3: CalendarDateToISO.
        let resolvedIsoResult = calendarDateToISO(calendarId, resolved, overflow, .yearMonth)
        guard case .success(let resolvedIso) = resolvedIsoResult else {
            return .failure(temporalValue(resolvedIsoResult.failure))
        }
        let isoDate = JSC.ISO8601.PlainDate(resolvedIso.year, UInt32(resolvedIso.month), UInt32(resolvedIso.day))
        if case .failure(let failure) = checkLunisolarMonthConsistency(calendarId, fields, isoDate) {
            return .failure(failure)
        }

        // Step 4: If ISOYearMonthWithinLimits(result) is false, throw RangeError.
        if !JSC.ISO8601.isYearMonthWithinLimits(resolvedIso.year, Int32(resolvedIso.month)) {
            return .failure(.range("YearMonth is not within representable range"))
        }

        // Step 5: Return result.
        return .success(JSC.TemporalCore.ResolvedCalendarDate(isoDate: isoDate, calendarId: isISO ? JSC.iso8601CalendarID() : calendarId))
    }

    fileprivate static func ecmaReferenceYearWithRegularFallback(
        _ calendarId: JSC.CalendarID,
        _ monthCode: JSC.ParsedMonthCode,
        _ day: UInt8,
        _ overflow: JSC.TemporalOverflow
    ) -> TemporalOutcome<TemporalReferenceYearResolution> {
        let refYear = JSC.TemporalCore.ecmaReferenceYear(calendarId, monthCode.monthNumber, monthCode.isLeapMonth, day)
        if refYear.has_value() {
            return .success(TemporalReferenceYearResolution(year: JSC.temporalValueOf(refYear), usedRegularMonthFallback: false))
        }
        switch JSC.temporalErrorOf(refYear) as JSC.TemporalCore.EcmaReferenceYearError {
        case .MonthNotInCalendar:
            return .failure(.range("This month code does not exist in this calendar"))
        case .UseRegularIfConstrain:
            if overflow == .Reject {
                return .failure(.range("This leap month does not exist in this calendar near the reference year"))
            }
            let fallback = JSC.TemporalCore.ecmaReferenceYear(calendarId, monthCode.monthNumber, false, day) // Not a leap month.
            precondition(fallback.has_value())
            return .success(TemporalReferenceYearResolution(year: JSC.temporalValueOf(fallback), usedRegularMonthFallback: true))
        @unknown default:
            fatalError()
        }
    }

    // https://tc39.es/proposal-intl-era-monthcode/#sup-temporal-nonisomonthdaytoisoreferencedate
    // Steps 4-5 (day clamp) are folded into the nonISOCalendarDateToISO calls below, not written out
    // separately. `fields` (the unresolved record) is only used for checkLunisolarMonthConsistency.
    fileprivate static func nonISOMonthDayToISOReferenceDate(
        _ calendarId: JSC.CalendarID,
        _ resolved: JSC.TemporalCore.CalendarFieldsIn,
        _ fields: JSC.TemporalCore.CalendarFieldsIn,
        _ overflow: JSC.TemporalOverflow
    ) -> TemporalOutcome<JSC.ISO8601.PlainDate> {
        // Step 1: Assert: fields.[[Day]] is not ~unset~. (`temporalValue` traps on an empty optional.)
        var monthCode: JSC.ParsedMonthCode
        var month: UInt8 = 0 // 0 = "resolve by monthCode"; overwritten below when a year is given.
        var day: UInt8 = temporalValue(Optional(fromCxx: resolved.day)) // clampTo<uint8_t> of a uint8_t: the identity.
        // Step 8 needs an overflow the spec doesn't give it; see below for when it's forced to Constrain.
        var step8Overflow = overflow

        if Optional(fromCxx: resolved.year) != nil {
            // Step 2.a: month was set upstream by nonISOResolveFields when a year is present.
            // Steps 2.d-2.i, all at once: resolve month/monthCode/day in the caller's year.
            let inCallerYearResult = JSC.TemporalCore.nonISOCalendarDateToISO(
                calendarId,
                resolved.year,
                temporalClampToUInt8(temporalValue(Optional(fromCxx: resolved.month))),
                day,
                resolved.monthCode,
                overflow
            )
            if !inCallerYearResult.has_value() {
                return .failure(TemporalFailure(JSC.temporalErrorOf(inCallerYearResult)))
            }
            let inCallerYear: JSC.ISO8601.PlainDate = JSC.temporalValueOf(inCallerYearResult)
            if case .failure(let failure) = checkLunisolarMonthConsistency(calendarId, fields, inCallerYear) {
                return .failure(failure)
            }
            // Step 2.b: no input in this year lands within the ISO limits.
            if !JSC.ISO8601.isYearWithinLimits(inCallerYear.year()) {
                return .failure(.range("Date is not within representable range"))
            }
            // Step 2.g: read the monthCode back off that date.
            let callerYearFieldsResult = JSC.TemporalCore.isoToCalendarFields(calendarId, inCallerYear)
            if !callerYearFieldsResult.has_value() {
                return .failure(TemporalFailure(JSC.temporalErrorOf(callerYearFieldsResult)))
            }
            let callerYearFields: JSC.TemporalCore.CalendarFields = JSC.temporalValueOf(callerYearFieldsResult)
            if callerYearFields.monthCode.isEmpty() {
                return .failure(.range(temporalICUReadCalendarFailed))
            }
            guard let parsed = TemporalISO8601.parseMonthCode(callerYearFields.monthCode) else {
                return .failure(.range(temporalICUReadCalendarFailed))
            }
            monthCode = parsed
            month = callerYearFields.month
            day = callerYearFields.day
            // Steps 4-5 already applied above; the step 8 stand-in must not reject again.
            step8Overflow = .Constrain
        } else {
            // Steps 3.a-3.b: no ordinal yet (a monthCode's number isn't its ordinal position — M05L is
            // number 5 but ordinal 6 in a leap year), so leave month at 0 for step 8 to resolve by monthCode.
            monthCode = temporalValue(Optional(fromCxx: resolved.monthCode))
        }

        // Steps 6-7: reference year, plus 6.c's reject-or-strip. The chinese/dangi-only guard lives inside
        // ecmaReferenceYear (only it returns UseRegularIfConstrain), so this applies safely to every calendar.
        let referenceResult = ecmaReferenceYearWithRegularFallback(calendarId, monthCode, day, overflow)
        guard case .success(let reference) = referenceResult else {
            return .failure(temporalValue(referenceResult.failure))
        }
        if reference.usedRegularMonthFallback {
            monthCode = JSC.ParsedMonthCode(monthNumber: monthCode.monthNumber, isLeapMonth: false)
        }

        // Step 8, delegated: nonISOCalendarDateToISO's own resolution IS this AO's steps 2.d-2.i and 4-5
        // (the spec duplicates them). referenceYear was chosen so this call never needs to clamp.
        let result = JSC.TemporalCore.nonISOCalendarDateToISO(
            calendarId,
            .init(reference.year),
            month,
            day,
            .init(monthCode),
            step8Overflow
        )
        if !result.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(result)))
        }
        return .success(JSC.temporalValueOf(result))
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-calendarmonthdaytoisoreferencedate
    // calendarDateToISO is not reused: it stores whatever year it is given, this stores the reference year.
    fileprivate static func monthDayToISOReferenceDate(
        _ calendarId: JSC.CalendarID,
        _ resolved: JSC.TemporalCore.CalendarFieldsIn,
        _ fields: JSC.TemporalCore.CalendarFieldsIn,
        _ overflow: JSC.TemporalOverflow
    ) -> TemporalOutcome<JSC.ISO8601.PlainDate> {
        // Step 2 first; step 1 is the iso8601 arm below.
        if !JSC.TemporalCore.calendarIsISO(calendarId) {
            return nonISOMonthDayToISOReferenceDate(calendarId, resolved, fields, overflow)
        }

        // Step 1.a. (`temporalValue` traps on an empty optional.)
        // Steps 1.b-1.c: year only decides whether Feb 29 exists; RegulateISODate won't range-check it.
        let year = Optional(fromCxx: resolved.year) ?? temporalISOMonthDayReferenceLeapYear
        // Step 1.d.
        let date: JSC.ISO8601.PlainDate
        switch TemporalOperations.regulateISODate(
            year,
            temporalClampToInt32(temporalValue(Optional(fromCxx: resolved.month))),
            Int64(temporalValue(Optional(fromCxx: resolved.day))),
            overflow
        ) {
        case .success(let value): date = value
        case .failure(let failure): return .failure(failure)
        }
        // Step 1.e: the stored year is always the reference year, never the caller's.
        return .success(JSC.ISO8601.PlainDate(temporalISOMonthDayReferenceLeapYear, UInt32(date.month()), UInt32(date.day())))
    }

    // CalendarMonthDayFromFields — temporal_rs: Calendar::month_day_from_fields (src/builtins/core/calendar.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-calendarmonthdayfromfields
    static func monthDayFromFields(
        _ calendarId: JSC.CalendarID,
        _ fields: JSC.TemporalCore.CalendarFieldsIn,
        _ overflow: JSC.TemporalOverflow
    ) -> TemporalOutcome<JSC.TemporalCore.ResolvedCalendarDate> {
        var resolved = fields
        // Step 1: CalendarResolveFields.
        if case .failure(let failure) = calendarResolveFields(calendarId, &resolved, .MonthDay) {
            return .failure(failure)
        }

        // Step 2: CalendarMonthDayToISOReferenceDate.
        let isoDateResult = monthDayToISOReferenceDate(calendarId, resolved, fields, overflow)
        guard case .success(let isoDate) = isoDateResult else {
            return .failure(temporalValue(isoDateResult.failure))
        }

        // Step 3: Assert: ISODateWithinLimits(result), in Debug only.
        // Step 4: Return result.
        return .success(
            JSC.TemporalCore.ResolvedCalendarDate(
                isoDate: isoDate,
                calendarId: JSC.TemporalCore.calendarIsISO(calendarId) ? JSC.iso8601CalendarID() : calendarId
            )
        )
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-isodatetofields
    static func isoDateToFields(
        _ calendarId: JSC.CalendarID,
        _ isoDate: JSC.ISO8601.PlainDate,
        _ type: JSC.TemporalCore.ResolveType
    ) -> TemporalOutcome<JSC.TemporalCore.CalendarFieldsIn> {
        // Step 1: Let fields be an empty Calendar Fields Record with all fields set to ~unset~.
        var fields = JSC.TemporalCore.CalendarFieldsIn()

        // Step 2: Let calendarDate be CalendarISOToDate(calendar, isoDate).
        if JSC.TemporalCore.calendarIsISO(calendarId) {
            // Identity for "iso8601", so no ICU round-trip; the month code is the ISO month, never leap.
            fields.monthCode = .init(JSC.ParsedMonthCode(monthNumber: isoDate.month(), isLeapMonth: false)) // Step 3
            if type == .MonthDay || type == .Date { // Step 4
                fields.day = .init(isoDate.day())
            }
            if type == .YearMonth || type == .Date { // Step 5
                fields.year = .init(isoDate.year())
            }
            return .success(fields) // Step 6
        }

        let calendarDateResult = JSC.TemporalCore.isoToCalendarFields(calendarId, isoDate)
        if !calendarDateResult.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(calendarDateResult)))
        }
        let calendarDate: JSC.TemporalCore.CalendarFields = JSC.temporalValueOf(calendarDateResult)

        // Step 3: Set fields.[[MonthCode]] to calendarDate.[[MonthCode]].
        if !calendarDate.monthCode.isEmpty() {
            if let parsed = TemporalISO8601.parseMonthCode(calendarDate.monthCode) {
                fields.monthCode = .init(parsed)
            } else {
                fields.monthCode = .init()
            }
        }
        // Step 4: If type is either ~month-day~ or ~date~, set fields.[[Day]] to calendarDate.[[Day]].
        if type == .MonthDay || type == .Date {
            fields.day = .init(calendarDate.day)
        }
        // Step 5: If type is either ~year-month~ or ~date~, set fields.[[Year]] to calendarDate.[[Year]].
        if type == .YearMonth || type == .Date {
            fields.year = .init(calendarDate.year)
        }
        // Step 6: Return fields.
        return .success(fields)
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-calendarfieldkeyspresent
    fileprivate static func calendarFieldKeysPresent(_ fields: JSC.TemporalCore.CalendarFieldsIn) -> TemporalCalendarFieldKeys {
        var keys: TemporalCalendarFieldKeys = .none
        if Optional(fromCxx: fields.era) != nil {
            keys.insert(.era)
        }
        if Optional(fromCxx: fields.eraYear) != nil {
            keys.insert(.eraYear)
        }
        if Optional(fromCxx: fields.year) != nil {
            keys.insert(.year)
        }
        if Optional(fromCxx: fields.month) != nil {
            keys.insert(.month)
        }
        if Optional(fromCxx: fields.monthCode) != nil {
            keys.insert(.monthCode)
        }
        if Optional(fromCxx: fields.day) != nil {
            keys.insert(.day)
        }
        return keys
    }

    // https://tc39.es/proposal-intl-era-monthcode/#sup-temporal-nonisofieldkeystoignore
    fileprivate static func nonISOFieldKeysToIgnore(
        _ calendarId: JSC.CalendarID,
        _ keys: TemporalCalendarFieldKeys
    ) -> TemporalCalendarFieldKeys {
        // Step 1: Let ignoredKeys be a copy of keys — "a field always invalidates at least itself".
        var ignoredKeys = keys
        // Steps 2.a-2.b: month and monthCode are two encodings of the same field.
        if keys.contains(.month) {
            ignoredKeys.insert(.monthCode)
        }
        if keys.contains(.monthCode) {
            ignoredKeys.insert(.month)
        }
        // Step 2.c: era+eraYear and year are two encodings of the same year, so changing either
        //   encoding invalidates the other.
        if JSC.TemporalCore.calendarHasEras(calendarId) && keys.containsAny(.era | .eraYear | .year) {
            ignoredKeys.insert(.era | .eraYear | .year)
        }
        // Step 2.d: with mid-year eras a day/month move can cross an era boundary without changing the
        //   arithmetic year, so drop the era pair but keep year.
        if JSC.TemporalCore.calendarHasMidYearEras(calendarId) && keys.containsAny(.day | .month | .monthCode) {
            ignoredKeys.insert(.era | .eraYear)
        }
        // Step 4: Return ignoredKeys.
        return ignoredKeys
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-calendarfieldkeystoignore
    fileprivate static func calendarFieldKeysToIgnore(
        _ calendarId: JSC.CalendarID,
        _ keys: TemporalCalendarFieldKeys
    ) -> TemporalCalendarFieldKeys {
        // Step 1: If calendar is "iso8601" — only the month/monthCode pairing applies.
        if JSC.TemporalCore.calendarIsISO(calendarId) {
            var ignoredKeys = keys // Steps 1.a-1.b.i
            if keys.contains(.month) { // Step 1.b.ii
                ignoredKeys.insert(.monthCode)
            }
            if keys.contains(.monthCode) { // Step 1.b.iii
                ignoredKeys.insert(.month)
            }
            return ignoredKeys // Step 1.d
        }
        // Step 2: Return NonISOFieldKeysToIgnore(calendar, keys).
        return nonISOFieldKeysToIgnore(calendarId, keys)
    }

    /// Step 5 of CalendarMergeFields for one row: the receiver's field unless the key is
    /// overridden, then the partial's field if present.
    fileprivate static func mergeKey<Field>(
        _ key: TemporalCalendarFieldKeys,
        _ overriddenKeys: TemporalCalendarFieldKeys,
        _ field: Field?,
        _ additionalField: Field?
    ) -> Field? {
        var mergedField: Field?
        // Step 5.b: fieldsKeys contains key and overriddenKeys does not contain key.
        if let field, !overriddenKeys.contains(key) {
            mergedField = field
        }
        // Step 5.c: additionalKeys contains key.
        if let additionalField {
            mergedField = additionalField
        }
        return mergedField
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-calendarmergefields
    static func calendarMergeFields(
        _ calendarId: JSC.CalendarID,
        _ fields: JSC.TemporalCore.CalendarFieldsIn,
        _ additionalFields: JSC.TemporalCore.CalendarFieldsIn
    ) -> JSC.TemporalCore.CalendarFieldsIn {
        // Step 1: Let additionalKeys be CalendarFieldKeysPresent(additionalFields).
        let additionalKeys = calendarFieldKeysPresent(additionalFields)
        // Step 2: Let overriddenKeys be CalendarFieldKeysToIgnore(calendar, additionalKeys).
        let overriddenKeys = calendarFieldKeysToIgnore(calendarId, additionalKeys)
        // Step 3: Let merged be a Calendar Fields Record with all fields set to ~unset~.
        var merged = JSC.TemporalCore.CalendarFieldsIn()
        // Step 4: fieldsKeys is CalendarFieldKeysPresent(fields) — each engaged optional below is its
        //   own membership test, so there is nothing to precompute.
        // Step 5: For each row of the Calendar Fields Record table.
        if let era = mergeKey(.era, overriddenKeys, Optional(fromCxx: fields.era), Optional(fromCxx: additionalFields.era)) {
            merged.era = .init(era)
        }
        if let eraYear = mergeKey(.eraYear, overriddenKeys, Optional(fromCxx: fields.eraYear), Optional(fromCxx: additionalFields.eraYear))
        {
            merged.eraYear = .init(eraYear)
        }
        if let year = mergeKey(.year, overriddenKeys, Optional(fromCxx: fields.year), Optional(fromCxx: additionalFields.year)) {
            merged.year = .init(year)
        }
        if let month = mergeKey(.month, overriddenKeys, Optional(fromCxx: fields.month), Optional(fromCxx: additionalFields.month)) {
            merged.month = .init(month)
        }
        if let monthCode = mergeKey(
            .monthCode,
            overriddenKeys,
            Optional(fromCxx: fields.monthCode),
            Optional(fromCxx: additionalFields.monthCode)
        ) {
            merged.monthCode = .init(monthCode)
        }
        if let day = mergeKey(.day, overriddenKeys, Optional(fromCxx: fields.day), Optional(fromCxx: additionalFields.day)) {
            merged.day = .init(day)
        }
        // Step 6: Return merged.
        return merged
    }

    // plainYearMonthWith — temporal_rs: PlainYearMonth::with (src/builtins/core/plain_year_month.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype.with
    // Implements steps 5, 7 and 10; IsPartialTemporalObject and PrepareCalendarFields done by JS-layer caller.
    static func plainYearMonthWith(
        _ calendarId: JSC.CalendarID,
        _ currentISODate: JSC.ISO8601.PlainDate,
        _ partialFields: JSC.TemporalCore.CalendarFieldsIn,
        _ overflow: JSC.TemporalOverflow
    ) -> TemporalOutcome<JSC.TemporalCore.ResolvedCalendarDate> {
        let fieldsResult = isoDateToFields(calendarId, currentISODate, .YearMonth)
        guard case .success(let fields) = fieldsResult else {
            return .failure(temporalValue(fieldsResult.failure))
        }
        return yearMonthFromFields(calendarId, calendarMergeFields(calendarId, fields, partialFields), overflow)
    }

    // plainDateWith — temporal_rs: PlainDate::with (src/builtins/core/plain_date.rs)
    //   merge: CalendarFields::with_fallback_date (src/builtins/core/calendar/fields.rs)
    //   resolve: Calendar::date_from_fields → dateFromFields
    // https://tc39.es/proposal-temporal/#sec-temporal.plaindate.prototype.with
    // Implements steps 5 (ISODateToFields), 7 (CalendarMergeFields), 10 (CalendarDateFromFields).
    // Steps 6, 8-9 (PrepareCalendarFields, overflow) done by PlainDate::with(); step 11 (CreateTemporalDate) by prototype caller.
    static func plainDateWith(
        _ calendarId: JSC.CalendarID,
        _ currentISODate: JSC.ISO8601.PlainDate,
        _ partialFields: JSC.TemporalCore.CalendarFieldsIn,
        _ overflow: JSC.TemporalOverflow
    ) -> TemporalOutcome<JSC.TemporalCore.ResolvedCalendarDate> {
        let fieldsResult = isoDateToFields(calendarId, currentISODate, .Date)
        guard case .success(let fields) = fieldsResult else {
            return .failure(temporalValue(fieldsResult.failure))
        }
        return dateFromFields(calendarId, calendarMergeFields(calendarId, fields, partialFields), overflow)
    }

    // plainMonthDayWith — temporal_rs: PlainMonthDay::with (src/builtins/core/plain_month_day.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal.plainmonthday.prototype.with
    // Implements steps 5, 7 and 10 (CalendarMonthDayFromFields).
    static func plainMonthDayWith(
        _ calendarId: JSC.CalendarID,
        _ currentISODate: JSC.ISO8601.PlainDate,
        _ partialFields: JSC.TemporalCore.CalendarFieldsIn,
        _ overflow: JSC.TemporalOverflow
    ) -> TemporalOutcome<JSC.TemporalCore.ResolvedCalendarDate> {
        let fieldsResult = isoDateToFields(calendarId, currentISODate, .MonthDay)
        guard case .success(let fields) = fieldsResult else {
            return .failure(temporalValue(fieldsResult.failure))
        }
        return monthDayFromFields(calendarId, calendarMergeFields(calendarId, fields, partialFields), overflow)
    }

    // differenceYearMonth — temporal_rs: PlainYearMonth::diff (src/builtins/core/plain_year_month.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-differencetemporalplainyearmonth
    // Implements steps 7-14; steps 1-6 and rounding (steps 15-16) done by JS-layer caller.
    static func differenceYearMonth(
        _ calendarId: JSC.CalendarID,
        _ thisISODate: JSC.ISO8601.PlainDate,
        _ otherISODate: JSC.ISO8601.PlainDate,
        _ largestUnit: JSC.TemporalUnit
    ) -> TemporalOutcome<JSC.ISO8601.Duration> {
        let isISO = JSC.TemporalCore.calendarIsISO(calendarId)

        if isISO {
            // Steps 7-8: set [[Day]]=1 on both dates; ISODateWithinLimits check.
            let thisDate = JSC.ISO8601.PlainDate(thisISODate.year(), UInt32(thisISODate.month()), 1)
            let otherDate = JSC.ISO8601.PlainDate(otherISODate.year(), UInt32(otherISODate.month()), 1)
            if abs(WTF.dateToDaysFrom1970(thisDate.year(), Int32(thisDate.month()) - 1, 1)) > 1e8
                || abs(WTF.dateToDaysFrom1970(otherDate.year(), Int32(otherDate.month()) - 1, 1)) > 1e8
            {
                return .failure(.range("date is outside the representable range for Temporal"))
            }
            // Steps 10-14: CalendarDateUntil(thisDate, otherDate, largestUnit).
            let until = JSC.TemporalCore.calendarDateUntil(calendarId, thisDate, otherDate, largestUnit)
            if !until.has_value() {
                return .failure(TemporalFailure(JSC.temporalErrorOf(until)))
            }
            return .success(JSC.temporalValueOf(until))
        }

        // Non-ISO: resolve both to day=1 via dateFromFields (matching temporal_rs).
        // Steps 7-9 for each side: ISODateToFields(calendar, isoDate, ~year-month~); set [[Day]] to 1;
        //   ? CalendarDateFromFields(calendar, fields, ~constrain~).
        let thisFieldsResult = isoDateToFields(calendarId, thisISODate, .YearMonth)
        guard case .success(var thisFields) = thisFieldsResult else {
            return .failure(temporalValue(thisFieldsResult.failure))
        }
        thisFields.day = .init(1)
        let thisResolvedResult = dateFromFields(calendarId, thisFields, .Constrain)
        guard case .success(let thisResolved) = thisResolvedResult else {
            return .failure(temporalValue(thisResolvedResult.failure))
        }

        let otherFieldsResult = isoDateToFields(calendarId, otherISODate, .YearMonth)
        guard case .success(var otherFields) = otherFieldsResult else {
            return .failure(temporalValue(otherFieldsResult.failure))
        }
        otherFields.day = .init(1)
        let otherResolvedResult = dateFromFields(calendarId, otherFields, .Constrain)
        guard case .success(let otherResolved) = otherResolvedResult else {
            return .failure(temporalValue(otherResolvedResult.failure))
        }

        // Steps 10-14: CalendarDateUntil(thisDate, otherDate, largestUnit).
        let until = JSC.TemporalCore.calendarDateUntil(calendarId, thisResolved.isoDate, otherResolved.isoDate, largestUnit)
        if !until.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(until)))
        }
        return .success(JSC.temporalValueOf(until))
    }

    // plainYearMonthAdd — temporal_rs: PlainYearMonth::add_duration (src/builtins/core/plain_year_month.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-adddurationtoyearmonth
    // Implements steps 9-14 (ISODateToFields → CalendarDateFromFields → CalendarDateAdd →
    // ISODateToFields → CalendarYearMonthFromFields). Steps 1-8 (duration prep + calendar lookup)
    // and step 15 (CreateTemporalYearMonth wrap) are done by the JS-layer caller.
    static func plainYearMonthAdd(
        _ calendarId: JSC.CalendarID,
        _ currentISODate: JSC.ISO8601.PlainDate,
        _ duration: JSC.ISO8601.Duration,
        _ overflow: JSC.TemporalOverflow
    ) -> TemporalOutcome<JSC.TemporalCore.ResolvedCalendarDate> {
        // Step 9: Let fields be ISODateToFields(calendar, yearMonth.[[ISODate]], ~year-month~).
        let fieldsResult = isoDateToFields(calendarId, currentISODate, .YearMonth)
        guard case .success(var fields) = fieldsResult else {
            return .failure(temporalValue(fieldsResult.failure))
        }
        // Step 10: Set fields.[[Day]] to 1.
        fields.day = .init(1)

        // Step 11: Let date be ? CalendarDateFromFields(calendar, fields, ~constrain~).
        let dateResult = dateFromFields(calendarId, fields, .Constrain)
        guard case .success(let date) = dateResult else {
            return .failure(temporalValue(dateResult.failure))
        }

        // Step 12: Let addedDate be ? CalendarDateAdd(calendar, date, durationToAdd, overflow).
        //   ISO takes the pure isoDateAdd overload, which handles the extreme boundary years
        //   (±271821) that ICU calendar arithmetic clamps.
        let addedISO =
            JSC.TemporalCore.calendarIsISO(calendarId)
            ? JSC.TemporalCore.calendarDateAdd(date.isoDate, duration, overflow)
            : JSC.TemporalCore.calendarDateAdd(calendarId, date.isoDate, duration, overflow)
        if !addedISO.has_value() {
            return .failure(TemporalFailure(JSC.temporalErrorOf(addedISO)))
        }

        // Step 13: Let addedDateFields be ISODateToFields(calendar, addedDate, ~year-month~).
        let addedFieldsResult = isoDateToFields(calendarId, JSC.temporalValueOf(addedISO), .YearMonth)
        guard case .success(let addedFields) = addedFieldsResult else {
            return .failure(temporalValue(addedFieldsResult.failure))
        }

        // Step 14: Return ? CalendarYearMonthFromFields(calendar, addedDateFields, overflow).
        return yearMonthFromFields(calendarId, addedFields, overflow)
    }

    // plainYearMonthToPlainDate — temporal_rs: PlainYearMonth::to_plain_date (src/builtins/core/plain_year_month.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal.plainyearmonth.prototype.toplaindate
    // Implements steps 5, 7, 8; steps 1-4, 6, 9 done by JS-layer caller.
    static func plainYearMonthToPlainDate(
        _ calendarId: JSC.CalendarID,
        _ pymISODate: JSC.ISO8601.PlainDate,
        _ day: UInt8
    ) -> TemporalOutcome<JSC.TemporalCore.ResolvedCalendarDate> {
        // Step 5: Let fields be ISODateToFields(calendar, plainYearMonth.[[ISODate]], ~year-month~).
        let fieldsResult = isoDateToFields(calendarId, pymISODate, .YearMonth)
        guard case .success(let fields) = fieldsResult else {
            return .failure(temporalValue(fieldsResult.failure))
        }

        // Step 6's PrepareCalendarFields(«~day~») is the caller's; it arrives as `day`.
        var inputFields = JSC.TemporalCore.CalendarFieldsIn()
        inputFields.day = .init(day)

        // Step 7: Let mergedFields be CalendarMergeFields(calendar, fields, inputFields).
        // Step 8: Return ? CalendarDateFromFields(calendar, mergedFields, ~constrain~).
        return dateFromFields(calendarId, calendarMergeFields(calendarId, fields, inputFields), .Constrain)
    }

    // plainYearMonthFromISODate — no 1:1 temporal_rs function; inlined in PlainYearMonth::from_parsed
    // https://tc39.es/proposal-temporal/#sec-temporal-totemporalyearmonth (string parse path)
    // Implements steps 12 and 14; step 11's ISOYearMonthWithinLimits check runs inside
    // yearMonthFromFields (see the guard in that function).
    static func plainYearMonthFromISODate(
        _ calendarId: JSC.CalendarID,
        _ fullISODate: JSC.ISO8601.PlainDate
    ) -> TemporalOutcome<JSC.TemporalCore.ResolvedCalendarDate> {
        // Step 12: Set result to ISODateToFields(calendar, isoDate, ~year-month~).
        let fieldsResult = isoDateToFields(calendarId, fullISODate, .YearMonth)
        guard case .success(let fields) = fieldsResult else {
            return .failure(temporalValue(fieldsResult.failure))
        }
        // Step 14: Return ? CalendarYearMonthFromFields(calendar, result, ~constrain~) — ~constrain~
        //   regardless of overflow, per Step 13's NOTE. yearMonthFromFields stores day=1 itself.
        return yearMonthFromFields(calendarId, fields, .Constrain)
    }

    // https://tc39.es/proposal-temporal/#sec-temporal-totemporalmonthday (string parse path)
    // Implements steps 13 and 15; step 12's ISODateWithinLimits check runs inside monthDayFromFields.
    // Step 10's "iso8601" shortcut is not special-cased: routing it through CalendarMonthDayFromFields
    // reaches the same reference year 1972 without a second code path.
    static func plainMonthDayFromISODate(
        _ calendarId: JSC.CalendarID,
        _ fullISODate: JSC.ISO8601.PlainDate,
        _ overflow: JSC.TemporalOverflow
    ) -> TemporalOutcome<JSC.TemporalCore.ResolvedCalendarDate> {
        // Step 13: Set result to ISODateToFields(calendar, isoDate, ~month-day~).
        let fieldsResult = isoDateToFields(calendarId, fullISODate, .MonthDay)
        guard case .success(let fields) = fieldsResult else {
            return .failure(temporalValue(fieldsResult.failure))
        }
        // Step 15: Return ? CalendarMonthDayFromFields(calendar, result, ~constrain~) — every caller
        //   passes ~constrain~ per Step 14's NOTE.
        return monthDayFromFields(calendarId, fields, overflow)
    }
}

// MARK: - Functions the C++ calls

// Exclusivity of their parameters: see TemporalSupport.swift.

/// `TemporalCore::nonISOResolveFields`: returns the fields as resolved so far, which `nonISOResolveFields` stores in
/// the caller's fields whether or not a step failed.
@_expose(Cxx)
func temporalNonISOResolveFields(
    _ calendarId: UInt32,
    _ fields: consuming JSC.TemporalCore.CalendarFieldsIn,
    _ type: JSC.TemporalCore.ResolveType
) -> JSC.TemporalCore.TemporalCalendarFieldsOutcome {
    let failure = TemporalOperations.nonISOResolveFields(calendarId, &fields, type).failure
    return temporalCalendarFieldsOutcome(fields, failure)
}

/// `TemporalCore::dateFromFields`.
@_expose(Cxx)
func temporalDateFromFields(
    _ calendarId: UInt32,
    _ fields: consuming JSC.TemporalCore.CalendarFieldsIn,
    _ overflow: JSC.TemporalOverflow,
    _ value: inout JSC.TemporalCore.ResolvedCalendarDate,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.dateFromFields(calendarId, fields, overflow).store(&value, &kind)
}

/// `TemporalCore::yearMonthFromFields`.
@_expose(Cxx)
func temporalYearMonthFromFields(
    _ calendarId: UInt32,
    _ fields: consuming JSC.TemporalCore.CalendarFieldsIn,
    _ overflow: JSC.TemporalOverflow,
    _ value: inout JSC.TemporalCore.ResolvedCalendarDate,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.yearMonthFromFields(calendarId, fields, overflow).store(&value, &kind)
}

/// `TemporalCore::monthDayFromFields`.
@_expose(Cxx)
func temporalMonthDayFromFields(
    _ calendarId: UInt32,
    _ fields: consuming JSC.TemporalCore.CalendarFieldsIn,
    _ overflow: JSC.TemporalOverflow,
    _ value: inout JSC.TemporalCore.ResolvedCalendarDate,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.monthDayFromFields(calendarId, fields, overflow).store(&value, &kind)
}

/// `TemporalCore::isoDateToFields`.
@_expose(Cxx)
func temporalIsoDateToFields(
    _ calendarId: UInt32,
    _ isoDate: JSC.ISO8601.PlainDate,
    _ type: JSC.TemporalCore.ResolveType
) -> JSC.TemporalCore.TemporalCalendarFieldsOutcome {
    switch TemporalOperations.isoDateToFields(calendarId, isoDate, type) {
    case .success(let fields):
        temporalCalendarFieldsOutcome(fields, nil)
    case .failure(let failure):
        temporalCalendarFieldsOutcome(JSC.TemporalCore.CalendarFieldsIn(), failure)
    }
}

/// `TemporalCore::calendarMergeFields`.
@_expose(Cxx)
func temporalCalendarMergeFields(
    _ calendarId: UInt32,
    _ fields: consuming JSC.TemporalCore.CalendarFieldsIn,
    _ additionalFields: consuming JSC.TemporalCore.CalendarFieldsIn
) -> JSC.TemporalCore.CalendarFieldsIn {
    TemporalOperations.calendarMergeFields(calendarId, fields, additionalFields)
}

/// `TemporalCore::plainYearMonthWith`.
@_expose(Cxx)
func temporalPlainYearMonthWith(
    _ calendarId: UInt32,
    _ currentISODate: JSC.ISO8601.PlainDate,
    _ partialFields: consuming JSC.TemporalCore.CalendarFieldsIn,
    _ overflow: JSC.TemporalOverflow,
    _ value: inout JSC.TemporalCore.ResolvedCalendarDate,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.plainYearMonthWith(calendarId, currentISODate, partialFields, overflow).store(&value, &kind)
}

/// `TemporalCore::plainDateWith`.
@_expose(Cxx)
func temporalPlainDateWith(
    _ calendarId: UInt32,
    _ currentISODate: JSC.ISO8601.PlainDate,
    _ partialFields: consuming JSC.TemporalCore.CalendarFieldsIn,
    _ overflow: JSC.TemporalOverflow,
    _ value: inout JSC.TemporalCore.ResolvedCalendarDate,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.plainDateWith(calendarId, currentISODate, partialFields, overflow).store(&value, &kind)
}

/// `TemporalCore::plainMonthDayWith`.
@_expose(Cxx)
func temporalPlainMonthDayWith(
    _ calendarId: UInt32,
    _ currentISODate: JSC.ISO8601.PlainDate,
    _ partialFields: consuming JSC.TemporalCore.CalendarFieldsIn,
    _ overflow: JSC.TemporalOverflow,
    _ value: inout JSC.TemporalCore.ResolvedCalendarDate,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.plainMonthDayWith(calendarId, currentISODate, partialFields, overflow).store(&value, &kind)
}

/// `TemporalCore::differenceYearMonth`.
@_expose(Cxx)
func temporalDifferenceYearMonth(
    _ calendarId: UInt32,
    _ thisISODate: JSC.ISO8601.PlainDate,
    _ otherISODate: JSC.ISO8601.PlainDate,
    _ largestUnit: JSC.TemporalUnit,
    _ value: inout JSC.ISO8601.Duration,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.differenceYearMonth(calendarId, thisISODate, otherISODate, largestUnit).store(&value, &kind)
}

/// `TemporalCore::plainYearMonthAdd`.
@_expose(Cxx)
func temporalPlainYearMonthAdd(
    _ calendarId: UInt32,
    _ currentISODate: JSC.ISO8601.PlainDate,
    _ duration: JSC.ISO8601.Duration,
    _ overflow: JSC.TemporalOverflow,
    _ value: inout JSC.TemporalCore.ResolvedCalendarDate,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.plainYearMonthAdd(calendarId, currentISODate, duration, overflow).store(&value, &kind)
}

/// `TemporalCore::plainYearMonthToPlainDate`.
@_expose(Cxx)
func temporalPlainYearMonthToPlainDate(
    _ calendarId: UInt32,
    _ pymISODate: JSC.ISO8601.PlainDate,
    _ day: UInt8,
    _ value: inout JSC.TemporalCore.ResolvedCalendarDate,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.plainYearMonthToPlainDate(calendarId, pymISODate, day).store(&value, &kind)
}

/// `TemporalCore::plainYearMonthFromISODate`.
@_expose(Cxx)
func temporalPlainYearMonthFromISODate(
    _ calendarId: UInt32,
    _ fullISODate: JSC.ISO8601.PlainDate,
    _ value: inout JSC.TemporalCore.ResolvedCalendarDate,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.plainYearMonthFromISODate(calendarId, fullISODate).store(&value, &kind)
}

/// `TemporalCore::plainMonthDayFromISODate`.
@_expose(Cxx)
func temporalPlainMonthDayFromISODate(
    _ calendarId: UInt32,
    _ fullISODate: JSC.ISO8601.PlainDate,
    _ overflow: JSC.TemporalOverflow,
    _ value: inout JSC.TemporalCore.ResolvedCalendarDate,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.plainMonthDayFromISODate(calendarId, fullISODate, overflow).store(&value, &kind)
}
