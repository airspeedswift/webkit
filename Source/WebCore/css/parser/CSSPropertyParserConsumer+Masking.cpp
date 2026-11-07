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
#include "CSSPropertyParserConsumer+Masking.h"

#include "CSSClipValue.h"
#include "CSSKeywordValueInlines.h"
#include "CSSMaskBorder.h"
#include "CSSMaskBorderOutsetValue.h"
#include "CSSMaskBorderRepeatValue.h"
#include "CSSMaskBorderSliceValue.h"
#include "CSSMaskBorderSourceValue.h"
#include "CSSMaskBorderWidthValue.h"
#include "CSSParserContext.h"
#include "CSSParserTokenRange.h"
#include "CSSParserTokenRangeGuard.h"
#include "CSSPrimitiveValue.h"
#include "CSSPropertyParserConsumer+Background.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+Image.h"
#include "CSSPropertyParserConsumer+LengthDefinitions.h"
#include "CSSPropertyParserConsumer+LengthPercentageDefinitions.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+NumberDefinitions.h"
#include "CSSPropertyParserConsumer+PercentageDefinitions.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserConsumer+Shapes.h"
#include "CSSPropertyParserConsumer+URL.h"
#include "CSSPropertyParserState.h"
#include "CSSPropertyParsing.h"
#include "CSSValueKeywords.h"
#include "CSSValueList.h"
#if USE_SWIFT_CSS_PROPERTY_CONSUMERS_4
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyConsumerSwiftComponents.h"
#endif

namespace WebCore {
namespace CSSPropertyParserHelpers {

#if !USE_SWIFT_CSS_PROPERTY_CONSUMERS_4

static std::optional<CSS::ClipRect> consumeUnresolvedClipRectFunction(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // rect() = rect( <top>, <right>, <bottom>, <left> )
    // "<top>, <right>, <bottom>, and <left> may either have a <length> value or auto."
    // https://drafts.fxtf.org/css-masking/#funcdef-clip-rect

    if (range.peek().functionId() != CSSValueID::Rect)
        return std::nullopt;

    CSSParserTokenRangeGuard guard { range };

    auto args = consumeFunction(range);

    auto consumeClipEdge = [&] -> std::optional<CSS::ClipEdge> {
        if (auto autoKeyword = consumeSpecificUnresolvedIdent<CSS::Keyword::Auto>(args))
            return CSS::ClipEdge { *autoKeyword };
        return MetaConsumer<CSS::ClipEdge::Length>::consume(args, state);
    };

    // Support both rect(t, r, b, l) and rect(t r b l).
    //
    // "User agents must support separation with commas, but may also support
    //  separation without commas (but not a combination), because a previous
    //  revision of this specification was ambiguous in this respect"
    auto top = consumeClipEdge();
    if (!top)
        return std::nullopt;

    bool needsComma = consumeCommaIncludingWhitespace(args);

    auto right = consumeClipEdge();
    if (!right || (needsComma && !consumeCommaIncludingWhitespace(args)))
        return std::nullopt;

    auto bottom = consumeClipEdge();
    if (!bottom || (needsComma && !consumeCommaIncludingWhitespace(args)))
        return std::nullopt;

    auto left = consumeClipEdge();
    if (!left || !args.atEnd())
        return std::nullopt;

    guard.commit();
    return CSS::ClipRect {
        WTF::move(*top),
        WTF::move(*right),
        WTF::move(*bottom),
        WTF::move(*left),
    };
}

static std::optional<CSS::Clip> consumeUnresolvedClip(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'clip'> = <rect()> | auto
    // https://drafts.csswg.org/css-masking/#propdef-clip

    if (auto keyword = consumeSpecificUnresolvedIdent<CSS::Keyword::Auto>(range))
        return CSS::Clip { *keyword };

    if (auto clipRectFunction = consumeUnresolvedClipRectFunction(range, state))
        return CSS::Clip { WTF::move(*clipRectFunction) };

    return std::nullopt;
}

RefPtr<CSSValue> consumeClip(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'clip'> = <rect()> | auto
    // https://drafts.csswg.org/css-masking/#propdef-clip

    if (auto unresolved = consumeUnresolvedClip(range, state))
        return CSSClipValue::create(WTF::move(*unresolved));
    return nullptr;
}

RefPtr<CSSValue> consumeClipPath(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'clip-path'> = none | <clip-source> | [ <basic-shape> || <geometry-box> ]
    // <clip-source> = <url>
    // https://drafts.fxtf.org/css-masking/#propdef-clip-path

    if (range.peek().id() == CSSValueID::None)
        return consumeIdent(range);

    if (auto url = consumeURL(range, state, { }))
        return url;

    RefPtr<CSSValue> shape;
    RefPtr<CSSValue> box;

    auto consumeShape = [&]() -> bool {
        if (shape)
            return false;
        shape = consumeBasicShape(range, state, { });
        return !!shape;
    };
    auto consumeBox = [&]() -> bool {
        if (box)
            return false;
        box = CSSPropertyParsing::consumeGeometryBox(range);
        return !!box;
    };

    while (!range.atEnd()) {
        if (consumeShape() || consumeBox())
            continue;
        break;
    }

    bool hasShape = !!shape;

    CSSValueListBuilder list;
    if (shape)
        list.append(shape.releaseNonNull());
    // Default value is border-box.
    if (box && (!isValueID(*box, CSSValueID::BorderBox) || !hasShape))
        list.append(box.releaseNonNull());

    if (list.isEmpty())
        return nullptr;

    return CSSValueList::createSpaceSeparated(WTF::move(list));
}

// MARK: - Mask Border

std::optional<CSS::MaskBorderSource> consumeUnresolvedMaskBorderSource(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'mask-border-source'> = none | <image>
    // https://drafts.csswg.org/css-masking-1/#propdef-mask-border-source

    if (auto keyword = consumeSpecificUnresolvedIdent<CSS::Keyword::None>(range))
        return CSS::MaskBorderSource { WTF::move(*keyword) };

    if (RefPtr image = consumeImage(range, state))
        return CSS::MaskBorderSource { image.releaseNonNull() };

    return std::nullopt;
}

RefPtr<CSSValue> consumeMaskBorderSource(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'mask-border-source'> = none | <image>
    // https://drafts.csswg.org/css-masking-1/#propdef-mask-border-source

    if (auto unresolved = consumeUnresolvedMaskBorderSource(range, state))
        return CSSMaskBorderSourceValue::create(WTF::move(*unresolved));
    return nullptr;
}

std::optional<CSS::MaskBorderOutset> consumeUnresolvedMaskBorderOutset(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'mask-border-outset'> = [ <length [0,∞]> | <number [0,∞]> ]{1,4}
    // https://drafts.fxtf.org/css-masking-1/#propdef-mask-border-outset

    std::array<std::optional<CSS::MaskBorderOutset::Value>, 4> values;

    for (auto& value : values) {
        value = MetaConsumer<CSS::MaskBorderOutset::Value::Number>::consume(range, state);
        if (!value)
            value = MetaConsumer<CSS::MaskBorderOutset::Value::Length>::consume(range, state);
        if (!value)
            break;
    }
    if (!values[0])
        return std::nullopt;

    return CSS::MaskBorderOutset {
        .values = completeQuadFromArray<CSS::MaskBorderOutset::Edges>(WTF::move(values)),
    };
}

RefPtr<CSSValue> consumeMaskBorderOutset(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'mask-border-outset'> = [ <length [0,∞]> | <number [0,∞]> ]{1,4}
    // https://drafts.fxtf.org/css-masking-1/#propdef-mask-border-outset

    if (auto unresolved = consumeUnresolvedMaskBorderOutset(range, state))
        return CSSMaskBorderOutsetValue::create(WTF::move(*unresolved));
    return nullptr;
}

std::optional<CSS::MaskBorderRepeat> consumeUnresolvedMaskBorderRepeat(CSSParserTokenRange& range, CSS::PropertyParserState&)
{
    // <'mask-border-repeat'> = [ stretch | repeat | round | space ]{1,2}
    // https://drafts.fxtf.org/css-masking-1/#propdef-mask-border-repeat

    std::array<std::optional<CSS::MaskBorderRepeat::Value>, 2> values;

    values[0] = consumeSpecificUnresolvedIdent<CSS::MaskBorderRepeat::Value>(range);
    if (!values[0])
        return std::nullopt;

    values[1] = consumeSpecificUnresolvedIdent<CSS::MaskBorderRepeat::Value>(range);
    if (!values[1])
        values[1] = values[0];

    return CSS::MaskBorderRepeat {
        .values = { WTF::move(*values[0]), WTF::move(*values[1]) }
    };
}

RefPtr<CSSValue> consumeMaskBorderRepeat(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'mask-border-repeat'> = [ stretch | repeat | round | space ]{1,2}
    // https://drafts.fxtf.org/css-masking-1/#propdef-mask-border-repeat

    if (auto unresolved = consumeUnresolvedMaskBorderRepeat(range, state))
        return CSSMaskBorderRepeatValue::create(WTF::move(*unresolved));
    return nullptr;
}

std::optional<CSS::MaskBorderSlice> consumeUnresolvedMaskBorderSlice(CSSParserTokenRange& range, CSS::PropertyParserState& state, MaskBorderSliceOverride overridesSlice)
{
    // <'mask-border-slice'> = [<number [0,∞]> | <percentage [0,∞]>]{1,4} && fill?
    // https://drafts.fxtf.org/css-masking-1/#propdef-mask-border-slice

    auto fill = consumeSpecificUnresolvedIdent<CSS::Keyword::Fill>(range);

    std::array<std::optional<CSS::MaskBorderSlice::Value>, 4> values;

    for (auto& value : values) {
        value = MetaConsumer<CSS::MaskBorderSlice::Value::Percentage>::consume(range, state);
        if (!value)
            value = MetaConsumer<CSS::MaskBorderSlice::Value::Number>::consume(range, state);
        if (!value)
            break;
    }
    if (!values[0])
        return std::nullopt;

    if (!fill)
        fill = consumeSpecificUnresolvedIdent<CSS::Keyword::Fill>(range);

    // NOTE: For backwards compatibility -webkit-mask-box-image and -webkit-box-reflect set fill unconditionally.
    if (overridesSlice == MaskBorderSliceOverride::AlwaysFill)
        fill = CSS::Keyword::Fill { };

    return CSS::MaskBorderSlice {
        .values = completeQuadFromArray<CSS::MaskBorderSlice::Edges>(WTF::move(values)),
        .fill = fill,
    };
}

RefPtr<CSSValue> consumeMaskBorderSlice(CSSParserTokenRange& range, CSS::PropertyParserState& state, MaskBorderSliceOverride overridesSlice)
{
    // <'mask-border-slice'> = [<number [0,∞]> | <percentage [0,∞]>]{1,4} && fill?
    // https://drafts.fxtf.org/css-masking-1/#propdef-mask-border-slice

    if (auto unresolved = consumeUnresolvedMaskBorderSlice(range, state, overridesSlice))
        return CSSMaskBorderSliceValue::create(WTF::move(*unresolved));
    return nullptr;
}

std::optional<CSS::MaskBorderWidth> consumeUnresolvedMaskBorderWidth(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'mask-border-width'> = [ <length-percentage [0,∞]> | <number [0,∞]> | auto ]{1,4}
    // https://drafts.fxtf.org/css-masking-1/#propdef-mask-border-width

    std::array<std::optional<CSS::MaskBorderWidth::Value>, 4> values;

    for (auto& value : values) {
        value = MetaConsumer<CSS::MaskBorderWidth::Value::Number>::consume(range, state);
        if (value)
            continue;

        // FIXME: Figure out and document why overrideParserMode is explicitly set to HTMLStandardMode here or remove the special case.
        // FIXME: As this falls into the "<length> ambiguous with <number>" case, this should probably be `.unitlessZeroLength = UnitlessZeroQuirk::Forbid` in case the order of checks ever changes.

        value = MetaConsumer<CSS::MaskBorderWidth::Value::LengthPercentage>::consume(range, state, { .overrideParserMode = HTMLStandardMode });
        if (value)
            continue;

        value = consumeSpecificUnresolvedIdent<CSS::Keyword::Auto>(range);
        if (value)
            continue;

        break;
    }

    if (!values[0])
        return std::nullopt;

    return CSS::MaskBorderWidth {
        .values = completeQuadFromArray<CSS::MaskBorderWidth::Edges>(WTF::move(values)),
    };
}

RefPtr<CSSValue> consumeMaskBorderWidth(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    // <'mask-border-width'> = [ <length-percentage [0,∞]> | <number [0,∞]> | auto ]{1,4}
    // https://drafts.fxtf.org/css-masking-1/#propdef-mask-border-width

    if (auto unresolved = consumeUnresolvedMaskBorderWidth(range, state))
        return CSSMaskBorderWidthValue::create(WTF::move(*unresolved));
    return nullptr;
}

std::optional<CSS::MaskBorder> consumeUnresolvedMaskBorder(CSSParserTokenRange& range, CSS::PropertyParserState& state, MaskBorderSliceOverride overridesSlice)
{
    // <'mask-border'> = <'mask-border-source'>
    //                || <'mask-border-slice'> [ / <'mask-border-width'>? [ / <'mask-border-outset'> ]? ]?
    //                || <'mask-border-repeat'>
    //                || <'mask-border-mode'>
    // FIXME: Add support for `mask-border-mode`.
    // https://drafts.csswg.org/css-masking-1/#propdef-mask-border

    std::optional<CSS::MaskBorderSource> source;
    std::optional<CSS::MaskBorderSlice> slice;
    std::optional<CSS::MaskBorderWidth> width;
    std::optional<CSS::MaskBorderOutset> outset;
    std::optional<CSS::MaskBorderRepeat> repeat;

    do {
        if (!source) {
            source = consumeUnresolvedMaskBorderSource(range, state);
            if (source)
                continue;
        }
        if (!repeat) {
            repeat = consumeUnresolvedMaskBorderRepeat(range, state);
            if (repeat)
                continue;
        }
        if (!slice) {
            slice = consumeUnresolvedMaskBorderSlice(range, state, overridesSlice);
            if (slice) {
                ASSERT(!width && !outset);
                if (consumeSlashIncludingWhitespace(range)) {
                    width = consumeUnresolvedMaskBorderWidth(range, state);
                    if (consumeSlashIncludingWhitespace(range)) {
                        outset = consumeUnresolvedMaskBorderOutset(range, state);
                        if (!outset)
                            return { };
                    } else if (!width)
                        return { };
                }
            } else
                return { };
        } else
            return { };
    } while (!range.atEnd());

    return CSS::MaskBorder {
        .maskBorderSource = WTF::move(source),
        .maskBorderSlice = WTF::move(slice),
        .maskBorderWidth = WTF::move(width),
        .maskBorderOutset = WTF::move(outset),
        .maskBorderRepeat = WTF::move(repeat),
    };
}
#else
RefPtr<CSSValue> consumeMaskBorderSlice(CSSParserTokenRange& range, CSS::PropertyParserState& state, MaskBorderSliceOverride overridesSlice)
{
    return consumePropertyWithSwift(range, state, CSSPropertyConsumerSwiftConsumer::MaskBorderSlice, overridesSlice == MaskBorderSliceOverride::AlwaysFill ? CSSPropertyConsumerSwiftBorderImageSliceAlwaysFill : 0);
}

#if !USE_SWIFT_CSS_SHORTHANDS_AND_TYPED_OM
std::optional<CSS::MaskBorder> consumeUnresolvedMaskBorder(CSSParserTokenRange& range, CSS::PropertyParserState& state, MaskBorderSliceOverride overridesSlice)
{
    return consumeUnresolvedWithSwift<CSS::MaskBorder>(range, state, CSSPropertyConsumerSwiftConsumer::UnresolvedMaskBorder, overridesSlice == MaskBorderSliceOverride::AlwaysFill ? CSSPropertyConsumerSwiftBorderImageSliceAlwaysFill : 0);
}
#endif
#endif

} // namespace CSSPropertyParserHelpers

#if USE_SWIFT_CSS_PROPERTY_CONSUMERS_4
// Swift's mask-border and clip consumers parse these primitives in these ranges.
static_assert(CSS::MaskBorderSlice::Value::Number::range == CSS::Nonnegative && CSS::MaskBorderSlice::Value::Percentage::range == CSS::Nonnegative && CSS::MaskBorderWidth::Value::Number::range == CSS::Nonnegative && CSS::MaskBorderWidth::Value::LengthPercentage::range == CSS::Nonnegative && CSS::MaskBorderOutset::Value::Number::range == CSS::Nonnegative && CSS::MaskBorderOutset::Value::Length::range == CSS::Nonnegative && CSS::ClipEdge::Length::range == CSS::All);

CSS::MaskBorder makeMaskBorderSwift(CSSImageSwiftParts& parts, size_t offset)
{
    auto& p = parts.positions;
    auto source = [&](size_t) { return parts.images.isEmpty() ? CSS::MaskBorderSource { CSS::Keyword::None { } } : CSS::MaskBorderSource { Ref { parts.images[0] } }; };
    auto slice = [&](size_t i) { return CSS::MaskBorderSlice { makeBorderSwiftEdges<CSS::MaskBorderSlice::Edges>(p, i, brigand::list<CSS::MaskBorderSlice::Value::Number, CSS::MaskBorderSlice::Value::Percentage> { }), p[i + 4].type ? std::optional { CSS::Keyword::Fill { } } : std::nullopt }; };
    auto width = [&](size_t i) { return CSS::MaskBorderWidth { makeBorderSwiftEdges<CSS::MaskBorderWidth::Edges>(p, i, brigand::list<CSS::Keyword::Auto, CSS::MaskBorderWidth::Value::LengthPercentage, CSS::MaskBorderWidth::Value::Number> { }) }; };
    auto outset = [&](size_t i) { return CSS::MaskBorderOutset { makeBorderSwiftEdges<CSS::MaskBorderOutset::Edges>(p, i, brigand::list<CSS::MaskBorderOutset::Value::Length, CSS::MaskBorderOutset::Value::Number> { }) }; };
    auto repeat = [&](size_t i) { return CSS::MaskBorderRepeat { { makeColorSwiftComponent<CSS::MaskBorderRepeat::Value>(p[i]), makeColorSwiftComponent<CSS::MaskBorderRepeat::Value>(p[i + 1]) } }; };
    auto part = [&](size_t i, const auto& make) { return p[offset + i].type ? std::optional { make(offset + i) } : std::nullopt; };
    return CSS::MaskBorder { part(15, source), part(0, slice), part(5, width), part(9, outset), part(13, repeat) };
}

RefPtr<CSSValue> makeMaskingValue(const CSSPropertyConsumerSwiftValue& value, uint16_t consumer, CSSImageSwiftParts&& parts)
{
    using Consumer = CSSPropertyConsumerSwiftConsumer;
    switch (static_cast<Consumer>(consumer)) {
    case Consumer::Clip: {
        auto& p = parts.positions;
        if (p.size() == 1)
            return CSSClipValue::create(CSS::Clip { CSS::Keyword::Auto { } });
        auto edge = [&](size_t i) { return makeColorSwiftComponent<CSS::ClipEdge>(p[i], brigand::list<CSS::Keyword::Auto, CSS::ClipEdge::Length> { }); };
        return CSSClipValue::create(CSS::Clip { CSS::ClipRect { edge(0), edge(1), edge(2), edge(3) } });
    }
    default:
        RELEASE_ASSERT(static_cast<Consumer>(consumer) == Consumer::UnresolvedMaskBorder);
        CSSPropertyConsumerSwiftUnresolvedResult::set(value, makeMaskBorderSwift(parts, 0));
        return nullptr;
    }
}

Ref<CSSValue> makeMaskBorderLonghandValue(uint16_t consumer, const CSSColorSwiftComponents& components, uint8_t countOrFill, CSSValue* image)
{
    using Consumer = CSSPropertyConsumerSwiftConsumer;
    switch (static_cast<Consumer>(consumer)) {
    case Consumer::MaskBorderSlice:
        return CSSMaskBorderSliceValue::create(CSS::MaskBorderSlice { makeBorderSwiftEdges<CSS::MaskBorderSlice::Edges>(components, 0, brigand::list<CSS::MaskBorderSlice::Value::Number, CSS::MaskBorderSlice::Value::Percentage> { }), countOrFill ? std::optional { CSS::Keyword::Fill { } } : std::nullopt });
    case Consumer::MaskBorderWidth:
        return CSSMaskBorderWidthValue::create(CSS::MaskBorderWidth { makeBorderSwiftEdges<CSS::MaskBorderWidth::Edges>(components, 0, brigand::list<CSS::Keyword::Auto, CSS::MaskBorderWidth::Value::LengthPercentage, CSS::MaskBorderWidth::Value::Number> { }) });
    case Consumer::MaskBorderOutset:
        return CSSMaskBorderOutsetValue::create(CSS::MaskBorderOutset { makeBorderSwiftEdges<CSS::MaskBorderOutset::Edges>(components, 0, brigand::list<CSS::MaskBorderOutset::Value::Length, CSS::MaskBorderOutset::Value::Number> { }) });
    case Consumer::MaskBorderRepeat:
        return CSSMaskBorderRepeatValue::create(CSS::MaskBorderRepeat { { makeColorSwiftComponent<CSS::MaskBorderRepeat::Value>(components.at(0)), makeColorSwiftComponent<CSS::MaskBorderRepeat::Value>(components.at(countOrFill == 2 ? 1 : 0)) } });
    default:
        RELEASE_ASSERT(static_cast<Consumer>(consumer) == Consumer::MaskBorderSource);
        return CSSMaskBorderSourceValue::create(image ? CSS::MaskBorderSource { Ref { *image } } : CSS::MaskBorderSource { CSS::Keyword::None { } });
    }
}

RefPtr<CSSValue> makeURLValue(const CSSPropertyConsumerSwiftValue& value, uint32_t start, uint32_t end)
{
    auto range = swiftTokenRange(value, start, end);
    return CSSPropertyParserHelpers::consumeURL(range, propertyParserState(value), { });
}
#endif
} // namespace WebCore
