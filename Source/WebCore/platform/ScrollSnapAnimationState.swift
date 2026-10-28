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

// ScrollingEffectsController's scroll snap state: which snap offset is active in each axis, which box is
// snapped, and the snap and glide animations. The snap offsets are copied out of the controller's
// LayoutScrollSnapOffsetsInfo when it is set; closestSnapOffset() is the C++ one, run on that info.

internal import WebCore_Private.Core.ScrollExtents
internal import WebCore_Private.Core.ScrollSnapOffsetsInfo
internal import WebCore_Private.ScrollPhysicsTypes

// A NodeIdentifier's value; 0 is the empty Markable<NodeIdentifier>.
typealias SnapNodeID = UInt64

// SnapOffset<LayoutUnit>, with the offset as LayoutUnit's raw value.
struct SnapOffsetValue {
    var offset: Int32
    var isFocused: Bool
    var isTarget: Bool
    var snapTargetID: SnapNodeID
    var snapAreaIndices: [UInt]
}

// LayoutRect, as LayoutUnit raw values.
struct SnapAreaRect: Equatable {
    var x: Int32
    var y: Int32
    var width: Int32
    var height: Int32

    init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var maxX: Int32 { layoutUnitSum(x, width) }
    var maxY: Int32 { layoutUnitSum(y, height) }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    // LayoutRect::contains(const LayoutRect&).
    func contains(_ other: SnapAreaRect) -> Bool {
        x <= other.x && maxX >= other.maxX && y <= other.y && maxY >= other.maxY
    }

    // LayoutRect::intersects().
    func intersects(_ other: SnapAreaRect) -> Bool {
        !isEmpty && !other.isEmpty && x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }
}

// HashSet<NodeIdentifier>, which crashes when given the empty or the deleted identifier.
struct SnapNodeIDSet {
    private var identifiers = Set<SnapNodeID>()

    init() {}

    mutating func add(_ identifier: SnapNodeID) {
        precondition(identifier != 0 && identifier != SnapNodeID.max)
        identifiers.insert(identifier)
    }

    func contains(_ identifier: SnapNodeID) -> Bool {
        precondition(identifier != 0 && identifier != SnapNodeID.max)
        return identifiers.contains(identifier)
    }
}

// What the scroll snap destination modifier of a momentum animation needs.
struct ScrollSnapModifierInput {
    var extents: ScrollPhysicsExtents
    var pageScale: Float
    var initialOffset: ScrollPoint
    var initialDelta: ScrollSize
}

private func otherAxis(_ axis: WebCore.ScrollEventAxis) -> WebCore.ScrollEventAxis {
    axis == .Horizontal ? .Vertical : .Horizontal
}

private func valueForAxis(_ point: ScrollPoint, _ axis: WebCore.ScrollEventAxis) -> Float {
    axis == .Horizontal ? point.x : point.y
}

final class ScrollSnapAnimationState {
    enum State {
        case snapping
        case gliding
        case destinationReached
        case userInteraction
    }

    private enum Flag {
        case isFocused
        case isTarget
    }

    private(set) var currentState = State.userInteraction

    private var horizontalSnapOffsets: [SnapOffsetValue] = []
    private var verticalSnapOffsets: [SnapOffsetValue] = []
    private var snapAreas: [SnapAreaRect] = []
    private var snapAreasIDs: [SnapNodeID] = []
    private var scrollerHasVerticalWritingMode = false

    private var activeSnapIndexX: UInt32?
    private var activeSnapIndexY: UInt32?
    private var currentlySnappedBoxes = SnapNodeIDSet()
    private var currentSnapTargetForHorizontalAxis: SnapNodeID = 0
    private var currentSnapTargetForVerticalAxis: SnapNodeID = 0

    // The focused/targeted box seen at the last re-snap, per axis, so we can tell a focus/:target
    // change (a snap-target selection trigger) apart from a pure layout change.
    private var lastFocusedOrTargetedNodeX: SnapNodeID = 0
    private var lastFocusedOrTargetedNodeY: SnapNodeID = 0

    // Scroll offset and viewport size from the last snap/re-snap, for cross-axis
    // visibility checks.
    private var lastLayoutScrollOffsetX: Int32 = 0
    private var lastLayoutScrollOffsetY: Int32 = 0
    private var lastViewportWidth: Int32 = 0
    private var lastViewportHeight: Int32 = 0

    init<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        readSnapOffsetsInfo(&c)
    }

    func setSnapOffsetInfo<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        readSnapOffsetsInfo(&c)
    }

    private func readSnapOffsetsInfo<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        horizontalSnapOffsets = snapOffsetValues(&c, .Horizontal)
        verticalSnapOffsets = snapOffsetValues(&c, .Vertical)

        var areas: [SnapAreaRect] = []
        let areaCount = c.snapAreaCount()
        areas.reserveCapacity(Int(areaCount))
        for index in 0..<areaCount {
            let area = c.snapArea(index)
            areas.append(
                SnapAreaRect(
                    x: area.x().rawValue(),
                    y: area.y().rawValue(),
                    width: area.width().rawValue(),
                    height: area.height().rawValue()
                )
            )
        }
        snapAreas = areas

        var areaIDs: [SnapNodeID] = []
        let areaIDCount = c.snapAreaIDCount()
        areaIDs.reserveCapacity(Int(areaIDCount))
        for index in 0..<areaIDCount {
            areaIDs.append(c.snapAreaID(index))
        }
        snapAreasIDs = areaIDs

        scrollerHasVerticalWritingMode = c.scrollerHasVerticalWritingMode()
    }

    private func snapOffsetValues<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ axis: WebCore.ScrollEventAxis
    ) -> [SnapOffsetValue] {
        let count = c.snapOffsetCount(axis)
        var values: [SnapOffsetValue] = []
        values.reserveCapacity(Int(count))
        for index in 0..<count {
            let areaIndexCount = c.snapOffsetAreaIndexCount(axis, index)
            var areaIndices: [UInt] = []
            areaIndices.reserveCapacity(Int(areaIndexCount))
            for areaIndex in 0..<areaIndexCount {
                areaIndices.append(UInt(c.snapOffsetAreaIndex(axis, index, areaIndex)))
            }
            values.append(
                SnapOffsetValue(
                    offset: c.snapOffset(axis, index).rawValue(),
                    isFocused: c.snapOffsetIsFocused(axis, index),
                    isTarget: c.snapOffsetIsTarget(axis, index),
                    snapTargetID: c.snapOffsetTargetID(axis, index),
                    snapAreaIndices: areaIndices
                )
            )
        }
        return values
    }

    func hasSnapOffsets(_ axis: WebCore.ScrollEventAxis) -> Bool {
        axis == .Horizontal ? !horizontalSnapOffsets.isEmpty : !verticalSnapOffsets.isEmpty
    }

    private func snapOffsetCount(_ axis: WebCore.ScrollEventAxis) -> Int {
        axis == .Horizontal ? horizontalSnapOffsets.count : verticalSnapOffsets.count
    }

    private func snapOffset(_ axis: WebCore.ScrollEventAxis, _ index: Int) -> SnapOffsetValue {
        axis == .Horizontal ? horizontalSnapOffsets[index] : verticalSnapOffsets[index]
    }

    private var blockAxis: WebCore.ScrollEventAxis {
        scrollerHasVerticalWritingMode ? .Horizontal : .Vertical
    }

    func activeSnapIndexForAxis(_ axis: WebCore.ScrollEventAxis) -> UInt32? {
        axis == .Horizontal ? activeSnapIndexX : activeSnapIndexY
    }

    func setActiveSnapIndexForAxis(_ axis: WebCore.ScrollEventAxis, _ index: UInt32?) {
        setActiveSnapIndexForAxisInternal(axis, index)
        updateCurrentlySnappedBoxes()
    }

    private func setActiveSnapIndexForAxisInternal(_ axis: WebCore.ScrollEventAxis, _ index: UInt32?) {
        if axis == .Horizontal {
            activeSnapIndexX = index
        } else {
            activeSnapIndexY = index
        }
    }

    // MARK: Animations

    // These return true if they start a new animation.
    func transitionToSnapAnimationState<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ extents: ScrollPhysicsExtents,
        _ pageScale: Float,
        _ initialOffset: ScrollPoint
    ) -> Bool {
        setupAnimationForState(&c, controller, .snapping, extents, pageScale, initialOffset, .zero, .zero)
    }

    func transitionToGlideAnimationState<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ extents: ScrollPhysicsExtents,
        _ pageScale: Float,
        _ initialOffset: ScrollPoint,
        _ initialVelocity: ScrollSize,
        _ initialDelta: ScrollSize
    ) -> Bool {
        setupAnimationForState(&c, controller, .gliding, extents, pageScale, initialOffset, initialVelocity, initialDelta)
    }

    private func setupAnimationForState<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ state: State,
        _ extents: ScrollPhysicsExtents,
        _ pageScale: Float,
        _ initialOffset: ScrollPoint,
        _ initialVelocity: ScrollSize,
        _ initialDelta: ScrollSize
    ) -> Bool {
        if currentState == state {
            return false
        }

        let input = ScrollSnapModifierInput(
            extents: extents,
            pageScale: pageScale,
            initialOffset: initialOffset,
            initialDelta: initialDelta
        )
        let animating = controller.startMomentumScroll(&c, initialOffset, initialVelocity, initialDelta, self, input)

        if !animating {
            return false
        }

        currentState = state
        return animating
    }

    // The momentum animation's destination modifier: the snap offset in each axis, which also becomes
    // the active snap index.
    func modifiedDestination<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ input: ScrollSnapModifierInput,
        _ targetOffset: ScrollPoint
    ) -> ScrollPoint {
        let (targetOffsetX, indexX) = targetOffsetForStartOffset(
            &c,
            .Horizontal,
            input.extents,
            input.initialOffset.x,
            targetOffset,
            input.pageScale,
            input.initialDelta.width
        )
        activeSnapIndexX = indexX
        let (targetOffsetY, indexY) = targetOffsetForStartOffset(
            &c,
            .Vertical,
            input.extents,
            input.initialOffset.y,
            targetOffset,
            input.pageScale,
            input.initialDelta.height
        )
        activeSnapIndexY = indexY
        return ScrollPoint(x: targetOffsetX, y: targetOffsetY)
    }

    func transitionToUserInteractionState<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ controller: ScrollPhysicsController) {
        teardownAnimationForState(&c, controller, .userInteraction)
    }

    func transitionToDestinationReachedState<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController
    ) {
        teardownAnimationForState(&c, controller, .destinationReached)
    }

    private func teardownAnimationForState<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ state: State
    ) {
        if currentState == state {
            return
        }

        controller.stopAnimatedScroll(&c)
        currentState = state
    }

    // MARK: Snap offsets

    private func closestSnapOffset<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ axis: WebCore.ScrollEventAxis,
        _ viewportSize: ScrollSize,
        _ scrollDestinationOffset: ScrollPoint,
        _ velocity: Float,
        _ originalPosition: Float?,
        _ selectionMethod: WebCore.ScrollSnapPointSelectionMethod ) -> (offset: Int32,
        index: UInt32?
    ) {
        let layoutViewportSize = WebCore.LayoutSize(viewportSize.floatSize)
        let layoutDestinationOffset = WebCore.LayoutPoint(scrollDestinationOffset.floatPoint)
        let result = c.closestSnapOffset(
            axis,
            layoutViewportSize,
            layoutDestinationOffset,
            velocity,
            originalPosition != nil,
            originalPosition ?? 0,
            selectionMethod
        )
        return (result.first.rawValue(), Optional(fromCxx: result.second))
    }

    private func closestSnapPointForOffset<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ axis: WebCore.ScrollEventAxis,
        _ scrollOffset: ScrollIntPoint,
        _ extents: ScrollPhysicsExtents,
        _ pageScale: Float
    ) -> UInt32? {
        let layoutScrollOffset = ScrollPoint(x: Float(scrollOffset.x) / pageScale, y: Float(scrollOffset.y) / pageScale)

        var activeIndex: UInt32?
        if hasSnapOffsets(axis) {
            activeIndex = closestSnapOffset(&c, axis, extents.snapportSize, layoutScrollOffset, 0, nil, .Closest).index
        }

        return activeIndex
    }

    func adjustedScrollDestination<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ axis: WebCore.ScrollEventAxis,
        _ destinationOffset: ScrollPoint,
        _ velocity: Float,
        _ originalOffset: Float?,
        _ extents: ScrollPhysicsExtents,
        _ pageScale: Float,
        _ selectionMethod: WebCore.ScrollSnapPointSelectionMethod
    ) -> Float {
        if !hasSnapOffsets(axis) {
            return valueForAxis(destinationOffset, axis)
        }

        let originalOffsetInLayoutUnits = originalOffset.map { $0 / pageScale }

        // Clamp the destination to the reachable scroll range before choosing a snap offset.
        let minScrollOffset = valueForAxis(extents.minimumScrollOffset, axis)
        let maxScrollOffset = valueForAxis(extents.maximumScrollOffset, axis)
        var destination = destinationOffset
        if axis == .Horizontal {
            destination.x = clampTo(destination.x, minScrollOffset, maxScrollOffset)
        } else {
            destination.y = clampTo(destination.y, minScrollOffset, maxScrollOffset)
        }

        let layoutDestinationOffset = ScrollPoint(x: destination.x / pageScale, y: destination.y / pageScale)
        let offset = closestSnapOffset(
            &c,
            axis,
            extents.snapportSize,
            layoutDestinationOffset,
            velocity,
            originalOffsetInLayoutUnits,
            selectionMethod
        )
        .offset
        return layoutUnitToFloat(offset) * pageScale
    }

    // The snap offset nodeID contributes to in this axis, plus nodeID's own area at that offset: a box can
    // be any of the areas sharing an offset, not just its representative snapTargetID, so we find both here.
    private func snapOffsetAndAreaIndicesForNode(
        _ axis: WebCore.ScrollEventAxis,
        _ nodeID: SnapNodeID
    ) -> (offsetIndex: Int, areaIndex: UInt?)? {
        for offsetIndex in 0..<snapOffsetCount(axis) {
            let offset = snapOffset(axis, offsetIndex)
            for areaIndex in offset.snapAreaIndices {
                if areaIndex < UInt(snapAreasIDs.count) && snapAreasIDs[Int(areaIndex)] == nodeID {
                    return (offsetIndex, areaIndex)
                }
            }
            if offset.snapTargetID != 0 && offset.snapTargetID == nodeID {
                return (offsetIndex, nil)
            }
        }
        return nil
    }

    // Returns the index of the snap offset that nodeID contributes to, if any.
    private func snapOffsetIndexForNode(_ axis: WebCore.ScrollEventAxis, _ nodeID: SnapNodeID) -> UInt32? {
        guard let indices = snapOffsetAndAreaIndicesForNode(axis, nodeID) else {
            return nil
        }
        return UInt32(truncatingIfNeeded: indices.offsetIndex)
    }

    // Returns whether the snap point is changed or not
    private func preserveCurrentTargetForAxis(_ axis: WebCore.ScrollEventAxis, _ nodeID: SnapNodeID) -> Bool {
        guard let index = snapOffsetIndexForNode(axis, nodeID) else {
            setActiveSnapIndexForAxis(axis, nil)
            return false
        }

        setActiveSnapIndexForAxis(axis, index)
        return true
    }

    // The first box among this axis's snap offsets carrying flag as the offset's representative target and
    // accepted by isEligible; callers ask for isFocused before isTarget to get the spec's preference order.
    private func flaggedNodeForAxis(
        _ axis: WebCore.ScrollEventAxis,
        _ flag: Flag,
        _ isEligible: (SnapOffsetValue) -> Bool = { _ in true }
    ) -> SnapNodeID {
        for index in 0..<snapOffsetCount(axis) {
            let offset = snapOffset(axis, index)
            let isFlagged = flag == .isFocused ? offset.isFocused : offset.isTarget
            if isFlagged && offset.snapTargetID != 0 && isEligible(offset) {
                return offset.snapTargetID
            }
        }
        return 0
    }

    // The focused (then fragment-targeted) box among all of this axis's snap offsets, evaluated fresh so
    // a focus/:target change can be detected. Unlike focusedOrTargetedBox() this is not restricted to the
    // currently-snapped boxes and does not apply the cross-axis visibility filter: it is only a change
    // signal, not a selection.
    private func focusedOrTargetedNodeForAxis(_ axis: WebCore.ScrollEventAxis) -> SnapNodeID {
        let box = flaggedNodeForAxis(axis, .isFocused)
        if box != 0 {
            return box
        }
        return flaggedNodeForAxis(axis, .isTarget)
    }

    private func currentlySnappedOffsetForAxis(_ axis: WebCore.ScrollEventAxis) -> SnapOffsetValue? {
        guard let activeIndex = activeSnapIndexForAxis(axis), Int(activeIndex) < snapOffsetCount(axis) else {
            return nil
        }
        return snapOffset(axis, Int(activeIndex))
    }

    private func currentlySnappedBoxes(_ horizontalOffset: SnapOffsetValue?, _ verticalOffset: SnapOffsetValue?) -> SnapNodeIDSet {
        var snappedNodeIDs = SnapNodeIDSet()

        func addBoxes(_ offset: SnapOffsetValue?) {
            guard let offset, offset.snapTargetID != 0 else {
                return
            }
            snappedNodeIDs.add(offset.snapTargetID)
            for index in offset.snapAreaIndices {
                snappedNodeIDs.add(snapAreasIDs[Int(index)])
            }
        }
        addBoxes(horizontalOffset)
        addBoxes(verticalOffset)
        return snappedNodeIDs
    }

    // Selects this axis's snap target among the boxes aligned at the active offset, per
    // https://drafts.csswg.org/css-scroll-snap/#multiple-aligned-snap-areas: focused, then targeted,
    // then innermost (ancestors removed), then the area aligned in both axes (the block/inline set
    // intersection), then first in tree order. snapTargetID is the focused/targeted representative; this
    // adds the innermost and common-to-both-axes steps.
    private func selectSnapTargetForAxis(_ axis: WebCore.ScrollEventAxis) -> SnapNodeID {
        guard let offset = currentlySnappedOffsetForAxis(axis) else {
            return 0
        }

        // A focused or fragment-targeted box wins outright, unless its area is scrolled out of the
        // snapport in a non-snapping cross axis (not a valid snap position).
        if (offset.isFocused || offset.isTarget) && offset.snapTargetID != 0 {
            var representativeAreaIsVisible = true
            for areaIndex in offset.snapAreaIndices
            where areaIndex < UInt(snapAreasIDs.count) && snapAreasIDs[Int(areaIndex)] == offset.snapTargetID {
                representativeAreaIsVisible = isSnapAreaVisibleInCrossAxis(areaIndex, axis)
                break
            }
            if representativeAreaIsVisible {
                return offset.snapTargetID
            }
        }

        // Candidate boxes after removing any area that encloses another aligned area (its ancestors), so
        // a nested area supersedes a co-located ancestor, including an ancestor aligned in both axes.
        var firstCandidateIndex: UInt?
        forEachInnermostAlignedAreaIndex(axis) { areaIndex in
            firstCandidateIndex = areaIndex
            return false
        }
        guard let firstCandidateIndex else {
            return offset.snapTargetID
        }

        // If the block and inline candidate sets overlap, both axes snap to the box common to both.
        // snapAreaIndices are in ascending tree order, so iterating this axis's candidates and taking the
        // first also present in the other axis's candidates yields the first-in-tree box of the
        // intersection, which is the same box for both axes.
        var otherAxisIDs = SnapNodeIDSet()
        var hasOtherCandidates = false
        forEachInnermostAlignedAreaIndex(otherAxis(axis)) { areaIndex in
            otherAxisIDs.add(snapAreasIDs[Int(areaIndex)])
            hasOtherCandidates = true
            return true
        }
        if hasOtherCandidates {
            var commonID: SnapNodeID?
            forEachInnermostAlignedAreaIndex(axis) { areaIndex in
                if otherAxisIDs.contains(snapAreasIDs[Int(areaIndex)]) {
                    commonID = snapAreasIDs[Int(areaIndex)]
                    return false
                }
                return true
            }
            if let commonID {
                return commonID
            }
        }

        // Otherwise, the first in tree order.
        return snapAreasIDs[Int(firstCandidateIndex)]
    }

    // Calls body with each snap area aligned at this axis's active offset, minus any area that encloses another
    // aligned area (an ancestor), in tree order, until body returns false. This is the per-axis candidate list
    // from https://drafts.csswg.org/css-scroll-snap/#multiple-aligned-snap-areas after ancestor removal.
    private func forEachInnermostAlignedAreaIndex(_ axis: WebCore.ScrollEventAxis, _ body: (UInt) -> Bool) {
        guard let offset = currentlySnappedOffsetForAxis(axis) else {
            return
        }

        let indices = offset.snapAreaIndices
        let areaCount = UInt(snapAreas.count)

        func enclosesAnotherArea(_ areaIndex: UInt) -> Bool {
            indices.contains { other in
                other != areaIndex && other < areaCount
                    && snapAreas[Int(areaIndex)] != snapAreas[Int(other)] && snapAreas[Int(areaIndex)].contains(snapAreas[Int(other)])
            }
        }

        for areaIndex in indices
        where areaIndex < areaCount && areaIndex < UInt(snapAreasIDs.count) && isSnapAreaVisibleInCrossAxis(areaIndex, axis)
            && !enclosesAnotherArea(areaIndex)
        {
            if !body(areaIndex) {
                return
            }
        }
    }

    private func updateCurrentlySnappedBoxes() {
        let horizontalOffset = currentlySnappedOffsetForAxis(.Horizontal)
        let verticalOffset = currentlySnappedOffsetForAxis(.Vertical)

        currentlySnappedBoxes = currentlySnappedBoxes(horizontalOffset, verticalOffset)
        currentSnapTargetForHorizontalAxis = selectSnapTargetForAxis(.Horizontal)
        currentSnapTargetForVerticalAxis = selectSnapTargetForAxis(.Vertical)
    }

    // True if the snap area is at least partly within the snapport in the (non-snapping) cross axis at
    // the last known scroll position. When the cross axis also snaps (2D case, handled by
    // closestSnapOffset) or no viewport is known yet, we don't filter. Mirrors findCompatibleSnapArea().
    private func isSnapAreaVisibleInCrossAxis(_ areaIndex: UInt, _ axis: WebCore.ScrollEventAxis) -> Bool {
        let crossAxis = otherAxis(axis)
        if hasSnapOffsets(crossAxis) || lastViewportWidth <= 0 || lastViewportHeight <= 0 {
            return true
        }
        if areaIndex >= UInt(snapAreas.count) {
            return true
        }

        let area = snapAreas[Int(areaIndex)]
        let crossMin = crossAxis == .Horizontal ? area.x : area.y
        let crossMax = crossAxis == .Horizontal ? area.maxX : area.maxY
        let crossScroll = crossAxis == .Horizontal ? lastLayoutScrollOffsetX : lastLayoutScrollOffsetY
        let crossViewport = crossAxis == .Horizontal ? lastViewportWidth : lastViewportHeight
        return layoutUnitSum(crossScroll, crossViewport) >= crossMin && crossScroll <= crossMax
    }

    // This axis's focused/targeted snapped box, evaluated fresh (focus and :target can change after the
    // snap). A focused/targeted area scrolled out of the snapport in a non-snapping cross axis is skipped:
    // it isn't a valid snap position, so it must not win the preference.
    private func focusedOrTargetedBox(_ axis: WebCore.ScrollEventAxis, _ snappedBoxes: SnapNodeIDSet) -> SnapNodeID? {
        let isEligible = { (offset: SnapOffsetValue) -> Bool in
            if !snappedBoxes.contains(offset.snapTargetID) {
                return false
            }
            for areaIndex in offset.snapAreaIndices
            where areaIndex < UInt(self.snapAreasIDs.count) && self.snapAreasIDs[Int(areaIndex)] == offset.snapTargetID {
                return self.isSnapAreaVisibleInCrossAxis(areaIndex, axis)
            }
            return true
        }

        let focused = flaggedNodeForAxis(axis, .isFocused, isEligible)
        if focused != 0 {
            return focused
        }
        let targeted = flaggedNodeForAxis(axis, .isTarget, isEligible)
        if targeted != 0 {
            return targeted
        }
        return nil
    }

    // The snap area rect (scroll-offset space) and this axis's snap offset for the area contributed by
    // nodeID, if it establishes an offset in this axis. The rect lets us test whether both axes' boxes coexist.
    private func snapAreaAndOffsetForNode(_ axis: WebCore.ScrollEventAxis, _ nodeID: SnapNodeID) -> (area: SnapAreaRect, offset: Int32)? {
        guard let indices = snapOffsetAndAreaIndicesForNode(axis, nodeID), let areaIndex = indices.areaIndex,
            areaIndex < UInt(snapAreas.count)
        else {
            return nil
        }

        return (snapAreas[Int(areaIndex)], snapOffset(axis, indices.offsetIndex).offset)
    }

    // Per https://drafts.csswg.org/css-scroll-snap/#re-snap, when the two axes pick different boxes that
    // can't both be snapped (snapping one pushes the other offscreen), collapse to one: focused, then
    // targeted, then the block-axis box. Returns nil when both boxes can be snapped simultaneously.
    private func resolvePreferredBoxForAxisConflict(_ horizontalBox: SnapNodeID, _ verticalBox: SnapNodeID) -> SnapNodeID? {
        if horizontalBox == verticalBox {
            return nil
        }

        let horizontal = snapAreaAndOffsetForNode(.Horizontal, horizontalBox)
        let vertical = snapAreaAndOffsetForNode(.Vertical, verticalBox)
        guard let horizontal, let vertical else {
            return nil
        }

        if lastViewportWidth <= 0 || lastViewportHeight <= 0 {
            return nil
        }

        // Both boxes can be snapped only if both areas still intersect the snapport at the combined
        // position (the x that aligns the H box, the y that aligns the V box); else it's a conflict.
        let snapport = SnapAreaRect(x: horizontal.offset, y: vertical.offset, width: lastViewportWidth, height: lastViewportHeight)
        if horizontal.area.intersects(snapport) && vertical.area.intersects(snapport) {
            return nil
        }

        // Conflict: prefer focused, then targeted, then the block-axis box.
        let isConflictingBox = { (offset: SnapOffsetValue) -> Bool in
            offset.snapTargetID == horizontalBox || offset.snapTargetID == verticalBox
        }
        for flag in [Flag.isFocused, Flag.isTarget] {
            for axis in [WebCore.ScrollEventAxis.Horizontal, WebCore.ScrollEventAxis.Vertical] {
                let box = flaggedNodeForAxis(axis, flag, isConflictingBox)
                if box != 0 {
                    return box
                }
            }
        }

        return blockAxis == .Horizontal ? horizontalBox : verticalBox
    }

    private func setLastLayoutScrollOffsetAndViewport(_ scrollOffset: ScrollIntPoint, _ extents: ScrollPhysicsExtents, _ pageScale: Float) {
        lastLayoutScrollOffsetX = layoutUnitRawValue(Float(scrollOffset.x) / pageScale)
        lastLayoutScrollOffsetY = layoutUnitRawValue(Float(scrollOffset.y) / pageScale)
        lastViewportWidth = layoutUnitRawValue(extents.snapportSize.width)
        lastViewportHeight = layoutUnitRawValue(extents.snapportSize.height)
    }

    // Returns true if an active snap index changed.
    func resnapAfterLayout<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ scrollOffset: ScrollIntPoint,
        _ extents: ScrollPhysicsExtents,
        _ pageScale: Float
    ) -> Bool {
        setLastLayoutScrollOffsetAndViewport(scrollOffset, extents, pageScale)

        let activeHorizontalIndex = activeSnapIndexForAxis(.Horizontal)
        let activeVerticalIndex = activeSnapIndexForAxis(.Vertical)

        let previouslySnappedBoxes = currentlySnappedBoxes
        currentlySnappedBoxes = SnapNodeIDSet()
        let previousSnapTargetForHorizontalAxis = currentSnapTargetForHorizontalAxis
        currentSnapTargetForHorizontalAxis = 0
        let previousSnapTargetForVerticalAxis = currentSnapTargetForVerticalAxis
        currentSnapTargetForVerticalAxis = 0

        let currentFocusedOrTargetedNodeX = focusedOrTargetedNodeForAxis(.Horizontal)
        let currentFocusedOrTargetedNodeY = focusedOrTargetedNodeForAxis(.Vertical)
        let focusOrTargetChangedX = currentFocusedOrTargetedNodeX != lastFocusedOrTargetedNodeX
        lastFocusedOrTargetedNodeX = currentFocusedOrTargetedNodeX
        let focusOrTargetChangedY = currentFocusedOrTargetedNodeY != lastFocusedOrTargetedNodeY
        lastFocusedOrTargetedNodeY = currentFocusedOrTargetedNodeY

        var snapPointChanged = false
        // Check if we need to set the current indices
        if activeVerticalIndex == nil || Int(activeVerticalIndex!) >= verticalSnapOffsets.count {
            let changed = setNearestScrollSnapIndexForAxisAndOffsetInternal(&c, .Vertical, scrollOffset, extents, pageScale)
            snapPointChanged = snapPointChanged || changed
        }
        if activeHorizontalIndex == nil || Int(activeHorizontalIndex!) >= horizontalSnapOffsets.count {
            let changed = setNearestScrollSnapIndexForAxisAndOffsetInternal(&c, .Horizontal, scrollOffset, extents, pageScale)
            snapPointChanged = snapPointChanged || changed
        }

        updateCurrentlySnappedBoxes()

        // Re-snap each axis independently to its selected box, following it to its post-layout offset.
        // When the focus/:target changed we honor that new preference among the previously-snapped boxes;
        // otherwise we keep the box recorded before the layout change (focused/targeted / innermost /
        // first-in-tree). Per-axis selection keeps a box tied only in the other axis from dragging this
        // axis off its snap position.
        func targetForAxis(_ axis: WebCore.ScrollEventAxis, _ recordedTarget: SnapNodeID, _ focusOrTargetChanged: Bool) -> SnapNodeID? {
            if focusOrTargetChanged {
                if let box = focusedOrTargetedBox(axis, previouslySnappedBoxes) {
                    return box
                }
            }
            // Keep the recorded target only if it is still a snap target for this axis; otherwise fall
            // through so the nearest-offset selection made above stands.
            if recordedTarget != 0 && snapOffsetIndexForNode(axis, recordedTarget) != nil {
                return recordedTarget
            }
            return nil
        }

        var targetForHorizontalAxis = targetForAxis(.Horizontal, previousSnapTargetForHorizontalAxis, focusOrTargetChangedX)
        var targetForVerticalAxis = targetForAxis(.Vertical, previousSnapTargetForVerticalAxis, focusOrTargetChangedY)

        // "prefer block axis": if the two axes' boxes conflict, collapse both onto the one box.
        if let horizontalTarget = targetForHorizontalAxis, let verticalTarget = targetForVerticalAxis {
            if let preferredBox = resolvePreferredBoxForAxisConflict(horizontalTarget, verticalTarget) {
                targetForHorizontalAxis = preferredBox
                targetForVerticalAxis = preferredBox
            }
        }

        if let targetForHorizontalAxis {
            let changed = preserveCurrentTargetForAxis(.Horizontal, targetForHorizontalAxis)
            snapPointChanged = snapPointChanged || changed
        }
        if let targetForVerticalAxis {
            let changed = preserveCurrentTargetForAxis(.Vertical, targetForVerticalAxis)
            snapPointChanged = snapPointChanged || changed
        }

        updateCurrentlySnappedBoxes()

        // Keep the box we actually followed as this axis's recorded target. updateCurrentlySnappedBoxes()
        // re-runs selection, which could pick a different aligned box (first-in-tree, or one that is now
        // common to both axes) and cause the scroller to abandon its tracked target on a later layout
        // change. The followed box is authoritative, so restore it when it is still snapped.
        if let targetForHorizontalAxis, currentlySnappedBoxes.contains(targetForHorizontalAxis) {
            currentSnapTargetForHorizontalAxis = targetForHorizontalAxis
        }
        if let targetForVerticalAxis, currentlySnappedBoxes.contains(targetForVerticalAxis) {
            currentSnapTargetForVerticalAxis = targetForVerticalAxis
        }

        return snapPointChanged
    }

    private func setNearestScrollSnapIndexForAxisAndOffsetInternal<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ axis: WebCore.ScrollEventAxis,
        _ scrollOffset: ScrollIntPoint,
        _ extents: ScrollPhysicsExtents,
        _ pageScale: Float
    ) -> Bool {
        let activeIndex = closestSnapPointForOffset(&c, axis, scrollOffset, extents, pageScale)
        if activeIndex == activeSnapIndexForAxis(axis) {
            return false
        }

        setActiveSnapIndexForAxisInternal(axis, activeIndex)
        return true
    }

    func setNearestScrollSnapIndexForOffset<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ scrollOffset: ScrollIntPoint,
        _ extents: ScrollPhysicsExtents,
        _ pageScale: Float
    ) -> Bool {
        var snapIndexChanged = false
        setLastLayoutScrollOffsetAndViewport(scrollOffset, extents, pageScale)
        let horizontalChanged = setNearestScrollSnapIndexForAxisAndOffsetInternal(&c, .Horizontal, scrollOffset, extents, pageScale)
        snapIndexChanged = snapIndexChanged || horizontalChanged
        let verticalChanged = setNearestScrollSnapIndexForAxisAndOffsetInternal(&c, .Vertical, scrollOffset, extents, pageScale)
        snapIndexChanged = snapIndexChanged || verticalChanged

        updateCurrentlySnappedBoxes()

        return snapIndexChanged
    }

    // The target is rounded to a LayoutUnit before it is returned.
    private func targetOffsetForStartOffset<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ axis: WebCore.ScrollEventAxis,
        _ extents: ScrollPhysicsExtents,
        _ startOffset: Float,
        _ predictedOffset: ScrollPoint,
        _ pageScale: Float,
        _ initialDelta: Float ) -> (Float,
        UInt32?
    ) {
        let minScrollOffset = valueForAxis(extents.minimumScrollOffset, axis)
        let maxScrollOffset = valueForAxis(extents.maximumScrollOffset, axis)

        if !hasSnapOffsets(axis) {
            return (clampTo(valueForAxis(predictedOffset, axis), minScrollOffset, maxScrollOffset), nil)
        }

        var predictedLayoutOffset = ScrollPoint(x: predictedOffset.x / pageScale, y: predictedOffset.y / pageScale)

        // Clamp the predicted destination to the reachable scroll range before choosing a snap offset.
        let clampedAxisOffset = clampTo(valueForAxis(predictedOffset, axis), minScrollOffset, maxScrollOffset) / pageScale
        if axis == .Horizontal {
            predictedLayoutOffset.x = clampedAxisOffset
        } else {
            predictedLayoutOffset.y = clampedAxisOffset
        }

        let (targetOffset, snapIndex) = closestSnapOffset(
            &c,
            axis,
            extents.snapportSize,
            predictedLayoutOffset,
            initialDelta,
            startOffset / pageScale,
            .Closest
        )
        let clampedTarget = layoutUnitRawValue(clampTo(layoutUnitToFloat(targetOffset), minScrollOffset, maxScrollOffset) * pageScale)
        return (layoutUnitToFloat(clampedTarget), snapIndex)
    }
}
