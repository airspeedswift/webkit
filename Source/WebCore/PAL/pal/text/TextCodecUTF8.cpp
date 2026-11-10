/*
 * Copyright (C) 2004-2020 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "TextCodecUTF8.h"

#include "TextCodecASCIIFastPath.h"
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/CString.h>
#include <wtf/text/ParsingUtilities.h>
#include <wtf/text/StringBuffer.h>
#include <wtf/text/WTFString.h>
#include <wtf/unicode/CharacterNames.h>

#include "PALSwiftBoundaryTypes.h"

namespace PAL {

WTF_MAKE_TZONE_ALLOCATED_IMPL(TextCodecUTF8);

void TextCodecUTF8::registerEncodingNames(EncodingNameRegistrar registrar)
{
    // From https://encoding.spec.whatwg.org.
    registrar("UTF-8"_s, "UTF-8"_s);
    registrar("utf8"_s, "UTF-8"_s);
    registrar("unicode-1-1-utf-8"_s, "UTF-8"_s);

    // Additional aliases that originally were present in the encoding
    // table in WebKit on Macintosh, and subsequently added by
    // TextCodecICU. Perhaps we can prove some are not used on the web
    // and remove them.
    registrar("unicode11utf8"_s, "UTF-8"_s);
    registrar("unicode20utf8"_s, "UTF-8"_s);
    registrar("x-unicode20utf8"_s, "UTF-8"_s);
}

std::unique_ptr<TextCodecUTF8> TextCodecUTF8::codec()
{
    return makeUnique<TextCodecUTF8>();
}

void TextCodecUTF8::registerCodecs(TextCodecRegistrar registrar)
{
    registrar("UTF-8"_s, [] {
        return codec();
    });
}

String TextCodecUTF8::decode(std::span<const uint8_t> bytes, bool flush, bool stopOnError, bool& sawError)
{
    // Each input byte might turn into a character.
    // That includes all bytes in the partial-sequence buffer because
    // each byte in an invalid sequence will turn into a replacement character.
    size_t bufferSize = m_partialSequenceSize + bytes.size();
    if (bufferSize > std::numeric_limits<unsigned>::max()) {
        sawError = true;
        return { };
    }

    auto adoptDecodedCharacters = [&]<typename CharacterType>(StringBuffer<CharacterType>& buffer, const TextCodecUTF8DecodeResult& result) -> String {
        RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(result.charactersWritten <= buffer.length());
        RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(result.state.partialSequenceSize <= m_partialSequence.size());
        if (result.sawError)
            sawError = true;
        m_partialSequence = { result.state.partialSequence0, result.state.partialSequence1, result.state.partialSequence2, result.state.partialSequence3 };
        m_partialSequenceSize = result.state.partialSequenceSize;
        m_shouldStripByteOrderMark = result.state.shouldStripByteOrderMark;
        buffer.shrink(result.charactersWritten);
        if (buffer.length() > String::MaxLength) {
            sawError = true;
            return { };
        }
        return String::adopt(WTF::move(buffer));
    };

    static_assert(std::tuple_size_v<decltype(m_partialSequence)> == 4);
    TextCodecUTF8DecoderState state { m_partialSequence[0], m_partialSequence[1], m_partialSequence[2], m_partialSequence[3], static_cast<uint8_t>(m_partialSequenceSize), m_shouldStripByteOrderMark };
    StringBuffer<Latin1Character> buffer(bufferSize);
    auto result = pal::decodeUTF8ToLatin1(state, bytes, byteCast<uint8_t>(buffer.span()), flush, stopOnError);
    if (!result.needsUpconvert)
        return adoptDecodedCharacters(buffer, result);

    RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(result.charactersWritten <= bufferSize);
    RELEASE_ASSERT_WITH_SECURITY_IMPLICATION(result.bytesRead <= bytes.size());
    if (result.sawError)
        sawError = true;
    StringBuffer<char16_t> buffer16(bufferSize);
    StringImpl::copyCharacters(buffer16.span(), buffer.span().first(result.charactersWritten));
    result = pal::decodeUTF8ToUTF16(result.state, bytes.subspan(result.bytesRead), buffer16.span(), result.charactersWritten, flush, stopOnError);
    return adoptDecodedCharacters(buffer16, result);
}

Vector<uint8_t> TextCodecUTF8::encodeUTF8(StringView string)
{
    // The buffer size is string.length() * maxBytesPerUnit, where maxBytesPerUnit is the
    // worst-case UTF-8 bytes per input code unit.
    // - 8-bit (Latin1) strings: max 2 UTF-8 bytes per character (for 0x80-0xFF).
    // - 16-bit strings: max 3 UTF-8 bytes per code unit (BMP characters use 1 code unit
    //   and up to 3 bytes; non-BMP use 2 code units and 4 bytes, i.e. only 2 per unit).
    size_t maxBytesPerUnit = string.is8Bit() ? 2 : 3;
    Vector<uint8_t> bytes(WTF::checkedProduct<size_t>(string.length(), maxBytesPerUnit));
    size_t bytesWritten = 0;
    for (auto character : string.codePoints())
        U8_APPEND_UNSAFE(bytes, bytesWritten, character);
    bytes.shrink(bytesWritten);
    return bytes;
}

Vector<uint8_t> TextCodecUTF8::encode(StringView string, UnencodableHandling) const
{
    return encodeUTF8(string);
}

} // namespace PAL
