/*
 * Copyright (C) 2018 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(WEB_AUTHN)

#include "FidoAuthenticator.h"
#include <WebCore/AuthenticatorGetInfoResponse.h>
#include <WebCore/CryptoKeyEC.h>
#include <WebCore/DeviceRequestConverter.h>
#include <WebCore/Pin.h>
#include <WebCore/PublicKeyCredentialDescriptor.h>
#include <wtf/SwiftBridging.h>

namespace WebKit {

class CtapDriver;

class SWIFT_PRIVATE_FILEID("WebKit/CtapAuthenticator.swift") CtapAuthenticator final : public FidoAuthenticator {
public:
    static Ref<CtapAuthenticator> create(Ref<CtapDriver>&& driver, fido::AuthenticatorGetInfoResponse&& info)
    {
        return adoptRef(*new CtapAuthenticator(WTF::move(driver), WTF::move(info)));
    }
    ~CtapAuthenticator(); // The key function, kept in C++ so the vtable is emitted with the destructor.

private:
    explicit CtapAuthenticator(Ref<CtapDriver>&&, fido::AuthenticatorGetInfoResponse&&);

    void makeCredential() final;
    void getAssertion() final;

    // For CtapAuthenticator.swift: Vector<Ref<AuthenticatorAssertionResponse>>
    // imports as unsafe, and Swift cannot compare the identity of a foreign reference (=== takes only AnyObject).
    void restartMakeCredential() { makeCredential(); }
    void restartGetAssertion() { getAssertion(); }
    void reserveAssertionResponses(size_t capacity) { m_assertionResponses.reserveInitialCapacity(capacity); }
    void appendAssertionResponse(WebCore::AuthenticatorAssertionResponse&);
    void selectAssertionResponseFromObserver();
    void markClientPinSet() { m_info.mutableOptions().setClientPinAvailability(fido::AuthenticatorSupportedOptions::ClientPinAvailability::kSupportedAndPinSet); }

    fido::AuthenticatorGetInfoResponse m_info;
    bool m_isDowngraded { false };
    bool m_isKeyStoreFull { false };
    size_t m_remainingAssertionResponses { 0 };
    size_t m_currentBatch { 0 };
    Vector<Ref<WebCore::AuthenticatorAssertionResponse>> m_assertionResponses;
    Vector<Vector<WebCore::PublicKeyCredentialDescriptor>> m_batches;
    Vector<uint8_t> m_pinAuth;
    // What the pending hmac-secret request decrypts the output with; a null key when there is none.
    RefPtr<WebCore::CryptoKeyAES> m_hmacSecretSharedKey;
    fido::PINUVAuthProtocol m_hmacSecretProtocol { fido::PINUVAuthProtocol::kPinProtocol1 };
    RefPtr<WebCore::CryptoKeyEC> m_cachedPeerKey;
};

using WeakPtrCtapAuthenticator = WeakPtr<CtapAuthenticator>;

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
