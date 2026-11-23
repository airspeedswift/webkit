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

#pragma once

#include "NavigatingToAppBoundDomain.h"
#include "NetworkCacheCompressionDictionaryEntry.h"
#include "NetworkCacheEntry.h"
#include "NetworkCacheHandlers.h"
#include "NetworkCacheStorage.h"
#include "WebPageProxyIdentifier.h"
#include <WebCore/FrameIdentifier.h>
#include <WebCore/PageIdentifier.h>
#include <WebCore/ResourceResponse.h>
#include <memory>
#include <pal/SessionID.h>
#include <wtf/CrossThreadCopier.h>
#include <wtf/Hasher.h>
#include <wtf/Markable.h>
#include <wtf/OptionSet.h>
#include <wtf/RefCounted.h>
#include <wtf/Seconds.h>
#include <wtf/WeakPtr.h>
#include <wtf/text/WTFString.h>

namespace WebCore {
class LowPowerModeNotifier;
class ResourceRequest;
class ResourceResponse;
class ThermalMitigationNotifier;
enum class AdvancedPrivacyProtections : uint16_t;
}

namespace WebKit {
namespace NetworkCache {

struct GlobalFrameID {
    WebPageProxyIdentifier webPageProxyID;
    WebCore::PageIdentifier webPageID;
    WebCore::FrameIdentifier frameID;

    static constexpr bool safeToCompareToHashTableEmptyOrDeletedValue = true;
};

inline void add(Hasher& hasher, const GlobalFrameID& identifier)
{
    add(hasher, identifier.webPageID, identifier.frameID);
}

// The hash WTF's HashMap<GlobalFrameID, ...> uses, for Swift, which cannot call the computeHash template. Here, not in
// NetworkCacheWTFInterop.h, since it needs the struct and its add().
inline unsigned globalFrameIDHash(const GlobalFrameID& identifier) { return computeHash(identifier); }

inline bool operator==(const GlobalFrameID& a, const GlobalFrameID& b)
{
    // No need to check webPageProxyID since webPageIDs are globally unique and a given WebPage is always
    // associated with the same WebPageProxy.
    return a.webPageID == b.webPageID &&  a.frameID == b.frameID;
}

}
}

namespace WTF {

template<> struct HashTraits<WebKit::NetworkCache::GlobalFrameID> : GenericHashTraits<WebKit::NetworkCache::GlobalFrameID> {
    static WebKit::NetworkCache::GlobalFrameID emptyValue() { return { HashTraits<WebKit::WebPageProxyIdentifier>::emptyValue(), HashTraits<WebCore::PageIdentifier>::emptyValue(), HashTraits<WebCore::FrameIdentifier>::emptyValue() }; }
    static bool isEmptyValue(const WebKit::NetworkCache::GlobalFrameID& slot) { return slot.webPageID.isHashTableEmptyValue(); }

    static void constructDeletedValue(WebKit::NetworkCache::GlobalFrameID& slot) { new (NotNull, &slot.webPageID) WebCore::PageIdentifier(WTF::HashTableDeletedValue); }

    static bool isDeletedValue(const WebKit::NetworkCache::GlobalFrameID& slot) { return slot.webPageID.isHashTableDeletedValue(); }
};

}

namespace WebKit {

class NetworkProcess;

namespace NetworkCache {

enum class RetrieveDecision {
    Yes,
    NoDueToHTTPMethod,
    NoDueToConditionalRequest,
    NoDueToReloadIgnoringCache,
    NoDueToStreamingMedia
};

enum class SpeculativeLoadDecision {
    Yes,
    NoDueToVaryingHeaderMismatch,
    NoDueToCannotUse,
};

enum class StoreDecision {
    Yes,
    NoDueToProtocol,
    NoDueToHTTPMethod,
    NoDueToNoStoreResponse,
    NoDueToMissingExpirationHeaders,
    NoDueToNoStoreRequest,
    NoDueToUnlikelyToReuse,
    NoDueToStreamingMedia,
    NoDueToRequestContainingFragments,
    NoDueToHTTPStatusCode
};

enum class UseDecision {
    Use,
    Validate,
    AsyncRevalidate,
    NoDueToVaryingHeaderMismatch,
    NoDueToMissingValidatorFields,
    NoDueToDecodeFailure,
    NoDueToExpiredRedirect,
    NoDueToRequestContainingFragments
};

enum class CacheOption : uint8_t {
    // In testing mode we try to eliminate sources of randomness. Cache does not shrink and there are no read timeouts.
    TestingMode = 1 << 0,
    RegisterNotify = 1 << 1,
    SpeculativeRevalidation = 1 << 2,
};

enum class RecordType : uint8_t {
    Resource = 1 << 0,
    CompressionDictionary = 1 << 1,
};

// The disk cache is the Swift class WebKit::NetworkDiskCache (NetworkCache.swift), NetworkCache::Cache to C++. A header
// holds it through NetworkCachePtr; the .cpp files that include WebKit-Swift.h use it by value. The types below are what
// the cache and its C++ callers exchange.

// Completion handler may get called back synchronously on failure.
struct RetrieveInfo {
    URL url;
    MonotonicTime startTime;
    MonotonicTime completionTime;
    unsigned priority { 0 };
    Storage::Timings storageTimings;
    Markable<RetrieveDecision> retrieveDecision;
    Markable<SpeculativeLoadDecision> speculativeLoadDecision;
    Markable<UseDecision> useDecision;

    // The Swift cache sets the Markable fields through these.
    void setRetrieveDecision(RetrieveDecision decision) { retrieveDecision = decision; }
    void setSpeculativeLoadDecision(SpeculativeLoadDecision decision) { speculativeLoadDecision = decision; }
    void setUseDecision(UseDecision decision) { useDecision = decision; }

    RetrieveInfo isolatedCopy() && { return {
        crossThreadCopy(WTF::move(url)),
        startTime,
        completionTime,
        priority,
        storageTimings,
        retrieveDecision,
        speculativeLoadDecision,
        useDecision
    }; }
};

using OptionalFrameID = std::optional<GlobalFrameID>;
using OptionalAppBoundDomain = std::optional<NavigatingToAppBoundDomain>;
using NetworkCacheAdvancedPrivacyProtections = OptionSet<WebCore::AdvancedPrivacyProtections>;
using OptionalSeconds = std::optional<Seconds>;

// The request's Cache-Control directives the decisions read (WebCore::parseCacheControlDirectives), as plain
// fields.
struct RequestDirectives {
    bool noCache { false };
    bool noStore { false };
    OptionalSeconds maxAge;
    OptionalSeconds maxStale;
    OptionalSeconds minFresh;
};
RequestDirectives parseRequestDirectives(const WebCore::ResourceRequest&);
bool isGETRequest(const WebCore::ResourceRequest&);
bool isMediaMIMEType(const String&);
// The session's storage session and network session, looked up for the decisions (NetworkCacheValidation.h).
bool networkCacheVerifyVaryingRequestHeaders(PAL::SessionID, const Vector<std::pair<String, String>>&, const WebCore::ResourceRequest&);
Vector<std::pair<String, String>> networkCacheCollectVaryingRequestHeaders(PAL::SessionID, const WebCore::ResourceRequest&, const WebCore::ResourceResponse&);
bool isStaleWhileRevalidateEnabled(PAL::SessionID);
bool isPrimaryWebBrowser();
size_t computeCapacity(const String& cachePath);
void signpostRetrieve(const RetrieveInfo&, bool isHit);

// Speculative revalidation's power state notifiers: the changed function runs when low power mode or thermal mitigation
// changes, and the cache then asks whether to keep its speculative load manager. The notifiers take C++ lambdas.
class SpeculationNotifiers : public RefCounted<SpeculationNotifiers>, public CanMakeWeakPtr<SpeculationNotifiers> {
public:
    static Ref<SpeculationNotifiers> create(Function<void()>&& changed) { return adoptRef(*new SpeculationNotifiers(WTF::move(changed))); }
    ~SpeculationNotifiers();
    bool shouldUseSpeculativeLoadManager() const;
private:
    explicit SpeculationNotifiers(Function<void()>&&);
    Function<void()> m_changed;
    std::unique_ptr<WebCore::LowPowerModeNotifier> m_lowPowerModeNotifier;
    RefPtr<WebCore::ThermalMitigationNotifier> m_thermalMitigationNotifier;
};

#ifndef __swift__
NetworkCachePtr retainedCopy(Cache&);
PrefetchCachePtr makePrefetchCache();

// Opens the Swift cache and gives it its speculation state and its dump notification (NetworkCache.cpp).
NetworkCachePtr openNetworkCache(const String& cachePath, OptionSet<CacheOption>, PAL::SessionID);

// The cache's retrieve as its C++ callers call it: it builds the handler box the Swift entry point takes, and the
// completion gets the entry, which it takes from the cache with the token. A template, so that it compiles before
// WebKit-Swift.h completes Cache.
void retrieveFromNetworkCache(auto& cache, const WebCore::ResourceRequest& request, const OptionalFrameID& frameID, const OptionalAppBoundDomain& isNavigatingToAppBoundDomain, bool allowPrivacyProxy, NetworkCacheAdvancedPrivacyProtections advancedPrivacyProtections, auto&& completionHandler)
{
    // The completion holds a reference to the cache, which takes the entry when the completion runs.
    cache.retrieve(request, frameID, isNavigatingToAppBoundDomain, allowPrivacyProxy, advancedPrivacyProtections, RetrieveHandlerBox::create([cache = std::remove_cvref_t<decltype(cache)> { cache }, completionHandler = std::forward<decltype(completionHandler)>(completionHandler)](uint64_t token, const RetrieveInfo& info) mutable {
        completionHandler(token ? entryPointer(cache.takeRetrievedEntry(token)) : nullptr, info);
    }).ptr());
}

#endif

} // namespace NetworkCache
} // namespace WebKit
