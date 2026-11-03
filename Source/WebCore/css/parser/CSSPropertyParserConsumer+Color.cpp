/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
 * Copyright (C) 2024-2026 Samuel Weinig <sam@webkit.org>
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
#include "CSSPropertyParserConsumer+Color.h"

#include "CSSAbsoluteColor.h"
#include "CSSAbsoluteColorResolver.h"
#include "CSSCalcSymbolsAllowed.h"
#include "CSSColor.h"
#include "CSSColorConversion+Normalize.h"
#include "CSSColorDescriptors.h"
#include "CSSColorInterpolationMethod.h"
#include "CSSColorLayers.h"
#include "CSSColorMix.h"
#include "CSSContrastColor.h"
#include "CSSDynamicRangeLimit.h"
#include "CSSDynamicRangeLimitMix.h"
#include "CSSDynamicRangeLimitValue.h"
#include "CSSHexColor.h"
#include "CSSKeywordColor.h"
#include "CSSLightDarkColor.h"
#include "CSSParser.h"
#include "CSSParserContext.h"
#include "CSSParserFastPaths.h"
#include "CSSParserIdioms.h"
#include "CSSParserTokenRange.h"
#include "CSSPrimitiveNumericTypes+EvaluateCalc.h"
#include "CSSPropertyParserConsumer+AngleDefinitions.h"
#include "CSSPropertyParserConsumer+ColorInterpolationMethod.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+KeywordDefinitions.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+NumberDefinitions.h"
#include "CSSPropertyParserConsumer+PercentageDefinitions.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserConsumer+SymbolDefinitions.h"
#include "CSSPropertyParsing.h"
#include "CSSRelativeAlphaColor.h"
#include "CSSRelativeColor.h"
#include "CSSResolvedColor.h"
#include "CSSTokenizer.h"
#include "CSSValuePool.h"
#include "Color.h"
#include "ColorLuminance.h"
#include "StyleKeyword+Mappings.h"
#include <wtf/SortedArrayMap.h>
#include <wtf/text/MakeString.h>
#include "CSSBackgroundRepeatValue.h"
#include "CSSCanvasValue.h"
#include "CSSColorImageValue.h"
#include "CSSCrossfadeValue.h"
#include "CSSFilterImageValue.h"
#include "CSSGradientValue.h"
#include "CSSImageSetOptionValue.h"
#include "CSSImageSetValue.h"
#include "CSSImageValue.h"
#include "CSSKeywordValueInlines.h"
#include "CSSLightDarkImageValue.h"
#include "CSSNamedImageValue.h"
#include "CSSPaintImageValue.h"
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyParserConsumer+Background.h"
#include "CSSPropertyParserConsumer+Filter.h"
#include "CSSPropertyParserConsumer+Masking.h"
#include "CSSPropertyParserConsumer+URL.h"
#include "CSSURL.h"
#include "CSSVariableData.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

// State passed to internal color consumer functions. Used to pass information
// down the stack and levels of color parsing nesting.
struct ColorParserState {
    ColorParserState(CSS::PropertyParserState& propertyParserState, const CSSColorParsingOptions& options)
        : propertyParserState { propertyParserState }
        , allowedColorTypes { options.allowedColorTypes }
        , acceptsQuirkyColor { propertyParserState.context.mode == HTMLQuirksMode && CSSProperty::acceptsQuirkyColor(propertyParserState.currentProperty) }
    {
    }

    CSS::PropertyParserState& propertyParserState;
    OptionSet<CSS::ColorType> allowedColorTypes;
    bool acceptsQuirkyColor { false };
    unsigned nestingLevel { 0 };
};

template<typename Descriptor> static CSS::AbsoluteColor<typename Descriptor::Canonical> normalizeNonCalcComponents(const CSS::AbsoluteColor<Descriptor>& unresolved, ColorParserState& state)
{
    ASSERT(componentsContainsUnevaluatedCalc<Descriptor>(unresolved.components));

    // The canonical descriptor is normally the descriptor itself, except for legacy rgb and hsl, which use the modern counterparts.
    using CanonicalDescriptor = typename Descriptor::Canonical;

    if (state.nestingLevel > 1) {
        // If this is a nested color, we want to only normalize the numeric color channel components, leaving them unclamped. The alpha channel can be both normalized and clamped.
        //
        // This behavior is described in section on the processing of relative colors: https://drafts.csswg.org/css-color-5/#rcs-intro.
        return CSS::AbsoluteColor<CanonicalDescriptor> {
            CSSColorParseTypeWithCalc<CanonicalDescriptor> {
                normalizeNumericComponentsIntoCanonicalRepresentation<Descriptor, 0>(std::get<0>(unresolved.components)),
                normalizeNumericComponentsIntoCanonicalRepresentation<Descriptor, 1>(std::get<1>(unresolved.components)),
                normalizeNumericComponentsIntoCanonicalRepresentation<Descriptor, 2>(std::get<2>(unresolved.components)),
                normalizeAndClampNumericComponentsIntoCanonicalRepresentation<Descriptor, 3>(std::get<3>(unresolved.components))
            }
        };
    }

    // For non-nested colors, we want to normalize and clamp the numeric color and alpha channel components.
    return CSS::AbsoluteColor<CanonicalDescriptor> {
        CSSColorParseTypeWithCalc<CanonicalDescriptor> {
            normalizeAndClampNumericComponentsIntoCanonicalRepresentation<Descriptor, 0>(std::get<0>(unresolved.components)),
            normalizeAndClampNumericComponentsIntoCanonicalRepresentation<Descriptor, 1>(std::get<1>(unresolved.components)),
            normalizeAndClampNumericComponentsIntoCanonicalRepresentation<Descriptor, 2>(std::get<2>(unresolved.components)),
            normalizeAndClampNumericComponentsIntoCanonicalRepresentation<Descriptor, 3>(std::get<3>(unresolved.components))
        }
    };
}

template<typename Descriptor> static CSS::AbsoluteColor<typename Descriptor::Canonical> normalizeNonCalcRequiringConversionDataComponents(const CSS::AbsoluteColor<Descriptor>& unresolved, ColorParserState& state)
{
    ASSERT(componentsContainsUnevaluatedCalc<Descriptor>(unresolved.components));

    // Evaluated any calc values that don't require conversion data.
    auto partiallyResolved = CSS::AbsoluteColor<Descriptor> {
        CSSColorParseTypeWithCalc<Descriptor> {
            CSS::evaluateCalcIfNoConversionDataRequired(std::get<0>(unresolved.components), CSSCalcSymbolTable { }),
            CSS::evaluateCalcIfNoConversionDataRequired(std::get<1>(unresolved.components), CSSCalcSymbolTable { }),
            CSS::evaluateCalcIfNoConversionDataRequired(std::get<2>(unresolved.components), CSSCalcSymbolTable { }),
            CSS::evaluateCalcIfNoConversionDataRequired(std::get<3>(unresolved.components), CSSCalcSymbolTable { })
        }
    };

    return normalizeNonCalcComponents(WTF::move(partiallyResolved), state);
}

bool isColorKeywordAllowed(CSSValueID id, const CSSParserContext& context)
{
    switch (id) {
    case CSSValueID::WebkitFocusRingColor:
        switch (context.mode) {
        case UASheetMode:
        case HTMLQuirksMode:
            return true;
        default:
            return false;
        }

#if PLATFORM(COCOA)
    case CSSValueID::AppleSystemTertiaryFill:
#endif
#if PLATFORM(IOS_FAMILY)
    case CSSValueID::AppleSystemQuaternaryFill:
#endif
#if PLATFORM(MAC)
    case CSSValueID::AppleSystemOpaqueFill:
    case CSSValueID::AppleSystemOpaqueSecondaryFill:
#endif
    case CSSValueID::InternalDocumentTextColor:
        switch (context.mode) {
        case UASheetMode:
            return true;
        default:
            return false;
        }

    default:
        return true;
    }
}

std::optional<CSS::Color> consumeUnresolvedColor(CSSParserTokenRange& range, CSS::PropertyParserState& state, const CSSColorParsingOptions& options)
{
    return consumeUnresolvedWithSwift<CSS::Color>(range, state, CSSPropertyConsumerSwiftConsumer::UnresolvedColor, options.allowedColorTypes.toRaw());
}

RefPtr<CSSValue> consumeColor(CSSParserTokenRange& range, CSS::PropertyParserState& state, const CSSColorParsingOptions& options)
{
    return consumePropertyWithSwift(range, state, CSSPropertyConsumerSwiftConsumer::Color, options.allowedColorTypes.toRaw());
}

Color consumeColorRaw(CSSParserTokenRange& range, CSS::PropertyParserState& state, const CSSColorParsingOptions& options, CSS::PlatformColorResolutionState& eagerResolutionState)
{
    if (auto color = consumeUnresolvedColor(range, state, options))
        return createColor(*color, eagerResolutionState);
    return { };
}

} // namespace CSSPropertyParserHelpers

// Swift's color consumers check a percentage of color-mix() or dynamic-range-limit-mix() against [0, 100], and parse
// calc() in the channels of the color functions in the range of CSS::Number<>, CSS::Percentage<> and CSS::Angle<>.
static_assert(CSS::ColorMix::Component::Percentage::range == CSS::Range { 0, 100 } && CSS::DynamicRangeLimitMixPercentage::range == CSS::Range { 0, 100 });
static_assert(CSS::Number<>::range == CSS::All && CSS::Percentage<>::range == CSS::All && CSS::Angle<>::range == CSS::All);
// Swift's consumers take [-infinity, infinity] for an unbounded numeric component, [0, infinity] for a nonnegative
// one, and CSS::Length<>'s range for box shadow offsets and spread.
static_assert(CSS::All == CSS::Range { -CSS::Range::infinity, CSS::Range::infinity } && CSS::Nonnegative == CSS::Range { 0, CSS::Range::infinity } && CSS::Length<>::range == CSS::All);

static CSS::PropertyParserState& propertyParserState(const CSSPropertyConsumerSwiftValue& value)
{
    return static_cast<const CSSPropertyConsumerSwiftValueState&>(value).propertyParserState;
}

uint8_t colorKeywordForSwift(const CSSPropertyConsumerSwiftValue& value, uint16_t id, uint8_t allowedColorTypes)
{
    auto keyword = static_cast<CSSValueID>(id);
    if (!CSS::isColorKeyword(keyword, OptionSet<CSS::ColorType>::fromRaw(allowedColorTypes)))
        return CSSColorSwiftNotAKeyword;
    return CSSPropertyParserHelpers::isColorKeywordAllowed(keyword, propertyParserState(value).context) ? CSSColorSwiftAllowedKeyword : CSSColorSwiftDisallowedKeyword;
}

uint8_t colorContextForSwift(const CSSPropertyConsumerSwiftValue& value)
{
    auto& state = propertyParserState(value);
    auto& context = state.context;
    return (context.mode == HTMLQuirksMode && CSSProperty::acceptsQuirkyColor(state.currentProperty) ? CSSColorSwiftAcceptsQuirkyColor : 0)
        | (context.colorLayersEnabled ? CSSColorSwiftColorLayersEnabled : 0)
        | (context.cssDynamicRangeLimitMixEnabled ? CSSColorSwiftDynamicRangeLimitMixEnabled : 0)
        | (context.cssConstrainedDynamicRangeLimitEnabled ? CSSColorSwiftConstrainedDynamicRangeLimitEnabled : 0)
        | (context.cssAxisRelativePositionKeywordsEnabled ? CSSColorSwiftAxisRelativePositionKeywordsEnabled : 0);
}

template<typename> inline constexpr bool isColorSwiftVariant = false;
template<typename... Ts> inline constexpr bool isColorSwiftVariant<Variant<Ts...>> = true;
template<typename Result, typename... Ts> static Result makeColorSwiftComponent(const CSSColorSwiftComponents::Component&, brigand::list<Ts...>);

// A channel's alternative of the descriptor's component Variant (or single type) Result, whose types are Ts.
template<typename T> static bool isColorSwiftComponent(const CSSColorSwiftComponents::Component& component)
{
    if constexpr (isColorSwiftVariant<T>)
        return []<typename... Ts>(const CSSColorSwiftComponents::Component& component, brigand::list<Ts...>) { return (isColorSwiftComponent<Ts>(component) || ...); }(component, brigand::as_list<T> { });
    else if constexpr (std::same_as<T, CSS::Symbol>)
        return component.type == CSSColorSwiftChannelNone && component.symbol;
    else if constexpr (std::same_as<T, CSS::Keyword::None>)
        return component.type == CSSColorSwiftChannelNone && !component.symbol;
    else if constexpr (CSS::SpecificKeyword<T>)
        return component.type == CSSColorSwiftChannelNone && component.symbol == std::to_underlying(T::value);
    else if constexpr (requires { T::category; })
        return component.type == colorSwiftChannelType<T>();
    else
        return false;
}

template<typename T> static T makeColorSwiftComponent(const CSSColorSwiftComponents::Component& component)
{
    if constexpr (isColorSwiftVariant<T>)
        return makeColorSwiftComponent<T>(component, brigand::as_list<T> { });
    else if constexpr (std::same_as<T, CSS::Symbol>)
        return T { CSS::SymbolRaw { static_cast<CSSValueID>(component.symbol) } };
    else if constexpr (CSS::SpecificKeyword<T>)
        return T { };
    else {
        if (component.calc)
            return T { typename T::Calc { *component.calc } };
        if constexpr (T::category == CSS::Category::Angle || T::category == CSS::Category::AnglePercentage || T::category == CSS::Category::Resolution) {
            auto unit = CSS::UnitTraits<typename T::Raw::UnitType>::validate(static_cast<CSSUnitType>(component.unit));
            RELEASE_ASSERT(unit);
            return T { typename T::Raw { *unit, component.value } };
        } else if constexpr (T::category == CSS::Category::LengthPercentage || T::category == CSS::Category::Length) {
            RELEASE_ASSERT(component.unit < T::Raw::UnitTraits::count);
            return T { typename T::Raw { static_cast<typename T::Raw::UnitType>(component.unit), component.value } };
        } else if constexpr (T::category == CSS::Category::Percentage)
            return T { typename T::Raw { CSS::PercentageUnit::Percentage, component.value } };
        else
            return T { typename T::Raw { CSS::NumberUnit::Number, component.value } };
    }
}

// The first of Ts that matches the component, as a Result. Types that are not one component, such as a pair of
// lengths in a Variant, never match.
template<typename Result, typename T, typename... Ts> static Result makeFirstColorSwiftComponent(const CSSColorSwiftComponents::Component& component)
{
    if constexpr (isColorSwiftVariant<T> || std::same_as<T, CSS::Symbol> || CSS::SpecificKeyword<T> || requires { T::category; }) {
        if (isColorSwiftComponent<T>(component))
            return Result(makeColorSwiftComponent<T>(component));
    }
    if constexpr (sizeof...(Ts))
        return makeFirstColorSwiftComponent<Result, Ts...>(component);
    else
        RELEASE_ASSERT_NOT_REACHED();
}

template<typename Result, typename... Ts> static Result makeColorSwiftComponent(const CSSColorSwiftComponents::Component& component, brigand::list<Ts...>)
{
    return makeFirstColorSwiftComponent<Result, Ts...>(component);
}

// The T of a component, or none if it is absent.
template<typename T> static std::optional<T> optionalSwiftComponent(const CSSColorSwiftComponents::Component& component)
{
    return component.type ? std::optional { makeColorSwiftComponent<T>(component) } : std::nullopt;
}

template<typename Descriptor, unsigned Index> static auto makeAbsoluteColorSwiftComponent(const CSSColorSwiftComponents& components)
{
    return makeColorSwiftComponent<CSS::AbsoluteColorComponent<Descriptor, Index>>(components.at(Index), GetCSSColorParseTypeWithCalcComponentTypeList<Descriptor, Index> { });
}

template<typename Descriptor, unsigned Index> static auto makeRelativeColorSwiftComponent(const CSSColorSwiftComponents& components)
{
    return makeColorSwiftComponent<CSS::RelativeColorComponent<Descriptor, Index>>(components.at(Index), GetCSSColorParseTypeWithCalcAndSymbolsComponentTypeList<Descriptor, Index> { });
}

CSS::Color makeAbsoluteColor(const CSSPropertyConsumerSwiftValue& value, uint8_t descriptor, const CSSColorSwiftComponents& components, uint32_t nestingLevel)
{
    return callWithColorSwiftDescriptor(descriptor, [&]<typename Descriptor>() -> CSS::Color {
        if constexpr (std::same_as<Descriptor, AlphaDescriptor>)
            RELEASE_ASSERT_NOT_REACHED();
        else if constexpr (!std::is_constructible_v<CSS::Color, CSS::AbsoluteColor<Descriptor>&&>)
            RELEASE_ASSERT_NOT_REACHED();
        else {
            std::optional<CSS::AbsoluteColorComponent<Descriptor, 3>> alpha;
            if (components.type(3))
                alpha = makeAbsoluteColorSwiftComponent<Descriptor, 3>(components);
            auto unresolved = CSS::AbsoluteColor<Descriptor> {
                .components = { makeAbsoluteColorSwiftComponent<Descriptor, 0>(components), makeAbsoluteColorSwiftComponent<Descriptor, 1>(components), makeAbsoluteColorSwiftComponent<Descriptor, 2>(components), WTF::move(alpha) },
            };
            CSSPropertyParserHelpers::ColorParserState state { propertyParserState(value), { } };
            state.nestingLevel = nestingLevel;

            if constexpr (Descriptor::allowEagerEvaluationOfResolvableCalc) {
                if (componentsRequireConversionData<Descriptor>(unresolved.components))
                    return CSS::Color { CSSPropertyParserHelpers::normalizeNonCalcRequiringConversionDataComponents(unresolved, state) };
            } else {
                if (componentsContainsUnevaluatedCalc<Descriptor>(unresolved.components))
                    return CSS::Color { CSSPropertyParserHelpers::normalizeNonCalcComponents(unresolved, state) };
            }

            auto resolver = CSS::AbsoluteColorResolver<Descriptor> {
                .components = unresolved.components,
                .nestingLevel = state.nestingLevel
            };
            return CSS::Color { CSS::ResolvedColor { resolveNoConversionDataRequired(WTF::move(resolver)) } };
        }
    });
}

CSS::Color makeRelativeColor(uint8_t descriptor, const CSSColorSwiftComponents& components, CSS::Color&& origin)
{
    return callWithColorSwiftDescriptor(descriptor, [&]<typename Descriptor>() -> CSS::Color {
        if constexpr (std::same_as<Descriptor, AlphaDescriptor>)
            RELEASE_ASSERT_NOT_REACHED();
        else if constexpr (!std::is_constructible_v<CSS::Color, CSS::RelativeColor<Descriptor>&&>)
            RELEASE_ASSERT_NOT_REACHED();
        else {
            std::optional<CSS::RelativeColorComponent<Descriptor, 3>> alpha;
            if (components.type(3))
                alpha = makeRelativeColorSwiftComponent<Descriptor, 3>(components);
            return CSS::Color { CSS::RelativeColor<Descriptor> {
                .origin = WTF::move(origin),
                .components = { makeRelativeColorSwiftComponent<Descriptor, 0>(components), makeRelativeColorSwiftComponent<Descriptor, 1>(components), makeRelativeColorSwiftComponent<Descriptor, 2>(components), WTF::move(alpha) }
            } };
        }
    });
}

CSS::Color makeRelativeAlphaColor(const CSSColorSwiftComponents& components, CSS::Color&& origin)
{
    return CSS::Color { CSS::RelativeAlphaColor {
        .origin = WTF::move(origin),
        .alpha = makeRelativeColorSwiftComponent<CSS::RelativeAlphaColor::Descriptor, 0>(components),
    } };
}

CSS::Color makeColorLayers(CSSColorSwiftList&& list)
{
    return CSS::Color { CSS::ColorLayers { .blendMode = BlendMode::Normal, .colors = WTF::move(list.colors) } };
}

// The Container that `storage` holds behind a UniqueRef, made by the first call.
template<typename Container, typename Storage> static Container& swiftContainer(Storage& storage)
{
    if (auto* container = std::get_if<UniqueRef<Container>>(&storage))
        return container->get();
    return storage.template emplace<UniqueRef<Container>>(makeUniqueRef<Container>()).get();
}

CSSColorSwiftList::~CSSColorSwiftList() = default;

void CSSColorSwiftList::appendMixComponent(const CSSColorSwiftComponents& percentage, CSS::Color&& color)
{
    swiftContainer<CommaSeparatedVector<CSS::ColorMix::Component>::Container>(mixComponents).append(CSS::ColorMix::Component {
        .color = WTF::move(color),
        .percentage = optionalSwiftComponent<CSS::ColorMix::Component::Percentage>(percentage.at(0)),
    });
}

CSS::Color makeColorMix(CSSColorSwiftList&& list)
{
    auto* components = std::get_if<UniqueRef<CommaSeparatedVector<CSS::ColorMix::Component>::Container>>(&list.mixComponents);
    RELEASE_ASSERT(components);
    return CSS::Color { CSS::ColorMix {
        .colorInterpolationMethod = list.colorInterpolationMethod.value_or(CSS::defaultInterpolationMethodForColorMix),
        .components = CommaSeparatedVector<CSS::ColorMix::Component>(WTF::move(components->get())),
    } };
}

Ref<CSSValue> makeColorValue(const CSSPropertyConsumerSwiftValue& value, CSS::Color&& color)
{
    // Special case top level color keywords, hex (SRGBA<uint8_t>) and absolute color values to maintain
    // backwards compatibility and existing optimizations.
    if (auto keyword = color.keyword())
        return CSSKeywordValue::create(keyword->valueID);
    if (auto hex = color.hex())
        return propertyParserState(value).pool.createColorValue(Color { hex->value });
    if (auto resolved = color.resolved())
        return propertyParserState(value).pool.createColorValue(WTF::move(resolved->value));
    return CSSColorValue::create(WTF::move(color));
}

Ref<CSSValue> makeHexColorValue(const CSSPropertyConsumerSwiftValue& value, CSSPropertyConsumerSwiftSRGBA8 hex)
{
    return propertyParserState(value).pool.createColorValue(Color { hex });
}

CSSDynamicRangeLimitSwiftMix::~CSSDynamicRangeLimitSwiftMix() = default;

void CSSDynamicRangeLimitSwiftMix::append(const CSSColorSwiftComponents& percentage, CSS::DynamicRangeLimit&& limit)
{
    swiftContainer<CSS::DynamicRangeLimitMixParameters::Container>(components).append(CSS::DynamicRangeLimitMixComponent { WTF::move(limit), makeColorSwiftComponent<CSS::DynamicRangeLimitMixPercentage>(percentage.at(0)) });
}

size_t CSSDynamicRangeLimitSwiftMix::size() const
{
    auto* components = std::get_if<UniqueRef<CSS::DynamicRangeLimitMixParameters::Container>>(&this->components);
    return components ? (*components)->size() : 0;
}

CSS::DynamicRangeLimit makeDynamicRangeLimitMix(CSSDynamicRangeLimitSwiftMix&& mix)
{
    auto* components = std::get_if<UniqueRef<CSS::DynamicRangeLimitMixParameters::Container>>(&mix.components);
    RELEASE_ASSERT(components);
    return CSS::DynamicRangeLimit {
        CSS::DynamicRangeLimitMixFunction {
            CSS::DynamicRangeLimitMixFunctionValue { CSS::DynamicRangeLimitMixParameters { WTF::move(components->get()) } }
        }
    };
}

// A position's axis T: its keyword or offset is the component at bits 0-3 of `layout`, its length at bits 4-7.
template<typename T> static T makePositionSwiftAxis(const CSSColorSwiftComponents& components, uint16_t layout)
{
    using Offset = decltype(T::offset);
    if constexpr (requires { typename Offset::Tuple; }) {
        using Keyword = std::tuple_element_t<0, typename Offset::Tuple>;
        return T { { makeColorSwiftComponent<Keyword>(components.at(layout & 0xf), brigand::as_list<Keyword> { }), makeColorSwiftComponent<CSS::LengthPercentage<>>(components.at((layout >> 4) & 0xf)) } };
    } else
        return T { makeColorSwiftComponent<Offset>(components.at(layout & 0xf), brigand::as_list<Offset> { }) };
}

// The position whose parts are in `components` at `layout`, as setPositionResult describes it.
static CSS::Position makePositionSwift(const CSSColorSwiftComponents& components, uint16_t layout)
{
    bool horizontalLength = (layout & 0xf0) != 0xf0;
    bool verticalLength = (layout & 0xf000) != 0xf000;
    if (horizontalLength && verticalLength)
        return CSS::Position { CSS::FourComponentPositionHorizontalVertical { makePositionSwiftAxis<CSS::FourComponentPositionHorizontal>(components, layout), makePositionSwiftAxis<CSS::FourComponentPositionVertical>(components, layout >> 8) } };
    if (horizontalLength)
        return CSS::Position { CSS::ThreeComponentPositionHorizontalVerticalLengthFirst { makePositionSwiftAxis<CSS::FourComponentPositionHorizontal>(components, layout), makePositionSwiftAxis<CSS::ThreeComponentPositionVertical>(components, layout >> 8) } };
    if (verticalLength)
        return CSS::Position { CSS::ThreeComponentPositionHorizontalVerticalLengthSecond { makePositionSwiftAxis<CSS::ThreeComponentPositionHorizontal>(components, layout), makePositionSwiftAxis<CSS::FourComponentPositionVertical>(components, layout >> 8) } };
    return CSS::Position { CSS::TwoComponentPositionHorizontalVertical { makePositionSwiftAxis<CSS::TwoComponentPositionHorizontal>(components, layout), makePositionSwiftAxis<CSS::TwoComponentPositionVertical>(components, layout >> 8) } };
}

void setPositionResult(const CSSPropertyConsumerSwiftValue& value, uint16_t consumer, const CSSColorSwiftComponents& components, uint16_t layout)
{
    using Result = CSSPropertyConsumerSwiftUnresolvedResult;
    switch (static_cast<CSSPropertyConsumerSwiftConsumer>(consumer)) {
    case CSSPropertyConsumerSwiftConsumer::Position:
        return Result::set(value, makePositionSwift(components, layout));
    case CSSPropertyConsumerSwiftConsumer::PositionX:
        return Result::set(value, (layout & 0xf0) != 0xf0 ? CSS::PositionX { makePositionSwiftAxis<CSS::FourComponentPositionHorizontal>(components, layout) } : CSS::PositionX { makePositionSwiftAxis<CSS::TwoComponentPositionHorizontal>(components, layout) });
    case CSSPropertyConsumerSwiftConsumer::PositionY:
        return Result::set(value, (layout & 0xf000) != 0xf000 ? CSS::PositionY { makePositionSwiftAxis<CSS::FourComponentPositionVertical>(components, layout >> 8) } : CSS::PositionY { makePositionSwiftAxis<CSS::TwoComponentPositionVertical>(components, layout >> 8) });
    case CSSPropertyConsumerSwiftConsumer::TwoComponentPositionHorizontal:
        return Result::set(value, makePositionSwiftAxis<CSS::TwoComponentPositionHorizontal>(components, layout));
    case CSSPropertyConsumerSwiftConsumer::TwoComponentPositionVertical:
        return Result::set(value, makePositionSwiftAxis<CSS::TwoComponentPositionVertical>(components, layout >> 8));
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }
}

// Swift's image consumers parse these primitives in these ranges, and colors with these types.
static_assert(CSS::GradientLinearColorStopPosition::value_type::range == CSS::Range { -33554430, 33554429, CSS::RangeParseTimeBehavior::Ignore, CSS::RangeParseTimeBehavior::Ignore });
static_assert(CSS::RadialGradient::Ellipse::Size::value_type::range == CSS::Nonnegative && CSS::RadialGradient::Circle::Length::range == CSS::Nonnegative && CSS::Number<CSS::Nonnegative>::range == CSS::Nonnegative && CSS::Resolution<>::range == CSS::Nonnegative && CSS::AnglePercentage<>::range == CSS::All);
static_assert(CSS::WebkitCrossfade::Progress::Number::range == CSS::Range { 0, 1, CSS::RangeParseTimeBehavior::Clamp, CSS::RangeParseTimeBehavior::Clamp } && CSS::WebkitCrossfade::Progress::Percentage::range == CSS::Range { 0, 100, CSS::RangeParseTimeBehavior::Clamp, CSS::RangeParseTimeBehavior::Clamp } && CSS::Crossfade::Component::Percentage::range == CSS::Range { 0, 100 });
static_assert(CSSPropertyParserHelpers::CSSColorParsingOptions { }.allowedColorTypes.toRaw() == 7);

static CSSParserTokenRange swiftTokenRange(const CSSPropertyConsumerSwiftValue& value, uint32_t start, uint32_t end)
{
    auto tokens = static_cast<const CSSPropertyConsumerSwiftValueState&>(value).tokens;
    RELEASE_ASSERT(start <= end && end <= tokens.size());
    return CSSParserTokenRange { tokens.subspan(start, end - start) };
}

uint32_t consumeColorInterpolationMethodForSwift(const CSSPropertyConsumerSwiftValue& value, uint32_t start, uint32_t end, CSS::ColorInterpolationMethod& method)
{
    auto range = swiftTokenRange(value, start, end);
    auto consumed = CSSPropertyParserHelpers::consumeColorInterpolationMethod(range, propertyParserState(value));
    if (!consumed)
        return std::numeric_limits<uint32_t>::max();
    method = WTF::move(*consumed);
    return end - start - range.size();
}

static CSSGradientSwiftStops& gradientSwiftStops(const CSSPropertyConsumerSwiftValue& value)
{
    auto* stops = static_cast<const CSSPropertyConsumerSwiftValueState&>(value).gradientStops;
    RELEASE_ASSERT(stops);
    return *stops;
}

// Gives `append` the color Swift consumed as `color` and `channels`, or what a CSS::Color is made of.
template<typename Append> static void appendSwiftColor(const CSSPropertyConsumerSwiftValue& value, const CSSColorSwiftStopColor& color, const CSSColorSwiftComponents& channels, const Append& append)
{
    switch (color.kind) {
    case CSSColorSwiftKeywordColor:
        return append(CSS::KeywordColor { static_cast<CSSValueID>(color.keyword) });
    case CSSColorSwiftHexColor:
        return append(CSS::HexColor { color.hex });
    case CSSColorSwiftPendingColor: {
        auto& pendingColor = gradientSwiftStops(value).pendingColor;
        append(WTF::move(pendingColor.value()));
        pendingColor = { };
        return;
    }
    default:
        RELEASE_ASSERT(color.kind == CSSColorSwiftFunctionColor);
        return append(makeAbsoluteColor(value, color.descriptor, channels, color.nestingLevel));
    }
}

void beginGradientStops(const CSSPropertyConsumerSwiftValue& value, uint8_t kind)
{
    auto& scratch = gradientSwiftStops(value);
    scratch.pendingColor = { };
    if (kind == CSSGradientSwiftAngularStops)
        scratch.stops.emplace<CSSGradientSwiftStops::Stops<CSS::GradientAngularColorStop>>();
    else if (kind == CSSGradientSwiftDeprecatedStops)
        scratch.stops.emplace<CSSGradientSwiftStops::Stops<CSS::GradientDeprecatedColorStop>>();
    else
        scratch.stops.emplace<CSSGradientSwiftStops::Stops<CSS::GradientLinearColorStop>>();
}

void appendGradientStop(const CSSPropertyConsumerSwiftValue& value, const CSSColorSwiftStopColor& color, const CSSColorSwiftComponents& channels, const CSSColorSwiftComponents& positions, bool second)
{
    WTF::switchOn(gradientSwiftStops(value).stops,
        [](std::monostate) { RELEASE_ASSERT_NOT_REACHED(); },
        [&](CSSGradientSwiftStops::Stops<CSS::GradientDeprecatedColorStop>& stops) {
            appendSwiftColor(value, color, channels, [&](auto&& stopColor) {
                stops.constructAndAppend(CSS::Color { WTF::move(stopColor) }, makeColorSwiftComponent<CSS::GradientDeprecatedColorStopPosition>(positions.at(0), brigand::list<CSS::Number<>, CSS::Percentage<>> { }));
            });
        },
        [&]<typename Stop>(CSSGradientSwiftStops::Stops<Stop>& stops) {
            using Position = typename Stop::Position::value_type;
            if (color.kind == CSSColorSwiftNoColor) {
                stops.constructAndAppend(Markable<CSS::Color> { }, optionalSwiftComponent<Position>(positions.at(0)));
                return;
            }
            appendSwiftColor(value, color, channels, [&](auto&& stopColor) {
                if (second)
                    stops.constructAndAppend(Markable<CSS::Color> { std::in_place, auto { stopColor } }, optionalSwiftComponent<Position>(positions.at(0)));
                stops.constructAndAppend(Markable<CSS::Color> { std::in_place, WTF::move(stopColor) }, optionalSwiftComponent<Position>(positions.at(second ? 1 : 0)));
            });
        });
}

void setPendingColor(const CSSPropertyConsumerSwiftValue& value, CSS::Color&& color)
{
    gradientSwiftStops(value).pendingColor = WTF::move(color);
}

// The stops appended since beginGradientStops, in a list with the capacity shrinkToFit leaves.
template<typename Stop> static typename Stop::List takeGradientSwiftStops(const CSSPropertyConsumerSwiftValue& value)
{
    auto* stops = std::get_if<CSSGradientSwiftStops::Stops<Stop>>(&gradientSwiftStops(value).stops);
    RELEASE_ASSERT(stops);
    typename Stop::List::Container list;
    list.reserveInitialCapacity(stops->size());
    for (auto& stop : *stops)
        list.append(WTF::move(stop));
    stops->clear();
    return { WTF::move(list) };
}

// Out of line, so that Swift calls it instead of emitting the destruction of the colors.
CSSImageSwiftParts::~CSSImageSwiftParts() = default;

void CSSImageSwiftParts::appendColor(const CSSPropertyConsumerSwiftValue& value, const CSSColorSwiftStopColor& color, const CSSColorSwiftComponents& channels, const CSSColorSwiftComponents& components)
{
    if (color.kind == CSSColorSwiftNoColor)
        colors.append(Markable<CSS::Color> { });
    else
        appendSwiftColor(value, color, channels, [&](auto&& stopColor) { colors.append(Markable<CSS::Color> { std::in_place, WTF::move(stopColor) }); });
    positions.append(components.at(0));
}

template<typename Stops> CSS::GradientColorInterpolationMethod CSSImageSwiftParts::gradientColorInterpolationMethod(const Stops& stops) const
{
    // Keyword colors and colors stored as 8-bit sRGB are legacy colors, which interpolate in sRGB by default.
    bool legacy = std::all_of(stops.begin(), stops.end(), [](auto& stop) { return !stop.color || stop.color->isKeyword() || stop.color->absoluteColor().tryGetAsSRGBABytes(); });
    auto defaultMethod = legacy ? CSS::GradientColorInterpolationMethod::Default::SRGB : CSS::GradientColorInterpolationMethod::Default::OKLab;
    if (colorInterpolationMethod)
        return { *colorInterpolationMethod, defaultMethod };
    if (legacy)
        return { { ColorInterpolationMethod::SRGB { }, AlphaPremultiplication::Premultiplied }, defaultMethod };
    return { { ColorInterpolationMethod::OKLab { }, AlphaPremultiplication::Premultiplied }, defaultMethod };
}

// The gradient T: its line, or its size and shape, in `line`, and -webkit-gradient()'s points in `line` 0-1 and 2-3
// and its radii in `radii`.
template<typename T> static T makeGradientSwift(const CSSPropertyConsumerSwiftValue& value, const CSSColorSwiftComponents& line, const CSSColorSwiftComponents& radii, std::optional<CSS::Position>&& position, CSSImageSwiftParts& parts)
{
    auto legacyMethod = CSS::GradientColorInterpolationMethod::legacyMethod(AlphaPremultiplication::Premultiplied);
    if constexpr (std::same_as<T, CSS::DeprecatedLinearGradient> || std::same_as<T, CSS::DeprecatedRadialGradient>) {
        using NumberOrPercentage = brigand::list<CSS::Number<>, CSS::Percentage<>>;
        auto point = [&](uint8_t index) { return CSS::DeprecatedGradientPosition { makeColorSwiftComponent<CSS::NumberOrPercentage<>>(line.at(index), NumberOrPercentage { }), makeColorSwiftComponent<CSS::NumberOrPercentage<>>(line.at(index + 1), NumberOrPercentage { }) }; };
        if constexpr (std::same_as<T, CSS::DeprecatedLinearGradient>)
            return { legacyMethod, { point(0), point(2) }, takeGradientSwiftStops<CSS::GradientDeprecatedColorStop>(value) };
        else
            return { legacyMethod, { point(0), makeColorSwiftComponent<CSS::Number<CSS::Nonnegative>>(radii.at(0)), point(2), makeColorSwiftComponent<CSS::Number<CSS::Nonnegative>>(radii.at(1)) }, takeGradientSwiftStops<CSS::GradientDeprecatedColorStop>(value) };
    } else if constexpr (std::same_as<T, CSS::ConicGradient>) {
        auto stops = takeGradientSwiftStops<CSS::GradientAngularColorStop>(value);
        return { parts.gradientColorInterpolationMethod(stops), { optionalSwiftComponent<CSS::Angle<>>(line.at(0)), WTF::move(position) }, WTF::move(stops) };
    } else {
        auto stops = takeGradientSwiftStops<CSS::GradientLinearColorStop>(value);
        auto method = std::same_as<T, CSS::LinearGradient> || std::same_as<T, CSS::RadialGradient> ? parts.gradientColorInterpolationMethod(stops) : legacyMethod;
        if constexpr (requires { typename T::GradientLine; }) {
            // An angle or a side at line 0, and a vertical side at line 1 after a horizontal one.
            using Line = typename T::GradientLine;
            auto gradientLine = line.type(1) ? Line { SpaceSeparatedTuple { makeColorSwiftComponent<CSS::Horizontal>(line.at(0)), makeColorSwiftComponent<CSS::Vertical>(line.at(1)) } } : makeColorSwiftComponent<Line>(line.at(0));
            return { WTF::move(method), WTF::move(gradientLine), WTF::move(stops) };
        } else {
            // A size at line 0, or two lengths at line 0 and 1, and the shape at line 3.
            using Ellipse = typename T::Ellipse;
            using Circle = typename T::Circle;
            using Lengths = typename Ellipse::Size;
            bool circle = line.at(3).symbol == std::to_underlying(CSSValueID::Circle);
            auto lengths = [&] { return Lengths { makeColorSwiftComponent<typename Lengths::value_type>(line.at(0)), makeColorSwiftComponent<typename Lengths::value_type>(line.at(1)) }; };
            if constexpr (std::same_as<T, CSS::RadialGradient>) {
                if (circle)
                    return { WTF::move(method), Circle { makeColorSwiftComponent<decltype(Circle::size)>(line.at(0)), WTF::move(position) }, WTF::move(stops) };
                return { WTF::move(method), Ellipse { line.type(1) ? decltype(Ellipse::size) { lengths() } : makeColorSwiftComponent<decltype(Ellipse::size)>(line.at(0)), WTF::move(position) }, WTF::move(stops) };
            } else {
                using Size = typename decltype(Ellipse::size)::value_type;
                if (circle)
                    return { WTF::move(method), Circle { optionalSwiftComponent<typename T::Extent>(line.at(0)), WTF::move(position) }, WTF::move(stops) };
                return { WTF::move(method), Ellipse { line.type(1) ? std::optional<Size> { lengths() } : line.type(0) ? std::optional<Size> { makeColorSwiftComponent<typename T::Extent>(line.at(0)) } : std::nullopt, WTF::move(position) }, WTF::move(stops) };
            }
        }
    }
}

// The CSSGradientValue of the alternative of CSS::Gradient named `function`; -webkit-gradient() is radial with radii.
template<typename... Ts> static Ref<CSSValue> makeGradientSwiftValue(const CSSPropertyConsumerSwiftValue& value, uint16_t function, const CSSColorSwiftComponents& line, const CSSColorSwiftComponents& radii, std::optional<CSS::Position>&& position, CSSImageSwiftParts& parts, brigand::list<Ts...>)
{
    RefPtr<CSSValue> result;
    (void)([&] {
        using T = decltype(Ts::parameters);
        if (function != std::to_underlying(Ts::name) || (Ts::name == CSSValueID::WebkitGradient && !!radii.type(0) != std::same_as<T, CSS::DeprecatedRadialGradient>))
            return false;
        result = CSSGradientValue::create(Ts { makeGradientSwift<T>(value, line, radii, WTF::move(position), parts) });
        return true;
    }() || ...);
    return result.releaseNonNull();
}

Ref<CSSValue> makeImageValue(const CSSPropertyConsumerSwiftValue& value, uint16_t function, const CSSColorSwiftComponents& line, const CSSColorSwiftComponents& position, uint16_t positionLayout, CSSImageSwiftParts&& parts)
{
    auto imageOrNone = [](Ref<CSSValue>& image) { return isValueID(image.get(), CSSValueID::None) ? CSS::ImageOrNone { CSS::Keyword::None { } } : CSS::ImageOrNone { CSS::ImageWrapper { image } }; };
    switch (static_cast<CSSValueID>(function)) {
    case CSSValueID::WebkitCrossFade:
        return CSSCrossfadeValue::create(CSS::WebkitCrossfadeFunction { { imageOrNone(parts.images[0]), imageOrNone(parts.images[1]), makeColorSwiftComponent<CSS::WebkitCrossfade::Progress>(line.at(0), brigand::list<CSS::WebkitCrossfade::Progress::Number, CSS::WebkitCrossfade::Progress::Percentage> { }) } });
    case CSSValueID::CrossFade: {
        CommaSeparatedVector<CSS::Crossfade::Component> components;
        for (size_t i = 0; i < parts.images.size(); ++i)
            components.value.append({ { parts.images[i] }, optionalSwiftComponent<CSS::Crossfade::Component::Percentage>(parts.positions[i]) });
        return CSSCrossfadeValue::create(CSS::CrossfadeFunction { { WTF::move(components) } });
    }
    case CSSValueID::Image:
        return CSSColorImageValue::create(WTF::move(*parts.colors[0]));
    case CSSValueID::LightDark:
        return CSSLightDarkImageValue::create(WTF::move(parts.images[0]), WTF::move(parts.images[1]));
    case CSSValueID::ImageSet:
        return CSSImageSetValue::create(WTF::move(parts.images));
    default:
        std::optional<CSS::Position> at;
        if (positionLayout != CSSImageSwiftNoPosition)
            at = makePositionSwift(position, positionLayout);
        return makeGradientSwiftValue(value, function, line, position, WTF::move(at), parts, brigand::as_list<CSS::Gradient> { });
    }
}

RefPtr<CSSValue> makeImageURLValue(const CSSPropertyConsumerSwiftValue& value, uint32_t start, uint32_t end)
{
    auto& state = propertyParserState(value);
    auto range = swiftTokenRange(value, start, end);
    auto url = range.peek().type() == StringToken ? CSS::completeURL(range.peek().value().toAtomString().string(), state.context) : CSSPropertyParserHelpers::consumeURLRaw(range, state, { CSSPropertyParserHelpers::AllowedURLModifiers::CrossOrigin, CSSPropertyParserHelpers::AllowedURLModifiers::ReferrerPolicy, CSSPropertyParserHelpers::AllowedURLModifiers::Param });
    if (!url)
        return nullptr;
    return CSSImageValue::create(WTF::move(*url));
}

RefPtr<CSSValue> makeFilterImageValue(const CSSPropertyConsumerSwiftValue& value, CSSValue& image, uint32_t start, uint32_t end)
{
    auto range = swiftTokenRange(value, start, end);
    auto filter = CSSPropertyParserHelpers::consumeUnresolvedFilter(range, propertyParserState(value));
    if (!filter || !range.atEnd())
        return nullptr;
    return CSSFilterImageValue::create(Ref { image }, WTF::move(*filter));
}

RefPtr<CSSValue> makeNamedImageValue(const CSSPropertyConsumerSwiftValue& value, uint16_t function, uint32_t name, uint32_t argumentsStart, uint32_t argumentsEnd)
{
    auto ident = CSS::CustomIdent { swiftTokenRange(value, name, name + 1).peek().value().toAtomString() };
    if (function == std::to_underlying(CSSValueID::WebkitCanvas))
        return CSSCanvasValue::create(WTF::move(ident));
    if (function == std::to_underlying(CSSValueID::WebkitNamedImage))
        return CSSNamedImageValue::create(WTF::move(ident));
    if (!propertyParserState(value).context.cssPaintingAPIEnabled)
        return nullptr;
    return CSSPaintImageValue::create(WTF::move(ident), CSSVariableData::create(swiftTokenRange(value, argumentsStart, argumentsEnd)));
}

Ref<CSSValue> makeImageSetOptionValue(const CSSPropertyConsumerSwiftValue& value, CSSValue& image, const CSSColorSwiftComponents& resolution, uint32_t type)
{
    std::optional<FunctionNotation<CSSValueID::Type, CSS::String>> typeFunction;
    if (type != std::numeric_limits<uint32_t>::max())
        typeFunction = FunctionNotation<CSSValueID::Type, CSS::String> { CSS::String { swiftTokenRange(value, type, type + 1).peek().value().toString() } };
    return CSSImageSetOptionValue::create(Ref { image }, optionalSwiftComponent<CSS::Resolution<>>(resolution.at(0)), WTF::move(typeFunction));
}

// Swift's border, shadow and reflection consumers parse these primitives in these ranges.
static_assert(CSS::BorderRadius::LengthPercentage::range == CSS::Nonnegative && CSS::BorderImageSlice::Value::Number::range == CSS::Nonnegative && CSS::BorderImageSlice::Value::Percentage::range == CSS::Nonnegative && CSS::BorderImageWidth::Value::Number::range == CSS::Nonnegative && CSS::BorderImageWidth::Value::LengthPercentage::range == CSS::Nonnegative && CSS::BorderImageOutset::Value::Number::range == CSS::Nonnegative && CSS::BorderImageOutset::Value::Length::range == CSS::Nonnegative);
static_assert(CSS::WebkitBoxReflection::Offset::range == CSS::All);

// The edges Edges of the components [offset, offset + 4) of `positions`, of the types Ts, completed from the present ones.
template<typename Edges, typename Positions, typename... Ts> static Edges makeBorderSwiftEdges(const Positions& positions, size_t offset, brigand::list<Ts...> types)
{
    std::array<std::optional<typename Edges::value_type>, 4> values;
    for (size_t i = 0; i < 4 && positions[offset + i].type; ++i)
        values[i] = makeColorSwiftComponent<typename Edges::value_type>(positions[offset + i], types);
    return CSSPropertyParserHelpers::completeQuadFromArray<Edges>(WTF::move(values));
}

uint32_t setBorderResult(const CSSPropertyConsumerSwiftValue& value, uint16_t consumer, CSSImageSwiftParts&& parts, uint32_t maskStart)
{
    using namespace CSS::Literals;
    using Result = CSSPropertyConsumerSwiftUnresolvedResult;
    using Consumer = CSSPropertyConsumerSwiftConsumer;
    auto& positions = parts.positions;
    auto source = [&] { return parts.images.isEmpty() ? CSS::BorderImageSource { CSS::Keyword::None { } } : CSS::BorderImageSource { Ref { parts.images[0] } }; };
    auto slice = [&](size_t offset) { return CSS::BorderImageSlice { makeBorderSwiftEdges<CSS::BorderImageSlice::Edges>(positions, offset, brigand::list<CSS::BorderImageSlice::Value::Number, CSS::BorderImageSlice::Value::Percentage> { }), positions[offset + 4].type ? std::optional { CSS::Keyword::Fill { } } : std::nullopt }; };
    auto width = [&](size_t offset) {
        auto values = makeBorderSwiftEdges<CSS::BorderImageWidth::Edges>(positions, offset, brigand::list<CSS::Keyword::Auto, CSS::BorderImageWidth::Value::LengthPercentage, CSS::BorderImageWidth::Value::Number> { });
        bool legacy = (value.consumerOptions() & CSSPropertyConsumerSwiftBorderImageWidthOverridesWidthForLength) && (values.top().isLength() || values.right().isLength() || values.bottom().isLength() || values.left().isLength());
        return CSS::BorderImageWidth { WTF::move(values), legacy };
    };
    auto outset = [&](size_t offset) { return CSS::BorderImageOutset { makeBorderSwiftEdges<CSS::BorderImageOutset::Edges>(positions, offset, brigand::list<CSS::BorderImageOutset::Value::Length, CSS::BorderImageOutset::Value::Number> { }) }; };
    auto rules = [&](size_t offset) { return CSS::BorderImageRepeat { { makeColorSwiftComponent<CSS::BorderImageRepeat::Value>(positions[offset]), makeColorSwiftComponent<CSS::BorderImageRepeat::Value>(positions[offset + 1]) } }; };
    auto part = [&](size_t offset, const auto& make) { return positions[offset].type ? std::optional { make(offset) } : std::nullopt; };
    auto set = [&](auto&& result) -> uint32_t {
        Result::set(value, std::forward<decltype(result)>(result));
        return 0;
    };
    using Radii = brigand::list<CSS::BorderRadius::LengthPercentage>;
    switch (static_cast<Consumer>(consumer)) {
    case Consumer::BorderRadius:
    case Consumer::WebKitBorderRadius:
        return set(CSS::BorderRadius { makeBorderSwiftEdges<CSS::BorderRadius::Axis>(positions, 0, Radii { }), makeBorderSwiftEdges<CSS::BorderRadius::Axis>(positions, 4, Radii { }) });
    case Consumer::BorderRadiusSide: {
        auto radius = [&](size_t index) { return makeColorSwiftComponent<CSS::BorderRadiusSide::LengthPercentage>(positions[index]); };
        return set(CSS::BorderRadiusSide { { radius(0), radius(1) }, { radius(2), radius(3) } });
    }
    case Consumer::BorderImageSource:
        return set(source());
    case Consumer::BorderImageOutset:
        return set(outset(0));
    case Consumer::BorderImageRepeat:
        return set(rules(0));
    case Consumer::BorderImageSlice:
        return set(slice(0));
    case Consumer::BorderImageWidth:
        return set(width(0));
    case Consumer::BorderImage:
        return set(CSS::BorderImage { positions[15].type ? std::optional { source() } : std::nullopt, part(0, slice), part(5, width), part(9, outset), part(13, rules) });
    case Consumer::BoxShadow:
    case Consumer::WebkitBoxShadow: {
        if (parts.colors.isEmpty())
            return set(CSS::BoxShadowProperty { CSS::Keyword::None { } });
        CSS::BoxShadowProperty::List shadows;
        for (size_t i = 0; i < parts.colors.size(); ++i) {
            shadows.value.append(CSS::BoxShadow {
                .color = WTF::move(parts.colors[i]),
                .location = { makeColorSwiftComponent<CSS::Length<>>(positions[5 * i + 1]), makeColorSwiftComponent<CSS::Length<>>(positions[5 * i + 2]) },
                .blur = optionalSwiftComponent<CSS::Length<CSS::Nonnegative>>(positions[5 * i + 3]),
                .spread = optionalSwiftComponent<CSS::Length<>>(positions[5 * i + 4]),
                .inset = positions[5 * i].type ? std::optional { CSS::Keyword::Inset { } } : std::nullopt,
                .isWebkitBoxShadow = static_cast<Consumer>(consumer) == Consumer::WebkitBoxShadow,
            });
        }
        return set(CSS::BoxShadowProperty { WTF::move(shadows) });
    }
    case Consumer::WebkitBoxReflect: {
        if (positions.isEmpty())
            return set(CSS::WebkitBoxReflect { CSS::Keyword::None { } });
        std::optional<CSS::WebkitBoxReflection::Mask> mask;
        size_t consumed = 0;
        if (maskStart != std::numeric_limits<uint32_t>::max()) {
            auto range = swiftTokenRange(value, maskStart, static_cast<uint32_t>(value.count()));
            consumed = range.size();
            mask = CSSPropertyParserHelpers::consumeUnresolvedMaskBorder(range, propertyParserState(value), CSSPropertyParserHelpers::MaskBorderSliceOverride::AlwaysFill);
            if (!mask)
                return std::numeric_limits<uint32_t>::max();
            consumed -= range.size();
        }
        set(CSS::WebkitBoxReflect { CSS::WebkitBoxReflection {
            .direction = makeColorSwiftComponent<CSS::WebkitBoxReflection::Direction>(positions[0]),
            .offset = optionalSwiftComponent<CSS::WebkitBoxReflection::Offset>(positions[1]).value_or(CSS::WebkitBoxReflection::Offset { 0_css_px }),
            .mask = WTF::move(mask).value_or(CSS::WebkitBoxReflection::Mask { }),
        } });
        return static_cast<uint32_t>(consumed);
    }
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }
}

Ref<CSSValue> makeBackgroundRepeatValue(uint16_t horizontal, uint16_t vertical)
{
    return CSSBackgroundRepeatValue::create(static_cast<CSSValueID>(horizontal), static_cast<CSSValueID>(vertical));
}

namespace CSSPropertyParserHelpers {

// MARK: - Raw parsing entry points

Color parseColorRawGeneral(StringView string, const CSSParserContext& context, ScriptExecutionContext& scriptExecutionContext, const CSSColorParsingOptions& options, CSS::PlatformColorResolutionState& eagerResolutionState)
{
    CSSTokenizer tokenizer(string);
    CSSParserTokenRange range(tokenizer.tokenRange());

    // Handle leading whitespace.
    range.consumeWhitespace();

    auto state = CSS::PropertyParserState { .context = context, .pool = scriptExecutionContext.cssValuePool() };
    auto result = consumeUnresolvedColor(range, state, options);

    // Handle trailing whitespace.
    range.consumeWhitespace();

    if (!range.atEnd() || !result)
        return { };

    return createColor(*result, eagerResolutionState);
}

Color deprecatedParseColorRawWithoutContext(StringView string, const CSSColorParsingOptions& options)
{
    auto& context = strictCSSParserContext();
    if (auto color = CSSParserFastPaths::parseSimpleColor(string, context))
        return *color;

    CSSTokenizer tokenizer(string);
    CSSParserTokenRange range(tokenizer.tokenRange());

    // Handle leading whitespace.
    range.consumeWhitespace();

    auto state = CSS::PropertyParserState { .context = context };
    auto result = consumeUnresolvedColor(range, state, options);

    // Handle trailing whitespace.
    range.consumeWhitespace();

    if (!range.atEnd() || !result)
        return { };

    return result->absoluteColor();
}

// MARK: - <dynamic-range-limit-mix()> (unresolved)

std::optional<CSS::DynamicRangeLimit> consumeUnresolvedDynamicRangeLimit(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::DynamicRangeLimit>(range, state, CSSPropertyConsumerSwiftConsumer::DynamicRangeLimit);
}

// MARK: -  <'dynamic-range-limit'> (CSSValue)

RefPtr<CSSValue> consumeDynamicRangeLimit(CSSParserTokenRange& range, CSS::PropertyParserState& propertyParserState)
{
    auto dynamicRangeLimit = consumeUnresolvedDynamicRangeLimit(range, propertyParserState);
    if (!dynamicRangeLimit)
        return { };
    return CSSDynamicRangeLimitValue::create(WTF::move(*dynamicRangeLimit));
}

} // namespace CSSPropertyParserHelpers
} // namespace WebCore
