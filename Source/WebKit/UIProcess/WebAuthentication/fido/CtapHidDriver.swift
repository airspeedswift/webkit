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

// The CTAP HID protocol and its transaction worker.
// https://fidoalliance.org/specs/fido-v2.0-ps-20170927/fido-client-to-authenticator-protocol-v2.0-ps-20170927.html#usb
//
// The worker sends one message as packets, then reads the response packets until the message is complete, keeping
// its state in the driver's fields. A step names what to do with the response: finish the channel allocation, or
// hand the response to the caller.

extension WebKit.CtapHidDriver {
    // The driver's transact(): allocates a channel with a CTAPHID_INIT carrying a nonce.
    @cxx @implementation
    func startTransaction() {
        if !isValidSize(m_requestData.size()) {
            WebKit.LogChannel.WebAuthn().releaseLog.log(
                "CtapHidDriver::transact Sending data larger than maxSize. msgSize=\(self.m_requestData.size())"
            )
        }
        assert(m_state == .Idle)
        m_state = .AllocateChannel
        m_channelId = fido.kHidBroadcastChannel

        // A pseudo random nonce, not a cryptographically strong one: the nonce only identifies the response.
        var nonce = cbor.CBORValue.BinaryValue()
        nonce.reserveCapacity(fido.kHidInitNonceLength)
        for _ in 0..<(fido.kHidInitNonceLength / MemoryLayout<UInt32>.size) {
            let random = UInt32.random(in: UInt32.min...UInt32.max)
            // In host byte order.
            nonce.append(consuming: UInt8(truncatingIfNeeded: random))
            nonce.append(consuming: UInt8(truncatingIfNeeded: random >> 8))
            nonce.append(consuming: UInt8(truncatingIfNeeded: random >> 16))
            nonce.append(consuming: UInt8(truncatingIfNeeded: random >> 24))
        }
        m_nonce = nonce

        let packets = fido.FidoHidMessage.serializedPackets(m_channelId, .`init`, m_nonce)
        workerTransact(packets, channelId: m_channelId, allocatingChannel: true)
    }

    // CTAPHID_CANCEL, which breaks the transaction rule of one request and one response:
    // https://fidoalliance.org/specs/fido-v2.0-ps-20190130/fido-client-to-authenticator-protocol-v2.0-ps-20190130.html#usb-hid-cancel
    @cxx @implementation
    public override func cancel() {
        if m_state == .Idle || !isCtap2Protocol() {
            return
        }
        // Cancel any outstanding request.
        if m_state == .Ready {
            let packets = fido.FidoHidMessage.serializedPackets(m_channelId, .cancel, cbor.CBORValue.BinaryValue())
            workerReset()
            m_connection.get().invalidateCache()
            assert(packets.size() == 1)
            _ = m_connection.get().sendSync(packets[0])
        }
        reset()
    }

    // The connection's answer to the last packet sent.
    @cxx @implementation
    func workerWrite(_ sent: WebKit.HidConnection.DataSent) {
        if m_workerState != .Write {
            return
        }
        if sent != .Yes {
            m_responseMessage = fido.HidMessageState()
            workerReturnMessage()
            return
        }
        if m_nextRequestPacket >= m_requestPackets.size() {
            m_workerState = .Read
            // Last: the connection may hand over buffered reports, and so call workerRead, before this returns.
            listenForData()
            return
        }
        sendNextPacket()
    }

    // One report from the connection.
    @cxx @implementation
    func workerRead(_ data: cbor.CBORValue.BinaryValue) {
        if m_workerState != .Read {
            return
        }
        if !m_responseMessage.valid {
            let message = fido.FidoHidMessage.parseInitPacket(data)
            // The first reports could be for other applications: ignore those.
            if !message.valid || message.channelId != m_requestChannelId {
                let reason = message.valid ? "wrong channel id." : "bad data."
                WebKit.LogChannel.WebAuthn().debugLog.error("Couldn't parse a hid init packet: \(reason)")
                m_responseMessage = fido.HidMessageState()
                return
            }
            m_responseMessage = message
        } else {
            let response = m_responseMessage
            var current = fido.HidMessageState()
            current.valid = true
            current.channelId = response.channelId
            current.cmd = response.cmd
            current.remainingSize = response.remainingSize
            let continuation = fido.FidoHidMessage.addContinuation(current, data)
            if !continuation.valid {
                WebKit.LogChannel.WebAuthn().debugLog.error("Couldn't parse a hid continuation packet.")
                m_responseMessage = fido.HidMessageState()
                workerReturnMessage()
                return
            }
            m_responseMessage.remainingSize = continuation.remainingSize
            m_responseMessage.sequence = continuation.sequence
            for byte in continuation.payload {
                m_responseMessage.payload.append(consuming: byte)
            }
        }

        if m_responseMessage.remainingSize == 0 {
            // A keep-alive can come between a request and its response while the authenticator waits for the user.
            // Keep listening for the response.
            if m_responseMessage.cmd == .keepAlive {
                m_responseMessage = fido.HidMessageState()
                return
            }
            workerReturnMessage()
        }
    }
}

extension WebKit.CtapHidDriver {
    private func workerTransact(_ packets: fido.ByteVectorVector, channelId: UInt32, allocatingChannel: Bool) {
        assert(m_workerState == .Idle)
        // An empty list is a message FidoHidMessage::create refused.
        guard !packets.isEmpty() else {
            fatalError("CtapHidDriver: the request cannot be framed as a HID message")
        }
        m_workerState = .Write
        m_requestPackets = packets
        m_nextRequestPacket = 0
        m_requestChannelId = channelId
        m_responseMessage = fido.HidMessageState()
        m_pendingStep = allocatingChannel ? .ChannelAllocated : .ResponseReceived

        // The connection could hold data from other applications: invalidate it before each transaction.
        m_connection.get().invalidateCache()
        sendNextPacket()
    }

    private func sendNextPacket() {
        let packet = m_requestPackets[m_nextRequestPacket]
        m_nextRequestPacket += 1
        sendPacket(packet)
    }

    private func workerReset() {
        m_connection.get().unregisterDataReceivedCallback()
        m_pendingStep = .None
        m_responseMessage = fido.HidMessageState()
        m_requestPackets = fido.ByteVectorVector()
        m_nextRequestPacket = 0
        m_workerState = .Idle
    }

    // Resets the worker before the step runs, since the step can start the next transaction.
    private func workerReturnMessage() {
        let allocatingChannel = m_pendingStep == .ChannelAllocated
        let respondingToRequest = m_pendingStep == .ResponseReceived
        let message = m_responseMessage
        workerReset()
        if allocatingChannel {
            continueAfterChannelAllocated(message)
        } else if respondingToRequest {
            continueAfterResponseReceived(message)
        }
    }

    private func continueAfterChannelAllocated(_ message: fido.HidMessageState) {
        if m_state != .AllocateChannel {
            return
        }
        if !message.valid {
            returnResponse(cbor.CBORValue.BinaryValue())
            return
        }
        assert(message.channelId == m_channelId)

        let payload = message.payload
        if payload.size() < fido.kHidInitResponseSize || !hasNoncePrefix(payload) {
            m_state = .Idle
            retryTransactionAsync()
            return
        }

        m_state = .Ready
        let index = fido.kHidInitNonceLength
        var channelId = UInt32(payload[index]) << 24
        channelId |= UInt32(payload[index + 1]) << 16
        channelId |= UInt32(payload[index + 2]) << 8
        channelId |= UInt32(payload[index + 3])
        m_channelId = channelId
        // FIXME(191534): Check the rest of the payload.
        let command: fido.FidoHidDeviceCommand = isCtap2Protocol() ? .cbor : .msg
        let packets = fido.FidoHidMessage.serializedPackets(m_channelId, command, m_requestData)
        workerTransact(packets, channelId: m_channelId, allocatingChannel: false)
    }

    private func continueAfterResponseReceived(_ message: fido.HidMessageState) {
        if m_state != .Ready {
            return
        }
        assert(!message.valid || message.channelId == m_channelId)
        returnResponse(message.valid ? message.payload : cbor.CBORValue.BinaryValue())
    }

    private func hasNoncePrefix(_ payload: cbor.CBORValue.BinaryValue) -> Bool {
        let nonce = m_nonce
        if payload.size() < nonce.size() {
            return false
        }
        for i in 0..<nonce.size() where payload[i] != nonce[i] {
            return false
        }
        return true
    }
}

#endif // ENABLE_WEB_AUTHN
