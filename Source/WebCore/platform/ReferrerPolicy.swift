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
internal import WebCore_Private.Core.ReferrerPolicy
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch

/// `parseReferrerPolicy()`: the policy a `Referrer-Policy` header, a `<meta>` tag, an attribute or a speculation rule
/// gives.
///
/// `isNull` is whether `policyString` is the null view, which no token matches; an empty one is `EmptyString`. The result
/// holds the policy's raw value.
///
/// `policyString` is the characters of the caller's `StringView`, whose `String` or buffer the caller keeps allocated
/// and unchanged, at their length, for the call. Nothing this function calls writes them, and every Latin-1 or UTF-16
/// code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseReferrerPolicy8(
    _ policyString: WebCore.HTTPHeaderLatin1Span,
    _ isNull: Bool,
    _ source: WebCore.ReferrerPolicySource
) -> WebCore.HTTPHeaderOptionalUInt64 {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(policyString))
    return parseReferrerPolicyBody(characters, isNull, source)
}

/// parseReferrerPolicy8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseReferrerPolicy16(
    _ policyString: WebCore.HTTPHeaderUTF16Span,
    _ isNull: Bool,
    _ source: WebCore.ReferrerPolicySource
) -> WebCore.HTTPHeaderOptionalUInt64 {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: policyString)
    return parseReferrerPolicyBody(characters, isNull, source)
}

// An empty value matches no keyword. A header's is a list with no entries and gives no policy; any other source's gives
// EmptyString unless the value is null.
@inline(always)
private func parseReferrerPolicyBody<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ isNull: Bool,
    _ source: WebCore.ReferrerPolicySource
) -> WebCore.HTTPHeaderOptionalUInt64 {
    guard characters.isEmpty else {
        return parseNonEmptyReferrerPolicy(characters, isNull, source)
    }
    let parsesOneToken: Bool
    switch source {
    case .MetaTag, .ReferrerPolicyAttribute, .SpeculationRules:
        parsesOneToken = true
    case .HTTPHeader:
        parsesOneToken = false
    @unknown default:
        parsesOneToken = false
    }
    return WebCore.HTTPHeaderOptionalUInt64(
        value: UInt64(WebCore.ReferrerPolicy.EmptyString.rawValue),
        hasValue: parsesOneToken && !isNull
    )
}

@inline(never)
private func parseNonEmptyReferrerPolicy<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ isNull: Bool,
    _ source: WebCore.ReferrerPolicySource
) -> WebCore.HTTPHeaderOptionalUInt64 {
    guard let policy = ReferrerPolicyParsing.parseReferrerPolicy(characters, isNull: isNull, source: source) else {
        return WebCore.HTTPHeaderOptionalUInt64(value: 0, hasValue: false)
    }
    return WebCore.HTTPHeaderOptionalUInt64(value: UInt64(policy.rawValue), hasValue: true)
}

/// `parseReferrerPolicy`: https://w3c.github.io/webappsec-referrer-policy/#parse-referrer-policy-from-header.
enum ReferrerPolicyParsing {
    private typealias Units = HTTPHeaderCodeUnits

    typealias ReferrerPolicy = WebCore.ReferrerPolicy

    typealias ReferrerPolicySource = WebCore.ReferrerPolicySource

    /// `parseReferrerPolicy`. `isNull` is whether the argument is the null `StringView`, which no token matches,
    /// where an empty one is `EmptyString`. A header's value is a comma-separated list whose last recognized token wins;
    /// a `<meta>` element's also takes the legacy keywords `never`, `always` and `default`.
    static func parseReferrerPolicy<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ policyString: Span<CodeUnit>,
        isNull: Bool,
        source: ReferrerPolicySource
    ) -> ReferrerPolicy? {
        switch source {
        case .HTTPHeader:
            var result: ReferrerPolicy?
            // `StringView::split(',')`, which skips empty entries.
            var position = 0
            while position < policyString.count {
                let separator = Units.find(0x2C, in: policyString, from: position)
                if separator > position {
                    let token = policyString.extracting(Units.trim(policyString, position..<separator, Units.isASCIIWhitespaceWithoutFF))
                    if let policy = parseReferrerPolicyToken(token, isNull: false, parsesLegacyKeywords: false), policy != .EmptyString {
                        result = policy
                    }
                }
                if separator >= policyString.count {
                    break
                }
                position = separator + 1
            }
            return result
        case .MetaTag:
            return parseReferrerPolicyToken(policyString, isNull: isNull, parsesLegacyKeywords: true)
        case .ReferrerPolicyAttribute, .SpeculationRules:
            return parseReferrerPolicyToken(policyString, isNull: isNull, parsesLegacyKeywords: false)
        @unknown default:
            return nil
        }
    }

    private static func parseReferrerPolicyToken<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ policy: Span<CodeUnit>,
        isNull: Bool,
        parsesLegacyKeywords: Bool
    ) -> ReferrerPolicy? {
        // "never", "default" and "always" are legacy keywords that the HTML specification still defines:
        // https://html.spec.whatwg.org/#meta-referrer
        if parsesLegacyKeywords {
            if Units.equalLettersIgnoringASCIICase(policy, Literal.legacyNever.span) {
                return .NoReferrer
            }
            if Units.equalLettersIgnoringASCIICase(policy, Literal.legacyAlways.span) {
                return .UnsafeUrl
            }
            if Units.equalLettersIgnoringASCIICase(policy, Literal.legacyDefault.span) {
                return .Default
            }
        }

        if Units.equalLettersIgnoringASCIICase(policy, Literal.noReferrer.span) {
            return .NoReferrer
        }
        if Units.equalLettersIgnoringASCIICase(policy, Literal.unsafeUrl.span) {
            return .UnsafeUrl
        }
        if Units.equalLettersIgnoringASCIICase(policy, Literal.origin.span) {
            return .Origin
        }
        if Units.equalLettersIgnoringASCIICase(policy, Literal.originWhenCrossOrigin.span) {
            return .OriginWhenCrossOrigin
        }
        if Units.equalLettersIgnoringASCIICase(policy, Literal.sameOrigin.span) {
            return .SameOrigin
        }
        if Units.equalLettersIgnoringASCIICase(policy, Literal.strictOrigin.span) {
            return .StrictOrigin
        }
        if Units.equalLettersIgnoringASCIICase(policy, Literal.strictOriginWhenCrossOrigin.span) {
            return .StrictOriginWhenCrossOrigin
        }
        if Units.equalLettersIgnoringASCIICase(policy, Literal.noReferrerWhenDowngrade.span) {
            return .NoReferrerWhenDowngrade
        }
        if !isNull && policy.isEmpty {
            return .EmptyString
        }
        return nil
    }

    private enum Literal {
        /// "never"
        static let legacyNever: [UInt8] = [0x6E, 0x65, 0x76, 0x65, 0x72]
        /// "always"
        static let legacyAlways: [UInt8] = [0x61, 0x6C, 0x77, 0x61, 0x79, 0x73]
        /// "default"
        static let legacyDefault: [UInt8] = [0x64, 0x65, 0x66, 0x61, 0x75, 0x6C, 0x74]
        /// "no-referrer"
        static let noReferrer: [UInt8] = [0x6E, 0x6F, 0x2D, 0x72, 0x65, 0x66, 0x65, 0x72, 0x72, 0x65, 0x72]
        /// "unsafe-url"
        static let unsafeUrl: [UInt8] = [0x75, 0x6E, 0x73, 0x61, 0x66, 0x65, 0x2D, 0x75, 0x72, 0x6C]
        /// "origin"
        static let origin: [UInt8] = [0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E]
        /// "origin-when-cross-origin"
        static let originWhenCrossOrigin: [UInt8] = [
            0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E, 0x2D, 0x77, 0x68, 0x65, 0x6E, 0x2D, 0x63, 0x72, 0x6F, 0x73, 0x73, 0x2D, 0x6F, 0x72, 0x69,
            0x67, 0x69, 0x6E,
        ]
        /// "same-origin"
        static let sameOrigin: [UInt8] = [0x73, 0x61, 0x6D, 0x65, 0x2D, 0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E]
        /// "strict-origin"
        static let strictOrigin: [UInt8] = [0x73, 0x74, 0x72, 0x69, 0x63, 0x74, 0x2D, 0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E]
        /// "strict-origin-when-cross-origin"
        static let strictOriginWhenCrossOrigin: [UInt8] = [
            0x73, 0x74, 0x72, 0x69, 0x63, 0x74, 0x2D, 0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E, 0x2D, 0x77, 0x68, 0x65, 0x6E, 0x2D, 0x63, 0x72,
            0x6F, 0x73, 0x73, 0x2D, 0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E,
        ]
        /// "no-referrer-when-downgrade"
        static let noReferrerWhenDowngrade: [UInt8] = [
            0x6E, 0x6F, 0x2D, 0x72, 0x65, 0x66, 0x65, 0x72, 0x72, 0x65, 0x72, 0x2D, 0x77, 0x68, 0x65, 0x6E, 0x2D, 0x64, 0x6F, 0x77, 0x6E,
            0x67, 0x72, 0x61, 0x64, 0x65,
        ]
    }
}
