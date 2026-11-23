/*
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

#pragma once

#include "NetworkCacheData.h"
#include "NetworkCacheIOChannel.h"
#include "NetworkCacheRecordFormat.h"
#include "NetworkCacheStorage.h"
#include <wtf/CompletionHandler.h>
#include <wtf/Function.h>
#include <wtf/MonotonicTime.h>
#include <wtf/RunLoop.h>
#include <wtf/SHA1.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/WorkQueue.h>

// The storage's IO (NetworkCacheStorageIO.swift): its work queues and the hops back to the main thread.

namespace WebKit::NetworkCache {

// The storage's and the cache's work queues. Swift retains a WTF queue through its inline ref, which WTF.dll does not
// export on Windows.
class NetworkCacheQueue : public ThreadSafeRefCounted<NetworkCacheQueue> {
public:
    static Ref<NetworkCacheQueue> create(Ref<WTF::WorkQueueBase>&& queue) { return adoptRef(*new NetworkCacheQueue(WTF::move(queue))); }
    ~NetworkCacheQueue();
    void dispatch(Function<void()>&& function) { m_queue->dispatch(WTF::move(function)); }
private:
    explicit NetworkCacheQueue(Ref<WTF::WorkQueueBase>&& queue)
        : m_queue(WTF::move(queue))
    {
    }

    const Ref<WTF::WorkQueueBase> m_queue;
};

// Runs work on the queue, then posts reply to the main thread; the reply is never run or destroyed on the queue.
inline void dispatchWithReplyOnMain(NetworkCacheQueue& queue, Function<void()>&& work, CompletionHandler<void()>&& reply)
{
    queue.dispatch([work = WTF::move(work), reply = WTF::move(reply)] mutable {
        work();
        RunLoop::mainSingleton().dispatch(WTF::move(reply));
    });
}

// The reply is built on the queue's thread by a Sendable closure and moved to the main thread.
// Each reply type is move-only, which is what lets Swift build its CompletionHandler (CxxConsumingCompletionHandler).
struct ReadRecordReply {
    ReadRecordReply() = default;
    ReadRecordReply(ReadRecordReply&&) = default;
    ReadRecordReply& operator=(ReadRecordReply&&) = default;
    ReadRecordReply(const ReadRecordReply&) = delete;
    std::optional<DecodedRecord> record;
    MonotonicTime recordIOStartTime;
    MonotonicTime recordIOEndTime;
};

struct ReadBlobReply {
    ReadBlobReply() = default;
    ReadBlobReply(ReadBlobReply&&) = default;
    ReadBlobReply& operator=(ReadBlobReply&&) = default;
    ReadBlobReply(const ReadBlobReply&) = delete;
    bool hasBlob { false };
    Data data;
    SHA1::Digest hash { };
    MonotonicTime blobIOStartTime;
    MonotonicTime blobIOEndTime;
};

struct WriteBlobReply {
    WriteBlobReply() = default;
    WriteBlobReply(WriteBlobReply&&) = default;
    WriteBlobReply& operator=(WriteBlobReply&&) = default;
    WriteBlobReply(const WriteBlobReply&) = delete;
    bool hasBlob { false };
    Data data;
    SHA1::Digest hash { };
};

// What a write's record stage takes from its blob stage (Storage::storeBodyAsBlob's hash).
struct WriteBlobHash {
    bool hasBlob { false };
    SHA1::Digest hash { };
};

struct WriteRecordReply {
    WriteRecordReply() = default;
    WriteRecordReply(WriteRecordReply&&) = default;
    WriteRecordReply& operator=(WriteRecordReply&&) = default;
    WriteRecordReply(const WriteRecordReply&) = delete;
    ~WriteRecordReply() { } // A Swift-built CompletionHandler takes a move-only argument only if it has a destructor.
    size_t recordSize { 0 };
};

struct SynchronizeReply {
    SynchronizeReply() = default;
    SynchronizeReply(SynchronizeReply&&) = default;
    SynchronizeReply& operator=(SynchronizeReply&&) = default;
    SynchronizeReply(const SynchronizeReply&) = delete;
    ~SynchronizeReply() { } // As WriteRecordReply's.
    // Made here, filled in place on the IO queue, and moved to the storage: the reply crosses to main as two pointers.
    ContentsFilterPointer recordFilter { ContentsFilterPointer::create() };
    ContentsFilterPointer blobFilter { ContentsFilterPointer::create() };
    size_t recordsSize { 0 };
};

using ReadRecordReplyHandler = CompletionHandler<void(ReadRecordReply&&)>;
using ReadBlobReplyHandler = CompletionHandler<void(ReadBlobReply&&)>;
using WriteBlobReplyHandler = CompletionHandler<void(WriteBlobReply&&)>;
using WriteRecordReplyHandler = CompletionHandler<void(WriteRecordReply&&)>;
using SynchronizeReplyHandler = CompletionHandler<void(SynchronizeReply&&)>;

using ReadRecordWork = Function<ReadRecordReply()>;
using ReadBlobWork = Function<ReadBlobReply()>;
using WriteBlobWork = Function<WriteBlobReply()>;
using WriteRecordWork = Function<WriteRecordReply(WriteBlobHash)>;
using SynchronizeWork = Function<SynchronizeReply()>;

template<typename Result> void postReply(CompletionHandler<void(Result&&)>&& reply, Result&& result)
{
    RunLoop::mainSingleton().dispatch([reply = WTF::move(reply), result = WTF::move(result)] mutable {
        reply(WTF::move(result));
    });
}

// A read: the record stage, its reply, then the blob stage and its reply.
inline void dispatchReadWithRepliesOnMain(NetworkCacheQueue& queue, ReadRecordWork&& recordWork, ReadRecordReplyHandler&& recordReply, ReadBlobWork&& blobWork, ReadBlobReplyHandler&& blobReply)
{
    queue.dispatch([recordWork = WTF::move(recordWork), recordReply = WTF::move(recordReply), blobWork = WTF::move(blobWork), blobReply = WTF::move(blobReply)] mutable {
        postReply(WTF::move(recordReply), recordWork());
        postReply(WTF::move(blobReply), blobWork());
    });
}

// A write: the blob stage, its reply posted before the record is written, then the record stage with the blob's hash,
// and its reply.
inline void dispatchWriteWithRepliesOnMain(NetworkCacheQueue& queue, WriteBlobWork&& blobWork, WriteBlobReplyHandler&& blobReply, WriteRecordWork&& recordWork, WriteRecordReplyHandler&& recordReply)
{
    queue.dispatch([blobWork = WTF::move(blobWork), blobReply = WTF::move(blobReply), recordWork = WTF::move(recordWork), recordReply = WTF::move(recordReply)] mutable {
        WriteBlobReply blob = blobWork();
        WriteBlobHash blobHash { blob.hasBlob, blob.hash };
        postReply(WTF::move(blobReply), WTF::move(blob));
        postReply(WTF::move(recordReply), recordWork(blobHash));
    });
}

inline void dispatchSynchronizeWithReplyOnMain(NetworkCacheQueue& queue, SynchronizeWork&& work, SynchronizeReplyHandler&& reply)
{
    queue.dispatch([work = WTF::move(work), reply = WTF::move(reply)] mutable {
        postReply(WTF::move(reply), work());
    });
}

inline void dispatchOnMain(CompletionHandler<void()>&& handler) { RunLoop::mainSingleton().dispatch(WTF::move(handler)); }
// From another thread: a Function, which has no thread contract (RunLoop imports as a value Swift cannot call through).
inline void dispatchFunctionOnMain(Function<void()>&& work) { RunLoop::mainSingleton().dispatch(WTF::move(work)); }

// Reads a record file; completion runs on the main thread with its bytes. Called on the IO queue.
inline void readFileOnMain(const String& path, FileReadCompletion&& completion)
{
    Ref channel = IOChannel::open(path, IOChannel::Type::Read);
    channel->read(0, std::numeric_limits<size_t>::max(), WorkQueue::mainSingleton(), [completion = WTF::move(completion)](Data&& data, int) mutable {
        completion(WTF::move(data));
    });
}

Ref<NetworkCacheQueue> makeIOQueue();
// The other queues the storage and the cache create (Swift cannot spell an ASCIILiteral name).
Ref<NetworkCacheQueue> makeBackgroundIOQueue();
Ref<NetworkCacheQueue> makeSerialBackgroundIOQueue();
Ref<NetworkCacheQueue> makeDeleteQueue();

} // namespace WebKit::NetworkCache
