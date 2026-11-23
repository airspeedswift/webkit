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

#include "NetworkCacheData.h"
#include "NetworkCacheEntry.h"
#include "NetworkCacheKey.h"
#include <WebCore/HTTPHeaderMap.h>
#include <WebCore/ResourceLoadPriority.h>
#include <WebCore/ResourceResponse.h>
#include <wtf/SHA1.h>
#include <wtf/URL.h>
#include <wtf/WallTime.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

// What the network cache's Swift gives its test support (NetworkCacheTestSupport.cpp). NetworkCacheTestSupport.h is the
// tests' C interface, which no WebKit type reaches.

namespace WebKit::NetworkCache {

// The entry and a subresource info as the test support prints them. C++, since the text is WTF's makeString and
// StringBuilder over WebCore types, templates Swift cannot spell.
namespace TestSupport {
String describeEntry(const WebCore::ResourceResponse&, WallTime timeStamp, bool needsValidation, bool isPrivateRelayed, const OptionalRequest& redirectRequest, const Key&, const HeaderPairs& varyingRequestHeaders);
void describeSubresource(StringBuilder&, const Key&, WallTime lastSeen, WallTime firstSeen, bool isTransient, bool isSameSite, bool isAppInitiated, const URL& firstPartyForCookies, const WebCore::HTTPHeaderMap& requestHeaders, WebCore::ResourceLoadPriority);
// StringBuilder::toString() returns a const String&, which Swift imports as a pointer.
inline String stringFromBuilder(StringBuilder& builder) { return builder.toString(); }
} // namespace TestSupport

// NetworkCacheStorage.testBlobAddGet's result (NetworkCacheTestSupport).
struct TestBlobResult {
    Data data;
    SHA1::Digest hash { };
    unsigned shareCount { 0 };
};

} // namespace WebKit::NetworkCache
