/*
 * Copyright (C) 2019 Apple Inc. All rights reserved.
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

#include <wtf/Platform.h>
#if PLATFORM(MAC)

#include <WebCore/FloatRect.h>
#include <WebCore/FloatSize.h>
#include <WebCore/PlatformWheelEvent.h>
#include <WebCore/ScrollTypes.h>
#include <WebCore/UserInterfaceLayoutDirection.h>
#include <wtf/SwiftBridging.h>
#include <WebCore/ScrollingStateScrollingNode.h>
#include <wtf/RecursiveLockAdapter.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>

OBJC_CLASS NSScrollerImp;
OBJC_CLASS CALayer;
OBJC_CLASS NSScrollerImpPair;

namespace WebCore {
class PlatformWheelEvent;
class ScrollingTreeScrollingNode;

struct ScrollbarColor;
class MacScrollerPair;
struct ScrollerPairMacState;
enum class ScrollerImpPairNotification : uint8_t;
enum class ScrollbarPartFeature : uint8_t;

}

namespace WebCore {

// Controls a pair of NSScrollerImps via a pair of ScrollerMac. The NSScrollerImps need to remain internal to this class.
class ScrollerPairMac : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<ScrollerPairMac> {
    WTF_MAKE_TZONE_ALLOCATED(ScrollerPairMac);
public:
    void init() CF_SWIFT_UNAVAILABLE("For C++ callers");

    static Ref<ScrollerPairMac> create(ScrollingTreeScrollingNode& node)
    {
        return adoptRef(*new ScrollerPairMac(node));
    }

    ~ScrollerPairMac();

    FloatSize visibleSize() const;

    struct Values {
        float value;
        float proportion;
    };
    Values valuesForOrientation(ScrollbarOrientation);

    RefPtr<ScrollingTreeScrollingNode> node() const { return m_scrollingNode.get(); }

    // The scrollers (ScrollerPairMac.swift).
    MacScrollerPair& scrollers() CF_SWIFT_UNAVAILABLE("For C++ callers");

    // Members for the scroller of one orientation.
    RetainPtr<CALayer> hostLayer(ScrollbarOrientation) const CF_SWIFT_UNAVAILABLE("Use isHostLayer");
    RetainPtr<NSScrollerImp> scrollerImp(ScrollbarOrientation) const CF_SWIFT_UNAVAILABLE("Use setScrollerImpProgress");
    bool isHostLayer(ScrollbarOrientation, CALayer *) const;
    void setScrollerImpProgress(ScrollbarOrientation, ScrollbarPartFeature, double value);
    void setScrollerReferences(ScrollbarOrientation, NSScrollerImp *, CALayer *);

    // Runs the block on the main thread, synchronously if called on the main thread, with the NSScrollerImpPair
    // and the NSScrollerImp, which may be null, keeping this and the NSScrollerImp alive until it has run.
    // The block and what it captures may be released on the calling thread; callers hold this across the call.
    void ensureOnMainThreadWithScrollerImp(NSScrollerImp *, void (^ __attribute__((swift_attr("@Sendable"))))(NSScrollerImpPair *, NSScrollerImp *)) const __attribute__((nonnull(3)));
    // The copy of the scroller's NSScrollerImp, retained for the caller.
    NSScrollerImp *retainedScrollerImp(ScrollbarOrientation) const NS_RETURNS_RETAINED;
private:

    ScrollerPairMac(ScrollingTreeScrollingNode&);

    ThreadSafeWeakPtr<ScrollingTreeScrollingNode> m_scrollingNode;

    std::unique_ptr<ScrollerPairMacState> m_state;
};

}

#endif
