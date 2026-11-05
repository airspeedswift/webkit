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
#if USE_SWIFT_CSS_PROPERTY_CONSUMERS_4
#include "CSSFilterImageValue.h"
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyConsumerSwiftComponents.h"
#endif

namespace WebCore {
namespace CSSPropertyParserHelpers {

#if !USE_SWIFT_CSS_PROPERTY_CONSUMERS_4
template<CSSValueID filterFunction> static decltype(auto) consumeNumberOrPercentFilterParameter(CSSParserTokenRange& args, CSS::PropertyParserState& state)
{
    if constexpr (filterFunctionAllowsValuesGreaterThanOne<filterFunction>()) {
        return MetaConsumer<
            CSS::Number<CSS::Nonnegative>,
            CSS::Percentage<CSS::Nonnegative>
        >::consume(args, state, { });
    } else {
        return MetaConsumer<
            CSS::Number<CSS::ClosedUnitRangeClampUpper>,
            CSS::Percentage<CSS::ClosedPercentageRangeClampUpper>
        >::consume(args, state, { });
    }
}

static std::optional<CSS::AppleInvertLightnessFunction> LEGACY_NODELETE consumeFilterAppleInvertLightness(CSSParserTokenRange& range, CSS::PropertyParserState&)
{
    // <-apple-invert-lightness()> = -apple-invert-lightness()
    // Non-standard

    auto args = consumeFunction(range);
    if (!args.atEnd())
        return { };

    return CSS::AppleInvertLightnessFunction { .parameters = { } };
}

static std::optional<CSS::BlurFunction> consumeFilterBlur(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // blur() = blur( <length [0,∞]>? )
    // https://drafts.fxtf.org/filter-effects/#funcdef-filter-blur

    auto args = consumeFunction(range);
    if (args.atEnd())
        return { CSS::BlurFunction { .parameters = { } } };

    auto parsedValue = MetaConsumer<CSS::Length<CSS::Nonnegative>>::consume(args, state);
    if (!parsedValue || !args.atEnd())
        return { };

    return CSS::BlurFunction { .parameters = { CSS::Blur::Parameter { WTF::move(*parsedValue) } } };
}

static std::optional<CSS::BrightnessFunction> consumeFilterBrightness(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // brightness() = brightness( [ <number [0,∞]> | <percentage [0,∞]> ]? )
    // https://drafts.fxtf.org/filter-effects/#funcdef-filter-brightness

    auto args = consumeFunction(range);
    if (args.atEnd())
        return CSS::BrightnessFunction { .parameters = { } };

    auto parsedValue = consumeNumberOrPercentFilterParameter<CSS::BrightnessFunction::name>(args, state);
    if (!parsedValue || !args.atEnd())
        return { };

    return CSS::BrightnessFunction { .parameters = { CSS::Brightness::Parameter { WTF::move(*parsedValue) } } };
}

static std::optional<CSS::ContrastFunction> consumeFilterContrast(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // contrast() = contrast( [ <number [0,∞]> | <percentage [0,∞]> ]? )
    // https://drafts.fxtf.org/filter-effects/#funcdef-filter-contrast

    auto args = consumeFunction(range);
    if (args.atEnd())
        return CSS::ContrastFunction { .parameters = { } };

    auto parsedValue = consumeNumberOrPercentFilterParameter<CSS::ContrastFunction::name>(args, state);
    if (!parsedValue || !args.atEnd())
        return { };

    return CSS::ContrastFunction { .parameters = { CSS::Contrast::Parameter { WTF::move(*parsedValue) } } };
}

static std::optional<CSS::DropShadowFunction> consumeFilterDropShadow(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // drop-shadow() = drop-shadow( [ <color>? && [<length>{2} <length [0,∞]>?] ] )
    // https://drafts.fxtf.org/filter-effects/#funcdef-filter-drop-shadow

    auto args = consumeFunction(range);

    std::optional<CSS::Color> color;
    std::optional<CSS::Length<>> x;
    std::optional<CSS::Length<>> y;
    std::optional<CSS::Length<CSS::Nonnegative>> stdDeviation;

    auto consumeOptionalColor = [&] -> bool {
        if (color)
            return false;
        auto maybeColor = consumeUnresolvedColor(args, state);
        if (!maybeColor)
            return false;
        color = WTF::move(*maybeColor);
        return true;
    };

    auto consumeLengths = [&] -> bool {
        if (x)
            return false;
        x = MetaConsumer<CSS::Length<>>::consume(args, state);
        if (!x)
            return false;
        y = MetaConsumer<CSS::Length<>>::consume(args, state);
        if (!y)
            return false;

        stdDeviation = MetaConsumer<CSS::Length<CSS::Nonnegative>>::consume(args, state);
        return true;
    };

    while (!args.atEnd()) {
        if (consumeOptionalColor() || consumeLengths())
            continue;
        break;
    }

    if (!y || !args.atEnd())
        return { };

    return CSS::DropShadowFunction {
        .parameters = {
            .color = WTF::move(color),
            .location = { WTF::move(*x), WTF::move(*y) },
            .stdDeviation = WTF::move(stdDeviation)
        }
    };
}

static std::optional<CSS::GrayscaleFunction> consumeFilterGrayscale(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // grayscale() = grayscale( [ <number [0,1(clamp upper)] > | <percentage [0,100(clamp upper)]> ]? )
    // https://drafts.fxtf.org/filter-effects/#funcdef-filter-grayscale

    auto args = consumeFunction(range);
    if (args.atEnd())
        return CSS::GrayscaleFunction { .parameters = { } };

    auto parsedValue = consumeNumberOrPercentFilterParameter<CSS::GrayscaleFunction::name>(args, state);
    if (!parsedValue || !args.atEnd())
        return { };

    return CSS::GrayscaleFunction { .parameters = { CSS::Grayscale::Parameter { WTF::move(*parsedValue) } } };
}

static std::optional<CSS::HueRotateFunction> consumeFilterHueRotate(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // hue-rotate() = hue-rotate( [ <angle> | <zero> ]? )
    // https://drafts.fxtf.org/filter-effects/#funcdef-filter-hue-rotate

    auto args = consumeFunction(range);
    if (args.atEnd())
        return CSS::HueRotateFunction { .parameters = { } };

    auto parsedValue = MetaConsumer<CSS::Angle<>>::consume(args, state, { .unitlessZeroAngle = UnitlessZeroQuirk::Allow });
    if (!parsedValue || !args.atEnd())
        return { };

    return CSS::HueRotateFunction { .parameters = { CSS::HueRotate::Parameter { WTF::move(*parsedValue) } } };
}

static std::optional<CSS::InvertFunction> consumeFilterInvert(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // invert() = invert( [ <number [0,1(clamp upper)] > | <percentage [0,100(clamp upper)]> ]? )
    // https://drafts.fxtf.org/filter-effects/#funcdef-filter-invert

    auto args = consumeFunction(range);
    if (args.atEnd())
        return CSS::InvertFunction { .parameters = { } };

    auto parsedValue = consumeNumberOrPercentFilterParameter<CSS::InvertFunction::name>(args, state);
    if (!parsedValue || !args.atEnd())
        return { };

    return CSS::InvertFunction { .parameters = { CSS::Invert::Parameter { WTF::move(*parsedValue) } } };
}

static std::optional<CSS::OpacityFunction> consumeFilterOpacity(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // opacity() = opacity( [ <number [0,1(clamp upper)] > | <percentage [0,100(clamp upper)]> ]? )
    // https://drafts.fxtf.org/filter-effects/#funcdef-filter-opacity

    auto args = consumeFunction(range);
    if (args.atEnd())
        return CSS::OpacityFunction { .parameters = { } };

    auto parsedValue = consumeNumberOrPercentFilterParameter<CSS::OpacityFunction::name>(args, state);
    if (!parsedValue || !args.atEnd())
        return { };

    return CSS::OpacityFunction { .parameters = { CSS::Opacity::Parameter { WTF::move(*parsedValue) } } };
}

static std::optional<CSS::SaturateFunction> consumeFilterSaturate(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // saturate() = saturate( [ <number [0,∞]> | <percentage [0,∞]> ]? )
    // https://drafts.fxtf.org/filter-effects/#funcdef-filter-saturate

    auto args = consumeFunction(range);
    if (args.atEnd())
        return CSS::SaturateFunction { .parameters = { } };

    auto parsedValue = consumeNumberOrPercentFilterParameter<CSS::SaturateFunction::name>(args, state);
    if (!parsedValue || !args.atEnd())
        return { };

    return CSS::SaturateFunction { .parameters = { CSS::Saturate::Parameter { WTF::move(*parsedValue) } } };
}

static std::optional<CSS::SepiaFunction> consumeFilterSepia(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // sepia() = sepia( [ <number [0,1(clamp upper)] > | <percentage [0,100(clamp upper)]> ]? )
    // https://drafts.fxtf.org/filter-effects/#funcdef-filter-sepia

    auto args = consumeFunction(range);
    if (args.atEnd())
        return CSS::SepiaFunction { .parameters = { } };

    auto parsedValue = consumeNumberOrPercentFilterParameter<CSS::SepiaFunction::name>(args, state);
    if (!parsedValue || !args.atEnd())
        return { };

    return CSS::SepiaFunction { .parameters = { CSS::Sepia::Parameter { WTF::move(*parsedValue) } } };
}

static std::optional<CSS::FilterValueList> consumeUnresolvedFilterValueList(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <filter-value-list> = [ <filter-function> | <url> ]+
    // <filter-function> = <blur()> | <brightness()> | <contrast()> | <drop-shadow()> | <grayscale()> | <hue-rotate()> | <invert()> | <opacity()> | <sepia()> | <saturate()>
    // https://drafts.fxtf.org/filter-effects/#typedef-filter-value-list

    auto rangeCopy = range;

    CSS::FilterValueList list;

    auto appendOnSuccess = [&](auto&& value) -> bool {
        if (!value)
            return false;
        list.value.append(WTF::move(*value));
        return true;
    };

    do {
        if (auto url = consumeURLRaw(rangeCopy, state, { })) {
            list.value.append(CSS::FilterReference { WTF::move(*url) });
            continue;
        }

        switch (rangeCopy.peek().functionId()) {
        case CSSValueID::Blur:
            if (!appendOnSuccess(consumeFilterBlur(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::Brightness:
            if (!appendOnSuccess(consumeFilterBrightness(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::Contrast:
            if (!appendOnSuccess(consumeFilterContrast(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::DropShadow:
            if (!appendOnSuccess(consumeFilterDropShadow(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::Grayscale:
            if (!appendOnSuccess(consumeFilterGrayscale(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::HueRotate:
            if (!appendOnSuccess(consumeFilterHueRotate(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::Invert:
            if (!appendOnSuccess(consumeFilterInvert(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::Opacity:
            if (!appendOnSuccess(consumeFilterOpacity(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::Saturate:
            if (!appendOnSuccess(consumeFilterSaturate(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::Sepia:
            if (!appendOnSuccess(consumeFilterSepia(rangeCopy, state)))
                return { };
            break;
        default:
            return { };
        }
    } while (!rangeCopy.atEnd());

    range = rangeCopy;

    return { WTF::move(list) };
}

std::optional<CSS::Filter> consumeUnresolvedFilter(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    if (range.peek().id() == CSSValueID::None) {
        range.consumeIncludingWhitespace();
        return CSS::Filter { CSS::Keyword::None { } };
    }
    if (auto filterValueList = consumeUnresolvedFilterValueList(range, state))
        return CSS::Filter { WTF::move(*filterValueList) };
    return { };
}

RefPtr<CSSValue> consumeFilter(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    if (auto property = consumeUnresolvedFilter(range, state))
        return CSSFilterValue::create({ WTF::move(*property) });
    return nullptr;
}

// MARK: - <-apple-color-filter>

static std::optional<CSS::AppleColorFilter::List> consumeUnresolvedAppleColorFilterValueList(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <-apple-color-filter-value-list = <-apple-color-filter-function>+
    // <-apple-color-filter-function> = <-apple-invert-lightness() | <brightness()> | <contrast()> | <grayscale()> | <hue-rotate()> | <invert()> | <opacity()> | <sepia()> | <saturate()>

    auto rangeCopy = range;

    CSS::AppleColorFilter::List list;

    auto appendOnSuccess = [&](auto&& value) -> bool {
        if (!value)
            return false;
        list.value.append(WTF::move(*value));
        return true;
    };

    do {
        switch (rangeCopy.peek().functionId()) {
        case CSSValueID::AppleInvertLightness:
            if (!appendOnSuccess(consumeFilterAppleInvertLightness(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::Brightness:
            if (!appendOnSuccess(consumeFilterBrightness(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::Contrast:
            if (!appendOnSuccess(consumeFilterContrast(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::Grayscale:
            if (!appendOnSuccess(consumeFilterGrayscale(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::HueRotate:
            if (!appendOnSuccess(consumeFilterHueRotate(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::Invert:
            if (!appendOnSuccess(consumeFilterInvert(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::Opacity:
            if (!appendOnSuccess(consumeFilterOpacity(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::Saturate:
            if (!appendOnSuccess(consumeFilterSaturate(rangeCopy, state)))
                return { };
            break;
        case CSSValueID::Sepia:
            if (!appendOnSuccess(consumeFilterSepia(rangeCopy, state)))
                return { };
            break;
        default:
            return { };
        }
    } while (!rangeCopy.atEnd());

    range = rangeCopy;

    return { WTF::move(list) };
}

std::optional<CSS::AppleColorFilter> consumeUnresolvedAppleColorFilter(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    if (range.peek().id() == CSSValueID::None) {
        range.consumeIncludingWhitespace();
        return CSS::AppleColorFilter { CSS::Keyword::None { } };
    }
    if (auto filterValueList = consumeUnresolvedAppleColorFilterValueList(range, state))
        return CSS::AppleColorFilter { WTF::move(*filterValueList) };
    return { };
}

RefPtr<CSSValue> consumeAppleColorFilter(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    if (auto property = consumeUnresolvedAppleColorFilter(range, state))
        return CSSAppleColorFilterValue::create({ WTF::move(*property) });
    return nullptr;
}
#else
std::optional<CSS::Filter> consumeUnresolvedFilter(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::Filter>(range, state, CSSPropertyConsumerSwiftConsumer::UnresolvedFilter);
}
#endif

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

#if USE_SWIFT_CSS_PROPERTY_CONSUMERS_4
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
        ((Fs::name == id && (list.value.append(makeFilterSwiftFunction<Fs>(component)), true)) || ...);
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
#endif
} // namespace WebCore
