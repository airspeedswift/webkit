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

import WebKit_Internal.NetworkCacheCxx
import wtf

#if canImport(Darwin)
import Darwin
#endif

enum NetworkCacheDirectoryEntryType {
    case directory
    case file
}

/// Calls `body` with the name and type of each entry of the directory at `path`.
///
/// A symbolic link is a file; an entry whose type cannot be read is skipped.
func networkCacheTraverseDirectory(
    _ path: borrowing WTF.String,
    _ body: (borrowing WTF.String, NetworkCacheDirectoryEntryType) -> Void
) {
    var cursor = WebKit.NetworkCache.DirectoryCursor(path)
    while let entry = cursor.next().value {
        body(entry.name, entry.type == .Directory ? .directory : .file)
    }
}

func networkCachePath(_ path: borrowing WTF.String, _ component: borrowing WTF.String) -> WTF.String {
    WebKit.NetworkCache.networkCachePathByAppendingComponent(path, component)
}

struct NetworkCacheFileTimes {
    var creation = WTF.WallTime()
    var modification = WTF.WallTime()

    var recordWorth: Double {
        let age = WTF.WallTime.nowSeconds - creation.seconds
        // File modification time is updated manually on cache read. We don't use access time since OS may update it automatically.
        let accessAge = modification.seconds - creation.seconds

        // For sanity.
        if age <= 0 || accessAge < 0 || accessAge > age {
            return 0
        }

        // We like old entries that have been accessed recently.
        return accessAge / age
    }
}

func fileTimes(_ path: borrowing WTF.String) -> NetworkCacheFileTimes {
    #if canImport(Darwin)
    var fileInfo = Darwin.stat()
    let representation = WTF.FileSystemImpl.fileSystemRepresentation(path)
    if WTF.FileSystemImpl.statFile(representation.spanIncludingNullTerminator(), &fileInfo) != 0 {
        return NetworkCacheFileTimes()
    }
    return NetworkCacheFileTimes(
        creation: WebKit.NetworkCache.wallTimeFromRawSeconds(Double(fileInfo.st_birthtimespec.tv_sec)),
        modification: WebKit.NetworkCache.wallTimeFromRawSeconds(Double(fileInfo.st_mtimespec.tv_sec))
    )
    #elseif os(Windows)
    let creation = WTF.FileSystemImpl.fileCreationTime(path).value ?? WTF.WallTime()
    let modification = WTF.FileSystemImpl.fileModificationTime(path).value ?? WTF.WallTime()
    return NetworkCacheFileTimes(creation: creation, modification: modification)
    #else
    // Linux has no st_birthtime; the creation time is an xattr, read through GIO in C++.
    let times = WebKit.NetworkCache.glibFileTimes(path)
    return NetworkCacheFileTimes(creation: times.creation, modification: times.modification)
    #endif
}

func updateFileModificationTimeIfNeeded(_ path: borrowing WTF.String) {
    let times = fileTimes(path)
    if times.creation.seconds != times.modification.seconds {
        // Don't update more than once per hour.
        let sinceModification = WTF.WallTime.nowSeconds - times.modification.seconds
        if sinceModification < 60 * 60 {
            return
        }
    }
    _ = WTF.FileSystemImpl.updateFileModificationTime(path)
}
