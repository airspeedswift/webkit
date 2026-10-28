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

// Deterministic inputs for ScrollingEffectsController: wheel gestures, smooth and keyboard scrolls, snap
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

inline Step smoothScroll(FloatPoint from, FloatPoint to)
{
    auto result = step(Op::StartAnimatedScroll);
    result.a = from;
    result.size = toFloatSize(to);
    return result;
}

inline Step retarget(FloatPoint to)
{
    auto result = step(Op::RetargetAnimatedScroll);
    result.a = to;
    return result;
}

inline Step retargetBy(FloatSize delta)
{
    auto result = step(Op::RetargetAnimatedScrollBy);
    result.size = delta;
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

inline KeyboardScroll keyboardScroll(ScrollDirection direction, ScrollGranularity granularity, float distance)
{
    // As KeyboardScrollingAnimator::makeKeyboardScroll() builds it.
    KeyboardScroll scroll;
    scroll.offset = unitVectorForScrollDirection(direction).scaled(distance);
    scroll.granularity = granularity;
    scroll.direction = direction;
    scroll.maximumVelocity = scroll.offset.scaled(KeyboardScrollParameters::parameters().maximumVelocityMultiplier);
    scroll.force = scroll.maximumVelocity.scaled(KeyboardScrollParameters::parameters().springMass / KeyboardScrollParameters::parameters().timeToMaximumVelocity);
    return scroll;
}

inline Step startKeyboard(const KeyboardScroll& scroll)
{
    auto result = step(Op::StartKeyboardScroll);
    result.keyboard = scroll;
    return result;
}

inline Step finishKeyboard(bool immediate)
{
    auto result = step(Op::FinishKeyboardScroll);
    result.flag = immediate;
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

inline Step adjustedDestination(ScrollEventAxis axis, FloatPoint destination, float velocity, std::optional<float> original, ScrollSnapPointSelectionMethod method)
{
    auto result = step(Op::AdjustedScrollDestination);
    result.axis = axis;
    result.a = destination;
    result.value = velocity;
    result.optionalFloat = original;
    result.method = method;
    return result;
}

inline Step setActiveIndex(ScrollEventAxis axis, std::optional<unsigned> index)
{
    auto result = step(Op::SetActiveScrollSnapIndex);
    result.axis = axis;
    result.optionalIndex = index;
    return result;
}

inline Step captureRestore(double secondsBetween)
{
    auto result = step(Op::CaptureRestoreRubberbanding);
    result.seconds = secondsBetween;
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
// Each shape is one case: one controller through one pass of a scroll session. The benchmark runs the pass
// once by default and many times in its full run.

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
    auto maximum = extentsFor(result.config).maximumScrollOffset();
    FloatPoint from = result.offset;
    for (unsigned i = 0; i < 64; ++i) {
        // About one in eight destinations is past the extents.
        FloatPoint to { random.between(-100, maximum.x() + 100), from.y() + random.between(-800, 800) };
        if (random.chance(12))
            to.setY(random.chance(50) ? -200 : maximum.y() + 200);
        result.steps.push_back(smoothScroll(from, to));
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
        result.steps.push_back(smoothScroll(result.offset, center));
        result.steps.push_back(retargetFrames(center, { random.between(-20, 20), random.between(-60, 60) }, 48));
        result.steps.push_back(frames());
    }
    return result;
}

inline Case keyboardScrollShape()
{
    Case result;
    result.name = "KeyboardScroll";
    result.config = benchConfig();
    result.offset = { 200, 5000 };
    static constexpr ScrollDirection directions[] = { ScrollDirection::ScrollDown, ScrollDirection::ScrollRight, ScrollDirection::ScrollUp, ScrollDirection::ScrollLeft };
    Lcg random(3);
    auto maximum = extentsFor(result.config).maximumScrollOffset();
    for (unsigned i = 0; i < 32; ++i) {
        // Every eighth run starts against an edge, for the rubber-band force.
        if (i % 8 == 7)
            result.steps.push_back(setConfig(result.config, FloatPoint(0, maximum.y())));
        auto direction = directions[i % 4];
        auto granularity = i % 3 ? ScrollGranularity::Line : ScrollGranularity::Page;
        result.steps.push_back(startKeyboard(keyboardScroll(direction, granularity, granularity == ScrollGranularity::Line ? 40 : 540)));
        result.steps.push_back(frames(random.range(6, 40)));
        result.steps.push_back(finishKeyboard(false));
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
    result.config.reentrant = true;
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
    result.config.reentrant = true;
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
    result.config.reentrant = true;
    result.offset = { 0, 4000 };
    SnapDescription snap;
    snap.offsets = evenlySpaced(0, 600, 34);
    result.snapInfos.push_back({ });
    result.snapInfos.push_back(snapInfo(snap));
    Lcg random(8);
    auto maximum = extentsFor(result.config).maximumScrollOffset();
    for (unsigned i = 0; i < 40; ++i) {
        switch (random.range(0, 7)) {
        case 0:
            result.steps.push_back(smoothScroll(result.offset, { 0, random.between(0, maximum.y()) }));
            result.steps.push_back(frames());
            break;
        case 1:
            result.steps.push_back(startKeyboard(keyboardScroll(random.chance(50) ? ScrollDirection::ScrollDown : ScrollDirection::ScrollUp, ScrollGranularity::Line, 40)));
            result.steps.push_back(frames(random.range(4, 30)));
            result.steps.push_back(finishKeyboard(false));
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
            result.steps.push_back(setConfig(result.config, FloatPoint(0, 0)));
            GestureDescription gesture;
            gesture.deltas = decayingDeltas({ 0, random.between(8, 25) }, 0.95f, random.range(6, 14));
            appendGesture(result.steps, gesture);
            result.steps.push_back(captureRestore(0.05));
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
            result.steps.push_back(smoothScroll(result.offset, { 0, random.between(0, maximum.y()) }));
            result.steps.push_back(frames(random.range(1, 10)));
            result.steps.push_back(step(Op::ContentsSizeChanged));
            result.steps.push_back(frames());
            break;
        case 7:
            result.steps.push_back(adjustedDestination(ScrollEventAxis::Vertical, { 0, random.between(0, maximum.y()) }, random.between(-2000, 2000), random.between(0, maximum.y()), ScrollSnapPointSelectionMethod::Closest));
            break;
        }
    }
    return result;
}

// MARK: - Unit cases
//
// ScrollPhysics.cpp checks each one's full trace digest: the input classes a size, count or ordering in the
// controller depends on.

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

// A glide over many snap offsets, with a client that re-enters the controller on every scroll.
inline Case snapGlideCase(unsigned snapOffsets)
{
    Case result;
    result.name = "SnapGlide" + std::to_string(snapOffsets);
    result.config = unitConfig();
    result.config.contentsSize = { 800, 200000 };
    result.config.reentrant = true;
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

// The client stops the smooth scroll from inside the scroll the animation asked for.
inline Case stopFromScrollCase()
{
    Case result;
    result.name = "StopFromScroll";
    result.config = unitConfig();
    result.config.reentrant = true;
    result.config.reentryAction = ReentryAction::StopAnimatedScroll;
    result.config.reentryAtScroll = 3;
    result.offset = { 0, 1300 };
    result.steps.push_back(smoothScroll({ 0, 1300 }, { 0, 1500 }));
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
    result.steps.push_back(smoothScroll({ 0, 1000 }, { 0, 1180 }));
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

// Keyboard scrolls whose position the animation truncates to an integral point within the extents: a position
// between 0 and 1, a position at or beyond 2^31, and contents smaller than the viewport while the key is held.
inline Case keyboardSubpixelPositionCase()
{
    Case result;
    result.name = "KeyboardSubpixelPosition";
    result.config = unitConfig();
    result.config.roundScrollOffset = false;
    result.offset = { 0.25f, 0.5f };
    result.steps.push_back(startKeyboard(keyboardScroll(ScrollDirection::ScrollDown, ScrollGranularity::Line, 40)));
    result.steps.push_back(frames(2));
    result.steps.push_back(finishKeyboard(false));
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
    result.steps.push_back(startKeyboard(keyboardScroll(ScrollDirection::ScrollDown, ScrollGranularity::Page, 540)));
    result.steps.push_back(frames(5));
    result.steps.push_back(finishKeyboard(false));
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
    result.steps.push_back(startKeyboard(keyboardScroll(ScrollDirection::ScrollDown, ScrollGranularity::Line, 40)));
    result.steps.push_back(frames(10));
    result.steps.push_back(finishKeyboard(false));
    result.steps.push_back(frames());
    return result;
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
    };
    count = std::size(shapes);
    return shapes;
}

} // namespace ScrollPhysics
} // namespace TestWebKitAPI
