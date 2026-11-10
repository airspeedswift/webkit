/*
 * Copyright (C) 2016-2025 Apple Inc. All rights reserved.
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
#include "CSSPropertyParserConsumer+Filter.h"

#include "CSSAppleColorFilterValue.h"
#include "CSSFilterFunctionDescriptor.h"
#include "CSSFilterValue.h"
#include "CSSParserContext.h"
#include "CSSParserTokenRange.h"
#include "CSSPrimitiveValue.h"
#include "CSSPropertyParserConsumer+AngleDefinitions.h"
#include "CSSPropertyParserConsumer+Background.h"
#include "CSSPropertyParserConsumer+Color.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+LengthDefinitions.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+NumberDefinitions.h"
#include "CSSPropertyParserConsumer+PercentageDefinitions.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserConsumer+URL.h"
#include "CSSPropertyParserState.h"
#include "CSSToLengthConversionData.h"
#include "CSSTokenizer.h"
#include "CSSValueKeywords.h"
#include "FilterOperations.h"
#include "StyleBuilderState.h"
#include "StyleFilter.h"
#include <wtf/text/StringView.h>
#include "CSSFilterImageValue.h"
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyConsumerSwiftComponents.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

std::optional<CSS::Filter> consumeUnresolvedFilter(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::Filter>(range, state, CSSPropertyConsumerSwiftConsumer::UnresolvedFilter);
}

std::optional<Style::Filter> parseFilterValueListOrNoneRaw(StringView string, const CSSParserContext& context, const Document& document, Style::ComputedStyle& style)
{
    auto tokenizer = CSSTokenizer(string);
    auto range = tokenizer.tokenRange();

    // Handle leading whitespace.
    range.consumeWhitespace();

    auto state = CSS::PropertyParserState { .context = context };
    auto filter = consumeUnresolvedFilter(range, state);
    if (!filter)
        return { };

    // Handle trailing whitespace.
    range.consumeWhitespace();

    if (!range.atEnd())
        return { };

    auto builderState = Style::BuilderState::create(style, Style::BuilderContext { document });
    return Style::toStyle(*filter, *CheckedPtr { builderState.ptr() });
}

} // namespace CSSPropertyParserHelpers

// The ranges Swift's filter functions read their arguments in: grayscale(), invert(), opacity() and sepia() clamp
// above 1 (100%) at parse time, brightness(), contrast() and saturate() do not.
static_assert(!filterFunctionAllowsValuesGreaterThanOne<CSSValueID::Grayscale>() && !filterFunctionAllowsValuesGreaterThanOne<CSSValueID::Invert>() && !filterFunctionAllowsValuesGreaterThanOne<CSSValueID::Opacity>() && !filterFunctionAllowsValuesGreaterThanOne<CSSValueID::Sepia>() && filterFunctionAllowsValuesGreaterThanOne<CSSValueID::Brightness>() && filterFunctionAllowsValuesGreaterThanOne<CSSValueID::Contrast>() && filterFunctionAllowsValuesGreaterThanOne<CSSValueID::Saturate>());
static_assert(CSS::Grayscale::Parameter::Number::range == CSS::ClosedUnitRangeClampUpper && CSS::Grayscale::Parameter::Percentage::range == CSS::ClosedPercentageRangeClampUpper && std::same_as<CSS::Invert::Parameter, CSS::Grayscale::Parameter> && std::same_as<CSS::Opacity::Parameter, CSS::Grayscale::Parameter> && std::same_as<CSS::Sepia::Parameter, CSS::Grayscale::Parameter>);
static_assert(CSS::ClosedUnitRangeClampUpper == CSS::Range { 0, 1, CSS::RangeParseTimeBehavior::Default, CSS::RangeParseTimeBehavior::Clamp } && CSS::ClosedPercentageRangeClampUpper == CSS::Range { 0, 100, CSS::RangeParseTimeBehavior::Default, CSS::RangeParseTimeBehavior::Clamp });
static_assert(CSS::Brightness::Parameter::Number::range == CSS::Nonnegative && CSS::Brightness::Parameter::Percentage::range == CSS::Nonnegative && std::same_as<CSS::Contrast::Parameter, CSS::Brightness::Parameter> && std::same_as<CSS::Saturate::Parameter, CSS::Brightness::Parameter> && CSS::Blur::Parameter::range == CSS::Nonnegative);

// The filter function F of the argument `component`, or of no argument if it is absent.
template<typename F> static F makeFilterSwiftFunction(const CSSColorSwiftComponents::Component& component)
{
    using Parameter = typename decltype(F::parameters)::Parameter;
    if (!component.type)
        return F { .parameters = { } };
    if constexpr (requires { typename Parameter::Number; typename Parameter::Percentage; })
        return F { .parameters = { makeColorSwiftComponent<Parameter>(component, brigand::list<typename Parameter::Number, typename Parameter::Percentage> { }) } };
    else
        return F { .parameters = { makeColorSwiftComponent<Parameter>(component) } };
}

void beginFilterValues(const CSSPropertyConsumerSwiftValue& value, bool apple)
{
    if (apple)
        swiftStopsAs<CSS::AppleColorFilterValueList>(value).value.clear();
    else
        swiftStopsAs<CSS::FilterValueList>(value).value.clear();
}

void appendFilterFunction(const CSSPropertyConsumerSwiftValue& value, bool apple, uint16_t function, const CSSColorSwiftComponents& argument)
{
    auto id = static_cast<CSSValueID>(function);
    auto& component = argument.at(0);
    auto append = [&]<typename... Fs>(auto& list, brigand::list<Fs...>) {
        static_cast<void>(((Fs::name == id && (list.value.append(makeFilterSwiftFunction<Fs>(component)), true)) || ...));
    };
    if (!apple) {
        append(swiftStopsAs<CSS::FilterValueList>(value), brigand::list<CSS::BlurFunction, CSS::BrightnessFunction, CSS::ContrastFunction, CSS::GrayscaleFunction, CSS::HueRotateFunction, CSS::InvertFunction, CSS::OpacityFunction, CSS::SaturateFunction, CSS::SepiaFunction> { });
        return;
    }
    auto& list = swiftStopsAs<CSS::AppleColorFilterValueList>(value);
    if (id == CSSValueID::AppleInvertLightness)
        list.value.append(CSS::AppleInvertLightnessFunction { .parameters = { } });
    else
        append(list, brigand::list<CSS::BrightnessFunction, CSS::ContrastFunction, CSS::GrayscaleFunction, CSS::HueRotateFunction, CSS::InvertFunction, CSS::OpacityFunction, CSS::SaturateFunction, CSS::SepiaFunction> { });
}

bool appendFilterURL(const CSSPropertyConsumerSwiftValue& value, uint32_t start, uint32_t end)
{
    auto range = swiftTokenRange(value, start, end);
    auto url = CSSPropertyParserHelpers::consumeURLRaw(range, propertyParserState(value), { });
    if (!url)
        return false;
    swiftStopsAs<CSS::FilterValueList>(value).value.append(CSS::FilterReference { WTF::move(*url) });
    return true;
}

RefPtr<CSSValue> makeFilterValue(const CSSPropertyConsumerSwiftValue& value, uint16_t consumer, CSSValue* image)
{
    using Consumer = CSSPropertyConsumerSwiftConsumer;
    if (static_cast<Consumer>(consumer) == Consumer::AppleColorFilter) {
        auto& appleColorFilters = swiftStopsAs<CSS::AppleColorFilterValueList>(value);
        return CSSAppleColorFilterValue::create({ appleColorFilters.value.isEmpty() ? CSS::AppleColorFilter { CSS::Keyword::None { } } : CSS::AppleColorFilter { WTF::move(appleColorFilters) } });
    }
    auto& filters = swiftStopsAs<CSS::FilterValueList>(value);
    auto filter = filters.value.isEmpty() ? CSS::Filter { CSS::Keyword::None { } } : CSS::Filter { WTF::move(filters) };
    if (image)
        return CSSFilterImageValue::create(Ref { *image }, WTF::move(filter));
    if (static_cast<Consumer>(consumer) == Consumer::UnresolvedFilter) {
        CSSPropertyConsumerSwiftUnresolvedResult::set(value, WTF::move(filter));
        return nullptr;
    }
    return CSSFilterValue::create({ WTF::move(filter) });
}
} // namespace WebCore
