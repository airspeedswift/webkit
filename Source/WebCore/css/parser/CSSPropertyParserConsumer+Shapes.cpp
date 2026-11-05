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
#include "CSSPropertyParserConsumer+Shapes.h"

#include "CSSBasicShapeValue.h"
#include "CSSKeywordValueInlines.h"
#include "CSSParserTokenRange.h"
#include "CSSPathValue.h"
#include "CSSPrimitiveValue.h"
#include "CSSPropertyParserConsumer+AngleDefinitions.h"
#include "CSSPropertyParserConsumer+Background.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+Image.h"
#include "CSSPropertyParserConsumer+LengthPercentageDefinitions.h"
#include "CSSPropertyParserConsumer+MetaConsumer.h"
#include "CSSPropertyParserConsumer+Position.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserConsumer+URL.h"
#include "CSSPropertyParserState.h"
#include "CSSPropertyParsing.h"
#include "CSSValueKeywords.h"
#include "CSSValueList.h"
#include <wtf/SortedArrayMap.h>
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyConsumerSwiftComponents.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

using namespace CSS::Literals;

template<CSSValueID Name, typename T> CSS::BasicShape toBasicShape(T&& parameters)
{
    return CSS::BasicShape { FunctionNotation<Name, T> { WTF::move(parameters) } };
}

// The ranges of the lengths Swift consumes: a circle()'s and an ellipse()'s radii and an xywh()'s size are non-negative.
static_assert(CSS::Circle::Length::range == CSS::Nonnegative && CSS::Ellipse::Length::range == CSS::Nonnegative && std::same_as<CSS::Xywh::Size, SpaceSeparatedSize<CSS::LengthPercentage<CSS::Nonnegative>>>);

RefPtr<CSSValue> consumeBasicShapeRect(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumePropertyWithSwift(range, state, CSSPropertyConsumerSwiftConsumer::BasicShapeRect);
}

} // namespace CSSPropertyParserHelpers

CSSColorSwiftComponents makePositionSwiftComponents(const Vector<CSSColorSwiftComponents::Component, 16>& components, size_t offset)
{
    CSSColorSwiftComponents result;
    for (uint8_t i = 0; i < 4; ++i)
        result.mutableAt(i) = components[offset + i];
    return result;
}

// shape()'s starting point and its commands, from `p`: a position is its layout (as setPositionResult describes it) as a
// symbol, then its four components; a coordinate pair is two components; a control point is a position or a coordinate
// pair, then its anchor (a symbol, or absent). A command is its CSSValueID and, but for close, to or by, as symbols, then
// its operands in the order of its grammar, a missing control point being one absent component; arc's are its two
// radii, then its sweep, its size and its rotation, each absent for the default.
static CSS::Shape makeShapeSwift(const Vector<CSSColorSwiftComponents::Component, 16>& p, std::optional<CSS::FillRule>&& fillRule)
{
    using namespace CSS::Literals;
    using LengthPercentage = CSS::LengthPercentage<>;
    size_t i = 0;
    auto next = [&]() -> const CSSColorSwiftComponents::Component& { return p[i++]; };
    auto position = [&] {
        uint16_t layout = next().symbol;
        auto components = makePositionSwiftComponents(p, i);
        i += 4;
        return makePositionSwift(components, layout);
    };
    auto lengthPercentage = [&] { return makeColorSwiftComponent<LengthPercentage>(next()); };
    // Braced initializers evaluate their elements in order, so each reads the components after the previous one.
    auto pair = [&] { return CSS::CoordinatePair { lengthPercentage(), lengthPercentage() }; };
    auto anchor = [&] { return optionalSwiftComponent<CSS::ControlPointAnchor>(next()); };
    auto absolute = [&] { return CSS::AbsoluteControlPoint { position(), anchor() }; };
    auto relative = [&] { return CSS::RelativeControlPoint { pair(), anchor() }; };
    auto optionalAbsolute = [&]() -> std::optional<CSS::AbsoluteControlPoint> {
        if (!p[i].type) {
            ++i;
            return std::nullopt;
        }
        return absolute();
    };
    auto optionalRelative = [&]() -> std::optional<CSS::RelativeControlPoint> {
        if (!p[i].type) {
            ++i;
            return std::nullopt;
        }
        return relative();
    };
    auto axis = [&]<typename Axis>() {
        using Offset = decltype(Axis::offset);
        return Axis { makeColorSwiftComponent<Offset>(next(), brigand::as_list<Offset> { }) };
    };

    auto startingPoint = position();
    CSS::Shape::Commands::Container commands;
    while (i < p.size()) {
        auto id = static_cast<CSSValueID>(next().symbol);
        if (id == CSSValueID::Close) {
            commands.append(CSS::ShapeCommand { CSS::CloseCommand { } });
            continue;
        }
        bool to = static_cast<CSSValueID>(next().symbol) == CSSValueID::To;
        switch (id) {
        case CSSValueID::Move:
            commands.append(CSS::ShapeCommand { to ? CSS::MoveCommand { CSS::MoveCommand::To { position() } } : CSS::MoveCommand { CSS::MoveCommand::By { pair() } } });
            break;
        case CSSValueID::Line:
            commands.append(CSS::ShapeCommand { to ? CSS::LineCommand { CSS::LineCommand::To { position() } } : CSS::LineCommand { CSS::LineCommand::By { pair() } } });
            break;
        case CSSValueID::Hline:
            commands.append(CSS::ShapeCommand { to ? CSS::HLineCommand { CSS::HLineCommand::To { axis.operator()<CSS::TwoComponentPositionHorizontal>() } } : CSS::HLineCommand { CSS::HLineCommand::By { lengthPercentage() } } });
            break;
        case CSSValueID::Vline:
            commands.append(CSS::ShapeCommand { to ? CSS::VLineCommand { CSS::VLineCommand::To { axis.operator()<CSS::TwoComponentPositionVertical>() } } : CSS::VLineCommand { CSS::VLineCommand::By { lengthPercentage() } } });
            break;
        case CSSValueID::Curve:
            commands.append(CSS::ShapeCommand { to ? CSS::CurveCommand { CSS::CurveCommand::To { position(), absolute(), optionalAbsolute() } } : CSS::CurveCommand { CSS::CurveCommand::By { pair(), relative(), optionalRelative() } } });
            break;
        case CSSValueID::Smooth:
            commands.append(CSS::ShapeCommand { to ? CSS::SmoothCommand { CSS::SmoothCommand::To { position(), optionalAbsolute() } } : CSS::SmoothCommand { CSS::SmoothCommand::By { pair(), optionalRelative() } } });
            break;
        default: {
            RELEASE_ASSERT(id == CSSValueID::Arc);
            using ToBy = Variant<CSS::ArcCommand::To, CSS::ArcCommand::By>;
            auto toBy = to ? ToBy { CSS::ArcCommand::To { position() } } : ToBy { CSS::ArcCommand::By { pair() } };
            CSS::ArcCommand::SizeOfEllipse size { lengthPercentage(), lengthPercentage() };
            auto arcSweep = optionalSwiftComponent<CSS::ArcSweep>(next());
            auto arcSize = optionalSwiftComponent<CSS::ArcSize>(next());
            auto rotation = optionalSwiftComponent<CSS::Angle<>>(next());
            commands.append(CSS::ShapeCommand { CSS::ArcCommand {
                .toBy = WTF::move(toBy),
                .size = WTF::move(size),
                .arcSweep = arcSweep.value_or(CSS::ArcSweep { CSS::Keyword::Ccw { } }),
                .arcSize = arcSize.value_or(CSS::ArcSize { CSS::Keyword::Small { } }),
                .rotation = rotation.value_or(0_css_deg)
            } });
            break;
        }
        }
    }
    return CSS::Shape { .fillRule = WTF::move(fillRule), .startingPoint = WTF::move(startingPoint), .commands = { WTF::move(commands) } };
}

RefPtr<CSSValue> makeBasicShapeValue(const CSSPropertyConsumerSwiftValue& value, uint16_t function, uint16_t fillRule, uint32_t pathString, bool asPathValue, const CSSColorSwiftComponents& positionComponents, uint16_t positionLayout, CSSImageSwiftParts&& parts)
{
    using CSSPropertyParserHelpers::toBasicShape;
    using Radii = brigand::list<CSS::BorderRadius::LengthPercentage>;
    // WTF::Vector's indexing is checked, so parts that do not follow their grammar stop here.
    auto& p = parts.positions;
    auto position = [&]() -> std::optional<CSS::Position> {
        if (positionLayout == CSSImageSwiftNoPosition)
            return std::nullopt;
        return makePositionSwift(positionComponents, positionLayout);
    };
    auto radii = [&]() -> CSS::BorderRadius {
        if (!p[4].type)
            return CSS::BorderRadius::defaultValue();
        return CSS::BorderRadius { makeBorderSwiftEdges<CSS::BorderRadius::Axis>(p, 4, Radii { }), makeBorderSwiftEdges<CSS::BorderRadius::Axis>(p, 8, Radii { }) };
    };
    std::optional<CSS::FillRule> rule;
    if (static_cast<CSSValueID>(fillRule) == CSSValueID::Nonzero)
        rule = CSS::FillRule { CSS::Keyword::Nonzero { } };
    else if (static_cast<CSSValueID>(fillRule) == CSSValueID::Evenodd)
        rule = CSS::FillRule { CSS::Keyword::Evenodd { } };

    using LengthPercentage = CSS::LengthPercentage<>;
    switch (static_cast<CSSValueID>(function)) {
    case CSSValueID::Circle:
        return CSSBasicShapeValue::create(toBasicShape<CSSValueID::Circle>(CSS::Circle { .radius = makeColorSwiftComponent<CSS::Circle::RadialSize>(p[0]), .position = position() }));
    case CSSValueID::Ellipse:
        return CSSBasicShapeValue::create(toBasicShape<CSSValueID::Ellipse>(CSS::Ellipse { .radii = { makeColorSwiftComponent<CSS::Ellipse::RadialSize>(p[0]), makeColorSwiftComponent<CSS::Ellipse::RadialSize>(p[1]) }, .position = position() }));
    case CSSValueID::Inset:
        return CSSBasicShapeValue::create(toBasicShape<CSSValueID::Inset>(CSS::Inset { .insets = makeBorderSwiftEdges<CSS::Inset::Insets>(p, 0, brigand::list<LengthPercentage> { }), .radii = radii() }));
    case CSSValueID::Rect: {
        auto edge = [&](size_t index) { return makeColorSwiftComponent<CSS::Rect::Edge>(p[index]); };
        return CSSBasicShapeValue::create(toBasicShape<CSSValueID::Rect>(CSS::Rect { .edges = SpaceSeparatedRectEdges<CSS::Rect::Edge> { edge(0), edge(1), edge(2), edge(3) }, .radii = radii() }));
    }
    case CSSValueID::Xywh: {
        using Size = CSS::LengthPercentage<CSS::Nonnegative>;
        return CSSBasicShapeValue::create(toBasicShape<CSSValueID::Xywh>(CSS::Xywh {
            .location = CSS::Xywh::Location { makeColorSwiftComponent<LengthPercentage>(p[0]), makeColorSwiftComponent<LengthPercentage>(p[1]) },
            .size = CSS::Xywh::Size { makeColorSwiftComponent<Size>(p[2]), makeColorSwiftComponent<Size>(p[3]) },
            .radii = radii()
        }));
    }
    case CSSValueID::Polygon: {
        CSS::Polygon::Vertices::Container vertices;
        for (size_t i = 0; i < p.size(); i += 2)
            vertices.append(CSS::Polygon::Vertex { makeColorSwiftComponent<LengthPercentage>(p[i]), makeColorSwiftComponent<LengthPercentage>(p[i + 1]) });
        return CSSBasicShapeValue::create(toBasicShape<CSSValueID::Polygon>(CSS::Polygon { .fillRule = WTF::move(rule), .vertices = { WTF::move(vertices) } }));
    }
    case CSSValueID::Shape:
        return CSSBasicShapeValue::create(toBasicShape<CSSValueID::Shape>(makeShapeSwift(p, WTF::move(rule))));
    default: {
        RELEASE_ASSERT(static_cast<CSSValueID>(function) == CSSValueID::Path);
        SVGPathByteStream byteStream;
        if (!buildSVGPathByteStreamFromString(swiftTokenRange(value, pathString, pathString + 1).peek().value(), byteStream, UnalteredParsing) || byteStream.isEmpty())
            return nullptr;
        CSS::Path path { .fillRule = WTF::move(rule), .data = { .byteStream = WTF::move(byteStream) } };
        if (asPathValue)
            return CSSPathValue::create(CSS::PathFunction { .parameters = WTF::move(path) });
        return CSSBasicShapeValue::create(toBasicShape<CSSValueID::Path>(WTF::move(path)));
    }
    }
}
} // namespace WebCore
