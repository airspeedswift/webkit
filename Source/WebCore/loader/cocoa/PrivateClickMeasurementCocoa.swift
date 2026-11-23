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

internal import Foundation
// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// them name (rdar://192229293).
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import WebCore_Private.Core.AttributionTimeToSendData
internal import WebCore_Private.Core.PCMTokens
internal import WebCore_Private.Core.PrivateClickMeasurement
internal import WebCore_Private.Core.PrivateClickMeasurementSwift
internal import wtf.Core.text.WTFString

// The unlinkable and secret tokens of a click measurement, made with CryptoKit's RSA blind signatures.

#if HAVE_RSA_BSSA
/// What an unlinkable token holds, from the bits of PCM::tokenState().
private struct PCMTokenState: OptionSet {
    let rawValue: UInt8

    static let blinder = PCMTokenState(rawValue: 1)
    static let waitingToken = PCMTokenState(rawValue: 2)
    static let readyToken = PCMTokenState(rawValue: 4)
}

extension PCMTokenState {
    init(_ token: borrowing WebCore.PCM.UnlinkableToken) {
        self.init(rawValue: WebCore.PCM.tokenState(token))
    }
}
#endif

/// Makes the token's blinder, waiting token and blinded message value from the server's public key.
///
/// Returns the token, with the error message of the step that failed if one did; that step leaves what it set.
@_expose(Cxx)
func pcmCalculateUnlinkableToken(
    _ serverPublicKeyBase64URL: consuming WTF.String,
    _ token: consuming WebCore.PCM.UnlinkableToken,
    _ attributionReportEndpoint: WebCore.PCM.AttributionReportEndpoint
) -> WebCore.PCM.TokenUpdate {
    #if HAVE_RSA_BSSA
    let side = attributionReportEndpoint == .Destination ? "destination" : "source"
    guard let serverPublicKey = base64URLDecodedData(serverPublicKeyBase64URL) else {
        return tokenFailure(token, "Could not decode the \(side)'s public key data.")
    }

    // Without this pool, the NSData bridged from serverPublicKey stays retained until the thread's pool drains.
    if let message = autoreleasepool(invoking: { Optional(fromCxx: WebCore.PCM.makeBlinder(&token, serverPublicKey)) }) {
        return tokenFailure(token, message)
    }
    if !PCMTokenState(token).contains(.blinder) {
        return tokenFailure(token, "Did not get a \(side) unlinkable token blinder.")
    }

    if let message = Optional(fromCxx: WebCore.PCM.makeWaitingToken(&token)) {
        return tokenFailure(token, message)
    }
    if !PCMTokenState(token).contains(.waitingToken) {
        return tokenFailure(token, "Did not get a \(side) unlinkable token waiting token.")
    }

    WebCore.PCM.setBlindedMessageValue(&token)
    var update = WebCore.PCM.TokenUpdate()
    update.token = consume token
    return update
    #else
    return tokenFailure(token, "Unlinkable tokens are not supported by this platform.")
    #endif
}

/// Activates the token's waiting token with the server's response.
///
/// Returns the token, and its secret token or the error message of the step that failed.
@_expose(Cxx)
func pcmCalculateSecretToken(
    _ serverResponseBase64URL: consuming WTF.String,
    _ token: consuming WebCore.PCM.UnlinkableToken,
    _ attributionReportEndpoint: WebCore.PCM.AttributionReportEndpoint
) -> WebCore.PCM.TokenUpdate {
    #if HAVE_RSA_BSSA
    let side = attributionReportEndpoint == .Destination ? "destination" : "source"
    if !PCMTokenState(token).contains(.waitingToken) {
        return tokenFailure(token, "Did not find a \(side) unlinkable token waiting token.")
    }

    guard let serverResponse = base64URLDecodedData(serverResponseBase64URL) else {
        return tokenFailure(token, "Could not decode \(side) response data.")
    }

    // Without this pool, the NSData bridged from serverResponse stays retained until the thread's pool drains.
    if let message = autoreleasepool(invoking: { Optional(fromCxx: WebCore.PCM.makeReadyToken(&token, serverResponse)) }) {
        return tokenFailure(token, message)
    }
    if !PCMTokenState(token).contains(.readyToken) {
        return tokenFailure(token, "Did not get a \(side) unlinkable token ready token.")
    }

    var update = WebCore.PCM.TokenUpdate()
    WebCore.PCM.setReadyTokenValues(token, &update.secretToken)
    update.token = consume token
    return update
    #else
    return tokenFailure(token, "Unlinkable tokens are not supported by this platform.")
    #endif
}

/// The update that returns `token` with `message`, the error message of the step that failed.
private func tokenFailure(_ token: consuming WebCore.PCM.UnlinkableToken, _ message: consuming WTF.String) -> WebCore.PCM.TokenUpdate {
    var update = WebCore.PCM.TokenUpdate()
    update.token = consume token
    update.errorMessage = .init(message)
    return update
}

private func tokenFailure(_ token: consuming WebCore.PCM.UnlinkableToken, _ message: Swift.String) -> WebCore.PCM.TokenUpdate {
    tokenFailure(token, pcmString(message))
}

#if HAVE_RSA_BSSA
/// base64URLDecode() of a String's characters, as the Data that CryptoKit takes, or nil.
private func base64URLDecodedData(_ string: WTF.String) -> Data? {
    let characters: Span<UInt8> = WebCore.securityPoliciesSpan8(string)
    return characters.isEmpty
        ? base64URLDecodedData(string.checkedSpan16()) : base64URLDecodedData(characters)
}

private func base64URLDecodedData<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ characters: Span<CodeUnit>) -> Data? {
    guard let count = pcmBase64URLDecodedCount(characters) else {
        return nil
    }
    var data = Data(count: count)
    var output = data.mutableSpan
    pcmBase64URLDecode(characters, into: &output)
    return data
}
#endif
