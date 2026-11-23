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
#include "NetworkCacheSpeculativeLoad.h"

#include "NetworkCache.h"
#include "NetworkLoad.h"
#include "NetworkProcess.h"
#include "NetworkSession.h"
#include "NetworkStorageSession.h"
#include "PreconnectTask.h"
#include <pal/SessionID.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {
namespace NetworkCache {

using namespace WebCore;

WTF_MAKE_TZONE_ALLOCATED_IMPL(SpeculativeLoad);

Ref<SpeculativeLoad> SpeculativeLoad::create()
{
    return adoptRef(*new SpeculativeLoad);
}

SpeculativeLoad::~SpeculativeLoad()
{
    // At teardown the handler is the Swift load's empty one (set by its deinit) or one whose load is gone, so
    // calling it does nothing; an uncalled CompletionHandler asserts in its destructor.
    if (auto handler = std::exchange(m_eventHandler, { }))
        handler();
}

NetworkLoadParameters SpeculativeLoad::makeParameters(const GlobalFrameID& frameID, const ResourceRequest& request, std::optional<NavigatingToAppBoundDomain> isNavigatingToAppBoundDomain, bool allowPrivacyProxy, OptionSet<AdvancedPrivacyProtections> advancedPrivacyProtections)
{
    NetworkLoadParameters parameters;
    parameters.webPageProxyID = frameID.webPageProxyID;
    parameters.webPageID = frameID.webPageID;
    parameters.webFrameID = frameID.frameID;
    parameters.storedCredentialsPolicy = StoredCredentialsPolicy::Use;
    parameters.contentSniffingPolicy = ContentSniffingPolicy::DoNotSniffContent;
    parameters.contentEncodingSniffingPolicy = ContentEncodingSniffingPolicy::Default;
    parameters.request = request;
    parameters.isNavigatingToAppBoundDomain = isNavigatingToAppBoundDomain;
    parameters.allowPrivacyProxy = allowPrivacyProxy;
    parameters.advancedPrivacyProtections = advancedPrivacyProtections;
    return parameters;
}

RefPtr<NetworkLoad> SpeculativeLoad::createNetworkLoad(const GlobalFrameID& frameID, const ResourceRequest& request, std::optional<NavigatingToAppBoundDomain> isNavigatingToAppBoundDomain, bool allowPrivacyProxy, OptionSet<AdvancedPrivacyProtections> advancedPrivacyProtections, PAL::SessionID sessionID)
{
    CheckedPtr networkSession = NetworkProcess::singleton().networkSession(sessionID);
    if (!networkSession)
        return nullptr;
    return NetworkLoad::create(*this, makeParameters(frameID, request, isNavigatingToAppBoundDomain, allowPrivacyProxy, advancedPrivacyProtections), *networkSession);
}

void SpeculativeLoad::preconnect(const GlobalFrameID& frameID, const ResourceRequest& request, std::optional<NavigatingToAppBoundDomain> isNavigatingToAppBoundDomain, bool allowPrivacyProxy, OptionSet<AdvancedPrivacyProtections> advancedPrivacyProtections, PAL::SessionID sessionID)
{
#if ENABLE(SERVER_PRECONNECT)
    CheckedPtr networkSession = NetworkProcess::singleton().networkSession(sessionID);
    if (!networkSession)
        return;
    auto parameters = makeParameters(frameID, request, isNavigatingToAppBoundDomain, allowPrivacyProxy, advancedPrivacyProtections);
    parameters.shouldPreconnectOnly = PreconnectOnly::Yes;
    Ref preconnectTask = PreconnectTask::create(*networkSession, WTF::move(parameters));
    preconnectTask->start();
#else
    UNUSED_PARAM(frameID);
    UNUSED_PARAM(request);
    UNUSED_PARAM(isNavigatingToAppBoundDomain);
    UNUSED_PARAM(allowPrivacyProxy);
    UNUSED_PARAM(advancedPrivacyProtections);
    UNUSED_PARAM(sessionID);
#endif // ENABLE(SERVER_PRECONNECT)
}

std::optional<Seconds> SpeculativeLoad::maxAgeCap(PAL::SessionID sessionID, const ResourceRequest& request)
{
    if (CheckedPtr networkStorageSession = NetworkProcess::singleton().storageSession(sessionID))
        return networkStorageSession->maxAgeCacheCap(request, NetworkSession::isRequestToKnownCrossSiteTracker(request));
    return std::nullopt;
}

void SpeculativeLoad::deliver(SpeculativeLoadEvent&& event)
{
    // The handler takes the event (takeEvent()) and may free this load: nothing here touches this after the call.
    auto handler = std::exchange(m_eventHandler, { });
    // Swift sets the next handler as it takes each event, and an empty one when the load goes away.
    ASSERT(handler);
    if (!handler)
        return;
    m_event = WTF::move(event);
    handler();
}

} // namespace NetworkCache
} // namespace WebKit
