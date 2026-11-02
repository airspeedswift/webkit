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
#if !USE_SWIFT_SCROLLABLE_AREA
        auto identifier = area().scrollingNodeIDForTesting();
#else
        auto identifier = mutableArea().scrollingNodeIDForTesting();
#endif
        if (RefPtr monitor = constAnimator().m_wheelEventTestMonitor)
            monitor->deferForReason(identifier, reason);
    }
    void removeWheelEventTestCompletionDeferral(WheelEventTestMonitor::DeferReason reason)
    {
#if !USE_SWIFT_SCROLLABLE_AREA
        auto identifier = area().scrollingNodeIDForTesting();
#else
        auto identifier = mutableArea().scrollingNodeIDForTesting();
#endif
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
#if !USE_SWIFT_SCROLLABLE_AREA
    void scrollToPositionWithAnimation(FloatPoint position, FloatSize originalScrollDelta) { area().scrollToPositionWithAnimation(position, ScrollPositionChangeOptions::createProgrammaticWithOptions(ScrollClamping::Clamped, ScrollIsAnimated::No, ScrollSnapPointSelectionMethod::Closest, originalScrollDelta)); }
    void scrollToPositionWithAnimation(FloatPoint position, ScrollAnimationCurve curve)
    {
        auto options = ScrollPositionChangeOptions::createProgrammatic();
        options.animationCurve = curve;
        area().scrollToPositionWithAnimation(position, options);
    }
    bool scroll(ScrollDirection direction, ScrollGranularity granularity) { return area().scroll(direction, granularity); }
    void scrollDidEnd() { area().scrollDidEnd(); }
#else
    void scrollDidEnd() { mutableArea().scrollDidEnd(); }
#endif
    bool hasSteppedScrolling() { return area().hasSteppedScrolling(); }
#if !USE_SWIFT_SCROLLABLE_AREA
    void clearScrollAnchor() { area().clearScrollAnchor(); }
#else
    void clearScrollAnchor() { mutableArea().clearScrollAnchor(); }
#endif
#if !USE_SWIFT_SCROLLABLE_AREA
    void setScrollPositionFromAnimation(IntPoint position) { area().setScrollPositionFromAnimation(position); }
#endif
    ScrollClamping scrollClamping() { return area().scrollClamping(); }
#if !USE_SWIFT_SCROLLABLE_AREA
    void setScrollClamping(ScrollClamping clamping) { area().setScrollClamping(clamping); }
#else
    void setScrollClamping(ScrollClamping clamping) { mutableArea().setScrollClamping(clamping); }
#endif
    IntPoint constrainedScrollPosition(IntPoint position) { return area().constrainedScrollPosition(position); }
    bool isUserScrollInProgress() { return area().isUserScrollInProgress(); }
#if !USE_SWIFT_SCROLLABLE_AREA
    void beginKeyboardScroll(const KeyboardScroll& scroll) { area().beginKeyboardScroll(scroll); }
    void endKeyboardScroll(bool immediate) { area().endKeyboardScroll(immediate); }
    float adjustVerticalPageScrollStepForFixedContent(float step) { return area().adjustVerticalPageScrollStepForFixedContent(step); }
    bool hasScrollableOrRubberbandableAncestor() { return area().hasScrollableOrRubberbandableAncestor(); }
#else
    float adjustVerticalPageScrollStepForFixedContent(float step) { return mutableArea().adjustVerticalPageScrollStepForFixedContent(step); }
    bool hasScrollableOrRubberbandableAncestor() { return mutableArea().hasScrollableOrRubberbandableAncestor(); }
#endif
    OverscrollBehavior horizontalOverscrollBehavior() { return area().horizontalOverscrollBehavior(); }
    OverscrollBehavior verticalOverscrollBehavior() { return area().verticalOverscrollBehavior(); }
    ScrollElasticity horizontalScrollElasticity() { return area().horizontalScrollElasticity(); }
    ScrollElasticity verticalScrollElasticity() { return area().verticalScrollElasticity(); }
#if !USE_SWIFT_SCROLLABLE_AREA
    static std::optional<BoxSide> targetSideForScrollDelta(FloatSize delta, ScrollEventAxis axis) { return ScrollableArea::targetSideForScrollDelta(delta, axis); }
    void setScrollAnimationStatus(ScrollAnimationStatus status) { area().setScrollAnimationStatus(status); }
    void animatedScrollDidEnd() { area().animatedScrollDidEnd(); }
    void didStartScrollAnimation() { area().didStartScrollAnimation(); }
#else
    void setScrollAnimationStatus(ScrollAnimationStatus status) { mutableArea().setScrollAnimationStatus(status); }
    void animatedScrollDidEnd() { mutableArea().animatedScrollDidEnd(); }
    void didStartScrollAnimation() { mutableArea().didStartScrollAnimation(); }
#endif
#if !USE_SWIFT_SCROLLABLE_AREA
    IntPoint scrollOffsetFromPosition(IntPoint position) { return area().scrollOffsetFromPosition(position); }
#endif
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
#if !USE_SWIFT_SCROLLABLE_AREA
    void setScrollbarAnimationsUnsuspendedByUserInteraction(bool unsuspended) { area().scrollbarsController().setScrollbarAnimationsUnsuspendedByUserInteraction(unsuspended); }
    void notifyContentAreaScrolled(FloatSize delta) { area().scrollbarsController().notifyContentAreaScrolled(delta); }
    void cancelScrollbarAnimations() { area().scrollbarsController().cancelAnimations(); }
    void didBeginScrollGesture() { area().scrollbarsController().didBeginScrollGesture(); }
    void didEndScrollGesture() { area().scrollbarsController().didEndScrollGesture(); }
    void mayBeginScrollGesture() { area().scrollbarsController().mayBeginScrollGesture(); }
#else
    void setScrollbarAnimationsUnsuspendedByUserInteraction(bool unsuspended) { mutableArea().scrollbarsController().setScrollbarAnimationsUnsuspendedByUserInteraction(unsuspended); }
    void notifyContentAreaScrolled(FloatSize delta) { mutableArea().scrollbarsController().notifyContentAreaScrolled(delta); }
    void cancelScrollbarAnimations() { mutableArea().scrollbarsController().cancelAnimations(); }
    void didBeginScrollGesture() { mutableArea().scrollbarsController().didBeginScrollGesture(); }
    void didEndScrollGesture() { mutableArea().scrollbarsController().didEndScrollGesture(); }
    void mayBeginScrollGesture() { mutableArea().scrollbarsController().mayBeginScrollGesture(); }
#endif
#endif

#if USE_SWIFT_SCROLLABLE_AREA
    // The ScrollableArea's members that its scrolling members in Swift call.
    void setScrollOffset(IntPoint offset) { mutableArea().setScrollOffset(offset); }
    bool requestScrollToPosition(IntPoint position, ScrollType type, ScrollClamping clamping, ScrollIsAnimated animated, ScrollSnapPointSelectionMethod method, bool hasOriginalScrollDelta, FloatSize originalScrollDelta, ScrollAnimationCurve curve) { return mutableArea().requestScrollToPosition(position, { type, clamping, animated, method, hasOriginalScrollDelta ? std::optional { originalScrollDelta } : std::nullopt, ScrollInterruptsAnimation::Yes, curve }); }
    bool requestStartKeyboardScrollAnimation(const KeyboardScroll& scroll) { return mutableArea().requestStartKeyboardScrollAnimation(scroll); }
    bool requestStopKeyboardScrollAnimation(bool immediate) { return mutableArea().requestStopKeyboardScrollAnimation(immediate); }
    void scrollAnchoringScrollPositionDidChange();
    void updateAnchorPositionedAfterScroll() { mutableArea().updateAnchorPositionedAfterScroll(); }
    bool isScrollSnapInProgress() { return area().isScrollSnapInProgress(); }
    bool isInStableState() { return area().isInStableState(); }
    ScrollAnimationStatus scrollAnimationStatus() { return mutableArea().scrollAnimationStatus(); }
    ScrollType currentScrollType() { return area().currentScrollType(); }
    bool hasLayerForHorizontalScrollbar() { return area().hasLayerForHorizontalScrollbar(); }
    bool hasLayerForVerticalScrollbar() { return area().hasLayerForVerticalScrollbar(); }
    bool hasScrollAnimator() { return !!area().existingScrollAnimator(); }
    ScrollbarPart scrollbarPressedPart(ScrollbarOrientation orientation) { return existingScrollbar(orientation).pressedPart(); }
    OptionalSnapPointIndex activeScrollSnapIndex(ScrollEventAxis axis) { return axis == ScrollEventAxis::Horizontal ? area().currentHorizontalSnapPointIndex() : area().currentVerticalSnapPointIndex(); }
    void notifyContentAreaScrolledFrom(IntPoint oldPosition) { mutableArea().scrollbarsController().notifyContentAreaScrolled(area().scrollPosition() - oldPosition); }

    // A ScrollTypeScope for Swift; the State ends one Swift leaves open.
    void beginScrollTypeScope(ScrollType type) { scrollTypeScope().emplace(mutableArea(), type); }
    void endScrollTypeScope() { scrollTypeScope().reset(); }

    // The scrollbars, held across their updates: protectScrollbars() fetches the vertical one first. Swift is not
    // handed a Scrollbar.
    void protectScrollbars() { protectedScrollbar(ScrollbarOrientation::Vertical) = mutableArea().verticalScrollbar(); protectedScrollbar(ScrollbarOrientation::Horizontal) = mutableArea().horizontalScrollbar(); }
    bool protectScrollbar(ScrollbarOrientation orientation) { auto& bar = protectedScrollbar(orientation); bar = orientation == ScrollbarOrientation::Horizontal ? mutableArea().horizontalScrollbar() : mutableArea().verticalScrollbar(); return !!bar; }
    void releaseProtectedScrollbar(ScrollbarOrientation orientation) { protectedScrollbar(orientation) = nullptr; }
    int protectedScrollbarLineStep(ScrollbarOrientation orientation) { return existingProtectedScrollbar(orientation).lineStep(); }
    int protectedScrollbarPageStep(ScrollbarOrientation orientation) { return existingProtectedScrollbar(orientation).pageStep(); }
    int protectedScrollbarTotalSize(ScrollbarOrientation orientation) { return existingProtectedScrollbar(orientation).totalSize(); }
    float protectedScrollbarPixelStep(ScrollbarOrientation orientation) { return existingProtectedScrollbar(orientation).pixelStep(); }
    bool hasProtectedScrollbar(ScrollbarOrientation orientation) { return !!protectedScrollbar(orientation); }
    void protectedScrollbarOffsetDidChange(ScrollbarOrientation orientation) { existingProtectedScrollbar(orientation).offsetDidChange(); }
    bool protectedScrollbarIsOverlay(ScrollbarOrientation orientation) { return existingProtectedScrollbar(orientation).isOverlayScrollbar(); }
    void protectedScrollbarInvalidate(ScrollbarOrientation orientation) { existingProtectedScrollbar(orientation).invalidate(); }
    IntRect protectedScrollbarBoundsRect(ScrollbarOrientation orientation) { return existingProtectedScrollbar(orientation).boundsRect(); }
    int protectedScrollbarWidth(ScrollbarOrientation orientation) { return existingProtectedScrollbar(orientation).width(); }
    void protectedScrollbarInvalidateRect(ScrollbarOrientation orientation, IntRect rect) { existingProtectedScrollbar(orientation).invalidateRect(rect); }

    // The area's ScrollAnimator, created on first use as scrollAnimator() does.
    bool animatorSingleAxisScroll(ScrollEventAxis axis, float delta, bool paged, bool documentEdge)
    {
        EnumSet<ScrollAnimator::ScrollBehavior> behavior = ScrollAnimator::ScrollBehavior::RespectScrollSnap;
        behavior.set(ScrollAnimator::ScrollBehavior::Paged, paged);
        behavior.set(ScrollAnimator::ScrollBehavior::DocumentEdge, documentEdge);
        return animator().singleAxisScroll(axis, delta, behavior);
    }
    bool animatorScrollToPositionWithoutAnimation(FloatPoint position, ScrollClamping clamping) { return animator().scrollToPositionWithoutAnimation(position, clamping); }
    bool animatorScrollToPositionWithAnimation(FloatPoint position, ScrollClamping clamping, ScrollAnimationCurve curve) { return animator().scrollToPositionWithAnimation(position, clamping, curve); }
    bool animatorRetargetRunningAnimation(FloatPoint position, ScrollAnimationCurve curve) { return animator().retargetRunningAnimation(position, curve); }
    void animatorCancelAnimations() { animator().cancelAnimations(); }
    void animatorSetCurrentPosition(FloatPoint position) { animator().setCurrentPosition(position); }
    void animatorResnapAfterLayout() { animator().resnapAfterLayout(); }
    float animatorScrollOffsetAdjustedForSnapping(ScrollEventAxis axis, FloatPoint offset, ScrollSnapPointSelectionMethod method) { return constAnimator().scrollOffsetAdjustedForSnapping(axis, offset, method); }
#endif

protected:
    ScrollAnimatorScrollPhysicsClient() = default;

private:
    friend class ScrollSnapPhysicsClient<ScrollAnimatorScrollPhysicsClient>;

    ScrollAnimator& animator();
    const ScrollAnimator& constAnimator();
#if USE_SWIFT_SCROLL_ANIMATOR
#if !USE_SWIFT_SCROLLABLE_AREA
    ScrollableArea& area() { return constAnimator().scrollableArea(); }
#else
    const ScrollableArea& area();
    // Traps in a State made from a const ScrollAnimator, whose members only read.
    ScrollableArea& mutableArea();
    std::optional<ScrollTypeScope>& scrollTypeScope();
    RefPtr<Scrollbar>& protectedScrollbar(ScrollbarOrientation);
    // Out of line, so that animator() and constAnimator() inline.
    NEVER_INLINE void createAnimator(ScrollableArea&);
    Scrollbar& existingProtectedScrollbar(ScrollbarOrientation orientation) { auto& bar = protectedScrollbar(orientation); RELEASE_ASSERT(bar); return *bar; }
#endif
    Scrollbar* scrollbar(ScrollbarOrientation orientation) { return orientation == ScrollbarOrientation::Horizontal ? area().horizontalScrollbar() : area().verticalScrollbar(); }
    Scrollbar& existingScrollbar(ScrollbarOrientation orientation) { auto* bar = scrollbar(orientation); RELEASE_ASSERT(bar); return *bar; }
#endif
#if !USE_SWIFT_SCROLLABLE_AREA
    const LayoutScrollSnapOffsetsInfo& snapOffsetsInfo() { return *constAnimator().m_snapOffsetsInfo; }
#else
    const LayoutScrollSnapOffsetsInfo& snapOffsetsInfo();
#endif
    ScrollAnimator& snapTimerOwner() { return animator(); }
    std::unique_ptr<ScrollingEffectsControllerTimer> createSnapTimer(Function<void()>&& function) { return animator().createTimer(WTF::move(function)); }
};

class ScrollAnimatorScrollPhysicsClientState final : public ScrollAnimatorScrollPhysicsClient {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    explicit ScrollAnimatorScrollPhysicsClientState(ScrollAnimator& animator)
        : m_animator(&animator)
#if !USE_SWIFT_SCROLLABLE_AREA
        , m_constAnimator(animator)
#else
        , m_constAnimator(&animator)
#endif
#if USE_SWIFT_SCROLL_ANIMATOR
        , m_scrollableArea(animator.scrollableArea())
#endif
#if USE_SWIFT_SCROLLABLE_AREA
        , m_liveArea(animator.scrollableArea())
#endif
    {
    }

    // For ScrollAnimator's const members, which only read the snap offsets and the scroll position.
    explicit ScrollAnimatorScrollPhysicsClientState(const ScrollAnimator& animator)
        : m_animator(nullptr)
#if !USE_SWIFT_SCROLLABLE_AREA
        , m_constAnimator(animator)
#else
        , m_constAnimator(&animator)
#endif
#if USE_SWIFT_SCROLL_ANIMATOR
        , m_scrollableArea(animator.scrollableArea())
#endif
#if USE_SWIFT_SCROLLABLE_AREA
        , m_liveArea(animator.scrollableArea())
#endif
    {
    }

#if USE_SWIFT_SCROLLABLE_AREA
    // For ScrollableArea's members, which create the animator only where they use it.
    explicit ScrollAnimatorScrollPhysicsClientState(ScrollableArea& area)
        : m_animator(area.existingScrollAnimator())
        , m_constAnimator(m_animator)
        , m_scrollableArea(area)
        , m_liveArea(area)
    {
    }
#endif

    ScrollAnimatorScrollPhysicsClient& facade() LIFETIME_BOUND { return *this; }

private:
    friend class ScrollAnimatorScrollPhysicsClient;

#if !USE_SWIFT_SCROLLABLE_AREA
    ScrollAnimator* const m_animator;
    const ScrollAnimator& m_constAnimator;
#else
    // Both null until first use in a State made from an area that has no animator yet; only m_animator null in one
    // made from a const animator.
    ScrollAnimator* m_animator;
    const ScrollAnimator* m_constAnimator;
#endif
#if USE_SWIFT_SCROLL_ANIMATOR
    // The area must outlive the call into Swift; destroying it during the call crashes.
    const CheckedRef<ScrollableArea> m_scrollableArea;
#endif
#if USE_SWIFT_SCROLLABLE_AREA
    // Cleared when the area is destroyed, which the CheckedRef detects only when the State is. Every member that
    // reaches the area or its animator checks it first.
    const WeakRef<ScrollableArea> m_liveArea;
    std::optional<ScrollTypeScope> m_scrollTypeScope;
    RefPtr<Scrollbar> m_horizontalScrollbar;
    RefPtr<Scrollbar> m_verticalScrollbar;
    // The address of the animator's snap offsets, fixed while the animator lives.
    const LayoutScrollSnapOffsetsInfo* m_snapOffsetsInfo { nullptr };
#endif
};

inline ScrollAnimator& ScrollAnimatorScrollPhysicsClient::animator()
{
#if !USE_SWIFT_SCROLLABLE_AREA
    auto* animator = static_cast<ScrollAnimatorScrollPhysicsClientState&>(*this).m_animator;
    RELEASE_ASSERT(animator);
    return *animator;
#else
    auto& state = static_cast<ScrollAnimatorScrollPhysicsClientState&>(*this);
    auto& area = state.m_liveArea.get();
    if (!state.m_constAnimator) [[unlikely]]
        createAnimator(area);
    RELEASE_ASSERT(state.m_animator);
    return *state.m_animator;
#endif
}

inline const ScrollAnimator& ScrollAnimatorScrollPhysicsClient::constAnimator()
{
#if !USE_SWIFT_SCROLLABLE_AREA
    return static_cast<ScrollAnimatorScrollPhysicsClientState&>(*this).m_constAnimator;
#else
    auto& state = static_cast<ScrollAnimatorScrollPhysicsClientState&>(*this);
    auto& area = state.m_liveArea.get();
    if (!state.m_constAnimator) [[unlikely]]
        createAnimator(area);
    return *state.m_constAnimator;
#endif
}

#if USE_SWIFT_SCROLLABLE_AREA
// Called only after hasSnapOffsets(), which creates the animator if the area has none. Each call checks that the
// area is alive and still has snap offsets: code run since the previous call can have changed either.
inline const LayoutScrollSnapOffsetsInfo& ScrollAnimatorScrollPhysicsClient::snapOffsetsInfo()
{
    auto& state = static_cast<ScrollAnimatorScrollPhysicsClientState&>(*this);
    RELEASE_ASSERT(state.m_liveArea.ptr() && state.m_constAnimator && state.m_constAnimator->m_snapOffsetsInfo);
    if (!state.m_snapOffsetsInfo) [[unlikely]]
        state.m_snapOffsetsInfo = &*state.m_constAnimator->m_snapOffsetsInfo;
    return *state.m_snapOffsetsInfo;
}
inline const ScrollableArea& ScrollAnimatorScrollPhysicsClient::area() { return static_cast<ScrollAnimatorScrollPhysicsClientState&>(*this).m_liveArea.get(); }
inline ScrollableArea& ScrollAnimatorScrollPhysicsClient::mutableArea()
{
    auto& state = static_cast<ScrollAnimatorScrollPhysicsClientState&>(*this);
    auto& area = state.m_liveArea.get();
    RELEASE_ASSERT(state.m_animator || !state.m_constAnimator);
    return area;
}
inline std::optional<ScrollTypeScope>& ScrollAnimatorScrollPhysicsClient::scrollTypeScope() { return static_cast<ScrollAnimatorScrollPhysicsClientState&>(*this).m_scrollTypeScope; }
inline RefPtr<Scrollbar>& ScrollAnimatorScrollPhysicsClient::protectedScrollbar(ScrollbarOrientation orientation)
{
    auto& state = static_cast<ScrollAnimatorScrollPhysicsClientState&>(*this);
    return orientation == ScrollbarOrientation::Horizontal ? state.m_horizontalScrollbar : state.m_verticalScrollbar;
}
#endif

} // namespace WebCore

#endif // USE_SWIFT_SCROLL_ANIMATOR_PHYSICS
