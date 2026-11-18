// Copyright (C) 2011 Google Inc. All rights reserved.
// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//
// 1.  Redistributions of source code must retain the above copyright
//     notice, this list of conditions and the following disclaimer.
// 2.  Redistributions in binary form must reproduce the above copyright
//     notice, this list of conditions and the following disclaimer in the
//     documentation and/or other materials provided with the distribution.
// 3.  Neither the name of Google, Inc. ("Google") nor the names of
//     its contributors may be used to endorse or promote products derived
//     from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY GOOGLE AND ITS CONTRIBUTORS "AS IS" AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL APPLE OR ITS CONTRIBUTORS BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
// THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

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
internal import WebCore_Private.Core.ReferrerPolicy
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch

/// `SecurityPolicy::generateReferrerHeader()`: which referrer `policy` sends for a request to a URL that is `https` or
/// not, from a referrer that is empty or not, in the HTTP family or not, and `https`, `http` or neither (each as
/// `URL::protocolIs()` tests it).
///
/// When the outcome depends on whether the referrer's origin can request the URL, it is `NeedsCanRequest` until
/// `canRequestIsKnown`, and then `canRequest` decides. When it depends on the schemes, it is `NeedsSchemes` until
/// `schemesAreKnown`.
@_expose(Cxx)
func securityPolicyReferrerOutcome(
    _ policy: WebCore.ReferrerPolicy,
    _ referrerIsEmpty: Bool,
    _ referrerIsHTTPFamily: Bool,
    _ schemesAreKnown: Bool,
    _ referrerIsHTTPS: Bool,
    _ referrerIsHTTP: Bool,
    _ urlIsHTTPS: Bool,
    _ canRequestIsKnown: Bool,
    _ canRequest: Bool
) -> WebCore.SecurityPolicyReferrerOutcome {
    if referrerIsEmpty || !referrerIsHTTPFamily {
        return .None
    }

    // What the policy sends unless the referrer is hidden.
    let outcomeUnlessHidden: WebCore.SecurityPolicyReferrerOutcome
    switch policy {
    case .EmptyString:
        // Callers never pass the empty policy; it acts as no-referrer-when-downgrade.
        assertionFailure()
        outcomeUnlessHidden = .Full
    case .NoReferrer:
        return .None
    case .NoReferrerWhenDowngrade:
        outcomeUnlessHidden = .Full
    case .SameOrigin:
        if !canRequestIsKnown {
            return .NeedsCanRequest
        }
        if !canRequest {
            return .None
        }
        outcomeUnlessHidden = .Full
    case .Origin:
        return .Origin
    case .StrictOrigin:
        outcomeUnlessHidden = .Origin
    case .OriginWhenCrossOrigin:
        if !canRequestIsKnown {
            return .NeedsCanRequest
        }
        if !canRequest {
            return .Origin
        }
        outcomeUnlessHidden = .Full
    case .StrictOriginWhenCrossOrigin:
        if !canRequestIsKnown {
            return .NeedsCanRequest
        }
        outcomeUnlessHidden = canRequest ? .Full : .Origin
    case .UnsafeUrl:
        return .Full
    @unknown default:
        outcomeUnlessHidden = .Full
    }
    if !schemesAreKnown {
        return .NeedsSchemes
    }
    return securityPolicyShouldHideReferrer(referrerIsHTTPS, referrerIsHTTP, urlIsHTTPS) ? .None : outcomeUnlessHidden
}

/// `SecurityPolicy::generateOriginHeader()`: whether referrer `policy` sends the origin or `null` for a request to a URL
/// that is `https` or not, from an origin whose protocol is `https` or not.
///
/// When the outcome depends on whether the origin can request the URL, it is `NeedsCanRequest` until
/// `canRequestIsKnown`, and then `canRequest` decides. When it depends on the schemes, it is `NeedsSchemes` until
/// `schemesAreKnown`. `None` is `null`.
@_expose(Cxx)
func securityPolicyOriginHeaderOutcome(
    _ policy: WebCore.ReferrerPolicy,
    _ schemesAreKnown: Bool,
    _ urlIsHTTPS: Bool,
    _ originIsHTTPS: Bool,
    _ canRequestIsKnown: Bool,
    _ canRequest: Bool
) -> WebCore.SecurityPolicyReferrerOutcome {
    switch policy {
    case .NoReferrer:
        return .None
    case .NoReferrerWhenDowngrade, .StrictOrigin, .StrictOriginWhenCrossOrigin:
        if !schemesAreKnown {
            return .NeedsSchemes
        }
        if originIsHTTPS && !urlIsHTTPS {
            return .None
        }
    case .SameOrigin:
        if !canRequestIsKnown {
            return .NeedsCanRequest
        }
        if !canRequest {
            return .None
        }
    case .EmptyString, .Origin, .OriginWhenCrossOrigin, .UnsafeUrl:
        break
    @unknown default:
        break
    }
    return .Origin
}

/// Whether the referrer is hidden by the default policy: always when it is neither `https` nor `http`, never when it is
/// `http`, and when it is `https` unless the URL is too.
private func securityPolicyShouldHideReferrer(_ referrerIsHTTPS: Bool, _ referrerIsHTTP: Bool, _ urlIsHTTPS: Bool) -> Bool {
    let referrerIsWebURL = referrerIsHTTPS || referrerIsHTTP
    if !referrerIsWebURL {
        return true
    }
    if !referrerIsHTTPS {
        return false
    }
    return !urlIsHTTPS
}
