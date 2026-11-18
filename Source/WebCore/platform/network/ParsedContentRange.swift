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
internal import WebCore_Private.Core.ParsedContentRange
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

/// `ParsedContentRange(const String&)`: a `Content-Range` value.
///
/// `headerValue` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call;
/// a `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseContentRange8(_ headerValue: WebCore.HTTPHeaderLatin1Span) -> WebCore.ParsedContentRange {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(headerValue))
    return parseContentRangeBody(characters)
}

/// parseContentRange8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseContentRange16(_ headerValue: WebCore.HTTPHeaderUTF16Span) -> WebCore.ParsedContentRange {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: headerValue)
    return parseContentRangeBody(characters)
}

/// `ParsedContentRange(int64_t, int64_t, int64_t)`: whether the positions and length make a valid range.
@_expose(Cxx)
func areContentRangeValuesValid(_ firstBytePosition: Int64, _ lastBytePosition: Int64, _ instanceLength: Int64) -> Bool {
    httpContentRangeValuesAreValid(firstBytePosition: firstBytePosition, lastBytePosition: lastBytePosition, instanceLength: instanceLength)
}

/// `ParsedContentRange::headerValue()`: the `Content-Range` value, or the null string for an invalid range
/// (`instanceLength` is `ParsedContentRange::invalidLength`).
@_expose(Cxx)
func contentRangeHeaderValue(_ firstBytePosition: Int64, _ lastBytePosition: Int64, _ instanceLength: Int64) -> WTF.String {
    if instanceLength == httpContentRangeInvalidLength {
        return WTF.String()
    }
    var buffer = HTTPContentRangeHeaderValueBuffer(repeating: 0)
    var text = buffer.mutableSpan
    let start = writeHTTPContentRangeHeaderValue(
        &text,
        firstBytePosition: firstBytePosition,
        lastBytePosition: lastBytePosition,
        instanceLength: instanceLength
    )
    return WTF.makeStringFromLatin1Characters(buffer.span.extracting(start...))
}

/// The constructor keeps an invalid range's instance length, `ParsedContentRange::invalidLength`, and the positions
/// parsed before the value failed.
@inline(always)
func parseContentRangeBody<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>
) -> WebCore.ParsedContentRange {
    let range = httpContentRangeValues(characters)
    return WebCore.ParsedContentRange(range.firstBytePosition, range.lastBytePosition, range.instanceLength)
}
