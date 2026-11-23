/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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

#import "config.h"
#import "PrivateClickMeasurement.h"

#import "PrivateClickMeasurementSwift.h"
#import "WebCore-Swift.h"
#import <wtf/cocoa/SpanCocoa.h>

#import <pal/cocoa/CryptoKitPrivateSoftLink.h>

namespace WebCore {

std::optional<String> PrivateClickMeasurement::calculateAndUpdateSourceUnlinkableToken(const String& serverPublicKeyBase64URL)
{
    auto update = pcmCalculateUnlinkableToken(serverPublicKeyBase64URL, WTF::move(m_sourceUnlinkableToken), PCM::AttributionReportEndpoint::Source);
    static_cast<PCM::UnlinkableToken&>(m_sourceUnlinkableToken) = WTF::move(update.token);
    return WTF::move(update.errorMessage);
}

std::expected<PCM::DestinationUnlinkableToken, String> PrivateClickMeasurement::calculateAndUpdateDestinationUnlinkableToken(String serverPublicKeyBase64URL)
{
    auto update = pcmCalculateUnlinkableToken(WTF::move(serverPublicKeyBase64URL), { }, PCM::AttributionReportEndpoint::Destination);
    if (update.errorMessage)
        return makeUnexpected(WTF::move(*update.errorMessage));
    return PCM::DestinationUnlinkableToken { WTF::move(update.token) };
}

std::optional<String> PrivateClickMeasurement::calculateAndUpdateSourceSecretToken(const String& serverResponseBase64URL)
{
    auto update = pcmCalculateSecretToken(serverResponseBase64URL, WTF::move(m_sourceUnlinkableToken), PCM::AttributionReportEndpoint::Source);
    static_cast<PCM::UnlinkableToken&>(m_sourceUnlinkableToken) = WTF::move(update.token);
    if (update.errorMessage)
        return WTF::move(update.errorMessage);
    m_sourceSecretToken = PCM::SourceSecretToken { WTF::move(update.secretToken) };
    return std::nullopt;
}

std::expected<PCM::DestinationSecretToken, String> PrivateClickMeasurement::calculateAndUpdateDestinationSecretToken(const String& serverResponseBase64URL, PCM::DestinationUnlinkableToken& unlinkableToken)
{
    auto update = pcmCalculateSecretToken(serverResponseBase64URL, WTF::move(unlinkableToken), PCM::AttributionReportEndpoint::Destination);
    static_cast<PCM::UnlinkableToken&>(unlinkableToken) = WTF::move(update.token);
    if (update.errorMessage)
        return makeUnexpected(WTF::move(*update.errorMessage));
    return PCM::DestinationSecretToken { WTF::move(update.secretToken) };
}

} // namespace WebCore

#if HAVE(RSA_BSSA)

// Declared in PrivateClickMeasurementSwift.h.
namespace WebCore::PCM {

std::optional<String> makeBlinder(UnlinkableToken& token, NSData *serverPublicKey)
{
    NSError* nsError = 0;
    token.blinder = adoptNS([PAL::allocRSABSSATokenBlinderInstance() initWithPublicKey:serverPublicKey error:&nsError]);
    if (nsError)
        return nsError.localizedDescription;
    return std::nullopt;
}

std::optional<String> makeWaitingToken(UnlinkableToken& token)
{
    NSError* nsError = 0;
    token.waitingToken = [token.blinder tokenWaitingActivationWithContent:nullptr error:&nsError];
    if (nsError)
        return nsError.localizedDescription;
    return std::nullopt;
}

std::optional<String> makeReadyToken(UnlinkableToken& token, NSData *serverResponse)
{
    NSError* nsError = 0;
    token.readyToken = [token.waitingToken activateTokenWithServerResponse:serverResponse error:&nsError];
    if (nsError)
        return nsError.localizedDescription;
    return std::nullopt;
}

uint8_t tokenState(const UnlinkableToken& token)
{
    return (token.blinder ? 1 : 0) | (token.waitingToken ? 2 : 0) | (token.readyToken ? 4 : 0);
}

void setBlindedMessageValue(UnlinkableToken& unlinkableToken)
{
    unlinkableToken.valueBase64URL = base64URLEncodeToString(span([unlinkableToken.waitingToken blindedMessage]));
}

void setReadyTokenValues(const UnlinkableToken& unlinkableToken, SecretToken& secretToken)
{
    secretToken.tokenBase64URL = base64URLEncodeToString(span([unlinkableToken.readyToken tokenContent]));
    secretToken.keyIDBase64URL = base64URLEncodeToString(span([unlinkableToken.readyToken keyId]));
    secretToken.signatureBase64URL = base64URLEncodeToString(span([unlinkableToken.readyToken signature]));
}

} // namespace WebCore::PCM

#endif // HAVE(RSA_BSSA)
