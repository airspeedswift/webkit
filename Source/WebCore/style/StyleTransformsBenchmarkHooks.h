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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <array>
#include <memory>
#include <optional>
#include <wtf/Forward.h>
#include <wtf/Noncopyable.h>

namespace WebCore {

class CSSValue;
enum class CompositeOperation : uint8_t;
enum class IterationCompositeOperation : uint8_t;

// Out-of-line entry points into the computed values of `transform` and `filter`, for TestWebKitAPI's
// StyleTransformsBench. The values live behind this class, so a test binary compiles none of their layout or inline
// code and runs unchanged against any WebCore built from this header. Each call runs the production operation it
// names: the style builder's conversion from a parsed CSS value, Style::Transform::apply, Blending<Transform>,
// Blending<Filter>, the blending of `translate`, `rotate` and `scale`, operator== and the conversion back to a CSS
// value for serialization.
class StyleTransformsBenchmarkHooks {
    WTF_MAKE_NONCOPYABLE(StyleTransformsBenchmarkHooks);
public:
    WEBCORE_EXPORT StyleTransformsBenchmarkHooks();
    // The style's used zoom, which the conversion from a CSS value and the conversion back read.
    WEBCORE_EXPORT explicit StyleTransformsBenchmarkHooks(float usedZoom);
    WEBCORE_EXPORT ~StyleTransformsBenchmarkHooks();

    // Parses the text as a value of `transform` (or `filter`), keeps the parsed CSS value and the computed value built
    // from it, and returns the value's index; std::nullopt if the text does not parse.
    WEBCORE_EXPORT std::optional<size_t> addTransform(StringView);
    WEBCORE_EXPORT std::optional<size_t> addFilter(StringView);

    // Builds the computed transform at the index again from its parsed CSS value (CSSValueConversion) and returns the
    // number of functions it holds.
    WEBCORE_EXPORT size_t buildTransform(size_t index);

    // The computed value's serialization (CSSValueCreation, then cssText()), and its predicates as bits: for a
    // transform isNone, has3DOperation, isRepresentableIn2D, affectedByTransformOrigin, the size dependencies and
    // containsNonInvertibleMatrix at a 100 by 50 box; for a filter isNone, the four has...() predicates,
    // hasReferenceFilter and isReferenceFilter.
    WEBCORE_EXPORT String transformText(size_t index) const;
    WEBCORE_EXPORT String filterText(size_t index) const;
    WEBCORE_EXPORT uint64_t transformPredicates(size_t index) const;
    WEBCORE_EXPORT uint64_t filterPredicates(size_t index) const;

    // Filter::calculateOutsets at the zoom: top, right, bottom and left, or all zero when it has none.
    WEBCORE_EXPORT std::array<int, 4> filterOutsets(size_t index, float zoom) const;

    using Matrix = std::array<double, 16>;

    // The identity with Style::Transform::apply of the value at the index, for a reference box and a zoom, row by
    // row (m11, m12, ... m44).
    WEBCORE_EXPORT Matrix applyTransform(size_t index, float width, float height, float zoom) const;

    // Blending<Transform>: canBlend, and when it holds, the blend at the progress, kept as the blended value.
    // CompositeOperation::Add takes a progress of 1, as interpolation passes it.
    WEBCORE_EXPORT bool blendTransforms(size_t from, size_t to, double progress, CompositeOperation);
    WEBCORE_EXPORT Matrix applyBlendedTransform(float width, float height, float zoom) const;
    WEBCORE_EXPORT String blendedTransformText() const;
    WEBCORE_EXPORT size_t blendedTransformSize() const;

    // Blending<Filter>: canBlend, and when it holds, the blend at the progress, kept as the blended value.
    WEBCORE_EXPORT bool blendFilters(size_t from, size_t to, double progress, CompositeOperation);
    WEBCORE_EXPORT String blendedFilterText() const;
    WEBCORE_EXPORT size_t blendedFilterSize() const;

    // operator== on two computed transforms, as style difference compares them.
    WEBCORE_EXPORT bool transformsEqual(size_t, size_t) const;
    WEBCORE_EXPORT bool blendedTransformEquals(size_t) const;

    // The individual transform properties, each with values of its own: the text parsed as a value of the property
    // and built into its computed value, then Blending<> of two of them, kept as the property's blended value, with
    // its serialization and its apply to the identity.
    enum class IndividualTransformProperty : uint8_t { Translate, Rotate, Scale };
    WEBCORE_EXPORT std::optional<size_t> addIndividualTransform(IndividualTransformProperty, StringView);
    WEBCORE_EXPORT bool blendIndividualTransforms(IndividualTransformProperty, size_t from, size_t to, double progress, CompositeOperation);
    WEBCORE_EXPORT Matrix applyBlendedIndividualTransform(IndividualTransformProperty, float width, float height, float zoom) const;
    WEBCORE_EXPORT String blendedIndividualTransformText(IndividualTransformProperty) const;

    // Every value at once, for a differential test that runs the same calls against another copy of the code: the
    // computed value of a property built from a CSS value the caller parsed (CSSValueConversion), and each operation
    // on it by index. Properties without an operation (a dump of a filter, the platform apply of an individual
    // property) return an empty string or the identity.
    enum class Property : uint8_t { Transform, Translate, Rotate, Scale, Perspective, Filter, PortalTransform };
    WEBCORE_EXPORT size_t addValue(Property, const CSSValue&);
    // The CSS value of `portal-transform` that the property's parser makes from these parts (none, `auto` and an
    // optional transform list after it, or a transform list, `auto` and an optional list after it), for builds where
    // the property is not parsed: a parsed `transform` list, the `auto` keyword, and the list after `auto`. Returns
    // std::nullopt for a combination the grammar does not allow; otherwise the index of the value built from it.
    WEBCORE_EXPORT std::optional<size_t> addPortalTransform(const CSSValue* beforeAuto, bool hasAuto, const CSSValue* afterAuto);
    WEBCORE_EXPORT size_t valueSize(Property, size_t index) const;
    // CSSValueCreation, then cssText() (an empty string for a portal transform); Style::serializationForCSS of a
    // transform, translate, rotate, scale or perspective (an empty string for the others); the TextStream dump of a
    // transform.
    WEBCORE_EXPORT String valueText(Property, size_t index) const;
    WEBCORE_EXPORT String valueSerialization(Property, size_t index) const;
    WEBCORE_EXPORT String valueDump(Property, size_t index) const;
    // The bits of transformPredicates (containsNonInvertibleMatrix at the box) or filterPredicates; for a portal
    // transform isNone and hasAuto.
    WEBCORE_EXPORT uint64_t valuePredicates(Property, size_t index, float width, float height) const;
    // apply from the function at the start (for a portal transform, applyBeforeAuto with a start of 0 and
    // applyAfterAuto otherwise), and ToPlatform with its TextStream dump ("null" for no operation) and, for a
    // transform, TransformOperations::apply.
    WEBCORE_EXPORT Matrix applyValue(Property, size_t index, float width, float height, float zoom, unsigned start) const;
    WEBCORE_EXPORT String platformText(Property, size_t index, float width, float height, float zoom) const;
    WEBCORE_EXPORT Matrix applyPlatform(Property, size_t index, float width, float height, float zoom) const;
    // Filter::calculateOutsets (top, right, bottom, left), std::nullopt when it has none; evaluate<float> of a
    // perspective.
    WEBCORE_EXPORT std::optional<std::array<int, 4>> valueOutsets(size_t filterIndex, float zoom) const;
    WEBCORE_EXPORT float perspectiveValue(size_t index, float zoom) const;
    WEBCORE_EXPORT bool valuesEqual(Property, size_t, size_t) const;
    WEBCORE_EXPORT bool canBlendValues(Property, size_t from, size_t to, CompositeOperation) const;
    // Blending<> with the interpolation's inputs, without checking canBlend; the blended value is added, and its
    // index returned.
    struct BlendInputs {
        double progress;
        bool isDiscrete;
        CompositeOperation compositeOperation;
        IterationCompositeOperation iterationCompositeOperation;
        double currentIteration;
        std::optional<unsigned> transformFunctionListPrefix;
    };
    WEBCORE_EXPORT size_t blendValues(Property, size_t from, size_t to, const BlendInputs&);
    // Translate::computeSizeDependencies (Property::Translate) or the transform's (Property::Transform) as bits:
    // isWidthDependent, then isHeightDependent; 0 for the other properties.
    WEBCORE_EXPORT uint64_t valueSizeDependencies(Property, size_t index) const;
    // Blending<Transform> as the interpolation of a registered custom property holding a transform list: the context's
    // property is the custom property's name, not CSSPropertyID::Transform. The blended value is added as a transform,
    // and its index returned.
    WEBCORE_EXPORT size_t blendTransformsAsCustomProperty(size_t from, size_t to, const BlendInputs&);
    // Blending<TransformFunction> of the function at fromFunction in the transform at from and the function at
    // toFunction in the transform at to, as the interpolation of a value holding one function does; the blended
    // function is added as a transform of one function, and its index returned.
    WEBCORE_EXPORT size_t blendTransformFunctions(size_t from, size_t fromFunction, size_t to, size_t toFunction, const BlendInputs&);

private:
    struct Values;
    std::unique_ptr<Values> m_values;
};

} // namespace WebCore
