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
#include "CBORWriter.h"

#if ENABLE(WEB_AUTHN)

#include "CBORBinary.h"
#include "CBORReader.h"
#include "WebCore-Swift.h"

namespace cbor {

// The numbers that WebAuthnCBOR.swift spells as literals: CBORBinary.h is not in a header Swift sees, and class-scope
// constants do not import.
static_assert(constants::kMajorTypeBitShift == 5 && constants::kAdditionalInformationMask == 0x1F);
static_assert(constants::kAdditionalInformation1Byte == 24 && constants::kAdditionalInformation2Bytes == 25);
static_assert(constants::kAdditionalInformation4Bytes == 26 && constants::kAdditionalInformation8Bytes == 27);
static_assert(static_cast<int>(CBORValue::Type::Unsigned) == 0 && static_cast<int>(CBORValue::Type::Negative) == 1);
static_assert(static_cast<int>(CBORValue::Type::ByteString) == 2 && static_cast<int>(CBORValue::Type::String) == 3);
static_assert(static_cast<int>(CBORValue::Type::Array) == 4 && static_cast<int>(CBORValue::Type::Map) == 5);
static_assert(static_cast<int>(CBORValue::Type::SimpleValue) == 7);
static_assert(static_cast<int>(CBORValue::SimpleValue::FalseValue) == 20 && static_cast<int>(CBORValue::SimpleValue::TrueValue) == 21);
static_assert(static_cast<int>(CBORValue::SimpleValue::NullValue) == 22 && static_cast<int>(CBORValue::SimpleValue::Undefined) == 23);
static_assert(CBORReader::kCBORMaxDepth == 16 && CBORWriter::kDefaultMaxNestingDepth == 16);

// static
std::optional<Vector<uint8_t>> CBORWriter::write(const CBORValue& node, size_t maxNestingLevel)
{
    auto cbor = WebCore::cborWrite(node, maxNestingLevel);
    if (cbor.isEmpty())
        return std::nullopt;
    return cbor;
}

} // namespace cbor

#endif // ENABLE(WEB_AUTHN)
