// Copyright (C) 2014-2025 Apple Inc. All rights reserved.
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

/// The cache's compression dictionaries by partition, and what changed while the startup scan ran.
struct NetworkCacheCompressionDictionaryIndex {
    /// A registered dictionary.
    struct Entry {
        let key: WebKit.NetworkCache.Key
        let hash: WebKit.NetworkCache.CompressionDictionaryHash
        let id: WTF.String
        let pattern: WebKit.NetworkCache.DictionaryPattern
        let matchDest: WebKit.NetworkCache.CompressionDictionaryDestinationSet
        let matchLength: UInt32
        let expirationTime: Double
        let timeStamp: Double

        // https://www.rfc-editor.org/rfc/rfc9842#name-multiple-matching-dictionar
        func isBetterMatch(than best: borrowing Self) -> Bool {
            let hasDest = !matchDest.isEmpty()
            let bestHasDest = !best.matchDest.isEmpty()
            if hasDest != bestHasDest {
                return hasDest
            }
            if matchLength != best.matchLength {
                return matchLength > best.matchLength
            }
            return timeStamp > best.timeStamp
        }
    }

    /// What changed while the startup scan ran, so records it delivers late can be skipped.
    private struct Population {
        // One time per key, the last one set.
        var removedKeys: [NetworkCacheHashableKey: Double] = [:]
        var clearedSince = Double.infinity

        mutating func setRemoved(_ key: WebKit.NetworkCache.Key, _ time: Double) {
            removedKeys[NetworkCacheHashableKey(key)] = time
        }

        mutating func setCleared(since time: Double) {
            clearedSince = min(clearedSince, time)
        }
    }

    // A storage shrink does not report evictions, so an entry can outlive its record.
    private var entriesByPartition: [NetworkCacheIsolatedString: [Entry]] = [:]
    // Set while the startup scan runs.
    private var population: Population?

    var isEmpty: Bool { entriesByPartition.isEmpty }

    func entries(inPartition partition: NetworkCacheIsolatedString) -> [Entry] {
        entriesByPartition[partition] ?? []
    }

    /// The partition's entries that have not expired at `now`; each expired one is dropped and passed to `expired`.
    mutating func unexpiredEntries(
        inPartition partition: NetworkCacheIsolatedString,
        now: Double,
        _ expired: (Entry) -> Void
    ) -> [Entry] {
        updateEntries(inPartition: partition) { entries in
            entries.removeAll { entry in
                if entry.expirationTime > now {
                    return false
                }
                expired(entry)
                return true
            }
            return entries
        } ?? []
    }

    mutating func add(_ entry: consuming Entry) {
        entriesByPartition[NetworkCacheIsolatedString(entry.key.partitionCopy()), default: []].append(entry)
    }

    /// Returns false, keeping the entry, if it was registered after `registeredNotAfter`.
    @discardableResult
    mutating func remove(_ key: WebKit.NetworkCache.Key, registeredNotAfter: Double) -> Bool {
        if key.recordType != .CompressionDictionary {
            return true
        }

        let partition = NetworkCacheIsolatedString(key.partitionCopy())
        let kept = updateEntries(inPartition: partition) { entries in
            guard let index = entries.firstIndex(where: { $0.key == key }) else {
                return false
            }
            if entries[index].timeStamp > registeredNotAfter {
                return true
            }
            entries.remove(at: index)
            return false
        }
        if kept ?? false {
            return false
        }

        population?.setRemoved(key, WTF.WallTime.nowSeconds)
        return true
    }

    /// Calls `body` on the partition's entries in place, then drops the partition if none are left; nil if it has none.
    private mutating func updateEntries<Result>(
        inPartition partition: NetworkCacheIsolatedString,
        _ body: (inout [Entry]) -> Result
    ) -> Result? {
        guard let index = entriesByPartition.index(forKey: partition) else {
            return nil
        }
        let result = body(&entriesByPartition.values[index])
        if entriesByPartition.values[index].isEmpty {
            entriesByPartition.remove(at: index)
        }
        return result
    }

    mutating func clear(since: Double) {
        entriesByPartition =
            entriesByPartition
            .mapValues { entries in
                entries.filter { $0.timeStamp < since }
            }
            .filter { !$0.value.isEmpty }
        population?.setCleared(since: since)
    }

    mutating func beginPopulation() {
        population = Population()
    }

    mutating func endPopulation() {
        population = nil
    }

    /// Whether the startup scan adds a record: not after the scan ended, nor one cleared or removed since it began.
    func shouldPopulate(_ key: WebKit.NetworkCache.Key, timeStamp: Double) -> Bool {
        guard let population else {
            return false
        }
        if timeStamp >= population.clearedSince {
            return false
        }
        if let removedTime = population.removedKeys[NetworkCacheHashableKey(key)], timeStamp <= removedTime {
            return false
        }
        return true
    }
}
