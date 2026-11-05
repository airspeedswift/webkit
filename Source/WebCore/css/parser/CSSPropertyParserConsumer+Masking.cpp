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
#include "CSSPropertyParserConsumer+Masking.h"

#include "CSSClipValue.h"
#include "CSSKeywordValueInlines.h"
#include "CSSMaskBorder.h"
#include "CSSMaskBorderOutsetValue.h"
#include "CSSMaskBorderRepeatValue.h"
#include "CSSMaskBorderSliceValue.h"
#include "CSSMaskBorderSourceValue.h"
#include "CSSMaskBorderWidthValue.h"
#include "CSSParserContext.h"
#include "CSSParserTokenRange.h"
#include "CSSParserTokenRangeGuard.h"
#include "CSSPrimitiveValue.h"
#include "CSSPropertyParserConsumer+Background.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+Image.h"
#include "CSSPropertyParserConsumer+LengthDefinitions.h"
#include "CSSPropertyParserConsumer+LengthPercentageDefinitions.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+NumberDefinitions.h"
#include "CSSPropertyParserConsumer+PercentageDefinitions.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserConsumer+Shapes.h"
#include "CSSPropertyParserConsumer+URL.h"
#include "CSSPropertyParserState.h"
#include "CSSPropertyParsing.h"
#include "CSSValueKeywords.h"
#include "CSSValueList.h"
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyConsumerSwiftComponents.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

RefPtr<CSSValue> consumeMaskBorderSlice(CSSParserTokenRange& range, CSS::PropertyParserState& state, MaskBorderSliceOverride overridesSlice)
{
    return consumePropertyWithSwift(range, state, CSSPropertyConsumerSwiftConsumer::MaskBorderSlice, overridesSlice == MaskBorderSliceOverride::AlwaysFill ? CSSPropertyConsumerSwiftBorderImageSliceAlwaysFill : 0);
}

std::optional<CSS::MaskBorder> consumeUnresolvedMaskBorder(CSSParserTokenRange& range, CSS::PropertyParserState& state, MaskBorderSliceOverride overridesSlice)
{
    return consumeUnresolvedWithSwift<CSS::MaskBorder>(range, state, CSSPropertyConsumerSwiftConsumer::UnresolvedMaskBorder, overridesSlice == MaskBorderSliceOverride::AlwaysFill ? CSSPropertyConsumerSwiftBorderImageSliceAlwaysFill : 0);
}

} // namespace CSSPropertyParserHelpers

// Swift's mask-border and clip consumers parse these primitives in these ranges.
static_assert(CSS::MaskBorderSlice::Value::Number::range == CSS::Nonnegative && CSS::MaskBorderSlice::Value::Percentage::range == CSS::Nonnegative && CSS::MaskBorderWidth::Value::Number::range == CSS::Nonnegative && CSS::MaskBorderWidth::Value::LengthPercentage::range == CSS::Nonnegative && CSS::MaskBorderOutset::Value::Number::range == CSS::Nonnegative && CSS::MaskBorderOutset::Value::Length::range == CSS::Nonnegative && CSS::ClipEdge::Length::range == CSS::All);

CSS::MaskBorder makeMaskBorderSwift(CSSImageSwiftParts& parts, size_t offset)
{
    auto& p = parts.positions;
    auto source = [&](size_t) { return parts.images.isEmpty() ? CSS::MaskBorderSource { CSS::Keyword::None { } } : CSS::MaskBorderSource { Ref { parts.images[0] } }; };
    auto slice = [&](size_t i) { return CSS::MaskBorderSlice { makeBorderSwiftEdges<CSS::MaskBorderSlice::Edges>(p, i, brigand::list<CSS::MaskBorderSlice::Value::Number, CSS::MaskBorderSlice::Value::Percentage> { }), p[i + 4].type ? std::optional { CSS::Keyword::Fill { } } : std::nullopt }; };
    auto width = [&](size_t i) { return CSS::MaskBorderWidth { makeBorderSwiftEdges<CSS::MaskBorderWidth::Edges>(p, i, brigand::list<CSS::Keyword::Auto, CSS::MaskBorderWidth::Value::LengthPercentage, CSS::MaskBorderWidth::Value::Number> { }) }; };
    auto outset = [&](size_t i) { return CSS::MaskBorderOutset { makeBorderSwiftEdges<CSS::MaskBorderOutset::Edges>(p, i, brigand::list<CSS::MaskBorderOutset::Value::Length, CSS::MaskBorderOutset::Value::Number> { }) }; };
    auto repeat = [&](size_t i) { return CSS::MaskBorderRepeat { { makeColorSwiftComponent<CSS::MaskBorderRepeat::Value>(p[i]), makeColorSwiftComponent<CSS::MaskBorderRepeat::Value>(p[i + 1]) } }; };
    auto part = [&](size_t i, const auto& make) { return p[offset + i].type ? std::optional { make(offset + i) } : std::nullopt; };
    return CSS::MaskBorder { part(15, source), part(0, slice), part(5, width), part(9, outset), part(13, repeat) };
}

RefPtr<CSSValue> makeMaskingValue(const CSSPropertyConsumerSwiftValue& value, uint16_t consumer, CSSImageSwiftParts&& parts)
{
    using Consumer = CSSPropertyConsumerSwiftConsumer;
    switch (static_cast<Consumer>(consumer)) {
    case Consumer::Clip: {
        auto& p = parts.positions;
        if (p.size() == 1)
            return CSSClipValue::create(CSS::Clip { CSS::Keyword::Auto { } });
        auto edge = [&](size_t i) { return makeColorSwiftComponent<CSS::ClipEdge>(p[i], brigand::list<CSS::Keyword::Auto, CSS::ClipEdge::Length> { }); };
        return CSSClipValue::create(CSS::Clip { CSS::ClipRect { edge(0), edge(1), edge(2), edge(3) } });
    }
    default:
        RELEASE_ASSERT(static_cast<Consumer>(consumer) == Consumer::UnresolvedMaskBorder);
        CSSPropertyConsumerSwiftUnresolvedResult::set(value, makeMaskBorderSwift(parts, 0));
        return nullptr;
    }
}

Ref<CSSValue> makeMaskBorderLonghandValue(uint16_t consumer, const CSSColorSwiftComponents& components, uint8_t countOrFill, CSSValue* image)
{
    using Consumer = CSSPropertyConsumerSwiftConsumer;
    switch (static_cast<Consumer>(consumer)) {
    case Consumer::MaskBorderSlice:
        return CSSMaskBorderSliceValue::create(CSS::MaskBorderSlice { makeBorderSwiftEdges<CSS::MaskBorderSlice::Edges>(components, 0, brigand::list<CSS::MaskBorderSlice::Value::Number, CSS::MaskBorderSlice::Value::Percentage> { }), countOrFill ? std::optional { CSS::Keyword::Fill { } } : std::nullopt });
    case Consumer::MaskBorderWidth:
        return CSSMaskBorderWidthValue::create(CSS::MaskBorderWidth { makeBorderSwiftEdges<CSS::MaskBorderWidth::Edges>(components, 0, brigand::list<CSS::Keyword::Auto, CSS::MaskBorderWidth::Value::LengthPercentage, CSS::MaskBorderWidth::Value::Number> { }) });
    case Consumer::MaskBorderOutset:
        return CSSMaskBorderOutsetValue::create(CSS::MaskBorderOutset { makeBorderSwiftEdges<CSS::MaskBorderOutset::Edges>(components, 0, brigand::list<CSS::MaskBorderOutset::Value::Length, CSS::MaskBorderOutset::Value::Number> { }) });
    case Consumer::MaskBorderRepeat:
        return CSSMaskBorderRepeatValue::create(CSS::MaskBorderRepeat { { makeColorSwiftComponent<CSS::MaskBorderRepeat::Value>(components.at(0)), makeColorSwiftComponent<CSS::MaskBorderRepeat::Value>(components.at(countOrFill == 2 ? 1 : 0)) } });
    default:
        RELEASE_ASSERT(static_cast<Consumer>(consumer) == Consumer::MaskBorderSource);
        return CSSMaskBorderSourceValue::create(image ? CSS::MaskBorderSource { Ref { *image } } : CSS::MaskBorderSource { CSS::Keyword::None { } });
    }
}

RefPtr<CSSValue> makeURLValue(const CSSPropertyConsumerSwiftValue& value, uint32_t start, uint32_t end)
{
    auto range = swiftTokenRange(value, start, end);
    return CSSPropertyParserHelpers::consumeURL(range, propertyParserState(value), { });
}
} // namespace WebCore
