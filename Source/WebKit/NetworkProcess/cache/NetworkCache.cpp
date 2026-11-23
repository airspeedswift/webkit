/*
 * Copyright (C) 2014-2025 Apple Inc. All rights reserved.
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
#include "NetworkCache.h"

#include "Logging.h"
#include "NetworkCacheDump.h"
#include "NetworkCacheValidation.h"
#include "NetworkProcess.h"
#include "NetworkSession.h"
#include "NetworkStorageSession.h"
#include "WebKit-Swift.h"
#include <WebCore/CacheValidation.h>
#include <WebCore/LowPowerModeNotifier.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ThermalMitigationNotifier.h>
#include <wtf/BlockPtr.h>
#include <wtf/FileSystem.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/RunLoop.h>
#include <wtf/SystemTracing.h>

#if PLATFORM(COCOA)
#include <notify.h>
#include <wtf/darwin/DispatchExtras.h>
#endif

#if PLATFORM(GTK) || PLATFORM(WPE)
#include <wtf/glib/GLibExtras.h>
#endif

#if USE(SOUP)
#include <gio/gio.h>
#include <wtf/glib/GRefPtr.h>
#endif

namespace WebKit {
namespace NetworkCache {

// The cache is NetworkCache.swift; below are the C++ functions it calls, and those that call it from translation units
// without the Swift header.

const AtomString& recordTypeName(RecordType recordType)
{
    ASSERT_WITH_SECURITY_IMPLICATION(RunLoop::isMain());
    static NeverDestroyed<const AtomString> resource("Resource"_s);
    static NeverDestroyed<const AtomString> compressionDictionary("CompressionDictionary"_s);
    return recordType == RecordType::CompressionDictionary ? compressionDictionary : resource;
}

size_t computeCapacity(const String& cachePath)
{
    if (auto diskFreeSize = FileSystem::volumeFreeSpace(cachePath)) {
        // As a fudge factor, use 1000 instead of 1024, in case the reported byte
        // count doesn't align exactly to a megabyte boundary.
        *diskFreeSize /= KB * 1000;
        return calculateURLCacheDiskCapacity(NetworkProcess::singleton().cacheModel(), *diskFreeSize);
    }
    return 0;
}

bool isPrimaryWebBrowser()
{
    return NetworkProcess::singleton().cacheModel() == CacheModel::PrimaryWebBrowser;
}

RequestDirectives parseRequestDirectives(const WebCore::ResourceRequest& request)
{
    auto directives = WebCore::parseCacheControlDirectives(request.httpHeaderFields());
    RequestDirectives result;
    result.noCache = directives.noCache;
    result.noStore = directives.noStore;
    result.maxAge = directives.maxAge;
    result.maxStale = directives.maxStale;
    result.minFresh = directives.minFresh;
    return result;
}

bool isGETRequest(const WebCore::ResourceRequest& request)
{
    return request.httpMethod() == "GET"_s;
}

bool isMediaMIMEType(const String& type)
{
    return startsWithLettersIgnoringASCIICase(type, "video/"_s) || startsWithLettersIgnoringASCIICase(type, "audio/"_s);
}

bool networkCacheVerifyVaryingRequestHeaders(PAL::SessionID sessionID, const Vector<std::pair<String, String>>& varyingRequestHeaders, const WebCore::ResourceRequest& request)
{
    return verifyVaryingRequestHeaders(protect(NetworkProcess::singleton().storageSession(sessionID)), varyingRequestHeaders, request);
}

Vector<std::pair<String, String>> networkCacheCollectVaryingRequestHeaders(PAL::SessionID sessionID, const WebCore::ResourceRequest& request, const WebCore::ResourceResponse& response)
{
    return collectVaryingRequestHeaders(protect(NetworkProcess::singleton().storageSession(sessionID)), request, response);
}

bool isStaleWhileRevalidateEnabled(PAL::SessionID sessionID)
{
    // The session exists while its cache does.
    return protect(NetworkProcess::singleton().networkSession(sessionID))->isStaleWhileRevalidateEnabled();
}

void signpostRetrieve(const RetrieveInfo& info, bool isHit)
{
#if ENABLE(NETWORK_CACHE_SIGNPOSTS)
    if (WTFSignpostsEnabled()) [[unlikely]] {
        auto retrieveDecision = info.retrieveDecision ? static_cast<int>(*info.retrieveDecision) : -1;
        auto speculativeLoadDecision = info.speculativeLoadDecision ? static_cast<int>(*info.speculativeLoadDecision) : -1;
        auto useDecision = info.useDecision ? static_cast<int>(*info.useDecision) : -1;

        if (isHit) {
            WTFBeginSignpostAlwaysWithTimeDelta(&info, NetworkCacheHit, info.startTime - info.completionTime, "Network cache hit for %" PRIVATE_LOG_STRING " retrieveDecision: %d speculativeLoadDecision: %d useDecision: %d", info.url.string().utf8(), retrieveDecision, speculativeLoadDecision, useDecision);
            WTFEndSignpostAlways(&info, NetworkCacheHit);
        } else {
            WTFBeginSignpostAlwaysWithTimeDelta(&info, NetworkCacheMiss, info.startTime - info.completionTime, "Network cache miss for %" PRIVATE_LOG_STRING " retrieveDecision: %d speculativeLoadDecision: %d useDecision: %d", info.url.string().utf8(), retrieveDecision, speculativeLoadDecision, useDecision);
            WTFEndSignpostAlways(&info, NetworkCacheMiss);
        }
    }
#else
    UNUSED_PARAM(info);
    UNUSED_PARAM(isHit);
#endif
}

std::optional<RecordType> TraversalRecord::type() const
{
    auto typeName = record.key.type();
    if (typeName == recordTypeName(RecordType::Resource))
        return RecordType::Resource;
    if (typeName == recordTypeName(RecordType::CompressionDictionary))
        return RecordType::CompressionDictionary;
    return std::nullopt;
}

std::optional<URL> TraversalRecord::url() const
{
    auto recordType = type();
    if (!recordType)
        return std::nullopt;

    std::optional<URL> url;
    if (*recordType == RecordType::CompressionDictionary)
        url = URL { record.key.identifier() };
    else if (auto responseURL = Entry::decodeStorageRecordResponseURL(record.header))
        url = responseURL.get();

    if (url && !url->isValid())
        return std::nullopt;

    return url;
}

void invokeMappedBodyHandler(MappedBodyHandler& handler, const Data& bodyData)
{
    if (!handler)
        return;
    MappedBody mappedBody;
#if ENABLE(SHAREABLE_RESOURCE)
    if (RefPtr resource = shareableResourceFromBody(bodyData)) {
        if (auto handle = resource->createHandle())
            mappedBody.shareableResourceHandle = WTF::move(*handle);
        mappedBody.shareableResource = WTF::move(resource);
    }
#else
    UNUSED_PARAM(bodyData);
#endif
    handler(WTF::move(mappedBody));
}

SpeculationNotifiers::SpeculationNotifiers(Function<void()>&& changed)
    : m_changed(WTF::move(changed))
{
    m_lowPowerModeNotifier = makeUnique<WebCore::LowPowerModeNotifier>([weakThis = WeakPtr { *this }](bool) {
        if (RefPtr protectedThis = weakThis)
            protectedThis->m_changed();
    });
    m_thermalMitigationNotifier = WebCore::ThermalMitigationNotifier::create([weakThis = WeakPtr { *this }](bool) {
        if (RefPtr protectedThis = weakThis)
            protectedThis->m_changed();
    });
}

SpeculationNotifiers::~SpeculationNotifiers() = default;

bool SpeculationNotifiers::shouldUseSpeculativeLoadManager() const
{
    CheckedPtr notifier = m_lowPowerModeNotifier;
    bool isLowPowerModeEnabled = notifier && notifier->isLowPowerModeEnabled();
    bool isThermalMitigationEnabled = m_thermalMitigationNotifier && m_thermalMitigationNotifier->isThermalMitigationEnabled();
    return !isLowPowerModeEnabled && !isThermalMitigationEnabled;
}

void NetworkCacheDeleter::operator()(Cache* cache) const
{
    delete cache;
}

NetworkCachePtr retainedCopy(Cache& cache)
{
    return NetworkCachePtr { new Cache(cache) };
}

void PrefetchCacheDeleter::operator()(PrefetchCache* prefetchCache) const
{
    delete prefetchCache;
}

PrefetchCachePtr makePrefetchCache()
{
    return PrefetchCachePtr { new PrefetchCache(PrefetchCache::init()) };
}

#if PLATFORM(GTK) || PLATFORM(WPE)
static void dumpFileChanged(NetworkDiskCacheWeakReference* cache)
{
    if (auto strongCache = cache->get())
        strongCache.get().dumpContentsToFile();
}
#endif

NetworkCachePtr openNetworkCache(const String& cachePath, OptionSet<CacheOption> options, PAL::SessionID sessionID)
{
    auto openedCache = Cache::open(cachePath, options.toRaw(), sessionID);
    LOG(NetworkCache, "(NetworkProcess) opened cache storage, success %d", !!openedCache);
    if (!openedCache)
        return nullptr;

    auto cache = NetworkCachePtr { new Cache(openedCache.get()) };

    if (options.contains(CacheOption::SpeculativeRevalidation)) {
        Ref notifiers = SpeculationNotifiers::create([weakCache = cache->makeWeakReference()] mutable {
            if (auto strongCache = weakCache.get())
                strongCache.get().updateSpeculativeLoadManagerEnabledState();
        });
        cache->enableSpeculativeRevalidation(notifiers.ptr());
    }

    if (options.contains(CacheOption::RegisterNotify)) {
#if PLATFORM(COCOA)
        // Triggers with "notifyutil -p com.apple.WebKit.Cache.dump".
        int token;
        auto weakCache = cache->makeWeakReference();
        notify_register_dispatch("com.apple.WebKit.Cache.dump", &token, mainDispatchQueueSingleton(), makeBlockPtr([weakCache](int) {
            // A block's captures are const and the Swift class's methods are not.
            auto reference = weakCache;
            if (auto strongCache = reference.get())
                strongCache.get().dumpContentsToFile();
        }).get());
#endif
#if PLATFORM(GTK) || PLATFORM(WPE)
        // Triggers with "touch $cachePath/dump". The monitor and its weak reference live as long as the process.
        auto dumpFilePath = FileSystem::fileSystemRepresentation(FileSystem::pathByAppendingComponent(cache->getStorage().basePathIsolatedCopy(), "dump"_s));
        GRefPtr<GFile> dumpFile = gFileNewForPath(dumpFilePath);
        GFileMonitor* monitor = g_file_monitor_file(dumpFile.get(), G_FILE_MONITOR_NONE, nullptr, nullptr);
        g_signal_connect_swapped(monitor, "changed", G_CALLBACK(dumpFileChanged), new NetworkDiskCacheWeakReference(cache->makeWeakReference()));
#endif
    }

    return cache;
}

} // namespace NetworkCache
} // namespace WebKit
