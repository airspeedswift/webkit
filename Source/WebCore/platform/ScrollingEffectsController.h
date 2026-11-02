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
#include <WebCore/ScrollSnapAnimatorState.h>
#include <WebCore/ScrollSnapOffsetsInfo.h>
#include <WebCore/ScrollTypes.h>
#include <WebCore/WheelEventTestMonitor.h>
#include <wtf/Deque.h>
#include <wtf/Noncopyable.h>
#include <wtf/Platform.h>
#include <wtf/RunLoop.h>
#include <wtf/TZoneMalloc.h>

#if !defined(USE_SWIFT_DEAD_CODE_SWEEP)
#define USE_SWIFT_DEAD_CODE_SWEEP 0
#endif

namespace WebCore {

class KeyboardScrollingAnimator;
class LayoutSize;
class PlatformWheelEvent;
class ScrollSnapAnimatorState;
class ScrollingEffectsController;
class ScrollableArea;
class WheelEventTestMonitor;
struct ScrollExtents;

#if USE_SWIFT_SCROLL_PHYSICS
#if !USE_SWIFT_SCROLL_ANIMATOR_PHYSICS
class ScrollPhysicsClient;
struct ScrollPhysicsControllerHolder;
#endif
#endif

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

#if USE_SWIFT_SCROLL_PHYSICS
class WEBCORE_EXPORT ScrollingEffectsController {
#else
class WEBCORE_EXPORT ScrollingEffectsController : public ScrollAnimationClient {
#endif
#if !USE_SWIFT_SCROLL_ANIMATOR_PHYSICS
    WTF_MAKE_NONCOPYABLE(ScrollingEffectsController);
#endif

public:
#if !USE_SWIFT_SCROLL_ANIMATOR_PHYSICS
    explicit ScrollingEffectsController(ScrollingEffectsControllerClient&);
    virtual ~ScrollingEffectsController();

    bool LEGACY_NODELETE usesScrollSnap() const;
    void stopAllTimers();
    void scrollPositionChanged();

    bool startAnimatedScrollToDestination(FloatPoint startOffset, FloatPoint destinationOffset, ScrollAnimationCurve = ScrollAnimationCurve::Default);
    bool retargetAnimatedScroll(FloatPoint newDestinationOffset, ScrollAnimationCurve);
    bool retargetAnimatedScrollBy(FloatSize);
    std::optional<FloatPoint> animatedScrollDestinationOffset() const;

    void stopAnimatedScroll();
    void stopAnimatedNonRubberbandingScroll();
    void stopSpringAnimation();

    void stopKeyboardScrolling();
#endif

#if !USE_SWIFT_SCROLL_PHYSICS
    bool startMomentumScrollWithInitialVelocity(const FloatPoint& initialOffset, const FloatSize& initialVelocity, const FloatSize& initialDelta, NOESCAPE const Function<FloatPoint(const FloatPoint&)>& destinationModifier);

    void willBeginKeyboardScrolling();
    void didStopKeyboardScrolling();
#endif

#if !USE_SWIFT_SCROLL_ANIMATOR_PHYSICS
    bool startKeyboardScroll(const KeyboardScroll&);

    void finishKeyboardScroll(bool immediate);
    
    // Should be called periodically by the client. Started by startAnimationCallback(), stopped by stopAnimationCallback().
    void animationCallback(MonotonicTime);

    void updateGestureInProgressState(const PlatformWheelEvent&);
    
    void contentsSizeChanged();

    void setSnapOffsetsInfo(const LayoutScrollSnapOffsetsInfo&);
    const LayoutScrollSnapOffsetsInfo* LEGACY_NODELETE snapOffsetsInfo() const;
    void setActiveScrollSnapIndexForAxis(ScrollEventAxis, std::optional<unsigned>);
    void updateActiveScrollSnapIndexForClientOffset();
    void resnapAfterLayout();

    std::optional<unsigned> LEGACY_NODELETE activeScrollSnapIndexForAxis(ScrollEventAxis) const;
    float adjustedScrollDestination(ScrollEventAxis, FloatPoint destinationOffset, float velocity, std::optional<float> originalOffset, ScrollSnapPointSelectionMethod = ScrollSnapPointSelectionMethod::Closest) const;

#if USE_SWIFT_SCROLL_PHYSICS
    bool activeScrollSnapIndexDidChange() const;
#else
    bool activeScrollSnapIndexDidChange() const { return m_activeScrollSnapIndexDidChange; }
    // FIXME: This is never called. We never set m_activeScrollSnapIndexDidChange back to false.
    void setScrollSnapIndexDidChange(bool state) { m_activeScrollSnapIndexDidChange = state; }
#endif

    // Returns true if handled.
    bool handleWheelEvent(const PlatformWheelEvent&);

    bool isScrollSnapInProgress() const;
    bool LEGACY_NODELETE isUserScrollInProgress() const;
#endif

#if PLATFORM(MAC)
#if !USE_SWIFT_SCROLL_ANIMATOR_PHYSICS
    // Stops a running spring animation, or ignores the rest of a momentum scroll while one runs. Called before the wheel event
    // scrolls anything, including for events with PlatformWheelEventPhase::MayBegin.
    void handleWheelEventDuringSpringAnimation(const PlatformWheelEvent&);
#endif

    static FloatSize LEGACY_NODELETE wheelDeltaBiasingTowardsVertical(const FloatSize&);
    static bool LEGACY_NODELETE isScrollDeltaOpposingStretch(IntSize stretch, ScrollEventAxis, float delta);

#if !USE_SWIFT_SCROLL_ANIMATOR_PHYSICS
    // Returns true if handled.
    bool processWheelEventForScrollSnap(const PlatformWheelEvent&);

    void stopRubberBanding();
    void startRubberBandSnapBack();
    void rubberBandTargetOffsetDidChange();
    bool LEGACY_NODELETE isRubberBandInProgress() const;
#if USE_SWIFT_SCROLL_PHYSICS
    RectEdges<bool> rubberBandingEdges() const;
#else
    RectEdges<bool> rubberBandingEdges() const { return m_rubberBandingEdges; }
#endif

    std::optional<RubberbandingState> captureRubberbandingState() const;
    bool restoreRubberbandingState(const RubberbandingState&);
#endif
#if !USE_SWIFT_SCROLL_PHYSICS
    bool LEGACY_NODELETE shouldAttemptRubberbandingRestoration(const RubberbandingState&);
#endif
#if HAVE(APPKIT_GESTURES_SUPPORT)
    // Only code under !USE_SWIFT_SCROLL_PHYSICS calls these.
#if !USE_SWIFT_DEAD_CODE_SWEEP
    FloatSize LEGACY_NODELETE computeDampedStretchDelta(FloatSize delta, bool horizontalDeltaOpposesStretch, bool verticalDeltaOpposesStretch);
    float LEGACY_NODELETE deltaAdjustedForRefreshController(float generalDampedHeight, float verticalDelta, float verticalStretch, bool verticalDeltaOpposesStretch);
#endif

    float rubberbandHyperbolicCoefficientForTesting() const { return m_rubberbandHyperbolicCoefficient; }
#else
#if !USE_SWIFT_SCROLL_PHYSICS
    FloatSize LEGACY_NODELETE deltaAdjustedForRefreshController(const FloatSize& adjustedDelta, bool);
#endif
#endif
#endif

private:
#if !USE_SWIFT_SCROLL_ANIMATOR_PHYSICS
    bool isSpringAnimationRunning() const;
#endif

#if !USE_SWIFT_SCROLL_PHYSICS
    void updateRubberBandAnimatingState();

    void setIsAnimatingRubberBand(bool);
    void setIsAnimatingScrollSnap(bool);
    void setIsAnimatingKeyboardScrolling(bool);

    void startScrollSnapAnimation();
    void stopScrollSnapAnimation();
#endif

#if PLATFORM(MAC)
#if !USE_SWIFT_SCROLL_PHYSICS
    bool LEGACY_NODELETE shouldOverrideMomentumScrolling() const;
#endif
#if !USE_SWIFT_SCROLL_ANIMATOR_PHYSICS
    void discreteSnapTransitionTimerFired();
#endif
#if !USE_SWIFT_SCROLL_PHYSICS
    void scheduleDiscreteScrollSnap(const FloatSize& delta);
#endif
#if !USE_SWIFT_SCROLL_ANIMATOR_PHYSICS
    void scrollendTimerFired();
    void scheduleScrollendTimer();
#endif
#if !USE_SWIFT_SCROLL_PHYSICS

    bool modifyScrollDeltaForStretching(const PlatformWheelEvent&, FloatSize&, bool isHorizontallyStretched, bool isVerticallyStretched);
    bool applyScrollDeltaWithStretching(const PlatformWheelEvent&, FloatSize, bool isHorizontallyStretched, bool isVerticallyStretched);

    FloatSize deltaAlignedToPredominantGestureAxis(MonotonicTime, FloatSize);

    void startRubberBandAnimationIfNecessary(const PlatformWheelEvent&);

    bool startRubberBandAnimation(const FloatSize& initialVelocity, const FloatSize& initialOverscroll);
    bool startRubberBandAnimationWithElapsedTime(const FloatSize& initialVelocity, const FloatSize& initialOverscroll, Seconds alreadyElapsed, std::optional<FloatSize> targetOverscroll = std::nullopt);
    void stopRubberBandAnimation();

    void willStartRubberBandAnimation();
    void didStopRubberBandAnimation();

    bool shouldRubberBandOnSide(BoxSide, FloatSize) const;
    bool isRubberBandInProgressInternal() const;
    void updateRubberBandingState();
    void LEGACY_NODELETE updateRubberBandingEdges(IntSize clientStretch);
#endif
#endif

#if !USE_SWIFT_SCROLL_PHYSICS
    void startOrStopAnimationCallbacks();

    void startDeferringWheelEventTestCompletion(WheelEventTestMonitor::DeferReason);
    void stopDeferringWheelEventTestCompletion(WheelEventTestMonitor::DeferReason);

    // ScrollAnimationClient
    void scrollAnimationDidUpdate(ScrollAnimation&, const FloatPoint& /* currentOffset */) final;
    void scrollAnimationWillStart(ScrollAnimation&) final;
    void scrollAnimationDidEnd(ScrollAnimation&) final;
    ScrollExtents scrollExtentsForAnimation(ScrollAnimation&) final;
    FloatSize overscrollAmount(ScrollAnimation&) final;
    FloatPoint scrollOffset(ScrollAnimation&) final;

    void adjustDeltaForSnappingIfNeeded(float& deltaX, float& deltaY);

    void clampDeltaForAllowedAxes(const PlatformWheelEvent&, FloatSize&);
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

#if !USE_SWIFT_SCROLL_ANIMATOR_PHYSICS
    ScrollingEffectsControllerClient& m_client;

#if USE_SWIFT_SCROLL_PHYSICS
    friend class ScrollPhysicsClient;
    template<typename> friend class ScrollSnapPhysicsClient;
    std::unique_ptr<ScrollPhysicsControllerHolder> m_physics;
    std::optional<LayoutScrollSnapOffsetsInfo> m_snapOffsetsInfo;
#else
    std::unique_ptr<ScrollAnimation> m_currentAnimation;

    std::unique_ptr<ScrollSnapAnimatorState> m_scrollSnapState;
    bool m_activeScrollSnapIndexDidChange { false };

    bool m_isRunningAnimatingCallback { false };
    bool m_isAnimatingRubberBand { false };
    bool m_isAnimatingScrollSnap { false };
    bool m_isAnimatingKeyboardScrolling { false };
    bool m_inScrollGesture { false };
#endif
#endif

#if PLATFORM(MAC)
#if !USE_SWIFT_SCROLL_PHYSICS
    MonotonicTime m_lastMomentumScrollTimestamp;
    FloatSize m_unappliedOverscrollDelta;
    FloatSize m_stretchScrollForce;
    FloatSize m_momentumVelocity;

    FloatSize m_scrollingVelocityForScrollSnap;

    bool m_momentumScrollInProgress { false };
    bool m_ignoreMomentumScrolls { false };
    bool m_isRubberBanding { false };

    FloatSize m_cumulativeGestureDelta;
    MonotonicTime m_lastGestureEventTime;
#endif

#if HAVE(APPKIT_GESTURES_SUPPORT)
    float m_rubberbandHyperbolicCoefficient { 0 };
    bool m_gestureBeganAtTop { false };
#elif HAVE(NSREFRESHCONTROLLER)
#if !USE_SWIFT_SCROLL_PHYSICS
    bool m_skipAdditionalDeltaAdjustments { false };
#endif
#endif

#if !USE_SWIFT_SCROLL_PHYSICS
    Deque<FloatSize> m_recentDiscreteWheelDeltas;
#endif
#if !USE_SWIFT_SCROLL_ANIMATOR_PHYSICS
    std::unique_ptr<ScrollingEffectsControllerTimer> m_discreteSnapTransitionTimer;
    std::unique_ptr<ScrollingEffectsControllerTimer> m_discreteScrollendTimer;
#endif

#if HAVE(RUBBER_BANDING)
#if !USE_SWIFT_SCROLL_PHYSICS
    RectEdges<bool> m_rubberBandingEdges;
#endif
#endif

#if !USE_SWIFT_SCROLL_ANIMATOR_PHYSICS
#if ASSERT_ENABLED
    bool m_timersWereStopped { false };
#endif
#endif
#endif
};

} // namespace WebCore
