/*
 * Copyright (C) 2015 Apple Inc. All rights reserved.
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
#include "DataURLDecoder.h"

#include "ParsedContentType.h"
#include <pal/text/DecodeEscapeSequences.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RunLoop.h>
#include <wtf/URL.h>
#include <wtf/WorkQueue.h>
#include <wtf/text/Base64.h>

namespace WebCore {
namespace DataURLDecoder {

static WorkQueue& decodeQueueSingleton()
{
    static NeverDestroyed<Ref<WorkQueue>> queue(WorkQueue::create("org.webkit.DataURLDecoder"_s, WorkQueue::QOS::UserInitiated));
    return queue.get();
}

Result parseMediaType(const String& mediaType)
{
    if (std::optional<ParsedContentType> parsedContentType = ParsedContentType::create(mediaType))
        return { parsedContentType->mimeType().isolatedCopy(), parsedContentType->charset().isolatedCopy(), parsedContentType->serialize().isolatedCopy(), { } };
    return { "text/plain"_s, "US-ASCII"_s, "text/plain;charset=US-ASCII"_s, { } };
}

bool decodeBase64Data(Result& result, const String& urlString, size_t encodedDataStart, ShouldValidatePadding shouldValidatePadding)
{
    OptionSet<Base64DecodeOption> options = { Base64DecodeOption::IgnoreWhitespace };
    if (shouldValidatePadding == ShouldValidatePadding::Yes)
        options.add(Base64DecodeOption::ValidatePadding);
    auto decodedData = base64Decode(PAL::decodeURLEscapeSequences(StringView(urlString).substring(encodedDataStart)), options);
    if (!decodedData)
        return false;
    result.data = WTF::move(*decodedData);
    return true;
}

void decodePercentEncodedData(Result& result, const String& urlString, size_t encodedDataStart)
{
    result.data = PAL::decodeURLEscapeSequencesAsData(StringView(urlString).substring(encodedDataStart));
}

void decode(const URL& url, const ScheduleContext& scheduleContext, ShouldValidatePadding shouldValidatePadding, DecodeCompletionHandler&& completionHandler)
{
    ASSERT(url.protocolIsData());

    decodeQueueSingleton().dispatch([url = url.isolatedCopy(), scheduleContext, shouldValidatePadding, completionHandler = WTF::move(completionHandler)] mutable {
        auto result = decode(WTF::move(url), shouldValidatePadding);

#if USE(COCOA_EVENT_LOOP)
        auto scheduledPairs = scheduleContext.scheduledPairs;
#else
        UNUSED_VARIABLE(scheduleContext);
#endif

        auto callCompletionHandler = [result = WTF::move(result), completionHandler = WTF::move(completionHandler)] mutable {
            completionHandler(WTF::move(result));
        };

#if USE(COCOA_EVENT_LOOP)
        RunLoop::dispatch(scheduledPairs, WTF::move(callCompletionHandler));
#else
        RunLoop::mainSingleton().dispatch(WTF::move(callCompletionHandler));
#endif
    });
}

} // namespace DataURLDecoder
} // namespace WebCore
