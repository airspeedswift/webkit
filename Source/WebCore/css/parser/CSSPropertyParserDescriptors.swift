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

// The descriptor consumers of CSSPropertyParser.cpp (@font-face, @font-palette-values, @counter-style, @page,
// @property, @view-transition, @environment-map, @position-try, @function), as `PropertyParser` methods that
// CSSPropertyParserRoot.swift's parseValue calls; and consumeCustomPropertyValueWithSyntax, the parse of a value against
// a registered custom property's syntax, with its entry. consumeKeyframeDescriptor and consumeStyleProperty are in
// CSSPropertyParserRoot.swift.
//
// Each consumer requires its value to reach the end before adding it, and adds it with IsImportant::No where the C++
// passes it explicitly. The generated CSSPropertyParsing::parse<Rule>Descriptor stays C++ and is reached through
// parseDescriptorWithCxx.

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
internal import WebCore_Private.Core.CSSCustomPropertySyntax
internal import WebCore_Private.Core.CSSParserToken
internal import WebCore_Private.Core.CSSProperty
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftBuilders
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftTypes

extension PropertyParser {
    // MARK: - The C++ descriptor parsers

    /// The generated `CSSPropertyParsing::parse<Rule>Descriptor` of the rule being parsed, on the tokens from
    /// `index`; `index` advances by what it consumed, with or without a value, as the C++ range does.
    private mutating func parseDescriptorWithCxx(_ property: WebCore.CSSPropertyID) -> PropertyValue? {
        var consumed: UInt32 = 0
        // `index` and `end` are at most the token count, a size_t from a UInt32.
        let parsed = tokens.value
            .parseWithCxx(
                property.rawValue,
                true,
                UInt32(truncatingIfNeeded: index),
                UInt32(truncatingIfNeeded: end),
                &consumed
            )
            .get()
        index &+= Int(consumed) // parseWithCxx checks that the range is within the tokens: at most end.
        return parsed
    }

    /// The body the descriptor consumers that only parse the descriptor share (consumeFontFaceDescriptor and the five
    /// after it, and consumeEnvironmentMapDescriptor and consumeFunctionDescriptor): the rule's descriptor parser,
    /// which must consume every token, and the value added not important.
    private mutating func consumeDescriptor(_ sink: borrowing ShorthandSink, _ property: WebCore.CSSPropertyID) -> Bool {
        guard let parsedValue = parseDescriptorWithCxx(property), atEnd else {
            return false
        }
        sink.addProperty(property.rawValue, parsedValue, false)
        return true
    }

    // MARK: - Descriptors parsed by the rule's descriptor parser alone

    /// `consumeFontFaceDescriptor`.
    mutating func consumeFontFaceDescriptor(
        _ sink: borrowing ShorthandSink,
        _ property: WebCore.CSSPropertyID,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeDescriptor(sink, property)
    }

    /// `consumeFontPaletteValuesDescriptor`.
    mutating func consumeFontPaletteValuesDescriptor(
        _ sink: borrowing ShorthandSink,
        _ property: WebCore.CSSPropertyID,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeDescriptor(sink, property)
    }

    /// `consumeCounterStyleDescriptor`.
    mutating func consumeCounterStyleDescriptor(
        _ sink: borrowing ShorthandSink,
        _ property: WebCore.CSSPropertyID,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeDescriptor(sink, property)
    }

    /// `consumePropertyDescriptor`.
    mutating func consumePropertyDescriptor(
        _ sink: borrowing ShorthandSink,
        _ property: WebCore.CSSPropertyID,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeDescriptor(sink, property)
    }

    /// `consumeViewTransitionDescriptor`.
    mutating func consumeViewTransitionDescriptor(
        _ sink: borrowing ShorthandSink,
        _ property: WebCore.CSSPropertyID,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeDescriptor(sink, property)
    }

    #if ENABLE_SPATIAL_PORTAL
    /// `consumeEnvironmentMapDescriptor`.
    mutating func consumeEnvironmentMapDescriptor(
        _ sink: borrowing ShorthandSink,
        _ property: WebCore.CSSPropertyID,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeDescriptor(sink, property)
    }
    #endif

    /// `consumeFunctionDescriptor`. The C++ asserts the setting in debug builds only, as `assert` does: the `result`
    /// descriptor is exposed exactly when cssFunctionAtRuleEnabled is set (CSSProperties.json's settings-flag).
    mutating func consumeFunctionDescriptor(
        _ sink: borrowing ShorthandSink,
        _ property: WebCore.CSSPropertyID,
        _ calc: PropertyCalc
    ) -> Bool {
        assert(tokens.value.isExposed(WebCore.CSSPropertyID.Result.rawValue))
        return consumeDescriptor(sink, property)
    }

    // MARK: - The descriptors that fall back to style properties

    /// `consumePageDescriptor`: `page` does not apply in @page; the page descriptor, without a `portrait` that is the
    /// default; otherwise, for any property but `size`, the style property, with no namespace map.
    mutating func consumePageDescriptor(
        _ sink: borrowing ShorthandSink,
        _ property: WebCore.CSSPropertyID,
        _ important: Bool,
        _ calc: PropertyCalc
    ) -> Bool {
        if property == .Page {
            return false
        }

        if var parsedValue = parseDescriptorWithCxx(property) {
            if !atEnd {
                return false
            }

            // dynamicDowncast<CSSValuePair>: CSSValuePair's type traits are isPair() (CSSValuePair.h).
            if property == .PageSize && parsedValue.isPair() && WebCore.valueIDForSwift(parsedValue.second()) == .Portrait {
                parsedValue = parsedValue.first()
            }

            sink.addProperty(property.rawValue, parsedValue, false)
            return true
        }

        // Not the width and height shorthand `size` inside @page.
        if property == .PageSize {
            return false
        }

        return consumeStyleProperty(sink, property, important, withNamespaceMap: false, calc)
    }

    /// `propertyAllowedInPositionTryRule`.
    static func propertyAllowedInPositionTryRule(_ property: WebCore.CSSPropertyID) -> Bool {
        WebCore.CSSProperty.isInsetProperty(property)
            || WebCore.CSSProperty.isMarginProperty(property)
            || WebCore.CSSProperty.isSizingProperty(property)
            || property == .AlignSelf
            || property == .JustifySelf
            || property == .PlaceSelf
            || property == .PositionAnchor
            || property == .PositionArea
    }

    /// `consumePositionTryDescriptor`: `!important` makes the declaration invalid; then only the properties
    /// propertyAllowedInPositionTryRule allows, as style properties with no namespace map.
    mutating func consumePositionTryDescriptor(
        _ sink: borrowing ShorthandSink,
        _ property: WebCore.CSSPropertyID,
        _ important: Bool,
        _ calc: PropertyCalc
    ) -> Bool {
        if important {
            return false
        }

        if !Self.propertyAllowedInPositionTryRule(property) {
            return false
        }

        return consumeStyleProperty(sink, property, important, withNamespaceMap: false, calc)
    }
}

// MARK: - Custom property values with a syntax

/// `consumeCustomPropertyValueWithSyntax` on the tokens in `value` against `syntax`, which is not the universal syntax:
/// the value of the first of its components that consumes every token, set with `value.setResult`, and that
/// component's type; or Unknown, with nothing consumed. `consumedTokens` is set to the tokens consumed. `property` is
/// the state's current property, whose quirks the numeric consumers accept in HTMLQuirksMode.
///
/// consumeCustomPropertyValueWithSyntax makes `value` on its stack for this call only, over its CSS::PropertyParserState
/// and CSSGradientSwiftStops. While it is live, Swift reads `syntax`'s definition and calls only `value`'s members
/// (parseWithCxx, parseCalc, setResult, tokenValue and the token accessors type, blockType, unitType, delimiter,
/// identifier, identEquals), the CSSValue factories (CSSPrimitiveValue::create), the C++ helpers of the Swift consumers (consumerContextForSwift, colorContextForSwift,
/// colorKeywordForSwift, appendKeywordForSwift, consumeColorInterpolationMethodForSwift, consumeCalcSizeSumForSwift,
/// consumeCounterStyleSymbolForSwift, counterStyleIntegerForSwift, currentPropertyForSwift,
/// isGenericFontFamilyForSwift, isObliqueAngleForSwift), and, through parseWithCxx,
/// CSSPropertyParsing::parseStylePropertyLonghand, consumeRuleForSwift and parseDescriptorForSwift. None of them
/// reaches the facade, script or another thread. A C++ consumer that re-enters Swift does so with facades of its own.
@_expose(Cxx)
func cssConsumeCustomPropertyValueWithSyntax(
    _ value: borrowing WebCore.CSSPropertyConsumerSwiftValue,
    _ syntax: borrowing WebCore.CSSCustomPropertySyntax,
    _ property: UInt16,
    _ parserMode: UInt8,
    _ numericFlags: UInt8,
    _ consumedTokens: inout UInt32
) -> UInt8 {
    // Never nil: an imported C++ enum's init(rawValue:) does not check its value.
    let property = WebCore.CSSPropertyID(rawValue: property) ?? .Invalid
    var propertyParser = PropertyParser(
        value,
        parserMode: parserMode,
        numericFlags: numericFlags | quirkyNumericFlags(property, parserMode)
    )
    let (parsed, type) = propertyParser.consumeCustomPropertyValueWithSyntax(syntax) { arguments, function, calc in
        // Both at most the token count, an Int from a UInt32.
        let argumentsStart = UInt32(truncatingIfNeeded: arguments.lowerBound)
        let argumentsEnd = UInt32(truncatingIfNeeded: arguments.upperBound)
        return value.parseCalc(argumentsStart, argumentsEnd, function, calc.category.rawValue, calc.flags, calc.min, calc.max).get()
    }
    if let parsed {
        value.setResult(parsed)
    }
    // At most the token count, an Int from a UInt32.
    consumedTokens = UInt32(truncatingIfNeeded: propertyParser.index)
    return type.rawValue
}

extension PropertyParser {
    /// `consumeCustomPropertyValueWithSyntax`: each component in the syntax's order, from the same start; the first
    /// whose value ends at the end wins. Between attempts both ends of the range are restored.
    fileprivate mutating func consumeCustomPropertyValueWithSyntax(
        _ syntax: WebCore.CSSCustomPropertySyntax,
        _ calc: PropertyCalc
    ) -> (PropertyValue?, WebCore.CSSCustomPropertySyntax.`Type`) {
        assert(!syntax.isUniversal())

        let rangeStart = index
        let rangeEnd = end
        // Each component is read out of the definition once (a Component copy: one AtomString ref), and the helpers
        // borrow it: no read of `syntax` copies its Vector.
        let componentCount = syntax.definition.size()
        for componentIndex in 0..<componentCount {
            let component = syntax.definition[componentIndex]
            if let value = consumeSyntaxComponent(component, calc), atEnd {
                return (value, component.type)
            }
            index = rangeStart
            end = rangeEnd
        }
        return (nil, .Unknown)
    }

    /// `consumeComponent`: one value, or a comma or space separated list of one or more (`consumeListSeparatedBy` with
    /// OneOrMore).
    private mutating func consumeSyntaxComponent(
        _ component: borrowing WebCore.CSSCustomPropertySyntax.Component,
        _ calc: PropertyCalc
    ) -> PropertyValue? {
        switch component.multiplier {
        case .Single:
            return consumeSyntaxSingleValue(component, calc)
        case .CommaList:
            var list = PropertyValueList()
            repeat {
                guard let value = consumeSyntaxSingleValue(component, calc) else {
                    return nil
                }
                list.append(value)
            } while consumeComma()
            return makeCommaSeparatedList(list)
        case .SpaceList:
            var list = PropertyValueList()
            var isEmpty = true
            repeat {
                guard let value = consumeSyntaxSingleValue(component, calc) else {
                    break
                }
                list.append(value)
                isEmpty = false
            } while !atEnd
            if isEmpty {
                return nil
            }
            return makeSpaceSeparatedList(list)
        @unknown default:
            assertionFailure()
            return nil
        }
    }

    /// `consumeSingleValue`. The end of the range does not move.
    private mutating func consumeSyntaxSingleValue(
        _ component: borrowing WebCore.CSSCustomPropertySyntax.Component,
        _ calc: PropertyCalc
    ) -> PropertyValue? {
        let rangeEnd = end
        defer {
            end = rangeEnd
        }

        switch component.type {
        case .Ident:
            // The token's value against the ident as written in the syntax, case-sensitively.
            guard !atEnd, tokens.value.identEquals(index, component.ident) else {
                return nil
            }
            let value = tokens.value.tokenValue(index).get()
            consumeIncludingWhitespace()
            return value
        case .CustomIdent:
            return customIdent()
        case .Length:
            return primitive(PropertyPrimitive(.length), calc)
        case .LengthPercentage:
            return primitive(PropertyPrimitive(.lengthPercentage), calc)
        case .Percentage:
            return primitive(PropertyPrimitive(.percentage), calc)
        case .Integer:
            return primitive(PropertyPrimitive(.integer), calc)
        case .Number:
            return primitive(PropertyPrimitive(.number), calc)
        case .Angle:
            return primitive(PropertyPrimitive(.angle), calc)
        case .Time:
            return primitive(PropertyPrimitive(.time), calc)
        case .Resolution:
            // CSS::Resolution<> is non-negative.
            return primitive(PropertyPrimitive(.resolution, min: 0), calc)
        case .Color:
            // consumeColor's default CSSColorParsingOptions, which CSSPropertyParser.cpp pins.
            return colorValue(calc, allowedColorTypes: 0b111)
        case .Image:
            // url() and generated images: no image-set(), and no string as a URL.
            let start = index
            let allowed =
                WebCore.CSSPropertyParserHelpers.AllowedImageType.URLFunction.rawValue
                | WebCore.CSSPropertyParserHelpers.AllowedImageType.GeneratedImage.rawValue
            guard let image = consumeImage(allowed) else {
                index = start
                return nil
            }
            return image
        case .URL:
            return consumeURLValue()
        case .String:
            return stringValue()
        case .TransformFunction:
            return parseGeneratedRule(.transformFunction, calc)
        case .TransformList:
            return parseGeneratedRule(.transformList, calc)
        case .Unknown:
            return nil
        @unknown default:
            assertionFailure()
            return nil
        }
    }
}

#endif // USE_SWIFT_CSS_SHORTHANDS_AND_TYPED_OM
