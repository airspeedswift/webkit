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
#include "StyleTransformList.h"

#include "LayoutSize.h"
#include "RenderBox.h"
#include "StyleInterpolationClient.h"
#include "StyleInterpolationContext.h"

#include "WebCore-Swift.h"

namespace WebCore {
namespace Style {

bool TransformList::operator==(const TransformList& other) const
{
    return styleTransformListEqual(*this, other);
}

void TransformList::apply(TransformationMatrix& matrix, const FloatSize& size, ZoomFactor zoom, unsigned start) const
{
    styleTransformListApply(*this, matrix, size.width(), size.height(), zoom.value, start);
}

bool TransformList::has3DOperation() const
{
    return styleTransformListHas3DOperation(*this);
}

bool TransformList::isRepresentableIn2D() const
{
    return styleTransformListIsRepresentableIn2D(*this);
}

bool TransformList::affectedByTransformOrigin() const
{
    return styleTransformListAffectedByTransformOrigin(*this);
}

bool TransformList::isInvertible(const LayoutSize& size) const
{
    FloatSize floatSize = size;
    return styleTransformListIsInvertible(*this, floatSize.width(), floatSize.height(), ZoomFactor::none().value);
}

bool TransformList::containsNonInvertibleMatrix(const LayoutSize& boxSize) const
{
    return (hasTransformOfType<TransformFunctionType::Matrix>() || hasTransformOfType<TransformFunctionType::Matrix3D>()) && !isInvertible(boxSize);
}

TransformFunctionSizeDependencies TransformList::computeSizeDependencies() const
{
    return styleTransformListSizeDependencies(*this);
}

// MARK: - Blending

auto Blending<TransformList>::canBlend(const TransformList& from, const TransformList& to, CompositeOperation compositeOperation) -> bool
{
    return styleTransformListCanBlend(from, to, compositeOperation);
}

auto Blending<TransformList>::blend(const TransformList& from, const TransformList& to, const Interpolation::Context& context) -> TransformList
{
    CheckedPtr renderBox = dynamicDowncast<RenderBox>(context.client.renderer());
    FloatSize boxSize = renderBox ? renderBox->borderBoxSize() : LayoutSize();

    auto prefixLengthFromContext = [&] -> std::optional<unsigned> {
        // We cannot use the pre-computed prefix when dealing with accumulation
        // since the values used to accumulate may be different than those held
        // in the initial keyframe list. We must do the same with any property
        // other than "transform" since we only pre-compute the prefix for that
        // property.
        if (context.compositeOperation == CompositeOperation::Accumulate
            || std::holds_alternative<AtomString>(context.property)
            || std::get<CSSPropertyID>(context.property) != CSSPropertyID::Transform)
            return std::nullopt;
        return context.client.transformFunctionListPrefix();
    }();

    return styleTransformListBlend(from, to, context, boxSize.width(), boxSize.height(), prefixLengthFromContext.has_value(), prefixLengthFromContext.value_or(0));
}

} // namespace Style
} // namespace WebCore
