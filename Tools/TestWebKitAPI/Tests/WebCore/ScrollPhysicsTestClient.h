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
#include <WebCore/ScrollAlignment.h>
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
    All, // Full, plus the area's answers to the queries that only configurable areas vary.
};

class Trace {
public:
    explicit Trace(TraceLevel level = TraceLevel::Full)
        : m_level(level)
    {
    }

    TraceLevel level() const { return m_level; }
    // With an All trace, also the layers, invalidations, stable state and request options the area is asked for.
    void setTracesAreaQueries(bool traces) { m_tracesAreaQueries = traces; }
    bool tracesAreaQueries() const { return m_level == TraceLevel::All && m_tracesAreaQueries; }
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

    // Sees each recorded event's kind and name, for counting.
    using Observer = void (*)(void* context, char kind, const char* name);
    void setObserver(Observer observer, void* context)
    {
        m_observer = observer;
        m_observerContext = context;
    }

    void observe(char kind, const char* name)
    {
        if (m_observer)
            m_observer(m_observerContext, kind, name);
    }

private:
    static constexpr uint64_t initialHash = 14695981039346656037ull;
    TraceLevel m_level;
    bool m_tracesAreaQueries { false };
    Observer m_observer { nullptr };
    void* m_observerContext { nullptr };
    uint64_t m_hash { initialHash };
    uint64_t m_events { 0 };
    uint64_t m_entries { 0 };
};

// One event: a kind ('C' call on the scrollable area or its scrollbars controller, 'E' entry, 'R' return,
// 'K' clock read, 'T' timer, 'S' snapshot, 'X' case boundary), a name and its values. An event is hashed only
// when the trace is Full, or when it is marked light. Each value's key names it in the call site; keys are not
// hashed.
// An All trace hashes every event a Full trace does.
class TraceLine {
public:
    TraceLine(Trace& trace, char kind, const char* name, bool light = false)
        : m_trace(trace)
        , m_active(trace.level() == TraceLevel::Full || light)
    {
        m_active = m_active || trace.level() == TraceLevel::All;
        if (!m_active)
            return;
        m_trace.countEvent();
        m_trace.observe(kind, name);
        if (m_trace.level() == TraceLevel::Full) {
            m_trace.bytes(&kind, 1);
            m_trace.bytes(name, std::strlen(name) + 1);
        }
        if (m_trace.level() == TraceLevel::All) {
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

    TraceLine& lu(const char* key, LayoutUnit value) { return u(key, static_cast<uint32_t>(value.rawValue())); }
    TraceLine& lpt(const char* key, const LayoutPoint& value) { return lu(key, value.x()).lu("", value.y()); }
    TraceLine& lrect(const char* key, const LayoutRect& value) { return lu(key, value.x()).lu("", value.y()).lu("", value.width()).lu("", value.height()); }

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
    SetCurrentPosition,
    ScrollToPositionWithoutAnimation,
    // ScrollableArea's own members, called on the area.
    AreaScrollToPositionWithAnimation,
    AreaScrollToOffsetWithoutAnimation,
    AreaScroll,
    AreaResnapAfterLayout,
    NotifyScrollPositionChanged,
    SetScrollOffsetFromInternals,
    // Puts the horizontal scrollbar aside, as when layout removes it.
    HideHorizontalScrollbar,
    // Releases the area's reference to its vertical scrollbar.
    DropVerticalScrollbar,
};

// Where the area calls reentryAction from.
enum class ReentryPoint : uint8_t {
    SetScrollOffset, // The reentryAtScroll'th setScrollOffset() that changes the position.
    RequestScrollToPosition, // The reentryAtScroll'th requestScrollToPosition().
    InvalidateScrollbar, // The reentryAtScroll'th scrollbar invalidation.
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
    // Without a scrollbar the area returns null for it.
    bool hasHorizontalScrollbar { true };
    bool hasVerticalScrollbar { true };
    // Each scrollbar's pixels per step, by which stepped scrolling multiplies a wheel delta.
    int horizontalPixelStep { 1 };
    int verticalPixelStep { 1 };
    // Replaces the elasticity that allows*Stretching gives, when set.
    std::optional<ScrollElasticity> horizontalScrollElasticity;
    std::optional<ScrollElasticity> verticalScrollElasticity;
    OverscrollBehavior horizontalOverscrollBehavior { OverscrollBehavior::Auto };
    OverscrollBehavior verticalOverscrollBehavior { OverscrollBehavior::Auto };
    // As a list box: wheel events scroll by whole steps.
    bool hasSteppedScrolling { false };
    // Non-zero for right-to-left or bottom-to-top content.
    IntPoint scrollOrigin;
    // Taken off the vertical page step, as for fixed headers and footers.
    float fixedContentPageStepAdjustment { 0 };
    // Makes isUserScrollInProgress() answer true whatever the animator says.
    bool userScrollInProgress { false };
    // What requestStartKeyboardScrollAnimation() and requestStopKeyboardScrollAnimation() answer.
    bool startsKeyboardScrollAnimation { false };
    bool stopsKeyboardScrollAnimation { false };
    // Without it the area makes no ScrollAnimator until something asks for one.
    bool createsScrollAnimator { true };
    ReentryPoint reentryPoint { ReentryPoint::SetScrollOffset };
    // What requestScrollToPosition() answers.
    bool requestsScrollToPosition { false };
    bool inStableState { true };
    // Makes isScrollSnapInProgress() answer true whatever the animator says.
    bool scrollSnapInProgress { false };
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
        if (!m_config.createsScrollAnimator)
            m_position = roundedIntPoint(position);
        else
            setPosition(position);
        m_ready = true;
    }

    ~RecordingScrollableArea()
    {
        m_ready = false;
        m_horizontalScrollbar = nullptr;
        m_verticalScrollbar = nullptr;
        m_hiddenHorizontalScrollbar = nullptr;
        m_hiddenVerticalScrollbar = nullptr;
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
    unsigned maximumReentryDepth() const { return m_maximumReentryDepth; }
    bool animationRequested() const { return m_animationRequested; }
    void animationEnded() { m_animationRequested = false; }

    // The scroll position as WebKit reports one from outside the animator: the area's integral position, and the
    // animator's own position.
    void setPosition(FloatPoint position)
    {
        m_position = roundedIntPoint(position);
        scrollAnimator().setCurrentPosition(position);
    }

    // The area's integral position only, as a subclass scrolls its own contents, leaving the animator as it is.
    void setAreaPosition(FloatPoint position)
    {
        m_position = roundedIntPoint(position);
    }

    void setAreaPosition(IntPoint position)
    {
        m_position = position;
    }

    LayoutRect rectToExposeForScrollIntoView(const LayoutRect& visibleBounds, const LayoutRect& exposeRect, const ScrollAlignment& alignX, const ScrollAlignment& alignY, const std::optional<LayoutRect>& visibilityCheckRect) const
    {
        return getRectToExposeForScrollIntoView(visibleBounds, exposeRect, alignX, alignY, visibilityCheckRect);
    }

    // Applies the scripted extents and policies to the scrollbars, as layout does for a frame.
    void applyConfig()
    {
        if (m_hiddenHorizontalScrollbar)
            m_horizontalScrollbar = std::exchange(m_hiddenHorizontalScrollbar, nullptr);
        if (m_hiddenVerticalScrollbar)
            m_verticalScrollbar = std::exchange(m_hiddenVerticalScrollbar, nullptr);
        if (!m_verticalScrollbar)
            m_verticalScrollbar = Scrollbar::createNativeScrollbar(*this, ScrollbarOrientation::Vertical, ScrollbarWidth::Auto);
        // As layout sets the origin, but leaving scrollOriginChanged() false: ScrollableArea::setScrollOrigin() is
        // not exported.
        const_cast<IntPoint&>(scrollOrigin()) = m_config.scrollOrigin;
        auto visible = visibleSize();
        auto contents = contentsSize();
        m_horizontalScrollbar->setSteps(Scrollbar::pixelsPerLineStep(visible.width()), Scrollbar::pageStep(visible.width()));
        m_verticalScrollbar->setSteps(Scrollbar::pixelsPerLineStep(visible.height()), Scrollbar::pageStep(visible.height()));
        m_horizontalScrollbar->setSteps(Scrollbar::pixelsPerLineStep(visible.width()), Scrollbar::pageStep(visible.width()), m_config.horizontalPixelStep);
        m_verticalScrollbar->setSteps(Scrollbar::pixelsPerLineStep(visible.height()), Scrollbar::pageStep(visible.height()), m_config.verticalPixelStep);
        m_horizontalScrollbar->setProportion(visible.width(), contents.width());
        m_verticalScrollbar->setProportion(visible.height(), contents.height());
        m_horizontalScrollbar->setEnabled(m_config.allowsHorizontalScrolling);
        m_verticalScrollbar->setEnabled(m_config.allowsVerticalScrolling);
        setHorizontalScrollElasticity(m_config.allowsHorizontalStretching ? ScrollElasticity::Automatic : ScrollElasticity::None);
        setVerticalScrollElasticity(m_config.allowsVerticalStretching ? ScrollElasticity::Automatic : ScrollElasticity::None);
        if (m_config.horizontalScrollElasticity)
            setHorizontalScrollElasticity(*m_config.horizontalScrollElasticity);
        if (m_config.verticalScrollElasticity)
            setVerticalScrollElasticity(*m_config.verticalScrollElasticity);
        // An area without a scrollbar keeps it aside, so that the scrollbar's own state carries over.
        if (!m_config.hasHorizontalScrollbar)
            m_hiddenHorizontalScrollbar = std::exchange(m_horizontalScrollbar, nullptr);
        if (!m_config.hasVerticalScrollbar)
            m_hiddenVerticalScrollbar = std::exchange(m_verticalScrollbar, nullptr);
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

    void invalidateScrollbar(Scrollbar& scrollbar, const IntRect& rect) final
    {
        if (m_trace.tracesAreaQueries()) {
            TraceLine(m_trace, 'C', "invalidateScrollbar").u("orientation", static_cast<uint8_t>(scrollbar.orientation()))
                .u("x", static_cast<uint32_t>(rect.x())).u("y", static_cast<uint32_t>(rect.y())).u("w", static_cast<uint32_t>(rect.width())).u("h", static_cast<uint32_t>(rect.height()));
        }
        ScrollableArea::invalidateScrollbar(scrollbar, rect);
        if (!m_ready)
            return;
        ++m_invalidations;
        if (m_config.reentryPoint == ReentryPoint::InvalidateScrollbar && m_invalidations == m_config.reentryAtScroll)
            performReentry();
    }
    void invalidateScrollCornerRect(const IntRect&) final { }

    void createScrollbarsController() final
    {
        setScrollbarsController(makeUnique<RecordingScrollbarsController>(*this, m_trace));
    }

    // Not traced: how often the scrollbars are asked for depends on whether they are overlay scrollbars, which
    // follows the system's scroller style.
    Scrollbar* horizontalScrollbar() const final { return m_horizontalScrollbar.get(); }
    Scrollbar* verticalScrollbar() const final { return m_verticalScrollbar.get(); }

    GraphicsLayer* layerForHorizontalScrollbar() const final
    {
        if (m_trace.tracesAreaQueries())
            TraceLine(m_trace, 'C', "layerForHorizontalScrollbar");
        return nullptr;
    }

    GraphicsLayer* layerForVerticalScrollbar() const final
    {
        if (m_trace.tracesAreaQueries())
            TraceLine(m_trace, 'C', "layerForVerticalScrollbar");
        return nullptr;
    }

    bool isInStableState() const final
    {
        if (m_trace.tracesAreaQueries())
            TraceLine(m_trace, 'C', "isInStableState").b("r", m_config.inStableState);
        return m_config.inStableState;
    }

    void updateAnchorPositionedAfterScroll() final
    {
        if (m_trace.tracesAreaQueries())
            TraceLine(m_trace, 'C', "updateAnchorPositionedAfterScroll");
    }

    // Traced only in an All trace, so that Full digests do not depend on them.
    bool hasSteppedScrolling() const final
    {
        if (m_trace.level() == TraceLevel::All)
            TraceLine(m_trace, 'C', "hasSteppedScrolling").b("r", m_config.hasSteppedScrolling);
        return m_config.hasSteppedScrolling;
    }

    OverscrollBehavior horizontalOverscrollBehavior() const final
    {
        if (m_trace.level() == TraceLevel::All)
            TraceLine(m_trace, 'C', "horizontalOverscrollBehavior").u("r", static_cast<uint8_t>(m_config.horizontalOverscrollBehavior));
        return m_config.horizontalOverscrollBehavior;
    }

    OverscrollBehavior verticalOverscrollBehavior() const final
    {
        if (m_trace.level() == TraceLevel::All)
            TraceLine(m_trace, 'C', "verticalOverscrollBehavior").u("r", static_cast<uint8_t>(m_config.verticalOverscrollBehavior));
        return m_config.verticalOverscrollBehavior;
    }

    float adjustVerticalPageScrollStepForFixedContent(float step) final
    {
        float result = step - m_config.fixedContentPageStepAdjustment;
        if (m_trace.level() == TraceLevel::All)
            TraceLine(m_trace, 'C', "adjustVerticalPageScrollStepForFixedContent").f("step", step).f("r", result);
        return result;
    }

    // Seen as the scroll anchor being cleared.
    ScrollAnchoringController* scrollAnchoringController() const final
    {
        if (m_trace.level() == TraceLevel::All)
            TraceLine(m_trace, 'C', "scrollAnchoringController");
        return nullptr;
    }

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
        if (m_config.userScrollInProgress) {
            TraceLine(m_trace, 'C', "isUserScrollInProgress").b("r", true);
            return true;
        }
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
        if (m_config.scrollSnapInProgress) {
            TraceLine(m_trace, 'C', "isScrollSnapInProgress").b("r", true);
            return true;
        }
        bool result = existingScrollAnimator() && existingScrollAnimator()->isScrollSnapInProgress();
        TraceLine(m_trace, 'C', "isScrollSnapInProgress").b("r", result);
        return result;
    }

    bool requestScrollToPosition(const ScrollPosition& position, const ScrollPositionChangeOptions& options) final
    {
        TraceLine(m_trace, 'C', "requestScrollToPosition").ipt("position", position).u("type", static_cast<uint8_t>(options.type)).u("clamping", static_cast<uint8_t>(options.clamping)).u("animated", static_cast<uint8_t>(options.animated));
        if (m_trace.tracesAreaQueries()) {
            TraceLine(m_trace, 'C', "requestScrollToPositionOptions").u("method", static_cast<uint8_t>(options.snapPointSelectionMethod))
                .b("delta", !!options.originalScrollDelta).sz("", options.originalScrollDelta.value_or(FloatSize { }))
                .u("interrupts", static_cast<uint8_t>(options.interruptsAnimation)).u("curve", static_cast<uint8_t>(options.animationCurve)).b("r", m_config.requestsScrollToPosition);
        }
        if (m_ready)
            ++m_requests;
        if (m_ready && m_config.reentryPoint == ReentryPoint::RequestScrollToPosition && m_requests == m_config.reentryAtScroll)
            const_cast<RecordingScrollableArea&>(*this).performReentry();
        if (m_config.requestsScrollToPosition)
            return true;
        return false;
    }

    bool requestStartKeyboardScrollAnimation(const KeyboardScroll& scroll) final
    {
        TraceLine(m_trace, 'C', "requestStartKeyboardScrollAnimation").sz("offset", scroll.offset).u("granularity", static_cast<uint8_t>(scroll.granularity)).u("direction", static_cast<uint8_t>(scroll.direction));
        if (m_trace.level() == TraceLevel::All)
            TraceLine(m_trace, 'C', "keyboardScrollForce").sz("maximumVelocity", scroll.maximumVelocity).sz("force", scroll.force);
        if (m_config.startsKeyboardScrollAnimation)
            return true;
        return false;
    }

    bool requestStopKeyboardScrollAnimation(bool immediate) final
    {
        TraceLine(m_trace, 'C', "requestStopKeyboardScrollAnimation").b("immediate", immediate);
        if (m_config.stopsKeyboardScrollAnimation)
            return true;
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
        if (m_config.reentryPoint == ReentryPoint::SetScrollOffset)
            performReentry();
    }

    void performReentry()
    {
        if (m_config.reentryAction == ReentryAction::None)
            return;
        ++m_reentryDepth;
        m_maximumReentryDepth = std::max(m_maximumReentryDepth, m_reentryDepth);
        auto& animator = scrollAnimator();
        auto destination = m_config.reentryDestination;
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
        case ReentryAction::SetCurrentPosition:
            TraceLine(m_trace, 'E', "reentry.setCurrentPosition").pt("to", m_config.reentryDestination);
            m_trace.countEntry();
            animator.setCurrentPosition(m_config.reentryDestination, ScrollAnimator::NotifyScrollableArea::Yes);
            break;
        case ReentryAction::ScrollToPositionWithoutAnimation: {
            TraceLine(m_trace, 'E', "reentry.scrollToPositionWithoutAnimation").pt("to", m_config.reentryDestination);
            m_trace.countEntry();
            bool result = animator.scrollToPositionWithoutAnimation(m_config.reentryDestination);
            TraceLine(m_trace, 'R', "reentry.scrollToPositionWithoutAnimation", true).b("r", result);
            break;
        }
        case ReentryAction::AreaScrollToPositionWithAnimation:
            TraceLine(m_trace, 'E', "reentry.areaScrollToPositionWithAnimation").pt("to", destination);
            m_trace.countEntry();
            scrollToPositionWithAnimation(destination);
            break;
        case ReentryAction::AreaScrollToOffsetWithoutAnimation:
            TraceLine(m_trace, 'E', "reentry.areaScrollToOffsetWithoutAnimation").pt("to", destination);
            m_trace.countEntry();
            scrollToOffsetWithoutAnimation(destination);
            break;
        case ReentryAction::AreaScroll: {
            TraceLine(m_trace, 'E', "reentry.areaScroll");
            m_trace.countEntry();
            bool result = scroll(ScrollDirection::ScrollDown, ScrollGranularity::Line);
            TraceLine(m_trace, 'R', "reentry.areaScroll", true).b("r", result);
            break;
        }
        case ReentryAction::AreaResnapAfterLayout:
            TraceLine(m_trace, 'E', "reentry.areaResnapAfterLayout");
            m_trace.countEntry();
            resnapAfterLayout();
            break;
        case ReentryAction::NotifyScrollPositionChanged:
            TraceLine(m_trace, 'E', "reentry.notifyScrollPositionChanged").pt("to", destination);
            m_trace.countEntry();
            notifyScrollPositionChanged(roundedIntPoint(destination));
            break;
        case ReentryAction::SetScrollOffsetFromInternals:
            TraceLine(m_trace, 'E', "reentry.setScrollOffsetFromInternals").pt("to", destination);
            m_trace.countEntry();
            setScrollOffsetFromInternals(roundedIntPoint(destination));
            break;
        case ReentryAction::HideHorizontalScrollbar:
            TraceLine(m_trace, 'E', "reentry.hideHorizontalScrollbar");
            if (m_horizontalScrollbar)
                m_hiddenHorizontalScrollbar = std::exchange(m_horizontalScrollbar, nullptr);
            break;
        case ReentryAction::DropVerticalScrollbar:
            TraceLine(m_trace, 'E', "reentry.dropVerticalScrollbar");
            m_verticalScrollbar = nullptr;
            break;
        }
        --m_reentryDepth;
    }

    Trace& m_trace;
    ScriptedConfig m_config;
    IntPoint m_position;
    RefPtr<Scrollbar> m_horizontalScrollbar;
    RefPtr<Scrollbar> m_verticalScrollbar;
    RefPtr<Scrollbar> m_hiddenHorizontalScrollbar;
    RefPtr<Scrollbar> m_hiddenVerticalScrollbar;
    bool m_ready { false };
    bool m_animationRequested { false };
    uint64_t m_scrollCount { 0 };
    mutable uint64_t m_requests { 0 };
    uint64_t m_invalidations { 0 };
    unsigned m_reentryDepth { 0 };
    unsigned m_maximumReentryDepth { 0 };
};

// MARK: - Steps

enum class Op : uint8_t {
    Wheel, // handleWheelEvent(), as the event handler sends a wheel event to a scrollable area.
    WheelForScrollSnap, // processWheelEventForScrollSnap().
    Frames, // serviceScrollAnimation() at 120 Hz while the area has an animation scheduled, at most count frames.
    RetargetFrames, // As Frames, with retargetRunningAnimation() before each frame.
    AdvanceClock,
    ScrollToPositionWithAnimation, // To a, clamped unless flag.
    // ScrollToPositionWithoutAnimation is clamped unless flag.
    ScrollToPositionWithoutAnimation, // To a.
    RetargetRunningAnimation, // To a, or with flag to the area's position.
    SingleAxisScroll, // By value on axis; count holds the ScrollBehavior bits.
    CancelAnimations,
    // SetCurrentPosition with flag notifies the area.
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
    WheelEventPhase, // handleWheelEventPhase() with the wheel's phase.
    Snapshot,
    // ScrollableArea's own members. None of them makes the area's ScrollAnimator.
    AreaScroll, // ScrollableArea::scroll() in direction by granularity, count steps.
    AreaScrollToPositionWithAnimation, // To a with scrollType and curve, unclamped with flag; size is the original delta when hasDelta.
    AreaScrollToOffsetWithoutAnimation, // To offset a, unclamped with flag.
    AreaScrollToOffsetOnAxis, // To offset value on axis.
    NotifyScrollPositionChanged, // To a.
    SetScrollOffsetFromInternals, // To offset a.
    BeginKeyboardScroll, // Points per step size, direction and granularity.
    EndKeyboardScroll, // Immediately with flag.
    AreaResnapAfterLayout,
    DoPostThumbMoveSnapping, // On axis.
    EdgeQueries, // isPinnedOnSide() on each side and edgePinnedState().
    PropagationQueries, // deltaForPropagation() and shouldBlockScrollPropagation() for size.
    ScrollbarValueAndOverhang, // Position value, total size width and visible size height.
    TargetSideForScrollDelta, // size on axis.
    ConstrainScrollPositionForOverhang, // Visible rect, total size otherRect's size, position point, origin otherRect's location, header and footer.
    ScrollIntoView, // Visible bounds rect, expose otherRect, checkRect, alignX and alignY.
    SetPressedPart, // count on axis's scrollbar.
    SetScrollAnimationStatus, // Animating with flag.
    SetAreaPosition, // To a, without the animator.
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
    LayoutRect rect { };
    LayoutRect otherRect { };
    std::optional<LayoutRect> checkRect { };
    LayoutPoint point { };
    ScrollAlignment alignX { ScrollAlignment::Behavior::NoScroll, ScrollAlignment::Behavior::NoScroll, ScrollAlignment::Behavior::NoScroll };
    ScrollAlignment alignY { ScrollAlignment::Behavior::NoScroll, ScrollAlignment::Behavior::NoScroll, ScrollAlignment::Behavior::NoScroll };
    int header { 0 };
    int footer { 0 };
    ScrollType scrollType { ScrollType::Programmatic };
    ScrollAnimationCurve curve { ScrollAnimationCurve::Default };
    bool hasDelta { false };
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
            m_maximumReentryDepth = area.maximumReentryDepth();
            m_area = nullptr;
        }
        ScrollingMomentumCalculator::setPlatformMomentumScrollingPredictionEnabled(true);
        TraceLine(m_trace, 'X', "end").u("scrolls", scrolls).u("clockReads", scriptedClock().reads);
    }

    RecordingScrollableArea& area() { return *m_area; }
    ScrollAnimator& animator() { return m_area->scrollAnimator(); }
    // How deeply the area's scripted reentry nested in the last run.
    unsigned maximumReentryDepth() const { return m_maximumReentryDepth; }

    void perform(const Step& step)
    {
        if (performAreaStep(step))
            return;
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
            if (step.flag) {
                TraceLine(m_trace, 'E', "scrollToPositionWithoutAnimation").pt("to", step.a).b("unclamped", true);
                m_trace.countEntry();
                bool result = animator.scrollToPositionWithoutAnimation(step.a, ScrollClamping::Unclamped);
                TraceLine(m_trace, 'R', "scrollToPositionWithoutAnimation", true).b("r", result);
                break;
            }
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
            if (step.flag) {
                TraceLine(m_trace, 'E', "setCurrentPositionNotifying").pt("to", step.a);
                m_trace.countEntry();
                animator.setCurrentPosition(step.a, ScrollAnimator::NotifyScrollableArea::Yes);
                break;
            }
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
        case Op::WheelEventPhase:
            TraceLine(m_trace, 'E', "handleWheelEventPhase").u("phase", static_cast<uint8_t>(step.wheel.phase));
            m_trace.countEntry();
            animator.handleWheelEventPhaseForTesting(step.wheel.phase);
            break;
        case Op::Snapshot:
            snapshot();
            break;
        case Op::AreaScroll:
        case Op::AreaScrollToPositionWithAnimation:
        case Op::AreaScrollToOffsetWithoutAnimation:
        case Op::AreaScrollToOffsetOnAxis:
        case Op::NotifyScrollPositionChanged:
        case Op::SetScrollOffsetFromInternals:
        case Op::BeginKeyboardScroll:
        case Op::EndKeyboardScroll:
        case Op::AreaResnapAfterLayout:
        case Op::DoPostThumbMoveSnapping:
        case Op::EdgeQueries:
        case Op::PropagationQueries:
        case Op::ScrollbarValueAndOverhang:
        case Op::TargetSideForScrollDelta:
        case Op::ConstrainScrollPositionForOverhang:
        case Op::ScrollIntoView:
        case Op::SetPressedPart:
        case Op::SetScrollAnimationStatus:
        case Op::SetAreaPosition:
            // performAreaStep() handles these.
            break;
        }
    }

    // ScrollableArea's own members, on the area, without making its animator.
    bool performAreaStep(const Step& step)
    {
        auto& area = *m_area;
        auto orientation = [](ScrollEventAxis axis) {
            return axis == ScrollEventAxis::Horizontal ? ScrollbarOrientation::Horizontal : ScrollbarOrientation::Vertical;
        };
        auto traceAlignment = [](TraceLine& line, const ScrollAlignment& alignment) {
            line.u("visible", static_cast<uint8_t>(alignment.m_rectVisible)).u("hidden", static_cast<uint8_t>(alignment.m_rectHidden))
                .u("partial", static_cast<uint8_t>(alignment.m_rectPartial)).b("threshold", alignment.m_enableLegacyHorizontalVisibilityThreshold);
        };
        switch (step.op) {
        case Op::AreaScroll: {
            TraceLine(m_trace, 'E', "areaScroll").u("direction", static_cast<uint8_t>(step.direction)).u("granularity", static_cast<uint8_t>(step.granularity)).u("steps", step.count);
            m_trace.countEntry();
            bool result = area.scroll(step.direction, step.granularity, step.count);
            TraceLine(m_trace, 'R', "areaScroll", true).b("r", result);
            return true;
        }
        case Op::AreaScrollToPositionWithAnimation: {
            ScrollPositionChangeOptions options { step.scrollType };
            options.clamping = step.flag ? ScrollClamping::Unclamped : ScrollClamping::Clamped;
            options.snapPointSelectionMethod = step.method;
            if (step.hasDelta)
                options.originalScrollDelta = step.size;
            options.animationCurve = step.curve;
            TraceLine(m_trace, 'E', "areaScrollToPositionWithAnimation").pt("to", step.a).u("type", static_cast<uint8_t>(step.scrollType)).b("unclamped", step.flag)
                .u("method", static_cast<uint8_t>(step.method)).b("delta", step.hasDelta).sz("", step.size).u("curve", static_cast<uint8_t>(step.curve));
            m_trace.countEntry();
            area.scrollToPositionWithAnimation(step.a, options);
            TraceLine(m_trace, 'R', "areaScrollToPositionWithAnimation", true).ipt("position", area.position()).u("status", static_cast<uint8_t>(area.scrollAnimationStatus()));
            return true;
        }
        case Op::AreaScrollToOffsetWithoutAnimation:
            TraceLine(m_trace, 'E', "areaScrollToOffsetWithoutAnimation").pt("to", step.a).b("unclamped", step.flag);
            m_trace.countEntry();
            area.scrollToOffsetWithoutAnimation(step.a, step.flag ? ScrollClamping::Unclamped : ScrollClamping::Clamped);
            TraceLine(m_trace, 'R', "areaScrollToOffsetWithoutAnimation", true).ipt("position", area.position());
            return true;
        case Op::AreaScrollToOffsetOnAxis:
            TraceLine(m_trace, 'E', "areaScrollToOffsetOnAxis").u("axis", static_cast<uint8_t>(step.axis)).f("offset", step.value);
            m_trace.countEntry();
            area.scrollToOffsetWithoutAnimation(orientation(step.axis), step.value);
            TraceLine(m_trace, 'R', "areaScrollToOffsetOnAxis", true).ipt("position", area.position());
            return true;
        case Op::NotifyScrollPositionChanged:
            TraceLine(m_trace, 'E', "notifyScrollPositionChanged").ipt("to", roundedIntPoint(step.a));
            m_trace.countEntry();
            area.notifyScrollPositionChanged(roundedIntPoint(step.a));
            TraceLine(m_trace, 'R', "notifyScrollPositionChanged", true).ipt("position", area.position());
            return true;
        case Op::SetScrollOffsetFromInternals:
            TraceLine(m_trace, 'E', "setScrollOffsetFromInternals").ipt("to", roundedIntPoint(step.a));
            m_trace.countEntry();
            area.setScrollOffsetFromInternals(roundedIntPoint(step.a));
            TraceLine(m_trace, 'R', "setScrollOffsetFromInternals", true).ipt("position", area.position());
            return true;
        case Op::BeginKeyboardScroll: {
            KeyboardScroll scroll;
            scroll.offset = step.size;
            scroll.maximumVelocity = step.size;
            scroll.force = step.size;
            scroll.granularity = step.granularity;
            scroll.direction = step.direction;
            TraceLine(m_trace, 'E', "beginKeyboardScroll").sz("offset", step.size).u("granularity", static_cast<uint8_t>(step.granularity)).u("direction", static_cast<uint8_t>(step.direction));
            m_trace.countEntry();
            area.beginKeyboardScroll(scroll);
            TraceLine(m_trace, 'R', "beginKeyboardScroll", true).u("status", static_cast<uint8_t>(area.scrollAnimationStatus()));
            return true;
        }
        case Op::EndKeyboardScroll:
            TraceLine(m_trace, 'E', "endKeyboardScroll").b("immediate", step.flag);
            m_trace.countEntry();
            area.endKeyboardScroll(step.flag);
            TraceLine(m_trace, 'R', "endKeyboardScroll", true).u("status", static_cast<uint8_t>(area.scrollAnimationStatus()));
            return true;
        case Op::AreaResnapAfterLayout:
            TraceLine(m_trace, 'E', "areaResnapAfterLayout");
            m_trace.countEntry();
            area.resnapAfterLayout();
            TraceLine(m_trace, 'R', "areaResnapAfterLayout", true).ipt("position", area.position()).b("animator", !!area.existingScrollAnimator());
            return true;
        case Op::DoPostThumbMoveSnapping:
            TraceLine(m_trace, 'E', "doPostThumbMoveSnapping").u("axis", static_cast<uint8_t>(step.axis));
            m_trace.countEntry();
            area.doPostThumbMoveSnapping(orientation(step.axis));
            TraceLine(m_trace, 'R', "doPostThumbMoveSnapping", true).ipt("position", area.position()).b("animator", !!area.existingScrollAnimator());
            return true;
        case Op::EdgeQueries: {
            TraceLine(m_trace, 'E', "edgeQueries");
            unsigned pinned = 0;
            for (auto side : { BoxSide::Top, BoxSide::Right, BoxSide::Bottom, BoxSide::Left }) {
                m_trace.countEntry();
                pinned = (pinned << 1) | (area.isPinnedOnSide(side) ? 1 : 0);
            }
            m_trace.countEntry();
            auto edges = area.edgePinnedState();
            TraceLine(m_trace, 'R', "edgeQueries", true).u("pinned", pinned).edges("edges", edges);
            return true;
        }
        case Op::PropagationQueries: {
            TraceLine(m_trace, 'E', "propagationQueries").sz("delta", step.size);
            m_trace.countEntry();
            auto delta = area.deltaForPropagation(step.size);
            m_trace.countEntry();
            bool blocks = area.shouldBlockScrollPropagation(step.size);
            TraceLine(m_trace, 'R', "propagationQueries", true).sz("delta", delta).b("blocks", blocks);
            return true;
        }
        case Op::ScrollbarValueAndOverhang: {
            float value = -1;
            float overhang = -1;
            m_trace.countEntry();
            ScrollableArea::computeScrollbarValueAndOverhang(step.value, step.size.width(), step.size.height(), value, overhang);
            TraceLine(m_trace, 'R', "computeScrollbarValueAndOverhang", true).f("position", step.value).sz("sizes", step.size).f("value", value).f("overhang", overhang);
            return true;
        }
        case Op::TargetSideForScrollDelta: {
            m_trace.countEntry();
            auto side = ScrollableArea::targetSideForScrollDelta(step.size, step.axis);
            TraceLine(m_trace, 'R', "targetSideForScrollDelta", true).sz("delta", step.size).u("axis", static_cast<uint8_t>(step.axis)).b("side", !!side).u("", side ? static_cast<uint8_t>(*side) : 0);
            return true;
        }
        case Op::ConstrainScrollPositionForOverhang: {
            m_trace.countEntry();
            auto result = ScrollableArea::constrainScrollPositionForOverhang(step.rect, step.otherRect.size(), step.point, step.otherRect.location(), step.header, step.footer);
            TraceLine(m_trace, 'R', "constrainScrollPositionForOverhang", true).lrect("visible", step.rect).lrect("contents", step.otherRect).lpt("position", step.point)
                .u("header", static_cast<uint32_t>(step.header)).u("footer", static_cast<uint32_t>(step.footer)).lpt("r", result);
            return true;
        }
        case Op::ScrollIntoView: {
            m_trace.countEntry();
            auto result = area.rectToExposeForScrollIntoView(step.rect, step.otherRect, step.alignX, step.alignY, step.checkRect);
            TraceLine line(m_trace, 'R', "rectToExposeForScrollIntoView", true);
            line.lrect("visible", step.rect).lrect("expose", step.otherRect).b("check", !!step.checkRect).lrect("", step.checkRect.value_or(LayoutRect { }));
            traceAlignment(line, step.alignX);
            traceAlignment(line, step.alignY);
            line.lrect("r", result);
            return true;
        }
        case Op::SetPressedPart: {
            auto* scrollbar = step.axis == ScrollEventAxis::Horizontal ? area.horizontalScrollbar() : area.verticalScrollbar();
            TraceLine(m_trace, 'T', "setPressedPart").u("axis", static_cast<uint8_t>(step.axis)).u("part", step.count).b("scrollbar", !!scrollbar);
            if (scrollbar)
                scrollbar->setPressedPart(static_cast<ScrollbarPart>(step.count));
            return true;
        }
        case Op::SetScrollAnimationStatus:
            TraceLine(m_trace, 'T', "setScrollAnimationStatus").b("animating", step.flag);
            area.setScrollAnimationStatus(step.flag ? ScrollAnimationStatus::Animating : ScrollAnimationStatus::NotAnimating);
            return true;
        case Op::SetAreaPosition:
            TraceLine(m_trace, 'T', "setAreaPosition").pt("to", step.a);
            area.setAreaPosition(step.a);
            return true;
        default:
            return false;
        }
    }

    // State read through the animator's out-of-line members, and the area's own state.
    void snapshot()
    {
        if (!m_area->existingScrollAnimator()) {
            TraceLine(m_trace, 'S', "areaState").ipt("position", m_area->position()).u("status", static_cast<uint8_t>(m_area->scrollAnimationStatus()))
                .u("type", static_cast<uint8_t>(m_area->currentScrollType())).u("clamping", static_cast<uint8_t>(m_area->scrollClamping()));
            return;
        }
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
        if (m_trace.level() == TraceLevel::All) {
            // The animator's own position, which can be fractional, and the scrollbar animations flag, cleared so
            // that the next snapshot shows whether a later entry set it.
            auto& scrollbars = m_area->scrollbarsController();
            line.pt("currentPosition", animator.currentPosition()).b("unsuspended", scrollbars.scrollbarAnimationsUnsuspendedByUserInteraction())
                .b("originChanged", m_area->scrollOriginChanged()).u("clamping", static_cast<uint8_t>(m_area->scrollClamping()));
            if (m_trace.tracesAreaQueries())
                line.u("type", static_cast<uint8_t>(m_area->currentScrollType()));
            scrollbars.setScrollbarAnimationsUnsuspendedByUserInteraction(false);
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
        bool result = animator().retargetRunningAnimation(destination, ScrollAnimationCurve::Default);
        TraceLine(m_trace, 'R', "retargetRunningAnimation", true).b("r", result);
    }

    Trace& m_trace;
    const Case& m_case;
    bool m_snapshotEveryStep;
    TimerRecorder m_timers;
    RecordingScrollableArea* m_area { nullptr };
    const LayoutScrollSnapOffsetsInfo* m_lastSnapInfo { nullptr };
    double m_lastEventTime { caseStartTime };
    unsigned m_maximumReentryDepth { 0 };
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
