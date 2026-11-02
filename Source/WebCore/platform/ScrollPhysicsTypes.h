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

#include <WebCore/PlatformWheelEvent.h>
#include <WebCore/ScrollExtents.h>
#include <WebCore/ScrollingEffectsController.h>
#include <optional>
#include <wtf/ForbidHeapAllocation.h>

namespace WebCore {

// For Swift, which cannot name RectEdges<bool>.
using RubberBandingEdges = RectEdges<bool>;
// For Swift, which cannot name the std::optional specializations that the keyboard event's scroll direction and
// granularity functions return.
using OptionalScrollDirection = std::optional<ScrollDirection>;
using OptionalScrollGranularity = std::optional<ScrollGranularity>;
// For Swift, which cannot name the std::optional that ScrollableArea::targetSideForScrollDelta() returns.
using OptionalBoxSide = std::optional<BoxSide>;
// For Swift, which cannot name the std::optional that ScrollableArea's snap point index getters return.
using OptionalSnapPointIndex = std::optional<unsigned>;

// The snap offsets and the discrete scroll snap timer that a scroll physics client gives Swift. Derived provides
// snapOffsetsInfo(), createSnapTimer(), and snapTimerOwner(), which holds m_discreteSnapTransitionTimer and whose
// discreteSnapTransitionTimerFired() the timer calls.
template<typename Derived>
class ScrollSnapPhysicsClient {
public:
    unsigned snapOffsetCount(ScrollEventAxis axis) { return snapOffsets(axis).size(); }
    LayoutUnit snapOffset(ScrollEventAxis axis, unsigned index) { return snapOffsets(axis)[index].offset; }
    bool snapOffsetIsFocused(ScrollEventAxis axis, unsigned index) { return snapOffsets(axis)[index].isFocused; }
    bool snapOffsetIsTarget(ScrollEventAxis axis, unsigned index) { return snapOffsets(axis)[index].isTarget; }
    uint64_t snapOffsetTargetID(ScrollEventAxis axis, unsigned index)
    {
        auto identifier = snapOffsets(axis)[index].snapTargetID.asOptional();
        return identifier ? identifier->toUInt64() : 0;
    }
    unsigned snapOffsetAreaIndexCount(ScrollEventAxis axis, unsigned index) { return snapOffsets(axis)[index].snapAreaIndices.size(); }
    size_t snapOffsetAreaIndex(ScrollEventAxis axis, unsigned index, unsigned areaIndex) { return snapOffsets(axis)[index].snapAreaIndices[areaIndex]; }
    unsigned snapAreaCount() { return snapOffsetsInfo().snapAreas.size(); }
    LayoutRect snapArea(unsigned index) { return snapOffsetsInfo().snapAreas[index]; }
    unsigned snapAreaIDCount() { return snapOffsetsInfo().snapAreasIDs.size(); }
    uint64_t snapAreaID(unsigned index) { return snapOffsetsInfo().snapAreasIDs[index].toUInt64(); }
    bool scrollerHasVerticalWritingMode() { return snapOffsetsInfo().scrollerHasVerticalWritingMode; }
    bool snapOffsetStopsAlways(ScrollEventAxis axis, unsigned index) { return snapOffsets(axis)[index].stop == ScrollSnapStop::Always; }
    bool snapOffsetHasSnapAreaLargerThanViewport(ScrollEventAxis axis, unsigned index) { return snapOffsets(axis)[index].hasSnapAreaLargerThanViewport; }
    bool snapStrictnessIsProximity() { return snapOffsetsInfo().strictness == ScrollSnapStrictness::Proximity; }

    // The discrete scroll snap timer.
    bool isDiscreteSnapTimerActive()
    {
        auto& timer = derived().snapTimerOwner().m_discreteSnapTransitionTimer;
        return timer && timer->isActive();
    }

    void startDiscreteSnapTimer()
    {
        auto& owner = derived().snapTimerOwner();
        owner.m_discreteSnapTransitionTimer = derived().createSnapTimer([owner = &owner] {
            owner->discreteSnapTransitionTimerFired();
        });
        static constexpr Seconds discreteScrollSnapDelay = 100_ms;
        owner.m_discreteSnapTransitionTimer->startOneShot(discreteScrollSnapDelay);
    }

    // Returns whether there was a timer to stop.
    bool stopDiscreteSnapTimer()
    {
        auto& timer = derived().snapTimerOwner().m_discreteSnapTransitionTimer;
        if (!timer)
            return false;
        timer->stop();
        timer = nullptr;
        return true;
    }

protected:
    ScrollSnapPhysicsClient() = default;

private:
    Derived& derived() { return static_cast<Derived&>(*this); }
    const LayoutScrollSnapOffsetsInfo& snapOffsetsInfo() { return derived().snapOffsetsInfo(); }
    const Vector<SnapOffset<LayoutUnit>>& snapOffsets(ScrollEventAxis axis) { return axis == ScrollEventAxis::Horizontal ? snapOffsetsInfo().horizontalSnapOffsets : snapOffsetsInfo().verticalSnapOffsets; }
};

// The scroll physics' static helpers, which Swift calls for every client.
class ScrollPhysicsClient {
public:

    static bool platformMomentumScrollingPredictionEnabled();

    // The "Momentum scroll" signpost interval.
    static void momentumScrollBegan();
    static void momentumScrollEnded();

    static MonotonicTime monotonicTime(double seconds) { return MonotonicTime::fromRawSeconds(seconds); }
    static FloatSize scrollingVelocity(const PlatformWheelEvent& event) { return event.scrollingVelocity(); }

};

} // namespace WebCore
