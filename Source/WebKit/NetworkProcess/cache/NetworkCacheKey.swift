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

/// Bytes on their way into a SHA-1, gathered in a fixed buffer so that a string's characters can be narrowed without
/// allocating.
private struct NetworkCacheSHA1Feed: ~Copyable {
    private var bytes: [128 of UInt8]
    private var count: Int

    init() {
        bytes = .init(repeating: 0)
        count = 0
    }

    /// Appends each character narrowed to a byte, a block at a time.
    mutating func append(narrowing characters: Span<UInt16>, to sha1: inout WTF.SHA1) {
        var start = 0
        while start < characters.count {
            if count == bytes.count {
                flush(to: &sha1)
            }
            let blockCount = min(characters.count - start, bytes.count - count)
            for index in 0..<blockCount {
                bytes[count + index] = UInt8(truncatingIfNeeded: characters[start + index])
            }
            count += blockCount
            start += blockCount
        }
    }

    mutating func flush(to sha1: inout WTF.SHA1) {
        if count == 0 {
            return
        }
        sha1.addBytes(bytes.span.extracting(0..<count))
        count = 0
    }
}

/// Feeds `string` to `sha1` as `SHA1::addUTF8Bytes` does: the characters themselves when they are all ASCII, else
/// their UTF-8.
private func addUTF8Bytes(_ sha1: inout WTF.SHA1, _ string: borrowing WTF.String) {
    if string.isNull() {
        return
    }
    if !string.containsOnlyASCII() {
        let utf8 = string.utf8()
        // Typed, so that the Span overload is chosen over the unsafe std.span one.
        let characters: Span<UInt8> = WebKit.NetworkCache.utf8Bytes(utf8)
        sha1.addBytes(characters)
    } else if string.is8Bit() {
        let characters: Span<UInt8> = WebKit.NetworkCache.latin1Bytes(string)
        sha1.addBytes(characters)
    } else {
        var feed = NetworkCacheSHA1Feed()
        let characters: Span<UInt16> = string.checkedSpan16()
        // Every character is ASCII, so it fits in a byte.
        feed.append(narrowing: characters, to: &sha1)
        feed.flush(to: &sha1)
    }
}

/// Feeds the salt's bytes in one call.
private func addSalt(_ sha1: inout WTF.SHA1, _ salt: borrowing WebKit.NetworkCache.Salt) {
    // The salt's `std::array` imports with no `span`, so its bytes are copied out.
    var bytes: [8 of UInt8] = .init(repeating: 0)
    for index in 0..<bytes.count {
        bytes[index] = salt[index]
    }
    sha1.addBytes(bytes.span)
}

private func finish(_ sha1: inout WTF.SHA1) -> WebKit.NetworkCache.Key.HashType {
    var hash = WebKit.NetworkCache.Key.HashType()
    sha1.computeHash(&hash)
    return hash
}

/// The byte two hexadecimal digits spell, or nil if either is not a digit.
private func hexByte(_ high: UInt16, _ low: UInt16) -> UInt8? {
    if !WTF.isASCIIHexDigit(high) || !WTF.isASCIIHexDigit(low) {
        return nil
    }
    return WTF.toASCIIHexValue(high, low)
}

/// The size of a SHA-1 hash, in bytes.
private let hashByteCount = 20

/// The 20 bytes spelled by the 40 hexadecimal digits `character` reads by index, or nil if one of them is not a digit.
///
/// Inlined so each caller's loop reads its span directly.
@inline(__always)
private func hexDigitsToHash(_ character: (Int) -> UInt16) -> WebKit.NetworkCache.Key.HashType? {
    var hash = WebKit.NetworkCache.Key.HashType()
    for index in 0..<hashByteCount {
        guard let byte = hexByte(character(2 * index), character(2 * index + 1)) else {
            return nil
        }
        hash[index] = byte
    }
    return hash
}

/// The uppercase hexadecimal digit of a nibble's low four bits.
func asciiHexDigit(_ nibble: UInt8) -> WTF.Latin1Character {
    WTF.Latin1Character(UInt8(bitPattern: WTF.lowerNibbleToASCIIHexDigit(nibble)))
}

/// The SHA-1 of a key's salt, strings and credentials flag, reading the strings in place.
private func hashOfFields(
    _ partition: borrowing WTF.String,
    _ type: borrowing WTF.String,
    _ identifier: borrowing WTF.String,
    _ range: borrowing WTF.String,
    _ salt: WebKit.NetworkCache.Salt,
    _ includesCredentials: WebKit.NetworkCache.Key.IncludesCredentials
) -> WebKit.NetworkCache.Key.HashType {
    var sha1 = WTF.SHA1()
    addSalt(&sha1, salt)
    addUTF8Bytes(&sha1, partition)
    addUTF8Bytes(&sha1, type)
    addUTF8Bytes(&sha1, identifier)
    addUTF8Bytes(&sha1, range)
    if includesCredentials == .No {
        let withoutCredentials: [1 of UInt8] = [0]
        sha1.addBytes(withoutCredentials.span)
    }
    return finish(&sha1)
}

/// The SHA-1 of a key's salt and partition, reading the partition in place.
private func hashOfPartition(
    _ partition: borrowing WTF.String,
    _ salt: WebKit.NetworkCache.Salt
) -> WebKit.NetworkCache.Key.HashType {
    var sha1 = WTF.SHA1()
    addSalt(&sha1, salt)
    addUTF8Bytes(&sha1, partition)
    return finish(&sha1)
}

extension WebKit.NetworkCache.Key {
    // SHA-1 is not needed as a cryptographic hash: the key is always verified against the entry header.
    // It is suitably sized, fast and available.
    @cxx
    @implementation
    static func computeHash(
        _ partition: WTF.String,
        _ type: WTF.String,
        _ identifier: WTF.String,
        _ range: WTF.String,
        _ salt: WebKit.NetworkCache.Salt,
        _ includesCredentials: IncludesCredentials
    ) -> HashType {
        hashOfFields(partition, type, identifier, range, salt, includesCredentials)
    }

    @cxx
    @implementation
    static func partitionToPartitionHash(_ partition: WTF.String, _ salt: WebKit.NetworkCache.Salt) -> HashType {
        hashOfPartition(partition, salt)
    }

    /// The key of the four strings and both hashes, which read the strings in place before they move into the key.
    ///
    /// The parameters keep the default convention, as a `consuming` one cannot implement a C++ by-value parameter.
    @cxx
    @implementation
    static func computeKey(
        _ partition: WTF.String,
        _ type: WTF.String,
        _ identifier: WTF.String,
        _ range: WTF.String,
        _ salt: WebKit.NetworkCache.Salt,
        _ includesCredentials: IncludesCredentials
    ) -> WebKit.NetworkCache.Key {
        let hash = hashOfFields(partition, type, identifier, range, salt, includesCredentials)
        let partitionHash = hashOfPartition(partition, salt)
        return makeWithHashes(consume partition, consume type, consume identifier, consume range, hash, partitionHash)
    }

    @cxx
    @implementation
    static func partitionToPartitionHashAsString(_ partition: WTF.String, _ salt: WebKit.NetworkCache.Salt) -> WTF.String {
        hashAsString(partitionToPartitionHash(partition, salt))
    }

    @cxx
    @implementation
    static func hashAsString(_ hash: HashType) -> WTF.String {
        var characters: [40 of WTF.Latin1Character] = .init(repeating: WTF.Latin1Character())
        for index in 0..<hashByteCount {
            let byte = hash[index]
            characters[2 * index] = asciiHexDigit(byte >> 4)
            characters[2 * index + 1] = asciiHexDigit(byte & 0xF)
        }
        return WTF.String(characters.span)
    }

    @cxx
    @implementation
    static func stringToHash(_ string: WTF.String) -> OptionalHashType {
        if Int(string.length()) != 2 * hashByteCount {
            return OptionalHashType()
        }
        if string.is8Bit() {
            let characters: Span<WTF.Latin1Character> = string.span8()
            return OptionalHashType(optional: hexDigitsToHash { UInt16(characters[$0].value) })
        }
        let characters: Span<UInt16> = string.checkedSpan16()
        return OptionalHashType(optional: hexDigitsToHash { characters[$0] })
    }

    /// The record type the key's type names, or nil for any other type.
    var recordType: WebKit.NetworkCache.RecordType? {
        let typeName = typeCopy()
        if typeName == WebKit.NetworkCache.recordTypeNameString(.Resource) {
            return .Resource
        }
        if typeName == WebKit.NetworkCache.recordTypeNameString(.CompressionDictionary) {
            return .CompressionDictionary
        }
        return nil
    }
}

/// A cache key as a dictionary key, hashed as WTF's HashMap<Key, ...> hashes it.
struct NetworkCacheHashableKey: Hashable {
    let key: WebKit.NetworkCache.Key

    init(_ key: borrowing WebKit.NetworkCache.Key) {
        self.key = copy key
    }

    static func == (lhs: NetworkCacheHashableKey, rhs: NetworkCacheHashableKey) -> Bool {
        lhs.key == rhs.key
    }

    func hash(into hasher: inout Swift.Hasher) {
        hasher.combine(WebKit.NetworkCache.networkCacheKeyHash(key))
    }
}

/// A frame identifier as a dictionary key, hashed and compared as WTF's HashMap<GlobalFrameID, ...> does.
struct NetworkCacheHashableFrameID: Hashable {
    let frameID: WebKit.NetworkCache.GlobalFrameID

    init(_ frameID: borrowing WebKit.NetworkCache.GlobalFrameID) {
        self.frameID = copy frameID
    }

    static func == (lhs: NetworkCacheHashableFrameID, rhs: NetworkCacheHashableFrameID) -> Bool {
        lhs.frameID == rhs.frameID
    }

    func hash(into hasher: inout Swift.Hasher) {
        hasher.combine(WebKit.NetworkCache.globalFrameIDHash(frameID))
    }
}
