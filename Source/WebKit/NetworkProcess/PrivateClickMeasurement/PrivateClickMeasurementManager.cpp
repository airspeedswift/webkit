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
#include "PrivateClickMeasurementManager.h"

#include "PrivateClickMeasurementEphemeralStore.h"
#include "PrivateClickMeasurementPersistentStore.h"
#include <pal/crypto/CryptoDigest.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {
using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(PrivateClickMeasurementManager);

Ref<PrivateClickMeasurementManager> PrivateClickMeasurementManager::create(UniqueRef<PCM::Client>&& client, const String& storageDirectory, const ApplicationBundleIdentifiersOrAuditToken& applicationBundleIdentifier)
{
    return adoptRef(*new PrivateClickMeasurementManager(WTF::move(client), storageDirectory, applicationBundleIdentifier));
}

PrivateClickMeasurementManager::PrivateClickMeasurementManager(UniqueRef<PCM::Client>&& client, const String& storageDirectory, const ApplicationBundleIdentifiersOrAuditToken& applicationBundleIdentifier)
    : m_firePendingAttributionRequestsTimer(RunLoop::mainSingleton(), "PrivateClickMeasurementManager::FirePendingAttributionRequestsTimer"_s, this, &PrivateClickMeasurementManager::firePendingAttributionRequests)
    , m_storageDirectory(storageDirectory)
    , m_applicationBundleIdentifier(applicationBundleIdentifier)
    , m_client(WTF::move(client))
{
    // We should send any pending attributions on session-start in case their
    // send delay has expired while the session was closed. Waiting 5 seconds accounts for the
    // delay in database startup. When running in the daemon, the xpc activity does this instead.
    if (!m_client->runningInDaemon())
        startTimer(5_s);
}

PrivateClickMeasurementManager::~PrivateClickMeasurementManager()
{
    if (RefPtr store = m_store)
        store->close([] { });
}

void PrivateClickMeasurementManager::storeUnattributed(PrivateClickMeasurement&& measurement, CompletionHandler<void()>&& completionHandler)
{
    if (!featureEnabled())
        return completionHandler();

    clearExpired();

    if (m_privateClickMeasurementAppBundleIDForTesting)
        measurement.setSourceApplicationBundleIDForTesting(*m_privateClickMeasurementAppBundleIDForTesting);

    if (measurement.ephemeralSourceNonce())
        getTokenPublicKeyForUnattributed(measurement);

    m_client->broadcastConsoleMessage(MessageLevel::Log, "[Private Click Measurement] Storing a click."_s);

    insertPrivateClickMeasurement(WTF::move(measurement), PrivateClickMeasurementAttributionType::Unattributed, WTF::move(completionHandler));
}

void PrivateClickMeasurementManager::insertPrivateClickMeasurement(PrivateClickMeasurement&& measurement, PrivateClickMeasurementAttributionType type, CompletionHandler<void()>&& completionHandler)
{
    protect(store())->insertPrivateClickMeasurement(WTF::move(measurement), type, WTF::move(completionHandler));
}

void PrivateClickMeasurementManager::startTimer(Seconds seconds)
{
    m_firePendingAttributionRequestsTimer.startOneShot(seconds);
}

bool PrivateClickMeasurementManager::firePendingAttributionRequestsTimerFiresBefore(Seconds seconds) const
{
    return m_firePendingAttributionRequestsTimer.isActive() && m_firePendingAttributionRequestsTimer.secondsUntilFire() < seconds;
}

void PrivateClickMeasurementManager::startNetworkLoad(URL&& url, RefPtr<JSON::Object>&& jsonPayload, PrivateClickMeasurement::PcmDataCarried pcmDataCarried, PCM::NetworkLoader::Callback&& callback)
{
    PCM::NetworkLoader::start(WTF::move(url), WTF::move(jsonPayload), pcmDataCarried, m_applicationBundleIdentifier, WTF::move(callback));
}

std::optional<String> PrivateClickMeasurementManager::keyIDForPublicKey(const String& publicKeyBase64URL)
{
    const auto publicKeyData = base64URLDecode(publicKeyBase64URL);
    if (!publicKeyData)
        return std::nullopt;

    auto crypto = PAL::Crypto::CryptoDigest::create(PAL::Crypto::CryptoDigest::Algorithm::SHA_256);
    crypto->addBytes(publicKeyData->span());

    return base64URLEncodeToString(crypto->computeHash());
}

void PrivateClickMeasurementManager::clear(CompletionHandler<void()>&& completionHandler)
{
    m_firePendingAttributionRequestsTimer.stop();
    m_privateClickMeasurementAppBundleIDForTesting = std::nullopt;

    if (!featureEnabled())
        return completionHandler();

    protect(store())->clearPrivateClickMeasurement(WTF::move(completionHandler));
}

void PrivateClickMeasurementManager::clearForRegistrableDomain(RegistrableDomain&& domain, CompletionHandler<void()>&& completionHandler)
{
    if (!featureEnabled())
        return completionHandler();

    protect(store())->clearPrivateClickMeasurementForRegistrableDomain(WTF::move(domain), WTF::move(completionHandler));
}

void PrivateClickMeasurementManager::toStringForTesting(CompletionHandler<void(String)>&& completionHandler) const
{
    if (!featureEnabled())
        return completionHandler("\nNo stored Private Click Measurement data.\n"_s);

    protect(store())->privateClickMeasurementToStringForTesting(WTF::move(completionHandler));
}

bool PrivateClickMeasurementManager::featureEnabled() const
{
    return m_client->featureEnabled();
}

bool PrivateClickMeasurementManager::debugModeEnabled() const
{
    return m_client->debugModeEnabled();
}

bool PrivateClickMeasurementManager::shouldBypassPrivateRelay() const
{
    return debugModeEnabled() && !m_client->privateRelayEnforcementEnabled();
}

void PrivateClickMeasurementManager::markAttributedPrivateClickMeasurementsAsExpiredForTesting(CompletionHandler<void()>&& completionHandler)
{
    if (!featureEnabled())
        return completionHandler();

    protect(store())->markAttributedPrivateClickMeasurementsAsExpiredForTesting(WTF::move(completionHandler));
}

void PrivateClickMeasurementManager::initializeStore() const
{
    if (m_store)
        return;

    if (m_client->usesEphemeralDataStore()) {
        ASSERT(m_storageDirectory.isEmpty());
        m_store = PCM::EphemeralStore::create();
    } else
        m_store = PCM::PersistentStore::create(m_storageDirectory);
}

PCM::Store& PrivateClickMeasurementManager::store()
{
    initializeStore();
    return *m_store;
}

const PCM::Store& PrivateClickMeasurementManager::store() const
{
    initializeStore();
    return *m_store;
}

void PrivateClickMeasurementManager::destroyStoreForTesting(CompletionHandler<void()>&& completionHandler)
{
    RefPtr store = m_store;
    if (!store)
        return completionHandler();
    store->close([weakThis = WeakPtr { *this }, completionHandler = WTF::move(completionHandler)] () mutable {
        if (weakThis)
            weakThis->m_store = nullptr;
        return completionHandler();
    });
}

void PrivateClickMeasurementManager::allowTLSCertificateChainForLocalPCMTesting(const WebCore::CertificateInfo& certificateInfo)
{
    PCM::NetworkLoader::allowTLSCertificateChainForLocalPCMTesting(certificateInfo);
}

void PrivateClickMeasurementManager::fetchRegistrableDomains(CompletionHandler<void(Vector<WebCore::RegistrableDomain>&&)>&& completionHandler)
{
    initializeStore();

    if (!m_store) {
        completionHandler({ });
        return;
    }

    protect(store())->fetchRegistrableDomains(WTF::move(completionHandler));
}

} // namespace WebKit
