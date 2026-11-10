/*
 * Copyright (C) 2016-2025 Apple Inc. All rights reserved.
 * Copyright (C) 2024-2026 Samuel Weinig <sam@webkit.org>
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
#include "CSSPropertyParserConsumer+Background.h"

#include "CSSBackgroundRepeatValue.h"
#include "CSSBorderImage.h"
#include "CSSBorderImageOutsetValue.h"
#include "CSSBorderImageRepeatValue.h"
#include "CSSBorderImageSliceValue.h"
#include "CSSBorderImageSourceValue.h"
#include "CSSBorderImageWidthValue.h"
#include "CSSBorderRadius.h"
#include "CSSBoxShadowPropertyValue.h"
#include "CSSCalcTree+Parser.h"
#include "CSSParserTokenRange.h"
#include "CSSPrimitiveValue.h"
#include "CSSPropertyParserConsumer+CSSPrimitiveValueResolver.h"
#include "CSSPropertyParserConsumer+Color.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+Image.h"
#include "CSSPropertyParserConsumer+LengthDefinitions.h"
#include "CSSPropertyParserConsumer+LengthPercentageDefinitions.h"
#include "CSSPropertyParserConsumer+List.h"
#include "CSSPropertyParserConsumer+Masking.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+NumberDefinitions.h"
#include "CSSPropertyParserConsumer+PercentageDefinitions.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserState.h"
#include "CSSPropertyParsing.h"
#include "CSSValueKeywords.h"
#include "CSSPropertyConsumerSwiftTypes.h"
#include "CSSValueList.h"
#include "CSSValuePair.h"
#include "CSSWebkitBoxReflectValue.h"
#include "CSSPropertyConsumerSwiftBuilders.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

// MARK: - Border Radius

// MARK: - Border Image

std::optional<CSS::BorderImageSource> consumeUnresolvedBorderImageSource(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::BorderImageSource>(range, state, CSSPropertyConsumerSwiftConsumer::BorderImageSource);
}

RefPtr<CSSValue> consumeBorderImageSource(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'border-image-source'> = none | <image>
    // https://drafts.csswg.org/css-backgrounds/#propdef-border-image-source

    if (auto unresolved = consumeUnresolvedBorderImageSource(range, state))
        return CSSBorderImageSourceValue::create(WTF::move(*unresolved));
    return nullptr;
}

std::optional<CSS::BorderImageOutset> consumeUnresolvedBorderImageOutset(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::BorderImageOutset>(range, state, CSSPropertyConsumerSwiftConsumer::BorderImageOutset);
}

RefPtr<CSSValue> consumeBorderImageOutset(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'border-image-outset'> = [ <length [0,∞]> | <number [0,∞]> ]{1,4}
    // https://drafts.csswg.org/css-backgrounds/#propdef-border-image-outset

    if (auto unresolved = consumeUnresolvedBorderImageOutset(range, state))
        return CSSBorderImageOutsetValue::create(WTF::move(*unresolved));
    return nullptr;
}

std::optional<CSS::BorderImageRepeat> consumeUnresolvedBorderImageRepeat(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::BorderImageRepeat>(range, state, CSSPropertyConsumerSwiftConsumer::BorderImageRepeat);
}

RefPtr<CSSValue> consumeBorderImageRepeat(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'border-image-repeat'> = [ stretch | repeat | round | space ]{1,2}
    // https://drafts.csswg.org/css-backgrounds/#propdef-border-image-repeat

    if (auto unresolved = consumeUnresolvedBorderImageRepeat(range, state))
        return CSSBorderImageRepeatValue::create(WTF::move(*unresolved));
    return nullptr;
}

std::optional<CSS::BorderImageSlice> consumeUnresolvedBorderImageSlice(CSSParserTokenRange& range, CSS::PropertyParserState& state, BorderImageSliceOverride overridesSlice)
{
    return consumeUnresolvedWithSwift<CSS::BorderImageSlice>(range, state, CSSPropertyConsumerSwiftConsumer::BorderImageSlice, overridesSlice == BorderImageSliceOverride::AlwaysFill ? CSSPropertyConsumerSwiftBorderImageSliceAlwaysFill : 0);
}

RefPtr<CSSValue> consumeBorderImageSlice(CSSParserTokenRange& range, CSS::PropertyParserState& state, BorderImageSliceOverride overridesSlice)
{
    // <'border-image-slice'> = [<number [0,∞]> | <percentage [0,∞]>]{1,4} && fill?
    // https://drafts.csswg.org/css-backgrounds/#propdef-border-image-slice

    if (auto unresolved = consumeUnresolvedBorderImageSlice(range, state, overridesSlice))
        return CSSBorderImageSliceValue::create(WTF::move(*unresolved));
    return nullptr;
}

std::optional<CSS::BorderImageWidth> consumeUnresolvedBorderImageWidth(CSSParserTokenRange& range, CSS::PropertyParserState& state, BorderImageWidthOverridesWidthForLength overridesWidth)
{
    return consumeUnresolvedWithSwift<CSS::BorderImageWidth>(range, state, CSSPropertyConsumerSwiftConsumer::BorderImageWidth, overridesWidth == BorderImageWidthOverridesWidthForLength::Yes ? CSSPropertyConsumerSwiftBorderImageWidthOverridesWidthForLength : 0);
}

RefPtr<CSSValue> consumeBorderImageWidth(CSSParserTokenRange& range, CSS::PropertyParserState& state, BorderImageWidthOverridesWidthForLength overridesWidth)
{
    // <'border-image-width'> = [ <length-percentage [0,∞]> | <number [0,∞]> | auto ]{1,4}
    // https://drafts.csswg.org/css-backgrounds/#propdef-border-image-width

    if (auto unresolved = consumeUnresolvedBorderImageWidth(range, state, overridesWidth))
        return CSSBorderImageWidthValue::create(WTF::move(*unresolved));
    return nullptr;
}

// MARK: - Background Size

template<CSSPropertyID property> static RefPtr<CSSValue> consumeBackgroundSize(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumePropertyWithSwift(range, state, std::to_underlying(property));
}

RefPtr<CSSValue> consumeSingleBackgroundSize(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <single-background-size> = <bg-size>
    // https://drafts.csswg.org/css-backgrounds/#background-size

    return consumeBackgroundSize<CSSPropertyID::BackgroundSize>(range, state);
}

RefPtr<CSSValue> consumeSingleWebkitBackgroundSize(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // Non-standard.
    return consumeBackgroundSize<CSSPropertyID::WebkitBackgroundSize>(range, state);
}

RefPtr<CSSValue> consumeSingleMaskSize(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <single-mask-size> = <bg-size>
    // https://drafts.fxtf.org/css-masking/#the-mask-size

    return consumeBackgroundSize<CSSPropertyID::MaskSize>(range, state);
}

// MARK: - Background Repeat

RefPtr<CSSValue> consumeRepeatStyle(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumePropertyWithSwift(range, state, CSSPropertyConsumerSwiftConsumer::RepeatStyle);
}

// MARK: - Box Shadows

static std::optional<CSS::BoxShadowProperty> consumeUnresolvedBoxShadow(CSSParserTokenRange& range, CSS::PropertyParserState& state, bool isWebkitBoxShadow)
{
    return consumeUnresolvedWithSwift<CSS::BoxShadowProperty>(range, state, isWebkitBoxShadow ? CSSPropertyConsumerSwiftConsumer::WebkitBoxShadow : CSSPropertyConsumerSwiftConsumer::BoxShadow);
}

RefPtr<CSSValue> consumeBoxShadow(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'box-shadow'> = none | <shadow>#
    // https://drafts.csswg.org/css-backgrounds/#propdef-box-shadow

    if (auto property = consumeUnresolvedBoxShadow(range, state, false))
        return CSSBoxShadowPropertyValue::create({ WTF::move(*property) });
    return nullptr;
}

RefPtr<CSSValue> consumeWebkitBoxShadow(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    if (auto property = consumeUnresolvedBoxShadow(range, state, true))
        return CSSBoxShadowPropertyValue::create({ WTF::move(*property) });
    return nullptr;
}

// MARK: - Reflect (non-standard)

static std::optional<CSS::WebkitBoxReflect> consumeUnresolvedWebkitBoxReflect(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::WebkitBoxReflect>(range, state, CSSPropertyConsumerSwiftConsumer::WebkitBoxReflect);
}

RefPtr<CSSValue> consumeWebkitBoxReflect(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'-webkit-box-reflect'> = none | [ [ above | below | left | right ] <length-percentage>? <mask-border>? ]
    // NOTE: There is no standard associated with this property.

    if (auto unresolved = consumeUnresolvedWebkitBoxReflect(range, state))
        return CSSWebkitBoxReflectValue::create(WTF::move(*unresolved));
    return nullptr;
}

} // namespace CSSPropertyParserHelpers
} // namespace WebCore
