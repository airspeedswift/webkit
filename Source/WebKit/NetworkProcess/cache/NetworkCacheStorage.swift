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

private let saltFileName = "salt"

/// A retrieve's handler, called once.
typealias NetworkCacheStorageRetrieveHandler = (consuming WebKit.NetworkCache.Storage.Record, WebKit.NetworkCache.Storage.Timings) -> Bool
/// A store's mapped body handler, called on the main thread once the body is stored as a blob.
typealias NetworkCacheStorageMappedBodyHandler = (borrowing WebKit.NetworkCache.Data) -> Void
/// A traversal's handler, called on the main thread for each record and then once with none.
typealias NetworkCacheStorageTraverseHandler = (consuming WebKit.NetworkCache.Storage.Record?, WebKit.NetworkCache.Storage.RecordInfo) ->
    Void

// MARK: - Storage (main thread)

/// The cache's storage.
///
/// Every member is called on the main thread, except the test entries.
@_expose(Cxx)
public final class NetworkCacheStorage {
    /// A synchronization or a shrink in progress, never both.
    private enum Activity {
        case idle
        // The hashes added to the filters while the synchronization runs, added to its new filters when it ends.
        case synchronizing(AddedHashes)
        case shrinking

        struct AddedHashes {
            var record: [WebKit.NetworkCache.Key.HashType]
            var blob: [WebKit.NetworkCache.Key.HashType]
        }

        mutating func synchronizationAdded(
            _ hash: WebKit.NetworkCache.Key.HashType,
            to hashes: WritableKeyPath<AddedHashes, [WebKit.NetworkCache.Key.HashType]>
        ) {
            guard case .synchronizing(var added) = self else {
                return
            }
            // Releases the stored array first, so the append does not copy it.
            self = .idle
            added[keyPath: hashes].append(hash)
            self = .synchronizing(added)
        }
    }

    @_expose(!Cxx)
    let io: NetworkCacheStorageIO
    let mode: WebKit.NetworkCache.Storage.Mode
    private(set) var capacity: Int
    var approximateRecordsSize = 0

    // Null until the first synchronization, as the C++ storage's.
    private var recordFilter = WebKit.NetworkCache.ContentsFilterPointer()
    private var blobFilter = WebKit.NetworkCache.ContentsFilterPointer()

    private var activity = Activity.idle
    var readOperationDispatchCount = 0

    var synchronizationInProgress: Bool {
        if case .synchronizing = activity {
            return true
        }
        return false
    }

    var shrinkInProgress: Bool {
        if case .shrinking = activity {
            return true
        }
        return false
    }

    @_expose(!Cxx)
    var pendingReadOperations: [NetworkCacheReadOperation] = []
    @_expose(!Cxx)
    var activeReadOperations: [UInt64: NetworkCacheReadOperation] = [:]
    // The active reads' identifiers, in the order they are canceled in.
    let activeReadOperationOrder = WebKit.NetworkCache.ReadOperationOrder.create().get()
    let readOperationTimeoutTimer: WebKit.NetworkCache.OneShotTimer

    // First is the newest; writes are dispatched from the end.
    @_expose(!Cxx)
    var pendingWriteOperations: [NetworkCacheWriteOperation] = []
    @_expose(!Cxx)
    var activeWriteOperations: [NetworkCacheWriteOperation] = []
    let writeOperationDispatchTimer: WebKit.NetworkCache.OneShotTimer

    let ioQueue: WebKit.NetworkCache.NetworkCacheQueue
    let backgroundIOQueue: WebKit.NetworkCache.NetworkCacheQueue
    private let serialBackgroundIOQueue: WebKit.NetworkCache.NetworkCacheQueue

    static func open(
        at baseCachePath: WTF.String,
        mode: WebKit.NetworkCache.Storage.Mode,
        capacity: Int,
        mainResourceBlobMemoryCacheFileLimit: Int
    ) -> NetworkCacheStorage? {
        assert(WTF.RunLoop.isMain())
        assert(!baseCachePath.isNull())

        let cachePath = WebKit.NetworkCache.makeCachePath(baseCachePath)
        let isNewCachePath = !(cachePath == baseCachePath)
        if isNewCachePath {
            if !WTF.FileSystemImpl.makeAllDirectories(cachePath) {
                return nil
            }
            _ = WTF.FileSystemImpl.setExcludedFromBackup(cachePath, true)
        }

        let versionedPath = versionedDirectoryPath(cachePath)
        if !WTF.FileSystemImpl.makeAllDirectories(versionedPath) {
            return nil
        }
        if !isNewCachePath {
            _ = WTF.FileSystemImpl.setExcludedFromBackup(versionedPath, true)
        }

        let saltPath = networkCachePath(versionedPath, WTF.String(saltFileName))
        guard let salt = WTF.FileSystemImpl.readOrMakeSalt(saltPath).value else {
            return nil
        }
        return NetworkCacheStorage(cachePath, mode, salt, capacity, UInt32(truncatingIfNeeded: mainResourceBlobMemoryCacheFileLimit))
    }

    private init(
        _ baseDirectoryPath: borrowing WTF.String,
        _ mode: WebKit.NetworkCache.Storage.Mode,
        _ salt: WebKit.NetworkCache.Salt,
        _ capacity: Int,
        _ mainResourceBlobMemoryCacheFileLimit: UInt32
    ) {
        io = NetworkCacheStorageIO(
            basePath: baseDirectoryPath,
            salt: salt,
            mainResourceBlobMemoryCacheFileLimit: mainResourceBlobMemoryCacheFileLimit
        )
        self.mode = mode
        self.capacity = capacity
        readOperationTimeoutTimer = WebKit.NetworkCache.OneShotTimer.create().get()
        writeOperationDispatchTimer = WebKit.NetworkCache.OneShotTimer.create().get()
        ioQueue = WebKit.NetworkCache.makeIOQueue().get()
        backgroundIOQueue = WebKit.NetworkCache.makeBackgroundIOQueue().get()
        serialBackgroundIOQueue = WebKit.NetworkCache.makeSerialBackgroundIOQueue().get()

        assert(WTF.RunLoop.isMain())
        deleteOldVersions()
        synchronize()
    }

    // MARK: Entries for NetworkCacheTestSupport

    /// Encodes `record` as the write path does.
    ///
    /// `record` is borrowed for the call from a local of NetworkCacheTestSupport. The only C++ called with it is
    /// `RecordFormat::encodeRecord`, which reads it.
    public func testEncodeRecord(
        _ record: borrowing WebKit.NetworkCache.Storage.Record,
        _ hasBlob: Bool,
        _ blobHash: WTF.SHA1.Digest
    ) -> WebKit.NetworkCache.Data {
        io.encodeRecord(record, hasBlob: hasBlob, blobHash: blobHash)
    }

    /// Decodes a record file as the read path does; a null record on failure.
    ///
    /// `recordData` is borrowed for the call; NetworkCacheTestSupport passes a temporary. The only C++ called with it
    /// is `RecordFormat::readRecord`, which reads a span of it while it parses.
    public func testReadRecord(_ recordData: borrowing WebKit.NetworkCache.Data) -> WebKit.NetworkCache.Storage.Record {
        io.readRecord(recordData)?.record ?? WebKit.NetworkCache.Storage.Record()
    }

    /// Adds `data` for `path` to a blob storage in `blobDirectory`, then reads it back.
    ///
    /// `blobDirectory`, `path` and `data` are borrowed for the call from locals and a temporary of
    /// NetworkCacheTestSupport. The blob storage copies the directory into an isolated string; adding, counting
    /// shares and reading are Swift, with the SHA-1 of `data` and file IO by path. No callback runs.
    public static func testBlobAddGet(
        _ blobDirectory: WTF.String,
        _ salt: WebKit.NetworkCache.Salt,
        _ path: WTF.String,
        _ data: WebKit.NetworkCache.Data
    ) -> WebKit.NetworkCache.TestBlobResult {
        let storage = NetworkCacheBlobStorage(blobDirectoryPath: blobDirectory, salt: salt)
        let added = storage.add(path, data)
        var result = WebKit.NetworkCache.TestBlobResult()
        if let added {
            result.hash = added.hash
        }
        result.shareCount = storage.shareCount(path)
        result.data = storage.get(path).data
        return result
    }

    /// No write pending or in progress, and no synchronization or shrink in progress.
    public func isIdle() -> Bool {
        pendingWriteOperations.isEmpty && activeWriteOperations.isEmpty && !synchronizationInProgress && !shrinkInProgress
    }

    /// A read pending or in progress.
    public func isReading() -> Bool {
        !pendingReadOperations.isEmpty || !activeReadOperations.isEmpty
    }

    deinit {
        assert(WTF.RunLoop.isMain())
        assert(activeReadOperations.isEmpty)
        assert(activeWriteOperations.isEmpty)
        assert(!synchronizationInProgress)
        assert(!shrinkInProgress)
    }

    /// The salt mixed into every key hash of this storage.
    public var salt: WebKit.NetworkCache.Salt {
        io.salt
    }

    /// The storage's directory, as a string the caller's thread owns.
    public func basePathIsolatedCopy() -> WTF.String {
        io.basePath.string
    }

    var versionPath: WTF.String {
        versionedDirectoryPath(io.basePath.string)
    }

    func recordsPathIsolatedCopy() -> WTF.String {
        io.recordsPath.string
    }

    var approximateSize: Int {
        approximateRecordsSize &+ io.blobStorage.approximateSize
    }

    // MARK: Synchronization

    private func synchronize() {
        assert(WTF.RunLoop.isMain())

        guard case .idle = activity else {
            return
        }
        var writeHashes = pendingWriteOperations.map { $0.record.key.hashCopy() }
        writeHashes.append(contentsOf: activeWriteOperations.lazy.map { $0.record.key.hashCopy() })
        activity = .synchronizing(.init(record: writeHashes, blob: []))

        let io = io
        WebKit.NetworkCache.dispatchSynchronizeWithReplyOnMain(
            backgroundIOQueue,
            consuming: .init(sendable: { io.synchronizeStage() }),
            consuming: .init { [self] (reply: consuming WebKit.NetworkCache.SynchronizeReply) in
                if case .synchronizing(let added) = activity {
                    for hash in added.record {
                        reply.recordFilter.add(hash)
                    }
                    for hash in added.blob {
                        reply.blobFilter.add(hash)
                    }
                }

                swap(&recordFilter, &reply.recordFilter)
                swap(&blobFilter, &reply.blobFilter)
                approximateRecordsSize = reply.recordsSize
                activity = .idle
                if mode == .AvoidRandomness {
                    dispatchPendingWriteOperations()
                }
            }
        )
    }

    func addToRecordFilter(_ key: borrowing WebKit.NetworkCache.Key) {
        assert(WTF.RunLoop.isMain())
        let hash = key.hashCopy()
        recordFilter.add(hash)

        // If we get new entries during filter synchronization take care to add them to the new filter as well.
        activity.synchronizationAdded(hash, to: \.record)
    }

    func addToBlobFilter(_ key: borrowing WebKit.NetworkCache.Key) {
        assert(WTF.RunLoop.isMain())
        let hash = key.hashCopy()
        blobFilter.add(hash)

        activity.synchronizationAdded(hash, to: \.blob)
    }

    func mayContain(_ key: borrowing WebKit.NetworkCache.Key) -> Bool {
        assert(WTF.RunLoop.isMain())
        return recordFilter.mayContain(key.hashCopy())
    }

    func mayContainBlob(_ key: borrowing WebKit.NetworkCache.Key) -> Bool {
        assert(WTF.RunLoop.isMain())
        return blobFilter.mayContain(key.hashCopy())
    }

    // MARK: Removal

    private func removeFromPendingWriteOperations(_ key: WebKit.NetworkCache.Key) {
        assert(WTF.RunLoop.isMain())
        pendingWriteOperations.removeAll { $0.record.key == key }
    }

    /// `std::optional<String>` parameters import with no members, so a flag stands for nullopt.
    func pendingWriteKeys(
        ofType type: borrowing WTF.String,
        hasPartition: Bool,
        partition: WTF.String
    ) -> WebKit.NetworkCache.KeyVector {
        assert(WTF.RunLoop.isMain())
        var keys = WebKit.NetworkCache.KeyVector()
        // The key is read in place: a `let` copy of it, or its by-value type(), would copy for every pending write.
        for operation in pendingWriteOperations
        where operation.record.key.typeEquals(type)
            && (!hasPartition || WTF.equalIgnoringNullity(operation.record.key.partitionCopy(), partition))
        {
            keys.append(consuming: operation.record.key)
        }
        return keys
    }

    func remove(_ key: borrowing WebKit.NetworkCache.Key) {
        assert(WTF.RunLoop.isMain())
        if !mayContain(key) {
            return
        }
        // We can't remove the key from the Bloom filter (but some false positives are expected anyway).
        // For simplicity we also don't reduce the approximate size on removals.
        // The next synchronization will update everything.
        removeFromPendingWriteOperations(key)

        let io = io
        let isolatedKey = NetworkCacheIsolatedKey(key)
        serialBackgroundIOQueue.dispatch(
            consuming: .init(sendable: {
                io.deleteFiles(isolatedKey.key)
            })
        )
    }

    func remove(
        _ keys: borrowing WebKit.NetworkCache.KeyVector,
        _ completionHandler: consuming WTF.VoidCompletionHandler
    ) {
        assert(WTF.RunLoop.isMain())
        var keysToRemove: [NetworkCacheIsolatedKey] = []
        for index in 0..<keys.size() {
            let key = keys[index]
            if !mayContain(key) {
                continue
            }
            removeFromPendingWriteOperations(key)
            keysToRemove.append(NetworkCacheIsolatedKey(key))
        }

        let io = io
        let removedKeys = keysToRemove
        WebKit.NetworkCache.dispatchWithReplyOnMain(
            serialBackgroundIOQueue,
            consuming: .init(sendable: {
                for key in removedKeys {
                    io.deleteFiles(key.key)
                }
            }),
            consuming: consume completionHandler
        )
    }

    func updateFileModificationTime(_ path: borrowing WTF.String) {
        let isolatedPath = NetworkCacheIsolatedString(path)
        serialBackgroundIOQueue.dispatch(
            consuming: .init(sendable: {
                updateFileModificationTimeIfNeeded(isolatedPath.string)
            })
        )
    }

    // MARK: Traversal

    /// A C++ caller's traversal.
    ///
    /// `type` is borrowed for the call. NetworkCacheWebsiteData passes the string `recordTypeName(...)` returns, and
    /// NetworkCacheTestSupport passes `emptyString()`. The traversal takes an isolated copy of it, and no other C++
    /// is called with it.
    public func traverse(_ type: WTF.String, _ flags: UInt8, _ traverseHandler: WebKit.NetworkCache.StorageTraverseHandlerBox) {
        traverse(type, partition: nil, flags) { record, info in
            if let record {
                WebKit.NetworkCache.invokeStorageTraverseHandler(traverseHandler, record, info)
            } else {
                WebKit.NetworkCache.invokeStorageTraverseHandlerAtEnd(traverseHandler)
            }
        }
    }

    // MARK: Capacity, clear, shrink

    func setCapacity(_ capacity: Int) {
        assert(WTF.RunLoop.isMain())
        if self.capacity == capacity {
            return
        }

        let assumedAverageRecordSize = 50 << 10
        // ~10 bits per element are required for <1% false positive rate.
        // If this gets hit it might be time to increase the filter size.
        // The filter is its bit array, one bit per table entry: `tableSize`, a template's static member, does not import.
        let tableSize = MemoryLayout<WebKit.NetworkCache.ContentsFilter>.size * 8
        assert(capacity / assumedAverageRecordSize < tableSize / 10)
        self.capacity = capacity
        shrinkIfNeeded()
    }

    func clear(
        ofType type: WTF.String,
        modifiedSince modifiedSinceTime: WTF.WallTime,
        _ completionHandler: consuming WTF.VoidCompletionHandler
    ) {
        assert(WTF.RunLoop.isMain())
        recordFilter.clear()
        blobFilter.clear()
        approximateRecordsSize = 0

        let since = modifiedSinceTime.seconds
        pendingWriteOperations.removeAll { operation in
            (type.isEmpty() || operation.record.key.typeCopy() == type) && operation.record.timeStamp.seconds >= since
        }

        let io = io
        let isolatedType = NetworkCacheIsolatedString(type)
        WebKit.NetworkCache.dispatchWithReplyOnMain(
            ioQueue,
            consuming: .init(sendable: { io.clearStage(type: isolatedType, since: since) }),
            consuming: consume completionHandler
        )
    }

    func shrinkIfNeeded() {
        assert(WTF.RunLoop.isMain())
        // Avoid randomness caused by cache shrinks.
        if mode == .AvoidRandomness {
            return
        }
        if approximateSize > capacity {
            shrink()
        }
    }

    private func shrink() {
        assert(WTF.RunLoop.isMain())
        guard case .idle = activity else {
            return
        }
        activity = .shrinking

        let io = io
        WebKit.NetworkCache.dispatchWithReplyOnMain(
            backgroundIOQueue,
            consuming: .init(sendable: { io.shrinkStage() }),
            consuming: .init { [self] in
                activity = .idle
                // We could synchronize during the shrink traversal. However this is fast and it is better to have just one code path.
                synchronize()
            }
        )
    }

    private func deleteOldVersions() {
        let cachePath = io.basePath
        backgroundIOQueue.dispatch(
            consuming: .init(sendable: {
                let path = cachePath.string
                networkCacheTraverseDirectory(path) { subdirName, type in
                    if type != .directory {
                        return
                    }
                    guard let directoryVersion = WebKit.NetworkCache.versionOfDirectory(subdirName).value,
                        directoryVersion < WebKit.NetworkCache.Storage.version
                    else {
                        return
                    }
                    _ = WTF.FileSystemImpl.deleteNonEmptyDirectory(networkCachePath(path, subdirName))
                }
            })
        )
    }
}

// The synchronization's IO stage and its reply.
extension WebKit.NetworkCache.SynchronizeWork: CxxResultFunction {
    typealias Output = WebKit.NetworkCache.SynchronizeReply

    init(sendable body: @escaping @Sendable () -> WebKit.NetworkCache.SynchronizeReply) {
        self.init(cxxSendable: body)
    }
}

extension WebKit.NetworkCache.SynchronizeReplyHandler: CxxConsumingCompletionHandler {
    typealias Argument = WebKit.NetworkCache.SynchronizeReply
}
