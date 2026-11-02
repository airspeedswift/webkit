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

// Helpers for ScrollAnimator's and ScrollAnimatorMac's members on macOS, which are ScrollPhysicsController methods
// (ScrollPhysicsController.swift). Main thread only, as ScrollAnimator is.

internal import WebCore_Private.Core.PlatformWheelEvent
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.ScrollAnimatorScrollPhysicsClient
internal import WebCore_Private.ScrollPhysicsTypes

extension ScrollPhysicsController {
    // "Stepped scrolling" is only used by RenderListBox. It's special in that it has no rubberbanding, and scroll
    // deltas respect Scrollbar::pixelStep().
    func scrollAnimatorHandleSteppedScrolling(
        _ c: inout MainThreadScrollPhysicsClient,
        _ wheelEvent: borrowing @_addressable WebCore.PlatformWheelEvent
    ) -> Bool {
        let phase = wheelEvent.phase()
        let momentumPhase = wheelEvent.momentumPhase()
        if (phase == .Ended && momentumPhase == .None) || momentumPhase == .Ended {
            c.scrollDidEnd()
            return true
        }

        let hasHorizontalScrollbar = c.hasScrollbar(.Horizontal)
        let hasVerticalScrollbar = c.hasScrollbar(.Vertical)

        // Accept the event if we have a scrollbar in that direction and can still
        // scroll any further.
        var deltaX: Float = hasHorizontalScrollbar ? wheelEvent.deltaX() : 0
        var deltaY: Float = hasVerticalScrollbar ? wheelEvent.deltaY() : 0

        var handled = false

        // IntPoint subtraction: wraps when the scroll range is wider than an int.
        let maximumPosition = c.maximumScrollPosition()
        let forwardPosition = c.scrollPosition()
        let maxForwardScrollDeltaWidth = maximumPosition.x() &- forwardPosition.x()
        let maxForwardScrollDeltaHeight = maximumPosition.y() &- forwardPosition.y()
        let backwardPosition = c.scrollPosition()
        let minimumPosition = c.minimumScrollPosition()
        let maxBackwardScrollDeltaWidth = backwardPosition.x() &- minimumPosition.x()
        let maxBackwardScrollDeltaHeight = backwardPosition.y() &- minimumPosition.y()
        if (deltaX < 0 && maxForwardScrollDeltaWidth > 0)
            || (deltaX > 0 && maxBackwardScrollDeltaWidth > 0)
            || (deltaY < 0 && maxForwardScrollDeltaHeight > 0)
            || (deltaY > 0 && maxBackwardScrollDeltaHeight > 0)
        {
            handled = true

            let neverAnimate = wheelEvent.hasPreciseScrollingDeltas()
            let isPageGranularity = wheelEvent.granularity() == .ScrollByPageWheelEvent

            if deltaY != 0 {
                if isPageGranularity {
                    deltaY = Float(signOf: deltaY, magnitudeOf: WebCore.ScrollAnimatorScrollPhysicsClient.pageStepDelta(c.visibleSize().height()))
                }

                let scrollDelta = c.scrollbarPixelStep(.Vertical) * -deltaY // Wheel deltas are reversed from scrolling direction.
                _ = scrollAnimatorSingleAxisScroll(&c, .Vertical, scrollDelta, true, false, neverAnimate, false)
            }

            if deltaX != 0 {
                if isPageGranularity {
                    deltaX = Float(signOf: deltaX, magnitudeOf: WebCore.ScrollAnimatorScrollPhysicsClient.pageStepDelta(c.visibleSize().width()))
                }

                let scrollDelta = c.scrollbarPixelStep(.Horizontal) * -deltaX // Wheel deltas are reversed from scrolling direction.
                _ = scrollAnimatorSingleAxisScroll(&c, .Horizontal, scrollDelta, true, false, neverAnimate, false)
            }
        }
        return handled
    }

    // ScrollAnimator::immediateScrollBy(), which the scroll physics calls through its client. The given clamping applies
    // for the move; the area's own is put back after.
    func scrollAnimatorImmediateScrollBy(
        _ c: inout MainThreadScrollPhysicsClient,
        _ delta: WebCore.FloatSize,
        _ clamping: WebCore.ScrollClamping
    ) {
        let previousClamping = c.scrollClamping()
        c.setScrollClamping(clamping)

        let currentPosition = ScrollPoint(c.currentPosition())
        let newPosition = scrollAnimatorAdjustScrollPositionIfNecessary(&c, currentPosition + ScrollSize(delta))
        if newPosition != currentPosition {
            scrollAnimatorSetCurrentPosition(&c, newPosition.floatPoint, true)
        }

        c.setScrollClamping(previousClamping)
    }

    // ScrollAnimator::adjustScrollPositionIfNecessary(): the area constrains an IntPoint, so a clamped position loses
    // its fraction.
    private func scrollAnimatorAdjustScrollPositionIfNecessary(
        _ c: inout MainThreadScrollPhysicsClient,
        _ position: ScrollPoint
    ) -> ScrollPoint {
        if c.scrollClamping() == .Unclamped {
            return position
        }

        let constrained = c.constrainedScrollPosition(WebCore.IntPoint(clampToInt32(position.x), clampToInt32(position.y)))
        return ScrollPoint(x: Float(constrained.x()), y: Float(constrained.y()))
    }

    // The position, constrained between the area's minimum and maximum scroll positions when clamped.
    func scrollAnimatorAdjustedPosition(
        _ c: inout MainThreadScrollPhysicsClient,
        _ position: ScrollPoint,
        _ clamping: WebCore.ScrollClamping
    ) -> ScrollPoint {
        guard clamping == .Clamped else {
            return position
        }
        let minimum = ScrollPoint(c.minimumScrollPosition())
        let maximum = ScrollPoint(c.maximumScrollPosition())
        return position.constrainedBetween(minimum, maximum)
    }

    // ScrollAnimator::offsetFromPosition(): ScrollableArea::scrollOffsetFromPosition() with the area's scroll origin.
    func scrollAnimatorOffsetFromPosition(_ c: inout MainThreadScrollPhysicsClient, _ position: ScrollPoint) -> ScrollPoint {
        scrollableAreaScrollOffsetFromPosition(&c, position)
    }

    // ScrollAnimator::positionFromOffset(): ScrollableArea::scrollPositionFromOffset() with the area's scroll origin.
    func scrollAnimatorPositionFromOffset(_ c: inout MainThreadScrollPhysicsClient, _ offset: ScrollPoint) -> ScrollPoint {
        scrollableAreaScrollPositionFromOffset(&c, offset)
    }

    // Requests the edge itself, rather than a delta that is relative to a position that may be out of date while an
    // animation runs. On the other axis, keeps the destination of an animation running on the main thread, such as the
    // inline edge that Home and End scroll to first.
    func scrollAnimatorScrollToDocumentEdgeWithAnimation(
        _ c: inout MainThreadScrollPhysicsClient,
        _ axis: WebCore.ScrollEventAxis,
        _ edgePosition: ScrollPoint
    ) {
        var newPosition = edgePosition
        if let destinationOffset = animatedScrollDestinationOffset() {
            let destinationPosition = scrollAnimatorPositionFromOffset(&c, ScrollPoint(destinationOffset))
            if axis == .Horizontal {
                newPosition.y = destinationPosition.y
            } else {
                newPosition.x = destinationPosition.x
            }
        }
        var options = WebCore.ScrollPositionChangeOptions.createProgrammatic()
        options.animationCurve = WebCore.documentEdgeScrollAnimationCurve()
        scrollableAreaScrollToPositionWithAnimation(&c, newPosition.floatPoint, options: options)
    }
}

extension ScrollPoint {
    init(_ point: WebCore.IntPoint) {
        self.init(x: Float(point.x()), y: Float(point.y()))
    }
}
