// Copyright (C) 2025 Shopify Inc. All rights reserved.
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

// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// them name (rdar://192229293).
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.Core.IntegrityPolicy
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

private typealias StructuredFieldStep = WebCore.HTTPHeaderStructuredFieldStep

/// `processIntegrityPolicy()`: the integrity policy of the header value `header`, or none when it is not an RFC 8941
/// dictionary (https://w3c.github.io/webappsec-subresource-integrity/#processing-an-integrity-policy).
@_expose(Cxx)
func integrityPolicyFromHeader(_ header: consuming WTF.String) -> WebCore.SecurityPoliciesOptionalIntegrityPolicy {
    if header.isEmpty() {
        return WebCore.SecurityPoliciesOptionalIntegrityPolicy()
    }
    if header.is8Bit() {
        return integrityPolicyFromHeader(WTF.bytesOfLatin1Characters(header.span8()))
    }
    return integrityPolicyFromHeader(header.checkedSpan16())
}

private func integrityPolicyFromHeader<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ header: Span<CodeUnit>
) -> WebCore.SecurityPoliciesOptionalIntegrityPolicy {
    // 2. Let dictionary be the result of getting a structured field value from headers given headerName and "dictionary".
    var buffer = InlineArray<32, StructuredFieldStep>(repeating: StructuredFieldStep())
    var steps = buffer.mutableSpan
    let count = parseStructuredFieldBody(header, .Dictionary, &steps)
    if count < 0 {
        return WebCore.SecurityPoliciesOptionalIntegrityPolicy()
    }
    if count <= 32 {
        return integrityPolicy(header, steps.span.extracting(0..<Int(count)))
    }
    var largeBuffer = [StructuredFieldStep](repeating: StructuredFieldStep(), count: Int(count))
    var largeSteps = largeBuffer.mutableSpan
    _ = parseStructuredFieldBody(header, .Dictionary, &largeSteps)
    return integrityPolicy(header, largeSteps.span)
}

/// The integrity policy of a dictionary's steps.
///
/// As RFC8941::parseDictionaryStructuredFieldValue() reads them, a byte sequence anywhere that is not base64 makes the
/// value not a dictionary, and a key given twice keeps its last value.
private func integrityPolicy<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ header: Span<CodeUnit>,
    _ steps: Span<StructuredFieldStep>
) -> WebCore.SecurityPoliciesOptionalIntegrityPolicy {
    var blockedDestinations: Range<Int>? = nil
    var sources: Range<Int>? = nil
    var endpoints: Range<Int>? = nil
    var index = 0
    while index < steps.count {
        let key = integrityPolicyText(steps[index])
        index += 1
        // The steps of the member's items and their parameters when its value is an inner list, else nil.
        var innerList: Range<Int>? = nil
        if steps[index].kind == .InnerListStart {
            index += 1
            let start = index
            while steps[index].kind != .InnerListEnd {
                guard integrityPolicyIsDecodable(header, steps[index]) else {
                    return WebCore.SecurityPoliciesOptionalIntegrityPolicy()
                }
                index += 1
                guard integrityPolicySkipParameters(header, steps, &index) else {
                    return WebCore.SecurityPoliciesOptionalIntegrityPolicy()
                }
            }
            innerList = start..<index
            index += 1
        } else {
            guard integrityPolicyIsDecodable(header, steps[index]) else {
                return WebCore.SecurityPoliciesOptionalIntegrityPolicy()
            }
            index += 1
        }
        guard integrityPolicySkipParameters(header, steps, &index) else {
            return WebCore.SecurityPoliciesOptionalIntegrityPolicy()
        }

        let name = header.extracting(key)
        if crossOriginAccessControlEquals(name, "blocked-destinations") {
            blockedDestinations = innerList
        } else if crossOriginAccessControlEquals(name, "sources") {
            sources = innerList
        } else if crossOriginAccessControlEquals(name, "endpoints") {
            endpoints = innerList
        }
    }

    // 1. Let integrityPolicy be a new integrity policy struct.
    var policy = WebCore.IntegrityPolicy()
    // 4. If dictionary["blocked-destinations"] exists:
    // 4.1. If its value contains "script", append "script" to integrityPolicy’s blocked destinations.
    if let blockedDestinations {
        var tokens = IntegrityPolicyInnerListTokens(steps.extracting(blockedDestinations))
        while let token = tokens.next() {
            if crossOriginAccessControlEquals(header.extracting(token), "script") {
                policy.blockedDestinations.append(consuming: CodeUnit.httpHeaderString(header.extracting(token)))
            }
        }
    }
    // 3. If dictionary["sources"] ... value contains "inline", append "inline" to integrityPolicy’s sources.
    if let sources {
        var tokens = IntegrityPolicyInnerListTokens(steps.extracting(sources))
        while let token = tokens.next() {
            if crossOriginAccessControlEquals(header.extracting(token), "inline") {
                policy.sources.append(consuming: CodeUnit.httpHeaderString(header.extracting(token)))
            }
        }
    } else {
        // 3. If dictionary["sources"] does not exist, append "inline" to integrityPolicy’s sources.
        policy.sources.append(consuming: rfc8941TokenString("inline"))
    }
    if let endpoints {
        var tokens = IntegrityPolicyInnerListTokens(steps.extracting(endpoints))
        while let token = tokens.next() {
            policy.endpoints.append(consuming: CodeUnit.httpHeaderString(header.extracting(token)))
        }
    }
    return WebCore.SecurityPoliciesOptionalIntegrityPolicy(policy)
}

/// The text of each token among the items of an inner list, in order, from the steps of its items and their parameters.
///
/// A parameter's key is followed by its value, which is not an item.
private struct IntegrityPolicyInnerListTokens: ~Escapable {
    private let steps: Span<StructuredFieldStep>
    private var index = 0
    private var followsParameterKey = false

    @_lifetime(copy steps)
    init(_ steps: Span<StructuredFieldStep>) {
        self.steps = steps
    }

    mutating func next() -> Range<Int>? {
        while index < steps.count {
            let step = steps[index]
            index += 1
            let isItem = !followsParameterKey
            followsParameterKey = step.kind == .ParameterKey
            if isItem && step.kind == .Token {
                return integrityPolicyText(step)
            }
        }
        return nil
    }
}

/// The range of a key's, token's or byte sequence's text in the value.
private func integrityPolicyText(_ step: StructuredFieldStep) -> Range<Int> {
    let start = Int(step.start)
    // A 32-bit start and length cannot overflow Int.
    return start..<start &+ Int(step.length)
}

/// Whether a step is not a byte sequence, or one that base64 decodes.
private func integrityPolicyIsDecodable<CodeUnit: HTTPHeaderStringCodeUnit>(_ header: Span<CodeUnit>, _ step: StructuredFieldStep) -> Bool {
    step.kind != .ByteSequence || structuredFieldBase64Decodes(header.extracting(integrityPolicyText(step)), url: false)
}

/// Moves `index` past the parameters at it, each a key and a bare item.
///
/// False when one of them is a byte sequence that does not decode.
private func integrityPolicySkipParameters<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ header: Span<CodeUnit>,
    _ steps: Span<StructuredFieldStep>,
    _ index: inout Int
) -> Bool {
    while index < steps.count && steps[index].kind == .ParameterKey {
        index += 1
        guard integrityPolicyIsDecodable(header, steps[index]) else {
            return false
        }
        index += 1
    }
    return true
}
