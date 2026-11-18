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

#if ENABLE_WEB_AUTHN

import WebCore_Private
import WebKit_Internal
import wtf

// The driver an authenticator talks to.

extension WebKit.FidoAuthenticator {
    @cxx @implementation
    func releaseDriver() -> WebKit.CtapDriverRef {
        // A second release finds no driver.
        guard let driver = m_driver.get() else {
            fatalError("FidoAuthenticator: the driver was already released")
        }
        let released = WebKit.CtapDriverRef(driver)
        m_driver = .init()
        return released
    }

    @cxx @implementation
    func transportForDebugging() -> WTF.String {
        WebCore.toString(driver().transport())
    }
}

// Helpers the authenticators share.

// A WTF.String with the characters of `text` and no terminating NUL.
func webAuthnString(_ text: Swift.String) -> WTF.String {
    let units = Array(text.utf16)
    return WTF.String(units.span)
}

// base64EncodeToString, for logs.
func base64String(_ bytes: cbor.CBORValue.BinaryValue) -> Swift.String {
    fido.base64EncodeBytes(bytes).description
}

// base64URLEncodeToString.
func base64URLString(_ bytes: cbor.CBORValue.BinaryValue) -> Swift.String {
    fido.base64URLEncodeBytes(bytes).description
}

// The bytes a BufferSource holds.
func bufferSourceBytes(_ source: borrowing WebCore.BufferSource) -> [UInt8] {
    let span: Span<UInt8> = source.span()
    var bytes: [UInt8] = []
    bytes.reserveCapacity(span.count)
    for index in 0..<span.count {
        bytes.append(span[index])
    }
    return bytes
}

#endif // ENABLE_WEB_AUTHN
