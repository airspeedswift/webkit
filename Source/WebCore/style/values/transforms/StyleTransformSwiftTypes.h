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

#pragma once

#include <WebCore/AnimationUtilities.h>
#include <WebCore/Matrix3DTransformOperation.h>
#include <WebCore/MatrixTransformOperation.h>
#include <WebCore/PerspectiveTransformOperation.h>
#include <WebCore/RotateTransformOperation.h>
#include <WebCore/ScaleTransformOperation.h>
#include <WebCore/SkewTransformOperation.h>
#include <WebCore/StyleMatrix3DTransformFunction.h>
#include <WebCore/StyleMatrixTransformFunction.h>
#include <WebCore/StylePerspectiveTransformFunction.h>
#include <WebCore/StylePrimitiveNumericTypes+Evaluation.h>
#include <WebCore/StyleRotate.h>
#include <WebCore/StyleRotateTransformFunction.h>
#include <WebCore/StyleScale.h>
#include <WebCore/StyleScaleTransformFunction.h>
#include <WebCore/StyleSkewTransformFunction.h>
#include <WebCore/StyleTransformList.h>
#include <WebCore/StyleTranslate.h>
#include <WebCore/StyleTranslateTransformFunction.h>
#include <WebCore/StyleZoomPrimitives.h>
#include <WebCore/TranslateTransformOperation.h>

// What StyleTransformFunctionSwift.swift and StyleTransformListSwift.swift call on the transform functions and lists,
// which their own headers do not give Swift: a function as its kind's class, the evaluation and equality of its
// parameters, the platform operations they make, and the making of functions and lists.

namespace WebCore {
namespace Style {

// The function as each kind's class, or null when it is of another kind.
ALWAYS_INLINE const TranslateTransformFunction* styleAsTranslateTransformFunction(const TransformFunctionBase& function) { return dynamicDowncast<TranslateTransformFunction>(function); }
ALWAYS_INLINE const PerspectiveTransformFunction* styleAsPerspectiveTransformFunction(const TransformFunctionBase& function) { return dynamicDowncast<PerspectiveTransformFunction>(function); }
ALWAYS_INLINE const MatrixTransformFunction* styleAsMatrixTransformFunction(const TransformFunctionBase& function) { return dynamicDowncast<MatrixTransformFunction>(function); }
ALWAYS_INLINE const Matrix3DTransformFunction* styleAsMatrix3DTransformFunction(const TransformFunctionBase& function) { return dynamicDowncast<Matrix3DTransformFunction>(function); }

// The parameters of a scale (x, y, z), a rotation (axis x, y, z and angle), a skew (angles about x and y, as x and y)
// or a translation (x and y against the reference box's width and height, and z, each resolved as a float), read from
// a function that must be of that kind; downcast<> traps on another kind.
struct StyleTransformFunctionValues { double x; double y; double z; double angle; };
ALWAYS_INLINE StyleTransformFunctionValues styleScaleValues(const TransformFunctionBase& function) { auto& scale = downcast<ScaleTransformFunction>(function); return { scale.x().value.value, scale.y().value.value, scale.z().value.value, 0 }; }
ALWAYS_INLINE StyleTransformFunctionValues styleRotateValues(const TransformFunctionBase& function) { auto& rotate = downcast<RotateTransformFunction>(function); return { rotate.x().value, rotate.y().value, rotate.z().value, rotate.angle().value }; }
ALWAYS_INLINE StyleTransformFunctionValues styleSkewValues(const TransformFunctionBase& function) { auto& skew = downcast<SkewTransformFunction>(function); return { skew.angleX().value, skew.angleY().value, 0, 0 }; }
ALWAYS_INLINE StyleTransformFunctionValues styleTranslateValues(const TransformFunctionBase& function, float width, float height, float zoom) { auto& translate = downcast<TranslateTransformFunction>(function); return { evaluate<float>(translate.x(), width, ZoomFactor { zoom }), evaluate<float>(translate.y(), height, ZoomFactor { zoom }), evaluate<float>(translate.z(), ZoomFactor { zoom }), 0 }; }

// The same, and the type, for the function at index of a list, read in place: Swift then holds no reference to the
// function, so it neither retains nor releases it. The index is bounds-checked by the list.
ALWAYS_INLINE TransformFunctionType styleTransformFunctionTypeAt(const TransformList& list, size_t index) { return list.function(index).type(); }
ALWAYS_INLINE StyleTransformFunctionValues styleScaleValues(const TransformList& list, size_t index) { return styleScaleValues(list.function(index)); }
ALWAYS_INLINE StyleTransformFunctionValues styleRotateValues(const TransformList& list, size_t index) { return styleRotateValues(list.function(index)); }
ALWAYS_INLINE StyleTransformFunctionValues styleSkewValues(const TransformList& list, size_t index) { return styleSkewValues(list.function(index)); }

// Whether two lists hold the same function object at index.
ALWAYS_INLINE bool styleIsSameTransformFunction(const TransformList& a, const TransformList& b, size_t index) { return &a.function(index) == &b.function(index); }

// Equality of the parameters Swift cannot compare itself: two translations' lengths, compared in place, of two
// functions or of the functions at index of two lists.
ALWAYS_INLINE bool styleEqualTranslate(const TransformFunctionBase& a, const TransformFunctionBase& b) { auto& lhs = downcast<TranslateTransformFunction>(a); auto& rhs = downcast<TranslateTransformFunction>(b); return lhs.x() == rhs.x() && lhs.y() == rhs.y() && lhs.z() == rhs.z(); }
ALWAYS_INLINE bool styleEqualTranslate(const TransformList& a, const TransformList& b, size_t index) { return styleEqualTranslate(a.function(index), b.function(index)); }

// The distance of a perspective that is not none, before zoom.
ALWAYS_INLINE float styleUnresolvedPerspective(const Perspective& perspective) { return perspective.tryValue()->unresolvedValue(); }

// A perspective function, a function as a list element, and a list of them.
ALWAYS_INLINE Ref<const PerspectiveTransformFunction> styleMakePerspectiveTransformFunction(bool isNone, float distance) { return PerspectiveTransformFunction::create(isNone ? Perspective { CSS::Keyword::None { } } : Perspective { Perspective::Length { distance } }); }
ALWAYS_INLINE TransformFunction styleMakeTransformFunction(const TransformFunctionBase& function) { return TransformFunction { function }; }
// The list moves each function straight out of the vector, which Swift passes by address (inout), and leaves the vector
// empty.
using StyleTransformFunctionVector = Vector<TransformFunction, 8>;
ALWAYS_INLINE TransformList styleMakeTransformList(StyleTransformFunctionVector& functions) { TransformList list { TransformList::Container::createWithSizeFromGenerator(functions.size(), [&](size_t index) { return WTF::move(functions[index]); }) }; functions.shrink(0); return list; }

// A platform operation as the function's toPlatform() returns it.
using StyleTransformOperationRef = Ref<TransformOperation>;

} // namespace Style
} // namespace WebCore
