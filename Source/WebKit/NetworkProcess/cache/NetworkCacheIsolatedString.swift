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

import WebKit_Internal.NetworkCacheCxx
import wtf

/// A string's code units, owned by Swift, so a path or a key can move to another thread. `string` makes a new
/// `WTF::String` each time, as `isolatedCopy()` does; the null string stays null.
struct NetworkCacheIsolatedString: Sendable, Hashable {
    private enum Storage: Sendable, Hashable {
        case null
        case latin1([UInt8])
        case utf16([UInt16])
    }

    private let storage: Storage

    init(_ string: borrowing WTF.String) {
        if string.isNull() {
            storage = .null
        } else if string.is8Bit() {
            let bytes: Span<UInt8> = WebKit.NetworkCache.latin1Bytes(string)
            storage = .latin1(Array(copying: bytes))
        } else {
            // WTF::String compares contents, not width, so a 16-bit string of Latin-1 characters is stored as one.
            let span16: Span<UInt16> = string.checkedSpan16()
            var isLatin1 = true
            for index in span16.indices where span16[index] > 0xFF {
                isLatin1 = false
                break
            }
            if isLatin1 {
                storage = .latin1(
                    Array(capacity: span16.count) { output in
                        for index in span16.indices {
                            output.append(UInt8(truncatingIfNeeded: span16[index]))
                        }
                    }
                )
            } else {
                storage = .utf16(Array(copying: span16))
            }
        }
    }

    var isEmpty: Bool {
        switch storage {
        case .null:
            true
        case .latin1(let characters):
            characters.isEmpty
        case .utf16(let characters):
            characters.isEmpty
        }
    }

    var string: WTF.String {
        switch storage {
        case .null:
            WTF.String()
        case .latin1(let characters):
            WebKit.NetworkCache.latin1String(characters.span)
        case .utf16(let characters):
            WTF.String(characters.span)
        }
    }
}
