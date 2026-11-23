// Copyright (C) 2015-2026 Apple Inc. All rights reserved.
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

/// A blob file's contents and the salted SHA-1 of its bytes.
struct NetworkCacheBlob {
    var data = WebKit.NetworkCache.Data()
    var hash = WTF.SHA1.Digest()
}

/// BlobStorage deduplicates the data using SHA1 hash computed over the blob bytes.
///
/// On Cocoa, main resource blobs are also kept in memory, up to a number of files; a random one is dropped past the
/// limit.
final class NetworkCacheBlobStorage: Sendable {
    private let blobDirectoryPath: NetworkCacheIsolatedString
    private let salt: WebKit.NetworkCache.Salt
    private let approximateSizeInBytes = Atomic<UInt>(0)
    // Nil when there is no memory cache.
    private let memoryCache: NetworkCacheBlobMemoryCache?

    init(blobDirectoryPath: borrowing WTF.String, salt: WebKit.NetworkCache.Salt, memoryCacheFileLimit: UInt32 = 0) {
        self.blobDirectoryPath = NetworkCacheIsolatedString(blobDirectoryPath)
        self.salt = salt
        if WebKit.NetworkCache.networkCacheBlobMemoryCacheEnabled && memoryCacheFileLimit != 0 {
            memoryCache = NetworkCacheBlobMemoryCache(fileLimit: Int(memoryCacheFileLimit))
        } else {
            memoryCache = nil
        }
    }

    var approximateSize: Int {
        Int(bitPattern: approximateSizeInBytes.load(ordering: .sequentiallyConsistent))
    }

    func synchronize() {
        assert(!WTF.RunLoop.isMain())
        let blobDirectory = blobDirectoryPath.string
        _ = WTF.FileSystemImpl.makeAllDirectories(blobDirectory)

        approximateSizeInBytes.store(0, ordering: .sequentiallyConsistent)
        networkCacheTraverseDirectory(blobDirectory) { name, type in
            if type != .file {
                return
            }
            let path = networkCachePath(blobDirectory, name)
            let linkCount = WTF.FileSystemImpl.hardLinkCount(path).value
            // No clients left for this blob.
            if linkCount == 1 {
                _ = WTF.FileSystemImpl.deleteFile(path)
                memoryCache?.remove(path)
            } else {
                let size = WTF.FileSystemImpl.fileSize(path).value ?? 0
                approximateSizeInBytes.wrappingAdd(UInt(truncatingIfNeeded: size), ordering: .sequentiallyConsistent)
            }
        }

        WebKit.LogChannel.NetworkCacheStorage().debugLog
            .log(
                "(NetworkProcess) blob synchronization completed approximateSize=\(approximateSizeInBytes.load(ordering: .sequentiallyConsistent))"
            )
    }

    private func blobPath(forHash hash: borrowing WTF.SHA1.Digest) -> WTF.String {
        networkCachePath(blobDirectoryPath.string, WebKit.NetworkCache.Key.hashAsString(hash))
    }

    /// Links `path` to the blob file, and logs a failure.
    private func link(_ blobPath: borrowing WTF.String, to path: borrowing WTF.String) {
        if WTF.FileSystemImpl.hardLink(blobPath, path) {
            return
        }
        let pathDescription = path.description
        let blobPathDescription = blobPath.description
        WebKit.LogChannel.NetworkCacheStorage().releaseLog
            .error("Failed to create hard link from \(blobPathDescription, privacy: .public) to \(pathDescription, privacy: .public)")
    }

    func add(
        _ path: borrowing WTF.String,
        _ data: borrowing WebKit.NetworkCache.Data,
        addToMemoryCache: Bool = false
    ) -> NetworkCacheBlob? {
        assert(!WTF.RunLoop.isMain())
        let hash = WebKit.NetworkCache.computeSHA1(data, salt)
        if data.isEmpty() {
            return NetworkCacheBlob(data: copy data, hash: hash)
        }

        let blobFile = blobPath(forHash: hash)

        _ = WTF.FileSystemImpl.deleteFile(path)
        memoryCache?.remove(path)

        if WTF.FileSystemImpl.fileExists(blobFile) {
            if WTF.FileSystemImpl.makeSafeToUseMemoryMapForPath(blobFile) {
                let existingData = WebKit.NetworkCache.mapFile(blobFile)
                if WebKit.NetworkCache.bytesEqual(existingData, data) {
                    link(blobFile, to: path)
                    let result = NetworkCacheBlob(data: existingData, hash: hash)
                    if addToMemoryCache {
                        memoryCache?.add(path, result)
                    }
                    return result
                }
            }
            _ = WTF.FileSystemImpl.deleteFile(blobFile)
        }

        let mappedData = data.mapToFile(blobFile)
        if mappedData.isNull() {
            return nil
        }

        link(blobFile, to: path)

        approximateSizeInBytes.wrappingAdd(UInt(mappedData.size()), ordering: .sequentiallyConsistent)

        let result = NetworkCacheBlob(data: mappedData, hash: hash)
        if addToMemoryCache {
            memoryCache?.add(path, result)
        }
        return result
    }

    func get(_ path: borrowing WTF.String) -> NetworkCacheBlob {
        assert(!WTF.RunLoop.isMain())
        if let blob = memoryCache?.get(path) {
            return blob
        }
        let data = WebKit.NetworkCache.mapFile(path)
        let hash = WebKit.NetworkCache.computeSHA1(data, salt)
        return NetworkCacheBlob(data: data, hash: hash)
    }

    /// Blob won't be removed until synchronization.
    func remove(_ path: borrowing WTF.String) {
        assert(!WTF.RunLoop.isMain())
        _ = WTF.FileSystemImpl.deleteFile(path)
        memoryCache?.remove(path)
    }

    func shareCount(_ path: borrowing WTF.String) -> UInt32 {
        assert(!WTF.RunLoop.isMain())
        guard let linkCount = WTF.FileSystemImpl.hardLinkCount(path).value else {
            return 0
        }
        // Link count is 2 in the single client case (the blob file and a link).
        return UInt32(truncatingIfNeeded: linkCount &- 1)
    }
}

// The memory cache is Cocoa's only; its entries are ~Copyable over dispatch_data_t, so the other platforms get an empty stand-in.
#if canImport(Darwin)
/// Main resource blobs kept in memory, up to a number of files; a random one is dropped past the limit.
private struct NetworkCacheBlobMemoryCache: ~Copyable, Sendable {
    // The stored blob's dispatch data and whether it maps a file, which `Data::copyData` keeps.
    private struct Entry {
        let dispatchData: dispatch_data_t?
        let isMap: Bool
        let hash: WTF.SHA1.Digest
    }

    private let fileLimit: Int
    // Reached on the IO queues, which share each entry's immutable dispatch data.
    private let entries = Mutex<[NetworkCacheIsolatedString: Entry]>([:])

    init(fileLimit: Int) {
        self.fileLimit = fileLimit
    }

    func get(_ path: borrowing WTF.String) -> NetworkCacheBlob? {
        let key = NetworkCacheIsolatedString(path)
        let entry = entries.withLock { $0[key] }
        guard let entry else {
            return nil
        }
        let data = WebKit.NetworkCache.dataWithDispatchData(entry.dispatchData, entry.isMap)
        return NetworkCacheBlob(data: data, hash: entry.hash)
    }

    func add(_ path: borrowing WTF.String, _ blob: borrowing NetworkCacheBlob) {
        let key = NetworkCacheIsolatedString(path)
        let entry = Entry(dispatchData: blob.data.dispatchData(), isMap: blob.data.isMap(), hash: blob.hash)
        let limit = fileLimit
        entries.withLock { cache in
            cache[key] = entry
            if cache.count > limit, let victim = cache.keys.randomElement() {
                cache[victim] = nil
            }
        }
    }

    func remove(_ path: borrowing WTF.String) {
        let key = NetworkCacheIsolatedString(path)
        entries.withLock { $0[key] = nil }
    }
}
#else
private struct NetworkCacheBlobMemoryCache: Sendable {
    init(fileLimit: Int) {
    }

    func get(_ path: borrowing WTF.String) -> NetworkCacheBlob? {
        nil
    }

    func add(_ path: borrowing WTF.String, _ blob: borrowing NetworkCacheBlob) {
    }

    func remove(_ path: borrowing WTF.String) {
    }
}
#endif
