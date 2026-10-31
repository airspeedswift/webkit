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

// A ScrollableArea that answers from a scripted scroll state and records every call its ScrollAnimator makes on
// it and on its scrollbars controller, a replaced clock, test-fired timers, and a driver that runs a list of
// steps through the animator's public members. ScrollPhysics.cpp and ScrollPhysicsBench.cpp share it.
//
// The animator's virtual members are called through the ...ForTesting() members, which call them from inside WebCore,
// so a binary built against one configuration of ScrollAnimator.h can drive a WebCore built with another, while the
// fields its inline members read keep their offsets.

#include <WebCore/FloatPoint.h>
#include <WebCore/FloatSize.h>
#include <WebCore/IntPoint.h>
#include <WebCore/IntRect.h>
#include <WebCore/IntSize.h>
#include <WebCore/KeyboardScrollingAnimator.h>
#include <WebCore/LayoutRect.h>
#include <WebCore/LayoutUnit.h>
#include <WebCore/PlatformWheelEvent.h>
#include <WebCore/ScrollAnimator.h>
#include <WebCore/ScrollSnapOffsetsInfo.h>
#include <WebCore/ScrollTypes.h>
#include <WebCore/ScrollableArea.h>
#include <WebCore/Scrollbar.h>
#include <WebCore/ScrollbarsController.h>
#include <WebCore/ScrollingEffectsClock.h>
#include <WebCore/ScrollingMomentumCalculator.h>
#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <vector>
#include <wtf/CheckedRef.h>
#include <wtf/MonotonicTime.h>
#include <wtf/RunLoop.h>

namespace TestWebKitAPI {
namespace ScrollPhysics {

using namespace WebCore;

// MARK: - Trace

enum class TraceLevel : uint8_t {
    Full, // Every call on the scrollable area, clock read, timer event, entry and return value.
    Light, // setScrollOffset() offsets and entry return values only.
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

// One event: a kind ('C' call on the scrollable area or its scrollbars controller, 'E' entry, 'R' return,
// 'K' clock read, 'T' timer, 'S' snapshot, 'X' case boundary), a name and its values. An event is hashed only
// when the trace is Full, or when it is marked light. Each value's key names it in the call site; keys are not
// hashed.
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
    TraceLine& ipt(const char* key, IntPoint value) { return u(key, static_cast<uint32_t>(value.x())).u("", static_cast<uint32_t>(value.y())); }
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

// The clock the scroll physics read through scrollingEffectsClockNow(). Each read is traced.
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
    CancelAnimations,
    ScrollToPositionWithAnimation,
    KeyboardPageScroll,
};

struct ScriptedConfig {
    FloatSize contentsSize { 800, 4000 };
    FloatSize viewportSize { 800, 600 };
    FloatSize snapportSize { 800, 600 };
    // Whether each scrollbar is enabled, which is what ScrollableArea::allows*Scrolling() reads.
    bool allowsHorizontalScrolling { true };
    bool allowsVerticalScrolling { true };
    // Automatic elasticity when set, none otherwise.
    bool allowsHorizontalStretching { true };
    bool allowsVerticalStretching { true };
    bool hasScrollableOrRubberbandableAncestor { false };
    float pageScaleFactor { 1 };
    bool scrollAnimatorEnabled { true };
    // The area calls back into its animator from inside its reentryAtScroll'th setScrollOffset().
    ReentryAction reentryAction { ReentryAction::None };
    uint32_t reentryAtScroll { 0 };
    FloatPoint reentryDestination;
};

inline IntSize clampedIntSize(FloatSize size)
{
    return flooredIntSize(size);
}

// MARK: - Timers

// Makes the timers ScrollAnimator asks for, through ScrollAnimator::setTimerFactoryForTesting(), and fires them when
// a step says so instead of from the run loop.
class TimerRecorder {
    WTF_MAKE_NONCOPYABLE(TimerRecorder);
public:
    explicit TimerRecorder(Trace& trace)
        : m_trace(trace)
    {
    }

    struct TimerRecord {
        uint64_t id { 0 };
        ScrollingEffectsControllerTimer* timer { nullptr };
        bool alive { false };
    };
    const std::vector<TimerRecord>& timers() const { return m_timers; }

    std::unique_ptr<ScrollingEffectsControllerTimer> createTimer(Function<void()>&& callback)
    {
        uint64_t id = m_timers.size() + 1;
        TraceLine(m_trace, 'C', "createTimer").u("id", id);
        auto timer = makeUnique<ScrollingEffectsControllerTimer>(RunLoop::currentSingleton(), [callback = WTF::move(callback), lifetime = TimerLifetime(*this, id - 1)] {
            callback();
        });
        m_timers.push_back({ id, timer.get(), true });
        return timer;
    }

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

    static TimerRecorder*& current()
    {
        static TimerRecorder* recorder;
        return recorder;
    }

    static std::unique_ptr<ScrollingEffectsControllerTimer> makeTimer(Function<void()>&& callback)
    {
        return current()->createTimer(WTF::move(callback));
    }

private:
    // Held by each timer's callback, so it is destroyed with the timer.
    class TimerLifetime {
    public:
        TimerLifetime(TimerRecorder& recorder, size_t index)
            : m_recorder(&recorder)
            , m_index(index)
        {
        }

        TimerLifetime(TimerLifetime&& other)
            : m_recorder(std::exchange(other.m_recorder, nullptr))
            , m_index(other.m_index)
        {
        }

        TimerLifetime(const TimerLifetime&) = delete;

        ~TimerLifetime()
        {
            if (!m_recorder)
                return;
            auto& record = m_recorder->m_timers[m_index];
            record.alive = false;
            record.timer = nullptr;
            TraceLine(m_recorder->m_trace, 'T', "destroyed").u("id", record.id);
        }

    private:
        TimerRecorder* m_recorder;
        size_t m_index;
    };

    Trace& m_trace;
    std::vector<TimerRecord> m_timers;
};

class TimerFactoryScope {
    WTF_MAKE_NONCOPYABLE(TimerFactoryScope);
public:
    explicit TimerFactoryScope(TimerRecorder& recorder)
    {
        TimerRecorder::current() = &recorder;
        ScrollAnimator::setTimerFactoryForTesting(TimerRecorder::makeTimer);
    }

    ~TimerFactoryScope()
    {
        ScrollAnimator::setTimerFactoryForTesting(nullptr);
        TimerRecorder::current() = nullptr;
    }
};

// MARK: - Recording scrollbars controller

// Records the calls ScrollAnimator makes on the scrollbars, and keeps the scrollbars from making scroller
// implementations, so no window or AppKit state is involved.
class RecordingScrollbarsController final : public ScrollbarsController {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(RecordingScrollbarsController);
public:
    RecordingScrollbarsController(ScrollableArea& area, Trace& trace)
        : ScrollbarsController(area)
        , m_trace(trace)
    {
    }

    bool shouldRegisterScrollbars() const final { return false; }
    void notifyContentAreaScrolled(const FloatSize& delta) final { TraceLine(m_trace, 'C', "notifyContentAreaScrolled").sz("delta", delta); }
    void cancelAnimations() final { TraceLine(m_trace, 'C', "scrollbarsCancelAnimations"); }
    void didBeginScrollGesture() final { TraceLine(m_trace, 'C', "didBeginScrollGesture"); }
    void didEndScrollGesture() final { TraceLine(m_trace, 'C', "didEndScrollGesture"); }
    void mayBeginScrollGesture() final { TraceLine(m_trace, 'C', "mayBeginScrollGesture"); }

private:
    Trace& m_trace;
};

// MARK: - Recording scrollable area

class RecordingScrollableArea final : public CanMakeCheckedPtr<RecordingScrollableArea, WTF::DefaultedOperatorEqual::No, WTF::CheckedPtrDeleteCheckException::Yes>, public ScrollableArea {
    WTF_MAKE_NONCOPYABLE(RecordingScrollableArea);
    WTF_MAKE_TZONE_ALLOCATED_INLINE(RecordingScrollableArea);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(RecordingScrollableArea);
public:
    RecordingScrollableArea(Trace& trace, const ScriptedConfig& config, FloatPoint position)
        : m_trace(trace)
        , m_config(config)
    {
        m_horizontalScrollbar = Scrollbar::createNativeScrollbar(*this, ScrollbarOrientation::Horizontal, ScrollbarWidth::Auto);
        m_verticalScrollbar = Scrollbar::createNativeScrollbar(*this, ScrollbarOrientation::Vertical, ScrollbarWidth::Auto);
        applyConfig();
        setPosition(position);
        m_ready = true;
    }

    ~RecordingScrollableArea()
    {
        m_ready = false;
        m_horizontalScrollbar = nullptr;
        m_verticalScrollbar = nullptr;
    }

    // CheckedPtr interface
    uint32_t checkedPtrCount() const final { return CanMakeCheckedPtr::checkedPtrCount(); }
    uint32_t checkedPtrCountWithoutThreadCheck() const final { return CanMakeCheckedPtr::checkedPtrCountWithoutThreadCheck(); }
    void incrementCheckedPtrCount() const final { CanMakeCheckedPtr::incrementCheckedPtrCount(); }
    void decrementCheckedPtrCount() const final { CanMakeCheckedPtr::decrementCheckedPtrCount(); }
    void setDidBeginCheckedPtrDeletion() final { CanMakeCheckedPtr::setDidBeginCheckedPtrDeletion(); }

    ScriptedConfig& config() { return m_config; }
    IntPoint position() const { return m_position; }
    uint64_t scrollCount() const { return m_scrollCount; }
    bool animationRequested() const { return m_animationRequested; }
    void animationEnded() { m_animationRequested = false; }

    // The scroll position as WebKit reports one from outside the animator: the area's integral position, and the
    // animator's own position.
    void setPosition(FloatPoint position)
    {
        m_position = roundedIntPoint(position);
        scrollAnimator().setCurrentPosition(position);
    }

    // Applies the scripted extents and policies to the scrollbars, as layout does for a frame.
    void applyConfig()
    {
        auto visible = visibleSize();
        auto contents = contentsSize();
        m_horizontalScrollbar->setSteps(Scrollbar::pixelsPerLineStep(visible.width()), Scrollbar::pageStep(visible.width()));
        m_verticalScrollbar->setSteps(Scrollbar::pixelsPerLineStep(visible.height()), Scrollbar::pageStep(visible.height()));
        m_horizontalScrollbar->setProportion(visible.width(), contents.width());
        m_verticalScrollbar->setProportion(visible.height(), contents.height());
        m_horizontalScrollbar->setEnabled(m_config.allowsHorizontalScrolling);
        m_verticalScrollbar->setEnabled(m_config.allowsVerticalScrolling);
        setHorizontalScrollElasticity(m_config.allowsHorizontalStretching ? ScrollElasticity::Automatic : ScrollElasticity::None);
        setVerticalScrollElasticity(m_config.allowsVerticalStretching ? ScrollElasticity::Automatic : ScrollElasticity::None);
    }

    // ScrollableArea
    bool isActive() const final { return true; }
    bool isScrollCornerVisible() const final { return false; }
    IntRect scrollCornerRect() const final { return { }; }
    bool forceUpdateScrollbarsOnMainThreadForPerformanceTesting() const final { return false; }
    ScrollableArea* enclosingScrollableArea() const final { return nullptr; }
    IntRect scrollableAreaBoundingBox(bool* = nullptr) const final { return { { }, visibleSize() }; }
    bool shouldPlaceVerticalScrollbarOnLeft() const final { return false; }
    String debugDescription() const final { return "RecordingScrollableArea"_s; }
    void invalidateScrollbarRect(Scrollbar&, const IntRect&) final { }
    void invalidateScrollCornerRect(const IntRect&) final { }

    void createScrollbarsController() final
    {
        setScrollbarsController(makeUnique<RecordingScrollbarsController>(*this, m_trace));
    }

    // Not traced: how often the scrollbars are asked for depends on whether they are overlay scrollbars, which
    // follows the system's scroller style.
    Scrollbar* horizontalScrollbar() const final { return m_horizontalScrollbar.get(); }
    Scrollbar* verticalScrollbar() const final { return m_verticalScrollbar.get(); }

    ScrollPosition scrollPosition() const final
    {
        TraceLine(m_trace, 'C', "scrollPosition").ipt("r", m_position);
        return m_position;
    }

    ScrollPosition minimumScrollPosition() const final
    {
        auto result = ScrollableArea::minimumScrollPosition();
        TraceLine(m_trace, 'C', "minimumScrollPosition").ipt("r", result);
        return result;
    }

    ScrollPosition maximumScrollPosition() const final
    {
        auto result = ScrollableArea::maximumScrollPosition();
        TraceLine(m_trace, 'C', "maximumScrollPosition").ipt("r", result);
        return result;
    }

    IntSize visibleSize() const final
    {
        auto result = clampedIntSize(m_config.viewportSize);
        TraceLine(m_trace, 'C', "visibleSize").isz("r", result);
        return result;
    }

    IntSize snapportSize() const final
    {
        auto result = clampedIntSize(m_config.snapportSize);
        TraceLine(m_trace, 'C', "snapportSize").isz("r", result);
        return result;
    }

    IntSize contentsSize() const final
    {
        auto result = clampedIntSize(m_config.contentsSize);
        TraceLine(m_trace, 'C', "contentsSize").isz("r", result);
        return result;
    }

    // As ScrollView: how far the position is past the extents.
    IntSize overhangAmount() const final
    {
        auto position = m_position;
        auto minimum = ScrollableArea::minimumScrollPosition();
        auto maximum = ScrollableArea::maximumScrollPosition();
        auto overhang = [](int value, int minimum, int maximum) -> int {
            if (value < minimum)
                return value - minimum;
            if (value > maximum)
                return value - maximum;
            return 0;
        };
        IntSize result { overhang(position.x(), minimum.x(), maximum.x()), overhang(position.y(), minimum.y(), maximum.y()) };
        TraceLine(m_trace, 'C', "overhangAmount").isz("r", result);
        return result;
    }

    bool isScrollableOrRubberbandable() final
    {
        TraceLine(m_trace, 'C', "isScrollableOrRubberbandable");
        return true;
    }

    bool hasScrollableOrRubberbandableAncestor() final
    {
        TraceLine(m_trace, 'C', "hasScrollableOrRubberbandableAncestor").b("r", m_config.hasScrollableOrRubberbandableAncestor);
        return m_config.hasScrollableOrRubberbandableAncestor;
    }

    float pageScaleFactor() const final
    {
        TraceLine(m_trace, 'C', "pageScaleFactor").f("r", m_config.pageScaleFactor);
        return m_config.pageScaleFactor;
    }

    bool scrollAnimatorEnabled() const final
    {
        TraceLine(m_trace, 'C', "scrollAnimatorEnabled").b("r", m_config.scrollAnimatorEnabled);
        return m_config.scrollAnimatorEnabled;
    }

    bool isUserScrollInProgress() const final
    {
        bool result = existingScrollAnimator() && existingScrollAnimator()->isUserScrollInProgress();
        TraceLine(m_trace, 'C', "isUserScrollInProgress").b("r", result);
        return result;
    }

    bool isRubberBandInProgress() const final
    {
        bool result = existingScrollAnimator() && existingScrollAnimator()->isRubberBandInProgressForTesting();
        TraceLine(m_trace, 'C', "isRubberBandInProgress").b("r", result);
        return result;
    }

    bool isScrollSnapInProgress() const final
    {
        bool result = existingScrollAnimator() && existingScrollAnimator()->isScrollSnapInProgress();
        TraceLine(m_trace, 'C', "isScrollSnapInProgress").b("r", result);
        return result;
    }

    bool requestScrollToPosition(const ScrollPosition& position, const ScrollPositionChangeOptions& options) final
    {
        TraceLine(m_trace, 'C', "requestScrollToPosition").ipt("position", position).u("type", static_cast<uint8_t>(options.type)).u("clamping", static_cast<uint8_t>(options.clamping)).u("animated", static_cast<uint8_t>(options.animated));
        return false;
    }

    bool requestStartKeyboardScrollAnimation(const KeyboardScroll& scroll) final
    {
        TraceLine(m_trace, 'C', "requestStartKeyboardScrollAnimation").sz("offset", scroll.offset).u("granularity", static_cast<uint8_t>(scroll.granularity)).u("direction", static_cast<uint8_t>(scroll.direction));
        return false;
    }

    bool requestStopKeyboardScrollAnimation(bool immediate) final
    {
        TraceLine(m_trace, 'C', "requestStopKeyboardScrollAnimation").b("immediate", immediate);
        return false;
    }

    void didStartScrollAnimation() final
    {
        TraceLine(m_trace, 'C', "didStartScrollAnimation").b("wasRequested", m_animationRequested);
        m_animationRequested = true;
    }

    void animatedScrollDidEnd() final { TraceLine(m_trace, 'C', "animatedScrollDidEnd"); }
    void scrollDidEnd() final { TraceLine(m_trace, 'C', "scrollDidEnd"); }

    void setScrollOffset(const ScrollOffset& offset) final
    {
        TraceLine(m_trace, 'C', "setScrollOffset", true).ipt("offset", offset);
        ++m_scrollCount;
        auto previous = m_position;
        m_position = scrollPositionFromOffset(offset);
        if (m_ready && m_position != previous)
            reenter();
    }

private:
    void reenter()
    {
        if (m_config.reentryAction == ReentryAction::None || m_scrollCount != m_config.reentryAtScroll)
            return;
        auto& animator = scrollAnimator();
        switch (m_config.reentryAction) {
        case ReentryAction::None:
            break;
        case ReentryAction::CancelAnimations:
            TraceLine(m_trace, 'E', "reentry.cancelAnimations");
            m_trace.countEntry();
            animator.cancelAnimations();
            break;
        case ReentryAction::ScrollToPositionWithAnimation: {
            TraceLine(m_trace, 'E', "reentry.scrollToPositionWithAnimation").pt("to", m_config.reentryDestination);
            m_trace.countEntry();
            bool result = animator.scrollToPositionWithAnimation(m_config.reentryDestination);
            TraceLine(m_trace, 'R', "reentry.scrollToPositionWithAnimation", true).b("r", result);
            break;
        }
        case ReentryAction::KeyboardPageScroll: {
            TraceLine(m_trace, 'E', "reentry.beginKeyboardScrollGesture");
            m_trace.countEntry();
            bool result = animator.keyboardScrollingAnimator()->beginKeyboardScrollGesture(ScrollDirection::ScrollDown, ScrollGranularity::Page, false);
            TraceLine(m_trace, 'R', "reentry.beginKeyboardScrollGesture", true).b("r", result);
            break;
        }
        }
    }

    Trace& m_trace;
    ScriptedConfig m_config;
    IntPoint m_position;
    RefPtr<Scrollbar> m_horizontalScrollbar;
    RefPtr<Scrollbar> m_verticalScrollbar;
    bool m_ready { false };
    bool m_animationRequested { false };
    uint64_t m_scrollCount { 0 };
};

// MARK: - Steps

enum class Op : uint8_t {
    Wheel, // handleWheelEvent(), as the event handler sends a wheel event to a scrollable area.
    WheelForScrollSnap, // processWheelEventForScrollSnap().
    Frames, // serviceScrollAnimation() at 120 Hz while the area has an animation scheduled, at most count frames.
    RetargetFrames, // As Frames, with retargetRunningAnimation() before each frame.
    AdvanceClock,
    ScrollToPositionWithAnimation, // To a, clamped unless flag.
    ScrollToPositionWithoutAnimation, // To a.
    RetargetRunningAnimation, // To a, or with flag to the area's position.
    SingleAxisScroll, // By value on axis; count holds the ScrollBehavior bits.
    CancelAnimations,
    SetCurrentPosition, // To a, as when the position changes from outside the animator.
    KeyboardScrollGesture, // KeyboardScrollingAnimator::beginKeyboardScrollGesture(); flag for a key repeat.
    KeyUp, // KeyboardScrollingAnimator::handleKeyUpEvent(), or with flag stopScrollingImmediately().
    StopKeyboardScrollAnimation,
    ContentsSizeChanged,
    SetSnapOffsetsInfo,
    SetActiveScrollSnapIndex,
    ResnapAfterLayout,
    ScrollOffsetAdjustedForSnapping, // On axis, or with flag on both axes.
    FireTimers,
    SetConfig, // Replaces the scripted configuration; flag also sets the position to a.
    SetPrediction,
    Snapshot,
};

struct Step {
    Op op;
    WheelDescription wheel { };
    FloatPoint a { };
    FloatSize size { };
    unsigned count { 0 };
    bool flag { false };
    ScrollEventAxis axis { ScrollEventAxis::Vertical };
    std::optional<unsigned> optionalIndex { };
    float value { 0 };
    ScrollSnapPointSelectionMethod method { ScrollSnapPointSelectionMethod::Closest };
    ScrollDirection direction { ScrollDirection::ScrollDown };
    ScrollGranularity granularity { ScrollGranularity::Line };
    unsigned snapInfo { 0 };
    double seconds { 0 };
    ScriptedConfig config { };
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
        , m_timers(trace)
    {
    }

    // Runs the case from a new scrollable area to its destruction.
    void run()
    {
        TraceLine(m_trace, 'X', "case").u("group", m_case.group);
        ScrollingMomentumCalculator::setPlatformMomentumScrollingPredictionEnabled(m_case.predictionEnabled);
        uint64_t scrolls = 0;
        {
            TimerFactoryScope timerScope(m_timers);
            RecordingScrollableArea area(m_trace, m_case.config, m_case.offset);
            m_area = &area;
            for (auto& step : m_case.steps) {
                perform(step);
                if (m_snapshotEveryStep && step.op != Op::Snapshot)
                    snapshot();
            }
            if (m_trace.level() == TraceLevel::Full)
                snapshot();
            scrolls = area.scrollCount();
            m_area = nullptr;
        }
        ScrollingMomentumCalculator::setPlatformMomentumScrollingPredictionEnabled(true);
        TraceLine(m_trace, 'X', "end").u("scrolls", scrolls).u("clockReads", scriptedClock().reads);
    }

    RecordingScrollableArea& area() { return *m_area; }
    ScrollAnimator& animator() { return m_area->scrollAnimator(); }

    void perform(const Step& step)
    {
        auto& animator = this->animator();
        switch (step.op) {
        case Op::Wheel:
        case Op::WheelForScrollSnap: {
            // The event comes `seconds` after the previous one, and never before the clock.
            auto& clock = scriptedClock();
            auto wheel = step.wheel;
            wheel.timestamp = std::max(m_lastEventTime + step.seconds, clock.now);
            m_lastEventTime = wheel.timestamp;
            clock.now = wheel.timestamp;
            TestWheelEvent event(wheel);
            const char* name = step.op == Op::Wheel ? "handleWheelEvent" : "processWheelEventForScrollSnap";
            {
                TraceLine line(m_trace, 'E', name);
                traceWheel(line, wheel);
            }
            m_trace.countEntry();
            bool handled = step.op == Op::Wheel ? animator.handleWheelEventForTesting(event) : animator.processWheelEventForScrollSnapForTesting(event);
            TraceLine(m_trace, 'R', name, true).b("r", handled);
            break;
        }
        case Op::Frames:
        case Op::RetargetFrames: {
            unsigned limit = step.count ? step.count : defaultFrameLimit;
            for (unsigned frame = 0; frame < limit && m_area->animationRequested(); ++frame) {
                if (step.op == Op::RetargetFrames) {
                    // A destination that moves every frame: a + size * ((frame % 7) - 3).
                    float k = static_cast<float>(static_cast<int>(frame % 7) - 3);
                    retargetRunningAnimation(FloatPoint(step.a.x() + step.size.width() * k, step.a.y() + step.size.height() * k));
                }
                auto& clock = scriptedClock();
                clock.now += frameInterval;
                auto time = MonotonicTime::fromRawSeconds(clock.now);
                TraceLine(m_trace, 'E', "serviceScrollAnimation").t("t", time);
                m_trace.countEntry();
                auto status = animator.serviceScrollAnimation(time);
                TraceLine(m_trace, 'R', "serviceScrollAnimation", true).u("r", static_cast<uint8_t>(status));
                if (status == ScrollAnimationStatus::NotAnimating)
                    m_area->animationEnded();
            }
            break;
        }
        case Op::AdvanceClock:
            scriptedClock().now += step.seconds;
            TraceLine(m_trace, 'T', "advance").d("s", step.seconds);
            break;
        case Op::ScrollToPositionWithAnimation: {
            auto clamping = step.flag ? ScrollClamping::Unclamped : ScrollClamping::Clamped;
            TraceLine(m_trace, 'E', "scrollToPositionWithAnimation").pt("to", step.a).u("clamping", static_cast<uint8_t>(clamping));
            m_trace.countEntry();
            bool result = animator.scrollToPositionWithAnimation(step.a, clamping);
            TraceLine(m_trace, 'R', "scrollToPositionWithAnimation", true).b("r", result);
            break;
        }
        case Op::ScrollToPositionWithoutAnimation: {
            TraceLine(m_trace, 'E', "scrollToPositionWithoutAnimation").pt("to", step.a);
            m_trace.countEntry();
            bool result = animator.scrollToPositionWithoutAnimation(step.a);
            TraceLine(m_trace, 'R', "scrollToPositionWithoutAnimation", true).b("r", result);
            break;
        }
        case Op::RetargetRunningAnimation:
            retargetRunningAnimation(step.flag ? FloatPoint(m_area->position()) : step.a);
            break;
        case Op::SingleAxisScroll: {
            EnumSet<ScrollAnimator::ScrollBehavior> behavior;
            for (auto candidate : { ScrollAnimator::ScrollBehavior::RespectScrollSnap, ScrollAnimator::ScrollBehavior::Paged, ScrollAnimator::ScrollBehavior::NeverAnimate }) {
                if (step.count & (1u << static_cast<uint8_t>(candidate)))
                    behavior.add(candidate);
            }
            TraceLine(m_trace, 'E', "singleAxisScroll").u("axis", static_cast<uint8_t>(step.axis)).f("delta", step.value).u("behavior", step.count);
            m_trace.countEntry();
            bool result = animator.singleAxisScroll(step.axis, step.value, behavior);
            TraceLine(m_trace, 'R', "singleAxisScroll", true).b("r", result);
            break;
        }
        case Op::CancelAnimations:
            TraceLine(m_trace, 'E', "cancelAnimations");
            m_trace.countEntry();
            animator.cancelAnimations();
            break;
        case Op::SetCurrentPosition:
            TraceLine(m_trace, 'E', "setCurrentPosition").pt("to", step.a);
            m_trace.countEntry();
            m_area->setPosition(step.a);
            break;
        case Op::KeyboardScrollGesture: {
            TraceLine(m_trace, 'E', "beginKeyboardScrollGesture").u("direction", static_cast<uint8_t>(step.direction)).u("granularity", static_cast<uint8_t>(step.granularity)).b("repeat", step.flag);
            m_trace.countEntry();
            bool result = animator.keyboardScrollingAnimator()->beginKeyboardScrollGesture(step.direction, step.granularity, step.flag);
            TraceLine(m_trace, 'R', "beginKeyboardScrollGesture", true).b("r", result);
            break;
        }
        case Op::KeyUp:
            TraceLine(m_trace, 'E', step.flag ? "stopScrollingImmediately" : "handleKeyUpEvent");
            m_trace.countEntry();
            if (step.flag)
                animator.keyboardScrollingAnimator()->stopScrollingImmediately();
            else
                animator.keyboardScrollingAnimator()->handleKeyUpEvent();
            break;
        case Op::StopKeyboardScrollAnimation:
            TraceLine(m_trace, 'E', "stopKeyboardScrollAnimation");
            m_trace.countEntry();
            animator.stopKeyboardScrollAnimation();
            break;
        case Op::ContentsSizeChanged:
            TraceLine(m_trace, 'E', "contentsSizeChanged");
            m_trace.countEntry();
            animator.contentsSizeChanged();
            break;
        case Op::SetSnapOffsetsInfo: {
            const auto& info = m_case.snapInfos.at(step.snapInfo);
            {
                TraceLine line(m_trace, 'E', "setSnapOffsetsInfo");
                traceSnapInfo(line, info);
            }
            m_trace.countEntry();
            animator.setSnapOffsetsInfo(info);
            m_lastSnapInfo = &info;
            break;
        }
        case Op::SetActiveScrollSnapIndex:
            TraceLine(m_trace, 'E', "setActiveScrollSnapIndexForAxis").u("axis", static_cast<uint8_t>(step.axis)).optu("index", step.optionalIndex);
            m_trace.countEntry();
            animator.setActiveScrollSnapIndexForAxis(step.axis, step.optionalIndex);
            break;
        case Op::ResnapAfterLayout:
            TraceLine(m_trace, 'E', "resnapAfterLayout");
            m_trace.countEntry();
            animator.resnapAfterLayout();
            break;
        case Op::ScrollOffsetAdjustedForSnapping: {
            TraceLine(m_trace, 'E', "scrollOffsetAdjustedForSnapping").b("both", step.flag).u("axis", static_cast<uint8_t>(step.axis)).pt("offset", step.a).u("method", static_cast<uint8_t>(step.method));
            m_trace.countEntry();
            if (step.flag) {
                auto result = animator.scrollOffsetAdjustedForSnapping(step.a, step.method);
                TraceLine(m_trace, 'R', "scrollOffsetAdjustedForSnapping", true).pt("r", result);
            } else {
                float result = animator.scrollOffsetAdjustedForSnapping(step.axis, step.a, step.method);
                TraceLine(m_trace, 'R', "scrollOffsetAdjustedForSnapping", true).f("r", result);
            }
            break;
        }
        case Op::FireTimers: {
            if (step.seconds)
                scriptedClock().now += step.seconds;
            unsigned fired = m_timers.fireTimers();
            TraceLine(m_trace, 'T', "fired").u("n", fired);
            break;
        }
        case Op::SetConfig:
            m_area->config() = step.config;
            m_area->applyConfig();
            if (step.flag)
                m_area->setPosition(step.a);
            TraceLine(m_trace, 'T', "config").ipt("position", m_area->position());
            break;
        case Op::SetPrediction:
            TraceLine(m_trace, 'E', "setPlatformMomentumScrollingPredictionEnabled").b("v", step.flag);
            ScrollingMomentumCalculator::setPlatformMomentumScrollingPredictionEnabled(step.flag);
            break;
        case Op::Snapshot:
            snapshot();
            break;
        }
    }

    // State read through the animator's out-of-line members, and the area's own state.
    void snapshot()
    {
        auto& animator = this->animator();
        m_trace.countEntry();
        bool userScroll = animator.isUserScrollInProgress();
        m_trace.countEntry();
        bool snapInProgress = animator.isScrollSnapInProgress();
        m_trace.countEntry();
        bool rubberBand = animator.isRubberBandInProgressForTesting();
        m_trace.countEntry();
        bool usesSnap = animator.usesScrollSnap();
        m_trace.countEntry();
        auto horizontalIndex = animator.activeScrollSnapIndexForAxis(ScrollEventAxis::Horizontal);
        m_trace.countEntry();
        auto verticalIndex = animator.activeScrollSnapIndexForAxis(ScrollEventAxis::Vertical);
        m_trace.countEntry();
        bool indexDidChange = animator.activeScrollSnapIndexDidChange();
        m_trace.countEntry();
        auto* info = animator.snapOffsetsInfo();
        TraceLine line(m_trace, 'S', "state");
        line.b("user", userScroll).b("snap", snapInProgress).b("rubberBand", rubberBand).b("usesSnap", usesSnap)
            .optu("indexH", horizontalIndex).optu("indexV", verticalIndex).b("indexDidChange", indexDidChange)
            .b("info", !!info).b("infoEqual", info && m_lastSnapInfo && info->isEqual(*m_lastSnapInfo))
            .ipt("position", m_area->position()).b("animation", m_area->animationRequested())
            .u("status", static_cast<uint8_t>(m_area->scrollAnimationStatus()));
        if (info)
            traceSnapInfo(line, *info);
        for (auto& record : m_timers.timers()) {
            line.u("timer", record.id).b("alive", record.alive);
            if (record.alive)
                line.b("active", record.timer->isActive());
        }
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
    void retargetRunningAnimation(FloatPoint destination)
    {
        TraceLine(m_trace, 'E', "retargetRunningAnimation").pt("to", destination);
        m_trace.countEntry();
        bool result = animator().retargetRunningAnimation(destination);
        TraceLine(m_trace, 'R', "retargetRunningAnimation", true).b("r", result);
    }

    Trace& m_trace;
    const Case& m_case;
    bool m_snapshotEveryStep;
    TimerRecorder m_timers;
    RecordingScrollableArea* m_area { nullptr };
    const LayoutScrollSnapOffsetsInfo* m_lastSnapInfo { nullptr };
    double m_lastEventTime { caseStartTime };
};

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
