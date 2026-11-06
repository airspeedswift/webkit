/*
 * Copyright (C) 2020 Apple Inc. All rights reserved.
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

#if ENABLE(ASYNC_SCROLLING)

#include <WebCore/ScrollTypes.h>
#include <wtf/Lock.h>
#include <wtf/Markable.h>
#include <wtf/MonotonicTime.h>
#include <wtf/OptionSet.h>
#include <array>
#include <cstddef>
#include <memory>

namespace WebCore {

class PlatformWheelEvent;
enum class WheelEventProcessingSteps : uint8_t;
class ScrollingTreeWheelState;

class ScrollingTreeLatchingController {
public:
    struct ScrollingNodeAndProcessingSteps {
        ScrollingNodeID scrollingNodeID;
        OptionSet<WheelEventProcessingSteps> processingSteps;
    };

    NODELETE ScrollingTreeLatchingController();
    ~ScrollingTreeLatchingController();
    ScrollingTreeLatchingController(const ScrollingTreeLatchingController&) = delete;
    ScrollingTreeLatchingController& operator=(const ScrollingTreeLatchingController&) = delete;

    // The latching and gesture state, and the tree's wheel event handling (ScrollingTreeLatchingController.swift).
    ScrollingTreeWheelState& wheelState() const LIFETIME_BOUND;

    void receivedWheelEvent(const PlatformWheelEvent&, OptionSet<WheelEventProcessingSteps>, bool allowLatching);

    std::optional<ScrollingNodeAndProcessingSteps> latchingDataForEvent(const PlatformWheelEvent&, bool allowLatching) const;

    NODELETE std::optional<ScrollingNodeID> latchedNodeID() const;

    NODELETE void nodeWasRemoved(ScrollingNodeID);
    NODELETE void clearLatchedNode();

private:
    // Keeps the size and alignment of the members above, as ScrollingTree's layout does (ScrollingTree.h).
    struct StateLayout {
        Lock latchedNodeLock;
        std::optional<ScrollingNodeAndProcessingSteps> latchedNodeAndSteps;
        std::optional<OptionSet<WheelEventProcessingSteps>> processingStepsForCurrentGesture;
        MonotonicTime lastLatchedNodeInterationTime;
    };
    alignas(StateLayout) const std::unique_ptr<ScrollingTreeWheelState> m_state;
    [[maybe_unused]] std::array<std::byte, sizeof(StateLayout) - sizeof(m_state)> m_unusedStateStorage { };
};

}

#endif // ENABLE(ASYNC_SCROLLING)
