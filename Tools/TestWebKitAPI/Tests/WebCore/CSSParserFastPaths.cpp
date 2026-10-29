/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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
#include <wtf/text/StringBuilder.h>

namespace TestWebKitAPI {

using namespace WebCore;

TEST(CSSParserFastPaths, ParseRgbAndRgba)
{
    StringView expectedValidInputs[] = {
        "rgb(255,0,0)"_s,
        "rgba(255,0,0)"_s,
        "rgb(255,0,0,1.0)"_s,
        "rgba(255,0,0,1.0)"_s,
        "rgb(0,255,0)"_s,
        "rgba(0,255,0)"_s,
        "rgb(0,255,0,1.0)"_s,
        "rgba(0,255,0,1.0)"_s,
        "rgb(0,0,255)"_s,
        "rgba(0,0,255)"_s,
        "rgb(0,0,255,1.0)"_s,
        "rgba(0,0,255,1.0)"_s
    };

    for (auto input : expectedValidInputs)
        EXPECT_TRUE(CSSParserFastPaths::parseSimpleColor(input, strictCSSParserContext()));

    StringView expectedInvalidInputs[] = {
        "rgb(255,0,0"_s,
        "rgba(255,0,0"_s,
        "rgb(255,0,0,"_s,
        "rgba(255,0,0,"_s,
        "rgb(255,0,0?"_s,
        "rgba(255,0,0?"_s,
        "rgb(255,0,0,)"_s,
        "rgba(255,0,0,)"_s,
        "rgb(255,0,0,1.0"_s,
        "rgba(255,0,0,1.0"_s,
        "rgb(255,0,0?1.0,"_s,
        "rgba(255,0,0?1.0,"_s,
        "rgb(255,0,0,1.0?"_s,
        "rgba(255,0,0,1.0?"_s,
        "rgb(255,0,0,1.0,)"_s,
        "rgba(255,0,0,1.0,)"_s,
    };

    for (auto input : expectedInvalidInputs)
        EXPECT_FALSE(CSSParserFastPaths::parseSimpleColor(input, strictCSSParserContext()));
}

TEST(CSSParserFastPaths, ParseLegacyHsl)
{
    auto& context = strictCSSParserContext();

    // Basic legacy HSL colors (comma-separated).
    auto red = CSSParserFastPaths::parseSimpleColor("hsl(0, 100%, 50%)"_s, context);
    ASSERT_TRUE(red);
    auto redResolved = red->resolved();
    EXPECT_EQ(redResolved.red, 255);
    EXPECT_EQ(redResolved.green, 0);
    EXPECT_EQ(redResolved.blue, 0);

    auto green = CSSParserFastPaths::parseSimpleColor("hsl(120, 100%, 50%)"_s, context);
    ASSERT_TRUE(green);
    auto greenResolved = green->resolved();
    EXPECT_EQ(greenResolved.red, 0);
    EXPECT_EQ(greenResolved.green, 255);
    EXPECT_EQ(greenResolved.blue, 0);

    auto blue = CSSParserFastPaths::parseSimpleColor("hsl(240, 100%, 50%)"_s, context);
    ASSERT_TRUE(blue);
    auto blueResolved = blue->resolved();
    EXPECT_EQ(blueResolved.red, 0);
    EXPECT_EQ(blueResolved.green, 0);
    EXPECT_EQ(blueResolved.blue, 255);

    // hsla() synonym.
    auto redA = CSSParserFastPaths::parseSimpleColor("hsla(0, 100%, 50%, 0.5)"_s, context);
    ASSERT_TRUE(redA);
    auto redAResolved = redA->resolved();
    EXPECT_EQ(redAResolved.red, 255);
    EXPECT_EQ(redAResolved.green, 0);
    EXPECT_EQ(redAResolved.blue, 0);
    EXPECT_EQ(redAResolved.alpha, 128);

    // With angle units.
    auto degColor = CSSParserFastPaths::parseSimpleColor("hsl(120deg, 100%, 50%)"_s, context);
    ASSERT_TRUE(degColor);
    EXPECT_EQ(degColor->resolved().green, 255);

    // Hue wrapping.
    auto wrapped = CSSParserFastPaths::parseSimpleColor("hsl(480, 100%, 50%)"_s, context);
    ASSERT_TRUE(wrapped);
    auto wrappedResolved = wrapped->resolved();
    EXPECT_EQ(wrappedResolved.red, 0);
    EXPECT_EQ(wrappedResolved.green, 255);
    EXPECT_EQ(wrappedResolved.blue, 0);
}

TEST(CSSParserFastPaths, ParseModernHsl)
{
    auto& context = strictCSSParserContext();

    // Basic modern HSL colors (space-separated).
    auto red = CSSParserFastPaths::parseSimpleColor("hsl(0 100% 50%)"_s, context);
    ASSERT_TRUE(red);
    auto redResolved = red->resolved();
    EXPECT_EQ(redResolved.red, 255);
    EXPECT_EQ(redResolved.green, 0);
    EXPECT_EQ(redResolved.blue, 0);

    auto green = CSSParserFastPaths::parseSimpleColor("hsl(120 100% 50%)"_s, context);
    ASSERT_TRUE(green);
    auto greenResolved = green->resolved();
    EXPECT_EQ(greenResolved.red, 0);
    EXPECT_EQ(greenResolved.green, 255);
    EXPECT_EQ(greenResolved.blue, 0);

    auto blue = CSSParserFastPaths::parseSimpleColor("hsl(240 100% 50%)"_s, context);
    ASSERT_TRUE(blue);
    auto blueResolved = blue->resolved();
    EXPECT_EQ(blueResolved.red, 0);
    EXPECT_EQ(blueResolved.green, 0);
    EXPECT_EQ(blueResolved.blue, 255);

    // Black and white.
    auto black = CSSParserFastPaths::parseSimpleColor("hsl(0 0% 0%)"_s, context);
    ASSERT_TRUE(black);
    auto blackResolved = black->resolved();
    EXPECT_EQ(blackResolved.red, 0);
    EXPECT_EQ(blackResolved.green, 0);
    EXPECT_EQ(blackResolved.blue, 0);

    auto white = CSSParserFastPaths::parseSimpleColor("hsl(0 0% 100%)"_s, context);
    ASSERT_TRUE(white);
    auto whiteResolved = white->resolved();
    EXPECT_EQ(whiteResolved.red, 255);
    EXPECT_EQ(whiteResolved.green, 255);
    EXPECT_EQ(whiteResolved.blue, 255);

    // With alpha (/ separator).
    auto semiRed = CSSParserFastPaths::parseSimpleColor("hsl(0 100% 50% / 0.5)"_s, context);
    ASSERT_TRUE(semiRed);
    auto semiRedResolved = semiRed->resolved();
    EXPECT_EQ(semiRedResolved.red, 255);
    EXPECT_EQ(semiRedResolved.green, 0);
    EXPECT_EQ(semiRedResolved.blue, 0);
    EXPECT_EQ(semiRedResolved.alpha, 128);

    // Alpha as percentage.
    auto alphaPercent = CSSParserFastPaths::parseSimpleColor("hsl(0 100% 50% / 50%)"_s, context);
    ASSERT_TRUE(alphaPercent);
    auto alphaPercentResolved = alphaPercent->resolved();
    EXPECT_EQ(alphaPercentResolved.red, 255);
    EXPECT_EQ(alphaPercentResolved.alpha, 128);

    // With angle units.
    auto degColor = CSSParserFastPaths::parseSimpleColor("hsl(120deg 100% 50%)"_s, context);
    ASSERT_TRUE(degColor);
    auto degColorResolved = degColor->resolved();
    EXPECT_EQ(degColorResolved.red, 0);
    EXPECT_EQ(degColorResolved.green, 255);
    EXPECT_EQ(degColorResolved.blue, 0);

    auto radColor = CSSParserFastPaths::parseSimpleColor("hsl(3.14rad 100% 50%)"_s, context);
    ASSERT_TRUE(radColor);
    // 3.14 rad ~= 179.9 deg, close to cyan (180 deg).
    EXPECT_EQ(radColor->resolved().red, 0);

    // hsla() synonym with modern syntax.
    auto hslaModern = CSSParserFastPaths::parseSimpleColor("hsla(120 100% 50% / 1)"_s, context);
    ASSERT_TRUE(hslaModern);
    auto hslaModernResolved = hslaModern->resolved();
    EXPECT_EQ(hslaModernResolved.green, 255);
    EXPECT_EQ(hslaModernResolved.alpha, 255);

    // No space around slash.
    auto noSpaceSlash = CSSParserFastPaths::parseSimpleColor("hsl(0 100% 50%/0.5)"_s, context);
    ASSERT_TRUE(noSpaceSlash);
    auto noSpaceSlashResolved = noSpaceSlash->resolved();
    EXPECT_EQ(noSpaceSlashResolved.red, 255);
    EXPECT_EQ(noSpaceSlashResolved.alpha, 128);

    // Hue wrapping.
    auto wrapped = CSSParserFastPaths::parseSimpleColor("hsl(480 100% 50%)"_s, context);
    ASSERT_TRUE(wrapped);
    auto wrappedResolved = wrapped->resolved();
    EXPECT_EQ(wrappedResolved.red, 0);
    EXPECT_EQ(wrappedResolved.green, 255);
    EXPECT_EQ(wrappedResolved.blue, 0);

    // Modern and legacy should produce the same result.
    auto modern = CSSParserFastPaths::parseSimpleColor("hsl(120 50% 75%)"_s, context);
    auto legacy = CSSParserFastPaths::parseSimpleColor("hsl(120, 50%, 75%)"_s, context);
    ASSERT_TRUE(modern);
    ASSERT_TRUE(legacy);
    EXPECT_EQ(*modern, *legacy);
}

TEST(CSSParserFastPaths, ParseModernHslInvalid)
{
    auto& context = strictCSSParserContext();

    // Missing closing paren.
    EXPECT_FALSE(CSSParserFastPaths::parseSimpleColor("hsl(0 100% 50%"_s, context));

    // Missing lightness.
    EXPECT_FALSE(CSSParserFastPaths::parseSimpleColor("hsl(0 100%)"_s, context));

    // Missing saturation and lightness.
    EXPECT_FALSE(CSSParserFastPaths::parseSimpleColor("hsl(0)"_s, context));

    // Empty.
    EXPECT_FALSE(CSSParserFastPaths::parseSimpleColor("hsl()"_s, context));

    // Mixing commas and spaces.
    EXPECT_FALSE(CSSParserFastPaths::parseSimpleColor("hsl(0 100%, 50%)"_s, context));

    // Alpha with comma instead of slash.
    EXPECT_FALSE(CSSParserFastPaths::parseSimpleColor("hsl(0 100% 50%, 0.5)"_s, context));

    // Slash without alpha value.
    EXPECT_FALSE(CSSParserFastPaths::parseSimpleColor("hsl(0 100% 50% /)"_s, context));

    // Double slash.
    EXPECT_FALSE(CSSParserFastPaths::parseSimpleColor("hsl(0 100% 50% / / 0.5)"_s, context));
}

TEST(CSSParserFastPaths, ParseNamedColorsInAnyCase)
{
    // Every name in ColorData.gperf, each of lowercase ASCII letters only.
    static constexpr ASCIILiteral names[] = {
        "aliceblue"_s, "alpha"_s, "antiquewhite"_s, "aqua"_s, "aquamarine"_s, "azure"_s, "beige"_s, "bisque"_s,
        "black"_s, "blanchedalmond"_s, "blue"_s, "blueviolet"_s, "brown"_s, "burlywood"_s, "cadetblue"_s,
        "chartreuse"_s, "chocolate"_s, "coral"_s, "cornflowerblue"_s, "cornsilk"_s, "crimson"_s, "cyan"_s,
        "darkblue"_s, "darkcyan"_s, "darkgoldenrod"_s, "darkgray"_s, "darkgrey"_s, "darkgreen"_s, "darkkhaki"_s,
        "darkmagenta"_s, "darkolivegreen"_s, "darkorange"_s, "darkorchid"_s, "darkred"_s, "darksalmon"_s,
        "darkseagreen"_s, "darkslateblue"_s, "darkslategray"_s, "darkslategrey"_s, "darkturquoise"_s,
        "darkviolet"_s, "deeppink"_s, "deepskyblue"_s, "dimgray"_s, "dimgrey"_s, "dodgerblue"_s, "firebrick"_s,
        "floralwhite"_s, "forestgreen"_s, "fuchsia"_s, "gainsboro"_s, "ghostwhite"_s, "gold"_s, "goldenrod"_s,
        "gray"_s, "grey"_s, "green"_s, "greenyellow"_s, "honeydew"_s, "hotpink"_s, "indianred"_s, "indigo"_s,
        "ivory"_s, "khaki"_s, "lavender"_s, "lavenderblush"_s, "lawngreen"_s, "lemonchiffon"_s, "lightblue"_s,
        "lightcoral"_s, "lightcyan"_s, "lightgoldenrodyellow"_s, "lightgray"_s, "lightgrey"_s, "lightgreen"_s,
        "lightpink"_s, "lightsalmon"_s, "lightseagreen"_s, "lightskyblue"_s, "lightslateblue"_s,
        "lightslategray"_s, "lightslategrey"_s, "lightsteelblue"_s, "lightyellow"_s, "lime"_s, "limegreen"_s,
        "linen"_s, "magenta"_s, "maroon"_s, "mediumaquamarine"_s, "mediumblue"_s, "mediumorchid"_s,
        "mediumpurple"_s, "mediumseagreen"_s, "mediumslateblue"_s, "mediumspringgreen"_s, "mediumturquoise"_s,
        "mediumvioletred"_s, "midnightblue"_s, "mintcream"_s, "mistyrose"_s, "moccasin"_s, "navajowhite"_s,
        "navy"_s, "oldlace"_s, "olive"_s, "olivedrab"_s, "orange"_s, "orangered"_s, "orchid"_s,
        "palegoldenrod"_s, "palegreen"_s, "paleturquoise"_s, "palevioletred"_s, "papayawhip"_s, "peachpuff"_s,
        "peru"_s, "pink"_s, "plum"_s, "powderblue"_s, "purple"_s, "rebeccapurple"_s, "red"_s, "rosybrown"_s,
        "royalblue"_s, "saddlebrown"_s, "salmon"_s, "sandybrown"_s, "seagreen"_s, "seashell"_s, "sienna"_s,
        "silver"_s, "skyblue"_s, "slateblue"_s, "slategray"_s, "slategrey"_s, "snow"_s, "springgreen"_s,
        "steelblue"_s, "tan"_s, "teal"_s, "thistle"_s, "tomato"_s, "transparent"_s, "turquoise"_s, "violet"_s,
        "violetred"_s, "wheat"_s, "white"_s, "whitesmoke"_s, "yellow"_s, "yellowgreen"_s
    };
    EXPECT_EQ(std::size(names), 152u);

    for (auto name : names) {
        StringView lower { name };
        auto color = CSSParserFastPaths::parseNamedColor(lower);
        ASSERT_TRUE(color) << name.characters();
        StringBuilder upper;
        for (size_t i = 0; i < lower.length(); ++i) {
            ASSERT_TRUE(isASCIILower(lower[i])) << name.characters();
            upper.append(toASCIIUpper(lower[i]));
        }
        EXPECT_EQ(CSSParserFastPaths::parseNamedColor(upper.toString()), color) << name.characters();

        // Any other ASCII character in place of a letter is not a name.
        for (char16_t character = 0; character < 0x80; ++character) {
            if (isASCIIAlpha(character))
                continue;
            for (unsigned position : { 0u, lower.length() / 2, lower.length() - 1 }) {
                StringBuilder builder;
                builder.append(lower.left(position), character, lower.substring(position + 1));
                EXPECT_FALSE(CSSParserFastPaths::parseNamedColor(builder.toString()))
                    << name.characters() << " " << static_cast<unsigned>(character) << " at " << position;
            }
        }
    }
}

TEST(CSSParserFastPaths, ParseNumbersAroundExactConversionLimits)
{
    // A decimal number with at most 19 significant digits, a significand of at most 2^53 and an exponent from -22 to
    // 22 converts with one exact multiplication or division. These are on both sides of each limit.
    struct TestCase {
        ASCIILiteral input;
        double expected;
    };
    static constexpr TestCase testCases[] = {
        { "9007199254740992"_s, 9007199254740992.0 },
        { "9007199254740993"_s, 9007199254740993.0 },
        { "9007199254740995"_s, 9007199254740995.0 },
        { "1234567890123456789"_s, 1234567890123456789.0 },
        { "12345678901234567890"_s, 12345678901234567890.0 },
        { "0.1234567890123456789"_s, 0.1234567890123456789 },
        { "0.12345678901234567891"_s, 0.12345678901234567891 },
        { "1e22"_s, 1e22 },
        { "1e23"_s, 1e23 },
        { "3e-22"_s, 3e-22 },
        { "3e-23"_s, 3e-23 },
        { "0.0000000000000000000003"_s, 0.0000000000000000000003 },
        { "0.00000000000000000000003"_s, 0.00000000000000000000003 },
        { "123.456e5"_s, 123.456e5 },
        { "-0.1"_s, -0.1 },
        { "1.7976931348623157e308"_s, 1.7976931348623157e308 },
    };

    CSS::PropertyParserState state { .context = strictCSSParserContext() };
    for (auto& testCase : testCases) {
        RefPtr value = CSSParserFastPaths::maybeParseValue(CSSPropertyID::Opacity, StringView { testCase.input }, state);
        ASSERT_TRUE(value) << testCase.input.characters();
        auto raw = downcast<CSSPrimitiveValue>(*value).raw();
        ASSERT_TRUE(raw) << testCase.input.characters();
        EXPECT_EQ(raw->value, testCase.expected) << testCase.input.characters();
    }

    // An explicit exponent of a million or more, after a fraction with as many digits: 10^-1000000 times
    // 10^999999, 10^1000000 and 10^10000000.
    struct LongTestCase {
        ASCIILiteral exponent;
        std::optional<double> expected;
    };
    static constexpr LongTestCase longTestCases[] = {
        { "999999"_s, 0.1 },
        { "1000000"_s, 1.0 },
        { "10000000"_s, std::nullopt },
    };
    for (auto& testCase : longTestCases) {
        StringBuilder builder;
        builder.append("0."_s);
        for (unsigned i = 0; i < 999999; ++i)
            builder.append('0');
        builder.append("1e"_s, testCase.exponent);
        auto input = builder.toString();
        RefPtr value = CSSParserFastPaths::maybeParseValue(CSSPropertyID::Opacity, input, state);
        if (!testCase.expected) {
            EXPECT_FALSE(value) << testCase.exponent.characters();
            continue;
        }
        ASSERT_TRUE(value) << testCase.exponent.characters();
        auto raw = downcast<CSSPrimitiveValue>(*value).raw();
        ASSERT_TRUE(raw) << testCase.exponent.characters();
        EXPECT_EQ(raw->value, *testCase.expected) << testCase.exponent.characters();
    }
}

TEST(CSSParserFastPaths, ParseNumbersAroundLargestDouble)
{
    // A number of 10^309 or more is above the largest double, so it is infinite, which an opacity cannot be. These
    // are on both sides of that bound, at both widths.
    struct TestCase {
        ASCIILiteral input;
        std::optional<double> expected;
    };
    static constexpr TestCase testCases[] = {
        { "1e308"_s, 1e308 },
        { "-1e308"_s, -1e308 },
        { "1e309"_s, std::nullopt },
        { "-1e309"_s, std::nullopt },
        { "+1e309"_s, std::nullopt },
        { "0.1e309"_s, 1e308 },
        { "0.1e310"_s, std::nullopt },
        { "10e307"_s, 1e308 },
        { "10e308"_s, std::nullopt },
        { "17976931348623157e292"_s, 1.7976931348623157e308 },
        { "17976931348623159e292"_s, std::nullopt },
        { "1234567890123456789e290"_s, 1234567890123456789e290 },
        { "1234567890123456789e291"_s, std::nullopt },
        { "0e400"_s, 0.0 },
        { "1e1000000"_s, std::nullopt },
    };

    CSS::PropertyParserState state { .context = strictCSSParserContext() };
    for (auto& testCase : testCases) {
        String narrow { testCase.input };
        Vector<char16_t> characters;
        for (unsigned i = 0; i < narrow.length(); ++i)
            characters.append(narrow[i]);
        for (auto& input : { narrow, String { characters.span() } }) {
            RefPtr value = CSSParserFastPaths::maybeParseValue(CSSPropertyID::Opacity, input, state);
            if (!testCase.expected) {
                EXPECT_FALSE(value) << testCase.input.characters();
                continue;
            }
            ASSERT_TRUE(value) << testCase.input.characters();
            auto raw = downcast<CSSPrimitiveValue>(*value).raw();
            ASSERT_TRUE(raw) << testCase.input.characters();
            EXPECT_EQ(raw->value, *testCase.expected) << testCase.input.characters();
        }
    }

    // A transform keeps an infinite argument.
    struct TransformTestCase {
        ASCIILiteral input;
        ASCIILiteral expected;
    };
    static constexpr TransformTestCase transformTestCases[] = {
        { "scale3d(1e309, 1, 1)"_s, "scale3d(infinity, 1, 1)"_s },
        { "scale3d(-1e309, 1, 1)"_s, "scale3d(-infinity, 1, 1)"_s },
        { "scale3d(17976931348623159e292, 1, 1)"_s, "scale3d(infinity, 1, 1)"_s },
        { "scale3d(1, 1, 1e309)"_s, "scale3d(1, 1, infinity)"_s },
    };
    for (auto& testCase : transformTestCases) {
        String narrow { testCase.input };
        Vector<char16_t> characters;
        for (unsigned i = 0; i < narrow.length(); ++i)
            characters.append(narrow[i]);
        for (auto& input : { narrow, String { characters.span() } }) {
            RefPtr value = CSSParserFastPaths::maybeParseValue(CSSPropertyID::Transform, input, state);
            ASSERT_TRUE(value) << testCase.input.characters();
            EXPECT_EQ(value->cssText(CSS::defaultSerializationContext()), String { testCase.expected }) << testCase.input.characters();
        }
    }
}

} // namespace TestWebKitAPI
