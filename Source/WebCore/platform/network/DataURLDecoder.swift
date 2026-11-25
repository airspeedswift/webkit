// Copyright (C) 2015 Apple Inc. All rights reserved.
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
internal import WebCore_Private.Core.DataURLDecoder
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.URL
internal import wtf.Core.Vector
internal import wtf.Core.text.WTFString
#if WTF_PLATFORM_COCOA
internal import wtf.Core.cocoa.RuntimeApplicationChecksCocoa
#endif

extension WebCore.DataURLDecoder {
    /// Decodes a data: URL, or returns nothing when it is malformed.
    @cxx
    @implementation
    public static func decode(
        _ url: WTF.URL,
        _ shouldValidatePadding: ShouldValidatePadding
    ) -> OptionalResult {
        assert(url.protocolIsData())

        let urlString = WebCore.DataURLDecoder.urlString(url)
        guard let header = DataURLHeader(urlString) else {
            return WebCore.DataURLDecoder.OptionalResult()
        }

        let encodedDataString = header.shouldRemoveFragmentIdentifier ? url.stringWithoutFragmentIdentifier() : urlString
        var result = WebCore.DataURLDecoder.parseMediaType(header.mediaType)

        if header.isBase64 {
            if !WebCore.DataURLDecoder.decodeBase64Data(&result, encodedDataString, header.encodedDataStart, shouldValidatePadding) {
                return WebCore.DataURLDecoder.OptionalResult()
            }
        } else {
            WebCore.DataURLDecoder.decodePercentEncodedData(&result, encodedDataString, header.encodedDataStart)
        }

        result.data.shrinkToFit()
        return WebCore.DataURLDecoder.OptionalResult(result)
    }
}

private struct DataURLHeader {
    private static let dataString: [UInt8] = Array("data:".utf8)
    private static let base64: [UInt8] = Array("base64".utf8)
    private static let textPlain: [UInt8] = Array("text/plain".utf8)
    private static let comma = UInt32(UInt8(ascii: ","))
    private static let numberSign = UInt32(UInt8(ascii: "#"))
    private static let semicolon = UInt32(UInt8(ascii: ";"))

    let encodedDataStart: Int
    let isBase64: Bool
    let mediaType: WTF.String
    let shouldRemoveFragmentIdentifier: Bool

    init?(_ urlString: borrowing WTF.String) {
        if urlString.isEmpty() {
            return nil
        }
        if urlString.is8Bit() {
            let characters: Span<UInt8> = WTF.bytesOfLatin1Characters(urlString.span8())
            self.init(characters)
        } else {
            let characters: Span<UInt16> = urlString.checkedSpan16()
            self.init(characters)
        }
    }

    private init?<CodeUnit: HTTPHeaderStringCodeUnit>(_ characters: Span<CodeUnit>) {
        // Syntax:
        //  url := data:<header>,<encodedData>
        //  header := [<mediatype>][;base64]
        //  mediatype := [<mimetype>][;charset=<charsettype>]

        assert(HTTPHeaderCodeUnits.equal(characters.extracting(first: Self.dataString.count), Self.dataString.span))

        let headerStart = Self.dataString.count
        let headerEnd = HTTPHeaderCodeUnits.find(Self.comma, in: characters, from: headerStart)
        if headerEnd == characters.count {
            return nil
        }
        if HTTPHeaderCodeUnits.find(Self.numberSign, in: characters.extracting(first: headerEnd), from: 0) < headerEnd {
            return nil
        }
        encodedDataStart = headerEnd + 1

        let header = characters.extracting(headerStart..<headerEnd)

        // There might one or two semicolons in the header, find the last one.
        let mediaTypeEnd = header.indices.last { HTTPHeaderCodeUnits.value(header[$0]) == Self.semicolon } ?? header.count

        // formatTypeStart might be at the begining of "base64" or "charset=...".
        let formatTypeStart = mediaTypeEnd + 1
        let formatType = Self.trimmingASCIIWhitespaceWithoutFF(header.extracting(droppingFirst: formatTypeStart))

        let isBase64 = HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(formatType, Self.base64.span)
        self.isBase64 = isBase64

        // If header does not end with "base64", mediaType should be the whole header.
        let mediaTypeCharacters = Self.trimmingASCIIWhitespaceWithoutFF(isBase64 ? header.extracting(first: mediaTypeEnd) : header)
        if !mediaTypeCharacters.isEmpty && HTTPHeaderCodeUnits.value(mediaTypeCharacters[0]) == Self.semicolon {
            var prefixedCharacters = Self.textPlain.map { CodeUnit($0) }
            for index in mediaTypeCharacters.indices {
                prefixedCharacters.append(mediaTypeCharacters[index])
            }
            mediaType = CodeUnit.httpHeaderString(prefixedCharacters.span)
            shouldRemoveFragmentIdentifier = Self.shouldRemoveFragmentIdentifier(prefixedCharacters.span)
        } else {
            mediaType = CodeUnit.httpHeaderString(mediaTypeCharacters)
            shouldRemoveFragmentIdentifier = Self.shouldRemoveFragmentIdentifier(mediaTypeCharacters)
        }
    }

    @_lifetime(copy characters)
    private static func trimmingASCIIWhitespaceWithoutFF<CodeUnit: HTTPHeaderStringCodeUnit>(
        _ characters: Span<CodeUnit>
    ) -> Span<CodeUnit> {
        characters.extracting(HTTPHeaderCodeUnits.trim(characters, characters.indices, HTTPHeaderCodeUnits.isASCIIWhitespaceWithoutFF))
    }

    #if WTF_PLATFORM_COCOA
    private static let videoMPEGURL: [UInt8] = Array("video/mpegurl".utf8)
    private static let audioMPEGURL: [UInt8] = Array("audio/mpegurl".utf8)
    private static let applicationXMPEGURL: [UInt8] = Array("application/x-mpegurl".utf8)
    private static let vndAppleMPEGURL: [UInt8] = Array("vnd.apple.mpegurl".utf8)
    #endif

    private static func shouldRemoveFragmentIdentifier<CodeUnit: FixedWidthInteger & UnsignedInteger>(
        _ mediaType: Span<CodeUnit>
    ) -> Bool {
        #if WTF_PLATFORM_COCOA
        if !WTF.linkedOnOrAfterSDKWithBehavior(.DataURLFragmentRemoval) {
            return false
        }

        // HLS uses # in the middle of the manifests.
        return !HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(mediaType, videoMPEGURL.span)
            && !HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(mediaType, audioMPEGURL.span)
            && !HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(mediaType, applicationXMPEGURL.span)
            && !HTTPHeaderCodeUnits.equalLettersIgnoringASCIICase(mediaType, vndAppleMPEGURL.span)
        #else
        return true
        #endif
    }
}
