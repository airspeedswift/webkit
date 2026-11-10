/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

// CSSPropertyParser's entry points into Swift (CSSPropertyParserRoot.swift, CSSPropertyParserDescriptors.swift), apart
// from CSSPropertyParser.cpp because they include WebCore-Swift.h.

#include "config.h"
#include "CSSPropertyParser.h"

#include "CSSCustomPropertySyntax.h"
#include "CSSParserContext.h"
#include "CSSParserTokenRange.h"
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyParserResult.h"
#include "CSSPropertyParserState.h"
#include "WebCore-Swift.h"

namespace WebCore {

bool CSSPropertyParser::parseValue(CSSPropertyID property, IsImportant important, CSSParserTokenRange range, const CSSParserContext& context, ParsedPropertyVector& parsedProperties, StyleRuleType ruleType, const CSSNamespacePrefixMap& namespaceMap)
{
    int initialParsedPropertiesSize = parsedProperties.size();
    CSS::PropertyParserResult result { parsedProperties };
    auto state = CSS::PropertyParserState { .context = context, .currentRule = ruleType, .currentProperty = property, .important = important };
    RefPtr<CSSValue> unused;
    CSSGradientSwiftStops gradientStops;
    // The whitespace at either end is in the tokens: cssParsePropertyValue skips it.
    CSSPropertyConsumerSwiftValueState value { range.span(), state, unused, 0, gradientStops, nullptr };
    CSSPropertyConsumerSwiftShorthandSinkState sink { value, result, namespaceMap };
    bool parseSuccess = cssParsePropertyValue(value, sink, std::to_underlying(property), std::to_underlying(ruleType), important == IsImportant::Yes, static_cast<uint8_t>(context.mode));
    if (!parseSuccess)
        parsedProperties.shrink(initialParsedPropertiesSize);
    return parseSuccess;
}

// makePositionXYValues (CSSPropertyParserShorthands.swift) checks a unit against LengthPercentageUnit::Percentage.
static_assert(CSS::UnitTraits<CSS::LengthPercentageUnit>::count == std::to_underlying(CSS::LengthPercentageUnit::Percentage) + 1);

std::pair<RefPtr<CSSValue>, CSSCustomPropertySyntax::Type> consumeCustomPropertyValueWithSyntax(CSSParserTokenRange& range, CSS::PropertyParserState& state, const CSSCustomPropertySyntax& syntax)
{
    RefPtr<CSSValue> result;
    CSSGradientSwiftStops gradientStops;
    CSSPropertyConsumerSwiftValueState value { range.span(), state, result, 0, gradientStops, nullptr };
    uint32_t consumedTokens = 0;
    auto type = cssConsumeCustomPropertyValueWithSyntax(value, syntax, std::to_underlying(state.currentProperty), static_cast<uint8_t>(state.context.mode), state.absoluteLengthUnitsOnly ? CSSNumericConsumerSwiftAbsoluteLengthUnitsOnly : 0, consumedTokens);
    RELEASE_ASSERT(consumedTokens <= range.size());
    range = range.span().subspan(consumedTokens);
    return { WTF::move(result), static_cast<CSSCustomPropertySyntax::Type>(type) };
}

} // namespace WebCore
