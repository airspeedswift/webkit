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

internal import WebCore_Private.Core.AnchorPositionEvaluator
internal import WebCore_Private.Core.CSSCalcSwiftTypes
internal import WebCore_Private.Core.CSSParserToken

// The parse of a math function's arguments into a calculation tree (CSSCalcTree+Parser.cpp): the grammar, the type
// checking of each function's arguments, and the simplification of each node as it is built.

// MARK: - Types (CSSCalcType.h)

extension CalcType {
    private func exponent(at k: UInt64) -> Int8 {
        Int8(truncatingIfNeeded: bits >> (8 * k))
    }

    /// The exponents of length, time, frequency, resolution, flex and percent, and of angle when `includingAngle`,
    /// are all 0.
    private func hasOnlyZeroExponents(includingAngle: Bool) -> Bool {
        for k: UInt64 in 0..<7 where (k != 1 || includingAngle) && exponent(at: k) != 0 {
            return false
        }
        return true
    }

    /// `matchesAny<Match::Number>({ .allowsPercentHint = true })`.
    var isNumberAllowingPercentHint: Bool {
        hasOnlyZeroExponents(includingAngle: true)
    }

    /// `matchesAny<Match::Number, Match::Angle>({ .allowsPercentHint = true })`.
    var isNumberOrAngleAllowingPercentHint: Bool {
        let angle = exponent(at: 1)
        return hasOnlyZeroExponents(includingAngle: false) && (angle == 0 || angle == 1)
    }

    /// `matchesAny<Match::Angle>({ .allowsPercentHint = true })`.
    var isAngleAllowingPercentHint: Bool {
        hasOnlyZeroExponents(includingAngle: false) && exponent(at: 1) == 1
    }

    /// `Type::makeLength()`.
    static var length: CalcType {
        var type = CxxCalcType()
        type.length = 1
        return CalcType(type)
    }

    /// `Type::makeAngle()`.
    static var angle: CalcType {
        var type = CxxCalcType()
        type.angle = 1
        return CalcType(type)
    }

    /// `Type::consistentType`.
    func consistent(with other: CalcType) -> CalcType? {
        CxxCalcType.consistentType(cxx, other.cxx).value.map { CalcType($0) }
    }

    /// `Type::sameType`.
    func same(as other: CalcType) -> CalcType? {
        CxxCalcType.sameType(cxx, other.cxx).value.map { CalcType($0) }
    }

    /// `Type::madeConsistent(base, self)`.
    func madeConsistent(base: CalcType) -> CalcType? {
        CxxCalcType.madeConsistent(base.cxx, cxx).value.map { CalcType($0) }
    }

    /// This type with the percent hint `Type::determinePercentHint(category)`.
    func withPercentHint(of category: WebCore.CSS.Category) -> CalcType {
        var type = cxx
        type.percentHint = CxxCalcType.determinePercentHint(category)
        return CalcType(type)
    }
}

/// What a math function accepts as an argument (`AllowedTypes`), how its arguments' types combine (`MergePolicy`),
/// and what its own type is (`OutputTransform`).
struct CalcFunctionTypes {
    enum Input {
        case any
        case number
        case numberOrAngle
    }

    enum Output {
        case none
        case numberMadeConsistent
        case angleMadeConsistent
    }

    let input: Input
    let mergesSame: Bool
    let output: Output

    init(_ kind: CalcKind) {
        switch kind {
        case .Sin, .Cos, .Tan:
            self.init(.numberOrAngle, output: .numberMadeConsistent)
        case .Asin, .Acos, .Atan:
            self.init(.number, output: .angleMadeConsistent)
        case .Atan2:
            self.init(.any, output: .angleMadeConsistent)
        case .Pow:
            self.init(.number, output: .none)
        case .Sqrt, .Log, .Exp:
            self.init(.number, output: .numberMadeConsistent)
        case .Sign, .Progress, .ProgressNoClamp:
            self.init(.any, output: .numberMadeConsistent)
        case .Random:
            self.init(.any, mergesSame: true, output: .none)
        default:
            // Min, Max, Clamp, the roundings, Mod, Rem, Hypot, Abs, CalcMix.
            self.init(.any, output: .none)
        }
    }

    private init(_ input: Input, mergesSame: Bool = false, output: Output) {
        self.input = input
        self.mergesSame = mergesSame
        self.output = output
    }

    /// `validateType<input>`.
    func validates(_ type: CalcType) -> Bool {
        switch input {
        case .any:
            return true
        case .number:
            return type.isNumberAllowingPercentHint
        case .numberOrAngle:
            return type.isNumberOrAngleAllowingPercentHint
        }
    }

    /// `mergeTypes<merge>`.
    func merge(_ a: CalcType, _ b: CalcType) -> CalcType? {
        mergesSame ? a.same(as: b) : a.consistent(with: b)
    }

    /// `getValidatedTypeFor`: `type` where it validates, else nil.
    func validated(_ type: CalcType) -> CalcType? {
        validates(type) ? type : nil
    }

    /// `mergeTypes<merge>` of two types either of which may be absent.
    func merge(_ a: CalcType?, _ b: CalcType?) -> CalcType? {
        guard let a, let b else {
            return nil
        }
        return merge(a, b)
    }

    /// `transformType<output>`.
    func transform(_ type: CalcType) -> CalcType? {
        switch output {
        case .none:
            return type
        case .numberMadeConsistent:
            return type.madeConsistent(base: .number)
        case .angleMadeConsistent:
            return type.madeConsistent(base: .angle)
        }
    }
}

/// `toType(const Op&)`: the type of the operation at `index` in `arena` from its arguments' types, nil where they
/// do not combine.
func calcOperationType(_ index: Int, _ arena: borrowing CalcArena) -> CalcType? {
    let kind = arena.kind(index)
    let count = arena.childCount(index)
    let first = index &+ 1 // index < arena.count.
    switch kind {
    case .Sum, .Product:
        var type: CalcType? = arena.type(first)
        var child = first
        for _ in 1..<count {
            child = arena.end(child)
            guard let current = type else {
                return nil
            }
            type = kind == .Sum ? current.adding(arena.type(child)) : current.multiplying(arena.type(child))
        }
        return type
    case .Negate:
        return arena.type(first)
    case .Invert:
        return arena.type(first).inverted()
    case .Deg2Rad:
        // An <angle> to a <number> (radians).
        return CalcType(CxxCalcType())
    case .Clamp:
        let types = CalcFunctionTypes(.Clamp)
        let flags = arena[index].flags
        let minIsNone = flags & CalcNodeFlags.minIsNone != 0
        let maxIsNone = flags & CalcNodeFlags.maxIsNone != 0
        let value = minIsNone ? first : arena.end(first)
        var type = types.validated(arena.type(value))
        if !minIsNone {
            type = types.merge(type, types.validated(arena.type(first)))
        }
        if !maxIsNone {
            type = types.merge(type, types.validated(arena.type(arena.end(value))))
        }
        return type.flatMap { types.transform($0) }
    case .CalcMix:
        let types = CalcFunctionTypes(.CalcMix)
        var item = first
        var type = types.validated(arena.type(item &+ 1)) // An item has a child.
        for _ in 1..<count {
            item = arena.end(item)
            type = types.merge(type, types.validated(arena.type(item &+ 1)))
        }
        return type.flatMap { types.transform($0) }
    default:
        // The other math functions, whose arguments are their children in order.
        precondition(!kind.isLeaf && kind != .CalcMixItem && kind != .Anchor && kind != .AnchorSize)
        let types = CalcFunctionTypes(kind)
        var child = first
        var type = types.validated(arena.type(child))
        for _ in 1..<count {
            child = arena.end(child)
            type = types.merge(type, types.validated(arena.type(child)))
        }
        return type.flatMap { types.transform($0) }
    }
}

// MARK: - Tokens

/// The CSSParserTokenType values the grammar reads.
private enum CalcTokenType {
    static var ident: UInt8 { UInt8(WebCore.IdentToken.rawValue) }
    static var function: UInt8 { UInt8(WebCore.FunctionToken.rawValue) }
    static var delimiter: UInt8 { UInt8(WebCore.DelimiterToken.rawValue) }
    static var number: UInt8 { UInt8(WebCore.NumberToken.rawValue) }
    static var percentage: UInt8 { UInt8(WebCore.PercentageToken.rawValue) }
    static var dimension: UInt8 { UInt8(WebCore.DimensionToken.rawValue) }
    static var nonNewlineWhitespace: UInt8 { UInt8(WebCore.NonNewlineWhitespaceToken.rawValue) }
    static var newline: UInt8 { UInt8(WebCore.NewlineToken.rawValue) }
    static var comma: UInt8 { UInt8(WebCore.CommaToken.rawValue) }
    static var leftParenthesis: UInt8 { UInt8(WebCore.LeftParenthesisToken.rawValue) }
    static var eof: UInt8 { UInt8(WebCore.EOFToken.rawValue) }

    /// `CSSTokenizer::isWhitespace`.
    static func isWhitespace(_ type: UInt8) -> Bool {
        type == nonNewlineWhitespace || type == newline
    }

    /// A token's block type (`CSSParserToken::BlockType`): it starts a block.
    static var blockStart: UInt8 { UInt8(WebCore.CSSParserToken.BlockStart.rawValue) }
    /// A token's block type: it ends the block it is in.
    static var blockEnd: UInt8 { UInt8(WebCore.CSSParserToken.BlockEnd.rawValue) }
}

/// The value IDs the grammar reads.
private typealias CalcValueID = WebCore.CSSValueID

private func calcValueID(_ id: CalcValueID) -> UInt16 {
    id.rawValue
}

/// The tokens `[index, end)`: a `CSSParserTokenRange`.
private struct CalcRange {
    var index: Int
    var end: Int

    var atEnd: Bool { index >= end }
}

/// A clamp() bound's type, or `none`.
///
/// Internal, not private: a private type's metadata is a linkonce_odr alias in a multithreaded whole-module build,
/// which LLVM's COFF symbol table rejects at the LTO link ("Invalid weak external").
struct CalcBound {
    var type: CalcType
    var isNone: Bool
}

/// The ParserOptions and the parts of the property parser state the grammar reads, and whether it simplifies as it
/// builds.
private struct CalcParseContext {
    var category: WebCore.CSS.Category
    var flags: UInt32
    var allowsSymbols: Bool
    var simplifies: Bool

    func allows(_ flag: UInt32) -> Bool {
        flags & flag != 0
    }
}

/// `maxExpressionDepth`: the nesting of math functions and parenthesized expressions a parse accepts.
private var calcMaxExpressionDepth: Int { 100 }

/// `isCalcFunction`.
private func calcIsMathFunction(_ id: UInt16) -> Bool {
    guard let id = CalcValueID(rawValue: id) else {
        return false
    }
    switch id {
    case .Calc, .CalcMix, .WebkitCalc, .Min, .Max, .Clamp, .Pow, .Sqrt, .Hypot, .Sin, .Cos, .Tan, .Exp, .Log, .Asin, .Acos,
        .Atan, .Atan2, .Abs, .Sign, .Round, .Mod, .Rem, .Progress, .Random, .SiblingCount, .SiblingIndex, .Anchor, .AnchorSize:
        return true
    default:
        return false
    }
}

/// `lookupConstantNumber`: e, pi, infinity, -infinity and NaN.
private func calcConstant(_ id: UInt16) -> Double? {
    guard let id = CalcValueID(rawValue: id) else {
        return nil
    }
    switch id {
    case .E:
        // std::numbers::e.
        return 2.718281828459045235360287471352662
    case .Pi:
        return Double.pi
    case .Infinity:
        return .infinity
    case .NegativeInfinity:
        return -1 * Double.infinity
    case .NaN:
        return .nan
    default:
        return nil
    }
}

/// `cssValueIDToAnchorSizeDimension`: the Style::AnchorSizeDimension raw value of an <anchor-size> keyword.
private func calcAnchorSizeDimension(_ id: UInt16) -> UInt8? {
    guard let id = CalcValueID(rawValue: id) else {
        return nil
    }
    switch id {
    case .Width:
        return WebCore.Style.AnchorSizeDimension.Width.rawValue
    case .Height:
        return WebCore.Style.AnchorSizeDimension.Height.rawValue
    case .Block:
        return WebCore.Style.AnchorSizeDimension.Block.rawValue
    case .Inline:
        return WebCore.Style.AnchorSizeDimension.Inline.rawValue
    case .SelfBlock:
        return WebCore.Style.AnchorSizeDimension.SelfBlock.rawValue
    case .SelfInline:
        return WebCore.Style.AnchorSizeDimension.SelfInline.rawValue
    default:
        return nil
    }
}

// MARK: - The parser

/// The tokens of one parse, the tree it builds and what it has found: `ParserState`, with the CSSParserTokens.
///
/// Each parse function appends the tree it parses to `arena`, where it is the last subtree, and returns its type.
/// One that fails returns nil, and leaves records only the caller's failure discards.
private struct CalcParser: ~Copyable, ~Escapable {
    /// The tokens, each with the block type the tokenizer gave it.
    let tokens: Span<WebCore.CSSCalcSwiftToken>
    var arena: CalcArena
    var simplifier: CalcSimplifier
    /// Whether the tree has a unit or function that needs conversion data.
    var requiresConversionData = false

    @_lifetime(copy tokens, copy arena)
    init(_ tokens: Span<WebCore.CSSCalcSwiftToken>, _ arena: consuming CalcArena, _ options: WebCore.CSSCalcSwiftSimplificationOptions) {
        self.tokens = tokens
        self.arena = arena
        simplifier = CalcSimplifier(options)
    }

    // MARK: Token access (CSSParserTokenRange)

    func peekType(_ range: CalcRange) -> UInt8 {
        range.atEnd ? CalcTokenType.eof : tokens[range.index].type
    }

    /// `peek().id()`: the CSSValueID of an ident token, Invalid otherwise.
    func peekIdent(_ range: CalcRange) -> UInt16 {
        peekType(range) == CalcTokenType.ident ? tokens[range.index].id : 0
    }

    /// `peek().functionId()`.
    func peekFunction(_ range: CalcRange) -> UInt16 {
        peekType(range) == CalcTokenType.function ? tokens[range.index].id : 0
    }

    func consume(_ range: inout CalcRange) {
        if !range.atEnd {
            range.index += 1
        }
    }

    func consumeWhitespace(_ range: inout CalcRange) {
        while !range.atEnd && CalcTokenType.isWhitespace(tokens[range.index].type) {
            range.index += 1
        }
    }

    func consumeIncludingWhitespace(_ range: inout CalcRange) {
        consume(&range)
        consumeWhitespace(&range)
    }

    /// `consumeCommaIncludingWhitespace`.
    func consumeComma(_ range: inout CalcRange) -> Bool {
        guard peekType(range) == CalcTokenType.comma else {
            return false
        }
        consumeIncludingWhitespace(&range)
        return true
    }

    /// `consumeIdentRaw<ids...>`: the ident at the front if `matches` accepts it, consumed with the whitespace after it.
    func consumeIdent(_ range: inout CalcRange, _ matches: (CalcValueID) -> Bool) -> UInt16? {
        guard peekType(range) == CalcTokenType.ident, let id = CalcValueID(rawValue: tokens[range.index].id), matches(id) else {
            return nil
        }
        consumeIncludingWhitespace(&range)
        return id.rawValue
    }

    /// `consumeBlock`: consumes the block starting at the front, and returns its contents.
    func consumeBlock(_ range: inout CalcRange) -> CalcRange {
        let start = range.index + 1
        var nestingLevel = 0
        repeat {
            let i = range.index
            consume(&range)
            let blockType = tokens[i].blockType
            if blockType == CalcTokenType.blockStart {
                nestingLevel += 1
            } else if blockType == CalcTokenType.blockEnd {
                nestingLevel -= 1
            }
        } while nestingLevel != 0 && !range.atEnd
        // Ended at the end of the tokens, or before the token that closed the block.
        return CalcRange(index: start, end: nestingLevel != 0 ? range.index : range.index - 1)
    }

    /// Replaces the node at `index`, the last subtree, by what it simplifies to, when the context simplifies.
    mutating func simplify(_ index: Int, _ context: CalcParseContext, _ resolver: inout WebCore.CSSCalcSwiftResolver) {
        if context.simplifies {
            simplifier.simplify(index, &arena, &resolver)
        }
    }

    /// Makes the last `childCount` subtrees, from `start` on, the children of an operation, and simplifies it.
    mutating func makeOperation(
        at start: Int,
        _ kind: CalcKind,
        type: CalcType,
        childCount: Int,
        _ context: CalcParseContext,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) {
        arena.makeOperation(at: start, kind, type: type, childCount: childCount)
        simplify(start, context, &resolver)
    }

    // MARK: Math functions

    /// `parseCalcFunction`: the arguments of the math function `function` in `range`.
    mutating func parseFunction(
        _ range: inout CalcRange,
        _ function: UInt16,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        guard depth <= calcMaxExpressionDepth, let id = CalcValueID(rawValue: function) else {
            return nil
        }
        switch id {
        case .WebkitCalc, .Calc:
            return parseSum(&range, depth, context, &facade, &resolver)
        case .Min:
            return parseOneOrMoreArguments(.Min, &range, depth, context, &facade, &resolver)
        case .Max:
            return parseOneOrMoreArguments(.Max, &range, depth, context, &facade, &resolver)
        case .Clamp:
            return parseClamp(&range, depth, context, &facade, &resolver)
        case .Round:
            return parseRound(&range, depth, context, &facade, &resolver)
        case .Mod:
            return parseTwoArguments(.Mod, &range, depth, context, &facade, &resolver)
        case .Rem:
            return parseTwoArguments(.Rem, &range, depth, context, &facade, &resolver)
        case .Sin:
            return parseOneArgument(.Sin, &range, depth, context, &facade, &resolver)
        case .Cos:
            return parseOneArgument(.Cos, &range, depth, context, &facade, &resolver)
        case .Tan:
            return parseOneArgument(.Tan, &range, depth, context, &facade, &resolver)
        case .Asin:
            return parseOneArgument(.Asin, &range, depth, context, &facade, &resolver)
        case .Acos:
            return parseOneArgument(.Acos, &range, depth, context, &facade, &resolver)
        case .Atan:
            return parseOneArgument(.Atan, &range, depth, context, &facade, &resolver)
        case .Atan2:
            return parseTwoArguments(.Atan2, &range, depth, context, &facade, &resolver)
        case .Pow:
            return parseTwoArguments(.Pow, &range, depth, context, &facade, &resolver)
        case .Sqrt:
            return parseOneArgument(.Sqrt, &range, depth, context, &facade, &resolver)
        case .Hypot:
            return parseOneOrMoreArguments(.Hypot, &range, depth, context, &facade, &resolver)
        case .Log:
            return parseLog(&range, depth, context, &facade, &resolver)
        case .Exp:
            return parseOneArgument(.Exp, &range, depth, context, &facade, &resolver)
        case .Abs:
            return parseOneArgument(.Abs, &range, depth, context, &facade, &resolver)
        case .Sign:
            return parseOneArgument(.Sign, &range, depth, context, &facade, &resolver)
        case .Random:
            return parseRandom(&range, depth, context, &facade, &resolver)
        case .Progress:
            return parseProgress(&range, depth, context, &facade, &resolver)
        case .CalcMix:
            return parseCalcMix(&range, depth, context, &facade, &resolver)
        case .SiblingCount, .SiblingIndex:
            guard context.allows(UInt32(WebCore.CSSCalcParseAllowTreeCounting)) else {
                return nil
            }
            requiresConversionData = true
            guard range.atEnd else {
                return nil
            }
            arena.append(.leaf(id == .SiblingCount ? .SiblingCount : .SiblingIndex, type: .number))
            return .number
        case .Anchor:
            return parseAnchor(&range, depth, context, &facade, &resolver)
        case .AnchorSize:
            return parseAnchorSize(&range, depth, context, &facade, &resolver)
        default:
            return nil
        }
    }

    /// `consumeExactlyOneArgument`.
    mutating func parseOneArgument(
        _ kind: CalcKind,
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        let types = CalcFunctionTypes(kind)
        let start = arena.count
        guard let sumType = parseSum(&range, depth, context, &facade, &resolver), range.atEnd, types.validates(sumType),
            let outputType = types.transform(sumType)
        else {
            return nil
        }

        // sin(), cos() and tan() take a <number> in radians or an <angle>, in degrees, which a Deg2Rad converts.
        if (kind == .Sin || kind == .Cos || kind == .Tan) && sumType.isAngleAllowingPercentHint {
            makeOperation(at: start, .Deg2Rad, type: .number, childCount: 1, context, &resolver)
        }

        makeOperation(at: start, kind, type: outputType, childCount: 1, context, &resolver)
        return outputType
    }

    /// `consumeOneOrMoreArguments`: a comma-separated list of calculations.
    mutating func parseOneOrMoreArguments(
        _ kind: CalcKind,
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        let types = CalcFunctionTypes(kind)
        let start = arena.count
        var mergedType: CalcType? = nil
        var childCount = 0
        var requireComma = false

        while !range.atEnd {
            consumeWhitespace(&range)
            if requireComma && !consumeComma(&range) {
                return nil
            }
            guard let sumType = parseSum(&range, depth, context, &facade, &resolver), types.validates(sumType) else {
                return nil
            }
            if let merged = mergedType {
                guard let type = types.merge(merged, sumType) else {
                    return nil
                }
                mergedType = type
            } else {
                mergedType = sumType
            }
            childCount += 1
            requireComma = true
        }

        guard let mergedType, let outputType = types.transform(mergedType) else {
            return nil
        }
        makeOperation(at: start, kind, type: outputType, childCount: childCount, context, &resolver)
        return outputType
    }

    /// `consumeExactlyTwoArguments`.
    mutating func parseTwoArguments(
        _ kind: CalcKind,
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        let types = CalcFunctionTypes(kind)
        let start = arena.count
        guard let a = parseSum(&range, depth, context, &facade, &resolver), types.validates(a), consumeComma(&range),
            let b = parseSum(&range, depth, context, &facade, &resolver), range.atEnd, types.validates(b),
            let mergedType = types.merge(a, b), let outputType = types.transform(mergedType)
        else {
            return nil
        }
        makeOperation(at: start, kind, type: outputType, childCount: 2, context, &resolver)
        return outputType
    }

    /// `consumeOneOrTwoArguments<Log>`.
    mutating func parseLog(
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        let types = CalcFunctionTypes(.Log)
        let start = arena.count
        guard let a = parseSum(&range, depth, context, &facade, &resolver), types.validates(a) else {
            return nil
        }
        if range.atEnd {
            guard let outputType = types.transform(a) else {
                return nil
            }
            arena.makeNode(at: start, .operation(.Log, type: outputType, childCount: 1, flags: CalcNodeFlags.optionalAbsent))
            simplify(start, context, &resolver)
            return outputType
        }
        guard consumeComma(&range), let b = parseSum(&range, depth, context, &facade, &resolver), range.atEnd,
            types.validates(b), let mergedType = types.merge(a, b), let outputType = types.transform(mergedType)
        else {
            return nil
        }
        arena.makeNode(at: start, .operation(.Log, type: outputType, childCount: 2))
        simplify(start, context, &resolver)
        return outputType
    }

    /// `consumeClamp`: clamp( [ <calc-sum> | none ], <calc-sum>, [ <calc-sum> | none ] ).
    mutating func parseClamp(
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        let start = arena.count
        guard let min = parseSumOrNone(&range, depth, context, &facade, &resolver), consumeComma(&range),
            let value = parseSum(&range, depth, context, &facade, &resolver), consumeComma(&range),
            let max = parseSumOrNone(&range, depth, context, &facade, &resolver), range.atEnd
        else {
            return nil
        }

        let outputType: CalcType
        switch (min.isNone, max.isNone) {
        case (true, true):
            outputType = value
        case (true, false):
            guard let type = value.consistent(with: max.type) else {
                return nil
            }
            outputType = type
        case (false, true):
            guard let type = min.type.consistent(with: value) else {
                return nil
            }
            outputType = type
        case (false, false):
            guard let minAndValue = min.type.consistent(with: value), let type = minAndValue.consistent(with: max.type) else {
                return nil
            }
            outputType = type
        }

        let flags = (min.isNone ? CalcNodeFlags.minIsNone : 0) | (max.isNone ? CalcNodeFlags.maxIsNone : 0)
        let childCount = 1 + (min.isNone ? 0 : 1) + (max.isNone ? 0 : 1)
        arena.makeNode(at: start, .operation(.Clamp, type: outputType, childCount: childCount, flags: flags))
        simplify(start, context, &resolver)
        return outputType
    }

    mutating func parseSumOrNone(
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcBound? {
        if peekIdent(range) == calcValueID(.None) {
            consumeIncludingWhitespace(&range)
            return CalcBound(type: .number, isNone: true)
        }
        guard let type = parseSum(&range, depth, context, &facade, &resolver) else {
            return nil
        }
        return CalcBound(type: type, isNone: false)
    }

    /// `consumeRound`: round( <rounding-strategy>?, <calc-sum>, <calc-sum>? ).
    mutating func parseRound(
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        var kind = CalcKind.RoundNearest
        if let strategy = consumeIdent(&range, { $0 == .Nearest || $0 == .ToZero || $0 == .Up || $0 == .Down }) {
            guard consumeComma(&range) else {
                return nil
            }
            switch strategy {
            case calcValueID(.ToZero):
                kind = .RoundToZero
            case calcValueID(.Up):
                kind = .RoundUp
            case calcValueID(.Down):
                kind = .RoundDown
            default:
                kind = .RoundNearest
            }
        }

        let start = arena.count
        guard let a = parseSum(&range, depth, context, &facade, &resolver) else {
            return nil
        }
        if range.atEnd {
            // A single argument is a <number>, rounded to an integer.
            guard a.isNumberAllowingPercentHint else {
                return nil
            }
            arena.makeNode(at: start, .operation(kind, type: a, childCount: 1, flags: CalcNodeFlags.optionalAbsent))
            simplify(start, context, &resolver)
            return a
        }
        guard consumeComma(&range), let b = parseSum(&range, depth, context, &facade, &resolver), range.atEnd,
            let outputType = a.consistent(with: b)
        else {
            return nil
        }
        arena.makeNode(at: start, .operation(kind, type: outputType, childCount: 2))
        simplify(start, context, &resolver)
        return outputType
    }

    /// `consumeRandom`: random( <random-key>? , <calc-sum>, <calc-sum>, <calc-sum>? ).
    mutating func parseRandom(
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        guard context.allows(UInt32(WebCore.CSSCalcParseAllowRandom)) else {
            return nil
        }

        // The sharing: `auto` without a <random-key>.
        let keyStart = range.index
        let consumed = facade.consumeRandomSharing(UInt32(keyStart))
        let next = Int(consumed.nextToken)
        guard consumed.payload != CalcNode.noPayload, next >= keyStart, next <= range.end else {
            return nil
        }
        var fixedIsCalc = false
        if next > keyStart {
            if peekIdent(range) == calcValueID(.Fixed) {
                var number = range
                consumeIncludingWhitespace(&number)
                fixedIsCalc = peekType(number) == CalcTokenType.function
            }
            range.index = next
            guard consumeComma(&range) else {
                return nil
            }
        }
        // Counted after the sharing, so that a random() in the arguments sees the count with this one in it.
        facade.countRandomFunction()

        let types = CalcFunctionTypes(.Random)
        let start = arena.count
        guard let min = parseSum(&range, depth, context, &facade, &resolver), consumeComma(&range),
            let max = parseSum(&range, depth, context, &facade, &resolver)
        else {
            return nil
        }

        var hasStep = false
        var outputType: CalcType
        if range.atEnd {
            guard types.validates(min), types.validates(max), let mergedType = types.merge(min, max), let type = types.transform(mergedType)
            else {
                return nil
            }
            outputType = type
        } else {
            guard consumeComma(&range), let step = parseSum(&range, depth, context, &facade, &resolver), range.atEnd,
                types.validates(step), let minAndMax = types.merge(min, max), let mergedType = types.merge(minAndMax, step),
                let type = types.transform(mergedType)
            else {
                return nil
            }
            outputType = type
            hasStep = true
        }
        requiresConversionData = true

        arena.makeNode(
            at: start,
            .operation(
                .Random,
                type: outputType,
                childCount: hasStep ? 3 : 2,
                flags: hasStep ? 0 : CalcNodeFlags.optionalAbsent,
                unit: fixedIsCalc ? CalcNode.calcValueUnit : 0,
                payload: consumed.payload
            )
        )
        simplify(start, context, &resolver)
        return outputType
    }

    /// `consumeProgress`: progress( no-clamp? <calc-sum>, <calc-sum>, <calc-sum> ).
    mutating func parseProgress(
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        let kind: CalcKind = consumeIdent(&range, { $0 == .NoClamp }) != nil ? .ProgressNoClamp : .Progress
        let types = CalcFunctionTypes(kind)
        let start = arena.count
        guard let value = parseSum(&range, depth, context, &facade, &resolver), consumeComma(&range),
            let startType = parseSum(&range, depth, context, &facade, &resolver), consumeComma(&range),
            let end = parseSum(&range, depth, context, &facade, &resolver), range.atEnd,
            types.validates(value), types.validates(startType), types.validates(end),
            let valueAndStart = types.merge(value, startType), let mergedType = types.merge(valueAndStart, end),
            let outputType = types.transform(mergedType)
        else {
            return nil
        }
        makeOperation(at: start, kind, type: outputType, childCount: 3, context, &resolver)
        return outputType
    }

    /// `consumeCalcMix`: calc-mix( [ <calc-sum> <percentage [0,100]>? ]# ).
    mutating func parseCalcMix(
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        guard context.allows(UInt32(WebCore.CSSCalcParseAllowCalcMix)) else {
            return nil
        }
        let types = CalcFunctionTypes(.CalcMix)
        let start = arena.count
        var mergedType: CalcType? = nil
        var itemCount = 0
        var requireComma = false

        while !range.atEnd {
            consumeWhitespace(&range)
            if requireComma && !consumeComma(&range) {
                return nil
            }
            let item = arena.count
            guard let sumType = parseSum(&range, depth, context, &facade, &resolver), types.validates(sumType) else {
                return nil
            }
            if let merged = mergedType {
                guard let type = types.merge(merged, sumType) else {
                    return nil
                }
                mergedType = type
            } else {
                mergedType = sumType
            }

            if !range.atEnd && peekType(range) != CalcTokenType.comma {
                // A <percentage> is a raw weight; a math function is a weight only evaluation resolves.
                let weightStart = range.index
                let isPercentage = peekType(range) == CalcTokenType.percentage
                let rawWeight = tokens[weightStart].numericValue
                let consumed = facade.consumeCalcMixWeight(UInt32(weightStart))
                guard consumed.payload != CalcNode.noPayload, Int(consumed.nextToken) <= range.end else {
                    return nil
                }
                range.index = Int(consumed.nextToken)
                arena.makeNode(
                    at: item,
                    .operation(
                        .CalcMixItem,
                        type: .number,
                        childCount: 1,
                        unit: isPercentage ? CalcNode.rawWeightUnit : CalcNode.calcValueUnit,
                        payload: consumed.payload,
                        value: isPercentage ? rawWeight : 0
                    )
                )
            } else {
                arena.makeNode(at: item, .operation(.CalcMixItem, type: .number, childCount: 1))
            }
            itemCount += 1
            requireComma = true
        }

        guard let mergedType, let outputType = types.transform(mergedType) else {
            return nil
        }
        makeOperation(at: start, .CalcMix, type: outputType, childCount: itemCount, context, &resolver)
        return outputType
    }

    // MARK: anchor() and anchor-size()

    /// `consumeValueWithoutSimplifyingRootCalc`: a value, with a math function that parses to a leaf kept as a sum
    /// of it, so that it still serializes as a function.
    mutating func parseValueKeepingFunction(
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        // Complex arguments need to be in a math function.
        if peekType(range) == CalcTokenType.leftParenthesis {
            return nil
        }
        let isFunction = peekFunction(range) != 0
        let start = arena.count
        guard let type = parseValue(&range, depth, context, &facade, &resolver) else {
            return nil
        }
        if isFunction && arena.kind(start).isLeaf {
            arena.makeOperation(at: start, .Sum, type: type, childCount: 1)
        }
        return type
    }

    /// `consumeAnchorFallback`: a <length> or <length-percentage>, or a unitless 0 as 0px where the property allows it.
    mutating func parseAnchorFallback(
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        let start = arena.count
        guard let type = parseValueKeepingFunction(&range, depth, context, &facade, &resolver),
            let category = type.calculationCategory()
        else {
            return nil
        }
        switch category {
        case .Length, .LengthPercentage:
            return type
        case .Number:
            // Only a bare <number> leaf: calc(0) or min(0, 0) is a sum, not a unitless zero.
            guard context.allows(UInt32(WebCore.CSSCalcParseAllowUnitlessZeroLength)), arena.kind(start) == .Number,
                arena.value(start) == 0
            else {
                return nil
            }
            arena.replace(start, with: .canonicalDimension(0, unit: .Px))
            return .length
        default:
            return nil
        }
    }

    /// The anchor name a <dashed-ident> at the front gives, consumed, or `noPayload`.
    func consumeDashedIdent(_ range: inout CalcRange, _ facade: inout WebCore.CSSCalcSwiftParser) -> UInt32 {
        let consumed = facade.consumeDashedIdent(UInt32(range.index))
        let next = Int(consumed.nextToken)
        if next >= range.index && next <= range.end {
            range.index = next
        }
        return consumed.payload
    }

    /// `consumeAnchor`: anchor( <anchor-element>? && <anchor-side>, <length-percentage>? ).
    mutating func parseAnchor(
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        guard context.allows(UInt32(WebCore.CSSCalcParseAllowAnchor)) else {
            return nil
        }
        let start = arena.count
        var name = consumeDashedIdent(&range, &facade)

        // <anchor-side> = inside | outside | top | left | right | bottom | start | end | self-start | self-end |
        // <percentage> | center
        let sideKeyword = consumeIdent(&range) { id in
            switch id {
            case .Inside, .Outside, .Top, .Left, .Right, .Bottom, .Start, .End, .SelfStart, .SelfEnd, .Center:
                return true
            default:
                return false
            }
        }
        if sideKeyword == nil {
            // A <percentage> parsed on its own, without simplification, symbols or the property's anchor options.
            let percentageContext = CalcParseContext(
                category: .Percentage,
                flags: (context.flags & ~UInt32(WebCore.CSSCalcParseAllowAnchor | WebCore.CSSCalcParseAllowAnchorSize))
                    | UInt32(WebCore.CSSCalcParseAllowUnitlessZeroLength),
                allowsSymbols: false,
                simplifies: false
            )
            let requiresConversionData = self.requiresConversionData
            let percentage = parseValueKeepingFunction(&range, depth, percentageContext, &facade, &resolver)
            self.requiresConversionData = requiresConversionData
            guard let percentage, percentage.calculationCategory() == .Percentage else {
                return nil
            }
        }

        if name == CalcNode.noPayload {
            name = consumeDashedIdent(&range, &facade)
        }

        var type = CalcType.length
        var hasFallback = false
        if consumeComma(&range) {
            guard let fallback = parseAnchorFallback(&range, depth, context, &facade, &resolver),
                let category = fallback.calculationCategory()
            else {
                return nil
            }
            hasFallback = true
            type = type.withPercentHint(of: category)
        }
        requiresConversionData = true

        let optionalFlag = hasFallback ? 0 : CalcNodeFlags.optionalAbsent
        if let sideKeyword {
            precondition(sideKeyword != 0)
            arena.makeNode(
                at: start,
                .operation(.Anchor, type: type, childCount: hasFallback ? 1 : 0, flags: optionalFlag, unit: sideKeyword, payload: name)
            )
        } else {
            arena.makeNode(
                at: start,
                .operation(
                    .Anchor,
                    type: type,
                    childCount: hasFallback ? 2 : 1,
                    flags: CalcNodeFlags.sideIsChild | optionalFlag,
                    payload: name
                )
            )
        }
        return type
    }

    /// `consumeAnchorSize`: anchor-size( [ <anchor-element> || <anchor-size> ]? , <length-percentage>? ).
    mutating func parseAnchorSize(
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        guard context.allows(UInt32(WebCore.CSSCalcParseAllowAnchorSize)) else {
            return nil
        }
        let start = arena.count
        var name = consumeDashedIdent(&range, &facade)
        let size = consumeIdent(&range) { calcAnchorSizeDimension($0.rawValue) != nil }
        // The <anchor-element> may follow the <anchor-size>.
        if size != nil && name == CalcNode.noPayload {
            name = consumeDashedIdent(&range, &facade)
        }

        var fallbackType: CalcType? = nil
        if size != nil || name != CalcNode.noPayload {
            // A comma is followed by the fallback, which must parse.
            if consumeComma(&range) {
                guard let parsed = parseAnchorFallback(&range, depth, context, &facade, &resolver) else {
                    return nil
                }
                fallbackType = parsed
            }
        } else {
            // A fallback that does not parse leaves none, and what it consumed consumed.
            fallbackType = parseAnchorFallback(&range, depth, context, &facade, &resolver)
            if fallbackType == nil {
                arena.truncate(to: start)
            }
        }

        // A <length> where the anchor resolves, otherwise the <length-percentage> fallback.
        var type = CalcType.length
        if let fallbackType {
            // parseAnchorFallback gives only a <length> or a <length-percentage>.
            guard let category = fallbackType.calculationCategory() else {
                preconditionFailure()
            }
            type = type.withPercentHint(of: category)
        }
        requiresConversionData = true

        let dimension = size.flatMap { calcAnchorSizeDimension($0) }
        arena.makeNode(
            at: start,
            .operation(
                .AnchorSize,
                type: type,
                childCount: fallbackType != nil ? 1 : 0,
                flags: fallbackType != nil ? 0 : CalcNodeFlags.optionalAbsent,
                unit: dimension.map { UInt16($0) } ?? CalcNode.noDimension,
                payload: name
            )
        )
        return type
    }

    // MARK: Sums, products and values

    /// `parseCalcSum`: <calc-product> [ [ '+' | '-' ] <calc-product> ]*.
    mutating func parseSum(
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        guard depth <= calcMaxExpressionDepth else {
            return nil
        }
        let start = range.index
        let node = arena.count
        guard let firstType = parseProduct(&range, depth, context, &facade, &resolver) else {
            return nil
        }
        var sumType = firstType
        var childCount = 1

        while !range.atEnd {
            let operation = peekType(range) == CalcTokenType.delimiter ? tokens[range.index].id : 0
            guard
                operation == UInt16(WebCore.CSSCalc.Operator.Sum.rawValue)
                    || operation == UInt16(WebCore.CSSCalc.Operator.Negate.rawValue)
            else {
                break
            }
            // calc(1px+ 2px) and calc(1px +2px) are invalid.
            precondition(range.index > start)
            guard CalcTokenType.isWhitespace(tokens[range.index - 1].type) else {
                return nil
            }
            consume(&range)
            guard CalcTokenType.isWhitespace(peekType(range)) else {
                return nil
            }
            consumeIncludingWhitespace(&range)

            let next = arena.count
            guard let nextType = parseProduct(&range, depth, context, &facade, &resolver) else {
                return nil
            }
            if operation == UInt16(WebCore.CSSCalc.Operator.Negate.rawValue) {
                makeOperation(at: next, .Negate, type: nextType, childCount: 1, context, &resolver)
            }

            guard let newType = sumType.adding(nextType) else {
                return nil
            }
            sumType = newType
            childCount += 1
        }

        if childCount == 1 {
            return firstType
        }
        makeOperation(at: node, .Sum, type: sumType, childCount: childCount, context, &resolver)
        return sumType
    }

    /// `parseCalcProduct`: <calc-value> [ [ '*' | '/' ] <calc-value> ]*.
    mutating func parseProduct(
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        guard depth <= calcMaxExpressionDepth else {
            return nil
        }
        let node = arena.count
        guard let firstType = parseValue(&range, depth, context, &facade, &resolver) else {
            return nil
        }
        var productType = firstType
        var childCount = 1

        while !range.atEnd {
            let operation = peekType(range) == CalcTokenType.delimiter ? tokens[range.index].id : 0
            guard
                operation == UInt16(WebCore.CSSCalc.Operator.Product.rawValue)
                    || operation == UInt16(WebCore.CSSCalc.Operator.Invert.rawValue)
            else {
                break
            }
            consumeIncludingWhitespace(&range)

            let next = arena.count
            guard var nextType = parseValue(&range, depth, context, &facade, &resolver) else {
                return nil
            }
            if operation == UInt16(WebCore.CSSCalc.Operator.Invert.rawValue) {
                guard let invertType = nextType.inverted() else {
                    return nil
                }
                makeOperation(at: next, .Invert, type: invertType, childCount: 1, context, &resolver)
                nextType = invertType
            }

            guard let newType = productType.multiplying(nextType) else {
                return nil
            }
            productType = newType
            childCount += 1
        }

        if childCount == 1 {
            return firstType
        }
        makeOperation(at: node, .Product, type: productType, childCount: childCount, context, &resolver)
        return productType
    }

    /// `parseCalcValue`: <number> | <dimension> | <percentage> | <calc-keyword> | ( <calc-sum> ), or a math function.
    /// The keywords are e, pi, infinity, -infinity, NaN and the symbols the context allows.
    mutating func parseValue(
        _ range: inout CalcRange,
        _ depth: Int,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        guard depth <= calcMaxExpressionDepth else {
            return nil
        }

        // A parenthesized expression is a nested calc().
        var function: UInt16? = nil
        if peekType(range) == CalcTokenType.leftParenthesis {
            function = calcValueID(.Calc)
        } else if calcIsMathFunction(peekFunction(range)) {
            function = peekFunction(range)
        }
        if let function {
            var inner = consumeBlock(&range)
            consumeWhitespace(&range)
            consumeWhitespace(&inner)
            guard let type = parseFunction(&inner, function, depth + 1, context, &facade, &resolver), inner.atEnd else {
                return nil
            }
            return type
        }

        let type = peekType(range)
        let index = range.index
        consumeIncludingWhitespace(&range)
        switch type {
        case CalcTokenType.ident:
            return parseKeyword(tokens[index].id, context, &facade, &resolver)
        case CalcTokenType.number:
            arena.append(.number(tokens[index].numericValue))
            return .number
        case CalcTokenType.percentage:
            let leaf = CalcRecord.percentage(tokens[index].numericValue, hint: CalcType.percentHint(context.category))
            arena.append(leaf)
            return CalcType(bits: leaf.typeBits)
        case CalcTokenType.dimension:
            return parseDimension(tokens[index].numericValue, tokens[index].unit, context, &resolver)
        default:
            return nil
        }
    }

    /// `parseCalcKeyword`.
    mutating func parseKeyword(
        _ id: UInt16,
        _ context: CalcParseContext,
        _ facade: inout WebCore.CSSCalcSwiftParser,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        if context.allowsSymbols {
            let symbolUnit = facade.allowedSymbolUnit(id)
            if symbolUnit >= 0 {
                guard let unit = WebCore.CSSUnitType(rawValue: UInt8(truncatingIfNeeded: symbolUnit)) else {
                    preconditionFailure()
                }
                let type = CalcType.determine(unit)
                if WebCore.conversionToCanonicalUnitRequiresConversionData(unit) {
                    if context.allows(UInt32(WebCore.CSSCalcParseAbsoluteLengthUnitsOnly)) {
                        return nil
                    }
                    requiresConversionData = true
                }
                let node = arena.count
                arena.append(.symbol(id, unit: unit))
                simplify(node, context, &resolver)
                return type
            }
        }
        guard let constant = calcConstant(id) else {
            return nil
        }
        arena.append(.number(constant))
        return .number
    }

    /// `parseCalcDimension`.
    mutating func parseDimension(
        _ value: Double,
        _ unitValue: UInt32,
        _ context: CalcParseContext,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> CalcType? {
        guard let unit = WebCore.CSSUnitType(rawValue: UInt8(truncatingIfNeeded: unitValue)), UInt32(unit.rawValue) == unitValue else {
            preconditionFailure()
        }
        if unit == .Unknown {
            return nil
        }
        let type = CalcType.determine(unit)
        if WebCore.conversionToCanonicalUnitRequiresConversionData(unit) {
            if context.allows(UInt32(WebCore.CSSCalcParseAbsoluteLengthUnitsOnly)) {
                return nil
            }
            requiresConversionData = true
        }
        let node = arena.count
        arena.append(.numeric(value, unit: unit))
        simplify(node, context, &resolver)
        return type
    }
}

// MARK: - Entry

/// Where a calc() is parsed: its category, the math function's CSSValueID (Invalid for a bare `<calc-sum>`), the
/// `CSSCalcParse` flags and the simplification options.
struct CalcParseOptions {
    let category: UInt8
    let function: UInt16
    let flags: UInt32
    let simplification: WebCore.CSSCalcSwiftSimplificationOptions
}

/// A parse of up to 32 tokens holds them and up to 32 records on the stack; one of up to 256 tokens holds them and up
/// to 128 records there. More records, and more tokens, are held on the heap. Inlined, so that the buffers are zeroed
/// with a memset.
@inline(always)
func cssCalcParseImpl(
    _ parser: inout WebCore.CSSCalcSwiftParser,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    _ output: inout WebCore.CSSCalcSwiftOutput,
    _ options: CalcParseOptions
) -> WebCore.CSSCalcSwiftParseResult {
    let count = Int(parser.tokenCount())
    guard count <= 32 else {
        return cssCalcParseLarge(count, &parser, &resolver, &output, options)
    }
    var tokenBuffer = [32 of WebCore.CSSCalcSwiftToken](repeating: WebCore.CSSCalcSwiftToken())
    var recordBuffer = [32 of CalcRecord](repeating: CalcRecord())
    var tokens = tokenBuffer.mutableSpan
    parser.fillTokens(&tokens)
    return cssCalcParse(tokens.span.extracting(0..<count), CalcArena(recordBuffer.mutableSpan), &parser, &resolver, &output, options)
}

@inline(never)
private func cssCalcParseLarge(
    _ count: Int,
    _ parser: inout WebCore.CSSCalcSwiftParser,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    _ output: inout WebCore.CSSCalcSwiftOutput,
    _ options: CalcParseOptions
) -> WebCore.CSSCalcSwiftParseResult {
    var recordBuffer = [128 of CalcRecord](repeating: CalcRecord())
    guard count <= 256 else {
        var storage = UniqueArray(repeating: WebCore.CSSCalcSwiftToken(), count: count)
        var tokens = storage.mutableSpan
        parser.fillTokens(&tokens)
        return cssCalcParse(tokens.span, CalcArena(recordBuffer.mutableSpan), &parser, &resolver, &output, options)
    }
    var tokenBuffer = [256 of WebCore.CSSCalcSwiftToken](repeating: WebCore.CSSCalcSwiftToken())
    var tokens = tokenBuffer.mutableSpan
    parser.fillTokens(&tokens)
    return cssCalcParse(tokens.span.extracting(0..<count), CalcArena(recordBuffer.mutableSpan), &parser, &resolver, &output, options)
}

/// The parse of `tokens`, the parser's, into `arena`.
@inline(never)
private func cssCalcParse(
    _ tokens: Span<WebCore.CSSCalcSwiftToken>,
    _ arena: consuming CalcArena,
    _ parser: inout WebCore.CSSCalcSwiftParser,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    _ output: inout WebCore.CSSCalcSwiftOutput,
    _ options: CalcParseOptions
) -> WebCore.CSSCalcSwiftParseResult {
    guard let category = WebCore.CSS.Category(rawValue: options.category) else {
        preconditionFailure()
    }
    var state = CalcParser(tokens, arena, options.simplification)
    let context = CalcParseContext(category: category, flags: options.flags, allowsSymbols: true, simplifies: true)
    var range = CalcRange(index: 0, end: tokens.count)

    let bareSum = options.function == UInt16(WebCore.CSSValueID.Invalid.rawValue)
    let rootType =
        bareSum
        ? state.parseSum(&range, 0, context, &parser, &resolver)
        : state.parseFunction(&range, options.function, 0, context, &parser, &resolver)

    // A math function's arguments are all its tokens; a tree of the wrong category is no tree.
    let consumedTokens = UInt32(truncatingIfNeeded: range.index) // At most the token count, a UInt32.
    guard let rootType, bareSum || range.atEnd, rootType.matches(category) else {
        return WebCore.CSSCalcSwiftParseResult(typeBits: 0, consumedTokens: consumedTokens, ok: 0, requiresConversionData: 0)
    }

    precondition(state.arena.count > 0 && state.arena.end(0) == state.arena.count)
    if state.simplifier.madeWeights {
        calcWritePendingWeights(&state.arena, at: 0, &output)
    }
    assert(state.arena.span.isCalcTree)
    output.adopt(state.arena.span)
    return WebCore.CSSCalcSwiftParseResult(
        typeBits: rootType.bits,
        consumedTokens: consumedTokens,
        ok: 1,
        requiresConversionData: state.requiresConversionData ? 1 : 0
    )
}
