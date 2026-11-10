/*
 * Copyright (C) 2016 The Chromium Authors. All rights reserved
 * Copyright (C) 2021 Metrological Group B.V.
 * Copyright (C) 2021 Igalia S.L.
 * Copyright (C) 2023-2024 Apple Inc. All rights reserved.
 * Copyright (C) 2024-2025 Samuel Weinig <sam@webkit.org>
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
#include "CSSPropertyParserConsumer+UnicodeRange.h"

#include "CSSParserTokenRange.h"
#include "CSSUnicodeRangeValue.h"
#include <wtf/text/ParsingUtilities.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringParsingBuffer.h>
#include "CSSPropertyConsumerSwiftTypes.h"

namespace WebCore {
namespace CSSPropertyParserHelpers {

// The largest code point of a unicode-range Swift consumes.
static_assert(UCHAR_MAX_VALUE == 0x10FFFF);

RefPtr<CSSValue> consumeUnicodeRangeToken(CSSParserTokenRange& range)
{
    auto unicodeRange = consumeUnicodeRangeWithSwift(range);
    if (!unicodeRange.ok)
        return nullptr;
    return CSSUnicodeRangeValue::create(unicodeRange.start, unicodeRange.end);
}

} // namespace CSSPropertyParserHelpers
} // namespace WebCore
