// Copyright 2019 The Chromium Authors. All rights reserved.
// Copyright (C) 2019 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#include "config.h"
#include "Pin.h"

#if ENABLE(WEB_AUTHN)

#include "CBORWriter.h"
#include "CryptoAlgorithmAESCBC.h"
#include "CryptoAlgorithmAesCbcCfbParams.h"
#include "CryptoAlgorithmECDH.h"
#include "CryptoAlgorithmHKDF.h"
#include "CryptoAlgorithmHMAC.h"
#include "CryptoAlgorithmHkdfParams.h"
#include "CryptoKeyAES.h"
#include "CryptoKeyEC.h"
#include "CryptoKeyHMAC.h"
#include "CryptoKeyRaw.h"
#include "WebAuthenticationUtils.h"
#include "WebCore-Swift.h"
#include <pal/crypto/CryptoDigest.h>
#include <wtf/CryptographicallyRandomNumber.h>

namespace fido {
namespace pin {

std::optional<UTF8CString> validateAndConvertToUTF8(String pin)
{
    auto result = validatePinAsUTF8(WTF::move(pin));
    if (result.isNull())
        return std::nullopt;
    return result;
}

PinKeyAgreement pinKeyAgreement(const WebCore::CryptoKeyEC& peerKey)
{
    using namespace WebCore;
    PinKeyAgreement result;
    auto keyPair = CryptoKeyEC::generatePair(CryptoAlgorithmIdentifier::ECDH, "P-256"_s, true, CryptoKeyUsageDeriveBits);
    if (keyPair.hasException())
        return result;
    result.generated = true;
    auto pair = keyPair.releaseReturnValue();
    auto sharedSecret = CryptoAlgorithmECDH::platformDeriveBits(downcast<CryptoKeyEC>(*pair.privateKey), peerKey);
    if (!sharedSecret)
        return result;
    result.derived = true;
    result.sharedSecret = WTF::move(*sharedSecret);
    auto rawPublicKey = downcast<CryptoKeyEC>(*pair.publicKey).exportRaw();
    if (rawPublicKey.hasException())
        return result;
    result.exported = true;
    result.rawPublicKey = rawPublicKey.releaseReturnValue();
    return result;
}

Vector<uint8_t> pinSHA256(const Vector<uint8_t>& data)
{
    auto crypto = PAL::Crypto::CryptoDigest::create(PAL::Crypto::CryptoDigest::Algorithm::SHA_256);
    crypto->addBytes(data.span());
    return crypto->computeHash();
}

Vector<uint8_t> pinHKDF(const Vector<uint8_t>& secret, PinHKDFKey key)
{
    using namespace WebCore;
    auto hkdfKey = CryptoKeyRaw::create(CryptoAlgorithmIdentifier::HKDF, Vector<uint8_t> { secret }, CryptoKeyUsageDeriveBits);
    std::array<uint8_t, 32> salt { };
    auto info = key == PinHKDFKey::HMACKey ? std::span<const uint8_t> { kHKDFInfoHMACKey } : std::span<const uint8_t> { kHKDFInfoAESKey };
    auto init = CryptoAlgorithmHkdfParamsInit { CryptoAlgorithmParametersInit { "HKDF"_s }, String(), toBufferSource(std::span { salt }), toBufferSource(info) };
    auto params = CryptoAlgorithmHkdfParams(CryptoAlgorithmIdentifier::HKDF, WTF::move(init), CryptoAlgorithmIdentifier::SHA_256);
    auto material = CryptoAlgorithmHKDF::deriveBits(params, hkdfKey.get(), 32 * 8);
    if (material.hasException())
        return { };
    return material.releaseReturnValue();
}

static WebCore::CryptoAlgorithmAesCbcCfbParams aesCBCParams(const Vector<uint8_t>& iv)
{
    WebCore::CryptoAlgorithmAesCbcCfbParams params;
    if (!iv.isEmpty())
        params.iv = WebCore::toBufferSource(iv.span());
    return params;
}

Vector<uint8_t> pinAESCBCEncrypt(const WebCore::CryptoKeyAES& key, const Vector<uint8_t>& iv, const Vector<uint8_t>& plaintext)
{
    auto result = WebCore::CryptoAlgorithmAESCBC::platformEncrypt(aesCBCParams(iv), key, plaintext, WebCore::CryptoAlgorithmAESCBC::Padding::No);
    ASSERT(!result.hasException());
    return result.releaseReturnValue();
}

Vector<uint8_t> pinAESCBCDecrypt(const WebCore::CryptoKeyAES& key, const Vector<uint8_t>& iv, const Vector<uint8_t>& ciphertext)
{
    auto result = WebCore::CryptoAlgorithmAESCBC::platformDecrypt(aesCBCParams(iv), key, ciphertext, WebCore::CryptoAlgorithmAESCBC::Padding::No);
    if (result.hasException())
        return { };
    return result.releaseReturnValue();
}

Vector<uint8_t> pinHMACSign(const WebCore::CryptoKeyHMAC& key, const Vector<uint8_t>& message)
{
    auto result = WebCore::CryptoAlgorithmHMAC::platformSign(key, message);
    ASSERT(!result.hasException());
    return result.releaseReturnValue();
}

Vector<uint8_t> pinRandomIV()
{
    std::array<uint8_t, 16> iv { };
    cryptographicallyRandomValues(iv);
    return Vector<uint8_t>(std::span { iv });
}

RetriesResponse::RetriesResponse() = default;

std::optional<RetriesResponse> RetriesResponse::parse(Vector<uint8_t> inBuffer)
{
    auto result = parseRetriesResponse(WTF::move(inBuffer));
    if (!result.valid)
        return std::nullopt;
    RetriesResponse ret;
    ret.retries = result.retries;
    return ret;
}

KeyAgreementResponse::KeyAgreementResponse(Ref<WebCore::CryptoKeyEC>&& peerKey)
    : peerKey(WTF::move(peerKey))
{
}

KeyAgreementResponse::~KeyAgreementResponse() = default;
KeyAgreementResponse::KeyAgreementResponse(KeyAgreementResponse&&) = default;
KeyAgreementResponse& KeyAgreementResponse::operator=(KeyAgreementResponse&&) = default;

std::optional<KeyAgreementResponse> KeyAgreementResponse::parse(Vector<uint8_t> inBuffer)
{
    auto result = parseKeyAgreementResponse(WTF::move(inBuffer));
    if (!result)
        return std::nullopt;
    return KeyAgreementResponse(result.releaseNonNull());
}

std::optional<KeyAgreementResponse> KeyAgreementResponse::parseFromCOSE(const cbor::CBORValue::MapValue& coseKey)
{
    auto result = WebCore::parseKeyAgreementFromCOSE(coseKey);
    if (!result)
        return std::nullopt;
    return KeyAgreementResponse(result.releaseNonNull());
}

TokenResponse::TokenResponse(Ref<WebCore::CryptoKeyHMAC>&& token)
    : m_token(WTF::move(token))
{
}

std::optional<TokenResponse> TokenResponse::parse(PINUVAuthProtocol protocol, const WebCore::CryptoKeyAES& sharedKey, Vector<uint8_t> inBuffer)
{
    auto result = parseTokenResponse(protocol, sharedKey, WTF::move(inBuffer));
    if (!result)
        return std::nullopt;
    return TokenResponse(result.releaseNonNull());
}

Vector<uint8_t> TokenResponse::pinAuth(PINUVAuthProtocol protocol, Vector<uint8_t> clientDataHash) const
{
    return tokenPinAuth(protocol, m_token, WTF::move(clientDataHash));
}

const Vector<uint8_t>& TokenResponse::token() const
{
    return m_token->key();
}

TokenRequest::TokenRequest(WebCore::CryptoKeyAES& sharedKey, cbor::CBORValue::MapValue&& coseKey, Vector<uint8_t>&& pinHash, PINUVAuthProtocol protocol)
    : m_sharedKey(sharedKey)
    , m_coseKey(WTF::move(coseKey))
    , m_pinHash(WTF::move(pinHash))
    , m_protocol(protocol)
{
}

SetPinRequest::SetPinRequest(WebCore::CryptoKeyAES& sharedKey, cbor::CBORValue::MapValue&& coseKey, Vector<uint8_t>&& newPinEnc, Vector<uint8_t>&& pinUvAuthParam, PINUVAuthProtocol protocol)
    : m_sharedKey(sharedKey)
    , m_coseKey(WTF::move(coseKey))
    , m_newPinEnc(WTF::move(newPinEnc))
    , m_pinUvAuthParam(WTF::move(pinUvAuthParam))
    , m_protocol(protocol)
{
}

const Vector<uint8_t>& SetPinRequest::pinAuth() const
{
    return m_pinUvAuthParam;
}

Vector<uint8_t> encodeAsCBOR(const TokenRequest& request)
{
    auto result = WebCore::encodeTokenRequestAsCBOR(request);
    // The encoding moves the COSE key out of the request, so a second encoding sends an empty one.
    request.m_coseKey.clear();
    return result;
}

Vector<uint8_t> encodeAsCBOR(SetPinRequest request)
{
    return WebCore::encodeSetPinRequestAsCBOR(request);
}

HmacSecretRequest::HmacSecretRequest(WebCore::CryptoKeyAES& sharedKey, cbor::CBORValue::MapValue&& coseKey, Vector<uint8_t>&& saltEnc, Vector<uint8_t>&& saltAuth, PINUVAuthProtocol protocol)
    : m_sharedKey(sharedKey)
    , m_coseKey(WTF::move(coseKey))
    , m_saltEnc(WTF::move(saltEnc))
    , m_saltAuth(WTF::move(saltAuth))
    , m_protocol(protocol)
{
}

HmacSecretResponse::HmacSecretResponse(Vector<uint8_t>&& decryptedOutput)
    : m_output(WTF::move(decryptedOutput))
{
}

const Vector<uint8_t>& HmacSecretResponse::output() const
{
    return m_output;
}

} // namespace pin
} // namespace fido

#endif // ENABLE(WEB_AUTHN)
