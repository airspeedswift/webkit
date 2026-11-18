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
internal import WebCore_Private.Core.DocumentIsolationPolicy
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

/// parseDocumentIsolationPolicy(): the policy that the values of a response's Document-Isolation-Policy and
/// Document-Isolation-Policy-Report-Only headers give.
///
/// A null value is an absent header.
@_expose(Cxx)
func documentIsolationPolicyFromHeaders(
    _ header: consuming WTF.String,
    _ reportOnlyHeader: consuming WTF.String
) -> WebCore.DocumentIsolationPolicy {
    var policy = WebCore.DocumentIsolationPolicy()
    // An empty value is not an item, and leaves the policy as it is.
    if !header.isEmpty() {
        let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(header)
        if !bytes.isEmpty {
            documentIsolationPolicyReadHeader(bytes, reportOnly: false, into: &policy)
        } else {
            let units: Span<UInt16> = header.checkedSpan16()
            documentIsolationPolicyReadHeader(units, reportOnly: false, into: &policy)
        }
    }
    if !reportOnlyHeader.isEmpty() {
        let reportOnlyBytes: Span<UInt8> = WebCore.securityPoliciesSpan8(reportOnlyHeader)
        if !reportOnlyBytes.isEmpty {
            documentIsolationPolicyReadHeader(reportOnlyBytes, reportOnly: true, into: &policy)
        } else {
            let reportOnlyUnits: Span<UInt16> = reportOnlyHeader.checkedSpan16()
            documentIsolationPolicyReadHeader(reportOnlyUnits, reportOnly: true, into: &policy)
        }
    }
    return policy
}

/// The values DocumentIsolationPolicy::addPolicyHeadersTo() sets for the Document-Isolation-Policy and
/// Document-Isolation-Policy-Report-Only headers, each null when the header is not set.
@_expose(Cxx)
func documentIsolationPolicyHeaderValues(
    _ value: WebCore.DocumentIsolationPolicyValue,
    _ reportingEndpoint: consuming WTF.String,
    _ reportOnlyValue: WebCore.DocumentIsolationPolicyValue,
    _ reportOnlyReportingEndpoint: consuming WTF.String
) -> WebCore.SecurityPoliciesPolicyHeaderValues {
    var values = WebCore.SecurityPoliciesPolicyHeaderValues()
    if value != .None {
        values.value = documentIsolationPolicyHeaderValue(value, reportingEndpoint)
    }
    if reportOnlyValue != .None {
        values.reportOnlyValue = documentIsolationPolicyHeaderValue(reportOnlyValue, reportOnlyReportingEndpoint)
    }
    return values
}

// As for Cross-Origin-Embedder-Policy, report-to is only used with a policy value and has to be a string.
// https://github.com/WICG/document-isolation-policy/issues/10
// Sets the value, isolate-and-require-corp or isolate-and-credentialless, and the report-to string that one header gives,
// or the null string when it gives none, the report-only ones for `reportOnly`, and leaves the policy as it is unless
// the header's item is one of those tokens. obtainDocumentIsolationPolicy() drops isolate-and-credentialless where it
// is not supported.
private func documentIsolationPolicyReadHeader<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ characters: Span<CodeUnit>,
    reportOnly: Bool,
    into policy: inout WebCore.DocumentIsolationPolicy
) {
    guard let item = rfc8941PolicyItem(characters), item.bareItem.kind == .Token else {
        return
    }
    let value: WebCore.DocumentIsolationPolicyValue
    if rfc8941TextEquals(characters, item.bareItem, "isolate-and-require-corp") {
        value = .IsolateAndRequireCORP
    } else if rfc8941TextEquals(characters, item.bareItem, "isolate-and-credentialless") {
        value = .IsolateAndCredentialless
    } else {
        return
    }
    let reportingEndpoint: WTF.String
    if let reportTo = item.reportTo {
        reportingEndpoint = structuredFieldStringBody(characters, reportTo.start, reportTo.length, reportTo.integer)
    } else {
        reportingEndpoint = WTF.String()
    }
    if reportOnly {
        policy.reportOnlyValue = value
        policy.reportOnlyReportingEndpoint = reportingEndpoint
    } else {
        policy.value = value
        policy.reportingEndpoint = reportingEndpoint
    }
}

// The endpoint is escaped as an RFC 8941 string; the token is written alone when the endpoint is empty or cannot be
// one.
private func documentIsolationPolicyHeaderValue(
    _ value: WebCore.DocumentIsolationPolicyValue,
    _ reportingEndpoint: borrowing WTF.String
) -> WTF.String {
    let token = value == .IsolateAndCredentialless ? "isolate-and-credentialless" : "isolate-and-require-corp"
    if reportingEndpoint.isEmpty() {
        return rfc8941TokenString(token)
    }
    let escapedReportingEndpoint = rfc8941WithCharacters(
        reportingEndpoint,
        { escapeStructuredFieldStringBody($0) },
        { escapeStructuredFieldStringBody($0) }
    )
    if escapedReportingEndpoint.isNull() {
        return rfc8941TokenString(token)
    }
    return rfc8941TokenWithReportToHeaderValue(token, escapedReportingEndpoint)
}
