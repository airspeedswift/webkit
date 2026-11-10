/*
 * Copyright (C) 2016-2023 Apple Inc. All rights reserved.
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
#include "CSSPropertyParserConsumer+Animations.h"

#include "CSSCalcSymbolTable.h"
#include "CSSCustomIdentValue.h"
#include "CSSParserContext.h"
#include "CSSParserIdioms.h"
#include "CSSParserTokenRange.h"
#include "CSSPrimitiveValue.h"
#include "CSSPropertyParser.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+PercentageDefinitions.h"
#include "CSSPropertyParserConsumer+Timeline.h"
#include "CSSPropertyParserState.h"
#include "CSSStringValue.h"
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyConsumerSwiftComponents.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

// A <percentage> key without a timeline range name is a CSS::Percentage<CSS::ClosedPercentageRange>.
static_assert(CSS::ClosedPercentageRange == CSS::Range { 0, 100 });

Vector<std::pair<CSSValueID, CSS::Percentage<>>> consumeKeyframeKeyList(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    using KeyList = Vector<std::pair<CSSValueID, CSS::Percentage<>>>;
    return consumeUnresolvedWithSwift<KeyList>(range, state, CSSPropertyConsumerSwiftConsumer::KeyframeKeyList).value_or(KeyList { });
}

Vector<std::pair<CSSValueID, CSS::Percentage<>>> parseKeyframeKeyList(StringView string, const CSSParserContext& context)
{
    auto tokenizer = CSSTokenizer(string);
    auto range = tokenizer.tokenRange();

    // Handle leading whitespace.
    range.consumeWhitespace();

    auto state = CSS::PropertyParserState { .context = context };
    auto result = consumeKeyframeKeyList(range, state);

    // Handle trailing whitespace.
    range.consumeWhitespace();

    if (!range.atEnd())
        return { };

    return result;
}

} // namespace CSSPropertyParserHelpers

bool isTimelineRangeNameForSwift(uint16_t id)
{
    return CSSPropertyParserHelpers::isTimelineRangeName(static_cast<CSSValueID>(id));
}

void setKeyframeKeyListResult(const CSSPropertyConsumerSwiftValue& value, CSSImageSwiftParts&& parts)
{
    auto& positions = parts.positions;
    Vector<std::pair<CSSValueID, CSS::Percentage<>>> result;
    for (size_t i = 0; i < positions.size() / 2; ++i)
        result.append({ static_cast<CSSValueID>(positions[2 * i].symbol), makeColorSwiftComponent<CSS::Percentage<>>(positions[2 * i + 1]) });
    result.shrinkToFit();
    CSSPropertyConsumerSwiftUnresolvedResult::set(value, WTF::move(result));
}

RefPtr<CSSValue> makeKeyframesNameValue(const CSSPropertyConsumerSwiftValue& value, uint32_t index)
{
    auto range = swiftTokenRange(value, index, index + 1);
    auto& token = range.peek();
    if (token.value().isEmpty())
        return nullptr;
    auto valueId = cssValueKeywordID(token.value());
    if (isValidCustomIdentifier(valueId) && valueId != CSSValueID::None)
        return CSSCustomIdentValue::create(CSS::CustomIdent { token.value().toAtomString() });
    return CSSStringValue::create(CSS::String { token.value().toString() });
}
} // namespace WebCore
