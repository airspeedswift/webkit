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

/// The handler of one traversal of the cache's records.
///
/// The IO queue holds a reference but never reads `handler`, which the main thread calls and releases under the lock.
///
/// The lock is recursive because a handler that runs the main run loop lets the next record's read completion call the
/// handler again on the main thread while the lock is held. Each region calls a copy of `handler` and writes the copy
/// back. Only the last call, with no record, takes the handler, and it is dispatched after every record's slot is
/// signaled, which follows that record's region, so no region is open around it to write the handler back.
final class NetworkCacheTraverseOperation: @unchecked Sendable {
    /// WTF::RecursiveLock's algorithm.
    ///
    /// Only the thread that holds the lock finds its own ID in owner, so a nested withLock on that thread runs its
    /// body directly.
    private struct RecursiveLock: ~Copyable, Sendable {
        private let mutex = Mutex<Void>(())
        private let owner = Atomic<UInt32>(0)

        borrowing func withLock<Result: Sendable>(_ body: () -> Result) -> Result {
            let currentThreadID = WTF.currentThreadID()
            if owner.load(ordering: .relaxed) == currentThreadID {
                return body()
            }
            return mutex.withLock { _ in
                owner.store(currentThreadID, ordering: .relaxed)
                defer { owner.store(0, ordering: .relaxed) }
                return body()
            }
        }
    }

    private let lock = RecursiveLock()
    private var handler: NetworkCacheStorageTraverseHandler?

    init(_ handler: @escaping NetworkCacheStorageTraverseHandler) {
        assert(WTF.RunLoop.isMain())
        self.handler = handler
    }

    /// Runs `body` with the handler, under the lock. `body` must not keep the handler or anything it reaches.
    func withLock<Result: Sendable>(_ body: (inout NetworkCacheStorageTraverseHandler?) -> Result) -> Result {
        lock.withLock {
            var handler = self.handler
            defer { self.handler = handler }
            return body(&handler)
        }
    }
}

// So a debugger or print never reads `handler` outside the lock.
extension NetworkCacheTraverseOperation: CustomReflectable {
    var customMirror: Mirror {
        Mirror(self, children: [])
    }
}
