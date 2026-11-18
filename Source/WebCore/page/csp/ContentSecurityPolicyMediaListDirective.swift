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
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

@inline(always)
private func isMediaTypeCharacter(_ c: UInt16) -> Bool {
    !cspIsASCIIWhitespace(c) && c != 0x2F
}

// plugin-types: a list of MIME types. The types are parsed for their reports only:
// ContentSecurityPolicy::allowPluginType() allows every type.
enum ContentSecurityPolicyMediaListDirective {
    static func parseValue<C: ContentSecurityPolicyCharacter>(
        _ contentSecurityPolicy: ContentSecurityPolicyDirectiveListVector,
        _ value: Span<C>
    ) {
        // 'plugin-types ____;' OR 'plugin-types;'
        if value.isEmpty {
            contentSecurityPolicy.reportInvalidPluginTypes(C.cspMakeString(value))
            return
        }

        parse(contentSecurityPolicy, value)
    }

    private static func skipToWhitespace<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>, _ position: inout Int) {
        while position < characters.count && !cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
            position += 1
        }
    }

    private static func parse<C: ContentSecurityPolicyCharacter>(
        _ contentSecurityPolicy: ContentSecurityPolicyDirectiveListVector,
        _ characters: Span<C>
    ) {
        let end = characters.count
        var position = 0

        while position < end {
            // _____ OR _____mime1/mime1
            // ^        ^
            while position < end && cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
                position += 1
            }
            if position == end {
                return
            }

            // mime1/mime1 mime2/mime2
            // ^
            let begin = position
            if !isMediaTypeCharacter(characters[position].cspCodeUnit) {
                skipToWhitespace(characters, &position)
                contentSecurityPolicy.reportInvalidPluginTypes(C.cspMakeString(characters.extracting(begin..<position)))
                continue
            }
            position += 1
            while position < end && isMediaTypeCharacter(characters[position].cspCodeUnit) {
                position += 1
            }

            // mime1/mime1 mime2/mime2
            //      ^
            if position == end || characters[position].cspCodeUnit != 0x2F {
                skipToWhitespace(characters, &position)
                contentSecurityPolicy.reportInvalidPluginTypes(C.cspMakeString(characters.extracting(begin..<position)))
                continue
            }
            position += 1

            // mime1/mime1 mime2/mime2
            //       ^
            if position == end || !isMediaTypeCharacter(characters[position].cspCodeUnit) {
                skipToWhitespace(characters, &position)
                contentSecurityPolicy.reportInvalidPluginTypes(C.cspMakeString(characters.extracting(begin..<position)))
                continue
            }
            position += 1
            while position < end && isMediaTypeCharacter(characters[position].cspCodeUnit) {
                position += 1
            }

            // mime1/mime1 mime2/mime2 OR mime1/mime1  OR mime1/mime1/error
            //            ^                          ^               ^
            if position < end && !cspIsASCIIWhitespace(characters[position].cspCodeUnit) {
                skipToWhitespace(characters, &position)
                contentSecurityPolicy.reportInvalidPluginTypes(C.cspMakeString(characters.extracting(begin..<position)))
                continue
            }
        }
    }
}
