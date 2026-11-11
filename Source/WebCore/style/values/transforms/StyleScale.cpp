/*
 * Copyright (C) 2025 Samuel Weinig <sam@webkit.org>
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
#include "StyleScale.h"

#include "CSSKeywordValue.h"
#include "StyleBuilderChecking.h"
#include "StylePrimitiveNumericTypes+Blending.h"
#include "StylePrimitiveNumericTypes+CSSValueConversion.h"
#include "StylePrimitiveNumericTypes+CSSValueCreation.h"

#include "WebCore-Swift.h"

namespace WebCore {
namespace Style {

using namespace CSS::Literals;

void Scale::apply(TransformationMatrix& transform, const FloatSize& size, ZoomFactor zoom) const
{
    if (RefPtr protectedValue = value)
        styleTransformFunctionApply(TransformFunction { protectedValue.releaseNonNull() }, transform, size.width(), size.height(), zoom.value);
}

// MARK: - Conversion

auto CSSValueConversion<Scale>::operator()(BuilderState& state, const CSSValue& value) -> Scale
{
    // https://drafts.csswg.org/css-transforms-2/#propdef-scale
    // none | [ <number> | <percentage> ]{1,3}

    if (auto* keywordValue = dynamicDowncast<CSSKeywordValue>(value)) {
        switch (keywordValue->valueID()) {
        case CSSValueID::None:
            return CSS::Keyword::None { };
        default:
            state.setCurrentPropertyInvalidAtComputedValueTime();
            return CSS::Keyword::None { };
        }
    }

    auto list = requiredListDowncast<CSSValueList, CSSPrimitiveValue>(state, value);
    if (!list)
        return CSS::Keyword::None { };

    auto sx = toStyleFromCSSValue<NumberOrPercentageResolvedToNumber<>>(state, protect(list->item(0)));
    auto sy = list->size() > 1 ? toStyleFromCSSValue<NumberOrPercentageResolvedToNumber<>>(state, protect(list->item(1))) : sx;
    auto sz = list->size() > 2 ? toStyleFromCSSValue<NumberOrPercentageResolvedToNumber<>>(state, protect(list->item(2))) : NumberOrPercentageResolvedToNumber<> { 1_css_number };

    return ScaleTransformFunction::create(sx, sy, sz, TransformFunctionType::Scale);
}

// MARK: - Blending

// styleScaleBlend() clamps a blended factor to the finite doubles, as Blending<NumberOrPercentageResolvedToNumber<>>
// does for this range.
static_assert(NumberOrPercentageResolvedToNumber<>::Number::range == CSS::All);

auto Blending<Scale>::blend(const Scale& from, const Scale& to, const BlendingContext& context) -> Scale
{
    return styleScaleBlend(from, to, context);
}

// MARK: - Platform

auto ToPlatform<Scale>::operator()(const Scale& value, const FloatSize& size, ZoomFactor zoom) -> RefPtr<TransformOperation>
{
    if (RefPtr function = value.value)
        return styleTransformFunctionToPlatform(TransformFunction { function.releaseNonNull() }, size.width(), size.height(), zoom.value);
    return nullptr;
}

} // namespace Style
} // namespace WebCore
