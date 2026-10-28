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

// A ScrollingEffectsControllerClient that answers from a scripted scroll state and records every call the
// controller makes, a replaced clock, test-fired timers, and a driver that replays a list of steps through
// the controller's public members. ScrollPhysics.cpp and ScrollPhysicsBench.cpp share it.
//
// The controller is built in a fixed-size buffer and only its out-of-line members are called, so a binary
// built against one configuration of ScrollingEffectsController.h can drive a WebCore built with another.

#include <WebCore/FloatPoint.h>
#include <WebCore/FloatSize.h>
#include <WebCore/IntSize.h>
#include <WebCore/KeyboardScroll.h>
#include <WebCore/LayoutRect.h>
#include <WebCore/LayoutUnit.h>
#include <WebCore/PlatformWheelEvent.h>
#include <WebCore/RectEdges.h>
#include <WebCore/RubberbandingState.h>
#include <WebCore/ScrollExtents.h>
#include <WebCore/ScrollSnapOffsetsInfo.h>
#include <WebCore/ScrollTypes.h>
#include <WebCore/ScrollingEffectsClock.h>
#include <WebCore/ScrollingEffectsController.h>
#include <WebCore/ScrollingMomentumCalculator.h>
#include <WebCore/WheelEventTestMonitor.h>
#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <new>
#include <optional>
#include <string>
#include <vector>
#include <wtf/MonotonicTime.h>
#include <wtf/RunLoop.h>

namespace TestWebKitAPI {
namespace ScrollPhysics {

using namespace WebCore;

// MARK: - Trace

enum class TraceLevel : uint8_t {
    Full, // Every client call, clock read, timer event, entry and return value.
    Light, // immediateScrollBy() deltas and entry return values only.
};

class Trace {
public:
    explicit Trace(TraceLevel level = TraceLevel::Full)
        : m_level(level)
    {
    }

    TraceLevel level() const { return m_level; }
    uint64_t digest() const { return m_hash; }
    uint64_t events() const { return m_events; }
    uint64_t entries() const { return m_entries; }
    void countEntry() { ++m_entries; }

    void reset()
    {
        m_hash = initialHash;
        m_events = 0;
        m_entries = 0;
    }

    void bytes(const void* data, size_t size)
    {
        auto* p = static_cast<const uint8_t*>(data);
        for (size_t i = 0; i < size; ++i) {
            m_hash ^= p[i];
            m_hash *= 1099511628211ull;
        }
    }

    void countEvent() { ++m_events; }

private:
    static constexpr uint64_t initialHash = 14695981039346656037ull;
    TraceLevel m_level;
    uint64_t m_hash { initialHash };
    uint64_t m_events { 0 };
    uint64_t m_entries { 0 };
};

// One event: a kind ('C' client call, 'E' entry, 'R' return, 'K' clock read, 'T' timer, 'S' snapshot,
// 'X' case boundary), a name and its values. An event is hashed only when the trace is Full, or when
// it is marked light. Each value's key names it in the call site; keys are not hashed.
class TraceLine {
public:
    TraceLine(Trace& trace, char kind, const char* name, bool light = false)
        : m_trace(trace)
        , m_active(trace.level() == TraceLevel::Full || light)
    {
        if (!m_active)
            return;
        m_trace.countEvent();
        if (m_trace.level() == TraceLevel::Full) {
            m_trace.bytes(&kind, 1);
            m_trace.bytes(name, std::strlen(name) + 1);
        }
    }

    TraceLine& f(const char* key, float value)
    {
        if (!m_active)
            return *this;
        auto bits = std::bit_cast<uint32_t>(value);
        m_trace.bytes(&bits, sizeof(bits));
        UNUSED_PARAM(key);
        return *this;
    }

    TraceLine& d(const char* key, double value)
    {
        if (!m_active)
            return *this;
        auto bits = std::bit_cast<uint64_t>(value);
        m_trace.bytes(&bits, sizeof(bits));
        UNUSED_PARAM(key);
        return *this;
    }

    TraceLine& u(const char* key, uint64_t value)
    {
        if (!m_active)
            return *this;
        m_trace.bytes(&value, sizeof(value));
        UNUSED_PARAM(key);
        return *this;
    }

    TraceLine& b(const char* key, bool value) { return u(key, value ? 1 : 0); }
    TraceLine& sz(const char* key, FloatSize value) { return f(key, value.width()).f("", value.height()); }
    TraceLine& pt(const char* key, FloatPoint value) { return f(key, value.x()).f("", value.y()); }
    TraceLine& isz(const char* key, IntSize value) { return u(key, static_cast<uint32_t>(value.width())).u("", static_cast<uint32_t>(value.height())); }
    TraceLine& t(const char* key, MonotonicTime value) { return d(key, value.secondsSinceEpoch().value()); }
    TraceLine& s(const char* key, Seconds value) { return d(key, value.value()); }

    TraceLine& optu(const char* key, std::optional<unsigned> value)
    {
        b(key, !!value);
        if (value)
            u("", *value);
        return *this;
    }

    TraceLine& optf(const char* key, std::optional<float> value)
    {
        b(key, !!value);
        if (value)
            f("", *value);
        return *this;
    }

    TraceLine& edges(const char* key, const RectEdges<bool>& value)
    {
        return u(key, (value.top() ? 1 : 0) | (value.right() ? 2 : 0) | (value.bottom() ? 4 : 0) | (value.left() ? 8 : 0));
    }

private:
    Trace& m_trace;
    bool m_active;
};

// MARK: - Clock

// The clock ScrollingEffectsController reads through scrollingEffectsClockNow(). Each read is traced.
struct ScriptedClock {
    double now { 1000 };
    double stepPerRead { 0 };
    Trace* trace { nullptr };
    uint64_t reads { 0 };
};

inline ScriptedClock& scriptedClock()
{
    static ScriptedClock clock;
    return clock;
}

inline MonotonicTime scriptedClockNow()
{
    auto& clock = scriptedClock();
    auto now = MonotonicTime::fromRawSeconds(clock.now);
    ++clock.reads;
    if (clock.trace)
        TraceLine(*clock.trace, 'K', "now").t("t", now);
    clock.now += clock.stepPerRead;
    return now;
}

class ScriptedClockScope {
public:
    ScriptedClockScope(Trace& trace, double start)
    {
        auto& clock = scriptedClock();
        clock = { };
        clock.now = start;
        clock.trace = &trace;
        setScrollingEffectsClockForTesting(scriptedClockNow);
    }

    ~ScriptedClockScope()
    {
        setScrollingEffectsClockForTesting(nullptr);
        scriptedClock().trace = nullptr;
    }
};

// MARK: - Wheel events

// Sets the fields WebKit's own event conversion sets.
class TestWheelEvent : public PlatformWheelEvent {
public:
    struct Description {
        PlatformWheelEventPhase phase { PlatformWheelEventPhase::None };
        PlatformWheelEventPhase momentumPhase { PlatformWheelEventPhase::None };
        FloatSize delta;
        FloatSize unacceleratedDelta;
        FloatSize velocity;
        FloatSize wheelTicks;
        double timestamp { 0 };
        PlatformWheelEventGranularity granularity { PlatformWheelEventGranularity::ScrollByPixelWheelEvent };
        MouseEventInputSource inputSource { MouseEventInputSource::UserDriven };
        bool hasPreciseScrollingDeltas { true };
    };

    explicit TestWheelEvent(const Description& description)
    {
        m_timestamp = MonotonicTime::fromRawSeconds(description.timestamp);
        m_phase = description.phase;
        m_momentumPhase = description.momentumPhase;
        m_deltaX = description.delta.width();
        m_deltaY = description.delta.height();
        m_wheelTicksX = description.wheelTicks.width();
        m_wheelTicksY = description.wheelTicks.height();
        m_unacceleratedScrollingDeltaX = description.unacceleratedDelta.width();
        m_unacceleratedScrollingDeltaY = description.unacceleratedDelta.height();
        m_scrollingVelocity = description.velocity;
        m_granularity = description.granularity;
        m_inputSource = description.inputSource;
        m_hasPreciseScrollingDeltas = description.hasPreciseScrollingDeltas;
        m_ioHIDEventTimestamp = m_timestamp;
        m_rawPlatformDelta = description.delta;
    }
};

using WheelDescription = TestWheelEvent::Description;

inline void traceWheel(TraceLine& line, const WheelDescription& wheel)
{
    line.u("phase", static_cast<uint8_t>(wheel.phase)).u("momentum", static_cast<uint8_t>(wheel.momentumPhase))
        .sz("delta", wheel.delta).sz("unaccel", wheel.unacceleratedDelta).sz("velocity", wheel.velocity).sz("ticks", wheel.wheelTicks)
        .d("ts", wheel.timestamp).u("granularity", static_cast<uint8_t>(wheel.granularity))
        .u("source", static_cast<uint8_t>(wheel.inputSource)).b("precise", wheel.hasPreciseScrollingDeltas);
}

// MARK: - Scripted state

enum class ReentryAction : uint8_t {
    None,
    StopAnimatedScroll,
    StartAnimatedScroll,
    StartKeyboardScroll,
};

struct ScriptedConfig {
    FloatSize contentsSize { 800, 4000 };
    FloatSize viewportSize { 800, 600 };
    FloatSize snapportSize { 800, 600 };
    bool allowsHorizontalScrolling { true };
    bool allowsVerticalScrolling { true };
    bool allowsHorizontalStretching { true };
    bool allowsVerticalStretching { true };
    // Bits 0-3: BoxSide Top, Right, Bottom, Left. Without an override, pinning follows the offset.
    std::optional<uint8_t> pinnedSides;
    uint8_t rubberBandSides { 0xF };
    float pageScaleFactor { 1 };
    bool hasRefreshController { false };
    float refreshControllerSnappingThreshold { 0 };
    FloatSize rubberBandTargetOffset;
    bool scrollAnimationEnabled { true };
    bool roundScrollOffset { true };
    // Mirrors ScrollAnimator: a scroll that moves the offset calls scrollPositionChanged() and
    // updateActiveScrollSnapIndexForClientOffset() on the controller before returning.
    bool reentrant { false };
    ReentryAction reentryAction { ReentryAction::None };
    uint32_t reentryAtScroll { 0 };
    FloatPoint reentryDestination;
    uint64_t scrollingNodeID { 7 };
};

inline ScrollExtents extentsFor(const ScriptedConfig& config)
{
    return { config.contentsSize, config.viewportSize, config.snapportSize };
}

class ControllerHost;

// MARK: - Recording client

class RecordingClient final : public ScrollingEffectsControllerClient {
public:
    RecordingClient(Trace& trace, const ScriptedConfig& config, FloatPoint offset)
        : m_trace(trace)
        , m_config(config)
        , m_offset(offset)
    {
    }

    ~RecordingClient() = default;

    void setHost(ControllerHost* host) { m_host = host; }

    ScriptedConfig& config() { return m_config; }
    const ScriptedConfig& config() const { return m_config; }
    FloatPoint offset() const { return m_offset; }
    void setOffset(FloatPoint offset) { m_offset = offset; }
    bool animationCallbacksRunning() const { return m_animationCallbacksRunning; }
    uint64_t scrollCount() const { return m_scrollCount; }

    struct TimerRecord {
        uint64_t id { 0 };
        ScrollingEffectsControllerTimer* timer { nullptr };
        bool alive { false };
    };
    std::vector<TimerRecord>& timers() { return m_timers; }

    // Fires each live, scheduled timer in creation order, as its run loop would: the one-shot timer is
    // invalidated, then fired. A callback may destroy its own timer.
    unsigned fireTimers()
    {
        unsigned fired = 0;
        // A timer created by a callback waits for the next call.
        size_t count = m_timers.size();
        for (size_t i = 0; i < count; ++i) {
            if (!m_timers[i].alive || !m_timers[i].timer->isActive())
                continue;
            auto* timer = m_timers[i].timer;
            TraceLine(m_trace, 'T', "fire").u("id", m_timers[i].id);
            timer->stop();
            timer->fired();
            ++fired;
        }
        return fired;
    }

    // ScrollingEffectsControllerClient
    std::unique_ptr<ScrollingEffectsControllerTimer> createTimer(Function<void()>&& callback) final
    {
        uint64_t id = m_timers.size() + 1;
        TraceLine(m_trace, 'C', "createTimer").u("id", id);
        auto timer = makeUnique<ScrollingEffectsControllerTimer>(RunLoop::currentSingleton(), [callback = WTF::move(callback), lifetime = TimerLifetime(*this, id - 1)] {
            callback();
        });
        m_timers.push_back({ id, timer.get(), true });
        return timer;
    }

    void destroyTimer(std::unique_ptr<ScrollingEffectsControllerTimer> timer) final
    {
        TraceLine(m_trace, 'C', "destroyTimer").u("id", idForTimer(timer.get()));
        timer = nullptr;
    }

    void startAnimationCallback(ScrollingEffectsController&) final
    {
        TraceLine(m_trace, 'C', "startAnimationCallback").b("wasRunning", m_animationCallbacksRunning);
        m_animationCallbacksRunning = true;
    }

    void stopAnimationCallback(ScrollingEffectsController&) final
    {
        TraceLine(m_trace, 'C', "stopAnimationCallback").b("wasRunning", m_animationCallbacksRunning);
        m_animationCallbacksRunning = false;
    }

    KeyboardScrollingAnimator* keyboardScrollingAnimator() const final
    {
        TraceLine(m_trace, 'C', "keyboardScrollingAnimator");
        return nullptr;
    }

    bool allowsHorizontalScrolling() const final
    {
        TraceLine(m_trace, 'C', "allowsHorizontalScrolling").b("r", m_config.allowsHorizontalScrolling);
        return m_config.allowsHorizontalScrolling;
    }

    bool allowsVerticalScrolling() const final
    {
        TraceLine(m_trace, 'C', "allowsVerticalScrolling").b("r", m_config.allowsVerticalScrolling);
        return m_config.allowsVerticalScrolling;
    }

    inline void immediateScrollBy(const FloatSize&, ScrollClamping = ScrollClamping::Clamped) final;

    void adjustScrollPositionToBoundsIfNecessary() final
    {
        TraceLine(m_trace, 'C', "adjustScrollPositionToBoundsIfNecessary");
        auto constrained = clampedOffset(m_offset);
        immediateScrollBy(constrained - m_offset, ScrollClamping::Clamped);
    }

    bool allowsHorizontalStretching(const PlatformWheelEvent&) const final
    {
        TraceLine(m_trace, 'C', "allowsHorizontalStretching").b("r", m_config.allowsHorizontalStretching);
        return m_config.allowsHorizontalStretching;
    }

    bool allowsVerticalStretching(const PlatformWheelEvent&) const final
    {
        TraceLine(m_trace, 'C', "allowsVerticalStretching").b("r", m_config.allowsVerticalStretching);
        return m_config.allowsVerticalStretching;
    }

    IntSize stretchAmount() const final
    {
        auto stretch = currentStretch();
        TraceLine(m_trace, 'C', "stretchAmount").isz("r", stretch);
        return stretch;
    }

    bool isScrollDeltaOpposingStretch(ScrollEventAxis axis, float delta) const final
    {
        bool result = ScrollingEffectsController::isScrollDeltaOpposingStretch(currentStretch(), axis, delta);
        TraceLine(m_trace, 'C', "isScrollDeltaOpposingStretch").u("axis", static_cast<uint8_t>(axis)).f("delta", delta).b("r", result);
        return result;
    }

    bool isPinnedOnSide(BoxSide side) const final
    {
        bool result = pinned(side);
        TraceLine(m_trace, 'C', "isPinnedOnSide").u("side", static_cast<uint8_t>(side)).b("r", result);
        return result;
    }

    RectEdges<bool> edgePinnedState() const final
    {
        RectEdges<bool> result { pinned(BoxSide::Top), pinned(BoxSide::Right), pinned(BoxSide::Bottom), pinned(BoxSide::Left) };
        TraceLine(m_trace, 'C', "edgePinnedState").edges("r", result);
        return result;
    }

    bool shouldRubberBandOnSide(BoxSide side, FloatSize delta) const final
    {
        bool result = m_config.rubberBandSides & (1 << static_cast<uint8_t>(side));
        TraceLine(m_trace, 'C', "shouldRubberBandOnSide").u("side", static_cast<uint8_t>(side)).sz("delta", delta).b("r", result);
        return result;
    }

    void willStartRubberBandAnimation() final { TraceLine(m_trace, 'C', "willStartRubberBandAnimation"); }
    void didStopRubberBandAnimation() final { TraceLine(m_trace, 'C', "didStopRubberBandAnimation"); }
    void rubberBandingStateChanged(bool inRubberBand) final { TraceLine(m_trace, 'C', "rubberBandingStateChanged").b("v", inRubberBand); }

    FloatSize rubberBandTargetOffset() const final
    {
        TraceLine(m_trace, 'C', "rubberBandTargetOffset").sz("r", m_config.rubberBandTargetOffset);
        return m_config.rubberBandTargetOffset;
    }

    bool hasRefreshController() const final
    {
        TraceLine(m_trace, 'C', "hasRefreshController").b("r", m_config.hasRefreshController);
        return m_config.hasRefreshController;
    }

    float refreshControllerSnappingThreshold() const final
    {
        TraceLine(m_trace, 'C', "refreshControllerSnappingThreshold").f("r", m_config.refreshControllerSnappingThreshold);
        return m_config.refreshControllerSnappingThreshold;
    }

    void deferWheelEventTestCompletionForReason(ScrollingNodeID nodeID, WheelEventTestMonitor::DeferReason reason) const final
    {
        TraceLine(m_trace, 'C', "deferWheelEventTestCompletionForReason").u("node", nodeID.object().toUInt64()).u("reason", static_cast<uint16_t>(reason));
    }

    void removeWheelEventTestCompletionDeferralForReason(ScrollingNodeID nodeID, WheelEventTestMonitor::DeferReason reason) const final
    {
        TraceLine(m_trace, 'C', "removeWheelEventTestCompletionDeferralForReason").u("node", nodeID.object().toUInt64()).u("reason", static_cast<uint16_t>(reason));
    }

    FloatPoint scrollOffset() const final
    {
        auto result = reportedOffset();
        TraceLine(m_trace, 'C', "scrollOffset").pt("r", result);
        return result;
    }

    void willStartAnimatedScroll() final { TraceLine(m_trace, 'C', "willStartAnimatedScroll"); }
    void didStopAnimatedScroll() final { TraceLine(m_trace, 'C', "didStopAnimatedScroll"); }
    void willStartWheelEventScroll() final { TraceLine(m_trace, 'C', "willStartWheelEventScroll"); }
    void didStopWheelEventScroll() final { TraceLine(m_trace, 'C', "didStopWheelEventScroll"); }
    void willStartScrollSnapAnimation() final { TraceLine(m_trace, 'C', "willStartScrollSnapAnimation"); }
    void didStopScrollSnapAnimation() final { TraceLine(m_trace, 'C', "didStopScrollSnapAnimation"); }

    float pageScaleFactor() const final
    {
        TraceLine(m_trace, 'C', "pageScaleFactor").f("r", m_config.pageScaleFactor);
        return m_config.pageScaleFactor;
    }

    ScrollExtents scrollExtents() const final
    {
        TraceLine(m_trace, 'C', "scrollExtents").sz("contents", m_config.contentsSize).sz("viewport", m_config.viewportSize).sz("snapport", m_config.snapportSize);
        return extentsFor(m_config);
    }

    bool scrollAnimationEnabled() const final
    {
        TraceLine(m_trace, 'C', "scrollAnimationEnabled").b("r", m_config.scrollAnimationEnabled);
        return m_config.scrollAnimationEnabled;
    }

    ScrollingNodeID scrollingNodeIDForTesting() const final
    {
        TraceLine(m_trace, 'C', "scrollingNodeIDForTesting").u("r", m_config.scrollingNodeID);
        return ScrollingNodeID { ObjectIdentifier<ScrollingNodeIDType>(m_config.scrollingNodeID), ProcessIdentifier(1) };
    }

    FloatPoint maximumOffset() const { return extentsFor(m_config).maximumScrollOffset(); }

    FloatPoint clampedOffset(FloatPoint offset) const
    {
        auto maximum = maximumOffset();
        return { std::clamp(offset.x(), 0.0f, maximum.x()), std::clamp(offset.y(), 0.0f, maximum.y()) };
    }

    FloatPoint reportedOffset() const
    {
        if (!m_config.roundScrollOffset)
            return m_offset;
        return { std::round(m_offset.x()), std::round(m_offset.y()) };
    }

    IntSize currentStretch() const
    {
        auto offset = reportedOffset();
        auto maximum = maximumOffset();
        auto stretch = [](float value, float maximum) -> int {
            if (value < 0)
                return static_cast<int>(value);
            if (value > maximum)
                return static_cast<int>(value - maximum);
            return 0;
        };
        return { stretch(offset.x(), maximum.x()), stretch(offset.y(), maximum.y()) };
    }

    bool pinned(BoxSide side) const
    {
        if (m_config.pinnedSides)
            return *m_config.pinnedSides & (1 << static_cast<uint8_t>(side));
        auto offset = reportedOffset();
        auto maximum = maximumOffset();
        switch (side) {
        case BoxSide::Top:
            return offset.y() <= 0;
        case BoxSide::Right:
            return offset.x() >= maximum.x();
        case BoxSide::Bottom:
            return offset.y() >= maximum.y();
        case BoxSide::Left:
            return offset.x() <= 0;
        }
        return false;
    }

private:
    // Captured by each timer's callback: its destruction is the timer's.
    class TimerLifetime {
    public:
        TimerLifetime(RecordingClient& client, size_t index)
            : m_client(&client)
            , m_index(index)
        {
        }

        TimerLifetime(TimerLifetime&& other)
            : m_client(std::exchange(other.m_client, nullptr))
            , m_index(other.m_index)
        {
        }

        TimerLifetime(const TimerLifetime&) = delete;

        ~TimerLifetime()
        {
            if (!m_client)
                return;
            auto& record = m_client->m_timers[m_index];
            record.alive = false;
            record.timer = nullptr;
            TraceLine(m_client->m_trace, 'T', "destroyed").u("id", record.id);
        }

    private:
        RecordingClient* m_client;
        size_t m_index;
    };

    uint64_t idForTimer(ScrollingEffectsControllerTimer* timer) const
    {
        for (auto& record : m_timers) {
            if (record.alive && record.timer == timer)
                return record.id;
        }
        return 0;
    }

    inline void reenter();

    Trace& m_trace;
    ScriptedConfig m_config;
    FloatPoint m_offset;
    ControllerHost* m_host { nullptr };
    bool m_animationCallbacksRunning { false };
    uint64_t m_scrollCount { 0 };
    std::vector<TimerRecord> m_timers;
};

// MARK: - Controller host

// Holds a ScrollingEffectsController without depending on its size or layout: the object is constructed in a
// buffer larger than any configuration of the class, and destroyed with a non-virtual destructor call. Only
// out-of-line members are called through it.
class ControllerHost {
    WTF_MAKE_NONCOPYABLE(ControllerHost);
public:
    static constexpr size_t storageSize = 4096;
    static constexpr size_t storageAlignment = 64;

    explicit ControllerHost(RecordingClient& client)
        : m_client(client)
    {
        static_assert(sizeof(ScrollingEffectsController) <= storageSize / 4, "ControllerHost storage must leave a wide margin");
        static_assert(alignof(ScrollingEffectsController) <= storageAlignment);
        std::memset(m_storage, 0xA5, sizeof(m_storage));
        m_controller = new (m_storage) ScrollingEffectsController(client);
        client.setHost(this);
    }

    ~ControllerHost()
    {
        m_controller->stopAllTimers();
        m_controller->ScrollingEffectsController::~ScrollingEffectsController();
        m_client.setHost(nullptr);
    }

    ScrollingEffectsController& controller() { return *m_controller; }

private:
    alignas(storageAlignment) unsigned char m_storage[storageSize];
    RecordingClient& m_client;
    ScrollingEffectsController* m_controller { nullptr };
};

// MARK: - Steps

enum class Op : uint8_t {
    Wheel, // updateGestureInProgressState() then handleWheelEvent(), as ScrollAnimator does.
    WheelOnly, // handleWheelEvent() alone, as the scrolling tree's delegate does.
    GestureState, // updateGestureInProgressState() alone.
    WheelForScrollSnap, // processWheelEventForScrollSnap().
    Frames, // animationCallback() at 120 Hz while the client's callbacks run, at most count frames.
    RetargetFrames, // As Frames, with retargetAnimatedScroll() before each frame.
    AdvanceClock,
    StartAnimatedScroll,
    RetargetAnimatedScroll, // To a, or with flag to the client's offset.
    RetargetAnimatedScrollBy,
    StopAnimatedScroll,
    StopAnimatedNonRubberbandingScroll,
    StartKeyboardScroll,
    FinishKeyboardScroll,
    ContentsSizeChanged,
    SetSnapOffsetsInfo,
    SetActiveScrollSnapIndex,
    UpdateActiveScrollSnapIndex,
    ResnapAfterLayout,
    AdjustedScrollDestination,
    ScrollPositionChanged,
    StopRubberBanding,
    StartRubberBandSnapBack,
    RubberBandTargetOffsetDidChange,
    CaptureRestoreRubberbanding, // captureRubberbandingState(), then restoreRubberbandingState() of the result.
    RestoreRubberbanding,
    FireTimers,
    SetConfig, // Replaces the scripted configuration; flag also sets the offset to a.
    SetPrediction,
    Snapshot,
    WheelDeltaBiasingTowardsVertical,
};

struct Step {
    Op op;
    WheelDescription wheel { };
    FloatPoint a { };
    FloatSize size { };
    unsigned count { 0 };
    bool flag { false };
    ScrollEventAxis axis { ScrollEventAxis::Vertical };
    std::optional<float> optionalFloat { };
    std::optional<unsigned> optionalIndex { };
    float value { 0 };
    ScrollSnapPointSelectionMethod method { ScrollSnapPointSelectionMethod::Closest };
    KeyboardScroll keyboard { };
    unsigned snapInfo { 0 };
    double seconds { 0 };
    ScriptedConfig config { };
    RubberbandingState rubberbanding { };
};

struct Case {
    std::string name;
    unsigned group { 0 };
    ScriptedConfig config;
    FloatPoint offset;
    std::vector<LayoutScrollSnapOffsetsInfo> snapInfos;
    std::vector<Step> steps;
    bool predictionEnabled { true };
};

inline constexpr double frameInterval = 1.0 / 120;
inline constexpr double caseStartTime = 1000;
inline constexpr unsigned defaultFrameLimit = 2000;

// MARK: - Driver

class Driver {
public:
    Driver(Trace& trace, const Case& testCase, bool snapshotEveryStep)
        : m_trace(trace)
        , m_case(testCase)
        , m_snapshotEveryStep(snapshotEveryStep)
        , m_client(trace, testCase.config, testCase.offset)
    {
    }

    // Runs the case from a new controller to its destruction.
    void run()
    {
        TraceLine(m_trace, 'X', "case").u("group", m_case.group);
        ScrollingMomentumCalculator::setPlatformMomentumScrollingPredictionEnabled(m_case.predictionEnabled);
        {
            ControllerHost host(m_client);
            m_host = &host;
            for (auto& step : m_case.steps) {
                perform(step);
                if (m_snapshotEveryStep && step.op != Op::Snapshot)
                    snapshot();
            }
            if (m_trace.level() == TraceLevel::Full)
                snapshot();
            m_host = nullptr;
        }
        ScrollingMomentumCalculator::setPlatformMomentumScrollingPredictionEnabled(true);
        TraceLine(m_trace, 'X', "end").u("scrolls", m_client.scrollCount()).u("clockReads", scriptedClock().reads);
    }

    RecordingClient& client() { return m_client; }
    ScrollingEffectsController& controller() { return m_host->controller(); }

    void perform(const Step& step)
    {
        auto& controller = m_host->controller();
        switch (step.op) {
        case Op::Wheel:
        case Op::WheelOnly:
        case Op::GestureState:
        case Op::WheelForScrollSnap: {
            // The event comes `seconds` after the previous one, and never before the clock.
            auto& clock = scriptedClock();
            auto wheel = step.wheel;
            wheel.timestamp = std::max(m_lastEventTime + step.seconds, clock.now);
            m_lastEventTime = wheel.timestamp;
            clock.now = wheel.timestamp;
            TestWheelEvent event(wheel);
            if (step.op == Op::Wheel || step.op == Op::GestureState) {
                {
                    TraceLine line(m_trace, 'E', "updateGestureInProgressState");
                    traceWheel(line, wheel);
                }
                m_trace.countEntry();
                controller.updateGestureInProgressState(event);
            }
            if (step.op == Op::Wheel || step.op == Op::WheelOnly) {
                {
                    TraceLine line(m_trace, 'E', "handleWheelEvent");
                    traceWheel(line, wheel);
                }
                m_trace.countEntry();
                bool handled = controller.handleWheelEvent(event);
                TraceLine(m_trace, 'R', "handleWheelEvent", true).b("r", handled);
            }
            if (step.op == Op::WheelForScrollSnap) {
                {
                    TraceLine line(m_trace, 'E', "processWheelEventForScrollSnap");
                    traceWheel(line, wheel);
                }
                m_trace.countEntry();
                bool handled = controller.processWheelEventForScrollSnap(event);
                TraceLine(m_trace, 'R', "processWheelEventForScrollSnap", true).b("r", handled);
            }
            break;
        }
        case Op::Frames:
        case Op::RetargetFrames: {
            unsigned limit = step.count ? step.count : defaultFrameLimit;
            for (unsigned frame = 0; frame < limit && m_client.animationCallbacksRunning(); ++frame) {
                if (step.op == Op::RetargetFrames) {
                    // A destination that moves every frame: a + size * ((frame % 7) - 3).
                    float k = static_cast<float>(static_cast<int>(frame % 7) - 3);
                    retargetAnimatedScroll(controller, FloatPoint(step.a.x() + step.size.width() * k, step.a.y() + step.size.height() * k));
                }
                auto& clock = scriptedClock();
                clock.now += frameInterval;
                auto time = MonotonicTime::fromRawSeconds(clock.now);
                TraceLine(m_trace, 'E', "animationCallback").t("t", time);
                m_trace.countEntry();
                controller.animationCallback(time);
            }
            break;
        }
        case Op::AdvanceClock:
            scriptedClock().now += step.seconds;
            TraceLine(m_trace, 'T', "advance").d("s", step.seconds);
            break;
        case Op::StartAnimatedScroll: {
            TraceLine(m_trace, 'E', "startAnimatedScrollToDestination").pt("from", step.a).pt("to", FloatPoint(step.size));
            m_trace.countEntry();
            bool result = controller.startAnimatedScrollToDestination(step.a, FloatPoint(step.size));
            TraceLine(m_trace, 'R', "startAnimatedScrollToDestination", true).b("r", result);
            break;
        }
        case Op::RetargetAnimatedScroll:
            retargetAnimatedScroll(controller, step.flag ? m_client.offset() : step.a);
            break;
        case Op::RetargetAnimatedScrollBy: {
            TraceLine(m_trace, 'E', "retargetAnimatedScrollBy").sz("delta", step.size);
            m_trace.countEntry();
            bool result = controller.retargetAnimatedScrollBy(step.size);
            TraceLine(m_trace, 'R', "retargetAnimatedScrollBy", true).b("r", result);
            break;
        }
        case Op::StopAnimatedScroll:
            TraceLine(m_trace, 'E', "stopAnimatedScroll");
            m_trace.countEntry();
            controller.stopAnimatedScroll();
            break;
        case Op::StopAnimatedNonRubberbandingScroll:
            TraceLine(m_trace, 'E', "stopAnimatedNonRubberbandingScroll");
            m_trace.countEntry();
            controller.stopAnimatedNonRubberbandingScroll();
            break;
        case Op::StartKeyboardScroll:
            startKeyboardScroll(controller, step.keyboard);
            break;
        case Op::FinishKeyboardScroll:
            TraceLine(m_trace, 'E', "finishKeyboardScroll").b("immediate", step.flag);
            m_trace.countEntry();
            controller.finishKeyboardScroll(step.flag);
            break;
        case Op::ContentsSizeChanged:
            TraceLine(m_trace, 'E', "contentsSizeChanged");
            m_trace.countEntry();
            controller.contentsSizeChanged();
            break;
        case Op::SetSnapOffsetsInfo: {
            const auto& info = m_case.snapInfos.at(step.snapInfo);
            {
                TraceLine line(m_trace, 'E', "setSnapOffsetsInfo");
                traceSnapInfo(line, info);
            }
            m_trace.countEntry();
            controller.setSnapOffsetsInfo(info);
            m_lastSnapInfo = &info;
            break;
        }
        case Op::SetActiveScrollSnapIndex:
            TraceLine(m_trace, 'E', "setActiveScrollSnapIndexForAxis").u("axis", static_cast<uint8_t>(step.axis)).optu("index", step.optionalIndex);
            m_trace.countEntry();
            controller.setActiveScrollSnapIndexForAxis(step.axis, step.optionalIndex);
            break;
        case Op::UpdateActiveScrollSnapIndex:
            TraceLine(m_trace, 'E', "updateActiveScrollSnapIndexForClientOffset");
            m_trace.countEntry();
            controller.updateActiveScrollSnapIndexForClientOffset();
            break;
        case Op::ResnapAfterLayout:
            TraceLine(m_trace, 'E', "resnapAfterLayout");
            m_trace.countEntry();
            controller.resnapAfterLayout();
            break;
        case Op::AdjustedScrollDestination: {
            TraceLine(m_trace, 'E', "adjustedScrollDestination").u("axis", static_cast<uint8_t>(step.axis)).pt("destination", step.a).f("velocity", step.value).optf("original", step.optionalFloat).u("method", static_cast<uint8_t>(step.method));
            m_trace.countEntry();
            float result = controller.adjustedScrollDestination(step.axis, step.a, step.value, step.optionalFloat, step.method);
            TraceLine(m_trace, 'R', "adjustedScrollDestination", true).f("r", result);
            break;
        }
        case Op::ScrollPositionChanged:
            TraceLine(m_trace, 'E', "scrollPositionChanged");
            m_trace.countEntry();
            controller.scrollPositionChanged();
            break;
        case Op::StopRubberBanding:
            TraceLine(m_trace, 'E', "stopRubberBanding");
            m_trace.countEntry();
            controller.stopRubberBanding();
            break;
        case Op::StartRubberBandSnapBack:
            TraceLine(m_trace, 'E', "startRubberBandSnapBack");
            m_trace.countEntry();
            controller.startRubberBandSnapBack();
            break;
        case Op::RubberBandTargetOffsetDidChange:
            TraceLine(m_trace, 'E', "rubberBandTargetOffsetDidChange");
            m_trace.countEntry();
            controller.rubberBandTargetOffsetDidChange();
            break;
        case Op::CaptureRestoreRubberbanding: {
            auto state = captureRubberbandingState(controller);
            if (step.seconds)
                scriptedClock().now += step.seconds;
            if (state)
                restoreRubberbandingState(controller, *state);
            break;
        }
        case Op::RestoreRubberbanding:
            restoreRubberbandingState(controller, step.rubberbanding);
            break;
        case Op::FireTimers: {
            if (step.seconds)
                scriptedClock().now += step.seconds;
            unsigned fired = m_client.fireTimers();
            TraceLine(m_trace, 'T', "fired").u("n", fired);
            break;
        }
        case Op::SetConfig:
            m_client.config() = step.config;
            if (step.flag)
                m_client.setOffset(step.a);
            TraceLine(m_trace, 'T', "config").pt("offset", m_client.offset());
            break;
        case Op::SetPrediction:
            TraceLine(m_trace, 'E', "setPlatformMomentumScrollingPredictionEnabled").b("v", step.flag);
            ScrollingMomentumCalculator::setPlatformMomentumScrollingPredictionEnabled(step.flag);
            break;
        case Op::Snapshot:
            snapshot();
            break;
        case Op::WheelDeltaBiasingTowardsVertical: {
            TraceLine(m_trace, 'E', "wheelDeltaBiasingTowardsVertical").sz("delta", step.size);
            m_trace.countEntry();
            auto result = ScrollingEffectsController::wheelDeltaBiasingTowardsVertical(step.size);
            TraceLine(m_trace, 'R', "wheelDeltaBiasingTowardsVertical", true).sz("r", result);
            break;
        }
        }
    }

    // State read through the controller's out-of-line members, and the client's own state.
    void snapshot()
    {
        auto& controller = m_host->controller();
        m_trace.countEntry();
        bool userScroll = controller.isUserScrollInProgress();
        m_trace.countEntry();
        bool snapInProgress = controller.isScrollSnapInProgress();
        m_trace.countEntry();
        bool rubberBand = controller.isRubberBandInProgress();
        m_trace.countEntry();
        bool usesSnap = controller.usesScrollSnap();
        m_trace.countEntry();
        auto horizontalIndex = controller.activeScrollSnapIndexForAxis(ScrollEventAxis::Horizontal);
        m_trace.countEntry();
        auto verticalIndex = controller.activeScrollSnapIndexForAxis(ScrollEventAxis::Vertical);
        m_trace.countEntry();
        auto* info = controller.snapOffsetsInfo();
        {
            TraceLine line(m_trace, 'S', "state");
            line.b("user", userScroll).b("snap", snapInProgress).b("rubberBand", rubberBand).b("usesSnap", usesSnap)
                .optu("indexH", horizontalIndex).optu("indexV", verticalIndex)
                .b("info", !!info).b("infoEqual", info && m_lastSnapInfo && info->isEqual(*m_lastSnapInfo))
                .pt("offset", m_client.offset()).b("callbacks", m_client.animationCallbacksRunning());
            if (info)
                traceSnapInfo(line, *info);
            for (auto& record : m_client.timers()) {
                line.u("timer", record.id).b("alive", record.alive);
                if (record.alive)
                    line.b("active", record.timer->isActive());
            }
        }
        captureRubberbandingState(controller);
    }

    static void traceSnapInfo(TraceLine& line, const LayoutScrollSnapOffsetsInfo& info)
    {
        line.b("strictness", !!info.strictness);
        if (info.strictness)
            line.u("", static_cast<uint8_t>(*info.strictness));
        line.b("vertical", info.scrollerHasVerticalWritingMode);
        auto offsets = [&](const char* key, const Vector<SnapOffset<LayoutUnit>>& list) {
            line.u(key, list.size());
            for (auto& offset : list) {
                line.u("o", static_cast<uint32_t>(offset.offset.rawValue())).u("stop", static_cast<uint8_t>(offset.stop))
                    .b("large", offset.hasSnapAreaLargerThanViewport).b("focused", offset.isFocused).b("target", offset.isTarget)
                    .u("id", offset.snapTargetID ? offset.snapTargetID->toUInt64() : 0).u("areas", offset.snapAreaIndices.size());
                for (auto index : offset.snapAreaIndices)
                    line.u("", index);
            }
        };
        offsets("h", info.horizontalSnapOffsets);
        offsets("v", info.verticalSnapOffsets);
        line.u("areas", info.snapAreas.size());
        for (auto& area : info.snapAreas)
            line.u("x", static_cast<uint32_t>(area.x().rawValue())).u("y", static_cast<uint32_t>(area.y().rawValue())).u("w", static_cast<uint32_t>(area.width().rawValue())).u("h", static_cast<uint32_t>(area.height().rawValue()));
        line.u("ids", info.snapAreasIDs.size());
        for (auto& id : info.snapAreasIDs)
            line.u("", id.toUInt64());
    }

private:
    void retargetAnimatedScroll(ScrollingEffectsController& controller, FloatPoint destination)
    {
        TraceLine(m_trace, 'E', "retargetAnimatedScroll").pt("to", destination);
        m_trace.countEntry();
        bool result = controller.retargetAnimatedScroll(destination);
        TraceLine(m_trace, 'R', "retargetAnimatedScroll", true).b("r", result);
    }

    void startKeyboardScroll(ScrollingEffectsController& controller, const KeyboardScroll& scroll)
    {
        TraceLine(m_trace, 'E', "startKeyboardScroll").sz("offset", scroll.offset).sz("maximumVelocity", scroll.maximumVelocity).sz("force", scroll.force)
            .u("granularity", static_cast<uint8_t>(scroll.granularity)).u("direction", static_cast<uint8_t>(scroll.direction));
        m_trace.countEntry();
        bool result = controller.startKeyboardScroll(scroll);
        TraceLine(m_trace, 'R', "startKeyboardScroll", true).b("r", result);
    }

    std::optional<RubberbandingState> captureRubberbandingState(ScrollingEffectsController& controller)
    {
        TraceLine(m_trace, 'E', "captureRubberbandingState");
        m_trace.countEntry();
        auto state = controller.captureRubberbandingState();
        TraceLine line(m_trace, 'R', "captureRubberbandingState", true);
        line.b("r", !!state);
        if (state)
            line.sz("velocity", state->initialVelocity).sz("overscroll", state->initialOverscroll).sz("target", state->targetOverscroll)
                .t("start", state->animationStartTime).t("capture", state->captureTime).edges("edges", state->rubberbandingEdges);
        return state;
    }

    void restoreRubberbandingState(ScrollingEffectsController& controller, const RubberbandingState& state)
    {
        TraceLine(m_trace, 'E', "restoreRubberbandingState").sz("velocity", state.initialVelocity).sz("overscroll", state.initialOverscroll).sz("target", state.targetOverscroll)
            .t("start", state.animationStartTime).t("capture", state.captureTime).edges("edges", state.rubberbandingEdges);
        m_trace.countEntry();
        bool result = controller.restoreRubberbandingState(state);
        TraceLine(m_trace, 'R', "restoreRubberbandingState", true).b("r", result);
    }

    Trace& m_trace;
    const Case& m_case;
    bool m_snapshotEveryStep;
    RecordingClient m_client;
    ControllerHost* m_host { nullptr };
    const LayoutScrollSnapOffsetsInfo* m_lastSnapInfo { nullptr };
    double m_lastEventTime { caseStartTime };
};

inline void RecordingClient::immediateScrollBy(const FloatSize& delta, ScrollClamping clamping)
{
    TraceLine(m_trace, 'C', "immediateScrollBy", true).f("w", delta.width()).f("h", delta.height()).u("clamping", static_cast<uint8_t>(clamping));
    ++m_scrollCount;
    auto previous = m_offset;
    auto next = m_offset + delta;
    if (clamping == ScrollClamping::Clamped)
        next = clampedOffset(next);
    m_offset = next;
    if (next != previous)
        reenter();
}

inline void RecordingClient::reenter()
{
    if (!m_host)
        return;
    auto& controller = m_host->controller();
    if (m_config.reentryAction != ReentryAction::None && m_scrollCount == m_config.reentryAtScroll) {
        switch (m_config.reentryAction) {
        case ReentryAction::None:
            break;
        case ReentryAction::StopAnimatedScroll:
            TraceLine(m_trace, 'E', "reentry.stopAnimatedScroll");
            m_trace.countEntry();
            controller.stopAnimatedScroll();
            break;
        case ReentryAction::StartAnimatedScroll: {
            TraceLine(m_trace, 'E', "reentry.startAnimatedScrollToDestination").pt("to", m_config.reentryDestination);
            m_trace.countEntry();
            bool result = controller.startAnimatedScrollToDestination(reportedOffset(), m_config.reentryDestination);
            TraceLine(m_trace, 'R', "reentry.startAnimatedScrollToDestination", true).b("r", result);
            break;
        }
        case ReentryAction::StartKeyboardScroll: {
            KeyboardScroll scroll;
            scroll.offset = { 0, 40 };
            scroll.direction = ScrollDirection::ScrollDown;
            scroll.maximumVelocity = scroll.offset.scaled(KeyboardScrollParameters::parameters().maximumVelocityMultiplier);
            scroll.force = scroll.maximumVelocity.scaled(KeyboardScrollParameters::parameters().springMass / KeyboardScrollParameters::parameters().timeToMaximumVelocity);
            TraceLine(m_trace, 'E', "reentry.startKeyboardScroll");
            m_trace.countEntry();
            bool result = controller.startKeyboardScroll(scroll);
            TraceLine(m_trace, 'R', "reentry.startKeyboardScroll", true).b("r", result);
            break;
        }
        }
    }
    if (!m_config.reentrant)
        return;
    TraceLine(m_trace, 'E', "reentry.scrollPositionChanged");
    m_trace.countEntry();
    controller.scrollPositionChanged();
    TraceLine(m_trace, 'E', "reentry.updateActiveScrollSnapIndexForClientOffset");
    m_trace.countEntry();
    controller.updateActiveScrollSnapIndexForClientOffset();
}

// Runs a list of cases with the scripted clock in place, and returns the trace's digest.
inline uint64_t runCases(Trace& trace, const std::vector<Case>& cases, bool snapshotEveryStep)
{
    ScriptedClockScope clockScope(trace, caseStartTime);
    for (auto& testCase : cases) {
        scriptedClock().now = caseStartTime;
        scriptedClock().reads = 0;
        Driver driver(trace, testCase, snapshotEveryStep);
        driver.run();
    }
    return trace.digest();
}

} // namespace ScrollPhysics
} // namespace TestWebKitAPI
