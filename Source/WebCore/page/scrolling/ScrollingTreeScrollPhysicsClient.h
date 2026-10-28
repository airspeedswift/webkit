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

#include <wtf/Platform.h>

#if ENABLE(ASYNC_SCROLLING) && ENABLE(SCROLLING_THREAD)

// RubberbandingState.h, ScrollerPairMac.h and ScrollingCoordinatorTypes.h are for the Swift delegate's members in
// WebCoreSwift-Generated.h.
#include <WebCore/RubberbandingState.h>
#include <WebCore/ScrollPhysicsTypes.h>
#include <WebCore/ScrollerPairMac.h>
#include <WebCore/ScrollingCoordinatorTypes.h>
#include <WebCore/ScrollingTree.h>
#include <WebCore/ScrollingTreeFrameScrollingNode.h>
#include <WebCore/ThreadedScrollingTreeScrollingNodeDelegate.h>
#include <wtf/ForbidHeapAllocation.h>

namespace WebCore {

// What the scrolling tree's scroll delegate in Swift calls back into: its node, and the snap offsets and timers its
// C++ class holds. Only ScrollingTreeScrollPhysicsClientState makes one, on the stack of a
// ThreadedScrollingTreeScrollingNodeDelegate member, for one call into Swift.
class __attribute__((swift_attr("~Sendable"))) ScrollingTreeScrollPhysicsClient : public ScrollSnapPhysicsClient<ScrollingTreeScrollPhysicsClient> {
public:
    // Swift takes this only inout, and must not copy, move or relocate it. Swift imports the class only if it has a
    // move constructor, so one is declared; it is never called.
    ScrollingTreeScrollPhysicsClient(const ScrollingTreeScrollPhysicsClient&) = delete;
    ScrollingTreeScrollPhysicsClient& operator=(const ScrollingTreeScrollPhysicsClient&) = delete;
    [[noreturn]] ScrollingTreeScrollPhysicsClient(ScrollingTreeScrollPhysicsClient&&);
    ~ScrollingTreeScrollPhysicsClient();

    ScrollingTreeScrollingNode& node();
    Ref<ScrollingTree> scrollingTree()
    {
        RefPtr tree = node().scrollingTree();
        RELEASE_ASSERT(tree);
        return tree.releaseNonNull();
    }
    // Null when the node is not a frame's.
    ScrollingTreeFrameScrollingNode* frameNode() { return dynamicDowncast<ScrollingTreeFrameScrollingNode>(node()); }

    // The ScrollingPerformanceTestRubberBand signpost.
    void emitRubberBandSignpost(bool isRubberBanding, IntSize stretch, bool isMainFrame);

    // The scrollend timer.
    void startScrollendTimer();

protected:
    ScrollingTreeScrollPhysicsClient() = default;

private:
    friend class ScrollSnapPhysicsClient<ScrollingTreeScrollPhysicsClient>;

    ThreadedScrollingTreeScrollingNodeDelegate& delegate();
    // The snap offsets of the delegate's last state node.
    const LayoutScrollSnapOffsetsInfo& snapOffsetsInfo() { return *delegate().m_snapOffsetsInfo; }
    ThreadedScrollingTreeScrollingNodeDelegate& snapTimerOwner() { return delegate(); }
    std::unique_ptr<ScrollingEffectsControllerTimer> createSnapTimer(Function<void()>&& function) { return delegate().createTimer(WTF::move(function)); }
};

class ScrollingTreeScrollPhysicsClientState final : public ScrollingTreeScrollPhysicsClient {
    WTF_FORBID_HEAP_ALLOCATION;
public:
    explicit ScrollingTreeScrollPhysicsClientState(ThreadedScrollingTreeScrollingNodeDelegate& delegate)
        : m_delegate(&delegate)
        , m_node(delegate.scrollingNode())
    {
    }

    // For the delegate's const members, which reach neither the snap offsets nor the timers.
    explicit ScrollingTreeScrollPhysicsClientState(Ref<ScrollingTreeScrollingNode>&& node)
        : m_delegate(nullptr)
        , m_node(WTF::move(node))
    {
    }

    ScrollingTreeScrollPhysicsClient& facade() LIFETIME_BOUND { return *this; }

private:
    friend class ScrollingTreeScrollPhysicsClient;

    ThreadedScrollingTreeScrollingNodeDelegate* const m_delegate;
    const Ref<ScrollingTreeScrollingNode> m_node;
};

inline ScrollingTreeScrollingNode& ScrollingTreeScrollPhysicsClient::node()
{
    return static_cast<ScrollingTreeScrollPhysicsClientState&>(*this).m_node;
}

inline ThreadedScrollingTreeScrollingNodeDelegate& ScrollingTreeScrollPhysicsClient::delegate()
{
    auto* delegate = static_cast<ScrollingTreeScrollPhysicsClientState&>(*this).m_delegate;
    RELEASE_ASSERT(delegate);
    return *delegate;
}

} // namespace WebCore

#endif // ENABLE(ASYNC_SCROLLING) && ENABLE(SCROLLING_THREAD)
