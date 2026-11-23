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

#pragma once

#include "NetworkCacheKey.h"
#include <WebCore/FetchOptions.h>
#include <WebCore/SharedBuffer.h>
#include <array>
#include <optional>
#include <pal/crypto/CryptoDigest.h>
#include <wtf/RefPtr.h>
#include <wtf/StdLibExtras.h>
#include <wtf/URL.h>
#include <wtf/WallTime.h>
#include <wtf/text/WTFString.h>

namespace WebCore {
class URLPattern;
}

namespace WebKit::NetworkCache {

// A dictionary registered by Use-As-Dictionary, stored beside the regular cache entry for the
// same URL (NetworkCacheCompressionDictionaryEntry.swift). https://www.rfc-editor.org/rfc/rfc9842#name-use-as-dictionary

inline constexpr size_t compressionDictionaryHashSize = 32;
using CompressionDictionaryHash = std::array<uint8_t, compressionDictionaryHashSize>;

// FetchOptions::Destination values are not powers of two, so OptionSet cannot hold them.
class CompressionDictionaryDestinationSet {
public:
    constexpr CompressionDictionaryDestinationSet() = default;
    static constexpr CompressionDictionaryDestinationSet fromRaw(uint32_t bits) { return CompressionDictionaryDestinationSet { bits }; }
    constexpr uint32_t toRaw() const { return m_bits; }

    constexpr bool isEmpty() const { return !m_bits; }
    constexpr bool contains(WebCore::FetchOptions::Destination destination) const { return m_bits & bit(destination); }
    constexpr void add(WebCore::FetchOptions::Destination destination) { m_bits |= bit(destination); }

private:
    constexpr explicit CompressionDictionaryDestinationSet(uint32_t bits)
        : m_bits(bits)
    {
    }

    static constexpr uint32_t bit(WebCore::FetchOptions::Destination destination) { return 1u << std::to_underlying(destination); }
    static_assert(std::to_underlying(WTF::EnumTraitsForPersistence<WebCore::FetchOptions::Destination>::values::max) < 32);

    uint32_t m_bits { 0 };
};

struct CompressionDictionaryInfo {
    String match;
    String id;
    CompressionDictionaryDestinationSet matchDest;
    WallTime expirationTime;
};

std::optional<WebCore::FetchOptions::Destination> parseFetchDestination(const String&);

struct CompressionDictionaryMatch {
    Key key;
    CompressionDictionaryHash hash;
    String id;
};
using OptionalDictionaryMatch = std::optional<CompressionDictionaryMatch>;
inline OptionalDictionaryMatch makeDictionaryMatch(const Key& key, const CompressionDictionaryHash& hash, const String& id) { return CompressionDictionaryMatch { key, hash, id }; }

// Swift holds the pattern, and URLPattern is incomplete here (its header does not build in the Swift module): the
// copy, assignment and destruction are defined in NetworkCacheCompressionDictionaryEntry.cpp.
class DictionaryPattern {
public:
    DictionaryPattern();
    explicit DictionaryPattern(RefPtr<WebCore::URLPattern>&&);
    DictionaryPattern(const DictionaryPattern&);
    DictionaryPattern& operator=(const DictionaryPattern&);
    ~DictionaryPattern();

    bool isNull() const { return !m_pattern; }
    bool test(const URL&) const;

private:
    RefPtr<WebCore::URLPattern> m_pattern;
};
// The compression dictionary index's match pattern; null when the match does not parse.
DictionaryPattern makeDictionaryPattern(const String& match, const String& baseURL);

// The dump file's "matchDest" list of a compression dictionary: its destinations' names as JSON strings, in the order
// they persist.
String dumpMatchDestinations(const CompressionDictionaryDestinationSet&);

inline bool dictionaryHashEquals(const CompressionDictionaryHash& a, const CompressionDictionaryHash& b) { return a == b; }

inline CompressionDictionaryHash networkCacheSHA256(const RefPtr<WebCore::SharedBuffer>& buffer)
{
    auto digest = PAL::Crypto::CryptoDigest::create(PAL::Crypto::CryptoDigest::Algorithm::SHA_256);
    if (buffer)
        digest->addBytes(buffer->span());
    CompressionDictionaryHash hash { };
    memcpySpan(std::span { hash }, digest->computeHash().span());
    return hash;
}

} // namespace WebKit::NetworkCache
