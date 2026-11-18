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
internal import WebCore_Private.Core.ResourceCryptographicDigest
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.Vector
internal import wtf.Core.text.WTFString

// https://w3c.github.io/webappsec-subresource-integrity/

/// Parse metadata: the algorithm of the strongest metadata in `integrity`, `None` when the parsed metadata is empty.
@_expose(Cxx)
func subresourceIntegrityStrongestAlgorithm(_ integrity: consuming WTF.String) -> WebCore.SubresourceIntegrityStrongestAlgorithm {
    if integrity.is8Bit(), !integrity.isEmpty() {
        return strongestAlgorithmOfIntegrityMetadata(WTF.bytesOfLatin1Characters(integrity.span8()))
    }
    return strongestAlgorithmOfIntegrityMetadata(integrity.checkedSpan16())
}

/// Whether an item of the strongest metadata in `integrity` decodes to the bytes of `digest`, the response's digest
/// with that metadata's algorithm, so the items with the digest's algorithm are compared with it.
///
/// An item whose value does not decode matches no digest.
@_expose(Cxx)
func subresourceIntegrityMatches(_ integrity: consuming WTF.String, _ digest: consuming WebCore.ResourceCryptographicDigest) -> Bool {
    let actualValue = digest.value
    let algorithm = digest.algorithm.rawValue
    if integrity.is8Bit(), !integrity.isEmpty() {
        return integrityMetadataMatches(WTF.bytesOfLatin1Characters(integrity.span8()), algorithm, actualValue.span())
    }
    return integrityMetadataMatches(integrity.checkedSpan16(), algorithm, actualValue.span())
}

/// Whether `integrity` holds at least one digest: its parsed metadata is not empty.
@_expose(Cxx)
func subresourceIntegrityHasItems(_ integrity: consuming WTF.String) -> Bool {
    if integrity.is8Bit(), !integrity.isEmpty() {
        return integrityMetadataHasItems(WTF.bytesOfLatin1Characters(integrity.span8()))
    }
    return integrityMetadataHasItems(integrity.checkedSpan16())
}

/// The digests of the metadata in `integrity` that decode, in order, the items of every algorithm.
func subresourceIntegrityDecodedDigests(_ integrity: borrowing WTF.String) -> [ResourceCryptographicDigestBytes] {
    if integrity.is8Bit(), !integrity.isEmpty() {
        return decodedDigestsOfIntegrityMetadata(WTF.bytesOfLatin1Characters(integrity.span8()))
    }
    return decodedDigestsOfIntegrityMetadata(integrity.checkedSpan16())
}

/// Parse metadata: the digest of each token of the characters, in order, read one at a time.
///
/// Tokens are separated by ASCII whitespace. A token is a digest optionally followed by "?" and its options, which are
/// ignored; any other token gives no item.
struct SubresourceIntegrityMetadataItems<CodeUnit: FixedWidthInteger & UnsignedInteger>: ~Escapable {
    private let characters: Span<CodeUnit>
    private var position: Int

    @_lifetime(copy characters)
    init(_ characters: Span<CodeUnit>) {
        self.characters = characters
        position = integrityMetadataEndOfWhitespace(characters, 0)
    }

    /// The digest of the next token that has one, or nil when no token is left.
    mutating func next() -> ResourceCryptographicDigestExtent? {
        while position < characters.count {
            var item = resourceCryptographicDigestExtent(characters, from: position)
            if let digest = item {
                position = digest.value.upperBound
                // After the value, the token ends or its options begin.
                if position < characters.count && characters[position] != 0x3F
                    && !isIntegrityMetadataWhitespace(characters[position]) {
                    item = nil
                }
            }
            while position < characters.count && !isIntegrityMetadataWhitespace(characters[position]) {
                position += 1
            }
            position = integrityMetadataEndOfWhitespace(characters, position)
            if item != nil {
                return item
            }
        }
        return nil
    }
}

// Get the strongest metadata from a set: its items all have the algorithm that is the largest
// ResourceCryptographicDigest::Algorithm value of the set's items.
private func strongestAlgorithmOfIntegrityMetadata<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>
) -> WebCore.SubresourceIntegrityStrongestAlgorithm {
    var items = SubresourceIntegrityMetadataItems(characters)
    var strongest: UInt8? = nil
    while let item = items.next() {
        if let current = strongest, item.algorithm <= current {
            continue
        }
        strongest = item.algorithm
    }
    switch strongest {
    case nil:
        return .None
    case contentSecurityPolicyHashAlgorithmSHA256:
        return .SHA256
    case contentSecurityPolicyHashAlgorithmSHA384:
        return .SHA384
    default:
        return .SHA512
    }
}

// The items with `algorithm`, the strongest metadata's, are compared with the digest's bytes.
private func integrityMetadataMatches<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ algorithm: UInt8,
    _ actualValue: Span<UInt8>
) -> Bool {
    var items = SubresourceIntegrityMetadataItems(characters)
    while let item = items.next() {
        if item.algorithm == algorithm && resourceCryptographicDigestValueEquals(characters.extracting(item.value), actualValue) {
            return true
        }
    }
    return false
}

private func integrityMetadataHasItems<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ characters: Span<CodeUnit>) -> Bool {
    var items = SubresourceIntegrityMetadataItems(characters)
    return items.next() != nil
}

private func decodedDigestsOfIntegrityMetadata<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>
) -> [ResourceCryptographicDigestBytes] {
    var digests: [ResourceCryptographicDigestBytes] = []
    var items = SubresourceIntegrityMetadataItems(characters)
    while let item = items.next() {
        if let value = resourceCryptographicDigestValue(characters.extracting(item.value)) {
            digests.append(ResourceCryptographicDigestBytes(algorithm: item.algorithm, value: value))
        }
    }
    return digests
}

// isASCIIWhitespace(): space, tab, line feed, form feed or carriage return; not vertical tab.
@inline(always)
private func isIntegrityMetadataWhitespace<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ character: CodeUnit) -> Bool {
    character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0C || character == 0x0D
}

private func integrityMetadataEndOfWhitespace<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ start: Int
) -> Int {
    var position = start
    while position < characters.count && isIntegrityMetadataWhitespace(characters[position]) {
        position += 1
    }
    return position
}
