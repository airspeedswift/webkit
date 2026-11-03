/*
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
#include "CSSPropertyParserConsumer+Position.h"

#include "CSSParserContext.h"
#include "CSSParserTokenRange.h"
#include "CSSParserTokenRangeGuard.h"
#include "CSSPositionValue.h"
#include "CSSPrimitiveValue.h"
#include "CSSPropertyParserConsumer+CSSPrimitiveValueResolver.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+LengthPercentageDefinitions.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserState.h"
#include "CSSValueKeywords.h"
#include "CSSValuePair.h"
#include "CSSValuePool.h"
#include "RenderStyleConstants.h"
#include "CSSPropertyConsumerSwiftBuilders.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

using namespace CSS::Literals;

// MARK: <position>
// https://drafts.csswg.org/css-values/#position

// <position> = <position-one> | <position-two> | <position-four>

// MARK: <bg-position>
// https://drafts.csswg.org/css-backgrounds-3/#propdef-background-position

// background-position has special parsing rules, allowing a 3-value syntax:
//
// <bg-position> = <position-one> | <position-two> | <bg-position-three> | <position-four>

// Sub-productions

// <position-one> = [ left | center | right | top | bottom | x-start | x-end | y-start | y-end | <length-percentage> ]
//
// <position-two> = [
//   [ left | center | right | x-start | x-end ] &&
//   [ top | center | bottom | y-start | y-end ]
// |
//   [ left | center | right | x-start | x-end | <length-percentage> ]
//   [ top | center | bottom | y-start | y-end | <length-percentage> ]
// ]
//
// <bg-position-three> = [
//   [ [        left |  right | x-start | x-end ] <length-percentage> ] &&
//   [ center |  top | bottom | y-start | y-end ]
// |
//   [ center | left |  right | x-start | x-end ] &&
//   [ [         top | bottom | y-start | y-end ] <length-percentage> ]
// ]
//
// <position-four> = [
//   [ [ left | right | x-start | x-end ] <length-percentage> ] &&
//   [ [ top | bottom | y-start | y-end ] <length-percentage> ]
// ]

// MARK: Unresolved Position

std::optional<CSS::Position> consumePositionUnresolved(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::Position>(range, state, CSSPropertyConsumerSwiftConsumer::Position);
}

std::optional<CSS::Position> consumeBackgroundPositionUnresolved(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::Position>(range, state, CSSPropertyConsumerSwiftConsumer::BackgroundPosition);
}

std::optional<CSS::PositionX> consumePositionXUnresolved(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::PositionX>(range, state, CSSPropertyConsumerSwiftConsumer::PositionX);
}

std::optional<CSS::PositionY> consumePositionYUnresolved(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::PositionY>(range, state, CSSPropertyConsumerSwiftConsumer::PositionY);
}

std::optional<CSS::Position> consumeOneOrTwoComponentPositionUnresolved(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::Position>(range, state, CSSPropertyConsumerSwiftConsumer::OneOrTwoComponentPosition);
}

std::optional<CSS::TwoComponentPositionHorizontal> consumeTwoComponentPositionHorizontalUnresolved(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::TwoComponentPositionHorizontal>(range, state, CSSPropertyConsumerSwiftConsumer::TwoComponentPositionHorizontal);
}

std::optional<CSS::TwoComponentPositionVertical> consumeTwoComponentPositionVerticalUnresolved(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::TwoComponentPositionVertical>(range, state, CSSPropertyConsumerSwiftConsumer::TwoComponentPositionVertical);
}

// MARK: CSSValue

RefPtr<CSSValue> consumePosition(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    if (auto position = consumePositionUnresolved(range, state))
        return CSSPositionValue::create(WTF::move(*position));
    return nullptr;
}

RefPtr<CSSValue> consumePositionX(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    if (auto positionX = consumePositionXUnresolved(range, state))
        return CSSPositionXValue::create(WTF::move(*positionX));
    return nullptr;
}

RefPtr<CSSValue> consumePositionY(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    if (auto positionY = consumePositionYUnresolved(range, state))
        return CSSPositionYValue::create(WTF::move(*positionY));
    return nullptr;
}

} // namespace CSSPropertyParserHelpers
} // namespace WebCore
