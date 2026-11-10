// Copyright 2014 The Chromium Authors. All rights reserved.
// Copyright (C) 2016-2022 Apple Inc. All rights reserved.
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
#include "CSSParserFastPaths.h"

#include "CSSAbsoluteColorResolver.h"
#include "CSSFunctionValue.h"
#include "CSSKeywordColor.h"
#include "CSSParserContext.h"
#include "CSSParserIdioms.h"
#include "CSSPrimitiveNumericTypes.h"
#include "CSSPrimitiveValue.h"
#include "CSSProperty.h"
#include "CSSPropertyNames.h"
#include "CSSPropertyParser.h"
#include "CSSPropertyParserConsumer+Color.h"
#include "CSSPropertyParserState.h"
#include "CSSPropertyParsing.h"
#include "CSSTransformListValue.h"
#include "CSSValueList.h"
#include "CSSValuePool.h"
#include "ColorConversion.h"
#include "FloatConversion.h"
#include "HashTools.h"
#include "StylePropertyShorthand.h"
#include <wtf/text/ParsingUtilities.h>
#include <wtf/text/StringParsingBuffer.h>

#include "WebCore-Swift.h"

namespace WebCore {

std::optional<CSS::Range> CSSParserFastPaths::lengthValueRangeForPropertiesSupportingSimpleLengths(CSSPropertyID propertyId)
{
    switch (propertyId) {
    case CSSPropertyID::FontSize:
    case CSSPropertyID::Height:
    case CSSPropertyID::Width:
    case CSSPropertyID::MinHeight:
    case CSSPropertyID::MinWidth:
    case CSSPropertyID::PaddingBottom:
    case CSSPropertyID::PaddingLeft:
    case CSSPropertyID::PaddingRight:
    case CSSPropertyID::PaddingTop:
    case CSSPropertyID::InlineSize:
    case CSSPropertyID::BlockSize:
    case CSSPropertyID::MinInlineSize:
    case CSSPropertyID::MinBlockSize:
    case CSSPropertyID::PaddingBlockEnd:
    case CSSPropertyID::PaddingBlockStart:
    case CSSPropertyID::PaddingInlineEnd:
    case CSSPropertyID::PaddingInlineStart:
    case CSSPropertyID::R:
    case CSSPropertyID::Rx:
    case CSSPropertyID::Ry:
    case CSSPropertyID::ShapeMargin:
        return CSS::Nonnegative;
    case CSSPropertyID::Bottom:
    case CSSPropertyID::Cx:
    case CSSPropertyID::Cy:
    case CSSPropertyID::Left:
    case CSSPropertyID::InsetBlockEnd:
    case CSSPropertyID::InsetBlockStart:
    case CSSPropertyID::InsetInlineEnd:
    case CSSPropertyID::InsetInlineStart:
    case CSSPropertyID::MarginBottom:
    case CSSPropertyID::MarginLeft:
    case CSSPropertyID::MarginRight:
    case CSSPropertyID::MarginTop:
    case CSSPropertyID::Right:
    case CSSPropertyID::Top:
    case CSSPropertyID::MarginBlockEnd:
    case CSSPropertyID::MarginBlockStart:
    case CSSPropertyID::MarginInlineEnd:
    case CSSPropertyID::MarginInlineStart:
    case CSSPropertyID::X:
    case CSSPropertyID::Y:
        return CSS::All;
    default:
        return { };
    }
}

template<typename CharacterType> static CSSFastPathNumber parseNumberForSwift(std::span<const CharacterType> characters)
{
    bool ok;
    double number = charactersToDouble(characters, &ok);
    return { number, CSSUnitType::Number, ok };
}

CSSFastPathNumber cssFastPathParseNumber8([[clang::noescape]] std::span<const uint8_t> characters)
{
    return parseNumberForSwift(byteCast<Latin1Character>(characters));
}

CSSFastPathNumber cssFastPathParseNumber16([[clang::noescape]] std::span<const char16_t> characters)
{
    return parseNumberForSwift(characters);
}

static RefPtr<CSSValue> parseSimpleLengthValue(StringView string, CSSParserMode cssParserMode, CSS::Range valueRange)
{
    ASSERT(!string.isEmpty());

    bool svgAttributeMode = cssParserMode == SVGAttributeMode;
    auto result = string.is8Bit() ? cssFastPathLength8(byteCast<uint8_t>(string.span8()), svgAttributeMode, valueRange.min, valueRange.max) : cssFastPathLength16(string.span16(), svgAttributeMode, valueRange.min, valueRange.max);
    if (!result.ok)
        return nullptr;
    return CSSPrimitiveValue::create(result.value, result.unit);
}

// CSSParserFastPathsSwift.swift converts an hsl() hue in radians to degrees with this value.
static_assert(degreesPerRadianDouble == 180.0 / std::numbers::pi);

// A color CSSParserFastPathsSwift.swift returns: a PackedColor::ARGB, or -1 for none.
static std::optional<SRGBA<uint8_t>> colorFromSwift(int64_t color)
{
    if (color < 0)
        return std::nullopt;
    return asSRGBA(PackedColor::ARGB { static_cast<uint32_t>(color) });
}

static std::optional<SRGBA<uint8_t>> parseNumericColor(StringView string, const CSSParserContext& context)
{
    bool quirksMode = isQuirksModeBehavior(context.mode);
    return colorFromSwift(string.is8Bit() ? cssFastPathNumericColor8(byteCast<uint8_t>(string.span8()), quirksMode) : cssFastPathNumericColor16(string.span16(), quirksMode));
}

static RefPtr<CSSValue> parseColor(StringView string, const CSSParserContext& context)
{
    ASSERT(!string.isEmpty());
    auto valueID = cssValueKeywordID(string);
    if (CSS::isColorKeyword(valueID)) {
        if (!CSSPropertyParserHelpers::isColorKeywordAllowed(valueID, context))
            return nullptr;
        return CSSKeywordValue::create(valueID);
    }
    if (auto color = parseNumericColor(string, context))
        return CSSValuePool::singleton().createColorValue(*color);
    return nullptr;
}

int64_t cssFastPathFindNamedColor([[clang::noescape]] std::span<const uint8_t> name)
{
    auto* namedColor = findColor(byteCast<char>(name.data()), static_cast<unsigned>(name.size()));
    return namedColor ? static_cast<int64_t>(namedColor->ARGBValue) : -1;
}

std::optional<SRGBA<uint8_t>> CSSParserFastPaths::parseSimpleColor(StringView string, const CSSParserContext& context)
{
    bool quirksMode = isQuirksModeBehavior(context.mode);
    return colorFromSwift(string.is8Bit() ? cssFastPathSimpleColor8(byteCast<uint8_t>(string.span8()), quirksMode) : cssFastPathSimpleColor16(string.span16(), quirksMode));
}

std::optional<SRGBA<uint8_t>> CSSParserFastPaths::parseHexColor(StringView string)
{
    return colorFromSwift(string.is8Bit() ? cssFastPathHexColor8(byteCast<uint8_t>(string.span8())) : cssFastPathHexColor16(string.span16()));
}

std::optional<SRGBA<uint8_t>> CSSParserFastPaths::parseNamedColor(StringView string)
{
    return colorFromSwift(string.is8Bit() ? cssFastPathNamedColor8(byteCast<uint8_t>(string.span8())) : cssFastPathNamedColor16(string.span16()));
}

static bool isUniversalKeyword(StringView string)
{
    // These keywords can be used for all properties.
    return equalLettersIgnoringASCIICase(string, "initial"_s)
        || equalLettersIgnoringASCIICase(string, "inherit"_s)
        || equalLettersIgnoringASCIICase(string, "unset"_s)
        || equalLettersIgnoringASCIICase(string, "revert"_s)
        || equalLettersIgnoringASCIICase(string, "revert-layer"_s)
        || equalLettersIgnoringASCIICase(string, "revert-rule"_s);
}

static RefPtr<CSSValue> parseKeywordValue(CSSPropertyID property, StringView string, CSS::PropertyParserState& state)
{
    ASSERT(!string.isEmpty());

    if (!CSSPropertyParsing::isKeywordFastPathEligibleStyleProperty(property)) {
        // All properties, including non-keyword properties, accept the CSS-wide keywords.
        if (!isUniversalKeyword(string))
            return nullptr;

        // Leave shorthands to parse CSS-wide keywords using CSSPropertyParser.
        if (shorthandForProperty(property).length())
            return nullptr;
    }

    auto valueID = cssValueKeywordID(string);
    if (valueID == CSSValueID::Invalid)
        return nullptr;

    if (isCSSWideKeyword(valueID))
        return CSSKeywordValue::create(valueID);

    if (CSSPropertyParsing::isKeywordValidForStyleProperty(property, valueID, state))
        return CSSKeywordValue::create(valueID);
    return nullptr;
}

// Swift moves a noncopyable C++ type with its move constructor only when its destructor is not trivial; m_functions'
// inline buffer needs that.
static_assert(!std::is_trivially_destructible_v<CSSFastPathTransformSink>);

void CSSFastPathTransformSink::append(uint16_t name, [[clang::noescape]] std::span<const double> values, [[clang::noescape]] std::span<const uint8_t> units)
{
    RELEASE_ASSERT(values.size() == units.size());
    CSSValueListBuilder arguments;
    for (size_t i = 0; i < values.size(); ++i)
        [[clang::always_inline]] arguments.append(CSSPrimitiveValue::create(values[i], static_cast<CSSUnitType>(units[i])));
    m_functions.append(CSSFunctionValue::create(static_cast<CSSValueID>(name), WTF::move(arguments)));
}

static RefPtr<CSSValue> parseSimpleTransform(StringView string)
{
    ASSERT(!string.isEmpty());
    CSSFastPathTransformSink sink;
    if (!(string.is8Bit() ? cssFastPathTransform8(byteCast<uint8_t>(string.span8()), sink) : cssFastPathTransform16(string.span16(), sink)))
        return nullptr;
    return CSSTransformListValue::create(sink.takeFunctions());
}

static RefPtr<CSSValue> parseDisplay(StringView string)
{
    ASSERT(!string.isEmpty());
    auto valueID = cssValueKeywordID(string);

    switch (valueID) {
    case CSSValueID::None:
    // <display-outside>
    case CSSValueID::Block:
    case CSSValueID::Inline:
    // <display-inside> (except for CSSValueID::Flow since it becomes "block")
    case CSSValueID::Flex:
    case CSSValueID::FlowRoot:
    case CSSValueID::Grid:
    case CSSValueID::Table:
    // <display-internal>
    case CSSValueID::TableCaption:
    case CSSValueID::TableCell:
    case CSSValueID::TableColumnGroup:
    case CSSValueID::TableColumn:
    case CSSValueID::TableHeaderGroup:
    case CSSValueID::TableFooterGroup:
    case CSSValueID::TableRow:
    case CSSValueID::TableRowGroup:
    // <display-legacy>
    case CSSValueID::InlineBlock:
    case CSSValueID::InlineFlex:
    case CSSValueID::InlineGrid:
    case CSSValueID::InlineTable:
    // Prefixed values
    case CSSValueID::WebkitInlineBox:
    case CSSValueID::WebkitBox:
    // No layout support for the full <display-listitem> syntax, so treat it as <display-legacy>
    case CSSValueID::ListItem:
        return CSSKeywordValue::create(valueID);
    default:
        if (isCSSWideKeyword(valueID))
            return CSSKeywordValue::create(valueID);
        return nullptr;
    }
}

static RefPtr<CSSValue> parseOpacity(StringView string)
{
    auto result = string.is8Bit() ? cssFastPathOpacity8(byteCast<uint8_t>(string.span8())) : cssFastPathOpacity16(string.span16());
    if (!result.ok)
        return nullptr;
    double number = result.value;

    return CSSPrimitiveValue::create(number, CSSUnitType::Number);
}

static RefPtr<CSSValue> parseColorWithAuto(StringView string, const CSSParserContext& context)
{
    ASSERT(!string.isEmpty());
    if (cssValueKeywordID(string) == CSSValueID::Auto)
        return CSSKeywordValue::create(CSSValueID::Auto);
    return parseColor(string, context);
}

RefPtr<CSSValue> CSSParserFastPaths::maybeParseValue(CSSPropertyID property, StringView string, CSS::PropertyParserState& state)
{
    // Some at-rules like @keyframes, @position-try restrict which properties
    // are allowed inside the rule. Fallback to slow path for at-rules since
    // the restriction logic is in the slow-path parser (CSSPropertyParser).
    if (state.currentRule != StyleRuleType::Style)
        return nullptr;

    switch (property) {
    case CSSPropertyID::Display:
        return parseDisplay(string);
    case CSSPropertyID::Opacity:
        return parseOpacity(string);
    case CSSPropertyID::Transform:
        return parseSimpleTransform(string);
    case CSSPropertyID::CaretColor:
    case CSSPropertyID::AccentColor:
        if (isExposed(property, &state.context.propertySettings))
            return parseColorWithAuto(string, state.context);
        break;
    default:
        break;
    }

    if (CSSProperty::isColorProperty(property)) {
        auto context = state.context;
        if (!CSSProperty::acceptsQuirkyColor(property))
            context.mode = HTMLStandardMode;
        return parseColor(string, context);
    }

    if (auto valueRange = lengthValueRangeForPropertiesSupportingSimpleLengths(property)) {
        if (auto result = parseSimpleLengthValue(string, state.context.mode, *valueRange))
            return result;
    }

    return parseKeywordValue(property, string, state);
}

} // namespace WebCore
