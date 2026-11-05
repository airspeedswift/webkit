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
#include "CSSPropertyParserConsumer+CalcSize.h"

#include "CSSCalcSizeValue.h"
#include "CSSCalcSymbolsAllowed.h"
#include "CSSCalcTree+Parser.h"
#include "CSSCalcTree+Simplification.h"
#include "CSSCalcValue.h"
#include "CSSParserContext.h"
#include "CSSParserTokenRange.h"
#include "CSSPrimitiveNumericCategory.h"
#include "CSSPrimitiveNumericRange.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserState.h"
#include "CSSUnits.h"
#include "CSSValueKeywords.h"
#include <wtf/UniqueRef.h>
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyConsumerSwiftComponents.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

enum class SizeKeywordPolicy : bool { Forbid, Allow };

// The range is unrestricted even for properties that only accept non-negative sizes, since the
// calculation may go negative internally and is clamped when resolved.
static std::optional<CSS::CalcSizeCalculation> consumeCalcSum(CSSParserTokenRange& args, CSS::PropertyParserState& state, SizeKeywordPolicy sizeKeywordPolicy)
{
    auto parserOptions = CSSCalc::ParserOptions {
        .category = CSS::Category::LengthPercentage,
        .range = CSS::All,
        .allowedSymbols = sizeKeywordPolicy == SizeKeywordPolicy::Allow ? CSSCalcSymbolsAllowed { { CSSValueID::Size, CSSUnitType::Px } } : CSSCalcSymbolsAllowed { },
        .propertyOptions = { }
    };
    auto simplificationOptions = CSSCalc::SimplificationOptions {
        .category = CSS::Category::LengthPercentage,
        .range = CSS::All,
        .conversionData = std::nullopt,
        .symbolTable = { },
        .allowZeroValueLengthRemovalFromSum = false,
    };

    return CSSCalc::parseAndSimplifyCalcSum(args, state, parserOptions, simplificationOptions);
}

} // namespace CSSPropertyParserHelpers

uint16_t currentPropertyForSwift(const CSSPropertyConsumerSwiftValue& value)
{
    return std::to_underlying(propertyParserState(value).currentProperty);
}

CSSCalcSizeSwiftParts::~CSSCalcSizeSwiftParts() = default;

bool consumeCalcSizeSumForSwift(const CSSPropertyConsumerSwiftValue& value, uint32_t start, uint32_t end, bool allowsSize, uint32_t& next)
{
    using namespace CSSPropertyParserHelpers;
    auto range = swiftTokenRange(value, start, end);
    auto tree = consumeCalcSum(range, propertyParserState(value), allowsSize ? SizeKeywordPolicy::Allow : SizeKeywordPolicy::Forbid);
    next = end - range.size();
    if (!tree)
        return false;
    swiftStopsAs<Vector<CSS::CalcSizeCalculation>>(value).append(WTF::move(*tree));
    return true;
}

Ref<CSSValue> makeCalcSizeValue(const CSSPropertyConsumerSwiftValue& value, CSSCalcSizeSwiftParts&& parts)
{
    auto sums = WTF::move(swiftStopsAs<Vector<CSS::CalcSizeCalculation>>(value));
    size_t sumIndex = 0;
    auto nextSum = [&] -> CSS::CalcSizeCalculation { return WTF::move(sums[sumIndex++]); };
    std::optional<CSS::CalcSizeFunction> function;
    for (auto basisID : parts.bases) {
        auto basis = [&] -> CSS::CalcSizeBasis {
            switch (static_cast<CSSValueID>(basisID)) {
            case CSSValueID::Invalid: return nextSum();
            case CSSValueID::CalcSize: return makeUniqueRef<CSS::CalcSizeFunction>(WTF::move(*function));
            case CSSValueID::Any: return CSS::Keyword::Any { };
            case CSSValueID::Auto: return CSS::Keyword::Auto { };
            case CSSValueID::Content: return CSS::Keyword::Content { };
            case CSSValueID::MinContent: return CSS::Keyword::MinContent { };
            case CSSValueID::WebkitMinContent: return CSS::Keyword::WebkitMinContent { };
            case CSSValueID::MaxContent: return CSS::Keyword::MaxContent { };
            case CSSValueID::WebkitMaxContent: return CSS::Keyword::WebkitMaxContent { };
            case CSSValueID::FitContent: return CSS::Keyword::FitContent { };
            case CSSValueID::WebkitFitContent: return CSS::Keyword::WebkitFitContent { };
            case CSSValueID::Stretch: return CSS::Keyword::Stretch { };
            case CSSValueID::WebkitFillAvailable: return CSS::Keyword::WebkitFillAvailable { };
            case CSSValueID::Intrinsic: return CSS::Keyword::Intrinsic { };
            case CSSValueID::MinIntrinsic: return CSS::Keyword::MinIntrinsic { };
            default: RELEASE_ASSERT_NOT_REACHED();
            }
        }();
        function = CSS::CalcSizeFunction { CSS::CalcSizeFunctionValue { .parameters = CSS::CalcSizeParameters { WTF::move(basis), nextSum() } } };
    }
    RELEASE_ASSERT(function && sumIndex == sums.size());
    return CSSCalcSizeValue::create(WTF::move(*function));
}
} // namespace WebCore
