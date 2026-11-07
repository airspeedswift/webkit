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

#if USE_SWIFT_CSS_SHORTHANDS_AND_TYPED_OM

// Without these, no operator in this file type-checks: WebCore's C++ operators name types these modules define.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif

internal import WebCore_Private.Core.CSSCalcSwiftTypes
internal import WebCore_Private.Core.CSSNumericValueSwiftTypes

/// Writes the calc() tree of the Typed OM value `source.root()` to `output`, as a CSSCalc::Tree's records, inside a
/// one-child sum when `wrapInSum`. Fails, writing nothing, where the value has no calc() tree, or, without
/// `wrapInSum`, where the tree's type has no calculation category.
///
/// Both facades are passed inout: CSSNumericValue::toCalcTree makes their states on its stack, passes them to this
/// call only, and destroys them after it returns. During the call Swift calls only these C++ functions: the facades'
/// `root()` and `adopt`; CSSNumericValue's `styleValueType()`, `mathOperand(_:)`, `unitValue()` and `unitType()`; and
/// CSSCalc::Type's `add`, `multiply`, `invert`, `consistentType`, `determineType`, `applyPercentHint` and
/// `calculationCategory`. None of them reaches either facade, script or another thread.
@_expose(Cxx)
func cssCalcConvertTypedOM(
    _ source: inout WebCore.CSSCalcSwiftTypedOMSource,
    _ output: inout WebCore.CSSCalcSwiftOutput,
    _ wrapInSum: Bool
) -> WebCore.CSSCalcSwiftParseResult {
    // The records are held on the stack until there are more than 32, as cssCalcParse holds a parse's.
    var recordBuffer = [32 of CalcRecord](repeating: CalcRecord())
    var arena = CalcArena(recordBuffer.mutableSpan)
    if wrapInSum {
        arena.append(.operation(.Sum, type: .number, childCount: 1))
    }
    guard let type = appendCalcRecords(of: source.root(), to: &arena),
        wrapInSum || type.calculationCategory() != nil
    else {
        return WebCore.CSSCalcSwiftParseResult(typeBits: 0, consumedTokens: 0, ok: 0, requiresConversionData: 0)
    }
    if wrapInSum {
        // The sum has the type of its one child.
        var sum = arena[0]
        sum.typeBits = type.bits
        sum.subtreeSize = UInt32(truncatingIfNeeded: arena.count) // A tree has far fewer than 2^32 nodes.
        arena[0] = sum
    }
    output.adopt(arena.span)
    return WebCore.CSSCalcSwiftParseResult(typeBits: type.bits, consumedTokens: 0, ok: 1, requiresConversionData: 0)
}

/// Appends the records of `value`'s calc() node, in pre-order, and returns its type. Returns nil, with `arena` as
/// it was, where the value has no node: an operand of a sum, a product, a negation, an inversion or a clamp has none,
/// or an operation's type cannot be made. A min() or max() leaves out each operand that has no node, and has none
/// only when no operand has one.
private func appendCalcRecords(of value: WebCore.CSSNumericValue, to arena: inout CalcArena) -> CalcType? {
    let valueType = value.styleValueType()
    if valueType == .CSSUnitValue {
        let leaf = CalcRecord.numeric(value.unitValue(), unit: value.unitType())
        arena.append(leaf)
        return CalcType(bits: leaf.typeBits)
    }

    let kind: CalcKind
    switch valueType {
    case .CSSMathSum:
        kind = .Sum
    case .CSSMathProduct:
        kind = .Product
    case .CSSMathMin:
        kind = .Min
    case .CSSMathMax:
        kind = .Max
    case .CSSMathNegate:
        kind = .Negate
    case .CSSMathInvert:
        kind = .Invert
    case .CSSMathClamp:
        kind = .Clamp
    default:
        preconditionFailure()
    }

    let start = arena.count
    arena.append(.operation(kind, type: .number, childCount: 0))
    var childCount = 0
    var type: CalcType?
    switch kind {
    case .Sum, .Product:
        while let operand = value.mathOperand(childCount) {
            guard let operandType = appendCalcRecords(of: operand, to: &arena) else {
                arena.truncate(to: start)
                return nil
            }
            if childCount == 0 {
                type = operandType
            } else {
                type = kind == .Sum ? type?.adding(operandType) : type?.multiplying(operandType)
            }
            childCount += 1
        }
    case .Min, .Max:
        let types = CalcFunctionTypes(kind)
        var index = 0
        while let operand = value.mathOperand(index) {
            index += 1
            guard let operandType = appendCalcRecords(of: operand, to: &arena) else {
                continue
            }
            type = childCount == 0 ? types.validated(operandType) : types.merge(type, types.validated(operandType))
            childCount += 1
        }
        if childCount == 0 {
            arena.truncate(to: start)
            return nil
        }
        type = type.flatMap { types.transform($0) }
    case .Negate, .Invert:
        guard let operand = value.mathOperand(0), let operandType = appendCalcRecords(of: operand, to: &arena) else {
            arena.truncate(to: start)
            return nil
        }
        type = kind == .Negate ? operandType : operandType.inverted()
        childCount = 1
    default:
        // Clamp's operands are lower, value and upper, as its records are; its type merges value, lower, then upper.
        guard let lowerOperand = value.mathOperand(0), let valueOperand = value.mathOperand(1),
            let upperOperand = value.mathOperand(2),
            let lower = appendCalcRecords(of: lowerOperand, to: &arena),
            let operand = appendCalcRecords(of: valueOperand, to: &arena),
            let upper = appendCalcRecords(of: upperOperand, to: &arena)
        else {
            arena.truncate(to: start)
            return nil
        }
        let types = CalcFunctionTypes(kind)
        type = types.merge(types.merge(types.validated(operand), types.validated(lower)), types.validated(upper))
        type = type.flatMap { types.transform($0) }
        childCount = 3
    }

    guard let type else {
        arena.truncate(to: start)
        return nil
    }
    var node = arena[start]
    node.typeBits = type.bits
    node.childCount = UInt32(truncatingIfNeeded: childCount) // A tree has far fewer than 2^32 nodes.
    node.subtreeSize = UInt32(truncatingIfNeeded: arena.count &- start) // start <= arena.count.
    arena[start] = node
    return type
}

#endif // USE_SWIFT_CSS_SHORTHANDS_AND_TYPED_OM
