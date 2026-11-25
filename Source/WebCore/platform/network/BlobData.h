/*
 * Copyright (C) 2010 Google Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *     * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *     * Neither the name of Google Inc. nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <WebCore/BlobDataFileReference.h>
#include <WebCore/PolicyContainer.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/Forward.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/Variant.h>
#include <wtf/text/WTFString.h>

namespace WebCore {

class BlobDataItem {
public:
    WEBCORE_EXPORT static const long long toEndOfFile;

#if PLATFORM(COCOA)
    template<typename... F> constexpr decltype(auto) switchOn(NOESCAPE F&&... f) const
#else
    template<typename... F> constexpr decltype(auto) switchOn(F&&... f) const
#endif
    {
        auto visitor = WTF::makeVisitor(std::forward<F>(f)...);
        return WTF::switchOn(m_data,
            [&](const Ref<DataSegment>& data) {
                return visitor(data.get());
            },
            [&](const Ref<BlobDataFileReference>& file) {
                return visitor(file.get());
            }
        );
    }

    long long offset() const { return m_offset; }
    WEBCORE_EXPORT long long length() const; // Computes file length if it's not known yet.

    // For Swift, which cannot call switchOn(): the item's data or file, whichever it holds.
    DataSegment* dataSegment() const
    {
        auto* data = std::get_if<Ref<DataSegment>>(&m_data);
        return data ? data->ptr() : nullptr;
    }
    BlobDataFileReference* file() const
    {
        auto* file = std::get_if<Ref<BlobDataFileReference>>(&m_data);
        return file ? file->ptr() : nullptr;
    }

private:
    friend class BlobData;

    explicit BlobDataItem(Ref<BlobDataFileReference>&& file)
        : m_data(WTF::move(file))
        , m_offset(0)
        , m_length(toEndOfFile)
    {
    }

    BlobDataItem(Ref<DataSegment>&& data, long long offset, long long length)
        : m_data(WTF::move(data))
        , m_offset(offset)
        , m_length(length)
    {
    }

    BlobDataItem(Ref<BlobDataFileReference>&& file, long long offset, long long length)
        : m_data(WTF::move(file))
        , m_offset(offset)
        , m_length(length)
    {
    }

    Variant<Ref<DataSegment>, Ref<BlobDataFileReference>> m_data;
    long long m_offset;
    long long m_length;
};

typedef Vector<BlobDataItem> BlobDataItemList;

class SWIFT_PRIVATE_FILEID("WebCore/BlobRegistryImpl.swift") BlobData : public ThreadSafeRefCounted<BlobData, WTF::DestructionThread::Main> {
public:
    static Ref<BlobData> create(const String& contentType)
    {
        return adoptRef(*new BlobData(contentType));
    }

    const String& contentType() const LIFETIME_BOUND { return m_contentType; }

    const PolicyContainer& policyContainer() const LIFETIME_BOUND { return m_policyContainer; }
    // For Swift, which would copy the policy container to compare it.
    bool policyContainerEquals(const PolicyContainer& policyContainer) const { return m_policyContainer == policyContainer; }
    void setPolicyContainer(const PolicyContainer& policyContainer) { m_policyContainer = policyContainer; }

    const BlobDataItemList& items() const LIFETIME_BOUND { return m_items; }
    // For Swift, which imports items() as a pointer; operator[] imports as a subscript.
    size_t itemCount() const { return m_items.size(); }
    const BlobDataItem& operator[](size_t index) const LIFETIME_BOUND { return m_items[index]; }

    void replaceData(const DataSegment& oldData, Ref<DataSegment>&& newData);
    void appendData(Ref<DataSegment>&&);
    void appendFile(Ref<BlobDataFileReference>&&);

    Ref<BlobData> clone() const;

private:
    friend class BlobRegistryImpl;
    WEBCORE_EXPORT BlobData(const String& contentType);

    void appendData(Ref<DataSegment>&&, long long offset, long long length);
    void appendFile(Ref<BlobDataFileReference>&&, long long offset, long long length);

    String m_contentType;
    PolicyContainer m_policyContainer;
    BlobDataItemList m_items;
};

} // namespace WebCore
