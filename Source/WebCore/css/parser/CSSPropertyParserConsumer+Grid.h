/*
 * Copyright (C) 2024 Apple Inc. All rights reserved.
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

#pragma once

#include <wtf/Forward.h>

namespace WebCore {

class CSSParserTokenRange;
class CSSValue;

enum class CSSValueID : uint16_t;

namespace CSS {
struct CustomIdent;
struct GridAutoFlow;
struct GridLine;
struct GridLineNames;
struct GridNamedAreaMap;
struct GridTemplateAreas;
struct GridTemplateList;
struct GridTrackList;
struct GridTrackSize;
struct GridTrackSizes;
struct PropertyParserState;
using GridNamedAreaMapRow = Vector<AtomString, 8>;
}

namespace CSSPropertyParserHelpers {

// https://drafts.csswg.org/css-grid/

// <'grid-template-columns'/'grid-template-rows'> = none | <track-list> | <auto-track-list> | subgrid <line-name-list>?
// https://drafts.csswg.org/css-grid/#propdef-grid-template-columns
// https://drafts.csswg.org/css-grid/#propdef-grid-template-rows
RefPtr<CSSValue> consumeGridTemplateList(CSSParserTokenRange&, CSS::PropertyParserState&);

// <'grid-auto-columns'>/<'grid-auto-rows'> = <track-size>+
// https://drafts.csswg.org/css-grid/#propdef-grid-auto-columns
// https://drafts.csswg.org/css-grid/#propdef-grid-auto-rows
RefPtr<CSSValue> consumeGridTrackSizes(CSSParserTokenRange&, CSS::PropertyParserState&);

// MARK: - Shorthand Parser Utilities

} // namespace CSSPropertyParserHelpers
} // namespace WebCore
