/*
 * Copyright (C) 2014-2015 Apple Inc. All rights reserved.
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
#include "NetworkCacheKey.h"

#include "NetworkCacheCoders.h"
#include <wtf/persistence/PersistentDecoder.h>
#include <wtf/persistence/PersistentEncoder.h>

namespace WebKit {
namespace NetworkCache {

// NetworkCacheKey.swift spells a hash as 40 hexadecimal digits, and its addSalt copies 8 bytes.
static_assert(std::tuple_size_v<Key::HashType> == 20);
static_assert(std::tuple_size_v<Salt> == 8);

Key::Key(const Key& o)
    : m_partition(o.m_partition.isolatedCopy())
    , m_type(o.m_type.isolatedCopy())
    , m_identifier(o.m_identifier.isolatedCopy())
    , m_range(o.m_range.isolatedCopy())
    , m_hash(o.m_hash)
    , m_partitionHash(o.m_partitionHash)
{
}

Key::Key(const String& partition, const String& type, const String& range, const String& identifier, const Salt& salt, IncludesCredentials includesCredentials)
    : Key(computeKey(partition, type, identifier, range, salt, includesCredentials))
{
}

Key::Key(WTF::HashTableDeletedValueType)
    : m_identifier(WTF::HashTableDeletedValue)
{
}

Key::Key(const DataKey& dataKey, const Salt& salt)
    : m_partition(dataKey.partition)
    , m_type(dataKey.type)
    , m_identifier(hashAsString(dataKey.identifier))
    , m_hash(computeHash(m_partition, m_type, m_identifier, m_range, salt, IncludesCredentials::Yes))
    , m_partitionHash(partitionToPartitionHash(m_partition, salt))
{
}

Key& Key::operator=(const Key& other)
{
    m_partition = other.m_partition.isolatedCopy();
    m_type = other.m_type.isolatedCopy();
    m_identifier = other.m_identifier.isolatedCopy();
    m_range = other.m_range.isolatedCopy();
    m_hash = other.m_hash;
    m_partitionHash = other.m_partitionHash;
    return *this;
}

bool Key::operator==(const Key& other) const
{
    return m_hash == other.m_hash && m_partition == other.m_partition && m_type == other.m_type && m_identifier == other.m_identifier && m_range == other.m_range;
}

}
}
