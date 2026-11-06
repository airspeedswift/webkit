/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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
#include "MomentumEventDispatcher.h"

#if ENABLE(MOMENTUM_EVENT_DISPATCHER)

#include "Logging.h"
#include <WebCore/AnimationFrameRate.h>
#include <WebCore/Scrollbar.h>
#include <WebCore/ScrollingEffectsClock.h>
#include <wtf/Borrow.h>
#include <wtf/SystemTracing.h>
#include <wtf/TZoneMallocInlines.h>

#include "WebKit-Swift.h"

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(MomentumEventDispatcher);

// MomentumEventDispatcher.swift copies these values.
static_assert(std::to_underlying(WebEventPhase::Began) == 1);
static_assert(std::to_underlying(WebEventPhase::Changed) == 3);
static_assert(std::to_underlying(WebEventPhase::Ended) == 4);
static_assert(std::to_underlying(WebWheelEventMomentumEndType::Interrupted) == 1);
static_assert(std::to_underlying(WebWheelEventMomentumEndType::Natural) == 2);

MomentumEventDispatcher::MomentumEventDispatcher(Client& client)
    : m_client(client)
    , m_state(makeUniqueWithoutFastMallocCheck<MomentumEventDispatcherState>(MomentumEventDispatcherState::init()))
{
}

std::unique_ptr<MomentumEventDispatcher> MomentumEventDispatcher::create(Client& client)
{
    return makeUnique<MomentumEventDispatcher>(client);
}

MomentumEventDispatcher::~MomentumEventDispatcher()
{
    performActions(momentumStopDisplayLink(*m_state));
}

bool MomentumEventDispatcher::handleWheelEvent(WebCore::PageIdentifier pageIdentifier, const WebWheelEvent& event, WebCore::RectEdges<WebCore::RubberBandingBehavior> rubberBandableEdges)
{
    m_lastRubberBandableEdges = rubberBandableEdges;
    m_lastIncomingEvent = &event;

    auto rawPlatformDelta = event.rawPlatformDelta().value_or(WebCore::FloatSize { });
    auto actions = momentumHandleWheelEvent(*m_state, pageIdentifier.toUInt64(), std::to_underlying(event.phase()), std::to_underlying(event.momentumPhase()), std::to_underlying(event.momentumEndType()), event.isMomentumEvent(),
        !!event.rawPlatformDelta(), rawPlatformDelta.width(), rawPlatformDelta.height(), event.ioHIDEventTimestamp().secondsSinceEpoch().value(), event.inputSource() == WebEventInputSource::Automation,
        event.momentumFastScrollMultiplier(), event.delta().width(), event.delta().height(), event.directionInvertedFromDevice(), WebCore::scrollingEffectsClockNow().secondsSinceEpoch().value());
    performActions(actions, pageIdentifier, &event);
    return actions.ignoresEvent();
}

void MomentumEventDispatcher::performActions(const MomentumActions& actions, std::optional<WebCore::PageIdentifier> beginningPage, const WebWheelEvent* beginningEvent)
{
    bool endsGesture = actions.endsGesture();
    if (endsGesture) {
        dispatchSyntheticMomentumEvent(WebWheelEvent::Phase::Ended, { }, static_cast<WebWheelEvent::MomentumEndType>(actions.endType()));
        m_client->didEndSyntheticMomentumScrolling();
    }
    if (actions.stopsDisplayLink())
        m_client->stopDisplayDidRefreshCallbacks(actions.stopDisplayID());
    if (endsGesture) {
        m_currentGesture = { };
        tracePoint(SyntheticMomentumEnd);
    }

    bool beginsGesture = actions.beginsGesture();
    if (beginsGesture) {
        tracePoint(SyntheticMomentumStart);
        m_currentGesture.active = true;
        m_currentGesture.pageIdentifier = beginningPage;
        m_currentGesture.initiatingEvent = beginningEvent;
    }
    if (actions.startsDisplayLink())
        m_client->startDisplayDidRefreshCallbacks(actions.startDisplayID());
    if (beginsGesture)
        dispatchSyntheticMomentumEvent(WebWheelEvent::Phase::Began, beginningEvent->delta());

    if (actions.dispatchesChangedEvent())
        dispatchSyntheticMomentumEvent(WebWheelEvent::Phase::Changed, { actions.changedDeltaWidth(), actions.changedDeltaHeight() });
}

static float appKitScrollMultiplierForEvent(const WebWheelEvent& event)
{
    auto delta = event.delta();
    auto unacceleratedDelta = event.unacceleratedScrollingDelta();
    float multiplier = 1;
    
    // FIXME: Can the AppKit multiplier ever differ by axis?
    if (delta.width() && unacceleratedDelta.width())
        multiplier = std::max(multiplier, delta.width() / unacceleratedDelta.width());
    if (delta.height() && unacceleratedDelta.height())
        multiplier = std::max(multiplier, delta.height() / unacceleratedDelta.height());

    return multiplier;
}

void MomentumEventDispatcher::dispatchSyntheticMomentumEvent(WebWheelEvent::Phase phase, WebCore::FloatSize delta, WebWheelEvent::MomentumEndType momentumEndType)
{
    tracePoint(SyntheticMomentumEvent, std::to_underlying(phase), std::abs(delta.width()), std::abs(delta.height()));

    ASSERT(m_currentGesture.active);
    ASSERT(m_currentGesture.initiatingEvent);

    Ref<const WebWheelEvent> initiatingEvent = *m_currentGesture.initiatingEvent;
    auto appKitScrollMultiplier = appKitScrollMultiplierForEvent(initiatingEvent);
    auto appKitAcceleratedDelta = delta * appKitScrollMultiplier;
    auto wheelTicks = appKitAcceleratedDelta / WebCore::Scrollbar::pixelsPerLineStep();
    auto time = WebCore::scrollingEffectsClockNow();

    // FIXME: Ideally we would stick legitimate rawPlatformDeltas on the event,
    // but currently nothing will consume them, and we'd have to keep track of them separately.
    Ref syntheticEvent = WebWheelEvent::create({ WebEventType::Wheel, m_lastIncomingEvent->modifiers(), time }, {
        .position = initiatingEvent->position(),
        .globalPosition = initiatingEvent->globalPosition(),
        .delta = appKitAcceleratedDelta,
        .wheelTicks = wheelTicks,
        .granularity = WebWheelEvent::Granularity::ScrollByPixelWheelEvent,
        .directionInvertedFromDevice = initiatingEvent->directionInvertedFromDevice(),
        .phase = WebWheelEvent::Phase::None,
        .momentumPhase = phase,
        .hasPreciseScrollingDeltas = true,
        .scrollCount = initiatingEvent->scrollCount(),
        .unacceleratedScrollingDelta = delta,
        .ioHIDEventTimestamp = time,
        .rawPlatformDelta = { },
        .momentumEndType = momentumEndType,
        .inputSource = initiatingEvent->inputSource(),
    });

    m_client->handleSyntheticWheelEvent(*m_currentGesture.pageIdentifier, syntheticEvent, m_lastRubberBandableEdges);

#if ENABLE(MOMENTUM_EVENT_DISPATCHER_TEMPORARY_LOGGING)
    m_currentLogState.totalGeneratedOffset += appKitAcceleratedDelta.height();
    pushLogEntry({ .event = WebWheelEvent::Phase::None, .momentum = phase }, { });
#endif
}

void MomentumEventDispatcher::setScrollingAccelerationCurve(WebCore::PageIdentifier pageIdentifier, std::optional<ScrollingAccelerationCurve>&& curve)
{
    if (!curve) {
        momentumClearScrollingAccelerationCurve(*m_state, pageIdentifier.toUInt64());
        return;
    }
    momentumSetScrollingAccelerationCurve(*m_state, pageIdentifier.toUInt64(), curve->gainLinear(), curve->gainParabolic(), curve->gainCubic(), curve->gainQuartic(),
        curve->tangentSpeedLinear(), curve->tangentSpeedParabolicRoot(), curve->resolution(), curve->frameRate());
}

void MomentumEventDispatcher::pageScreenDidChange(WebCore::PageIdentifier pageID, WebCore::PlatformDisplayID displayID, std::optional<unsigned> nominalFramesPerSecond)
{
    performActions(momentumPageScreenDidChange(*m_state, pageID.toUInt64(), displayID, nominalFramesPerSecond.value_or(WebCore::FullSpeedFramesPerSecond)));
}

void MomentumEventDispatcher::displayDidRefresh(WebCore::PlatformDisplayID displayID)
{
    performActions(momentumDisplayDidRefresh(*m_state, displayID, WebCore::scrollingEffectsClockNow().secondsSinceEpoch().value()));
}

#if ENABLE(MOMENTUM_EVENT_DISPATCHER_TEMPORARY_LOGGING)

void MomentumEventDispatcher::pushLogEntry(LogEntry::Phases generatedPhases, LogEntry::Phases eventPhases)
{
    m_currentLogState.time = MonotonicTime::now();
    m_currentLogState.generatedPhases = generatedPhases;
    m_currentLogState.eventPhases = eventPhases;
    m_log.append(m_currentLogState);
}

void MomentumEventDispatcher::flushLog()
{
    if ((MonotonicTime::now() - m_currentLogState.time) < 500_ms)
        return;

    if (m_log.isEmpty())
        return;

    auto startTime = m_log[0].time;
    RELEASE_LOG(ScrollAnimations, "MomentumEventDispatcher event log: time,generatedOffset,generatedPhase[wheel:momentum],eventOffset,eventPhase[wheel:momentum]");
    for (const auto& entry : m_log)
        RELEASE_LOG(ScrollAnimations, "MomentumEventDispatcher event log: %f,%f,%d:%d,%f,%d:%d", (entry.time - startTime).seconds(), entry.totalGeneratedOffset, std::to_underlying(entry.generatedPhases.event), std::to_underlying(entry.generatedPhases.momentum), entry.totalEventOffset, std::to_underlying(entry.eventPhases.event), std::to_underlying(entry.eventPhases.momentum));

    m_log.clear();
    m_currentLogState = { };
}

#endif

} // namespace WebKit

#endif
