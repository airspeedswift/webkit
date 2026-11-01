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

#if USE_SWIFT_CSS_PROPERTY_CONSUMERS

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

internal import WebCore_Private.Core.CSSPropertyConsumerSwiftTypes

// The hand-written property consumers: background-size, -webkit-background-size and mask-size
// (CSSPropertyParserConsumer+Background.cpp), translate, rotate, scale, translate(), translate3d() and rotate3d()
// (+Transform.cpp), stroke-dasharray (+SVG.cpp), and animation-range-start and -end (+Timeline.cpp).

extension PropertyParser {
    /// The hand-written consumer of the CSSPropertyID `consumer`.
    mutating func consumeHandWritten(_ consumer: UInt16, _ calc: PropertyCalc) -> PropertyValue? {
        switch consumer {
        case WebCore.CSSPropertyID.BackgroundSize.rawValue: return backgroundSize(.backgroundSize, calc)
        case WebCore.CSSPropertyID.WebkitBackgroundSize.rawValue: return backgroundSize(.webkitBackgroundSize, calc)
        case WebCore.CSSPropertyID.MaskSize.rawValue: return backgroundSize(.maskSize, calc)
        case WebCore.CSSPropertyID.Translate.rawValue: return translate(calc)
        case WebCore.CSSPropertyID.Rotate.rawValue: return rotate(calc)
        case WebCore.CSSPropertyID.Scale.rawValue: return scale(calc)
        case WebCore.CSSPropertyID.StrokeDasharray.rawValue: return strokeDasharray(calc)
        case WebCore.CSSPropertyID.AnimationRangeStart.rawValue: return animationRange(isStart: true, calc)
        case WebCore.CSSPropertyID.AnimationRangeEnd.rawValue: return animationRange(isStart: false, calc)
        default: return nil
        }
    }

    /// `consumeIdent` of the next token if it is `id`.
    private mutating func consumeKeyword(_ id: WebCore.CSSValueID) -> PropertyValue? {
        peekIdent() == id ? consumeKeyword() : nil
    }

    enum BackgroundSizeProperty {
        case backgroundSize
        case webkitBackgroundSize
        case maskSize
    }

    // <bg-size> = [ <length-percentage [0,∞]> | auto ]{1,2} | cover | contain
    // https://drafts.csswg.org/css-backgrounds/#propdef-background-size
    private mutating func backgroundSize(_ property: BackgroundSizeProperty, _ calc: PropertyCalc) -> PropertyValue? {
        let id = peekIdent()
        if id == .Contain || id == .Cover {
            return consumeKeyword()
        }

        let size = PropertyPrimitive(.lengthPercentage, min: 0)
        var shouldCoalesce = true
        var horizontal = consumeKeyword(.Auto)
        if horizontal == nil {
            horizontal = primitive(size, calc)
            guard horizontal != nil else {
                return nil
            }
            shouldCoalesce = false
        }
        guard let horizontal else {
            return nil
        }

        var vertical: PropertyValue? = nil
        if !atEnd {
            vertical = consumeKeyword(.Auto) ?? primitive(size, calc)
        }
        if vertical == nil {
            switch property {
            case .webkitBackgroundSize:
                // Legacy syntax: "-webkit-background-size: 10px" is equivalent to "background-size: 10px 10px".
                vertical = horizontal
            case .maskSize:
                return horizontal
            case .backgroundSize:
                vertical = keywordValue(.Auto)
            }
        }
        guard let vertical else {
            return nil
        }
        return makePair(horizontal, vertical, coalescing: shouldCoalesce)
    }

    // none | <length-percentage> [ <length-percentage> <length>? ]?
    // https://drafts.csswg.org/css-transforms-2/#propdef-translate
    private mutating func translate(_ calc: PropertyCalc) -> PropertyValue? {
        if peekIdent() == .None {
            return consumeKeyword()
        }

        guard let x = inlineNumeric(PropertyPrimitive(.lengthPercentage), calc) else {
            return nil
        }
        consumeWhitespace()
        if atEnd {
            return makeSpaceSeparatedList(x.value)
        }

        guard let y = inlineNumeric(PropertyPrimitive(.lengthPercentage), calc) else {
            return nil
        }
        consumeWhitespace()

        // A calc(), percentage or non-zero y is kept; a zero y only when a non-zero z follows. 0% always serializes.
        let haveNonZeroY = y.isCalculated || y.unit == .Percentage || y.number != 0
        if atEnd {
            return haveNonZeroY ? makeSpaceSeparatedList(x.value, y.value) : makeSpaceSeparatedList(x.value)
        }

        guard let z = inlineNumeric(PropertyPrimitive(.length), calc) else {
            return nil
        }
        let haveNonZeroZ = z.isCalculated || z.unit == .Percentage || z.number != 0
        if !haveNonZeroY && !haveNonZeroZ {
            return makeSpaceSeparatedList(x.value)
        }
        if !haveNonZeroZ {
            return makeSpaceSeparatedList(x.value, y.value)
        }
        return makeSpaceSeparatedList(x.value, y.value, z.value)
    }

    // none | <angle> | [ x | y | z | <number>{3} ] && <angle>
    // https://drafts.csswg.org/css-transforms-2/#propdef-rotate
    private mutating func rotate(_ calc: PropertyCalc) -> PropertyValue? {
        if peekIdent() == .None {
            return consumeKeyword()
        }

        // The first three numbers; more than three make the value invalid, but are still read.
        var numbers: (PropertyNumeric?, PropertyNumeric?, PropertyNumeric?) = (nil, nil, nil)
        var numberCount = 0
        var angle: PropertyNumeric? = nil
        var axis: PropertyValue? = nil
        var axisID = WebCore.CSSValueID.Invalid

        while !atEnd {
            // A number first, so that a unitless 0 is a number rather than an angle.
            if let number = inlineNumeric(PropertyPrimitive(.number), calc) {
                guard axis == nil else {
                    return nil
                }
                switch numberCount {
                case 0: numbers.0 = number
                case 1: numbers.1 = number
                case 2: numbers.2 = number
                default: break
                }
                numberCount &+= 1 // At most the tokens read.
                consumeWhitespace()
                continue
            }

            if let parsedAngle = inlineNumeric(PropertyPrimitive(.angle), calc) {
                guard angle == nil, numberCount == 0 || numberCount == 3 else {
                    return nil
                }
                angle = parsedAngle
                consumeWhitespace()
                continue
            }

            let id = peekIdent()
            guard id == .X || id == .Y || id == .Z, axis == nil, numberCount == 0 else {
                return nil
            }
            axisID = id
            axis = consumeKeyword()
            consumeWhitespace()
        }

        guard let angle else {
            return nil
        }

        if numberCount == 3, let x = numbers.0, let y = numbers.1, let z = numbers.2 {
            // An axis along x, y or z serializes as that axis, with the angle negated if the axis points the other way.
            // https://drafts.csswg.org/css-transforms-2/#individual-transform-serialization
            func angleAlong(_ axis: PropertyNumeric) -> PropertyValue {
                guard axis.isKnownNegative, !angle.isCalculated else {
                    return angle.value
                }
                return WebCore.CSSPrimitiveValue.create(-angle.number, angle.unit).get()
            }
            if x.isKnownNonzero && y.isKnownZero && z.isKnownZero {
                return makeSpaceSeparatedList(keywordValue(.X), angleAlong(x))
            }
            if x.isKnownZero && y.isKnownNonzero && z.isKnownZero {
                return makeSpaceSeparatedList(keywordValue(.Y), angleAlong(y))
            }
            if x.isKnownZero && y.isKnownZero && z.isKnownNonzero {
                return makeSpaceSeparatedList(angleAlong(z))
            }
            return makeSpaceSeparatedList(x.value, y.value, z.value, angle.value)
        }

        guard numberCount == 0 else {
            return nil
        }
        if let axis, axisID != .Z {
            return makeSpaceSeparatedList(axis, angle.value)
        }
        return makeSpaceSeparatedList(angle.value)
    }

    // none | [ <number> | <percentage> ]{1,3}
    // https://drafts.csswg.org/css-transforms-2/#propdef-scale
    private mutating func scale(_ calc: PropertyCalc) -> PropertyValue? {
        if peekIdent() == .None {
            return consumeKeyword()
        }

        let component = PropertyPrimitive(.numberOrPercentageResolvedToNumber)
        guard let x = inlineNumeric(component, calc) else {
            return nil
        }
        consumeWhitespace()
        if atEnd {
            return makeSpaceSeparatedList(x.value)
        }

        guard let y = inlineNumeric(component, calc) else {
            return nil
        }
        consumeWhitespace()

        // raw() is nil for a calc(); both units are CSSUnitType::Number.
        let xIsY = !x.isCalculated && !y.isCalculated && x.number == y.number
        if atEnd {
            return xIsY ? makeSpaceSeparatedList(x.value) : makeSpaceSeparatedList(x.value, y.value)
        }

        guard let z = inlineNumeric(component, calc) else {
            return nil
        }
        if z.isCalculated || z.number != 1 {
            return makeSpaceSeparatedList(x.value, y.value, z.value)
        }
        return xIsY ? makeSpaceSeparatedList(x.value) : makeSpaceSeparatedList(x.value, y.value)
    }

    // <'stroke-dasharray'> = none | [ [ <length-percentage> | <number> ]+ ]#
    // https://svgwg.org/svg2-draft/painting.html#StrokeDashing
    private mutating func strokeDasharray(_ calc: PropertyCalc) -> PropertyValue? {
        if peekIdent() == .None {
            return consumeKeyword()
        }
        let length = PropertyPrimitive(.lengthPercentage, min: 0, forbidUnitlessZeroLength: true, standardMode: true)
        let number = PropertyPrimitive(.number, min: 0)
        var dashes = PropertyValueList()
        repeat {
            // A number token is never a <length-percentage> here: its mode is HTMLStandardMode, which accepts no
            // unitless length, and a unitless zero is forbidden.
            let parsed = peekIsNumber() ? inlinePrimitive(number, calc) : inlinePrimitive(length, calc) ?? inlinePrimitive(number, calc)
            guard let dash = parsed else {
                return nil
            }
            // A trailing comma is invalid.
            if consumeComma() && atEnd {
                return nil
            }
            dashes.append(dash)
        } while !atEnd
        return makeCommaSeparatedList(consume dashes)
    }

    // <'animation-range-{start|end}'> = normal | <length-percentage> | <timeline-range-name> <length-percentage>?
    // https://drafts.csswg.org/scroll-animations-1/#propdef-animation-range-start
    private mutating func animationRange(isStart: Bool, _ calc: PropertyCalc) -> PropertyValue? {
        let id = peekIdent()
        if id == .Normal {
            return consumeKeyword()
        }
        if isTimelineRangeName(id) {
            guard let name = consumeKeyword() else {
                return nil
            }
            guard let offset = numeric(PropertyPrimitive(.lengthPercentage), calc) else {
                return name
            }
            // The default offset, 0% for a start and 100% for an end, is omitted.
            if !offset.isCalculated && offset.unit == .Percentage && offset.number == (isStart ? 0 : 100) {
                return name
            }
            return makePair(name, offset.value, coalescing: false)
        }
        return primitive(PropertyPrimitive(.lengthPercentage), calc)
    }

    // translate() = translate( <length-percentage> , <length-percentage>? )
    // https://drafts.csswg.org/css-transforms-1/#funcdef-transform-translate
    mutating func translateFunction(_ calc: PropertyCalc) -> PropertyValue? {
        guard let function = beginFunction(.Translate) else {
            return nil
        }
        return endFunction(function, translateArguments(calc))
    }

    private mutating func translateArguments(_ calc: PropertyCalc) -> PropertyValue? {
        guard !atEnd, let x = primitive(PropertyPrimitive(.lengthPercentage), calc) else {
            return nil
        }
        if consumeComma() {
            guard let y = numeric(PropertyPrimitive(.lengthPercentage), calc) else {
                return nil
            }
            // A second value of 0 is the same as no second argument.
            if !y.isKnownZero {
                return makeFunction(.Translate, x, y.value)
            }
        }
        return makeFunction(.Translate, x)
    }

    // translate3d() = translate3d( <length-percentage> , <length-percentage> , <length> )
    // https://drafts.csswg.org/css-transforms-2/#funcdef-translate3d
    mutating func translate3dFunction(_ calc: PropertyCalc) -> PropertyValue? {
        guard let function = beginFunction(.Translate3d) else {
            return nil
        }
        return endFunction(function, translate3dArguments(calc))
    }

    private mutating func translate3dArguments(_ calc: PropertyCalc) -> PropertyValue? {
        guard !atEnd, let x = primitive(PropertyPrimitive(.lengthPercentage), calc), consumeComma(),
            let y = primitive(PropertyPrimitive(.lengthPercentage), calc), consumeComma(),
            let z = primitive(PropertyPrimitive(.length), calc)
        else {
            return nil
        }
        return makeFunction(.Translate3d, x, y, z)
    }

    // rotate3d() = rotate3d( <number> , <number> , <number> , [ <angle> | <zero> ] )
    // https://drafts.csswg.org/css-transforms-2/#funcdef-rotate3d
    mutating func rotate3dFunction(_ calc: PropertyCalc) -> PropertyValue? {
        guard let function = beginFunction(.Rotate3d) else {
            return nil
        }
        return endFunction(function, rotate3dArguments(calc))
    }

    private mutating func rotate3dArguments(_ calc: PropertyCalc) -> PropertyValue? {
        guard !atEnd, let x = primitive(PropertyPrimitive(.number), calc), consumeComma(),
            let y = primitive(PropertyPrimitive(.number), calc), consumeComma(),
            let z = primitive(PropertyPrimitive(.number), calc), consumeComma(),
            let angle = primitive(PropertyPrimitive(.angle, allowUnitlessZeroAngle: true), calc)
        else {
            return nil
        }
        return makeFunction(.Rotate3d, x, y, z, angle)
    }
}

/// `isTimelineRangeName` (CSSPropertyParserConsumer+Timeline.cpp).
///
/// <timeline-range-name> = cover | contain | entry | exit | entry-crossing | exit-crossing | scroll
private func isTimelineRangeName(_ id: WebCore.CSSValueID) -> Bool {
    switch id {
    case .Cover, .Contain, .Entry, .Exit, .EntryCrossing, .ExitCrossing, .Scroll:
        return true
    default:
        return false
    }
}

#endif // USE_SWIFT_CSS_PROPERTY_CONSUMERS
