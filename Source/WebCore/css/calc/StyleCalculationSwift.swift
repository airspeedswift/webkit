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
internal import wtf.Core.MathExtras

internal import WebCore_Private.Core.CSSCalcSwiftTypes

// This file holds Style::Calculation's side of the calculation trees (StyleCalculationTree.cpp and its +Conversion,
// +Evaluation and +Substitution files): conversion from and to a CSSCalc::Tree, evaluation, the combinations
// animation uses, the calc-size() substitutions, and the TextStream dump. Evaluation, the depth, the combinations and
// the conversion to a CSSCalc tree read the records they are given in place. The other functions decode them into a
// StyleCalcNode or CalcNode tree, which they own for the call only, and write any tree they make back as records.

// MARK: - Conversion from a CSSCalc tree

/// Writes the Style::Calculation tree of the simplification of `nodes` to `output`: `toStyle(const CSSCalc::Tree&)`.
func toStyleImpl(
    _ nodes: Span<WebCore.CSSCalcNodeRecord>,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    _ output: inout WebCore.StyleCalcSwiftOutput,
    _ options: WebCore.CSSCalcSwiftSimplificationOptions
) {
    withCalcArena(holding: nodes.count) { arena in
        _ = calcSimplify(nodes, into: &arena, &resolver, options)
        assert(arena.span.isCalcTree)
        let simplified = CalcNode(decoding: arena.span)
        let tree = styleCalcNode(simplified, &resolver, hasConversionData: options.hasConversionData != 0)
        tree.encode(into: &output)
    }
}

/// `toStyle(const CSSCalc::Child&)`.
///
/// The children are converted in order, the way `toStyle(const CSSCalc::IndirectNode<Op>&)` constructs each operation:
/// a random()'s base value is resolved before its arguments, and a calc-mix() item's weight before its value, since
/// both read caches the builder state keeps.
private func styleCalcNode(
    _ node: borrowing CalcNode,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    hasConversionData: Bool
) -> StyleCalcNode {
    switch node.kind {
    case .Number:
        return .number(node.value)
    case .Percentage:
        return .percentage(node.value)
    case .CanonicalDimension:
        // A canonical length is in px; the other canonical dimensions are kept as they are.
        guard node.unit == UInt16(WebCore.CSSUnitType.Px.rawValue) else {
            return .dimension(node.value)
        }
        return .dimension(styleLength(node.value, &resolver, hasConversionData: hasConversionData))
    case .Symbol:
        // `size` is the one symbol the tree holds, since it resolves at used value time rather than during
        // conversion. Simplification resolves every other symbol, so `toStyle(const CSSCalc::Symbol&)` asserts and
        // gives 0 for one.
        if node.symbolID == UInt16(WebCore.CSSValueID.Size.rawValue) {
            return .size()
        }
        return .number(0)
    case .NonCanonicalDimension, .SiblingCount, .SiblingIndex, .Anchor, .AnchorSize:
        // Resolved by simplification with conversion data. `toStyle` asserts and gives 0 for one that is left, without
        // converting its arguments.
        return .number(0)
    case .Deg2Rad:
        // The tree has no Deg2Rad node, so the conversion multiplies by the radians-per-degree constant.
        let angle = styleCalcNode(node.children[0], &resolver, hasConversionData: hasConversionData)
        return .operation(.Product, angle, .number(radiansPerDegreeDouble))
    case .Random:
        let baseValue = randomBaseValue(node, &resolver)
        let min = styleCalcNode(node.children[0], &resolver, hasConversionData: hasConversionData)
        let max = styleCalcNode(node.children[1], &resolver, hasConversionData: hasConversionData)
        var step: StyleCalcNode? = nil
        if let index = node.optionalArgumentIndex {
            step = styleCalcNode(node.children[index], &resolver, hasConversionData: hasConversionData)
        }
        return .random(baseValue: baseValue, min: min, max: max, step: step)
    case .CalcMix:
        var items = UniqueArray<StyleCalcNode>(capacity: node.children.count)
        for i in 0..<node.children.count {
            let weight = calcMixWeight(node.children[i], &resolver)
            let value = styleCalcNode(node.children[i].children[0], &resolver, hasConversionData: hasConversionData)
            items.append(.calcMixItem(value, weight: weight))
        }
        return .operation(.CalcMix, children: items)
    case .Clamp:
        var min: StyleCalcNode? = nil
        if let index = node.clampMinIndex {
            min = styleCalcNode(node.children[index], &resolver, hasConversionData: hasConversionData)
        }
        let value = styleCalcNode(node.children[node.clampValueIndex], &resolver, hasConversionData: hasConversionData)
        var max: StyleCalcNode? = nil
        if let index = node.clampMaxIndex {
            max = styleCalcNode(node.children[index], &resolver, hasConversionData: hasConversionData)
        }
        return .clamp(min: min, value: value, max: max)
    case .RoundNearest, .RoundUp, .RoundDown, .RoundToZero, .Log:
        let a = styleCalcNode(node.children[0], &resolver, hasConversionData: hasConversionData)
        var b: StyleCalcNode? = nil
        if let index = node.optionalArgumentIndex {
            b = styleCalcNode(node.children[index], &resolver, hasConversionData: hasConversionData)
        }
        guard let kind = styleCalcKind(node.kind) else {
            preconditionFailure()
        }
        return node.kind == .Log ? .log(a, base: b) : .round(kind, a, interval: b)
    default:
        // A calc-mix() item is converted with its calc-mix(); a decoded tree has one nowhere else.
        guard let kind = styleCalcKind(node.kind), kind != .CalcMixItem else {
            preconditionFailure()
        }
        var children = UniqueArray<StyleCalcNode>(capacity: node.children.count)
        for i in 0..<node.children.count {
            children.append(styleCalcNode(node.children[i], &resolver, hasConversionData: hasConversionData))
        }
        return .operation(kind, children: children)
    }
}

/// `resolveLength(value, CSS::LengthUnit::Px, ...)` of a canonical length: with conversion data, with the text zoom
/// of the property; without, the value itself, as `NoConversionDataRequiredToken` resolves px.
private func styleLength(_ value: Double, _ resolver: inout WebCore.CSSCalcSwiftResolver, hasConversionData: Bool) -> Double {
    guard hasConversionData else {
        return value
    }
    return resolver.resolveStyleLength(value)
}

/// `toStyle(const CSSCalc::Random::Sharing&)`: a raw `fixed` number as it is, and any other sharing through the
/// builder state's cache, 0 where that has no value.
private func randomBaseValue(_ node: borrowing CalcNode, _ resolver: inout WebCore.CSSCalcSwiftResolver) -> Double {
    if node.unit == UInt16(WebCore.CSSUnitType.Number.rawValue) {
        return node.value
    }
    // The resolver has no value only without an element where the sharing is element-scoped, which style building
    // never asks for; `toStyle(const CSSCalc::Random::Sharing&)` asserts that and gives 0.
    return resolver.resolveRandomBaseValue(node.payload).value
}

/// The weight of the calc-mix() item `item`, as `Style::toStyle` gives the percentage.
private func calcMixWeight(_ item: borrowing CalcNode, _ resolver: inout WebCore.CSSCalcSwiftResolver) -> Double {
    // A weight the simplifier normalised has no payload yet: a raw percentage, which Style::toStyle clamps to
    // CSS::ClosedPercentageRange as WTF::clampTo does.
    if item.unit == UInt16(WebCore.CSSUnitType.Percentage.rawValue) && item.payload == CalcNode.noPayload {
        let weight = item.value
        if weight >= 100 {
            return 100
        }
        if weight <= 0 {
            return 0
        }
        return weight
    }
    // An item that survives simplification without a weight is one whose calc-mix() has a weight simplification
    // cannot resolve. `toStyle(const CSSCalc::CalcMix::Item&)` reads its empty std::optional weight, which hardened
    // libc++ traps on; the precondition below traps there too.
    precondition(item.payload != CalcNode.noPayload)
    return resolver.resolveCalcMixWeight(item.payload).value
}

/// The Style::Calculation kind of the CSSCalc operation `kind`, which has the same arguments; nil for a CSSCalc
/// kind the style tree does not have.
private func styleCalcKind(_ kind: CalcKind) -> StyleCalcKind? {
    switch kind {
    case .Number: return .Number
    case .Percentage: return .Percentage
    case .Sum: return .Sum
    case .Product: return .Product
    case .Negate: return .Negate
    case .Invert: return .Invert
    case .Min: return .Min
    case .Max: return .Max
    case .Clamp: return .Clamp
    case .RoundNearest: return .RoundNearest
    case .RoundUp: return .RoundUp
    case .RoundDown: return .RoundDown
    case .RoundToZero: return .RoundToZero
    case .Mod: return .Mod
    case .Rem: return .Rem
    case .Sin: return .Sin
    case .Cos: return .Cos
    case .Tan: return .Tan
    case .Asin: return .Asin
    case .Acos: return .Acos
    case .Atan: return .Atan
    case .Atan2: return .Atan2
    case .Pow: return .Pow
    case .Sqrt: return .Sqrt
    case .Hypot: return .Hypot
    case .Log: return .Log
    case .Exp: return .Exp
    case .Abs: return .Abs
    case .Sign: return .Sign
    case .Random: return .Random
    case .Progress: return .Progress
    case .ProgressNoClamp: return .ProgressNoClamp
    case .CalcMix: return .CalcMix
    case .CalcMixItem: return .CalcMixItem
    default: return nil
    }
}

// MARK: - Conversion to a CSSCalc tree

/// Writes the CSSCalc tree of the Style::Calculation tree `nodes` to `output`, and returns its type:
/// `toCSS(const Tree&, const ToCSSOptions&)`.
func toCSSImpl(
    _ nodes: Span<WebCore.StyleCalcNodeRecord>,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    _ output: inout WebCore.CSSCalcSwiftOutput,
    category: UInt8
) -> UInt64 {
    guard let cssCategory = WebCore.CSS.Category(rawValue: category) else {
        preconditionFailure()
    }
    var conversion = CSSCalcConversion(
        canonicalUnit: canonicalUnit(cssCategory),
        percentHint: CalcType.percentHint(cssCategory),
        simplification: WebCore.CSSCalcSwiftSimplificationOptions(
            category: category,
            hasConversionData: 0,
            allowZeroValueLengthRemovalFromSum: 1
        )
    )
    return withCalcArena(holding: nodes.count) { arena in
        var index = 0
        conversion.convert(nodes, at: &index, &arena, &resolver, &output)
        precondition(index == nodes.count)
        if conversion.madeWeights {
            calcWritePendingWeights(&arena, at: 0, &output)
        }
        assert(arena.span.isCalcTree)
        output.adopt(arena.span)
        return arena.type(0).bits
    }
}

/// `determineCanonicalDimension`: lengths for <length-percentage>, angles for <angle-percentage>. The tree holds no
/// other category; `determineCanonicalDimension` asserts and takes lengths for one.
private func canonicalUnit(_ category: WebCore.CSS.Category) -> WebCore.CSSUnitType {
    category == .AnglePercentage ? .Deg : .Px
}

/// `toCSS(const Child&, const ToCSSConversionOptions&)`.
private struct CSSCalcConversion {
    let canonicalUnit: WebCore.CSSUnitType
    /// `Type::determinePercentHint(category)`'s raw value.
    let percentHint: UInt8
    let simplification: WebCore.CSSCalcSwiftSimplificationOptions
    /// The records of a percentage and of a dimension in the canonical unit, with value 0.
    private let percentageLeaf: CalcRecord
    private let dimensionLeaf: CalcRecord
    /// Some calc-mix() item has a weight made by the simplifier (`calcWritePendingWeights`).
    private(set) var madeWeights = false

    init(canonicalUnit: WebCore.CSSUnitType, percentHint: UInt8, simplification: WebCore.CSSCalcSwiftSimplificationOptions) {
        self.canonicalUnit = canonicalUnit
        self.percentHint = percentHint
        self.simplification = simplification
        percentageLeaf = .percentage(0, hint: percentHint)
        dimensionLeaf = .canonicalDimension(0, unit: canonicalUnit)
    }

    /// Appends the CSSCalc tree of the subtree of `records` at `index` to `arena`, and advances `index` past it.
    /// Each operation is built from its converted arguments, in order, and simplified as it is made; a leaf is not
    /// simplified. A random()'s fixed base value is appended to the payloads before its arguments are converted, and a
    /// calc-mix() item's weight after its value.
    mutating func convert(
        _ records: Span<WebCore.StyleCalcNodeRecord>,
        at index: inout Int,
        _ arena: inout CalcArena,
        _ resolver: inout WebCore.CSSCalcSwiftResolver,
        _ output: inout WebCore.CSSCalcSwiftOutput
    ) {
        let node = records.styleCalcNode(at: index)
        index &+= 1 // index < records.count: the record was read.
        switch node.kind {
        case .Number:
            arena.append(.number(node.value))
        case .Percentage:
            var record = percentageLeaf
            record.value = node.value
            arena.append(record)
        case .Dimension:
            var record = dimensionLeaf
            record.value = node.value
            arena.append(record)
        case .Size:
            arena.append(.symbol(UInt16(WebCore.CSSValueID.Size.rawValue), unit: .Px))
        default:
            convertOperation(records, node, at: &index, &arena, &resolver, &output)
        }
    }

    /// `convert` of the operation `node`, whose first child `index` is at. Its record is kept in its place while its
    /// children are converted.
    @inline(never)
    private mutating func convertOperation(
        _ records: Span<WebCore.StyleCalcNodeRecord>,
        _ node: StyleCalcRecordNode,
        at index: inout Int,
        _ arena: inout CalcArena,
        _ resolver: inout WebCore.CSSCalcSwiftResolver,
        _ output: inout WebCore.CSSCalcSwiftOutput
    ) {
        let start = arena.reserveNode()
        switch node.kind {
        case .Random:
            convertRandom(records, node, at: &index, start, &arena, &resolver, &output)
        case .CalcMix:
            convertCalcMix(records, node, at: &index, start, &arena, &resolver, &output)
        case .Clamp:
            convertChildren(records, at: &index, node, &arena, &resolver, &output)
            let flags = (node.minIsNone ? CalcNodeFlags.minIsNone : 0) | (node.maxIsNone ? CalcNodeFlags.maxIsNone : 0)
            simplified(start, .operation(.Clamp, type: .number, childCount: node.childCount, flags: flags), &arena, &resolver)
        default:
            // A calc-mix() item is converted with its calc-mix(); a tree has one nowhere else.
            guard let kind = calcKind(node.kind), kind != .CalcMixItem else {
                preconditionFailure()
            }
            convertChildren(records, at: &index, node, &arena, &resolver, &output)
            var flags: UInt8 = 0
            if kind == .Log || kind.isRound {
                flags = node.hasOptionalArgument ? 0 : CalcNodeFlags.optionalAbsent
            }
            simplified(start, .operation(kind, type: .number, childCount: node.childCount, flags: flags), &arena, &resolver)
        }
    }

    @inline(never)
    private mutating func convertRandom(
        _ records: Span<WebCore.StyleCalcNodeRecord>,
        _ node: StyleCalcRecordNode,
        at index: inout Int,
        _ start: Int,
        _ arena: inout CalcArena,
        _ resolver: inout WebCore.CSSCalcSwiftResolver,
        _ output: inout WebCore.CSSCalcSwiftOutput
    ) {
        // `Random::SharingFixed { baseValue }`: a raw `fixed` number, which the record holds as the parser writes
        // one, with unit Number and the number as its value.
        let sharing = output.appendRandomFixed(node.value)
        convertChildren(records, at: &index, node, &arena, &resolver, &output)
        let random = CalcRecord.operation(
            .Random,
            type: .number,
            childCount: node.childCount,
            flags: node.hasOptionalArgument ? 0 : CalcNodeFlags.optionalAbsent,
            unit: UInt16(WebCore.CSSUnitType.Number.rawValue),
            payload: sharing,
            value: node.value
        )
        simplified(start, random, &arena, &resolver)
    }

    @inline(never)
    private mutating func convertCalcMix(
        _ records: Span<WebCore.StyleCalcNodeRecord>,
        _ node: StyleCalcRecordNode,
        at index: inout Int,
        _ start: Int,
        _ arena: inout CalcArena,
        _ resolver: inout WebCore.CSSCalcSwiftResolver,
        _ output: inout WebCore.CSSCalcSwiftOutput
    ) {
        while index < node.end {
            let item = records.styleCalcNode(at: index)
            index &+= 1 // index < records.count: the record was read.
            let itemStart = arena.reserveNode()
            convert(records, at: &index, &arena, &resolver, &output)
            precondition(index == item.end)
            // A raw percentage weight, which the record holds as the parser writes one, with unit Percentage and the
            // weight as its value.
            let record = CalcRecord.operation(
                .CalcMixItem,
                type: .number,
                childCount: 1,
                unit: UInt16(WebCore.CSSUnitType.Percentage.rawValue),
                payload: output.appendCalcMixWeight(item.value),
                value: item.value
            )
            arena.setNode(at: itemStart, record)
        }
        simplified(start, .operation(.CalcMix, type: .number, childCount: node.childCount), &arena, &resolver)
    }

    /// Converts the children of `node`, whose first child `index` is at, in order.
    private mutating func convertChildren(
        _ records: Span<WebCore.StyleCalcNodeRecord>,
        at index: inout Int,
        _ node: StyleCalcRecordNode,
        _ arena: inout CalcArena,
        _ resolver: inout WebCore.CSSCalcSwiftResolver,
        _ output: inout WebCore.CSSCalcSwiftOutput
    ) {
        while index < node.end {
            convert(records, at: &index, &arena, &resolver, &output)
        }
    }

    /// Makes the records after `start`, reserved by `reserveNode`, the children of `record`, an operation made with a
    /// placeholder type, which simplification of the operation does not read; replaces it with what
    /// `CSSCalc::simplify(op, options)` gives, or else gives it the type `toType` gives it.
    ///
    /// Each operation this makes has the type `toType` gives it, and so has every operation a replacement can be (an
    /// argument, or the min() or max() a clamp() becomes), so an operation is given `toType`'s type whether or not it
    /// was replaced.
    private mutating func simplified(
        _ start: Int,
        _ record: CalcRecord,
        _ arena: inout CalcArena,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) {
        arena.setNode(at: start, record)
        var simplifier = CalcSimplifier(simplification)
        simplifier.simplify(start, &arena, &resolver)
        madeWeights = madeWeights || simplifier.madeWeights
        guard !arena.kind(start).isLeaf else {
            return
        }
        // An operation over a style tree's arguments always has a type; `toCSS(const IndirectNode<CalculationOp>&)`
        // dereferences the std::optional.
        guard let type = calcOperationType(start, arena) else {
            preconditionFailure()
        }
        arena[start].typeBits = type.bits
    }
}

/// The CSSCalc kind of the Style::Calculation operation `kind`; nil for a leaf, which has no single counterpart.
private func calcKind(_ kind: StyleCalcKind) -> CalcKind? {
    switch kind {
    case .Sum: return .Sum
    case .Product: return .Product
    case .Negate: return .Negate
    case .Invert: return .Invert
    case .Min: return .Min
    case .Max: return .Max
    case .Clamp: return .Clamp
    case .RoundNearest: return .RoundNearest
    case .RoundUp: return .RoundUp
    case .RoundDown: return .RoundDown
    case .RoundToZero: return .RoundToZero
    case .Mod: return .Mod
    case .Rem: return .Rem
    case .Sin: return .Sin
    case .Cos: return .Cos
    case .Tan: return .Tan
    case .Asin: return .Asin
    case .Acos: return .Acos
    case .Atan: return .Atan
    case .Atan2: return .Atan2
    case .Pow: return .Pow
    case .Sqrt: return .Sqrt
    case .Hypot: return .Hypot
    case .Log: return .Log
    case .Exp: return .Exp
    case .Abs: return .Abs
    case .Sign: return .Sign
    case .Progress: return .Progress
    case .ProgressNoClamp: return .ProgressNoClamp
    case .Random: return .Random
    case .CalcMix: return .CalcMix
    case .CalcMixItem: return .CalcMixItem
    default: return nil
    }
}

// MARK: - Evaluation

/// The value of the Style::Calculation tree `nodes`: `evaluate(const Tree&, const EvaluationOptions&)`.
func evaluateImpl(
    _ nodes: Span<WebCore.StyleCalcNodeRecord>,
    percentResolutionLength: Double,
    usedZoom: Double,
    sizeResolutionLength: Double
) -> Double {
    let evaluation = StyleCalcEvaluation(
        percentResolutionLength: percentResolutionLength,
        usedZoom: usedZoom,
        sizeResolutionLength: sizeResolutionLength
    )
    var index = 0
    let value = evaluation.evaluate(nodes, at: &index)
    precondition(index == nodes.count)
    return value
}

/// Evaluation over the tree's records in place. Each operation's children are evaluated in order, each from where the
/// one before it ends, as the executors ask for them.
private struct StyleCalcEvaluation {
    let percentResolutionLength: Double
    let usedZoom: Double
    let sizeResolutionLength: Double

    /// The value of the subtree whose record is `records[index]`; `index` moves past the subtree.
    func evaluate(_ records: Span<WebCore.StyleCalcNodeRecord>, at index: inout Int) -> Double {
        let node = records.styleCalcNode(at: index)
        index &+= 1 // The first child; index < records.count.
        defer {
            index = node.end
        }
        switch node.kind {
        case .Number:
            // A number is dimensionless, so zoom does not apply.
            return node.value
        case .Percentage:
            return percentResolutionLength * node.value / 100.0
        case .Dimension:
            return node.value * usedZoom
        case .Size:
            // Already a used value, so no zoom applies, as for percentResolutionLength.
            return sizeResolutionLength
        case .Sum:
            return CalcExecutor.sum(count: node.childCount) { _ in evaluate(records, at: &index) }
        case .Product:
            return CalcExecutor.product(count: node.childCount) { _ in evaluate(records, at: &index) }
        case .Min:
            return CalcExecutor.min(count: node.childCount) { _ in evaluate(records, at: &index) }
        case .Max:
            return CalcExecutor.max(count: node.childCount) { _ in evaluate(records, at: &index) }
        case .Hypot:
            return CalcExecutor.hypot(count: node.childCount) { _ in evaluate(records, at: &index) }
        case .Negate:
            return CalcExecutor.negate(evaluate(records, at: &index))
        case .Invert:
            return CalcExecutor.invert(evaluate(records, at: &index))
        case .Clamp:
            var min: Double? = nil
            if !node.minIsNone {
                min = evaluate(records, at: &index)
            }
            let value = evaluate(records, at: &index)
            var max: Double? = nil
            if !node.maxIsNone {
                max = evaluate(records, at: &index)
            }
            return CalcExecutor.clamp(min, value, max)
        case .RoundNearest, .RoundUp, .RoundDown, .RoundToZero:
            guard let strategy = CalcRoundingStrategy(node.kind) else {
                preconditionFailure()
            }
            let a = evaluate(records, at: &index)
            return CalcExecutor.round(strategy, a, optionalArgument(node, records, at: &index))
        case .Log:
            let a = evaluate(records, at: &index)
            return CalcExecutor.log(a, optionalArgument(node, records, at: &index))
        case .Mod:
            let a = evaluate(records, at: &index)
            return CalcExecutor.mod(a, evaluate(records, at: &index))
        case .Rem:
            let a = evaluate(records, at: &index)
            return CalcExecutor.rem(a, evaluate(records, at: &index))
        case .Atan2:
            let a = evaluate(records, at: &index)
            return CalcExecutor.atan2(a, evaluate(records, at: &index))
        case .Pow:
            let a = evaluate(records, at: &index)
            return CalcExecutor.pow(a, evaluate(records, at: &index))
        case .Sin:
            return CalcExecutor.sin(evaluate(records, at: &index))
        case .Cos:
            return CalcExecutor.cos(evaluate(records, at: &index))
        case .Tan:
            return CalcExecutor.tan(evaluate(records, at: &index))
        case .Asin:
            return CalcExecutor.asin(evaluate(records, at: &index))
        case .Acos:
            return CalcExecutor.acos(evaluate(records, at: &index))
        case .Atan:
            return CalcExecutor.atan(evaluate(records, at: &index))
        case .Sqrt:
            return CalcExecutor.sqrt(evaluate(records, at: &index))
        case .Exp:
            return CalcExecutor.exp(evaluate(records, at: &index))
        case .Abs:
            return CalcExecutor.abs(evaluate(records, at: &index))
        case .Sign:
            return CalcExecutor.sign(evaluate(records, at: &index))
        case .Progress, .ProgressNoClamp:
            let value = evaluate(records, at: &index)
            let start = evaluate(records, at: &index)
            let end = evaluate(records, at: &index)
            return node.kind == .Progress ? CalcExecutor.progress(value, start, end) : CalcExecutor.progressNoClamp(value, start, end)
        case .Random:
            let min = evaluate(records, at: &index)
            let max = evaluate(records, at: &index)
            return CalcExecutor.random(node.value, min, max, optionalArgument(node, records, at: &index))
        case .CalcMix:
            // Every child is a calc-mix() item, whose one child is its value.
            return CalcExecutor.calcMix(count: node.childCount) { _ in
                let weight = records[index].value
                index &+= 1 // The item's value.
                return (value: evaluate(records, at: &index), percentage: weight)
            }
        case .CalcMixItem:
            // Evaluated with its calc-mix(); a tree has one nowhere else.
            preconditionFailure()
        @unknown default:
            preconditionFailure()
        }
    }

    /// The value of round()'s interval, log()'s base or random()'s step, the last child of `node`, which `index` is
    /// at; nil when it is absent.
    private func optionalArgument(
        _ node: StyleCalcRecordNode,
        _ records: Span<WebCore.StyleCalcNodeRecord>,
        at index: inout Int
    ) -> Double? {
        guard node.hasOptionalArgument else {
            return nil
        }
        return evaluate(records, at: &index)
    }
}

// MARK: - Combination

/// Writes `a` and `b` combined by the StyleCalcCombination `combination` to `output`: `add`, `subtract`, `multiply`
/// and `blend`. The result's records are those of the operations the combination makes, in pre-order, around `a`'s and
/// `b`'s records as they are. A combination of up to 16 records is written on the stack, a larger one into a heap
/// buffer.
func combineImpl(
    _ combination: UInt8,
    _ a: Span<WebCore.StyleCalcNodeRecord>,
    _ b: Span<WebCore.StyleCalcNodeRecord>,
    progress: Double,
    _ output: inout WebCore.StyleCalcSwiftOutput
) {
    guard let combination = WebCore.StyleCalcCombination(rawValue: combination) else {
        preconditionFailure()
    }
    // Each is a whole tree: the subtree of its first record is all of its records.
    precondition(a.styleCalcNode(at: 0).end == a.count && b.styleCalcNode(at: 0).end == b.count)
    let count = a.count + b.count + combinationRecordCount(combination)
    guard count <= 16 else {
        combineOnHeap(combination, a, b, progress: progress, count, &output)
        return
    }
    var scratch = [16 of WebCore.StyleCalcNodeRecord](repeating: WebCore.StyleCalcNodeRecord())
    do {
        var records = scratch.mutableSpan
        writeCombination(combination, a, b, progress: progress, into: &records)
    }
    output.adopt(scratch.span.extracting(0..<count))
}

@inline(never)
private func combineOnHeap(
    _ combination: WebCore.StyleCalcCombination,
    _ a: Span<WebCore.StyleCalcNodeRecord>,
    _ b: Span<WebCore.StyleCalcNodeRecord>,
    progress: Double,
    _ count: Int,
    _ output: inout WebCore.StyleCalcSwiftOutput
) {
    var storage = UniqueArray<WebCore.StyleCalcNodeRecord>(repeating: WebCore.StyleCalcNodeRecord(), count: count)
    do {
        var records = storage.mutableSpan
        writeCombination(combination, a, b, progress: progress, into: &records)
    }
    output.adopt(storage.span)
}

/// The records `combination` adds around its operands.
private func combinationRecordCount(_ combination: WebCore.StyleCalcCombination) -> Int {
    switch combination {
    case .Add, .Multiply:
        return 1
    case .Subtract:
        return 2
    case .Blend:
        return 5
    @unknown default:
        preconditionFailure()
    }
}

/// Writes the records of `combination` of `a` and `b` to the start of `records`: `Sum(a, b)`, `Sum(a, Negate(b))`,
/// `Product(a, b)` or `Sum(Product(a, 1 - progress), Product(b, progress))`.
private func writeCombination(
    _ combination: WebCore.StyleCalcCombination,
    _ a: Span<WebCore.StyleCalcNodeRecord>,
    _ b: Span<WebCore.StyleCalcNodeRecord>,
    progress: Double,
    into records: inout MutableSpan<WebCore.StyleCalcNodeRecord>
) {
    var next = 0
    let count = a.count + b.count + combinationRecordCount(combination)
    switch combination {
    case .Add:
        writeRecord(.Sum, subtreeSize: count, into: &records, at: &next)
        writeRecords(a, into: &records, at: &next)
        writeRecords(b, into: &records, at: &next)
    case .Subtract:
        writeRecord(.Sum, subtreeSize: count, into: &records, at: &next)
        writeRecords(a, into: &records, at: &next)
        writeRecord(.Negate, subtreeSize: 1 + b.count, into: &records, at: &next)
        writeRecords(b, into: &records, at: &next)
    case .Multiply:
        writeRecord(.Product, subtreeSize: count, into: &records, at: &next)
        writeRecords(a, into: &records, at: &next)
        writeRecords(b, into: &records, at: &next)
    case .Blend:
        writeRecord(.Sum, subtreeSize: count, into: &records, at: &next)
        writeRecord(.Product, subtreeSize: 2 + a.count, into: &records, at: &next)
        writeRecords(a, into: &records, at: &next)
        writeRecord(.Number, subtreeSize: 1, value: 1 - progress, into: &records, at: &next)
        writeRecord(.Product, subtreeSize: 2 + b.count, into: &records, at: &next)
        writeRecords(b, into: &records, at: &next)
        writeRecord(.Number, subtreeSize: 1, value: progress, into: &records, at: &next)
    @unknown default:
        preconditionFailure()
    }
}

/// Writes one record, of a node with no flags, at `next`, and advances `next` past it.
private func writeRecord(
    _ kind: StyleCalcKind,
    subtreeSize: Int,
    value: Double = 0,
    into records: inout MutableSpan<WebCore.StyleCalcNodeRecord>,
    at next: inout Int
) {
    // A tree has far fewer than 2^32 records, so the size does not truncate.
    records[next] = WebCore.StyleCalcNodeRecord(
        kind: kind.rawValue,
        flags: 0,
        reserved: 0,
        subtreeSize: UInt32(truncatingIfNeeded: subtreeSize),
        value: value
    )
    next &+= 1 // next < records.count: records[next] was written.
}

/// Copies `tree`'s records to `records` at `next`, and advances `next` past them.
private func writeRecords(
    _ tree: Span<WebCore.StyleCalcNodeRecord>,
    into records: inout MutableSpan<WebCore.StyleCalcNodeRecord>,
    at next: inout Int
) {
    for i in 0..<tree.count {
        records[next] = tree[i]
        next &+= 1 // next < records.count: records[next] was written.
    }
}

// MARK: - Substitution

/// computeNodeCount's bound on a substituted tree, `maximumCalcSizeNodeCount` (pinned in
/// StyleCalculationTree+Substitution.cpp).
private let maximumCalcSizeNodeCount: UInt = 1024

/// substituteSize's bound on computeDepth of the substituted tree.
private let maximumSubstitutionTreeDepth: UInt = 128

/// Writes `nodes` with every `size` replaced by `insertion` to `output`; false, writing nothing, when the result would
/// have more than `maximumCalcSizeNodeCount` nodes or be deeper than `maximumSubstitutionTreeDepth`.
func substituteSizeImpl(
    _ nodes: Span<WebCore.StyleCalcNodeRecord>,
    _ insertion: Span<WebCore.StyleCalcNodeRecord>,
    _ output: inout WebCore.StyleCalcSwiftOutput
) -> Bool {
    let tree = StyleCalcNode(decoding: nodes)
    let insertionTree = StyleCalcNode(decoding: insertion)
    let occurrences = recordCount(nodes, of: .Size)
    if occurrences == 0 {
        // A copy of the tree, whose records are the tree's.
        output.adopt(nodes)
        return true
    }
    // Avoid constructing an oversized tree in the first place. The size_t arithmetic wraps, as substituteSize's does;
    // the node count is at least the number of `size` leaves in it, so the subtraction does not, and a wrapped count
    // would pass the bound below, which needs more than 2^64 nodes.
    let predictedNodeCount = (styleNodeCount(nodes) &- occurrences) &+ occurrences &* styleNodeCount(insertion)
    if predictedNodeCount > maximumCalcSizeNodeCount {
        return false
    }
    let result = substitutingSize(tree, insertionTree)
    if styleDepth(result) > maximumSubstitutionTreeDepth {
        return false
    }
    result.encode(into: &output)
    return true
}

/// Writes `nodes` with every percentage P replaced by `size * (P / 100)` to `output`: `dePercentify`.
func dePercentifyImpl(_ nodes: Span<WebCore.StyleCalcNodeRecord>, _ output: inout WebCore.StyleCalcSwiftOutput) {
    let tree = StyleCalcNode(decoding: nodes)
    dePercentified(tree).encode(into: &output)
}

/// The records of `kind` in `nodes`: with `.Size`, `countSizeLeaves`.
private func recordCount(_ nodes: Span<WebCore.StyleCalcNodeRecord>, of kind: StyleCalcKind) -> UInt {
    var total: UInt = 0
    for i in 0..<nodes.count where nodes[i].kind == kind.rawValue {
        total &+= 1 // At most nodes.count.
    }
    return total
}

/// A copy of `node` with every `size` replaced by a copy of `insertion`: `mapLeaves`.
private func substitutingSize(_ node: borrowing StyleCalcNode, _ insertion: borrowing StyleCalcNode) -> StyleCalcNode {
    if node.kind == .Size {
        return insertion.copied()
    }
    var children = UniqueArray<StyleCalcNode>(capacity: node.children.count)
    for i in 0..<node.children.count {
        children.append(substitutingSize(node.children[i], insertion))
    }
    return StyleCalcNode(kind: node.kind, flags: node.flags, value: node.value, children: children)
}

/// A copy of `node` with every percentage P replaced by `size * (P / 100)`: `mapLeaves`. A calc-mix() item's weight
/// is not a leaf.
private func dePercentified(_ node: borrowing StyleCalcNode) -> StyleCalcNode {
    if node.kind == .Percentage {
        return .operation(.Product, .size(), .number(node.value / 100.0))
    }
    var children = UniqueArray<StyleCalcNode>(capacity: node.children.count)
    for i in 0..<node.children.count {
        children.append(dePercentified(node.children[i]))
    }
    return StyleCalcNode(kind: node.kind, flags: node.flags, value: node.value, children: children)
}

extension StyleCalcNode {
    /// A copy of the tree: `copy(const Child&)`.
    fileprivate func copied() -> StyleCalcNode {
        var copies = UniqueArray<StyleCalcNode>(capacity: children.count)
        for i in 0..<children.count {
            copies.append(children[i].copied())
        }
        return StyleCalcNode(kind: kind, flags: flags, value: value, children: copies)
    }
}

// MARK: - Detection and counting
//
// Style::Calculation's C++ tree has no calc-mix() item node: an item's value is a child of its calc-mix(), and its
// weight a double that is not. So these walks count an item's value at the item's place and do not count the item.

/// The depth of the tree `nodes`: `computeDepth`, a leaf being 1.
func depthImpl(_ nodes: Span<WebCore.StyleCalcNodeRecord>) -> UInt {
    var index = 0
    let depth = styleDepth(nodes, at: &index)
    precondition(index == nodes.count)
    return depth
}

/// The depth of the subtree whose record is `records[index]`; `index` moves past the subtree.
private func styleDepth(_ records: Span<WebCore.StyleCalcNodeRecord>, at index: inout Int) -> UInt {
    let node = records.styleCalcNode(at: index)
    index &+= 1 // The first child; index < records.count.
    if node.kind == .CalcMixItem {
        return styleDepth(records, at: &index)
    }
    var deepest: UInt = 0
    while index < node.end {
        deepest = Swift.max(deepest, styleDepth(records, at: &index))
    }
    // At most the tree's record count, which is far below UInt.max.
    return deepest &+ 1
}

private func styleDepth(_ node: borrowing StyleCalcNode) -> UInt {
    if node.kind == .CalcMixItem {
        return styleDepth(node.children[0])
    }
    var deepest: UInt = 0
    for i in 0..<node.children.count {
        deepest = Swift.max(deepest, styleDepth(node.children[i]))
    }
    // At most the tree's record count, which is far below UInt.max.
    return deepest &+ 1
}

/// The nodes of the tree `nodes`: `computeNodeCount`.
private func styleNodeCount(_ nodes: Span<WebCore.StyleCalcNodeRecord>) -> UInt {
    // The items are at most all of the records.
    UInt(nodes.count) &- recordCount(nodes, of: .CalcMixItem)
}

// MARK: - Dumping

/// Writes the tree `nodes` to `sink`'s TextStream: `operator<<(TextStream&, const Tree&)`.
func dumpImpl(_ nodes: Span<WebCore.StyleCalcNodeRecord>, _ sink: inout WebCore.StyleCalcSwiftDumpSink) {
    dump(StyleCalcNode(decoding: nodes), &sink)
}

private func append(_ text: Swift.String, _ sink: inout WebCore.StyleCalcSwiftDumpSink) {
    sink.appendLatin1(text.utf8.span)
}

/// `operator<<(TextStream&, const Child&)`.
private func dump(_ node: borrowing StyleCalcNode, _ sink: inout WebCore.StyleCalcSwiftDumpSink) {
    switch node.kind {
    case .Number, .Dimension:
        sink.appendNumber(node.value, true)
    case .Percentage:
        sink.appendNumber(node.value, true)
        append("%", &sink)
    case .Size:
        append("size", &sink)
    case .Sum:
        dumpVariadic(node, prefix: "", between: " + ", &sink)
    case .Product:
        dumpVariadic(node, prefix: "", between: " * ", &sink)
    case .Negate:
        append("-(", &sink)
        dump(node.children[0], &sink)
        append(")", &sink)
    case .Invert:
        append("1.0 / (", &sink)
        dump(node.children[0], &sink)
        append(")", &sink)
    case .Min:
        dumpVariadic(node, prefix: "min", between: " * ", &sink)
    case .Max:
        dumpVariadic(node, prefix: "max", between: " * ", &sink)
    case .Hypot:
        dumpVariadic(node, prefix: "hypot", between: ", ", &sink)
    case .CalcMixItem:
        // Written with its calc-mix(); a decoded tree has one nowhere else.
        preconditionFailure()
    default:
        dumpOperation(node, &sink)
    }
}

/// `dumpVariadic`.
private func dumpVariadic(
    _ node: borrowing StyleCalcNode,
    prefix: Swift.String,
    between: Swift.String,
    _ sink: inout WebCore.StyleCalcSwiftDumpSink
) {
    append(prefix, &sink)
    append("(", &sink)
    for i in 0..<node.children.count {
        if i > 0 {
            append(between, &sink)
        }
        dump(node.children[i], &sink)
    }
    append(")", &sink)
}

/// `operator<<(TextStream&, const IndirectNode<Op>&)`: `Op::op`, then each of the operation's fields, in declaration
/// order: a `none` clamp() bound as `none`, an absent optional argument not at all, random()'s fixed base value as
/// `fixed <value>`, and each calc-mix() item's value and then its weight.
private func dumpOperation(_ node: borrowing StyleCalcNode, _ sink: inout WebCore.StyleCalcSwiftDumpSink) {
    sink.appendOperator(calcOperator(node.kind))
    append("(", &sink)
    var first = true
    func separate(_ sink: inout WebCore.StyleCalcSwiftDumpSink) {
        if !first {
            append(", ", &sink)
        }
        first = false
    }
    switch node.kind {
    case .Random:
        separate(&sink)
        append("fixed ", &sink)
        sink.appendNumber(node.value, false)
        for i in 0..<node.children.count {
            separate(&sink)
            dump(node.children[i], &sink)
        }
    case .Clamp:
        if node.minIsNone {
            separate(&sink)
            append("none", &sink)
        }
        for i in 0..<node.children.count {
            separate(&sink)
            dump(node.children[i], &sink)
        }
        if node.maxIsNone {
            separate(&sink)
            append("none", &sink)
        }
    case .CalcMix:
        for i in 0..<node.children.count {
            separate(&sink)
            dump(node.children[i].children[0], &sink)
            separate(&sink)
            sink.appendNumber(node.children[i].value, false)
        }
    default:
        for i in 0..<node.children.count {
            separate(&sink)
            dump(node.children[i], &sink)
        }
    }
    append(")", &sink)
}

/// `Op::op` of a kind `dumpOperation` writes.
private func calcOperator(_ kind: StyleCalcKind) -> WebCore.CSSCalc.Operator {
    switch kind {
    case .Clamp: return .Clamp
    case .RoundNearest: return .RoundNearest
    case .RoundUp: return .RoundUp
    case .RoundDown: return .RoundDown
    case .RoundToZero: return .RoundToZero
    case .Mod: return .Mod
    case .Rem: return .Rem
    case .Sin: return .Sin
    case .Cos: return .Cos
    case .Tan: return .Tan
    case .Asin: return .Asin
    case .Acos: return .Acos
    case .Atan: return .Atan
    case .Atan2: return .Atan2
    case .Pow: return .Pow
    case .Sqrt: return .Sqrt
    case .Log: return .Log
    case .Exp: return .Exp
    case .Abs: return .Abs
    case .Sign: return .Sign
    case .Progress: return .Progress
    case .ProgressNoClamp: return .ProgressNoClamp
    case .Random: return .Random
    case .CalcMix: return .CalcMix
    default:
        // Every other kind is written by `dump` itself.
        preconditionFailure()
    }
}
