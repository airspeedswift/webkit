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

#include "ScrollingTreeScrollPhysicsClient.h"
#include "ScrollingTreeScrollPhysicsDelegateHolder.h"

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ThreadedScrollingTreeScrollingNodeDelegate);

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

ThreadedScrollingTreeScrollingNodeDelegate::ThreadedScrollingTreeScrollingNodeDelegate(ScrollingTreeScrollingNode& scrollingNode)
    : ScrollingTreeScrollingNodeDelegate(scrollingNode)
    , m_physics(makeUnique<ScrollingTreeScrollPhysicsDelegateHolder>())
{
}

ThreadedScrollingTreeScrollingNodeDelegate::~ThreadedScrollingTreeScrollingNodeDelegate() = default;

void ThreadedScrollingTreeScrollingNodeDelegate::updateFromStateNode(const ScrollingStateScrollingNode& scrollingStateNode)
{
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
}

void ThreadedScrollingTreeScrollingNodeDelegate::updateSnapScrollState()
{
    m_physics->delegate.updateSnapScrollState(ScrollingTreeScrollPhysicsClientState(*this).facade());
}

bool ThreadedScrollingTreeScrollingNodeDelegate::startAnimatedScrollToPosition(FloatPoint destinationPosition, ScrollAnimationCurve curve)
{
    return m_physics->delegate.startAnimatedScrollToPosition(ScrollingTreeScrollPhysicsClientState(*this).facade(), destinationPosition, curve);
}

void ThreadedScrollingTreeScrollingNodeDelegate::stopAnimatedScroll(EnumSet<AnimatedScrollType>)
{
    m_physics->delegate.stopAnimatedScroll(ScrollingTreeScrollPhysicsClientState(*this).facade());
}

void ThreadedScrollingTreeScrollingNodeDelegate::stopSpringAnimation()
{
    m_physics->delegate.stopSpringAnimation(ScrollingTreeScrollPhysicsClientState(*this).facade());
}

void ThreadedScrollingTreeScrollingNodeDelegate::serviceScrollAnimation(MonotonicTime currentTime)
{
    m_physics->delegate.serviceScrollAnimation(ScrollingTreeScrollPhysicsClientState(*this).facade(), currentTime.secondsSinceEpoch().value());
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

void ThreadedScrollingTreeScrollingNodeDelegate::discreteSnapTransitionTimerFired()
{
    // The timer's callback may hold the last reference to the node, which owns this delegate.
    ScrollingTreeScrollPhysicsClientState state(*this);
    m_discreteSnapTransitionTimer = nullptr;
    m_physics->delegate.discreteSnapTransitionTimerFired(state.facade());
}

FloatPoint ThreadedScrollingTreeScrollingNodeDelegate::adjustedScrollPosition(const FloatPoint& position) const
{
    return { roundf(position.x()), roundf(position.y()) };
}

void ThreadedScrollingTreeScrollingNodeDelegate::handleKeyboardScrollRequest(const RequestedKeyboardScrollData& scrollData)
{
    m_physics->delegate.handleKeyboardScrollRequest(ScrollingTreeScrollPhysicsClientState(*this).facade(), scrollData);
}

} // namespace WebCore

#endif // ENABLE(ASYNC_SCROLLING) && ENABLE(SCROLLING_THREAD)
