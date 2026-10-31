/*
 * Copyright (C) 2024-2026 Samuel Weinig <sam@webkit.org>
 * Copyright (C) 2024 Apple Inc. All rights reserved.
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
#include "CSSCalcTree.h"

#include "CSSCalcTree+Serialization.h"
#include "CSSSerializationContext.h"
#include "CSSUnits.h"
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>

namespace WebCore {
namespace CSSCalc {

WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Abs);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Acos);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Anchor);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(AnchorSize);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Asin);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Atan);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Atan2);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(CalcMix);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Clamp);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Cos);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Deg2Rad);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Exp);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Hypot);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Invert);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Log);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Max);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Min);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Mod);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Negate);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Pow);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Product);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Progress);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(ProgressNoClamp);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Random);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Rem);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(RoundDown);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(RoundNearest);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(RoundToZero);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(RoundUp);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Sign);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Sin);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Sqrt);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Sum);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(Tan);

// MARK: - Child

Child::Child(Child&&) = default;
Child& Child::operator=(Child&&) = default;
Child::~Child() = default;
bool Child::operator==(const Child&) const = default;

static_assert(sizeof(Child) <= 24, "Child should stay small");

// MARK: - ChildOrNone

ChildOrNone::ChildOrNone(Child&& child)
    : value(WTF::move(child))
{
}

ChildOrNone::ChildOrNone(CSS::Keyword::None none)
    : value(none)
{
}

// MARK: - Children

Children::Children(Vector<Child>&& other)
    : value(WTF::move(other))
{
}

Children& Children::operator=(Vector<Child>&& other)
{
    value = WTF::move(other);
    return *this;
}

Children::iterator Children::begin()
{
    return value.begin();
}

Children::iterator Children::end()
{
    return value.end();
}

Children::reverse_iterator Children::rbegin()
{
    return value.rbegin();
}

Children::reverse_iterator Children::rend()
{
    return value.rend();
}

Children::const_iterator Children::begin() const
{
    return value.begin();
}

Children::const_iterator Children::end() const
{
    return value.end();
}

Children::const_reverse_iterator Children::rbegin() const
{
    return value.rbegin();
}

Children::const_reverse_iterator Children::rend() const
{
    return value.rend();
}

bool Children::isEmpty() const
{
    return value.isEmpty();
}

size_t Children::size() const
{
    return value.size();
}

Child& Children::operator[](size_t i)
{
    return value[i];
}

const Child& Children::operator[](size_t i) const
{
    return value[i];
}

// MARK: - AnchorSide

AnchorSide::AnchorSide(CSSValueID valueID)
    : value(valueID)
{
}

AnchorSide::AnchorSide(Child&& child)
    : value(WTF::move(child))
{
}

Child makeNumeric(double value, CSSUnitType unit)
{
    switch (unit) {
    // Number
    case CSSUnitType::Number:
    case CSSUnitType::Integer:
        return makeChild(Number { .value = value });

    // Percentage
    case CSSUnitType::Percentage:
        return makeChild(Percentage { .value = value, .hint = { } });

    // Canonical Dimension
    case CSSUnitType::Px:
        return makeChild(CanonicalDimension { .value = value, .dimension = CanonicalDimension::Dimension::Length });
    case CSSUnitType::Deg:
        return makeChild(CanonicalDimension { .value = value, .dimension = CanonicalDimension::Dimension::Angle });
    case CSSUnitType::S:
        return makeChild(CanonicalDimension { .value = value, .dimension = CanonicalDimension::Dimension::Time });
    case CSSUnitType::Hz:
        return makeChild(CanonicalDimension { .value = value, .dimension = CanonicalDimension::Dimension::Frequency });
    case CSSUnitType::Dppx:
        return makeChild(CanonicalDimension { .value = value, .dimension = CanonicalDimension::Dimension::Resolution });
    case CSSUnitType::Fr:
        return makeChild(CanonicalDimension { .value = value, .dimension = CanonicalDimension::Dimension::Flex });

    // <length>
    case CSSUnitType::Cm:
    case CSSUnitType::Mm:
    case CSSUnitType::Q:
    case CSSUnitType::In:
    case CSSUnitType::Pt:
    case CSSUnitType::Pc:
    case CSSUnitType::Em:
    case CSSUnitType::Ex:
    case CSSUnitType::Lh:
    case CSSUnitType::Cap:
    case CSSUnitType::Ch:
    case CSSUnitType::Ic:
    case CSSUnitType::Rcap:
    case CSSUnitType::Rch:
    case CSSUnitType::Rem:
    case CSSUnitType::Rex:
    case CSSUnitType::Ric:
    case CSSUnitType::Rlh:
    case CSSUnitType::Vw:
    case CSSUnitType::Vh:
    case CSSUnitType::Vmin:
    case CSSUnitType::Vmax:
    case CSSUnitType::Vb:
    case CSSUnitType::Vi:
    case CSSUnitType::Svw:
    case CSSUnitType::Svh:
    case CSSUnitType::Svmin:
    case CSSUnitType::Svmax:
    case CSSUnitType::Svb:
    case CSSUnitType::Svi:
    case CSSUnitType::Lvw:
    case CSSUnitType::Lvh:
    case CSSUnitType::Lvmin:
    case CSSUnitType::Lvmax:
    case CSSUnitType::Lvb:
    case CSSUnitType::Lvi:
    case CSSUnitType::Dvw:
    case CSSUnitType::Dvh:
    case CSSUnitType::Dvmin:
    case CSSUnitType::Dvmax:
    case CSSUnitType::Dvb:
    case CSSUnitType::Dvi:
    case CSSUnitType::Cqw:
    case CSSUnitType::Cqh:
    case CSSUnitType::Cqi:
    case CSSUnitType::Cqb:
    case CSSUnitType::Cqmin:
    case CSSUnitType::Cqmax:
    // <angle>
    case CSSUnitType::Rad:
    case CSSUnitType::Grad:
    case CSSUnitType::Turn:
    // <time>
    case CSSUnitType::Ms:
    // <frequency>
    case CSSUnitType::Khz:
    // <resolution>
    case CSSUnitType::X:
    case CSSUnitType::Dpi:
    case CSSUnitType::Dpcm:
        return makeChild(NonCanonicalDimension { .value = value, .unit = unit });

    // Non-numeric types are not supported.
    case CSSUnitType::Calc:
    case CSSUnitType::CalcPercentageWithAngle:
    case CSSUnitType::CalcPercentageWithLength:
    case CSSUnitType::QuirkyEm:
    case CSSUnitType::Unknown:
        break;
    }

    ASSERT_NOT_REACHED();
    return makeChild(Number { .value = 0 });
}

Type getType(CanonicalDimension::Dimension dimension)
{
    switch (dimension) {
    case CanonicalDimension::Dimension::Length:         return Type { .length = 1 };
    case CanonicalDimension::Dimension::Angle:          return Type { .angle = 1 };
    case CanonicalDimension::Dimension::Time:           return Type { .time = 1 };
    case CanonicalDimension::Dimension::Frequency:      return Type { .frequency = 1 };
    case CanonicalDimension::Dimension::Resolution:     return Type { .resolution = 1 };
    case CanonicalDimension::Dimension::Flex:           return Type { .flex = 1 };
    }

    ASSERT_NOT_REACHED();
    return Type { };
}

Type getType(const Number&)
{
    return Type { };
}

Type getType(const Percentage& root)
{
    auto type = Type { .percent = 1 };
    if (root.hint)
        type.applyPercentHint(*root.hint);
    return type;
}

Type getType(const CanonicalDimension& root)
{
    return getType(root.dimension);
}

Type getType(const NonCanonicalDimension& root)
{
    return Type::determineType(toCSSUnit(root));
}

Type getType(const Symbol& root)
{
    return Type::determineType(root.unit);
}

Type getType(const SiblingCount&)
{
    return Type { };
}

Type getType(const SiblingIndex&)
{
    return Type { };
}

Type getType(const Child& child)
{
    return WTF::switchOn(child, [&](const auto& root) { return getType(root); });
}

std::optional<Type> toType(const Sum& root)
{
    std::optional<Type> type = getType(root.children[0]);
    for (size_t i = 1; i < root.children.size(); ++i)
        type = Type::add(type, getType(root.children[i]));
    return type;
}

std::optional<Type> toType(const Product& root)
{
    std::optional<Type> type = getType(root.children[0]);
    for (size_t i = 1; i < root.children.size(); ++i)
        type = Type::multiply(type, getType(root.children[i]));
    return type;
}

std::optional<Type> toType(const Negate& root)
{
    return getType(root.a);
}

std::optional<Type> toType(const Invert& root)
{
    return Type::invert(getType(root.a));
}

// Utilities to deduce the right input/merge/output policies from the operation.

template<typename Op> static std::optional<Type> getValidatedTypeFor(const Op&, const Child& child)
{
    auto type = getType(child);
    if (validateType<Op::input>(type))
        return type;
    return std::nullopt;
}

template<typename Op> NODELETE static std::optional<Type> mergeTypesFor(const Op&, std::optional<Type> a, std::optional<Type> b)
{
    return mergeTypes<Op::merge>(a, b);
}

template<typename Op, typename... Args> NODELETE static std::optional<Type> transformTypeFor(const Op&, std::optional<Type> a)
{
    return transformType<Op::output>(a);
}

std::optional<Type> toType(const Min& root)
{
    auto type = getValidatedTypeFor(root, root.children[0]);
    for (size_t i = 1; i < root.children.size(); ++i)
        type = mergeTypesFor(root, type, getValidatedTypeFor(root, root.children[i]));
    return transformTypeFor(root, type);
}

std::optional<Type> toType(const Max& root)
{
    auto type = getValidatedTypeFor(root, root.children[0]);
    for (size_t i = 1; i < root.children.size(); ++i)
        type = mergeTypesFor(root, type, getValidatedTypeFor(root, root.children[i]));
    return transformTypeFor(root, type);
}

std::optional<Type> toType(const Clamp& root)
{
    auto type = getValidatedTypeFor(root, root.val);
    if (WTF::holdsAlternative<Child>(root.min))
        type = mergeTypesFor(root, type, getValidatedTypeFor(root, std::get<Child>(root.min.value)));
    if (WTF::holdsAlternative<Child>(root.max))
        type = mergeTypesFor(root, type, getValidatedTypeFor(root, std::get<Child>(root.max.value)));
    return transformTypeFor(root, type);
}

TextStream& operator<<(TextStream& ts, Tree tree)
{
    return ts << "CSSCalc::Tree [ "_s << serializationForCSS(tree, { .range = CSS::All, .serializationContext = CSS::defaultSerializationContext() }) << " ]"_s;
}

// Typed OM expressions have only these nodes; a null operand is `none`.
static void appendRecords(Vector<CSSCalcNodeRecord, 4>& nodes, const Child& child)
{
    auto start = nodes.size();
    uint32_t childCount = 0;
    auto append = [&](CSSCalcNodeKind kind, Type type, auto unit, double value, int flags) {
        nodes.append({ static_cast<uint8_t>(kind), static_cast<uint8_t>(flags), static_cast<uint16_t>(unit), 1, UINT32_MAX, 0, std::bit_cast<uint64_t>(type), value });
    };
    auto appendOperation = [&](CSSCalcNodeKind kind, Type type, std::initializer_list<const Child*> operands, int flags) {
        append(kind, type, 0, 0, flags);
        for (auto* operand : operands) {
            if (!operand)
                continue;
            ++childCount;
            appendRecords(nodes, *operand);
        }
    };
    auto appendVariadic = [&](CSSCalcNodeKind kind, Type type, const Children& operands) {
        append(kind, type, 0, 0, 0);
        for (auto& operand : operands)
            appendRecords(nodes, operand);
        childCount = static_cast<uint32_t>(operands.size());
    };
    WTF::switchOn(child,
        [&](const Number& number) { append(CSSCalcNodeKind::Number, getType(number), CSSUnitType::Number, number.value, 0); },
        [&](const Percentage& percentage) { append(CSSCalcNodeKind::Percentage, getType(percentage), percentage.hint ? static_cast<uint8_t>(*percentage.hint) : 0, percentage.value, percentage.hint ? CSSCalcNodeFlagPercentHint : 0); },
        [&](const CanonicalDimension& dimension) { append(CSSCalcNodeKind::CanonicalDimension, getType(dimension), toCSSUnit(dimension), dimension.value, 0); },
        [&](const NonCanonicalDimension& dimension) { append(CSSCalcNodeKind::NonCanonicalDimension, getType(dimension), dimension.unit, dimension.value, 0); },
        [&](const IndirectNode<Sum>& node) { appendVariadic(CSSCalcNodeKind::Sum, node.type, node->children); },
        [&](const IndirectNode<Product>& node) { appendVariadic(CSSCalcNodeKind::Product, node.type, node->children); },
        [&](const IndirectNode<Min>& node) { appendVariadic(CSSCalcNodeKind::Min, node.type, node->children); },
        [&](const IndirectNode<Max>& node) { appendVariadic(CSSCalcNodeKind::Max, node.type, node->children); },
        [&](const IndirectNode<Negate>& node) { appendOperation(CSSCalcNodeKind::Negate, node.type, { &node->a }, 0); },
        [&](const IndirectNode<Invert>& node) { appendOperation(CSSCalcNodeKind::Invert, node.type, { &node->a }, 0); },
        [&](const IndirectNode<Clamp>& node) {
            auto* min = std::get_if<Child>(&node->min.value);
            auto* max = std::get_if<Child>(&node->max.value);
            appendOperation(CSSCalcNodeKind::Clamp, node.type, { min, &node->val, max }, (min ? 0 : CSSCalcNodeFlagMinIsNone) | (max ? 0 : CSSCalcNodeFlagMaxIsNone));
        },
        [&](const auto&) { RELEASE_ASSERT_NOT_REACHED(); });
    nodes[start].subtreeSize = static_cast<uint32_t>(nodes.size() - start);
    nodes[start].childCount = childCount;
}

bool TreeStorage::operator==(const TreeStorage& other) const
{
    if (nodes.size() != other.nodes.size())
        return false;
    for (size_t i = 0; i < nodes.size(); ++i) {
        auto& a = nodes[i];
        auto& b = other.nodes[i];
        if (a.kind != b.kind || a.flags != b.flags || a.unit != b.unit || a.subtreeSize != b.subtreeSize || a.childCount != b.childCount || a.typeBits != b.typeBits || a.value != b.value)
            return false;
        if ((a.payload == UINT32_MAX) != (b.payload == UINT32_MAX))
            return false;
        if (a.payload != UINT32_MAX && !(payloads[a.payload] == other.payloads[b.payload]))
            return false;
    }
    return true;
}

Tree makeTree(const Child& root, Type type, Stage stage, bool requiresConversionData)
{
    Tree tree { .storage = { }, .type = type, .stage = stage, .requiresConversionData = requiresConversionData };
    appendRecords(tree.storage.nodes, root);
    return tree;
}
} // namespace CSSCalc
} // namespace WebCore
