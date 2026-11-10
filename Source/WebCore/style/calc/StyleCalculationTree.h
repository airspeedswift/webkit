/*
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

#pragma once

#include <WebCore/CSSCalcOperator.h>
#include <WebCore/CSSValueKeywords.h>
#include <optional>
#include <tuple>
#include <wtf/Ref.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/Vector.h>

#include <WebCore/CSSCalcSwiftTypes.h>
#include <wtf/ForbidHeapAllocation.h>

namespace WebCore {
namespace Style {
namespace Calculation {

// `Style::Calculation::Tree` is a reduced representation of `CSSCalc::Tree` used in cases where everything else (e.g all non-canonical dimensions) has been resolved except percentages, which can't be resolved until they are used as they need some value to resolve against. Currently, these are only used by the `Length` type to represent <length-percentage> values, but are implemented generically so can be used for any <*-percentage> type if the need ever arises.

// Container.
struct Tree;

// The `size` keyword of calc-size(). Carries no value because it stands for the used value of the
// calc-size basis, which is not known until layout resolves it.
struct Size {
    static constexpr bool isLeaf = true;

    bool operator==(const Size&) const = default;
};

// A tree as records (CSSCalcSwiftTypes.h).
struct Child {
    Vector<StyleCalcNodeRecord, 4> nodes;

    Child(Size) : nodes { { static_cast<uint8_t>(StyleCalcNodeKind::Size), 0, 0, 1, 0 } } { }
    explicit Child(Vector<StyleCalcNodeRecord, 4>&& nodes) : nodes(WTF::move(nodes)) { }
    Child(Child&&) = default;
    Child& operator=(Child&&) = default;

    bool operator==(const Child&) const = default;
};

// The state behind StyleCalcSwiftOutput: the tree it writes.
class SwiftOutput final : public StyleCalcSwiftOutput {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    Child take() { return Child { WTF::move(nodes) }; }

    Vector<StyleCalcNodeRecord, 4> nodes;
};

struct Tree {
    Child root;

    bool operator==(const Tree&) const = default;
};

size_t computeDepth(const Tree&);

// Distinct from computeDepth(): substitution multiplies a tree rather than deepening it, so the two
// bound different things.
size_t computeNodeCount(const Tree&);
size_t computeNodeCount(const Child&);

// Convenience constructors

NODELETE Child number(double value);
NODELETE Child percentage(double value);
NODELETE Child dimension(double value);
Child add(Child&& a, Child&& b);
Child multiply(Child&& a, Child&& b);
Child subtract(Child&& a, Child&& b);
Child blend(Child&& from, Child&& to, double progress);

// MARK: Dumping

TextStream& operator<<(TextStream&, const Tree&);

} // namespace Calculation
} // namespace Style
} // namespace WebCore
