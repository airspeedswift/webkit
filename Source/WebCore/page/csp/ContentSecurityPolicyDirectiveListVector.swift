// Copyright (C) 2011 Google, Inc. All rights reserved.
// Copyright (C) 2013-2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY GOOGLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// The JavaScriptCore_Private and Stopwatch imports define types that WebCore_Private's headers name, which the importer needs.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.ContentSecurityPolicySwift
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

// A URL as the policies match it: URL::string() and the offsets of its parts, and the policy's own origin.
struct ContentSecurityPolicyURL {
    let string: WTF.String
    let bounds: WebCore.ContentSecurityPolicyURLBounds
    let selfOrigin: ContentSecurityPolicySelfOrigin
    // The document's setting, read for each check.
    let allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool

    init(
        _ string: consuming WTF.String,
        _ bounds: WebCore.ContentSecurityPolicyURLBounds,
        _ selfOrigin: ContentSecurityPolicySelfOrigin,
        _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    ) {
        self.string = string
        self.bounds = bounds
        self.selfOrigin = selfOrigin
        self.allowContentSecurityPolicySourceStarToMatchAnyProtocol = allowContentSecurityPolicySourceStarToMatchAnyProtocol
    }

    var is8Bit: Bool { bounds.is8Bit }
    var isEmpty: Bool { bounds.length == 0 }
    var isValid: Bool { bounds.isValid }
    var length: Int { Int(bounds.length) }
    var protocolIsInHTTPFamily: Bool { bounds.protocolIsInHTTPFamily }
    var port: UInt16? { bounds.hasPort ? bounds.port : nil }

    var protocolRange: Range<Int> { 0..<Int(bounds.protocolEnd) }
    var hostRange: Range<Int> { Int(bounds.hostStart)..<Int(bounds.hostEnd) }
    var pathRange: Range<Int> { Int(bounds.pathStart)..<Int(bounds.pathEnd) }

    // URL::protocolIs("about"): the scheme, which a valid URL keeps in lowercase, equals it.
    var protocolIsAbout: Bool {
        if is8Bit {
            return ContentSecurityPolicySchemeName(string.span8().extracting(protocolRange)) == .about
        }
        return ContentSecurityPolicySchemeName(string.checkedSpan16().extracting(protocolRange)) == .about
    }
}

// The code unit at `index` of either width.
func contentSecurityPolicyCodeUnit(_ string: borrowing WTF.String, _ index: Int) -> UInt16 {
    if string.is8Bit() {
        let characters: Span<WTF.Latin1Character> = string.span8()
        return characters[index].cspCodeUnit
    }
    let characters: Span<UInt16> = string.checkedSpan16()
    return characters[index]
}

// Builds the text of a console message or a report from its parts, copying each part whole: 8-bit while every
// character fits, 16-bit from the first part with one that does not. Literals are ASCII. Text of up to
// inlineCapacity bytes is built on the stack, longer text in one array of its length.
struct ContentSecurityPolicyStringBuilder: ~Copyable {
    // The count of inlineBytes.
    static var inlineCapacity: Int { 256 }

    private var inlineBytes = InlineArray<256, UInt8>(repeating: 0)
    // The text's bytes when it is longer than inlineCapacity.
    private var bytes: [UInt8] = []
    // The text's characters once it is 16-bit.
    private var utf16: [UInt16] = []
    private var length = 0
    private var is8Bit = true
    private let capacity: Int

    // `capacity` is the text's length: the sum of its parts' lengths.
    init(capacity: Int) {
        self.capacity = capacity
        if capacity > ContentSecurityPolicyStringBuilder.inlineCapacity {
            bytes = Array(repeating: 0, count: capacity)
        }
    }

    mutating func append(_ literal: Swift.String) {
        append(literal.utf8.span)
    }

    mutating func append(_ bytes: [UInt8]) {
        append(bytes.span)
    }

    // ASCII bytes.
    mutating func append(_ bytes: Span<UInt8>) {
        if is8Bit {
            appendLowBytes(bytes)
            return
        }
        appendCodeUnits(bytes)
    }

    mutating func append(_ string: borrowing WTF.String) {
        if string.is8Bit() {
            append(string.span8())
        } else {
            append(string.checkedSpan16())
        }
    }

    mutating func append(_ characters: Span<WTF.Latin1Character>) {
        if is8Bit {
            appendLowBytes(characters)
            return
        }
        appendCodeUnits(characters)
    }

    mutating func append<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) {
        if is8Bit {
            if contentSecurityPolicyFitsInLatin1(characters) {
                appendLowBytes(characters)
                return
            }
            widen()
        }
        appendCodeUnits(characters)
    }

    // The low byte of each character, for text the parser has already limited to ASCII.
    mutating func appendASCII(_ string: borrowing WTF.String) {
        if string.is8Bit() {
            appendASCII(string.span8())
        } else {
            appendASCII(string.checkedSpan16())
        }
    }

    mutating func appendASCII<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) {
        if is8Bit {
            appendLowBytes(characters)
            return
        }
        let end = reserveCodeUnits(characters.count)
        var output = utf16.mutableSpan
        for index in 0..<characters.count {
            // Below the end reserveCodeUnits made room for.
            output[length &+ index] = UInt16(UInt8(truncatingIfNeeded: characters[index].cspCodeUnit))
        }
        length = end
    }

    private mutating func appendLowBytes<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) {
        let end = length + characters.count
        if bytes.isEmpty && end <= ContentSecurityPolicyStringBuilder.inlineCapacity {
            var output = inlineBytes.mutableSpan
            contentSecurityPolicyCopyLowBytes(characters, &output, length)
        } else {
            if bytes.count < end {
                growBytes(end)
            }
            var output = bytes.mutableSpan
            contentSecurityPolicyCopyLowBytes(characters, &output, length)
        }
        length = end
    }

    private mutating func appendCodeUnits<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) {
        let end = reserveCodeUnits(characters.count)
        var output = utf16.mutableSpan
        for index in 0..<characters.count {
            // Below the end reserveCodeUnits made room for.
            output[length &+ index] = characters[index].cspCodeUnit
        }
        length = end
    }

    // Room in `utf16` for `count` more characters; returns the text's end after them.
    private mutating func reserveCodeUnits(_ count: Int) -> Int {
        let end = length + count
        if utf16.count < end {
            utf16.append(contentsOf: repeatElement(0, count: end - utf16.count))
        }
        return end
    }

    // A text longer than its capacity moves to, or grows, `bytes`.
    @inline(never)
    private mutating func growBytes(_ end: Int) {
        if bytes.isEmpty {
            bytes = Array(repeating: 0, count: Swift.max(end, capacity))
            let text = inlineBytes.span
            var output = bytes.mutableSpan
            contentSecurityPolicyCopyLowBytes(text.extracting(0..<length), &output, 0)
            return
        }
        bytes.append(contentsOf: repeatElement(0, count: end - bytes.count))
    }

    // The text so far, widened, in a 16-bit buffer of the text's capacity.
    @inline(never)
    private mutating func widen() {
        utf16 = Array(repeating: 0, count: Swift.max(capacity, length))
        var output = utf16.mutableSpan
        if bytes.isEmpty {
            let text = inlineBytes.span
            for index in 0..<length {
                output[index] = UInt16(text[index])
            }
        } else {
            let text = bytes.span
            for index in 0..<length {
                output[index] = UInt16(text[index])
            }
        }
        is8Bit = false
    }

    func toString() -> WTF.String {
        if !is8Bit {
            return UInt16.cspMakeString(utf16.span.extracting(0..<length))
        }
        if bytes.isEmpty {
            return makeContentSecurityPolicyString(inlineBytes.span.extracting(0..<length))
        }
        return makeContentSecurityPolicyString(bytes.span.extracting(0..<length))
    }
}

// Whether every character is at most 0xFF.
private func contentSecurityPolicyFitsInLatin1<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) -> Bool {
    var bits: UInt16 = 0
    for index in 0..<characters.count {
        bits |= characters[index].cspCodeUnit
    }
    return bits <= 0xFF
}

// Writes the low byte of each character to `output` from `offset`, which the caller has checked `output` holds.
// For bytes and Latin-1 characters this is one copy.
@inline(always)
private func contentSecurityPolicyCopyLowBytes<C: ContentSecurityPolicyCharacter>(
    _ characters: Span<C>,
    _ output: inout MutableSpan<UInt8>,
    _ offset: Int
) {
    for index in 0..<characters.count {
        // Below the end the caller checked.
        output[offset &+ index] = UInt8(truncatingIfNeeded: characters[index].cspCodeUnit)
    }
}

// The name a console message gives a directive: script-src for script-src-elem and script-src-attr, and style-src
// for style-src-elem and style-src-attr.
private func contentSecurityPolicyConsoleName(_ name: ContentSecurityPolicyDirectiveNames) -> [UInt8] {
    switch name {
    case .scriptSrc, .scriptSrcAttr, .scriptSrcElem:
        return ContentSecurityPolicyDirectiveNames.scriptSrc.spelling
    case .styleSrc, .styleSrcAttr, .styleSrcElem:
        return ContentSecurityPolicyDirectiveNames.styleSrc.spelling
    default:
        return name.spelling
    }
}

// What a console message names as missing from the violated directive, with the words around it, from " because " to
// the directive's name.
private enum ContentSecurityPolicyViolationSubject {
    case it
    case hashOrUnsafeInline
    case unsafeInline
    case hashNonceOrUnsafeInline
    case unsafeEval

    func text(_ isDefaultSrc: Bool) -> Swift.String {
        switch self {
        case .it:
            isDefaultSrc ? " because it appears in neither the " : " because it does not appear in the "
        case .hashOrUnsafeInline:
            isDefaultSrc
                ? " because its hash or 'unsafe-inline' appears in neither the "
                : " because its hash or 'unsafe-inline' does not appear in the "
        case .unsafeInline:
            isDefaultSrc ? " because 'unsafe-inline' appears in neither the " : " because 'unsafe-inline' does not appear in the "
        case .hashNonceOrUnsafeInline:
            isDefaultSrc
                ? " because its hash, its nonce, or 'unsafe-inline' appears in neither the "
                : " because its hash, its nonce, or 'unsafe-inline' does not appear in the "
        case .unsafeEval:
            isDefaultSrc
                ? " because 'unsafe-eval' and 'trusted-types-eval' appears in neither the "
                : " because 'unsafe-eval' and 'trusted-types-eval' does not appear in the "
        }
    }
}

// Whether `string` starts with the ASCII literal `prefix`.
func contentSecurityPolicyStartsWith(_ string: borrowing WTF.String, _ prefix: Swift.String) -> Bool {
    if string.is8Bit() {
        return contentSecurityPolicyStartsWith(string.span8(), prefix)
    }
    return contentSecurityPolicyStartsWith(string.checkedSpan16(), prefix)
}

func contentSecurityPolicyStartsWith<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>, _ prefix: Swift.String) -> Bool {
    var index = 0
    for byte in prefix.utf8 {
        if index == characters.count {
            return false
        }
        if characters[index].cspCodeUnit != UInt16(byte) {
            return false
        }
        index += 1
    }
    return true
}

// Whether `string` is the ASCII literal `literal`.
func contentSecurityPolicyEquals(_ string: borrowing WTF.String, _ literal: Swift.String) -> Bool {
    if string.is8Bit() {
        return contentSecurityPolicyEquals(string.span8(), literal)
    }
    return contentSecurityPolicyEquals(string.checkedSpan16(), literal)
}

func contentSecurityPolicyEquals<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>, _ literal: Swift.String) -> Bool {
    if characters.count != literal.utf8.count {
        return false
    }
    return contentSecurityPolicyStartsWith(characters, literal)
}

private func isASCIIWhitespaceCodeUnit(_ character: UInt16) -> Bool {
    character == 0x20 || character == 0x0A || character == 0x09 || character == 0x0D || character == 0x0C
}

// The URLs of a frame-ancestors check's ancestors, nearest first, each made from its origin (urlFromOrigin) by
// ContentSecurityPolicy the first time a policy reads it.
struct ContentSecurityPolicyFrameAncestors {
    private let selfOrigin: ContentSecurityPolicySelfOrigin
    private let allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    private var urls: [ContentSecurityPolicyURL] = []
    private var hasAll = false

    init(_ selfOrigin: ContentSecurityPolicySelfOrigin, _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool) {
        self.selfOrigin = selfOrigin
        self.allowContentSecurityPolicySourceStarToMatchAnyProtocol = allowContentSecurityPolicySourceStarToMatchAnyProtocol
    }

    // Whether every ancestor's URL is valid and allowed by `policy`'s `directive`, stopping at the first that is not.
    mutating func areAllowed(_ policy: ContentSecurityPolicyDirectiveList, _ directive: Int) -> Bool {
        let didReceiveRedirectResponse = false
        var index = 0
        while true {
            if index == urls.count {
                if hasAll {
                    return true
                }
                var url = WTF.String()
                var bounds = WebCore.ContentSecurityPolicyURLBounds()
                // An ancestor's index is below its frame's depth.
                if !WebCore.ContentSecurityPolicyCallbacks.frameAncestorURL(UInt32(truncatingIfNeeded: index), &url, &bounds) {
                    hasAll = true
                    return true
                }
                urls.append(ContentSecurityPolicyURL(url, bounds, selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol))
            }
            if !urls[index].isValid || !policy.sourceAllows(directive, urls[index], didReceiveRedirectResponse) {
                return false
            }
            index += 1
        }
    }
}

// The policies of one ContentSecurityPolicy, in the order their headers were received, with its self source.
// ContentSecurityPolicy owns one and calls it from its members; the policies call back into it while parsing.
@_expose(Cxx)
final class ContentSecurityPolicyDirectiveListVector {
    private var policies: [ContentSecurityPolicyDirectiveList] = []
    private var selfOrigin = ContentSecurityPolicySelfOrigin()
    private var modeForExtension = contentSecurityPolicyModeForExtensionNone
    private var scriptHashAlgorithms: UInt8 = 0
    private var styleHashAlgorithms: UInt8 = 0
    // The sandbox flags of the policies of the header didReceiveHeader() was last called with.
    private var headerSandboxFlags: UInt16 = 0
    // Indexed by ContentSecurityPolicyDirectiveNames; empty until the first violation.
    private var nameStrings: [WTF.String] = []
    // A bit per name whose String nameStrings holds (there are fewer than 64 names).
    private var nameStringsMade: UInt64 = 0

    @_expose(Cxx)
    init() {
    }

    // MARK: - Policies

    @_expose(Cxx)
    func isEmpty() -> Bool {
        policies.isEmpty
    }

    @_expose(Cxx)
    func policyCount() -> UInt32 {
        UInt32(policies.count)
    }

    @_expose(Cxx)
    func policyHeader(_ index: UInt32) -> WTF.String {
        policies[Int(index)].header()
    }

    @_expose(Cxx)
    func policyHeaderType(_ index: UInt32) -> UInt8 {
        policies[Int(index)].headerType()
    }

    // A HashAlgorithmSet.
    @_expose(Cxx)
    func policyReportHash(_ index: UInt32) -> UInt8 {
        policies[Int(index)].reportHash()
    }

    @_expose(Cxx)
    func policyReportToTokenCount(_ index: UInt32) -> UInt32 {
        UInt32(policies[Int(index)].m_reportToTokens.count)
    }

    @_expose(Cxx)
    func policyReportToToken(_ index: UInt32, _ tokenIndex: UInt32) -> WTF.String {
        policies[Int(index)].m_reportToTokens[Int(tokenIndex)]
    }

    // RFC2616, section 4.2 specifies that headers appearing multiple times can be combined with a comma. Walk the
    // header string, and parse each comma separated chunk as a separate header.
    // Returns the number of these policies that upgrade insecure requests.
    @_expose(Cxx)
    func didReceiveHeader(_ header: consuming WTF.String, _ type: UInt8, _ policyFrom: UInt8, _ modeForExtension: UInt8) -> UInt32 {
        self.modeForExtension = modeForExtension
        headerSandboxFlags = 0
        if header.is8Bit() {
            return addPolicies(header.span8(), type, policyFrom)
        }
        return addPolicies(header.checkedSpan16(), type, policyFrom)
    }

    private func addPolicies<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>, _ type: UInt8, _ policyFrom: UInt8) -> UInt32 {
        var upgrades = 0
        let length = characters.count
        var position = 0
        while position < length {
            if !isASCIIWhitespaceCodeUnit(characters[position].cspCodeUnit) {
                break
            }
            position += 1
        }
        var begin = position
        while position < length {
            while position < length {
                if characters[position].cspCodeUnit == 0x2C {
                    break
                }
                position += 1
            }
            let policy = ContentSecurityPolicyDirectiveList.create(
                self,
                C.cspMakeSubstring(characters.extracting(begin..<position)),
                type,
                policyFrom
            )
            if policy.upgradeInsecureRequests() {
                upgrades += 1
            }
            policies.append(policy)
            if position < length {
                position += 1
            }
            begin = position
        }
        // A header has fewer than 2^32 policies.
        return UInt32(truncatingIfNeeded: upgrades)
    }

    @_expose(Cxx)
    func hashAlgorithmsForInlineScripts() -> UInt8 {
        scriptHashAlgorithms
    }

    @_expose(Cxx)
    func hashAlgorithmsForInlineStylesheets() -> UInt8 {
        styleHashAlgorithms
    }

    // The SandboxFlags of the sandbox directives of the header didReceiveHeader() was last called with.
    @_expose(Cxx)
    func sandboxFlags() -> UInt16 {
        headerSandboxFlags
    }

    @_expose(Cxx)
    func updateSourceSelf(_ scheme: consuming WTF.String, _ host: consuming WTF.String, _ port: UInt16, _ hasPort: Bool) {
        selfOrigin = ContentSecurityPolicySelfOrigin(scheme, host, hasPort ? port : nil)
    }

    // MARK: - Applying the policies

    // The index of the last enforced policy that disallows eval, or -1.
    @_expose(Cxx)
    func lastEnforcedPolicyDisallowingEval() -> Int32 {
        var result: Int32 = -1
        for (index, policy) in policies.enumerated() where policy.violatedDirectiveForUnsafeEval() != nil && !policy.isReportOnly() {
            result = Int32(index)
        }
        return result
    }

    @_expose(Cxx)
    func evalDisabledErrorMessage(_ index: UInt32) -> WTF.String {
        policies[Int(index)].evalDisabledErrorMessage()
    }

    @_expose(Cxx)
    func webAssemblyDisabledErrorMessage(_ index: UInt32) -> WTF.String {
        policies[Int(index)].webAssemblyDisabledErrorMessage()
    }

    @_expose(Cxx)
    func requiresTrustedTypesForScript() -> Bool {
        policies.contains { $0.requiresTrustedTypesForScript() }
    }

    // Whether the last policy that requires Trusted Types for scripts is enforced.
    @_expose(Cxx)
    func lastPolicyRequiringTrustedTypesForScriptIsEnforced() -> Bool {
        policies.last { $0.requiresTrustedTypesForScript() }.map { !$0.isReportOnly() } ?? false
    }

    @_expose(Cxx)
    func trustedEvalEnabled() -> Bool {
        policies.allSatisfy { $0.trustedEvalEnabled() }
    }

    @_expose(Cxx)
    func overridesXFrameOptions() -> Bool {
        // If a resource is delivered with a policy that includes a directive named frame-ancestors and whose disposition
        // is "enforce", then the X-Frame-Options header MUST be ignored.
        // https://www.w3.org/TR/CSP3/#frame-ancestors-and-frame-options
        policies.contains { !$0.isReportOnly() && $0.hasFrameAncestorsDirective() }
    }

    @_expose(Cxx)
    func hasFrameAncestorsDirective() -> Bool {
        policies.contains { $0.hasFrameAncestorsDirective() }
    }

    @_expose(Cxx)
    func hasPluginTypesDirective() -> Bool {
        policies.contains { $0.hasPluginTypesDirective() }
    }

    // MARK: - Checks

    // The checks read a copy of the list of policies, which a callback that adds a policy leaves unchanged.
    private func allPoliciesWithDispositionAllow(_ isReportOnly: Bool, _ predicate: (ContentSecurityPolicyDirectiveList) -> Int?) -> Bool {
        let list = self.policies
        let policies = list.span
        for index in policies.indices where policies[index].isReportOnly() == isReportOnly {
            if predicate(policies[index]) != nil {
                return false
            }
        }
        return true
    }

    private func allPoliciesAllow(
        _ callback: (ContentSecurityPolicyDirectiveList, Int) -> Void,
        _ predicate: (ContentSecurityPolicyDirectiveList) -> Int?
    ) -> Bool {
        var isAllowed = true
        let list = self.policies
        let policies = list.span
        for index in policies.indices {
            if let violatedDirective = predicate(policies[index]) {
                if !policies[index].isReportOnly() {
                    isAllowed = false
                }
                callback(policies[index], violatedDirective)
            }
        }
        return isAllowed
    }

    private func consoleMessageForViolation(
        _ policy: ContentSecurityPolicyDirectiveList,
        _ violatedDirective: Int,
        _ prefix: Swift.String,
        _ subject: ContentSecurityPolicyViolationSubject = .it
    ) -> WTF.String {
        let isDefaultSrc = policy.isDefaultSrc(violatedDirective)
        let name = contentSecurityPolicyConsoleName(policy.nameForReporting(violatedDirective))
        let blockedURL = WebCore.ContentSecurityPolicyCallbacks.blockedURLForConsole()
        let blockedURLLength = Int(blockedURL.length())
        let isReportOnly = policy.isReportOnly()
        let reportOnly = "[Report Only] "
        let because = subject.text(isDefaultSrc)
        let suffix =
            isDefaultSrc
            ? " directive nor the default-src directive of the Content Security Policy." : " directive of the Content Security Policy."
        var message = ContentSecurityPolicyStringBuilder(
            capacity: (isReportOnly ? reportOnly.utf8.count : 0) + prefix.utf8.count + (blockedURLLength == 0 ? 0 : 1 + blockedURLLength)
                + because.utf8.count + name.count + suffix.utf8.count
        )
        if isReportOnly {
            message.append(reportOnly)
        }
        message.append(prefix)
        if blockedURLLength != 0 {
            message.append(" ")
            message.append(blockedURL)
        }
        message.append(because)
        message.append(name)
        message.append(suffix)
        return message.toString()
    }

    // A directive text for the inspector is given to it after the violation is reported.
    private func reportViolation(
        _ violatedDirectiveName: ContentSecurityPolicyDirectiveNames,
        _ policy: ContentSecurityPolicyDirectiveList,
        _ consoleMessage: WTF.String,
        _ sample: WTF.String = WTF.String(),
        _ directiveTextForInspector: WTF.String = WTF.String()
    ) {
        let index = nameStringIndex(violatedDirectiveName)
        let names = nameStrings
        let shouldReportSample = policy.shouldReportSample(violatedDirectiveName)
        WebCore.ContentSecurityPolicyCallbacks.reportViolation(
            names.span[index],
            policy.m_header,
            policy.isReportOnly(),
            shouldReportSample,
            policy.m_reportToTokens.span,
            policy.m_reportURIs.span,
            consoleMessage,
            sample,
            directiveTextForInspector
        )
    }

    private func reportViolation(
        _ policy: ContentSecurityPolicyDirectiveList,
        _ violatedDirective: Int,
        _ consoleMessage: WTF.String,
        _ directiveTextForInspector: WTF.String = WTF.String()
    ) {
        reportViolation(policy.nameForReporting(violatedDirective), policy, consoleMessage, WTF.String(), directiveTextForInspector)
    }

    // The index in nameStrings of a directive name's String, made at the first violation reported under it.
    private func nameStringIndex(_ name: ContentSecurityPolicyDirectiveNames) -> Int {
        let index = Int(name.rawValue)
        let bit: UInt64 = 1 << UInt64(index)
        if nameStringsMade & bit == 0 {
            if nameStrings.isEmpty {
                nameStrings = Array(repeating: WTF.String(), count: contentSecurityPolicyDirectiveNameSpellings.count)
            }
            nameStrings[index] = name.string()
            nameStringsMade |= bit
        }
        return index
    }

    // An inline check that tells the inspector about its first violation in a policy of the given disposition.
    private func allowInline(
        _ prefix: Swift.String,
        _ subject: ContentSecurityPolicyViolationSubject,
        _ notifiesInspectorOfReportOnly: Bool,
        _ predicate: (ContentSecurityPolicyDirectiveList) -> Int?
    ) -> Bool {
        var didNotifyInspector = false
        return allPoliciesAllow(
            { policy, violatedDirective in
                let consoleMessage = consoleMessageForViolation(policy, violatedDirective, prefix, subject)
                let notifiesInspector = !didNotifyInspector && policy.isReportOnly() == notifiesInspectorOfReportOnly
                reportViolation(
                    policy,
                    violatedDirective,
                    consoleMessage,
                    notifiesInspector ? policy.directiveText(violatedDirective) : WTF.String()
                )
                didNotifyInspector = didNotifyInspector || notifiesInspector
            },
            predicate
        )
    }

    @_expose(Cxx)
    func allowJavaScriptURLs(_ hashes: WebCore.ContentSecurityPolicyContentHashes) -> Bool {
        allowInline("Refused to execute a script", .hashOrUnsafeInline, true) {
            $0.violatedDirectiveForInlineJavascriptURL(hashes)
        }
    }

    @_expose(Cxx)
    func allowInlineEventHandlers(_ hashes: WebCore.ContentSecurityPolicyContentHashes) -> Bool {
        allowInline("Refused to execute a script for an inline event handler", .unsafeInline, false) {
            $0.violatedDirectiveForInlineEventHandlers(hashes)
        }
    }

    // FIXME: We need to report violations in report-only policies. See <https://bugs.webkit.org/show_bug.cgi?id=159830>.
    @_expose(Cxx)
    func allowScriptWithNonce(_ nonce: consuming WTF.String) -> Bool {
        let nonce = consume nonce
        if nonce.isEmpty() {
            return false
        }
        return allPoliciesWithDispositionAllow(false) { $0.violatedDirectiveForScriptNonce(nonce) }
    }

    @_expose(Cxx)
    func allowStyleWithNonce(_ nonce: consuming WTF.String) -> Bool {
        let nonce = consume nonce
        if nonce.isEmpty() {
            return false
        }
        return allPoliciesWithDispositionAllow(false) { $0.violatedDirectiveForStyleNonce(nonce) }
    }

    // We perform checks early if strict-dynamic is included in the CSP policy because
    // we have access to necessary information about the script that we do not have later on.
    @_expose(Cxx)
    func shouldPerformEarlyCSPCheck() -> Bool {
        policies.contains { $0.strictDynamicIncluded() }
    }

    @_expose(Cxx)
    func allowScriptForStrictDynamic(
        _ sourceURL: consuming WTF.String,
        _ bounds: WebCore.ContentSecurityPolicyURLBounds,
        _ nonce: consuming WTF.String,
        _ parserInserted: Bool,
        _ hashes: WebCore.ContentSecurityPolicyContentHashes,
        _ integrity: consuming WTF.String,
        _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    ) -> Bool {
        let nonce = consume nonce
        let url = ContentSecurityPolicyURL(sourceURL, bounds, selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol)
        let prefix = url.isEmpty ? "Refused to execute a script" : "Refused to load"
        var digests = ContentSecurityPolicyIntegrityDigests(integrity)
        // swift-format-ignore: OnlyOneTrailingClosureArgument
        return allPoliciesAllow({ policy, violatedDirective in
            let consoleMessage = consoleMessageForViolation(policy, violatedDirective, prefix)
            reportViolation(policy, violatedDirective, consoleMessage)
        }) {
            $0.violatedDirectiveForScriptUnderStrictDynamic(nonce, hashes, &digests, url, parserInserted)
        }
    }

    @_expose(Cxx)
    func allowInlineScript(_ nonce: consuming WTF.String, _ hashes: WebCore.ContentSecurityPolicyContentHashes) -> Bool {
        let nonce = consume nonce
        return allowInline("Refused to execute a script", .hashNonceOrUnsafeInline, false) {
            $0.violatedDirectiveForUnsafeInlineScriptElement(nonce, hashes)
        }
    }

    @_expose(Cxx)
    func allowInlineStyle(
        _ nonce: consuming WTF.String,
        _ checkUnsafeHashes: Bool,
        _ hashes: WebCore.ContentSecurityPolicyContentHashes
    ) -> Bool {
        let nonce = consume nonce
        func handleViolatedDirective(_ policy: ContentSecurityPolicyDirectiveList, _ violatedDirective: Int) {
            let consoleMessage = consoleMessageForViolation(
                policy,
                violatedDirective,
                "Refused to apply a stylesheet",
                .hashNonceOrUnsafeInline
            )
            reportViolation(policy, violatedDirective, consoleMessage)
        }
        if checkUnsafeHashes {
            return allPoliciesAllow(handleViolatedDirective) { $0.violatedDirectiveForUnsafeInlineStyleAttribute(nonce, hashes) }
        }
        return allPoliciesAllow(handleViolatedDirective) { $0.violatedDirectiveForUnsafeInlineStyleElement(nonce, hashes) }
    }

    @_expose(Cxx)
    func allowEval(_ shouldLogToConsole: Bool) -> Bool {
        var didNotifyInspector = false
        // swift-format-ignore: OnlyOneTrailingClosureArgument
        return allPoliciesAllow({ policy, violatedDirective in
            let consoleMessage =
                shouldLogToConsole
                ? consoleMessageForViolation(policy, violatedDirective, "Refused to execute a script", .unsafeEval) : WTF.String()
            let notifiesInspector = !didNotifyInspector && !policy.isReportOnly()
            reportViolation(
                policy,
                violatedDirective,
                consoleMessage,
                notifiesInspector ? policy.directiveText(violatedDirective) : WTF.String()
            )
            didNotifyInspector = didNotifyInspector || notifiesInspector
        }) {
            $0.violatedDirectiveForUnsafeEval()
        }
    }

    // The ancestors come from the frame tree or the ancestor origins, which ContentSecurityPolicy keeps.
    @_expose(Cxx)
    func allowFrameAncestors(_ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool) -> Bool {
        var ancestors = ContentSecurityPolicyFrameAncestors(selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol)
        // swift-format-ignore: OnlyOneTrailingClosureArgument
        return allPoliciesAllow({ policy, violatedDirective in
            let consoleMessage = consoleMessageForViolation(policy, violatedDirective, "Refused to load")
            reportViolation(policy, violatedDirective, consoleMessage)
        }) {
            $0.violatedDirectiveForFrameAncestorOrigins(&ancestors)
        }
    }

    private func allowSource(_ prefix: Swift.String, _ predicate: (ContentSecurityPolicyDirectiveList) -> Int?) -> Bool {
        allPoliciesAllow(
            { policy, violatedDirective in
                let consoleMessage = consoleMessageForViolation(policy, violatedDirective, prefix)
                reportViolation(policy, violatedDirective, consoleMessage)
            },
            predicate
        )
    }

    @_expose(Cxx)
    func allowImageFromSource(
        _ url: consuming WTF.String,
        _ bounds: WebCore.ContentSecurityPolicyURLBounds,
        _ didReceiveRedirectResponse: Bool,
        _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    ) -> Bool {
        let url = ContentSecurityPolicyURL(url, bounds, selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol)
        return allowSource("Refused to load") {
            $0.violatedDirectiveForImage(url, didReceiveRedirectResponse)
        }
    }

    @_expose(Cxx)
    func allowPrefetchFromSource(
        _ url: consuming WTF.String,
        _ bounds: WebCore.ContentSecurityPolicyURLBounds,
        _ didReceiveRedirectResponse: Bool,
        _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    ) -> Bool {
        let url = ContentSecurityPolicyURL(url, bounds, selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol)
        return allowSource("Refused to load") {
            $0.violatedDirectiveForPrefetch(url, didReceiveRedirectResponse)
        }
    }

    @_expose(Cxx)
    func allowFontFromSource(
        _ url: consuming WTF.String,
        _ bounds: WebCore.ContentSecurityPolicyURLBounds,
        _ didReceiveRedirectResponse: Bool,
        _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    ) -> Bool {
        let url = ContentSecurityPolicyURL(url, bounds, selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol)
        return allowSource("Refused to load") {
            $0.violatedDirectiveForFont(url, didReceiveRedirectResponse)
        }
    }

    @_expose(Cxx)
    func allowManifestFromSource(
        _ url: consuming WTF.String,
        _ bounds: WebCore.ContentSecurityPolicyURLBounds,
        _ didReceiveRedirectResponse: Bool,
        _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    ) -> Bool {
        let url = ContentSecurityPolicyURL(url, bounds, selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol)
        return allowSource("Refused to load") {
            $0.violatedDirectiveForManifest(url, didReceiveRedirectResponse)
        }
    }

    @_expose(Cxx)
    func allowMediaFromSource(
        _ url: consuming WTF.String,
        _ bounds: WebCore.ContentSecurityPolicyURLBounds,
        _ didReceiveRedirectResponse: Bool,
        _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    ) -> Bool {
        let url = ContentSecurityPolicyURL(url, bounds, selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol)
        return allowSource("Refused to load") {
            $0.violatedDirectiveForMedia(url, didReceiveRedirectResponse)
        }
    }

    @_expose(Cxx)
    func allowFormAction(
        _ url: consuming WTF.String,
        _ bounds: WebCore.ContentSecurityPolicyURLBounds,
        _ didReceiveRedirectResponse: Bool,
        _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    ) -> Bool {
        let url = ContentSecurityPolicyURL(url, bounds, selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol)
        return allowSource("Refused to load") {
            $0.violatedDirectiveForFormAction(url, didReceiveRedirectResponse)
        }
    }

    @_expose(Cxx)
    func allowObjectFromSource(
        _ url: consuming WTF.String,
        _ bounds: WebCore.ContentSecurityPolicyURLBounds,
        _ didReceiveRedirectResponse: Bool,
        _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    ) -> Bool {
        let url = ContentSecurityPolicyURL(url, bounds, selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol)
        return allowSource("Refused to load") {
            $0.violatedDirectiveForObjectSource(url, didReceiveRedirectResponse)
        }
    }

    @_expose(Cxx)
    func allowChildFrameFromSource(
        _ url: consuming WTF.String,
        _ bounds: WebCore.ContentSecurityPolicyURLBounds,
        _ didReceiveRedirectResponse: Bool,
        _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    ) -> Bool {
        let url = ContentSecurityPolicyURL(url, bounds, selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol)
        return allowSource("Refused to load") {
            $0.violatedDirectiveForFrame(url, didReceiveRedirectResponse)
        }
    }

    @_expose(Cxx)
    func allowWorkerFromSource(
        _ url: consuming WTF.String,
        _ bounds: WebCore.ContentSecurityPolicyURLBounds,
        _ didReceiveRedirectResponse: Bool,
        _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    ) -> Bool {
        let url = ContentSecurityPolicyURL(url, bounds, selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol)
        return allowSource("Refused to load") {
            $0.violatedDirectiveForWorker(url, didReceiveRedirectResponse)
        }
    }

    @_expose(Cxx)
    func allowScriptFromSource(
        _ url: consuming WTF.String,
        _ bounds: WebCore.ContentSecurityPolicyURLBounds,
        _ didReceiveRedirectResponse: Bool,
        _ nonce: consuming WTF.String,
        _ integrity: consuming WTF.String,
        _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    ) -> Bool {
        let nonce = consume nonce
        let url = ContentSecurityPolicyURL(url, bounds, selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol)
        var digests = ContentSecurityPolicyIntegrityDigests(integrity)
        return allowSource("Refused to load") {
            $0.violatedDirectiveForScript(url, didReceiveRedirectResponse, &digests, nonce)
        }
    }

    @_expose(Cxx)
    func allowStyleFromSource(
        _ url: consuming WTF.String,
        _ bounds: WebCore.ContentSecurityPolicyURLBounds,
        _ didReceiveRedirectResponse: Bool,
        _ nonce: consuming WTF.String,
        _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    ) -> Bool {
        let nonce = consume nonce
        let url = ContentSecurityPolicyURL(url, bounds, selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol)
        return allowSource("Refused to load") {
            $0.violatedDirectiveForStyle(url, didReceiveRedirectResponse, nonce)
        }
    }

    @_expose(Cxx)
    func allowConnectToSource(
        _ url: consuming WTF.String,
        _ bounds: WebCore.ContentSecurityPolicyURLBounds,
        _ didReceiveRedirectResponse: Bool,
        _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    ) -> Bool {
        let url = ContentSecurityPolicyURL(url, bounds, selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol)
        return allowSource("Refused to connect to") {
            $0.violatedDirectiveForConnectSource(url, didReceiveRedirectResponse)
        }
    }

    @_expose(Cxx)
    func allowBaseURI(
        _ url: consuming WTF.String,
        _ bounds: WebCore.ContentSecurityPolicyURLBounds,
        _ allowContentSecurityPolicySourceStarToMatchAnyProtocol: Bool
    ) -> Bool {
        let url = ContentSecurityPolicyURL(url, bounds, selfOrigin, allowContentSecurityPolicySourceStarToMatchAnyProtocol)
        return allowSource("Refused to change the document base URL to") {
            $0.violatedDirectiveForBaseURI(url)
        }
    }

    // https://w3c.github.io/trusted-types/dist/spec/#should-block-create-policy
    @_expose(Cxx)
    func allowTrustedTypesPolicy(_ value: consuming WTF.String, _ isDuplicate: Bool) -> UInt8 {
        let value = consume value
        if value.is8Bit() {
            return allowTrustedTypesPolicy(value.span8(), isDuplicate)
        }
        return allowTrustedTypesPolicy(value.checkedSpan16(), isDuplicate)
    }

    private func allowTrustedTypesPolicy<C: ContentSecurityPolicyCharacter>(_ value: Span<C>, _ isDuplicate: Bool) -> UInt8 {
        var details = allowTrustedTypePolicyAllowed
        var isAllowed = true
        for policy in policies {
            var perPolicyDetails = allowTrustedTypePolicyAllowed
            if let violatedDirective = policy.violatedDirectiveForTrustedTypesPolicy(value, isDuplicate, &perPolicyDetails) {
                let isReportOnly = policy.isReportOnly()
                if !isReportOnly {
                    isAllowed = false
                }
                // If we already have a violation, we should use the details from the first policy that violated the directive.
                if !isAllowed && details == allowTrustedTypePolicyAllowed {
                    details = perPolicyDetails
                }
                let reportOnly = "[Report Only] "
                let refused = "Refused to create a TrustedTypePolicy named '"
                let because = "' because it violates the following Content Security Policy directive: \""
                var consoleMessage = ContentSecurityPolicyStringBuilder(
                    capacity: (isReportOnly ? reportOnly.utf8.count : 0) + refused.utf8.count + value.count + because.utf8.count
                        + policy.directiveTextLength(violatedDirective) + 1
                )
                if isReportOnly {
                    consoleMessage.append(reportOnly)
                }
                consoleMessage.append(refused)
                consoleMessage.append(value)
                consoleMessage.append(because)
                policy.appendDirectiveText(violatedDirective, &consoleMessage)
                consoleMessage.append("\"")
                reportViolation(policy, violatedDirective, consoleMessage.toString())
            }
        }

        if isDuplicate && contentSecurityPolicyEquals(value, "default") {
            return allowTrustedTypePolicyDisallowedDuplicateName
        }

        return isAllowed ? allowTrustedTypePolicyAllowed : details
    }

    // https://w3c.github.io/trusted-types/dist/spec/#does-sink-require-trusted-types
    // ContentSecurityPolicy checks that the sink group is "script".
    @_expose(Cxx)
    func requireTrustedTypesForSinkGroup(_ includeReportOnlyPolicies: Bool) -> Bool {
        for policy in policies where policy.requiresTrustedTypesForScript() {
            if !policy.isReportOnly() || includeReportOnlyPolicies {
                return true
            }
        }
        return false
    }

    // https://w3c.github.io/trusted-types/dist/spec/#should-block-sink-type-mismatch
    // ContentSecurityPolicy checks that the sink group is "script".
    @_expose(Cxx)
    func allowMissingTrustedTypesForSinkGroup(
        _ stringContext: consuming WTF.String,
        _ sink: consuming WTF.String,
        _ sinkSource: consuming WTF.String
    ) -> Bool {
        let stringContext = consume stringContext
        let sink = consume sink
        let sinkSource = consume sinkSource
        guard let first = policies.firstIndex(where: { $0.requiresTrustedTypesForScript() }) else {
            return true
        }
        let sample: WTF.String
        if sinkSource.is8Bit() {
            sample = allowMissingTrustedTypesSample(sink, sinkSource.span8())
        } else {
            sample = allowMissingTrustedTypesSample(sink, sinkSource.checkedSpan16())
        }
        var isAllowed = true
        for index in first..<policies.count where policies[index].requiresTrustedTypesForScript() {
            let policy = policies[index]
            let isReportOnly = policy.isReportOnly()
            if !isReportOnly {
                isAllowed = false
            }

            let reportOnly = "[Report Only] "
            let requires = "This requires a "
            let violates = " value else it violates the following Content Security Policy directive: \"require-trusted-types-for 'script'\""
            var consoleMessage = ContentSecurityPolicyStringBuilder(
                capacity: (isReportOnly ? reportOnly.utf8.count : 0) + requires.utf8.count + Int(stringContext.length())
                    + violates.utf8.count
            )
            if isReportOnly {
                consoleMessage.append(reportOnly)
            }
            consoleMessage.append(requires)
            consoleMessage.append(stringContext)
            consoleMessage.append(violates)
            reportViolation(.requireTrustedTypesFor, policy, consoleMessage.toString(), sample)
        }
        return isAllowed
    }

    // The sink, '|', and up to 40 characters of the source after a Function constructor's prefix.
    private func allowMissingTrustedTypesSample<C: ContentSecurityPolicyCharacter>(
        _ sink: borrowing WTF.String,
        _ sinkSource: Span<C>
    ) -> WTF.String {
        var sampleStart = 0
        if contentSecurityPolicyEquals(sink, "Function") {
            for prefix in ["function anonymous", "async function anonymous", "function* anonymous", "async function* anonymous"]
            where contentSecurityPolicyStartsWith(sinkSource, prefix) {
                sampleStart = prefix.utf8.count
                break
            }
        }
        // A prefix the source starts with is no longer than it.
        let sampleEnd = Swift.max(sampleStart, Swift.min(sinkSource.count, sampleStart + 40))
        var sample = ContentSecurityPolicyStringBuilder(capacity: Int(sink.length()) + 1 + sampleEnd - sampleStart)
        sample.append(sink)
        sample.append("|")
        sample.append(sinkSource.extracting(sampleStart..<sampleEnd))
        return sample.toString()
    }

    // MARK: - For the policies while they are parsed

    func contentSecurityPolicyModeForExtension() -> UInt8 {
        modeForExtension
    }

    func enforceSandboxFlags<C: ContentSecurityPolicyCharacter>(_ sandboxPolicy: Span<C>) {
        let result = C.cspSandboxPolicy(sandboxPolicy)
        headerSandboxFlags |= result.flags
        if !result.invalidTokensErrorMessage.isNull() {
            reportInvalidSandboxFlags(result.invalidTokensErrorMessage)
        }
    }

    func addHashAlgorithmsForInlineScripts(_ hashAlgorithmsForInlineScripts: UInt8) {
        scriptHashAlgorithms |= hashAlgorithmsForInlineScripts
    }

    func addHashAlgorithmsForInlineStylesheets(_ hashAlgorithmsForInlineStylesheets: UInt8) {
        styleHashAlgorithms |= hashAlgorithmsForInlineStylesheets
    }

    func isPublicSuffix(_ host: WTF.String) -> Bool {
        WebCore.ContentSecurityPolicyCallbacks.isPublicSuffix(host)
    }

    func isLocalHostOrLoopbackIPAddress(_ host: WTF.String) -> Bool {
        WebCore.ContentSecurityPolicyCallbacks.isLocalHostOrLoopbackIPAddress(host)
    }

    // MARK: - Parse-time reports

    private func logToConsole(_ message: borrowing ContentSecurityPolicyStringBuilder) {
        WebCore.ContentSecurityPolicyCallbacks.logToConsole(message.toString())
    }

    private func logMessage(_ message: Swift.String) {
        WebCore.ContentSecurityPolicyCallbacks.logToConsole(makeContentSecurityPolicyString(message.utf8.span))
    }

    private func logMessage(_ prefix: Swift.String, _ part: borrowing WTF.String, _ suffix: Swift.String) {
        var message = ContentSecurityPolicyStringBuilder(capacity: prefix.utf8.count + Int(part.length()) + suffix.utf8.count)
        message.append(prefix)
        message.append(part)
        message.append(suffix)
        logToConsole(message)
    }

    private func logMessage(
        _ prefix: Swift.String,
        _ first: borrowing WTF.String,
        _ infix: Swift.String,
        _ second: borrowing WTF.String,
        _ suffix: Swift.String
    ) {
        var message = ContentSecurityPolicyStringBuilder(
            capacity: prefix.utf8.count + Int(first.length()) + infix.utf8.count + Int(second.length()) + suffix.utf8.count
        )
        message.append(prefix)
        message.append(first)
        message.append(infix)
        message.append(second)
        message.append(suffix)
        logToConsole(message)
    }

    func reportUnsupportedDirective(_ name: WTF.String) {
        if contentSecurityPolicyEqualLettersIgnoringASCIICase(name, "allow") {
            logMessage(
                "The 'allow' directive has been replaced with 'default-src'. Please use that directive instead, as 'allow' has no effect."
            )
        } else if contentSecurityPolicyEqualLettersIgnoringASCIICase(name, "options") {
            logMessage(
                "The 'options' directive has been replaced with 'unsafe-inline' and 'unsafe-eval' source expressions for the 'script-src' and 'style-src' directives. Please use those directives instead, as 'options' has no effect."
            )
        } else if contentSecurityPolicyEqualLettersIgnoringASCIICase(name, "policy-uri") {
            logMessage(
                "The 'policy-uri' directive has been removed from the specification. Please specify a complete policy via the Content-Security-Policy header."
            )
        } else {
            // FIXME: Why does this include a newline?
            logMessage("Unrecognized Content-Security-Policy directive '", name, "'.\n")
        }
    }

    func reportDeprecatedDirectiveToConsole(_ name: WTF.String) {
        logMessage("The Content Security Policy directive '", name, "' has been removed from the specification and is ignored.\n")
    }

    func reportDirectiveAsSourceExpression(_ directiveName: WTF.String, _ sourceExpression: WTF.String) {
        let prefix = "The Content Security Policy directive '"
        let contains = "' contains '"
        let didYouMean = "' as a source expression. Did you mean '"
        let separator = " ...; "
        let suffix = "...' (note the semicolon)?"
        var message = ContentSecurityPolicyStringBuilder(
            capacity: prefix.utf8.count + 2 * Int(directiveName.length()) + contains.utf8.count + 2 * Int(sourceExpression.length())
                + didYouMean.utf8.count + separator.utf8.count + suffix.utf8.count
        )
        message.append(prefix)
        message.append(directiveName)
        message.append(contains)
        message.append(sourceExpression)
        message.append(didYouMean)
        message.append(directiveName)
        message.append(separator)
        message.append(sourceExpression)
        message.append(suffix)
        logToConsole(message)
    }

    func reportDuplicateDirective(_ name: WTF.String) {
        logMessage("Ignoring duplicate Content-Security-Policy directive '", name, "'.\n")
    }

    func reportInvalidPluginTypes(_ pluginType: WTF.String) {
        if pluginType.isNull() {
            logMessage("'plugin-types' Content Security Policy directive is empty; all plugins will be blocked.\n")
        } else {
            logMessage("Invalid plugin type in 'plugin-types' Content Security Policy directive: '", pluginType, "'.\n")
        }
    }

    func reportInvalidTrustedTypesPolicy(_ policyName: WTF.String) {
        logMessage("Invalid policy name in 'trusted-types' Content Security Policy directive: '", policyName, "'.\n")
    }

    func reportInvalidTrustedTypesNoneKeyword() {
        logMessage(
            "Invalid policy name in 'trusted-types' Content Security Policy directive: 'none'. Note that 'none' has no effect unless it is the only expression.\n"
        )
    }

    func reportInvalidTrustedTypesSinkGroup(_ sinkGroup: WTF.String) {
        logMessage("Invalid sink group in 'require-trusted-types-for' Content Security Policy directive: '", sinkGroup, "'.\n")
    }

    func reportEmptyRequireTrustedTypesForDirective() {
        logMessage("'require-trusted-types-for' Content Security Policy directive is empty; The directive has no effect.\n")
    }

    func reportInvalidSandboxFlags(_ invalidFlags: WTF.String) {
        logMessage("Error while parsing the 'sandbox' Content Security Policy directive: ", invalidFlags, "")
    }

    func reportInvalidDirectiveInReportOnlyMode(_ directiveName: WTF.String) {
        logMessage("The Content Security Policy directive '", directiveName, "' is ignored when delivered in a report-only policy.")
    }

    func reportInvalidDirectiveInHTTPEquivMeta(_ directiveName: WTF.String) {
        logMessage("The Content Security Policy directive '", directiveName, "' is ignored when delivered via an HTML meta element.")
    }

    func reportInvalidDirectiveValueCharacter(_ directiveName: WTF.String, _ value: WTF.String) {
        logMessage(
            "The value for Content Security Policy directive '",
            directiveName,
            "' contains an invalid character: '",
            value,
            "'. Non-whitespace characters outside ASCII 0x21-0x7E must be percent-encoded, as described in RFC 3986, section 2.1: http://tools.ietf.org/html/rfc3986#section-2.1."
        )
    }

    func reportInvalidPathCharacter(_ directiveName: WTF.String, _ value: WTF.String, _ invalidChar: UInt8) {
        assert(invalidChar == UInt8(ascii: "#") || invalidChar == UInt8(ascii: "?"))
        let suffix =
            invalidChar == UInt8(ascii: "?")
            ? "'. The query component, including the '?', will be ignored."
            : "'. The fragment identifier, including the '#', will be ignored."
        logMessage(
            "The source list for Content Security Policy directive '",
            directiveName,
            "' contains a source with an invalid path: '",
            value,
            suffix
        )
    }

    func reportInvalidSourceExpression(_ directiveName: WTF.String, _ source: WTF.String) {
        let suffix =
            contentSecurityPolicyEqualLettersIgnoringASCIICase(source, "'none'")
            ? "'. It will be ignored. Note that 'none' has no effect unless it is the only expression in the source list."
            : "'. It will be ignored."
        logMessage(
            "The source list for Content Security Policy directive '",
            directiveName,
            "' contains an invalid source: '",
            source,
            suffix
        )
    }

    func reportMissingReportToTokens(_ policy: WTF.String) {
        logMessage(
            "The Content Security Policy '",
            policy,
            "' was delivered in report-only mode, but does not specify a 'report-to'; the policy will have no effect. Please either add a 'report-to' directive, or deliver the policy via the 'Content-Security-Policy' header."
        )
    }
}

// Whether `string` equals `lowercaseLetters` with its ASCII uppercase letters lowered, as equalLettersIgnoringASCIICase().
func contentSecurityPolicyEqualLettersIgnoringASCIICase(_ string: borrowing WTF.String, _ lowercaseLetters: Swift.String) -> Bool {
    var index = 0
    for unit in lowercaseLetters.utf16 {
        guard index < Int(string.length()) else {
            return false
        }
        var character = contentSecurityPolicyCodeUnit(string, index)
        if character >= 0x41 && character <= 0x5A {
            character |= 0x20
        }
        guard character == unit else {
            return false
        }
        index += 1
    }
    return index == Int(string.length())
}
