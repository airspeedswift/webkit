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

// A directive of a policy, as its ContentSecurityPolicyDirectiveList holds it: its name, where it is in the policy's
// characters, and the source list of a fetch directive. Its text, "<name> <value>", is its characters from its name on
// when they are already the text, and is made from its name and value otherwise.
struct ContentSecurityPolicyDirective {
    let name: ContentSecurityPolicyDirectiveNames
    let location: ContentSecurityPolicyDirectiveLocation
    let sourceList: ContentSecurityPolicySourceList

    init(
        _ name: ContentSecurityPolicyDirectiveNames,
        _ location: ContentSecurityPolicyDirectiveLocation,
        _ sourceList: ContentSecurityPolicySourceList
    ) {
        self.name = name
        self.location = location
        self.sourceList = sourceList
    }

    // `characters` are the policy's characters the directive was parsed from.
    func text<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>) -> WTF.String {
        if location.textStart != location.textEnd {
            return C.cspMakeSubstring(characters.extracting(Int(location.textStart)..<Int(location.textEnd)))
        }
        return makeDirectiveText(name, characters.extracting(Int(location.valueStart)..<Int(location.valueEnd)))
    }

    func textLength() -> Int {
        if location.textStart != location.textEnd {
            return Int(location.textEnd) - Int(location.textStart)
        }
        return name.spelling.count + 1 + Int(location.valueEnd) - Int(location.valueStart)
    }

    // The text's characters, which are ASCII, appended to `builder`.
    func appendText<C: ContentSecurityPolicyCharacter>(_ characters: Span<C>, _ builder: inout ContentSecurityPolicyStringBuilder) {
        if location.textStart != location.textEnd {
            builder.appendASCII(characters.extracting(Int(location.textStart)..<Int(location.textEnd)))
            return
        }
        builder.append(name.spelling)
        builder.append(" ")
        builder.appendASCII(characters.extracting(Int(location.valueStart)..<Int(location.valueEnd)))
    }
}

// makeString(name, ' ', value). A directive's value has only ASCII whitespace and VCHAR characters.
private func makeDirectiveText<C: ContentSecurityPolicyCharacter>(
    _ name: ContentSecurityPolicyDirectiveNames,
    _ value: Span<C>
) -> WTF.String {
    let spelling = name.spelling
    var text = ContentSecurityPolicyStringBuilder(capacity: spelling.count + 1 + value.count)
    text.append(spelling)
    text.append(" ")
    text.appendASCII(value)
    return text.toString()
}
