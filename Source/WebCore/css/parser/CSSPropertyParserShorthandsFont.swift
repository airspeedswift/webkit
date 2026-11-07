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

// The font, animation and remaining small shorthands of CSSPropertyParserCustom.h, as `PropertyParser` methods: font,
// font-variant (with CSSFontVariantLigaturesParser and CSSFontVariantNumericParser), font-synthesis,
// text-decoration-skip, animation, transition, block-step, overscroll-behavior, container, contain-intrinsic-size,
// transform-origin, perspective-origin, -webkit-perspective, offset, hyphenate-limit-chars, text-box, text-wrap,
// animation-range and the two timeline-trigger ranges, scroll-timeline, view-timeline, position-try and marker.
// Each follows the C++ as CSSPropertyParserShorthands.swift's header describes.
//
// Not here: the patterns, white-space, list-style, line-clamp and the other small ones
// (CSSPropertyParserShorthands.swift); the box shorthands (CSSPropertyParserShorthandsBox.swift); background, mask,
// their positions and -webkit-background-size, and grid* (CSSPropertyParserShorthandsBackgroundGrid.swift).
// text-emphasis and -webkit-text-stroke are StandardSpaceSeparated (CSSPropertyParserShorthands.swift).
//
// The font shorthand gives each longhand the value its own parser makes (parseStylePropertyLonghand), so it does not
// use unresolvedFont (CSSPropertyConsumerSwiftFonts.swift), which builds a CSS::UnresolvedFont.

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
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftBuilders
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftTypes

/// `CSSFontVariantLigaturesParser::ParseResult` and `CSSFontVariantNumericParser::ParseResult`.
enum FontVariantParseResult {
    case consumedValue
    case disallowedValue
    case unknownValue
}

/// The state of a CSSFontVariantLigaturesParser or CSSFontVariantNumericParser (CSSFontVariantLigaturesParser.h,
/// CSSFontVariantNumericParser.h): the groups seen, one bit each, and the keywords consumed, in order.
struct FontVariantKeywordList: ~Copyable {
    var seenGroups: UInt8 = 0
    var count = 0
    var list = PropertyValueList()
}

extension PropertyParser {
    // MARK: - font

    /// `CSSPropertyParserHelpers::isSystemFontShorthand` (CSSPropertyParserConsumer+Font.h): caption to
    /// status-bar, the C++ enumerators, imported.
    private static func isSystemFontShorthand(_ id: WebCore.CSSValueID) -> Bool {
        id.rawValue >= WebCore.CSSValueID.Caption.rawValue && id.rawValue <= WebCore.CSSValueID.StatusBar.rawValue
    }

    /// `consumeFontShorthand`. A system-font keyword alone goes to every longhand, implicit. Otherwise every longhand is
    /// added implicit, the given ones too: the first seven from the values in `longhands` order
    /// (`first(7)`), the rest null.
    mutating func consumeFontShorthand(
        _ sink: borrowing ShorthandSink,
        _ property: WebCore.CSSPropertyID,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        let systemFont = peekIdent()
        if Self.isSystemFontShorthand(systemFont) {
            // `range.consumeIncludingWhitespace().id()`: the token is the identifier just peeked. No range guard yet,
            // so a failure leaves it consumed.
            consumeIncludingWhitespace()
            guard atEnd else {
                return false
            }
            sink.addAllLonghands(property.rawValue, keywordValue(systemFont), true)
            return true
        }

        // `CSSParserTokenRangeGuard guard { range }`: the range is restored unless committed.
        let guardIndex = index
        if consumeFontShorthandValues(sink, longhands, calc) {
            return true
        }
        index = guardIndex
        return false
    }

    /// consumeFontShorthand after its range guard; the adds happen only after `guard.commit()`.
    private mutating func consumeFontShorthandValues(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        var fontStyle: PropertyValue? = nil
        var fontVariantCaps: PropertyValue? = nil
        var fontWeight: PropertyValue? = nil
        var fontWidth: PropertyValue? = nil

        // Optional font-style, font-variant, font-width and font-weight, in any order; `normal` uses a round.
        var i = 0
        while i < 4 && !atEnd {
            defer { i += 1 }
            if shorthandConsumeIdent(.Normal) != nil {
                continue
            }
            if fontStyle == nil {
                fontStyle = parseStylePropertyLonghand(.FontStyle, calc)
                if fontStyle != nil {
                    continue
                }
            }
            if fontVariantCaps == nil {
                fontVariantCaps = shorthandConsumeIdent(.SmallCaps)
                if fontVariantCaps != nil {
                    continue
                }
            }
            if fontWeight == nil {
                fontWeight = parseStylePropertyLonghand(.FontWeight, calc)
                if fontWeight != nil {
                    continue
                }
            }
            if fontWidth == nil {
                fontWidth = parseGeneratedRule(.fontWidthAbsolute, calc)
                if fontWidth != nil {
                    continue
                }
            }
            break
        }

        if atEnd {
            return false
        }

        guard let fontSize = parseStylePropertyLonghand(.FontSize, calc), !atEnd else {
            return false
        }

        var lineHeight: PropertyValue? = nil
        if consumeSlash() {
            // `/ normal` leaves line-height null (implicit initial).
            if shorthandConsumeIdent(.Normal) == nil {
                lineHeight = parseStylePropertyLonghand(.LineHeight, calc)
                if lineHeight == nil {
                    return false
                }
            }
            if atEnd {
                return false
            }
        }

        guard let fontFamily = parseStylePropertyLonghand(.FontFamily, calc), atEnd else {
            return false
        }

        // `zippedRange(values, shorthandProperties.first(7))`: values[k] goes to the k-th longhand, whatever it is.
        let values: [7 of PropertyValue?] = [fontStyle, fontVariantCaps, fontWeight, fontWidth, fontSize, lineHeight, fontFamily]
        for k in 0..<7 {
            shorthandAdd(sink, longhands[k], values[k], implicit: true)
        }
        for k in 7..<longhands.count {
            shorthandAdd(sink, longhands[k], nil, implicit: true)
        }
        return true
    }

    // MARK: - font-variant

    /// The group bit of a `CSSFontVariantLigaturesParser` keyword, or nil for UnknownValue.
    private static func fontVariantLigatureGroup(_ id: WebCore.CSSValueID) -> UInt8? {
        switch id {
        case .NoCommonLigatures, .CommonLigatures: return 1 << 0
        case .NoDiscretionaryLigatures, .DiscretionaryLigatures: return 1 << 1
        case .NoHistoricalLigatures, .HistoricalLigatures: return 1 << 2
        case .NoContextual, .Contextual: return 1 << 3
        default: return nil
        }
    }

    /// The group bit of a `CSSFontVariantNumericParser` keyword, or nil for UnknownValue.
    private static func fontVariantNumericGroup(_ id: WebCore.CSSValueID) -> UInt8? {
        switch id {
        case .LiningNums, .OldstyleNums: return 1 << 0
        case .ProportionalNums, .TabularNums: return 1 << 1
        case .DiagonalFractions, .StackedFractions: return 1 << 2
        case .Ordinal: return 1 << 3
        case .SlashedZero: return 1 << 4
        default: return nil
        }
    }

    /// `consumeLigature` (`numeric` false) or `consumeNumeric` (`numeric` true): the next keyword, if of the parser's
    /// groups and of a group not yet seen.
    mutating func consumeFontVariantKeyword(_ state: inout FontVariantKeywordList, numeric: Bool) -> FontVariantParseResult {
        let valueID = peekIdent()
        guard let group = numeric ? Self.fontVariantNumericGroup(valueID) : Self.fontVariantLigatureGroup(valueID) else {
            return .unknownValue
        }
        if state.seenGroups & group != 0 {
            return .disallowedValue
        }
        state.seenGroups |= group
        // `consumeIdent(range).releaseNonNull()`: valueID is a keyword, so the token is an identifier.
        state.list.append(keywordValue(valueID))
        consumeIncludingWhitespace()
        state.count &+= 1 // At most 5, one per group.
        return .consumedValue
    }

    /// `finalizeValue()`: `normal` if nothing was consumed, else the space-separated keywords.
    func finalizeFontVariantKeywords(_ state: consuming FontVariantKeywordList) -> PropertyValue? {
        if state.count == 0 {
            return keywordValue(.Normal)
        }
        // CSSValueList::createSpaceSeparated never returns null (the C++ calls releaseNonNull on it).
        return makeSpaceSeparatedList(state.list)
    }

    /// `consumeFontVariantShorthand`. `normal` or `none` goes to ligatures, the rest null, before the end is checked.
    /// Otherwise any order; caps, position and alternates are tried before ligatures and numeric, which
    /// both run on each round: when the ligature consumes, numeric has already read the token after it, and the
    /// round continues before numeric's implicit flag or its DisallowedValue is looked at.
    mutating func consumeFontVariantShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        let first = peekIdent()
        if first == .Normal || first == .None {
            // `consumeIdent(range)`: an identifier.
            shorthandAdd(sink, .FontVariantLigatures, consumeKeyword(peeked: first))
            shorthandAdd(sink, .FontVariantCaps, nil)
            shorthandAdd(sink, .FontVariantAlternates, nil)
            shorthandAdd(sink, .FontVariantNumeric, nil)
            shorthandAdd(sink, .FontVariantEastAsian, nil)
            shorthandAdd(sink, .FontVariantPosition, nil)
            shorthandAdd(sink, .FontVariantEmoji, nil)
            return atEnd
        }

        var capsValue: PropertyValue? = nil
        var alternatesValue: PropertyValue? = nil
        var positionValue: PropertyValue? = nil
        var eastAsianValue: PropertyValue? = nil
        var emojiValue: PropertyValue? = nil
        var ligatures = FontVariantKeywordList()
        var numeric = FontVariantKeywordList()
        var implicitLigatures = true
        var implicitNumeric = true
        repeat {
            if peekIdent() == .Normal {
                return false
            }

            if capsValue == nil {
                capsValue = parseStylePropertyLonghand(.FontVariantCaps, calc)
                if capsValue != nil {
                    continue
                }
            }

            if positionValue == nil {
                positionValue = parseStylePropertyLonghand(.FontVariantPosition, calc)
                if positionValue != nil {
                    continue
                }
            }

            if alternatesValue == nil {
                alternatesValue = parseStylePropertyLonghand(.FontVariantAlternates, calc)
                if alternatesValue != nil {
                    continue
                }
            }

            let ligaturesParseResult = consumeFontVariantKeyword(&ligatures, numeric: false)
            let numericParseResult = consumeFontVariantKeyword(&numeric, numeric: true)
            if ligaturesParseResult == .consumedValue {
                implicitLigatures = false
                continue
            }
            if numericParseResult == .consumedValue {
                implicitNumeric = false
                continue
            }

            if ligaturesParseResult == .disallowedValue || numericParseResult == .disallowedValue {
                return false
            }

            if eastAsianValue == nil {
                eastAsianValue = parseStylePropertyLonghand(.FontVariantEastAsian, calc)
                if eastAsianValue != nil {
                    continue
                }
            }

            if tokens.value.isExposed(WebCore.CSSPropertyID.FontVariantEmoji.rawValue) && emojiValue == nil {
                emojiValue = parseStylePropertyLonghand(.FontVariantEmoji, calc)
                if emojiValue != nil {
                    continue
                }
            }

            // Saw some value that didn't match anything else.
            return false
        } while !atEnd

        shorthandAdd(sink, .FontVariantLigatures, finalizeFontVariantKeywords(ligatures), implicit: implicitLigatures)
        shorthandAdd(sink, .FontVariantCaps, capsValue)
        shorthandAdd(sink, .FontVariantAlternates, alternatesValue)
        shorthandAdd(sink, .FontVariantNumeric, finalizeFontVariantKeywords(numeric), implicit: implicitNumeric)
        shorthandAdd(sink, .FontVariantEastAsian, eastAsianValue)
        shorthandAdd(sink, .FontVariantPosition, positionValue)
        shorthandAdd(sink, .FontVariantEmoji, emojiValue)
        return true
    }

    // MARK: - font-synthesis

    /// `consumeFontSynthesisShorthand`: none | [ weight || style || small-caps ]. `none` adds small-caps, style and
    /// weight, in that order, before the end is checked.
    mutating func consumeFontSynthesisShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        if peekIdent() == .None {
            // `consumeIdent(range).releaseNonNull()`: an identifier.
            shorthandAdd(sink, .FontSynthesisSmallCaps, consumeKeyword(peeked: .None))
            shorthandAdd(sink, .FontSynthesisStyle, keywordValue(.None))
            shorthandAdd(sink, .FontSynthesisWeight, keywordValue(.None))
            return atEnd
        }

        var foundWeight = false
        var foundStyle = false
        var foundSmallCaps = false

        while !atEnd {
            // `consumeIdent<Weight, Style, SmallCaps>(range)`: consumes only one of the three.
            let id = peekIdent()
            switch id {
            case .Weight:
                consumeIncludingWhitespace()
                if foundWeight {
                    return false
                }
                foundWeight = true
            case .Style:
                consumeIncludingWhitespace()
                if foundStyle {
                    return false
                }
                foundStyle = true
            case .SmallCaps:
                consumeIncludingWhitespace()
                if foundSmallCaps {
                    return false
                }
                foundSmallCaps = true
            default:
                return false
            }
        }

        shorthandAdd(sink, .FontSynthesisWeight, keywordValue(foundWeight ? .Auto : .None))
        shorthandAdd(sink, .FontSynthesisStyle, keywordValue(foundStyle ? .Auto : .None))
        shorthandAdd(sink, .FontSynthesisSmallCaps, keywordValue(foundSmallCaps ? .Auto : .None))
        return true
    }

    // MARK: - text-decoration-skip

    /// `consumeTextDecorationSkipShorthand`: `none` -> skip-ink none; `auto` or `ink` -> skip-ink auto; added before
    /// the end is checked.
    mutating func consumeTextDecorationSkipShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        // `consumeIdentRaw<None, Auto, Ink>(range)`: consumes only one of the three.
        let skip = peekIdent()
        switch skip {
        case .None:
            consumeIncludingWhitespace()
            shorthandAdd(sink, .TextDecorationSkipInk, keywordValue(.None))
            return atEnd
        case .Auto, .Ink:
            consumeIncludingWhitespace()
            shorthandAdd(sink, .TextDecorationSkipInk, keywordValue(.Auto))
            return atEnd
        default:
            return false
        }
    }

    // MARK: - animation, transition

    /// `isResetOnlyLonghand` in consumeAnimationShorthand.
    private static func isResetOnlyAnimationLonghand(_ longhand: WebCore.CSSPropertyID) -> Bool {
        switch longhand {
        case .AnimationTimeline, .AnimationRangeStart, .AnimationRangeEnd:
            return true
        default:
            return false
        }
    }

    /// `consumeAnimationValueForShorthand`.
    private mutating func animationValueForShorthand(_ property: WebCore.CSSPropertyID, _ calc: PropertyCalc) -> PropertyValue? {
        switch property {
        case .AnimationDelay:
            // `CSSPrimitiveValueResolver<Time<>>::consumeAndResolve`.
            return primitive(PropertyPrimitive(.time), calc)
        case .AnimationDirection:
            return parseGeneratedRule(.singleAnimationDirection, calc)
        case .AnimationDuration:
            return parseGeneratedRule(.singleAnimationDuration, calc)
        case .AnimationFillMode:
            return parseGeneratedRule(.singleAnimationFillMode, calc)
        case .AnimationIterationCount:
            return parseGeneratedRule(.singleAnimationIterationCount, calc)
        case .AnimationName:
            return parseGeneratedRule(.singleAnimationName, calc)
        case .AnimationPlayState:
            return parseGeneratedRule(.singleAnimationPlayState, calc)
        case .AnimationComposition:
            return parseGeneratedRule(.singleAnimationComposition, calc)
        case .AnimationTimeline, .AnimationRangeStart, .AnimationRangeEnd:
            return nil // Reset-only longhands.
        case .AnimationTimingFunction:
            // `consumeEasingFunction(range, state)`: consumer (CSSPropertyConsumerSwiftEffects.swift).
            return easingFunction(unresolved: false, calc)
        case .TransitionBehavior:
            return parseGeneratedRule(.transitionBehaviorValue, calc)
        default:
            assertionFailure("ASSERT_NOT_REACHED") // A debug check, as the C++'s.
            return nil
        }
    }

    /// `consumeTransitionValueForShorthand`.
    private mutating func transitionValueForShorthand(_ property: WebCore.CSSPropertyID, _ calc: PropertyCalc) -> PropertyValue? {
        switch property {
        case .TransitionDelay:
            // `CSSPrimitiveValueResolver<Time<>>`.
            return primitive(PropertyPrimitive(.time), calc)
        case .TransitionDuration:
            // `CSSPrimitiveValueResolver<Time<Nonnegative>>`.
            return primitive(PropertyPrimitive(.time, min: 0), calc)
        case .TransitionProperty:
            return parseGeneratedRule(.singleTransitionPropertyOrNone, calc)
        case .TransitionTimingFunction:
            return easingFunction(unresolved: false, calc)
        case .TransitionBehavior:
            return parseGeneratedRule(.transitionBehaviorValue, calc)
        default:
            assertionFailure("ASSERT_NOT_REACHED")
            return nil
        }
    }

    /// `maxLonghandCount` of both.
    private static var maxAnimationLonghandCount: Int { 11 }

    /// `consumeAnimationShorthand`: per layer, repeatedly the first unparsed longhand, in shorthand order, whose
    /// value parses, until a comma or the end; then the implicit initial value for each unparsed longhand that is not
    /// reset-only. A longhand with an empty list (the reset-only ones) is added null. Adds, then returns whether at
    /// the end.
    mutating func consumeAnimationShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        let longhandCount = longhands.count
        // ASSERT(longhandCount <= maxLonghandCount), a debug check; indexing the arrays traps past 11 as
        // std::array's hardened operator[] does.
        assert(longhandCount <= Self.maxAnimationLonghandCount)
        var lists = ShorthandLayerLists()

        repeat {
            var parsedLonghand: [11 of Bool] = .init(repeating: false)
            repeat {
                var foundProperty = false
                var i = 0
                while i < longhandCount {
                    defer { i += 1 }
                    if parsedLonghand[i] {
                        continue
                    }
                    if let value = animationValueForShorthand(longhands[i], calc) {
                        parsedLonghand[i] = true
                        foundProperty = true
                        lists.append(value, to: i)
                        break
                    }
                }
                if !foundProperty {
                    return false
                }
            } while !atEnd && peekType() != PropertyTokenType.comma

            for i in 0..<longhandCount {
                if !parsedLonghand[i] && !Self.isResetOnlyAnimationLonghand(longhands[i]) {
                    lists.append(WebCore.CSSKeywordValue.implicitInitialValue(), to: i)
                }
                parsedLonghand[i] = false
            }
        } while consumeComma()

        for i in 0..<longhandCount {
            if lists.count(i) == 0 { // Reset-only property.
                shorthandAdd(sink, longhands[i], nil)
            } else {
                shorthandAdd(sink, longhands[i], lists.takeCommaSeparatedList(i))
            }
        }

        return atEnd
    }

    /// `consumeTransitionShorthand`: as animation, with no reset-only longhand; then `none` as a transition-property is
    /// invalid when there are two or more layers, the implicit-initial entries counting. Adds, then
    /// returns whether at the end.
    mutating func consumeTransitionShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        let longhandCount = longhands.count
        assert(longhandCount <= Self.maxAnimationLonghandCount)
        var lists = ShorthandLayerLists()
        // Whether a transition-property list holds `none`, recorded as it is parsed: only a `none` identifier makes
        // that keyword, and the implicit initial value is not `none`.
        var listHasNone: [11 of Bool] = .init(repeating: false)

        repeat {
            var parsedLonghand: [11 of Bool] = .init(repeating: false)
            repeat {
                var foundProperty = false
                var i = 0
                while i < longhandCount {
                    defer { i += 1 }
                    if parsedLonghand[i] {
                        continue
                    }
                    // For transition-property only, the one list the C++ checks.
                    let isProperty = longhands[i] == .TransitionProperty
                    let peeked = isProperty ? peekIdent() : .Invalid
                    if let value = transitionValueForShorthand(longhands[i], calc) {
                        parsedLonghand[i] = true
                        foundProperty = true
                        lists.append(value, to: i)
                        if isProperty && peeked == .None {
                            listHasNone[i] = true
                        }
                        break
                    }
                }
                if !foundProperty {
                    return false
                }
            } while !atEnd && peekType() != PropertyTokenType.comma

            for i in 0..<longhandCount {
                if !parsedLonghand[i] {
                    lists.append(WebCore.CSSKeywordValue.implicitInitialValue(), to: i)
                }
                parsedLonghand[i] = false
            }
        } while consumeComma()

        // `isValidTransitionPropertyList`.
        for i in 0..<longhandCount {
            if longhands[i] == .TransitionProperty && lists.count(i) >= 2 && listHasNone[i] {
                return false
            }
        }

        for i in 0..<longhandCount {
            shorthandAdd(sink, longhands[i], lists.takeCommaSeparatedList(i))
        }

        return atEnd
    }

    // MARK: - block-step

    /// `consumeBlockStepShorthand`: up to four of size, insert, align and round, in any order; the missing ones get
    /// none, margin-box, auto and up.
    mutating func consumeBlockStepShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        var size: PropertyValue? = nil
        var insert: PropertyValue? = nil
        var align: PropertyValue? = nil
        var round: PropertyValue? = nil

        var propertiesParsed = 0
        while propertiesParsed < 4 && !atEnd {
            defer { propertiesParsed += 1 }
            if size == nil {
                size = parseGeneratedRule(.blockStepSize, calc)
                if size != nil {
                    continue
                }
            }
            if insert == nil {
                insert = parseGeneratedRule(.blockStepInsert, calc)
                if insert != nil {
                    continue
                }
            }
            if align == nil {
                align = parseGeneratedRule(.blockStepAlign, calc)
                if align != nil {
                    continue
                }
            }
            if round == nil {
                round = parseGeneratedRule(.blockStepRound, calc)
                if round != nil {
                    continue
                }
            }
            // There has to be at least one valid longhand.
            return false
        }

        guard atEnd else {
            return false
        }

        shorthandAdd(sink, .BlockStepSize, size ?? keywordValue(.None))
        shorthandAdd(sink, .BlockStepInsert, insert ?? keywordValue(.MarginBox))
        shorthandAdd(sink, .BlockStepAlign, align ?? keywordValue(.Auto))
        shorthandAdd(sink, .BlockStepRound, round ?? keywordValue(.Up))
        return true
    }

    // MARK: - overscroll-behavior

    /// `consumeOverscrollBehaviorShorthand`: x, then y or a copy of x. A y that does not parse is added null when the
    /// end follows anyway.
    mutating func consumeOverscrollBehaviorShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        if atEnd {
            return false
        }

        guard let overscrollBehaviorX = parseGeneratedRule(.overscrollBehaviorX, calc) else {
            return false
        }

        let overscrollBehaviorY: PropertyValue?
        consumeWhitespace()
        if atEnd {
            overscrollBehaviorY = overscrollBehaviorX
        } else {
            overscrollBehaviorY = parseGeneratedRule(.overscrollBehaviorY, calc)
            consumeWhitespace()
            if !atEnd {
                return false
            }
        }

        shorthandAdd(sink, .OverscrollBehaviorX, overscrollBehaviorX)
        shorthandAdd(sink, .OverscrollBehaviorY, overscrollBehaviorY)
        return true
    }

    // MARK: - container

    /// `consumeContainerShorthand`: <'container-name'> [ / <'container-type'> ]?.
    mutating func consumeContainerShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        guard let name = parseStylePropertyLonghand(.ContainerName, calc) else {
            return false
        }

        // The lambda consumeSlashType.
        var sawSlash = false
        var type: PropertyValue? = nil
        if !atEnd && consumeSlash() {
            sawSlash = true
            type = parseStylePropertyLonghand(.ContainerType, calc)
        }

        if !atEnd || (sawSlash && type == nil) {
            return false
        }

        shorthandAdd(sink, .ContainerName, name)
        shorthandAdd(sink, .ContainerType, type)
        return true
    }

    // MARK: - contain-intrinsic-size

    /// `consumeContainIntrinsicSizeShorthand`: width, then height or a copy of width.
    mutating func consumeContainIntrinsicSizeShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        // ASSERT(isExposed(ContainIntrinsicSize)), a debug check, not repeated.
        if atEnd {
            return false
        }

        guard let containIntrinsicWidth = parseGeneratedRule(.containIntrinsicWidth, calc) else {
            return false
        }

        let containIntrinsicHeight: PropertyValue
        consumeWhitespace()
        if atEnd {
            containIntrinsicHeight = containIntrinsicWidth
        } else {
            let height = parseGeneratedRule(.containIntrinsicHeight, calc)
            consumeWhitespace()
            guard atEnd, let height else {
                return false
            }
            containIntrinsicHeight = height
        }

        shorthandAdd(sink, .ContainIntrinsicWidth, containIntrinsicWidth)
        shorthandAdd(sink, .ContainIntrinsicHeight, containIntrinsicHeight)
        return true
    }

    // MARK: - transform-origin, perspective-origin

    /// `consumeTransformOriginShorthand`: a one- or two-component position, then an optional <length>.
    mutating func consumeTransformOriginShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        // `consumeOneOrTwoComponentPositionUnresolved`, as oneOrTwoComponentPosition
        // (CSSPropertyConsumerSwiftValues.swift) reads it, into components.
        var components = WebCore.CSSColorSwiftComponents()
        guard let layout = consumePosition(&components, maxComponents: 2, allowsThree: false) else {
            return false
        }
        consumeWhitespace()
        let wasAtEnd = atEnd
        // `CSSPrimitiveValueResolver<Length<>>::consumeAndResolve`.
        let resultZ = primitive(PropertyPrimitive(.length), calc)
        if (resultZ == nil && !wasAtEnd) || !atEnd {
            return false
        }

        let xy = makePositionXYValues(components, layout)
        shorthandAdd(sink, .TransformOriginX, xy.x)
        shorthandAdd(sink, .TransformOriginY, xy.y)
        shorthandAdd(sink, .TransformOriginZ, resultZ)
        return true
    }

    /// `consumePerspectiveOriginShorthand`: a position (`consumePositionUnresolved`, position,
    /// CSSPropertyConsumerSwiftValues.swift), then the end.
    mutating func consumePerspectiveOriginShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        var components = WebCore.CSSColorSwiftComponents()
        guard let layout = consumePosition(&components, maxComponents: 4, allowsThree: false) else {
            return false
        }
        if !atEnd {
            return false
        }
        let xy = makePositionXYValues(components, layout)
        shorthandAdd(sink, .PerspectiveOriginX, xy.x)
        shorthandAdd(sink, .PerspectiveOriginY, xy.y)
        return true
    }

    // MARK: - -webkit-perspective

    /// `consumeWebkitPerspectiveShorthand`: <'perspective'>, or a bare non-negative number; added before the end is
    /// checked.
    mutating func consumeWebkitPerspectiveShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        if let value = parseGeneratedRule(.perspective, calc) {
            shorthandAdd(sink, .Perspective, value)
            return atEnd
        }

        // `CSSPrimitiveValueResolver<Number<Nonnegative>>`.
        if let perspective = primitive(PropertyPrimitive(.number, min: 0), calc) {
            shorthandAdd(sink, .Perspective, perspective)
            return atEnd
        }

        return false
    }

    // MARK: - offset

    /// `consumeOffsetShorthand`: [ <'offset-position'>? [ <'offset-path'> [ <'offset-distance'> || <'offset-rotate'> ]? ]? ]!
    /// [ / <'offset-anchor'> ]?. Adds path, distance, position, anchor, rotate, then returns whether at the end.
    mutating func consumeOffsetShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        let offsetPosition = parseStylePropertyLonghand(.OffsetPosition, calc)
        let offsetPath = parseStylePropertyLonghand(.OffsetPath, calc)

        // Either one of offset-position and offset-path must be present.
        if offsetPosition == nil && offsetPath == nil {
            return false
        }

        // Only parse offset-distance and offset-rotate if offset-path is specified: distance first, and if it is not
        // there, rotate and then distance.
        var offsetDistance: PropertyValue? = nil
        var offsetRotate: PropertyValue? = nil
        if offsetPath != nil {
            offsetDistance = parseStylePropertyLonghand(.OffsetDistance, calc)
            if offsetDistance != nil {
                offsetRotate = parseStylePropertyLonghand(.OffsetRotate, calc)
            } else {
                offsetRotate = parseStylePropertyLonghand(.OffsetRotate, calc)
                offsetDistance = parseStylePropertyLonghand(.OffsetDistance, calc)
            }
        }

        // offset-anchor must follow the slash.
        var offsetAnchor: PropertyValue? = nil
        if consumeSlash() {
            offsetAnchor = parseStylePropertyLonghand(.OffsetAnchor, calc)
            if offsetAnchor == nil {
                return false
            }
        }

        shorthandAdd(sink, .OffsetPath, offsetPath)
        shorthandAdd(sink, .OffsetDistance, offsetDistance)
        shorthandAdd(sink, .OffsetPosition, offsetPosition)
        shorthandAdd(sink, .OffsetAnchor, offsetAnchor)
        shorthandAdd(sink, .OffsetRotate, offsetRotate)
        return atEnd
    }

    // MARK: - hyphenate-limit-chars

    /// `consumeHyphenateLimitCharsShorthand`: total; before or `auto` (implicit); after or a copy of before
    /// (implicit). Adds, then returns whether at the end.
    mutating func consumeHyphenateLimitCharsShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        // ASSERT(state.currentProperty == shorthand.id()), ASSERT(shorthand.length() == 3): debug checks.
        assert(longhands.count == 3)

        guard let total = parseStylePropertyLonghand(longhands[0], calc) else {
            return false
        }

        let parsedBefore = parseStylePropertyLonghand(longhands[1], calc)
        let beforeImplicit = parsedBefore == nil
        let before = parsedBefore ?? keywordValue(.Auto)

        let parsedAfter = parseStylePropertyLonghand(longhands[2], calc)
        let afterImplicit = parsedAfter == nil
        let after = parsedAfter ?? before

        shorthandAdd(sink, longhands[0], total)
        shorthandAdd(sink, longhands[1], before, implicit: beforeImplicit)
        shorthandAdd(sink, longhands[2], after, implicit: afterImplicit)
        return atEnd
    }

    // MARK: - text-box

    /// `consumeTextBoxShorthand`: `normal` adds trim none and edge auto before it is consumed and the end checked;
    /// otherwise trim and edge in either order, an omitted trim being `trim-both`, not the initial value.
    mutating func consumeTextBoxShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        if peekIdent() == .Normal {
            shorthandAdd(sink, .TextBoxTrim, keywordValue(.None))
            shorthandAdd(sink, .TextBoxEdge, keywordValue(.Auto))
            // `consumeIdent(range)`: an identifier.
            consumeIncludingWhitespace()
            return atEnd
        }

        var textBoxTrim: PropertyValue? = nil
        var textBoxEdge: PropertyValue? = nil

        var propertiesParsed = 0
        while propertiesParsed < 2 && !atEnd {
            defer { propertiesParsed += 1 }
            if textBoxTrim == nil {
                textBoxTrim = parseGeneratedRule(.textBoxTrim, calc)
                if textBoxTrim != nil {
                    continue
                }
            }
            if textBoxEdge == nil {
                // `consumeTextBoxEdge(range, state)`: consumer (CSSPropertyConsumerSwiftSmall.swift).
                textBoxEdge = self.textBoxEdge()
                if textBoxEdge != nil {
                    continue
                }
            }
            // There has to be at least one valid longhand.
            return false
        }

        guard atEnd else {
            return false
        }

        shorthandAdd(sink, .TextBoxTrim, textBoxTrim ?? keywordValue(.TrimBoth))
        shorthandAdd(sink, .TextBoxEdge, textBoxEdge ?? keywordValue(.Auto))
        return true
    }

    // MARK: - text-wrap

    /// `consumeTextWrapShorthand`: mode and style in either order; the missing ones `wrap` and `auto`.
    mutating func consumeTextWrapShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        var mode: PropertyValue? = nil
        var style: PropertyValue? = nil

        var propertiesParsed = 0
        while propertiesParsed < 2 && !atEnd {
            defer { propertiesParsed += 1 }
            if mode == nil {
                mode = parseGeneratedRule(.textWrapMode, calc)
                if mode != nil {
                    continue
                }
            }
            if style == nil {
                style = parseGeneratedRule(.textWrapStyle, calc)
                if style != nil {
                    continue
                }
            }
            // If we didn't find at least one match, this is an invalid shorthand and we have to ignore it.
            return false
        }

        guard atEnd else {
            return false
        }

        shorthandAdd(sink, .TextWrapMode, mode ?? keywordValue(.Wrap))
        shorthandAdd(sink, .TextWrapStyle, style ?? keywordValue(.Auto))
        return true
    }

    // MARK: - animation-range, timeline-trigger-activation-range, timeline-trigger-active-range

    /// `consumeAnimationRangeShorthand`: per layer a start (singleAnimationRangeStart,
    /// CSSPropertyConsumerSwiftProperties.swift) and an end, the end, when omitted, derived from the start as the
    /// C++'s `rangeEndValueForStartValue` does. The two lists go to the shorthand's two longhands.
    mutating func consumeAnimationRangeShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        var startList = PropertyValueList()
        var endList = PropertyValueList()
        repeat {
            let startID = peekIdent()
            guard let start = singleAnimationRangeStart(calc) else {
                return false
            }

            let rangeEnd: PropertyValue
            consumeWhitespace()
            if atEnd || peekType() == PropertyTokenType.comma {
                // An omitted end: `normal` for an offset start, else the start's (or its pair's first) keyword. The start
                // is `normal`, a <timeline-range-name> alone or paired with an offset, or an offset, which is every
                // primitive a <length-percentage> makes.
                rangeEnd = keywordValue(WebCore.isTimelineRangeNameForSwift(startID.rawValue) ? startID : .Normal)
            } else {
                let parsedEnd = singleAnimationRangeEnd(calc)
                consumeWhitespace()
                guard let parsedEnd else {
                    return false
                }
                rangeEnd = parsedEnd
            }
            startList.append(start)
            endList.append(rangeEnd)
        } while consumeComma()

        if !atEnd {
            return false
        }

        assert(longhands.count == 2)
        shorthandAdd(sink, longhands[0], makeCommaSeparatedList(startList))
        shorthandAdd(sink, longhands[1], makeCommaSeparatedList(endList))
        return true
    }

    /// `consumeTimelineTriggerActivationRangeShorthand`.
    mutating func consumeTimelineTriggerActivationRangeShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeAnimationRangeShorthand(sink, longhands, calc)
    }

    /// `consumeTimelineTriggerActiveRangeShorthand`.
    mutating func consumeTimelineTriggerActiveRangeShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeAnimationRangeShorthand(sink, longhands, calc)
    }

    // MARK: - scroll-timeline

    /// `consumeScrollTimelineShorthand`: per layer a name and an optional axis (`block`).
    mutating func consumeScrollTimelineShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        var namesList = PropertyValueList()
        var namesCount = 0
        var axesList = PropertyValueList()
        var axesCount = 0

        repeat {
            // A valid scroll-timeline-name is required.
            guard let name = parseGeneratedRule(.singleScrollTimelineName, calc) else {
                return false
            }
            namesList.append(name)
            namesCount &+= 1 // At most the token count.

            // A scroll-timeline-axis is optional.
            if peekType() == PropertyTokenType.comma || atEnd {
                axesList.append(keywordValue(.Block))
            } else if let axis = parseGeneratedRule(.axis, calc) {
                axesList.append(axis)
            } else {
                return false
            }
            axesCount &+= 1 // At most the token count.
        } while consumeComma()

        if namesCount == 0 {
            return false
        }

        shorthandAdd(sink, .ScrollTimelineName, makeCommaSeparatedList(namesList))
        if axesCount != 0 {
            shorthandAdd(sink, .ScrollTimelineAxis, makeCommaSeparatedList(axesList))
        }
        return true
    }

    // MARK: - view-timeline

    /// `consumeSingleViewTimelineInsetItem` (CSSPropertyParserConsumer+Timeline.cpp):
    /// <single-view-timeline-inset>{1,2}, a pair only when the two differ.
    mutating func singleViewTimelineInsetItem(_ calc: PropertyCalc) -> PropertyValue? {
        guard let startInset = parseGeneratedRule(.singleViewTimelineInset, calc) else {
            return nil
        }
        if let endInset = parseGeneratedRule(.singleViewTimelineInset, calc) {
            if !endInset.equals(startInset) {
                return makePair(startInset, endInset, coalescing: false)
            }
        }
        return startInset
    }

    /// `consumeViewTimelineShorthand`: per layer a name, then an axis, an inset and the axis again (the two may come in
    /// either order); either may be omitted (`block`, `auto`), not both when anything follows the name.
    mutating func consumeViewTimelineShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        var namesList = PropertyValueList()
        var namesCount = 0
        var axesList = PropertyValueList()
        var insetsList = PropertyValueList()

        repeat {
            // A valid view-timeline-name is required.
            guard let name = parseGeneratedRule(.singleScrollTimelineName, calc) else {
                return false
            }
            namesList.append(name)
            namesCount &+= 1 // At most the token count.

            // Both a view-timeline-axis and a view-timeline-inset are optional.
            if peekType() != PropertyTokenType.comma && !atEnd {
                var axis = parseGeneratedRule(.axis, calc)
                let insets = singleViewTimelineInsetItem(calc)
                // The order of axis and inset is not fixed: the axis is tried again.
                if axis == nil {
                    axis = parseGeneratedRule(.axis, calc)
                }
                if axis == nil && insets == nil {
                    return false
                }
                axesList.append(axis ?? keywordValue(.Block))
                insetsList.append(insets ?? keywordValue(.Auto))
            } else {
                axesList.append(keywordValue(.Block))
                insetsList.append(keywordValue(.Auto))
            }
        } while consumeComma()

        if namesCount == 0 {
            return false
        }

        shorthandAdd(sink, .ViewTimelineName, makeCommaSeparatedList(namesList))
        shorthandAdd(sink, .ViewTimelineAxis, makeCommaSeparatedList(axesList))
        shorthandAdd(sink, .ViewTimelineInset, makeCommaSeparatedList(insetsList))
        return true
    }

    // MARK: - position-try

    /// `consumePositionTryShorthand`: <'position-try-order'>? <'position-try-fallbacks'>; adds, then returns whether at
    /// the end.
    mutating func consumePositionTryShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        let order = parseStylePropertyLonghand(.PositionTryOrder, calc)
        guard let fallbacks = parseStylePropertyLonghand(.PositionTryFallbacks, calc) else {
            return false
        }

        shorthandAdd(sink, .PositionTryOrder, order)
        shorthandAdd(sink, .PositionTryFallbacks, fallbacks)
        return atEnd
    }

    // MARK: - marker

    /// `consumeMarkerShorthand`: one marker-start value, the same object for start, mid and end.
    mutating func consumeMarkerShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        guard let marker = parseStylePropertyLonghand(.MarkerStart, calc), atEnd else {
            return false
        }

        shorthandAdd(sink, .MarkerStart, marker)
        shorthandAdd(sink, .MarkerMid, marker)
        shorthandAdd(sink, .MarkerEnd, marker)
        return true
    }
}

#endif // USE_SWIFT_CSS_SHORTHANDS_AND_TYPED_OM
