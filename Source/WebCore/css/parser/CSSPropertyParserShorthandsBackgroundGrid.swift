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

// The background and grid shorthands of CSSPropertyParserCustom.h, as `PropertyParser` methods: background and
// -webkit-mask (consumeBackgroundShorthand), mask, background-position and -webkit-mask-position, mask-position,
// -webkit-background-size, grid-row and grid-column (consumeGridItemPositionShorthand), grid-area, grid-template and
// grid. Each follows the C++ as CSSPropertyParserShorthands.swift's header describes. gap and its alias grid-gap are
// consumeAlignShorthand, in CSSPropertyParserShorthands.swift; background-repeat and mask-repeat are longhands.
//
// Each has the signature the generated dispatch calls: `(sink, ShorthandLonghands.<name>.span, calc)`.
//
// Where the C++ shorthand holds a CSS:: value between consumers (a position, a <grid-line>, the track lists and the
// area map of grid-template's areas form), the Swift holds the parts the Swift consumers of
// CSSPropertyConsumerSwiftValues.swift and CSSPropertyConsumerSwiftGrid.swift consume into (CSSColorSwiftComponents
// and a layout, ShorthandGridLineParts, CSSGridSwiftParts), and the builders of CSSPropertyConsumerSwiftBuilders.h make
// the values.

#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch

internal import WebCore_Private.Core.CSSParserToken
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftBuilders
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftTypes

/// A comma-separated list a shorthand builds per longhand, stored bare when it has one value:
/// `list.size() == 1 ? list[0] : CSSValueList::createCommaSeparated(list)`, and
/// `consumeListSeparatedBy<',', OneOrMore, ListOptimization::SingleValue>` (CSSPropertyParserConsumer+List.h).
/// The first value is held apart, so a one-value list makes no CSSValueListBuilder.
struct ShorthandCommaSeparatedSingleValueList: ~Copyable {
    private var first: PropertyValue? = nil
    private var list = PropertyValueList()
    /// `list.size()`.
    private(set) var count = 0

    mutating func append(_ value: PropertyValue) {
        if count == 0 {
            first = value
        } else {
            if count == 1, let first {
                list.append(first)
            }
            list.append(value)
        }
        count &+= 1 // At most the token count.
    }

    /// The bare value of a one-value list, else the comma-separated list (empty if there are none).
    consuming func takeValue() -> PropertyValue? {
        if count == 1 {
            return first.take()
        }
        return WebCore.CSSValueList.createCommaSeparated(list.take()).get()
    }
}

/// The values a shorthand of comma-separated layers gives its longhands, one a layer at most: the C++'s
/// `std::array<CSSValueListBuilder, maxLonghandCount>` of background, mask and -webkit-mask (10) and of animation and
/// transition (11). Each longhand's list is made once, at the end, in the order its values were appended.
///
/// Value `k` of longhand `i` is slot `k * 11 + i`: a longhand's first four values are held inline, the rest in
/// `overflowValues`, from slot 44 on.
struct ShorthandLayerLists: ~Copyable {
    private var inline: [44 of PropertyValue?] = .init(repeating: nil)
    private var overflowValues = UniqueArray<PropertyValue?>()
    /// `list.size()` of each longhand's list. Indexing it traps past 11, as hardened std::array does.
    private var counts: [11 of Int] = .init(repeating: 0)

    /// `longhands[longhand].size()`.
    @inline(always)
    func count(_ longhand: Int) -> Int {
        counts[longhand]
    }

    /// `longhands[longhand].append(value)`.
    @inline(always)
    mutating func append(_ value: consuming PropertyValue, to longhand: Int) {
        let index = counts[longhand]
        let slot = index &* 11 &+ longhand // index is at most the token count, longhand below 11: no overflow.
        if slot < 44 {
            inline[slot] = value
        } else {
            appendOverflowValue(value, at: slot - 44)
        }
        counts[longhand] = index &+ 1 // At most the token count.
    }

    @inline(never)
    private mutating func appendOverflowValue(_ value: consuming PropertyValue, at index: Int) {
        while overflowValues.count <= index {
            overflowValues.append(nil)
        }
        overflowValues[index] = value
    }

    /// Moves out value `index` of `longhand`, which is below its count.
    @inline(always)
    private mutating func take(_ index: Int, of longhand: Int) -> PropertyValue {
        let slot = index &* 11 &+ longhand // As in `append`.
        let value = slot < 44 ? inline[slot].take() : overflowValues[slot - 44]
        guard let value else {
            preconditionFailure() // Every slot below a longhand's count holds a value.
        }
        return value
    }

    /// `CSSValueList::createCommaSeparated(WTF::move(longhands[longhand]))`: one value through the one-value
    /// `createCommaSeparated(Ref<CSSValue>)`, which makes the same list.
    mutating func takeCommaSeparatedList(_ longhand: Int) -> PropertyValue {
        if counts[longhand] == 1 {
            return WebCore.CSSValueList.createCommaSeparated(PropertyValueRef(take(0, of: longhand))).get()
        }
        return takeList(longhand)
    }

    /// `longhands[longhand].size() == 1 ? longhands[longhand][0] : CSSValueList::createCommaSeparated(...)`: one value
    /// bare.
    mutating func takeSingleValueList(_ longhand: Int) -> PropertyValue {
        if counts[longhand] == 1 {
            return take(0, of: longhand)
        }
        return takeList(longhand)
    }

    /// The comma-separated list of every value of `longhand`, built once.
    private mutating func takeList(_ longhand: Int) -> PropertyValue {
        var list = PropertyValueList()
        for index in 0..<counts[longhand] {
            list.append(take(index, of: longhand))
        }
        return WebCore.CSSValueList.createCommaSeparated(list.take()).get()
    }
}

extension PropertyParser {
    // MARK: - background, -webkit-mask, mask

    /// `consumeBackgroundComponent`: the single-layer consumer of `property`, or nil for a property it does not list.
    /// The layer loop parses positions itself.
    private mutating func backgroundComponent(_ property: WebCore.CSSPropertyID, _ calc: PropertyCalc) -> PropertyValue? {
        switch property {
        // background-*
        case .BackgroundClip: return parseGeneratedRule(.singleBackgroundClip, calc)
        case .BackgroundBlendMode: return parseGeneratedRule(.singleBackgroundBlendMode, calc)
        case .BackgroundAttachment: return parseGeneratedRule(.singleBackgroundAttachment, calc)
        case .BackgroundOrigin: return parseGeneratedRule(.singleBackgroundOrigin, calc)
        case .BackgroundImage: return parseGeneratedRule(.singleBackgroundImage, calc)
        case .BackgroundRepeat: return parseGeneratedRule(.singleBackgroundRepeat, calc)
        // consumeSingleBackgroundSize (CSSPropertyConsumerSwiftProperties.swift).
        case .BackgroundSize: return singleBackgroundSize(calc)
        // consumeColor with the default CSSColorParsingOptions: Absolute, Current and System (CSSPropertyParser.cpp
        // checks the value).
        case .BackgroundColor: return colorValue(calc, allowedColorTypes: 0b111)

        // mask-*
        case .MaskComposite: return parseGeneratedRule(.singleMaskComposite, calc)
        case .MaskOrigin: return parseGeneratedRule(.singleMaskOrigin, calc)
        case .MaskClip: return parseGeneratedRule(.singleMaskClip, calc)
        case .MaskImage: return parseGeneratedRule(.singleMaskImage, calc)
        case .MaskMode: return parseGeneratedRule(.singleMaskMode, calc)
        case .MaskRepeat: return parseGeneratedRule(.singleMaskRepeat, calc)
        // consumeSingleMaskSize (CSSPropertyConsumerSwiftProperties.swift).
        case .MaskSize: return singleMaskSize(calc)

        // -webkit-background-*
        // consumeSingleWebkitBackgroundSize: backgroundSize(.webkitBackgroundSize) (CSSPropertyConsumerSwiftProperties.swift).
        case .WebkitBackgroundSize: return consumeHandWritten(WebCore.CSSPropertyID.WebkitBackgroundSize.rawValue, calc)
        case .WebkitBackgroundClip: return parseGeneratedRule(.singleWebkitBackgroundClip, calc)
        case .WebkitBackgroundOrigin: return parseGeneratedRule(.singleWebkitBackgroundOrigin, calc)

        // -webkit-mask-*
        case .WebkitMaskClip: return parseGeneratedRule(.singleWebkitMaskClip, calc)
        case .WebkitMaskComposite: return parseGeneratedRule(.singleWebkitMaskComposite, calc)
        case .WebkitMaskSourceType: return parseGeneratedRule(.singleWebkitMaskSourceType, calc)

        default: return nil
        }
    }

    /// `std::array<CSSValueListBuilder, 10>`.
    private static var maxBackgroundLonghandCount: Int { 10 }

    /// `consumeBackgroundShorthand`, for background and -webkit-mask (CSSProperties.json "parser-function").
    mutating func consumeBackgroundShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeBackgroundLayers(sink, longhands, isMask: false, calc)
    }

    /// The body of `consumeBackgroundShorthand`. `isMask` is `shorthand.id() == CSSPropertyID::Mask`: true only
    /// when consumeMaskShorthand calls it, mask's parser function.
    ///
    /// Per layer, every unparsed longhand in shorthand order is tried, a whole pass at a time (no break after a match,
    /// unlike animation), until a comma or the end. A position consumes X and Y together and marks Y parsed (the Y
    /// longhand must follow X); `/ size` only right after a position in the same pass order; the colour only in
    /// the last layer; an absent clip copies the origin value object; `background-clip: border-area` makes an absent
    /// background-origin `border-box`; the rest get the implicit initial value. All longhands are added only after
    /// the whole value parses, a one-layer list bare.
    private mutating func consumeBackgroundLayers(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        isMask: Bool,
        _ calc: PropertyCalc
    ) -> Bool {
        var longhandCount = longhands.count

        // mask resets mask-border properties outside of this method.
        if isMask {
            longhandCount -= ShorthandLonghands.maskBorder.count
        }

        // ASSERT(longhandCount <= 10), a debug check; indexing the arrays traps past 10, as hardened std::array does.
        assert(longhandCount <= Self.maxBackgroundLonghandCount)
        var lists = ShorthandLayerLists()

        repeat {
            var parsedLonghand: [10 of Bool] = .init(repeating: false)
            var lastParsedWasPosition = false
            var clipIsBorderArea = false
            var originValue: PropertyValue? = nil
            repeat {
                var foundProperty = false
                var i = 0
                while i < longhandCount {
                    defer { i += 1 } // Below longhandCount, at most 10.
                    if parsedLonghand[i] {
                        continue
                    }

                    var value: PropertyValue? = nil
                    var valueY: PropertyValue? = nil
                    let property = longhands[i]
                    // `isValueID(value, CSSValueID::BorderArea)` for a background-clip value: that keyword can
                    // only come from a `border-area` identifier (<single-background-clip> = <box> | border-area |
                    // text | -webkit-text, a keyword list with no aliases), so the identifier is read before the parse,
                    // for background-clip only, the one property the C++ checks.
                    let peeked = property == .BackgroundClip ? peekIdent() : .Invalid

                    if property == .BackgroundPositionX || property == .WebkitMaskPositionX {
                        // Note: This assumes y properties (for example background-position-y) follow the x properties
                        // in the shorthand array.
                        // `consumeBackgroundPositionUnresolved`: backgroundPosition (CSSPropertyConsumerSwiftValues.swift)
                        // into components; it consumes nothing when it fails.
                        var components = WebCore.CSSColorSwiftComponents()
                        guard let layout = consumePosition(&components, maxComponents: 4, allowsThree: true) else {
                            continue
                        }
                        let xy = makePositionXYValues(components, layout)
                        value = xy.x
                        valueY = xy.y
                    } else if property == .BackgroundSize {
                        if !consumeSlash() {
                            continue
                        }
                        if !lastParsedWasPosition {
                            return false
                        }
                        value = singleBackgroundSize(calc)
                        if value == nil {
                            return false
                        }
                    } else if property == .MaskSize {
                        if !consumeSlash() {
                            continue
                        }
                        if !lastParsedWasPosition {
                            return false
                        }
                        value = singleMaskSize(calc)
                        if value == nil {
                            return false
                        }
                    } else if property == .BackgroundPositionY || property == .WebkitMaskPositionY {
                        continue
                    } else {
                        value = backgroundComponent(property, calc)
                    }
                    if let value {
                        if property == .BackgroundOrigin || property == .MaskOrigin {
                            originValue = value
                        } else if property == .BackgroundClip {
                            clipIsBorderArea = peeked == .BorderArea
                        }
                        parsedLonghand[i] = true
                        foundProperty = true
                        lists.append(value, to: i)
                        lastParsedWasPosition = valueY != nil
                        if let valueY {
                            parsedLonghand[i + 1] = true
                            lists.append(valueY, to: i + 1)
                        }
                    }
                }
                if !foundProperty {
                    return false
                }
            } while !atEnd && peekType() != PropertyTokenType.comma

            for i in 0..<longhandCount {
                let property = longhands[i]
                if property == .BackgroundColor && !atEnd {
                    if parsedLonghand[i] {
                        return false // Colors are only allowed in the last layer.
                    }
                    continue
                }
                if (property == .BackgroundClip || property == .MaskClip || property == .WebkitMaskClip) && !parsedLonghand[i],
                    let origin = originValue.take()
                {
                    // `originValue.releaseNonNull()`: the origin's own value object, moved, so a later clip in the
                    // same layer would not see it.
                    lists.append(origin, to: i)
                    continue
                }
                if clipIsBorderArea && property == .BackgroundOrigin && !parsedLonghand[i] {
                    lists.append(keywordValue(.BorderBox), to: i)
                    continue
                }
                if !parsedLonghand[i] {
                    lists.append(WebCore.CSSKeywordValue.implicitInitialValue(), to: i)
                }
            }
        } while consumeComma()
        if !atEnd {
            return false
        }

        for i in 0..<longhandCount {
            shorthandAdd(sink, longhands[i], lists.takeSingleValueList(i))
        }
        return true
    }

    /// `consumeMaskShorthand`: background's layers over mask's first nine longhands, then the mask-border
    /// longhands null (implicit initial), in maskBorderShorthand() order.
    mutating func consumeMaskShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        if !consumeBackgroundLayers(sink, longhands, isMask: true, calc) {
            return false
        }
        for longhand in ShorthandLonghands.maskBorder {
            shorthandAdd(sink, longhand, nil)
        }
        return true
    }

    // MARK: - background-position, -webkit-mask-position, mask-position

    /// `consumeBackgroundPositionShorthand`, for background-position and -webkit-mask-position: a comma
    /// list of `consumeBackgroundPositionUnresolved` (one to four components), split into X and Y, each bare when one.
    mutating func consumeBackgroundPositionShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumePositionListShorthand(sink, longhands, allowsThree: true)
    }

    /// `consumeMaskPositionShorthand`: as background-position, with `consumePositionUnresolved` (one, two or
    /// four components; position, CSSPropertyConsumerSwiftValues.swift).
    mutating func consumeMaskPositionShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumePositionListShorthand(sink, longhands, allowsThree: false)
    }

    /// The common body of the two (identical but for the position consumer).
    private mutating func consumePositionListShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        allowsThree: Bool
    ) -> Bool {
        var x = ShorthandCommaSeparatedSingleValueList()
        var y = ShorthandCommaSeparatedSingleValueList()
        repeat {
            var components = WebCore.CSSColorSwiftComponents()
            guard let layout = consumePosition(&components, maxComponents: 4, allowsThree: allowsThree) else {
                return false
            }
            let xy = makePositionXYValues(components, layout)
            x.append(xy.x)
            y.append(xy.y)
        } while consumeComma()

        if !atEnd {
            return false
        }

        let resultX = x.takeValue()
        let resultY = y.takeValue()
        shorthandAdd(sink, longhands[0], resultX)
        shorthandAdd(sink, longhands[1], resultY)
        return true
    }

    // MARK: - -webkit-background-size

    /// `consumeWebkitBackgroundSizeShorthand`: a comma list of `consumeSingleWebkitBackgroundSize`, bare when one, added
    /// to background-size (the property hardcoded, not the span).
    mutating func consumeWebkitBackgroundSizeShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        var list = ShorthandCommaSeparatedSingleValueList()
        repeat {
            // consumeSingleWebkitBackgroundSize (CSSPropertyConsumerSwiftProperties.swift).
            guard let size = consumeHandWritten(WebCore.CSSPropertyID.WebkitBackgroundSize.rawValue, calc) else {
                return false
            }
            list.append(size)
        } while consumeComma()
        if !atEnd {
            return false
        }
        shorthandAdd(sink, .BackgroundSize, list.takeValue())
        return true
    }

    // MARK: - grid-row, grid-column, grid-area

    /// `CSS::GridLine { CSS::Keyword::Auto { } }`, as parts.
    private static var autoGridLineParts: ShorthandGridLineParts {
        (UInt8(WebCore.CSSGridSwiftLineAuto), (number: 1.0, calc: UInt32.max), nil)
    }

    /// `line->isCustomIdent() ? line : CSS::GridLine { CSS::Keyword::Auto { } }` (CSSGridLine.h): a copy of a
    /// custom-ident line, else auto.
    private static func gridLineCopyOrAuto(_ line: ShorthandGridLineParts) -> ShorthandGridLineParts {
        line.kind == UInt8(WebCore.CSSGridSwiftLineCustomIdent) ? line : autoGridLineParts
    }

    /// `CSSGridLineValue::create(line)`: setGridLineResult with the GridLine consumer (CSSPropertyConsumerSwiftBuilders.h,
    /// as gridLine does, CSSPropertyConsumerSwiftGrid.swift). A copied line is built again from its parts, so
    /// each longhand gets its own value, as the C++ makes one CSSGridLineValue per longhand.
    private func gridLineValue(_ line: ShorthandGridLineParts) -> PropertyValue? {
        let consumer = WebCore.CSSPropertyConsumerSwiftConsumer.GridLine
        return
            WebCore.setGridLineResult(tokens.value, consumer.rawValue, line.kind, line.integer.number, line.integer.calc, line.name ?? .max)
            .get()
    }

    /// `consumeUnresolvedGridLine`: gridLineParts (CSSPropertyConsumerSwiftGrid.swift), restoring
    /// the index on a failure as gridLine does.
    private mutating func unresolvedGridLineParts(_ calc: PropertyCalc) -> ShorthandGridLineParts? {
        let start = index
        guard let line = gridLinePartsForShorthand(calc) else {
            index = start
            return nil
        }
        return line
    }

    /// `consumeGridItemPositionShorthand`, for grid-row and grid-column: start, then `/ end` or a copy of a
    /// custom-ident start, else auto.
    mutating func consumeGridItemPositionShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        assert(longhands.count == 2)

        guard let startValue = unresolvedGridLineParts(calc) else {
            return false
        }

        let endValue: ShorthandGridLineParts
        if consumeSlash() {
            guard let end = unresolvedGridLineParts(calc) else {
                return false
            }
            endValue = end
        } else {
            endValue = Self.gridLineCopyOrAuto(startValue)
        }
        if !atEnd {
            return false
        }

        shorthandAdd(sink, longhands[0], gridLineValue(startValue))
        shorthandAdd(sink, longhands[1], gridLineValue(endValue))
        return true
    }

    /// `consumeGridAreaShorthand`: row-start, then up to three `/ <grid-line>`; a missing column-start and
    /// row-end copy a custom-ident row-start, a missing column-end a custom-ident column-start (as completed), else
    /// auto. Added in row-start, column-start, row-end, column-end order.
    mutating func consumeGridAreaShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        guard let rowStart = unresolvedGridLineParts(calc) else {
            return false
        }
        var columnStart: ShorthandGridLineParts? = nil
        var rowEnd: ShorthandGridLineParts? = nil
        var columnEnd: ShorthandGridLineParts? = nil
        if consumeSlash() {
            columnStart = unresolvedGridLineParts(calc)
            if columnStart == nil {
                return false
            }
            if consumeSlash() {
                rowEnd = unresolvedGridLineParts(calc)
                if rowEnd == nil {
                    return false
                }
                if consumeSlash() {
                    columnEnd = unresolvedGridLineParts(calc)
                    if columnEnd == nil {
                        return false
                    }
                }
            }
        }
        if !atEnd {
            return false
        }
        let completedColumnStart = columnStart ?? Self.gridLineCopyOrAuto(rowStart)
        let completedRowEnd = rowEnd ?? Self.gridLineCopyOrAuto(rowStart)
        let completedColumnEnd = columnEnd ?? Self.gridLineCopyOrAuto(completedColumnStart)

        shorthandAdd(sink, .GridRowStart, gridLineValue(rowStart))
        shorthandAdd(sink, .GridColumnStart, gridLineValue(completedColumnStart))
        shorthandAdd(sink, .GridRowEnd, gridLineValue(completedRowEnd))
        shorthandAdd(sink, .GridColumnEnd, gridLineValue(completedColumnEnd))
        return true
    }

    // MARK: - grid-template

    /// `range.peek().type() == DelimiterToken && range.peek().delimiter() == '/'`.
    private func peekIsSlash() -> Bool {
        peekType() == PropertyTokenType.delimiter && tokens.value.delimiter(index) == 0x2F
    }

    /// `consumeUnresolvedGridLineNames` (CSSPropertyParserConsumer+Grid.cpp) for the areas form, appending the
    /// names as CSSGridSwiftLineName parts with no CSSGridSwiftLineNames/End around them, so the caller can open a new
    /// group or extend the last one. nil, nothing consumed or appended, if there are no <line-names>; else how many
    /// names. As gridLineNames (CSSPropertyConsumerSwiftGrid.swift), whose brackets it leaves out.
    private mutating func gridTemplateLineNameIdents(_ parts: inout WebCore.CSSGridSwiftParts) -> Int? {
        guard peekType() == PropertyTokenType.leftBracket else {
            return nil
        }
        let start = index
        let mark = parts.size()
        consumeIncludingWhitespace()
        var count = 0
        while let name = gridLineNameForShorthand() {
            parts.append(UInt8(WebCore.CSSGridSwiftLineName), token: name)
            count &+= 1 // At most the token count.
        }
        guard peekType() == PropertyTokenType.rightBracket else {
            index = start
            parts.shrink(mark)
            return nil
        }
        consumeIncludingWhitespace()
        return count
    }

    /// `consumeUnresolvedGridLineNames`, then `if (lineNames && !lineNames->isEmpty()) append(Track { *lineNames })`:
    /// a new CSSGridSwiftLineNames group, dropped if there are no names. Returns whether it was appended.
    private mutating func gridTemplateAppendLineNames(_ parts: inout WebCore.CSSGridSwiftParts) -> Bool {
        let mark = parts.size()
        parts.append(UInt8(WebCore.CSSGridSwiftLineNames))
        guard let count = gridTemplateLineNameIdents(&parts), count != 0 else {
            parts.shrink(mark)
            return false
        }
        parts.append(UInt8(WebCore.CSSGridSwiftLineNamesEnd))
        return true
    }

    /// `consumeUnresolvedGridExplicitTrackList` into `parts`: the loop of unresolvedGridExplicitTrackList
    /// (CSSPropertyConsumerSwiftGrid.swift), which gives its value to setUnresolvedResult and so cannot be
    /// called for the parts. False if it does not parse (the index is then restored, as there).
    private mutating func gridTemplateExplicitTrackList(_ parts: inout WebCore.CSSGridSwiftParts, _ calc: PropertyCalc) -> Bool {
        let start = index
        gridLineNamesInListForShorthand(&parts)
        repeat {
            guard gridTrackSizeForShorthand(&parts, calc) != nil else {
                index = start
                return false
            }
            gridLineNamesInListForShorthand(&parts)
        } while !atEnd && peekType() != PropertyTokenType.delimiter
        return true
    }

    /// `consumeGridTemplateShorthand`, for grid-template.
    mutating func consumeGridTemplateShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        consumeGridTemplate(sink, calc)
    }

    /// The body of `consumeGridTemplateShorthand`, which grid calls too (with gridTemplateShorthand(), which the body
    /// does not read): `none`; `<grid-template-rows> / <grid-template-columns>`; or
    /// `[ <line-names>? <string> <track-size>? <line-names>? ]+ [ / <explicit-track-list> ]?`. Adds rows, columns,
    /// areas, only when the whole value parses.
    ///
    /// The areas form keeps the rows, the area rows and the columns as three CSSGridSwiftParts, which setGridResult
    /// builds into GridTemplateLists and GridTemplateAreas. A rejected area row fails the shorthand after the rest of
    /// the value is parsed, where the C++ fails at the row; both add nothing.
    private mutating func consumeGridTemplate(_ sink: borrowing ShorthandSink, _ calc: PropertyCalc) -> Bool {
        let rangeCopyIndex = index
        let rangeCopyEnd = end
        var rowsValue = shorthandConsumeIdent(.None)

        // 1- 'none' case.
        if rowsValue != nil && atEnd {
            shorthandAdd(sink, .GridTemplateRows, keywordValue(.None))
            shorthandAdd(sink, .GridTemplateColumns, keywordValue(.None))
            shorthandAdd(sink, .GridTemplateAreas, keywordValue(.None))
            return true
        }

        // 2- <grid-template-rows> / <grid-template-columns>
        if rowsValue == nil {
            // `consumeGridTemplateList`: gridTemplateList (CSSPropertyConsumerSwiftGrid.swift).
            rowsValue = gridTemplateList(calc)
        }

        if let rowsValue {
            if !consumeSlash() {
                return false
            }
            guard let columnsValue = gridTemplateList(calc), atEnd else {
                return false
            }

            shorthandAdd(sink, .GridTemplateRows, rowsValue)
            shorthandAdd(sink, .GridTemplateColumns, columnsValue)
            shorthandAdd(sink, .GridTemplateAreas, keywordValue(.None))
            return true
        }

        // 3- [ <line-names>? <string> <track-size>? <line-names>? ]+ [ / <explicit-track-list> ]?

        index = rangeCopyIndex
        end = rangeCopyEnd

        var areaRows = WebCore.CSSGridSwiftParts()
        var templateRows = WebCore.CSSGridSwiftParts()

        // Persists between loop iterations so we can use the same value for consecutive <line-names> values: whether
        // the previous row's trailing <line-names> were appended (`previousLineNames && !previousLineNames->isEmpty()`),
        // which makes them the last parts of templateRows (`templateRowsTrackList.last()`).
        var previousLineNamesAppended = false

        repeat {
            // Handle leading <line-names>?.
            if previousLineNamesAppended {
                // Combined with the previous trailing names: its group is reopened (its
                // CSSGridSwiftLineNamesEnd dropped), these names appended, and it is closed again. An empty or absent
                // <line-names> leaves it as it was.
                let size = templateRows.size()
                templateRows.shrink(size &- 1) // At least the previous group's three parts.
                _ = gridTemplateLineNameIdents(&templateRows)
                templateRows.append(UInt8(WebCore.CSSGridSwiftLineNamesEnd))
            } else {
                _ = gridTemplateAppendLineNames(&templateRows)
            }

            // Handle a template-area's row <string>: gridAreaRow (CSSPropertyConsumerSwiftGrid.swift), as
            // unresolvedGridTemplateAreasRow consumes it. CSS::addRow is the builder's, below.
            if !gridAreaRowForShorthand(&areaRows) {
                return false
            }

            // Handle template-rows's <track-size>: gridTrackSize, or `auto`.
            if gridTrackSizeForShorthand(&templateRows, calc) == nil {
                templateRows.appendKeyword(UInt8(WebCore.CSSGridSwiftBreadthKeyword), WebCore.CSSValueID.Auto.rawValue)
            }

            // This will handle the trailing/leading <line-names>? in the grammar.
            previousLineNamesAppended = gridTemplateAppendLineNames(&templateRows)
        } while !atEnd && !peekIsSlash()

        var templateColumnsValue: PropertyValue? = nil
        if !atEnd {
            if !consumeSlash() {
                return false
            }
            var templateColumns = WebCore.CSSGridSwiftParts()
            guard gridTemplateExplicitTrackList(&templateColumns, calc), atEnd else {
                return false
            }
            let consumer = WebCore.CSSPropertyConsumerSwiftConsumer.GridTemplateList
            templateColumnsValue = WebCore.setGridResult(tokens.value, consumer.rawValue, consuming: consume templateColumns).get()
        } else {
            templateColumnsValue = keywordValue(.None)
        }

        let areasConsumer = WebCore.CSSPropertyConsumerSwiftConsumer.GridTemplateAreas
        guard let areasValue = WebCore.setGridResult(tokens.value, areasConsumer.rawValue, consuming: consume areaRows).get() else {
            return false // `!CSS::addRow(gridAreaMap, *row)` for some row.
        }
        let rowsConsumer = WebCore.CSSPropertyConsumerSwiftConsumer.GridTemplateList
        let templateRowsValue = WebCore.setGridResult(tokens.value, rowsConsumer.rawValue, consuming: consume templateRows).get()

        shorthandAdd(sink, .GridTemplateRows, templateRowsValue)
        shorthandAdd(sink, .GridTemplateColumns, templateColumnsValue)
        shorthandAdd(sink, .GridTemplateAreas, areasValue)
        return true
    }

    // MARK: - grid

    /// `consumeIdentRaw<CSSValueID::id>(range).has_value()`: consumes the identifier only if it is `id`.
    private mutating func gridConsumeIdentIfMatches(_ id: WebCore.CSSValueID) -> Bool {
        guard peekIdent() == id else {
            return false
        }
        consumeIncludingWhitespace()
        return true
    }

    /// `consumeImplicitGridAutoFlow`: `[ auto-flow && dense? ]` in the direction `isRow` names; a
    /// CSSGridAutoFlowValue built in Swift as gridAutoFlow builds it (CSSPropertyConsumerSwiftGrid.swift).
    private mutating func implicitGridAutoFlow(isRow: Bool) -> PropertyValue? {
        // [ auto-flow && dense? ]
        let autoFlow = gridConsumeIdentIfMatches(.AutoFlow)
        let dense = gridConsumeIdentIfMatches(.Dense)
        if !autoFlow && (!dense || !gridConsumeIdentIfMatches(.AutoFlow)) {
            return nil
        }
        typealias Keyword = WebCore.CSS.Keyword
        let flow: WebCore.CSS.GridAutoFlow
        if !dense {
            flow = isRow ? .init(Keyword.Row()) : .init(Keyword.Column())
        } else if isRow {
            flow = .init(Keyword.Dense())
        } else {
            flow = .init(Keyword.Column(), Keyword.Dense())
        }
        return WebCore.CSSGridAutoFlowValue.create(flow).get()
    }

    /// `consumeGridShorthand`: grid-template first, added into the same result, then the auto longhands
    /// as keywords (`row`, a CSSKeywordValue where the other forms make a CSSGridAutoFlowValue);
    /// else `[ auto-flow && dense? ] <grid-auto-rows>? / <grid-template-columns>` or
    /// `<grid-template-rows> / [ auto-flow && dense? ] <grid-auto-columns>?`.
    mutating func consumeGridShorthand(
        _ sink: borrowing ShorthandSink,
        _ longhands: Span<WebCore.CSSPropertyID>,
        _ calc: PropertyCalc
    ) -> Bool {
        assert(longhands.count == 6)

        let rangeCopyIndex = index
        let rangeCopyEnd = end

        // 1- <grid-template>
        if consumeGridTemplate(sink, calc) {
            // It can only be specified the explicit or the implicit grid properties in a single grid declaration.
            // The sub-properties not specified are set to their initial value, as normal for shorthands.
            shorthandAdd(sink, .GridAutoFlow, keywordValue(.Row))
            shorthandAdd(sink, .GridAutoColumns, keywordValue(.Auto))
            shorthandAdd(sink, .GridAutoRows, keywordValue(.Auto))
            return true
        }

        index = rangeCopyIndex
        end = rangeCopyEnd

        var autoColumnsValue: PropertyValue? = nil
        var autoRowsValue: PropertyValue? = nil
        var templateRows: PropertyValue? = nil
        var templateColumns: PropertyValue? = nil
        var gridAutoFlow: PropertyValue? = nil

        let peeked = peekIdent()
        if peeked == .AutoFlow || peeked == .Dense {
            // 2- [ auto-flow && dense? ] <grid-auto-rows>? / <grid-template-columns>
            gridAutoFlow = implicitGridAutoFlow(isRow: true)
            if gridAutoFlow == nil || atEnd {
                return false
            }
            if consumeSlash() {
                autoRowsValue = keywordValue(.Auto)
            } else {
                // `consumeGridTrackSizes`: gridTrackSizes (CSSPropertyConsumerSwiftGrid.swift).
                autoRowsValue = gridTrackSizes(calc)
                if autoRowsValue == nil {
                    return false
                }
                if !consumeSlash() {
                    return false
                }
            }
            if atEnd {
                return false
            }
            templateColumns = gridTemplateList(calc)
            if templateColumns == nil {
                return false
            }
            templateRows = keywordValue(.None)
            autoColumnsValue = keywordValue(.Auto)
        } else {
            // 3- <grid-template-rows> / [ auto-flow && dense? ] <grid-auto-columns>?
            templateRows = gridTemplateList(calc)
            if templateRows == nil {
                return false
            }
            if !consumeSlash() || atEnd {
                return false
            }
            gridAutoFlow = implicitGridAutoFlow(isRow: false)
            if gridAutoFlow == nil {
                return false
            }
            if atEnd {
                autoColumnsValue = keywordValue(.Auto)
            } else {
                autoColumnsValue = gridTrackSizes(calc)
                if autoColumnsValue == nil {
                    return false
                }
            }
            templateColumns = keywordValue(.None)
            autoRowsValue = keywordValue(.Auto)
        }

        if !atEnd {
            return false
        }

        // It can only be specified the explicit or the implicit grid properties in a single grid declaration.
        // The sub-properties not specified are set to their initial value, as normal for shorthands.
        shorthandAdd(sink, .GridTemplateColumns, templateColumns)
        shorthandAdd(sink, .GridTemplateRows, templateRows)
        shorthandAdd(sink, .GridTemplateAreas, keywordValue(.None))
        shorthandAdd(sink, .GridAutoFlow, gridAutoFlow)
        shorthandAdd(sink, .GridAutoColumns, autoColumnsValue)
        shorthandAdd(sink, .GridAutoRows, autoRowsValue)

        return true
    }
}
