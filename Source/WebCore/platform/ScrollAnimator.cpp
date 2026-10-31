/*
 * Copyright (C) 2014-2015 Apple Inc. All rights reserved.
 * Copyright (c) 2010 Google Inc. All rights reserved.
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

#include "config.h"
#include "ScrollAnimator.h"

#include "FloatPoint.h"
#include "KeyboardScrollingAnimator.h"
#include "LayoutSize.h"
#include "Logging.h"
#include "PlatformWheelEvent.h"
#include "ScrollExtents.h"
#include "ScrollableArea.h"
#include "ScrollbarsController.h"
#include "ScrollingEffectsController.h"
#include <algorithm>
#include <wtf/TZoneMallocInlines.h>

#include "ScrollAnimatorScrollPhysicsClient.h"
#include "ScrollPhysicsControllerHolder.h"

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollAnimator);

// Swift may use ScrollAnimatorScrollPhysicsClient only in place (ScrollAnimatorScrollPhysicsClient.h).
static_assert(std::is_empty_v<ScrollAnimatorScrollPhysicsClient>);
static_assert(!std::is_polymorphic_v<ScrollAnimatorScrollPhysicsClient>);
static_assert(!std::is_default_constructible_v<ScrollAnimatorScrollPhysicsClient>);
static_assert(!std::is_copy_constructible_v<ScrollAnimatorScrollPhysicsClient>);
static_assert(!std::is_copy_assignable_v<ScrollAnimatorScrollPhysicsClient>);
static_assert(!std::is_move_assignable_v<ScrollAnimatorScrollPhysicsClient>);
static_assert(std::is_move_constructible_v<ScrollAnimatorScrollPhysicsClient>);
static_assert(!std::is_trivially_destructible_v<ScrollAnimatorScrollPhysicsClient>);

ScrollAnimatorScrollPhysicsClient::ScrollAnimatorScrollPhysicsClient(ScrollAnimatorScrollPhysicsClient&&)
{
    RELEASE_ASSERT_NOT_REACHED();
}

ScrollAnimatorScrollPhysicsClient::~ScrollAnimatorScrollPhysicsClient() = default;

#if !PLATFORM(IOS_FAMILY) && !PLATFORM(MAC)
std::unique_ptr<ScrollAnimator> ScrollAnimator::create(ScrollableArea& scrollableArea)
{
    return makeUnique<ScrollAnimator>(scrollableArea);
}
#endif

ScrollAnimator::ScrollAnimator(ScrollableArea& scrollableArea)
    : m_scrollableArea(scrollableArea)
    , m_physics(makeUnique<ScrollPhysicsControllerHolder>())
    , m_keyboardScrollingAnimator(makeUniqueRef<KeyboardScrollingAnimator>(scrollableArea))
{
}

ScrollAnimator::~ScrollAnimator()
{
}

KeyboardScrollingAnimator* ScrollAnimator::keyboardScrollingAnimator() const
{
    return m_keyboardScrollingAnimator.ptr();
}

bool ScrollAnimator::singleAxisScroll(ScrollEventAxis axis, float scrollDelta, EnumSet<ScrollBehavior> behavior)
{
    CheckedRef scrollableArea = m_scrollableArea;
    scrollableArea->scrollbarsController().setScrollbarAnimationsUnsuspendedByUserInteraction(true);

    auto delta = setValueForAxis(FloatSize { }, axis, scrollDelta);

    if (behavior.contains(ScrollBehavior::RespectScrollSnap) && usesScrollSnap()) {
        auto currentOffset = offsetFromPosition(currentPosition());
        auto newOffset = currentOffset + delta;
        auto velocity = copysignf(1.0f, scrollDelta);
        auto selectionMethod = behavior.contains(ScrollBehavior::Paged) ? ScrollSnapPointSelectionMethod::Paging : ScrollSnapPointSelectionMethod::Directional;
        auto newOffsetOnAxis = m_physics->controller.adjustedScrollDestination(ScrollAnimatorScrollPhysicsClientState(*this).facade(), axis, newOffset, velocity, true, valueForAxis(currentOffset, axis), selectionMethod);
        newOffset = setValueForAxis(newOffset, axis, newOffsetOnAxis);
        delta = newOffset - currentOffset;
    } else {
        auto newPosition = m_currentPosition + delta;
        newPosition = newPosition.constrainedBetween(scrollableArea->minimumScrollPosition(), scrollableArea->maximumScrollPosition());
        if (newPosition == m_currentPosition)
            return false;

        delta = newPosition - m_currentPosition;
    }

    if (scrollableArea->scrollAnimatorEnabled() && !behavior.contains(ScrollBehavior::NeverAnimate)) {
        auto options = ScrollPositionChangeOptions::createProgrammatic();
        auto newPosition = m_currentPosition + delta;
        if (behavior.contains(ScrollBehavior::DocumentEdge)) {
            // Request the edge itself, rather than a delta that is relative to a position that may be out of date while an animation runs.
            options.animationCurve = documentEdgeScrollAnimationCurve();
            // On the other axis, keep the destination of an animation running on the main thread, such as the inline edge that Home and End scroll to first.
            if (auto destinationOffset = m_physics->controller.animatedScrollDestinationOffset(ScrollAnimatorScrollPhysicsClientState(*this).facade()))
                newPosition = setValueForAxis(positionFromOffset(*destinationOffset), axis, valueForAxis(newPosition, axis));
        } else {
            if (m_physics->controller.retargetAnimatedScrollBy(ScrollAnimatorScrollPhysicsClientState(*this).facade(), delta))
                return true;
            options.originalScrollDelta = delta;
        }
        scrollableArea->scrollToPositionWithAnimation(newPosition, options);
        return true;
    }

    return scrollToPositionWithoutAnimation(currentPosition() + delta);
}

bool ScrollAnimator::scrollToPositionWithoutAnimation(const FloatPoint& position, ScrollClamping clamping)
{
    CheckedRef scrollableArea = m_scrollableArea;
    FloatPoint currentPosition = this->currentPosition();
    auto adjustedPosition = clamping == ScrollClamping::Clamped ? position.constrainedBetween(scrollableArea->minimumScrollPosition(), scrollableArea->maximumScrollPosition()) : position;

    // FIXME: In some cases on iOS the ScrollableArea position is out of sync with the ScrollAnimator position.
    // When these cases are fixed, this extra check against the ScrollableArea position can be removed.
    if (adjustedPosition == currentPosition && adjustedPosition == scrollableArea->scrollPosition() && !scrollableArea->scrollOriginChanged())
        return false;

    m_physics->controller.stopAnimatedScroll(ScrollAnimatorScrollPhysicsClientState(*this).facade());

    setCurrentPosition(adjustedPosition, NotifyScrollableArea::Yes);
    scrollableArea->scrollDidEnd();
    return true;
}

bool ScrollAnimator::scrollToPositionWithAnimation(const FloatPoint& position, ScrollClamping clamping, ScrollAnimationCurve curve)
{
    CheckedRef scrollableArea = m_scrollableArea;
    auto adjustedPosition = clamping == ScrollClamping::Clamped ? position.constrainedBetween(scrollableArea->minimumScrollPosition(), scrollableArea->maximumScrollPosition()) : position;
    bool positionChanged = adjustedPosition != currentPosition();
    if (!positionChanged && !scrollableArea->scrollOriginChanged())
        return false;

    return m_physics->controller.startAnimatedScrollToDestination(ScrollAnimatorScrollPhysicsClientState(*this).facade(), offsetFromPosition(m_currentPosition), offsetFromPosition(adjustedPosition), curve);
}

bool ScrollAnimator::retargetRunningAnimation(const FloatPoint& newPosition, ScrollAnimationCurve curve)
{
    ASSERT(scrollableArea().scrollAnimationStatus() == ScrollAnimationStatus::Animating);
    return m_physics->controller.retargetAnimatedScroll(ScrollAnimatorScrollPhysicsClientState(*this).facade(), offsetFromPosition(newPosition), curve);
}

FloatPoint ScrollAnimator::offsetFromPosition(const FloatPoint& position) const
{
    return ScrollableArea::scrollOffsetFromPosition(position, toFloatSize(m_scrollableArea->scrollOrigin()));
}

FloatPoint ScrollAnimator::positionFromOffset(const FloatPoint& offset) const
{
    return ScrollableArea::scrollPositionFromOffset(offset, toFloatSize(m_scrollableArea->scrollOrigin()));
}

bool ScrollAnimator::activeScrollSnapIndexDidChange() const
{
    return m_physics->controller.activeScrollSnapIndexDidChange();
}

std::optional<unsigned> ScrollAnimator::activeScrollSnapIndexForAxis(ScrollEventAxis axis) const
{
    // Swift returns -1 for no index.
    auto index = m_physics->controller.activeScrollSnapIndexForAxis(axis);
    return index < 0 ? std::nullopt : std::optional<unsigned> { static_cast<unsigned>(index) };
}

void ScrollAnimator::setActiveScrollSnapIndexForAxis(ScrollEventAxis axis, std::optional<unsigned> index)
{
    m_physics->controller.setActiveScrollSnapIndexForAxis(axis, index ? int64_t { *index } : -1);
}

void ScrollAnimator::resnapAfterLayout()
{
    m_physics->controller.resnapAfterLayout(ScrollAnimatorScrollPhysicsClientState(*this).facade());
}

bool ScrollAnimator::handleWheelEvent(const PlatformWheelEvent& wheelEvent)
{
#if !PLATFORM(MAC)
    m_scrollController.updateGestureInProgressState(wheelEvent);
#endif

    if (processWheelEventForScrollSnap(wheelEvent))
        return false;

    if (protect(scrollableArea())->hasSteppedScrolling())
        return handleSteppedScrolling(wheelEvent);

    return m_physics->controller.handleWheelEvent(ScrollAnimatorScrollPhysicsClientState(*this).facade(), wheelEvent, wheelEvent.timestamp().secondsSinceEpoch().value());
}

// "Stepped scrolling" is only used by RenderListBox. It's special in that it has no rubberbanding, and scroll deltas respect Scrollbar::pixelStep().
bool ScrollAnimator::handleSteppedScrolling(const PlatformWheelEvent& wheelEvent)
{
    CheckedRef scrollableArea = m_scrollableArea;
#if ENABLE(KINETIC_SCROLLING)
    if ((wheelEvent.phase() == PlatformWheelEventPhase::Ended && wheelEvent.momentumPhase() == PlatformWheelEventPhase::None) || wheelEvent.momentumPhase() == PlatformWheelEventPhase::Ended) {
        scrollableArea->scrollDidEnd();
        return true;
    }
#endif

    RefPtr horizontalScrollbar = scrollableArea->horizontalScrollbar();
    RefPtr verticalScrollbar = scrollableArea->verticalScrollbar();

    // Accept the event if we have a scrollbar in that direction and can still
    // scroll any further.
    float deltaX = horizontalScrollbar ? wheelEvent.deltaX() : 0;
    float deltaY = verticalScrollbar ? wheelEvent.deltaY() : 0;

    bool handled = false;

    IntSize maxForwardScrollDelta = scrollableArea->maximumScrollPosition() - scrollableArea->scrollPosition();
    IntSize maxBackwardScrollDelta = scrollableArea->scrollPosition() - scrollableArea->minimumScrollPosition();
    if ((deltaX < 0 && maxForwardScrollDelta.width() > 0)
        || (deltaX > 0 && maxBackwardScrollDelta.width() > 0)
        || (deltaY < 0 && maxForwardScrollDelta.height() > 0)
        || (deltaY > 0 && maxBackwardScrollDelta.height() > 0)) {
        handled = true;

        EnumSet<ScrollBehavior> behavior = { ScrollBehavior::RespectScrollSnap };
        if (wheelEvent.hasPreciseScrollingDeltas())
            behavior.add(ScrollBehavior::NeverAnimate);

        if (deltaY) {
            if (wheelEvent.granularity() == PlatformWheelEventGranularity::ScrollByPageWheelEvent)
                deltaY = std::copysign(Scrollbar::pageStepDelta(scrollableArea->visibleHeight()), deltaY);

            auto scrollDelta = verticalScrollbar->pixelStep() * -deltaY; // Wheel deltas are reversed from scrolling direction.
            singleAxisScroll(ScrollEventAxis::Vertical, scrollDelta, behavior);
        }

        if (deltaX) {
            if (wheelEvent.granularity() == PlatformWheelEventGranularity::ScrollByPageWheelEvent)
                deltaX = std::copysign(Scrollbar::pageStepDelta(scrollableArea->visibleWidth()), deltaX);

            auto scrollDelta = horizontalScrollbar->pixelStep() * -deltaX; // Wheel deltas are reversed from scrolling direction.
            singleAxisScroll(ScrollEventAxis::Horizontal, scrollDelta, behavior);
        }
    }
    return handled;
}

void ScrollAnimator::stopKeyboardScrollAnimation()
{
    protect(keyboardScrollingAnimator())->handleKeyUpEvent();
}

#if ENABLE(TOUCH_EVENTS)
bool ScrollAnimator::handleTouchEvent(const PlatformTouchEvent&)
{
    return false;
}
#endif

static void notifyScrollAnchoringControllerOfScroll(ScrollableArea& scrollableArea)
{
    scrollableArea.clearScrollAnchor();
}

void ScrollAnimator::setCurrentPosition(const FloatPoint& position, NotifyScrollableArea notify)
{
    // FIXME: An early return here if the position is not changing triggers test failures because of adjustForIOSCaretWhenScrolling()
    // code in RenderLayerScrollableArea. We can early return when webkit.org/b/230454 is fixed.
    auto delta = position - m_currentPosition;
    m_currentPosition = position;
    
    if (notify == NotifyScrollableArea::Yes)
        notifyPositionChanged(delta);
    else
        notifyScrollAnchoringControllerOfScroll(protect(scrollableArea()));

    updateActiveScrollSnapIndexForOffset();
}

void ScrollAnimator::updateActiveScrollSnapIndexForOffset()
{
    m_physics->controller.updateActiveScrollSnapIndexForClientOffset(ScrollAnimatorScrollPhysicsClientState(*this).facade());
}

void ScrollAnimator::notifyPositionChanged(const FloatSize& delta)
{
    CheckedRef scrollableArea = m_scrollableArea;
    scrollableArea->scrollbarsController().notifyContentAreaScrolled(delta);
    scrollableArea->setScrollPositionFromAnimation(roundedIntPoint(m_currentPosition));
    m_physics->controller.scrollPositionChanged(ScrollAnimatorScrollPhysicsClientState(*this).facade());
}

void ScrollAnimator::setSnapOffsetsInfo(const LayoutScrollSnapOffsetsInfo& info)
{
    m_snapOffsetsInfo = info.isEmpty() ? std::nullopt : std::make_optional(info);
    m_physics->controller.setSnapOffsetsInfo(ScrollAnimatorScrollPhysicsClientState(*this).facade(), !!m_snapOffsetsInfo);
}

const LayoutScrollSnapOffsetsInfo* ScrollAnimator::snapOffsetsInfo() const
{
    return m_snapOffsetsInfo ? &m_snapOffsetsInfo.value() : nullptr;
}

FloatPoint ScrollAnimator::scrollOffset() const
{
    return scrollableArea().scrollOffsetFromPosition(roundedIntPoint(currentPosition()));
}

bool ScrollAnimator::allowsHorizontalScrolling() const
{
    return protect(scrollableArea())->allowsHorizontalScrolling();
}

bool ScrollAnimator::allowsVerticalScrolling() const
{
    return protect(scrollableArea())->allowsVerticalScrolling();
}

void ScrollAnimator::willStartAnimatedScroll()
{
    m_scrollableArea->setScrollAnimationStatus(ScrollAnimationStatus::Animating);
}

void ScrollAnimator::didStopAnimatedScroll()
{
    CheckedRef scrollableArea = m_scrollableArea;
    scrollableArea->setScrollAnimationStatus(ScrollAnimationStatus::NotAnimating);
    scrollableArea->animatedScrollDidEnd();
    scrollableArea->scrollDidEnd();
}

void ScrollAnimator::didStopWheelEventScroll()
{
    protect(m_scrollableArea)->scrollDidEnd();
}

#if HAVE(RUBBER_BANDING)
IntSize ScrollAnimator::stretchAmount() const
{
    return protect(scrollableArea())->overhangAmount();
}

RectEdges<bool> ScrollAnimator::edgePinnedState() const
{
    return protect(scrollableArea())->edgePinnedState();
}

bool ScrollAnimator::isPinnedOnSide(BoxSide side) const
{
    return protect(scrollableArea())->isPinnedOnSide(side);
}

#endif

void ScrollAnimator::adjustScrollPositionToBoundsIfNecessary()
{
    CheckedRef scrollableArea = m_scrollableArea;
    auto previousClamping = scrollableArea->scrollClamping();
    scrollableArea->setScrollClamping(ScrollClamping::Clamped);

    auto currentScrollPosition = scrollableArea->scrollPosition();
    auto constrainedPosition = scrollableArea->constrainedScrollPosition(currentScrollPosition);
    immediateScrollBy(constrainedPosition - currentScrollPosition);

    scrollableArea->setScrollClamping(previousClamping);
}

FloatPoint ScrollAnimator::adjustScrollPositionIfNecessary(const FloatPoint& position) const
{
    CheckedRef scrollableArea = m_scrollableArea;
    if (scrollableArea->scrollClamping() == ScrollClamping::Unclamped)
        return position;

    return scrollableArea->constrainedScrollPosition(ScrollPosition(position));
}

void ScrollAnimator::immediateScrollBy(const FloatSize& delta, ScrollClamping clamping)
{
    auto previousClamping = m_scrollableArea->scrollClamping();
    m_scrollableArea->setScrollClamping(clamping);

    auto currentPosition = this->currentPosition();
    auto newPosition = adjustScrollPositionIfNecessary(currentPosition + delta);
    if (newPosition != currentPosition)
        setCurrentPosition(newPosition, NotifyScrollableArea::Yes);

    m_scrollableArea->setScrollClamping(previousClamping);
}

ScrollExtents ScrollAnimator::scrollExtents() const
{
    CheckedRef scrollableArea = m_scrollableArea;
    return {
        scrollableArea->totalContentsSize(),
        scrollableArea->visibleSize(),
        scrollableArea->snapportSize()
    };
}

float ScrollAnimator::pageScaleFactor() const
{
    return protect(scrollableArea())->pageScaleFactor();
}

static ScrollAnimator::TimerFactory timerFactoryForTesting;

void ScrollAnimator::setTimerFactoryForTesting(TimerFactory factory)
{
    timerFactoryForTesting = factory;
}

bool ScrollAnimator::handleWheelEventForTesting(const PlatformWheelEvent& wheelEvent)
{
    return handleWheelEvent(wheelEvent);
}

bool ScrollAnimator::processWheelEventForScrollSnapForTesting(const PlatformWheelEvent& wheelEvent)
{
    return processWheelEventForScrollSnap(wheelEvent);
}

#if PLATFORM(COCOA)
void ScrollAnimator::handleWheelEventPhaseForTesting(PlatformWheelEventPhase phase)
{
    handleWheelEventPhase(phase);
}
#endif

bool ScrollAnimator::isRubberBandInProgressForTesting() const
{
    return isRubberBandInProgress();
}

std::unique_ptr<ScrollingEffectsControllerTimer> ScrollAnimator::createTimer(Function<void()>&& function)
{
    auto callback = [function = WTF::move(function), weakScrollableArea = WeakPtr { m_scrollableArea.get() }] {
        if (!weakScrollableArea)
            return;
        function();
    };
    if (timerFactoryForTesting)
        return timerFactoryForTesting(WTF::move(callback));
    return makeUnique<ScrollingEffectsControllerTimer>(RunLoop::currentSingleton(), WTF::move(callback));
}

void ScrollAnimator::discreteSnapTransitionTimerFired()
{
    m_discreteSnapTransitionTimer = nullptr;
    m_physics->controller.discreteSnapTransitionTimerFired(ScrollAnimatorScrollPhysicsClientState(*this).facade());
}

void ScrollAnimator::scheduleScrollendTimer()
{
    static const Seconds discreteScrollDelay = 100_ms;

    if (!m_discreteScrollendTimer) {
        m_discreteScrollendTimer = createTimer([this] {
            didStopWheelEventScroll();
        });
    }
    m_discreteScrollendTimer->startOneShot(discreteScrollDelay);
}

void ScrollAnimator::startAnimationCallback(ScrollingEffectsController&)
{
    startAnimationCallback();
}

void ScrollAnimator::startAnimationCallback()
{
    if (!m_scrollAnimationScheduled) {
        m_scrollAnimationScheduled = true;
        protect(scrollableArea())->didStartScrollAnimation();
    }
}

void ScrollAnimator::stopAnimationCallback(ScrollingEffectsController&)
{
    stopAnimationCallback();
}

void ScrollAnimator::stopAnimationCallback()
{
    m_scrollAnimationScheduled = false;
}

void ScrollAnimator::deferWheelEventTestCompletionForReason(ScrollingNodeID identifier, WheelEventTestMonitor::DeferReason reason) const
{
    if (RefPtr monitor = m_wheelEventTestMonitor)
        monitor->deferForReason(identifier, reason);
}

void ScrollAnimator::removeWheelEventTestCompletionDeferralForReason(ScrollingNodeID identifier, WheelEventTestMonitor::DeferReason reason) const
{
    if (RefPtr monitor = m_wheelEventTestMonitor)
        monitor->removeDeferralForReason(identifier, reason);
}

#if USE(COORDINATED_GRAPHICS)
bool ScrollAnimator::scrollAnimationEnabled() const
{
    return protect(scrollableArea())->scrollAnimatorEnabled();
}
#endif

void ScrollAnimator::cancelAnimations()
{
    m_physics->controller.stopAnimatedScroll(ScrollAnimatorScrollPhysicsClientState(*this).facade());
    protect(scrollableArea())->scrollbarsController().cancelAnimations();
}

bool ScrollAnimator::isUserScrollInProgress() const
{
    return m_physics->controller.isUserScrollInProgress();
}

bool ScrollAnimator::isScrollSnapInProgress() const
{
    return m_physics->controller.isScrollSnapInProgress(m_discreteSnapTransitionTimer && m_discreteSnapTransitionTimer->isActive());
}

bool ScrollAnimator::usesScrollSnap() const
{
    return !!m_snapOffsetsInfo;
}

void ScrollAnimator::contentsSizeChanged()
{
    m_physics->controller.contentsSizeChanged(ScrollAnimatorScrollPhysicsClientState(*this).facade());
}

FloatPoint ScrollAnimator::scrollOffsetAdjustedForSnapping(const FloatPoint& offset, ScrollSnapPointSelectionMethod method) const
{
    if (!usesScrollSnap())
        return offset;

    auto result = FloatPoint {
        scrollOffsetAdjustedForSnapping(ScrollEventAxis::Horizontal, offset, method),
        scrollOffsetAdjustedForSnapping(ScrollEventAxis::Vertical, offset, method)
    };

    LOG_WITH_STREAM(ScrollSnap, stream << "ScrollAnimator::scrollOffsetAdjustedForSnapping() - offset " << offset << " adjusted to  " << result);
    return result;
}

float ScrollAnimator::scrollOffsetAdjustedForSnapping(ScrollEventAxis axis, const FloatPoint& newOffset, ScrollSnapPointSelectionMethod method) const
{
    if (!usesScrollSnap())
        return axis == ScrollEventAxis::Horizontal ? newOffset.x() : newOffset.y();

    std::optional<float> originalOffset;
    float velocityInScrollAxis = 0.;
    if (method == ScrollSnapPointSelectionMethod::Directional) {
        FloatSize scrollOrigin = toFloatSize(m_scrollableArea->scrollOrigin());
        auto currentOffset = ScrollableArea::scrollOffsetFromPosition(this->currentPosition(), scrollOrigin);
        auto velocity = newOffset - currentOffset;
        originalOffset = axis == ScrollEventAxis::Horizontal ? currentOffset.x() : currentOffset.y();
        velocityInScrollAxis = axis == ScrollEventAxis::Horizontal ? velocity.width() : velocity.height();
    }

    return m_physics->controller.adjustedScrollDestination(ScrollAnimatorScrollPhysicsClientState(*this).facade(), axis, newOffset, velocityInScrollAxis, originalOffset.has_value(), originalOffset.value_or(0), ScrollSnapPointSelectionMethod::Closest);
}

ScrollAnimationStatus ScrollAnimator::serviceScrollAnimation(MonotonicTime time)
{
    if (m_scrollAnimationScheduled)
        m_physics->controller.animationCallback(ScrollAnimatorScrollPhysicsClientState(*this).facade(), time.secondsSinceEpoch().value());
    return m_scrollAnimationScheduled ? ScrollAnimationStatus::Animating : ScrollAnimationStatus::NotAnimating;
}

ScrollingNodeID ScrollAnimator::scrollingNodeIDForTesting() const
{
    return protect(scrollableArea())->scrollingNodeIDForTesting();
}


} // namespace WebCore
