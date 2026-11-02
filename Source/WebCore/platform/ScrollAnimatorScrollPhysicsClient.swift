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

internal import WebCore_Private.Core.PlatformWheelEvent
internal import WebCore_Private.ScrollAnimatorScrollPhysicsClient
internal import WebCore_Private.ScrollPhysicsTypes
internal import WebCore_Private.Core.ScrollExtents
internal import WebCore_Private.Core.ScrollTypes

// ScrollAnimatorMac's scroll physics client members that are not C++ members of ScrollAnimatorScrollPhysicsClient:
// ScrollingEffectsControllerClient's defaults, shouldRubberBandOnSide() and isScrollDeltaOpposingStretch().
extension WebCore.ScrollAnimatorScrollPhysicsClient: ScrollPhysicsClientProtocol {
    // As ScrollAnimatorMac::isScrollDeltaOpposingStretch().
    mutating func isScrollDeltaOpposingStretch(_ axis: WebCore.ScrollEventAxis, _ delta: Float) -> Bool {
        WebCore.ScrollingEffectsController.isScrollDeltaOpposingStretch(stretchAmount(), axis, delta)
    }

    mutating func shouldRubberBandOnSide(_ side: WebCore.BoxSide, _ delta: WebCore.FloatSize) -> Bool {
        false
    }

    mutating func willStartRubberBandAnimation() {
    }

    mutating func didStopRubberBandAnimation() {
    }

    mutating func rubberBandingStateChanged(_ isRubberBanding: Bool) {
    }

    mutating func rubberBandTargetOffset() -> WebCore.FloatSize {
        WebCore.FloatSize()
    }

    mutating func hasRefreshController() -> Bool {
        false
    }

    mutating func refreshControllerSnappingThreshold() -> Float {
        0
    }

    mutating func willStartWheelEventScroll() {
    }

    mutating func willStartScrollSnapAnimation() {
    }

    mutating func didStopScrollSnapAnimation() {
    }

    mutating func immediateScrollBy(_ delta: WebCore.FloatSize, _ clamping: WebCore.ScrollClamping, _ controller: ScrollPhysicsController) {
        controller.scrollAnimatorImmediateScrollBy(&self, delta, clamping)
    }

    mutating func startAnimationCallback() {
        if !scrollAnimationScheduled() {
            setScrollAnimationScheduled(true)
            didStartScrollAnimation()
        }
    }

    mutating func stopAnimationCallback() {
        setScrollAnimationScheduled(false)
    }

    // As ScrollAnimatorMac::allowsHorizontalStretching().
    mutating func allowsHorizontalStretching(_ wheelEvent: borrowing @_addressable WebCore.PlatformWheelEvent) -> Bool {
        if horizontalOverscrollBehavior() == .None {
            return false
        }

        switch horizontalScrollElasticity() {
        case .Automatic:
            var scrollbarsAllowStretching = scrollbarEnabled(.Horizontal)
            if !scrollbarsAllowStretching {
                scrollbarsAllowStretching = !scrollbarEnabled(.Vertical)
            }
            let relevantSide = stretchingTargetSide(wheelEvent, .Horizontal)
            var eventPreventsStretching = false
            if hasScrollableOrRubberbandableAncestor(), wheelEvent.isGestureStart(), let relevantSide {
                eventPreventsStretching = isPinnedOnSide(relevantSide)
            }
            if !eventPreventsStretching {
                eventPreventsStretching = gestureShouldBeginSnap(wheelEvent, .Horizontal)
            }
            return scrollbarsAllowStretching && !eventPreventsStretching
        case .None:
            return false
        case .Allowed:
            return true
        @unknown default:
            return false
        }
    }

    // As ScrollAnimatorMac::allowsVerticalStretching().
    mutating func allowsVerticalStretching(_ wheelEvent: borrowing @_addressable WebCore.PlatformWheelEvent) -> Bool {
        if verticalOverscrollBehavior() == .None {
            return false
        }

        switch verticalScrollElasticity() {
        case .Automatic:
            var scrollbarsAllowStretching = scrollbarEnabled(.Vertical)
            if !scrollbarsAllowStretching {
                scrollbarsAllowStretching = !scrollbarEnabled(.Horizontal)
            }
            let relevantSide = stretchingTargetSide(wheelEvent, .Vertical)
            var eventPreventsStretching = false
            if hasScrollableOrRubberbandableAncestor(), wheelEvent.isGestureStart(), let relevantSide {
                eventPreventsStretching = isPinnedOnSide(relevantSide)
            }
            if !eventPreventsStretching {
                eventPreventsStretching = gestureShouldBeginSnap(wheelEvent, .Vertical)
            }
            return scrollbarsAllowStretching && !eventPreventsStretching
        case .None:
            return false
        case .Allowed:
            return true
        @unknown default:
            return false
        }
    }

    // Whether a gesture's end should snap on the axis rather than stretch. The area's snap offsets are this
    // animator's.
    private mutating func gestureShouldBeginSnap(
        _ wheelEvent: borrowing @_addressable WebCore.PlatformWheelEvent,
        _ axis: WebCore.ScrollEventAxis
    ) -> Bool {
        if !hasSnapOffsets() {
            return false
        }

        if snapOffsetCount(axis) == 0 {
            return false
        }

        if wheelEvent.phase() != .Ended {
            if !wheelEvent.isEndOfMomentumScroll() {
                return false
            }
        }

        return true
    }

    mutating func scrollOffset() -> WebCore.FloatPoint {
        let position = roundedIntPoint(ScrollPoint(currentPosition()))
        let offset = scrollableAreaScrollOffsetFromPosition(&self, WebCore.IntPoint(position.x, position.y))
        return WebCore.FloatPoint(Float(offset.x()), Float(offset.y()))
    }

    mutating func willStartAnimatedScroll() {
        setScrollAnimationStatus(.Animating)
    }

    mutating func didStopAnimatedScroll() {
        setScrollAnimationStatus(.NotAnimating)
        animatedScrollDidEnd()
        scrollDidEnd()
    }

    mutating func scrollExtents() -> WebCore.ScrollExtents {
        var extents = WebCore.ScrollExtents()
        extents.contentsSize = ScrollSize(totalContentsSize()).floatSize
        extents.viewportSize = ScrollSize(visibleSize()).floatSize
        extents.snapportSize = ScrollSize(snapportSize()).floatSize
        return extents
    }
}

// ScrollableArea::targetSideForScrollDelta() for the scroll the event asks for: wheel deltas are reversed from the
// scrolling direction.
private func stretchingTargetSide(
    _ wheelEvent: borrowing @_addressable WebCore.PlatformWheelEvent,
    _ axis: WebCore.ScrollEventAxis
) -> WebCore.BoxSide? {
    targetSideForScrollDelta(-ScrollSize(wheelEvent.delta()), axis)
}
