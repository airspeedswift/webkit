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

#import "config.h"
#import "ScrollingEffectsController.h"

#import "Logging.h"
#import "PlatformWheelEvent.h"
#import "RubberbandingState.h"
#import "ScrollExtents.h"
#import "ScrollPhysicsControllerHolder.h"
#import "ScrollableArea.h"
#import "ScrollingEffectsClock.h"
#import <pal/spi/mac/NSScrollViewSPI.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#import <wtf/SystemTracing.h>
#import <wtf/text/TextStream.h>

#if USE(APPLE_INTERNAL_SDK)
#import <WebKitAdditions/ScrollingEffectsControllerAdditions.mm>
#endif

#if PLATFORM(MAC)

namespace WebCore {

ScrollingEffectsController::~ScrollingEffectsController()
{
    ASSERT(m_timersWereStopped);
}

void ScrollingEffectsController::stopAllTimers()
{
    // Hand the timers to the client for destruction rather than stopping them here: they may fire on
    // another thread (e.g. the scrolling thread) than the one tearing down the controller, and stopping
    // or destroying a timer off its run loop's thread races with an in-flight callback.
    if (m_discreteSnapTransitionTimer) {
        m_client.destroyTimer(WTF::move(m_discreteSnapTransitionTimer));
        m_client.didStopScrollSnapAnimation();
    }

    if (m_discreteScrollendTimer)
        m_client.destroyTimer(WTF::move(m_discreteScrollendTimer));

#if ASSERT_ENABLED
    m_timersWereStopped = true;
#endif
}

NODELETE static ScrollEventAxis dominantAxisFavoringVertical(FloatSize delta)
{
    if (std::abs(delta.height()) >= std::abs(delta.width()))
        return ScrollEventAxis::Vertical;

    return ScrollEventAxis::Horizontal;
}

NODELETE static FloatSize deltaAlignedToAxis(FloatSize delta, ScrollEventAxis axis)
{
    switch (axis) {
    case ScrollEventAxis::Horizontal: return FloatSize { delta.width(), 0 };
    case ScrollEventAxis::Vertical: return FloatSize { 0, delta.height() };
    }

    return { };
}

NODELETE static FloatSize deltaAlignedToDominantAxis(FloatSize delta)
{
    auto dominantAxis = dominantAxisFavoringVertical(delta);
    return deltaAlignedToAxis(delta, dominantAxis);
}

#if HAVE(APPKIT_GESTURES_SUPPORT)
static FloatSize hyperbolicReboundDeltaForElasticDelta(IntSize stretchAmount, float rubberbandHyperbolicCoefficient, FloatSize viewportSize)
{
    const auto width = _NSHyperbolicReboundDeltaForElasticDelta(stretchAmount.width(), rubberbandHyperbolicCoefficient, viewportSize.width());
    const auto height = _NSHyperbolicReboundDeltaForElasticDelta(stretchAmount.height(), rubberbandHyperbolicCoefficient, viewportSize.height());
    return { static_cast<float>(width), static_cast<float>(height) };
}
#endif

void ScrollingEffectsController::handleWheelEventDuringSpringAnimation(const PlatformWheelEvent& wheelEvent)
{
    m_physics->controller.handleWheelEventDuringSpringAnimation(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade(), wheelEvent);
}

bool ScrollingEffectsController::handleWheelEvent(const PlatformWheelEvent& wheelEvent)
{
    return m_physics->controller.handleWheelEvent(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade(), wheelEvent, wheelEvent.timestamp().secondsSinceEpoch().value());
}

#if HAVE(APPKIT_GESTURES_SUPPORT)
float ScrollingEffectsController::deltaAdjustedForRefreshController(float generalDampedHeight, float verticalDelta, float verticalStretch, bool verticalDeltaOpposesStretch)
{
    // This logic mirrors AppKit. We layer the refresh-control reveal on top of the general vertical curve.
    if (!m_client.hasRefreshController() || verticalDeltaOpposesStretch || !verticalDelta)
        return generalDampedHeight;

    if (!m_gestureBeganAtTop || m_momentumScrollInProgress)
        return generalDampedHeight;

    if (verticalStretch > 0 || verticalDelta >= 0)
        return generalDampedHeight;

    // Vertical stretch at the top is negative. Take the absolute value and work in positive magnitudes.
    const auto currentStretchMagnitude = std::abs(verticalStretch);
    verticalDelta = std::abs(verticalDelta);

    const auto activationHeight = m_client.refreshControllerSnappingThreshold();
    const auto viewportHeight = m_client.scrollExtents().viewportSize.height();

    // Split delta between the linear zone (below the control's activation height) and the hyperbolic zone (above).
    auto newStretchMagnitude = 0.f;
    if (currentStretchMagnitude + verticalDelta > activationHeight) {
        const auto stretchAlreadyInHyperbolic = std::max(0.0f, currentStretchMagnitude - activationHeight);
        const auto deltaConsumedInLinear = std::max(0.0f, activationHeight - currentStretchMagnitude);
        const auto deltaForHyperbolic = verticalDelta - deltaConsumedInLinear;
        const auto currentHyperbolicReboundDelta = _NSHyperbolicReboundDeltaForElasticDelta(stretchAlreadyInHyperbolic, m_rubberbandHyperbolicCoefficient, viewportHeight);
        const auto combinedHyperbolicReboundDelta = currentHyperbolicReboundDelta + deltaForHyperbolic;

        // The new magnitude will be layered on top of the general scroll curve. Floor it like the non-refresh-control
        // path so that the positions remain pixel-aligned.
        newStretchMagnitude = activationHeight + std::ceilf(_NSHyperbolicElasticDeltaForReboundDelta(combinedHyperbolicReboundDelta, m_rubberbandHyperbolicCoefficient, viewportHeight));
    } else
        newStretchMagnitude = currentStretchMagnitude + verticalDelta;

    const auto signedNewStretch = -newStretchMagnitude;
    // Keep the force as if this stretch had come from the general hyperbolic curve so that any
    // later general-path event that takes place is handled correctly.
    m_stretchScrollForce.setHeight(_NSHyperbolicReboundDeltaForElasticDelta(signedNewStretch, m_rubberbandHyperbolicCoefficient, viewportHeight));
    return signedNewStretch - verticalStretch;
}
#else
#endif

#if HAVE(APPKIT_GESTURES_SUPPORT)

FloatSize ScrollingEffectsController::computeDampedStretchDelta(FloatSize delta, bool horizontalDeltaOpposesStretch, bool verticalDeltaOpposesStretch)
{
    // This logic mirrors AppKit.
    const auto stretchAmount = m_client.stretchAmount();
    auto hyperbolicDampedDeltaForAxis = [&](ScrollEventAxis axis) -> std::pair<float, float> {
        // Returns (dampedDelta, newForce). When the axis opposes the current stretch we don't
        // accumulate into force (the caller already zeroed it), and the delta passes straight through.

        auto lengthForAxis = [](FloatSize size, ScrollEventAxis axis) {
            return (axis == ScrollEventAxis::Horizontal) ? size.width() : size.height();
        };
        const auto viewportSize = m_client.scrollExtents().viewportSize;
        const auto viewportLength = lengthForAxis(viewportSize, axis);
        const auto deltaForAxis = lengthForAxis(delta, axis);
        const auto currentForce = lengthForAxis(m_stretchScrollForce, axis);
        const auto currentStretch = lengthForAxis(stretchAmount, axis);
        const auto opposesStretch = axis == ScrollEventAxis::Horizontal ? horizontalDeltaOpposesStretch : verticalDeltaOpposesStretch;

        if (opposesStretch) {
            const auto remainingStretch = currentStretch + deltaForAxis;
            const auto forceForRemainingStretch = _NSHyperbolicReboundDeltaForElasticDelta(remainingStretch, m_rubberbandHyperbolicCoefficient, viewportLength);
            return { deltaForAxis, static_cast<float>(forceForRemainingStretch) };
        }

        if (!deltaForAxis)
            return { 0, currentForce };

        const auto newForce = currentForce + deltaForAxis;
        const auto newStretch = ceilf(_NSHyperbolicElasticDeltaForReboundDelta(newForce, m_rubberbandHyperbolicCoefficient, viewportLength));
        return { newStretch - currentStretch, newForce };
    };

    const auto [dampedWidth, newForceWidth] = hyperbolicDampedDeltaForAxis(ScrollEventAxis::Horizontal);
    auto [dampedHeight, newForceHeight] = hyperbolicDampedDeltaForAxis(ScrollEventAxis::Vertical);
    m_stretchScrollForce = { newForceWidth, newForceHeight };

    dampedHeight = deltaAdjustedForRefreshController(dampedHeight, delta.height(), stretchAmount.height(), verticalDeltaOpposesStretch);

    return { dampedWidth, dampedHeight };
}

#endif

FloatSize ScrollingEffectsController::wheelDeltaBiasingTowardsVertical(const FloatSize& wheelDelta)
{
    return deltaAlignedToDominantAxis(wheelDelta);
}

bool ScrollingEffectsController::isScrollDeltaOpposingStretch(IntSize stretch, ScrollEventAxis axis, float delta)
{
    auto stretchOnAxis = (axis == ScrollEventAxis::Horizontal) ? stretch.width() : stretch.height();
    if (!stretchOnAxis || !delta)
        return false;

    return (stretchOnAxis > 0 && delta < 0) || (stretchOnAxis < 0 && delta > 0);
}

void ScrollingEffectsController::scrollPositionChanged()
{
    m_physics->controller.scrollPositionChanged(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade());
}

bool ScrollingEffectsController::isUserScrollInProgress() const
{
    return m_physics->controller.isUserScrollInProgress();
}

bool ScrollingEffectsController::isRubberBandInProgress() const
{
    return m_physics->controller.isRubberBandInProgress();
}

RectEdges<bool> ScrollingEffectsController::rubberBandingEdges() const
{
    return m_physics->controller.rubberBandingEdges();
}

bool ScrollingEffectsController::isScrollSnapInProgress() const
{
    return m_physics->controller.isScrollSnapInProgress(m_discreteSnapTransitionTimer && m_discreteSnapTransitionTimer->isActive());
}

void ScrollingEffectsController::stopRubberBanding()
{
    m_physics->controller.stopRubberBanding(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade());
}

void ScrollingEffectsController::startRubberBandSnapBack()
{
    m_physics->controller.startRubberBandSnapBack(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade());
}

void ScrollingEffectsController::rubberBandTargetOffsetDidChange()
{
    m_physics->controller.rubberBandTargetOffsetDidChange(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade());
}

void ScrollingEffectsController::scheduleScrollendTimer()
{
    static const Seconds discreteScrollDelay = 100_ms;

    if (!m_discreteScrollendTimer) {
        m_discreteScrollendTimer = m_client.createTimer([this] {
            scrollendTimerFired();
        });
    }
    m_discreteScrollendTimer->startOneShot(discreteScrollDelay);
}

void ScrollingEffectsController::discreteSnapTransitionTimerFired()
{
    m_discreteSnapTransitionTimer = nullptr;
    m_physics->controller.discreteSnapTransitionTimerFired(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade());
}

void ScrollingEffectsController::scrollendTimerFired()
{
    m_client.didStopWheelEventScroll();
}

bool ScrollingEffectsController::processWheelEventForScrollSnap(const PlatformWheelEvent& wheelEvent)
{
    return m_physics->controller.processWheelEventForScrollSnap(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade(), wheelEvent);
}

void ScrollingEffectsController::updateGestureInProgressState(const PlatformWheelEvent& wheelEvent)
{
    m_physics->controller.updateGestureInProgressState(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade(), wheelEvent);
}

std::optional<RubberbandingState> ScrollingEffectsController::captureRubberbandingState() const
{
    RubberbandingState state;
    if (!m_physics->controller.captureRubberbandingState(ScrollPhysicsClientState(m_client, nullptr, m_snapOffsetsInfo).facade(), state))
        return std::nullopt;
    return state;
}

bool ScrollingEffectsController::restoreRubberbandingState(const RubberbandingState& state)
{
    return m_physics->controller.restoreRubberbandingState(ScrollPhysicsClientState(m_client, this, m_snapOffsetsInfo).facade(), state);
}

bool ScrollPhysicsClient::isDiscreteSnapTimerActive()
{
    auto& timer = controller().m_discreteSnapTransitionTimer;
    return timer && timer->isActive();
}

void ScrollPhysicsClient::startDiscreteSnapTimer()
{
    auto& controller = this->controller();
    controller.m_discreteSnapTransitionTimer = client().createTimer([controller = &controller] {
        controller->discreteSnapTransitionTimerFired();
    });
    static constexpr Seconds discreteScrollSnapDelay = 100_ms;
    controller.m_discreteSnapTransitionTimer->startOneShot(discreteScrollSnapDelay);
}

bool ScrollPhysicsClient::stopDiscreteSnapTimer()
{
    auto& timer = controller().m_discreteSnapTransitionTimer;
    if (!timer)
        return false;
    timer->stop();
    timer = nullptr;
    return true;
}

WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN
void ScrollPhysicsClient::momentumScrollBegan()
{
#if HAVE(OS_SIGNPOST)
    SUPPRESS_UNRETAINED_ARG os_signpost_interval_begin(WTFSignpostLogHandle(), OS_SIGNPOST_ID_EXCLUSIVE, "Momentum scroll", "isAnimation=YES");
#endif
}

void ScrollPhysicsClient::momentumScrollEnded()
{
#if HAVE(OS_SIGNPOST)
    SUPPRESS_UNRETAINED_ARG os_signpost_interval_end(WTFSignpostLogHandle(), OS_SIGNPOST_ID_EXCLUSIVE, "Momentum scroll");
#endif
}
WTF_ALLOW_UNSAFE_BUFFER_USAGE_END

} // namespace WebCore

#endif // PLATFORM(MAC)
