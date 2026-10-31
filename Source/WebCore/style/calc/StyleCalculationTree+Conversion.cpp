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
#include "StyleCalculationTree+Conversion.h"

#include "CSSCalcRandomCachingKey.h"
#include "CSSCalcSymbolTable.h"
#include "CSSCalcTree+Evaluation.h"
#include "CSSCalcTree+Simplification.h"
#include "CSSCalcTree+Traversal.h"
#include "CSSCalcTree.h"
#include "CSSPrimitiveNumericCategory.h"
#include "CSSUnevaluatedCalc.h"
#include "StyleBuilderState.h"
#include "StyleCalculationTree.h"
#include "StyleLengthResolution.h"
#include "StylePrimitiveNumericTypes+Conversions.h"
#include <wtf/MathExtras.h>
#include <wtf/StdLibExtras.h>

#include "WebCore-Swift.h"

namespace WebCore {
namespace Style {
namespace Calculation {

// StyleCalculationSwift.swift clamps a calc-mix() weight to this range.
static_assert(!CSS::ClosedPercentageRange.min && CSS::ClosedPercentageRange.max == 100);

CSSCalc::Tree toCSS(const Tree& tree, const ToCSSOptions& toCSSOptions)
{
    CSSCalc::Tree result { .storage = { }, .type = { }, .stage = CSSCalc::Stage::Computed };
    // Each operation is simplified as it is made, with no conversion data and no symbols.
    std::optional<CSSToLengthConversionData> conversionData;
    CSSCalcSymbolTable symbolTable;
    CSSCalc::SwiftResolverState resolver { conversionData, symbolTable, result.storage };
    CSSCalc::SwiftOutputState output { result.storage };
    result.type = std::bit_cast<CSSCalc::Type>(styleCalcToCSS(tree.root.nodes.span(), resolver, output, static_cast<uint8_t>(toCSSOptions.category)));
    return result;
}

Tree toStyle(const CSSCalc::Tree& tree, const ToStyleOptions& toStyleOptions)
{
    ASSERT(toStyleOptions.category == CSS::Category::LengthPercentage || toStyleOptions.category == CSS::Category::AnglePercentage);

    CSSCalc::SwiftResolverState resolver { toStyleOptions.conversionData, toStyleOptions.symbolTable, tree.storage };
    SwiftOutput output;
    styleCalcToStyle(tree.storage.nodes.span(), resolver, output, { static_cast<uint8_t>(toStyleOptions.category), toStyleOptions.conversionData.has_value(), true });
    return Tree { output.take() };
}

} // namespace Calculation
} // namespace Style
} // namespace WebCore
