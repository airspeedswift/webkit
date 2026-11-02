/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

#if USE_SWIFT_SCROLL_ANIMATOR_PHYSICS

#include <WebCore/ScrollAnimator.h>
#include <WebCore/ScrollPhysicsTypes.h>
#if USE_SWIFT_SCROLL_ANIMATOR
#include <WebCore/KeyboardScrollingAnimator.h>
#include <WebCore/ScrollableArea.h>
#include <WebCore/Scrollbar.h>
#include <WebCore/ScrollbarsController.h>
#endif
#include <wtf/ForbidHeapAllocation.h>

namespace WebCore {

// What ScrollAnimator's scroll physics in Swift calls back into: the ScrollAnimator, and the snap offsets and timers
// it holds. Only ScrollAnimatorScrollPhysicsClientState makes one, on the stack of a ScrollAnimator member, for one
// call into Swift.
class __attribute__((swift_attr("~Sendable"))) ScrollAnimatorScrollPhysicsClient : public ScrollSnapPhysicsClient<ScrollAnimatorScrollPhysicsClient> {
public:
    // Swift takes this only inout, and must not copy, move or relocate it. Swift imports the class only if it has a
    // move constructor, so one is declared; it is never called.
    ScrollAnimatorScrollPhysicsClient(const ScrollAnimatorScrollPhysicsClient&) = delete;
    ScrollAnimatorScrollPhysicsClient& operator=(const ScrollAnimatorScrollPhysicsClient&) = delete;
    [[noreturn]] ScrollAnimatorScrollPhysicsClient(ScrollAnimatorScrollPhysicsClient&&);
    ~ScrollAnimatorScrollPhysicsClient();

#if !USE_SWIFT_SCROLL_ANIMATOR
    void startAnimationCallback() { animator().startAnimationCallback(); }
    void stopAnimationCallback() { animator().stopAnimationCallback(); }
#endif

#if !USE_SWIFT_SCROLL_ANIMATOR
    bool allowsHorizontalScrolling() { return constAnimator().allowsHorizontalScrolling(); }
    bool allowsVerticalScrolling() { return constAnimator().allowsVerticalScrolling(); }
    void immediateScrollBy(const FloatSize& delta, ScrollClamping clamping) { animator().immediateScrollBy(delta, clamping); }
#else
    bool allowsHorizontalScrolling() { return area().allowsHorizontalScrolling(); }
    bool allowsVerticalScrolling() { return area().allowsVerticalScrolling(); }
#endif

#if !USE_SWIFT_SCROLL_ANIMATOR
    bool allowsHorizontalStretching(const PlatformWheelEvent& event) { return constAnimator().allowsHorizontalStretching(event); }
    bool allowsVerticalStretching(const PlatformWheelEvent& event) { return constAnimator().allowsVerticalStretching(event); }
    IntSize stretchAmount() { return constAnimator().stretchAmount(); }
    bool isPinnedOnSide(BoxSide side) { return constAnimator().isPinnedOnSide(side); }
#else
    IntSize stretchAmount() { return area().overhangAmount(); }
    bool isPinnedOnSide(BoxSide side) { return area().isPinnedOnSide(side); }
#endif

#if !USE_SWIFT_SCROLL_ANIMATOR
    void deferWheelEventTestCompletion(WheelEventTestMonitor::DeferReason reason) { constAnimator().deferWheelEventTestCompletionForReason(constAnimator().scrollingNodeIDForTesting(), reason); }
    void removeWheelEventTestCompletionDeferral(WheelEventTestMonitor::DeferReason reason) { constAnimator().removeWheelEventTestCompletionDeferralForReason(constAnimator().scrollingNodeIDForTesting(), reason); }
#else
    // The node is read whether or not there is a monitor.
    void deferWheelEventTestCompletion(WheelEventTestMonitor::DeferReason reason)
    {
        auto identifier = area().scrollingNodeIDForTesting();
        if (RefPtr monitor = constAnimator().m_wheelEventTestMonitor)
            monitor->deferForReason(identifier, reason);
    }
    void removeWheelEventTestCompletionDeferral(WheelEventTestMonitor::DeferReason reason)
    {
        auto identifier = area().scrollingNodeIDForTesting();
        if (RefPtr monitor = constAnimator().m_wheelEventTestMonitor)
            monitor->removeDeferralForReason(identifier, reason);
    }
#endif

#if !USE_SWIFT_SCROLL_ANIMATOR
    FloatPoint scrollOffset() { return constAnimator().scrollOffset(); }
    void willStartAnimatedScroll() { animator().willStartAnimatedScroll(); }
    void didStopAnimatedScroll() { animator().didStopAnimatedScroll(); }
#endif
    void didStopWheelEventScroll() { animator().didStopWheelEventScroll(); }
#if !USE_SWIFT_SCROLL_ANIMATOR
    float pageScaleFactor() { return constAnimator().pageScaleFactor(); }
    ScrollExtents scrollExtents() { return constAnimator().scrollExtents(); }
#else
    float pageScaleFactor() { return area().pageScaleFactor(); }
#endif

    // ScrollAnimator's scrollend timer.
    void startScrollendTimer() { animator().scheduleScrollendTimer(); }

#if USE_SWIFT_SCROLL_ANIMATOR
    // ScrollAnimator's and its KeyboardScrollingAnimator's own state.
    FloatPoint currentPosition() { return constAnimator().m_currentPosition; }
    void setCurrentPositionValue(FloatPoint position) { animator().m_currentPosition = position; }
    bool scrollAnimationScheduled() { return constAnimator().m_scrollAnimationScheduled; }
    void setScrollAnimationScheduled(bool scheduled) { animator().m_scrollAnimationScheduled = scheduled; }
    bool hasSnapOffsets() { return !!constAnimator().m_snapOffsetsInfo; }
    bool keyboardScrollTriggeringKeyIsPressed() { return constAnimator().m_keyboardScrollingAnimator->m_scrollTriggeringKeyIsPressed; }
    void setKeyboardScrollTriggeringKeyIsPressed(bool pressed) { animator().m_keyboardScrollingAnimator->m_scrollTriggeringKeyIsPressed = pressed; }

    // The ScrollableArea.
    IntPoint scrollOrigin() { return area().scrollOrigin(); }
    IntPoint minimumScrollPosition() { return area().minimumScrollPosition(); }
    IntPoint maximumScrollPosition() { return area().maximumScrollPosition(); }
    IntPoint scrollPosition() { return area().scrollPosition(); }
    bool scrollOriginChanged() { return area().scrollOriginChanged(); }
    bool scrollAnimatorEnabled() { return area().scrollAnimatorEnabled(); }
    void scrollToPositionWithAnimation(FloatPoint position, FloatSize originalScrollDelta) { area().scrollToPositionWithAnimation(position, ScrollPositionChangeOptions::createProgrammaticWithOptions(ScrollClamping::Clamped, ScrollIsAnimated::No, ScrollSnapPointSelectionMethod::Closest, originalScrollDelta)); }
    void scrollToPositionWithAnimation(FloatPoint position, ScrollAnimationCurve curve)
    {
        auto options = ScrollPositionChangeOptions::createProgrammatic();
        options.animationCurve = curve;
        area().scrollToPositionWithAnimation(position, options);
    }
    bool scroll(ScrollDirection direction, ScrollGranularity granularity) { return area().scroll(direction, granularity); }
    void scrollDidEnd() { area().scrollDidEnd(); }
    bool hasSteppedScrolling() { return area().hasSteppedScrolling(); }
    void clearScrollAnchor() { area().clearScrollAnchor(); }
    void setScrollPositionFromAnimation(IntPoint position) { area().setScrollPositionFromAnimation(position); }
    ScrollClamping scrollClamping() { return area().scrollClamping(); }
    void setScrollClamping(ScrollClamping clamping) { area().setScrollClamping(clamping); }
    IntPoint constrainedScrollPosition(IntPoint position) { return area().constrainedScrollPosition(position); }
    bool isUserScrollInProgress() { return area().isUserScrollInProgress(); }
    void beginKeyboardScroll(const KeyboardScroll& scroll) { area().beginKeyboardScroll(scroll); }
    void endKeyboardScroll(bool immediate) { area().endKeyboardScroll(immediate); }
    float adjustVerticalPageScrollStepForFixedContent(float step) { return area().adjustVerticalPageScrollStepForFixedContent(step); }
    bool hasScrollableOrRubberbandableAncestor() { return area().hasScrollableOrRubberbandableAncestor(); }
    OverscrollBehavior horizontalOverscrollBehavior() { return area().horizontalOverscrollBehavior(); }
    OverscrollBehavior verticalOverscrollBehavior() { return area().verticalOverscrollBehavior(); }
    ScrollElasticity horizontalScrollElasticity() { return area().horizontalScrollElasticity(); }
    ScrollElasticity verticalScrollElasticity() { return area().verticalScrollElasticity(); }
    static std::optional<BoxSide> targetSideForScrollDelta(FloatSize delta, ScrollEventAxis axis) { return ScrollableArea::targetSideForScrollDelta(delta, axis); }
    void setScrollAnimationStatus(ScrollAnimationStatus status) { area().setScrollAnimationStatus(status); }
    void animatedScrollDidEnd() { area().animatedScrollDidEnd(); }
    void didStartScrollAnimation() { area().didStartScrollAnimation(); }
    IntPoint scrollOffsetFromPosition(IntPoint position) { return area().scrollOffsetFromPosition(position); }
    IntSize totalContentsSize() { return area().totalContentsSize(); }
    IntSize visibleSize() { return area().visibleSize(); }
    IntSize snapportSize() { return area().snapportSize(); }

    // The area's scrollbar values, so that Swift is not handed a Scrollbar. A missing scrollbar is not enabled;
    // the step and size getters require one.
    bool hasScrollbar(ScrollbarOrientation orientation) { return !!scrollbar(orientation); }
    bool scrollbarEnabled(ScrollbarOrientation orientation) { auto* bar = scrollbar(orientation); return bar && bar->enabled(); }
    float scrollbarPixelStep(ScrollbarOrientation orientation) { return existingScrollbar(orientation).pixelStep(); }
    int scrollbarLineStep(ScrollbarOrientation orientation) { return existingScrollbar(orientation).lineStep(); }
    int scrollbarPageStep(ScrollbarOrientation orientation) { return existingScrollbar(orientation).pageStep(); }
    int scrollbarTotalSize(ScrollbarOrientation orientation) { return existingScrollbar(orientation).totalSize(); }
    static float pageStepDelta(int widthOrHeight) { return Scrollbar::pageStepDelta(widthOrHeight); }

    // The ScrollbarsController.
    void setScrollbarAnimationsUnsuspendedByUserInteraction(bool unsuspended) { area().scrollbarsController().setScrollbarAnimationsUnsuspendedByUserInteraction(unsuspended); }
    void notifyContentAreaScrolled(FloatSize delta) { area().scrollbarsController().notifyContentAreaScrolled(delta); }
    void cancelScrollbarAnimations() { area().scrollbarsController().cancelAnimations(); }
    void didBeginScrollGesture() { area().scrollbarsController().didBeginScrollGesture(); }
    void didEndScrollGesture() { area().scrollbarsController().didEndScrollGesture(); }
    void mayBeginScrollGesture() { area().scrollbarsController().mayBeginScrollGesture(); }
#endif

protected:
    ScrollAnimatorScrollPhysicsClient() = default;

private:
    friend class ScrollSnapPhysicsClient<ScrollAnimatorScrollPhysicsClient>;

    ScrollAnimator& animator();
    const ScrollAnimator& constAnimator();
#if USE_SWIFT_SCROLL_ANIMATOR
    ScrollableArea& area() { return constAnimator().scrollableArea(); }
    Scrollbar* scrollbar(ScrollbarOrientation orientation) { return orientation == ScrollbarOrientation::Horizontal ? area().horizontalScrollbar() : area().verticalScrollbar(); }
    Scrollbar& existingScrollbar(ScrollbarOrientation orientation) { auto* bar = scrollbar(orientation); RELEASE_ASSERT(bar); return *bar; }
#endif
    const LayoutScrollSnapOffsetsInfo& snapOffsetsInfo() { return *constAnimator().m_snapOffsetsInfo; }
    ScrollAnimator& snapTimerOwner() { return animator(); }
    std::unique_ptr<ScrollingEffectsControllerTimer> createSnapTimer(Function<void()>&& function) { return animator().createTimer(WTF::move(function)); }
};

class ScrollAnimatorScrollPhysicsClientState final : public ScrollAnimatorScrollPhysicsClient {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    explicit ScrollAnimatorScrollPhysicsClientState(ScrollAnimator& animator)
        : m_animator(&animator)
        , m_constAnimator(animator)
#if USE_SWIFT_SCROLL_ANIMATOR
        , m_scrollableArea(animator.scrollableArea())
#endif
    {
    }

    // For ScrollAnimator's const members, which only read the snap offsets and the scroll position.
    explicit ScrollAnimatorScrollPhysicsClientState(const ScrollAnimator& animator)
        : m_animator(nullptr)
        , m_constAnimator(animator)
#if USE_SWIFT_SCROLL_ANIMATOR
        , m_scrollableArea(animator.scrollableArea())
#endif
    {
    }

    ScrollAnimatorScrollPhysicsClient& facade() LIFETIME_BOUND { return *this; }

private:
    friend class ScrollAnimatorScrollPhysicsClient;

    ScrollAnimator* const m_animator;
    const ScrollAnimator& m_constAnimator;
#if USE_SWIFT_SCROLL_ANIMATOR
    // The area must outlive the call into Swift; destroying it during the call crashes.
    const CheckedRef<ScrollableArea> m_scrollableArea;
#endif
};

inline ScrollAnimator& ScrollAnimatorScrollPhysicsClient::animator()
{
    auto* animator = static_cast<ScrollAnimatorScrollPhysicsClientState&>(*this).m_animator;
    RELEASE_ASSERT(animator);
    return *animator;
}

inline const ScrollAnimator& ScrollAnimatorScrollPhysicsClient::constAnimator()
{
    return static_cast<ScrollAnimatorScrollPhysicsClientState&>(*this).m_constAnimator;
}

} // namespace WebCore

#endif // USE_SWIFT_SCROLL_ANIMATOR_PHYSICS
