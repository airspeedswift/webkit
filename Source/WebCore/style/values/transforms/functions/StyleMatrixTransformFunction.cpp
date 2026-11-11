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
#include "StyleMatrixTransformFunction.h"

#include "StyleKeyword+Logging.h"
#include "StylePrimitiveNumericTypes+Logging.h"

namespace WebCore {
namespace Style {

MatrixTransformFunction::MatrixTransformFunction(Number<> a, Number<> b, Number<> c, Number<> d, Number<> e, Number<> f)
    : TransformFunctionBase(TransformFunctionBase::Type::Matrix)
    , m_a(a)
    , m_b(b)
    , m_c(c)
    , m_d(d)
    , m_e(e)
    , m_f(f)
{
}

MatrixTransformFunction::MatrixTransformFunction(const TransformationMatrix& matrix)
    : MatrixTransformFunction(matrix.a(), matrix.b(), matrix.c(), matrix.d(), matrix.e(), matrix.f())
{
}

Ref<const MatrixTransformFunction> MatrixTransformFunction::createIdentity()
{
    return adoptRef(*new MatrixTransformFunction(1, 0, 0, 1, 0, 0));
}

Ref<const MatrixTransformFunction> MatrixTransformFunction::create(Number<> a, Number<> b, Number<> c, Number<> d, Number<> e, Number<> f)
{
    return adoptRef(*new MatrixTransformFunction(a, b, c, d, e, f));
}

Ref<const MatrixTransformFunction> MatrixTransformFunction::create(const TransformationMatrix& matrix)
{
    return adoptRef(*new MatrixTransformFunction(matrix));
}

void MatrixTransformFunction::dump(TextStream& ts) const
{
    ts << '('
       << m_a << ", "_s
       << m_b << ", "_s
       << m_c << ", "_s
       << m_d << ", "_s
       << m_e << ", "_s
       << m_f << ')';
}

} // namespace Style
} // namespace WebCore
