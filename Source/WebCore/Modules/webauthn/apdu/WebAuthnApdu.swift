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

// ISO 7816-4 APDU commands and responses, for the U2F and NFC/CCID framing. Only the extended length encoding.

// The C++ class constants (`static constexpr` members do not import); ApduCommand.cpp pins each with a static_assert.
private let apduMinHeader = 4 // ApduCommand::kApduMinHeader
private let apduCommandLengthOffset = 5 // ApduCommand::kApduCommandLengthOffset
private let apduCommandDataOffset = 7 // ApduCommand::kApduCommandDataOffset
private let apduMaxDataLength = 65_535 // ApduCommand::kApduMaxDataLength
let apduMaxResponseLength = 65_536 // ApduCommand::kApduMaxResponseLength
private let apduMaxLength = 65_544 // ApduCommand::kApduMaxLength: data, a 7-byte header and a 2-byte Le.

// A big-endian 16-bit length at `offset`.
@inline(always)
private func apduLength(_ bytes: Span<UInt8>, _ offset: Int) -> Int {
    Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
}

extension apdu.ApduCommand {
    // Entries that read a span of a by-value C++ parameter forward to a `...Body` helper with the same parameters, here
    // and in the other WebAuthn Swift files: Swift 6.5 rejects a span of an `@cxx @implementation` parameter
    // ("lifetime-dependent value escapes its scope"), while the same span of an ordinary Swift parameter compiles.
    @cxx @implementation public static func createFromMessage(_ message: cbor.CBORValue.BinaryValue) -> fido.OptionalApduCommand {
        createFromMessageBody(message)
    }

    private static func createFromMessageBody(_ message: cbor.CBORValue.BinaryValue) -> fido.OptionalApduCommand {
        let size = message.size()
        if size < apduMinHeader || size > apduMaxLength {
            return fido.OptionalApduCommand()
        }
        let bytes: Span<UInt8> = message.span()

        var responseLength = 0
        var data = cbor.CBORValue.BinaryValue()
        switch size {
        case apduMinHeader:
            // No data present; no expected response.
            break
        case apduMinHeader + 1, apduMinHeader + 2:
            // Invalid encoding sizes.
            return fido.OptionalApduCommand()
        case apduMinHeader + 3:
            // No data present; response expected. The fifth byte must be 0.
            if bytes[4] != 0 {
                return fido.OptionalApduCommand()
            }
            responseLength = apduLength(bytes, apduCommandLengthOffset)
            // A response length of 0x0000 is 65536 (ISO 7816-4).
            if responseLength == 0 {
                responseLength = apduMaxResponseLength
            }
        default:
            if bytes[4] != 0 {
                return fido.OptionalApduCommand()
            }
            let dataLength = apduLength(bytes, apduCommandLengthOffset)
            if size == dataLength + apduCommandDataOffset {
                // No response expected.
                data = message.subvector(apduCommandDataOffset, dataLength)
            } else if size == dataLength + apduCommandDataOffset + 2 {
                // The maximum response size is in the final 2 bytes.
                data = message.subvector(apduCommandDataOffset, dataLength)
                responseLength = apduLength(bytes, apduCommandDataOffset + dataLength)
                if responseLength == 0 {
                    responseLength = apduMaxResponseLength
                }
            } else {
                return fido.OptionalApduCommand()
            }
        }

        var command = apdu.ApduCommand()
        command.setCla(bytes[0])
        command.setIns(bytes[1])
        command.setP1(bytes[2])
        command.setP2(bytes[3])
        command.setResponseLength(responseLength)
        command.setData(consuming: data)
        return fido.OptionalApduCommand(command)
    }

    @cxx @implementation public static func encodeCommand(_ cla: UInt8, _ ins: UInt8, _ p1: UInt8, _ p2: UInt8, _ responseLength: Int, _ data: cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue {
        encodeCommandBody(cla, ins, p1, p2, responseLength, data)
    }

    private static func encodeCommandBody(_ cla: UInt8, _ ins: UInt8, _ p1: UInt8, _ p2: UInt8, _ responseLength: Int, _ data: cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue {
        // size_t in C++: compare and clamp it unsigned.
        encodeApduCommand(cla, ins, p1, p2, UInt(bitPattern: responseLength), data.span())
    }
}

// ApduCommand::getEncodedCommand, for the C++ and for the U2F commands (WebAuthnU2f.swift).
func encodeApduCommand(_ cla: UInt8, _ ins: UInt8, _ p1: UInt8, _ p2: UInt8, _ responseLength: UInt, _ data: Span<UInt8>) -> cbor.CBORValue.BinaryValue {
    let dataLength = min(data.count, apduMaxDataLength)
    var sink = fido.WebAuthnByteSink()
    sink.reserve(apduMinHeader + 3 + dataLength + 2)
    var header = InlineArray<7, UInt8>(repeating: 0)
    header[0] = cla
    header[1] = ins
    header[2] = p1
    header[3] = p2
    var headerLength = apduMinHeader

    // With data, Lc is 3 bytes: a zero byte and the big-endian request size. Without data, Le gets the zero byte.
    if dataLength != 0 {
        header[5] = UInt8(dataLength >> 8)
        header[6] = UInt8(dataLength & 0xff)
        headerLength += 3
    } else if responseLength != 0 {
        headerLength += 1
    }
    addBytes(&sink, header.span.extracting(0..<headerLength))
    addBytes(&sink, data.extracting(0..<dataLength))
    var encoded = sink.take()

    if responseLength != 0 {
        // 65536 encodes as 0x0000.
        let length = min(responseLength, UInt(apduMaxResponseLength))
        encoded.append(consuming: UInt8((length >> 8) & 0xff))
        encoded.append(consuming: UInt8(length & 0xff))
    }
    return encoded
}

extension apdu.ApduResponse {
    @cxx @implementation public static func createFromMessage(_ data: cbor.CBORValue.BinaryValue) -> fido.OptionalApduResponse {
        createFromMessageBody(data)
    }

    private static func createFromMessageBody(_ data: cbor.CBORValue.BinaryValue) -> fido.OptionalApduResponse {
        // The data is followed by two status bytes.
        let size = data.size()
        if size < 2 {
            return fido.OptionalApduResponse()
        }
        let bytes: Span<UInt8> = data.span()
        let statusBytes = UInt16(bytes[size - 2]) << 8 | UInt16(bytes[size - 1])
        // Any value, as static_cast<Status> takes it.
        let status = apdu.ApduResponse.Status(rawValue: statusBytes)!
        var payload = data
        payload.shrink(size - 2)
        return fido.OptionalApduResponse(apdu.ApduResponse(consuming: payload, status))
    }

    @cxx @implementation public static func encodeResponse(_ data: cbor.CBORValue.BinaryValue, _ status: apdu.ApduResponse.Status) -> cbor.CBORValue.BinaryValue {
        var encoded = data
        encoded.append(consuming: UInt8(status.rawValue >> 8))
        encoded.append(consuming: UInt8(status.rawValue & 0xff))
        return encoded
    }
}

#endif // !os(watchOS) && !targetEnvironment(macCatalyst)
