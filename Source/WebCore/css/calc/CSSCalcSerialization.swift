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

internal import WebCore_Private.Core.CSSCalcSwiftTypes

// MARK: - Serialization
// https://drafts.csswg.org/css-values-4/#serialize-a-math-function

extension WebCore.CSSCalcSwiftSerializer {
    /// Appends a fixed ASCII spelling of at most 16 characters. For a literal, the copy folds to constants.
    @inline(always)
    fileprivate mutating func append(_ text: Swift.String) {
        var characters = [16 of UInt8](repeating: 0)
        var count = 0
        for character in text.utf8 {
            characters[count] = character
            count += 1
        }
        appendLatin1(characters.span.extracting(0..<count))
    }

    @inline(always)
    fileprivate mutating func append(keyword: WebCore.CSSValueID) {
        appendValueIDName(keyword.rawValue)
    }
}

/// Sorts after every numeric unit, even one with no priority.
private let otherSortPriority = UInt32.max

/// A unit with no priority: one that is not numeric.
private let errorSortPriority = UInt32.max - 1

/// Number, percentage, then dimensions by unit, ordered ASCII case-insensitively.
private func sortPriority(_ unit: WebCore.CSSUnitType) -> UInt32 {
    switch unit {
    case .Number, .Integer: return 0
    case .Percentage: return 1
    case .Cap: return 2
    case .Ch: return 3
    case .Cm: return 4
    case .Cqb: return 5
    case .Cqh: return 6
    case .Cqi: return 7
    case .Cqmax: return 8
    case .Cqmin: return 9
    case .Cqw: return 10
    case .Deg: return 11
    case .Dpcm: return 12
    case .Dpi: return 13
    case .Dppx: return 14
    case .Dvb: return 15
    case .Dvh: return 16
    case .Dvi: return 17
    case .Dvmax: return 18
    case .Dvmin: return 19
    case .Dvw: return 20
    case .Em: return 21
    case .Ex: return 22
    case .Fr: return 23
    case .Grad: return 24
    case .Hz: return 25
    case .Ic: return 26
    case .In: return 27
    case .Khz: return 28
    case .Lh: return 29
    case .Lvb: return 30
    case .Lvh: return 31
    case .Lvi: return 32
    case .Lvmax: return 33
    case .Lvmin: return 34
    case .Lvw: return 35
    case .Mm: return 36
    case .Ms: return 37
    case .Pc: return 38
    case .Pt: return 39
    case .Px: return 40
    case .Q: return 41
    case .Rad: return 42
    case .Rcap: return 43
    case .Rch: return 44
    case .Rem: return 45
    case .Rex: return 46
    case .Ric: return 47
    case .Rlh: return 48
    case .S: return 49
    case .Svb: return 50
    case .Svh: return 51
    case .Svi: return 52
    case .Svmax: return 53
    case .Svmin: return 54
    case .Svw: return 55
    case .Turn: return 56
    case .Vb: return 57
    case .Vh: return 58
    case .Vi: return 59
    case .Vmax: return 60
    case .Vmin: return 61
    case .Vw: return 62
    case .X: return 63
    default: return errorSortPriority
    }
}

/// The CSSUnitType a numeric leaf serializes with.
@inline(always)
private func serializationUnit(_ node: CalcNodeView) -> UInt16 {
    node.kind == .Percentage ? UInt16(WebCore.CSSUnitType.Percentage.rawValue) : node.unit
}

/// https://drafts.csswg.org/css-values-4/#sort-a-calculations-children
///
/// The priority in the high half and the index of the child's record in the low half, so that sorting the keys is a
/// stable sort by priority. Read from the child's record alone: the child is read as a node when it is serialized.
@inline(always)
private func sortKey(_ child: WebCore.CSSCalcNodeRecord, _ index: Int) -> UInt64 {
    var priority = otherSortPriority
    if child.kind <= CalcKind.NonCanonicalDimension.rawValue {
        let unit = child.kind == CalcKind.Percentage.rawValue ? UInt16(WebCore.CSSUnitType.Percentage.rawValue) : child.unit
        if let unit = WebCore.CSSUnitType(rawValue: UInt8(truncatingIfNeeded: unit)) {
            priority = sortPriority(unit)
        } else {
            priority = errorSortPriority
        }
    }
    return UInt64(priority) << 32 | UInt64(UInt32(index))
}

/// The index of the record of the child whose sort key is `key`.
@inline(always)
private func childRecord(_ key: UInt64) -> Int {
    Int(UInt32(truncatingIfNeeded: key))
}

/// Fills `keys[0..<count]` with the sort keys of `node`'s children and sorts them. Insertion sort, since a sum or
/// product is usually short and already in order.
private func sortChildren(_ node: CalcNodeView, _ keys: inout MutableSpan<UInt64>) {
    let count = node.childCount
    var child = node.firstChild
    for i in 0..<count {
        keys[i] = sortKey(node.records[child], child)
        child = node.end(child)
    }
    var i = 1
    while i < count {
        let key = keys[i]
        var j = i
        while j > 0 && keys[j - 1] > key {
            keys[j] = keys[j - 1]
            j -= 1
        }
        keys[j] = key
        i += 1
    }
}

/// Sorted-order buffers of up to this many children are on the stack.
private let inlineSortCapacity = 16

/// The parts of the serialization state that do not change during the walk. Whether a calc-operator node writes its
/// grouping parentheses is a parameter instead.
private struct CalcSerialization {
    let computed: Bool
    let rangeMin: Double
    let rangeMax: Double

    /// NaN becomes 0, then `std::clamp` to the range.
    func clampValue(_ value: Double) -> Double {
        let value = value.isNaN ? 0 : value
        if value < rangeMin {
            return rangeMin
        }
        if rangeMax < value {
            return rangeMax
        }
        return value
    }

    // MARK: Math function

    func serializeMathFunction(_ node: CalcNodeView, _ out: inout WebCore.CSSCalcSwiftSerializer) {
        switch node.kind {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            // 1. A numeric value serialized as a computed value or later is clamped to its context's range and
            // serialized as normal.
            if computed {
                out.appendNumber(clampValue(node.value), serializationUnit(node))
                return
            }
            out.append("calc(")
            out.appendNumber(node.value, serializationUnit(node))
            out.append(")")

        case .Symbol:
            out.append("calc(")
            out.appendValueIDName(node.symbolID)
            out.append(")")

        case .SiblingCount, .SiblingIndex:
            serializeCalculationTree(node, grouping: true, &out)

        case .Deg2Rad:
            // Deg2Rad has no CSS spelling, so its child takes its place.
            serializeMathFunction(node.child(0), &out)

        default:
            // 3. "calc(" for a calc-operator node, else the function's name and "(".
            serializeMathFunctionPrefix(node, &out)
            // 4. The arguments, separated by ", ", each without its grouping parentheses.
            serializeMathFunctionArguments(node, &out)
            // 5.
            out.append(")")
        }
    }

    func serializeMathFunctionPrefix(_ node: CalcNodeView, _ out: inout WebCore.CSSCalcSwiftSerializer) {
        switch node.kind {
        case .Sum, .Product, .Negate, .Invert:
            out.append("calc(")
        case .RoundNearest, .RoundUp, .RoundDown, .RoundToZero:
            out.append(keyword: .Round)
            out.append("(")
            out.append(keyword: roundingStrategyKeyword(node.kind))
            out.append(", ")
        case .ProgressNoClamp:
            out.append(keyword: .Progress)
            out.append("(no-clamp ")
        default:
            out.append(keyword: functionKeyword(node.kind))
            out.append("(")
        }
    }

    func serializeMathFunctionArguments(_ node: CalcNodeView, _ out: inout WebCore.CSSCalcSwiftSerializer) {
        switch node.kind {
        case .Sum:
            serializeSum(node, grouping: false, &out)
        case .Product:
            serializeProduct(node, grouping: false, &out)
        case .Random:
            serializeRandomArguments(node, &out)
        case .CalcMix:
            serializeCalcMixArguments(node, &out)
        case .Anchor:
            serializeAnchorArguments(node, &out)
        case .AnchorSize:
            serializeAnchorSizeArguments(node, &out)
        case .Clamp:
            var child = node.firstChild
            if node.minIsNone {
                out.append(keyword: .None)
            } else {
                serializeCalculationTree(CalcNodeView(node.records, at: child), grouping: false, &out)
                child = node.end(child)
            }
            out.append(", ")
            serializeCalculationTree(CalcNodeView(node.records, at: child), grouping: false, &out)
            out.append(", ")
            if node.clampMaxIndex != nil {
                serializeCalculationTree(CalcNodeView(node.records, at: node.end(child)), grouping: false, &out)
            } else {
                out.append(keyword: .None)
            }
        default:
            // An absent optional argument has no child, and so no separator. A root Negate or Invert serializes
            // only its operand here, as `calc(<operand>)`, without the "-1 * " or "1 / ".
            var child = node.firstChild
            for i in 0..<node.childCount {
                if i > 0 {
                    out.append(", ")
                }
                serializeCalculationTree(CalcNodeView(node.records, at: child), grouping: false, &out)
                child = node.end(child)
            }
        }
    }

    func serializeRandomArguments(_ node: CalcNodeView, _ out: inout WebCore.CSSCalcSwiftSerializer) {
        let sharing = out.randomSharing(node.payload)
        switch sharing.kind {
        case 1:
            // A <random-cache-key>, which the parser never produces empty.
            var wroteSomething = false
            if sharing.hasName != 0 {
                wroteSomething = true
                out.appendPayload(node.payload)
            }
            if sharing.elementScoped != 0 {
                if wroteSomething {
                    out.append(" ")
                }
                wroteSomething = true
                out.append(keyword: .ElementScoped)
            }
            if sharing.propertyScope != 0 {
                if wroteSomething {
                    out.append(" ")
                }
                out.append(keyword: sharing.propertyScope == 1 ? .PropertyScoped : .PropertyIndexScoped)
            }
            out.append(", ")
        case 2:
            out.append(keyword: .Fixed)
            out.append(" ")
            out.appendPayload(node.payload)
            out.append(", ")
        default:
            // `auto` serializes as omitted.
            break
        }

        serializeCalculationTree(node.child(0), grouping: false, &out)
        out.append(", ")
        serializeCalculationTree(node.child(1), grouping: false, &out)
        if let stepIndex = node.optionalArgumentIndex {
            out.append(", ")
            serializeCalculationTree(node.child(stepIndex), grouping: false, &out)
        }
    }

    func serializeCalcMixArguments(_ node: CalcNodeView, _ out: inout WebCore.CSSCalcSwiftSerializer) {
        var child = node.firstChild
        for i in 0..<node.childCount {
            if i > 0 {
                out.append(", ")
            }
            let item = CalcNodeView(node.records, at: child)
            serializeCalculationTree(item.child(0), grouping: false, &out)
            if let weight = item.payloadIndex {
                out.append(" ")
                out.appendPayload(weight)
            }
            child = node.end(child)
        }
    }

    func serializeAnchorArguments(_ node: CalcNodeView, _ out: inout WebCore.CSSCalcSwiftSerializer) {
        if let name = node.payloadIndex {
            out.appendPayload(name)
            out.append(" ")
        }
        if node.anchorSideIsChild {
            // anchor() is not a math function, so its arguments keep their calc().
            serializeWithoutOmittingPrefix(node.child(0), &out)
        } else {
            out.appendValueIDName(node.unit)
        }
        if let fallbackIndex = node.optionalArgumentIndex {
            out.append(", ")
            serializeWithoutOmittingPrefix(node.child(fallbackIndex), &out)
        }
    }

    func serializeAnchorSizeArguments(_ node: CalcNodeView, _ out: inout WebCore.CSSCalcSwiftSerializer) {
        let name = node.payloadIndex
        if let name {
            out.appendPayload(name)
        }
        let dimension = node.anchorSizeDimension
        if let dimension {
            if name != nil {
                out.append(" ")
            }
            // Style::AnchorSizeDimension's values, in order.
            switch dimension {
            case 0: out.append("width")
            case 1: out.append("height")
            case 2: out.append("block")
            case 3: out.append("inline")
            case 4: out.append("self-block")
            case 5: out.append("self-inline")
            default: break
            }
        }
        if let fallbackIndex = node.optionalArgumentIndex {
            if name != nil || dimension != nil {
                out.append(", ")
            }
            serializeWithoutOmittingPrefix(node.child(fallbackIndex), &out)
        }
    }

    func serializeWithoutOmittingPrefix(_ node: CalcNodeView, _ out: inout WebCore.CSSCalcSwiftSerializer) {
        if node.kind.isLeaf {
            serializeCalculationTree(node, grouping: false, &out)
        } else {
            serializeMathFunction(node, &out)
        }
    }

    // MARK: Calculation tree
    // https://drafts.csswg.org/css-values-4/#serialize-a-calculation-tree

    func serializeCalculationTree(_ node: CalcNodeView, grouping: Bool, _ out: inout WebCore.CSSCalcSwiftSerializer) {
        switch node.kind {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            // 2. A numeric value serializes per the normal rules for it.
            out.appendNumber(node.value, serializationUnit(node))

        case .Symbol:
            out.appendValueIDName(node.symbolID)

        case .SiblingCount:
            out.append(keyword: .SiblingCount)
            out.append("()")

        case .SiblingIndex:
            out.append(keyword: .SiblingIndex)
            out.append("()")

        case .Sum:
            serializeSum(node, grouping: grouping, &out)

        case .Product:
            serializeProduct(node, grouping: grouping, &out)

        case .Negate:
            // 4. "(-1 * ", the child, ")".
            if grouping {
                out.append("(")
            }
            out.append("-1 * ")
            serializeCalculationTree(node.child(0), grouping: true, &out)
            if grouping {
                out.append(")")
            }

        case .Invert:
            // 5. "(1 / ", the child, ")".
            if grouping {
                out.append("(")
            }
            out.append("1 / ")
            serializeCalculationTree(node.child(0), grouping: true, &out)
            if grouping {
                out.append(")")
            }

        case .Deg2Rad:
            serializeCalculationTree(node.child(0), grouping: grouping, &out)

        default:
            // 3. Anything else serializes as a math function.
            serializeMathFunction(node, &out)
        }
    }

    /// 6. A Sum: "(", its sorted children separated by " + ", or " - " before a Negate's child or a negative
    /// numeric value's negation, ")".
    func serializeSum(_ node: CalcNodeView, grouping: Bool, _ out: inout WebCore.CSSCalcSwiftSerializer) {
        if grouping {
            out.append("(")
        }
        let count = node.childCount
        if count <= inlineSortCapacity {
            var storage = [16 of UInt64](repeating: 0)
            var keys = storage.mutableSpan
            sortChildren(node, &keys)
            serializeSumChildren(node, keys.span, &out)
        } else {
            var storage = UniqueArray<UInt64>(repeating: 0, count: count)
            var keys = storage.mutableSpan
            sortChildren(node, &keys)
            serializeSumChildren(node, keys.span, &out)
        }
        if grouping {
            out.append(")")
        }
    }

    func serializeSumChildren(_ node: CalcNodeView, _ order: Span<UInt64>, _ out: inout WebCore.CSSCalcSwiftSerializer) {
        serializeCalculationTree(CalcNodeView(node.records, at: childRecord(order[0])), grouping: true, &out)
        for i in 1..<node.childCount {
            serializeSumTerm(CalcNodeView(node.records, at: childRecord(order[i])), &out)
        }
    }

    func serializeSumTerm(_ child: CalcNodeView, _ out: inout WebCore.CSSCalcSwiftSerializer) {
        switch child.kind {
        case .Negate:
            out.append(" - ")
            serializeCalculationTree(child.child(0), grouping: true, &out)
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
            // -0 and NaN are not negative.
            if child.value < 0 {
                out.append(" - ")
                out.appendNumber(-child.value, serializationUnit(child))
            } else {
                out.append(" + ")
                out.appendNumber(child.value, serializationUnit(child))
            }
        default:
            out.append(" + ")
            serializeCalculationTree(child, grouping: true, &out)
        }
    }

    /// 7. A Product: "(", its sorted children separated by " * ", or " / " before an Invert's child, ")".
    func serializeProduct(_ node: CalcNodeView, grouping: Bool, _ out: inout WebCore.CSSCalcSwiftSerializer) {
        if grouping {
            out.append("(")
        }
        let count = node.childCount
        if count <= inlineSortCapacity {
            var storage = [16 of UInt64](repeating: 0)
            var keys = storage.mutableSpan
            sortChildren(node, &keys)
            serializeProductChildren(node, keys.span, &out)
        } else {
            var storage = UniqueArray<UInt64>(repeating: 0, count: count)
            var keys = storage.mutableSpan
            sortChildren(node, &keys)
            serializeProductChildren(node, keys.span, &out)
        }
        if grouping {
            out.append(")")
        }
    }

    func serializeProductChildren(_ node: CalcNodeView, _ order: Span<UInt64>, _ out: inout WebCore.CSSCalcSwiftSerializer) {
        serializeCalculationTree(CalcNodeView(node.records, at: childRecord(order[0])), grouping: true, &out)
        for i in 1..<node.childCount {
            let child = CalcNodeView(node.records, at: childRecord(order[i]))
            if child.kind == .Invert {
                out.append(" / ")
                serializeCalculationTree(child.child(0), grouping: true, &out)
            } else {
                out.append(" * ")
                serializeCalculationTree(child, grouping: true, &out)
            }
        }
    }
}

/// The keyword that names a math function's node, as its serialization spells it.
private func functionKeyword(_ kind: CalcKind) -> WebCore.CSSValueID {
    switch kind {
    case .Min: return .Min
    case .Max: return .Max
    case .Clamp: return .Clamp
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
    case .Progress, .ProgressNoClamp: return .Progress
    case .CalcMix: return .CalcMix
    case .Anchor: return .Anchor
    case .AnchorSize: return .AnchorSize
    default:
        // A calc-mix() item is serialized by its calc-mix(); the other kinds have their own serialization.
        preconditionFailure("not a math function")
    }
}

private func roundingStrategyKeyword(_ kind: CalcKind) -> WebCore.CSSValueID {
    switch kind {
    case .RoundUp: return .Up
    case .RoundDown: return .Down
    case .RoundToZero: return .ToZero
    default: return .Nearest
    }
}

/// Appends the serialization of the tree `nodes` holds: as a math function, or, `asFunctionArgument`, as the
/// calculation tree alone, with no calc() and no grouping parentheses at its root. `computed` clamps a numeric root
/// math function's value to [rangeMin, rangeMax].
func cssCalcSerializeImpl(
    _ nodes: Span<WebCore.CSSCalcNodeRecord>,
    _ serializer: inout WebCore.CSSCalcSwiftSerializer,
    computed: Bool,
    rangeMin: Double,
    rangeMax: Double,
    asFunctionArgument: Bool
) {
    let root = CalcNodeView(nodes, at: 0)
    precondition(root.end(0) == nodes.count)
    let serialization = CalcSerialization(computed: computed, rangeMin: rangeMin, rangeMax: rangeMax)
    if asFunctionArgument {
        serialization.serializeCalculationTree(root, grouping: false, &serializer)
    } else {
        serialization.serializeMathFunction(root, &serializer)
    }
}

// MARK: - Typed OM
// https://drafts.css-houdini.org/css-typed-om/#reify-a-math-expression

/// Pushes the CSSNumericValue for `node` onto `builder`, its operands first, in order. False once the builder has
/// recorded an exception, after which nothing more is pushed, so the first exception is the one reported.
private func reify(_ node: CalcNodeView, _ builder: inout WebCore.CSSCalcSwiftNumericValueBuilder) -> Bool {
    switch node.kind {
    case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension:
        return builder.pushUnitValue(node.value, serializationUnit(node))

    case .Sum, .Product, .Min, .Max, .Negate, .Invert:
        var child = node.firstChild
        for _ in 0..<node.childCount {
            guard reify(CalcNodeView(node.records, at: child), &builder) else {
                return false
            }
            child = node.end(child)
        }
        return builder.pushOperation(node.kind.rawValue, UInt32(node.childCount))

    case .Clamp:
        // A `none` bound cannot be reified; operation with no operands records the exception.
        guard let minIndex = node.clampMinIndex else {
            return builder.pushOperation(node.kind.rawValue, 0)
        }
        guard reify(node.child(minIndex), &builder), reify(node.child(node.clampValueIndex), &builder) else {
            return false
        }
        guard let maxIndex = node.clampMaxIndex else {
            return builder.pushOperation(node.kind.rawValue, 0)
        }
        guard reify(node.child(maxIndex), &builder) else {
            return false
        }
        return builder.pushOperation(node.kind.rawValue, 3)

    default:
        // Symbols, sibling-count(), sibling-index() and the other math functions have no CSSNumericValue; their
        // operands are not visited.
        return builder.pushOperation(node.kind.rawValue, 0)
    }
}

/// Builds the CSSNumericValue for the tree `nodes` holds on `builder`. False when the builder recorded an exception.
func cssCalcReifyImpl(_ nodes: Span<WebCore.CSSCalcNodeRecord>, _ builder: inout WebCore.CSSCalcSwiftNumericValueBuilder) -> Bool {
    let root = CalcNodeView(nodes, at: 0)
    precondition(root.end(0) == nodes.count)
    return reify(root, &builder)
}
