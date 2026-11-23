/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 * Copyright (C) 2026 Igalia S.L. All rights reserved.
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

#include "config.h"
#include "NetworkCacheCompressionDictionaryEntry.h"

#include <WebCore/ExceptionOr.h>
#include <WebCore/URLPattern.h>
#include <WebCore/URLPatternOptions.h>
#include <wtf/text/StringBuilder.h>

namespace WebCore {
// Created by binding generator.
String convertEnumerationToString(FetchOptions::Destination);
}

namespace WebKit::NetworkCache {

std::optional<WebCore::FetchOptions::Destination> parseFetchDestination(const String& string)
{
    std::optional<WebCore::FetchOptions::Destination> result;
    WTF::EnumTraitsForPersistence<WebCore::FetchOptions::Destination>::values::forEach([&](auto destination) {
        if (!result && WebCore::convertEnumerationToString(destination) == string)
            result = destination;
    });
    return result;
}

DictionaryPattern::DictionaryPattern() = default;
DictionaryPattern::DictionaryPattern(RefPtr<WebCore::URLPattern>&& pattern)
    : m_pattern(WTF::move(pattern))
{
}
DictionaryPattern::DictionaryPattern(const DictionaryPattern&) = default;
DictionaryPattern& DictionaryPattern::operator=(const DictionaryPattern&) = default;
DictionaryPattern::~DictionaryPattern() = default;

DictionaryPattern makeDictionaryPattern(const String& match, const String& baseURL)
{
    auto patternOrException = WebCore::URLPattern::createWithoutRegExpSupport(match, String { baseURL }, { });
    if (patternOrException.hasException())
        return { };
    return DictionaryPattern { patternOrException.releaseReturnValue().ptr() };
}

bool DictionaryPattern::test(const URL& url) const
{
    return protect(m_pattern)->testWithoutRegExp(url);
}

String dumpMatchDestinations(const CompressionDictionaryDestinationSet& matchDest)
{
    StringBuilder json;
    bool firstDestination = true;
    WTF::EnumTraitsForPersistence<WebCore::FetchOptions::Destination>::values::forEach([&](auto destination) {
        if (!matchDest.contains(destination))
            return;
        json.append(std::exchange(firstDestination, false) ? ""_s : ",\n"_s, "    "_s);
        json.appendQuotedJSONString(WebCore::convertEnumerationToString(destination));
    });
    return json.toString();
}

} // namespace WebKit::NetworkCache
