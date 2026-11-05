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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <WebCore/CSSCalcSwiftTypes.h>
#include <WebCore/CSSFunctionValue.h>
#include <WebCore/CSSParserMode.h>
#include <WebCore/CSSParserToken.h>
#include <WebCore/CSSPrimitiveValue.h>
#include <WebCore/CSSTransformListValue.h>
#include <WebCore/CSSValueList.h>
#include <WebCore/CSSValuePair.h>
#include <WebCore/CSSValuePool.h>
#include <cstdint>
#include <span>
#include <wtf/ForbidHeapAllocation.h>

namespace WebCore {

// What a numeric token may be where it is consumed, from the property parser's state and options.
enum : uint8_t {
    CSSNumericConsumerSwiftResolvesToFloat = 1 << 0,
    CSSNumericConsumerSwiftUnitlessZeroLength = 1 << 1,
    CSSNumericConsumerSwiftAbsoluteLengthUnitsOnly = 1 << 2,
    CSSNumericConsumerSwiftQuirkyLength = 1 << 3, // HTMLQuirksMode and CSSProperty::acceptsQuirkyLength(currentProperty).
    CSSNumericConsumerSwiftQuirkyAngle = 1 << 4, // HTMLQuirksMode and CSSProperty::acceptsQuirkyAngle(currentProperty).
};

struct CSSPropertyConsumerSwiftResult {
    uint32_t consumedTokens;
    uint8_t ok;
};

// The hand-written consumers of colors, positions, images, border radii, border images, repeat styles, shadows and
// reflections that cssConsumeProperty consumes, numbered from 0x8000, above every CSSPropertyID and generated
// consumer. Their options are in the state; those consumed into a CSS:: value give it to
// CSSPropertyConsumerSwiftUnresolvedResult (CSSPropertyConsumerSwiftBuilders.h).
enum class CSSPropertyConsumerSwiftConsumer : uint16_t {
    UnresolvedColor = 0x8000, // Options: OptionSet<CSS::ColorType>.
    Color, // Options: OptionSet<CSS::ColorType>.
    DynamicRangeLimit,
    ColorScheme,
    Position,
    BackgroundPosition,
    PositionX,
    PositionY,
    OneOrTwoComponentPosition,
    TwoComponentPositionHorizontal,
    TwoComponentPositionVertical,
    Image, // Options: OptionSet<CSSPropertyParserHelpers::AllowedImageType>.
    BorderRadius,
    WebKitBorderRadius,
    BorderRadiusSide,
    BorderImageSource,
    BorderImageOutset,
    BorderImageRepeat,
    BorderImageSlice, // Options: CSSPropertyConsumerSwiftBorderImageSliceAlwaysFill.
    BorderImageWidth, // Options: CSSPropertyConsumerSwiftBorderImageWidthOverridesWidthForLength.
    BorderImage, // Options: both.
    RepeatStyle,
    BoxShadow,
    WebkitBoxShadow,
    WebkitBoxReflect,
    // The consumers of alignment, display, margin-trim, overflow-clip-margin, the text edges and the counters
    // (CSSPropertyConsumerSwiftAlignment.swift and CSSPropertyConsumerSwiftSmall.swift).
    AlignContent,
    JustifyContent,
    AlignSelf,
    JustifySelf,
    AlignItems,
    JustifyItems,
    Display,
    MarginTrim,
    OverflowClipMargin,
    LineFitEdge,
    TextBoxEdge,
    CounterReset,
    CounterIncrement,
    CounterSet,
    // The consumers of keyframes, text-shadow, position-area, param() (CSSPropertyConsumerSwiftSmall.swift) and easing
    // functions (CSSPropertyConsumerSwiftEffects.swift).
    KeyframeKeyList,
    KeyframesName,
    TextShadow,
    PositionArea,
    ParamFunctionRaw,
    EasingFunction,
    UnresolvedEasingFunction,
    // The consumers of counter styles, quotes, content and calc-size() (CSSPropertyConsumerSwiftSmall.swift).
    CounterStyle,
    CounterStyleName,
    CounterStyleSystem,
    CounterStyleRange,
    CounterStyleAdditiveSymbols,
    Quotes,
    Content,
    CalcSize,
    // The consumers of fonts (CSSPropertyConsumerSwiftFonts.swift).
    FontStyle,
    FontFamily,
    FamilyName,
    FontSizeAdjust,
    FontPalette,
    UnresolvedFont,
    FontFaceSrc,
    FontTech, // Options: CSSPropertyConsumerSwiftFontSingleValue.
    FontFormat, // Options: CSSPropertyConsumerSwiftFontRejectStringValues.
    FontFaceFontStyle,
    FontFeatureValuesPrelude,
    // The consumers of grid lines, grid-auto-flow, grid-template-areas, line names, track sizes and template lists
    // (CSSPropertyConsumerSwiftGrid.swift).
    GridLine,
    UnresolvedGridLine,
    GridAutoFlow,
    GridTemplateAreas,
    UnresolvedGridTemplateAreasRow,
    UnresolvedGridLineNames,
    UnresolvedGridTrackSize,
    GridTrackSizes,
    UnresolvedGridExplicitTrackList,
    GridTemplateList,
    // The consumers of basic shapes (CSSPropertyConsumerSwiftShapes.swift).
    BasicShapeRect,
    Path,
    ShapeOutside,
    // The consumers of clip, clip-path, mask-border and offset-path (CSSPropertyConsumerSwiftShapes.swift).
    Clip,
    ClipPath,
    MaskBorderSource,
    MaskBorderOutset,
    MaskBorderRepeat,
    MaskBorderSlice, // Options: CSSPropertyConsumerSwiftBorderImageSliceAlwaysFill.
    MaskBorderWidth,
    UnresolvedMaskBorder, // Options: CSSPropertyConsumerSwiftBorderImageSliceAlwaysFill.
    OffsetPath,
    // The consumers of filters (CSSPropertyConsumerSwiftEffects.swift).
    Filter,
    AppleColorFilter,
    UnresolvedFilter,
};

enum : uint8_t {
    CSSPropertyConsumerSwiftBorderImageSliceAlwaysFill = 1 << 0,
    CSSPropertyConsumerSwiftBorderImageWidthOverridesWidthForLength = 1 << 1,
};
enum : uint8_t {
    CSSPropertyConsumerSwiftFontSingleValue = 1 << 0,
};
enum : uint8_t {
    CSSPropertyConsumerSwiftFontRejectStringValues = 1 << 0,
};

struct CSSGradientSwiftStops;
class CSSPropertyConsumerSwiftUnresolvedResult;

// The length of a token's text, and its first 8 characters, one per byte from the low byte, a character that is not
// ASCII as 0.
struct CSSColorSwiftText {
    uint64_t characters;
    uint32_t length;
};

// Consumes a value with the consumer of the CSSPropertyID `consumer`, the generated one numbered `consumer` from
// cssPropertyIDEnumValueCount, or a CSSPropertyConsumerSwiftConsumer that makes no CSS:: value and needs no
// CSSGradientSwiftStops (no gradient, filter, linear() or calc-size()), through cssConsumeProperty.
RefPtr<CSSValue> consumePropertyWithSwift(CSSParserTokenRange&, CSS::PropertyParserState&, uint16_t consumer);
// The same, through cssConsumeStatelessProperty, for a generated consumer that takes no state: one that consumes only
// keywords and strings. Its state is made from main-thread objects on the first call, so no consumer reached off the
// main thread may use it.
RefPtr<CSSValue> consumePropertyWithSwift(CSSParserTokenRange&, uint16_t consumer);

// Appends CSSKeywordValue::create(id) to `list` without another reference count change.
inline void appendKeywordForSwift(CSSValueListBuilder& list, CSSValueID id) { list.append(CSSKeywordValue::create(id)); }

// A numeric token's value, and in packed its unit (the low byte) and whether it was accepted (bit 8).
struct CSSNumericConsumerSwiftResult {
    double value;
    uint32_t packed;
};

// The value of an ident or string token or the original text of a number or dimension token, else a null text.
inline StringView consumerSwiftTokenText(const CSSParserToken& token)
{
    auto type = token.type();
    if (type == IdentToken || type == StringToken)
        return token.value();
    if (type == NumberToken || type == DimensionToken)
        return token.originalText();
    return { };
}

// A property value's tokens, read one at a time by index, and what receives the value consumed from them
// (CSSCalcSwiftTypes.h describes the facades). Past the last token, a read is that of an EOF token, as
// CSSParserTokenRange::peek's is. Its members are const; they change only what the state refers to.
struct __attribute__((swift_attr("~Sendable"))) CSSPropertyConsumerSwiftValue : CSSCalcSwiftFacade {
    inline size_t count() const;
    uint8_t type(size_t index) const { return index < count() ? token(index).type() : EOFToken; } // CSSParserTokenType.
    uint8_t blockType(size_t index) const { return index < count() ? token(index).getBlockType() : CSSParserToken::NotBlock; }
    uint8_t unitType(size_t index) const { return index < count() ? std::to_underlying(token(index).unitType()) : 0; }
    // The numeric value of a number, percentage or dimension token, else 0.
    double numericValue(size_t index) const
    {
        auto type = this->type(index);
        return type == NumberToken || type == PercentageToken || type == DimensionToken ? token(index).numericValue() : 0;
    }
    // The CSSValueID of an ident token (id()) or a function token (functionId()), else CSSValueID::Invalid.
    // Inlined into the generated Swift, whose keyword switches read it for every token.
    ALWAYS_INLINE uint16_t identifier(size_t index) const
    {
        auto type = this->type(index);
        return std::to_underlying(type == IdentToken ? token(index).id() : type == FunctionToken ? token(index).functionId() : CSSValueID::Invalid);
    }
    // The character of a delimiter token, else 0.
    uint16_t delimiter(size_t index) const { return type(index) == DelimiterToken ? token(index).delimiter() : 0; }
    // Whether a token is a number token with an integer value; whether it is an ident token that starts with two
    // dashes.
    bool isIntegerNumber(size_t index) const { return type(index) == NumberToken && token(index).numericValueType() == IntegerValueType; }
    bool isDashedIdent(size_t index) const { return type(index) == IdentToken && token(index).value().startsWith("--"_s); }
    // The CSSCustomIdentValue of an ident token, or the CSSStringValue of a string token.
    Ref<CSSValue> tokenValue(size_t index) const;
    void setResult(CSSValue&) const;
    // The options of a CSSPropertyConsumerSwiftConsumer.
    inline uint8_t consumerOptions() const;
    // The text of a hash or ident token's value or of a dimension token's unit, for hex colors.
    inline CSSColorSwiftText hexColorText(size_t index) const;
    // Whether a number or dimension token's value is an integer.
    bool isIntegerNumeric(size_t index) const { return (type(index) == NumberToken || type(index) == DimensionToken) && token(index).numericValueType() == IntegerValueType; }
    // The length of an ident or string token's value or of a number or dimension token's original text, or UINT32_MAX
    // for a null text or a token of another type.
    uint32_t textLength(size_t index) const
    {
        auto text = index < count() ? consumerSwiftTokenText(token(index)) : StringView { };
        return text.isNull() ? std::numeric_limits<uint32_t>::max() : text.length();
    }
    // The code unit at `offset` of that text, or 0 past its end.
    uint16_t textCharacter(size_t index, uint32_t offset) const
    {
        auto text = index < count() ? consumerSwiftTokenText(token(index)) : StringView { };
        return offset < text.length() ? text[offset] : 0;
    }
    // The calc() value of the math function `function` whose arguments are the tokens [argumentsStart, argumentsEnd),
    // which cssConsumePropertyCalc parses with calc() states of this call's own, or null if they do not parse.
    RefPtr<CSSPrimitiveValue> parseCalc(uint32_t argumentsStart, uint32_t argumentsEnd, uint16_t function, uint8_t category, uint32_t flags, double rangeMin, double rangeMax) const;
protected:
    CSSPropertyConsumerSwiftValue() = default;
private:
    inline const CSSParserToken& token(size_t index) const;
};

// The state behind CSSPropertyConsumerSwiftValue: the value's tokens, the property parser's state, and where the consumed
// value goes.
class CSSPropertyConsumerSwiftValueState final : public CSSPropertyConsumerSwiftValue {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    CSSPropertyConsumerSwiftValueState(std::span<const CSSParserToken> tokens, CSS::PropertyParserState& propertyParserState, RefPtr<CSSValue>& result)
        : tokens(tokens)
        , propertyParserState(propertyParserState)
        , result(result)
    {
    }

    // For a CSSPropertyConsumerSwiftConsumer: its options, where the stops of a gradient it consumes go, and where a
    // CSS:: value it consumes goes, if anywhere.
    CSSPropertyConsumerSwiftValueState(std::span<const CSSParserToken> tokens, CSS::PropertyParserState& propertyParserState, RefPtr<CSSValue>& result, uint8_t consumerOptions, CSSGradientSwiftStops& gradientStops, CSSPropertyConsumerSwiftUnresolvedResult* unresolvedResult)
        : tokens(tokens)
        , propertyParserState(propertyParserState)
        , result(result)
        , options(consumerOptions)
        , gradientStops(&gradientStops)
        , unresolvedResult(unresolvedResult)
    {
    }

    const std::span<const CSSParserToken> tokens;
    CSS::PropertyParserState& propertyParserState;
    RefPtr<CSSValue>& result;
    const uint8_t options { 0 };
    CSSGradientSwiftStops* const gradientStops { nullptr };
    CSSPropertyConsumerSwiftUnresolvedResult* const unresolvedResult { nullptr };
};

inline size_t CSSPropertyConsumerSwiftValue::count() const { return static_cast<const CSSPropertyConsumerSwiftValueState&>(*this).tokens.size(); }
inline uint8_t CSSPropertyConsumerSwiftValue::consumerOptions() const { return static_cast<const CSSPropertyConsumerSwiftValueState&>(*this).options; }

inline CSSColorSwiftText CSSPropertyConsumerSwiftValue::hexColorText(size_t index) const
{
    auto type = this->type(index);
    auto text = type == HashToken || type == IdentToken ? token(index).value() : type == DimensionToken ? token(index).unitString() : StringView { };
    uint64_t characters = 0;
    for (unsigned i = 0; i < std::min(text.length(), 8u); ++i)
        characters |= static_cast<uint64_t>(isASCII(text[i]) ? text[i] : 0) << (8 * i);
    return { characters, text.length() };
}
inline const CSSParserToken& CSSPropertyConsumerSwiftValue::token(size_t index) const { return static_cast<const CSSPropertyConsumerSwiftValueState&>(*this).tokens[index]; }

// The tokens of a unicode-range, read as CSSPropertyConsumerSwiftValue reads them, with no property parser's state:
// FontFace can consume one on a worker thread.
struct __attribute__((swift_attr("~Sendable"))) CSSUnicodeRangeSwiftTokens : CSSCalcSwiftFacade {
    inline size_t count() const;
    uint8_t type(size_t index) const { return index < count() ? token(index).type() : EOFToken; } // CSSParserTokenType.
    uint16_t delimiter(size_t index) const { return type(index) == DelimiterToken ? token(index).delimiter() : 0; }
    // As CSSPropertyConsumerSwiftValue's.
    uint32_t textLength(size_t index) const
    {
        auto text = index < count() ? consumerSwiftTokenText(token(index)) : StringView { };
        return text.isNull() ? std::numeric_limits<uint32_t>::max() : text.length();
    }
    uint16_t textCharacter(size_t index, uint32_t offset) const
    {
        auto text = index < count() ? consumerSwiftTokenText(token(index)) : StringView { };
        return offset < text.length() ? text[offset] : 0;
    }
protected:
    CSSUnicodeRangeSwiftTokens() = default;
private:
    inline const CSSParserToken& token(size_t index) const;
};

class CSSUnicodeRangeSwiftTokensState final : public CSSUnicodeRangeSwiftTokens {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    explicit CSSUnicodeRangeSwiftTokensState(std::span<const CSSParserToken> tokens)
        : tokens(tokens)
    {
    }

    const std::span<const CSSParserToken> tokens;
};

inline size_t CSSUnicodeRangeSwiftTokens::count() const { return static_cast<const CSSUnicodeRangeSwiftTokensState&>(*this).tokens.size(); }
inline const CSSParserToken& CSSUnicodeRangeSwiftTokens::token(size_t index) const { return static_cast<const CSSUnicodeRangeSwiftTokensState&>(*this).tokens[index]; }

// A <urange>'s code points, and the tokens it and the whitespace after it took; with ok 0, there is none, and nothing
// was taken.
struct CSSUnicodeRangeSwiftResult {
    uint32_t consumedTokens;
    uint32_t start;
    uint32_t end;
    uint8_t ok;
};

// A <urange> and the whitespace after it, through cssConsumeUnicodeRange, which reads only the tokens; nothing is
// consumed if there is none.
CSSUnicodeRangeSwiftResult consumeUnicodeRangeWithSwift(CSSParserTokenRange&);

} // namespace WebCore

// A numeric token of a numeric primitive with the given range, CSS::Category and CSS::RangeParseTimeBehaviors.
extern "C" WebCore::CSSNumericConsumerSwiftResult cssConsumeNumericSwift(double value, double rangeMin, double rangeMax, uint8_t category, uint8_t tokenType, uint8_t unitType, uint8_t parserMode, uint8_t minBehavior, uint8_t maxBehavior, uint8_t flags) noexcept;
