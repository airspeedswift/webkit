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

#include "config.h"
#include "StyleTransformsBenchmarkHooks.h"

#include "CSSFontSelector.h"
#include "CSSKeywordValue.h"
#include "CSSParserContext.h"
#include "CSSPropertyNames.h"
#include "CSSPropertyParser.h"
#include "CSSSerializationContext.h"
#include "CSSTransformListValue.h"
#include "CSSValue.h"
#include "CSSValueList.h"
#include "CSSValuePool.h"
#include "CompositeOperation.h"
#include "DocumentInlines.h"
#include "FilterOperations.h"
#include "FontCascadeDescription.h"
#include "IterationCompositeOperation.h"
#include "ProcessWarming.h"
#include "Settings.h"
#include "StyleBuilderState.h"
#include "StyleComputedStyle+SettersInlines.h"
#include "StyleComputedStyle.h"
#include "StyleFilter.h"
#include "StyleInterpolationClient.h"
#include "StyleInterpolationContext.h"
#include "StylePerspective.h"
#include "StylePortalTransform.h"
#include "StylePrimitiveNumericTypes+Evaluation.h"
#include "StylePrimitiveNumericTypes+CSSValueCreation.h"
#include "StylePrimitiveNumericTypes+Serialization.h"
#include "StyleRotate.h"
#include "StyleScale.h"
#include "StyleTransform.h"
#include "StyleTranslate.h"
#include "TransformOperations.h"
#include "TransformationMatrix.h"
#include <wtf/TZoneMallocInlines.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/TextStream.h>

namespace WebCore {

// A style with a 16px font, so that em resolves to a fixed size, built against a document without a frame: no
// viewport, no root element and no container, as for a value that depends on none of them. Its font cascade is
// updated once the document exists (Values), so the units that read font metrics resolve against its primary font.
static Style::ComputedStyle benchmarkStyle(float usedZoom)
{
    auto style = Style::ComputedStyle::create();
    FontCascadeDescription description;
    description.setComputedSize(16);
    style.setFontDescriptionWithoutUpdate(WTF::move(description));
    style.setUsedZoom(usedZoom);
    return style;
}

struct StyleTransformsBenchmarkHooks::Values final : Style::Interpolation::Client {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(Values);

    Values(Ref<Document>&& newDocument, float usedZoom)
        : benchmarkDocument(WTF::move(newDocument))
        , style(benchmarkStyle(usedZoom))
        , builderState(Style::BuilderState::create(style, Style::BuilderContext { benchmarkDocument.get() }))
        , parserContext(benchmarkDocument.get())
    {
        // As Style::BuilderState::updateFont does, so ex, ch, ic, cap and lh (and their root forms, which fall back to
        // this style without a root element) read the metrics of a primary font.
        Ref fontSelector = benchmarkDocument->fontSelector();
        style.fontCascade().update(fontSelector.ptr());
    }

    // Interpolation without a renderer: a mismatched list's matrix fallback resolves percentages against an empty box,
    // as it does for an element that is not rendered, and no list prefix is precomputed.
    Document* document() const final { return benchmarkDocument.ptr(); }
    RenderElement* renderer() const final { return nullptr; }
    const Style::ComputedStyle& currentStyle() const final { return style; }
    std::optional<unsigned> transformFunctionListPrefix() const final { return prefix; }

    Style::Interpolation::Context interpolationContext(CSSPropertyID property, double progress, CompositeOperation compositeOperation) const
    {
        return { property, progress, false, compositeOperation, IterationCompositeOperation::Replace, 0, *this };
    }

    Style::Interpolation::Context interpolationContext(CSSPropertyID property, const BlendInputs& inputs) const
    {
        return { property, inputs.progress, inputs.isDiscrete, inputs.compositeOperation, inputs.iterationCompositeOperation, inputs.currentIteration, *this };
    }

    template<typename T> static String dump(const T& value)
    {
        TextStream stream(TextStream::LineMode::SingleLine);
        stream << value;
        return stream.release();
    }

    String text(const Ref<CSSValue>& value) const
    {
        return value->cssText(CSS::SerializationContext { });
    }

    static StyleTransformsBenchmarkHooks::Matrix elements(const TransformationMatrix& matrix)
    {
        return {
            matrix.m11(), matrix.m12(), matrix.m13(), matrix.m14(),
            matrix.m21(), matrix.m22(), matrix.m23(), matrix.m24(),
            matrix.m31(), matrix.m32(), matrix.m33(), matrix.m34(),
            matrix.m41(), matrix.m42(), matrix.m43(), matrix.m44(),
        };
    }

    const Ref<Document> benchmarkDocument;
    Style::ComputedStyle style;
    const UniqueRef<Style::BuilderState> builderState;
    const CSSParserContext parserContext;

    Vector<Ref<const CSSValue>> transformValues;
    Vector<Style::Transform> transforms;
    Vector<Style::Filter> filters;

    Style::Transform blendedTransform { CSS::Keyword::None { } };
    Style::Filter blendedFilter { CSS::Keyword::None { } };

    template<typename T> struct IndividualValues {
        Vector<T> values;
        T blended { CSS::Keyword::None { } };
    };
    IndividualValues<Style::Translate> translates;
    IndividualValues<Style::Rotate> rotates;
    IndividualValues<Style::Scale> scales;
    Vector<Style::Perspective> perspectives;
    Vector<Style::PortalTransform> portalTransforms;
    std::optional<unsigned> prefix;
};

// Calls the function with the property's ID and its values.
template<typename ValuesType, typename Function>
static decltype(auto) withIndividualValues(ValuesType& values, StyleTransformsBenchmarkHooks::IndividualTransformProperty property, NOESCAPE const Function& function)
{
    using Property = StyleTransformsBenchmarkHooks::IndividualTransformProperty;
    switch (property) {
    case Property::Translate:
        return function(CSSPropertyID::Translate, values.translates);
    case Property::Rotate:
        return function(CSSPropertyID::Rotate, values.rotates);
    case Property::Scale:
        return function(CSSPropertyID::Scale, values.scales);
    }
    RELEASE_ASSERT_NOT_REACHED();
}

WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(StyleTransformsBenchmarkHooks::Values);

static Ref<Document> createBenchmarkDocument()
{
    ProcessWarming::initializeNames();
    return Document::create(Settings::create(nullptr).get(), aboutBlankURL());
}

StyleTransformsBenchmarkHooks::StyleTransformsBenchmarkHooks()
    : StyleTransformsBenchmarkHooks(1)
{
}

StyleTransformsBenchmarkHooks::StyleTransformsBenchmarkHooks(float usedZoom)
    : m_values(makeUnique<Values>(createBenchmarkDocument(), usedZoom))
{
}

StyleTransformsBenchmarkHooks::~StyleTransformsBenchmarkHooks() = default;

std::optional<size_t> StyleTransformsBenchmarkHooks::addTransform(StringView text)
{
    RefPtr value = CSSPropertyParser::parseStylePropertyLonghand(CSSPropertyID::Transform, text, m_values->parserContext);
    if (!value)
        return std::nullopt;
    m_values->transforms.append(Style::toStyleFromCSSValue<Style::Transform>(m_values->builderState.get(), *value));
    m_values->transformValues.append(value.releaseNonNull());
    return m_values->transforms.size() - 1;
}

std::optional<size_t> StyleTransformsBenchmarkHooks::addFilter(StringView text)
{
    RefPtr value = CSSPropertyParser::parseStylePropertyLonghand(CSSPropertyID::Filter, text, m_values->parserContext);
    if (!value)
        return std::nullopt;
    m_values->filters.append(Style::toStyleFromCSSValue<Style::Filter>(m_values->builderState.get(), *value));
    return m_values->filters.size() - 1;
}

size_t StyleTransformsBenchmarkHooks::buildTransform(size_t index)
{
    auto& transform = m_values->transforms[index];
    transform = Style::toStyleFromCSSValue<Style::Transform>(m_values->builderState.get(), m_values->transformValues[index].get());
    return transform.size();
}

String StyleTransformsBenchmarkHooks::transformText(size_t index) const
{
    return m_values->text(Style::createCSSValue(CSSValuePool::singleton(), m_values->style, m_values->transforms[index]));
}

String StyleTransformsBenchmarkHooks::filterText(size_t index) const
{
    return m_values->text(Style::createCSSValue(CSSValuePool::singleton(), m_values->style, m_values->filters[index]));
}

uint64_t StyleTransformsBenchmarkHooks::transformPredicates(size_t index) const
{
    auto& transform = m_values->transforms[index];
    auto dependencies = transform.computeSizeDependencies();
    uint64_t bits = 0;
    bits |= static_cast<uint64_t>(transform.isNone()) << 0;
    bits |= static_cast<uint64_t>(transform.has3DOperation()) << 1;
    bits |= static_cast<uint64_t>(transform.isRepresentableIn2D()) << 2;
    bits |= static_cast<uint64_t>(transform.affectedByTransformOrigin()) << 3;
    bits |= static_cast<uint64_t>(dependencies.isWidthDependent) << 4;
    bits |= static_cast<uint64_t>(dependencies.isHeightDependent) << 5;
    bits |= static_cast<uint64_t>(transform.containsNonInvertibleMatrix(LayoutSize { 100, 50 })) << 6;
    return bits;
}

uint64_t StyleTransformsBenchmarkHooks::filterPredicates(size_t index) const
{
    auto& filter = m_values->filters[index];
    uint64_t bits = 0;
    bits |= static_cast<uint64_t>(filter.isNone()) << 0;
    bits |= static_cast<uint64_t>(filter.hasFilterThatRequiresRepaintForCurrentColorChange()) << 1;
    bits |= static_cast<uint64_t>(filter.hasFilterThatAffectsOpacity()) << 2;
    bits |= static_cast<uint64_t>(filter.hasFilterThatMovesPixels()) << 3;
    bits |= static_cast<uint64_t>(filter.hasFilterThatShouldBeRestrictedBySecurityOrigin()) << 4;
    bits |= static_cast<uint64_t>(filter.hasReferenceFilter()) << 5;
    bits |= static_cast<uint64_t>(filter.isReferenceFilter()) << 6;
    return bits;
}

std::array<int, 4> StyleTransformsBenchmarkHooks::filterOutsets(size_t index, float zoom) const
{
    auto outsets = m_values->filters[index].calculateOutsets(Style::ZoomFactor { zoom });
    if (!outsets)
        return { };
    return { outsets->top(), outsets->right(), outsets->bottom(), outsets->left() };
}

auto StyleTransformsBenchmarkHooks::applyTransform(size_t index, float width, float height, float zoom) const -> Matrix
{
    TransformationMatrix matrix;
    m_values->transforms[index].apply(matrix, FloatSize { width, height }, Style::ZoomFactor { zoom });
    return Values::elements(matrix);
}

bool StyleTransformsBenchmarkHooks::blendTransforms(size_t from, size_t to, double progress, CompositeOperation compositeOperation)
{
    auto& fromTransform = m_values->transforms[from];
    auto& toTransform = m_values->transforms[to];
    if (!Style::canBlend(fromTransform, toTransform, compositeOperation))
        return false;
    m_values->blendedTransform = Style::blend(fromTransform, toTransform, m_values->interpolationContext(CSSPropertyID::Transform, progress, compositeOperation));
    return true;
}

auto StyleTransformsBenchmarkHooks::applyBlendedTransform(float width, float height, float zoom) const -> Matrix
{
    TransformationMatrix matrix;
    m_values->blendedTransform.apply(matrix, FloatSize { width, height }, Style::ZoomFactor { zoom });
    return Values::elements(matrix);
}

String StyleTransformsBenchmarkHooks::blendedTransformText() const
{
    return m_values->text(Style::createCSSValue(CSSValuePool::singleton(), m_values->style, m_values->blendedTransform));
}

size_t StyleTransformsBenchmarkHooks::blendedTransformSize() const
{
    return m_values->blendedTransform.size();
}

bool StyleTransformsBenchmarkHooks::blendFilters(size_t from, size_t to, double progress, CompositeOperation compositeOperation)
{
    auto& fromFilter = m_values->filters[from];
    auto& toFilter = m_values->filters[to];
    if (!Style::canBlend(fromFilter, toFilter, compositeOperation))
        return false;
    m_values->blendedFilter = Style::blend(fromFilter, toFilter, m_values->style, m_values->style, BlendingContext { progress, false, compositeOperation });
    return true;
}

String StyleTransformsBenchmarkHooks::blendedFilterText() const
{
    return m_values->text(Style::createCSSValue(CSSValuePool::singleton(), m_values->style, m_values->blendedFilter));
}

size_t StyleTransformsBenchmarkHooks::blendedFilterSize() const
{
    return m_values->blendedFilter.size();
}

bool StyleTransformsBenchmarkHooks::transformsEqual(size_t a, size_t b) const
{
    return m_values->transforms[a] == m_values->transforms[b];
}

bool StyleTransformsBenchmarkHooks::blendedTransformEquals(size_t index) const
{
    return m_values->blendedTransform == m_values->transforms[index];
}

std::optional<size_t> StyleTransformsBenchmarkHooks::addIndividualTransform(IndividualTransformProperty property, StringView text)
{
    return withIndividualValues(*m_values, property, [&]<typename T>(CSSPropertyID propertyID, Values::IndividualValues<T>& values) -> std::optional<size_t> {
        RefPtr value = CSSPropertyParser::parseStylePropertyLonghand(propertyID, text, m_values->parserContext);
        if (!value)
            return std::nullopt;
        values.values.append(Style::toStyleFromCSSValue<T>(m_values->builderState.get(), *value));
        return values.values.size() - 1;
    });
}

bool StyleTransformsBenchmarkHooks::blendIndividualTransforms(IndividualTransformProperty property, size_t from, size_t to, double progress, CompositeOperation compositeOperation)
{
    return withIndividualValues(*m_values, property, [&](CSSPropertyID propertyID, auto& values) {
        auto& fromValue = values.values[from];
        auto& toValue = values.values[to];
        if (!Style::canBlend(fromValue, toValue, compositeOperation))
            return false;
        values.blended = Style::blend(fromValue, toValue, m_values->interpolationContext(propertyID, progress, compositeOperation));
        return true;
    });
}

auto StyleTransformsBenchmarkHooks::applyBlendedIndividualTransform(IndividualTransformProperty property, float width, float height, float zoom) const -> Matrix
{
    return withIndividualValues(*m_values, property, [&](CSSPropertyID, const auto& values) {
        TransformationMatrix matrix;
        values.blended.apply(matrix, FloatSize { width, height }, Style::ZoomFactor { zoom });
        return Values::elements(matrix);
    });
}

String StyleTransformsBenchmarkHooks::blendedIndividualTransformText(IndividualTransformProperty property) const
{
    return withIndividualValues(*m_values, property, [&](CSSPropertyID, const auto& values) {
        return m_values->text(Style::createCSSValue(CSSValuePool::singleton(), m_values->style, values.blended));
    });
}

// Calls the function with the property's ID and its values, for the properties whose values are kept as individual
// transforms are.
template<typename ValuesType, typename Function>
static decltype(auto) withValues(ValuesType& values, StyleTransformsBenchmarkHooks::Property property, NOESCAPE const Function& function)
{
    using Property = StyleTransformsBenchmarkHooks::Property;
    switch (property) {
    case Property::Transform:
        return function(CSSPropertyID::Transform, values.transforms);
    case Property::Translate:
        return function(CSSPropertyID::Translate, values.translates.values);
    case Property::Rotate:
        return function(CSSPropertyID::Rotate, values.rotates.values);
    case Property::Scale:
        return function(CSSPropertyID::Scale, values.scales.values);
    case Property::Perspective:
        return function(CSSPropertyID::Perspective, values.perspectives);
    case Property::Filter:
        return function(CSSPropertyID::Filter, values.filters);
    case Property::PortalTransform:
        // The property ID is only for interpolation contexts, which Blending<PortalTransform> passes to the lists'
        // blending; `portal-transform` exists only with ENABLE(SPATIAL_PORTAL).
        return function(CSSPropertyID::Transform, values.portalTransforms);
    }
    RELEASE_ASSERT_NOT_REACHED();
}

template<typename T> static constexpr bool isTransform = std::same_as<T, Style::Transform>;
template<typename T> static constexpr bool isIndividualTransform = std::same_as<T, Style::Translate> || std::same_as<T, Style::Rotate> || std::same_as<T, Style::Scale>;
template<typename T> static constexpr bool isFilter = std::same_as<T, Style::Filter>;
template<typename T> static constexpr bool isPortalTransform = std::same_as<T, Style::PortalTransform>;

size_t StyleTransformsBenchmarkHooks::addValue(Property property, const CSSValue& value)
{
    return withValues(*m_values, property, [&]<typename T>(CSSPropertyID, Vector<T>& values) {
        values.append(Style::toStyleFromCSSValue<T>(m_values->builderState.get(), value));
        if constexpr (isTransform<T>)
            m_values->transformValues.append(Ref { value });
        return values.size() - 1;
    });
}

std::optional<size_t> StyleTransformsBenchmarkHooks::addPortalTransform(const CSSValue* beforeAuto, bool hasAuto, const CSSValue* afterAuto)
{
    auto* beforeList = dynamicDowncast<CSSTransformListValue>(beforeAuto);
    auto* afterList = dynamicDowncast<CSSTransformListValue>(afterAuto);
    if ((beforeAuto && !beforeList) || (afterAuto && !afterList))
        return std::nullopt;

    // As consumePortalTransform: `auto` alone is the keyword, a list alone is the list, and a list with `auto` is one
    // space-separated list of the functions with the keyword in place.
    if (!hasAuto) {
        if (!beforeList == !afterList)
            return std::nullopt;
        return addValue(Property::PortalTransform, beforeList ? *beforeList : *afterList);
    }
    if (!beforeList && !afterList)
        return addValue(Property::PortalTransform, CSSKeywordValue::create(CSSValueID::Auto));

    CSSValueListBuilder builder;
    if (beforeList)
        builder.appendVector(beforeList->copyValues());
    builder.append(CSSKeywordValue::create(CSSValueID::Auto));
    if (afterList)
        builder.appendVector(afterList->copyValues());
    return addValue(Property::PortalTransform, CSSValueList::createSpaceSeparated(WTF::move(builder)));
}

size_t StyleTransformsBenchmarkHooks::valueSize(Property property, size_t index) const
{
    return withValues(*m_values, property, [&]<typename T>(CSSPropertyID, const Vector<T>& values) -> size_t {
        if constexpr (isTransform<T> || isFilter<T>)
            return values[index].size();
        else
            return !values[index].isNone();
    });
}

String StyleTransformsBenchmarkHooks::valueText(Property property, size_t index) const
{
    return withValues(*m_values, property, [&]<typename T>(CSSPropertyID, const Vector<T>& values) -> String {
        if constexpr (isPortalTransform<T>)
            return emptyString();
        else
            return m_values->text(Style::createCSSValue(CSSValuePool::singleton(), m_values->style, values[index]));
    });
}

String StyleTransformsBenchmarkHooks::valueSerialization(Property property, size_t index) const
{
    return withValues(*m_values, property, [&]<typename T>(CSSPropertyID, const Vector<T>& values) -> String {
        if constexpr (isTransform<T> || isIndividualTransform<T> || std::same_as<T, Style::Perspective>)
            return Style::serializationForCSS(CSS::SerializationContext { }, m_values->style, values[index]);
        else
            return emptyString();
    });
}

String StyleTransformsBenchmarkHooks::valueDump(Property property, size_t index) const
{
    if (property != Property::Transform)
        return emptyString();
    return Values::dump(m_values->transforms[index]);
}

uint64_t StyleTransformsBenchmarkHooks::valuePredicates(Property property, size_t index, float width, float height) const
{
    if (property == Property::Filter)
        return filterPredicates(index);
    if (property == Property::PortalTransform) {
        auto& portalTransform = m_values->portalTransforms[index];
        return static_cast<uint64_t>(portalTransform.isNone()) | static_cast<uint64_t>(portalTransform.hasAuto()) << 1;
    }
    if (property != Property::Transform)
        return 0;
    auto& transform = m_values->transforms[index];
    auto bits = transformPredicates(index) & ~(1ull << 6);
    bits |= static_cast<uint64_t>(transform.containsNonInvertibleMatrix(LayoutSize { width, height })) << 6;
    return bits;
}

auto StyleTransformsBenchmarkHooks::applyValue(Property property, size_t index, float width, float height, float zoom, unsigned start) const -> Matrix
{
    return withValues(*m_values, property, [&]<typename T>(CSSPropertyID, const Vector<T>& values) {
        TransformationMatrix matrix;
        if constexpr (isTransform<T>)
            values[index].apply(matrix, FloatSize { width, height }, Style::ZoomFactor { zoom }, start);
        else if constexpr (isIndividualTransform<T>)
            values[index].apply(matrix, FloatSize { width, height }, Style::ZoomFactor { zoom });
        else if constexpr (isPortalTransform<T>) {
            if (!start)
                values[index].applyBeforeAuto(matrix, FloatSize { width, height }, Style::ZoomFactor { zoom });
            else
                values[index].applyAfterAuto(matrix, FloatSize { width, height }, Style::ZoomFactor { zoom });
        }
        return Values::elements(matrix);
    });
}

String StyleTransformsBenchmarkHooks::platformText(Property property, size_t index, float width, float height, float zoom) const
{
    return withValues(*m_values, property, [&]<typename T>(CSSPropertyID, const Vector<T>& values) -> String {
        if constexpr (isTransform<T>)
            return Values::dump(Style::toPlatform(values[index], FloatSize { width, height }, Style::ZoomFactor { zoom }));
        else if constexpr (isIndividualTransform<T>) {
            RefPtr operation = Style::toPlatform(values[index], FloatSize { width, height }, Style::ZoomFactor { zoom });
            return operation ? Values::dump(*operation) : String { "null"_s };
        } else if constexpr (isFilter<T>)
            return Values::dump(Style::toPlatform(values[index], m_values->style));
        else
            return emptyString();
    });
}

auto StyleTransformsBenchmarkHooks::applyPlatform(Property property, size_t index, float width, float height, float zoom) const -> Matrix
{
    TransformationMatrix matrix;
    if (property == Property::Transform)
        Style::toPlatform(m_values->transforms[index], FloatSize { width, height }, Style::ZoomFactor { zoom }).apply(matrix);
    return Values::elements(matrix);
}

std::optional<std::array<int, 4>> StyleTransformsBenchmarkHooks::valueOutsets(size_t index, float zoom) const
{
    auto outsets = m_values->filters[index].calculateOutsets(Style::ZoomFactor { zoom });
    if (!outsets)
        return std::nullopt;
    return std::array<int, 4> { outsets->top(), outsets->right(), outsets->bottom(), outsets->left() };
}

float StyleTransformsBenchmarkHooks::perspectiveValue(size_t index, float zoom) const
{
    return Style::evaluate<float>(m_values->perspectives[index], Style::ZoomFactor { zoom });
}

bool StyleTransformsBenchmarkHooks::valuesEqual(Property property, size_t a, size_t b) const
{
    return withValues(*m_values, property, [&](CSSPropertyID, const auto& values) {
        return values[a] == values[b];
    });
}

bool StyleTransformsBenchmarkHooks::canBlendValues(Property property, size_t from, size_t to, CompositeOperation compositeOperation) const
{
    return withValues(*m_values, property, [&]<typename T>(CSSPropertyID, const Vector<T>& values) {
        if constexpr (isTransform<T> || isIndividualTransform<T> || isFilter<T> || isPortalTransform<T>)
            return Style::canBlend(values[from], values[to], compositeOperation);
        else
            return false;
    });
}

size_t StyleTransformsBenchmarkHooks::blendValues(Property property, size_t from, size_t to, const BlendInputs& inputs)
{
    m_values->prefix = inputs.transformFunctionListPrefix;
    auto index = withValues(*m_values, property, [&]<typename T>(CSSPropertyID propertyID, Vector<T>& values) -> size_t {
        if constexpr (isTransform<T> || isIndividualTransform<T> || isPortalTransform<T>) {
            auto blended = Style::blend(values[from], values[to], m_values->interpolationContext(propertyID, inputs));
            values.append(WTF::move(blended));
            if constexpr (isTransform<T>)
                m_values->transformValues.append(m_values->transformValues[from]);
        } else if constexpr (isFilter<T>) {
            auto blended = Style::blend(values[from], values[to], m_values->style, m_values->style, BlendingContext { inputs.progress, inputs.isDiscrete, inputs.compositeOperation, inputs.iterationCompositeOperation, inputs.currentIteration });
            values.append(WTF::move(blended));
        } else
            values.append(values[from]);
        return values.size() - 1;
    });
    m_values->prefix = std::nullopt;
    return index;
}

} // namespace WebCore
