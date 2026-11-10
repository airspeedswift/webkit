/*
 * Copyright (C) 2016-2022 Apple Inc. All rights reserved.
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
#include "CSSPropertyParserConsumer+CounterStyles.h"

#include "CSSCounterStyle.h"
#include "CSSCustomIdentValue.h"
#include "CSSParserContext.h"
#include "CSSParserIdioms.h"
#include "CSSParserTokenRange.h"
#include "CSSParserTokenRangeGuard.h"
#include "CSSPrimitiveValue.h"
#include "CSSPropertyParserConsumer+CSSPrimitiveValueResolver.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+Image.h"
#include "CSSPropertyParserConsumer+IntegerDefinitions.h"
#include "CSSPropertyParserConsumer+List.h"
#include "CSSPropertyParserConsumer+String.h"
#include "CSSPropertyParserState.h"
#include "CSSPropertyParsing.h"
#include "CSSSymbolsFunctionValue.h"
#include "CSSValueKeywords.h"
#include "CSSValueList.h"
#include "CSSValuePair.h"
#include "CSSValuePool.h"
#include "StylePrimitiveNumericTypes+DeprecatedCSSValueConversion.h"
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyConsumerSwiftComponents.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

bool isPredefinedCounterStyle(CSSValueID valueID)
{
    // https://drafts.csswg.org/css-counter-styles-3/#predefined-counters

    return valueID >= CSSValueID::Disc && valueID <= CSSValueID::EthiopicNumeric;
}

AtomString consumeCounterStyleNameInPrelude(CSSParserTokenRange& prelude, CSSParserMode mode)
{
    // In the context of the prelude of an @counter-style rule, a <counter-style-name> must not be an
    // ASCII case-insensitive match for "decimal", "disc", "square", "circle", "disclosure-open" and
    // "disclosure-closed". No <counter-style-name>, prelude or not, may be an ASCII case-insensitive
    // match for "none".
    // https://drafts.csswg.org/css-counter-styles-3/#typedef-counter-style-name

    auto nameToken = prelude.consumeIncludingWhitespace();
    if (!prelude.atEnd())
        return AtomString();
    // Ensure this token is a valid <custom-ident>.
    if (nameToken.type() != IdentToken || !isValidCustomIdentifier(nameToken.id()))
        return AtomString();
    auto id = nameToken.id();
    if (identMatches<CSSValueID::None>(id) || (!isUASheetBehavior(mode) && identMatches<CSSValueID::Decimal, CSSValueID::Disc, CSSValueID::Circle, CSSValueID::Square, CSSValueID::DisclosureOpen, CSSValueID::DisclosureClosed>(id)))
        return AtomString();
    auto name = nameToken.value();
    return isPredefinedCounterStyle(nameToken.id()) ? name.convertToASCIILowercaseAtom() : name.toAtomString();
}

} // namespace CSSPropertyParserHelpers

Ref<CSSValue> makeCounterStyleNameValue(const CSSPropertyConsumerSwiftValue& value, uint32_t index)
{
    auto token = swiftTokenRange(value, index, index + 1).peek();
    if (CSSPropertyParserHelpers::isPredefinedCounterStyle(token.id()))
        return CSSKeywordValue::create(token.id());
    return CSSCustomIdentValue::create(CSS::CustomIdent { token.value().toAtomString() });
}

static std::optional<CSS::SymbolsFunction> makeSymbolsFunction(const CSSPropertyConsumerSwiftValue& value, uint32_t system, uint32_t start, uint32_t end)
{
    std::optional<CSS::SymbolsType> type;
    if (system != std::numeric_limits<uint32_t>::max()) {
        auto range = swiftTokenRange(value, system, system + 1);
        type = CSSPropertyParserHelpers::consumeSpecificUnresolvedIdent<CSS::SymbolsType>(range);
        if (!type)
            return std::nullopt;
        // `symbolic` is the default system, and is omitted from the serialization.
        if (std::holds_alternative<CSS::Keyword::Symbolic>(*type))
            type = std::nullopt;
    }
    Vector<CSS::String> symbols;
    for (auto& token : swiftTokenRange(value, start, end).span()) {
        if (token.type() == StringToken)
            symbols.append(CSS::String { token.value().toString() });
    }
    return CSS::SymbolsFunction { type, WTF::move(symbols) };
}

RefPtr<CSSValue> makeSymbolsFunctionValue(const CSSPropertyConsumerSwiftValue& value, uint32_t system, uint32_t start, uint32_t end)
{
    if (auto function = makeSymbolsFunction(value, system, start, end))
        return CSSSymbolsFunctionValue::create(WTF::move(*function));
    return nullptr;
}

std::optional<CSS::CounterStyle> makeCounterStyleForSwift(const CSSPropertyConsumerSwiftValue& value, uint32_t style, uint32_t system, uint32_t start, uint32_t end)
{
    if (style == std::numeric_limits<uint32_t>::max())
        return CSS::CounterStyle { CSS::Keyword { CSSValueID::Decimal } };
    auto token = swiftTokenRange(value, style, style + 1).peek();
    if (token.type() == FunctionToken) {
        if (auto function = makeSymbolsFunction(value, system, start, end))
            return CSS::CounterStyle { WTF::move(*function) };
        return std::nullopt;
    }
    if (CSSPropertyParserHelpers::isPredefinedCounterStyle(token.id()))
        return CSS::CounterStyle { CSS::Keyword { token.id() } };
    return CSS::CounterStyle { CSS::CustomIdent { token.value().toAtomString() } };
}

int counterStyleIntegerForSwift(CSSValue& integer, bool nonnegative)
{
    // Never empty: the conversion has no integer only for a unit that no integer consumer makes.
    auto& primitive = downcast<CSSPrimitiveValue>(integer);
    if (nonnegative) {
        auto converted = Style::deprecatedToStyleFromCSSValue<Style::Integer<CSS::Nonnegative>>(primitive);
        RELEASE_ASSERT(converted);
        return converted->value;
    }
    auto converted = Style::deprecatedToStyleFromCSSValue<Style::Integer<>>(primitive);
    RELEASE_ASSERT(converted);
    return converted->value;
}

RefPtr<CSSValue> consumeCounterStyleSymbolForSwift(const CSSPropertyConsumerSwiftValue& value, uint32_t start, uint32_t end, uint32_t& next)
{
    auto range = swiftTokenRange(value, start, end);
    auto symbol = CSSPropertyParsing::consumeSymbol(range, propertyParserState(value));
    next = end - range.size();
    return symbol;
}
} // namespace WebCore
