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

// CTAP2 PIN protocol: requests, responses and the hmac-secret extension.
// https://fidoalliance.org/specs/fido-v2.1-ps-20210615/fido-client-to-authenticator-protocol-v2.1-ps-20210615.html#authnrClientPin-cmd

// A protocol 2 shared secret is an HMAC key then an AES key, 32 bytes each; its ciphertexts start with a 16-byte IV.
private let pinSharedKeyLength = 32
private let pinIVLength = 16
// Protocol 1 truncates HMACs to their left 16 bytes, as it does the PIN hash.
private let pinProtocol1AuthLength = 16
// SetPin pads the new PIN with zeros to 64 bytes.
private let pinPaddedLength = 64

@inline(always)
private func appendBytes(_ out: inout cbor.CBORValue.BinaryValue, _ bytes: Span<UInt8>) {
    for index in bytes.indices {
        out.append(consuming: bytes[index])
    }
}

// decodeResponseMap: a success status byte, then a CBOR map.
private func pinResponseMap(_ buffer: borrowing cbor.CBORValue.BinaryValue) -> CBOR.Map? {
    let bytes: Span<UInt8> = buffer.span()
    if bytes.count <= fido.kResponseCodeLength || bytes[0] != fido.CtapDeviceResponseCode.success.rawValue {
        return nil
    }
    return CBOR.read(bytes.extracting(fido.kResponseCodeLength..<bytes.count))?.mapValue
}

private func decryptForProtocol(_ pinProtocol: fido.PINUVAuthProtocol, _ key: borrowing WebCore.CryptoKeyAES, _ ciphertext: borrowing cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue {
    if pinProtocol == .pinProtocol2 {
        // Protocol 2: the IV, then the ciphertext.
        let size = ciphertext.size()
        if size < pinIVLength {
            return cbor.CBORValue.BinaryValue()
        }
        return fido.pin.pinAESCBCDecrypt(key, ciphertext.subvector(0, pinIVLength), ciphertext.subvector(pinIVLength, size - pinIVLength))
    }
    // Protocol 1: a zero IV.
    return fido.pin.pinAESCBCDecrypt(key, cbor.CBORValue.BinaryValue(), ciphertext)
}

private func encryptForProtocol(_ pinProtocol: fido.PINUVAuthProtocol, _ key: borrowing WebCore.CryptoKeyAES, _ plaintext: borrowing cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue {
    if pinProtocol == .pinProtocol2 {
        // Protocol 2: a random IV, prepended.
        var output = fido.pin.pinRandomIV()
        let ciphertext = fido.pin.pinAESCBCEncrypt(key, output, plaintext)
        output.reserveCapacity(output.size() + ciphertext.size())
        appendBytes(&output, ciphertext.span())
        return output
    }
    return fido.pin.pinAESCBCEncrypt(key, cbor.CBORValue.BinaryValue(), plaintext)
}

private func authenticateForProtocol(_ pinProtocol: fido.PINUVAuthProtocol, _ key: borrowing WebCore.CryptoKeyHMAC, _ message: borrowing cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue {
    var signature = fido.pin.pinHMACSign(key, message)
    if pinProtocol == .pinProtocol1 {
        signature.shrink(pinProtocol1AuthLength)
    }
    return signature
}

private func bytesOf(_ characters: Span<UInt8>, capacity: Int = 0) -> cbor.CBORValue.BinaryValue {
    var bytes = cbor.CBORValue.BinaryValue()
    bytes.reserveCapacity(max(capacity, characters.count))
    for index in characters.indices {
        bytes.append(consuming: characters[index])
    }
    return bytes
}

// CTAP 2.1 6.5.6 (protocol 1: SHA-256) and 6.5.7 (protocol 2: HKDF-SHA-256 for the HMAC key, then the AES key).
// Empty when a step fails.
private func deriveProtocolSharedSecret(_ pinProtocol: fido.PINUVAuthProtocol, _ ecdhResult: borrowing cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue {
    switch pinProtocol {
    case .pinProtocol1:
        return fido.pin.pinSHA256(ecdhResult)
    case .pinProtocol2:
        var sharedSecret = fido.pin.pinHKDF(ecdhResult, .HMACKey)
        if sharedSecret.isEmpty() {
            return sharedSecret
        }
        let aesKey = fido.pin.pinHKDF(ecdhResult, .AESKey)
        if aesKey.isEmpty() {
            return aesKey
        }
        sharedSecret.reserveCapacity(2 * pinSharedKeyLength)
        appendBytes(&sharedSecret, aesKey.span())
        return sharedSecret
    default:
        return cbor.CBORValue.BinaryValue()
    }
}

private func importAESKey(_ material: consuming cbor.CBORValue.BinaryValue) -> fido.CryptoKeyAESPtr {
    WebCore.CryptoKeyAES.importRaw(.AES_CBC, consuming: material, true, WebCore.CryptoKeyUsageBitmap(WebCore.CryptoKeyUsageEncrypt | WebCore.CryptoKeyUsageDecrypt))
}

private func importHMACKey(_ material: consuming cbor.CBORValue.BinaryValue) -> fido.CryptoKeyHMACPtr {
    let lengthInBits = material.size() * 8
    return WebCore.CryptoKeyHMAC.importRaw(lengthInBits, .SHA_256, consuming: material, true, WebCore.CryptoKeyUsageBitmap(WebCore.CryptoKeyUsageSign))
}

// The halves of the shared secret a protocol uses for HMAC and AES keys: protocol 2 splits it, protocol 1 uses it whole.
private func sharedSecretHalves(_ pinProtocol: fido.PINUVAuthProtocol, _ sharedSecret: borrowing cbor.CBORValue.BinaryValue) -> (hmac: cbor.CBORValue.BinaryValue, aes: cbor.CBORValue.BinaryValue) {
    if pinProtocol == .pinProtocol2 {
        let size = sharedSecret.size()
        return (sharedSecret.subvector(0, pinSharedKeyLength), sharedSecret.subvector(size - pinSharedKeyLength, pinSharedKeyLength))
    }
    return (copy sharedSecret, copy sharedSecret)
}

// encodePinCommand: the authenticatorClientPin command byte, then the CBOR map of protocol, subcommand and `additional`.
private func encodePinCommand(_ subcommand: fido.pin.Subcommand, _ pinProtocol: fido.PINUVAuthProtocol, _ additional: (inout CBOR.Map) -> Void = { _ in }) -> cbor.CBORValue.BinaryValue {
    var map = CBOR.Map()
    map.insert(.integer(Int64(fido.pin.RequestKey.protocol.rawValue)), .integer(Int64(pinProtocol.rawValue)))
    map.insert(.integer(Int64(fido.pin.RequestKey.subcommand.rawValue)), .integer(Int64(subcommand.rawValue)))
    additional(&map)

    // A map this shallow always writes.
    let serialized = CBOR.write(.map(map))!
    var request = cbor.CBORValue.BinaryValue()
    request.reserveCapacity(1 + serialized.count)
    request.append(consuming: fido.CtapRequestCommand.authenticatorClientPin.rawValue)
    appendBytes(&request, serialized.span)
    return request
}

private func requestKey(_ key: fido.pin.RequestKey) -> CBOR {
    .integer(Int64(key.rawValue))
}

private func coseKeyCBOR(_ coseKey: borrowing cbor.CBORValue.MapValue) -> CBOR {
    var value = cbor.CBORValue.cloneOfMap(coseKey)
    return CBOR(taking: &value)
}

// KeyAgreementResponse::parseFromCOSE: a P-256 ECDH COSE key (RFC 8152 7.1, 13.1.1).
private func parseKeyAgreementCOSE(_ coseKey: CBOR.Map) -> fido.CryptoKeyECPtr {
    if coseKey[COSE.kty]?.integerValue != COSE.EC2 || coseKey[COSE.alg]?.integerValue != COSE.ECDH256 || coseKey[COSE.crv]?.integerValue != COSE.P_256 {
        return fido.CryptoKeyECPtr()
    }
    guard let x = coseKey[COSE.x]?.byteStringValue, let y = coseKey[COSE.y]?.byteStringValue else {
        return fido.CryptoKeyECPtr()
    }
    let rawPublicKey = WebCore.encodeRawPublicKey(makeByteVector(x), makeByteVector(y))
    return WebCore.CryptoKeyEC.importRaw(.ECDH, makeWTFString("P-256"), consuming: rawPublicKey, true, WebCore.CryptoKeyUsageBitmap(WebCore.CryptoKeyUsageDeriveBits))
}

extension fido.pin {
    @cxx @implementation public static func encodeCOSEPublicKey(_ key: cbor.CBORValue.BinaryValue) -> cbor.CBORValue.MapValue {
        encodeCOSEPublicKeyBody(key)
    }

    private static func encodeCOSEPublicKeyBody(_ key: cbor.CBORValue.BinaryValue) -> cbor.CBORValue.MapValue {
        // The key is 65 bytes; a shorter one traps reading x or y.
        let bytes: Span<UInt8> = key.span()
        let fieldLength = WebCore.ES256FieldElementLength
        var map = CBOR.Map()
        map.set(COSE.kty, .integer(COSE.EC2))
        map.set(COSE.alg, .integer(COSE.ECDH256))
        map.set(COSE.crv, .integer(COSE.P_256))
        map.set(COSE.x, .byteString(makeByteArray(bytes.extracting(1..<(1 + fieldLength)))))
        map.set(COSE.y, .byteString(makeByteArray(bytes.extracting((1 + fieldLength)..<(1 + 2 * fieldLength)))))
        return CBOR.map(map).makeMapValue()
    }

    @cxx @implementation public static func validatePinAsUTF8(_ pin: WTF.String) -> WTF.UTF8CString {
        // The CTAP2 four-character minimum, counted in UTF-16 code units.
        if pin.length() < 4 {
            return WTF.UTF8CString()
        }
        let utf8 = pin.utf8()
        let length = fido.utf8CStringLength(utf8)
        if length < fido.pin.kMinBytes || length > fido.pin.kMaxBytes {
            return WTF.UTF8CString()
        }
        return utf8
    }

    @cxx @implementation public static func parseRetriesResponse(_ buffer: cbor.CBORValue.BinaryValue) -> fido.pin.RetriesParseResult {
        var result = fido.pin.RetriesParseResult()
        guard let retries = pinResponseMap(buffer)?[Int64(fido.pin.ResponseKey.retries.rawValue)]?.unsignedValue else {
            return result
        }
        // Non-negative: unsignedValue holds only CBOR unsigned integers.
        result.retries = UInt64(retries)
        result.valid = true
        return result
    }

    @cxx @implementation public static func parseKeyAgreementResponse(_ buffer: cbor.CBORValue.BinaryValue) -> fido.CryptoKeyECPtr {
        guard let coseKey = pinResponseMap(buffer)?[Int64(fido.pin.ResponseKey.keyAgreement.rawValue)]?.mapValue else {
            return fido.CryptoKeyECPtr()
        }
        return parseKeyAgreementCOSE(coseKey)
    }

    @cxx @implementation public static func parseTokenResponse(_ pinProtocol: fido.PINUVAuthProtocol, _ sharedKey: borrowing WebCore.CryptoKeyAES, _ buffer: cbor.CBORValue.BinaryValue) -> fido.CryptoKeyHMACPtr {
        guard let encryptedToken = pinResponseMap(buffer)?[Int64(fido.pin.ResponseKey.pinToken.rawValue)]?.byteStringValue else {
            return fido.CryptoKeyHMACPtr()
        }
        let token = decryptForProtocol(pinProtocol, sharedKey, makeByteVector(encryptedToken))
        if token.isEmpty() {
            return fido.CryptoKeyHMACPtr()
        }
        return importHMACKey(token)
    }

    @cxx @implementation public static func tokenPinAuth(_ pinProtocol: fido.PINUVAuthProtocol, _ token: borrowing WebCore.CryptoKeyHMAC, _ clientDataHash: cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue {
        authenticateForProtocol(pinProtocol, token, clientDataHash)
    }

    @cxx @implementation public static func encodeAsCBOR(_ request: fido.pin.RetriesRequest) -> cbor.CBORValue.BinaryValue {
        encodePinCommand(.getRetries, request.`protocol`)
    }

    @cxx @implementation public static func encodeAsCBOR(_ request: fido.pin.KeyAgreementRequest) -> cbor.CBORValue.BinaryValue {
        encodePinCommand(.getKeyAgreement, request.`protocol`)
    }
}

// What a PIN request is made of, before the C++ request object (a move-only optional) or its encoding is made of it.
private struct SetPinInputs {
    var sharedKey: fido.CryptoKeyAESPtr
    var rawPublicKey: cbor.CBORValue.BinaryValue
    var newPinEnc: cbor.CBORValue.BinaryValue
    var pinUvAuthParam: cbor.CBORValue.BinaryValue
}

private struct TokenInputs {
    var sharedKey: fido.CryptoKeyAESPtr
    var rawPublicKey: cbor.CBORValue.BinaryValue
    var pinHash: cbor.CBORValue.BinaryValue
}

private struct HmacSecretInputs {
    var sharedKey: fido.CryptoKeyAESPtr
    var rawPublicKey: cbor.CBORValue.BinaryValue
    var saltEnc: cbor.CBORValue.BinaryValue
    var saltAuth: cbor.CBORValue.BinaryValue
}

private func setPinInputs(_ pinProtocol: fido.PINUVAuthProtocol, _ newPin: WTF.String, _ peerKey: borrowing WebCore.CryptoKeyEC) -> SetPinInputs? {
    let validated = fido.pin.validatePinAsUTF8(newPin)
    if fido.utf8CStringLength(validated) == 0 {
        return nil
    }

    // CTAP2 5.5.4, getting sharedSecret from the authenticator: a P-256 key pair, ECDH, the protocol's KDF.
    let agreement = fido.pin.pinKeyAgreement(peerKey)
    precondition(agreement.generated, "P-256 key pair generation failed")
    if !agreement.derived {
        return nil
    }
    let sharedSecret = deriveProtocolSharedSecret(pinProtocol, agreement.sharedSecret)
    if sharedSecret.isEmpty() {
        return nil
    }
    let halves = sharedSecretHalves(pinProtocol, sharedSecret)
    let sharedKeyPtr = importAESKey(halves.aes)
    let sharedKey = sharedKeyPtr.get()!
    precondition(agreement.exported, "P-256 public key export failed")

    var paddedPin = bytesOf(validated.span(), capacity: pinPaddedLength)
    while paddedPin.size() < pinPaddedLength {
        paddedPin.append(consuming: UInt8(0))
    }

    let hmacKey = importHMACKey(halves.hmac).get()!
    let newPinEnc = encryptForProtocol(pinProtocol, sharedKey, paddedPin)
    let pinUvAuthParam = authenticateForProtocol(pinProtocol, hmacKey, newPinEnc)
    return SetPinInputs(sharedKey: sharedKeyPtr, rawPublicKey: agreement.rawPublicKey, newPinEnc: newPinEnc, pinUvAuthParam: pinUvAuthParam)
}

private func tokenInputs(_ pinProtocol: fido.PINUVAuthProtocol, _ pin: WTF.UTF8CString, _ peerKey: borrowing WebCore.CryptoKeyEC) -> TokenInputs? {
    // CTAP2 5.5.4, as above.
    let agreement = fido.pin.pinKeyAgreement(peerKey)
    precondition(agreement.generated, "P-256 key pair generation failed")
    if !agreement.derived {
        return nil
    }
    let sharedSecret = deriveProtocolSharedSecret(pinProtocol, agreement.sharedSecret)
    if sharedSecret.isEmpty() {
        return nil
    }
    let sharedKeyPtr = importAESKey(sharedSecretHalves(pinProtocol, sharedSecret).aes)
    _ = sharedKeyPtr.get()!
    precondition(agreement.exported, "P-256 public key export failed")

    // The left 16 bytes of the PIN's SHA-256.
    var pinHash = fido.pin.pinSHA256(bytesOf(pin.span()))
    pinHash.shrink(pinProtocol1AuthLength)
    return TokenInputs(sharedKey: sharedKeyPtr, rawPublicKey: agreement.rawPublicKey, pinHash: pinHash)
}

private func hmacSecretInputs(_ pinProtocol: fido.PINUVAuthProtocol, _ salt1: cbor.CBORValue.BinaryValue, _ salt2: fido.OptionalByteVector, _ peerKey: fido.CryptoKeyECPtr) -> HmacSecretInputs? {
    let secondSalt = Optional(fromCxx: salt2)
    if salt1.size() != pinSharedKeyLength {
        return nil
    }
    if let secondSalt, secondSalt.size() != pinSharedKeyLength {
        return nil
    }

    let agreement = fido.pin.pinKeyAgreement(peerKey.get()!)
    if !agreement.generated || !agreement.derived {
        return nil
    }
    let sharedSecret = deriveProtocolSharedSecret(pinProtocol, agreement.sharedSecret)
    if sharedSecret.isEmpty() {
        return nil
    }
    let halves = sharedSecretHalves(pinProtocol, sharedSecret)
    let sharedKeyPtr = importAESKey(halves.aes)
    guard let sharedKey = sharedKeyPtr.get(), agreement.exported else {
        return nil
    }

    var salts = salt1
    if let secondSalt {
        salts.reserveCapacity(salts.size() + secondSalt.size())
        appendBytes(&salts, secondSalt.span())
    }
    let saltEnc = encryptForProtocol(pinProtocol, sharedKey, salts)
    guard let hmacKey = importHMACKey(halves.hmac).get() else {
        return nil
    }
    let saltAuth = authenticateForProtocol(pinProtocol, hmacKey, saltEnc)
    return HmacSecretInputs(sharedKey: sharedKeyPtr, rawPublicKey: agreement.rawPublicKey, saltEnc: saltEnc, saltAuth: saltAuth)
}

private func encodeTokenCommand(_ pinProtocol: fido.PINUVAuthProtocol, _ sharedKey: borrowing WebCore.CryptoKeyAES, _ coseKey: CBOR, _ pinHash: borrowing cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue {
    let encryptedPin = encryptForProtocol(pinProtocol, sharedKey, pinHash)
    return encodePinCommand(.getPinToken, pinProtocol) { map in
        map.insert(requestKey(.keyAgreement), coseKey)
        map.insert(requestKey(.pinHashEnc), .byteString(makeByteArray(encryptedPin)))
    }
}

private func encodeSetPinCommand(_ pinProtocol: fido.PINUVAuthProtocol, _ coseKey: CBOR, _ newPinEnc: borrowing cbor.CBORValue.BinaryValue, _ pinUvAuthParam: borrowing cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue {
    let newPinEnc = makeByteArray(newPinEnc)
    let pinUvAuthParam = makeByteArray(pinUvAuthParam)
    return encodePinCommand(.setPin, pinProtocol) { map in
        map.insert(requestKey(.keyAgreement), coseKey)
        map.insert(requestKey(.newPinEnc), .byteString(newPinEnc))
        map.insert(requestKey(.pinAuth), .byteString(pinUvAuthParam))
    }
}

extension fido.pin.SetPinRequest {
    @cxx @implementation public static func tryCreate(_ pinProtocol: fido.PINUVAuthProtocol, _ newPin: WTF.String, _ peerKey: borrowing WebCore.CryptoKeyEC) -> fido.OptionalSetPinRequest {
        guard let inputs = setPinInputs(pinProtocol, newPin, peerKey) else {
            return fido.OptionalSetPinRequest()
        }
        return fido.pin.SetPinRequest.makeOptional(inputs.sharedKey.get()!, consuming: fido.pin.encodeCOSEPublicKey(inputs.rawPublicKey), consuming: inputs.newPinEnc, consuming: inputs.pinUvAuthParam, pinProtocol)
    }
}

extension fido.pin.TokenRequest {
    @cxx @implementation public static func tryCreate(_ pinProtocol: fido.PINUVAuthProtocol, _ pin: WTF.UTF8CString, _ peerKey: borrowing WebCore.CryptoKeyEC) -> fido.OptionalTokenRequest {
        tryCreateBody(pinProtocol, pin, peerKey)
    }

    private static func tryCreateBody(_ pinProtocol: fido.PINUVAuthProtocol, _ pin: WTF.UTF8CString, _ peerKey: borrowing WebCore.CryptoKeyEC) -> fido.OptionalTokenRequest {
        guard let inputs = tokenInputs(pinProtocol, pin, peerKey) else {
            return fido.OptionalTokenRequest()
        }
        return fido.pin.TokenRequest.makeOptional(inputs.sharedKey.get()!, consuming: fido.pin.encodeCOSEPublicKey(inputs.rawPublicKey), consuming: inputs.pinHash, pinProtocol)
    }
}

extension fido.pin.HmacSecretRequest {
    @cxx @implementation public static func create(_ pinProtocol: fido.PINUVAuthProtocol, _ salt1: cbor.CBORValue.BinaryValue, _ salt2: fido.OptionalByteVector, _ peerKey: fido.CryptoKeyECPtr) -> fido.OptionalHmacSecretRequest {
        guard let inputs = hmacSecretInputs(pinProtocol, salt1, salt2, peerKey) else {
            return fido.OptionalHmacSecretRequest()
        }
        return fido.pin.HmacSecretRequest.makeOptional(inputs.sharedKey.get()!, consuming: fido.pin.encodeCOSEPublicKey(inputs.rawPublicKey), consuming: inputs.saltEnc, consuming: inputs.saltAuth, pinProtocol)
    }
}

// The PIN requests as WebKit's Swift needs them: the CBOR command and what the C++ request holds on to, in plain types.
extension fido.pin {
    @cxx @implementation public static func tokenRequestParts(_ pinProtocol: fido.PINUVAuthProtocol, _ pin: WTF.UTF8CString, _ peerKey: borrowing WebCore.CryptoKeyEC) -> fido.pin.TokenRequestParts {
        var parts = fido.pin.TokenRequestParts()
        guard let inputs = tokenInputs(pinProtocol, pin, peerKey) else {
            return parts
        }
        parts.command = encodeTokenCommand(pinProtocol, inputs.sharedKey.get()!, coseKeyCBOR(fido.pin.encodeCOSEPublicKey(inputs.rawPublicKey)), inputs.pinHash)
        parts.sharedKey = inputs.sharedKey
        return parts
    }

    @cxx @implementation public static func setPinRequestParts(_ pinProtocol: fido.PINUVAuthProtocol, _ newPin: WTF.String, _ peerKey: borrowing WebCore.CryptoKeyEC) -> fido.pin.SetPinRequestParts {
        var parts = fido.pin.SetPinRequestParts()
        guard let inputs = setPinInputs(pinProtocol, newPin, peerKey) else {
            return parts
        }
        parts.command = encodeSetPinCommand(pinProtocol, coseKeyCBOR(fido.pin.encodeCOSEPublicKey(inputs.rawPublicKey)), inputs.newPinEnc, inputs.pinUvAuthParam)
        parts.pinAuth = inputs.pinUvAuthParam
        parts.valid = true
        return parts
    }

    @cxx @implementation public static func hmacSecretRequestParts(_ pinProtocol: fido.PINUVAuthProtocol, _ salt1: cbor.CBORValue.BinaryValue, _ salt2: fido.OptionalByteVector, _ peerKey: fido.CryptoKeyECPtr) -> fido.pin.HmacSecretRequestParts {
        var parts = fido.pin.HmacSecretRequestParts()
        guard let inputs = hmacSecretInputs(pinProtocol, salt1, salt2, peerKey) else {
            return parts
        }
        // A COSE key map is two levels at most, so the write cannot fail.
        parts.parameters.keyAgreement = makeByteVector(CBOR.write(coseKeyCBOR(fido.pin.encodeCOSEPublicKey(inputs.rawPublicKey)))!)
        parts.parameters.saltEnc = inputs.saltEnc
        parts.parameters.saltAuth = inputs.saltAuth
        parts.parameters.`protocol` = Int32(pinProtocol.rawValue)
        parts.sharedKey = inputs.sharedKey
        parts.pinProtocol = pinProtocol
        parts.valid = true
        return parts
    }
}

// HmacSecretResponse::parse's body: the decrypted output, or nil where parse gives nullopt.
private func decryptHmacSecretOutput(_ pinProtocol: fido.PINUVAuthProtocol, _ sharedKey: borrowing WebCore.CryptoKeyAES, _ encryptedOutput: borrowing cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue? {
    let output = decryptForProtocol(pinProtocol, sharedKey, encryptedOutput)
    let size = output.size()
    // One or two 32-byte outputs.
    if size != pinSharedKeyLength && size != 2 * pinSharedKeyLength {
        return nil
    }
    return output
}

/// The hmac-secret extension output for the CTAP response converters, as `HmacSecretResponse::parse` gives it.
func hmacSecretOutput(_ pinProtocol: fido.PINUVAuthProtocol, _ sharedKey: WebCore.CryptoKeyAES, _ encryptedOutput: [UInt8]) -> [UInt8]? {
    decryptHmacSecretOutput(pinProtocol, sharedKey, makeByteVector(encryptedOutput)).map { makeByteArray($0) }
}

extension fido.pin.HmacSecretResponse {
    @cxx @implementation public static func parse(_ pinProtocol: fido.PINUVAuthProtocol, _ sharedKey: borrowing WebCore.CryptoKeyAES, _ encryptedOutput: cbor.CBORValue.BinaryValue) -> fido.OptionalHmacSecretResponse {
        guard let output = decryptHmacSecretOutput(pinProtocol, sharedKey, encryptedOutput) else {
            return fido.OptionalHmacSecretResponse()
        }
        return fido.OptionalHmacSecretResponse(fido.pin.HmacSecretResponse(consuming: output))
    }
}

/// The definition of `fido::pin::KeyAgreementResponse::parseFromCOSE`, which forwards here.
///
/// `coseKey` is owned by the caller and only read here.
@_expose(Cxx)
func parseKeyAgreementFromCOSE(_ coseKey: borrowing cbor.CBORValue.MapValue) -> fido.CryptoKeyECPtr {
    guard let map = coseKeyCBOR(coseKey).mapValue else {
        return fido.CryptoKeyECPtr()
    }
    return parseKeyAgreementCOSE(map)
}

/// The body of `fido::pin::encodeAsCBOR(const TokenRequest&)`, which forwards here.
///
/// `request` is owned by the caller of `encodeAsCBOR`, which keeps it alive and unchanged for the call; it arrives by
/// `const&` and is passed on as one. It is read through `sharedKey()`, `cbor::CBORValue::cloneOfMap(m_coseKey)` and
/// `m_pinHash`. The other C++ functions called while it is live, `pinRandomIV` and `pinAESCBCEncrypt`, take the key
/// and copied bytes and reach nothing else. `encodeAsCBOR` clears `m_coseKey` after this function returns.
@_expose(Cxx)
func encodeTokenRequestAsCBOR(_ request: borrowing fido.pin.TokenRequest) -> cbor.CBORValue.BinaryValue {
    request.encodedAsCBOR()
}

// SWIFT_PRIVATE_FILEID opens the private members to extensions in this file only.
extension fido.pin.TokenRequest {
    fileprivate func encodedAsCBOR() -> cbor.CBORValue.BinaryValue {
        encodeTokenCommand(m_protocol, sharedKey(), coseKeyCBOR(m_coseKey), m_pinHash)
    }
}

/// The body of `fido::pin::encodeAsCBOR(SetPinRequest)`, which forwards here.
///
/// `request` is `encodeAsCBOR`'s by-value parameter, which it owns and keeps alive for the call; it is passed on by
/// `const&`. It is read through `cbor::CBORValue::cloneOfMap(m_coseKey)` and its byte-vector members, which are copied.
/// No other C++ function is called while it is live.
@_expose(Cxx)
func encodeSetPinRequestAsCBOR(_ request: borrowing fido.pin.SetPinRequest) -> cbor.CBORValue.BinaryValue {
    request.encodedAsCBOR()
}

extension fido.pin.SetPinRequest {
    fileprivate func encodedAsCBOR() -> cbor.CBORValue.BinaryValue {
        encodeSetPinCommand(m_protocol, coseKeyCBOR(m_coseKey), m_newPinEnc, m_pinUvAuthParam)
    }
}

#endif // !os(watchOS) && !targetEnvironment(macCatalyst)
