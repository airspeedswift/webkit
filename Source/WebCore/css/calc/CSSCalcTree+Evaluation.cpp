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
#include "CSSCalcTree+Evaluation.h"

#include "AnchorPositionEvaluator.h"
#include "CSSCalcRandomCachingKey.h"
#include "CSSCalcSymbolTable.h"
#include "CSSCalcTree+Simplification.h"
#include "CSSCalcTree.h"
#include "CSSCalcType.h"
#include "CSSUnevaluatedCalc.h"
#include "StyleBuilderState.h"
#include "StyleComputedStyle.h"
#include "StyleCustomIdent.h"
#include "StylePrimitiveNumericTypes+Conversions.h"

#include "WebCore-Swift.h"

namespace WebCore {
namespace CSSCalc {

std::optional<double> resolveRandomBaseValue(const Random::Sharing& sharing, Style::BuilderState& builderState)
{
    return WTF::switchOn(sharing,
        [&](const Random::SharingAuto& sharingAuto) -> std::optional<double> {
            if (sharingAuto.elementScoped && !builderState.element())
                return { };

            RandomCachingKey::Key key {
                .name = std::nullopt,
                .propertyScoped = Random::Key::PropertyIndexScoped { sharingAuto.property, sharingAuto.index }
            };
            return builderState.lookupCSSRandomBaseValue(RandomCachingKey { WTF::move(key) }, sharingAuto.elementScoped);
        },
        [&](const Random::Key& sharingKey) -> std::optional<double> {
            if (sharingKey.elementScoped && !builderState.element())
                return { };

            RandomCachingKey::Key key;
            if (sharingKey.name)
                key.name = Style::toStyle(*sharingKey.name, builderState);
            key.propertyScoped = sharingKey.propertyScoped;
            return builderState.lookupCSSRandomBaseValue(RandomCachingKey { WTF::move(key) }, sharingKey.elementScoped);
        },
        [&](const Random::SharingFixed& sharingFixed) -> std::optional<double> {
            return Style::toStyle(sharingFixed.value, builderState).value;
        }
    );
}

std::optional<double> evaluateDouble(const Tree& tree, const EvaluationOptions& options)
{
    SwiftResolverState resolver { options.conversionData, options.symbolTable, tree.storage };
    auto result = cssCalcEvaluate(tree.storage.nodes.span(), resolver, options.conversionData.has_value());
    if (!result.ok)
        return std::nullopt;
    return result.value;
}

} // namespace CSSCalc
} // namespace WebCore
