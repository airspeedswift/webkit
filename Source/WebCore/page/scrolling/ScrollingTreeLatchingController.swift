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

// ScrollingTreeLatchingController's state and logic, the tree's gesture state, and the scrolling tree's wheel event
// handling. The latching and gesture state are behind one Mutex. A wheel event takes it at most once before the event
// reaches a node and once after a node handled it, and only when latching is on or the event's phases reach the gesture
// state; the other members take it once.

internal import Synchronization
internal import WebCore_Private.Core.BoxSides
internal import WebCore_Private.Core.FloatPoint
internal import WebCore_Private.Core.FloatSize
internal import WebCore_Private.Core.PlatformWheelEvent
internal import WebCore_Private.Core.ProcessQualified
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingNodeID
internal import WebCore_Private.Core.ScrollingTree
internal import WebCore_Private.Core.ScrollingTreeFrameScrollingNode
internal import WebCore_Private.Core.ScrollingTreeNode
internal import WebCore_Private.Core.ScrollingTreeOverflowScrollProxyNode
internal import WebCore_Private.Core.ScrollingTreeScrollingNode
internal import wtf.Core.MonotonicTime

@_expose(Cxx)
final class ScrollingTreeWheelState: Sendable {
    // The bits of WheelEventProcessingSteps::AsyncScrolling and SynchronousScrolling (ScrollingCoordinatorTypes.h).
    private static var asyncScrolling: UInt8 { WebCore.WheelEventProcessingSteps.AsyncScrolling.rawValue }
    private static var synchronousScrolling: UInt8 { WebCore.WheelEventProcessingSteps.SynchronousScrolling.rawValue }

    // See also ScrollLatchingController.cpp.
    private static let resetLatchedStateTimeout: Double = 100.0 / 1000.0

    private struct LatchedNode {
        var nodeID: WebCore.ScrollingNodeID
        var processingSteps: UInt8
    }

    // The phase notifications a gesture state change sends, in order.
    private struct PhaseNotifications {
        var count = 0
        var nodeIDs: (WebCore.ScrollingNodeID?, WebCore.ScrollingNodeID?) = (nil, nil)
        var phases: (WebCore.PlatformWheelEventPhase, WebCore.PlatformWheelEventPhase) = (.None, .None)

        mutating func send(_ nodeID: WebCore.ScrollingNodeID, _ phase: WebCore.PlatformWheelEventPhase) {
            if count == 0 {
                nodeIDs.0 = nodeID
                phases.0 = phase
            } else {
                nodeIDs.1 = nodeID
                phases.1 = phase
            }
            count += 1
        }

        func deliver(_ locked: borrowing WebCore.ScrollingTreeLockedAccess) {
            if count > 0, let nodeID = nodeIDs.0 {
                locked.handleWheelEventPhase(nodeID, phases.0)
            }
            if count > 1, let nodeID = nodeIDs.1 {
                locked.handleWheelEventPhase(nodeID, phases.1)
            }
        }
    }

    private struct State {
        var latchedNode: LatchedNode? = nil
        var processingStepsForCurrentGesture: UInt8? = nil
        // MonotonicTime's seconds since its epoch; 0 is MonotonicTime { }.
        var lastLatchedNodeInteractionTime: Double = 0
        // The nodes that received the current gesture's MayBegin and Began phases.
        var mayBeginNodeID: WebCore.ScrollingNodeID? = nil
        var activeNodeID: WebCore.ScrollingNodeID? = nil

        func latchedNodeHasRecentInteraction() -> Bool {
            let secondsSinceLastInteraction = WTF.MonotonicTime.now().secondsSinceEpoch().value() - lastLatchedNodeInteractionTime
            return secondsSinceLastInteraction < ScrollingTreeWheelState.resetLatchedStateTimeout
        }

        mutating func receivedWheelEvent(_ isGestureStart: Bool, _ processingSteps: UInt8, _ allowLatching: Bool) {
            if !allowLatching {
                return
            }
            if isGestureStart && !latchedNodeHasRecentInteraction() {
                latchedNode = nil
                processingStepsForCurrentGesture = processingSteps
            }
        }

        func latchingDataForEvent(_ useLatchedEventElement: Bool, _ isGestureStart: Bool, _ allowLatching: Bool) -> LatchedNode? {
            if !allowLatching {
                return nil
            }
            guard useLatchedEventElement, let latchedNode else {
                return nil
            }
            if isGestureStart && !latchedNodeHasRecentInteraction() {
                return nil
            }
            return latchedNode
        }

        mutating func latchingNodeDidHandleEvent(
            _ nodeID: WebCore.ScrollingNodeID, _ processingSteps: UInt8,
            _ useLatchedEventElement: Bool, _ isEndOfMomentumScroll: Bool, _ deltaIsZero: Bool,
            _ isGestureStart: Bool, _ isGestureContinuation: Bool, _ allowLatching: Bool
        ) {
            if !allowLatching {
                return
            }

            if useLatchedEventElement, let latchedNode, latchedNode.nodeID.isEqual(nodeID) {
                if isEndOfMomentumScroll {
                    lastLatchedNodeInteractionTime = 0
                } else {
                    lastLatchedNodeInteractionTime = WTF.MonotonicTime.now().secondsSinceEpoch().value()
                }
                return
            }

            let shouldLatch: Bool
            if deltaIsZero {
                shouldLatch = false
            } else if isGestureStart {
                shouldLatch = true
            } else if !isGestureContinuation {
                shouldLatch = false
            } else {
                let stepsForCurrentGesture = processingStepsForCurrentGesture ?? 0
                shouldLatch = stepsForCurrentGesture & ScrollingTreeWheelState.synchronousScrolling != 0
                    && processingSteps & ScrollingTreeWheelState.asyncScrolling != 0
            }

            if !shouldLatch {
                return
            }

            processingStepsForCurrentGesture = processingSteps
            latchedNode = LatchedNode(nodeID: nodeID, processingSteps: processingSteps)
            lastLatchedNodeInteractionTime = WTF.MonotonicTime.now().secondsSinceEpoch().value()
        }

        mutating func gestureNodeDidHandleEvent(
            _ nodeID: WebCore.ScrollingNodeID, _ phase: WebCore.PlatformWheelEventPhase,
            _ momentumPhase: WebCore.PlatformWheelEventPhase, _ isGestureCancel: Bool
        ) -> PhaseNotifications {
            var notifications = PhaseNotifications()
            switch phase {
            case .MayBegin:
                mayBeginNodeID = nodeID
                notifications.send(nodeID, phase)
            case .Cancelled:
                // We can get here via handleWheelEventAfterMainThread(), in which case the gesture cancel was not
                // handled first.
                if isGestureCancel, let mayBeginNodeID {
                    notifications.send(mayBeginNodeID, .Cancelled)
                }
            case .Began:
                activeNodeID = nodeID
                notifications.send(nodeID, phase)
            case .Ended:
                if let activeNodeID {
                    notifications.send(activeNodeID, phase)
                }
            default:
                break
            }

            switch momentumPhase {
            case .MayBegin, .Cancelled:
                assertionFailure()
            case .Began:
                activeNodeID = nodeID
                notifications.send(nodeID, momentumPhase)
            case .Ended:
                if let activeNodeID {
                    notifications.send(activeNodeID, momentumPhase)
                }
            default:
                break
            }
            return notifications
        }
    }

    private let state = Mutex(State())

    /// Made by the scrolling tree's constructor, on the thread that creates the tree.
    @_expose(Cxx)
    init() {}

    /// Called on the event dispatcher's queue (ScrollingTree::determineWheelEventProcessing()), with the tree's state
    /// lock held.
    @_expose(Cxx)
    nonisolated func receivedWheelEvent(_ isGestureStart: Bool, _ processingSteps: UInt8, _ allowLatching: Bool) {
        if !allowLatching {
            return
        }

        state.withLock { state in
            state.receivedWheelEvent(isGestureStart, processingSteps, allowLatching)
        }
    }

    /// Called on the event dispatcher's queue, with the tree's state lock held. Returns whether there is a latched node
    /// for the event, and if so stores it and its processing steps in `nodeID` and `processingSteps`.
    @_expose(Cxx)
    nonisolated func latchingDataForEvent(
        _ useLatchedEventElement: Bool, _ isGestureStart: Bool, _ allowLatching: Bool,
        _ nodeID: inout WebCore.ScrollingNodeID, _ processingSteps: inout UInt8
    ) -> Bool {
        if !allowLatching {
            return false
        }

        return state.withLock { state in
            guard let latchedNode = state.latchingDataForEvent(useLatchedEventElement, isGestureStart, allowLatching) else {
                return false
            }
            nodeID = latchedNode.nodeID
            processingSteps = latchedNode.processingSteps
            return true
        }
    }

    /// Called on any thread. Returns whether there is a latched node, and if so stores it and its processing steps
    /// in `nodeID` and `processingSteps`.
    @_expose(Cxx)
    nonisolated func latchedNodeAndSteps(_ nodeID: inout WebCore.ScrollingNodeID, _ processingSteps: inout UInt8) -> Bool {
        state.withLock { state in
            guard let latchedNode = state.latchedNode else {
                return false
            }
            nodeID = latchedNode.nodeID
            processingSteps = latchedNode.processingSteps
            return true
        }
    }

    /// Called on the thread that commits the tree, when a node is removed.
    @_expose(Cxx)
    nonisolated func nodeWasRemoved(_ nodeID: WebCore.ScrollingNodeID) {
        state.withLock { state in
            if let latchedNode = state.latchedNode, latchedNode.nodeID.isEqual(nodeID) {
                state.latchedNode = nil
            }
        }
    }

    /// Called on any thread.
    @_expose(Cxx)
    nonisolated func clearLatchedNode() {
        state.withLock { state in
            state.latchedNode = nil
        }
    }

    // MARK: Wheel event handling

    /// Whether an event with these phases changes the gesture state or sends a phase notification.
    private static func phasesChangeGestureState(
        _ phase: WebCore.PlatformWheelEventPhase, _ momentumPhase: WebCore.PlatformWheelEventPhase
    ) -> Bool {
        switch phase {
        case .MayBegin, .Cancelled, .Began, .Ended:
            return true
        default:
            break
        }
        switch momentumPhase {
        case .MayBegin, .Cancelled, .Began, .Ended:
            return true
        default:
            return false
        }
    }

    /// After `nodeID` handled `event`: the latching and gesture state, under one lock take, then the gesture's phase
    /// notifications, in order. The lock is not taken when latching is off and the event's phases leave the gesture
    /// state as it is.
    @inline(always)
    private func nodeDidHandleEvent(
        _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ nodeID: WebCore.ScrollingNodeID,
        _ processingSteps: UInt8, _ event: borrowing @_addressable WebCore.PlatformWheelEvent, _ allowLatching: Bool
    ) {
        let phase = event.phase()
        let momentumPhase = event.momentumPhase()
        if !allowLatching && !Self.phasesChangeGestureState(phase, momentumPhase) {
            return
        }
        let isGestureCancel = event.isGestureCancel()
        let notifications: PhaseNotifications
        if allowLatching {
            let useLatchedEventElement = event.useLatchedEventElement()
            let isEndOfMomentumScroll = event.isEndOfMomentumScroll()
            let deltaIsZero = event.delta().isZero()
            let isGestureStart = event.isGestureStart()
            let isGestureContinuation = event.isGestureContinuation()
            notifications = state.withLock { state in
                state.latchingNodeDidHandleEvent(
                    nodeID, processingSteps, useLatchedEventElement, isEndOfMomentumScroll, deltaIsZero, isGestureStart,
                    isGestureContinuation, allowLatching)
                return state.gestureNodeDidHandleEvent(nodeID, phase, momentumPhase, isGestureCancel)
            }
        } else {
            notifications = state.withLock { state in
                state.gestureNodeDidHandleEvent(nodeID, phase, momentumPhase, isGestureCancel)
            }
        }
        notifications.deliver(locked)
    }

    /// ScrollingTree::handleWheelEvent() after the wheel event test monitor and up to the hit test. Called on the
    /// scrolling thread (the web process's scrolling thread, the UI process's scrolling thread, or the caller's thread
    /// in tests) with the tree's lock held, which `locked` shows; in the UI process the layer hit-test lock is held
    /// too, taken before the tree's lock. `hasRootNode` and `asyncFrameOrOverflowScrollingEnabled` are the tree's,
    /// read under its lock.
    ///
    /// Returns the result, or sets `needsHitTest` when no latched node took the event: the caller then hit tests at the
    /// event's position and calls handleWheelEventWithNode() with the node it finds, keeping the C++'s lock order.
    /// `event` is the caller's argument, which nothing this calls changes.
    @_expose(Cxx)
    nonisolated func handleWheelEvent(
        _ locked: borrowing WebCore.ScrollingTreeLockedAccess,
        _ event: borrowing @_addressable WebCore.PlatformWheelEvent, _ processingSteps: UInt8, _ allowLatching: Bool,
        _ hasRootNode: Bool, _ asyncFrameOrOverflowScrollingEnabled: Bool, _ needsHitTest: inout Bool
    ) -> WebCore.WheelEventHandlingResult {
        needsHitTest = false
        let isGestureStart = event.isGestureStart()
        if !hasRootNode {
            receivedWheelEvent(isGestureStart, processingSteps, allowLatching)
            return .result(false)
        }

        if !asyncFrameOrOverflowScrollingEnabled {
            receivedWheelEvent(isGestureStart, processingSteps, allowLatching)
            guard let rootNode = locked.rootNode().get(),
                let rootScrollingNode = WebCore.asScrollingTreeScrollingNode(rootNode).get()
            else {
                return .result(false)
            }
            // The root node is the tree's, which `locked` shows.
            let result = unsafe rootScrollingNode.handleWheelEvent(event, .Propagate) // U5(m_treeLock): the caller holds it
            if result.wasHandled {
                let phase = event.phase()
                let momentumPhase = event.momentumPhase()
                if Self.phasesChangeGestureState(phase, momentumPhase) {
                    let isGestureCancel = event.isGestureCancel()
                    let notifications = state.withLock { state in
                        state.gestureNodeDidHandleEvent(rootNode.scrollingNodeID(), phase, momentumPhase, isGestureCancel)
                    }
                    notifications.deliver(locked)
                }
            }
            return result
        }

        // The latching controller's receivedWheelEvent(), the gesture state's handleGestureCancel() and
        // receivedWheelEvent(), and the latching controller's latchingDataForEvent(), in that order.
        enum Next {
            case cancel(WebCore.ScrollingNodeID?)
            case latched(LatchedNode?)
        }
        // With latching off, only a gesture's cancel or start reads or changes the state.
        let isGestureCancel = event.isGestureCancel()
        let next: Next
        if !allowLatching && !isGestureCancel && !isGestureStart {
            next = .latched(nil)
        } else {
            let useLatchedEventElement = event.useLatchedEventElement()
            next = state.withLock { state -> Next in
                state.receivedWheelEvent(isGestureStart, processingSteps, allowLatching)
                if isGestureCancel {
                    return .cancel(state.mayBeginNodeID)
                }
                if isGestureStart {
                    state.mayBeginNodeID = nil
                    state.activeNodeID = nil
                }
                return .latched(state.latchingDataForEvent(useLatchedEventElement, isGestureStart, allowLatching))
            }
        }

        switch next {
        case .cancel(let mayBeginNodeID):
            if let mayBeginNodeID {
                locked.handleWheelEventPhase(mayBeginNodeID, .Cancelled)
            }
            // The root node's tree is the tree `locked` shows.
            locked.rootNode().get()?.scrollingTree().get()?.clearNodesWithUserScrollInProgress()
            return .result(true)
        case .latched(let latchedNode):
            var result = WebCore.WheelEventHandlingResult()
            if let latchedNode, WebCore.handleWheelEventOnScrollingNodeForID(locked, latchedNode.nodeID, event, &result) {
                if result.wasHandled {
                    nodeDidHandleEvent(locked, latchedNode.nodeID, processingSteps, event, allowLatching)
                }
                return result
            }
        }

        needsHitTest = true
        return .result(false)
    }

    /// ScrollingTree::handleWheelEventWithNode(): offers the event to `startingNode` and, with
    /// EventTargeting::Propagate, to the nodes that enclose it. `startingScrollingNode` is `startingNode` if it is a
    /// scrolling node, or else nil. Called on the scrolling thread with the tree's lock held, which `locked` shows.
    /// `event` is the caller's argument, which nothing this calls changes.
    @_expose(Cxx)
    nonisolated func handleWheelEventWithNode(
        _ locked: borrowing WebCore.ScrollingTreeLockedAccess,
        _ event: borrowing @_addressable WebCore.PlatformWheelEvent, _ processingSteps: UInt8, _ allowLatching: Bool,
        _ startingNode: WebCore.ScrollingTreeNode, _ startingScrollingNode: WebCore.ScrollingTreeScrollingNode?,
        _ eventTargeting: WebCore.EventTargeting
    ) -> WebCore.WheelEventHandlingResult {
        // `startingNode` is the caller's, so `locked` checks that it is the tree's; the nodes that enclose it are
        // then the tree's too.
        var adjustedWheelEvent: WebCore.PlatformWheelEvent
        if let scrollingNode = startingScrollingNode {
            let result = locked.handleWheelEvent(scrollingNode, event, eventTargeting)
            if let result = afterNodeOffered(
                locked, scrollingNode, event, result, processingSteps, allowLatching, eventTargeting)
            {
                return result
            }
            adjustedWheelEvent = scrollingNode.eventForPropagation(event)
        } else {
            adjustedWheelEvent = copy event
        }

        var node = enclosingNode(locked, startingNode, true)
        while let currentNode = node {
            if let scrollingNode = WebCore.asScrollingTreeScrollingNode(currentNode).get() {
                let result = unsafe scrollingNode.handleWheelEvent(adjustedWheelEvent, eventTargeting) // U5(m_treeLock): caller holds it
                if let result = afterNodeOffered(
                    locked, scrollingNode, adjustedWheelEvent, result, processingSteps, allowLatching, eventTargeting)
                {
                    return result
                }
                adjustedWheelEvent = scrollingNode.eventForPropagation(adjustedWheelEvent)
            }
            node = enclosingNode(locked, currentNode, false)
        }
        return .result(false)
    }

    /// After `scrollingNode` was offered `event` and gave `result`: the result handleWheelEventWithNode() returns, or
    /// nil when the event goes on to the nodes that enclose `scrollingNode`.
    @inline(always)
    private func afterNodeOffered(
        _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ scrollingNode: WebCore.ScrollingTreeScrollingNode,
        _ event: borrowing @_addressable WebCore.PlatformWheelEvent, _ result: WebCore.WheelEventHandlingResult,
        _ processingSteps: UInt8, _ allowLatching: Bool, _ eventTargeting: WebCore.EventTargeting
    ) -> WebCore.WheelEventHandlingResult? {
        if result.wasHandled {
            nodeDidHandleEvent(locked, scrollingNode.scrollingNodeID(), processingSteps, event, allowLatching)
            return result
        }

        if result.needsMainThreadProcessing() || eventTargeting != .Propagate {
            return result
        }

        let scrollPropagationInfo = scrollPropagation(
            scrollingNode.horizontalOverscrollBehaviorPreventsPropagation(),
            scrollingNode.verticalOverscrollBehaviorPreventsPropagation(), event.delta())
        if scrollPropagationInfo.shouldBlockScrollPropagation {
            let nodeID = scrollingNode.scrollingNodeID()
            if !scrollPropagationInfo.isHandled {
                // As ScrollingTreeWheelEventTestMonitorCompletionDeferrer's constructor and destructor, on the node's tree.
                if let tree = scrollingNode.scrollingTree().get() {
                    tree.deferWheelEventTestCompletionForReason(nodeID, .None)
                    tree.removeWheelEventTestCompletionDeferralForReason(nodeID, .None)
                }
                return .result(false)
            }
            nodeDidHandleEvent(locked, nodeID, processingSteps, event, allowLatching)
            return .result(true)
        }
        return nil
    }

    /// ScrollingTree::stopSpringAnimationsForWheelEvent() from the hit test's node: stops the spring animations of
    /// `startingNode` and of the nodes that enclose it. Called on the UI process's event dispatcher thread with the
    /// layer hit-test lock and the tree's lock held, in that order; `locked` shows the tree's.
    @_expose(Cxx)
    nonisolated func stopSpringAnimations(
        _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ startingNode: WebCore.ScrollingTreeNode
    ) {
        var node: WebCore.ScrollingTreeNode? = startingNode
        // As in handleWheelEventWithNode(), `locked` checks `startingNode`, the caller's.
        var isStartingNode = true
        while let currentNode = node {
            if let scrollingNode = WebCore.asScrollingTreeScrollingNode(currentNode).get() {
                if isStartingNode {
                    locked.stopSpringAnimation(scrollingNode)
                } else {
                    unsafe scrollingNode.stopSpringAnimation() // U5(m_treeLock): the caller's Locker holds it; locked is in scope
                }
            }
            node = enclosingNode(locked, currentNode, isStartingNode)
            isStartingNode = false
        }
    }

    /// The node an event goes to after `node`: an overflow scroll proxy's overflow scrolling node, if the tree has it,
    /// or else `node`'s parent. `isStartingNode` says that `node` is the caller's, which `locked` checks; any other
    /// `node` came from the tree's node map or is a parent of one of its nodes.
    @inline(always)
    private func enclosingNode(
        _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ node: WebCore.ScrollingTreeNode, _ isStartingNode: Bool
    ) -> WebCore.ScrollingTreeNode? {
        if let proxyNode = WebCore.asScrollingTreeOverflowScrollProxyNode(node).get(),
            let relatedNodeID = Optional(fromCxx: proxyNode.overflowScrollingNodeID()),
            let relatedNode = locked.nodeForID(relatedNodeID).get() {
            return relatedNode
        }
        if isStartingNode {
            return locked.parent(node).get()
        }
        return unsafe node.parent().get() // U5(m_treeLock): the caller's Locker holds it; locked is in scope
    }
}

/// ScrollingTreeScrollingNode::computeScrollPropagation(): whether a scrolling node whose overscroll behavior prevents
/// scroll propagation horizontally or vertically keeps a wheel event's `delta` from the nodes that enclose it, and if
/// so, whether the event counts as handled. Reads only its arguments, so it may be called on any thread; the tree calls
/// it on the scrolling thread with its lock held.
@_expose(Cxx)
nonisolated func scrollPropagation(
    _ horizontalPreventsPropagation: Bool, _ verticalPreventsPropagation: Bool, _ delta: WebCore.FloatSize
) -> WebCore.ScrollPropagationInfo {
    var propagation = WebCore.ScrollPropagationInfo()
    if !horizontalPreventsPropagation && !verticalPreventsPropagation {
        return propagation
    }

    // History swipe case
    if horizontalPreventsPropagation && delta.height() == 0 && delta.width() != 0 {
        propagation.shouldBlockScrollPropagation = true
        propagation.isHandled = false
        return propagation
    }

    if (horizontalPreventsPropagation && verticalPreventsPropagation)
        || (horizontalPreventsPropagation && delta.height() == 0)
        || (verticalPreventsPropagation && delta.width() == 0)
    {
        propagation.shouldBlockScrollPropagation = true
        propagation.isHandled = true
    }
    return propagation
}

/// ScrollingTreeScrollingNode::shouldRubberBandOnSide() once the node is pinned on `side`: whether a wheel event may
/// rubber-band the node on that side. The C++ member passes the node's root-ness, the client's rubber-banding
/// behavior for the main frame on `side` and the node's scrollable area parameters as values. Reads only its
/// arguments, so it may be called on any thread; the scrolling thread calls it, with the tree's lock held, from a
/// node's wheel event handling, and the main thread from the scroll physics delegate.
@_expose(Cxx)
nonisolated func scrollingNodeShouldRubberBandOnSide(
    _ side: WebCore.BoxSide, _ isRootNode: Bool, _ mainFrameRubberBandingBehavior: WebCore.RubberBandingBehavior,
    _ overscrollBehaviorAllowsHorizontalRubberBand: Bool, _ overscrollBehaviorAllowsVerticalRubberBand: Bool,
    _ canHaveHorizontalScrollbar: Bool, _ canHaveVerticalScrollbar: Bool,
    _ allowsHorizontalScrolling: Bool, _ allowsVerticalScrolling: Bool,
    _ horizontalPreventsPropagation: Bool, _ verticalPreventsPropagation: Bool
) -> Bool {
    if isRootNode && mainFrameRubberBandingBehavior == .Never {
        return false
    }

    switch side {
    case .Top, .Bottom:
        if !overscrollBehaviorAllowsVerticalRubberBand {
            return false
        }

        // The root allows rubberbanding if it doesn't have enough content, but only if a scrollbar is allowed.
        if isRootNode && canHaveVerticalScrollbar {
            if !allowsVerticalScrolling && mainFrameRubberBandingBehavior == .BasedOnSize {
                return false
            }
            return true
        }

        if !allowsVerticalScrolling {
            return false
        }
        return verticalPreventsPropagation

    case .Left, .Right:
        if !overscrollBehaviorAllowsHorizontalRubberBand {
            return false
        }

        // The root allows rubberbanding if it doesn't have enough content, but only if a scrollbar is allowed.
        if isRootNode && canHaveHorizontalScrollbar {
            if !allowsHorizontalScrolling && mainFrameRubberBandingBehavior == .BasedOnSize {
                return false
            }
            return true
        }

        if !allowsHorizontalScrolling {
            return false
        }
        return horizontalPreventsPropagation

    @unknown default:
        return true
    }
}

/// FloatPoint::constrainedBetween() on one axis: std::max(minimum, std::min(maximum, value)), with std::min and
/// std::max's choices when a value is NaN.
@inline(always)
private func constrainedBetween(_ value: Float, _ minimum: Float, _ maximum: Float) -> Float {
    let upperBounded = value < maximum ? value : maximum
    return minimum < upperBounded ? upperBounded : minimum
}

/// ScrollingTreeScrollingNode::eventCanScrollContents() for a wheel event whose `delta` is not zero: whether
/// scrolling the node by the event moves it within its scroll extents. The C++ member passes the node's scroll
/// positions and whether it scrolls on each axis. Reads only its arguments, so it may be called on any thread; the
/// scrolling thread calls it with the tree's lock held.
@_expose(Cxx)
nonisolated func scrollingNodeEventCanScrollContents(
    _ delta: WebCore.FloatSize, _ allowsHorizontalScrolling: Bool, _ allowsVerticalScrolling: Bool,
    _ currentScrollPosition: WebCore.FloatPoint, _ minimumScrollPosition: WebCore.FloatPoint,
    _ maximumScrollPosition: WebCore.FloatPoint
) -> Bool {
    let deltaWidth: Float = allowsHorizontalScrolling ? delta.width() : 0
    let deltaHeight: Float = allowsVerticalScrolling ? delta.height() : 0

    let oldX = currentScrollPosition.x()
    let oldY = currentScrollPosition.y()
    let newX = constrainedBetween(oldX - deltaWidth, minimumScrollPosition.x(), maximumScrollPosition.x())
    let newY = constrainedBetween(oldY - deltaHeight, minimumScrollPosition.y(), maximumScrollPosition.y())
    return !(newX == oldX && newY == oldY)
}

/// ScrollingTreeScrollingNode::edgePinnedState(): the edges at which the node cannot scroll further, as bits in the
/// order of RectEdges' members (1 top, 2 right, 4 bottom, 8 left). An axis the node does not scroll on is pinned at
/// both of its edges. Reads only its arguments, so it may be called on any thread; the C++ member passes the node's
/// scroll positions and whether it scrolls on each axis.
@_expose(Cxx)
nonisolated func scrollingNodeEdgePinnedState(
    _ scrollPosition: WebCore.FloatPoint, _ minimumScrollPosition: WebCore.FloatPoint,
    _ maximumScrollPosition: WebCore.FloatPoint, _ allowsHorizontalScrolling: Bool, _ allowsVerticalScrolling: Bool
) -> UInt8 {
    let horizontallyUnscrollable = !allowsHorizontalScrolling
    let verticallyUnscrollable = !allowsVerticalScrolling

    var pinnedEdges: UInt8 = 0
    if verticallyUnscrollable || scrollPosition.y() <= minimumScrollPosition.y() {
        pinnedEdges |= 1
    }
    if horizontallyUnscrollable || scrollPosition.x() >= maximumScrollPosition.x() {
        pinnedEdges |= 2
    }
    if verticallyUnscrollable || scrollPosition.y() >= maximumScrollPosition.y() {
        pinnedEdges |= 4
    }
    if horizontallyUnscrollable || scrollPosition.x() <= minimumScrollPosition.x() {
        pinnedEdges |= 8
    }
    return pinnedEdges
}
