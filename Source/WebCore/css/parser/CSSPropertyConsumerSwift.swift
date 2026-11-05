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

// Without these, no operator in this file type-checks: WebCore's C++ operators name types these modules define.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch

internal import WebCore_Private.Core.CSSCalcSwiftTypes
internal import WebCore_Private.Core.CSSParserToken
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftTypes
internal import WebCore_Private.Core.CSSParserIdioms

// The property consumers (CSSPropertyParserConsumer+*.cpp and the generated CSSPropertyParsing.cpp): the value's
// tokens, the numeric primitives, and calc() through calc()'s parser (CSSCalcParser.swift).

// MARK: - Entry points

/// Consumes a value from the tokens of `value` with the consumer of the CSSPropertyID `consumer`, or the generated one
/// numbered `consumer` from cssPropertyIDEnumValueCount, gives it to `value.setResult`, and returns how many tokens it
/// consumed.
/// `parserMode` is the CSSParserMode and `numericFlags` the CSSNumericConsumerSwift bits.
///
/// consumePropertyWithSwift makes the state of `value` on its stack for this call only, with the CSSGradientSwiftStops
/// and the std::optional it points to. No C++ function Swift calls keeps a reference to the tokens or the state, or
/// reaches the state other than through what Swift passes it:
/// - every consumer: the state's members, CSS::toAngleUnit, CSS::toTimeUnit, CSS::toFlexUnit, CSS::toResolutionUnit,
///   CSS::toCSSUnitType, isValidCustomIdentifier, the CSSValue factories, CSSValueListBuilder, appendKeywordForSwift
///   and CSSColorSwiftComponents::parseCalc. Only `identifier` writes a token, its CSSValueID cache, as
///   CSSParserToken::id() does.
/// - CSSPropertyConsumerSwiftValues.swift: setUnresolvedResult, which writes only the caller's std::optional;
///   beginGradientStops, appendGradientStop and setPendingColor, which write only the CSSGradientSwiftStops;
///   colorKeywordForSwift, colorContextForSwift, colorSwiftChannel, the CSS:: color constructors and the color, image,
///   filter, border and position builders; consumeURLRaw and consumeColorInterpolationMethodForSwift, which read a
///   range of the tokens.
/// - CSSPropertyConsumerSwiftAlignment.swift and CSSPropertyConsumerSwiftSmall.swift: consumerContextForSwift, which
///   reads only the context; currentPropertyForSwift; isTimelineRangeNameForSwift; valueForPositionArea;
///   setParamFunctionResult (CSSCustomPropertySyntax::consumeType,
///   CSSSubstitutionParser::containsSubstitutionFunctions, CSSVariableData::create); counterStyleIntegerForSwift,
///   consumeCounterStyleSymbolForSwift and the counter style, content, quotes, text-shadow and keyframe builders
///   (isPredefinedCounterStyle, consumeSpecificUnresolvedIdent, Style::deprecatedToStyleFromCSSValue); and
///   consumeCalcSizeSumForSwift and makeCalcSizeValue, which add <calc-sum>s to the CSSGradientSwiftStops and take
///   them.
/// - CSSPropertyConsumerSwiftEffects.swift: appendLinearEasingStop and setEasingFunctionResult, and beginFilterValues,
///   appendFilterFunction, appendDropShadowFilter, appendFilterURL (consumeURLRaw) and makeFilterValue, which write
///   and take only the CSSGradientSwiftStops.
/// - CSSPropertyConsumerSwiftFonts.swift: isGenericFontFamilyForSwift (genericFontFamily), isObliqueAngleForSwift, the
///   state's CSSValuePool, AngleValidator, fromCSSValueID<FontTechnology>, consumeURLRaw,
///   consumeColorInterpolationMethodForSwift and the font builders.
/// - CSSPropertyConsumerSwiftGrid.swift: CSS::addRow, MetaConsumer for an <integer> or <flex> calc(),
///   Style::GridPosition::max(), CSSGridAutoFlowValue::create and the grid builders.
/// - CSSPropertyConsumerSwiftShapes.swift: buildSVGPathByteStreamFromString, makeURLValue (consumeURL) and the basic
///   shape, clip, mask-border and ray() builders.
/// A url() with a param() modifier, and the image of the generated consumeSymbol, are consumed through
/// cssConsumeProperty again, each with a state of its own.
@_expose(Cxx)
func cssConsumeProperty(
    _ value: borrowing WebCore.CSSPropertyConsumerSwiftValue,
    _ consumer: UInt16,
    _ parserMode: UInt8,
    _ numericFlags: UInt8
) -> WebCore.CSSPropertyConsumerSwiftResult {
    var propertyParser = PropertyParser(value, parserMode: parserMode, numericFlags: numericFlags)
    let parsed = propertyParser.consume(consumer) { arguments, function, calc in
        // Both at most the token count, an Int from a UInt32.
        let argumentsStart = UInt32(truncatingIfNeeded: arguments.lowerBound)
        let argumentsEnd = UInt32(truncatingIfNeeded: arguments.upperBound)
        return value.parseCalc(argumentsStart, argumentsEnd, function, calc.category.rawValue, calc.flags, calc.min, calc.max).get()
    }
    // At most the token count, an Int from a UInt32.
    let consumedTokens = UInt32(truncatingIfNeeded: propertyParser.index)
    guard let parsed else {
        return WebCore.CSSPropertyConsumerSwiftResult(consumedTokens: consumedTokens, ok: 0)
    }
    value.setResult(parsed)
    return WebCore.CSSPropertyConsumerSwiftResult(consumedTokens: consumedTokens, ok: 1)
}

/// `cssConsumeProperty` for a generated consumer, numbered `consumer` from cssPropertyIDEnumValueCount, that takes no
/// state: one that consumes only keywords and strings and so reads no parser mode, numeric flags or calc().
///
/// The stateless consumePropertyWithSwift makes `value` on its stack for this call only, over a default state that
/// every call shares and that Swift has no member to reach. Swift calls the members of `value`, the CSSValue
/// factories, appendKeywordForSwift and CSSValueListBuilder, none of which reach it; only `identifier` writes a
/// token, its CSSValueID cache.
@_expose(Cxx)
func cssConsumeStatelessProperty(
    _ value: borrowing WebCore.CSSPropertyConsumerSwiftValue,
    _ consumer: UInt16
) -> WebCore.CSSPropertyConsumerSwiftResult {
    var propertyParser = PropertyParser(value, parserMode: WebCore.HTMLStandardMode.rawValue, numericFlags: 0)
    let parsed = propertyParser.consumeGeneratedStateless(consumer)
    // At most the token count, an Int from a UInt32.
    let consumedTokens = UInt32(truncatingIfNeeded: propertyParser.index)
    guard let parsed else {
        return WebCore.CSSPropertyConsumerSwiftResult(consumedTokens: consumedTokens, ok: 0)
    }
    value.setResult(parsed)
    return WebCore.CSSPropertyConsumerSwiftResult(consumedTokens: consumedTokens, ok: 1)
}

/// calc()'s parser on the arguments [argumentsStart, argumentsEnd) of the math function `function` in the tokens of
/// `value`, read onto the stack up to 64 tokens. parseCalc makes `parser`, `resolver` and `calcOutput` on its stack for
/// this call only; Swift calls their CSSCalcSwiftTypes.h members and those of `value`, and a nested parseCalc makes
/// states of its own.
@_expose(Cxx)
func cssConsumePropertyCalc(
    _ value: borrowing WebCore.CSSPropertyConsumerSwiftValue,
    _ parser: inout WebCore.CSSCalcSwiftParser,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    _ calcOutput: inout WebCore.CSSCalcSwiftOutput,
    _ argumentsStart: UInt32,
    _ argumentsEnd: UInt32,
    _ function: UInt16,
    _ category: UInt8,
    _ flags: UInt32
) -> WebCore.CSSCalcSwiftParseResult {
    // UnevaluatedCalcBase::parseBase: no conversion data, no symbols.
    let simplification = WebCore.CSSCalcSwiftSimplificationOptions(
        category: category,
        hasConversionData: 0,
        allowZeroValueLengthRemovalFromSum: 0
    )
    let options = CalcParseOptions(category: category, function: function, flags: flags, simplification: simplification)
    let start = Int(argumentsStart)
    // parseCalc checks that the arguments end after they start.
    let count = Int(argumentsEnd) - start
    if count <= 64 {
        var tokenBuffer = [64 of WebCore.CSSCalcSwiftToken](repeating: WebCore.CSSCalcSwiftToken())
        var calcTokens = tokenBuffer.mutableSpan
        for i in 0..<count {
            calcTokens[i] = calcToken(value, start + i)
        }
        return cssCalcParseArguments(calcTokens.span.extracting(0..<count), &parser, &resolver, &calcOutput, options)
    }
    var calcTokens = UniqueArray<WebCore.CSSCalcSwiftToken>(capacity: count)
    for i in 0..<count {
        calcTokens.append(calcToken(value, start + i))
    }
    return cssCalcParseArguments(calcTokens.span, &parser, &resolver, &calcOutput, options)
}

/// Token `index` of `tokens` as calc()'s parser reads it: `CSSCalcSwiftParser::fillTokens`.
@inline(always)
private func calcToken(_ tokens: borrowing WebCore.CSSPropertyConsumerSwiftValue, _ index: Int) -> WebCore.CSSCalcSwiftToken {
    let type = tokens.type(index)
    let id = type == PropertyTokenType.delimiter ? tokens.delimiter(index) : tokens.identifier(index)
    return WebCore.CSSCalcSwiftToken(
        type: type,
        blockType: tokens.blockType(index),
        id: id,
        unit: UInt32(tokens.unitType(index)),
        numericValue: tokens.numericValue(index)
    )
}

/// A numeric token of a numeric primitive whose range is `[rangeMin, rangeMax]`, with the CSS::RangeParseTimeBehavior
/// `minBehavior` and `maxBehavior`: the validator, the parse-time clamp and the range check of the primitive's
/// family. `packed` holds the unit (the primitive's UnitType) and, in bit 8, whether it was accepted.
@c
@implementation
public func cssConsumeNumericSwift(
    _ value: Double,
    _ rangeMin: Double,
    _ rangeMax: Double,
    _ category: UInt8,
    _ tokenType: UInt8,
    _ unitType: UInt8,
    _ parserMode: UInt8,
    _ minBehavior: UInt8,
    _ maxBehavior: UInt8,
    _ flags: UInt8
) -> WebCore.CSSNumericConsumerSwiftResult {
    let rejected = WebCore.CSSNumericConsumerSwiftResult(value: 0, packed: 0)
    let unit: UInt8
    switch (category, tokenType) {
    case (NumericCategory.length, PropertyTokenType.dimension), (NumericCategory.lengthPercentage, PropertyTokenType.dimension),
        (NumericCategory.length, PropertyTokenType.number), (NumericCategory.lengthPercentage, PropertyTokenType.number):
        // A LengthPercentageUnit's length cases are the LengthUnit's, in order, as LengthPercentageValidator casts them.
        guard let length = lengthUnit(tokenType, unitType, value, parserMode, flags) else {
            return rejected
        }
        unit = lengthUnitRawValue(length)
    case (NumericCategory.lengthPercentage, PropertyTokenType.percentage):
        unit = WebCore.CSS.LengthPercentageUnit.Percentage.rawValue
    case (NumericCategory.number, PropertyTokenType.number), (NumericCategory.percentage, PropertyTokenType.percentage):
        // NumberUnit and PercentageUnit have one case each, 0.
        unit = 0
    case (NumericCategory.integer, PropertyTokenType.number):
        // IntegerUnit has one case, 0. NumberConsumerForIntegerValues has checked that the token's value is an integer.
        unit = 0
    case (NumericCategory.time, PropertyTokenType.dimension):
        // TimeValidator, whose range check compares the value in seconds.
        guard let time = timeUnit(unitType) else {
            return rejected
        }
        let range = NumericRange(min: rangeMin, max: rangeMax, minBehavior: minBehavior, maxBehavior: maxBehavior)
        let clamped = range.clamp(value, resolvesToFloat: flags & UInt8(WebCore.CSSNumericConsumerSwiftResolvesToFloat) != 0)
        guard range.containsTime(clamped, inMilliseconds: time == .Ms) else {
            return rejected
        }
        return WebCore.CSSNumericConsumerSwiftResult(value: clamped, packed: UInt32(time.rawValue) | 0x100)
    default:
        // MetaConsumer never hands a primitive a token its ConsumerDefinition has no consumer for.
        return rejected
    }
    let range = NumericRange(min: rangeMin, max: rangeMax, minBehavior: minBehavior, maxBehavior: maxBehavior)
    let clamped = range.clamp(value, resolvesToFloat: flags & UInt8(WebCore.CSSNumericConsumerSwiftResolvesToFloat) != 0)
    guard range.contains(clamped) else {
        return rejected
    }
    return WebCore.CSSNumericConsumerSwiftResult(value: clamped, packed: UInt32(unit) | 0x100)
}

// MARK: - Numeric tokens

enum PropertyTokenType {
    static var ident: UInt8 { UInt8(WebCore.IdentToken.rawValue) }
    static var function: UInt8 { UInt8(WebCore.FunctionToken.rawValue) }
    static var number: UInt8 { UInt8(WebCore.NumberToken.rawValue) }
    static var percentage: UInt8 { UInt8(WebCore.PercentageToken.rawValue) }
    static var dimension: UInt8 { UInt8(WebCore.DimensionToken.rawValue) }
    static var comma: UInt8 { UInt8(WebCore.CommaToken.rawValue) }
    static var delimiter: UInt8 { UInt8(WebCore.DelimiterToken.rawValue) }
    static var eof: UInt8 { UInt8(WebCore.EOFToken.rawValue) }
    static var string: UInt8 { UInt8(WebCore.StringToken.rawValue) }

    /// `CSSTokenizer::isWhitespace`.
    static func isWhitespace(_ type: UInt8) -> Bool {
        type == UInt8(WebCore.NonNewlineWhitespaceToken.rawValue) || type == UInt8(WebCore.NewlineToken.rawValue)
    }

    static var blockStart: UInt8 { UInt8(WebCore.CSSParserToken.BlockStart.rawValue) }
    static var blockEnd: UInt8 { UInt8(WebCore.CSSParserToken.BlockEnd.rawValue) }
}

private enum NumericCategory {
    static var number: UInt8 { WebCore.CSS.Category.Number.rawValue }
    static var percentage: UInt8 { WebCore.CSS.Category.Percentage.rawValue }
    static var length: UInt8 { WebCore.CSS.Category.Length.rawValue }
    static var lengthPercentage: UInt8 { WebCore.CSS.Category.LengthPercentage.rawValue }
    static var integer: UInt8 { WebCore.CSS.Category.Integer.rawValue }
    static var time: UInt8 { WebCore.CSS.Category.Time.rawValue }
}

private func hasFlag(_ flags: UInt8, _ flag: UInt8) -> Bool {
    flags & flag != 0
}

/// `LengthValidator::validate` for a dimension token, `LengthValidator::shouldAcceptUnitlessValue` for a number token:
/// the CSSUnitType of the LengthUnit, which for a dimension token is its own (CSSCalcTree+Parser.cpp checks that
/// `CSS::toCSSUnitType` of `CSS::toLengthUnit` is the identity). The quirky-length bit of `flags` is the caller's, for
/// the mode `parserMode`.
@inline(always)
private func lengthUnit(_ tokenType: UInt8, _ unitType: UInt8, _ value: Double, _ parserMode: UInt8, _ flags: UInt8) -> WebCore.CSSUnitType?
{
    guard tokenType == PropertyTokenType.dimension else {
        if value == 0 && hasFlag(flags, UInt8(WebCore.CSSNumericConsumerSwiftUnitlessZeroLength)) {
            return .Px
        }
        if parserMode == WebCore.SVGAttributeMode.rawValue || hasFlag(flags, UInt8(WebCore.CSSNumericConsumerSwiftQuirkyLength)) {
            return .Px
        }
        return nil
    }
    // The CSSUnitTypes CSS::toLengthUnit accepts, bit n of word n / 64 for unit n, and below those of them whose
    // conversion to the canonical unit needs no conversion data. CSSCalcTree+Parser.cpp checks both masks.
    guard isUnit(unitType, 0xfdc1_ffff_fff8_0ff0, 0x23) else {
        return nil
    }
    if unitType == WebCore.CSSUnitType.QuirkyEm.rawValue && parserMode != WebCore.UASheetMode.rawValue {
        return nil
    }
    if hasFlag(flags, UInt8(WebCore.CSSNumericConsumerSwiftAbsoluteLengthUnitsOnly))
        && !isUnit(unitType, 0x40_0000_0000_0fc0, 0)
    {
        return nil
    }
    // Never nil: an imported C++ enum's init(rawValue:) does not check its value.
    return WebCore.CSSUnitType(rawValue: unitType) ?? .Unknown
}

/// Whether bit `unit` of the 128-bit mask `word0`, `word1` is set. `&>>` shifts by `unit % 64`.
@inline(always)
private func isUnit(_ unit: UInt8, _ word0: UInt64, _ word1: UInt64) -> Bool {
    unit < 128 && ((unit < 64 ? word0 : word1) &>> unit) & 1 != 0
}

/// `CSS::toLengthUnit` of a unit `lengthUnit` accepts, as its raw value.
@inline(always)
private func lengthUnitRawValue(_ unit: WebCore.CSSUnitType) -> UInt8 {
    switch unit {
    case .Px: WebCore.CSS.LengthUnit.Px.rawValue
    case .Cm: WebCore.CSS.LengthUnit.Cm.rawValue
    case .Mm: WebCore.CSS.LengthUnit.Mm.rawValue
    case .Q: WebCore.CSS.LengthUnit.Q.rawValue
    case .In: WebCore.CSS.LengthUnit.In.rawValue
    case .Pt: WebCore.CSS.LengthUnit.Pt.rawValue
    case .Pc: WebCore.CSS.LengthUnit.Pc.rawValue
    case .Em: WebCore.CSS.LengthUnit.Em.rawValue
    case .QuirkyEm: WebCore.CSS.LengthUnit.QuirkyEm.rawValue
    case .Ex: WebCore.CSS.LengthUnit.Ex.rawValue
    case .Lh: WebCore.CSS.LengthUnit.Lh.rawValue
    case .Cap: WebCore.CSS.LengthUnit.Cap.rawValue
    case .Ch: WebCore.CSS.LengthUnit.Ch.rawValue
    case .Ic: WebCore.CSS.LengthUnit.Ic.rawValue
    case .Rcap: WebCore.CSS.LengthUnit.Rcap.rawValue
    case .Rch: WebCore.CSS.LengthUnit.Rch.rawValue
    case .Rem: WebCore.CSS.LengthUnit.Rem.rawValue
    case .Rex: WebCore.CSS.LengthUnit.Rex.rawValue
    case .Ric: WebCore.CSS.LengthUnit.Ric.rawValue
    case .Rlh: WebCore.CSS.LengthUnit.Rlh.rawValue
    case .Vw: WebCore.CSS.LengthUnit.Vw.rawValue
    case .Vh: WebCore.CSS.LengthUnit.Vh.rawValue
    case .Vmin: WebCore.CSS.LengthUnit.Vmin.rawValue
    case .Vmax: WebCore.CSS.LengthUnit.Vmax.rawValue
    case .Vb: WebCore.CSS.LengthUnit.Vb.rawValue
    case .Vi: WebCore.CSS.LengthUnit.Vi.rawValue
    case .Svw: WebCore.CSS.LengthUnit.Svw.rawValue
    case .Svh: WebCore.CSS.LengthUnit.Svh.rawValue
    case .Svmin: WebCore.CSS.LengthUnit.Svmin.rawValue
    case .Svmax: WebCore.CSS.LengthUnit.Svmax.rawValue
    case .Svb: WebCore.CSS.LengthUnit.Svb.rawValue
    case .Svi: WebCore.CSS.LengthUnit.Svi.rawValue
    case .Lvw: WebCore.CSS.LengthUnit.Lvw.rawValue
    case .Lvh: WebCore.CSS.LengthUnit.Lvh.rawValue
    case .Lvmin: WebCore.CSS.LengthUnit.Lvmin.rawValue
    case .Lvmax: WebCore.CSS.LengthUnit.Lvmax.rawValue
    case .Lvb: WebCore.CSS.LengthUnit.Lvb.rawValue
    case .Lvi: WebCore.CSS.LengthUnit.Lvi.rawValue
    case .Dvw: WebCore.CSS.LengthUnit.Dvw.rawValue
    case .Dvh: WebCore.CSS.LengthUnit.Dvh.rawValue
    case .Dvmin: WebCore.CSS.LengthUnit.Dvmin.rawValue
    case .Dvmax: WebCore.CSS.LengthUnit.Dvmax.rawValue
    case .Dvb: WebCore.CSS.LengthUnit.Dvb.rawValue
    case .Dvi: WebCore.CSS.LengthUnit.Dvi.rawValue
    case .Cqw: WebCore.CSS.LengthUnit.Cqw.rawValue
    case .Cqh: WebCore.CSS.LengthUnit.Cqh.rawValue
    case .Cqi: WebCore.CSS.LengthUnit.Cqi.rawValue
    case .Cqb: WebCore.CSS.LengthUnit.Cqb.rawValue
    case .Cqmin: WebCore.CSS.LengthUnit.Cqmin.rawValue
    case .Cqmax: WebCore.CSS.LengthUnit.Cqmax.rawValue
    default:
        // Not a length unit, which the caller's RELEASE_ASSERT on the unit stops at.
        UInt8.max
    }
}

/// `AngleValidator::validate` for a dimension token, `AngleValidator::shouldAcceptUnitlessValue` for a number token.
@inline(always)
func angleUnit(
    _ tokenType: UInt8,
    _ unitType: UInt8,
    _ value: Double,
    _ parserMode: UInt8,
    _ flags: UInt8,
    allowsUnitlessZero: Bool
) -> WebCore.CSSUnitType? {
    guard tokenType == PropertyTokenType.dimension else {
        if value == 0 && allowsUnitlessZero {
            return .Deg
        }
        if parserMode == WebCore.SVGAttributeMode.rawValue || hasFlag(flags, UInt8(WebCore.CSSNumericConsumerSwiftQuirkyAngle)) {
            return .Deg
        }
        return nil
    }
    guard let cssUnit = WebCore.CSSUnitType(rawValue: unitType), let unit = WebCore.CSS.toAngleUnit(cssUnit).value else {
        return nil
    }
    return WebCore.CSS.toCSSUnitType(unit)
}

/// `TimeValidator::validate`: the TimeUnit of a dimension token's unit, s or ms.
@inline(always)
private func timeUnit(_ unitType: UInt8) -> WebCore.CSS.TimeUnit? {
    guard let cssUnit = WebCore.CSSUnitType(rawValue: unitType) else {
        return nil
    }
    return WebCore.CSS.toTimeUnit(cssUnit).value
}

/// A CSS::Range and its parse-time behaviors.
private struct NumericRange {
    let min: Double
    let max: Double
    let minBehavior: UInt8
    let maxBehavior: UInt8

    static var clamp: UInt8 { UInt8(WebCore.CSS.RangeParseTimeBehavior.Clamp.rawValue) }
    static var ignore: UInt8 { UInt8(WebCore.CSS.RangeParseTimeBehavior.Ignore.rawValue) }

    /// `performOptionalParseTimeClamp`: std::clamp, std::max or std::min in the primitive's ResolvedValueType, so a
    /// clamped value is rounded to it and one that is not clamped is not. A double out of float's range rounds to an
    /// infinity, which `contains` then rejects.
    @inline(always)
    func clamp(_ value: Double, resolvesToFloat: Bool) -> Double {
        let clampsMin = minBehavior == Self.clamp
        let clampsMax = maxBehavior == Self.clamp
        guard clampsMin || clampsMax else {
            return value
        }
        func resolved(_ value: Double) -> Double {
            resolvesToFloat ? Double(Float(value)) : value
        }
        var result = resolved(value)
        if clampsMin && result < resolved(min) {
            result = resolved(min)
        }
        if clampsMax && resolved(max) < result {
            result = resolved(max)
        }
        return result
    }

    /// `isValidCanonicalValue`, which is also `isValidNonCanonicalizableDimensionValue` and `isValidDimensionValue`
    /// for the ranges they accept.
    @inline(always)
    func contains(_ value: Double) -> Bool {
        if value.isInfinite {
            return false
        }
        let effectiveMin = minBehavior == Self.ignore ? -Double.infinity : min
        let effectiveMax = maxBehavior == Self.ignore ? Double.infinity : max
        return (effectiveMin == -.infinity || value >= effectiveMin) && (effectiveMax == .infinity || value <= effectiveMax)
    }
}

extension NumericRange {
    /// `TimeValidator::isValid`: `isValidDimensionValue`, which converts to seconds only for a range other than all
    /// values, [0, inf] and [-inf, 0].
    @inline(always)
    func containsTime(_ value: Double, inMilliseconds: Bool) -> Bool {
        if value.isInfinite {
            return false
        }
        let effectiveMin = minBehavior == Self.ignore ? -Double.infinity : min
        let effectiveMax = maxBehavior == Self.ignore ? Double.infinity : max
        if effectiveMin == -.infinity && effectiveMax == .infinity {
            return true
        }
        if effectiveMin == 0 && effectiveMax == .infinity {
            return value >= 0
        }
        if effectiveMin == -.infinity && effectiveMax == 0 {
            return value <= 0
        }
        // CSS::canonicalize's secondsPerMillisecond (CSSUnits.h), which a static_assert in CSSCalcTree+Parser.cpp pins.
        let seconds = inMilliseconds ? value * (1.0 / 1000.0) : value
        return seconds >= min && seconds <= max
    }
}

// MARK: - The parser

/// A value a consumer made.
typealias PropertyValue = WebCore.CSSValue

/// A calc() of a primitive: its category and range, and the CSSCalcParse bits its options set.
struct PropertyCalcPrimitive {
    let category: WebCore.CSS.Category
    let min: Double
    let max: Double
    let flags: UInt32
}

/// Parses the arguments at the indices `arguments` of the math function `function`, and makes its value, or returns nil.
typealias PropertyCalc = (_ arguments: Range<Int>, _ function: UInt16, _ primitive: PropertyCalcPrimitive) -> PropertyValue?

/// A CSSParserTokenRange over the value's tokens `[index, end)`: a read at `end` is an EOF token. The generated
/// consumers (CSSPropertyParsingSwift.swift) and the hand-written ones (CSSPropertyConsumerSwiftProperties.swift) are
/// its methods.
struct PropertyParser: ~Copyable, ~Escapable {
    let tokens: Swift.Ref<WebCore.CSSPropertyConsumerSwiftValue>
    let parserMode: UInt8
    let numericFlags: UInt8
    var index = 0
    var end: Int

    @_lifetime(borrow tokens)
    init(_ tokens: borrowing WebCore.CSSPropertyConsumerSwiftValue, parserMode: UInt8, numericFlags: UInt8) {
        self.tokens = Swift.Ref(tokens)
        self.parserMode = parserMode
        self.numericFlags = numericFlags
        end = tokens.count()
    }

    /// The consumer of the CSSPropertyID `consumer`, the generated one numbered `consumer`, or the
    /// CSSPropertyConsumerSwiftConsumer `consumer`.
    mutating func consume(_ consumer: UInt16, _ calc: PropertyCalc) -> PropertyValue? {
        // consumeValue4's consumers are the last, from AlignContent.
        if consumer >= WebCore.CSSPropertyConsumerSwiftConsumer.AlignContent.rawValue {
            return consumeValue4(consumer, calc)
        }
        if consumer >= WebCore.CSSPropertyConsumerSwiftConsumer.UnresolvedColor.rawValue {
            return consumeValue(consumer, calc)
        }
        if consumer >= WebCore.cssPropertyIDEnumValueCount {
            return consumeGenerated(consumer, calc)
        }
        return consumeHandWritten(consumer, calc)
    }

    // MARK: Tokens

    var atEnd: Bool { index >= end }

    @inline(always)
    func peekType() -> UInt8 {
        atEnd ? PropertyTokenType.eof : tokens.value.type(index)
    }

    /// `peek().id()`: the CSSValueID of an identifier, else Invalid.
    func peekIdent() -> WebCore.CSSValueID {
        peekType() == PropertyTokenType.ident ? valueID(tokens.value.identifier(index)) : .Invalid
    }

    /// `peek().functionId()`.
    func peekFunction() -> WebCore.CSSValueID {
        peekType() == PropertyTokenType.function ? valueID(tokens.value.identifier(index)) : .Invalid
    }

    private func valueID(_ id: UInt16) -> WebCore.CSSValueID {
        // Never nil: an imported C++ enum's init(rawValue:) does not check its value.
        WebCore.CSSValueID(rawValue: id) ?? .Invalid
    }

    @inline(always)
    mutating func consumeWhitespace() {
        while !atEnd && PropertyTokenType.isWhitespace(tokens.value.type(index)) {
            index &+= 1 // Below end, a token count.
        }
    }

    @inline(always)
    mutating func consumeIncludingWhitespace() {
        if !atEnd {
            index &+= 1 // Below end, a token count.
        }
        consumeWhitespace()
    }

    /// Consumes the next token, an identifier, and the whitespace after it, and returns its keyword value.
    mutating func consumeKeyword() -> PropertyValue? {
        let id = peekIdent()
        consumeIncludingWhitespace()
        return keywordValue(id)
    }

    /// `consumeKeyword()` where `id` is the `peekIdent()` already read.
    @inline(always)
    mutating func consumeKeyword(peeked id: WebCore.CSSValueID) -> PropertyValue? {
        consumeIncludingWhitespace()
        return keywordValue(id)
    }

    /// `consumeCommaIncludingWhitespace`.
    mutating func consumeComma() -> Bool {
        guard peekType() == PropertyTokenType.comma else {
            return false
        }
        consumeIncludingWhitespace()
        return true
    }

    // MARK: Functions

    /// Where a function's arguments are, and where the parser was before them.
    struct Function {
        let start: Int
        let end: Int
        let next: Int
    }

    /// If the next token is the function `name`, narrows the parser to its arguments, as `consumeFunction`, and returns
    /// what `endFunction` needs to restore it.
    mutating func beginFunction(_ name: WebCore.CSSValueID) -> Function? {
        guard peekFunction() == name else {
            return nil
        }
        let start = index
        let (arguments, next) = consumeBlock()
        let function = Function(start: start, end: end, next: next)
        index = arguments.lowerBound
        end = arguments.upperBound
        consumeWhitespace()
        return function
    }

    /// Consumes the function `function` came from, and the whitespace after it, if `value` is its value and all its
    /// arguments are consumed; consumes nothing otherwise.
    mutating func endFunction(_ function: Function, _ value: PropertyValue?) -> PropertyValue? {
        let consumedAll = atEnd
        end = function.end
        guard let value, consumedAll else {
            index = function.start
            return nil
        }
        index = function.next
        consumeWhitespace()
        return value
    }

    /// `CSSParserTokenRange::consumeBlock` at a token that starts a block: its contents, and the index after it, without
    /// consuming it. A block left open runs to `end`.
    private func consumeBlock() -> (contents: Range<Int>, next: Int) {
        var nestingLevel = 0
        var i = index
        repeat {
            let blockType = tokens.value.blockType(i)
            i &+= 1 // At most end, a token count.
            if blockType == PropertyTokenType.blockStart {
                nestingLevel &+= 1 // Between 0 and the tokens read.
            } else if blockType == PropertyTokenType.blockEnd {
                nestingLevel &-= 1 // Between 0 and the tokens read.
            }
        } while nestingLevel != 0 && i < end
        // index is below end, and i above index.
        return (index &+ 1..<(nestingLevel != 0 ? i : i &- 1), i)
    }

    // MARK: Numeric primitives

    /// `CSSPrimitiveValueResolver<primitive>::consumeAndResolve`, or `consumePercentageDividedBy100OrNumber`.
    mutating func primitive(_ primitive: PropertyPrimitive, _ calc: PropertyCalc) -> PropertyValue? {
        numeric(primitive, calc)?.value
    }

    /// As `primitive`, with the value's number and unit, which a calc() does not have.
    mutating func numeric(_ primitive: PropertyPrimitive, _ calc: PropertyCalc) -> PropertyNumeric? {
        let type = peekType()
        return type == PropertyTokenType.function ? calcNumeric(primitive, calc) : tokenNumeric(type, primitive)
    }

    /// `primitive`, inlined into the caller so that the primitive's kind and options are constants there: for the
    /// hand-written consumers.
    @inline(always)
    mutating func inlinePrimitive(_ primitive: PropertyPrimitive, _ calc: PropertyCalc) -> PropertyValue? {
        inlineNumeric(primitive, calc)?.value
    }

    /// `numeric`, inlined into the caller.
    @inline(always)
    mutating func inlineNumeric(_ primitive: PropertyPrimitive, _ calc: PropertyCalc) -> PropertyNumeric? {
        let type = peekType()
        return type == PropertyTokenType.function ? calcNumeric(primitive, calc) : tokenNumeric(type, primitive)
    }

    /// Whether the next token is a number token.
    @inline(always)
    func peekIsNumber() -> Bool {
        peekType() == PropertyTokenType.number
    }

    /// `numeric` for the next token, of type `type`, which is not a function token.
    @inline(always)
    private mutating func tokenNumeric(_ type: UInt8, _ primitive: PropertyPrimitive) -> PropertyNumeric? {
        guard type == PropertyTokenType.number || type == PropertyTokenType.percentage || type == PropertyTokenType.dimension else {
            return nil
        }
        var value = tokens.value.numericValue(index)
        let unit: WebCore.CSSUnitType
        switch primitive.kind {
        case .number:
            guard type == PropertyTokenType.number else {
                return nil
            }
            unit = .Number
        case .numberOrPercentageResolvedToNumber:
            // A <percentage> is a <number> of a hundredth of its value.
            guard type != PropertyTokenType.dimension, primitive.contains(value) else {
                return nil
            }
            if type == PropertyTokenType.percentage {
                value = value / 100.0
            }
            unit = .Number
        case .length, .lengthPercentage:
            if type == PropertyTokenType.percentage {
                guard primitive.kind == .lengthPercentage else {
                    return nil
                }
                unit = .Percentage
            } else {
                guard let length = lengthUnit(type, tokens.value.unitType(index), value, parserMode(primitive), numericFlags(primitive))
                else {
                    return nil
                }
                unit = length
            }
        case .integer:
            // NumberConsumerForIntegerValues: a number token whose value is an integer.
            guard type == PropertyTokenType.number, tokens.value.isIntegerNumber(index) else {
                return nil
            }
            unit = .Integer
        case .percentage:
            guard type == PropertyTokenType.percentage else {
                return nil
            }
            unit = .Percentage
        case .time:
            guard type == PropertyTokenType.dimension, let time = timeUnit(tokens.value.unitType(index)) else {
                return nil
            }
            unit = WebCore.CSS.toCSSUnitType(time)
        case .angle:
            guard type != PropertyTokenType.percentage,
                let angle = angleUnit(
                    type,
                    tokens.value.unitType(index),
                    value,
                    parserMode,
                    numericFlags,
                    allowsUnitlessZero: primitive.allowUnitlessZeroAngle
                )
            else {
                return nil
            }
            unit = angle
        }
        if primitive.kind != .numberOrPercentageResolvedToNumber {
            guard primitive.contains(value) else {
                return nil
            }
        }
        consumeIncludingWhitespace()
        let created: PropertyValue = WebCore.CSSPrimitiveValue.create(value, unit).get()
        return PropertyNumeric(value: created, number: value, unit: unit, isCalculated: false)
    }

    /// The mode a primitive's tokens are read in: `overrideParserMode`, or the context's.
    private func parserMode(_ primitive: PropertyPrimitive) -> UInt8 {
        primitive.standardMode ? WebCore.HTMLStandardMode.rawValue : parserMode
    }

    /// The CSSNumericConsumerSwift bits for a primitive's tokens: the quirky bits hold only in the context's mode.
    private func numericFlags(_ primitive: PropertyPrimitive) -> UInt8 {
        var flags = numericFlags
        if primitive.standardMode {
            flags &= ~(UInt8(WebCore.CSSNumericConsumerSwiftQuirkyLength) | UInt8(WebCore.CSSNumericConsumerSwiftQuirkyAngle))
        }
        if !primitive.forbidUnitlessZeroLength {
            flags |= UInt8(WebCore.CSSNumericConsumerSwiftUnitlessZeroLength)
        }
        return flags
    }

    /// `FunctionConsumerForCalcValues`: a math function at the next token, which is a function token, parsed for the
    /// primitive's category; for `<number-or-percentage-resolved-to-number>`, for <number> and then for <percentage>.
    @inline(never)
    private mutating func calcNumeric(_ primitive: PropertyPrimitive, _ calc: PropertyCalc) -> PropertyNumeric? {
        let function = tokens.value.identifier(index)
        guard cssCalcIsMathFunction(function) else {
            return nil
        }
        // consumeFunction.
        let (block, next) = consumeBlock()
        var arguments = block.lowerBound
        while arguments < block.upperBound && PropertyTokenType.isWhitespace(tokens.value.type(arguments)) {
            arguments += 1
        }
        let flags =
            (primitive.allowAnchor ? UInt32(WebCore.CSSCalcParseAllowAnchor) : 0)
            | (primitive.allowAnchorSize ? UInt32(WebCore.CSSCalcParseAllowAnchorSize) : 0)
            | (primitive.forbidUnitlessZeroLength ? 0 : UInt32(WebCore.CSSCalcParseAllowUnitlessZeroLength))
        var value = calc(
            arguments..<block.upperBound,
            function,
            PropertyCalcPrimitive(category: primitive.category, min: primitive.min, max: primitive.max, flags: flags)
        )
        if value == nil && primitive.kind == .numberOrPercentageResolvedToNumber {
            value = calc(
                arguments..<block.upperBound,
                function,
                PropertyCalcPrimitive(category: .Percentage, min: primitive.min, max: primitive.max, flags: flags)
            )
        }
        guard let value else {
            return nil
        }
        index = next
        consumeWhitespace()
        return PropertyNumeric(value: value, number: 0, unit: .Unknown, isCalculated: true)
    }

    // MARK: Values

    func keywordValue(_ id: WebCore.CSSValueID) -> PropertyValue {
        WebCore.CSSKeywordValue.create(id).get()
    }

    /// The CSSFunctionValue `name` of the arguments.
    func makeFunction(_ name: WebCore.CSSValueID) -> PropertyValue? {
        WebCore.CSSFunctionValue.create(name).get()
    }

    func makeFunction(_ name: WebCore.CSSValueID, _ a0: PropertyValue) -> PropertyValue? {
        WebCore.CSSFunctionValue.create(name, consuming: PropertyValueRef(a0)).get()
    }

    func makeFunction(_ name: WebCore.CSSValueID, _ a0: PropertyValue, _ a1: PropertyValue) -> PropertyValue? {
        WebCore.CSSFunctionValue.create(name, consuming: PropertyValueRef(a0), consuming: PropertyValueRef(a1)).get()
    }

    func makeFunction(_ name: WebCore.CSSValueID, _ a0: PropertyValue, _ a1: PropertyValue, _ a2: PropertyValue) -> PropertyValue? {
        WebCore.CSSFunctionValue
            .create(name, consuming: PropertyValueRef(a0), consuming: PropertyValueRef(a1), consuming: PropertyValueRef(a2)).get()
    }

    func makeFunction(
        _ name: WebCore.CSSValueID,
        _ a0: PropertyValue,
        _ a1: PropertyValue,
        _ a2: PropertyValue,
        _ a3: PropertyValue
    ) -> PropertyValue? {
        WebCore.CSSFunctionValue
            .create(
                name,
                consuming: PropertyValueRef(a0),
                consuming: PropertyValueRef(a1),
                consuming: PropertyValueRef(a2),
                consuming: PropertyValueRef(a3)
            )
            .get()
    }

    func makeFunction(_ name: WebCore.CSSValueID, _ arguments: consuming PropertyValueList) -> PropertyValue? {
        WebCore.CSSFunctionValue.create(name, arguments.take()).get()
    }

    func makeSpaceSeparatedList(_ items: consuming PropertyValueList) -> PropertyValue? {
        WebCore.CSSValueList.createSpaceSeparated(items.take()).get()
    }

    func makeCommaSeparatedList(_ items: consuming PropertyValueList) -> PropertyValue? {
        WebCore.CSSValueList.createCommaSeparated(items.take()).get()
    }

    func makeTransformList(_ items: consuming PropertyValueList) -> PropertyValue? {
        WebCore.CSSTransformListValue.create(items.take()).get()
    }

    /// The CSSValueList of up to four values.
    func makeSpaceSeparatedList(_ a0: PropertyValue) -> PropertyValue {
        WebCore.CSSValueList.createSpaceSeparated(PropertyValueRef(a0)).get()
    }

    func makeSpaceSeparatedList(_ a0: PropertyValue, _ a1: PropertyValue) -> PropertyValue {
        WebCore.CSSValueList.createSpaceSeparated(PropertyValueRef(a0), PropertyValueRef(a1)).get()
    }

    func makeSpaceSeparatedList(_ a0: PropertyValue, _ a1: PropertyValue, _ a2: PropertyValue) -> PropertyValue {
        WebCore.CSSValueList.createSpaceSeparated(PropertyValueRef(a0), PropertyValueRef(a1), PropertyValueRef(a2)).get()
    }

    func makeSpaceSeparatedList(_ a0: PropertyValue, _ a1: PropertyValue, _ a2: PropertyValue, _ a3: PropertyValue) -> PropertyValue {
        WebCore.CSSValueList.createSpaceSeparated(PropertyValueRef(a0), PropertyValueRef(a1), PropertyValueRef(a2), PropertyValueRef(a3))
            .get()
    }

    func makePair(_ first: PropertyValue, _ second: PropertyValue, coalescing: Bool) -> PropertyValue {
        if coalescing {
            return WebCore.CSSValuePair.create(PropertyValueRef(first), PropertyValueRef(second)).get()
        }
        return WebCore.CSSValuePair.createNoncoalescing(PropertyValueRef(first), PropertyValueRef(second)).get()
    }
}

typealias PropertyValueRef = WebCore.CSSValueListBuilder.ValueType

/// The items of a list or of a function's arguments: a CSSValueListBuilder.
struct PropertyValueList: ~Copyable {
    private var builder = WebCore.CSSValueListBuilder()

    mutating func append(_ value: PropertyValue) {
        builder.append(consuming: PropertyValueRef(value))
    }

    /// Appends the keyword value of `id`.
    mutating func appendKeyword(_ id: WebCore.CSSValueID) {
        WebCore.appendKeywordForSwift(&builder, id)
    }

    consuming func take() -> WebCore.CSSValueListBuilder {
        builder
    }
}

/// A primitive a consumer read, and for one that is not a calc(), its number and unit: `CSSPrimitiveValue::raw()`.
struct PropertyNumeric {
    let value: PropertyValue
    let number: Double
    let unit: WebCore.CSSUnitType
    let isCalculated: Bool

    /// `isZero() == true`, `isZero() == false` and `isNegative() == true`.
    var isKnownZero: Bool { !isCalculated && number == 0 }
    var isKnownNonzero: Bool { !isCalculated && number != 0 }
    var isKnownNegative: Bool { !isCalculated && number < 0 }
}

/// A numeric primitive a grammar names, with its range and the options of its `CSSPrimitiveValueResolver`.
struct PropertyPrimitive {
    enum Kind {
        case number
        case numberOrPercentageResolvedToNumber
        case length
        case lengthPercentage
        case angle
        case integer
        case percentage
        /// A range of all values or the non-negative ones, which `contains` checks as `TimeValidator` does.
        case time
    }

    let kind: Kind
    let min: Double
    let max: Double
    let forbidUnitlessZeroLength: Bool
    let allowAnchor: Bool
    let allowAnchorSize: Bool
    let allowUnitlessZeroAngle: Bool
    /// `.overrideParserMode = HTMLStandardMode`.
    let standardMode: Bool

    init(
        _ kind: Kind,
        min: Double = -.infinity,
        max: Double = .infinity,
        forbidUnitlessZeroLength: Bool = false,
        allowAnchor: Bool = false,
        allowAnchorSize: Bool = false,
        allowUnitlessZeroAngle: Bool = false,
        standardMode: Bool = false
    ) {
        self.kind = kind
        self.min = min
        self.max = max
        self.forbidUnitlessZeroLength = forbidUnitlessZeroLength
        self.allowAnchor = allowAnchor
        self.allowAnchorSize = allowAnchorSize
        self.allowUnitlessZeroAngle = allowUnitlessZeroAngle
        self.standardMode = standardMode
    }

    var category: WebCore.CSS.Category {
        switch kind {
        case .number, .numberOrPercentageResolvedToNumber: .Number
        case .length: .Length
        case .lengthPercentage: .LengthPercentage
        case .angle: .Angle
        case .integer: .Integer
        case .percentage: .Percentage
        case .time: .Time
        }
    }

    /// The range check of the primitive's validator, whose range parse-time behaviors are the defaults.
    func contains(_ value: Double) -> Bool {
        let behavior = UInt8(WebCore.CSS.RangeParseTimeBehavior.Default.rawValue)
        return NumericRange(min: min, max: max, minBehavior: behavior, maxBehavior: behavior).contains(value)
    }
}

// MARK: - Strings and identifiers

extension PropertyParser {
    /// `consumeString`.
    mutating func stringValue() -> PropertyValue? {
        guard peekType() == PropertyTokenType.string else {
            return nil
        }
        let value = tokens.value.tokenValue(index).get()
        consumeIncludingWhitespace()
        return value
    }

    /// `consumeCustomIdent`: an identifier other than the CSS-wide keywords and `default`.
    mutating func customIdent() -> PropertyValue? {
        guard peekType() == PropertyTokenType.ident, WebCore.isValidCustomIdentifier(peekIdent()) else {
            return nil
        }
        let value = tokens.value.tokenValue(index).get()
        consumeIncludingWhitespace()
        return value
    }

    /// `consumeDashedIdent`: an identifier that starts with two dashes.
    mutating func dashedIdent() -> PropertyValue? {
        guard peekType() == PropertyTokenType.ident, tokens.value.isDashedIdent(index) else {
            return nil
        }
        let value = tokens.value.tokenValue(index).get()
        consumeIncludingWhitespace()
        return value
    }
}
