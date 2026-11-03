/*
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
#include "CSSPropertyParserConsumer+Image.h"

#include "CSSCalcSymbolTable.h"
#include "CSSCanvasValue.h"
#include "CSSColor.h"
#include "CSSColorImageValue.h"
#include "CSSColorInterpolationMethod.h"
#include "CSSCrossfadeValue.h"
#include "CSSCursorImageValue.h"
#include "CSSFilterImageValue.h"
#include "CSSGradientValue.h"
#include "CSSImageSetOptionValue.h"
#include "CSSImageSetValue.h"
#include "CSSImageValue.h"
#include "CSSLightDarkImageValue.h"
#include "CSSMeshGradientValue.h"
#include "CSSNamedImageValue.h"
#include "CSSPaintImageValue.h"
#include "CSSParserContext.h"
#include "CSSParserTokenRange.h"
#include "CSSPrimitiveNumericTypes.h"
#include "CSSPropertyParserConsumer+AngleDefinitions.h"
#include "CSSPropertyParserConsumer+AnglePercentageDefinitions.h"
#include "CSSPropertyParserConsumer+Background.h"
#include "CSSPropertyParserConsumer+CSSPrimitiveValueResolver.h"
#include "CSSPropertyParserConsumer+Color.h"
#include "CSSPropertyParserConsumer+ColorInterpolationMethod.h"
#include "CSSPropertyParserConsumer+Filter.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+LengthPercentageDefinitions.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+MetaResolver.h"
#include "CSSPropertyParserConsumer+NumberDefinitions.h"
#include "CSSPropertyParserConsumer+Percentage.h"
#include "CSSPropertyParserConsumer+PercentageDefinitions.h"
#include "CSSPropertyParserConsumer+Position.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserConsumer+ResolutionDefinitions.h"
#include "CSSPropertyParserConsumer+Shapes.h"
#include "CSSPropertyParserConsumer+String.h"
#include "CSSPropertyParserConsumer+URL.h"
#include "CSSPropertyParserOptions.h"
#include "CSSPropertyParserState.h"
#include "CSSStringValue.h"
#include "CSSValue.h"
#include "CSSValueList.h"
#include "CSSValuePool.h"
#include "CSSVariableData.h"
#include <wtf/SortedArrayMap.h>
#include "CSSPropertyConsumerSwiftBuilders.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

RefPtr<CSSValue> consumeImage(CSSParserTokenRange& range, CSS::PropertyParserState& state, OptionSet<AllowedImageType> allowedImageTypes)
{
    return consumePropertyWithSwift(range, state, CSSPropertyConsumerSwiftConsumer::Image, allowedImageTypes.toRaw());
}

// MARK: <image> | none

RefPtr<CSSValue> consumeImageOrNone(CSSParserTokenRange& range, CSS::PropertyParserState& state, OptionSet<AllowedImageType> allowedImageTypes)
{
    if (range.peek().id() == CSSValueID::None && allowedImageTypes.contains(AllowedImageType::GeneratedImage))
        return consumeIdent(range);
    return consumeImage(range, state, allowedImageTypes);
}

std::optional<CSS::ImageOrNone> consumeUnresolvedImageOrNone(CSSParserTokenRange& range, CSS::PropertyParserState& state, OptionSet<AllowedImageType> allowedImageTypes)
{
    if (range.peek().id() == CSSValueID::None && allowedImageTypes.contains(AllowedImageType::GeneratedImage)) {
        range.consumeIncludingWhitespace();
        return CSS::ImageOrNone { CSS::Keyword::None { } };
    }
    RefPtr image = consumeImage(range, state, allowedImageTypes);
    if (!image)
        return std::nullopt;
    return CSS::ImageOrNone { CSS::ImageWrapper { image.releaseNonNull() } };
}

} // namespace CSSPropertyParserHelpers
} // namespace WebCore
