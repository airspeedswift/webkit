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

import Dispatch
import WebKit_Internal.NetworkCacheCxx
import wtf

private struct PartitionEntry {
    let recordPath: WTF.String
    let lastAccessTime: WTF.WallTime
}

extension NetworkCacheStorageIO {
    /// A traversal's walk, on the IO queue.
    ///
    /// Each record's read completes on the main thread, which decodes its header and calls the handler; `slots` holds
    /// the limit of reads in progress.
    fileprivate func traverseRecords(
        _ operation: NetworkCacheTraverseOperation,
        _ slots: DispatchSemaphore,
        _ partitionName: NetworkCacheIsolatedString?,
        _ expectedType: NetworkCacheIsolatedString,
        _ flags: UInt8
    ) {
        assert(!WTF.RunLoop.isMain())
        let computeWorth = flags & WebKit.NetworkCache.Storage.TraverseFlag.ComputeWorth.rawValue != 0
        let shareCount = flags & WebKit.NetworkCache.Storage.TraverseFlag.ShareCount.rawValue != 0
        let lastAccessedRecordPerPartition = flags & WebKit.NetworkCache.Storage.TraverseFlag.LastAccessedRecordPerPartition.rawValue != 0
        assert(!lastAccessedRecordPerPartition || (!computeWorth && !shareCount))

        // Record directory -> its most recently modified record.
        var partitionEntries: [NetworkCacheIsolatedString: PartitionEntry] = [:]
        let directoryOrder = WebKit.NetworkCache.RecordDirectoryOrder.create().get()

        let traverseFunction: NetworkCacheRecordFileTraverseFunction = { [self] fileName, _, type, isBlob, recordDirectoryPath in
            assert(expectedType.isEmpty || type == expectedType.string)
            if isBlob {
                return
            }
            let recordPath = networkCachePath(recordDirectoryPath, fileName)
            if lastAccessedRecordPerPartition {
                let mtime = WTF.FileSystemImpl.fileModificationTime(recordPath).value
                let directory = NetworkCacheIsolatedString(recordDirectoryPath)
                guard let entry = partitionEntries[directory] else {
                    directoryOrder.add(recordDirectoryPath)
                    partitionEntries[directory] = PartitionEntry(recordPath: recordPath, lastAccessTime: mtime ?? WTF.WallTime())
                    return
                }
                if let mtime, mtime.seconds > entry.lastAccessTime.seconds {
                    partitionEntries[directory] = PartitionEntry(recordPath: recordPath, lastAccessTime: mtime)
                }
                return
            }
            let worth = computeWorth ? fileTimes(recordPath).recordWorth : -1.0
            let bodyShareCount = shareCount ? blobStorage.shareCount(Self.blobPath(forRecordPath: recordPath)) : 0

            slots.wait()
            traverseReadRecord(
                operation,
                slots,
                recordPath,
                .sizing(worth: worth, bodyShareCount: bodyShareCount)
            )
        }

        if let partitionName {
            traversePartitionFiles(
                networkCachePath(recordsPath.string, partitionName.string),
                expectedType.string,
                traverseFunction
            )
        } else {
            traverseRecordsFiles(recordsPath.string, expectedType.string, traverseFunction)
        }

        if lastAccessedRecordPerPartition {
            let directories = directoryOrder.inOrder()
            for index in 0..<directories.size() {
                guard let entry = partitionEntries[NetworkCacheIsolatedString(directories[index])] else {
                    continue
                }
                slots.wait()
                traverseReadRecord(
                    operation,
                    slots,
                    entry.recordPath,
                    .lastAccess(seconds: entry.lastAccessTime.seconds)
                )
            }
        }
    }

    /// What a traversal reports of a record beside its header: its worth and body share count, or the last access time
    /// of its partition's most recently accessed record.
    fileprivate enum TraverseRecordDetail: Sendable {
        case sizing(worth: Double, bodyShareCount: UInt32)
        case lastAccess(seconds: Double)
    }

    /// Reads one record file through IOChannel; on the main thread, decodes its header and calls the traversal's handler.
    fileprivate func traverseReadRecord(
        _ operation: NetworkCacheTraverseOperation,
        _ slots: DispatchSemaphore,
        _ recordPath: borrowing WTF.String,
        _ detail: TraverseRecordDetail
    ) {
        let salt = self.salt
        WebKit.NetworkCache.readFileOnMain(
            recordPath,
            consuming: .init(sendable: { fileData in
                assert(WTF.RunLoop.isMain())
                if let decoded = WebKit.NetworkCache.RecordFormat.decodeRecordHeader(fileData, salt).value {
                    let metaData = decoded.metaData
                    let record = WebKit.NetworkCache.Storage.Record(
                        metaData.key,
                        metaData.timeStamp,
                        decoded.headerData,
                        WebKit.NetworkCache.Data(),
                        .init(metaData.bodyHash)
                    )
                    var info = WebKit.NetworkCache.Storage.RecordInfo()
                    info.bodySize = Int(truncatingIfNeeded: metaData.bodySize)
                    switch detail {
                    case .sizing(let worth, let bodyShareCount):
                        info.worth = worth
                        info.bodyShareCount = bodyShareCount
                        info.bodyHash = WebKit.NetworkCache.Key.hashAsString(metaData.bodyHash)
                    case .lastAccess(let seconds):
                        info.worth = -1
                        info.lastAccessTime = WebKit.NetworkCache.wallTimeFromRawSeconds(seconds)
                    }
                    operation.withLock { handler in
                        handler?(record, info)
                    }
                }
                slots.signal()
            })
        )
    }
}

extension NetworkCacheStorage {
    private static let maxParallelActivityCount = 5

    func traverse(
        _ type: borrowing WTF.String,
        partition: WTF.String?,
        _ flags: UInt8,
        _ traverseHandler: @escaping NetworkCacheStorageTraverseHandler
    ) {
        let partitionName = partition.map {
            NetworkCacheIsolatedString(WebKit.NetworkCache.Key.partitionToPartitionHashAsString($0, io.salt))
        }
        traverseInternal(partitionName, type, flags, traverseHandler)
    }

    private func traverseInternal(
        _ partitionName: NetworkCacheIsolatedString?,
        _ type: borrowing WTF.String,
        _ flags: UInt8,
        _ traverseHandler: @escaping NetworkCacheStorageTraverseHandler
    ) {
        assert(WTF.RunLoop.isMain())
        let traverseOperation = NetworkCacheTraverseOperation(traverseHandler)
        let slots = DispatchSemaphore(value: Self.maxParallelActivityCount)
        let io = io
        let isolatedType = NetworkCacheIsolatedString(type)
        ioQueue.dispatch(
            consuming: .init(sendable: {
                io.traverseRecords(traverseOperation, slots, partitionName, isolatedType, flags)
                for _ in 0..<Self.maxParallelActivityCount {
                    slots.wait() // Waits until every read's main-thread task has run.
                }
                // libdispatch traps when a semaphore is released with a value below its initial one.
                for _ in 0..<Self.maxParallelActivityCount {
                    slots.signal()
                }
                WebKit.NetworkCache.dispatchFunctionOnMain(
                    consuming: .init(sendable: {
                        traverseOperation.withLock { handler in
                            // Invoke with no record to indicate this is the last record, then destroy the handler here.
                            if let last = handler.take() {
                                last(nil, WebKit.NetworkCache.Storage.RecordInfo())
                            }
                        }
                    })
                )
            })
        )
    }
}

// A whole-file read (NetworkCacheData.h), which hands the file's bytes to its completion.
extension WebKit.NetworkCache.FileReadCompletion: CxxArgumentFunction {
    typealias Argument = WebKit.NetworkCache.Data

    init(sendable body: @escaping @Sendable (WebKit.NetworkCache.Data) -> Void) {
        self.init(cxxSendable: body)
    }
}
