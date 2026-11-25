/*
 * Copyright (C) 2010 Google Inc. All rights reserved.
 * Copyright (C) 2014-2026 Apple Inc. All rights reserved.
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
#include "BlobResourceHandleBase.h"

#include "AsyncFileStream.h"
#include "FileStream.h"
#include "HTTPHeaderNames.h"
#include "ResourceRequest.h"
#include "ResourceResponse.h"
#include <algorithm>
#include <wtf/MainThread.h>
#include <wtf/WeakPtr.h>

namespace WebCore {

static constexpr int httpOK = 200;
static constexpr int httpPartialContent = 206;
static constexpr auto httpOKText = "OK"_s;
static constexpr auto httpPartialContentText = "Partial Content"_s;

BlobResourceHandleBase::BlobResourceHandleBase(bool async, RefPtr<BlobData>&& blobData)
    : m_blobData(WTF::move(blobData))
    , m_buffer(Box<Vector<uint8_t>>::create())
{
    if (async)
        m_stream = makeUnique<AsyncFileStream>(*this);
    else
        m_stream = makeUnique<FileStream>();
}

BlobResourceHandleBase::~BlobResourceHandleBase() = default;

uint64_t BlobResourceHandleBase::clampReadSizeToRemaining(uint64_t requested, uint64_t totalRemaining)
{
    return std::min<uint64_t>(requested, totalRemaining);
}

void BlobResourceHandleBase::clearAsyncStream()
{
    m_stream = std::unique_ptr<AsyncFileStream>();
}

BlobData* BlobResourceHandleBase::blobData() const
{
    return m_blobData.get();
}

FileStream* BlobResourceHandleBase::syncStream() const
{
    return std::get<std::unique_ptr<FileStream>>(m_stream).get();
}

AsyncFileStream* BlobResourceHandleBase::asyncStream() const
{
    return std::get<std::unique_ptr<AsyncFileStream>>(m_stream).get();
}

void BlobResourceHandleBase::start()
{
    if (!async()) {
        doStart();
        return;
    }

    // Finish this async call quickly and return.
    callOnMainThread([protectedThis = Ref { *this }]() mutable {
        protectedThis->doStart();
    });
}

void BlobResourceHandleBase::resizeBuffer(size_t newSize)
{
    RELEASE_ASSERT(!m_isWritingIntoBuffer);
    m_buffer->resize(newSize);
}

void BlobResourceHandleBase::readFileAsync(const BlobDataItem& item, BlobDataFileReference& file)
{
    ASSERT(isMainThread());

    if (m_isFileOpen) {
        m_isWritingIntoBuffer = true;
        asyncStream()->read(m_buffer, [weakThis = WeakPtr { *this }](int bytesRead) {
            RefPtr protectedThis = weakThis;
            if (!protectedThis)
                return;
            protectedThis->m_isWritingIntoBuffer = false;
            protectedThis->didRead(bytesRead);
        });
        return;
    }

    auto bytesToRead = clampReadSizeToRemaining(lengthOfItemBeingRead() - m_currentItemReadSize, m_totalRemainingSize);
    asyncStream()->openForRead(file.path(), item.offset() + m_currentItemReadSize, bytesToRead);
    m_isFileOpen = true;
    m_currentItemReadSize = 0;
}

void BlobResourceHandleBase::closeAsyncStream()
{
    asyncStream()->close();
}

void BlobResourceHandleBase::getAsyncFileSize(BlobDataFileReference& file)
{
    asyncStream()->getSize(file.path(), file.expectedModificationTime());
}

long long BlobResourceHandleBase::getSyncFileSize(BlobDataFileReference& file)
{
    return syncStream()->getSize(file.path(), file.expectedModificationTime());
}

bool BlobResourceHandleBase::firstRequestIsGET() const
{
    return equalLettersIgnoringASCIICase(firstRequest().httpMethod(), "get"_s);
}

String BlobResourceHandleBase::firstRequestRangeHeader() const
{
    return firstRequest().httpHeaderField(HTTPHeaderName::Range);
}

bool BlobResourceHandleBase::notifyClientOfSegmentData(const DataSegment& data, uint64_t offset, uint64_t size)
{
    auto span = data.span().subspan(offset, size);
    return span.empty() || didReceiveData(span);
}

bool BlobResourceHandleBase::notifyClientOfBufferData(size_t size)
{
    auto span = m_buffer->subspan(0, size);
    return span.empty() || didReceiveData(span);
}

void BlobResourceHandleBase::dispatchDidReceiveResponse()
{
    ASSERT(isMainThread());

    if (shouldAbortDispatchDidReceiveResponse())
        return;

    ResourceResponse response(URL { firstRequest().url() }, extractMIMETypeFromMediaType(m_blobData->contentType()), m_totalRemainingSize, String());
    response.setHTTPStatusCode(m_isRangeRequest ? httpPartialContent : httpOK);
    response.setHTTPStatusText(m_isRangeRequest ? httpPartialContentText : httpOKText);

    response.setHTTPHeaderField(HTTPHeaderName::ContentType, m_blobData->contentType());
    response.setTextEncodingName(extractCharsetFromMediaType(m_blobData->contentType()).toString());
    response.setHTTPHeaderField(HTTPHeaderName::ContentLength, String::number(m_totalRemainingSize));
    addPolicyContainerHeaders(response, m_blobData->policyContainer());

    if (m_isRangeRequest)
        response.setHTTPHeaderField(HTTPHeaderName::ContentRange, ParsedContentRange(*m_range->start, *m_range->end, m_totalSize).headerValue());

    // FIXME: If a resource identified with a blob: URL is a File object, user agents must use that file's name attribute,
    // as if the response had a Content-Disposition header with the filename parameter set to the File's name attribute.
    // Notably, this will affect a name suggested in "File Save As".

    didReceiveResponse(WTF::move(response));
}

} // namespace WebCore
