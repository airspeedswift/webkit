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

#include "config.h"

#include "Helpers/Test.h"
#include <WebCore/CSSParser.h>
#include <WebCore/CSSParserContext.h>
#include <WebCore/CSSPropertyNames.h>
#include <WebCore/MutableStyleProperties.h>
#include <WebCore/StyleProperties.h>
#include <cstdio>
#include <cstdlib>
#include <iterator>
#include <wtf/MonotonicTime.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

// Each test parses declaration blocks of one family of property values once through the declaration-list parser and
// checks a checksum of what was parsed. With WEBKIT_RUN_BENCHMARKS set, it then parses them a fixed number of times
// and prints the time taken.
//
// The generators make every random draw in its own statement, so the inputs do not depend on the order in which a
// compiler evaluates function arguments.

namespace TestWebKitAPI {

using namespace WebCore;

namespace CSSConsumersBenchmark {

class Random {
public:
    explicit Random(uint64_t seed)
        : m_state(seed)
    {
    }

    unsigned below(unsigned bound)
    {
        m_state = m_state * 6364136223846793005ULL + 1442695040888963407ULL;
        return static_cast<unsigned>(m_state >> 33) % bound;
    }

    bool percent(unsigned chance) { return below(100) < chance; }

    template<typename T, size_t size>
    const T& pick(const T (&values)[size]) { return values[below(size)]; }

private:
    uint64_t m_state;
};

class Checksum {
public:
    void add(uint64_t value) { m_value = (m_value ^ value) * 0x100000001b3ULL; }

    void add(StringView string)
    {
        add(string.length());
        for (auto character : string.codeUnits())
            add(character);
    }

    uint64_t value() const { return m_value; }

private:
    uint64_t m_value { 0xcbf29ce484222325ULL };
};

static bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && StringView::fromLatin1(value) != "0"_s;
}

static void printResult(ASCIILiteral name, Seconds elapsed, double bytes, uint64_t checksum)
{
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, elapsed.milliseconds(), bytes / elapsed.microseconds(),
        static_cast<unsigned long long>(checksum));
}

// MARK: - Numbers and dimensions.

static void appendDigits(StringBuilder& builder, Random& random, unsigned count)
{
    for (unsigned i = 0; i < count; ++i) {
        unsigned digit = random.below(10);
        builder.append(static_cast<char>('0' + digit));
    }
}

static void appendNumber(StringBuilder& builder, Random& random, unsigned maximumInteger, unsigned maximumFractionDigits)
{
    unsigned integer = random.below(maximumInteger + 1);
    builder.append(integer);
    unsigned fractionDigits = random.below(maximumFractionDigits + 1);
    if (fractionDigits) {
        builder.append('.');
        appendDigits(builder, random, fractionDigits);
    }
}

static void appendSignedNumber(StringBuilder& builder, Random& random, unsigned maximumInteger, unsigned maximumFractionDigits, unsigned negativeChance)
{
    if (random.percent(negativeChance))
        builder.append('-');
    appendNumber(builder, random, maximumInteger, maximumFractionDigits);
}

static constexpr ASCIILiteral lengthUnits[] = {
    "px"_s, "px"_s, "px"_s, "px"_s, "em"_s, "em"_s, "rem"_s, "rem"_s, "vw"_s, "vh"_s, "ex"_s, "ch"_s, "vmin"_s, "vmax"_s,
    "pt"_s, "pc"_s, "cm"_s, "mm"_s, "in"_s, "q"_s, "lh"_s, "rlh"_s, "cqw"_s, "svh"_s, "dvh"_s, "lvw"_s,
};

static constexpr ASCIILiteral angleUnits[] = { "deg"_s, "deg"_s, "deg"_s, "rad"_s, "grad"_s, "turn"_s };

static void appendLength(StringBuilder& builder, Random& random, unsigned negativeChance)
{
    auto unit = random.pick(lengthUnits);
    appendSignedNumber(builder, random, unit == "px"_s ? 500 : 40, 2, negativeChance);
    builder.append(unit);
}

static void appendLengthPercentage(StringBuilder& builder, Random& random, unsigned negativeChance)
{
    if (random.percent(30)) {
        appendSignedNumber(builder, random, 100, 1, negativeChance);
        builder.append('%');
        return;
    }
    appendLength(builder, random, negativeChance);
}

static void appendAngle(StringBuilder& builder, Random& random)
{
    auto unit = random.pick(angleUnits);
    appendSignedNumber(builder, random, unit == "deg"_s || unit == "grad"_s ? 360 : 6, 2, 20);
    builder.append(unit);
}

// MARK: - calc() in numeric slots.

static ASCIILiteral additiveOperator(Random& random)
{
    return random.percent(50) ? " + "_s : " - "_s;
}

static void appendCalcLengthPercentage(StringBuilder& builder, Random& random)
{
    switch (random.below(5)) {
    case 0:
        builder.append("calc("_s);
        appendLengthPercentage(builder, random, 0);
        builder.append(additiveOperator(random));
        appendLength(builder, random, 0);
        builder.append(')');
        break;
    case 1:
        builder.append("calc("_s);
        appendLength(builder, random, 0);
        builder.append(" * "_s);
        appendNumber(builder, random, 4, 2);
        builder.append(')');
        break;
    case 2:
        builder.append(random.percent(50) ? "min("_s : "max("_s);
        appendLengthPercentage(builder, random, 0);
        builder.append(", "_s);
        appendLength(builder, random, 0);
        builder.append(')');
        break;
    case 3:
        builder.append("clamp("_s);
        appendLength(builder, random, 0);
        builder.append(", "_s);
        appendLengthPercentage(builder, random, 0);
        builder.append(", "_s);
        appendLength(builder, random, 0);
        builder.append(')');
        break;
    default:
        builder.append("calc(("_s);
        appendLengthPercentage(builder, random, 0);
        builder.append(additiveOperator(random));
        appendLength(builder, random, 0);
        builder.append(") / 2)"_s);
        break;
    }
}

static void appendCalcAngle(StringBuilder& builder, Random& random)
{
    if (random.percent(50)) {
        builder.append("calc("_s);
        appendAngle(builder, random);
        builder.append(additiveOperator(random));
        appendAngle(builder, random);
        builder.append(')');
        return;
    }
    builder.append("calc("_s);
    appendAngle(builder, random);
    builder.append(" * "_s);
    appendNumber(builder, random, 3, 2);
    builder.append(')');
}

static void appendCalcNumber(StringBuilder& builder, Random& random)
{
    switch (random.below(3)) {
    case 0:
        builder.append("calc("_s);
        appendNumber(builder, random, 3, 2);
        builder.append(additiveOperator(random));
        appendNumber(builder, random, 1, 2);
        builder.append(')');
        break;
    case 1:
        builder.append("calc("_s);
        appendNumber(builder, random, 3, 2);
        builder.append(" * "_s);
        appendNumber(builder, random, 2, 1);
        builder.append(')');
        break;
    default:
        builder.append(random.percent(50) ? "min("_s : "max("_s);
        appendNumber(builder, random, 3, 2);
        builder.append(", "_s);
        appendNumber(builder, random, 3, 2);
        builder.append(')');
        break;
    }
}

// MARK: - Declaration blocks.

struct Property {
    CSSPropertyID id;
    ASCIILiteral name;
};

struct Block {
    String text;
    Vector<CSSPropertyID> properties;
};

static constexpr unsigned declarationsPerBlock = 8;
static constexpr unsigned declarationCount = 8192;

// A block holds each property once, so that every value parsed is read back.
struct BlockBuilder {
    bool contains(const Property& property) const { return properties.contains(property.id); }

    void add(const Property& property, const String& value)
    {
        if (!text.isEmpty())
            text.append(' ');
        text.append(property.name, ": "_s, value, ';');
        properties.append(property.id);
    }

    Block take()
    {
        Block block { text.toString(), WTF::move(properties) };
        text.clear();
        properties = { };
        return block;
    }

    StringBuilder text;
    Vector<CSSPropertyID> properties;
};

// The generator appends one value to its builder and returns the property it is for.
template<typename Generator>
static Vector<Block> generateBlocks(uint64_t seed, Generator&& generator)
{
    Random random(seed);
    Vector<Block> blocks;
    BlockBuilder builder;
    for (unsigned i = 0; i < declarationCount; ++i) {
        StringBuilder value;
        auto& property = generator(random, value, i);
        if (builder.contains(property))
            blocks.append(builder.take());
        builder.add(property, value.toString());
        if (builder.properties.size() == declarationsPerBlock)
            blocks.append(builder.take());
    }
    if (!builder.properties.isEmpty())
        blocks.append(builder.take());
    return blocks;
}

static constexpr Property width { CSSPropertyID::Width, "width"_s };
static constexpr Property backgroundSize { CSSPropertyID::BackgroundSize, "background-size"_s };
static constexpr Property webkitBackgroundSize { CSSPropertyID::WebkitBackgroundSize, "-webkit-background-size"_s };
static constexpr Property maskSize { CSSPropertyID::MaskSize, "mask-size"_s };
static constexpr Property transform { CSSPropertyID::Transform, "transform"_s };
static constexpr Property translate { CSSPropertyID::Translate, "translate"_s };
static constexpr Property rotate { CSSPropertyID::Rotate, "rotate"_s };
static constexpr Property scale { CSSPropertyID::Scale, "scale"_s };
static constexpr Property strokeDasharray { CSSPropertyID::StrokeDasharray, "stroke-dasharray"_s };
static constexpr Property animationRangeStart { CSSPropertyID::AnimationRangeStart, "animation-range-start"_s };
static constexpr Property animationRangeEnd { CSSPropertyID::AnimationRangeEnd, "animation-range-end"_s };

// MARK: - <length>, <length-percentage>, <number> and <percentage> in properties of each.

enum class NumericKind : uint8_t { Length, LengthPercentage, Number, Percentage };

struct NumericProperty {
    Property property;
    NumericKind kind;
};

static constexpr NumericProperty numericProperties[] = {
    { width, NumericKind::LengthPercentage },
    { { CSSPropertyID::Height, "height"_s }, NumericKind::LengthPercentage },
    { { CSSPropertyID::MinWidth, "min-width"_s }, NumericKind::LengthPercentage },
    { { CSSPropertyID::MaxWidth, "max-width"_s }, NumericKind::LengthPercentage },
    { { CSSPropertyID::MarginTop, "margin-top"_s }, NumericKind::LengthPercentage },
    { { CSSPropertyID::MarginLeft, "margin-left"_s }, NumericKind::LengthPercentage },
    { { CSSPropertyID::PaddingTop, "padding-top"_s }, NumericKind::LengthPercentage },
    { { CSSPropertyID::PaddingLeft, "padding-left"_s }, NumericKind::LengthPercentage },
    { { CSSPropertyID::Top, "top"_s }, NumericKind::LengthPercentage },
    { { CSSPropertyID::Left, "left"_s }, NumericKind::LengthPercentage },
    { { CSSPropertyID::TextIndent, "text-indent"_s }, NumericKind::LengthPercentage },
    { { CSSPropertyID::LetterSpacing, "letter-spacing"_s }, NumericKind::LengthPercentage },
    { { CSSPropertyID::FontSize, "font-size"_s }, NumericKind::LengthPercentage },
    { { CSSPropertyID::ShapeMargin, "shape-margin"_s }, NumericKind::LengthPercentage },
    { { CSSPropertyID::BorderTopWidth, "border-top-width"_s }, NumericKind::Length },
    { { CSSPropertyID::OutlineOffset, "outline-offset"_s }, NumericKind::Length },
    { { CSSPropertyID::ScrollMarginTop, "scroll-margin-top"_s }, NumericKind::Length },
    { { CSSPropertyID::ColumnWidth, "column-width"_s }, NumericKind::Length },
    { { CSSPropertyID::Perspective, "perspective"_s }, NumericKind::Length },
    { { CSSPropertyID::LineHeight, "line-height"_s }, NumericKind::Number },
    { { CSSPropertyID::Opacity, "opacity"_s }, NumericKind::Number },
    { { CSSPropertyID::FlexGrow, "flex-grow"_s }, NumericKind::Number },
    { { CSSPropertyID::FlexShrink, "flex-shrink"_s }, NumericKind::Number },
    { { CSSPropertyID::StrokeMiterlimit, "stroke-miterlimit"_s }, NumericKind::Number },
    { { CSSPropertyID::FontWidth, "font-width"_s }, NumericKind::Percentage },
};

// Every unit, unitless zero, unitless non-zero numbers in length slots, negative values (rejected where the range is
// [0,∞]) and exponents.
static Vector<Block> numericPrimitivesBlocks()
{
    return generateBlocks(201, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        auto& entry = numericProperties[index % std::size(numericProperties)];
        unsigned variant = random.below(100);
        if (variant < 8) {
            value.append('0');
            return entry.property;
        }
        if (variant < 11 && entry.kind != NumericKind::Number) {
            appendNumber(value, random, 20, 1);
            return entry.property;
        }
        if (variant < 14) {
            appendNumber(value, random, 9, 2);
            value.append("e1"_s);
            value.append(entry.kind == NumericKind::Number ? ""_s : entry.kind == NumericKind::Percentage ? "%"_s : "px"_s);
            return entry.property;
        }
        unsigned negativeChance = 12;
        switch (entry.kind) {
        case NumericKind::Length:
            appendLength(value, random, negativeChance);
            break;
        case NumericKind::LengthPercentage:
            appendLengthPercentage(value, random, negativeChance);
            break;
        case NumericKind::Number:
            appendSignedNumber(value, random, 3, 3, negativeChance);
            break;
        case NumericKind::Percentage:
            appendSignedNumber(value, random, 200, 1, negativeChance);
            value.append('%');
            break;
        }
        return entry.property;
    });
}

// MARK: - background-size, -webkit-background-size and mask-size.

static void appendBackgroundSizeLayer(StringBuilder& value, Random& random, unsigned negativeChance)
{
    unsigned variant = random.below(100);
    if (variant < 15) {
        value.append(random.percent(50) ? "cover"_s : "contain"_s);
        return;
    }
    bool horizontalAuto = random.percent(25);
    if (horizontalAuto)
        value.append("auto"_s);
    else
        appendLengthPercentage(value, random, negativeChance);
    if (variant < 45)
        return;
    value.append(' ');
    bool verticalAuto = random.percent(40);
    if (verticalAuto)
        value.append("auto"_s);
    else
        appendLengthPercentage(value, random, negativeChance);
}

// One to three layers, each a keyword, one value or two, with `auto` in either position.
static Vector<Block> backgroundSizeBlocks()
{
    return generateBlocks(202, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        static constexpr const Property* properties[] = { &backgroundSize, &webkitBackgroundSize, &maskSize };
        auto& property = *properties[index % std::size(properties)];
        unsigned layers = 1 + (random.percent(20) ? 1 + random.below(2) : 0);
        for (unsigned layer = 0; layer < layers; ++layer) {
            if (layer)
                value.append(", "_s);
            appendBackgroundSizeLayer(value, random, 3);
        }
        return property;
    });
}

// MARK: - The transform property.

static void appendTransformFunction(StringBuilder& value, Random& random)
{
    switch (random.below(18)) {
    case 0:
    case 1:
        value.append("translate("_s);
        appendLengthPercentage(value, random, 30);
        if (random.percent(60)) {
            value.append(", "_s);
            appendLengthPercentage(value, random, 30);
        }
        value.append(')');
        break;
    case 2:
        value.append("translateX("_s);
        appendLengthPercentage(value, random, 30);
        value.append(')');
        break;
    case 3:
        value.append("translateY("_s);
        appendLengthPercentage(value, random, 30);
        value.append(')');
        break;
    case 4:
        value.append("translateZ("_s);
        appendLength(value, random, 30);
        value.append(')');
        break;
    case 5:
        value.append("translate3d("_s);
        appendLengthPercentage(value, random, 30);
        value.append(", "_s);
        appendLengthPercentage(value, random, 30);
        value.append(", "_s);
        appendLength(value, random, 30);
        value.append(')');
        break;
    case 6:
    case 7:
        value.append("scale("_s);
        appendNumber(value, random, 2, 2);
        if (random.percent(40)) {
            value.append(", "_s);
            appendNumber(value, random, 2, 2);
        }
        value.append(')');
        break;
    case 8:
        value.append(random.percent(50) ? "scaleX("_s : "scaleY("_s);
        appendNumber(value, random, 2, 2);
        value.append(')');
        break;
    case 9:
        value.append("scale3d("_s);
        appendNumber(value, random, 2, 2);
        value.append(", "_s);
        appendNumber(value, random, 2, 2);
        value.append(", "_s);
        appendNumber(value, random, 2, 2);
        value.append(')');
        break;
    case 10:
    case 11:
        value.append("rotate("_s);
        appendAngle(value, random);
        value.append(')');
        break;
    case 12: {
        unsigned axis = random.below(3);
        value.append(!axis ? "rotateX("_s : axis == 1 ? "rotateY("_s : "rotateZ("_s);
        appendAngle(value, random);
        value.append(')');
        break;
    }
    case 13:
        value.append("rotate3d("_s);
        appendSignedNumber(value, random, 1, 2, 30);
        value.append(", "_s);
        appendSignedNumber(value, random, 1, 2, 30);
        value.append(", "_s);
        appendSignedNumber(value, random, 1, 2, 30);
        value.append(", "_s);
        appendAngle(value, random);
        value.append(')');
        break;
    case 14:
        value.append("skew("_s);
        appendAngle(value, random);
        if (random.percent(50)) {
            value.append(", "_s);
            appendAngle(value, random);
        }
        value.append(')');
        break;
    case 15:
        value.append(random.percent(50) ? "skewX("_s : "skewY("_s);
        appendAngle(value, random);
        value.append(')');
        break;
    case 16:
        value.append("perspective("_s);
        if (random.percent(15))
            value.append("none"_s);
        else
            appendLength(value, random, 0);
        value.append(')');
        break;
    default:
        value.append("translate("_s);
        appendLengthPercentage(value, random, 30);
        value.append(") rotate("_s);
        appendAngle(value, random);
        value.append(')');
        break;
    }
}

// Lists of one to six functions of every kind but matrix() and matrix3d().
static Vector<Block> transformListBlocks()
{
    return generateBlocks(203, [](Random& random, StringBuilder& value, unsigned) -> const Property& {
        if (random.percent(2)) {
            value.append("none"_s);
            return transform;
        }
        unsigned count = 1 + random.below(6);
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                value.append(' ');
            appendTransformFunction(value, random);
        }
        return transform;
    });
}

// MARK: - matrix() and matrix3d().

static void appendMatrixNumber(StringBuilder& value, Random& random)
{
    unsigned kind = random.below(4);
    if (!kind) {
        value.append(random.percent(50) ? '0' : '1');
        return;
    }
    if (kind == 1) {
        appendSignedNumber(value, random, 400, 2, 30);
        return;
    }
    if (random.percent(30))
        value.append('-');
    value.append("0."_s);
    appendDigits(value, random, 1 + random.below(6));
}

static Vector<Block> matrixBlocks()
{
    return generateBlocks(204, [](Random& random, StringBuilder& value, unsigned) -> const Property& {
        bool is3D = random.percent(40);
        value.append(is3D ? "matrix3d("_s : "matrix("_s);
        unsigned count = is3D ? 16 : 6;
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                value.append(", "_s);
            appendMatrixNumber(value, random);
        }
        value.append(')');
        return transform;
    });
}

// MARK: - The translate, rotate and scale properties.

static void appendTranslateValue(StringBuilder& value, Random& random)
{
    if (random.percent(4)) {
        value.append("none"_s);
        return;
    }
    appendLengthPercentage(value, random, 25);
    unsigned count = random.below(3);
    for (unsigned i = 0; i < count; ++i) {
        value.append(' ');
        if (random.percent(25)) {
            value.append(random.percent(50) ? "0"_s : "0px"_s);
            continue;
        }
        if (i)
            appendLength(value, random, 25);
        else
            appendLengthPercentage(value, random, 25);
    }
}

static void appendRotateValue(StringBuilder& value, Random& random)
{
    static constexpr ASCIILiteral axes[] = { "x"_s, "y"_s, "z"_s };
    static constexpr ASCIILiteral axisVectors[] = { "1 0 0"_s, "0 1 0"_s, "0 0 1"_s, "-1 0 0"_s, "0 -1 0"_s, "0 0 -1"_s };
    switch (random.below(6)) {
    case 0:
        value.append("none"_s);
        break;
    case 1:
    case 2:
        appendAngle(value, random);
        break;
    case 3:
        value.append(random.pick(axes), ' ');
        appendAngle(value, random);
        break;
    case 4:
        appendAngle(value, random);
        value.append(' ', random.pick(axes));
        break;
    default:
        if (random.percent(50))
            value.append(random.pick(axisVectors));
        else {
            appendSignedNumber(value, random, 1, 2, 30);
            value.append(' ');
            appendSignedNumber(value, random, 1, 2, 30);
            value.append(' ');
            appendSignedNumber(value, random, 1, 2, 30);
        }
        value.append(' ');
        appendAngle(value, random);
        break;
    }
}

static void appendScaleValue(StringBuilder& value, Random& random)
{
    if (random.percent(4)) {
        value.append("none"_s);
        return;
    }
    unsigned count = 1 + random.below(3);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            value.append(' ');
        if (random.percent(20)) {
            appendNumber(value, random, 200, 1);
            value.append('%');
        } else
            appendSignedNumber(value, random, 2, 2, 10);
    }
}

// translate with one to three components (zero second and third components included), rotate as an angle, with an axis
// keyword or with an axis vector, and scale with one to three numbers or percentages.
static Vector<Block> translateRotateScaleBlocks()
{
    return generateBlocks(205, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        switch (index % 3) {
        case 0:
            appendTranslateValue(value, random);
            return translate;
        case 1:
            appendRotateValue(value, random);
            return rotate;
        default:
            appendScaleValue(value, random);
            return scale;
        }
    });
}

// MARK: - stroke-dasharray.

static void appendDash(StringBuilder& value, Random& random)
{
    unsigned kind = random.below(10);
    if (kind < 4)
        appendNumber(value, random, 20, 1);
    else if (kind < 8) {
        appendNumber(value, random, 30, 1);
        value.append(random.percent(70) ? "px"_s : "em"_s);
    } else {
        appendNumber(value, random, 50, 1);
        value.append('%');
    }
}

// Lists of one to twelve lengths, percentages and numbers, separated by commas, spaces or both.
static Vector<Block> dasharrayBlocks()
{
    return generateBlocks(206, [](Random& random, StringBuilder& value, unsigned) -> const Property& {
        if (random.percent(4)) {
            value.append("none"_s);
            return strokeDasharray;
        }
        unsigned count = 1 + random.below(12);
        unsigned separators = random.below(3);
        for (unsigned i = 0; i < count; ++i) {
            if (i) {
                bool comma = !separators || (separators == 2 && random.percent(50));
                value.append(comma ? ", "_s : " "_s);
            }
            appendDash(value, random);
        }
        return strokeDasharray;
    });
}

// MARK: - animation-range-start and animation-range-end.

static constexpr ASCIILiteral timelineRangeNames[] = { "cover"_s, "contain"_s, "entry"_s, "exit"_s, "entry-crossing"_s, "exit-crossing"_s, "scroll"_s };

static void appendAnimationRange(StringBuilder& value, Random& random, bool isStart)
{
    switch (random.below(6)) {
    case 0:
        value.append("normal"_s);
        break;
    case 1:
        appendLengthPercentage(value, random, 10);
        break;
    case 2:
        value.append(random.pick(timelineRangeNames));
        break;
    case 3:
        value.append(random.pick(timelineRangeNames), isStart ? " 0%"_s : " 100%"_s);
        break;
    default:
        value.append(random.pick(timelineRangeNames), ' ');
        appendLengthPercentage(value, random, 10);
        break;
    }
}

// normal, offsets, names, and names with an offset (the default offset included), one or two per value.
static Vector<Block> animationRangeBlocks()
{
    return generateBlocks(207, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        bool isStart = !(index % 2);
        unsigned count = random.percent(20) ? 2 : 1;
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                value.append(", "_s);
            appendAnimationRange(value, random, isStart);
        }
        return isStart ? animationRangeStart : animationRangeEnd;
    });
}

// MARK: - calc() in the numeric slots of each family.

static Vector<Block> calcArgumentsBlocks()
{
    return generateBlocks(208, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        switch (index % 8) {
        case 0: {
            auto& entry = numericProperties[random.below(14)];
            appendCalcLengthPercentage(value, random);
            return entry.property;
        }
        case 1:
            appendCalcLengthPercentage(value, random);
            if (random.percent(50)) {
                value.append(' ');
                appendLengthPercentage(value, random, 0);
            }
            return index % 3 ? backgroundSize : maskSize;
        case 2:
            value.append("translate("_s);
            appendCalcLengthPercentage(value, random);
            value.append(", "_s);
            appendLength(value, random, 20);
            value.append(") rotate("_s);
            appendCalcAngle(value, random);
            value.append(") scale("_s);
            appendCalcNumber(value, random);
            value.append(')');
            return transform;
        case 3:
            value.append("matrix("_s);
            appendCalcNumber(value, random);
            value.append(", 0, 0, "_s);
            appendCalcNumber(value, random);
            value.append(", "_s);
            appendCalcNumber(value, random);
            value.append(", "_s);
            appendNumber(value, random, 100, 1);
            value.append(')');
            return transform;
        case 4:
            appendCalcLengthPercentage(value, random);
            value.append(' ');
            appendCalcLengthPercentage(value, random);
            return translate;
        case 5:
            if (random.percent(50)) {
                appendCalcAngle(value, random);
                return rotate;
            }
            appendCalcNumber(value, random);
            value.append(' ');
            appendCalcNumber(value, random);
            return scale;
        case 6: {
            unsigned count = 1 + random.below(4);
            for (unsigned i = 0; i < count; ++i) {
                if (i)
                    value.append(", "_s);
                appendCalcLengthPercentage(value, random);
            }
            return strokeDasharray;
        }
        default:
            value.append(random.pick(timelineRangeNames), ' ');
            appendCalcLengthPercentage(value, random);
            return index % 2 ? animationRangeEnd : animationRangeStart;
        }
    });
}

// MARK: - Invalid values.

// Values of the same properties that fail at the first token, at a middle one and at the last one, in turn.
static Vector<Block> invalidValuesBlocks()
{
    return generateBlocks(209, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        unsigned position = index % 3;
        unsigned family = random.below(7);
        switch (family) {
        case 0: {
            auto& entry = numericProperties[random.below(std::size(numericProperties))];
            if (!position)
                value.append(random.percent(50) ? "solid"_s : "#fff"_s);
            else if (position == 1) {
                appendLength(value, random, 0);
                value.append(" red "_s);
                appendLength(value, random, 0);
            } else {
                appendLength(value, random, 0);
                value.append(' ');
                appendLength(value, random, 0);
            }
            return entry.property;
        }
        case 1:
            if (!position)
                value.append("-10px"_s);
            else if (position == 1) {
                appendLengthPercentage(value, random, 0);
                value.append(" red, cover"_s);
            } else {
                appendLengthPercentage(value, random, 0);
                value.append(" auto auto"_s);
            }
            return index % 2 ? backgroundSize : maskSize;
        case 2:
            if (!position) {
                value.append("rotation("_s);
                appendAngle(value, random);
                value.append(") "_s);
                appendTransformFunction(value, random);
            } else if (position == 1) {
                appendTransformFunction(value, random);
                value.append(" skewZ(10deg) "_s);
                appendTransformFunction(value, random);
            } else {
                appendTransformFunction(value, random);
                value.append(' ');
                appendTransformFunction(value, random);
                value.append(" scale(1, 2, 3)"_s);
            }
            return transform;
        case 3:
            if (!position)
                value.append("matrix(1, 0, 0, 1, 0)"_s);
            else if (position == 1)
                value.append("matrix3d(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1px, 0, 0, 0, 0, 1)"_s);
            else
                value.append("matrix(1, 0, 0, 1, 0, 0, 0)"_s);
            return transform;
        case 4:
            if (!position) {
                value.append("auto "_s);
                appendLength(value, random, 0);
                return translate;
            }
            if (position == 1) {
                value.append("x "_s);
                appendLength(value, random, 0);
                return rotate;
            }
            value.append("1 2 3 4"_s);
            return scale;
        case 5:
            if (!position)
                value.append("dashed"_s);
            else if (position == 1) {
                appendDash(value, random);
                value.append(", red, "_s);
                appendDash(value, random);
            } else {
                appendDash(value, random);
                value.append(", "_s);
                appendDash(value, random);
                value.append(',');
            }
            return strokeDasharray;
        default:
            if (!position)
                value.append("10deg"_s);
            else if (position == 1) {
                value.append(random.pick(timelineRangeNames), " cover "_s);
                appendLengthPercentage(value, random, 0);
            } else {
                value.append(random.pick(timelineRangeNames), ' ');
                appendLengthPercentage(value, random, 0);
                value.append(" 5px"_s);
            }
            return index % 2 ? animationRangeEnd : animationRangeStart;
        }
    });
}

// MARK: - A stylesheet's declarations.

// Declarations as found in stylesheets of real sites, these properties among others, weighted by how often each
// occurs. `@` is a number. One block in sixteen has a comment with a character outside Latin-1, so it is parsed from a
// 16-bit string.
struct MixedTemplate {
    Property property;
    ASCIILiteral text;
    unsigned weight;
};

static constexpr MixedTemplate mixedTemplates[] = {
    { { CSSPropertyID::Color, "color"_s }, "#333"_s, 10 },
    { { CSSPropertyID::Display, "display"_s }, "flex"_s, 8 },
    { width, "@%"_s, 4 },
    { width, "@px"_s, 3 },
    { { CSSPropertyID::Margin, "margin"_s }, "0 auto"_s, 3 },
    { { CSSPropertyID::Margin, "margin"_s }, "@px 0 @px"_s, 3 },
    { { CSSPropertyID::Padding, "padding"_s }, "@px @px"_s, 5 },
    { { CSSPropertyID::FontSize, "font-size"_s }, "@px"_s, 3 },
    { { CSSPropertyID::FontSize, "font-size"_s }, "1.@rem"_s, 2 },
    { { CSSPropertyID::LineHeight, "line-height"_s }, "1.@"_s, 4 },
    { transform, "translate(-50%, -50%)"_s, 2 },
    { transform, "rotate(@deg)"_s, 1 },
    { transform, "scale(1.0@)"_s, 1 },
    { transform, "translateY(-@px)"_s, 1 },
    { transform, "translate3d(0, 0, 0)"_s, 1 },
    { transform, "matrix(1, 0, 0, 1, @, @)"_s, 1 },
    { { CSSPropertyID::Opacity, "opacity"_s }, ".@"_s, 4 },
    { { CSSPropertyID::BackgroundColor, "background-color"_s }, "rgba(0, 0, 0, .@)"_s, 4 },
    { { CSSPropertyID::Border, "border"_s }, "@px solid #ddd"_s, 3 },
    { { CSSPropertyID::Position, "position"_s }, "absolute"_s, 3 },
    { { CSSPropertyID::Top, "top"_s }, "@px"_s, 2 },
    { { CSSPropertyID::Left, "left"_s }, "@%"_s, 1 },
    { { CSSPropertyID::ZIndex, "z-index"_s }, "@"_s, 2 },
    { backgroundSize, "cover"_s, 2 },
    { backgroundSize, "@px @px"_s, 1 },
    { { CSSPropertyID::Transition, "transition"_s }, "opacity .@s ease"_s, 2 },
    { { CSSPropertyID::BoxShadow, "box-shadow"_s }, "0 @px @px rgba(0, 0, 0, .@)"_s, 1 },
    { strokeDasharray, "@, @"_s, 1 },
    { rotate, "@deg"_s, 1 },
    { translate, "@px -@px"_s, 1 },
    { scale, "1.@"_s, 1 },
    { maskSize, "contain"_s, 1 },
    { animationRangeStart, "entry @%"_s, 1 },
    { { CSSPropertyID::Height, "height"_s }, "calc(100% - @px)"_s, 1 },
};

static Vector<Block> mixedBlocks()
{
    unsigned totalWeight = 0;
    for (auto& entry : mixedTemplates)
        totalWeight += entry.weight;
    return generateBlocks(210, [totalWeight](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        unsigned choice = random.below(totalWeight);
        const MixedTemplate* chosen = &mixedTemplates[0];
        for (auto& entry : mixedTemplates) {
            if (choice < entry.weight) {
                chosen = &entry;
                break;
            }
            choice -= entry.weight;
        }
        if (!(index % (16 * declarationsPerBlock)))
            value.append("/* "_s, static_cast<char16_t>(0x3C00), " */ "_s);
        for (auto character : chosen->text.span()) {
            if (character != '@') {
                value.append(character);
                continue;
            }
            unsigned number = 1 + random.below(99);
            value.append(number);
        }
        return chosen->property;
    });
}

// MARK: - Long lists.

// background-size, mask-size, animation-range-start, animation-range-end and transform values of 256, 1000 and 4000
// items, one value per block, all valid.
static Vector<Block> longListsBlocks()
{
    static constexpr unsigned itemCounts[] = { 256, 1000, 4000 };
    static constexpr const Property* properties[] = { &backgroundSize, &maskSize, &animationRangeStart, &animationRangeEnd, &transform };
    Random random(211);
    Vector<Block> blocks;
    BlockBuilder builder;
    for (unsigned count : itemCounts) {
        for (auto* property : properties) {
            StringBuilder value;
            for (unsigned i = 0; i < count; ++i) {
                if (property == &transform) {
                    if (i)
                        value.append(' ');
                    appendTransformFunction(value, random);
                    continue;
                }
                if (i)
                    value.append(", "_s);
                if (property == &animationRangeStart || property == &animationRangeEnd)
                    appendAnimationRange(value, random, property == &animationRangeStart);
                else
                    appendBackgroundSizeLayer(value, random, 0);
            }
            builder.add(*property, value.toString());
            blocks.append(builder.take());
        }
    }
    return blocks;
}

// MARK: - Long values with calc().

// transform and stroke-dasharray values of 100 and 1000 items, each with a math function, one value per block, all
// valid.
static Vector<Block> longCalcListsBlocks()
{
    static constexpr unsigned itemCounts[] = { 100, 1000 };
    Random random(212);
    Vector<Block> blocks;
    BlockBuilder builder;
    for (unsigned count : itemCounts) {
        StringBuilder transformValue;
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                transformValue.append(' ');
            switch (random.below(3)) {
            case 0:
                transformValue.append("translateX("_s);
                appendCalcLengthPercentage(transformValue, random);
                break;
            case 1:
                transformValue.append("rotate("_s);
                appendCalcAngle(transformValue, random);
                break;
            default:
                transformValue.append("scale("_s);
                appendCalcNumber(transformValue, random);
                break;
            }
            transformValue.append(')');
        }
        builder.add(transform, transformValue.toString());
        blocks.append(builder.take());

        StringBuilder dasharrayValue;
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                dasharrayValue.append(", "_s);
            appendCalcLengthPercentage(dasharrayValue, random);
        }
        builder.add(strokeDasharray, dasharrayValue.toString());
        blocks.append(builder.take());
    }
    return blocks;
}

// MARK: - Running.

static size_t blockBytes(const Vector<Block>& blocks)
{
    size_t bytes = 0;
    for (auto& block : blocks)
        bytes += block.text.length();
    return bytes;
}

static uint64_t checksumOfParse(const Vector<Block>& blocks, const CSSParserContext& context, unsigned& parsedValues, unsigned& changedBlocks)
{
    Checksum checksum;
    for (auto& block : blocks) {
        Ref properties = MutableStyleProperties::create();
        bool changed = CSSParser::parseDeclarationList(properties, block.text, context);
        changedBlocks += changed;
        checksum.add(changed);
        for (auto property : block.properties) {
            auto text = properties->getPropertyValue(property);
            parsedValues += !text.isEmpty();
            checksum.add(text);
        }
    }
    return checksum.value();
}

enum class Values : bool { Valid, Invalid };

static void run(ASCIILiteral name, const Vector<Block>& blocks, Values values, uint64_t expectedChecksum, unsigned passes)
{
    auto& context = strictCSSParserContext();
    auto bytes = blockBytes(blocks);
    ASSERT_GT(bytes, 0u);
    unsigned parsedValues = 0;
    unsigned changedBlocks = 0;
    auto checksum = checksumOfParse(blocks, context, parsedValues, changedBlocks);
    if (values == Values::Valid)
        EXPECT_GT(parsedValues, 0u);
    else
        EXPECT_EQ(0u, parsedValues);
    EXPECT_EQ(expectedChecksum, checksum) << "checksum=" << std::hex << checksum;
    if (!runsBenchmarks())
        return;

    unsigned changed = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass) {
        for (auto& block : blocks) {
            Ref properties = MutableStyleProperties::create();
            changed += CSSParser::parseDeclarationList(properties, block.text, context);
        }
    }
    auto elapsed = MonotonicTime::now() - start;
    EXPECT_EQ(changedBlocks * passes, changed);
    printResult(name, elapsed, static_cast<double>(bytes) * passes, checksum);
}

} // namespace CSSConsumersBenchmark

using namespace CSSConsumersBenchmark;

TEST(CSSConsumersBench, NumericPrimitives) { run("NumericPrimitives"_s, numericPrimitivesBlocks(), Values::Valid, 0x68e4648d41da4e9eULL, 1100); }
TEST(CSSConsumersBench, BackgroundSize) { run("BackgroundSize"_s, backgroundSizeBlocks(), Values::Valid, 0xa664ad7a4ba33f21ULL, 650); }
TEST(CSSConsumersBench, TransformList) { run("TransformList"_s, transformListBlocks(), Values::Valid, 0x8d88b923a1722f75ULL, 200); }
TEST(CSSConsumersBench, Matrix) { run("Matrix"_s, matrixBlocks(), Values::Valid, 0xe5f51f8a5b5ad50dULL, 225); }
TEST(CSSConsumersBench, TranslateRotateScale) { run("TranslateRotateScale"_s, translateRotateScaleBlocks(), Values::Valid, 0xedb1ddf496078a81ULL, 800); }
TEST(CSSConsumersBench, Dasharray) { run("Dasharray"_s, dasharrayBlocks(), Values::Valid, 0xc5c157ea304bf966ULL, 280); }
TEST(CSSConsumersBench, AnimationRange) { run("AnimationRange"_s, animationRangeBlocks(), Values::Valid, 0x5644faf7dee4f5e7ULL, 700); }
TEST(CSSConsumersBench, CalcArguments) { run("CalcArguments"_s, calcArgumentsBlocks(), Values::Valid, 0x2061e65aa728af92ULL, 240); }
TEST(CSSConsumersBench, InvalidValues) { run("InvalidValues"_s, invalidValuesBlocks(), Values::Invalid, 0x5317fa4ea8f080bfULL, 400); }
TEST(CSSConsumersBench, Mixed) { run("Mixed"_s, mixedBlocks(), Values::Valid, 0x03dee0898f337ef4ULL, 700); }
TEST(CSSConsumersBench, LongLists) { run("LongLists"_s, longListsBlocks(), Values::Valid, 0x2fdd38e418995bfdULL, 550); }
TEST(CSSConsumersBench, LongCalcLists) { run("LongCalcLists"_s, longCalcListsBlocks(), Values::Valid, 0xe209a136162215abULL, 2400); }

} // namespace TestWebKitAPI
