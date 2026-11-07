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

// The shorthands of CSSPropertyParserCustom.h, as `PropertyParser` methods (CSSPropertyConsumerSwift.swift): the three
// patterns the generator dispatches (consume<pattern>Shorthand, CSSProperties.json "shorthand-pattern"), the place-*
// and gap pair, and the keyword-mapping and small shorthands. The box shorthands (border, border-radius, corner,
// border-image, mask-border) are in CSSPropertyParserShorthandsBox.swift.
//
// Each matches the C++ function of the same name, including the longhands it adds before failing: parseValue
// removes them, and consumeStyleProperty keeps them ahead of the substitution values.
//
// Longhands are parsed with the shorthand as the current property, so with the shorthand's quirks.

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
internal import WebCore_Private.Core.CSSPosition
internal import WebCore_Private.Core.CSSPositionValue
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftTypes

/// The sink a shorthand adds its longhands to.
typealias ShorthandSink = WebCore.CSSPropertyConsumerSwiftShorthandSink

extension PropertyParser {
    // MARK: - Adding longhands

    /// `result.addPropertyForCurrentShorthand(state, longhand, value, implicit)`: a null value is the implicit initial
    /// value (CSSPropertyParserResult.cpp).
    @inline(always)
    func shorthandAdd(_ sink: borrowing ShorthandSink, _ longhand: WebCore.CSSPropertyID, _ value: PropertyValue?, implicit: Bool = false) {
        sink.addLonghand(longhand.rawValue, value, implicit)
    }

    /// `consumeIdent<CSSValueID::id>(range)`: the keyword `id`, consumed with the whitespace after it, or nil.
    @inline(always)
    mutating func shorthandConsumeIdent(_ id: WebCore.CSSValueID) -> PropertyValue? {
        guard peekType() == PropertyTokenType.ident, peekIdent() == id else {
            return nil
        }
        return consumeKeyword(peeked: id)
    }

    /// `consumeIdentRaw(range)`: the CSSValueID of an identifier (Invalid for an unknown one), consumed with the
    /// whitespace after it, or nil for a token of another type (CSSPropertyParserConsumer+Ident.cpp).
    @inline(always)
    mutating func shorthandConsumeIdentRaw() -> WebCore.CSSValueID? {
        guard peekType() == PropertyTokenType.ident else {
            return nil
        }
        let id = peekIdent()
        consumeIncludingWhitespace()
        return id
    }

    // MARK: - The generator's patterns (CSSPropertyParserCustom.h)

    /// `consumeStandardSpaceSeparatedShorthand`: repeatedly the first unparsed longhand, in order, that
    /// parses, until the end; then every longhand, a missing one null (implicit initial).
    mutating func consumeStandardSpaceSeparatedShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        // ASSERT(shorthand.length() <= 6) in the C++, a debug check; std::array<RefPtr<CSSValue>, 6>.
        assert(longhands.count <= 6)
        var values = [6 of PropertyValue?](repeating: nil)
        repeat {
            var foundLonghand = false
            var i = 0
            while !foundLonghand && i < longhands.count {
                if values[i] == nil {
                    values[i] = parseStylePropertyLonghand(longhands[i], calc)
                    if values[i] != nil {
                        foundLonghand = true
                    }
                }
                i += 1
            }
            if !foundLonghand {
                return false
            }
        } while !atEnd

        for i in 0..<longhands.count {
            shorthandAdd(sink, longhands[i], values[i])
        }
        return true
    }

    /// `consumeCoalescingPairShorthand`: start, and end or a copy of start (implicit). Adds both, then
    /// returns whether at the end (the adds stay on a failure).
    mutating func consumeCoalescingPairShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        assert(longhands.count == 2)
        guard let start = parseStylePropertyLonghand(longhands[0], calc) else {
            return false
        }
        let end = parseStylePropertyLonghand(longhands[1], calc)
        let endImplicit = end == nil

        shorthandAdd(sink, longhands[0], start)
        shorthandAdd(sink, longhands[1], end ?? start, implicit: endImplicit)
        return atEnd
    }

    /// `consumeCoalescingQuadShorthand`: top; right only after top, bottom only after right, left only after
    /// bottom; a missing right or bottom copies top, a missing left copies right (implicit). Adds all four, then returns
    /// whether at the end.
    mutating func consumeCoalescingQuadShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        assert(longhands.count == 4)
        guard let top = parseStylePropertyLonghand(longhands[0], calc) else {
            return false
        }
        let right = parseStylePropertyLonghand(longhands[1], calc)
        var bottom: PropertyValue? = nil
        var left: PropertyValue? = nil
        if right != nil {
            bottom = parseStylePropertyLonghand(longhands[2], calc)
            if bottom != nil {
                left = parseStylePropertyLonghand(longhands[3], calc)
            }
        }

        let rightImplicit = right == nil
        let bottomImplicit = bottom == nil
        let leftImplicit = left == nil
        let rightValue = right ?? top
        // `left = right` runs after `right = top`, so a missing left copies the right as completed.
        let leftValue = left ?? rightValue

        shorthandAdd(sink, longhands[0], top)
        shorthandAdd(sink, longhands[1], rightValue, implicit: rightImplicit)
        shorthandAdd(sink, longhands[2], bottom ?? top, implicit: bottomImplicit)
        shorthandAdd(sink, longhands[3], leftValue, implicit: leftImplicit)
        return atEnd
    }

    // MARK: - place-content, place-items, place-self, gap

    /// `consumeAlignShorthand`: the first longhand, then the second, parsed again from the same tokens at the end and
    /// otherwise from what follows. Adds nothing unless both parse and the end is reached.
    mutating func consumeAlignShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        assert(longhands.count == 2)
        // `auto rangeCopy = range`: a CSSParserTokenRange is [index, end).
        let rangeCopyIndex = index
        let rangeCopyEnd = end

        guard let prop1 = parseStylePropertyLonghand(longhands[0], calc) else {
            return false
        }

        if atEnd {
            index = rangeCopyIndex
            end = rangeCopyEnd
        }

        guard let prop2 = parseStylePropertyLonghand(longhands[1], calc), atEnd else {
            return false
        }

        shorthandAdd(sink, longhands[0], prop1)
        shorthandAdd(sink, longhands[1], prop2)
        return true
    }

    // MARK: - border-spacing

    /// `consumeBorderSpacingShorthand`: <length [0,∞]>{1,2}.
    mutating func consumeBorderSpacingShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        let length = PropertyPrimitive(.length, min: 0)
        guard let horizontalSpacing = primitive(length, calc) else {
            return false
        }
        var verticalSpacing: PropertyValue? = horizontalSpacing
        if !atEnd {
            verticalSpacing = primitive(length, calc)
        }
        guard let verticalSpacing, atEnd else {
            return false
        }

        shorthandAdd(sink, .WebkitBorderHorizontalSpacing, horizontalSpacing)
        shorthandAdd(sink, .WebkitBorderVerticalSpacing, verticalSpacing)
        return true
    }

    // MARK: - columns

    /// `consumeColumnsShorthand`: up to two values; `auto` is consumed for either and decides nothing.
    mutating func consumeColumnsShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        var columnWidth: PropertyValue? = nil
        var columnCount: PropertyValue? = nil

        var propertiesParsed = 0
        while propertiesParsed < 2 && !atEnd {
            defer { propertiesParsed += 1 }
            if peekIdent() == .Auto {
                // `consumeIdent(range)`: an identifier, so it consumes.
                consumeIncludingWhitespace()
            } else {
                if columnWidth == nil {
                    columnWidth = parseStylePropertyLonghand(.ColumnWidth, calc)
                    if columnWidth != nil {
                        continue
                    }
                }
                if columnCount == nil {
                    columnCount = parseStylePropertyLonghand(.ColumnCount, calc)
                    if columnCount != nil {
                        continue
                    }
                }
                return false
            }
        }

        guard atEnd else {
            return false
        }

        shorthandAdd(sink, .ColumnWidth, columnWidth)
        shorthandAdd(sink, .ColumnCount, columnCount)
        return true
    }

    // MARK: - flex

    /// `isFlexBasisIdent` in consumeFlexShorthand.
    private static func isFlexBasisIdent(_ id: WebCore.CSSValueID) -> Bool {
        switch id {
        case .Auto, .Content, .Intrinsic, .MinIntrinsic, .MinContent, .WebkitMinContent, .MaxContent, .WebkitMaxContent,
            .WebkitFillAvailable, .Stretch, .FitContent, .WebkitFitContent:
            return true
        default:
            return false
        }
    }

    /// `consumeFlexShorthand`: none | [ <'flex-grow'> <'flex-shrink'>? || <'flex-basis'> ].
    mutating func consumeFlexShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        var flexGrow: PropertyValue? = nil
        var flexShrink: PropertyValue? = nil
        var flexBasis: PropertyValue? = nil

        if peekIdent() == .None {
            flexGrow = WebCore.CSSPrimitiveValue.create(0, .Number).get()
            flexShrink = WebCore.CSSPrimitiveValue.create(0, .Number).get()
            flexBasis = keywordValue(.Auto)
            consumeIncludingWhitespace()
        } else {
            // `while (!range.atEnd() && index++ < 3)`: index is incremented only when the range is not at its end,
            // and also on the test that ends the loop (to 4), which nothing reads but `index == 0`.
            var index: UInt32 = 0
            while !atEnd {
                let previous = index
                index &+= 1 // At most 4.
                guard previous < 3 else {
                    break
                }
                if let number = numeric(PropertyPrimitive(.number, min: 0), calc) {
                    if flexGrow == nil {
                        flexGrow = number.value
                    } else if flexShrink == nil {
                        flexShrink = number.value
                    } else if number.isKnownZero {
                        // `number->isZero() == true`: an unresolved calc() is not zero.
                        flexBasis = WebCore.CSSPrimitiveValue.create(0, .Px).get()
                    } else {
                        return false
                    }
                } else if flexBasis == nil {
                    if Self.isFlexBasisIdent(peekIdent()) {
                        flexBasis = consumeKeyword()
                    }
                    if flexBasis == nil {
                        flexBasis = primitive(PropertyPrimitive(.lengthPercentage, min: 0), calc)
                    }
                    if index == 2 && !atEnd {
                        return false
                    }
                }
            }
            if index == 0 {
                return false
            }
            if flexGrow == nil {
                flexGrow = WebCore.CSSPrimitiveValue.create(1, .Number).get()
            }
            if flexShrink == nil {
                flexShrink = WebCore.CSSPrimitiveValue.create(1, .Number).get()
            }
            if flexBasis == nil {
                flexBasis = WebCore.CSSPrimitiveValue.create(0, .Percentage).get()
            }
        }

        guard atEnd, let flexGrow, let flexShrink, let flexBasis else {
            return false
        }

        shorthandAdd(sink, .FlexGrow, flexGrow)
        shorthandAdd(sink, .FlexShrink, flexShrink)
        shorthandAdd(sink, .FlexBasis, flexBasis)
        return true
    }

    // MARK: - page-break-*, -webkit-column-break-*

    /// `mapFromPageBreakBetween`.
    private static func mapFromPageBreakBetween(_ value: WebCore.CSSValueID) -> WebCore.CSSValueID {
        if value == .Always {
            return .Page
        }
        if value == .Auto || value == .Avoid || value == .Left || value == .Right {
            return value
        }
        return .Invalid
    }

    /// `mapFromColumnBreakBetween`.
    private static func mapFromColumnBreakBetween(_ value: WebCore.CSSValueID) -> WebCore.CSSValueID {
        if value == .Always {
            return .Column
        }
        if value == .Auto {
            return value
        }
        if value == .Avoid {
            return .AvoidColumn
        }
        return .Invalid
    }

    /// `mapFromColumnRegionOrPageBreakInside`.
    private static func mapFromColumnRegionOrPageBreakInside(_ value: WebCore.CSSValueID) -> WebCore.CSSValueID {
        if value == .Auto || value == .Avoid {
            return value
        }
        return .Invalid
    }

    /// What each of the six legacy break shorthands maps its keyword with.
    enum BreakShorthandMap {
        case pageBreakBetween
        case columnBreakBetween
        case columnRegionOrPageBreakInside
    }

    /// The six bodies of consumePageBreak{After,Before,Inside}Shorthand and
    /// consumeWebkitColumnBreak{After,Before,Inside}Shorthand, which differ only in the map and the longhand: one
    /// identifier, the end, then a mapped keyword other than Invalid.
    mutating func consumeBreakShorthand(
        _ sink: borrowing ShorthandSink,
        _ map: BreakShorthandMap,
        _ longhand: WebCore.CSSPropertyID
    ) -> Bool {
        guard let keyword = shorthandConsumeIdentRaw(), atEnd else {
            return false
        }
        let value: WebCore.CSSValueID
        switch map {
        case .pageBreakBetween: value = Self.mapFromPageBreakBetween(keyword)
        case .columnBreakBetween: value = Self.mapFromColumnBreakBetween(keyword)
        case .columnRegionOrPageBreakInside: value = Self.mapFromColumnRegionOrPageBreakInside(keyword)
        }
        if value == .Invalid {
            return false
        }

        shorthandAdd(sink, longhand, keywordValue(value))
        return true
    }

    /// `consumePageBreakAfterShorthand`.
    mutating func consumePageBreakAfterShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeBreakShorthand(sink, .pageBreakBetween, .BreakAfter)
    }

    /// `consumePageBreakBeforeShorthand`.
    mutating func consumePageBreakBeforeShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeBreakShorthand(sink, .pageBreakBetween, .BreakBefore)
    }

    /// `consumePageBreakInsideShorthand`.
    mutating func consumePageBreakInsideShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeBreakShorthand(sink, .columnRegionOrPageBreakInside, .BreakInside)
    }

    /// `consumeWebkitColumnBreakAfterShorthand`.
    mutating func consumeWebkitColumnBreakAfterShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeBreakShorthand(sink, .columnBreakBetween, .BreakAfter)
    }

    /// `consumeWebkitColumnBreakBeforeShorthand`.
    mutating func consumeWebkitColumnBreakBeforeShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeBreakShorthand(sink, .columnBreakBetween, .BreakBefore)
    }

    /// `consumeWebkitColumnBreakInsideShorthand`.
    mutating func consumeWebkitColumnBreakInsideShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeBreakShorthand(sink, .columnRegionOrPageBreakInside, .BreakInside)
    }

    // MARK: - -webkit-text-orientation

    /// `consumeWebkitTextOrientationShorthand`: `sideways-right` is `sideways`; any other keyword valid for
    /// text-orientation is itself.
    mutating func consumeWebkitTextOrientationShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        var keyword: PropertyValue? = nil
        let valueID = peekIdent()
        if valueID == .SidewaysRight {
            keyword = keywordValue(.Sideways)
            consumeIncludingWhitespace()
        } else if sink.isKeywordValid(WebCore.CSSPropertyID.TextOrientation.rawValue, valueID.rawValue) {
            // `consumeIdent(range)`: valueID is a keyword, so the token is an identifier.
            keyword = consumeKeyword(peeked: valueID)
        }
        guard let keyword, atEnd else {
            return false
        }

        shorthandAdd(sink, .TextOrientation, keyword)
        return true
    }

    // MARK: - overflow

    /// `consumeOverflowShorthand`: each value a keyword valid for overflow-y (the two-value form
    /// accepts -webkit-paged-x/y for overflow-x); one -webkit-paged-x/y value makes overflow-x `auto`.
    mutating func consumeOverflowShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        // `range.consumeIncludingWhitespace().id()`: any token, its id Invalid unless an identifier.
        var xValueID = peekIdent()
        consumeIncludingWhitespace()
        guard sink.isKeywordValid(WebCore.CSSPropertyID.OverflowY.rawValue, xValueID.rawValue) else {
            return false
        }

        let yValueID: WebCore.CSSValueID
        if atEnd {
            yValueID = xValueID
            if xValueID == .WebkitPagedX || xValueID == .WebkitPagedY {
                xValueID = .Auto
            }
        } else {
            yValueID = peekIdent()
            consumeIncludingWhitespace()
        }

        guard sink.isKeywordValid(WebCore.CSSPropertyID.OverflowY.rawValue, yValueID.rawValue), atEnd else {
            return false
        }

        shorthandAdd(sink, .OverflowX, keywordValue(xValueID))
        shorthandAdd(sink, .OverflowY, keywordValue(yValueID))
        return true
    }

    // MARK: - list-style

    /// `consumeListStyleShorthand`: any order; `none` counted, and given to type and implicitly to image. Adds the three,
    /// then returns whether at the end (always true there: the loop runs to the end or returns false).
    mutating func consumeListStyleShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        var position: PropertyValue? = nil
        var image: PropertyValue? = nil
        var type: PropertyValue? = nil
        var noneCount: UInt32 = 0

        while !atEnd {
            if peekIdent() == .None {
                noneCount &+= 1 // At most the token count.
                consumeIncludingWhitespace()
                continue
            }
            if position == nil {
                position = parseStylePropertyLonghand(.ListStylePosition, calc)
                if position != nil {
                    continue
                }
            }
            if image == nil {
                image = parseStylePropertyLonghand(.ListStyleImage, calc)
                if image != nil {
                    continue
                }
            }
            if type == nil {
                type = parseStylePropertyLonghand(.ListStyleType, calc)
                if type != nil {
                    continue
                }
            }
            return false
        }

        // `noneCount > static_cast<unsigned>(!image + !type)`.
        let unset: UInt32 = (image == nil ? 1 : 0) + (type == nil ? 1 : 0)
        if noneCount > unset {
            return false
        }

        if noneCount == 2 {
            image = nil
            type = keywordValue(.None)
        } else if noneCount == 1 {
            if type == nil {
                type = keywordValue(.None)
            }
        }

        shorthandAdd(sink, .ListStylePosition, position)
        shorthandAdd(sink, .ListStyleImage, image)
        shorthandAdd(sink, .ListStyleType, type)
        return atEnd
    }

    // MARK: - line-clamp, -webkit-line-clamp

    mutating func consumeLineClampShorthand(
        _ sink: borrowing ShorthandSink,
        _ property: WebCore.CSSPropertyID,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeLineClampShorthand(sink, isLegacyLineClamp: property == .WebkitLineClamp, calc)
    }

    /// `consumeLineClampShorthand`. `none` adds max-lines `auto`, continue `normal` and
    /// block-ellipsis `no-ellipsis`, in that order, before checking the end.
    mutating func consumeLineClampShorthand(_ sink: borrowing ShorthandSink, isLegacyLineClamp: Bool, _ calc: PropertyCalc) -> Bool {
        if peekIdent() == .None {
            shorthandAdd(sink, .MaxLines, keywordValue(.Auto))
            shorthandAdd(sink, .Continue, keywordValue(.Normal))
            shorthandAdd(sink, .BlockEllipsis, keywordValue(.NoEllipsis))
            consumeIncludingWhitespace()
            return atEnd
        }

        var numLines: PropertyValue? = nil
        var blockEllipsis: PropertyValue? = nil
        var autoKeyword: PropertyValue? = nil
        var webkitLegacy: PropertyValue? = nil

        repeat {
            if webkitLegacy == nil {
                webkitLegacy = shorthandConsumeIdent(.WebkitLegacy)
                if webkitLegacy != nil {
                    break
                }
            }
            if autoKeyword == nil {
                autoKeyword = shorthandConsumeIdent(.Auto)
                if autoKeyword != nil {
                    if blockEllipsis != nil && numLines != nil {
                        return false
                    }
                    continue
                }
            }
            if blockEllipsis == nil {
                blockEllipsis = parseGeneratedRule(.blockEllipsis, calc)
                if blockEllipsis != nil {
                    continue
                }
            }
            if numLines == nil {
                numLines = primitive(PropertyPrimitive(.integer, min: 1), calc)
                if numLines != nil {
                    if blockEllipsis != nil && autoKeyword != nil {
                        return false
                    }
                    continue
                }
            }
            break
        } while !atEnd

        if isLegacyLineClamp && (autoKeyword != nil || blockEllipsis != nil || webkitLegacy != nil) {
            return false
        }
        if numLines == nil && autoKeyword == nil && blockEllipsis == nil {
            return false
        }

        let maxLines: PropertyValue
        if let numLines, let autoKeyword {
            maxLines = makeSpaceSeparatedList(numLines, autoKeyword)
        } else if let numLines {
            maxLines = numLines
        } else if let autoKeyword {
            maxLines = autoKeyword
        } else {
            maxLines = keywordValue(.Auto)
        }

        shorthandAdd(sink, .MaxLines, maxLines)
        shorthandAdd(sink, .BlockEllipsis, blockEllipsis ?? keywordValue(.Ellipsis))
        shorthandAdd(sink, .Continue, keywordValue(isLegacyLineClamp || webkitLegacy != nil ? .WebkitLegacy : .Collapse))
        return atEnd
    }

    // MARK: - white-space

    /// `consumeWhiteSpaceShorthand`: `normal`, `pre`, `pre-line` or `pre-wrap` alone, mapped; otherwise up to three of
    /// white-space-collapse, text-wrap-mode and (behind its setting) white-space-trim, in any order.
    mutating func consumeWhiteSpaceShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        var whiteSpaceCollapse: PropertyValue? = nil
        var textWrapMode: PropertyValue? = nil
        var whiteSpaceTrim: PropertyValue? = nil

        // `consumeIdentRaw<Normal, Pre, PreLine, PreWrap>(range)`.
        let single = peekIdent()
        if single == .Normal || single == .Pre || single == .PreLine || single == .PreWrap {
            consumeIncludingWhitespace()
            switch single {
            case .Normal:
                whiteSpaceCollapse = keywordValue(.Collapse)
                textWrapMode = keywordValue(.Wrap)
            case .Pre:
                whiteSpaceCollapse = keywordValue(.Preserve)
                textWrapMode = keywordValue(.Nowrap)
            case .PreLine:
                whiteSpaceCollapse = keywordValue(.PreserveBreaks)
                textWrapMode = keywordValue(.Wrap)
            default: // .PreWrap
                whiteSpaceCollapse = keywordValue(.Preserve)
                textWrapMode = keywordValue(.Wrap)
            }
            whiteSpaceTrim = keywordValue(.None)
        } else {
            var propertiesParsed = 0
            while propertiesParsed < 3 && !atEnd {
                defer { propertiesParsed += 1 }
                if whiteSpaceCollapse == nil {
                    whiteSpaceCollapse = parseGeneratedRule(.whiteSpaceCollapse, calc)
                    if whiteSpaceCollapse != nil {
                        continue
                    }
                }
                if textWrapMode == nil {
                    textWrapMode = parseGeneratedRule(.textWrapMode, calc)
                    if textWrapMode != nil {
                        continue
                    }
                }
                if whiteSpaceTrim == nil && tokens.value.isExposed(WebCore.CSSPropertyID.WhiteSpaceTrim.rawValue) {
                    whiteSpaceTrim = parseGeneratedRule(.whiteSpaceTrim, calc)
                    if whiteSpaceTrim != nil {
                        continue
                    }
                }
                return false
            }
        }

        guard atEnd else {
            return false
        }

        shorthandAdd(sink, .WhiteSpaceCollapse, whiteSpaceCollapse ?? keywordValue(.Collapse))
        shorthandAdd(sink, .TextWrapMode, textWrapMode ?? keywordValue(.Wrap))
        shorthandAdd(sink, .WhiteSpaceTrim, whiteSpaceTrim ?? keywordValue(.None))
        return true
    }
}

// MARK: - Position values

/// The <length-percentage> of a position's component: its calc() value, or its unit and value.
private func positionLengthPercentage(
    _ component: borrowing WebCore.CSSColorSwiftComponents.Component
) -> WebCore.CSSPositionSwiftLengthPercentage {
    typealias LengthPercentage = WebCore.CSSPositionSwiftLengthPercentage
    if let calc = Optional(fromCxx: component.calc) {
        return LengthPercentage(LengthPercentage.Calc(calc))
    }
    // A CSS::LengthPercentageUnit: consumePosition writes no other unit. makeColorSwiftComponent's
    // RELEASE_ASSERT(unit < UnitTraits::count): Percentage is the last unit (CSSPropertyParserSwift.cpp pins it), and
    // an imported enum's init(rawValue:) does not check its value.
    guard component.unit <= WebCore.CSS.LengthPercentageUnit.Percentage.rawValue,
        let unit = WebCore.CSS.LengthPercentageUnit(rawValue: component.unit)
    else {
        preconditionFailure()
    }
    return LengthPercentage(LengthPercentage.Raw(unit, component.value))
}

/// The CSSPositionXValue and CSSPositionYValue of the position in `components` at `layout`, as setPositionResult
/// describes it: an axis with a length is its keyword and that length, else its one component, a keyword or a
/// <length-percentage>.
func makePositionXYValues(
    _ components: borrowing WebCore.CSSColorSwiftComponents,
    _ layout: UInt16
) -> (x: PropertyValue, y: PropertyValue) {
    typealias Keyword = WebCore.CSS.Keyword
    let horizontal = components[Int(layout & 0xf)]
    let positionX: WebCore.CSS.PositionX
    if layout & 0xf0 != 0xf0 {
        let length = positionLengthPercentage(components[Int((layout >> 4) & 0xf)])
        let edge: WebCore.CSS.FourComponentPositionHorizontal
        switch WebCore.CSSValueID(rawValue: horizontal.symbol) {
        case .Left: edge = .init(offset: .init(.fromAlternative(Keyword.Left()), length))
        case .Right: edge = .init(offset: .init(.fromAlternative(Keyword.Right()), length))
        case .XStart: edge = .init(offset: .init(.fromAlternative(Keyword.XStart()), length))
        case .XEnd: edge = .init(offset: .init(.fromAlternative(Keyword.XEnd()), length))
        default: preconditionFailure()
        }
        positionX = WebCore.CSS.PositionX(consuming: .fromAlternative(edge))
    } else {
        let offset: WebCore.CSS.TwoComponentPositionHorizontal
        if horizontal.type != UInt8(WebCore.CSSColorSwiftChannelNone) {
            offset = .init(offset: .fromAlternative(positionLengthPercentage(horizontal)))
        } else {
            switch WebCore.CSSValueID(rawValue: horizontal.symbol) {
            case .Left: offset = .init(offset: .fromAlternative(Keyword.Left()))
            case .Right: offset = .init(offset: .fromAlternative(Keyword.Right()))
            case .Center: offset = .init(offset: .fromAlternative(Keyword.Center()))
            case .XStart: offset = .init(offset: .fromAlternative(Keyword.XStart()))
            case .XEnd: offset = .init(offset: .fromAlternative(Keyword.XEnd()))
            default: preconditionFailure()
            }
        }
        positionX = WebCore.CSS.PositionX(consuming: .fromAlternative(offset))
    }

    let vertical = components[Int((layout >> 8) & 0xf)]
    let positionY: WebCore.CSS.PositionY
    if layout & 0xf000 != 0xf000 {
        let length = positionLengthPercentage(components[Int((layout >> 12) & 0xf)])
        let edge: WebCore.CSS.FourComponentPositionVertical
        switch WebCore.CSSValueID(rawValue: vertical.symbol) {
        case .Top: edge = .init(offset: .init(.fromAlternative(Keyword.Top()), length))
        case .Bottom: edge = .init(offset: .init(.fromAlternative(Keyword.Bottom()), length))
        case .YStart: edge = .init(offset: .init(.fromAlternative(Keyword.YStart()), length))
        case .YEnd: edge = .init(offset: .init(.fromAlternative(Keyword.YEnd()), length))
        default: preconditionFailure()
        }
        positionY = WebCore.CSS.PositionY(consuming: .fromAlternative(edge))
    } else {
        let offset: WebCore.CSS.TwoComponentPositionVertical
        if vertical.type != UInt8(WebCore.CSSColorSwiftChannelNone) {
            offset = .init(offset: .fromAlternative(positionLengthPercentage(vertical)))
        } else {
            switch WebCore.CSSValueID(rawValue: vertical.symbol) {
            case .Top: offset = .init(offset: .fromAlternative(Keyword.Top()))
            case .Bottom: offset = .init(offset: .fromAlternative(Keyword.Bottom()))
            case .Center: offset = .init(offset: .fromAlternative(Keyword.Center()))
            case .YStart: offset = .init(offset: .fromAlternative(Keyword.YStart()))
            case .YEnd: offset = .init(offset: .fromAlternative(Keyword.YEnd()))
            default: preconditionFailure()
            }
        }
        positionY = WebCore.CSS.PositionY(consuming: .fromAlternative(offset))
    }

    return (WebCore.CSSPositionXValue.create(consuming: positionX).get(), WebCore.CSSPositionYValue.create(consuming: positionY).get())
}

#endif // USE_SWIFT_CSS_SHORTHANDS_AND_TYPED_OM
