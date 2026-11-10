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

// The evaluation of a calculation tree to a double (CSSCalcTree+Evaluation.cpp, evaluateDouble), over the tree's
// records in place.

/// `evaluate(const Child&)` of the tree `records`: its value, nil where it does not resolve.
func calcEvaluate(
    _ records: Span<WebCore.CSSCalcNodeRecord>,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    hasConversionData: Bool
) -> Double? {
    var evaluator = CalcEvaluator(hasConversionData: hasConversionData)
    var index = 0
    let value = evaluator.evaluate(records, at: &index, &resolver)
    precondition(index == records.count)
    return value
}

/// Each operation's children are evaluated in order, each from where the one before it ends, as
/// CSSCalcTree+Evaluation.cpp's `evaluate` overloads evaluate them; one that is not evaluated is skipped.
private struct CalcEvaluator {
    let hasConversionData: Bool

    /// `evaluate(const std::optional<Child>&)` of the optional last argument of `node`, which `index` is at: an
    /// absent argument is nil, and so is one that does not resolve, which round(), log() and random() then use as if
    /// it were absent.
    mutating func evaluateOptional(
        _ node: CalcRecordNode,
        _ records: Span<WebCore.CSSCalcNodeRecord>,
        at index: inout Int,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> Double? {
        guard node.hasOptionalArgument else {
            return nil
        }
        return evaluate(records, at: &index, &resolver)
    }

    /// `executeVariadicMathOperationAfterUnwrapping`: the operation over every child the executor asks for, nil if
    /// one did not resolve.
    mutating func evaluateVariadic(
        _ node: CalcRecordNode,
        _ records: Span<WebCore.CSSCalcNodeRecord>,
        at index: inout Int,
        _ resolver: inout WebCore.CSSCalcSwiftResolver,
        _ operation: (Int, (Int) -> Double) -> Double
    ) -> Double? {
        var failure = false
        let result = operation(node.childCount) { _ in
            if let value = evaluate(records, at: &index, &resolver) {
                return value
            }
            failure = true
            return .nan
        }
        return failure ? nil : result
    }

    /// The value of the subtree whose record is `records[index]`, nil where it does not resolve; `index` moves past
    /// the subtree.
    mutating func evaluate(
        _ records: Span<WebCore.CSSCalcNodeRecord>,
        at index: inout Int,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> Double? {
        let node = records.calcNode(at: index)
        index &+= 1 // The first child; index < records.count.
        defer {
            index = node.end
        }
        switch node.kind {
        case .Number, .Percentage, .CanonicalDimension:
            return node.value
        case .NonCanonicalDimension:
            return calcCanonicalValue(node.value, node.unitType, &resolver, hasConversionData: hasConversionData)?.value
        case .Symbol:
            let symbol = resolver.resolveSymbol(node.symbolID)
            guard symbol.ok != 0 else {
                return nil
            }
            return numericValue(symbol.value, unit: node.unitType, &resolver)
        case .SiblingCount, .SiblingIndex:
            guard hasConversionData else {
                return nil
            }
            let result = node.kind == .SiblingCount ? resolver.siblingCount() : resolver.siblingIndex()
            return result.ok != 0 ? result.value : nil
        case .Sum:
            return evaluateVariadic(node, records, at: &index, &resolver) { CalcExecutor.sum(count: $0, $1) }
        case .Product:
            return evaluateVariadic(node, records, at: &index, &resolver) { CalcExecutor.product(count: $0, $1) }
        case .Min:
            return evaluateVariadic(node, records, at: &index, &resolver) { CalcExecutor.min(count: $0, $1) }
        case .Max:
            return evaluateVariadic(node, records, at: &index, &resolver) { CalcExecutor.max(count: $0, $1) }
        case .Hypot:
            return evaluateVariadic(node, records, at: &index, &resolver) { CalcExecutor.hypot(count: $0, $1) }
        case .Negate:
            return evaluate(records, at: &index, &resolver).map { CalcExecutor.negate($0) }
        case .Invert:
            return evaluate(records, at: &index, &resolver).map { CalcExecutor.invert($0) }
        case .Deg2Rad:
            // The angle is in degrees, its canonical unit; the trigonometric functions take radians.
            return evaluate(records, at: &index, &resolver).map { CalcExecutor.deg2rad($0) }
        case .Sin:
            return evaluate(records, at: &index, &resolver).map { CalcExecutor.sin($0) }
        case .Cos:
            return evaluate(records, at: &index, &resolver).map { CalcExecutor.cos($0) }
        case .Tan:
            return evaluate(records, at: &index, &resolver).map { CalcExecutor.tan($0) }
        case .Asin:
            return evaluate(records, at: &index, &resolver).map { CalcExecutor.asin($0) }
        case .Acos:
            return evaluate(records, at: &index, &resolver).map { CalcExecutor.acos($0) }
        case .Atan:
            return evaluate(records, at: &index, &resolver).map { CalcExecutor.atan($0) }
        case .Sqrt:
            return evaluate(records, at: &index, &resolver).map { CalcExecutor.sqrt($0) }
        case .Exp:
            return evaluate(records, at: &index, &resolver).map { CalcExecutor.exp($0) }
        case .Abs:
            return evaluate(records, at: &index, &resolver).map { CalcExecutor.abs($0) }
        case .Sign:
            return evaluate(records, at: &index, &resolver).map { CalcExecutor.sign($0) }
        case .Mod, .Rem, .Atan2, .Pow:
            // Every argument is evaluated before any is checked.
            let a = evaluate(records, at: &index, &resolver)
            let b = evaluate(records, at: &index, &resolver)
            guard let a, let b else {
                return nil
            }
            switch node.kind {
            case .Mod:
                return CalcExecutor.mod(a, b)
            case .Rem:
                return CalcExecutor.rem(a, b)
            case .Atan2:
                return CalcExecutor.atan2(a, b)
            default:
                return CalcExecutor.pow(a, b)
            }
        case .Progress, .ProgressNoClamp:
            let value = evaluate(records, at: &index, &resolver)
            let start = evaluate(records, at: &index, &resolver)
            let end = evaluate(records, at: &index, &resolver)
            guard let value, let start, let end else {
                return nil
            }
            return node.kind == .Progress ? CalcExecutor.progress(value, start, end) : CalcExecutor.progressNoClamp(value, start, end)
        case .Clamp:
            // A `none` bound is not evaluated; a bound or value that does not resolve fails the clamp().
            var failed = false
            var minimum: Double? = nil
            if !node.minIsNone {
                minimum = evaluate(records, at: &index, &resolver)
                failed = minimum == nil
            }
            let value = evaluate(records, at: &index, &resolver)
            var maximum: Double? = nil
            if !node.maxIsNone {
                maximum = evaluate(records, at: &index, &resolver)
                failed = failed || maximum == nil
            }
            guard !failed, let value else {
                return nil
            }
            return CalcExecutor.clamp(minimum, value, maximum)
        case .RoundNearest, .RoundUp, .RoundDown, .RoundToZero:
            guard let strategy = CalcRoundingStrategy(node.kind) else {
                preconditionFailure()
            }
            let a = evaluate(records, at: &index, &resolver)
            let b = evaluateOptional(node, records, at: &index, &resolver)
            guard let a else {
                return nil
            }
            return CalcExecutor.round(strategy, a, b)
        case .Log:
            let a = evaluate(records, at: &index, &resolver)
            let b = evaluateOptional(node, records, at: &index, &resolver)
            guard let a else {
                return nil
            }
            return CalcExecutor.log(a, b)
        case .Random:
            guard hasConversionData, resolver.hasStyleBuilderState() else {
                return nil
            }
            guard let minimum = evaluate(records, at: &index, &resolver), let maximum = evaluate(records, at: &index, &resolver) else {
                return nil
            }
            let step = evaluateOptional(node, records, at: &index, &resolver)
            let base = resolver.resolveRandomBaseValue(node.payload)
            guard base.ok != 0 else {
                return nil
            }
            return CalcExecutor.random(base.value, minimum, maximum, step)
        case .CalcMix:
            return evaluateCalcMix(node, records, at: &index, &resolver)
        case .Anchor:
            guard hasConversionData, resolver.hasStyleBuilderState() else {
                return nil
            }
            // https://drafts.csswg.org/css-anchor-position-1/#anchor-valid: an anchor() that does not resolve is its
            // fallback, and without one makes the declaration invalid at computed-value time.
            // `evaluateWithoutFallback(const Anchor&)`: the side, a calculation, is evaluated first.
            var sideFraction = 0.0
            if node.anchorSideIsChild {
                sideFraction = (evaluate(records, at: &index, &resolver) ?? 0) / 100
            }
            let anchor = resolver.resolveAnchor(node.payload, node.anchorSideIsChild ? 0 : node.unit, sideFraction)
            var result = anchor.ok != 0 ? anchor.value : nil
            if result == nil && node.hasOptionalArgument {
                result = evaluate(records, at: &index, &resolver)
            }
            if result == nil {
                resolver.markInvalidAtComputedValueTime()
            }
            return result
        case .AnchorSize:
            guard hasConversionData, resolver.hasStyleBuilderState() else {
                return nil
            }
            let size = resolver.resolveAnchorSize(node.payload, UInt8(truncatingIfNeeded: node.unit))
            var result = size.ok != 0 ? size.value : nil
            if result == nil && node.hasOptionalArgument {
                result = evaluate(records, at: &index, &resolver)
            }
            if result == nil {
                resolver.markInvalidAtComputedValueTime()
            }
            return result
        case .CalcMixItem:
            preconditionFailure()
        @unknown default:
            preconditionFailure()
        }
    }

    /// The value of `makeNumeric(value, unit)`: a canonical or dimensionless value as it is, a non-canonical one
    /// canonicalized, and 0 for a unit that is not numeric, which `makeNumeric` gives after its assertion.
    func numericValue(_ value: Double, unit: WebCore.CSSUnitType, _ resolver: inout WebCore.CSSCalcSwiftResolver) -> Double? {
        switch unit {
        case .Number, .Integer, .Percentage, .Px, .Deg, .S, .Hz, .Dppx, .Fr:
            return value
        case .Calc, .CalcPercentageWithAngle, .CalcPercentageWithLength, .QuirkyEm, .Unknown:
            return 0
        default:
            return calcCanonicalValue(value, unit, &resolver, hasConversionData: hasConversionData)?.value
        }
    }

    mutating func evaluateCalcMix(
        _ node: CalcRecordNode,
        _ records: Span<WebCore.CSSCalcNodeRecord>,
        at index: inout Int,
        _ resolver: inout WebCore.CSSCalcSwiftResolver
    ) -> Double? {
        guard hasConversionData, resolver.hasStyleBuilderState() else {
            return nil
        }
        let count = node.childCount
        var numberOfOmittedWeights = 0
        var total = 0.0
        var values = UniqueArray<Double>(capacity: count)
        var weights = UniqueArray<Double>(capacity: count)
        var present = UniqueArray<Bool>(capacity: count)
        for _ in 0..<count {
            // Every child is a calc-mix() item, whose one child is its value.
            let item = records[index]
            index &+= 1 // The item's value; index < records.count.
            guard let value = evaluate(records, at: &index, &resolver) else {
                return nil
            }
            var weight = 0.0
            var hasWeight = true
            switch CalcMixWeight(unit: item.unit, value: item.value, payload: item.payload) {
            case .omitted:
                hasWeight = false
                numberOfOmittedWeights += 1
            case .raw(let raw, let payload) where payload == CalcNode.noPayload:
                weight = raw
            case .raw(_, let payload), .calc(let payload):
                let resolved = resolver.resolveCalcMixWeight(payload)
                guard resolved.ok != 0 else {
                    return nil
                }
                weight = resolved.value
            }
            if hasWeight {
                total += weight
            }
            values.append(value)
            weights.append(weight)
            present.append(hasWeight)
        }

        // std::min(total, 100.0): total unless 100 is less.
        let cappedTotal = 100.0 < total ? 100.0 : total
        let weightForOmitted = numberOfOmittedWeights > 0 ? (100.0 - cappedTotal) / Double(numberOfOmittedWeights) : 0.0
        let normalizationFactor = total > 100.0 ? (100.0 / total) : 1.0

        return CalcExecutor.calcMix(count: count) { i in
            (values[i], (present[i] ? weights[i] : weightForOmitted) * normalizationFactor)
        }
    }
}

// MARK: - Entry

func cssCalcEvaluateImpl(
    _ nodes: Span<WebCore.CSSCalcNodeRecord>,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    hasConversionData: Bool
) -> WebCore.CSSCalcSwiftNumericResult {
    guard let value = calcEvaluate(nodes, &resolver, hasConversionData: hasConversionData) else {
        return WebCore.CSSCalcSwiftNumericResult(value: 0, ok: 0)
    }
    return WebCore.CSSCalcSwiftNumericResult(value: value, ok: 1)
}
