/*
 * Copyright (c) 2010 Google Inc. All rights reserved.
 * Copyright (C) 2015 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 * 
 *     * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *     * Neither the name of Google Inc. nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include <WebCore/FloatPoint.h>
#include <WebCore/PlatformWheelEvent.h>
#include <WebCore/ScrollingEffectsController.h>
#include <WebCore/Timer.h>
#include <WebCore/WheelEventTestMonitor.h>
#include <wtf/EnumSet.h>
#include <wtf/Forward.h>
#include <wtf/Platform.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class FloatPoint;
class KeyboardScrollingAnimator;
class PlatformTouchEvent;
class ScrollAnimationSmooth;
class ScrollableArea;
class Scrollbar;
class WheelEventTestMonitor;

struct ScrollExtents;

class ScrollingEffectsControllerTimer;

class ScrollAnimatorScrollPhysicsClient;
struct ScrollPhysicsControllerHolder;

class ScrollAnimator {
    WTF_MAKE_TZONE_ALLOCATED(ScrollAnimator);
public:
    static std::unique_ptr<ScrollAnimator> create(ScrollableArea&);

    explicit ScrollAnimator(ScrollableArea&);
    virtual ~ScrollAnimator();

    ScrollableArea& scrollableArea() const { return m_scrollableArea; }

    WEBCORE_EXPORT KeyboardScrollingAnimator* keyboardScrollingAnimator() const;

    enum class ScrollBehavior : uint8_t {
        RespectScrollSnap,
        Paged,
        NeverAnimate,
        DocumentEdge,
    };

    // Computes a scroll destination for the given parameters.  Returns false if
    // already at the destination. Otherwise, starts scrolling towards the
    // destination and returns true. Scrolling may be immediate or animated.
    // The base class implementation always scrolls immediately, never animates.
    WEBCORE_EXPORT bool singleAxisScroll(ScrollEventAxis, float delta, EnumSet<ScrollBehavior>);

    WEBCORE_EXPORT bool scrollToPositionWithoutAnimation(const FloatPoint&, ScrollClamping = ScrollClamping::Clamped);
    WEBCORE_EXPORT bool scrollToPositionWithAnimation(const FloatPoint&, ScrollClamping = ScrollClamping::Clamped, ScrollAnimationCurve = ScrollAnimationCurve::Default);

    WEBCORE_EXPORT bool retargetRunningAnimation(const FloatPoint& newPosition, ScrollAnimationCurve);

    virtual bool handleWheelEvent(const PlatformWheelEvent&);
    virtual bool processWheelEventForScrollSnap(const PlatformWheelEvent&) { return false; }

    WEBCORE_EXPORT void stopKeyboardScrollAnimation();
    
#if PLATFORM(COCOA)
    virtual void handleWheelEventPhase(PlatformWheelEventPhase) { }
#endif

#if ENABLE(TOUCH_EVENTS)
    virtual bool handleTouchEvent(const PlatformTouchEvent&);
#endif

    WEBCORE_EXPORT void cancelAnimations();

    virtual bool isRubberBandInProgress() const { return false; }

    // For TestWebKitAPI: these call the virtual members above from inside WebCore, so that a test does not depend on
    // this class's virtual function table.
    WEBCORE_EXPORT bool handleWheelEventForTesting(const PlatformWheelEvent&);
    WEBCORE_EXPORT bool processWheelEventForScrollSnapForTesting(const PlatformWheelEvent&);
#if PLATFORM(COCOA)
    WEBCORE_EXPORT void handleWheelEventPhaseForTesting(PlatformWheelEventPhase);
#endif
    WEBCORE_EXPORT bool isRubberBandInProgressForTesting() const;

    WEBCORE_EXPORT bool isUserScrollInProgress() const;
    WEBCORE_EXPORT bool isScrollSnapInProgress() const;
    WEBCORE_EXPORT bool usesScrollSnap() const;

    WEBCORE_EXPORT void contentsSizeChanged();

    enum NotifyScrollableArea : bool { No, Yes };
    WEBCORE_EXPORT void setCurrentPosition(const FloatPoint&, NotifyScrollableArea = NotifyScrollableArea::No);
    const FloatPoint& currentPosition() const LIFETIME_BOUND { return m_currentPosition; }

    void setWheelEventTestMonitor(RefPtr<WheelEventTestMonitor>&& testMonitor) { m_wheelEventTestMonitor = testMonitor; }
    WheelEventTestMonitor* wheelEventTestMonitor() const { return m_wheelEventTestMonitor.get(); }

    WEBCORE_EXPORT FloatPoint scrollOffsetAdjustedForSnapping(const FloatPoint& offset, ScrollSnapPointSelectionMethod) const;
    WEBCORE_EXPORT float scrollOffsetAdjustedForSnapping(ScrollEventAxis, const FloatPoint& newOffset, ScrollSnapPointSelectionMethod) const;

    NODELETE WEBCORE_EXPORT bool activeScrollSnapIndexDidChange() const;
    NODELETE WEBCORE_EXPORT std::optional<unsigned> activeScrollSnapIndexForAxis(ScrollEventAxis) const;
    WEBCORE_EXPORT void setActiveScrollSnapIndexForAxis(ScrollEventAxis, std::optional<unsigned> index);
    WEBCORE_EXPORT void setSnapOffsetsInfo(const LayoutScrollSnapOffsetsInfo&);
    NODELETE WEBCORE_EXPORT const LayoutScrollSnapOffsetsInfo* snapOffsetsInfo() const;
    WEBCORE_EXPORT void resnapAfterLayout();

    WEBCORE_EXPORT ScrollAnimationStatus serviceScrollAnimation(MonotonicTime);

    // Replaces the run loop timers createTimer() makes. Pass nullptr to go back to them.
    using TimerFactory = std::unique_ptr<ScrollingEffectsControllerTimer> (*)(Function<void()>&&);
    WEBCORE_EXPORT static void setTimerFactoryForTesting(TimerFactory);

protected:

private:

    void discreteSnapTransitionTimerFired();
    void scheduleScrollendTimer();

    friend class ScrollAnimatorScrollPhysicsClient;
    template<typename> friend class ScrollSnapPhysicsClient;
    friend class KeyboardScrollingAnimator;

    std::unique_ptr<ScrollingEffectsControllerTimer> createTimer(Function<void()>&&);
    void didStopWheelEventScroll();

protected:
    WeakRef<ScrollableArea> m_scrollableArea;
    RefPtr<WheelEventTestMonitor> m_wheelEventTestMonitor;
    std::unique_ptr<ScrollPhysicsControllerHolder> m_physics;
    std::optional<LayoutScrollSnapOffsetsInfo> m_snapOffsetsInfo;
    // Declared so that member destruction stops the snap timer, then the scrollend timer, before m_physics.
    std::unique_ptr<ScrollingEffectsControllerTimer> m_discreteScrollendTimer;
    std::unique_ptr<ScrollingEffectsControllerTimer> m_discreteSnapTransitionTimer;
    FloatPoint m_currentPosition;

    const UniqueRef<KeyboardScrollingAnimator> m_keyboardScrollingAnimator;

private:
    bool m_scrollAnimationScheduled { false };
};

} // namespace WebCore

