// Copyright 2015 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2024 Apple Inc. All rights reserved.
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
#include "CSSTokenizer.h"

#include "CSSParserIdioms.h"
#include "CSSParserObserverWrapper.h"
#include "CSSParserTokenRange.h"
#include "CSSTokenizerInputStream.h"
#include <wtf/NeverDestroyed.h>
#include <wtf/SIMDHelpers.h>
#include <wtf/text/CodePointIterator.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/unicode/CharacterNames.h>

#include "WebCore-Swift.h"

namespace WebCore {
DEFINE_ALLOCATOR_WITH_HEAP_IDENTIFIER(CSSTokenizer);

static_assert(std::is_empty_v<CSSTokenizerSink>);
static_assert(!std::is_polymorphic_v<CSSTokenizerSink>);
static_assert(!std::is_default_constructible_v<CSSTokenizerSink>);
static_assert(!std::is_copy_constructible_v<CSSTokenizerSink>);
static_assert(!std::is_copy_assignable_v<CSSTokenizerSink>);
static_assert(!std::is_move_assignable_v<CSSTokenizerSink>);
static_assert(std::is_move_constructible_v<CSSTokenizerSink>);
static_assert(!std::is_trivially_destructible_v<CSSTokenizerSink>);

// The token types each member of CSSTokenizerSink accepts, as bits of a mask.
static constexpr uint64_t simpleTokenTypes = 1ull << BadUrlToken | 1ull << IncludeMatchToken | 1ull << DashMatchToken
    | 1ull << PrefixMatchToken | 1ull << SuffixMatchToken | 1ull << SubstringMatchToken | 1ull << ColumnToken
    | 1ull << NewlineToken | 1ull << CDOToken | 1ull << CDCToken | 1ull << ColonToken | 1ull << SemicolonToken
    | 1ull << CommaToken | 1ull << LeftParenthesisToken | 1ull << RightParenthesisToken | 1ull << LeftBracketToken
    | 1ull << RightBracketToken | 1ull << LeftBraceToken | 1ull << RightBraceToken | 1ull << BadStringToken;
static constexpr uint64_t valueTokenTypes = 1ull << IdentToken | 1ull << FunctionToken | 1ull << AtKeywordToken
    | 1ull << UrlToken | 1ull << StringToken;
static_assert(numberOfCSSParserTokenTypes <= 64);

// The token types each block type goes with: openers and functions start a block, closers may end one.
static constexpr uint64_t blockStartTokenTypes = 1ull << LeftParenthesisToken | 1ull << LeftBracketToken | 1ull << LeftBraceToken
    | 1ull << FunctionToken;
static constexpr uint64_t blockEndTokenTypes = 1ull << RightParenthesisToken | 1ull << RightBracketToken | 1ull << RightBraceToken;
static constexpr std::array<uint64_t, 3> tokenTypesForBlockType {
    (simpleTokenTypes | valueTokenTypes) & ~blockStartTokenTypes,
    blockStartTokenTypes,
    blockEndTokenTypes,
};
static_assert(!CSSParserToken::NotBlock && CSSParserToken::BlockStart == 1 && CSSParserToken::BlockEnd == 2);

// CSSTokenizerSwift.swift keeps its own copies of these.
static_assert(replacementCharacter == 0xFFFD);
static_assert(UCHAR_MAX_VALUE == 0x10FFFF);
static_assert(!kEndOfFileMarker);

// The state behind the CSSTokenizerSink that the constructor passes to the Swift scanner.
struct CSSTokenizerSinkState final : CSSTokenizerSink {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    CSSTokenizerSinkState(CSSTokenizer& tokenizer, CSSParserObserverWrapper* wrapper)
        : tokenizer(tokenizer)
        , wrapper(wrapper)
    {
    }

    static CSSParserToken::BlockType checkedBlockType(uint8_t type, uint8_t blockType, uint64_t types)
    {
        RELEASE_ASSERT(type < 64 && blockType <= CSSParserToken::BlockEnd && ((types & tokenTypesForBlockType[blockType]) >> type & 1));
        return static_cast<CSSParserToken::BlockType>(blockType);
    }

    unsigned inputLength() const { return tokenizer.m_input.length(); }

    StringView range(uint32_t start, uint32_t length)
    {
        RELEASE_ASSERT(length <= inputLength() && start <= inputLength() - length);
        return tokenizer.m_input.rangeAt(start, length);
    }

    void pool(std::span<const char16_t> characters)
    {
        RELEASE_ASSERT(characters.size() <= inputLength());
        pooledValue = tokenizer.registerString(String { StringImpl::create8BitIfPossible(characters) });
        hasPooledValue = true;
    }

    // A range of the input, or the value pool() left pending, which only one token can take.
    StringView value(bool pooled, uint32_t start, uint32_t length)
    {
        if (!pooled)
            return range(start, length);
        RELEASE_ASSERT(hasPooledValue);
        return pooledValue;
    }

    [[clang::always_inline]] CSSParserToken number(bool isInteger, uint8_t sign, uint32_t start, uint32_t length, double value)
    {
        RELEASE_ASSERT(sign <= MinusSign);
        auto text = range(start, length);
        bool isResultOK = !std::isnan(value);
        if (!isResultOK)
            value = text.is8Bit() ? charactersToDouble(text.span8(), &isResultOK) : charactersToDouble(text.span16(), &isResultOK);
        return CSSParserToken(isResultOK ? value : 0.0, isInteger ? IntegerValueType : NumberValueType, static_cast<NumericSign>(sign), text);
    }

    bool append(CSSParserToken&& token)
    {
        hasPooledValue = false;
        return tokenizer.m_tokens.tryAppend(WTF::move(token));
    }

    CSSTokenizer& tokenizer;
    CSSParserObserverWrapper* const wrapper;
    StringView pooledValue;
    bool hasPooledValue { false };
};

// Every CSSTokenizerSink is a CSSTokenizerSinkState: only the constructor makes one, on its stack, and
// Swift cannot copy or move it.
[[clang::always_inline]] static CSSTokenizerSinkState& sinkState(CSSTokenizerSink& sink)
{
    return static_cast<CSSTokenizerSinkState&>(sink);
}

CSSTokenizerSink::CSSTokenizerSink(CSSTokenizerSink&&)
{
    RELEASE_ASSERT_NOT_REACHED();
}

CSSTokenizerSink::~CSSTokenizerSink() = default;

[[clang::always_inline]] bool CSSTokenizerSink::hasObserver()
{
    return sinkState(*this).wrapper;
}

[[clang::always_inline]] bool CSSTokenizerSink::simpleToken(uint8_t type, uint8_t blockType)
{
    auto& state = sinkState(*this);
    return state.append(CSSParserToken(static_cast<CSSParserTokenType>(type), state.checkedBlockType(type, blockType, simpleTokenTypes)));
}

[[clang::always_inline]] bool CSSTokenizerSink::whitespaceToken(uint32_t count)
{
    auto& state = sinkState(*this);
    RELEASE_ASSERT(count && count <= state.inputLength());
    return state.append(CSSParserToken(count));
}

[[clang::always_inline]] bool CSSTokenizerSink::delimiterToken(char16_t character)
{
    auto& state = sinkState(*this);
    RELEASE_ASSERT(isASCII(character));
    return state.append(CSSParserToken(DelimiterToken, character));
}

[[clang::always_inline]] bool CSSTokenizerSink::valueToken(uint8_t type, uint8_t blockType, bool pooled, uint32_t start, uint32_t length)
{
    auto& state = sinkState(*this);
    return state.append(CSSParserToken(static_cast<CSSParserTokenType>(type), state.value(pooled, start, length), state.checkedBlockType(type, blockType, valueTokenTypes)));
}

[[clang::always_inline]] bool CSSTokenizerSink::hashToken(bool isIdentifier, bool pooled, uint32_t start, uint32_t length)
{
    auto& state = sinkState(*this);
    return state.append(CSSParserToken(isIdentifier ? HashTokenId : HashTokenUnrestricted, state.value(pooled, start, length)));
}

[[clang::always_inline]] bool CSSTokenizerSink::numericToken(CSSTokenizerNumericKind kind, bool isInteger, uint8_t sign, uint32_t start, uint32_t length, uint32_t unitStart, uint32_t unitLength, double value)
{
    auto& state = sinkState(*this);
    RELEASE_ASSERT(kind <= CSSTokenizerPooledDimension);
    auto token = state.number(isInteger, sign, start, length, value);
    if (kind == CSSTokenizerPercentage)
        token.convertToPercentage();
    else if (kind != CSSTokenizerNumber)
        token.convertToDimensionWithUnit(state.value(kind == CSSTokenizerPooledDimension, unitStart, unitLength));
    return state.append(WTF::move(token));
}

[[clang::always_inline]] void CSSTokenizerSink::poolValue([[clang::noescape]] std::span<const char16_t> value)
{
    sinkState(*this).pool(value);
}

[[clang::always_inline]] void CSSTokenizerSink::observeToken(uint32_t start)
{
    auto& state = sinkState(*this);
    RELEASE_ASSERT(state.wrapper && start <= state.inputLength());
    state.wrapper->addToken(start);
}

[[clang::always_inline]] void CSSTokenizerSink::observeComment(uint32_t start, uint32_t end)
{
    auto& state = sinkState(*this);
    RELEASE_ASSERT(state.wrapper && start <= end && end <= state.inputLength());
    state.wrapper->addComment(start, end, state.tokenizer.tokenCount());
}

// https://drafts.csswg.org/css-syntax/#input-preprocessing
StringView CSSTokenizer::preprocessString(StringView string)
{
    // We don't replace '\r' and '\f' with '\n' as the specification suggests, instead
    // we treat them all the same in the isCSSNewline() function from CSSParserIdioms.h.

    auto preprocessSpan8 = [&](auto characters) -> StringView {
        // Latin-1 strings only need to replace any null characters.

        size_t indexOfNullCharacter = WTF::find(characters, '\0');
        if (indexOfNullCharacter == notFound)
            return string;

        return registerString(String { StringImpl::createByReplacingInCharacters(characters, '\0', replacementCharacter, indexOfNullCharacter) });
    };

    auto preprocessSpan16 = [&](auto characters) -> StringView {
        // UTF-16 string need to replace any null characters and any unpaired surrogates.

        bool hasUnpairedSurrogate = cssHasUnpairedSurrogate(characters);

        if (!hasUnpairedSurrogate) {
            // When there are no unpaired surrogates, we can treat this just like the Latin-1 case.

            size_t indexOfNullCharacter = WTF::find(characters, '\0');
            if (indexOfNullCharacter == notFound)
                return string;

            return registerString(String { StringImpl::createByReplacingInCharacters(characters, '\0', replacementCharacter, indexOfNullCharacter) });
        } else {
            StringBuilder result;
            result.reserveCapacity(string.length());
            for (WTF::CodePointIterator<char16_t> iterator(characters); !iterator.atEnd(); ++iterator) {
                auto codePoint = *iterator;
                if (!codePoint || U_IS_SURROGATE(codePoint))
                    result.append(replacementCharacter);
                else
                    result.append(codePoint);
            }
            return registerString(result.toString());
        }
    };

    if (string.is8Bit())
        return preprocessSpan8(string.span8());
    return preprocessSpan16(string.span16());
}

std::unique_ptr<CSSTokenizer> CSSTokenizer::tryCreate(StringView string)
{
    bool success = true;
    // We can't use makeUnique here because it does not have access to this private constructor.
    auto tokenizer = std::unique_ptr<CSSTokenizer>(new CSSTokenizer(string, nullptr, &success));
    if (!success) [[unlikely]]
        return nullptr;
    return tokenizer;
}

std::unique_ptr<CSSTokenizer> CSSTokenizer::tryCreate(StringView string, CSSParserObserverWrapper& wrapper)
{
    bool success = true;
    // We can't use makeUnique here because it does not have access to this private constructor.
    auto tokenizer = std::unique_ptr<CSSTokenizer>(new CSSTokenizer(string, &wrapper, &success));
    if (!success) [[unlikely]]
        return nullptr;
    return tokenizer;
}

CSSTokenizer::CSSTokenizer(StringView string)
    : CSSTokenizer(string, nullptr, nullptr)
{
}

CSSTokenizer::CSSTokenizer(StringView string, CSSParserObserverWrapper& wrapper)
    : CSSTokenizer(string, &wrapper, nullptr)
{
}

CSSTokenizer::CSSTokenizer(StringView string, CSSParserObserverWrapper* wrapper, bool* constructionSuccessPtr)
    : m_input(preprocessString(string))
{
    if (constructionSuccessPtr)
        *constructionSuccessPtr = true;

    if (string.isEmpty())
        return;

    // To avoid resizing we err on the side of reserving too much space.
    // Most strings we tokenize have about 3.5 to 5 characters per token.
    if (!m_tokens.tryReserveInitialCapacity(string.length() / 3)) [[unlikely]] {
        // When constructionSuccessPtr is null, our policy is to crash on failure.
        RELEASE_ASSERT(constructionSuccessPtr);
        *constructionSuccessPtr = false;
        return;
    }

    CSSTokenizerSinkState sink { *this, wrapper };
    auto input = m_input.rangeAt(0, m_input.length());
    if (!(input.is8Bit() ? cssTokenize8(byteCast<uint8_t>(input.span8()), sink) : cssTokenize16(input.span16(), sink))) [[unlikely]] {
        // When constructionSuccessPtr is null, our policy is to crash on failure.
        RELEASE_ASSERT(constructionSuccessPtr);
        *constructionSuccessPtr = false;
        return;
    }

    if (wrapper) {
        wrapper->finalizeConstruction(m_tokens.begin());
    }
}

CSSParserTokenRange CSSTokenizer::tokenRange() const LIFETIME_BOUND
{
    return m_tokens;
}

unsigned CSSTokenizer::tokenCount() const
{
    return m_tokens.size();
}

bool CSSTokenizer::isWhitespace(CSSParserTokenType type)
{
    return type == NonNewlineWhitespaceToken || type == NewlineToken;
}

StringView CSSTokenizer::registerString(String&& string)
{
    m_stringPool.append(WTF::move(string));
    return m_stringPool.last();
}

StringView CSSTokenizer::registerString(const String& string)
{
    m_stringPool.append(string);
    return string;
}

} // namespace WebCore
