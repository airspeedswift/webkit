// Copyright (C) 2017 Apple Inc. All rights reserved.
// Copyright (C) 2026 Apple Inc. All rights reserved.
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

// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// them name (rdar://192229293).
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch

/// A digest in text, `hash-algorithm "-" base64-value`: its algorithm and where its value is.
struct ResourceCryptographicDigestExtent {
    /// The `ResourceCryptographicDigest::Algorithm` value, one of `contentSecurityPolicyHashAlgorithmSHA256`,
    /// `contentSecurityPolicyHashAlgorithmSHA384` and `contentSecurityPolicyHashAlgorithmSHA512`.
    var algorithm: UInt8
    /// Where the base64 value is in the characters, with its padding.
    ///
    /// The digest ends where the value does.
    var value: Range<Int>
}

/// A decoded digest: its `ResourceCryptographicDigest::Algorithm` value and its bytes.
struct ResourceCryptographicDigestBytes {
    var algorithm: UInt8
    var value: [UInt8]
}

/// The digest at `start` in `characters`: `sha256`, `sha384` or `sha512` ignoring ASCII case, `-`, a run of base64 and
/// base64url characters, then at most two `=`.
///
/// Nil when the characters there are not a digest, and when the value is empty. Characters may follow it.
func resourceCryptographicDigestExtent<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    from start: Int
) -> ResourceCryptographicDigestExtent? {
    // The algorithm's six characters and "-" come first. Cannot overflow: start is at least 0, and past this check at
    // most characters.count - 7.
    if start >= characters.count || characters.count &- start < 7 {
        return nil
    }
    guard let algorithm = resourceCryptographicDigestAlgorithm(characters.extracting(start..<start &+ 6)),
        characters[start &+ 6] == 0x2D
    else {
        return nil
    }
    var position = start &+ 7
    let valueStart = position
    while position < characters.count && isBase64OrBase64URLCharacter(characters[position]) {
        position += 1
    }
    if position < characters.count && characters[position] == 0x3D {
        position += 1
    }
    if position < characters.count && characters[position] == 0x3D {
        position += 1
    }
    if position == valueStart {
        return nil
    }
    return ResourceCryptographicDigestExtent(algorithm: algorithm, value: valueStart..<position)
}

/// The bytes of a digest's base64 value: decoded as base64, or as base64url when that fails.
///
/// Nil when neither decodes it. A value may decode to more bytes than any algorithm's digest has.
func resourceCryptographicDigestValue<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ value: Span<CodeUnit>) -> [UInt8]? {
    if let bytes = integrityBase64DecodedBytes(value, url: false) {
        return bytes
    }
    return integrityBase64DecodedBytes(value, url: true)
}

/// Whether resourceCryptographicDigestValue() of `value` is `bytes`, found without decoding into an array: the length
/// the value decodes to is checked first, then each byte as it is decoded, up to the first that differs.
func resourceCryptographicDigestValueEquals<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ value: Span<CodeUnit>,
    _ bytes: Span<UInt8>
) -> Bool {
    if value.isEmpty {
        return bytes.isEmpty
    }
    var count = value.count
    while count > 0 && value[count - 1] == 0x3D {
        count -= 1
    }
    // Valid data is (n * 4 + [0,2,3]) characters long, followed by any number of "=". Cannot overflow: a Span's count
    // is far below Int.max, and (n + 3) / 4 is at most n.
    if count == 0 || count % 4 == 1 || count &- (count &+ 3) / 4 != bytes.count {
        return false
    }
    let characters = value.extracting(0..<count)
    var bits: UInt32 = 0
    var bitCount: UInt32 = 0
    var byteIndex = 0
    var alphabets: UInt8 = 0
    for index in characters.indices {
        let entry = base64DecodeEntry(characters[index])
        if entry == 0xFF {
            return false
        }
        alphabets |= entry
        bits = (bits &<< 6) | UInt32(entry & 0x3F)
        // Cannot overflow: bitCount is below 8 before each character, and byteIndex below bytes.count.
        bitCount &+= 6
        if bitCount >= 8 {
            bitCount &-= 8
            if UInt8(truncatingIfNeeded: bits &>> bitCount) != bytes[byteIndex] {
                return false
            }
            byteIndex &+= 1
        }
    }
    // "+" or "/" and also "-" or "_": neither map has all of them.
    return alphabets & 0xC0 != 0xC0
}

/// base64Decode() with no options, or with Base64DecodeOption::URL when `url` is true: nil where it gives no value.
/// Padding is not validated, so any number of "=" may end the characters, and the bits of the last character past the
/// last byte are ignored. Empty characters decode to no bytes.
func integrityBase64DecodedBytes<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ characters: Span<CodeUnit>, url: Bool) -> [UInt8]? {
    if characters.isEmpty {
        return []
    }

    var sextets: [UInt8] = []
    sextets.reserveCapacity(characters.count)
    var equalsSignCount = 0
    for index in 0..<characters.count {
        let character = characters[index]
        if character == 0x3D {
            equalsSignCount += 1
            continue
        }
        guard let sextet = base64Sextet(character, url: url) else {
            return nil
        }
        if equalsSignCount != 0 {
            return nil
        }
        sextets.append(sextet)
    }

    if sextets.isEmpty {
        return equalsSignCount != 0 ? nil : []
    }

    // Valid data is (n * 4 + [0,2,3]) characters long.
    if sextets.count % 4 == 1 {
        return nil
    }

    // 4-byte to 3-byte conversion. Cannot overflow: a Span's count is far below Int.max, and (n + 3) / 4 is at most n.
    let length = sextets.count &- (sextets.count &+ 3) / 4
    if length == 0 {
        return nil
    }

    var bytes = [UInt8](repeating: 0, count: length)
    var sourceIndex = 0
    var destinationIndex = 0
    if length > 1 {
        while destinationIndex < length - 2 {
            bytes[destinationIndex] = (sextets[sourceIndex] &<< 2) | ((sextets[sourceIndex + 1] &>> 4) & 0x03)
            bytes[destinationIndex + 1] = (sextets[sourceIndex + 1] &<< 4) | ((sextets[sourceIndex + 2] &>> 2) & 0x0F)
            bytes[destinationIndex + 2] = (sextets[sourceIndex + 2] &<< 6) | (sextets[sourceIndex + 3] & 0x3F)
            sourceIndex += 4
            destinationIndex += 3
        }
    }

    if destinationIndex < length {
        bytes[destinationIndex] = (sextets[sourceIndex] &<< 2) | ((sextets[sourceIndex + 1] &>> 4) & 0x03)
    }

    destinationIndex += 1
    if destinationIndex < length {
        bytes[destinationIndex] = (sextets[sourceIndex + 1] &<< 4) | ((sextets[sourceIndex + 2] &>> 2) & 0x0F)
    }

    return bytes
}

/// Whether integrityBase64DecodedBytes() gives a value for `characters`, found without decoding them.
func structuredFieldBase64Decodes<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ characters: Span<CodeUnit>, url: Bool) -> Bool {
    var index = 0
    while index < characters.count && characters[index] != 0x3D {
        if base64Sextet(characters[index], url: url) == nil {
            return false
        }
        index += 1
    }
    let sextetCount = index
    while index < characters.count {
        if characters[index] != 0x3D {
            return false
        }
        index += 1
    }
    // Empty characters decode to no bytes. Valid data is (n * 4 + [0,2,3]) characters long.
    return characters.isEmpty || (sextetCount != 0 && sextetCount % 4 != 1)
}

// skipExactlyIgnoringASCIICase() of "sha256", "sha384" and "sha512", in that order: each character, with its 0x20 bit
// set, equals the spelling's. So the control characters 0x10 to 0x19 of an 8-bit string compare equal to the digits.
// The six characters, each with that bit set, are compared as one word of their low bytes; a code unit above 0xFF
// matches no spelling.
@inline(always)
private func resourceCryptographicDigestAlgorithm<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ name: Span<CodeUnit>) -> UInt8? {
    var word: UInt64 = 0
    var allBits: CodeUnit = 0
    for index in 0..<6 {
        let character = name[index] | 0x20
        allBits |= character
        word |= UInt64(truncatingIfNeeded: character & 0xFF) &<< UInt64(8 * index)
    }
    if allBits > 0xFF {
        return nil
    }
    // The spellings' characters, the first in the lowest byte.
    switch word {
    case 0x36_35_32_61_68_73:
        return contentSecurityPolicyHashAlgorithmSHA256
    case 0x34_38_33_61_68_73:
        return contentSecurityPolicyHashAlgorithmSHA384
    case 0x32_31_35_61_68_73:
        return contentSecurityPolicyHashAlgorithmSHA512
    default:
        return nil
    }
}

// isBase64OrBase64URLCharacter(): an ASCII letter or digit, "+", "/", "-" or "_". The characters are the bits of two
// words, those below 0x40 in the first and the others in the second.
@inline(always)
private func isBase64OrBase64URLCharacter<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ character: CodeUnit) -> Bool {
    let bit = UInt64(truncatingIfNeeded: character)
    let characters: UInt64 = bit < 0x40 ? 0x03FF_A800_0000_0000 : 0x07FF_FFFE_87FF_FFFE
    return bit < 0x80 && (characters &>> bit) & 1 != 0
}

// base64DecMap and base64URLDecMap together: the value of each ASCII character either has, with 0x40 set for "+" and
// "/", which only base64DecMap has, and 0x80 for "-" and "_", which only base64URLDecMap has. 0xFF for any other
// character, "=" included.
private let base64DecodeEntries: [128 of UInt8] = [
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7E, 0xFF, 0xBE, 0xFF, 0x7F,
    0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E,
    0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0xFF, 0xFF, 0xFF, 0xFF, 0xBF,
    0xFF, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
]

@inline(always)
private func base64DecodeEntry<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ character: CodeUnit) -> UInt8 {
    character < 0x80 ? base64DecodeEntries[Int(truncatingIfNeeded: character)] : 0xFF
}

// The value of a character in base64DecMap, or in base64URLDecMap when `url` is true: the letters, the digits, then
// "+" and "/", or "-" and "_". Nil for any other character, "=" included.
@inline(always)
private func base64Sextet<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ character: CodeUnit, url: Bool) -> UInt8? {
    let entry = base64DecodeEntry(character)
    if entry & (url ? 0x40 : 0x80) != 0 {
        return nil
    }
    return entry & 0x3F
}
