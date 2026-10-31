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

#include "config.h"
#include "StyleCalculationTree.h"

#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>

#include "WebCore-Swift.h"

namespace WebCore {
namespace Style {
namespace Calculation {

static Vector<StyleCalcNodeRecord, 4> leaf(StyleCalcNodeKind kind, double value)
{
    return { { static_cast<uint8_t>(kind), 0, 0, 1, value } };
}

Child number(double value)
{
    return Child { leaf(StyleCalcNodeKind::Number, value) };
}

Child percentage(double value)
{
    return Child { leaf(StyleCalcNodeKind::Percentage, value) };
}

Child dimension(double value)
{
    return Child { leaf(StyleCalcNodeKind::Dimension, value) };
}

static Child combine(StyleCalcCombination combination, const Child& a, const Child& b, double progress)
{
    SwiftOutput output;
    styleCalcCombine(static_cast<uint8_t>(combination), a.nodes.span(), b.nodes.span(), progress, output);
    return output.take();
}

Child add(Child&& a, Child&& b)
{
    return combine(StyleCalcCombination::Add, a, b, 0);
}

Child multiply(Child&& a, Child&& b)
{
    return combine(StyleCalcCombination::Multiply, a, b, 0);
}

Child subtract(Child&& a, Child&& b)
{
    return combine(StyleCalcCombination::Subtract, a, b, 0);
}

Child blend(Child&& from, Child&& to, double progress)
{
    return combine(StyleCalcCombination::Blend, from, to, progress);
}

size_t computeDepth(const Tree& tree)
{
    return styleCalcDepth(tree.root.nodes.span());
}

size_t computeNodeCount(const Child& root)
{
    return root.nodes.size() - std::ranges::count(root.nodes, static_cast<uint8_t>(StyleCalcNodeKind::CalcMixItem), &StyleCalcNodeRecord::kind);
}

size_t computeNodeCount(const Tree& tree)
{
    return computeNodeCount(tree.root);
}

namespace {

class SwiftDumpSink final : public StyleCalcSwiftDumpSink {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    explicit SwiftDumpSink(TextStream& ts)
        : ts(ts)
    {
    }

    TextStream& ts;
};

} // namespace (anonymous)

TextStream& operator<<(TextStream& ts, const Tree& tree)
{
    SwiftDumpSink sink { ts };
    styleCalcDump(tree.root.nodes.span(), sink);
    return ts;
}

} // namespace Calculation
} // namespace Style

static_assert(isCSSCalcSwiftFacade<StyleCalcSwiftOutput>);

void StyleCalcSwiftOutput::adopt([[clang::noescape]] std::span<const StyleCalcNodeRecord> nodes)
{
    // Built before it replaces the records, which nodes may view.
    static_cast<Style::Calculation::SwiftOutput&>(*this).nodes = Vector<StyleCalcNodeRecord, 4> { nodes };
}

static_assert(isCSSCalcSwiftFacade<StyleCalcSwiftDumpSink>);

void StyleCalcSwiftDumpSink::appendLatin1([[clang::noescape]] std::span<const uint8_t> characters)
{
    static_cast<Style::Calculation::SwiftDumpSink&>(*this).ts << StringView { byteCast<Latin1Character>(characters) };
}

void StyleCalcSwiftDumpSink::appendNumber(double value, bool respectingIntegers)
{
    auto& ts = static_cast<Style::Calculation::SwiftDumpSink&>(*this).ts;
    if (respectingIntegers)
        ts << TextStream::FormatNumberRespectingIntegers(value);
    else
        ts << value;
}

void StyleCalcSwiftDumpSink::appendOperator(CSSCalc::Operator op)
{
    static_cast<Style::Calculation::SwiftDumpSink&>(*this).ts << op;
}

} // namespace WebCore
