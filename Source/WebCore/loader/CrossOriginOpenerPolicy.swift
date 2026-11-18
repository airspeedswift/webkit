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
internal import WebCore_Private.Core.CrossOriginOpenerPolicy
internal import WebCore_Private.Core.FrameLoaderTypes
internal import WebCore_Private.Core.SecurityOrigin
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

/// https://html.spec.whatwg.org/multipage/origin.html#obtain-coop, once the response's URL is potentially
/// trustworthy: the policy that the values of a response's Cross-Origin-Opener-Policy and
/// Cross-Origin-Opener-Policy-Report-Only headers give, before its Cross-Origin-Embedder-Policy values are read, so
/// that a same-origin token gives same-origin.
///
/// A null value is an absent header.
@_expose(Cxx)
func crossOriginOpenerPolicyFromHeaders(
    _ coop: consuming WTF.String,
    _ coopReportOnly: consuming WTF.String
) -> WebCore.CrossOriginOpenerPolicy {
    var policy = WebCore.CrossOriginOpenerPolicy()
    // An empty value is not an item, and leaves the policy as it is.
    if !coop.isEmpty() {
        let bytes: Span<UInt8> = WebCore.securityPoliciesSpan8(coop)
        if !bytes.isEmpty {
            crossOriginOpenerPolicyReadHeader(bytes, reportOnly: false, into: &policy)
        } else {
            let units: Span<UInt16> = coop.checkedSpan16()
            crossOriginOpenerPolicyReadHeader(units, reportOnly: false, into: &policy)
        }
    }
    if !coopReportOnly.isEmpty() {
        let reportOnlyBytes: Span<UInt8> = WebCore.securityPoliciesSpan8(coopReportOnly)
        if !reportOnlyBytes.isEmpty {
            crossOriginOpenerPolicyReadHeader(reportOnlyBytes, reportOnly: true, into: &policy)
        } else {
            let reportOnlyUnits: Span<UInt16> = coopReportOnly.checkedSpan16()
            crossOriginOpenerPolicyReadHeader(reportOnlyUnits, reportOnly: true, into: &policy)
        }
    }
    return policy
}

/// `policy`, which crossOriginOpenerPolicyFromHeaders() gave, once the response's Cross-Origin-Embedder-Policy values
/// are read: a same-origin value is same-origin-plus-COEP where the embedder policy that
/// obtainCrossOriginEmbedderPolicy() gives for a secure context with no settings to read is compatible with cross-origin
/// isolation (require-corp, or credentialless where `supportsCredentialless`), the enforced value where `coep` is and
/// the report-only value where either header is.
///
/// A null value is an absent header.
@_expose(Cxx)
func crossOriginOpenerPolicyWithEmbedderPolicy(
    _ policy: consuming WebCore.CrossOriginOpenerPolicy,
    _ coep: consuming WTF.String,
    _ coepReportOnly: consuming WTF.String,
    _ supportsCredentialless: Bool
) -> WebCore.CrossOriginOpenerPolicy {
    let isolates = crossOriginEmbedderPolicyIsCompatibleWithCrossOriginIsolation(coep, supportsCredentialless)
    if policy.value == .SameOrigin && isolates {
        policy.value = .SameOriginPlusCOEP
    }
    if policy.reportOnlyValue == .SameOrigin && (isolates || crossOriginEmbedderPolicyIsCompatibleWithCrossOriginIsolation(coepReportOnly, supportsCredentialless)) {
        policy.reportOnlyValue = .SameOriginPlusCOEP
    }
    return policy
}

// https://html.spec.whatwg.org/multipage/origin.html#check-browsing-context-group-switch-coop-value
extension WebCore {
    /// Whether the active document's and the response's COOP values and origins need a browsing context group switch.
    @cxx
    @implementation
    public static func coopValuesRequireBrowsingContextGroupSwitch(
        _ isInitialAboutBlank: WebCore.IsInitialAboutBlank,
        _ activeDocumentCOOPValue: WebCore.CrossOriginOpenerPolicyValue,
        _ activeDocumentNavigationOrigin: borrowing WebCore.SecurityOrigin,
        _ responseCOOPValue: WebCore.CrossOriginOpenerPolicyValue,
        _ responseOrigin: borrowing WebCore.SecurityOrigin
    ) -> Bool {
        // Matching COOP compares the origins only for equal values other than unsafe-none and noopener-allow-popups.
        let isSameOrigin =
            activeDocumentCOOPValue == responseCOOPValue && responseCOOPValue != .UnsafeNone
            && responseCOOPValue != .NoopenerAllowPopups && activeDocumentNavigationOrigin.isSameOriginAs(responseOrigin)
        return crossOriginOpenerPolicyValuesRequireBrowsingContextGroupSwitch(
            isInitialAboutBlank,
            activeDocumentCOOPValue,
            responseCOOPValue,
            isSameOrigin
        )
    }
}

/// https://html.spec.whatwg.org/multipage/origin.html#check-bcg-switch-navigation-report-only: whether enforcing the
/// report-only values would switch browsing context groups where the enforced ones do not. `isSameOrigin` is whether
/// the active document's navigation origin is same origin with the response's.
@_expose(Cxx)
func crossOriginOpenerPolicyReportOnlyRequiresBrowsingContextGroupSwitch(
    _ isInitialAboutBlank: WebCore.IsInitialAboutBlank,
    _ activeDocumentCOOPValue: WebCore.CrossOriginOpenerPolicyValue,
    _ activeDocumentCOOPReportOnlyValue: WebCore.CrossOriginOpenerPolicyValue,
    _ responseCOOPValue: WebCore.CrossOriginOpenerPolicyValue,
    _ responseCOOPReportOnlyValue: WebCore.CrossOriginOpenerPolicyValue,
    _ isSameOrigin: Bool
) -> Bool {
    if !crossOriginOpenerPolicyValuesRequireBrowsingContextGroupSwitch(
        isInitialAboutBlank,
        activeDocumentCOOPReportOnlyValue,
        responseCOOPReportOnlyValue,
        isSameOrigin
    ) {
        return false
    }
    if crossOriginOpenerPolicyValuesRequireBrowsingContextGroupSwitch(
        isInitialAboutBlank,
        activeDocumentCOOPReportOnlyValue,
        responseCOOPValue,
        isSameOrigin
    ) {
        return true
    }
    if crossOriginOpenerPolicyValuesRequireBrowsingContextGroupSwitch(
        isInitialAboutBlank,
        activeDocumentCOOPValue,
        responseCOOPReportOnlyValue,
        isSameOrigin
    ) {
        return true
    }
    return false
}

/// isRecognizedCrossOriginOpenerPolicyToken() for 8-bit characters.
///
/// `token` is the characters of the caller's `StringView`, whose `String` the caller keeps allocated and unchanged, at
/// their length, for the call. Nothing this function calls writes them, and every Latin-1 code unit is a valid value.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isRecognizedCrossOriginOpenerPolicyToken8(_ token: WebCore.HTTPHeaderLatin1Span) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(token))
    return crossOriginOpenerPolicyTokenIsRecognized(characters)
}

/// isRecognizedCrossOriginOpenerPolicyToken8() for 16-bit characters, which hold for the call in the same way, and
/// every UTF-16 code unit is a valid value.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isRecognizedCrossOriginOpenerPolicyToken16(_ token: WebCore.HTTPHeaderUTF16Span) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: token)
    return crossOriginOpenerPolicyTokenIsRecognized(characters)
}

/// The values CrossOriginOpenerPolicy::addPolicyHeadersTo() sets for the Cross-Origin-Opener-Policy and
/// Cross-Origin-Opener-Policy-Report-Only headers, each null when the header is not set.
@_expose(Cxx)
func crossOriginOpenerPolicyHeaderValues(
    _ value: WebCore.CrossOriginOpenerPolicyValue,
    _ reportingEndpoint: consuming WTF.String,
    _ reportOnlyValue: WebCore.CrossOriginOpenerPolicyValue,
    _ reportOnlyReportingEndpoint: consuming WTF.String
) -> WebCore.SecurityPoliciesPolicyHeaderValues {
    var values = WebCore.SecurityPoliciesPolicyHeaderValues()
    if value != .UnsafeNone {
        values.value = crossOriginOpenerPolicyHeaderValue(value, reportingEndpoint)
    }
    if reportOnlyValue != .UnsafeNone {
        values.reportOnlyValue = crossOriginOpenerPolicyHeaderValue(reportOnlyValue, reportOnlyReportingEndpoint)
    }
    return values
}

// Sets the value and the report-to string that one header gives, the report-only ones for `reportOnly`, and leaves
// each as it is when the header gives none. The header is an item whose bare item is a token, compared
// case-sensitively; any token takes report-to, which is only read as a string.
private func crossOriginOpenerPolicyReadHeader<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ characters: Span<CodeUnit>,
    reportOnly: Bool,
    into policy: inout WebCore.CrossOriginOpenerPolicy
) {
    guard let item = rfc8941PolicyItem(characters), item.bareItem.kind == .Token else {
        return
    }
    let value: WebCore.CrossOriginOpenerPolicyValue?
    if rfc8941TextEquals(characters, item.bareItem, "same-origin") {
        value = .SameOrigin
    } else if rfc8941TextEquals(characters, item.bareItem, "same-origin-allow-popups") {
        value = .SameOriginAllowPopups
    } else if rfc8941TextEquals(characters, item.bareItem, "noopener-allow-popups") {
        value = .NoopenerAllowPopups
    } else {
        value = nil
    }
    if let value {
        if reportOnly {
            policy.reportOnlyValue = value
        } else {
            policy.value = value
        }
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

private func crossOriginOpenerPolicyTokenIsRecognized<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ token: Span<CodeUnit>
) -> Bool {
    crossOriginAccessControlEquals(token, "same-origin")
        || crossOriginAccessControlEquals(token, "same-origin-allow-popups")
        || crossOriginAccessControlEquals(token, "noopener-allow-popups")
        || crossOriginAccessControlEquals(token, "unsafe-none")
}

// The value is not unsafe-none. The endpoint is written between the quotes as it is, without escaping.
private func crossOriginOpenerPolicyHeaderValue(
    _ value: WebCore.CrossOriginOpenerPolicyValue,
    _ reportingEndpoint: borrowing WTF.String
) -> WTF.String {
    let token: Swift.String
    switch value {
    case .SameOrigin, .SameOriginPlusCOEP:
        token = "same-origin"
    case .SameOriginAllowPopups:
        token = "same-origin-allow-popups"
    case .NoopenerAllowPopups:
        token = "noopener-allow-popups"
    case .UnsafeNone:
        token = "unsafe-none"
    @unknown default:
        token = "unsafe-none"
    }
    if reportingEndpoint.isEmpty() {
        return rfc8941TokenString(token)
    }
    return rfc8941TokenWithReportToHeaderValue(token, reportingEndpoint)
}

// https://html.spec.whatwg.org/multipage/origin.html#check-browsing-context-group-switch-coop-value
private func crossOriginOpenerPolicyValuesRequireBrowsingContextGroupSwitch(
    _ isInitialAboutBlank: WebCore.IsInitialAboutBlank,
    _ activeDocumentCOOPValue: WebCore.CrossOriginOpenerPolicyValue,
    _ responseCOOPValue: WebCore.CrossOriginOpenerPolicyValue,
    _ isSameOrigin: Bool
) -> Bool {
    if isInitialAboutBlank == .Yes {
        return crossOriginOpenerPolicyValuesRequireBrowsingContextGroupSwitchForPopup(
            activeDocumentCOOPValue,
            responseCOOPValue,
            isSameOrigin
        )
    }
    return !crossOriginOpenerPolicyValuesMatch(activeDocumentCOOPValue, responseCOOPValue, isSameOrigin)
}

// https://html.spec.whatwg.org/multipage/origin.html#check-browsing-context-group-switch-coop-value-popup
private func crossOriginOpenerPolicyValuesRequireBrowsingContextGroupSwitchForPopup(
    _ activeDocumentCOOPValue: WebCore.CrossOriginOpenerPolicyValue,
    _ responseCOOPValue: WebCore.CrossOriginOpenerPolicyValue,
    _ isSameOrigin: Bool
) -> Bool {
    if responseCOOPValue == .NoopenerAllowPopups {
        return true
    }
    if (activeDocumentCOOPValue == .SameOriginAllowPopups || activeDocumentCOOPValue == .NoopenerAllowPopups)
        && responseCOOPValue == .UnsafeNone
    {
        return false
    }
    return !crossOriginOpenerPolicyValuesMatch(activeDocumentCOOPValue, responseCOOPValue, isSameOrigin)
}

// https://html.spec.whatwg.org/multipage/origin.html#matching-coop
private func crossOriginOpenerPolicyValuesMatch(
    _ activeDocumentCOOPValue: WebCore.CrossOriginOpenerPolicyValue,
    _ responseCOOPValue: WebCore.CrossOriginOpenerPolicyValue,
    _ isSameOrigin: Bool
) -> Bool {
    if activeDocumentCOOPValue == .UnsafeNone && responseCOOPValue == .UnsafeNone {
        return true
    }
    if activeDocumentCOOPValue == .UnsafeNone || responseCOOPValue == .UnsafeNone {
        return false
    }
    if responseCOOPValue == .NoopenerAllowPopups {
        return false
    }
    return activeDocumentCOOPValue == responseCOOPValue && isSameOrigin
}
