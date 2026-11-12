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

internal import JSCSwiftBoundary

// JSC Temporal Core — Rounding algorithms
// temporal_rs reference: src/rounding.rs
//                        src/options.rs
//                        src/options/increment.rs
// Last synced: v0.2.3

extension TemporalOperations {
    // NegateRoundingMode — temporal_rs: RoundingMode::negate (src/options.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-negateroundingmode
    static func negateTemporalRoundingMode(_ roundingMode: JSC.RoundingMode) -> JSC.RoundingMode {
        switch roundingMode {
        case .Ceil:
            return .Floor
        case .Floor:
            return .Ceil
        case .HalfCeil:
            return .HalfFloor
        case .HalfFloor:
            return .HalfCeil
        default:
            return roundingMode
        }
    }

    // ApplyUnsignedRoundingMode — temporal_rs: apply_unsigned_rounding_mode
    // https://tc39.es/proposal-temporal/#sec-applyunsignedroundingmode
    // The products and sums wrap on overflow. The callers keep them below
    // maxTimeDuration × increment, about 1e37 < 2^127.
    static func applyUnsignedRoundingMode(
        _ xNumerator: Int128,
        _ xDenominator: Int128,
        _ r1: Int128,
        _ r2: Int128,
        _ unsignedRoundingMode: JSC.UnsignedRoundingMode
    ) -> Int128 {
        assert(xDenominator > 0)
        let scaledR1 = r1 &* xDenominator
        // 1. If x = r1, return r1.
        if xNumerator == scaledR1 {
            return r1
        }
        // 2. Assert: r1 < x < r2. 3. Assert: unsignedRoundingMode is not undefined.
        // 4. If unsignedRoundingMode is ~zero~, return r1.
        if unsignedRoundingMode == .Zero {
            return r1
        }
        // 5. If unsignedRoundingMode is ~infinity~, return r2.
        if unsignedRoundingMode == .Infinity {
            return r2
        }
        // 6-9. d1 = x - r1, d2 = r2 - x; d1 < d2 iff 2x < r1 + r2.
        let doubledX = xNumerator &* 2
        let sumOfBounds = (r1 &+ r2) &* xDenominator
        if doubledX < sumOfBounds {
            return r1
        }
        if doubledX > sumOfBounds {
            return r2
        }
        // 10. Assert: d1 is equal to d2.
        // 11. If unsignedRoundingMode is ~half-zero~, return r1.
        if unsignedRoundingMode == .HalfZero {
            return r1
        }
        // 12. If unsignedRoundingMode is ~half-infinity~, return r2.
        if unsignedRoundingMode == .HalfInfinity {
            return r2
        }
        // 13. Assert: unsignedRoundingMode is ~half-even~.
        assert(unsignedRoundingMode == .HalfEven)
        // 14-16. cardinality = (r1 / (r2 - r1)) modulo 2.
        // r2 - r1 is 1 from every caller.
        return temporalDivideInt128(r1, r2 &- r1).quotient % 2 == 0 ? r1 : r2
    }

    // MaximumTemporalDurationRoundingIncrement — temporal_rs: Unit::to_maximum_rounding_increment (src/options.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-maximumtemporaldurationroundingincrement
    static func maximumRoundingIncrement(_ unit: JSC.TemporalUnit) -> UInt32? {
        // 1. Return the value from the "Maximum duration rounding increment" column of #table-temporal-units.
        // Year/Month/Week/Day have no maximum (return ~unset~); time units return fixed values.
        if unit.rawValue <= JSC.TemporalUnit.Day.rawValue {
            return nil
        }
        if unit == .Hour {
            return 24
        }
        if unit.rawValue <= JSC.TemporalUnit.Second.rawValue {
            return 60
        }
        return 1000
    }

    // RoundNumberToIncrement (double path) — temporal_rs: IncrementRounder<f64>::round (src/rounding.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-roundnumbertoincrement
    // NOTE: Stays signed throughout rather than abs+negate like temporal_rs/spec.
    // truncatedQuotient = -r1 (negative) or r1 (positive); expandedQuotient = -r2 or r2.
    // Produces identical results to IncrementRounder<f64>::round.
    static func roundNumberToIncrementDouble(_ x: Double, _ increment: Double, _ mode: JSC.RoundingMode) -> Double {
        // quotient = x / increment (spec step 1).
        let quotient = x / increment
        let truncatedQuotient = quotient.rounded(.towardZero)
        if truncatedQuotient == quotient {
            return truncatedQuotient * increment
        }

        let isNegative = quotient < 0
        // expandedQuotient = r2 (positive) or r1 (negative) in spec terms.
        let expandedQuotient = isNegative ? truncatedQuotient - 1 : truncatedQuotient + 1

        if mode.rawValue >= JSC.RoundingMode.HalfCeil.rawValue {
            let unsignedFractionalPart = abs(quotient - truncatedQuotient)
            if unsignedFractionalPart < 0.5 {
                return truncatedQuotient * increment
            }
            if unsignedFractionalPart > 0.5 {
                return expandedQuotient * increment
            }
        }

        switch mode {
        case .Ceil, .HalfCeil:
            return (isNegative ? truncatedQuotient : expandedQuotient) * increment
        case .Floor, .HalfFloor:
            return (isNegative ? expandedQuotient : truncatedQuotient) * increment
        case .Expand, .HalfExpand:
            return expandedQuotient * increment
        case .Trunc, .HalfTrunc:
            return truncatedQuotient * increment
        case .HalfEven:
            return (truncatedQuotient.truncatingRemainder(dividingBy: 2) == 0 ? truncatedQuotient : expandedQuotient) * increment
        default:
            fatalError()
        }
    }

    // RoundNumberToIncrementAsIfPositive — temporal_rs: IncrementRounder::round_as_if_positive (src/rounding.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-roundnumbertoincrementasifpositive
    static func roundNumberToIncrementAsIfPositive(_ x: Int128, _ increment: Int128, _ roundingMode: JSC.RoundingMode) -> Int128 {
        // 1. Let quotient be x / increment.
        // Callers validate increment >= 1; an increment of 0 gives 0, as arm64's division by zero does.
        let (quotient, remainder) = temporalDivideInt128(x, increment)
        // Exact case: x is divisible by increment — return x directly before computing r1/r2.
        // (spec step 1 of ApplyUnsignedRoundingMode: "if x = r1, return r1")
        if remainder == 0 {
            return x
        }
        // 2. Let unsignedRoundingMode be GetUnsignedRoundingMode(roundingMode, ~positive~).
        let unsignedRoundingMode = JSC.getUnsignedRoundingMode(roundingMode, false)
        // 3. Let r1 be the largest integer such that r1 ≤ quotient.
        // 4. Let r2 be the smallest integer such that r2 > quotient.
        // The `&±` cannot overflow: a nonzero remainder means |increment| >= 2 or increment is 0, so |quotient| <= Int128.max / 2.
        var r1 = quotient
        var r2 = quotient &+ 1
        if x < 0 {
            r1 = quotient &- 1
            r2 = quotient
        }
        // 5. Let rounded be ApplyUnsignedRoundingMode(quotient, r1, r2, unsignedRoundingMode).
        // 6. Return rounded × increment.
        // Wraps on overflow; callers keep it below about 1e37.
        return applyUnsignedRoundingMode(x, increment, r1, r2, unsignedRoundingMode) &* increment
    }

    // RoundNumberToIncrement (Int128 path) — temporal_rs: IncrementRounder<i128>::round (src/rounding.rs)
    // https://tc39.es/proposal-temporal/#sec-temporal-roundnumbertoincrement
    static func roundNumberToIncrementInt128(_ x: Int128, _ increment: Int128, _ mode: JSC.RoundingMode) -> Int128 {
        // 1. Let quotient be x / increment.
        // Callers validate increment >= 1; an increment of 0 gives 0, as arm64's division by zero does.
        let (quotient, remainder) = temporalDivideInt128(x, increment)
        if remainder == 0 {
            return x
        }
        // 2-3. Determine isNegative from x; work with abs(quotient) as unsigned quotient.
        let isNegative = x < 0
        // 4. Let unsignedRoundingMode be GetUnsignedRoundingMode(roundingMode, isNegative).
        let unsignedRoundingMode = JSC.getUnsignedRoundingMode(mode, isNegative)
        // 5. Let r1 be the largest integer such that r1 ≤ abs(quotient).
        let r1 = temporalAbsInt128(quotient)
        // 6. Let r2 be the smallest integer such that r2 > abs(quotient).
        let r2 = r1 &+ 1 // Cannot overflow: a nonzero remainder means |increment| >= 2 or increment is 0, so r1 <= Int128.max / 2.
        // 7. Let rounded be ApplyUnsignedRoundingMode(abs(quotient), r1, r2, unsignedRoundingMode).
        var rounded = applyUnsignedRoundingMode(temporalAbsInt128(x), increment, r1, r2, unsignedRoundingMode)
        // 8. If isNegative is ~negative~, set rounded to -rounded.
        if isNegative {
            rounded = 0 &- rounded // Cannot overflow: rounded is r1 or r2, both in [0, Int128.max / 2 + 1].
        }
        // 9. Return rounded × increment.
        // Wraps on overflow; callers keep it below about 1e37.
        return rounded &* increment
    }

    // ValidateTemporalRoundingIncrement — temporal_rs: RoundingIncrement::validate (src/options/increment.rs)
    // https://tc39.es/proposal-temporal/#sec-validatetemporalroundingincrement
    // NOTE: dividend is optional here; callers pass nullopt when largestUnit ≤ Day (no maximum applies).
    // In that case we use nsPerSecond as a safe upper bound (largest valid nanosecond increment).
    static func validateTemporalRoundingIncrement(
        _ increment: Double,
        _ dividend: Double?,
        _ isInclusive: JSC.Inclusivity
    ) -> TemporalOutcome<Void> {
        // 1. If inclusive is true, then a. Let maximum be dividend.
        // 2. Else, b. Let maximum be dividend - 1.
        let maximum: Double
        if let dividend {
            if isInclusive == .Inclusive {
                maximum = dividend
            } else if dividend > 1 {
                maximum = dividend - 1
            } else {
                maximum = 1
            }
        } else {
            maximum = temporalDouble(JSC.lengthInNanoseconds(.Second))
        }

        let increment = increment.rounded(.towardZero)
        // 3. If increment > maximum, throw a RangeError exception.
        if increment < 1 || increment > maximum {
            return .failure(.range("rounding increment is out of range"))
        }
        // 4. If dividend modulo increment ≠ 0, throw a RangeError exception.
        // (A NaN remainder counts as nonzero.)
        if let dividend, dividend.truncatingRemainder(dividingBy: increment) != 0 {
            return .failure(.range("roundingIncrement does not divide evenly"))
        }
        // 5. Return ~unused~.
        return .success(())
    }
}

// MARK: - Implementations of C++ declarations
//
// Each is the definition of the `JS_EXPORT_PRIVATE` declaration it names, under its C++ symbol: `public`, so that
// JavaScriptCore exports it, with the C++ type names spelled out. Every parameter is a value.

extension JSC.TemporalCore {
    /// `TemporalCore::negateTemporalRoundingMode`.
    @cxx
    @implementation
    public static func negateTemporalRoundingMode(_ roundingMode: JSC.RoundingMode) -> JSC.RoundingMode {
        TemporalOperations.negateTemporalRoundingMode(roundingMode)
    }

    /// `TemporalCore::applyUnsignedRoundingMode`.
    @cxx
    @implementation
    public static func applyUnsignedRoundingMode(
        _ xNumerator: Int128,
        _ xDenominator: Int128,
        _ r1: Int128,
        _ r2: Int128,
        _ unsignedRoundingMode: JSC.UnsignedRoundingMode
    ) -> Int128 {
        TemporalOperations.applyUnsignedRoundingMode(xNumerator, xDenominator, r1, r2, unsignedRoundingMode)
    }

    /// `TemporalCore::maximumRoundingIncrement`.
    @cxx
    @implementation
    public static func maximumRoundingIncrement(_ unit: JSC.TemporalUnit) -> JSC.TemporalOptionalUnsigned {
        guard let value = TemporalOperations.maximumRoundingIncrement(unit) else {
            return JSC.TemporalOptionalUnsigned()
        }
        return JSC.TemporalOptionalUnsigned(value)
    }

    /// `TemporalCore::roundNumberToIncrementDouble`.
    @cxx
    @implementation
    public static func roundNumberToIncrementDouble(_ x: Double, _ increment: Double, _ mode: JSC.RoundingMode) -> Double {
        TemporalOperations.roundNumberToIncrementDouble(x, increment, mode)
    }

    /// `TemporalCore::roundNumberToIncrementAsIfPositive`.
    @cxx
    @implementation
    public static func roundNumberToIncrementAsIfPositive(_ x: Int128, _ increment: Int128, _ roundingMode: JSC.RoundingMode) -> Int128 {
        TemporalOperations.roundNumberToIncrementAsIfPositive(x, increment, roundingMode)
    }

    /// `TemporalCore::roundNumberToIncrementInt128`.
    @cxx
    @implementation
    public static func roundNumberToIncrementInt128(_ x: Int128, _ increment: Int128, _ mode: JSC.RoundingMode) -> Int128 {
        TemporalOperations.roundNumberToIncrementInt128(x, increment, mode)
    }
}

// MARK: - Functions the C++ calls

// Exclusivity of their parameters: see TemporalSupport.swift.

/// `TemporalCore::validateTemporalRoundingIncrement`.
@_expose(Cxx)
func temporalValidateTemporalRoundingIncrement(
    _ increment: Double,
    _ dividend: consuming JSC.TemporalOptionalDouble,
    _ isInclusive: JSC.Inclusivity,
    _ kind: inout JSC.TemporalErrorKind
) -> WTF.String {
    TemporalOperations.validateTemporalRoundingIncrement(increment, dividend.value, isInclusive).store(&kind)
}
