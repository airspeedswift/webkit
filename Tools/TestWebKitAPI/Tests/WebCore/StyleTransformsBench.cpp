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
#include <WebCore/CompositeOperation.h>
#include <WebCore/StyleTransformsBenchmarkHooks.h>
#include <bit>
#include <cmath>
#include <cstdlib>
#include <optional>
#include <span>
#include <wtf/MonotonicTime.h>
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>
#include <wtf/text/ASCIILiteral.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

// Times the computed values of `transform` and `filter`, one test per kind of work: building them from parsed CSS
// values as the style builder does (BuildTransformLists), applying them to a matrix (ApplyTransformLists), blending
// lists whose functions match pairwise (BlendMatchingLists) and lists that fall back to matrix interpolation
// (BlendMismatchedLists), blending filters (BlendFilters), blending the translate, rotate and scale properties
// (BlendIndividualProperties), comparing lists as style difference does (TransformEquality), and a page's worth of
// animated transforms and filters blended and applied per frame (AnimationFrame).
//
// Each test runs one pass over its input and checks a checksum of what the pass produced, on ARM64 only, because the
// trigonometry and the decomposition round differently by CPU. With WEBKIT_RUN_BENCHMARKS set, it then runs a fixed
// number of passes (fixed, so that every build does the same work) and prints the time.
//
// The values are reached only through StyleTransformsBenchmarkHooks, whose members are out of line in WebCore: the
// test compiles none of the values' layout or inline code, so one TestWebKitAPI binary runs against every WebCore.
//
// Lengths use px, the font-relative units (the hooks' style has a 16px font whose metrics resolve ex, ch, ic, cap and
// lh, and stands in for the root style for their root forms) and percentages; viewport and container units are left
// out because the hooks' document has no view and the style no element. The generators make every random draw
// in its own statement, so the inputs do not depend on the order in which a compiler evaluates function arguments.

namespace TestWebKitAPI {

using namespace WebCore;

namespace StyleTransformsBenchmark {

using Matrix = StyleTransformsBenchmarkHooks::Matrix;

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

    void add(double number) { add(std::isnan(number) ? 0x7ff8000000000000ULL : std::bit_cast<uint64_t>(number)); }

    void add(StringView string)
    {
        add(static_cast<uint64_t>(string.length()));
        for (auto character : string.codeUnits())
            add(static_cast<uint64_t>(character));
    }

    void add(const Matrix& matrix)
    {
        for (double element : matrix)
            add(element);
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

// One pass with a checksum, checked against a recorded value; then, with WEBKIT_RUN_BENCHMARKS set, `passes` passes
// without one, timed. `bytesPerPass` is what MB/s divides: the CSS text of the values a pass reads, or the matrices it
// writes.
template<typename Pass>
static void runShape(ASCIILiteral name, size_t bytesPerPass, uint64_t expectedChecksum, unsigned passes, Pass&& pass)
{
    ASSERT_GT(bytesPerPass, 0u);
    Checksum checksum;
    pass(&checksum);
#if CPU(ARM64)
    EXPECT_EQ(expectedChecksum, checksum.value()) << name.characters() << " checksum=" << std::hex << checksum.value();
#else
    UNUSED_PARAM(expectedChecksum);
#endif
    if (!runsBenchmarks())
        return;

    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < passes; ++i)
        pass(nullptr);
    auto elapsed = MonotonicTime::now() - start;
    printResult(name, elapsed, static_cast<double>(bytesPerPass) * passes, checksum.value());
}

// MARK: - Numbers, lengths and angles.

static void appendNumber(StringBuilder& builder, Random& random, unsigned maximumInteger, unsigned maximumFractionDigits, unsigned negativeChance)
{
    if (random.percent(negativeChance))
        builder.append('-');
    unsigned integer = random.below(maximumInteger + 1);
    builder.append(integer);
    unsigned fractionDigits = random.below(maximumFractionDigits + 1);
    if (!fractionDigits)
        return;
    builder.append('.');
    for (unsigned i = 0; i < fractionDigits; ++i) {
        unsigned digit = random.below(10);
        builder.append(static_cast<char>('0' + digit));
    }
}

static constexpr ASCIILiteral lengthUnits[] = {
    "px"_s, "px"_s, "px"_s, "px"_s, "px"_s, "px"_s, "px"_s, "px"_s, "em"_s, "em"_s, "rem"_s,
    "ex"_s, "ch"_s, "ic"_s, "cap"_s, "lh"_s, "rex"_s, "rch"_s, "ric"_s, "rcap"_s, "rlh"_s,
};

static void appendPlainLength(StringBuilder& builder, Random& random, unsigned negativeChance)
{
    auto unit = random.pick(lengthUnits);
    appendNumber(builder, random, unit == "px"_s ? 400 : 12, 2, negativeChance);
    builder.append(unit);
}

// A length, one in ten of them a calc() of two units.
static void appendLength(StringBuilder& builder, Random& random, unsigned negativeChance)
{
    if (!random.percent(10)) {
        appendPlainLength(builder, random, negativeChance);
        return;
    }
    builder.append("calc("_s);
    appendPlainLength(builder, random, 0);
    builder.append(random.percent(50) ? " + "_s : " - "_s);
    appendPlainLength(builder, random, 0);
    builder.append(')');
}

// A length or a percentage, one in ten of them a calc() mixing the two.
static void appendLengthPercentage(StringBuilder& builder, Random& random)
{
    unsigned kind = random.below(10);
    if (kind < 6) {
        appendLength(builder, random, 25);
        return;
    }
    if (kind < 9) {
        appendNumber(builder, random, 100, 1, 25);
        builder.append('%');
        return;
    }
    builder.append("calc("_s);
    appendNumber(builder, random, 100, 1, 0);
    builder.append("% - "_s);
    appendPlainLength(builder, random, 0);
    builder.append(')');
}

static constexpr ASCIILiteral angleUnits[] = { "deg"_s, "deg"_s, "deg"_s, "deg"_s, "rad"_s, "grad"_s, "turn"_s };

static void appendAngle(StringBuilder& builder, Random& random)
{
    if (random.percent(8)) {
        builder.append("calc("_s);
        appendNumber(builder, random, 180, 1, 0);
        builder.append("deg + "_s);
        appendNumber(builder, random, 3, 2, 0);
        builder.append("rad)"_s);
        return;
    }
    auto unit = random.pick(angleUnits);
    unsigned maximum = unit == "deg"_s || unit == "grad"_s ? 360 : unit == "rad"_s ? 6 : 1;
    appendNumber(builder, random, maximum, 2, 30);
    builder.append(unit);
}

// A scale factor: a number near 1, or a percentage.
static void appendScaleFactor(StringBuilder& builder, Random& random)
{
    if (random.percent(15)) {
        appendNumber(builder, random, 200, 0, 10);
        builder.append('%');
        return;
    }
    appendNumber(builder, random, 2, 2, 10);
}

// MARK: - Transform functions.

enum class Kind : uint8_t {
    Matrix, Matrix3D,
    Translate, TranslateX, TranslateY, TranslateZ, Translate3D,
    Scale, ScaleX, ScaleY, ScaleZ, Scale3D,
    Rotate, RotateX, RotateY, RotateZ, Rotate3D,
    Skew, SkewX, SkewY,
    Perspective,
};
static constexpr unsigned kindCount = static_cast<unsigned>(Kind::Perspective) + 1;

// Kinds whose blends share a primitive (translateX and translate3d both blend as translate3d, and so on).
enum class Family : uint8_t { Matrix, Translate, Scale, Rotate, Skew, Perspective };
static constexpr unsigned familyCount = static_cast<unsigned>(Family::Perspective) + 1;

static Family family(Kind kind)
{
    switch (kind) {
    case Kind::Matrix:
    case Kind::Matrix3D:
        return Family::Matrix;
    case Kind::Translate:
    case Kind::TranslateX:
    case Kind::TranslateY:
    case Kind::TranslateZ:
    case Kind::Translate3D:
        return Family::Translate;
    case Kind::Scale:
    case Kind::ScaleX:
    case Kind::ScaleY:
    case Kind::ScaleZ:
    case Kind::Scale3D:
        return Family::Scale;
    case Kind::Rotate:
    case Kind::RotateX:
    case Kind::RotateY:
    case Kind::RotateZ:
    case Kind::Rotate3D:
        return Family::Rotate;
    case Kind::Skew:
    case Kind::SkewX:
    case Kind::SkewY:
        return Family::Skew;
    case Kind::Perspective:
        return Family::Perspective;
    }
    return Family::Matrix;
}

static Kind kindInFamily(Family family, Random& random)
{
    switch (family) {
    case Family::Matrix: {
        static constexpr Kind kinds[] = { Kind::Matrix, Kind::Matrix, Kind::Matrix3D };
        return random.pick(kinds);
    }
    case Family::Translate: {
        static constexpr Kind kinds[] = { Kind::Translate, Kind::Translate, Kind::TranslateX, Kind::TranslateY, Kind::TranslateZ, Kind::Translate3D };
        return random.pick(kinds);
    }
    case Family::Scale: {
        static constexpr Kind kinds[] = { Kind::Scale, Kind::Scale, Kind::ScaleX, Kind::ScaleY, Kind::ScaleZ, Kind::Scale3D };
        return random.pick(kinds);
    }
    case Family::Rotate: {
        static constexpr Kind kinds[] = { Kind::Rotate, Kind::Rotate, Kind::RotateX, Kind::RotateY, Kind::RotateZ, Kind::Rotate3D };
        return random.pick(kinds);
    }
    case Family::Skew: {
        static constexpr Kind kinds[] = { Kind::Skew, Kind::SkewX, Kind::SkewY };
        return random.pick(kinds);
    }
    case Family::Perspective:
        return Kind::Perspective;
    }
    return Kind::Matrix;
}

// The families a page's transforms are made of, by how often they appear.
static Family commonFamily(Random& random)
{
    static constexpr Family families[] = {
        Family::Translate, Family::Translate, Family::Translate, Family::Translate, Family::Rotate, Family::Rotate, Family::Rotate,
        Family::Scale, Family::Scale, Family::Scale, Family::Skew, Family::Matrix, Family::Matrix, Family::Perspective,
    };
    return random.pick(families);
}

static Kind randomKind(Random& random)
{
    auto chosenFamily = commonFamily(random);
    return kindInFamily(chosenFamily, random);
}

// A matrix() argument; one in forty matrices has a non-finite entry, which the style builder clamps.
static void appendMatrixEntry(StringBuilder& builder, Random& random, bool nonFinite)
{
    if (nonFinite) {
        static constexpr ASCIILiteral values[] = { "calc(infinity)"_s, "calc(-infinity)"_s, "calc(NaN)"_s };
        builder.append(random.pick(values));
        return;
    }
    appendNumber(builder, random, 2, 3, 30);
}

static void appendFunction(StringBuilder& builder, Random& random, Kind kind)
{
    switch (kind) {
    case Kind::Matrix: {
        bool hasNonFinite = random.percent(3);
        unsigned nonFiniteIndex = random.below(6);
        builder.append("matrix("_s);
        for (unsigned i = 0; i < 6; ++i) {
            if (i)
                builder.append(", "_s);
            if (i >= 4 && !(hasNonFinite && i == nonFiniteIndex)) {
                appendNumber(builder, random, 300, 1, 30);
                continue;
            }
            appendMatrixEntry(builder, random, hasNonFinite && i == nonFiniteIndex);
        }
        builder.append(')');
        return;
    }
    case Kind::Matrix3D: {
        // Close to the identity, with a translation and, in one of three, a perspective term.
        bool hasPerspective = random.percent(33);
        builder.append("matrix3d("_s);
        for (unsigned i = 0; i < 16; ++i) {
            if (i)
                builder.append(", "_s);
            if (i == 11 && hasPerspective) {
                builder.append("-0.00"_s);
                unsigned digits = 1 + random.below(9);
                builder.append(digits);
            } else if (i >= 12 && i < 15)
                appendNumber(builder, random, 200, 1, 30);
            else if (i == 15)
                builder.append('1');
            else if (!(i % 5)) {
                builder.append("1."_s);
                unsigned digits = random.below(100);
                builder.append(digits);
            } else {
                builder.append(random.percent(50) ? "0."_s : "-0."_s);
                unsigned digits = random.below(400);
                builder.append(digits);
            }
        }
        builder.append(')');
        return;
    }
    case Kind::Translate:
        builder.append("translate("_s);
        appendLengthPercentage(builder, random);
        if (random.percent(70)) {
            builder.append(", "_s);
            appendLengthPercentage(builder, random);
        }
        builder.append(')');
        return;
    case Kind::TranslateX:
        builder.append("translateX("_s);
        appendLengthPercentage(builder, random);
        builder.append(')');
        return;
    case Kind::TranslateY:
        builder.append("translateY("_s);
        appendLengthPercentage(builder, random);
        builder.append(')');
        return;
    case Kind::TranslateZ:
        builder.append("translateZ("_s);
        appendLength(builder, random, 40);
        builder.append(')');
        return;
    case Kind::Translate3D:
        builder.append("translate3d("_s);
        appendLengthPercentage(builder, random);
        builder.append(", "_s);
        appendLengthPercentage(builder, random);
        builder.append(", "_s);
        appendLength(builder, random, 40);
        builder.append(')');
        return;
    case Kind::Scale:
        builder.append("scale("_s);
        appendScaleFactor(builder, random);
        if (random.percent(50)) {
            builder.append(", "_s);
            appendScaleFactor(builder, random);
        }
        builder.append(')');
        return;
    case Kind::ScaleX:
        builder.append("scaleX("_s);
        appendScaleFactor(builder, random);
        builder.append(')');
        return;
    case Kind::ScaleY:
        builder.append("scaleY("_s);
        appendScaleFactor(builder, random);
        builder.append(')');
        return;
    case Kind::ScaleZ:
        builder.append("scaleZ("_s);
        appendScaleFactor(builder, random);
        builder.append(')');
        return;
    case Kind::Scale3D:
        builder.append("scale3d("_s);
        appendScaleFactor(builder, random);
        builder.append(", "_s);
        appendScaleFactor(builder, random);
        builder.append(", "_s);
        appendScaleFactor(builder, random);
        builder.append(')');
        return;
    case Kind::Rotate:
        builder.append("rotate("_s);
        appendAngle(builder, random);
        builder.append(')');
        return;
    case Kind::RotateX:
        builder.append("rotateX("_s);
        appendAngle(builder, random);
        builder.append(')');
        return;
    case Kind::RotateY:
        builder.append("rotateY("_s);
        appendAngle(builder, random);
        builder.append(')');
        return;
    case Kind::RotateZ:
        builder.append("rotateZ("_s);
        appendAngle(builder, random);
        builder.append(')');
        return;
    case Kind::Rotate3D: {
        // One axis in twenty is the zero vector.
        bool zeroAxis = random.percent(5);
        builder.append("rotate3d("_s);
        for (unsigned i = 0; i < 3; ++i) {
            if (zeroAxis)
                builder.append('0');
            else
                appendNumber(builder, random, 1, 2, 30);
            builder.append(", "_s);
        }
        appendAngle(builder, random);
        builder.append(')');
        return;
    }
    case Kind::Skew:
        builder.append("skew("_s);
        appendAngle(builder, random);
        if (random.percent(60)) {
            builder.append(", "_s);
            appendAngle(builder, random);
        }
        builder.append(')');
        return;
    case Kind::SkewX:
        builder.append("skewX("_s);
        appendAngle(builder, random);
        builder.append(')');
        return;
    case Kind::SkewY:
        builder.append("skewY("_s);
        appendAngle(builder, random);
        builder.append(')');
        return;
    case Kind::Perspective:
        builder.append("perspective("_s);
        if (random.percent(15))
            builder.append("none"_s);
        else {
            unsigned length = 50 + random.below(2000);
            builder.append(length);
            builder.append("px"_s);
        }
        builder.append(')');
        return;
    }
}

static String transformText(Random& random, std::span<const Kind> kinds)
{
    if (kinds.empty())
        return "none"_s;
    StringBuilder builder;
    for (auto kind : kinds) {
        if (!builder.isEmpty())
            builder.append(' ');
        appendFunction(builder, random, kind);
    }
    return builder.toString();
}

static Vector<Kind> randomKinds(Random& random, unsigned minimumLength, unsigned maximumLength)
{
    unsigned length = minimumLength + random.below(maximumLength - minimumLength + 1);
    Vector<Kind> kinds;
    for (unsigned i = 0; i < length; ++i)
        kinds.append(randomKind(random));
    return kinds;
}

// MARK: - Filter functions.

enum class FilterKind : uint8_t { Blur, Brightness, Contrast, DropShadow, Grayscale, HueRotate, Invert, Opacity, Saturate, Sepia, Reference };

static FilterKind randomFilterKind(Random& random, bool allowReference)
{
    static constexpr FilterKind kinds[] = {
        FilterKind::Blur, FilterKind::Blur, FilterKind::Brightness, FilterKind::Contrast, FilterKind::DropShadow, FilterKind::DropShadow,
        FilterKind::Grayscale, FilterKind::HueRotate, FilterKind::Invert, FilterKind::Opacity, FilterKind::Opacity, FilterKind::Saturate,
        FilterKind::Sepia, FilterKind::Reference,
    };
    while (true) {
        auto kind = random.pick(kinds);
        if (allowReference || kind != FilterKind::Reference)
            return kind;
    }
}

// An amount for brightness(), contrast() and saturate() (no upper bound), or for grayscale(), invert(), opacity()
// and sepia() (clamped to 1 at parse time); one in ten is left out, for the function's default.
static void appendFilterAmount(StringBuilder& builder, Random& random)
{
    unsigned kind = random.below(10);
    if (!kind)
        return;
    if (kind < 4) {
        appendNumber(builder, random, 150, 0, 0);
        builder.append('%');
        return;
    }
    appendNumber(builder, random, 1, 2, 0);
}

static constexpr ASCIILiteral shadowColors[] = {
    ""_s, "black"_s, "red"_s, "#3366cc"_s, "rgb(0 0 0 / 50%)"_s, "currentcolor"_s, "hsl(120deg 50% 40%)"_s, "transparent"_s,
};

static void appendFilterFunction(StringBuilder& builder, Random& random, FilterKind kind)
{
    switch (kind) {
    case FilterKind::Blur:
        builder.append("blur("_s);
        if (random.percent(90))
            appendPlainLength(builder, random, 0);
        builder.append(')');
        return;
    case FilterKind::Brightness:
        builder.append("brightness("_s);
        appendFilterAmount(builder, random);
        builder.append(')');
        return;
    case FilterKind::Contrast:
        builder.append("contrast("_s);
        appendFilterAmount(builder, random);
        builder.append(')');
        return;
    case FilterKind::DropShadow: {
        auto color = random.pick(shadowColors);
        builder.append("drop-shadow("_s);
        appendPlainLength(builder, random, 30);
        builder.append(' ');
        appendPlainLength(builder, random, 30);
        if (random.percent(70)) {
            builder.append(' ');
            appendPlainLength(builder, random, 0);
        }
        if (!color.isEmpty()) {
            builder.append(' ');
            builder.append(color);
        }
        builder.append(')');
        return;
    }
    case FilterKind::Grayscale:
        builder.append("grayscale("_s);
        appendFilterAmount(builder, random);
        builder.append(')');
        return;
    case FilterKind::HueRotate:
        builder.append("hue-rotate("_s);
        if (random.percent(90))
            appendAngle(builder, random);
        builder.append(')');
        return;
    case FilterKind::Invert:
        builder.append("invert("_s);
        appendFilterAmount(builder, random);
        builder.append(')');
        return;
    case FilterKind::Opacity:
        builder.append("opacity("_s);
        appendFilterAmount(builder, random);
        builder.append(')');
        return;
    case FilterKind::Saturate:
        builder.append("saturate("_s);
        appendFilterAmount(builder, random);
        builder.append(')');
        return;
    case FilterKind::Sepia:
        builder.append("sepia("_s);
        appendFilterAmount(builder, random);
        builder.append(')');
        return;
    case FilterKind::Reference: {
        unsigned identifier = random.below(16);
        builder.append("url(#filter"_s);
        builder.append(identifier);
        builder.append(')');
        return;
    }
    }
}

static String filterText(Random& random, std::span<const FilterKind> kinds)
{
    if (kinds.empty())
        return "none"_s;
    StringBuilder builder;
    for (auto kind : kinds) {
        if (!builder.isEmpty())
            builder.append(' ');
        appendFilterFunction(builder, random, kind);
    }
    return builder.toString();
}

static Vector<FilterKind> randomFilterKinds(Random& random, unsigned minimumLength, unsigned maximumLength, bool allowReference)
{
    unsigned length = minimumLength + random.below(maximumLength - minimumLength + 1);
    Vector<FilterKind> kinds;
    for (unsigned i = 0; i < length; ++i)
        kinds.append(randomFilterKind(random, allowReference));
    return kinds;
}

// MARK: - Inputs held in WebCore.

static constexpr double progresses[] = { 0, 0.125, 0.25, 0.5, 0.5, 0.75, 1, -0.5, 1.5 };
static constexpr float boxWidths[] = { 0, 100, 320.5, 1024 };
static constexpr float boxHeights[] = { 0, 50, 240, 768.25 };
static constexpr float zooms[] = { 1, 1, 1, 2, 0.5, 1.25 };

struct Pair {
    size_t from;
    size_t to;
    double progress;
    CompositeOperation compositeOperation;
    float width;
    float height;
};

struct Inputs {
    StyleTransformsBenchmarkHooks hooks;
    size_t bytes { 0 };
    unsigned rejected { 0 };

    size_t addTransform(const String& text)
    {
        bytes += text.length();
        auto index = hooks.addTransform(text);
        if (!index) {
            ++rejected;
            index = hooks.addTransform("none"_s);
        }
        return *index;
    }

    size_t addFilter(const String& text)
    {
        bytes += text.length();
        auto index = hooks.addFilter(text);
        if (!index) {
            ++rejected;
            index = hooks.addFilter("none"_s);
        }
        return *index;
    }

    size_t addIndividualTransform(StyleTransformsBenchmarkHooks::IndividualTransformProperty property, const String& text)
    {
        bytes += text.length();
        auto index = hooks.addIndividualTransform(property, text);
        if (!index) {
            ++rejected;
            index = hooks.addIndividualTransform(property, "none"_s);
        }
        return *index;
    }
};

// Replace mostly; one pair in eight accumulates and one in sixteen adds, both at a progress of 1, as interpolation
// passes it for them.
static void pickComposite(Random& random, Pair& pair)
{
    unsigned draw = random.below(16);
    if (!draw)
        pair.compositeOperation = CompositeOperation::Add;
    else if (draw < 3)
        pair.compositeOperation = CompositeOperation::Accumulate;
    else
        pair.compositeOperation = CompositeOperation::Replace;
    if (pair.compositeOperation != CompositeOperation::Replace)
        pair.progress = 1;
}

static Pair makePair(Random& random, size_t from, size_t to)
{
    Pair pair { from, to, 0, CompositeOperation::Replace, 0, 0 };
    pair.progress = random.pick(progresses);
    pickComposite(random, pair);
    pair.width = random.pick(boxWidths);
    pair.height = random.pick(boxHeights);
    return pair;
}

// The kinds of a list matching `kinds` pairwise: the same kind, or in one function of five another kind of its
// family, which blends through the shared primitive.
static Vector<Kind> matchingKinds(Random& random, std::span<const Kind> kinds)
{
    Vector<Kind> result;
    for (auto kind : kinds) {
        if (random.percent(20))
            result.append(kindInFamily(family(kind), random));
        else
            result.append(kind);
    }
    return result;
}

// A pair of lists that blends pairwise: the same kinds; one pair in eight with one list a prefix of the other (the
// missing functions blend to identity); one in sixteen from or to none.
static void appendMatchingPair(Random& random, Inputs& inputs, Vector<Pair>& pairs)
{
    auto fromKinds = randomKinds(random, 1, 5);
    auto toKinds = matchingKinds(random, fromKinds.span());
    unsigned shape = random.below(16);
    if (!shape)
        (random.percent(50) ? fromKinds : toKinds).clear();
    else if (shape < 3 && toKinds.size() > 1)
        toKinds.shrink(1 + random.below(static_cast<unsigned>(toKinds.size() - 1)));
    auto fromText = transformText(random, fromKinds.span());
    auto toText = transformText(random, toKinds.span());
    auto from = inputs.addTransform(fromText);
    auto to = inputs.addTransform(toText);
    pairs.append(makePair(random, from, to));
}

// A pair of lists that differ in family at some function, so the blend interpolates the rest as matrices
// (decomposition through TransformationMatrix). In one pair of four the lists start with matching functions, which
// blend pairwise before the matrix suffix.
static void appendMismatchedPair(Random& random, Inputs& inputs, Vector<Pair>& pairs)
{
    auto fromKinds = randomKinds(random, 1, 5);
    Vector<Kind> toKinds;
    unsigned prefix = random.percent(25) ? random.below(static_cast<unsigned>(fromKinds.size())) : 0;
    for (unsigned i = 0; i < prefix; ++i)
        toKinds.append(fromKinds[i]);
    // The first function after the prefix is of another family than the one it faces.
    auto faced = family(fromKinds[prefix]);
    auto other = static_cast<Family>((static_cast<unsigned>(faced) + 1 + random.below(familyCount - 1)) % familyCount);
    toKinds.append(kindInFamily(other, random));
    unsigned extra = random.below(4);
    for (unsigned i = 0; i < extra; ++i)
        toKinds.append(randomKind(random));
    auto fromText = transformText(random, fromKinds.span());
    auto toText = transformText(random, toKinds.span());
    auto from = inputs.addTransform(fromText);
    auto to = inputs.addTransform(toText);
    pairs.append(makePair(random, from, to));
}

// A pair of filter lists: matching kinds (pairwise blends), one a prefix of the other (a missing function blends from
// or to its initial value), mismatched kinds or a reference filter (neither blends), or none against a list.
static void appendFilterPair(Random& random, Inputs& inputs, Vector<Pair>& pairs)
{
    Vector<FilterKind> fromKinds;
    Vector<FilterKind> toKinds;
    unsigned shape = random.below(20);
    if (shape < 12) {
        fromKinds = randomFilterKinds(random, 1, 4, false);
        toKinds = fromKinds;
    } else if (shape < 15) {
        fromKinds = randomFilterKinds(random, 2, 5, false);
        toKinds = fromKinds;
        toKinds.shrink(1 + random.below(static_cast<unsigned>(fromKinds.size() - 1)));
        if (random.percent(50))
            std::swap(fromKinds, toKinds);
    } else if (shape < 17) {
        fromKinds = randomFilterKinds(random, 1, 4, false);
        toKinds = randomFilterKinds(random, 1, 4, false);
    } else if (shape < 18) {
        fromKinds = randomFilterKinds(random, 1, 3, true);
        toKinds = fromKinds;
        toKinds.append(FilterKind::Reference);
    } else {
        fromKinds = randomFilterKinds(random, 1, 4, false);
        if (random.percent(50))
            std::swap(fromKinds, toKinds);
    }
    auto fromText = filterText(random, fromKinds.span());
    auto toText = filterText(random, toKinds.span());
    auto from = inputs.addFilter(fromText);
    auto to = inputs.addFilter(toText);
    pairs.append(makePair(random, from, to));
}

// MARK: - Individual transform properties.

using IndividualTransformProperty = StyleTransformsBenchmarkHooks::IndividualTransformProperty;

// A value of `translate`, `rotate` or `scale`: none in one of ten, else one to three components (for `rotate`, an
// angle alone, about a named axis, or about a vector).
static String individualTransformText(Random& random, IndividualTransformProperty property)
{
    if (!random.below(10))
        return "none"_s;
    StringBuilder builder;
    unsigned components = 1 + random.below(3);
    switch (property) {
    case IndividualTransformProperty::Translate:
        appendLengthPercentage(builder, random);
        if (components > 1) {
            builder.append(' ');
            appendLengthPercentage(builder, random);
        }
        if (components > 2) {
            builder.append(' ');
            appendLength(builder, random, 25);
        }
        break;
    case IndividualTransformProperty::Rotate:
        if (components == 2) {
            static constexpr ASCIILiteral axes[] = { "x "_s, "y "_s, "z "_s };
            builder.append(random.pick(axes));
        } else if (components == 3) {
            for (unsigned i = 0; i < 3; ++i) {
                appendNumber(builder, random, 2, 1, 30);
                builder.append(' ');
            }
        }
        appendAngle(builder, random);
        break;
    case IndividualTransformProperty::Scale:
        for (unsigned i = 0; i < components; ++i) {
            if (i)
                builder.append(' ');
            appendScaleFactor(builder, random);
        }
        break;
    }
    return builder.toString();
}

// MARK: - Tests.

static constexpr unsigned listCount = 2048;
static constexpr unsigned pairCount = 2048;

// About a second each on an Apple silicon Mac.
static constexpr unsigned buildPasses = 3300;
static constexpr unsigned applyPasses = 13000;
static constexpr unsigned blendMatchingPasses = 2200;
static constexpr unsigned blendMismatchedPasses = 2600;
static constexpr unsigned blendFiltersPasses = 10000;
static constexpr unsigned equalityPasses = 30000;
static constexpr unsigned animationFramePasses = 830;
static constexpr unsigned blendIndividualPasses = 5600;

// The checksums of one pass (ARM64).
static constexpr uint64_t buildChecksum = 0x4a9c5420466df5f1ULL;
static constexpr uint64_t applyChecksum = 0x6ee087515b76d849ULL;
static constexpr uint64_t blendMatchingChecksum = 0x58ec55a223f6579cULL;
static constexpr uint64_t blendMismatchedChecksum = 0xba8dea306cd3b4d9ULL;
static constexpr uint64_t blendFiltersChecksum = 0x40255f6d1b857833ULL;
static constexpr uint64_t equalityChecksum = 0xf7fdc2950fa1d74bULL;
static constexpr uint64_t animationFrameChecksum = 0xde75b05209068ec9ULL;
static constexpr uint64_t blendIndividualChecksum = 0xd06fc9ae96bc22c5ULL;

// Transform lists of one to six functions, the first of each list cycling through every kind; one in thirty is none.
static Vector<size_t> addTransformLists(Random& random, Inputs& inputs, unsigned count)
{
    Vector<size_t> indices;
    for (unsigned i = 0; i < count; ++i) {
        Vector<Kind> kinds;
        if (random.below(30)) {
            kinds = randomKinds(random, 0, 5);
            kinds.insert(0, static_cast<Kind>(i % kindCount));
        }
        auto text = transformText(random, kinds.span());
        indices.append(inputs.addTransform(text));
    }
    return indices;
}

} // namespace StyleTransformsBenchmark

using namespace StyleTransformsBenchmark;

// Style building: each list made again from its parsed CSS value, as the style builder makes a computed value. The
// checksum adds each list's length, its CSS value's text, its serialization and its predicates.
TEST(StyleTransformsBench, BuildTransformLists)
{
    Random random(1);
    Inputs inputs;
    auto lists = addTransformLists(random, inputs, listCount);
    EXPECT_EQ(0u, inputs.rejected);
    runShape("BuildTransformLists"_s, inputs.bytes, buildChecksum, buildPasses, [&](Checksum* checksum) {
        size_t functions = 0;
        for (auto index : lists) {
            size_t size = inputs.hooks.buildTransform(index);
            functions += size;
            if (!checksum)
                continue;
            checksum->add(static_cast<uint64_t>(size));
            checksum->add(inputs.hooks.transformText(index));
            checksum->add(inputs.hooks.valueSerialization(StyleTransformsBenchmarkHooks::Property::Transform, index));
            checksum->add(inputs.hooks.transformPredicates(index));
        }
        if (checksum)
            checksum->add(static_cast<uint64_t>(functions));
    });
}

// Style::Transform::apply to the identity, at a box size and zoom per list.
TEST(StyleTransformsBench, ApplyTransformLists)
{
    Random random(2);
    Inputs inputs;
    auto lists = addTransformLists(random, inputs, listCount);
    EXPECT_EQ(0u, inputs.rejected);
    struct Geometry {
        float width;
        float height;
        float zoom;
    };
    Vector<Geometry> geometries;
    for (unsigned i = 0; i < lists.size(); ++i) {
        float width = random.pick(boxWidths);
        float height = random.pick(boxHeights);
        float zoom = random.pick(zooms);
        geometries.append({ width, height, zoom });
    }
    runShape("ApplyTransformLists"_s, lists.size() * sizeof(Matrix), applyChecksum, applyPasses, [&](Checksum* checksum) {
        double sink = 0;
        for (size_t i = 0; i < lists.size(); ++i) {
            auto& geometry = geometries[i];
            auto matrix = inputs.hooks.applyTransform(lists[i], geometry.width, geometry.height, geometry.zoom);
            sink += matrix[12];
            if (checksum)
                checksum->add(matrix);
        }
        if (checksum)
            checksum->add(sink);
    });
}

template<typename AppendPair>
static void runTransformBlends(ASCIILiteral name, uint64_t seed, uint64_t expectedChecksum, unsigned passes, AppendPair&& appendPair)
{
    Random random(seed);
    Inputs inputs;
    Vector<Pair> pairs;
    for (unsigned i = 0; i < pairCount; ++i)
        appendPair(random, inputs, pairs);
    EXPECT_EQ(0u, inputs.rejected);
    runShape(name, inputs.bytes, expectedChecksum, passes, [&](Checksum* checksum) {
        unsigned blended = 0;
        for (auto& pair : pairs) {
            bool didBlend = inputs.hooks.blendTransforms(pair.from, pair.to, pair.progress, pair.compositeOperation);
            blended += didBlend;
            if (!checksum)
                continue;
            checksum->add(static_cast<uint64_t>(didBlend));
            if (!didBlend)
                continue;
            checksum->add(static_cast<uint64_t>(inputs.hooks.blendedTransformSize()));
            checksum->add(inputs.hooks.applyBlendedTransform(pair.width, pair.height, 1));
            checksum->add(inputs.hooks.blendedTransformText());
        }
        if (checksum)
            checksum->add(static_cast<uint64_t>(blended));
    });
}

// Blending<Transform> between lists whose functions match pairwise, prefixes and none included.
TEST(StyleTransformsBench, BlendMatchingLists)
{
    runTransformBlends("BlendMatchingLists"_s, 3, blendMatchingChecksum, blendMatchingPasses, appendMatchingPair);
}

// Blending<Transform> between lists that fall back to matrix interpolation.
TEST(StyleTransformsBench, BlendMismatchedLists)
{
    runTransformBlends("BlendMismatchedLists"_s, 4, blendMismatchedChecksum, blendMismatchedPasses, appendMismatchedPair);
}

// Blending<Filter>: matching lists, missing functions, lists that cannot blend (mismatched kinds, reference filters)
// and none. The checksum also adds each input's serialization, predicates and outsets.
TEST(StyleTransformsBench, BlendFilters)
{
    Random random(5);
    Inputs inputs;
    Vector<Pair> pairs;
    for (unsigned i = 0; i < pairCount; ++i)
        appendFilterPair(random, inputs, pairs);
    EXPECT_EQ(0u, inputs.rejected);
    runShape("BlendFilters"_s, inputs.bytes, blendFiltersChecksum, blendFiltersPasses, [&](Checksum* checksum) {
        unsigned blended = 0;
        for (auto& pair : pairs) {
            bool didBlend = inputs.hooks.blendFilters(pair.from, pair.to, pair.progress, pair.compositeOperation);
            blended += didBlend;
            if (!checksum)
                continue;
            checksum->add(static_cast<uint64_t>(didBlend));
            if (didBlend) {
                checksum->add(static_cast<uint64_t>(inputs.hooks.blendedFilterSize()));
                checksum->add(inputs.hooks.blendedFilterText());
            }
            checksum->add(inputs.hooks.filterText(pair.from));
            checksum->add(inputs.hooks.filterPredicates(pair.from));
            for (int outset : inputs.hooks.filterOutsets(pair.from, pair.width ? 1 : 2))
                checksum->add(static_cast<uint64_t>(static_cast<int64_t>(outset)));
        }
        if (checksum)
            checksum->add(static_cast<uint64_t>(blended));
    });
}

// operator== as style difference uses it: each list against an equal list built separately, lists that differ in
// one argument, in one function's kind or in length, none, and an unrelated list.
TEST(StyleTransformsBench, TransformEquality)
{
    Random random(6);
    Inputs inputs;
    Vector<std::pair<size_t, size_t>> comparisons;
    Vector<size_t> bases;
    for (unsigned i = 0; i < listCount / 4; ++i) {
        auto kinds = randomKinds(random, 1, 6);
        uint64_t seed = 1000 + i;
        Random textRandom(seed);
        auto baseText = transformText(textRandom, kinds.span());
        auto base = inputs.addTransform(baseText);
        // The same text again: equal values, held separately.
        auto same = inputs.addTransform(baseText);
        // The same kinds and draws but one argument redrawn: equal up to the last function.
        Random changedRandom(seed);
        auto changedKinds = kinds;
        auto changedText = transformText(changedRandom, changedKinds.span().first(changedKinds.size() - 1));
        StringBuilder changedBuilder;
        changedBuilder.append(changedText == "none"_s ? String { } : changedText);
        if (!changedBuilder.isEmpty())
            changedBuilder.append(' ');
        appendFunction(changedBuilder, random, changedKinds.last());
        auto changed = inputs.addTransform(changedBuilder.toString());
        // Some functions swapped for another kind of their family (in one list of three or so, none is).
        auto swappedKinds = matchingKinds(random, kinds.span());
        Random swappedRandom(seed);
        auto swapped = inputs.addTransform(transformText(swappedRandom, swappedKinds.span()));
        // One function more.
        auto longerKinds = kinds;
        longerKinds.append(randomKind(random));
        Random longerRandom(seed);
        auto longer = inputs.addTransform(transformText(longerRandom, longerKinds.span()));
        comparisons.append({ base, same });
        comparisons.append({ same, base });
        comparisons.append({ base, changed });
        comparisons.append({ base, swapped });
        comparisons.append({ base, longer });
        comparisons.append({ longer, base });
        bases.append(base);
    }
    auto none = inputs.addTransform("none"_s);
    for (unsigned i = 0; i < bases.size(); ++i) {
        comparisons.append({ bases[i], none });
        comparisons.append({ bases[i], bases[(i * 7 + 3) % bases.size()] });
    }
    EXPECT_EQ(0u, inputs.rejected);
    runShape("TransformEquality"_s, inputs.bytes, equalityChecksum, equalityPasses, [&](Checksum* checksum) {
        unsigned equal = 0;
        for (auto& [a, b] : comparisons) {
            bool isEqual = inputs.hooks.transformsEqual(a, b);
            equal += isEqual;
            if (checksum)
                checksum->add(static_cast<uint64_t>(isEqual));
        }
        if (checksum)
            checksum->add(static_cast<uint64_t>(equal));
    });
}

// A page's worth of animations: 256 elements, each with a transform animation (three in four between matching
// lists, the rest mismatched) and a filter animation, at its own phase. A frame blends each element's transform,
// applies it at the element's box size, compares it with the element's starting value (style difference) and blends
// its filter. A pass is sixteen frames.
TEST(StyleTransformsBench, AnimationFrame)
{
    static constexpr unsigned elementCount = 256;
    static constexpr unsigned framesPerPass = 16;
    Random random(7);
    Inputs inputs;
    Vector<Pair> transformPairs;
    Vector<Pair> filterPairs;
    Vector<double> phases;
    for (unsigned i = 0; i < elementCount; ++i) {
        if (random.percent(75))
            appendMatchingPair(random, inputs, transformPairs);
        else
            appendMismatchedPair(random, inputs, transformPairs);
        transformPairs.last().compositeOperation = CompositeOperation::Replace;
        appendFilterPair(random, inputs, filterPairs);
        filterPairs.last().compositeOperation = CompositeOperation::Replace;
        unsigned phase = random.below(1000);
        phases.append(phase / 1000.0);
    }
    EXPECT_EQ(0u, inputs.rejected);
    runShape("AnimationFrame"_s, framesPerPass * elementCount * sizeof(Matrix), animationFrameChecksum, animationFramePasses, [&](Checksum* checksum) {
        unsigned changed = 0;
        for (unsigned frame = 0; frame < framesPerPass; ++frame) {
            for (unsigned i = 0; i < elementCount; ++i) {
                double progress = std::fmod(phases[i] + frame / static_cast<double>(framesPerPass), 1.0);
                auto& transformPair = transformPairs[i];
                if (inputs.hooks.blendTransforms(transformPair.from, transformPair.to, progress, CompositeOperation::Replace)) {
                    auto matrix = inputs.hooks.applyBlendedTransform(transformPair.width, transformPair.height, 1);
                    changed += !inputs.hooks.blendedTransformEquals(transformPair.from);
                    if (checksum)
                        checksum->add(matrix);
                }
                auto& filterPair = filterPairs[i];
                bool filterBlended = inputs.hooks.blendFilters(filterPair.from, filterPair.to, progress, CompositeOperation::Replace);
                if (checksum && filterBlended)
                    checksum->add(inputs.hooks.blendedFilterText());
            }
        }
        if (checksum)
            checksum->add(static_cast<uint64_t>(changed));
    });
}

// Blending<Translate>, Blending<Rotate> and Blending<Scale> between values of the individual transform properties,
// none included (a rotate about another axis interpolates through quaternions). The checksum adds each blend's apply
// at the pair's box size and its CSS value's text, and the serialization of the value blended from.
TEST(StyleTransformsBench, BlendIndividualProperties)
{
    static constexpr IndividualTransformProperty properties[] = {
        IndividualTransformProperty::Translate, IndividualTransformProperty::Rotate, IndividualTransformProperty::Scale,
    };
    static constexpr StyleTransformsBenchmarkHooks::Property valueProperties[] = {
        StyleTransformsBenchmarkHooks::Property::Translate, StyleTransformsBenchmarkHooks::Property::Rotate, StyleTransformsBenchmarkHooks::Property::Scale,
    };
    Random random(8);
    Inputs inputs;
    Vector<std::pair<IndividualTransformProperty, Pair>> pairs;
    for (unsigned i = 0; i < pairCount; ++i) {
        auto property = properties[i % std::size(properties)];
        auto fromText = individualTransformText(random, property);
        auto toText = individualTransformText(random, property);
        auto from = inputs.addIndividualTransform(property, fromText);
        auto to = inputs.addIndividualTransform(property, toText);
        pairs.append({ property, makePair(random, from, to) });
    }
    EXPECT_EQ(0u, inputs.rejected);
    runShape("BlendIndividualProperties"_s, inputs.bytes, blendIndividualChecksum, blendIndividualPasses, [&](Checksum* checksum) {
        unsigned blended = 0;
        for (auto& [property, pair] : pairs) {
            bool didBlend = inputs.hooks.blendIndividualTransforms(property, pair.from, pair.to, pair.progress, pair.compositeOperation);
            blended += didBlend;
            if (!checksum)
                continue;
            checksum->add(static_cast<uint64_t>(didBlend));
            checksum->add(inputs.hooks.valueSerialization(valueProperties[static_cast<unsigned>(property)], pair.from));
            if (!didBlend)
                continue;
            checksum->add(inputs.hooks.applyBlendedIndividualTransform(property, pair.width, pair.height, 1));
            checksum->add(inputs.hooks.blendedIndividualTransformText(property));
        }
        if (checksum)
            checksum->add(static_cast<uint64_t>(blended));
    });
}

} // namespace TestWebKitAPI
