// Copyright (C) 2019 Apple Inc. All rights reserved.
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

import WebCore_Private.Core.PrivateClickMeasurementSwift
import WebKit_Internal
import os
import wtf
import wtf.Core.CryptographicallyRandomNumber

// The completion handlers passed to the store and the network loader.
extension WebKit.PCM.NetworkLoader.Callback: CxxCompletionHandler {
    typealias Argument = WebKit.PCM.NetworkLoader.Response
}

extension WebKit.PCM.Store.AttributionHandler: CxxCompletionHandler {
    typealias Argument = WebKit.PCM.AttributionResult
}

extension WebKit.PCM.Store.AllAttributedHandler: CxxCompletionHandler {
    typealias Argument = WebKit.PCM.Store.PrivateClickMeasurementVector
}

extension WebKit.PrivateClickMeasurementManager {
    // MARK: ManagerInterface overrides

    @cxx
    @implementation
    override func handleAttribution(
        _ attributionTriggerData: WebCore.PCM.AttributionTriggerData,
        _ requestURL: WTF.URL,
        _ redirectDomain: WebCore.RegistrableDomain,
        _ firstPartyURL: WTF.URL,
        _ applicationBundleIdentifier: WTF.String
    ) {
        if !featureEnabled() {
            return
        }

        if !redirectDomain.matches(requestURL) {
            broadcastConsoleMessage(
                .Warning,
                "[Private Click Measurement] Triggering event was not accepted because the HTTP redirect was not same-site."
            )
            return
        }

        let sourceDomain: WebCore.RegistrableDomain
        if redirectDomain.matches(firstPartyURL) {
            guard let domain = attributionTriggerData.sourceRegistrableDomain.value else {
                broadcastConsoleMessage(
                    .Warning,
                    "[Private Click Measurement] Triggering event was not accepted because it was requested in an HTTP redirect that is same-site as the first-party and no attributionSource query parameter was provided."
                )
                return
            }
            sourceDomain = domain
        } else if attributionTriggerData.sourceRegistrableDomain.value != nil {
            broadcastConsoleMessage(
                .Warning,
                "[Private Click Measurement] Triggering event was not accepted because it was requested in an HTTP redirect that is cross-site from the first-party but an attributionSource query parameter was still provided."
            )
            return
        } else {
            sourceDomain = redirectDomain
        }

        broadcastConsoleMessage(.Log, "[Private Click Measurement] Triggering event accepted.")

        // Signing of a destination token must be done unconditionally. Otherwise it becomes a way to discover that there is a pending attribution.
        if attributionTriggerData.ephemeralDestinationNonce.value != nil {
            let weakThis = weakPtrForSwift()
            let sourceSite = WebCore.PCM.SourceSite(consuming: sourceDomain)
            let destinationSite = WebCore.PCM.AttributionDestinationSite(firstPartyURL)
            let applicationBundleIdentifier = applicationBundleIdentifier.isolatedCopy()
            // This is guaranteed to be close in time to the triggering event which makes it likely to be personally identifiable.
            getTokenPublicKey(attributionTriggerData, .Destination, .PersonallyIdentifiable) {
                attributionTriggerData,
                publicKeyBase64URL in
                guard let protectedThis = weakThis.get() else {
                    return
                }
                protectedThis.didReceiveDestinationTokenPublicKey(
                    consume attributionTriggerData,
                    publicKeyBase64URL,
                    sourceSite: sourceSite,
                    destinationSite: destinationSite,
                    applicationBundleIdentifier: applicationBundleIdentifier
                )
            }
            return
        }

        let bundleIdentifier = bundleIdentifierForAttribution(applicationBundleIdentifier)
        attribute(
            WebCore.PCM.SourceSite(consuming: sourceDomain),
            WebCore.PCM.AttributionDestinationSite(firstPartyURL),
            attributionTriggerData,
            bundleIdentifier
        )
    }

    @cxx
    @implementation
    override func checkAttributionTimer() {
        startTimer(WTF.Seconds(5))
    }

    @cxx
    @implementation
    override func startTimerImmediatelyForTesting() {
        startTimer(WTF.Seconds(0))
    }

    @cxx
    @implementation
    override func setDebugModeIsEnabled(_ enabled: Bool) {
        // This doesn't maintain global state, it just broadcasts a message when debug mode enabled changes.
        // The state is either stored in NetworkSession when not using the daemon
        // or in DaemonConnectionSet per-connection when using the daemon.
        let message = enabled ? "[Private Click Measurement] Turned Debug Mode on." : "[Private Click Measurement] Turned Debug Mode off."
        broadcastConsoleMessage(.Info, message)
    }

    @cxx
    @implementation
    override func setPrivateRelayEnforcementIsEnabled(_ enabled: Bool) {
        let message =
            enabled
            ? "[Private Click Measurement] Turned Private Relay Enforcement on."
            : "[Private Click Measurement] Turned Private Relay Enforcement off."
        broadcastConsoleMessage(.Info, message)
    }

    @cxx
    @implementation
    override func setTokenPublicKeyURLForTesting(_ testURL: WTF.URL) {
        if testURL.isEmpty() {
            return
        }
        m_tokenPublicKeyURLForTesting = .init(testURL)
    }

    @cxx
    @implementation
    override func setTokenSignatureURLForTesting(_ testURL: WTF.URL) {
        if testURL.isEmpty() {
            m_tokenSignatureURLForTesting = .init()
        } else {
            m_tokenSignatureURLForTesting = .init(testURL)
        }
    }

    @cxx
    @implementation
    override func setAttributionReportURLsForTesting(_ sourceURL: WTF.URL, _ destinationURL: WTF.URL) {
        if sourceURL.isEmpty() || destinationURL.isEmpty() {
            m_attributionReportTestConfig = .init()
        } else {
            // AttributionReportTestConfig has no imported memberwise initializer.
            var config = Self.AttributionReportTestConfig()
            config.attributionReportClickSourceURL = sourceURL
            config.attributionReportClickDestinationURL = destinationURL
            m_attributionReportTestConfig = .init(config)
        }
    }

    @cxx
    @implementation
    override func markAllUnattributedAsExpiredForTesting() {
        if !featureEnabled() {
            return
        }
        store().markAllUnattributedPrivateClickMeasurementAsExpiredForTesting()
    }

    @cxx
    @implementation
    override func setPCMFraudPreventionValuesForTesting(
        _ unlinkableToken: WTF.String,
        _ secretToken: WTF.String,
        _ signature: WTF.String,
        _ keyID: WTF.String
    ) {
        if unlinkableToken.isEmpty() || secretToken.isEmpty() || signature.isEmpty() || keyID.isEmpty() {
            return
        }
        let emptyString = WTF.String.pcmASCII("")
        var values = Self.TestingFraudPreventionValues()
        values.unlinkableTokenForSource = unlinkableToken
        values.secretTokenForSource = secretToken
        values.signatureForSource = signature
        values.keyIDForSource = keyID
        values.unlinkableTokenForDestination = emptyString
        values.secretTokenForDestination = emptyString
        values.signatureForDestination = emptyString
        values.keyIDForDestination = emptyString
        m_fraudPreventionValuesForTesting = .init(values)
    }

    @cxx
    @implementation
    override func setPrivateClickMeasurementAppBundleIDForTesting(_ appBundleID: WTF.String) {
        if appBundleID.isEmpty() {
            m_privateClickMeasurementAppBundleIDForTesting = .init()
        } else {
            m_privateClickMeasurementAppBundleIDForTesting = .init(appBundleID)
        }
    }

    @cxx
    @implementation
    override func migratePrivateClickMeasurementFromLegacyStorage(
        _ measurement: WebCore.PrivateClickMeasurement,
        _ type: WebKit.PrivateClickMeasurementAttributionType
    ) {
        insertPrivateClickMeasurement(consuming: measurement, type, consuming: WTF.VoidCompletionHandler {})
    }

    // MARK: Attribution timer

    @cxx
    @implementation
    func firePendingAttributionRequests() {
        if !featureEnabled() {
            return
        }

        let weakThis = weakPtrForSwift()
        store()
            .allAttributedPrivateClickMeasurement(
                consuming: .init { (attributions: WebKit.PCM.Store.PrivateClickMeasurementVector) in
                    guard let protectedThis = weakThis.get() else {
                        return
                    }
                    var nextTimeToFire = WTF.Seconds.infinity()
                    var hasSentAttribution = false

                    for attribution in attributions {
                        // AttributionTimeToSendData's accessors are non-const.
                        var timesToSend = attribution.timesToSend()
                        let earliestTimeToSend = timesToSend.earliestTimeToSend().value
                        let attributionReportEndpoint = timesToSend.attributionReportEndpoint().value

                        guard let earliestTimeToSend, let attributionReportEndpoint else {
                            assertionFailure()
                            continue
                        }

                        let now = WTF.WallTime.now()
                        if earliestTimeToSend.secondsSinceEpoch().value() <= now.secondsSinceEpoch().value()
                            || protectedThis.m_isRunningTest || protectedThis.debugModeEnabled()
                        {
                            if hasSentAttribution {
                                // We've already sent an attribution this round. We should send additional overdue attributions at
                                // a random time between 15 and 30 minutes to avoid a burst of simultaneous attributions. If debug
                                // mode is enabled, this should be much shorter for easy testing.
                                protectedThis.startTimer(protectedThis.randomlyBetweenFifteenAndThirtyMinutes())
                                return
                            }

                            let laterTimeToSend = timesToSend.latestTimeToSend().value
                            protectedThis.fireConversionRequest(attribution, attributionReportEndpoint)
                            protectedThis.clearSentAttribution(consume attribution, attributionReportEndpoint)
                            hasSentAttribution = true

                            // Update nextTimeToFire in case the later report time for this attribution is sooner than the scheduled next time to fire.
                            // Or, if debug mode is enabled, we should send the second report on a much shorter delay for easy testing.
                            if let laterTimeToSend {
                                let secondsFromNow = WTF.Seconds(
                                    laterTimeToSend.secondsSinceEpoch().value() - WTF.WallTime.now().secondsSinceEpoch().value()
                                )
                                // Avoid sending expired attributions in bursts by using a random 15-30 minute interval if laterTimeToSend is expired.
                                let laterTimeToSendInSecondsFromNow =
                                    secondsFromNow.value() < 0
                                    ? protectedThis.randomlyBetweenFifteenAndThirtyMinutes() : secondsFromNow
                                nextTimeToFire =
                                    protectedThis.debugModeEnabled()
                                    ? Self.debugModeSecondsUntilSend : nextTimeToFire.minimum(laterTimeToSendInSecondsFromNow)
                            }
                            continue
                        }

                        let seconds = WTF.Seconds(earliestTimeToSend.secondsSinceEpoch().value() - now.secondsSinceEpoch().value())
                        nextTimeToFire = nextTimeToFire.minimum(seconds)

                        // Attributions are sorted by earliestTimeToSend, so the first time we hit this there can be no further attributions
                        // due for reporting, and nextTimeToFire is the minimum earliestTimeToSend value for any pending attribution.
                        break
                    }

                    if nextTimeToFire.value() < WTF.Seconds.infinity().value() {
                        protectedThis.startTimer(nextTimeToFire)
                    }
                }
            )
    }

    @cxx
    @implementation
    func clearExpired() {
        if !featureEnabled() {
            return
        }
        store().clearExpiredPrivateClickMeasurement()
    }

    // MARK: Token signing

    /// Loads the source's token public key for a click with an ephemeral nonce, then makes its unlinkable token and asks for
    /// its signature.
    @cxx
    @implementation
    func getTokenPublicKeyForUnattributed(_ measurement: WebCore.PrivateClickMeasurement) {
        let weakThis = weakPtrForSwift()
        // This is guaranteed to be close in time to the navigational click which makes it likely to be personally identifiable.
        getTokenPublicKey(measurement, .Source, .PersonallyIdentifiable) { measurement, publicKeyBase64URL in
            guard let protectedThis = weakThis.get() else {
                return
            }
            var measurement = measurement

            if publicKeyBase64URL.isEmpty() {
                return
            }

            if let fraudPreventionValues = protectedThis.m_fraudPreventionValuesForTesting.value {
                measurement.setSourceUnlinkableTokenValue(fraudPreventionValues.unlinkableTokenForSource)
            } else {
                #if WTF_PLATFORM_COCOA
                if let errorMessage = measurement.calculateAndUpdateSourceUnlinkableToken(publicKeyBase64URL).value {
                    WebKit.LogChannel.PrivateClickMeasurement().releaseLog
                        .info(
                            "Got the following error in calculateAndUpdateSourceUnlinkableToken(): '\(errorMessage.description, privacy: .public)'"
                        )
                    protectedThis.broadcastPrefixedConsoleMessage(.Error, errorMessage)
                    return
                }
                #endif
            }

            protectedThis.getSignedUnlinkableTokenForSource(consume measurement)
        }
    }

    /// handleAttribution()'s callback for the destination's token public key: makes the destination's unlinkable token
    /// and, without testing values, asks for its signature.
    private func didReceiveDestinationTokenPublicKey(
        _ attributionTriggerData: consuming WebCore.PCM.AttributionTriggerData,
        _ publicKeyBase64URL: WTF.String,
        sourceSite: WebCore.PCM.SourceSite,
        destinationSite: WebCore.PCM.AttributionDestinationSite,
        applicationBundleIdentifier: WTF.String
    ) {
        if publicKeyBase64URL.isEmpty() {
            WebKit.LogChannel.PrivateClickMeasurement().releaseLog.info("The public key URL was empty.")
            broadcastPrefixedConsoleMessage(.Error, "The public key URL was empty.")
            return
        }

        if let fraudPreventionValues = m_fraudPreventionValuesForTesting.value {
            attributionTriggerData.setDestinationUnlinkableTokenValue(fraudPreventionValues.unlinkableTokenForDestination)
            return
        }
        #if WTF_PLATFORM_COCOA
        let result = WebCore.PCM.updateDestinationUnlinkableToken(
            publicKeyBase64URL,
            &attributionTriggerData.destinationUnlinkableToken
        )
        guard let error = result.value else {
            let bundleIdentifier = bundleIdentifierForAttribution(applicationBundleIdentifier)
            getSignedUnlinkableTokenForDestination(
                sourceSite,
                destinationSite,
                attributionTriggerData,
                bundleIdentifier
            )
            return
        }

        let errorMessage = error.orUnknown
        WebKit.LogChannel.PrivateClickMeasurement().releaseLog
            .info(
                "Got the following error in calculateAndUpdateDestinationUnlinkableToken(): '\(errorMessage.description, privacy: .public)'"
            )
        broadcastPrefixedConsoleMessage(.Error, errorMessage)
        #endif
    }

    // MARK: Token requests

    private func getTokenPublicKey(
        _ attribution: consuming WebCore.PrivateClickMeasurement,
        _ attributionReportEndpoint: WebCore.PCM.AttributionReportEndpoint,
        _ pcmDataCarried: WebCore.PrivateClickMeasurement.PcmDataCarried,
        _ callback: @escaping (consuming WebCore.PrivateClickMeasurement, WTF.String) -> Void
    ) {
        getTokenPublicKey(
            attribution,
            attributionReportEndpoint,
            skippedWithTestingURL: .Destination,
            pcmDataCarried,
            tokenPublicKeyURL: { $0.tokenPublicKeyURL().value },
            callback
        )
    }

    private func getTokenPublicKey(
        _ attributionTriggerData: consuming WebCore.PCM.AttributionTriggerData,
        _ attributionReportEndpoint: WebCore.PCM.AttributionReportEndpoint,
        _ pcmDataCarried: WebCore.PrivateClickMeasurement.PcmDataCarried,
        _ callback: @escaping (consuming WebCore.PCM.AttributionTriggerData, WTF.String) -> Void
    ) {
        getTokenPublicKey(
            attributionTriggerData,
            attributionReportEndpoint,
            skippedWithTestingURL: .Source,
            pcmDataCarried,
            tokenPublicKeyURL: { $0.tokenPublicKeyURL().value },
            callback
        )
    }

    /// Loads the token public key for a click or its trigger data and passes it to callback.
    private func getTokenPublicKey<Payload>(
        _ payload: consuming Payload,
        _ attributionReportEndpoint: WebCore.PCM.AttributionReportEndpoint,
        skippedWithTestingURL skippedEndpoint: WebCore.PCM.AttributionReportEndpoint,
        _ pcmDataCarried: WebCore.PrivateClickMeasurement.PcmDataCarried,
        tokenPublicKeyURL payloadTokenPublicKeyURL: (borrowing Payload) -> WTF.URL?,
        _ callback: @escaping (consuming Payload, WTF.String) -> Void
    ) {
        if !featureEnabled() {
            return
        }

        var pcmDataCarried = pcmDataCarried
        let tokenPublicKeyURL: WTF.URL
        if let testURL = m_tokenPublicKeyURLForTesting.value {
            if attributionReportEndpoint == skippedEndpoint {
                return
            }
            tokenPublicKeyURL = testURL
            // FIXME(225364)
            pcmDataCarried = .NonPersonallyIdentifiable
        } else {
            guard let url = payloadTokenPublicKeyURL(payload) else {
                return
            }
            tokenPublicKeyURL = url
        }

        if tokenPublicKeyURL.isEmpty() || !tokenPublicKeyURL.isValid() {
            return
        }

        if shouldBypassPrivateRelay() {
            pcmDataCarried = .PersonallyIdentifiable
        }

        WebKit.LogChannel.PrivateClickMeasurement().releaseLog.info("About to fire a token public key request.")
        broadcastPrefixedConsoleMessage(.Log, "About to fire a token public key request.")

        let weakThis = weakPtrForSwift()
        // The loader calls the callback once; take() moves the payload out of the escaping closure.
        var payload = Optional(payload)
        let noJSON = Self.RefPtrJSONObject()
        startNetworkLoad(
            consuming: tokenPublicKeyURL,
            consuming: noJSON,
            pcmDataCarried,
            consuming: .init { response in
                guard let protectedThis = weakThis.get() else {
                    return
                }
                guard let publicKey = protectedThis.tokenPublicKey(from: response) else {
                    return
                }
                guard let payload = payload.take() else {
                    return
                }
                callback(consume payload, publicKey)
            }
        )
    }

    /// The token public key of a getTokenPublicKey() response, or nil when it has an error or no JSON; writes each check's
    /// console message.
    private func tokenPublicKey(from response: borrowing WebKit.PCM.NetworkLoader.Response) -> WTF.String? {
        if !response.errorDescription.isNull() {
            broadcastConsoleMessage(
                .Error,
                .pcmMessage("[Private Click Measurement] Received error: '", response.errorDescription, "' for token public key request.")
            )
            return nil
        }

        guard let jsonObject = response.jsonObject.get() else {
            broadcastConsoleMessage(.Error, "[Private Click Measurement] JSON response is empty for token public key request.")
            return nil
        }

        broadcastConsoleMessage(.Log, "[Private Click Measurement] Got JSON response for token public key request.")
        return jsonObject.getString(.pcmASCII("token_public_key"))
    }

    private func configureForTokenSigning(_ givenTokenSignatureURL: WTF.URL?) -> (WebCore.PrivateClickMeasurement.PcmDataCarried, WTF.URL) {
        // This is guaranteed to be close in time to a page load which can identify the user, either the source or the destination.
        guard let testURL = m_tokenSignatureURLForTesting.value else {
            return (.PersonallyIdentifiable, givenTokenSignatureURL ?? WTF.URL())
        }
        // FIXME(225364)
        return (shouldBypassPrivateRelay() ? .PersonallyIdentifiable : .NonPersonallyIdentifiable, testURL)
    }

    private func getSignatureBase64URLFromTokenSignatureResponse(_ response: borrowing WebKit.PCM.NetworkLoader.Response) -> WTF.String? {
        if !response.errorDescription.isNull() {
            broadcastConsoleMessage(
                .Error,
                .pcmMessage("[Private Click Measurement] Received error: '", response.errorDescription, "' for token signing request.")
            )
            return nil
        }

        guard let jsonObject = response.jsonObject.get() else {
            broadcastConsoleMessage(.Error, "[Private Click Measurement] JSON response is empty for token signing request.")
            return nil
        }

        let signatureBase64URL = jsonObject.getString(.pcmASCII("unlinkable_token"))
        if signatureBase64URL.isEmpty() {
            broadcastConsoleMessage(
                .Error,
                "[Private Click Measurement] JSON response doesn't have the key 'unlinkable_token' for token signing request."
            )
            return nil
        }

        return signatureBase64URL
    }

    private func getSignedUnlinkableTokenForSource(_ measurement: consuming WebCore.PrivateClickMeasurement) {
        if !featureEnabled() {
            return
        }

        let (pcmDataCarried, tokenSignatureURL) = configureForTokenSigning(measurement.tokenSignatureURL().value)

        if tokenSignatureURL.isEmpty() || !tokenSignatureURL.isValid() {
            return
        }

        WebKit.LogChannel.PrivateClickMeasurement().releaseLog
            .info("About to fire a unlinkable token signing request for the click source.")
        broadcastPrefixedConsoleMessage(.Log, "About to fire a unlinkable token signing request for the click source.")

        let weakThis = weakPtrForSwift()
        let json = Self.RefPtrJSONObject(measurement.tokenSignatureJSON().get())
        var measurement = Optional(measurement)
        startNetworkLoad(
            consuming: tokenSignatureURL,
            consuming: json,
            pcmDataCarried,
            consuming: .init { response in
                guard let protectedThis = weakThis.get() else {
                    return
                }

                guard let signatureBase64URL = protectedThis.getSignatureBase64URLFromTokenSignatureResponse(response) else {
                    return
                }
                guard var measurement = measurement.take() else {
                    return
                }

                if let fraudPreventionValues = protectedThis.m_fraudPreventionValuesForTesting.value {
                    var sourceSecretToken = WebCore.PCM.SourceSecretToken()
                    sourceSecretToken.tokenBase64URL = fraudPreventionValues.secretTokenForSource
                    sourceSecretToken.signatureBase64URL = fraudPreventionValues.signatureForSource
                    sourceSecretToken.keyIDBase64URL = fraudPreventionValues.keyIDForSource
                    measurement.setSourceSecretToken(consuming: sourceSecretToken)
                } else {
                    #if WTF_PLATFORM_COCOA
                    if let errorMessage = measurement.calculateAndUpdateSourceSecretToken(signatureBase64URL).value {
                        WebKit.LogChannel.PrivateClickMeasurement().releaseLog
                            .info(
                                "Got the following error in calculateAndUpdateSourceSecretToken(): '\(errorMessage.description, privacy: .public)'"
                            )
                        protectedThis.broadcastPrefixedConsoleMessage(.Error, errorMessage)
                        return
                    }
                    #endif
                }

                protectedThis.broadcastConsoleMessage(.Log, "[Private Click Measurement] Storing a secret token.")

                protectedThis.insertPrivateClickMeasurement(consuming: measurement, .Unattributed, consuming: WTF.VoidCompletionHandler {})
            }
        )
    }

    private func getSignedUnlinkableTokenForDestination(
        _ sourceSite: consuming WebCore.PCM.SourceSite,
        _ destinationSite: consuming WebCore.PCM.AttributionDestinationSite,
        _ attributionTriggerData: consuming WebCore.PCM.AttributionTriggerData,
        _ applicationBundleIdentifier: WTF.String
    ) {
        if !featureEnabled() {
            return
        }

        let (pcmDataCarried, tokenSignatureURL) = configureForTokenSigning(attributionTriggerData.tokenSignatureURL().value)

        if tokenSignatureURL.isEmpty() || !tokenSignatureURL.isValid() {
            return
        }

        WebKit.LogChannel.PrivateClickMeasurement().releaseLog
            .info("About to fire a unlinkable token signing request for the click destination.")
        broadcastPrefixedConsoleMessage(.Log, "About to fire a unlinkable token signing request for the click destination.")

        let weakThis = weakPtrForSwift()
        let json = Self.RefPtrJSONObject(attributionTriggerData.tokenSignatureJSON().get())
        var captured = Optional((sourceSite, destinationSite, attributionTriggerData))
        let applicationBundleIdentifier = applicationBundleIdentifier.isolatedCopy()
        startNetworkLoad(
            consuming: tokenSignatureURL,
            consuming: json,
            pcmDataCarried,
            consuming: .init { response in
                guard let protectedThis = weakThis.get() else {
                    return
                }

                guard let signatureBase64URL = protectedThis.getSignatureBase64URLFromTokenSignatureResponse(response) else {
                    return
                }

                #if WTF_PLATFORM_COCOA
                guard case (let sourceSite, let destinationSite, var attributionTriggerData)? = captured.take() else {
                    return
                }
                guard var destinationUnlinkableToken = attributionTriggerData.destinationUnlinkableToken.value else {
                    WebKit.LogChannel.PrivateClickMeasurement().releaseLog.info("Destination unlinkable token is missing.")
                    protectedThis.broadcastPrefixedConsoleMessage(.Error, "Destination unlinkable token is missing.")
                    return
                }

                // The std::optional's value imports as a copy, so the token is written back.
                let result = WebCore.PCM.updateDestinationSecretToken(
                    signatureBase64URL,
                    &destinationUnlinkableToken,
                    &attributionTriggerData.destinationSecretToken
                )
                attributionTriggerData.destinationUnlinkableToken = .init(destinationUnlinkableToken)
                if let error = result.value {
                    let errorMessage = error.orUnknown
                    WebKit.LogChannel.PrivateClickMeasurement().releaseLog
                        .info(
                            "Got the following error in calculateAndUpdateSourceSecretToken(): '\(errorMessage.description, privacy: .public)'"
                        )
                    protectedThis.broadcastPrefixedConsoleMessage(.Error, errorMessage)
                    return
                }

                protectedThis.broadcastConsoleMessage(.Log, "[Private Click Measurement] Storing a secret token.")

                let bundleIdentifier = protectedThis.bundleIdentifierForAttribution(applicationBundleIdentifier)
                protectedThis.attribute(sourceSite, destinationSite, attributionTriggerData, bundleIdentifier)
                #endif
            }
        )
    }

    // MARK: Attribution reports

    private func attribute(
        _ sourceSite: consuming WebCore.PCM.SourceSite,
        _ destinationSite: consuming WebCore.PCM.AttributionDestinationSite,
        _ attributionTriggerData: consuming WebCore.PCM.AttributionTriggerData,
        _ applicationBundleIdentifier: WTF.String
    ) {
        if !featureEnabled() {
            return
        }

        let weakThis = weakPtrForSwift()
        let isRunningLayoutTest: WebCore.PrivateClickMeasurement.IsRunningLayoutTest = m_isRunningTest ? .Yes : .No
        store()
            .attributePrivateClickMeasurement(
                consuming: sourceSite,
                consuming: destinationSite,
                applicationBundleIdentifier,
                consuming: attributionTriggerData,
                isRunningLayoutTest,
                consuming: .init { (result: WebKit.PCM.AttributionResult) in
                    guard let protectedThis = weakThis.get() else {
                        return
                    }

                    guard var attributionSecondsUntilSendData = result.attributionSecondsUntilSendData.value else {
                        return
                    }

                    if protectedThis.debugModeEnabled() {
                        for message in result.debugInfo.messages {
                            protectedThis.broadcastConsoleMessage(message.messageLevel, message.message)
                        }
                    }

                    if attributionSecondsUntilSendData.hasValidSecondsUntilSendValues() {
                        guard var minSecondsUntilSend = attributionSecondsUntilSendData.minSecondsUntilSend().value else {
                            assertionFailure()
                            return
                        }

                        if protectedThis.firePendingAttributionRequestsTimerFiresBefore(minSecondsUntilSend) {
                            return
                        }

                        if protectedThis.debugModeEnabled() {
                            protectedThis.broadcastConsoleMessage(
                                .Log,
                                "[Private Click Measurement] Setting timer for firing attribution request to the debug mode timeout of \(Self.debugModeSecondsUntilSend.numberDescription) seconds where the regular timeout would have been \(minSecondsUntilSend.numberDescription) seconds."
                            )
                            minSecondsUntilSend = Self.debugModeSecondsUntilSend
                        } else {
                            protectedThis.broadcastConsoleMessage(
                                .Log,
                                "[Private Click Measurement] Setting timer for firing attribution request to the timeout of \(minSecondsUntilSend.numberDescription) seconds."
                            )
                        }

                        protectedThis.startTimer(minSecondsUntilSend)
                    }
                }
            )
    }

    private func fireConversionRequest(
        _ attribution: WebCore.PrivateClickMeasurement,
        _ attributionReportEndpoint: WebCore.PCM.AttributionReportEndpoint
    ) {
        guard featureEnabled(), let triggerData = attribution.attributionTriggerDataCopy() else {
            return
        }

        let hasSourceSecretToken = attribution.sourceSecretTokenCopy().value != nil
        if !hasSourceSecretToken && triggerData.destinationSecretToken.value == nil {
            fireConversionRequestImpl(attribution, attributionReportEndpoint)
            return
        }

        let weakThis = weakPtrForSwift()
        // This happens out of webpage context and with a long delay and is thus unlikely to be personally identifiable.
        if hasSourceSecretToken {
            getTokenPublicKey(attribution, attributionReportEndpoint, .NonPersonallyIdentifiable) {
                attribution,
                publicKeyBase64URL in
                guard let protectedThis = weakThis.get() else {
                    return
                }

                guard let sourceSecretToken = attribution.sourceSecretTokenCopy().value,
                    Self.publicKey(publicKeyBase64URL, matches: sourceSecretToken.keyIDBase64URL)
                else {
                    return
                }

                guard let triggerData = attribution.attributionTriggerDataCopy() else {
                    return
                }

                if triggerData.destinationSecretToken.value != nil {
                    protectedThis.getDestinationTokenPublicKeyAndFire(consume attribution, attributionReportEndpoint)
                    return
                }

                protectedThis.fireConversionRequestImpl(attribution, attributionReportEndpoint)
            }
            return
        }

        getDestinationTokenPublicKeyAndFire(attribution, attributionReportEndpoint)
    }

    /// Fires the attribution request once the destination's token public key matches its secret token's key ID.
    private func getDestinationTokenPublicKeyAndFire(
        _ attribution: consuming WebCore.PrivateClickMeasurement,
        _ attributionReportEndpoint: WebCore.PCM.AttributionReportEndpoint
    ) {
        let weakThis = weakPtrForSwift()
        getTokenPublicKey(consume attribution, attributionReportEndpoint, .NonPersonallyIdentifiable) {
            attribution,
            publicKeyBase64URL in
            guard let protectedThis = weakThis.get() else {
                return
            }

            guard let destinationSecretToken = attribution.attributionTriggerDataCopy()?.destinationSecretToken.value,
                Self.publicKey(publicKeyBase64URL, matches: destinationSecretToken.keyIDBase64URL)
            else {
                return
            }

            protectedThis.fireConversionRequestImpl(attribution, attributionReportEndpoint)
        }
    }

    private func fireConversionRequestImpl(
        _ attribution: WebCore.PrivateClickMeasurement,
        _ attributionReportEndpoint: WebCore.PCM.AttributionReportEndpoint
    ) {
        let attributionURL: WTF.URL
        let testConfig = m_attributionReportTestConfig.value
        switch attributionReportEndpoint {
        case .Source:
            attributionURL = testConfig?.attributionReportClickSourceURL ?? attribution.attributionReportClickSourceURL()
        case .Destination:
            attributionURL = testConfig?.attributionReportClickDestinationURL ?? attribution.attributionReportClickDestinationURL()
        @unknown default:
            return
        }

        if attributionURL.isEmpty() || !attributionURL.isValid() {
            return
        }

        let pcmDataCarried: WebCore.PrivateClickMeasurement.PcmDataCarried =
            shouldBypassPrivateRelay() ? .PersonallyIdentifiable : .NonPersonallyIdentifiable

        if debugModeEnabled() {
            let message =
                shouldBypassPrivateRelay()
                ? "[Private Click Measurement] Private Relay is not required for the attribution request because Debug Mode is enabled."
                : "[Private Click Measurement] Private Relay is required for the attribution request."
            broadcastConsoleMessage(.Log, message)
        }

        WebKit.LogChannel.PrivateClickMeasurement().releaseLog.info("About to fire an attribution request.")
        broadcastPrefixedConsoleMessage(.Log, "About to fire an attribution request.")

        let weakThis = weakPtrForSwift()
        startNetworkLoad(
            consuming: attributionURL,
            consuming: Self.RefPtrJSONObject(attribution.attributionReportJSON().get()),
            pcmDataCarried,
            consuming: .init { response in
                guard let protectedThis = weakThis.get() else {
                    return
                }

                if !response.errorDescription.isNull() {
                    protectedThis.broadcastConsoleMessage(
                        .Error,
                        .pcmMessage(
                            "[Private Click Measurement] Received error: '",
                            response.errorDescription,
                            "' for ad click attribution request."
                        )
                    )
                }
            }
        )
    }

    private func clearSentAttribution(
        _ sentConversion: consuming WebCore.PrivateClickMeasurement,
        _ attributionReportEndpoint: WebCore.PCM.AttributionReportEndpoint
    ) {
        if !featureEnabled() {
            return
        }

        store().clearSentAttribution(consuming: sentConversion, attributionReportEndpoint)
    }

    /// Writes a message of ASCII text (literals and numbers) to the console.
    private func broadcastConsoleMessage(_ level: JSC.MessageLevel, _ message: Swift.String) {
        broadcastConsoleMessage(level, .pcmASCII(message))
    }

    /// Writes the message, with the feature's prefix, to the console.
    private func broadcastPrefixedConsoleMessage(_ level: JSC.MessageLevel, _ message: Swift.String) {
        broadcastConsoleMessage(level, "[Private Click Measurement] \(message)")
    }

    /// Writes the error message, with the feature's prefix, to the console.
    private func broadcastPrefixedConsoleMessage(_ level: JSC.MessageLevel, _ message: borrowing WTF.String) {
        broadcastConsoleMessage(level, .pcmMessage("[Private Click Measurement] ", message, ""))
    }

    /// The testing override of the application bundle identifier if one is set, or applicationBundleIdentifier.
    private func bundleIdentifierForAttribution(_ applicationBundleIdentifier: WTF.String) -> WTF.String {
        m_privateClickMeasurementAppBundleIDForTesting.value ?? applicationBundleIdentifier
    }
}

extension WebCore.PrivateClickMeasurement {
    /// A copy of the trigger data; its const std::optional<T>& accessor imports as UnsafePointer.
    fileprivate func attributionTriggerDataCopy() -> WebCore.PCM.AttributionTriggerData? {
        var triggerData = WebCore.PrivateClickMeasurement.OptionalAttributionTriggerData()
        copyAttributionTriggerData(&triggerData)
        return triggerData.value
    }
}

extension WebKit.PrivateClickMeasurementManager {
    private static let debugModeSecondsUntilSend = WTF.Seconds(10)

    private func randomlyBetweenFifteenAndThirtyMinutes() -> WTF.Seconds {
        if m_isRunningTest {
            return WTF.Seconds(0)
        }
        if debugModeEnabled() {
            return Self.debugModeSecondsUntilSend
        }
        // Swift cannot name the explicit specialization cryptographicallyRandomNumber<unsigned>(); this recovers its
        // UInt32 from cryptographicallyRandomUnitInterval(), which is that number / (UInt32.max + 1).
        let random = UInt32(WTF.cryptographicallyRandomUnitInterval() * (Double(UInt32.max) + 1))
        return WTF.Seconds(15 * 60 + Double(random % 900))
    }

    /// Whether the public key's SHA-256 key ID is keyIDBase64URL; false when the key does not decode.
    fileprivate static func publicKey(_ publicKeyBase64URL: WTF.String, matches keyIDBase64URL: WTF.String) -> Bool {
        guard let keyID = keyIDForPublicKey(publicKeyBase64URL).value else {
            return false
        }
        return keyID == keyIDBase64URL
    }
}

extension WTF.Seconds {
    /// The lesser of the two; self when they are equal.
    fileprivate func minimum(_ other: WTF.Seconds) -> WTF.Seconds {
        other.value() < value() ? other : self
    }

    /// String::number() of the seconds, for a message.
    fileprivate var numberDescription: Swift.String {
        WTF.String.number(seconds()).description
    }
}

extension WTF.String {
    /// The error message, or "Unknown" when it is empty.
    fileprivate var orUnknown: WTF.String {
        isEmpty() ? .pcmASCII("Unknown") : self
    }

    /// makeString() of `prefix`, `string` and `suffix`, ASCII text around a String: 8-bit unless the String is 16-bit.
    fileprivate static func pcmMessage(_ prefix: Swift.String, _ string: borrowing WTF.String, _ suffix: Swift.String) -> WTF.String {
        var codeUnits = Array(prefix.utf16)
        for index in 0..<string.length() {
            codeUnits.append(string[index])
        }
        codeUnits.append(contentsOf: suffix.utf16)
        if string.is8Bit() {
            let characters = codeUnits.map { UInt8(truncatingIfNeeded: $0) }
            return WTF.makeStringFromLatin1Characters(characters.span)
        }
        return WTF.makeStringFromUTF16Characters(codeUnits.span)
    }
}
