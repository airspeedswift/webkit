/*
 * Copyright (C) 2011, 2014-2015 Apple Inc. All rights reserved.
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

#include <WebCore/FloatPoint.h>
#include <WebCore/FloatSize.h>

#include <WebCore/KeyboardScroll.h>
#include <WebCore/RectEdges.h>
#include <WebCore/RubberbandingState.h>
#include <WebCore/ScrollAnimation.h>
#include <WebCore/ScrollSnapOffsetsInfo.h>
#include <WebCore/ScrollTypes.h>
#include <WebCore/WheelEventTestMonitor.h>
#include <wtf/Deque.h>
#include <wtf/Noncopyable.h>
#include <wtf/Platform.h>
#include <wtf/RunLoop.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class KeyboardScrollingAnimator;
class LayoutSize;
class PlatformWheelEvent;
class ScrollingEffectsController;
class ScrollableArea;
class WheelEventTestMonitor;
struct ScrollExtents;

class ScrollingEffectsControllerTimer : public RunLoop::TimerBase {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(ScrollingEffectsControllerTimer, WEBCORE_EXPORT);
public:
    ScrollingEffectsControllerTimer(RunLoop& runLoop, Function<void()>&& callback)
        : RunLoop::TimerBase(runLoop, "ScrollingEffectsControllerTimer"_s)
        , m_callback(WTF::move(callback))
    {
    }

    void fired() final
    {
        m_callback();
    }

private:
    Function<void()> m_callback;
};

class ScrollingEffectsControllerClient {
protected:
    virtual ~ScrollingEffectsControllerClient() = default;

public:
    // Only used for non-animation timers.
    virtual std::unique_ptr<ScrollingEffectsControllerTimer> createTimer(Function<void()>&&) = 0;

    // Destroys a timer returned by createTimer() on the thread that owns its run loop. A timer may
    // fire on a different thread than the one tearing the controller down (e.g. the scrolling thread),
    // so it must not be stopped or destroyed from the wrong thread. The default destroys it inline,
    // which is correct for clients whose timers run on the calling thread.
    virtual void destroyTimer(std::unique_ptr<ScrollingEffectsControllerTimer>) { }

    virtual void startAnimationCallback(ScrollingEffectsController&) = 0;
    virtual void stopAnimationCallback(ScrollingEffectsController&) = 0;

    virtual KeyboardScrollingAnimator *keyboardScrollingAnimator() const { return nullptr; }

    virtual bool allowsHorizontalScrolling() const = 0;
    virtual bool allowsVerticalScrolling() const = 0;

    virtual void immediateScrollBy(const FloatSize&, ScrollClamping = ScrollClamping::Clamped) = 0;

    // If the current scroll position is within the overhang area, this function will cause
    // the page to scroll to the nearest boundary point.
    virtual void adjustScrollPositionToBoundsIfNecessary() = 0;

#if HAVE(RUBBER_BANDING)
    virtual bool allowsHorizontalStretching(const PlatformWheelEvent&) const = 0;
    virtual bool allowsVerticalStretching(const PlatformWheelEvent&) const = 0;
    virtual IntSize stretchAmount() const = 0;
    virtual bool isScrollDeltaOpposingStretch(ScrollEventAxis, float) const = 0;

    // "Pinned" means scrolled at or beyond the edge.
    virtual bool isPinnedOnSide(BoxSide) const = 0;
    virtual RectEdges<bool> edgePinnedState() const = 0;

    virtual bool shouldRubberBandOnSide(BoxSide, FloatSize) const = 0;

    virtual void willStartRubberBandAnimation() { }
    virtual void didStopRubberBandAnimation() { }

    virtual void rubberBandingStateChanged(bool) { }

    virtual FloatSize rubberBandTargetOffset() const { return { }; }
    virtual bool hasRefreshController() const { return false; }
    virtual float refreshControllerSnappingThreshold() const { return 0; }
#endif

    virtual void deferWheelEventTestCompletionForReason(ScrollingNodeID, WheelEventTestMonitor::DeferReason) const { /* Do nothing */ }
    virtual void removeWheelEventTestCompletionDeferralForReason(ScrollingNodeID, WheelEventTestMonitor::DeferReason) const { /* Do nothing */ }

    virtual FloatPoint scrollOffset() const = 0;

    virtual void willStartAnimatedScroll() { }
    virtual void didStopAnimatedScroll() { }

    virtual void willStartWheelEventScroll() { }
    virtual void didStopWheelEventScroll() { }

    virtual void willStartScrollSnapAnimation() { }
    virtual void didStopScrollSnapAnimation() { }

    virtual float pageScaleFactor() const = 0;
    virtual ScrollExtents scrollExtents() const = 0;
    virtual bool scrollAnimationEnabled() const { return true; }
    virtual ScrollingNodeID scrollingNodeIDForTesting() const = 0;
};

class WEBCORE_EXPORT ScrollingEffectsController {

public:

#if PLATFORM(MAC)

    NODELETE static FloatSize wheelDeltaBiasingTowardsVertical(const FloatSize&);
    NODELETE static bool isScrollDeltaOpposingStretch(IntSize stretch, ScrollEventAxis, float delta);

#if HAVE(APPKIT_GESTURES_SUPPORT)

    float rubberbandHyperbolicCoefficientForTesting() const { return m_rubberbandHyperbolicCoefficient; }
#else
#endif
#endif

private:

#if PLATFORM(MAC)
#endif

#if ENABLE(KINETIC_SCROLLING) && !PLATFORM(MAC)
    // Returns true if handled.
    bool processWheelEventForKineticScrolling(const PlatformWheelEvent&);

    Deque<PlatformWheelEvent> m_scrollHistory;

    struct {
        MonotonicTime startTime;
        FloatPoint initialOffset;
        FloatSize initialVelocity;
    } m_previousKineticAnimationInfo;
#endif

#if PLATFORM(MAC)

#if HAVE(APPKIT_GESTURES_SUPPORT)
    float m_rubberbandHyperbolicCoefficient { 0 };
    bool m_gestureBeganAtTop { false };
#elif HAVE(NSREFRESHCONTROLLER)
#endif

#if HAVE(RUBBER_BANDING)
#endif

#endif
};

} // namespace WebCore
