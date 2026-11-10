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

internal import WebCore_Private.Core.CSSPropertyConsumerSwiftBuilders
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftTypes

// The consumers of CSSPropertyParserConsumer+Box.cpp (margin-trim), +Overflow.cpp (overflow-clip-margin), +Inline.cpp
// (line-fit-edge and text-box-edge), +Lists.cpp (counter-reset, counter-increment and counter-set), +Animations.cpp
// (keyframe selectors and keyframes names), +TextDecoration.cpp (text-shadow), +Anchor.cpp (position-area) and
// +LinkParameters.cpp (param()), +CounterStyles.cpp (counter styles and their descriptors), +Content.cpp (quotes and
// content), +CalcSize.cpp (calc-size()) and +UnicodeRange.cpp (unicode-range), and consumeValue4, which dispatches to
// the consumers from AlignContent on.

extension PropertyParser {
    /// The CSSPropertyConsumerSwiftConsumer `consumer`, from AlignContent on, or nil if there is none.
    mutating func consumeValue4(_ consumer: UInt16, _ calc: PropertyCalc) -> PropertyValue? {
        typealias Consumer = WebCore.CSSPropertyConsumerSwiftConsumer
        switch consumer {
        case Consumer.AlignContent.rawValue: return alignContent()
        case Consumer.JustifyContent.rawValue: return justifyContent()
        case Consumer.AlignSelf.rawValue: return alignSelf()
        case Consumer.JustifySelf.rawValue: return justifySelf()
        case Consumer.AlignItems.rawValue: return alignItems()
        case Consumer.JustifyItems.rawValue: return justifyItems()
        case Consumer.Display.rawValue: return display()
        case Consumer.MarginTrim.rawValue: return marginTrim()
        case Consumer.OverflowClipMargin.rawValue: return overflowClipMargin(calc)
        case Consumer.LineFitEdge.rawValue: return lineFitEdge()
        case Consumer.TextBoxEdge.rawValue: return textBoxEdge()
        case Consumer.CounterReset.rawValue: return counter(defaultValue: 0, calc)
        case Consumer.CounterIncrement.rawValue: return counter(defaultValue: 1, calc)
        case Consumer.CounterSet.rawValue: return counter(defaultValue: 0, calc)
        case Consumer.KeyframeKeyList.rawValue: return keyframeKeyList()
        case Consumer.KeyframesName.rawValue: return keyframesName()
        case Consumer.TextShadow.rawValue: return textShadow()
        case Consumer.PositionArea.rawValue: return positionArea()
        case Consumer.ParamFunctionRaw.rawValue: return paramFunction()
        case Consumer.EasingFunction.rawValue: return easingFunction(unresolved: false, calc)
        case Consumer.UnresolvedEasingFunction.rawValue: return easingFunction(unresolved: true, calc)
        case Consumer.CounterStyle.rawValue: return counterStyle()
        case Consumer.CounterStyleName.rawValue: return counterStyleName()
        case Consumer.CounterStyleSystem.rawValue: return counterStyleSystem(calc)
        case Consumer.CounterStyleRange.rawValue: return counterStyleRange(calc)
        case Consumer.CounterStyleAdditiveSymbols.rawValue: return counterStyleAdditiveSymbols(calc)
        case Consumer.Quotes.rawValue: return quotes()
        case Consumer.Content.rawValue: return content()
        case Consumer.CalcSize.rawValue: return calcSize()
        case Consumer.FontStyle.rawValue: return fontStyle()
        case Consumer.FontFamily.rawValue: return fontFamily()
        case Consumer.FamilyName.rawValue: return familyNameValue()
        case Consumer.FontSizeAdjust.rawValue: return fontSizeAdjust(calc)
        case Consumer.FontPalette.rawValue: return fontPalette()
        case Consumer.UnresolvedFont.rawValue: return unresolvedFont()
        case Consumer.FontFaceSrc.rawValue: return fontFaceSrc()
        case Consumer.FontTech.rawValue: return fontTech()
        case Consumer.FontFormat.rawValue: return fontFormat()
        case Consumer.FontFaceFontStyle.rawValue: return fontFaceFontStyle()
        case Consumer.FontFeatureValuesPrelude.rawValue: return fontFeatureValuesPrelude()
        case Consumer.GridLine.rawValue: return gridLine(unresolved: false, calc)
        case Consumer.UnresolvedGridLine.rawValue: return gridLine(unresolved: true, calc)
        case Consumer.GridAutoFlow.rawValue: return gridAutoFlow()
        case Consumer.GridTemplateAreas.rawValue: return gridTemplateAreas()
        case Consumer.UnresolvedGridTemplateAreasRow.rawValue: return unresolvedGridTemplateAreasRow()
        case Consumer.UnresolvedGridLineNames.rawValue: return unresolvedGridLineNames()
        case Consumer.UnresolvedGridTrackSize.rawValue: return unresolvedGridTrackSize(calc)
        case Consumer.GridTrackSizes.rawValue: return gridTrackSizes(calc)
        case Consumer.UnresolvedGridExplicitTrackList.rawValue: return unresolvedGridExplicitTrackList(calc)
        case Consumer.GridTemplateList.rawValue: return gridTemplateList(calc)
        case Consumer.BasicShapeRect.rawValue: return basicShape(rectOnly: true, rejectPathFillRule: false)
        case Consumer.Path.rawValue: return path()
        case Consumer.ShapeOutside.rawValue: return shapeOutside()
        case Consumer.Clip.rawValue: return clip()
        case Consumer.ClipPath.rawValue: return clipPath()
        case Consumer.MaskBorderSource.rawValue: return maskBorderSource()
        case Consumer.MaskBorderOutset.rawValue: return maskBorderOutset()
        case Consumer.MaskBorderRepeat.rawValue: return maskBorderRepeat()
        case Consumer.MaskBorderSlice.rawValue: return maskBorderSlice()
        case Consumer.MaskBorderWidth.rawValue: return maskBorderWidth()
        case Consumer.UnresolvedMaskBorder.rawValue: return unresolvedMaskBorder()
        case Consumer.OffsetPath.rawValue: return offsetPath()
        case Consumer.Filter.rawValue: return filter(.Filter)
        case Consumer.AppleColorFilter.rawValue: return filter(.AppleColorFilter)
        case Consumer.UnresolvedFilter.rawValue: return filter(.UnresolvedFilter)
        default: return nil
        }
    }

    /// Whether the context enables `bit`, one of the CSSConsumerSwift bits of consumerContextForSwift.
    func contextEnables(_ bit: UInt32) -> Bool {
        WebCore.consumerContextForSwift(tokens.value) & bit != 0
    }

    // MARK: - margin-trim

    // <'margin-trim'> = none | block | [ block-start || block-end ]
    // https://drafts.csswg.org/css-box/#margin-trim
    mutating func marginTrim() -> PropertyValue? {
        let first = peekIdent()
        switch first {
        case .None, .Block:
            return consumeKeyword(peeked: first)
        case .BlockStart, .BlockEnd:
            consumeIncludingWhitespace()
        default:
            return nil
        }
        let second = peekIdent()
        guard second == .BlockStart || second == .BlockEnd else {
            return keywordValue(first)
        }
        consumeIncludingWhitespace()
        if second == first {
            return nil
        }
        return keywordValue(.Block)
    }

    // MARK: - overflow-clip-margin

    // <'overflow-clip-margin'> = <visual-box> || <length>
    // https://drafts.csswg.org/css-overflow/#overflow-clip-margin
    mutating func overflowClipMargin(_ calc: PropertyCalc) -> PropertyValue? {
        var visualBoxID = WebCore.CSSValueID.Invalid
        var visualBox: PropertyValue? = nil
        var length: PropertyNumeric? = nil
        for _ in 0..<2 {
            if atEnd {
                break
            }
            if visualBox == nil {
                let id = peekIdent()
                if let box = consumeVisualBox() {
                    visualBoxID = id
                    visualBox = box
                    continue
                }
            }
            if length == nil, let value = numeric(PropertyPrimitive(.length), calc) {
                length = value
                continue
            }
            break
        }
        guard visualBox != nil || length != nil else {
            return nil
        }

        // The default value is padding-box.
        let box = visualBoxID == .PaddingBox ? nil : visualBox
        // The default value is 0px.
        let margin = length.flatMap { $0.isKnownZero ? nil : $0.value }
        switch (box, margin) {
        case let (box?, margin?):
            return makeSpaceSeparatedList(box, margin)
        case let (box?, nil):
            return box
        case let (nil, margin?):
            return margin
        case (nil, nil):
            return WebCore.CSSPrimitiveValue.create(0, .Px).get()
        }
    }

    // MARK: - line-fit-edge and text-box-edge

    // <text-edge> = [ text | cap | ex | ideographic | ideographic-ink ]
    //               [ text | alphabetic | ideographic | ideographic-ink ]?
    // https://drafts.csswg.org/css-inline-3/#typedef-text-edge
    private mutating func textEdge() -> PropertyValue? {
        let first = peekIdent()
        switch first {
        case .Text, .Cap, .Ex, .Ideographic, .IdeographicInk:
            consumeIncludingWhitespace()
        default:
            return nil
        }
        let second = peekIdent()
        switch second {
        case .Text, .Alphabetic, .Ideographic, .IdeographicInk:
            consumeIncludingWhitespace()
        default:
            return keywordValue(first)
        }

        // https://drafts.csswg.org/css-inline-3/#text-edges
        // "If only one value is specified, both edges are assigned that same keyword if possible; else text is assumed as the missing value."
        let isSecondImplied = first == .Cap || first == .Ex ? second == .Text : second == first
        if isSecondImplied {
            return keywordValue(first)
        }
        return makePair(keywordValue(first), keywordValue(second), coalescing: true)
    }

    // <'line-fit-edge'> = leading | <text-edge>
    // https://drafts.csswg.org/css-inline-3/#propdef-line-fit-edge
    mutating func lineFitEdge() -> PropertyValue? {
        if peekIdent() == .Leading {
            return consumeKeyword(peeked: .Leading)
        }
        return textEdge()
    }

    // <'text-box-edge'> = auto | <text-edge>
    // https://drafts.csswg.org/css-inline-3/#propdef-text-box-edge
    mutating func textBoxEdge() -> PropertyValue? {
        if peekIdent() == .Auto {
            return consumeKeyword(peeked: .Auto)
        }
        return textEdge()
    }

    // MARK: - counter-reset, counter-increment and counter-set

    // <'counter-reset'> = [ <counter-name> <integer>? | <reversed-counter-name> <integer>? ]+ | none
    // https://drafts.csswg.org/css-lists/#propdef-counter-reset
    // <'counter-increment'> = [ <counter-name> <integer>? ]+ | none
    // https://drafts.csswg.org/css-lists/#propdef-counter-increment
    // <'counter-set'> = [ <counter-name> <integer>? ]+ | none
    // https://drafts.csswg.org/css-lists/#propdef-counter-set
    // A counter with no <integer> has `defaultValue`.
    // FIXME: Implement support for `reversed-counter-name`.
    private mutating func counter(defaultValue: Double, _ calc: PropertyCalc) -> PropertyValue? {
        if peekIdent() == .None {
            return consumeKeyword(peeked: .None)
        }

        var list = PropertyValueList()
        repeat {
            guard let name = customIdent() else {
                return nil
            }
            let value: PropertyValue
            if let integer = primitive(PropertyPrimitive(.integer), calc) {
                value = integer
            } else {
                value = WebCore.CSSPrimitiveValue.createInteger(defaultValue).get()
            }
            list.append(makePair(name, value, coalescing: true))
        } while !atEnd
        return makeSpaceSeparatedList(list)
    }

    // MARK: - Keyframe selectors and keyframes names

    // <keyframe-selector> = from | to | <percentage [0,100]> | <timeline-range-name> <percentage>
    // https://drafts.csswg.org/css-animations-1/#typedef-keyframe-selector
    //   and extended by
    // https://drafts.csswg.org/scroll-animations/#named-range-keyframes
    // Gives a comma-separated list of them to setKeyframeKeyListResult.
    private mutating func keyframeKeyList() -> PropertyValue? {
        var parts = WebCore.CSSImageSwiftParts()
        while true {
            consumeWhitespace()

            var key = WebCore.CSSColorSwiftComponents()
            let percentage = UInt8(WebCore.CSSColorSwiftChannelPercentage)
            if peekType() == PropertyTokenType.ident {
                let id = peekIdent()
                consumeIncludingWhitespace()
                if id == .From {
                    key.setSymbol(0, WebCore.CSSValueID.Normal.rawValue)
                    key.setValue(1, percentage, 0, 0)
                } else if id == .To {
                    key.setSymbol(0, WebCore.CSSValueID.Normal.rawValue)
                    key.setValue(1, percentage, 0, 100)
                } else if WebCore.isTimelineRangeNameForSwift(id.rawValue), consumeNumeric(&key, 1, .percentage) {
                    key.setSymbol(0, id.rawValue)
                } else {
                    return nil
                }
            } else if consumeNumeric(&key, 1, .crossfadePercentage) {
                key.setSymbol(0, WebCore.CSSValueID.Normal.rawValue)
            } else {
                return nil
            }
            parts.append(key, 0..<2)

            if atEnd {
                WebCore.setKeyframeKeyListResult(tokens.value, consuming: consume parts)
                return nil
            }

            // Any token but a comma ends the list, consumed.
            let type = peekType()
            index &+= 1 // Below end, a token count.
            guard type == PropertyTokenType.comma else {
                return nil
            }
        }
    }

    // <keyframes-name> = <custom-ident> | <string>
    // https://drafts.csswg.org/css-animations/#typedef-keyframes-name
    private mutating func keyframesName() -> PropertyValue? {
        if peekType() == PropertyTokenType.string {
            let string = index
            consumeIncludingWhitespace()
            // At most the token count, an Int from a UInt32.
            return WebCore.makeKeyframesNameValue(tokens.value, UInt32(truncatingIfNeeded: string)).get()
        }
        return customIdent()
    }

    // MARK: - text-shadow

    // <'text-shadow'> = none | [ <color>? && <length>{2,3} ]#
    // https://drafts.csswg.org/css-text-decor-3/#propdef-text-shadow
    private mutating func textShadow() -> PropertyValue? {
        var parts = WebCore.CSSImageSwiftParts()
        if peekIdent() == .None {
            consumeIncludingWhitespace()
            return WebCore.makeTextShadowValue(tokens.value, consuming: consume parts).get()
        }
        let start = index
        repeat {
            guard singleTextShadow(&parts) else {
                index = start
                return nil
            }
        } while consumeComma()
        return WebCore.makeTextShadowValue(tokens.value, consuming: consume parts).get()
    }

    // <single-text-shadow> = [ <color>? && <length>{2,3} ]
    // https://drafts.csswg.org/css-text-decor-3/#propdef-text-shadow
    // Appends its color and its x, y and blur components to `parts`. Consumes nothing if there is none.
    private mutating func singleTextShadow(_ parts: inout WebCore.CSSImageSwiftParts) -> Bool {
        let start = index
        var state = gradientColorState()
        var color = WebCore.CSSColorSwiftStopColor()
        var channels = WebCore.CSSColorSwiftComponents()
        var lengths = WebCore.CSSColorSwiftComponents()
        var hasX = false
        var hasY = false
        while !atEnd {
            if color.kind == UInt8(WebCore.CSSColorSwiftNoColor) {
                color = consumeStopColor(&state, &channels)
                if color.kind != UInt8(WebCore.CSSColorSwiftNoColor) {
                    continue
                }
            }
            guard !hasX else {
                break
            }
            hasX = consumeNumeric(&lengths, 0, .length)
            guard hasX else {
                break
            }
            hasY = consumeNumeric(&lengths, 1, .length)
            guard hasY else {
                break
            }
            // A blur that is not a non-negative length ends the shadow before it.
            _ = consumeNumeric(&lengths, 2, .nonnegativeLength)
        }
        guard hasY else {
            index = start
            return false
        }
        parts.appendColor(tokens.value, color, channels, WebCore.CSSColorSwiftComponents())
        parts.append(lengths, 0..<3)
        return true
    }

    // MARK: - position-area

    // <'position-area'> = none | <position-area>
    // https://drafts.csswg.org/css-anchor-position-1/#propdef-position-area
    // The identifiers stay consumed when they are not a position area.
    private mutating func positionArea() -> PropertyValue? {
        guard peekType() == PropertyTokenType.ident else {
            return nil
        }
        let first = peekIdent()
        consumeIncludingWhitespace()
        if first == .None {
            return keywordValue(.None)
        }
        guard peekType() == PropertyTokenType.ident else {
            return WebCore.makePositionAreaValue(first.rawValue, UInt32.max).get()
        }
        let second = peekIdent()
        consumeIncludingWhitespace()
        return WebCore.makePositionAreaValue(first.rawValue, UInt32(second.rawValue)).get()
    }

    // MARK: - param()

    // <param()>    = param( <param-spec> , <declaration-value>? )
    // <param-spec> = color | accent-color | [ <dashed-ident> <css-type>? ]
    // https://drafts.csswg.org/css-link-params/#funcdef-param
    // Gives it to setParamFunctionResult. Consumes the function and the whitespace after it even if it is not one.
    private mutating func paramFunction() -> PropertyValue? {
        guard let function = beginFunction(.Param) else {
            return nil
        }
        var keyword = WebCore.CSSValueID.Invalid
        var name = 0
        let id = peekIdent()
        if id == .Color || id == .AccentColor {
            keyword = id
            consumeIncludingWhitespace()
        } else if peekType() == PropertyTokenType.ident, tokens.value.isDashedIdent(index) {
            name = index
            consumeIncludingWhitespace()
        } else {
            endColorFunction(function, true)
            return nil
        }
        // All at most the token count, Ints from a UInt32.
        _ = WebCore.setParamFunctionResult(
            tokens.value,
            keyword.rawValue,
            UInt32(truncatingIfNeeded: name),
            UInt32(truncatingIfNeeded: index),
            UInt32(truncatingIfNeeded: end)
        )
        endColorFunction(function, true)
        return nil
    }
}


// MARK: - Counter styles

extension PropertyParser {
    // <counter-style-name> is a <custom-ident> that is not an ASCII case-insensitive match for "none", and the keyword
    // of a predefined counter style. A predefined counter style is never a CSS-wide keyword, `default` or `none`.
    // https://drafts.csswg.org/css-counter-styles-3/#typedef-counter-style-name
    private mutating func counterStyleName() -> PropertyValue? {
        let id = peekIdent()
        guard peekType() == PropertyTokenType.ident, id != .None, WebCore.isValidCustomIdentifier(id) else {
            return nil
        }
        let name = index
        consumeIncludingWhitespace()
        // At most the token count, an Int from a UInt32.
        return WebCore.makeCounterStyleNameValue(tokens.value, UInt32(truncatingIfNeeded: name)).get()
    }

    // <counter-style> = <counter-style-name excluding=none> | <symbols()>
    // https://drafts.csswg.org/css-counter-styles-3/#typedef-counter-style
    private mutating func counterStyle() -> PropertyValue? {
        if peekType() == PropertyTokenType.ident {
            return counterStyleName()
        }
        let start = index
        guard let symbols = symbols() else {
            return nil
        }
        guard let value = WebCore.makeSymbolsFunctionValue(tokens.value, symbols.system, symbols.start, symbols.end).get() else {
            index = start
            return nil
        }
        return value
    }

    // symbols() = symbols( <symbols-type>? [ <string> | <image> ]+ )
    // https://drafts.csswg.org/css-counter-styles-3/#funcdef-symbols
    // FIXME: Add support for <image> symbols.
    // The token of its identifier, or UInt32.max without one, and the tokens of its strings, for makeSymbolsFunctionValue,
    // which rejects an identifier that is not a <symbols-type>. Consumes nothing if there is none.
    private mutating func symbols() -> (system: UInt32, start: UInt32, end: UInt32)? {
        guard contextEnables(UInt32(WebCore.CSSConsumerSwiftSymbolsFunctionEnabled)), let function = beginFunction(.Symbols) else {
            return nil
        }
        var system = UInt32.max
        var isAlphabeticOrNumeric = false
        if peekType() == PropertyTokenType.ident {
            let id = peekIdent()
            // At most the token count, an Int from a UInt32.
            system = UInt32(truncatingIfNeeded: index)
            isAlphabeticOrNumeric = id == .Alphabetic || id == .Numeric
            consumeIncludingWhitespace()
        }
        let start = index
        var count = 0
        while peekType() == PropertyTokenType.string {
            consumeIncludingWhitespace()
            count &+= 1 // At most the token count.
        }
        let end = index
        // If the system is alphabetic or numeric, there must be at least two <string>s, or else the function is invalid.
        let isValid = count > 0 && atEnd && !(isAlphabeticOrNumeric && count < 2)
        endColorFunction(function, isValid)
        guard isValid else {
            return nil
        }
        // Both at most the token count, Ints from a UInt32.
        return (system, UInt32(truncatingIfNeeded: start), UInt32(truncatingIfNeeded: end))
    }

    // <'system'> = cyclic | numeric | alphabetic | symbolic | additive | [fixed <integer>?] | [ extends <counter-style-name> ]
    // https://drafts.csswg.org/css-counter-styles-3/#counter-style-system
    private mutating func counterStyleSystem(_ calc: PropertyCalc) -> PropertyValue? {
        let id = peekIdent()
        switch id {
        case .Cyclic, .Numeric, .Alphabetic, .Symbolic, .Additive:
            return consumeKeyword(peeked: id)
        case .InternalDisclosureClosed, .InternalDisclosureOpen, .InternalSimplifiedChineseInformal, .InternalSimplifiedChineseFormal,
            .InternalTraditionalChineseInformal, .InternalTraditionalChineseFormal, .InternalJapaneseInformal, .InternalJapaneseFormal,
            .InternalKoreanHangulFormal, .InternalKoreanHanjaInformal, .InternalKoreanHanjaFormal, .InternalEthiopicNumeric:
            guard parserMode == WebCore.UASheetMode.rawValue else {
                return nil
            }
            return consumeKeyword(peeked: id)
        case .Fixed:
            consumeIncludingWhitespace()
            let fixed = keywordValue(.Fixed)
            if atEnd {
                return fixed
            }
            // If we have the `fixed` keyword but the range is not at the end, the next token must be a integer.
            // If it's not, this value is invalid.
            guard let firstSymbolValue = primitive(PropertyPrimitive(.integer), calc) else {
                return nil
            }
            return makePair(fixed, firstSymbolValue, coalescing: true)
        case .Extends:
            consumeIncludingWhitespace()
            // There must be a `<counter-style-name>` following the `extends` keyword. If there isn't, this value is invalid.
            guard let name = counterStyleName() else {
                return nil
            }
            return makePair(keywordValue(.Extends), name, coalescing: true)
        default:
            return nil
        }
    }

    // <'range'> = [ [ <integer> | infinite ]{2} ]# | auto
    // https://drafts.csswg.org/css-counter-styles-3/#counter-style-range
    private mutating func counterStyleRange(_ calc: PropertyCalc) -> PropertyValue? {
        if peekIdent() == .Auto {
            return consumeKeyword(peeked: .Auto)
        }
        var list = PropertyValueList()
        repeat {
            guard let lowerBound = counterStyleRangeBound(calc), let upperBound = counterStyleRangeBound(calc) else {
                return nil
            }
            // If the lower bound of any range is higher than the upper bound, the entire descriptor is invalid and must be ignored.
            // `infinite` means negative infinity when used for the lower bound and positive infinity when used for the upper bound,
            // so if either value was `infinite`, the bound is valid.
            if lowerBound.isInteger && upperBound.isInteger
                && WebCore.counterStyleIntegerForSwift(lowerBound.value, false) > WebCore.counterStyleIntegerForSwift(upperBound.value, false)
            {
                return nil
            }
            list.append(makePair(lowerBound.value, upperBound.value, coalescing: false))
        } while consumeComma()
        guard atEnd else {
            return nil
        }
        return makeCommaSeparatedList(list)
    }

    // [ <integer> | infinite ], and whether it is an integer.
    private mutating func counterStyleRangeBound(_ calc: PropertyCalc) -> (value: PropertyValue, isInteger: Bool)? {
        if peekIdent() == .Infinite {
            consumeIncludingWhitespace()
            return (keywordValue(.Infinite), false)
        }
        guard let integer = primitive(PropertyPrimitive(.integer), calc) else {
            return nil
        }
        return (integer, true)
    }

    // <'additive-symbols'> = [ <integer [0,∞]> && <symbol> ]#
    // https://drafts.csswg.org/css-counter-styles-3/#descdef-counter-style-additive-symbols
    private mutating func counterStyleAdditiveSymbols(_ calc: PropertyCalc) -> PropertyValue? {
        let weightPrimitive = PropertyPrimitive(.integer, min: 0)
        var lastWeight: Int32? = nil
        var list = PropertyValueList()
        repeat {
            var integer = primitive(weightPrimitive, calc)
            let symbol = counterStyleSymbol()
            if integer == nil {
                guard symbol != nil else {
                    return nil
                }
                integer = primitive(weightPrimitive, calc)
            }
            guard let integer, let symbol else {
                return nil
            }
            // Additive tuples must be specified in order of strictly descending weight.
            let weight = WebCore.counterStyleIntegerForSwift(integer, true)
            if let lastWeight, !(weight < lastWeight) {
                return nil
            }
            lastWeight = weight
            list.append(makePair(integer, symbol, coalescing: true))
        } while consumeComma()
        guard atEnd else {
            return nil
        }
        return makeCommaSeparatedList(list)
    }

    // <symbol> = <string> | <image> | <custom-ident>
    // https://drafts.csswg.org/css-counter-styles-3/#typedef-symbol
    private mutating func counterStyleSymbol() -> PropertyValue? {
        // All at most the token count, Ints from a UInt32.
        var next = UInt32(truncatingIfNeeded: index)
        let symbol = WebCore.consumeCounterStyleSymbolForSwift(tokens.value, UInt32(truncatingIfNeeded: index), UInt32(truncatingIfNeeded: end), &next)
        index = Int(next)
        return symbol.get()
    }
}

// MARK: - quotes and content

extension PropertyParser {
    // <'quotes'> = auto | none | match-parent | [ <string> <string> ]+
    // https://drafts.csswg.org/css-content-3/#propdef-quotes
    // FIXME: Support `match-parent`.
    // Consumes nothing if there is none.
    private mutating func quotes() -> PropertyValue? {
        let id = peekIdent()
        if id == .None || id == .Auto {
            consumeIncludingWhitespace()
            return WebCore.makeQuotesValue(tokens.value, id.rawValue, 0, 0).get()
        }
        let start = index
        while !atEnd {
            for _ in 0..<2 {
                guard peekType() == PropertyTokenType.string else {
                    index = start
                    return nil
                }
                consumeIncludingWhitespace()
            }
        }
        guard index > start else {
            return nil
        }
        // Both at most the token count, Ints from a UInt32.
        return WebCore.makeQuotesValue(tokens.value, WebCore.CSSValueID.Invalid.rawValue, UInt32(truncatingIfNeeded: start), UInt32(truncatingIfNeeded: index)).get()
    }

    // <'content'> = normal | none | [ <content-replacement> | <content-list> ] [/ [ <string> | <counter> | <attr()> ]+ ]?
    // https://drafts.csswg.org/css-content-3/#propdef-content
    // Consumes nothing if there is none.
    private mutating func content() -> PropertyValue? {
        var parts = WebCore.CSSContentSwiftParts(0)
        let id = peekIdent()
        if id == .None || id == .Normal {
            consumeIncludingWhitespace()
            return WebCore.makeContentValue(tokens.value, id.rawValue, consuming: consume parts).get()
        }
        let start = index
        // Visible content parsing ends at '/' or end of range.
        repeat {
            guard contentItem(&parts) else {
                index = start
                return nil
            }
        } while !atEnd && !peekIsSlash()
        if peekIsSlash() {
            consumeIncludingWhitespace()
            parts.beginAltContent()
            // FIXME: <alt-content> should support <counter> as well.
            repeat {
                guard peekType() == PropertyTokenType.string else {
                    index = start
                    return nil
                }
                // At most the token count, an Int from a UInt32.
                parts.append(UInt8(WebCore.CSSContentSwiftText), UInt32(truncatingIfNeeded: index), 0, 0, 0, 0, 0)
                consumeIncludingWhitespace()
            } while !atEnd
        }
        guard let value = WebCore.makeContentValue(tokens.value, WebCore.CSSValueID.Invalid.rawValue, consuming: consume parts).get() else {
            index = start
            return nil
        }
        return value
    }

    private func peekIsSlash() -> Bool {
        peekType() == PropertyTokenType.delimiter && tokens.value.delimiter(index) == 0x2F // '/'
    }

    // A <string>, an <image>, a quote or glyph identifier, counter() or counters(), appended to `parts`. Consumes nothing
    // if there is none; makeContentValue rejects an identifier that is neither a quote nor, in the UA sheet, a glyph.
    private mutating func contentItem(_ parts: inout WebCore.CSSContentSwiftParts) -> Bool {
        // All the token indices below are at most the token count, Ints from a UInt32.
        if peekType() == PropertyTokenType.string {
            parts.append(UInt8(WebCore.CSSContentSwiftText), UInt32(truncatingIfNeeded: index), 0, 0, 0, 0, 0)
            consumeIncludingWhitespace()
            return true
        }
        let start = index
        if let image = consumeImage(defaultAllowedImageTypes) {
            parts.appendImage(image)
            return true
        }
        index = start
        if peekType() == PropertyTokenType.ident {
            parts.append(UInt8(WebCore.CSSContentSwiftKeyword), UInt32(truncatingIfNeeded: index), 0, 0, 0, 0, 0)
            consumeIncludingWhitespace()
            return true
        }
        let name = peekFunction()
        guard name == .Counter || name == .Counters, let function = beginFunction(name) else {
            return false
        }
        // counter()  = counter( <counter-name>, <counter-style>?@(default=decimal) )
        // https://www.w3.org/TR/css-lists-3/#funcdef-counter
        // counters() = counters( <counter-name>, <string>, <counter-style>?@(default=decimal) )
        // https://www.w3.org/TR/css-lists-3/#funcdef-counters
        guard peekType() == PropertyTokenType.ident, WebCore.isValidCustomIdentifier(peekIdent()) else {
            endColorFunction(function, false)
            return false
        }
        let identifier = UInt32(truncatingIfNeeded: index)
        consumeIncludingWhitespace()
        var separator: UInt32 = 0
        if name == .Counters {
            guard consumeComma(), peekType() == PropertyTokenType.string else {
                endColorFunction(function, false)
                return false
            }
            separator = UInt32(truncatingIfNeeded: index)
            consumeIncludingWhitespace()
        }
        var style = UInt32.max
        var styleSymbols: (system: UInt32, start: UInt32, end: UInt32) = (UInt32.max, 0, 0)
        if consumeComma() {
            // <counter-style> = <counter-style-name excluding=none> | <symbols()>
            let id = peekIdent()
            style = UInt32(truncatingIfNeeded: index)
            if peekType() == PropertyTokenType.ident && id != .None && WebCore.isValidCustomIdentifier(id) {
                consumeIncludingWhitespace()
            } else if let parsed = symbols() {
                styleSymbols = parsed
            } else {
                endColorFunction(function, false)
                return false
            }
        }
        guard atEnd else {
            endColorFunction(function, false)
            return false
        }
        endColorFunction(function, true)
        let kind = name == .Counter ? WebCore.CSSContentSwiftCounter : WebCore.CSSContentSwiftCounters
        parts.append(UInt8(kind), identifier, separator, style, styleSymbols.system, styleSymbols.start, styleSymbols.end)
        return true
    }
}

// MARK: - calc-size()

extension PropertyParser {
    // <calc-size()> = calc-size( <calc-size-basis>, <calc-sum> )
    // https://drafts.csswg.org/css-values-5/#calc-size
    // Consumes nothing if there is none.
    private mutating func calcSize() -> PropertyValue? {
        guard contextEnables(UInt32(WebCore.CSSConsumerSwiftCalcSizeFunctionEnabled)), peekFunction() == .CalcSize else {
            return nil
        }
        var parts = WebCore.CSSCalcSizeSwiftParts(0)
        guard calcSizeFunction(&parts) else {
            return nil
        }
        return WebCore.makeCalcSizeValue(tokens.value, consuming: consume parts).get()
    }

    // A calc-size() and the ones nested in its basis, appended to `parts`, the innermost first. Consumes nothing if there
    // is none.
    private mutating func calcSizeFunction(_ parts: inout WebCore.CSSCalcSizeSwiftParts) -> Bool {
        guard let function = beginFunction(.CalcSize) else {
            return false
        }
        // <calc-size-basis> = [ <size-keyword> | <calc-sum> | <calc-size()> | any ]
        var basis = WebCore.CSSValueID.Invalid
        if peekType() == PropertyTokenType.ident && isCalcSizeBasisKeyword(peekIdent()) {
            basis = peekIdent()
            consumeIncludingWhitespace()
        } else if peekFunction() == .CalcSize {
            guard calcSizeFunction(&parts) else {
                endColorFunction(function, false)
                return false
            }
            basis = .CalcSize
        } else if !calcSizeSum(allowsSize: false) {
            endColorFunction(function, false)
            return false
        }
        // `size` is a syntax error when the basis is `any`, but is allowed when the basis is a nested
        // calc-size() whose own basis is `any`.
        guard consumeComma(), calcSizeSum(allowsSize: basis != .Any), atEnd else {
            endColorFunction(function, false)
            return false
        }
        endColorFunction(function, true)
        parts.appendLevel(basis.rawValue)
        return true
    }

    private func isCalcSizeBasisKeyword(_ id: WebCore.CSSValueID) -> Bool {
        switch id {
        case .Auto:
            switch WebCore.currentPropertyForSwift(tokens.value) {
            case WebCore.CSSPropertyID.MaxWidth.rawValue, WebCore.CSSPropertyID.MaxHeight.rawValue, WebCore.CSSPropertyID.MaxBlockSize.rawValue,
                WebCore.CSSPropertyID.MaxInlineSize.rawValue:
                return false
            default:
                return true
            }
        case .Content:
            return WebCore.currentPropertyForSwift(tokens.value) == WebCore.CSSPropertyID.FlexBasis.rawValue
        case .Any, .MinContent, .WebkitMinContent, .MaxContent, .WebkitMaxContent, .FitContent, .WebkitFitContent, .Stretch,
            .WebkitFillAvailable, .Intrinsic, .MinIntrinsic:
            return true
        default:
            return false
        }
    }

    // A <calc-sum>, which the calc() parser consumes, appended to the state's CSSGradientSwiftStops.
    private mutating func calcSizeSum(allowsSize: Bool) -> Bool {
        // All at most the token count, Ints from a UInt32.
        var next = UInt32(truncatingIfNeeded: index)
        let consumed = WebCore.consumeCalcSizeSumForSwift(tokens.value, UInt32(truncatingIfNeeded: index), UInt32(truncatingIfNeeded: end), allowsSize, &next)
        index = Int(next)
        return consumed
    }
}

// MARK: - unicode-range

/// Consumes a <urange> and the whitespace after it from the tokens of `tokens`, and returns its code points and how
/// many tokens it took; with ok 0, there is none, and none were taken.
///
/// consumeUnicodeRangeWithSwift makes `tokens` on its stack for this call only, with no property parser's state:
/// FontFace can consume a unicode-range on a worker thread. Swift reads only the tokens, through the members of
/// `tokens`.
@_expose(Cxx)
func cssConsumeUnicodeRange(_ tokens: borrowing WebCore.CSSUnicodeRangeSwiftTokens) -> WebCore.CSSUnicodeRangeSwiftResult {
    var parser = UnicodeRangeParser(tokens)
    guard let range = parser.unicodeRange() else {
        return WebCore.CSSUnicodeRangeSwiftResult(consumedTokens: 0, start: 0, end: 0, ok: 0)
    }
    parser.consumeWhitespace()
    guard range.end <= 0x10FFFF, range.start <= range.end else {
        return WebCore.CSSUnicodeRangeSwiftResult(consumedTokens: 0, start: 0, end: 0, ok: 0)
    }
    // At most the token count, an Int from a UInt32.
    let consumedTokens = UInt32(truncatingIfNeeded: parser.index)
    return WebCore.CSSUnicodeRangeSwiftResult(consumedTokens: consumedTokens, start: range.start, end: range.end, ok: 1)
}

private struct UnicodeRangeParser: ~Copyable, ~Escapable {
    let tokens: Swift.Ref<WebCore.CSSUnicodeRangeSwiftTokens>
    var index = 0
    let end: Int

    @_lifetime(borrow tokens)
    init(_ tokens: borrowing WebCore.CSSUnicodeRangeSwiftTokens) {
        self.tokens = Swift.Ref(tokens)
        end = tokens.count()
    }

    private func peekType() -> UInt8 {
        index >= end ? PropertyTokenType.eof : tokens.value.type(index)
    }

    mutating func consumeWhitespace() {
        while index < end && PropertyTokenType.isWhitespace(tokens.value.type(index)) {
            index &+= 1 // Below end, a token count.
        }
    }

    // <urange> as the tokenizer splits it: `u`, then `+` and an identifier or a `?`, a dimension, or a number followed
    // by a dimension or a number, then any `?`s, with no whitespace between them. Its value is read from the text of
    // the tokens.
    // https://drafts.csswg.org/css-syntax/#urange-syntax
    mutating func unicodeRange() -> (start: UInt32, end: UInt32)? {
        guard peekType() == PropertyTokenType.ident, tokens.value.textLength(index) == 1 else {
            return nil
        }
        let u = tokens.value.textCharacter(index, 0)
        guard u == 0x75 || u == 0x55 else { // 'u' or 'U'
            return nil
        }
        index &+= 1 // Below end, a token count.
        var text = UnicodeRangeText()
        if appendUnicodeRangeText(PropertyTokenType.dimension, &text) {
            appendQuestionMarks(&text)
        } else if appendUnicodeRangeText(PropertyTokenType.number, &text) {
            if !(appendUnicodeRangeText(PropertyTokenType.dimension, &text) || appendUnicodeRangeText(PropertyTokenType.number, &text)) {
                appendQuestionMarks(&text)
            }
        } else if peekIsDelimiter(0x2B) { // '+'
            index &+= 1 // Below end, a token count.
            text.append(0x2B)
            if !appendUnicodeRangeText(PropertyTokenType.ident, &text) {
                guard peekIsDelimiter(0x3F) else { // '?'
                    return nil
                }
                index &+= 1 // Below end, a token count.
                text.append(0x3F)
            }
            appendQuestionMarks(&text)
        } else {
            return nil
        }
        return text.range
    }

    private func peekIsDelimiter(_ delimiter: UInt16) -> Bool {
        peekType() == PropertyTokenType.delimiter && tokens.value.delimiter(index) == delimiter
    }

    // Consumes a token of `type` and appends its text to `text`; false, with the token consumed, if it has none.
    private mutating func appendUnicodeRangeText(_ type: UInt8, _ text: inout UnicodeRangeText) -> Bool {
        guard peekType() == type else {
            return false
        }
        let token = index
        index &+= 1 // Below end, a token count.
        let length = tokens.value.textLength(token)
        guard length != UInt32.max else {
            return false
        }
        for offset in 0..<length {
            text.append(tokens.value.textCharacter(token, offset))
        }
        return true
    }

    private mutating func appendQuestionMarks(_ text: inout UnicodeRangeText) {
        while peekIsDelimiter(0x3F) { // '?'
            index &+= 1 // Below end, a token count.
            text.append(0x3F)
        }
    }
}

// The text of a <urange>, read one code unit at a time: `+`, up to 6 hex digits and `?`s, and if there is no `?`, an
// optional `-` and up to 6 hex digits.
private struct UnicodeRangeText {
    private enum State {
        case plus
        case startDigits
        case questionMarks
        case endDigits
        case invalid
    }

    private var state = State.plus
    private var digitCount = 0
    private var start: UInt32 = 0
    private var end: UInt32 = 0

    mutating func append(_ character: UInt16) {
        switch state {
        case .plus:
            state = character == 0x2B ? .startDigits : .invalid
        case .startDigits:
            if let digit = hexDigitValue(character) {
                if countDigit() {
                    start = start << 4 | digit // At most 6 digits, 24 bits.
                }
                return
            }
            end = start
            state = .questionMarks
            appendQuestionMark(character)
        case .questionMarks:
            appendQuestionMark(character)
        case .endDigits:
            if let digit = hexDigitValue(character) {
                if countDigit() {
                    end = end << 4 | digit // At most 6 digits, 24 bits.
                }
            } else {
                state = .invalid
            }
        case .invalid:
            break
        }
    }

    // The range, or nil if the text is not one.
    var range: (start: UInt32, end: UInt32)? {
        switch state {
        case .plus, .invalid:
            return nil
        case .startDigits:
            return digitCount > 0 ? (start, start) : nil
        case .questionMarks, .endDigits:
            return digitCount > 0 ? (start, end) : nil
        }
    }

    private mutating func countDigit() -> Bool {
        digitCount &+= 1 // At most 7: the text stops being read past 6.
        guard digitCount <= 6 else {
            state = .invalid
            return false
        }
        return true
    }

    private mutating func appendQuestionMark(_ character: UInt16) {
        if character == 0x3F { // '?'
            if countDigit() {
                start <<= 4
                end = end << 4 | 0xF
            }
            return
        }
        // After the first code point, `-` and the second, only if it has no `?`.
        guard digitCount > 0, start == end, character == 0x2D else { // '-'
            state = .invalid
            return
        }
        digitCount = 0
        end = 0
        state = .endDigits
    }

    private func hexDigitValue(_ character: UInt16) -> UInt32? {
        switch character {
        case 0x30...0x39: UInt32(character &- 0x30) // At least '0'.
        case 0x41...0x46: UInt32(character &- 0x37) // At least 'A'.
        case 0x61...0x66: UInt32(character &- 0x57) // At least 'a'.
        default: nil
        }
    }
}
