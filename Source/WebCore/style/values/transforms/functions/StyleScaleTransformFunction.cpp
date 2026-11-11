/*
 * Copyright (C) 1999 Antti Koivisto (koivisto@kde.org)
 * Copyright (C) 2004, 2005, 2006, 2007, 2008 Apple Inc. All rights reserved.
 * Copyright (C) 2025 Samuel Weinig <sam@webkit.org>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 *
 */

#include "config.h"
#include "StyleScaleTransformFunction.h"

#include "StyleKeyword+Logging.h"
#include "StylePrimitiveNumericTypes+Logging.h"

namespace WebCore {
namespace Style {

ScaleTransformFunction::ScaleTransformFunction(NumberOrPercentageResolvedToNumber<> x, NumberOrPercentageResolvedToNumber<> y, NumberOrPercentageResolvedToNumber<> z, TransformFunctionBase::Type type)
    : TransformFunctionBase(type)
    , m_x(x)
    , m_y(y)
    , m_z(z)
{
    RELEASE_ASSERT(isScaleTransformFunctionType(type));
}

Ref<const ScaleTransformFunction> ScaleTransformFunction::create(NumberOrPercentageResolvedToNumber<> x, NumberOrPercentageResolvedToNumber<> y, TransformFunctionBase::Type type)
{
    return adoptRef(*new ScaleTransformFunction(x, y, NumberOrPercentageResolvedToNumber<> { 1 }, type));
}

Ref<const ScaleTransformFunction> ScaleTransformFunction::create(NumberOrPercentageResolvedToNumber<> x, NumberOrPercentageResolvedToNumber<> y, NumberOrPercentageResolvedToNumber<> z, TransformFunctionBase::Type type)
{
    return adoptRef(*new ScaleTransformFunction(x, y, z, type));
}

void ScaleTransformFunction::dump(TextStream& ts) const
{
    ts << type() << '(' << m_x << ", "_s << m_y << ", "_s << m_z << ')';
}

} // namespace Style
} // namespace WebCore
