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
#include "StyleCalculationTree+Substitution.h"

#include "StyleCalculationTree+Copy.h"
#include "StyleCalculationTree.h"
#include <wtf/StdLibExtras.h>

#include "WebCore-Swift.h"

namespace WebCore {
namespace Style {
namespace Calculation {

// styleCalcSubstituteSize's bound.
static_assert(maximumCalcSizeNodeCount == 1024);

std::optional<Tree> substituteSize(const Tree& tree, const Child& insertion)
{
    SwiftOutput output;
    if (!styleCalcSubstituteSize(tree.root.nodes.span(), insertion.nodes.span(), output))
        return std::nullopt;
    return Tree { output.take() };
}

Tree dePercentify(const Tree& tree)
{
    SwiftOutput output;
    styleCalcDePercentify(tree.root.nodes.span(), output);
    return Tree { output.take() };
}

bool containsSize(const Tree& tree)
{
    return std::ranges::any_of(tree.root.nodes, [](auto& node) { return node.kind == static_cast<uint8_t>(StyleCalcNodeKind::Size); });
}

bool containsPercentage(const Tree& tree)
{
    return std::ranges::any_of(tree.root.nodes, [](auto& node) { return node.kind == static_cast<uint8_t>(StyleCalcNodeKind::Percentage); });
}

} // namespace Calculation
} // namespace Style
} // namespace WebCore
