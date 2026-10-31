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
#include "CSSCalcTree+Serialization.h"

#include "AnchorPositionEvaluator.h"
#include "CSSCalcSymbolTable.h"
#include "CSSCalcTree+Traversal.h"
#include "CSSCalcTree.h"
#include "CSSMarkup.h"
#include "CSSPrimitiveNumericTypes+Serialization.h"
#include "CSSPrimitiveValue.h"
#include "CSSUnits.h"
#include <limits>
#include <ranges>
#include <wtf/text/StringBuilder.h>

#include "WebCore-Swift.h"
#include <wtf/ForbidHeapAllocation.h>

namespace WebCore {
namespace CSSCalc {

String serializationForCSS(const Tree& tree, const SerializationOptions& options)
{
    StringBuilder builder;
    serializationForCSS(builder, tree, options);
    return builder.toString();
}

namespace {

class SwiftSerializerState final : public CSSCalcSwiftSerializer {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    SwiftSerializerState(StringBuilder& builder, const CSS::SerializationContext& context, const TreeStorage& storage)
        : builder(builder)
        , context(context)
        , storage(storage)
    {
    }

    StringBuilder& builder;
    const CSS::SerializationContext& context;
    const TreeStorage& storage;
};

} // namespace (anonymous)

static void serializeWithSwift(StringBuilder& builder, const Tree& tree, const SerializationOptions& options, bool asFunctionArgument)
{
    SwiftSerializerState serializer { builder, options.serializationContext, tree.storage };
    cssCalcSerialize(tree.storage.nodes.span(), serializer, tree.stage == Stage::Computed, options.range.min, options.range.max, asFunctionArgument);
}

void serializationForCSS(StringBuilder& builder, const Tree& tree, const SerializationOptions& options)
{
    serializeWithSwift(builder, tree, options, false);
}

void serializationForCSSAsFunctionArgument(StringBuilder& builder, const Tree& tree, const SerializationOptions& options)
{
    serializeWithSwift(builder, tree, options, true);
}

} // namespace CSSCalc

static_assert(isCSSCalcSwiftFacade<CSSCalcSwiftSerializer>);

void CSSCalcSwiftSerializer::appendLatin1([[clang::noescape]] std::span<const uint8_t> characters)
{
    static_cast<CSSCalc::SwiftSerializerState&>(*this).builder.append(byteCast<Latin1Character>(characters));
}

void CSSCalcSwiftSerializer::appendNumber(double value, uint16_t unit)
{
    auto& state = static_cast<CSSCalc::SwiftSerializerState&>(*this);
    CSS::serializationForCSS(state.builder, state.context, CSS::SerializableNumber { value, unitTypeString(static_cast<CSSUnitType>(unit)) });
}

void CSSCalcSwiftSerializer::appendValueIDName(uint16_t valueID)
{
    RELEASE_ASSERT(valueID < numCSSValueKeywords);
    static_cast<CSSCalc::SwiftSerializerState&>(*this).builder.append(nameLiteralForSerialization(static_cast<CSSValueID>(valueID)));
}

void CSSCalcSwiftSerializer::appendPayload(uint32_t payload)
{
    auto& state = static_cast<CSSCalc::SwiftSerializerState&>(*this);
    WTF::switchOn(state.storage.payloads[payload],
        [&](const CSSCalc::RandomSharingAuto&) { },
        [&](const CSSCalc::RandomSharingKey& key) {
            if (key.name)
                CSS::serializationForCSS(state.builder, state.context, *key.name);
        },
        [&](const auto& value) { CSS::serializationForCSS(state.builder, state.context, value); });
}

CSSCalcSwiftRandomSharing CSSCalcSwiftSerializer::randomSharing(uint32_t payload)
{
    return WTF::switchOn(static_cast<CSSCalc::SwiftSerializerState&>(*this).storage.payloads[payload],
        [](const CSSCalc::RandomSharingAuto&) -> CSSCalcSwiftRandomSharing { return { 0, 0, 0, 0 }; },
        [](const CSSCalc::RandomSharingKey& key) -> CSSCalcSwiftRandomSharing {
            return { 1, key.name.has_value(), key.elementScoped.has_value(), static_cast<uint8_t>(key.propertyScoped ? key.propertyScoped->index() + 1 : 0) };
        },
        [](const CSS::Number<CSS::ClosedUnitRange>&) -> CSSCalcSwiftRandomSharing { return { 2, 0, 0, 0 }; },
        [](const auto&) -> CSSCalcSwiftRandomSharing { RELEASE_ASSERT_NOT_REACHED(); });
}

} // namespace WebCore
