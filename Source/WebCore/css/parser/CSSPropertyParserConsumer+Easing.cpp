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
#if USE_SWIFT_CSS_PROPERTY_CONSUMERS_4
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyConsumerSwiftComponents.h"
#endif

namespace WebCore {
namespace CSSPropertyParserHelpers {

#if !USE_SWIFT_CSS_PROPERTY_CONSUMERS_4
// MARK: - <steps()>

static std::optional<CSS::EasingFunction> consumeUnresolvedStepsEasingFunction(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <steps-easing-function> = steps( <integer>, <steps-easing-function-position>? )
    // <steps-easing-function-position> = jump-start | jump-end | jump-none | jump-both | start | end
    //
    // with range constraints, this is:
    //
    // <steps-easing-function> = steps( <integer [1,∞]>, jump-start )
    //                         | steps( <integer [1,∞]>, jump-end )
    //                         | steps( <integer [1,∞]>, jump-both )
    //                         | steps( <integer [1,∞]>, start )
    //                         | steps( <integer [1,∞]>, end )
    //                         | steps( <integer [2,∞]>, jump-none )
    // https://drafts.csswg.org/css-easing-2/#funcdef-steps

    ASSERT(range.peek().functionId() == CSSValueID::Steps);
    auto rangeCopy = range;
    auto args = consumeFunction(rangeCopy);

    // Stash args so we can re-parse if we get `jump-none`.
    auto stashedArgs = args;

    auto steps = MetaConsumer<CSS::Integer<CSS::Range{1,CSS::Range::infinity}>>::consume(args, state);
    if (!steps)
        return { };

    std::optional<CSS::StepsEasingParameters> parameters;

    if (consumeCommaIncludingWhitespace(args)) {
        switch (args.consumeIncludingWhitespace().id()) {
        case CSSValueID::JumpStart:
            parameters = { CSS::StepsEasingParameters::JumpStart { WTF::move(*steps) } };
            break;
        case CSSValueID::JumpEnd:
            parameters = { CSS::StepsEasingParameters::JumpEnd { WTF::move(*steps) } };
            break;
        case CSSValueID::JumpNone: {
            // "The first parameter specifies the number of intervals in the function. It must be a
            //  positive integer greater than 0 unless the second parameter is jump-none in which
            //  case it must be a positive integer greater than 1."

            // Re-parse `steps` to account for different type requirement.
            auto stepsJumpNone = MetaConsumer<CSS::Integer<CSS::Range{2,CSS::Range::infinity}>>::consume(stashedArgs, state);
            if (!stepsJumpNone)
                return { };

            parameters = { CSS::StepsEasingParameters::JumpNone { WTF::move(*stepsJumpNone) } };
            break;
        }

        case CSSValueID::JumpBoth:
            parameters = { CSS::StepsEasingParameters::JumpBoth { WTF::move(*steps) } };
            break;
        case CSSValueID::Start:
            parameters = { CSS::StepsEasingParameters::Start { WTF::move(*steps) } };
            break;
        case CSSValueID::End:
            parameters = { CSS::StepsEasingParameters::End { WTF::move(*steps) } };
            break;
        default:
            return { };
        }
    } else
        parameters = { CSS::StepsEasingParameters::End { WTF::move(*steps) } };

    if (!args.atEnd())
        return { };

    range = rangeCopy;

    return CSS::EasingFunction {
        CSS::StepsEasingFunction {
            .parameters = WTF::move(*parameters)
        }
    };
}

// MARK: - <linear()>

static std::optional<CSS::LinearEasingParameters::Stop::Length> consumeUnresolvedLinearEasingFunctionStopLength(CSSParserTokenRange& args, CSS::PropertyParserState& state)
{
    // <linear-easing-function-stop-length> = <percentage>{0,2}

    auto input = MetaConsumer<CSS::Percentage<>>::consume(args, state);
    if (!input)
        return { };
    auto extra = MetaConsumer<CSS::Percentage<>>::consume(args, state);

    return CSS::LinearEasingParameters::Stop::Length {
        .input = WTF::move(*input),
        .extra = WTF::move(extra)
    };
}

static std::optional<CSS::LinearEasingParameters::Stop> consumeUnresolvedLinearEasingFunctionStop(CSSParserTokenRange& args, CSS::PropertyParserState& state)
{
    // <linear-easing-function-stop> = <number> && <percentage>{0,2}

    auto output = MetaConsumer<CSS::Number<>>::consume(args, state);
    std::optional<CSS::LinearEasingParameters::Stop::Length> input;
    if (output)
        input = consumeUnresolvedLinearEasingFunctionStopLength(args, state);
    else {
        input = consumeUnresolvedLinearEasingFunctionStopLength(args, state);
        if (!input)
            return { };
        output = MetaConsumer<CSS::Number<>>::consume(args, state);
        if (!output)
            return { };
    }

    return CSS::LinearEasingParameters::Stop {
        .output = WTF::move(*output),
        .input = WTF::move(input)
    };
}

static std::optional<CSS::EasingFunction> consumeUnresolvedLinearEasingFunction(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <linear()> = linear( [ <number> && <percentage>{0,2} ]# )
    // https://drafts.csswg.org/css-easing-2/#funcdef-linear

    ASSERT(range.peek().functionId() == CSSValueID::Linear);
    auto rangeCopy = range;
    auto args = consumeFunction(rangeCopy);

    Vector<CSS::LinearEasingParameters::Stop> stops;

    while (true) {
        auto stop = consumeUnresolvedLinearEasingFunctionStop(args, state);
        if (!stop)
            break;

        stops.append(WTF::move(*stop));

        if (!consumeCommaIncludingWhitespace(args))
            break;
    }

    if (!args.atEnd() || stops.size() < 2)
        return { };

    range = rangeCopy;

    return CSS::EasingFunction {
        CSS::LinearEasingFunction {
            .parameters = {
                .stops = { WTF::move(stops) }
            }
        }
    };
}

// MARK: - <cubic-bezier()>

static std::optional<CSS::EasingFunction> consumeUnresolvedCubicBezierEasingFunction(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <cubic-bezier()> = cubic-bezier( [ <number [0,1]>, <number> ]#{2} )
    // https://drafts.csswg.org/css-easing-2/#funcdef-cubic-bezier

    ASSERT(range.peek().functionId() == CSSValueID::CubicBezier);
    auto rangeCopy = range;
    auto args = consumeFunction(rangeCopy);

    auto x1 = MetaConsumer<CSS::Number<CSS::ClosedUnitRange>>::consume(args, state);
    if (!x1)
        return { };
    if (!consumeCommaIncludingWhitespace(args))
        return { };
    auto y1 = MetaConsumer<CSS::Number<>>::consume(args, state);
    if (!y1)
        return { };
    if (!consumeCommaIncludingWhitespace(args))
        return { };
    auto x2 = MetaConsumer<CSS::Number<CSS::ClosedUnitRange>>::consume(args, state);
    if (!x2)
        return { };
    if (!consumeCommaIncludingWhitespace(args))
        return { };
    auto y2 = MetaConsumer<CSS::Number<>>::consume(args, state);
    if (!y2)
        return { };

    if (!args.atEnd())
        return { };

    range = rangeCopy;

    return CSS::EasingFunction {
        CSS::CubicBezierEasingFunction {
            .parameters = {
                .value = {
                    CSS::CubicBezierEasingParameters::Coordinate { WTF::move(*x1), WTF::move(*y1) },
                    CSS::CubicBezierEasingParameters::Coordinate { WTF::move(*x2), WTF::move(*y2) },
                }
            }
        }
    };
}

// MARK: - <spring()>

static std::optional<CSS::EasingFunction> consumeUnresolvedSpringEasingFunction(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <spring()> = spring( <number [>0,∞]> <number [>0,∞]> <number [0,∞]> <number> )
    // Non-standard

    ASSERT(range.peek().functionId() == CSSValueID::Spring);

    if (!state.context.springTimingFunctionEnabled)
        return { };

    auto rangeCopy = range;
    auto args = consumeFunction(rangeCopy);

    auto mass = MetaConsumer<CSS::Number<CSS::SpringEasingParameters::Positive>>::consume(args, state);
    if (!mass)
        return { };
    auto stiffness = MetaConsumer<CSS::Number<CSS::SpringEasingParameters::Positive>>::consume(args, state);
    if (!stiffness)
        return { };
    auto damping = MetaConsumer<CSS::Number<CSS::Nonnegative>>::consume(args, state);
    if (!damping)
        return { };
    auto initialVelocity = MetaConsumer<CSS::Number<>>::consume(args, state);
    if (!initialVelocity)
        return { };

    if (!args.atEnd())
        return { };

    range = rangeCopy;

    return CSS::EasingFunction {
        CSS::SpringEasingFunction {
            .parameters = {
                .mass = WTF::move(*mass),
                .stiffness = WTF::move(*stiffness),
                .damping = WTF::move(*damping),
                .initialVelocity = WTF::move(*initialVelocity),
            }
        }
    };
}

// MARK: - <easing-function>

std::optional<CSS::EasingFunction> consumeUnresolvedEasingFunction(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <easing-function> = linear | ease | ease-in | ease-out | ease-in-out | step-start | step-end | <linear()> | <cubic-bezier()> | <steps()>
    // NOTE: also includes non-standard <spring()>.
    // https://drafts.csswg.org/css-easing/#typedef-easing-function

    switch (range.peek().id()) {
    case CSSValueID::Linear:
        range.consumeIncludingWhitespace();
        return CSS::EasingFunction { CSS::Keyword::Linear { } };
    case CSSValueID::Ease:
        range.consumeIncludingWhitespace();
        return CSS::EasingFunction { CSS::Keyword::Ease { } };
    case CSSValueID::EaseIn:
        range.consumeIncludingWhitespace();
        return CSS::EasingFunction { CSS::Keyword::EaseIn { } };
    case CSSValueID::EaseOut:
        range.consumeIncludingWhitespace();
        return CSS::EasingFunction { CSS::Keyword::EaseOut { } };
    case CSSValueID::EaseInOut:
        range.consumeIncludingWhitespace();
        return CSS::EasingFunction { CSS::Keyword::EaseInOut { } };

    case CSSValueID::StepStart:
        range.consumeIncludingWhitespace();
        return CSS::EasingFunction {
            CSS::StepsEasingFunction {
                .parameters = { CSS::StepsEasingParameters::Start { CSS::Integer<CSS::Range{1,CSS::Range::infinity}> { 1 } } }
            }
        };

    case CSSValueID::StepEnd:
        range.consumeIncludingWhitespace();
        return CSS::EasingFunction {
            CSS::StepsEasingFunction {
                .parameters = { CSS::StepsEasingParameters::End { CSS::Integer<CSS::Range{1,CSS::Range::infinity}> { 1 } } }
            }
        };

    default:
        break;
    }

    switch (range.peek().functionId()) {
    case CSSValueID::Linear:
        return consumeUnresolvedLinearEasingFunction(range, state);

    case CSSValueID::CubicBezier:
        return consumeUnresolvedCubicBezierEasingFunction(range, state);

    case CSSValueID::Steps:
        return consumeUnresolvedStepsEasingFunction(range, state);

    case CSSValueID::Spring:
        return consumeUnresolvedSpringEasingFunction(range, state);

    default:
        break;
    }

    return { };
}

RefPtr<CSSValue> consumeEasingFunction(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // Avoid allocation of a CSSEasingFunctionValue when the result is a just a value ID.
    switch (range.peek().id()) {
    case CSSValueID::Linear:
    case CSSValueID::Ease:
    case CSSValueID::EaseIn:
    case CSSValueID::EaseOut:
    case CSSValueID::EaseInOut:
        return consumeIdent(range);
    default:
        break;
    }

    if (auto value = consumeUnresolvedEasingFunction(range, state))
        return CSSEasingFunctionValue::create(WTF::move(*value));
    return { };
}
#endif

#if USE_SWIFT_CSS_PROPERTY_CONSUMERS_4
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
#endif

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

#if USE_SWIFT_CSS_PROPERTY_CONSUMERS_4
void appendLinearEasingStop(const CSSPropertyConsumerSwiftValue& value, const CSSColorSwiftComponents& stop)
{
    std::optional<CSS::LinearEasingParameters::Stop::Length> input;
    if (stop.type(1))
        input = CSS::LinearEasingParameters::Stop::Length { makeColorSwiftComponent<CSS::Percentage<>>(stop.at(1)), optionalSwiftComponent<CSS::Percentage<>>(stop.at(2)) };
    swiftStopsAs<Vector<CSS::LinearEasingParameters::Stop>>(value).append(CSS::LinearEasingParameters::Stop { .output = makeColorSwiftComponent<CSS::Number<>>(stop.at(0)), .input = WTF::move(input) });
}

RefPtr<CSSValue> setEasingFunctionResult(const CSSPropertyConsumerSwiftValue& value, uint16_t consumer, uint16_t function, uint16_t keyword, const CSSColorSwiftComponents& numbers, double count, uint32_t countCalc, CSSImageSwiftParts&& parts)
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
#endif
} // namespace WebCore
