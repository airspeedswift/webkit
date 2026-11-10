/*
 * Copyright (C) 2024-2026 Samuel Weinig <sam@webkit.org>
 * Copyright (C) 2024 Apple Inc. All rights reserved.
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

#include <WebCore/CSSCalcRandomSharing.h>
#include <WebCore/CSSCalcType.h>
#include <WebCore/CSSCustomIdent.h>
#include <WebCore/CSSPrimitiveNumeric.h>
#include <WebCore/CSSPrimitiveNumericRange.h>
#include <WebCore/CSSUnits.h>
#include <WebCore/CSSValueKeywords.h>
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/Vector.h>

#include <WebCore/CSSCalcSwiftTypes.h>

namespace WebCore {

namespace Style {
enum class AnchorSizeDimension : uint8_t;
}

enum class CSSUnitType : uint8_t;

namespace CSSCalc {

enum class Stage : bool { Specified, Computed };

// A tree as records (CSSCalcSwiftTypes.h), and the values they name by index: anchor names, random() sharing (auto,
// a key, or a fixed value) and calc-mix() weights.
using Payload = Variant<CSS::CustomIdent, RandomSharingAuto, RandomSharingKey, CSS::Number<CSS::ClosedUnitRange>, CSS::Percentage<CSS::ClosedPercentageRange>>;
struct TreeStorage {
    Vector<CSSCalcNodeRecord, 4> nodes;
    Vector<Payload> payloads;

    // Compares the records, and for each record the payload it names rather than the payload's index.
    WEBCORE_EXPORT bool operator==(const TreeStorage&) const;
};

struct Tree {
    TreeStorage storage;
    bool rootIsPercentage() const { return storage.nodes[0].kind == static_cast<uint8_t>(CSSCalcNodeKind::Percentage); }
    Type type;
    Stage stage;

    // `requiresConversionData` is used both to both indicate whether eager evaluation of the tree (at parse time) is possible or not and to trigger a warning in `UnevaluatedCalcBase::evaluateDeprecated` that the evaluation results will be incorrect.
    bool requiresConversionData = false;

    bool operator==(const Tree&) const = default;
};

// Random Function - https://drafts.csswg.org/css-values-5/#random
struct Random {

    // <random-key> = auto | <random-cache-key> | fixed <number [0,1]>
    // <random-cache-key> = <dashed-ident> || element-scoped || [ property-scoped | property-index-scoped ]
    // NOTE: <random-ua-ident> is intentionally not yet supported (follow-up).
    using SharingAuto = RandomSharingAuto;
    using Key = RandomSharingKey;
    struct SharingFixed {
        CSS::Number<CSS::ClosedUnitRange> value;

        bool operator==(const SharingFixed&) const = default;
    };
    using Sharing = Variant<SharingAuto, Key, SharingFixed>;

};

// CalcMix Function - https://drafts.csswg.org/css-values-5/#calc-mix

struct CalcMix {

    struct Item {
        using Weight = CSS::Percentage<CSS::ClosedPercentageRange>;

    };

};

// MARK: TextStream

TextStream& operator<<(TextStream&, Tree);

} // namespace CSSCalc
} // namespace WebCore
