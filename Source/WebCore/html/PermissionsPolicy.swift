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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// them name (rdar://192229293).
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import WebCore_Private.Core.SecurityPoliciesSwiftTypes
internal import WebCore_Private.HTTPHeaderParsersTypes
internal import wtf.Core.StdLibExtras
internal import wtf.Core.Stopwatch
internal import wtf.Core.text.WTFString

/// readFeatureIdentifier(): the PermissionsPolicy::Feature value of the feature an item of an allow attribute names,
/// Invalid when it names none, and where the rest of the item, its allowlist, is in `value`.
///
/// `value` is the characters of the caller's `StringView`, a part of the attribute's value, whose `String` the caller
/// holds unchanged for the call; a `StringImpl`'s characters never change after it is created. Nothing this function
/// calls writes them, and every Latin-1 or UTF-16 code unit is a valid value. This one takes 8-bit characters.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func permissionsPolicyFeatureIdentifier8(_ value: WebCore.HTTPHeaderLatin1Span) -> WebCore.PermissionsPolicyFeatureIdentifier {
    let characters = unsafe Span<UInt8>(_unsafeCxxSpan: WTF.bytesOfLatin1Characters(value))
    return permissionsPolicyFeatureIdentifier(characters)
}

/// permissionsPolicyFeatureIdentifier8() for 16-bit characters, which hold for the call in the same way.
///
/// FIXME: Take the characters as a Span when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func permissionsPolicyFeatureIdentifier16(_ value: WebCore.HTTPHeaderUTF16Span) -> WebCore.PermissionsPolicyFeatureIdentifier {
    let characters = unsafe Span<UInt16>(_unsafeCxxSpan: value)
    return permissionsPolicyFeatureIdentifier(characters)
}

/// The name of the PermissionsPolicy::Feature value `feature` in console messages; the empty string past Invalid.
@_expose(Cxx)
func permissionsPolicyFeatureNameForLogging(_ feature: UInt8) -> WTF.String {
    let features = permissionsPolicyFeatureTable.features
    let index = Int(feature)
    if index < features.count {
        let name = features[index].nameForLogging
        return WTF.makeStringFromLatin1Characters(name.span)
    }
    if index == features.count {
        return WTF.makeStringFromLatin1Characters(permissionsPolicyInvalidFeatureNameForLogging.span)
    }
    let noName: [UInt8] = []
    return WTF.makeStringFromLatin1Characters(noName.span)
}

/// isFeatureAllowedByDefaultAllowlist(): whether the default allowlist of the PermissionsPolicy::Feature value
/// `feature` allows an origin, which `isSameOrigin` says is the document's or not.
///
/// The allowlist is "*" for the gamepad, sync-xhr and storage-access features, 'self' for the other features, and
/// 'none' for Invalid and past it.
@_expose(Cxx)
func permissionsPolicyIsAllowedByDefault(_ feature: UInt8, _ isSameOrigin: Bool) -> Bool {
    let features = permissionsPolicyFeatureTable.features
    let index = Int(feature)
    if index >= features.count {
        return false
    }
    return features[index].allowsAllOriginsByDefault || isSameOrigin
}

// A feature: its token in an allow attribute, its name in console messages, and whether its default allowlist is "*"
// rather than 'self'.
private struct PermissionsPolicyFeatureDescription {
    let token: [UInt8]
    let nameForLogging: [UInt8]
    let allowsAllOriginsByDefault: Bool

    init(_ token: Swift.String, _ nameForLogging: Swift.String, allowsAllOriginsByDefault: Bool = false) {
        self.token = Array(token.utf8)
        self.nameForLogging = Array(nameForLogging.utf8)
        self.allowsAllOriginsByDefault = allowsAllOriginsByDefault
    }
}

private let permissionsPolicyInvalidFeatureNameForLogging: [UInt8] = Array("Invalid".utf8)

// The features before Invalid, in PermissionsPolicy::Feature's order, so that a feature's value is its index. The
// device orientation, Web Authentication and WebXR features are values only in a build that enables them, and the
// values after a disabled group are lower by its size. `tokenOrder` is the order readFeatureIdentifier() tries the
// tokens in: the features' order, except that loopback-network comes before local-network.
private let permissionsPolicyFeatureTable: (features: [PermissionsPolicyFeatureDescription], tokenOrder: [Int]) = {
    var features = [
        PermissionsPolicyFeatureDescription("camera", "Camera"),
        PermissionsPolicyFeatureDescription("microphone", "Microphone"),
        PermissionsPolicyFeatureDescription("speaker-selection", "SpeakerSelection"),
        PermissionsPolicyFeatureDescription("display-capture", "DisplayCapture"),
        PermissionsPolicyFeatureDescription("gamepad", "Gamepad", allowsAllOriginsByDefault: true),
        PermissionsPolicyFeatureDescription("geolocation", "Geolocation"),
        PermissionsPolicyFeatureDescription("payment", "Payment"),
        PermissionsPolicyFeatureDescription("screen-wake-lock", "ScreenWakeLock"),
        PermissionsPolicyFeatureDescription("sync-xhr", "SyncXHR", allowsAllOriginsByDefault: true),
        PermissionsPolicyFeatureDescription("fullscreen", "Fullscreen"),
        PermissionsPolicyFeatureDescription("web-share", "WebShare"),
    ]
#if ENABLE_DEVICE_ORIENTATION
    features.append(PermissionsPolicyFeatureDescription("gyroscope", "Gyroscope"))
    features.append(PermissionsPolicyFeatureDescription("accelerometer", "Accelerometer"))
    features.append(PermissionsPolicyFeatureDescription("magnetometer", "Magnetometer"))
#endif
#if ENABLE_WEB_AUTHN
    features.append(PermissionsPolicyFeatureDescription("publickey-credentials-get", "PublickeyCredentialsGet"))
    features.append(PermissionsPolicyFeatureDescription("digital-credentials-get", "DigitalCredentialsGet"))
#endif
#if ENABLE_WEBXR
    features.append(PermissionsPolicyFeatureDescription("xr-spatial-tracking", "XRSpatialTracking"))
#endif
    features.append(PermissionsPolicyFeatureDescription("private-token", "PrivateToken"))
    features.append(PermissionsPolicyFeatureDescription("storage-access", "StorageAccess", allowsAllOriginsByDefault: true))
    let localNetwork = features.count
    features.append(PermissionsPolicyFeatureDescription("local-network", "LocalNetwork"))
    features.append(PermissionsPolicyFeatureDescription("loopback-network", "LoopbackNetwork"))
    features.append(PermissionsPolicyFeatureDescription("cross-origin-isolated", "CrossOriginIsolated"))

    var tokenOrder = Array(features.indices)
    tokenOrder.swapAt(localNetwork, localNetwork + 1)
    return (features, tokenOrder)
}()

// https://w3c.github.io/webappsec-permissions-policy/#serialized-policy-directive
// The value, without its leading and trailing ASCII whitespace, starts with a feature's token, compared exactly. The
// rest of it, after a ":" that follows the token, is the allowlist.
private func permissionsPolicyFeatureIdentifier<CodeUnit: FixedWidthInteger & UnsignedInteger>(
    _ value: Span<CodeUnit>
) -> WebCore.PermissionsPolicyFeatureIdentifier {
    var start = 0
    var end = value.count
    while start < end && isPermissionsPolicyWhitespace(value[start]) {
        start += 1
    }
    while end > start && isPermissionsPolicyWhitespace(value[end - 1]) {
        end -= 1
    }

    let table = permissionsPolicyFeatureTable
    for feature in table.tokenOrder {
        let tokenCharacters = table.features[feature].token
        let token = tokenCharacters.span
        if end - start < token.count {
            continue
        }
        var matched = 0
        while matched < token.count && value[start + matched] == CodeUnit(token[matched]) {
            matched += 1
        }
        if matched < token.count {
            continue
        }

        var remainingStart = start + token.count
        // FIXME: webkit.org/b/274159.
        // Using colon as delimiter is no longer standard behavior. We should drop this,
        // update tests and use splitOnAsciiWhiteSpace to read feature identifier.
        if remainingStart < end && value[remainingStart] == 0x3A {
            remainingStart += 1
        }
        // A StringView's offsets fit in 32 bits, and there are fewer than 256 features.
        return WebCore.PermissionsPolicyFeatureIdentifier(
            remainingStart: UInt32(truncatingIfNeeded: remainingStart),
            remainingLength: UInt32(truncatingIfNeeded: end - remainingStart),
            feature: UInt8(truncatingIfNeeded: feature)
        )
    }

    return WebCore.PermissionsPolicyFeatureIdentifier(
        remainingStart: UInt32(truncatingIfNeeded: value.count),
        remainingLength: 0,
        feature: UInt8(truncatingIfNeeded: table.features.count)
    )
}

// isASCIIWhitespace(): space, tab, line feed, form feed or carriage return; not vertical tab.
@inline(always)
private func isPermissionsPolicyWhitespace<CodeUnit: FixedWidthInteger & UnsignedInteger>(_ character: CodeUnit) -> Bool {
    character == 0x20 || character == 0x09 || character == 0x0A || character == 0x0C || character == 0x0D
}
