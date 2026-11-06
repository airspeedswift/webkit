/*
 * Copyright (C) 2021-2025 Apple Inc. All rights reserved.
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

#if ENABLE(MOMENTUM_EVENT_DISPATCHER)

#define ENABLE_MOMENTUM_EVENT_DISPATCHER_TEMPORARY_LOGGING 0

#include "ScrollingAccelerationCurve.h"
#include "WebWheelEvent.h"
#include <WebCore/FloatSize.h>
#include <WebCore/PageIdentifier.h>
#include <WebCore/RectEdges.h>
#include <WebKit/WKDeclarationSpecifiers.h>
#include <memory>
#include <wtf/CheckedPtr.h>
#include <wtf/Deque.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Noncopyable.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {
struct DisplayUpdate;
using FramesPerSecond = unsigned;
using PlatformDisplayID = uint32_t;
enum class RubberBandingBehavior : uint8_t;
}

namespace WebKit {

class MomentumActions;
class MomentumEventDispatcherState;

class MomentumEventDispatcher {
    WTF_MAKE_NONCOPYABLE(MomentumEventDispatcher);
    WTF_MAKE_TZONE_ALLOCATED(MomentumEventDispatcher);
public:
    class Client : public CanMakeCheckedPtr<Client> {
        WTF_DEPRECATED_MAKE_FAST_ALLOCATED(Client);
        WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(Client);
    friend class MomentumEventDispatcher;
    public:
        virtual ~Client() = default;

    private:
        virtual void handleSyntheticWheelEvent(WebCore::PageIdentifier, const WebWheelEvent&, WebCore::RectEdges<WebCore::RubberBandingBehavior> rubberBandableEdges) = 0;

        virtual void startDisplayDidRefreshCallbacks(WebCore::PlatformDisplayID) = 0;
        virtual void stopDisplayDidRefreshCallbacks(WebCore::PlatformDisplayID) = 0;

        virtual void didEndSyntheticMomentumScrolling() { }

#if ENABLE(MOMENTUM_EVENT_DISPATCHER_TEMPORARY_LOGGING)
        virtual void flushMomentumEventLoggingSoon() = 0;
#endif
    };

    // Made in WebKit, so a caller outside it never sizes or lays out the object from its copy of this header.
    WK_EXPORT static std::unique_ptr<MomentumEventDispatcher> create(Client&);

    MomentumEventDispatcher(Client&);
    WK_EXPORT ~MomentumEventDispatcher();

    WK_EXPORT bool handleWheelEvent(WebCore::PageIdentifier, const WebWheelEvent&, WebCore::RectEdges<WebCore::RubberBandingBehavior> rubberBandableEdges);

    WK_EXPORT void setScrollingAccelerationCurve(WebCore::PageIdentifier, std::optional<ScrollingAccelerationCurve>&&);

    WK_EXPORT void displayDidRefresh(WebCore::PlatformDisplayID);

    WK_EXPORT void pageScreenDidChange(WebCore::PageIdentifier, WebCore::PlatformDisplayID, std::optional<unsigned> nominalFramesPerSecond);

#if ENABLE(MOMENTUM_EVENT_DISPATCHER_TEMPORARY_LOGGING)
    void flushLog();
#endif

private:

    void dispatchSyntheticMomentumEvent(WebWheelEvent::Phase, WebCore::FloatSize delta, WebWheelEvent::MomentumEndType = WebWheelEvent::MomentumEndType::Unknown);

    RefPtr<const WebWheelEvent> m_lastIncomingEvent;
    WebCore::RectEdges<WebCore::RubberBandingBehavior> m_lastRubberBandableEdges;
    void performActions(const MomentumActions&, std::optional<WebCore::PageIdentifier> beginningPage = std::nullopt, const WebWheelEvent* beginningEvent = nullptr);

    // The gesture's page and initiating event, which the synthetic events are built from.
    struct {
        bool active { false };
        Markable<WebCore::PageIdentifier> pageIdentifier;
        RefPtr<const WebWheelEvent> initiatingEvent;
    } m_currentGesture;
    const CheckedRef<Client> m_client;
    const std::unique_ptr<MomentumEventDispatcherState> m_state;
};

} // namespace WebKit

#endif
