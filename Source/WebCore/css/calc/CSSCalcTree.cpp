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

#include "config.h"
#include "CSSCalcTree.h"

#include "CSSCalcTree+Serialization.h"
#include "CSSSerializationContext.h"
#include "CSSUnits.h"
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>

namespace WebCore {
namespace CSSCalc {

TextStream& operator<<(TextStream& ts, Tree tree)
{
    return ts << "CSSCalc::Tree [ "_s << serializationForCSS(tree, { .range = CSS::All, .serializationContext = CSS::defaultSerializationContext() }) << " ]"_s;
}

bool TreeStorage::operator==(const TreeStorage& other) const
{
    if (nodes.size() != other.nodes.size())
        return false;
    for (size_t i = 0; i < nodes.size(); ++i) {
        auto& a = nodes[i];
        auto& b = other.nodes[i];
        if (a.kind != b.kind || a.flags != b.flags || a.unit != b.unit || a.subtreeSize != b.subtreeSize || a.childCount != b.childCount || a.typeBits != b.typeBits || a.value != b.value)
            return false;
        if ((a.payload == UINT32_MAX) != (b.payload == UINT32_MAX))
            return false;
        if (a.payload != UINT32_MAX && !(payloads[a.payload] == other.payloads[b.payload]))
            return false;
    }
    return true;
}

} // namespace CSSCalc
} // namespace WebCore
