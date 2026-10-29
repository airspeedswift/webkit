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

#include <WebCore/CSSParserContext.h>
#include <WebCore/CSSParserFastPaths.h>
#include <WebCore/CSSPrimitiveValue.h>
#include <WebCore/CSSPropertyNames.h>
#include <WebCore/CSSPropertyParserState.h>
#include <WebCore/CSSSerializationContext.h>
#include <WebCore/CSSValue.h>
#include <WebCore/CSSValueList.h>
#include <bit>
#include <cstdio>
#include <cstdlib>
#include <iterator>
#include <wtf/MonotonicTime.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

// Each test parses its property values once through the CSS fast paths and checks a checksum of the results. With
// WEBKIT_RUN_BENCHMARKS set, it then parses them a fixed number of times and prints the time taken.

namespace TestWebKitAPI {

using namespace WebCore;

namespace CSSFastPathsBenchmark {

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

static constexpr unsigned inputCount = 4096;

// An input is parsed either as a color with no property (parseSimpleColor) or as a property's value (maybeParseValue).
enum class Entry : uint8_t { Color, Value };

struct Input {
    Entry entry;
    CSSPropertyID property;
    CSSParserMode mode;
    String value;
};

static String make16Bit(const String& string)
{
    Vector<char16_t> characters;
    characters.reserveInitialCapacity(string.length());
    for (unsigned i = 0; i < string.length(); ++i)
        characters.append(string[i]);
    return String(characters.span());
}

enum class Width : uint8_t { Mixed, Wide };

// Every fourth input is a 16-bit copy, so each test parses both widths.
static Vector<Input> finish(Vector<Input>&& inputs, Width width = Width::Mixed)
{
    for (size_t i = 0; i < inputs.size(); ++i) {
        if (width == Width::Wide || i % 4 == 3)
            inputs[i].value = make16Bit(inputs[i].value);
    }
    return WTF::move(inputs);
}

static void appendDigits(StringBuilder& builder, Random& random, unsigned count)
{
    for (unsigned i = 0; i < count; ++i)
        builder.append(static_cast<char>('0' + random.below(10)));
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

static void appendHexDigits(StringBuilder& builder, Random& random, unsigned count)
{
    static constexpr char digits[] = "0123456789abcdefABCDEF";
    for (unsigned i = 0; i < count; ++i)
        builder.append(digits[random.below(sizeof(digits) - 1)]);
}

static Input color(String value, CSSParserMode mode = HTMLStandardMode)
{
    return { Entry::Color, CSSPropertyID::Invalid, mode, WTF::move(value) };
}

static Input value(CSSPropertyID property, String value, CSSParserMode mode = HTMLStandardMode)
{
    return { Entry::Value, property, mode, WTF::move(value) };
}

static String hexColorString(Random& random)
{
    StringBuilder builder;
    builder.append('#');
    unsigned kind = random.below(100);
    appendHexDigits(builder, random, kind < 70 ? 6 : kind < 85 ? 3 : kind < 92 ? 4 : 8);
    return builder.toString();
}

static Vector<Input> hexColorInputs()
{
    Random random(1);
    Vector<Input> inputs;
    for (unsigned i = 0; i < inputCount; ++i)
        inputs.append(color(hexColorString(random)));
    return finish(WTF::move(inputs));
}

static constexpr ASCIILiteral colorNames[] = {
    "aliceblue"_s, "alpha"_s, "antiquewhite"_s, "aqua"_s, "aquamarine"_s, "azure"_s, "beige"_s, "bisque"_s,
    "black"_s, "blanchedalmond"_s, "blue"_s, "blueviolet"_s, "brown"_s, "burlywood"_s, "cadetblue"_s,
    "chartreuse"_s, "chocolate"_s, "coral"_s, "cornflowerblue"_s, "cornsilk"_s, "crimson"_s, "cyan"_s,
    "darkblue"_s, "darkcyan"_s, "darkgoldenrod"_s, "darkgray"_s, "darkgrey"_s, "darkgreen"_s, "darkkhaki"_s,
    "darkmagenta"_s, "darkolivegreen"_s, "darkorange"_s, "darkorchid"_s, "darkred"_s, "darksalmon"_s,
    "darkseagreen"_s, "darkslateblue"_s, "darkslategray"_s, "darkslategrey"_s, "darkturquoise"_s, "darkviolet"_s,
    "deeppink"_s, "deepskyblue"_s, "dimgray"_s, "dimgrey"_s, "dodgerblue"_s, "firebrick"_s, "floralwhite"_s,
    "forestgreen"_s, "fuchsia"_s, "gainsboro"_s, "ghostwhite"_s, "gold"_s, "goldenrod"_s, "gray"_s, "grey"_s,
    "green"_s, "greenyellow"_s, "honeydew"_s, "hotpink"_s, "indianred"_s, "indigo"_s, "ivory"_s, "khaki"_s,
    "lavender"_s, "lavenderblush"_s, "lawngreen"_s, "lemonchiffon"_s, "lightblue"_s, "lightcoral"_s,
    "lightcyan"_s, "lightgoldenrodyellow"_s, "lightgray"_s, "lightgrey"_s, "lightgreen"_s, "lightpink"_s,
    "lightsalmon"_s, "lightseagreen"_s, "lightskyblue"_s, "lightslateblue"_s, "lightslategray"_s,
    "lightslategrey"_s, "lightsteelblue"_s, "lightyellow"_s, "lime"_s, "limegreen"_s, "linen"_s, "magenta"_s,
    "maroon"_s, "mediumaquamarine"_s, "mediumblue"_s, "mediumorchid"_s, "mediumpurple"_s, "mediumseagreen"_s,
    "mediumslateblue"_s, "mediumspringgreen"_s, "mediumturquoise"_s, "mediumvioletred"_s, "midnightblue"_s,
    "mintcream"_s, "mistyrose"_s, "moccasin"_s, "navajowhite"_s, "navy"_s, "oldlace"_s, "olive"_s, "olivedrab"_s,
    "orange"_s, "orangered"_s, "orchid"_s, "palegoldenrod"_s, "palegreen"_s, "paleturquoise"_s,
    "palevioletred"_s, "papayawhip"_s, "peachpuff"_s, "peru"_s, "pink"_s, "plum"_s, "powderblue"_s, "purple"_s,
    "rebeccapurple"_s, "red"_s, "rosybrown"_s, "royalblue"_s, "saddlebrown"_s, "salmon"_s, "sandybrown"_s,
    "seagreen"_s, "seashell"_s, "sienna"_s, "silver"_s, "skyblue"_s, "slateblue"_s, "slategray"_s,
    "slategrey"_s, "snow"_s, "springgreen"_s, "steelblue"_s, "tan"_s, "teal"_s, "thistle"_s, "tomato"_s,
    "transparent"_s, "turquoise"_s, "violet"_s, "violetred"_s, "wheat"_s, "white"_s, "whitesmoke"_s,
    "yellow"_s, "yellowgreen"_s,
};

static constexpr ASCIILiteral commonColorNames[] = {
    "black"_s, "white"_s, "red"_s, "transparent"_s, "gray"_s, "blue"_s, "green"_s, "orange"_s, "yellow"_s,
    "silver"_s, "navy"_s, "lightgray"_s,
};

static Vector<Input> namedColorInputs()
{
    Random random(2);
    Vector<Input> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        bool common = random.percent(50);
        StringView name = common ? random.pick(commonColorNames) : random.pick(colorNames);
        unsigned casing = random.below(10);
        if (casing == 8)
            inputs.append(color(name.convertToASCIIUppercase()));
        else if (casing == 9) {
            StringBuilder builder;
            for (unsigned j = 0; j < name.length(); ++j)
                builder.append(static_cast<char>(j % 2 ? toASCIIUpper(name[j]) : name[j]));
            inputs.append(color(builder.toString()));
        } else
            inputs.append(color(name.toString()));
    }
    return finish(WTF::move(inputs));
}

static void appendAlpha(StringBuilder& builder, Random& random)
{
    static constexpr ASCIILiteral alphas[] = { "0"_s, "1"_s, ".5"_s, "0.5"_s, ".1"_s, "0.8"_s, "1.0"_s, ".25"_s, "0.75"_s, "0.125"_s };
    builder.append(random.pick(alphas));
}

static ASCIILiteral separator(Random& random)
{
    return random.percent(50) ? ", "_s : ","_s;
}

static String rgbString(Random& random)
{
    StringBuilder builder;
    bool hasAlpha = random.percent(40);
    builder.append(hasAlpha && random.percent(70) ? "rgba("_s : "rgb("_s);
    bool percentages = random.percent(20);
    for (unsigned channel = 0; channel < 3; ++channel) {
        if (channel)
            builder.append(separator(random));
        if (percentages) {
            appendNumber(builder, random, 100, channel == 1 ? 1 : 0);
            builder.append('%');
        } else
            builder.append(random.below(256));
    }
    if (hasAlpha) {
        builder.append(separator(random));
        appendAlpha(builder, random);
    }
    builder.append(')');
    return builder.toString();
}

static Vector<Input> rgbFunctionInputs()
{
    Random random(3);
    Vector<Input> inputs;
    for (unsigned i = 0; i < inputCount; ++i)
        inputs.append(color(rgbString(random)));
    return finish(WTF::move(inputs));
}

static String hslString(Random& random)
{
    static constexpr ASCIILiteral hueUnits[] = { ""_s, ""_s, "deg"_s, "deg"_s, "DEG"_s, "rad"_s };
    StringBuilder builder;
    bool hasAlpha = random.percent(40);
    bool legacy = random.percent(60);
    builder.append(hasAlpha && random.percent(50) ? "hsla("_s : "hsl("_s);
    unsigned unit = random.below(std::size(hueUnits));
    if (hueUnits[unit] == "rad"_s)
        appendNumber(builder, random, 6, 3);
    else
        appendNumber(builder, random, 360, 1);
    builder.append(hueUnits[unit]);
    for (unsigned component = 0; component < 2; ++component) {
        builder.append(legacy ? separator(random) : " "_s);
        appendNumber(builder, random, 100, 1);
        builder.append('%');
    }
    if (hasAlpha) {
        builder.append(legacy ? separator(random) : " / "_s);
        if (!legacy && random.percent(30)) {
            builder.append(random.below(101));
            builder.append('%');
        } else
            appendAlpha(builder, random);
    }
    builder.append(')');
    return builder.toString();
}

static Vector<Input> hslFunctionInputs()
{
    Random random(4);
    Vector<Input> inputs;
    for (unsigned i = 0; i < inputCount; ++i)
        inputs.append(color(hslString(random)));
    return finish(WTF::move(inputs));
}

static constexpr CSSPropertyID nonnegativeLengthProperties[] = {
    CSSPropertyID::Width, CSSPropertyID::Height, CSSPropertyID::MinWidth, CSSPropertyID::MinHeight,
    CSSPropertyID::PaddingTop, CSSPropertyID::PaddingLeft, CSSPropertyID::FontSize,
};

static constexpr CSSPropertyID anyLengthProperties[] = {
    CSSPropertyID::Left, CSSPropertyID::Top, CSSPropertyID::Right, CSSPropertyID::Bottom,
    CSSPropertyID::MarginTop, CSSPropertyID::MarginLeft, CSSPropertyID::MarginBottom,
};

static String pxLengthString(Random& random, bool allowNegative)
{
    StringBuilder builder;
    if (allowNegative && random.percent(20))
        builder.append('-');
    if (random.percent(50))
        builder.append(random.below(256));
    else
        appendNumber(builder, random, 2000, random.percent(30) ? 2 : 0);
    builder.append("px"_s);
    return builder.toString();
}

static Vector<Input> lengthPxInputs()
{
    Random random(5);
    Vector<Input> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        bool any = random.percent(50);
        auto property = any ? random.pick(anyLengthProperties) : random.pick(nonnegativeLengthProperties);
        inputs.append(value(property, pxLengthString(random, any)));
    }
    return finish(WTF::move(inputs));
}

static String mixedLengthString(Random& random, bool allowNegative)
{
    StringBuilder builder;
    unsigned kind = random.below(10);
    if (kind == 0)
        return "0"_s;
    if (allowNegative && random.percent(15))
        builder.append('-');
    else if (random.percent(5))
        builder.append('+');
    if (kind == 1) {
        appendNumber(builder, random, 9, 1);
        builder.append('e');
        builder.append(random.below(3));
    } else if (kind == 2) {
        builder.append('.');
        appendDigits(builder, random, 1 + random.below(3));
    } else
        appendNumber(builder, random, 500, 3);
    static constexpr ASCIILiteral units[] = { "px"_s, "px"_s, "PX"_s, "Px"_s, "%"_s, "%"_s };
    builder.append(random.pick(units));
    return builder.toString();
}

static Vector<Input> lengthMixedUnitsInputs()
{
    static constexpr CSSPropertyID svgProperties[] = { CSSPropertyID::R, CSSPropertyID::Cx, CSSPropertyID::Cy, CSSPropertyID::X, CSSPropertyID::Y };
    Random random(6);
    Vector<Input> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        if (random.percent(15)) {
            // Unitless lengths in SVG attributes.
            auto property = random.pick(svgProperties);
            StringBuilder builder;
            appendNumber(builder, random, 300, 2);
            inputs.append(value(property, builder.toString(), SVGAttributeMode));
            continue;
        }
        bool any = random.percent(50);
        auto property = any ? random.pick(anyLengthProperties) : random.pick(nonnegativeLengthProperties);
        auto mode = random.percent(10) ? HTMLQuirksMode : HTMLStandardMode;
        inputs.append(value(property, mixedLengthString(random, any), mode));
    }
    return finish(WTF::move(inputs));
}

static Vector<Input> opacityInputs()
{
    Random random(7);
    Vector<Input> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        StringBuilder builder;
        unsigned kind = random.below(10);
        if (kind < 2)
            builder.append(random.percent(50) ? '0' : '1');
        else if (kind < 4) {
            builder.append('.');
            appendDigits(builder, random, 1 + random.below(2));
        } else if (kind < 8) {
            builder.append("0."_s);
            appendDigits(builder, random, 1 + random.below(3));
        } else {
            appendNumber(builder, random, 100, 1);
            builder.append('%');
        }
        inputs.append(value(CSSPropertyID::Opacity, builder.toString()));
    }
    return finish(WTF::move(inputs));
}

static void appendTranslateArgument(StringBuilder& builder, Random& random, bool allowPercentage)
{
    if (random.percent(10)) {
        builder.append('0');
        return;
    }
    if (random.percent(20))
        builder.append('-');
    appendNumber(builder, random, 400, random.percent(30) ? 2 : 0);
    builder.append(allowPercentage && random.percent(25) ? "%"_s : "px"_s);
}

static void appendTranslate(StringBuilder& builder, Random& random)
{
    unsigned kind = random.below(10);
    if (kind < 4) {
        builder.append("translate("_s);
        appendTranslateArgument(builder, random, true);
        builder.append(separator(random));
        appendTranslateArgument(builder, random, true);
    } else if (kind < 6) {
        builder.append("translateX("_s);
        appendTranslateArgument(builder, random, true);
    } else if (kind < 7) {
        builder.append("translateY("_s);
        appendTranslateArgument(builder, random, true);
    } else if (kind < 8) {
        builder.append("translateZ("_s);
        appendTranslateArgument(builder, random, false);
    } else {
        builder.append("translate3d("_s);
        appendTranslateArgument(builder, random, true);
        builder.append(separator(random));
        appendTranslateArgument(builder, random, true);
        builder.append(separator(random));
        appendTranslateArgument(builder, random, false);
    }
    builder.append(')');
}

static void appendSignedNumber(StringBuilder& builder, Random& random, unsigned maximumInteger, unsigned maximumFractionDigits)
{
    if (random.percent(25))
        builder.append('-');
    appendNumber(builder, random, maximumInteger, maximumFractionDigits);
}

static void appendMatrix3d(StringBuilder& builder, Random& random)
{
    builder.append("matrix3d("_s);
    for (unsigned i = 0; i < 16; ++i) {
        if (i)
            builder.append(separator(random));
        if (i == 15)
            builder.append('1');
        else if (i >= 12)
            appendSignedNumber(builder, random, 500, 2);
        else
            appendSignedNumber(builder, random, 1, 6);
    }
    builder.append(')');
}

static void appendRotate(StringBuilder& builder, Random& random)
{
    builder.append(random.percent(70) ? "rotate("_s : "rotateZ("_s);
    if (random.percent(70)) {
        appendSignedNumber(builder, random, 360, 1);
        builder.append("deg"_s);
    } else {
        appendSignedNumber(builder, random, 6, 4);
        builder.append("rad"_s);
    }
    builder.append(')');
}

static void appendScale3d(StringBuilder& builder, Random& random)
{
    builder.append("scale3d("_s);
    for (unsigned i = 0; i < 3; ++i) {
        if (i)
            builder.append(separator(random));
        appendNumber(builder, random, 2, 2);
    }
    builder.append(')');
}

static Vector<Input> transformTranslateInputs()
{
    Random random(8);
    Vector<Input> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        StringBuilder builder;
        appendTranslate(builder, random);
        inputs.append(value(CSSPropertyID::Transform, builder.toString()));
    }
    return finish(WTF::move(inputs));
}

static Vector<Input> transformMatrix3dInputs()
{
    Random random(9);
    Vector<Input> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        StringBuilder builder;
        appendMatrix3d(builder, random);
        inputs.append(value(CSSPropertyID::Transform, builder.toString()));
    }
    return finish(WTF::move(inputs));
}

static String transformListString(Random& random)
{
    StringBuilder builder;
    unsigned count = 2 + random.below(4);
    for (unsigned i = 0; i < count; ++i) {
        if (i)
            builder.append(' ');
        unsigned kind = random.below(10);
        if (kind < 4)
            appendTranslate(builder, random);
        else if (kind < 7)
            appendRotate(builder, random);
        else if (kind < 9)
            appendScale3d(builder, random);
        else
            appendMatrix3d(builder, random);
    }
    return builder.toString();
}

static Vector<Input> transformMixedListInputs()
{
    Random random(10);
    Vector<Input> inputs;
    for (unsigned i = 0; i < inputCount; ++i)
        inputs.append(value(CSSPropertyID::Transform, transformListString(random)));
    return finish(WTF::move(inputs));
}

// Values that every fast path hands back to the full parser.
static Input declinedInput(Random& random)
{
    static constexpr ASCIILiteral lengths[] = {
        "1em"_s, "2.5rem"_s, "calc(1px + 2px)"_s, "5.px"_s, "10px "_s, "1e400px"_s, "50vw"_s, "min(10px, 5%)"_s,
    };
    static constexpr ASCIILiteral transforms[] = {
        "translate(1em)"_s, "translate(10px)"_s, "rotate(1turn)"_s, "rotate(0)"_s, "scale(2)"_s,
        "translateZ(10%)"_s, "matrix(1, 0, 0, 1, 0, 0)"_s, "translateX(1px) skew(10deg)"_s,
    };
    static constexpr ASCIILiteral colors[] = {
        "rgb(1 2 3)"_s, "rgb(10%, 20, 30)"_s, "rgba(1, 2, 3, 50%)"_s, "color-mix(in srgb, red, blue)"_s,
        "lab(50% 40 59.5)"_s, "#12345"_s, "hsl(120grad, 50%, 50%)"_s, "notacolor"_s,
    };
    static constexpr ASCIILiteral opacities[] = { "inf"_s, "1e400"_s, "calc(0.5)"_s, "50 %"_s };
    switch (random.below(4)) {
    case 0: {
        auto property = random.pick(nonnegativeLengthProperties);
        return value(property, random.pick(lengths));
    }
    case 1:
        return value(CSSPropertyID::Transform, random.pick(transforms));
    case 2:
        return color(random.pick(colors));
    default:
        return value(CSSPropertyID::Opacity, random.pick(opacities));
    }
}

static Vector<Input> declinesInputs()
{
    Random random(11);
    Vector<Input> inputs;
    for (unsigned i = 0; i < inputCount; ++i)
        inputs.append(declinedInput(random));
    return finish(WTF::move(inputs));
}

// A stream of style.setProperty() calls as a page's script makes them.
static Vector<Input> setPropertyStream(uint64_t seed)
{
    static constexpr CSSPropertyID colorProperties[] = {
        CSSPropertyID::Color, CSSPropertyID::BackgroundColor, CSSPropertyID::BorderTopColor, CSSPropertyID::OutlineColor,
    };
    static constexpr ASCIILiteral colorKeywords[] = { "red"_s, "white"_s, "black"_s, "transparent"_s, "currentcolor"_s };
    static constexpr ASCIILiteral displays[] = { "block"_s, "none"_s, "flex"_s, "inline-block"_s, "grid"_s, "inline"_s };
    static constexpr ASCIILiteral positions[] = { "absolute"_s, "relative"_s, "fixed"_s, "static"_s };
    static constexpr ASCIILiteral visibilities[] = { "visible"_s, "hidden"_s };
    Random random(seed);
    Vector<Input> inputs;
    for (unsigned i = 0; i < inputCount; ++i) {
        unsigned kind = random.below(100);
        if (kind < 35) {
            bool any = random.percent(50);
            auto property = any ? random.pick(anyLengthProperties) : random.pick(nonnegativeLengthProperties);
            inputs.append(value(property, random.percent(80) ? pxLengthString(random, any) : mixedLengthString(random, any)));
        } else if (kind < 55) {
            auto property = random.pick(colorProperties);
            unsigned form = random.below(3);
            if (!form)
                inputs.append(value(property, hexColorString(random)));
            else if (form == 1)
                inputs.append(value(property, rgbString(random)));
            else
                inputs.append(value(property, random.pick(colorKeywords)));
        } else if (kind < 70) {
            StringBuilder builder;
            if (random.percent(60))
                appendTranslate(builder, random);
            else
                builder.append(transformListString(random));
            inputs.append(value(CSSPropertyID::Transform, builder.toString()));
        } else if (kind < 80) {
            StringBuilder builder;
            builder.append("0."_s);
            appendDigits(builder, random, 1 + random.below(2));
            inputs.append(value(CSSPropertyID::Opacity, builder.toString()));
        } else if (kind < 95) {
            unsigned which = random.below(3);
            if (!which)
                inputs.append(value(CSSPropertyID::Display, random.pick(displays)));
            else if (which == 1)
                inputs.append(value(CSSPropertyID::Position, random.pick(positions)));
            else
                inputs.append(value(CSSPropertyID::Visibility, random.pick(visibilities)));
        } else
            inputs.append(declinedInput(random));
    }
    return inputs;
}

static Vector<Input> setPropertyMixInputs()
{
    return finish(setPropertyStream(12));
}

// The SetPropertyMix stream with every value 16-bit; the checksum does not depend on width, so it is SetPropertyMix's.
static Vector<Input> wideInputs()
{
    return finish(setPropertyStream(12), Width::Wide);
}

class Parser {
public:
    Parser()
        : m_standard(strictCSSParserContext())
        , m_quirks(strictCSSParserContext())
        , m_svgAttribute(strictCSSParserContext())
    {
        m_quirks.mode = HTMLQuirksMode;
        m_svgAttribute.mode = SVGAttributeMode;
    }

    const CSSParserContext& context(CSSParserMode mode) const
    {
        switch (mode) {
        case HTMLQuirksMode:
            return m_quirks;
        case SVGAttributeMode:
            return m_svgAttribute;
        default:
            return m_standard;
        }
    }

    CSS::PropertyParserState& state(CSSParserMode mode)
    {
        switch (mode) {
        case HTMLQuirksMode:
            return m_quirksState;
        case SVGAttributeMode:
            return m_svgAttributeState;
        default:
            return m_standardState;
        }
    }

private:
    CSSParserContext m_standard;
    CSSParserContext m_quirks;
    CSSParserContext m_svgAttribute;
    CSS::PropertyParserState m_standardState { .context = m_standard };
    CSS::PropertyParserState m_quirksState { .context = m_quirks };
    CSS::PropertyParserState m_svgAttributeState { .context = m_svgAttribute };
};

static uint64_t mix(uint64_t hash, uint64_t value)
{
    return (hash ^ value) * 0x100000001b3ULL;
}

static uint64_t mix(uint64_t hash, StringView string)
{
    hash = mix(hash, string.length());
    for (auto character : string.codeUnits())
        hash = mix(hash, character);
    return hash;
}

static uint64_t packed(const SRGBA<uint8_t>& color)
{
    auto resolved = color.resolved();
    return static_cast<uint64_t>(resolved.red) << 24 | resolved.green << 16 | resolved.blue << 8 | resolved.alpha;
}

static uint64_t valueClass(const CSSValue& value)
{
    if (value.isPrimitiveValue())
        return 1;
    if (value.isKeywordValue())
        return 2;
    if (value.isColor())
        return 3;
    if (value.isFunctionValue())
        return 4;
    if (value.isTransformListValue())
        return 5;
    if (value.isValueList())
        return 6;
    return 7;
}

static uint64_t mixStructure(uint64_t hash, const CSSValue& value)
{
    hash = mix(hash, valueClass(value));
    if (auto* primitive = dynamicDowncast<CSSPrimitiveValue>(value)) {
        if (auto raw = primitive->raw()) {
            hash = mix(hash, static_cast<uint64_t>(raw->unit));
            hash = mix(hash, std::bit_cast<uint64_t>(raw->value));
        }
    } else if (auto* list = dynamicDowncast<CSSValueContainingVector>(value)) {
        hash = mix(hash, list->size());
        for (unsigned i = 0; i < list->size(); ++i)
            hash = mixStructure(hash, (*list)[i]);
    }
    return hash;
}

static uint64_t checksum(Parser& parser, const Vector<Input>& inputs, size_t& parsed)
{
    uint64_t hash = 0xcbf29ce484222325ULL;
    for (auto& input : inputs) {
        if (input.entry == Entry::Color) {
            auto result = CSSParserFastPaths::parseSimpleColor(input.value, parser.context(input.mode));
            parsed += !!result;
            hash = mix(hash, result ? packed(*result) : 1ULL << 40);
            continue;
        }
        auto result = CSSParserFastPaths::maybeParseValue(input.property, input.value, parser.state(input.mode));
        if (!result) {
            hash = mix(hash, 1ULL << 40);
            continue;
        }
        ++parsed;
        hash = mixStructure(hash, *result);
        hash = mix(hash, result->cssText(CSS::defaultSerializationContext()));
    }
    return hash;
}

static void run(ASCIILiteral name, const Vector<Input>& inputs, uint64_t expectedChecksum, unsigned passes)
{
    size_t length = 0;
    for (auto& input : inputs)
        length += input.value.length();
    ASSERT_GT(length, 0u);

    Parser parser;
    size_t parsedOnce = 0;
    auto result = checksum(parser, inputs, parsedOnce);
    EXPECT_EQ(expectedChecksum, result);
    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    size_t parsed = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass) {
        for (auto& input : inputs) {
            if (input.entry == Entry::Color) {
                if (CSSParserFastPaths::parseSimpleColor(input.value, parser.context(input.mode)))
                    ++parsed;
            } else if (CSSParserFastPaths::maybeParseValue(input.property, input.value, parser.state(input.mode)))
                ++parsed;
        }
    }
    auto elapsed = MonotonicTime::now() - start;
    EXPECT_EQ(parsedOnce * passes, parsed);
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, elapsed.milliseconds(),
        static_cast<double>(length) * passes / elapsed.microseconds(), static_cast<unsigned long long>(result));
}

} // namespace CSSFastPathsBenchmark

using namespace CSSFastPathsBenchmark;

TEST(CSSFastPathsBench, HexColor) { run("HexColor"_s, hexColorInputs(), 0xe376ac7f57a2d052ULL, 12500); }
TEST(CSSFastPathsBench, NamedColor) { run("NamedColor"_s, namedColorInputs(), 0x76a09bad0ae78c05ULL, 17000); }
TEST(CSSFastPathsBench, RGBFunction) { run("RGBFunction"_s, rgbFunctionInputs(), 0xd6790fab0ade27faULL, 6300); }
TEST(CSSFastPathsBench, HSLFunction) { run("HSLFunction"_s, hslFunctionInputs(), 0x30100965ab49b3a2ULL, 2500); }
TEST(CSSFastPathsBench, LengthPx) { run("LengthPx"_s, lengthPxInputs(), 0x6aef873ead92324cULL, 12000); }
TEST(CSSFastPathsBench, LengthMixedUnits) { run("LengthMixedUnits"_s, lengthMixedUnitsInputs(), 0x037fa5a68736e0c7ULL, 8800); }
TEST(CSSFastPathsBench, Opacity) { run("Opacity"_s, opacityInputs(), 0x74664baea25c0fa2ULL, 13500); }
TEST(CSSFastPathsBench, TransformTranslate) { run("TransformTranslate"_s, transformTranslateInputs(), 0xb9c0f009b50aba8bULL, 2400); }
TEST(CSSFastPathsBench, TransformMatrix3d) { run("TransformMatrix3d"_s, transformMatrix3dInputs(), 0xbeb1fd58bf42c248ULL, 520); }
TEST(CSSFastPathsBench, TransformMixedList) { run("TransformMixedList"_s, transformMixedListInputs(), 0x0683911476427307ULL, 500); }
TEST(CSSFastPathsBench, Declines) { run("Declines"_s, declinesInputs(), 0xee8f3e83ce3b6325ULL, 12800); }
TEST(CSSFastPathsBench, SetPropertyMix) { run("SetPropertyMix"_s, setPropertyMixInputs(), 0xea29ab1a95f713ccULL, 3200); }
TEST(CSSFastPathsBench, Wide) { run("Wide"_s, wideInputs(), 0xea29ab1a95f713ccULL, 3200); }

} // namespace TestWebKitAPI
