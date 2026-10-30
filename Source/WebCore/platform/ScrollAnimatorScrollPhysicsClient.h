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

#include <WebCore/ScrollAnimator.h>
#include <WebCore/ScrollPhysicsTypes.h>
#include <wtf/ForbidHeapAllocation.h>

namespace WebCore {

// What ScrollAnimator's scroll physics in Swift calls back into: the ScrollAnimator, and the snap offsets and timers
// it holds. Only ScrollAnimatorScrollPhysicsClientState makes one, on the stack of a ScrollAnimator member, for one
// call into Swift.
class __attribute__((swift_attr("~Sendable"))) ScrollAnimatorScrollPhysicsClient : public ScrollSnapPhysicsClient<ScrollAnimatorScrollPhysicsClient> {
public:
    // Swift takes this only inout, and must not copy, move or relocate it. Swift imports the class only if it has a
    // move constructor, so one is declared; it is never called.
    ScrollAnimatorScrollPhysicsClient(const ScrollAnimatorScrollPhysicsClient&) = delete;
    ScrollAnimatorScrollPhysicsClient& operator=(const ScrollAnimatorScrollPhysicsClient&) = delete;
    [[noreturn]] ScrollAnimatorScrollPhysicsClient(ScrollAnimatorScrollPhysicsClient&&);
    ~ScrollAnimatorScrollPhysicsClient();

    void startAnimationCallback() { animator().startAnimationCallback(); }
    void stopAnimationCallback() { animator().stopAnimationCallback(); }

    bool allowsHorizontalScrolling() { return constAnimator().allowsHorizontalScrolling(); }
    bool allowsVerticalScrolling() { return constAnimator().allowsVerticalScrolling(); }
    void immediateScrollBy(const FloatSize& delta, ScrollClamping clamping) { animator().immediateScrollBy(delta, clamping); }

    bool allowsHorizontalStretching(const PlatformWheelEvent& event) { return constAnimator().allowsHorizontalStretching(event); }
    bool allowsVerticalStretching(const PlatformWheelEvent& event) { return constAnimator().allowsVerticalStretching(event); }
    IntSize stretchAmount() { return constAnimator().stretchAmount(); }
    bool isPinnedOnSide(BoxSide side) { return constAnimator().isPinnedOnSide(side); }

    void deferWheelEventTestCompletion(WheelEventTestMonitor::DeferReason reason) { constAnimator().deferWheelEventTestCompletionForReason(constAnimator().scrollingNodeIDForTesting(), reason); }
    void removeWheelEventTestCompletionDeferral(WheelEventTestMonitor::DeferReason reason) { constAnimator().removeWheelEventTestCompletionDeferralForReason(constAnimator().scrollingNodeIDForTesting(), reason); }

    FloatPoint scrollOffset() { return constAnimator().scrollOffset(); }
    void willStartAnimatedScroll() { animator().willStartAnimatedScroll(); }
    void didStopAnimatedScroll() { animator().didStopAnimatedScroll(); }
    void didStopWheelEventScroll() { animator().didStopWheelEventScroll(); }
    float pageScaleFactor() { return constAnimator().pageScaleFactor(); }
    ScrollExtents scrollExtents() { return constAnimator().scrollExtents(); }

    // ScrollAnimator's scrollend timer.
    void startScrollendTimer() { animator().scheduleScrollendTimer(); }

protected:
    ScrollAnimatorScrollPhysicsClient() = default;

private:
    friend class ScrollSnapPhysicsClient<ScrollAnimatorScrollPhysicsClient>;

    ScrollAnimator& animator();
    const ScrollAnimator& constAnimator();
    const LayoutScrollSnapOffsetsInfo& snapOffsetsInfo() { return *constAnimator().m_snapOffsetsInfo; }
    ScrollAnimator& snapTimerOwner() { return animator(); }
    std::unique_ptr<ScrollingEffectsControllerTimer> createSnapTimer(Function<void()>&& function) { return animator().createTimer(WTF::move(function)); }
};

class ScrollAnimatorScrollPhysicsClientState final : public ScrollAnimatorScrollPhysicsClient {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    explicit ScrollAnimatorScrollPhysicsClientState(ScrollAnimator& animator)
        : m_animator(&animator)
        , m_constAnimator(animator)
    {
    }

    // For ScrollAnimator's const members, which only read the snap offsets and the scroll position.
    explicit ScrollAnimatorScrollPhysicsClientState(const ScrollAnimator& animator)
        : m_animator(nullptr)
        , m_constAnimator(animator)
    {
    }

    ScrollAnimatorScrollPhysicsClient& facade() LIFETIME_BOUND { return *this; }

private:
    friend class ScrollAnimatorScrollPhysicsClient;

    ScrollAnimator* const m_animator;
    const ScrollAnimator& m_constAnimator;
};

inline ScrollAnimator& ScrollAnimatorScrollPhysicsClient::animator()
{
    auto* animator = static_cast<ScrollAnimatorScrollPhysicsClientState&>(*this).m_animator;
    RELEASE_ASSERT(animator);
    return *animator;
}

inline const ScrollAnimator& ScrollAnimatorScrollPhysicsClient::constAnimator()
{
    return static_cast<ScrollAnimatorScrollPhysicsClientState&>(*this).m_constAnimator;
}

} // namespace WebCore
