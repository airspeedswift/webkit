/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
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
#include "CSSPropertyParserConsumer+Easing.h"

#include "CSSEasingFunctionValue.h"
#include "CSSParserContext.h"
#include "CSSParserTokenRange.h"
#include "CSSPropertyParserConsumer+CSSPrimitiveValueResolver.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+IntegerDefinitions.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+NumberDefinitions.h"
#include "CSSPropertyParserConsumer+PercentageDefinitions.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserState.h"
#include "CSSValueKeywords.h"
#include "StyleEasingFunction.h"
#include "TimingFunction.h"
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyConsumerSwiftComponents.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

// The ranges of the numbers and step counts Swift consumes.
static_assert(CSS::ClosedUnitRange == CSS::Range { 0, 1 } && CSS::SpringEasingParameters::Positive == CSS::Range { std::numeric_limits<double>::denorm_min(), CSS::Range::infinity });
static_assert(decltype(CSS::StepsEasingParameters::JumpNone::steps)::range == CSS::Range { 2, CSS::Range::infinity });
static_assert(decltype(CSS::StepsEasingParameters::JumpStart::steps)::range == CSS::Range { 1, CSS::Range::infinity } && decltype(CSS::StepsEasingParameters::JumpEnd::steps)::range == CSS::Range { 1, CSS::Range::infinity } && decltype(CSS::StepsEasingParameters::JumpBoth::steps)::range == CSS::Range { 1, CSS::Range::infinity } && decltype(CSS::StepsEasingParameters::Start::steps)::range == CSS::Range { 1, CSS::Range::infinity } && decltype(CSS::StepsEasingParameters::End::steps)::range == CSS::Range { 1, CSS::Range::infinity });

std::optional<CSS::EasingFunction> consumeUnresolvedEasingFunction(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::EasingFunction>(range, state, CSSPropertyConsumerSwiftConsumer::UnresolvedEasingFunction);
}

RefPtr<CSSValue> consumeEasingFunction(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumePropertyWithSwift(range, state, CSSPropertyConsumerSwiftConsumer::EasingFunction);
}

RefPtr<TimingFunction> parseEasingFunctionDeprecated(StringView string, const CSSParserContext& context)
{
    auto tokenizer = CSSTokenizer(string);
    auto range = tokenizer.tokenRange();

    // Handle leading whitespace.
    range.consumeWhitespace();

    auto state = CSS::PropertyParserState { .context = context };
    auto result = consumeUnresolvedEasingFunction(range, state);
    if (!result)
        return { };

    // Handle trailing whitespace.
    range.consumeWhitespace();

    if (!range.atEnd())
        return { };

    return Style::createTimingFunctionDeprecated(*result);
}

} // namespace CSSPropertyParserHelpers

void appendLinearEasingStop(const CSSPropertyConsumerSwiftValue& value, const CSSColorSwiftComponents& stop)
{
    std::optional<CSS::LinearEasingParameters::Stop::Length> input;
    if (stop.type(1))
        input = CSS::LinearEasingParameters::Stop::Length { makeColorSwiftComponent<CSS::Percentage<>>(stop.at(1)), optionalSwiftComponent<CSS::Percentage<>>(stop.at(2)) };
    swiftStopsAs<Vector<CSS::LinearEasingParameters::Stop>>(value).append(CSS::LinearEasingParameters::Stop { .output = makeColorSwiftComponent<CSS::Number<>>(stop.at(0)), .input = WTF::move(input) });
}

RefPtr<CSSValue> setEasingFunctionResult(const CSSPropertyConsumerSwiftValue& value, uint16_t consumer, uint16_t function, uint16_t keyword, const CSSColorSwiftComponents& numbers, double count, uint32_t countCalc, CSSImageSwiftParts&&)
{
    using Steps = CSS::StepsEasingParameters;
    auto steps = [&]<typename Kind>(std::type_identity<Kind>) {
        using Count = decltype(Kind::steps);
        if (countCalc != std::numeric_limits<uint32_t>::max())
            return CSS::EasingFunction { CSS::StepsEasingFunction { .parameters = { Kind { consumeSwiftCheckedCalc<Count>(value, countCalc) } } } };
        return CSS::EasingFunction { CSS::StepsEasingFunction { .parameters = { Kind { Count { typename Count::Raw { CSS::IntegerUnit::Integer, count } } } } } };
    };
    auto easing = [&] -> CSS::EasingFunction {
        switch (static_cast<CSSValueID>(function)) {
        case CSSValueID::CubicBezier:
            return { CSS::CubicBezierEasingFunction { .parameters = { .value = {
                CSS::CubicBezierEasingParameters::Coordinate { makeColorSwiftComponent<CSS::Number<CSS::ClosedUnitRange>>(numbers.at(0)), makeColorSwiftComponent<CSS::Number<>>(numbers.at(1)) },
                CSS::CubicBezierEasingParameters::Coordinate { makeColorSwiftComponent<CSS::Number<CSS::ClosedUnitRange>>(numbers.at(2)), makeColorSwiftComponent<CSS::Number<>>(numbers.at(3)) },
            } } } };
        case CSSValueID::Spring:
            return { CSS::SpringEasingFunction { .parameters = {
                .mass = makeColorSwiftComponent<CSS::Number<CSS::SpringEasingParameters::Positive>>(numbers.at(0)),
                .stiffness = makeColorSwiftComponent<CSS::Number<CSS::SpringEasingParameters::Positive>>(numbers.at(1)),
                .damping = makeColorSwiftComponent<CSS::Number<CSS::Nonnegative>>(numbers.at(2)),
                .initialVelocity = makeColorSwiftComponent<CSS::Number<>>(numbers.at(3)),
            } } };
        case CSSValueID::Linear:
            return { CSS::LinearEasingFunction { .parameters = { .stops = { WTF::move(swiftStopsAs<Vector<CSS::LinearEasingParameters::Stop>>(value)) } } } };
        case CSSValueID::Steps:
            break;
        default:
            switch (static_cast<CSSValueID>(keyword)) {
            case CSSValueID::Linear: return { CSS::Keyword::Linear { } };
            case CSSValueID::Ease: return { CSS::Keyword::Ease { } };
            case CSSValueID::EaseIn: return { CSS::Keyword::EaseIn { } };
            case CSSValueID::EaseOut: return { CSS::Keyword::EaseOut { } };
            case CSSValueID::EaseInOut: return { CSS::Keyword::EaseInOut { } };
            case CSSValueID::StepStart: return { CSS::StepsEasingFunction { .parameters = { Steps::Start { CSS::Integer<CSS::Range { 1, CSS::Range::infinity }> { 1 } } } } };
            case CSSValueID::StepEnd: return { CSS::StepsEasingFunction { .parameters = { Steps::End { CSS::Integer<CSS::Range { 1, CSS::Range::infinity }> { 1 } } } } };
            default: RELEASE_ASSERT_NOT_REACHED();
            }
        }
        switch (static_cast<CSSValueID>(keyword)) {
        case CSSValueID::JumpStart: return steps(std::type_identity<Steps::JumpStart> { });
        case CSSValueID::JumpEnd: return steps(std::type_identity<Steps::JumpEnd> { });
        case CSSValueID::JumpNone: return steps(std::type_identity<Steps::JumpNone> { });
        case CSSValueID::JumpBoth: return steps(std::type_identity<Steps::JumpBoth> { });
        case CSSValueID::Start: return steps(std::type_identity<Steps::Start> { });
        case CSSValueID::End: return steps(std::type_identity<Steps::End> { });
        default: RELEASE_ASSERT_NOT_REACHED();
        }
    };
    if (static_cast<CSSPropertyConsumerSwiftConsumer>(consumer) == CSSPropertyConsumerSwiftConsumer::EasingFunction)
        return CSSEasingFunctionValue::create(easing());
    CSSPropertyConsumerSwiftUnresolvedResult::set(value, easing());
    return nullptr;
}
} // namespace WebCore
