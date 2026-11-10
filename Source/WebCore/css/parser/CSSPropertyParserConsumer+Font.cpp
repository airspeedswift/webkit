/*
 * Copyright (C) 2016 The Chromium Authors. All rights reserved
 * Copyright (C) 2021 Metrological Group B.V.
 * Copyright (C) 2021 Igalia S.L.
 * Copyright (C) 2023-2024 Apple Inc. All rights reserved.
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
#include "CSSPropertyParserConsumer+Font.h"

#include "CSSCalcSymbolTable.h"
#include "CSSColorInterpolationMethod.h"
#include "CSSFontFaceSrcValue.h"
#include "CSSFontFeatureValue.h"
#include "CSSFontPaletteMix.h"
#include "CSSFontPaletteValue.h"
#include "CSSFontStyleWithAngleValue.h"
#include "CSSFontVariantLigaturesParser.h"
#include "CSSFontVariantNumericParser.h"
#include "CSSParser.h"
#include "CSSParserIdioms.h"
#include "CSSParserToken.h"
#include "CSSParserTokenRange.h"
#include "CSSPrimitiveValue.h"
#include "CSSPropertyParserConsumer+AngleDefinitions.h"
#include "CSSPropertyParserConsumer+CSSPrimitiveValueResolver.h"
#include "CSSPropertyParserConsumer+Color.h"
#include "CSSPropertyParserConsumer+ColorInterpolationMethod.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+IntegerDefinitions.h"
#include "CSSPropertyParserConsumer+KeywordDefinitions.h"
#include "CSSPropertyParserConsumer+LengthPercentageDefinitions.h"
#include "CSSPropertyParserConsumer+List.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+NumberDefinitions.h"
#include "CSSPropertyParserConsumer+PercentageDefinitions.h"
#include "CSSPropertyParserConsumer+URL.h"
#include "CSSPropertyParserOptions.h"
#include "CSSPropertyParserState.h"
#include "CSSPropertyParsing.h"
#include "CSSUnicodeRangeValue.h"
#include "CSSValuePair.h"
#include "Document.h"
#include "FontCustomPlatformData.h"
#include "FontFace.h"
#include "StyleKeyword+Mappings.h"
#include "WebKitFontFamilyNames.h"
#include <wtf/Function.h>
#include <wtf/text/ParsingUtilities.h>

#if ENABLE(VARIATION_FONTS)
#include "CSSFontStyleRangeValue.h"
#include "CSSFontVariationValue.h"
#endif
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyConsumerSwiftComponents.h"
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/StringBuilder.h>

namespace WebCore {
namespace CSSPropertyParserHelpers {

NODELETE static CSSParserMode parserMode(ScriptExecutionContext& context)
{
    auto* document = dynamicDowncast<Document>(context);
    return (document && document->inQuirksMode()) ? HTMLQuirksMode : HTMLStandardMode;
}

// MARK: - 'font-width'

// MARK: - 'font-weight'

// MARK: - 'font-style'

#if !ENABLE(VARIATION_FONTS)
#error "The Swift font consumers consume the grammar of ENABLE(VARIATION_FONTS)"
#endif

// The ranges of the oblique angle and the palette-mix() percentages Swift consumes, and the length of a tag.
static_assert(std::same_as<CSSFontStyleWithAngleValue::ObliqueAngle, UnresolvedFontStyleObliqueAngle> && UnresolvedFontStyleObliqueAngle::range == CSS::Range { -90, 90 });
static_assert(CSS::FontPaletteMixParameters::Component::Percentage::range == CSS::Range { 0, 100 } && std::tuple_size_v<FontTag> == 4);

// MARK: - 'font-family'

const AtomString& genericFontFamily(CSSValueID ident)
{
    switch (ident) {
    case CSSValueID::Serif:
        return WebKitFontFamilyNames::serifFamily.get();
    case CSSValueID::SansSerif:
        return WebKitFontFamilyNames::sansSerifFamily.get();
    case CSSValueID::Cursive:
        return WebKitFontFamilyNames::cursiveFamily.get();
    case CSSValueID::Fantasy:
        return WebKitFontFamilyNames::fantasyFamily.get();
    case CSSValueID::Monospace:
        return WebKitFontFamilyNames::monospaceFamily.get();
    case CSSValueID::WebkitPictograph:
        return WebKitFontFamilyNames::pictographFamily.get();
    case CSSValueID::SystemUi:
        return WebKitFontFamilyNames::systemUiFamily.get();
    case CSSValueID::Math:
        return WebKitFontFamilyNames::mathFamily.get();
    default:
        return nullAtom();
    }
}

WebKitFontFamilyNames::FamilyNamesIndex genericFontFamilyIndex(CSSValueID ident)
{
    switch (ident) {
    case CSSValueID::Serif:
        return WebKitFontFamilyNames::FamilyNamesIndex::SerifFamily;
    case CSSValueID::SansSerif:
        return WebKitFontFamilyNames::FamilyNamesIndex::SansSerifFamily;
    case CSSValueID::Cursive:
        return WebKitFontFamilyNames::FamilyNamesIndex::CursiveFamily;
    case CSSValueID::Fantasy:
        return WebKitFontFamilyNames::FamilyNamesIndex::FantasyFamily;
    case CSSValueID::Monospace:
        return WebKitFontFamilyNames::FamilyNamesIndex::MonospaceFamily;
    case CSSValueID::WebkitPictograph:
        return WebKitFontFamilyNames::FamilyNamesIndex::PictographFamily;
    case CSSValueID::SystemUi:
        return WebKitFontFamilyNames::FamilyNamesIndex::SystemUiFamily;
    case CSSValueID::Math:
        return WebKitFontFamilyNames::FamilyNamesIndex::MathFamily;
    default:
        ASSERT_NOT_REACHED();
        return WebKitFontFamilyNames::FamilyNamesIndex::StandardFamily;
    }
}

// MARK: - 'font-size'

// The range of the font-weight number and the angles of the @font-face font-style Swift consumes.
static_assert(UnresolvedFontWeightNumber::range == CSS::Range { 1, 1000 } && std::same_as<CSS::FontStyleRange::Oblique::Angle, UnresolvedFontStyleObliqueAngle>);

static std::optional<UnresolvedFont> consumeUnresolvedFont(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<UnresolvedFont>(range, state, CSSPropertyConsumerSwiftConsumer::UnresolvedFont);
}

std::optional<UnresolvedFont> parseUnresolvedFont(StringView string, ScriptExecutionContext& context, std::optional<CSSParserMode> parserModeOverride)
{
    auto parserContext = CSSParserContext(parserModeOverride ? *parserModeOverride : parserMode(context));
    auto tokenizer = CSSTokenizer(string);
    auto range = tokenizer.tokenRange();

    range.consumeWhitespace();

    auto state = CSS::PropertyParserState { .context = parserContext, .pool = context.cssValuePool() };
    return consumeUnresolvedFont(range, state);
}

// MARK: 'font-size-adjust'

// MARK: 'font-palette'

// MARK: - @-rule descriptor consumers:

// MARK: - @font-face

// MARK: @font-face 'src'

Vector<FontTechnology> consumeFontTech(CSSParserTokenRange& range, CSS::PropertyParserState& state, bool singleValue)
{
    return consumeUnresolvedWithSwift<Vector<FontTechnology>>(range, state, CSSPropertyConsumerSwiftConsumer::FontTech, singleValue ? CSSPropertyConsumerSwiftFontSingleValue : 0).value_or(Vector<FontTechnology> { });
}

String consumeFontFormat(CSSParserTokenRange& range, CSS::PropertyParserState& state, bool rejectStringValues)
{
    return consumeUnresolvedWithSwift<String>(range, state, CSSPropertyConsumerSwiftConsumer::FontFormat, rejectStringValues ? CSSPropertyConsumerSwiftFontRejectStringValues : 0).value_or(nullString());
}

RefPtr<CSSValueList> consumeFontFaceSrc(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return downcast<CSSValueList>(consumePropertyWithSwift(range, state, CSSPropertyConsumerSwiftConsumer::FontFaceSrc));
}

RefPtr<CSSValueList> parseFontFaceSrc(StringView string, ScriptExecutionContext& context)
{
    RefPtr document = dynamicDowncast<Document>(context);
    CSSParserContext parserContext = document ? CSSParserContext(*document) : CSSParserContext(HTMLStandardMode);
    CSSParser parser(parserContext, string);
    CSSParserTokenRange range = parser.tokenizer()->tokenRange();

    range.consumeWhitespace();

    if (range.atEnd())
        return nullptr;

    auto state = CSS::PropertyParserState { .context = parserContext, .pool = context.cssValuePool() };
    auto parsedValue = consumeFontFaceSrc(range, state);
    if (!parsedValue || !range.atEnd())
        return nullptr;

    return parsedValue;
}

// MARK: @font-face 'size-adjust'

RefPtr<CSSValue> parseFontFaceSizeAdjust(StringView string, ScriptExecutionContext& context)
{
    // <'size-adjust'> = <percentage [0,∞]>
    // https://www.w3.org/TR/css-fonts-5/#descdef-font-face-size-adjust

    CSSParserContext parserContext(parserMode(context));
    CSSParser parser(parserContext, string);
    CSSParserTokenRange range = parser.tokenizer()->tokenRange();

    range.consumeWhitespace();

    if (range.atEnd())
        return nullptr;

    auto state = CSS::PropertyParserState { .context = parserContext, .pool = context.cssValuePool() };
    auto parsedValue = CSSPropertyParsing::consumeFontFaceSizeAdjust(range, state);
    if (!parsedValue || !range.atEnd())
        return nullptr;

    return parsedValue;
}

static RefPtr<CSSValue> parseFontFaceMetricOverride(StringView string, ScriptExecutionContext& context,
    NOESCAPE const Function<RefPtr<CSSValue>(CSSParserTokenRange&, CSS::PropertyParserState&)>& consumeMetricOverride)
{
    // <font-metrics-override> = normal | <percentage [0,∞]>
    // https://drafts.csswg.org/css-fonts-4/#font-metrics-override-desc

    CSSParserContext parserContext(parserMode(context));
    CSSParser parser(parserContext, string);
    CSSParserTokenRange range = parser.tokenizer()->tokenRange();

    range.consumeWhitespace();

    if (range.atEnd())
        return nullptr;

    auto state = CSS::PropertyParserState { .context = parserContext, .pool = context.cssValuePool() };
    auto parsedValue = consumeMetricOverride(range, state);
    if (!parsedValue || !range.atEnd())
        return nullptr;

    return parsedValue;
}

RefPtr<CSSValue> parseFontFaceAscentOverride(StringView string, ScriptExecutionContext& context)
{
    return parseFontFaceMetricOverride(string, context, CSSPropertyParsing::consumeFontFaceAscentOverride);
}

RefPtr<CSSValue> parseFontFaceDescentOverride(StringView string, ScriptExecutionContext& context)
{
    return parseFontFaceMetricOverride(string, context, CSSPropertyParsing::consumeFontFaceDescentOverride);
}

RefPtr<CSSValue> parseFontFaceLineGapOverride(StringView string, ScriptExecutionContext& context)
{
    return parseFontFaceMetricOverride(string, context, CSSPropertyParsing::consumeFontFaceLineGapOverride);
}

// MARK: @font-face 'unicode-range'

RefPtr<CSSValueList> parseFontFaceUnicodeRange(StringView string, ScriptExecutionContext& context)
{
    // <'unicode-range'> = <unicode-range-token>#
    // https://drafts.csswg.org/css-fonts/#descdef-font-face-unicode-range

    CSSParserContext parserContext(parserMode(context));
    CSSParser parser(parserContext, string);
    CSSParserTokenRange range = parser.tokenizer()->tokenRange();

    range.consumeWhitespace();

    if (range.atEnd())
        return nullptr;

    RefPtr parsedValue = CSSPropertyParsing::consumeFontFaceUnicodeRange(range);
    if (!parsedValue || !range.atEnd())
        return nullptr;

    return dynamicDowncast<CSSValueList>(*parsedValue);
}

// MARK: @font-face 'font-display'

RefPtr<CSSValue> parseFontFaceDisplay(StringView string, ScriptExecutionContext& context)
{
    // <'font-display'> = auto | block | swap | fallback | optional
    // https://drafts.csswg.org/css-fonts/#descdef-font-face-font-display

    CSSParserContext parserContext(parserMode(context));
    CSSParser parser(parserContext, string);
    CSSParserTokenRange range = parser.tokenizer()->tokenRange();

    range.consumeWhitespace();

    if (range.atEnd())
        return nullptr;

    RefPtr parsedValue = CSSPropertyParsing::consumeFontFaceFontDisplay(range);
    if (!parsedValue || !range.atEnd())
        return nullptr;

    return parsedValue;
}

// MARK: @font-face 'font-style'

RefPtr<CSSValue> parseFontFaceFontStyle(StringView string, ScriptExecutionContext& context)
{
    // <'font-style'> = auto | normal | italic | oblique [ <angle [-90deg,90deg]>{1,2} ]?
    // https://drafts.csswg.org/css-fonts/#descdef-font-face-font-style

    // FIXME: Missing support for "auto" identifier.

    CSSParserContext parserContext(parserMode(context));
    CSSParser parser(parserContext, string);
    CSSParserTokenRange range = parser.tokenizer()->tokenRange();

    range.consumeWhitespace();

    if (range.atEnd())
        return nullptr;

    auto state = CSS::PropertyParserState { .context = parserContext, .pool = context.cssValuePool() };
    auto parsedValue = consumeFontFaceFontStyle(range, state);
    if (!parsedValue || !range.atEnd())
        return nullptr;

    return parsedValue;
}

RefPtr<CSSValue> consumeFontFaceFontStyle(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumePropertyWithSwift(range, state, CSSPropertyConsumerSwiftConsumer::FontFaceFontStyle);
}

// MARK: @font-face 'font-feature-settings'

RefPtr<CSSValue> parseFontFaceFeatureSettings(StringView string, ScriptExecutionContext& context)
{
    // <'font-feature-settings'> = normal | <feature-tag-value>#
    // https://drafts.csswg.org/css-fonts/#descdef-font-face-font-feature-settings

    CSSParserContext parserContext(parserMode(context));
    CSSParser parser(parserContext, string);
    CSSParserTokenRange range = parser.tokenizer()->tokenRange();

    range.consumeWhitespace();

    if (range.atEnd())
        return nullptr;

    auto state = CSS::PropertyParserState { .context = parserContext, .pool = context.cssValuePool() };
    auto parsedValue = CSSPropertyParsing::consumeFontFeatureSettings(range, state);
    if (!parsedValue || !range.atEnd())
        return nullptr;

    return parsedValue;
}

// MARK: @font-face 'font-variation-settings'

#if ENABLE(VARIATION_FONTS)

#endif

// MARK: @font-face 'font-width'

RefPtr<CSSValue> parseFontFaceFontWidth(StringView string, ScriptExecutionContext& context)
{
    // <font-width> = auto | <'font-width'>{1,2}
    // https://drafts.csswg.org/css-fonts-4/#descdef-font-face-font-width

    CSSParserContext parserContext(parserMode(context));
    CSSParser parser(parserContext, string);
    CSSParserTokenRange range = parser.tokenizer()->tokenRange();

    range.consumeWhitespace();

    if (range.atEnd())
        return nullptr;

    auto state = CSS::PropertyParserState { .context = parserContext, .pool = context.cssValuePool() };
    auto parsedValue = CSSPropertyParsing::consumeFontFaceFontWidth(range, state);
    if (!parsedValue || !range.atEnd())
        return nullptr;

    return parsedValue;
}

// MARK: @font-face 'font-weight'

RefPtr<CSSValue> parseFontFaceFontWeight(StringView string, ScriptExecutionContext& context)
{
    // <'font-weight'> = auto | <font-weight-absolute>{1,2}
    // https://drafts.csswg.org/css-fonts-4/#descdef-font-face-font-weight

    CSSParserContext parserContext(parserMode(context));
    CSSParser parser(parserContext, string);
    CSSParserTokenRange range = parser.tokenizer()->tokenRange();

    range.consumeWhitespace();

    if (range.atEnd())
        return nullptr;

    auto state = CSS::PropertyParserState { .context = parserContext, .pool = context.cssValuePool() };
    auto parsedValue = CSSPropertyParsing::consumeFontFaceFontWeight(range, state);
    if (!parsedValue || !range.atEnd())
        return nullptr;

    return parsedValue;
}

// MARK: - @font-feature-values

// MARK: @font-feature-values 'prelude family name list'

Vector<AtomString> consumeFontFeatureValuesPreludeFamilyNameList(CSSParserTokenRange& range, const CSSParserContext& context)
{
    CSS::PropertyParserState state { .context = context };
    return consumeUnresolvedWithSwift<Vector<AtomString>>(range, state, CSSPropertyConsumerSwiftConsumer::FontFeatureValuesPrelude).value_or(Vector<AtomString> { });
}

} // namespace CSSPropertyParserHelpers

bool isGenericFontFamilyForSwift(uint16_t id)
{
    return !CSSPropertyParserHelpers::genericFontFamily(static_cast<CSSValueID>(id)).isNull();
}

// The family name of the string token at `start`, or of the identifiers and numbers among the tokens [start, end),
// joined by spaces.
static AtomString familyNameForSwift(const CSSPropertyConsumerSwiftValue& value, uint32_t start, uint32_t end)
{
    auto range = swiftTokenRange(value, start, end);
    if (range.peek().type() == StringToken)
        return range.peek().value().toAtomString();
    StringBuilder builder;
    for (auto& token : range.span()) {
        if (token.type() != IdentToken && token.type() != NumberToken)
            continue;
        if (!builder.isEmpty())
            builder.append(' ');
        builder.append(token.value());
    }
    return builder.toAtomString();
}

Ref<CSSValue> makeFontFamilyNameValue(const CSSPropertyConsumerSwiftValue& value, uint16_t keyword, uint32_t start, uint32_t end)
{
    auto& pool = propertyParserState(value).pool;
    if (static_cast<CSSValueID>(keyword) != CSSValueID::Invalid)
        return pool.createFontFamilyNameValue(nameLiteral(static_cast<CSSValueID>(keyword)));
    return pool.createFontFamilyNameValue(familyNameForSwift(value, start, end));
}

bool isObliqueAngleForSwift(double value, uint8_t unit)
{
    auto angleUnit = CSS::UnitTraits<CSS::AngleUnit>::validate(static_cast<CSSUnitType>(unit));
    RELEASE_ASSERT(angleUnit);
    return CSSPropertyParserHelpers::AngleValidator::isValid(CSSPropertyParserHelpers::UnresolvedFontStyleObliqueAngle::Raw { *angleUnit, value }, { });
}

Ref<CSSValue> makeFontStyleWithAngleValue(const CSSColorSwiftComponents& angle)
{
    return CSSFontStyleWithAngleValue::create(makeColorSwiftComponent<CSSFontStyleWithAngleValue::ObliqueAngle>(angle.at(0)));
}

struct CSSFontPaletteSwiftStack {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(CSSFontPaletteSwiftStack);
    struct Mix {
        std::optional<CSS::ColorInterpolationMethod> colorInterpolationMethod;
        CSS::FontPaletteMixParameters::Components components;
    };
    Vector<CSS::FontPalette, 1> palettes;
    Vector<Mix> mixes;
};

WTF_MAKE_TZONE_ALLOCATED_IMPL(CSSFontPaletteSwiftStack);

CSSFontPaletteSwiftParts::CSSFontPaletteSwiftParts(uint8_t)
    : stack(makeUniqueRef<CSSFontPaletteSwiftStack>())
{
}

CSSFontPaletteSwiftParts::CSSFontPaletteSwiftParts(CSSFontPaletteSwiftParts&&) = default;
CSSFontPaletteSwiftParts::~CSSFontPaletteSwiftParts() = default;

void CSSFontPaletteSwiftParts::appendKeyword(uint16_t keyword)
{
    switch (static_cast<CSSValueID>(keyword)) {
    case CSSValueID::Normal:
        stack->palettes.append(CSS::FontPalette { CSS::Keyword::Normal { } });
        return;
    case CSSValueID::Light:
        stack->palettes.append(CSS::FontPalette { CSS::Keyword::Light { } });
        return;
    case CSSValueID::Dark:
        stack->palettes.append(CSS::FontPalette { CSS::Keyword::Dark { } });
        return;
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }
}

void CSSFontPaletteSwiftParts::appendIdentifier(const CSSPropertyConsumerSwiftValue& value, uint32_t index)
{
    stack->palettes.append(CSS::FontPalette { CSS::CustomIdent { swiftTokenRange(value, index, index + 1).peek().value().toAtomString() } });
}

void CSSFontPaletteSwiftParts::beginMix()
{
    stack->mixes.append(CSSFontPaletteSwiftStack::Mix { });
}

void CSSFontPaletteSwiftParts::setColorInterpolationMethod(CSS::ColorInterpolationMethod&& method)
{
    stack->mixes.last().colorInterpolationMethod = WTF::move(method);
}

void CSSFontPaletteSwiftParts::endMixComponent(const CSSColorSwiftComponents& percentage)
{
    stack->mixes.last().components.value.append(CSS::FontPaletteMixParameters::Component {
        .palette = stack->palettes.takeLast(),
        .percentage = optionalSwiftComponent<CSS::FontPaletteMixParameters::Component::Percentage>(percentage.at(0)),
    });
}

void CSSFontPaletteSwiftParts::endMix()
{
    auto mix = stack->mixes.takeLast();
    stack->palettes.append(CSS::FontPalette { CSS::FontPaletteMixFunction {
        CSS::FontPaletteMixFunctionValue {
            .parameters = CSS::FontPaletteMixParameters {
                .colorInterpolationMethod = mix.colorInterpolationMethod.value_or(CSS::defaultInterpolationMethodForPaletteMix),
                .components = WTF::move(mix.components),
            }
        }
    } });
}

Ref<CSSValue> makeFontPaletteValue(CSSFontPaletteSwiftParts&& parts)
{
    return CSSFontPaletteValue::create(parts.stack->palettes.takeLast());
}

static FontTag fontTagFromSwift(uint32_t tag)
{
    return { static_cast<char>(tag), static_cast<char>(tag >> 8), static_cast<char>(tag >> 16), static_cast<char>(tag >> 24) };
}

Ref<CSSValue> makeFontFeatureValue(const CSSPropertyConsumerSwiftValue& value, uint32_t tag, double integer, uint32_t calc)
{
    using Integer = CSS::Integer<CSS::Nonnegative>;
    if (calc != std::numeric_limits<uint32_t>::max())
        return CSSFontFeatureValue::create(fontTagFromSwift(tag), consumeSwiftCheckedCalc<Integer>(value, calc));
    return CSSFontFeatureValue::create(fontTagFromSwift(tag), Integer { Integer::Raw { CSS::IntegerUnit::Integer, integer } });
}

Ref<CSSValue> makeFontVariationValue(uint32_t tag, CSSValue& number)
{
    return CSSFontVariationValue::create(fontTagFromSwift(tag), Ref { number });
}

CSSFontSwiftParts::~CSSFontSwiftParts() = default;

bool CSSFontSwiftParts::appendTechnology(uint16_t id)
{
    auto technology = fromCSSValueID<FontTechnology>(static_cast<CSSValueID>(id));
    if (technology == FontTechnology::Invalid)
        return false;
    technologies.append(technology);
    return true;
}

void setUnresolvedFontResult(const CSSPropertyConsumerSwiftValue& value, const CSSColorSwiftComponents& slots, uint16_t variantCaps, uint16_t width, CSSFontSwiftParts&& parts)
{
    using namespace CSSPropertyParserHelpers;
    auto keyword = [&](uint8_t slot) {
        return slots.type(slot) ? static_cast<CSSValueID>(slots.at(slot).symbol) : CSSValueID::Normal;
    };
    auto isKeyword = [&](uint8_t slot) {
        return slots.type(slot) == CSSColorSwiftChannelNone || !slots.type(slot);
    };
    UnresolvedFontFamily family;
    for (auto& name : parts.families) {
        if (static_cast<CSSValueID>(name.keyword) != CSSValueID::Invalid)
            family.append({ static_cast<CSSValueID>(name.keyword) });
        else
            family.append({ familyNameForSwift(value, name.start, name.end) });
    }
    CSSPropertyConsumerSwiftUnresolvedResult::set(value, UnresolvedFont {
        .style = isKeyword(0) ? UnresolvedFontStyle { keyword(0) } : UnresolvedFontStyle { makeColorSwiftComponent<UnresolvedFontStyleObliqueAngle>(slots.at(0)) },
        .variantCaps = static_cast<CSSValueID>(variantCaps),
        .weight = isKeyword(1) ? UnresolvedFontWeight { keyword(1) } : UnresolvedFontWeight { makeColorSwiftComponent<UnresolvedFontWeightNumber>(slots.at(1)) },
        .width = static_cast<CSSValueID>(width),
        .size = isKeyword(2) ? UnresolvedFontSize { keyword(2) } : UnresolvedFontSize { makeColorSwiftComponent<CSS::LengthPercentage<CSS::Nonnegative>>(slots.at(2)) },
        .lineHeight = isKeyword(3) ? UnresolvedFontLineHeight { keyword(3) }
            : slots.type(3) == CSSColorSwiftChannelNumber ? UnresolvedFontLineHeight { makeColorSwiftComponent<CSS::Number<CSS::Nonnegative>>(slots.at(3)) }
            : UnresolvedFontLineHeight { makeColorSwiftComponent<CSS::LengthPercentage<CSS::Nonnegative>>(slots.at(3)) },
        .family = WTF::move(family),
    });
}

void setFontTechResult(const CSSPropertyConsumerSwiftValue& value, CSSFontSwiftParts&& parts)
{
    CSSPropertyConsumerSwiftUnresolvedResult::set(value, WTF::move(parts.technologies));
}

void setFontFormatResult(const CSSPropertyConsumerSwiftValue& value, uint32_t index)
{
    CSSPropertyConsumerSwiftUnresolvedResult::set(value, swiftTokenRange(value, index, index + 1).peek().value().toString());
}

RefPtr<CSSValue> makeFontFaceSrcResourceValue(const CSSPropertyConsumerSwiftValue& value, uint32_t urlStart, uint32_t urlEnd, uint32_t format, CSSFontSwiftParts&& parts)
{
    auto range = swiftTokenRange(value, urlStart, urlEnd);
    auto location = CSSPropertyParserHelpers::consumeURLRaw(range, propertyParserState(value), { });
    if (!location)
        return nullptr;
    auto formatString = format == std::numeric_limits<uint32_t>::max() ? String { } : swiftTokenRange(value, format, format + 1).peek().value().toString();
    return CSSFontFaceSrcResourceValue::create(WTF::move(*location), WTF::move(formatString), WTF::move(parts.technologies));
}

Ref<CSSValue> makeFontFaceSrcLocalValue(const CSSPropertyConsumerSwiftValue& value, uint32_t start, uint32_t end)
{
    return CSSFontFaceSrcLocalValue::create(familyNameForSwift(value, start, end));
}

Ref<CSSValue> makeFontFaceFontStyleValue(uint16_t keyword, const CSSColorSwiftComponents& angles, uint8_t angleCount)
{
    using Oblique = CSS::FontStyleRange::Oblique;
    switch (static_cast<CSSValueID>(keyword)) {
    case CSSValueID::Normal:
        return CSSFontStyleRangeValue::create(CSS::FontStyleRange { CSS::Keyword::Normal { } });
    case CSSValueID::Italic:
        return CSSFontStyleRangeValue::create(CSS::FontStyleRange { CSS::Keyword::Italic { } });
    default:
        break;
    }
    RELEASE_ASSERT(static_cast<CSSValueID>(keyword) == CSSValueID::Oblique && angleCount <= 2);
    if (!angleCount)
        return CSSFontStyleRangeValue::create(CSS::FontStyleRange { Oblique { std::nullopt } });
    auto firstAngle = makeColorSwiftComponent<Oblique::Angle>(angles.at(0));
    auto secondAngle = angleCount == 2 ? makeColorSwiftComponent<Oblique::Angle>(angles.at(1)) : firstAngle;
    return CSSFontStyleRangeValue::create(CSS::FontStyleRange { Oblique { Oblique::Angles { WTF::move(firstAngle), WTF::move(secondAngle) } } });
}

void setFontFeatureValuesPreludeResult(const CSSPropertyConsumerSwiftValue& value, CSSFontSwiftParts&& parts)
{
    Vector<AtomString> names = parts.families.map([&](auto& name) {
        return familyNameForSwift(value, name.start, name.end);
    });
    CSSPropertyConsumerSwiftUnresolvedResult::set(value, WTF::move(names));
}

} // namespace WebCore
