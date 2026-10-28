/*
 * Copyright (C) 2011-2017 Apple Inc. All rights reserved.
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
#include "ScrollingEffectsController.h"

#include "KeyboardScrollingAnimator.h"
#include "LayoutSize.h"
#include "Logging.h"
#include "PlatformWheelEvent.h"
#include "ScrollAnimationKeyboard.h"
#include "ScrollAnimationSmooth.h"
#include "ScrollExtents.h"
#include "ScrollPhysicsControllerHolder.h"
#include "ScrollableArea.h"
#include "ScrollingEffectsClock.h"
#include <atomic>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>

#if ENABLE(KINETIC_SCROLLING) && !PLATFORM(MAC)
#include "ScrollAnimationKinetic.h"
#endif

#if HAVE(RUBBER_BANDING)
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollingEffectsControllerTimer);

static std::atomic<ScrollingEffectsClockFunction> scrollingEffectsClock;

MonotonicTime scrollingEffectsClockNow()
{
    if (auto clock = scrollingEffectsClock.load(std::memory_order_relaxed))
        return clock();
    return MonotonicTime::now();
}

void setScrollingEffectsClockForTesting(ScrollingEffectsClockFunction clock)
{
    scrollingEffectsClock.store(clock, std::memory_order_relaxed);
}

WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(ScrollPhysicsControllerHolder);

// The shape that lets Swift use ScrollPhysicsClient only in place (ScrollPhysicsTypes.h).
static_assert(std::is_empty_v<ScrollPhysicsClient>);
static_assert(!std::is_polymorphic_v<ScrollPhysicsClient>);
static_assert(!std::is_default_constructible_v<ScrollPhysicsClient>);
static_assert(!std::is_copy_constructible_v<ScrollPhysicsClient>);
static_assert(!std::is_copy_assignable_v<ScrollPhysicsClient>);
static_assert(!std::is_move_assignable_v<ScrollPhysicsClient>);
static_assert(std::is_move_constructible_v<ScrollPhysicsClient>);
static_assert(!std::is_trivially_destructible_v<ScrollPhysicsClient>);

// ScrollPhysicsController.swift converts to and from LayoutUnit's raw value, and treats these
// NodeIdentifier values as ones a HashSet rejects.
static_assert(kFixedPointDenominator == 64);
static_assert(!NodeIdentifier::isValidIdentifier(0) && !NodeIdentifier::isValidIdentifier(std::numeric_limits<uint64_t>::max()));

ScrollPhysicsClient::ScrollPhysicsClient(ScrollPhysicsClient&&)
{
    RELEASE_ASSERT_NOT_REACHED();
}

ScrollPhysicsClient::~ScrollPhysicsClient() { }

ScrollingEffectsController::ScrollingEffectsController(ScrollingEffectsControllerClient& client)
    : m_client(client)
    , m_physics(makeUnique<ScrollPhysicsControllerHolder>())
{
}

void ScrollingEffectsController::animationCallback(MonotonicTime currentTime)
{
    m_physics->controller.animationCallback(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade(), currentTime.secondsSinceEpoch().value());
}

bool ScrollingEffectsController::startKeyboardScroll(const KeyboardScroll& scrollData)
{
    return m_physics->controller.startKeyboardScroll(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade(), scrollData);
}

void ScrollingEffectsController::finishKeyboardScroll(bool immediate)
{
    m_physics->controller.finishKeyboardScroll(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade(), immediate);
}

bool ScrollingEffectsController::startAnimatedScrollToDestination(FloatPoint startOffset, FloatPoint destinationOffset, ScrollAnimationCurve curve)
{
    return m_physics->controller.startAnimatedScrollToDestination(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade(), startOffset, destinationOffset, curve);
}

bool ScrollingEffectsController::retargetAnimatedScroll(FloatPoint newDestinationOffset, ScrollAnimationCurve curve)
{
    return m_physics->controller.retargetAnimatedScroll(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade(), newDestinationOffset, curve);
}

bool ScrollingEffectsController::retargetAnimatedScrollBy(FloatSize offset)
{
    return m_physics->controller.retargetAnimatedScrollBy(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade(), offset);
}

std::optional<FloatPoint> ScrollingEffectsController::animatedScrollDestinationOffset() const
{
    return m_physics->controller.animatedScrollDestinationOffset();
}

void ScrollingEffectsController::stopAnimatedNonRubberbandingScroll()
{
    m_physics->controller.stopAnimatedNonRubberbandingScroll(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade());
}

void ScrollingEffectsController::stopAnimatedScroll()
{
    m_physics->controller.stopAnimatedScroll(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade());
}

bool ScrollingEffectsController::isSpringAnimationRunning() const
{
    return m_physics->controller.isSpringAnimationRunning();
}

void ScrollingEffectsController::stopSpringAnimation()
{
    m_physics->controller.stopSpringAnimation(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade());
}

void ScrollingEffectsController::stopKeyboardScrolling()
{
    protect(m_client.keyboardScrollingAnimator())->handleKeyUpEvent();
}

void ScrollingEffectsController::contentsSizeChanged()
{
    m_physics->controller.contentsSizeChanged(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade());
}

bool ScrollingEffectsController::usesScrollSnap() const
{
    return !!m_snapOffsetsInfo;
}

void ScrollingEffectsController::setSnapOffsetsInfo(const LayoutScrollSnapOffsetsInfo& snapOffsetInfo)
{
    if (snapOffsetInfo.isEmpty())
        m_snapOffsetsInfo = std::nullopt;
    else
        m_snapOffsetsInfo = snapOffsetInfo;
    m_physics->controller.setSnapOffsetsInfo(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade(), !!m_snapOffsetsInfo);
}

const LayoutScrollSnapOffsetsInfo* ScrollingEffectsController::snapOffsetsInfo() const
{
    return m_snapOffsetsInfo ? &m_snapOffsetsInfo.value() : nullptr;
}

std::optional<unsigned> ScrollingEffectsController::activeScrollSnapIndexForAxis(ScrollEventAxis axis) const
{
    // Swift returns -1 for no index.
    auto index = m_physics->controller.activeScrollSnapIndexForAxis(axis);
    return index < 0 ? std::nullopt : std::optional<unsigned> { static_cast<unsigned>(index) };
}

void ScrollingEffectsController::setActiveScrollSnapIndexForAxis(ScrollEventAxis axis, std::optional<unsigned> index)
{
    m_physics->controller.setActiveScrollSnapIndexForAxis(axis, index ? int64_t { *index } : -1);
}

bool ScrollingEffectsController::activeScrollSnapIndexDidChange() const
{
    return m_physics->controller.activeScrollSnapIndexDidChange();
}

float ScrollingEffectsController::adjustedScrollDestination(ScrollEventAxis axis, FloatPoint destinationOffset, float velocity, std::optional<float> originalOffset, ScrollSnapPointSelectionMethod selectionMethod) const
{
    return m_physics->controller.adjustedScrollDestination(ScrollPhysicsClientState(m_client, nullptr, m_snapOffsetsInfo).facade(), axis, destinationOffset, velocity, originalOffset.has_value(), originalOffset.value_or(0), selectionMethod);
}

#if !PLATFORM(MAC)
#if ENABLE(KINETIC_SCROLLING)
bool ScrollingEffectsController::processWheelEventForKineticScrolling(const PlatformWheelEvent& event)
{
    if (CheckedPtr kineticAnimation = dynamicDowncast<ScrollAnimationKinetic>(m_currentAnimation.get())) {
        m_previousKineticAnimationInfo.startTime = kineticAnimation->startTime();
        m_previousKineticAnimationInfo.initialOffset = kineticAnimation->initialOffset();
        m_previousKineticAnimationInfo.initialVelocity = kineticAnimation->initialVelocity();

        kineticAnimation->stop();
    }

    if (!event.hasPreciseScrollingDeltas()) {
        m_scrollHistory.clear();
        m_previousKineticAnimationInfo.initialVelocity = FloatSize();
        return false;
    }

    m_scrollHistory.append(event);

    if (!event.isEndOfNonMomentumScroll() && !event.isTransitioningToMomentumScroll())
        return false;

    if (m_currentAnimation && !is<ScrollAnimationKinetic>(m_currentAnimation.get())) {
        protect(m_currentAnimation)->stop();
        m_currentAnimation = nullptr;
        m_previousKineticAnimationInfo.initialVelocity = FloatSize();
    }

    if (usesScrollSnap())
        return false;

    if (!m_currentAnimation)
        m_currentAnimation = makeUnique<ScrollAnimationKinetic>(*this);

    CheckedRef kineticAnimation = downcast<ScrollAnimationKinetic>(*m_currentAnimation);
    while (!m_scrollHistory.isEmpty())
        kineticAnimation->appendToScrollHistory(m_scrollHistory.takeFirst());

    FloatSize previousVelocity;
    if (!m_previousKineticAnimationInfo.initialVelocity.isZero()) {
        previousVelocity = kineticAnimation->accumulateVelocityFromPreviousGesture(m_previousKineticAnimationInfo.startTime,
            m_previousKineticAnimationInfo.initialOffset, m_previousKineticAnimationInfo.initialVelocity);
        m_previousKineticAnimationInfo.initialVelocity = FloatSize();
    }

    if (event.isEndOfNonMomentumScroll()) {
        kineticAnimation->startAnimatedScrollWithInitialVelocity(m_client.scrollOffset(), kineticAnimation->computeVelocity(), previousVelocity, m_client.allowsHorizontalScrolling(), m_client.allowsVerticalScrolling());
        return true;
    }
    if (event.isTransitioningToMomentumScroll()) {
        kineticAnimation->clearScrollHistory();
        kineticAnimation->startAnimatedScrollWithInitialVelocity(m_client.scrollOffset(), event.swipeVelocity(), previousVelocity, m_client.allowsHorizontalScrolling(), m_client.allowsVerticalScrolling());
        return true;
    }

    ASSERT_NOT_REACHED();
    return false;
}
#endif

void ScrollingEffectsController::adjustDeltaForSnappingIfNeeded(float& deltaX, float& deltaY)
{
    if (snapOffsetsInfo() && !snapOffsetsInfo()->isEmpty()) {
        float scale = m_client.pageScaleFactor();
        auto scrollOffset = m_client.scrollOffset();
        auto extents = m_client.scrollExtents();

        auto originalOffset = LayoutPoint(scrollOffset.x() / scale, scrollOffset.y() / scale);
        auto newOffset = LayoutPoint((scrollOffset.x() + deltaX) / scale, (scrollOffset.y() + deltaY) / scale);

        auto offsetX = snapOffsetsInfo()->closestSnapOffset(ScrollEventAxis::Horizontal, LayoutSize(extents.contentsSize), newOffset, deltaX, originalOffset.x()).first;
        auto offsetY = snapOffsetsInfo()->closestSnapOffset(ScrollEventAxis::Vertical, LayoutSize(extents.contentsSize), newOffset, deltaY, originalOffset.y()).first;

        deltaX = (offsetX - originalOffset.x()) * scale;
        deltaY = (offsetY - originalOffset.y()) * scale;
    }
}

void ScrollingEffectsController::updateGestureInProgressState(const PlatformWheelEvent& wheelEvent)
{
#if ENABLE(KINETIC_SCROLLING)
    m_inScrollGesture = wheelEvent.hasPreciseScrollingDeltas() && !wheelEvent.isEndOfNonMomentumScroll() && !wheelEvent.isTransitioningToMomentumScroll();
#else
    UNUSED_PARAM(wheelEvent);
#endif
}

bool ScrollingEffectsController::handleWheelEvent(const PlatformWheelEvent& wheelEvent)
{
#if ENABLE(KINETIC_SCROLLING)
    if (processWheelEventForKineticScrolling(wheelEvent))
        return true;
#endif

    auto scrollOffset = m_client.scrollOffset();
    float deltaX = m_client.allowsHorizontalScrolling() ? wheelEvent.deltaX() : 0;
    float deltaY = m_client.allowsVerticalScrolling() ? wheelEvent.deltaY() : 0;
    auto extents = m_client.scrollExtents();
    auto minPosition = extents.minimumScrollOffset();
    auto maxPosition = extents.maximumScrollOffset();

    if ((deltaX < 0 && scrollOffset.x() >= maxPosition.x())
        || (deltaX > 0 && scrollOffset.x() <= minPosition.x()))
        deltaX = 0;
    if ((deltaY < 0 && scrollOffset.y() >= maxPosition.y())
        || (deltaY > 0 && scrollOffset.y() <= minPosition.y()))
        deltaY = 0;

    if (wheelEvent.granularity() == PlatformWheelEventGranularity::ScrollByPageWheelEvent) {
        if (deltaX) {
            bool negative = deltaX < 0;
            deltaX = Scrollbar::pageStepDelta(extents.contentsSize.width());
            if (negative)
                deltaX = -deltaX;
        }
        if (deltaY) {
            bool negative = deltaY < 0;
            deltaY = Scrollbar::pageStepDelta(extents.contentsSize.height());
            if (negative)
                deltaY = -deltaY;
        }
    }

    deltaX = -deltaX;
    deltaY = -deltaY;

    if (!m_inScrollGesture)
        adjustDeltaForSnappingIfNeeded(deltaX, deltaY);

    if (!deltaX && !deltaY)
        return false;

#if ENABLE(SMOOTH_SCROLLING)
    if (m_client.scrollAnimationEnabled() && !m_inScrollGesture) {
        if (!retargetAnimatedScrollBy({ deltaX, deltaY }))
            startAnimatedScrollToDestination(scrollOffset, scrollOffset + FloatSize { deltaX, deltaY });
        return true;
    }
#endif

#if ENABLE(COORDINATED_TOUCH_EVENTS)
    if (m_client.scrollAnimationEnabled() && m_inScrollGesture) {
        // For precise-delta wheel events, which are dispatched by touchpad or synthesized from touch events,
        // scroll immediately with immediateScrollBy below.
        // However, it's not enough for async scrolling while the main thread is busy.
        // We have to start a scroll animation here to start monitoring the display link.
        auto destination = scrollOffset;
        destination.move(FloatSize { deltaX, deltaY });
        float fromX = std::nextafter(destination.x(), scrollOffset.x());
        float fromY = std::nextafter(destination.y(), scrollOffset.y());
        startAnimatedScrollToDestination({ fromX, fromY }, destination);
    }
#endif

    m_client.immediateScrollBy({ deltaX, deltaY });

    return true;
}

bool ScrollingEffectsController::isUserScrollInProgress() const
{
    return m_inScrollGesture;
}

bool ScrollingEffectsController::isScrollSnapInProgress() const
{
    if (!usesScrollSnap())
        return false;

    if (m_inScrollGesture)
        return true;

    CheckedPtr animation = m_currentAnimation.get();
    return animation && animation->isActive();
}
#endif

void ScrollingEffectsController::updateActiveScrollSnapIndexForClientOffset()
{
    m_physics->controller.updateActiveScrollSnapIndexForClientOffset(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade());
}

void ScrollingEffectsController::resnapAfterLayout()
{
    m_physics->controller.resnapAfterLayout(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade());
}

// Currently, only Mac supports momentum srolling-based scrollsnapping and rubber banding
// so all of these methods are a noop on non-Mac platforms.
#if !PLATFORM(MAC)
ScrollingEffectsController::~ScrollingEffectsController() = default;

void ScrollingEffectsController::stopAllTimers()
{
}

void ScrollingEffectsController::scrollPositionChanged()
{
}

void ScrollingEffectsController::updateRubberBandAnimatingState()
{
}

#endif // PLATFORM(MAC)

} // namespace WebCore
