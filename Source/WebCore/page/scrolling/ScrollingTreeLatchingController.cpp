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

#include "config.h"
#include "ScrollingTreeLatchingController.h"

#if ENABLE(ASYNC_SCROLLING)

#include "FloatPoint.h"
#include "Logging.h"
#include "PlatformWheelEvent.h"
#include "ScrollingThread.h"
#include "ScrollingTree.h"
#include "WebCore-Swift.h"

namespace WebCore {

// The latched node, the processing steps of the current gesture, the time of the latched node's last interaction
// and the gesture state live in Swift (ScrollingTreeLatchingController.swift), under its own lock.
ScrollingTreeLatchingController::ScrollingTreeLatchingController()
    : m_state(makeUniqueWithoutFastMallocCheck<ScrollingTreeWheelState>(ScrollingTreeWheelState::init()))
{
    static_assert(sizeof(ScrollingTreeLatchingController) == sizeof(StateLayout));
    static_assert(alignof(ScrollingTreeLatchingController) == alignof(StateLayout));
}

ScrollingTreeLatchingController::~ScrollingTreeLatchingController() = default;

ScrollingTreeWheelState& ScrollingTreeLatchingController::wheelState() const
{
    return *m_state;
}

void ScrollingTreeLatchingController::receivedWheelEvent(const PlatformWheelEvent& wheelEvent, OptionSet<WheelEventProcessingSteps> processingSteps, bool allowLatching)
{
    m_state->receivedWheelEvent(wheelEvent.isGestureStart(), processingSteps.toRaw(), allowLatching);
}

std::optional<ScrollingTreeLatchingController::ScrollingNodeAndProcessingSteps> ScrollingTreeLatchingController::latchingDataForEvent(const PlatformWheelEvent& wheelEvent, bool allowLatching) const
{
    ScrollingNodeID nodeID { WTF::HashTableDeletedValue };
    uint8_t processingSteps = 0;
    if (!m_state->latchingDataForEvent(wheelEvent.useLatchedEventElement(), wheelEvent.isGestureStart(), allowLatching, nodeID, processingSteps))
        return std::nullopt;
    return ScrollingNodeAndProcessingSteps { nodeID, OptionSet<WheelEventProcessingSteps>::fromRaw(processingSteps) };
}

std::optional<ScrollingNodeID> ScrollingTreeLatchingController::latchedNodeID() const
{
    ScrollingNodeID nodeID { WTF::HashTableDeletedValue };
    uint8_t processingSteps = 0;
    if (!m_state->latchedNodeAndSteps(nodeID, processingSteps))
        return std::nullopt;
    return nodeID;
}

void ScrollingTreeLatchingController::nodeWasRemoved(ScrollingNodeID nodeID)
{
    m_state->nodeWasRemoved(nodeID);
}

void ScrollingTreeLatchingController::clearLatchedNode()
{
    m_state->clearLatchedNode();
}

} // namespace WebCore

#endif // ENABLE(ASYNC_SCROLLING)
