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

import Synchronization
import WebKit_Internal.NetworkCacheCxx
import wtf

private let recordsDirectoryName = "Records"
/// NetworkCacheTestSupport.cpp's NCTS_BlobAddGet spells this name too.
private let blobsDirectoryName = "Blobs"
/// A record's blob is the record's path with this suffix.
private let blobSuffix = "-blob"

func versionedDirectoryPath(_ baseDirectoryPath: borrowing WTF.String) -> WTF.String {
    networkCachePath(baseDirectoryPath, WebKit.NetworkCache.versionDirectoryName(WebKit.NetworkCache.Storage.version))
}

typealias NetworkCacheRecordFileTraverseFunction = (
    _ fileName: borrowing WTF.String, _ hashString: borrowing WTF.String, _ type: borrowing WTF.String, _ isBlob: Bool,
    _ recordDirectoryPath: borrowing WTF.String
) -> Void

func traversePartitionFiles(
    _ partitionPath: WTF.String,
    _ expectedType: WTF.String,
    _ function: NetworkCacheRecordFileTraverseFunction
) {
    let hashStringLength = Int(WebKit.NetworkCache.Key.hashStringLength())
    let blobSuffixString = WTF.String(blobSuffix)
    networkCacheTraverseDirectory(partitionPath) { actualType, entryType in
        if entryType != .directory {
            return
        }
        if !expectedType.isEmpty() && !(expectedType == actualType) {
            return
        }
        let recordDirectoryPath = networkCachePath(partitionPath, actualType)
        networkCacheTraverseDirectory(recordDirectoryPath) { fileName, entryType in
            if entryType != .file || Int(fileName.length()) < hashStringLength {
                return
            }
            let hashString = fileName.left(UInt32(hashStringLength))
            let isBlob = Int(fileName.length()) > hashStringLength && WebKit.NetworkCache.networkCacheEndsWith(fileName, blobSuffixString)
            function(fileName, hashString, actualType, isBlob, recordDirectoryPath)
        }
    }
}

func traverseRecordsFiles(
    _ recordsPath: WTF.String,
    _ expectedType: WTF.String,
    _ function: NetworkCacheRecordFileTraverseFunction
) {
    networkCacheTraverseDirectory(recordsPath) { partitionName, entryType in
        if entryType != .directory {
            return
        }
        traversePartitionFiles(networkCachePath(recordsPath, partitionName), expectedType, function)
    }
}

/// A key's strings and hashes, owned by Swift so the key can move to an IO queue.
struct NetworkCacheIsolatedKey: Sendable {
    let partition: NetworkCacheIsolatedString
    let type: NetworkCacheIsolatedString
    let identifier: NetworkCacheIsolatedString
    let range: NetworkCacheIsolatedString
    let hash: WebKit.NetworkCache.Key.HashType
    let partitionHash: WebKit.NetworkCache.Key.HashType

    init(_ key: borrowing WebKit.NetworkCache.Key) {
        partition = NetworkCacheIsolatedString(key.partitionCopy())
        type = NetworkCacheIsolatedString(key.typeCopy())
        identifier = NetworkCacheIsolatedString(key.identifierCopy())
        range = NetworkCacheIsolatedString(key.rangeCopy())
        hash = key.hashCopy()
        partitionHash = key.partitionHashCopy()
    }

    var key: WebKit.NetworkCache.Key {
        WebKit.NetworkCache.Key.makeWithHashes(partition.string, type.string, identifier.string, range.string, hash, partitionHash)
    }
}

/// What the IO queues read: Swift values, the blob storage and the write activity counts.
///
/// Never the main thread's state, and never a queue.
final class NetworkCacheStorageIO: Sendable {
    let basePath: NetworkCacheIsolatedString
    let recordsPath: NetworkCacheIsolatedString
    let salt: WebKit.NetworkCache.Salt
    let blobStorage: NetworkCacheBlobStorage
    // 0 means unset.
    private let volumeBlockSizeCache = Atomic<UInt64>(0)
    // Write operation identifier -> activities in progress; reached on the main thread and the IO queues.
    private let writeOperationActivities = Mutex<[UInt64: Int]>([:])

    static let maximumInlineBodySize = Int(WTF.pageSize())

    static func blobPath(forRecordPath recordPath: borrowing WTF.String) -> WTF.String {
        if recordPath.is8Bit() {
            let bytes: Span<UInt8> = WebKit.NetworkCache.latin1Bytes(recordPath)
            let path = Array(copying: bytes) + blobSuffix.utf8
            return WebKit.NetworkCache.latin1String(path.span)
        }
        let span16: Span<UInt16> = recordPath.checkedSpan16()
        let path = Array(copying: span16) + blobSuffix.utf16
        return WTF.String(path.span)
    }

    init(basePath: borrowing WTF.String, salt: WebKit.NetworkCache.Salt, mainResourceBlobMemoryCacheFileLimit: UInt32) {
        self.basePath = NetworkCacheIsolatedString(basePath)
        let versioned = versionedDirectoryPath(basePath)
        self.recordsPath = NetworkCacheIsolatedString(networkCachePath(versioned, WTF.String(recordsDirectoryName)))
        self.salt = salt
        self.blobStorage = NetworkCacheBlobStorage(
            blobDirectoryPath: networkCachePath(versioned, WTF.String(blobsDirectoryName)),
            salt: salt,
            memoryCacheFileLimit: mainResourceBlobMemoryCacheFileLimit
        )
    }

    func addWriteOperationActivity(_ identifier: UInt64) {
        writeOperationActivities.withLock { $0[identifier, default: 0] += 1 }
    }

    /// True when the last activity of the operation is removed.
    func removeWriteOperationActivity(_ identifier: UInt64) -> Bool {
        writeOperationActivities.withLock { activities in
            guard let count = activities[identifier] else {
                assertionFailure()
                return false
            }
            if count == 1 {
                activities[identifier] = nil
                return true
            }
            activities[identifier] = count - 1
            return false
        }
    }

    // Called on the IO queues.
    private func volumeBlockSize() -> UInt64 {
        assert(!WTF.RunLoop.isMain())
        let cached = volumeBlockSizeCache.load(ordering: .relaxed)
        if cached != 0 {
            return cached
        }
        let size = UInt64(WTF.FileSystemImpl.volumeFileBlockSize(basePath.string).value ?? 4 * 1024)
        volumeBlockSizeCache.store(size, ordering: .relaxed)
        return size
    }

    private func estimateRecordsSize(recordCount: UInt32, blobCount: UInt32) -> Int {
        let inlineBodyCount = recordCount &- min(blobCount, recordCount)
        let headerSizes = Int(recordCount) &* Int(truncatingIfNeeded: volumeBlockSize())
        let inlineBodySizes = (Self.maximumInlineBodySize / 2) &* Int(inlineBodyCount)
        return headerSizes &+ inlineBodySizes
    }

    func recordDirectoryPath(for key: WebKit.NetworkCache.Key) -> WTF.String {
        assert(!key.typeCopy().isEmpty())
        return networkCachePath(networkCachePath(recordsPath.string, key.partitionHashAsString()), key.typeCopy())
    }

    func recordPath(for key: borrowing WebKit.NetworkCache.Key) -> WTF.String {
        networkCachePath(recordDirectoryPath(for: key), key.hashAsString())
    }

    func blobPath(for key: borrowing WebKit.NetworkCache.Key) -> WTF.String {
        Self.blobPath(forRecordPath: recordPath(for: key))
    }

    func deleteFiles(_ key: borrowing WebKit.NetworkCache.Key) {
        assert(!WTF.RunLoop.isMain())
        _ = WTF.FileSystemImpl.deleteFile(recordPath(for: key))
        blobStorage.remove(blobPath(for: key))
    }

    func readRecord(_ recordData: WebKit.NetworkCache.Data) -> WebKit.NetworkCache.DecodedRecord? {
        WebKit.NetworkCache.RecordFormat.readRecord(recordData, salt).value
    }

    func encodeRecord(
        _ record: borrowing WebKit.NetworkCache.Storage.Record,
        hasBlob: Bool,
        blobHash: WTF.SHA1.Digest
    ) -> WebKit.NetworkCache.Data {
        WebKit.NetworkCache.RecordFormat.encodeRecord(record.key, record.timeStamp, record.header, record.body, salt, hasBlob, blobHash)
    }
}

extension WebKit.NetworkCache.DecodedRecord {
    var record: WebKit.NetworkCache.Storage.Record {
        WebKit.NetworkCache.Storage.Record(
            header.metaData.key,
            header.metaData.timeStamp,
            header.headerData,
            bodyData,
            .init(header.metaData.bodyHash)
        )
    }
}

private func deleteEmptyRecordsDirectories(_ recordsPath: WTF.String) {
    networkCacheTraverseDirectory(recordsPath) { partitionName, type in
        if type != .directory {
            return
        }
        // Delete [type] sub-folders.
        let partitionPath = networkCachePath(recordsPath, partitionName)
        networkCacheTraverseDirectory(partitionPath) { subdirName, entryType in
            if entryType != .directory {
                return
            }
            // Let system figure out if it is really empty.
            _ = WTF.FileSystemImpl.deleteEmptyDirectory(networkCachePath(partitionPath, subdirName))
        }
        // Delete [Partition] folders.
        // Let system figure out if it is really empty.
        _ = WTF.FileSystemImpl.deleteEmptyDirectory(networkCachePath(recordsPath, partitionName))
    }
}

private func deletionProbability(_ times: NetworkCacheFileTimes, _ bodyShareCount: UInt32) -> Double {
    let maximumProbability = 0.33
    let maximumEffectiveShareCount: UInt32 = 5

    let worth = times.recordWorth

    // Adjust a bit so the most valuable entries don't get deleted at all.
    let effectiveWorth = min(1.1 * worth, 1.0)

    var probability = (1 - effectiveWorth) * maximumProbability

    // It is less useful to remove an entry that shares its body data.
    if bodyShareCount != 0 {
        probability /= Double(min(bodyShareCount, maximumEffectiveShareCount))
    }

    return probability
}

// The synchronization's, the clear's and the shrink's IO stages, on the IO queues.
extension NetworkCacheStorageIO {
    func synchronizeStage() -> WebKit.NetworkCache.SynchronizeReply {
        // The reply owns both filters, which are filled in place.
        var reply = WebKit.NetworkCache.SynchronizeReply()

        // Most of the disk space usage is in blobs if we are using them. Approximate records file sizes to avoid expensive stat() calls.
        var recordCount: UInt32 = 0
        var blobCount: UInt32 = 0

        traverseRecordsFiles(recordsPath.string, WTF.String()) { fileName, hashString, _, isBlob, recordDirectoryPath in
            let filePath = networkCachePath(recordDirectoryPath, fileName)

            guard let parsedHash = WebKit.NetworkCache.Key.stringToHash(hashString).value else {
                _ = WTF.FileSystemImpl.deleteFile(filePath)
                return
            }

            if isBlob {
                blobCount &+= 1
                reply.blobFilter.add(parsedHash)
                return
            }

            recordCount &+= 1
            reply.recordFilter.add(parsedHash)
        }

        let recordsSize = estimateRecordsSize(recordCount: recordCount, blobCount: blobCount)

        blobStorage.synchronize()

        deleteEmptyRecordsDirectories(recordsPath.string)

        reply.recordsSize = recordsSize
        return reply
    }

    func clearStage(type: NetworkCacheIsolatedString, since: Double) {
        let recordsPath = recordsPath.string
        traverseRecordsFiles(recordsPath, type.string) { fileName, _, _, _, recordDirectoryPath in
            let filePath = networkCachePath(recordDirectoryPath, fileName)
            if since > -Double.infinity {
                let times = fileTimes(filePath)
                if times.modification.seconds < since {
                    return
                }
            }
            _ = WTF.FileSystemImpl.deleteFile(filePath)
        }

        deleteEmptyRecordsDirectories(recordsPath)

        // This cleans unreferenced blobs.
        blobStorage.synchronize()
    }

    func shrinkStage() {
        traverseRecordsFiles(recordsPath.string, WTF.String()) { fileName, _, _, isBlob, recordDirectoryPath in
            if isBlob {
                return
            }
            let recordPath = networkCachePath(recordDirectoryPath, fileName)
            let blobPath = Self.blobPath(forRecordPath: recordPath)

            let times = fileTimes(recordPath)
            let bodyShareCount = blobStorage.shareCount(blobPath)
            let probability = deletionProbability(times, bodyShareCount)

            let shouldDelete = WTF.cryptographicallyRandomUnitInterval() < probability
            if shouldDelete {
                _ = WTF.FileSystemImpl.deleteFile(recordPath)
                blobStorage.remove(blobPath)
            }
        }
    }
}
