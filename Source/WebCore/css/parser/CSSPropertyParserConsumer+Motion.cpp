/*
 * Copyright (C) 2016-2023 Apple Inc. All rights reserved.
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
#include "CSSPropertyParserConsumer+Motion.h"

#include "CSSKeywordValueInlines.h"
#include "CSSOffsetRotateValue.h"
#include "CSSParserContext.h"
#include "CSSParserTokenRange.h"
#include "CSSPrimitiveValue.h"
#include "CSSPropertyParserConsumer+AngleDefinitions.h"
#include "CSSPropertyParserConsumer+CSSPrimitiveValueResolver.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+Position.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserConsumer+Shapes.h"
#include "CSSPropertyParserConsumer+URL.h"
#include "CSSPropertyParserState.h"
#include "CSSPropertyParsing.h"
#include "CSSRayValue.h"
#include "CSSValueKeywords.h"
#include "CSSValueList.h"
#include <wtf/SortedArrayMap.h>
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyConsumerSwiftComponents.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

} // namespace CSSPropertyParserHelpers

Ref<CSSValue> makeRayValue(const CSSColorSwiftComponents& ray, const CSSColorSwiftComponents& position, uint16_t positionLayout)
{
    return CSSRayValue::create(CSS::RayFunction { .parameters = CSS::Ray {
        makeColorSwiftComponent<CSS::Angle<>>(ray.at(0)),
        ray.at(1).type ? makeColorSwiftComponent<CSS::RaySize>(ray.at(1)) : CSS::RaySize { CSS::Keyword::ClosestSide { } },
        ray.at(2).type ? std::optional { CSS::Keyword::Contain { } } : std::nullopt,
        positionLayout == CSSImageSwiftNoPosition ? std::nullopt : std::optional { makePositionSwift(position, positionLayout) }
    } });
}
} // namespace WebCore
