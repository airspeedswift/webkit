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

// The simplification of a calculation tree (CSSCalcTree+Simplification.cpp): CSSCalc::simplify of each node, which
// the parser calls as it builds, and CSSCalc::copyAndSimplify of a whole tree. Both work on a `CalcArena`, on the
// node that is its last subtree.

// MARK: - The weights and keys the payloads cannot tell

/// A calc-mix() item's weight, as the item records it.
enum CalcMixWeight {
    case omitted
    /// A <percentage>, and the payload holding it, or `CalcNode.noPayload` when the simplifier made it and no payload
    /// holds it yet.
    case raw(Double, payload: UInt32)
    /// A math function, in the payload.
    case calc(payload: UInt32)

    /// The weight of the calc-mix() item whose record has `unit`, `value` and `payload`.
    init(unit: UInt16, value: Double, payload: UInt32) {
        if unit == CalcNode.rawWeightUnit {
            self = .raw(value, payload: payload)
        } else if payload == CalcNode.noPayload {
            self = .omitted
        } else {
            self = .calc(payload: payload)
        }
    }

    /// The weight of the calc-mix() item `item`.
    init(_ item: CalcRecord) {
        precondition(item.kind == CalcKind.CalcMixItem.rawValue)
        self.init(unit: item.unit, value: item.value, payload: item.payload)
    }
}

extension CalcNode {
    /// A CalcMixItem's `unit` when its weight is a <percentage>, whose value `value` holds.
    static var rawWeightUnit: UInt16 { UInt16(WebCore.CSSUnitType.Percentage.rawValue) }

    /// A CalcMixItem's `unit` when its weight is a math function, and a Random's when its sharing is `fixed` with a
    /// math function.
    static var calcValueUnit: UInt16 { UInt16(WebCore.CSSUnitType.Calc.rawValue) }
}

/// Writes each calc-mix() weight the simplifier made in the subtree at `index` to `output`'s payloads, children
/// before their parents, and names it from its item.
func calcWritePendingWeights(_ arena: inout CalcArena, at index: Int, _ output: inout WebCore.CSSCalcSwiftOutput) {
    let end = arena.end(index)
    var child = index &+ 1 // index < arena.count.
    while child < end {
        calcWritePendingWeights(&arena, at: child, &output)
        child = arena.end(child)
    }
    let record = arena[index]
    if record.kind == CalcKind.CalcMixItem.rawValue, record.unit == CalcNode.rawWeightUnit, record.payload == CalcNode.noPayload {
        arena[index].payload = output.appendCalcMixWeight(record.value)
    }
}

// MARK: - Numeric identities

/// `toNumericIdentity`: what a numeric leaf merges with in a sum, min() and max(): every number, every percentage
/// whatever its hint, and each dimension's unit.
private func calcNumericIdentity(_ leaf: CalcRecord) -> UInt16 {
    switch CalcKind(rawValue: leaf.kind) {
    case .Number:
        return UInt16(WebCore.CSSUnitType.Number.rawValue)
    case .Percentage:
        return UInt16(WebCore.CSSUnitType.Percentage.rawValue)
    case .CanonicalDimension, .NonCanonicalDimension:
        return leaf.unit
    default:
        preconditionFailure()
    }
}

/// `isLength(NumericIdentity)`: px and the non-canonical length units.
private func calcIsLength(_ identity: UInt16) -> Bool {
    guard let unit = WebCore.CSSUnitType(rawValue: UInt8(truncatingIfNeeded: identity)), UInt16(unit.rawValue) == identity else {
        return false
    }
    switch unit {
    case .Px, .Cm, .Mm, .Q, .In, .Pt, .Pc, .Em, .Ex, .Lh, .Cap, .Ch, .Ic, .Rcap, .Rch, .Rem, .Rex, .Ric, .Rlh,
        .Vw, .Vh, .Vmin, .Vmax, .Vb, .Vi, .Svw, .Svh, .Svmin, .Svmax, .Svb, .Svi, .Lvw, .Lvh, .Lvmin, .Lvmax, .Lvb, .Lvi,
        .Dvw, .Dvh, .Dvmin, .Dvmax, .Dvb, .Dvi, .Cqw, .Cqh, .Cqi, .Cqb, .Cqmin, .Cqmax:
        return true
    default:
        return false
    }
}

/// A set of a node's child indices, one bit per child: the first 64 in a word, the rest in words that only a node
/// of more than 64 children allocates.
private struct CalcChildSet: ~Copyable {
    private var low: UInt64 = 0
    private var high: UniqueArray<UInt64>

    init(childCount: Int) {
        high = childCount > 64 ? CalcChildSet.highWords(childCount) : UniqueArray()
    }

    @inline(never)
    private static func highWords(_ childCount: Int) -> UniqueArray<UInt64> {
        UniqueArray(repeating: 0, count: (childCount &- 1) / 64) // childCount > 64: no wrap.
    }

    func contains(_ i: Int) -> Bool {
        let bit: UInt64 = 1 << UInt64(truncatingIfNeeded: i % 64)
        return (i < 64 ? low : high[i / 64 &- 1]) & bit != 0 // i >= 64 on the right: no wrap.
    }

    mutating func insert(_ i: Int) {
        let bit: UInt64 = 1 << UInt64(truncatingIfNeeded: i % 64)
        if i < 64 {
            low |= bit
        } else {
            high[i / 64 &- 1] |= bit // i >= 64: no wrap.
        }
    }
}

/// The first instance of each numeric identity among a node's children, in child order: each child's index and the
/// index of its record. The first ones are held in the caller's buffer, on the stack, and the rest in an array that
/// only a node with more identities than the buffer holds allocates.
struct CalcFirstInstances: ~Copyable, ~Escapable {
    private var inline: MutableSpan<UInt64>
    private var more = UniqueArray<UInt64>()
    private(set) var count = 0

    @_lifetime(copy buffer)
    init(_ buffer: consuming MutableSpan<UInt64>) {
        inline = buffer
    }

    /// Child `i` of the node, with its record at `record`.
    mutating func append(child i: Int, record: Int) {
        // A tree has far fewer than 2^32 nodes, so both fit their halves.
        let entry = UInt64(truncatingIfNeeded: record) << 32 | UInt64(truncatingIfNeeded: i)
        if count < inline.count {
            inline[count] = entry
        } else {
            more.append(entry)
        }
        count &+= 1 // At most the node's children.
    }

    private func entry(_ k: Int) -> UInt64 {
        k < inline.count ? inline[k] : more[k &- inline.count] // k >= inline.count on the right: no wrap.
    }

    /// The child index of the `k`th first instance.
    func child(_ k: Int) -> Int {
        Int(truncatingIfNeeded: entry(k) & 0xffff_ffff)
    }

    /// The record index of the `k`th first instance.
    func record(_ k: Int) -> Int {
        Int(truncatingIfNeeded: entry(k) >> 32)
    }
}

// MARK: - Unit canonicalization

/// `canonicalize`: the canonical dimension a non-canonical one converts to, nil when that needs conversion data
/// and there is none.
func calcCanonicalize(
    _ value: Double,
    _ unit: WebCore.CSSUnitType,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    hasConversionData: Bool
) -> CalcRecord? {
    guard let canonical = calcCanonicalValue(value, unit, &resolver, hasConversionData: hasConversionData) else {
        return nil
    }
    return .canonicalDimension(canonical.value, unit: canonical.unit)
}

/// The value and canonical unit of `calcCanonicalize`'s dimension.
func calcCanonicalValue(
    _ value: Double,
    _ unit: WebCore.CSSUnitType,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    hasConversionData: Bool
) -> (value: Double, unit: WebCore.CSSUnitType)? {
    switch unit {
    // Absolute lengths.
    case .Cm:
        return (value * WebCore.CSS.pixelsPerCm, .Px)
    case .Mm:
        return (value * WebCore.CSS.pixelsPerMm, .Px)
    case .Q:
        return (value * WebCore.CSS.pixelsPerQ, .Px)
    case .In:
        return (value * WebCore.CSS.pixelsPerInch, .Px)
    case .Pt:
        return (value * WebCore.CSS.pixelsPerPt, .Px)
    case .Pc:
        return (value * WebCore.CSS.pixelsPerPc, .Px)

    // Font, viewport and container relative lengths, which need conversion data.
    case .Em, .Ex, .Lh, .Cap, .Ch, .Ic, .Rcap, .Rch, .Rem, .Rex, .Ric, .Rlh, .Vw, .Vh, .Vmin, .Vmax, .Vb, .Vi,
        .Svw, .Svh, .Svmin, .Svmax, .Svb, .Svi, .Lvw, .Lvh, .Lvmin, .Lvmax, .Lvb, .Lvi, .Dvw, .Dvh, .Dvmin, .Dvmax,
        .Dvb, .Dvi, .Cqw, .Cqh, .Cqi, .Cqb, .Cqmin, .Cqmax:
        guard hasConversionData else {
            return nil
        }
        return (resolver.resolveLength(value, UInt16(unit.rawValue)), .Px)

    case .Rad:
        return (value * degreesPerRadianDouble, .Deg)
    case .Grad:
        return (value * degreesPerGradientDouble, .Deg)
    case .Turn:
        return (value * degreesPerTurnDouble, .Deg)
    case .Ms:
        return (value * WebCore.CSS.secondsPerMillisecond, .S)
    case .Khz:
        return (value * WebCore.CSS.hertzPerKilohertz, .Hz)
    case .X:
        return (value * WebCore.CSS.dppxPerX, .Dppx)
    case .Dpi:
        return (value * WebCore.CSS.dppxPerDpi, .Dppx)
    case .Dpcm:
        return (value * WebCore.CSS.dppxPerDpcm, .Dppx)

    // Canonical, non-dimensional and non-numeric units are never stored in a NonCanonicalDimension.
    default:
        return nil
    }
}

/// The CSSUnitType of a Number, CanonicalDimension, NonCanonicalDimension or Symbol record.
private func calcUnitType(_ record: CalcRecord) -> WebCore.CSSUnitType {
    guard let unitType = WebCore.CSSUnitType(rawValue: UInt8(truncatingIfNeeded: record.unit)) else {
        preconditionFailure()
    }
    return unitType
}

// MARK: - The simplifier

/// `CSSCalc::SimplificationOptions`, without the conversion data and symbol table, which the resolver holds; and
/// whether a calc-mix() weight has been made that no payload holds yet.
struct CalcSimplifier {
    let category: WebCore.CSS.Category
    let hasConversionData: Bool
    let allowZeroValueLengthRemovalFromSum: Bool
    /// Some calc-mix() item has a weight made by the simplifier (`calcWritePendingWeights`).
    var madeWeights = false

    init(_ options: WebCore.CSSCalcSwiftSimplificationOptions) {
        guard let category = WebCore.CSS.Category(rawValue: options.category) else {
            preconditionFailure()
        }
        self.category = category
        hasConversionData = options.hasConversionData != 0
        allowZeroValueLengthRemovalFromSum = options.allowZeroValueLengthRemovalFromSum != 0
    }

    // MARK: Predicates

    /// `percentageResolveToDimension`.
    var percentageResolvesToDimension: Bool {
        category == .AnglePercentage || category == .LengthPercentage
    }

    /// `unitsMatch` of two numeric leaves of the same kind.
    func unitsMatch(_ a: CalcRecord, _ b: CalcRecord) -> Bool {
        switch CalcKind(rawValue: a.kind) {
        case .Number, .Percentage:
            return true
        default:
            return a.unit == b.unit
        }
    }

    /// `magnitudeComparable` of a numeric leaf.
    func magnitudeComparable(_ a: CalcRecord) -> Bool {
        a.kind == CalcKind.Percentage.rawValue ? !percentageResolvesToDimension : true
    }

    /// `fullyResolved` of a numeric leaf.
    func fullyResolved(_ a: CalcRecord) -> Bool {
        switch CalcKind(rawValue: a.kind) {
        case .Percentage:
            return !percentageResolvesToDimension
        case .NonCanonicalDimension:
            return false
        default:
            return true
        }
    }

    /// The percentage `Type::determinePercentHint` gives the context.
    func contextPercentage(_ value: Double) -> CalcRecord {
        .percentage(value, hint: CalcType.percentHint(category))
    }

    /// The leaf of `category` with `value`, in its canonical unit, as Product and CalcMix simplification make it.
    func leaf(_ value: Double, ofCategory category: WebCore.CSS.Category) -> CalcRecord {
        switch category {
        case .Integer, .Number:
            return .number(value)
        case .Percentage:
            return contextPercentage(value)
        case .LengthPercentage:
            return .percentage(value, hint: WebCore.CSSCalc.PercentHint.Length.rawValue)
        case .Length:
            return .canonicalDimension(value, unit: .Px)
        case .Angle:
            return .canonicalDimension(value, unit: .Deg)
        case .AnglePercentage:
            return .percentage(value, hint: WebCore.CSSCalc.PercentHint.Angle.rawValue)
        case .Time:
            return .canonicalDimension(value, unit: .S)
        case .Frequency:
            return .canonicalDimension(value, unit: .Hz)
        case .Resolution:
            return .canonicalDimension(value, unit: .Dppx)
        case .Flex:
            return .canonicalDimension(value, unit: .Fr)
        @unknown default:
            preconditionFailure()
        }
    }

    // MARK: Copy and simplify

    /// `copyAndSimplify(const Child&)`: appends the subtree of `records` at `index` to `arena`, its children
    /// simplified before it, and advances `index` past it.
    mutating func copyAndSimplify(
        _ records: Span<CalcRecord>,
        at index: inout Int,
        _ arena: inout CalcArena,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) {
        let record = records[index]
        let node = records.calcNode(record, at: index)
        let start = arena.count
        arena.append(record)
        index &+= 1 // index < records.count: records[index] was read.
        switch node.kind {
        case .Number, .Percentage, .CanonicalDimension:
            // Simplification leaves these leaves as they are, and a leaf's subtree is its record.
            return
        case .Anchor:
            // The side is copied, not simplified.
            if node.anchorSideIsChild {
                arena.append(records, at: &index)
            }
            if index < node.end {
                copyAndSimplify(records, at: &index, &arena, &resolver)
            }
        case .CalcMix:
            while index < node.end {
                let item = arena.count
                let itemRecord = records[index]
                _ = records.calcNode(itemRecord, at: index)
                arena.append(itemRecord)
                index &+= 1 // index < records.count: records[index] was read.
                copyAndSimplify(records, at: &index, &arena, &resolver)
                arena.closeSubtree(item)
            }
        default:
            while index < node.end {
                copyAndSimplify(records, at: &index, &arena, &resolver)
            }
        }
        arena.closeSubtree(start)
        simplify(start, &arena, &resolver)
    }

    // MARK: Simplify one node

    /// `simplify(Op&)` of the node at `index`, the last subtree of `arena`: replaces it with what it simplifies to, or
    /// leaves it, possibly with its children changed, where `simplify(Op&)` returns std::nullopt.
    mutating func simplify(_ index: Int, _ arena: inout CalcArena, _ resolver: inout WebCore.CSSCalcSwiftResolver) {
        let kind = arena.kind(index)
        switch kind {
        case .Number, .Percentage, .CanonicalDimension, .CalcMixItem:
            return
        case .NonCanonicalDimension:
            simplifyNonCanonicalDimension(index, &arena, &resolver)
        case .Sum:
            simplifySum(index, &arena)
        case .Product:
            simplifyProduct(index, &arena)
        case .Negate:
            simplifyNegate(index, &arena)
        case .Min, .Max:
            simplifyMinMax(index, &arena)
        case .Clamp:
            simplifyClamp(index, &arena)
        default:
            simplifyOther(index, kind, &arena, &resolver)
        }
    }

    @inline(never)
    private func simplifyNonCanonicalDimension(_ index: Int, _ arena: inout CalcArena, _ resolver: inout WebCore.CSSCalcSwiftResolver) {
        let record = arena[index]
        if let canonical = calcCanonicalize(record.value, calcUnitType(record), &resolver, hasConversionData: hasConversionData) {
            arena.replace(index, with: canonical)
        }
    }

    /// `simplify` of the symbols, sibling-count(), sibling-index() and the operations other than sums, products,
    /// negations, min(), max() and clamp().
    @inline(never)
    private mutating func simplifyOther(
        _ index: Int,
        _ kind: CalcKind,
        _ arena: inout CalcArena,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) {
        let record = arena[index]
        switch kind {
        case .Symbol:
            guard let symbolID = UInt16(exactly: record.childCount) else {
                preconditionFailure()
            }
            let symbol = resolver.resolveSymbol(symbolID)
            if symbol.ok != 0 {
                arena.replace(index, with: .numeric(symbol.value, unit: calcUnitType(record)))
                simplify(index, &arena, &resolver)
            }
            return
        case .SiblingCount, .SiblingIndex:
            guard hasConversionData else {
                return
            }
            let result = kind == .SiblingCount ? resolver.siblingCount() : resolver.siblingIndex()
            if result.ok != 0 {
                arena.replace(index, with: .number(result.value))
            }
            return
        case .Hypot:
            simplifyHypot(index, &arena)
            return
        case .Random:
            simplifyRandom(index, &arena, &resolver)
            return
        case .CalcMix:
            simplifyCalcMix(index, &arena, &resolver)
            return
        case .Anchor:
            simplifyAnchor(index, &arena, &resolver)
            return
        case .AnchorSize:
            simplifyAnchorSize(index, &arena, &resolver)
            return
        default:
            break
        }

        // The other operations read their arguments, the first at index + 1, and replace the node with a leaf.
        let a = index &+ 1 // index < arena.count.
        let first = arena[a]
        let firstKind = arena.kind(a)
        switch kind {
        case .Invert:
            switch firstKind {
            case .Number:
                arena.replace(index, with: .number(CalcExecutor.invert(first.value)))
            case .Invert:
                arena.replace(index, withSubtreeAt: a &+ 1) // The Invert at a has a child.
            default:
                return
            }
        case .Deg2Rad:
            if firstKind == .CanonicalDimension {
                arena.replace(index, with: .number(CalcExecutor.deg2rad(first.value)))
            }
        case .RoundNearest, .RoundUp, .RoundDown, .RoundToZero:
            guard let strategy = CalcRoundingStrategy(kind) else {
                preconditionFailure()
            }
            if arena.optionalArgumentIndex(index) != nil {
                simplifyForOperation(index, &arena) { CalcExecutor.round(strategy, $0, $1) }
            } else if firstKind == .Number {
                arena.replace(index, with: .number(CalcExecutor.round(strategy, first.value, 1.0)))
            }
        case .Mod:
            simplifyForOperation(index, &arena) { CalcExecutor.mod($0, $1) }
        case .Rem:
            simplifyForOperation(index, &arena) { CalcExecutor.rem($0, $1) }
        case .Sin, .Cos, .Tan:
            guard firstKind == .Number else {
                return
            }
            let x = first.value
            arena.replace(
                index,
                with: .number(kind == .Sin ? CalcExecutor.sin(x) : kind == .Cos ? CalcExecutor.cos(x) : CalcExecutor.tan(x))
            )
        case .Asin, .Acos, .Atan:
            guard firstKind == .Number else {
                return
            }
            let x = first.value
            let degrees = kind == .Asin ? CalcExecutor.asin(x) : kind == .Acos ? CalcExecutor.acos(x) : CalcExecutor.atan(x)
            arena.replace(index, with: .canonicalDimension(degrees, unit: .Deg))
        case .Atan2:
            let second = arena[arena.end(a)]
            guard firstKind.rawValue == second.kind, firstKind.isNumeric, unitsMatch(first, second), fullyResolved(first) else {
                return
            }
            arena.replace(index, with: .canonicalDimension(CalcExecutor.atan2(first.value, second.value), unit: .Deg))
        case .Pow:
            let second = arena[arena.end(a)]
            if firstKind == .Number, second.kind == CalcKind.Number.rawValue {
                arena.replace(index, with: .number(CalcExecutor.pow(first.value, second.value)))
            }
        case .Sqrt:
            if firstKind == .Number {
                arena.replace(index, with: .number(CalcExecutor.sqrt(first.value)))
            }
        case .Log:
            if arena.optionalArgumentIndex(index) != nil {
                let second = arena[arena.end(a)]
                if firstKind == .Number, second.kind == CalcKind.Number.rawValue {
                    arena.replace(index, with: .number(CalcExecutor.log(first.value, second.value)))
                }
            } else if firstKind == .Number {
                arena.replace(index, with: .number(CalcExecutor.log(first.value)))
            }
        case .Exp:
            if firstKind == .Number {
                arena.replace(index, with: .number(CalcExecutor.exp(first.value)))
            }
        case .Abs:
            if firstKind.isNumeric, magnitudeComparable(first) {
                arena.replace(index, with: .numeric(CalcExecutor.abs(first.value), basedOn: first))
            }
        case .Sign:
            if firstKind.isNumeric, magnitudeComparable(first) {
                arena.replace(index, with: .number(CalcExecutor.sign(first.value)))
            }
        case .Progress, .ProgressNoClamp:
            let b = arena.end(a)
            let start = arena[b]
            let end = arena[arena.end(b)]
            guard firstKind.isNumeric, start.kind == firstKind.rawValue, end.kind == firstKind.rawValue,
                unitsMatch(first, start), unitsMatch(start, end), fullyResolved(first)
            else {
                return
            }
            let value = first.value
            arena.replace(
                index,
                with: .number(
                    kind == .Progress
                        ? CalcExecutor.progress(value, start.value, end.value) : CalcExecutor.progressNoClamp(value, start.value, end.value)
                )
            )
        default:
            preconditionFailure()
        }
    }

    /// `simplifyForOperation`: two numeric leaves of the same kind and unit, the first fully resolved, give a leaf
    /// like the first.
    private func simplifyForOperation(_ index: Int, _ arena: inout CalcArena, _ operation: (Double, Double) -> Double) {
        let a = index &+ 1 // index < arena.count.
        let first = arena[a]
        let second = arena[arena.end(a)]
        guard first.kind == second.kind, arena.kind(a).isNumeric, unitsMatch(first, second), fullyResolved(first) else {
            return
        }
        arena.replace(index, with: .numeric(operation(first.value, second.value), basedOn: first))
    }

    // MARK: Sum

    private func simplifySum(_ index: Int, _ arena: inout CalcArena) {
        // 8.1. For each of root's children that are Sum nodes, replace them with their children.
        arena.flattenChildren(of: index, .Sum)

        // 8.2. Combine the numeric children with identical units into one with their sum. 8.3. If one child is
        // left, return it.
        let count = arena.childCount(index)
        if count == 1 {
            arena.replace(index, withSubtreeAt: index &+ 1) // index < arena.count.
            return
        }

        // Each numeric child merges into the first child with its identity, in child order. `firsts` holds the
        // first instances, and `removed` the children the merges remove and the first instances that are zero lengths.
        var firstsBuffer = [8 of UInt64](repeating: 0)
        var firsts = CalcFirstInstances(firstsBuffer.mutableSpan)
        var removed = CalcChildSet(childCount: count)
        var childrenToRemoveFromMerges = 0
        var child = index &+ 1 // index < arena.count.
        for i in 0..<count {
            let record = arena[child]
            if arena.kind(child).isNumeric {
                let identity = calcNumericIdentity(record)
                var k = 0
                while k < firsts.count && calcNumericIdentity(arena[firsts.record(k)]) != identity {
                    k &+= 1 // At most firsts.count.
                }
                if k < firsts.count {
                    let first = firsts.record(k)
                    arena[first].value = CalcExecutor.sum(arena[first].value, record.value)
                    removed.insert(i)
                    childrenToRemoveFromMerges &+= 1 // At most count.
                } else {
                    firsts.append(child: i, record: child)
                }
            }
            child = arena.end(child)
        }

        var childrenToRemoveTotal = childrenToRemoveFromMerges
        if allowZeroValueLengthRemovalFromSum {
            for k in 0..<firsts.count {
                let first = arena[firsts.record(k)]
                if calcIsLength(calcNumericIdentity(first)) && first.value == 0 {
                    removed.insert(firsts.child(k))
                    childrenToRemoveTotal &+= 1 // At most count.
                }
            }
        }
        if childrenToRemoveTotal == 0 {
            return
        }

        // All the merges left a single child: everything merged into the first.
        if count - childrenToRemoveFromMerges == 1 {
            arena.replace(index, withSubtreeAt: index &+ 1) // index < arena.count.
            return
        }

        let combinedChildrenSize = count - childrenToRemoveTotal
        // Too much was removed; only lengths are removed, so a zero length keeps the sum valid.
        if combinedChildrenSize == 0 {
            arena.replace(index, with: .canonicalDimension(0, unit: .Px))
            return
        }

        if combinedChildrenSize == 1 {
            var child = index &+ 1 // index < arena.count.
            for i in 0..<count {
                if !removed.contains(i) {
                    arena.replace(index, withSubtreeAt: child)
                    return
                }
                child = arena.end(child)
            }
        }

        arena.retainChildren(of: index) { i, _ in !removed.contains(i) }
    }

    // MARK: Product

    private func simplifyProduct(_ index: Int, _ arena: inout CalcArena) {
        // 9.1. Replace Product children with their children, and 9.2. replace the numbers with one number, their
        // product, after the other children.
        arena.flattenChildren(of: index, .Product)
        var numericProduct: Double? = nil
        arena.retainChildren(of: index) { _, record in
            guard record.kind == CalcKind.Number.rawValue else {
                return true
            }
            if let value = numericProduct {
                numericProduct = record.value * value
            } else {
                numericProduct = record.value
            }
            return false
        }

        if let product = numericProduct {
            let count = arena.childCount(index)
            if count == 0 {
                arena.replace(index, with: .number(product))
                return
            }

            // 9.3. A number and a Sum of numeric values: multiply the Sum's children by the number. Extended to a
            // numeric value and to an Invert of one.
            if count == 1 {
                let child = index &+ 1 // index < arena.count.
                switch arena.kind(child) {
                case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
                    arena.replace(index, with: .numeric(arena.value(child) * product, basedOn: arena[child]))
                    return
                case .Sum:
                    if arena.allChildrenNumeric(child) {
                        var grandchild = child &+ 1 // child < arena.count.
                        for _ in 0..<arena.childCount(child) {
                            arena[grandchild].value *= product
                            grandchild = arena.end(grandchild)
                        }
                        arena.replace(index, withSubtreeAt: child)
                        return
                    }
                case .Invert:
                    let operand = child &+ 1 // The Invert at child has a child.
                    if arena.kind(operand).isNumeric {
                        arena.replace(index, with: .numeric(arena.value(operand) * product, basedOn: arena[operand]))
                        return
                    }
                default:
                    break
                }
            }

            arena.append(.number(product))
            arena.setChildren(of: index, count: count &+ 1) // At most the tree's nodes.
        }

        // 9.4. Numeric values and Inverts of them whose types multiply to a type a math function can resolve to:
        // return their product in the canonical unit.
        var value = 1.0
        var type = CalcType.number
        var success = false
        var child = index &+ 1 // index < arena.count.
        for _ in 0..<arena.childCount(index) {
            success = multiply(child, arena, &value, &type)
            if !success {
                break
            }
            child = arena.end(child)
        }
        if success, let category = type.calculationCategory() {
            arena.replace(index, with: leaf(value, ofCategory: category))
        }
    }

    /// Multiplies `value` and `type` by a Product's child at `child`, for 9.4; false when it is not a numeric value
    /// or an Invert of one, or the types do not multiply.
    private func multiply(_ child: Int, _ arena: borrowing CalcArena, _ value: inout Double, _ type: inout CalcType) -> Bool {
        switch arena.kind(child) {
        case .Number:
            value *= arena.value(child)
            return true
        case .Percentage, .CanonicalDimension:
            guard let multiplied = type.multiplying(arena.type(child)) else {
                return false
            }
            type = multiplied
            value *= arena.value(child)
            return true
        case .Invert:
            let operand = child &+ 1 // The Invert at child has a child.
            let a = arena.kind(operand)
            if a == .Number {
                value /= arena.value(operand)
                return true
            }
            guard a == .Percentage || a == .CanonicalDimension, let inverted = arena.type(operand).inverted(),
                let multiplied = type.multiplying(inverted)
            else {
                return false
            }
            type = multiplied
            value /= arena.value(operand)
            return true
        default:
            return false
        }
    }

    // MARK: Negate

    private func simplifyNegate(_ index: Int, _ arena: inout CalcArena) {
        let child = index &+ 1 // index < arena.count.
        switch arena.kind(child) {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            // 6.1. Unary negation, so that negating +0 gives -0.
            arena.replace(index, with: .numeric(-arena.value(child), basedOn: arena[child]))
        case .Negate:
            // 6.2. A Negate of a Negate is its grandchild.
            arena.replace(index, withSubtreeAt: child &+ 1) // child < arena.count.
        case .Sum:
            guard arena.allChildrenNumeric(child) else {
                return
            }
            var grandchild = child &+ 1 // child < arena.count.
            for _ in 0..<arena.childCount(child) {
                arena[grandchild].value = -arena[grandchild].value
                grandchild = arena.end(grandchild)
            }
            arena.replace(index, withSubtreeAt: child)
        case .Product:
            guard arena.allChildrenNumeric(child) else {
                return
            }
            let grandchild = child &+ 1 // A Product has children.
            arena[grandchild].value = -arena[grandchild].value
            arena.replace(index, withSubtreeAt: child)
        default:
            return
        }
    }

    // MARK: Min and max

    private func simplifyMinMax(_ index: Int, _ arena: inout CalcArena) {
        let isMin = arena.kind(index) == .Min
        let count = arena.childCount(index)

        if count == 1 {
            arena.replace(index, withSubtreeAt: index &+ 1) // index < arena.count.
            return
        }

        // 5.1. Combine the numeric children with the same unit whose magnitudes compare. 5.2. If one child is
        // left, return it.
        var firstsBuffer = [8 of UInt64](repeating: 0)
        var firsts = CalcFirstInstances(firstsBuffer.mutableSpan)
        var removed = CalcChildSet(childCount: count)
        let canMergePercentages = !percentageResolvesToDimension
        var numberOfMergeOpportunities = 0
        var child = index &+ 1 // index < arena.count.
        for i in 0..<count {
            let record = arena[child]
            let kind = arena.kind(child)
            if kind.isNumeric && (kind != .Percentage || canMergePercentages) {
                let identity = calcNumericIdentity(record)
                var k = 0
                while k < firsts.count && calcNumericIdentity(arena[firsts.record(k)]) != identity {
                    k &+= 1 // At most firsts.count.
                }
                if k < firsts.count {
                    let first = firsts.record(k)
                    let (a, b) = (arena[first].value, record.value)
                    arena[first].value = isMin ? CalcExecutor.min(a, b) : CalcExecutor.max(a, b)
                    removed.insert(i)
                    numberOfMergeOpportunities &+= 1 // At most count.
                } else {
                    firsts.append(child: i, record: child)
                }
            }
            child = arena.end(child)
        }

        if numberOfMergeOpportunities == 0 {
            return
        }

        if count - numberOfMergeOpportunities == 1 {
            arena.replace(index, withSubtreeAt: index &+ 1) // index < arena.count.
            return
        }

        arena.retainChildren(of: index) { i, _ in !removed.contains(i) }
    }

    // MARK: Clamp

    private func simplifyClamp(_ index: Int, _ arena: inout CalcArena) {
        let flags = arena[index].flags
        let minIsNone = flags & CalcNodeFlags.minIsNone != 0
        let maxIsNone = flags & CalcNodeFlags.maxIsNone != 0

        // clamp(none, VAL, none) is calc(VAL).
        if minIsNone && maxIsNone {
            arena.replace(index, withSubtreeAt: index &+ 1) // index < arena.count.
            return
        }

        let a = index &+ 1 // index < arena.count.
        let b = arena.end(a)
        let value = minIsNone ? a : b
        let kind = arena.kind(value)
        guard kind.isNumeric else {
            return
        }
        let first = arena[a]
        let second = arena[b]

        if minIsNone {
            // clamp(none, VAL, MAX) is min(VAL, MAX).
            if second.kind == kind.rawValue, unitsMatch(first, second), magnitudeComparable(first) {
                arena.replace(index, with: .numeric(CalcExecutor.min(first.value, second.value), basedOn: first))
            } else {
                convert(index, &arena, to: .Min)
            }
        } else if maxIsNone {
            // clamp(MIN, VAL, none) is max(MIN, VAL).
            if first.kind == kind.rawValue, unitsMatch(first, second), magnitudeComparable(second) {
                arena.replace(index, with: .numeric(CalcExecutor.max(first.value, second.value), basedOn: second))
            } else {
                convert(index, &arena, to: .Max)
            }
        } else {
            // All three with the same unit clamp in full.
            let third = arena[arena.end(b)]
            guard first.kind == kind.rawValue, third.kind == kind.rawValue, unitsMatch(first, second), unitsMatch(second, third),
                magnitudeComparable(second)
            else {
                return
            }
            arena.replace(index, with: .numeric(CalcExecutor.clamp(first.value, second.value, third.value), basedOn: second))
        }
    }

    /// clamp() with one bound `none` as min() (VAL, MAX) or max() (MIN, VAL), whose type is `toType` of it.
    ///
    /// Where the two types are not consistent, `simplify(Clamp&)` has already moved the operands out of the clamp() it
    /// leaves; the clamp() is left whole here instead.
    private func convert(_ index: Int, _ arena: inout CalcArena, to kind: CalcKind) {
        let a = index &+ 1 // index < arena.count.
        guard let type = arena.type(a).consistent(with: arena.type(arena.end(a))) else {
            return
        }
        var record = CalcRecord.operation(kind, type: type, childCount: 2)
        record.subtreeSize = arena[index].subtreeSize
        arena[index] = record
    }

    // MARK: hypot()

    private enum HypotTag: Equatable {
        case none
        case number
        case percentage
        case dimension(UInt16)
        case failure
    }

    private func simplifyHypot(_ index: Int, _ arena: inout CalcArena) {
        var tag = HypotTag.none
        let percentageFails = percentageResolvesToDimension
        // The executor reads the operands in order, so each is the one after the last.
        var child = index &+ 1 // index < arena.count.
        var next = 0
        let value = CalcExecutor.hypot(count: arena.childCount(index)) { i in
            precondition(i == next)
            next &+= 1 // At most the child count.
            let record = arena[child]
            child = arena.end(child)
            let kind = CalcKind(rawValue: record.kind)
            switch tag {
            case .none:
                switch kind {
                case .Number:
                    tag = .number
                case .Percentage:
                    if percentageFails {
                        tag = .failure
                        return .nan
                    }
                    tag = .percentage
                case .CanonicalDimension:
                    tag = .dimension(record.unit)
                default:
                    tag = .failure
                    return .nan
                }
                return record.value
            case .number:
                if kind == .Number {
                    return record.value
                }
            case .percentage:
                if kind == .Percentage {
                    return record.value
                }
            case .dimension(let unit):
                if kind == .CanonicalDimension && record.unit == unit {
                    return record.value
                }
            case .failure:
                return .nan
            }
            tag = .failure
            return .nan
        }

        switch tag {
        case .number:
            arena.replace(index, with: .number(value))
        case .percentage:
            arena.replace(index, with: contextPercentage(value))
        case .dimension(let unit):
            guard let unitType = WebCore.CSSUnitType(rawValue: UInt8(truncatingIfNeeded: unit)) else {
                preconditionFailure()
            }
            arena.replace(index, with: .canonicalDimension(value, unit: unitType))
        case .none, .failure:
            return
        }
    }

    // MARK: random()

    private func simplifyRandom(_ index: Int, _ arena: inout CalcArena, _ resolver: inout WebCore.CSSCalcSwiftResolver) {
        guard hasConversionData, resolver.hasStyleBuilderState() else {
            return
        }
        let a = index &+ 1 // index < arena.count.
        let b = arena.end(a)
        let first = arena[a]
        let second = arena[b]
        let kind = arena.kind(a)
        let hasStep = arena.optionalArgumentIndex(index) != nil
        let stepRecord = hasStep ? arena[arena.end(b)] : first
        guard second.kind == kind.rawValue, stepRecord.kind == kind.rawValue, kind.isNumeric, unitsMatch(first, second),
            fullyResolved(first)
        else {
            return
        }
        var step: Double? = nil
        if hasStep {
            guard unitsMatch(first, stepRecord) else {
                return
            }
            step = stepRecord.value
        }

        // A fixed value that is a math function needs evaluation; every other sharing, a fixed <number> included,
        // resolves through the style builder.
        let node = arena[index]
        guard node.unit != CalcNode.calcValueUnit else {
            return
        }
        let base = resolver.resolveRandomBaseValue(node.payload)
        guard base.ok != 0 else {
            return
        }
        arena.replace(index, with: .numeric(CalcExecutor.random(base.value, first.value, second.value, step), basedOn: first))
    }

    // MARK: calc-mix()

    /// The zero of the type of a calc-mix() item's value, which the calc-mix() is when every weight is zero.
    private func zeroValue(matching item: Int, _ arena: borrowing CalcArena) -> CalcRecord {
        // `zeroValueMatchingChild` dereferences the category unchecked; a type with none stops the process here.
        guard let category = arena.type(item &+ 1).calculationCategory() else { // An item has a child.
            preconditionFailure()
        }
        return leaf(0, ofCategory: category)
    }

    private mutating func simplifyCalcMix(_ index: Int, _ arena: inout CalcArena, _ resolver: inout WebCore.CSSCalcSwiftResolver) {
        let count = arena.childCount(index)
        var canNormalize = true
        var numberOfKnownZeroWeights = 0
        var item = index &+ 1 // index < arena.count.
        for _ in 0..<count {
            switch CalcMixWeight(arena[item]) {
            case .omitted:
                break
            case .raw(let weight, _):
                if weight == 0 {
                    numberOfKnownZeroWeights += 1
                }
            case .calc:
                canNormalize = false
            }
            item = arena.end(item)
        }

        // Without every weight resolved (calc-mix(10px calc(50% * sibling-index()), 20px) at parse time), there is no
        // normalising, but the items with a weight known to be zero go.
        if !canNormalize {
            guard numberOfKnownZeroWeights > 0 else {
                return
            }
            if count - numberOfKnownZeroWeights == 0 {
                arena.replace(index, with: zeroValue(matching: index &+ 1, arena)) // index < arena.count.
                return
            }
            arena.retainChildren(of: index) { _, item in
                if case .raw(let weight, _) = CalcMixWeight(item) {
                    return weight != 0
                }
                return true
            }
            return
        }

        // The leftover mix percentage applies to a zero of the type, so it is discarded.
        if count <= 16 {
            var weights = [16 of Double](repeating: 0)
            var present = [16 of UInt8](repeating: 0)
            var normalized = [16 of Double](repeating: 0)
            var w = weights.mutableSpan
            var p = present.mutableSpan
            var n = normalized.mutableSpan
            normalizeCalcMix(index, count, &arena, &resolver, &w, &p, &n)
        } else {
            normalizeCalcMixOnHeap(index, count, &arena, &resolver)
        }
    }

    @inline(never)
    private mutating func normalizeCalcMixOnHeap(
        _ index: Int,
        _ count: Int,
        _ arena: inout CalcArena,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) {
        var weights = UniqueArray<Double>(repeating: 0, count: count)
        var present = UniqueArray<UInt8>(repeating: 0, count: count)
        var normalized = UniqueArray<Double>(repeating: 0, count: count)
        var w = weights.mutableSpan
        var p = present.mutableSpan
        var n = normalized.mutableSpan
        normalizeCalcMix(index, count, &arena, &resolver, &w, &p, &n)
    }

    /// The calc-mix() at `index`, of `count` items, with its weights normalised; `weights`, `present` and
    /// `normalized` are its scratch, at least one element per item.
    private mutating func normalizeCalcMix(
        _ index: Int,
        _ count: Int,
        _ arena: inout CalcArena,
        _ resolver: inout WebCore.CSSCalcSwiftResolver,
        _ weights: inout MutableSpan<Double>,
        _ present: inout MutableSpan<UInt8>,
        _ normalized: inout MutableSpan<Double>
    ) {
        var item = index &+ 1 // index < arena.count.
        for i in 0..<count {
            if case .raw(let weight, _) = CalcMixWeight(arena[item]) {
                weights[i] = weight
                present[i] = 1
            }
            item = arena.end(item)
        }
        resolver.normalizeMixPercentages(weights.span.extracting(0..<count), present.span.extracting(0..<count), &normalized)

        // Items whose weight normalises to 0 go, omitted weights included when the given ones reach 100%.
        var survivors = 0
        for i in 0..<count where normalized[i] != 0 {
            survivors += 1
        }
        if survivors == 0 {
            arena.replace(index, with: zeroValue(matching: index &+ 1, arena)) // index < arena.count.
            return
        }
        item = index &+ 1 // index < arena.count.
        for i in 0..<count {
            if normalized[i] != 0 {
                var payload = CalcNode.noPayload
                if case .raw(let weight, let existing) = CalcMixWeight(arena[item]), weight.bitPattern == normalized[i].bitPattern {
                    payload = existing
                }
                if payload == CalcNode.noPayload {
                    madeWeights = true
                }
                arena[item].unit = CalcNode.rawWeightUnit
                arena[item].value = normalized[i]
                arena[item].payload = payload
            }
            item = arena.end(item)
        }
        let kept = normalized.span
        arena.retainChildren(of: index) { i, _ in kept[i] != 0 }

        // Every value a numeric leaf of one kind and unit (or hint) makes a leaf of their weighted sum. Not so
        // for calc-mix(10% 25%, 10px 75%) as a <length-percentage>, calc-mix(10px * sibling-index() 25%, 10px 75%),
        // or calc-mix(10em 25%, 10px 75%).
        let firstValue = arena[index &+ 2] // The first item, at index + 1, and its value.
        var result = 0.0
        item = index &+ 1 // index < arena.count.
        for i in 0..<arena.childCount(index) {
            let weight = arena.value(item) / 100.0
            let value = arena[item &+ 1] // An item has a child.
            guard let kind = CalcKind(rawValue: value.kind), kind.isNumeric else {
                return
            }
            item = arena.end(item)
            if i == 0 {
                result = value.value * weight
                continue
            }
            guard value.kind == firstValue.kind else {
                return
            }
            if kind != .Number && value.unit != firstValue.unit {
                return
            }
            let addition = value.value * weight
            result = result + addition
        }
        arena.replace(index, with: .numeric(result, basedOn: firstValue))
    }

    // MARK: anchor() and anchor-size()

    private func simplifyAnchor(_ index: Int, _ arena: inout CalcArena, _ resolver: inout WebCore.CSSCalcSwiftResolver) {
        guard hasConversionData, resolver.hasStyleBuilderState() else {
            return
        }
        let node = arena[index]
        var sideFraction = 0.0
        let sideIsChild = node.flags & CalcNodeFlags.sideIsChild != 0
        if sideIsChild {
            let side = index &+ 1 // index < arena.count.
            let records = arena.span.extracting(side..<arena.end(side))
            sideFraction = (calcEvaluate(records, &resolver, hasConversionData: hasConversionData) ?? 0) / 100
        }
        let result = resolver.resolveAnchor(node.payload, sideIsChild ? 0 : node.unit, sideFraction)
        guard result.ok != 0 else {
            // https://drafts.csswg.org/css-anchor-position-1/#anchor-valid: the anchor() resolves to its fallback,
            // and without one makes the declaration invalid at computed-value time.
            guard let fallback = arena.optionalArgumentIndex(index) else {
                resolver.markInvalidAtComputedValueTime()
                return
            }
            arena.replace(index, withSubtreeAt: arena.child(index, fallback))
            return
        }
        arena.replace(index, with: .canonicalDimension(result.value, unit: .Px))
    }

    private func simplifyAnchorSize(_ index: Int, _ arena: inout CalcArena, _ resolver: inout WebCore.CSSCalcSwiftResolver) {
        guard hasConversionData, resolver.hasStyleBuilderState() else {
            return
        }
        let node = arena[index]
        let result = resolver.resolveAnchorSize(node.payload, UInt8(truncatingIfNeeded: node.unit))
        guard result.ok != 0 else {
            guard let fallback = arena.optionalArgumentIndex(index) else {
                resolver.markInvalidAtComputedValueTime()
                return
            }
            arena.replace(index, withSubtreeAt: arena.child(index, fallback))
            return
        }
        arena.replace(index, with: .canonicalDimension(result.value, unit: .Px))
    }
}

// MARK: - Trees that simplify to one length

/// The index after the subtree of `records` at `index` when, with conversion data, it simplifies to one px
/// CanonicalDimension: when it is a px CanonicalDimension, a NonCanonicalDimension in a length unit, or a Sum, Min,
/// Max, Negate or Clamp whose children are such subtrees, as many as a CSSCalc::Child of its kind has. Else nil.
private func calcLengthFoldEnd(_ records: Span<CalcRecord>, at index: Int) -> Int? {
    let node = records.calcNode(at: index)
    let px = UInt16(WebCore.CSSUnitType.Px.rawValue)
    let childCount: Int
    switch node.kind {
    case .CanonicalDimension:
        return node.unit == px ? node.end : nil
    case .NonCanonicalDimension:
        return node.unit != px && calcIsLength(node.unit) ? node.end : nil
    case .Sum, .Min, .Max:
        childCount = node.childCount >= 1 ? node.childCount : -1
    case .Negate:
        childCount = node.childCount == 1 ? 1 : -1
    case .Clamp:
        childCount = 1 + (node.minIsNone ? 0 : 1) + (node.maxIsNone ? 0 : 1)
    default:
        return nil
    }
    guard childCount == node.childCount else {
        return nil
    }
    var child = index &+ 1 // index < records.count: the record was read.
    for _ in 0..<childCount {
        guard child < node.end, let end = calcLengthFoldEnd(records, at: child) else {
            return nil
        }
        child = end
    }
    return child == node.end ? child : nil
}

/// The px CanonicalDimension that `CalcSimplifier.copyAndSimplify` makes of the subtree of `records` at `index`, for
/// which `calcLengthFoldEnd` is not nil, with conversion data; advances `index` past the subtree. Each node is
/// simplified as the simplifier simplifies it once its children are px leaves: the record kept is the one it keeps,
/// the arithmetic is its executors' in its order, and the resolver converts the same leaves in the same order.
private func calcFoldLength(
    _ records: Span<CalcRecord>,
    at index: inout Int,
    _ resolver: inout WebCore.CSSCalcSwiftResolver
) -> CalcRecord {
    let record = records[index]
    let node = records.calcNode(record, at: index)
    index &+= 1 // index < records.count: records[index] was read.
    switch node.kind {
    case .CanonicalDimension:
        return record
    case .NonCanonicalDimension:
        // simplifyNonCanonicalDimension.
        guard let canonical = calcCanonicalize(record.value, calcUnitType(record), &resolver, hasConversionData: true) else {
            preconditionFailure()
        }
        return canonical
    case .Sum:
        // Every child merges into the first, which is left alone.
        var first = calcFoldLength(records, at: &index, &resolver)
        while index < node.end {
            first.value = CalcExecutor.sum(first.value, calcFoldLength(records, at: &index, &resolver).value)
        }
        return first
    case .Min, .Max:
        let isMin = node.kind == .Min
        var first = calcFoldLength(records, at: &index, &resolver)
        while index < node.end {
            let (a, b) = (first.value, calcFoldLength(records, at: &index, &resolver).value)
            first.value = isMin ? CalcExecutor.min(a, b) : CalcExecutor.max(a, b)
        }
        return first
    case .Negate:
        let child = calcFoldLength(records, at: &index, &resolver)
        return .numeric(-child.value, basedOn: child)
    case .Clamp:
        let first = calcFoldLength(records, at: &index, &resolver)
        if node.minIsNone && node.maxIsNone {
            return first
        }
        let second = calcFoldLength(records, at: &index, &resolver)
        if node.minIsNone {
            return .numeric(CalcExecutor.min(first.value, second.value), basedOn: first)
        }
        if node.maxIsNone {
            return .numeric(CalcExecutor.max(first.value, second.value), basedOn: second)
        }
        let third = calcFoldLength(records, at: &index, &resolver)
        return .numeric(CalcExecutor.clamp(first.value, second.value, third.value), basedOn: second)
    default:
        preconditionFailure()
    }
}

// MARK: - Entry

/// `CSSCalc::copyAndSimplify` of the tree `records` into `arena`, which is empty, with `resolver` and `options`. A
/// calc-mix() weight it normalises is left as a raw weight no payload holds (`calcWritePendingWeights`), and
/// `madeWeights` says whether there is one.
func calcSimplify(
    _ records: Span<CalcRecord>,
    into arena: inout CalcArena,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    _ options: WebCore.CSSCalcSwiftSimplificationOptions
) -> Bool {
    precondition(arena.count == 0)
    var simplifier = CalcSimplifier(options)
    var index = 0
    simplifier.copyAndSimplify(records, at: &index, &arena, &resolver)
    precondition(index == records.count)
    return simplifier.madeWeights
}

func cssCalcSimplifyImpl(
    _ nodes: Span<WebCore.CSSCalcNodeRecord>,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    _ output: inout WebCore.CSSCalcSwiftOutput,
    _ options: WebCore.CSSCalcSwiftSimplificationOptions
) {
    if options.hasConversionData != 0 && calcLengthFoldEnd(nodes, at: 0) == nodes.count {
        var index = 0
        let length = [1 of CalcRecord](repeating: calcFoldLength(nodes, at: &index, &resolver))
        precondition(index == nodes.count)
        output.adopt(length.span)
        return
    }
    withCalcArena(holding: nodes.count) { arena in
        if calcSimplify(nodes, into: &arena, &resolver, options) {
            calcWritePendingWeights(&arena, at: 0, &output)
        }
        assert(arena.span.isCalcTree)
        output.adopt(arena.span)
    }
}
