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
    return m_physics->controller.scrollAnimatorSingleAxisScroll(ScrollAnimatorScrollPhysicsClientState(*this).facade(), axis, scrollDelta, behavior.contains(ScrollBehavior::RespectScrollSnap), behavior.contains(ScrollBehavior::Paged), behavior.contains(ScrollBehavior::NeverAnimate), behavior.contains(ScrollBehavior::DocumentEdge));
}

bool ScrollAnimator::scrollToPositionWithoutAnimation(const FloatPoint& position, ScrollClamping clamping)
{
    return m_physics->controller.scrollAnimatorScrollToPositionWithoutAnimation(ScrollAnimatorScrollPhysicsClientState(*this).facade(), position, clamping);
}

bool ScrollAnimator::scrollToPositionWithAnimation(const FloatPoint& position, ScrollClamping clamping, ScrollAnimationCurve curve)
{
    return m_physics->controller.scrollAnimatorScrollToPositionWithAnimation(ScrollAnimatorScrollPhysicsClientState(*this).facade(), position, clamping, curve);
}

bool ScrollAnimator::retargetRunningAnimation(const FloatPoint& newPosition, ScrollAnimationCurve curve)
{
    return m_physics->controller.scrollAnimatorRetargetRunningAnimation(ScrollAnimatorScrollPhysicsClientState(*this).facade(), newPosition, curve);
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
    return m_physics->controller.scrollAnimatorBaseHandleWheelEvent(ScrollAnimatorScrollPhysicsClientState(*this).facade(), wheelEvent, wheelEvent.timestamp().secondsSinceEpoch().value());
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

void ScrollAnimator::setCurrentPosition(const FloatPoint& position, NotifyScrollableArea notify)
{
    m_physics->controller.scrollAnimatorSetCurrentPosition(ScrollAnimatorScrollPhysicsClientState(*this).facade(), position, notify == NotifyScrollableArea::Yes);
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

void ScrollAnimator::didStopWheelEventScroll()
{
    protect(m_scrollableArea)->scrollDidEnd();
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

void ScrollAnimator::cancelAnimations()
{
    m_physics->controller.scrollAnimatorCancelAnimations(ScrollAnimatorScrollPhysicsClientState(*this).facade());
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
    return m_physics->controller.scrollAnimatorScrollOffsetAdjustedForSnapping(ScrollAnimatorScrollPhysicsClientState(*this).facade(), offset, method);
}

float ScrollAnimator::scrollOffsetAdjustedForSnapping(ScrollEventAxis axis, const FloatPoint& newOffset, ScrollSnapPointSelectionMethod method) const
{
    return m_physics->controller.scrollAnimatorScrollOffsetAdjustedForSnappingOnAxis(ScrollAnimatorScrollPhysicsClientState(*this).facade(), axis, newOffset, method);
}

ScrollAnimationStatus ScrollAnimator::serviceScrollAnimation(MonotonicTime time)
{
    return m_physics->controller.scrollAnimatorServiceScrollAnimation(ScrollAnimatorScrollPhysicsClientState(*this).facade(), time.secondsSinceEpoch().value());
}

} // namespace WebCore
