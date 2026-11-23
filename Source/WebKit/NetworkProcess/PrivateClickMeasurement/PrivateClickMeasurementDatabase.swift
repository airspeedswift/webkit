// Copyright (C) 2021 Apple Inc. All rights reserved.
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

import WebKit_Internal
import os
import wtf

extension WTF.String {
    /// A WTF.String of an ASCII string, whose UTF-8 bytes are its Latin-1 characters.
    static func pcmASCII(_ string: Swift.String) -> WTF.String {
        WTF.makeStringFromLatin1Characters(string.utf8.span)
    }
}

extension WebKit.PCM.DebugInfo.Message {
    /// A DebugInfo message of ASCII text (literals and decimal integers).
    fileprivate static func ascii(_ level: JSC.MessageLevel, _ message: Swift.String) -> Self {
        Self(messageLevel: level, message: .pcmASCII(message))
    }
}

extension WebKit.PCM.Database.AttributionOutcome {
    /// No attribution is scheduled; the outcome carries only the debug messages.
    fileprivate static func unscheduled(_ debugInfo: consuming WebKit.PCM.DebugInfo) -> Self {
        .init(first: .init(), second: consume debugInfo)
    }
}

extension WebKit.PCM.Database {
    @cxx
    @implementation
    func attributePrivateClickMeasurement(
        _ sourceSite: WebCore.PCM.SourceSite,
        _ destinationSite: WebCore.PCM.AttributionDestinationSite,
        _ applicationBundleIdentifier: WTF.String,
        _ attributionTriggerData: WebCore.PCM.AttributionTriggerData,
        _ isRunningTest: WebCore.PrivateClickMeasurement.IsRunningLayoutTest
    ) -> WebKit.PCM.Database.AttributionOutcome {
        assert(!WTF.RunLoop.isMain())

        // We should always clear expired clicks from the database before scheduling an attribution.
        clearExpiredPrivateClickMeasurement()
        if !attributionTriggerData.isValid() {
            WebKit.LogChannel.PrivateClickMeasurement().releaseLog.info("Got an invalid attribution.")
            var debugInfo = WebKit.PCM.DebugInfo()
            debugInfo.messages.append(consuming: .ascii(.Error, "[Private Click Measurement] Got an invalid attribution."))
            return .unscheduled(consume debugInfo)
        }

        var debugInfo = WebKit.PCM.DebugInfo()
        let data = attributionTriggerData.data
        let priority = attributionTriggerData.priority
        WebKit.LogChannel.PrivateClickMeasurement().releaseLog
            .info(
                "Got an attribution with attribution trigger data: \(data, privacy: .public) and priority: \(priority, privacy: .public)."
            )
        debugInfo.messages.append(
            consuming: .ascii(
                .Info,
                "[Private Click Measurement] Got an attribution with attribution trigger data: '\(data)' and priority: '\(priority)'."
            )
        )

        var secondsUntilSend = WebCore.PCM.AttributionSecondsUntilSendData()

        var foundUnattributed = WebKit.PCM.Database.OptionalPrivateClickMeasurement()
        var foundAttributed = WebKit.PCM.Database.OptionalPrivateClickMeasurement()
        findPrivateClickMeasurement(sourceSite, destinationSite, applicationBundleIdentifier, &foundUnattributed, &foundAttributed)
        if var unattributed = foundUnattributed.value {
            // Always convert the pending attribution and remove it from the unattributed map.
            removeUnattributed(&unattributed)
            secondsUntilSend = unattributed.attributeAndGetEarliestTimeToSend(consuming: attributionTriggerData, isRunningTest)

            // We should always have a valid secondsUntilSend value for an unattributed measurement because there can be no previous attribution with a higher priority.
            if !secondsUntilSend.hasValidSecondsUntilSendValues() {
                assertionFailure()
                return .unscheduled(consume debugInfo)
            }

            WebKit.LogChannel.PrivateClickMeasurement().releaseLog
                .info(
                    "Converted a stored ad click with attribution trigger data: \(data, privacy: .public) and priority: \(priority, privacy: .public)."
                )
            debugInfo.messages.append(
                consuming: .ascii(
                    .Info,
                    "[Private Click Measurement] Converted a stored ad click with attribution trigger data: '\(data)' and priority: '\(priority)'."
                )
            )

            // If there is no previous attribution, or the new attribution has higher priority, insert/update the database.
            if foundAttributed.value.map({ unattributed.hasHigherPriorityThan($0) }) ?? true {
                insertPrivateClickMeasurement(consume unattributed, .Attributed)

                WebKit.LogChannel.PrivateClickMeasurement().releaseLog
                    .info(
                        "Replaced a previously converted ad click with a new one with attribution data: \(data, privacy: .public) and priority: \(priority, privacy: .public) because it had higher priority."
                    )
                debugInfo.messages.append(
                    consuming: .ascii(
                        .Info,
                        "[Private Click Measurement] Replaced a previously converted ad click with a new one with attribution trigger data: '\(data)' and priority: '\(priority)' because it had higher priority."
                    )
                )
            }
        } else if var attributed = foundAttributed.value {
            // If we have no new attribution, re-attribute the old one to respect the new priority, but only if this report has
            // not been sent to the source or destination site yet.
            if !attributed.hasPreviouslyBeenReported() {
                var reattributedSecondsUntilSend = attributed.attributeAndGetEarliestTimeToSend(
                    consuming: attributionTriggerData,
                    isRunningTest
                )
                if !reattributedSecondsUntilSend.hasValidSecondsUntilSendValues() {
                    return .unscheduled(consume debugInfo)
                }

                insertPrivateClickMeasurement(consume attributed, .Attributed)

                WebKit.LogChannel.PrivateClickMeasurement().releaseLog
                    .info(
                        "Re-converted an ad click with a new one with attribution trigger data: \(data, privacy: .public) and priority: \(priority, privacy: .public) because it had higher priority."
                    )
                debugInfo.messages.append(
                    consuming: .ascii(
                        .Info,
                        "[Private Click Measurement] Re-converted an ad click with a new one with attribution trigger data: '\(data)' and priority: '\(priority)'' because it had higher priority."
                    )
                )
            }
        }

        if !secondsUntilSend.hasValidSecondsUntilSendValues() {
            return .unscheduled(consume debugInfo)
        }

        return .init(first: .init(secondsUntilSend), second: consume debugInfo)
    }

    @cxx
    @implementation
    func clearSentAttribution(
        _ attribution: WebCore.PrivateClickMeasurement,
        _ attributionReportEndpoint: WebCore.PCM.AttributionReportEndpoint
    ) {
        assert(!WTF.RunLoop.isMain())
        let timesToSend = earliestTimesToSend(attribution)
        let sourceEarliestTimeToSend = timesToSend.first.value
        let destinationEarliestTimeToSend = timesToSend.second.value

        let sourceSiteDomainID = domainID(attribution.sourceSiteCopy().registrableDomain).value
        let destinationSiteDomainID = domainID(attribution.destinationSiteCopy().registrableDomain).value
        let sourceApplicationBundleID = attribution.sourceApplicationBundleIDCopy()

        guard let sourceSiteDomainID, let destinationSiteDomainID else {
            return
        }

        let otherReportIsPending: Bool
        switch attributionReportEndpoint {
        case .Source:
            guard sourceEarliestTimeToSend != nil else {
                assertionFailure()
                return
            }
            markReportAsSentToSource(sourceSiteDomainID, destinationSiteDomainID, sourceApplicationBundleID)
            otherReportIsPending = destinationEarliestTimeToSend != nil
        case .Destination:
            guard destinationEarliestTimeToSend != nil else {
                assertionFailure()
                return
            }
            markReportAsSentToDestination(sourceSiteDomainID, destinationSiteDomainID, sourceApplicationBundleID)
            otherReportIsPending = sourceEarliestTimeToSend != nil
        @unknown default:
            return
        }

        // Don't clear the attribute from the database unless it has been reported both to the source and destination site.
        guard !otherReportIsPending else {
            return
        }

        clearAttributedPrivateClickMeasurement(sourceSiteDomainID, destinationSiteDomainID, sourceApplicationBundleID)
    }
}
