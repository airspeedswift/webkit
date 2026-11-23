/*
 * Copyright (C) 2019 Apple Inc. All rights reserved.
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

#include "config.h"
#include "PrivateClickMeasurement.h"

#include "PrivateClickMeasurementSwift.h"
#include "WebCore-Swift.h"
#include <wtf/CrossThreadCopier.h>

namespace WebCore {

bool PrivateClickMeasurement::isValid() const
{
    return pcmIsValid(m_attributionTriggerData && m_attributionTriggerData->isValid(), m_sourceSite.registrableDomain.isEmpty(), m_destinationSite.registrableDomain.isEmpty(), m_timesToSend);
}

PCM::UnlinkableToken PCM::UnlinkableToken::isolatedCopy() const &
{
    return {
#if PLATFORM(COCOA)
        blinder, waitingToken, readyToken,
#endif
        valueBase64URL.isolatedCopy()
    };
}

PCM::UnlinkableToken PCM::UnlinkableToken::isolatedCopy()&&
{
    return {
#if PLATFORM(COCOA)
        blinder, waitingToken, readyToken,
#endif
        WTF::move(valueBase64URL).isolatedCopy()
    };
}

PCM::SourceUnlinkableToken PCM::SourceUnlinkableToken::isolatedCopy() const &
{
    return { UnlinkableToken::isolatedCopy() };
}

PCM::SourceUnlinkableToken PCM::SourceUnlinkableToken::isolatedCopy() &&
{
    return { UnlinkableToken::isolatedCopy() };
}

PCM::DestinationUnlinkableToken PCM::DestinationUnlinkableToken::isolatedCopy() const &
{
    return { UnlinkableToken::isolatedCopy() };
}

PCM::DestinationUnlinkableToken PCM::DestinationUnlinkableToken::isolatedCopy() &&
{
    return { UnlinkableToken::isolatedCopy() };
}

PrivateClickMeasurement PrivateClickMeasurement::isolatedCopy() const &
{
    PrivateClickMeasurement copy {
        m_sourceID,
        m_sourceSite.isolatedCopy(),
        m_destinationSite.isolatedCopy(),
        m_sourceApplicationBundleID.isolatedCopy(),
        m_timeOfAdClick.isolatedCopy(),
        m_isEphemeral,
    };
    copy.m_attributionTriggerData = m_attributionTriggerData;
    copy.m_timesToSend = m_timesToSend;
    copy.m_ephemeralSourceNonce = crossThreadCopy(m_ephemeralSourceNonce);
    copy.m_sourceUnlinkableToken = m_sourceUnlinkableToken.isolatedCopy();
    copy.m_sourceSecretToken = crossThreadCopy(m_sourceSecretToken);
    return copy;
}

PrivateClickMeasurement PrivateClickMeasurement::isolatedCopy() &&
{
    PrivateClickMeasurement copy {
        m_sourceID,
        WTF::move(m_sourceSite).isolatedCopy(),
        WTF::move(m_destinationSite).isolatedCopy(),
        WTF::move(m_sourceApplicationBundleID).isolatedCopy(),
        WTF::move(m_timeOfAdClick).isolatedCopy(),
        m_isEphemeral,
    };
    copy.m_attributionTriggerData = WTF::move(m_attributionTriggerData);
    copy.m_timesToSend = WTF::move(m_timesToSend);
    copy.m_ephemeralSourceNonce = crossThreadCopy(WTF::move(m_ephemeralSourceNonce));
    copy.m_sourceUnlinkableToken = WTF::move(m_sourceUnlinkableToken).isolatedCopy();
    copy.m_sourceSecretToken = crossThreadCopy(WTF::move(m_sourceSecretToken));
    return copy;
}

bool PrivateClickMeasurement::isNeitherSameSiteNorCrossSiteTriggeringEvent(const RegistrableDomain& redirectDomain, const URL& firstPartyURL, const PCM::AttributionTriggerData& attributionTriggerData)
{
    return pcmIsNeitherSameSiteNorCrossSiteTriggeringEvent(m_sourceSite.registrableDomain, redirectDomain, firstPartyURL, !!attributionTriggerData.sourceRegistrableDomain);
}

bool PrivateClickMeasurement::hasPreviouslyBeenReported()
{
    return pcmHasPreviouslyBeenReported(m_timesToSend);
}

void PrivateClickMeasurement::setSourceApplicationBundleIDForTesting(const String& appBundleIDForTesting)
{
    m_sourceApplicationBundleID = appBundleIDForTesting;
}

PCM::AttributionSecondsUntilSendData PrivateClickMeasurement::attributeAndGetEarliestTimeToSend(PCM::AttributionTriggerData&& attributionTriggerData, IsRunningLayoutTest isRunningTest)
{
    // The literals in PrivateClickMeasurement.swift (triggerDataMaxEntropy, priorityMaxEntropy) are these values.
    static_assert(PCM::AttributionTriggerData::MaxEntropy == 15 && PCM::AttributionTriggerData::Priority::MaxEntropy == 63);
    auto secondsUntilSend = pcmAttributionSecondsUntilSend(attributionTriggerData.isValid(), attributionTriggerData.priority, !!m_attributionTriggerData, m_attributionTriggerData ? m_attributionTriggerData->priority : 0, isRunningTest);
    if (!secondsUntilSend.hasValidSecondsUntilSendValues())
        return secondsUntilSend;
    m_attributionTriggerData = WTF::move(attributionTriggerData);
    m_timesToSend = { WallTime::now() + *secondsUntilSend.sourceSeconds, WallTime::now() + *secondsUntilSend.destinationSeconds };
    return secondsUntilSend;
}

bool PrivateClickMeasurement::hasHigherPriorityThan(const PrivateClickMeasurement& other) const
{
    return pcmHasHigherPriorityThan(!!m_attributionTriggerData, m_attributionTriggerData ? m_attributionTriggerData->priority : 0, !!other.m_attributionTriggerData, other.m_attributionTriggerData ? other.m_attributionTriggerData->priority : 0);
}

URL PrivateClickMeasurement::attributionReportClickSourceURL() const
{
    return pcmAttributionReportURL(isValid(), m_sourceSite.registrableDomain);
}

URL PrivateClickMeasurement::attributionReportClickDestinationURL() const
{
    return pcmAttributionReportURL(isValid(), m_destinationSite.registrableDomain);
}

Ref<JSON::Object> PrivateClickMeasurement::attributionReportJSON() const
{
    if (!m_attributionTriggerData || !isValid())
        return JSON::Object::create();
    return pcmAttributionReportJSON(m_sourceID, m_sourceSite.registrableDomain, m_destinationSite.registrableDomain, m_attributionTriggerData->data,
        !!m_sourceSecretToken, m_sourceSecretToken ? m_sourceSecretToken->tokenBase64URL : String { }, m_sourceSecretToken ? m_sourceSecretToken->signatureBase64URL : String { },
        !!m_attributionTriggerData->destinationSecretToken, m_attributionTriggerData->destinationSecretToken ? m_attributionTriggerData->destinationSecretToken->tokenBase64URL : String { }, m_attributionTriggerData->destinationSecretToken ? m_attributionTriggerData->destinationSecretToken->signatureBase64URL : String { });
}

bool PCM::EphemeralNonce::isValid() const
{
    return pcmEphemeralNonceIsValid(nonce);
}

void PrivateClickMeasurement::setEphemeralSourceNonce(PCM::EphemeralNonce&& nonce)
{
    if (!nonce.isValid())
        return;
    m_ephemeralSourceNonce = WTF::move(nonce);
}

std::optional<URL> PrivateClickMeasurement::tokenPublicKeyURL() const
{
    return tokenPublicKeyURL(m_sourceSite.registrableDomain);
}

std::optional<URL> PrivateClickMeasurement::tokenSignatureURL() const
{
    return pcmTokenSignatureURL(m_ephemeralSourceNonce ? m_ephemeralSourceNonce->nonce : String { }, m_sourceSite.registrableDomain);
}

Ref<JSON::Object> PrivateClickMeasurement::tokenSignatureJSON() const
{
    return pcmTokenSignatureJSON(m_ephemeralSourceNonce ? m_ephemeralSourceNonce->nonce : String { }, m_sourceUnlinkableToken.valueBase64URL, PCM::AttributionReportEndpoint::Source);
}

Ref<JSON::Object> PCM::AttributionTriggerData::tokenSignatureJSON() const
{
    return pcmTokenSignatureJSON(ephemeralDestinationNonce ? ephemeralDestinationNonce->nonce : String { }, destinationUnlinkableToken ? destinationUnlinkableToken->valueBase64URL : String { }, PCM::AttributionReportEndpoint::Destination);
}

bool PCM::SecretToken::isValid() const
{
    return !(tokenBase64URL.isEmpty() || signatureBase64URL.isEmpty() || keyIDBase64URL.isEmpty());
}

void PrivateClickMeasurement::setSourceSecretToken(PCM::SourceSecretToken&& token)
{
    if (!token.isValid())
        return;
    m_sourceSecretToken = WTF::move(token);
}

void PrivateClickMeasurement::setDestinationSecretToken(PCM::DestinationSecretToken&& token)
{
    if (!token.isValid() || !m_attributionTriggerData)
        return;
    m_attributionTriggerData->destinationSecretToken = WTF::move(token);
}

std::optional<uint64_t> PrivateClickMeasurement::appStoreURLAdamID(URL url)
{
    auto adamID = pcmAppStoreURLAdamID(WTF::move(url));
    return adamID.second ? std::optional { adamID.first } : std::nullopt;
}

} // namespace WebCore
