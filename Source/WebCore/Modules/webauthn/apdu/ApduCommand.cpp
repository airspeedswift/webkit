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
#include "ApduCommand.h"

#if ENABLE(WEB_AUTHN)

namespace apdu {

// WebAuthnApdu.swift spells these as literals (static constexpr members do not import).
static_assert(ApduCommand::kApduMinHeader == 4 && ApduCommand::kApduCommandLengthOffset == 5 && ApduCommand::kApduCommandDataOffset == 7);
static_assert(ApduCommand::kApduMaxDataLength == 65535 && ApduCommand::kApduMaxResponseLength == 65536 && ApduCommand::kApduMaxLength == 65544);

ApduCommand::ApduCommand(uint8_t cla, uint8_t ins, uint8_t p1, uint8_t p2, size_t responseLength, Vector<uint8_t>&& data)
    : m_cla(cla)
    , m_ins(ins)
    , m_p1(p1)
    , m_p2(p2)
    , m_responseLength(responseLength)
    , m_data(WTF::move(data))
{
}

Vector<uint8_t> ApduCommand::getEncodedCommand() const
{
    return encodeCommand(m_cla, m_ins, m_p1, m_p2, m_responseLength, m_data);
}

} // namespace apdu

#endif // ENABLE(WEB_AUTHN)
