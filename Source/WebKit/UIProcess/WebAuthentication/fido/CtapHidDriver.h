/*
 * Copyright (C) 2018-2025 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(WEB_AUTHN)

#include "CtapDriver.h"
#include "HidConnection.h"
#include <WebCore/FidoHidMessage.h>
#include <wtf/SwiftBridging.h>

namespace WebKit {

// The following implements the CTAP HID protocol:
// https://fidoalliance.org/specs/fido-v2.0-ps-20170927/fido-client-to-authenticator-protocol-v2.0-ps-20170927.html#usb
// FSM: Idle => AllocateChannel => Ready
// The transaction worker's FSM: Idle => Write => Read.
// https://fidoalliance.org/specs/fido-v2.0-ps-20170927/fido-client-to-authenticator-protocol-v2.0-ps-20170927.html#arbitration
class SWIFT_PRIVATE_FILEID("WebKit/CtapHidDriver.swift") CtapHidDriver final : public CtapDriver {
public:
    enum class State : uint8_t {
        Idle,
        AllocateChannel,
        Ready,
        // FIXME(191528)
        Busy
    };

    static Ref<CtapHidDriver> create(Ref<HidConnection>&&);
    ~CtapHidDriver();

    void transact(Vector<uint8_t>&& data, ResponseCallback&&) final;
    void cancel() final;

private:
    explicit CtapHidDriver(Ref<HidConnection>&&);

    enum class WorkerState : uint8_t { Idle, Write, Read };
    enum class PendingStep : uint8_t { None, ChannelAllocated, ResponseReceived };

    void startTransaction();
    void workerWrite(HidConnection::DataSent);
    void workerRead(Vector<uint8_t>);
    void sendPacket(Vector<uint8_t>);
    void listenForData();
    void retryTransactionAsync();
    void returnResponse(Vector<uint8_t>);
    void reset();

    const Ref<HidConnection> m_connection;
    WorkerState m_workerState { WorkerState::Idle };
    Vector<Vector<uint8_t>> m_requestPackets;
    size_t m_nextRequestPacket { 0 };
    uint32_t m_requestChannelId { 0 };
    fido::HidMessageState m_responseMessage;
    PendingStep m_pendingStep { PendingStep::None };
    State m_state { State::Idle };
    uint32_t m_channelId { fido::kHidBroadcastChannel };
    // One request at a time.
    Vector<uint8_t> m_requestData;
    ResponseCallback m_responseCallback;
    Vector<uint8_t> m_nonce;
};

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
