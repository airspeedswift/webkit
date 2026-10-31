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

// Deterministic inputs for ScrollAnimator: wheel gestures, smooth, programmatic and keyboard scrolls, snap
// offsets, and the benchmark's session shapes. ScrollPhysics.cpp and ScrollPhysicsBench.cpp share them.

#include "ScrollPhysicsTestClient.h"

namespace TestWebKitAPI {
namespace ScrollPhysics {

class Lcg {
public:
    explicit Lcg(uint64_t seed)
        : m_state(seed * 6364136223846793005ull + 1442695040888963407ull)
    {
    }

    uint32_t next()
    {
        m_state = m_state * 6364136223846793005ull + 1442695040888963407ull;
        return static_cast<uint32_t>(m_state >> 33);
    }

    // [0, 1)
    float unit() { return static_cast<float>(next() >> 8) / static_cast<float>(1 << 23); }
    // [low, high]
    int range(int low, int high) { return low + static_cast<int>(next() % static_cast<uint32_t>(high - low + 1)); }
    float between(float low, float high) { return low + (high - low) * unit(); }
    bool chance(unsigned percent) { return next() % 100 < percent; }

private:
    uint64_t m_state;
};

// MARK: - Step builders

inline Step step(Op op)
{
    Step result { };
    result.op = op;
    return result;
}

inline Step frames(unsigned count = 0)
{
    auto result = step(Op::Frames);
    result.count = count;
    return result;
}

// `gap` is the time since the previous event. An event never comes before the clock, so after animation frames
// it arrives at the current time instead.
inline Step wheelStep(const WheelDescription& wheel, double gap, Op op = Op::Wheel)
{
    auto result = step(op);
    result.wheel = wheel;
    result.seconds = gap;
    return result;
}

// Past the extents only with `unclamped`.
inline Step smoothScroll(FloatPoint to, bool unclamped = false)
{
    auto result = step(Op::ScrollToPositionWithAnimation);
    result.a = to;
    result.flag = unclamped;
    return result;
}

inline Step scrollWithoutAnimation(FloatPoint to)
{
    auto result = step(Op::ScrollToPositionWithoutAnimation);
    result.a = to;
    return result;
}

inline Step scrollWithoutAnimation(FloatPoint to, bool unclamped)
{
    auto result = scrollWithoutAnimation(to);
    result.flag = unclamped;
    return result;
}

// As when the position changes from outside the animator; with `notify`, the animator tells the area.
inline Step setCurrentPosition(FloatPoint to, bool notify = false)
{
    auto result = step(Op::SetCurrentPosition);
    result.a = to;
    result.flag = notify;
    return result;
}

inline Step retarget(FloatPoint to)
{
    auto result = step(Op::RetargetRunningAnimation);
    result.a = to;
    return result;
}

inline Step retargetFrames(FloatPoint center, FloatSize stride, unsigned count = 0)
{
    auto result = step(Op::RetargetFrames);
    result.a = center;
    result.size = stride;
    result.count = count;
    return result;
}

inline unsigned behaviorBits(std::initializer_list<ScrollAnimator::ScrollBehavior> behaviors)
{
    unsigned bits = 0;
    for (auto behavior : behaviors)
        bits |= 1u << static_cast<uint8_t>(behavior);
    return bits;
}

inline Step singleAxisScroll(ScrollEventAxis axis, float delta, unsigned behavior)
{
    auto result = step(Op::SingleAxisScroll);
    result.axis = axis;
    result.value = delta;
    result.count = behavior;
    return result;
}

// A key press, as the event handler sends it to the keyboard scrolling animator.
inline Step keyDown(ScrollDirection direction, ScrollGranularity granularity, bool isKeyRepeat = false)
{
    auto result = step(Op::KeyboardScrollGesture);
    result.direction = direction;
    result.granularity = granularity;
    result.flag = isKeyRepeat;
    return result;
}

inline Step keyUp(bool immediately = false)
{
    auto result = step(Op::KeyUp);
    result.flag = immediately;
    return result;
}

inline Step setSnapInfo(unsigned index)
{
    auto result = step(Op::SetSnapOffsetsInfo);
    result.snapInfo = index;
    return result;
}

inline Step fireTimers(double afterSeconds = 0.1)
{
    auto result = step(Op::FireTimers);
    result.seconds = afterSeconds;
    return result;
}

inline Step advance(double seconds)
{
    auto result = step(Op::AdvanceClock);
    result.seconds = seconds;
    return result;
}

inline Step setConfig(const ScriptedConfig& config, std::optional<FloatPoint> offset = std::nullopt)
{
    auto result = step(Op::SetConfig);
    result.config = config;
    result.flag = !!offset;
    if (offset)
        result.a = *offset;
    return result;
}

inline Step setPrediction(bool enabled)
{
    auto result = step(Op::SetPrediction);
    result.flag = enabled;
    return result;
}

inline Step adjustedForSnapping(ScrollEventAxis axis, FloatPoint offset, ScrollSnapPointSelectionMethod method, bool bothAxes = false)
{
    auto result = step(Op::ScrollOffsetAdjustedForSnapping);
    result.axis = axis;
    result.a = offset;
    result.method = method;
    result.flag = bothAxes;
    return result;
}

inline Step setActiveIndex(ScrollEventAxis axis, std::optional<unsigned> index)
{
    auto result = step(Op::SetActiveScrollSnapIndex);
    result.axis = axis;
    result.optionalIndex = index;
    return result;
}

// MARK: - Wheel event sequences

inline WheelDescription gestureEvent(PlatformWheelEventPhase phase, PlatformWheelEventPhase momentumPhase, FloatSize delta, double interval)
{
    WheelDescription wheel;
    wheel.phase = phase;
    wheel.momentumPhase = momentumPhase;
    wheel.delta = delta;
    wheel.unacceleratedDelta = delta.scaled(0.75f);
    wheel.velocity = interval > 0 ? delta.scaled(static_cast<float>(1 / interval)) : FloatSize();
    wheel.wheelTicks = delta.scaled(0.1f);
    wheel.hasPreciseScrollingDeltas = true;
    return wheel;
}

inline WheelDescription mouseWheelEvent(FloatSize delta, PlatformWheelEventGranularity granularity = PlatformWheelEventGranularity::ScrollByPixelWheelEvent)
{
    WheelDescription wheel;
    wheel.delta = delta;
    wheel.unacceleratedDelta = delta;
    wheel.wheelTicks = delta.scaled(0.1f);
    wheel.granularity = granularity;
    wheel.hasPreciseScrollingDeltas = false;
    return wheel;
}

struct GestureDescription {
    bool mayBegin { true };
    std::vector<FloatSize> deltas; // Began, then Changed.
    std::vector<FloatSize> momentumDeltas; // Momentum Began, then Changed; empty for no momentum.
    double interval { 1.0 / 120 };
    double gapBefore { 1.0 / 120 };
    double gapBeforeMomentum { 1.0 / 120 };
    // Stops after this many events; zero for the whole gesture.
    unsigned cutAfter { 0 };
    // Ends the fingers-down part with Cancelled instead of Ended.
    bool cancelled { false };
    MouseEventInputSource inputSource { MouseEventInputSource::UserDriven };
    Op op { Op::Wheel };
    // Runs animation frames after each event, as the display would while a snap or rubber band animates.
    bool framesBetweenEvents { false };
};

inline unsigned appendGesture(std::vector<Step>& steps, const GestureDescription& gesture)
{
    using Phase = PlatformWheelEventPhase;
    unsigned emitted = 0;
    auto emit = [&](Phase phase, Phase momentumPhase, FloatSize delta, double interval) {
        if (gesture.cutAfter && emitted >= gesture.cutAfter)
            return;
        auto wheel = gestureEvent(phase, momentumPhase, delta, interval);
        wheel.inputSource = gesture.inputSource;
        steps.push_back(wheelStep(wheel, emitted ? interval : gesture.gapBefore, gesture.op));
        if (gesture.framesBetweenEvents) {
            auto frame = frames(1);
            steps.push_back(frame);
        }
        ++emitted;
    };
    if (gesture.mayBegin)
        emit(Phase::MayBegin, Phase::None, { }, gesture.interval);
    for (size_t i = 0; i < gesture.deltas.size(); ++i)
        emit(i ? Phase::Changed : Phase::Began, Phase::None, gesture.deltas[i], gesture.interval);
    emit(gesture.cancelled ? Phase::Cancelled : Phase::Ended, Phase::None, { }, gesture.interval);
    if (!gesture.cancelled && !gesture.momentumDeltas.empty()) {
        for (size_t i = 0; i < gesture.momentumDeltas.size(); ++i)
            emit(Phase::None, i ? Phase::Changed : Phase::Began, gesture.momentumDeltas[i], i ? gesture.interval : gesture.gapBeforeMomentum);
        emit(Phase::None, Phase::Ended, { }, gesture.interval);
    }
    return emitted;
}

// Deltas that start at `first` and decay by `decay` per event.
inline std::vector<FloatSize> decayingDeltas(FloatSize first, float decay, unsigned count)
{
    std::vector<FloatSize> result;
    auto delta = first;
    for (unsigned i = 0; i < count; ++i) {
        result.push_back(delta);
        delta = delta.scaled(decay);
    }
    return result;
}

// MARK: - Snap offsets

struct SnapDescription {
    ScrollEventAxis axis { ScrollEventAxis::Vertical };
    std::vector<float> offsets;
    bool withAreas { true };
    bool withIDs { true };
    std::optional<unsigned> focused;
    std::optional<unsigned> target;
    std::optional<unsigned> stopAlways;
    // The area for each offset is this tall (or wide); larger than the snapport gives
    // hasSnapAreaLargerThanViewport.
    float areaLength { 300 };
    float snapportLength { 600 };
    ScrollSnapStrictness strictness { ScrollSnapStrictness::Mandatory };
    bool bothAxes { false };
    // Two offsets share each area index when set: nested areas.
    bool nested { false };
};

inline void appendSnapAxis(LayoutScrollSnapOffsetsInfo& info, const SnapDescription& description, ScrollEventAxis axis)
{
    auto& list = axis == ScrollEventAxis::Vertical ? info.verticalSnapOffsets : info.horizontalSnapOffsets;
    for (unsigned i = 0; i < description.offsets.size(); ++i) {
        SnapOffset<LayoutUnit> offset {
            LayoutUnit(static_cast<double>(description.offsets[i])),
            description.stopAlways && *description.stopAlways == i ? ScrollSnapStop::Always : ScrollSnapStop::Normal,
            description.areaLength > description.snapportLength,
            description.focused && *description.focused == i,
            description.target && *description.target == i,
            { },
            { }
        };
        if (description.withAreas) {
            size_t areaIndex = info.snapAreas.size();
            float position = description.offsets[i];
            LayoutRect area = axis == ScrollEventAxis::Vertical
                ? LayoutRect(LayoutPoint(LayoutUnit(0), LayoutUnit(static_cast<double>(position))), LayoutSize(LayoutUnit(400), LayoutUnit(static_cast<double>(description.areaLength))))
                : LayoutRect(LayoutPoint(LayoutUnit(static_cast<double>(position)), LayoutUnit(0)), LayoutSize(LayoutUnit(static_cast<double>(description.areaLength)), LayoutUnit(400)));
            info.snapAreas.append(area);
            uint64_t id = areaIndex + 1;
            info.snapAreasIDs.append(NodeIdentifier(id));
            offset.snapAreaIndices.append(areaIndex);
            if (description.nested && areaIndex > 0)
                offset.snapAreaIndices.append(areaIndex - 1);
            if (description.withIDs)
                offset.snapTargetID = NodeIdentifier(id);
        }
        list.append(WTF::move(offset));
    }
}

inline LayoutScrollSnapOffsetsInfo snapInfo(const SnapDescription& description)
{
    LayoutScrollSnapOffsetsInfo info;
    info.strictness = description.strictness;
    appendSnapAxis(info, description, description.axis);
    if (description.bothAxes)
        appendSnapAxis(info, description, description.axis == ScrollEventAxis::Vertical ? ScrollEventAxis::Horizontal : ScrollEventAxis::Vertical);
    return info;
}

inline std::vector<float> evenlySpaced(float start, float spacing, unsigned count)
{
    std::vector<float> result;
    for (unsigned i = 0; i < count; ++i)
        result.push_back(start + spacing * i);
    return result;
}

// MARK: - Benchmark shapes
//
// Each shape is one case: one scrollable area and its animator through one pass of a scroll session. The
// benchmark runs the pass once by default and many times in its full run.

inline FloatPoint maximumScrollOffset(const ScriptedConfig& config)
{
    return FloatPoint(config.contentsSize - config.viewportSize);
}

inline ScriptedConfig benchConfig()
{
    ScriptedConfig config;
    config.contentsSize = { 1200, 20000 };
    config.viewportSize = { 800, 600 };
    config.snapportSize = { 800, 600 };
    return config;
}

inline Case smoothScrollShape()
{
    Case result;
    result.name = "SmoothScroll";
    result.config = benchConfig();
    result.offset = { 0, 5000 };
    Lcg random(1);
    auto maximum = maximumScrollOffset(result.config);
    FloatPoint from = result.offset;
    for (unsigned i = 0; i < 64; ++i) {
        // About one in eight destinations is past the extents, and is not clamped.
        FloatPoint to { random.between(0, maximum.x()), from.y() + random.between(-800, 800) };
        bool pastExtents = random.chance(12);
        if (pastExtents)
            to = { random.between(-100, maximum.x() + 100), random.chance(50) ? -200 : maximum.y() + 200 };
        result.steps.push_back(smoothScroll(to, pastExtents));
        result.steps.push_back(frames());
        from = to.constrainedBetween({ }, maximum);
    }
    return result;
}

inline Case smoothRetargetShape()
{
    Case result;
    result.name = "SmoothRetarget";
    result.config = benchConfig();
    result.offset = { 0, 5000 };
    Lcg random(2);
    for (unsigned i = 0; i < 16; ++i) {
        FloatPoint center { random.between(0, 400), random.between(1000, 15000) };
        result.steps.push_back(smoothScroll(center));
        result.steps.push_back(retargetFrames(center, { random.between(-20, 20), random.between(-60, 60) }, 48));
        result.steps.push_back(frames());
    }
    return result;
}

// Key presses through the keyboard scrolling animator: a page or the whole document animates from the animator,
// an arrow key scrolls one line through singleAxisScroll(), and a held arrow key goes to the area's own keyboard
// scrolling.
inline Case keyboardScrollShape()
{
    Case result;
    result.name = "KeyboardScroll";
    result.config = benchConfig();
    result.offset = { 200, 5000 };
    static constexpr ScrollDirection directions[] = { ScrollDirection::ScrollDown, ScrollDirection::ScrollRight, ScrollDirection::ScrollUp, ScrollDirection::ScrollLeft };
    Lcg random(3);
    auto maximum = maximumScrollOffset(result.config);
    for (unsigned i = 0; i < 32; ++i) {
        // Every eighth run starts against an edge.
        if (i % 8 == 7)
            result.steps.push_back(setConfig(result.config, FloatPoint(0, maximum.y())));
        auto direction = directions[i % 4];
        if (i % 4 == 3) {
            auto axis = axisFromDirection(direction);
            float sign = direction == ScrollDirection::ScrollUp || direction == ScrollDirection::ScrollLeft ? -1 : 1;
            result.steps.push_back(keyDown(direction, ScrollGranularity::Line));
            for (unsigned repeat = 0, count = random.range(2, 6); repeat < count; ++repeat) {
                result.steps.push_back(singleAxisScroll(axis, sign * 40, behaviorBits({ ScrollAnimator::ScrollBehavior::RespectScrollSnap })));
                result.steps.push_back(frames(random.range(2, 8)));
            }
            result.steps.push_back(keyUp());
            result.steps.push_back(frames());
            continue;
        }
        auto granularity = i % 5 == 4 ? ScrollGranularity::Document : ScrollGranularity::Page;
        result.steps.push_back(keyDown(direction, granularity));
        result.steps.push_back(frames(random.range(6, 40)));
        if (i % 2)
            result.steps.push_back(step(Op::StopKeyboardScrollAnimation));
        result.steps.push_back(keyUp(i % 6 == 5));
        result.steps.push_back(frames());
    }
    return result;
}

inline Case trackpadGestureShape()
{
    Case result;
    result.name = "TrackpadGesture";
    result.config = benchConfig();
    result.offset = { 200, 8000 };
    Lcg random(4);
    for (unsigned i = 0; i < 24; ++i) {
        GestureDescription gesture;
        float sign = i % 2 ? -1 : 1;
        gesture.deltas = decayingDeltas({ random.between(-2, 2), sign * random.between(4, 30) }, 0.97f, random.range(10, 30));
        gesture.momentumDeltas = decayingDeltas({ 0, sign * random.between(10, 40) }, 0.92f, random.range(20, 60));
        gesture.interval = 1.0 / 120;
        gesture.gapBefore = 0.3;
        appendGesture(result.steps, gesture);
    }
    return result;
}

inline Case rubberBandShape()
{
    Case result;
    result.name = "RubberBand";
    result.config = benchConfig();
    result.offset = { 0, 0 };
    Lcg random(5);
    for (unsigned i = 0; i < 16; ++i) {
        result.steps.push_back(setConfig(result.config, FloatPoint(0, 0)));
        GestureDescription gesture;
        gesture.gapBefore = 0.2;
        // Pulling down past the top edge.
        gesture.deltas = decayingDeltas({ 0, random.between(8, 30) }, 0.95f, random.range(8, 20));
        gesture.interval = 1.0 / 120;
        appendGesture(result.steps, gesture);
        result.steps.push_back(frames());
    }
    return result;
}

inline Case scrollSnapGestureShape()
{
    Case result;
    result.name = "ScrollSnapGesture";
    result.config = benchConfig();
    result.offset = { 0, 6000 };
    SnapDescription snap;
    snap.offsets = evenlySpaced(0, 190, 100);
    result.snapInfos.push_back(snapInfo(snap));
    result.steps.push_back(setSnapInfo(0));
    Lcg random(6);
    for (unsigned i = 0; i < 16; ++i) {
        GestureDescription gesture;
        gesture.gapBefore = 0.2;
        float sign = i % 2 ? -1 : 1;
        gesture.deltas = decayingDeltas({ 0, sign * random.between(4, 20) }, 0.95f, random.range(6, 16));
        if (i % 4 != 3)
            gesture.momentumDeltas = decayingDeltas({ 0, sign * random.between(10, 30) }, 0.9f, random.range(10, 30));
        gesture.framesBetweenEvents = true;
        appendGesture(result.steps, gesture);
        result.steps.push_back(frames());
    }
    return result;
}

inline Case discreteWheelSnapShape()
{
    Case result;
    result.name = "DiscreteWheelSnap";
    result.config = benchConfig();
    result.offset = { 0, 3800 };
    SnapDescription snap;
    snap.offsets = evenlySpaced(0, 380, 50);
    result.snapInfos.push_back(snapInfo(snap));
    result.steps.push_back(setSnapInfo(0));
    Lcg random(7);
    for (unsigned i = 0; i < 24; ++i) {
        unsigned burst = random.range(1, 5);
        float sign = random.chance(50) ? -1 : 1;
        for (unsigned tick = 0; tick < burst; ++tick)
            result.steps.push_back(wheelStep(mouseWheelEvent({ 0, sign * 40 }), tick ? 0.03 : 0.2));
        result.steps.push_back(fireTimers(0.1));
        result.steps.push_back(frames());
    }
    return result;
}

inline Case mixedSessionShape()
{
    Case result;
    result.name = "MixedSession";
    result.config = benchConfig();
    result.offset = { 0, 4000 };
    SnapDescription snap;
    snap.offsets = evenlySpaced(0, 600, 34);
    result.snapInfos.push_back({ });
    result.snapInfos.push_back(snapInfo(snap));
    // Snapping from the start, so programmatic scrolls and snap queries meet snap offsets until a layout clears them.
    result.steps.push_back(setSnapInfo(1));
    Lcg random(8);
    auto maximum = maximumScrollOffset(result.config);
    static constexpr ScrollSnapPointSelectionMethod methods[] = { ScrollSnapPointSelectionMethod::Closest, ScrollSnapPointSelectionMethod::Directional, ScrollSnapPointSelectionMethod::Paging };
    for (unsigned i = 0; i < 40; ++i) {
        switch (random.range(0, 8)) {
        case 0:
            result.steps.push_back(smoothScroll({ 0, random.between(0, maximum.y()) }));
            result.steps.push_back(frames());
            break;
        case 1:
            result.steps.push_back(keyDown(random.chance(50) ? ScrollDirection::ScrollDown : ScrollDirection::ScrollUp, ScrollGranularity::Page));
            result.steps.push_back(frames(random.range(4, 30)));
            result.steps.push_back(keyUp());
            result.steps.push_back(frames());
            break;
        case 2: {
            GestureDescription gesture;
            gesture.deltas = decayingDeltas({ 0, random.between(-25, 25) }, 0.96f, random.range(8, 20));
            gesture.momentumDeltas = decayingDeltas({ 0, random.between(-30, 30) }, 0.9f, random.range(10, 30));
            gesture.framesBetweenEvents = true;
            appendGesture(result.steps, gesture);
            result.steps.push_back(frames());
            break;
        }
        case 3: {
            // A pull past the top, then a programmatic scroll while it snaps back.
            result.steps.push_back(setConfig(result.config, FloatPoint(0, 0)));
            GestureDescription gesture;
            gesture.deltas = decayingDeltas({ 0, random.between(8, 25) }, 0.95f, random.range(6, 14));
            appendGesture(result.steps, gesture);
            result.steps.push_back(frames(random.range(1, 6)));
            result.steps.push_back(scrollWithoutAnimation({ 0, random.between(0, 2000) }));
            result.steps.push_back(frames());
            break;
        }
        case 4:
            result.steps.push_back(setSnapInfo(random.chance(70) ? 1 : 0));
            result.steps.push_back(step(Op::ResnapAfterLayout));
            result.steps.push_back(frames());
            break;
        case 5:
            for (unsigned tick = 0, burst = random.range(1, 4); tick < burst; ++tick)
                result.steps.push_back(wheelStep(mouseWheelEvent({ 0, 40 }), tick ? 0.03 : 0.1));
            result.steps.push_back(fireTimers(0.1));
            result.steps.push_back(frames());
            break;
        case 6:
            result.steps.push_back(smoothScroll({ 0, random.between(0, maximum.y()) }));
            result.steps.push_back(frames(random.range(1, 10)));
            result.steps.push_back(step(Op::ContentsSizeChanged));
            result.steps.push_back(frames());
            break;
        case 7:
            result.steps.push_back(adjustedForSnapping(ScrollEventAxis::Vertical, { 0, random.between(0, maximum.y()) }, methods[random.range(0, 2)], random.chance(30)));
            break;
        case 8: {
            bool paged = random.chance(50);
            float delta = (random.chance(50) ? -1 : 1) * (paged ? 540 : 40);
            unsigned behavior = paged ? behaviorBits({ ScrollAnimator::ScrollBehavior::RespectScrollSnap, ScrollAnimator::ScrollBehavior::Paged }) : behaviorBits({ ScrollAnimator::ScrollBehavior::RespectScrollSnap });
            result.steps.push_back(singleAxisScroll(ScrollEventAxis::Vertical, delta, behavior));
            result.steps.push_back(frames());
            break;
        }
        }
    }
    return result;
}

// Scrolls a script asks for: to a position with and without animation, by a line or a page on one axis, and snap
// queries, on an area whose snap offsets come and go.
inline Case programmaticScrollShape()
{
    Case result;
    result.name = "ProgrammaticScroll";
    result.config = benchConfig();
    result.offset = { 0, 5000 };
    SnapDescription snap;
    snap.offsets = evenlySpaced(0, 500, 40);
    snap.bothAxes = true;
    result.snapInfos.push_back({ });
    result.snapInfos.push_back(snapInfo(snap));
    Lcg random(9);
    auto maximum = maximumScrollOffset(result.config);
    static constexpr ScrollSnapPointSelectionMethod methods[] = { ScrollSnapPointSelectionMethod::Closest, ScrollSnapPointSelectionMethod::Directional, ScrollSnapPointSelectionMethod::Paging };
    auto anywhere = [&] {
        // About one in ten is past the extents.
        if (random.chance(10))
            return FloatPoint { random.between(-200, maximum.x() + 200), random.chance(50) ? -300.0f : maximum.y() + 300 };
        return FloatPoint { random.between(0, maximum.x()), random.between(0, maximum.y()) };
    };
    for (unsigned i = 0; i < 600; ++i) {
        // Each draw is its own statement, so the order of draws does not depend on the order arguments are
        // evaluated in.
        switch (random.range(0, 6)) {
        case 0: {
            auto to = anywhere();
            result.steps.push_back(scrollWithoutAnimation(to, random.chance(20)));
            break;
        }
        case 1: {
            auto to = anywhere();
            result.steps.push_back(setCurrentPosition(to, random.chance(50)));
            break;
        }
        case 2: {
            auto axis = random.chance(70) ? ScrollEventAxis::Vertical : ScrollEventAxis::Horizontal;
            bool paged = random.chance(40);
            float delta = (random.chance(50) ? -1 : 1) * (paged ? 540 : 40);
            unsigned behavior = behaviorBits({ ScrollAnimator::ScrollBehavior::NeverAnimate });
            if (random.chance(50))
                behavior |= behaviorBits({ ScrollAnimator::ScrollBehavior::RespectScrollSnap });
            if (paged)
                behavior |= behaviorBits({ ScrollAnimator::ScrollBehavior::Paged });
            result.steps.push_back(singleAxisScroll(axis, delta, behavior));
            break;
        }
        case 3: {
            auto axis = random.chance(70) ? ScrollEventAxis::Vertical : ScrollEventAxis::Horizontal;
            auto offset = anywhere();
            auto method = methods[random.range(0, 2)];
            result.steps.push_back(adjustedForSnapping(axis, offset, method, random.chance(30)));
            break;
        }
        case 4: {
            auto to = anywhere();
            result.steps.push_back(smoothScroll(to, random.chance(10)));
            result.steps.push_back(frames(random.range(2, 12)));
            result.steps.push_back(scrollWithoutAnimation(anywhere()));
            break;
        }
        case 5:
            result.steps.push_back(setSnapInfo(random.chance(60) ? 1 : 0));
            break;
        case 6:
            result.steps.push_back(step(Op::CancelAnimations));
            break;
        }
    }
    return result;
}

// Wheel events on an area that scrolls by whole steps, as a list box does: mouse wheel ticks, which animate,
// trackpad gestures, which do not, page-sized ticks, and gestures that end against an edge.
inline Case steppedWheelShape()
{
    Case result;
    result.name = "SteppedWheel";
    result.config = benchConfig();
    result.config.contentsSize = { 1000, 12000 };
    result.config.hasSteppedScrolling = true;
    result.config.verticalPixelStep = 20;
    result.config.horizontalPixelStep = 4;
    result.offset = { 0, 4000 };
    Lcg random(10);
    auto maximum = maximumScrollOffset(result.config);
    for (unsigned i = 0; i < 160; ++i) {
        if (i % 16 == 15)
            result.steps.push_back(setConfig(result.config, FloatPoint(0, random.chance(50) ? 0 : maximum.y())));
        switch (random.range(0, 3)) {
        case 0: {
            float sign = random.chance(50) ? -1 : 1;
            for (unsigned tick = 0, burst = random.range(1, 4); tick < burst; ++tick) {
                float lines = random.range(1, 3);
                result.steps.push_back(wheelStep(mouseWheelEvent({ 0, sign * lines }), tick ? 0.03 : 0.2));
            }
            result.steps.push_back(frames(random.range(4, 30)));
            break;
        }
        case 1: {
            GestureDescription gesture;
            float sign = random.chance(50) ? -1 : 1;
            FloatSize first { random.between(-1, 1), sign * random.between(0.5f, 6) };
            gesture.deltas = decayingDeltas(first, 0.9f, random.range(6, 16));
            if (random.chance(50)) {
                FloatSize momentum { 0, sign * random.between(1, 8) };
                gesture.momentumDeltas = decayingDeltas(momentum, 0.85f, random.range(6, 20));
            }
            appendGesture(result.steps, gesture);
            break;
        }
        case 2:
            result.steps.push_back(wheelStep(mouseWheelEvent({ 0, random.chance(50) ? -1.0f : 1.0f }, PlatformWheelEventGranularity::ScrollByPageWheelEvent), 0.2));
            result.steps.push_back(frames());
            break;
        case 3:
            result.steps.push_back(wheelStep(mouseWheelEvent({ random.chance(50) ? -2.0f : 2.0f, 0 }), 0.2));
            result.steps.push_back(frames());
            break;
        }
    }
    return result;
}

// MARK: - Unit cases
//
// ScrollPhysics.cpp checks each one's full trace digest: the input classes a size, count or ordering in the
// scroll physics depends on.

inline ScriptedConfig unitConfig()
{
    ScriptedConfig config;
    config.contentsSize = { 2400, 6000 };
    return config;
}

// Mouse wheel ticks on a snap container: the controller keeps the last three discrete deltas, so bursts of
// three, four and five, then the discrete snap timer, whose callback destroys the timer.
inline Case discreteWheelBurstCase(unsigned burst)
{
    Case result;
    result.name = "DiscreteWheelBurst" + std::to_string(burst);
    result.config = unitConfig();
    result.offset = { 0, 1900 };
    SnapDescription snap;
    snap.offsets = evenlySpaced(0, 380, 15);
    result.snapInfos.push_back(snapInfo(snap));
    result.steps.push_back(setSnapInfo(0));
    for (unsigned i = 0; i < burst; ++i)
        result.steps.push_back(wheelStep(mouseWheelEvent({ 0, (i % 3 == 2) ? -40.0f : 40.0f }), 0.02));
    result.steps.push_back(fireTimers(0.1));
    result.steps.push_back(frames());
    return result;
}

// A glide over many snap offsets; every scroll the glide makes updates the animator's snap index.
inline Case snapGlideCase(unsigned snapOffsets)
{
    Case result;
    result.name = "SnapGlide" + std::to_string(snapOffsets);
    result.config = unitConfig();
    result.config.contentsSize = { 800, 200000 };
    result.offset = { 0, 5000 };
    SnapDescription snap;
    snap.offsets = evenlySpaced(0, 190, snapOffsets);
    snap.focused = snapOffsets / 2;
    result.snapInfos.push_back(snapInfo(snap));
    result.steps.push_back(setSnapInfo(0));
    GestureDescription gesture;
    gesture.deltas = decayingDeltas({ 0, 12 }, 0.9f, 6);
    gesture.momentumDeltas = decayingDeltas({ 0, 25 }, 0.9f, 12);
    gesture.framesBetweenEvents = true;
    appendGesture(result.steps, gesture);
    result.steps.push_back(frames());
    return result;
}

// The scrollable area stops the smooth scroll from inside the scroll the animation asked for.
inline Case stopFromScrollCase()
{
    Case result;
    result.name = "StopFromScroll";
    result.config = unitConfig();
    result.config.reentryAction = ReentryAction::CancelAnimations;
    result.config.reentryAtScroll = 3;
    result.offset = { 0, 1300 };
    result.steps.push_back(smoothScroll({ 0, 1500 }));
    result.steps.push_back(frames());
    return result;
}

// A smooth scroll retargeted, before its first frame, to where it starts: the retarget fails, and the scroll
// keeps the state the retarget gave it.
inline Case retargetToCurrentOffsetCase()
{
    Case result;
    result.name = "RetargetToCurrentOffset";
    result.config = unitConfig();
    result.offset = { 0, 1000 };
    result.steps.push_back(smoothScroll({ 0, 1180 }));
    result.steps.push_back(retarget({ 0, 1000 }));
    result.steps.push_back(frames());
    return result;
}

// A momentum glide whose destination is cut off by a smaller contents size.
inline Case momentumContentsSizeChangedCase()
{
    Case result;
    result.name = "MomentumContentsSizeChanged";
    result.config = unitConfig();
    result.offset = { 0, 1300 };
    SnapDescription snap;
    snap.offsets = evenlySpaced(0, 450, 12);
    result.snapInfos.push_back(snapInfo(snap));
    result.steps.push_back(setSnapInfo(0));
    GestureDescription gesture;
    gesture.deltas = decayingDeltas({ 0, 12 }, 0.9f, 6);
    gesture.momentumDeltas = decayingDeltas({ 0, 30 }, 0.9f, 8);
    appendGesture(result.steps, gesture);
    result.steps.push_back(frames(4));
    auto smaller = result.config;
    smaller.contentsSize = { 2400, 1600 };
    result.steps.push_back(setConfig(smaller));
    result.steps.push_back(step(Op::ContentsSizeChanged));
    result.steps.push_back(frames());
    return result;
}

// Page-down presses whose destination the keyboard scrolling animator truncates to an integral point: from a
// position between 0 and 1, from a position at or beyond 2^31, and on contents smaller than the viewport.
inline Case keyboardSubpixelPositionCase()
{
    Case result;
    result.name = "KeyboardSubpixelPosition";
    result.config = unitConfig();
    result.offset = { 0.25f, 0.5f };
    result.steps.push_back(keyDown(ScrollDirection::ScrollDown, ScrollGranularity::Page));
    result.steps.push_back(frames(2));
    result.steps.push_back(keyUp());
    result.steps.push_back(frames());
    return result;
}

inline Case keyboardPositionBeyondInt32Case()
{
    Case result;
    result.name = "KeyboardPositionBeyondInt32";
    result.config = unitConfig();
    result.config.contentsSize = { 6e9f, 6e9f };
    result.offset = { 3e9f, 2147483392.0f };
    result.steps.push_back(keyDown(ScrollDirection::ScrollDown, ScrollGranularity::Page));
    result.steps.push_back(frames(5));
    result.steps.push_back(keyUp());
    result.steps.push_back(frames());
    return result;
}

inline Case keyboardContentsSmallerThanViewportCase()
{
    Case result;
    result.name = "KeyboardContentsSmallerThanViewport";
    result.config = unitConfig();
    result.config.contentsSize = { 500, 400 };
    result.offset = { 0, 0 };
    result.steps.push_back(keyDown(ScrollDirection::ScrollDown, ScrollGranularity::Page));
    result.steps.push_back(frames(10));
    result.steps.push_back(keyUp());
    result.steps.push_back(frames());
    return result;
}

// Snap offsets with explicit snap areas, for the snap point selection case.
inline unsigned appendSnapArea(LayoutScrollSnapOffsetsInfo& info, float x, float y, float width, float height)
{
    unsigned index = info.snapAreas.size();
    info.snapAreas.append(LayoutRect(LayoutPoint(LayoutUnit(static_cast<double>(x)), LayoutUnit(static_cast<double>(y))), LayoutSize(LayoutUnit(static_cast<double>(width)), LayoutUnit(static_cast<double>(height)))));
    info.snapAreasIDs.append(NodeIdentifier(static_cast<uint64_t>(index + 1)));
    return index;
}

inline void appendSnapOffset(LayoutScrollSnapOffsetsInfo& info, ScrollEventAxis axis, float offset, std::initializer_list<unsigned> areas, bool stopAlways = false, bool hasSnapAreaLargerThanViewport = false)
{
    SnapOffset<LayoutUnit> snapOffset { LayoutUnit(static_cast<double>(offset)), stopAlways ? ScrollSnapStop::Always : ScrollSnapStop::Normal, hasSnapAreaLargerThanViewport, false, false, { }, { } };
    for (auto area : areas)
        snapOffset.snapAreaIndices.append(area);
    (axis == ScrollEventAxis::Vertical ? info.verticalSnapOffsets : info.horizontalSnapOffsets).append(WTF::move(snapOffset));
}

inline std::vector<LayoutScrollSnapOffsetsInfo> snapPointSelectionInfos()
{
    constexpr auto horizontal = ScrollEventAxis::Horizontal;
    constexpr auto vertical = ScrollEventAxis::Vertical;
    std::vector<LayoutScrollSnapOffsetsInfo> infos;

    // One snap offset.
    LayoutScrollSnapOffsetsInfo single;
    single.strictness = ScrollSnapStrictness::Mandatory;
    appendSnapOffset(single, vertical, 500, { appendSnapArea(single, 0, 500, 400, 300) });
    infos.push_back(single);

    // Proximity, a fractional offset, and offsets 3.5 apart for a tie.
    LayoutScrollSnapOffsetsInfo proximity;
    proximity.strictness = ScrollSnapStrictness::Proximity;
    for (float offset : { 300.0f, 1000.0f, 1003.5f, 1400.0f, 2500.0f })
        appendSnapOffset(proximity, vertical, offset, { appendSnapArea(proximity, 0, offset, 400, 300) });
    infos.push_back(proximity);

    // scroll-snap-stop: always on some offsets.
    LayoutScrollSnapOffsetsInfo stops;
    stops.strictness = ScrollSnapStrictness::Mandatory;
    for (float offset : { 0.0f, 300.0f, 600.0f, 900.0f, 1200.0f, 1500.0f, 2000.0f })
        appendSnapOffset(stops, vertical, offset, { appendSnapArea(stops, 0, offset, 400, 300) }, offset == 600 || offset == 1200 || offset == 2000);
    infos.push_back(stops);

    // Snap areas larger than the snapport, one between offsets further apart than the snapport and one between
    // offsets closer than it.
    LayoutScrollSnapOffsetsInfo large;
    large.strictness = ScrollSnapStrictness::Mandatory;
    for (auto [offset, length] : { std::pair { 200.0f, 700.0f }, { 1000.0f, 2000.0f }, { 3000.0f, 300.0f }, { 5000.0f, 1000.0f }, { 5300.0f, 300.0f }, { 7000.0f, 2000.0f } })
        appendSnapOffset(large, vertical, offset, { appendSnapArea(large, 0, offset, 400, length) }, false, length > 600);
    infos.push_back(large);

    // The same on the horizontal axis, with no strictness.
    LayoutScrollSnapOffsetsInfo largeHorizontal;
    for (auto [offset, length] : { std::pair { 0.0f, 300.0f }, { 900.0f, 2000.0f }, { 2900.0f, 300.0f }, { 4000.0f, 300.0f } })
        appendSnapOffset(largeHorizontal, horizontal, offset, { appendSnapArea(largeHorizontal, offset, 0, length, 400) }, false, length > 800);
    infos.push_back(largeHorizontal);

    // Snap areas off screen in the other axis, and an offset with two snap areas.
    LayoutScrollSnapOffsetsInfo offscreen;
    offscreen.strictness = ScrollSnapStrictness::Mandatory;
    appendSnapOffset(offscreen, vertical, 0, { appendSnapArea(offscreen, 0, 2000, 400, 300), appendSnapArea(offscreen, 0, 0, 400, 300) });
    appendSnapOffset(offscreen, vertical, 500, { appendSnapArea(offscreen, 3000, 500, 400, 300) });
    appendSnapOffset(offscreen, vertical, 1000, { appendSnapArea(offscreen, 3000, 1000, 400, 300), appendSnapArea(offscreen, 0, 1000, 400, 300) });
    appendSnapOffset(offscreen, vertical, 1500, { appendSnapArea(offscreen, 5000, 1500, 400, 300), appendSnapArea(offscreen, 0, 100, 400, 300) });
    infos.push_back(offscreen);

    // A grid whose snap areas are not visible at each other's offsets, one visible in one direction only, one never
    // compatible, and a far one.
    LayoutScrollSnapOffsetsInfo grid;
    grid.strictness = ScrollSnapStrictness::Mandatory;
    unsigned lowerLeft = appendSnapArea(grid, 0, 3000, 400, 400);
    unsigned upperRight = appendSnapArea(grid, 1000, 0, 400, 400);
    unsigned middle = appendSnapArea(grid, 2000, 3000, 400, 400);
    unsigned lower = appendSnapArea(grid, 2000, 6000, 400, 400);
    unsigned incompatible = appendSnapArea(grid, 5000, 100, 400, 300);
    unsigned far = appendSnapArea(grid, 30000, 30000, 400, 400);
    unsigned incompatibleHorizontally = appendSnapArea(grid, 100, 5000, 300, 400);
    appendSnapOffset(grid, horizontal, 0, { lowerLeft });
    appendSnapOffset(grid, horizontal, 1000, { upperRight });
    appendSnapOffset(grid, horizontal, 2000, { middle });
    appendSnapOffset(grid, horizontal, 30000, { far });
    appendSnapOffset(grid, horizontal, 35000, { incompatibleHorizontally });
    appendSnapOffset(grid, vertical, 0, { upperRight });
    appendSnapOffset(grid, vertical, 3000, { lowerLeft });
    appendSnapOffset(grid, vertical, 6000, { lower });
    appendSnapOffset(grid, vertical, 8000, { incompatible });
    appendSnapOffset(grid, vertical, 30000, { far });
    appendSnapOffset(grid, vertical, 35000, { incompatible });
    infos.push_back(grid);

    return infos;
}

// Snap point selection on each of snapPointSelectionInfos(), at and on both sides of each snap offset, each proximity
// threshold, each snap area edge and each midpoint, by the closest, directional and paging methods on both axes.
inline Case snapPointSelectionCase()
{
    Case result;
    result.name = "SnapPointSelection";
    result.config = unitConfig();
    result.config.contentsSize = { 40000, 40000 };
    result.offset = { 0, 0 };
    result.snapInfos = snapPointSelectionInfos();
    auto pagedBehavior = behaviorBits({ ScrollAnimator::ScrollBehavior::RespectScrollSnap, ScrollAnimator::ScrollBehavior::Paged, ScrollAnimator::ScrollBehavior::NeverAnimate });
    auto directionalBehavior = behaviorBits({ ScrollAnimator::ScrollBehavior::RespectScrollSnap, ScrollAnimator::ScrollBehavior::NeverAnimate });
    static constexpr float subpixel = 1.0f / 64;
    for (unsigned index = 0; index < result.snapInfos.size(); ++index) {
        const auto& info = result.snapInfos[index];
        result.steps.push_back(setSnapInfo(index));
        for (auto axis : { ScrollEventAxis::Horizontal, ScrollEventAxis::Vertical }) {
            const auto& offsets = axis == ScrollEventAxis::Vertical ? info.verticalSnapOffsets : info.horizontalSnapOffsets;
            float viewportLength = axis == ScrollEventAxis::Vertical ? 600 : 800;
            std::vector<float> destinations;
            for (unsigned i = 0; i < offsets.size(); ++i) {
                float offset = offsets[i].offset.toFloat();
                for (float delta : { 0.0f, 0.5f, 0.3f * viewportLength, viewportLength - 0.5f }) {
                    for (float side : { -subpixel, 0.0f, subpixel }) {
                        destinations.push_back(offset + delta + side);
                        destinations.push_back(offset - delta + side);
                    }
                }
                if (i + 1 < offsets.size())
                    destinations.push_back((offset + offsets[i + 1].offset.toFloat()) / 2);
            }
            // The other axis matters only where it has snap offsets or the snap areas are off screen in it.
            bool otherAxisMatters = !info.horizontalSnapOffsets.isEmpty() && !info.verticalSnapOffsets.isEmpty();
            for (auto& area : info.snapAreas)
                otherAxisMatters = otherAxisMatters || (axis == ScrollEventAxis::Vertical ? area.x() : area.y()) > 0;
            auto others = otherAxisMatters ? std::vector<float> { 0, 100, 3000 } : std::vector<float> { 0 };
            for (unsigned d = 0; d < destinations.size(); ++d) {
                float destination = destinations[d];
                for (float other : others) {
                    FloatPoint point = axis == ScrollEventAxis::Vertical ? FloatPoint { other, destination } : FloatPoint { destination, other };
                    result.steps.push_back(adjustedForSnapping(axis, point, ScrollSnapPointSelectionMethod::Closest, d % 2));
                    for (float from : { -50.0f, 0.0f, 50.0f }) {
                        auto position = step(Op::SetCurrentPosition);
                        position.a = axis == ScrollEventAxis::Vertical ? FloatPoint { other, destination + from } : FloatPoint { destination + from, other };
                        result.steps.push_back(position);
                        result.steps.push_back(adjustedForSnapping(axis, point, ScrollSnapPointSelectionMethod::Directional));
                    }
                }
                auto position = step(Op::SetCurrentPosition);
                position.a = axis == ScrollEventAxis::Vertical ? FloatPoint { 0, destination } : FloatPoint { destination, 0 };
                for (float delta : { -viewportLength, viewportLength }) {
                    result.steps.push_back(position);
                    result.steps.push_back(singleAxisScroll(axis, delta, d % 2 ? directionalBehavior : pagedBehavior));
                }
            }
        }
    }
    // Directional scrolls across several snap stops, and from a position outside the scroll range, so that a
    // destination with no velocity is clamped away from it.
    result.steps.push_back(setSnapInfo(2));
    for (auto [from, to] : { std::pair { 0.0f, 2500.0f }, { 2500.0f, 0.0f }, { -100.0f, -100.0f }, { 40000.0f, 40000.0f } }) {
        auto position = step(Op::SetCurrentPosition);
        position.a = { 0, from };
        result.steps.push_back(position);
        result.steps.push_back(adjustedForSnapping(ScrollEventAxis::Vertical, { 0, to }, ScrollSnapPointSelectionMethod::Directional));
    }
    return result;
}

// The case's many steps are not each followed by a snapshot: the trace has every result.
inline uint64_t snapPointSelectionDigest()
{
    Trace trace(TraceLevel::Full);
    std::vector<Case> one { snapPointSelectionCase() };
    return runCases(trace, one, false);
}

inline std::vector<Case> unitCases()
{
    std::vector<Case> cases;
    for (unsigned burst : { 3u, 4u, 5u })
        cases.push_back(discreteWheelBurstCase(burst));
    for (unsigned count : { 100u, 1000u })
        cases.push_back(snapGlideCase(count));
    cases.push_back(stopFromScrollCase());
    cases.push_back(retargetToCurrentOffsetCase());
    cases.push_back(momentumContentsSizeChangedCase());
    cases.push_back(keyboardSubpixelPositionCase());
    cases.push_back(keyboardPositionBeyondInt32Case());
    cases.push_back(keyboardContentsSmallerThanViewportCase());
    return cases;
}

inline uint64_t unitCaseDigest(const Case& testCase)
{
    Trace trace(TraceLevel::Full);
    std::vector<Case> one { testCase };
    return runCases(trace, one, true);
}

struct Shape {
    const char* name;
    Case (*make)();
};

inline const Shape* benchmarkShapes(size_t& count)
{
    static const Shape shapes[] = {
        { "SmoothScroll", smoothScrollShape },
        { "SmoothRetarget", smoothRetargetShape },
        { "KeyboardScroll", keyboardScrollShape },
        { "TrackpadGesture", trackpadGestureShape },
        { "RubberBand", rubberBandShape },
        { "ScrollSnapGesture", scrollSnapGestureShape },
        { "DiscreteWheelSnap", discreteWheelSnapShape },
        { "MixedSession", mixedSessionShape },
        { "ProgrammaticScroll", programmaticScrollShape },
        { "SteppedWheel", steppedWheelShape },
    };
    count = std::size(shapes);
    return shapes;
}

} // namespace ScrollPhysics
} // namespace TestWebKitAPI
