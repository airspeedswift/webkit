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

// The consumers of CSSPropertyParserConsumer+Align.cpp and +Display.cpp: align-content, justify-content, align-self,
// justify-self, align-items, justify-items and display.

extension PropertyParser {
    // MARK: - Alignment

    /// `baseline`, the next token.
    private mutating func alignmentBaseline() -> PropertyValue? {
        // FIXME: The spec states that <baseline-position> is defined as `<baseline-position> = [ first | last ]? && baseline`,
        // allowing any ordering, but tests expect `[ first | last ]` to always precede `baseline`.
        consumeKeyword(peeked: .Baseline)
    }

    /// `first baseline`, which is `baseline`, at the next token, `first`. Consumes nothing if `baseline` does not follow.
    private mutating func alignmentFirstBaseline() -> PropertyValue? {
        let start = index
        consumeIncludingWhitespace()
        guard peekIdent() == .Baseline else {
            index = start
            return nil
        }
        consumeIncludingWhitespace()
        return keywordValue(.Baseline)
    }

    /// `last baseline` at the next token, `last`. Consumes nothing if `baseline` does not follow.
    private mutating func alignmentLastBaseline() -> PropertyValue? {
        let start = index
        consumeIncludingWhitespace()
        guard peekIdent() == .Baseline else {
            index = start
            return nil
        }
        consumeIncludingWhitespace()
        return makePair(keywordValue(.Last), keywordValue(.Baseline), coalescing: true)
    }

    /// Whether `id` follows `safe` or `unsafe`: a <content-position>, with `selfPositions` a <self-position> or
    /// `normal`, and with `leftAndRight` also `left` or `right`.
    @inline(always)
    private func isAlignmentOverflowPosition(_ id: WebCore.CSSValueID, selfPositions: Bool, leftAndRight: Bool) -> Bool {
        switch id {
        case .Start, .End, .Center, .FlexStart, .FlexEnd:
            return true
        case .Normal, .AnchorCenter, .SelfStart, .SelfEnd:
            return selfPositions
        case .Left, .Right:
            return leftAndRight
        default:
            return false
        }
    }

    /// <overflow-position> and the position after it, at the next token, `safe` or `unsafe` (`safety`). Consumes nothing
    /// if no position that `isAlignmentOverflowPosition` allows follows.
    @inline(always)
    private mutating func alignmentOverflowPosition(
        _ safety: WebCore.CSSValueID,
        selfPositions: Bool,
        leftAndRight: Bool
    ) -> PropertyValue? {
        let start = index
        consumeIncludingWhitespace()
        let position = peekIdent()
        guard isAlignmentOverflowPosition(position, selfPositions: selfPositions, leftAndRight: leftAndRight) else {
            index = start
            return nil
        }
        consumeIncludingWhitespace()
        return makePair(keywordValue(safety), keywordValue(position), coalescing: true)
    }

    // <'align-content'> = normal | <baseline-position> | <content-distribution> | <overflow-position>? <content-position>
    // https://drafts.csswg.org/css-align/#propdef-align-content
    mutating func alignContent() -> PropertyValue? {
        let initial = peekIdent()
        switch initial {
        case .Normal, .SpaceBetween, .SpaceAround, .SpaceEvenly, .Stretch, .Start, .End, .Center, .FlexStart, .FlexEnd:
            return consumeKeyword(peeked: initial)
        case .First:
            return alignmentFirstBaseline()
        case .Last:
            return alignmentLastBaseline()
        case .Baseline:
            return alignmentBaseline()
        case .Unsafe, .Safe:
            return alignmentOverflowPosition(initial, selfPositions: false, leftAndRight: false)
        default:
            return nil
        }
    }

    // <'justify-content'> = normal | <content-distribution> | <overflow-position>? [ <content-position> | left | right ]
    // https://drafts.csswg.org/css-align/#propdef-justify-content
    mutating func justifyContent() -> PropertyValue? {
        let initial = peekIdent()
        switch initial {
        case .Normal, .SpaceBetween, .SpaceAround, .SpaceEvenly, .Stretch, .Start, .End, .Center, .FlexStart, .FlexEnd, .Left,
            .Right:
            return consumeKeyword(peeked: initial)
        case .Unsafe, .Safe:
            return alignmentOverflowPosition(initial, selfPositions: false, leftAndRight: true)
        default:
            return nil
        }
    }

    // <'align-self'> = auto | <overflow-position>? normal | stretch | <baseline-position> | <overflow-position>? <self-position>
    // https://drafts.csswg.org/css-align/#propdef-align-self
    mutating func alignSelf() -> PropertyValue? {
        let initial = peekIdent()
        switch initial {
        case .Auto, .Normal, .Stretch, .AnchorCenter, .Start, .End, .Center, .SelfStart, .SelfEnd, .FlexStart, .FlexEnd:
            return consumeKeyword(peeked: initial)
        case .First:
            return alignmentFirstBaseline()
        case .Last:
            return alignmentLastBaseline()
        case .Baseline:
            return alignmentBaseline()
        case .Unsafe, .Safe:
            return alignmentOverflowPosition(initial, selfPositions: true, leftAndRight: false)
        default:
            return nil
        }
    }

    // <'justify-self'> = auto | <overflow-position>? normal | stretch | <baseline-position> | <overflow-position>? [ <self-position> | left | right ]
    // https://drafts.csswg.org/css-align/#propdef-justify-self
    mutating func justifySelf() -> PropertyValue? {
        let initial = peekIdent()
        switch initial {
        case .Auto, .Normal, .Stretch, .AnchorCenter, .Start, .End, .Center, .SelfStart, .SelfEnd, .FlexStart, .FlexEnd, .Left,
            .Right:
            return consumeKeyword(peeked: initial)
        case .First:
            return alignmentFirstBaseline()
        case .Last:
            return alignmentLastBaseline()
        case .Baseline:
            return alignmentBaseline()
        case .Unsafe, .Safe:
            return alignmentOverflowPosition(initial, selfPositions: true, leftAndRight: true)
        default:
            return nil
        }
    }

    // <'align-items'> = <overflow-position>? normal | stretch | <baseline-position> | <overflow-position>? <self-position>
    // https://drafts.csswg.org/css-align/#propdef-align-items
    mutating func alignItems() -> PropertyValue? {
        let initial = peekIdent()
        switch initial {
        case .Normal, .Stretch, .AnchorCenter, .Start, .End, .Center, .SelfStart, .SelfEnd, .FlexStart, .FlexEnd:
            return consumeKeyword(peeked: initial)
        case .First:
            return alignmentFirstBaseline()
        case .Last:
            return alignmentLastBaseline()
        case .Baseline:
            return alignmentBaseline()
        case .Unsafe, .Safe:
            return alignmentOverflowPosition(initial, selfPositions: true, leftAndRight: false)
        default:
            return nil
        }
    }

    // <'justify-items'> = <overflow-position>? normal | stretch | <baseline-position> | <overflow-position>? [ <self-position> | left | right ] | legacy | legacy && [ left | right | center ]
    // https://drafts.csswg.org/css-align/#propdef-justify-items
    mutating func justifyItems() -> PropertyValue? {
        let initial = peekIdent()
        switch initial {
        // `left`, `right` and `center` are below, for the `legacy` that may follow them.
        case .Normal, .Stretch, .AnchorCenter, .Start, .End, .SelfStart, .SelfEnd, .FlexStart, .FlexEnd:
            return consumeKeyword(peeked: initial)
        case .First:
            return alignmentFirstBaseline()
        case .Last:
            return alignmentLastBaseline()
        case .Baseline:
            return alignmentBaseline()
        case .Unsafe, .Safe:
            return alignmentOverflowPosition(initial, selfPositions: true, leftAndRight: true)
        case .Legacy:
            consumeIncludingWhitespace()
            let second = peekIdent()
            switch second {
            case .Left, .Right, .Center:
                consumeIncludingWhitespace()
                return makePair(keywordValue(initial), keywordValue(second), coalescing: true)
            default:
                return keywordValue(initial)
            }
        case .Center, .Left, .Right:
            consumeIncludingWhitespace()
            guard peekIdent() == .Legacy else {
                return keywordValue(initial)
            }
            consumeIncludingWhitespace()
            // `legacy` first, as it serializes.
            return makePair(keywordValue(.Legacy), keywordValue(initial), coalescing: true)
        default:
            return nil
        }
    }

    // MARK: - Display

    /// The value of <display-outside> `outside` (`block`, `inline`, or Invalid for none) with <display-inside> `inside`
    /// (`flow`, `flow-root`, `table`, `flex`, `grid`, `grid-lanes`, `ruby`, or Invalid for none), in its shortest form:
    /// `inline <display-inside>` is `inline-<display-inside>` but for `inline`, `inline flow` (`inline`),
    /// `inline flow-root` (`inline-block`) and `inline ruby` (`ruby`); `block <display-inside>` and `<display-inside>`
    /// alone are `<display-inside>` but for `block`, `block flow` and `flow` (`block`), `block ruby` (not shortened) and
    /// `ruby` (`ruby`). Nil for neither.
    private func displayValue(outside: WebCore.CSSValueID, inside: WebCore.CSSValueID) -> PropertyValue? {
        if outside == .Inline {
            switch inside {
            case .FlowRoot: return keywordValue(.InlineBlock)
            case .Table: return keywordValue(.InlineTable)
            case .Flex: return keywordValue(.InlineFlex)
            case .Grid: return keywordValue(.InlineGrid)
            case .GridLanes: return keywordValue(.InlineGridLanes)
            case .Ruby: return keywordValue(.Ruby)
            default: return keywordValue(.Inline)
            }
        }
        switch inside {
        case .Invalid:
            return outside == .Block ? keywordValue(.Block) : nil
        case .Flow:
            return keywordValue(.Block)
        case .Ruby:
            return outside == .Block ? makePair(keywordValue(.Block), keywordValue(.Ruby), coalescing: false) : keywordValue(.Ruby)
        default:
            return keywordValue(inside)
        }
    }

    private func gridLanesEnabled() -> Bool {
        contextEnables(UInt32(WebCore.CSSConsumerSwiftGridLanesEnabled))
    }

    private func rubyDisplayTypesEnabled() -> Bool {
        contextEnables(UInt32(WebCore.CSSConsumerSwiftRubyDisplayTypesEnabled))
    }

    /// The display value after the next token, <display-outside> `outside`. Consumes nothing if what follows is a
    /// keyword that is not a <display-inside> the context allows.
    private mutating func displayAfterOutside(_ outside: WebCore.CSSValueID) -> PropertyValue? {
        let start = index
        consumeIncludingWhitespace()
        let inside = peekIdent()
        switch inside {
        case .Flow, .FlowRoot, .Table, .Flex, .Grid:
            break
        case .GridLanes:
            guard gridLanesEnabled() else {
                index = start
                return nil
            }
        case .Ruby:
            guard rubyDisplayTypesEnabled() else {
                index = start
                return nil
            }
        case .Invalid:
            return displayValue(outside: outside, inside: .Invalid)
        default:
            index = start
            return nil
        }
        consumeIncludingWhitespace()
        return displayValue(outside: outside, inside: inside)
    }

    /// The display value after the next token, <display-inside> `inside`. Consumes nothing if what follows is a keyword
    /// that is not a <display-outside>.
    private mutating func displayAfterInside(_ inside: WebCore.CSSValueID) -> PropertyValue? {
        let start = index
        consumeIncludingWhitespace()
        let outside = peekIdent()
        switch outside {
        case .Block, .Inline:
            consumeIncludingWhitespace()
            return displayValue(outside: outside, inside: inside)
        case .Invalid:
            return displayValue(outside: .Invalid, inside: inside)
        default:
            index = start
            return nil
        }
    }

    // Keep in sync with the single keyword value fast path of CSSParserFastPaths's parseDisplay.
    // <'display'>        = [ <display-outside> || <display-inside> ] | <display-listitem> | <display-internal> | <display-box> | <display-legacy> | <display-non-standard>
    // <display-outside>  = block | inline | run-in
    // <display-inside>   = flow | flow-root | table | flex | grid | grid-lanes | ruby
    // <display-listitem> = <display-outside>? && [ flow | flow-root ]? && list-item
    // <display-internal> = table-row-group | table-header-group |
    //                      table-footer-group | table-row | table-cell |
    //                      table-column-group | table-column | table-caption |
    //                      ruby-base | ruby-text | ruby-base-container |
    //                      ruby-text-container
    // <display-box>      = contents | none
    // <display-legacy>   = inline-block | inline-table | inline-flex | inline-grid | inline-grid-lanes
    // <display-non-standard> = -webkit-box | -webkit-inline-box | -webkit-flex | -webkit-inline-flex
    // https://drafts.csswg.org/css-display/#propdef-display
    //  and
    // https://drafts.csswg.org/css-grid-3/#grid-lanes-containers (for additions of grid-lanes and inline-grid-lanes)
    mutating func display() -> PropertyValue? {
        let id = peekIdent()
        switch id {
        // FIXME: Add support for `run-in`.
        case .Block, .Inline:
            return displayAfterOutside(id)
        case .Flow, .FlowRoot, .Table, .Flex, .Grid:
            return displayAfterInside(id)
        case .GridLanes:
            guard gridLanesEnabled() else {
                return nil
            }
            return displayAfterInside(id)
        case .Ruby:
            guard rubyDisplayTypesEnabled() else {
                return nil
            }
            return displayAfterInside(id)
        // FIXME: Add support for the full <display-listitem> syntax, not just the single value version.
        // FIXME: Add support for `ruby-base-container` and `ruby-text-container`.
        case .ListItem, .TableCaption, .TableCell, .TableColumnGroup, .TableColumn, .TableHeaderGroup, .TableFooterGroup, .TableRow,
            .TableRowGroup, .Contents, .None, .InlineBlock, .InlineTable, .InlineFlex, .InlineGrid, .WebkitBox, .WebkitInlineBox:
            return consumeKeyword(peeked: id)
        case .RubyBase, .RubyText:
            guard rubyDisplayTypesEnabled() else {
                return nil
            }
            return consumeKeyword(peeked: id)
        case .InlineGridLanes:
            guard gridLanesEnabled() else {
                return nil
            }
            return consumeKeyword(peeked: id)
        case .WebkitFlex:
            consumeIncludingWhitespace()
            return keywordValue(.Flex)
        case .WebkitInlineFlex:
            consumeIncludingWhitespace()
            return keywordValue(.InlineFlex)
        default:
            return nil
        }
    }
}
