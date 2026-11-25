// Copyright (C) 2010 Google Inc. All rights reserved.
// Copyright (C) 2013-2020 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//     * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

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
internal import CxxStdlib
internal import WebCore_Private.Core.BlobData
internal import WebCore_Private.Core.BlobDataFileReference
internal import WebCore_Private.Core.BlobPart
internal import WebCore_Private.Core.BlobRegistryImpl
internal import wtf.Core.MainThread

extension WebCore.BlobData {
    fileprivate func appendData(_ data: WebCore.DataSegment, offset: Int64, length: Int64) {
        appendData(consuming: WebCore.BlobRegistryImpl.RefDataSegment(data), offset, length)
    }

    fileprivate func appendFile(_ file: WebCore.BlobDataFileReference, offset: Int64, length: Int64) {
        appendFile(consuming: WebCore.BlobRegistryImpl.RefBlobDataFileReference(file), offset, length)
    }

    // The sum of the item lengths, wrapping on overflow.
    fileprivate var totalLength: UInt64 {
        var result: UInt64 = 0
        for index in 0..<itemCount() {
            result = result &+ UInt64(bitPattern: self[index].length())
        }
        return result
    }
}

extension WebCore.BlobDataItem {
    enum Content {
        case data(WebCore.DataSegment)
        case file(WebCore.BlobDataFileReference)
    }

    var content: Content {
        if let data = dataSegment() {
            return .data(data)
        }
        guard let file = file() else {
            preconditionFailure("a blob item holds data or a file")
        }
        return .file(file)
    }
}

extension WebCore.BlobRegistryImpl {
    private static var noTopOrigin: OptionalSecurityOriginData { OptionalSecurityOriginData() }

    /// Registers a blob URL for a file.
    @cxx
    @implementation
    public func registerInternalFileBlobURL(
        _ url: WTF.URL,
        _ file: RefBlobDataFileReference,
        _ contentType: WTF.String
    ) {
        WTF.assertIsMainThread()
        Self.registerBlobResourceHandleConstructor()

        let blobData = WebCore.BlobData.create(contentType)
        blobData.ptr().appendFile(consuming: file)
        addBlobData(url, consuming: consume blobData, Self.noTopOrigin)
    }

    /// Registers a blob URL for the blob at another URL.
    @cxx
    @implementation
    public func registerBlobURL(
        _ url: WTF.URL,
        _ srcURL: WTF.URL,
        _ policyContainer: WebCore.PolicyContainer,
        _ topOrigin: OptionalSecurityOriginData
    ) {
        registerBlobURLOptionallyFileBacked(url, srcURL, policyContainer: policyContainer, topOrigin: topOrigin)
    }

    /// Registers a blob URL for the blob at another URL, or else for the file.
    @cxx
    @implementation
    public func registerInternalBlobURLOptionallyFileBacked(
        _ url: WTF.URL,
        _ srcURL: WTF.URL,
        _ file: RefPtrBlobDataFileReference,
        _ contentType: WTF.String,
        _ policyContainer: WebCore.PolicyContainer
    ) {
        registerBlobURLOptionallyFileBacked(
            url,
            srcURL,
            file: file,
            contentType: contentType,
            policyContainer: policyContainer
        )
    }

    private func registerBlobURLOptionallyFileBacked(
        _ url: WTF.URL,
        _ srcURL: WTF.URL,
        file: consuming RefPtrBlobDataFileReference = RefPtrBlobDataFileReference(),
        contentType: WTF.String = WTF.String(),
        policyContainer: WebCore.PolicyContainer,
        topOrigin: OptionalSecurityOriginData = Self.noTopOrigin
    ) {
        WTF.assertIsMainThread()
        Self.assertIsInternalURLOrHasTopOrigin(url, topOrigin)
        Self.registerBlobResourceHandleConstructor()

        if let source = blobDataFromURL(srcURL, Self.noTopOrigin) {
            if source.policyContainerEquals(policyContainer) {
                addBlobData(url, consuming: RefBlobData(source), topOrigin)
            } else {
                let clone = source.clone()
                clone.ptr().setPolicyContainer(policyContainer)
                addBlobData(url, consuming: consume clone, topOrigin)
            }
            return
        }

        guard let fileReference = file.get(), !WebCore.isBlobDataFileReferencePathEmpty(fileReference) else {
            return
        }

        let backingFile = WebCore.BlobData.create(contentType)
        backingFile.ptr().appendFile(consuming: RefBlobDataFileReference(fileReference))
        backingFile.ptr().setPolicyContainer(policyContainer)

        addBlobData(url, consuming: consume backingFile, topOrigin)
    }

    /// Registers a blob URL for a slice of the blob at another URL.
    @cxx
    @implementation
    public func registerInternalBlobURLForSlice(
        _ url: WTF.URL,
        _ srcURL: WTF.URL,
        _ start: Int64,
        _ end: Int64,
        _ contentType: WTF.String
    ) {
        WTF.assertIsMainThread()
        guard let originalData = blobDataFromURL(srcURL, Self.noTopOrigin) else {
            return
        }

        let originalSize = originalData.totalLength
        var start = start
        var end = end

        // Convert the negative value that is used to select from the end.
        if start < 0 {
            start = Int64(bitPattern: UInt64(bitPattern: start) &+ originalSize)
        }
        if end < 0 {
            end = Int64(bitPattern: UInt64(bitPattern: end) &+ originalSize)
        }

        // Clamp the range if it exceeds the size limit.
        start = max(start, 0)
        end = max(end, 0)
        if UInt64(bitPattern: start) >= originalSize {
            start = 0
            end = 0
        } else if end < start {
            end = start
        } else if UInt64(bitPattern: end) > originalSize {
            end = Int64(bitPattern: originalSize)
        }

        let newData = WebCore.BlobData.create(contentType)
        appendStorageItems(to: newData.ptr(), from: originalData, offset: start, length: end - start)

        addBlobData(url, consuming: consume newData, Self.noTopOrigin)
    }

    private func appendStorageItems(to blobData: WebCore.BlobData, from source: WebCore.BlobData, offset: Int64, length: Int64) {
        assert(length != WebCore.BlobDataItem.toEndOfFile)

        var offset = offset
        var length = length
        var itemsIndex = 0
        if offset != 0 {
            while itemsIndex < source.itemCount() {
                let itemLength = source[itemsIndex].length()
                guard offset >= itemLength else {
                    break
                }
                offset = offset &- itemLength
                itemsIndex += 1
            }
        }

        while itemsIndex < source.itemCount() && length > 0 {
            let item = source[itemsIndex]
            let newLength = min(item.length() &- offset, length)
            let itemOffset = item.offset() &+ offset
            switch item.content {
            case .data(let data):
                blobData.appendData(data, offset: itemOffset, length: newLength)
            case .file(let file):
                blobData.appendFile(file, offset: itemOffset, length: newLength)
            }
            length -= newLength
            offset = 0
            itemsIndex += 1
        }
        assert(length == 0)
    }

    /// The files of the blob at the URL.
    @cxx
    @implementation
    public func filesInBlob(_ url: WTF.URL, _ topOrigin: OptionalSecurityOriginData) -> BlobDataFileReferenceVector {
        var result = BlobDataFileReferenceVector()
        guard let blobData = blobDataFromURL(url, topOrigin) else {
            return result
        }

        for index in 0..<blobData.itemCount() {
            if case .file(let file) = blobData[index].content {
                result.append(consuming: RefBlobDataFileReference(file))
            }
        }
        return result
    }
}
