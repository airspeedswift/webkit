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

#pragma once

#include "NetworkCache.h"
#include "NetworkLoadClient.h"
#include "NetworkLoadParameters.h"
#include "PolicyDecision.h"
#include "PrivateRelayed.h"
#include <WebCore/FrameLoaderTypes.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/CompletionHandler.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {
enum class AdvancedPrivacyProtections : uint16_t;
}

namespace WebKit {

class NetworkLoad;

namespace NetworkCache {

// NetworkLoadClient's callbacks take references and move-only handlers, which Swift cannot override; each stores its
// values and calls the handler Swift set.
struct SpeculativeLoadEvent {
    enum class Type : uint8_t { None, Redirect, Response, Buffer, Finish, Fail };
    Type type { Type::None };
    WebCore::ResourceRequest request;
    WebCore::ResourceRequest redirectRequest;
    WebCore::ResourceResponse response;
    PrivateRelayed privateRelayed { PrivateRelayed::No };
    RefPtr<const WebCore::FragmentedSharedBuffer> buffer;
};

class SpeculativeLoad final : public RefCounted<SpeculativeLoad>, public NetworkLoadClient {
    WTF_MAKE_TZONE_ALLOCATED(SpeculativeLoad);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(SpeculativeLoad);
public:
    // Out of line, with the destructor (the key function): Swift's clang would emit the construction and the vtable,
    // which name WTF's dllimport inline CanMakeCheckedPtrBase members on Windows.
    static Ref<SpeculativeLoad> create();
    ~SpeculativeLoad();

    SWIFT_UNSAFE void ref() const final { RefCounted::ref(); }
    SWIFT_UNSAFE void deref() const final { RefCounted::deref(); }

    // The network load of request for frameID with this client, not started; null when the session is gone. The
    // caller stores it before it calls startWithScheduling(), since the load can call its client inside the start.
    // Kept in C++: the load is made for the NetworkSession, which Swift does not import (no shared-reference
    // annotation, and its unique_ptr members and declared destructor leave it neither copyable nor movable).
    RefPtr<NetworkLoad> createNetworkLoad(const GlobalFrameID&, const WebCore::ResourceRequest&, std::optional<NavigatingToAppBoundDomain>, bool allowPrivacyProxy, OptionSet<WebCore::AdvancedPrivacyProtections>, PAL::SessionID);
    // Kept in C++: the PreconnectTask is made for the NetworkSession too (with SERVER_PRECONNECT; otherwise nothing).
    static void preconnect(const GlobalFrameID&, const WebCore::ResourceRequest&, std::optional<NavigatingToAppBoundDomain>, bool allowPrivacyProxy, OptionSet<WebCore::AdvancedPrivacyProtections>, PAL::SessionID);
    // Kept in C++: NetworkStorageSession is not imported either (noncopyable, with no shared-reference annotation).
    static std::optional<Seconds> maxAgeCap(PAL::SessionID, const WebCore::ResourceRequest&);

    void setEventHandler(CompletionHandler<void()>&& handler) { m_eventHandler = WTF::move(handler); }
    SpeculativeLoadEvent takeEvent() { return std::exchange(m_event, { }); }

private:
    SpeculativeLoad() = default;
    static NetworkLoadParameters makeParameters(const GlobalFrameID&, const WebCore::ResourceRequest&, std::optional<NavigatingToAppBoundDomain>, bool allowPrivacyProxy, OptionSet<WebCore::AdvancedPrivacyProtections>);
    void deliver(SpeculativeLoadEvent&&);

    // NetworkLoadClient.
    void didSendData(uint64_t bytesSent, uint64_t totalBytesToBeSent) override { }
    bool isSynchronous() const override { return false; }
    bool isAllowedToAskUserForCredentials() const final { return false; }
    void willSendRedirectedRequest(WebCore::ResourceRequest&& request, WebCore::ResourceRequest&& redirectRequest, WebCore::ResourceResponse&& redirectResponse, CompletionHandler<void(WebCore::ResourceRequest&&)>&& completionHandler) override { deliver({ .type = SpeculativeLoadEvent::Type::Redirect, .request = WTF::move(request), .redirectRequest = WTF::move(redirectRequest), .response = WTF::move(redirectResponse) }); completionHandler({ }); }
    void didReceiveResponse(WebCore::ResourceResponse&& response, PrivateRelayed privateRelayed, ResponseCompletionHandler&& completionHandler) override { deliver({ .type = SpeculativeLoadEvent::Type::Response, .response = WTF::move(response), .privateRelayed = privateRelayed }); completionHandler(WebCore::PolicyAction::Use); }
    void didReceiveBuffer(const WebCore::FragmentedSharedBuffer& buffer) override { deliver({ .type = SpeculativeLoadEvent::Type::Buffer, .buffer = &buffer }); }
    void didFinishLoading(const WebCore::NetworkLoadMetrics&) override { deliver({ .type = SpeculativeLoadEvent::Type::Finish }); }
    void didFailLoading(const WebCore::ResourceError&) override { deliver({ .type = SpeculativeLoadEvent::Type::Fail }); }

    CompletionHandler<void()> m_eventHandler;
    SpeculativeLoadEvent m_event;
};

// The test support's dry run of the speculative load manager (defined in NetworkCacheTestSupport.cpp). While it is on, the
// manager starts no network load or preconnect and logs no diagnostic message: it passes each to the test support, which
// records it. Each returns false when the dry run is off, and the manager goes on as it does without one.
enum class SpeculativeLoadDryRun : uint8_t { Preconnect, Diagnostic };
bool dryRunSpeculativeRevalidation(const WebCore::ResourceRequest&);
bool dryRunSpeculativeLoad(SpeculativeLoadDryRun, const String& subject);

} // namespace NetworkCache
} // namespace WebKit
