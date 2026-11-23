/*
 * Copyright (C) 2019-2025 Apple Inc. All rights reserved.
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

#include "PrivateClickMeasurementClient.h"
#include "PrivateClickMeasurementManagerInterface.h"
#include "PrivateClickMeasurementNetworkLoader.h"
#include "PrivateClickMeasurementStore.h"
#include <JavaScriptCore/ConsoleTypes.h>
#include <WebCore/Timer.h>
#include <wtf/CompletionHandler.h>
#include <wtf/JSONValues.h>
#include <wtf/SwiftBridging.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/WeakPtr.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

using ApplicationBundleIdentifiersOrAuditToken = Variant<std::pair<String, String>, Vector<uint8_t>>;

class SWIFT_PRIVATE_FILEID("WebKit/PrivateClickMeasurementManager.swift") PrivateClickMeasurementManager : public PCM::ManagerInterface, public CanMakeWeakPtr<PrivateClickMeasurementManager> {
    WTF_MAKE_TZONE_ALLOCATED(PrivateClickMeasurementManager);
public:
    static Ref<PrivateClickMeasurementManager> create(UniqueRef<PCM::Client>&&, const String& storageDirectory, const ApplicationBundleIdentifiersOrAuditToken&);

    ~PrivateClickMeasurementManager();

    using ApplicationBundleIdentifier = String;

    // Implemented in PrivateClickMeasurementManager.swift, except setOverrideTimerForTesting(),
    // allowTLSCertificateChainForLocalPCMTesting() and the members that take a CompletionHandler&&, which Swift
    // cannot implement.
    void storeUnattributed(PrivateClickMeasurement&&, CompletionHandler<void()>&&) final;
    void handleAttribution(AttributionTriggerData, URL requestURL, WebCore::RegistrableDomain redirectDomain, URL firstPartyURL, ApplicationBundleIdentifier) final;
    void checkAttributionTimer() final;
    void clear(CompletionHandler<void()>&&) final;
    void clearForRegistrableDomain(RegistrableDomain&&, CompletionHandler<void()>&&) final;
    void migratePrivateClickMeasurementFromLegacyStorage(PrivateClickMeasurement, PrivateClickMeasurementAttributionType) final;
    void setDebugModeIsEnabled(bool) final;
    void setPrivateRelayEnforcementIsEnabled(bool) final;
    void firePendingAttributionRequests();

    void toStringForTesting(CompletionHandler<void(String)>&&) const final;
    void setOverrideTimerForTesting(bool value) final { m_isRunningTest = value; }
    void setTokenPublicKeyURLForTesting(URL) final;
    void setTokenSignatureURLForTesting(URL) final;
    void setAttributionReportURLsForTesting(URL sourceURL, URL destinationURL) final;
    void markAllUnattributedAsExpiredForTesting() final;
    void markAttributedPrivateClickMeasurementsAsExpiredForTesting(CompletionHandler<void()>&&) final;
    void setPCMFraudPreventionValuesForTesting(String unlinkableToken, String secretToken, String signature, String keyID) final;
    void startTimerImmediatelyForTesting() final;
    void setPrivateClickMeasurementAppBundleIDForTesting(ApplicationBundleIdentifier);
    void destroyStoreForTesting(CompletionHandler<void()>&&) final;
    void allowTLSCertificateChainForLocalPCMTesting(const WebCore::CertificateInfo&) final;
    void fetchRegistrableDomains(CompletionHandler<void(Vector<WebCore::RegistrableDomain>&&)>&&);

private:
    PrivateClickMeasurementManager(UniqueRef<PCM::Client>&&, const String& storageDirectory, const ApplicationBundleIdentifiersOrAuditToken&);

    // The name Swift uses to construct a RefPtr<JSON::Object>.
    using RefPtrJSONObject = RefPtr<JSON::Object>;

    PCM::Store& store();
    const PCM::Store& store() const;
    void initializeStore() const;
    void startTimer(Seconds);
    void insertPrivateClickMeasurement(PrivateClickMeasurement&&, PrivateClickMeasurementAttributionType, CompletionHandler<void()>&&);
    // Implemented in PrivateClickMeasurementManager.swift. getTokenPublicKeyForUnattributed() is the token request
    // storeUnattributed() makes for a click with an ephemeral nonce.
    void getTokenPublicKeyForUnattributed(PrivateClickMeasurement);
    void clearExpired();

    // PCM::NetworkLoader::start is SWIFT_UNSAFE; this is Swift's one route to it, with m_applicationBundleIdentifier.
    void startNetworkLoad(URL&&, RefPtrJSONObject&&, PrivateClickMeasurement::PcmDataCarried, PCM::NetworkLoader::Callback&&);
    // Swift reads a RunLoop::Timer only as unsafe.
    bool firePendingAttributionRequestsTimerFiresBefore(Seconds) const;
    // The WeakPtr Swift's callbacks capture; Swift does not construct one from self.
    WeakPtr<PrivateClickMeasurementManager> weakPtrForSwift() { return *this; }
    // WebKit's Swift cannot name PAL::Crypto::CryptoDigest.
    static std::optional<String> keyIDForPublicKey(const String& publicKeyBase64URL);
    // m_client is a UniqueRef<PCM::Client>, which Swift cannot call through.
    void broadcastConsoleMessage(JSC::MessageLevel level, const String& message) { m_client->broadcastConsoleMessage(level, message); }
    bool featureEnabled() const;
    bool debugModeEnabled() const;
    bool shouldBypassPrivateRelay() const;

    RunLoop::Timer m_firePendingAttributionRequestsTimer;
    bool m_isRunningTest { false };
    std::optional<URL> m_tokenPublicKeyURLForTesting;
    std::optional<URL> m_tokenSignatureURLForTesting;
    std::optional<ApplicationBundleIdentifier> m_privateClickMeasurementAppBundleIDForTesting;
    mutable RefPtr<PCM::Store> m_store;
    String m_storageDirectory;
    const ApplicationBundleIdentifiersOrAuditToken m_applicationBundleIdentifier;
    const UniqueRef<PCM::Client> m_client;

    struct AttributionReportTestConfig {
        URL attributionReportClickSourceURL;
        URL attributionReportClickDestinationURL;
    };

    std::optional<AttributionReportTestConfig> m_attributionReportTestConfig;

    struct TestingFraudPreventionValues {
        String unlinkableTokenForSource;
        String secretTokenForSource;
        String signatureForSource;
        String keyIDForSource;
        String unlinkableTokenForDestination;
        String secretTokenForDestination;
        String signatureForDestination;
        String keyIDForDestination;
    };

    std::optional<TestingFraudPreventionValues> m_fraudPreventionValuesForTesting;
};
    
} // namespace WebKit
