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

// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// them name (rdar://192229293).
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import WebCore_Private.Core.AttributionSecondsUntilSendData
internal import WebCore_Private.Core.AttributionTimeToSendData
internal import WebCore_Private.Core.AttributionTriggerData
internal import WebCore_Private.Core.EphemeralNonce
internal import WebCore_Private.Core.PCMTokens
internal import WebCore_Private.Core.PrivateClickMeasurement
internal import WebCore_Private.Core.PrivateClickMeasurementSwift
internal import WebCore_Private.Core.RegistrableDomain
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import wtf.Core.CryptographicallyRandomNumber
internal import wtf.Core.JSONValues
internal import wtf.Core.URL
internal import wtf.Core.text.WTFString

// The URLs, JSON and parsing of a click measurement. PrivateClickMeasurement.cpp calls the exposed pcm* functions with the
// fields they read.

private let privateClickMeasurementTriggerAttributionPath = "/.well-known/private-click-measurement/trigger-attribution/"
private let privateClickMeasurementTokenSignaturePath = "/.well-known/private-click-measurement/sign-unlinkable-token/"
private let privateClickMeasurementTokenPublicKeyPath = "/.well-known/private-click-measurement/get-token-public-key/"
private let privateClickMeasurementReportAttributionPath = "/.well-known/private-click-measurement/report-attribution/"
private let privateClickMeasurementToSKAdNetworkURLPrefix = "https://apps.apple.com/app/id"

private let privateClickMeasurementAttributionTriggerDataPathSegmentSize = 2
private let privateClickMeasurementPriorityPathSegmentSize = 2

private let privateClickMeasurementVersion: Int32 = 3

// AttributionTriggerData::MaxEntropy and AttributionTriggerData::Priority::MaxEntropy, which Swift does not import;
// PrivateClickMeasurement.cpp static_asserts them.
private let triggerDataMaxEntropy: UInt8 = 15
private let priorityMaxEntropy: UInt8 = 63

private let ephemeralNonceRequiredNumberOfBytes = 16

/// The String of an ASCII literal.
func pcmString(_ literal: Swift.String) -> WTF.String {
    WTF.makeStringFromLatin1Characters(literal.utf8.span)
}

extension WebCore.PrivateClickMeasurement {
    /// How long a click is kept before it is attributed.
    @cxx
    @implementation
    public static func maxAge() -> WTF.Seconds {
        WTF.Seconds(7 * 24 * 60 * 60)
    }

    /// The trigger data of a redirect to a trigger-attribution path, or why the redirect does not trigger an attribution:
    /// the null String when its path is not a trigger-attribution path.
    @cxx
    @implementation
    public static func parseAttributionRequest(
        _ redirectURL: WTF.URL
    ) -> WebCore.PCM.AttributionTriggerDataOrError {
        let string = WebCore.PCM.urlString(redirectURL)
        let characters: Span<UInt8> = WebCore.securityPoliciesSpan8(string)
        let result =
            characters.isEmpty
            ? pcmParseAttributionRequest(string.checkedSpan16(), redirectURL)
            : pcmParseAttributionRequest(characters, redirectURL)
        switch consume result {
        case .data(let data):
            return WebCore.PCM.attributionTriggerDataResult(consume data)
        case .error(let message):
            return WebCore.PCM.attributionTriggerDataError(consume message)
        }
    }

    /// The get-token-public-key URL of the registrable domain, or nil when it is empty.
    @cxx
    @implementation
    public static func tokenPublicKeyURL(_ registrableDomain: WebCore.RegistrableDomain) -> WebCore.PCM.OptionalURL {
        if registrableDomain.isEmpty() {
            return WebCore.PCM.OptionalURL()
        }
        return WebCore.PCM.OptionalURL(makeValidURL(registrableDomain, privateClickMeasurementTokenPublicKeyPath))
    }

    /// The sign-unlinkable-token URL of the registrable domain, or nil when it is empty.
    @cxx
    @implementation
    public static func tokenSignatureURL(_ registrableDomain: WebCore.RegistrableDomain) -> WebCore.PCM.OptionalURL {
        if registrableDomain.isEmpty() {
            return WebCore.PCM.OptionalURL()
        }
        return WebCore.PCM.OptionalURL(makeValidURL(registrableDomain, privateClickMeasurementTokenSignaturePath))
    }
}

/// The URL of `https://`, the domain and `path`, or the null URL when that is not a valid URL.
private func makeValidURL(_ domain: borrowing WebCore.RegistrableDomain, _ path: Swift.String) -> WTF.URL {
    let validURL = WebCore.PCM.urlFromString(concatenate("https://", WebCore.PCM.domainString(domain), path))
    return validURL.isValid() ? validURL : WTF.URL()
}

/// The String of `prefix`, `string` and `suffix`, ASCII text around a String, as makeString() makes it: 8-bit unless
/// the String is 16-bit.
private func concatenate(_ prefix: Swift.String, _ string: borrowing WTF.String, _ suffix: Swift.String) -> WTF.String {
    let prefixCharacters = prefix.utf8.span
    let suffixCharacters = suffix.utf8.span
    let characters: Span<UInt8> = WebCore.securityPoliciesSpan8(string)
    let units: Span<UInt16> = characters.isEmpty ? string.checkedSpan16() : Span()
    // Strings are shorter than 2^31.
    let length = prefixCharacters.count &+ characters.count &+ units.count &+ suffixCharacters.count
    if units.isEmpty {
        return crossOriginAccessControlMakeString(UInt8.self, length) { output in
            var offset = crossOriginAccessControlCopy(prefixCharacters, to: &output, at: 0)
            offset = crossOriginAccessControlCopy(characters, to: &output, at: offset)
            _ = crossOriginAccessControlCopy(suffixCharacters, to: &output, at: offset)
        }
    }
    return crossOriginAccessControlMakeString(UInt16.self, length) { output in
        var offset = crossOriginAccessControlCopy(prefixCharacters, to: &output, at: 0)
        offset = crossOriginAccessControlCopy(units, to: &output, at: offset)
        _ = crossOriginAccessControlCopy(suffixCharacters, to: &output, at: offset)
    }
}

// MARK: App Store ID

/// PrivateClickMeasurement::appStoreURLAdamID(): the App Store ID of an App Store app URL.
///
/// appStoreURLAdamID() is C++ and calls this: a 16-byte std::optional returned from a
/// `@cxx @implementation` loses its engaged flag (rdar://192728798).
@_expose(Cxx)
func pcmAppStoreURLAdamID(_ url: consuming WTF.URL) -> WebCore.PCM.AdamIDValue {
    let string = WebCore.PCM.urlString(url)
    let characters: Span<UInt8> = WebCore.securityPoliciesSpan8(string)
    let adamID = characters.isEmpty ? appStoreURLAdamID(in: string.checkedSpan16()) : appStoreURLAdamID(in: characters)
    guard let adamID else {
        return WebCore.PCM.AdamIDValue(first: 0, second: false)
    }
    return WebCore.PCM.AdamIDValue(first: adamID, second: true)
}

/// The number after `https://apps.apple.com/app/id` in `characters`, or nil.
private func appStoreURLAdamID<CodeUnit: FixedWidthInteger & UnsignedInteger>(in characters: Span<CodeUnit>) -> UInt64? {
    if !startsWith(characters, privateClickMeasurementToSKAdNetworkURLPrefix) {
        return nil
    }
    let prefixLength = privateClickMeasurementToSKAdNetworkURLPrefix.utf8.count
    return parseUInt64(characters.extracting(prefixLength..<characters.count))
}

// MARK: Validity, times to send and reports

/// PrivateClickMeasurement::isValid(), from whether its trigger data is there and valid, whether its source and
/// destination sites' registrable domains are empty, and its times to send.
@_expose(Cxx)
func pcmIsValid(
    hasValidAttributionTriggerData: Bool,
    sourceDomainIsEmpty: Bool,
    destinationDomainIsEmpty: Bool,
    _ timesToSend: WebCore.PCM.AttributionTimeToSendData
) -> Bool {
    hasValidAttributionTriggerData && !sourceDomainIsEmpty && !destinationDomainIsEmpty
        && (timesToSend.sourceEarliestTimeToSend.has_value()
            || timesToSend.destinationEarliestTimeToSend.has_value())
}

/// PrivateClickMeasurement::isNeitherSameSiteNorCrossSiteTriggeringEvent(), with the measurement's source site's
/// registrable domain and whether the trigger data names a source registrable domain.
@_expose(Cxx)
func pcmIsNeitherSameSiteNorCrossSiteTriggeringEvent(
    _ sourceDomain: consuming WebCore.RegistrableDomain,
    _ redirectDomain: consuming WebCore.RegistrableDomain,
    _ firstPartyURL: consuming WTF.URL,
    _ hasSourceRegistrableDomain: Bool
) -> Bool {
    let isSameSiteTriggeringEvent = redirectDomain.matches(firstPartyURL) && hasSourceRegistrableDomain
    if isSameSiteTriggeringEvent {
        return false
    }
    let isCrossSiteTriggeringEvent = sourceDomain == redirectDomain && !hasSourceRegistrableDomain
    return !isCrossSiteTriggeringEvent
}

/// 24 hours and a random fraction of 24 more, or 1 second in layout tests.
private func randomlyBetweenTwentyFourAndFortyEightHours(
    _ isRunningTest: WebCore.PrivateClickMeasurement.IsRunningLayoutTest
) -> WTF.Seconds {
    if isRunningTest == .Yes {
        return WTF.Seconds(1)
    }
    let day: Double = 24 * 60 * 60
    return WTF.Seconds(day + WTF.cryptographicallyRandomUnitInterval() * day)
}

/// The seconds until each report of an attribution is sent, or neither when the trigger data is not valid or its
/// priority is not higher than the attributed trigger data's.
@_expose(Cxx)
func pcmAttributionSecondsUntilSend(
    triggerDataIsValid: Bool,
    _ priority: UInt8,
    isAttributed: Bool,
    _ attributedPriority: UInt8,
    _ isRunningTest: WebCore.PrivateClickMeasurement.IsRunningLayoutTest
) -> WebCore.PCM.AttributionSecondsUntilSendData {
    guard triggerDataIsValid, !(isAttributed && attributedPriority >= priority) else {
        return WebCore.PCM.AttributionSecondsUntilSendData()
    }
    // 24-48 hour delay before sending. This helps privacy since the conversion and the attribution
    // requests are detached and the time of the attribution does not reveal the time of the conversion.
    let sourceSeconds = randomlyBetweenTwentyFourAndFortyEightHours(isRunningTest)
    let destinationSeconds = randomlyBetweenTwentyFourAndFortyEightHours(isRunningTest)
    return .init(sourceSeconds: .init(sourceSeconds), destinationSeconds: .init(destinationSeconds))
}

/// PrivateClickMeasurement::hasPreviouslyBeenReported(): whether either time to send is unset.
@_expose(Cxx)
func pcmHasPreviouslyBeenReported(_ timesToSend: WebCore.PCM.AttributionTimeToSendData) -> Bool {
    !timesToSend.sourceEarliestTimeToSend.has_value()
        || !timesToSend.destinationEarliestTimeToSend.has_value()
}

/// PrivateClickMeasurement::hasHigherPriorityThan(), from whether each measurement has trigger data, and its priority.
@_expose(Cxx)
func pcmHasHigherPriorityThan(isAttributed: Bool, _ priority: UInt8, otherIsAttributed: Bool, _ otherPriority: UInt8) -> Bool {
    if !otherIsAttributed {
        return true
    }
    if !isAttributed {
        return false
    }
    return priority > otherPriority
}

/// attributionReportClickSourceURL() and attributionReportClickDestinationURL(): the report-attribution URL of
/// `domain`, the source's or the destination's, or the null URL when the measurement is not valid.
@_expose(Cxx)
func pcmAttributionReportURL(_ isValid: Bool, _ domain: consuming WebCore.RegistrableDomain) -> WTF.URL {
    if !isValid {
        return WTF.URL()
    }
    return makeValidURL(domain, privateClickMeasurementReportAttributionPath)
}

/// PrivateClickMeasurement::attributionReportJSON(): the attribution report of a measurement that has trigger data and is
/// valid; PrivateClickMeasurement.cpp returns the empty object for any other.
@_expose(Cxx)
func pcmAttributionReportJSON(
    _ sourceID: UInt8,
    _ sourceDomain: consuming WebCore.RegistrableDomain,
    _ destinationDomain: consuming WebCore.RegistrableDomain,
    _ triggerData: UInt8,
    hasSourceSecretToken: Bool,
    _ sourceSecretToken: consuming WTF.String,
    _ sourceSecretTokenSignature: consuming WTF.String,
    hasDestinationSecretToken: Bool,
    _ destinationSecretToken: consuming WTF.String,
    _ destinationSecretTokenSignature: consuming WTF.String
) -> WebCore.PCM.JSONObjectRef {
    let reportDetails = WTF.JSONImpl.Object.create()
    let object = reportDetails.get()
    object.setString(pcmString("source_engagement_type"), pcmString("click"))
    object.setString(pcmString("source_site"), WebCore.PCM.domainString(sourceDomain))
    object.setInteger(pcmString("source_id"), Int32(sourceID))
    object.setString(pcmString("attributed_on_site"), WebCore.PCM.domainString(destinationDomain))
    object.setInteger(pcmString("trigger_data"), Int32(triggerData))
    object.setInteger(pcmString("version"), privateClickMeasurementVersion)
    // This token has been kept secret this far and cannot be linked to the unlinkable token.
    if hasSourceSecretToken {
        object.setString(pcmString("source_secret_token"), sourceSecretToken)
        object.setString(pcmString("source_secret_token_signature"), sourceSecretTokenSignature)
    }
    // This token has been kept secret this far and cannot be linked to the unlinkable token.
    if hasDestinationSecretToken {
        object.setString(pcmString("destination_secret_token"), destinationSecretToken)
        object.setString(pcmString("destination_secret_token_signature"), destinationSecretTokenSignature)
    }
    return reportDetails
}

// MARK: Fraud Prevention

/// PrivateClickMeasurement::tokenSignatureURL(): nil unless the ephemeral source nonce is valid and the source site has
/// a registrable domain.
///
/// A measurement without a nonce passes the null String.
@_expose(Cxx)
func pcmTokenSignatureURL(
    _ ephemeralSourceNonce: consuming WTF.String,
    _ sourceDomain: consuming WebCore.RegistrableDomain
) -> WebCore.PCM.OptionalURL {
    if !pcmEphemeralNonceIsValid(ephemeralSourceNonce) {
        return WebCore.PCM.OptionalURL()
    }
    return WebCore.PrivateClickMeasurement.tokenSignatureURL(sourceDomain)
}

/// PrivateClickMeasurement::tokenSignatureJSON() and AttributionTriggerData::tokenSignatureJSON().
///
/// Empty without a valid nonce or a token value; a missing nonce or token is the null String.
@_expose(Cxx)
func pcmTokenSignatureJSON(
    _ ephemeralNonce: consuming WTF.String,
    _ unlinkableTokenValueBase64URL: consuming WTF.String,
    _ endpoint: WebCore.PCM.AttributionReportEndpoint
) -> WebCore.PCM.JSONObjectRef {
    let reportDetails = WTF.JSONImpl.Object.create()
    if !pcmEphemeralNonceIsValid(copy ephemeralNonce) {
        return reportDetails
    }
    if unlinkableTokenValueBase64URL.isEmpty() {
        return reportDetails
    }
    let object = reportDetails.get()
    object.setString(pcmString("source_engagement_type"), pcmString("click"))
    object.setString(pcmString(endpoint == .Destination ? "destination_nonce" : "source_nonce"), ephemeralNonce)
    // This token can not be linked to the secret token.
    object.setString(
        pcmString(endpoint == .Destination ? "destination_unlinkable_token" : "source_unlinkable_token"),
        unlinkableTokenValueBase64URL
    )
    object.setInteger(pcmString("version"), privateClickMeasurementVersion)
    return reportDetails
}

/// EphemeralNonce::isValid(): whether the nonce decodes as base64url to 16 bytes.
@_expose(Cxx)
func pcmEphemeralNonceIsValid(_ nonce: consuming WTF.String) -> Bool {
    // FIXME: Investigate if we can do with a simple length check instead of decoding.
    // https://bugs.webkit.org/show_bug.cgi?id=221945
    let characters: Span<UInt8> = WebCore.securityPoliciesSpan8(nonce)
    let count = characters.isEmpty ? pcmBase64URLDecodedCount(nonce.checkedSpan16()) : pcmBase64URLDecodedCount(characters)
    return count == ephemeralNonceRequiredNumberOfBytes
}

/// The sextet of a base64url character, or nil.
private func base64URLSextet<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ character: CodeUnit) -> UInt8? {
    // Each range starts at the value it subtracts, so the subtraction cannot wrap.
    switch character {
    case 0x41...0x5A: UInt8(truncatingIfNeeded: character &- 0x41)
    case 0x61...0x7A: UInt8(truncatingIfNeeded: character &- 0x61 &+ 26)
    case 0x30...0x39: UInt8(truncatingIfNeeded: character &- 0x30 &+ 52)
    case 0x2D: 62
    case 0x5F: 63
    default: nil
    }
}

/// The number of bytes base64URLDecode() gives for the characters, or nil where it gives none.
///
/// Any number of "=" may end them, after at least one other character, and nothing else may follow one; a last group
/// of one character is not valid.
func pcmBase64URLDecodedCount<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ characters: Span<CodeUnit>) -> Int? {
    var sextetCount = 0
    var equalsSignCount = 0
    for index in characters.indices {
        if characters[index] == 0x3D {
            equalsSignCount += 1
            continue
        }
        if base64URLSextet(characters[index]) == nil || equalsSignCount != 0 {
            return nil
        }
        sextetCount += 1
    }
    if sextetCount == 0 {
        return equalsSignCount == 0 ? 0 : nil
    }
    switch sextetCount % 4 {
    case 1: return nil
    case 2: return sextetCount / 4 * 3 + 1
    case 3: return sextetCount / 4 * 3 + 2
    default: return sextetCount / 4 * 3
    }
}

/// Decodes the characters into output, whose count pcmBase64URLDecodedCount() gave.
///
/// The bits of the last character past the last byte are dropped.
func pcmBase64URLDecode<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ characters: Span<CodeUnit>, into output: inout MutableSpan<UInt8>)
{
    var group: UInt32 = 0
    var sextetCount = 0
    var outputIndex = 0
    for index in characters.indices {
        guard let sextet = base64URLSextet(characters[index]) else {
            // The "=" at the end.
            break
        }
        group = group &<< 6 | UInt32(sextet)
        sextetCount += 1
        if sextetCount % 4 == 0 {
            output[outputIndex] = UInt8(truncatingIfNeeded: group &>> 16)
            output[outputIndex + 1] = UInt8(truncatingIfNeeded: group &>> 8)
            output[outputIndex + 2] = UInt8(truncatingIfNeeded: group)
            outputIndex += 3
            group = 0
        }
    }
    switch sextetCount % 4 {
    case 2:
        output[outputIndex] = UInt8(truncatingIfNeeded: group &>> 4)
    case 3:
        output[outputIndex] = UInt8(truncatingIfNeeded: group &>> 10)
        output[outputIndex + 1] = UInt8(truncatingIfNeeded: group &>> 2)
    default:
        break
    }
}

// MARK: Attribution request parsing

/// Whether `characters` start with the ASCII `literal`, code unit for code unit.
private func startsWith<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ characters: Span<CodeUnit>, _ literal: Swift.String) -> Bool {
    let literalCharacters = literal.utf8.span
    if characters.count < literalCharacters.count {
        return false
    }
    for index in literalCharacters.indices where characters[index] != CodeUnit(literalCharacters[index]) {
        return false
    }
    return true
}

/// Code units `index..<index + 8` of 8-bit `characters` as one little-endian word.
private func littleEndianWord<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ characters: Span<CodeUnit>, at index: Int) -> UInt64 {
    var word: UInt64 = 0
    for offset in 0..<8 {
        word |= UInt64(characters[index + offset]) << (8 * offset)
    }
    return word
}

/// startsWith(characters, privateClickMeasurementTriggerAttributionPath), eight 8-bit code units at a time.
private func startsWithTriggerAttributionPath<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ characters: Span<CodeUnit>) -> Bool {
    // The words are privateClickMeasurementTriggerAttributionPath's 59 bytes 0..<56 and 51..<59, little-endian:
    // "/.well-k", "nown/pri", "vate-cli", "ck-measu", "rement/t", "rigger-a", "ttributi" and "ibution/".
    if characters.count < 59 {
        return false
    }
    if CodeUnit.bitWidth != 8 {
        return startsWith(characters, privateClickMeasurementTriggerAttributionPath)
    }
    let result =
        littleEndianWord(characters, at: 0) == 0x6B2D_6C6C_6577_2E2F
        && littleEndianWord(characters, at: 8) == 0x6972_702F_6E77_6F6E
        && littleEndianWord(characters, at: 16) == 0x696C_632D_6574_6176
        && littleEndianWord(characters, at: 24) == 0x7573_6165_6D2D_6B63
        && littleEndianWord(characters, at: 32) == 0x742F_746E_656D_6572
        && littleEndianWord(characters, at: 40) == 0x612D_7265_6767_6972
        && littleEndianWord(characters, at: 48) == 0x6974_7562_6972_7474
        && littleEndianWord(characters, at: 51) == 0x2F6E_6F69_7475_6269
    assert(startsWith(characters, privateClickMeasurementTriggerAttributionPath) == result)
    return result
}

/// Whether `string` equals the ASCII `literal`, as `String == ASCIILiteral` compares them.
private func equalsASCIILiteral(_ string: borrowing WTF.String, _ literal: Swift.String) -> Bool {
    let characters: Span<UInt8> = WebCore.securityPoliciesSpan8(string)
    if !characters.isEmpty {
        return characters.count == literal.utf8.count && startsWith(characters, literal)
    }
    let units: Span<UInt16> = string.checkedSpan16()
    return units.count == literal.utf8.count && startsWith(units, literal)
}

/// StringView::substring(start, length) of `characters`: clamped to them.
private func clampedSubstring<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ start: Int,
    _ length: Int
) -> Span<CodeUnit> {
    if start >= characters.count {
        return characters.extracting(characters.count..<characters.count)
    }
    // 0 <= start < characters.count and length >= 0 at every caller, so neither operation wraps.
    return characters.extracting(start..<(start &+ min(length, characters.count &- start)))
}

/// isUnicodeCompatibleASCIIWhitespace() of a code unit.
private func pcmIsUnicodeCompatibleASCIIWhitespace<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ character: CodeUnit) -> Bool {
    // " ", "\t", "\n", "\v", "\f" and "\r".
    character == 0x20 || (character >= 0x09 && character <= 0x0D)
}

/// WTF's parseInteger<uint64_t>() of `characters` in base 10: ASCII whitespace allowed around a run of digits after an
/// optional "+", and nil when the value overflows or anything else is there.
///
/// The shared Swift parseInteger() is built only with ENABLE_WEBCORE_SWIFT.
private func parseUInt64<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ characters: Span<CodeUnit>) -> UInt64? {
    var index = 0
    while index < characters.count && pcmIsUnicodeCompatibleASCIIWhitespace(characters[index]) {
        index += 1
    }
    if index < characters.count && characters[index] == 0x2B {
        index += 1
    }
    guard index < characters.count, characters[index] >= 0x30, characters[index] <= 0x39 else {
        return nil
    }
    var value: UInt64 = 0
    while index < characters.count && characters[index] >= 0x30 && characters[index] <= 0x39 {
        let (product, productOverflowed) = value.multipliedReportingOverflow(by: 10)
        // The loop condition gives characters[index] >= 0x30.
        let (sum, sumOverflowed) = product.addingReportingOverflow(UInt64(characters[index] &- 0x30))
        guard !productOverflowed, !sumOverflowed else {
            return nil
        }
        value = sum
        index += 1
    }
    while index < characters.count && pcmIsUnicodeCompatibleASCIIWhitespace(characters[index]) {
        index += 1
    }
    return index == characters.count ? value : nil
}

/// The trigger data of an attribution request, or why it was not accepted (the null String when it is not one).
private enum AttributionRequest: ~Copyable {
    case data(WebCore.PCM.AttributionTriggerData)
    case error(WTF.String)
}

private func attributionRequestError(_ message: Swift.String) -> AttributionRequest {
    .error(pcmString(message))
}

/// The message `prefix`, the decimal `maximum` and ".", as makeString() makes it.
private func attributionRequestError(_ prefix: Swift.String, maximum: UInt8) -> AttributionRequest {
    let prefixCharacters = prefix.utf8.span
    let digitCount = maximum >= 100 ? 3 : maximum >= 10 ? 2 : 1
    let message = crossOriginAccessControlMakeString(UInt8.self, prefixCharacters.count + digitCount + 1) { output in
        let digitsStart = crossOriginAccessControlCopy(prefixCharacters, to: &output, at: 0)
        var remaining = maximum
        for index in (0..<digitCount).reversed() {
            output[digitsStart + index] = 0x30 + remaining % 10
            remaining /= 10
        }
        output[digitsStart + digitCount] = 0x2E
    }
    return .error(message)
}

/// parseAttributionRequest() of the URL's characters.
private func pcmParseAttributionRequest<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ redirectURL: WTF.URL
) -> AttributionRequest {
    let pathStart = Int(redirectURL.pathStart())
    // The unsigned difference, which substring() clamps.
    let pathLength = Int(redirectURL.pathEnd() &- redirectURL.pathStart())
    let path = clampedSubstring(characters, pathStart, pathLength)
    if path.isEmpty || !startsWithTriggerAttributionPath(path) {
        return .error(WTF.String())
    }

    if !protocolIsHTTPS(characters, redirectURL) || redirectURL.hasCredentials() || redirectURL.hasFragmentIdentifier() {
        return attributionRequestError(
            "[Private Click Measurement] Triggering event was not accepted because the URL's protocol is not HTTPS or the URL contains one or more of username, password, and fragment."
        )
    }

    var attributionTriggerData = WebCore.PCM.AttributionTriggerData()
    if redirectURL.hasQuery() {
        switch parseAttributionRequestQuery(redirectURL) {
        case .data(let data):
            attributionTriggerData = data
        case .error(let message):
            if !message.isEmpty() {
                return .error(message)
            }
            return attributionRequestError(
                "[Private Click Measurement] Triggering event was not accepted because the URL's query string could not be parsed."
            )
        }
    }

    let prefixLength = privateClickMeasurementTriggerAttributionPath.utf8.count
    let dataError =
        "[Private Click Measurement] Triggering event was not accepted because the conversion data could not be parsed or was higher than the allowed maximum of "
    if path.count == prefixLength + privateClickMeasurementAttributionTriggerDataPathSegmentSize {
        guard let data = parseUInt64(clampedSubstring(path, prefixLength, privateClickMeasurementAttributionTriggerDataPathSegmentSize)),
            data <= UInt64(triggerDataMaxEntropy)
        else {
            return attributionRequestError(dataError, maximum: triggerDataMaxEntropy)
        }
        attributionTriggerData.data = UInt8(truncatingIfNeeded: data)
        attributionTriggerData.priority = 0
        return .data(attributionTriggerData)
    }

    if path.count == prefixLength + privateClickMeasurementAttributionTriggerDataPathSegmentSize + 1
        + privateClickMeasurementPriorityPathSegmentSize
    {
        guard let data = parseUInt64(clampedSubstring(path, prefixLength, privateClickMeasurementAttributionTriggerDataPathSegmentSize)),
            data <= UInt64(triggerDataMaxEntropy)
        else {
            return attributionRequestError(dataError, maximum: triggerDataMaxEntropy)
        }
        let priorityStart = prefixLength + privateClickMeasurementAttributionTriggerDataPathSegmentSize + 1
        guard let priority = parseUInt64(clampedSubstring(path, priorityStart, privateClickMeasurementPriorityPathSegmentSize)),
            priority <= UInt64(priorityMaxEntropy)
        else {
            return attributionRequestError(
                "[Private Click Measurement] Triggering event was not accepted because the priority could not be parsed or was higher than the allowed maximum of ",
                maximum: priorityMaxEntropy
            )
        }
        attributionTriggerData.data = UInt8(truncatingIfNeeded: data)
        attributionTriggerData.priority = UInt8(truncatingIfNeeded: priority)
        return .data(attributionTriggerData)
    }

    return attributionRequestError(
        "[Private Click Measurement] Triggering event was not accepted because the URL path contained unrecognized parts."
    )
}

/// URL::protocolIs("https"_s): a valid URL whose scheme, which ends at its first ":", is "https" in any ASCII case.
private func protocolIsHTTPS<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ characters: Span<CodeUnit>,
    _ url: borrowing WTF.URL
) -> Bool {
    let scheme = "https"
    let schemeLength = 5
    if !url.isValid() || characters.count <= schemeLength {
        return false
    }
    if CodeUnit.bitWidth == 8 {
        // "https:" as a little-endian word, the five letters compared with their ASCII case bit set and ":" exactly.
        var word: UInt64 = 0
        for offset in 0...schemeLength {
            word |= UInt64(characters[offset]) << (8 * offset)
        }
        return word | 0x20_2020_2020 == 0x3A_7370_7474_68
    }
    if characters[schemeLength] != 0x3A {
        return false
    }
    let schemeCharacters = scheme.utf8.span
    for index in 0..<schemeLength where characters[index] | 0x20 != CodeUnit(schemeCharacters[index]) {
        return false
    }
    return true
}

/// The trigger data that a redirect's query gives, its source registrable domain and its destination nonce, or why it
/// gives none, for a URL with a query.
private func parseAttributionRequestQuery(_ redirectURL: borrowing WTF.URL) -> AttributionRequest {
    let parameters = WTF.queryParameters(redirectURL)
    if parameters.isEmpty() {
        return attributionRequestError(
            "[Private Click Measurement] Triggering event was not accepted because the URL had a query string but it didn't contain supported parameters."
        )
    }
    if parameters.size() > 2 {
        return attributionRequestError(
            "[Private Click Measurement] Triggering event was not accepted because the URL's query string contained unsupported parameters."
        )
    }

    var destinationNonce = WTF.String()
    var sourceDomain = WebCore.RegistrableDomain()
    for parameter in parameters {
        if equalsASCIILiteral(parameter.key, "attributionSource") {
            if parameter.value.isEmpty() {
                return attributionRequestError(
                    "[Private Click Measurement] Triggering event was not accepted because the URL's attributionSource query parameter had no value."
                )
            }
            if !sourceDomain.isEmpty() {
                return attributionRequestError(
                    "[Private Click Measurement] Triggering event was not accepted because the URL had multiple attributionSource query parameters."
                )
            }
            let attributionSourceURL = WebCore.PCM.urlFromString(parameter.value)
            // hasPath() gives pathEnd() >= pathStart().
            if !attributionSourceURL.isValid()
                || (attributionSourceURL.hasPath() && attributionSourceURL.pathEnd() &- attributionSourceURL.pathStart() > 1)
                || attributionSourceURL.hasCredentials() || attributionSourceURL.hasQuery()
                || attributionSourceURL.hasFragmentIdentifier()
            {
                return attributionRequestError(
                    "[Private Click Measurement] Triggering event was not accepted because the URL's attributionSource query parameter was not a valid URL or was a URL with a path, credentials, query string, or fragment."
                )
            }
            sourceDomain = WebCore.RegistrableDomain(attributionSourceURL)
            if sourceDomain.isEmpty() {
                return attributionRequestError(
                    "[Private Click Measurement] Triggering event was not accepted because the URL's attributionSource query parameter had no registrable domain."
                )
            }
        } else if equalsASCIILiteral(parameter.key, "attributionDestinationNonce") {
            if parameter.value.isEmpty() {
                return attributionRequestError(
                    "[Private Click Measurement] Triggering event was not accepted because the URL's attributionDestinationNonce query parameter had no value."
                )
            }
            if !destinationNonce.isEmpty() {
                return attributionRequestError(
                    "[Private Click Measurement] Triggering event was not accepted because the URL had multiple attributionDestinationNonce query parameters."
                )
            }
            destinationNonce = parameter.value
        } else {
            return attributionRequestError(
                "[Private Click Measurement] Triggering event was not accepted because the URL's query string contained unsupported parameters."
            )
        }
    }

    var attributionTriggerData = WebCore.PCM.AttributionTriggerData()
    if !sourceDomain.isEmpty() {
        attributionTriggerData.sourceRegistrableDomain = .init(sourceDomain)
    }
    if !destinationNonce.isEmpty() {
        attributionTriggerData.ephemeralDestinationNonce = .init(WebCore.PCM.EphemeralNonce(nonce: destinationNonce))
    }
    return .data(attributionTriggerData)
}
