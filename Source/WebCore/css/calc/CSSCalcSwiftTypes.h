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

#pragma once

#include <WebCore/CSSCalcOperator.h>
#include <WebCore/CSSCalcType.h>
#include <WebCore/CSSPrimitiveNumericCategory.h>
#include <WebCore/CSSUnits.h>
#include <WebCore/CSSValueKeywords.h>
#include <cstdint>
#include <span>
#include <type_traits>
#include <wtf/Assertions.h>
#include <wtf/Noncopyable.h>

namespace WebCore {

// The node kinds of a CSSCalc::Tree's records: CSSCalc::Node's alternatives, and a calc-mix() item, whose weight is
// its payload and whose value is its child.
enum class CSSCalcNodeKind : uint8_t {
    Number, Percentage, CanonicalDimension, NonCanonicalDimension, Symbol, SiblingCount, SiblingIndex,
    Sum, Product, Negate, Invert, Deg2Rad, Min, Max, Clamp, RoundNearest, RoundUp, RoundDown, RoundToZero, Mod, Rem,
    Sin, Cos, Tan, Asin, Acos, Atan, Atan2, Pow, Sqrt, Hypot, Log, Exp, Abs, Sign, Random, Progress, ProgressNoClamp,
    CalcMix, Anchor, AnchorSize, CalcMixItem
};

// The node kinds of a Style::Calculation::Tree's records, and a calc-mix() item, whose weight is its value.
enum class StyleCalcNodeKind : uint8_t {
    Number, Percentage, Dimension, Size, Sum, Product, Negate, Invert, Min, Max, Clamp, RoundNearest, RoundUp,
    RoundDown, RoundToZero, Mod, Rem, Sin, Cos, Tan, Asin, Acos, Atan, Atan2, Pow, Sqrt, Hypot, Log, Exp, Abs, Sign,
    Progress, ProgressNoClamp, Random, CalcMix, CalcMixItem
};

// Bits of a record's flags.
enum : uint8_t {
    CSSCalcNodeFlagMinIsNone = 1 << 0, // clamp()'s first argument is `none`.
    CSSCalcNodeFlagMaxIsNone = 1 << 1, // clamp()'s last argument is `none`.
    CSSCalcNodeFlagOptionalAbsent = 1 << 2, // The optional last argument (round(), log(), random(), the anchor fallback) is absent.
    CSSCalcNodeFlagPercentHint = 1 << 3, // A percentage's hint, in unit, is present.
    CSSCalcNodeFlagSideIsChild = 1 << 4, // anchor()'s side is its first child rather than the keyword in unit.
};

// A tree is its records in pre-order: node i's subtree is records [i, i + subtreeSize), its children following it.
// Values Swift does not read (anchor names, random keys, calc-mix weights) are C++ payloads named by index.
struct CSSCalcNodeRecord {
    uint8_t kind; // CSSCalcNodeKind.
    uint8_t flags;
    uint16_t unit; // A leaf's CSSUnitType, an anchor side's CSSValueID, a rounding or anchor-size keyword.
    uint32_t subtreeSize;
    uint32_t payload; // An index into the tree's payloads, or UINT32_MAX.
    uint32_t childCount; // A symbol's CSSValueID.
    uint64_t typeBits; // The node's CSSCalc::Type.
    double value;

    bool operator==(const CSSCalcNodeRecord&) const = default;
};

struct StyleCalcNodeRecord {
    uint8_t kind; // StyleCalcNodeKind.
    uint8_t flags;
    uint16_t reserved;
    uint32_t subtreeSize;
    double value;

    bool operator==(const StyleCalcNodeRecord&) const = default;
};

using CSSCalcNodeSpan = std::span<const CSSCalcNodeRecord>;
using StyleCalcNodeSpan = std::span<const StyleCalcNodeRecord>;

// One CSSParserToken of a math function's arguments.
struct CSSCalcSwiftToken {
    uint8_t type; // CSSParserTokenType.
    uint8_t blockType; // CSSParserToken::BlockType: whether the token starts a block or ends the block it is in.
    uint16_t id; // The CSSValueID of an ident or function token, or a delimiter's character.
    uint32_t unit; // CSSUnitType, widened so that the token has no padding.
    double numericValue;
};

// What calc() may contain where it is parsed, from CSSCalc::ParserOptions and the property parser's state.
enum : uint32_t {
    CSSCalcParseAllowAnchor = 1 << 0,
    CSSCalcParseAllowAnchorSize = 1 << 1,
    CSSCalcParseAllowUnitlessZeroLength = 1 << 2,
    CSSCalcParseAbsoluteLengthUnitsOnly = 1 << 3,
    CSSCalcParseAllowRandom = 1 << 4,
    CSSCalcParseAllowTreeCounting = 1 << 5,
    CSSCalcParseAllowCalcMix = 1 << 6,
};

// CSSCalc::SimplificationOptions without the conversion data and symbol table, which the resolver holds.
struct CSSCalcSwiftSimplificationOptions {
    uint8_t category; // CSS::Category.
    uint8_t hasConversionData;
    uint8_t allowZeroValueLengthRemovalFromSum;
};

struct CSSCalcSwiftParseResult {
    uint64_t typeBits;
    uint32_t consumedTokens;
    uint8_t ok;
    uint8_t requiresConversionData;
};

struct CSSCalcSwiftNumericResult {
    double value;
    uint8_t ok;
};

struct CSSCalcSwiftSymbolValue {
    double value;
    uint16_t unit;
    uint8_t ok;
};

// The payload a parser call appended, or UINT32_MAX on failure, and the index of the first token after what it
// consumed.
struct CSSCalcSwiftConsumed {
    uint32_t payload;
    uint32_t nextToken;
};

// What serializing a random() payload needs besides its name or fixed value.
struct CSSCalcSwiftRandomSharing {
    uint8_t kind; // 0 auto, 1 key, 2 fixed.
    uint8_t hasName;
    uint8_t elementScoped;
    uint8_t propertyScope; // 0 none, 1 property-scoped, 2 property-index-scoped.
};

// The facades Swift calls back through during one entry. Each is an empty base of state on the C++ entry's stack,
// which only that entry constructs, and is passed to Swift inout: it cannot be copied, made (each facade's own
// default constructor is protected), moved (the move constructor traps) or reached from another thread.
// CSSCalcSwiftFacade's destructor is user-provided, so that no facade is relocated bitwise. Every member checks its
// arguments against the state.
class __attribute__((swift_attr("~Sendable"))) CSSCalcSwiftFacade {
public:
    WTF_MAKE_NONCOPYABLE(CSSCalcSwiftFacade);
    [[noreturn]] CSSCalcSwiftFacade(CSSCalcSwiftFacade&&) { RELEASE_ASSERT_NOT_REACHED(); }
    ~CSSCalcSwiftFacade() { }
protected:
    CSSCalcSwiftFacade() = default;
};

// The parse of one math function's arguments.
struct __attribute__((swift_attr("~Sendable"))) CSSCalcSwiftParser : CSSCalcSwiftFacade {
    uint32_t tokenCount();
    // Writes the tokens to the front of tokens.
    void fillTokens([[clang::noescape]] std::span<CSSCalcSwiftToken> tokens);
    // The CSSUnitType of an allowed symbol, or -1.
    int32_t allowedSymbolUnit(uint16_t valueID);
    // Each consumes from token index on and appends what it consumed to the tree's payloads. A random() with no
    // <random-key> consumes nothing and appends `auto`.
    CSSCalcSwiftConsumed consumeRandomSharing(uint32_t index);
    // Counts one random() in the property parser state.
    void countRandomFunction();
    CSSCalcSwiftConsumed consumeDashedIdent(uint32_t index);
    CSSCalcSwiftConsumed consumeCalcMixWeight(uint32_t index);
protected:
    CSSCalcSwiftParser() = default;
};

// Conversion data, the symbol table and the style builder state, for simplification and evaluation.
struct __attribute__((swift_attr("~Sendable"))) CSSCalcSwiftResolver : CSSCalcSwiftFacade {
    double resolveLength(double value, uint16_t unit);
    // A px length as Style::resolveLength resolves it, with the text zoom of the property.
    double resolveStyleLength(double value);
    bool hasStyleBuilderState();
    CSSCalcSwiftSymbolValue resolveSymbol(uint16_t valueID);
    CSSCalcSwiftNumericResult siblingCount();
    CSSCalcSwiftNumericResult siblingIndex();
    CSSCalcSwiftNumericResult resolveAnchor(uint32_t namePayload, uint16_t sideValueID, double sideFraction);
    CSSCalcSwiftNumericResult resolveAnchorSize(uint32_t namePayload, uint8_t dimension);
    CSSCalcSwiftNumericResult resolveRandomBaseValue(uint32_t payload);
    CSSCalcSwiftNumericResult resolveCalcMixWeight(uint32_t payload);
    void markInvalidAtComputedValueTime();
    // CSS::normalizedMixPercentages over the weights of present[i] items, written to the front of normalized.
    void normalizeMixPercentages([[clang::noescape]] std::span<const double> weights, [[clang::noescape]] std::span<const uint8_t> present, [[clang::noescape]] std::span<double> normalized);
protected:
    CSSCalcSwiftResolver() = default;
};

// Appends a serialization to a StringBuilder.
struct __attribute__((swift_attr("~Sendable"))) CSSCalcSwiftSerializer : CSSCalcSwiftFacade {
    void appendLatin1([[clang::noescape]] std::span<const uint8_t> characters);
    void appendNumber(double value, uint16_t unit);
    void appendValueIDName(uint16_t valueID);
    // An anchor name, a calc-mix weight, a random() key's name or fixed value.
    void appendPayload(uint32_t payload);
    CSSCalcSwiftRandomSharing randomSharing(uint32_t payload);
protected:
    CSSCalcSwiftSerializer() = default;
};

// Builds a CSSNumericValue from a tree, bottom up, on a stack of values.
struct __attribute__((swift_attr("~Sendable"))) CSSCalcSwiftNumericValueBuilder : CSSCalcSwiftFacade {
    // Each returns false once an exception is recorded.
    bool pushUnitValue(double value, uint16_t unit);
    bool pushOperation(uint8_t kind, uint32_t operandCount);
protected:
    CSSCalcSwiftNumericValueBuilder() = default;
};

// Receives a CSSCalc::Tree's records.
struct __attribute__((swift_attr("~Sendable"))) CSSCalcSwiftOutput : CSSCalcSwiftFacade {
    void adopt([[clang::noescape]] std::span<const CSSCalcNodeRecord> nodes);
    uint32_t appendCalcMixWeight(double weight);
    uint32_t appendRandomFixed(double baseValue);
protected:
    CSSCalcSwiftOutput() = default;
};

// The operations of styleCalcCombine.
enum class StyleCalcCombination : uint8_t { Add, Subtract, Multiply, Blend };

// Receives a Style::Calculation::Tree's records.
struct __attribute__((swift_attr("~Sendable"))) StyleCalcSwiftOutput : CSSCalcSwiftFacade {
    void adopt([[clang::noescape]] std::span<const StyleCalcNodeRecord> nodes);
protected:
    StyleCalcSwiftOutput() = default;
};

// Writes a Style::Calculation::Tree to a TextStream.
struct __attribute__((swift_attr("~Sendable"))) StyleCalcSwiftDumpSink : CSSCalcSwiftFacade {
    void appendLatin1([[clang::noescape]] std::span<const uint8_t> characters);
    // With TextStream::FormatNumberRespectingIntegers, or as TextStream writes a double.
    void appendNumber(double value, bool respectingIntegers);
    void appendOperator(CSSCalc::Operator);
protected:
    StyleCalcSwiftDumpSink() = default;
};

// The shape that keeps a facade's address: checked by a static_assert beside each facade's members.
template<typename Facade> constexpr bool isCSSCalcSwiftFacade = std::is_empty_v<Facade> && !std::is_polymorphic_v<Facade>
    && !std::is_default_constructible_v<Facade> && !std::is_copy_constructible_v<Facade> && !std::is_copy_assignable_v<Facade>
    && !std::is_move_assignable_v<Facade> && std::is_move_constructible_v<Facade> && !std::is_trivially_destructible_v<Facade>;

} // namespace WebCore
