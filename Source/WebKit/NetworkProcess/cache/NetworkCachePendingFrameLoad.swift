// Copyright (C) 2015-2025 Apple Inc. All rights reserved.
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

/// The loads of one frame, from its main resource until no load has come for the hysteresis time, or the next main resource.
final class NetworkCachePendingFrameLoad {
    // PAL::HysteresisActivity's default.
    private static let loadHysteresisSeconds = 5.0

    // The frame's stored subresources entry: not retrieved yet, retrieved and absent, or retrieved.
    private enum ExistingEntry {
        case pending
        case absent
        case loaded(NetworkCacheSubresourcesEntry)

        var isPending: Bool {
            if case .pending = self {
                return true
            }
            return false
        }
    }

    // Weak; the storage must outlive the load, and saving without it traps.
    private weak var storage: NetworkCacheStorage?
    private let mainResourceKey: WebKit.NetworkCache.Key
    private var subresourceLoads: [NetworkCacheSubresourceLoad] = []
    private let loadCompletionHandler: () -> Void
    private let loadHysteresisTimer = WebKit.NetworkCache.OneShotTimer.create().get()
    private var existingEntry = ExistingEntry.pending
    private var postMainResourceResponseTasks: [() -> Void] = []
    private var didFinishLoad = false
    private(set) var didReceiveMainResourceResponse = false

    init(storage: NetworkCacheStorage, mainResourceKey: borrowing WebKit.NetworkCache.Key, loadCompletionHandler: @escaping () -> Void) {
        self.storage = storage
        self.mainResourceKey = copy mainResourceKey
        self.loadCompletionHandler = loadCompletionHandler
        loadHysteresisTimer.setHandler(
            consuming: .init { [weak self] in
                self?.markLoadAsCompleted()
            }
        )
        impulse()
    }

    // The load stops once no impulse has come for the hysteresis time.
    private func impulse() {
        loadHysteresisTimer.startOneShot(Self.loadHysteresisSeconds)
    }

    func registerSubresourceLoad(_ request: WebCore.ResourceRequest, _ subresourceKey: WebKit.NetworkCache.Key) {
        assert(WTF.RunLoop.isMain())
        subresourceLoads.append(NetworkCacheSubresourceLoad(request, subresourceKey))
        impulse()
    }

    func markLoadAsCompleted() {
        assert(WTF.RunLoop.isMain())
        if didFinishLoad {
            return
        }
        printSpeculativeLoadingDiagnosticMessageCounts()
        didFinishLoad = true
        saveToDiskIfReady()
        loadCompletionHandler()
    }

    func setExistingSubresourcesEntry(_ entry: NetworkCacheSubresourcesEntry?) {
        assert(existingEntry.isPending)
        existingEntry = entry.map { .loaded($0) } ?? .absent
        saveToDiskIfReady()
    }

    func markMainResourceResponseAsReceived() {
        didReceiveMainResourceResponse = true
        for task in postMainResourceResponseTasks {
            task()
        }
    }

    func addPostMainResourceResponseTask(_ task: @escaping () -> Void) {
        postMainResourceResponseTasks.append(task)
    }

    private func saveToDiskIfReady() {
        if !didFinishLoad || existingEntry.isPending {
            return
        }
        if subresourceLoads.isEmpty {
            return
        }
        let log = WebKit.LogChannel.NetworkCacheSpeculativePreloading().debugLog
        log.log(
            "(NetworkProcess) Saving to disk list of subresources for '\(mainResourceKey.identifierCopy().description, privacy: .public)':"
        )
        for subresourceLoad in subresourceLoads {
            log.log("(NetworkProcess) * Subresource: '\(subresourceLoad.key.identifierCopy().description, privacy: .public)'.")
        }

        guard let storage else {
            fatalError("The cache storage is gone")
        }
        let entry: NetworkCacheSubresourcesEntry
        if case .loaded(let existing) = existingEntry {
            entry = existing.updatingSubresourceLoads(subresourceLoads)
            existingEntry = .loaded(entry)
        } else {
            entry = NetworkCacheSubresourcesEntry(mainResourceKey.subresourcesKey(salt: storage.salt), subresourceLoads)
        }
        storage.store(entry.encodeAsStorageRecord(), storeBlobInMemoryCache: false, nil)
    }
}
