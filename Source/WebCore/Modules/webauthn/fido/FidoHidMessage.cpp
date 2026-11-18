// Copyright 2017 The Chromium Authors. All rights reserved.
// Copyright (C) 2018 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#include "config.h"
#include "FidoHidMessage.h"

#if ENABLE(WEB_AUTHN)

#include <wtf/Vector.h>

namespace fido {

// static
std::optional<FidoHidMessage> FidoHidMessage::create(uint32_t channelId, FidoHidDeviceCommand type, Vector<uint8_t> data)
{
    auto payloadLength = static_cast<uint16_t>(data.size());
    auto payloads = packetPayloads(type, WTF::move(data));
    if (payloads.isEmpty())
        return std::nullopt;
    return FidoHidMessage(channelId, type, WTF::move(payloads), payloadLength);
}

// static
std::optional<FidoHidMessage> FidoHidMessage::createFromSerializedData(Vector<uint8_t> serializedData)
{
    auto state = parseInitPacket(WTF::move(serializedData));
    if (!state.valid)
        return std::nullopt;
    auto payloadLength = static_cast<uint16_t>(state.payload.size() + state.remainingSize);
    return FidoHidMessage(makeUnique<FidoHidInitPacket>(state.channelId, state.cmd, WTF::move(state.payload), payloadLength), state.remainingSize);
}

bool FidoHidMessage::messageComplete() const
{
    return !m_remainingSize;
}

Vector<uint8_t> FidoHidMessage::getMessagePayload() const
{
    Vector<uint8_t> data;
    size_t dataSize = 0;
    for (const auto& packet : m_packets)
        dataSize += packet->getPacketPayload().size();
    data.reserveInitialCapacity(dataSize);

    for (const auto& packet : m_packets) {
        const auto& packet_data = packet->getPacketPayload();
        data.appendVector(packet_data);
    }

    return data;
}

Vector<uint8_t> FidoHidMessage::popNextPacket()
{
    if (m_packets.isEmpty())
        return { };

    Vector<uint8_t> data = m_packets.first()->getSerializedData();
    m_packets.removeFirst();
    return data;
}

bool FidoHidMessage::addContinuationPacket(Vector<uint8_t> buf)
{
    auto state = addContinuation({ true, m_channelId, m_cmd, 0, { }, m_remainingSize }, WTF::move(buf));
    if (!state.valid)
        return false;
    m_remainingSize = state.remainingSize;
    m_packets.append(makeUnique<FidoHidContinuationPacket>(m_channelId, state.sequence, WTF::move(state.payload)));
    return true;
}

size_t FidoHidMessage::numPackets() const
{
    return m_packets.size();
}

FidoHidMessage::FidoHidMessage(uint32_t channelId, FidoHidDeviceCommand type, Vector<Vector<uint8_t>>&& payloads, uint16_t payloadLength)
    : m_channelId(channelId)
    , m_cmd(type)
{
    m_packets.append(makeUnique<FidoHidInitPacket>(channelId, type, WTF::move(payloads[0]), payloadLength));
    for (size_t i = 1; i < payloads.size(); ++i)
        m_packets.append(makeUnique<FidoHidContinuationPacket>(channelId, static_cast<uint8_t>(i - 1), WTF::move(payloads[i])));
}

FidoHidMessage::FidoHidMessage(std::unique_ptr<FidoHidInitPacket> initPacket, size_t remainingSize)
    : m_remainingSize(remainingSize)
{
    m_channelId = initPacket->channelId();
    m_cmd = initPacket->command();
    m_packets.append(WTF::move(initPacket));
}

} // namespace fido

#endif // ENABLE(WEB_AUTHN)
