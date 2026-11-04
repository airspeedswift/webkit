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

#include "CSSParserTokenRange.h"
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyParserConsumer+Background.h"
#include "CSSPropertyParserState.h"
#include <array>
#include <optional>
#include <wtf/Brigand.h>

namespace WebCore {

inline CSS::PropertyParserState& propertyParserState(const CSSPropertyConsumerSwiftValue& value)
{
    return static_cast<const CSSPropertyConsumerSwiftValueState&>(value).propertyParserState;
}

inline CSSParserTokenRange swiftTokenRange(const CSSPropertyConsumerSwiftValue& value, uint32_t start, uint32_t end)
{
    auto tokens = static_cast<const CSSPropertyConsumerSwiftValueState&>(value).tokens;
    RELEASE_ASSERT(start <= end && end <= tokens.size());
    return CSSParserTokenRange { tokens.subspan(start, end - start) };
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
inline CSS::Position makePositionSwift(const CSSColorSwiftComponents& components, uint16_t layout)
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

// The edges Edges of the components [offset, offset + 4) of `positions`, of the types Ts, completed from the present ones.
template<typename Edges, typename Positions, typename... Ts> static Edges makeBorderSwiftEdges(const Positions& positions, size_t offset, brigand::list<Ts...> types)
{
    std::array<std::optional<typename Edges::value_type>, 4> values;
    for (size_t i = 0; i < 4 && positions[offset + i].type; ++i)
        values[i] = makeColorSwiftComponent<typename Edges::value_type>(positions[offset + i], types);
    return CSSPropertyParserHelpers::completeQuadFromArray<Edges>(WTF::move(values));
}

} // namespace WebCore
