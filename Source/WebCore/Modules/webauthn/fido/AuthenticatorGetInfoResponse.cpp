// Copyright 2018 The Chromium Authors. All rights reserved.
// Copyright (C) 2018 Apple Inc. All rights reserved.
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
#include "AuthenticatorGetInfoResponse.h"

#if ENABLE(WEB_AUTHN)

#include "WebCore-Swift.h"

namespace fido {

AuthenticatorGetInfoResponse::AuthenticatorGetInfoResponse(StdSet<ProtocolVersion>&& versions, Vector<uint8_t>&& aaguid)
    : m_versions(WTF::move(versions))
    , m_aaguid(WTF::move(aaguid))
{
}

AuthenticatorGetInfoResponse& AuthenticatorGetInfoResponse::setMaxMsgSize(uint32_t maxMsgSize)
{
    m_maxMsgSize = maxMsgSize;
    return *this;
}

AuthenticatorGetInfoResponse& AuthenticatorGetInfoResponse::setPinProtocols(StdSet<PINUVAuthProtocol>&& pinProtocols)
{
    m_pinProtocols = WTF::move(pinProtocols);
    return *this;
}

AuthenticatorGetInfoResponse& AuthenticatorGetInfoResponse::setExtensions(Vector<String>&& extensions)
{
    m_extensions = WTF::move(extensions);
    return *this;
}

AuthenticatorGetInfoResponse& AuthenticatorGetInfoResponse::setOptions(AuthenticatorSupportedOptions&& options)
{
    m_options = WTF::move(options);
    return *this;
}

AuthenticatorGetInfoResponse& AuthenticatorGetInfoResponse::setTransports(Vector<WebCore::AuthenticatorTransport>&& transports)
{
    m_transports = WTF::move(transports);
    return *this;
}

AuthenticatorGetInfoResponse& AuthenticatorGetInfoResponse::setRemainingDiscoverableCredentials(uint32_t remainingDiscoverableCredentials)
{
    m_remainingDiscoverableCredentials = remainingDiscoverableCredentials;
    return *this;
}

AuthenticatorGetInfoResponse& AuthenticatorGetInfoResponse::setMinPINLength(uint32_t minPINLength)
{
    m_minPINLength = minPINLength;
    return *this;
}

AuthenticatorGetInfoResponse& AuthenticatorGetInfoResponse::setMaxCredentialCountInList(uint32_t maxCredentialCountInList)
{
    m_maxCredentialCountInList = maxCredentialCountInList;
    return *this;
}

AuthenticatorGetInfoResponse& AuthenticatorGetInfoResponse::setMaxCredentialIDLength(uint32_t maxCredentialIDLength)
{
    m_maxCredentialIdLength = maxCredentialIDLength;
    return *this;
}

Vector<uint8_t> encodeAsCBOR(AuthenticatorGetInfoResponse response)
{
    return WebCore::encodeGetInfoResponseAsCBOR(response);
}


std::optional<AuthenticatorGetInfoResponse> makeGetInfoResponse(GetInfoResponseFields&& fields)
{
    if (fields.versions.isEmpty())
        return std::nullopt;
    AuthenticatorGetInfoResponse response(StdSet<ProtocolVersion>(fields.versions.begin(), fields.versions.end()), WTF::move(fields.aaguid));
    if (fields.maxMsgSize)
        response.setMaxMsgSize(*fields.maxMsgSize);
    if (fields.pinProtocols)
        response.setPinProtocols(StdSet<PINUVAuthProtocol>(fields.pinProtocols->begin(), fields.pinProtocols->end()));
    if (fields.extensions)
        response.setExtensions(WTF::move(*fields.extensions));
    AuthenticatorSupportedOptions options;
    options.setIsPlatformDevice(fields.isPlatformDevice).setResidentKeyAvailability(fields.residentKeyAvailability).setUserVerificationAvailability(fields.userVerificationAvailability).setUserPresenceRequired(fields.userPresenceRequired).setClientPinAvailability(fields.clientPinAvailability);
    response.setOptions(WTF::move(options));
    if (fields.transports)
        response.setTransports(WTF::move(*fields.transports));
    if (fields.remainingDiscoverableCredentials)
        response.setRemainingDiscoverableCredentials(*fields.remainingDiscoverableCredentials);
    if (fields.minPINLength)
        response.setMinPINLength(*fields.minPINLength);
    if (fields.maxCredentialCountInList)
        response.setMaxCredentialCountInList(*fields.maxCredentialCountInList);
    if (fields.maxCredentialIDLength)
        response.setMaxCredentialIDLength(*fields.maxCredentialIDLength);
    return response;
}

GetInfoResponseFields getInfoResponseFields(const AuthenticatorGetInfoResponse& response)
{
    auto& options = response.options();
    return {
        .versions = WTF::copyToVector(response.versions()),
        .aaguid = response.aaguid(),
        .maxMsgSize = response.maxMsgSize(),
        .pinProtocols = response.pinProtocol() ? std::optional(WTF::copyToVector(*response.pinProtocol())) : std::nullopt,
        .extensions = response.extensions(),
        .isPlatformDevice = options.isPlatformDevice(),
        .residentKeyAvailability = options.residentKeyAvailability(),
        .userVerificationAvailability = options.userVerificationAvailability(),
        .userPresenceRequired = options.userPresenceRequired(),
        .clientPinAvailability = options.clientPinAvailability(),
        .transports = response.transports(),
        .remainingDiscoverableCredentials = response.remainingDiscoverableCredentials(),
        .minPINLength = response.minPINLength(),
        .maxCredentialCountInList = response.maxCredentialCountInList(),
        .maxCredentialIDLength = response.maxCredentialIDLength(),
        .algorithms = response.algorithms(),
    };
}

// The FidoConstants.h names that WebAuthnCtapRequests.swift's FidoName spells as literals (ASCIILiteral does not
// import).
static consteval bool spells(ASCIILiteral name, std::string_view literal)
{
    return std::string_view(name.characters(), name.length()) == literal;
}
static_assert(spells(kResidentKeyMapKey, "rk") && spells(kUserVerificationMapKey, "uv") && spells(kUserPresenceMapKey, "up"));
static_assert(spells(kClientPinMapKey, "clientPin") && spells(kPlatformDeviceMapKey, "plat"));
static_assert(spells(kEntityIdMapKey, "id") && spells(kEntityNameMapKey, "name") && spells(kDisplayNameMapKey, "displayName"));
static_assert(spells(kIconUrlMapKey, "icon") && spells(kCredentialTypeMapKey, "type") && spells(kCredentialAlgorithmMapKey, "alg"));
static_assert(spells(kCredentialIdKey, "id") && spells(kCredentialTypeKey, "type") && spells(kPublicKey, "public-key"));
static_assert(spells(kCtap2Version, "FIDO_2_0") && spells(kCtap21Version, "FIDO_2_1") && spells(kCtap21PreVersion, "FIDO_2_1_PRE"));
static_assert(spells(kU2fVersion, "U2F_V2") && spells(kExtensionHmacSecret, "hmac-secret") && spells(kExtensionHmacSecretMc, "hmac-secret-mc"));
static_assert(spells(kFormatKey, "fmt") && spells(kAttestationStatementKey, "attStmt") && spells(kAuthDataKey, "authData"));

} // namespace fido

#endif // ENABLE(WEB_AUTHN)
