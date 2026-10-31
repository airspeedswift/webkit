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
#include "CSSCalcTree+Simplification.h"

#include "AnchorPositionEvaluator.h"
#include "CSSCalcRandomCachingKey.h"
#include "CSSCalcSymbolTable.h"
#include "CSSCalcTree+Copy.h"
#include "CSSCalcTree+Evaluation.h"
#include "CSSCalcTree+Traversal.h"
#include "CSSCalcTree.h"
#include "CSSNormalizedMixPercentages.h"
#include "CSSPrimitiveNumericCategory.h"
#include "CSSPrimitiveValue.h"
#include "CSSUnevaluatedCalc.h"
#include "StyleBuilderState.h"
#include "StyleComputedStyle+GettersInlines.h"
#include "StyleLengthResolution.h"
#include <wtf/StdLibExtras.h>
#include <wtf/ZippedRange.h>

#include "StylePrimitiveNumericTypes+Conversions.h"
#include "WebCore-Swift.h"
#include <ranges>

namespace WebCore {
namespace CSSCalc {

} // namespace CSSCalc

namespace CSSCalc {

CSSCalcSwiftSimplificationOptions swiftSimplificationOptions(const SimplificationOptions& options)
{
    return { static_cast<uint8_t>(options.category), options.conversionData.has_value(), options.allowZeroValueLengthRemovalFromSum };
}

Tree copyAndSimplify(const Tree& tree, const SimplificationOptions& options)
{
    Tree result { .storage = { .nodes = { }, .payloads = tree.storage.payloads }, .type = tree.type, .stage = tree.stage, .requiresConversionData = tree.requiresConversionData };
    SwiftResolverState resolver { options.conversionData, options.symbolTable, tree.storage };
    SwiftOutputState output { result.storage };
    cssCalcSimplify(tree.storage.nodes.span(), resolver, output, swiftSimplificationOptions(options));
    return result;
}

bool canSimplify(const Tree& tree, const SimplificationOptions&)
{
    auto kind = static_cast<CSSCalcNodeKind>(tree.storage.nodes[0].kind);
    return kind != CSSCalcNodeKind::Number && kind != CSSCalcNodeKind::Percentage && kind != CSSCalcNodeKind::CanonicalDimension;
}

} // namespace CSSCalc

static_assert(isCSSCalcSwiftFacade<CSSCalcSwiftResolver>);

static Style::BuilderState* styleBuilderState(const CSSCalc::SwiftResolverState& state)
{
    return state.conversionData ? state.conversionData->styleBuilderState() : nullptr;
}

static std::optional<Style::ScopedName> anchorName(const CSSCalc::SwiftResolverState& state, uint32_t payload, Style::BuilderState& builderState)
{
    if (payload == UINT32_MAX)
        return std::nullopt;
    return Style::ScopedName { .name = Style::toStyle(std::get<CSS::CustomIdent>(state.storage.payloads[payload]), builderState).value, .scopeOrdinal = builderState.styleScopeOrdinal() };
}

double CSSCalcSwiftResolver::resolveLength(double value, uint16_t unit)
{
    auto& state = static_cast<CSSCalc::SwiftResolverState&>(*this);
    auto lengthUnit = CSS::toLengthUnit(static_cast<CSSUnitType>(unit));
    RELEASE_ASSERT(state.conversionData && lengthUnit);
    return Style::resolveLengthForCalc(value, *lengthUnit, *state.conversionData);
}

double CSSCalcSwiftResolver::resolveStyleLength(double value)
{
    auto& state = static_cast<CSSCalc::SwiftResolverState&>(*this);
    RELEASE_ASSERT(state.conversionData);
    return Style::resolveLength(value, CSS::LengthUnit::Px, *state.conversionData);
}

bool CSSCalcSwiftResolver::hasStyleBuilderState()
{
    return styleBuilderState(static_cast<CSSCalc::SwiftResolverState&>(*this));
}

CSSCalcSwiftSymbolValue CSSCalcSwiftResolver::resolveSymbol(uint16_t valueID)
{
    auto value = static_cast<CSSCalc::SwiftResolverState&>(*this).symbolTable.get(static_cast<CSSValueID>(valueID));
    if (!value)
        return { 0, 0, 0 };
    return { value->value, static_cast<uint16_t>(value->unit), 1 };
}

CSSCalcSwiftNumericResult CSSCalcSwiftResolver::siblingCount()
{
    CheckedPtr builderState = styleBuilderState(static_cast<CSSCalc::SwiftResolverState&>(*this));
    if (!builderState || !builderState->element())
        return { 0, 0 };
    return { static_cast<double>(builderState->siblingCount()), 1 };
}

CSSCalcSwiftNumericResult CSSCalcSwiftResolver::siblingIndex()
{
    CheckedPtr builderState = styleBuilderState(static_cast<CSSCalc::SwiftResolverState&>(*this));
    if (!builderState || !builderState->element())
        return { 0, 0 };
    return { static_cast<double>(builderState->siblingIndex()), 1 };
}

CSSCalcSwiftNumericResult CSSCalcSwiftResolver::resolveAnchor(uint32_t namePayload, uint16_t sideValueID, double sideFraction)
{
    auto& state = static_cast<CSSCalc::SwiftResolverState&>(*this);
    CheckedPtr builderState = styleBuilderState(state);
    RELEASE_ASSERT(builderState);
    auto side = sideValueID ? Style::AnchorPositionEvaluator::Side { static_cast<CSSValueID>(sideValueID) } : Style::AnchorPositionEvaluator::Side { sideFraction };
    auto result = Style::AnchorPositionEvaluator::evaluate(*builderState, anchorName(state, namePayload, *builderState), side);
    return { result.value_or(0), result.has_value() };
}

CSSCalcSwiftNumericResult CSSCalcSwiftResolver::resolveAnchorSize(uint32_t namePayload, uint8_t dimension)
{
    auto& state = static_cast<CSSCalc::SwiftResolverState&>(*this);
    CheckedPtr builderState = styleBuilderState(state);
    RELEASE_ASSERT(builderState && (dimension == UINT8_MAX || dimension <= static_cast<uint8_t>(Style::AnchorSizeDimension::SelfInline)));
    auto anchorDimension = dimension == UINT8_MAX ? std::nullopt : std::optional { static_cast<Style::AnchorSizeDimension>(dimension) };
    auto result = Style::AnchorPositionEvaluator::evaluateSize(*builderState, anchorName(state, namePayload, *builderState), anchorDimension);
    return { result.value_or(0), result.has_value() };
}

CSSCalcSwiftNumericResult CSSCalcSwiftResolver::resolveRandomBaseValue(uint32_t payload)
{
    auto& state = static_cast<CSSCalc::SwiftResolverState&>(*this);
    CheckedPtr builderState = styleBuilderState(state);
    if (!builderState)
        return { 0, 0 };
    auto sharing = WTF::switchOn(state.storage.payloads[payload],
        [](const CSSCalc::RandomSharingAuto& sharing) -> CSSCalc::Random::Sharing { return sharing; },
        [](const CSSCalc::RandomSharingKey& sharing) -> CSSCalc::Random::Sharing { return sharing; },
        [](const CSS::Number<CSS::ClosedUnitRange>& value) -> CSSCalc::Random::Sharing { return CSSCalc::Random::SharingFixed { value }; },
        [](const auto&) -> CSSCalc::Random::Sharing { RELEASE_ASSERT_NOT_REACHED(); });
    auto value = CSSCalc::resolveRandomBaseValue(sharing, *builderState);
    return { value.value_or(0), value.has_value() };
}

CSSCalcSwiftNumericResult CSSCalcSwiftResolver::resolveCalcMixWeight(uint32_t payload)
{
    auto& state = static_cast<CSSCalc::SwiftResolverState&>(*this);
    CheckedPtr builderState = styleBuilderState(state);
    if (!builderState)
        return { 0, 0 };
    return { Style::toStyle(std::get<CSS::Percentage<CSS::ClosedPercentageRange>>(state.storage.payloads[payload]), *builderState).value, 1 };
}

void CSSCalcSwiftResolver::markInvalidAtComputedValueTime()
{
    CheckedPtr builderState = styleBuilderState(static_cast<CSSCalc::SwiftResolverState&>(*this));
    RELEASE_ASSERT(builderState);
    builderState->setCurrentPropertyInvalidAtComputedValueTime();
}

void CSSCalcSwiftResolver::normalizeMixPercentages([[clang::noescape]] std::span<const double> weights, [[clang::noescape]] std::span<const uint8_t> present, [[clang::noescape]] std::span<double> normalized)
{
    RELEASE_ASSERT(present.size() == weights.size() && normalized.size() >= weights.size());
    struct Percentage {
        double value;
    };
    struct Weight {
        std::optional<Percentage> percentage;
    };
    auto result = CSS::normalizedMixPercentages<CSS::ForceNormalization::No>(std::views::iota(size_t { 0 }, weights.size()) | std::views::transform([&](size_t i) {
        return Weight { .percentage = present[i] ? std::optional { Percentage { weights[i] } } : std::nullopt };
    }));
    for (size_t i = 0; i < weights.size(); ++i)
        normalized[i] = result.percentages[i];
}

static_assert(isCSSCalcSwiftFacade<CSSCalcSwiftOutput>);

void CSSCalcSwiftOutput::adopt([[clang::noescape]] std::span<const CSSCalcNodeRecord> nodes)
{
    // Empty, the records hold nothing nodes could view; otherwise they are built before they are replaced.
    auto& records = static_cast<CSSCalc::SwiftOutputState&>(*this).storage.nodes;
    if (records.isEmpty())
        records.append(nodes);
    else
        records = Vector<CSSCalcNodeRecord, 4> { nodes };
}

uint32_t CSSCalcSwiftOutput::appendCalcMixWeight(double weight)
{
    auto& payloads = static_cast<CSSCalc::SwiftOutputState&>(*this).storage.payloads;
    payloads.append(CSS::Percentage<CSS::ClosedPercentageRange> { weight });
    return static_cast<uint32_t>(payloads.size() - 1);
}

uint32_t CSSCalcSwiftOutput::appendRandomFixed(double baseValue)
{
    auto& payloads = static_cast<CSSCalc::SwiftOutputState&>(*this).storage.payloads;
    payloads.append(CSS::Number<CSS::ClosedUnitRange> { baseValue });
    return static_cast<uint32_t>(payloads.size() - 1);
}

} // namespace WebCore
