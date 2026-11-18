// Copyright (C) 2011 Google Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY GOOGLE, INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

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
internal import WebCore_Private.Core.SandboxFlags
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

/// SecurityContext::isSupportedSandboxPolicy() for 8-bit characters: whether `policy` is one of the sandbox
/// attribute's keywords, ignoring ASCII case.
///
/// `policy` is the characters of the caller's `StringView`, whose `String` the caller keeps allocated and unchanged,
/// at their length, for the call. Nothing this function calls writes them, and every Latin-1 code unit is a valid
/// value.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isSupportedSandboxPolicy8(_ policy: WebCore.HTTPHeaderLatin1Span) -> Bool {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(policy))
    return isSupportedSandboxPolicy(characters)
}

/// isSupportedSandboxPolicy8() for 16-bit characters, which hold for the call in the same way, and every UTF-16 code
/// unit is a valid value.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func isSupportedSandboxPolicy16(_ policy: WebCore.HTTPHeaderUTF16Span) -> Bool {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: policy)
    return isSupportedSandboxPolicy(characters)
}

/// SecurityContext::parseSandboxPolicy() for 8-bit characters: parseSandboxPolicy() of `policy`.
///
/// `policy` is the characters of the caller's `StringView`, whose `String` the caller keeps allocated and unchanged,
/// at their length, for the call. Nothing this function calls writes them, and every Latin-1 code unit is a valid
/// value.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseSandboxPolicy8(_ policy: WebCore.HTTPHeaderLatin1Span) -> WebCore.SandboxPolicyParseResult {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(policy))
    return parseSandboxPolicy(characters)
}

/// parseSandboxPolicy8() for 16-bit characters, which hold for the call in the same way, and every UTF-16 code unit is
/// a valid value.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func parseSandboxPolicy16(_ policy: WebCore.HTTPHeaderUTF16Span) -> WebCore.SandboxPolicyParseResult {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: policy)
    return parseSandboxPolicy(characters)
}

/// The sandbox flags `policy` leaves set, and the message naming its invalid tokens, which is the null string when it
/// has none. Every flag starts set, and each token that allows something clears its flags.
/// http://www.w3.org/TR/html5/the-iframe-element.html#attr-iframe-sandbox
func parseSandboxPolicy<CodeUnit: HTTPHeaderStringCodeUnit>(_ policy: Span<CodeUnit>) -> WebCore.SandboxPolicyParseResult {
    // Parse the unordered set of unique space-separated tokens.
    var flags = sandboxPolicyAllFlags
    var start = 0
    while let token = nextSandboxPolicyToken(policy, &start) {
        let allowedFlags = sandboxPolicyAllowedFlags(policy.extracting(token))
        if allowedFlags == 0 {
            return parseSandboxPolicyFromInvalidToken(policy, token, start, flags)
        }
        // Turn off the corresponding sandbox flags.
        flags &= ~allowedFlags
    }
    var result = WebCore.SandboxPolicyParseResult()
    result.flags = flags
    return result
}

// parseSandboxPolicy() from its first invalid token, `firstInvalidToken`, given the flags the tokens before it leave
// and the position after it. The message is written to a buffer on the stack when it fits, and otherwise to one
// allocated at its length, which the first pass counts.
@inline(never)
private func parseSandboxPolicyFromInvalidToken<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ policy: Span<CodeUnit>,
    _ firstInvalidToken: Range<Int>,
    _ startAfterFirstInvalidToken: Int,
    _ flagsBeforeFirstInvalidToken: UInt16
) -> WebCore.SandboxPolicyParseResult {
    var flags = flagsBeforeFirstInvalidToken
    var numberOfTokenErrors = 1
    var buffer = SandboxPolicyMessageBuffer<CodeUnit>(repeating: 0)
    var output = buffer.mutableSpan
    // The message's length so far, without its ending, which needs at most 28 more code units. A token is shorter than
    // the policy, a StringView, whose length is below 2^32, so this cannot overflow.
    var length = firstInvalidToken.count &+ 2
    let lengthWithoutEndingThatFits = SandboxPolicyMessageBuffer<CodeUnit>.count - 28
    var fitsInBuffer = length <= lengthWithoutEndingThatFits
    if fitsInBuffer {
        length = 0
        writeSandboxPolicyInvalidToken(policy.extracting(firstInvalidToken), isFirst: true, to: &output, at: &length)
    }
    var start = startAfterFirstInvalidToken
    while let token = nextSandboxPolicyToken(policy, &start) {
        let allowedFlags = sandboxPolicyAllowedFlagsCall(policy.extracting(token))
        if allowedFlags != 0 {
            flags &= ~allowedFlags
            continue
        }
        numberOfTokenErrors += 1
        // The message has at most three code units per code unit of the policy, a StringView, whose length is below
        // 2^32, and 28 more, so this cannot overflow.
        if fitsInBuffer && length &+ token.count &+ 4 <= lengthWithoutEndingThatFits {
            writeSandboxPolicyInvalidToken(policy.extracting(token), isFirst: false, to: &output, at: &length)
        } else {
            fitsInBuffer = false
            length &+= token.count &+ 4 // As above, this cannot overflow.
        }
    }

    var result = WebCore.SandboxPolicyParseResult()
    result.flags = flags
    let ending = numberOfTokenErrors > 1 ? " are invalid sandbox flags." : " is an invalid sandbox flag."
    // StringBuilder keeps an 8-bit policy's message 8-bit, and makes it 16-bit once it appends a 16-bit token.
    if fitsInBuffer {
        writeSandboxPolicyASCII(ending, to: &output, at: &length)
        result.invalidTokensErrorMessage = CodeUnit.httpHeaderString(buffer.span.extracting(0..<length))
        return result
    }

    // The message is too long for the buffer: write it again from the first invalid token, at its length.
    let utf8 = ending.utf8
    var message = [CodeUnit](repeating: 0, count: length &+ utf8.count) // As above, this cannot overflow.
    var messageOutput = message.mutableSpan
    var messageLength = 0
    writeSandboxPolicyInvalidToken(policy.extracting(firstInvalidToken), isFirst: true, to: &messageOutput, at: &messageLength)
    start = startAfterFirstInvalidToken
    while let token = nextSandboxPolicyToken(policy, &start) {
        if sandboxPolicyAllowedFlagsCall(policy.extracting(token)) == 0 {
            writeSandboxPolicyInvalidToken(policy.extracting(token), isFirst: false, to: &messageOutput, at: &messageLength)
        }
    }
    writeSandboxPolicyASCII(ending, to: &messageOutput, at: &messageLength)
    result.invalidTokensErrorMessage = CodeUnit.httpHeaderString(message.span)
    return result
}

// A message of at most this many code units, with its ending, is written on the stack.
private typealias SandboxPolicyMessageBuffer<CodeUnit> = InlineArray<256, CodeUnit>

// SandboxFlags::all(): every bit of SandboxFlags' storage.
private var sandboxPolicyAllFlags: UInt16 { UInt16.max }

// The next token at or after `start`, a run of code units other than ASCII whitespace, with `start` moved past the code
// unit that ends it. Nil when only whitespace remains.
@inline(always)
private func nextSandboxPolicyToken<CodeUnit: HTTPHeaderStringCodeUnit>(_ policy: Span<CodeUnit>, _ start: inout Int) -> Range<Int>? {
    while start < policy.count && isSandboxPolicyWhitespace(policy[start]) {
        start += 1
    }
    if start >= policy.count {
        return nil
    }
    let end = sandboxPolicyTokenEnd(policy, start + 1)
    let token = start..<end
    start = end + 1
    return token
}

// The position of the first ASCII whitespace at or after `position`, or the policy's length: a word at a time while a
// whole word remains, then one code unit at a time.
@inline(always)
private func sandboxPolicyTokenEnd<CodeUnit: HTTPHeaderStringCodeUnit>(_ policy: Span<CodeUnit>, _ position: Int) -> Int {
    let bytes = policy.bytes
    let codeUnitsPerWord = 8 / MemoryLayout<CodeUnit>.size
    let lowBitOfEachCodeUnit: UInt64 = MemoryLayout<CodeUnit>.size == 1 ? 0x0101_0101_0101_0101 : 0x0001_0001_0001_0001
    let highBitOfEachCodeUnit = lowBitOfEachCodeUnit << (CodeUnit.bitWidth - 1)
    var end = position
    // Positions are at most the policy's length, a StringView's, below 2^32, so these cannot overflow.
    while end &+ codeUnitsPerWord <= policy.count {
        let word = UInt64(littleEndian: bytes.load(fromByteOffset: end &* MemoryLayout<CodeUnit>.size, as: UInt64.self))
        // The high bit of each code unit below 0x21, every whitespace among them. The subtraction wraps on purpose: a
        // borrow out of a code unit below 0x21 can mark code units after it, but never one before it.
        let below0x21 = (word &- lowBitOfEachCodeUnit * 0x21) & ~word & highBitOfEachCodeUnit
        if below0x21 == 0 {
            end &+= codeUnitsPerWord
            continue
        }
        let index = end &+ below0x21.trailingZeroBitCount / CodeUnit.bitWidth
        if isSandboxPolicyWhitespace(policy[index]) {
            return index
        }
        end = index &+ 1
    }
    while end < policy.count && !isSandboxPolicyWhitespace(policy[end]) {
        end += 1
    }
    return end
}

// isASCIIWhitespace(): space, tab, line feed, carriage return and form feed.
private func isSandboxPolicyWhitespace<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ character: CodeUnit) -> Bool {
    switch UInt16(truncatingIfNeeded: character) {
    case 0x20, 0x09, 0x0A, 0x0D, 0x0C:
        true
    default:
        false
    }
}

// isSupportedSandboxPolicy(): whether `policy` is one of the sandbox attribute's keywords, ignoring ASCII case.
private func isSupportedSandboxPolicy<CodeUnit: HTTPHeaderStringCodeUnit>(_ policy: Span<CodeUnit>) -> Bool {
    sandboxPolicyAllowedFlagsCall(policy) != 0
}

// sandboxPolicyAllowedFlags() as a call, for the paths other than parseSandboxPolicy()'s valid tokens.
@inline(never)
private func sandboxPolicyAllowedFlagsCall<CodeUnit: HTTPHeaderStringCodeUnit>(_ characters: Span<CodeUnit>) -> UInt16 {
    sandboxPolicyAllowedFlags(characters)
}

// The flags a keyword allows, which parseSandboxPolicy() clears, or 0 when `characters` are no keyword: each keyword
// allows at least one. Only a keyword of their length can match them, and a keyword's letters match in either case and
// its '-' only itself. That is isSupportedSandboxPolicy()'s equalIgnoringASCIICase(), and parseSandboxPolicy()'s
// equalLettersIgnoringASCIICase() on a token, which also matches a carriage return to a '-' but never holds one.
//
// Each keyword is compared a word of eight characters at a time, the last word holding its last eight characters.
@inline(always)
private func sandboxPolicyAllowedFlags<CodeUnit: HTTPHeaderStringCodeUnit>(_ characters: Span<CodeUnit>) -> UInt16 {
    let c = characters
    switch characters.count {
    case 17
    where sandboxPolicyWordDifference(c, 0, 0x6173_2d77_6f6c_6c61) | sandboxPolicyWordDifference(c, 8, 0x6967_6972_6f2d_656d)
        | sandboxPolicyWordDifference(c, 9, 0x6e69_6769_726f_2d65) == 0: // "allow-sa", "me-origi", "e-origin"
        return WebCore.SandboxFlag.Origin.rawValue
    case 15 where sandboxPolicyWordDifference(c, 0, 0x6f64_2d77_6f6c_6c61) | sandboxPolicyWordDifference(c, 7, 0x7364_616f_6c6e_776f) == 0:
        // "allow-do", "ownloads"
        return WebCore.SandboxFlag.Downloads.rawValue
    case 11 where sandboxPolicyWordDifference(c, 0, 0x6f66_2d77_6f6c_6c61) | sandboxPolicyWordDifference(c, 3, 0x736d_726f_662d_776f) == 0:
        // "allow-fo", "ow-forms"
        return WebCore.SandboxFlag.Forms.rawValue
    case 13 where sandboxPolicyWordDifference(c, 0, 0x6373_2d77_6f6c_6c61) | sandboxPolicyWordDifference(c, 5, 0x7374_7069_7263_732d) == 0:
        // "allow-sc", "-scripts"
        return WebCore.SandboxFlag.Scripts.rawValue | WebCore.SandboxFlag.AutomaticFeatures.rawValue
    case 20
    where sandboxPolicyWordDifference(c, 0, 0x6f74_2d77_6f6c_6c61) | sandboxPolicyWordDifference(c, 8, 0x6167_6976_616e_2d70)
        | sandboxPolicyWordDifference(c, 12, 0x6e6f_6974_6167_6976) == 0: // "allow-to", "p-naviga", "vigation"
        return WebCore.SandboxFlag.TopNavigation.rawValue | WebCore.SandboxFlag.TopNavigationByUserActivation.rawValue
    case 12 where sandboxPolicyWordDifference(c, 0, 0x6f70_2d77_6f6c_6c61) | sandboxPolicyWordDifference(c, 4, 0x7370_7570_6f70_2d77) == 0:
        // "allow-po", "w-popups"
        return WebCore.SandboxFlag.Popups.rawValue
    case 18
    where sandboxPolicyWordDifference(c, 0, 0x6f70_2d77_6f6c_6c61) | sandboxPolicyWordDifference(c, 8, 0x6f6c_2d72_6574_6e69)
        | sandboxPolicyWordDifference(c, 10, 0x6b63_6f6c_2d72_6574) == 0: // "allow-po", "inter-lo", "ter-lock"
        return WebCore.SandboxFlag.PointerLock.rawValue
    case 30
    where sandboxPolicyWordDifference(c, 0, 0x6f70_2d77_6f6c_6c61) | sandboxPolicyWordDifference(c, 8, 0x2d6f_742d_7370_7570)
        | sandboxPolicyWordDifference(c, 16, 0x732d_6570_6163_7365) | sandboxPolicyWordDifference(c, 22, 0x786f_6264_6e61_732d) == 0:
        // "allow-po", "pups-to-", "escape-s", "-sandbox"
        return WebCore.SandboxFlag.PropagatesToAuxiliaryBrowsingContexts.rawValue
    case 39
    where sandboxPolicyWordDifference(c, 0, 0x6f74_2d77_6f6c_6c61) | sandboxPolicyWordDifference(c, 8, 0x6167_6976_616e_2d70)
        | sandboxPolicyWordDifference(c, 16, 0x2d79_622d_6e6f_6974) | sandboxPolicyWordDifference(c, 24, 0x7463_612d_7265_7375)
        | sandboxPolicyWordDifference(c, 31, 0x6e6f_6974_6176_6974) == 0:
        // "allow-to", "p-naviga", "tion-by-", "user-act", "tivation"
        return WebCore.SandboxFlag.TopNavigationByUserActivation.rawValue
    case 40
    where sandboxPolicyWordDifference(c, 0, 0x6f74_2d77_6f6c_6c61) | sandboxPolicyWordDifference(c, 8, 0x6167_6976_616e_2d70)
        | sandboxPolicyWordDifference(c, 16, 0x2d6f_742d_6e6f_6974) | sandboxPolicyWordDifference(c, 24, 0x702d_6d6f_7473_7563)
        | sandboxPolicyWordDifference(c, 32, 0x736c_6f63_6f74_6f72) == 0:
        // "allow-to", "p-naviga", "tion-to-", "custom-p", "rotocols"
        return WebCore.SandboxFlag.TopNavigationToCustomProtocols.rawValue
    case 12 where sandboxPolicyWordDifference(c, 0, 0x6f6d_2d77_6f6c_6c61) | sandboxPolicyWordDifference(c, 4, 0x736c_6164_6f6d_2d77) == 0:
        // "allow-mo", "w-modals"
        return WebCore.SandboxFlag.Modals.rawValue
    case 39
    where sandboxPolicyWordDifference(c, 0, 0x7473_2d77_6f6c_6c61) | sandboxPolicyWordDifference(c, 8, 0x6361_2d65_6761_726f)
        | sandboxPolicyWordDifference(c, 16, 0x2d79_622d_7373_6563) | sandboxPolicyWordDifference(c, 24, 0x7463_612d_7265_7375)
        | sandboxPolicyWordDifference(c, 31, 0x6e6f_6974_6176_6974) == 0:
        // "allow-st", "orage-ac", "cess-by-", "user-act", "tivation"
        return WebCore.SandboxFlag.StorageAccessByUserActivation.rawValue
    default:
        return 0
    }
}

// Zero when the eight code units of `characters` at `offset` are the ASCII characters of `keyword`, the first in its
// lowest byte, each letter in either case and anything else exactly. A letter's 0x40 bit is set and '-''s is not, so
// `caseBits` is 0x20 at each letter.
@inline(always)
private func sandboxPolicyWordDifference<CodeUnit: HTTPHeaderStringCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ offset: Int,
    _ keyword: UInt64
) -> UInt64 {
    let caseBits = (keyword >> 1) & 0x2020_2020_2020_2020
    let bytes = characters.bytes
    if MemoryLayout<CodeUnit>.size == 1 {
        return (UInt64(littleEndian: bytes.load(fromByteOffset: offset, as: UInt64.self)) | caseBits) ^ keyword
    }
    // Four code units to a word, each matched with a character widened to 16 bits.
    let low = UInt64(littleEndian: bytes.load(fromByteOffset: offset * 2, as: UInt64.self))
    let high = UInt64(littleEndian: bytes.load(fromByteOffset: offset * 2 + 8, as: UInt64.self))
    return ((low | sandboxPolicyWidened(caseBits)) ^ sandboxPolicyWidened(keyword))
        | ((high | sandboxPolicyWidened(caseBits >> 32)) ^ sandboxPolicyWidened(keyword >> 32))
}

// The four low bytes of `word` as four 16-bit code units, the first in the lowest.
@inline(always)
private func sandboxPolicyWidened(_ word: UInt64) -> UInt64 {
    (word & 0xFF) | (word & 0xFF00) << 8 | (word & 0xFF_0000) << 16 | (word & 0xFF00_0000) << 24
}

// Writes an invalid token's part of the message to `output` at `length`, and moves `length` past it: the token in single
// quotes, after ", " unless it is the first.
@inline(always)
private func writeSandboxPolicyInvalidToken<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ token: Span<CodeUnit>,
    isFirst: Bool,
    to output: inout MutableSpan<CodeUnit>,
    at length: inout Int
) {
    if !isFirst {
        output[length] = 0x2C // ','
        output[length + 1] = 0x20 // ' '
        length += 2
    }
    output[length] = 0x27 // '\''
    length += 1
    for index in token.indices {
        output[length] = token[index]
        length += 1
    }
    output[length] = 0x27 // '\''
    length += 1
}

// Writes the ASCII `literal` to `output` at `length`, and moves `length` past it.
private func writeSandboxPolicyASCII<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ literal: Swift.String,
    to output: inout MutableSpan<CodeUnit>,
    at length: inout Int
) {
    let utf8 = literal.utf8
    let bytes = utf8.span
    for index in bytes.indices {
        output[length] = CodeUnit(bytes[index])
        length += 1
    }
}
