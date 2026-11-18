// Copyright (C) 2011 Google, Inc. All rights reserved.
// Copyright (C) 2016-2026 Apple Inc. All rights reserved.
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
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.Latin1Character
internal import wtf.Core.text.WTFString

// ContentSecurityPolicyHeaderType's values.
private let contentSecurityPolicyHeaderTypeReport: UInt8 = 0

// ContentSecurityPolicy::PolicyFrom's values.
private let policyFromHTTPEquivMeta: UInt8 = 1
private let policyFromInherited: UInt8 = 3
private let policyFromInheritedForPluginDocument: UInt8 = 4

private let evalDisabledErrorMessagePrefix: [UInt8] = Array(
    "Refused to evaluate a string as JavaScript because 'unsafe-eval' or 'trusted-types-eval' is not an allowed source of script in the following Content Security Policy directive: \""
        .utf8
)
private let webAssemblyDisabledErrorMessagePrefix: [UInt8] = Array(
    "Refused to create a WebAssembly object because 'unsafe-eval' or 'wasm-unsafe-eval' is not an allowed source of script in the following Content Security Policy directive: \""
        .utf8
)
private let disabledErrorMessageSuffix: [UInt8] = Array("\".\n".utf8)
private let scriptKeyword: [UInt8] = Array("'script'".utf8)

@inline(always)
private func isDirectiveNameCharacter(_ c: UInt16) -> Bool {
    cspIsASCIIAlphanumeric(c) || c == 0x2D
}

@inline(always)
private func isDirectiveValueCharacter(_ c: UInt16) -> Bool {
    cspIsASCIIWhitespace(c) || (c >= 0x21 && c <= 0x7E) // Whitespace + VCHAR
}

private func cspHasASCIIUpper<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) -> Bool {
    for index in 0..<characters.count where characters[index].cspCodeUnit >= 0x41 && characters[index].cspCodeUnit <= 0x5A {
        return true
    }
    return false
}

@inline(always)
private func isASCIIWhitespaceWithoutFF(_ c: UInt16) -> Bool {
    c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D
}

// Where a directive's text and value are in its policy's characters.
struct ContentSecurityPolicyDirectiveLocation {
    // Offsets into a policy's characters, which number fewer than 2^32.
    let textStart: UInt32
    let textEnd: UInt32
    let valueStart: UInt32
    let valueEnd: UInt32

    // `textRange` and `valueRange` are in the directive's characters, which start at `directiveBegin`.
    init(_ directiveBegin: Int, _ textRange: Range<Int>, _ valueRange: Range<Int>) {
        textStart = UInt32(truncatingIfNeeded: directiveBegin + textRange.lowerBound)
        textEnd = UInt32(truncatingIfNeeded: directiveBegin + textRange.upperBound)
        valueStart = UInt32(truncatingIfNeeded: directiveBegin + valueRange.lowerBound)
        valueEnd = UInt32(truncatingIfNeeded: directiveBegin + valueRange.upperBound)
    }
}

// The index in its list's directives of each directive a policy has.
struct ContentSecurityPolicyDirectiveIndices {
    var pluginTypes: Int?
    var baseURI: Int?
    var connectSrc: Int?
    var childSrc: Int?
    var defaultSrc: Int?
    var fontSrc: Int?
    var formAction: Int?
    var frameAncestors: Int?
    var frameSrc: Int?
    var imgSrc: Int?
    var manifestSrc: Int?
    var mediaSrc: Int?
    var objectSrc: Int?
    var prefetchSrc: Int?
    var scriptSrc: Int?
    var styleSrc: Int?
    var scriptSrcElem: Int?
    var scriptSrcAttr: Int?
    var styleSrcElem: Int?
    var styleSrcAttr: Int?
    var trustedTypes: Int?
    var workerSrc: Int?
}

// One policy: the directives of one header, or of one comma-separated part of it. It holds its directives, and the
// sources, nonces and hashes of their source lists, which the checks read; a check returns the index of the
// directive a request violates, whose name for reporting the fallback lookups set.
// swift-format-ignore: AlwaysUseLowerCamelCase
final class ContentSecurityPolicyDirectiveList {
    let m_header: WTF.String
    // The characters the directives were parsed from: the header, which a <meta> policy's m_header trims.
    private let m_parsedHeader: WTF.String
    let m_headerType: UInt8

    let m_reportOnly: Bool
    private let m_upgradeInsecureRequests: Bool
    private let m_requireTrustedTypesForScript: Bool
    private var m_trustedEvalEnabled = false

    private let m_directives: [ContentSecurityPolicyDirective]
    // Each directive's name for reporting, which the fallback lookups set: five bits per directive, twelve directives
    // to a word, in the order of m_directives. A list has at most one directive of each name, so fewer than 24.
    private var m_namesForReporting0: UInt64 = 0
    private var m_namesForReporting1: UInt64 = 0
    private let m_indices: ContentSecurityPolicyDirectiveIndices
    private let m_store: ContentSecurityPolicySourceStore
    private let m_trustedTypes: ContentSecurityPolicyTrustedTypesDirective?
    // Each directive's text, made the first time a report asks for it; empty until then. A bit per directive whose
    // text m_texts holds.
    private var m_texts: [WTF.String] = []
    private var m_textsMade: UInt32 = 0

    let m_reportToTokens: [WTF.String]
    let m_reportURIs: [WTF.String]

    // The directive that disallows eval or WebAssembly, whose text the error message quotes, or nil.
    private var m_evalDisabledDirective: Int?
    private var m_webAssemblyDisabledDirective: Int?

    private init(
        _ type: UInt8,
        _ header: WTF.String,
        _ parsedHeader: WTF.String,
        _ parser: consuming ContentSecurityPolicyDirectiveListParser
    ) {
        m_header = header
        m_parsedHeader = parsedHeader
        m_headerType = type
        m_reportOnly = type == contentSecurityPolicyHeaderTypeReport
        m_upgradeInsecureRequests = parser.m_upgradeInsecureRequests
        m_requireTrustedTypesForScript = parser.m_requireTrustedTypesForScript
        m_directives = parser.m_directives
        m_indices = parser.m_indices
        m_store = parser.m_store
        m_trustedTypes = parser.m_trustedTypes
        m_reportToTokens = parser.m_reportToTokens
        m_reportURIs = parser.m_reportURIs
        for directive in 0..<m_directives.count {
            setNameForReporting(directive, m_directives[directive].name)
        }
    }

    static func create(
        _ policy: ContentSecurityPolicyDirectiveListVector,
        _ header: WTF.String,
        _ type: UInt8,
        _ from: UInt8
    ) -> ContentSecurityPolicyDirectiveList {
        // A meta tag delivered CSP could contain invalid HTTP header values depending on how it was formatted in the document.
        // We want to store the CSP as a valid HTTP header for e.g. blob URL inheritance.
        let storedHeader = from == policyFromHTTPEquivMeta ? headerForMetaPolicy(header) : header
        var parser = ContentSecurityPolicyDirectiveListParser(policy, type == contentSecurityPolicyHeaderTypeReport)
        parser.parse(header, from)
        let directives = ContentSecurityPolicyDirectiveList(type, storedHeader, header, parser)

        // The messages are made when they are asked for, from the directive kept here.
        if !directives.checkEval(directives.operativeDirective(directives.m_indices.scriptSrc, .scriptSrc)) {
            // swift-format-ignore: NeverForceUnwrap
            directives.m_evalDisabledDirective = directives.operativeDirective(directives.m_indices.scriptSrc, .scriptSrc)!
        }

        if directives.checkTrustedEval(directives.operativeDirective(directives.m_indices.scriptSrc, .scriptSrc)) {
            directives.setTrustedEvalEnabled(true)
        }

        if !directives.checkWasmEval(directives.operativeDirective(directives.m_indices.scriptSrc, .scriptSrc)) {
            // swift-format-ignore: NeverForceUnwrap
            directives.m_webAssemblyDisabledDirective = directives.operativeDirective(directives.m_indices.scriptSrc, .scriptSrc)!
        }

        if directives.isReportOnly() && directives.m_reportToTokens.isEmpty && directives.m_reportURIs.isEmpty {
            policy.reportMissingReportToTokens(header)
        }

        return directives
    }

    // makeString(prefix, directiveText, "\".\n"_s), or a null String with no directive. A directive's text is ASCII.
    private func makeDisabledErrorMessage(_ prefix: [UInt8], _ directive: Int?) -> WTF.String {
        guard let directive else {
            return WTF.String()
        }
        var message = ContentSecurityPolicyStringBuilder(
            capacity: prefix.count + directiveTextLength(directive) + disabledErrorMessageSuffix.count
        )
        message.append(prefix)
        appendDirectiveText(directive, &message)
        message.append(disabledErrorMessageSuffix)
        return message.toString()
    }

    func header() -> WTF.String { m_header }
    func headerType() -> UInt8 { m_headerType }

    func hasPluginTypesDirective() -> Bool { m_indices.pluginTypes != nil }
    func hasFrameAncestorsDirective() -> Bool { m_indices.frameAncestors != nil }
    func requiresTrustedTypesForScript() -> Bool { m_requireTrustedTypesForScript }
    func trustedEvalEnabled() -> Bool { m_trustedEvalEnabled }

    func evalDisabledErrorMessage() -> WTF.String { makeDisabledErrorMessage(evalDisabledErrorMessagePrefix, m_evalDisabledDirective) }
    func webAssemblyDisabledErrorMessage() -> WTF.String {
        makeDisabledErrorMessage(webAssemblyDisabledErrorMessagePrefix, m_webAssemblyDisabledDirective)
    }
    func isReportOnly() -> Bool { m_reportOnly }

    private func setTrustedEvalEnabled(_ enabled: Bool) { m_trustedEvalEnabled = enabled }

    // MARK: The directive a check returns: its name for reporting, whether it is default-src, and its text.

    func nameForReporting(_ directive: Int) -> ContentSecurityPolicyDirectiveNames {
        let index = UInt64(truncatingIfNeeded: directive)
        let word = index < 12 ? m_namesForReporting0 : m_namesForReporting1
        // swift-format-ignore: NeverForceUnwrap
        return ContentSecurityPolicyDirectiveNames(rawValue: UInt8(truncatingIfNeeded: (word >> ((index % 12) * 5)) & 0x1F))!
    }

    func isDefaultSrc(_ directive: Int) -> Bool {
        m_directives[directive].name == .defaultSrc
    }

    func directiveText(_ directive: Int) -> WTF.String {
        let bit: UInt32 = 1 << UInt32(truncatingIfNeeded: directive)
        if m_textsMade & bit == 0 {
            if m_texts.isEmpty {
                m_texts = Array(repeating: WTF.String(), count: m_directives.count)
            }
            let characters = m_parsedHeader
            let record = m_directives[directive]
            m_texts[directive] = characters.is8Bit() ? record.text(characters.span8()) : record.text(characters.checkedSpan16())
            m_textsMade |= bit
        }
        return m_texts[directive]
    }

    func directiveTextLength(_ directive: Int) -> Int {
        m_directives[directive].textLength()
    }

    func appendDirectiveText(_ directive: Int, _ builder: inout ContentSecurityPolicyStringBuilder) {
        let characters = m_parsedHeader
        let record = m_directives[directive]
        if characters.is8Bit() {
            record.appendText(characters.span8(), &builder)
        } else {
            record.appendText(characters.checkedSpan16(), &builder)
        }
    }

    // Whether the fetch directive allows `url`.
    func sourceAllows(_ directive: Int, _ url: ContentSecurityPolicyURL, _ didReceiveRedirectResponse: Bool) -> Bool {
        if url.isEmpty {
            return false
        }
        return m_directives[directive].sourceList.matches(url, didReceiveRedirectResponse, m_store)
    }

    private func sourceList(_ directive: Int) -> ContentSecurityPolicySourceList {
        m_directives[directive].sourceList
    }

    private func checkEval(_ directive: Int?) -> Bool {
        guard let directive else {
            return true
        }
        return sourceList(directive).allowEval()
    }

    private func checkTrustedEval(_ directive: Int?) -> Bool {
        guard let directive else {
            return true
        }
        return sourceList(directive).allowTrustedEval()
    }

    private func checkWasmEval(_ directive: Int?) -> Bool {
        guard let directive else {
            return true
        }
        return sourceList(directive).allowWasmEval()
    }

    private func checkInline(_ directive: Int?) -> Bool {
        guard let directive else {
            return true
        }
        return sourceList(directive).allowInline()
    }

    private func checkUnsafeHashes(_ directive: Int?, _ hashes: WebCore.ContentSecurityPolicyContentHashes) -> Bool {
        guard let directive else {
            return true
        }
        let sourceList = sourceList(directive)
        return sourceList.allowUnsafeHashes() && sourceList.matches(hashes, m_store)
    }

    private func checkNonParserInsertedScripts(_ directive: Int?, _ parserInserted: Bool) -> Bool {
        guard let directive else {
            return true
        }

        return sourceList(directive).allowNonParserInsertedScripts() && !parserInserted
    }

    private func checkSource(_ directive: Int?, _ url: ContentSecurityPolicyURL, _ didReceiveRedirectResponse: Bool = false) -> Bool {
        guard let directive else {
            return true
        }
        return sourceAllows(directive, url, didReceiveRedirectResponse)
    }

    private func checkHashes(_ directive: Int?, _ hashes: WebCore.ContentSecurityPolicyContentHashes) -> Bool {
        guard let directive else {
            return true
        }
        return sourceList(directive).matches(hashes, m_store)
    }

    private func checkNonce(_ directive: Int?, _ nonce: borrowing WTF.String) -> Bool {
        guard let directive else {
            return true
        }
        return sourceList(directive).matches(nonce, m_store)
    }

    private func checkFrameAncestors(_ directive: Int?, _ ancestors: inout ContentSecurityPolicyFrameAncestors) -> Bool {
        guard let directive else {
            return true
        }
        return ancestors.areAllowed(self, directive)
    }

    // MARK: The directive a check uses, and the name its violation is reported under.

    private func setNameForReporting(_ directive: Int, _ nameForReporting: ContentSecurityPolicyDirectiveNames) {
        let index = UInt64(truncatingIfNeeded: directive)
        let shift = (index % 12) * 5
        let mask: UInt64 = 0x1F << shift
        let bits = UInt64(nameForReporting.rawValue) << shift
        if index < 12 {
            m_namesForReporting0 = (m_namesForReporting0 & ~mask) | bits
        } else {
            m_namesForReporting1 = (m_namesForReporting1 & ~mask) | bits
        }
    }

    private func operativeDirectiveForWorkerSrc(_ directive: Int?, _ nameForReporting: ContentSecurityPolicyDirectiveNames) -> Int? {
        // worker-src defers to child-src, then script-src, then default-src (https://www.w3.org/TR/CSP3/#changes-from-level-2).
        if let directive {
            setNameForReporting(directive, nameForReporting)
            return directive
        }

        if let childSrc = m_indices.childSrc {
            setNameForReporting(childSrc, nameForReporting)
            return childSrc
        }

        return operativeDirective(m_indices.scriptSrc, nameForReporting)
    }

    private func operativeDirective(_ directive: Int?, _ nameForReporting: ContentSecurityPolicyDirectiveNames) -> Int? {
        if let directive {
            setNameForReporting(directive, nameForReporting)
            return directive
        }

        let defaultSrc = m_indices.defaultSrc
        if let defaultSrc {
            setNameForReporting(defaultSrc, nameForReporting)
        }

        return defaultSrc
    }

    private func operativeDirectiveScript(_ directive: Int?, _ nameForReporting: ContentSecurityPolicyDirectiveNames) -> Int? {
        if let directive {
            setNameForReporting(directive, nameForReporting)
            return directive
        }
        return operativeDirective(m_indices.scriptSrc, nameForReporting)
    }

    private func operativeDirectiveStyle(_ directive: Int?, _ nameForReporting: ContentSecurityPolicyDirectiveNames) -> Int? {
        if let directive {
            setNameForReporting(directive, nameForReporting)
            return directive
        }
        return operativeDirective(m_indices.styleSrc, nameForReporting)
    }

    // MARK: The checks. Each returns the directive a request violates, or nil.

    func violatedDirectiveForUnsafeEval() -> Int? {
        let operativeDirective = self.operativeDirective(m_indices.scriptSrc, .scriptSrc)
        if checkEval(operativeDirective) {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForUnsafeInlineScriptElement(_ nonce: WTF.String, _ hashes: WebCore.ContentSecurityPolicyContentHashes) -> Int? {
        let operativeDirective = operativeDirectiveScript(m_indices.scriptSrcElem, .scriptSrcElem)
        if checkHashes(operativeDirective, hashes)
            || checkNonce(operativeDirective, nonce)
            || checkInline(operativeDirective)
        {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForInlineJavascriptURL(_ hashes: WebCore.ContentSecurityPolicyContentHashes) -> Int? {
        let operativeDirective = operativeDirectiveScript(m_indices.scriptSrcElem, .scriptSrcElem)
        if checkUnsafeHashes(operativeDirective, hashes)
            || checkInline(operativeDirective)
        {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForInlineEventHandlers(_ hashes: WebCore.ContentSecurityPolicyContentHashes) -> Int? {
        let operativeDirective = operativeDirectiveScript(m_indices.scriptSrcAttr, .scriptSrcAttr)
        if checkUnsafeHashes(operativeDirective, hashes)
            || checkInline(operativeDirective)
        {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForScriptUnderStrictDynamic(
        _ nonce: WTF.String,
        _ hashes: WebCore.ContentSecurityPolicyContentHashes,
        _ subResourceIntegrityDigests: inout ContentSecurityPolicyIntegrityDigests,
        _ url: ContentSecurityPolicyURL,
        _ parserInserted: Bool
    ) -> Int? {
        let operativeDirective = operativeDirectiveScript(m_indices.scriptSrcElem, .scriptSrcElem)
        let isInline = url.isEmpty
        // checkNonParserInsertedScripts() is true without a directive, so operativeDirective is not nil after it.
        // swift-format-ignore: NeverForceUnwrap
        if (isInline && checkHashes(operativeDirective, hashes))
            || checkNonParserInsertedScripts(operativeDirective, parserInserted)
            || checkNonce(operativeDirective, nonce)
            || sourceList(operativeDirective!).matchesAll(&subResourceIntegrityDigests, m_store)
            || (checkSource(operativeDirective, url) && !strictDynamicIncluded())
            || (isInline && checkInline(operativeDirective))
        {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForUnsafeInlineStyleElement(_ nonce: WTF.String, _ hashes: WebCore.ContentSecurityPolicyContentHashes) -> Int? {
        let operativeDirective = operativeDirectiveStyle(m_indices.styleSrcElem, .styleSrcElem)
        if checkHashes(operativeDirective, hashes)
            || checkNonce(operativeDirective, nonce)
            || checkInline(operativeDirective)
        {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForUnsafeInlineStyleAttribute(_ nonce: WTF.String, _ hashes: WebCore.ContentSecurityPolicyContentHashes) -> Int? {
        let operativeDirective = operativeDirectiveStyle(m_indices.styleSrcAttr, .styleSrcAttr)
        if checkUnsafeHashes(operativeDirective, hashes)
            || checkNonce(operativeDirective, nonce)
            || checkInline(operativeDirective)
        {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForScriptNonce(_ nonce: borrowing WTF.String) -> Int? {
        let operativeDirective = operativeDirectiveScript(m_indices.scriptSrcElem, .scriptSrc)
        if checkNonce(operativeDirective, nonce) {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForStyleNonce(_ nonce: borrowing WTF.String) -> Int? {
        let operativeDirective = operativeDirectiveStyle(m_indices.styleSrcElem, .styleSrc)
        if checkNonce(operativeDirective, nonce) {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForBaseURI(_ url: ContentSecurityPolicyURL) -> Int? {
        if checkSource(m_indices.baseURI, url) {
            return nil
        }
        return m_indices.baseURI
    }

    func violatedDirectiveForConnectSource(_ url: ContentSecurityPolicyURL, _ didReceiveRedirectResponse: Bool) -> Int? {
        let operativeDirective = self.operativeDirective(m_indices.connectSrc, .connectSrc)
        if checkSource(operativeDirective, url, didReceiveRedirectResponse) {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForFont(_ url: ContentSecurityPolicyURL, _ didReceiveRedirectResponse: Bool) -> Int? {
        let operativeDirective = self.operativeDirective(m_indices.fontSrc, .fontSrc)
        if checkSource(operativeDirective, url, didReceiveRedirectResponse) {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForFormAction(_ url: ContentSecurityPolicyURL, _ didReceiveRedirectResponse: Bool) -> Int? {
        if checkSource(m_indices.formAction, url, didReceiveRedirectResponse) {
            return nil
        }
        return m_indices.formAction
    }

    func violatedDirectiveForFrame(_ url: ContentSecurityPolicyURL, _ didReceiveRedirectResponse: Bool) -> Int? {
        if url.protocolIsAbout {
            return nil
        }

        // We must enforce the frame-src directive (if specified) before enforcing the child-src directive for a nested browsing
        // context by <https://w3c.github.io/webappsec-csp/2/#directive-child-src-nested> (29 August 2015).
        let operativeDirective = self.operativeDirective(m_indices.frameSrc ?? m_indices.childSrc, .frameSrc)
        if checkSource(operativeDirective, url, didReceiveRedirectResponse) {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForFrameAncestorOrigins(_ ancestors: inout ContentSecurityPolicyFrameAncestors) -> Int? {
        if checkFrameAncestors(m_indices.frameAncestors, &ancestors) {
            return nil
        }
        return m_indices.frameAncestors
    }

    func violatedDirectiveForImage(_ url: ContentSecurityPolicyURL, _ didReceiveRedirectResponse: Bool) -> Int? {
        let operativeDirective = self.operativeDirective(m_indices.imgSrc, .imgSrc)
        if checkSource(operativeDirective, url, didReceiveRedirectResponse) {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForPrefetch(_ url: ContentSecurityPolicyURL, _ didReceiveRedirectResponse: Bool) -> Int? {
        let operativeDirective = self.operativeDirective(m_indices.prefetchSrc, .prefetchSrc)
        if checkSource(operativeDirective, url, didReceiveRedirectResponse) {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForManifest(_ url: ContentSecurityPolicyURL, _ didReceiveRedirectResponse: Bool) -> Int? {
        let operativeDirective = self.operativeDirective(m_indices.manifestSrc, .manifestSrc)
        if checkSource(operativeDirective, url, didReceiveRedirectResponse) {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForMedia(_ url: ContentSecurityPolicyURL, _ didReceiveRedirectResponse: Bool) -> Int? {
        let operativeDirective = self.operativeDirective(m_indices.mediaSrc, .mediaSrc)
        if checkSource(operativeDirective, url, didReceiveRedirectResponse) {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForObjectSource(_ url: ContentSecurityPolicyURL, _ didReceiveRedirectResponse: Bool) -> Int? {
        if url.protocolIsAbout {
            return nil
        }
        let operativeDirective = self.operativeDirective(m_indices.objectSrc, .objectSrc)
        if checkSource(operativeDirective, url, didReceiveRedirectResponse) {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForWorker(_ url: ContentSecurityPolicyURL, _ didReceiveRedirectResponse: Bool) -> Int? {
        let operativeDirective = operativeDirectiveForWorkerSrc(m_indices.workerSrc, .workerSrc)
        // Per https://github.com/w3c/webappsec-csp/issues/200 we should allow workers when the directive contains 'strict-dynamic'
        if checkSource(operativeDirective, url, didReceiveRedirectResponse)
            || checkNonParserInsertedScripts(operativeDirective, false)
        {
            return nil
        }
        return operativeDirective
    }

    func violatedDirectiveForScript(
        _ url: ContentSecurityPolicyURL,
        _ didReceiveRedirectResponse: Bool,
        _ subResourceIntegrityDigests: inout ContentSecurityPolicyIntegrityDigests,
        _ nonce: WTF.String
    ) -> Int? {
        guard let operativeDirective = operativeDirectiveScript(m_indices.scriptSrcElem, .scriptSrcElem) else {
            return nil
        }

        if sourceList(operativeDirective).matchesAll(&subResourceIntegrityDigests, m_store)
            || checkNonce(operativeDirective, nonce)
            || (checkSource(operativeDirective, url, didReceiveRedirectResponse) && !strictDynamicIncluded())
        {
            return nil
        }

        return operativeDirective
    }

    func violatedDirectiveForStyle(
        _ url: ContentSecurityPolicyURL,
        _ didReceiveRedirectResponse: Bool,
        _ nonce: borrowing WTF.String
    ) -> Int? {
        let operativeDirective = operativeDirectiveStyle(m_indices.styleSrcElem, .styleSrcElem)
        if checkNonce(operativeDirective, nonce)
            || checkSource(operativeDirective, url, didReceiveRedirectResponse)
        {
            return nil
        }
        return operativeDirective
    }

    // `details` is AllowTrustedTypePolicy's value, which the directive sets when it refuses the name.
    func violatedDirectiveForTrustedTypesPolicy<C: ContentSecurityPolicyCharacter>(
        _ value: Span<C>,
        _ isDuplicate: Bool,
        _ details: inout UInt8
    ) -> Int? {
        guard let directive = m_indices.trustedTypes, let trustedTypes = m_trustedTypes else {
            return nil
        }
        if trustedTypes.allows(value, isDuplicate, &details, m_store) {
            return nil
        }
        return directive
    }

    func upgradeInsecureRequests() -> Bool {
        m_upgradeInsecureRequests
    }

    func strictDynamicIncluded() -> Bool {
        guard let directive = operativeDirectiveScript(m_indices.scriptSrcElem, .scriptSrc) else {
            return false
        }
        return sourceList(directive).allowNonParserInsertedScripts()
    }

    func shouldReportSample(_ violatedDirective: ContentSecurityPolicyDirectiveNames) -> Bool {
        var directive: Int?
        switch violatedDirective {
        case .styleSrc, .styleSrcAttr, .styleSrcElem:
            directive = m_indices.styleSrc
        case .scriptSrc, .scriptSrcAttr, .scriptSrcElem:
            directive = m_indices.scriptSrc
        case .trustedTypes, .requireTrustedTypesFor:
            return true
        default:
            break
        }

        guard let directive else {
            return false
        }
        return sourceList(directive).shouldReportSample()
    }

    private func hashReportDirectiveForScript() -> Int? {
        guard let directive = operativeDirectiveScript(m_indices.scriptSrcElem, .scriptSrcElem), sourceList(directive).reportHash() != 0
        else {
            return nil
        }
        return directive
    }

    // A HashAlgorithmSet.
    func reportHash() -> UInt8 {
        guard let directive = hashReportDirectiveForScript() else {
            return 0
        }
        return sourceList(directive).reportHash()
    }

    // MARK: The header a <meta> policy keeps.

    // policy.trim(isASCIIWhitespaceWithoutFF).removeCharacters(NUL, CR, LF), in the policy's width: the policy itself
    // when that changes nothing.
    private static func headerForMetaPolicy(_ policy: borrowing WTF.String) -> WTF.String {
        if policy.isEmpty() {
            return copy policy
        }
        if policy.is8Bit() {
            let characters: Span<WTF.Latin1Character> = policy.span8()
            let range = metaPolicyHeaderRange(characters)
            return headerForMetaPolicy(policy, characters, range, countRemovedFromMetaPolicyHeader(characters.extracting(range)))
        }
        let characters: Span<UInt16> = policy.checkedSpan16()
        let range = metaPolicyHeaderRange(characters)
        return headerForMetaPolicy(policy, characters, range, countRemovedFromMetaPolicyHeader(characters.extracting(range)))
    }

    private static func headerForMetaPolicy<C: ContentSecurityPolicyCharacter>(
        _ policy: borrowing WTF.String,
        _ characters: Span<C>,
        _ range: Range<Int>,
        _ removedCount: Int
    ) -> WTF.String {
        if removedCount == range.count {
            // An empty, not null, String.
            return C.cspMakeSubstring(characters.extracting(0..<0))
        }
        if removedCount == 0 {
            if range.count == characters.count {
                return copy policy
            }
            return C.cspMakeSubstring(characters.extracting(range))
        }
        let header = [C](capacity: range.count - removedCount) { output in
            for index in range where !isRemovedFromMetaPolicyHeader(characters[index].cspCodeUnit) {
                output.append(characters[index])
            }
        }
        return C.cspMakeSubstring(header.span)
    }

    private static func metaPolicyHeaderRange<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) -> Range<Int> {
        var start = 0
        var end = characters.count
        while start < end && isASCIIWhitespaceWithoutFF(characters[start].cspCodeUnit) {
            start += 1
        }
        while end > start && isASCIIWhitespaceWithoutFF(characters[end - 1].cspCodeUnit) {
            end -= 1
        }
        return start..<end
    }

    @inline(always)
    private static func isRemovedFromMetaPolicyHeader(_ c: UInt16) -> Bool {
        c == 0x00 || c == 0x0D || c == 0x0A
    }

    // The count of NUL, CR and LF characters, 16 bytes at a time. In a block, (x &- 1) & ~x has a lane's top bit set
    // only when the lane is 0. index is at most characters.count, and the count at most index, so none of the
    // arithmetic can overflow.
    private static func countRemovedFromMetaPolicyHeader(_ characters: Span<WTF.Latin1Character>) -> Int {
        var count = 0
        var index = 0
        while characters.count &- index >= 16 {
            let block = characters.extracting(index..<index &+ 16)
            let v = SIMD16<UInt8>(
                block[0].value, block[1].value, block[2].value, block[3].value, block[4].value, block[5].value,
                block[6].value, block[7].value, block[8].value, block[9].value, block[10].value, block[11].value,
                block[12].value, block[13].value, block[14].value, block[15].value)
            let one = SIMD16<UInt8>(repeating: 1)
            let cr = v ^ SIMD16<UInt8>(repeating: 0x0D)
            let lf = v ^ SIMD16<UInt8>(repeating: 0x0A)
            let zero = ((v &- one) & ~v) | ((cr &- one) & ~cr) | ((lf &- one) & ~lf)
            count &+= countOfTopBits(bitCast(zero & SIMD16<UInt8>(repeating: 0x80), to: SIMD2<UInt64>.self))
            index &+= 16
        }
        while index < characters.count {
            count &+= isRemovedFromMetaPolicyHeader(characters[index].cspCodeUnit) ? 1 : 0
            index &+= 1
        }
        return count
    }

    private static func countRemovedFromMetaPolicyHeader(_ characters: Span<UInt16>) -> Int {
        var count = 0
        var index = 0
        let bytes = characters.bytes
        while characters.count &- index >= 8 {
            let v = bytes.load(fromByteOffset: index &* 2, as: SIMD8<UInt16>.self)
            let one = SIMD8<UInt16>(repeating: 1)
            let cr = v ^ SIMD8<UInt16>(repeating: 0x0D)
            let lf = v ^ SIMD8<UInt16>(repeating: 0x0A)
            let zero = ((v &- one) & ~v) | ((cr &- one) & ~cr) | ((lf &- one) & ~lf)
            count &+= countOfTopBits(bitCast(zero & SIMD8<UInt16>(repeating: 0x8000), to: SIMD2<UInt64>.self))
            index &+= 8
        }
        while index < characters.count {
            count &+= isRemovedFromMetaPolicyHeader(characters[index]) ? 1 : 0
            index &+= 1
        }
        return count
    }

    @inline(always)
    private static func countOfTopBits(_ words: SIMD2<UInt64>) -> Int {
        let low = words[0]
        let high = words[1]
        if (low | high) == 0 {
            return 0
        }
        return low.nonzeroBitCount &+ high.nonzeroBitCount
    }
}

// Parses a policy into the directives, source lists and flags a ContentSecurityPolicyDirectiveList keeps.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct ContentSecurityPolicyDirectiveListParser {
    // FIXME: Make this private once a private type links under ThinLTO on Windows ("Invalid weak external").
    struct ParsedDirective {
        var name: ContentSecurityPolicyDirectiveNames?
        // The lowercased name of a directive this list does not know.
        var unknownName: [UInt8]
        // The value's characters in the directive's.
        var valueRange: Range<Int>
        // The directive's characters from its name on, when they are already its text: a lowercase name and one
        // space before the value. Empty otherwise.
        var textRange: Range<Int> = 0..<0

        func nameString() -> WTF.String {
            if let name {
                return name.string()
            }
            return makeContentSecurityPolicyString(unknownName.span)
        }
    }

    let m_policy: ContentSecurityPolicyDirectiveListVector
    let m_reportOnly: Bool
    private var m_haveSandboxPolicy = false
    private(set) var m_upgradeInsecureRequests = false
    private var m_hasBlockAllMixedContentDirective = false
    private(set) var m_requireTrustedTypesForScript = false

    private(set) var m_directives: [ContentSecurityPolicyDirective] = []
    private(set) var m_indices = ContentSecurityPolicyDirectiveIndices()
    private(set) var m_store = ContentSecurityPolicySourceStore()
    private(set) var m_trustedTypes: ContentSecurityPolicyTrustedTypesDirective?

    private(set) var m_reportToTokens: [WTF.String] = []
    private(set) var m_reportURIs: [WTF.String] = []

    init(_ policy: ContentSecurityPolicyDirectiveListVector, _ reportOnly: Bool) {
        m_policy = policy
        m_reportOnly = reportOnly
    }

    // policy            = directive-list
    // directive-list    = [ directive *( ";" [ directive ] ) ]
    //
    mutating func parse(_ policy: borrowing WTF.String, _ policyFrom: UInt8) {
        if policy.isEmpty() {
            return
        }

        if policy.is8Bit() {
            parse(policy.span8(), policyFrom)
        } else {
            parse(policy.checkedSpan16(), policyFrom)
        }
    }

    private mutating func parse<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>, _ policyFrom: UInt8) {
        let end = characters.count
        var position = 0
        while position < end {
            let directiveBegin = position
            while position < end && characters[position].cspCodeUnit != 0x3B {
                position += 1
            }

            let directiveCharacters = characters.extracting(directiveBegin..<position)
            if let directive = parseDirective(directiveCharacters) {
                if policyFrom == policyFromInherited {
                    if directive.name == .upgradeInsecureRequests
                        || directive.name == .sandbox
                    {
                        continue
                    }
                } else if policyFrom == policyFromHTTPEquivMeta {
                    if directive.name == .sandbox
                        || directive.name == .reportURI
                        || directive.name == .frameAncestors
                    {
                        m_policy.reportInvalidDirectiveInHTTPEquivMeta(directive.nameString())
                        continue
                    }
                } else if policyFrom == policyFromInheritedForPluginDocument {
                    if directive.name != .pluginTypes
                        && directive.name != .reportURI
                        && directive.name != .reportTo
                    {
                        continue
                    }
                }
                addDirective(directive, directiveCharacters.extracting(directive.valueRange), directiveBegin, end - position)
            }

            if position < end && characters[position].cspCodeUnit == 0x3B {
                position += 1
            }
        }
    }

    // directive         = *WSP [ directive-name [ WSP directive-value ] ]
    // directive-name    = 1*( ALPHA / DIGIT / "-" )
    // directive-value   = *( WSP / <VCHAR except ";"> )
    //
    private func parseDirective<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) -> ParsedDirective? {
        let end = characters.count
        var position = 0
        while position < end && cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
            position += 1
        }

        // Empty directive (e.g. ";;;"). Exit early.
        if position == end {
            return nil
        }

        let nameBegin = position
        while position < end && isDirectiveNameCharacter(characters[position].cspCodeUnit) {
            position += 1
        }
        let nameEnd = position

        // The directive-name must be non-empty.
        if nameBegin == position {
            while position < end && !cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
                position += 1
            }
            m_policy.reportUnsupportedDirective(C.cspMakeString(characters.extracting(nameBegin..<position)))
            return nil
        }

        // Lowercase the directive name eagerly so downstream code can use case-sensitive comparisons.
        let nameCharacters = characters.extracting(nameBegin..<position)
        let name = ContentSecurityPolicyDirectiveNames.named(nameCharacters)
        var unknownName: [UInt8] = []
        if name == nil {
            unknownName = cspASCIIBytes(nameCharacters, 0..<nameCharacters.count)
            for index in 0..<unknownName.count {
                unknownName[index] = UInt8(truncatingIfNeeded: cspToASCIILower(UInt16(unknownName[index])))
            }
        }

        if position == end {
            return ParsedDirective(name: name, unknownName: unknownName, valueRange: 0..<0)
        }

        if !cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
            while position < end && !cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
                position += 1
            }
            m_policy.reportUnsupportedDirective(C.cspMakeString(characters.extracting(nameBegin..<position)))
            return nil
        }
        position += 1

        while position < end && cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
            position += 1
        }

        let valueBegin = position
        while position < end && isDirectiveValueCharacter(characters[position].cspCodeUnit) {
            position += 1
        }

        if position != end {
            let directive = ParsedDirective(name: name, unknownName: unknownName, valueRange: 0..<0)
            m_policy.reportInvalidDirectiveValueCharacter(directive.nameString(), C.cspMakeString(characters.extracting(valueBegin..<end)))
            return nil
        }

        // The directive-value may be empty.
        var textRange = 0..<0
        if characters[nameEnd].cspCodeUnit == 0x20 && valueBegin == nameEnd + 1 && !cspHasASCIIUpper(nameCharacters) {
            textRange = nameBegin..<end
        }
        if valueBegin == position {
            return ParsedDirective(name: name, unknownName: unknownName, valueRange: 0..<0, textRange: textRange)
        }

        return ParsedDirective(name: name, unknownName: unknownName, valueRange: valueBegin..<position, textRange: textRange)
    }

    // The tokens of a report-uri or report-to value, split on ASCII whitespace.
    private static func reportTokens<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) -> [WTF.String] {
        var tokens: [WTF.String] = []
        let end = characters.count
        var position = 0
        while position < end {
            while position < end && cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
                position += 1
            }

            let urlBegin = position
            while position < end && !cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
                position += 1
            }

            if urlBegin < position {
                tokens.append(C.cspMakeString(characters.extracting(urlBegin..<position)))
            }
        }
        return tokens
    }

    private mutating func parseReportURI<C: ContentSecurityPolicyCharacter>(_ directive: ParsedDirective, _ value: Span<C>) {
        if !m_reportURIs.isEmpty {
            m_policy.reportDuplicateDirective(directive.nameString())
            return
        }

        m_reportURIs = ContentSecurityPolicyDirectiveListParser.reportTokens(value)
    }

    private mutating func parseReportTo<C: ContentSecurityPolicyCharacter>(_ directive: ParsedDirective, _ value: Span<C>) {
        if !m_reportToTokens.isEmpty {
            m_policy.reportDuplicateDirective(directive.nameString())
            return
        }

        m_reportToTokens = ContentSecurityPolicyDirectiveListParser.reportTokens(value)
    }

    private mutating func parseRequireTrustedTypesFor<C: ContentSecurityPolicyCharacter>(_ directive: ParsedDirective, _ value: Span<C>) {
        if m_requireTrustedTypesForScript {
            m_policy.reportDuplicateDirective(directive.nameString())
            return
        }

        parseRequireTrustedTypesFor(value)
    }

    private mutating func parseRequireTrustedTypesFor<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) {
        let end = characters.count
        var position = 0
        while position < end {
            while position < end && cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
                position += 1
            }
            if position == end {
                m_policy.reportEmptyRequireTrustedTypesForDirective()
                continue
            }

            let begin = position
            guard
                cspStartsWithLettersIgnoringASCIICase(characters.extracting(position..<end), scriptKeyword.span)
                    && (position + scriptKeyword.count == end
                        || cspIsASCIIWhitespace(characters[position + scriptKeyword.count].cspCodeUnit))
            else {
                while position < end && !cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
                    position += 1
                }
                m_policy.reportInvalidTrustedTypesSinkGroup(C.cspMakeString(characters.extracting(begin..<position)))
                continue
            }
            position += scriptKeyword.count
            m_requireTrustedTypesForScript = true
        }
    }

    // The directive's index in m_directives. `location` is where the directive's text and value are in the policy's
    // characters, and `charactersAfterValue` how many of them follow the value.
    private mutating func makeSourceListDirective<C: ContentSecurityPolicyCharacter>(
        _ existingDirective: Int?,
        _ name: ContentSecurityPolicyDirectiveNames,
        _ value: Span<C>,
        _ location: ContentSecurityPolicyDirectiveLocation,
        _ charactersAfterValue: Int
    ) -> Int {
        if let existingDirective {
            m_policy.reportDuplicateDirective(name.string())
            return existingDirective
        }
        var sourceList = ContentSecurityPolicySourceList(name, m_policy.contentSecurityPolicyModeForExtension())
        sourceList.parse(value, m_policy, &m_store, charactersAfterValue)
        return appendDirective(name, location, sourceList)
    }

    private mutating func appendDirective(
        _ name: ContentSecurityPolicyDirectiveNames,
        _ location: ContentSecurityPolicyDirectiveLocation,
        _ sourceList: ContentSecurityPolicySourceList
    ) -> Int {
        m_directives.append(ContentSecurityPolicyDirective(name, location, sourceList))
        return m_directives.count - 1
    }

    private mutating func applySandboxPolicy<C: ContentSecurityPolicyCharacter>(_ directive: ParsedDirective, _ value: Span<C>) {
        if m_reportOnly {
            m_policy.reportInvalidDirectiveInReportOnlyMode(directive.nameString())
            return
        }
        if m_haveSandboxPolicy {
            m_policy.reportDuplicateDirective(directive.nameString())
            return
        }
        m_haveSandboxPolicy = true
        // Adds the flags parseSandboxPolicy() gives to the header's, and reports the invalid tokens.
        m_policy.enforceSandboxFlags(value)
    }

    private mutating func setUpgradeInsecureRequests(_ directive: ParsedDirective) {
        if m_reportOnly {
            m_policy.reportInvalidDirectiveInReportOnlyMode(directive.nameString())
            return
        }
        if m_upgradeInsecureRequests {
            m_policy.reportDuplicateDirective(directive.nameString())
            return
        }
        m_upgradeInsecureRequests = true
    }

    private mutating func setBlockAllMixedContentEnabled(_ directive: ParsedDirective) {
        if m_hasBlockAllMixedContentDirective {
            m_policy.reportDuplicateDirective(directive.nameString())
            return
        }
        m_hasBlockAllMixedContentDirective = true
    }

    // `directiveBegin` is where the directive's characters start in the policy's, and `charactersAfterValue` how many
    // of the policy's characters follow its value.
    private mutating func addDirective<C: ContentSecurityPolicyCharacter>(
        _ directive: ParsedDirective,
        _ value: Span<C>,
        _ directiveBegin: Int,
        _ charactersAfterValue: Int
    ) {
        guard let name = directive.name else {
            m_policy.reportUnsupportedDirective(directive.nameString())
            return
        }

        let location = ContentSecurityPolicyDirectiveLocation(directiveBegin, directive.textRange, directive.valueRange)
        switch name {
        case .defaultSrc:
            let defaultSrc = makeSourceListDirective(m_indices.defaultSrc, name, value, location, charactersAfterValue)
            m_indices.defaultSrc = defaultSrc
            let hashAlgorithmsUsed = m_directives[defaultSrc].sourceList.hashAlgorithmsUsed()
            m_policy.addHashAlgorithmsForInlineScripts(hashAlgorithmsUsed)
            m_policy.addHashAlgorithmsForInlineStylesheets(hashAlgorithmsUsed)
        case .scriptSrc:
            let scriptSrc = makeSourceListDirective(m_indices.scriptSrc, name, value, location, charactersAfterValue)
            m_indices.scriptSrc = scriptSrc
            m_policy.addHashAlgorithmsForInlineScripts(m_directives[scriptSrc].sourceList.hashAlgorithmsUsed())
        case .scriptSrcElem:
            let scriptSrcElem = makeSourceListDirective(m_indices.scriptSrcElem, name, value, location, charactersAfterValue)
            m_indices.scriptSrcElem = scriptSrcElem
            m_policy.addHashAlgorithmsForInlineScripts(m_directives[scriptSrcElem].sourceList.hashAlgorithmsUsed())
        case .scriptSrcAttr:
            let scriptSrcAttr = makeSourceListDirective(m_indices.scriptSrcAttr, name, value, location, charactersAfterValue)
            m_indices.scriptSrcAttr = scriptSrcAttr
            m_policy.addHashAlgorithmsForInlineScripts(m_directives[scriptSrcAttr].sourceList.hashAlgorithmsUsed())
        case .styleSrc:
            let styleSrc = makeSourceListDirective(m_indices.styleSrc, name, value, location, charactersAfterValue)
            m_indices.styleSrc = styleSrc
            m_policy.addHashAlgorithmsForInlineStylesheets(m_directives[styleSrc].sourceList.hashAlgorithmsUsed())
        case .styleSrcElem:
            let styleSrcElem = makeSourceListDirective(m_indices.styleSrcElem, name, value, location, charactersAfterValue)
            m_indices.styleSrcElem = styleSrcElem
            m_policy.addHashAlgorithmsForInlineStylesheets(m_directives[styleSrcElem].sourceList.hashAlgorithmsUsed())
        case .styleSrcAttr:
            let styleSrcAttr = makeSourceListDirective(m_indices.styleSrcAttr, name, value, location, charactersAfterValue)
            m_indices.styleSrcAttr = styleSrcAttr
            m_policy.addHashAlgorithmsForInlineStylesheets(m_directives[styleSrcAttr].sourceList.hashAlgorithmsUsed())
        case .objectSrc:
            m_indices.objectSrc = makeSourceListDirective(m_indices.objectSrc, name, value, location, charactersAfterValue)
        case .workerSrc:
            m_indices.workerSrc = makeSourceListDirective(m_indices.workerSrc, name, value, location, charactersAfterValue)
        case .frameSrc:
            // FIXME: Log to console "The frame-src directive is deprecated. Use the child-src directive instead."
            // See <https://bugs.webkit.org/show_bug.cgi?id=155773>.
            m_indices.frameSrc = makeSourceListDirective(m_indices.frameSrc, name, value, location, charactersAfterValue)
        case .imgSrc:
            m_indices.imgSrc = makeSourceListDirective(m_indices.imgSrc, name, value, location, charactersAfterValue)
        case .fontSrc:
            m_indices.fontSrc = makeSourceListDirective(m_indices.fontSrc, name, value, location, charactersAfterValue)
        case .manifestSrc:
            m_indices.manifestSrc = makeSourceListDirective(m_indices.manifestSrc, name, value, location, charactersAfterValue)
        case .mediaSrc:
            m_indices.mediaSrc = makeSourceListDirective(m_indices.mediaSrc, name, value, location, charactersAfterValue)
        case .connectSrc:
            m_indices.connectSrc = makeSourceListDirective(m_indices.connectSrc, name, value, location, charactersAfterValue)
        case .childSrc:
            m_indices.childSrc = makeSourceListDirective(m_indices.childSrc, name, value, location, charactersAfterValue)
        case .formAction:
            m_indices.formAction = makeSourceListDirective(m_indices.formAction, name, value, location, charactersAfterValue)
        case .baseURI:
            m_indices.baseURI = makeSourceListDirective(m_indices.baseURI, name, value, location, charactersAfterValue)
        case .frameAncestors:
            m_indices.frameAncestors = makeSourceListDirective(m_indices.frameAncestors, name, value, location, charactersAfterValue)
        case .pluginTypes:
            if m_indices.pluginTypes != nil {
                m_policy.reportDuplicateDirective(directive.nameString())
            } else {
                ContentSecurityPolicyMediaListDirective.parseValue(m_policy, value)
                m_indices.pluginTypes = appendDirective(
                    name,
                    location,
                    ContentSecurityPolicySourceList(name, contentSecurityPolicyModeForExtensionNone)
                )
            }
            m_policy.reportDeprecatedDirectiveToConsole(directive.nameString())
        case .prefetchSrc:
            m_indices.prefetchSrc = makeSourceListDirective(m_indices.prefetchSrc, name, value, location, charactersAfterValue)
        case .sandbox:
            applySandboxPolicy(directive, value)
        case .reportTo:
            parseReportTo(directive, value)
        case .reportURI:
            parseReportURI(directive, value)
        case .upgradeInsecureRequests:
            setUpgradeInsecureRequests(directive)
        case .blockAllMixedContent:
            setBlockAllMixedContentEnabled(directive)
        case .trustedTypes:
            if m_indices.trustedTypes != nil {
                m_policy.reportDuplicateDirective(directive.nameString())
            } else {
                m_trustedTypes = ContentSecurityPolicyTrustedTypesDirective(m_policy, value, &m_store)
                m_indices.trustedTypes = appendDirective(
                    name,
                    location,
                    ContentSecurityPolicySourceList(name, contentSecurityPolicyModeForExtensionNone)
                )
            }
        case .requireTrustedTypesFor:
            parseRequireTrustedTypesFor(directive, value)
        }
    }
}
