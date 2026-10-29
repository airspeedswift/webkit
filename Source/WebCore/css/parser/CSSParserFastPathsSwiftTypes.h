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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <WebCore/CSSUnits.h>
#include <WebCore/CSSValueKeywords.h>
#include <WebCore/CSSValueList.h>
#include <cstdint>
#include <span>
#include <wtf/ForbidHeapAllocation.h>

namespace WebCore {

// The input types of the fast paths in CSSParserFastPathsSwift.swift. They read 8-bit input as bytes, so
// CSSParserFastPaths passes its Latin1Character spans through byteCast.
using CSSFastPathSpan8 = std::span<const uint8_t>;
using CSSFastPathSpan16 = std::span<const char16_t>;

// A number and its unit: a length or an opacity the fast paths parsed, or a number charactersToDouble parsed for
// them. ok is false when there is none.
struct CSSFastPathNumber {
    double value;
    CSSUnitType unit;
    bool ok;
};

// charactersToDouble over the whole of characters, for a number the fast paths do not convert themselves.
CSSFastPathNumber cssFastPathParseNumber8([[clang::noescape]] std::span<const uint8_t> characters);
CSSFastPathNumber cssFastPathParseNumber16([[clang::noescape]] std::span<const char16_t> characters);

// The named color whose lowercase name is name, as a PackedColor::ARGB, or -1.
int64_t cssFastPathFindNamedColor([[clang::noescape]] std::span<const uint8_t> name);

// Builds the transform list parseSimpleTransform returns, one call per function: the CSSValueID name, and arguments
// values[i] in the CSSUnitType units[i]. Only parseSimpleTransform makes one, on its stack, and only the scan it
// calls reaches it.
class __attribute__((swift_attr("~Sendable"))) CSSFastPathTransformSink {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    __attribute__((availability(swift, unavailable))) CSSFastPathTransformSink() = default;
    // Movable but not copyable, so that Swift imports it as a noncopyable type.
    CSSFastPathTransformSink(CSSFastPathTransformSink&&) = default;
    ~CSSFastPathTransformSink() { }

    void append(uint16_t name, [[clang::noescape]] std::span<const double> values, [[clang::noescape]] std::span<const uint8_t> units);
    __attribute__((availability(swift, unavailable))) CSSValueListBuilder takeFunctions() { return WTF::move(m_functions); }

private:
    CSSValueListBuilder m_functions;
};

} // namespace WebCore
