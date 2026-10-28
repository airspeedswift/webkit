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

// What ScrollingEffectsController's Swift implementation calls back into: the controller's client,
// and the timers the controller owns. Only ScrollPhysicsClientState makes one, on the stack of a
// ScrollingEffectsController member, for one call into Swift.
class __attribute__((swift_attr("~Sendable"))) ScrollPhysicsClient {
public:
    // Swift takes this only inout, and must not copy, move or relocate it. Swift imports the class only if it has a
    // move constructor, so one is declared; it is never called.
    ScrollPhysicsClient(const ScrollPhysicsClient&) = delete;
    ScrollPhysicsClient& operator=(const ScrollPhysicsClient&) = delete;
    [[noreturn]] ScrollPhysicsClient(ScrollPhysicsClient&&);
    ~ScrollPhysicsClient();

    void startAnimationCallback() { client().startAnimationCallback(controller()); }
    void stopAnimationCallback() { client().stopAnimationCallback(controller()); }

    bool allowsHorizontalScrolling() { return client().allowsHorizontalScrolling(); }
    bool allowsVerticalScrolling() { return client().allowsVerticalScrolling(); }
    void immediateScrollBy(const FloatSize& delta, ScrollClamping clamping) { client().immediateScrollBy(delta, clamping); }

    bool allowsHorizontalStretching(const PlatformWheelEvent& event) { return client().allowsHorizontalStretching(event); }
    bool allowsVerticalStretching(const PlatformWheelEvent& event) { return client().allowsVerticalStretching(event); }
    IntSize stretchAmount() { return client().stretchAmount(); }
    bool isScrollDeltaOpposingStretch(ScrollEventAxis axis, float delta) { return client().isScrollDeltaOpposingStretch(axis, delta); }
    bool isPinnedOnSide(BoxSide side) { return client().isPinnedOnSide(side); }
    bool shouldRubberBandOnSide(BoxSide side, const FloatSize& delta) { return client().shouldRubberBandOnSide(side, delta); }
    void willStartRubberBandAnimation() { client().willStartRubberBandAnimation(); }
    void didStopRubberBandAnimation() { client().didStopRubberBandAnimation(); }
    void rubberBandingStateChanged(bool isRubberBanding) { client().rubberBandingStateChanged(isRubberBanding); }
    FloatSize rubberBandTargetOffset() { return client().rubberBandTargetOffset(); }
    bool hasRefreshController() { return client().hasRefreshController(); }
    float refreshControllerSnappingThreshold() { return client().refreshControllerSnappingThreshold(); }

    void deferWheelEventTestCompletion(WheelEventTestMonitor::DeferReason reason) { client().deferWheelEventTestCompletionForReason(client().scrollingNodeIDForTesting(), reason); }
    void removeWheelEventTestCompletionDeferral(WheelEventTestMonitor::DeferReason reason) { client().removeWheelEventTestCompletionDeferralForReason(client().scrollingNodeIDForTesting(), reason); }

    FloatPoint scrollOffset() { return client().scrollOffset(); }
    void willStartAnimatedScroll() { client().willStartAnimatedScroll(); }
    void didStopAnimatedScroll() { client().didStopAnimatedScroll(); }
    void willStartWheelEventScroll() { client().willStartWheelEventScroll(); }
    void didStopWheelEventScroll() { client().didStopWheelEventScroll(); }
    void willStartScrollSnapAnimation() { client().willStartScrollSnapAnimation(); }
    void didStopScrollSnapAnimation() { client().didStopScrollSnapAnimation(); }
    float pageScaleFactor() { return client().pageScaleFactor(); }
    ScrollExtents scrollExtents() { return client().scrollExtents(); }

    // The snap offsets ScrollingEffectsController::snapOffsetsInfo() returns.
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
    std::pair<LayoutUnit, std::optional<unsigned>> closestSnapOffset(ScrollEventAxis axis, const LayoutSize& viewportSize, LayoutPoint destination, float velocity, bool hasOriginalPosition, float originalPosition, ScrollSnapPointSelectionMethod method) { return snapOffsetsInfo().closestSnapOffset(axis, viewportSize, destination, velocity, hasOriginalPosition ? std::make_optional(LayoutUnit(originalPosition)) : std::nullopt, method); }

    // The controller's discrete scroll snap and scrollend timers.
    bool isDiscreteSnapTimerActive();
    void startDiscreteSnapTimer();
    // Returns whether there was a timer to stop.
    bool stopDiscreteSnapTimer();
    void startScrollendTimer() { controller().scheduleScrollendTimer(); }

    static bool platformMomentumScrollingPredictionEnabled();

    // The "Momentum scroll" signpost interval.
    static void momentumScrollBegan();
    static void momentumScrollEnded();

    static MonotonicTime monotonicTime(double seconds) { return MonotonicTime::fromRawSeconds(seconds); }
    static FloatSize scrollingVelocity(const PlatformWheelEvent& event) { return event.scrollingVelocity(); }

protected:
    ScrollPhysicsClient() = default;

private:
    ScrollingEffectsControllerClient& client();
    ScrollingEffectsController& controller();
    const LayoutScrollSnapOffsetsInfo& snapOffsetsInfo();
    const Vector<SnapOffset<LayoutUnit>>& snapOffsets(ScrollEventAxis axis) { return axis == ScrollEventAxis::Horizontal ? snapOffsetsInfo().horizontalSnapOffsets : snapOffsetsInfo().verticalSnapOffsets; }
};

class ScrollPhysicsClientState final : public ScrollPhysicsClient {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    // controller is null in ScrollingEffectsController's const members, which only read the snap offsets.
    ScrollPhysicsClientState(ScrollingEffectsControllerClient& client, ScrollingEffectsController* controller, const std::optional<LayoutScrollSnapOffsetsInfo>& snapOffsetsInfo LIFETIME_BOUND)
        : m_client(client)
        , m_controller(controller)
        , m_snapOffsetsInfo(snapOffsetsInfo)
    {
    }

    ScrollPhysicsClient& facade() LIFETIME_BOUND { return *this; }

private:
    friend class ScrollPhysicsClient;

    ScrollingEffectsControllerClient& m_client;
    ScrollingEffectsController* m_controller;
    const std::optional<LayoutScrollSnapOffsetsInfo>& m_snapOffsetsInfo;
};

inline ScrollingEffectsControllerClient& ScrollPhysicsClient::client()
{
    return static_cast<ScrollPhysicsClientState&>(*this).m_client;
}

inline ScrollingEffectsController& ScrollPhysicsClient::controller()
{
    auto* controller = static_cast<ScrollPhysicsClientState&>(*this).m_controller;
    RELEASE_ASSERT(controller);
    return *controller;
}

inline const LayoutScrollSnapOffsetsInfo& ScrollPhysicsClient::snapOffsetsInfo()
{
    return *static_cast<ScrollPhysicsClientState&>(*this).m_snapOffsetsInfo;
}

} // namespace WebCore
