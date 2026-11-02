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
#include "CSSCalcTree+Parser.h"

#include "AnchorPositionEvaluator.h"
#include "CSSCalcOperator.h"
#include "CSSCalcSymbolTable.h"
#include "CSSCalcTree+Serialization.h"
#include "CSSCalcTree+Simplification.h"
#include "CSSCalcTree.h"
#include "CSSParserContext.h"
#include "CSSParserIdioms.h"
#include "CSSParserTokenRange.h"
#include "CSSParserTokenRangeGuard.h"
#include "CSSPrimitiveNumericCategory.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+NumberDefinitions.h"
#include "CSSPropertyParserConsumer+PercentageDefinitions.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserState.h"
#include "CSSPropertyParsing.h"
#include "CSSRandomKeyParser.h"
#include "CSSSerializationContext.h"
#include "CSSUnits.h"
#include "Logging.h"
#include <numbers>
#include <wtf/SortedArrayMap.h>

#include "WebCore-Swift.h"
#include <wtf/ForbidHeapAllocation.h>

namespace WebCore {
namespace CSSCalc {

bool isCalcFunction(CSSValueID functionId)
{
    switch (functionId) {
    case CSSValueID::Calc:
    case CSSValueID::CalcMix:
    case CSSValueID::WebkitCalc:
    case CSSValueID::Min:
    case CSSValueID::Max:
    case CSSValueID::Clamp:
    case CSSValueID::Pow:
    case CSSValueID::Sqrt:
    case CSSValueID::Hypot:
    case CSSValueID::Sin:
    case CSSValueID::Cos:
    case CSSValueID::Tan:
    case CSSValueID::Exp:
    case CSSValueID::Log:
    case CSSValueID::Asin:
    case CSSValueID::Acos:
    case CSSValueID::Atan:
    case CSSValueID::Atan2:
    case CSSValueID::Abs:
    case CSSValueID::Sign:
    case CSSValueID::Round:
    case CSSValueID::Mod:
    case CSSValueID::Rem:
    case CSSValueID::Progress:
    case CSSValueID::Random:
    case CSSValueID::SiblingCount:
    case CSSValueID::SiblingIndex:
    case CSSValueID::Anchor:
    case CSSValueID::AnchorSize:
        return true;
    default:
        return false;
    }
    return false;
}

namespace {

class SwiftParserState final : public CSSCalcSwiftParser {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    SwiftParserState(const CSSParserTokenRange& tokens, CSS::PropertyParserState& propertyParserState, const ParserOptions& options, TreeStorage& storage)
        : tokens(tokens)
        , propertyParserState(propertyParserState)
        , options(options)
        , storage(storage)
    {
    }

    CSSParserTokenRange tokens;
    CSS::PropertyParserState& propertyParserState;
    const ParserOptions& options;
    TreeStorage& storage;
};

} // namespace (anonymous)

// Parses a math function's arguments, or a bare <calc-sum> when function is Invalid, and consumes what the parse
// consumed.
static std::optional<Tree> parseWithSwift(CSSParserTokenRange& tokens, CSSValueID function, CSS::PropertyParserState& propertyParserState, const ParserOptions& parserOptions, const SimplificationOptions& simplificationOptions)
{
    TreeStorage storage;
    SwiftParserState parser { tokens, propertyParserState, parserOptions, storage };
    SwiftResolverState resolver { simplificationOptions.conversionData, simplificationOptions.symbolTable, storage };
    SwiftOutputState output { storage };
    auto& state = propertyParserState;
    auto& propertyOptions = parserOptions.propertyOptions;
    bool inStyleRule = state.currentRule == StyleRuleType::Style || state.currentRule == StyleRuleType::Keyframe;
    uint32_t flags = (propertyOptions.anchorPolicy == AnchorPolicy::Allow ? CSSCalcParseAllowAnchor : 0)
        | (propertyOptions.anchorSizePolicy == AnchorSizePolicy::Allow ? CSSCalcParseAllowAnchorSize : 0)
        | (propertyOptions.unitlessZeroLength == UnitlessZeroQuirk::Allow ? CSSCalcParseAllowUnitlessZeroLength : 0)
        | (state.absoluteLengthUnitsOnly ? CSSCalcParseAbsoluteLengthUnitsOnly : 0)
        | (state.context.cssRandomFunctionEnabled && inStyleRule && state.currentProperty != CSSPropertyID::Invalid && !state.randomFunctionsDisallowed ? CSSCalcParseAllowRandom : 0)
        | (state.context.cssTreeCountingFunctionsEnabled && inStyleRule && (state.currentProperty != CSSPropertyID::Invalid || state.treeCountingFunctionsAllowed) ? CSSCalcParseAllowTreeCounting : 0)
        | (state.context.cssCalcMixEnabled ? CSSCalcParseAllowCalcMix : 0);
    auto result = cssCalcParse(parser, resolver, output, static_cast<uint8_t>(parserOptions.category), static_cast<uint16_t>(function), flags, swiftSimplificationOptions(simplificationOptions));
    RELEASE_ASSERT(result.consumedTokens <= tokens.size());
    tokens = tokens.span().subspan(result.consumedTokens);
    auto type = std::bit_cast<Type>(result.typeBits);
    if (!result.ok || !type.matches(parserOptions.category))
        return std::nullopt;
    return Tree { .storage = WTF::move(storage), .type = type, .stage = Stage::Specified, .requiresConversionData = !!result.requiresConversionData };
}

std::optional<Tree> parseAndSimplify(CSSParserTokenRange& range, CSS::PropertyParserState& propertyParserState, const ParserOptions& parserOptions, const SimplificationOptions& simplificationOptions)
{
    auto function = range.peek().functionId();
    if (!isCalcFunction(function))
        return std::nullopt;
    auto tokens = CSSPropertyParserHelpers::consumeFunction(range);
    auto tree = parseWithSwift(tokens, function, propertyParserState, parserOptions, simplificationOptions);
    if (!tokens.atEnd())
        return std::nullopt;
    return tree;
}

std::optional<Tree> parseAndSimplifyCalcSum(CSSParserTokenRange& tokens, CSS::PropertyParserState& propertyParserState, const ParserOptions& parserOptions, const SimplificationOptions& simplificationOptions)
{
    return parseWithSwift(tokens, CSSValueID::Invalid, propertyParserState, parserOptions, simplificationOptions);
}

} // namespace CSSCalc

static_assert(isCSSCalcSwiftFacade<CSSCalcSwiftParser>);

// CSSCalcParser.swift's e.
static_assert(std::numbers::e == 2.718281828459045235360287471352662);

uint32_t CSSCalcSwiftParser::tokenCount()
{
    return static_cast<uint32_t>(static_cast<CSSCalc::SwiftParserState&>(*this).tokens.size());
}

void CSSCalcSwiftParser::fillTokens([[clang::noescape]] std::span<CSSCalcSwiftToken> out)
{
    auto tokens = static_cast<CSSCalc::SwiftParserState&>(*this).tokens.span();
    RELEASE_ASSERT(out.size() >= tokens.size());
    for (size_t i = 0; i < tokens.size(); ++i) {
        auto& token = tokens[i];
        auto type = token.type();
        bool numeric = type == NumberToken || type == PercentageToken || type == DimensionToken;
        uint16_t id = 0;
        if (type == IdentToken)
            id = static_cast<uint16_t>(token.id());
        else if (type == FunctionToken)
            id = static_cast<uint16_t>(token.functionId());
        else if (type == DelimiterToken)
            id = token.delimiter();
        out[i] = { static_cast<uint8_t>(type), static_cast<uint8_t>(token.getBlockType()), id, static_cast<uint32_t>(token.unitType()), numeric ? token.numericValue() : 0 };
    }
}

int32_t CSSCalcSwiftParser::allowedSymbolUnit(uint16_t valueID)
{
    auto unit = static_cast<CSSCalc::SwiftParserState&>(*this).options.allowedSymbols.get(static_cast<CSSValueID>(valueID));
    return unit ? static_cast<int32_t>(*unit) : -1;
}

template<typename Consume> static CSSCalcSwiftConsumed consumePayload(CSSCalc::SwiftParserState& state, uint32_t index, const Consume& consume)
{
    RELEASE_ASSERT(index <= state.tokens.size());
    CSSParserTokenRange range { state.tokens.span().subspan(index) };
    auto payload = consume(range);
    auto next = static_cast<uint32_t>(state.tokens.size() - range.size());
    if (!payload)
        return { UINT32_MAX, next };
    state.storage.payloads.append(WTF::move(*payload));
    return { static_cast<uint32_t>(state.storage.payloads.size() - 1), next };
}

CSSCalcSwiftConsumed CSSCalcSwiftParser::consumeRandomSharing(uint32_t index)
{
    auto& state = static_cast<CSSCalc::SwiftParserState&>(*this);
    auto& parserState = state.propertyParserState;
    auto keySource = CSSPropertyParserHelpers::RandomKeySource {
        .property = { parserState.currentProperty, parserState.currentCustomPropertyName, CSSCalc::RandomFunction::Random },
        .autoElementScoped = CSS::Keyword::ElementScoped { }
    };
    auto result = consumePayload(state, index, [&](CSSParserTokenRange& range) -> std::optional<CSSCalc::Payload> {
        auto sharing = CSSPropertyParserHelpers::consumeUnresolvedRandomKey(range, parserState, keySource, [&] {
            return parserState.cssRandomFunctionCount;
        });
        if (!sharing)
            return CSSPropertyParserHelpers::randomSharingAuto(keySource, parserState.cssRandomFunctionCount);
        return WTF::switchOn(*sharing,
            [](const CSSCalc::Random::SharingFixed& fixed) -> CSSCalc::Payload { return fixed.value; },
            [](const auto& sharing) -> CSSCalc::Payload { return sharing; });
    });
    return result;
}

void CSSCalcSwiftParser::countRandomFunction()
{
    ++static_cast<CSSCalc::SwiftParserState&>(*this).propertyParserState.cssRandomFunctionCount;
}

CSSCalcSwiftConsumed CSSCalcSwiftParser::consumeDashedIdent(uint32_t index)
{
    auto& state = static_cast<CSSCalc::SwiftParserState&>(*this);
    return consumePayload(state, index, [&](CSSParserTokenRange& range) -> std::optional<CSSCalc::Payload> {
        if (auto ident = CSSPropertyParserHelpers::consumeUnresolvedDashedIdent(range, state.propertyParserState))
            return CSSCalc::Payload { WTF::move(*ident) };
        return std::nullopt;
    });
}

CSSCalcSwiftConsumed CSSCalcSwiftParser::consumeCalcMixWeight(uint32_t index)
{
    auto& state = static_cast<CSSCalc::SwiftParserState&>(*this);
    return consumePayload(state, index, [&](CSSParserTokenRange& range) -> std::optional<CSSCalc::Payload> {
        if (auto weight = CSSPropertyParserHelpers::MetaConsumer<CSSCalc::CalcMix::Item::Weight>::consume(range, state.propertyParserState))
            return CSSCalc::Payload { WTF::move(*weight) };
        return std::nullopt;
    });
}

static_assert(isCSSCalcSwiftFacade<CSSPropertyConsumerSwiftValue>);

// lengthUnit's masks in CSSPropertyConsumerSwift.swift are CSS::toLengthUnit's units, and one that does not map back to
// itself sets every bit, matching no mask.
static_assert([] {
    std::array<uint64_t, 2> length { }, absolute { };
    for (unsigned unit = 0; unit < 128; ++unit) {
        if (auto lengthUnit = CSS::toLengthUnit(static_cast<CSSUnitType>(unit))) {
            length[unit / 64] |= CSS::toCSSUnitType(*lengthUnit) == static_cast<CSSUnitType>(unit) ? uint64_t { 1 } << (unit % 64) : ~uint64_t { 0 };
            absolute[unit / 64] |= uint64_t { !CSS::conversionToCanonicalUnitRequiresConversionData(*lengthUnit) } << (unit % 64);
        }
    }
    return length[0] == 0xfdc1'ffff'fff8'0ff0 && length[1] == 0x23 && absolute[0] == 0x40'0000'0000'0fc0 && !absolute[1];
}());
// cssConsumeNumericSwift names each LengthUnit.
static_assert(CSS::UnitTraits<CSS::LengthUnit>::count == 50);

void CSSPropertyConsumerSwiftValue::setResult(CSSValue& value) const
{
    static_cast<const CSSPropertyConsumerSwiftValueState&>(*this).result = &value;
}

// cssConsumeProperty's consumer on range, which it advances past what the consumer consumed.
RefPtr<CSSValue> consumePropertyWithSwift(CSSParserTokenRange& range, CSS::PropertyParserState& state, uint16_t consumer)
{
    RefPtr<CSSValue> result;
    CSSPropertyConsumerSwiftValueState value { range.span(), state, result };
    auto mode = state.context.mode;
    uint8_t numericFlags = (state.absoluteLengthUnitsOnly ? CSSNumericConsumerSwiftAbsoluteLengthUnitsOnly : 0)
        | (mode == HTMLQuirksMode && CSSProperty::acceptsQuirkyLength(state.currentProperty) ? CSSNumericConsumerSwiftQuirkyLength : 0)
        | (mode == HTMLQuirksMode && CSSProperty::acceptsQuirkyAngle(state.currentProperty) ? CSSNumericConsumerSwiftQuirkyAngle : 0);
    auto consumed = cssConsumeProperty(value, consumer, static_cast<uint8_t>(mode), numericFlags);
    RELEASE_ASSERT(consumed.consumedTokens <= range.size());
    range = range.span().subspan(consumed.consumedTokens);
    if (!consumed.ok)
        return nullptr;
    return result;
}

} // namespace WebCore

#include "CSSCalcValue.h"

// UnevaluatedCalcBase::parseBase on the arguments: no conversion data, no symbols.
auto WebCore::CSSPropertyConsumerSwiftValue::parseCalc(uint32_t argumentsStart, uint32_t argumentsEnd, uint16_t function, uint8_t category, uint32_t flags, double rangeMin, double rangeMax) const -> RefPtr<CSSPrimitiveValue>
{
    auto& value = static_cast<const CSSPropertyConsumerSwiftValueState&>(*this);
    RELEASE_ASSERT(argumentsStart <= argumentsEnd && argumentsEnd <= value.tokens.size());
    auto& state = value.propertyParserState;
    CSSCalc::TreeStorage storage;
    CSSCalc::ParserOptions options { .category = CSS::Category::Number, .range = CSS::All, .allowedSymbols = { }, .propertyOptions = { } };
    CSSCalc::SwiftParserState parser { CSSParserTokenRange { value.tokens.subspan(argumentsStart, argumentsEnd - argumentsStart) }, state, options, storage };
    std::optional<CSSToLengthConversionData> conversionData;
    CSSCalcSymbolTable symbolTable;
    CSSCalc::SwiftResolverState resolver { conversionData, symbolTable, storage };
    CSSCalc::SwiftOutputState calcOutput { storage };
    bool inStyleRule = state.currentRule == StyleRuleType::Style || state.currentRule == StyleRuleType::Keyframe;
    flags |= (state.absoluteLengthUnitsOnly ? CSSCalcParseAbsoluteLengthUnitsOnly : 0)
        | (state.context.cssRandomFunctionEnabled && inStyleRule && state.currentProperty != CSSPropertyID::Invalid && !state.randomFunctionsDisallowed ? CSSCalcParseAllowRandom : 0)
        | (state.context.cssTreeCountingFunctionsEnabled && inStyleRule && (state.currentProperty != CSSPropertyID::Invalid || state.treeCountingFunctionsAllowed) ? CSSCalcParseAllowTreeCounting : 0)
        | (state.context.cssCalcMixEnabled ? CSSCalcParseAllowCalcMix : 0);
    auto parsed = cssConsumePropertyCalc(*this, parser, resolver, calcOutput, argumentsStart, argumentsEnd, function, category, flags);
    if (!parsed.ok || parsed.consumedTokens != argumentsEnd - argumentsStart)
        return nullptr;
    RELEASE_ASSERT(!storage.nodes.isEmpty());
    auto type = std::bit_cast<CSSCalc::Type>(parsed.typeBits);
    RELEASE_ASSERT(category <= std::to_underlying(CSS::Category::AnglePercentage) && type.matches(static_cast<CSS::Category>(category)));
    auto tree = CSSCalc::Tree { .storage = WTF::move(storage), .type = type, .stage = CSSCalc::Stage::Specified, .requiresConversionData = !!parsed.requiresConversionData };
    return CSSPrimitiveValue::create(CSS::UnevaluatedCalcBase { CSSCalc::Value::create(static_cast<CSS::Category>(category), CSS::Range { rangeMin, rangeMax }, WTF::move(tree)) });
}

#include <wtf/NeverDestroyed.h>

// consumePropertyWithSwift for a generated consumer that takes no state, one that consumes only keywords and strings.
// cssConsumeStatelessProperty reads none of the state, so every call shares one.
RefPtr<WebCore::CSSValue> WebCore::consumePropertyWithSwift(CSSParserTokenRange& range, uint16_t consumer)
{
    static NeverDestroyed<CSS::PropertyParserState> state { CSS::PropertyParserState { .context = strictCSSParserContext() } };
    RefPtr<CSSValue> result;
    CSSPropertyConsumerSwiftValueState value { range.span(), state.get(), result };
    auto consumed = cssConsumeStatelessProperty(value, consumer);
    RELEASE_ASSERT(consumed.consumedTokens <= range.size());
    if (consumed.consumedTokens)
        range = range.span().subspan(consumed.consumedTokens);
    return consumed.ok ? WTF::move(result) : nullptr;
}

#include "CSSCustomIdentValue.h"
#include "CSSStringValue.h"

// cssConsumeNumericSwift converts a time in milliseconds to seconds with this factor.
static_assert(WebCore::CSS::secondsPerMillisecond == 1.0 / 1000.0);

auto WebCore::CSSPropertyConsumerSwiftValue::tokenValue(size_t index) const -> Ref<CSSValue>
{
    if (type(index) == IdentToken)
        return CSSCustomIdentValue::create(CSS::CustomIdent { token(index).value().toAtomString() });
    RELEASE_ASSERT(type(index) == StringToken);
    return CSSStringValue::create(CSS::String { token(index).value().toString() });
}
