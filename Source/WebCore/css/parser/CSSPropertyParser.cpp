// Copyright 2015 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2022 Apple Inc. All rights reserved.
// Copyright (C) 2024-2025 Samuel Weinig <sam@webkit.org>
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#include "config.h"
#include "CSSPropertyParser.h"

#include "CSSCustomIdentValue.h"
#include "CSSCustomPropertySyntax.h"
#include "CSSCustomPropertyValue.h"
#include "CSSKeywordValueInlines.h"
#include "CSSMarkup.h"
#include "CSSParserContext.h"
#include "CSSParserFastPaths.h"
#include "CSSParserIdioms.h"
#include "CSSParserTokenRange.h"
#include "CSSPrimitiveNumericTypes+CSSValueCreation.h"
#include "CSSPrimitiveValue.h"
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyConsumerSwiftComponents.h"
#include "CSSPropertyParserConsumer+AngleDefinitions.h"
#include "CSSPropertyParserConsumer+CSSPrimitiveValueResolver.h"
#include "CSSPropertyParserConsumer+Color.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+Image.h"
#include "CSSPropertyParserConsumer+IntegerDefinitions.h"
#include "CSSPropertyParserConsumer+LengthDefinitions.h"
#include "CSSPropertyParserConsumer+LengthPercentageDefinitions.h"
#include "CSSPropertyParserConsumer+List.h"
#include "CSSPropertyParserConsumer+NumberDefinitions.h"
#include "CSSPropertyParserConsumer+PercentageDefinitions.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserConsumer+ResolutionDefinitions.h"
#include "CSSPropertyParserConsumer+String.h"
#include "CSSPropertyParserConsumer+TimeDefinitions.h"
#include "CSSPropertyParserConsumer+URL.h"
#include "CSSPropertyParserResult.h"
#include "CSSPropertyParserState.h"
#include "CSSPropertyParsing.h"
#include "CSSShorthandSubstitutionValue.h"
#include "CSSStringValue.h"
#include "CSSSubstitutionParser.h"
#include "CSSSubstitutionValue.h"
#include "CSSTokenizer.h"
#include "CSSTransformListValue.h"
#include "CSSURLValue.h"
#include "CSSValueKeywords.h"
#include "CSSValuePair.h"
#include "CSSWideKeyword.h"
#include "ComputedStyleDependencies.h"
#include "StyleBuilder.h"
#include "StyleCustomIdent.h"
#include "StyleCustomProperty.h"
#include "StylePrimitiveNumericTypes+CSSValueConversion.h"
#include "StylePropertyShorthand.h"
#include "StylePropertyShorthandFunctions.h"
#include "StyleRuleType.h"
#include "StyleURL.h"
#include <memory>
#include <wtf/StdLibExtras.h>
#include <wtf/text/ParsingUtilities.h>
#include <wtf/text/StringView.h>

namespace WebCore {

// MARK: - Custom properties

static std::optional<Variant<Ref<const Style::CustomProperty>, CSSWideKeyword>> consumeTypedCustomPropertyValue(CSSParserTokenRange&, CSS::PropertyParserState&, const AtomString& name, const CSSCustomPropertySyntax&, Style::BuilderState&, Style::IsAttrTainted = Style::IsAttrTainted::No);

// MARK: - CSSPropertyID parsing

template<typename CharacterType> static CSSPropertyID cssPropertyID(std::span<const CharacterType> characters)
{
    std::array<char, maxCSSPropertyNameLength> buffer;
    for (size_t i = 0; i != characters.size(); ++i) {
        auto character = characters[i];
        if (!character || !isASCII(character))
            return CSSPropertyID::Invalid;
        buffer[i] = toASCIILower(character);
    }
    return findCSSProperty(buffer.data(), characters.size());
}

CSSPropertyID cssPropertyID(StringView string)
{
    auto length = string.length();
    if (!length)
        return CSSPropertyID::Invalid;
    if (length > maxCSSPropertyNameLength)
        return CSSPropertyID::Invalid;
    return string.is8Bit() ? cssPropertyID(string.span8()) : cssPropertyID(string.span16());
}

// MARK: - CSSValueID parsing

// FIXME: Remove this mechanism entirely once we can do it without breaking the web.
NODELETE static bool isAppleLegacyCSSValueKeyword(std::span<const char> characters)
{
    return spanHasPrefix(characters.subspan(1), "apple-"_span)
        && !spanHasPrefix(characters.subspan(7), "system"_span)
        && !spanHasPrefix(characters.subspan(7), "pay"_span)
        && !spanHasPrefix(characters.subspan(7), "wireless"_span);
}

template<typename CharacterType> static CSSValueID cssValueKeywordID(std::span<const CharacterType> characters)
{
    ASSERT(!characters.empty()); // Otherwise buffer[0] would access uninitialized memory below.

    std::array<char, maxCSSValueKeywordLength + 1> buffer; // 1 to turn "apple" into "webkit"
    
    for (unsigned i = 0; i != characters.size(); ++i) {
        auto character = characters[i];
        if (!character || !isASCII(character))
            return CSSValueID::Invalid;
        buffer[i] = toASCIILower(character);
    }

    // In most cases, if the prefix is -apple-, change it to -webkit-. This makes the string one character longer.
    auto length = characters.size();
    std::span bufferSpan { buffer };
    if (buffer[0] == '-' && isAppleLegacyCSSValueKeyword(bufferSpan.first(length))) {
        memmoveSpan(bufferSpan.subspan(7), bufferSpan.subspan(6, length - 6));
        memcpySpan(bufferSpan.subspan(1), "webkit"_span);
        ++length;
    }

    return findCSSValueKeyword(bufferSpan.first(length));
}

CSSValueID cssValueKeywordID(StringView string)
{
    unsigned length = string.length();
    if (!length)
        return CSSValueID::Invalid;
    if (length > maxCSSValueKeywordLength)
        return CSSValueID::Invalid;
    
    return string.is8Bit() ? cssValueKeywordID(string.span8()) : cssValueKeywordID(string.span16());
}

// MARK: - Custom property name validation

bool isCustomPropertyName(StringView propertyName)
{
    return propertyName.length() > 2 && propertyName.codeUnitAt(0) == '-' && propertyName.codeUnitAt(1) == '-';
}

// MARK: - CSS-wide keyword value consumer

static RefPtr<CSSValue> consumeCSSWideKeywordValue(CSSParserTokenRange& range)
{
    auto rangeCopy = range;
    auto valueID = rangeCopy.consumeIncludingWhitespace().id();
    if (!rangeCopy.atEnd())
        return nullptr;

    if (!isCSSWideKeyword(valueID))
        return nullptr;

    range = rangeCopy;
    return CSSKeywordValue::create(valueID);
}

// MARK: - Parser entry points

using namespace CSSPropertyParserHelpers;

RefPtr<CSSValue> CSSPropertyParser::parseStylePropertyLonghand(CSSPropertyID property, StringView string, const CSSParserContext& context)
{
    ASSERT(!WebCore::isShorthand(property));

    if (string.isEmpty())
        return nullptr;

    auto state = CSS::PropertyParserState {
        .context = context,
        .currentRule = StyleRuleType::Style,
        .currentProperty = property,
        .important = IsImportant::No,
    };
    if (RefPtr value = CSSParserFastPaths::maybeParseValue(property, string, state))
        return value;

    CSSTokenizer tokenizer(string);

    auto range = tokenizer.tokenRange();
    range.consumeWhitespace();

    if (RefPtr value = consumeCSSWideKeywordValue(range))
        return value;

    RefPtr value = CSSPropertyParsing::parseStylePropertyLonghand(range, property, state);
    if (!value || !range.atEnd())
        return nullptr;

    return value;
}

RefPtr<CSSValue> CSSPropertyParser::parseStylePropertyLonghand(CSSPropertyID property, CSSParserTokenRange range, const CSSParserContext& context)
{
    ASSERT(!WebCore::isShorthand(property));

    range.consumeWhitespace();

    if (RefPtr value = consumeCSSWideKeywordValue(range))
        return value;

    auto state = CSS::PropertyParserState {
        .context = context,
        .currentRule = StyleRuleType::Style,
        .currentProperty = property,
        .important = IsImportant::No,
    };

    RefPtr value = CSSPropertyParsing::parseStylePropertyLonghand(range, property, state);
    if (!value || !range.atEnd())
        return nullptr;

    return value;
}

RefPtr<CSSValue> CSSPropertyParser::parseCounterStyleDescriptor(CSSPropertyID property, StringView string, const CSSParserContext& context)
{
    auto tokenizer = CSSTokenizer(string);
    auto range = tokenizer.tokenRange();

    // Handle leading whitespace.
    range.consumeWhitespace();

    auto state = CSS::PropertyParserState {
        .context = context,
        .currentRule = StyleRuleType::CounterStyle,
        .currentProperty = property,
        .important = IsImportant::No,
    };

    auto result = CSSPropertyParsing::parseCounterStyleDescriptor(range, property, state);

    // Handle trailing whitespace.
    range.consumeWhitespace();

    if (!range.atEnd())
        return nullptr;

    return result;
}



// MARK: - Custom properties

std::optional<Variant<Ref<const Style::CustomProperty>, CSSWideKeyword>> CSSPropertyParser::parseTypedCustomPropertyValue(const AtomString& name, const CSSCustomPropertySyntax& syntax, CSSParserTokenRange range, Style::BuilderState& builderState, const CSSParserContext& context, Style::IsAttrTainted isAttrTainted)
{
    auto state = CSS::PropertyParserState {
        .context = context,
        .currentRule = StyleRuleType::Style,
        .currentProperty = CSSPropertyID::Custom,
        .currentCustomPropertyName = name,
        .important = IsImportant::No,
        .randomFunctionsDisallowed = builderState.isResolvingContainerQueries(),
    };

    auto value = consumeTypedCustomPropertyValue(range, state, name, syntax, builderState, isAttrTainted);
    if (!value || !range.atEnd())
        return { };
    return value;
}

RefPtr<const Style::CustomProperty> CSSPropertyParser::parseTypedCustomPropertyInitialValue(const AtomString& name, const CSSCustomPropertySyntax& syntax, CSSParserTokenRange range, Style::BuilderState& builderState, const CSSParserContext& context)
{
    if (syntax.isUniversal())
        return CSSSubstitutionParser::parseInitialValueForUniversalSyntax(name, range);

    auto state = CSS::PropertyParserState {
        .context = context,
        .currentRule = StyleRuleType::Style,
        .currentProperty = CSSPropertyID::Custom,
        .important = IsImportant::No,
        .randomFunctionsDisallowed = true,
    };

    auto value = consumeTypedCustomPropertyValue(range, state, name, syntax, builderState);
    if (!value || !range.atEnd())
        return { };

    return WTF::switchOn(*value,
        [](const Ref<const Style::CustomProperty>& resolved) -> RefPtr<const Style::CustomProperty> {
            return resolved.copyRef();
        },
        [](const CSSWideKeyword&) -> RefPtr<const Style::CustomProperty> {
            return nullptr;
        }
    );
}

ComputedStyleDependencies CSSPropertyParser::collectParsedCustomPropertyValueDependencies(const CSSCustomPropertySyntax& syntax, CSSParserTokenRange range, const CSSParserContext& context)
{
    if (syntax.isUniversal())
        return { };

    range.consumeWhitespace();

    auto state = CSS::PropertyParserState {
        .context = context,
        .currentRule = StyleRuleType::Style,
        .currentProperty = CSSPropertyID::Custom,
        .important = IsImportant::No,
    };

    auto [value, syntaxType] = consumeCustomPropertyValueWithSyntax(range, state, syntax);
    if (!value)
        return { };

    return value->computedStyleDependencies();
}

bool CSSPropertyParser::isValidCustomPropertyValueForSyntax(const CSSCustomPropertySyntax& syntax, CSSParserTokenRange range, const CSSParserContext& context)
{
    if (syntax.isUniversal())
        return true;

    range.consumeWhitespace();

    auto state = CSS::PropertyParserState {
        .context = context,
        .currentRule = StyleRuleType::Style,
        .currentProperty = CSSPropertyID::Custom,
        .important = IsImportant::No,
    };

    return !!consumeCustomPropertyValueWithSyntax(range, state, syntax).first;
}

// https://drafts.csswg.org/css-values-5/#parse-with-a-syntax
RefPtr<CSSValue> CSSPropertyParser::parseWithSyntax(const CSSCustomPropertySyntax& syntax, CSSParserTokenRange range, const CSSParserContext& context)
{
    ASSERT(!syntax.isUniversal());

    range.consumeWhitespace();

    auto state = CSS::PropertyParserState {
        .context = context,
        .currentRule = StyleRuleType::Style,
        .currentProperty = CSSPropertyID::Custom,
        .important = IsImportant::No,
    };

    auto [value, syntaxType] = consumeCustomPropertyValueWithSyntax(range, state, syntax);
    if (!value || !range.atEnd())
        return { };
    return value;
}

std::optional<Variant<Ref<const Style::CustomProperty>, CSSWideKeyword>> consumeTypedCustomPropertyValue(CSSParserTokenRange& range, CSS::PropertyParserState& state, const AtomString& name, const CSSCustomPropertySyntax& syntax, Style::BuilderState& builderState, Style::IsAttrTainted isAttrTainted)
{
    if (syntax.isUniversal()) {
        auto data = CSSVariableData::create(range.consumeAll(), isAttrTainted);
        return { { Style::CustomProperty::createForVariableData(name, WTF::move(data)) } };
    }

    range.consumeWhitespace();

    if (auto keyword = consumeCSSWideKeyword(range))
        return { { *keyword } };

    auto [value, syntaxType] = consumeCustomPropertyValueWithSyntax(range, state, syntax);
    if (!value)
        return { };

    auto resolveSyntaxValue = [&, syntaxType = syntaxType](const CSSValue& value) -> std::optional<Style::CustomProperty::Value> {
        switch (syntaxType) {
        case CSSCustomPropertySyntax::Type::LengthPercentage:
            return Style::toStyleFromCSSValue<Style::LengthPercentage<>>(builderState, downcast<CSSPrimitiveValue>(value));
        case CSSCustomPropertySyntax::Type::Length:
            return Style::toStyleFromCSSValue<Style::Length<>>(builderState, downcast<CSSPrimitiveValue>(value));
        case CSSCustomPropertySyntax::Type::Integer:
        case CSSCustomPropertySyntax::Type::Number:
            return Style::toStyleFromCSSValue<Style::Number<>>(builderState, downcast<CSSPrimitiveValue>(value));
        case CSSCustomPropertySyntax::Type::Percentage:
            return Style::toStyleFromCSSValue<Style::Percentage<>>(builderState, downcast<CSSPrimitiveValue>(value));
        case CSSCustomPropertySyntax::Type::Angle:
            return Style::toStyleFromCSSValue<Style::Angle<>>(builderState, downcast<CSSPrimitiveValue>(value));
        case CSSCustomPropertySyntax::Type::Time:
            return Style::toStyleFromCSSValue<Style::Time<>>(builderState, downcast<CSSPrimitiveValue>(value));
        case CSSCustomPropertySyntax::Type::Resolution:
            return Style::toStyleFromCSSValue<Style::Resolution<>>(builderState, downcast<CSSPrimitiveValue>(value));
        case CSSCustomPropertySyntax::Type::Color:
            return Style::toStyleFromCSSValue<Style::Color>(builderState, value, Style::ForVisitedLink::No);
        case CSSCustomPropertySyntax::Type::Image:
            if (RefPtr styleImage = builderState.createStyleImage(value))
                return Style::ImageWrapper { styleImage.releaseNonNull() };
            return { };
        case CSSCustomPropertySyntax::Type::URL:
            return Style::toStyleFromCSSValue<Style::URL>(builderState, downcast<CSSURLValue>(value));
        case CSSCustomPropertySyntax::Type::Ident:
        case CSSCustomPropertySyntax::Type::CustomIdent:
            return Style::toStyleFromCSSValue<Style::CustomIdent>(builderState, downcast<CSSCustomIdentValue>(value));
        case CSSCustomPropertySyntax::Type::String:
            return Style::toStyleFromCSSValue<Style::String>(builderState, downcast<CSSStringValue>(value));
        case CSSCustomPropertySyntax::Type::TransformFunction:
        case CSSCustomPropertySyntax::Type::TransformList:
            return Style::toStyleFromCSSValue<Style::TransformFunction>(builderState, value);
        case CSSCustomPropertySyntax::Type::Unknown:
            return { };
        }
        ASSERT_NOT_REACHED();
        return { };
    };

    if (is<CSSValueList>(value.get()) || is<CSSTransformListValue>(value.get())) {
        Ref valueList = downcast<CSSValueContainingVector>(value.releaseNonNull());
        auto syntaxValueList = Style::CustomProperty::ValueList { { }, valueList->separator() };
        for (Ref listValue : valueList.get()) {
            auto syntaxValue = resolveSyntaxValue(listValue);
            if (!syntaxValue)
                return { };
            syntaxValueList.values.append(WTF::move(*syntaxValue));
        }
        return { { Style::CustomProperty::createForValueList(name, WTF::move(syntaxValueList), isAttrTainted) } };
    };

    auto syntaxValue = resolveSyntaxValue(*value);
    if (!syntaxValue)
        return { };

    return { { Style::CustomProperty::createForValue(name, WTF::move(*syntaxValue), isAttrTainted) } };
}

// MARK: - C++ called by the Swift root consumers

// The allowed color types of consumeBackgroundShorthand's color in CSSPropertyParserShorthandsBackgroundGrid.swift, and
// of a <color> syntax component in CSSPropertyParserDescriptors.swift.
static_assert(CSSPropertyParserHelpers::CSSColorParsingOptions { }.allowedColorTypes.toRaw() == 0b111);

bool CSSPropertyConsumerSwiftValue::isExposed(uint16_t property) const
{
    return WebCore::isExposed(static_cast<CSSPropertyID>(property), propertyParserState(*this).context.propertySettings);
}

RefPtr<CSSValue> CSSPropertyConsumerSwiftValue::parseWithCxx(uint16_t consumer, bool descriptor, uint32_t start, uint32_t end, uint32_t& consumed) const
{
    auto range = swiftTokenRange(*this, start, end);
    auto size = range.size();
    auto& state = propertyParserState(*this);
    RefPtr<CSSValue> parsed;
    if (descriptor)
        parsed = CSSPropertyParsing::parseDescriptorForSwift(state.currentRule, range, static_cast<CSSPropertyID>(consumer), state);
    else if (consumer < cssPropertyIDEnumValueCount)
        parsed = CSSPropertyParsing::parseStylePropertyLonghand(range, static_cast<CSSPropertyID>(consumer), state);
    else
        parsed = CSSPropertyParsing::consumeRuleForSwift(consumer - cssPropertyIDEnumValueCount, range, state);
    consumed = size - range.size();
    return parsed;
}

static_assert(isCSSCalcSwiftFacade<CSSPropertyConsumerSwiftShorthandSink>);

void CSSPropertyConsumerSwiftShorthandSink::addLonghand(uint16_t longhand, CSSValue* longhandValue, bool implicit) const
{
    state().result.addPropertyForCurrentShorthand(state().value.propertyParserState, static_cast<CSSPropertyID>(longhand), longhandValue, implicit ? IsImplicit::Yes : IsImplicit::No);
}

void CSSPropertyConsumerSwiftShorthandSink::addAllLonghands(uint16_t shorthand, CSSValue* longhandValue, bool implicit) const
{
    auto& parserState = state().value.propertyParserState;
    state().result.addPropertyForAllLonghandsOfShorthand(parserState, static_cast<CSSPropertyID>(shorthand), longhandValue, parserState.important, implicit ? IsImplicit::Yes : IsImplicit::No);
}

void CSSPropertyConsumerSwiftShorthandSink::addProperty(uint16_t property, CSSValue& propertyValue, bool important) const
{
    state().result.addProperty(state().value.propertyParserState, static_cast<CSSPropertyID>(property), CSSPropertyID::Invalid, &propertyValue, important ? IsImportant::Yes : IsImportant::No);
}

bool CSSPropertyConsumerSwiftShorthandSink::addSubstitutionValue(uint32_t start, uint32_t end, bool withNamespaceMap) const
{
    auto& sink = state();
    auto& state = sink.value.propertyParserState;
    auto range = swiftTokenRange(sink.value, start, end);
    if (!CSSSubstitutionParser::containsSubstitutionFunctions(range, state.context))
        return false;
    const CSSNamespacePrefixMap noNamespaceMap;
    Ref substitution = CSSSubstitutionValue::create(range, withNamespaceMap ? sink.namespaceMap : noNamespaceMap, state.context);
    if (WebCore::isShorthand(state.currentProperty))
        sink.result.addPropertyForAllLonghandsOfCurrentShorthand(state, CSSShorthandSubstitutionValue::create(state.currentProperty, WTF::move(substitution)));
    else
        sink.result.addProperty(state, state.currentProperty, CSSPropertyID::Invalid, WTF::move(substitution), state.important);
    return true;
}

bool CSSPropertyConsumerSwiftShorthandSink::isKeywordValid(uint16_t property, uint16_t valueID) const
{
    return CSSPropertyParsing::isKeywordValidForStyleProperty(static_cast<CSSPropertyID>(property), static_cast<CSSValueID>(valueID), state().value.propertyParserState);
}

void addBorderImageLonghandsForSwift(const CSSPropertyConsumerSwiftShorthandSink& shorthandSink, uint8_t options, CSSImageSwiftParts&& parts)
{
    auto& sink = static_cast<const CSSPropertyConsumerSwiftShorthandSinkState&>(shorthandSink);
    auto& state = sink.value.propertyParserState;
    std::optional<CSS::BorderImage> components;
    CSSPropertyConsumerSwiftUnresolvedResult result { components };
    RefPtr<CSSValue> unused;
    CSSPropertyConsumerSwiftValueState value { sink.value.tokens, state, unused, options, *sink.value.gradientStops, &result };
    setBorderResult(value, std::to_underlying(CSSPropertyConsumerSwiftConsumer::BorderImage), WTF::move(parts), std::numeric_limits<uint32_t>::max());
    RELEASE_ASSERT(components);
    auto add = [&](CSSPropertyID longhand, RefPtr<CSSValue>&& longhandValue) {
        sink.result.addPropertyForCurrentShorthand(state, longhand, WTF::move(longhandValue));
    };
    add(CSSPropertyID::BorderImageSource, CSS::tryCreateCSSValue(state.pool, components->borderImageSource));
    add(CSSPropertyID::BorderImageSlice, CSS::tryCreateCSSValue(state.pool, components->borderImageSlice));
    add(CSSPropertyID::BorderImageWidth, CSS::tryCreateCSSValue(state.pool, components->borderImageWidth));
    add(CSSPropertyID::BorderImageOutset, CSS::tryCreateCSSValue(state.pool, components->borderImageOutset));
    add(CSSPropertyID::BorderImageRepeat, CSS::tryCreateCSSValue(state.pool, components->borderImageRepeat));
}

} // namespace WebCore
