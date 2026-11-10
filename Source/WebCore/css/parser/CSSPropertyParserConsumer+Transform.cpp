/*
// Copyright (C) 2016-2023 Apple Inc. All rights reserved.
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
#include "CSSPropertyParserConsumer+Transform.h"

#include "CSSFunctionValue.h"
#include "CSSKeywordValue.h"
#include "CSSParserContext.h"
#include "CSSParserTokenRange.h"
#include "CSSPrimitiveValue.h"
#include "CSSPropertyParserConsumer+AngleDefinitions.h"
#include "CSSPropertyParserConsumer+CSSPrimitiveValueResolver.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+LengthDefinitions.h"
#include "CSSPropertyParserConsumer+LengthPercentageDefinitions.h"
#include "CSSPropertyParserConsumer+NumberDefinitions.h"
#include "CSSPropertyParserConsumer+Percentage.h"
#include "CSSPropertyParserConsumer+PercentageDefinitions.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserState.h"
#include "CSSPropertyParsing.h"
#include "CSSPropertyConsumerSwiftTypes.h"
#include "CSSTransformListValue.h"
#include "CSSValueList.h"
#include "CSSValuePool.h"
#include "StyleBuilderState.h"
#include "StyleComputedStyle.h"
#include "StyleTransform.h"
#include "StyleValueTypes+CSSValueConversion.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

RefPtr<CSSValue> consumeTranslate(CSSParserTokenRange& range, CSS::PropertyParserState& state) { return consumePropertyWithSwift(range, state, std::to_underlying(CSSPropertyID::Translate)); }
RefPtr<CSSValue> consumeRotate(CSSParserTokenRange& range, CSS::PropertyParserState& state) { return consumePropertyWithSwift(range, state, std::to_underlying(CSSPropertyID::Rotate)); }
RefPtr<CSSValue> consumeScale(CSSParserTokenRange& range, CSS::PropertyParserState& state) { return consumePropertyWithSwift(range, state, std::to_underlying(CSSPropertyID::Scale)); }

std::optional<Style::Transform> parseTransformRaw(StringView string, const CSSParserContext& context, const Document& document)
{
    auto tokenizer = CSSTokenizer(string);
    auto range = tokenizer.tokenRange();

    // Handle leading whitespace.
    range.consumeWhitespace();

    auto state = CSS::PropertyParserState { .context = context, .absoluteLengthUnitsOnly = true };
    auto parsedValue = CSSPropertyParsing::consumeTransform(range, state);
    if (!parsedValue)
        return { };

    // Handle trailing whitespace.
    range.consumeWhitespace();

    if (!range.atEnd())
        return { };

    auto dummyStyle = Style::ComputedStyle::create();
    auto dummyState = Style::BuilderState::create(dummyStyle, Style::BuilderContext { document });

    ASSERT(parsedValue->computedStyleDependencies().isAbsolute());

    return Style::toStyleFromCSSValue<Style::Transform>(*CheckedPtr { dummyState.ptr() }, *parsedValue);
}

#if ENABLE(SPATIAL_PORTAL)

static void flattenTransformListValues(CSSValueListBuilder& builder, CSSValue& transformList)
{
    builder.appendVector(downcast<CSSTransformListValue>(transformList).copyValues());
}

RefPtr<CSSValue> consumePortalTransform(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'portal-transform'> = none | auto | auto? <transform-list> | <transform-list> auto <transform-list>?
    // https://webkit.github.io/explainers/css-spatial/Overview.html#stage-transform

    if (range.peek().id() == CSSValueID::None)
        return consumeIdent(range);

    RefPtr leadingAuto = consumeIdent<CSSValueID::Auto>(range);
    RefPtr firstList = CSSPropertyParsing::consumeTransformList(range, state);

    if (leadingAuto) {
        // `auto` | `auto <transform-list>`
        if (!firstList)
            return leadingAuto;

        CSSValueListBuilder builder;
        builder.append(leadingAuto.releaseNonNull());
        flattenTransformListValues(builder, *firstList);
        return CSSValueList::createSpaceSeparated(WTF::move(builder));
    }

    if (!firstList)
        return nullptr;

    RefPtr trailingAuto = consumeIdent<CSSValueID::Auto>(range);
    if (!trailingAuto)
        return firstList; // `<transform-list>`

    // `<transform-list> auto` | `<transform-list> auto <transform-list>`
    CSSValueListBuilder builder;
    flattenTransformListValues(builder, *firstList);
    builder.append(trailingAuto.releaseNonNull());

    if (RefPtr secondList = CSSPropertyParsing::consumeTransformList(range, state))
        flattenTransformListValues(builder, *secondList);

    return CSSValueList::createSpaceSeparated(WTF::move(builder));
}

#endif // ENABLE(SPATIAL_PORTAL)

} // namespace CSSPropertyParserHelpers
} // namespace WebCore
