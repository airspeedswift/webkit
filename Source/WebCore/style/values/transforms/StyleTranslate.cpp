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
#include "StyleTranslate.h"

#include "CSSKeywordValue.h"
#include "StyleBuilderChecking.h"
#include "StylePrimitiveNumericTypes+Blending.h"
#include "StylePrimitiveNumericTypes+CSSValueConversion.h"
#include "StylePrimitiveNumericTypes+CSSValueCreation.h"

#include "WebCore-Swift.h"

namespace WebCore {
namespace Style {

using namespace CSS::Literals;

TransformFunctionSizeDependencies Translate::computeSizeDependencies() const
{
    if (RefPtr protectedValue = value)
        return styleTransformFunctionSizeDependencies(TransformFunction { protectedValue.releaseNonNull() });
    return { };
}

void Translate::apply(TransformationMatrix& transform, const FloatSize& size, ZoomFactor zoom) const
{
    if (RefPtr protectedValue = value)
        styleTransformFunctionApply(TransformFunction { protectedValue.releaseNonNull() }, transform, size.width(), size.height(), zoom.value);
}

// MARK: - Conversion

auto CSSValueConversion<Translate>::operator()(BuilderState& state, const CSSValue& value) -> Translate
{
    // https://drafts.csswg.org/css-transforms-2/#propdef-translate
    // none | <length-percentage> [ <length-percentage> <length>? ]?

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

    auto type = list->size() > 2 ? TransformFunctionType::Translate3D : TransformFunctionType::Translate;
    auto tx = toStyleFromCSSValue<TranslateTransformFunction::X>(state, protect(list->item(0)));
    auto ty = list->size() > 1 ? toStyleFromCSSValue<TranslateTransformFunction::Y>(state, protect(list->item(1))) : TranslateTransformFunction::Y { 0_css_px };
    auto tz = list->size() > 2 ? toStyleFromCSSValue<TranslateTransformFunction::Z>(state, protect(list->item(2))) : TranslateTransformFunction::Z { 0_css_px };

    return TranslateTransformFunction::create(WTF::move(tx), WTF::move(ty), WTF::move(tz), type);
}

// MARK: - Blending

auto Blending<Translate>::blend(const Translate& from, const Translate& to, const BlendingContext& context) -> Translate
{
    return styleTranslateBlend(from, to, context);
}

// MARK: - Platform

auto ToPlatform<Translate>::operator()(const Translate& value, const FloatSize& size, ZoomFactor zoom) -> RefPtr<TransformOperation>
{
    if (RefPtr function = value.value)
        return styleTransformFunctionToPlatform(TransformFunction { function.releaseNonNull() }, size.width(), size.height(), zoom.value);
    return nullptr;
}

} // namespace Style
} // namespace WebCore
