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
internal import WebCore_Private.ContentSecurityPolicySwift
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.Latin1Character
internal import wtf.Core.text.WTFString

// The directive names. Directive names are parsed lowercased, so each one is compared and stored as its lowercase
// ASCII spelling; the String forms are made only for reports and console messages.
enum ContentSecurityPolicyDirectiveNames: UInt8 {
    case baseURI
    case childSrc
    case connectSrc
    case defaultSrc
    case fontSrc
    case formAction
    case frameAncestors
    case frameSrc
    case manifestSrc
    case imgSrc
    case mediaSrc
    case objectSrc
    case pluginTypes
    case prefetchSrc
    case reportTo
    case reportURI
    case requireTrustedTypesFor
    case sandbox
    case scriptSrc
    case scriptSrcAttr
    case scriptSrcElem
    case styleSrc
    case styleSrcAttr
    case styleSrcElem
    case trustedTypes
    case upgradeInsecureRequests
    case blockAllMixedContent
    case workerSrc

    var spelling: [UInt8] { contentSecurityPolicyDirectiveNameSpellings[Int(rawValue)] }

    func string() -> WTF.String { makeContentSecurityPolicyString(spelling.span) }

    // The directive whose lowercase spelling equals `characters` compared ASCII case-insensitively, which is the
    // same as lowercasing `characters` and comparing exactly.
    static func named<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) -> ContentSecurityPolicyDirectiveNames? {
        let names = contentSecurityPolicyDirectiveNameSpellings.span
        for index in 0..<names.count where cspEqualLettersIgnoringASCIICase(characters, names[index].span) {
            return ContentSecurityPolicyDirectiveNames(rawValue: UInt8(truncatingIfNeeded: index))
        }
        return nil
    }
}

// In the order of the enumeration.
let contentSecurityPolicyDirectiveNameSpellings: [[UInt8]] = [
    Array("base-uri".utf8),
    Array("child-src".utf8),
    Array("connect-src".utf8),
    Array("default-src".utf8),
    Array("font-src".utf8),
    Array("form-action".utf8),
    Array("frame-ancestors".utf8),
    Array("frame-src".utf8),
    Array("manifest-src".utf8),
    Array("img-src".utf8),
    Array("media-src".utf8),
    Array("object-src".utf8),
    Array("plugin-types".utf8),
    Array("prefetch-src".utf8),
    Array("report-to".utf8),
    Array("report-uri".utf8),
    Array("require-trusted-types-for".utf8),
    Array("sandbox".utf8),
    Array("script-src".utf8),
    Array("script-src-attr".utf8),
    Array("script-src-elem".utf8),
    Array("style-src".utf8),
    Array("style-src-attr".utf8),
    Array("style-src-elem".utf8),
    Array("trusted-types".utf8),
    Array("upgrade-insecure-requests".utf8),
    Array("block-all-mixed-content".utf8),
    Array("worker-src".utf8),
]

// MARK: Characters of a WTF::String, either width.

// A code unit of a String's characters: Latin1Character for an 8-bit String, char16_t for a 16-bit one. The parsers
// and matchers are generic over it.
protocol ContentSecurityPolicyCharacter {
    var cspCodeUnit: UInt16 { get }
    static func cspMakeString(_ characters: Span<Self>) -> WTF.String
    // A part of a String's characters, as String(std::span) makes it: an empty part of a non-empty String is an
    // empty String, not a null one.
    static func cspMakeSubstring(_ characters: Span<Self>) -> WTF.String
    // contentSecurityPolicyHashSourceDigest() of the characters between a hash source's quotes.
    static func cspHashSourceDigest(_ characters: Span<Self>) -> WebCore.ContentSecurityPolicyDigest
    // parseSandboxPolicy() of a sandbox directive's value.
    static func cspSandboxPolicy(_ characters: Span<Self>) -> WebCore.SandboxPolicyParseResult
}

extension ContentSecurityPolicyCharacter where Self: HTTPHeaderStringCodeUnit {
    static func cspHashSourceDigest(_ characters: Span<Self>) -> WebCore.ContentSecurityPolicyDigest {
        contentSecurityPolicyHashSourceDigest(characters)
    }
    static func cspSandboxPolicy(_ characters: Span<Self>) -> WebCore.SandboxPolicyParseResult {
        parseSandboxPolicy(characters)
    }
}

extension WTF.Latin1Character: ContentSecurityPolicyCharacter {
    var cspCodeUnit: UInt16 { UInt16(value) }
    static func cspMakeString(_ characters: Span<WTF.Latin1Character>) -> WTF.String {
        // An empty span may have no address, which a std::span parameter cannot take; empty characters give a null String.
        if characters.isEmpty {
            return WTF.String()
        }
        return WTF.String(characters)
    }
    static func cspMakeSubstring(_ characters: Span<WTF.Latin1Character>) -> WTF.String { WTF.String(characters) }
    static func cspHashSourceDigest(_ characters: Span<WTF.Latin1Character>) -> WebCore.ContentSecurityPolicyDigest {
        contentSecurityPolicyHashSourceDigest(WTF.bytesOfLatin1Characters(characters))
    }
    static func cspSandboxPolicy(_ characters: Span<WTF.Latin1Character>) -> WebCore.SandboxPolicyParseResult {
        parseSandboxPolicy(WTF.bytesOfLatin1Characters(characters))
    }
}

extension UInt16: ContentSecurityPolicyCharacter {
    var cspCodeUnit: UInt16 { self }
    static func cspMakeString(_ characters: Span<UInt16>) -> WTF.String {
        if characters.isEmpty {
            return WTF.String()
        }
        return WTF.String(characters)
    }
    static func cspMakeSubstring(_ characters: Span<UInt16>) -> WTF.String { WTF.String(characters) }
}

// An 8-bit String of the given characters.
func makeContentSecurityPolicyString(_ characters: Span<UInt8>) -> WTF.String {
    // An empty span may have no address, which a std::span parameter cannot take; empty characters give a null String.
    if characters.isEmpty {
        return WTF.String()
    }
    return WTF.String(WTF.latin1CharactersOfBytes(characters))
}

@inline(always)
func cspIsASCIIWhitespace(_ c: UInt16) -> Bool {
    // isASCIIWhitespace: space, tab, LF, FF, CR.
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D
}

@inline(always)
func cspIsASCIIAlpha(_ c: UInt16) -> Bool {
    (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A
}

@inline(always)
func cspIsASCIIDigit(_ c: UInt16) -> Bool {
    c >= 0x30 && c <= 0x39
}

@inline(always)
func cspIsASCIIAlphanumeric(_ c: UInt16) -> Bool {
    cspIsASCIIAlpha(c) || cspIsASCIIDigit(c)
}

@inline(always)
func cspToASCIILower(_ c: UInt16) -> UInt16 {
    c >= 0x41 && c <= 0x5A ? c | 0x20 : c
}

// equalLettersIgnoringASCIICase, or equalIgnoringASCIICase, with a lowercase ASCII spelling.
func cspEqualLettersIgnoringASCIICase<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>, _ lowercaseSpelling: Span<UInt8>) -> Bool {
    if characters.count != lowercaseSpelling.count {
        return false
    }
    for index in 0..<characters.count where cspToASCIILower(characters[index].cspCodeUnit) != UInt16(lowercaseSpelling[index]) {
        return false
    }
    return true
}

// Whether `characters` start with `lowercaseSpelling`, ASCII case-insensitively (skipExactlyIgnoringASCIICase).
func cspStartsWithLettersIgnoringASCIICase<C: ContentSecurityPolicyCharacter>(
    _ characters: Span<C>,
    _ lowercaseSpelling: Span<UInt8>
) -> Bool {
    if characters.count < lowercaseSpelling.count {
        return false
    }
    for index in 0..<lowercaseSpelling.count where cspToASCIILower(characters[index].cspCodeUnit) != UInt16(lowercaseSpelling[index]) {
        return false
    }
    return true
}

// Exact comparison of two character sequences of either width (String's operator==).
func cspEqualCodeUnits<A: ContentSecurityPolicyCharacter, B: ContentSecurityPolicyCharacter>(_ a: Span<A>, _ b: Span<B>) -> Bool {
    if a.count != b.count {
        return false
    }
    for index in 0..<a.count where a[index].cspCodeUnit != b[index].cspCodeUnit {
        return false
    }
    return true
}

extension UInt8: ContentSecurityPolicyCharacter {
    var cspCodeUnit: UInt16 { UInt16(self) }
    static func cspMakeString(_ characters: Span<UInt8>) -> WTF.String { makeContentSecurityPolicyString(characters) }
    static func cspMakeSubstring(_ characters: Span<UInt8>) -> WTF.String { WTF.String(WTF.latin1CharactersOfBytes(characters)) }
}

// A set of ASCII names, such as the nonces of a source list, compared exactly, as HashSet<String> compares them. Below
// hashedNameCount names, a name is compared with each one; from hashedNameCount on, it is found by a hash of its
// characters.
struct ContentSecurityPolicyNameSet {
    static let hashedNameCount = 16

    // The names' characters, one after another, and where each name ends.
    private var characters: [UInt8] = []
    private var ends: [UInt32] = []
    // With hashedNameCount names or more: each name's hash, and a table of name indices plus one (0 for an empty
    // slot), probed linearly, with at least twice as many slots as names.
    private var hashes: [UInt32] = []
    private var table: [UInt32] = []

    var isEmpty: Bool { ends.isEmpty }

    mutating func add<C: ContentSecurityPolicyCharacter>(_ name: Span<C>) {
        if contains(name) {
            return
        }
        for index in 0..<name.count {
            characters.append(UInt8(truncatingIfNeeded: name[index].cspCodeUnit))
        }
        // The names are a directive value's characters, which number fewer than 2^32.
        ends.append(UInt32(truncatingIfNeeded: characters.count))
        let count = ends.count
        if count < ContentSecurityPolicyNameSet.hashedNameCount {
            return
        }
        if count == ContentSecurityPolicyNameSet.hashedNameCount {
            for index in 0..<count {
                let hash = ContentSecurityPolicyNameSet.hash(characters.span.extracting(nameRange(index)))
                hashes.append(hash)
            }
        } else {
            hashes.append(ContentSecurityPolicyNameSet.hash(name))
        }
        if table.count >= 2 * count {
            insert(count - 1)
            return
        }
        var capacity = 1
        while capacity < 4 * count {
            capacity *= 2
        }
        table = Array(repeating: 0, count: capacity)
        for index in 0..<count {
            insert(index)
        }
    }

    func contains(_ string: borrowing WTF.String) -> Bool {
        if string.is8Bit() {
            return contains(string.span8())
        }
        return contains(string.checkedSpan16())
    }

    func contains<C: ContentSecurityPolicyCharacter>(_ name: Span<C>) -> Bool {
        let characters = self.characters.span
        let ends = self.ends.span
        if ends.count < ContentSecurityPolicyNameSet.hashedNameCount {
            var start = 0
            for index in 0..<ends.count {
                let end = Int(ends[index])
                if cspEqualCodeUnits(name, characters.extracting(start..<end)) {
                    return true
                }
                start = end
            }
            return false
        }
        let hash = ContentSecurityPolicyNameSet.hash(name)
        let hashes = self.hashes.span
        let table = self.table.span
        let mask = table.count - 1
        var slot = Int(hash) & mask
        while table[slot] != 0 {
            let index = Int(table[slot]) - 1
            if hashes[index] == hash && cspEqualCodeUnits(name, characters.extracting(nameRange(index))) {
                return true
            }
            slot = (slot + 1) & mask
        }
        return false
    }

    private func nameRange(_ index: Int) -> Range<Int> {
        let ends = self.ends.span
        return (index == 0 ? 0 : Int(ends[index - 1]))..<Int(ends[index])
    }

    private mutating func insert(_ index: Int) {
        let mask = table.count - 1
        var slot = Int(hashes[index]) & mask
        while table[slot] != 0 {
            slot = (slot + 1) & mask
        }
        table[slot] = UInt32(truncatingIfNeeded: index + 1)
    }

    // FNV-1a over the code units, which wraps by design.
    private static func hash<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for index in 0..<characters.count {
            hash = (hash ^ UInt32(characters[index].cspCodeUnit)) &* 16_777_619
        }
        return hash
    }
}

// The ASCII of `range` of a String's characters, which the caller knows to be ASCII.
func cspASCIIBytes<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>, _ range: Range<Int>) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(range.count)
    for index in range {
        bytes.append(UInt8(truncatingIfNeeded: characters[index].cspCodeUnit))
    }
    return bytes
}
