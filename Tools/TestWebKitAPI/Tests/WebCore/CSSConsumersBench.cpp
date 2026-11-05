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
#include <WebCore/CSSPropertyParserConsumer+Easing.h>
#include <WebCore/CSSPropertyParserConsumer+Font.h>
#include <WebCore/DocumentInlines.h>
#include <WebCore/MutableStyleProperties.h>
#include <WebCore/ProcessWarming.h>
#include <WebCore/Settings.h>
#include <WebCore/StyleProperties.h>
#include <WebCore/StyleRule.h>
#include <WebCore/StyleSheetContents.h>
#include <WebCore/TimingFunction.h>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <iterator>
#include <span>
#include <wtf/MonotonicTime.h>
#include <wtf/URL.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

// Each test parses declaration blocks of one family of property values once through the declaration-list parser and
// checks a checksum of what was parsed. With WEBKIT_RUN_BENCHMARKS set, it then parses them a fixed number of times
// and prints the time taken. FontShorthands also parses its strings with parseUnresolvedFont, TimingFunctions parses
// each of its easings with parseEasingFunctionDeprecated, and FontFaceBlocks parses style sheets of @font-face rules
// and reads their descriptors back.
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

    template<typename T>
    const T& pick(std::span<const T> values) { return values[below(static_cast<unsigned>(values.size()))]; }

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

// MARK: - Margins and insets.

static constexpr Property marginsInsetsProperties[] = {
    { CSSPropertyID::Margin, "margin"_s },
    { CSSPropertyID::MarginTop, "margin-top"_s },
    { CSSPropertyID::MarginRight, "margin-right"_s },
    { CSSPropertyID::MarginBottom, "margin-bottom"_s },
    { CSSPropertyID::MarginLeft, "margin-left"_s },
    { CSSPropertyID::MarginBlock, "margin-block"_s },
    { CSSPropertyID::MarginInline, "margin-inline"_s },
    { CSSPropertyID::MarginBlockStart, "margin-block-start"_s },
    { CSSPropertyID::MarginInlineEnd, "margin-inline-end"_s },
    { CSSPropertyID::Inset, "inset"_s },
    { CSSPropertyID::InsetBlock, "inset-block"_s },
    { CSSPropertyID::InsetInline, "inset-inline"_s },
    { CSSPropertyID::InsetBlockStart, "inset-block-start"_s },
    { CSSPropertyID::InsetInlineEnd, "inset-inline-end"_s },
    { CSSPropertyID::Top, "top"_s },
    { CSSPropertyID::Left, "left"_s },
    { CSSPropertyID::Bottom, "bottom"_s },
    { CSSPropertyID::Right, "right"_s },
};

static void appendMarginOrInset(StringBuilder& value, Random& random)
{
    unsigned variant = random.below(100);
    if (variant < 15)
        value.append("auto"_s);
    else if (variant < 25)
        value.append('0');
    else if (variant < 60)
        appendLength(value, random, 15);
    else if (variant < 75) {
        appendSignedNumber(value, random, 100, 1, 15);
        value.append('%');
    } else if (variant < 87)
        appendCalcLengthPercentage(value, random);
    else if (variant < 92)
        value.append(random.percent(50) ? "anchor-size(width)"_s : "anchor-size(--a inline, 8px)"_s);
    else
        appendNumber(value, random, 20, 0);
}

// The margin and inset shorthands with one to four values (one or two for the logical ones) and their longhands: auto,
// lengths of every unit, percentages, unitless zero and non-zero numbers, math functions and anchor-size().
static Vector<Block> marginsInsetsBlocks()
{
    return generateBlocks(213, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        auto& property = marginsInsetsProperties[index % std::size(marginsInsetsProperties)];
        unsigned maximumCount = 1;
        if (property.id == CSSPropertyID::Margin || property.id == CSSPropertyID::Inset)
            maximumCount = 4;
        else if (property.id == CSSPropertyID::MarginBlock || property.id == CSSPropertyID::MarginInline || property.id == CSSPropertyID::InsetBlock || property.id == CSSPropertyID::InsetInline)
            maximumCount = 2;
        unsigned count = 1 + random.below(maximumCount);
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                value.append(' ');
            appendMarginOrInset(value, random);
        }
        return property;
    });
}

// MARK: - Border widths.

static constexpr Property borderWidthProperties[] = {
    { CSSPropertyID::BorderWidth, "border-width"_s },
    { CSSPropertyID::BorderTopWidth, "border-top-width"_s },
    { CSSPropertyID::BorderRightWidth, "border-right-width"_s },
    { CSSPropertyID::BorderBottomWidth, "border-bottom-width"_s },
    { CSSPropertyID::BorderLeftWidth, "border-left-width"_s },
    { CSSPropertyID::BorderBlockWidth, "border-block-width"_s },
    { CSSPropertyID::BorderInlineWidth, "border-inline-width"_s },
    { CSSPropertyID::BorderBlockStartWidth, "border-block-start-width"_s },
    { CSSPropertyID::BorderInlineEndWidth, "border-inline-end-width"_s },
    { CSSPropertyID::OutlineWidth, "outline-width"_s },
    { CSSPropertyID::ColumnRuleWidth, "column-rule-width"_s },
};

static void appendLineWidth(StringBuilder& value, Random& random)
{
    static constexpr ASCIILiteral keywords[] = { "thin"_s, "medium"_s, "thick"_s };
    unsigned variant = random.below(100);
    if (variant < 30)
        value.append(random.pick(keywords));
    else if (variant < 40)
        value.append('0');
    else if (variant < 90)
        appendLength(value, random, 5);
    else
        appendCalcLengthPercentage(value, random);
}

// border-width with one to four values (one or two for the logical ones), the border-*-width longhands, outline-width
// and column-rule-width: keywords, lengths (negative ones are rejected), unitless zero and math functions.
static Vector<Block> borderWidthsBlocks()
{
    return generateBlocks(214, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        auto& property = borderWidthProperties[index % std::size(borderWidthProperties)];
        unsigned maximumCount = 1;
        if (property.id == CSSPropertyID::BorderWidth)
            maximumCount = 4;
        else if (property.id == CSSPropertyID::BorderBlockWidth || property.id == CSSPropertyID::BorderInlineWidth)
            maximumCount = 2;
        unsigned count = 1 + random.below(maximumCount);
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                value.append(' ');
            appendLineWidth(value, random);
        }
        return property;
    });
}

// MARK: - Keywords in any order.

using Keywords = std::span<const ASCIILiteral>;

// A property whose value is one of its single keywords, or one keyword from each of one or more of its groups, in any
// order.
struct GroupedProperty {
    Property property;
    Keywords singles;
    std::span<const Keywords> groups;
};

// One to eight of the groups, in a random order, one keyword of each. One value in twenty-five repeats its first
// group, which is invalid.
static void appendKeywordGroups(StringBuilder& value, Random& random, std::span<const Keywords> groups)
{
    std::array<unsigned, 32> order;
    unsigned groupCount = static_cast<unsigned>(groups.size());
    ASSERT(groupCount <= order.size());
    for (unsigned i = 0; i < groupCount; ++i)
        order[i] = i;
    for (unsigned i = groupCount; i > 1; --i) {
        unsigned other = random.below(i);
        std::swap(order[i - 1], order[other]);
    }
    unsigned count = 1 + random.below(std::min(groupCount, 8u));
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            value.append(' ');
        value.append(random.pick(groups[order[i]]));
    }
    if (random.percent(4)) {
        auto& first = groups[order[0]];
        value.append(' ', first[0]);
    }
}

static void appendGroupedValue(StringBuilder& value, Random& random, const GroupedProperty& entry)
{
    if (!entry.singles.empty() && random.percent(12)) {
        value.append(random.pick(entry.singles));
        return;
    }
    appendKeywordGroups(value, random, entry.groups);
}

// A comma-separated list of one to four keywords.
static void appendKeywordList(StringBuilder& value, Random& random, Keywords keywords)
{
    unsigned count = 1 + random.below(4);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            value.append(", "_s);
        value.append(random.pick(keywords));
    }
}

static constexpr ASCIILiteral normalOrNone[] = { "normal"_s, "none"_s };
static constexpr ASCIILiteral normalKeyword[] = { "normal"_s };
static constexpr ASCIILiteral noneKeyword[] = { "none"_s };

// MARK: - font-variant and its longhands.

static constexpr ASCIILiteral commonLigatures[] = { "common-ligatures"_s, "no-common-ligatures"_s };
static constexpr ASCIILiteral discretionaryLigatures[] = { "discretionary-ligatures"_s, "no-discretionary-ligatures"_s };
static constexpr ASCIILiteral historicalLigatures[] = { "historical-ligatures"_s, "no-historical-ligatures"_s };
static constexpr ASCIILiteral contextualAlternates[] = { "contextual"_s, "no-contextual"_s };
static constexpr ASCIILiteral fontCaps[] = { "small-caps"_s, "all-small-caps"_s, "petite-caps"_s, "all-petite-caps"_s, "unicase"_s, "titling-caps"_s };
static constexpr ASCIILiteral stylisticAlternates[] = { "stylistic(fancy)"_s, "stylistic(a1)"_s };
static constexpr ASCIILiteral historicalForms[] = { "historical-forms"_s };
static constexpr ASCIILiteral styleset[] = { "styleset(one)"_s, "styleset(one, two)"_s };
static constexpr ASCIILiteral characterVariant[] = { "character-variant(cv)"_s, "character-variant(cv, alt)"_s };
static constexpr ASCIILiteral swash[] = { "swash(flowing)"_s };
static constexpr ASCIILiteral ornaments[] = { "ornaments(leaves)"_s };
static constexpr ASCIILiteral annotation[] = { "annotation(circled)"_s };
static constexpr ASCIILiteral numericFigures[] = { "lining-nums"_s, "oldstyle-nums"_s };
static constexpr ASCIILiteral numericSpacing[] = { "proportional-nums"_s, "tabular-nums"_s };
static constexpr ASCIILiteral numericFractions[] = { "diagonal-fractions"_s, "stacked-fractions"_s };
static constexpr ASCIILiteral ordinal[] = { "ordinal"_s };
static constexpr ASCIILiteral slashedZero[] = { "slashed-zero"_s };
static constexpr ASCIILiteral eastAsianVariants[] = { "jis78"_s, "jis83"_s, "jis90"_s, "jis04"_s, "simplified"_s, "traditional"_s };
static constexpr ASCIILiteral eastAsianWidths[] = { "full-width"_s, "proportional-width"_s };
static constexpr ASCIILiteral ruby[] = { "ruby"_s };
static constexpr ASCIILiteral fontPosition[] = { "sub"_s, "super"_s };

static constexpr Keywords ligatureGroups[] = { commonLigatures, discretionaryLigatures, historicalLigatures, contextualAlternates };
static constexpr Keywords numericGroups[] = { numericFigures, numericSpacing, numericFractions, ordinal, slashedZero };
static constexpr Keywords eastAsianGroups[] = { eastAsianVariants, eastAsianWidths, ruby };
static constexpr Keywords alternatesGroups[] = { stylisticAlternates, historicalForms, styleset, characterVariant, swash, ornaments, annotation };
static constexpr Keywords fontVariantGroups[] = {
    commonLigatures, discretionaryLigatures, historicalLigatures, contextualAlternates, fontCaps, stylisticAlternates,
    historicalForms, styleset, characterVariant, swash, ornaments, annotation, numericFigures, numericSpacing,
    numericFractions, ordinal, slashedZero, eastAsianVariants, eastAsianWidths, ruby, fontPosition,
};

static constexpr GroupedProperty fontVariantProperties[] = {
    { { CSSPropertyID::FontVariantLigatures, "font-variant-ligatures"_s }, normalOrNone, ligatureGroups },
    { { CSSPropertyID::FontVariantNumeric, "font-variant-numeric"_s }, normalKeyword, numericGroups },
    { { CSSPropertyID::FontVariantEastAsian, "font-variant-east-asian"_s }, normalKeyword, eastAsianGroups },
    { { CSSPropertyID::FontVariantAlternates, "font-variant-alternates"_s }, normalKeyword, alternatesGroups },
    { { CSSPropertyID::FontVariant, "font-variant"_s }, normalOrNone, fontVariantGroups },
};

// font-variant-ligatures, -numeric, -east-asian and -alternates and the font-variant shorthand: normal and none, and
// one to eight of their groups in any order, some with a group repeated.
static Vector<Block> fontVariantGroupsBlocks()
{
    return generateBlocks(215, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        auto& entry = fontVariantProperties[index % std::size(fontVariantProperties)];
        appendGroupedValue(value, random, entry);
        return entry.property;
    });
}

// MARK: - text-decoration, text-underline-position, text-emphasis-style and their lengths.

static constexpr ASCIILiteral underline[] = { "underline"_s };
static constexpr ASCIILiteral overline[] = { "overline"_s };
static constexpr ASCIILiteral lineThrough[] = { "line-through"_s };
static constexpr ASCIILiteral decorationStyles[] = { "solid"_s, "double"_s, "dotted"_s, "dashed"_s, "wavy"_s };
static constexpr ASCIILiteral decorationColors[] = { "red"_s, "#123"_s, "currentcolor"_s, "rgb(10, 20, 30)"_s };
static constexpr ASCIILiteral decorationThicknesses[] = { "auto"_s, "from-font"_s, "2px"_s, "0.1em"_s, "10%"_s };
static constexpr ASCIILiteral underlineSides[] = { "under"_s, "from-font"_s };
static constexpr ASCIILiteral underlineDirections[] = { "left"_s, "right"_s };
static constexpr ASCIILiteral emphasisFills[] = { "filled"_s, "open"_s };
static constexpr ASCIILiteral emphasisShapes[] = { "dot"_s, "circle"_s, "double-circle"_s, "triangle"_s, "sesame"_s };
static constexpr ASCIILiteral autoKeyword[] = { "auto"_s };
static constexpr ASCIILiteral emphasisSingles[] = { "none"_s, "\"*\""_s, "'x'"_s };

static constexpr Keywords textDecorationGroups[] = { underline, overline, lineThrough, decorationStyles, decorationColors, decorationThicknesses };
static constexpr Keywords underlinePositionGroups[] = { underlineSides, underlineDirections };
static constexpr Keywords emphasisStyleGroups[] = { emphasisFills, emphasisShapes };

static constexpr GroupedProperty textDecorationProperties[] = {
    { { CSSPropertyID::TextDecoration, "text-decoration"_s }, noneKeyword, textDecorationGroups },
    { { CSSPropertyID::TextUnderlinePosition, "text-underline-position"_s }, autoKeyword, underlinePositionGroups },
    { { CSSPropertyID::TextEmphasisStyle, "text-emphasis-style"_s }, emphasisSingles, emphasisStyleGroups },
};

static constexpr Property textDecorationThickness { CSSPropertyID::TextDecorationThickness, "text-decoration-thickness"_s };
static constexpr Property textDecorationInset { CSSPropertyID::TextDecorationInset, "text-decoration-inset"_s };
static constexpr Property textUnderlineOffset { CSSPropertyID::TextUnderlineOffset, "text-underline-offset"_s };

static void appendDecorationLength(StringBuilder& value, Random& random)
{
    if (random.percent(10)) {
        appendCalcLengthPercentage(value, random);
        return;
    }
    appendLengthPercentage(value, random, 10);
}

// The text-decoration shorthand, text-underline-position and text-emphasis-style with their groups in any order, and
// text-decoration-thickness, text-decoration-inset (one or two values) and text-underline-offset.
static Vector<Block> textDecorationGroupsBlocks()
{
    return generateBlocks(216, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        unsigned kind = index % 6;
        if (kind < std::size(textDecorationProperties)) {
            auto& entry = textDecorationProperties[kind];
            appendGroupedValue(value, random, entry);
            return entry.property;
        }
        unsigned variant = random.below(100);
        if (kind == 3) {
            if (variant < 15)
                value.append("auto"_s);
            else if (variant < 30)
                value.append("from-font"_s);
            else
                appendDecorationLength(value, random);
            return textDecorationThickness;
        }
        if (kind == 4) {
            if (variant < 15)
                value.append("auto"_s);
            else {
                appendDecorationLength(value, random);
                if (variant < 60) {
                    value.append(' ');
                    appendDecorationLength(value, random);
                }
            }
            return textDecorationInset;
        }
        if (variant < 20)
            value.append("auto"_s);
        else
            appendDecorationLength(value, random);
        return textUnderlineOffset;
    });
}

// MARK: - Border radii.

static constexpr Property borderRadiusProperties[] = {
    { CSSPropertyID::BorderTopLeftRadius, "border-top-left-radius"_s },
    { CSSPropertyID::BorderTopRightRadius, "border-top-right-radius"_s },
    { CSSPropertyID::BorderBottomRightRadius, "border-bottom-right-radius"_s },
    { CSSPropertyID::BorderBottomLeftRadius, "border-bottom-left-radius"_s },
    { CSSPropertyID::BorderStartStartRadius, "border-start-start-radius"_s },
    { CSSPropertyID::BorderStartEndRadius, "border-start-end-radius"_s },
    { CSSPropertyID::BorderEndStartRadius, "border-end-start-radius"_s },
    { CSSPropertyID::BorderEndEndRadius, "border-end-end-radius"_s },
};

static void appendRadius(StringBuilder& value, Random& random)
{
    unsigned variant = random.below(100);
    if (variant < 8)
        value.append('0');
    else if (variant < 18)
        appendCalcLengthPercentage(value, random);
    else
        appendLengthPercentage(value, random, 4);
}

// The border-*-radius longhands, physical and logical: one value, two equal ones (which collapse to one), two
// different ones, percentages, math functions and negative values (rejected).
static Vector<Block> borderRadiusPairsBlocks()
{
    return generateBlocks(217, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        auto& property = borderRadiusProperties[index % std::size(borderRadiusProperties)];
        unsigned variant = random.below(100);
        StringBuilder firstBuilder;
        appendRadius(firstBuilder, random);
        auto first = firstBuilder.toString();
        value.append(first);
        if (variant < 35)
            return property;
        value.append(' ');
        if (variant < 60)
            value.append(first);
        else
            appendRadius(value, random);
        return property;
    });
}

// MARK: - Keyword properties.

static constexpr ASCIILiteral containSize[] = { "size"_s, "inline-size"_s };
static constexpr ASCIILiteral containLayout[] = { "layout"_s };
static constexpr ASCIILiteral containStyle[] = { "style"_s };
static constexpr ASCIILiteral containPaint[] = { "paint"_s };
static constexpr ASCIILiteral containSingles[] = { "none"_s, "strict"_s, "content"_s };
static constexpr ASCIILiteral panX[] = { "pan-x"_s };
static constexpr ASCIILiteral panY[] = { "pan-y"_s };
static constexpr ASCIILiteral pinchZoom[] = { "pinch-zoom"_s };
static constexpr ASCIILiteral touchActionSingles[] = { "auto"_s, "none"_s, "manipulation"_s };
static constexpr ASCIILiteral discardBefore[] = { "discard-before"_s };
static constexpr ASCIILiteral discardAfter[] = { "discard-after"_s };
static constexpr ASCIILiteral discardInner[] = { "discard-inner"_s };
static constexpr ASCIILiteral ideographAlpha[] = { "ideograph-alpha"_s };
static constexpr ASCIILiteral ideographNumeric[] = { "ideograph-numeric"_s };
static constexpr ASCIILiteral insertKeyword[] = { "insert"_s };
static constexpr ASCIILiteral textAutospaceSingles[] = { "normal"_s, "auto"_s, "no-autospace"_s };
static constexpr ASCIILiteral hangingFirst[] = { "first"_s };
static constexpr ASCIILiteral hangingEnd[] = { "force-end"_s, "allow-end"_s };
static constexpr ASCIILiteral hangingLast[] = { "last"_s };
static constexpr ASCIILiteral speakAsSpelling[] = { "normal"_s, "spell-out"_s };
static constexpr ASCIILiteral speakAsDigits[] = { "digits"_s };
static constexpr ASCIILiteral speakAsPunctuation[] = { "literal-punctuation"_s, "no-punctuation"_s };
static constexpr ASCIILiteral anchorsValid[] = { "anchors-valid"_s, "anchor-valid"_s };
static constexpr ASCIILiteral anchorsVisible[] = { "anchors-visible"_s, "anchor-visible"_s };
static constexpr ASCIILiteral noOverflow[] = { "no-overflow"_s };
static constexpr ASCIILiteral alwaysKeyword[] = { "always"_s };
static constexpr ASCIILiteral lineBoxBlock[] = { "block"_s };
static constexpr ASCIILiteral lineBoxInline[] = { "inline"_s };
static constexpr ASCIILiteral lineBoxFont[] = { "font"_s };
static constexpr ASCIILiteral lineBoxGlyphs[] = { "glyphs"_s };
static constexpr ASCIILiteral lineBoxReplaced[] = { "replaced"_s };
static constexpr ASCIILiteral lineBoxInlineBox[] = { "inline-box"_s };
static constexpr ASCIILiteral lineBoxInitialLetter[] = { "initial-letter"_s };

static constexpr Keywords containGroups[] = { containSize, containLayout, containStyle, containPaint };
static constexpr Keywords touchActionGroups[] = { panX, panY, pinchZoom };
static constexpr Keywords whiteSpaceTrimGroups[] = { discardBefore, discardAfter, discardInner };
static constexpr Keywords textAutospaceGroups[] = { ideographAlpha, ideographNumeric, insertKeyword };
static constexpr Keywords hangingPunctuationGroups[] = { hangingFirst, hangingEnd, hangingLast };
static constexpr Keywords speakAsGroups[] = { speakAsSpelling, speakAsDigits, speakAsPunctuation };
static constexpr Keywords positionVisibilityGroups[] = { anchorsValid, anchorsVisible, noOverflow };
static constexpr Keywords lineBoxContainGroups[] = { lineBoxBlock, lineBoxInline, lineBoxFont, lineBoxGlyphs, lineBoxReplaced, lineBoxInlineBox, lineBoxInitialLetter };

static constexpr GroupedProperty keywordGroupProperties[] = {
    { { CSSPropertyID::Contain, "contain"_s }, containSingles, containGroups },
    { { CSSPropertyID::TouchAction, "touch-action"_s }, touchActionSingles, touchActionGroups },
    { { CSSPropertyID::WhiteSpaceTrim, "white-space-trim"_s }, noneKeyword, whiteSpaceTrimGroups },
    { { CSSPropertyID::TextAutospace, "text-autospace"_s }, textAutospaceSingles, textAutospaceGroups },
    { { CSSPropertyID::HangingPunctuation, "hanging-punctuation"_s }, noneKeyword, hangingPunctuationGroups },
    { { CSSPropertyID::SpeakAs, "speak-as"_s }, noneKeyword, speakAsGroups },
    { { CSSPropertyID::PositionVisibility, "position-visibility"_s }, alwaysKeyword, positionVisibilityGroups },
    { { CSSPropertyID::WebkitLineBoxContain, "-webkit-line-box-contain"_s }, noneKeyword, lineBoxContainGroups },
};

struct KeywordListProperty {
    Property property;
    Keywords keywords;
};

static constexpr ASCIILiteral backgroundClips[] = { "border-box"_s, "padding-box"_s, "content-box"_s, "text"_s, "border-area"_s };
static constexpr ASCIILiteral maskModes[] = { "alpha"_s, "luminance"_s, "match-source"_s };
static constexpr ASCIILiteral animationDirections[] = { "normal"_s, "reverse"_s, "alternate"_s, "alternate-reverse"_s };

static constexpr KeywordListProperty keywordListProperties[] = {
    { { CSSPropertyID::BackgroundClip, "background-clip"_s }, backgroundClips },
    { { CSSPropertyID::MaskMode, "mask-mode"_s }, maskModes },
    { { CSSPropertyID::AnimationDirection, "animation-direction"_s }, animationDirections },
};

// Properties of keywords in any order (contain, touch-action, white-space-trim, text-autospace, hanging-punctuation,
// speak-as, position-visibility, -webkit-line-box-contain) and comma-separated keyword lists (background-clip,
// mask-mode, animation-direction).
static Vector<Block> keywordGroupsBlocks()
{
    return generateBlocks(218, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        unsigned kind = index % (std::size(keywordGroupProperties) + std::size(keywordListProperties));
        if (kind < std::size(keywordGroupProperties)) {
            auto& entry = keywordGroupProperties[kind];
            appendGroupedValue(value, random, entry);
            return entry.property;
        }
        auto& entry = keywordListProperties[kind - std::size(keywordGroupProperties)];
        appendKeywordList(value, random, entry.keywords);
        return entry.property;
    });
}

// MARK: - Identifiers, integers and times.

static constexpr ASCIILiteral customIdents[] = { "header"_s, "main"_s, "sidebar"_s, "card"_s, "nav-bar"_s, "a1"_s, "_x"_s, "Item"_s };
static constexpr ASCIILiteral dashedIdents[] = { "--anchor"_s, "--a"_s, "--menu-button"_s, "--tooltip"_s, "--x1"_s };
static constexpr ASCIILiteral willChangeValues[] = { "scroll-position"_s, "contents"_s, "transform"_s, "opacity"_s, "top"_s, "left"_s };
static constexpr ASCIILiteral transitionPropertyValues[] = { "all"_s, "opacity"_s, "transform"_s, "width"_s, "background-color"_s, "--custom"_s, "unknown-thing"_s };

static constexpr Property zIndex { CSSPropertyID::ZIndex, "z-index"_s };
static constexpr Property columnCount { CSSPropertyID::ColumnCount, "column-count"_s };
static constexpr Property mathDepth { CSSPropertyID::MathDepth, "math-depth"_s };
static constexpr Property maxLines { CSSPropertyID::MaxLines, "max-lines"_s };
static constexpr Property animationDuration { CSSPropertyID::AnimationDuration, "animation-duration"_s };
static constexpr Property animationDelay { CSSPropertyID::AnimationDelay, "animation-delay"_s };
static constexpr Property transitionDuration { CSSPropertyID::TransitionDuration, "transition-duration"_s };
static constexpr Property transitionDelay { CSSPropertyID::TransitionDelay, "transition-delay"_s };
static constexpr Property viewTimelineName { CSSPropertyID::ViewTimelineName, "view-timeline-name"_s };
static constexpr Property anchorName { CSSPropertyID::AnchorName, "anchor-name"_s };
static constexpr Property containerName { CSSPropertyID::ContainerName, "container-name"_s };
static constexpr Property willChange { CSSPropertyID::WillChange, "will-change"_s };
static constexpr Property transitionProperty { CSSPropertyID::TransitionProperty, "transition-property"_s };

static void appendInteger(StringBuilder& value, Random& random, unsigned maximum, unsigned negativeChance)
{
    if (random.percent(negativeChance))
        value.append('-');
    unsigned integer = random.below(maximum + 1);
    value.append(integer);
}

static void appendTime(StringBuilder& value, Random& random, unsigned negativeChance)
{
    bool seconds = random.percent(50);
    appendSignedNumber(value, random, seconds ? 3 : 2000, seconds ? 2 : 0, negativeChance);
    value.append(seconds ? "s"_s : "ms"_s);
}

// A comma-separated list of one to three times, with calc() in one in ten.
static void appendTimeList(StringBuilder& value, Random& random, unsigned negativeChance)
{
    unsigned count = 1 + random.below(3);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            value.append(", "_s);
        if (random.percent(10)) {
            value.append("calc("_s);
            appendTime(value, random, 0);
            value.append(" * 2)"_s);
            continue;
        }
        appendTime(value, random, negativeChance);
    }
}

// A list of one to three identifiers, separated by commas or spaces.
template<size_t size>
static void appendIdentList(StringBuilder& value, Random& random, const ASCIILiteral (&idents)[size], ASCIILiteral separator)
{
    unsigned count = 1 + random.below(3);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            value.append(separator);
        value.append(random.pick(idents));
    }
}

// <integer> (z-index, column-count, math-depth, max-lines), <time> lists (animation and transition durations and
// delays), <custom-ident> and <dashed-ident> lists (view-timeline-name, anchor-name, container-name, will-change,
// transition-property) and their keywords.
static Vector<Block> identsIntegersTimesBlocks()
{
    return generateBlocks(219, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        unsigned variant = random.below(100);
        switch (index % 13) {
        case 0:
            if (variant < 15)
                value.append("auto"_s);
            else if (variant < 20)
                value.append("1.5"_s);
            else
                appendInteger(value, random, 9999, 20);
            return zIndex;
        case 1:
            if (variant < 15)
                value.append("auto"_s);
            else
                appendInteger(value, random, 12, 3);
            return columnCount;
        case 2:
            if (variant < 15)
                value.append("auto-add"_s);
            else if (variant < 40) {
                value.append("add("_s);
                appendInteger(value, random, 5, 30);
                value.append(')');
            } else
                appendInteger(value, random, 8, 20);
            return mathDepth;
        case 3:
            if (variant < 15)
                value.append("auto"_s);
            else {
                appendInteger(value, random, 6, 3);
                if (variant < 30)
                    value.append(" auto"_s);
            }
            return maxLines;
        case 4:
            if (variant < 10)
                value.append("auto"_s);
            else
                appendTimeList(value, random, 3);
            return animationDuration;
        case 5:
            appendTimeList(value, random, 20);
            return animationDelay;
        case 6:
            appendTimeList(value, random, 3);
            return transitionDuration;
        case 7:
            appendTimeList(value, random, 20);
            return transitionDelay;
        case 8:
            if (variant < 10)
                value.append("none"_s);
            else
                appendIdentList(value, random, dashedIdents, ", "_s);
            return viewTimelineName;
        case 9:
            if (variant < 10)
                value.append("none"_s);
            else
                appendIdentList(value, random, dashedIdents, ", "_s);
            return anchorName;
        case 10:
            if (variant < 10)
                value.append("none"_s);
            else
                appendIdentList(value, random, customIdents, " "_s);
            return containerName;
        case 11:
            if (variant < 10)
                value.append("auto"_s);
            else
                appendIdentList(value, random, willChangeValues, ", "_s);
            return willChange;
        default:
            if (variant < 10)
                value.append("none"_s);
            else
                appendIdentList(value, random, transitionPropertyValues, ", "_s);
            return transitionProperty;
        }
    });
}

// MARK: - Shorthands.

static constexpr Property animationShorthand { CSSPropertyID::Animation, "animation"_s };
static constexpr Property transitionShorthand { CSSPropertyID::Transition, "transition"_s };
static constexpr Property backgroundShorthand { CSSPropertyID::Background, "background"_s };
static constexpr Property maskShorthand { CSSPropertyID::Mask, "mask"_s };

static constexpr ASCIILiteral animationNames[] = { "fade"_s, "slide-in"_s, "spin"_s, "pulse2"_s, "none"_s, "\"quoted name\""_s };
static constexpr ASCIILiteral easingFunctions[] = { "ease"_s, "linear"_s, "ease-in-out"_s, "step-start"_s, "steps(4, end)"_s, "cubic-bezier(0.1, 0.7, 1, 0.1)"_s };
static constexpr ASCIILiteral iterationCounts[] = { "infinite"_s, "2"_s, "0.5"_s };
static constexpr ASCIILiteral fillModes[] = { "none"_s, "forwards"_s, "backwards"_s, "both"_s };
static constexpr ASCIILiteral playStates[] = { "running"_s, "paused"_s };
static constexpr ASCIILiteral transitionBehaviors[] = { "normal"_s, "allow-discrete"_s };
static constexpr ASCIILiteral layerImages[] = { "none"_s, "url(a.png)"_s, "linear-gradient(red, blue)"_s };
static constexpr ASCIILiteral positionKeywords[] = { "center"_s, "left"_s, "right"_s, "top"_s, "bottom"_s };
static constexpr ASCIILiteral sizeKeywords[] = { "auto"_s, "cover"_s, "contain"_s };
static constexpr ASCIILiteral repeatStyles[] = { "repeat"_s, "no-repeat"_s, "repeat-x"_s, "repeat-y"_s, "space"_s, "round"_s, "repeat no-repeat"_s };
static constexpr ASCIILiteral backgroundAttachments[] = { "scroll"_s, "fixed"_s, "local"_s };
static constexpr ASCIILiteral layerBoxes[] = { "border-box"_s, "padding-box"_s, "content-box"_s };
static constexpr ASCIILiteral layerColors[] = { "red"_s, "#123456"_s, "transparent"_s, "rgb(1, 2, 3)"_s };
static constexpr ASCIILiteral maskComposites[] = { "add"_s, "subtract"_s, "intersect"_s, "exclude"_s };

// Appends one component of an item, after a space unless it is the first.
static void appendComponent(StringBuilder& value, bool& first, ASCIILiteral text)
{
    if (!first)
        value.append(' ');
    first = false;
    value.append(text);
}

// The space before a component the caller appends, unless it is the first.
static void appendComponentSeparator(StringBuilder& value, bool& first)
{
    if (!first)
        value.append(' ');
    first = false;
}

static void appendAnimationItem(StringBuilder& value, Random& random)
{
    bool first = true;
    if (random.percent(85))
        appendComponent(value, first, random.pick(animationNames));
    if (random.percent(80)) {
        appendComponentSeparator(value, first);
        appendTime(value, random, 0);
        if (random.percent(40)) {
            value.append(' ');
            appendTime(value, random, 20);
        }
    }
    if (random.percent(50))
        appendComponent(value, first, random.pick(easingFunctions));
    if (random.percent(30))
        appendComponent(value, first, random.pick(iterationCounts));
    if (random.percent(30))
        appendComponent(value, first, random.pick(animationDirections));
    if (random.percent(30))
        appendComponent(value, first, random.pick(fillModes));
    if (random.percent(15))
        appendComponent(value, first, random.pick(playStates));
    if (first)
        value.append("1s"_s);
}

static void appendTransitionItem(StringBuilder& value, Random& random)
{
    bool first = true;
    if (random.percent(80))
        appendComponent(value, first, random.pick(transitionPropertyValues));
    if (random.percent(85)) {
        appendComponentSeparator(value, first);
        appendTime(value, random, 0);
    }
    if (random.percent(50))
        appendComponent(value, first, random.pick(easingFunctions));
    if (random.percent(40)) {
        appendComponentSeparator(value, first);
        appendTime(value, random, 20);
    }
    if (random.percent(15))
        appendComponent(value, first, random.pick(transitionBehaviors));
    if (first)
        value.append("all"_s);
}

static void appendLayerPosition(StringBuilder& value, Random& random)
{
    if (random.percent(50)) {
        value.append(random.pick(positionKeywords));
        if (random.percent(50)) {
            value.append(' ');
            value.append(random.pick(positionKeywords));
        }
        return;
    }
    appendLengthPercentage(value, random, 10);
    value.append(' ');
    appendLengthPercentage(value, random, 10);
}

static void appendLayerSize(StringBuilder& value, Random& random)
{
    if (random.percent(40)) {
        value.append(random.pick(sizeKeywords));
        return;
    }
    appendLengthPercentage(value, random, 0);
    if (random.percent(50)) {
        value.append(' ');
        appendLengthPercentage(value, random, 0);
    }
}

// A background or mask layer, with a background color only if `allowsColor`.
static void appendLayer(StringBuilder& value, Random& random, bool isMask, bool allowsColor)
{
    bool first = true;
    if (random.percent(70))
        appendComponent(value, first, random.pick(layerImages));
    if (random.percent(50)) {
        appendComponentSeparator(value, first);
        appendLayerPosition(value, random);
        if (random.percent(50)) {
            value.append(" / "_s);
            appendLayerSize(value, random);
        }
    }
    if (random.percent(40))
        appendComponent(value, first, random.pick(repeatStyles));
    if (!isMask && random.percent(20))
        appendComponent(value, first, random.pick(backgroundAttachments));
    if (random.percent(30)) {
        appendComponent(value, first, random.pick(layerBoxes));
        if (random.percent(50))
            appendComponent(value, first, random.pick(layerBoxes));
    }
    if (isMask && random.percent(25))
        appendComponent(value, first, random.pick(maskComposites));
    if (isMask && random.percent(25))
        appendComponent(value, first, random.pick(maskModes));
    if (allowsColor && random.percent(40))
        appendComponent(value, first, random.pick(layerColors));
    if (first)
        value.append("none"_s);
}

// The animation, transition, background and mask shorthands, which parse each comma-separated item's longhands in turn:
// one to three items mixing names, times, easing functions, keywords, images, positions, sizes, boxes and colors. In
// one background in twenty-five any layer may have a color, which is invalid in a layer other than the last.
static Vector<Block> shorthandsBlocks()
{
    return generateBlocks(220, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        unsigned count = 1 + random.below(3);
        unsigned kind = index % 4;
        bool misplacedColor = kind == 2 && random.percent(4);
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                value.append(", "_s);
            switch (kind) {
            case 0:
                appendAnimationItem(value, random);
                break;
            case 1:
                appendTransitionItem(value, random);
                break;
            case 2:
                appendLayer(value, random, false, misplacedColor || i == count - 1);
                break;
            default:
                appendLayer(value, random, true, false);
                break;
            }
        }
        switch (kind) {
        case 0:
            return animationShorthand;
        case 1:
            return transitionShorthand;
        case 2:
            return backgroundShorthand;
        default:
            return maskShorthand;
        }
    });
}

// MARK: - Colors.

static constexpr Property colorProperties[] = {
    { CSSPropertyID::Color, "color"_s },
    { CSSPropertyID::BackgroundColor, "background-color"_s },
    { CSSPropertyID::BorderTopColor, "border-top-color"_s },
    { CSSPropertyID::BorderLeftColor, "border-left-color"_s },
    { CSSPropertyID::OutlineColor, "outline-color"_s },
    { CSSPropertyID::TextDecorationColor, "text-decoration-color"_s },
    { CSSPropertyID::ColumnRuleColor, "column-rule-color"_s },
    { CSSPropertyID::CaretColor, "caret-color"_s },
    { CSSPropertyID::Fill, "fill"_s },
    { CSSPropertyID::StopColor, "stop-color"_s },
    { CSSPropertyID::FloodColor, "flood-color"_s },
    { CSSPropertyID::WebkitTextFillColor, "-webkit-text-fill-color"_s },
};

static constexpr ASCIILiteral namedColors[] = {
    "red"_s, "blue"_s, "white"_s, "black"_s, "gray"_s, "orange"_s, "transparent"_s, "currentcolor"_s, "rebeccapurple"_s,
    "darkslategray"_s, "lightgoldenrodyellow"_s, "cornflowerblue"_s, "tomato"_s, "silver"_s, "teal"_s, "aliceblue"_s,
    "Navy"_s, "SteelBlue"_s, "GREEN"_s, "currentColor"_s, "Canvas"_s, "CanvasText"_s, "LinkText"_s, "ButtonFace"_s,
};

// Named colors without currentcolor, which -webkit-gradient() rejects.
static constexpr ASCIILiteral absoluteNamedColors[] = { "red"_s, "blue"_s, "white"_s, "black"_s, "transparent"_s, "teal"_s, "SteelBlue"_s };

static constexpr ASCIILiteral predefinedColorSpaces[] = {
    "srgb"_s, "srgb-linear"_s, "display-p3"_s, "a98-rgb"_s, "prophoto-rgb"_s, "rec2020"_s, "xyz"_s, "xyz-d50"_s, "xyz-d65"_s,
};

static constexpr ASCIILiteral rectangularColorSpaces[] = {
    "srgb"_s, "srgb-linear"_s, "display-p3"_s, "a98-rgb"_s, "prophoto-rgb"_s, "rec2020"_s, "lab"_s, "oklab"_s, "xyz"_s,
    "xyz-d50"_s, "xyz-d65"_s,
};

static constexpr ASCIILiteral polarColorSpaces[] = { "hsl"_s, "hwb"_s, "lch"_s, "oklch"_s };
static constexpr ASCIILiteral hueInterpolationMethods[] = { "shorter"_s, "longer"_s, "increasing"_s, "decreasing"_s };

// Three, four, six and eight digits, in both cases.
static void appendHexColor(StringBuilder& value, Random& random)
{
    static constexpr unsigned lengths[] = { 3, 3, 4, 6, 6, 6, 8 };
    static constexpr char digits[] = "0123456789abcdefABCDEF";
    unsigned length = random.pick(lengths);
    value.append('#');
    for (unsigned i = 0; i < length; ++i) {
        unsigned digit = random.below(22);
        value.append(digits[digit]);
    }
}

static void appendFraction(StringBuilder& value, Random& random, unsigned negativeChance)
{
    if (random.percent(negativeChance))
        value.append('-');
    value.append("0."_s);
    appendDigits(value, random, 1 + random.below(3));
}

static void appendAlpha(StringBuilder& value, Random& random)
{
    unsigned variant = random.below(10);
    if (variant < 3) {
        appendNumber(value, random, 100, 0);
        value.append('%');
    } else if (variant < 9)
        appendFraction(value, random, 0);
    else
        value.append(random.percent(50) ? '0' : '1');
}

static void appendHue(StringBuilder& value, Random& random)
{
    unsigned variant = random.below(10);
    if (!variant)
        value.append("none"_s);
    else if (variant < 4)
        appendAngle(value, random);
    else
        appendSignedNumber(value, random, 360, 1, 10);
}

// A channel of a modern color function, up to `maximum` (a fraction when it is 1).
struct Channel {
    unsigned maximum;
    bool isSigned;
    bool isHue;
};

static constexpr Channel rgbChannel { 255, false, false };
static constexpr Channel percentChannel { 100, false, false };
static constexpr Channel hueChannel { 360, false, true };
static constexpr Channel labChannel { 125, true, false };
static constexpr Channel chromaChannel { 150, false, false };
static constexpr Channel unitChannel { 1, false, false };
static constexpr Channel signedUnitChannel { 1, true, false };

// Numbers, percentages, none and calc().
static void appendChannel(StringBuilder& value, Random& random, const Channel& channel)
{
    if (channel.isHue) {
        appendHue(value, random);
        return;
    }
    unsigned negativeChance = channel.isSigned ? 25 : 0;
    unsigned variant = random.below(100);
    if (variant < 5)
        value.append("none"_s);
    else if (variant < 10) {
        value.append("calc("_s);
        appendNumber(value, random, channel.maximum, 2);
        value.append(" / 2)"_s);
    } else if (variant < 35) {
        appendSignedNumber(value, random, 100, 1, negativeChance);
        value.append('%');
    } else if (channel.maximum == 1)
        appendFraction(value, random, negativeChance);
    else
        appendSignedNumber(value, random, channel.maximum, 2, negativeChance);
}

struct ModernColorFunction {
    ASCIILiteral name;
    std::array<Channel, 3> channels;
};

static constexpr ModernColorFunction modernColorFunctions[] = {
    { "rgb"_s, { rgbChannel, rgbChannel, rgbChannel } },
    { "rgba"_s, { rgbChannel, rgbChannel, rgbChannel } },
    { "hsl"_s, { hueChannel, percentChannel, percentChannel } },
    { "hsla"_s, { hueChannel, percentChannel, percentChannel } },
    { "hwb"_s, { hueChannel, percentChannel, percentChannel } },
    { "lab"_s, { percentChannel, labChannel, labChannel } },
    { "lch"_s, { percentChannel, chromaChannel, hueChannel } },
    { "oklab"_s, { unitChannel, signedUnitChannel, signedUnitChannel } },
    { "oklch"_s, { unitChannel, unitChannel, hueChannel } },
};

static void appendOptionalAlpha(StringBuilder& value, Random& random)
{
    unsigned variant = random.below(100);
    if (variant < 60)
        return;
    value.append(" / "_s);
    if (variant < 65)
        value.append("none"_s);
    else
        appendAlpha(value, random);
}

static void appendModernColor(StringBuilder& value, Random& random, const ModernColorFunction& function)
{
    value.append(function.name, '(');
    for (unsigned i = 0; i < 3; ++i) {
        if (i)
            value.append(' ');
        appendChannel(value, random, function.channels[i]);
    }
    appendOptionalAlpha(value, random);
    value.append(')');
}

// rgb() and rgba() with commas: all numbers or all percentages.
static void appendLegacyRGB(StringBuilder& value, Random& random)
{
    bool hasAlpha = random.percent(40);
    value.append(hasAlpha ? "rgba("_s : "rgb("_s);
    bool percentages = random.percent(20);
    for (unsigned i = 0; i < 3; ++i) {
        if (i)
            value.append(", "_s);
        if (percentages) {
            appendNumber(value, random, 100, 1);
            value.append('%');
        } else
            appendInteger(value, random, 255, 0);
    }
    if (hasAlpha) {
        value.append(", "_s);
        appendAlpha(value, random);
    }
    value.append(')');
}

// hsl() and hsla() with commas.
static void appendLegacyHSL(StringBuilder& value, Random& random)
{
    bool hasAlpha = random.percent(40);
    value.append(hasAlpha ? "hsla("_s : "hsl("_s);
    if (random.percent(30))
        appendAngle(value, random);
    else
        appendNumber(value, random, 360, 1);
    for (unsigned i = 0; i < 2; ++i) {
        value.append(", "_s);
        appendNumber(value, random, 100, 1);
        value.append('%');
    }
    if (hasAlpha) {
        value.append(", "_s);
        appendAlpha(value, random);
    }
    value.append(')');
}

static void appendPredefinedColor(StringBuilder& value, Random& random)
{
    value.append("color("_s);
    value.append(random.pick(predefinedColorSpaces));
    for (unsigned i = 0; i < 3; ++i) {
        value.append(' ');
        appendChannel(value, random, unitChannel);
    }
    appendOptionalAlpha(value, random);
    value.append(')');
}

static void appendKeywordOrHexColor(StringBuilder& value, Random& random)
{
    if (random.percent(50))
        appendHexColor(value, random);
    else
        value.append(random.pick(namedColors));
}

// Every color function but the relative forms and color-mix().
static void appendFunctionalColor(StringBuilder& value, Random& random)
{
    unsigned variant = random.below(16);
    if (variant < 3)
        appendLegacyRGB(value, random);
    else if (variant < 5)
        appendLegacyHSL(value, random);
    else if (variant < 14)
        appendModernColor(value, random, modernColorFunctions[variant - 5]);
    else if (variant < 15)
        appendPredefinedColor(value, random);
    else {
        value.append("light-dark("_s);
        appendKeywordOrHexColor(value, random);
        value.append(", "_s);
        appendKeywordOrHexColor(value, random);
        value.append(')');
    }
}

static void appendColor(StringBuilder& value, Random& random)
{
    unsigned variant = random.below(10);
    if (variant < 4)
        appendHexColor(value, random);
    else if (variant < 7)
        value.append(random.pick(namedColors));
    else
        appendFunctionalColor(value, random);
}

// Colors that are not currentcolor.
static void appendAbsoluteColor(StringBuilder& value, Random& random)
{
    unsigned variant = random.below(10);
    if (variant < 4)
        appendHexColor(value, random);
    else if (variant < 7)
        value.append(random.pick(absoluteNamedColors));
    else if (variant < 9)
        appendLegacyRGB(value, random);
    else
        appendModernColor(value, random, modernColorFunctions[0]);
}

// Hex colors and named colors, the system colors among them.
static Vector<Block> colorsHexNamedBlocks()
{
    return generateBlocks(221, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        auto& property = colorProperties[index % std::size(colorProperties)];
        appendKeywordOrHexColor(value, random);
        return property;
    });
}

// rgb(), rgba(), hsl() and hsla() with commas and without, hwb(), lab(), lch(), oklab(), oklch(), color() in every
// predefined color space and light-dark(), with none and calc() in channels and an optional alpha.
static Vector<Block> colorsFunctionalBlocks()
{
    return generateBlocks(222, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        auto& property = colorProperties[index % std::size(colorProperties)];
        appendFunctionalColor(value, random);
        return property;
    });
}

// MARK: - Relative colors.

struct RelativeColorFunction {
    ASCIILiteral name;
    ASCIILiteral colorSpace;
    std::array<ASCIILiteral, 3> keywords;
};

static constexpr RelativeColorFunction relativeColorFunctions[] = {
    { "rgb"_s, { }, { "r"_s, "g"_s, "b"_s } },
    { "rgb"_s, { }, { "r"_s, "g"_s, "b"_s } },
    { "hsl"_s, { }, { "h"_s, "s"_s, "l"_s } },
    { "hwb"_s, { }, { "h"_s, "w"_s, "b"_s } },
    { "lab"_s, { }, { "l"_s, "a"_s, "b"_s } },
    { "lch"_s, { }, { "l"_s, "c"_s, "h"_s } },
    { "oklab"_s, { }, { "l"_s, "a"_s, "b"_s } },
    { "oklch"_s, { }, { "l"_s, "c"_s, "h"_s } },
    { "color"_s, "srgb"_s, { "r"_s, "g"_s, "b"_s } },
    { "color"_s, "display-p3"_s, { "r"_s, "g"_s, "b"_s } },
    { "color"_s, "rec2020"_s, { "r"_s, "g"_s, "b"_s } },
    { "color"_s, "xyz-d65"_s, { "x"_s, "y"_s, "z"_s } },
};

// The channel's own keyword, another channel's, calc() of a keyword, none or a number.
static void appendRelativeChannel(StringBuilder& value, Random& random, const RelativeColorFunction& function, unsigned index)
{
    auto keyword = function.keywords[index];
    unsigned variant = random.below(100);
    if (variant < 50)
        value.append(keyword);
    else if (variant < 60) {
        unsigned other = random.below(3);
        value.append(function.keywords[other]);
    } else if (variant < 75) {
        value.append("calc("_s, keyword, " * 0."_s);
        appendDigits(value, random, 1 + random.below(2));
        value.append(')');
    } else if (variant < 88) {
        value.append("calc("_s, keyword, additiveOperator(random));
        appendNumber(value, random, 20, 1);
        value.append(')');
    } else if (variant < 93)
        value.append("none"_s);
    else
        appendNumber(value, random, 1, 2);
}

static void appendRelativeColor(StringBuilder&, Random&, unsigned depth);

static void appendOriginColor(StringBuilder& value, Random& random, unsigned depth)
{
    unsigned variant = random.below(100);
    if (variant < 35)
        appendHexColor(value, random);
    else if (variant < 65)
        value.append(random.pick(namedColors));
    else if (variant < 92 || depth)
        appendFunctionalColor(value, random);
    else
        appendRelativeColor(value, random, depth + 1);
}

static void appendRelativeColor(StringBuilder& value, Random& random, unsigned depth)
{
    auto& function = random.pick(relativeColorFunctions);
    value.append(function.name, "(from "_s);
    appendOriginColor(value, random, depth);
    if (!function.colorSpace.isNull())
        value.append(' ', function.colorSpace);
    for (unsigned i = 0; i < 3; ++i) {
        value.append(' ');
        appendRelativeChannel(value, random, function, i);
    }
    unsigned alpha = random.below(10);
    if (alpha < 2)
        value.append(" / alpha"_s);
    else if (alpha < 4)
        value.append(" / calc(alpha * 0.5)"_s);
    else if (alpha < 5) {
        value.append(" / "_s);
        appendAlpha(value, random);
    }
    value.append(')');
}

// Relative colors of every function, from hex, named, functional and (rarely) relative origins, with channel keywords
// in their own places and swapped, calc() of channel keywords, none and numbers.
static Vector<Block> colorsRelativeBlocks()
{
    return generateBlocks(223, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        auto& property = colorProperties[index % std::size(colorProperties)];
        appendRelativeColor(value, random, 0);
        return property;
    });
}

// MARK: - color-mix().

static void appendColorInterpolationMethod(StringBuilder& value, Random& random)
{
    value.append("in "_s);
    if (random.percent(65)) {
        value.append(random.pick(rectangularColorSpaces));
        return;
    }
    value.append(random.pick(polarColorSpaces));
    if (random.percent(40)) {
        value.append(' ');
        value.append(random.pick(hueInterpolationMethods));
        value.append(" hue"_s);
    }
}

static void appendMixPercentage(StringBuilder& value, Random& random)
{
    appendNumber(value, random, 99, 1);
    value.append('%');
}

static void appendColorMix(StringBuilder&, Random&, unsigned depth);

// A color with an optional percentage before or after it.
static void appendColorMixComponent(StringBuilder& value, Random& random, unsigned depth)
{
    unsigned placement = random.below(10);
    if (placement < 2) {
        appendMixPercentage(value, random);
        value.append(' ');
    }
    if (!depth && random.percent(6))
        appendColorMix(value, random, depth + 1);
    else
        appendColor(value, random);
    if (placement >= 6) {
        value.append(' ');
        appendMixPercentage(value, random);
    }
}

static void appendColorMix(StringBuilder& value, Random& random, unsigned depth)
{
    value.append("color-mix("_s);
    if (random.percent(90)) {
        appendColorInterpolationMethod(value, random);
        value.append(", "_s);
    }
    unsigned count = 2;
    unsigned variant = random.below(100);
    if (variant < 6)
        count = 3;
    else if (variant < 9)
        count = 1;
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            value.append(", "_s);
        appendColorMixComponent(value, random, depth);
    }
    value.append(')');
}

// color-mix() in every rectangular and polar color space, with each hue interpolation method, without a color space,
// with percentages before, after and on neither color, with one, two and three colors, and nested.
static Vector<Block> colorMixBlocks()
{
    return generateBlocks(224, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        auto& property = colorProperties[index % std::size(colorProperties)];
        appendColorMix(value, random, 0);
        return property;
    });
}

// MARK: - Gradients.

static constexpr Property backgroundImage { CSSPropertyID::BackgroundImage, "background-image"_s };
static constexpr Property listStyleImage { CSSPropertyID::ListStyleImage, "list-style-image"_s };
static constexpr Property borderImageSource { CSSPropertyID::BorderImageSource, "border-image-source"_s };
static constexpr Property maskImage { CSSPropertyID::MaskImage, "mask-image"_s };

static constexpr Property imageProperties[] = { backgroundImage, listStyleImage, borderImageSource, maskImage };

enum class StopPositions : bool { Linear, Angular };

static void appendStopPosition(StringBuilder& value, Random& random, StopPositions kind)
{
    unsigned variant = random.below(10);
    if (kind == StopPositions::Angular) {
        if (!variant)
            value.append('0');
        else if (variant < 5) {
            appendNumber(value, random, 100, 1);
            value.append('%');
        } else if (variant < 9)
            appendAngle(value, random);
        else
            appendCalcAngle(value, random);
        return;
    }
    if (variant < 6) {
        appendNumber(value, random, 100, 1);
        value.append('%');
    } else if (variant < 9)
        appendLength(value, random, 5);
    else
        appendCalcLengthPercentage(value, random);
}

// Two to five stops, one in ten with three to six more; each with no position, one or two, and color hints between
// stops where `allowsHints`.
static void appendColorStops(StringBuilder& value, Random& random, StopPositions kind, bool allowsHints)
{
    unsigned count = 2 + random.below(4);
    if (random.percent(10))
        count += 3 + random.below(4);
    for (unsigned i = 0; i < count; ++i) {
        if (i) {
            value.append(", "_s);
            if (allowsHints && random.percent(12)) {
                appendStopPosition(value, random, kind);
                value.append(", "_s);
            }
        }
        appendColor(value, random);
        unsigned positions = random.below(10);
        if (positions >= 4) {
            value.append(' ');
            appendStopPosition(value, random, kind);
        }
        if (positions >= 8) {
            value.append(' ');
            appendStopPosition(value, random, kind);
        }
    }
}

static constexpr ASCIILiteral sidesAndCorners[] = {
    "to top"_s, "to bottom"_s, "to left"_s, "to right"_s, "to top right"_s, "to bottom left"_s, "to left top"_s, "to right bottom"_s,
};

static void appendLinearGradient(StringBuilder& value, Random& random)
{
    bool repeating = random.percent(15);
    value.append(repeating ? "repeating-linear-gradient("_s : "linear-gradient("_s);
    unsigned prelude = random.below(20);
    if (prelude < 6) {
        appendAngle(value, random);
        value.append(", "_s);
    } else if (prelude < 7)
        value.append("0, "_s);
    else if (prelude < 8) {
        appendCalcAngle(value, random);
        value.append(", "_s);
    } else if (prelude < 13) {
        value.append(random.pick(sidesAndCorners));
        value.append(", "_s);
    } else if (prelude < 15) {
        appendColorInterpolationMethod(value, random);
        value.append(", "_s);
    } else if (prelude < 16) {
        value.append(random.pick(sidesAndCorners));
        value.append(' ');
        appendColorInterpolationMethod(value, random);
        value.append(", "_s);
    } else if (prelude < 17) {
        appendColorInterpolationMethod(value, random);
        value.append(' ');
        appendAngle(value, random);
        value.append(", "_s);
    }
    appendColorStops(value, random, StopPositions::Linear, true);
    value.append(')');
}

// MARK: - Positions.

static constexpr ASCIILiteral horizontalKeywords[] = { "left"_s, "center"_s, "right"_s };
static constexpr ASCIILiteral verticalKeywords[] = { "top"_s, "center"_s, "bottom"_s };
static constexpr ASCIILiteral horizontalEdges[] = { "left"_s, "right"_s };
static constexpr ASCIILiteral verticalEdges[] = { "top"_s, "bottom"_s };

static void appendPositionComponent(StringBuilder& value, Random& random, const ASCIILiteral (&keywords)[3])
{
    unsigned variant = random.below(20);
    if (variant < 9)
        value.append(random.pick(keywords));
    else if (variant < 19)
        appendLengthPercentage(value, random, 10);
    else
        appendCalcLengthPercentage(value, random);
}

static void appendEdgeOffset(StringBuilder& value, Random& random, const ASCIILiteral (&edges)[2])
{
    value.append(random.pick(edges));
    value.append(' ');
    appendLengthPercentage(value, random, 10);
}

// One, two or four components, and three where `allowsThree` (<bg-position>).
static void appendPosition(StringBuilder& value, Random& random, bool allowsThree)
{
    unsigned variant = random.below(allowsThree ? 12 : 10);
    if (variant < 2) {
        value.append(random.pick(positionKeywords));
        return;
    }
    if (variant < 3) {
        appendLengthPercentage(value, random, 10);
        return;
    }
    if (variant < 6) {
        appendPositionComponent(value, random, horizontalKeywords);
        value.append(' ');
        appendPositionComponent(value, random, verticalKeywords);
        return;
    }
    if (variant < 7) {
        value.append(random.pick(verticalEdges));
        value.append(' ');
        value.append(random.pick(horizontalEdges));
        return;
    }
    if (variant < 10) {
        bool verticalFirst = random.percent(30);
        appendEdgeOffset(value, random, verticalFirst ? verticalEdges : horizontalEdges);
        value.append(' ');
        appendEdgeOffset(value, random, verticalFirst ? horizontalEdges : verticalEdges);
        return;
    }
    switch (random.below(3)) {
    case 0:
        appendEdgeOffset(value, random, horizontalEdges);
        value.append(' ');
        value.append(random.pick(verticalKeywords));
        break;
    case 1:
        value.append(random.pick(horizontalKeywords));
        value.append(' ');
        appendEdgeOffset(value, random, verticalEdges);
        break;
    default:
        value.append(random.pick(verticalEdges));
        value.append(' ');
        appendEdgeOffset(value, random, horizontalEdges);
        break;
    }
}

static void appendAxisPosition(StringBuilder& value, Random& random, const ASCIILiteral (&edges)[2])
{
    unsigned variant = random.below(10);
    if (variant < 2)
        value.append("center"_s);
    else if (variant < 4)
        value.append(random.pick(edges));
    else if (variant < 7)
        appendLengthPercentage(value, random, 10);
    else
        appendEdgeOffset(value, random, edges);
}

// MARK: - Radial and conic gradients.

static constexpr ASCIILiteral radialExtents[] = { "closest-side"_s, "closest-corner"_s, "farthest-side"_s, "farthest-corner"_s };

static void appendRadialGradient(StringBuilder& value, Random& random)
{
    bool repeating = random.percent(15);
    value.append(repeating ? "repeating-radial-gradient("_s : "radial-gradient("_s);
    bool hasPrelude = true;
    bool forcesPosition = false;
    switch (random.below(10)) {
    case 0:
        hasPrelude = false;
        break;
    case 1:
        value.append(random.percent(50) ? "circle"_s : "ellipse"_s);
        break;
    case 2:
        value.append("circle "_s);
        appendLength(value, random, 0);
        break;
    case 3:
        value.append("ellipse "_s);
        appendLengthPercentage(value, random, 0);
        value.append(' ');
        appendLengthPercentage(value, random, 0);
        break;
    case 4:
        value.append(random.pick(radialExtents));
        break;
    case 5:
        value.append(random.percent(50) ? "circle "_s : "ellipse "_s);
        value.append(random.pick(radialExtents));
        break;
    case 6:
        value.append(random.pick(radialExtents));
        value.append(random.percent(50) ? " circle"_s : " ellipse"_s);
        break;
    case 7:
        appendLength(value, random, 0);
        break;
    case 8:
        appendLengthPercentage(value, random, 0);
        value.append(' ');
        appendLengthPercentage(value, random, 0);
        break;
    default:
        hasPrelude = false;
        forcesPosition = true;
        break;
    }
    if (forcesPosition || random.percent(45)) {
        if (hasPrelude)
            value.append(' ');
        value.append("at "_s);
        appendPosition(value, random, false);
        hasPrelude = true;
    }
    if (random.percent(10)) {
        if (hasPrelude)
            value.append(' ');
        appendColorInterpolationMethod(value, random);
        hasPrelude = true;
    }
    if (hasPrelude)
        value.append(", "_s);
    appendColorStops(value, random, StopPositions::Linear, true);
    value.append(')');
}

static void appendConicGradient(StringBuilder& value, Random& random)
{
    bool repeating = random.percent(15);
    value.append(repeating ? "repeating-conic-gradient("_s : "conic-gradient("_s);
    bool hasPrelude = false;
    if (random.percent(50)) {
        value.append("from "_s);
        unsigned variant = random.below(10);
        if (!variant)
            value.append('0');
        else if (variant < 9)
            appendAngle(value, random);
        else
            appendCalcAngle(value, random);
        hasPrelude = true;
    }
    if (random.percent(40)) {
        if (hasPrelude)
            value.append(' ');
        value.append("at "_s);
        appendPosition(value, random, false);
        hasPrelude = true;
    }
    if (random.percent(15)) {
        if (hasPrelude)
            value.append(' ');
        appendColorInterpolationMethod(value, random);
        hasPrelude = true;
    }
    if (hasPrelude)
        value.append(", "_s);
    appendColorStops(value, random, StopPositions::Angular, true);
    value.append(')');
}

// One gradient, or in one background-image or mask-image in seven, two.
template<typename Appender>
static Vector<Block> gradientBlocks(uint64_t seed, Appender&& appendGradient)
{
    return generateBlocks(seed, [&](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        auto& property = imageProperties[index % std::size(imageProperties)];
        appendGradient(value, random);
        bool isList = property.id == CSSPropertyID::BackgroundImage || property.id == CSSPropertyID::MaskImage;
        if (isList && random.percent(14)) {
            value.append(", "_s);
            appendGradient(value, random);
        }
        return property;
    });
}

// linear-gradient() and repeating-linear-gradient() with no line, an angle (unitless zero and calc() among them), a
// side or corner, and a color interpolation method before or after it; stops with zero, one or two positions and hints.
static Vector<Block> linearGradientsBlocks()
{
    return gradientBlocks(225, appendLinearGradient);
}

// radial-gradient() and repeating-radial-gradient() with every combination of shape, extent keyword, lengths and
// `at <position>`, and a color interpolation method.
static Vector<Block> radialGradientsBlocks()
{
    return gradientBlocks(226, appendRadialGradient);
}

// conic-gradient() and repeating-conic-gradient() with `from <angle>`, `at <position>` and a color interpolation
// method, each optional; stops with angles, percentages and unitless zero.
static Vector<Block> conicGradientsBlocks()
{
    return gradientBlocks(227, appendConicGradient);
}

static constexpr Property objectPosition { CSSPropertyID::ObjectPosition, "object-position"_s };
static constexpr Property offsetPosition { CSSPropertyID::OffsetPosition, "offset-position"_s };
static constexpr Property offsetAnchor { CSSPropertyID::OffsetAnchor, "offset-anchor"_s };
static constexpr Property backgroundPosition { CSSPropertyID::BackgroundPosition, "background-position"_s };
static constexpr Property maskPosition { CSSPropertyID::MaskPosition, "mask-position"_s };
static constexpr Property backgroundPositionX { CSSPropertyID::BackgroundPositionX, "background-position-x"_s };
static constexpr Property backgroundPositionY { CSSPropertyID::BackgroundPositionY, "background-position-y"_s };

// object-position, offset-position and offset-anchor with one, two and four components; background-position (three
// components too) and mask-position lists of one to three; background-position-x and -y lists of keywords, offsets
// and keywords with offsets.
static Vector<Block> positionsBlocks()
{
    return generateBlocks(228, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        switch (index % 7) {
        case 0:
            appendPosition(value, random, false);
            return objectPosition;
        case 1:
            if (random.percent(8))
                value.append(random.percent(50) ? "normal"_s : "auto"_s);
            else
                appendPosition(value, random, false);
            return offsetPosition;
        case 2:
            if (random.percent(8))
                value.append("auto"_s);
            else
                appendPosition(value, random, false);
            return offsetAnchor;
        default:
            break;
        }
        unsigned kind = index % 7;
        unsigned count = 1;
        if (random.percent(25))
            count += 1 + random.below(2);
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                value.append(", "_s);
            if (kind == 3)
                appendPosition(value, random, true);
            else if (kind == 4)
                appendPosition(value, random, false);
            else
                appendAxisPosition(value, random, kind == 5 ? horizontalEdges : verticalEdges);
        }
        if (kind == 3)
            return backgroundPosition;
        if (kind == 4)
            return maskPosition;
        return kind == 5 ? backgroundPositionX : backgroundPositionY;
    });
}

// MARK: - Background and mask layers.

static constexpr Property webkitMaskShorthand { CSSPropertyID::WebkitMask, "-webkit-mask"_s };

static constexpr ASCIILiteral layerURLs[] = {
    "url(https://example.com/a.png)"_s, "url(\"https://example.com/b.svg#c\")"_s, "url('https://example.com/d.webp')"_s,
};

static void appendLayerImage(StringBuilder& value, Random& random)
{
    unsigned variant = random.below(10);
    if (variant < 2)
        value.append("none"_s);
    else if (variant < 5)
        value.append(random.pick(layerURLs));
    else if (variant < 8)
        appendLinearGradient(value, random);
    else if (variant < 9)
        appendRadialGradient(value, random);
    else
        appendConicGradient(value, random);
}

// A layer of the background, mask or -webkit-mask shorthand, with a background color only if `allowsColor`.
static void appendFullLayer(StringBuilder& value, Random& random, const Property& property, bool allowsColor)
{
    bool isMask = property.id != CSSPropertyID::Background;
    bool first = true;
    if (random.percent(75)) {
        appendComponentSeparator(value, first);
        appendLayerImage(value, random);
    }
    if (random.percent(55)) {
        appendComponentSeparator(value, first);
        appendPosition(value, random, property.id != CSSPropertyID::Mask);
        if (random.percent(40)) {
            value.append(" / "_s);
            appendLayerSize(value, random);
        }
    }
    if (random.percent(40))
        appendComponent(value, first, random.pick(repeatStyles));
    if (!isMask && random.percent(20))
        appendComponent(value, first, random.pick(backgroundAttachments));
    if (random.percent(30)) {
        appendComponent(value, first, random.pick(layerBoxes));
        if (random.percent(50))
            appendComponent(value, first, random.pick(layerBoxes));
    }
    if (property.id == CSSPropertyID::Mask && random.percent(25))
        appendComponent(value, first, random.pick(maskComposites));
    if (property.id == CSSPropertyID::Mask && random.percent(25))
        appendComponent(value, first, random.pick(maskModes));
    if (allowsColor && random.percent(50)) {
        appendComponentSeparator(value, first);
        appendColor(value, random);
    }
    if (first)
        value.append("none"_s);
}

// The background, mask and -webkit-mask shorthands with one to four layers of urls, gradients, positions of every
// form with sizes, repeats, attachments, boxes, mask composites and modes, and colors of every form in the last
// background layer.
static Vector<Block> backgroundLayersBlocks()
{
    return generateBlocks(229, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        static constexpr const Property* properties[] = { &backgroundShorthand, &backgroundShorthand, &maskShorthand, &webkitMaskShorthand };
        auto& property = *properties[index % std::size(properties)];
        unsigned count = 1 + random.below(4);
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                value.append(", "_s);
            appendFullLayer(value, random, property, property.id == CSSPropertyID::Background && i == count - 1);
        }
        return property;
    });
}

// MARK: - Prefixed gradients.

static constexpr ASCIILiteral prefixedSides[] = { "top"_s, "bottom"_s, "left"_s, "right"_s, "top left"_s, "bottom right"_s, "left bottom"_s, "right top"_s };
static constexpr ASCIILiteral prefixedRadialExtents[] = { "contain"_s, "cover"_s, "closest-side"_s, "closest-corner"_s, "farthest-side"_s, "farthest-corner"_s };

static void appendPrefixedLinearGradient(StringBuilder& value, Random& random)
{
    bool repeating = random.percent(15);
    value.append(repeating ? "-webkit-repeating-linear-gradient("_s : "-webkit-linear-gradient("_s);
    unsigned prelude = random.below(10);
    if (prelude < 3) {
        value.append(random.pick(prefixedSides));
        value.append(", "_s);
    } else if (prelude < 6) {
        appendAngle(value, random);
        value.append(", "_s);
    }
    appendColorStops(value, random, StopPositions::Linear, false);
    value.append(')');
}

static void appendPrefixedRadialGradient(StringBuilder& value, Random& random)
{
    bool repeating = random.percent(15);
    value.append(repeating ? "-webkit-repeating-radial-gradient("_s : "-webkit-radial-gradient("_s);
    unsigned position = random.below(10);
    if (position < 2) {
        value.append(random.pick(positionKeywords));
        value.append(", "_s);
    } else if (position < 4) {
        value.append(random.pick(horizontalKeywords));
        value.append(' ');
        value.append(random.pick(verticalKeywords));
        value.append(", "_s);
    } else if (position < 5) {
        appendLengthPercentage(value, random, 10);
        value.append(' ');
        appendLengthPercentage(value, random, 10);
        value.append(", "_s);
    }
    switch (random.below(6)) {
    case 0:
        value.append(random.percent(50) ? "circle, "_s : "ellipse, "_s);
        break;
    case 1:
        value.append(random.pick(prefixedRadialExtents));
        value.append(", "_s);
        break;
    case 2:
        value.append(random.percent(50) ? "circle "_s : "ellipse "_s);
        value.append(random.pick(prefixedRadialExtents));
        value.append(", "_s);
        break;
    case 3:
        appendLengthPercentage(value, random, 0);
        value.append(' ');
        appendLengthPercentage(value, random, 0);
        value.append(", "_s);
        break;
    default:
        break;
    }
    appendColorStops(value, random, StopPositions::Linear, false);
    value.append(')');
}

static void appendDeprecatedGradientPoint(StringBuilder& value, Random& random)
{
    static constexpr ASCIILiteral horizontal[] = { "left"_s, "right"_s, "center"_s };
    static constexpr ASCIILiteral vertical[] = { "top"_s, "bottom"_s, "center"_s };
    for (unsigned i = 0; i < 2; ++i) {
        if (i)
            value.append(' ');
        unsigned variant = random.below(10);
        if (variant < 5)
            value.append(random.pick(i ? vertical : horizontal));
        else if (variant < 8) {
            appendNumber(value, random, 100, 0);
            value.append('%');
        } else
            appendNumber(value, random, 200, 1);
    }
}

// -webkit-gradient(linear, ...) and -webkit-gradient(radial, ...) with from(), to() and color-stop() stops.
static void appendDeprecatedGradient(StringBuilder& value, Random& random)
{
    bool isRadial = random.percent(35);
    value.append(isRadial ? "-webkit-gradient(radial, "_s : "-webkit-gradient(linear, "_s);
    appendDeprecatedGradientPoint(value, random);
    if (isRadial) {
        value.append(", "_s);
        appendNumber(value, random, 50, 1);
    }
    value.append(", "_s);
    appendDeprecatedGradientPoint(value, random);
    if (isRadial) {
        value.append(", "_s);
        appendNumber(value, random, 200, 1);
    }
    unsigned count = random.below(6);
    for (unsigned i = 0; i < count; ++i) {
        unsigned kind = random.below(4);
        if (!kind)
            value.append(", from("_s);
        else if (kind == 1)
            value.append(", to("_s);
        else {
            value.append(", color-stop("_s);
            if (random.percent(50))
                appendFraction(value, random, 0);
            else {
                appendNumber(value, random, 100, 0);
                value.append('%');
            }
            value.append(", "_s);
        }
        appendAbsoluteColor(value, random);
        value.append(')');
    }
    value.append(')');
}

static void appendPrefixedGradient(StringBuilder& value, Random& random)
{
    unsigned variant = random.below(10);
    if (variant < 4)
        appendPrefixedLinearGradient(value, random);
    else if (variant < 7)
        appendPrefixedRadialGradient(value, random);
    else
        appendDeprecatedGradient(value, random);
}

// -webkit-linear-gradient(), -webkit-radial-gradient(), their repeating forms and -webkit-gradient().
static Vector<Block> prefixedGradientsBlocks()
{
    return gradientBlocks(230, appendPrefixedGradient);
}

// MARK: - Shadows, border radii, border images and other images.

static constexpr Property boxShadow { CSSPropertyID::BoxShadow, "box-shadow"_s };
static constexpr Property webkitBoxShadow { CSSPropertyID::WebkitBoxShadow, "-webkit-box-shadow"_s };
static constexpr Property borderRadius { CSSPropertyID::BorderRadius, "border-radius"_s };
static constexpr Property webkitBorderRadius { CSSPropertyID::WebkitBorderRadius, "-webkit-border-radius"_s };
static constexpr Property borderImage { CSSPropertyID::BorderImage, "border-image"_s };
static constexpr Property webkitBorderImage { CSSPropertyID::WebkitBorderImage, "-webkit-border-image"_s };
static constexpr Property webkitMaskBoxImage { CSSPropertyID::WebkitMaskBoxImage, "-webkit-mask-box-image"_s };
static constexpr Property webkitBoxReflect { CSSPropertyID::WebkitBoxReflect, "-webkit-box-reflect"_s };

static void appendShadow(StringBuilder& value, Random& random)
{
    bool inset = random.percent(15);
    bool insetFirst = random.percent(50);
    unsigned colorPlace = random.below(10);
    if (inset && insetFirst)
        value.append("inset "_s);
    if (colorPlace < 3) {
        appendColor(value, random);
        value.append(' ');
    }
    appendLength(value, random, 30);
    value.append(' ');
    appendLength(value, random, 30);
    unsigned lengths = random.below(3);
    if (lengths) {
        value.append(' ');
        appendLength(value, random, 0);
    }
    if (lengths == 2) {
        value.append(' ');
        appendLength(value, random, 30);
    }
    if (colorPlace >= 3 && colorPlace < 8) {
        value.append(' ');
        appendColor(value, random);
    }
    if (inset && !insetFirst)
        value.append(" inset"_s);
}

static void appendBorderRadiusValues(StringBuilder& value, Random& random, unsigned maximumCount)
{
    unsigned count = 1 + random.below(maximumCount);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            value.append(' ');
        appendRadius(value, random);
    }
}

static void appendBorderImageSource(StringBuilder& value, Random& random)
{
    unsigned variant = random.below(10);
    if (variant < 4)
        value.append(random.pick(layerURLs));
    else if (variant < 7)
        appendLinearGradient(value, random);
    else if (variant < 8)
        appendRadialGradient(value, random);
    else
        value.append("none"_s);
}

static void appendBorderImageNumbers(StringBuilder& value, Random& random, bool allowsAuto, bool allowsPercentage)
{
    unsigned count = 1 + random.below(4);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            value.append(' ');
        unsigned variant = random.below(10);
        if (allowsAuto && !variant)
            value.append("auto"_s);
        else if (variant < 5)
            appendNumber(value, random, 30, allowsPercentage ? 0 : 1);
        else if (allowsPercentage && variant < 8) {
            appendNumber(value, random, 100, 0);
            value.append('%');
        } else
            appendLength(value, random, 0);
    }
}

// <source> <slice> [/ <width> [/ <outset>]] <repeat>, each part optional but the source, in either of two orders.
static void appendBorderImage(StringBuilder& value, Random& random)
{
    static constexpr ASCIILiteral repeats[] = { "stretch"_s, "repeat"_s, "round"_s, "space"_s };
    bool repeatFirst = random.percent(20);
    bool hasRepeat = random.percent(50);
    if (hasRepeat && repeatFirst) {
        value.append(random.pick(repeats));
        value.append(' ');
    }
    appendBorderImageSource(value, random);
    if (random.percent(80)) {
        value.append(' ');
        bool fillFirst = random.percent(30);
        bool fill = random.percent(25);
        if (fill && fillFirst)
            value.append("fill "_s);
        unsigned count = 1 + random.below(4);
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                value.append(' ');
            appendNumber(value, random, 40, 0);
            if (random.percent(30))
                value.append('%');
        }
        if (fill && !fillFirst)
            value.append(" fill"_s);
        unsigned slashes = random.below(10);
        if (slashes >= 5) {
            value.append(" / "_s);
            appendBorderImageNumbers(value, random, true, true);
        }
        if (slashes >= 8) {
            value.append(" / "_s);
            appendBorderImageNumbers(value, random, false, false);
        }
    }
    if (hasRepeat && !repeatFirst) {
        value.append(' ');
        value.append(random.pick(repeats));
        if (random.percent(40)) {
            value.append(' ');
            value.append(random.pick(repeats));
        }
    }
}

static void appendOtherImage(StringBuilder& value, Random& random)
{
    switch (random.below(8)) {
    case 0:
        value.append(random.pick(layerURLs));
        break;
    case 1:
        value.append("image-set("_s);
        value.append(random.pick(layerURLs));
        value.append(" 1x, "_s);
        value.append(random.pick(layerURLs));
        value.append(random.percent(50) ? " 2x)"_s : " 2dppx type(\"image/png\"))"_s);
        break;
    case 2:
        value.append("-webkit-image-set(\"https://example.com/e.png\" 1x, "_s);
        appendLinearGradient(value, random);
        value.append(" 3x)"_s);
        break;
    case 3:
        value.append("cross-fade("_s);
        value.append(random.pick(layerURLs));
        value.append(' ');
        appendNumber(value, random, 100, 0);
        value.append("%, "_s);
        appendLinearGradient(value, random);
        value.append(')');
        break;
    case 4:
        value.append("-webkit-cross-fade("_s);
        value.append(random.pick(layerURLs));
        value.append(", "_s);
        appendRadialGradient(value, random);
        value.append(", "_s);
        appendFraction(value, random, 0);
        value.append(')');
        break;
    case 5:
        value.append(random.percent(50) ? "-webkit-canvas(sprite)"_s : "-webkit-named-image(apple-pay-logo-black)"_s);
        break;
    case 6:
        value.append("image("_s);
        appendColor(value, random);
        value.append(')');
        break;
    default:
        value.append("light-dark("_s);
        value.append(random.pick(layerURLs));
        value.append(", "_s);
        appendConicGradient(value, random);
        value.append(')');
        break;
    }
}

// box-shadow and -webkit-box-shadow lists, the border-radius and -webkit-border-radius shorthands, border-image,
// -webkit-border-image and -webkit-mask-box-image, -webkit-box-reflect, and url(), image-set(), cross-fade(),
// -webkit-canvas(), -webkit-named-image(), image() and light-dark() images.
static Vector<Block> shadowsBordersImagesBlocks()
{
    return generateBlocks(231, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        switch (index % 10) {
        case 0:
        case 1: {
            if (random.percent(4)) {
                value.append("none"_s);
                return index % 10 ? webkitBoxShadow : boxShadow;
            }
            unsigned count = 1 + random.below(3);
            for (unsigned i = 0; i < count; ++i) {
                if (i)
                    value.append(", "_s);
                appendShadow(value, random);
            }
            return index % 10 ? webkitBoxShadow : boxShadow;
        }
        case 2:
            appendBorderRadiusValues(value, random, 4);
            if (random.percent(30)) {
                value.append(" / "_s);
                appendBorderRadiusValues(value, random, 4);
            }
            return borderRadius;
        case 3:
            appendBorderRadiusValues(value, random, 2);
            return webkitBorderRadius;
        case 4:
            appendBorderImage(value, random);
            return borderImage;
        case 5:
            appendBorderImage(value, random);
            return webkitBorderImage;
        case 6:
            appendBorderImage(value, random);
            return webkitMaskBoxImage;
        case 7: {
            static constexpr ASCIILiteral directions[] = { "above"_s, "below"_s, "left"_s, "right"_s };
            value.append(random.pick(directions));
            if (random.percent(60)) {
                value.append(' ');
                appendLength(value, random, 20);
            }
            if (random.percent(50)) {
                value.append(' ');
                appendBorderImage(value, random);
            }
            return webkitBoxReflect;
        }
        case 8:
            appendOtherImage(value, random);
            return listStyleImage;
        default:
            appendOtherImage(value, random);
            return borderImageSource;
        }
    });
}

// MARK: - Invalid colors and images.

struct InvalidTemplate {
    Property property;
    ASCIILiteral text;
};

// Each is invalid for its property whatever number replaces `@`.
static constexpr InvalidTemplate invalidColorsImagesTemplates[] = {
    { colorProperties[0], "#12"_s },
    { colorProperties[1], "#12345"_s },
    { colorProperties[2], "#1234567"_s },
    { colorProperties[3], "#ggg"_s },
    { colorProperties[4], "#12g"_s },
    { colorProperties[5], "rgb(@, @)"_s },
    { colorProperties[6], "rgb(@, @, @, @, @)"_s },
    { colorProperties[7], "rgb(@ @, @)"_s },
    { colorProperties[8], "rgb(@%, @, @)"_s },
    { colorProperties[9], "hsl(@deg @% @%, 0.5)"_s },
    { colorProperties[10], "lab(@% @ @ / )"_s },
    { colorProperties[11], "lab(@% @)"_s },
    { colorProperties[0], "oklch(0.@ 0.@ @ @)"_s },
    { colorProperties[1], "color(unknown 0.@ 0.@ 0.@)"_s },
    { colorProperties[2], "color(srgb 0.@ 0.@)"_s },
    { colorProperties[3], "rgb(from red r g)"_s },
    { colorProperties[4], "rgb(from #@@@ r g b q)"_s },
    { colorProperties[5], "hsl(from blue h s x)"_s },
    { colorProperties[6], "lch(from)"_s },
    { colorProperties[7], "color-mix(in nowhere, red, blue)"_s },
    { colorProperties[8], "color-mix(in srgb red, blue)"_s },
    { colorProperties[9], "color-mix(in hsl farther hue, red, blue)"_s },
    { colorProperties[10], "color-mix(in srgb, red 1@0%, blue)"_s },
    { colorProperties[11], "red blue"_s },
    { colorProperties[0], "notacolor"_s },
    { colorProperties[1], "light-dark(red)"_s },
    { colorProperties[2], "@px"_s },
    { backgroundImage, "linear-gradient()"_s },
    { listStyleImage, "linear-gradient(to middle, red, blue)"_s },
    { borderImageSource, "linear-gradient(@deg red, blue)"_s },
    { maskImage, "linear-gradient(red, @%, @%, blue)"_s },
    { backgroundImage, "linear-gradient(red, blue, @%)"_s },
    { listStyleImage, "radial-gradient(circle @px @px, red, blue)"_s },
    { borderImageSource, "radial-gradient(ellipse @px, red, blue)"_s },
    { maskImage, "conic-gradient(from @px, red, blue)"_s },
    { backgroundImage, "conic-gradient(red @px, blue)"_s },
    { listStyleImage, "-webkit-gradient(linear, left top, red)"_s },
    { borderImageSource, "-webkit-linear-gradient(to top, red, blue)"_s },
    { maskImage, "-webkit-gradient(radial, center, @, center, red)"_s },
    { backgroundImage, "image-set()"_s },
    { maskImage, "linear-gradient(red, blue) linear-gradient(red, blue)"_s },
    { listStyleImage, "repeating-radial-gradient(at, red, blue)"_s },
    { borderImageSource, "-webkit-cross-fade(url(https://example.com/a.png), url(https://example.com/b.png))"_s },
    { objectPosition, "left left"_s },
    { objectPosition, "@px @px @px"_s },
    { offsetAnchor, "top @px bottom"_s },
    { backgroundShorthand, "red, linear-gradient(red, blue)"_s },
    { backgroundShorthand, "linear-gradient(red, blue) / cover"_s },
    { maskShorthand, "red"_s },
    { boxShadow, "@px"_s },
    { boxShadow, "inset inset @px @px"_s },
    { webkitBoxShadow, "@px @px -@px red"_s },
    { borderRadius, "@px / / @px"_s },
};

// Colors, gradients, images, positions, background layers and shadows that fail at their first token, at a middle
// one or at the last one.
static Vector<Block> invalidColorsImagesBlocks()
{
    return generateBlocks(232, [](Random& random, StringBuilder& value, unsigned) -> const Property& {
        auto& chosen = random.pick(invalidColorsImagesTemplates);
        for (auto character : chosen.text.span()) {
            if (character != '@') {
                value.append(character);
                continue;
            }
            unsigned number = 1 + random.below(99);
            value.append(number);
        }
        return chosen.property;
    });
}

// MARK: - Font families.

static constexpr Property fontFamily { CSSPropertyID::FontFamily, "font-family"_s };
static constexpr Property fontShorthand { CSSPropertyID::Font, "font"_s };

static constexpr ASCIILiteral genericFamilies[] = {
    "serif"_s, "sans-serif"_s, "monospace"_s, "cursive"_s, "fantasy"_s, "system-ui"_s, "ui-serif"_s, "ui-sans-serif"_s,
    "ui-monospace"_s, "ui-rounded"_s, "math"_s, "emoji"_s, "fangsong"_s, "-webkit-body"_s, "-webkit-pictograph"_s,
};
static constexpr ASCIILiteral singleWordFamilies[] = {
    "Arial"_s, "Helvetica"_s, "Roboto"_s, "Inter"_s, "Georgia"_s, "Menlo"_s, "Verdana"_s, "Tahoma"_s, "-apple-system"_s,
    "BlinkMacSystemFont"_s, "Ubuntu"_s, "Consolas"_s,
};
// Some contain a generic family's word, which unquoted is still part of one family name.
static constexpr ASCIILiteral multiWordFamilies[] = {
    "Helvetica Neue"_s, "Segoe UI"_s, "Times New Roman"_s, "Noto Sans CJK JP"_s, "Source Code Pro"_s, "Apple Color Emoji"_s,
    "Liberation Sans"_s, "PT Serif"_s, "Fira Mono"_s, "Segoe UI Emoji"_s, "Open Sans"_s,
};
// Entries that invalidate a list of more than one: CSS-wide and default keywords as unquoted names, a number, an
// empty entry (and so a trailing comma), a URL. Alone, a CSS-wide keyword is valid.
static constexpr ASCIILiteral invalidFamilyEntries[] = { "inherit"_s, "initial"_s, "default"_s, "unset"_s, "12px"_s, ""_s, "serif 2"_s, "url(a)"_s };

static constexpr unsigned familyCounts[] = { 1, 1, 2, 3, 5, 5, 10 };

static void appendFamilyName(StringBuilder& value, Random& random)
{
    unsigned kind = random.below(100);
    if (kind < 20) {
        auto& generic = random.pick(genericFamilies);
        if (random.percent(10))
            value.append('"', generic, '"');
        else
            value.append(generic);
        return;
    }
    auto& name = kind < 60 ? random.pick(singleWordFamilies) : random.pick(multiWordFamilies);
    unsigned quoting = random.below(100);
    if (quoting < 25)
        value.append('"', name, '"');
    else if (quoting < 35)
        value.append('\'', name, '\'');
    else
        value.append(name);
}

static void appendFamilyList(StringBuilder& value, Random& random, unsigned count, unsigned invalidChance)
{
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            value.append(", "_s);
        if (random.percent(invalidChance)) {
            value.append(random.pick(invalidFamilyEntries));
            continue;
        }
        appendFamilyName(value, random);
    }
}

// font-family stacks of 1, 2, 3, 5 and 10 names: quoted and unquoted, single- and multi-word, generic and quoted
// generic, with an invalid entry in about one list in six of ten names.
static Vector<Block> fontFamilyStacksBlocks()
{
    return generateBlocks(301, [](Random& random, StringBuilder& value, unsigned) -> const Property& {
        unsigned count = random.pick(familyCounts);
        appendFamilyList(value, random, count, 2);
        return fontFamily;
    });
}

// MARK: - The font shorthand.

static constexpr ASCIILiteral shorthandFontStyles[] = { "italic"_s, "oblique"_s, "oblique 10deg"_s, "oblique -20deg"_s, "normal"_s };
static constexpr ASCIILiteral shorthandFontWeights[] = {
    "bold"_s, "bolder"_s, "lighter"_s, "normal"_s, "100"_s, "300"_s, "500"_s, "600"_s, "700"_s, "900"_s, "1000"_s, "450"_s, "calc(400 + 50)"_s,
};
static constexpr ASCIILiteral fontWidthKeywords[] = {
    "condensed"_s, "semi-condensed"_s, "ultra-condensed"_s, "extra-condensed"_s, "semi-expanded"_s, "expanded"_s,
    "extra-expanded"_s, "ultra-expanded"_s, "normal"_s,
};
static constexpr ASCIILiteral fontSizeKeywords[] = {
    "xx-small"_s, "x-small"_s, "small"_s, "medium"_s, "large"_s, "x-large"_s, "xx-large"_s, "xxx-large"_s, "-webkit-xxx-large"_s,
    "smaller"_s, "larger"_s, "math"_s,
};
static constexpr ASCIILiteral shorthandLineHeights[] = { "normal"_s, "1"_s, "1.5"_s, "1.25"_s, "120%"_s, "20px"_s, "1.2em"_s, "calc(1em + 4px)"_s };
static constexpr ASCIILiteral systemFonts[] = {
    "caption"_s, "icon"_s, "menu"_s, "message-box"_s, "small-caption"_s, "status-bar"_s, "-apple-system-body"_s,
    "-apple-system-headline"_s, "-webkit-control"_s, "-webkit-small-control"_s,
};
// No size, no family, '/' with no line height, five slots, a slot after the size, a negative size, a lone keyword,
// a repeated slot, an angle out of range, a trailing comma, a CSS-wide keyword (valid only for the declaration).
static constexpr ASCIILiteral invalidFontStrings[] = {
    "bold serif"_s, "12px"_s, "italic bold 12px/ serif"_s, "italic small-caps bold condensed normal 12px serif"_s,
    "12px bold serif"_s, "-12px serif"_s, "bold"_s, "12px/1.5"_s, "italic italic 12px serif"_s, "small-caps 12px, serif"_s,
    "12px serif,"_s, "oblique 100deg 12px serif"_s, "inherit"_s, "12px inherit"_s,
};

static void appendFontSize(StringBuilder& value, Random& random)
{
    unsigned kind = random.below(100);
    if (kind < 20) {
        value.append(random.pick(fontSizeKeywords));
        return;
    }
    if (kind < 30) {
        appendNumber(value, random, 200, 1);
        value.append('%');
        return;
    }
    if (kind < 35) {
        appendCalcLengthPercentage(value, random);
        return;
    }
    appendLength(value, random, 0);
}

// Up to four of style, small-caps, weight and width in any order (a repeat written as `normal`), a size, a line
// height in two in five, and a family list; one in twenty a system font, one in fourteen an invalid string.
static void appendFontString(StringBuilder& value, Random& random)
{
    unsigned kind = random.below(100);
    if (kind < 5) {
        value.append(random.pick(systemFonts));
        return;
    }
    if (kind < 12) {
        value.append(random.pick(invalidFontStrings));
        return;
    }
    unsigned slots = random.below(5);
    std::array<bool, 4> used { };
    for (unsigned i = 0; i < slots; ++i) {
        unsigned slot = random.below(4);
        if (used[slot]) {
            value.append("normal "_s);
            continue;
        }
        used[slot] = true;
        switch (slot) {
        case 0:
            value.append(random.pick(shorthandFontStyles));
            break;
        case 1:
            value.append("small-caps"_s);
            break;
        case 2:
            value.append(random.pick(shorthandFontWeights));
            break;
        default:
            value.append(random.pick(fontWidthKeywords));
            break;
        }
        value.append(' ');
    }
    appendFontSize(value, random);
    if (random.percent(40)) {
        value.append('/');
        value.append(random.pick(shorthandLineHeights));
    }
    value.append(' ');
    unsigned count = random.pick(familyCounts);
    appendFamilyList(value, random, count, 1);
}

static Vector<String> fontShorthandStrings()
{
    Random random(302);
    Vector<String> strings;
    for (unsigned i = 0; i < declarationCount; ++i) {
        StringBuilder value;
        appendFontString(value, random);
        strings.append(value.toString());
    }
    return strings;
}

// One `font` declaration per block, on the same strings parseUnresolvedFont parses.
static Vector<Block> fontShorthandBlocks(const Vector<String>& strings)
{
    Vector<Block> blocks;
    BlockBuilder builder;
    for (auto& string : strings) {
        builder.add(fontShorthand, string);
        blocks.append(builder.take());
    }
    return blocks;
}

// MARK: - @font-face blocks.

static constexpr ASCIILiteral webfontFormats[] = { "woff2"_s, "woff"_s, "truetype"_s, "opentype"_s, "embedded-opentype"_s, "svg"_s, "collection"_s };
static constexpr ASCIILiteral webfontTechnologies[] = {
    "variations"_s, "color-COLRv1"_s, "color-SVG"_s, "color-sbix"_s, "features-opentype"_s, "incremental"_s, "palettes"_s,
};
// An unknown format (dropped, the rest kept), an unknown technology (the whole descriptor fails), an empty local(),
// an empty format(), a bare ident, two formats.
static constexpr ASCIILiteral invalidSourceEntries[] = {
    "url(x.woff) format(\"unknown\")"_s, "url(x.woff) tech(bogus)"_s, "local()"_s, "url(x.ttf) format()"_s, "foo"_s,
    "url(x.ttf) format(woff2) format(woff)"_s,
};
// Past U+10FFFF, seven digits, start after end, no digits, a non-hex digit.
static constexpr ASCIILiteral invalidUnicodeRanges[] = { "U+110000"_s, "U+1234567"_s, "U+50-20"_s, "U+"_s, "U+G0"_s, "U+0-110000"_s };
static constexpr ASCIILiteral fontFaceWeights[] = { "400"_s, "bold"_s, "normal"_s, "100 900"_s, "300 700"_s, "200.5"_s, "900 100"_s, "auto"_s };
static constexpr ASCIILiteral fontFaceStyles[] = { "normal"_s, "italic"_s, "oblique"_s, "oblique 0deg"_s, "oblique 0deg 0deg"_s, "oblique 10deg"_s, "oblique 0deg 20deg"_s, "oblique -10deg 10deg"_s };
static constexpr ASCIILiteral fontDisplays[] = { "auto"_s, "block"_s, "swap"_s, "fallback"_s, "optional"_s };
static constexpr ASCIILiteral fontFaceOverrides[] = { "normal"_s, "90%"_s, "105.5%"_s, "0%"_s, "-5%"_s };

static void appendHexDigits(StringBuilder& value, unsigned number, unsigned digits)
{
    for (unsigned i = digits; i--;) {
        unsigned digit = (number >> (4 * i)) & 0xF;
        value.append(static_cast<char>(digit < 10 ? '0' + digit : 'A' + digit - 10));
    }
}

static void appendUnicodeRange(StringBuilder& value, Random& random)
{
    unsigned kind = random.below(100);
    if (kind < 3) {
        value.append(random.pick(invalidUnicodeRanges));
        return;
    }
    value.append("U+"_s);
    if (kind < 15) {
        unsigned prefix = random.below(0x100);
        appendHexDigits(value, prefix, 2);
        value.append(random.percent(50) ? "??"_s : "?"_s);
        return;
    }
    unsigned start = random.below(0x30000);
    appendHexDigits(value, start, start > 0xFFFF ? 5 : 4);
    if (kind < 40)
        return;
    unsigned length = random.below(0x200);
    unsigned end = start + length;
    value.append('-');
    appendHexDigits(value, end, end > 0xFFFF ? 5 : 4);
}

static void appendFontSource(StringBuilder& value, Random& random, unsigned index)
{
    unsigned kind = random.below(100);
    if (kind < 3) {
        value.append(random.pick(invalidSourceEntries));
        return;
    }
    if (kind < 30) {
        auto& name = random.pick(multiWordFamilies);
        if (random.percent(60))
            value.append("local(\""_s, name, "\")"_s);
        else
            value.append("local("_s, name, ')');
        return;
    }
    auto& format = random.pick(webfontFormats);
    value.append("url(\"fonts/face-"_s, index, '.', format, "\")"_s);
    unsigned formatKind = random.below(100);
    if (formatKind < 50)
        value.append(" format(\""_s, format, "\")"_s);
    else if (formatKind < 80)
        value.append(" format("_s, format, ')');
    if (random.percent(20))
        value.append(" tech("_s, random.pick(webfontTechnologies), ')');
}

static constexpr unsigned fontFaceRulesPerSheet = 4;
static constexpr unsigned fontFaceSheetCount = 1024;

// Style sheets of four @font-face rules: a family, a `src` list of one to four sources (url() with and without
// format() and tech(), local() quoted and not), a `unicode-range` of ten ranges (single, span, wildcard; 5- and
// 4-digit), weight and style ranges, font-display and, in some, font-feature-settings and the metric overrides.
static Vector<String> fontFaceSheets()
{
    Random random(303);
    Vector<String> sheets;
    for (unsigned sheetIndex = 0; sheetIndex < fontFaceSheetCount; ++sheetIndex) {
        StringBuilder sheet;
        for (unsigned rule = 0; rule < fontFaceRulesPerSheet; ++rule) {
            unsigned index = sheetIndex * fontFaceRulesPerSheet + rule;
            sheet.append("@font-face { font-family: "_s);
            appendFamilyName(sheet, random);
            sheet.append("; src: "_s);
            unsigned sources = 1 + random.below(4);
            for (unsigned i = 0; i < sources; ++i) {
                if (i)
                    sheet.append(", "_s);
                appendFontSource(sheet, random, index);
            }
            sheet.append("; unicode-range: "_s);
            for (unsigned i = 0; i < 10; ++i) {
                if (i)
                    sheet.append(", "_s);
                appendUnicodeRange(sheet, random);
            }
            sheet.append("; font-weight: "_s, random.pick(fontFaceWeights));
            sheet.append("; font-style: "_s, random.pick(fontFaceStyles));
            sheet.append("; font-display: "_s, random.pick(fontDisplays));
            if (random.percent(30))
                sheet.append("; font-feature-settings: \"liga\" 0, \"kern\""_s);
            if (random.percent(25)) {
                sheet.append("; size-adjust: "_s, random.pick(fontFaceOverrides));
                sheet.append("; ascent-override: "_s, random.pick(fontFaceOverrides));
                sheet.append("; descent-override: "_s, random.pick(fontFaceOverrides));
                sheet.append("; line-gap-override: "_s, random.pick(fontFaceOverrides));
            }
            sheet.append("; }\n"_s);
        }
        sheets.append(sheet.toString());
    }
    return sheets;
}

// MARK: - Font feature settings and the other font longhands.

static constexpr Property fontFeatureSettings { CSSPropertyID::FontFeatureSettings, "font-feature-settings"_s };
static constexpr Property fontVariationSettings { CSSPropertyID::FontVariationSettings, "font-variation-settings"_s };
static constexpr Property fontSizeAdjust { CSSPropertyID::FontSizeAdjust, "font-size-adjust"_s };
static constexpr Property fontPalette { CSSPropertyID::FontPalette, "font-palette"_s };
static constexpr Property fontStyle { CSSPropertyID::FontStyle, "font-style"_s };
static constexpr Property fontWeight { CSSPropertyID::FontWeight, "font-weight"_s };
static constexpr Property fontWidth { CSSPropertyID::FontWidth, "font-width"_s };
static constexpr Property fontSize { CSSPropertyID::FontSize, "font-size"_s };

static constexpr ASCIILiteral featureTags[] = {
    "liga"_s, "kern"_s, "calt"_s, "ss01"_s, "ss02"_s, "smcp"_s, "c2sc"_s, "tnum"_s, "onum"_s, "zero"_s, "cv11"_s, "frac"_s, "dlig"_s, "salt"_s,
};
static constexpr ASCIILiteral featureValues[] = { ""_s, ""_s, " on"_s, " off"_s, " 0"_s, " 1"_s, " 2"_s, " 3"_s };
// Three and five characters, unquoted, negative, fractional, two values, empty, a character below 0x20.
static constexpr ASCIILiteral invalidFeatureEntries[] = {
    "\"lig\""_s, "\"ligat\""_s, "liga"_s, "\"liga\" -1"_s, "\"liga\" 1.5"_s, "\"liga\" on off"_s, "\"\""_s, "\"li\\9 g\""_s,
};
static constexpr ASCIILiteral variationTags[] = { "wght"_s, "wdth"_s, "opsz"_s, "slnt"_s, "ital"_s, "GRAD"_s, "XHGT"_s };
static constexpr ASCIILiteral invalidVariationEntries[] = { "\"wght\" bold"_s, "\"wgh\" 400"_s, "wght 400"_s, "\"wght\""_s, "\"wght\" 1px"_s };
static constexpr ASCIILiteral fontSizeAdjustValues[] = {
    "none"_s, "from-font"_s, "0.5"_s, "ex-height 0.5"_s, "cap-height from-font"_s, "ch-width 0.4"_s, "ic-width 1"_s,
    "ic-height from-font"_s, "calc(0.25 * 2)"_s, "-0.5"_s, "ex-height"_s, "cap-height cap-height 1"_s,
};
static constexpr ASCIILiteral fontPaletteValues[] = {
    "normal"_s, "light"_s, "dark"_s, "--brand"_s, "--x"_s, "palette-mix(in lch, light, dark 30%)"_s,
    "palette-mix(in srgb, 40% --a, --b)"_s, "brand"_s, "light dark"_s,
};
static constexpr ASCIILiteral fontStyleValues[] = {
    "normal"_s, "italic"_s, "oblique"_s, "oblique 14deg"_s, "oblique -90deg"_s, "oblique 90deg"_s, "oblique 91deg"_s,
    "oblique calc(10deg * 2)"_s, "oblique 0.2turn"_s, "italic 10deg"_s,
};
static constexpr ASCIILiteral fontWeightKeywords[] = { "normal"_s, "bold"_s, "bolder"_s, "lighter"_s, "0"_s, "1001"_s };

template<size_t tagCount, size_t invalidCount>
static void appendTagList(StringBuilder& value, Random& random, const ASCIILiteral (&tags)[tagCount], const ASCIILiteral (&invalid)[invalidCount], bool numericValues)
{
    if (random.percent(10)) {
        value.append("normal"_s);
        return;
    }
    unsigned count = 1 + random.below(5);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            value.append(", "_s);
        if (random.percent(4)) {
            value.append(random.pick(invalid));
            continue;
        }
        auto& tag = random.pick(tags);
        bool singleQuoted = random.percent(20);
        value.append(singleQuoted ? '\'' : '"', tag, singleQuoted ? '\'' : '"');
        if (numericValues) {
            value.append(' ');
            appendSignedNumber(value, random, 1000, 1, 10);
        } else
            value.append(random.pick(featureValues));
    }
}

// font-feature-settings and font-variation-settings (OpenType tags, quoted either way, with and without values, and
// their errors), and the font longhands with a grammar of their own: font-size-adjust, font-palette, font-style
// with angles, font-weight numbers, font-width percentages, font-size.
static Vector<Block> fontFeatureSettingsBlocks()
{
    return generateBlocks(304, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        switch (index % 10) {
        case 0:
        case 1:
        case 2:
            appendTagList(value, random, featureTags, invalidFeatureEntries, false);
            return fontFeatureSettings;
        case 3:
        case 4:
            appendTagList(value, random, variationTags, invalidVariationEntries, true);
            return fontVariationSettings;
        case 5:
            value.append(random.pick(fontSizeAdjustValues));
            return fontSizeAdjust;
        case 6:
            value.append(random.pick(fontPaletteValues));
            return fontPalette;
        case 7:
            value.append(random.pick(fontStyleValues));
            return fontStyle;
        case 8:
            if (random.percent(30))
                value.append(random.pick(fontWeightKeywords));
            else
                appendNumber(value, random, 1000, 1);
            return fontWeight;
        default:
            if (random.percent(50)) {
                if (random.percent(50))
                    value.append(random.pick(fontWidthKeywords));
                else {
                    appendSignedNumber(value, random, 200, 1, 5);
                    value.append('%');
                }
                return fontWidth;
            }
            appendFontSize(value, random);
            return fontSize;
        }
    });
}

// MARK: - Alignment.

static constexpr Property alignmentProperties[] = {
    { CSSPropertyID::AlignContent, "align-content"_s },
    { CSSPropertyID::AlignItems, "align-items"_s },
    { CSSPropertyID::AlignSelf, "align-self"_s },
    { CSSPropertyID::JustifyContent, "justify-content"_s },
    { CSSPropertyID::JustifyItems, "justify-items"_s },
    { CSSPropertyID::JustifySelf, "justify-self"_s },
};
static constexpr Property placeProperties[] = {
    { CSSPropertyID::PlaceContent, "place-content"_s },
    { CSSPropertyID::PlaceItems, "place-items"_s },
    { CSSPropertyID::PlaceSelf, "place-self"_s },
};

// Every value is valid for some of the properties and invalid for others; the last ones are invalid for all.
static constexpr ASCIILiteral alignmentValues[] = {
    "normal"_s, "stretch"_s, "baseline"_s, "first baseline"_s, "last baseline"_s, "center"_s, "start"_s, "end"_s,
    "self-start"_s, "self-end"_s, "flex-start"_s, "flex-end"_s, "left"_s, "right"_s, "safe center"_s, "unsafe end"_s,
    "safe flex-end"_s, "unsafe self-start"_s, "space-between"_s, "space-around"_s, "space-evenly"_s, "auto"_s, "legacy"_s,
    "legacy right"_s, "legacy left"_s, "center legacy"_s, "right legacy"_s, "legacy center"_s, "anchor-center"_s,
    "safe normal"_s, "center"_s, "start"_s, "flex-start"_s, "space-between"_s, "stretch"_s,
    "baseline last"_s, "safe"_s, "first"_s, "legacy legacy"_s, "safe space-between"_s, "unsafe left right"_s,
    "first last baseline"_s, "self-start legacy"_s,
};

// align-*, justify-* and place-* (one value or two): the overflow positions, baseline positions, legacy in either
// order, distributions, and their combinations each property rejects.
static Vector<Block> alignmentKeywordsBlocks()
{
    return generateBlocks(305, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        unsigned kind = index % (std::size(alignmentProperties) + std::size(placeProperties));
        value.append(random.pick(alignmentValues));
        if (kind < std::size(alignmentProperties))
            return alignmentProperties[kind];
        if (random.percent(60)) {
            value.append(' ');
            value.append(random.pick(alignmentValues));
        }
        return placeProperties[kind - std::size(alignmentProperties)];
    });
}

// MARK: - Display.

static constexpr Property display { CSSPropertyID::Display, "display"_s };

static constexpr ASCIILiteral displaySingles[] = {
    "block"_s, "inline"_s, "inline-block"_s, "flex"_s, "inline-flex"_s, "grid"_s, "inline-grid"_s, "flow-root"_s, "none"_s,
    "contents"_s, "list-item"_s, "table"_s, "inline-table"_s, "table-row"_s, "table-cell"_s, "table-caption"_s,
    "table-row-group"_s, "table-header-group"_s, "table-footer-group"_s, "table-column"_s, "table-column-group"_s,
    "flow"_s, "run-in"_s, "ruby"_s, "ruby-base"_s, "ruby-text"_s, "-webkit-box"_s, "-webkit-inline-box"_s, "-webkit-flex"_s,
    "-webkit-inline-flex"_s, "grid-lanes"_s, "inline-grid-lanes"_s,
};
static constexpr ASCIILiteral displayPairs[] = {
    "block flow"_s, "inline flow"_s, "inline flow-root"_s, "block flex"_s, "inline flex"_s, "block grid"_s, "inline grid"_s,
    "block flow-root"_s, "block list-item"_s, "list-item block"_s, "inline list-item"_s, "list-item inline flow"_s,
    "flow list-item block"_s, "inline table"_s, "block table"_s, "block ruby"_s, "inline ruby"_s, "run-in flow"_s,
    "flex inline"_s, "grid block"_s,
};
static constexpr ASCIILiteral invalidDisplays[] = {
    "block inline"_s, "flex flex"_s, "list-item list-item"_s, "table-row block"_s, "inline-block flow"_s, "list-item flex"_s,
    "block block"_s, "inline-block list-item"_s, "contents block"_s, "grid flex"_s, "blocks"_s, "inline-"_s,
};

// display: single keywords (the fast path's), legacy -webkit- keywords, two- and three-keyword pairs in either order,
// and invalid combinations.
static Vector<Block> displayPairsBlocks()
{
    return generateBlocks(306, [](Random& random, StringBuilder& value, unsigned) -> const Property& {
        unsigned kind = random.below(100);
        if (kind < 55)
            value.append(random.pick(displaySingles));
        else if (kind < 90)
            value.append(random.pick(displayPairs));
        else
            value.append(random.pick(invalidDisplays));
        return display;
    });
}

// MARK: - Grid templates.

static constexpr Property gridTemplateColumns { CSSPropertyID::GridTemplateColumns, "grid-template-columns"_s };
static constexpr Property gridTemplateRows { CSSPropertyID::GridTemplateRows, "grid-template-rows"_s };
static constexpr Property gridTemplateAreas { CSSPropertyID::GridTemplateAreas, "grid-template-areas"_s };
static constexpr Property gridTemplate { CSSPropertyID::GridTemplate, "grid-template"_s };
static constexpr Property gridShorthand { CSSPropertyID::Grid, "grid"_s };
static constexpr Property gridAutoColumns { CSSPropertyID::GridAutoColumns, "grid-auto-columns"_s };
static constexpr Property gridAutoRows { CSSPropertyID::GridAutoRows, "grid-auto-rows"_s };
static constexpr Property gridAutoFlow { CSSPropertyID::GridAutoFlow, "grid-auto-flow"_s };

static constexpr ASCIILiteral gridLineNames[] = { "a"_s, "full-start"_s, "content-start"_s, "content-end"_s, "full-end"_s, "col"_s, "main"_s, "sidebar-start"_s };
static constexpr ASCIILiteral commonTrackLists[] = {
    "repeat(auto-fill, minmax(200px, 1fr))"_s, "repeat(auto-fit, minmax(min(100%, 250px), 1fr))"_s,
    "[full-start] minmax(1rem, 1fr) [content-start] minmax(0, 60rem) [content-end] minmax(1rem, 1fr) [full-end]"_s,
    "repeat(12, [col-start] 1fr)"_s, "200px 1fr"_s, "1fr 1fr 1fr"_s, "auto 1fr auto"_s, "subgrid"_s, "subgrid [a] [b] repeat(auto-fill, [c])"_s,
    "none"_s, "fit-content(40%) 1fr"_s, "repeat(2, 100px 1fr) 50px"_s, "minmax(100px, max-content) 1fr"_s, "repeat(10000, 10px)"_s,
    "repeat(auto-fill, [a] 100px [b])"_s, "masonry"_s,
};
// A non-fixed auto-repeat, two auto-repeats, a zero count, names with no track, a flexible minimum, a dangling
// slash, no tracks in repeat(), a negative size, `span` as a name.
static constexpr ASCIILiteral invalidTrackLists[] = {
    "repeat(auto-fill, 1fr)"_s, "repeat(auto-fill, 100px) repeat(auto-fit, 100px)"_s, "repeat(0, 1fr)"_s, "[a] [b]"_s,
    "minmax(1fr, 100px)"_s, "1fr /"_s, "repeat(3)"_s, "-1px"_s, "100px [span]"_s, "subgrid 1fr"_s,
};
// 4x4 templates with spans, runs of dots, `a.b` split into three names.
static constexpr ASCIILiteral commonTemplateAreas[] = {
    "\"h h h h\" \"s m m a\" \"s m m a\" \"f f f f\""_s,
    "\"a a b b\" \"a a b b\" \"c d d e\" \"c . . e\""_s,
    "\". h h .\" \"n m m s\" \"n m m s\" \". f f .\""_s,
    "\"hd hd hd hd\" \"sd main main main\" \"sd main main main\" \"ft ft ft ft\""_s,
    "\"... a a ....\" \"b b c c\" \"b b c c\" \"d d d d\""_s,
    "\"a.b c\""_s, "none"_s,
};
// Not rectangular, rows of different lengths, a whitespace-only row, a code point that is not a name.
static constexpr ASCIILiteral invalidTemplateAreas[] = {
    "\"a b\" \"b a\""_s, "\"a a a a\" \"a b b a\""_s, "\"a\" \"b c\""_s, "\"   \""_s, "\"a@b\""_s, "\"a\" 10px"_s,
};
static constexpr ASCIILiteral areaNames[] = { "header"_s, "nav"_s, "main"_s, "aside"_s, "footer"_s, "ad"_s, "x"_s, "y"_s };
static constexpr ASCIILiteral commonGridTemplates[] = {
    "auto 1fr / auto 1fr auto"_s, "[header-left] \"head head\" 30px [header-right] [main-left] \"nav main\" 1fr [main-right] / 120px 1fr"_s,
    "\"a a a\" 40px \"b c c\" 40px / 1fr 1fr 1fr"_s, "none"_s, "100px / repeat(3, 1fr)"_s, "\"a\" \"b\" / 1fr 2fr"_s,
};
static constexpr ASCIILiteral commonGridShorthands[] = {
    "auto-flow / 1fr 1fr"_s, "100px 300px / auto-flow 200px"_s, "repeat(3, 80px) / auto-flow dense"_s,
    "auto-flow dense 40px / repeat(auto-fill, minmax(10rem, 1fr))"_s, "\"a b\" 1fr / auto 1fr"_s, "none"_s, "auto-flow / auto-flow"_s,
};
static constexpr ASCIILiteral gridAutoFlows[] = { "row"_s, "column"_s, "dense"_s, "row dense"_s, "column dense"_s, "dense row"_s, "dense column"_s, "row column"_s, "dense dense"_s };

static void appendLineNames(StringBuilder& value, Random& random)
{
    value.append('[');
    value.append(random.pick(gridLineNames));
    if (random.percent(30)) {
        value.append(' ');
        value.append(random.pick(gridLineNames));
    }
    value.append(']');
}

static void appendTrackBreadth(StringBuilder& value, Random& random, bool fixed)
{
    unsigned kind = random.below(fixed ? 60 : 100);
    if (kind < 45)
        appendLengthPercentage(value, random, 2);
    else if (kind < 50)
        appendCalcLengthPercentage(value, random);
    else if (kind < 60)
        value.append("auto"_s);
    else if (kind < 80) {
        appendNumber(value, random, 4, 1);
        value.append("fr"_s);
    } else if (kind < 88)
        value.append("min-content"_s);
    else if (kind < 96)
        value.append("max-content"_s);
    else
        value.append("-webkit-min-content"_s);
}

static void appendTrackSize(StringBuilder& value, Random& random)
{
    unsigned kind = random.below(100);
    if (kind < 20) {
        value.append("minmax("_s);
        appendTrackBreadth(value, random, random.percent(70));
        value.append(", "_s);
        appendTrackBreadth(value, random, false);
        value.append(')');
    } else if (kind < 28) {
        value.append("fit-content("_s);
        appendLengthPercentage(value, random, 2);
        value.append(')');
    } else
        appendTrackBreadth(value, random, false);
}

static void appendTrackList(StringBuilder& value, Random& random)
{
    unsigned count = 1 + random.below(6);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            value.append(' ');
        if (random.percent(25)) {
            appendLineNames(value, random);
            value.append(' ');
        }
        if (random.percent(12)) {
            unsigned repetitions = 1 + random.below(12);
            value.append("repeat("_s, repetitions, ", "_s);
            appendTrackSize(value, random);
            if (random.percent(40)) {
                value.append(' ');
                appendTrackSize(value, random);
            }
            value.append(')');
            continue;
        }
        appendTrackSize(value, random);
    }
    if (random.percent(15)) {
        value.append(' ');
        appendLineNames(value, random);
    }
}

// Four quadrants split at a random column and row, so every area is a rectangle and most span cells.
static void appendQuadrantAreas(StringBuilder& value, Random& random)
{
    unsigned columnSplit = 1 + random.below(3);
    unsigned rowSplit = 1 + random.below(3);
    std::array<ASCIILiteral, 4> names;
    for (auto& name : names)
        name = random.percent(10) ? "."_s : random.pick(areaNames);
    for (unsigned row = 0; row < 4; ++row) {
        if (row)
            value.append(' ');
        value.append('"');
        for (unsigned column = 0; column < 4; ++column) {
            if (column)
                value.append(' ');
            value.append(names[(row < rowSplit ? 0 : 2) + (column < columnSplit ? 0 : 1)]);
        }
        value.append('"');
    }
}

static void appendGridTemplateValue(StringBuilder& value, Random& random, unsigned commonChance)
{
    unsigned kind = random.below(100);
    if (kind < 6)
        value.append(random.pick(invalidTrackLists));
    else if (kind < 6 + commonChance)
        value.append(random.pick(commonTrackLists));
    else
        appendTrackList(value, random);
}

// grid-template-columns and -rows (repeat(auto-fill, minmax(200px, 1fr)), named lines, subgrid, the repeat() clamp,
// generated track lists), 4x4 grid-template-areas with spans, the grid-template and grid shorthands, the grid-auto-*
// properties, and their errors.
static Vector<Block> gridTemplatesBlocks()
{
    return generateBlocks(307, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        unsigned variant = random.below(100);
        switch (index % 8) {
        case 0:
            appendGridTemplateValue(value, random, 35);
            return gridTemplateColumns;
        case 1:
            appendGridTemplateValue(value, random, 20);
            return gridTemplateRows;
        case 2:
            if (variant < 8)
                value.append(random.pick(invalidTemplateAreas));
            else if (variant < 40)
                value.append(random.pick(commonTemplateAreas));
            else
                appendQuadrantAreas(value, random);
            return gridTemplateAreas;
        case 3:
            if (variant < 50)
                value.append(random.pick(commonGridTemplates));
            else {
                appendTrackList(value, random);
                value.append(" / "_s);
                appendTrackList(value, random);
            }
            return gridTemplate;
        case 4:
            value.append(random.pick(commonGridShorthands));
            return gridShorthand;
        case 5:
            appendTrackSize(value, random);
            if (variant < 30) {
                value.append(' ');
                appendTrackSize(value, random);
            }
            return gridAutoColumns;
        case 6:
            appendTrackSize(value, random);
            return gridAutoRows;
        default:
            value.append(random.pick(gridAutoFlows));
            return gridAutoFlow;
        }
    });
}

// MARK: - Grid lines.

static constexpr Property gridLineProperties[] = {
    { CSSPropertyID::GridRowStart, "grid-row-start"_s },
    { CSSPropertyID::GridRowEnd, "grid-row-end"_s },
    { CSSPropertyID::GridColumnStart, "grid-column-start"_s },
    { CSSPropertyID::GridColumnEnd, "grid-column-end"_s },
};
static constexpr Property gridRow { CSSPropertyID::GridRow, "grid-row"_s };
static constexpr Property gridColumn { CSSPropertyID::GridColumn, "grid-column"_s };
static constexpr Property gridArea { CSSPropertyID::GridArea, "grid-area"_s };

// A lone `span`, a zero or negative span, `auto` with an integer, two spans, two idents, a fraction.
static constexpr ASCIILiteral invalidGridLines[] = { "span"_s, "span 0"_s, "span -2"_s, "auto 2"_s, "span a span"_s, "a b"_s, "1.5"_s, "span auto"_s };

static void appendGridLine(StringBuilder& value, Random& random)
{
    unsigned kind = random.below(100);
    if (kind < 15)
        value.append("auto"_s);
    else if (kind < 40)
        appendInteger(value, random, 20, 30);
    else if (kind < 52) {
        value.append("span "_s);
        appendInteger(value, random, 6, 0);
    } else if (kind < 56) {
        appendInteger(value, random, 6, 0);
        value.append(" span"_s);
    } else if (kind < 68)
        value.append(random.pick(areaNames));
    else if (kind < 74) {
        value.append(random.pick(areaNames), ' ');
        appendInteger(value, random, 4, 20);
    } else if (kind < 78) {
        appendInteger(value, random, 4, 20);
        value.append(' ', random.pick(areaNames));
    } else if (kind < 86)
        value.append("span "_s, random.pick(areaNames));
    else if (kind < 92) {
        value.append("span "_s, random.pick(areaNames), ' ');
        appendInteger(value, random, 4, 0);
    } else
        value.append(random.pick(invalidGridLines));
}

// The grid line longhands (integers including 0, spans with integer and ident in either order, idents), grid-row and
// grid-column with one or two lines, grid-area with one to four.
static Vector<Block> gridLinesBlocks()
{
    return generateBlocks(308, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        unsigned kind = index % 7;
        if (kind < std::size(gridLineProperties)) {
            appendGridLine(value, random);
            return gridLineProperties[kind];
        }
        unsigned count = kind == 6 ? 1 + random.below(4) : 1 + random.below(2);
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                value.append(" / "_s);
            appendGridLine(value, random);
        }
        return kind == 4 ? gridRow : kind == 5 ? gridColumn : gridArea;
    });
}

// MARK: - Timing functions.

static constexpr Property transitionTimingFunction { CSSPropertyID::TransitionTimingFunction, "transition-timing-function"_s };
static constexpr Property animationTimingFunction { CSSPropertyID::AnimationTimingFunction, "animation-timing-function"_s };

static constexpr ASCIILiteral namedEasings[] = { "ease"_s, "linear"_s, "ease-in"_s, "ease-out"_s, "ease-in-out"_s, "step-start"_s, "step-end"_s };
static constexpr ASCIILiteral stepPositions[] = { "jump-start"_s, "jump-end"_s, "jump-none"_s, "jump-both"_s, "start"_s, "end"_s };
// x out of [0, 1], three arguments, zero steps, one step with jump-none, fractional steps, one stop, no stops, a
// lone percentage, an unknown position, two keywords, a trailing comma, spring() (behind a setting).
static constexpr ASCIILiteral invalidEasings[] = {
    "cubic-bezier(1.5, 0, 0, 1)"_s, "cubic-bezier(0, 0, 1)"_s, "steps(0)"_s, "steps(1, jump-none)"_s, "steps(2.5)"_s, "linear(1)"_s,
    "linear()"_s, "linear(50%)"_s, "steps(3, middle)"_s, "ease-in ease-out"_s, "cubic-bezier(-0.1, 0, 1, 1)"_s, "steps(4,)"_s,
    "spring(1 100 10 0)"_s,
};

static void appendLinearEasing(StringBuilder& value, Random& random, unsigned stops)
{
    value.append("linear("_s);
    for (unsigned i = 0; i < stops; ++i) {
        if (i)
            value.append(", "_s);
        appendSignedNumber(value, random, 1, 3, 5);
        unsigned percentages = random.below(10);
        if (percentages < 4)
            continue;
        unsigned percentage = (100 * i) / (stops - 1);
        value.append(' ', percentage, '%');
        if (percentages == 9) {
            unsigned second = percentage + 1;
            value.append(' ', second, '%');
        }
    }
    value.append(')');
}

static void appendEasing(StringBuilder& value, Random& random)
{
    unsigned kind = random.below(100);
    if (kind < 30)
        value.append(random.pick(namedEasings));
    else if (kind < 50) {
        value.append("cubic-bezier("_s);
        appendNumber(value, random, 0, 3);
        value.append(", "_s);
        appendSignedNumber(value, random, 2, 2, 20);
        value.append(", "_s);
        appendNumber(value, random, 1, 3);
        value.append(", "_s);
        appendSignedNumber(value, random, 2, 2, 20);
        value.append(')');
    } else if (kind < 65) {
        unsigned count = 2 + random.below(19);
        value.append("steps("_s, count);
        if (random.percent(70))
            value.append(", "_s, random.pick(stepPositions));
        value.append(')');
    } else if (kind < 80) {
        unsigned stops = 2 + random.below(5);
        appendLinearEasing(value, random, stops);
    } else if (kind < 92)
        appendLinearEasing(value, random, 40);
    else
        value.append(random.pick(invalidEasings));
}

// transition- and animation-timing-function lists of one to three: the named curves and steps, cubic-bezier(),
// steps() with every position, linear() with 2-6 stops and with 40, and their errors. Each easing of the lists is
// also appended to `easings`, the strings the Web Animations entry (parseEasingFunctionDeprecated) parses one by one.
static Vector<Block> timingFunctionsBlocks(Vector<String>& easings)
{
    return generateBlocks(309, [&easings](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        unsigned count = 1 + random.below(3);
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                value.append(", "_s);
            StringBuilder easing;
            appendEasing(easing, random);
            easings.append(easing.toString());
            value.append(easings.last());
        }
        return index % 2 ? animationTimingFunction : transitionTimingFunction;
    });
}

// MARK: - Filters.

static constexpr Property filter { CSSPropertyID::Filter, "filter"_s };
static constexpr Property backdropFilter { CSSPropertyID::BackdropFilter, "backdrop-filter"_s };

static constexpr ASCIILiteral amountFilters[] = { "brightness"_s, "contrast"_s, "grayscale"_s, "invert"_s, "opacity"_s, "saturate"_s, "sepia"_s };
static constexpr ASCIILiteral commonFilters[] = {
    "drop-shadow(0 4px 8px rgba(0, 0, 0, 0.2)) blur(4px)"_s, "saturate(180%) blur(20px)"_s, "blur(10px)"_s, "grayscale(100%)"_s,
    "brightness(0.9) contrast(1.1)"_s, "url(#filter)"_s, "none"_s,
};
// A negative blur, a shadow with no lengths, a colour between lengths, a unitless angle, two arguments, a negative
// amount, `none` in a list, a second amount, a negative shadow blur, an unknown function.
static constexpr ASCIILiteral invalidFilters[] = {
    "blur(-2px)"_s, "drop-shadow(red)"_s, "drop-shadow(1px red 2px)"_s, "hue-rotate(10)"_s, "blur(1px, 2px)"_s, "saturate(-1)"_s,
    "none blur(1px)"_s, "opacity(50% 1)"_s, "drop-shadow(1px 1px -2px)"_s, "glow(1px)"_s,
};

static void appendFilterFunction(StringBuilder& value, Random& random)
{
    unsigned kind = random.below(100);
    if (kind < 20) {
        value.append("blur("_s);
        if (random.percent(95))
            appendLength(value, random, 0);
        value.append(')');
    } else if (kind < 60) {
        value.append(random.pick(amountFilters), '(');
        unsigned amount = random.below(100);
        if (amount < 40) {
            appendNumber(value, random, 300, 0);
            value.append('%');
        } else if (amount < 95)
            appendNumber(value, random, 3, 2);
        value.append(')');
    } else if (kind < 72) {
        value.append("hue-rotate("_s);
        if (random.percent(10))
            value.append('0');
        else
            appendAngle(value, random);
        value.append(')');
    } else if (kind < 96) {
        value.append("drop-shadow("_s);
        bool hasColor = random.percent(60);
        bool colorFirst = random.percent(50);
        if (hasColor && colorFirst) {
            appendKeywordOrHexColor(value, random);
            value.append(' ');
        }
        appendLength(value, random, 30);
        value.append(' ');
        appendLength(value, random, 30);
        if (random.percent(60)) {
            value.append(' ');
            appendLength(value, random, 0);
        }
        if (hasColor && !colorFirst) {
            value.append(' ');
            appendKeywordOrHexColor(value, random);
        }
        value.append(')');
    } else
        value.append("url(#f)"_s);
}

// filter and backdrop-filter: chains of one to four functions (blur, the amounts as numbers and percentages,
// hue-rotate with a zero, drop-shadow with the colour first, last or absent, url()), empty arguments, the two common
// stacks, and invalid lists.
static Vector<Block> filtersBlocks()
{
    return generateBlocks(310, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        unsigned kind = random.below(100);
        if (kind < 15)
            value.append(random.pick(commonFilters));
        else if (kind < 22)
            value.append(random.pick(invalidFilters));
        else {
            unsigned count = 1 + random.below(4);
            for (unsigned i = 0; i < count; ++i) {
                if (i)
                    value.append(' ');
                appendFilterFunction(value, random);
            }
        }
        return index % 3 == 2 ? backdropFilter : filter;
    });
}

// MARK: - Clip paths.

static constexpr Property clipPath { CSSPropertyID::ClipPath, "clip-path"_s };
static constexpr Property shapeOutside { CSSPropertyID::ShapeOutside, "shape-outside"_s };
static constexpr Property clip { CSSPropertyID::Clip, "clip"_s };

static constexpr ASCIILiteral geometryBoxes[] = { "border-box"_s, "padding-box"_s, "content-box"_s, "margin-box"_s, "fill-box"_s, "stroke-box"_s, "view-box"_s };
static constexpr ASCIILiteral shapeRadii[] = { "closest-side"_s, "farthest-side"_s };
// A fill rule with no comma, one radius for an ellipse, no insets, two radii for a circle, round in polygon(), a
// negative radius, five insets, no vertices, two boxes, mixed separators in rect().
static constexpr ASCIILiteral invalidClipPaths[] = {
    "polygon(nonzero 0 0, 1px 1px, 2px 2px)"_s, "ellipse(10px)"_s, "inset()"_s, "circle(1px 2px)"_s,
    "polygon(0 0, 1px 1px round 2px)"_s, "circle(-1px)"_s, "inset(1px 2px 3px 4px 5px)"_s, "polygon()"_s,
    "border-box padding-box"_s, "rect(1px, 2px 3px, 4px)"_s,
};

static void appendShapeRadius(StringBuilder& value, Random& random)
{
    if (random.percent(25))
        value.append(random.pick(shapeRadii));
    else
        appendLengthPercentage(value, random, 0);
}

static void appendBasicShape(StringBuilder& value, Random& random)
{
    unsigned kind = random.below(100);
    if (kind < 30) {
        value.append("inset("_s);
        unsigned count = 1 + random.below(4);
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                value.append(' ');
            appendLengthPercentage(value, random, 5);
        }
        if (random.percent(60)) {
            value.append(" round "_s);
            unsigned radii = 1 + random.below(4);
            for (unsigned i = 0; i < radii; ++i) {
                if (i)
                    value.append(' ');
                appendRadius(value, random);
            }
            if (random.percent(20)) {
                value.append(" / "_s);
                appendRadius(value, random);
            }
        }
        value.append(')');
    } else if (kind < 50) {
        value.append("circle("_s);
        bool hasRadius = random.percent(70);
        if (hasRadius)
            appendShapeRadius(value, random);
        if (random.percent(60)) {
            value.append(hasRadius ? " at "_s : "at "_s);
            appendPosition(value, random, false);
        }
        value.append(')');
    } else if (kind < 62) {
        value.append("ellipse("_s);
        bool hasRadii = random.percent(70);
        if (hasRadii) {
            appendShapeRadius(value, random);
            value.append(' ');
            appendShapeRadius(value, random);
        }
        if (random.percent(60)) {
            value.append(hasRadii ? " at "_s : "at "_s);
            appendPosition(value, random, false);
        }
        value.append(')');
    } else {
        value.append("polygon("_s);
        if (random.percent(20))
            value.append(random.percent(50) ? "evenodd, "_s : "nonzero, "_s);
        unsigned vertices = 3 + random.below(10);
        for (unsigned i = 0; i < vertices; ++i) {
            if (i)
                value.append(", "_s);
            appendLengthPercentage(value, random, 5);
            value.append(' ');
            appendLengthPercentage(value, random, 5);
        }
        value.append(')');
    }
}

static void appendClipRect(StringBuilder& value, Random& random)
{
    bool commas = random.percent(70);
    value.append("rect("_s);
    for (unsigned i = 0; i < 4; ++i) {
        if (i)
            value.append(commas ? ", "_s : " "_s);
        if (random.percent(15))
            value.append("auto"_s);
        else
            appendLength(value, random, 10);
    }
    value.append(')');
}

// clip-path and shape-outside: inset() with and without round (and a second radius set), circle() and ellipse() with
// and without radii and positions, polygon() of 3-12 vertices with and without a fill rule, a geometry box before or
// after the shape or alone, url(), none; clip rect() with commas or spaces; and their errors.
static Vector<Block> clipPathsBlocks()
{
    return generateBlocks(311, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        unsigned kind = random.below(100);
        if (index % 5 == 4) {
            if (kind < 10)
                value.append("auto"_s);
            else if (kind < 15)
                value.append(random.pick(invalidClipPaths));
            else
                appendClipRect(value, random);
            return clip;
        }
        auto& property = index % 5 == 3 ? shapeOutside : clipPath;
        if (kind < 6)
            value.append(random.pick(invalidClipPaths));
        else if (kind < 10)
            value.append("none"_s);
        else if (kind < 14)
            value.append("url(#clip)"_s);
        else if (kind < 20)
            value.append(random.pick(geometryBoxes));
        else {
            bool hasBox = random.percent(20);
            bool boxFirst = random.percent(50);
            if (hasBox && boxFirst)
                value.append(random.pick(geometryBoxes), ' ');
            appendBasicShape(value, random);
            if (hasBox && !boxFirst)
                value.append(' ', random.pick(geometryBoxes));
        }
        return property;
    });
}

// MARK: - Rare shapes and mask-border.

static constexpr Property offsetPath { CSSPropertyID::OffsetPath, "offset-path"_s };
static constexpr Property maskBorder { CSSPropertyID::MaskBorder, "mask-border"_s };
static constexpr Property maskBorderSlice { CSSPropertyID::MaskBorderSlice, "mask-border-slice"_s };
static constexpr Property maskBorderOutset { CSSPropertyID::MaskBorderOutset, "mask-border-outset"_s };
static constexpr Property maskBorderRepeat { CSSPropertyID::MaskBorderRepeat, "mask-border-repeat"_s };
static constexpr Property maskBorderWidth { CSSPropertyID::MaskBorderWidth, "mask-border-width"_s };

static constexpr ASCIILiteral pathCommands[] = { "M"_s, "m"_s, "L"_s, "l"_s, "H"_s, "h"_s, "V"_s, "v"_s, "C"_s, "c"_s, "Q"_s, "q"_s, "A"_s, "Z"_s };
static constexpr ASCIILiteral shapeCommands[] = {
    "line to 10px 20px"_s, "line by 5% 5%"_s, "hline to 50%"_s, "vline by -10px"_s, "hline by 2em"_s, "vline to bottom"_s,
    "curve to 100px 0 with 50px -20px"_s, "curve to 0 0 with 10px 10px / 20px 20px"_s, "curve by 5px 5px with start 1px 1px"_s,
    "smooth to 10px 10px with 5px 5px"_s, "smooth by 10px 10px"_s, "arc to 50% 50% of 20px"_s,
    "arc by 10px 10px of 10px 20px cw large rotate 45deg"_s, "arc to 0 0 of 5px small ccw"_s, "move to 0 0"_s, "move by 10px 0"_s,
    "line to right center"_s, "close"_s,
};
// An empty path, an unknown command, a missing string, no commands, no `from`, duplicate arc keywords, too few
// xywh() values, a negative xywh() size.
static constexpr ASCIILiteral invalidRareShapes[] = {
    "path(\"\")"_s, "path(\"X 10\")"_s, "path(nonzero)"_s, "shape()"_s, "shape(line to 0 0)"_s,
    "shape(from 0 0, arc to 1px 1px of 1px cw ccw)"_s, "xywh(0 0 10px)"_s, "xywh(0 0 -10px 10px)"_s,
};
static constexpr ASCIILiteral maskBorderRepeats[] = { "stretch"_s, "repeat"_s, "round"_s, "space"_s, "stretch round"_s, "repeat space"_s, "fill"_s };

static void appendPathData(StringBuilder& value, Random& random)
{
    value.append("M 0 0"_s);
    unsigned count = 2 + random.below(9);
    for (unsigned i = 0; i < count; ++i) {
        auto& command = random.pick(pathCommands);
        value.append(' ', command);
        unsigned arguments = 2;
        if (command == "H"_s || command == "h"_s || command == "V"_s || command == "v"_s)
            arguments = 1;
        else if (command == "C"_s || command == "c"_s)
            arguments = 6;
        else if (command == "Q"_s || command == "q"_s)
            arguments = 4;
        else if (command == "A"_s)
            arguments = 0;
        else if (command == "Z"_s)
            continue;
        if (!arguments) {
            unsigned large = random.below(2);
            unsigned sweep = random.below(2);
            value.append(" 10 10 0 "_s, large, ' ', sweep, ' ');
            appendSignedNumber(value, random, 100, 1, 20);
            value.append(' ');
            appendSignedNumber(value, random, 100, 1, 20);
            continue;
        }
        for (unsigned j = 0; j < arguments; ++j) {
            value.append(' ');
            appendSignedNumber(value, random, 200, 1, 20);
        }
    }
}

static void appendRareShape(StringBuilder& value, Random& random)
{
    unsigned kind = random.below(100);
    if (kind < 6) {
        value.append(random.pick(invalidRareShapes));
        return;
    }
    if (kind < 35) {
        value.append("path("_s);
        if (random.percent(20))
            value.append(random.percent(50) ? "evenodd, "_s : "nonzero, "_s);
        value.append('"');
        appendPathData(value, random);
        value.append("\")"_s);
        return;
    }
    if (kind < 70) {
        value.append("shape("_s);
        if (random.percent(15))
            value.append("evenodd "_s);
        value.append("from "_s);
        appendPosition(value, random, false);
        unsigned count = 1 + random.below(8);
        for (unsigned i = 0; i < count; ++i)
            value.append(", "_s, random.pick(shapeCommands));
        value.append(')');
        return;
    }
    value.append(kind < 85 ? "xywh("_s : "rect("_s);
    for (unsigned i = 0; i < 4; ++i) {
        if (i)
            value.append(' ');
        if (kind >= 85 && random.percent(15))
            value.append("auto"_s);
        else
            appendLengthPercentage(value, random, i < 2 ? 10 : 0);
    }
    if (random.percent(40)) {
        value.append(" round "_s);
        appendRadius(value, random);
    }
    value.append(')');
}

static void appendMaskBorderNumbers(StringBuilder& value, Random& random, bool allowsPercentage)
{
    unsigned count = 1 + random.below(4);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            value.append(' ');
        if (allowsPercentage && random.percent(30)) {
            appendNumber(value, random, 50, 0);
            value.append('%');
        } else
            appendNumber(value, random, 40, 1);
    }
}

// path() (generated SVG path data, with and without a fill rule), shape() (every command, the arc keywords, control
// points relative and absolute), xywh() and rect() with round, in clip-path, shape-outside and offset-path; the
// mask-border shorthand and longhands (a leading `fill`, slices with percentages, outsets, widths, repeats).
static Vector<Block> shapesRareBlocks()
{
    return generateBlocks(312, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        switch (index % 8) {
        case 0:
        case 1:
            appendRareShape(value, random);
            return clipPath;
        case 2:
            appendRareShape(value, random);
            return shapeOutside;
        case 3:
            appendRareShape(value, random);
            return offsetPath;
        case 4:
            value.append("url(m.png) "_s);
            appendMaskBorderNumbers(value, random, true);
            if (random.percent(30))
                value.append(" fill"_s);
            if (random.percent(50)) {
                value.append(" / "_s);
                appendLength(value, random, 0);
                if (random.percent(50)) {
                    value.append(" / "_s);
                    appendMaskBorderNumbers(value, random, false);
                }
            }
            value.append(' ', random.pick(maskBorderRepeats));
            return maskBorder;
        case 5: {
            bool leadingFill = random.percent(15);
            if (leadingFill)
                value.append("fill "_s);
            appendMaskBorderNumbers(value, random, true);
            if (!leadingFill && random.percent(25))
                value.append(" fill"_s);
            return maskBorderSlice;
        }
        case 6:
            if (random.percent(50)) {
                appendMaskBorderNumbers(value, random, false);
                return maskBorderOutset;
            }
            value.append(random.pick(maskBorderRepeats));
            return maskBorderRepeat;
        default: {
            unsigned count = 1 + random.below(4);
            for (unsigned i = 0; i < count; ++i) {
                if (i)
                    value.append(' ');
                unsigned kind = random.below(3);
                if (!kind)
                    value.append("auto"_s);
                else if (kind == 1)
                    appendLengthPercentage(value, random, 5);
                else
                    appendNumber(value, random, 4, 1);
            }
            return maskBorderWidth;
        }
        }
    });
}

// MARK: - Content and counters.

static constexpr Property content { CSSPropertyID::Content, "content"_s };
static constexpr Property quotes { CSSPropertyID::Quotes, "quotes"_s };
static constexpr Property counterReset { CSSPropertyID::CounterReset, "counter-reset"_s };
static constexpr Property counterIncrement { CSSPropertyID::CounterIncrement, "counter-increment"_s };
static constexpr Property counterSet { CSSPropertyID::CounterSet, "counter-set"_s };
static constexpr Property listStyleType { CSSPropertyID::ListStyleType, "list-style-type"_s };

static constexpr ASCIILiteral counterNames[] = { "item"_s, "section"_s, "chapter"_s, "list-item"_s, "c1"_s, "Fig"_s };
static constexpr ASCIILiteral counterStyleNames[] = {
    "decimal"_s, "lower-roman"_s, "upper-alpha"_s, "disc"_s, "circle"_s, "square"_s, "cjk-decimal"_s, "hebrew"_s, "armenian"_s,
    "georgian"_s, "ethiopic-numeric"_s, "disclosure-open"_s, "decimal-leading-zero"_s, "my-style"_s, "none"_s,
};
static constexpr ASCIILiteral contentStrings[] = { "\"\""_s, "\"\\201C\""_s, "\"Note: \""_s, "\"\\2192\""_s, "'x'"_s, "\" / \""_s };
static constexpr ASCIILiteral contentKeywords[] = { "open-quote"_s, "close-quote"_s, "no-open-quote"_s, "no-close-quote"_s };
// No name, three arguments, no separator, an empty attr(), `none` among items, `match-parent`, two alt texts, a
// number.
static constexpr ASCIILiteral invalidContents[] = {
    "counter()"_s, "counter(a, decimal, b)"_s, "counters(a)"_s, "attr()"_s, "\"a\" none"_s, "match-parent"_s,
    "\"a\" / \"b\" / \"c\""_s, "12"_s,
};
static constexpr ASCIILiteral quotePairs[] = { "\"\\AB\" \"\\BB\""_s, "\"\\2039\" \"\\203A\""_s, "'\"' '\"'"_s, "\"\\201C\" \"\\201D\""_s, "\"(\" \")\""_s };
static constexpr ASCIILiteral invalidCounters[] = { "none item"_s, "item 1.5"_s, "item item"_s, "1"_s, "item 2 3"_s, "initial item"_s };
static constexpr ASCIILiteral listStyleTypeExtras[] = {
    "\"\\2192  \""_s, "'-'"_s, "symbols(cyclic \"*\" \"\\2020\")"_s, "symbols(numeric \"0\" \"1\")"_s, "symbols()"_s, "decimal decimal"_s,
    "\"a\" \"b\""_s, "1"_s,
};

static void appendContentItem(StringBuilder& value, Random& random)
{
    unsigned kind = random.below(100);
    if (kind < 30)
        value.append(random.pick(contentStrings));
    else if (kind < 50) {
        value.append("counter("_s, random.pick(counterNames));
        if (random.percent(40))
            value.append(", "_s, random.pick(counterStyleNames));
        value.append(')');
    } else if (kind < 60) {
        value.append("counters("_s, random.pick(counterNames), ", \".\""_s);
        if (random.percent(40))
            value.append(", "_s, random.pick(counterStyleNames));
        value.append(')');
    } else if (kind < 72)
        value.append("attr("_s, random.pick(customIdents), ')');
    else if (kind < 88)
        value.append(random.pick(contentKeywords));
    else if (kind < 95)
        value.append("url(icon.png)"_s);
    else
        value.append("linear-gradient(red, blue)"_s);
}

static void appendCounterList(StringBuilder& value, Random& random, bool allowsReversed)
{
    unsigned kind = random.below(100);
    if (kind < 10) {
        value.append("none"_s);
        return;
    }
    if (kind < 15) {
        value.append(random.pick(invalidCounters));
        return;
    }
    unsigned count = 1 + random.below(3);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            value.append(' ');
        auto& name = random.pick(counterNames);
        if (allowsReversed && random.percent(15))
            value.append("reversed("_s, name, ')');
        else
            value.append(name);
        unsigned integer = random.below(100);
        if (integer < 40) {
            value.append(' ');
            appendInteger(value, random, 20, 30);
        } else if (integer < 45)
            value.append(" calc(1 + 2)"_s);
    }
}

// content (strings, counter() and counters() with and without a style, attr(), the quote keywords, images, an alt
// text after `/`, none and normal), quotes, counter-reset (with reversed()), counter-increment and counter-set, and
// list-style-type (predefined and custom styles, strings, symbols()), with their errors.
static Vector<Block> contentAndCountersBlocks()
{
    return generateBlocks(313, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        unsigned kind = random.below(100);
        switch (index % 6) {
        case 0:
        case 1:
            if (kind < 5)
                value.append(kind < 3 ? "none"_s : "normal"_s);
            else if (kind < 11)
                value.append(random.pick(invalidContents));
            else {
                unsigned count = 1 + random.below(4);
                for (unsigned i = 0; i < count; ++i) {
                    if (i)
                        value.append(' ');
                    appendContentItem(value, random);
                }
                if (random.percent(10))
                    value.append(" / \"alt\""_s);
            }
            return content;
        case 2:
            if (kind < 15)
                value.append(kind < 8 ? "auto"_s : "none"_s);
            else if (kind < 22)
                value.append("\"\\AB\" \"\\BB\" \"\\2039\""_s);
            else {
                unsigned pairs = 1 + random.below(3);
                for (unsigned i = 0; i < pairs; ++i) {
                    if (i)
                        value.append(' ');
                    value.append(random.pick(quotePairs));
                }
            }
            return quotes;
        case 3:
            appendCounterList(value, random, true);
            return counterReset;
        case 4:
            appendCounterList(value, random, false);
            return kind < 50 ? counterIncrement : counterSet;
        default:
            if (kind < 80)
                value.append(random.pick(counterStyleNames));
            else
                value.append(random.pick(listStyleTypeExtras));
            return listStyleType;
        }
    });
}

// MARK: - Small families.

static constexpr Property height { CSSPropertyID::Height, "height"_s };
static constexpr Property textShadow { CSSPropertyID::TextShadow, "text-shadow"_s };
static constexpr Property marginTrim { CSSPropertyID::MarginTrim, "margin-trim"_s };
static constexpr Property textBoxEdge { CSSPropertyID::TextBoxEdge, "text-box-edge"_s };
static constexpr Property lineFitEdge { CSSPropertyID::LineFitEdge, "line-fit-edge"_s };
static constexpr Property overflowClipMargin { CSSPropertyID::OverflowClipMargin, "overflow-clip-margin"_s };
static constexpr Property positionArea { CSSPropertyID::PositionArea, "position-area"_s };
static constexpr Property linkParameters { CSSPropertyID::LinkParameters, "link-parameters"_s };
static constexpr Property animationName { CSSPropertyID::AnimationName, "animation-name"_s };

static constexpr ASCIILiteral calcSizeValues[] = {
    "calc-size(auto, size)"_s, "calc-size(fit-content, size + 20px)"_s, "calc-size(min-content, size * 2)"_s,
    "calc-size(calc-size(auto, size + 1px), size * 2)"_s, "calc-size(any, 100px)"_s, "calc-size(50%, size - 10px)"_s,
    "calc-size(max-content, round(up, size, 10px))"_s, "auto"_s, "100px"_s, "fit-content"_s,
    "calc-size(auto)"_s, "calc-size(size, auto)"_s, "calc-size(auto, size +)"_s,
};
static constexpr ASCIILiteral offsetPathValues[] = {
    "none"_s, "ray(45deg)"_s, "ray(90deg closest-side contain)"_s, "ray(at 50% 50% 30deg farthest-corner)"_s, "ray(sides 0.25turn)"_s,
    "url(#p)"_s, "border-box"_s, "margin-box"_s, "ray(10deg) margin-box"_s, "circle(10px) border-box"_s,
    "ray()"_s, "ray(10deg 20deg)"_s, "url(#p) border-box"_s,
};
static constexpr ASCIILiteral marginTrimValues[] = {
    "none"_s, "block"_s, "inline"_s, "block-start"_s, "block-end"_s, "inline-start"_s, "inline-end"_s, "block-start block-end"_s,
    "inline-end inline-start"_s, "block-start inline-start block-end"_s, "block block"_s, "none block"_s,
};
static constexpr ASCIILiteral textBoxEdgeValues[] = {
    "auto"_s, "text"_s, "cap alphabetic"_s, "ex text"_s, "text text"_s, "ideographic"_s, "ideographic-ink"_s, "cap"_s,
    "alphabetic cap"_s, "cap cap"_s, "text auto"_s,
};
static constexpr ASCIILiteral lineFitEdgeValues[] = {
    "leading"_s, "text"_s, "cap"_s, "ex"_s, "ideographic"_s, "ideographic-ink"_s, "cap alphabetic"_s, "text text"_s,
    "leading text"_s, "alphabetic"_s,
};
static constexpr ASCIILiteral overflowClipMarginValues[] = {
    "0px"_s, "10px"_s, "content-box"_s, "padding-box 5px"_s, "border-box 2em"_s, "5px content-box"_s, "padding-box 0px"_s,
    "-1px"_s, "10px 20px"_s, "content-box padding-box"_s,
};
static constexpr ASCIILiteral positionAreaValues[] = {
    "top"_s, "top left"_s, "span-left bottom"_s, "center"_s, "span-all"_s, "block-start inline-end"_s, "x-start y-end"_s,
    "self-block-start"_s, "start start"_s, "span-all top"_s, "end span-start"_s, "none"_s,
    "top top"_s, "left right"_s, "span-all span-all x"_s,
};
static constexpr ASCIILiteral linkParametersValues[] = {
    "none"_s, "param(--a, red)"_s, "param(--color, #123), param(--size, 10px)"_s, "param(--empty,)"_s,
    "param(--a)"_s, "param(a, b)"_s,
};
static constexpr ASCIILiteral keyframesIdents[] = {
    "fade"_s, "slide-in"_s, "spin"_s, "pulse2"_s, "_x"_s, "-webkit-bounce"_s, "FadeOut"_s, "a-very-long-keyframes-name"_s,
};
// A string that is a valid identifier (a <custom-ident>), one that is not (`none`, a CSS-wide keyword: a string
// value), and other strings.
static constexpr ASCIILiteral keyframesStrings[] = {
    "\"fade\""_s, "\"none\""_s, "\"initial\""_s, "\"quoted name\""_s, "\"12\""_s, "\"\\66 ade\""_s,
};
// An empty string, the excluded `default`, a CSS-wide keyword in a list, a number, a dimension, two names without a
// comma, a trailing comma.
static constexpr ASCIILiteral invalidKeyframesNames[] = {
    "\"\""_s, "default"_s, "fade, inherit"_s, "12"_s, "1s"_s, "fade spin"_s, "fade,"_s,
};

// animation-name lists of one to four: `none`, identifiers and strings, and their errors.
static void appendAnimationNames(StringBuilder& value, Random& random)
{
    if (random.percent(6)) {
        value.append(random.pick(invalidKeyframesNames));
        return;
    }
    unsigned count = 1 + random.below(4);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            value.append(", "_s);
        unsigned kind = random.below(100);
        if (kind < 10)
            value.append("none"_s);
        else if (kind < 75)
            value.append(random.pick(keyframesIdents));
        else
            value.append(random.pick(keyframesStrings));
    }
}

static void appendTextShadow(StringBuilder& value, Random& random)
{
    unsigned count = 1 + random.below(3);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            value.append(", "_s);
        bool colorFirst = random.percent(40);
        if (colorFirst) {
            appendKeywordOrHexColor(value, random);
            value.append(' ');
        }
        appendLength(value, random, 30);
        value.append(' ');
        appendLength(value, random, 30);
        unsigned blur = random.below(100);
        if (blur < 50) {
            value.append(' ');
            appendLength(value, random, 5);
        }
        if (blur >= 97)
            value.append(" 1px 1px"_s);
        if (!colorFirst && random.percent(50)) {
            value.append(' ');
            appendKeywordOrHexColor(value, random);
        }
    }
}

// calc-size() in width and height, offset-path (ray(), url(), boxes), text-shadow, margin-trim, text-box-edge,
// line-fit-edge, overflow-clip-margin, position-area, link-parameters (param()) and animation-name, each with its
// errors.
static Vector<Block> smallFamiliesBlocks()
{
    return generateBlocks(314, [](Random& random, StringBuilder& value, unsigned index) -> const Property& {
        switch (index % 11) {
        case 0:
            value.append(random.pick(calcSizeValues));
            return width;
        case 1:
            value.append(random.pick(calcSizeValues));
            return height;
        case 2:
            value.append(random.pick(offsetPathValues));
            return offsetPath;
        case 3:
            appendTextShadow(value, random);
            return textShadow;
        case 4:
            value.append(random.pick(marginTrimValues));
            return marginTrim;
        case 5:
            value.append(random.pick(textBoxEdgeValues));
            return textBoxEdge;
        case 6:
            value.append(random.pick(lineFitEdgeValues));
            return lineFitEdge;
        case 7:
            value.append(random.pick(overflowClipMarginValues));
            return overflowClipMargin;
        case 8:
            value.append(random.pick(positionAreaValues));
            return positionArea;
        case 9:
            value.append(random.pick(linkParametersValues));
            return linkParameters;
        default:
            appendAnimationNames(value, random);
            return animationName;
        }
    });
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


// MARK: - Running the font shorthand and @font-face shapes.

static size_t stringBytes(const Vector<String>& strings)
{
    size_t bytes = 0;
    for (auto& string : strings)
        bytes += string.length();
    return bytes;
}

// The alternative a value took, and its keyword's name if it is one. The numbers are in the `font` declaration's
// serialization of the same string.
template<typename... Alternatives>
static void addKeywordOrKind(Checksum& checksum, const Variant<CSSValueID, Alternatives...>& value)
{
    checksum.add(static_cast<uint64_t>(value.index()));
    WTF::switchOn(value,
        [&](CSSValueID keyword) { checksum.add(nameString(keyword).string()); },
        [](const auto&) { });
}

static uint64_t checksumOfUnresolvedFonts(const Vector<String>& strings, ScriptExecutionContext& context, unsigned& parsedFonts)
{
    Checksum checksum;
    for (auto& string : strings) {
        auto font = CSSPropertyParserHelpers::parseUnresolvedFont(string, context);
        checksum.add(font.has_value());
        if (!font)
            continue;
        ++parsedFonts;
        addKeywordOrKind(checksum, font->style);
        checksum.add(nameString(font->variantCaps).string());
        addKeywordOrKind(checksum, font->weight);
        addKeywordOrKind(checksum, font->width);
        addKeywordOrKind(checksum, font->size);
        addKeywordOrKind(checksum, font->lineHeight);
        checksum.add(font->family.size());
        for (auto& name : font->family) {
            checksum.add(static_cast<uint64_t>(name.index()));
            WTF::switchOn(name,
                [&](CSSValueID keyword) { checksum.add(nameString(keyword).string()); },
                [&](const AtomString& family) { checksum.add(family.string()); });
        }
    }
    return checksum.value();
}

// The same strings through the declaration parser (`font: <string>;`, one declaration a block) and through
// parseUnresolvedFont (the canvas and FontFaceSet entry, with a document as its context); one pass is both.
static void runFontShorthands(ASCIILiteral name, uint64_t expectedChecksum, unsigned passes)
{
    ProcessWarming::initializeNames();
    auto settings = Settings::create(nullptr);
    Ref document = Document::create(settings.get(), aboutBlankURL());

    auto strings = fontShorthandStrings();
    auto blocks = fontShorthandBlocks(strings);
    auto& context = strictCSSParserContext();
    auto bytes = blockBytes(blocks) + stringBytes(strings);
    ASSERT_GT(bytes, 0u);
    unsigned parsedValues = 0;
    unsigned changedBlocks = 0;
    unsigned parsedFonts = 0;
    Checksum checksum;
    checksum.add(checksumOfParse(blocks, context, parsedValues, changedBlocks));
    checksum.add(checksumOfUnresolvedFonts(strings, document.get(), parsedFonts));
    EXPECT_GT(parsedValues, 0u);
    EXPECT_GT(parsedFonts, 0u);
    EXPECT_EQ(expectedChecksum, checksum.value()) << "checksum=" << std::hex << checksum.value();
    if (!runsBenchmarks())
        return;

    unsigned changed = 0;
    unsigned fonts = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass) {
        for (auto& block : blocks) {
            Ref properties = MutableStyleProperties::create();
            changed += CSSParser::parseDeclarationList(properties, block.text, context);
        }
        for (auto& string : strings)
            fonts += CSSPropertyParserHelpers::parseUnresolvedFont(string, document.get()).has_value();
    }
    auto elapsed = MonotonicTime::now() - start;
    EXPECT_EQ(changedBlocks * passes, changed);
    EXPECT_EQ(parsedFonts * passes, fonts);
    printResult(name, elapsed, static_cast<double>(bytes) * passes, checksum.value());
}

// MARK: - Running the timing function shape.

// Whether each easing parsed, the kind of timing function it made and that function's serialization.
static uint64_t checksumOfTimingFunctions(const Vector<String>& easings, const CSSParserContext& context, unsigned& parsedEasings)
{
    Checksum checksum;
    for (auto& easing : easings) {
        auto function = CSSPropertyParserHelpers::parseEasingFunctionDeprecated(easing, context);
        checksum.add(!!function);
        if (!function)
            continue;
        ++parsedEasings;
        checksum.add(static_cast<uint64_t>(function->type()));
        checksum.add(function->cssText());
    }
    return checksum.value();
}

// The timing function lists through the declaration parser, and each of their easings through
// parseEasingFunctionDeprecated (the Web Animations entry: KeyframeEffect and AnimationEffect easings); one pass is
// both.
static void runTimingFunctions(ASCIILiteral name, uint64_t expectedChecksum, unsigned passes)
{
    Vector<String> easings;
    auto blocks = timingFunctionsBlocks(easings);
    auto& context = strictCSSParserContext();
    auto bytes = blockBytes(blocks) + stringBytes(easings);
    ASSERT_GT(bytes, 0u);
    unsigned parsedValues = 0;
    unsigned changedBlocks = 0;
    unsigned parsedEasings = 0;
    Checksum checksum;
    checksum.add(checksumOfParse(blocks, context, parsedValues, changedBlocks));
    checksum.add(checksumOfTimingFunctions(easings, context, parsedEasings));
    EXPECT_GT(parsedValues, 0u);
    EXPECT_GT(parsedEasings, 0u);
    EXPECT_GT(easings.size(), parsedEasings);
    EXPECT_EQ(expectedChecksum, checksum.value()) << "checksum=" << std::hex << checksum.value();
    if (!runsBenchmarks())
        return;

    unsigned changed = 0;
    unsigned functions = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass) {
        for (auto& block : blocks) {
            Ref properties = MutableStyleProperties::create();
            changed += CSSParser::parseDeclarationList(properties, block.text, context);
        }
        for (auto& easing : easings)
            functions += !!CSSPropertyParserHelpers::parseEasingFunctionDeprecated(easing, context);
    }
    auto elapsed = MonotonicTime::now() - start;
    EXPECT_EQ(changedBlocks * passes, changed);
    EXPECT_EQ(parsedEasings * passes, functions);
    printResult(name, elapsed, static_cast<double>(bytes) * passes, checksum.value());
}

static constexpr CSSPropertyID fontFaceDescriptors[] = {
    CSSPropertyID::FontFamily, CSSPropertyID::Src, CSSPropertyID::UnicodeRange, CSSPropertyID::FontWeight, CSSPropertyID::FontStyle,
    CSSPropertyID::FontDisplay, CSSPropertyID::FontFeatureSettings, CSSPropertyID::SizeAdjust, CSSPropertyID::AscentOverride,
    CSSPropertyID::DescentOverride, CSSPropertyID::LineGapOverride,
};

static uint64_t checksumOfSheets(const Vector<String>& sheets, const CSSParserContext& context, unsigned& parsedDescriptors, unsigned& parsedRules)
{
    Checksum checksum;
    for (auto& text : sheets) {
        Ref sheet = StyleSheetContents::create(context);
        checksum.add(sheet->parseString(text));
        auto& rules = sheet->childRules();
        parsedRules += static_cast<unsigned>(rules.size());
        checksum.add(rules.size());
        for (auto& rule : rules) {
            RefPtr fontFace = dynamicDowncast<StyleRuleFontFace>(rule.get());
            checksum.add(!!fontFace);
            if (!fontFace)
                continue;
            for (auto descriptor : fontFaceDescriptors) {
                auto value = fontFace->properties().getPropertyValue(descriptor);
                parsedDescriptors += !value.isEmpty();
                checksum.add(value);
            }
        }
    }
    return checksum.value();
}

// Style sheets through StyleSheetContents::parseString, the @font-face rules' descriptors read back.
static void runFontFaceSheets(ASCIILiteral name, const Vector<String>& sheets, uint64_t expectedChecksum, unsigned passes)
{
    // The descriptors serialise generic family names from the names table, which a process without it fills only when
    // a Document is made (FontShorthands): without this, the shape's checksum depends on which shapes ran before it.
    ProcessWarming::initializeNames();
    auto& context = strictCSSParserContext();
    auto bytes = stringBytes(sheets);
    ASSERT_GT(bytes, 0u);
    unsigned parsedDescriptors = 0;
    unsigned parsedRules = 0;
    auto checksum = checksumOfSheets(sheets, context, parsedDescriptors, parsedRules);
    EXPECT_GT(parsedRules, 0u);
    EXPECT_GT(parsedDescriptors, 0u);
    EXPECT_EQ(expectedChecksum, checksum) << "checksum=" << std::hex << checksum;
    if (!runsBenchmarks())
        return;

    unsigned rules = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass) {
        for (auto& text : sheets) {
            Ref sheet = StyleSheetContents::create(context);
            sheet->parseString(text);
            rules += static_cast<unsigned>(sheet->childRules().size());
        }
    }
    auto elapsed = MonotonicTime::now() - start;
    EXPECT_EQ(parsedRules * passes, rules);
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

TEST(CSSConsumersBench, MarginsInsets) { run("MarginsInsets"_s, marginsInsetsBlocks(), Values::Valid, 0x212fce51585d4fdeULL, 650); }
TEST(CSSConsumersBench, BorderWidths) { run("BorderWidths"_s, borderWidthsBlocks(), Values::Valid, 0xe9f782e16adb8e8dULL, 750); }
TEST(CSSConsumersBench, FontVariantGroups) { run("FontVariantGroups"_s, fontVariantGroupsBlocks(), Values::Valid, 0x7a73ba4f172050d6ULL, 320); }
TEST(CSSConsumersBench, TextDecorationGroups) { run("TextDecorationGroups"_s, textDecorationGroupsBlocks(), Values::Valid, 0xe3d0f80015cdc7d3ULL, 600); }
TEST(CSSConsumersBench, BorderRadiusPairs) { run("BorderRadiusPairs"_s, borderRadiusPairsBlocks(), Values::Valid, 0x8d0477b7b69d3ca0ULL, 500); }
TEST(CSSConsumersBench, KeywordGroups) { run("KeywordGroups"_s, keywordGroupsBlocks(), Values::Valid, 0xbfda503034be6af6ULL, 600); }
TEST(CSSConsumersBench, IdentsIntegersTimes) { run("IdentsIntegersTimes"_s, identsIntegersTimesBlocks(), Values::Valid, 0x6339a06c9cbfe594ULL, 550); }
TEST(CSSConsumersBench, Shorthands) { run("Shorthands"_s, shorthandsBlocks(), Values::Valid, 0x11111383457331c3ULL, 150); }

TEST(CSSConsumersBench, ColorsHexNamed) { run("ColorsHexNamed"_s, colorsHexNamedBlocks(), Values::Valid, 0xb85589f4f1c377a6ULL, 800); }
TEST(CSSConsumersBench, ColorsFunctional) { run("ColorsFunctional"_s, colorsFunctionalBlocks(), Values::Valid, 0xb05b0a00bc7a5a9aULL, 275); }
TEST(CSSConsumersBench, ColorsRelative) { run("ColorsRelative"_s, colorsRelativeBlocks(), Values::Valid, 0x335c0d164f596351ULL, 115); }
TEST(CSSConsumersBench, ColorMix) { run("ColorMix"_s, colorMixBlocks(), Values::Valid, 0x594669eff9d18eaeULL, 200); }
TEST(CSSConsumersBench, LinearGradients) { run("LinearGradients"_s, linearGradientsBlocks(), Values::Valid, 0x98fab395f76f5a3aULL, 95); }
TEST(CSSConsumersBench, RadialGradients) { run("RadialGradients"_s, radialGradientsBlocks(), Values::Valid, 0x93e803d6b879e9ebULL, 85); }
TEST(CSSConsumersBench, ConicGradients) { run("ConicGradients"_s, conicGradientsBlocks(), Values::Valid, 0x5c71cd70069a571bULL, 90); }
TEST(CSSConsumersBench, Positions) { run("Positions"_s, positionsBlocks(), Values::Valid, 0x064053ed652431dbULL, 510); }
TEST(CSSConsumersBench, BackgroundLayers) { run("BackgroundLayers"_s, backgroundLayersBlocks(), Values::Valid, 0x2e9772d502e0907eULL, 50); }
TEST(CSSConsumersBench, PrefixedGradients) { run("PrefixedGradients"_s, prefixedGradientsBlocks(), Values::Valid, 0x2d3be6178e5cbf04ULL, 100); }
TEST(CSSConsumersBench, ShadowsBordersImages) { run("ShadowsBordersImages"_s, shadowsBordersImagesBlocks(), Values::Valid, 0x12d771aa1b7b596cULL, 130); }
TEST(CSSConsumersBench, InvalidColorsImages) { run("InvalidColorsImages"_s, invalidColorsImagesBlocks(), Values::Invalid, 0xeae961133aa717afULL, 370); }

TEST(CSSConsumersBench, FontFamilyStacks) { run("FontFamilyStacks"_s, fontFamilyStacksBlocks(), Values::Valid, 0x74464000cb39c39bULL, 250); }
TEST(CSSConsumersBench, FontShorthands) { runFontShorthands("FontShorthands"_s, 0x01cee9dfa656d72fULL, 100); }
TEST(CSSConsumersBench, FontFaceBlocks) { runFontFaceSheets("FontFaceBlocks"_s, fontFaceSheets(), 0x37dae25b194bca45ULL, 110); }
TEST(CSSConsumersBench, FontFeatureSettings) { run("FontFeatureSettings"_s, fontFeatureSettingsBlocks(), Values::Valid, 0xb0d631a684db0892ULL, 450); }
TEST(CSSConsumersBench, AlignmentKeywords) { run("AlignmentKeywords"_s, alignmentKeywordsBlocks(), Values::Valid, 0x4ece3ad8585bfb93ULL, 700); }
TEST(CSSConsumersBench, DisplayPairs) { run("DisplayPairs"_s, displayPairsBlocks(), Values::Valid, 0xe7a2d68e3a2ad997ULL, 900); }
TEST(CSSConsumersBench, GridTemplates) { run("GridTemplates"_s, gridTemplatesBlocks(), Values::Valid, 0xedd99a6c825560a5ULL, 240); }
TEST(CSSConsumersBench, GridLines) { run("GridLines"_s, gridLinesBlocks(), Values::Valid, 0x9ede339757af349bULL, 600); }
TEST(CSSConsumersBench, TimingFunctions) { runTimingFunctions("TimingFunctions"_s, 0x4b4b0e85e722e03aULL, 60); }
TEST(CSSConsumersBench, Filters) { run("Filters"_s, filtersBlocks(), Values::Valid, 0x015e10f5f94b8c04ULL, 250); }
TEST(CSSConsumersBench, ClipPaths) { run("ClipPaths"_s, clipPathsBlocks(), Values::Valid, 0xc2fda9b8edee40c9ULL, 200); }
TEST(CSSConsumersBench, ShapesRare) { run("ShapesRare"_s, shapesRareBlocks(), Values::Valid, 0xf3b04e261f1daf91ULL, 150); }
TEST(CSSConsumersBench, ContentAndCounters) { run("ContentAndCounters"_s, contentAndCountersBlocks(), Values::Valid, 0x6261324865658724ULL, 400); }
TEST(CSSConsumersBench, SmallFamilies) { run("SmallFamilies"_s, smallFamiliesBlocks(), Values::Valid, 0xe6b2ff5e0da3d285ULL, 450); }

} // namespace TestWebKitAPI
