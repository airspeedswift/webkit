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

#pragma once

#include "CSSCalcSymbolTable.h"
#include "CSSPrimitiveNumericRange.h"
#include "CSSToLengthConversionData.h"

#include "CSSCalcSwiftTypes.h"
#include <wtf/ForbidHeapAllocation.h>

namespace WebCore {

namespace CSS {
enum class Category : uint8_t;
}

namespace CSSCalc {

struct Child;
struct Tree;

// https://drafts.csswg.org/css-values-4/#calc-simplification

struct SimplificationOptions {
    // `category` represents the context in which the simplification is taking place.
    CSS::Category category;

    // `range` represents the allowed numeric range for the calculated result.
    CSS::Range range;

    // `conversionData` contains information needed to convert length units into their canonical forms.
    std::optional<CSSToLengthConversionData> conversionData;

    // `symbolTable` contains information needed to convert unresolved symbols into Numeric values.
    CSSCalcSymbolTable symbolTable;

    // `allowZeroValueLengthRemovalFromSum` allows removal of 0 value lengths (px, em, etc.) from Sum operations.
    bool allowZeroValueLengthRemovalFromSum = false;
};


// MARK: Can Simplify

bool canSimplify(const Tree&, const SimplificationOptions&);

// MARK: Copy & Simplify

Tree copyAndSimplify(const Tree&, const SimplificationOptions&);

struct TreeStorage;

// The state behind CSSCalcSwiftResolver: what simplification and evaluation read besides the tree, whose payloads
// are those of `storage`.
class SwiftResolverState final : public CSSCalcSwiftResolver {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    SwiftResolverState(const std::optional<CSSToLengthConversionData>& conversionData, const CSSCalcSymbolTable& symbolTable, const TreeStorage& storage)
        : conversionData(conversionData)
        , symbolTable(symbolTable)
        , storage(storage)
    {
    }

    const std::optional<CSSToLengthConversionData>& conversionData;
    const CSSCalcSymbolTable& symbolTable;
    const TreeStorage& storage;
};

// The state behind CSSCalcSwiftOutput: the tree it writes.
class SwiftOutputState final : public CSSCalcSwiftOutput {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    explicit SwiftOutputState(TreeStorage& storage)
        : storage(storage)
    {
    }

    TreeStorage& storage;
};

CSSCalcSwiftSimplificationOptions swiftSimplificationOptions(const SimplificationOptions&);

} // namespace CSSCalc
} // namespace WebCore
