/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
 * Copyright (C) 2024 Samuel Weinig <sam@webkit.org>
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
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "CSSPropertyParserConsumer+ColorAdjust.h"

#include "CSSColorScheme.h"
#include "CSSColorSchemeValue.h"
#include "CSSParserContext.h"
#include "CSSParserIdioms.h"
#include "CSSParserTokenRange.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserState.h"
#include "CSSValueKeywords.h"
#include "CSSPropertyConsumerSwiftBuilders.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

#if ENABLE(DARK_MODE_CSS)

std::optional<CSS::ColorScheme> consumeUnresolvedColorScheme(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::ColorScheme>(range, state, CSSPropertyConsumerSwiftConsumer::ColorScheme);
}

std::optional<CSS::ColorScheme> parseUnresolvedColorScheme(StringView string, const CSSParserContext& context)
{
    auto tokenizer = CSSTokenizer(string);
    auto range = tokenizer.tokenRange();

    // Handle leading whitespace.
    range.consumeWhitespace();

    auto state = CSS::PropertyParserState { .context = context };
    auto result = consumeUnresolvedColorScheme(range, state);

    // Handle trailing whitespace.
    range.consumeWhitespace();

    if (!range.atEnd())
        return { };

    return result;
}

RefPtr<CSSValue> consumeColorScheme(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    auto colorScheme = consumeUnresolvedColorScheme(range, state);
    if (!colorScheme)
        return { };
    return CSSColorSchemeValue::create(WTF::move(*colorScheme));
}

#endif // ENABLE(DARK_MODE_CSS)

} // namespace CSSPropertyParserHelpers

#if ENABLE(DARK_MODE_CSS)
CSS::ColorScheme makeColorScheme(const CSSPropertyConsumerSwiftValue& value, uint32_t start, uint32_t end, bool only)
{
    auto tokens = static_cast<const CSSPropertyConsumerSwiftValueState&>(value).tokens;
    RELEASE_ASSERT(start <= end && end <= tokens.size());
    CSS::ColorScheme result { .schemes = { }, .only = { } };
    for (auto& token : tokens.subspan(start, end - start)) {
        if (token.type() == IdentToken)
            result.schemes.value.append(CSS::CustomIdent { token.value().toAtomString() });
    }
    if (only)
        result.only = CSS::Keyword::Only { };
    return result;
}
#endif
} // namespace WebCore
