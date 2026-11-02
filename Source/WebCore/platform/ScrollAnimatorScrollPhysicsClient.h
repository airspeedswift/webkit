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
#if USE_SWIFT_SCROLL_VIEW
#include <WebCore/BoxSides.h>
#include <WebCore/CornerRadii.h>
#include <WebCore/HostWindow.h>
#include <WebCore/ScrollView.h>
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

#if USE_SWIFT_SCROLL_VIEW
    // ScrollView's state, for its members in Swift. Each member reads the view again, and traps if it is gone or the
    // State was not made from a ScrollView.
    ScrollbarMode scrollbarModeValue(ScrollbarOrientation orientation) { auto& view = scrollView(); return orientation == ScrollbarOrientation::Horizontal ? view.m_horizontalScrollbarMode : view.m_verticalScrollbarMode; }
    void setScrollbarModeValue(ScrollbarOrientation orientation, ScrollbarMode mode) { auto& view = scrollView(); (orientation == ScrollbarOrientation::Horizontal ? view.m_horizontalScrollbarMode : view.m_verticalScrollbarMode) = mode; }
    void setScrollbarLock(ScrollbarOrientation orientation) { auto& view = scrollView(); orientation == ScrollbarOrientation::Horizontal ? view.setHorizontalScrollbarLock() : view.setVerticalScrollbarLock(); }
    bool scrollbarsSuppressed() { return scrollView().m_scrollbarsSuppressed; }
    void setScrollbarsSuppressedValue(bool suppressed) { scrollView().m_scrollbarsSuppressed = suppressed; }
    ALWAYS_INLINE unsigned updateScrollbarsPass() { return scrollView().m_updateScrollbarsPass; }
    ALWAYS_INLINE void setUpdateScrollbarsPass(unsigned pass) { scrollView().m_updateScrollbarsPass = pass; }
    IntPoint scrollPositionValue() { return scrollView().m_scrollPosition; }
    void setScrollPositionValue(IntPoint position) { scrollView().m_scrollPosition = position; }
    bool hasDeferredScrollDelta() { return !!scrollView().m_deferredScrollDelta; }
    IntSize deferredScrollDelta() { auto& delta = scrollView().m_deferredScrollDelta; RELEASE_ASSERT(delta); return *delta; }
    void setDeferredScrollDelta(IntSize delta) { scrollView().m_deferredScrollDelta = delta; }
    void clearDeferredScrollDelta() { scrollView().m_deferredScrollDelta = std::nullopt; }
    bool hasDeferredScrollOffsets() { return !!scrollView().m_deferredScrollOffsets; }
    IntPoint deferredScrollOldOffset() { auto& offsets = scrollView().m_deferredScrollOffsets; RELEASE_ASSERT(offsets); return offsets->first; }
    IntPoint deferredScrollNewOffset() { auto& offsets = scrollView().m_deferredScrollOffsets; RELEASE_ASSERT(offsets); return offsets->second; }
    void setDeferredScrollOffsets(IntPoint oldOffset, IntPoint newOffset) { scrollView().m_deferredScrollOffsets = std::make_pair(oldOffset, newOffset); }
    void clearDeferredScrollOffsets() { scrollView().m_deferredScrollOffsets = std::nullopt; }
    bool hasDelegatedScrollingGeometry() { return !!scrollView().m_delegatedScrollingGeometry; }
    FloatRect delegatedExposedViewRect() { auto& geometry = scrollView().m_delegatedScrollingGeometry; RELEASE_ASSERT(geometry); return geometry->exposedViewRect.raw(); }
    void setDelegatedExposedViewRect(FloatRect rect) { auto& geometry = scrollView().m_delegatedScrollingGeometry; RELEASE_ASSERT(geometry); geometry->exposedViewRect = inViewSpace(rect); }
    bool drawPanScrollIcon() { return scrollView().m_drawPanScrollIcon; }
    IntPoint panScrollIconPoint() { return scrollView().m_panScrollIconPoint; }

    // updateScrollbars()'s re-entry guard.
    bool inUpdateScrollbars() { return scrollView().m_inUpdateScrollbars; }
    void setInUpdateScrollbars(bool value) { scrollView().m_inUpdateScrollbars = value; }

    // The view's scrollbar members, read again on each call, as the C++ does. Swift is not handed a Scrollbar.
    bool hasViewScrollbar(ScrollbarOrientation orientation) { return !!memberScrollbar(orientation); }
    ALWAYS_INLINE bool protectViewScrollbar(ScrollbarOrientation orientation) { auto& bar = protectedScrollbar(orientation); bar = memberScrollbar(orientation); return !!bar; }
    void createScrollbarInto(ScrollbarOrientation orientation) { Ref scrollbar = scrollView().createScrollbar(orientation); memberScrollbar(orientation) = WTF::move(scrollbar); }
    void addScrollbarChild(ScrollbarOrientation orientation) { Ref scrollbar = existingMemberScrollbar(orientation); scrollView().addChild(scrollbar); }
    void didAddScrollbar(ScrollbarOrientation orientation) { Ref scrollbar = existingMemberScrollbar(orientation); scrollView().didAddScrollbar(scrollbar.ptr(), orientation); }
    void willRemoveScrollbar(ScrollbarOrientation orientation) { Ref scrollbar = existingMemberScrollbar(orientation); scrollView().willRemoveScrollbar(scrollbar, orientation); }
    void removeScrollbarChild(ScrollbarOrientation orientation) { Ref scrollbar = existingMemberScrollbar(orientation); scrollView().removeChild(scrollbar); }
    void clearScrollbar(ScrollbarOrientation orientation) { memberScrollbar(orientation) = nullptr; }
    int protectedScrollbarOccupiedWidth(ScrollbarOrientation orientation) { return existingProtectedScrollbar(orientation).occupiedWidth(); }
    int protectedScrollbarOccupiedHeight(ScrollbarOrientation orientation) { return existingProtectedScrollbar(orientation).occupiedHeight(); }
    IntRect protectedScrollbarFrameRect(ScrollbarOrientation orientation) { return existingProtectedScrollbar(orientation).frameRect(); }
    void protectedScrollbarSetFrameRect(ScrollbarOrientation orientation, IntRect rect) { existingProtectedScrollbar(orientation).setFrameRect(rect); }
    int protectedScrollbarHeight(ScrollbarOrientation orientation) { return existingProtectedScrollbar(orientation).height(); }
    bool protectedScrollbarIsCustom(ScrollbarOrientation orientation) { return existingProtectedScrollbar(orientation).isCustomScrollbar(); }
    void protectedScrollbarSetSuppressInvalidation(ScrollbarOrientation orientation, bool suppress) { existingProtectedScrollbar(orientation).setSuppressInvalidation(suppress); }
    void protectedScrollbarSetEnabled(ScrollbarOrientation orientation, bool enabled) { existingProtectedScrollbar(orientation).setEnabled(enabled); }
    void protectedScrollbarSetProportion(ScrollbarOrientation orientation, int visibleSize, int totalSize) { existingProtectedScrollbar(orientation).setProportion(visibleSize, totalSize); }
    void protectedScrollbarSetSteps(ScrollbarOrientation orientation, int lineStep, int pageStep) { existingProtectedScrollbar(orientation).setSteps(lineStep, pageStep); }
    void protectedScrollbarStyleChanged(ScrollbarOrientation orientation) { existingProtectedScrollbar(orientation).styleChanged(); }
    static int pixelsPerLineStep(int widthOrHeight) { return Scrollbar::pixelsPerLineStep(widthOrHeight); }
    static int pageStep(int widthOrHeight) { return Scrollbar::pageStep(widthOrHeight); }
    // CornerRadii's corners, which Swift reads only through a pointer.
    static FloatSize cornerRadius(const CornerRadii& radii, BoxCorner corner) { return corner == BoxCorner::TopLeft ? radii.topLeft() : corner == BoxCorner::TopRight ? radii.topRight() : corner == BoxCorner::BottomLeft ? radii.bottomLeft() : radii.bottomRight(); }

    // ScrollView's members, virtual ones included, so that LocalFrameView's overrides run.
    bool prohibitsScrolling() { return scrollView().prohibitsScrolling(); }
    // Out of line: platformWidget() returns an Objective-C object.
    bool hasPlatformWidget();
    void platformSetScrollbarModes() { scrollView().platformSetScrollbarModes(); }
    void platformSetScrollbarsSuppressed(bool repaintOnUnsuppress) { scrollView().platformSetScrollbarsSuppressed(repaintOnUnsuppress); }
    void platformSetScrollPosition(IntPoint position) { scrollView().platformSetScrollPosition(position); }
    void platformSetScrollOrigin(IntPoint origin, bool updatePositionAtAll, bool updatePositionSynchronously) { scrollView().platformSetScrollOrigin(origin, updatePositionAtAll, updatePositionSynchronously); }
    void scrollbarModesDidChange() { scrollView().scrollbarModesDidChange(); }
    bool isRubberBandInProgress() { return scrollView().isRubberBandInProgress(); }
    IntPoint adjustScrollPositionWithinRange(IntPoint position) { return scrollView().adjustScrollPositionWithinRange(position); }
    void scrollToPositionWithoutAnimation(FloatPoint position) { scrollView().ScrollableArea::scrollToPositionWithoutAnimation(position); }
    void resetScrollOriginChanged() { scrollView().resetScrollOriginChanged(); }
    void setAreaScrollOrigin(IntPoint origin) { scrollView().ScrollableArea::setScrollOrigin(origin); }
    bool canShowNonOverlayScrollbars() { return scrollView().canShowNonOverlayScrollbars(); }
    void updateContentsSize() { scrollView().updateContentsSize(); }
    void availableContentSizeChangedByScrollbars() { scrollView().availableContentSizeChanged(ScrollableArea::AvailableSizeChangeReason::ScrollbarsChanged); }
    void addedOrRemovedScrollbar() { scrollView().addedOrRemovedScrollbar(); }
    IntRect unobscuredContentRectIncludingScrollbars() { return scrollView().unobscuredContentRectIncludingScrollbars(); }
    IntSize contentsSize() { return scrollView().contentsSize(); }
    FloatBoxExtent obscuredContentInsets() { return scrollView().obscuredContentInsets(); }
    CornerRadii scrollbarAvoidanceCornerRadii() { return scrollView().scrollbarAvoidanceCornerRadii(); }
    bool shouldPlaceVerticalScrollbarOnLeft() { return scrollView().shouldPlaceVerticalScrollbarOnLeft(); }
    IntRect frameRect() { return scrollView().frameRect(); }
    bool hasOverlayScrollbars() { return scrollView().hasOverlayScrollbars(); }
    void positionScrollbarLayers() { scrollView().positionScrollbarLayers(); }
    void frameRectsChanged() { scrollView().frameRectsChanged(); }
    void updateScrollCorner() { scrollView().updateScrollCorner(); }
    void invalidateRect(IntRect rect) { scrollView().invalidateRect(rect); }
    void updateLayerPositionsAfterScrolling() { scrollView().updateLayerPositionsAfterScrolling(); }
    void updateCompositingLayersAfterScrolling() { scrollView().updateCompositingLayersAfterScrolling(); }
    bool shouldDeferScrollUpdateAfterContentSizeChange() { return scrollView().shouldDeferScrollUpdateAfterContentSizeChange(); }
    void scrollOffsetChangedViaPlatformWidgetImpl(IntPoint oldOffset, IntPoint newOffset) { scrollView().scrollOffsetChangedViaPlatformWidgetImpl(oldOffset, newOffset); }
    void stopAsyncAnimatedScroll() { scrollView().stopAsyncAnimatedScroll(); }
    bool delegatesScrollingToNativeView() { return scrollView().delegatesScrollingToNativeView(); }
    ALWAYS_INLINE void updateScrollbarSteps() { scrollView().updateScrollbarSteps(); }
    bool canBlitOnScroll() { return scrollView().canBlitOnScroll(); }
    IntRect windowClipRect() { return scrollView().windowClipRect(); }
    bool scrollContentsFastPath(IntSize scrollDelta, IntRect rectToScroll, IntRect clipRect) { return scrollView().scrollContentsFastPath(scrollDelta, rectToScroll, clipRect); }
    void scrollContentsSlowPath(IntRect updateRect) { scrollView().scrollContentsSlowPath(updateRect); }
    IntRect convertToRootView(IntRect rect) { return scrollView().convertToRootView(rect); }
    bool requestScrollViewScrollToPosition(IntPoint position, ScrollType type, ScrollClamping clamping, ScrollIsAnimated animated, ScrollSnapPointSelectionMethod method, bool hasOriginalScrollDelta, FloatSize originalScrollDelta, ScrollInterruptsAnimation interruptsAnimation, ScrollAnimationCurve curve) { return scrollView().requestScrollToPosition(position, { type, clamping, animated, method, hasOriginalScrollDelta ? std::optional { originalScrollDelta } : std::nullopt, interruptsAnimation, curve }); }

    // Whether the view has a host window. Each host window call reads it again, since code run in between can
    // change it. Swift is not handed it.
    bool hasHostWindow() { return !!scrollView().hostWindow(); }
    void hostWindowInvalidateRootView(IntRect rect) { existingHostWindow().invalidateRootView(rect); }
    void hostWindowInvalidateContentsAndRootView(IntRect rect) { existingHostWindow().invalidateContentsAndRootView(rect); }
#endif
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
#if USE_SWIFT_SCROLL_VIEW
    ScrollView& scrollView();
    RefPtr<Scrollbar>& memberScrollbar(ScrollbarOrientation orientation) { auto& view = scrollView(); return orientation == ScrollbarOrientation::Horizontal ? view.m_horizontalScrollbar : view.m_verticalScrollbar; }
    Scrollbar& existingMemberScrollbar(ScrollbarOrientation orientation) { auto& bar = memberScrollbar(orientation); RELEASE_ASSERT(bar); return *bar; }
    HostWindow& existingHostWindow() { auto* hostWindow = scrollView().hostWindow(); RELEASE_ASSERT(hostWindow); return *hostWindow; }
#endif
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

#if USE_SWIFT_SCROLL_VIEW
    // For ScrollView's members.
    explicit ScrollAnimatorScrollPhysicsClientState(ScrollView& view) : ScrollAnimatorScrollPhysicsClientState(static_cast<ScrollableArea&>(view)) { m_isScrollView = true; }

    // Traps if the view was destroyed during the call, before the CheckedRef is released.
    ~ScrollAnimatorScrollPhysicsClientState() { RELEASE_ASSERT(m_liveArea.ptrAllowingHashTableEmptyValue()); }
#endif
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
#if USE_SWIFT_SCROLL_VIEW
    bool m_isScrollView { false };
#endif
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

#if USE_SWIFT_SCROLL_VIEW
inline ScrollView& ScrollAnimatorScrollPhysicsClient::scrollView()
{
    auto& state = static_cast<ScrollAnimatorScrollPhysicsClientState&>(*this);
    auto& area = state.m_liveArea.get();
    RELEASE_ASSERT(state.m_isScrollView);
    return uncheckedDowncast<ScrollView>(area);
}
#endif
#endif

} // namespace WebCore

#endif // USE_SWIFT_SCROLL_ANIMATOR_PHYSICS
