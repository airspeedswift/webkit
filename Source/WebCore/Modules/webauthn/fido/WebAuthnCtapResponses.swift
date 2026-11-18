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

// ENABLE(WEB_AUTHN) (PlatformEnableCocoa.h): every Cocoa platform but watchOS and Mac Catalyst.
#if !os(watchOS) && !targetEnvironment(macCatalyst)

// Without these, no operator in this file type-checks: WebCore's C++ operators name types these modules define.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch
internal import wtf
internal import WebCore_Private.Core.WebAuthnSwiftTypes

// CTAP2 response decoding and the protocol constants' helpers.

/// Whether `code` is a response code a CTAP device can send.
func isCtapDeviceResponseCode(_ code: fido.CtapDeviceResponseCode) -> Bool {
    switch code {
    case .success, .ctap1ErrInvalidCommand, .ctap1ErrInvalidParameter, .ctap1ErrInvalidLength, .ctap1ErrInvalidSeq,
        .ctap1ErrTimeout, .ctap1ErrChannelBusy, .ctap1ErrLockRequired, .ctap1ErrInvalidChannel,
        .ctap2ErrCBORParsing, .ctap2ErrUnexpectedType, .ctap2ErrInvalidCBOR, .ctap2ErrInvalidCBORType,
        .ctap2ErrMissingParameter, .ctap2ErrLimitExceeded, .ctap2ErrUnsupportedExtension, .ctap2ErrTooManyElements,
        .ctap2ErrExtensionNotSupported, .ctap2ErrCredentialExcluded, .ctap2ErrProcesssing,
        .ctap2ErrInvalidCredential, .ctap2ErrUserActionPending, .ctap2ErrOperationPending, .ctap2ErrNoOperations,
        .ctap2ErrUnsupportedAlgorithms, .ctap2ErrOperationDenied, .ctap2ErrKeyStoreFull, .ctap2ErrNotBusy,
        .ctap2ErrNoOperationPending, .ctap2ErrUnsupportedOption, .ctap2ErrInvalidOption, .ctap2ErrKeepAliveCancel,
        .ctap2ErrNoCredentials, .ctap2ErrUserActionTimeout, .ctap2ErrUserPresenceRequired, .ctap2ErrNotAllowed,
        .ctap2ErrPinInvalid, .ctap2ErrPinBlocked, .ctap2ErrPinAuthInvalid, .ctap2ErrPinAuthBlocked,
        .ctap2ErrPinNotSet, .ctap2ErrPinRequired, .ctap2ErrPinPolicyViolation, .ctap2ErrPinTokenExpired,
        .ctap2ErrRequestTooLarge, .ctap2ErrActionTimeout, .ctap2ErrOther, .ctap2ErrSpecLast,
        .ctap2ErrExtensionFirst, .ctap2ErrExtensionLast, .ctap2ErrVendorFirst, .ctap2ErrVendorLast:
        return true
    default:
        return false
    }
}

/// `getResponseCode` on bytes.
private func responseCode(_ bytes: Span<UInt8>) -> fido.CtapDeviceResponseCode {
    if bytes.isEmpty {
        return .ctap2ErrInvalidCBOR
    }
    // init?(rawValue:) of an imported C++ enum never fails; the check is the one above.
    let code = fido.CtapDeviceResponseCode(rawValue: bytes[0])!
    return isCtapDeviceResponseCode(code) ? code : .ctap2ErrInvalidCBOR
}

/// `decodeResponseMap`: the CBOR map after a success status byte, read from the buffer in place. The span of a
/// by-value C++ parameter is taken in a helper (see apdu.ApduCommand.createFromMessage).
private func decodeResponseMap(_ buffer: borrowing cbor.CBORValue.BinaryValue) -> CBOR.Map? {
    let bytes: Span<UInt8> = buffer.span()
    if bytes.count <= fido.kResponseCodeLength {
        return nil
    }
    if responseCode(bytes) != .success {
        return nil
    }
    return CBOR.read(bytes.extracting(1...))?.mapValue
}

/// A big-endian 16-bit length at `offset`; the caller has checked the bounds.
private func readLength16(_ bytes: [UInt8], _ offset: Int) -> Int {
    (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
}

/// The credential ID in authenticator data: empty when the authenticator data has no complete credential ID.
private func credentialId(fromAuthenticatorData authenticatorData: [UInt8]) -> [UInt8] {
    let credentialIdLengthOffset = WebCore.rpIdHashLength + WebCore.flagsLength + WebCore.signCounterLength + WebCore.aaguidLength
    if authenticatorData.count < credentialIdLengthOffset + WebCore.credentialIdLengthLength {
        return []
    }
    let credentialIdLength = readLength16(authenticatorData, credentialIdLengthOffset)
    let start = credentialIdLengthOffset + WebCore.credentialIdLengthLength
    if authenticatorData.count < start + credentialIdLength {
        return []
    }
    return Array(authenticatorData[start..<(start + credentialIdLength)])
}

/// The prf state that `parseAuthenticatorDataExtensions` builds, as plain values.
private struct PRFState {
    var enabled: Bool?
    /// The decrypted output of the last hmac-secret byte string that decrypted.
    var output: [UInt8]?

    /// An engaged `AuthenticationExtensionsClientOutputs`, with prf when the C++ would set it.
    func makeOutputs() -> fido.OptionalClientOutputs {
        var first = cbor.CBORValue.BinaryValue()
        var second = cbor.CBORValue.BinaryValue()
        var hasSecond = false
        if let output {
            // first: the first hmacSecretOutputLength bytes (fewer if shorter); second: the next ones, for a dual output.
            first = makeByteVector(Array(output.prefix(WebCore.hmacSecretOutputLength)))
            if output.count == WebCore.hmacSecretDualOutputLength {
                second = makeByteVector(Array(output[WebCore.hmacSecretOutputLength..<WebCore.hmacSecretDualOutputLength]))
                hasSecond = true
            }
        }
        return WebCore.makeClientOutputsWithPRF(enabled != nil, enabled ?? false, output != nil, first, hasSecond, second)
    }
}

/// `parseAuthenticatorDataExtensions`: nil where it gives nullopt, which the callers turn into empty outputs.
private func parseAuthenticatorDataExtensions(_ authData: [UInt8], _ hmacSharedKey: WebCore.CryptoKeyAES?, _ pinProtocol: fido.PINUVAuthProtocol) -> PRFState? {
    let minAuthDataLength = WebCore.rpIdHashLength + WebCore.flagsLength + WebCore.signCounterLength
    if authData.count < minAuthDataLength {
        return nil
    }

    let flags = authData[WebCore.rpIdHashLength]
    if flags & WebAuthn.extensionDataIncludedFlag == 0 {
        return nil
    }

    var offset = minAuthDataLength
    if flags & WebAuthn.attestedCredentialDataIncludedFlag != 0 {
        offset += WebCore.aaguidLength
        if authData.count < offset + WebCore.credentialIdLengthLength {
            return nil
        }
        let credentialIdLength = readLength16(authData, offset)
        offset += WebCore.credentialIdLengthLength + credentialIdLength
        if authData.count <= offset {
            return nil
        }
        guard let publicKey = CBOR.readWithBytesConsumed(authData.span.extracting(offset...)) else {
            return nil
        }
        offset += publicKey.bytesConsumed
    }

    if authData.count <= offset {
        return nil
    }
    guard let extensionsMap = CBOR.read(authData.span.extracting(offset...))?.mapValue else {
        return nil
    }

    var state = PRFState()
    // hmac-secret-mc is looked at only when hmac-secret is present.
    guard let hmacSecret = extensionsMap[FidoName.extensionHmacSecret] else {
        return state
    }
    for value in [hmacSecret, extensionsMap[FidoName.extensionHmacSecretMc]] {
        guard let value else {
            break
        }
        if let enabled = value.boolValue {
            state.enabled = enabled
        } else if let encryptedOutput = value.byteStringValue, let hmacSharedKey {
            if let output = hmacSecretOutput(pinProtocol, hmacSharedKey, encryptedOutput) {
                state.output = output
            }
        }
    }
    return state
}

extension fido {
    @cxx @implementation public static func isCtap2Protocol(_ version: fido.ProtocolVersion) -> Bool {
        switch version {
        case .ctap2, .ctap21, .ctap21Pre:
            return true
        default:
            return false
        }
    }

    @cxx @implementation public static func toString(_ version: fido.ProtocolVersion) -> WTF.String {
        makeWTFString(protocolVersionName(version))
    }

    @cxx @implementation public static func getResponseCode(_ buffer: cbor.CBORValue.BinaryValue) -> fido.CtapDeviceResponseCode {
        if buffer.isEmpty() {
            return .ctap2ErrInvalidCBOR
        }
        let code = fido.CtapDeviceResponseCode(rawValue: buffer[0])!
        return isCtapDeviceResponseCode(code) ? code : .ctap2ErrInvalidCBOR
    }

    @cxx @implementation public static func readCTAPMakeCredentialResponse(_ inBuffer: cbor.CBORValue.BinaryValue, _ attachment: WebCore.AuthenticatorAttachment, _ transports: fido.TransportVector, _ attestation: WebCore.AttestationConveyancePreference, _ hmacSharedKey: fido.CryptoKeyAESPtr, _ pinProtocol: fido.PINUVAuthProtocol) -> fido.AttestationResponsePtr {
        guard let responseMap = decodeResponseMap(inBuffer) else {
            return fido.AttestationResponsePtr()
        }
        guard let format = responseMap[fido.kCtapMakeCredentialResponseFormatKey], format.isString else {
            return fido.AttestationResponsePtr()
        }
        guard let authDataBytes = responseMap[fido.kCtapMakeCredentialResponseAuthDataKey]?.byteStringValue else {
            return fido.AttestationResponsePtr()
        }
        let credentialId = credentialId(fromAuthenticatorData: authDataBytes)
        if credentialId.isEmpty {
            return fido.AttestationResponsePtr()
        }
        guard let attStmt = responseMap[fido.kCtapMakeCredentialResponseAttStmtKey], attStmt.isMap else {
            return fido.AttestationResponsePtr()
        }

        let extensions = (parseAuthenticatorDataExtensions(authDataBytes, hmacSharedKey.get(), pinProtocol) ?? PRFState()).makeOutputs()

        var attestationObject: cbor.CBORValue.BinaryValue
        if attestation == .None {
            attestationObject = WebCore.buildAttestationObject(consuming: makeByteVector(authDataBytes), consuming: fido.emptyWTFString(), consuming: cbor.CBORValue.MapValue(), attestation, .Yes)
        } else {
            // The response map nests attStmt as deep as this map does, and it was read within the writer's limit.
            guard let written = CBOR.writeAttestationObject(format: format, attStatement: attStmt, authData: authDataBytes) else {
                preconditionFailure("an attestation object nests no deeper than the response it came from")
            }
            attestationObject = makeByteVector(written)
        }

        let response = WebCore.AuthenticatorAttestationResponse.create(makeByteVector(credentialId), attestationObject, consuming: extensions, attachment, consuming: transports).get()
        return fido.AttestationResponsePtr(response)
    }

    @cxx @implementation public static func readCTAPGetAssertionResponse(_ inBuffer: cbor.CBORValue.BinaryValue, _ attachment: WebCore.AuthenticatorAttachment, _ hmacSharedKey: fido.CryptoKeyAESPtr, _ pinProtocol: fido.PINUVAuthProtocol) -> fido.AssertionResponsePtr {
        guard let responseMap = decodeResponseMap(inBuffer) else {
            return fido.AssertionResponsePtr()
        }
        guard let credential = responseMap[fido.kCtapGetAssertionResponseCredentialKey]?.mapValue,
            let credentialId = credential[FidoName.credentialId]?.byteStringValue else {
            return fido.AssertionResponsePtr()
        }
        guard let authData = responseMap[fido.kCtapGetAssertionResponseAuthDataKey]?.byteStringValue else {
            return fido.AssertionResponsePtr()
        }
        guard let signature = responseMap[fido.kCtapGetAssertionResponseSignatureKey]?.byteStringValue else {
            return fido.AssertionResponsePtr()
        }

        // Parse extensions from authenticatorData
        let extensions = (parseAuthenticatorDataExtensions(authData, hmacSharedKey.get(), pinProtocol) ?? PRFState()).makeOutputs()

        var userHandle: [UInt8] = []
        var name: Swift.String?
        var displayName: Swift.String?
        if let user = responseMap[fido.kCtapGetAssertionResponseUserKey]?.mapValue {
            guard let id = user[FidoName.entityId]?.byteStringValue else {
                return fido.AssertionResponsePtr()
            }
            userHandle = id
            if let value = user[FidoName.entityName] {
                guard let string = value.stringValue else {
                    return fido.AssertionResponsePtr()
                }
                name = string
            }
            if let value = user[FidoName.displayName] {
                guard let string = value.stringValue else {
                    return fido.AssertionResponsePtr()
                }
                displayName = string
            }
        }

        let response = WebCore.AuthenticatorAssertionResponse.create(makeByteVector(credentialId), makeByteVector(authData), makeByteVector(signature), makeByteVector(userHandle), consuming: extensions, attachment).get()
        if let name {
            response.setName(makeWTFString(name))
        }
        if let displayName {
            response.setDisplayName(makeWTFString(displayName))
        }
        if let numberOfCredentials = responseMap[fido.kCtapGetAssertionResponseNumberOfCredentialsKey]?.unsignedValue {
            response.setNumberOfCredentials(Int(numberOfCredentials))
        }
        return fido.AssertionResponsePtr(response)
    }

    @cxx @implementation public static func readCTAPGetInfoResponse(_ inBuffer: cbor.CBORValue.BinaryValue) -> fido.OptionalGetInfoResponse {
        guard let responseMap = decodeResponseMap(inBuffer) else {
            return noGetInfoResponse()
        }

        var fields = fido.GetInfoResponseFields()
        guard let versions = responseMap[fido.kCtapAuthenticatorGetInfoVersionsKey]?.arrayValue else {
            return noGetInfoResponse()
        }
        // StdSet<ProtocolVersion>: kept in enum order.
        var protocolVersions: [fido.ProtocolVersion] = []
        for version in versions {
            guard let string = version.stringValue else {
                return noGetInfoResponse()
            }
            let protocolVersion = protocolVersionFromName(string)
            if protocolVersion == .unknown {
                continue
            }
            if protocolVersions.contains(protocolVersion) {
                return noGetInfoResponse()
            }
            protocolVersions.append(protocolVersion)
        }
        if protocolVersions.isEmpty {
            return noGetInfoResponse()
        }
        protocolVersions.sort { $0.rawValue < $1.rawValue }
        for protocolVersion in protocolVersions {
            fields.versions.append(consuming: protocolVersion)
        }

        guard let aaguid = responseMap[fido.kCtapAuthenticatorGetInfoAAGUIDKey]?.byteStringValue, aaguid.count == WebCore.aaguidLength else {
            return noGetInfoResponse()
        }
        fields.aaguid = makeByteVector(aaguid)

        if let value = responseMap[fido.kCtapAuthenticatorGetInfoExtensionsKey] {
            guard let extensions = value.arrayValue else {
                return noGetInfoResponse()
            }
            var extensionNames = fido.StringVector()
            for extensionName in extensions {
                guard let string = extensionName.stringValue else {
                    return noGetInfoResponse()
                }
                extensionNames.append(consuming: makeWTFString(string))
            }
            fields.extensions = fido.OptionalStringVector(extensionNames)
        }

        if let value = responseMap[fido.kCtapAuthenticatorGetInfoOptionsKey] {
            guard let optionMap = value.mapValue else {
                return noGetInfoResponse()
            }
            if let option = optionMap[FidoName.platformDevice] {
                guard let flag = option.boolValue else {
                    return noGetInfoResponse()
                }
                fields.isPlatformDevice = flag
            }
            if let option = optionMap[FidoName.residentKey] {
                guard let flag = option.boolValue else {
                    return noGetInfoResponse()
                }
                fields.residentKeyAvailability = flag ? .supported : .notSupported
            }
            if let option = optionMap[FidoName.userPresence] {
                guard let flag = option.boolValue else {
                    return noGetInfoResponse()
                }
                fields.userPresenceRequired = flag
            }
            if let option = optionMap[FidoName.userVerification] {
                guard let flag = option.boolValue else {
                    return noGetInfoResponse()
                }
                fields.userVerificationAvailability = flag ? .supportedAndConfigured : .supportedButNotConfigured
            }
            if let option = optionMap[FidoName.clientPin] {
                guard let flag = option.boolValue else {
                    return noGetInfoResponse()
                }
                fields.clientPinAvailability = flag ? .supportedAndPinSet : .supportedButPinNotSet
            }
        }

        if let value = responseMap[fido.kCtapAuthenticatorGetInfoMaxMsgSizeKey] {
            guard let size = value.unsignedValue else {
                return noGetInfoResponse()
            }
            fields.maxMsgSize = fido.OptionalUInt32(UInt32(truncatingIfNeeded: size)) // setMaxMsgSize(uint32_t) narrows getUnsigned().
        }

        if let value = responseMap[fido.kCtapAuthenticatorGetInfoPinUVAuthProtocolsKey] {
            guard let protocols = value.arrayValue else {
                return noGetInfoResponse()
            }
            // StdSet<PINUVAuthProtocol>: 1 before 2, each once; unknown protocols are ignored.
            var hasProtocol1 = false
            var hasProtocol2 = false
            for protocolValue in protocols {
                guard let number = protocolValue.unsignedValue else {
                    return noGetInfoResponse()
                }
                if number == Int64(fido.PINUVAuthProtocol.pinProtocol1.rawValue) {
                    hasProtocol1 = true
                } else if number == Int64(fido.PINUVAuthProtocol.pinProtocol2.rawValue) {
                    hasProtocol2 = true
                }
            }
            var pinProtocols = fido.PinProtocolVector()
            if hasProtocol1 {
                pinProtocols.append(consuming: .pinProtocol1)
            }
            if hasProtocol2 {
                pinProtocols.append(consuming: .pinProtocol2)
            }
            fields.pinProtocols = fido.OptionalPinProtocolVector(pinProtocols)
        }

        if let value = responseMap[fido.kCtapAuthenticatorGetInfoMaxCredentialCountInListKey] {
            guard let count = value.unsignedValue else {
                return noGetInfoResponse()
            }
            fields.maxCredentialCountInList = fido.OptionalUInt32(UInt32(truncatingIfNeeded: count))
        }
        if let value = responseMap[fido.kCtapAuthenticatorGetInfoMaxCredentialIdLengthKey] {
            guard let length = value.unsignedValue else {
                return noGetInfoResponse()
            }
            fields.maxCredentialIDLength = fido.OptionalUInt32(UInt32(truncatingIfNeeded: length))
        }

        if let value = responseMap[fido.kCtapAuthenticatorGetInfoTransportsKey] {
            guard let transports = value.arrayValue else {
                return noGetInfoResponse()
            }
            var transportList = fido.TransportVector()
            for transportName in transports {
                guard let string = transportName.stringValue else {
                    return noGetInfoResponse()
                }
                if let transport = Optional(fromCxx: WebCore.convertStringToAuthenticatorTransport(makeWTFString(string))) {
                    transportList.append(consuming: transport)
                }
            }
            fields.transports = fido.OptionalTransportVector(transportList)
        }

        if let value = responseMap[fido.kCtapAuthenticatorGetInfoMinPINLengthKey] {
            guard let length = value.unsignedValue else {
                return noGetInfoResponse()
            }
            fields.minPINLength = fido.OptionalUInt32(UInt32(truncatingIfNeeded: length))
        }

        if let value = responseMap[fido.kCtapAuthenticatorGetInfoRemainingDiscoverableCredentialsKey] {
            guard let count = value.unsignedValue else {
                return noGetInfoResponse()
            }
            fields.remainingDiscoverableCredentials = fido.OptionalUInt32(UInt32(truncatingIfNeeded: count))
        }

        return fido.makeGetInfoResponse(consuming: fields)
    }
}

/// nullopt (makeGetInfoResponse gives it for an empty versions list).
private func noGetInfoResponse() -> fido.OptionalGetInfoResponse {
    fido.makeGetInfoResponse(consuming: fido.GetInfoResponseFields())
}

/// `toString(ProtocolVersion)`'s names.
func protocolVersionName(_ version: fido.ProtocolVersion) -> Swift.String {
    switch version {
    case .ctap2: "FIDO_2_0"
    case .ctap21: "FIDO_2_1"
    case .ctap21Pre: "FIDO_2_1_PRE"
    case .u2f: "U2F_V2"
    default: "UNKNOWN"
    }
}

/// The protocol version a name stands for, against FidoConstants.h's names.
private func protocolVersionFromName(_ name: Swift.String) -> fido.ProtocolVersion {
    if sameCodeUnits(name, FidoName.ctap21Version) {
        return .ctap21
    }
    if sameCodeUnits(name, FidoName.ctap21PreVersion) {
        return .ctap21Pre
    }
    if sameCodeUnits(name, FidoName.ctap2Version) {
        return .ctap2
    }
    if sameCodeUnits(name, FidoName.u2fVersion) {
        return .u2f
    }
    return .unknown
}

#endif // !os(watchOS) && !targetEnvironment(macCatalyst)
