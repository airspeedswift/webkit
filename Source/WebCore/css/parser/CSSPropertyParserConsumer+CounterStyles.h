/*
 * Copyright (C) 2016-2022 Apple Inc. All rights reserved.
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

#include "CSSParserMode.h"
#include <wtf/Forward.h>

namespace WebCore {

class CSSParserTokenRange;
class CSSValue;
enum class CSSValueID : uint16_t;

namespace CSS {
struct CounterStyle;
struct PropertyParserState;
}

namespace CSSPropertyParserHelpers {

// https://drafts.csswg.org/css-counter-styles-3/

NODELETE bool isPredefinedCounterStyle(CSSValueID);

// MARK: @counter-style consumer
AtomString consumeCounterStyleNameInPrelude(CSSParserTokenRange&, CSSParserMode = CSSParserMode::HTMLStandardMode);

} // namespace CSSPropertyParserHelpers

struct CSSPropertyConsumerSwiftValue;

// The counter style of a counter() or counters() Swift consumed: decimal if `style` is UINT32_MAX, else the identifier
// or the symbols() at the token `style`, with the <symbols-type> at the token `system` (none for UINT32_MAX) and the
// strings among the tokens [start, end); none if that is not a <symbols-type>.
std::optional<CSS::CounterStyle> makeCounterStyleForSwift(const CSSPropertyConsumerSwiftValue&, uint32_t style, uint32_t system, uint32_t start, uint32_t end);
} // namespace WebCore
