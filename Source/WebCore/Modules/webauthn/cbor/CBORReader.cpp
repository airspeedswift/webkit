// Copyright 2017 The Chromium Authors. All rights reserved.
// Copyright (C) 2018-2023 Apple Inc. All rights reserved.
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
#include "CBORReader.h"

#if ENABLE(WEB_AUTHN)

#include "WebCore-Swift.h"

namespace cbor {

std::optional<CBORValue> CBORReader::read(const Bytes& data, DecoderError* errorCodeOut, int maxNestingLevel)
{
    ReadResult result;
    WebCore::cborReadResult(data, maxNestingLevel, false, result);
    if (errorCodeOut)
        *errorCodeOut = result.error;
    if (result.error != DecoderError::CBORNoError || result.value.isNone())
        return std::nullopt;
    return WTF::move(result.value);
}

std::optional<std::pair<CBORValue, size_t>> CBORReader::readWithBytesConsumed(const Bytes& data, DecoderError* errorCodeOut, int maxNestingLevel)
{
    ReadResult result;
    WebCore::cborReadResult(data, maxNestingLevel, true, result);
    if (errorCodeOut)
        *errorCodeOut = result.error;
    if (result.error != DecoderError::CBORNoError || result.value.isNone())
        return std::nullopt;
    return std::make_pair(WTF::move(result.value), result.bytesConsumed);
}

} // namespace cbor

#endif // ENABLE(WEB_AUTHN)
