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

#include "config.h"
#include "ThreadedScrollingTreeScrollingNodeDelegate.h"

#if ENABLE(ASYNC_SCROLLING) && ENABLE(SCROLLING_THREAD)

#include "ScrollExtents.h"
#include "ScrollingStateScrollingNode.h"
#include "ScrollingThread.h"
#include "ScrollingTree.h"
#include "ScrollingTreeFrameScrollingNode.h"
#include "ScrollingTreeScrollingNode.h"
#include <wtf/TZoneMallocInlines.h>

#if USE_SWIFT_SCROLLING_TREE_DELEGATE
#include "ScrollingTreeScrollPhysicsClient.h"
#include "ScrollingTreeScrollPhysicsDelegateHolder.h"
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ThreadedScrollingTreeScrollingNodeDelegate);

#if USE_SWIFT_SCROLLING_TREE_DELEGATE
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(ScrollingTreeScrollPhysicsDelegateHolder);

// The shape that lets Swift use ScrollingTreeScrollPhysicsClient only in place (ScrollingTreeScrollPhysicsClient.h).
static_assert(std::is_empty_v<ScrollingTreeScrollPhysicsClient>);
static_assert(!std::is_polymorphic_v<ScrollingTreeScrollPhysicsClient>);
static_assert(!std::is_default_constructible_v<ScrollingTreeScrollPhysicsClient>);
static_assert(!std::is_copy_constructible_v<ScrollingTreeScrollPhysicsClient>);
static_assert(!std::is_copy_assignable_v<ScrollingTreeScrollPhysicsClient>);
static_assert(!std::is_move_assignable_v<ScrollingTreeScrollPhysicsClient>);
static_assert(std::is_move_constructible_v<ScrollingTreeScrollPhysicsClient>);
static_assert(!std::is_trivially_destructible_v<ScrollingTreeScrollPhysicsClient>);

ScrollingTreeScrollPhysicsClient::ScrollingTreeScrollPhysicsClient(ScrollingTreeScrollPhysicsClient&&)
{
    RELEASE_ASSERT_NOT_REACHED();
}

ScrollingTreeScrollPhysicsClient::~ScrollingTreeScrollPhysicsClient() = default;

void ScrollingTreeScrollPhysicsClient::startScrollendTimer()
{
    auto& delegate = this->delegate();
    if (!delegate.m_discreteScrollendTimer) {
        delegate.m_discreteScrollendTimer = delegate.createTimer([delegate = &delegate] {
            delegate->scrollingNode()->didStopWheelEventScroll();
        });
    }
    // As ScrollingEffectsController::scheduleScrollendTimer().
    static constexpr Seconds discreteScrollDelay = 100_ms;
    delegate.m_discreteScrollendTimer->startOneShot(discreteScrollDelay);
}
#endif

ThreadedScrollingTreeScrollingNodeDelegate::ThreadedScrollingTreeScrollingNodeDelegate(ScrollingTreeScrollingNode& scrollingNode)
    : ScrollingTreeScrollingNodeDelegate(scrollingNode)
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    , m_physics(makeUnique<ScrollingTreeScrollPhysicsDelegateHolder>())
#else
    , m_scrollController(*this)
#endif
{
}

ThreadedScrollingTreeScrollingNodeDelegate::~ThreadedScrollingTreeScrollingNodeDelegate() = default;

void ThreadedScrollingTreeScrollingNodeDelegate::updateFromStateNode(const ScrollingStateScrollingNode& scrollingStateNode)
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    bool snapOffsetsChanged = scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::SnapOffsetsInfo);
    if (snapOffsetsChanged) {
        auto snapOffsetsInfo = scrollingStateNode.snapOffsetsInfo().convertUnits<LayoutScrollSnapOffsetsInfo>();
        m_snapOffsetsInfo = snapOffsetsInfo.isEmpty() ? std::nullopt : std::make_optional(WTF::move(snapOffsetsInfo));
    }
    // -1 is no index.
    auto snapIndex = [](std::optional<unsigned> index) {
        return index ? int64_t { *index } : -1;
    };
    m_physics->delegate.updateFromStateNode(ScrollingTreeScrollPhysicsClientState(*this).facade(), snapOffsetsChanged, !!m_snapOffsetsInfo,
        scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::CurrentHorizontalSnapOffsetIndex), snapIndex(scrollingStateNode.currentHorizontalSnapPointIndex()),
        scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::CurrentVerticalSnapOffsetIndex), snapIndex(scrollingStateNode.currentVerticalSnapPointIndex()));
#else
    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::SnapOffsetsInfo))
        m_scrollController.setSnapOffsetsInfo(scrollingStateNode.snapOffsetsInfo().convertUnits<LayoutScrollSnapOffsetsInfo>());

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::CurrentHorizontalSnapOffsetIndex))
        m_scrollController.setActiveScrollSnapIndexForAxis(ScrollEventAxis::Horizontal, scrollingStateNode.currentHorizontalSnapPointIndex());

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::CurrentVerticalSnapOffsetIndex))
        m_scrollController.setActiveScrollSnapIndexForAxis(ScrollEventAxis::Vertical, scrollingStateNode.currentVerticalSnapPointIndex());
#endif
}

void ThreadedScrollingTreeScrollingNodeDelegate::updateSnapScrollState()
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    m_physics->delegate.updateSnapScrollState(ScrollingTreeScrollPhysicsClientState(*this).facade());
#else
    Ref scrollingNode = this->scrollingNode();
    scrollingNode->setScrollSnapInProgress(m_scrollController.isScrollSnapInProgress());

    if (m_scrollController.activeScrollSnapIndexDidChange())
        scrollingTree()->setActiveScrollSnapIndices(scrollingNode->scrollingNodeID(), m_scrollController.activeScrollSnapIndexForAxis(ScrollEventAxis::Horizontal), m_scrollController.activeScrollSnapIndexForAxis(ScrollEventAxis::Vertical));
#endif
}

#if !USE_SWIFT_SCROLLING_TREE_DELEGATE
void ThreadedScrollingTreeScrollingNodeDelegate::updateUserScrollInProgressForEvent(const PlatformWheelEvent& wheelEvent)
{
    bool wasInUserScroll = m_scrollController.isUserScrollInProgress();
    m_scrollController.updateGestureInProgressState(wheelEvent);
    bool isInUserScroll = m_scrollController.isUserScrollInProgress();
    if (isInUserScroll != wasInUserScroll)
        scrollingNode()->setUserScrollInProgress(isInUserScroll);
}
#endif

bool ThreadedScrollingTreeScrollingNodeDelegate::startAnimatedScrollToPosition(FloatPoint destinationPosition, ScrollAnimationCurve curve)
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    return m_physics->delegate.startAnimatedScrollToPosition(ScrollingTreeScrollPhysicsClientState(*this).facade(), destinationPosition, curve);
#else
    auto currentOffset = ScrollableArea::scrollOffsetFromPosition(currentScrollPosition(), scrollOrigin());
    auto destinationOffset = ScrollableArea::scrollOffsetFromPosition(destinationPosition, scrollOrigin());
    return m_scrollController.startAnimatedScrollToDestination(currentOffset, destinationOffset, curve);
#endif
}

void ThreadedScrollingTreeScrollingNodeDelegate::stopAnimatedScroll(EnumSet<AnimatedScrollType>)
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    m_physics->delegate.stopAnimatedScroll(ScrollingTreeScrollPhysicsClientState(*this).facade());
#else
    m_scrollController.stopAnimatedScroll();
#endif
}

void ThreadedScrollingTreeScrollingNodeDelegate::stopSpringAnimation()
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    m_physics->delegate.stopSpringAnimation(ScrollingTreeScrollPhysicsClientState(*this).facade());
#else
    m_scrollController.stopSpringAnimation();
#endif
}

void ThreadedScrollingTreeScrollingNodeDelegate::serviceScrollAnimation(MonotonicTime currentTime)
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    m_physics->delegate.serviceScrollAnimation(ScrollingTreeScrollPhysicsClientState(*this).facade(), currentTime.secondsSinceEpoch().value());
#else
    m_scrollController.animationCallback(currentTime);
#endif
}

std::unique_ptr<ScrollingEffectsControllerTimer> ThreadedScrollingTreeScrollingNodeDelegate::createTimer(Function<void()>&& function)
{
    // This is only used for a scroll snap timer.
    return WTF::makeUnique<ScrollingEffectsControllerTimer>(RunLoop::currentSingleton(), [function = WTF::move(function), scrollingNode = this->scrollingNode()] {
        Locker locker { scrollingNode->scrollingTree()->treeLock() };
        function();
    });
}

void ThreadedScrollingTreeScrollingNodeDelegate::destroyTimer(std::unique_ptr<ScrollingEffectsControllerTimer> timer)
{
    // Snap timers are created against the scrolling thread's run loop (see createTimer), so they must
    // be destroyed there to avoid racing CFRunLoopTimerInvalidate() against an in-flight callback when
    // the node is torn down on the main thread (e.g. from commitTreeState()). The timer's callback
    // holds a Ref to the scrolling node, so the node and this delegate stay alive until the timer is
    // gone, keeping a late-firing callback safe.
    ScrollingThread::dispatch([timer = WTF::move(timer)] { });
}

#if USE_SWIFT_SCROLLING_TREE_DELEGATE
void ThreadedScrollingTreeScrollingNodeDelegate::discreteSnapTransitionTimerFired()
{
    // The timer's callback may hold the last reference to the node, which owns this delegate.
    ScrollingTreeScrollPhysicsClientState state(*this);
    m_discreteSnapTransitionTimer = nullptr;
    m_physics->delegate.discreteSnapTransitionTimerFired(state.facade());
}
#endif

#if !USE_SWIFT_SCROLLING_TREE_DELEGATE
void ThreadedScrollingTreeScrollingNodeDelegate::startAnimationCallback(ScrollingEffectsController&)
{
    scrollingNode()->setScrollAnimationInProgress(true);
}

void ThreadedScrollingTreeScrollingNodeDelegate::stopAnimationCallback(ScrollingEffectsController&)
{
    scrollingNode()->setScrollAnimationInProgress(false);
}

bool ThreadedScrollingTreeScrollingNodeDelegate::allowsHorizontalScrolling() const
{
    return ScrollingTreeScrollingNodeDelegate::allowsHorizontalScrolling();
}

bool ThreadedScrollingTreeScrollingNodeDelegate::allowsVerticalScrolling() const
{
    return ScrollingTreeScrollingNodeDelegate::allowsVerticalScrolling();
}

void ThreadedScrollingTreeScrollingNodeDelegate::immediateScrollBy(const FloatSize& delta, ScrollClamping clamping)
{
    scrollingNode()->scrollBy(delta, clamping);
}

void ThreadedScrollingTreeScrollingNodeDelegate::adjustScrollPositionToBoundsIfNecessary()
{
    FloatPoint scrollPosition = currentScrollPosition();
    FloatPoint constrainedPosition = scrollPosition.constrainedBetween(minimumScrollPosition(), maximumScrollPosition());
    immediateScrollBy(constrainedPosition - scrollPosition);
}

FloatPoint ThreadedScrollingTreeScrollingNodeDelegate::scrollOffset() const
{
    return ScrollableArea::scrollOffsetFromPosition(currentScrollPosition(), scrollOrigin());
}

float ThreadedScrollingTreeScrollingNodeDelegate::pageScaleFactor() const
{
    // FIXME: What should this return for non-root frames, and overflow?
    // Also, this should not have to access ScrollingTreeFrameScrollingNode.
    if (RefPtr node = dynamicDowncast<ScrollingTreeFrameScrollingNode>(scrollingNode()))
        return node->frameScaleFactor();

    return 1;
}

void ThreadedScrollingTreeScrollingNodeDelegate::willStartAnimatedScroll()
{
    scrollingNode()->willStartAnimatedScroll();
}

void ThreadedScrollingTreeScrollingNodeDelegate::didStopAnimatedScroll()
{
    scrollingNode()->didStopAnimatedScroll();
}

void ThreadedScrollingTreeScrollingNodeDelegate::willStartWheelEventScroll()
{
    scrollingNode()->willStartWheelEventScroll();
}

void ThreadedScrollingTreeScrollingNodeDelegate::didStopWheelEventScroll()
{
    scrollingNode()->didStopWheelEventScroll();
}

void ThreadedScrollingTreeScrollingNodeDelegate::willStartScrollSnapAnimation()
{
    scrollingNode()->setScrollSnapInProgress(true);
}

void ThreadedScrollingTreeScrollingNodeDelegate::didStopScrollSnapAnimation()
{
    scrollingNode()->setScrollSnapInProgress(false);
    didStopAnimatedScroll();
}

ScrollExtents ThreadedScrollingTreeScrollingNodeDelegate::scrollExtents() const
{
    Ref scrollingNode = this->scrollingNode();
    // scrollableAreaSize() is the frame view's visibleSize(), which has the delegated page scale divided out
    // of it. Put it back to get the snapport the snap offsets were computed in.
    auto snapportSize = scrollingNode->scrollableAreaSize();
    if (RefPtr frameNode = dynamicDowncast<ScrollingTreeFrameScrollingNode>(scrollingNode.get()))
        snapportSize.scale(frameNode->delegatedPageScaleFactor());

    return {
        scrollingNode->totalContentsSize(),
        scrollingNode->scrollableAreaSize(),
        snapportSize
    };
}

void ThreadedScrollingTreeScrollingNodeDelegate::deferWheelEventTestCompletionForReason(ScrollingNodeID, WheelEventTestMonitor::DeferReason reason) const
{
    if (!scrollingTree()->isMonitoringWheelEvents())
        return;

    // Just use the scrolling node ID as the identifier, since we know this is coming from a ScrollingEffectsController associated with this node.
    scrollingTree()->deferWheelEventTestCompletionForReason(scrollingNode()->scrollingNodeID(), reason);
}

void ThreadedScrollingTreeScrollingNodeDelegate::removeWheelEventTestCompletionDeferralForReason(ScrollingNodeID, WheelEventTestMonitor::DeferReason reason) const
{
    if (!scrollingTree()->isMonitoringWheelEvents())
        return;

    // Just use the scrolling node ID as the identifier, since we know this is coming from a ScrollingEffectsController associated with this node.
    scrollingTree()->removeWheelEventTestCompletionDeferralForReason(scrollingNode()->scrollingNodeID(), reason);
}
#endif

FloatPoint ThreadedScrollingTreeScrollingNodeDelegate::adjustedScrollPosition(const FloatPoint& position) const
{
    return { roundf(position.x()), roundf(position.y()) };
}

void ThreadedScrollingTreeScrollingNodeDelegate::handleKeyboardScrollRequest(const RequestedKeyboardScrollData& scrollData)
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    m_physics->delegate.handleKeyboardScrollRequest(ScrollingTreeScrollPhysicsClientState(*this).facade(), scrollData);
#else
    switch (scrollData.action) {
    case KeyboardScrollAction::StartAnimation:
        m_scrollController.startKeyboardScroll(*scrollData.keyboardScroll);
        break;
    case KeyboardScrollAction::StopWithAnimation:
        m_scrollController.finishKeyboardScroll(false);
        break;
    case KeyboardScrollAction::StopImmediately:
        m_scrollController.finishKeyboardScroll(true);
        break;
    }
#endif
}

#if !USE_SWIFT_SCROLLING_TREE_DELEGATE
ScrollingNodeID ThreadedScrollingTreeScrollingNodeDelegate::scrollingNodeIDForTesting() const
{
    return scrollingNode()->scrollingNodeID();
}
#endif


} // namespace WebCore

#endif // ENABLE(ASYNC_SCROLLING) && ENABLE(SCROLLING_THREAD)
