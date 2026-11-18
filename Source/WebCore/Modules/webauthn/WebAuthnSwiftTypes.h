/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#include <WebCore/ApduCommand.h>
#include <WebCore/ApduResponse.h>
#include <WebCore/AuthenticatorGetInfoResponse.h>
#include <WebCore/BufferSource.h>
#include <WebCore/CBORReader.h>
#include <WebCore/CBORWriter.h>
#include <WebCore/CryptoKeyAES.h>
#include <WebCore/CryptoKeyEC.h>
#include <WebCore/CryptoKeyHMAC.h>
#include <WebCore/DeviceRequestConverter.h>
#include <WebCore/DeviceResponseConverter.h>
#include <WebCore/FidoHidMessage.h>
#include <WebCore/FidoHidPacket.h>
#include <WebCore/Pin.h>
#include <WebCore/PublicKeyCredentialCreationOptions.h>
#include <WebCore/PublicKeyCredentialRequestOptions.h>
#include <WebCore/U2fCommandConstructor.h>
#include <WebCore/U2fResponseConverter.h>
#include <wtf/text/Base64.h>

namespace fido {

// Names for the template instantiations in the WebAuthn entries' signatures, which Swift cannot spell.
using StringVector = Vector<String>;
using ByteVectorVector = Vector<Vector<uint8_t>>;
using OptionalByteVector = std::optional<Vector<uint8_t>>;
using OptionalUInt32 = std::optional<uint32_t>;
using PinProtocolVector = Vector<PINUVAuthProtocol>;
using OptionalPinProtocolVector = std::optional<PinProtocolVector>;
using OptionalStringVector = std::optional<Vector<String>>;
using OptionalPinParameters = std::optional<PinParameters>;
using OptionalHmacSecretParameters = std::optional<HmacSecretParameters>;
using CredentialParametersVector = Vector<WebCore::PublicKeyCredentialParameters>;
using OptionalCredentialParametersVector = std::optional<Vector<WebCore::PublicKeyCredentialParameters>>;
using CredentialDescriptorVector = Vector<WebCore::PublicKeyCredentialDescriptor>;
using OptionalCredentialDescriptorVector = std::optional<Vector<WebCore::PublicKeyCredentialDescriptor>>;
using TransportVector = Vector<WebCore::AuthenticatorTransport>;
using OptionalTransportVector = std::optional<TransportVector>;
using AttestationResponsePtr = RefPtr<WebCore::AuthenticatorAttestationResponse>;
using AssertionResponsePtr = RefPtr<WebCore::AuthenticatorAssertionResponse>;
using OptionalGetInfoResponse = std::optional<AuthenticatorGetInfoResponse>;
using CryptoKeyAESPtr = RefPtr<WebCore::CryptoKeyAES>;
using CryptoKeyECPtr = RefPtr<WebCore::CryptoKeyEC>;
using CryptoKeyHMACPtr = RefPtr<WebCore::CryptoKeyHMAC>;
using OptionalTokenRequest = std::optional<pin::TokenRequest>;
using OptionalSetPinRequest = std::optional<pin::SetPinRequest>;
using OptionalHmacSecretRequest = std::optional<pin::HmacSecretRequest>;
using OptionalHmacSecretResponse = std::optional<pin::HmacSecretResponse>;
using OptionalApduCommand = std::optional<apdu::ApduCommand>;
using OptionalApduResponse = std::optional<apdu::ApduResponse>;
using OptionalClientOutputs = std::optional<WebCore::AuthenticationExtensionsClientOutputs>;
// PublicKeyCredentialType has one enumerator, which Swift imports with no cases.
inline WebCore::PublicKeyCredentialType publicKeyCredentialTypePublicKey() { return WebCore::PublicKeyCredentialType::PublicKey; }
// WTF::emptyString() by value: Swift imports its const String& result as a pointer.
inline String emptyWTFString() { return emptyString(); }
// CStringBase::length(), which Swift does not import on the CString template.
inline size_t utf8CStringLength(const UTF8CString& string) { return string.length(); }
// For WebKit's Swift: ApduCommand::kApduMaxResponseLength, a static constexpr member Swift does not import.
inline size_t apduMaxResponseLength() { return apdu::ApduCommand::kApduMaxResponseLength; }
// ApduResponse::data() by value: Swift imports neither of its const and non-const reference overloads.
inline Vector<uint8_t> apduResponseData(const apdu::ApduResponse& response) { return response.data(); }
// base64EncodeToString and base64URLEncodeToString of a byte vector: Swift reaches only their std::span overloads,
// and only unsafely.
// A byte vector built by bulk copies. Swift gets a Span overload of add (noescape) only on a function whose signature
// has no Vector, so the vector is a member. Its Swift callers pass no empty Span (an empty Span() traps at a std::span).
struct WebAuthnByteSink {
    void reserve(size_t capacity) { bytes.reserveCapacity(capacity); }
    void add([[clang::noescape]] std::span<const uint8_t> span) { bytes.append(span); }
    void addByte(uint8_t byte) { bytes.append(byte); }
    Vector<uint8_t> take() { return std::exchange(bytes, { }); }
    Vector<uint8_t> bytes;
};
inline String base64EncodeBytes(const Vector<uint8_t>& bytes) { return base64EncodeToString(bytes.span()); }
inline String base64URLEncodeBytes(const Vector<uint8_t>& bytes) { return base64URLEncodeToString(bytes.span()); }

} // namespace fido

#endif // ENABLE(WEB_AUTHN)
