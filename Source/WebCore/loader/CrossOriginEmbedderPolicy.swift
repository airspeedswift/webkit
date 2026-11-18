// Copyright (C) 2021 Apple Inc. All rights reserved.
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
internal import WebCore_Private.Core.CrossOriginEmbedderPolicy
internal import WebCore_Private.Core.CrossOriginEmbedderPolicyValue
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

/// The policy that the values of a response's Cross-Origin-Embedder-Policy and
/// Cross-Origin-Embedder-Policy-Report-Only headers give, for obtainCrossOriginEmbedderPolicy() once the context and
/// the settings allow it.
///
/// A null value is an absent header. The credentialless token is read only where `supportsCredentialless`.
@_expose(Cxx)
func crossOriginEmbedderPolicyFromHeaders(
    _ coep: consuming WTF.String,
    _ coepReportOnly: consuming WTF.String,
    _ supportsCredentialless: Bool
) -> WebCore.CrossOriginEmbedderPolicy {
    var policy = WebCore.CrossOriginEmbedderPolicy()
    // An empty value is not an item, and leaves the policy as it is.
    if !coep.isEmpty() {
        let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(coep)
        if !bytes.isEmpty {
            crossOriginEmbedderPolicyReadHeader(bytes, reportOnly: false, supportsCredentialless, into: &policy)
        } else {
            let units: Span<UInt16> = coep.checkedSpan16()
            crossOriginEmbedderPolicyReadHeader(units, reportOnly: false, supportsCredentialless, into: &policy)
        }
    }
    if !coepReportOnly.isEmpty() {
        let reportOnlyBytes: Span<UInt8> = WebCore.securityPoliciesSpan8(coepReportOnly)
        if !reportOnlyBytes.isEmpty {
            crossOriginEmbedderPolicyReadHeader(reportOnlyBytes, reportOnly: true, supportsCredentialless, into: &policy)
        } else {
            let reportOnlyUnits: Span<UInt16> = coepReportOnly.checkedSpan16()
            crossOriginEmbedderPolicyReadHeader(reportOnlyUnits, reportOnly: true, supportsCredentialless, into: &policy)
        }
    }
    return policy
}

/// isRecognizedCrossOriginEmbedderPolicyToken() for 8-bit characters.
///
/// `token` is the characters of the caller's `StringView`, whose `String` the caller keeps allocated and unchanged, at
/// their length, for the call. Nothing this function calls writes them, and every Latin-1 code unit is a valid value.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isRecognizedCrossOriginEmbedderPolicyToken8(_ token: WebCore.HTTPHeaderLatin1Span, _ supportsCredentialless: Bool) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(token))
    return crossOriginEmbedderPolicyTokenIsRecognized(characters, supportsCredentialless)
}

/// isRecognizedCrossOriginEmbedderPolicyToken8() for 16-bit characters, which hold for the call in the same way, and
/// every UTF-16 code unit is a valid value.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isRecognizedCrossOriginEmbedderPolicyToken16(_ token: WebCore.HTTPHeaderUTF16Span, _ supportsCredentialless: Bool) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: token)
    return crossOriginEmbedderPolicyTokenIsRecognized(characters, supportsCredentialless)
}

/// isUnsupportedCrossOriginEmbedderPolicyToken() for 8-bit characters.
///
/// `token` is the characters of the caller's `StringView`, whose `String` the caller keeps allocated and unchanged, at
/// their length, for the call. Nothing this function calls writes them, and every Latin-1 code unit is a valid value.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isUnsupportedCrossOriginEmbedderPolicyToken8(_ token: WebCore.HTTPHeaderLatin1Span, _ supportsCredentialless: Bool) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(token))
    // A Span cannot be captured by the autoclosure of &&.
    if supportsCredentialless {
        return false
    }
    return crossOriginAccessControlEquals(characters, "credentialless")
}

/// isUnsupportedCrossOriginEmbedderPolicyToken8() for 16-bit characters, which hold for the call in the same way, and
/// every UTF-16 code unit is a valid value.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isUnsupportedCrossOriginEmbedderPolicyToken16(_ token: WebCore.HTTPHeaderUTF16Span, _ supportsCredentialless: Bool) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: token)
    // A Span cannot be captured by the autoclosure of &&.
    if supportsCredentialless {
        return false
    }
    return crossOriginAccessControlEquals(characters, "credentialless")
}

/// The values CrossOriginEmbedderPolicy::addPolicyHeadersTo() sets for the Cross-Origin-Embedder-Policy and
/// Cross-Origin-Embedder-Policy-Report-Only headers, each null when the header is not set.
@_expose(Cxx)
func crossOriginEmbedderPolicyHeaderValues(
    _ value: WebCore.CrossOriginEmbedderPolicyValue,
    _ reportingEndpoint: consuming WTF.String,
    _ reportOnlyValue: WebCore.CrossOriginEmbedderPolicyValue,
    _ reportOnlyReportingEndpoint: consuming WTF.String
) -> WebCore.SecurityPoliciesPolicyHeaderValues {
    var values = WebCore.SecurityPoliciesPolicyHeaderValues()
    if value != .UnsafeNone {
        values.value = crossOriginEmbedderPolicyHeaderValue(value, reportingEndpoint)
    }
    if reportOnlyValue != .UnsafeNone {
        values.reportOnlyValue = crossOriginEmbedderPolicyHeaderValue(reportOnlyValue, reportOnlyReportingEndpoint)
    }
    return values
}

// https://html.spec.whatwg.org/multipage/origin.html#compatible-with-cross-origin-isolation: whether the policy the
// header's item gives is require-corp, or credentialless where `supportsCredentialless`.
func crossOriginEmbedderPolicyIsCompatibleWithCrossOriginIsolation(_ header: borrowing WTF.String, _ supportsCredentialless: Bool) -> Bool {
    // An empty value is not an item.
    if header.isEmpty() {
        return false
    }
    let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(header)
    if !bytes.isEmpty {
        return crossOriginEmbedderPolicyItem(bytes, supportsCredentialless) != nil
    }
    let units: Span<UInt16> = header.checkedSpan16()
    return crossOriginEmbedderPolicyItem(units, supportsCredentialless) != nil
}

// Sets the value, require-corp or credentialless, and the report-to string that one header gives, the report-only ones
// for `reportOnly`, and leaves the policy as it is unless the header's item is the require-corp token, or the
// credentialless token where `supportsCredentialless`. report-to is only read as a string.
private func crossOriginEmbedderPolicyReadHeader<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ characters: Span<CodeUnit>,
    reportOnly: Bool,
    _ supportsCredentialless: Bool,
    into policy: inout WebCore.CrossOriginEmbedderPolicy
) {
    guard let found = crossOriginEmbedderPolicyItem(characters, supportsCredentialless) else {
        return
    }
    let (item, value) = found
    if reportOnly {
        policy.reportOnlyValue = value
    } else {
        policy.value = value
    }
    guard let reportTo = item.reportTo else {
        return
    }
    if reportOnly {
        policy.reportOnlyReportingEndpoint = structuredFieldStringBody(characters, reportTo.start, reportTo.length, reportTo.integer)
    } else {
        policy.reportingEndpoint = structuredFieldStringBody(characters, reportTo.start, reportTo.length, reportTo.integer)
    }
}

// The header's item and its value when it is the require-corp token, or the credentialless token where
// `supportsCredentialless`.
private func crossOriginEmbedderPolicyItem<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ supportsCredentialless: Bool
) -> (RFC8941PolicyItem, WebCore.CrossOriginEmbedderPolicyValue)? {
    guard let item = rfc8941PolicyItem(characters), item.bareItem.kind == .Token else {
        return nil
    }
    if rfc8941TextEquals(characters, item.bareItem, "require-corp") {
        return (item, .RequireCORP)
    }
    if supportsCredentialless && rfc8941TextEquals(characters, item.bareItem, "credentialless") {
        return (item, .Credentialless)
    }
    return nil
}

private func crossOriginEmbedderPolicyTokenIsRecognized<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ token: Span<CodeUnit>,
    _ supportsCredentialless: Bool
) -> Bool {
    crossOriginAccessControlEquals(token, "require-corp") || crossOriginAccessControlEquals(token, "unsafe-none")
        || (supportsCredentialless && crossOriginAccessControlEquals(token, "credentialless"))
}

// The endpoint is written between the quotes as it is, without escaping.
private func crossOriginEmbedderPolicyHeaderValue(
    _ value: WebCore.CrossOriginEmbedderPolicyValue,
    _ reportingEndpoint: borrowing WTF.String
) -> WTF.String {
    let token = value == .Credentialless ? "credentialless" : "require-corp"
    if reportingEndpoint.isEmpty() {
        return rfc8941TokenString(token)
    }
    return rfc8941TokenWithReportToHeaderValue(token, reportingEndpoint)
}
