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
#if !USE_SWIFT_MAC_SCROLLERS
#include <WebCore/ScrollerMac.h>
#else
#include <WebCore/ScrollTypes.h>
#include <WebCore/UserInterfaceLayoutDirection.h>
#include <wtf/SwiftBridging.h>
#endif
#include <WebCore/ScrollingStateScrollingNode.h>
#include <wtf/RecursiveLockAdapter.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeWeakPtr.h>

OBJC_CLASS NSScrollerImp;
#if !USE_SWIFT_MAC_SCROLLERS
OBJC_CLASS NSScrollerImpPair;
OBJC_CLASS WebScrollerImpPairDelegateMac;
#else
OBJC_CLASS CALayer;
OBJC_CLASS NSScrollerImpPair;
#endif

namespace WebCore {
class PlatformWheelEvent;
class ScrollingTreeScrollingNode;

struct ScrollbarColor;
#if USE_SWIFT_MAC_SCROLLERS
class MacScrollerPair;
struct ScrollerPairMacState;
enum class ScrollerImpPairNotification : uint8_t;
enum class ScrollbarPartFeature : uint8_t;
#endif

}

namespace WebCore {

// Controls a pair of NSScrollerImps via a pair of ScrollerMac. The NSScrollerImps need to remain internal to this class.
class ScrollerPairMac : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<ScrollerPairMac> {
    WTF_MAKE_TZONE_ALLOCATED(ScrollerPairMac);
#if !USE_SWIFT_MAC_SCROLLERS
    friend class ScrollerMac;
#endif
public:
#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    void init();
#else
    void init() CF_SWIFT_UNAVAILABLE("For C++ callers");
#endif

    static Ref<ScrollerPairMac> create(ScrollingTreeScrollingNode& node)
    {
        return adoptRef(*new ScrollerPairMac(node));
    }

    ~ScrollerPairMac();

#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    void handleWheelEventPhase(PlatformWheelEventPhase);

    void setUsePresentationValues(bool);
    bool isUsingPresentationValues() const { return m_usingPresentationValues; }
#endif

#if !USE_SWIFT_MAC_SCROLLERS
    void setVerticalScrollbarPresentationValue(float);
    void setHorizontalScrollbarPresentationValue(float);
#endif

#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    void updateValues();
#endif

    FloatSize visibleSize() const;
#if !USE_SWIFT_MAC_SCROLLERS
    bool LEGACY_NODELETE useDarkAppearance() const;
    ScrollbarWidth LEGACY_NODELETE scrollbarWidthStyle() const;
#endif

    struct Values {
        float value;
        float proportion;
    };
    Values valuesForOrientation(ScrollbarOrientation);

#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    void releaseReferencesToScrollerImpsOnTheMainThread();

    bool hasScrollerImp();

    void viewWillStartLiveResize();
    void viewWillEndLiveResize();
    void contentsSizeChanged();
#endif
#if !USE_SWIFT_MAC_SCROLLERS
    bool inLiveResize() const { return m_inLiveResize; }

    // Only for use by WebScrollerImpPairDelegateMac. Do not use elsewhere!
    ScrollerMac& verticalScroller() { return m_verticalScroller.get(); }
    ScrollerMac& horizontalScroller() { return m_horizontalScroller.get(); }
#endif

#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    String scrollbarStateForOrientation(ScrollbarOrientation) const;

    ScrollbarStyle scrollbarStyle() const { return m_scrollbarStyle; }
    void setScrollbarStyle(ScrollbarStyle);

    void setVerticalScrollerImp(NSScrollerImp *);
    void setHorizontalScrollerImp(NSScrollerImp *);
    
    void mouseEnteredContentArea();
    void mouseExitedContentArea();
    void mouseMovedInContentArea(const MouseLocationState&);
    void mouseIsInScrollbar(ScrollbarHoverState);
    void scrollbarColorChanged(const std::optional<ScrollbarColor>&);
#endif

#if !USE_SWIFT_MAC_SCROLLERS
    NSScrollerImpPair *scrollerImpPair() const { return m_scrollerImpPair.get(); }
#endif
#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    void ensureOnMainThreadWithProtectedThis(Function<void(ScrollerPairMac&)>&&);
#endif
    RefPtr<ScrollingTreeScrollingNode> node() const { return m_scrollingNode.get(); }

#if !USE_SWIFT_MAC_SCROLLERS
    bool mouseInContentArea() const { return m_mouseInContentArea; }
#endif

#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    void setUseDarkAppearance(bool);

    void setScrollbarWidth(ScrollbarWidth);

    void updateScrollbarPainters();
#endif

#if USE_SWIFT_MAC_SCROLLERS
    // The scrollers (ScrollerPairMac.swift).
    MacScrollerPair& scrollers() CF_SWIFT_UNAVAILABLE("For C++ callers");

    // Members for the scroller of one orientation.
    RetainPtr<CALayer> hostLayer(ScrollbarOrientation) const CF_SWIFT_UNAVAILABLE("Use isHostLayer");
    RetainPtr<NSScrollerImp> scrollerImp(ScrollbarOrientation) const CF_SWIFT_UNAVAILABLE("Use setScrollerImpProgress");
    bool isHostLayer(ScrollbarOrientation, CALayer *) const;
    void setScrollerImpProgress(ScrollbarOrientation, ScrollbarPartFeature, double value);
    void setScrollerReferences(ScrollbarOrientation, NSScrollerImp *, CALayer *);

#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    void contentAreaScrolledInDirection(FloatSize);
    void notifyScrollerImpOfMouse(ScrollbarOrientation, bool mouseEntered);
#else
    // Runs the block on the main thread, synchronously if called on the main thread, with the NSScrollerImpPair
    // and the NSScrollerImp, which may be null, keeping this and the NSScrollerImp alive until it has run.
    // The block and what it captures may be released on the calling thread; callers hold this across the call.
    void ensureOnMainThreadWithScrollerImp(NSScrollerImp *, void (^ __attribute__((swift_attr("@Sendable"))))(NSScrollerImpPair *, NSScrollerImp *)) const __attribute__((nonnull(3)));
    // The copy of the scroller's NSScrollerImp, retained for the caller.
    NSScrollerImp *retainedScrollerImp(ScrollbarOrientation) const NS_RETURNS_RETAINED;
#endif
#endif
private:
#if USE_SWIFT_MAC_SCROLLERS
#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    void notifyScrollerImpPair(ScrollerImpPairNotification);
#endif
#endif

    ScrollerPairMac(ScrollingTreeScrollingNode&);

    ThreadSafeWeakPtr<ScrollingTreeScrollingNode> m_scrollingNode;

#if !USE_SWIFT_MAC_SCROLLERS
    ScrollbarHoverState m_scrollbarHoverState;

    const Ref<ScrollerMac> m_verticalScroller;
    const Ref<ScrollerMac> m_horizontalScroller;

    std::optional<FloatPoint> m_lastScrollOffset;

    RetainPtr<NSScrollerImpPair> m_scrollerImpPair;
    const RetainPtr<WebScrollerImpPairDelegateMac> m_scrollerImpPairDelegate;

    ScrollbarWidth m_scrollbarWidth { ScrollbarWidth::Auto };
#else
    std::unique_ptr<ScrollerPairMacState> m_state;
#endif
#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    std::atomic<bool> m_usingPresentationValues { false };
    std::atomic<ScrollbarStyle> m_scrollbarStyle { ScrollbarStyle::AlwaysVisible };
#endif
#if !USE_SWIFT_MAC_SCROLLERS
    bool m_useDarkAppearance { false };
    bool m_inLiveResize { false };
    bool m_mouseInContentArea { false };
#endif
};

}

#endif
