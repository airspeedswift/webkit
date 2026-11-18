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
internal import WebCore_Private.Core.HTTPHeaderNames
internal import WebCore_Private.Core.HTTPParsers
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.dtoa
internal import wtf.Core.text.WTFString

/// `isValidReasonPhrase()`: whether a status line's reason phrase is valid.
///
/// `value` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isValidReasonPhrase8(_ value: WebCore.HTTPHeaderLatin1Span) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return HTTPHeaderValueValidation.isValidReasonPhrase(characters)
}

/// isValidReasonPhrase8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isValidReasonPhrase16(_ value: WebCore.HTTPHeaderUTF16Span) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return HTTPHeaderValueValidation.isValidReasonPhrase(characters)
}

/// `isValidHTTPHeaderValue()`: whether a header value is valid.
///
/// `value` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isValidHTTPHeaderValue8(_ value: WebCore.HTTPHeaderLatin1Span) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return HTTPHeaderValueValidation.isValidHTTPHeaderValue(characters)
}

/// isValidHTTPHeaderValue8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isValidHTTPHeaderValue16(_ value: WebCore.HTTPHeaderUTF16Span) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return HTTPHeaderValueValidation.isValidHTTPHeaderValue(characters)
}

/// `isValidAcceptHeaderValue()`: whether an `Accept` value is valid.
///
/// `value` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isValidAcceptHeaderValue8(_ value: WebCore.HTTPHeaderLatin1Span) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return HTTPHeaderValueValidation.isValidAcceptHeaderValue(characters)
}

/// isValidAcceptHeaderValue8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isValidAcceptHeaderValue16(_ value: WebCore.HTTPHeaderUTF16Span) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return HTTPHeaderValueValidation.isValidAcceptHeaderValue(characters)
}

/// `isValidLanguageHeaderValue()`: whether a language header value is CORS-safelisted.
///
/// `value` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isValidLanguageHeaderValue8(_ value: WebCore.HTTPHeaderLatin1Span) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return HTTPHeaderValueValidation.isValidLanguageHeaderValue(characters)
}

/// isValidLanguageHeaderValue8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isValidLanguageHeaderValue16(_ value: WebCore.HTTPHeaderUTF16Span) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return HTTPHeaderValueValidation.isValidLanguageHeaderValue(characters)
}

/// `isValidHTTPToken()`: whether a value is a token.
///
/// `value` is the characters of the caller's `StringView`, whose `String` or buffer the caller keeps allocated and
/// unchanged, at their length, for the call. Nothing this function calls writes them, and every Latin-1 or UTF-16 code
/// unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isValidHTTPToken8(_ value: WebCore.HTTPHeaderLatin1Span) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return HTTPHeaderValueValidation.isValidHTTPToken(characters)
}

/// isValidHTTPToken8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isValidHTTPToken16(_ value: WebCore.HTTPHeaderUTF16Span) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return HTTPHeaderValueValidation.isValidHTTPToken(characters)
}

/// `parseHTTPDate()`: a date in milliseconds since the epoch, or NaN.
///
/// `value` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseHTTPDate8(_ value: WebCore.HTTPHeaderLatin1Span) -> Double {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return parseHTTPDateBody(characters)
}

/// parseHTTPDate8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseHTTPDate16(_ value: WebCore.HTTPHeaderUTF16Span) -> Double {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return parseHTTPDateBody(characters)
}

/// `filenameFromHTTPContentDisposition()`: the extent of the filename, or a null one.
///
/// `value` is the characters of the caller's `StringView`, whose `String` or buffer the caller keeps allocated and
/// unchanged, at their length, for the call. Nothing this function calls writes them, and every Latin-1 or UTF-16 code
/// unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func filenameFromHTTPContentDisposition8(_ value: WebCore.HTTPHeaderLatin1Span) -> WebCore.HTTPHeaderExtent {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return httpHeaderExtent(httpContentDispositionFilenameExtent(characters))
}

/// filenameFromHTTPContentDisposition8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func filenameFromHTTPContentDisposition16(_ value: WebCore.HTTPHeaderUTF16Span) -> WebCore.HTTPHeaderExtent {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return httpHeaderExtent(httpContentDispositionFilenameExtent(characters))
}

/// `extractMIMETypeFromMediaType()`: the extent of the MIME type.
///
/// `mediaType` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func extractMIMETypeFromMediaType8(_ mediaType: WebCore.HTTPHeaderLatin1Span) -> WebCore.HTTPHeaderExtent {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(mediaType))
    return httpHeaderExtent(httpMediaTypeMIMETypeExtent(characters))
}

/// extractMIMETypeFromMediaType8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func extractMIMETypeFromMediaType16(_ mediaType: WebCore.HTTPHeaderUTF16Span) -> WebCore.HTTPHeaderExtent {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: mediaType)
    return httpHeaderExtent(httpMediaTypeMIMETypeExtent(characters))
}

/// `extractCharsetFromMediaType()`: the extent of the charset.
///
/// `mediaType` is the characters of the caller's `StringView`, whose `String` or buffer the caller keeps allocated and
/// unchanged, at their length, for the call. Nothing this function calls writes them, and every Latin-1 or UTF-16 code
/// unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func extractCharsetFromMediaType8(_ mediaType: WebCore.HTTPHeaderLatin1Span) -> WebCore.HTTPHeaderExtent {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(mediaType))
    return httpHeaderExtent(httpMediaTypeCharsetExtent(characters))
}

/// extractCharsetFromMediaType8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func extractCharsetFromMediaType16(_ mediaType: WebCore.HTTPHeaderUTF16Span) -> WebCore.HTTPHeaderExtent {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: mediaType)
    return httpHeaderExtent(httpMediaTypeCharsetExtent(characters))
}

/// `parseContentTypeOptionsHeader()`: an `X-Content-Type-Options` value.
///
/// `header` is the characters of the caller's `StringView`, whose `String` or buffer the caller keeps allocated and
/// unchanged, at their length, for the call. Nothing this function calls writes them, and every Latin-1 or UTF-16 code
/// unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseContentTypeOptionsHeader8(_ header: WebCore.HTTPHeaderLatin1Span) -> WebCore.ContentTypeOptionsDisposition {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(header))
    return parseContentTypeOptionsHeaderBody(characters)
}

/// parseContentTypeOptionsHeader8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseContentTypeOptionsHeader16(_ header: WebCore.HTTPHeaderUTF16Span) -> WebCore.ContentTypeOptionsDisposition {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: header)
    return parseContentTypeOptionsHeaderBody(characters)
}

/// `extractReasonPhraseFromHTTPStatusLine()`: the extent of the reason phrase, or a null one.
///
/// `statusLine` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call;
/// a `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func extractReasonPhraseFromHTTPStatusLine8(_ statusLine: WebCore.HTTPHeaderLatin1Span) -> WebCore.HTTPHeaderExtent {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(statusLine))
    return extractReasonPhraseFromHTTPStatusLineBody(characters)
}

/// extractReasonPhraseFromHTTPStatusLine8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func extractReasonPhraseFromHTTPStatusLine16(_ statusLine: WebCore.HTTPHeaderUTF16Span) -> WebCore.HTTPHeaderExtent {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: statusLine)
    return extractReasonPhraseFromHTTPStatusLineBody(characters)
}

/// `parseXFrameOptionsHeader()`: an `X-Frame-Options` value.
///
/// `header` is the characters of the caller's `StringView`, whose `String` or buffer the caller keeps allocated and
/// unchanged, at their length, for the call. Nothing this function calls writes them, and every Latin-1 or UTF-16 code
/// unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseXFrameOptionsHeader8(_ header: WebCore.HTTPHeaderLatin1Span) -> WebCore.XFrameOptionsDisposition {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(header))
    return HTTPResponseHeaderParsing.parseXFrameOptionsHeader(characters)
}

/// parseXFrameOptionsHeader8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseXFrameOptionsHeader16(_ header: WebCore.HTTPHeaderUTF16Span) -> WebCore.XFrameOptionsDisposition {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: header)
    return HTTPResponseHeaderParsing.parseXFrameOptionsHeader(characters)
}

/// `parseClearSiteDataHeader()`: a `Clear-Site-Data` value, as `ClearSiteDataValue` bits.
///
/// `header` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseClearSiteDataHeader8(_ header: WebCore.HTTPHeaderLatin1Span) -> UInt8 {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(header))
    return HTTPResponseHeaderParsing.parseClearSiteDataHeader(characters)
}

/// parseClearSiteDataHeader8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseClearSiteDataHeader16(_ header: WebCore.HTTPHeaderUTF16Span) -> UInt8 {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: header)
    return HTTPResponseHeaderParsing.parseClearSiteDataHeader(characters)
}

/// `parseRange()`: a `Range` value.
///
/// `range` is the characters of the caller's `StringView`, whose `String` or buffer the caller keeps allocated and
/// unchanged, at their length, for the call. Nothing this function calls writes them, and every Latin-1 or UTF-16 code
/// unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseRange8(_ range: WebCore.HTTPHeaderLatin1Span, _ allowWhitespace: Bool) -> WebCore.HTTPHeaderRangeResult {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(range))
    return parseRangeBody(characters, allowWhitespace)
}

/// parseRange8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseRange16(_ range: WebCore.HTTPHeaderUTF16Span, _ allowWhitespace: Bool) -> WebCore.HTTPHeaderRangeResult {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: range)
    return parseRangeBody(characters, allowWhitespace)
}

/// `parseContentLength()`: a `Content-Length` value.
///
/// `value` is the characters of the caller's `StringView`, whose `String` or buffer the caller keeps allocated and
/// unchanged, at their length, for the call. Nothing this function calls writes them, and every Latin-1 or UTF-16 code
/// unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseContentLength8(_ value: WebCore.HTTPHeaderLatin1Span) -> WebCore.HTTPHeaderOptionalUInt64 {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return parseContentLengthBody(characters)
}

/// parseContentLength8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseContentLength16(_ value: WebCore.HTTPHeaderUTF16Span) -> WebCore.HTTPHeaderOptionalUInt64 {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return parseContentLengthBody(characters)
}

/// `isForbiddenHeaderName()`: whether a request header name is forbidden. `isKnownName` and `headerName` are
/// `findHTTPHeaderName()`'s.
///
/// `name` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isForbiddenHeaderName8(_ name: WebCore.HTTPHeaderLatin1Span, _ isKnownName: Bool, _ headerName: WebCore.HTTPHeaderName) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(name))
    return isForbiddenHeaderNameBody(characters, isKnownName, headerName)
}

/// isForbiddenHeaderName8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isForbiddenHeaderName16(_ name: WebCore.HTTPHeaderUTF16Span, _ isKnownName: Bool, _ headerName: WebCore.HTTPHeaderName) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: name)
    return isForbiddenHeaderNameBody(characters, isKnownName, headerName)
}

/// `isForbiddenHeader()`: whether a request header is forbidden, for the characters of its `name` and of its
/// value.
///
/// `name` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. `value` is the characters of the caller's `StringView`,
/// whose `String` or buffer the caller keeps allocated and unchanged, at their length, for the call. Nothing this
/// function calls writes either, and every Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit name and
/// value characters.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isForbiddenHeader8And8(
    _ name: WebCore.HTTPHeaderLatin1Span,
    _ isKnownName: Bool,
    _ headerName: WebCore.HTTPHeaderName,
    _ value: WebCore.HTTPHeaderLatin1Span
) -> Bool {
    let nameCharacters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(name))
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return isForbiddenHeaderBody(nameCharacters, isKnownName, headerName, characters)
}

/// isForbiddenHeader8And8() for 16-bit value characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isForbiddenHeader8And16(
    _ name: WebCore.HTTPHeaderLatin1Span,
    _ isKnownName: Bool,
    _ headerName: WebCore.HTTPHeaderName,
    _ value: WebCore.HTTPHeaderUTF16Span
) -> Bool {
    let nameCharacters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(name))
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return isForbiddenHeaderBody(nameCharacters, isKnownName, headerName, characters)
}

/// isForbiddenHeader8And8() for 16-bit name characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isForbiddenHeader16And8(
    _ name: WebCore.HTTPHeaderUTF16Span,
    _ isKnownName: Bool,
    _ headerName: WebCore.HTTPHeaderName,
    _ value: WebCore.HTTPHeaderLatin1Span
) -> Bool {
    let nameCharacters = unsafe Span<UInt16>(_unsafeCxxSpan: name)
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return isForbiddenHeaderBody(nameCharacters, isKnownName, headerName, characters)
}

/// isForbiddenHeader8And8() for 16-bit name and value characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isForbiddenHeader16And16(
    _ name: WebCore.HTTPHeaderUTF16Span,
    _ isKnownName: Bool,
    _ headerName: WebCore.HTTPHeaderName,
    _ value: WebCore.HTTPHeaderUTF16Span
) -> Bool {
    let nameCharacters = unsafe Span<UInt16>(_unsafeCxxSpan: name)
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return isForbiddenHeaderBody(nameCharacters, isKnownName, headerName, characters)
}

/// `isNoCORSSafelistedRequestHeaderName()`. `isKnownName` and `headerName` are `findHTTPHeaderName()`'s.
///
/// `name` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isNoCORSSafelistedRequestHeaderName8(
    _ name: WebCore.HTTPHeaderLatin1Span,
    _ isKnownName: Bool,
    _ headerName: WebCore.HTTPHeaderName
) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(name))
    return isNoCORSSafelistedRequestHeaderNameBody(characters, isKnownName, headerName)
}

/// isNoCORSSafelistedRequestHeaderName8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isNoCORSSafelistedRequestHeaderName16(
    _ name: WebCore.HTTPHeaderUTF16Span,
    _ isKnownName: Bool,
    _ headerName: WebCore.HTTPHeaderName
) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: name)
    return isNoCORSSafelistedRequestHeaderNameBody(characters, isKnownName, headerName)
}

/// `isPriviledgedNoCORSRequestHeaderName()`.
///
/// `name` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isPriviledgedNoCORSRequestHeaderName8(_ name: WebCore.HTTPHeaderLatin1Span, _ length: UInt32) -> Bool {
    // Only "range" has 5 characters.
    guard length == 5 else {
        return false
    }
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(name))
    return FetchHeaderChecks.isPriviledgedNoCORSRequestHeaderName(characters)
}

/// isPriviledgedNoCORSRequestHeaderName8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isPriviledgedNoCORSRequestHeaderName16(_ name: WebCore.HTTPHeaderUTF16Span, _ length: UInt32) -> Bool {
    guard length == 5 else {
        return false
    }
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: name)
    return FetchHeaderChecks.isPriviledgedNoCORSRequestHeaderName(characters)
}

/// `isForbiddenResponseHeaderName()`.
///
/// `name` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isForbiddenResponseHeaderName8(_ name: WebCore.HTTPHeaderLatin1Span, _ length: UInt32) -> Bool {
    // Only "set-cookie" and "set-cookie2" have 10 or 11 characters.
    guard length == 10 || length == 11 else {
        return false
    }
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(name))
    return FetchHeaderChecks.isForbiddenResponseHeaderName(characters)
}

/// isForbiddenResponseHeaderName8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isForbiddenResponseHeaderName16(_ name: WebCore.HTTPHeaderUTF16Span, _ length: UInt32) -> Bool {
    guard length == 10 || length == 11 else {
        return false
    }
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: name)
    return FetchHeaderChecks.isForbiddenResponseHeaderName(characters)
}

/// `isForbiddenMethod()`.
///
/// `name` is the characters of the caller's `StringView`, whose `String` or buffer the caller keeps allocated and
/// unchanged, at their length, for the call. Nothing this function calls writes them, and every Latin-1 or UTF-16 code
/// unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isForbiddenMethod8(_ name: WebCore.HTTPHeaderLatin1Span, _ length: UInt32) -> Bool {
    // Only "connect", "trace" and "track" have 5 or 7 characters.
    guard length == 5 || length == 7 else {
        return false
    }
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(name))
    return FetchHeaderChecks.isForbiddenMethod(characters)
}

/// isForbiddenMethod8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isForbiddenMethod16(_ name: WebCore.HTTPHeaderUTF16Span, _ length: UInt32) -> Bool {
    guard length == 5 || length == 7 else {
        return false
    }
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: name)
    return FetchHeaderChecks.isForbiddenMethod(characters)
}

/// `isCrossOriginSafeRequestHeader()`: whether a request header is CORS-safelisted, for its `name` and the characters
/// of its value.
///
/// `value` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isCrossOriginSafeRequestHeader8(_ name: WebCore.HTTPHeaderName, _ value: WebCore.HTTPHeaderLatin1Span) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return isCrossOriginSafeRequestHeaderBody(name, characters)
}

/// isCrossOriginSafeRequestHeader8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isCrossOriginSafeRequestHeader16(_ name: WebCore.HTTPHeaderName, _ value: WebCore.HTTPHeaderUTF16Span) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return isCrossOriginSafeRequestHeaderBody(name, characters)
}

/// `normalizeHTTPMethod()`: the method's normalized name, or the null string to keep the method.
///
/// `method` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func normalizedHTTPMethod8(_ method: WebCore.HTTPHeaderLatin1Span) -> WTF.String {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(method))
    return normalizedHTTPMethodBody(characters)
}

/// normalizedHTTPMethod8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func normalizedHTTPMethod16(_ method: WebCore.HTTPHeaderUTF16Span) -> WTF.String {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: method)
    return normalizedHTTPMethodBody(characters)
}

/// `isSafeMethod()`: whether a method is safe.
///
/// `method` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isSafeMethod8(_ method: WebCore.HTTPHeaderLatin1Span) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(method))
    return FetchHeaderChecks.isSafeMethod(characters)
}

/// isSafeMethod8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isSafeMethod16(_ method: WebCore.HTTPHeaderUTF16Span) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: method)
    return FetchHeaderChecks.isSafeMethod(characters)
}

/// `parseCrossOriginResourcePolicyHeader()`.
///
/// `header` is the characters of the caller's `StringView`, whose `String` or buffer the caller keeps allocated and
/// unchanged, at their length, for the call. Nothing this function calls writes them, and every Latin-1 or UTF-16 code
/// unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseCrossOriginResourcePolicyHeader8(_ header: WebCore.HTTPHeaderLatin1Span) -> WebCore.CrossOriginResourcePolicy {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(header))
    return HTTPResponseHeaderParsing.parseCrossOriginResourcePolicyHeader(characters)
}

/// parseCrossOriginResourcePolicyHeader8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseCrossOriginResourcePolicyHeader16(_ header: WebCore.HTTPHeaderUTF16Span) -> WebCore.CrossOriginResourcePolicy {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: header)
    return HTTPResponseHeaderParsing.parseCrossOriginResourcePolicyHeader(characters)
}

/// `requestHeaderAppendDelimiter()`: 0 for none, or one more than the index of the delimiter.
///
/// `header` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func requestHeaderAppendDelimiterIndex8(_ header: WebCore.HTTPHeaderLatin1Span) -> UInt8 {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(header))
    return requestHeaderAppendDelimiterIndexBody(characters)
}

/// requestHeaderAppendDelimiterIndex8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func requestHeaderAppendDelimiterIndex16(_ header: WebCore.HTTPHeaderUTF16Span) -> UInt8 {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: header)
    return requestHeaderAppendDelimiterIndexBody(characters)
}

/// `isRequestHeaderUnsafeToModify()`, for the characters of the `header` name and of its value.
///
/// `header` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. `value` is the characters of the caller's `StringView`,
/// whose `String` or buffer the caller keeps allocated and unchanged, at their length, for the call. Nothing this
/// function calls writes either, and every Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit name and
/// value characters.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isRequestHeaderUnsafeToModify8And8(_ header: WebCore.HTTPHeaderLatin1Span, _ value: WebCore.HTTPHeaderLatin1Span) -> Bool {
    let headerCharacters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(header))
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return isRequestHeaderUnsafeToModifyBody(headerCharacters, characters)
}

/// isRequestHeaderUnsafeToModify8And8() for 16-bit value characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isRequestHeaderUnsafeToModify8And16(_ header: WebCore.HTTPHeaderLatin1Span, _ value: WebCore.HTTPHeaderUTF16Span) -> Bool {
    let headerCharacters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(header))
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return isRequestHeaderUnsafeToModifyBody(headerCharacters, characters)
}

/// isRequestHeaderUnsafeToModify8And8() for 16-bit name characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isRequestHeaderUnsafeToModify16And8(_ header: WebCore.HTTPHeaderUTF16Span, _ value: WebCore.HTTPHeaderLatin1Span) -> Bool {
    let headerCharacters = unsafe Span<UInt16>(_unsafeCxxSpan: header)
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return isRequestHeaderUnsafeToModifyBody(headerCharacters, characters)
}

/// isRequestHeaderUnsafeToModify8And8() for 16-bit name and value characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isRequestHeaderUnsafeToModify16And16(_ header: WebCore.HTTPHeaderUTF16Span, _ value: WebCore.HTTPHeaderUTF16Span) -> Bool {
    let headerCharacters = unsafe Span<UInt16>(_unsafeCxxSpan: header)
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return isRequestHeaderUnsafeToModifyBody(headerCharacters, characters)
}

/// `parseAccessControlAllowList()`: the token of the list item at `start`, and where the next starts.
///
/// `string` is the characters of the caller's `String`, which keeps them allocated, at their length, for the call; a
/// `StringImpl`'s characters never change after it is created. Nothing this function calls writes them, and every
/// Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func accessControlAllowListToken8(_ string: WebCore.HTTPHeaderLatin1Span, _ start: UInt32) -> WebCore.HTTPHeaderListItem {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(string))
    return accessControlAllowListTokenBody(characters, start)
}

/// accessControlAllowListToken8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func accessControlAllowListToken16(_ string: WebCore.HTTPHeaderUTF16Span, _ start: UInt32) -> WebCore.HTTPHeaderListItem {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: string)
    return accessControlAllowListTokenBody(characters, start)
}

/// `isCrossOriginSafeHeader()`: whether a response header is CORS-safelisted, unsafe, or safe only when exposed.
@_expose(Cxx)
func crossOriginHeaderSafety(_ name: WebCore.HTTPHeaderName) -> WebCore.HTTPHeaderCrossOriginSafety {
    switch FetchHeaderChecks.crossOriginSafeHeaderNameDecision(name) {
    case .safe:
        .Safe
    case .notSafe:
        .Unsafe
    case .safeIfExposed:
        .Exposed
    }
}

/// `parseHTTPHeader()`: one header line of `data`, its length, the extents of its name and value in `data`, or why it
/// fails.
///
/// `data` is the caller's byte span, whose buffer the caller holds unchanged for the call. Nothing this function calls
/// writes it, and every byte is a valid value.
///
/// FIXME: Take the bytes as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseHTTPHeaderLine(_ data: WebCore.HTTPHeaderByteSpan, _ strict: Bool) -> WebCore.HTTPHeaderLineResult {
    let bytes = unsafe Span<UInt8>(_unsafeCxxSpan: data)
    return parseHTTPHeaderLineBody(bytes, strict)
}

@inline(never)
private func parseHTTPHeaderLineBody(_ bytes: Span<UInt8>, _ strict: Bool) -> WebCore.HTTPHeaderLineResult {
    let line = httpHeaderLine(bytes, strict: strict)
    return WebCore.HTTPHeaderLineResult(
        failureReason: httpHeaderLineFailureReason(line, bytes),
        length: line.consumed,
        field: WebCore.HTTPHeaderFieldExtents(name: httpHeaderExtent(line.name), value: httpHeaderExtent(line.value))
    )
}

/// parseHTTPHeader()'s failure message: its text, then the input from where it fails, cut at 128 bytes and an ellipsis.
private func httpHeaderLineFailureReason(_ line: HTTPHeaderLine, _ bytes: Span<UInt8>) -> WTF.String {
    let message: Swift.String
    switch line.failure {
    case .none:
        return WTF.String()
    case .crDoesNotFollowLFInName:
        message = "CR doesn't follow LF in header name at "
    case .unexpectedCRInName:
        message = "Unexpected CR in header name at "
    case .unexpectedLFInName:
        message = "Unexpected LF in header name at "
    case .unexpectedStartCharacterInName:
        message = "Unexpected start character in header name"
    case .unexpectedCharacterInName:
        message = "Unexpected character in header name at "
    case .unexpectedLFInValue:
        message = "Unexpected LF in header value at "
    case .crDoesNotFollowLFAfterValue:
        message = "CR doesn't follow LF after header value at "
    case .invalidUTF8InValue:
        message = "Invalid UTF-8 sequence in header value"
    }
    let maxInputSampleSize = 128
    let sample = bytes.extracting(line.sample.start..<line.sample.end)
    if sample.count <= maxInputSampleSize {
        var buffer = HTTPHeaderLineFailureReasonBuffer(repeating: 0)
        var text = buffer.mutableSpan
        var count = 0
        for letter in message.utf8 {
            text[count] = letter
            count += 1
        }
        for index in sample.indices {
            text[count] = sample[index]
            count += 1
        }
        return WTF.makeStringFromLatin1Characters(buffer.span.extracting(0..<count))
    }
    // The ellipsis, U+2026, makes the message 16-bit.
    var buffer = HTTPHeaderLineFailureReasonWithEllipsisBuffer(repeating: 0)
    var text = buffer.mutableSpan
    var count = 0
    for letter in message.utf8 {
        text[count] = UInt16(letter)
        count += 1
    }
    for index in 0..<maxInputSampleSize {
        text[count] = UInt16(sample[index])
        count += 1
    }
    text[count] = 0x2026
    count += 1
    return WTF.makeStringFromUTF16Characters(buffer.span.extracting(0..<count))
}

// A failure message is put together in one of these: the longest text followed by the input, "CR doesn't follow LF
// after header value at ", has 43 characters, then up to 128 bytes of the input, and the ellipsis when it is cut.
private typealias HTTPHeaderLineFailureReasonBuffer = InlineArray<171, UInt8>
private typealias HTTPHeaderLineFailureReasonWithEllipsisBuffer = InlineArray<172, UInt16>

@inline(always)
func parseHTTPDateBody<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ characters: Span<CodeUnit>) -> Double {
    // FIXME: parseDate() requires Latin1, but we're passing it UTF-8.
    if characters.count <= HTTPDateStackBuffer.count / 3 {
        var buffer = HTTPDateStackBuffer(repeating: 0)
        var output = buffer.mutableSpan
        let count = httpDateUTF8Bytes(characters, into: &output)
        return parseHTTPDateBytes(buffer.span.extracting(0..<count))
    }
    // A String has fewer than 2^32 code units, so this cannot overflow.
    var bytes = [UInt8](repeating: 0, count: characters.count &* 3)
    var output = bytes.mutableSpan
    let count = httpDateUTF8Bytes(characters, into: &output)
    return parseHTTPDateBytes(bytes.span.extracting(0..<count))
}

// UTF-8 takes at most three bytes for each code unit, so the UTF-8 of a date of up to 42 code units is put together
// on the stack, and a longer one's in an Array.
private typealias HTTPDateStackBuffer = InlineArray<126, UInt8>

/// `WTF::parseDate()`'s one-argument form, which subtracts the local time offset from a date in local time. A date
/// that does not parse is NaN, with or without the offset, so the offset is computed only for one that does.
@inline(always)
private func parseHTTPDateBytes(_ bytes: Span<UInt8>) -> Double {
    var isLocalTime = false
    let milliseconds = WTF.parseDate(bytes, &isLocalTime)
    guard isLocalTime && milliseconds.isFinite else {
        return milliseconds
    }
    return milliseconds - Double(WTF.calculateLocalTimeOffset(milliseconds, .LocalTime).offset)
}

@inline(never)
private func parseContentTypeOptionsHeaderBody<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>
) -> WebCore.ContentTypeOptionsDisposition {
    HTTPResponseHeaderParsing.parseContentTypeOptionsHeader(characters)
}

@inline(always)
private func extractReasonPhraseFromHTTPStatusLineBody<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>
) -> WebCore.HTTPHeaderExtent {
    guard let start = HTTPResponseHeaderParsing.reasonPhraseStartInHTTPStatusLine(characters) else {
        return WebCore.HTTPHeaderExtent(start: 0, length: 0, isNull: true)
    }
    // start is at most the count.
    return httpHeaderExtent(HTTPHeaderSubstringExtent(start: start, length: characters.count &- start))
}

@inline(always)
private func parseRangeBody<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ allowWhitespace: Bool
) -> WebCore.HTTPHeaderRangeResult {
    let range = httpRangeValue(characters, allowWhitespace: allowWhitespace)
    return WebCore.HTTPHeaderRangeResult(
        start: range.start ?? 0,
        end: range.end ?? 0,
        isValid: range.isValid,
        hasStart: range.start != nil,
        hasEnd: range.end != nil
    )
}

@inline(always)
private func parseContentLengthBody<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>
) -> WebCore.HTTPHeaderOptionalUInt64 {
    guard let length = httpContentLengthValue(characters) else {
        return WebCore.HTTPHeaderOptionalUInt64(value: 0, hasValue: false)
    }
    return WebCore.HTTPHeaderOptionalUInt64(value: length, hasValue: true)
}

@inline(never)
private func isForbiddenHeaderNameBody<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ isKnownName: Bool,
    _ headerName: WebCore.HTTPHeaderName
) -> Bool {
    FetchHeaderChecks.isForbiddenHeaderName(isKnown: isKnownName, headerName: headerName, characters)
}

@inline(never)
private func isForbiddenHeaderBody<NameCodeUnit: FixedWidthInteger & UnsignedInteger, ValueCodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ name: Span<NameCodeUnit>,
    _ isKnownName: Bool,
    _ headerName: WebCore.HTTPHeaderName,
    _ characters: Span<ValueCodeUnit>
) -> Bool {
    FetchHeaderChecks.isForbiddenHeader(isKnown: isKnownName, headerName: headerName, name, characters)
}

@inline(never)
private func isNoCORSSafelistedRequestHeaderNameBody<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ isKnownName: Bool,
    _ headerName: WebCore.HTTPHeaderName
) -> Bool {
    FetchHeaderChecks.isNoCORSSafelistedRequestHeaderName(isKnown: isKnownName, headerName: headerName)
}

/// `isCrossOriginSafeRequestHeader()` (https://fetch.spec.whatwg.org/#cors-safelisted-request-header). Its limit
/// counts code units.
@inline(never)
func isCrossOriginSafeRequestHeaderBody<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ name: WebCore.HTTPHeaderName,
    _ characters: Span<CodeUnit>
) -> Bool {
    if characters.count > 128 {
        return false
    }
    switch name {
    case .Accept:
        return HTTPHeaderValueValidation.isValidAcceptHeaderValue(characters)
    case .AcceptLanguage, .ContentLanguage:
        return HTTPHeaderValueValidation.isValidLanguageHeaderValue(characters)
    case .ContentType:
        // Preflight is required for MIME types that can not be sent via form submission.
        if HTTPHeaderValueValidation.containsCORSUnsafeRequestHeaderBytes(characters) {
            return false
        }
        // ParsedContentType::create(), which parses the value trimmed of ASCII whitespace without form feed.
        let contentType = characters.extracting(
            HTTPHeaderCodeUnits.trim(characters, characters.indices, HTTPHeaderCodeUnits.isASCIIWhitespaceWithoutFF)
        )
        let head = httpContentTypeHead(contentType)
        if !head.isValid {
            return false
        }
        let mimeType = httpHeaderCharacters(contentType, head.mimeType)
        return HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(mimeType, httpHeaderFormURLEncoded.span)
            || HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(mimeType, httpHeaderMultipartFormData.span)
            || HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(mimeType, httpHeaderTextPlain.span)
    case .Range:
        let range = httpRangeValue(characters, allowWhitespace: false)
        return range.isValid && range.start != nil
    default:
        return false
    }
}

/// "application/x-www-form-urlencoded"
private let httpHeaderFormURLEncoded: [UInt8] = Array("application/x-www-form-urlencoded".utf8)
/// "multipart/form-data"
private let httpHeaderMultipartFormData: [UInt8] = Array("multipart/form-data".utf8)
/// "text/plain"
private let httpHeaderTextPlain: [UInt8] = Array("text/plain".utf8)

@inline(always)
private func normalizedHTTPMethodBody<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ characters: Span<CodeUnit>) -> WTF.String {
    guard let name = FetchHeaderChecks.normalizeHTTPMethod(characters) else {
        return WTF.String()
    }
    return WTF.makeStringFromLatin1Characters(name.span)
}

@inline(always)
private func requestHeaderAppendDelimiterIndexBody<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ characters: Span<CodeUnit>) -> UInt8 {
    guard let delimiter = FetchHeaderChecks.requestHeaderAppendDelimiter(characters) else {
        return 0
    }
    // The raw value is at most 3.
    return delimiter.rawValue &+ 1
}

@inline(never)
private func isRequestHeaderUnsafeToModifyBody<
    NameCodeUnit: FixedWidthInteger & UnsignedInteger,
    ValueCodeUnit: FixedWidthInteger & UnsignedInteger
>(
    _ header: Span<NameCodeUnit>,
    _ characters: Span<ValueCodeUnit>
) -> Bool {
    FetchHeaderChecks.isRequestHeaderUnsafeToModify(header, characters)
}

@inline(always)
private func accessControlAllowListTokenBody<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ start: UInt32
) -> WebCore.HTTPHeaderListItem {
    let null = WebCore.HTTPHeaderExtent(start: 0, length: 0, isNull: true)
    switch AccessControlAllowListParsing.nextToken(characters, from: Int(start)) {
    case .token(let start, let length, let next):
        return WebCore.HTTPHeaderListItem(
            item: httpHeaderExtent(HTTPHeaderSubstringExtent(start: start, length: length)),
            next: UInt32(truncatingIfNeeded: next),
            isValid: true
        )
    case .end:
        return WebCore.HTTPHeaderListItem(item: null, next: UInt32(truncatingIfNeeded: characters.count), isValid: true)
    case .invalid:
        return WebCore.HTTPHeaderListItem(item: null, next: UInt32(truncatingIfNeeded: characters.count), isValid: false)
    }
}

// MARK: Values returned to C++

/// The HTTPHeaderExtent of an extent, or of none.
func httpHeaderExtent(_ extent: HTTPHeaderSubstringExtent?) -> WebCore.HTTPHeaderExtent {
    guard let extent else {
        return WebCore.HTTPHeaderExtent(start: 0, length: 0, isNull: true)
    }
    // An extent lies within a String, whose length is a 32-bit unsigned.
    return WebCore.HTTPHeaderExtent(
        start: UInt32(truncatingIfNeeded: extent.start),
        length: UInt32(truncatingIfNeeded: extent.length),
        isNull: false
    )
}

/// The characters of an extent; one that starts at or past the end has none.
func httpHeaderCharacters<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ extent: HTTPHeaderSubstringExtent
) -> Span<CodeUnit> {
    if extent.start >= characters.count {
        return characters.extracting(characters.count..<characters.count)
    }
    return characters.extracting(extent.start..<extent.end)
}

/// A Latin-1 (`UInt8`) or UTF-16 (`UInt16`) code unit, whose span's bytes can be read, and the `String` of a run of them in
/// that width.
protocol HTTPHeaderStringCodeUnit: FixedWidthInteger & UnsignedInteger & ConvertibleToBytes {
    /// The `String` of `characters`, which is the empty string, not the null one, when there are none.
    static func httpHeaderString(_ characters: Span<Self>) -> WTF.String
    /// Stores httpHeaderString() of `characters` in `destination`.
    static func httpHeaderAssignString(_ destination: inout WTF.String, _ characters: Span<Self>)
    /// `WTF::parseDouble()` of `characters`, which are not empty.
    static func httpHeaderParseDouble(_ characters: Span<Self>, _ parsedLength: inout Int) -> Double
}

extension UInt8: HTTPHeaderStringCodeUnit {
    static func httpHeaderString(_ characters: Span<UInt8>) -> WTF.String {
        WTF.makeStringFromLatin1Characters(characters)
    }

    static func httpHeaderAssignString(_ destination: inout WTF.String, _ characters: Span<UInt8>) {
        WTF.assignStringFromLatin1Characters(&destination, characters)
    }

    static func httpHeaderParseDouble(_ characters: Span<UInt8>, _ parsedLength: inout Int) -> Double {
        WTF.parseDoubleFromLatin1(characters, &parsedLength)
    }
}

extension UInt16: HTTPHeaderStringCodeUnit {
    static func httpHeaderString(_ characters: Span<UInt16>) -> WTF.String {
        WTF.makeStringFromUTF16Characters(characters)
    }

    static func httpHeaderAssignString(_ destination: inout WTF.String, _ characters: Span<UInt16>) {
        WTF.assignStringFromUTF16Characters(&destination, characters)
    }

    static func httpHeaderParseDouble(_ characters: Span<UInt16>, _ parsedLength: inout Int) -> Double {
        WTF.parseDoubleFromUTF16(characters, &parsedLength)
    }
}

/// `toDouble()` of the `String` of `characters`: after leading Unicode-compatible ASCII whitespace, the number
/// `WTF::parseDouble()` reads, and whether it reads every remaining character. Nil when it reads none.
func httpHeaderToDouble<CodeUnit: HTTPHeaderStringCodeUnit>(_ characters: Span<CodeUnit>) -> (value: Double, isWhole: Bool)? {
    var start = 0
    while start < characters.count && HTTPHeaderCodeUnits.isUnicodeCompatibleASCIIWhitespace(HTTPHeaderCodeUnits.value(characters[start])) {
        start += 1
    }
    // An empty span may have no base, and parseDouble() reads nothing of it.
    if start == characters.count {
        return nil
    }
    var parsedLength = 0
    let value = CodeUnit.httpHeaderParseDouble(characters.extracting(start...), &parsedLength)
    if parsedLength == 0 {
        return nil
    }
    // parsedLength is at most the count after start.
    return (value, start &+ parsedLength == characters.count)
}

// MARK: Parsers

/// The character classes and comparisons the HTTP header parsers use, over the code units of a
/// header value: `UInt8` for a Latin-1 string, `UInt16` for a UTF-16 one. A code unit is compared as
/// its value, as WTF compares a `char16_t`.
enum HTTPHeaderCodeUnits {
    @inline(always)
    static func value<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ codeUnit: CodeUnit) -> UInt32 {
        UInt32(truncatingIfNeeded: codeUnit)
    }

    // MARK: WTF's ASCII classes

    @inline(always)
    static func isTabOrSpace(_ c: UInt32) -> Bool {
        c == 0x20 || c == 0x09
    }

    /// Space, line feed, tab and carriage return.
    @inline(always)
    static func isASCIIWhitespaceWithoutFF(_ c: UInt32) -> Bool {
        c == 0x20 || c == 0x0A || c == 0x09 || c == 0x0D
    }

    /// Space, tab, line feed, vertical tab, form feed and carriage return.
    @inline(always)
    static func isUnicodeCompatibleASCIIWhitespace(_ c: UInt32) -> Bool {
        c == 0x20 || (c >= 0x09 && c <= 0x0D)
    }

    @inline(always)
    static func isASCIIDigit(_ c: UInt32) -> Bool {
        c >= 0x30 && c <= 0x39
    }

    @inline(always)
    static func isASCIIAlpha(_ c: UInt32) -> Bool {
        (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A
    }

    @inline(always)
    static func isASCIIAlphanumeric(_ c: UInt32) -> Bool {
        isASCIIDigit(c) || isASCIIAlpha(c)
    }

    @inline(always)
    static func toASCIILower(_ c: UInt32) -> UInt32 {
        c >= 0x41 && c <= 0x5A ? c | 0x20 : c
    }

    // MARK: RFC 7230's classes

    /// `tchar`: letters, digits and ``!#$%&'*+-.^_`|~``.
    @inline(always)
    static func isTokenCharacter(_ c: UInt32) -> Bool {
        switch c {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
            true
        case 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E:
            true
        default:
            false
        }
    }

    /// `(),/:;<=>?@[\]{}"`.
    @inline(always)
    static func isDelimiter(_ c: UInt32) -> Bool {
        switch c {
        case 0x28, 0x29, 0x2C, 0x2F, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x5B, 0x5C, 0x5D, 0x7B, 0x7D, 0x22:
            true
        default:
            false
        }
    }

    /// A token character or a delimiter, which together are 0x21 to 0x7E.
    @inline(always)
    static func isVisibleCharacter(_ c: UInt32) -> Bool {
        isTokenCharacter(c) || isDelimiter(c)
    }

    @inline(always)
    static func isOBSText(_ c: UInt32) -> Bool {
        c >= 0x80 && c <= 0xFF
    }

    @inline(always)
    static func isQuotedTextCharacter(_ c: UInt32) -> Bool {
        isTabOrSpace(c) || c == 0x21 || (c >= 0x23 && c <= 0x5B) || (c >= 0x5D && c <= 0x7E) || isOBSText(c)
    }

    @inline(always)
    static func isQuotedPairSecondOctet(_ c: UInt32) -> Bool {
        isTabOrSpace(c) || isVisibleCharacter(c) || isOBSText(c)
    }

    @inline(always)
    static func isCommentText(_ c: UInt32) -> Bool {
        isTabOrSpace(c) || (c >= 0x21 && c <= 0x27) || (c >= 0x2A && c <= 0x5B) || (c >= 0x5D && c <= 0x7E) || isOBSText(c)
    }

    // MARK: Searching and trimming

    /// The index of the first code unit equal to `codeUnit` at or after `start`, or `characters.count` if there is none.
    @inline(always)
    static func find<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ codeUnit: UInt32,
        in characters: Span<CodeUnit>,
        from start: Int
    ) -> Int {
        var index = start
        while index < characters.count {
            if value(characters[index]) == codeUnit {
                return index
            }
            index += 1
        }
        return characters.count
    }

    /// `range` without its leading and trailing code units that `isTrimmed` accepts, as `StringView::trim` gives it.
    @inline(always)
    static func trim<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ characters: Span<CodeUnit>,
        _ range: Range<Int>,
        _ isTrimmed: (UInt32) -> Bool
    ) -> Range<Int> {
        var start = range.lowerBound
        var end = range.upperBound
        while start < end {
            if !isTrimmed(value(characters[start])) {
                break
            }
            start += 1
        }
        while end > start {
            if !isTrimmed(value(characters[end - 1])) {
                break
            }
            end -= 1
        }
        return start..<end
    }

    // MARK: Comparing with literals

    /// `equalLettersIgnoringASCIICase`: each code unit, with bit 0x20 set, equals the literal's code unit. The
    /// literal is lowercase, so letters match in either case; a `-` also matches a carriage return and a digit
    /// matches the control character 0x20 below it, as in WTF.
    @inline(always)
    static func equalLettersIgnoringASCIICase<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ characters: Span<CodeUnit>,
        _ lowercaseLetters: Span<UInt8>
    ) -> Bool {
        characters.count == lowercaseLetters.count && hasPrefixWithLettersIgnoringASCIICase(characters, lowercaseLetters)
    }

    /// `startsWithLettersIgnoringASCIICase`, with `equalLettersIgnoringASCIICase`'s comparison.
    @inline(always)
    static func startsWithLettersIgnoringASCIICase<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ characters: Span<CodeUnit>,
        _ lowercaseLetters: Span<UInt8>
    ) -> Bool {
        characters.count >= lowercaseLetters.count && hasPrefixWithLettersIgnoringASCIICase(characters, lowercaseLetters)
    }

    @inline(always)
    private static func hasPrefixWithLettersIgnoringASCIICase<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ characters: Span<CodeUnit>,
        _ lowercaseLetters: Span<UInt8>
    ) -> Bool {
        for index in lowercaseLetters.indices {
            if value(characters[index]) | 0x20 != UInt32(lowercaseLetters[index]) {
                return false
            }
        }
        return true
    }

    /// `equalIgnoringASCIICase`: equal after lowering the ASCII upper-case letters of both.
    @inline(always)
    static func equalIgnoringASCIICase<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ characters: Span<CodeUnit>,
        _ literal: Span<UInt8>
    ) -> Bool {
        guard characters.count == literal.count else {
            return false
        }
        for index in literal.indices {
            if toASCIILower(value(characters[index])) != toASCIILower(UInt32(literal[index])) {
                return false
            }
        }
        return true
    }

    /// Equal code unit for code unit, as a `StringView` compares with an `ASCIILiteral`.
    @inline(always)
    static func equal<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ characters: Span<CodeUnit>, _ literal: Span<UInt8>) -> Bool {
        guard characters.count == literal.count else {
            return false
        }
        for index in literal.indices {
            if value(characters[index]) != UInt32(literal[index]) {
                return false
            }
        }
        return true
    }
}

// MARK: Searching 16 code units at a time

/// A class of ASCII characters that `HTTPHeaderCodeUnits.firstIndex` searches for 16 code units at a time.
protocol HTTPHeaderCharacterClass {
    static func contains(_ c: UInt32) -> Bool
    /// The highest bit of each lane set where the lane is in the class. The other bits are not defined.
    static func lanes(in codeUnits: SIMD16<UInt8>) -> SIMD16<UInt8>
}

/// Tests of 16 lanes, each marking the lanes it accepts with their highest bit.
enum HTTPHeaderLanes {
    /// The lanes from `lowest` to `lowest + count - 1`, for a count of at most 0x80. Only their offsets from `lowest`
    /// are below both the count and 0x80, so only they borrow into the highest bit when the count is subtracted, which
    /// wraps on purpose.
    @inline(always)
    static func inRange(_ lanes: SIMD16<UInt8>, _ lowest: UInt8, _ count: UInt8) -> SIMD16<UInt8> {
        let offset = lanes &- lowest
        return (offset &- count) & ~offset
    }

    @inline(always)
    static func equal(_ lanes: SIMD16<UInt8>, _ c: UInt8) -> SIMD16<UInt8> {
        inRange(lanes, c, 1)
    }

    @inline(always)
    static func delimiters(_ lanes: SIMD16<UInt8>) -> SIMD16<UInt8> {
        var marks = equal(lanes, 0x22)
        marks |= inRange(lanes, 0x28, 2)
        marks |= equal(lanes, 0x2C)
        marks |= equal(lanes, 0x2F)
        marks |= inRange(lanes, 0x3A, 7)
        marks |= inRange(lanes, 0x5B, 3)
        marks |= equal(lanes, 0x7B)
        marks |= equal(lanes, 0x7D)
        return marks
    }
}

/// `HTTPHeaderCodeUnits.isTokenCharacter()`: the visible characters, 0x21 to 0x7E, that are not delimiters.
enum HTTPHeaderTokenCharacters: HTTPHeaderCharacterClass {
    @inline(always)
    static func contains(_ c: UInt32) -> Bool {
        HTTPHeaderCodeUnits.isTokenCharacter(c)
    }

    @inline(always)
    static func lanes(in codeUnits: SIMD16<UInt8>) -> SIMD16<UInt8> {
        HTTPHeaderLanes.inRange(codeUnits, 0x21, 0x5E) & ~HTTPHeaderLanes.delimiters(codeUnits)
    }
}

/// Line feed and carriage return.
enum HTTPHeaderLineBreaks: HTTPHeaderCharacterClass {
    @inline(always)
    static func contains(_ c: UInt32) -> Bool {
        c == 0x0A || c == 0x0D
    }

    @inline(always)
    static func lanes(in codeUnits: SIMD16<UInt8>) -> SIMD16<UInt8> {
        HTTPHeaderLanes.equal(codeUnits, 0x0A) | HTTPHeaderLanes.equal(codeUnits, 0x0D)
    }
}

/// NUL, line feed and carriage return, which a header value may not hold.
enum HTTPHeaderNULAndLineBreaks: HTTPHeaderCharacterClass {
    @inline(always)
    static func contains(_ c: UInt32) -> Bool {
        c == 0x00 || c == 0x0A || c == 0x0D
    }

    @inline(always)
    static func lanes(in codeUnits: SIMD16<UInt8>) -> SIMD16<UInt8> {
        HTTPHeaderLanes.equal(codeUnits, 0x00) | HTTPHeaderLanes.equal(codeUnits, 0x0A) | HTTPHeaderLanes.equal(codeUnits, 0x0D)
    }
}

extension HTTPHeaderCodeUnits {
    // Fewer than 16 code units are searched inline, one at a time; 16 or more by an out-of-line firstBlockIndex()
    // function, as a tail call.

    /// The index of the first code unit from `start` to `end` that is in `Class`, or `end` when there is none. `end` is
    /// at most the count, and a `start` at or past it is returned as it is.
    @inline(always)
    static func firstIndex<CodeUnit: HTTPHeaderStringCodeUnit, Class: HTTPHeaderCharacterClass>(
        of _: Class.Type,
        in characters: Span<CodeUnit>,
        from start: Int,
        to end: Int
    ) -> Int {
        if end - start >= 16 {
            return firstBlockIndex(of: Class.self, characters, start, end)
        }
        return firstIndex(Class.self, characters, start, end, inClass: true)
    }

    /// firstIndex(of:in:from:to:) for the first code unit that is not in `Class`.
    @inline(always)
    static func firstIndex<CodeUnit: HTTPHeaderStringCodeUnit, Class: HTTPHeaderCharacterClass>(
        notOf _: Class.Type,
        in characters: Span<CodeUnit>,
        from start: Int,
        to end: Int
    ) -> Int {
        if end - start >= 16 {
            return firstBlockIndex(notOf: Class.self, characters, start, end)
        }
        return firstIndex(Class.self, characters, start, end, inClass: false)
    }

    /// Whether every code unit from `start` to `end` is in `Class`.
    @inline(always)
    static func containsOnly<CodeUnit: HTTPHeaderStringCodeUnit, Class: HTTPHeaderCharacterClass>(
        _: Class.Type,
        in characters: Span<CodeUnit>,
        from start: Int,
        to end: Int
    ) -> Bool {
        // Indices are at most a String's length, below 2^32, so wrapping arithmetic cannot wrap.
        if end &- start >= 16 {
            return firstBlockIndexIsEnd(notOf: Class.self, characters, start, end)
        }
        return !contains(Class.self, characters, start, end, inClass: false)
    }

    /// Whether no code unit from `start` to `end` is in `Class`.
    @inline(always)
    static func containsNone<CodeUnit: HTTPHeaderStringCodeUnit, Class: HTTPHeaderCharacterClass>(
        of _: Class.Type,
        in characters: Span<CodeUnit>,
        from start: Int,
        to end: Int
    ) -> Bool {
        if end - start >= 16 {
            return firstBlockIndexIsEnd(of: Class.self, characters, start, end)
        }
        return !contains(Class.self, characters, start, end, inClass: true)
    }

    /// The extent from `start` to the first code unit before `end` that is in `Class`, or to `end`. `start` is at most
    /// `end`.
    @inline(always)
    static func extent<CodeUnit: HTTPHeaderStringCodeUnit, Class: HTTPHeaderCharacterClass>(
        upToFirstOf _: Class.Type,
        in characters: Span<CodeUnit>,
        from start: Int,
        to end: Int
    ) -> HTTPHeaderSubstringExtent {
        // Indices are at most a String's length, below 2^32, so wrapping arithmetic cannot wrap.
        if end &- start >= 16 {
            return firstBlockExtent(of: Class.self, characters, start, end)
        }
        return HTTPHeaderSubstringExtent(start: start, length: firstIndex(Class.self, characters, start, end, inClass: true) &- start)
    }

    // One code unit at a time.
    @inline(always)
    private static func firstIndex<CodeUnit: HTTPHeaderStringCodeUnit, Class: HTTPHeaderCharacterClass>(
        _: Class.Type,
        _ characters: Span<CodeUnit>,
        _ start: Int,
        _ end: Int,
        inClass: Bool
    ) -> Int {
        var index = start
        while index < end {
            if Class.contains(value(characters[index])) == inClass {
                return index
            }
            index += 1
        }
        return index
    }

    // Whether a code unit from `start` to `end` is in `Class`, or with `inClass` false is not, one at a time.
    @inline(always)
    private static func contains<CodeUnit: HTTPHeaderStringCodeUnit, Class: HTTPHeaderCharacterClass>(
        _: Class.Type,
        _ characters: Span<CodeUnit>,
        _ start: Int,
        _ end: Int,
        inClass: Bool
    ) -> Bool {
        var index = start
        while index < end {
            if Class.contains(value(characters[index])) == inClass {
                return true
            }
            index += 1
        }
        return false
    }

    @inline(never)
    private static func firstBlockIndex<CodeUnit: HTTPHeaderStringCodeUnit, Class: HTTPHeaderCharacterClass>(
        of _: Class.Type,
        _ characters: Span<CodeUnit>,
        _ start: Int,
        _ end: Int
    ) -> Int {
        firstBlockIndex(Class.self, characters, start, end, inClass: true)
    }

    @inline(never)
    private static func firstBlockIndex<CodeUnit: HTTPHeaderStringCodeUnit, Class: HTTPHeaderCharacterClass>(
        notOf _: Class.Type,
        _ characters: Span<CodeUnit>,
        _ start: Int,
        _ end: Int
    ) -> Int {
        firstBlockIndex(Class.self, characters, start, end, inClass: false)
    }

    @inline(never)
    private static func firstBlockIndexIsEnd<CodeUnit: HTTPHeaderStringCodeUnit, Class: HTTPHeaderCharacterClass>(
        of _: Class.Type,
        _ characters: Span<CodeUnit>,
        _ start: Int,
        _ end: Int
    ) -> Bool {
        firstBlockIndex(Class.self, characters, start, end, inClass: true) == end
    }

    @inline(never)
    private static func firstBlockIndexIsEnd<CodeUnit: HTTPHeaderStringCodeUnit, Class: HTTPHeaderCharacterClass>(
        notOf _: Class.Type,
        _ characters: Span<CodeUnit>,
        _ start: Int,
        _ end: Int
    ) -> Bool {
        firstBlockIndex(Class.self, characters, start, end, inClass: false) == end
    }

    @inline(never)
    private static func firstBlockExtent<CodeUnit: HTTPHeaderStringCodeUnit, Class: HTTPHeaderCharacterClass>(
        of _: Class.Type,
        _ characters: Span<CodeUnit>,
        _ start: Int,
        _ end: Int
    ) -> HTTPHeaderSubstringExtent {
        // The index is at least `start`.
        HTTPHeaderSubstringExtent(start: start, length: firstBlockIndex(Class.self, characters, start, end, inClass: true) &- start)
    }

    // From 16 code units or more before `end`: 16 at a time while 16 are left in the span, even past `end`, then one
    // at a time.
    @inline(always)
    private static func firstBlockIndex<CodeUnit: HTTPHeaderStringCodeUnit, Class: HTTPHeaderCharacterClass>(
        _: Class.Type,
        _ characters: Span<CodeUnit>,
        _ start: Int,
        _ end: Int,
        inClass: Bool
    ) -> Int {
        let bytes = characters.bytes
        var index = start
        // Indices are at most a String's length, below 2^32, so wrapping arithmetic cannot wrap.
        while index &+ 16 <= characters.count {
            let marks = laneMarks(Class.self, bytes, index, inClass: inClass, CodeUnit.self)
            if marks != 0 {
                // A lane past `end` means that none before `end` matches.
                return min(index &+ (marks.trailingZeroBitCount &>> 2), end)
            }
            index &+= 16
            if index >= end {
                return end
            }
        }
        while index < end {
            if Class.contains(value(characters[index])) == inClass {
                return index
            }
            index += 1
        }
        return end
    }

    /// 4 bits for each of the 16 code units at `index`, set when the code unit is in `Class`, or with `inClass` false
    /// when it is not, the first code unit's lowest. Each 16-bit code unit is compared whole: one above 0xFF is in no
    /// class.
    @inline(always)
    private static func laneMarks<CodeUnit: HTTPHeaderStringCodeUnit, Class: HTTPHeaderCharacterClass>(
        _: Class.Type,
        _ bytes: RawSpan,
        _ index: Int,
        inClass: Bool,
        _: CodeUnit.Type
    ) -> UInt64 {
        var lanes: SIMD16<UInt8>
        if CodeUnit.bitWidth == 8 {
            lanes = Class.lanes(in: bytes.load(fromByteOffset: index, as: SIMD16<UInt8>.self))
        } else {
            // The index is within the span, whose bytes fit in an Int, so this cannot overflow.
            let first = bytes.load(fromByteOffset: index &* 2, as: SIMD8<UInt16>.self)
            let second = bytes.load(fromByteOffset: index &* 2 &+ 16, as: SIMD8<UInt16>.self)
            let low = SIMD16<UInt8>(lowHalf: SIMD8<UInt8>(truncatingIfNeeded: first), highHalf: SIMD8<UInt8>(truncatingIfNeeded: second))
            let high = SIMD16<UInt8>(
                lowHalf: SIMD8<UInt8>(truncatingIfNeeded: first &>> 8),
                highHalf: SIMD8<UInt8>(truncatingIfNeeded: second &>> 8)
            )
            // The highest bit of high | (0 - high) is set where high is not zero; the subtraction wraps on purpose.
            lanes = Class.lanes(in: low) & ~(high | (0 &- high))
        }
        if !inClass {
            lanes = ~lanes
        }
        // Each lane's highest bit across the lane, then the middle 8 bits of each pair of lanes.
        let full = SIMD16<UInt8>(truncatingIfNeeded: SIMD16<Int8>(truncatingIfNeeded: lanes) &>> 7)
        let nibbles = SIMD8<UInt8>(truncatingIfNeeded: bitCast(full, to: SIMD8<UInt16>.self) &>> 4)
        return UInt64(littleEndian: bitCast(nibbles, to: UInt64.self))
    }
}

/// A substring of the argument: the view or String that `substring(start, length)` of the argument makes.
/// A start at or past the argument's length stands for WTF's 8-bit empty view, `emptyStringView()`.
// An extent lies within its argument, so the sums and differences of positions and lengths below are at most the
// argument's length: wrapping arithmetic, which cannot wrap, where the compiler cannot see the bound.
struct HTTPHeaderSubstringExtent: Equatable {
    var start: Int
    var length: Int

    @inline(always)
    var end: Int {
        // An extent lies within its argument, so its end cannot overflow.
        start &+ length
    }

    /// `StringView::substring(start, length)` of this view, in the argument's coordinates.
    @inline(always)
    func substring(from start: Int, length: Int = .max, argumentLength: Int) -> HTTPHeaderSubstringExtent {
        if start >= self.length {
            return HTTPHeaderSubstringExtent(start: argumentLength, length: 0)
        }
        // start is below self.length, and the extent lies within its argument.
        let maxLength = self.length &- start
        if length >= maxLength {
            if start == 0 {
                return self
            }
            return HTTPHeaderSubstringExtent(start: self.start &+ start, length: maxLength)
        }
        return HTTPHeaderSubstringExtent(start: self.start + start, length: length)
    }
}

extension HTTPHeaderCodeUnits {
    /// isValidHTTPToken: not empty, and token characters only.
    static func isHTTPToken<CodeUnit: HTTPHeaderStringCodeUnit>(_ input: Span<CodeUnit>, _ extent: HTTPHeaderSubstringExtent) -> Bool {
        if extent.length == 0 {
            return false
        }
        return containsOnly(HTTPHeaderTokenCharacters.self, in: input, from: extent.start, to: extent.end)
    }

    /// `StringView::trim(predicate)` of a view, in the argument's coordinates.
    @inline(always)
    static func trim<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ input: Span<CodeUnit>,
        _ view: HTTPHeaderSubstringExtent,
        _ predicate: (UInt32) -> Bool
    ) -> HTTPHeaderSubstringExtent {
        if view.length == 0 {
            return view
        }
        // The view is not empty, and start and end stay within it.
        var start = 0
        var end = view.length &- 1
        while start <= end && predicate(value(input[view.start &+ start])) {
            start += 1
        }
        if start > end {
            return HTTPHeaderSubstringExtent(start: input.count, length: 0)
        }
        while end != 0 && predicate(value(input[view.start &+ end])) {
            end -= 1
        }
        if start == 0 && end == view.length &- 1 {
            return view
        }
        return HTTPHeaderSubstringExtent(start: view.start &+ start, length: end &+ 1 &- start)
    }

    /// equalLettersIgnoringASCIICase: the same length, and `c | 0x20` equal to each character of the literal.
    @inline(always)
    static func equalLettersIgnoringASCIICase<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ input: Span<CodeUnit>,
        _ extent: HTTPHeaderSubstringExtent,
        _ lowercaseLetters: Swift.String
    ) -> Bool {
        let letters = lowercaseLetters.utf8
        if extent.length != letters.count {
            return false
        }
        var index = extent.start
        for letter in letters {
            if value(input[index]) | 0x20 != UInt32(letter) {
                return false
            }
            index += 1
        }
        return true
    }
}

/// The header value validators of HTTPParsers.
enum HTTPHeaderValueValidation {
    private typealias Units = HTTPHeaderCodeUnits

    /// `isValidReasonPhrase`: RFC 7230, section 3.1.2.
    static func isValidReasonPhrase<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ value: Span<CodeUnit>) -> Bool {
        for index in value.indices {
            let c = Units.value(value[index])
            if c == 0x7F || c > 0xFF || (c < 0x20 && c != 0x09) {
                return false
            }
        }
        return true
    }

    /// `isValidHTTPHeaderValue`: https://fetch.spec.whatwg.org/#concept-header. An empty value is valid.
    @inline(always)
    static func isValidHTTPHeaderValue<CodeUnit: HTTPHeaderStringCodeUnit>(_ value: Span<CodeUnit>) -> Bool {
        if !value.isEmpty {
            if Units.isTabOrSpace(Units.value(value[0])) || Units.isTabOrSpace(Units.value(value[value.count - 1])) {
                return false
            }
        }
        return Units.containsNone(of: HTTPHeaderNULAndLineBreaks.self, in: value, from: 0, to: value.count)
    }

    /// `isValidAcceptHeaderValue`: RFC 7231, section 5.3.2. A code unit above 0xFF that is not a delimiter is
    /// accepted; only the debug assertion rejects it.
    @inline(always)
    static func isValidAcceptHeaderValue<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ value: Span<CodeUnit>) -> Bool {
        for index in value.indices {
            let c = Units.value(value[index])
            // Alphanumerics first, then the four delimiters this header allows: `,`, `/`, `;` and `=`.
            if Units.isASCIIAlphanumeric(c) || c == 0x2C || c == 0x2F || c == 0x3B || c == 0x3D {
                continue
            }
            assert(c <= 0xFF)
            if c == 0x7F || (c < 0x20 && c != 0x09) {
                return false
            }
            if Units.isDelimiter(c) {
                return false
            }
        }
        return true
    }

    /// `containsCORSUnsafeRequestHeaderBytes`: https://fetch.spec.whatwg.org/#cors-unsafe-request-header-byte.
    /// Code units above 0xFF are not unsafe.
    static func containsCORSUnsafeRequestHeaderBytes<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ value: Span<CodeUnit>) -> Bool {
        for index in value.indices {
            let c = Units.value(value[index])
            if c < 0x20 && c != 0x09 {
                return true
            }
            switch c {
            case 0x22, 0x28, 0x29, 0x3A, 0x3C, 0x3E, 0x3F, 0x40, 0x5B, 0x5C, 0x5D, 0x7B, 0x7D, 0x7F: // "():<>?@[\]{} and DEL
                return true
            default:
                break
            }
        }
        return false
    }

    /// `isValidLanguageHeaderValue`: RFC 7231, sections 5.3.5 and 3.1.3.2, and
    /// https://fetch.spec.whatwg.org/#cors-safelisted-request-header.
    static func isValidLanguageHeaderValue<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ value: Span<CodeUnit>) -> Bool {
        for index in value.indices {
            let c = Units.value(value[index])
            if Units.isASCIIAlphanumeric(c) {
                continue
            }
            switch c {
            case 0x20, 0x2A, 0x2C, 0x2D, 0x2E, 0x3B, 0x3D: // space and *,-.;=
                continue
            default:
                return false
            }
        }
        return true
    }

    /// `isValidHTTPToken`: RFC 7230, section 3.2.6.
    @inline(always)
    static func isValidHTTPToken<CodeUnit: HTTPHeaderStringCodeUnit>(_ value: Span<CodeUnit>) -> Bool {
        if value.isEmpty {
            return false
        }
        return Units.containsOnly(HTTPHeaderTokenCharacters.self, in: value, from: 0, to: value.count)
    }
}

/// Fetch's checks on request and response header names, header values and methods, from HTTPParsers. The caller looks
/// a name up with `findHTTPHeaderName()`, and passes `isKnown` and the `HTTPHeaderName` found; `headerName` is read only
/// when `isKnown` is true.
enum FetchHeaderChecks {
    private typealias Units = HTTPHeaderCodeUnits
    typealias HTTPHeaderName = WebCore.HTTPHeaderName

    /// The delimiter `requestHeaderAppendDelimiter` places between appended values. HTTPParsers.cpp's table of
    /// delimiters is indexed by the raw value, so the cases are in the table's order.
    enum AppendDelimiter: UInt8 {
        /// `", "`
        case commaSpace
        /// `"; "`
        case semicolonSpace
        /// `""`
        case empty
        /// `" "`
        case space
    }

    /// What `isCrossOriginSafeHeader(HTTPHeaderName, const HTTPHeaderSet&)` decides from the name alone.
    enum CrossOriginSafeHeaderNameDecision: UInt8 {
        case safe
        case notSafe
        /// Safe if the Access-Control-Expose-Headers set contains the name's string.
        case safeIfExposed
    }

    /// `isForbiddenHeaderName`: https://fetch.spec.whatwg.org/#forbidden-header-name.
    static func isForbiddenHeaderName<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        isKnown: Bool,
        headerName: HTTPHeaderName,
        _ name: Span<CodeUnit>
    ) -> Bool {
        if isKnown {
            switch headerName {
            case .AcceptCharset, .AcceptEncoding, .AccessControlRequestHeaders, .AccessControlRequestMethod, .AvailableDictionary,
                .Connection, .ContentLength, .Cookie, .Cookie2, .Date, .DictionaryID, .DNT, .Expect, .Host, .KeepAlive, .Origin,
                .Referer, .SetCookie, .TE, .Trailer, .TransferEncoding, .Upgrade, .Via:
                return true
            default:
                break
            }
        }
        return Units.startsWithLettersIgnoringASCIICase(name, Literal.secPrefix.span)
            || Units.startsWithLettersIgnoringASCIICase(name, Literal.proxyPrefix.span)
    }

    /// `isForbiddenMethodOverrideHeader`: a method-override header whose comma-separated value names a forbidden method.
    static func isForbiddenMethodOverrideHeader<
        NameCodeUnit: FixedWidthInteger & UnsignedInteger,
        ValueCodeUnit: FixedWidthInteger & UnsignedInteger
    >(
        _ name: Span<NameCodeUnit>,
        _ value: Span<ValueCodeUnit>
    ) -> Bool {
        if !Units.equalLettersIgnoringASCIICase(name, Literal.xHTTPMethodOverride.span)
            && !Units.equalLettersIgnoringASCIICase(name, Literal.xHTTPMethod.span)
            && !Units.equalLettersIgnoringASCIICase(name, Literal.xMethodOverride.span)
        {
            return false
        }
        // `StringView::split(',')`, which skips empty entries.
        var position = 0
        while position < value.count {
            let separator = Units.find(0x2C, in: value, from: position)
            if separator > position {
                let method = Units.trim(value, position..<separator, Units.isUnicodeCompatibleASCIIWhitespace)
                if isForbiddenMethod(value.extracting(method)) {
                    return true
                }
            }
            if separator >= value.count {
                break
            }
            position = separator + 1
        }
        return false
    }

    /// `isForbiddenHeader`.
    static func isForbiddenHeader<NameCodeUnit: FixedWidthInteger & UnsignedInteger, ValueCodeUnit: FixedWidthInteger & UnsignedInteger>(
        isKnown: Bool,
        headerName: HTTPHeaderName,
        _ name: Span<NameCodeUnit>,
        _ value: Span<ValueCodeUnit>
    ) -> Bool {
        isForbiddenHeaderName(isKnown: isKnown, headerName: headerName, name) || isForbiddenMethodOverrideHeader(name, value)
    }

    /// `isNoCORSSafelistedRequestHeaderName`: https://fetch.spec.whatwg.org/#no-cors-safelisted-request-header-name.
    static func isNoCORSSafelistedRequestHeaderName(isKnown: Bool, headerName: HTTPHeaderName) -> Bool {
        guard isKnown else {
            return false
        }
        switch headerName {
        case .Accept, .AcceptLanguage, .ContentLanguage, .ContentType:
            return true
        default:
            return false
        }
    }

    /// `isPriviledgedNoCORSRequestHeaderName`: https://fetch.spec.whatwg.org/#privileged-no-cors-request-header-name.
    static func isPriviledgedNoCORSRequestHeaderName<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ name: Span<CodeUnit>) -> Bool {
        Units.equalLettersIgnoringASCIICase(name, Literal.range.span)
    }

    /// `isForbiddenResponseHeaderName`: https://fetch.spec.whatwg.org/#forbidden-response-header-name.
    @inline(always)
    static func isForbiddenResponseHeaderName<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ name: Span<CodeUnit>) -> Bool {
        Units.equalLettersIgnoringASCIICase(name, Literal.setCookie.span)
            || Units.equalLettersIgnoringASCIICase(name, Literal.setCookie2.span)
    }

    /// `isForbiddenMethod`: https://fetch.spec.whatwg.org/#forbidden-method.
    @inline(always)
    static func isForbiddenMethod<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ name: Span<CodeUnit>) -> Bool {
        Units.equalLettersIgnoringASCIICase(name, Literal.connect.span)
            || Units.equalLettersIgnoringASCIICase(name, Literal.trace.span)
            || Units.equalLettersIgnoringASCIICase(name, Literal.track.span)
    }

    /// `isCrossOriginSafeHeader(HTTPHeaderName, const HTTPHeaderSet&)`, up to its set lookup.
    static func crossOriginSafeHeaderNameDecision(_ headerName: HTTPHeaderName) -> CrossOriginSafeHeaderNameDecision {
        switch headerName {
        case .CacheControl, .ContentLanguage, .ContentLength, .ContentType, .Expires, .LastModified, .Pragma, .Accept:
            return .safe
        case .SetCookie, .SetCookie2:
            return .notSafe
        default:
            return .safeIfExposed
        }
    }

    /// `normalizeHTTPMethod`: https://fetch.spec.whatwg.org/#concept-method-normalize. `DELETE`, `GET`, `HEAD`,
    /// `OPTIONS`, `POST` or `PUT` for the argument in another case; nil to keep the argument.
    static func normalizeHTTPMethod<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ method: Span<CodeUnit>) -> [UInt8]? {
        if let name = normalizedMethod(method, Literal.deleteMethod) {
            return name
        }
        if let name = normalizedMethod(method, Literal.getMethod) {
            return name
        }
        if let name = normalizedMethod(method, Literal.headMethod) {
            return name
        }
        if let name = normalizedMethod(method, Literal.optionsMethod) {
            return name
        }
        if let name = normalizedMethod(method, Literal.postMethod) {
            return name
        }
        return normalizedMethod(method, Literal.putMethod)
    }

    /// No two of the names are equal ignoring ASCII case, so an argument that is one of them matches no other.
    @inline(always)
    private static func normalizedMethod<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ method: Span<CodeUnit>,
        _ name: [UInt8]
    ) -> [UInt8]? {
        guard Units.equalIgnoringASCIICase(method, name.span), !Units.equal(method, name.span) else {
            return nil
        }
        return name
    }

    /// `isSafeMethod`: RFC 7231, section 4.2.1.
    @inline(always)
    static func isSafeMethod<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ method: Span<CodeUnit>) -> Bool {
        Units.equalIgnoringASCIICase(method, Literal.getMethod.span)
            || Units.equalIgnoringASCIICase(method, Literal.headMethod.span)
            || Units.equalIgnoringASCIICase(method, Literal.optionsMethod.span)
            || Units.equalIgnoringASCIICase(method, Literal.traceMethod.span)
    }

    /// `requestHeaderAppendDelimiter`: the request headers that can be appended to, and the delimiter placed between
    /// values, or nil for the others.
    static func requestHeaderAppendDelimiter<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ header: Span<CodeUnit>) -> AppendDelimiter? {
        typealias Name = AppendableHeader
        if Units.equalIgnoringASCIICase(header, Name.accept.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.acceptEncoding.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.acceptLanguage.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.accessControlRequestHeaders.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.cacheControl.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.connection.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.contentLanguage.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.cookie.span) {
            return .semicolonSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.forwarded.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.ifMatch.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.ifNoneMatch.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.keepAlive.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.range.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.te.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.trailer.span) {
            return .empty
        }
        if Units.equalIgnoringASCIICase(header, Name.transferEncoding.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.upgrade.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.userAgent.span) {
            return .space
        }
        if Units.equalIgnoringASCIICase(header, Name.via.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.wantDigest.span) {
            return .commaSpace
        }
        if Units.equalIgnoringASCIICase(header, Name.xForwardedFor.span) {
            return .commaSpace
        }
        return nil
    }

    /// `isRequestHeaderUnsafeToModify`: request headers, and header values, that an extension can't set or append to,
    /// because the network stack manages them.
    static func isRequestHeaderUnsafeToModify<
        NameCodeUnit: FixedWidthInteger & UnsignedInteger,
        ValueCodeUnit: FixedWidthInteger & UnsignedInteger
    >(
        _ header: Span<NameCodeUnit>,
        _ value: Span<ValueCodeUnit>
    ) -> Bool {
        if Units.startsWithLettersIgnoringASCIICase(header, Literal.proxyPrefix.span) {
            return true
        }
        typealias Name = UnsafeHeader
        if Units.equalIgnoringASCIICase(header, Name.availableDictionary.span)
            || Units.equalIgnoringASCIICase(header, Name.contentLength.span)
            || Units.equalIgnoringASCIICase(header, Name.cookie2.span)
            || Units.equalIgnoringASCIICase(header, Name.host.span)
            || Units.equalIgnoringASCIICase(header, Name.keepAlive.span)
            || Units.equalIgnoringASCIICase(header, Name.setCookie.span)
            || Units.equalIgnoringASCIICase(header, Name.te.span)
            || Units.equalIgnoringASCIICase(header, Name.trailer.span)
            || Units.equalIgnoringASCIICase(header, Name.transferEncoding.span)
            || Units.equalIgnoringASCIICase(header, Name.upgrade.span)
        {
            return true
        }

        // Shared dictionary encodings and wildcards can't be negotiated by an extension.
        if Units.equalLettersIgnoringASCIICase(header, AppendableHeader.acceptEncoding.span) {
            var position = 0
            while position < value.count {
                let separator = Units.find(0x2C, in: value, from: position)
                if separator > position {
                    let encodingValue = value.extracting(position..<separator)
                    let parameters = Units.find(0x3B, in: encodingValue, from: 0)
                    let encoding = encodingValue.extracting(
                        Units.trim(encodingValue, 0..<parameters, Units.isUnicodeCompatibleASCIIWhitespace)
                    )
                    if Units.equalLettersIgnoringASCIICase(encoding, Literal.dcb.span)
                        || Units.equalLettersIgnoringASCIICase(encoding, Literal.dcz.span)
                        || Units.equal(encoding, Literal.star.span)
                    {
                        return true
                    }
                }
                if separator >= value.count {
                    break
                }
                position = separator + 1
            }
        }

        // Only the connection options that the network stack itself uses are allowed.
        if Units.equalLettersIgnoringASCIICase(header, AppendableHeader.connection.span) {
            var position = 0
            while position < value.count {
                let separator = Units.find(0x2C, in: value, from: position)
                if separator > position {
                    let token = value.extracting(Units.trim(value, position..<separator, Units.isUnicodeCompatibleASCIIWhitespace))
                    if !token.isEmpty
                        && !Units.equalLettersIgnoringASCIICase(token, Literal.close.span)
                        && !Units.equalLettersIgnoringASCIICase(token, AppendableHeader.keepAlive.span)
                    {
                        return true
                    }
                }
                if separator >= value.count {
                    break
                }
                position = separator + 1
            }
        }

        return isForbiddenMethodOverrideHeader(header, value)
    }

    private enum Literal {
        /// "sec-"
        static let secPrefix: [UInt8] = [0x73, 0x65, 0x63, 0x2D]
        /// "proxy-"
        static let proxyPrefix: [UInt8] = [0x70, 0x72, 0x6F, 0x78, 0x79, 0x2D]
        /// "x-http-method-override"
        static let xHTTPMethodOverride: [UInt8] = [
            0x78, 0x2D, 0x68, 0x74, 0x74, 0x70, 0x2D, 0x6D, 0x65, 0x74, 0x68, 0x6F, 0x64, 0x2D, 0x6F, 0x76, 0x65, 0x72, 0x72, 0x69, 0x64,
            0x65,
        ]
        /// "x-http-method"
        static let xHTTPMethod: [UInt8] = [0x78, 0x2D, 0x68, 0x74, 0x74, 0x70, 0x2D, 0x6D, 0x65, 0x74, 0x68, 0x6F, 0x64]
        /// "x-method-override"
        static let xMethodOverride: [UInt8] = [
            0x78, 0x2D, 0x6D, 0x65, 0x74, 0x68, 0x6F, 0x64, 0x2D, 0x6F, 0x76, 0x65, 0x72, 0x72, 0x69, 0x64, 0x65,
        ]
        /// "range"
        static let range: [UInt8] = [0x72, 0x61, 0x6E, 0x67, 0x65]
        /// "set-cookie"
        static let setCookie: [UInt8] = [0x73, 0x65, 0x74, 0x2D, 0x63, 0x6F, 0x6F, 0x6B, 0x69, 0x65]
        /// "set-cookie2"
        static let setCookie2: [UInt8] = [0x73, 0x65, 0x74, 0x2D, 0x63, 0x6F, 0x6F, 0x6B, 0x69, 0x65, 0x32]
        /// "connect"
        static let connect: [UInt8] = [0x63, 0x6F, 0x6E, 0x6E, 0x65, 0x63, 0x74]
        /// "trace"
        static let trace: [UInt8] = [0x74, 0x72, 0x61, 0x63, 0x65]
        /// "track"
        static let track: [UInt8] = [0x74, 0x72, 0x61, 0x63, 0x6B]
        /// "DELETE"
        static let deleteMethod: [UInt8] = [0x44, 0x45, 0x4C, 0x45, 0x54, 0x45]
        /// "GET"
        static let getMethod: [UInt8] = [0x47, 0x45, 0x54]
        /// "HEAD"
        static let headMethod: [UInt8] = [0x48, 0x45, 0x41, 0x44]
        /// "OPTIONS"
        static let optionsMethod: [UInt8] = [0x4F, 0x50, 0x54, 0x49, 0x4F, 0x4E, 0x53]
        /// "POST"
        static let postMethod: [UInt8] = [0x50, 0x4F, 0x53, 0x54]
        /// "PUT"
        static let putMethod: [UInt8] = [0x50, 0x55, 0x54]
        /// "TRACE"
        static let traceMethod: [UInt8] = [0x54, 0x52, 0x41, 0x43, 0x45]
        /// "dcb"
        static let dcb: [UInt8] = [0x64, 0x63, 0x62]
        /// "dcz"
        static let dcz: [UInt8] = [0x64, 0x63, 0x7A]
        /// "*"
        static let star: [UInt8] = [0x2A]
        /// "close"
        static let close: [UInt8] = [0x63, 0x6C, 0x6F, 0x73, 0x65]
    }

    private enum AppendableHeader {
        /// "accept"
        static let accept: [UInt8] = [0x61, 0x63, 0x63, 0x65, 0x70, 0x74]
        /// "accept-encoding"
        static let acceptEncoding: [UInt8] = [0x61, 0x63, 0x63, 0x65, 0x70, 0x74, 0x2D, 0x65, 0x6E, 0x63, 0x6F, 0x64, 0x69, 0x6E, 0x67]
        /// "accept-language"
        static let acceptLanguage: [UInt8] = [0x61, 0x63, 0x63, 0x65, 0x70, 0x74, 0x2D, 0x6C, 0x61, 0x6E, 0x67, 0x75, 0x61, 0x67, 0x65]
        /// "access-control-request-headers"
        static let accessControlRequestHeaders: [UInt8] = [
            0x61, 0x63, 0x63, 0x65, 0x73, 0x73, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C, 0x2D, 0x72, 0x65, 0x71, 0x75, 0x65, 0x73,
            0x74, 0x2D, 0x68, 0x65, 0x61, 0x64, 0x65, 0x72, 0x73,
        ]
        /// "cache-control"
        static let cacheControl: [UInt8] = [0x63, 0x61, 0x63, 0x68, 0x65, 0x2D, 0x63, 0x6F, 0x6E, 0x74, 0x72, 0x6F, 0x6C]
        /// "connection"
        static let connection: [UInt8] = [0x63, 0x6F, 0x6E, 0x6E, 0x65, 0x63, 0x74, 0x69, 0x6F, 0x6E]
        /// "content-language"
        static let contentLanguage: [UInt8] = [
            0x63, 0x6F, 0x6E, 0x74, 0x65, 0x6E, 0x74, 0x2D, 0x6C, 0x61, 0x6E, 0x67, 0x75, 0x61, 0x67, 0x65,
        ]
        /// "cookie"
        static let cookie: [UInt8] = [0x63, 0x6F, 0x6F, 0x6B, 0x69, 0x65]
        /// "forwarded"
        static let forwarded: [UInt8] = [0x66, 0x6F, 0x72, 0x77, 0x61, 0x72, 0x64, 0x65, 0x64]
        /// "if-match"
        static let ifMatch: [UInt8] = [0x69, 0x66, 0x2D, 0x6D, 0x61, 0x74, 0x63, 0x68]
        /// "if-none-match"
        static let ifNoneMatch: [UInt8] = [0x69, 0x66, 0x2D, 0x6E, 0x6F, 0x6E, 0x65, 0x2D, 0x6D, 0x61, 0x74, 0x63, 0x68]
        /// "keep-alive"
        static let keepAlive: [UInt8] = [0x6B, 0x65, 0x65, 0x70, 0x2D, 0x61, 0x6C, 0x69, 0x76, 0x65]
        /// "range"
        static let range: [UInt8] = [0x72, 0x61, 0x6E, 0x67, 0x65]
        /// "te"
        static let te: [UInt8] = [0x74, 0x65]
        /// "trailer"
        static let trailer: [UInt8] = [0x74, 0x72, 0x61, 0x69, 0x6C, 0x65, 0x72]
        /// "transfer-encoding"
        static let transferEncoding: [UInt8] = [
            0x74, 0x72, 0x61, 0x6E, 0x73, 0x66, 0x65, 0x72, 0x2D, 0x65, 0x6E, 0x63, 0x6F, 0x64, 0x69, 0x6E, 0x67,
        ]
        /// "upgrade"
        static let upgrade: [UInt8] = [0x75, 0x70, 0x67, 0x72, 0x61, 0x64, 0x65]
        /// "user-agent"
        static let userAgent: [UInt8] = [0x75, 0x73, 0x65, 0x72, 0x2D, 0x61, 0x67, 0x65, 0x6E, 0x74]
        /// "via"
        static let via: [UInt8] = [0x76, 0x69, 0x61]
        /// "want-digest"
        static let wantDigest: [UInt8] = [0x77, 0x61, 0x6E, 0x74, 0x2D, 0x64, 0x69, 0x67, 0x65, 0x73, 0x74]
        /// "x-forwarded-for"
        static let xForwardedFor: [UInt8] = [0x78, 0x2D, 0x66, 0x6F, 0x72, 0x77, 0x61, 0x72, 0x64, 0x65, 0x64, 0x2D, 0x66, 0x6F, 0x72]
    }

    private enum UnsafeHeader {
        /// "available-dictionary"
        static let availableDictionary: [UInt8] = [
            0x61, 0x76, 0x61, 0x69, 0x6C, 0x61, 0x62, 0x6C, 0x65, 0x2D, 0x64, 0x69, 0x63, 0x74, 0x69, 0x6F, 0x6E, 0x61, 0x72, 0x79,
        ]
        /// "content-length"
        static let contentLength: [UInt8] = [0x63, 0x6F, 0x6E, 0x74, 0x65, 0x6E, 0x74, 0x2D, 0x6C, 0x65, 0x6E, 0x67, 0x74, 0x68]
        /// "cookie2"
        static let cookie2: [UInt8] = [0x63, 0x6F, 0x6F, 0x6B, 0x69, 0x65, 0x32]
        /// "host"
        static let host: [UInt8] = [0x68, 0x6F, 0x73, 0x74]
        /// "keep-alive"
        static let keepAlive: [UInt8] = [0x6B, 0x65, 0x65, 0x70, 0x2D, 0x61, 0x6C, 0x69, 0x76, 0x65]
        /// "set-cookie"
        static let setCookie: [UInt8] = [0x73, 0x65, 0x74, 0x2D, 0x63, 0x6F, 0x6F, 0x6B, 0x69, 0x65]
        /// "te"
        static let te: [UInt8] = [0x74, 0x65]
        /// "trailer"
        static let trailer: [UInt8] = [0x74, 0x72, 0x61, 0x69, 0x6C, 0x65, 0x72]
        /// "transfer-encoding"
        static let transferEncoding: [UInt8] = [
            0x74, 0x72, 0x61, 0x6E, 0x73, 0x66, 0x65, 0x72, 0x2D, 0x65, 0x6E, 0x63, 0x6F, 0x64, 0x69, 0x6E, 0x67,
        ]
        /// "upgrade"
        static let upgrade: [UInt8] = [0x75, 0x70, 0x67, 0x72, 0x61, 0x64, 0x65]
    }
}

/// The tokenizer of `parseAccessControlAllowList`, one token per call. The list is split at every `,`; each
/// non-empty entry is trimmed of ASCII whitespace without form feed, an entry left empty is skipped, and any other
/// must be an HTTP token, or the whole list is invalid.
enum AccessControlAllowListParsing {
    private typealias Units = HTTPHeaderCodeUnits

    enum Step: Equatable {
        /// A token at `start`, `length` code units long; the next call starts at `next`.
        case token(start: Int, length: Int, next: Int)
        /// No token is left: the list is valid.
        case end
        /// An entry is not a token: the list is invalid.
        case invalid
    }

    /// The next token of `list` at or after `cursor`, which is 0 for the first call.
    static func nextToken<CodeUnit: HTTPHeaderStringCodeUnit>(_ list: Span<CodeUnit>, from cursor: Int) -> Step {
        var start = cursor
        while start < list.count {
            let end = Units.find(0x2C, in: list, from: start)
            let next = end < list.count ? end + 1 : end
            if start != end {
                let token = Units.trim(list, start..<end, Units.isASCIIWhitespaceWithoutFF)
                if !token.isEmpty {
                    // longTokenStep() checks a token of 16 code units or more 16 at a time.
                    if token.count >= 16 {
                        return longTokenStep(list, token, next: next)
                    }
                    return tokenStep(list, token, next: next)
                }
            }
            start = next
        }
        return .end
    }

    @inline(never)
    private static func longTokenStep<CodeUnit: HTTPHeaderStringCodeUnit>(_ list: Span<CodeUnit>, _ token: Range<Int>, next: Int) -> Step {
        tokenStep(list, token, next: next)
    }

    @inline(always)
    private static func tokenStep<CodeUnit: HTTPHeaderStringCodeUnit>(_ list: Span<CodeUnit>, _ token: Range<Int>, next: Int) -> Step {
        guard HTTPHeaderValueValidation.isValidHTTPToken(list.extracting(token)) else {
            return .invalid
        }
        return .token(start: token.lowerBound, length: token.count, next: next)
    }
}

/// The parsers of single-value response headers in HTTPParsers: X-Content-Type-Options, X-Frame-Options,
/// Cross-Origin-Resource-Policy, Clear-Site-Data, and the reason phrase of a status line.
enum HTTPResponseHeaderParsing {
    private typealias Units = HTTPHeaderCodeUnits

    typealias ContentTypeOptionsDisposition = WebCore.ContentTypeOptionsDisposition

    typealias XFrameOptionsDisposition = WebCore.XFrameOptionsDisposition

    typealias CrossOriginResourcePolicy = WebCore.CrossOriginResourcePolicy

    typealias ClearSiteDataValue = WebCore.ClearSiteDataValue

    /// `parseContentTypeOptionsHeader`: only the text before the first `,` counts.
    static func parseContentTypeOptionsHeader<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ header: Span<CodeUnit>
    ) -> ContentTypeOptionsDisposition {
        let leftToken = 0..<Units.find(0x2C, in: header, from: 0)
        let token = header.extracting(Units.trim(header, leftToken, Units.isASCIIWhitespaceWithoutFF))
        return Units.equalLettersIgnoringASCIICase(token, Literal.nosniff.span) ? .Nosniff : .None
    }

    /// `extractReasonPhraseFromHTTPStatusLine`: the start of the text after the second space, or nil for the empty
    /// atom when the line has fewer than two spaces. "HTTP/1.1 200 OK" gives the start of "OK".
    static func reasonPhraseStartInHTTPStatusLine<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ statusLine: Span<CodeUnit>) -> Int? {
        // The second search starts at `notFound + 1`, which wraps to 0, when the line has no space.
        let notFound = UInt.max
        let firstSpace = Units.find(0x20, in: statusLine, from: 0)
        let firstSpacePosition = firstSpace == statusLine.count ? notFound : UInt(firstSpace)
        let secondSearchStart = UInt32(truncatingIfNeeded: firstSpacePosition &+ 1)
        let secondSpace = Units.find(0x20, in: statusLine, from: Int(secondSearchStart))
        if secondSpace == statusLine.count {
            return nil
        }
        return secondSpace + 1
    }

    /// `parseXFrameOptionsHeader`. Entries are split at every `,`, empty ones included, and trimmed of tabs and
    /// spaces; a second value that differs from the first is a conflict.
    @inline(always)
    static func parseXFrameOptionsHeader<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ header: Span<CodeUnit>
    ) -> XFrameOptionsDisposition {
        var result = XFrameOptionsDisposition.None
        if header.isEmpty {
            return result
        }
        // `StringView::splitAllowingEmptyEntries(',')`.
        var position = 0
        while true {
            let separator = Units.find(0x2C, in: header, from: position)
            let currentHeader = header.extracting(Units.trim(header, position..<separator, Units.isTabOrSpace))
            let currentValue: XFrameOptionsDisposition
            if Units.equalLettersIgnoringASCIICase(currentHeader, Literal.deny.span) {
                currentValue = .Deny
            } else if Units.equalLettersIgnoringASCIICase(currentHeader, Literal.sameorigin.span) {
                currentValue = .SameOrigin
            } else if Units.equalLettersIgnoringASCIICase(currentHeader, Literal.allowall.span) {
                currentValue = .AllowAll
            } else {
                currentValue = .Invalid
            }

            if result == .None {
                result = currentValue
            } else if result != currentValue {
                return .Conflict
            }

            if separator >= header.count {
                return result
            }
            position = separator + 1
        }
    }

    /// `parseCrossOriginResourcePolicyHeader`, which compares case-sensitively.
    @inline(always)
    static func parseCrossOriginResourcePolicyHeader<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ header: Span<CodeUnit>
    ) -> CrossOriginResourcePolicy {
        let trimmedHeader = header.extracting(Units.trim(header, header.indices, Units.isASCIIWhitespaceWithoutFF))
        if trimmedHeader.isEmpty {
            return .None
        }
        if Units.equal(trimmedHeader, Literal.sameOrigin.span) {
            return .SameOrigin
        }
        if Units.equal(trimmedHeader, Literal.sameSite.span) {
            return .SameSite
        }
        if Units.equal(trimmedHeader, Literal.crossOrigin.span) {
            return .CrossOrigin
        }
        return .Invalid
    }

    /// `parseClearSiteDataHeader`, after its checks that the header is not empty and the response's URL is
    /// potentially trustworthy: the raw value of `OptionSet<ClearSiteDataValue>`. Entries are split at `,`, skipping
    /// empty ones, and the quoted values are compared case-sensitively, quotes included.
    @inline(always)
    static func parseClearSiteDataHeader<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ header: Span<CodeUnit>) -> UInt8 {
        var result: UInt8 = 0
        // `StringView::split(',')`, which skips empty entries.
        var position = 0
        while position < header.count {
            let separator = Units.find(0x2C, in: header, from: position)
            if separator > position {
                let trimmedValue = header.extracting(Units.trim(header, position..<separator, Units.isASCIIWhitespaceWithoutFF))
                if Units.equal(trimmedValue, Literal.quotedCache.span) {
                    result |= ClearSiteDataValue.Cache.rawValue
                } else if Units.equal(trimmedValue, Literal.quotedCookies.span) {
                    result |= ClearSiteDataValue.Cookies.rawValue
                } else if Units.equal(trimmedValue, Literal.quotedExecutionContexts.span) {
                    result |= ClearSiteDataValue.ExecutionContexts.rawValue
                } else if Units.equal(trimmedValue, Literal.quotedStorage.span) {
                    result |= ClearSiteDataValue.Storage.rawValue
                } else if Units.equal(trimmedValue, Literal.quotedPrefetchCache.span) {
                    result |= ClearSiteDataValue.PrefetchCache.rawValue
                } else if Units.equal(trimmedValue, Literal.quotedStar.span) {
                    result |=
                        ClearSiteDataValue.Cache.rawValue | ClearSiteDataValue.Cookies.rawValue
                        | ClearSiteDataValue.ExecutionContexts.rawValue
                        | ClearSiteDataValue.Storage.rawValue | ClearSiteDataValue.PrefetchCache.rawValue
                }
            }
            if separator >= header.count {
                break
            }
            position = separator + 1
        }
        return result
    }

    private enum Literal {
        /// "nosniff"
        static let nosniff: [UInt8] = [0x6E, 0x6F, 0x73, 0x6E, 0x69, 0x66, 0x66]
        /// "deny"
        static let deny: [UInt8] = [0x64, 0x65, 0x6E, 0x79]
        /// "sameorigin"
        static let sameorigin: [UInt8] = [0x73, 0x61, 0x6D, 0x65, 0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E]
        /// "allowall"
        static let allowall: [UInt8] = [0x61, 0x6C, 0x6C, 0x6F, 0x77, 0x61, 0x6C, 0x6C]
        /// "same-origin"
        static let sameOrigin: [UInt8] = [0x73, 0x61, 0x6D, 0x65, 0x2D, 0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E]
        /// "same-site"
        static let sameSite: [UInt8] = [0x73, 0x61, 0x6D, 0x65, 0x2D, 0x73, 0x69, 0x74, 0x65]
        /// "cross-origin"
        static let crossOrigin: [UInt8] = [0x63, 0x72, 0x6F, 0x73, 0x73, 0x2D, 0x6F, 0x72, 0x69, 0x67, 0x69, 0x6E]
        /// `"cache"`
        static let quotedCache: [UInt8] = [0x22, 0x63, 0x61, 0x63, 0x68, 0x65, 0x22]
        /// `"cookies"`
        static let quotedCookies: [UInt8] = [0x22, 0x63, 0x6F, 0x6F, 0x6B, 0x69, 0x65, 0x73, 0x22]
        /// `"executionContexts"`
        static let quotedExecutionContexts: [UInt8] = [
            0x22, 0x65, 0x78, 0x65, 0x63, 0x75, 0x74, 0x69, 0x6F, 0x6E, 0x43, 0x6F, 0x6E, 0x74, 0x65, 0x78, 0x74, 0x73, 0x22,
        ]
        /// `"storage"`
        static let quotedStorage: [UInt8] = [0x22, 0x73, 0x74, 0x6F, 0x72, 0x61, 0x67, 0x65, 0x22]
        /// `"prefetchCache"`
        static let quotedPrefetchCache: [UInt8] = [
            0x22, 0x70, 0x72, 0x65, 0x66, 0x65, 0x74, 0x63, 0x68, 0x43, 0x61, 0x63, 0x68, 0x65, 0x22,
        ]
        /// `"*"`
        static let quotedStar: [UInt8] = [0x22, 0x2A, 0x22]
    }
}

// MIME types: ParsedContentType's parse, and HTTPParsers' media type and Content-Disposition helpers.

/// filenameFromHTTPContentDisposition: the filename's extent in `value`, or nil for the null view.
func httpContentDispositionFilenameExtent<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ value: Span<CodeUnit>
) -> HTTPHeaderSubstringExtent? {
    // Positions here are at most `count`: wrapping arithmetic cannot wrap.
    let count = value.count
    var entryStart = 0
    // StringView::split(';'), which skips empty entries.
    while entryStart < count {
        var entryEnd = entryStart
        while entryEnd < count {
            if HTTPHeaderCodeUnits.value(value[entryEnd]) == 0x3B {
                break
            }
            entryEnd += 1
        }
        if entryEnd > entryStart {
            var equalSign = entryStart
            while equalSign < entryEnd {
                if HTTPHeaderCodeUnits.value(value[equalSign]) == 0x3D {
                    break
                }
                equalSign += 1
            }
            if equalSign < entryEnd {
                // entryStart <= equalSign < entryEnd <= count.
                let entry = HTTPHeaderSubstringExtent(start: entryStart, length: entryEnd &- entryStart)
                let key = HTTPHeaderCodeUnits.trim(
                    value,
                    entry.substring(from: 0, length: equalSign &- entryStart, argumentLength: count),
                    HTTPHeaderCodeUnits.isUnicodeCompatibleASCIIWhitespace
                )
                if isFilenameKey(value, key) {
                    var filename = HTTPHeaderCodeUnits.trim(
                        value,
                        entry.substring(from: equalSign &- entryStart &+ 1, argumentLength: count),
                        HTTPHeaderCodeUnits.isUnicodeCompatibleASCIIWhitespace
                    )
                    if filename.length > 1 && HTTPHeaderCodeUnits.value(value[filename.start]) == 0x22 {
                        filename = filename.substring(from: 1, length: filename.length - 2, argumentLength: count)
                    }
                    return filename
                }
            }
        }
        // entryEnd is at most the count.
        entryStart = entryEnd &+ 1
    }
    return nil
}

/// The key `filename`, compared case-sensitively.
private func isFilenameKey<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ value: Span<CodeUnit>,
    _ key: HTTPHeaderSubstringExtent
) -> Bool {
    if key.length != 8 {
        return false
    }
    var index = key.start
    for letter in "filename".utf8 {
        if HTTPHeaderCodeUnits.value(value[index]) != UInt32(letter) {
            return false
        }
        index += 1
    }
    return true
}

/// extractMIMETypeFromMediaType: the extent of the MIME type, which it returns ASCII-lowercased. When the argument is
/// all tabs and spaces it is `(0, length)`, which `String::substring` returns as the argument itself.
@inline(always)
func httpMediaTypeMIMETypeExtent<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ mediaType: Span<CodeUnit>) -> HTTPHeaderSubstringExtent {
    let length = mediaType.count
    var position = 0
    while position < length {
        if !HTTPHeaderCodeUnits.isTabOrSpace(HTTPHeaderCodeUnits.value(mediaType[position])) {
            break
        }
        position += 1
    }
    if position == length {
        return HTTPHeaderSubstringExtent(start: 0, length: length)
    }
    let typeStart = position
    var typeEnd = position
    while position < length {
        let c = HTTPHeaderCodeUnits.value(mediaType[position])
        if c == 0x2C || HTTPHeaderCodeUnits.isTabOrSpace(c) || c == 0x3B {
            break
        }
        position += 1
        typeEnd = position
    }
    // typeEnd is at most the argument's length.
    return HTTPHeaderSubstringExtent(start: typeStart, length: typeEnd &- typeStart)
}

/// extractCharsetFromMediaType: the start and length it gives `StringView::substring`.
@inline(always)
func httpMediaTypeCharsetExtent<CodeUnit: HTTPHeaderStringCodeUnit>(_ mediaType: Span<CodeUnit>) -> HTTPHeaderSubstringExtent {
    // A match of "charset" ends within the argument, so positions here are at most its length: wrapping arithmetic
    // cannot wrap.
    var charsetPosition = 0
    var charsetLength = 0
    var position = 0
    let length = mediaType.count
    while position < length {
        guard let found = findCharsetIgnoringASCIICase(mediaType, from: position), found > 0 else {
            charsetLength = 0
            break
        }
        position = found
        // Is what we found the beginning of a word?
        let previous = HTTPHeaderCodeUnits.value(mediaType[position - 1])
        position &+= 7
        if previous > 0x20 && previous != 0x3B {
            continue
        }
        while position < length {
            if HTTPHeaderCodeUnits.value(mediaType[position]) > 0x20 {
                break
            }
            position += 1
        }
        if position >= length {
            break
        }
        let equalSign = HTTPHeaderCodeUnits.value(mediaType[position])
        position += 1
        if equalSign != 0x3D {
            continue
        }
        while position < length {
            let c = HTTPHeaderCodeUnits.value(mediaType[position])
            if c > 0x20 && c != 0x22 && c != 0x27 {
                break
            }
            // Below the length.
            position &+= 1
        }
        var end = position
        while end < length {
            let c = HTTPHeaderCodeUnits.value(mediaType[end])
            if c <= 0x20 || c == 0x22 || c == 0x27 || c == 0x3B {
                break
            }
            end += 1
        }
        charsetPosition = position
        // end starts at position and only advances.
        charsetLength = end &- position
        break
    }
    return HTTPHeaderSubstringExtent(start: charsetPosition, length: charsetLength)
}

/// StringView::findIgnoringASCIICase("charset"_s, start). Sixteen code units at a time, the word is compared only at
/// the offsets whose code unit is 'c' or 'C'; at the last offsets, fewer than sixteen, it is compared at each.
private func findCharsetIgnoringASCIICase<CodeUnit: HTTPHeaderStringCodeUnit>(_ input: Span<CodeUnit>, from start: Int) -> Int? {
    let count = input.count
    // offset stays at most count, and a candidate below it.
    var offset = start
    while count &- offset >= 16 {
        var candidates = charsetCandidates(input, offset)
        while candidates != 0 {
            let candidate = offset &+ candidates.trailingZeroBitCount
            // A later offset leaves fewer code units still.
            if count &- candidate < 7 {
                return nil
            }
            if isCharsetIgnoringASCIICase(input, candidate) {
                return candidate
            }
            candidates &= candidates - 1
        }
        offset &+= 16
    }
    while count &- offset >= 7 {
        if isCharsetIgnoringASCIICase(input, offset) {
            return offset
        }
        offset += 1
    }
    return nil
}

/// Whether the 7 code units at `offset` are "charset", ignoring ASCII case.
@inline(always)
private func isCharsetIgnoringASCIICase<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ input: Span<CodeUnit>, _ offset: Int) -> Bool {
    var index = offset
    for letter in "charset".utf8 {
        let c = HTTPHeaderCodeUnits.value(input[index])
        if c != UInt32(letter) && c != UInt32(letter) - 0x20 {
            return false
        }
        index += 1
    }
    return true
}

/// A bit for each of the 16 code units at `offset` that is 'c' or 'C', the first one's in bit 0.
@inline(always)
private func charsetCandidates<CodeUnit: HTTPHeaderStringCodeUnit>(_ input: Span<CodeUnit>, _ offset: Int) -> UInt32 {
    let bytes = input.bytes
    if CodeUnit.bitWidth == 8 {
        let difference = (bytes.load(fromByteOffset: offset, as: SIMD16<UInt8>.self) | 0x20) ^ 0x63
        // The top bit of each lane whose difference is zero: the subtraction borrows only out of those.
        let marks = bitCast((difference &- 1) & ~difference & 0x80, to: SIMD2<UInt64>.self)
        let low = UInt64(littleEndian: marks[0])
        let high = UInt64(littleEndian: marks[1])
        if low | high == 0 {
            return 0
        }
        return httpHeaderGatherByteMarks(low) | httpHeaderGatherByteMarks(high) << 8
    }
    // The offset is within the span, whose bytes fit in an Int.
    let byteOffset = offset &* 2
    let first = (bytes.load(fromByteOffset: byteOffset, as: SIMD8<UInt16>.self) | 0x20) ^ 0x63
    let second = (bytes.load(fromByteOffset: byteOffset &+ 16, as: SIMD8<UInt16>.self) | 0x20) ^ 0x63
    let firstMarks = bitCast((first &- 1) & ~first & 0x8000, to: SIMD2<UInt64>.self)
    let secondMarks = bitCast((second &- 1) & ~second & 0x8000, to: SIMD2<UInt64>.self)
    let word0 = UInt64(littleEndian: firstMarks[0])
    let word1 = UInt64(littleEndian: firstMarks[1])
    let word2 = UInt64(littleEndian: secondMarks[0])
    let word3 = UInt64(littleEndian: secondMarks[1])
    if word0 | word1 | word2 | word3 == 0 {
        return 0
    }
    return httpHeaderGatherLaneMarks(word0) | httpHeaderGatherLaneMarks(word1) << 4
        | httpHeaderGatherLaneMarks(word2) << 8 | httpHeaderGatherLaneMarks(word3) << 12
}

/// The top bits of a word's 8 bytes, the first byte's in bit 0, when no other bit is set.
@inline(always)
private func httpHeaderGatherByteMarks(_ word: UInt64) -> UInt32 {
    // Byte k's bit, at 8 * k once shifted, reaches bit 56 + k of the product, which drops what passes bit 63 on
    // purpose, and no two bits of the product meet.
    UInt32(truncatingIfNeeded: ((word &>> 7) &* 0x0102_0408_1020_4080) &>> 56)
}

/// The top bits of a word's four 16-bit lanes, the first lane's in bit 0, when no other bit is set.
@inline(always)
private func httpHeaderGatherLaneMarks(_ word: UInt64) -> UInt32 {
    // Lane k's bit, at 16 * k once shifted, reaches bit 48 + k of the product, which drops what passes bit 63 on
    // purpose, and no two bits of the product meet.
    UInt32(truncatingIfNeeded: ((word &>> 15) &* 0x0001_0002_0004_0008) &>> 48)
}

/// ParsedContentType::parseContentType up to its parameters, over `m_contentType` (the argument already trimmed of
/// whitespace without form feed).
struct HTTPContentTypeHead: Equatable {
    var isValid: Bool
    /// The MIME type before `convertToASCIILowercase`.
    var mimeType: HTTPHeaderSubstringExtent
    /// Where httpContentTypeParameter starts.
    var parametersStart: Int
}

func httpContentTypeHead<CodeUnit: HTTPHeaderStringCodeUnit>(_ contentType: Span<CodeUnit>) -> HTTPContentTypeHead {
    let length = contentType.count
    let invalid = HTTPContentTypeHead(isValid: false, mimeType: HTTPHeaderSubstringExtent(start: 0, length: 0), parametersStart: length)
    var index = 0
    skipContentTypeSpaces(contentType, &index)
    if index >= length {
        return invalid
    }
    let contentTypeStart = index
    guard let type = parseContentTypeToken(contentType, &index, { $0 != 0x2F }), HTTPHeaderCodeUnits.isHTTPToken(contentType, type) else {
        return invalid
    }
    if index >= length || HTTPHeaderCodeUnits.value(contentType[index]) != 0x2F {
        return invalid
    }
    index += 1
    guard let subtype = parseContentTypeToken(contentType, &index, { $0 != 0x3B }, skipTrailingWhitespace: true),
        HTTPHeaderCodeUnits.isHTTPToken(contentType, subtype)
    else {
        return invalid
    }
    // Neither the type nor the subtype holds a ';', so the first one is at or after the subtype's end.
    var semicolon = index
    while semicolon < length {
        if HTTPHeaderCodeUnits.value(contentType[semicolon]) == 0x3B {
            break
        }
        semicolon += 1
    }
    // semicolon is at most the argument's length.
    let mimeType = HTTPHeaderCodeUnits.trim(
        contentType,
        HTTPHeaderSubstringExtent(start: contentTypeStart, length: semicolon &- contentTypeStart),
        HTTPHeaderCodeUnits.isASCIIWhitespaceWithoutFF
    )
    return HTTPContentTypeHead(isValid: true, mimeType: mimeType, parametersStart: semicolon < length ? semicolon + 1 : length)
}

struct HTTPContentTypeParameter: Equatable {
    /// False when there are no more parameters.
    var isPresent: Bool
    var name: HTTPHeaderSubstringExtent
    /// The value's characters: an unquoted value's, or a quoted string's between its quotes, with its escapes.
    var value: HTTPHeaderSubstringExtent
    /// Whether the value is a quoted string with an escape: its String leaves out each backslash that escapes a
    /// character.
    var valueHasEscapes: Bool
    /// Whether the value's String is 16-bit: as `collectHTTPQuotedString()` decides for a quoted string, else the
    /// argument's width.
    var isValue16Bit: Bool
    /// Whether the parameter is kept when its name is not already in the map: the name is an HTTP token, and every
    /// character of the value is a quoted-string token character.
    var isAcceptable: Bool
    /// Where the next call starts.
    var next: Int
}

/// One pass of parseContentType's parameter loop from `start`, up to the next parameter that has a name and a value.
func httpContentTypeParameter<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ contentType: Span<CodeUnit>,
    from start: Int
) -> HTTPContentTypeParameter {
    let length = contentType.count
    let end = HTTPContentTypeParameter(
        isPresent: false,
        name: HTTPHeaderSubstringExtent(start: 0, length: 0),
        value: HTTPHeaderSubstringExtent(start: 0, length: 0),
        valueHasEscapes: false,
        isValue16Bit: false,
        isAcceptable: false,
        next: length
    )
    var index = start
    while true {
        skipContentTypeSpaces(contentType, &index)
        let key = parseContentTypeToken(contentType, &index, { $0 != 0x3B && $0 != 0x3D })
        if index >= length {
            return end
        }
        // The key stops only at ';' or '=', so the separator is one of them.
        let separator = HTTPHeaderCodeUnits.value(contentType[index])
        index += 1
        if separator == 0x3B {
            continue
        }
        let value: HTTPContentTypeParameterValue
        if index < length && HTTPHeaderCodeUnits.value(contentType[index]) == 0x22 {
            value = collectHTTPQuotedString(contentType, &index)
            _ = parseContentTypeToken(contentType, &index, { $0 != 0x3B })
        } else {
            guard let valueRange = parseContentTypeToken(contentType, &index, { $0 != 0x3B }, skipTrailingWhitespace: true) else {
                continue
            }
            value = HTTPContentTypeParameterValue(content: valueRange, hasEscapes: false, is16Bit: CodeUnit.bitWidth > 8)
        }
        if let key {
            let isAcceptable =
                HTTPHeaderCodeUnits.isHTTPToken(contentType, key) && !containsNonQuoteStringTokenCharacters(contentType, value.content)
            return HTTPContentTypeParameter(
                isPresent: true,
                name: key,
                value: value.content,
                valueHasEscapes: value.hasEscapes,
                isValue16Bit: value.is16Bit,
                isAcceptable: isAcceptable,
                next: index
            )
        }
        if index >= length {
            return end
        }
    }
}

private func skipContentTypeSpaces<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ input: Span<CodeUnit>, _ index: inout Int) {
    while index < input.count {
        if !HTTPHeaderCodeUnits.isASCIIWhitespaceWithoutFF(HTTPHeaderCodeUnits.value(input[index])) {
            return
        }
        index += 1
    }
}

/// The token at `index` whose characters meet the condition, or nil when there is none. Trimming trailing whitespace
/// moves `index` back too.
@inline(always)
private func parseContentTypeToken<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ input: Span<CodeUnit>,
    _ index: inout Int,
    _ characterMeetsCondition: (UInt32) -> Bool,
    skipTrailingWhitespace: Bool = false
) -> HTTPHeaderSubstringExtent? {
    let length = input.count
    let tokenStart = index
    if index >= length {
        return nil
    }
    while index < length {
        if !characterMeetsCondition(HTTPHeaderCodeUnits.value(input[index])) {
            break
        }
        index += 1
    }
    if index == tokenStart {
        return nil
    }
    if skipTrailingWhitespace {
        // The character before the token is '/' or '=', so this stops at the token's start, and index stays above 0.
        while HTTPHeaderCodeUnits.isASCIIWhitespaceWithoutFF(HTTPHeaderCodeUnits.value(input[index - 1])) {
            index -= 1
        }
    }
    return HTTPHeaderSubstringExtent(start: tokenStart, length: index &- tokenStart)
}

/// A parameter's value: its characters in the argument, and the String to make of them.
private struct HTTPContentTypeParameterValue {
    var content: HTTPHeaderSubstringExtent
    var hasEscapes: Bool
    var is16Bit: Bool
}

/// The quoted string whose opening quote is at `index`. In a 16-bit argument its String is 16-bit when two unescaped
/// characters are adjacent, or one is above U+00FF.
private func collectHTTPQuotedString<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ input: Span<CodeUnit>,
    _ index: inout Int
) -> HTTPContentTypeParameterValue {
    // Positions here are at most the argument's length: wrapping arithmetic cannot wrap.
    let length = input.count
    let isInput16Bit = CodeUnit.bitWidth > 8
    let contentStart = index + 1
    var position = contentStart
    var contentEnd = length
    var hasEscapes = false
    var is16Bit = false
    while true {
        let runStart = position
        while position < length {
            let c = HTTPHeaderCodeUnits.value(input[position])
            if c == 0x22 || c == 0x5C {
                break
            }
            position += 1
        }
        let runLength = position &- runStart
        if isInput16Bit && (runLength > 1 || (runLength == 1 && HTTPHeaderCodeUnits.value(input[runStart]) > 0xFF)) {
            is16Bit = true
        }
        if position >= length {
            break
        }
        let quoteOrBackslash = HTTPHeaderCodeUnits.value(input[position])
        position += 1
        if quoteOrBackslash == 0x5C {
            // A backslash at the end is kept as it is.
            if position >= length {
                break
            }
            if HTTPHeaderCodeUnits.value(input[position]) > 0xFF {
                is16Bit = true
            }
            hasEscapes = true
            position += 1
        } else {
            contentEnd = position - 1
            break
        }
    }
    index = position
    return HTTPContentTypeParameterValue(
        content: HTTPHeaderSubstringExtent(start: contentStart, length: contentEnd &- contentStart),
        hasEscapes: hasEscapes,
        is16Bit: is16Bit
    )
}

/// Whether a code unit of the value is not a quoted-string character (tab, U+0020-U+007E, U+0080-U+00FF).
private func containsNonQuoteStringTokenCharacters<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ input: Span<CodeUnit>,
    _ value: HTTPHeaderSubstringExtent
) -> Bool {
    var index = value.start
    while index < value.end {
        if !isQuotedStringTokenCharacter(HTTPHeaderCodeUnits.value(input[index])) {
            return true
        }
        index += 1
    }
    return false
}

@inline(always)
private func isQuotedStringTokenCharacter(_ c: UInt32) -> Bool {
    (c >= 0x20 && c <= 0x7E) || (c >= 0x80 && c <= 0xFF) || c == 0x09
}

// Ranges and lengths: HTTPParsers' parseRange and parseContentLength, and ParsedContentRange.

/// ParsedContentRange::unknownLength.
let httpContentRangeUnknownLength = Int64.max
/// ParsedContentRange::invalidLength.
let httpContentRangeInvalidLength = Int64.min

/// WTF::parseInteger<uint64_t> with its defaults (base 10, whitespace allowed) over an extent: leading and trailing
/// Unicode-compatible ASCII whitespace, one optional '+', and nil on overflow.
func parseHTTPHeaderUInt64<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ extent: HTTPHeaderSubstringExtent
) -> UInt64? {
    let end = extent.end
    var index = extent.start
    while index < end {
        if !HTTPHeaderCodeUnits.isUnicodeCompatibleASCIIWhitespace(HTTPHeaderCodeUnits.value(characters[index])) {
            break
        }
        index += 1
    }
    if index < end && HTTPHeaderCodeUnits.value(characters[index]) == 0x2B {
        index += 1
    }
    if index >= end || !HTTPHeaderCodeUnits.isASCIIDigit(HTTPHeaderCodeUnits.value(characters[index])) {
        return nil
    }
    var value: UInt64 = 0
    var hasOverflowed = false
    while index < end {
        let c = HTTPHeaderCodeUnits.value(characters[index])
        if !HTTPHeaderCodeUnits.isASCIIDigit(c) {
            break
        }
        let (product, productOverflowed) = value.multipliedReportingOverflow(by: 10)
        let (sum, sumOverflowed) = product.addingReportingOverflow(UInt64(c - 0x30))
        value = sum
        if productOverflowed || sumOverflowed {
            hasOverflowed = true
        }
        index += 1
    }
    if hasOverflowed {
        return nil
    }
    while index < end {
        if !HTTPHeaderCodeUnits.isUnicodeCompatibleASCIIWhitespace(HTTPHeaderCodeUnits.value(characters[index])) {
            return nil
        }
        index += 1
    }
    return value
}

/// parseRange's HTTPRange: nil ends are absent ones.
struct HTTPRangeValue: Equatable {
    var isValid: Bool
    var start: UInt64?
    var end: UInt64?
}

/// parseRange (https://fetch.spec.whatwg.org/#simple-range-header-value).
func httpRangeValue<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ range: Span<CodeUnit>, allowWhitespace: Bool) -> HTTPRangeValue {
    let invalid = HTTPRangeValue(isValid: false, start: nil, end: nil)
    let length = range.count
    if length < 5 {
        return invalid
    }
    var index = 0
    for letter in "bytes".utf8 {
        if HTTPHeaderCodeUnits.value(range[index]) != UInt32(letter) {
            return invalid
        }
        index += 1
    }
    skipRangeWhitespace(range, &index, allowWhitespace)
    if index >= length || HTTPHeaderCodeUnits.value(range[index]) != 0x3D {
        return invalid
    }
    index += 1
    skipRangeWhitespace(range, &index, allowWhitespace)
    let startDigits = collectHTTPHeaderDigitRun(range, from: index)
    index = startDigits.end
    skipRangeWhitespace(range, &index, allowWhitespace)
    if index >= length || HTTPHeaderCodeUnits.value(range[index]) != 0x2D {
        return invalid
    }
    index += 1
    skipRangeWhitespace(range, &index, allowWhitespace)
    let endDigits = collectHTTPHeaderDigitRun(range, from: index)
    if endDigits.end != length {
        return invalid
    }
    if startDigits.length == 0 && endDigits.length == 0 {
        return invalid
    }
    var start: UInt64?
    if startDigits.length != 0 {
        guard let value = httpHeaderDigitRunValue(range, startDigits) else {
            return invalid
        }
        start = value
    }
    var end: UInt64?
    if endDigits.length != 0 {
        guard let value = httpHeaderDigitRunValue(range, endDigits) else {
            return invalid
        }
        end = value
    }
    if let start, let end, start > end {
        return invalid
    }
    return HTTPRangeValue(isValid: true, start: start, end: end)
}

/// Only tab and space, and only where the caller allows them: newlines are gone from a header value by then.
@inline(always)
private func skipRangeWhitespace<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ range: Span<CodeUnit>,
    _ index: inout Int,
    _ allowWhitespace: Bool
) {
    if !allowWhitespace {
        return
    }
    while index < range.count {
        if !HTTPHeaderCodeUnits.isTabOrSpace(HTTPHeaderCodeUnits.value(range[index])) {
            return
        }
        index += 1
    }
}

/// A run of ASCII digits, and its value when it has 18 digits or fewer.
private struct HTTPHeaderDigitRun {
    var start: Int
    var end: Int
    var value: UInt64

    @inline(always)
    var length: Int {
        // A run ends at or after its start.
        end &- start
    }

    @inline(always)
    var isShort: Bool {
        length <= 18
    }

    @inline(always)
    var extent: HTTPHeaderSubstringExtent {
        HTTPHeaderSubstringExtent(start: start, length: length)
    }
}

/// The run of ASCII digits at `start`. Its first 18 digits are added up as they are found: they are below 10^18, so
/// they need no overflow check. A longer run is parsed again by the caller.
@inline(always)
private func collectHTTPHeaderDigitRun<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    from start: Int
) -> HTTPHeaderDigitRun {
    var index = start
    var value: UInt64 = 0
    var digitsLeft = 18
    while index < characters.count && digitsLeft > 0 {
        let c = HTTPHeaderCodeUnits.value(characters[index])
        if !HTTPHeaderCodeUnits.isASCIIDigit(c) {
            return HTTPHeaderDigitRun(start: start, end: index, value: value)
        }
        // At most 18 digits are added up, so the value stays below 10^18.
        value = value &* 10 &+ UInt64(c - 0x30)
        digitsLeft -= 1
        index += 1
    }
    while index < characters.count {
        if !HTTPHeaderCodeUnits.isASCIIDigit(HTTPHeaderCodeUnits.value(characters[index])) {
            break
        }
        index += 1
    }
    return HTTPHeaderDigitRun(start: start, end: index, value: value)
}

/// `parseInteger<uint64_t>` of a digit run: nil on overflow.
@inline(always)
private func httpHeaderDigitRunValue<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ digits: HTTPHeaderDigitRun
) -> UInt64? {
    if digits.isShort {
        return digits.value
    }
    return parseHTTPHeaderUInt64(characters, digits.extent)
}

/// parseContentLength: comma-separated values that must all be equal. A value that does not parse is skipped before
/// the first one that does, and fails the header after it.
func httpContentLengthValue<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ httpContentLengthValue: Span<CodeUnit>) -> UInt64? {
    let count = httpContentLengthValue.count
    var value: UInt64?
    var tokenStart = 0
    // StringView::split(','), which skips empty entries.
    while tokenStart < count {
        // A value of 18 digits or fewer, the usual one, is parsed as its digits are found. Any other is found first and
        // parsed with parseInteger's whitespace, '+' and overflow rules.
        let digits = collectHTTPHeaderDigitRun(httpContentLengthValue, from: tokenStart)
        var tokenEnd = digits.end
        let expectedContentLength: UInt64?
        if digits.length != 0 && digits.isShort
            && (tokenEnd == count || HTTPHeaderCodeUnits.value(httpContentLengthValue[tokenEnd]) == 0x2C)
        {
            expectedContentLength = digits.value
        } else {
            while tokenEnd < count {
                if HTTPHeaderCodeUnits.value(httpContentLengthValue[tokenEnd]) == 0x2C {
                    break
                }
                tokenEnd += 1
            }
            if tokenEnd == tokenStart {
                // tokenEnd is at most count.
                tokenStart = tokenEnd &+ 1
                continue
            }
            // tokenEnd is at most count.
            expectedContentLength = parseHTTPHeaderUInt64(
                httpContentLengthValue,
                HTTPHeaderSubstringExtent(start: tokenStart, length: tokenEnd &- tokenStart)
            )
        }
        if let expectedContentLength {
            if let value, value != expectedContentLength {
                return nil
            }
            value = expectedContentLength
        } else if value != nil {
            return nil
        }
        // tokenEnd is at most count.
        tokenStart = tokenEnd &+ 1
    }
    return value
}

/// ParsedContentRange's members after its String constructor: the positions it parsed before it failed stay, and an
/// invalid range has `httpContentRangeInvalidLength` as its instance length.
struct HTTPContentRangeValues: Equatable {
    var firstBytePosition: Int64
    var lastBytePosition: Int64
    var instanceLength: Int64
}

/// ParsedContentRange(const String&): `bytes <first>-<last>/<length or *>`.
func httpContentRangeValues<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ headerValue: Span<CodeUnit>) -> HTTPContentRangeValues {
    var result = HTTPContentRangeValues(firstBytePosition: 0, lastBytePosition: 0, instanceLength: httpContentRangeInvalidLength)
    let length = headerValue.count
    if length < 6 {
        return result
    }
    var index = 0
    for letter in "bytes ".utf8 {
        if HTTPHeaderCodeUnits.value(headerValue[index]) != UInt32(letter) {
            return result
        }
        index += 1
    }
    // A value whose numbers have 18 digits or fewer, the usual one, is parsed as its digits are found. Any other is
    // parsed as the separators are found first, with the fields parsed before a failure kept.
    let first = collectHTTPHeaderDigitRun(headerValue, from: 6)
    if first.length != 0 && first.isShort && first.end < length && HTTPHeaderCodeUnits.value(headerValue[first.end]) == 0x2D {
        let last = collectHTTPHeaderDigitRun(headerValue, from: first.end + 1)
        if last.length != 0 && last.isShort && last.end < length && HTTPHeaderCodeUnits.value(headerValue[last.end]) == 0x2F {
            let instanceStart = last.end + 1
            var instanceLength: Int64?
            if instanceStart == length - 1 && HTTPHeaderCodeUnits.value(headerValue[instanceStart]) == 0x2A {
                instanceLength = httpContentRangeUnknownLength
            } else {
                let instance = collectHTTPHeaderDigitRun(headerValue, from: instanceStart)
                if instance.length != 0 && instance.isShort && instance.end == length {
                    // A short run's value is below 10^18.
                    instanceLength = Int64(truncatingIfNeeded: instance.value)
                }
            }
            if let instanceLength {
                // A short run's value is below 10^18.
                result.firstBytePosition = Int64(truncatingIfNeeded: first.value)
                result.lastBytePosition = Int64(truncatingIfNeeded: last.value)
                if httpContentRangeValuesAreValid(
                    firstBytePosition: result.firstBytePosition,
                    lastBytePosition: result.lastBytePosition,
                    instanceLength: instanceLength
                ) {
                    result.instanceLength = instanceLength
                }
                return result
            }
        }
    }
    guard let byteSeparator = findContentRangeCharacter(headerValue, 0x2D, from: 6),
        let instanceLengthSeparator = findContentRangeCharacter(headerValue, 0x2F, from: byteSeparator + 1)
    else {
        return result
    }
    guard let firstBytePosition = parseContentRangeDigits(headerValue, HTTPHeaderSubstringExtent(start: 6, length: byteSeparator - 6))
    else {
        return result
    }
    result.firstBytePosition = firstBytePosition
    guard
        let lastBytePosition = parseContentRangeDigits(
            headerValue,
            HTTPHeaderSubstringExtent(start: byteSeparator + 1, length: instanceLengthSeparator - (byteSeparator + 1))
        )
    else {
        return result
    }
    result.lastBytePosition = lastBytePosition
    let instance = HTTPHeaderSubstringExtent(start: instanceLengthSeparator + 1, length: length - (instanceLengthSeparator + 1))
    let instanceLength: Int64
    if instance.length == 1 && HTTPHeaderCodeUnits.value(headerValue[instance.start]) == 0x2A {
        instanceLength = httpContentRangeUnknownLength
    } else {
        guard let value = parseContentRangeDigits(headerValue, instance) else {
            return result
        }
        instanceLength = value
    }
    if httpContentRangeValuesAreValid(
        firstBytePosition: firstBytePosition,
        lastBytePosition: lastBytePosition,
        instanceLength: instanceLength
    ) {
        result.instanceLength = instanceLength
    }
    return result
}

private func findContentRangeCharacter<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ headerValue: Span<CodeUnit>,
    _ character: UInt32,
    from start: Int
) -> Int? {
    var index = start
    while index < headerValue.count {
        if HTTPHeaderCodeUnits.value(headerValue[index]) == character {
            return index
        }
        index += 1
    }
    return nil
}

/// `containsOnly<isASCIIDigit>()` then `parseInteger<int64_t>`: nil when empty, when a character is not a digit, or on
/// overflow.
private func parseContentRangeDigits<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ headerValue: Span<CodeUnit>,
    _ extent: HTTPHeaderSubstringExtent
) -> Int64? {
    if extent.length == 0 {
        return nil
    }
    var value: Int64 = 0
    var hasOverflowed = false
    var index = extent.start
    while index < extent.end {
        let c = HTTPHeaderCodeUnits.value(headerValue[index])
        if !HTTPHeaderCodeUnits.isASCIIDigit(c) {
            return nil
        }
        let (product, productOverflowed) = value.multipliedReportingOverflow(by: 10)
        let (sum, sumOverflowed) = product.addingReportingOverflow(Int64(c - 0x30))
        value = sum
        if productOverflowed || sumOverflowed {
            hasOverflowed = true
        }
        index += 1
    }
    return hasOverflowed ? nil : value
}

/// areContentRangeValuesValid, which ParsedContentRange(int64_t, int64_t, int64_t) applies too.
func httpContentRangeValuesAreValid(firstBytePosition: Int64, lastBytePosition: Int64, instanceLength: Int64) -> Bool {
    if firstBytePosition < 0 {
        return false
    }
    if lastBytePosition < firstBytePosition {
        return false
    }
    if instanceLength == httpContentRangeUnknownLength {
        return true
    }
    return lastBytePosition < instanceLength
}

/// ParsedContentRange::headerValue's characters are put together in this. A valid range's positions and length are
/// not negative, so they have at most 19 digits each, and its value at most 65 characters.
typealias HTTPContentRangeHeaderValueBuffer = InlineArray<65, UInt8>

/// Writes ParsedContentRange::headerValue's characters for a valid range so that they end at the end of `text`, and
/// returns where they start.
@inline(always)
func writeHTTPContentRangeHeaderValue(
    _ text: inout MutableSpan<UInt8>,
    firstBytePosition: Int64,
    lastBytePosition: Int64,
    instanceLength: Int64
) -> Int {
    var position = text.count
    if instanceLength == httpContentRangeUnknownLength {
        position -= 2
        text[position] = 0x2F
        text[position + 1] = 0x2A
    } else {
        position = writeDecimal(&text, endingAt: position, instanceLength)
        position -= 1
        text[position] = 0x2F
    }
    position = writeDecimal(&text, endingAt: position, lastBytePosition)
    position -= 1
    text[position] = 0x2D
    position = writeDecimal(&text, endingAt: position, firstBytePosition)
    position -= 6
    var index = position
    for letter in "bytes ".utf8 {
        text[index] = letter
        index += 1
    }
    return position
}

/// Writes the decimal form of `value` so that it ends before `end` in `text`, and returns where it starts.
@inline(always)
private func writeDecimal(_ text: inout MutableSpan<UInt8>, endingAt end: Int, _ value: Int64) -> Int {
    var position = end
    var magnitude = value.magnitude
    repeat {
        position -= 1
        text[position] = UInt8(truncatingIfNeeded: magnitude % 10) + 0x30
        magnitude /= 10
    } while magnitude != 0
    if value < 0 {
        position -= 1
        text[position] = 0x2D
    }
    return position
}

// Header lines: HTTPParsers' parseHTTPHeader, which the WebSocket handshake applies to each response line.

/// Which of parseHTTPHeader's failure messages, each followed by the input from where it fails, cut at 128 bytes with an
/// ellipsis, where it has one.
enum HTTPHeaderLineFailure: UInt8 {
    case none
    /// "CR doesn't follow LF in header name at "
    case crDoesNotFollowLFInName
    /// "Unexpected CR in header name at "
    case unexpectedCRInName
    /// "Unexpected LF in header name at "
    case unexpectedLFInName
    /// "Unexpected start character in header name", with nothing after it.
    case unexpectedStartCharacterInName
    /// "Unexpected character in header name at "
    case unexpectedCharacterInName
    /// "Unexpected LF in header value at "
    case unexpectedLFInValue
    /// "CR doesn't follow LF after header value at "
    case crDoesNotFollowLFAfterValue
    /// "Invalid UTF-8 sequence in header value", with nothing after it.
    case invalidUTF8InValue
}

struct HTTPHeaderLine: Equatable {
    /// What parseHTTPHeader returns: 0 on failure, 2 for an empty line, and otherwise the offset of the LF that ends
    /// the line in strict mode, or the offset after the CR or LF that ends it in lenient mode.
    var consumed: Int
    var failure: HTTPHeaderLineFailure
    /// The input the message ends with, before it is cut.
    var sample: HTTPHeaderSubstringExtent
    /// `nameStr`'s extent, or nil when it is the null view.
    var name: HTTPHeaderSubstringExtent?
    /// The value's bytes, for `String::fromUTF8`, or nil when `valueStr` stays null. A value that is not UTF-8 makes
    /// `fromUTF8` return null, which is the invalid-UTF-8 failure. An empty value is that failure too.
    var value: HTTPHeaderSubstringExtent?
}

/// parseHTTPHeader(data, failureReason, nameStr, valueStr, strict).
func httpHeaderLine(_ data: Span<UInt8>, strict: Bool) -> HTTPHeaderLine {
    let count = data.count
    let noSample = HTTPHeaderSubstringExtent(start: 0, length: 0)
    // The name is the token characters the line starts with.
    var position = HTTPHeaderCodeUnits.firstIndex(notOf: HTTPHeaderTokenCharacters.self, in: data, from: 0, to: count)
    let nameSize = position

    if position < count {
        switch data[position] {
        case 0x0D:
            if nameSize == 0 {
                if count - position > 1 && data[position + 1] == 0x0A {
                    return HTTPHeaderLine(consumed: position + 2, failure: .none, sample: noSample, name: nil, value: nil)
                }
                return HTTPHeaderLine(
                    consumed: 0,
                    failure: .crDoesNotFollowLFInName,
                    sample: HTTPHeaderSubstringExtent(start: position, length: count - position),
                    name: nil,
                    value: nil
                )
            }
            return HTTPHeaderLine(
                consumed: 0,
                failure: .unexpectedCRInName,
                sample: HTTPHeaderSubstringExtent(start: 0, length: nameSize),
                name: nil,
                value: nil
            )
        case 0x0A:
            return HTTPHeaderLine(
                consumed: 0,
                failure: .unexpectedLFInName,
                sample: HTTPHeaderSubstringExtent(start: 0, length: nameSize),
                name: nil,
                value: nil
            )
        case 0x3A:
            position += 1
        default:
            if nameSize < 1 {
                return HTTPHeaderLine(consumed: 0, failure: .unexpectedStartCharacterInName, sample: noSample, name: nil, value: nil)
            }
            return HTTPHeaderLine(
                consumed: 0,
                failure: .unexpectedCharacterInName,
                sample: HTTPHeaderSubstringExtent(start: 0, length: nameSize),
                name: nil,
                value: nil
            )
        }
    }

    let name: HTTPHeaderSubstringExtent? = nameSize > 0 ? HTTPHeaderSubstringExtent(start: 0, length: nameSize) : nil

    while position < count {
        if data[position] != 0x20 {
            break
        }
        position += 1
    }

    let valueStart = position
    // The value ends at the first CR or LF, which the line consumes.
    let valueEnd = HTTPHeaderCodeUnits.firstIndex(of: HTTPHeaderLineBreaks.self, in: data, from: valueStart, to: count)
    position = valueEnd
    if position < count {
        if data[position] == 0x0A && strict {
            return HTTPHeaderLine(
                consumed: 0,
                failure: .unexpectedLFInValue,
                sample: HTTPHeaderSubstringExtent(start: valueStart, length: position - valueStart),
                name: name,
                value: nil
            )
        }
        position += 1
    }
    if position >= count || (strict && data[position] != 0x0A) {
        return HTTPHeaderLine(
            consumed: 0,
            failure: .crDoesNotFollowLFAfterValue,
            sample: HTTPHeaderSubstringExtent(start: position, length: count - position),
            name: name,
            value: nil
        )
    }
    // "Name:" and "Name:   " fail as invalid UTF-8: String::fromUTF8 returns null for an empty span with no data.
    if valueEnd == valueStart {
        return HTTPHeaderLine(consumed: 0, failure: .invalidUTF8InValue, sample: noSample, name: name, value: nil)
    }
    // Cannot overflow: the value's end is at or after its start.
    return HTTPHeaderLine(
        consumed: position,
        failure: .none,
        sample: noSample,
        name: name,
        value: HTTPHeaderSubstringExtent(start: valueStart, length: valueEnd &- valueStart)
    )
}

// parseHTTPDate's input: the bytes `String::utf8()` gives, which parseHTTPDate hands to `WTF::parseDate` as they are.

/// `String::utf8()` (lenient conversion) of a String's characters: Latin-1 and UTF-16 to UTF-8, each unpaired
/// surrogate as U+FFFD, written to the start of `bytes`, which has three bytes for each code unit. Returns the number
/// of bytes written.
@inline(always)
func httpDateUTF8Bytes<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ value: Span<CodeUnit>,
    into bytes: inout MutableSpan<UInt8>
) -> Int {
    var length = 0
    let count = value.count
    var index = 0
    while index < count {
        var codePoint = UInt32(HTTPHeaderCodeUnits.value(value[index]))
        index += 1
        if codePoint & 0xF800 == 0xD800 {
            if codePoint <= 0xDBFF && index < count {
                let trail = UInt32(HTTPHeaderCodeUnits.value(value[index]))
                if trail & 0xFC00 == 0xDC00 {
                    index += 1
                    codePoint = 0x10000 + ((codePoint - 0xD800) << 10) + (trail - 0xDC00)
                } else {
                    codePoint = 0xFFFD
                }
            } else {
                codePoint = 0xFFFD
            }
        }
        if codePoint < 0x80 {
            bytes[length] = UInt8(truncatingIfNeeded: codePoint)
            length += 1
        } else if codePoint < 0x800 {
            bytes[length] = UInt8(truncatingIfNeeded: 0xC0 | (codePoint >> 6))
            length += 1
            bytes[length] = UInt8(truncatingIfNeeded: 0x80 | (codePoint & 0x3F))
            length += 1
        } else if codePoint < 0x10000 {
            bytes[length] = UInt8(truncatingIfNeeded: 0xE0 | (codePoint >> 12))
            length += 1
            bytes[length] = UInt8(truncatingIfNeeded: 0x80 | ((codePoint >> 6) & 0x3F))
            length += 1
            bytes[length] = UInt8(truncatingIfNeeded: 0x80 | (codePoint & 0x3F))
            length += 1
        } else {
            bytes[length] = UInt8(truncatingIfNeeded: 0xF0 | (codePoint >> 18))
            length += 1
            bytes[length] = UInt8(truncatingIfNeeded: 0x80 | ((codePoint >> 12) & 0x3F))
            length += 1
            bytes[length] = UInt8(truncatingIfNeeded: 0x80 | ((codePoint >> 6) & 0x3F))
            length += 1
            bytes[length] = UInt8(truncatingIfNeeded: 0x80 | (codePoint & 0x3F))
            length += 1
        }
    }
    return length
}
