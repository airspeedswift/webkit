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
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "CSSPropertyParserConsumer+LinkParameters.h"

#include "CSSCustomPropertySyntax.h"
#include "CSSLinkParameter.h"
#include "CSSParamValue.h"
#include "CSSParserTokenRange.h"
#include "CSSPropertyParserConsumer+Ident.h"
#include "CSSPropertyParserConsumer+Primitives.h"
#include "CSSPropertyParserState.h"
#include "CSSSubstitutionParser.h"
#include "CSSTokenizer.h"
#include "CSSValueKeywords.h"
#include "CSSVariableData.h"
#include <pal/text/TextEncoding.h>
#include "CSSPropertyConsumerSwiftBuilders.h"
#include "CSSPropertyConsumerSwiftComponents.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

std::optional<CSS::ParamFunction> consumeParamFunctionRaw(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    return consumeUnresolvedWithSwift<CSS::ParamFunction>(range, state, CSSPropertyConsumerSwiftConsumer::ParamFunctionRaw);
}

RefPtr<CSSValue> consumeParamFunction(CSSParserTokenRange& range, CSS::PropertyParserState& state)
{
    if (auto parameter = consumeParamFunctionRaw(range, state))
        return CSSParamValue::create(WTF::move(*parameter));
    return nullptr;
}

Vector<CSS::ParamFunction> parseLinkParametersFromFragmentDirective(StringView fragmentDirective, const CSSParserContext& context)
{
    if (!context.cssLinkParametersEnabled || fragmentDirective.isEmpty())
        return { };

    CSS::PropertyParserState state { .context = context };

    Vector<CSS::ParamFunction> parameters;
    for (auto directive : fragmentDirective.split('&')) {
        auto decodedDirective = PAL::decodeURLEscapeSequences(directive);
        CSSTokenizer tokenizer { decodedDirective };
        auto range = tokenizer.tokenRange();

        auto parameter = consumeParamFunctionRaw(range, state);
        if (!parameter || !range.atEnd())
            continue;

        parameters.append(WTF::move(*parameter));
    }

    return parameters;
}

} // namespace CSSPropertyParserHelpers

bool setParamFunctionResult(const CSSPropertyConsumerSwiftValue& value, uint16_t keyword, uint32_t name, uint32_t start, uint32_t end)
{
    auto& state = propertyParserState(value);
    auto arguments = swiftTokenRange(value, start, end);
    std::optional<CSS::ParamSpec> spec;
    switch (static_cast<CSSValueID>(keyword)) {
    case CSSValueID::Color:
        spec = CSS::ParamSpec { CSS::Keyword::Color { } };
        break;
    case CSSValueID::AccentColor:
        spec = CSS::ParamSpec { CSS::Keyword::AccentColor { } };
        break;
    default: {
        auto ident = CSS::CustomIdent { swiftTokenRange(value, name, name + 1).peek().value().toAtomString() };
        std::optional<CSS::TypeSpecifier> type;
        if (!arguments.atEnd() && arguments.peek().type() != CommaToken) {
            auto syntax = CSSCustomPropertySyntax::consumeType(arguments);
            if (!syntax)
                return false;
            type = CSS::TypeSpecifier { WTF::move(*syntax) };
        }
        spec = CSS::ParamSpec { CSS::ParamSpec::Custom { WTF::move(ident), WTF::move(type) } };
    }
    }
    if (!CSSPropertyParserHelpers::consumeCommaIncludingWhitespace(arguments))
        return false;
    if (CSSSubstitutionParser::containsSubstitutionFunctions(arguments, state.context))
        return false;
    CSSPropertyConsumerSwiftUnresolvedResult::set(value, CSS::ParamFunction { CSS::LinkParameter { WTF::move(*spec), CSS::DeclarationValue { CSSVariableData::create(arguments) } } });
    return true;
}
} // namespace WebCore
