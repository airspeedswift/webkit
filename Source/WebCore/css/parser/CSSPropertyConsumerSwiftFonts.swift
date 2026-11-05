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

// The consumers of CSSPropertyParserConsumer+Font.cpp: font-style, font-family and <family-name>, font-size-adjust,
// font-palette, the tags of font-feature-settings and font-variation-settings, the font of parseUnresolvedFont, the
// @font-face src and font-style, tech() and format() (also of @supports), and the @font-feature-values prelude.
//
// FontFace, FontFaceSet and OffscreenCanvas reach some of them on a worker thread, with that worker's CSSValuePool:
// the values that come from a pool come from the state's, and nothing here is kept between calls.

extension NumericComponent {
    /// An oblique font style's `CSS::Angle<CSS::Range{-90, 90}>`.
    static var obliqueAngle: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelAngle), min: -90, max: 90) }
    /// A font weight's `CSS::Number<CSS::Range{1, 1000}>`.
    static var fontWeightNumber: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelNumber), min: 1, max: 1000) }
}

extension PropertyParser {
    // MARK: - font-style

    // <'font-style'> = normal | italic | oblique <angle [-90deg,90deg]>?
    // https://drafts.csswg.org/css-fonts-4/#font-style-prop
    mutating func fontStyle() -> PropertyValue? {
        let id = peekIdent()
        guard id == .Normal || id == .Italic || id == .Oblique else {
            return nil
        }
        consumeIncludingWhitespace()
        if id == .Oblique && !atEnd {
            var angle = WebCore.CSSColorSwiftComponents()
            if obliqueAngle(&angle, 0) {
                return WebCore.makeFontStyleWithAngleValue(angle).get()
            }
        }
        return keywordValue(id)
    }

    /// `MetaConsumer<UnresolvedFontStyleObliqueAngle>` into component `slot`: an angle in [-90deg, 90deg], a unitless
    /// zero only where unitless angles are allowed. Consumes nothing if there is none.
    mutating func obliqueAngle(_ components: inout WebCore.CSSColorSwiftComponents, _ slot: UInt8) -> Bool {
        let type = peekType()
        if type == PropertyTokenType.function {
            return consumeNumeric(&components, slot, .obliqueAngle)
        }
        guard type == PropertyTokenType.number || type == PropertyTokenType.dimension else {
            return false
        }
        let value = tokens.value.numericValue(index)
        guard let unit = angleUnit(type, tokens.value.unitType(index), value, parserMode, numericFlags, allowsUnitlessZero: false),
            WebCore.isObliqueAngleForSwift(value, unit.rawValue)
        else {
            return false
        }
        components.setValue(slot, UInt8(WebCore.CSSColorSwiftChannelAngle), unit.rawValue, value)
        consumeIncludingWhitespace()
        return true
    }

    // MARK: - font-family

    // <'font-family'> = [ <family-name> | <generic-family> ]#
    // https://drafts.csswg.org/css-fonts-4/#font-family-prop
    mutating func fontFamily() -> PropertyValue? {
        var list = PropertyValueList()
        repeat {
            let id = peekIdent()
            switch id {
            case .SystemUi:
                // system-ui is a family name, written in lower case.
                consumeIncludingWhitespace()
                list.append(WebCore.makeFontFamilyNameValue(tokens.value, id.rawValue, 0, 0).get())
            case .Serif, .SansSerif, .Cursive, .Fantasy, .Monospace, .WebkitBody, .WebkitPictograph, .Math:
                consumeIncludingWhitespace()
                list.append(keywordValue(id))
            default:
                guard let name = familyNameValue() else {
                    return nil
                }
                list.append(name)
            }
        } while consumeComma()
        return makeCommaSeparatedList(list)
    }

    // <family-name> = <string> | <custom-ident>+
    // https://drafts.csswg.org/css-fonts-4/#family-name-syntax
    mutating func familyNameValue() -> PropertyValue? {
        guard let name = familyName(allowNumbers: contextEnables(UInt32(WebCore.CSSConsumerSwiftLegacyFontFaceAttributeMode))) else {
            return nil
        }
        // Both at most the token count, an Int from a UInt32.
        let start = UInt32(truncatingIfNeeded: name.start)
        let end = UInt32(truncatingIfNeeded: name.end)
        return WebCore.makeFontFamilyNameValue(tokens.value, WebCore.CSSValueID.Invalid.rawValue, start, end).get()
    }

    /// `consumeFamilyNameUnresolved`: the tokens of a <family-name>, a string or identifiers, and numbers if
    /// `allowNumbers` (the <font face> attribute's "Bodoni 72"). A lone identifier that names a generic family or is not
    /// a <custom-ident> is not one, and stays consumed.
    mutating func familyName(allowNumbers: Bool) -> (start: Int, end: Int)? {
        let start = index
        let type = peekType()
        if type == PropertyTokenType.string {
            consumeIncludingWhitespace()
            return (start, start &+ 1) // Below end, a token count.
        }
        guard type == PropertyTokenType.ident else {
            return nil
        }
        let first = peekIdent()
        var count = 0
        while peekType() == PropertyTokenType.ident || (allowNumbers && peekType() == PropertyTokenType.number) {
            consumeIncludingWhitespace()
            count &+= 1 // At most the token count.
        }
        if count == 1 && (!WebCore.isValidCustomIdentifier(first) || WebCore.isGenericFontFamilyForSwift(first.rawValue)) {
            return nil
        }
        return (start, index)
    }

    // MARK: - font-size-adjust

    // <'font-size-adjust'> = none | [ ex-height | cap-height | ch-width | ic-width | ic-height ]? [ from-font | <number [0,∞]> ]
    // https://drafts.csswg.org/css-fonts-5/#font-size-adjust-prop
    mutating func fontSizeAdjust(_ calc: PropertyCalc) -> PropertyValue? {
        let id = peekIdent()
        if id == .None || id == .FromFont {
            return consumeKeyword(peeked: id)
        }
        var metric = WebCore.CSSValueID.Invalid
        switch id {
        case .ExHeight, .CapHeight, .ChWidth, .IcWidth, .IcHeight:
            consumeIncludingWhitespace()
            metric = id
        default:
            break
        }
        var value = primitive(PropertyPrimitive(.number, min: 0), calc)
        if value == nil && peekIdent() == .FromFont {
            value = consumeKeyword(peeked: .FromFont)
        }
        guard let value else {
            return nil
        }
        // ex-height is the default metric, and is omitted.
        if metric == .Invalid || metric == .ExHeight {
            return value
        }
        return makePair(keywordValue(metric), value, coalescing: true)
    }

    // MARK: - font-palette

    // <'font-palette'> = normal | light | dark | <palette-identifier> | <palette-mix()>
    // https://drafts.csswg.org/css-fonts-4/#propdef-font-palette
    mutating func fontPalette() -> PropertyValue? {
        var parts = WebCore.CSSFontPaletteSwiftParts(0)
        guard fontPalette(&parts) else {
            return nil
        }
        return WebCore.makeFontPaletteValue(consuming: consume parts).get()
    }

    private mutating func fontPalette(_ parts: inout WebCore.CSSFontPaletteSwiftParts) -> Bool {
        let id = peekIdent()
        switch id {
        case .Invalid:
            break
        case .Normal, .Light, .Dark:
            consumeIncludingWhitespace()
            parts.appendKeyword(id.rawValue)
            return true
        default:
            return false
        }
        switch peekFunction() {
        case .Invalid:
            break
        case .PaletteMix:
            return paletteMix(&parts)
        default:
            return false
        }
        guard peekType() == PropertyTokenType.ident, tokens.value.isDashedIdent(index) else {
            return false
        }
        parts.appendIdentifier(tokens.value, UInt32(truncatingIfNeeded: index)) // Below end, a token count.
        consumeIncludingWhitespace()
        return true
    }

    // <palette-mix()> = palette-mix( <color-interpolation-method>? , [ <'font-palette'> && <percentage [0,100]>? ]# )
    // https://drafts.csswg.org/css-fonts-4/#funcdef-palette-mix
    // The function stays consumed whether its arguments parse or not.
    private mutating func paletteMix(_ parts: inout WebCore.CSSFontPaletteSwiftParts) -> Bool {
        guard contextEnables(UInt32(WebCore.CSSConsumerSwiftFontPaletteMixFunctionEnabled)), let function = beginFunction(.PaletteMix) else {
            return false
        }
        let parsed = paletteMixArguments(&parts)
        endColorFunction(function, true)
        return parsed
    }

    private mutating func paletteMixArguments(_ parts: inout WebCore.CSSFontPaletteSwiftParts) -> Bool {
        parts.beginMix()
        if peekIdent() == .In {
            guard let method = consumeColorInterpolationMethod(), consumeComma() else {
                return false
            }
            parts.setColorInterpolationMethod(consuming: consume method)
        }
        repeat {
            var percentage = WebCore.CSSColorSwiftComponents()
            let percentageFirst = consumeNumeric(&percentage, 0, .crossfadePercentage)
            guard fontPalette(&parts) else {
                return false
            }
            if !percentageFirst {
                _ = consumeNumeric(&percentage, 0, .crossfadePercentage)
            }
            parts.endMixComponent(percentage)
        } while consumeComma()
        guard atEnd else {
            return false
        }
        parts.endMix()
        return true
    }

    // MARK: - font-feature-settings and font-variation-settings

    /// `consumeFontOpenTypeTag`: a string of four characters in U+0020-U+007E, packed from the low byte up. Consumes
    /// nothing if there is none.
    mutating func openTypeTag() -> UInt32? {
        guard peekType() == PropertyTokenType.string, tokens.value.textLength(index) == 4 else {
            return nil
        }
        var tag: UInt32 = 0
        for offset in 0..<UInt32(4) {
            let character = tokens.value.textCharacter(index, offset)
            guard character >= 0x20 && character <= 0x7E else {
                return nil
            }
            tag |= UInt32(character) << (8 * offset)
        }
        consumeIncludingWhitespace()
        return tag
    }

    // <feature-tag-value> = <opentype-tag> [ <integer [0,∞]> | on | off ]?
    // https://drafts.csswg.org/css-fonts/#feature-tag-value
    mutating func featureTagValue(_ calc: PropertyCalc) -> PropertyValue? {
        guard let tag = openTypeTag() else {
            return nil
        }
        var integer = 1.0
        var calcIndex = UInt32.max
        if !atEnd && peekType() != PropertyTokenType.comma {
            if let numeric = integerOrCalc(min: 0, calc) {
                integer = numeric.number
                calcIndex = numeric.calc
            } else {
                let id = peekIdent()
                guard id == .On || id == .Off else {
                    return nil
                }
                consumeIncludingWhitespace()
                integer = id == .On ? 1 : 0
            }
        }
        return WebCore.makeFontFeatureValue(tokens.value, tag, integer, calcIndex).get()
    }

    // <variation-tag-value> = <opentype-tag> <number>
    // https://drafts.csswg.org/css-fonts/#font-variation-settings-def
    mutating func variationTagValue(_ calc: PropertyCalc) -> PropertyValue? {
        guard let tag = openTypeTag(), let number = primitive(PropertyPrimitive(.number), calc) else {
            return nil
        }
        return WebCore.makeFontVariationValue(tag, number).get()
    }

    // MARK: - font

    // <'font'> = [ <'font-style'> || <font-variant-css2> || <'font-weight'> || <font-width-css3> ]? <'font-size'>
    //            [ / <'line-height'> ]? <'font-family'>
    // https://drafts.csswg.org/css-fonts-4/#font-prop
    // `consumeUnresolvedFont`, which gives the font to setUnresolvedFontResult: the style, weight, size and line height
    // in components 0 to 3.
    mutating func unresolvedFont() -> PropertyValue? {
        var slots = WebCore.CSSColorSwiftComponents()
        var variantCaps = WebCore.CSSValueID.Invalid
        var width = WebCore.CSSValueID.Invalid
        var hasStyle = false
        var hasWeight = false
        // Up to four of normal, the style, small-caps, the weight and the width, in any order.
        var round = 0
        optionalParts: while round < 4 && !atEnd {
            round &+= 1 // At most 4.
            let id = peekIdent()
            if id == .Normal {
                consumeIncludingWhitespace()
                continue
            }
            if !hasStyle && (id == .Italic || id == .Oblique) {
                consumeIncludingWhitespace()
                hasStyle = true
                slots.setSymbol(0, id.rawValue)
                if id == .Oblique && !atEnd {
                    _ = obliqueAngle(&slots, 0)
                }
                continue
            }
            if variantCaps == .Invalid && id == .SmallCaps {
                consumeIncludingWhitespace()
                variantCaps = id
                continue
            }
            if !hasWeight {
                if id == .Bold || id == .Bolder || id == .Lighter {
                    consumeIncludingWhitespace()
                    hasWeight = true
                    slots.setSymbol(1, id.rawValue)
                    continue
                }
                if consumeNumeric(&slots, 1, .fontWeightNumber) {
                    hasWeight = true
                    continue
                }
            }
            if width == .Invalid {
                switch id {
                case .UltraCondensed, .ExtraCondensed, .Condensed, .SemiCondensed, .SemiExpanded, .Expanded, .ExtraExpanded, .UltraExpanded:
                    consumeIncludingWhitespace()
                    width = id
                    continue optionalParts
                default:
                    break
                }
            }
            break
        }
        guard !atEnd else {
            return nil
        }
        // <'font-size'>, and -webkit-xxx-large, which is xxx-large.
        let size = peekIdent()
        if size == .WebkitXxxLarge {
            consumeIncludingWhitespace()
            slots.setSymbol(2, WebCore.CSSValueID.XxxLarge.rawValue)
        } else if (size.rawValue >= WebCore.CSSValueID.XxSmall.rawValue && size.rawValue <= WebCore.CSSValueID.Larger.rawValue) || size == .Math {
            consumeIncludingWhitespace()
            slots.setSymbol(2, size.rawValue)
        } else if !consumeNumeric(&slots, 2, .nonnegativeLengthPercentage) {
            return nil
        }
        guard !atEnd else {
            return nil
        }
        if consumeSlash() {
            // A slash is followed by a <'line-height'>.
            if peekIdent() == .Normal {
                consumeIncludingWhitespace()
                slots.setSymbol(3, WebCore.CSSValueID.Normal.rawValue)
            } else if !(consumeNumeric(&slots, 3, .nonnegativeNumber) || consumeNumeric(&slots, 3, .nonnegativeLengthPercentage)) {
                return nil
            }
        }
        var parts = WebCore.CSSFontSwiftParts(0)
        repeat {
            let id = peekIdent()
            switch id {
            case .Serif, .SansSerif, .Cursive, .Fantasy, .Monospace, .WebkitBody, .WebkitPictograph, .SystemUi, .Math:
                consumeIncludingWhitespace()
                parts.appendFamily(id.rawValue, 0, 0)
            default:
                guard let name = familyName(allowNumbers: false) else {
                    return nil
                }
                appendFamilyName(&parts, name)
            }
        } while consumeComma()
        guard atEnd else {
            return nil
        }
        let normal = WebCore.CSSValueID.Normal
        WebCore.setUnresolvedFontResult(
            tokens.value,
            slots,
            (variantCaps == .Invalid ? normal : variantCaps).rawValue,
            (width == .Invalid ? normal : width).rawValue,
            consuming: consume parts
        )
        return nil
    }

    private func appendFamilyName(_ parts: inout WebCore.CSSFontSwiftParts, _ name: (start: Int, end: Int)) {
        // Both at most the token count, an Int from a UInt32.
        parts.appendFamily(WebCore.CSSValueID.Invalid.rawValue, UInt32(truncatingIfNeeded: name.start), UInt32(truncatingIfNeeded: name.end))
    }

    // MARK: - @font-face src

    // <font-src-list> = [ <url> [ format( <font-format> ) ]? [ tech( <font-tech># ) ]? | local( <family-name> ) ]#
    // https://drafts.csswg.org/css-fonts-4/#src-desc
    // Each entry runs to the next comma outside a block, and one that does not parse is dropped. Every token stays
    // consumed.
    mutating func fontFaceSrc() -> PropertyValue? {
        var list = PropertyValueList()
        var hasEntry = false
        while !atEnd {
            let entryStart = index
            while !atEnd && peekType() != PropertyTokenType.comma {
                consumeComponentValue()
            }
            let entryEnd = index
            let outerEnd = end
            index = entryStart
            end = entryEnd
            let entry = fontFaceSrcEntry()
            index = entryEnd
            end = outerEnd
            if let entry {
                list.append(entry)
                hasEntry = true
            }
            if !atEnd {
                consumeIncludingWhitespace()
            }
        }
        guard hasEntry else {
            return nil
        }
        return makeCommaSeparatedList(list)
    }

    /// `CSSParserTokenRange::consumeComponentValue`: a token, or a block whole. An unmatched block end drops the
    /// nesting below zero, and tokens are consumed until it returns to zero or the end, as the C++'s unsigned nesting
    /// does.
    private mutating func consumeComponentValue() {
        var nestingLevel = 0
        repeat {
            let blockType = tokens.value.blockType(index)
            index &+= 1 // At most end, a token count.
            if blockType == PropertyTokenType.blockStart {
                nestingLevel &+= 1 // Its magnitude is at most the tokens read.
            } else if blockType == PropertyTokenType.blockEnd {
                nestingLevel &-= 1 // Its magnitude is at most the tokens read.
            }
        } while nestingLevel != 0 && !atEnd
    }

    private mutating func fontFaceSrcEntry() -> PropertyValue? {
        if peekType() == UInt8(WebCore.UrlToken.rawValue) || peekFunction() == .Url {
            return fontFaceSrcURI()
        }
        if peekFunction() == .Local {
            return fontFaceSrcLocal()
        }
        return nil
    }

    // <font-src-uri> = <url> [ format( <font-format> ) ]? [ tech( <font-tech># ) ]?
    private mutating func fontFaceSrcURI() -> PropertyValue? {
        let urlStart = index
        let urlEnd: Int
        if peekType() == UInt8(WebCore.UrlToken.rawValue) {
            urlEnd = index &+ 1 // Below end.
        } else if let function = beginFunction(.Url) {
            urlEnd = function.next
            end = function.end
        } else {
            return nil
        }
        index = urlEnd
        consumeWhitespace()
        var format = UInt32.max
        var parts = WebCore.CSSFontSwiftParts(0)
        if peekFunction() == .Format {
            guard let argument = fontFormat(rejectingStrings: false) else {
                return nil
            }
            format = UInt32(truncatingIfNeeded: argument) // At most the token count, an Int from a UInt32.
        }
        if peekFunction() == .Tech {
            guard fontTech(&parts, singleValue: false) else {
                return nil
            }
        }
        guard atEnd else {
            return nil
        }
        // Both at most the token count, Ints from a UInt32.
        let start = UInt32(truncatingIfNeeded: urlStart)
        let next = UInt32(truncatingIfNeeded: urlEnd)
        return WebCore.makeFontFaceSrcResourceValue(tokens.value, start, next, format, consuming: consume parts).get()
    }

    // <font-src-local> = local( <family-name> )
    private mutating func fontFaceSrcLocal() -> PropertyValue? {
        guard let function = beginFunction(.Local) else {
            return nil
        }
        let name = familyName(allowNumbers: false)
        let parsed = name != nil && atEnd
        endColorFunction(function, true)
        guard let name, parsed, atEnd else {
            return nil
        }
        // Both at most the token count, Ints from a UInt32.
        return WebCore.makeFontFaceSrcLocalValue(tokens.value, UInt32(truncatingIfNeeded: name.start), UInt32(truncatingIfNeeded: name.end)).get()
    }

    // MARK: - tech() and format()

    // `consumeFontTech` of @supports font-tech(), whose options say whether it takes a single technology: gives the
    // technologies to setFontTechResult.
    mutating func fontTech() -> PropertyValue? {
        var parts = WebCore.CSSFontSwiftParts(0)
        let singleValue = tokens.value.consumerOptions() & UInt8(WebCore.CSSPropertyConsumerSwiftFontSingleValue) != 0
        if fontTech(&parts, singleValue: singleValue) {
            WebCore.setFontTechResult(tokens.value, consuming: consume parts)
        }
        return nil
    }

    // `consumeFontFormat` of @supports font-format(), whose options say whether it rejects strings: gives the format
    // to setFontFormatResult.
    mutating func fontFormat() -> PropertyValue? {
        let rejectingStrings = tokens.value.consumerOptions() & UInt8(WebCore.CSSPropertyConsumerSwiftFontRejectStringValues) != 0
        if let argument = fontFormat(rejectingStrings: rejectingStrings) {
            WebCore.setFontFormatResult(tokens.value, UInt32(truncatingIfNeeded: argument)) // At most the token count.
        }
        return nil
    }

    /// <font-tech># in the function at the next token, whatever its name, or one <font-tech> if `singleValue`. The
    /// function is consumed whether its arguments parse or not.
    // <font-tech> = <font-features-tech> | <color-font-tech> | variations | palettes | incremental
    // https://drafts.csswg.org/css-fonts-4/#font-tech-values
    private mutating func fontTech(_ parts: inout WebCore.CSSFontSwiftParts, singleValue: Bool) -> Bool {
        guard peekType() == PropertyTokenType.function, let function = beginFunction(peekFunction()) else {
            return false
        }
        let parsed = fontTechnologies(&parts, singleValue: singleValue)
        endColorFunction(function, true)
        return parsed
    }

    private mutating func fontTechnologies(_ parts: inout WebCore.CSSFontSwiftParts, singleValue: Bool) -> Bool {
        repeat {
            let type = peekType()
            let id = peekIdent()
            consumeIncludingWhitespace()
            guard type == PropertyTokenType.ident, parts.appendTechnology(id.rawValue) else {
                return false
            }
        } while consumeComma() && !singleValue
        return atEnd
    }

    /// The index of the <font-format> in the function at the next token, whatever its name: a string unless
    /// `rejectingStrings`, or a format keyword. The function is consumed whether it has one or not.
    // <font-format> = <string> | collection | embedded-opentype | opentype | svg | truetype | woff | woff2
    // https://drafts.csswg.org/css-fonts-4/#font-format-values
    private mutating func fontFormat(rejectingStrings: Bool) -> Int? {
        guard peekType() == PropertyTokenType.function, let function = beginFunction(peekFunction()) else {
            return nil
        }
        let argument = index
        let type = peekType()
        let id = peekIdent()
        consumeIncludingWhitespace()
        var parsed = false
        if atEnd {
            if type == PropertyTokenType.ident {
                switch id {
                case .Collection, .EmbeddedOpentype, .Opentype, .Svg, .Truetype, .Woff, .Woff2:
                    parsed = true
                default:
                    break
                }
            } else if type == PropertyTokenType.string {
                parsed = !rejectingStrings
            }
        }
        endColorFunction(function, true)
        return parsed ? argument : nil
    }

    // MARK: - @font-face font-style

    // <'font-style'> = auto | normal | italic | oblique [ <angle [-90deg,90deg]>{1,2} ]?
    // https://drafts.csswg.org/css-fonts-4/#descdef-font-face-font-style
    // Without auto. Consumes nothing if an angle does not parse.
    mutating func fontFaceFontStyle() -> PropertyValue? {
        let id = peekIdent()
        var angles = WebCore.CSSColorSwiftComponents()
        switch id {
        case .Normal, .Italic:
            consumeIncludingWhitespace()
            return WebCore.makeFontFaceFontStyleValue(id.rawValue, angles, 0).get()
        case .Oblique:
            let start = index
            consumeIncludingWhitespace()
            if atEnd {
                return WebCore.makeFontFaceFontStyleValue(id.rawValue, angles, 0).get()
            }
            // Oblique of angles that are all zero, and not calc(), is normal.
            let zero = peekType() != PropertyTokenType.function && tokens.value.numericValue(index) == 0
            guard obliqueAngle(&angles, 0) else {
                index = start
                return nil
            }
            if atEnd {
                return WebCore.makeFontFaceFontStyleValue(zero ? WebCore.CSSValueID.Normal.rawValue : id.rawValue, angles, 1).get()
            }
            let bothZero = zero && peekType() != PropertyTokenType.function && tokens.value.numericValue(index) == 0
            guard obliqueAngle(&angles, 1) else {
                index = start
                return nil
            }
            return WebCore.makeFontFaceFontStyleValue(bothZero ? WebCore.CSSValueID.Normal.rawValue : id.rawValue, angles, 2).get()
        default:
            return nil
        }
    }

    // MARK: - @font-feature-values prelude

    // <prelude-family-name-list> = <family-name>#
    // https://drafts.csswg.org/css-fonts/#font-feature-values-syntax
    // Gives the names to setFontFeatureValuesPreludeResult.
    mutating func fontFeatureValuesPrelude() -> PropertyValue? {
        var parts = WebCore.CSSFontSwiftParts(0)
        repeat {
            guard let name = familyName(allowNumbers: false) else {
                return nil
            }
            appendFamilyName(&parts, name)
        } while consumeComma()
        WebCore.setFontFeatureValuesPreludeResult(tokens.value, consuming: consume parts)
        return nil
    }
}
