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

// The consumers of CSSPropertyParserConsumer+Shapes.cpp (<basic-shape-rect>, path() and shape-outside),
// CSSPropertyParserConsumer+Masking.cpp (clip, clip-path and mask-border) and CSSPropertyParserConsumer+Motion.cpp
// (offset-path).
//
// Every basic shape is a CSS:: value built in C++ from what Swift consumed (CSSImageSwiftParts and makeBasicShapeValue).
// A basic shape that does not parse consumes nothing; path() for d and ray() stay consumed even when they do not parse,
// as consumePath and consumeRayFunction leave them.

/// What a basic shape's arguments hold besides its components: its position and its fill rule, and path()'s string.
// FIXME: Make this private once a private type links under ThinLTO on Windows ("Invalid weak external").
struct BasicShapeArguments: ~Copyable {
    var parts = WebCore.CSSImageSwiftParts()
    var position = WebCore.CSSColorSwiftComponents()
    var positionLayout = WebCore.CSSImageSwiftNoPosition
    var fillRule = WebCore.CSSValueID.Invalid
    var pathString = UInt32.max
}

extension PropertyParser {
    // MARK: - <basic-shape>

    // <basic-shape>      = <circle()> | <ellipse()> | <inset()> | <path()> | <polygon()> | <rect()> | <shape()> | <xywh()>
    // <basic-shape-rect> = <inset()> | <rect()> | <xywh()>
    // https://drafts.csswg.org/css-shapes/#typedef-basic-shape
    // https://drafts.csswg.org/css-shapes-1/#typedef-basic-shape-rect
    mutating func basicShape(rectOnly: Bool, rejectPathFillRule: Bool) -> PropertyValue? {
        let name = peekFunction()
        switch name {
        case .Inset, .Rect, .Xywh:
            break
        case .Circle, .Ellipse, .Polygon, .Path, .Shape:
            guard !rectOnly else {
                return nil
            }
        default:
            return nil
        }
        guard let function = beginFunction(name) else {
            return nil
        }
        var arguments = BasicShapeArguments()
        let parsed = basicShapeArguments(name, &arguments, rejectPathFillRule: rejectPathFillRule) && atEnd
        let value = parsed ? makeBasicShapeValue(name, arguments, asPathValue: false) : nil
        endColorFunction(function, value != nil)
        return value
    }

    // <'shape-outside'> = none | [ <basic-shape> || <shape-box> ] | <image>
    // https://drafts.csswg.org/css-shapes-1/#propdef-shape-outside
    mutating func shapeOutside() -> PropertyValue? {
        if let image = consumeImageOrNone(defaultAllowedImageTypes) {
            return image
        }
        var boxID = peekIdent()
        var box = consumeShapeBox()
        let shape = basicShape(rectOnly: false, rejectPathFillRule: false)
        if box == nil {
            boxID = peekIdent()
            box = consumeShapeBox()
        }
        guard let shape else {
            guard let box else {
                return nil
            }
            return makeSpaceSeparatedList(box)
        }
        // margin-box is the default.
        guard let box, boxID != .MarginBox else {
            return makeSpaceSeparatedList(shape)
        }
        return makeSpaceSeparatedList(shape, box)
    }

    // <path()> = path( <'fill-rule'>? , <string> ), for d.
    // https://drafts.csswg.org/css-shapes/#funcdef-basic-shape-path
    mutating func path() -> PropertyValue? {
        guard let function = beginFunction(.Path) else {
            return nil
        }
        var arguments = BasicShapeArguments()
        let parsed = pathArguments(&arguments, rejectFillRule: false) && atEnd
        let value = parsed ? makeBasicShapeValue(.Path, arguments, asPathValue: true) : nil
        // consumePath consumes the function whether or not it parses.
        endColorFunction(function, true)
        return value
    }

    private func makeBasicShapeValue(_ name: WebCore.CSSValueID, _ arguments: consuming BasicShapeArguments, asPathValue: Bool) -> PropertyValue? {
        WebCore.makeBasicShapeValue(
            tokens.value,
            name.rawValue,
            arguments.fillRule.rawValue,
            arguments.pathString,
            asPathValue,
            arguments.position,
            arguments.positionLayout,
            consuming: arguments.parts
        ).get()
    }

    /// The arguments of the basic shape `name`, into `arguments`; false if they are not its arguments. What follows
    /// them is not checked.
    private mutating func basicShapeArguments(_ name: WebCore.CSSValueID, _ arguments: inout BasicShapeArguments, rejectPathFillRule: Bool) -> Bool {
        switch name {
        case .Circle:
            // <circle()> = circle( <radial-size>? [ at <position> ]? ), closest-side by default.
            // FIXME: The specification allows only a <length> and makes `farthest-corner` the default.
            if !shapeRadius(&arguments.parts) {
                arguments.parts.append(Self.closestSide, 0)
            }
            return shapePosition(&arguments)
        case .Ellipse:
            // <ellipse()> = ellipse( [ <shape-radius>{2} ]? [ at <position> ]? ): a first radius needs a second.
            if shapeRadius(&arguments.parts) {
                guard shapeRadius(&arguments.parts) else {
                    return false
                }
            } else {
                arguments.parts.append(Self.closestSide, 0)
                arguments.parts.append(Self.closestSide, 0)
            }
            return shapePosition(&arguments)
        case .Inset:
            // <inset()> = inset( <length-percentage>{1,4} [ round <'border-radius'> ]? )
            var count: UInt8 = 0
            var components = WebCore.CSSColorSwiftComponents()
            while count < 4 && consumeNumeric(&components, 0, .lengthPercentage) {
                arguments.parts.append(components, 0)
                count += 1
            }
            guard count != 0 else {
                return false
            }
            arguments.parts.append(WebCore.CSSColorSwiftComponents(), count..<4)
            return shapeRound(&arguments.parts)
        case .Rect:
            // <rect()> = rect( [ <length-percentage> | auto ]{4} [ round <'border-radius'> ]? )
            var components = WebCore.CSSColorSwiftComponents()
            for _ in 0..<4 {
                if peekType() == PropertyTokenType.ident {
                    guard peekIdent() == .Auto else {
                        return false
                    }
                    consumeIncludingWhitespace()
                    components.setSymbol(0, WebCore.CSSValueID.Auto.rawValue)
                } else {
                    guard consumeNumeric(&components, 0, .lengthPercentage) else {
                        return false
                    }
                }
                arguments.parts.append(components, 0)
            }
            return shapeRound(&arguments.parts)
        case .Xywh:
            // <xywh()> = xywh( <length-percentage>{2} <length-percentage [0,∞]>{2} [ round <'border-radius'> ]? )
            var components = WebCore.CSSColorSwiftComponents()
            guard consumeNumeric(&components, 0, .lengthPercentage), consumeNumeric(&components, 1, .lengthPercentage),
                consumeNumeric(&components, 2, .nonnegativeLengthPercentage), consumeNumeric(&components, 3, .nonnegativeLengthPercentage)
            else {
                return false
            }
            arguments.parts.append(components, 0..<4)
            return shapeRound(&arguments.parts)
        case .Polygon:
            // <polygon()> = polygon( <'fill-rule'>? , [<length-percentage> <length-percentage>]# ).
            // FIXME: Support the `round` clause.
            arguments.fillRule = consumeFillRule()
            if arguments.fillRule != .Invalid {
                guard consumeComma() else {
                    return false
                }
            }
            var vertex = WebCore.CSSColorSwiftComponents()
            repeat {
                guard consumeNumeric(&vertex, 0, .lengthPercentage), consumeNumeric(&vertex, 1, .lengthPercentage) else {
                    return false
                }
                arguments.parts.append(vertex, 0..<2)
            } while consumeComma()
            return true
        case .Shape:
            // <shape()> = shape( <'fill-rule'>? from <position>, <shape-command># ), with no comma after the fill rule.
            // The starting point is a <position>, not the specification's <coordinate-pair>.
            arguments.fillRule = consumeFillRule()
            guard peekIdent() == .From else {
                return false
            }
            consumeIncludingWhitespace()
            guard appendPosition(&arguments.parts), consumeComma() else {
                return false
            }
            repeat {
                guard shapeCommand(&arguments.parts) else {
                    return false
                }
            } while consumeComma()
            return true
        default:
            return pathArguments(&arguments, rejectFillRule: rejectPathFillRule)
        }
    }

    // MARK: - <shape-command>

    /// Appends a <shape-command>: its keyword and to or by, then its operands, as makeShapeSwift reads them. The
    /// command's keyword is consumed before its arguments are read.
    private mutating func shapeCommand(_ parts: inout WebCore.CSSImageSwiftParts) -> Bool {
        guard peekType() == PropertyTokenType.ident else {
            return false
        }
        let id = peekIdent()
        consumeIncludingWhitespace()
        switch id {
        case .Close:
            appendSymbol(&parts, id)
            return true
        case .Move, .Line, .Hline, .Vline, .Curve, .Smooth, .Arc:
            break
        default:
            return false
        }
        // <by-to> = by | to
        let affinity = peekIdent()
        guard affinity == .To || affinity == .By else {
            return false
        }
        consumeIncludingWhitespace()
        appendSymbol(&parts, id)
        appendSymbol(&parts, affinity)
        let to = affinity == .To
        switch id {
        case .Move, .Line:
            // move [to <position>] | [by <coordinate-pair>], and line the same.
            return to ? appendPosition(&parts) : appendCoordinatePair(&parts)
        case .Hline, .Vline:
            // hline to [ <length-percentage> | left | center | right | x-start | x-end ] | by <length-percentage>, and
            // vline with the vertical keywords.
            var components = WebCore.CSSColorSwiftComponents()
            if to && peekType() == PropertyTokenType.ident {
                guard consumeAxisKeyword(&components, horizontal: id == .Hline) != nil else {
                    return false
                }
            } else {
                guard consumeNumeric(&components, 0, .lengthPercentage) else {
                    return false
                }
            }
            parts.append(components, 0)
            return true
        case .Curve:
            // curve [to <position> with <to-control-point> [/ <to-control-point>]?]
            //     | [by <coordinate-pair> with <relative-control-point> [/ <relative-control-point>]?]
            guard to ? appendPosition(&parts) : appendCoordinatePair(&parts), peekIdent() == .With else {
                return false
            }
            consumeIncludingWhitespace()
            guard appendControlPoint(&parts, to: to) else {
                return false
            }
            guard consumeSlash() else {
                appendAbsent(&parts)
                return true
            }
            return appendControlPoint(&parts, to: to)
        case .Smooth:
            // smooth [to <position> [with <to-control-point>]?] | [by <coordinate-pair> [with <relative-control-point>]?]
            guard to ? appendPosition(&parts) : appendCoordinatePair(&parts) else {
                return false
            }
            guard peekIdent() == .With else {
                appendAbsent(&parts)
                return true
            }
            consumeIncludingWhitespace()
            return appendControlPoint(&parts, to: to)
        default:
            return arcCommand(&parts, to: to)
        }
    }

    /// The rest of `arc [to <position>] | [by <coordinate-pair>] of <length-percentage>{1,2} [<arc-sweep>? || <arc-size>?
    /// || [rotate <angle>]?]` after its <by-to>; a single radius is used twice.
    private mutating func arcCommand(_ parts: inout WebCore.CSSImageSwiftParts, to: Bool) -> Bool {
        guard to ? appendPosition(&parts) : appendCoordinatePair(&parts), peekIdent() == .Of else {
            return false
        }
        consumeIncludingWhitespace()
        var radii = WebCore.CSSColorSwiftComponents()
        guard consumeNumeric(&radii, 0, .lengthPercentage) else {
            return false
        }
        let second: UInt8 = consumeNumeric(&radii, 1, .lengthPercentage) ? 1 : 0
        parts.append(radii, 0)
        parts.append(radii, second)
        // The sweep at 0, the size at 1 and the rotation at 2, each at most once, until the end of the command.
        var options = WebCore.CSSColorSwiftComponents()
        while !atEnd && peekType() != PropertyTokenType.comma {
            let id = peekIdent()
            switch id {
            case .Cw, .Ccw, .Large, .Small:
                let slot: UInt8 = id == .Cw || id == .Ccw ? 0 : 1
                guard options.type(slot) == 0 else {
                    return false
                }
                consumeIncludingWhitespace()
                options.setSymbol(slot, id.rawValue)
            case .Rotate:
                guard options.type(2) == 0 else {
                    return false
                }
                consumeIncludingWhitespace()
                guard consumeNumeric(&options, 2, .strictAngle) else {
                    return false
                }
            default:
                return false
            }
        }
        parts.append(options, 0..<3)
        return true
    }

    /// Appends a <position>: its layout as a symbol, then its four components.
    private mutating func appendPosition(_ parts: inout WebCore.CSSImageSwiftParts) -> Bool {
        var components = WebCore.CSSColorSwiftComponents()
        guard let layout = consumePosition(&components, maxComponents: 4, allowsThree: false) else {
            return false
        }
        var header = WebCore.CSSColorSwiftComponents()
        header.setSymbol(0, layout)
        parts.append(header, 0)
        parts.append(components, 0..<4)
        return true
    }

    /// Appends a <coordinate-pair> = <length-percentage>{2}. Consumes nothing if there is none.
    private mutating func appendCoordinatePair(_ parts: inout WebCore.CSSImageSwiftParts) -> Bool {
        var components = WebCore.CSSColorSwiftComponents()
        guard relativeControlPoint(&components, anchored: false) else {
            return false
        }
        parts.append(components, 0..<2)
        return true
    }

    /// Appends a <to-control-point> = [<position> | <relative-control-point>] if `to`, trying a relative control point
    /// first and keeping its coordinates as a position's, else a <relative-control-point>; then the anchor.
    // FIXME: The specification should resolve the ambiguity between a <position> and a <relative-control-point>.
    private mutating func appendControlPoint(_ parts: inout WebCore.CSSImageSwiftParts, to: Bool) -> Bool {
        var components = WebCore.CSSColorSwiftComponents()
        if relativeControlPoint(&components, anchored: true) {
            if to {
                var header = WebCore.CSSColorSwiftComponents()
                header.setSymbol(0, positionLayout(0, vertical: 1))
                parts.append(header, 0)
                parts.append(components, 0..<2)
                parts.append(WebCore.CSSColorSwiftComponents(), 2..<4)
            } else {
                parts.append(components, 0..<2)
            }
            parts.append(components, 2)
            return true
        }
        guard to, appendPosition(&parts) else {
            return false
        }
        appendAbsent(&parts)
        return true
    }

    /// <relative-control-point> = [<coordinate-pair> [from [start | end | origin]]?], the coordinates into components
    /// 0-1 and the anchor into 2 (if `anchored`). Consumes nothing if there is none.
    private mutating func relativeControlPoint(_ components: inout WebCore.CSSColorSwiftComponents, anchored: Bool) -> Bool {
        let start = index
        guard consumeNumeric(&components, 0, .lengthPercentage), consumeNumeric(&components, 1, .lengthPercentage) else {
            index = start
            return false
        }
        guard anchored, peekIdent() == .From else {
            return true
        }
        consumeIncludingWhitespace()
        let anchor = peekIdent()
        guard anchor == .Start || anchor == .End || anchor == .Origin else {
            index = start
            return false
        }
        consumeIncludingWhitespace()
        components.setSymbol(2, anchor.rawValue)
        return true
    }

    private func appendSymbol(_ parts: inout WebCore.CSSImageSwiftParts, _ id: WebCore.CSSValueID) {
        var components = WebCore.CSSColorSwiftComponents()
        components.setSymbol(0, id.rawValue)
        parts.append(components, 0)
    }

    private func appendAbsent(_ parts: inout WebCore.CSSImageSwiftParts) {
        parts.append(WebCore.CSSColorSwiftComponents(), 0)
    }

    /// path()'s arguments: an optional fill rule (rejected if `rejectFillRule`) and a comma, then the string, whose
    /// token the builder reads.
    private mutating func pathArguments(_ arguments: inout BasicShapeArguments, rejectFillRule: Bool) -> Bool {
        let fillRule = peekIdent()
        if fillRule == .Nonzero || fillRule == .Evenodd {
            guard !rejectFillRule else {
                return false
            }
            consumeIncludingWhitespace()
            guard consumeComma() else {
                return false
            }
            arguments.fillRule = fillRule
        }
        guard peekType() == PropertyTokenType.string else {
            return false
        }
        arguments.pathString = UInt32(truncatingIfNeeded: index) // Below end, a token count.
        consumeIncludingWhitespace()
        return true
    }

    /// The default radius, closest-side.
    private static var closestSide: WebCore.CSSColorSwiftComponents {
        var components = WebCore.CSSColorSwiftComponents()
        components.setSymbol(0, WebCore.CSSValueID.ClosestSide.rawValue)
        return components
    }

    /// Appends a <radial-extent> or a <length-percentage [0,∞]>; false and nothing consumed if there is none, an
    /// identifier that is not an extent included.
    private mutating func shapeRadius(_ parts: inout WebCore.CSSImageSwiftParts) -> Bool {
        var components = WebCore.CSSColorSwiftComponents()
        if peekType() == PropertyTokenType.ident {
            let id = peekIdent()
            guard id == .ClosestSide || id == .ClosestCorner || id == .FarthestSide || id == .FarthestCorner else {
                return false
            }
            consumeIncludingWhitespace()
            components.setSymbol(0, id.rawValue)
        } else {
            guard consumeNumeric(&components, 0, .nonnegativeLengthPercentage) else {
                return false
            }
        }
        parts.append(components, 0)
        return true
    }

    /// `at <position>`, if there is `at`.
    private mutating func shapePosition(_ arguments: inout BasicShapeArguments) -> Bool {
        guard peekIdent() == .At else {
            return true
        }
        consumeIncludingWhitespace()
        guard let layout = consumePosition(&arguments.position, maxComponents: 4, allowsThree: false) else {
            return false
        }
        arguments.positionLayout = layout
        return true
    }

    /// Appends the radii of `round <'border-radius'>`, or eight absent ones if there is no round.
    private mutating func shapeRound(_ parts: inout WebCore.CSSImageSwiftParts) -> Bool {
        guard peekIdent() == .Round else {
            let absent = WebCore.CSSColorSwiftComponents()
            parts.append(absent, 0..<4)
            parts.append(absent, 0..<4)
            return true
        }
        consumeIncludingWhitespace()
        return consumeBorderRadius(&parts, .BorderRadius)
    }

    /// `consumeFillRule`: nonzero or evenodd, consumed, else Invalid.
    private mutating func consumeFillRule() -> WebCore.CSSValueID {
        let id = peekIdent()
        guard id == .Nonzero || id == .Evenodd else {
            return .Invalid
        }
        consumeIncludingWhitespace()
        return id
    }
}

extension PropertyParser {
    // MARK: - Masking

    // <'clip'> = <rect()> | auto
    // https://drafts.csswg.org/css-masking/#propdef-clip
    mutating func clip() -> PropertyValue? {
        var parts = WebCore.CSSImageSwiftParts()
        var edges = WebCore.CSSColorSwiftComponents()
        if peekIdent() == .Auto {
            consumeIncludingWhitespace()
            edges.setSymbol(0, WebCore.CSSValueID.Auto.rawValue)
            parts.append(edges, 0)
            return makeMaskingValue(.Clip, parts)
        }
        // rect() = rect( <top>, <right>, <bottom>, <left> ), with the edges separated all by commas or all by spaces.
        // https://drafts.fxtf.org/css-masking/#funcdef-clip-rect
        guard let function = beginFunction(.Rect) else {
            return nil
        }
        var parsed = clipEdge(&edges, 0)
        let commas = parsed && consumeComma()
        parsed = parsed && clipEdge(&edges, 1) && (!commas || consumeComma())
        parsed = parsed && clipEdge(&edges, 2) && (!commas || consumeComma())
        parsed = parsed && clipEdge(&edges, 3) && atEnd
        endColorFunction(function, parsed)
        guard parsed else {
            return nil
        }
        parts.append(edges, 0..<4)
        return makeMaskingValue(.Clip, parts)
    }

    /// A clip edge, auto or a <length>, into component `slot`.
    private mutating func clipEdge(_ edges: inout WebCore.CSSColorSwiftComponents, _ slot: UInt8) -> Bool {
        guard peekIdent() == .Auto else {
            return consumeNumeric(&edges, slot, .length)
        }
        consumeIncludingWhitespace()
        edges.setSymbol(slot, WebCore.CSSValueID.Auto.rawValue)
        return true
    }

    // <'clip-path'> = none | <clip-source> | [ <basic-shape> || <geometry-box> ]
    // <clip-source> = <url>
    // https://drafts.fxtf.org/css-masking/#propdef-clip-path
    mutating func clipPath() -> PropertyValue? {
        if peekIdent() == .None {
            return consumeKeyword(peeked: .None)
        }
        if let url = consumeURLValue() {
            return url
        }
        var shape: PropertyValue? = nil
        var box: PropertyValue? = nil
        var boxID = WebCore.CSSValueID.Invalid
        while !atEnd {
            if shape == nil, let value = basicShape(rectOnly: false, rejectPathFillRule: false) {
                shape = value
                continue
            }
            if box == nil {
                let id = peekIdent()
                if let value = consumeGeometryBox() {
                    box = value
                    boxID = id
                    continue
                }
            }
            break
        }
        // border-box is the default.
        return makeShapeAndBox(shape, box, defaultBox: boxID == .BorderBox)
    }

    /// The list of `shape` and `box`, without `box` beside a shape if it is the default; nil if there is neither.
    private func makeShapeAndBox(_ shape: PropertyValue?, _ box: PropertyValue?, defaultBox: Bool) -> PropertyValue? {
        guard let shape else {
            guard let box else {
                return nil
            }
            return makeSpaceSeparatedList(box)
        }
        guard let box, !defaultBox else {
            return makeSpaceSeparatedList(shape)
        }
        return makeSpaceSeparatedList(shape, box)
    }

    // <'mask-border-source'> = none | <image>
    // https://drafts.csswg.org/css-masking-1/#propdef-mask-border-source
    mutating func maskBorderSource() -> PropertyValue? {
        guard let source = consumeBorderImageSource() else {
            return nil
        }
        return WebCore.makeMaskBorderLonghandValue(WebCore.CSSPropertyConsumerSwiftConsumer.MaskBorderSource.rawValue, WebCore.CSSColorSwiftComponents(), 0, source.image).get()
    }

    // <'mask-border-outset'> = [ <length [0,∞]> | <number [0,∞]> ]{1,4}
    // https://drafts.fxtf.org/css-masking-1/#propdef-mask-border-outset
    mutating func maskBorderOutset() -> PropertyValue? {
        var outset = WebCore.CSSColorSwiftComponents()
        guard consumeBorderImageOutset(&outset) else {
            return nil
        }
        return WebCore.makeMaskBorderLonghandValue(WebCore.CSSPropertyConsumerSwiftConsumer.MaskBorderOutset.rawValue, outset, 0, nil).get()
    }

    // <'mask-border-repeat'> = [ stretch | repeat | round | space ]{1,2}
    // https://drafts.fxtf.org/css-masking-1/#propdef-mask-border-repeat
    mutating func maskBorderRepeat() -> PropertyValue? {
        var rules = WebCore.CSSColorSwiftComponents()
        let count = consumeBorderImageRepeat(&rules)
        guard count != 0 else {
            return nil
        }
        return WebCore.makeMaskBorderLonghandValue(WebCore.CSSPropertyConsumerSwiftConsumer.MaskBorderRepeat.rawValue, rules, count, nil).get()
    }

    // <'mask-border-slice'> = [<number [0,∞]> | <percentage [0,∞]>]{1,4} && fill?, with the
    // CSSPropertyConsumerSwiftBorderImageSliceAlwaysFill option.
    // https://drafts.fxtf.org/css-masking-1/#propdef-mask-border-slice
    mutating func maskBorderSlice() -> PropertyValue? {
        var slice = WebCore.CSSColorSwiftComponents()
        var fill = WebCore.CSSColorSwiftComponents()
        guard consumeBorderImageSlice(&slice, &fill, alwaysFill: sliceAlwaysFill) else {
            return nil
        }
        return WebCore.makeMaskBorderLonghandValue(WebCore.CSSPropertyConsumerSwiftConsumer.MaskBorderSlice.rawValue, slice, fill.type(0) != 0 ? 1 : 0, nil).get()
    }

    // <'mask-border-width'> = [ <length-percentage [0,∞]> | <number [0,∞]> | auto ]{1,4}
    // https://drafts.fxtf.org/css-masking-1/#propdef-mask-border-width
    mutating func maskBorderWidth() -> PropertyValue? {
        var width = WebCore.CSSColorSwiftComponents()
        guard consumeBorderImageWidth(&width) else {
            return nil
        }
        return WebCore.makeMaskBorderLonghandValue(WebCore.CSSPropertyConsumerSwiftConsumer.MaskBorderWidth.rawValue, width, 0, nil).get()
    }

    // <'mask-border'> = <'mask-border-source'> || <'mask-border-slice'> [ / <'mask-border-width'>? [ / <'mask-border-outset'> ]? ]?
    //                || <'mask-border-repeat'>, to the end, with the CSSPropertyConsumerSwiftBorderImageSliceAlwaysFill option.
    // FIXME: Add support for `mask-border-mode`.
    // https://drafts.csswg.org/css-masking-1/#propdef-mask-border
    mutating func unresolvedMaskBorder() -> PropertyValue? {
        var parts = WebCore.CSSImageSwiftParts()
        guard consumeBorderImageParts(&parts, alwaysFill: sliceAlwaysFill) else {
            return nil
        }
        return makeMaskingValue(.UnresolvedMaskBorder, parts)
    }

    private func makeMaskingValue(_ consumer: WebCore.CSSPropertyConsumerSwiftConsumer, _ parts: consuming WebCore.CSSImageSwiftParts) -> PropertyValue? {
        WebCore.makeMaskingValue(tokens.value, consumer.rawValue, consuming: parts).get()
    }

    /// `consumeURL` with no modifiers: a url token or url(). Consumes nothing if there is no url.
    private mutating func consumeURLValue() -> PropertyValue? {
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
        guard let url = WebCore.makeURLValue(tokens.value, UInt32(truncatingIfNeeded: start), UInt32(truncatingIfNeeded: next)).get() else {
            return nil
        }
        index = next
        consumeWhitespace()
        return url
    }

    // MARK: - Motion

    // <'offset-path'> = none | [ <ray()> | <url> | <basic-shape> || <coord-box> ]
    // https://drafts.fxtf.org/motion-1/#propdef-offset-path
    mutating func offsetPath() -> PropertyValue? {
        if peekIdent() == .None {
            return consumeKeyword(peeked: .None)
        }
        // FIXME: It should be possible to consume both a <url> and <coord-box>.
        if let url = consumeURLValue() {
            return url
        }
        var shapeOrRay: PropertyValue? = nil
        var box: PropertyValue? = nil
        var boxID = WebCore.CSSValueID.Invalid
        while !atEnd {
            if shapeOrRay == nil {
                // A ray() that does not parse stays consumed, and the same pass goes on to the next token.
                if let value = ray() {
                    shapeOrRay = value
                    continue
                }
                if let value = basicShape(rectOnly: false, rejectPathFillRule: true) {
                    shapeOrRay = value
                    continue
                }
            }
            if box == nil {
                // FIXME: A <geometry-box>, which unlike the specification's <coord-box> includes margin-box; the
                // specification's examples use margin-box too. See https://github.com/w3c/fxtf-drafts/issues/481.
                let id = peekIdent()
                if let value = consumeGeometryBox() {
                    box = value
                    boxID = id
                    continue
                }
            }
            break
        }
        // border-box is the default.
        return makeShapeAndBox(shapeOrRay, box, defaultBox: boxID == .BorderBox)
    }

    // ray( <angle> && <ray-size>? && contain? && [at <position>]? )
    // <ray-size> = closest-side | closest-corner | farthest-side | farthest-corner | sides
    // https://drafts.fxtf.org/motion-1/#ray-function
    private mutating func ray() -> PropertyValue? {
        guard let function = beginFunction(.Ray) else {
            return nil
        }
        // The angle at 0, the size at 1 and contain at 2, each at most once.
        var ray = WebCore.CSSColorSwiftComponents()
        var position = WebCore.CSSColorSwiftComponents()
        var positionLayout = WebCore.CSSImageSwiftNoPosition
        var parsed = true
        while !atEnd {
            if ray.type(0) == 0 && consumeNumeric(&ray, 0, .strictAngle) {
                continue
            }
            let id = peekIdent()
            if ray.type(1) == 0 && (id == .ClosestSide || id == .ClosestCorner || id == .FarthestSide || id == .FarthestCorner || id == .Sides) {
                consumeIncludingWhitespace()
                ray.setSymbol(1, id.rawValue)
                continue
            }
            if ray.type(2) == 0 && id == .Contain {
                consumeIncludingWhitespace()
                ray.setSymbol(2, id.rawValue)
                continue
            }
            if positionLayout == WebCore.CSSImageSwiftNoPosition && id == .At {
                consumeIncludingWhitespace()
                if let layout = consumePosition(&position, maxComponents: 4, allowsThree: false) {
                    positionLayout = layout
                    continue
                }
            }
            parsed = false
            break
        }
        // The angle is the only argument required.
        let value: PropertyValue? = parsed && ray.type(0) != 0 ? WebCore.makeRayValue(ray, position, positionLayout).get() : nil
        // consumeRayFunction consumes the function whether or not it parses.
        endColorFunction(function, true)
        return value
    }
}

extension NumericComponent {
    /// `CSS::Angle<>` with unitless zero angles forbidden, as MetaConsumer reads one by default.
    static var strictAngle: Self { Self(type: angle.type, unitlessZeroAngle: false) }
}
