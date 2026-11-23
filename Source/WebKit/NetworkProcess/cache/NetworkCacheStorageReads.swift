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
final class NetworkCacheReadOperation {
    let identifier = WebKit.NetworkCache.generateReadOperationIdentifier()
    let key: WebKit.NetworkCache.Key
    let priority: UInt32
    var completionHandler: NetworkCacheStorageRetrieveHandler?
    var waitsForRecord = true
    var waitsForBlob = false
    var timings = WebKit.NetworkCache.Storage.Timings()
    var record = WebKit.NetworkCache.Storage.Record()
    var blobBodyHash: WTF.SHA1.Digest?

    init(key: WebKit.NetworkCache.Key, priority: UInt32, completionHandler: @escaping NetworkCacheStorageRetrieveHandler) {
        assert(WTF.RunLoop.isMain())
        self.key = key
        self.priority = priority
        self.completionHandler = completionHandler
    }

    var canFinish: Bool {
        !waitsForRecord && !waitsForBlob
    }

    // The highest priority first, then the oldest.
    func isLowerPriority(than other: NetworkCacheReadOperation) -> Bool {
        if priority == other.priority {
            return identifier > other.identifier
        }
        return priority < other.priority
    }

    func updateForStart(_ readOperationDispatchCount: Int) {
        assert(WTF.RunLoop.isMain())
        timings.startTime = WTF.MonotonicTime.now()
        timings.dispatchCountAtStart = readOperationDispatchCount
    }

    func updateForDispatch(synchronizationInProgress: Bool, shrinkInProgress: Bool, readOperationDispatchCount: Int) {
        assert(WTF.RunLoop.isMain())
        timings.dispatchTime = WTF.MonotonicTime.now()
        timings.synchronizationInProgressAtDispatch = synchronizationInProgress
        timings.shrinkInProgressAtDispatch = shrinkInProgress
        timings.dispatchCountAtDispatch = readOperationDispatchCount
    }

    func cancel() {
        assert(WTF.RunLoop.isMain())
        if timings.wasCanceled {
            return
        }
        timings.completionTime = WTF.MonotonicTime.now()
        timings.wasCanceled = true

        if let handler = completionHandler.take() {
            // The handler's Bool is ignored on cancel.
            _ = handler(WebKit.NetworkCache.Storage.Record(), timings)
        }
    }

    func finish() -> Bool {
        assert(WTF.RunLoop.isMain())
        assert(canFinish)
        guard let handler = completionHandler.take() else {
            return false
        }
        timings.completionTime = WTF.MonotonicTime.now()

        // Blob and record are read separately, so we need to check if blob hash matches record hash.
        let blobHashMismatch = blobBodyHash.map { !WebKit.NetworkCache.optionalDigestEquals($0, record.bodyHash) } ?? false
        // Failed to read body from both blob storage and record storage.
        let bodyIsMissing = record.body.isNull()
        if !(record.key == key) || blobHashMismatch || bodyIsMissing {
            record = WebKit.NetworkCache.Storage.Record()
        }
        return handler(exchange(&record, with: WebKit.NetworkCache.Storage.Record()), timings)
    }

    func finishReadRecord(
        _ newRecord: consuming WebKit.NetworkCache.Storage.Record,
        recordIOStartTime: WTF.MonotonicTime,
        recordIOEndTime: WTF.MonotonicTime
    ) {
        assert(WTF.RunLoop.isMain())
        waitsForRecord = false
        // Body is already read from blob storage, and it is not null.
        if blobBodyHash != nil {
            // Body should not be stored in both blob storage and record storage.
            assert(newRecord.body.isNull())
            newRecord.body = record.body
        }
        record = newRecord
        timings.recordIOStartTime = recordIOStartTime
        timings.recordIOEndTime = recordIOEndTime
    }

    func finishReadBlob(_ blob: consuming NetworkCacheBlob, blobIOStartTime: WTF.MonotonicTime, blobIOEndTime: WTF.MonotonicTime) {
        assert(WTF.RunLoop.isMain())
        waitsForBlob = false
        if blob.data.isNull() {
            return
        }
        record.body = blob.data
        blobBodyHash = blob.hash
        timings.blobIOStartTime = blobIOStartTime
        timings.blobIOEndTime = blobIOEndTime
    }
}

extension NetworkCacheStorage {
    private static let readTimeoutSeconds = 1.5
    private static let maximumActiveReadOperationCount = 5

    private func activeReadOperation(_ identifier: UInt64) -> NetworkCacheReadOperation {
        guard let readOperation = activeReadOperations[identifier] else {
            fatalError("No active read operation")
        }
        return readOperation
    }

    private func dispatchReadOperation(_ readOperation: NetworkCacheReadOperation) {
        assert(WTF.RunLoop.isMain())
        let identifier = readOperation.identifier
        activeReadOperations[identifier] = readOperation
        activeReadOperationOrder.add(identifier)
        let key = readOperation.key
        let recordPath = io.recordPath(for: key)
        let blobPath: WTF.String? = mayContainBlob(key) ? io.blobPath(for: key) : nil

        readOperation.updateForDispatch(
            synchronizationInProgress: synchronizationInProgress,
            shrinkInProgress: shrinkInProgress,
            readOperationDispatchCount: readOperationDispatchCount
        )
        if blobPath != nil {
            readOperation.waitsForBlob = true
        }

        readOperationDispatchCount += 1

        // Avoid randomness during testing.
        if mode != .AvoidRandomness {
            // I/O pressure may make disk operations slow. If they start taking very long time we rather go to network.
            if !readOperationTimeoutTimer.hasHandler() {
                readOperationTimeoutTimer.setHandler(
                    consuming: .init { [weak self] in
                        self?.cancelAllReadOperations()
                    }
                )
            }
            readOperationTimeoutTimer.startOneShot(Self.readTimeoutSeconds)
        }

        let io = io
        let isolatedRecordPath = NetworkCacheIsolatedString(recordPath)
        let isolatedBlobPath = blobPath.map { NetworkCacheIsolatedString($0) }
        WebKit.NetworkCache.dispatchReadWithRepliesOnMain(
            ioQueue,
            consuming: .init(sendable: { io.readRecordStage(isolatedRecordPath) }),
            consuming: .init { [self] (result: consuming WebKit.NetworkCache.ReadRecordReply) in
                didReadRecord(result, identifier: identifier)
            },
            consuming: .init(sendable: { io.readBlobStage(isolatedBlobPath) }),
            consuming: .init { [self] (result: consuming WebKit.NetworkCache.ReadBlobReply) in
                didReadBlob(result, identifier: identifier)
            }
        )
    }

    private func didReadRecord(_ result: borrowing WebKit.NetworkCache.ReadRecordReply, identifier: UInt64) {
        let readOperation = activeReadOperation(identifier)
        let record = result.record.value?.record ?? WebKit.NetworkCache.Storage.Record()
        readOperation.finishReadRecord(record, recordIOStartTime: result.recordIOStartTime, recordIOEndTime: result.recordIOEndTime)
        finishReadOperationIfReady(readOperation)
    }

    private func didReadBlob(_ result: borrowing WebKit.NetworkCache.ReadBlobReply, identifier: UInt64) {
        guard result.hasBlob else {
            return
        }
        let readOperation = activeReadOperation(identifier)
        readOperation.finishReadBlob(
            NetworkCacheBlob(data: result.data, hash: result.hash),
            blobIOStartTime: result.blobIOStartTime,
            blobIOEndTime: result.blobIOEndTime
        )
        finishReadOperationIfReady(readOperation)
    }

    private func finishReadOperationIfReady(_ readOperation: NetworkCacheReadOperation) {
        if readOperation.canFinish {
            finishReadOperation(readOperation.identifier)
        }
    }

    private func finishReadOperation(_ identifier: UInt64) {
        assert(WTF.RunLoop.isMain())
        guard let readOperation = activeReadOperations.removeValue(forKey: identifier) else {
            fatalError("No active read operation")
        }
        activeReadOperationOrder.remove(identifier)

        if readOperation.finish() {
            updateFileModificationTime(io.recordPath(for: readOperation.key))
        } else if !readOperation.timings.wasCanceled {
            remove(readOperation.key)
        }

        if activeReadOperations.isEmpty {
            readOperationTimeoutTimer.stop()
        }

        dispatchPendingReadOperations()
    }

    private func cancelAllReadOperations() {
        assert(WTF.RunLoop.isMain())
        // Canceling calls completion handlers, which may start new reads: cancel the operations active now.
        let identifiers = activeReadOperationOrder.inOrder()
        for index in 0..<identifiers.size() {
            activeReadOperations[identifiers[index]]?.cancel()
        }

        while !pendingReadOperations.isEmpty {
            dequeuePendingReadOperation().cancel()
        }
    }

    // The highest-priority pending read; priority and then identifier make a total order.
    private func dequeuePendingReadOperation() -> NetworkCacheReadOperation {
        let best = pendingReadOperations.indices.max { pendingReadOperations[$0].isLowerPriority(than: pendingReadOperations[$1]) }
        guard let best else {
            preconditionFailure("No pending read operation")
        }
        return pendingReadOperations.remove(at: best)
    }

    private func dispatchPendingReadOperations() {
        assert(WTF.RunLoop.isMain())
        while !pendingReadOperations.isEmpty {
            if activeReadOperations.count > Self.maximumActiveReadOperationCount {
                return
            }
            dispatchReadOperation(dequeuePendingReadOperation())
        }
    }

    /// A write in progress for `key` answers the retrieve from memory, on a later turn of the main run loop.
    private func retrieveFromMemory(
        _ operations: [NetworkCacheWriteOperation],
        _ key: borrowing WebKit.NetworkCache.Key,
        _ completionHandler: @escaping NetworkCacheStorageRetrieveHandler
    ) -> Bool {
        assert(WTF.RunLoop.isMain())
        for operation in operations where operation.record.key == key {
            let record = operation.record
            WebKit.NetworkCache.dispatchOnMain(
                consuming: .init {
                    _ = completionHandler(record, WebKit.NetworkCache.Storage.Timings())
                }
            )
            return true
        }
        return false
    }

    /// A C++ caller's retrieve.
    func retrieve(
        _ key: WebKit.NetworkCache.Key,
        priority: UInt32,
        _ completionHandler: consuming WebKit.NetworkCache.Storage.RetrieveCompletionHandler
    ) {
        let box = NetworkCacheHandlerBox(Optional(completionHandler))
        retrieve(key, priority: priority) { record, timings in
            guard let handler = box.handler.take() else {
                fatalError("A retrieve's handler is called once")
            }
            return WebKit.NetworkCache.invokeStorageRetrieveCompletionHandler(consuming: handler, record, timings)
        }
    }

    func retrieve(_ key: WebKit.NetworkCache.Key, priority: UInt32, _ completionHandler: @escaping NetworkCacheStorageRetrieveHandler) {
        assert(WTF.RunLoop.isMain())
        assert(!key.isNull())

        if capacity == 0 || !mayContain(key) {
            _ = completionHandler(WebKit.NetworkCache.Storage.Record(), WebKit.NetworkCache.Storage.Timings())
            return
        }

        if retrieveFromMemory(pendingWriteOperations, key, completionHandler) {
            return
        }
        if retrieveFromMemory(activeWriteOperations, key, completionHandler) {
            return
        }

        let readOperation = NetworkCacheReadOperation(key: key, priority: priority, completionHandler: completionHandler)
        readOperation.updateForStart(readOperationDispatchCount)

        pendingReadOperations.append(readOperation)
        dispatchPendingReadOperations()
    }
}

// The read's IO stages, on the IO queue.
extension NetworkCacheStorageIO {
    fileprivate func readRecordStage(_ recordPath: NetworkCacheIsolatedString) -> WebKit.NetworkCache.ReadRecordReply {
        assert(!WTF.RunLoop.isMain())
        let recordIOStartTime = WTF.MonotonicTime.now()
        var decoded: WebKit.NetworkCache.DecodedRecord? = nil
        if let bytes = WTF.FileSystemImpl.readEntireFile(recordPath.string).value {
            decoded = readRecord(WebKit.NetworkCache.Data(consuming: bytes))
        }
        let recordIOEndTime = WTF.MonotonicTime.now()
        var reply = WebKit.NetworkCache.ReadRecordReply()
        if let decoded {
            reply.record = .init(decoded)
        }
        reply.recordIOStartTime = recordIOStartTime
        reply.recordIOEndTime = recordIOEndTime
        return reply
    }

    fileprivate func readBlobStage(_ blobPath: NetworkCacheIsolatedString?) -> WebKit.NetworkCache.ReadBlobReply {
        var reply = WebKit.NetworkCache.ReadBlobReply()
        guard let blobPath else {
            return reply
        }
        let blobIOStartTime = WTF.MonotonicTime.now()
        let blob = blobStorage.get(blobPath.string)
        reply.blobIOEndTime = WTF.MonotonicTime.now()
        reply.hasBlob = true
        reply.data = blob.data
        reply.hash = blob.hash
        reply.blobIOStartTime = blobIOStartTime
        return reply
    }
}

// The read's IO stages and their replies.
extension WebKit.NetworkCache.ReadRecordWork: CxxResultFunction {
    typealias Output = WebKit.NetworkCache.ReadRecordReply

    init(sendable body: @escaping @Sendable () -> WebKit.NetworkCache.ReadRecordReply) {
        self.init(cxxSendable: body)
    }
}

extension WebKit.NetworkCache.ReadBlobWork: CxxResultFunction {
    typealias Output = WebKit.NetworkCache.ReadBlobReply

    init(sendable body: @escaping @Sendable () -> WebKit.NetworkCache.ReadBlobReply) {
        self.init(cxxSendable: body)
    }
}

extension WebKit.NetworkCache.ReadRecordReplyHandler: CxxConsumingCompletionHandler {
    typealias Argument = WebKit.NetworkCache.ReadRecordReply
}

extension WebKit.NetworkCache.ReadBlobReplyHandler: CxxConsumingCompletionHandler {
    typealias Argument = WebKit.NetworkCache.ReadBlobReply
}
