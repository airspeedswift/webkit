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
#include "TestPageHarness.h"
#include <WebCore/CSSParser.h>
#include <WebCore/CSSParserContext.h>
#include <WebCore/CSSPropertyNames.h>
#include <WebCore/CSSStyleDeclaration.h>
#include <WebCore/CSSUnits.h>
#include <WebCore/Document.h>
#include <WebCore/Element.h>
#include <WebCore/LocalDOMWindow.h>
#include <WebCore/MutableStyleProperties.h>
#include <WebCore/StyleProperties.h>
#include <WebCore/StyledElement.h>
#include <cstdio>
#include <cstdlib>
#include <iterator>
#include <wtf/MonotonicTime.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

// Each test runs its calc() inputs once through a public WebCore entry point (the declaration parser, style
// resolution, getComputedStyle) and checks a checksum of the results. With WEBKIT_RUN_BENCHMARKS set, it then repeats
// the work a fixed number of times and prints the time taken.
//
// The generators make every random draw in its own statement, so the inputs do not depend on the order in which a
// compiler evaluates function arguments.

namespace TestWebKitAPI {

using namespace WebCore;

namespace CSSCalcBenchmark {

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

static void appendDimension(StringBuilder& builder, Random& random, unsigned maximumInteger, ASCIILiteral unit)
{
    appendNumber(builder, random, maximumInteger, 2);
    builder.append(unit);
}

static constexpr ASCIILiteral lengthUnits[] = { "px"_s, "px"_s, "px"_s, "em"_s, "rem"_s, "vw"_s, "%"_s, "%"_s };

static void appendLengthPercentage(StringBuilder& builder, Random& random)
{
    auto unit = random.pick(lengthUnits);
    appendDimension(builder, random, unit == "%"_s ? 100 : 400, unit);
}

static ASCIILiteral additiveOperator(Random& random)
{
    return random.percent(50) ? " + "_s : " - "_s;
}

// MARK: - Declaration blocks, parsed by the declaration-list parser.

struct Property {
    CSSPropertyID id;
    ASCIILiteral name;
};

struct Block {
    String text;
    Vector<CSSPropertyID> properties;
};

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

static constexpr Property lengthPercentageProperties[] = {
    { CSSPropertyID::Width, "width"_s }, { CSSPropertyID::Height, "height"_s },
    { CSSPropertyID::MinWidth, "min-width"_s }, { CSSPropertyID::MinHeight, "min-height"_s },
    { CSSPropertyID::MaxWidth, "max-width"_s }, { CSSPropertyID::MaxHeight, "max-height"_s },
    { CSSPropertyID::MarginTop, "margin-top"_s }, { CSSPropertyID::MarginRight, "margin-right"_s },
    { CSSPropertyID::MarginBottom, "margin-bottom"_s }, { CSSPropertyID::MarginLeft, "margin-left"_s },
    { CSSPropertyID::PaddingTop, "padding-top"_s }, { CSSPropertyID::PaddingRight, "padding-right"_s },
    { CSSPropertyID::PaddingBottom, "padding-bottom"_s }, { CSSPropertyID::PaddingLeft, "padding-left"_s },
    { CSSPropertyID::Left, "left"_s }, { CSSPropertyID::Top, "top"_s },
};

static constexpr Property opacity { CSSPropertyID::Opacity, "opacity"_s };
static constexpr Property rotate { CSSPropertyID::Rotate, "rotate"_s };
static constexpr Property transform { CSSPropertyID::Transform, "transform"_s };
static constexpr Property lineHeight { CSSPropertyID::LineHeight, "line-height"_s };
static constexpr Property zIndex { CSSPropertyID::ZIndex, "z-index"_s };
static constexpr Property marginLeft { CSSPropertyID::MarginLeft, "margin-left"_s };

static constexpr unsigned inputCount = 4096;

// The `calc(100% - 10px)` family: one percentage and one length, in either order.
static Vector<Block> simpleSumBlocks()
{
    Random random(101);
    Vector<Block> blocks;
    BlockBuilder builder;
    for (unsigned i = 0; i < inputCount; ++i) {
        StringBuilder value;
        value.append("calc("_s);
        bool percentageFirst = random.percent(75);
        unsigned percentage = random.below(101);
        unsigned length = random.below(501);
        auto op = additiveOperator(random);
        if (percentageFirst)
            value.append(percentage, '%', op, length, "px"_s);
        else
            value.append(length, "px"_s, op, percentage, '%');
        value.append(')');
        builder.add(lengthPercentageProperties[i % std::size(lengthPercentageProperties)], value.toString());
        if (builder.properties.size() == std::size(lengthPercentageProperties))
            blocks.append(builder.take());
    }
    return blocks;
}

static void appendNestedExpression(StringBuilder& builder, Random& random, unsigned depth)
{
    if (!depth) {
        appendLengthPercentage(builder, random);
        return;
    }
    unsigned kind = random.below(10);
    if (kind < 3) {
        builder.append(random.percent(50) ? "min("_s : "max("_s);
        unsigned count = 2 + random.below(2);
        for (unsigned i = 0; i < count; ++i) {
            if (i)
                builder.append(", "_s);
            appendNestedExpression(builder, random, depth - 1);
        }
        builder.append(')');
    } else if (kind < 5) {
        builder.append("clamp("_s);
        appendNestedExpression(builder, random, depth - 1);
        builder.append(", "_s);
        appendNestedExpression(builder, random, depth - 1);
        builder.append(", "_s);
        appendNestedExpression(builder, random, depth - 1);
        builder.append(')');
    } else if (kind < 8) {
        builder.append('(');
        appendNestedExpression(builder, random, depth - 1);
        builder.append(additiveOperator(random));
        appendNestedExpression(builder, random, depth - 1);
        builder.append(')');
    } else if (kind < 9) {
        builder.append('(');
        appendNestedExpression(builder, random, depth - 1);
        builder.append(" * "_s);
        appendNumber(builder, random, 3, 2);
        builder.append(')');
    } else
        appendLengthPercentage(builder, random);
}

// min(), max() and clamp() nested two to five deep over lengths in several units and percentages.
static Vector<Block> nestedMinMaxBlocks()
{
    Random random(102);
    Vector<Block> blocks;
    BlockBuilder builder;
    for (unsigned i = 0; i < inputCount; ++i) {
        StringBuilder value;
        unsigned depth = 2 + random.below(4);
        unsigned outer = random.below(3);
        value.append(outer == 0 ? "min("_s : outer == 1 ? "max("_s : "calc("_s);
        appendNestedExpression(value, random, depth - 1);
        value.append(outer == 2 ? " + "_s : ", "_s);
        appendNestedExpression(value, random, depth - 1);
        value.append(')');
        builder.add(lengthPercentageProperties[i % std::size(lengthPercentageProperties)], value.toString());
        if (builder.properties.size() == 8)
            blocks.append(builder.take());
    }
    if (!builder.properties.isEmpty())
        blocks.append(builder.take());
    return blocks;
}

static void appendAngle(StringBuilder& builder, Random& random)
{
    static constexpr ASCIILiteral units[] = { "deg"_s, "deg"_s, "rad"_s, "grad"_s, "turn"_s };
    auto unit = random.pick(units);
    if (random.percent(20))
        builder.append('-');
    appendDimension(builder, random, unit == "deg"_s || unit == "grad"_s ? 360 : 3, unit);
}

static void appendFraction(StringBuilder& builder, Random& random)
{
    if (random.percent(20))
        builder.append('-');
    builder.append("0."_s);
    appendDigits(builder, random, 1 + random.below(3));
}

// The trigonometric, exponential, rounding and sign-related functions over numbers, lengths and angles.
static String mathFunctionValue(Random& random, Property& property)
{
    static constexpr ASCIILiteral roundingStrategies[] = { ""_s, "nearest, "_s, "up, "_s, "down, "_s, "to-zero, "_s };
    static constexpr ASCIILiteral trigonometric[] = { "sin("_s, "cos("_s, "tan("_s };
    static constexpr ASCIILiteral inverseTrigonometric[] = { "asin("_s, "acos("_s, "atan("_s };
    StringBuilder builder;
    switch (random.below(12)) {
    case 0:
        property = opacity;
        builder.append("calc("_s, random.pick(trigonometric));
        appendAngle(builder, random);
        builder.append(") * 0.5 + 0.5)"_s);
        break;
    case 1:
        property = rotate;
        builder.append(random.pick(inverseTrigonometric));
        appendFraction(builder, random);
        builder.append(')');
        break;
    case 2:
        property = rotate;
        builder.append("atan2("_s);
        appendDimension(builder, random, 100, "px"_s);
        builder.append(", "_s);
        appendDimension(builder, random, 100, "px"_s);
        builder.append(')');
        break;
    case 3:
        property = transform;
        builder.append("rotate(calc("_s, random.pick(trigonometric));
        appendAngle(builder, random);
        builder.append(") * 1rad)) translateX(calc(10px * "_s, random.pick(trigonometric));
        appendAngle(builder, random);
        builder.append(")))"_s);
        break;
    case 4:
        property = opacity;
        builder.append(random.percent(50) ? "exp(-"_s : "sqrt(0."_s);
        appendDigits(builder, random, 1 + random.below(2));
        builder.append(')');
        break;
    case 5:
        property = lineHeight;
        builder.append("pow("_s);
        appendNumber(builder, random, 2, 2);
        builder.append(", "_s);
        appendNumber(builder, random, 3, 1);
        builder.append(')');
        break;
    case 6:
        property = lineHeight;
        builder.append("log("_s);
        appendNumber(builder, random, 100, 2);
        if (random.percent(50)) {
            builder.append(", "_s);
            builder.append(2 + random.below(9));
        }
        builder.append(')');
        break;
    case 7:
        property = random.pick(lengthPercentageProperties);
        builder.append("round("_s, random.pick(roundingStrategies));
        appendLengthPercentage(builder, random);
        builder.append(", "_s);
        appendDimension(builder, random, 16, "px"_s);
        builder.append(')');
        break;
    case 8:
        property = zIndex;
        builder.append("round("_s, random.pick(roundingStrategies));
        appendNumber(builder, random, 1000, 2);
        builder.append(random.percent(50) ? ", 1)"_s : ", 10)"_s);
        break;
    case 9:
        property = random.pick(lengthPercentageProperties);
        builder.append(random.percent(50) ? "mod("_s : "rem("_s);
        if (random.percent(30))
            builder.append('-');
        appendDimension(builder, random, 400, "px"_s);
        builder.append(", "_s);
        appendDimension(builder, random, 30, "px"_s);
        builder.append(')');
        break;
    case 10:
        property = random.pick(lengthPercentageProperties);
        builder.append("hypot("_s);
        appendDimension(builder, random, 100, "px"_s);
        builder.append(", "_s);
        appendDimension(builder, random, 100, "px"_s);
        builder.append(')');
        break;
    default:
        property = marginLeft;
        builder.append("calc(abs(-"_s);
        appendDimension(builder, random, 100, "px"_s);
        builder.append(") * sign("_s);
        appendFraction(builder, random);
        builder.append(") + 1px * exp("_s);
        appendNumber(builder, random, 2, 2);
        builder.append("))"_s);
        break;
    }
    return builder.toString();
}

static Vector<Block> mathFunctionsBlocks()
{
    Random random(103);
    Vector<Block> blocks;
    BlockBuilder builder;
    for (unsigned i = 0; i < inputCount; ++i) {
        Property property = opacity;
        auto value = mathFunctionValue(random, property);
        if (builder.contains(property))
            blocks.append(builder.take());
        builder.add(property, value);
        if (builder.properties.size() == 8)
            blocks.append(builder.take());
    }
    if (!builder.properties.isEmpty())
        blocks.append(builder.take());
    return blocks;
}

// Shapes of the calc() expressions found in stylesheets of real sites (custom properties substituted with lengths),
// weighted by how often each occurs, plus random() and calc-mix(). `#` is a number, `%` a percentage.
struct MixedTemplate {
    Property property;
    ASCIILiteral text;
    unsigned weight;
};

static constexpr MixedTemplate mixedTemplates[] = {
    { { CSSPropertyID::Width, "width"_s }, "calc(100% - #px)"_s, 12 },
    { { CSSPropertyID::MarginLeft, "margin-left"_s }, "calc(#px - #px)"_s, 10 },
    { { CSSPropertyID::MarginTop, "margin-top"_s }, "calc(#px*-1)"_s, 6 },
    { { CSSPropertyID::Width, "width"_s }, "calc(#px/2)"_s, 4 },
    { { CSSPropertyID::Height, "height"_s }, "calc(#px + #px)"_s, 4 },
    { { CSSPropertyID::Left, "left"_s }, "calc((#px + #px)*-1)"_s, 3 },
    { { CSSPropertyID::Width, "width"_s }, "calc(100% - (#px * 2))"_s, 3 },
    { { CSSPropertyID::Width, "width"_s }, "calc(#% - ((#px * 2) / 3))"_s, 3 },
    { { CSSPropertyID::PaddingLeft, "padding-left"_s }, "calc(#px - #px*2)"_s, 2 },
    { { CSSPropertyID::MaxHeight, "max-height"_s }, "max(#px, #vh)"_s, 2 },
    { { CSSPropertyID::Width, "width"_s }, "calc(100% - #px - #px - #px)"_s, 2 },
    { { CSSPropertyID::Top, "top"_s }, "calc(50% - #px)"_s, 2 },
    { { CSSPropertyID::FontSize, "font-size"_s }, "clamp(#rem, #vw + #rem, #rem)"_s, 2 },
    { { CSSPropertyID::Width, "width"_s }, "min(#%, #px)"_s, 2 },
    { { CSSPropertyID::MarginRight, "margin-right"_s }, "calc(#px/2 - #px*2.5)"_s, 1 },
    { { CSSPropertyID::Width, "width"_s }, "calc(100% / #)"_s, 1 },
    { { CSSPropertyID::Transform, "transform"_s }, "translate(calc(#px * -1), 0) rotate(-#deg)"_s, 1 },
    { { CSSPropertyID::BorderTopLeftRadius, "border-top-left-radius"_s }, "calc(#px/2)"_s, 1 },
    { { CSSPropertyID::Width, "width"_s }, "random(fixed 0.#, #px, #px)"_s, 1 },
    { { CSSPropertyID::Height, "height"_s }, "random(#px, #px, #px)"_s, 1 },
    { { CSSPropertyID::Width, "width"_s }, "calc-mix(#px #%, #% #%)"_s, 1 },
};

static Vector<Block> mixedBlocks()
{
    unsigned totalWeight = 0;
    for (auto& entry : mixedTemplates)
        totalWeight += entry.weight;
    Random random(104);
    Vector<Block> blocks;
    BlockBuilder builder;
    for (unsigned i = 0; i < inputCount; ++i) {
        unsigned choice = random.below(totalWeight);
        const MixedTemplate* chosen = &mixedTemplates[0];
        for (auto& entry : mixedTemplates) {
            if (choice < entry.weight) {
                chosen = &entry;
                break;
            }
            choice -= entry.weight;
        }
        StringBuilder value;
        for (auto character : chosen->text.span()) {
            if (character != '#') {
                value.append(character);
                continue;
            }
            unsigned number = 1 + random.below(99);
            value.append(number);
        }
        if (builder.contains(chosen->property))
            blocks.append(builder.take());
        builder.add(chosen->property, value.toString());
        if (builder.properties.size() == 8)
            blocks.append(builder.take());
    }
    if (!builder.properties.isEmpty())
        blocks.append(builder.take());
    return blocks;
}

static size_t blockBytes(const Vector<Block>& blocks)
{
    size_t bytes = 0;
    for (auto& block : blocks)
        bytes += block.text.length();
    return bytes;
}

static uint64_t checksumOfParse(const Vector<Block>& blocks, const CSSParserContext& context, unsigned& parsedValues)
{
    Checksum checksum;
    for (auto& block : blocks) {
        Ref properties = MutableStyleProperties::create();
        checksum.add(CSSParser::parseDeclarationList(properties, block.text, context));
        for (auto property : block.properties) {
            auto text = properties->getPropertyValue(property);
            parsedValues += !text.isEmpty();
            checksum.add(text);
        }
    }
    return checksum.value();
}

static void runParse(ASCIILiteral name, const Vector<Block>& blocks, const CSSParserContext& context, uint64_t expectedChecksum, unsigned passes)
{
    auto bytes = blockBytes(blocks);
    ASSERT_GT(bytes, 0u);
    unsigned parsedValues = 0;
    auto checksum = checksumOfParse(blocks, context, parsedValues);
    EXPECT_GT(parsedValues, 0u);
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
    EXPECT_GT(changed, 0u);
    printResult(name, elapsed, static_cast<double>(bytes) * passes, checksum);
}

static CSSParserContext mixedParserContext()
{
    CSSParserContext context = strictCSSParserContext();
    context.cssRandomFunctionEnabled = true;
    context.cssCalcMixEnabled = true;
    return context;
}

// MARK: - Documents, resolved by style resolution and read through getComputedStyle.

static constexpr unsigned elementCount = 1024;

static String elementIdentifier(unsigned index)
{
    return makeString('e', index);
}

static Vector<Ref<Element>> elementsOf(TestPageHarness& page)
{
    Vector<Ref<Element>> elements;
    for (unsigned i = 0; i < elementCount; ++i) {
        RefPtr element = page.getElementById(elementIdentifier(i));
        if (!element)
            break;
        elements.append(element.releaseNonNull());
    }
    return elements;
}

static Vector<Ref<CSSStyleDeclaration>> computedStylesOf(TestPageHarness& page, const Vector<Ref<Element>>& elements)
{
    RefPtr window = page.document().window();
    Vector<Ref<CSSStyleDeclaration>> styles;
    for (auto& element : elements)
        styles.append(window->getComputedStyle(element, String { }));
    return styles;
}

static uint64_t checksumOfComputedValues(const Vector<Ref<CSSStyleDeclaration>>& styles, std::span<const ASCIILiteral> properties, unsigned& calcValues)
{
    Checksum checksum;
    for (auto& style : styles) {
        for (auto property : properties) {
            auto text = style->getPropertyValue(String { property });
            calcValues += text.contains("calc("_s) || text.contains("min("_s) || text.contains("max("_s);
            checksum.add(text);
        }
    }
    return checksum.value();
}

// Toggles the root element's font size, which every element's style depends on, so that the next style update
// resolves every element again.
static void invalidateAllStyles(Document& document, unsigned pass)
{
    RefPtr root = dynamicDowncast<StyledElement>(document.documentElement());
    root->setInlineStyleProperty(CSSPropertyID::FontSize, pass % 2 ? 17 : 16, CSSUnitType::Px);
}

static constexpr ASCIILiteral serializedProperties[] = { "width"_s, "min-width"_s, "max-height"_s, "margin-left"_s };

static void appendSerializedValue(StringBuilder& builder, Random& random)
{
    unsigned kind = random.below(8);
    unsigned percentage = random.below(101);
    if (kind < 3) {
        builder.append("calc("_s, percentage, '%', additiveOperator(random));
        appendLengthPercentage(builder, random);
        if (kind == 2) {
            builder.append(additiveOperator(random));
            appendDimension(builder, random, 40, "em"_s);
        }
        builder.append(')');
    } else if (kind < 5) {
        builder.append(kind == 3 ? "min("_s : "max("_s, percentage, "%, "_s);
        appendDimension(builder, random, 400, "px"_s);
        builder.append(')');
    } else if (kind < 6) {
        builder.append("clamp("_s);
        appendDimension(builder, random, 100, "px"_s);
        builder.append(", "_s, percentage, "%, "_s);
        appendDimension(builder, random, 600, "px"_s);
        builder.append(')');
    } else if (kind < 7) {
        builder.append("calc(("_s, percentage, "% + "_s);
        appendDimension(builder, random, 100, "px"_s);
        builder.append(") * "_s);
        appendNumber(builder, random, 2, 2);
        builder.append(')');
    } else {
        builder.append("calc("_s, percentage, "% * 2 - "_s);
        appendDimension(builder, random, 50, "rem"_s);
        builder.append(" + "_s);
        appendDimension(builder, random, 10, "vw"_s);
        builder.append(')');
    }
}

// Elements in a display: none subtree, so getComputedStyle returns computed rather than used values: each calc()
// with a percentage serializes from the style's calculation tree.
static String serializeDocument()
{
    Random random(105);
    StringBuilder html;
    html.append("<!DOCTYPE html><html><body><div style='display: none'>"_s);
    for (unsigned i = 0; i < elementCount; ++i) {
        html.append("<div id='"_s, elementIdentifier(i), "' style='"_s);
        for (auto property : serializedProperties) {
            html.append(property, ": "_s);
            appendSerializedValue(html, random);
            html.append("; "_s);
        }
        html.append("'></div>"_s);
    }
    html.append("</div></body></html>"_s);
    return html.toString();
}

static void runSerialize(uint64_t expectedChecksum, unsigned passes)
{
    auto page = TestPageHarness::create();
    page.loadHTML(serializeDocument());
    auto elements = elementsOf(page);
    ASSERT_EQ(elementCount, elements.size());
    auto styles = computedStylesOf(page, elements);
    unsigned calcValues = 0;
    auto checksum = checksumOfComputedValues(styles, serializedProperties, calcValues);
    EXPECT_GT(calcValues, 0u);
    EXPECT_EQ(expectedChecksum, checksum) << "checksum=" << std::hex << checksum;
    if (!runsBenchmarks())
        return;

    size_t bytes = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass) {
        for (auto& style : styles) {
            for (auto property : serializedProperties)
                bytes += style->getPropertyValue(String { property }).length();
        }
    }
    auto elapsed = MonotonicTime::now() - start;
    printResult("Serialize"_s, elapsed, static_cast<double>(bytes), checksum);
}

static constexpr ASCIILiteral convertedProperties[] = { "letter-spacing"_s, "word-spacing"_s, "text-indent"_s, "outline-offset"_s };

static void appendConvertedLength(StringBuilder& builder, Random& random)
{
    switch (random.below(4)) {
    case 0:
        builder.append("calc("_s);
        appendDimension(builder, random, 4, "em"_s);
        builder.append(additiveOperator(random));
        appendDimension(builder, random, 4, "rem"_s);
        builder.append(additiveOperator(random));
        appendDimension(builder, random, 20, "px"_s);
        builder.append(" + "_s);
        appendDimension(builder, random, 2, "vw"_s);
        builder.append(')');
        break;
    case 1:
        builder.append("calc("_s);
        appendDimension(builder, random, 4, "em"_s);
        builder.append(" * 2 - "_s);
        appendDimension(builder, random, 4, "rem"_s);
        builder.append(" / 3)"_s);
        break;
    case 2:
        builder.append("max("_s);
        appendDimension(builder, random, 4, "em"_s);
        builder.append(", "_s);
        appendDimension(builder, random, 30, "px"_s);
        builder.append(" + "_s);
        appendDimension(builder, random, 3, "vh"_s);
        builder.append(')');
        break;
    default:
        builder.append("clamp("_s);
        appendDimension(builder, random, 10, "px"_s);
        builder.append(", "_s);
        appendDimension(builder, random, 3, "em"_s);
        builder.append(", "_s);
        appendDimension(builder, random, 5, "rem"_s);
        builder.append(')');
        break;
    }
}

// Lengths in font-relative, root-relative, viewport and absolute units, on elements with varied font sizes: resolving
// each element's style converts every one to pixels.
static String conversionDocument(size_t& valueBytes)
{
    Random random(106);
    StringBuilder html;
    html.append("<!DOCTYPE html><html style='font-size: 16px'><body>"_s);
    for (unsigned i = 0; i < elementCount; ++i) {
        unsigned fontSize = 8 + random.below(33);
        html.append("<div id='"_s, elementIdentifier(i), "' style='font-size: "_s, fontSize, "px; "_s);
        for (auto property : convertedProperties) {
            html.append(property, ": "_s);
            auto before = html.length();
            appendConvertedLength(html, random);
            valueBytes += html.length() - before;
            html.append("; "_s);
        }
        html.append("'></div>"_s);
    }
    html.append("</body></html>"_s);
    return html.toString();
}

static void runEvaluateWithConversion(uint64_t expectedChecksum, unsigned passes)
{
    auto page = TestPageHarness::create();
    size_t valueBytes = 0;
    page.loadHTML(conversionDocument(valueBytes));
    auto elements = elementsOf(page);
    ASSERT_EQ(elementCount, elements.size());
    auto styles = computedStylesOf(page, elements);
    unsigned calcValues = 0;
    auto checksum = checksumOfComputedValues(styles, convertedProperties, calcValues);
    EXPECT_EQ(0u, calcValues);
    EXPECT_EQ(expectedChecksum, checksum) << "checksum=" << std::hex << checksum;
    if (!runsBenchmarks())
        return;

    Ref document = page.document();
    auto start = MonotonicTime::now();
    for (unsigned pass = 1; pass <= passes; ++pass) {
        invalidateAllStyles(document, pass);
        document->updateStyleIfNeeded();
    }
    auto elapsed = MonotonicTime::now() - start;
    printResult("EvaluateWithConversion"_s, elapsed, static_cast<double>(valueBytes) * passes, checksum);
}

static constexpr unsigned keyframesCount = 64;

static void appendBlendedWidth(StringBuilder& builder, Random& random)
{
    unsigned percentage = random.below(101);
    switch (random.below(3)) {
    case 0:
        builder.append("calc("_s, percentage, '%', additiveOperator(random));
        appendDimension(builder, random, 200, "px"_s);
        builder.append(')');
        break;
    case 1:
        builder.append("calc("_s, percentage, "% - "_s);
        appendDimension(builder, random, 10, "em"_s);
        builder.append(" + "_s);
        appendDimension(builder, random, 100, "px"_s);
        builder.append(')');
        break;
    default:
        builder.append("calc(("_s, percentage, "% + "_s);
        appendDimension(builder, random, 100, "px"_s);
        builder.append(") / 2)"_s);
        break;
    }
}

// Elements whose width is a paused animation between two calc() widths, at a different point for each element: each
// style resolution converts the keyframes' trees, copies and blends them, and layout evaluates the result.
static String styleTreeDocument(size_t& valueBytes)
{
    Random random(107);
    StringBuilder html;
    html.append("<!DOCTYPE html><html style='font-size: 16px'><head><style>"_s);
    for (unsigned i = 0; i < keyframesCount; ++i) {
        html.append("@keyframes k"_s, i, " { from { width: "_s);
        auto before = html.length();
        appendBlendedWidth(html, random);
        html.append(" } to { width: "_s);
        appendBlendedWidth(html, random);
        valueBytes += html.length() - before;
        html.append(" } }\n"_s);
    }
    html.append("</style></head><body><div style='width: 640px'>"_s);
    for (unsigned i = 0; i < elementCount; ++i) {
        unsigned keyframes = random.below(keyframesCount);
        unsigned delay = 1 + random.below(998);
        html.append("<div id='"_s, elementIdentifier(i), "' style='height: 1px; width: "_s);
        auto before = html.length();
        appendBlendedWidth(html, random);
        valueBytes += html.length() - before;
        html.append("; animation: k"_s, keyframes, " 1s linear -"_s, delay, "ms paused'></div>"_s);
    }
    html.append("</div></body></html>"_s);
    return html.toString();
}

static void runStyleTreeCopy(uint64_t expectedChecksum, unsigned passes)
{
    auto page = TestPageHarness::create();
    size_t valueBytes = 0;
    page.loadHTML(styleTreeDocument(valueBytes));
    auto elements = elementsOf(page);
    ASSERT_EQ(elementCount, elements.size());
    auto styles = computedStylesOf(page, elements);
    static constexpr ASCIILiteral properties[] = { "width"_s };
    unsigned calcValues = 0;
    auto checksum = checksumOfComputedValues(styles, properties, calcValues);
    EXPECT_EQ(0u, calcValues);
    EXPECT_EQ(expectedChecksum, checksum) << "checksum=" << std::hex << checksum;
    if (!runsBenchmarks())
        return;

    Ref document = page.document();
    auto start = MonotonicTime::now();
    for (unsigned pass = 1; pass <= passes; ++pass) {
        invalidateAllStyles(document, pass);
        document->updateLayout();
    }
    auto elapsed = MonotonicTime::now() - start;
    printResult("StyleTreeCopy"_s, elapsed, static_cast<double>(valueBytes) * passes, checksum);
}

} // namespace CSSCalcBenchmark

using namespace CSSCalcBenchmark;

TEST(CSSCalcBench, SimpleSum) { runParse("SimpleSum"_s, simpleSumBlocks(), strictCSSParserContext(), 0xd5e82e8af2b0aa3dULL, 900); }
TEST(CSSCalcBench, NestedMinMax) { runParse("NestedMinMax"_s, nestedMinMaxBlocks(), strictCSSParserContext(), 0xae0226ef3990cc04ULL, 75); }
TEST(CSSCalcBench, MathFunctions) { runParse("MathFunctions"_s, mathFunctionsBlocks(), strictCSSParserContext(), 0xf8058ea607daa149ULL, 600); }
TEST(CSSCalcBench, Serialize) { runSerialize(0x8b7a108208d1a674ULL, 1000); }
TEST(CSSCalcBench, EvaluateWithConversion) { runEvaluateWithConversion(0xe19ae21cc34896d0ULL, 475); }
TEST(CSSCalcBench, StyleTreeCopy) { runStyleTreeCopy(0xe5a8aa8d0571de3bULL, 160); }
TEST(CSSCalcBench, Mixed) { runParse("Mixed"_s, mixedBlocks(), mixedParserContext(), 0x64888b96b007f534ULL, 600); }

} // namespace TestWebKitAPI
