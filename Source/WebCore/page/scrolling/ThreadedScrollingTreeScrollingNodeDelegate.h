/*
 * Copyright (C) 2019 Apple Inc. All rights reserved.
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

#include <WebCore/ScrollingTreeScrollingNodeDelegate.h>

#if ENABLE(ASYNC_SCROLLING) && ENABLE(SCROLLING_THREAD)

#include <WebCore/ScrollingEffectsController.h>
#include <wtf/TZoneMalloc.h>

namespace WebCore {

class FloatPoint;
class FloatSize;
class IntPoint;
class ScrollingStateScrollingNode;
class ScrollingTreeScrollingNode;
class ScrollingTree;
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
class ScrollingTreeScrollPhysicsClient;
struct ScrollingTreeScrollPhysicsDelegateHolder;
#endif

#if USE_SWIFT_SCROLLING_TREE_DELEGATE
class ThreadedScrollingTreeScrollingNodeDelegate : public ScrollingTreeScrollingNodeDelegate {
#else
class ThreadedScrollingTreeScrollingNodeDelegate : public ScrollingTreeScrollingNodeDelegate, private ScrollingEffectsControllerClient {
#endif
    WTF_MAKE_TZONE_ALLOCATED(ThreadedScrollingTreeScrollingNodeDelegate);
public:
    void updateSnapScrollState();

#if HAVE(APPKIT_GESTURES_SUPPORT)
    float rubberbandHyperbolicCoefficientForTesting() const final { return m_scrollController.rubberbandHyperbolicCoefficientForTesting(); }
#endif

protected:
    explicit ThreadedScrollingTreeScrollingNodeDelegate(ScrollingTreeScrollingNode&);
    virtual ~ThreadedScrollingTreeScrollingNodeDelegate();

#if !USE_SWIFT_SCROLLING_TREE_DELEGATE
    void updateUserScrollInProgressForEvent(const PlatformWheelEvent&);
#endif

    void updateFromStateNode(const ScrollingStateScrollingNode&) override;

    bool startAnimatedScrollToPosition(FloatPoint, ScrollAnimationCurve) override;
    void stopAnimatedScroll(EnumSet<AnimatedScrollType>) override;
    void stopSpringAnimation() override;
    void serviceScrollAnimation(MonotonicTime) override;

#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    std::unique_ptr<ScrollingEffectsControllerTimer> createTimer(Function<void()>&&);
    void destroyTimer(std::unique_ptr<ScrollingEffectsControllerTimer>);
#else
    // ScrollingEffectsControllerClient.
    std::unique_ptr<ScrollingEffectsControllerTimer> createTimer(Function<void()>&&) override;
    void destroyTimer(std::unique_ptr<ScrollingEffectsControllerTimer>) override;
    void startAnimationCallback(ScrollingEffectsController&) override;
    void stopAnimationCallback(ScrollingEffectsController&) override;

    bool allowsHorizontalScrolling() const override;
    bool allowsVerticalScrolling() const override;

    void immediateScrollBy(const FloatSize&, ScrollClamping = ScrollClamping::Clamped) override;
    void adjustScrollPositionToBoundsIfNecessary() override;

    bool scrollPositionIsNotRubberbandingEdge(const FloatPoint&) const;

    FloatPoint scrollOffset() const override;
    float pageScaleFactor() const override;

    void willStartAnimatedScroll() override;
    void didStopAnimatedScroll() override;
    void willStartWheelEventScroll() override;
    void didStopWheelEventScroll() override;
    void willStartScrollSnapAnimation() override;
    void didStopScrollSnapAnimation() override;

    ScrollExtents scrollExtents() const override;

    void deferWheelEventTestCompletionForReason(ScrollingNodeID, WheelEventTestMonitor::DeferReason) const override;
    void removeWheelEventTestCompletionDeferralForReason(ScrollingNodeID, WheelEventTestMonitor::DeferReason) const override;

    ScrollingNodeID scrollingNodeIDForTesting() const final;
#endif

    FloatPoint adjustedScrollPosition(const FloatPoint&) const override;

    void handleKeyboardScrollRequest(const RequestedKeyboardScrollData&) override;

#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    void discreteSnapTransitionTimerFired();

    friend class ScrollingTreeScrollPhysicsClient;
    template<typename> friend class ScrollSnapPhysicsClient;
    std::unique_ptr<ScrollingTreeScrollPhysicsDelegateHolder> m_physics;
    std::optional<LayoutScrollSnapOffsetsInfo> m_snapOffsetsInfo;
    std::unique_ptr<ScrollingEffectsControllerTimer> m_discreteSnapTransitionTimer;
    std::unique_ptr<ScrollingEffectsControllerTimer> m_discreteScrollendTimer;
#else
    ScrollingEffectsController m_scrollController;
#endif
};

} // namespace WebCore

#endif // ENABLE(ASYNC_SCROLLING) && ENABLE(SCROLLING_THREAD)
