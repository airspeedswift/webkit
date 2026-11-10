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

// MARK: - Entry points
//
// Each entry that reads a tree receives its records as a std::span and converts it to a Span once, at entry; the
// Span is never stored and does not outlive the call. The caller passes the records of a CSSCalc::Tree or a
// Style::Calculation::Tree it holds by const reference for the whole call, and nothing reached during the call writes
// them: the facades' members read conversion data, the style builder state and the tree's payloads, append to a
// separate output, and call no Swift entry on the same tree. The records are integers and doubles, which have no
// invalid bit patterns. FIXME: Receive them as a `Span` once an exposed function can (rdar://186723514).
//
// Each facade (CSSCalcSwiftTypes.h) is passed inout: the calling C++ function makes its state on the stack, passes it
// to this call only, and destroys it after the call returns, so nothing else reaches it while Swift holds it. A
// calc-mix() weight or a random() key can hold a math function of its own, so CSSCalcSwiftParser.consumeCalcMixWeight
// and consumeRandomSharing, CSSCalcSwiftResolver.resolveCalcMixWeight and CSSCalcSwiftSerializer.appendPayload can call
// one of these entries again for that nested tree; the nested call makes its own states and reaches none of this call's
// facades. Swift calls only the members CSSCalcSwiftTypes.h declares on the facades: CSSCalcSwiftParser,
// CSSCalcSwiftResolver, CSSCalcSwiftSerializer, CSSCalcSwiftNumericValueBuilder, CSSCalcSwiftOutput,
// StyleCalcSwiftOutput and StyleCalcSwiftDumpSink.

/// Parses a math function's arguments, or a bare `<calc-sum>`, from `parser`'s tokens into `output`, simplifying
/// with `resolver` as it builds. Fails in the result rather than with an empty tree.
///
/// Records and facades: see Entry points above.
@_expose(Cxx)
func cssCalcParse(
    _ parser: inout WebCore.CSSCalcSwiftParser,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    _ output: inout WebCore.CSSCalcSwiftOutput,
    _ category: UInt8,
    _ function: UInt16,
    _ flags: UInt32,
    _ simplification: WebCore.CSSCalcSwiftSimplificationOptions
) -> WebCore.CSSCalcSwiftParseResult {
    let options = CalcParseOptions(category: category, function: function, flags: flags, simplification: simplification)
    return cssCalcParseImpl(&parser, &resolver, &output, options)
}

/// Writes the simplification of `nodes` to `output`, whose payloads start as a copy of the tree's.
///
/// Records and facades: see Entry points above.
@_expose(Cxx)
func cssCalcSimplify(
    _ nodes: WebCore.CSSCalcNodeSpan,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    _ output: inout WebCore.CSSCalcSwiftOutput,
    _ options: WebCore.CSSCalcSwiftSimplificationOptions
) {
    cssCalcSimplifyImpl(unsafe Span(_unsafeCxxSpan: nodes), &resolver, &output, options)
}

/// The value of the tree `nodes`, or a result that is not ok when it does not resolve.
///
/// Records and facades: see Entry points above.
@_expose(Cxx)
func cssCalcEvaluate(
    _ nodes: WebCore.CSSCalcNodeSpan,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    _ hasConversionData: Bool
) -> WebCore.CSSCalcSwiftNumericResult {
    cssCalcEvaluateImpl(unsafe Span(_unsafeCxxSpan: nodes), &resolver, hasConversionData: hasConversionData)
}

/// Appends the serialization of the tree `nodes` to `serializer`, clamped to the range at the computed stage, and
/// without its outermost grouping parentheses as a math function's argument.
///
/// Records and facades: see Entry points above.
@_expose(Cxx)
func cssCalcSerialize(
    _ nodes: WebCore.CSSCalcNodeSpan,
    _ serializer: inout WebCore.CSSCalcSwiftSerializer,
    _ computed: Bool,
    _ rangeMin: Double,
    _ rangeMax: Double,
    _ asFunctionArgument: Bool
) {
    cssCalcSerializeImpl(
        unsafe Span(_unsafeCxxSpan: nodes),
        &serializer,
        computed: computed,
        rangeMin: rangeMin,
        rangeMax: rangeMax,
        asFunctionArgument: asFunctionArgument
    )
}

/// Builds the CSSNumericValue of the tree `nodes` with `builder`; false when it has none.
///
/// Records and facades: see Entry points above.
@_expose(Cxx)
func cssCalcReify(_ nodes: WebCore.CSSCalcNodeSpan, _ builder: inout WebCore.CSSCalcSwiftNumericValueBuilder) -> Bool {
    cssCalcReifyImpl(unsafe Span(_unsafeCxxSpan: nodes), &builder)
}

/// Writes the Style::Calculation tree of the simplification of `nodes` to `output`.
///
/// Records and facades: see Entry points above.
@_expose(Cxx)
func styleCalcToStyle(
    _ nodes: WebCore.CSSCalcNodeSpan,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    _ output: inout WebCore.StyleCalcSwiftOutput,
    _ options: WebCore.CSSCalcSwiftSimplificationOptions
) {
    toStyleImpl(unsafe Span(_unsafeCxxSpan: nodes), &resolver, &output, options)
}

/// Writes the CSSCalc tree of the Style::Calculation tree `nodes` to `output`, and returns its type.
///
/// Records and facades: see Entry points above.
@_expose(Cxx)
func styleCalcToCSS(
    _ nodes: WebCore.StyleCalcNodeSpan,
    _ resolver: inout WebCore.CSSCalcSwiftResolver,
    _ output: inout WebCore.CSSCalcSwiftOutput,
    _ category: UInt8
) -> UInt64 {
    toCSSImpl(unsafe Span(_unsafeCxxSpan: nodes), &resolver, &output, category: category)
}

/// The value of the Style::Calculation tree `nodes`.
///
/// Records and facades: see Entry points above.
@_expose(Cxx)
func styleCalcEvaluate(
    _ nodes: WebCore.StyleCalcNodeSpan,
    _ percentResolutionLength: Double,
    _ usedZoom: Double,
    _ sizeResolutionLength: Double
) -> Double {
    evaluateImpl(
        unsafe Span(_unsafeCxxSpan: nodes),
        percentResolutionLength: percentResolutionLength,
        usedZoom: usedZoom,
        sizeResolutionLength: sizeResolutionLength
    )
}

/// Writes `a` and `b` combined by the StyleCalcCombination `combination` to `output`.
///
/// Records and facades: see Entry points above.
@_expose(Cxx)
func styleCalcCombine(
    _ combination: UInt8,
    _ a: WebCore.StyleCalcNodeSpan,
    _ b: WebCore.StyleCalcNodeSpan,
    _ progress: Double,
    _ output: inout WebCore.StyleCalcSwiftOutput
) {
    combineImpl(combination, unsafe Span(_unsafeCxxSpan: a), unsafe Span(_unsafeCxxSpan: b), progress: progress, &output)
}

/// Writes `nodes` with every `size` replaced by `insertion` to `output`; false when the result would be too large.
///
/// Records and facades: see Entry points above.
@_expose(Cxx)
func styleCalcSubstituteSize(
    _ nodes: WebCore.StyleCalcNodeSpan,
    _ insertion: WebCore.StyleCalcNodeSpan,
    _ output: inout WebCore.StyleCalcSwiftOutput
) -> Bool {
    substituteSizeImpl(unsafe Span(_unsafeCxxSpan: nodes), unsafe Span(_unsafeCxxSpan: insertion), &output)
}

/// Writes `nodes` with every percentage P replaced by `size * P / 100` to `output`.
///
/// Records and facades: see Entry points above.
@_expose(Cxx)
func styleCalcDePercentify(_ nodes: WebCore.StyleCalcNodeSpan, _ output: inout WebCore.StyleCalcSwiftOutput) {
    dePercentifyImpl(unsafe Span(_unsafeCxxSpan: nodes), &output)
}

/// The depth of the tree `nodes`, as Style::Calculation::computeDepth counts it.
///
/// Records and facades: see Entry points above.
@_expose(Cxx)
func styleCalcDepth(_ nodes: WebCore.StyleCalcNodeSpan) -> UInt {
    depthImpl(unsafe Span(_unsafeCxxSpan: nodes))
}

/// Writes the tree `nodes` to `sink`'s TextStream.
///
/// Records and facades: see Entry points above.
@_expose(Cxx)
func styleCalcDump(_ nodes: WebCore.StyleCalcNodeSpan, _ sink: inout WebCore.StyleCalcSwiftDumpSink) {
    dumpImpl(unsafe Span(_unsafeCxxSpan: nodes), &sink)
}
