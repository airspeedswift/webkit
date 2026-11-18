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
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

/// `ParsedContentType::parseContentType()`: the extent of the MIME type, and where the parameters start.
///
/// `contentType` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call;
/// a `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseContentTypeMIMEType8(_ contentType: WebCore.HTTPHeaderLatin1Span) -> WebCore.HTTPHeaderListItem {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(contentType))
    return parseContentTypeMIMETypeBody(characters)
}

/// parseContentTypeMIMEType8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseContentTypeMIMEType16(_ contentType: WebCore.HTTPHeaderUTF16Span) -> WebCore.HTTPHeaderListItem {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: contentType)
    return parseContentTypeMIMETypeBody(characters)
}

/// `ParsedContentType::parseContentType()`: the parameter at `index`, whether it is kept, and where the next starts.
///
/// `contentType` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call;
/// a `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseContentTypeParameter8(_ contentType: WebCore.HTTPHeaderLatin1Span, _ index: UInt32) -> WebCore.HTTPHeaderContentTypeParameter {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(contentType))
    return parseContentTypeParameterBody(characters, index)
}

/// parseContentTypeParameter8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseContentTypeParameter16(_ contentType: WebCore.HTTPHeaderUTF16Span, _ index: UInt32) -> WebCore.HTTPHeaderContentTypeParameter {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: contentType)
    return parseContentTypeParameterBody(characters, index)
}

@inline(always)
private func parseContentTypeMIMETypeBody<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ characters: Span<CodeUnit>
) -> WebCore.HTTPHeaderListItem {
    let head = httpContentTypeHead(characters)
    return WebCore.HTTPHeaderListItem(
        item: httpHeaderExtent(head.mimeType),
        next: UInt32(truncatingIfNeeded: head.parametersStart),
        isValid: head.isValid
    )
}

@inline(never)
private func parseContentTypeParameterBody<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ index: UInt32
) -> WebCore.HTTPHeaderContentTypeParameter {
    let parameter = httpContentTypeParameter(characters, from: Int(index))
    if !parameter.isPresent {
        return WebCore.HTTPHeaderContentTypeParameter(
            name: WTF.String(),
            value: WTF.String(),
            next: UInt32(truncatingIfNeeded: characters.count),
            isAccepted: false
        )
    }
    let content = httpHeaderCharacters(characters, parameter.value)
    let value: WTF.String
    if !parameter.valueHasEscapes && (CodeUnit.bitWidth == 8 || parameter.isValue16Bit) {
        value = CodeUnit.httpHeaderString(content)
    } else if CodeUnit.bitWidth > 8 && parameter.isValue16Bit {
        // An 8-bit argument's values are 8-bit.
        value = contentTypeUnescapedString(content, as: UInt16.self)
    } else {
        value = contentTypeUnescapedString(content, as: UInt8.self)
    }
    return WebCore.HTTPHeaderContentTypeParameter(
        name: CodeUnit.httpHeaderString(httpHeaderCharacters(characters, parameter.name)),
        value: value,
        next: UInt32(truncatingIfNeeded: parameter.next),
        isAccepted: parameter.isAcceptable
    )
}

// A quoted string of at most this many code units, with its escapes, is put together on the stack without them, and a
// longer one in an Array.
private typealias ContentTypeStackBuffer<CodeUnit> = InlineArray<64, CodeUnit>

// The String, in D's width, of a quoted string's characters without the backslashes that escape one.
private func contentTypeUnescapedString<C: FixedWidthInteger & UnsignedInteger, D: HTTPHeaderStringCodeUnit>(
    _ content: Span<C>,
    as _: D.Type
) -> WTF.String {
    if content.count <= ContentTypeStackBuffer<D>.count {
        var buffer = ContentTypeStackBuffer<D>(repeating: 0)
        var output = buffer.mutableSpan
        let count = contentTypeUnescape(content, into: &output)
        return D.httpHeaderString(buffer.span.extracting(0..<count))
    }
    var codeUnits = [D](repeating: 0, count: content.count)
    var output = codeUnits.mutableSpan
    let count = contentTypeUnescape(content, into: &output)
    return D.httpHeaderString(codeUnits.span.extracting(0..<count))
}

// Writes a quoted string's characters without the backslashes that escape one to the start of `output`, and returns
// how many it wrote. A backslash at the end is kept. An 8-bit D is given only code units at most U+00FF.
private func contentTypeUnescape<C: FixedWidthInteger & UnsignedInteger, D: FixedWidthInteger & UnsignedInteger>(
    _ content: Span<C>,
    into output: inout MutableSpan<D>
) -> Int {
    var count = 0
    var index = 0
    while index < content.count {
        if content[index] == 0x5C && index + 1 < content.count { // '\'
            index += 1
        }
        output[count] = D(truncatingIfNeeded: content[index])
        count += 1
        index += 1
    }
    return count
}
