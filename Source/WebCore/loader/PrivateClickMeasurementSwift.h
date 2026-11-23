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

#include <WebCore/PrivateClickMeasurement.h>
#include <wtf/JSONValues.h>
#include <wtf/URL.h>
#include <wtf/text/WTFString.h>

// Declarations that WebCore's and WebKit's Private Click Measurement Swift code imports or returns. WebCore-Swift.h
// includes this file for the types the generated header's signatures use.

OBJC_CLASS NSData;

namespace WebCore::PCM {

// Names for the template specializations in the signatures of the Swift functions C++ calls.
using AttributionTriggerDataOrError = std::expected<AttributionTriggerData, String>;
using OptionalURL = std::optional<URL>;
using JSONObjectRef = Ref<JSON::Object>;
using AdamIDValue = std::pair<uint64_t, bool>;
// What pcmCalculateUnlinkableToken() and pcmCalculateSecretToken() return: the unlinkable token, the secret token the
// second one makes, and the error of the step that failed.
struct TokenUpdate {
    UnlinkableToken token;
    SecretToken secretToken;
    std::optional<String> errorMessage;
};
// The AttributionTriggerDataOrError values Swift returns.
inline AttributionTriggerDataOrError attributionTriggerDataResult(AttributionTriggerData data) { return data; }
inline AttributionTriggerDataOrError attributionTriggerDataError(String message) { return makeUnexpected(WTF::move(message)); }

// Swift imports URL::string(), RegistrableDomain::string() and URL(String) as unsafe; these call them and return the
// value.
inline String urlString(const URL& url) { return url.string(); }
inline String domainString(const RegistrableDomain& domain) { return domain.string(); }
inline URL urlFromString(String string) { return URL { WTF::move(string) }; }

#if PLATFORM(COCOA)
// The std::expected results' value() and error() import as UnsafePointer: these return the error, or store the token.
template<typename T>
std::optional<String> takeValueOrError(std::expected<T, String>&& result, std::optional<T>& token)
{
    if (!result)
        return WTF::move(result.error());
    token = WTF::move(*result);
    return std::nullopt;
}
inline std::optional<String> updateDestinationUnlinkableToken(String serverPublicKeyBase64URL, std::optional<DestinationUnlinkableToken>& token) { return takeValueOrError(PrivateClickMeasurement::calculateAndUpdateDestinationUnlinkableToken(WTF::move(serverPublicKeyBase64URL)), token); }
inline std::optional<String> updateDestinationSecretToken(const String& serverResponseBase64URL, DestinationUnlinkableToken& unlinkableToken, std::optional<DestinationSecretToken>& token) { return takeValueOrError(PrivateClickMeasurement::calculateAndUpdateDestinationSecretToken(serverResponseBase64URL, unlinkableToken), token); }
#endif

#if HAVE(RSA_BSSA)
// CryptoKitPrivate does not import into Swift, so PrivateClickMeasurementCocoa.mm makes the RSA blind signature
// calls, reads which of the token's objects exist and writes their data to base64url strings.
std::optional<String> makeBlinder(UnlinkableToken&, NSData *);
std::optional<String> makeWaitingToken(UnlinkableToken&);
std::optional<String> makeReadyToken(UnlinkableToken&, NSData *);
// 1 when the token has a blinder, 2 a waiting token, 4 a ready token; PrivateClickMeasurementCocoa.swift's PCMTokenState
// reads these bits.
uint8_t tokenState(const UnlinkableToken&);
void setBlindedMessageValue(UnlinkableToken&);
void setReadyTokenValues(const UnlinkableToken&, SecretToken&);
#endif

} // namespace WebCore::PCM
