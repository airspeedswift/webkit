/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
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
#include "CSSPropertyParserConsumer+Grid.h"

#include "CSSCustomIdentValue.h"
#include "CSSGridAutoFlowValue.h"
#include "CSSGridLineValue.h"
#include "CSSGridTemplateAreasValue.h"
#include "CSSGridTemplateListValue.h"
#include "CSSGridTrackSizesValue.h"
#include "CSSParserIdioms.h"
#include "CSSParserTokenRange.h"
#include "CSSParserTokenRangeGuard.h"
#include "CSSPrimitiveValue.h"
#include "CSSPropertyParserConsumer+FlexDefinitions.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+IntegerDefinitions.h"
#include "CSSPropertyParserConsumer+LengthPercentageDefinitions.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserState.h"
#include "CSSValueList.h"
#include "CSSValuePool.h"
#include "StyleGridPosition.h"
#include <wtf/Vector.h>
#include <wtf/text/StringView.h>
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyConsumerSwiftComponents.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

// The ranges of the integers Swift consumes: a span's index is at least 1, a line's any integer.
static_assert(CSS::Positive == CSS::Range { 1, CSS::Range::infinity });
static_assert(decltype(CSS::GridLineSpan::index)::range == CSS::Positive && decltype(CSS::GridLineExplicit::index)::range == CSS::All);

std::optional<CSS::GridNamedAreaMapRow> consumeUnresolvedGridTemplateAreasRow(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::GridNamedAreaMapRow>(range, state, CSSPropertyConsumerSwiftConsumer::UnresolvedGridTemplateAreasRow);
}

std::optional<CSS::GridLine> consumeUnresolvedGridLine(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::GridLine>(range, state, CSSPropertyConsumerSwiftConsumer::UnresolvedGridLine);
}

std::optional<CSS::GridLineNames> consumeUnresolvedGridLineNames(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::GridLineNames>(range, state, CSSPropertyConsumerSwiftConsumer::UnresolvedGridLineNames);
}

std::optional<CSS::GridTrackList> consumeUnresolvedGridExplicitTrackList(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::GridTrackList>(range, state, CSSPropertyConsumerSwiftConsumer::UnresolvedGridExplicitTrackList);
}

// The ranges of the breadths Swift consumes: a fit-content() length and a flex are non-negative.
static_assert(std::same_as<decltype(CSS::GridFitContentFunctionParameters::value), CSS::LengthPercentage<CSS::Nonnegative>> && CSS::Flex<CSS::Nonnegative>::range == CSS::Nonnegative);

std::optional<CSS::GridTrackSize> consumeUnresolvedGridTrackSize(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::GridTrackSize>(range, state, CSSPropertyConsumerSwiftConsumer::UnresolvedGridTrackSize);
}

// The range of the repeat() counts Swift consumes, at least 1.
static_assert(CSS::Integer<CSS::Positive, unsigned>::range == CSS::Range { 1, CSS::Range::infinity });

RefPtr<CSSValue> consumeGridTemplateList(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumePropertyWithSwift(range, state, CSSPropertyConsumerSwiftConsumer::GridTemplateList);
}

RefPtr<CSSValue> consumeGridTrackSizes(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumePropertyWithSwift(range, state, CSSPropertyConsumerSwiftConsumer::GridTrackSizes);
}

} // namespace CSSPropertyParserHelpers

CSSGridSwiftParts::~CSSGridSwiftParts() = default;

RefPtr<CSSValue> setGridResult(const CSSPropertyConsumerSwiftValue& value, uint16_t consumer, CSSGridSwiftParts&& parts)
{
    // WTF::Vector's indexing is checked, so parts that do not follow their grammar stop here.
    auto& list = parts.m_parts;
    size_t i = 0;
    auto tokenText = [&](uint32_t token) {
        return swiftTokenRange(value, token, token + 1).peek().value();
    };
    auto lineNames = [&] {
        RELEASE_ASSERT(list[i++].kind == CSSGridSwiftLineNames);
        CSS::GridLineNames names;
        for (; list[i].kind == CSSGridSwiftLineName; ++i)
            names.value.value.append(CSS::CustomIdent { tokenText(list[i].token).toAtomString() });
        RELEASE_ASSERT(list[i++].kind == CSSGridSwiftLineNamesEnd);
        return names;
    };
    auto row = [&] {
        CSS::GridNamedAreaMapRow row;
        for (; list[i].kind == CSSGridSwiftAreaName; ++i)
            row.append(tokenText(list[i].token).substring(list[i].offset, list[i].length).toAtomString());
        RELEASE_ASSERT(list[i++].kind == CSSGridSwiftAreaRowEnd);
        return row;
    };
    auto breadth = [&]() -> CSS::GridTrackBreadth {
        auto& part = list[i++];
        switch (part.kind) {
        case CSSGridSwiftBreadthKeyword:
            switch (static_cast<CSSValueID>(part.keyword)) {
            case CSSValueID::MinContent:
                return CSS::GridTrackBreadth { CSS::Keyword::MinContent { } };
            case CSSValueID::MaxContent:
                return CSS::GridTrackBreadth { CSS::Keyword::MaxContent { } };
            default:
                RELEASE_ASSERT(static_cast<CSSValueID>(part.keyword) == CSSValueID::Auto);
                return CSS::GridTrackBreadth { CSS::Keyword::Auto { } };
            }
        case CSSGridSwiftFlex: {
            using Flex = CSS::Flex<CSS::Nonnegative>;
            if (part.token == std::numeric_limits<uint32_t>::max())
                return CSS::GridTrackBreadth { Flex { Flex::Raw { CSS::FlexUnit::Fr, part.component.value } } };
            return CSS::GridTrackBreadth { consumeSwiftCheckedCalc<Flex>(value, part.token) };
        }
        default:
            RELEASE_ASSERT(part.kind == CSSGridSwiftLengthPercentage);
            return CSS::GridTrackBreadth { makeColorSwiftComponent<CSS::LengthPercentage<CSS::Nonnegative>>(part.component) };
        }
    };
    auto trackSize = [&]() -> CSS::GridTrackSize {
        switch (list[i].kind) {
        case CSSGridSwiftMinMax: {
            ++i;
            auto min = breadth();
            auto max = breadth();
            return CSS::GridTrackSize { CSS::GridMinMaxFunction { .parameters = { .min = WTF::move(min), .max = WTF::move(max) } } };
        }
        case CSSGridSwiftFitContent: {
            ++i;
            auto& part = list[i++];
            RELEASE_ASSERT(part.kind == CSSGridSwiftLengthPercentage);
            return CSS::GridTrackSize { CSS::GridFitContentFunction { .parameters = { makeColorSwiftComponent<CSS::LengthPercentage<CSS::Nonnegative>>(part.component) } } };
        }
        default:
            return CSS::GridTrackSize { breadth() };
        }
    };
    using Count = CSS::Integer<CSS::Positive, unsigned>;
    // A repeat()'s count: the calc() Swift has checked is a count, unclamped, or the integer, at most `maximum`.
    // FIXME: Clamping to GridPosition::max() is not specified and is repeated at style building for calc(); it should
    // probably be removed.
    auto count = [&](const auto& part, auto maximum) -> Count {
        if (part.token != std::numeric_limits<uint32_t>::max())
            return consumeSwiftCheckedCalc<Count>(value, part.token);
        return Count { std::min<double>(part.component.value, maximum) };
    };
    auto trackRepeat = [&] {
        using Repeated = CSS::GridTrackRepeatFunctionParameters::Repeated;
        using Repetitions = CSS::GridTrackRepeatFunctionParameters::Repetitions;
        auto repeat = list[i++];
        SpaceSeparatedVector<Repeated> repeated;
        size_t numberOfTracks = 0;
        while (list[i].kind != CSSGridSwiftRepeatEnd) {
            if (list[i].kind == CSSGridSwiftLineNames)
                repeated.value.append(Repeated { lineNames() });
            else {
                repeated.value.append(Repeated { trackSize() });
                numberOfTracks++;
            }
        }
        ++i;
        RELEASE_ASSERT(numberOfTracks);
        auto repetitions = [&] {
            switch (static_cast<CSSValueID>(repeat.keyword)) {
            case CSSValueID::AutoFill:
                return Repetitions { CSS::Keyword::AutoFill { } };
            case CSSValueID::AutoFit:
                return Repetitions { CSS::Keyword::AutoFit { } };
            default:
                return Repetitions { count(repeat, Style::GridPosition::max() / numberOfTracks) };
            }
        }();
        return CSS::GridTrackRepeatFunction { .parameters = { .repetitions = WTF::move(repetitions), .repeated = WTF::move(repeated) } };
    };
    auto nameRepeat = [&] {
        using Repetitions = CSS::GridNameRepeatFunctionParameters::Repetitions;
        auto repeat = list[i++];
        auto repetitions = static_cast<CSSValueID>(repeat.keyword) == CSSValueID::AutoFill ? Repetitions { CSS::Keyword::AutoFill { } } : Repetitions { count(repeat, Style::GridPosition::max()) };
        SpaceSeparatedVector<CSS::GridNameRepeatFunctionParameters::Repeated> repeated;
        while (list[i].kind != CSSGridSwiftRepeatEnd)
            repeated.value.append(lineNames());
        ++i;
        return CSS::GridNameRepeatFunction { .parameters = { .repetitions = WTF::move(repetitions), .repeated = WTF::move(repeated) } };
    };
    auto trackList = [&] {
        using Track = CSS::GridTrackList::Track;
        SpaceSeparatedVector<Track> tracks;
        while (i < list.size()) {
            if (list[i].kind == CSSGridSwiftLineNames)
                tracks.value.append(Track { lineNames() });
            else if (list[i].kind == CSSGridSwiftRepeat)
                tracks.value.append(Track { trackRepeat() });
            else
                tracks.value.append(Track { trackSize() });
        }
        return CSS::GridTrackList { WTF::move(tracks) };
    };

    switch (static_cast<CSSPropertyConsumerSwiftConsumer>(consumer)) {
    case CSSPropertyConsumerSwiftConsumer::GridTemplateAreas: {
        CSS::GridNamedAreaMap map;
        while (i < list.size()) {
            if (!CSS::addRow(map, row()))
                return nullptr;
        }
        if (!map.rowCount)
            return nullptr;
        return CSSGridTemplateAreasValue::create(CSS::GridTemplateAreas { WTF::move(map) });
    }
    case CSSPropertyConsumerSwiftConsumer::UnresolvedGridTemplateAreasRow:
        CSSPropertyConsumerSwiftUnresolvedResult::set(value, row());
        return nullptr;
    case CSSPropertyConsumerSwiftConsumer::UnresolvedGridLineNames:
        CSSPropertyConsumerSwiftUnresolvedResult::set(value, lineNames());
        return nullptr;
    case CSSPropertyConsumerSwiftConsumer::UnresolvedGridTrackSize:
        CSSPropertyConsumerSwiftUnresolvedResult::set(value, trackSize());
        return nullptr;
    case CSSPropertyConsumerSwiftConsumer::GridTrackSizes: {
        SpaceSeparatedVector<CSS::GridTrackSize> sizes;
        while (i < list.size())
            sizes.value.append(trackSize());
        return CSSGridTrackSizesValue::create(CSS::GridTrackSizes { WTF::move(sizes) });
    }
    case CSSPropertyConsumerSwiftConsumer::UnresolvedGridExplicitTrackList:
        CSSPropertyConsumerSwiftUnresolvedResult::set(value, trackList());
        return nullptr;
    case CSSPropertyConsumerSwiftConsumer::GridTemplateList: {
        if (list[i].kind != CSSGridSwiftSubgrid)
            return CSSGridTemplateListValue::create(CSS::GridTemplateList { trackList() });
        ++i;
        using Entry = Variant<CSS::GridLineNames, CSS::GridNameRepeatFunction>;
        SpaceSeparatedVector<Entry> entries;
        while (i < list.size()) {
            if (list[i].kind == CSSGridSwiftNameRepeat)
                entries.value.append(Entry { nameRepeat() });
            else
                entries.value.append(Entry { lineNames() });
        }
        return CSSGridTemplateListValue::create(CSS::GridTemplateList { CSS::GridSubgrid { WTF::move(entries) } });
    }
    default:
        RELEASE_ASSERT_NOT_REACHED();
    }
}

RefPtr<CSSValue> setGridLineResult(const CSSPropertyConsumerSwiftValue& value, uint16_t consumer, uint8_t kind, double index, uint32_t indexCalc, uint32_t name)
{
    // The integer `index`, or the calc() Swift has checked is one.
    auto integer = [&]<typename T>(std::type_identity<T>) -> T {
        if (indexCalc != std::numeric_limits<uint32_t>::max())
            return consumeSwiftCheckedCalc<T>(value, indexCalc);
        return T { typename T::Raw { CSS::IntegerUnit::Integer, index } };
    };
    std::optional<CSS::CustomIdent> customIdent;
    if (name != std::numeric_limits<uint32_t>::max())
        customIdent = CSS::CustomIdent { swiftTokenRange(value, name, name + 1).peek().value().toAtomString() };

    auto line = [&] {
        switch (kind) {
        case CSSGridSwiftLineAuto:
            return CSS::GridLine { CSS::Keyword::Auto { } };
        case CSSGridSwiftLineCustomIdent:
            return CSS::GridLine { WTF::move(*customIdent) };
        case CSSGridSwiftLineExplicit:
            return CSS::GridLine { CSS::GridLineExplicit { .index = integer(std::type_identity<CSS::Integer<>> { }), .name = WTF::move(customIdent) } };
        case CSSGridSwiftLineSpan:
            return CSS::GridLine { CSS::GridLineSpan { .index = integer(std::type_identity<CSS::Integer<CSS::Positive>> { }), .name = WTF::move(customIdent) } };
        default: {
            RELEASE_ASSERT(kind == CSSGridSwiftLineSpanOfInteger);
            // Swift has checked that a raw index is in [1, ∞]; a calc() always narrows.
            auto narrowed = CSS::dynamicRangeNarrowingCast<CSS::Positive>(integer(std::type_identity<CSS::Integer<>> { }));
            RELEASE_ASSERT(narrowed);
            return CSS::GridLine { CSS::GridLineSpan { .index = WTF::move(*narrowed), .name = WTF::move(customIdent) } };
        }
        }
    }();
    if (static_cast<CSSPropertyConsumerSwiftConsumer>(consumer) == CSSPropertyConsumerSwiftConsumer::GridLine)
        return CSSGridLineValue::create(WTF::move(line));
    CSSPropertyConsumerSwiftUnresolvedResult::set(value, WTF::move(line));
    return nullptr;
}
} // namespace WebCore
