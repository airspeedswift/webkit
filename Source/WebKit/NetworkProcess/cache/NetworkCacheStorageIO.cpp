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

#include "config.h"
#include "NetworkCacheStorageIO.h"

#include <wtf/WorkQueue.h>

// The work queues of the storage's I/O (NetworkCacheStorageIO.swift).

namespace WebKit::NetworkCache {

NetworkCacheQueue::~NetworkCacheQueue() = default;

Ref<NetworkCacheQueue> makeBackgroundIOQueue()
{
    return NetworkCacheQueue::create(ConcurrentWorkQueue::create("com.apple.WebKit.Cache.Storage.background"_s, WorkQueue::QOS::Utility));
}

Ref<NetworkCacheQueue> makeSerialBackgroundIOQueue()
{
    return NetworkCacheQueue::create(WorkQueue::create("com.apple.WebKit.Cache.Storage.serialBackground"_s, WorkQueue::QOS::Utility));
}

Ref<NetworkCacheQueue> makeDeleteQueue()
{
    return NetworkCacheQueue::create(WorkQueue::create("com.apple.WebKit.Cache.delete"_s));
}

Ref<NetworkCacheQueue> makeIOQueue()
{
    return NetworkCacheQueue::create(ConcurrentWorkQueue::create("com.apple.WebKit.Cache.Storage"_s,
#if OS(LINUX)
        WorkQueue::QOS::UserInitiated
#else
        WorkQueue::QOS::UserInteractive
#endif
        ));
}

} // namespace WebKit::NetworkCache
