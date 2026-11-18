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

// U2F (CTAP1) command construction and response conversion.
// https://fidoalliance.org/specs/fido-u2f-v1.2-ps-20170411/fido-u2f-raw-message-formats-v1.2-ps-20170411.html

// In a U2F registration response, the key is in X9.62 format: a 0x04 prefix (uncompressed), then x and y (32 bytes each).
private let u2fUncompressedKey: UInt8 = 0x04
// https://www.w3.org/TR/webauthn/#flags: UP and AT.
private let u2fMakeCredentialFlags: UInt8 = 0b0100_0001
// Authentication response: 1 byte flags, 4 bytes counter, then the signature.
private let u2fCounterIndex = 1
private let u2fSignatureIndex = 5
// X.690 SEQUENCE tag (CommonCryptoDERUtilities.h SequenceMark).
private let derSequenceMark: UInt8 = 0x30

private func u2fRegisterCommand(_ applicationParameter: Span<UInt8>, _ challengeParameter: Span<UInt8>) -> cbor.CBORValue.BinaryValue {
    var sink = fido.WebAuthnByteSink()
    sink.reserve(challengeParameter.count + applicationParameter.count)
    addBytes(&sink, challengeParameter)
    addBytes(&sink, applicationParameter)
    let data = sink.take()
    // P1 asks for user presence, which the test of user presence needs though the spec does not say so.
    return encodeApduCommand(0, fido.U2fApduInstruction.register.rawValue, fido.kP1EnforceUserPresenceAndSign, 0, UInt(apduMaxResponseLength), data.span())
}

private func u2fSignCommand(_ applicationParameter: Span<UInt8>, _ challengeParameter: Span<UInt8>, _ keyHandle: Span<UInt8>, _ checkOnly: Bool) -> fido.OptionalByteVector {
    if keyHandle.count > fido.kMaxKeyHandleLength {
        return fido.OptionalByteVector()
    }
    var sink = fido.WebAuthnByteSink()
    sink.reserve(challengeParameter.count + applicationParameter.count + 1 + keyHandle.count)
    addBytes(&sink, challengeParameter)
    addBytes(&sink, applicationParameter)
    let keyHandleLength = InlineArray<1, UInt8>(repeating: UInt8(keyHandle.count))
    addBytes(&sink, keyHandleLength.span)
    addBytes(&sink, keyHandle)
    let data = sink.take()
    let p1 = checkOnly ? fido.kP1CheckOnly : fido.kP1EnforceUserPresenceAndSign
    return fido.OptionalByteVector(encodeApduCommand(0, fido.U2fApduInstruction.sign.rawValue, p1, 0, UInt(apduMaxResponseLength), data.span()))
}

// CommonCryptoDERUtilities bytesUsedToEncodedLength: 1 for a short form length octet, else the octet minus 127.
@inline(always)
private func derBytesUsedToEncodedLength(_ octet: UInt8) -> Int {
    octet < 128 ? 1 : Int(octet) - 128 + 1
}

// The length of the DER certificate at `start`, header included, or 0. size_t arithmetic.
private func parseX509Length(_ bytes: Span<UInt8>, _ start: Int) -> UInt {
    var offset = start
    if bytes.count <= offset || bytes[offset] != derSequenceMark {
        return 0
    }
    offset += 1
    if bytes.count <= offset {
        return 0
    }
    let sequenceLengthLength = derBytesUsedToEncodedLength(bytes[offset])
    if sequenceLengthLength > MemoryLayout<UInt>.size || bytes.count < offset + sequenceLengthLength {
        return 0
    }
    var sequenceLength: UInt = sequenceLengthLength == 1 ? UInt(bytes[offset]) : 0
    offset += 1
    var i = sequenceLengthLength - 1
    while i != 0 {
        let shift = (i - 1) * 8
        let term: UInt
        if shift >= 32 {
            // Shifting an int by 32 or more bits is undefined; this is the 64-bit shift.
            term = UInt(bytes[offset]) << shift
        } else {
            // The shift is of an int: at 24 a byte of 0x80 or more makes it negative, and adding it to the size_t
            // sign-extends it.
            term = UInt(bitPattern: Int(Int32(bitPattern: UInt32(bytes[offset]) << shift)))
        }
        // size_t addition, which wraps.
        sequenceLength = sequenceLength &+ term
        i -= 1
        offset += 1
    }
    // size_t addition, which wraps.
    return sequenceLength &+ UInt(sequenceLengthLength) &+ 1
}

// The "fido-u2f" attestation statement (x509 certificate then signature, from `offset`), or an empty map.
private func u2fAttestationStatement(_ u2fData: borrowing cbor.CBORValue.BinaryValue, _ bytes: Span<UInt8>, _ offset: Int) -> cbor.CBORValue.MapValue {
    let x509Length = parseX509Length(bytes, offset)
    let (requiredLength, overflow) = x509Length.addingReportingOverflow(UInt(offset))
    if overflow || x509Length == 0 || UInt(bytes.count) < requiredLength {
        return cbor.CBORValue.MapValue()
    }
    // Both fit in Int: requiredLength is at most the size.
    let signatureOffset = Int(requiredLength)
    let x509 = u2fData.subvector(offset, Int(x509Length))
    let signature = u2fData.subvector(signatureOffset, bytes.count - signatureOffset)
    if signature.isEmpty() {
        return cbor.CBORValue.MapValue()
    }
    return u2fAttestationStatementMap(signature, x509)
}

// {"sig": signature, "x5c": [x509]}
private func u2fAttestationStatementMap(_ signature: consuming cbor.CBORValue.BinaryValue, _ x509: consuming cbor.CBORValue.BinaryValue) -> cbor.CBORValue.MapValue {
    var map = CBOR.Map()
    map.set("sig", .byteString(makeByteArray(signature)))
    map.set("x5c", .array([.byteString(makeByteArray(x509))]))
    return CBOR.map(map).makeMapValue()
}

extension fido {
    @cxx @implementation public static func isConvertibleToU2fRegisterCommand(_ request: WebCore.PublicKeyCredentialCreationOptions) -> Bool {
        isConvertibleToU2fRegisterCommandBody(request)
    }

    private static func isConvertibleToU2fRegisterCommandBody(_ request: WebCore.PublicKeyCredentialCreationOptions) -> Bool {
        if let selection = Optional(fromCxx: request.authenticatorSelection), selection.userVerification == .Required || selection.requireResidentKey {
            return false
        }
        let parameters: Span<WebCore.PublicKeyCredentialParameters> = request.pubKeyCredParams.span()
        for index in parameters.indices where parameters[index].alg == COSE.ES256 {
            return true
        }
        return false
    }

    @cxx @implementation public static func isConvertibleToU2fSignCommand(_ request: WebCore.PublicKeyCredentialRequestOptions) -> Bool {
        request.userVerification != .Required && !request.allowCredentials.isEmpty()
    }

    @cxx @implementation public static func convertToU2fRegisterCommand(_ clientDataHash: cbor.CBORValue.BinaryValue, _ request: WebCore.PublicKeyCredentialCreationOptions) -> fido.OptionalByteVector {
        convertToU2fRegisterCommandBody(clientDataHash, request)
    }

    private static func convertToU2fRegisterCommandBody(_ clientDataHash: cbor.CBORValue.BinaryValue, _ request: WebCore.PublicKeyCredentialCreationOptions) -> fido.OptionalByteVector {
        if !isConvertibleToU2fRegisterCommand(request) {
            return fido.OptionalByteVector()
        }
        let rpIdHash = WebCore.produceRpIdHash(request.rp.id)
        return fido.OptionalByteVector(u2fRegisterCommand(rpIdHash.span(), clientDataHash.span()))
    }

    @cxx @implementation public static func convertToU2fCheckOnlySignCommand(_ clientDataHash: cbor.CBORValue.BinaryValue, _ request: WebCore.PublicKeyCredentialCreationOptions, _ keyHandle: WebCore.PublicKeyCredentialDescriptor) -> fido.OptionalByteVector {
        convertToU2fCheckOnlySignCommandBody(clientDataHash, request, keyHandle)
    }

    private static func convertToU2fCheckOnlySignCommandBody(_ clientDataHash: cbor.CBORValue.BinaryValue, _ request: WebCore.PublicKeyCredentialCreationOptions, _ keyHandle: WebCore.PublicKeyCredentialDescriptor) -> fido.OptionalByteVector {
        if keyHandle.type != fido.publicKeyCredentialTypePublicKey() {
            return fido.OptionalByteVector()
        }
        let rpIdHash = WebCore.produceRpIdHash(request.rp.id)
        return u2fSignCommand(rpIdHash.span(), clientDataHash.span(), keyHandle.id.span(), true)
    }

    @cxx @implementation public static func convertToU2fSignCommand(_ clientDataHash: cbor.CBORValue.BinaryValue, _ request: WebCore.PublicKeyCredentialRequestOptions, _ keyHandle: WebCore.BufferSource, _ isAppId: Bool) -> fido.OptionalByteVector {
        convertToU2fSignCommandBody(clientDataHash, request, keyHandle, isAppId)
    }

    private static func convertToU2fSignCommandBody(_ clientDataHash: cbor.CBORValue.BinaryValue, _ request: WebCore.PublicKeyCredentialRequestOptions, _ keyHandle: WebCore.BufferSource, _ isAppId: Bool) -> fido.OptionalByteVector {
        if !isConvertibleToU2fSignCommand(request) {
            return fido.OptionalByteVector()
        }
        if !isAppId {
            let rpIdHash = WebCore.produceRpIdHash(request.rpId)
            return u2fSignCommand(rpIdHash.span(), clientDataHash.span(), keyHandle.span(), false)
        }
        // The extensions are present; dereferencing an empty optional traps.
        let appIdHash = WebCore.produceRpIdHash(Optional(fromCxx: request.extensions)!.appid)
        return u2fSignCommand(appIdHash.span(), clientDataHash.span(), keyHandle.span(), false)
    }

    @cxx @implementation public static func constructBogusU2fRegistrationCommand() -> cbor.CBORValue.BinaryValue {
        let application = Array(fido.kBogusAppParam)
        let challenge = Array(fido.kBogusChallenge)
        return u2fRegisterCommand(application.span, challenge.span)
    }

    @cxx @implementation public static func readU2fRegisterResponse(_ rpId: WTF.String, _ u2fData: cbor.CBORValue.BinaryValue, _ attachment: WebCore.AuthenticatorAttachment, _ transports: fido.TransportVector, _ attestation: WebCore.AttestationConveyancePreference) -> fido.AttestationResponsePtr {
        readU2fRegisterResponseBody(rpId, u2fData, attachment, transports, attestation)
    }

    private static func readU2fRegisterResponseBody(_ rpId: WTF.String, _ u2fData: cbor.CBORValue.BinaryValue, _ attachment: WebCore.AuthenticatorAttachment, _ transports: fido.TransportVector, _ attestation: WebCore.AttestationConveyancePreference) -> fido.AttestationResponsePtr {
        let bytes: Span<UInt8> = u2fData.span()
        let fieldLength = WebCore.ES256FieldElementLength

        // The public key, after the reserved byte.
        var position = fido.kReservedLength
        if bytes.count <= position || bytes[position] != u2fUncompressedKey {
            return fido.AttestationResponsePtr()
        }
        position += 1
        if bytes.count < position + 2 * fieldLength {
            return fido.AttestationResponsePtr()
        }
        let publicKey = WebCore.encodeES256PublicKeyAsCBOR(consuming: u2fData.subvector(position, fieldLength), consuming: u2fData.subvector(position + fieldLength, fieldLength))
        if publicKey.isEmpty() {
            return fido.AttestationResponsePtr()
        }

        // The credential id (key handle), after its length byte.
        if bytes.count <= fido.kU2fKeyHandleLengthOffset {
            return fido.AttestationResponsePtr()
        }
        let credentialIdLength = Int(bytes[fido.kU2fKeyHandleLengthOffset])
        if bytes.count < fido.kU2fKeyHandleOffset + credentialIdLength {
            return fido.AttestationResponsePtr()
        }
        let credentialId = u2fData.subvector(fido.kU2fKeyHandleOffset, credentialIdLength)
        if credentialId.isEmpty() {
            return fido.AttestationResponsePtr()
        }

        var aaguid = cbor.CBORValue.BinaryValue()
        aaguid.reserveCapacity(WebCore.aaguidLength)
        for _ in 0..<WebCore.aaguidLength {
            aaguid.append(consuming: UInt8(0))
        }
        let attestedCredentialData = WebCore.buildAttestedCredentialData(aaguid, credentialId, publicKey)
        if attestedCredentialData.isEmpty() {
            return fido.AttestationResponsePtr()
        }

        // The counter is zero for registrations.
        let authData = WebCore.buildAuthData(rpId, u2fMakeCredentialFlags, 0, attestedCredentialData)

        let statement = u2fAttestationStatement(u2fData, bytes, fido.kU2fKeyHandleOffset + credentialIdLength)
        if statement.empty() {
            return fido.AttestationResponsePtr()
        }

        let attestationObject = WebCore.buildAttestationObject(consuming: authData, consuming: u2fFormat(), consuming: statement, attestation)
        return fido.AttestationResponsePtr(WebCore.AuthenticatorAttestationResponse.create(credentialId, attestationObject, attachment, consuming: transports).get())
    }

    @cxx @implementation public static func readU2fSignResponse(_ rpId: WTF.String, _ keyHandle: WebCore.BufferSource, _ u2fData: cbor.CBORValue.BinaryValue, _ attachment: WebCore.AuthenticatorAttachment) -> fido.AssertionResponsePtr {
        readU2fSignResponseBody(rpId, keyHandle, u2fData, attachment)
    }

    private static func readU2fSignResponseBody(_ rpId: WTF.String, _ keyHandle: WebCore.BufferSource, _ u2fData: cbor.CBORValue.BinaryValue, _ attachment: WebCore.AuthenticatorAttachment) -> fido.AssertionResponsePtr {
        let bytes: Span<UInt8> = u2fData.span()
        if keyHandle.byteLength() == 0 || bytes.count <= u2fSignatureIndex {
            return fido.AssertionResponsePtr()
        }

        let flags = bytes[0]
        // Big-endian counter.
        let counter = UInt32(bytes[u2fCounterIndex]) << 24 | UInt32(bytes[u2fCounterIndex + 1]) << 16
            | UInt32(bytes[u2fCounterIndex + 2]) << 8 | UInt32(bytes[u2fCounterIndex + 3])
        let authData = WebCore.buildAuthData(rpId, flags, counter, cbor.CBORValue.BinaryValue())

        let signature = u2fData.subvector(u2fSignatureIndex, bytes.count - u2fSignatureIndex)
        let keyHandleBytes: Span<UInt8> = keyHandle.span()
        var keyHandleSink = fido.WebAuthnByteSink()
        keyHandleSink.reserve(keyHandleBytes.count)
        addBytes(&keyHandleSink, keyHandleBytes)
        let keyHandleVector = keyHandleSink.take()
        return fido.AssertionResponsePtr(WebCore.AuthenticatorAssertionResponse.create(keyHandleVector, authData, signature, cbor.CBORValue.BinaryValue(), attachment).get())
    }
}

// "fido-u2f"
private func u2fFormat() -> WTF.String {
    makeWTFString("fido-u2f")
}

#endif // !os(watchOS) && !targetEnvironment(macCatalyst)
