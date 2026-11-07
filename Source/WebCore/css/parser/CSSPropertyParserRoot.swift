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

// The property parser's root: CSSPropertyParser::parseValue's choice of consumer by rule type, and the style property
// consumer, which adds a CSS-wide keyword to the property or to every longhand of a shorthand, parses the shorthand or
// the longhand, and otherwise adds a substitution value if the tokens contain var(), env() or attr(). The shorthand and
// longhand dispatch is generated (CSSPropertyParsingSwift.swift); the descriptor consumers are in
// CSSPropertyParserDescriptors.swift.

#if USE_SWIFT_CSS_SHORTHANDS_AND_TYPED_OM

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
internal import WebCore_Private.Core.CSSProperty
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftTypes

/// CSSPropertyParser::parseValue's consumers on the declaration's tokens in `value`, without the whitespace at either
/// end, for the CSSPropertyID `property` in a rule of the StyleRuleType `ruleType`: false if the declaration is invalid. The
/// properties go to `sink`; parseValue removes what was added when this returns false.
///
/// parseValue makes `value` and `sink` on its stack for this call only, over its own CSS::PropertyParserState,
/// CSS::PropertyParserResult and CSSGradientSwiftStops. While they are live, Swift calls only:
/// - `value`'s members: parseWithCxx, parseCalc, isExposed, setResult, tokenValue and the token accessors (type,
///   blockType, unitType, delimiter, identifier, identEquals, isIntegerNumber, isDashedIdent);
/// - `sink`'s members: addLonghand, addAllLonghands, addProperty, addSubstitutionValue, isKeywordValid;
/// - addBorderImageLonghandsForSwift, valueIDForSwift, isTimelineRangeNameForSwift, isCSSWideKeyword,
///   makeMaskBorderLonghandValue, setGridResult, setGridLineResult, CSSKeywordValue::implicitInitialValue, the
///   CSSProperty predicates (isSizingProperty, isMarginProperty, isInsetProperty, acceptsQuirkyLength,
///   acceptsQuirkyAngle) and the CSSValue factories (CSSPrimitiveValue::create, CSSValueList::createCommaSeparated,
///   CSSPositionXValue::create, CSSPositionYValue::create, CSSGridAutoFlowValue::create);
/// - the C++ helpers of the Swift consumers (consumerContextForSwift, colorContextForSwift,
///   colorKeywordForSwift, appendKeywordForSwift, consumeColorInterpolationMethodForSwift, consumeCalcSizeSumForSwift,
///   consumeCounterStyleSymbolForSwift, counterStyleIntegerForSwift, currentPropertyForSwift,
///   isGenericFontFamilyForSwift, isObliqueAngleForSwift);
/// - through parseWithCxx, CSSPropertyParsing::parseStylePropertyLonghand, consumeRuleForSwift and
///   parseDescriptorForSwift.
/// None of them reaches either facade, script or another thread. A C++ consumer that re-enters Swift does so with
/// facades of its own.
@_expose(Cxx)
func cssParsePropertyValue(
    _ value: borrowing WebCore.CSSPropertyConsumerSwiftValue,
    _ sink: borrowing WebCore.CSSPropertyConsumerSwiftShorthandSink,
    _ property: UInt16,
    _ ruleType: UInt8,
    _ important: Bool,
    _ parserMode: UInt8
) -> Bool {
    // Never nil: an imported C++ enum's init(rawValue:) does not check its value.
    let property = WebCore.CSSPropertyID(rawValue: property) ?? .Invalid
    var propertyParser = PropertyParser(value, parserMode: parserMode, numericFlags: quirkyNumericFlags(property, parserMode))
    propertyParser.consumeWhitespace()
    propertyParser.trimTrailingWhitespace()
    let ruleType = WebCore.StyleRuleType(rawValue: ruleType) ?? .Style
    return propertyParser.parseValue(sink, property, ruleType, important) { arguments, function, calc in
        // Both at most the token count, an Int from a UInt32.
        let argumentsStart = UInt32(truncatingIfNeeded: arguments.lowerBound)
        let argumentsEnd = UInt32(truncatingIfNeeded: arguments.upperBound)
        return value.parseCalc(argumentsStart, argumentsEnd, function, calc.category.rawValue, calc.flags, calc.min, calc.max).get()
    }
}

/// CSSNumericConsumerSwiftQuirkyLength and CSSNumericConsumerSwiftQuirkyAngle for `property`: in HTMLQuirksMode, where
/// CSSProperty::acceptsQuirkyLength and CSSProperty::acceptsQuirkyAngle.
func quirkyNumericFlags(_ property: WebCore.CSSPropertyID, _ parserMode: UInt8) -> UInt8 {
    guard parserMode == WebCore.HTMLQuirksMode.rawValue else {
        return 0
    }
    return (WebCore.CSSProperty.acceptsQuirkyLength(property) ? UInt8(WebCore.CSSNumericConsumerSwiftQuirkyLength) : 0)
        | (WebCore.CSSProperty.acceptsQuirkyAngle(property) ? UInt8(WebCore.CSSNumericConsumerSwiftQuirkyAngle) : 0)
}

extension PropertyParser {
    /// `CSSPropertyParser::parseValue` (CSSPropertyParser.cpp): the consumer of the rule type.
    mutating func parseValue(
        _ sink: borrowing ShorthandSink,
        _ property: WebCore.CSSPropertyID,
        _ ruleType: WebCore.StyleRuleType,
        _ important: Bool,
        _ calc: PropertyCalc
    ) -> Bool {
        switch ruleType {
        case .CounterStyle:
            return consumeCounterStyleDescriptor(sink, property, calc)
        case .FontFace:
            return consumeFontFaceDescriptor(sink, property, calc)
        case .FontPaletteValues:
            return consumeFontPaletteValuesDescriptor(sink, property, calc)
        case .Keyframe:
            return consumeKeyframeDescriptor(sink, property, important, calc)
        case .Page:
            return consumePageDescriptor(sink, property, important, calc)
        case .Property:
            return consumePropertyDescriptor(sink, property, calc)
        case .ViewTransition:
            return consumeViewTransitionDescriptor(sink, property, calc)
        case .PositionTry:
            return consumePositionTryDescriptor(sink, property, important, calc)
        case .Function:
            return consumeFunctionDescriptor(sink, property, calc)
        #if ENABLE_SPATIAL_PORTAL
        case .EnvironmentMap:
            return consumeEnvironmentMapDescriptor(sink, property, calc)
        #endif
        default:
            return consumeStyleProperty(sink, property, important, withNamespaceMap: true, calc)
        }
    }

    /// `consumeCSSWideKeywordValue`: a CSS-wide keyword that is the whole value, consumed with the whitespace after it;
    /// otherwise nil, and nothing is consumed.
    mutating func consumeCSSWideKeywordValue() -> PropertyValue? {
        let start = index
        let id = peekIdent()
        consumeIncludingWhitespace()
        guard atEnd, WebCore.isCSSWideKeyword(id) else {
            index = start
            return nil
        }
        return keywordValue(id)
    }

    /// `CSSParserTokenRange::trimTrailingWhitespace`: `end` before the whitespace at the end.
    mutating func trimTrailingWhitespace() {
        while end > index && PropertyTokenType.isWhitespace(tokens.value.type(end - 1)) {
            end -= 1
        }
    }

    /// Whether a token in `tokens` is a function that CSSSubstitutionParser::containsSubstitutionFunctions
    /// takes for a substitution function: var(), env(), inherit(), attr(), random-item(), if(), ident(),
    /// -internal-auto-base(), or a dashed function, whose name is no CSSValueID. Without one, it is false.
    func hasSubstitutionFunctionToken(_ tokens: Range<Int>) -> Bool {
        var i = tokens.lowerBound
        while i < tokens.upperBound {
            if self.tokens.value.type(i) == PropertyTokenType.function {
                switch WebCore.CSSValueID(rawValue: self.tokens.value.identifier(i)) ?? .Invalid {
                case .Var, .Env, .Inherit, .Attr, .RandomItem, .If, .Ident, .InternalAutoBase, .Invalid:
                    return true
                default:
                    break
                }
            }
            i += 1
        }
        return false
    }

    /// The substitution value of `tokens`, if they contain a substitution function.
    func addSubstitutionValue(_ sink: borrowing ShorthandSink, _ tokens: Range<Int>, withNamespaceMap: Bool) -> Bool {
        guard hasSubstitutionFunctionToken(tokens) else {
            return false
        }
        // Both at most the token count, an Int from a UInt32.
        return sink.addSubstitutionValue(
            UInt32(truncatingIfNeeded: tokens.lowerBound),
            UInt32(truncatingIfNeeded: tokens.upperBound),
            withNamespaceMap
        )
    }

    /// `consumeStyleProperty`. The C++ descriptor consumers that fall back to it pass no namespace map, so a
    /// substitution value they add has none (`withNamespaceMap` false).
    mutating func consumeStyleProperty(
        _ sink: borrowing ShorthandSink,
        _ property: WebCore.CSSPropertyID,
        _ important: Bool,
        withNamespaceMap: Bool,
        _ calc: PropertyCalc
    ) -> Bool {
        if Self.isDescriptorOnly(property) {
            return false
        }

        // The declaration's tokens, whatever a consumer leaves of `index` and `end`.
        let declaration = index..<end

        if Self.isShorthand(property) {
            if let keywordValue = consumeCSSWideKeywordValue() {
                sink.addAllLonghands(property.rawValue, keywordValue, false)
                return true
            }

            if parseStylePropertyShorthand(property, sink, calc) {
                return true
            }

            // The tokens from the start, whatever the shorthand consumed.
            if addSubstitutionValue(sink, declaration, withNamespaceMap: withNamespaceMap) {
                return true
            }
        } else {
            if let keywordValue = consumeCSSWideKeywordValue() {
                sink.addProperty(property.rawValue, keywordValue, important)
                return true
            }

            if let parsedValue = parseStylePropertyLonghand(property, calc), atEnd {
                sink.addProperty(property.rawValue, parsedValue, important)
                return true
            }

            if addSubstitutionValue(sink, declaration, withNamespaceMap: withNamespaceMap) {
                return true
            }
        }

        return false
    }

    /// `consumeKeyframeDescriptor`: in a keyframe, every style property but the animation properties
    /// (https://www.w3.org/TR/css-animations-1/#keyframes).
    mutating func consumeKeyframeDescriptor(
        _ sink: borrowing ShorthandSink,
        _ property: WebCore.CSSPropertyID,
        _ important: Bool,
        _ calc: PropertyCalc
    ) -> Bool {
        switch property {
        case .Animation, .AnimationDelay, .AnimationDirection, .AnimationDuration, .AnimationFillMode,
            .AnimationIterationCount, .AnimationName, .AnimationPlayState:
            return false
        default:
            return consumeStyleProperty(sink, property, important, withNamespaceMap: false, calc)
        }
    }

    /// The C++ consumer of the CSSPropertyID `consumer`, or of the GeneratedRule numbered `consumer` from
    /// cssPropertyIDEnumValueCount, on the tokens from `index`; `index` advances by what it consumed, with or without
    /// a value, as the C++ range does.
    private mutating func parseWithCxx(_ consumer: UInt16) -> PropertyValue? {
        var consumed: UInt32 = 0
        // `index` and `end` are at most the token count, a size_t from a UInt32.
        let parsed = tokens.value
            .parseWithCxx(consumer, false, UInt32(truncatingIfNeeded: index), UInt32(truncatingIfNeeded: end), &consumed).get()
        index &+= Int(consumed) // parseWithCxx checks that the range is within the tokens: at most end.
        return parsed
    }

    /// `CSSPropertyParsing::parseStylePropertyLonghand` in C++, for a longhand with no Swift consumer.
    mutating func parseLonghandWithCxx(_ property: WebCore.CSSPropertyID) -> PropertyValue? {
        parseWithCxx(property.rawValue)
    }

    /// The exported C++ consumer `rule` (CSSPropertyParsing::consumeRuleForSwift), for a rule with no Swift consumer.
    mutating func parseRuleWithCxx(_ rule: GeneratedRule) -> PropertyValue? {
        // cssPropertyIDEnumValueCount plus fewer rules than properties: within a UInt16.
        parseWithCxx(WebCore.cssPropertyIDEnumValueCount + rule.rawValue)
    }
}

#endif // USE_SWIFT_CSS_SHORTHANDS_AND_TYPED_OM
