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

// <'grid-template-areas'> = none | <string>+
// https://drafts.csswg.org/css-grid/#propdef-grid-template-areas
#if !USE_SWIFT_CSS_PROPERTY_CONSUMERS_4
std::optional<CSS::GridTemplateAreas> consumeUnresolvedGridTemplateAreas(CSSParserTokenRange&, CSS::PropertyParserState&);
RefPtr<CSSValue> consumeGridTemplateAreas(CSSParserTokenRange&, CSS::PropertyParserState&);
#endif

// <'grid-row-start'>/<'grid-column-start'>/<'grid-row-end'>/<'grid-column-end'> = <grid-line>
// https://drafts.csswg.org/css-grid/#propdef-grid-row-start
// https://drafts.csswg.org/css-grid/#propdef-grid-column-start
// https://drafts.csswg.org/css-grid/#propdef-grid-row-end
// https://drafts.csswg.org/css-grid/#propdef-grid-column-end
#if !USE_SWIFT_CSS_SHORTHANDS_AND_TYPED_OM
std::optional<CSS::GridLine> consumeUnresolvedGridLine(CSSParserTokenRange&, CSS::PropertyParserState&);
#endif
#if !USE_SWIFT_CSS_PROPERTY_CONSUMERS_4
RefPtr<CSSValue> consumeGridLine(CSSParserTokenRange&, CSS::PropertyParserState&);
#endif

// <'grid-template-columns'/'grid-template-rows'> = none | <track-list> | <auto-track-list> | subgrid <line-name-list>?
// https://drafts.csswg.org/css-grid/#propdef-grid-template-columns
// https://drafts.csswg.org/css-grid/#propdef-grid-template-rows
#if !USE_SWIFT_CSS_PROPERTY_CONSUMERS_4
std::optional<CSS::GridTemplateList> consumeUnresolvedGridTemplateList(CSSParserTokenRange&, CSS::PropertyParserState&);
#endif
RefPtr<CSSValue> consumeGridTemplateList(CSSParserTokenRange&, CSS::PropertyParserState&);

// <'grid-auto-columns'>/<'grid-auto-rows'> = <track-size>+
// https://drafts.csswg.org/css-grid/#propdef-grid-auto-columns
// https://drafts.csswg.org/css-grid/#propdef-grid-auto-rows
#if !USE_SWIFT_CSS_PROPERTY_CONSUMERS_4
std::optional<CSS::GridTrackSizes> consumeUnresolvedGridTrackSizes(CSSParserTokenRange&, CSS::PropertyParserState&);
#endif
RefPtr<CSSValue> consumeGridTrackSizes(CSSParserTokenRange&, CSS::PropertyParserState&);

// <'grid-auto-flow'> = normal | [ [ row | column ] || dense ]
// FIXME: `normal` is not specified in the link below. Figure out where `normal` comes from and add link.
// https://drafts.csswg.org/css-grid/#propdef-grid-auto-flow
#if !USE_SWIFT_CSS_PROPERTY_CONSUMERS_4
std::optional<CSS::GridAutoFlow> consumeUnresolvedGridAutoFlow(CSSParserTokenRange&, CSS::PropertyParserState&);
RefPtr<CSSValue> consumeGridAutoFlow(CSSParserTokenRange&, CSS::PropertyParserState&);
#endif


// MARK: - Shorthand Parser Utilities

// Parses a single <string> token from a <'grid-template-areas'> production.
// https://drafts.csswg.org/css-grid/#valdef-grid-template-areas-string
// NOTE: Exposed for use by shorthand parsers.
#if !USE_SWIFT_CSS_SHORTHANDS_AND_TYPED_OM
std::optional<CSS::GridNamedAreaMapRow> consumeUnresolvedGridTemplateAreasRow(CSSParserTokenRange&, CSS::PropertyParserState&);
#endif

// <line-names> = '[' <custom-ident excluding=span,auto>* ']'
// https://drafts.csswg.org/css-grid/#typedef-line-names
// NOTE: Exposed for use by shorthand parsers.
#if !USE_SWIFT_CSS_SHORTHANDS_AND_TYPED_OM
std::optional<CSS::GridLineNames> consumeUnresolvedGridLineNames(CSSParserTokenRange&, CSS::PropertyParserState&);
#endif

// <track-size> = <track-breadth> | minmax( <inflexible-breadth> , <track-breadth> ) | fit-content( <length-percentage [0,∞]> )
// https://drafts.csswg.org/css-grid/#typedef-track-size
// NOTE: Exposed for use by shorthand parsers.
#if !USE_SWIFT_CSS_SHORTHANDS_AND_TYPED_OM
std::optional<CSS::GridTrackSize> consumeUnresolvedGridTrackSize(CSSParserTokenRange&, CSS::PropertyParserState&);
#endif

// <explicit-track-list> = [ <line-names>? <track-size> ]+ <line-names>?
// https://drafts.csswg.org/css-grid-2/#typedef-explicit-track-list
// NOTE: Exposed for use by shorthand parsers.
#if !USE_SWIFT_CSS_SHORTHANDS_AND_TYPED_OM
std::optional<CSS::GridTrackList> consumeUnresolvedGridExplicitTrackList(CSSParserTokenRange&, CSS::PropertyParserState&);
#endif

} // namespace CSSPropertyParserHelpers
} // namespace WebCore
