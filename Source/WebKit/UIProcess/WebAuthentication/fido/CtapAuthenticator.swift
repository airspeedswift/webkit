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

#if ENABLE_WEB_AUTHN

import CryptoKit
import WebCore_Private
import WebKit_Internal
import wtf

// The CTAP2 authenticator: makeCredential and getAssertion over a CtapDriver, with the PIN and hmac-secret steps.
// https://fidoalliance.org/specs/fido-v2.0-ps-20190130/fido-client-to-authenticator-protocol-v2.0-ps-20190130.html
//
// Each step sends one command and goes on in the next step when the driver answers. The answers hold the
// authenticator weakly: a step whose authenticator is gone does nothing.

extension WebKit.CtapAuthenticator {
    @cxx @implementation
    override func makeCredential() {
        log("makeCredential")
        assert(!m_isDowngraded)

        let options = creationOptions()
        if options.excludeCredentials.size() > 1 {
            makeBatches(options.excludeCredentials)
            assert(!m_batches.isEmpty())
            if m_batches.isEmpty() {
                continueMakeCredentialAfterCheckExcludedCredentials()
                return
            }
            m_currentBatch = 0
            let command = fido.encodeSilentGetAssertion(
                options.rp.id, requestHash(), m_batches[m_currentBatch], pinParametersIfAuthorized()
            )
            transact(command) { this, data in
                this.continueSilentlyCheckCredentials(data, .makeCredential)
            }
        } else {
            continueMakeCredentialAfterCheckExcludedCredentials()
        }
    }

    @cxx @implementation
    override func getAssertion() {
        log("getAssertion")

        let options = requestOptions()
        if options.allowCredentials.size() > 1 {
            makeBatches(options.allowCredentials)
            assert(!m_batches.isEmpty())
            if m_batches.isEmpty() {
                continueGetAssertionAfterCheckAllowCredentials()
                return
            }
            m_currentBatch = 0
            let command = fido.encodeSilentGetAssertion(
                options.rpId, requestHash(), m_batches[m_currentBatch], pinParametersIfAuthorized()
            )
            transact(command) { this, data in
                this.continueSilentlyCheckCredentials(data, .getAssertion)
            }
        } else if options.allowCredentials.size() == 1 && canDowngradeToU2f() {
            let command = fido.encodeSilentGetAssertion(
                options.rpId, requestHash(), options.allowCredentials, pinParametersIfAuthorized()
            )
            transact(command) { this, data in
                let error = fido.getResponseCode(data)
                if error == .ctap2ErrNoCredentials && this.tryDowngrade() {
                    return
                }
                this.continueGetAssertionAfterCheckAllowCredentials()
            }
        } else {
            continueGetAssertionAfterCheckAllowCredentials()
        }
    }
}

// What the silent credential check goes on with when it is done.
private enum SilentCheckCompletion {
    case makeCredential
    case getAssertion
}

// The PIN status a CTAP error stands for.
private func toStatus(_ error: fido.CtapDeviceResponseCode) -> WebKit.WebAuthenticationStatus {
    switch error {
    case .ctap2ErrPinAuthInvalid, .ctap2ErrPinInvalid:
        return .PinInvalid
    case .ctap2ErrPinAuthBlocked:
        return .PinAuthBlocked
    case .ctap2ErrPinBlocked:
        return .PinBlocked
    case .success:
        return .PINSuccessful
    default:
        assertionFailure()
        return .PinInvalid
    }
}

private func isPinError(_ error: fido.CtapDeviceResponseCode) -> Bool {
    switch error {
    case .ctap2ErrPinAuthInvalid, .ctap2ErrPinAuthBlocked, .ctap2ErrPinInvalid, .ctap2ErrPinBlocked,
        .ctap2ErrPinRequired:
        return true
    default:
        return false
    }
}

private func isTerminalPinError(_ error: fido.CtapDeviceResponseCode) -> Bool {
    switch error {
    case .ctap2ErrPinAuthBlocked, .ctap2ErrPinBlocked, .ctap2ErrUserPresenceRequired:
        return true
    default:
        return false
    }
}

// The PRF input as the spec hashes it: SHA-256("WebAuthn PRF" || 0x00 || input).
private func hashPRFInput(_ input: WebCore.BufferSource) -> cbor.CBORValue.BinaryValue {
    var hasher = SHA256()
    hasher.update(data: Array("WebAuthn PRF".utf8))
    hasher.update(data: [UInt8(0)])
    hasher.update(data: bufferSourceBytes(input))
    var hash = cbor.CBORValue.BinaryValue()
    for byte in hasher.finalize() {
        hash.append(consuming: byte)
    }
    return hash
}

private func errorCodeMessage(_ error: fido.CtapDeviceResponseCode) -> WTF.String {
    webAuthnString("Unknown internal error. Error code: \(error.rawValue)")
}

// WTF::String equality compares code units; Swift's == compares canonical equivalence.
private func sameCodeUnits(_ a: Swift.String, _ b: Swift.String) -> Bool {
    let aUTF8 = a.utf8
    let bUTF8 = b.utf8
    let aBytes: Span<UInt8> = aUTF8.span
    let bBytes: Span<UInt8> = bUTF8.span
    if aBytes.count != bBytes.count {
        return false
    }
    for index in aBytes.indices where aBytes[index] != bBytes[index] {
        return false
    }
    return true
}

private func contains(_ strings: fido.StringVector, _ literal: Swift.String) -> Bool {
    for string in strings where sameCodeUnits(string.description, literal) {
        return true
    }
    return false
}

extension WebKit.CtapAuthenticator {
    // CTAP_RELEASE_LOG: the step's name is public, the details private.
    private func log(_ step: Swift.String, _ details: Swift.String = "") {
        WebKit.LogChannel.WebAuthn().releaseLog.log(
            "[aaguid=\(self.aaguidForDebugging()), transport=\(self.transportName().description)] - CtapAuthenticator::\(step, privacy: .public)\(details)"
        )
    }

    // Sends a command; the answer goes to `step` if the authenticator is still there.
    private func transact(
        _ command: cbor.CBORValue.BinaryValue,
        _ step: @escaping (WebKit.CtapAuthenticator, cbor.CBORValue.BinaryValue) -> Void
    ) {
        let weakThis = WebKit.WeakPtrCtapAuthenticator(self)
        let callback = WebKit.CtapDriver.ResponseCallback { (data: cbor.CBORValue.BinaryValue) in
            if let this = weakThis.get() {
                step(this, data)
            }
        }
        driverForSubclass().transact(consuming: command, consuming: callback)
    }

    // m_info as plain fields: the move-only AuthenticatorGetInfoResponse's accessors return references, which
    // Swift does not import. markClientPinSet changes m_info, so each use reads it again.
    private var info: fido.GetInfoResponseFields { fido.getInfoResponseFields(m_info) }

    // Vector's C++ contains() hides Sequence.contains and cannot infer its template argument from `.x`, so these loop.
    private func hasVersion(_ version: fido.ProtocolVersion) -> Bool {
        for candidate in info.versions where candidate == version {
            return true
        }
        return false
    }

    // batchesForCredentials: the credentials in batches the authenticator takes, without IDs it cannot take.
    private func makeBatches(_ credentials: fido.CredentialDescriptorVector) {
        var maxBatchSize: UInt32 = 1
        let info = self.info
        if let maxCredentialCountInList = Optional(fromCxx: info.maxCredentialCountInList) {
            maxBatchSize = maxCredentialCountInList
        }
        let maxCredentialIDLength = Optional(fromCxx: info.maxCredentialIDLength)
        m_batches = .init()
        for credential in credentials {
            if let maxCredentialIDLength, credential.id.byteLength() > Int(maxCredentialIDLength) {
                continue
            }
            if m_batches.isEmpty() || m_batches[m_batches.size() - 1].size() >= Int(maxBatchSize) {
                m_batches.append(consuming: fido.CredentialDescriptorVector())
            }
            m_batches[m_batches.size() - 1].append(consuming: credential)
        }
    }

    private func pinParameters() -> fido.PinParameters {
        fido.PinParameters(protocol: Int32(selectPinProtocol().rawValue), auth: m_pinAuth)
    }

    private func pinParametersIfAuthorized() -> fido.OptionalPinParameters {
        if m_pinAuth.isEmpty() {
            return fido.OptionalPinParameters()
        }
        return fido.OptionalPinParameters(pinParameters())
    }

    private func finishSilentCheck(_ completion: SilentCheckCompletion, _ found: Bool) {
        switch completion {
        case .makeCredential:
            continueMakeCredentialAfterCheckExcludedCredentials(includeCurrentBatch: found)
        case .getAssertion:
            if !found && tryDowngrade() {
                return
            }
            continueGetAssertionAfterCheckAllowCredentials()
        }
    }

    private func continueSilentlyCheckCredentials(_ data: cbor.CBORValue.BinaryValue, _ completion: SilentCheckCompletion) {
        let error = fido.getResponseCode(data)
        log("continueSilentlyCheckCredentials: Got error code: \(error.rawValue) from authenticator.")

        if error == .success {
            finishSilentCheck(completion, true)
            return
        }
        if error == .ctap2ErrNoCredentials {
            if m_currentBatch + 1 >= m_batches.size() {
                finishSilentCheck(completion, false)
                return
            }
            m_currentBatch += 1
            // Never true after the check above.
            if m_currentBatch >= m_batches.size() {
                continueMakeCredentialAfterCheckExcludedCredentials()
                return
            }
        }

        if isTerminalPinError(error) {
            log("continueSilentlyCheckCredentials: Terminal error - notifying UI")
            updateObserverStatus(.PinAuthBlocked)
            finishSilentCheck(completion, false)
            return
        }
        if isPinError(error) {
            if !m_pinAuth.isEmpty() {
                updateObserverStatus(toStatus(error))
            }
            if tryRestartPin(error) {
                return
            }
        }

        // The answer is parsed and the result dropped.
        _ = readGetAssertionResponse(data)
        let pinParameters = pinParametersIfAuthorized()
        let command: cbor.CBORValue.BinaryValue
        if isCreationRequest() {
            command = fido.encodeSilentGetAssertion(
                creationOptions().rp.id, requestHash(), m_batches[m_currentBatch], pinParameters
            )
        } else {
            command = fido.encodeSilentGetAssertion(
                requestOptions().rpId, requestHash(), m_batches[m_currentBatch], pinParameters
            )
        }

        // When the authenticator is gone, the completion finds it gone too and does nothing.
        transact(command) { this, data in
            this.continueSilentlyCheckCredentials(data, completion)
        }
    }

    private func continueMakeCredentialAfterCheckExcludedCredentials(includeCurrentBatch: Bool = false) {
        let options = creationOptions()
        var overrideExcludeCredentials = fido.OptionalCredentialDescriptorVector()
        if includeCurrentBatch {
            assert(m_currentBatch < m_batches.size())
            overrideExcludeCredentials = fido.OptionalCredentialDescriptorVector(m_batches[m_currentBatch])
        } else if !m_batches.isEmpty() {
            overrideExcludeCredentials = fido.OptionalCredentialDescriptorVector(fido.CredentialDescriptorVector())
        }
        let internalUVAvailability = info.userVerificationAvailability
        var residentKeyAvailability = info.residentKeyAvailability
        let selection = Optional(fromCxx: options.authenticatorSelection)
        if let selection, selection.userVerification == .Required, !isUVSetup() {
            performAuthenticatorSelectionForSetupPin()
            return
        }
        var authenticatorSupportedExtensions = fido.StringVector()
        if let extensions = Optional(fromCxx: info.extensions) {
            authenticatorSupportedExtensions = extensions
        }
        if m_isKeyStoreFull {
            if let selection,
                selection.requireResidentKey || Optional(fromCxx: selection.residentKey) == .Required
            {
                observerStatusUpdatedOrCrash(.KeyStoreFull)
                return
            }
            residentKeyAvailability = .notSupported
        }

        let extensions = Optional(fromCxx: options.extensions)
        let prf = extensions.flatMap { Optional(fromCxx: $0.prf) }
        let needsPRF = prf != nil
        log(
            "continueMakeCredentialAfterCheckExcludedCredentials: PRF check - extensions=\(extensions != nil ? 1 : 0), prf=\(needsPRF ? 1 : 0)"
        )
        let supportsHmacSecret = contains(authenticatorSupportedExtensions, "hmac-secret")
        var hmacSecretParameters = fido.OptionalHmacSecretParameters()
        if let prf, supportsHmacSecret, Optional(fromCxx: prf.eval) != nil {
            log(
                "continueMakeCredentialAfterCheckExcludedCredentials: PRF extension found with eval, preparing hmac-secret"
            )
            let supportsHmacSecretMc = contains(authenticatorSupportedExtensions, "hmac-secret-mc")
            if supportsHmacSecretMc {
                if let parameters = prepareHmacSecretParameters(prf, nil) {
                    hmacSecretParameters = fido.OptionalHmacSecretParameters(parameters)
                    log("continueMakeCredentialAfterCheckExcludedCredentials: PRF hmac-secret-mc parameters prepared")
                } else {
                    log(
                        "continueMakeCredentialAfterCheckExcludedCredentials: PRF hmac-secret-mc parameters failed to prepare"
                    )
                }
            } else {
                log("continueMakeCredentialAfterCheckExcludedCredentials: Authenticator doesn't support hmac-secret-mc")
            }
        } else if let prf {
            log(
                "continueMakeCredentialAfterCheckExcludedCredentials: PRF requested but conditions not met - supportsHmacSecret=\(supportsHmacSecret ? 1 : 0), hasEval=\(Optional(fromCxx: prf.eval) != nil ? 1 : 0)"
            )
        }

        let effectiveUVRequirement: WebCore.UserVerificationRequirement =
            needsPRF && supportsHmacSecret ? .Required : (selection?.userVerification ?? .Discouraged)

        let command: cbor.CBORValue.BinaryValue
        if internalUVAvailability == .supportedAndConfigured && effectiveUVRequirement != .Discouraged
            && m_pinAuth.isEmpty()
        {
            command = fido.encodeMakeCredentialRequestAsCBOR(
                requestHash(), options, internalUVAvailability, effectiveUVRequirement, residentKeyAvailability,
                authenticatorSupportedExtensions, fido.OptionalPinParameters(), info.algorithms,
                overrideExcludeCredentials, hmacSecretParameters
            )
        } else if info.clientPinAvailability == .supportedAndPinSet
            && effectiveUVRequirement != .Discouraged
        {
            command = fido.encodeMakeCredentialRequestAsCBOR(
                requestHash(), options, internalUVAvailability, effectiveUVRequirement, residentKeyAvailability,
                authenticatorSupportedExtensions, fido.OptionalPinParameters(pinParameters()), info.algorithms,
                overrideExcludeCredentials, hmacSecretParameters
            )
        } else {
            command = fido.encodeMakeCredentialRequestAsCBOR(
                requestHash(), options, internalUVAvailability, effectiveUVRequirement, residentKeyAvailability,
                authenticatorSupportedExtensions, fido.OptionalPinParameters(), info.algorithms,
                overrideExcludeCredentials, hmacSecretParameters
            )
        }
        log("makeCredential: Sending ", base64String(command))
        if let maxMsgSize = Optional(fromCxx: info.maxMsgSize), command.size() >= Int(maxMsgSize) {
            log("CtapAuthenticator::makeCredential cmdSize = \(command.size()) maxMsgSize = \(maxMsgSize)")
        }
        transact(command) { this, data in
            this.continueMakeCredentialAfterResponseReceived(data)
        }
    }

    private func continueMakeCredentialAfterResponseReceived(_ data: cbor.CBORValue.BinaryValue) {
        let error = fido.getResponseCode(data)
        log("continueMakeCredentialAfterResponseReceived: Got error code: \(error.rawValue) from authenticator.")
        let parsed = fido.readCTAPMakeCredentialResponse(
            data, .CrossPlatform, transports(), creationOptions().attestation, m_hmacSecretSharedKey,
            m_hmacSecretProtocol
        )
        guard let response = parsed.get() else {
            log("makeCredential: Failed to parse response ", base64String(data))

            if error == .ctap2ErrActionTimeout {
                restartMakeCredential()
                return
            }

            if error == .ctap2ErrCredentialExcluded {
                respondWithError(
                    .InvalidStateError,
                    webAuthnString(
                        "At least one credential matches an entry of the excludeCredentials list in the authenticator."
                    )
                )
                return
            }
            if error == .ctap2ErrKeyStoreFull {
                let selection = Optional(fromCxx: creationOptions().authenticatorSelection)
                if let selection,
                    selection.requireResidentKey || Optional(fromCxx: selection.residentKey) == .Required
                {
                    observerStatusUpdatedOrCrash(.KeyStoreFull)
                } else if !m_isKeyStoreFull {
                    m_isKeyStoreFull = true
                    restartMakeCredential()
                }
                return
            }

            if isTerminalPinError(error) {
                log("continueMakeCredentialAfterResponseReceived: Terminal PIN error - notifying UI")
                updateObserverStatus(.PinAuthBlocked)
                return
            }

            if isPinError(error) {
                // Skip the very first command, which acts as a wink.
                if !m_pinAuth.isEmpty() {
                    updateObserverStatus(toStatus(error))
                }
                if tryRestartPin(error) {
                    return
                }
            }

            respondWithError(.UnknownError, errorCodeMessage(error))
            return
        }
        let options = creationOptions()

        clearHmacSecretRequest()

        if let extensions = Optional(fromCxx: options.extensions), Optional(fromCxx: extensions.credProps) != nil {
            var extensionOutputs = response.extensions()

            let rkSupported = info.residentKeyAvailability == .supported
            var rkRequested = false
            if let selection = Optional(fromCxx: options.authenticatorSelection) {
                let residentKey = Optional(fromCxx: selection.residentKey)
                rkRequested = (residentKey != nil && residentKey != .Discouraged) || selection.requireResidentKey
            }
            extensionOutputs.credProps = .init(
                WebCore.CredentialPropertiesOutput(rk: rkSupported && rkRequested && !m_isKeyStoreFull)
            )
            response.setExtensions(consuming: extensionOutputs)
        }
        respondWithResponse(response)
    }

    private func continueGetAssertionAfterCheckAllowCredentials() {
        assert(!m_isDowngraded)
        let options = requestOptions()

        let internalUVAvailability = info.userVerificationAvailability
        var authenticatorSupportedExtensions = fido.StringVector()
        if let extensions = Optional(fromCxx: info.extensions) {
            authenticatorSupportedExtensions = extensions
        }
        var overrideAllowCredentials = fido.OptionalCredentialDescriptorVector()
        var overrideBatch: fido.CredentialDescriptorVector? = nil
        if options.allowCredentials.size() > 1 && m_currentBatch < m_batches.size() {
            overrideBatch = m_batches[m_currentBatch]
            overrideAllowCredentials = fido.OptionalCredentialDescriptorVector(m_batches[m_currentBatch])
        }

        let extensions = Optional(fromCxx: options.extensions)
        let prf = extensions.flatMap { Optional(fromCxx: $0.prf) }
        let needsPRF = prf != nil
        log(
            "continueGetAssertionAfterCheckAllowCredentials: PRF check - extensions=\(extensions != nil ? 1 : 0), prf=\(needsPRF ? 1 : 0)"
        )
        let supportsHmacSecret = contains(authenticatorSupportedExtensions, "hmac-secret")

        var hmacSecretParameters = fido.OptionalHmacSecretParameters()
        if let prf, supportsHmacSecret {
            log("continueGetAssertionAfterCheckAllowCredentials: PRF extension found, preparing hmac-secret")
            // The credential whose evalByCredential entry applies.
            var credentialId: cbor.CBORValue.BinaryValue? = nil
            if let overrideBatch, !overrideBatch.isEmpty() {
                credentialId = makeBinaryValue(bufferSourceBytes(overrideBatch[0].id))
            } else if !options.allowCredentials.isEmpty() {
                credentialId = makeBinaryValue(bufferSourceBytes(options.allowCredentials[0].id))
            }
            if let parameters = prepareHmacSecretParameters(prf, credentialId) {
                hmacSecretParameters = fido.OptionalHmacSecretParameters(parameters)
                log("continueGetAssertionAfterCheckAllowCredentials: PRF hmac-secret parameters prepared")
            } else {
                log("continueGetAssertionAfterCheckAllowCredentials: PRF hmac-secret parameters failed to prepare")
            }
        } else if needsPRF {
            log("continueGetAssertionAfterCheckAllowCredentials: PRF requested authenticator does not support hmac-secret")
        }

        log(
            "getAssertion uv: \(options.userVerification.rawValue) internalUvAvailability \(internalUVAvailability.rawValue)"
        )

        let effectiveUVRequirement: WebCore.UserVerificationRequirement =
            needsPRF && supportsHmacSecret ? .Required : options.userVerification

        let command: cbor.CBORValue.BinaryValue
        if internalUVAvailability == .supportedAndConfigured && effectiveUVRequirement != .Discouraged
            && m_pinAuth.isEmpty()
        {
            command = fido.encodeGetAssertionRequestAsCBOR(
                requestHash(), options, internalUVAvailability, effectiveUVRequirement,
                authenticatorSupportedExtensions, fido.OptionalPinParameters(), overrideAllowCredentials,
                hmacSecretParameters
            )
        } else if info.clientPinAvailability == .supportedAndPinSet
            && effectiveUVRequirement != .Discouraged
        {
            command = fido.encodeGetAssertionRequestAsCBOR(
                requestHash(), options, internalUVAvailability, effectiveUVRequirement,
                authenticatorSupportedExtensions, fido.OptionalPinParameters(pinParameters()), overrideAllowCredentials,
                hmacSecretParameters
            )
        } else {
            command = fido.encodeGetAssertionRequestAsCBOR(
                requestHash(), options, internalUVAvailability, effectiveUVRequirement,
                authenticatorSupportedExtensions, fido.OptionalPinParameters(), overrideAllowCredentials,
                hmacSecretParameters
            )
        }
        if let maxMsgSize = Optional(fromCxx: info.maxMsgSize), command.size() >= Int(maxMsgSize) {
            log("getAssertion cmdSize = \(command.size()) maxMsgSize = \(maxMsgSize)")
        }
        log("getAssertion: Sending ", base64String(command))
        transact(command) { this, data in
            this.continueGetAssertionAfterResponseReceived(data)
        }
    }

    private func continueGetAssertionAfterResponseReceived(_ data: cbor.CBORValue.BinaryValue) {
        let parsed = readGetAssertionResponse(data)
        let error = fido.getResponseCode(data)
        log("continueGetAssertionAfterResponseReceived: errorcode: \(error.rawValue)")
        guard let response = parsed.get() else {
            log("continueGetAssertionAfterResponseReceived: Failed to parse response ", base64String(data))
            if error == .ctap2ErrActionTimeout {
                restartGetAssertion()
                return
            }

            if !isPinError(error) && tryDowngrade() {
                return
            }

            if isTerminalPinError(error) {
                log("continueGetAssertionAfterResponseReceived: Terminal PIN error - notifying UI")
                updateObserverStatus(.PinAuthBlocked)
                return
            }

            if isPinError(error) {
                // Skip the very first command, which acts as a wink.
                if !m_pinAuth.isEmpty() {
                    updateObserverStatus(toStatus(error))
                }
                if tryRestartPin(error) {
                    return
                }
            }

            if error == .ctap2ErrNoCredentials {
                updateObserverStatus(.NoCredentialsFound)
            }

            log("continueGetAssertionAfterResponseReceived: No credentials found.")
            respondWithError(.UnknownError, errorCodeMessage(error))
            return
        }
        log("continueGetAssertionAfterResponseReceived: Get \(response.numberOfCredentials()) credentials back.")

        clearHmacSecretRequest()

        if response.numberOfCredentials() <= 1 {
            respondWithResponse(response)
            return
        }

        m_remainingAssertionResponses = Int(response.numberOfCredentials()) - 1
        reserveAssertionResponses(Int(response.numberOfCredentials()))
        appendAssertionResponse(response)
        let command = fido.encodeEmptyAuthenticatorRequest(.authenticatorGetNextAssertion)
        log("continueGetAssertionAfterResponseReceived: Sending ", base64String(command))
        transact(command) { this, data in
            this.continueGetNextAssertionAfterResponseReceived(data)
        }
    }

    private func continueGetNextAssertionAfterResponseReceived(_ data: cbor.CBORValue.BinaryValue) {
        let error = fido.getResponseCode(data)
        log("continueGetNextAssertionAfterResponseReceived: errorcode: \(error.rawValue)")
        guard let response = readGetAssertionResponse(data).get() else {
            log("continueGetNextAssertionAfterResponseReceived: Unable to parse response: ", base64String(data))
            respondWithError(.UnknownError, errorCodeMessage(error))
            return
        }
        m_remainingAssertionResponses -= 1
        appendAssertionResponse(response)
        log("continueGetNextAssertionAfterResponseReceived: Remaining responses: \(self.m_remainingAssertionResponses)")

        if m_remainingAssertionResponses == 0 {
            if hasObserver() {
                selectAssertionResponseFromObserver()
            }
            return
        }

        let command = fido.encodeEmptyAuthenticatorRequest(.authenticatorGetNextAssertion)
        log("continueGetNextAssertionAfterResponseReceived: Sending ", base64String(command))
        transact(command) { this, data in
            this.continueGetNextAssertionAfterResponseReceived(data)
        }
    }

    private func getRetries() {
        let command = fido.pin.encodeAsCBOR(fido.pin.RetriesRequest(protocol: selectPinProtocol()))
        log("getRetries: Sending ", base64String(command))
        transact(command) { this, data in
            this.log("getRetries: Response ", base64String(data))
            this.continueGetKeyAgreementAfterGetRetries(data)
        }
    }

    private func continueGetKeyAgreementAfterGetRetries(_ data: cbor.CBORValue.BinaryValue) {
        log("continueGetKeyAgreementAfterGetRetries")
        let retries = fido.pin.parseRetriesResponse(data)
        if !retries.valid {
            let error = fido.getResponseCode(data)
            log("continueGetKeyAgreementAfterGetRetries: Error code: \(error.rawValue)")
            respondWithError(.UnknownError, errorCodeMessage(error))
            return
        }

        let command = fido.pin.encodeAsCBOR(fido.pin.KeyAgreementRequest(protocol: selectPinProtocol()))
        log("continueGetKeyAgreementAfterGetRetries: Sending ", base64String(command))
        let retryCount = retries.retries
        transact(command) { this, data in
            this.log("continueGetKeyAgreementAfterGetRetries: Response ", base64String(data))
            this.continueRequestPinAfterGetKeyAgreement(data, retryCount)
        }
    }

    private func continueRequestPinAfterGetKeyAgreement(_ data: cbor.CBORValue.BinaryValue, _ retries: UInt64) {
        log("continueRequestPinAfterGetKeyAgreement")
        let keyAgreement = fido.pin.parseKeyAgreementResponse(data)
        guard let peerKey = keyAgreement.get() else {
            let error = fido.getResponseCode(data)
            respondWithError(.UnknownError, errorCodeMessage(error))
            return
        }

        if hasObserver() {
            log("continueRequestPinAfterGetKeyAgreement: Requesting pin from observer.")
            m_cachedPeerKey = keyAgreement
            let weakThis = WebKit.WeakPtrCtapAuthenticator(self)
            let handler = WebKit.AuthenticatorPinHandler { (pin: WTF.String) in
                precondition(WTF.RunLoop.isMain())
                guard let this = weakThis.get() else {
                    return
                }
                this.log("continueRequestPinAfterGetKeyAgreement: Got pin from observer.")
                this.continueGetPinTokenAfterRequestPin(pin, peerKey)
            }
            requestPinFromObserver(false, retries, consuming: handler)
        }
    }

    private func continueGetPinTokenAfterRequestPin(_ pin: WTF.String, _ peerKey: WebCore.CryptoKeyEC) {
        log("continueGetNextAssertionAfterResponseReceived")
        if pin.isNull() {
            respondWithError(.UnknownError, webAuthnString("Pin is null."))
            return
        }

        let pinUTF8 = fido.pin.validatePinAsUTF8(pin)
        if fido.utf8CStringLength(pinUTF8) == 0 {
            // Fake a PIN invalid answer from the authenticator, so that clients can show the user an error.
            updateObserverStatus(.PinInvalid)
            _ = tryRestartPin(.ctap2ErrPinInvalid)
            return
        }
        let tokenRequest = fido.pin.tokenRequestParts(selectPinProtocol(), pinUTF8, peerKey)
        guard let sharedKey = tokenRequest.sharedKey.get() else {
            respondWithError(.UnknownError, webAuthnString("Cannot create a TokenRequest."))
            return
        }

        log("continueGetPinTokenAfterRequestPin: Sending ", base64String(tokenRequest.command))
        transact(tokenRequest.command) { this, data in
            this.log("continueGetPinTokenAfterRequestPin: Response ", base64String(data))
            this.continueRequestAfterGetPinToken(data, sharedKey)
        }
    }

    private func continueRequestAfterGetPinToken(_ data: cbor.CBORValue.BinaryValue, _ sharedKey: WebCore.CryptoKeyAES) {
        log("continueGetNextAssertionAfterResponseReceived")
        let token = fido.pin.parseTokenResponse(selectPinProtocol(), sharedKey, data)
        guard let tokenKey = token.get() else {
            let error = fido.getResponseCode(data)

            if isPinError(error) {
                updateObserverStatus(toStatus(error))
                if tryRestartPin(error) {
                    return
                }
            }

            updateObserverStatus(toStatus(.success))

            respondWithError(.UnknownError, errorCodeMessage(error))
            return
        }

        updateObserverStatus(toStatus(.success))

        m_pinAuth = fido.pin.tokenPinAuth(selectPinProtocol(), tokenKey, requestHash())
        if isCreationRequest() {
            restartMakeCredential()
        } else {
            restartGetAssertion()
        }
    }

    private func tryRestartPin(_ error: fido.CtapDeviceResponseCode) -> Bool {
        log("tryRestartPin: Error code: \(error.rawValue)")
        switch error {
        case .ctap2ErrPinNotSet, .ctap2ErrPinAuthInvalid, .ctap2ErrPinInvalid, .ctap2ErrPinRequired:
            if info.clientPinAvailability == .supportedButPinNotSet {
                performAuthenticatorSelectionForSetupPin()
            } else {
                getRetries()
            }
            return true
        default:
            return false
        }
    }

    private func canDowngradeToU2f() -> Bool {
        log("canDowngradeToU2f")
        if !hasVersion(.u2f) {
            return false
        }
        if !hasObserver() {
            return false
        }
        if isCreationRequest() {
            return fido.isConvertibleToU2fRegisterCommand(creationOptions())
        }
        return fido.isConvertibleToU2fSignCommand(requestOptions())
    }

    private func tryDowngrade() -> Bool {
        log("tryDowngrade")
        if !canDowngradeToU2f() {
            return false
        }

        log("tryDowngrade: Downgrading to U2F.")
        m_isDowngraded = true
        driverForSubclass().setProtocol(.u2f)
        // canDowngradeToU2f checked the observer.
        precondition(hasObserver())
        let downgraded = WebKit.U2fAuthenticator.create(consuming: releaseDriverForDowngrade())
        downgradeInObserver(downgraded.get())
        return true
    }

    private func transports() -> fido.TransportVector {
        if let infoTransports = Optional(fromCxx: info.transports) {
            return infoTransports
        }
        var transports = fido.TransportVector()
        transports.append(consuming: driverForSubclass().transport())
        return transports
    }

    // The AAGUID formatted as a UUID (WTF::UUIDCanonicalForm), or empty when it is not 16 bytes. An AAGUID is
    // 16 arbitrary vendor bytes, commonly all zero, so it is not a UUID; it is only formatted like one.
    private func aaguidForDebugging() -> Swift.String {
        let aaguid = info.aaguid
        if aaguid.size() != WebCore.aaguidLength {
            return ""
        }
        let digits: [Character] = Array("0123456789abcdef")
        var text = ""
        for index in 0..<aaguid.size() {
            if index == 4 || index == 6 || index == 8 || index == 10 {
                text.append("-")
            }
            let byte = aaguid[index]
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0xf)])
        }
        return text
    }

    private func isUVSetup() -> Bool {
        info.clientPinAvailability == .supportedAndPinSet
            || info.userVerificationAvailability == .supportedAndConfigured
    }

    private func selectPinProtocol() -> fido.PINUVAuthProtocol {
        if let protocols = Optional(fromCxx: info.pinProtocols) {
            log("selectPinProtocol: Authenticator supports \(protocols.size()) protocols")
            for pinProtocol in protocols {
                log("selectPinProtocol: Available protocol \(pinProtocol.rawValue)")
            }

            var supportsProtocol2 = false
            for pinProtocol in protocols where pinProtocol == .pinProtocol2 {
                supportsProtocol2 = true
            }
            if supportsProtocol2 {
                log("selectPinProtocol: Selected Protocol 2")
                return .pinProtocol2
            }
        }
        log("selectPinProtocol: Defaulting to Protocol 1")
        return .pinProtocol1
    }

    private func continueSetupPinAfterCommand(
        _ data: cbor.CBORValue.BinaryValue,
        _ pin: WTF.String,
        _ peerKey: WebCore.CryptoKeyEC
    ) {
        let error = fido.getResponseCode(data)
        if error != .success {
            log("continueSetupPinAfterCommand: Response of setPin was not successful: ", base64String(data))
            observerStatusUpdatedOrCrash(.PinInvalid)
            return
        }
        markClientPinSet()
        let pinUTF8 = fido.pin.validatePinAsUTF8(pin)
        if fido.utf8CStringLength(pinUTF8) == 0 {
            log("continueSetupPinAfterCommand: Unable to convert PIN, although it was successfully set.")
            observerStatusUpdatedOrCrash(.PinInvalid)
            return
        }
        let tokenRequest = fido.pin.tokenRequestParts(selectPinProtocol(), pinUTF8, peerKey)
        guard let sharedKey = tokenRequest.sharedKey.get() else {
            log("continueSetupPinAfterCommand: Failed to create TokenRequest.")
            respondWithError(.UnknownError, webAuthnString("Cannot create a TokenRequest."))
            return
        }

        log("continueSetupPinAfterCommand: Sending ", base64String(tokenRequest.command))
        transact(tokenRequest.command) { this, data in
            this.log("continueGetPinTokenAfterRequestPin: Response ", base64String(data))
            this.continueRequestAfterGetPinToken(data, sharedKey)
        }
    }

    private func continueSetupPinAfterGetKeyAgreement(_ data: cbor.CBORValue.BinaryValue, _ pin: WTF.String) {
        let keyAgreement = fido.pin.parseKeyAgreementResponse(data)
        guard let peerKey = keyAgreement.get() else {
            let error = fido.getResponseCode(data)
            respondWithError(.UnknownError, errorCodeMessage(error))
            return
        }
        let setPinRequest = fido.pin.setPinRequestParts(selectPinProtocol(), pin, peerKey)
        if !setPinRequest.valid {
            respondWithError(.UnknownError, webAuthnString("Cannot create a SetPinRequest."))
            return
        }
        m_pinAuth = setPinRequest.pinAuth
        transact(setPinRequest.command) { this, response in
            this.continueSetupPinAfterCommand(response, pin, peerKey)
        }
    }

    private func setupPin() {
        if !hasObserver() {
            return
        }
        log("setupPin: Requesting new pin from delegate")
        let minLength = UInt64(Optional(fromCxx: info.minPINLength) ?? 4)
        let weakThis = WebKit.WeakPtrCtapAuthenticator(self)
        let handler = WebKit.AuthenticatorPinHandler { (pin: WTF.String) in
            guard let this = weakThis.get() else {
                return
            }
            let minPINLength = (Optional(fromCxx: this.info.minPINLength) ?? 4)
            if UInt64(pin.length()) < UInt64(minPINLength) {
                this.observerStatusUpdatedOrCrash(.PINTooShort)
                this.performAuthenticatorSelectionForSetupPin()
                return
            }
            if Int(pin.sizeInBytes()) > Int(fido.kPINMaxSizeInBytes) {
                this.observerStatusUpdatedOrCrash(.PINTooLong)
                this.performAuthenticatorSelectionForSetupPin()
                return
            }
            let command = fido.pin.encodeAsCBOR(fido.pin.KeyAgreementRequest(protocol: this.selectPinProtocol()))
            this.log("setupPin: Sending ", base64String(command))
            this.transact(command) { this, data in
                this.log("setupPin: Response ", base64String(data))
                this.continueSetupPinAfterGetKeyAgreement(data, pin)
            }
        }
        requestPinFromObserver(true, minLength, consuming: handler)
    }

    private func performAuthenticatorSelectionForSetupPin() {
        log("performAuthenticatorSelectionForSetupPin: Requesting gesture for authenticator selection")
        let command: cbor.CBORValue.BinaryValue
        if hasVersion(.ctap21) || hasVersion(.ctap21Pre) {
            // The authenticatorSelection command.
            command = fido.encodeEmptyAuthenticatorRequest(.authenticatorAuthenticatorSelection)
        } else {
            // A zero length pinAuth.
            command = fido.encodeBogusRequestForAuthenticatorSelection()
        }
        transact(command) { this, _ in
            this.setupPin()
        }
    }

    private func prepareHmacSecretParameters(
        _ prfInputs: WebCore.AuthenticationExtensionsClientInputs.PRFInputs,
        _ credentialId: cbor.CBORValue.BinaryValue?
    ) -> fido.HmacSecretParameters? {
        if m_cachedPeerKey.get() == nil {
            log("prepareHmacSecretParameters: No cached peer key available (likely first attempt before PIN)")
            return nil
        }

        var selectedValues: WebCore.AuthenticationExtensionsClientInputs.PRFValues? = nil

        if let evalByCredential = Optional(fromCxx: prfInputs.evalByCredential), let credentialId {
            let credentialIdString = base64URLString(credentialId)
            for entry in evalByCredential where sameCodeUnits(entry.key.description, credentialIdString) {
                selectedValues = entry.value
                log("prepareHmacSecretParameters: Using evalByCredential for credential")
                break
            }
        }

        if selectedValues == nil, let eval = Optional(fromCxx: prfInputs.eval) {
            selectedValues = eval
            log("prepareHmacSecretParameters: Using eval")
        }

        guard let selectedValues else {
            log("prepareHmacSecretParameters: No applicable PRF values")
            return nil
        }

        let salt1 = hashPRFInput(selectedValues.first)
        var salt2 = fido.OptionalByteVector()
        if let second = Optional(fromCxx: selectedValues.second) {
            salt2 = fido.OptionalByteVector(hashPRFInput(second))
        }

        let request = fido.pin.hmacSecretRequestParts(selectPinProtocol(), salt1, salt2, m_cachedPeerKey)
        if !request.valid {
            log("prepareHmacSecretParameters: Failed to create HmacSecretRequest")
            return nil
        }

        m_hmacSecretSharedKey = request.sharedKey
        m_hmacSecretProtocol = request.pinProtocol
        return request.parameters
    }

    // readCTAPGetAssertionResponse with the pending hmac-secret request.
    private func readGetAssertionResponse(_ data: cbor.CBORValue.BinaryValue) -> fido.AssertionResponsePtr {
        fido.readCTAPGetAssertionResponse(
            data, .CrossPlatform, m_hmacSecretSharedKey, m_hmacSecretProtocol
        )
    }

    private func clearHmacSecretRequest() {
        m_hmacSecretSharedKey = .init()
        m_hmacSecretProtocol = .pinProtocol1
    }

    // protect(observer())->authenticatorStatusUpdated(): crashes when there is no observer.
    private func observerStatusUpdatedOrCrash(_ status: WebKit.WebAuthenticationStatus) {
        precondition(hasObserver())
        updateObserverStatus(status)
    }
}

private func makeBinaryValue(_ bytes: [UInt8]) -> cbor.CBORValue.BinaryValue {
    var value = cbor.CBORValue.BinaryValue()
    value.reserveCapacity(bytes.count)
    for byte in bytes {
        value.append(consuming: byte)
    }
    return value
}

#endif // ENABLE_WEB_AUTHN
