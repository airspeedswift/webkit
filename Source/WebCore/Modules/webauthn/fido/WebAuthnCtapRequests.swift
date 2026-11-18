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

// CTAP2 request encoding (authenticatorMakeCredential, authenticatorGetAssertion, authenticatorGetInfo).

// FidoConstants.h's string constants (ASCIILiteral, which does not import). Each literal is pinned by a static_assert in
// AuthenticatorGetInfoResponse.cpp.
enum FidoName {
    static let residentKey = "rk" // kResidentKeyMapKey
    static let userVerification = "uv" // kUserVerificationMapKey
    static let userPresence = "up" // kUserPresenceMapKey
    static let clientPin = "clientPin" // kClientPinMapKey
    static let platformDevice = "plat" // kPlatformDeviceMapKey
    static let entityId = "id" // kEntityIdMapKey
    static let entityName = "name" // kEntityNameMapKey
    static let displayName = "displayName" // kDisplayNameMapKey
    static let iconUrl = "icon" // kIconUrlMapKey
    static let credentialTypeMap = "type" // kCredentialTypeMapKey
    static let credentialAlgorithm = "alg" // kCredentialAlgorithmMapKey
    static let credentialId = "id" // kCredentialIdKey
    static let credentialType = "type" // kCredentialTypeKey
    static let publicKey = "public-key" // kPublicKey
    static let ctap2Version = "FIDO_2_0" // kCtap2Version
    static let ctap21Version = "FIDO_2_1" // kCtap21Version
    static let ctap21PreVersion = "FIDO_2_1_PRE" // kCtap21PreVersion
    static let u2fVersion = "U2F_V2" // kU2fVersion
    static let format = "fmt" // kFormatKey
    static let attestationStatement = "attStmt" // kAttestationStatementKey
    static let authData = "authData" // kAuthDataKey
    static let extensionHmacSecret = "hmac-secret" // kExtensionHmacSecret
    static let extensionHmacSecretMc = "hmac-secret-mc" // kExtensionHmacSecretMc
}

/// Whether `a` and `b` have the same code units (WTF `String` equality; Swift's `==` compares canonical equivalence).
func sameCodeUnits(_ a: Swift.String, _ b: Swift.String) -> Bool {
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

/// `Vector<String>::contains`.
func containsString(_ strings: [Swift.String], _ string: Swift.String) -> Bool {
    strings.contains { sameCodeUnits($0, string) }
}

/// The bytes of a `BufferSource` (`CBORValue(const BufferSource&)`).
func bufferSourceBytes(_ source: borrowing WebCore.BufferSource) -> [UInt8] {
    let bytes: Span<UInt8> = source.span()
    return makeByteArray(bytes)
}

/// The Swift strings of a `Vector<String>`.
func makeSwiftStrings(_ strings: borrowing fido.StringVector) -> [Swift.String] {
    var result: [Swift.String] = []
    let count = strings.size()
    result.reserveCapacity(count)
    for index in 0..<count {
        result.append(makeSwiftString(strings[index]))
    }
    return result
}

/// The name of a credential type: PublicKeyCredentialType has one value.
private func publicKeyCredentialTypeName(_ type: WebCore.PublicKeyCredentialType) -> Swift.String {
    FidoName.publicKey
}

private func convertRpEntityToCBOR(_ rpEntity: borrowing WebCore.PublicKeyCredentialRpEntity) -> CBOR {
    var rpMap = CBOR.Map(minimumCapacity: 3)
    rpMap.insert(.string(FidoName.entityName), .string(makeSwiftString(rpEntity.name)))
    if !rpEntity.icon.isEmpty() {
        rpMap.insert(.string(FidoName.iconUrl), .string(makeSwiftString(rpEntity.icon)))
    }
    if !rpEntity.id.isEmpty() {
        rpMap.insert(.string(FidoName.entityId), .string(makeSwiftString(rpEntity.id)))
    }
    return .map(rpMap)
}

private func convertUserEntityToCBOR(_ userEntity: borrowing WebCore.PublicKeyCredentialUserEntity) -> CBOR {
    var userMap = CBOR.Map(minimumCapacity: 4)
    userMap.insert(.string(FidoName.entityName), .string(makeSwiftString(userEntity.name)))
    if !userEntity.icon.isEmpty() {
        userMap.insert(.string(FidoName.iconUrl), .string(makeSwiftString(userEntity.icon)))
    }
    userMap.insert(.string(FidoName.entityId), .byteString(bufferSourceBytes(userEntity.id)))
    userMap.insert(.string(FidoName.displayName), .string(makeSwiftString(userEntity.displayName)))
    return .map(userMap)
}

/// A credential parameter as plain values.
private struct CredentialParameter {
    var type: WebCore.PublicKeyCredentialType
    var alg: Int64
}

private func credentialParameters(_ parameters: borrowing fido.CredentialParametersVector) -> [CredentialParameter] {
    var result: [CredentialParameter] = []
    let count = parameters.size()
    result.reserveCapacity(count)
    for index in 0..<count {
        result.append(CredentialParameter(type: parameters[index].type, alg: parameters[index].alg))
    }
    return result
}

private func convertParametersToCBOR(_ parameters: [CredentialParameter]) -> CBOR {
    var array: [CBOR] = []
    array.reserveCapacity(parameters.count)
    for credential in parameters {
        var credentialMap = CBOR.Map(minimumCapacity: 2)
        credentialMap.insert(.string(FidoName.credentialTypeMap), .string(publicKeyCredentialTypeName(credential.type)))
        credentialMap.insert(.string(FidoName.credentialAlgorithm), .integer(credential.alg))
        array.append(.map(credentialMap))
    }
    return .array(array)
}

private func convertDescriptorToCBOR(_ descriptor: borrowing WebCore.PublicKeyCredentialDescriptor) -> CBOR {
    var descriptorMap = CBOR.Map(minimumCapacity: 2)
    descriptorMap.set(.string(FidoName.credentialType), .string(publicKeyCredentialTypeName(descriptor.type)))
    descriptorMap.set(.string(FidoName.credentialId), .byteString(bufferSourceBytes(descriptor.id)))
    return .map(descriptorMap)
}

private func convertDescriptorsToCBOR(_ descriptors: borrowing fido.CredentialDescriptorVector) -> CBOR {
    var array: [CBOR] = []
    let count = descriptors.size()
    array.reserveCapacity(count)
    for index in 0..<count {
        array.append(convertDescriptorToCBOR(descriptors[index]))
    }
    return .array(array)
}

private func trimmedParameters(_ parameters: [CredentialParameter], _ authenticatorSupportedParameters: fido.OptionalCredentialParametersVector) -> [CredentialParameter] {
    // HashSet<int64_t> (its hash table marks empty and deleted slots apart from the keys, so every value is a key).
    var authenticatorSupportedAlgorithms = Set<Int64>()
    if let supported = Optional(fromCxx: authenticatorSupportedParameters) {
        for parameter in credentialParameters(supported) where parameter.type == fido.publicKeyCredentialTypePublicKey() {
            authenticatorSupportedAlgorithms.insert(parameter.alg)
        }
    }

    for parameter in parameters {
        if parameter.type != fido.publicKeyCredentialTypePublicKey() {
            continue
        }
        if authenticatorSupportedAlgorithms.contains(parameter.alg) {
            return [parameter]
        }
        // Support for ES256 required by U2F backwards compatibility.
        if parameter.alg == COSE.ES256 {
            return [parameter]
        }
    }

    // We know the algorithms the authenticator supports and none of those were requested.
    if !authenticatorSupportedAlgorithms.isEmpty {
        return [parameters[0]] // parameters.first(): traps when empty, as Vector::first does.
    }
    return parameters
}

/// The hmac-secret / hmac-secret-mc extension input map.
private func hmacSecretMap(_ parameters: borrowing fido.HmacSecretParameters) -> CBOR {
    // keyAgreement is the platform COSE key map that CBORWriter encoded; embed the map itself.
    guard let keyAgreement = CBOR.read(makeByteArray(parameters.keyAgreement)) else {
        preconditionFailure("HmacSecretParameters.keyAgreement is CBORWriter output")
    }
    var map = CBOR.Map(minimumCapacity: 4)
    map.set(.integer(fido.kHmacSecretKeyAgreementKey), keyAgreement)
    map.set(.integer(fido.kHmacSecretSaltEncKey), .byteString(makeByteArray(parameters.saltEnc)))
    map.set(.integer(fido.kHmacSecretSaltAuthKey), .byteString(makeByteArray(parameters.saltAuth)))
    map.set(.integer(fido.kHmacSecretPinUvAuthProtocolKey), .integer(Int64(parameters.protocol)))
    return .map(map)
}

/// Whether user verification is requested, from the effective requirement and the authenticator's capability.
private func requiresUserVerification(_ effectiveUVRequirement: WebCore.UserVerificationRequirement, _ uvCapability: fido.AuthenticatorSupportedOptions.UserVerificationAvailability) -> Bool {
    switch effectiveUVRequirement {
    case .Required, .Preferred:
        return uvCapability == .supportedAndConfigured
    default:
        return false
    }
}

/// The command byte, then the CBOR of `map` (`CBORWriter::write`, which cannot fail at this depth).
private func encodeRequest(_ command: fido.CtapRequestCommand, _ map: CBOR.Map) -> cbor.CBORValue.BinaryValue {
    guard let request = CBOR.write(.map(map), prefix: command.rawValue, reservingCapacity: 256) else {
        preconditionFailure("CTAP request maps nest less than the writer's limit")
    }
    return makeByteVector(request)
}

extension fido {
    // Entries with no hmac-secret parameters.
    @cxx @implementation public static func encodeMakeCredentialRequestAsCBORForTesting(_ hash: cbor.CBORValue.BinaryValue, _ options: WebCore.PublicKeyCredentialCreationOptions, _ uvCapability: fido.AuthenticatorSupportedOptions.UserVerificationAvailability, _ effectiveUVRequirement: WebCore.UserVerificationRequirement, _ residentKeyAvailability: fido.AuthenticatorSupportedOptions.ResidentKeyAvailability, _ authenticatorSupportedExtensions: fido.StringVector, _ pin: fido.OptionalPinParameters, _ overrideParameters: fido.OptionalCredentialParametersVector, _ overrideExcludeCredentials: fido.OptionalCredentialDescriptorVector) -> cbor.CBORValue.BinaryValue {
        encodeMakeCredentialRequestAsCBOR(hash, options, uvCapability, effectiveUVRequirement, residentKeyAvailability, authenticatorSupportedExtensions, pin, overrideParameters, overrideExcludeCredentials, fido.OptionalHmacSecretParameters())
    }

    @cxx @implementation public static func encodeGetAssertionRequestAsCBORForTesting(_ hash: cbor.CBORValue.BinaryValue, _ options: WebCore.PublicKeyCredentialRequestOptions, _ uvCapability: fido.AuthenticatorSupportedOptions.UserVerificationAvailability, _ effectiveUVRequirement: WebCore.UserVerificationRequirement, _ authenticatorSupportedExtensions: fido.StringVector, _ pin: fido.OptionalPinParameters, _ overrideAllowCredentials: fido.OptionalCredentialDescriptorVector) -> cbor.CBORValue.BinaryValue {
        encodeGetAssertionRequestAsCBOR(hash, options, uvCapability, effectiveUVRequirement, authenticatorSupportedExtensions, pin, overrideAllowCredentials, fido.OptionalHmacSecretParameters())
    }

    @cxx @implementation public static func encodeMakeCredentialRequestAsCBOR(_ hash: cbor.CBORValue.BinaryValue, _ options: WebCore.PublicKeyCredentialCreationOptions, _ uvCapability: fido.AuthenticatorSupportedOptions.UserVerificationAvailability, _ effectiveUVRequirement: WebCore.UserVerificationRequirement, _ residentKeyAvailability: fido.AuthenticatorSupportedOptions.ResidentKeyAvailability, _ authenticatorSupportedExtensions: fido.StringVector, _ pin: fido.OptionalPinParameters, _ overrideParameters: fido.OptionalCredentialParametersVector, _ overrideExcludeCredentials: fido.OptionalCredentialDescriptorVector, _ hmacSecret: fido.OptionalHmacSecretParameters) -> cbor.CBORValue.BinaryValue {
        let supportedExtensions = makeSwiftStrings(authenticatorSupportedExtensions)
        var cborMap = CBOR.Map(minimumCapacity: 9)
        cborMap.set(fido.kCtapMakeCredentialClientDataHashKey, .byteString(makeByteArray(hash)))
        cborMap.set(fido.kCtapMakeCredentialRpKey, convertRpEntityToCBOR(options.rp))
        cborMap.set(fido.kCtapMakeCredentialUserKey, convertUserEntityToCBOR(options.user))
        cborMap.set(fido.kCtapMakeCredentialPubKeyCredParamsKey, convertParametersToCBOR(trimmedParameters(credentialParameters(options.pubKeyCredParams), overrideParameters)))
        if let excludeCredentials = Optional(fromCxx: overrideExcludeCredentials) {
            if !excludeCredentials.isEmpty() {
                cborMap.set(fido.kCtapMakeCredentialExcludeListKey, convertDescriptorsToCBOR(excludeCredentials))
            }
        } else if !options.excludeCredentials.isEmpty() {
            cborMap.set(fido.kCtapMakeCredentialExcludeListKey, convertDescriptorsToCBOR(options.excludeCredentials))
        }

        let extensions = Optional(fromCxx: options.extensions)
        let hmacSecretParameters = Optional(fromCxx: hmacSecret)
        if (!supportedExtensions.isEmpty && extensions != nil) || hmacSecretParameters != nil {
            var extensionsMap = CBOR.Map(minimumCapacity: 3)

            if let extensions {
                if let largeBlobInputs = Optional(fromCxx: extensions.largeBlob), containsString(supportedExtensions, "largeBlob") {
                    var largeBlobMap = CBOR.Map(minimumCapacity: 2)
                    if !largeBlobInputs.support.isNull() {
                        largeBlobMap.set(.string("support"), .string(makeSwiftString(largeBlobInputs.support)))
                    }
                    extensionsMap.set(.string("largeBlob"), .map(largeBlobMap))
                }

                // Convert prf extension to hmac-secret: true for makeCredential
                if extensions.prf.hasValue && containsString(supportedExtensions, FidoName.extensionHmacSecret) {
                    extensionsMap.set(.string(FidoName.extensionHmacSecret), .bool(true))
                }
            }

            // Add hmac-secret-mc extension with encrypted parameters
            if let hmacSecretParameters, containsString(supportedExtensions, FidoName.extensionHmacSecretMc) {
                extensionsMap.set(.string(FidoName.extensionHmacSecretMc), hmacSecretMap(hmacSecretParameters))
            }

            if !extensionsMap.isEmpty {
                cborMap.set(fido.kCtapMakeCredentialExtensionsKey, .map(extensionsMap))
            }
        }

        var optionMap = CBOR.Map(minimumCapacity: 3)
        if let authenticatorSelection = Optional(fromCxx: options.authenticatorSelection) {
            // Resident keys are not supported by default.
            if let residentKey = Optional(fromCxx: authenticatorSelection.residentKey) {
                if residentKey == .Required || (residentKey == .Preferred && residentKeyAvailability == .supported) {
                    optionMap.set(.string(FidoName.residentKey), .bool(true))
                }
            } else if authenticatorSelection.requireResidentKey {
                optionMap.set(.string(FidoName.residentKey), .bool(true))
            }

            // User verification is not required by default.
            if requiresUserVerification(effectiveUVRequirement, uvCapability) {
                optionMap.set(.string(FidoName.userVerification), .bool(true))
            }
        }
        if !optionMap.isEmpty {
            cborMap.set(fido.kCtapMakeCredentialRequestOptionsKey, .map(optionMap))
        }

        if let pin = Optional(fromCxx: pin) {
            cborMap.set(fido.kCtapMakeCredentialPinUvAuthParamKey, .byteString(makeByteArray(pin.auth)))
            cborMap.set(fido.kCtapMakeCredentialPinUvAuthProtocolKey, .integer(Int64(pin.protocol)))
        }

        return encodeRequest(.authenticatorMakeCredential, cborMap)
    }

    @cxx @implementation public static func encodeGetAssertionRequestAsCBOR(_ hash: cbor.CBORValue.BinaryValue, _ options: WebCore.PublicKeyCredentialRequestOptions, _ uvCapability: fido.AuthenticatorSupportedOptions.UserVerificationAvailability, _ effectiveUVRequirement: WebCore.UserVerificationRequirement, _ authenticatorSupportedExtensions: fido.StringVector, _ pin: fido.OptionalPinParameters, _ overrideAllowCredentials: fido.OptionalCredentialDescriptorVector, _ hmacSecret: fido.OptionalHmacSecretParameters) -> cbor.CBORValue.BinaryValue {
        let supportedExtensions = makeSwiftStrings(authenticatorSupportedExtensions)
        var cborMap = CBOR.Map(minimumCapacity: 9)
        cborMap.set(fido.kCtapGetAssertionRpIdKey, .string(makeSwiftString(options.rpId)))
        cborMap.set(fido.kCtapGetAssertionClientDataHashKey, .byteString(makeByteArray(hash)))
        if let allowCredentials = Optional(fromCxx: overrideAllowCredentials) {
            cborMap.set(fido.kCtapGetAssertionAllowListKey, convertDescriptorsToCBOR(allowCredentials))
        } else if !options.allowCredentials.isEmpty() {
            cborMap.set(fido.kCtapGetAssertionAllowListKey, convertDescriptorsToCBOR(options.allowCredentials))
        }

        let extensions = Optional(fromCxx: options.extensions)
        let hmacSecretParameters = Optional(fromCxx: hmacSecret)
        if (!supportedExtensions.isEmpty && extensions != nil) || hmacSecretParameters != nil {
            var extensionsMap = CBOR.Map(minimumCapacity: 3)

            if let extensions {
                if let largeBlobInputs = Optional(fromCxx: extensions.largeBlob), containsString(supportedExtensions, "largeBlob") {
                    var largeBlobMap = CBOR.Map(minimumCapacity: 2)
                    if let read = Optional(fromCxx: largeBlobInputs.read) {
                        largeBlobMap.set(.string("read"), .bool(read))
                    }
                    if let write = Optional(fromCxx: largeBlobInputs.write) {
                        largeBlobMap.set(.string("write"), .byteString(bufferSourceBytes(write)))
                    }
                    extensionsMap.set(.string("largeBlob"), .map(largeBlobMap))
                }
            }

            // Add hmac-secret extension with encrypted salt parameters
            if let hmacSecretParameters, containsString(supportedExtensions, FidoName.extensionHmacSecret) {
                extensionsMap.set(.string(FidoName.extensionHmacSecret), hmacSecretMap(hmacSecretParameters))
            }

            if !extensionsMap.isEmpty {
                cborMap.set(fido.kCtapGetAssertionExtensionsKey, .map(extensionsMap))
            }
        }

        var optionMap = CBOR.Map(minimumCapacity: 3)
        // User verification is not required by default.
        if requiresUserVerification(effectiveUVRequirement, uvCapability) {
            optionMap.set(.string(FidoName.userVerification), .bool(true))
        }
        optionMap.set(.string(FidoName.userPresence), .bool(true))
        cborMap.set(fido.kCtapGetAssertionRequestOptionsKey, .map(optionMap))

        if let pin = Optional(fromCxx: pin) {
            cborMap.set(fido.kCtapGetAssertionPinUvAuthParamKey, .byteString(makeByteArray(pin.auth)))
            cborMap.set(fido.kCtapGetAssertionPinUvAuthProtocolKey, .integer(Int64(pin.protocol)))
        }

        return encodeRequest(.authenticatorGetAssertion, cborMap)
    }

    @cxx @implementation public static func encodeBogusRequestForAuthenticatorSelection() -> cbor.CBORValue.BinaryValue {
        var cborMap = CBOR.Map(minimumCapacity: 9)
        // Vector<uint8_t>(FillWith { }, 0, 32) is size 0 filled with 32s: an empty hash.
        cborMap.set(fido.kCtapMakeCredentialClientDataHashKey, .byteString([]))
        var rpMap = CBOR.Map(minimumCapacity: 3)
        rpMap.insert(.string(FidoName.entityName), .string("notarealwebsite.com"))
        rpMap.insert(.string(FidoName.entityId), .string("notarealwebsite.com"))
        cborMap.set(fido.kCtapMakeCredentialRpKey, .map(rpMap))

        var userMap = CBOR.Map(minimumCapacity: 4)
        userMap.insert(.string(FidoName.entityName), .string("bogus"))
        userMap.insert(.string(FidoName.entityId), .byteString([0]))
        userMap.insert(.string(FidoName.displayName), .string("bogus"))
        cborMap.set(fido.kCtapMakeCredentialUserKey, .map(userMap))

        cborMap.set(fido.kCtapMakeCredentialPubKeyCredParamsKey, convertParametersToCBOR([CredentialParameter(type: fido.publicKeyCredentialTypePublicKey(), alg: COSE.ES256)]))
        cborMap.set(fido.kCtapMakeCredentialPinUvAuthParamKey, .byteString([]))
        cborMap.set(fido.kCtapMakeCredentialPinUvAuthProtocolKey, .integer(pin.kProtocolVersion))

        return encodeRequest(.authenticatorMakeCredential, cborMap)
    }

    @cxx @implementation public static func encodeSilentGetAssertion(_ rpId: WTF.String, _ hash: cbor.CBORValue.BinaryValue, _ credentials: fido.CredentialDescriptorVector, _ pin: fido.OptionalPinParameters) -> cbor.CBORValue.BinaryValue {
        var cborMap = CBOR.Map(minimumCapacity: 9)
        cborMap.set(fido.kCtapGetAssertionRpIdKey, .string(makeSwiftString(rpId)))
        cborMap.set(fido.kCtapGetAssertionClientDataHashKey, .byteString(makeByteArray(hash)))
        cborMap.set(fido.kCtapGetAssertionAllowListKey, convertDescriptorsToCBOR(credentials))

        if let pin = Optional(fromCxx: pin) {
            cborMap.set(fido.kCtapGetAssertionPinUvAuthParamKey, .byteString(makeByteArray(pin.auth)))
            cborMap.set(fido.kCtapGetAssertionPinUvAuthProtocolKey, .integer(Int64(pin.protocol)))
        }

        var optionMap = CBOR.Map(minimumCapacity: 3)
        optionMap.set(.string(FidoName.userPresence), .bool(false))
        cborMap.set(fido.kCtapGetAssertionRequestOptionsKey, .map(optionMap))

        return encodeRequest(.authenticatorGetAssertion, cborMap)
    }

    @cxx @implementation public static func encodeEmptyAuthenticatorRequest(_ cmd: fido.CtapRequestCommand) -> cbor.CBORValue.BinaryValue {
        makeByteVector([cmd.rawValue])
    }
}

/// The body of `fido::encodeAsCBOR(AuthenticatorGetInfoResponse)`, which forwards here.
///
/// `response` is owned by the caller and only read here.
@_expose(Cxx)
func encodeGetInfoResponseAsCBOR(_ response: borrowing fido.AuthenticatorGetInfoResponse) -> cbor.CBORValue.BinaryValue {
    let fields = fido.getInfoResponseFields(response)
    var deviceInfoMap = CBOR.Map(minimumCapacity: 4)

    var versionArray: [CBOR] = []
    for index in 0..<fields.versions.size() {
        versionArray.append(.string(protocolVersionName(fields.versions[index])))
    }
    deviceInfoMap.insert(.integer(fido.kCtapAuthenticatorGetInfoVersionsKey), .array(versionArray))

    if let extensions = Optional(fromCxx: fields.extensions) {
        deviceInfoMap.insert(.integer(fido.kCtapAuthenticatorGetInfoExtensionsKey), .array(makeSwiftStrings(extensions).map { .string($0) }))
    }

    deviceInfoMap.insert(.integer(fido.kCtapAuthenticatorGetInfoAAGUIDKey), .byteString(makeByteArray(fields.aaguid)))

    // The options map.
    var optionMap = CBOR.Map(minimumCapacity: 3)
    optionMap.insert(.string(FidoName.residentKey), .bool(fields.residentKeyAvailability == .supported))
    optionMap.insert(.string(FidoName.userPresence), .bool(fields.userPresenceRequired))
    optionMap.insert(.string(FidoName.platformDevice), .bool(fields.isPlatformDevice))
    switch fields.userVerificationAvailability {
    case .supportedAndConfigured:
        optionMap.insert(.string(FidoName.userVerification), .bool(true))
    case .supportedButNotConfigured:
        optionMap.insert(.string(FidoName.userVerification), .bool(false))
    default:
        break
    }
    switch fields.clientPinAvailability {
    case .supportedAndPinSet:
        optionMap.insert(.string(FidoName.clientPin), .bool(true))
    case .supportedButPinNotSet:
        optionMap.insert(.string(FidoName.clientPin), .bool(false))
    default:
        break
    }
    deviceInfoMap.insert(.integer(fido.kCtapAuthenticatorGetInfoOptionsKey), .map(optionMap))

    if let maxMsgSize = Optional(fromCxx: fields.maxMsgSize) {
        deviceInfoMap.insert(.integer(fido.kCtapAuthenticatorGetInfoMaxMsgSizeKey), .integer(Int64(maxMsgSize)))
    }

    if let pinProtocols = Optional(fromCxx: fields.pinProtocols) {
        var protocols: [CBOR] = []
        for index in 0..<pinProtocols.size() {
            protocols.append(.integer(Int64(pinProtocols[index].rawValue)))
        }
        deviceInfoMap.insert(.integer(fido.kCtapAuthenticatorGetInfoPinUVAuthProtocolsKey), .array(protocols))
    }

    if let infoTransports = Optional(fromCxx: fields.transports) {
        var transports: [CBOR] = []
        for index in 0..<infoTransports.size() {
            transports.append(.string(makeSwiftString(WebCore.toString(infoTransports[index]))))
        }
        deviceInfoMap.insert(.integer(fido.kCtapAuthenticatorGetInfoTransportsKey), .array(transports))
    }

    if let remaining = Optional(fromCxx: fields.remainingDiscoverableCredentials) {
        deviceInfoMap.insert(.integer(fido.kCtapAuthenticatorGetInfoRemainingDiscoverableCredentialsKey), .integer(Int64(remaining)))
    }
    if let minPINLength = Optional(fromCxx: fields.minPINLength) {
        deviceInfoMap.insert(.integer(fido.kCtapAuthenticatorGetInfoMinPINLengthKey), .integer(Int64(minPINLength)))
    }
    if let count = Optional(fromCxx: fields.maxCredentialCountInList) {
        deviceInfoMap.insert(.integer(fido.kCtapAuthenticatorGetInfoMaxCredentialCountInListKey), .integer(Int64(count)))
    }
    if let length = Optional(fromCxx: fields.maxCredentialIDLength) {
        deviceInfoMap.insert(.integer(fido.kCtapAuthenticatorGetInfoMaxCredentialIdLengthKey), .integer(Int64(length)))
    }

    guard let encodedBytes = CBOR.write(.map(deviceInfoMap)) else {
        preconditionFailure("a GetInfo map nests two levels")
    }
    return makeByteVector(encodedBytes)
}

#endif // !os(watchOS) && !targetEnvironment(macCatalyst)
