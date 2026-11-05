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

// The consumers of CSSPropertyParserConsumer+Grid.cpp: <grid-line>, grid-auto-flow, grid-template-areas and its rows,
// <line-names>, <track-size>, grid-auto-columns and grid-auto-rows, <explicit-track-list>, and grid-template-columns and
// grid-template-rows with their repeat()s and subgrid.
//
// Every grid value is a CSS:: value built in C++ from what Swift consumed (CSSGridSwiftParts and the grid builders of
// CSSPropertyConsumerSwiftBuilders.h). Like the C++, each consumer consumes nothing when it fails, which the
// grid-template shorthand relies on for its optional track size and line names; a row of grid-template-areas is the
// exception, its string stays consumed.

extension PropertyTokenType {
    static var leftBracket: UInt8 { UInt8(WebCore.LeftBracketToken.rawValue) }
    static var rightBracket: UInt8 { UInt8(WebCore.RightBracketToken.rawValue) }
}

extension WebCore.CSSGridSwiftParts {
    /// Empty parts, through the C++ constructor that Swift calls without zero-filling the object first.
    @inline(always)
    init() {
        self.init(0)
    }

    /// A part of `kind` (a CSSGridSwift kind) at the token `token`, if it has one.
    @inline(always)
    mutating func append(_ kind: UInt8, token: UInt32 = .max) {
        append(kind, token)
    }
}

/// A <grid-line>: its CSSGridSwiftLine kind, its index (1 if it has none), and its name, if it has one.
private typealias GridLineParts = (kind: UInt8, integer: (number: Double, calc: UInt32), name: UInt32?)

extension PropertyParser {
    // MARK: - <grid-line>

    /// `consumeUnresolvedCustomIdentForGridLine`: the index of the <custom-ident> at the next token, which is neither
    /// auto nor span, consumed with the whitespace after it; nil and nothing consumed if there is none.
    private mutating func gridLineName() -> UInt32? {
        let id = peekIdent()
        guard peekType() == PropertyTokenType.ident, WebCore.isValidCustomIdentifier(id), id != .Auto, id != .Span else {
            return nil
        }
        let token = UInt32(truncatingIfNeeded: index) // Below end, a token count.
        consumeIncludingWhitespace()
        return token
    }

    /// `MetaConsumer<CSS::Integer<R>>` for R = [min, ∞]: a number token whose value is an integer in R, or the
    /// calc() at the token `calc`, which the builder consumes again; nil and nothing consumed if there is none.
    mutating func integerOrCalc(min: Double, _ calc: PropertyCalc) -> (number: Double, calc: UInt32)? {
        let type = peekType()
        if type == PropertyTokenType.function {
            let token = UInt32(truncatingIfNeeded: index) // Below end, a token count.
            guard let numeric = numeric(PropertyPrimitive(.integer, min: min), calc), numeric.isCalculated else {
                return nil
            }
            return (0, token)
        }
        guard type == PropertyTokenType.number, tokens.value.isIntegerNumber(index) else {
            return nil
        }
        let value = tokens.value.numericValue(index)
        guard PropertyPrimitive(.integer, min: min).contains(value) else {
            return nil
        }
        consumeIncludingWhitespace()
        return (value, .max)
    }

    // <grid-line> = auto
    //             | <custom-ident>
    //             | [ [ <integer [-∞,-1]> | <integer [1,∞]> ] && <custom-ident>? ]
    //             | [ span && [ <integer [1,∞]> || <custom-ident> ] ]
    // https://drafts.csswg.org/css-grid/#typedef-grid-row-start-grid-line
    mutating func gridLine(unresolved: Bool, _ calc: PropertyCalc) -> PropertyValue? {
        let start = index
        guard let line = gridLineParts(calc) else {
            index = start
            return nil
        }
        let consumer: WebCore.CSSPropertyConsumerSwiftConsumer = unresolved ? .UnresolvedGridLine : .GridLine
        return WebCore.setGridLineResult(tokens.value, consumer.rawValue, line.kind, line.integer.number, line.integer.calc, line.name ?? .max).get()
    }

    /// The parts of a <grid-line>; nil if there is none.
    private mutating func gridLineParts(_ calc: PropertyCalc) -> GridLineParts? {
        let one = (number: 1.0, calc: UInt32.max)
        switch peekIdent() {
        case .Auto:
            consumeIncludingWhitespace()
            return (UInt8(WebCore.CSSGridSwiftLineAuto), one, nil)
        case .Span:
            // The integer before or after the name.
            consumeIncludingWhitespace()
            var integer = integerOrCalc(min: 1, calc)
            let name = gridLineName()
            if integer == nil {
                integer = integerOrCalc(min: 1, calc)
            }
            guard integer != nil || name != nil else {
                return nil
            }
            return (UInt8(WebCore.CSSGridSwiftLineSpan), integer ?? one, name)
        default:
            break
        }

        if let integer = integerOrCalc(min: -.infinity, calc) {
            let name = gridLineName()
            return gridLineAfterIndex(integer, name)
        }

        guard let name = gridLineName() else {
            return nil
        }
        guard let integer = integerOrCalc(min: -.infinity, calc) else {
            if peekIdent() == .Span {
                consumeIncludingWhitespace()
                return (UInt8(WebCore.CSSGridSwiftLineSpan), one, name)
            }
            return (UInt8(WebCore.CSSGridSwiftLineCustomIdent), one, name)
        }
        return gridLineAfterIndex(integer, name)
    }

    /// An index and a name or none, then span or nothing: a span of the index narrowed to [1, ∞] (a calc() always
    /// narrows), or a line other than 0.
    private mutating func gridLineAfterIndex(_ integer: (number: Double, calc: UInt32), _ name: UInt32?) -> GridLineParts? {
        if peekIdent() == .Span {
            consumeIncludingWhitespace()
            guard integer.calc != .max || integer.number >= 1 else {
                return nil
            }
            return (UInt8(WebCore.CSSGridSwiftLineSpanOfInteger), integer, name)
        }
        // isKnownZero: a calc() is never known to be zero.
        guard integer.calc != .max || integer.number != 0 else {
            return nil
        }
        return (UInt8(WebCore.CSSGridSwiftLineExplicit), integer, name)
    }

    // MARK: - grid-auto-flow

    // <'grid-auto-flow'> = normal | [ [ row | column ] || dense ]
    // https://drafts.csswg.org/css-grid/#propdef-grid-auto-flow
    mutating func gridAutoFlow() -> PropertyValue? {
        var direction = peekIdent()
        var dense = false
        switch direction {
        case .Normal:
            consumeIncludingWhitespace()
        case .Row, .Column:
            consumeIncludingWhitespace()
            if peekIdent() == .Dense {
                consumeIncludingWhitespace()
                dense = true
            }
        case .Dense:
            consumeIncludingWhitespace()
            dense = true
            direction = peekIdent()
            if direction == .Row || direction == .Column {
                consumeIncludingWhitespace()
            } else {
                direction = .Invalid
            }
        default:
            return nil
        }
        typealias Keyword = WebCore.CSS.Keyword
        let flow: WebCore.CSS.GridAutoFlow = switch (direction, dense) {
        case (.Normal, _): .init(Keyword.Normal())
        case (.Row, false): .init(Keyword.Row())
        case (.Row, true): .init(Keyword.Row(), Keyword.Dense())
        case (.Column, false): .init(Keyword.Column())
        case (.Column, true): .init(Keyword.Column(), Keyword.Dense())
        default: .init(Keyword.Dense()) // dense alone.
        }
        return WebCore.CSSGridAutoFlowValue.create(flow).get()
    }

    // MARK: - grid-template-areas

    // <'grid-template-areas'> = none | <string>+
    // https://drafts.csswg.org/css-grid/#propdef-grid-template-areas
    mutating func gridTemplateAreas() -> PropertyValue? {
        if peekIdent() == .None {
            return consumeKeyword(peeked: .None)
        }
        let start = index
        var parts = WebCore.CSSGridSwiftParts()
        repeat {
            guard gridAreaRow(&parts) else {
                index = start
                return nil
            }
        } while peekType() == PropertyTokenType.string
        // CSS::addRow, in C++, checks that each name's cells make a rectangle.
        let consumer = WebCore.CSSPropertyConsumerSwiftConsumer.GridTemplateAreas
        guard let value = WebCore.setGridResult(tokens.value, consumer.rawValue, consuming: consume parts).get() else {
            index = start
            return nil
        }
        return value
    }

    /// `consumeUnresolvedGridTemplateAreasRow`: a row whose string is invalid stays consumed.
    mutating func unresolvedGridTemplateAreasRow() -> PropertyValue? {
        var parts = WebCore.CSSGridSwiftParts()
        guard gridAreaRow(&parts) else {
            return nil
        }
        let consumer = WebCore.CSSPropertyConsumerSwiftConsumer.UnresolvedGridTemplateAreasRow
        _ = WebCore.setGridResult(tokens.value, consumer.rawValue, consuming: consume parts)
        return nil
    }

    /// Appends the names of the row of grid-template-areas at the next token, a string, consumed with the whitespace
    /// after it, and its end. False if it is not a string (nothing consumed) or not a row: empty, white space alone, or
    /// a character that is neither white space, `.` nor a name code point.
    /// https://drafts.csswg.org/css-grid/#valdef-grid-template-areas-string
    private mutating func gridAreaRow(_ parts: inout WebCore.CSSGridSwiftParts) -> Bool {
        guard peekType() == PropertyTokenType.string else {
            return false
        }
        let token = index
        consumeIncludingWhitespace()
        let token32 = UInt32(truncatingIfNeeded: token) // Below end, a token count.
        var length = tokens.value.textLength(token)
        if length == .max {
            length = 0 // A null string, as the empty one.
        }
        // A name is the characters [nameStart, nameStart + nameLength); a run of `.`s is the name ".".
        var nameStart: UInt32 = 0
        var nameLength: UInt32 = 0
        var isDot = false
        var names = 0
        var i: UInt32 = 0
        while i < length {
            let c = tokens.value.textCharacter(token, i)
            if isCSSSpace(c) {
                if nameLength != 0 {
                    parts.appendAreaName(token32, nameStart, nameLength)
                    names &+= 1 // At most the string's length.
                }
                nameLength = 0
                isDot = false
            } else if c == 0x2E {
                if !isDot {
                    if nameLength != 0 {
                        parts.appendAreaName(token32, nameStart, nameLength)
                        names &+= 1 // At most the string's length.
                    }
                    nameStart = i
                    nameLength = 1
                    isDot = true
                }
            } else {
                guard isNameCodePoint(c) else {
                    return false
                }
                if isDot {
                    parts.appendAreaName(token32, nameStart, 1)
                    names &+= 1 // At most the string's length.
                    nameLength = 0
                    isDot = false
                }
                if nameLength == 0 {
                    nameStart = i
                }
                nameLength &+= 1 // At most the string's length.
            }
            i &+= 1 // Below length.
        }
        if nameLength != 0 {
            parts.appendAreaName(token32, nameStart, nameLength)
            names &+= 1 // At most the string's length.
        }
        // A row of white space alone, or empty, has no name.
        guard names != 0 else {
            return false
        }
        parts.append(UInt8(WebCore.CSSGridSwiftAreaRowEnd))
        return true
    }

    /// `isCSSSpace` (CSSParserIdioms.h): space, tab and newline.
    private func isCSSSpace(_ c: UInt16) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A
    }

    /// `isNameCodePoint` (CSSParserIdioms.h): an ASCII letter or digit, `_`, `-`, or any code unit that is not ASCII.
    private func isNameCodePoint(_ c: UInt16) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2D || c >= 0x80
    }

    // MARK: - <line-names>

    // <line-names> = '[' <custom-ident excluding=span,auto>* ']'
    // https://drafts.csswg.org/css-grid/#typedef-line-names
    mutating func unresolvedGridLineNames() -> PropertyValue? {
        var parts = WebCore.CSSGridSwiftParts()
        guard gridLineNames(&parts) else {
            return nil
        }
        let consumer = WebCore.CSSPropertyConsumerSwiftConsumer.UnresolvedGridLineNames
        _ = WebCore.setGridResult(tokens.value, consumer.rawValue, consuming: consume parts)
        return nil
    }

    /// Appends the <line-names> at the next token; false and nothing consumed or appended if there are none.
    private mutating func gridLineNames(_ parts: inout WebCore.CSSGridSwiftParts) -> Bool {
        guard peekType() == PropertyTokenType.leftBracket else {
            return false
        }
        let start = index
        let mark = parts.size()
        consumeIncludingWhitespace()
        parts.append(UInt8(WebCore.CSSGridSwiftLineNames))
        while let name = gridLineName() {
            parts.append(UInt8(WebCore.CSSGridSwiftLineName), token: name)
        }
        guard peekType() == PropertyTokenType.rightBracket else {
            index = start
            parts.shrink(mark)
            return false
        }
        consumeIncludingWhitespace()
        parts.append(UInt8(WebCore.CSSGridSwiftLineNamesEnd))
        return true
    }

    /// <line-names> in a track list, which drops an empty `[]`; a list goes on after none.
    private mutating func gridLineNamesInList(_ parts: inout WebCore.CSSGridSwiftParts) {
        let mark = parts.size()
        if gridLineNames(&parts) && parts.size() == mark &+ 2 { // At most the parts appended, two here.
            parts.shrink(mark)
        }
    }

    // MARK: - <track-size>

    /// Appends the <track-breadth> (with `flex`) or <inflexible-breadth> at the next token, and returns whether it is
    /// not a <fixed-breadth>; nil and nothing consumed or appended if there is none.
    ///
    /// <track-breadth>      = <length-percentage [0,∞]> | <flex [0,∞]> | min-content | max-content | auto
    /// <inflexible-breadth> = <length-percentage [0,∞]> | min-content | max-content | auto
    /// https://drafts.csswg.org/css-grid/#typedef-track-breadth
    private mutating func gridBreadth(_ parts: inout WebCore.CSSGridSwiftParts, flex: Bool, _ calc: PropertyCalc) -> Bool? {
        var keyword = peekIdent()
        switch keyword {
        case .MinContent, .WebkitMinContent:
            keyword = .MinContent
        case .MaxContent, .WebkitMaxContent:
            keyword = .MaxContent
        case .Auto:
            break
        default:
            keyword = .Invalid
        }
        if keyword != .Invalid {
            consumeIncludingWhitespace()
            parts.appendKeyword(UInt8(WebCore.CSSGridSwiftBreadthKeyword), keyword.rawValue)
            return true
        }
        // A <flex> is tried before a <length-percentage>, which parses a calc() that is not a <flex> again.
        if flex, gridFlex(&parts, calc) {
            return true
        }
        var components = WebCore.CSSColorSwiftComponents()
        guard consumeNumeric(&components, 0, .nonnegativeLengthPercentage) else {
            return nil
        }
        parts.appendLengthPercentage(components, 0)
        return false
    }

    /// `MetaConsumer<CSS::Flex<CSS::Nonnegative>>`: a dimension token of a flex unit whose value is finite and
    /// non-negative, or a math function that is a <flex [0,∞]>, which the builder consumes again.
    private mutating func gridFlex(_ parts: inout WebCore.CSSGridSwiftParts, _ calc: PropertyCalc) -> Bool {
        let type = peekType()
        if type == PropertyTokenType.dimension {
            let value = tokens.value.numericValue(index)
            guard let unit = WebCore.CSSUnitType(rawValue: tokens.value.unitType(index)), WebCore.CSS.toFlexUnit(unit).value != nil,
                !value.isInfinite, value >= 0
            else {
                return false
            }
            consumeIncludingWhitespace()
            parts.appendFlex(value, .max)
            return true
        }
        guard type == PropertyTokenType.function else {
            return false
        }
        let identifier = tokens.value.identifier(index)
        guard cssCalcIsMathFunction(identifier), let function = beginFunction(peekFunction()) else {
            return false
        }
        // The flags calcNumeric passes by default.
        let primitive = PropertyCalcPrimitive(category: .Flex, min: 0, max: .infinity, flags: UInt32(WebCore.CSSCalcParseAllowUnitlessZeroLength))
        let consumed = calc(index..<end, identifier, primitive) != nil
        endColorFunction(function, consumed)
        if consumed {
            parts.appendFlex(0, UInt32(truncatingIfNeeded: function.start)) // Below end, a token count.
        }
        return consumed
    }

    /// Appends the <track-size> at the next token, and returns whether it is not a <fixed-size>; nil and nothing
    /// consumed or appended if there is none. minmax() is not fixed only if both of its breadths are not.
    ///
    /// <track-size> = <track-breadth> | minmax( <inflexible-breadth> , <track-breadth> ) | fit-content( <length-percentage [0,∞]> )
    /// https://drafts.csswg.org/css-grid/#typedef-track-size
    private mutating func gridTrackSize(_ parts: inout WebCore.CSSGridSwiftParts, _ calc: PropertyCalc) -> Bool? {
        if let nonFixed = gridBreadth(&parts, flex: true, calc) {
            return nonFixed
        }
        switch peekFunction() {
        case .FitContent:
            guard let function = beginFunction(.FitContent) else {
                return nil
            }
            var components = WebCore.CSSColorSwiftComponents()
            let consumed = consumeNumeric(&components, 0, .nonnegativeLengthPercentage) && atEnd
            endColorFunction(function, consumed)
            guard consumed else {
                return nil
            }
            parts.append(UInt8(WebCore.CSSGridSwiftFitContent))
            parts.appendLengthPercentage(components, 0)
            return true
        case .Minmax:
            guard let function = beginFunction(.Minmax) else {
                return nil
            }
            let mark = parts.size()
            parts.append(UInt8(WebCore.CSSGridSwiftMinMax))
            var nonFixed: Bool? = nil
            if let min = gridBreadth(&parts, flex: false, calc), consumeComma(), let max = gridBreadth(&parts, flex: true, calc), atEnd {
                nonFixed = min && max
            }
            endColorFunction(function, nonFixed != nil)
            if nonFixed == nil {
                parts.shrink(mark)
            }
            return nonFixed
        default:
            return nil
        }
    }

    // <track-size>, for the grid shorthands.
    mutating func unresolvedGridTrackSize(_ calc: PropertyCalc) -> PropertyValue? {
        var parts = WebCore.CSSGridSwiftParts()
        guard gridTrackSize(&parts, calc) != nil else {
            return nil
        }
        let consumer = WebCore.CSSPropertyConsumerSwiftConsumer.UnresolvedGridTrackSize
        _ = WebCore.setGridResult(tokens.value, consumer.rawValue, consuming: consume parts)
        return nil
    }

    // MARK: - grid-auto-columns, grid-auto-rows

    // <'grid-auto-columns'>/<'grid-auto-rows'> = <track-size>+
    // https://drafts.csswg.org/css-grid/#propdef-grid-auto-columns
    // https://drafts.csswg.org/css-grid/#propdef-grid-auto-rows
    mutating func gridTrackSizes(_ calc: PropertyCalc) -> PropertyValue? {
        let start = index
        var parts = WebCore.CSSGridSwiftParts()
        repeat {
            guard gridTrackSize(&parts, calc) != nil else {
                index = start
                return nil
            }
        } while !atEnd && peekType() != PropertyTokenType.delimiter
        let consumer = WebCore.CSSPropertyConsumerSwiftConsumer.GridTrackSizes
        return WebCore.setGridResult(tokens.value, consumer.rawValue, consuming: consume parts).get()
    }

    // MARK: - <explicit-track-list>

    // <explicit-track-list> = [ <line-names>? <track-size> ]+ <line-names>?
    // https://drafts.csswg.org/css-grid-2/#typedef-explicit-track-list
    mutating func unresolvedGridExplicitTrackList(_ calc: PropertyCalc) -> PropertyValue? {
        let start = index
        var parts = WebCore.CSSGridSwiftParts()
        gridLineNamesInList(&parts)
        repeat {
            guard gridTrackSize(&parts, calc) != nil else {
                index = start
                return nil
            }
            gridLineNamesInList(&parts)
        } while !atEnd && peekType() != PropertyTokenType.delimiter
        let consumer = WebCore.CSSPropertyConsumerSwiftConsumer.UnresolvedGridExplicitTrackList
        _ = WebCore.setGridResult(tokens.value, consumer.rawValue, consuming: consume parts)
        return nil
    }

    // MARK: - grid-template-columns, grid-template-rows

    // <'grid-template-columns'/'grid-template-rows'> = none | <track-list> | <auto-track-list> | subgrid <line-name-list>?
    // <track-list>      = [ <line-names>? [ <track-size> | <track-repeat> ] ]+ <line-names>?
    // <auto-track-list> = [ <line-names>? [ <fixed-size> | <fixed-repeat> ] ]* <line-names>? <auto-repeat>
    //                     [ <line-names>? [ <fixed-size> | <fixed-repeat> ] ]* <line-names>?
    // https://drafts.csswg.org/css-grid/#propdef-grid-template-columns
    // https://drafts.csswg.org/css-grid/#propdef-grid-template-rows
    mutating func gridTemplateList(_ calc: PropertyCalc) -> PropertyValue? {
        switch peekIdent() {
        case .None:
            return consumeKeyword(peeked: .None)
        case .Subgrid:
            return gridSubgrid(calc)
        default:
            break
        }
        let start = index
        var parts = WebCore.CSSGridSwiftParts()
        // At most one <auto-repeat>, and then only <fixed-size>s.
        var nonFixed = false
        var autoRepeat = false
        gridLineNamesInList(&parts)
        repeat {
            if peekFunction() == .Repeat {
                guard let repeated = gridTrackRepeat(&parts, calc), !(repeated.autoRepeat && autoRepeat) else {
                    index = start
                    return nil
                }
                autoRepeat = autoRepeat || repeated.autoRepeat
                nonFixed = nonFixed || repeated.nonFixed
            } else {
                guard let trackNonFixed = gridTrackSize(&parts, calc) else {
                    index = start
                    return nil
                }
                nonFixed = nonFixed || trackNonFixed
            }
            gridLineNamesInList(&parts)
        } while !atEnd && peekType() != PropertyTokenType.delimiter
        guard !(autoRepeat && nonFixed) else {
            index = start
            return nil
        }
        let consumer = WebCore.CSSPropertyConsumerSwiftConsumer.GridTemplateList
        return WebCore.setGridResult(tokens.value, consumer.rawValue, consuming: consume parts).get()
    }

    /// Appends the repeat() at the next token, and returns whether one of its track sizes is not a <fixed-size> and
    /// whether it is an <auto-repeat>; nil and nothing consumed or appended if there is none.
    ///
    /// <track-repeat> = repeat( [ <integer [1,∞]> ] , [ <line-names>? <track-size> ]+ <line-names>? )
    /// <auto-repeat>  = repeat( [ auto-fill | auto-fit ] , [ <line-names>? <fixed-size> ]+ <line-names>? )
    /// <fixed-repeat> = repeat( [ <integer [1,∞]> ] , [ <line-names>? <fixed-size> ]+ <line-names>? )
    /// https://drafts.csswg.org/css-grid/#repeat-syntax
    private mutating func gridTrackRepeat(_ parts: inout WebCore.CSSGridSwiftParts, _ calc: PropertyCalc) -> (nonFixed: Bool, autoRepeat: Bool)? {
        guard let function = beginFunction(.Repeat) else {
            return nil
        }
        let mark = parts.size()
        let repeated = gridTrackRepeatArguments(&parts, calc)
        if repeated == nil {
            parts.shrink(mark)
        }
        endColorFunction(function, repeated != nil)
        return repeated
    }

    /// The arguments of gridTrackRepeat's repeat(), all of them consumed.
    private mutating func gridTrackRepeatArguments(_ parts: inout WebCore.CSSGridSwiftParts, _ calc: PropertyCalc) -> (nonFixed: Bool, autoRepeat: Bool)? {
        var keyword = peekIdent()
        var count = (number: 0.0, calc: UInt32.max)
        if keyword == .AutoFill || keyword == .AutoFit {
            consumeIncludingWhitespace()
        } else {
            keyword = .Invalid
            guard let integer = integerOrCalc(min: 1, calc) else {
                return nil
            }
            count = integer
        }
        guard consumeComma() else {
            return nil
        }
        parts.appendRepeat(UInt8(WebCore.CSSGridSwiftRepeat), keyword.rawValue, count.number, count.calc)
        gridLineNamesInList(&parts)
        // The builder clamps a count to GridPosition::max() over the number of track sizes.
        var hasTrackSize = false
        var nonFixed = false
        while !atEnd {
            guard let trackNonFixed = gridTrackSize(&parts, calc) else {
                return nil
            }
            hasTrackSize = true
            nonFixed = nonFixed || trackNonFixed
            gridLineNamesInList(&parts)
        }
        guard hasTrackSize else {
            return nil
        }
        parts.append(UInt8(WebCore.CSSGridSwiftRepeatEnd))
        return (nonFixed, keyword != .Invalid)
    }

    /// `subgrid <line-name-list>?` at the next token, subgrid; nil and nothing consumed if it is not one. An empty
    /// <line-names> is kept, and at most one repeat() is of auto-fill.
    ///
    /// <line-name-list> = [ <line-names> | <name-repeat> ]+
    /// https://drafts.csswg.org/css-grid-2/#typedef-line-name-list
    private mutating func gridSubgrid(_ calc: PropertyCalc) -> PropertyValue? {
        let start = index
        consumeIncludingWhitespace()
        var parts = WebCore.CSSGridSwiftParts()
        parts.append(UInt8(WebCore.CSSGridSwiftSubgrid))
        var autoRepeat = false
        while !atEnd && peekType() != PropertyTokenType.delimiter {
            if peekFunction() == .Repeat {
                guard let isAutoFill = gridNameRepeat(&parts, calc), !(isAutoFill && autoRepeat) else {
                    index = start
                    return nil
                }
                autoRepeat = autoRepeat || isAutoFill
            } else {
                guard gridLineNames(&parts) else {
                    index = start
                    return nil
                }
            }
        }
        let consumer = WebCore.CSSPropertyConsumerSwiftConsumer.GridTemplateList
        return WebCore.setGridResult(tokens.value, consumer.rawValue, consuming: consume parts).get()
    }

    /// Appends the <name-repeat> at the next token, and returns whether it is of auto-fill; nil and nothing consumed
    /// or appended if there is none. Its empty <line-names> are kept.
    ///
    /// <name-repeat> = repeat( [ <integer [1,∞]> | auto-fill ], <line-names>+)
    /// https://drafts.csswg.org/css-grid-2/#typedef-name-repeat
    private mutating func gridNameRepeat(_ parts: inout WebCore.CSSGridSwiftParts, _ calc: PropertyCalc) -> Bool? {
        guard let function = beginFunction(.Repeat) else {
            return nil
        }
        let mark = parts.size()
        let isAutoFill = gridNameRepeatArguments(&parts, calc)
        if isAutoFill == nil {
            parts.shrink(mark)
        }
        endColorFunction(function, isAutoFill != nil)
        return isAutoFill
    }

    /// The arguments of gridNameRepeat's repeat(), all of them consumed.
    private mutating func gridNameRepeatArguments(_ parts: inout WebCore.CSSGridSwiftParts, _ calc: PropertyCalc) -> Bool? {
        let isAutoFill = peekIdent() == .AutoFill
        var count = (number: 0.0, calc: UInt32.max)
        if isAutoFill {
            consumeIncludingWhitespace()
        } else {
            guard let integer = integerOrCalc(min: 1, calc) else {
                return nil
            }
            count = integer
        }
        guard consumeComma() else {
            return nil
        }
        let keyword: WebCore.CSSValueID = isAutoFill ? .AutoFill : .Invalid
        parts.appendRepeat(UInt8(WebCore.CSSGridSwiftNameRepeat), keyword.rawValue, count.number, count.calc)
        repeat {
            guard gridLineNames(&parts) else {
                return nil
            }
        } while !atEnd
        parts.append(UInt8(WebCore.CSSGridSwiftRepeatEnd))
        return isAutoFill
    }
}
