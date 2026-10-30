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

// ThreadedScrollingTreeScrollingNodeDelegate's and ScrollingTreeScrollingNodeDelegateMac's state and logic. The C++
// classes forward each member to a ScrollingTreeScrollPhysicsDelegate, passing a ScrollingTreeScrollPhysicsClient made
// on their stack for the call. No access to the delegate's stored state is held across a call into the node, which
// can call back into the delegate (ScrollingTreeScrollingNode::scrollBy() calls currentScrollPositionChanged()).
//
// The delegate is used on one thread at a time, under the scrolling tree's lock.

internal import WebCore_Private.Core.KeyboardScroll
internal import WebCore_Private.Core.PlatformWheelEvent
internal import WebCore_Private.Core.RubberbandingState
internal import WebCore_Private.Core.ScrollExtents
internal import WebCore_Private.Core.ScrollerPairMac
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingTree
internal import WebCore_Private.Core.ScrollingTreeFrameScrollingNode
internal import WebCore_Private.Core.ScrollingTreeScrollingNode
internal import WebCore_Private.ScrollPhysicsTypes
internal import WebCore_Private.ScrollingTreeScrollPhysicsClient
internal import AppKit
internal import QuartzCore
internal import WebCore_Private.Core.ColorCocoa
internal import WebCore_Private.Core.ScrollingStateNode
internal import WebCore_Private.Core.ScrollingStateScrollingNode
internal import WebCore_Private.ScrollerPairMacTypes

// The scrollers handleWheelEvent() tells when momentum starts and ends: the Swift scrollers of the node's
// ScrollerPairMac, or the ScrollerPairMac.
typealias NodeScrollerPair = MacScrollerPair

@_expose(Cxx)
final class ScrollingTreeScrollPhysicsDelegate {
    private let controller = ScrollPhysicsController()
    private var inMomentumPhase = false

    @_expose(Cxx)
    init() {}

    // MARK: ThreadedScrollingTreeScrollingNodeDelegate

    /// `c` is made for this call on the calling C++ member's stack; nothing else reaches it.
    ///
    /// The state node's changes: whether its snap offsets changed (the C++ holds them, in `c`) and whether there are
    /// any, and whether each axis's current snap index changed, and to what (-1 for none).
    @_expose(Cxx)
    func updateFromStateNode(
        client c: inout WebCore.ScrollingTreeScrollPhysicsClient,
        _ snapOffsetsChanged: Bool,
        _ hasSnapOffsets: Bool,
        _ horizontalSnapIndexChanged: Bool,
        _ horizontalSnapIndex: Int64,
        _ verticalSnapIndexChanged: Bool,
        _ verticalSnapIndex: Int64
    ) {
        if snapOffsetsChanged {
            controller.setSnapOffsetsInfo(&c, hasSnapOffsets)
        }

        if horizontalSnapIndexChanged {
            controller.setActiveScrollSnapIndexForAxis(.Horizontal, horizontalSnapIndex)
        }

        if verticalSnapIndexChanged {
            controller.setActiveScrollSnapIndexForAxis(.Vertical, verticalSnapIndex)
        }
    }

    /// `c` is made for this call on the calling C++ member's stack; nothing else reaches it.
    @_expose(Cxx)
    func updateSnapScrollState(client c: inout WebCore.ScrollingTreeScrollPhysicsClient) {
        let node = c.node()
        node.setScrollSnapInProgress(controller.isScrollSnapInProgress(c.isDiscreteSnapTimerActive()))

        if controller.activeScrollSnapIndexDidChange() {
            // ScrollPhysicsController gives a snap index as -1 for none, and otherwise as the unsigned it was given.
            let horizontalIndex = controller.activeScrollSnapIndexForAxis(.Horizontal)
            let verticalIndex = controller.activeScrollSnapIndexForAxis(.Vertical)
            c.scrollingTree().get()
                .setActiveScrollSnapIndices(
                    node.scrollingNodeID(),
                    horizontalIndex < 0 ? .init() : .init(CUnsignedInt(truncatingIfNeeded: horizontalIndex)),
                    verticalIndex < 0 ? .init() : .init(CUnsignedInt(truncatingIfNeeded: verticalIndex))
                )
        }
    }

    /// `c` is made for this call on the calling C++ member's stack; nothing else reaches it.
    @_expose(Cxx)
    func startAnimatedScrollToPosition(
        client c: inout WebCore.ScrollingTreeScrollPhysicsClient,
        _ destinationPosition: WebCore.FloatPoint
    ) -> Bool {
        let node = c.node()
        let scrollOrigin = node.scrollOrigin()
        // ScrollableArea::scrollOffsetFromPosition().
        let currentOffset = node.currentScrollOffset()
        let destinationOffset = WebCore.FloatPoint(
            destinationPosition.x() + Float(scrollOrigin.x()),
            destinationPosition.y() + Float(scrollOrigin.y())
        )
        return controller.startAnimatedScrollToDestination(&c, currentOffset, destinationOffset)
    }

    /// `c` is made for this call on the calling C++ member's stack; nothing else reaches it.
    @_expose(Cxx)
    func stopAnimatedScroll(client c: inout WebCore.ScrollingTreeScrollPhysicsClient) {
        controller.stopAnimatedScroll(&c)
    }

    /// `c` is made for this call on the calling C++ member's stack; nothing else reaches it.
    @_expose(Cxx)
    func serviceScrollAnimation(client c: inout WebCore.ScrollingTreeScrollPhysicsClient, _ currentTime: Double) {
        controller.animationCallback(&c, currentTime)
    }

    /// `c` is made for this call on the calling C++ member's stack; nothing else reaches it.
    ///
    /// A StartAnimation request always carries a keyboard scroll; one without crashes here.
    @_expose(Cxx)
    func handleKeyboardScrollRequest(
        client c: inout WebCore.ScrollingTreeScrollPhysicsClient,
        _ scrollData: WebCore.RequestedKeyboardScrollData
    ) {
        switch scrollData.action {
        case .StartAnimation:
            _ = controller.startKeyboardScroll(&c, Optional(fromCxx: scrollData.keyboardScroll)!)
        case .StopWithAnimation:
            controller.finishKeyboardScroll(&c, false)
        case .StopImmediately:
            controller.finishKeyboardScroll(&c, true)
        @unknown default:
            break
        }
    }

    /// `c` is made for this call on the calling C++ member's stack; nothing else reaches it.
    @_expose(Cxx)
    func discreteSnapTransitionTimerFired(client c: inout WebCore.ScrollingTreeScrollPhysicsClient) {
        controller.discreteSnapTransitionTimerFired(&c)
    }

    // MARK: ScrollingTreeScrollingNodeDelegateMac

    /// `c` is made for this call on the calling C++ member's stack; nothing else reaches it.
    ///
    /// The caller holds `scrollerPair` for the call. The wheel event is borrowed in place, so the stretching checks get
    /// its address rather than a copy; `timestamp` is its timestamp, in seconds.
    @_expose(Cxx)
    func handleWheelEvent(
        client c: inout WebCore.ScrollingTreeScrollPhysicsClient,
        _ scrollerPair: NodeScrollerPair,
        _ wheelEvent: borrowing @_addressable WebCore.PlatformWheelEvent,
        _ timestamp: Double
    ) -> Bool {
        let wasInMomentumPhase = inMomentumPhase

        let momentumPhase = wheelEvent.momentumPhase()
        if momentumPhase == .Began {
            inMomentumPhase = true
        } else if momentumPhase == .Ended || momentumPhase == .Cancelled {
            inMomentumPhase = false
        }

        let isInMomentumPhase = inMomentumPhase
        if wasInMomentumPhase != isInMomentumPhase {
            scrollerPair.setUsePresentationValues(isInMomentumPhase)
        }

        // ScrollingTreeWheelEventTestMonitorCompletionDeferrer: deferred for the whole event, whether or not the tree
        // is monitoring wheel events, and removed once the result is known.
        let node = c.node()
        let tree = c.scrollingTree().get()
        let nodeID = node.scrollingNodeID()
        tree.deferWheelEventTestCompletionForReason(nodeID, .HandlingWheelEvent)
        defer {
            tree.removeWheelEventTestCompletionDeferralForReason(nodeID, .HandlingWheelEvent)
        }

        let wasInUserScroll = controller.isUserScrollInProgress()
        controller.updateGestureInProgressState(&c, wheelEvent)
        let isInUserScroll = controller.isUserScrollInProgress()
        if isInUserScroll != wasInUserScroll {
            node.setUserScrollInProgress(isInUserScroll)
        }

        // PlatformWheelEventPhase::MayBegin fires when two fingers touch the trackpad, and is used to flash overlay
        // scrollbars. We know we're scrollable at this point, so handle the event.
        if wheelEvent.phase() == .MayBegin {
            return true
        }

        return controller.handleWheelEvent(&c, wheelEvent, timestamp)
    }

    /// `c` is made for this call on the calling C++ member's stack; nothing else reaches it.
    @_expose(Cxx)
    func willDoProgrammaticScroll(
        client c: inout WebCore.ScrollingTreeScrollPhysicsClient,
        _ targetPosition: WebCore.FloatPoint
    ) {
        if scrollPositionIsNotRubberbandingEdge(&c, targetPosition) {
            controller.stopRubberBanding(&c)
        }
    }

    // Whether a programmatic scroll to targetPosition leaves an edge that is rubber-banding.
    private func scrollPositionIsNotRubberbandingEdge(
        _ c: inout WebCore.ScrollingTreeScrollPhysicsClient,
        _ targetPosition: WebCore.FloatPoint
    ) -> Bool {
        if !controller.isRubberBandInProgress() {
            return false
        }

        let rubberbandingEdges = controller.rubberBandingEdges()

        let node = c.node()
        let minimumScrollPosition = node.minimumScrollPosition()
        let maximumScrollPosition = node.maximumScrollPosition()

        // In allBoxSides order.
        if rubberbandingEdges[.Top], targetPosition.y() != minimumScrollPosition.y() {
            return true
        }
        if rubberbandingEdges[.Right], targetPosition.x() != maximumScrollPosition.x() {
            return true
        }
        if rubberbandingEdges[.Bottom], targetPosition.y() != maximumScrollPosition.y() {
            return true
        }
        if rubberbandingEdges[.Left], targetPosition.x() != minimumScrollPosition.x() {
            return true
        }
        return false
    }

    /// `c` is made for this call on the calling C++ member's stack; nothing else reaches it.
    @_expose(Cxx)
    func currentScrollPositionChanged(client c: inout WebCore.ScrollingTreeScrollPhysicsClient) {
        controller.scrollPositionChanged(&c)
    }

    @_expose(Cxx)
    func isRubberBandInProgress() -> Bool {
        controller.isRubberBandInProgress()
    }

    /// `c` is made for this call on the calling C++ member's stack; nothing else reaches it.
    @_expose(Cxx)
    func startRubberBandSnapBack(client c: inout WebCore.ScrollingTreeScrollPhysicsClient) {
        controller.startRubberBandSnapBack(&c)
    }

    /// `c` is made for this call on the calling C++ member's stack; nothing else reaches it.
    @_expose(Cxx)
    func rubberBandTargetOffsetDidChange(client c: inout WebCore.ScrollingTreeScrollPhysicsClient) {
        controller.rubberBandTargetOffsetDidChange(&c)
    }

    /// `c` is made for this call on the calling C++ member's stack; nothing else reaches it.
    ///
    /// It reaches only the node: capturing reads neither the snap offsets nor the timers. `state` is a local of
    /// ScrollingTreeScrollingNodeDelegateMac::captureRubberbandingState(), which nothing Swift calls can reach.
    ///
    /// Returns false where ScrollingTreeScrollingNodeDelegateMac::captureRubberbandingState() returns nullopt.
    @_expose(Cxx)
    func captureRubberbandingState(
        client c: inout WebCore.ScrollingTreeScrollPhysicsClient,
        _ state: inout WebCore.RubberbandingState
    ) -> Bool {
        controller.captureRubberbandingState(&c, &state)
    }

    /// `c` is made for this call on the calling C++ member's stack; nothing else reaches it.
    ///
    /// `state` is the C++ delegate's pending state, which only its updateFromStateNode() reads or clears, after this
    /// returns.
    @_expose(Cxx)
    func restoreRubberbandingState(
        client c: inout WebCore.ScrollingTreeScrollPhysicsClient,
        _ state: WebCore.RubberbandingState
    ) {
        if controller.restoreRubberbandingState(&c, state) {
            c.node().setRestoredRubberbandingInProgress(true)
        }
    }

    /// The scrollbar part of ScrollingTreeScrollingNodeDelegateMac::updateFromStateNode().
    ///
    /// The caller holds `scrollerPair`, which owns `scrollers`, for the call. The other arguments are the state node's
    /// changed properties (as OptionSet<ScrollingStateNodeProperty>::toRaw()) and its scrollbar values; each scrollbar
    /// layer is nil unless it changed.
    ///
    /// The scrollable area parameters and the scrollbar color are the const state node's own members, borrowed for the
    /// call. Nothing called here reaches the state node: the scrollers and their main-thread tasks reach only the
    /// ScrollerPairMac, its scrolling tree node and AppKit.
    @_expose(Cxx)
    func updateScrollbars(
        _ scrollerPair: WebCore.ScrollerPairMac,
        _ scrollers: MacScrollerPair,
        _ changedProperties: UInt64,
        _ horizontalScrollerImp: NSScrollerImp?,
        _ verticalScrollerImp: NSScrollerImp?,
        _ scrollbarHoverState: WebCore.ScrollbarHoverState,
        _ horizontalScrollbarLayer: CALayer?,
        _ verticalScrollbarLayer: CALayer?,
        _ scrollableAreaParameters: WebCore.ScrollableAreaParameters,
        _ scrollbarEnabledState: WebCore.ScrollbarEnabledState,
        _ scrollbarLayoutDirection: WebCore.UserInterfaceLayoutDirection,
        _ scrollbarWidth: WebCore.ScrollbarWidth,
        _ useDarkAppearanceForScrollbars: Bool,
        _ mouseIsOverContentArea: Bool,
        _ mouseLocationState: WebCore.MouseLocationState,
        _ scrollbarColor: WebCore.OptionalScrollbarColor
    ) {
        func hasChangedProperty(_ property: WebCore.ScrollingStateNodeProperty) -> Bool {
            changedProperties & property.rawValue != 0
        }

        if hasChangedProperty(.PainterForScrollbar) {
            if horizontalScrollerImp != nil || verticalScrollerImp != nil {
                scrollers.releaseReferencesToScrollerImpsOnTheMainThread(scrollerPair)
                scrollers.setScrollerImp(scrollerPair, .Horizontal, horizontalScrollerImp)
                scrollers.setScrollerImp(scrollerPair, .Vertical, verticalScrollerImp)
            }
        }

        if hasChangedProperty(.ScrollbarHoverState) {
            scrollers.mouseIsInScrollbar(scrollerPair, scrollbarHoverState)
        }

        if hasChangedProperty(.HorizontalScrollbarLayer) {
            scrollers.setHostLayer(scrollerPair, .Horizontal, horizontalScrollbarLayer)
        }

        if hasChangedProperty(.VerticalScrollbarLayer) {
            scrollers.setHostLayer(scrollerPair, .Vertical, verticalScrollbarLayer)
        }

        if hasChangedProperty(.ScrollableAreaParams) {
            scrollers.setHiddenByStyle(scrollerPair, .Horizontal, scrollableAreaParameters.horizontalNativeScrollbarVisibility)
            scrollers.setHiddenByStyle(scrollerPair, .Vertical, scrollableAreaParameters.verticalNativeScrollbarVisibility)
        }

        if hasChangedProperty(.ScrollbarEnabledState) {
            scrollers.setEnabled(.Horizontal, scrollbarEnabledState.horizontalScrollbarIsEnabled)
            scrollers.setEnabled(.Vertical, scrollbarEnabledState.verticalScrollbarIsEnabled)
        }

        if hasChangedProperty(.ScrollbarLayoutDirection) {
            scrollers.setScrollbarLayoutDirection(scrollerPair, .Horizontal, scrollbarLayoutDirection)
            scrollers.setScrollbarLayoutDirection(scrollerPair, .Vertical, scrollbarLayoutDirection)
        }

        if hasChangedProperty(.ScrollbarWidth) {
            scrollers.setScrollbarWidth(scrollerPair, scrollbarWidth)
        }

        if hasChangedProperty(.UseDarkAppearanceForScrollbars) {
            scrollers.setUseDarkAppearance(useDarkAppearanceForScrollbars)
        }

        if hasChangedProperty(.ContentAreaHoverState) {
            if mouseIsOverContentArea {
                scrollers.notifyScrollerImpPair(scrollerPair, .MouseEnteredContentArea)
            } else {
                scrollers.mouseExitedContentArea()
                scrollers.notifyScrollerImpPair(scrollerPair, .MouseExitedContentArea)
            }
        }

        if hasChangedProperty(.MouseActivityState) {
            scrollers.mouseMovedInContentArea(mouseLocationState)
            scrollers.notifyScrollerImpPair(scrollerPair, .MouseMovedInContentArea)
        }

        if hasChangedProperty(.ScrollbarColor) {
            // Each scroller gets its own NSColors, the horizontal one first.
            for orientation: WebCore.ScrollbarOrientation in [.Horizontal, .Vertical] {
                if let color = scrollbarColor.value {
                    scrollers.scrollbarColorChanged(
                        scrollerPair,
                        orientation,
                        WebCore.cocoaColor(color.trackColor).get(),
                        WebCore.cocoaColor(color.thumbColor).get()
                    )
                } else {
                    scrollers.scrollbarColorChanged(scrollerPair, orientation, nil, nil)
                }
            }
        }

        scrollers.updateValues(scrollerPair)
    }

    /// The caller holds `scrollerPair`, which owns `scrollers`, for the call.
    @_expose(Cxx)
    func updateScrollbarPainters(_ scrollerPair: WebCore.ScrollerPairMac, _ scrollers: MacScrollerPair) {
        if inMomentumPhase && scrollers.hasScrollerImp() && scrollers.isUsingPresentationValues {
            scrollers.updateScrollbarPainters(scrollerPair)
        }
    }
}

// The scroll physics client of the scrolling tree's nodes on macOS: ThreadedScrollingTreeScrollingNodeDelegate's and
// ScrollingTreeScrollingNodeDelegateMac's ScrollingEffectsControllerClient members. The snap offsets and the timers
// are C++ members of ScrollingTreeScrollPhysicsClient; everything else is here.
extension WebCore.ScrollingTreeScrollPhysicsClient: ScrollPhysicsClientProtocol {
    mutating func startAnimationCallback() {
        node().setScrollAnimationInProgress(true)
    }

    mutating func stopAnimationCallback() {
        node().setScrollAnimationInProgress(false)
    }

    mutating func allowsHorizontalScrolling() -> Bool {
        node().allowsHorizontalScrolling()
    }

    mutating func allowsVerticalScrolling() -> Bool {
        node().allowsVerticalScrolling()
    }

    mutating func immediateScrollBy(_ delta: WebCore.FloatSize, _ clamping: WebCore.ScrollClamping) {
        node().scrollBy(delta, clamping)
    }

    mutating func allowsHorizontalStretching(_ event: borrowing @_addressable WebCore.PlatformWheelEvent) -> Bool {
        let node = self.node()
        switch node.horizontalScrollElasticity() {
        case .Automatic:
            let scrollbarsAllowStretching = node.allowsHorizontalScrolling() ? true : !node.allowsVerticalScrolling()
            let relevantSide = targetSideForScrollDelta(-ScrollSize(event.delta()), .Horizontal)
            var eventPreventsStretching = false
            if event.isGestureStart(), let relevantSide {
                eventPreventsStretching = isPinnedOnSide(relevantSide)
            }
            return scrollbarsAllowStretching && !eventPreventsStretching
        case .None:
            return false
        case .Allowed:
            if let relevantSide = targetSideForScrollDelta(-ScrollSize(event.delta()), .Horizontal) {
                return shouldRubberBandOnSide(relevantSide, event.delta())
            }
            return true
        @unknown default:
            return false
        }
    }

    mutating func allowsVerticalStretching(_ event: borrowing @_addressable WebCore.PlatformWheelEvent) -> Bool {
        let node = self.node()
        switch node.verticalScrollElasticity() {
        case .Automatic:
            let scrollbarsAllowStretching = node.allowsVerticalScrolling() ? true : !node.allowsHorizontalScrolling()
            let relevantSide = targetSideForScrollDelta(-ScrollSize(event.delta()), .Vertical)
            var eventPreventsStretching = false
            if event.isGestureStart(), let relevantSide {
                eventPreventsStretching = isPinnedOnSide(relevantSide)
            }
            return scrollbarsAllowStretching && !eventPreventsStretching
        case .None:
            return false
        case .Allowed:
            if let relevantSide = targetSideForScrollDelta(-ScrollSize(event.delta()), .Vertical) {
                return shouldRubberBandOnSide(relevantSide, event.delta())
            }
            return true
        @unknown default:
            return false
        }
    }

    mutating func stretchAmount() -> WebCore.IntSize {
        let node = self.node()
        var stretchWidth: Int32 = 0
        var stretchHeight: Int32 = 0
        let scrollPosition = node.currentScrollPosition()

        if scrollPosition.y() < node.minimumScrollPosition().y() {
            stretchHeight = intSizeComponent(scrollPosition.y() - node.minimumScrollPosition().y())
        } else if scrollPosition.y() > node.maximumScrollPosition().y() {
            stretchHeight = intSizeComponent(scrollPosition.y() - node.maximumScrollPosition().y())
        }

        if scrollPosition.x() < node.minimumScrollPosition().x() {
            stretchWidth = intSizeComponent(scrollPosition.x() - node.minimumScrollPosition().x())
        } else if scrollPosition.x() > node.maximumScrollPosition().x() {
            stretchWidth = intSizeComponent(scrollPosition.x() - node.maximumScrollPosition().x())
        }

        return WebCore.IntSize(stretchWidth, stretchHeight)
    }

    // ScrollingEffectsController::isScrollDeltaOpposingStretch().
    mutating func isScrollDeltaOpposingStretch(_ axis: WebCore.ScrollEventAxis, _ delta: Float) -> Bool {
        let stretch = stretchAmount()
        let stretchOnAxis = axis == .Horizontal ? stretch.width() : stretch.height()
        if stretchOnAxis == 0 || delta == 0 {
            return false
        }

        return (stretchOnAxis > 0 && delta < 0) || (stretchOnAxis < 0 && delta > 0)
    }

    // "Pinned" means scrolled at or beyond the edge.
    mutating func isPinnedOnSide(_ side: WebCore.BoxSide) -> Bool {
        let node = self.node()
        switch side {
        case .Top:
            if !node.allowsVerticalScrolling() {
                return true
            }
            return node.currentScrollPosition().y() <= node.minimumScrollPosition().y()
        case .Bottom:
            if !node.allowsVerticalScrolling() {
                return true
            }
            return node.currentScrollPosition().y() >= node.maximumScrollPosition().y()
        case .Left:
            if !node.allowsHorizontalScrolling() {
                return true
            }
            return node.currentScrollPosition().x() <= node.minimumScrollPosition().x()
        case .Right:
            if !node.allowsHorizontalScrolling() {
                return true
            }
            return node.currentScrollPosition().x() >= node.maximumScrollPosition().x()
        @unknown default:
            return false
        }
    }

    mutating func shouldRubberBandOnSide(_ side: WebCore.BoxSide, _ delta: WebCore.FloatSize) -> Bool {
        let axis: WebCore.ScrollEventAxis = (side == .Left || side == .Right) ? .Horizontal : .Vertical
        let deltaOnAxis = axis == .Horizontal ? -delta.width() : -delta.height()
        if isScrollDeltaOpposingStretch(axis, deltaOnAxis) {
            return true
        }

        let node = self.node()
        return node.shouldRubberBandOnSide(side, node.edgePinnedState())
    }

    mutating func willStartRubberBandAnimation() {
    }

    mutating func didStopRubberBandAnimation() {
        // Since the rubberband timer has stopped, totalContentsSizeForRubberBand can be synchronized with totalContentsSize.
        let node = self.node()
        node.setTotalContentsSizeForRubberBand(node.totalContentsSize())
    }

    mutating func rubberBandingStateChanged(_ isRubberBanding: Bool) {
        let node = self.node()
        if scrollingTree().get().scrollingPerformanceTestingEnabled() {
            let stretch = stretchAmount()
            emitRubberBandSignpost(isRubberBanding, stretch, node.nodeType() == .MainFrame)
        }

        scrollingTree().get().setRubberBandingInProgressForNode(node.scrollingNodeID(), isRubberBanding)
        if !isRubberBanding {
            node.setRestoredRubberbandingInProgress(false)
        }
    }

    mutating func rubberBandTargetOffset() -> WebCore.FloatSize {
        // NSRefreshController will only affect the rubberbanding of the main frame.
        if node().nodeType() == .MainFrame {
            let topOffset = scrollingTree().get().topScrollStretchForRefreshController()
            if topOffset != 0 {
                return WebCore.FloatSize(0, -topOffset)
            }
        }
        return WebCore.FloatSize()
    }

    mutating func hasRefreshController() -> Bool {
        if node().nodeType() != .MainFrame {
            return false
        }
        return scrollingTree().get().hasRefreshController()
    }

    mutating func refreshControllerSnappingThreshold() -> Float {
        if node().nodeType() != .MainFrame {
            return 0
        }
        return scrollingTree().get().refreshControllerSnappingThreshold()
    }

    // The scrolling node ID is the identifier: the deferral comes from this node's controller.
    mutating func deferWheelEventTestCompletion(_ reason: WebCore.WheelEventTestMonitorDeferReason) {
        let tree = scrollingTree().get()
        if !tree.isMonitoringWheelEvents() {
            return
        }
        tree.deferWheelEventTestCompletionForReason(node().scrollingNodeID(), reason)
    }

    mutating func removeWheelEventTestCompletionDeferral(_ reason: WebCore.WheelEventTestMonitorDeferReason) {
        let tree = scrollingTree().get()
        if !tree.isMonitoringWheelEvents() {
            return
        }
        tree.removeWheelEventTestCompletionDeferralForReason(node().scrollingNodeID(), reason)
    }

    // ScrollableArea::scrollOffsetFromPosition() of the current scroll position.
    mutating func scrollOffset() -> WebCore.FloatPoint {
        node().currentScrollOffset()
    }

    mutating func willStartAnimatedScroll() {
        node().willStartAnimatedScroll()
    }

    mutating func didStopAnimatedScroll() {
        node().didStopAnimatedScroll()
    }

    mutating func willStartWheelEventScroll() {
        node().willStartWheelEventScroll()
    }

    mutating func didStopWheelEventScroll() {
        node().didStopWheelEventScroll()
    }

    mutating func willStartScrollSnapAnimation() {
        node().setScrollSnapInProgress(true)
    }

    mutating func didStopScrollSnapAnimation() {
        node().setScrollSnapInProgress(false)
        didStopAnimatedScroll()
    }

    // FIXME: What should this return for non-root frames, and overflow?
    mutating func pageScaleFactor() -> Float {
        if let frameNode = frameNode() {
            return frameNode.frameScaleFactor()
        }
        return 1
    }

    mutating func scrollExtents() -> WebCore.ScrollExtents {
        let node = self.node()
        // scrollableAreaSize() is the frame view's visibleSize(), which has the delegated page scale divided out
        // of it. Put it back to get the snapport the snap offsets were computed in.
        var snapportSize = node.scrollableAreaSize()
        if let frameNode = frameNode() {
            snapportSize.scale(frameNode.delegatedPageScaleFactor())
        }

        var extents = WebCore.ScrollExtents()
        extents.contentsSize = node.totalContentsSize()
        extents.viewportSize = node.scrollableAreaSize()
        extents.snapportSize = snapportSize
        return extents
    }
}

// IntSize::setWidth() and setHeight() of a float: toward zero, saturating at the int range, and 0 for NaN, where the
// C++ conversion is undefined.
private func intSizeComponent(_ value: Float) -> Int32 {
    if value.isNaN {
        return 0
    }
    if value >= Float(Int32.max) {
        return .max
    }
    if value <= Float(Int32.min) {
        return .min
    }
    return Int32(value)
}
