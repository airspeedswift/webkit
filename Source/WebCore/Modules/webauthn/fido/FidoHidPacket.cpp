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
#include "FidoHidPacket.h"

#if ENABLE(WEB_AUTHN)

#include "FidoHidMessage.h"
#include <wtf/TZoneMallocInlines.h>

namespace fido {

WTF_MAKE_TZONE_ALLOCATED_IMPL(FidoHidPacket);
WTF_MAKE_TZONE_ALLOCATED_IMPL(FidoHidInitPacket);
WTF_MAKE_TZONE_ALLOCATED_IMPL(FidoHidContinuationPacket);

FidoHidPacket::FidoHidPacket(Vector<uint8_t>&& data, uint32_t channelId)
    : m_data(WTF::move(data))
    , m_channelId(channelId)
{
}

// static
std::unique_ptr<FidoHidInitPacket> FidoHidInitPacket::createFromSerializedData(Vector<uint8_t> serialized, size_t* remainingSize)
{
    if (!remainingSize)
        return nullptr;
    auto state = FidoHidMessage::parseInitPacket(WTF::move(serialized));
    if (!state.valid)
        return nullptr;
    *remainingSize = state.remainingSize;
    auto payloadLength = static_cast<uint16_t>(state.payload.size() + state.remainingSize);
    return makeUnique<FidoHidInitPacket>(state.channelId, state.cmd, WTF::move(state.payload), payloadLength);
}

// U2F Initialization packet is defined as:
// Offset Length
// 0      4       Channel ID
// 4      1       Command ID
// 5      1       High order packet payload size
// 6      1       Low order packet payload size
// 7      (s-7)   Payload data
FidoHidInitPacket::FidoHidInitPacket(uint32_t channelId, FidoHidDeviceCommand cmd, Vector<uint8_t>&& data, uint16_t payloadLength)
    : FidoHidPacket(WTF::move(data), channelId)
    , m_command(cmd)
    , m_payloadLength(payloadLength)
{
}

Vector<uint8_t> FidoHidInitPacket::getSerializedData() const
{
    return FidoHidMessage::serializeInitPacket(m_channelId, m_command, m_payloadLength, m_data);
}

// static
std::unique_ptr<FidoHidContinuationPacket> FidoHidContinuationPacket::createFromSerializedData(Vector<uint8_t> serialized, size_t* remainingSize)
{
    if (!remainingSize)
        return nullptr;
    auto state = FidoHidMessage::parseContinuationPacket(WTF::move(serialized), *remainingSize);
    if (!state.valid)
        return nullptr;
    *remainingSize = state.remainingSize;
    return makeUnique<FidoHidContinuationPacket>(state.channelId, state.sequence, WTF::move(state.payload));
}

// U2F Continuation packet is defined as:
// Offset Length
// 0      4       Channel ID
// 4      1       Packet sequence 0x00..0x7f
// 5      (s-5)   Payload data
FidoHidContinuationPacket::FidoHidContinuationPacket(const uint32_t channelId, const uint8_t sequence, Vector<uint8_t>&& data)
    : FidoHidPacket(WTF::move(data), channelId)
    , m_sequence(sequence)
{
}

Vector<uint8_t> FidoHidContinuationPacket::getSerializedData() const
{
    return FidoHidMessage::serializeContinuationPacket(m_channelId, m_sequence, m_data);
}

} // namespace fido

#endif // ENABLE(WEB_AUTHN)
