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

// ScrollableArea's non-virtual scrolling members on macOS. Each takes, inout, a ScrollAnimatorScrollPhysicsClient
// that its caller made on its own stack and does not store, so nothing else reaches it while the function runs;
// a call that scrolls again makes its own. Main thread only, except for the functions that take only values.

internal import WebCore_Private.Core.BoxSides
internal import WebCore_Private.Core.FloatPoint
internal import WebCore_Private.Core.FloatSize
internal import WebCore_Private.Core.IntPoint
internal import WebCore_Private.Core.KeyboardScroll
internal import WebCore_Private.Core.LayoutPoint
internal import WebCore_Private.Core.LayoutRect
internal import WebCore_Private.Core.LayoutSize
internal import WebCore_Private.Core.RectEdges
internal import WebCore_Private.Core.ScrollAlignment
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.ScrollAnimatorScrollPhysicsClient
internal import WebCore_Private.ScrollPhysicsTypes

// ScrollableArea::scrollOffsetFromPosition() and scrollPositionFromOffset() with the area's scroll origin. A sum or
// difference outside the int range wraps (IntPoint's int arithmetic, undefined on overflow).
func scrollableAreaScrollOffsetFromPosition(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ position: WebCore.IntPoint
) -> WebCore.IntPoint {
    let origin = c.scrollOrigin()
    return WebCore.IntPoint(position.x() &+ origin.x(), position.y() &+ origin.y())
}

func scrollableAreaScrollPositionFromOffset(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ offset: WebCore.IntPoint
) -> WebCore.IntPoint {
    let origin = c.scrollOrigin()
    return WebCore.IntPoint(offset.x() &- origin.x(), offset.y() &- origin.y())
}

// The same, for FloatPoint positions and offsets.
func scrollableAreaScrollOffsetFromPosition(_ c: inout WebCore.ScrollAnimatorScrollPhysicsClient, _ position: ScrollPoint) -> ScrollPoint {
    let origin = c.scrollOrigin()
    return position + ScrollSize(width: Float(origin.x()), height: Float(origin.y()))
}

func scrollableAreaScrollPositionFromOffset(_ c: inout WebCore.ScrollAnimatorScrollPhysicsClient, _ offset: ScrollPoint) -> ScrollPoint {
    let origin = c.scrollOrigin()
    return ScrollPoint(x: offset.x - Float(origin.x()), y: offset.y - Float(origin.y()))
}

// ScrollableArea::scroll(). While `c` is live this calls the area's horizontalScrollbar() or verticalScrollbar(), that
// scrollbar's step getters, adjustVerticalPageScrollStepForFixedContent() and the animator's singleAxisScroll().
@_expose(Cxx)
func scrollableAreaScroll(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ direction: WebCore.ScrollDirection,
    _ granularity: WebCore.ScrollGranularity,
    _ stepCount: CUnsignedInt
) -> Bool {
    let axis = WebCore.axisFromDirection(direction)
    let orientation: WebCore.ScrollbarOrientation = axis == .Horizontal ? .Horizontal : .Vertical
    // The scrollbar is fetched once and held until the scroll returns.
    guard c.protectScrollbar(orientation) else {
        return false
    }

    var step: Float = 0
    switch granularity {
    case .Line:
        step = Float(c.protectedScrollbarLineStep(orientation))
    case .Page:
        step = Float(c.protectedScrollbarPageStep(orientation))
    case .Document:
        step = Float(c.protectedScrollbarTotalSize(orientation))
    case .Pixel:
        step = c.protectedScrollbarPixelStep(orientation)
    @unknown default:
        break
    }

    if granularity == .Page && axis == .Vertical {
        step = c.adjustVerticalPageScrollStepForFixedContent(step)
    }

    var scrollDelta = step * Float(stepCount)
    if direction == .up || direction == .left {
        scrollDelta = -scrollDelta
    }

    let scrolled = c.animatorSingleAxisScroll(axis, scrollDelta, granularity == .Page, granularity == .Document)
    c.releaseProtectedScrollbar(orientation)
    return scrolled
}

// ScrollableArea::beginKeyboardScroll(). While `c` is live this calls requestStartKeyboardScrollAnimation() and
// setScrollAnimationStatus().
@_expose(Cxx)
func scrollableAreaBeginKeyboardScroll(_ c: inout WebCore.ScrollAnimatorScrollPhysicsClient, _ scroll: WebCore.KeyboardScroll) {
    if c.requestStartKeyboardScrollAnimation(scroll) {
        c.setScrollAnimationStatus(.Animating)
    }
}

// ScrollableArea::endKeyboardScroll(). While `c` is live this calls requestStopKeyboardScrollAnimation() and
// setScrollAnimationStatus().
@_expose(Cxx)
func scrollableAreaEndKeyboardScroll(_ c: inout WebCore.ScrollAnimatorScrollPhysicsClient, _ immediate: Bool) {
    if c.requestStopKeyboardScrollAnimation(immediate) {
        c.setScrollAnimationStatus(.NotAnimating)
    }
}

// ScrollableArea::scrollToPositionWithAnimation(), with the options it reads as separate arguments: Swift and the
// generated C++ header disagree on the registers that carry a ScrollPositionChangeOptions passed by value, so Swift
// would read its last two fields from the wrong place. While `c` is live this calls scrollAnimationStatus(),
// setScrollAnimationStatus(), scrollPosition(), requestScrollToPosition(), a ScrollTypeScope, and the animator's
// retargetRunningAnimation(), cancelAnimations() and scrollToPositionWithAnimation().
@_expose(Cxx)
func scrollableAreaScrollToPositionWithAnimation(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ position: WebCore.FloatPoint,
    _ type: WebCore.ScrollType,
    _ clamping: WebCore.ScrollClamping,
    _ snapPointSelectionMethod: WebCore.ScrollSnapPointSelectionMethod,
    _ hasOriginalScrollDelta: Bool,
    _ originalScrollDelta: WebCore.FloatSize,
    _ animationCurve: WebCore.ScrollAnimationCurve
) {
    var options = WebCore.ScrollPositionChangeOptions.createProgrammaticWithOptions(clamping, .No, snapPointSelectionMethod, .init())
    options.type = type
    if hasOriginalScrollDelta {
        options.originalScrollDelta = .init(originalScrollDelta)
    }
    options.animationCurve = animationCurve
    scrollableAreaScrollToPositionWithAnimation(&c, position, options: options)
}

func scrollableAreaScrollToPositionWithAnimation(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ position: WebCore.FloatPoint,
    options: WebCore.ScrollPositionChangeOptions
) {
    if c.scrollAnimationStatus() == .Animating {
        // Retargeting a running smooth scroll lets it run to the new destination; cancelling it would fire scrollend
        // at the intermediate position. Cancel only when there is no main-thread animation to retarget.
        if c.animatorRetargetRunningAnimation(position, options.animationCurve) {
            return
        }
        c.animatorCancelAnimations()
    }

    let scrollPosition = c.scrollPosition()
    if position.x() == Float(scrollPosition.x()) && position.y() == Float(scrollPosition.y()) {
        return
    }

    c.beginScrollTypeScope(options.type)

    let roundedPosition = roundedIntPoint(ScrollPoint(position))
    let originalScrollDelta = options.originalScrollDelta.value
    var startedAnimation = c.requestScrollToPosition(
        WebCore.IntPoint(roundedPosition.x, roundedPosition.y),
        .Programmatic,
        options.clamping,
        .Yes,
        options.snapPointSelectionMethod,
        originalScrollDelta != nil,
        originalScrollDelta ?? WebCore.FloatSize(),
        options.animationCurve
    )
    if !startedAnimation {
        startedAnimation = c.animatorScrollToPositionWithAnimation(position, options.clamping, options.animationCurve)
    }

    if startedAnimation {
        c.setScrollAnimationStatus(.Animating)
    }

    c.endScrollTypeScope()
}

// ScrollableArea::scrollToOffsetWithoutAnimation(const FloatPoint&, ScrollClamping). While `c` is live this calls
// scrollOrigin() and the animator's scrollToPositionWithoutAnimation().
@_expose(Cxx)
func scrollableAreaScrollToOffsetWithoutAnimation(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ offset: WebCore.FloatPoint,
    _ clamping: WebCore.ScrollClamping
) {
    let position = scrollableAreaScrollPositionFromOffset(&c, ScrollPoint(offset))
    _ = c.animatorScrollToPositionWithoutAnimation(position.floatPoint, clamping)
}

// ScrollableArea::scrollToOffsetWithoutAnimation(ScrollbarOrientation, float), from the animator's current position.
// While `c` is live this calls the animator's currentPosition() and scrollToPositionWithoutAnimation(), and
// scrollOrigin().
@_expose(Cxx)
func scrollableAreaScrollToOffsetWithoutAnimationOnAxis(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ orientation: WebCore.ScrollbarOrientation,
    _ offset: Float
) {
    let currentOffset = scrollableAreaScrollOffsetFromPosition(&c, ScrollPoint(c.currentPosition()))
    if orientation == .Horizontal {
        scrollableAreaScrollToOffsetWithoutAnimation(&c, WebCore.FloatPoint(offset, currentOffset.y), .Clamped)
    } else {
        scrollableAreaScrollToOffsetWithoutAnimation(&c, WebCore.FloatPoint(currentOffset.x, offset), .Clamped)
    }
}

// ScrollableArea::notifyScrollPositionChanged(). While `c` is live this calls what scrollPositionChanged() calls
// (below) and the animator's setCurrentPosition().
@_expose(Cxx)
func scrollableAreaNotifyScrollPositionChanged(_ c: inout WebCore.ScrollAnimatorScrollPhysicsClient, _ position: WebCore.IntPoint) {
    scrollableAreaScrollPositionChanged(&c, position)
    c.animatorSetCurrentPosition(WebCore.FloatPoint(Float(position.x()), Float(position.y())))
}

// ScrollableArea::scrollPositionChanged(), which only ScrollableArea's members call. Both scrollbars are fetched, the
// vertical one first, and held: the horizontal one until its update is done, the vertical one until the end. This
// calls scrollPosition(), scrollOrigin(), setScrollOffset(), the scrollbars and their layers, the ScrollbarsController,
// the ScrollAnchoringController and updateAnchorPositionedAfterScroll().
func scrollableAreaScrollPositionChanged(_ c: inout WebCore.ScrollAnimatorScrollPhysicsClient, _ position: WebCore.IntPoint) {
    let oldPosition = c.scrollPosition()
    // Tell the derived class to scroll its contents.
    c.setScrollOffset(scrollableAreaScrollOffsetFromPosition(&c, position))

    c.protectScrollbars()

    // Tell the scrollbars to update their thumb positions.
    if c.hasProtectedScrollbar(.Horizontal) {
        c.protectedScrollbarOffsetDidChange(.Horizontal)
        if c.protectedScrollbarIsOverlay(.Horizontal) && !c.hasLayerForHorizontalScrollbar() {
            if !c.hasProtectedScrollbar(.Vertical) {
                c.protectedScrollbarInvalidate(.Horizontal)
            } else {
                // With both scrollbars, also invalidate the corner between them. A wrapped width invalidates the
                // wrong rect.
                var boundsAndCorner = c.protectedScrollbarBoundsRect(.Horizontal)
                boundsAndCorner.setWidth(boundsAndCorner.width() &+ c.protectedScrollbarWidth(.Vertical))
                c.protectedScrollbarInvalidateRect(.Horizontal, boundsAndCorner)
            }
        }
        c.releaseProtectedScrollbar(.Horizontal)
    }
    if c.hasProtectedScrollbar(.Vertical) {
        c.protectedScrollbarOffsetDidChange(.Vertical)
        if c.protectedScrollbarIsOverlay(.Vertical) && !c.hasLayerForVerticalScrollbar() {
            c.protectedScrollbarInvalidate(.Vertical)
        }
    }

    let scrollPosition = c.scrollPosition()
    if scrollPosition.x() != oldPosition.x() || scrollPosition.y() != oldPosition.y() {
        // Gets the ScrollbarsController, which creates it if needed, before reading the new position.
        c.notifyContentAreaScrolledFrom(oldPosition)
        c.scrollAnchoringScrollPositionDidChange()
        c.updateAnchorPositionedAfterScroll()
    }

    c.releaseProtectedScrollbar(.Vertical)
}

// ScrollableArea::setScrollPositionFromAnimation(). An early return here if the position has not changed breaks an
// iOS RTL scrolling test: webkit.org/b/230450. While `c` is live this calls currentScrollType(),
// requestScrollToPosition() and what scrollPositionChanged() calls.
@_expose(Cxx)
func scrollableAreaSetScrollPositionFromAnimation(_ c: inout WebCore.ScrollAnimatorScrollPhysicsClient, _ position: WebCore.IntPoint) {
    let scrollType = c.currentScrollType()
    let clamping: WebCore.ScrollClamping = scrollType == .User ? .Unclamped : .Clamped
    if c.requestScrollToPosition(position, scrollType, clamping, .No, .Closest, false, WebCore.FloatSize(), .Default) {
        return
    }

    scrollableAreaScrollPositionChanged(&c, position)
}

// The offset on one axis of the active snap point, if there is one, no scrollbar on that axis is pressed, and the snap
// area does not cover the snapport at the current offset.
private func correctedSnapOffset(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ axis: WebCore.ScrollEventAxis,
    _ currentOffset: Int32
) -> Int32? {
    let orientation: WebCore.ScrollbarOrientation = axis == .Horizontal ? .Horizontal : .Vertical
    if c.hasScrollbar(orientation) && c.scrollbarPressedPart(orientation) != WebCore.NoPart {
        return nil
    }
    guard let index = c.activeScrollSnapIndex(axis).value else {
        return nil
    }
    let axisOffset = WebCore.LayoutUnit(currentOffset).rawValue()
    let visibleSize = c.visibleSize()
    let length = WebCore.LayoutUnit(axis == .Horizontal ? visibleSize.width() : visibleSize.height()).rawValue()
    if snapOffsetCoversSnapport(&c, axis, index, axisOffset, length) {
        return nil
    }
    return c.snapOffset(axis, index).toInt()
}

// ScrollableArea::resnapAfterLayout(). While `c` is live this calls isScrollSnapInProgress(), isUserScrollInProgress(),
// isInStableState(), scrollPosition(), scrollOrigin(), visibleSize(), the scrollbars' pressedPart(), the snap offsets
// and the active snap indices, scrollAnimationStatus(), a ScrollTypeScope, and the animator's resnapAfterLayout(),
// retargetRunningAnimation() and scrollToPositionWithoutAnimation().
@_expose(Cxx)
func scrollableAreaResnapAfterLayout(_ c: inout WebCore.ScrollAnimatorScrollPhysicsClient) {
    if !c.hasScrollAnimator() || c.isScrollSnapInProgress() || c.isUserScrollInProgress() || !c.isInStableState() {
        return
    }

    c.animatorResnapAfterLayout()

    if !c.hasSnapOffsets() {
        return
    }

    let currentOffset = scrollableAreaScrollOffsetFromPosition(&c, c.scrollPosition())
    var correctedX = currentOffset.x()
    var correctedY = currentOffset.y()
    if let x = correctedSnapOffset(&c, .Horizontal, currentOffset.x()) {
        correctedX = x
    }
    if let y = correctedSnapOffset(&c, .Vertical, currentOffset.y()) {
        correctedY = y
    }

    if correctedX == currentOffset.x() && correctedY == currentOffset.y() {
        return
    }

    let correctedOffset = WebCore.IntPoint(correctedX, correctedY)
    let position = scrollableAreaScrollPositionFromOffset(&c, correctedOffset)
    if c.scrollAnimationStatus() == .NotAnimating {
        c.beginScrollTypeScope(.Programmatic)
        scrollableAreaScrollToOffsetWithoutAnimation(&c, WebCore.FloatPoint(Float(correctedX), Float(correctedY)), .Clamped)
        c.endScrollTypeScope()
    } else {
        // Resnapping corrects the position rather than scrolling to an edge of the document, so it uses the default curve.
        _ = c.animatorRetargetRunningAnimation(WebCore.FloatPoint(Float(position.x()), Float(position.y())), .Default)
    }
}

// Converts float to int as arm64 does: toward zero, saturating, and NaN to 0. The implicit conversion to int is
// undefined out of range. The value is a LayoutUnit snap offset or an int offset converted to float, so it is out of
// range only for an offset within 64 of INT_MAX.
private func truncatedToInt32(_ value: Float) -> Int32 {
    if value.isNaN {
        return 0
    }
    if value >= 2_147_483_648 {
        return .max
    }
    if value < -2_147_483_648 {
        return .min
    }
    return Int32(value)
}

// ScrollableArea::doPostThumbMoveSnapping(). While `c` is live this calls scrollPosition(), scrollOrigin(), and the
// animator's scrollOffsetAdjustedForSnapping() and scrollToPositionWithAnimation().
@_expose(Cxx)
func scrollableAreaDoPostThumbMoveSnapping(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ orientation: WebCore.ScrollbarOrientation
) {
    guard c.hasScrollAnimator() else {
        return
    }

    let currentOffset = scrollableAreaScrollOffsetFromPosition(&c, c.scrollPosition())
    let currentFloatOffset = WebCore.FloatPoint(Float(currentOffset.x()), Float(currentOffset.y()))
    var newX = currentOffset.x()
    var newY = currentOffset.y()
    if orientation == .Horizontal {
        newX = truncatedToInt32(c.animatorScrollOffsetAdjustedForSnapping(.Horizontal, currentFloatOffset, .Closest))
    } else {
        newY = truncatedToInt32(c.animatorScrollOffsetAdjustedForSnapping(.Vertical, currentFloatOffset, .Closest))
    }

    if newX == currentOffset.x() && newY == currentOffset.y() {
        return
    }

    let position = scrollableAreaScrollPositionFromOffset(&c, WebCore.IntPoint(newX, newY))
    _ = c.animatorScrollToPositionWithAnimation(WebCore.FloatPoint(Float(position.x()), Float(position.y())), .Clamped, .Default)
}

// LayoutUnit values below are raw values, with LayoutUnit's saturating arithmetic.

@inline(always)
private func layoutUnit(_ rawValue: Int32) -> WebCore.LayoutUnit {
    WebCore.LayoutUnit.fromRawValue(rawValue)
}

// LayoutUnit's unary operator-: -min() is max().
@inline(always)
private func layoutUnitNegation(_ a: Int32) -> Int32 {
    a == .min ? .max : -a
}

@inline(always)
private func layoutPoint(_ x: Int32, _ y: Int32) -> WebCore.LayoutPoint {
    var point = WebCore.LayoutPoint()
    point.setX(layoutUnit(x))
    point.setY(layoutUnit(y))
    return point
}

@inline(always)
private func layoutSize(_ width: Int32, _ height: Int32) -> WebCore.LayoutSize {
    var size = WebCore.LayoutSize()
    size.setWidth(layoutUnit(width))
    size.setHeight(layoutUnit(height))
    return size
}

// ScrollableArea::constrainScrollPositionForOverhang(), the static member.
@_expose(Cxx)
func scrollableAreaConstrainScrollPositionForOverhang(
    _ visibleContentRect: WebCore.LayoutRect,
    _ totalContentsSize: WebCore.LayoutSize,
    _ scrollPosition: WebCore.LayoutPoint,
    _ scrollOrigin: WebCore.LayoutPoint,
    _ headerHeight: CInt,
    _ footerHeight: CInt
) -> WebCore.LayoutPoint {
    let totalWidth = totalContentsSize.width().rawValue()
    let totalHeight = totalContentsSize.height().rawValue()
    let header = WebCore.LayoutUnit(headerHeight).rawValue()
    let footer = WebCore.LayoutUnit(footerHeight).rawValue()

    // The viewport rect that we're scrolling shouldn't be larger than our document.
    let idealWidth = stdMin(visibleContentRect.width().rawValue(), totalWidth)
    let idealHeight = stdMin(visibleContentRect.height().rawValue(), totalHeight)
    let idealScrollRectSize = layoutSize(idealWidth, idealHeight)

    let originX = scrollOrigin.x().rawValue()
    let originY = scrollOrigin.y().rawValue()
    var scrollRect = WebCore.LayoutRect(
        layoutPoint(
            layoutUnitSum(scrollPosition.x().rawValue(), originX),
            layoutUnitDifference(layoutUnitSum(scrollPosition.y().rawValue(), originY), header)
        ),
        idealScrollRectSize
    )
    let documentRect = WebCore.LayoutRect(
        WebCore.LayoutPoint(),
        layoutSize(totalWidth, layoutUnitDifference(layoutUnitDifference(totalHeight, header), footer))
    )

    // Use intersection to constrain our ideal scroll rect by the document rect.
    scrollRect.intersect(documentRect)

    if scrollRect.width().rawValue() != idealWidth || scrollRect.height().rawValue() != idealHeight {
        // If the rect was clipped, restore its size, effectively pushing it "down" from the top left.
        scrollRect.setSize(idealScrollRectSize)

        // If we still clip, push our rect "up" from the bottom right.
        scrollRect.intersect(documentRect)
        var x = scrollRect.x().rawValue()
        var y = scrollRect.y().rawValue()
        let width = scrollRect.width().rawValue()
        if width < idealWidth {
            x = layoutUnitSum(x, layoutUnitNegation(layoutUnitDifference(idealWidth, width)))
        }
        let height = scrollRect.height().rawValue()
        if height < idealHeight {
            y = layoutUnitSum(y, layoutUnitNegation(layoutUnitDifference(idealHeight, height)))
        }
        scrollRect.setLocation(layoutPoint(x, y))
    }

    return layoutPoint(
        layoutUnitDifference(scrollRect.x().rawValue(), originX),
        layoutUnitDifference(scrollRect.y().rawValue(), originY)
    )
}

// ScrollableArea::computeScrollbarValueAndOverhang().
@_expose(Cxx)
func scrollableAreaComputeScrollbarValueAndOverhang(
    _ currentPosition: Float,
    _ totalSize: Float,
    _ visibleSize: Float,
    _ scrollbarValue: inout Float,
    _ overhangAmount: inout Float
) {
    scrollbarValue = 0
    overhangAmount = 0
    let maximum = totalSize - visibleSize

    if currentPosition < 0 {
        // Scrolled past the top.
        scrollbarValue = 0
        overhangAmount = -currentPosition
    } else if visibleSize + currentPosition > totalSize {
        // Scrolled past the bottom.
        scrollbarValue = 1
        overhangAmount = currentPosition + visibleSize - totalSize
    } else {
        // Within the bounds of the scrollable area.
        if maximum > 0 {
            scrollbarValue = currentPosition / maximum
        } else {
            scrollbarValue = 0
        }
    }
}

// ScrollableArea::targetSideForScrollDelta().
@_expose(Cxx)
func scrollableAreaTargetSideForScrollDelta(_ delta: WebCore.FloatSize, _ axis: WebCore.ScrollEventAxis) -> WebCore.OptionalBoxSide {
    guard let side = targetSideForScrollDelta(ScrollSize(delta), axis) else {
        return WebCore.OptionalBoxSide()
    }
    return WebCore.OptionalBoxSide(side)
}

// One axis of getRectToExposeForScrollIntoView(): the behavior for how much of the exposed range is visible.
private func scrollIntoViewBehavior(
    _ align: WebCore.ScrollAlignment,
    _ visibleMin: Int32,
    _ visibleMax: Int32,
    _ visibleLength: Int32,
    _ exposeMin: Int32,
    _ exposeMax: Int32,
    _ exposeLength: Int32,
    _ intersects: Bool,
    _ usesLegacyThreshold: Bool
) -> WebCore.ScrollAlignment.Behavior {
    guard intersects else {
        return align.getHiddenBehavior()
    }
    let intersectLength = stdMax(0, layoutUnitDifference(stdMin(visibleMax, exposeMax), stdMax(visibleMin, exposeMin)))
    let minIntersectForReveal = WebCore.LayoutUnit(CInt(32)).rawValue()
    if intersectLength == exposeLength || (usesLegacyThreshold && intersectLength >= minIntersectForReveal) {
        // If the rectangle is fully visible, use the specified visible behavior. If the rectangle is partially
        // visible, but over a certain threshold, then treat it as fully visible to avoid unnecessary horizontal
        // scrolling.
        return align.getVisibleBehavior()
    }
    if intersectLength == visibleLength {
        // The rect is bigger than the visible area.
        return align.getVisibleBehavior()
    }
    if intersectLength > 0 {
        // If the rectangle is partially visible, but not above the minimum threshold, use the specified partial behavior.
        return align.getPartialBehavior()
    }
    return align.getHiddenBehavior()
}

// ScrollableArea::getRectToExposeForScrollIntoView(), with the optional visibility check rect as a flag and a rect.
@_expose(Cxx)
func scrollableAreaRectToExposeForScrollIntoView(
    _ visibleBounds: WebCore.LayoutRect,
    _ exposeRect: WebCore.LayoutRect,
    _ alignX: WebCore.ScrollAlignment,
    _ alignY: WebCore.ScrollAlignment,
    _ hasVisibilityCheckRect: Bool,
    _ visibilityCheckRect: WebCore.LayoutRect
) -> WebCore.LayoutRect {
    let visibleX = visibleBounds.x().rawValue()
    let visibleMaxX = visibleBounds.maxX().rawValue()
    let visibleWidth = visibleBounds.width().rawValue()
    let exposeX = exposeRect.x().rawValue()
    let exposeMaxX = exposeRect.maxX().rawValue()
    let exposeWidth = exposeRect.width().rawValue()

    let checkRect = hasVisibilityCheckRect ? visibilityCheckRect : exposeRect
    let intersectsInX = checkRect.maxX().rawValue() >= visibleX && checkRect.x().rawValue() <= visibleMaxX

    // Determine the appropriate X behavior.
    var scrollX = scrollIntoViewBehavior(
        alignX,
        visibleX,
        visibleMaxX,
        visibleWidth,
        exposeX,
        exposeMaxX,
        exposeWidth,
        intersectsInX,
        alignX.legacyHorizontalVisibilityThresholdEnabled()
    )

    if scrollX == .AlignToClosestEdge {
        // The closest edge is the right in two cases:
        // (1) exposeRect is to the right of and smaller than visibleBounds.
        // (2) exposeRect is to the left of and larger than visibleBounds.
        if (exposeMaxX > visibleMaxX && exposeWidth < visibleWidth) || (exposeMaxX < visibleMaxX && exposeWidth > visibleWidth) {
            scrollX = .AlignRight
        }
    }

    // Given the X behavior, compute the X coordinate. LayoutUnit / 2 truncates toward zero.
    let x: Int32
    if scrollX == .NoScroll {
        x = visibleX
    } else if scrollX == .AlignRight {
        x = layoutUnitDifference(exposeMaxX, visibleWidth)
    } else if scrollX == .AlignCenter {
        x = layoutUnitSum(exposeX, layoutUnitDifference(exposeWidth, visibleWidth) / 2)
    } else {
        x = exposeX
    }

    let visibleY = visibleBounds.y().rawValue()
    let visibleMaxY = visibleBounds.maxY().rawValue()
    let visibleHeight = visibleBounds.height().rawValue()
    let exposeY = exposeRect.y().rawValue()
    let exposeMaxY = exposeRect.maxY().rawValue()
    let exposeHeight = exposeRect.height().rawValue()

    let intersectsInY = checkRect.maxY().rawValue() >= visibleY && checkRect.y().rawValue() <= visibleMaxY

    // Determine the appropriate Y behavior.
    var scrollY = scrollIntoViewBehavior(
        alignY,
        visibleY,
        visibleMaxY,
        visibleHeight,
        exposeY,
        exposeMaxY,
        exposeHeight,
        intersectsInY,
        false
    )

    if scrollY == .AlignToClosestEdge {
        // The closest edge is the bottom in two cases:
        // (1) exposeRect is below and smaller than visibleBounds.
        // (2) exposeRect is above and larger than visibleBounds.
        if (exposeMaxY > visibleMaxY && exposeHeight < visibleHeight) || (exposeMaxY < visibleMaxY && exposeHeight > visibleHeight) {
            scrollY = .AlignBottom
        }
    }

    // Given the Y behavior, compute the Y coordinate.
    let y: Int32
    if scrollY == .NoScroll {
        y = visibleY
    } else if scrollY == .AlignBottom {
        y = layoutUnitDifference(exposeMaxY, visibleHeight)
    } else if scrollY == .AlignCenter {
        let halfHeight = layoutUnitDifference(exposeHeight, visibleHeight) / 2
        y = layoutUnitSum(exposeY, WebCore.LayoutUnit(layoutUnit(halfHeight).ceil()).rawValue())
    } else {
        y = exposeY
    }

    return WebCore.LayoutRect(layoutPoint(x, y), visibleBounds.size())
}

// ScrollableArea::deltaForPropagation(), from the area's horizontal and vertical overscroll behaviors.
@_expose(Cxx)
func scrollableAreaDeltaForPropagation(
    _ horizontal: WebCore.OverscrollBehavior,
    _ vertical: WebCore.OverscrollBehavior,
    _ biasedDelta: WebCore.FloatSize
) -> WebCore.FloatSize {
    var filteredDelta = biasedDelta
    if horizontal != .Auto {
        filteredDelta.setWidth(0)
    }
    if vertical != .Auto {
        filteredDelta.setHeight(0)
    }
    return filteredDelta
}

// ScrollableArea::shouldBlockScrollPropagation(), from the same behaviors.
@_expose(Cxx)
func scrollableAreaShouldBlockScrollPropagation(
    _ horizontal: WebCore.OverscrollBehavior,
    _ vertical: WebCore.OverscrollBehavior,
    _ biasedDelta: WebCore.FloatSize
) -> Bool {
    let preventsHorizontalPropagation = horizontal != .Auto
    let preventsVerticalPropagation = vertical != .Auto
    if preventsHorizontalPropagation && preventsVerticalPropagation {
        return true
    }
    if preventsHorizontalPropagation {
        return biasedDelta.height() == 0
    }
    if preventsVerticalPropagation {
        return biasedDelta.width() == 0
    }
    return false
}
