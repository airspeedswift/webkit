/*
 * Copyright (C) 2024-2026 Samuel Weinig <sam@webkit.org>
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
#include "CSSCalcTree+ComputedStyleDependencies.h"

#include "CSSCalcTree+Traversal.h"
#include "CSSPrimitiveNumericTypes+ComputedStyleDependencies.h"
#include "CSSPropertyNames.h"
#include "CSSUnits.h"
#include "ComputedStyleDependencies.h"

namespace WebCore {
namespace CSSCalc {

void collectComputedStyleDependencies(const Child& root, ComputedStyleDependencies& dependencies)
{
    WTF::switchOn(root,
        [&](const Number&) {
            // No potential dependencies.
        },
        [&](const Percentage&) {
            // No potential dependencies.
        },
        [&](const CanonicalDimension&) {
            // No potential dependencies.
        },
        [&](const NonCanonicalDimension& root) {
            if (auto lengthUnit = CSS::toLengthUnit(root.unit))
                CSS::collectComputedStyleDependencies(dependencies, *lengthUnit);
        },
        [&](const Symbol& root) {
            if (auto lengthUnit = CSS::toLengthUnit(root.unit))
                CSS::collectComputedStyleDependencies(dependencies, *lengthUnit);
        },
        [&](const SiblingCount&) {
            dependencies.siblingFunctions = true;
        },
        [&](const SiblingIndex&) {
            dependencies.siblingFunctions = true;
        },
        [&](const IndirectNode<CalcMix>& root) {
            for (const auto& item : root->children) {
                collectComputedStyleDependencies(item.value, dependencies);
                CSS::collectComputedStyleDependencies(dependencies, item.weight);
            }
        },
        [&](const IndirectNode<Anchor>& anchor) {
            dependencies.anchorFunctions = true;
            if (anchor->fallback)
                collectComputedStyleDependencies(*anchor->fallback, dependencies);
        },
        [&](const IndirectNode<AnchorSize>& anchorSize) {
            dependencies.anchorFunctions = true;
            if (anchorSize->fallback)
                collectComputedStyleDependencies(*anchorSize->fallback, dependencies);
        },
        [&](const auto& root) {
            forAllChildNodes(*root, [&](const auto& root) { collectComputedStyleDependencies(root, dependencies); });
        }
    );
}

void collectComputedStyleDependencies(const Tree& tree, ComputedStyleDependencies& dependencies)
{
    auto& nodes = tree.storage.nodes;
    for (size_t i = 0; i < nodes.size(); ++i) {
        auto& node = nodes[i];
        switch (static_cast<CSSCalcNodeKind>(node.kind)) {
        case CSSCalcNodeKind::NonCanonicalDimension:
        case CSSCalcNodeKind::Symbol:
            if (auto lengthUnit = CSS::toLengthUnit(static_cast<CSSUnitType>(node.unit)))
                CSS::collectComputedStyleDependencies(dependencies, *lengthUnit);
            break;
        case CSSCalcNodeKind::SiblingCount:
        case CSSCalcNodeKind::SiblingIndex:
            dependencies.siblingFunctions = true;
            break;
        case CSSCalcNodeKind::CalcMixItem:
            if (node.payload != UINT32_MAX)
                CSS::collectComputedStyleDependencies(dependencies, std::get<CSS::Percentage<CSS::ClosedPercentageRange>>(tree.storage.payloads[node.payload]));
            break;
        case CSSCalcNodeKind::Anchor:
        case CSSCalcNodeKind::AnchorSize:
            dependencies.anchorFunctions = true;
            // An anchor side given as a percentage has no dependencies of its own.
            if (node.flags & CSSCalcNodeFlagSideIsChild)
                i += nodes[i + 1].subtreeSize;
            break;
        default:
            break;
        }
    }
}

} // namespace CSSCalc
} // namespace WebCore
