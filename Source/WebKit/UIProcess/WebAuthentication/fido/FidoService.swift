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

// A transport service's getInfo step: makes a CTAP2 or a U2F authenticator from the device's answer.

extension WebKit.FidoService {
    @cxx @implementation
    func continueAfterGetInfo(_ inputDriver: WebKit.CtapDriver, _ response: cbor.CBORValue.BinaryValue) {
        guard let driver = takeDriver(inputDriver).get() else {
            return
        }
        if !hasObserver() {
            return
        }
        if response.isEmpty() {
            return
        }

        WebKit.LogChannel.WebAuthn().releaseLog.log(
            "FidoService::Got response from getInfo: \(fido.base64EncodeBytes(response).description)"
        )

        if let authenticator = WebKit.FidoService.ctapAuthenticatorForGetInfo(driver, response).get() {
            notifyAuthenticatorAdded(authenticator)
            return
        }
        driver.setProtocol(.u2f)
        let authenticator = WebKit.U2fAuthenticator.create(consuming: WebKit.CtapDriverRef(driver))
        notifyAuthenticatorAdded(authenticator.get())
    }
}

#endif // ENABLE_WEB_AUTHN
