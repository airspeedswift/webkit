// Copyright (C) 2010 Google Inc. All rights reserved.
// Copyright (C) 2014-2026 Apple Inc. All rights reserved.
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
internal import WebCore_Private.Core.BlobData
internal import WebCore_Private.Core.BlobDataFileReference
internal import WebCore_Private.Core.BlobResourceHandleBase
internal import WebCore_Private.Core.HTTPHeaderNames
internal import WebCore_Private.Core.HTTPParsers
internal import WebCore_Private.Core.SharedBuffer
internal import wtf.Core.MainThread
internal import wtf.Core.MemberContainerOperations
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Vector
internal import wtf.Core.text.WTFString

extension WebCore.BlobResourceHandleBase {
    /// Closes the file item being read, if one is open.
    @cxx
    @implementation
    public func closeFileIfOpen() {
        if m_isFileOpen {
            m_isFileOpen = false
            closeAsyncStream()
        }
    }

    @cxx
    @implementation
    func doStart() {
        assert(WTF.isMainThread())

        // Do not continue if the request is aborted or an error occurs.
        if erroredOrAborted() {
            clearStream()
            return
        }

        if !firstRequestIsGET() {
            didFail(.MethodNotAllowed)
            return
        }

        // If the blob data is not found, fail now.
        guard let blobData = m_blobData.get() else {
            didFail(.NotFoundError)
            return
        }

        // Parse the "Range" header we care about.
        let rangeHeader = firstRequestRangeHeader()
        if !rangeHeader.isNull() {
            guard let range = Self.parseRange(rangeHeader) else {
                RangeOperations.reset(self)
                didFail(.RangeError)
                return
            }
            RangeOperations.set(self, range)
            m_isRangeRequest = true
        }

        if async() {
            getSizeForNext()
            return
        }

        for _ in 0..<blobData.itemCount() {
            if erroredOrAborted() {
                break
            }
            getSizeForNext()
        }

        if let error = seek() {
            didFail(error)
            return
        }
        dispatchDidReceiveResponse()
    }

    /// Takes the size of the item being sized, or -1 when its file was moved or changed.
    @cxx
    @implementation
    public func didGetSize(_ size: Int64) {
        sizeDidBecomeKnown(size)
    }

    // For the other members, since Swift cannot call the @implementation of a final override such as didGetSize().
    private func sizeDidBecomeKnown(_ size: Int64) {
        assert(WTF.isMainThread())

        if erroredOrAborted() {
            clearStream()
            return
        }

        // If the size is -1, it means the file has been moved or changed. Fail now.
        if size == -1 {
            didFail(.NotFoundError)
            return
        }

        // The size passed back is the size of the whole file. If the underlying item is a sliced file, we need to use the slice length.
        let updatedSize = UInt64(bitPattern: itemBeingSized.length())

        // Cache the size.
        ItemLengthListOperations.append(self, updatedSize)

        // Count the size.
        // The sizes of a blob's items can sum past 2^64, and the totals then wrap.
        m_totalSize = m_totalSize &+ updatedSize
        m_totalRemainingSize = m_totalRemainingSize &+ updatedSize
        m_sizeItemCount += 1

        // Continue with the next item.
        getSizeForNext()
    }

    /// Reads the items from the current one until the remaining size is read.
    @cxx
    @implementation
    public func readAsync() {
        assert(WTF.isMainThread())

        if erroredOrAborted() {
            return
        }

        while m_totalRemainingSize != 0 && Int(m_readItemCount) < blobDataBeingRead.itemCount() {
            let item = blobDataBeingRead[Int(m_readItemCount)]
            switch item.content {
            case .data(let data):
                if !readDataAsync(item, data) {
                    return
                }
            case .file(let file):
                readFileAsync(item, file)
                return
            }
        }
        didFinish()
    }

    /// Continues reading once the file item is open.
    @cxx
    @implementation
    public func didOpen(_ success: Bool) {
        assert(async())

        if erroredOrAborted() {
            clearStream()
            return
        }

        if !success {
            didFail(.NotReadableError)
            return
        }

        // Continue the reading.
        readAsync()
    }

    @cxx
    @implementation
    func didRead(_ bytesRead: Int32) {
        if erroredOrAborted() {
            clearStream()
            return
        }

        if bytesRead < 0 {
            didFail(.NotReadableError)
            return
        }

        if consumeData(byteCount: UInt64(bytesRead), { notifyClientOfBufferData(Int(bytesRead)) }) {
            readAsync()
        }
    }

    private static func parseRange(_ range: borrowing WTF.String) -> WebCore.HTTPRange? {
        // An empty String has no characters to pass to C++, and an empty range is invalid.
        if range.isEmpty() {
            return nil
        }
        let parsedRange: HTTPRangeValue
        if range.is8Bit() {
            let characters: Span<UInt8> = WTF.bytesOfLatin1Characters(range.span8())
            parsedRange = httpRangeValue(characters, allowWhitespace: true)
        } else {
            let characters: Span<UInt16> = range.checkedSpan16()
            parsedRange = httpRangeValue(characters, allowWhitespace: true)
        }
        guard parsedRange.isValid else {
            return nil
        }
        return WebCore.HTTPRange(start: parsedRange.start, end: parsedRange.end)
    }

    // doStart() fails the load when there is no blob data, before anything sizes or reads its items.
    private var blobDataBeingRead: WebCore.BlobData {
        guard let blobData = m_blobData.get() else {
            preconditionFailure("a blob being sized or read has blob data")
        }
        return blobData
    }

    private var itemBeingSized: WebCore.BlobDataItem {
        blobDataBeingRead[Int(m_sizeItemCount)]
    }

    private func getSizeForNext() {
        assert(WTF.isMainThread())

        // Do we finish validating and counting size for all items?
        if Int(m_sizeItemCount) >= blobDataBeingRead.itemCount() {
            if let error = seek() {
                didFail(error)
                return
            }

            // Start reading if in asynchronous mode.
            if async() {
                dispatchDidReceiveResponse()
            }
            return
        }

        let item = itemBeingSized
        switch item.content {
        case .data:
            sizeDidBecomeKnown(item.length())
        case .file(let file):
            // Files know their sizes, but asking the stream to verify that the file wasn't modified.
            if async() {
                getAsyncFileSize(file)
            } else {
                sizeDidBecomeKnown(getSyncFileSize(file))
            }
        }
    }

    // nil is a RangeError.
    private func adjustedAndValidatedRangeBounds(start: UInt64?, end: UInt64?) -> (start: UInt64, end: UInt64)? {
        let totalSize = m_totalSize
        guard let start else {
            guard let end else {
                return nil
            }
            // end indicates the last bytes to read.
            if end > totalSize {
                return (start: 0, end: totalSize != 0 ? totalSize - 1 : 0)
            }
            // Wraps when totalSize is 0.
            return (start: totalSize - end, end: totalSize &- 1)
        }
        if start >= totalSize {
            return nil
        }
        if let end, start > end {
            return nil
        }
        guard let end, end < totalSize else {
            return (start: start, end: totalSize - 1)
        }
        return (start: start, end: end)
    }

    private func seek() -> WebCore.BlobResourceHandleBase.Error? {
        assert(WTF.isMainThread())

        // Bail out if the range is not provided.
        guard let range = Optional(fromCxx: m_range) else {
            return nil
        }

        guard
            let bounds = adjustedAndValidatedRangeBounds(
                start: Optional(fromCxx: range.start),
                end: Optional(fromCxx: range.end)
            )
        else {
            return .RangeError
        }
        RangeOperations.set(self, WebCore.HTTPRange(start: bounds.start, end: bounds.end))

        // Skip the initial items that are not in the range.
        let itemCount = blobDataBeingRead.itemCount()
        var offset = bounds.start
        m_readItemCount = 0
        while Int(m_readItemCount) < itemCount && offset >= lengthOfItemBeingRead() {
            offset -= lengthOfItemBeingRead()
            m_readItemCount += 1
        }

        // Set the offset that need to jump to for the first item in the range.
        m_currentItemReadSize = offset

        // Adjust the total remaining size in order not to go beyond the range.
        // Traps when the end is before the start or the range covers all of UInt64.
        let rangeSize = bounds.end - bounds.start + 1
        if m_totalRemainingSize > rangeSize {
            m_totalRemainingSize = rangeSize
        }
        return nil
    }

    private func readDataAsync(_ item: borrowing WebCore.BlobDataItem, _ data: WebCore.DataSegment) -> Bool {
        assert(WTF.isMainThread())

        let itemLength = UInt64(bitPattern: item.length())
        assert(m_currentItemReadSize <= itemLength)
        let bytesToRead = min(itemLength &- m_currentItemReadSize, m_totalRemainingSize)

        let offset = UInt64(bitPattern: item.offset()) &+ m_currentItemReadSize
        m_currentItemReadSize = 0

        return consumeData(byteCount: bytesToRead) { notifyClientOfSegmentData(data, offset, bytesToRead) }
    }

    private func consumeData(byteCount: UInt64, _ notifyClient: () -> Bool) -> Bool {
        assert(async())

        m_totalRemainingSize = m_totalRemainingSize &- byteCount

        // Notify the client.
        if !notifyClient() {
            return false
        }

        if m_isFileOpen {
            // When the current item is a file item, the reading is completed only if bytesRead is 0.
            if byteCount == 0 {
                closeFileIfOpen()

                // Move to the next item.
                m_readItemCount += 1
            }
        } else {
            // Otherwise, we read the current text item as a whole and move to the next item.
            m_readItemCount += 1
        }

        return true
    }
}

extension WebCore.HTTPRange {
    fileprivate init(start: UInt64?, end: UInt64?) {
        self.init()
        self.start.value = start
        self.end.value = end
    }
}
