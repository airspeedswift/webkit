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

#if ENABLE(WEB_AUTHN)

#include <WebCore/CBORValue.h>
#include <wtf/StdLibExtras.h>
#include <array>
#include <wtf/Vector.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

// The deterministic inputs of WebAuthnBench.cpp. Every input is a function of fixed bytes or of a fixed seed, so a
// checksum over the outputs is the same on every run.

namespace TestWebKitAPI {

namespace WebAuthnBenchInputs {

// FNV-1a over everything a test observes, in a fixed order.
class Hash {
public:
    void add(uint64_t value)
    {
        for (unsigned i = 0; i < 8; ++i) {
            m_state ^= (value >> (i * 8)) & 0xff;
            m_state *= 0x100000001b3ULL;
        }
    }

    void add(std::span<const uint8_t> bytes)
    {
        add(static_cast<uint64_t>(bytes.size()));
        for (uint8_t byte : bytes) {
            m_state ^= byte;
            m_state *= 0x100000001b3ULL;
        }
    }

    void add(const String& string)
    {
        add(static_cast<uint64_t>(string.length()));
        for (unsigned i = 0; i < string.length(); ++i)
            add(static_cast<uint64_t>(string[i]));
    }

    void addFlag(bool flag) { add(static_cast<uint64_t>(flag ? 1 : 0)); }

    uint64_t value() const { return m_state; }

private:
    uint64_t m_state { 0xcbf29ce484222325ULL };
};

class Random {
public:
    explicit Random(uint64_t seed)
        : m_state(seed)
    {
    }

    unsigned below(unsigned bound)
    {
        m_state = m_state * 6364136223846793005ULL + 1442695040888963407ULL;
        return static_cast<unsigned>(m_state >> 33) % bound;
    }

    uint8_t byte() { return static_cast<uint8_t>(below(256)); }

private:
    uint64_t m_state;
};

inline Vector<uint8_t> toVector(std::span<const uint8_t> span)
{
    Vector<uint8_t> result;
    result.append(span);
    return result;
}

inline Vector<uint8_t> patternBytes(size_t size, uint64_t seed)
{
    Random random(seed);
    Vector<uint8_t> result;
    result.reserveInitialCapacity(size);
    for (size_t i = 0; i < size; ++i)
        result.append(random.byte());
    return result;
}

// The whole tree: type, then the payload, in the map's order.
inline void hashValue(Hash& hash, const cbor::CBORValue& value)
{
    using Type = cbor::CBORValue::Type;
    hash.add(static_cast<uint64_t>(static_cast<int>(value.type()) + 2));
    switch (value.type()) {
    case Type::Unsigned:
    case Type::Negative:
        hash.add(static_cast<uint64_t>(value.getInteger()));
        break;
    case Type::ByteString:
        hash.add(value.getByteString().span());
        break;
    case Type::String:
        hash.add(value.getString());
        break;
    case Type::Array:
        hash.add(static_cast<uint64_t>(value.getArray().size()));
        for (auto& element : value.getArray())
            hashValue(hash, element);
        break;
    case Type::Map:
        hash.add(static_cast<uint64_t>(value.getMap().size()));
        for (auto& entry : value.getMap()) {
            hashValue(hash, entry.first);
            hashValue(hash, entry.second);
        }
        break;
    case Type::SimpleValue:
        hash.add(static_cast<uint64_t>(value.getSimpleValue()));
        break;
    case Type::None:
        break;
    }
}

// A CTAP makeCredential-shaped value: integer keys, nested maps and arrays, strings, byte strings.
inline cbor::CBORValue makeMakeCredentialValue()
{
    using namespace cbor;
    CBORValue::MapValue rp;
    rp[CBORValue("id")] = CBORValue("example.com");
    rp[CBORValue("name")] = CBORValue("Example Relying Party");

    CBORValue::MapValue user;
    user[CBORValue("id")] = CBORValue(patternBytes(32, 1));
    user[CBORValue("name")] = CBORValue("john.p.smith@example.com");
    user[CBORValue("displayName")] = CBORValue("John P. Smith");
    user[CBORValue("icon")] = CBORValue("https://pics.example.com/00/p/aBjjjpqPb.png");

    CBORValue::ArrayValue parameters;
    for (int64_t algorithm : { -7, -257, -8, -35, -36 }) {
        CBORValue::MapValue parameter;
        parameter[CBORValue("alg")] = CBORValue(algorithm);
        parameter[CBORValue("type")] = CBORValue("public-key");
        parameters.append(CBORValue(WTF::move(parameter)));
    }

    CBORValue::ArrayValue excluded;
    for (unsigned i = 0; i < 3; ++i) {
        CBORValue::MapValue descriptor;
        descriptor[CBORValue("id")] = CBORValue(patternBytes(64, 10 + i));
        descriptor[CBORValue("type")] = CBORValue("public-key");
        excluded.append(CBORValue(WTF::move(descriptor)));
    }

    CBORValue::MapValue options;
    options[CBORValue("rk")] = CBORValue(true);
    options[CBORValue("uv")] = CBORValue(false);

    CBORValue::MapValue extensions;
    extensions[CBORValue("hmac-secret")] = CBORValue(true);
    extensions[CBORValue("credBlob")] = CBORValue(patternBytes(32, 20));
    extensions[CBORValue("largeBlobKey")] = CBORValue(true);

    CBORValue::MapValue request;
    request[CBORValue(1)] = CBORValue(patternBytes(32, 2));
    request[CBORValue(2)] = CBORValue(WTF::move(rp));
    request[CBORValue(3)] = CBORValue(WTF::move(user));
    request[CBORValue(4)] = CBORValue(WTF::move(parameters));
    request[CBORValue(5)] = CBORValue(WTF::move(excluded));
    request[CBORValue(6)] = CBORValue(WTF::move(extensions));
    request[CBORValue(7)] = CBORValue(WTF::move(options));
    request[CBORValue(8)] = CBORValue(patternBytes(16, 3));
    request[CBORValue(9)] = CBORValue(2);
    return CBORValue(WTF::move(request));
}

// Every integer width, both signs, and every length class of a byte string, string, array and map.
inline cbor::CBORValue makeScalarsValue()
{
    using namespace cbor;
    CBORValue::ArrayValue values;
    for (int64_t value : { int64_t(0), int64_t(1), int64_t(23), int64_t(24), int64_t(255), int64_t(256), int64_t(65535), int64_t(65536), int64_t(0xffffffffLL), int64_t(0x100000000LL), int64_t(0x7fffffffffffffffLL) }) {
        values.append(CBORValue(value));
        values.append(CBORValue(-1 - value));
    }
    for (size_t length : { size_t(0), size_t(1), size_t(23), size_t(24), size_t(255), size_t(256), size_t(65535), size_t(65536) }) {
        values.append(CBORValue(patternBytes(length, 100 + length)));
        StringBuilder builder;
        for (size_t i = 0; i < length; ++i)
            builder.append(static_cast<char>('a' + (i % 26)));
        values.append(CBORValue(builder.toString()));
    }
    for (size_t length : { size_t(0), size_t(1), size_t(23), size_t(24), size_t(256) }) {
        CBORValue::ArrayValue array;
        for (size_t i = 0; i < length; ++i)
            array.append(CBORValue(static_cast<int64_t>(i)));
        values.append(CBORValue(WTF::move(array)));
        CBORValue::MapValue map;
        for (size_t i = 0; i < length; ++i)
            map[CBORValue(static_cast<int64_t>(i))] = CBORValue(static_cast<int64_t>(-1 - static_cast<int64_t>(i)));
        values.append(CBORValue(WTF::move(map)));
    }
    values.append(CBORValue(true));
    values.append(CBORValue(false));
    values.append(CBORValue(CBORValue::SimpleValue::NullValue));
    values.append(CBORValue(CBORValue::SimpleValue::Undefined));
    // Strings that need the UTF-8 encoder: two-, three- and four-byte sequences.
    static constexpr std::array<char16_t, 4> wide { 0x00E9, 0x20AC, 0xD83D, 0xDD11 };
    values.append(CBORValue(String(std::span<const char16_t> { wide })));
    // Maps whose keys are of both types, to hit the CTAP ordering.
    CBORValue::MapValue mixed;
    mixed[CBORValue("aa")] = CBORValue(1);
    mixed[CBORValue("b")] = CBORValue(2);
    mixed[CBORValue(-1)] = CBORValue(3);
    mixed[CBORValue(10)] = CBORValue(4);
    mixed[CBORValue(1)] = CBORValue(5);
    mixed[CBORValue("")] = CBORValue(6);
    values.append(CBORValue(WTF::move(mixed)));
    return CBORValue(WTF::move(values));
}

// Nesting: an array of arrays, depth levels deep.
inline cbor::CBORValue makeNestedArray(unsigned depth)
{
    using namespace cbor;
    CBORValue value(CBORValue::ArrayValue { });
    for (unsigned i = 0; i < depth; ++i) {
        CBORValue::ArrayValue array;
        array.append(WTF::move(value));
        value = CBORValue(WTF::move(array));
    }
    return value;
}

// A CBOR array nested depth levels deep, as bytes: 0x81 depth times, then 0x80.
inline Vector<uint8_t> nestedArrayBytes(unsigned depth)
{
    Vector<uint8_t> bytes;
    for (unsigned i = 0; i < depth; ++i)
        bytes.append(0x81);
    bytes.append(0x80);
    return bytes;
}

} // namespace WebAuthnBenchInputs

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUTHN)
