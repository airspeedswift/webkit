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

// CTAP HID message framing: init and continuation packets.
// https://fidoalliance.org/specs/fido-v2.0-ps-20170927/fido-client-to-authenticator-protocol-v2.0-ps-20170927.html#message-and-packet-structure

// The commands a received init packet may carry (after masking off the init bit).
private func isFidoHidDeviceCommand(_ raw: UInt8) -> Bool {
    switch raw {
    case fido.FidoHidDeviceCommand.msg.rawValue, fido.FidoHidDeviceCommand.cbor.rawValue,
        fido.FidoHidDeviceCommand.`init`.rawValue, fido.FidoHidDeviceCommand.ping.rawValue,
        fido.FidoHidDeviceCommand.cancel.rawValue, fido.FidoHidDeviceCommand.error.rawValue,
        fido.FidoHidDeviceCommand.keepAlive.rawValue, fido.FidoHidDeviceCommand.wink.rawValue,
        fido.FidoHidDeviceCommand.lock.rawValue:
        return true
    default:
        return false
    }
}

// FidoHidMessage::create's checks: whether a message of this command may carry this payload.
private func acceptsPayload(_ cmd: fido.FidoHidDeviceCommand, _ bytes: Span<UInt8>) -> Bool {
    let size = bytes.count
    if size > fido.kHidMaxMessageSize {
        return false
    }
    switch cmd {
    case .ping:
        return true
    case .msg, .cbor:
        return size != 0
    case .cancel, .wink:
        return size == 0
    case .lock:
        return size == 1 && bytes[0] <= fido.kHidMaxLockSeconds
    case .`init`:
        return size == 8
    case .keepAlive, .error:
        return size == 1
    default:
        // A raw value outside the enum has no size check.
        return true
    }
}

@inline(always)
private func appendBytes(_ out: inout cbor.CBORValue.BinaryValue, _ bytes: Span<UInt8>, _ range: Range<Int>) {
    for index in range {
        out.append(consuming: bytes[index])
    }
}

@inline(always)
private func readChannelId(_ bytes: Span<UInt8>) -> UInt32 {
    UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
}

// A packet: its header, the data, then zero padding up to the packet size. More than a packet's data traps, as
// Vector::grow's release assert does in C++.
private func makePacket(_ header: borrowing InlineArray<7, UInt8>, _ headerLength: Int, _ bytes: Span<UInt8>, _ range: Range<Int>) -> cbor.CBORValue.BinaryValue {
    let length = headerLength + range.count
    var packet = fido.WebAuthnByteSink()
    packet.reserve(max(fido.kHidPacketSize, length))
    addBytes(&packet, header.span.extracting(0..<headerLength))
    addBytes(&packet, bytes.extracting(range))
    precondition(length <= fido.kHidPacketSize, "HID packet data longer than the packet")
    let zeros = InlineArray<64, UInt8>(repeating: 0)
    addBytes(&packet, zeros.span.extracting(0..<(fido.kHidPacketSize - length)))
    return packet.take()
}

@inline(always)
private func storeChannelId(_ header: inout InlineArray<7, UInt8>, _ channelId: UInt32) {
    header[0] = UInt8(channelId >> 24)
    header[1] = UInt8((channelId >> 16) & 0xff)
    header[2] = UInt8((channelId >> 8) & 0xff)
    header[3] = UInt8(channelId & 0xff)
}

// Init packet: channel id (4), command with the init bit (1), payload length (2, big-endian), data, zero padding.
private func initPacket(_ channelId: UInt32, _ cmd: UInt8, _ payloadLength: UInt16, _ bytes: Span<UInt8>, _ range: Range<Int>) -> cbor.CBORValue.BinaryValue {
    var header = InlineArray<7, UInt8>(repeating: 0)
    storeChannelId(&header, channelId)
    header[4] = cmd | 0x80
    header[5] = UInt8(payloadLength >> 8)
    header[6] = UInt8(payloadLength & 0xff)
    return makePacket(header, fido.kHidInitPacketHeaderSize, bytes, range)
}

// Continuation packet: channel id (4), sequence (1), data, zero padding.
private func continuationPacket(_ channelId: UInt32, _ sequence: UInt8, _ bytes: Span<UInt8>, _ range: Range<Int>) -> cbor.CBORValue.BinaryValue {
    var header = InlineArray<7, UInt8>(repeating: 0)
    storeChannelId(&header, channelId)
    header[4] = sequence
    return makePacket(header, fido.kHidContinuationPacketHeader, bytes, range)
}

// The payload ranges of a message's packets: the init packet's, then each continuation packet's, in order.
private func forEachPacketRange(_ size: Int, _ body: (Range<Int>) -> Void) {
    var position = min(size, fido.kHidInitPacketDataSize)
    body(0..<position)
    while position < size {
        let end = min(position + fido.kHidContinuationPacketDataSize, size)
        body(position..<end)
        position = end
    }
}

// A received continuation packet's header and where its data is, or nil if it is not a whole packet.
private struct ContinuationHeader {
    var channelId: UInt32
    var sequence: UInt8
    var data: Range<Int>
    var remainingSize: UInt
}

private func readContinuationHeader(_ bytes: Span<UInt8>, _ remainingSize: Int) -> ContinuationHeader? {
    if bytes.count != fido.kHidPacketSize {
        return nil
    }
    // size_t in C++.
    let remaining = UInt(bitPattern: remainingSize)
    let dataSize = Int(min(remaining, UInt(fido.kHidContinuationPacketDataSize)))
    let start = fido.kHidContinuationPacketHeader
    return ContinuationHeader(channelId: readChannelId(bytes), sequence: bytes[4], data: start..<(start + dataSize), remainingSize: remaining - UInt(dataSize))
}

extension fido.FidoHidMessage {
    @cxx @implementation public static func serializedPackets(_ channelId: UInt32, _ cmd: fido.FidoHidDeviceCommand, _ data: cbor.CBORValue.BinaryValue) -> fido.ByteVectorVector {
        serializedPacketsBody(channelId, cmd, data)
    }

    private static func serializedPacketsBody(_ channelId: UInt32, _ cmd: fido.FidoHidDeviceCommand, _ data: cbor.CBORValue.BinaryValue) -> fido.ByteVectorVector {
        let bytes: Span<UInt8> = data.span()
        var packets = fido.ByteVectorVector()
        if !acceptsPayload(cmd, bytes) {
            return packets
        }
        let size = bytes.count
        // Fits: acceptsPayload bounds the size by kHidMaxMessageSize.
        let payloadLength = UInt16(size)
        var sequence: UInt8 = 0
        forEachPacketRange(size) { range in
            if range.lowerBound == 0 {
                packets.append(consuming: initPacket(channelId, cmd.rawValue, payloadLength, bytes, range))
            } else {
                packets.append(consuming: continuationPacket(channelId, sequence, bytes, range))
                sequence += 1
            }
        }
        return packets
    }

    @cxx @implementation public static func packetPayloads(_ cmd: fido.FidoHidDeviceCommand, _ data: cbor.CBORValue.BinaryValue) -> fido.ByteVectorVector {
        packetPayloadsBody(cmd, data)
    }

    private static func packetPayloadsBody(_ cmd: fido.FidoHidDeviceCommand, _ data: cbor.CBORValue.BinaryValue) -> fido.ByteVectorVector {
        let bytes: Span<UInt8> = data.span()
        var payloads = fido.ByteVectorVector()
        if !acceptsPayload(cmd, bytes) {
            return payloads
        }
        forEachPacketRange(bytes.count) { range in
            payloads.append(consuming: data.subvector(range.lowerBound, range.count))
        }
        return payloads
    }

    @cxx @implementation public static func parseInitPacket(_ serialized: cbor.CBORValue.BinaryValue) -> fido.HidMessageState {
        parseInitPacketBody(serialized)
    }

    private static func parseInitPacketBody(_ serialized: cbor.CBORValue.BinaryValue) -> fido.HidMessageState {
        // FidoHidMessage::createFromSerializedData's own bounds (7...64) admit only what this exact size admits.
        var state = fido.HidMessageState()
        if serialized.size() != fido.kHidPacketSize {
            return state
        }
        let bytes: Span<UInt8> = serialized.span()
        let raw = bytes[4] & 0x7f
        if !isFidoHidDeviceCommand(raw) {
            return state
        }
        let payloadSize = Int(bytes[5]) << 8 | Int(bytes[6])
        let dataSize = min(payloadSize, fido.kHidInitPacketDataSize)
        state.valid = true
        state.channelId = readChannelId(bytes)
        state.cmd = fido.FidoHidDeviceCommand(rawValue: raw)!
        state.payload = serialized.subvector(fido.kHidInitPacketHeaderSize, dataSize)
        state.remainingSize = payloadSize - dataSize
        return state
    }

    @cxx @implementation public static func parseContinuationPacket(_ serialized: cbor.CBORValue.BinaryValue, _ remainingSize: Int) -> fido.HidMessageState {
        parseContinuationPacketBody(serialized, remainingSize)
    }

    private static func parseContinuationPacketBody(_ serialized: cbor.CBORValue.BinaryValue, _ remainingSize: Int) -> fido.HidMessageState {
        var state = fido.HidMessageState()
        let bytes: Span<UInt8> = serialized.span()
        guard let header = readContinuationHeader(bytes, remainingSize) else {
            return state
        }
        state.valid = true
        state.channelId = header.channelId
        state.sequence = header.sequence
        state.payload = serialized.subvector(header.data.lowerBound, header.data.count)
        state.remainingSize = Int(bitPattern: header.remainingSize)
        return state
    }

    // An invalid result (the packet is not whole, or is on another channel) leaves the message as it was.
    // A packet after the message is complete is accepted and adds nothing; sequence numbers are not checked.
    @cxx @implementation public static func addContinuation(_ message: fido.HidMessageState, _ serialized: cbor.CBORValue.BinaryValue) -> fido.HidMessageState {
        addContinuationBody(message, serialized)
    }

    private static func addContinuationBody(_ message: fido.HidMessageState, _ serialized: cbor.CBORValue.BinaryValue) -> fido.HidMessageState {
        let bytes: Span<UInt8> = serialized.span()
        guard let header = readContinuationHeader(bytes, message.remainingSize), header.channelId == message.channelId else {
            return fido.HidMessageState()
        }
        var result = message
        result.valid = true
        result.sequence = header.sequence
        result.remainingSize = Int(bitPattern: header.remainingSize)
        if result.payload.isEmpty() {
            result.payload = serialized.subvector(header.data.lowerBound, header.data.count)
        } else {
            result.payload.reserveCapacity(result.payload.size() + header.data.count)
            appendBytes(&result.payload, bytes, header.data)
        }
        return result
    }

    @cxx @implementation public static func serializeInitPacket(_ channelId: UInt32, _ cmd: fido.FidoHidDeviceCommand, _ payloadLength: UInt16, _ data: cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue {
        serializeInitPacketBody(channelId, cmd, payloadLength, data)
    }

    private static func serializeInitPacketBody(_ channelId: UInt32, _ cmd: fido.FidoHidDeviceCommand, _ payloadLength: UInt16, _ data: cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue {
        let bytes: Span<UInt8> = data.span()
        return initPacket(channelId, cmd.rawValue, payloadLength, bytes, 0..<bytes.count)
    }

    @cxx @implementation public static func serializeContinuationPacket(_ channelId: UInt32, _ sequence: UInt8, _ data: cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue {
        serializeContinuationPacketBody(channelId, sequence, data)
    }

    private static func serializeContinuationPacketBody(_ channelId: UInt32, _ sequence: UInt8, _ data: cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue {
        let bytes: Span<UInt8> = data.span()
        return continuationPacket(channelId, sequence, bytes, 0..<bytes.count)
    }
}

#endif // !os(watchOS) && !targetEnvironment(macCatalyst)
