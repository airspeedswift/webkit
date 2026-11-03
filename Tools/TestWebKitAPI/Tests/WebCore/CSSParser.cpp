/*
 * Copyright (C) 2014 Igalia, S.L. All rights reserved.
 * Copyright (C) 2024-2026 Apple Inc. All rights reserved.
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

#include "TestPageHarness.h"

#include <WebCore/CSSColorValue.h>
#include <WebCore/CSSCustomPropertyValue.h>
#include <WebCore/CSSGridTemplateListValue.h>
#include <WebCore/CSSKeywordValueInlines.h>
#include <WebCore/CSSParser.h>
#include <WebCore/CSSSerializationContext.h>
#include <WebCore/CSSStyleDeclaration.h>
#include <WebCore/CSSValueList.h>
#include <WebCore/Color.h>
#include <WebCore/Document.h>
#include <WebCore/LocalDOMWindow.h>
#include <WebCore/MutableStyleProperties.h>
#include <WebCore/ProcessWarming.h>
#include <WebCore/StyleRule.h>
#include <WebCore/StyleSheetContents.h>
#include <WebCore/StyledElement.h>
#include <wtf/StackPointer.h>
#include <wtf/Threading.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

namespace TestWebKitAPI {

using namespace WebCore;

TEST(CSSParser, ParseColorInput)
{
    auto properties = MutableStyleProperties::create();

    ASSERT_TRUE(CSSParser::parseDeclarationList(properties, "color: #ff0000;"_s, strictCSSParserContext()));
    auto value = properties->getPropertyCSSValue(CSSPropertyID::Color).unsafeGet();

    ASSERT_TRUE(is<CSSValue>(value));
    Color valueColor(Color::red);

    EXPECT_TRUE(value->isColor());
    EXPECT_EQ(valueColor, CSSColorValue::absoluteColor(*value));
}

TEST(CSSParser, ParseColorWithNewlineAndWhitespacesInput)
{
    auto properties = MutableStyleProperties::create();

    ASSERT_TRUE(CSSParser::parseDeclarationList(properties, "color:  \n    #ff0000;"_s, strictCSSParserContext()));
    auto value = properties->getPropertyCSSValue(CSSPropertyID::Color).unsafeGet();

    ASSERT_TRUE(is<CSSValue>(value));
    Color valueColor(Color::red);

    EXPECT_TRUE(value->isColor());
    EXPECT_EQ(valueColor, CSSColorValue::absoluteColor(*value));
}

TEST(CSSParser, ParseCustomPropertyWithNewlineInput)
{
    auto properties = MutableStyleProperties::create();

    ASSERT_TRUE(CSSParser::parseDeclarationList(properties, "--mycustomprop: ValueHere\nWithAnotherValue;"_s, strictCSSParserContext()));
    auto customPropValue = downcast<CSSCustomPropertyValue>(properties->propertyAt(0).value());

    ASSERT_TRUE(is<CSSCustomPropertyValue>(customPropValue));
    auto customText = customPropValue->cssText(CSS::defaultSerializationContext());
    customText.convertTo16Bit();

    EXPECT_EQ("ValueHere\nWithAnotherValue"_s, customText);
}

TEST(CSSParser, ParseCustomPropertyWithNewlineAndWhitespacesInput)
{
    auto properties = MutableStyleProperties::create();

    ASSERT_TRUE(CSSParser::parseDeclarationList(properties, "--mycustomprop: ValueHere\nWithAnotherValue         ShouldPreserveAllWhitespace;"_s, strictCSSParserContext()));
    auto customPropValue = downcast<CSSCustomPropertyValue>(properties->propertyAt(0).value());

    ASSERT_TRUE(is<CSSCustomPropertyValue>(customPropValue));
    auto customText = customPropValue->cssText(CSS::defaultSerializationContext());
    customText.convertTo16Bit();

    EXPECT_EQ("ValueHere\nWithAnotherValue         ShouldPreserveAllWhitespace"_s, customText);
}

TEST(CSSParser, ParseCustomPropertyWithNewlineBetweenIdentInput)
{
    auto properties = MutableStyleProperties::create();

    ASSERT_TRUE(CSSParser::parseDeclarationList(properties, "--mycustomprop: foo\nbar"_s, strictCSSParserContext()));
    auto customPropValue = downcast<CSSCustomPropertyValue>(properties->propertyAt(0).value());

    ASSERT_TRUE(is<CSSCustomPropertyValue>(customPropValue));
    auto customText = customPropValue->cssText(CSS::defaultSerializationContext());
    customText.convertTo16Bit();

    EXPECT_EQ("foo\nbar"_s, customText);
}

TEST(CSSParser, ParseColorPropertyWithNewlineBetweenIdentInput)
{
    auto properties = MutableStyleProperties::create();

    ASSERT_TRUE(CSSParser::parseDeclarationList(properties, "color: #ff0000;"_s, strictCSSParserContext()));
    auto value = properties->propertyAt(0).value();

    ASSERT_TRUE(is<CSSValue>(value));

    Color valueColor(Color::red);

    EXPECT_TRUE(value->isColor());
    EXPECT_EQ(valueColor, CSSColorValue::absoluteColor(*value));
}

TEST(CSSParser, ParseTextTransformPropertyWithNewlineBetweenTwoIdentInput)
{
    auto check = [&] (auto& properties) {
        ASSERT_EQ((size_t)1, properties->size());

        auto value = properties->propertyAt(0).value();
        ASSERT_TRUE(is<CSSValueList>(value));
        auto& valueList = *downcast<CSSValueList>(value);

        ASSERT_EQ((size_t)2, valueList.size());
        EXPECT_EQ(CSSValueID::Capitalize, valueID(valueList[0]));
        EXPECT_EQ(CSSValueID::FullWidth, valueID(valueList[1]));
    };

    auto properties = MutableStyleProperties::create();
    ASSERT_TRUE(CSSParser::parseDeclarationList(properties, "text-transform: capitalize\nfull-width;"_s, strictCSSParserContext()));
    check(properties);

    auto value = properties->propertyAt(0).value();
    auto serialized = value->cssText(CSS::defaultSerializationContext());
    EXPECT_EQ(serialized, "capitalize full-width"_s);

    auto properties2 = MutableStyleProperties::create();

    StringBuilder builder;
    builder.append("text-transform: "_s, serialized, ";"_s);
    auto decl = builder.toString();

    ASSERT_TRUE(CSSParser::parseDeclarationList(properties2, decl, strictCSSParserContext()));
    check(properties2);
}

#if !ASAN_ENABLED

static constexpr uint8_t stackPaintByte = 0xA5;

// Paints from 1 KB below this frame down to paintSize below stackTop, clamped inside the stack; returns the lowest painted address.
NEVER_INLINE static uintptr_t paintStackBelow(uintptr_t stackTop, size_t paintSize)
{
    auto paintTop = reinterpret_cast<uintptr_t>(currentStackPointer()) - 1 * KB;
    auto stackLimit = reinterpret_cast<uintptr_t>(Thread::currentSingleton().stack().end()) + 64 * KB;
    auto paintBottom = std::max(stackTop - paintSize, stackLimit);
    memsetSpan(unsafeMakeSpan(reinterpret_cast<uint8_t*>(paintBottom), paintTop - paintBottom), stackPaintByte);
    WTF::compilerFence();
    return paintBottom;
}

NEVER_INLINE static void parseStyleSheet(StyleSheetContents& styleSheet, const String& text)
{
    styleSheet.parseString(text);
}

// Returns the distance from stackTop down to the lowest byte above paintBottom that no longer holds stackPaintByte.
NEVER_INLINE static size_t deepestStackUseBelow(uintptr_t stackTop, uintptr_t paintBottom)
{
    auto stack = unsafeMakeSpan(reinterpret_cast<const volatile uint8_t*>(paintBottom), stackTop - paintBottom);
    for (size_t i = 0; i < stack.size(); ++i) {
        if (stack[i] != stackPaintByte)
            return stackTop - (paintBottom + i);
    }
    return 0;
}

TEST(CSSParser, ParseMediaAndStyleRulesNestedToRuleListLimitStackUse)
{
    // 64 pairs nest 128 rule lists, the parser's maximumRuleListNestingLevel.
    constexpr unsigned nestingPairs = 64;
    // The default size of a secondary thread's stack on macOS.
    constexpr size_t stackUseLimit = 512 * KB;

    ProcessWarming::initializeNames();

    StringBuilder builder;
    for (unsigned i = 0; i < nestingPairs; ++i)
        builder.append("@media all { a { "_s);
    builder.append("color: green; "_s);
    for (unsigned i = 0; i < nestingPairs; ++i)
        builder.append("} } "_s);
    builder.append("b { color: red; }"_s);
    auto styleSheetText = builder.toString();

    Ref styleSheet = StyleSheetContents::create(strictCSSParserContext());

    auto stackTop = reinterpret_cast<uintptr_t>(currentStackPointer());
    auto paintBottom = paintStackBelow(stackTop, 1 * MB);
    parseStyleSheet(styleSheet, styleSheetText);
    auto stackUse = deepestStackUseBelow(stackTop, paintBottom);

    ASSERT_GT(stackTop - paintBottom, stackUseLimit);
    EXPECT_LT(stackUse, stackUseLimit);

    auto& rules = styleSheet->childRules();
    ASSERT_EQ(2u, rules.size());
    EXPECT_TRUE(rules.first()->isMediaRule());
    EXPECT_TRUE(rules.last()->isStyleRule());
}

#endif // !ASAN_ENABLED

static unsigned computeNumberOfTracks(const SpaceSeparatedVector<Variant<CSS::GridLineNames, CSS::GridTrackSize>>& repeatedTracks)
{
    unsigned numberOfTracks = 0;
    for (auto& repeatedTrack : repeatedTracks) {
        if (WTF::holdsAlternative<CSS::GridTrackSize>(repeatedTrack))
            ++numberOfTracks;
    }
    return numberOfTracks;
}

static unsigned computeNumberOfTracks(const CSSGridTemplateListValue& templateListValue)
{
    return WTF::switchOn(templateListValue.list(),
        [](CSS::Keyword::None) -> unsigned {
            return 0;
        },
        [](const CSS::GridSubgrid&) -> unsigned {
            return 0;
        },
        [](const CSS::GridTrackList& trackList) -> unsigned {
            unsigned numberOfTracks = 0;
            for (auto& track : trackList.value) {
                WTF::switchOn(track,
                    [&](const CSS::GridLineNames&) {
                        // Ignored in count.
                    },
                    [&](const CSS::GridTrackSize&) {
                        ++numberOfTracks;
                    },
                    [&](const CSS::GridTrackRepeatFunction& repeatFunction) {
                        WTF::switchOn(repeatFunction->repetitions,
                            [&](const CSS::Integer<CSS::Positive, unsigned>& numberOfRepetitions) {
                                return WTF::switchOn(numberOfRepetitions,
                                    [&](const CSS::Integer<CSS::Positive, unsigned>::Raw& numberOfRepetitions) {
                                        numberOfTracks += numberOfRepetitions.value * computeNumberOfTracks(repeatFunction->repeated);
                                    },
                                    [&](const CSS::Integer<CSS::Positive, unsigned>::Calc&) {
                                        // Number of repetitions is not yet calculated.
                                    }
                                );
                            },
                            [&](CSS::SpecificKeyword auto const& /* auto-fit or auto-fill */) {
                                // Ignored in count.
                            }
                        );
                    }
                );
            }
            return numberOfTracks;
        }
    );
}

TEST(CSSPropertyParser, GridTrackLimits)
{
    struct {
        const CSSPropertyID propertyID;
        ASCIILiteral input;
        const size_t output;
    }

    testCases[] = {
        { CSSPropertyID::GridTemplateColumns, "grid-template-columns: repeat(999999, 20px);"_s, 999999 },
        { CSSPropertyID::GridTemplateRows, "grid-template-rows: repeat(999999, 20px);"_s, 999999 },
        { CSSPropertyID::GridTemplateColumns, "grid-template-columns: repeat(1000000, 10%);"_s, 1000000 },
        { CSSPropertyID::GridTemplateRows, "grid-template-rows: repeat(1000000, 10%);"_s, 1000000 },
        { CSSPropertyID::GridTemplateColumns, "grid-template-columns: repeat(1000000, [first] -webkit-min-content [last]);"_s, 1000000 },
        { CSSPropertyID::GridTemplateRows, "grid-template-rows: repeat(1000000, [first] -webkit-min-content [last]);"_s, 1000000 },
        { CSSPropertyID::GridTemplateColumns, "grid-template-columns: repeat(1000001, auto);"_s, 1000000 },
        { CSSPropertyID::GridTemplateRows, "grid-template-rows: repeat(1000001, auto);"_s, 1000000 },
        { CSSPropertyID::GridTemplateColumns, "grid-template-columns: repeat(400000, 2em minmax(10px, -webkit-max-content) 0.5fr);"_s, 999999 },
        { CSSPropertyID::GridTemplateRows, "grid-template-rows: repeat(400000, 2em minmax(10px, -webkit-max-content) 0.5fr);"_s, 999999 },
        { CSSPropertyID::GridTemplateColumns, "grid-template-columns: repeat(600000, [first] 3vh 10% 2fr [nav] 10px auto 1fr 6em [last]);"_s, 999999 },
        { CSSPropertyID::GridTemplateRows, "grid-template-rows: repeat(600000, [first] 3vh 10% 2fr [nav] 10px auto 1fr 6em [last]);"_s, 999999 },
        { CSSPropertyID::GridTemplateColumns, "grid-template-columns: repeat(100000000000000000000, 10% 1fr);"_s, 1000000 },
        { CSSPropertyID::GridTemplateRows, "grid-template-rows: repeat(100000000000000000000, 10% 1fr);"_s, 1000000 },
        { CSSPropertyID::GridTemplateColumns, "grid-template-columns: repeat(100000000000000000000, 10% 5em 1fr auto auto 15px -webkit-min-content);"_s, 999999 },
        { CSSPropertyID::GridTemplateRows, "grid-template-rows: repeat(100000000000000000000, 10% 5em 1fr auto auto 15px -webkit-min-content);"_s, 999999 },
    };

    auto properties = MutableStyleProperties::create();

    for (auto& testCase : testCases) {
        ASSERT_TRUE(CSSParser::parseDeclarationList(properties, testCase.input, strictCSSParserContext()));
        RefPtr<CSSValue> value = properties->getPropertyCSSValue(testCase.propertyID);

        ASSERT_TRUE(is<CSSGridTemplateListValue>(value.get()));
        EXPECT_EQ(computeNumberOfTracks(downcast<CSSGridTemplateListValue>(*value)), testCase.output);
    }
}

TEST(CSSPropertyParser, CalcTreeSizes)
{
    // calc() trees of 15 to 18 nodes and of 40 nodes: a sum of min() terms, each three nodes. Each is parsed as a
    // width, and resolved as an element's text-indent, which keeps the percentages and resolves 1em to 16px.
    struct {
        ASCIILiteral input;
        ASCIILiteral output;
        ASCIILiteral computed;
    }

    testCases[] = {
        { "calc(min(1%, 1px) + min(2%, 2px) + min(3%, 3px) + min(4%, 4px) + 1% + 1em)"_s,
            "calc(1% + 1em + min(1%, 1px) + min(2%, 2px) + min(3%, 3px) + min(4%, 4px))"_s,
            "calc(1% + 16px + min(1%, 1px) + min(2%, 2px) + min(3%, 3px) + min(4%, 4px))"_s },
        { "calc(min(1%, 1px) + min(2%, 2px) + min(3%, 3px) + min(4%, 4px) + min(5%, 5px))"_s,
            "calc(min(1%, 1px) + min(2%, 2px) + min(3%, 3px) + min(4%, 4px) + min(5%, 5px))"_s,
            "calc(min(1%, 1px) + min(2%, 2px) + min(3%, 3px) + min(4%, 4px) + min(5%, 5px))"_s },
        { "calc(min(1%, 1px) + min(2%, 2px) + min(3%, 3px) + min(4%, 4px) + min(5%, 5px) + 1%)"_s,
            "calc(1% + min(1%, 1px) + min(2%, 2px) + min(3%, 3px) + min(4%, 4px) + min(5%, 5px))"_s,
            "calc(1% + min(1%, 1px) + min(2%, 2px) + min(3%, 3px) + min(4%, 4px) + min(5%, 5px))"_s },
        { "calc(min(1%, 1px) + min(2%, 2px) + min(3%, 3px) + min(4%, 4px) + min(5%, 5px) + 1% + 1em)"_s,
            "calc(1% + 1em + min(1%, 1px) + min(2%, 2px) + min(3%, 3px) + min(4%, 4px) + min(5%, 5px))"_s,
            "calc(1% + 16px + min(1%, 1px) + min(2%, 2px) + min(3%, 3px) + min(4%, 4px) + min(5%, 5px))"_s },
        { "calc(min(1%, 1px) + min(2%, 2px) + min(3%, 3px) + min(4%, 4px) + min(5%, 5px) + min(6%, 6px) + min(7%, 7px) + min(8%, 8px) + min(9%, 9px) + min(10%, 10px) + min(11%, 11px) + min(12%, 12px) + min(13%, 13px))"_s,
            "calc(min(1%, 1px) + min(2%, 2px) + min(3%, 3px) + min(4%, 4px) + min(5%, 5px) + min(6%, 6px) + min(7%, 7px) + min(8%, 8px) + min(9%, 9px) + min(10%, 10px) + min(11%, 11px) + min(12%, 12px) + min(13%, 13px))"_s,
            "calc(min(1%, 1px) + min(2%, 2px) + min(3%, 3px) + min(4%, 4px) + min(5%, 5px) + min(6%, 6px) + min(7%, 7px) + min(8%, 8px) + min(9%, 9px) + min(10%, 10px) + min(11%, 11px) + min(12%, 12px) + min(13%, 13px))"_s },
    };

    auto page = TestPageHarness::create();
    page.loadHTML("<!DOCTYPE html><html><body><div id='t' style='font-size: 16px'>x</div></body></html>"_s);
    RefPtr element = dynamicDowncast<StyledElement>(page.getElementById("t"_s));
    ASSERT_TRUE(element);
    RefPtr window = page.document().window();
    ASSERT_TRUE(window);

    for (auto& testCase : testCases) {
        auto properties = MutableStyleProperties::create();
        ASSERT_TRUE(CSSParser::parseDeclarationList(properties, makeString("width: "_s, testCase.input, ';'), strictCSSParserContext()));
        EXPECT_EQ(properties->getPropertyValue(CSSPropertyID::Width), String { testCase.output });

        ASSERT_TRUE(element->setInlineStyleProperty(CSSPropertyID::TextIndent, String { testCase.input }));
        EXPECT_EQ(window->getComputedStyle(*element, String { })->getPropertyValue("text-indent"_s), String { testCase.computed });
    }
}

TEST(CSSPropertyParser, CalcArgumentsAroundSixtyFour)
{
    // Sums and min()/max() of 64 to 66 arguments, whose numeric arguments merge across the 64th.
    auto terms = [](ASCIILiteral function, ASCIILiteral separator, unsigned count) {
        StringBuilder builder;
        for (unsigned i = 1; i <= count; ++i)
            builder.append(i > 1 ? separator : ""_s, function, '(', i, "%, "_s, i, "px)"_s);
        return builder.toString();
    };
    auto mins = [&](unsigned count) { return terms("min"_s, " + "_s, count); };
    auto maxes = [&](unsigned count) { return terms("max"_s, ", "_s, count); };

    std::pair<String, String> testCases[] = {
        { makeString("calc("_s, mins(63), " + 1px)"_s), makeString("calc(1px + "_s, mins(63), ')') },
        { makeString("calc("_s, mins(63), " + 1px + 2px)"_s), makeString("calc(3px + "_s, mins(63), ')') },
        { makeString("calc("_s, mins(64), " + 1px + 2px)"_s), makeString("calc(3px + "_s, mins(64), ')') },
        { makeString("calc(1px + "_s, mins(64), " + 2px)"_s), makeString("calc(3px + "_s, mins(64), ')') },
        { makeString("min("_s, maxes(63), ", 1px, 2px)"_s), makeString("min("_s, maxes(63), ", 1px)"_s) },
        { makeString("min("_s, maxes(64), ", 3px, 2px)"_s), makeString("min("_s, maxes(64), ", 2px)"_s) },
        { makeString("max(1px, "_s, maxes(64), ", 2px)"_s), makeString("max(2px, "_s, maxes(64), ')') },
    };

    for (auto& [input, output] : testCases) {
        auto properties = MutableStyleProperties::create();
        ASSERT_TRUE(CSSParser::parseDeclarationList(properties, makeString("width: "_s, input, ';'), strictCSSParserContext()));
        EXPECT_EQ(properties->getPropertyValue(CSSPropertyID::Width), output);
    }
}

TEST(CSSPropertyParser, CalcLongArgumentLists)
{
    // Sizes either side of the Swift code's stack buffers: trees of 127 to 130 nodes, one that has more than 128
    // nodes until its terms merge, and one nested in clamp(); argument lists of 29 to 37 and of 253 to 261 tokens;
    // unbalanced blocks; sums, min() and max() of 8 and 9 kinds of unit; calc-mix() of 16 and 17 items, and of 15 to
    // 17 items of more than 32 nodes in 31 to 33 tokens.
    auto join = [](auto&& term, ASCIILiteral separator, unsigned count) {
        StringBuilder builder;
        for (unsigned i = 1; i <= count; ++i)
            builder.append(i > 1 ? separator : ""_s, term(i));
        return builder.toString();
    };
    auto mins = [&](unsigned count) { return join([](unsigned i) { return makeString("min("_s, i, "%, "_s, i, "px)"_s); }, " + "_s, count); };
    auto pixels = [&](unsigned count, bool leading, bool trailing, bool parenthesized) {
        auto terms = join([&](unsigned i) { return i == 2 && parenthesized ? makeString("(2px)"_s) : makeString((i - 1) % 7 + 1, "px"_s); }, " + "_s, count);
        return makeString("calc("_s, leading ? " "_s : ""_s, terms, trailing ? " "_s : ""_s, ')');
    };
    auto mix = [&](unsigned count, auto&& weight) {
        return makeString("calc-mix("_s, join([&](unsigned i) { return makeString(i, "px "_s, weight(i)); }, ", "_s, count), ')');
    };

    std::pair<String, String> testCases[] = {
        { makeString("calc("_s, mins(42), ')'), makeString("calc("_s, mins(42), ')') },
        { makeString("calc("_s, mins(42), " + 1%)"_s), makeString("calc(1% + "_s, mins(42), ')') },
        { makeString("calc("_s, mins(42), " + 1% + 1em)"_s), makeString("calc(1% + 1em + "_s, mins(42), ')') },
        { makeString("calc("_s, mins(43), ')'), makeString("calc("_s, mins(43), ')') },
        { makeString("calc("_s, mins(40), " + "_s, join([](unsigned i) { return makeString((i - 1) % 7 + 1, "px"_s); }, " + "_s, 12), ')'), makeString("calc(43px + "_s, mins(40), ')') },
        { makeString("clamp(1px, calc("_s, mins(42), " + 1% + 1em), 100%)"_s), makeString("clamp(1px, 1% + 1em + "_s, mins(42), ", 100%)"_s) },
        { pixels(8, false, false, false), "calc(29px)"_s },
        { pixels(8, true, true, false), "calc(29px)"_s },
        { pixels(8, true, false, true), "calc(29px)"_s },
        { pixels(8, true, true, true), "calc(29px)"_s },
        { pixels(9, false, false, false), "calc(31px)"_s },
        { pixels(64, false, false, false), "calc(253px)"_s },
        { pixels(64, true, true, false), "calc(253px)"_s },
        { pixels(64, true, false, true), "calc(253px)"_s },
        { pixels(64, true, true, true), "calc(253px)"_s },
        { pixels(65, false, false, false), "calc(255px)"_s },
        { pixels(65, true, true, true), "calc(255px)"_s },
        { "calc(1px + (2px)"_s, "calc(3px)"_s },
        { "calc((1px + 2px)"_s, "calc(3px)"_s },
        { "calc(1px + (2px])"_s, String { } },
        { "calc(1em + 1ex + 1ch + 1rem + 1vw + 1vh + 1vmin + 1vmax + 2em + 2vmax + 3vmin)"_s, "calc(1ch + 3em + 1ex + 1rem + 1vh + 3vmax + 4vmin + 1vw)"_s },
        { "calc(1em + 1ex + 1ch + 1rem + 1vw + 1vh + 1vmin + 1vmax + 1lh + 2em + 2lh + 3vmax)"_s, "calc(1ch + 3em + 1ex + 3lh + 1rem + 1vh + 4vmax + 1vmin + 1vw)"_s },
        { "calc(1em + 1ex + 1ch + 1rem + 1vw + 1vh + 1vmin + 1vmax + 1lh + 0px + 2lh)"_s, "calc(1ch + 1em + 1ex + 3lh + 0px + 1rem + 1vh + 1vmax + 1vmin + 1vw)"_s },
        { "min(1em, 1ex, 1ch, 1rem, 1vw, 1vh, 1vmin, 1vmax, 1lh, 2lh, 0.5em)"_s, "min(0.5em, 1ex, 1ch, 1rem, 1vw, 1vh, 1vmin, 1vmax, 1lh)"_s },
        { "max(1em, 1ex, 1ch, 1rem, 1vw, 1vh, 1vmin, 1vmax, 2vmax, 1px, 2px)"_s, "max(1em, 1ex, 1ch, 1rem, 1vw, 1vh, 1vmin, 2vmax, 2px)"_s },
        { mix(16, [](unsigned) { return "6.250%"_s; }), "calc(8.5px)"_s },
        { mix(17, [](unsigned) { return "5.882%"_s; }), "calc(8.99946px)"_s },
        { mix(16, [](unsigned i) { return (i - 1) % 3 ? "0%"_s : "10%"_s; }), "calc(5.1px)"_s },
        { mix(17, [](unsigned i) { return (i - 1) % 3 ? "0%"_s : "10%"_s; }), "calc(5.1px)"_s },
        { makeString("calc-mix("_s, join([](unsigned i) { return makeString(i, "px"_s); }, ","_s, 15), ')'), "calc(8px)"_s },
        { makeString("calc-mix("_s, join([](unsigned i) { return makeString(i, "px"_s); }, ","_s, 16), ')'), "calc(8.5px)"_s },
        { makeString("calc-mix("_s, join([](unsigned i) { return makeString(i, "px"_s); }, ","_s, 17), ')'), "calc(9px)"_s },
        { makeString("calc-mix(1px 10%,"_s, join([](unsigned i) { return makeString(i + 1, "px"_s); }, ","_s, 15), ')'), "calc(8.2px)"_s },
    };

    auto context = strictCSSParserContext();
    context.cssCalcMixEnabled = true;
    for (auto& [input, output] : testCases) {
        auto properties = MutableStyleProperties::create();
        // No semicolon: an unclosed block would hold it.
        CSSParser::parseDeclarationList(properties, makeString("width: "_s, input), context);
        auto value = properties->getPropertyValue(CSSPropertyID::Width);
        if (output.isNull())
            EXPECT_TRUE(value.isEmpty());
        else
            EXPECT_EQ(value, output);
    }
}

TEST(CSSPropertyParser, TransformTokenCounts)
{
    // calc() arguments of 31 to 33 and 63 to 65 tokens.
    std::pair<ASCIILiteral, ASCIILiteral> calcCases[] = {
        { "translateX(calc(1px + (2px) + 3px + 4px + 5px + 6px + 7px + 1px))"_s, "translateX(calc(29px))"_s },
        { "translateX(calc(1px + (2px) + 3px + 4px + 5px + 6px + 7px + 1px ))"_s, "translateX(calc(29px))"_s },
        { "translateX(calc(1px + 2px + 3px + 4px + 5px + 6px + 7px + 1px + 2px))"_s, "translateX(calc(31px))"_s },
        { "translateX(calc(1px + (2px) + 3px + 4px + 5px + 6px + 7px + 1px + 2px + 3px + 4px + 5px + 6px + 7px + 1px + 2px))"_s, "translateX(calc(59px))"_s },
        { "translateX(calc(1px + (2px) + 3px + 4px + 5px + 6px + 7px + 1px + 2px + 3px + 4px + 5px + 6px + 7px + 1px + 2px ))"_s, "translateX(calc(59px))"_s },
        { "translateX(calc(1px + 2px + 3px + 4px + 5px + 6px + 7px + 1px + 2px + 3px + 4px + 5px + 6px + 7px + 1px + 2px + 3px))"_s, "translateX(calc(62px))"_s },
    };
    for (auto& [input, output] : calcCases) {
        auto properties = MutableStyleProperties::create();
        ASSERT_TRUE(CSSParser::parseDeclarationList(properties, makeString("transform: "_s, input, ';'), strictCSSParserContext()));
        EXPECT_EQ(properties->getPropertyValue(CSSPropertyID::Transform), output);
    }
}

TEST(CSSPropertyParser, GradientStopCounts)
{
    // Gradients of 15 to 17 stops, of keyword and rgb() colors: linear with a hint, conic, and -webkit-gradient().
    auto color = [](unsigned i) { return i % 2 ? "rgb(1, 2, 3)"_s : "red"_s; };
    auto stops = [&](unsigned count, ASCIILiteral unit, bool hint) {
        StringBuilder builder;
        for (unsigned i = 0; i < count; ++i)
            builder.append(i ? ", "_s : ""_s, hint && i == 1 ? "1%, "_s : ""_s, color(i), ' ', 2 * i, unit);
        return builder.toString();
    };
    auto colorStops = [&](unsigned count) {
        StringBuilder builder;
        for (unsigned i = 0; i < count; ++i)
            builder.append(i ? ", "_s : ""_s, "color-stop("_s, (i + 1) / 100.0, ", "_s, color(i), ')');
        return builder.toString();
    };

    for (unsigned count : { 15u, 16u, 17u }) {
        String values[] = {
            makeString("linear-gradient("_s, stops(count, "%"_s, true), ')'),
            makeString("conic-gradient("_s, stops(count, "deg"_s, false), ')'),
            makeString("-webkit-gradient(linear, 0% 0%, 100% 100%, "_s, colorStops(count), ')'),
        };
        for (auto& value : values) {
            auto properties = MutableStyleProperties::create();
            ASSERT_TRUE(CSSParser::parseDeclarationList(properties, makeString("background-image: "_s, value, ';'), strictCSSParserContext()));
            EXPECT_EQ(properties->getPropertyValue(CSSPropertyID::BackgroundImage), value);
        }
    }
}

} // namespace TestWebKitAPI
