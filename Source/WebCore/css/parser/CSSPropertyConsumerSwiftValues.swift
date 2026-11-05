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
internal import WebCore_Private.Core.CSSParserIdioms
internal import WebCore_Private.Core.CSSParserToken

// The consumers of CSSPropertyParserConsumer+Color.cpp, +ColorAdjust.cpp, +Position.cpp, +Image.cpp and +Background.cpp
// that other consumers call, numbered by CSSPropertyConsumerSwiftConsumer.
// One that consumes a CSS:: value gives it to setUnresolvedResult and returns nil; the C++ that called it gets it in
// the std::optional it passed.

extension PropertyParser {
    /// The CSSPropertyConsumerSwiftConsumer `consumer`, or nil if there is none.
    mutating func consumeValue(_ consumer: UInt16, _ calc: PropertyCalc) -> PropertyValue? {
        typealias Consumer = WebCore.CSSPropertyConsumerSwiftConsumer
        switch consumer {
        case Consumer.UnresolvedColor.rawValue: return unresolvedColor(calc)
        case Consumer.Color.rawValue: return colorValue(calc)
        case Consumer.DynamicRangeLimit.rawValue: return dynamicRangeLimit(calc)
        case Consumer.ColorScheme.rawValue: return colorScheme()
        case Consumer.Position.rawValue: return position(calc)
        case Consumer.BackgroundPosition.rawValue: return backgroundPosition(calc)
        case Consumer.PositionX.rawValue: return positionX(calc)
        case Consumer.PositionY.rawValue: return positionY(calc)
        case Consumer.OneOrTwoComponentPosition.rawValue: return oneOrTwoComponentPosition(calc)
        case Consumer.TwoComponentPositionHorizontal.rawValue: return twoComponentPositionHorizontal(calc)
        case Consumer.TwoComponentPositionVertical.rawValue: return twoComponentPositionVertical(calc)
        case Consumer.Image.rawValue: return image(calc)
        case Consumer.BorderRadius.rawValue: return borderRadius(calc)
        case Consumer.WebKitBorderRadius.rawValue: return webKitBorderRadius(calc)
        case Consumer.BorderRadiusSide.rawValue: return borderRadiusSide(calc)
        case Consumer.BorderImageSource.rawValue: return borderImageSource(calc)
        case Consumer.BorderImageOutset.rawValue: return borderImageOutset(calc)
        case Consumer.BorderImageRepeat.rawValue: return borderImageRepeat()
        case Consumer.BorderImageSlice.rawValue: return borderImageSlice(calc)
        case Consumer.BorderImageWidth.rawValue: return borderImageWidth(calc)
        case Consumer.BorderImage.rawValue: return borderImage(calc)
        case Consumer.RepeatStyle.rawValue: return repeatStyle()
        case Consumer.BoxShadow.rawValue: return boxShadow(calc)
        case Consumer.WebkitBoxShadow.rawValue: return webkitBoxShadow(calc)
        case Consumer.WebkitBoxReflect.rawValue: return webkitBoxReflect(calc)
        default: return nil
        }
    }

    // MARK: - Colors (CSSPropertyParserConsumer+Color.cpp, +ColorAdjust.cpp)

    /// `consumeUnresolvedColor`, with the CSS::ColorType options. Consumes nothing if there is no color.
    mutating func unresolvedColor(_ calc: PropertyCalc) -> PropertyValue? {
        let start = index
        var state = colorParserState()
        guard let color = consumeColor(&state) else {
            index = start
            return nil
        }
        WebCore.setUnresolvedResult(tokens.value, consuming: consume color)
        return nil
    }

    /// `consumeColor`: a keyword, a pooled resolved color or a CSSColorValue.
    mutating func colorValue(_ calc: PropertyCalc) -> PropertyValue? {
        let start = index
        var state = colorParserState()
        // The level consumeColor gives the color it consumes.
        state.nestingLevel = 1
        switch consumeSimpleColor(state) {
        case .keyword(let id):
            return keywordValue(id)
        case .hex(let hex):
            return WebCore.makeHexColorValue(tokens.value, hex).get()
        case .function:
            guard let color = consumeColorFunction(&state) else {
                index = start
                return nil
            }
            return WebCore.makeColorValue(tokens.value, consuming: consume color).get()
        case .notAColor:
            index = start
            return nil
        }
    }

    /// `consumeUnresolvedDynamicRangeLimit`.
    mutating func dynamicRangeLimit(_ calc: PropertyCalc) -> PropertyValue? {
        guard let limit = consumeDynamicRangeLimit(WebCore.colorContextForSwift(tokens.value)) else {
            return nil
        }
        WebCore.setUnresolvedResult(tokens.value, consuming: consume limit)
        return nil
    }

    /// `consumeUnresolvedColorScheme`: `normal`, or identifiers with `only` first or last.
    mutating func colorScheme() -> PropertyValue? {
        if peekIdent() == .Normal {
            consumeIncludingWhitespace()
            WebCore.setUnresolvedResult(tokens.value, consuming: WebCore.makeColorScheme(tokens.value, 0, 0, false))
            return nil
        }
        var only = false
        if peekIdent() == .Only {
            consumeIncludingWhitespace()
            only = true
        }
        let first = index
        var last = index
        while !atEnd {
            // consumeUnresolvedCustomIdentExcluding takes no token but an identifier.
            guard peekType() == PropertyTokenType.ident else {
                return nil
            }
            let id = peekIdent()
            switch id {
            case .Normal:
                return nil
            case .Only:
                guard !only else {
                    return nil
                }
                consumeIncludingWhitespace()
                only = true
                guard atEnd else {
                    return nil
                }
            default:
                guard WebCore.isValidCustomIdentifier(id) else {
                    return nil
                }
                consumeIncludingWhitespace()
                last = index
            }
        }
        guard last > first else {
            return nil
        }
        // Both at most the token count, an Int from a UInt32.
        let schemes = WebCore.makeColorScheme(tokens.value, UInt32(truncatingIfNeeded: first), UInt32(truncatingIfNeeded: last), only)
        WebCore.setUnresolvedResult(tokens.value, consuming: consume schemes)
        return nil
    }

    // MARK: - Positions (CSSPropertyParserConsumer+Position.cpp)

    /// `consumePositionUnresolved`: one, two or four components. Consumes nothing if there is no position.
    mutating func position(_ calc: PropertyCalc) -> PropertyValue? {
        consumePosition(maxComponents: 4, allowsThree: false)
    }

    /// `consumeBackgroundPositionUnresolved`: one to four components.
    mutating func backgroundPosition(_ calc: PropertyCalc) -> PropertyValue? {
        consumePosition(maxComponents: 4, allowsThree: true)
    }

    /// `consumePositionXUnresolved`.
    mutating func positionX(_ calc: PropertyCalc) -> PropertyValue? {
        consumeAxis(.PositionX)
    }

    /// `consumePositionYUnresolved`.
    mutating func positionY(_ calc: PropertyCalc) -> PropertyValue? {
        consumeAxis(.PositionY)
    }

    /// `consumeOneOrTwoComponentPositionUnresolved`.
    mutating func oneOrTwoComponentPosition(_ calc: PropertyCalc) -> PropertyValue? {
        consumePosition(maxComponents: 2, allowsThree: false)
    }

    /// `consumeTwoComponentPositionHorizontalUnresolved`.
    mutating func twoComponentPositionHorizontal(_ calc: PropertyCalc) -> PropertyValue? {
        consumeAxis(.TwoComponentPositionHorizontal)
    }

    /// `consumeTwoComponentPositionVerticalUnresolved`.
    mutating func twoComponentPositionVertical(_ calc: PropertyCalc) -> PropertyValue? {
        consumeAxis(.TwoComponentPositionVertical)
    }

    // MARK: - Images (CSSPropertyParserConsumer+Image.cpp)

    /// `consumeImage`, with the AllowedImageType options.
    mutating func image(_ calc: PropertyCalc) -> PropertyValue? {
        let start = index
        guard let image = consumeImage(tokens.value.consumerOptions()) else {
            index = start
            return nil
        }
        return image
    }

    // MARK: - Borders and backgrounds (CSSPropertyParserConsumer+Background.cpp)

    /// `consumeUnresolvedBorderRadius`.
    mutating func borderRadius(_ calc: PropertyCalc) -> PropertyValue? {
        consumeBorderRadius(.BorderRadius)
    }

    /// `consumeUnresolvedWebKitBorderRadius`.
    mutating func webKitBorderRadius(_ calc: PropertyCalc) -> PropertyValue? {
        consumeBorderRadius(.WebKitBorderRadius)
    }

    /// `consumeUnresolvedBorderRadiusSide`: <length-percentage [0,∞]>{1,2} [ / <length-percentage [0,∞]>{1,2} ]?
    mutating func borderRadiusSide(_ calc: PropertyCalc) -> PropertyValue? {
        var radii = WebCore.CSSColorSwiftComponents()
        guard consumeNumeric(&radii, 0, .nonnegativeLengthPercentage) else {
            return nil
        }
        let second: UInt8 = consumeNumeric(&radii, 1, .nonnegativeLengthPercentage) ? 1 : 0
        var parts = WebCore.CSSImageSwiftParts()
        parts.append(radii, 0)
        parts.append(radii, second)
        if atEnd {
            parts.append(radii, 0)
            parts.append(radii, second)
        } else {
            guard consumeSlash(), consumeNumeric(&radii, 2, .nonnegativeLengthPercentage) else {
                return nil
            }
            let verticalSecond: UInt8 = consumeNumeric(&radii, 3, .nonnegativeLengthPercentage) ? 3 : 2
            guard atEnd else {
                return nil
            }
            parts.append(radii, 2)
            parts.append(radii, verticalSecond)
        }
        return setBorderResult(.BorderRadiusSide, parts)
    }

    /// `consumeUnresolvedBorderImageSource`.
    mutating func borderImageSource(_ calc: PropertyCalc) -> PropertyValue? {
        guard let source = consumeBorderImageSource() else {
            return nil
        }
        var parts = WebCore.CSSImageSwiftParts()
        if let image = source.image {
            parts.appendImage(image, WebCore.CSSColorSwiftComponents())
        }
        return setBorderResult(.BorderImageSource, parts)
    }

    /// `consumeUnresolvedBorderImageOutset`.
    mutating func borderImageOutset(_ calc: PropertyCalc) -> PropertyValue? {
        var outset = WebCore.CSSColorSwiftComponents()
        guard consumeBorderImageOutset(&outset) else {
            return nil
        }
        var parts = WebCore.CSSImageSwiftParts()
        parts.append(outset, 0..<4)
        return setBorderResult(.BorderImageOutset, parts)
    }

    /// `consumeUnresolvedBorderImageRepeat`.
    mutating func borderImageRepeat() -> PropertyValue? {
        var rules = WebCore.CSSColorSwiftComponents()
        let count = consumeBorderImageRepeat(&rules)
        guard count != 0 else {
            return nil
        }
        var parts = WebCore.CSSImageSwiftParts()
        parts.appendRules(rules, count)
        return setBorderResult(.BorderImageRepeat, parts)
    }

    /// `consumeUnresolvedBorderImageSlice`, with the CSSPropertyConsumerSwiftBorderImageSliceAlwaysFill option.
    mutating func borderImageSlice(_ calc: PropertyCalc) -> PropertyValue? {
        var slice = WebCore.CSSColorSwiftComponents()
        var fill = WebCore.CSSColorSwiftComponents()
        guard consumeBorderImageSlice(&slice, &fill, alwaysFill: sliceAlwaysFill) else {
            return nil
        }
        var parts = WebCore.CSSImageSwiftParts()
        parts.append(slice, 0..<4)
        parts.append(fill, 0)
        return setBorderResult(.BorderImageSlice, parts)
    }

    /// `consumeUnresolvedBorderImageWidth`, with the CSSPropertyConsumerSwiftBorderImageWidthOverridesWidthForLength
    /// option.
    mutating func borderImageWidth(_ calc: PropertyCalc) -> PropertyValue? {
        var width = WebCore.CSSColorSwiftComponents()
        guard consumeBorderImageWidth(&width) else {
            return nil
        }
        var parts = WebCore.CSSImageSwiftParts()
        parts.append(width, 0..<4)
        return setBorderResult(.BorderImageWidth, parts)
    }

    /// `consumeUnresolvedBorderImage`, with both options: <'border-image-source'> || <'border-image-slice'>
    /// [ / <'border-image-width'> | / <'border-image-width'>? / <'border-image-outset'> ]? || <'border-image-repeat'>
    mutating func borderImage(_ calc: PropertyCalc) -> PropertyValue? {
        var parts = WebCore.CSSImageSwiftParts()
        guard consumeBorderImageParts(&parts, alwaysFill: sliceAlwaysFill) else {
            return nil
        }
        return setBorderResult(.BorderImage, parts)
    }

    /// Appends the parts of a border-image or a mask-border, which share a grammar, until the end: its slice and the
    /// slice's fill, its width, outset, rules and source, an absent part's first component absent. The slice is filled
    /// if `alwaysFill`.
    mutating func consumeBorderImageParts(_ parts: inout WebCore.CSSImageSwiftParts, alwaysFill: Bool) -> Bool {
        var source: BorderImageSource? = nil
        var slice = WebCore.CSSColorSwiftComponents()
        var fill = WebCore.CSSColorSwiftComponents()
        var width = WebCore.CSSColorSwiftComponents()
        var outset = WebCore.CSSColorSwiftComponents()
        var rules = WebCore.CSSColorSwiftComponents()
        var rulesCount: UInt8 = 0
        var hasSlice = false
        repeat {
            if source == nil {
                source = consumeBorderImageSource()
                if source != nil {
                    continue
                }
            }
            if rulesCount == 0 {
                rulesCount = consumeBorderImageRepeat(&rules)
                if rulesCount != 0 {
                    continue
                }
            }
            guard !hasSlice, consumeBorderImageSlice(&slice, &fill, alwaysFill: alwaysFill) else {
                return false
            }
            hasSlice = true
            if consumeSlash() {
                let hasWidth = consumeBorderImageWidth(&width)
                if consumeSlash() {
                    guard consumeBorderImageOutset(&outset) else {
                        return false
                    }
                } else if !hasWidth {
                    return false
                }
            }
        } while !atEnd
        // An absent part's first component is absent.
        parts.append(slice, 0..<4)
        parts.append(fill, 0)
        parts.append(width, 0..<4)
        parts.append(outset, 0..<4)
        if rulesCount != 0 {
            parts.appendRules(rules, rulesCount)
        } else {
            parts.append(rules, 0..<2)
        }
        var present = WebCore.CSSColorSwiftComponents()
        if let source {
            present.setNone(0)
            if let image = source.image {
                parts.appendImage(image, present)
            } else {
                parts.append(present, 0)
            }
        } else {
            parts.append(present, 0)
        }
        return true
    }

    /// `consumeRepeatStyle`: repeat-x | repeat-y | [repeat | space | round | no-repeat]{1,2}
    mutating func repeatStyle() -> PropertyValue? {
        let horizontal = peekIdent()
        let vertical: WebCore.CSSValueID
        switch horizontal {
        case .RepeatX:
            consumeIncludingWhitespace()
            return WebCore.makeBackgroundRepeatValue(WebCore.CSSValueID.Repeat.rawValue, WebCore.CSSValueID.NoRepeat.rawValue).get()
        case .RepeatY:
            consumeIncludingWhitespace()
            return WebCore.makeBackgroundRepeatValue(WebCore.CSSValueID.NoRepeat.rawValue, WebCore.CSSValueID.Repeat.rawValue).get()
        case .Repeat, .NoRepeat, .Round, .Space:
            consumeIncludingWhitespace()
            switch peekIdent() {
            case .Repeat, .NoRepeat, .Round, .Space:
                vertical = peekIdent()
                consumeIncludingWhitespace()
            default:
                vertical = horizontal
            }
        default:
            return nil
        }
        return WebCore.makeBackgroundRepeatValue(horizontal.rawValue, vertical.rawValue).get()
    }

    /// `consumeUnresolvedBoxShadow` for box-shadow.
    mutating func boxShadow(_ calc: PropertyCalc) -> PropertyValue? {
        consumeBoxShadow(.BoxShadow)
    }

    /// `consumeUnresolvedBoxShadow` for -webkit-box-shadow.
    mutating func webkitBoxShadow(_ calc: PropertyCalc) -> PropertyValue? {
        consumeBoxShadow(.WebkitBoxShadow)
    }

    /// `consumeUnresolvedWebkitBoxReflect`: none | [ above | below | left | right ] <length-percentage>? <mask-border>?
    mutating func webkitBoxReflect(_ calc: PropertyCalc) -> PropertyValue? {
        var parts = WebCore.CSSImageSwiftParts()
        if peekIdent() == .None {
            consumeIncludingWhitespace()
            return setBorderResult(.WebkitBoxReflect, parts)
        }
        let direction = peekIdent()
        guard direction == .Above || direction == .Below || direction == .Left || direction == .Right else {
            return nil
        }
        consumeIncludingWhitespace()
        var reflection = WebCore.CSSColorSwiftComponents()
        reflection.setSymbol(0, direction.rawValue)
        if !atEnd {
            guard consumeNumeric(&reflection, 1, .lengthPercentage) else {
                return nil
            }
        }
        parts.append(reflection, 0..<2)
        // The mask-border follows, with its slice always filled; if it does not parse, nothing is consumed.
        if !atEnd {
            let start = index
            guard consumeBorderImageParts(&parts, alwaysFill: true) else {
                index = start
                return nil
            }
        }
        return setBorderResult(.WebkitBoxReflect, parts)
    }
}


// MARK: - Border, shadow and reflection parsing

/// A border-image source: none, or an image.
struct BorderImageSource {
    let image: PropertyValue?
}

extension WebCore.CSSImageSwiftParts {
    /// Empty parts, through the C++ constructor that Swift calls without zero-filling the object first.
    @inline(always)
    init() {
        self.init(0)
    }

    /// Appends components `indices` of `components`.
    mutating func append(_ components: borrowing WebCore.CSSColorSwiftComponents, _ indices: Range<UInt8>) {
        for index in indices {
            append(components, index)
        }
    }

    /// Appends border-image rules: the first one, and the second or the first again.
    mutating func appendRules(_ rules: borrowing WebCore.CSSColorSwiftComponents, _ count: UInt8) {
        append(rules, 0)
        append(rules, count == 2 ? 1 : 0)
    }
}

extension PropertyParser {
    /// setBorderResult for `consumer`, with any mask-border in `parts`.
    private func setBorderResult(_ consumer: WebCore.CSSPropertyConsumerSwiftConsumer, _ parts: consuming WebCore.CSSImageSwiftParts) -> PropertyValue? {
        _ = WebCore.setBorderResult(tokens.value, consumer.rawValue, consuming: consume parts, UInt32.max)
        return nil
    }

    /// `consumeBorderRadius` for border-radius, or with the quirk of -webkit-border-radius, where `a b` is `a / b`:
    /// <length-percentage [0,∞]>{1,4} [ / <length-percentage [0,∞]>{1,4} ]?
    private mutating func consumeBorderRadius(_ consumer: WebCore.CSSPropertyConsumerSwiftConsumer) -> PropertyValue? {
        var parts = WebCore.CSSImageSwiftParts()
        guard consumeBorderRadius(&parts, consumer) else {
            return nil
        }
        return setBorderResult(consumer, parts)
    }

    /// Appends the eight radii of `consumeBorderRadius`, horizontal then vertical, absent ones completing the present.
    mutating func consumeBorderRadius(_ parts: inout WebCore.CSSImageSwiftParts, _ consumer: WebCore.CSSPropertyConsumerSwiftConsumer) -> Bool {
        var horizontal = WebCore.CSSColorSwiftComponents()
        var count: UInt8 = 0
        while count < 4 && !atEnd && peekType() != PropertyTokenType.delimiter {
            guard consumeNumeric(&horizontal, count, .nonnegativeLengthPercentage) else {
                return false
            }
            count += 1
        }
        guard count != 0 else {
            return false
        }
        // Absent radii complete the present ones.
        let absent = WebCore.CSSColorSwiftComponents()
        if atEnd {
            if consumer == .WebKitBorderRadius && count == 2 {
                parts.append(horizontal, 0..<1)
                parts.append(absent, 1..<4)
                parts.append(horizontal, 1..<2)
                parts.append(absent, 1..<4)
            } else {
                parts.append(horizontal, 0..<4)
                parts.append(horizontal, 0..<4)
            }
            return true
        }
        guard consumeSlash() else {
            return false
        }
        var vertical = WebCore.CSSColorSwiftComponents()
        var verticalCount: UInt8 = 0
        while verticalCount < 4 && !atEnd {
            guard consumeNumeric(&vertical, verticalCount, .nonnegativeLengthPercentage) else {
                return false
            }
            verticalCount += 1
        }
        guard verticalCount != 0, atEnd else {
            return false
        }
        parts.append(horizontal, 0..<4)
        parts.append(vertical, 0..<4)
        return true
    }

    /// `consumeUnresolvedBorderImageSource`: none | <image>. Consumes nothing if it is neither.
    mutating func consumeBorderImageSource() -> BorderImageSource? {
        if peekIdent() == .None {
            consumeIncludingWhitespace()
            return BorderImageSource(image: nil)
        }
        let start = index
        guard let image = consumeImage(defaultAllowedImageTypes) else {
            index = start
            return nil
        }
        return BorderImageSource(image: image)
    }

    /// `consumeUnresolvedBorderImageOutset` into `outset`: [ <length [0,∞]> | <number [0,∞]> ]{1,4}
    mutating func consumeBorderImageOutset(_ outset: inout WebCore.CSSColorSwiftComponents) -> Bool {
        var count: UInt8 = 0
        while count < 4 && (consumeNumeric(&outset, count, .nonnegativeNumber) || consumeNumeric(&outset, count, .nonnegativeLength)) {
            count += 1
        }
        return count != 0
    }

    /// `consumeUnresolvedBorderImageRepeat` into `rules` as symbols: [ stretch | repeat | round | space ]{1,2}. Returns
    /// how many it consumed.
    mutating func consumeBorderImageRepeat(_ rules: inout WebCore.CSSColorSwiftComponents) -> UInt8 {
        var count: UInt8 = 0
        while count < 2 {
            let id = peekIdent()
            guard id == .Stretch || id == .Repeat || id == .Round || id == .Space else {
                break
            }
            consumeIncludingWhitespace()
            rules.setSymbol(count, id.rawValue)
            count += 1
        }
        return count
    }

    /// Whether the CSSPropertyConsumerSwiftBorderImageSliceAlwaysFill option is set.
    var sliceAlwaysFill: Bool {
        tokens.value.consumerOptions() & UInt8(WebCore.CSSPropertyConsumerSwiftBorderImageSliceAlwaysFill) != 0
    }

    /// `consumeUnresolvedBorderImageSlice` into `slice` and its fill into `fill` 0, filled if `alwaysFill`:
    /// [<number [0,∞]> | <percentage [0,∞]>]{1,4} && fill?
    mutating func consumeBorderImageSlice(_ slice: inout WebCore.CSSColorSwiftComponents, _ fill: inout WebCore.CSSColorSwiftComponents, alwaysFill: Bool) -> Bool {
        var hasFill = peekIdent() == .Fill
        if hasFill {
            consumeIncludingWhitespace()
        }
        var count: UInt8 = 0
        while count < 4 && (consumeNumeric(&slice, count, .nonnegativePercentage) || consumeNumeric(&slice, count, .nonnegativeNumber)) {
            count += 1
        }
        guard count != 0 else {
            return false
        }
        if !hasFill && peekIdent() == .Fill {
            consumeIncludingWhitespace()
            hasFill = true
        }
        // For backwards compatibility, -webkit-border-image sets fill unconditionally.
        if hasFill || alwaysFill {
            fill.setSymbol(0, WebCore.CSSValueID.Fill.rawValue)
        }
        return true
    }

    /// `consumeUnresolvedBorderImageWidth` into `width`: [ <length-percentage [0,∞]> | <number [0,∞]> | auto ]{1,4}
    mutating func consumeBorderImageWidth(_ width: inout WebCore.CSSColorSwiftComponents) -> Bool {
        var count: UInt8 = 0
        while count < 4 {
            // FIXME: Figure out and document why the <length-percentage> is consumed in standard mode here, or remove
            // the special case.
            // FIXME: As this falls into the "<length> ambiguous with <number>" case, the <length-percentage> should
            // probably forbid a unitless zero in case the order of checks ever changes.
            if !consumeNumeric(&width, count, .nonnegativeNumber) && !consumeNumeric(&width, count, .standardModeNonnegativeLengthPercentage) {
                guard peekIdent() == .Auto else {
                    break
                }
                consumeIncludingWhitespace()
                width.setSymbol(count, WebCore.CSSValueID.Auto.rawValue)
            }
            count += 1
        }
        return count != 0
    }

    /// `consumeUnresolvedBoxShadow`: none | <shadow>#. Consumes nothing if it is neither.
    private mutating func consumeBoxShadow(_ consumer: WebCore.CSSPropertyConsumerSwiftConsumer) -> PropertyValue? {
        var parts = WebCore.CSSImageSwiftParts()
        if peekIdent() == .None {
            consumeIncludingWhitespace()
            return setBorderResult(consumer, parts)
        }
        let start = index
        repeat {
            guard consumeShadow(&parts) else {
                index = start
                return nil
            }
        } while consumeComma()
        return setBorderResult(consumer, parts)
    }

    /// `consumeSingleUnresolvedBoxShadow` into `parts`: <color>? && [<length>{2} <length [0,∞]>? <length>?] && inset?,
    /// in at most three parts.
    private mutating func consumeShadow(_ parts: inout WebCore.CSSImageSwiftParts) -> Bool {
        var state = gradientColorState()
        var color = WebCore.CSSColorSwiftStopColor()
        var channels = WebCore.CSSColorSwiftComponents()
        var inset = WebCore.CSSColorSwiftComponents()
        var lengths = WebCore.CSSColorSwiftComponents()
        for _ in 0..<3 {
            // A comma ends this shadow of a list.
            guard !atEnd, peekType() != PropertyTokenType.comma else {
                break
            }
            if peekIdent() == .Inset {
                guard inset.type(0) == 0 else {
                    return false
                }
                consumeIncludingWhitespace()
                inset.setSymbol(0, WebCore.CSSValueID.Inset.rawValue)
                continue
            }
            if color.kind == UInt8(WebCore.CSSColorSwiftNoColor) {
                color = consumeStopColor(&state, &channels)
                if color.kind != UInt8(WebCore.CSSColorSwiftNoColor) {
                    continue
                }
            } else {
                var otherChannels = WebCore.CSSColorSwiftComponents()
                guard consumeStopColor(&state, &otherChannels).kind == UInt8(WebCore.CSSColorSwiftNoColor) else {
                    return false
                }
            }
            // Neither a color nor inset: the lengths, which only one part can be.
            guard lengths.type(0) == 0, consumeNumeric(&lengths, 0, .length), consumeNumeric(&lengths, 1, .length) else {
                return false
            }
            // Only a length fails the shadow if it is out of range.
            let type = peekType()
            if type == PropertyTokenType.dimension || type == PropertyTokenType.number
                || (type == PropertyTokenType.function && cssCalcIsMathFunction(tokens.value.identifier(index)))
            {
                guard consumeNumeric(&lengths, 2, .nonnegativeLength) else {
                    return false
                }
                _ = consumeNumeric(&lengths, 3, .length)
            }
        }
        guard lengths.type(0) != 0 else {
            return false
        }
        parts.appendColor(tokens.value, color, channels, inset)
        parts.append(lengths, 0..<4)
        return true
    }
}

// MARK: - Color parsing

/// `ColorParserState`: what the color being consumed may be, and how deeply it is nested in other colors.
struct ColorConsumerState {
    /// OptionSet<CSS::ColorType>.
    let allowedColorTypes: UInt8
    /// The CSSColorSwift context bits.
    let context: UInt8
    var nestingLevel: UInt32 = 0
}

/// What consumeSimpleColor consumed.
private enum SimpleColor {
    case keyword(WebCore.CSSValueID)
    case hex(WebCore.CSSPropertyConsumerSwiftSRGBA8)
    /// A function token, which may be a color function.
    case function
    case notAColor
}

private typealias ColorDescriptor = WebCore.CSSColorSwiftDescriptor

/// What consumeAbsoluteColorFunction consumed.
private enum AbsoluteColorFunction {
    /// The channels of a color function with this descriptor.
    case absolute(ColorDescriptor)
    /// The function token of a relative color named this, whose arguments come next.
    case relative(WebCore.CSSValueID, PropertyParser.Function)
    /// Nothing, before color-layers(), color-mix(), contrast-color(), light-dark() or alpha().
    case other
    case notAColor
}

extension PropertyParser {
    func colorParserState() -> ColorConsumerState {
        ColorConsumerState(allowedColorTypes: tokens.value.consumerOptions(), context: WebCore.colorContextForSwift(tokens.value))
    }

    /// The color consumer bottleneck, `consumeColor(CSSParserTokenRange&, ColorParserState&)`: a keyword, a hex color or a
    /// color function. Consumes nothing if there is none.
    mutating func consumeColor(_ state: inout ColorConsumerState) -> WebCore.CSS.Color? {
        // At most one level for each token.
        state.nestingLevel &+= 1
        defer {
            state.nestingLevel &-= 1 // Incremented above.
        }

        switch consumeSimpleColor(state) {
        case .keyword(let id):
            return WebCore.CSS.Color(consuming: WebCore.CSS.KeywordColor(valueID: id))
        case .hex(let hex):
            return WebCore.CSS.Color(consuming: WebCore.CSS.HexColor(value: hex))
        case .function:
            return consumeColorFunction(&state)
        case .notAColor:
            return nil
        }
    }

    /// consumeColor's keyword or hex color, consumed; a function token, which may begin a color function; or no
    /// color, with nothing consumed.
    private mutating func consumeSimpleColor(_ state: ColorConsumerState) -> SimpleColor {
        let type = peekType()
        if type == PropertyTokenType.ident {
            let keyword = peekIdent()
            switch WebCore.colorKeywordForSwift(tokens.value, keyword.rawValue, state.allowedColorTypes) {
            case UInt8(WebCore.CSSColorSwiftAllowedKeyword):
                consumeIncludingWhitespace()
                return .keyword(keyword)
            case UInt8(WebCore.CSSColorSwiftDisallowedKeyword):
                return .notAColor
            default:
                break
            }
        }

        if let hex = consumeHexColor(type, state) {
            return .hex(hex)
        }

        return type == PropertyTokenType.function ? .function : .notAColor
    }

    // MARK: Hex

    /// `consumeHexColor`: a hash token, or in quirks mode a <quirky-color>, of 3, 4, 6 or 8 hex digits.
    private mutating func consumeHexColor(_ type: UInt8, _ state: ColorConsumerState) -> WebCore.CSSPropertyConsumerSwiftSRGBA8? {
        var digits = [8 of UInt16](repeating: 0)
        var count = 0
        if type == UInt8(WebCore.HashToken.rawValue) {
            let text = tokens.value.hexColorText(index)
            count = Int(text.length)
            guard count == 3 || count == 4 || count == 6 || count == 8 else {
                return nil
            }
            var characters = text.characters
            for i in 0..<count {
                // i is below count, at most 8.
                digits[i] = UInt16(truncatingIfNeeded: characters & 0xFF)
                characters >>= 8
            }
        } else {
            // <quirky-color> should only match for properties that explicitly opt-in and when not nested.
            // https://drafts.csswg.org/css-color-4/#quirky-color
            guard state.context & UInt8(WebCore.CSSColorSwiftAcceptsQuirkyColor) != 0, state.nestingLevel <= 1 else {
                return nil
            }
            if type == PropertyTokenType.ident {
                // e.g. FF0000
                let text = tokens.value.hexColorText(index)
                count = Int(text.length)
                guard count == 3 || count == 6 else {
                    return nil
                }
                var characters = text.characters
                for i in 0..<count {
                    // i is below count, at most 6.
                    digits[i] = UInt16(truncatingIfNeeded: characters & 0xFF)
                    characters >>= 8
                }
            } else if type == PropertyTokenType.number || type == PropertyTokenType.dimension {
                // e.g. 112233 or 0001FF: the integer's digits and the unit, left-padded with zeros to six.
                guard tokens.value.isIntegerNumeric(index) else {
                    return nil
                }
                let numericValue = tokens.value.numericValue(index)
                guard numericValue >= 0 && numericValue < 1000000 else {
                    return nil
                }
                var integer = Int(numericValue)
                var integerDigits = 1
                var power = 10
                while integer >= power {
                    // Both at most 10^6.
                    integerDigits &+= 1
                    power &*= 10
                }
                // A number token's text is empty.
                let unit = tokens.value.hexColorText(index)
                let unitLength = Int(unit.length)
                // Neither is more than the token's length.
                guard integerDigits &+ unitLength <= 6 else {
                    return nil
                }
                count = 6
                for i in 0..<6 {
                    digits[i] = 0x30
                }
                // The unit ends the six, and the digits end before it: both within them, as checked above.
                let unitStart = 6 &- unitLength
                var characters = unit.characters
                for i in 0..<unitLength {
                    digits[unitStart &+ i] = UInt16(truncatingIfNeeded: characters & 0xFF)
                    characters >>= 8
                }
                // The integer's digits end at unitStart and start at or after 0, as checked above; each is 0x30 to 0x39.
                var position = unitStart
                repeat {
                    position &-= 1
                    digits[position] = UInt16(truncatingIfNeeded: 0x30 &+ integer % 10)
                    integer /= 10
                } while integer > 0
            } else {
                return nil
            }
        }
        let argb = cssHexColor(digits.span.extracting(0..<count))
        guard argb >= 0 else {
            return nil
        }
        consumeIncludingWhitespace()
        return WebCore.CSSPropertyConsumerSwiftSRGBA8(
            UInt8(truncatingIfNeeded: argb >> 16),
            UInt8(truncatingIfNeeded: argb >> 8),
            UInt8(truncatingIfNeeded: argb),
            UInt8(truncatingIfNeeded: argb >> 24)
        )
    }

    // MARK: Functions

    /// `consumeAColorFunction`: the color function at the next token, a function token. Consumes nothing if it is not one.
    private mutating func consumeColorFunction(_ state: inout ColorConsumerState) -> WebCore.CSS.Color? {
        var components = WebCore.CSSColorSwiftComponents()
        let function = consumeAbsoluteColorFunction(&components)
        if case .absolute(let descriptor) = function {
            return WebCore.makeAbsoluteColor(tokens.value, descriptor.rawValue, components, state.nestingLevel)
        }
        return consumeColorFunction(after: function, &state)
    }

    /// `consumeAColorFunction` for rgb(), rgba(), hsl(), hsla(), hwb(), lab(), lch(), oklab(), oklch() and color()
    /// without `from`: their channels, into `components`. Consumes nothing unless it returns `.absolute`, except the
    /// function token of a relative color, whose arguments it leaves to `consumeColorFunction(after:)`.
    private mutating func consumeAbsoluteColorFunction(_ components: inout WebCore.CSSColorSwiftComponents) -> AbsoluteColorFunction {
        let name = peekFunction()
        switch name {
        case .Rgb, .Rgba, .Hsl, .Hsla, .Hwb, .Lab, .Lch, .Oklab, .Oklch, .Color:
            break
        case .ColorMix, .ContrastColor, .LightDark, .Alpha, .ColorLayers:
            return .other
        default:
            return .notAColor
        }
        guard let function = beginFunction(name) else {
            return .notAColor
        }
        if peekIdent() == .From {
            return .relative(name, function)
        }
        let descriptor: ColorDescriptor?
        switch name {
        case .Rgb, .Rgba:
            descriptor = consumeRGBChannels(&components)
        case .Hsl, .Hsla:
            descriptor = consumeHSLChannels(&components)
        case .Hwb:
            descriptor = consumeGenericChannels(ColorDescriptor.HWB, &components)
        case .Lab:
            descriptor = consumeGenericChannels(ColorDescriptor.Lab, &components)
        case .Lch:
            descriptor = consumeGenericChannels(ColorDescriptor.LCH, &components)
        case .Oklab:
            descriptor = consumeGenericChannels(ColorDescriptor.OKLab, &components)
        case .Oklch:
            descriptor = consumeGenericChannels(ColorDescriptor.OKLCH, &components)
        default:
            descriptor = consumeColorFunctionChannels(&components)
        }
        endColorFunction(function, descriptor != nil)
        guard let descriptor else {
            return .notAColor
        }
        return .absolute(descriptor)
    }

    /// `consumeAColorFunction` for the colors consumeAbsoluteColorFunction leaves to it: relative colors, whose
    /// arguments it began, color-layers(), color-mix(), contrast-color(), light-dark() and alpha().
    private mutating func consumeColorFunction(after absolute: AbsoluteColorFunction, _ state: inout ColorConsumerState) -> WebCore.CSS.Color? {
        let name: WebCore.CSSValueID
        let function: Function
        switch absolute {
        case .relative(let relativeName, let arguments):
            name = relativeName
            function = arguments
        case .other:
            name = peekFunction()
            if name == .ColorLayers {
                guard state.context & UInt8(WebCore.CSSColorSwiftColorLayersEnabled) != 0 else {
                    return nil
                }
            }
            guard let arguments = beginFunction(name) else {
                return nil
            }
            function = arguments
        case .absolute, .notAColor:
            return nil
        }
        let color: WebCore.CSS.Color?
        switch name {
        case .Rgb, .Rgba:
            color = consumeRelativeArguments(ColorDescriptor.RGBModernRelative, &state)
        case .Hsl, .Hsla:
            color = consumeRelativeArguments(ColorDescriptor.HSLModern, &state)
        case .Hwb:
            color = consumeRelativeArguments(ColorDescriptor.HWB, &state)
        case .Lab:
            color = consumeRelativeArguments(ColorDescriptor.Lab, &state)
        case .Lch:
            color = consumeRelativeArguments(ColorDescriptor.LCH, &state)
        case .Oklab:
            color = consumeRelativeArguments(ColorDescriptor.OKLab, &state)
        case .Oklch:
            color = consumeRelativeArguments(ColorDescriptor.OKLCH, &state)
        case .Color:
            color = consumeRelativeColorFunctionArguments(&state)
        case .ColorLayers:
            color = consumeColorLayersArguments(&state)
        case .ColorMix:
            color = consumeColorMixArguments(&state)
        case .ContrastColor:
            color = consumeContrastColorArguments(&state)
        case .LightDark:
            color = consumeLightDarkArguments(&state)
        default:
            color = consumeRelativeAlphaArguments(&state)
        }
        endColorFunction(function, color != nil)
        return color
    }

    /// Leaves the arguments of `function`, consuming it and the whitespace after it if `consumed`, else nothing.
    mutating func endColorFunction(_ function: Function, _ consumed: Bool) {
        end = function.end
        guard consumed else {
            index = function.start
            return
        }
        index = function.next
        consumeWhitespace()
    }

    /// `consumeSlashIncludingWhitespace`.
    mutating func consumeSlash() -> Bool {
        guard peekType() == PropertyTokenType.delimiter, tokens.value.delimiter(index) == 0x2F else {
            return false
        }
        consumeIncludingWhitespace()
        return true
    }

    /// rgb() and rgba() without `from`: legacy or modern, as the first channel and the separator after it decide.
    private mutating func consumeRGBChannels(_ components: inout WebCore.CSSColorSwiftComponents) -> ColorDescriptor? {
        guard consumeChannel(&components, ColorDescriptor.RGBModernAbsolute, 0, relative: false) else {
            return nil
        }
        guard consumeComma() else {
            return consumeAbsoluteChannels(&components, ColorDescriptor.RGBModernAbsolute, legacy: false)
        }
        // `none` is invalid for the legacy syntax, which the first channel's consumer did not know yet.
        switch components.type(0) {
        case UInt8(WebCore.CSSColorSwiftChannelPercentage):
            return consumeAbsoluteChannels(&components, ColorDescriptor.RGBLegacyPercentage, legacy: true)
        case UInt8(WebCore.CSSColorSwiftChannelNumber):
            return consumeAbsoluteChannels(&components, ColorDescriptor.RGBLegacyNumber, legacy: true)
        default:
            return nil
        }
    }

    /// hsl() and hsla() without `from`: legacy or modern, as the first channel and the separator after it decide.
    private mutating func consumeHSLChannels(_ components: inout WebCore.CSSColorSwiftComponents) -> ColorDescriptor? {
        guard consumeChannel(&components, ColorDescriptor.HSLModern, 0, relative: false) else {
            return nil
        }
        guard consumeComma() else {
            return consumeAbsoluteChannels(&components, ColorDescriptor.HSLModern, legacy: false)
        }
        guard components.type(0) != UInt8(WebCore.CSSColorSwiftChannelNone) else {
            return nil
        }
        return consumeAbsoluteChannels(&components, ColorDescriptor.HSLLegacy, legacy: true)
    }

    /// hwb(), lab(), lch(), oklab() and oklch() without `from`.
    private mutating func consumeGenericChannels(_ descriptor: ColorDescriptor, _ components: inout WebCore.CSSColorSwiftComponents) -> ColorDescriptor? {
        guard consumeChannel(&components, descriptor, 0, relative: false) else {
            return nil
        }
        return consumeAbsoluteChannels(&components, descriptor, legacy: false)
    }

    /// color() without `from`: a color space and its channels.
    private mutating func consumeColorFunctionChannels(_ components: inout WebCore.CSSColorSwiftComponents) -> ColorDescriptor? {
        guard let descriptor = consumeColorSpace(), consumeChannel(&components, descriptor, 0, relative: false) else {
            return nil
        }
        return consumeAbsoluteChannels(&components, descriptor, legacy: false)
    }

    /// color() at `from`: an origin color, a color space and its channels.
    private mutating func consumeRelativeColorFunctionArguments(_ state: inout ColorConsumerState) -> WebCore.CSS.Color? {
        consumeIncludingWhitespace()
        guard let origin = consumeColor(&state), let descriptor = consumeColorSpace(),
            let components = consumeRelativeChannels(descriptor)
        else {
            return nil
        }
        return WebCore.makeRelativeColor(descriptor.rawValue, components, consuming: consume origin)
    }

    /// `consumeColorSpace`: the predefined color space of color().
    private mutating func consumeColorSpace() -> ColorDescriptor? {
        let descriptor: ColorDescriptor
        switch peekIdent() {
        case .A98Rgb: descriptor = .A98RGB
        case .DisplayP3: descriptor = .DisplayP3
        case .DisplayP3Linear: descriptor = .DisplayP3Linear
        case .ProphotoRgb: descriptor = .ProPhotoRGB
        case .Rec2020: descriptor = .Rec2020
        case .SRGB: descriptor = .SRGB
        case .SrgbLinear: descriptor = .SRGBLinear
        case .XyzD50: descriptor = .XYZD50
        case .Xyz, .XyzD65: descriptor = .XYZD65
        default: return nil
        }
        consumeIncludingWhitespace()
        return descriptor
    }

    /// `consumeAbsoluteFunctionParameters` after the first channel, and after the comma that follows it in the legacy
    /// syntax.
    private mutating func consumeAbsoluteChannels(
        _ components: inout WebCore.CSSColorSwiftComponents,
        _ descriptor: ColorDescriptor,
        legacy: Bool
    ) -> ColorDescriptor? {
        guard consumeChannel(&components, descriptor, 1, relative: false) else {
            return nil
        }
        if legacy {
            guard consumeComma() else {
                return nil
            }
        }
        guard consumeChannel(&components, descriptor, 2, relative: false) else {
            return nil
        }
        if legacy ? consumeComma() : consumeSlash() {
            guard consumeChannel(&components, descriptor, 3, relative: false) else {
                return nil
            }
        }
        guard atEnd else {
            return nil
        }
        return descriptor
    }

    /// `consumeRelativeFunctionParameters` at `from`.
    private mutating func consumeRelativeArguments(_ descriptor: ColorDescriptor, _ state: inout ColorConsumerState) -> WebCore.CSS.Color? {
        consumeIncludingWhitespace()
        guard let origin = consumeColor(&state), let components = consumeRelativeChannels(descriptor) else {
            return nil
        }
        return WebCore.makeRelativeColor(descriptor.rawValue, components, consuming: consume origin)
    }

    /// `consumeRelativeFunctionParameters` after the origin color: the channels.
    private mutating func consumeRelativeChannels(_ descriptor: ColorDescriptor) -> WebCore.CSSColorSwiftComponents? {
        var components = WebCore.CSSColorSwiftComponents()
        for channel: UInt8 in 0..<3 {
            guard consumeChannel(&components, descriptor, channel, relative: true) else {
                return nil
            }
        }
        if consumeSlash() {
            guard consumeChannel(&components, descriptor, 3, relative: true) else {
                return nil
            }
        }
        guard atEnd else {
            return nil
        }
        return components
    }

    /// color-layers(): colors separated by commas. Its blend mode is never parsed.
    private mutating func consumeColorLayersArguments(_ state: inout ColorConsumerState) -> WebCore.CSS.Color? {
        var colors = WebCore.CSSColorSwiftList()
        repeat {
            guard let color = consumeColor(&state) else {
                return nil
            }
            colors.append(consuming: consume color)
        } while consumeComma()
        guard atEnd else {
            return nil
        }
        return WebCore.makeColorLayers(consuming: consume colors)
    }

    /// color-mix(): a color interpolation method or not, and colors, each with a percentage before or after it or not.
    private mutating func consumeColorMixArguments(_ state: inout ColorConsumerState) -> WebCore.CSS.Color? {
        var components = WebCore.CSSColorSwiftList()
        if peekIdent() == .In {
            guard let method = consumeColorInterpolationMethod(), consumeComma() else {
                return nil
            }
            components.setColorInterpolationMethod(consuming: consume method)
        }
        repeat {
            var percentage = WebCore.CSSColorSwiftComponents()
            let percentageFirst = consumeMixPercentage(&percentage)
            guard let color = consumeColor(&state) else {
                return nil
            }
            if !percentageFirst {
                _ = consumeMixPercentage(&percentage)
            }
            components.appendMixComponent(percentage, consuming: consume color)
        } while consumeComma()
        guard atEnd else {
            return nil
        }
        return WebCore.makeColorMix(consuming: consume components)
    }

    /// contrast-color(): one color.
    private mutating func consumeContrastColorArguments(_ state: inout ColorConsumerState) -> WebCore.CSS.Color? {
        guard let color = consumeColor(&state), atEnd else {
            return nil
        }
        return WebCore.CSS.Color(consuming: WebCore.CSS.ContrastColor(color: consume color))
    }

    /// light-dark(): two colors.
    private mutating func consumeLightDarkArguments(_ state: inout ColorConsumerState) -> WebCore.CSS.Color? {
        guard let light = consumeColor(&state), consumeComma(), let dark = consumeColor(&state), atEnd else {
            return nil
        }
        return WebCore.CSS.Color(consuming: WebCore.CSS.LightDarkColor(lightColor: consume light, darkColor: consume dark))
    }

    /// alpha(): `from`, an origin color, `/` and its alpha.
    private mutating func consumeRelativeAlphaArguments(_ state: inout ColorConsumerState) -> WebCore.CSS.Color? {
        guard peekIdent() == .From else {
            return nil
        }
        consumeIncludingWhitespace()
        guard let origin = consumeColor(&state), consumeSlash() else {
            return nil
        }
        var components = WebCore.CSSColorSwiftComponents()
        guard consumeChannel(&components, ColorDescriptor.Alpha, 0, relative: true), atEnd else {
            return nil
        }
        return WebCore.makeRelativeAlphaColor(components, consuming: consume origin)
    }

    // MARK: Channels

    /// `consumeAbsoluteComponent` or `consumeRelativeComponent`: channel `channel` of a color with `descriptor`, as
    /// MetaConsumer consumes its types in order. Consumes nothing if it is not one.
    private mutating func consumeChannel(
        _ components: inout WebCore.CSSColorSwiftComponents,
        _ descriptor: ColorDescriptor,
        _ channel: UInt8,
        relative: Bool
    ) -> Bool {
        let types = WebCore.colorSwiftChannel(descriptor.rawValue, channel).types
        let none = UInt8(WebCore.CSSColorSwiftChannelNone)
        let number = UInt8(WebCore.CSSColorSwiftChannelNumber)
        let percentage = UInt8(WebCore.CSSColorSwiftChannelPercentage)
        let angle = UInt8(WebCore.CSSColorSwiftChannelAngle)
        let type = peekType()
        switch type {
        case PropertyTokenType.function:
            // A <percentage> or an <angle> is listed before a <number>.
            if types & percentage != 0
                && consumeChannelCalc(&components, channel, percentage, min: -.infinity, max: .infinity, descriptor, relative: relative)
            {
                return true
            }
            if types & angle != 0 && consumeChannelCalc(&components, channel, angle, min: -.infinity, max: .infinity, descriptor, relative: relative) {
                return true
            }
            return types & number != 0
                && consumeChannelCalc(&components, channel, number, min: -.infinity, max: .infinity, descriptor, relative: relative)
        case PropertyTokenType.number:
            let value = tokens.value.numericValue(index)
            if types & angle != 0, !value.isInfinite,
                let unit = angleUnit(type, tokens.value.unitType(index), value, parserMode, numericFlags, allowsUnitlessZero: false)
            {
                components.setValue(channel, angle, unit.rawValue, value)
            } else if types & number != 0, !value.isInfinite {
                components.setValue(channel, number, 0, value)
            } else {
                return false
            }
        case PropertyTokenType.percentage:
            let value = tokens.value.numericValue(index)
            guard types & percentage != 0, !value.isInfinite else {
                return false
            }
            components.setValue(channel, percentage, 0, value)
        case PropertyTokenType.dimension:
            let value = tokens.value.numericValue(index)
            guard types & angle != 0, !value.isInfinite,
                let unit = angleUnit(type, tokens.value.unitType(index), value, parserMode, numericFlags, allowsUnitlessZero: false)
            else {
                return false
            }
            components.setValue(channel, angle, unit.rawValue, value)
        case PropertyTokenType.ident:
            let id = peekIdent()
            if types & none != 0 && id == .None {
                components.setNone(channel)
            } else if relative && isChannelSymbol(descriptor, id.rawValue) {
                components.setSymbol(channel, id.rawValue)
            } else {
                return false
            }
        default:
            return false
        }
        consumeIncludingWhitespace()
        return true
    }

    /// Whether `id` is the symbol of a channel of a relative color with `descriptor`.
    private func isChannelSymbol(_ descriptor: ColorDescriptor, _ id: UInt16) -> Bool {
        let channels: UInt8 = descriptor == .Alpha ? 1 : 4
        for channel in 0..<channels where WebCore.colorSwiftChannel(descriptor.rawValue, channel).symbol == id {
            return true
        }
        return false
    }

    /// `FunctionConsumerForCalcValues`: a math function at the next token, a function token, parsed as `type` in the
    /// range [min, max] into component `channel`, with the channels' symbols if `relative`.
    private mutating func consumeChannelCalc(
        _ components: inout WebCore.CSSColorSwiftComponents,
        _ channel: UInt8,
        _ type: UInt8,
        min: Double,
        max: Double,
        _ descriptor: ColorDescriptor,
        relative: Bool
    ) -> Bool {
        let name = tokens.value.identifier(index)
        guard cssCalcIsMathFunction(name), let function = beginFunction(peekFunction()) else {
            return false
        }
        // Both at most the token count, an Int from a UInt32.
        let argumentsStart = UInt32(truncatingIfNeeded: index)
        let argumentsEnd = UInt32(truncatingIfNeeded: end)
        let parsed = components.parseCalc(tokens.value, channel, type, min, max, argumentsStart, argumentsEnd, name, descriptor.rawValue, relative)
        endColorFunction(function, parsed)
        return parsed
    }

    /// `MetaConsumer<CSS::Percentage<Range { 0, 100 }>>`, into component 0. Consumes nothing if it is not one.
    private mutating func consumeMixPercentage(_ components: inout WebCore.CSSColorSwiftComponents) -> Bool {
        let percentage = UInt8(WebCore.CSSColorSwiftChannelPercentage)
        switch peekType() {
        case PropertyTokenType.percentage:
            let value = tokens.value.numericValue(index)
            guard value >= 0 && value <= 100 else {
                return false
            }
            components.setValue(0, percentage, 0, value)
            consumeIncludingWhitespace()
            return true
        case PropertyTokenType.function:
            return consumeChannelCalc(&components, 0, percentage, min: 0, max: 100, ColorDescriptor.Alpha, relative: false)
        default:
            return false
        }
    }

    // MARK: Color interpolation methods

    /// `consumeColorInterpolationMethod`, at `in`.
    mutating func consumeColorInterpolationMethod() -> WebCore.CSS.ColorInterpolationMethod? {
        var method = WebCore.CSS.ColorInterpolationMethod()
        // Both at most the token count, an Int from a UInt32.
        let consumed = WebCore.consumeColorInterpolationMethodForSwift(tokens.value, UInt32(truncatingIfNeeded: index), UInt32(truncatingIfNeeded: end), &method)
        guard consumed != UInt32.max else {
            return nil
        }
        index &+= Int(consumed) // At most the tokens from index to end.
        return method
    }

    // MARK: Dynamic range limits

    /// `consumeUnresolvedDynamicRangeLimit`: `standard`, `constrained`, `no-limit` or dynamic-range-limit-mix(), with the
    /// CSSColorSwift context bits `context`. Consumes nothing if there is none.
    mutating func consumeDynamicRangeLimit(_ context: UInt8) -> WebCore.CSS.DynamicRangeLimit? {
        let keyword = peekIdent()
        switch keyword {
        case .Standard:
            consumeIncludingWhitespace()
            return WebCore.CSS.DynamicRangeLimit(WebCore.CSS.Keyword.Standard())
        case .NoLimit:
            consumeIncludingWhitespace()
            return WebCore.CSS.DynamicRangeLimit(WebCore.CSS.Keyword.NoLimit())
        case .Constrained:
            guard context & UInt8(WebCore.CSSColorSwiftConstrainedDynamicRangeLimitEnabled) != 0 else {
                return nil
            }
            consumeIncludingWhitespace()
            return WebCore.CSS.DynamicRangeLimit(WebCore.CSS.Keyword.Constrained())
        default:
            break
        }
        guard context & UInt8(WebCore.CSSColorSwiftDynamicRangeLimitMixEnabled) != 0,
            let function = beginFunction(.DynamicRangeLimitMix)
        else {
            return nil
        }
        // dynamic-range-limit-mix() = dynamic-range-limit-mix( [ <'dynamic-range-limit'> && <percentage [0,100]> ]#{2,} )
        var mix = WebCore.CSSDynamicRangeLimitSwiftMix()
        repeat {
            var percentage = WebCore.CSSColorSwiftComponents()
            let percentageFirst = consumeMixPercentage(&percentage)
            guard let limit = consumeDynamicRangeLimit(context) else {
                endColorFunction(function, false)
                return nil
            }
            if !percentageFirst {
                guard consumeMixPercentage(&percentage) else {
                    endColorFunction(function, false)
                    return nil
                }
            }
            mix.append(percentage, consuming: consume limit)
        } while consumeComma()
        guard atEnd, mix.size() >= 2 else {
            endColorFunction(function, false)
            return nil
        }
        endColorFunction(function, true)
        return WebCore.makeDynamicRangeLimitMix(consuming: consume mix)
    }
}

// MARK: - Position parsing

/// Where setPositionResult finds a position's parts among the components: a horizontal keyword or offset, its length,
/// a vertical keyword or offset and its length, four bits each, 0xf for none.
func positionLayout(_ horizontal: UInt16, _ horizontalLength: UInt16 = 0xf, vertical: UInt16, _ verticalLength: UInt16 = 0xf) -> UInt16 {
    horizontal | horizontalLength << 4 | vertical << 8 | verticalLength << 12
}

/// `IsHorizontalOnlyComponent` and `IsVerticalOnlyComponent`: a keyword of one axis. A <length-percentage> is Invalid.
private func isHorizontalOnly(_ id: WebCore.CSSValueID) -> Bool {
    id == .Left || id == .Right || id == .XStart || id == .XEnd
}

private func isVerticalOnly(_ id: WebCore.CSSValueID) -> Bool {
    id == .Top || id == .Bottom || id == .YStart || id == .YEnd
}

extension PropertyParser {
    func axisRelativePositionKeywordsEnabled() -> Bool {
        WebCore.colorContextForSwift(tokens.value) & UInt8(WebCore.CSSColorSwiftAxisRelativePositionKeywordsEnabled) != 0
    }

    /// `consumePositionUnresolvedComponent` into component `slot`: a keyword, which it returns, or a
    /// <length-percentage>, for which it returns Invalid. Consumes nothing and returns nil if there is neither.
    private mutating func consumePositionComponent(
        _ components: inout WebCore.CSSColorSwiftComponents,
        _ slot: UInt8
    ) -> WebCore.CSSValueID? {
        guard peekType() == PropertyTokenType.ident else {
            return consumeNumeric(&components, slot, .lengthPercentage) ? .Invalid : nil
        }
        let id = peekIdent()
        switch id {
        case .Left, .Right, .Top, .Bottom, .Center:
            break
        case .XStart, .XEnd, .YStart, .YEnd:
            guard axisRelativePositionKeywordsEnabled() else {
                return nil
            }
        default:
            return nil
        }
        consumeIncludingWhitespace()
        components.setSymbol(slot, id.rawValue)
        return id
    }

    /// The positions of consumePositionUnresolved, consumeBackgroundPositionUnresolved (`allowsThree`) and
    /// consumeOneOrTwoComponentPositionUnresolved (`maxComponents` 2), from their components. Consumes nothing if there is
    /// no position.
    mutating func consumePosition(maxComponents: Int, allowsThree: Bool) -> PropertyValue? {
        var components = WebCore.CSSColorSwiftComponents()
        guard let layout = consumePosition(&components, maxComponents: maxComponents, allowsThree: allowsThree) else {
            return nil
        }
        WebCore.setPositionResult(tokens.value, WebCore.CSSPropertyConsumerSwiftConsumer.Position.rawValue, components, layout)
        return nil
    }

    /// `consumePosition` into `components`: the position's layout for setPositionResult.
    mutating func consumePosition(_ components: inout WebCore.CSSColorSwiftComponents, maxComponents: Int, allowsThree: Bool) -> UInt16? {
        let start = index
        var ids: [4 of WebCore.CSSValueID] = .init(repeating: .Invalid)
        var count = 0
        while count < maxComponents, let id = consumePositionComponent(&components, UInt8(truncatingIfNeeded: count)) {
            ids[count] = id
            count += 1
        }
        let layout: UInt16?
        switch count {
        case 1: layout = positionLayoutOfOne(ids[0], &components)
        case 2: layout = positionLayoutOfTwo(ids[0], ids[1])
        case 3: layout = allowsThree ? positionLayoutOfThree(ids[0], ids[1], ids[2]) : nil
        case 4: layout = positionLayoutOfFour(ids[0], ids[1], ids[2], ids[3])
        default: layout = nil
        }
        guard let layout else {
            index = start
            return nil
        }
        return layout
    }

    /// `positionUnresolvedFromOneComponent`: the other axis is `center`, put in component 1.
    private func positionLayoutOfOne(_ c1: WebCore.CSSValueID, _ components: inout WebCore.CSSColorSwiftComponents) -> UInt16 {
        components.setSymbol(1, WebCore.CSSValueID.Center.rawValue)
        if c1 == .Center {
            return positionLayout(0, vertical: 0)
        }
        return isVerticalOnly(c1) ? positionLayout(1, vertical: 0) : positionLayout(0, vertical: 1)
    }

    /// `positionUnresolvedFromTwoComponents`.
    private func positionLayoutOfTwo(_ c1: WebCore.CSSValueID, _ c2: WebCore.CSSValueID) -> UInt16? {
        if isVerticalOnly(c1) {
            // `c2` must be in the set [ left | center | right | x-start | x-end ] (not <length-percentage>).
            return isHorizontalOnly(c2) || c2 == .Center ? positionLayout(1, vertical: 0) : nil
        }
        if c1 == .Center && isHorizontalOnly(c2) {
            return positionLayout(1, vertical: 0)
        }
        // After a horizontal keyword or a <length-percentage>, `c2` must be in the set
        // [ top | center | bottom | y-start | y-end | <length-percentage> ]; after `center`, anything.
        return isHorizontalOnly(c2) ? nil : positionLayout(0, vertical: 1)
    }

    /// `positionUnresolvedFromThreeComponents`, for <bg-position>.
    private func positionLayoutOfThree(_ c1: WebCore.CSSValueID, _ c2: WebCore.CSSValueID, _ c3: WebCore.CSSValueID) -> UInt16? {
        let length = WebCore.CSSValueID.Invalid
        if isHorizontalOnly(c1) {
            if isVerticalOnly(c2) {
                return c3 == length ? positionLayout(0, vertical: 1, 2) : nil
            }
            if c2 == length {
                return isVerticalOnly(c3) || c3 == .Center ? positionLayout(0, 1, vertical: 2) : nil
            }
            return nil
        }
        if isVerticalOnly(c1) {
            if isHorizontalOnly(c2) {
                return c3 == length ? positionLayout(1, 2, vertical: 0) : nil
            }
            if c2 == length {
                return isHorizontalOnly(c3) || c3 == .Center ? positionLayout(2, vertical: 0, 1) : nil
            }
            return nil
        }
        guard c1 == .Center, c3 == length else {
            return nil
        }
        if isHorizontalOnly(c2) {
            return positionLayout(1, 2, vertical: 0)
        }
        return isVerticalOnly(c2) ? positionLayout(0, vertical: 1, 2) : nil
    }

    /// `positionUnresolvedFromFourComponents`.
    private func positionLayoutOfFour(_ c1: WebCore.CSSValueID, _ c2: WebCore.CSSValueID, _ c3: WebCore.CSSValueID, _ c4: WebCore.CSSValueID) -> UInt16? {
        let length = WebCore.CSSValueID.Invalid
        guard c2 == length, c4 == length else {
            return nil
        }
        if isHorizontalOnly(c1) && isVerticalOnly(c3) {
            return positionLayout(0, 1, vertical: 2, 3)
        }
        if isVerticalOnly(c1) && isHorizontalOnly(c3) {
            return positionLayout(2, 3, vertical: 0, 1)
        }
        return nil
    }

    /// consumePositionXUnresolved, consumePositionYUnresolved and consumeTwoComponentPosition{Horizontal,Vertical}Unresolved:
    /// a keyword of the axis, with a <length-percentage> after a side for PositionX and PositionY, or a
    /// <length-percentage>.
    private mutating func consumeAxis(_ consumer: WebCore.CSSPropertyConsumerSwiftConsumer) -> PropertyValue? {
        let horizontal = consumer == .PositionX || consumer == .TwoComponentPositionHorizontal
        var components = WebCore.CSSColorSwiftComponents()
        var hasLength = false
        if peekType() == PropertyTokenType.ident {
            guard let id = consumeAxisKeyword(&components, horizontal: horizontal) else {
                return nil
            }
            if id != .Center && (consumer == .PositionX || consumer == .PositionY) {
                hasLength = consumeNumeric(&components, 1, .lengthPercentage)
            }
        } else if !consumeNumeric(&components, 0, .lengthPercentage) {
            return nil
        }
        let axis = positionLayout(0, hasLength ? 1 : 0xf, vertical: 0xf)
        WebCore.setPositionResult(tokens.value, consumer.rawValue, components, horizontal ? axis : axis << 8 | 0xff)
        return nil
    }

    /// A keyword of the horizontal or the vertical axis, or center, into component 0. Consumes nothing and returns nil
    /// if there is none.
    mutating func consumeAxisKeyword(_ components: inout WebCore.CSSColorSwiftComponents, horizontal: Bool) -> WebCore.CSSValueID? {
        let id = peekIdent()
        switch id {
        case .Left, .Right:
            guard horizontal else {
                return nil
            }
        case .Top, .Bottom:
            guard !horizontal else {
                return nil
            }
        case .XStart, .XEnd:
            guard horizontal, axisRelativePositionKeywordsEnabled() else {
                return nil
            }
        case .YStart, .YEnd:
            guard !horizontal, axisRelativePositionKeywordsEnabled() else {
                return nil
            }
        case .Center:
            break
        default:
            return nil
        }
        consumeIncludingWhitespace()
        components.setSymbol(0, id.rawValue)
        return id
    }

    /// `MetaConsumer` of the numeric primitive `numeric` into component `slot`. Consumes nothing if there is none.
    mutating func consumeNumeric(_ components: inout WebCore.CSSColorSwiftComponents, _ slot: UInt8, _ numeric: NumericComponent) -> Bool {
        let type = peekType()
        if type == PropertyTokenType.function {
            return consumeChannelCalc(&components, slot, numeric.type, min: numeric.min, max: numeric.max, ColorDescriptor.Alpha, relative: false)
        }
        guard type == PropertyTokenType.number || type == PropertyTokenType.percentage || type == PropertyTokenType.dimension else {
            return false
        }
        var value = tokens.value.numericValue(index)
        let unitType = tokens.value.unitType(index)
        let unit: UInt8
        switch numeric.type {
        case NumericComponent.angle.type, NumericComponent.anglePercentage.type:
            // AngleValidator and AnglePercentageValidator, with unitless zero angles allowed unless the primitive forbids
            // them; the unit is a CSSUnitType.
            guard !value.isInfinite else {
                return false
            }
            if type == PropertyTokenType.percentage {
                guard numeric.type == NumericComponent.anglePercentage.type else {
                    return false
                }
                unit = WebCore.CSSUnitType.Percentage.rawValue
            } else {
                guard let angle = angleUnit(type, unitType, value, parserMode, numericFlags, allowsUnitlessZero: numeric.unitlessZeroAngle) else {
                    return false
                }
                unit = angle.rawValue
            }
        case NumericComponent.resolution.type:
            // ResolutionValidator, for [0, inf]; the unit is a CSSUnitType.
            guard type == PropertyTokenType.dimension, !value.isInfinite, value >= 0, let cssUnit = WebCore.CSSUnitType(rawValue: unitType),
                WebCore.CSS.toResolutionUnit(cssUnit).value != nil
            else {
                return false
            }
            unit = unitType
        default:
            // SwiftNumericConsumer, with the default CSSPropertyParserOptions (unitless zero allowed); lengths resolve to
            // float values; a primitive read in the standard mode (`overrideParserMode`) takes no quirky lengths.
            let isLength = numeric.type == NumericComponent.lengthPercentage.type || numeric.type == NumericComponent.nonnegativeLength.type
            var flags = numericFlags | UInt8(WebCore.CSSNumericConsumerSwiftUnitlessZeroLength) | (isLength ? UInt8(WebCore.CSSNumericConsumerSwiftResolvesToFloat) : 0)
            if numeric.standardMode {
                flags &= ~(UInt8(WebCore.CSSNumericConsumerSwiftQuirkyLength) | UInt8(WebCore.CSSNumericConsumerSwiftQuirkyAngle))
            }
            let mode = numeric.standardMode ? WebCore.HTMLStandardMode.rawValue : parserMode
            let result = cssConsumeNumericSwift(value, numeric.min, numeric.max, numeric.category, type, unitType, mode, numeric.minBehavior, numeric.maxBehavior, flags)
            guard result.packed >> 8 != 0 else {
                return false
            }
            unit = UInt8(truncatingIfNeeded: result.packed)
            value = result.value
        }
        components.setValue(slot, numeric.type, unit, value)
        consumeIncludingWhitespace()
        return true
    }
}

/// A numeric primitive of a position, a gradient, a cross-fade or an image set: its CSSColorSwiftChannel type, and its
/// CSS::Range and parse-time behaviors, which static_asserts in CSSPropertyParserConsumer+Color.cpp check.
struct NumericComponent {
    let type: UInt8
    var min = -Double.infinity
    var max = Double.infinity
    var minBehavior = UInt8(WebCore.CSS.RangeParseTimeBehavior.Default.rawValue)
    var maxBehavior = UInt8(WebCore.CSS.RangeParseTimeBehavior.Default.rawValue)
    var standardMode = false
    /// Whether a number token 0 is an angle, as `UnitlessZeroQuirk::Allow` makes it.
    var unitlessZeroAngle = true

    /// The CSS::Category of a number, percentage, length or length-percentage.
    var category: UInt8 {
        switch type {
        case Self.lengthPercentage.type: WebCore.CSS.Category.LengthPercentage.rawValue
        case Self.nonnegativeLength.type: WebCore.CSS.Category.Length.rawValue
        case Self.percentage.type: WebCore.CSS.Category.Percentage.rawValue
        default: WebCore.CSS.Category.Number.rawValue
        }
    }

    private static var clamp: UInt8 { UInt8(WebCore.CSS.RangeParseTimeBehavior.Clamp.rawValue) }
    private static var ignore: UInt8 { UInt8(WebCore.CSS.RangeParseTimeBehavior.Ignore.rawValue) }

    /// `CSS::LengthPercentage<>`.
    static var lengthPercentage: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelLengthPercentage)) }
    /// A gradient stop's `CSS::LengthPercentage<CSS::AllLayoutUnitClamped>`.
    static var stopLength: Self {
        Self(type: UInt8(WebCore.CSSColorSwiftChannelLengthPercentage), min: -33554430, max: 33554429, minBehavior: ignore, maxBehavior: ignore)
    }
    /// `CSS::LengthPercentage<CSS::Nonnegative>`.
    static var nonnegativeLengthPercentage: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelLengthPercentage), min: 0) }
    /// `CSS::Length<CSS::Nonnegative>` and `CSS::Length<>`.
    static var nonnegativeLength: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelLength), min: 0) }
    static var length: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelLength)) }
    /// border-image-width's `CSS::LengthPercentage<CSS::Nonnegative>`, read in the standard mode.
    static var standardModeNonnegativeLengthPercentage: Self {
        Self(type: UInt8(WebCore.CSSColorSwiftChannelLengthPercentage), min: 0, standardMode: true)
    }
    /// `CSS::Number<>` and `CSS::Percentage<>`.
    static var number: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelNumber)) }
    static var percentage: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelPercentage)) }
    /// `CSS::Number<CSS::Nonnegative>` and `CSS::Percentage<CSS::Nonnegative>`.
    static var nonnegativeNumber: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelNumber), min: 0) }
    static var nonnegativePercentage: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelPercentage), min: 0) }
    /// -webkit-cross-fade()'s `CSS::Number<CSS::ClosedUnitRangeClampBoth>` and `CSS::Percentage<CSS::ClosedPercentageRangeClampBoth>`.
    static var progressNumber: Self {
        Self(type: UInt8(WebCore.CSSColorSwiftChannelNumber), min: 0, max: 1, minBehavior: clamp, maxBehavior: clamp)
    }
    static var progressPercentage: Self {
        Self(type: UInt8(WebCore.CSSColorSwiftChannelPercentage), min: 0, max: 100, minBehavior: clamp, maxBehavior: clamp)
    }
    /// cross-fade()'s `CSS::Percentage<CSS::ClosedPercentageRange>`.
    static var crossfadePercentage: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelPercentage), min: 0, max: 100) }
    /// `CSS::Angle<>` and `CSS::AnglePercentage<>`, with unitless zero angles allowed.
    static var angle: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelAngle)) }
    static var anglePercentage: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelAnglePercentage)) }
    /// `CSS::Resolution<>`.
    static var resolution: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelResolution), min: 0) }
}

// MARK: - Image parsing

private typealias AllowedImageType = WebCore.CSSPropertyParserHelpers.AllowedImageType

/// consumeImage's default OptionSet<AllowedImageType>: url(), image-set() and generated images.
var defaultAllowedImageTypes: UInt8 {
    AllowedImageType.URLFunction.rawValue | AllowedImageType.ImageSet.rawValue | AllowedImageType.GeneratedImage.rawValue
}

extension PropertyParser {
    /// `consumeImage` with the OptionSet<AllowedImageType> `allowed`: a string as a URL, an image function or url().
    mutating func consumeImage(_ allowed: UInt8) -> PropertyValue? {
        let type = peekType()
        if type == PropertyTokenType.string && allowed & AllowedImageType.RawStringAsURL.rawValue != 0 {
            // At most the token count, an Int from a UInt32; below end.
            guard let image = WebCore.makeImageURLValue(tokens.value, UInt32(truncatingIfNeeded: index), UInt32(truncatingIfNeeded: index &+ 1)).get() else {
                return nil
            }
            consumeIncludingWhitespace()
            return image
        }
        if type == PropertyTokenType.function {
            let name = peekFunction()
            switch name {
            case .RadialGradient, .RepeatingRadialGradient, .WebkitLinearGradient, .WebkitRepeatingLinearGradient, .RepeatingLinearGradient,
                .LinearGradient, .WebkitGradient, .WebkitRadialGradient, .WebkitRepeatingRadialGradient, .ConicGradient, .RepeatingConicGradient,
                .MeshGradient, .WebkitCrossFade, .CrossFade, .WebkitCanvas, .WebkitNamedImage, .Image, .WebkitFilter, .Filter, .Paint:
                guard allowed & AllowedImageType.GeneratedImage.rawValue != 0 else {
                    return nil
                }
                return consumeImageFunction(name, allowed)
            case .LightDark:
                return consumeImageFunction(name, allowed)
            case .ImageSet, .WebkitImageSet:
                guard allowed & AllowedImageType.ImageSet.rawValue != 0 else {
                    return nil
                }
                return consumeImageFunction(name, allowed)
            default:
                break
            }
        }
        guard allowed & AllowedImageType.URLFunction.rawValue != 0 else {
            return nil
        }
        return consumeURLImage()
    }

    /// `consumeImageOrNone`: `none` as a keyword where generated images are allowed, or an image.
    mutating func consumeImageOrNone(_ allowed: UInt8) -> PropertyValue? {
        if peekIdent() == .None && allowed & AllowedImageType.GeneratedImage.rawValue != 0 {
            return consumeKeyword(peeked: .None)
        }
        return consumeImage(allowed)
    }

    /// `consumeURLRaw` for an image: a url token, or url() and its modifiers.
    private mutating func consumeURLImage() -> PropertyValue? {
        let start = index
        let next: Int
        if peekType() == UInt8(WebCore.UrlToken.rawValue) {
            next = index &+ 1 // Below end.
        } else if let function = beginFunction(.Url) {
            next = function.next
            end = function.end
            index = start
        } else {
            return nil
        }
        // Both at most the token count, an Int from a UInt32.
        guard let image = WebCore.makeImageURLValue(tokens.value, UInt32(truncatingIfNeeded: start), UInt32(truncatingIfNeeded: next)).get() else {
            return nil
        }
        index = next
        consumeWhitespace()
        return image
    }

    /// The image function `name` at the next token, whose arguments must all be consumed.
    private mutating func consumeImageFunction(_ name: WebCore.CSSValueID, _ allowed: UInt8) -> PropertyValue? {
        guard let function = beginFunction(name) else {
            return nil
        }
        let rawStringAsURL = AllowedImageType.RawStringAsURL.rawValue
        let image: PropertyValue?
        switch name {
        case .LinearGradient, .RepeatingLinearGradient:
            image = consumeLinearGradient(name, prefixed: false)
        case .WebkitLinearGradient, .WebkitRepeatingLinearGradient:
            image = consumeLinearGradient(name, prefixed: true)
        case .RadialGradient, .RepeatingRadialGradient:
            image = consumeRadialGradient(name)
        case .WebkitRadialGradient, .WebkitRepeatingRadialGradient:
            image = consumePrefixedRadialGradient(name)
        case .ConicGradient, .RepeatingConicGradient:
            image = consumeConicGradient(name)
        case .MeshGradient:
            image = consumeMeshGradient()
        case .WebkitGradient:
            image = consumeDeprecatedGradient()
        case .WebkitCrossFade:
            image = consumeWebkitCrossfade()
        case .CrossFade:
            image = consumeCrossfade()
        case .WebkitCanvas, .WebkitNamedImage:
            image = consumeNamedImage(name)
        case .Image:
            image = consumeColorImage()
        case .LightDark:
            image = consumeLightDarkImage(allowed & ~rawStringAsURL)
        case .WebkitFilter, .Filter:
            image = consumeFilterImage()
        case .Paint:
            image = consumeCustomPaint()
        default:
            image = consumeImageSet((allowed | rawStringAsURL) & ~AllowedImageType.ImageSet.rawValue)
        }
        return endFunction(function, image)
    }

    /// makeImageValue for `function`, with no line or position for those that have none.
    private func makeImageValue(
        _ function: WebCore.CSSValueID,
        _ parts: consuming WebCore.CSSImageSwiftParts,
        line: WebCore.CSSColorSwiftComponents = WebCore.CSSColorSwiftComponents(),
        position: WebCore.CSSColorSwiftComponents = WebCore.CSSColorSwiftComponents(),
        positionLayout: UInt16 = WebCore.CSSImageSwiftNoPosition
    ) -> PropertyValue {
        WebCore.makeImageValue(tokens.value, function.rawValue, line, position, positionLayout, consuming: consume parts).get()
    }

    // MARK: Gradients

    /// The color of a stop, a shadow or image(): `consumeUnresolvedColor` with its default options, as appendGradientStop
    /// and appendColor make it, with the channels of a color function in `channels`. Consumes nothing if there is none.
    mutating func consumeStopColor(_ state: inout ColorConsumerState, _ channels: inout WebCore.CSSColorSwiftComponents) -> WebCore.CSSColorSwiftStopColor {
        let start = index
        var color = WebCore.CSSColorSwiftStopColor()
        // consumeColor's level; at most one for each token.
        state.nestingLevel &+= 1
        switch consumeSimpleColor(state) {
        case .keyword(let id):
            color.kind = UInt8(WebCore.CSSColorSwiftKeywordColor)
            color.keyword = id.rawValue
        case .hex(let hex):
            color.kind = UInt8(WebCore.CSSColorSwiftHexColor)
            color.hex = hex
        case .function:
            let function = consumeAbsoluteColorFunction(&channels)
            if case .absolute(let descriptor) = function {
                color.kind = UInt8(WebCore.CSSColorSwiftFunctionColor)
                color.descriptor = descriptor.rawValue
                color.nestingLevel = state.nestingLevel
            } else if consumePendingColor(after: function, &state) {
                color.kind = UInt8(WebCore.CSSColorSwiftPendingColor)
            }
        case .notAColor:
            break
        }
        state.nestingLevel &-= 1 // Incremented above.
        if color.kind == UInt8(WebCore.CSSColorSwiftNoColor) {
            index = start
        }
        return color
    }

    /// consumeColorFunction(after:)'s color, given to setPendingColor, if there is one.
    @inline(never)
    private mutating func consumePendingColor(after function: AbsoluteColorFunction, _ state: inout ColorConsumerState) -> Bool {
        guard let color = consumeColorFunction(after: function, &state) else {
            return false
        }
        WebCore.setPendingColor(tokens.value, consuming: consume color)
        return true
    }

    func gradientColorState() -> ColorConsumerState {
        // CSSColorParsingOptions' default OptionSet<CSS::ColorType>, which a static_assert in CSSPropertyParserConsumer+Color.cpp
        // checks: absolute, current and system colors.
        ColorConsumerState(allowedColorTypes: 7, context: WebCore.colorContextForSwift(tokens.value))
    }

    /// `consumeColorStopList`: stops with a color, a position or both, a stop with both may have a second position,
    /// and with `hints`, a position alone between two stops.
    private mutating func consumeStops(hints: Bool, _ numeric: NumericComponent) -> Bool {
        // A conic gradient's stops are angles, the others' lengths.
        let angular = numeric.type == NumericComponent.anglePercentage.type
        WebCore.beginGradientStops(tokens.value, UInt8(angular ? WebCore.CSSGradientSwiftAngularStops : WebCore.CSSGradientSwiftLinearStops))
        var state = gradientColorState()
        // The first stop cannot be a hint.
        var previousWasHint = true
        repeat {
            var channels = WebCore.CSSColorSwiftComponents()
            let color = consumeStopColor(&state, &channels)
            var positions = WebCore.CSSColorSwiftComponents()
            let hasPosition = consumeNumeric(&positions, 0, numeric)
            var second = false
            if color.kind == UInt8(WebCore.CSSColorSwiftNoColor) {
                // Two hints in a row are not allowed.
                guard hasPosition, hints, !previousWasHint else {
                    return false
                }
                previousWasHint = true
            } else {
                previousWasHint = false
                // A second position is a second stop of the same color.
                second = hasPosition && consumeNumeric(&positions, 1, numeric)
            }
            WebCore.appendGradientStop(tokens.value, color, channels, positions, second)
        } while consumeComma()
        // The last stop cannot be a hint.
        return !previousWasHint
    }

    /// A color interpolation method at `in`, into `parts`.
    private mutating func consumeGradientColorInterpolationMethod(_ parts: inout WebCore.CSSImageSwiftParts) -> Bool {
        guard let method = consumeColorInterpolationMethod() else {
            return false
        }
        parts.setColorInterpolationMethod(consuming: consume method)
        return true
    }

    /// A side, or a horizontal and a vertical side in either order, into `line` 0 and 1, the horizontal one first.
    private mutating func consumeGradientSides(_ line: inout WebCore.CSSColorSwiftComponents) -> Bool {
        let first = peekIdent()
        let horizontal = first == .Left || first == .Right
        guard horizontal || first == .Top || first == .Bottom else {
            return false
        }
        consumeIncludingWhitespace()
        let second = peekIdent()
        guard horizontal ? second == .Top || second == .Bottom : second == .Left || second == .Right else {
            line.setSymbol(0, first.rawValue)
            return true
        }
        consumeIncludingWhitespace()
        line.setSymbol(0, (horizontal ? first : second).rawValue)
        line.setSymbol(1, (horizontal ? second : first).rawValue)
        return true
    }

    /// linear-gradient() and repeating-linear-gradient(), or with `prefixed` their -webkit- forms, whose line is an angle
    /// or sides without `to`, defaults to the top, and whose stops have no hints.
    private mutating func consumeLinearGradient(_ name: WebCore.CSSValueID, prefixed: Bool) -> PropertyValue? {
        var parts = WebCore.CSSImageSwiftParts()
        var line = WebCore.CSSColorSwiftComponents()
        var hasMethod = false
        if !prefixed && peekIdent() == .In {
            guard consumeGradientColorInterpolationMethod(&parts) else {
                return nil
            }
            hasMethod = true
        }
        var hasLine = true
        if consumeNumeric(&line, 0, .angle) {
        } else if prefixed {
            hasLine = consumeGradientSides(&line)
        } else if peekIdent() == .To {
            consumeIncludingWhitespace()
            guard consumeGradientSides(&line) else {
                return nil
            }
        } else {
            hasLine = false
        }
        if !hasLine {
            line.setSymbol(0, (prefixed ? WebCore.CSSValueID.Top : .Bottom).rawValue)
        }
        if hasLine && !hasMethod && !prefixed && peekIdent() == .In {
            guard consumeGradientColorInterpolationMethod(&parts) else {
                return nil
            }
            hasMethod = true
        }
        if hasLine || hasMethod {
            guard consumeComma() else {
                return nil
            }
        }
        guard consumeStops(hints: !prefixed, .stopLength) else {
            return nil
        }
        return makeImageValue(name, parts, line: line)
    }

    /// radial-gradient() and repeating-radial-gradient().
    private mutating func consumeRadialGradient(_ name: WebCore.CSSValueID) -> PropertyValue? {
        var parts = WebCore.CSSImageSwiftParts()
        var line = WebCore.CSSColorSwiftComponents()
        var hasMethod = false
        if peekIdent() == .In {
            guard consumeGradientColorInterpolationMethod(&parts) else {
                return nil
            }
            hasMethod = true
        }
        // [ [ circle || <length [0,inf]> ] | [ ellipse || <length-percentage [0,inf]>{2} ] | [ [ circle | ellipse ] || <extent-keyword> ] ]
        var shape = WebCore.CSSValueID.Invalid
        var size = RadialGradientSize.none
        var i = 0
        while i < 3 {
            if peekType() == PropertyTokenType.ident {
                let id = peekIdent()
                switch id {
                case .Circle, .Ellipse:
                    guard shape == .Invalid else {
                        return nil
                    }
                    shape = id
                    consumeIncludingWhitespace()
                case .ClosestSide, .ClosestCorner, .FarthestSide, .FarthestCorner:
                    guard size == .none else {
                        return nil
                    }
                    size = .extent
                    line.setSymbol(0, id.rawValue)
                    consumeIncludingWhitespace()
                default:
                    break
                }
                if shape == .Invalid && size == .none {
                    break
                }
            } else {
                let start = index
                guard consumeNumeric(&line, 0, .nonnegativeLengthPercentage) else {
                    break
                }
                guard size == .none else {
                    return nil
                }
                if consumeNumeric(&line, 1, .nonnegativeLengthPercentage) {
                    size = .lengths
                    // The second length counts too.
                    i += 1
                } else {
                    // A <length [0,inf]>, parsed again.
                    index = start
                    guard consumeNumeric(&line, 0, .nonnegativeLength) else {
                        return nil
                    }
                    size = .length
                }
            }
            i += 1
        }
        var position = WebCore.CSSColorSwiftComponents()
        var positionLayout = WebCore.CSSImageSwiftNoPosition
        if peekIdent() == .At {
            consumeIncludingWhitespace()
            guard let layout = consumePosition(&position, maxComponents: 4, allowsThree: false) else {
                return nil
            }
            positionLayout = layout
        }
        let hasPrelude = shape != .Invalid || size != .none || positionLayout != WebCore.CSSImageSwiftNoPosition
        if hasPrelude && !hasMethod && peekIdent() == .In {
            guard consumeGradientColorInterpolationMethod(&parts) else {
                return nil
            }
            hasMethod = true
        }
        if hasPrelude || hasMethod {
            guard consumeComma() else {
                return nil
            }
        }
        guard consumeStops(hints: true, .stopLength) else {
            return nil
        }
        // Ellipses must have two length-percentages, circles at most one length; a size alone decides the shape.
        switch (shape, size) {
        case (.Ellipse, .length), (.Circle, .lengths):
            return nil
        case (.Invalid, .length):
            shape = .Circle
        case (.Invalid, _):
            shape = .Ellipse
        default:
            break
        }
        if size == .none {
            line.setSymbol(0, WebCore.CSSValueID.FarthestCorner.rawValue)
        }
        line.setSymbol(3, shape.rawValue)
        return makeImageValue(name, parts, line: line, position: position, positionLayout: positionLayout)
    }

    /// -webkit-radial-gradient() and -webkit-repeating-radial-gradient().
    private mutating func consumePrefixedRadialGradient(_ name: WebCore.CSSValueID) -> PropertyValue? {
        let parts = WebCore.CSSImageSwiftParts()
        var line = WebCore.CSSColorSwiftComponents()
        var position = WebCore.CSSColorSwiftComponents()
        var positionLayout = WebCore.CSSImageSwiftNoPosition
        if let layout = consumePosition(&position, maxComponents: 2, allowsThree: false) {
            positionLayout = layout
            guard consumeComma() else {
                return nil
            }
        }
        var shape = WebCore.CSSValueID.Invalid
        var hasExtent = false
        if peekType() == PropertyTokenType.ident {
            if peekIdent() == .Circle || peekIdent() == .Ellipse {
                shape = peekIdent()
                consumeIncludingWhitespace()
            }
            switch peekIdent() {
            case .Contain, .Cover, .ClosestSide, .ClosestCorner, .FarthestSide, .FarthestCorner:
                line.setSymbol(0, peekIdent().rawValue)
                hasExtent = true
                consumeIncludingWhitespace()
            default:
                break
            }
            if shape == .Invalid && (peekIdent() == .Circle || peekIdent() == .Ellipse) {
                shape = peekIdent()
                consumeIncludingWhitespace()
            }
            if shape != .Invalid || hasExtent {
                guard consumeComma() else {
                    return nil
                }
            }
        }
        if shape == .Invalid && !hasExtent && consumeNumeric(&line, 0, .nonnegativeLengthPercentage) {
            guard consumeNumeric(&line, 1, .nonnegativeLengthPercentage), consumeComma() else {
                return nil
            }
        }
        guard consumeStops(hints: false, .stopLength) else {
            return nil
        }
        line.setSymbol(3, (shape == .Circle ? WebCore.CSSValueID.Circle : .Ellipse).rawValue)
        return makeImageValue(name, parts, line: line, position: position, positionLayout: positionLayout)
    }

    /// conic-gradient() and repeating-conic-gradient().
    private mutating func consumeConicGradient(_ name: WebCore.CSSValueID) -> PropertyValue? {
        var parts = WebCore.CSSImageSwiftParts()
        var line = WebCore.CSSColorSwiftComponents()
        var hasMethod = false
        if peekIdent() == .In {
            guard consumeGradientColorInterpolationMethod(&parts) else {
                return nil
            }
            hasMethod = true
        }
        var hasAngle = false
        if peekIdent() == .From {
            consumeIncludingWhitespace()
            guard consumeNumeric(&line, 0, .angle) else {
                return nil
            }
            hasAngle = true
        }
        var position = WebCore.CSSColorSwiftComponents()
        var positionLayout = WebCore.CSSImageSwiftNoPosition
        if peekIdent() == .At {
            consumeIncludingWhitespace()
            guard let layout = consumePosition(&position, maxComponents: 4, allowsThree: false) else {
                return nil
            }
            positionLayout = layout
        }
        let hasPrelude = hasAngle || positionLayout != WebCore.CSSImageSwiftNoPosition
        if hasPrelude && !hasMethod && peekIdent() == .In {
            guard consumeGradientColorInterpolationMethod(&parts) else {
                return nil
            }
            hasMethod = true
        }
        if hasPrelude || hasMethod {
            guard consumeComma() else {
                return nil
            }
        }
        guard consumeStops(hints: true, .anglePercentage) else {
            return nil
        }
        return makeImageValue(name, parts, line: line, position: position, positionLayout: positionLayout)
    }

    // MARK: mesh-gradient()
    // https://github.com/w3c/csswg-drafts/blob/main/css-images-5/explainers/2d-gradients.md#mesh-gradient

    /// mesh-gradient( [ <color-interpolation-method> || <color> ]?, <mesh-point># [ ';' <mesh-point># ]* ), behind the
    /// CSSMeshGradientsEnabled preference. The background color, or none, is the first color of the parts, and each point
    /// is a color with its header and location, as makeImageValue describes them.
    private mutating func consumeMeshGradient() -> PropertyValue? {
        guard contextEnables(UInt32(WebCore.CSSConsumerSwiftMeshGradientsEnabled)) else {
            return nil
        }
        // FIXME: A lone <color> is ambiguous between the prelude and the first <mesh-point> so the prelude is
        // only recognized when it contains a <color-interpolation-method>.
        var parts = WebCore.CSSImageSwiftParts()
        var state = gradientColorState()
        var background = WebCore.CSSColorSwiftStopColor()
        var backgroundChannels = WebCore.CSSColorSwiftComponents()
        var hasMethod = false
        let start = index
        if peekIdent() == .In {
            guard consumeGradientColorInterpolationMethod(&parts) else {
                return nil
            }
            hasMethod = true
            if peekType() != PropertyTokenType.comma {
                background = consumeStopColor(&state, &backgroundChannels)
                guard background.kind != UInt8(WebCore.CSSColorSwiftNoColor) else {
                    return nil
                }
            }
        } else {
            background = consumeStopColor(&state, &backgroundChannels)
            if background.kind != UInt8(WebCore.CSSColorSwiftNoColor) && peekIdent() == .In {
                guard consumeGradientColorInterpolationMethod(&parts) else {
                    return nil
                }
                hasMethod = true
            }
        }
        if hasMethod {
            guard consumeComma() else {
                return nil
            }
        } else {
            // A color without a method is the first point's, consumed again below.
            index = start
            background = WebCore.CSSColorSwiftStopColor()
        }
        parts.appendColor(tokens.value, background, backgroundChannels, WebCore.CSSColorSwiftComponents())

        // The rows' count, the first row's length, and whether every row has that length.
        var rows = 0
        var firstRowLength = 0
        var rowLength = 0
        var sameLengths = true
        while true {
            guard appendMeshGradientPoint(&parts, &state, beginsRow: rowLength == 0) else {
                return nil
            }
            rowLength += 1
            if consumeComma() {
                continue
            }
            if rows == 0 {
                firstRowLength = rowLength
            } else if rowLength != firstRowLength {
                sameLengths = false
            }
            rows += 1
            rowLength = 0
            if atEnd {
                break
            }
            // consumeSemicolon.
            guard peekType() == UInt8(WebCore.SemicolonToken.rawValue) else {
                return nil
            }
            consumeIncludingWhitespace()
        }
        // FIXME: The explainer doesn't say what grids are valid. For now, require a minimum of 2x2 and that
        // each row has the same number of points.
        guard rows >= 2, firstRowLength >= 2, sameLengths else {
            return nil
        }
        return makeImageValue(.MeshGradient, parts)
    }

    /// <mesh-point> = <color> [ <mesh-absolute-position> | <mesh-relative-position> ]?, appended as its color with its
    /// header, then its location and control points.
    private mutating func appendMeshGradientPoint(_ parts: inout WebCore.CSSImageSwiftParts, _ state: inout ColorConsumerState, beginsRow: Bool) -> Bool {
        var channels = WebCore.CSSColorSwiftComponents()
        let color = consumeStopColor(&state, &channels)
        guard color.kind != UInt8(WebCore.CSSColorSwiftNoColor) else {
            return false
        }
        // The location is read before the color is appended, which reads no color, so a pending color stays pending.
        var location = WebCore.CSSColorSwiftComponents()
        var header = UInt16(WebCore.CSSMeshGradientSwiftNoLocation)
        var layout: UInt16 = 0
        if peekIdent() == .By {
            // <mesh-relative-position> = by <coordinate-pair> [ with <mesh-relative-control-point> [ / <mesh-relative-control-point> ]{0,3} ]?
            consumeIncludingWhitespace()
            guard consumeMeshGradientCoordinatePair(&location) else {
                return false
            }
            header = UInt16(WebCore.CSSMeshGradientSwiftRelativeLocation)
        } else if let positionLayout = consumePosition(&location, maxComponents: 4, allowsThree: false) {
            // <mesh-absolute-position> = <position> [ with <position> [ / <position> ]{0,3} ]?
            layout = positionLayout
            header = UInt16(WebCore.CSSMeshGradientSwiftAbsoluteLocation)
        }
        if beginsRow {
            header |= UInt16(WebCore.CSSMeshGradientSwiftBeginsRow)
        }
        var headerComponents = WebCore.CSSColorSwiftComponents()
        headerComponents.setSymbol(0, header)
        parts.appendColor(tokens.value, color, channels, headerComponents)
        let relative = header & 3 == UInt16(WebCore.CSSMeshGradientSwiftRelativeLocation)
        if relative {
            parts.append(location, 0..<2)
        } else if header & 3 == UInt16(WebCore.CSSMeshGradientSwiftAbsoluteLocation) {
            appendMeshGradientPosition(&parts, location, layout)
        } else {
            return true
        }
        // [ with <control-point> [ / <control-point> ]{0,3} ]?, then one absent component.
        if peekIdent() == .With {
            consumeIncludingWhitespace()
            var count = 0
            repeat {
                var components = WebCore.CSSColorSwiftComponents()
                if relative {
                    // <mesh-relative-control-point> = <coordinate-pair> [from origin]?
                    guard consumeMeshGradientCoordinatePair(&components) else {
                        return false
                    }
                    if peekIdent() == .From {
                        consumeIncludingWhitespace()
                        guard peekIdent() == .Origin else {
                            return false
                        }
                        consumeIncludingWhitespace()
                        components.setSymbol(2, WebCore.CSSValueID.Origin.rawValue)
                    }
                    parts.append(components, 0..<3)
                } else {
                    guard let controlLayout = consumePosition(&components, maxComponents: 4, allowsThree: false) else {
                        return false
                    }
                    appendMeshGradientPosition(&parts, components, controlLayout)
                }
                count += 1
            } while count < 4 && consumeSlash()
        }
        parts.append(WebCore.CSSColorSwiftComponents(), 0)
        return true
    }

    /// A position: its layout as a symbol, then its four components.
    private func appendMeshGradientPosition(_ parts: inout WebCore.CSSImageSwiftParts, _ components: borrowing WebCore.CSSColorSwiftComponents, _ layout: UInt16) {
        var header = WebCore.CSSColorSwiftComponents()
        header.setSymbol(0, layout)
        parts.append(header, 0)
        parts.append(components, 0..<4)
    }

    /// `consumeCoordinatePair`: <coordinate-pair> = <length-percentage>{2}, into components 0 and 1. Consumes nothing
    /// if there is none.
    private mutating func consumeMeshGradientCoordinatePair(_ components: inout WebCore.CSSColorSwiftComponents) -> Bool {
        let start = index
        guard consumeNumeric(&components, 0, .lengthPercentage), consumeNumeric(&components, 1, .lengthPercentage) else {
            index = start
            return false
        }
        return true
    }

    /// -webkit-gradient(): linear or radial, its points (and radii), and stops.
    private mutating func consumeDeprecatedGradient() -> PropertyValue? {
        let kind = peekIdent()
        // The kind is the first token, whatever it is.
        consumeIncludingWhitespace()
        guard kind == .Linear || kind == .Radial else {
            return nil
        }
        let radial = kind == .Radial
        var line = WebCore.CSSColorSwiftComponents()
        var radii = WebCore.CSSColorSwiftComponents()
        guard consumeComma(), consumeDeprecatedGradientPoint(&line, 0) else {
            return nil
        }
        if radial {
            guard consumeComma(), consumeNumeric(&radii, 0, .nonnegativeNumber) else {
                return nil
            }
        }
        guard consumeComma(), consumeDeprecatedGradientPoint(&line, 2) else {
            return nil
        }
        if radial {
            guard consumeComma(), consumeNumeric(&radii, 1, .nonnegativeNumber) else {
                return nil
            }
        }
        let parts = WebCore.CSSImageSwiftParts()
        var state = gradientColorState()
        WebCore.beginGradientStops(tokens.value, UInt8(WebCore.CSSGradientSwiftDeprecatedStops))
        while consumeComma() {
            guard consumeDeprecatedGradientStop(&state) else {
                return nil
            }
        }
        return makeImageValue(.WebkitGradient, parts, line: line, position: radii)
    }

    /// A point of -webkit-gradient() into `line` `slot` and `slot` + 1: each a number or a percentage, or a keyword.
    private mutating func consumeDeprecatedGradientPoint(_ line: inout WebCore.CSSColorSwiftComponents, _ slot: UInt8) -> Bool {
        consumeDeprecatedGradientPointComponent(&line, slot, zero: .Left, oneHundred: .Right)
            && consumeDeprecatedGradientPointComponent(&line, slot &+ 1, zero: .Top, oneHundred: .Bottom) // slot is 0 or 2.
    }

    private mutating func consumeDeprecatedGradientPointComponent(
        _ line: inout WebCore.CSSColorSwiftComponents,
        _ slot: UInt8,
        zero: WebCore.CSSValueID,
        oneHundred: WebCore.CSSValueID
    ) -> Bool {
        guard peekType() == PropertyTokenType.ident else {
            return consumeNumeric(&line, slot, .number) || consumeNumeric(&line, slot, .percentage)
        }
        let id = peekIdent()
        let percentage: Double
        if id == zero {
            percentage = 0
        } else if id == oneHundred {
            percentage = 100
        } else if id == .Center {
            percentage = 50
        } else {
            return false
        }
        consumeIncludingWhitespace()
        line.setValue(slot, UInt8(WebCore.CSSColorSwiftChannelPercentage), 0, percentage)
        return true
    }

    /// from(), to() or color-stop() of -webkit-gradient(), whose color is not currentcolor.
    private mutating func consumeDeprecatedGradientStop(_ state: inout ColorConsumerState) -> Bool {
        let name = peekFunction()
        guard name == .From || name == .To || name == .ColorStop, let function = beginFunction(name) else {
            return false
        }
        var position = WebCore.CSSColorSwiftComponents()
        let number = UInt8(WebCore.CSSColorSwiftChannelNumber)
        var positioned = true
        if name == .From {
            position.setValue(0, number, 0, 0)
        } else if name == .To {
            position.setValue(0, number, 0, 1)
        } else {
            positioned = (consumeNumeric(&position, 0, .number) || consumeNumeric(&position, 0, .percentage)) && consumeComma()
        }
        var color = WebCore.CSSColorSwiftStopColor()
        var channels = WebCore.CSSColorSwiftComponents()
        if positioned && peekIdent() != .Currentcolor {
            color = consumeStopColor(&state, &channels)
        }
        guard color.kind != UInt8(WebCore.CSSColorSwiftNoColor), atEnd else {
            endColorFunction(function, false)
            return false
        }
        endColorFunction(function, true)
        WebCore.appendGradientStop(tokens.value, color, channels, position, false)
        return true
    }

    // MARK: Other images

    /// -webkit-cross-fade(): two images or none, and a progress.
    private mutating func consumeWebkitCrossfade() -> PropertyValue? {
        guard let from = consumeImageOrNone(defaultAllowedImageTypes), consumeComma(), let to = consumeImageOrNone(defaultAllowedImageTypes),
            consumeComma()
        else {
            return nil
        }
        var progress = WebCore.CSSColorSwiftComponents()
        guard consumeNumeric(&progress, 0, .progressNumber) || consumeNumeric(&progress, 0, .progressPercentage) else {
            return nil
        }
        var parts = WebCore.CSSImageSwiftParts()
        parts.appendImage(from, WebCore.CSSColorSwiftComponents())
        parts.appendImage(to, WebCore.CSSColorSwiftComponents())
        return makeImageValue(.WebkitCrossFade, parts, line: progress)
    }

    /// cross-fade(): images, each with a percentage before or after it or not.
    private mutating func consumeCrossfade() -> PropertyValue? {
        var parts = WebCore.CSSImageSwiftParts()
        repeat {
            var percentage = WebCore.CSSColorSwiftComponents()
            let percentageFirst = consumeNumeric(&percentage, 0, .crossfadePercentage)
            guard let image = consumeImage(defaultAllowedImageTypes) else {
                return nil
            }
            if !percentageFirst {
                _ = consumeNumeric(&percentage, 0, .crossfadePercentage)
            }
            parts.appendImage(image, percentage)
        } while consumeComma()
        guard atEnd else {
            return nil
        }
        return makeImageValue(.CrossFade, parts)
    }

    /// -webkit-canvas() and -webkit-named-image(): an identifier.
    private mutating func consumeNamedImage(_ name: WebCore.CSSValueID) -> PropertyValue? {
        guard peekType() == PropertyTokenType.ident else {
            return nil
        }
        // At most the token count, an Int from a UInt32.
        let ident = UInt32(truncatingIfNeeded: index)
        consumeIncludingWhitespace()
        return WebCore.makeNamedImageValue(tokens.value, name.rawValue, ident, 0, 0).get()
    }

    /// image(): a color.
    private mutating func consumeColorImage() -> PropertyValue? {
        var state = gradientColorState()
        var channels = WebCore.CSSColorSwiftComponents()
        let color = consumeStopColor(&state, &channels)
        guard color.kind != UInt8(WebCore.CSSColorSwiftNoColor) else {
            return nil
        }
        var parts = WebCore.CSSImageSwiftParts()
        parts.appendColor(tokens.value, color, channels, WebCore.CSSColorSwiftComponents())
        return makeImageValue(.Image, parts)
    }

    /// light-dark(): two images or none.
    private mutating func consumeLightDarkImage(_ allowed: UInt8) -> PropertyValue? {
        guard let light = consumeImageOrNone(allowed), consumeComma(), let dark = consumeImageOrNone(allowed) else {
            return nil
        }
        var parts = WebCore.CSSImageSwiftParts()
        parts.appendImage(light, WebCore.CSSColorSwiftComponents())
        parts.appendImage(dark, WebCore.CSSColorSwiftComponents())
        return makeImageValue(.LightDark, parts)
    }

    /// filter(): an image or none, and a filter, which C++ consumes.
    private mutating func consumeFilterImage() -> PropertyValue? {
        guard let image = consumeImageOrNone(defaultAllowedImageTypes), consumeComma() else {
            return nil
        }
        // The filter is all the rest of the arguments.
        guard filterList(apple: false), atEnd else {
            return nil
        }
        return WebCore.makeFilterValue(tokens.value, WebCore.CSSPropertyConsumerSwiftConsumer.Filter.rawValue, image).get()
    }

    /// paint(): an identifier, and after a comma, any arguments.
    private mutating func consumeCustomPaint() -> PropertyValue? {
        guard peekType() == PropertyTokenType.ident else {
            return nil
        }
        // Both at most the token count, an Int from a UInt32.
        let ident = UInt32(truncatingIfNeeded: index)
        consumeIncludingWhitespace()
        guard atEnd || peekType() == PropertyTokenType.comma else {
            return nil
        }
        if !atEnd {
            index &+= 1 // The comma, below end.
        }
        let paint = WebCore.makeNamedImageValue(tokens.value, WebCore.CSSValueID.Paint.rawValue, ident, UInt32(truncatingIfNeeded: index), UInt32(truncatingIfNeeded: end)).get()
        index = end
        return paint
    }

    /// image-set(): options of an image, and a resolution or type() or both, in any order.
    private mutating func consumeImageSet(_ allowed: UInt8) -> PropertyValue? {
        var parts = WebCore.CSSImageSwiftParts()
        repeat {
            guard let image = consumeImage(allowed) else {
                return nil
            }
            var resolution = WebCore.CSSColorSwiftComponents()
            var type = UInt32.max
            var i = 0
            while i < 2 && !atEnd {
                let hadResolution = resolution.type(0) != 0
                if consumeNumeric(&resolution, hadResolution ? 1 : 0, .resolution) {
                    guard !hadResolution else {
                        return nil
                    }
                } else if let string = consumeImageSetType() {
                    guard type == .max else {
                        return nil
                    }
                    type = string
                } else {
                    break
                }
                i += 1
            }
            guard atEnd || peekType() == PropertyTokenType.comma else {
                return nil
            }
            parts.appendImage(WebCore.makeImageSetOptionValue(tokens.value, image, resolution, type).get(), WebCore.CSSColorSwiftComponents())
        } while consumeComma()
        return makeImageValue(.ImageSet, parts)
    }

    /// type() of an image-set() option: the index of its string.
    private mutating func consumeImageSetType() -> UInt32? {
        guard peekFunction().rawValue == WebCore.CSSImageSwiftTypeFunction, let function = beginFunction(peekFunction()) else {
            return nil
        }
        // At most the token count, an Int from a UInt32.
        let string = UInt32(truncatingIfNeeded: index)
        let isString = peekType() == PropertyTokenType.string
        if isString {
            consumeIncludingWhitespace()
        }
        let consumed = isString && atEnd
        endColorFunction(function, consumed)
        return consumed ? string : nil
    }
}

/// The size of radial-gradient(): an extent keyword, a <length [0,inf]> or two <length-percentage [0,inf]>.
private enum RadialGradientSize {
    case none
    case extent
    case length
    case lengths
}
