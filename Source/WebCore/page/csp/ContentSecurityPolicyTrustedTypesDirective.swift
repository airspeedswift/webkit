// Copyright (C) 2024 Igalia S.L. All rights reserved.
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

// The JavaScriptCore_Private and Stopwatch imports define types that WebCore_Private's headers name, which the importer needs.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

// AllowTrustedTypePolicy's values, which ContentSecurityPolicy.cpp checks.
let allowTrustedTypePolicyAllowed: UInt8 = 0
let allowTrustedTypePolicyDisallowedName: UInt8 = 1
let allowTrustedTypePolicyDisallowedDuplicateName: UInt8 = 2

private let allowDuplicatesKeyword: [UInt8] = Array("'allow-duplicates'".utf8)
private let trustedTypesNoneKeyword: [UInt8] = Array("'none'".utf8)
private let defaultPolicyName: [UInt8] = Array("default".utf8)

@inline(always)
private func isPolicyNameCharacter(_ c: UInt16) -> Bool {
    cspIsASCIIAlphanumeric(c) || c == 0x2D || c == 0x23 || c == 0x3D || c == 0x5F || c == 0x2F || c == 0x40 || c == 0x2E || c == 0x25
}

private func isTrustedTypesNone<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) -> Bool {
    var position = 0
    while position < characters.count && cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
        position += 1
    }
    if !cspStartsWithLettersIgnoringASCIICase(characters.extracting(position..<characters.count), trustedTypesNoneKeyword.span) {
        return false
    }
    position += trustedTypesNoneKeyword.count
    while position < characters.count && cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
        position += 1
    }
    return position == characters.count
}

private func containsOnlyPolicyNameCharacters<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) -> Bool {
    for index in 0..<characters.count where !isPolicyNameCharacter(characters[index].cspCodeUnit) {
        return false
    }
    return true
}

// trusted-types: the policy names TrustedTypePolicyFactory.createPolicy() may use, whose set is in its policy's store.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct ContentSecurityPolicyTrustedTypesDirective {
    private struct ParsedValue {
        var allowDuplicates = false
        var allowAny = false
        // Policy names are ASCII (isPolicyNameCharacter).
        var list = ContentSecurityPolicyNameSet()
    }

    private let m_allowDuplicates: Bool
    private let m_allowAny: Bool
    // The index of the names' set in the store's nameSets.
    private let m_list: Int

    init<C: ContentSecurityPolicyCharacter>(
        _ policy: ContentSecurityPolicyDirectiveListVector,
        _ value: Span<C>,
        _ store: inout ContentSecurityPolicySourceStore
    ) {
        let parsedValue = ContentSecurityPolicyTrustedTypesDirective.parseValue(policy, value)
        m_allowDuplicates = parsedValue.allowDuplicates
        m_allowAny = parsedValue.allowAny
        m_list = store.nameSets.count
        store.nameSets.append(parsedValue.list)
    }

    // `details` is left as it is when the name is allowed.
    func allows<C: ContentSecurityPolicyCharacter>(
        _ value: Span<C>,
        _ isDuplicate: Bool,
        _ details: inout UInt8,
        _ store: ContentSecurityPolicySourceStore
    ) -> Bool {
        let hasInvalidCharacter = !containsOnlyPolicyNameCharacters(value)
        if isDuplicate && !m_allowDuplicates {
            details = allowTrustedTypePolicyDisallowedDuplicateName
        } else if isDuplicate && cspEqualCodeUnits(value, defaultPolicyName.span) {
            details = allowTrustedTypePolicyDisallowedDuplicateName
        } else if hasInvalidCharacter {
            details = allowTrustedTypePolicyDisallowedName
        } else if !m_allowAny && !store.nameSets.span[m_list].contains(value) {
            details = allowTrustedTypePolicyDisallowedName
        }
        return details == allowTrustedTypePolicyAllowed
    }

    private static func parseValue<C: ContentSecurityPolicyCharacter>(
        _ contentSecurityPolicy: ContentSecurityPolicyDirectiveListVector,
        _ value: Span<C>
    ) -> ParsedValue {
        // 'trusted-types;'
        if value.isEmpty {
            return ParsedValue()
        }

        return parse(contentSecurityPolicy, value)
    }

    private static func parse<C: ContentSecurityPolicyCharacter>(
        _ contentSecurityPolicy: ContentSecurityPolicyDirectiveListVector,
        _ characters: Span<C>
    ) -> ParsedValue {
        var parsedValue = ParsedValue()
        if isTrustedTypesNone(characters) {
            return parsedValue
        }

        let end = characters.count
        var position = 0
        while position < end {
            while position < end && cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
                position += 1
            }
            if position == end {
                return parsedValue
            }

            let beginPolicy = position
            while position < end && !cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
                position += 1
            }
            let policy = characters.extracting(beginPolicy..<position)

            // Each tt-expression must match a keyword, the wildcard, or a
            // tt-policy-name in its entirety; a token with trailing characters
            // (e.g. "*X" or "'allow-duplicates'X") is an invalid expression.
            if cspEqualLettersIgnoringASCIICase(policy, allowDuplicatesKeyword.span) {
                parsedValue.allowDuplicates = true
                continue
            }
            if cspEqualLettersIgnoringASCIICase(policy, trustedTypesNoneKeyword.span) {
                contentSecurityPolicy.reportInvalidTrustedTypesNoneKeyword()
                continue
            }
            if policy.count == 1 && policy[0].cspCodeUnit == 0x2A {
                parsedValue.allowAny = true
                continue
            }
            guard !policy.isEmpty && containsOnlyPolicyNameCharacters(policy) else {
                contentSecurityPolicy.reportInvalidTrustedTypesPolicy(C.cspMakeString(policy))
                return parsedValue
            }
            parsedValue.list.add(policy)
        }
        return parsedValue
    }
}
