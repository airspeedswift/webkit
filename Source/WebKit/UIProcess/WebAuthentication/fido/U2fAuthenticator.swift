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

import WebCore_Private
import WebKit_Internal
import wtf

// The U2F (CTAP1) authenticator: register and sign over a CtapDriver.
// https://fidoalliance.org/specs/fido-u2f-v1.2-ps-20170411/fido-u2f-raw-message-formats-v1.2-ps-20170411.html
//
// Each command's response arrives in responseReceived, which goes on by the command's type. A user presence test
// answers SW_CONDITIONS_NOT_SATISFIED until the user touches the key; a timer then sends the last command again.

extension WebKit.U2fAuthenticator {
    @cxx @implementation
    override func makeCredential() {
        WebKit.LogChannel.WebAuthn().releaseLog.log(
            "[transport=\(self.transportName().description)] - U2fAuthenticator::makeCredential"
        )
        let creationOptions = self.creationOptions()
        if !fido.isConvertibleToU2fRegisterCommand(creationOptions) {
            return
        }
        if !creationOptions.excludeCredentials.isEmpty() {
            assert(m_nextListIndex == 0)
            let index = m_nextListIndex
            m_nextListIndex += 1
            checkExcludeList(index)
            return
        }
        issueRegisterCommand()
    }

    @cxx @implementation
    override func getAssertion() {
        WebKit.LogChannel.WebAuthn().releaseLog.log(
            "[transport=\(self.transportName().description)] - U2fAuthenticator::getAssertion: Sending bogus sign."
        )
        if !fido.isConvertibleToU2fSignCommand(requestOptions()) {
            WebKit.LogChannel.WebAuthn().releaseLog.log(
                "[transport=\(self.transportName().description)] - U2fAuthenticator::getAssertion: command not convertible."
            )
            return
        }
        assert(m_nextListIndex == 0)
        let index = m_nextListIndex
        m_nextListIndex += 1
        issueSignCommand(index)
    }

    @cxx @implementation
    func issueCommand(_ command: cbor.CBORValue.BinaryValue, _ type: WebKit.U2fAuthenticator.CommandType) {
        WebKit.LogChannel.WebAuthn().releaseLog.log(
            "[transport=\(self.transportName().description)] - U2fAuthenticator::issueCommand: Sending \(fido.base64EncodeBytes(command).description)"
        )
        let weakThis = WebKit.WeakPtrU2fAuthenticator(self)
        let isRegister = type == .RegisterCommand
        let isCheckOnly = type == .CheckOnlyCommand
        let isBogusExcludeMatch = type == .BogusCommandExcludeCredentialsMatch
        let isBogusNoCredentials = type == .BogusCommandNoCredentials
        let step: U2fStep =
            isRegister ? .register
            : isCheckOnly ? .checkOnly
            : isBogusExcludeMatch ? .bogusExcludeCredentialsMatch
            : isBogusNoCredentials ? .bogusNoCredentials : .sign
        let callback = WebKit.CtapDriver.ResponseCallback { (data: cbor.CBORValue.BinaryValue) in
            if let authenticator = weakThis.get() {
                authenticator.responseReceived(data, step)
            }
        }
        driverForSubclass().transact(consuming: command, consuming: callback)
    }
}

// The command types as a Swift enum: a C++ enum nested in the class cannot appear in a Swift signature.
enum U2fStep {
    case register
    case checkOnly
    case bogusExcludeCredentialsMatch
    case bogusNoCredentials
    case sign

    var commandTypeNumber: UInt8 {
        switch self {
        case .register: 0
        case .checkOnly: 1
        case .bogusExcludeCredentialsMatch: 2
        case .bogusNoCredentials: 3
        case .sign: 4
        }
    }
}

extension WebKit.U2fAuthenticator {
    private func checkExcludeList(_ index: Int) {
        WebKit.LogChannel.WebAuthn().releaseLog.log(
            "[transport=\(self.transportName().description)] - U2fAuthenticator::checkExcludeList"
        )
        let creationOptions = self.creationOptions()
        if index >= creationOptions.excludeCredentials.size() {
            issueRegisterCommand()
            return
        }
        let command = fido.convertToU2fCheckOnlySignCommand(
            requestHash(), creationOptions, creationOptions.excludeCredentials[index]
        )
        // isConvertibleToU2fRegisterCommand held, so the command exists.
        guard let command = Optional(fromCxx: command) else {
            fatalError("U2fAuthenticator: the exclude list entry is not convertible to U2F")
        }
        issueNewCommand(command, .checkOnly)
    }

    private func issueRegisterCommand() {
        guard
            let command = Optional(fromCxx: fido.convertToU2fRegisterCommand(requestHash(), creationOptions()))
        else {
            WebKit.LogChannel.WebAuthn().releaseLog.log(
                "[transport=\(self.transportName().description)] - U2fAuthenticator::issueRegisterCommand: request not convertible to U2F."
            )
            return
        }
        WebKit.LogChannel.WebAuthn().releaseLog.log(
            "[transport=\(self.transportName().description)] - U2fAuthenticator::issueRegisterCommand: Sending \(fido.base64EncodeBytes(command).description)"
        )
        issueNewCommand(command, .register)
    }

    private func issueSignCommand(_ index: Int) {
        let requestOptions = self.requestOptions()
        if index >= requestOptions.allowCredentials.size() {
            WebKit.LogChannel.WebAuthn().releaseLog.log(
                "[transport=\(self.transportName().description)] - U2fAuthenticator::issueSignCommand: Sending bogus sign."
            )
            issueNewCommand(fido.constructBogusU2fRegistrationCommand(), .bogusNoCredentials)
            return
        }
        guard
            let command = Optional(
                fromCxx: fido.convertToU2fSignCommand(
                    requestHash(), requestOptions, requestOptions.allowCredentials[index].id, m_isAppId
                )
            )
        else {
            WebKit.LogChannel.WebAuthn().releaseLog.log(
                "[transport=\(self.transportName().description)] - U2fAuthenticator::issueSignCommand: request not convertible to U2F."
            )
            return
        }
        WebKit.LogChannel.WebAuthn().releaseLog.log(
            "[transport=\(self.transportName().description)] - U2fAuthenticator::issueSignCommand: index: \(index) Sending \(fido.base64EncodeBytes(command).description)"
        )
        issueNewCommand(command, .sign)
    }

    private func issueNewCommand(_ command: cbor.CBORValue.BinaryValue, _ step: U2fStep) {
        WebKit.LogChannel.WebAuthn().releaseLog.log(
            "[transport=\(self.transportName().description)] - U2fAuthenticator::issueNewCommand, type=\(step.commandTypeNumber)"
        )
        m_lastCommand = command
        switch step {
        case .register: m_lastCommandType = .RegisterCommand
        case .checkOnly: m_lastCommandType = .CheckOnlyCommand
        case .bogusExcludeCredentialsMatch: m_lastCommandType = .BogusCommandExcludeCredentialsMatch
        case .bogusNoCredentials: m_lastCommandType = .BogusCommandNoCredentials
        case .sign: m_lastCommandType = .SignCommand
        }
        issueCommand(m_lastCommand, m_lastCommandType)
    }

    fileprivate func responseReceived(_ response: cbor.CBORValue.BinaryValue, _ step: U2fStep) {
        guard let apduResponse = Optional(fromCxx: apdu.ApduResponse.createFromMessage(response)) else {
            WebKit.LogChannel.WebAuthn().releaseLog.log(
                "[transport=\(self.transportName().description)] - U2fAuthenticator::responseReceived: Failed to parse response."
            )
            respondWithError(.UnknownError, webAuthnString("Couldn't parse the APDU response."))
            return
        }
        WebKit.LogChannel.WebAuthn().releaseLog.log(
            "[transport=\(self.transportName().description)] - U2fAuthenticator::responseReceived: Got response for command type: \(step.commandTypeNumber)"
        )

        switch step {
        case .register:
            continueRegisterCommandAfterResponseReceived(apduResponse)
        case .checkOnly:
            continueCheckOnlyCommandAfterResponseReceived(apduResponse)
        case .bogusExcludeCredentialsMatch:
            continueBogusCommandExcludeCredentialsMatchAfterResponseReceived(apduResponse)
        case .bogusNoCredentials:
            continueBogusCommandNoCredentialsAfterResponseReceived(apduResponse)
        case .sign:
            continueSignCommandAfterResponseReceived(apduResponse)
        }
    }

    private func respondWithUnknownStatus(_ apduResponse: apdu.ApduResponse) {
        respondWithError(
            .UnknownError,
            webAuthnString("Unknown internal error. Error code: \(UInt32(apduResponse.status().rawValue))")
        )
    }

    private func continueRegisterCommandAfterResponseReceived(_ apduResponse: apdu.ApduResponse) {
        WebKit.LogChannel.WebAuthn().releaseLog.log(
            "[transport=\(self.transportName().description)] - U2fAuthenticator::continueRegisterCommandAfterResponseReceived: Status \(apduResponse.status().rawValue)"
        )
        switch apduResponse.status() {
        case .SW_NO_ERROR:
            let options = creationOptions()
            if options.rp.id.isNull() {
                WebKit.LogChannel.WebAuthn().releaseLog.log(
                    "[transport=\(self.transportName().description)] - U2fAuthenticator::continueRegisterCommandAfterResponseReceived: rp.id empty. Should not be."
                )
                assertionFailure()
            }
            var transports = fido.TransportVector()
            transports.append(consuming: driverForSubclass().transport())
            let response = fido.readU2fRegisterResponse(
                options.rp.id, fido.apduResponseData(apduResponse), .CrossPlatform, transports, options.attestation
            )
            guard let response = response.get() else {
                respondWithError(.UnknownError, webAuthnString("Couldn't parse the U2F register response."))
                return
            }
            respondWithResponse(response)
        case .SW_CONDITIONS_NOT_SATISFIED:
            // Polling is required during test of user presence.
            scheduleRetry()
        default:
            respondWithUnknownStatus(apduResponse)
        }
    }

    private func continueCheckOnlyCommandAfterResponseReceived(_ apduResponse: apdu.ApduResponse) {
        WebKit.LogChannel.WebAuthn().releaseLog.log(
            "[transport=\(self.transportName().description)] - U2fAuthenticator::continueCheckOnlyCommandAfterResponseReceived: Status \(apduResponse.status().rawValue)"
        )
        switch apduResponse.status() {
        case .SW_NO_ERROR, .SW_CONDITIONS_NOT_SATISFIED:
            issueNewCommand(fido.constructBogusU2fRegistrationCommand(), .bogusExcludeCredentialsMatch)
        default:
            let index = m_nextListIndex
            m_nextListIndex += 1
            checkExcludeList(index)
        }
    }

    private func continueBogusCommandExcludeCredentialsMatchAfterResponseReceived(_ apduResponse: apdu.ApduResponse) {
        WebKit.LogChannel.WebAuthn().releaseLog.log(
            "[transport=\(self.transportName().description)] - U2fAuthenticator::continueBogusCommandExcludeCredentialsMatchAfterResponseReceived: Status \(apduResponse.status().rawValue)"
        )
        switch apduResponse.status() {
        case .SW_NO_ERROR:
            respondWithError(
                .InvalidStateError,
                webAuthnString(
                    "At least one credential matches an entry of the excludeCredentials list in the authenticator."
                )
            )
        case .SW_CONDITIONS_NOT_SATISFIED:
            // Polling is required during test of user presence.
            scheduleRetry()
        default:
            respondWithUnknownStatus(apduResponse)
        }
    }

    private func continueBogusCommandNoCredentialsAfterResponseReceived(_ apduResponse: apdu.ApduResponse) {
        WebKit.LogChannel.WebAuthn().releaseLog.log(
            "[transport=\(self.transportName().description)] - U2fAuthenticator::continueBogusCommandNoCredentialsAfterResponseReceived: Status \(apduResponse.status().rawValue)"
        )
        switch apduResponse.status() {
        case .SW_NO_ERROR:
            updateObserverStatus(.NoCredentialsFound)
            respondWithError(
                .NotAllowedError,
                webAuthnString("No credentials from the allowCredentials list is found in the authenticator.")
            )
        case .SW_CONDITIONS_NOT_SATISFIED:
            // Polling is required during test of user presence.
            scheduleRetry()
        default:
            respondWithUnknownStatus(apduResponse)
        }
    }

    private func continueSignCommandAfterResponseReceived(_ apduResponse: apdu.ApduResponse) {
        WebKit.LogChannel.WebAuthn().releaseLog.log(
            "[transport=\(self.transportName().description)] - U2fAuthenticator::continueSignCommandAfterResponseReceived: Status \(apduResponse.status().rawValue)"
        )
        let requestOptions = self.requestOptions()
        let extensions = Optional(fromCxx: requestOptions.extensions)
        let hasAppId = extensions.map { !$0.appid.isNull() } ?? false
        switch apduResponse.status() {
        case .SW_NO_ERROR:
            WebKit.LogChannel.WebAuthn().releaseLog.log(
                "[transport=\(self.transportName().description)] - U2fAuthenticator::continueSignCommandAfterResponseReceived: m_isAppId=\(self.m_isAppId ? 1 : 0)"
            )
            let keyHandle = requestOptions.allowCredentials[m_nextListIndex - 1].id
            let response: fido.AssertionResponsePtr
            if m_isAppId {
                if !hasAppId {
                    WebKit.LogChannel.WebAuthn().releaseLog.log(
                        "[transport=\(self.transportName().description)] - U2fAuthenticator::continueSignCommandAfterResponseReceived: appid and m_isAppId mismatch"
                    )
                    assertionFailure()
                }
                // m_isAppId is only set when the extensions carry an appid.
                guard let extensions else {
                    fatalError("U2fAuthenticator: m_isAppId without extensions")
                }
                response = fido.readU2fSignResponse(extensions.appid, keyHandle, fido.apduResponseData(apduResponse), .CrossPlatform)
            } else {
                response = fido.readU2fSignResponse(
                    requestOptions.rpId, keyHandle, fido.apduResponseData(apduResponse), .CrossPlatform
                )
            }
            guard let response = response.get() else {
                WebKit.LogChannel.WebAuthn().releaseLog.log(
                    "[transport=\(self.transportName().description)] - U2fAuthenticator::continueSignCommandAfterResponseReceived: Couldn't parse the U2F sign response."
                )
                respondWithError(.UnknownError, webAuthnString("Couldn't parse the U2F sign response."))
                return
            }
            if m_isAppId {
                var outputs = WebCore.AuthenticationExtensionsClientOutputs()
                outputs.appid = .init(m_isAppId)
                response.setExtensions(consuming: outputs)
            }
            respondWithResponse(response)
        case .SW_CONDITIONS_NOT_SATISFIED:
            WebKit.LogChannel.WebAuthn().releaseLog.log(
                "[transport=\(self.transportName().description)] - U2fAuthenticator::continueSignCommandAfterResponseReceived: SW_CONDITIONS_NOT_SATISFIED"
            )
            // Polling is required during test of user presence.
            scheduleRetry()
        case .SW_WRONG_DATA:
            WebKit.LogChannel.WebAuthn().releaseLog.log(
                "[transport=\(self.transportName().description)] - U2fAuthenticator::continueSignCommandAfterResponseReceived: SW_WRONG_DATA"
            )
            if hasAppId {
                if !m_isAppId {
                    WebKit.LogChannel.WebAuthn().releaseLog.log(
                        "[transport=\(self.transportName().description)] - U2fAuthenticator::continueSignCommandAfterResponseReceived: trying appID extension."
                    )
                    m_isAppId = true
                    issueSignCommand(m_nextListIndex - 1)
                    return
                }
                WebKit.LogChannel.WebAuthn().releaseLog.log(
                    "[transport=\(self.transportName().description)] - U2fAuthenticator::continueSignCommandAfterResponseReceived: SW_WRONG_DATA and m_IsAppId"
                )
                m_isAppId = false
            }
            let index = m_nextListIndex
            m_nextListIndex += 1
            issueSignCommand(index)
        default:
            let index = m_nextListIndex
            m_nextListIndex += 1
            issueSignCommand(index)
        }
    }
}

#endif // ENABLE_WEB_AUTHN
