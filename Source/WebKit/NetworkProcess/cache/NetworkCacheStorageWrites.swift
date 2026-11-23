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

import WebKit_Internal.NetworkCacheCxx
import wtf

// Kept out of the C++ header: its generated declaration does not compile there.
@_expose(!Cxx)
final class NetworkCacheWriteOperation {
    let identifier = WebKit.NetworkCache.generateWriteOperationIdentifier()
    let record: WebKit.NetworkCache.Storage.Record
    let mappedBodyHandler: NetworkCacheStorageMappedBodyHandler?
    let storeBlobInMemoryCache: Bool

    init(record: WebKit.NetworkCache.Storage.Record, mappedBodyHandler: NetworkCacheStorageMappedBodyHandler?, storeBlobInMemoryCache: Bool)
    {
        assert(WTF.RunLoop.isMain())
        self.record = record
        self.mappedBodyHandler = mappedBodyHandler
        self.storeBlobInMemoryCache = storeBlobInMemoryCache
    }

    deinit {
        assert(WTF.RunLoop.isMain())
    }
}

/// A record on its way to an IO queue to be written: the key's Swift copy and the record's bytes.
///
/// The IO queue rebuilds the record from it.
private struct NetworkCacheWritePayload: Sendable {
    let key: NetworkCacheIsolatedKey
    let timeStamp: Double
    let header: [UInt8]
    // Nil for a null body.
    let body: [UInt8]?
    let bodyHash: WebKit.NetworkCache.Key.HashType?

    init(_ record: borrowing WebKit.NetworkCache.Storage.Record) {
        key = NetworkCacheIsolatedKey(record.key)
        timeStamp = record.timeStamp.seconds
        let headerBytes: Span<UInt8> = record.header.span()
        header = Array(copying: headerBytes)
        if record.body.isNull() {
            body = nil
        } else {
            let bodyBytes: Span<UInt8> = record.body.span()
            body = Array(copying: bodyBytes)
        }
        bodyHash = record.bodyHash.value
    }

    var record: WebKit.NetworkCache.Storage.Record {
        WebKit.NetworkCache.Storage.Record(
            key.key,
            WebKit.NetworkCache.wallTimeFromRawSeconds(timeStamp),
            WebKit.NetworkCache.Data(header.span),
            body.map { WebKit.NetworkCache.Data($0.span) } ?? WebKit.NetworkCache.Data(),
            WebKit.NetworkCache.Key.OptionalHashType(optional: bodyHash)
        )
    }
}

extension NetworkCacheStorage {
    private static let maximumActiveWriteOperationCount = 1
    // By default, delay the start of writes a bit to avoid affecting early page load.
    // Completing writes will dispatch more writes without delay.
    private static let initialWriteDelay = 1.0

    func dispatchPendingWriteOperations() {
        assert(WTF.RunLoop.isMain())
        while !pendingWriteOperations.isEmpty {
            if activeWriteOperations.count >= Self.maximumActiveWriteOperationCount {
                return
            }
            dispatchWriteOperation(pendingWriteOperations.removeLast())
        }
    }

    private func dispatchWriteOperation(_ writeOperation: NetworkCacheWriteOperation) {
        assert(WTF.RunLoop.isMain())
        let identifier = writeOperation.identifier
        activeWriteOperations.append(writeOperation)

        // This was added already when starting the store but filter might have been wiped.
        addToRecordFilter(writeOperation.record.key)

        let io = io
        let payload = NetworkCacheWritePayload(writeOperation.record)
        let storeBlobInMemoryCache = writeOperation.storeBlobInMemoryCache
        WebKit.NetworkCache.dispatchWriteWithRepliesOnMain(
            backgroundIOQueue,
            consuming: .init(sendable: {
                io.writeBlobStage(payload, identifier: identifier, storeBlobInMemoryCache: storeBlobInMemoryCache)
            }),
            consuming: .init { [self] (blob: consuming WebKit.NetworkCache.WriteBlobReply) in
                didWriteBlob(blob, identifier: identifier)
            },
            consuming: .init(sendable: { blobHash in io.writeRecordStage(payload, blobHash: blobHash) }),
            consuming: .init { [self] (result: consuming WebKit.NetworkCache.WriteRecordReply) in
                approximateRecordsSize &+= Int(result.recordSize)
                finishWriteOperationActivity(identifier)
            }
        )
    }

    private func activeWriteOperation(_ identifier: UInt64) -> NetworkCacheWriteOperation {
        guard let writeOperation = activeWriteOperations.first(where: { $0.identifier == identifier }) else {
            fatalError("No active write operation")
        }
        return writeOperation
    }

    private func didWriteBlob(_ blob: borrowing WebKit.NetworkCache.WriteBlobReply, identifier: UInt64) {
        assert(WTF.RunLoop.isMain())
        // The blob is stored before the record is written.
        guard blob.hasBlob else {
            return
        }
        let writeOperation = activeWriteOperation(identifier)
        addToBlobFilter(writeOperation.record.key)
        writeOperation.mappedBodyHandler?(blob.data)
        finishWriteOperationActivity(identifier)
    }

    private func finishWriteOperationActivity(_ identifier: UInt64) {
        assert(WTF.RunLoop.isMain())
        if !io.removeWriteOperationActivity(identifier) {
            return
        }
        guard let index = activeWriteOperations.firstIndex(where: { $0.identifier == identifier }) else {
            fatalError("No active write operation")
        }
        activeWriteOperations.remove(at: index)

        dispatchPendingWriteOperations()

        shrinkIfNeeded()
    }

    /// A C++ caller's store.
    func store(
        _ record: borrowing WebKit.NetworkCache.Storage.Record,
        _ mappedBodyHandler: consuming WebKit.NetworkCache.Storage.MappedBodyHandler,
        _ storeBlobInMemoryCache: Bool
    ) {
        let box = NetworkCacheHandlerBox(mappedBodyHandler)
        store(record, storeBlobInMemoryCache: storeBlobInMemoryCache) { data in
            WebKit.NetworkCache.invokeStorageMappedBodyHandler(&box.handler, data)
        }
    }

    func store(
        _ record: WebKit.NetworkCache.Storage.Record,
        storeBlobInMemoryCache: Bool,
        _ mappedBodyHandler: NetworkCacheStorageMappedBodyHandler?
    ) {
        assert(WTF.RunLoop.isMain())
        assert(!record.key.isNull())

        if capacity == 0 {
            return
        }

        let writeOperation = NetworkCacheWriteOperation(
            record: copy record,
            mappedBodyHandler: mappedBodyHandler,
            storeBlobInMemoryCache: storeBlobInMemoryCache
        )
        pendingWriteOperations.insert(writeOperation, at: 0)

        // Add key to the filter already here as we do lookups from the pending operations too.
        addToRecordFilter(record.key)

        let isInitialWrite = pendingWriteOperations.count == 1
        if !isInitialWrite || (synchronizationInProgress && mode == .AvoidRandomness) {
            return
        }

        if !writeOperationDispatchTimer.hasHandler() {
            writeOperationDispatchTimer.setHandler(
                consuming: .init { [weak self] in
                    self?.dispatchPendingWriteOperations()
                }
            )
        }
        writeOperationDispatchTimer.startOneShot(Self.initialWriteDelay)
    }
}

// The write's IO stages, on the background IO queue.
extension NetworkCacheStorageIO {
    fileprivate func writeBlobStage(
        _ payload: NetworkCacheWritePayload,
        identifier: UInt64,
        storeBlobInMemoryCache: Bool
    ) -> WebKit.NetworkCache.WriteBlobReply {
        let record = payload.record
        _ = WTF.FileSystemImpl.makeAllDirectories(recordDirectoryPath(for: record.key))

        addWriteOperationActivity(identifier)

        var reply = WebKit.NetworkCache.WriteBlobReply()
        if record.body.size() > Self.maximumInlineBodySize {
            if let blob = blobStorage.add(blobPath(for: record.key), record.body, addToMemoryCache: storeBlobInMemoryCache) {
                assert(WebKit.NetworkCache.bytesEqual(blob.data, record.body))
                addWriteOperationActivity(identifier)
                reply.hasBlob = true
                reply.data = blob.data
                reply.hash = blob.hash
            }
        }
        return reply
    }

    fileprivate func writeRecordStage(
        _ payload: NetworkCacheWritePayload,
        blobHash: WebKit.NetworkCache.WriteBlobHash
    ) -> WebKit.NetworkCache.WriteRecordReply {
        let record = payload.record
        let recordPath = self.recordPath(for: record.key)
        let recordData = encodeRecord(record, hasBlob: blobHash.hasBlob, blobHash: blobHash.hash)
        let recordSize = recordData.size()

        let recordBytes: Span<UInt8> = recordData.span()
        if !WebKit.NetworkCache.networkCacheOverwriteEntireFile(recordPath, recordBytes) {
            WebKit.LogChannel.NetworkCacheStorage().releaseLog
                .error(
                    "Failed to write \(recordSize) bytes of network cache record data to \(recordPath.description, privacy: .public)"
                )
        }
        var reply = WebKit.NetworkCache.WriteRecordReply()
        reply.recordSize = recordSize
        return reply
    }
}

// The write's IO stages and their replies.
extension WebKit.NetworkCache.WriteBlobWork: CxxResultFunction {
    typealias Output = WebKit.NetworkCache.WriteBlobReply

    init(sendable body: @escaping @Sendable () -> WebKit.NetworkCache.WriteBlobReply) {
        self.init(cxxSendable: body)
    }
}

extension WebKit.NetworkCache.WriteRecordWork: CxxResultArgumentFunction {
    typealias Argument = WebKit.NetworkCache.WriteBlobHash
    typealias Output = WebKit.NetworkCache.WriteRecordReply

    init(
        sendable body:
            @escaping @Sendable (WebKit.NetworkCache.WriteBlobHash) -> WebKit.NetworkCache.WriteRecordReply
    ) {
        self.init(cxxSendable: body)
    }
}

extension WebKit.NetworkCache.WriteBlobReplyHandler: CxxConsumingCompletionHandler {
    typealias Argument = WebKit.NetworkCache.WriteBlobReply
}

extension WebKit.NetworkCache.WriteRecordReplyHandler: CxxConsumingCompletionHandler {
    typealias Argument = WebKit.NetworkCache.WriteRecordReply
}
