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

// ScrollingEffectsController's state and logic (ScrollingEffectsController.h). The C++ class holds one
// ScrollPhysicsController and forwards each member to it.
//
// Every entry point takes the controller's client as a ScrollPhysicsClient. The caller, a member of
// ScrollingEffectsController, makes it on its own stack for the call, and nothing else reaches it, so
// Swift has sole access to it for the call. A client call can call back into the controller
// (ScrollAnimator::immediateScrollBy() calls scrollPositionChanged() and
// updateActiveScrollSnapIndexForClientOffset()); that call makes its own ScrollPhysicsClient, and no
// access to the controller's stored state is held across a client call.
//
// Threads: a controller is used on one thread at a time, as ScrollingEffectsController is: the main thread for
// ScrollAnimator, and the scrolling thread or the UI process's event dispatcher, under the scrolling
// tree's lock, for ThreadedScrollingTreeScrollingNodeDelegate.

internal import Foundation
internal import pal.spi.mac.NSScrollViewSPI
internal import WebCore_Private.Core.KeyboardScroll
internal import WebCore_Private.Core.PlatformWheelEvent
internal import WebCore_Private.Core.RubberbandingState
internal import WebCore_Private.Core.ScrollExtents
internal import WebCore_Private.Core.ScrollSnapOffsetsInfo
internal import WebCore_Private.Core.ScrollingEffectsClock
internal import WebCore_Private.ScrollPhysicsTypes

private let scrollVelocityZeroingTimeout = 0.1
private let rubberbandDirectionLockStretchRatio: Float = 1
private let rubberbandMinimumRequiredDeltaBeforeStretch: Float = 10
private let gestureAxisDecayTimeConstant = 0.12
private let numberOfDeltasToStoreForDiscreteScrollSnap = 3

// NSScrollWheelMultiplier, read from the user defaults once, when first needed.
private let scrollWheelMultiplierValue: Float = {
    let multiplier = UserDefaults.standard.float(forKey: "NSScrollWheelMultiplier")
    return multiplier <= 0 ? 1 : multiplier
}()

private func elasticDeltaForReboundDelta(_ delta: Float) -> Float {
    Float(_NSElasticDeltaForReboundDelta(CGFloat(delta)))
}

private func reboundDeltaForElasticDelta(_ delta: Float) -> Float {
    Float(_NSReboundDeltaForElasticDelta(CGFloat(delta)))
}

// ScrollableArea::targetSideForScrollDelta().
func targetSideForScrollDelta(_ delta: ScrollSize, _ axis: WebCore.ScrollEventAxis) -> WebCore.BoxSide? {
    switch axis {
    case .Horizontal:
        if delta.width < 0 {
            return .Left
        }
        if delta.width > 0 {
            return .Right
        }
    case .Vertical:
        if delta.height < 0 {
            return .Top
        }
        if delta.height > 0 {
            return .Bottom
        }
    @unknown default:
        break
    }
    return nil
}

private func dominantAxisFavoringVertical(_ delta: ScrollSize) -> WebCore.ScrollEventAxis {
    abs(delta.height) >= abs(delta.width) ? .Vertical : .Horizontal
}

// Out of line, so the caller branches on the axis, which a gesture rarely changes, instead of selecting between the results.
@inline(never)
private func deltaAlignedToHorizontalAxis(_ delta: ScrollSize) -> ScrollSize {
    ScrollSize(width: delta.width, height: 0)
}

private func affectedSideOnDominantAxis(_ delta: ScrollSize) -> WebCore.BoxSide? {
    targetSideForScrollDelta(delta, dominantAxisFavoringVertical(delta))
}

private enum WheelEventStatus {
    case userScrollBegin
    case userScrolling
    case userScrollEnd
    case momentumScrollWillBegin
    case momentumScrollBegin
    case momentumScrolling
    case momentumScrollEnd
    case discreteScrollEvent
    case unknown

    init(_ phase: WebCore.PlatformWheelEventPhase, _ momentumPhase: WebCore.PlatformWheelEventPhase) {
        if phase == .None {
            switch momentumPhase {
            case .Began: self = .momentumScrollBegin
            case .Changed: self = .momentumScrolling
            case .Ended: self = .momentumScrollEnd
            case .None: self = .discreteScrollEvent
            case .WillBegin: self = .momentumScrollWillBegin
            default: self = .unknown
            }
            return
        }
        if momentumPhase == .None || momentumPhase == .WillBegin {
            switch phase {
            case .Began, .MayBegin: self = .userScrollBegin
            case .Changed: self = .userScrolling
            case .Ended, .Cancelled: self = .userScrollEnd
            case .WillBegin: self = .momentumScrollWillBegin
            default: self = .unknown
            }
            return
        }
        self = .unknown
    }
}

// The last few discrete wheel deltas, oldest first: at most numberOfDeltasToStoreForDiscreteScrollSnap
// are kept, and one more for the moment an append makes it too long.
struct RecentWheelDeltas {
    private var deltas: (ScrollSize, ScrollSize, ScrollSize, ScrollSize) = (.zero, .zero, .zero, .zero)
    private(set) var count = 0

    init() {}

    init(_ delta: ScrollSize) {
        append(delta)
    }

    var isEmpty: Bool { count == 0 }

    func delta(at index: Int) -> ScrollSize {
        switch index {
        case 0: deltas.0
        case 1: deltas.1
        case 2: deltas.2
        case 3: deltas.3
        default: preconditionFailure()
        }
    }

    mutating func append(_ delta: ScrollSize) {
        switch count {
        case 0: deltas.0 = delta
        case 1: deltas.1 = delta
        case 2: deltas.2 = delta
        case 3: deltas.3 = delta
        default: preconditionFailure()
        }
        count += 1
    }

    mutating func removeFirst() {
        precondition(count > 0)
        deltas = (deltas.1, deltas.2, deltas.3, .zero)
        count -= 1
    }
}

@_expose(Cxx)
final class ScrollPhysicsController {
    private let smoothAnimation = SmoothScrollAnimation()
    private let keyboardAnimation = KeyboardScrollAnimation()
    private let momentumAnimation = MomentumScrollAnimation()
    private let rubberBandAnimation = RubberBandScrollAnimation()

    // The kind of the current animation, or nil when there is none.
    private var currentAnimationType: ScrollPhysicsAnimationType?
    // Changes whenever the current animation is replaced or cleared.
    private var animationGeneration: UInt64 = 0

    private var scrollSnapState: ScrollSnapAnimationState?
    private var activeScrollSnapIndexDidChangeValue = false

    private var isRunningAnimatingCallback = false
    private var isAnimatingRubberBand = false
    private var isAnimatingScrollSnap = false
    private var isAnimatingKeyboardScrolling = false
    private var inScrollGesture = false

    private var lastMomentumScrollTimestamp: Double = 0
    private var unappliedOverscrollDelta = ScrollSize.zero
    private var stretchScrollForce = ScrollSize.zero
    private var momentumVelocity = ScrollSize.zero

    private var scrollingVelocityForScrollSnap = ScrollSize.zero

    private var momentumScrollInProgress = false
    private var ignoreMomentumScrolls = false
    private var isRubberBanding = false

    private var cumulativeGestureDelta = ScrollSize.zero
    private var lastGestureEventTime: Double = 0

    private var skipAdditionalDeltaAdjustments = false

    private var recentDiscreteWheelDeltas = RecentWheelDeltas()

    private var rubberBandingEdgeTop = false
    private var rubberBandingEdgeRight = false
    private var rubberBandingEdgeBottom = false
    private var rubberBandingEdgeLeft = false

    @_expose(Cxx)
    init() {}

    // Whether the animation that was current at `generation` still is.
    func isCurrentAnimation(_ generation: UInt64) -> Bool {
        generation == animationGeneration
    }

    private func setCurrentAnimationType(_ type: ScrollPhysicsAnimationType?) {
        currentAnimationType = type
        animationGeneration += 1
    }

    private func isAnimationActive(_ type: ScrollPhysicsAnimationType) -> Bool {
        switch type {
        case .smooth: smoothAnimation.isActive
        case .keyboard: keyboardAnimation.isActive
        case .momentum: momentumAnimation.isActive
        case .rubberBand: rubberBandAnimation.isActive
        }
    }

    private func stopCurrentAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        switch currentAnimationType {
        case .smooth: smoothAnimation.stopIfActive(&c, self)
        case .keyboard: keyboardAnimation.stopIfActive(&c, self)
        case .momentum: momentumAnimation.stop(&c, self)
        case .rubberBand: rubberBandAnimation.stopIfActive(&c, self)
        case nil: break
        }
    }

    private func serviceAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ type: ScrollPhysicsAnimationType,
        _ currentTime: Double
    ) {
        switch type {
        case .smooth: smoothAnimation.serviceAnimation(&c, self, currentTime, animationGeneration)
        case .keyboard: keyboardAnimation.serviceAnimation(&c, self, currentTime, animationGeneration)
        case .momentum: momentumAnimation.serviceAnimation(&c, self, currentTime, animationGeneration)
        case .rubberBand: rubberBandAnimation.serviceAnimation(&c, self, currentTime, animationGeneration)
        }
    }

    var usesScrollSnap: Bool { scrollSnapState != nil }

    // MARK: Animation callbacks

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func animationCallback(client c: inout WebCore.ScrollPhysicsClient, _ currentTime: Double) {
        animationCallback(&c, currentTime)
    }

    func animationCallback<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ currentTime: Double) {
        switch currentAnimationType {
        case .smooth:
            if smoothAnimation.isActive {
                smoothAnimation.serviceAnimation(&c, self, currentTime, animationGeneration)
            }
        case .keyboard:
            if keyboardAnimation.isActive {
                keyboardAnimation.serviceAnimation(&c, self, currentTime, animationGeneration)
            }
        case .momentum:
            if momentumAnimation.isActive {
                momentumAnimation.serviceAnimation(&c, self, currentTime, animationGeneration)
            }
        case .rubberBand:
            if rubberBandAnimation.isActive {
                rubberBandAnimation.serviceAnimation(&c, self, currentTime, animationGeneration)
            }
        case nil:
            break
        }
        // The service can replace or clear the current animation through the client.
        if let type = currentAnimationType, !isAnimationActive(type) {
            setCurrentAnimationType(nil)
        }

        updateRubberBandAnimatingState(&c)

        startOrStopAnimationCallbacks(&c)
    }

    private func startOrStopAnimationCallbacks<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        let needsCallbacks = isAnimatingRubberBand || isAnimatingKeyboardScrolling || currentAnimationType != nil
        if needsCallbacks == isRunningAnimatingCallback {
            return
        }

        if needsCallbacks {
            c.startAnimationCallback()
            isRunningAnimatingCallback = true
            return
        }

        c.stopAnimationCallback()
        isRunningAnimatingCallback = false
    }

    // MARK: Keyboard scrolling

    private func setIsAnimatingKeyboardScrolling<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ value: Bool) {
        if value == isAnimatingKeyboardScrolling {
            return
        }

        isAnimatingKeyboardScrolling = value
        startOrStopAnimationCallbacks(&c)
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func startKeyboardScroll(client c: inout WebCore.ScrollPhysicsClient, _ scrollData: WebCore.KeyboardScroll) -> Bool {
        return startKeyboardScroll(&c, scrollData)
    }

    func startKeyboardScroll<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ scrollData: WebCore.KeyboardScroll) -> Bool {
        stopCurrentAnimation(&c)

        keyboardAnimation.reset()
        setCurrentAnimationType(.keyboard)
        return keyboardAnimation.startKeyboardScroll(&c, self, scrollData)
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func finishKeyboardScroll(client c: inout WebCore.ScrollPhysicsClient, _ immediate: Bool) {
        finishKeyboardScroll(&c, immediate)
    }

    func finishKeyboardScroll<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ immediate: Bool) {
        if currentAnimationType == .keyboard {
            keyboardAnimation.finishKeyboardScroll(&c, self, immediate)
        }
    }

    // MARK: Animated scrolls

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func startAnimatedScrollToDestination(
        client c: inout WebCore.ScrollPhysicsClient,
        _ startOffset: WebCore.FloatPoint,
        _ destinationOffset: WebCore.FloatPoint
    ) -> Bool {
        return startAnimatedScrollToDestination(&c, startOffset, destinationOffset)
    }

    func startAnimatedScrollToDestination<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ startOffset: WebCore.FloatPoint,
        _ destinationOffset: WebCore.FloatPoint
    ) -> Bool {
        stopCurrentAnimation(&c)

        // The animation is always reset and started. If it has nothing to animate it stays inactive, and
        // animationCallback() clears it.
        smoothAnimation.reset()
        setCurrentAnimationType(.smooth)
        return smoothAnimation.startAnimatedScrollToDestination(&c, self, ScrollPoint(startOffset), ScrollPoint(destinationOffset))
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func retargetAnimatedScroll(client c: inout WebCore.ScrollPhysicsClient, _ newDestinationOffset: WebCore.FloatPoint) -> Bool {
        return retargetAnimatedScroll(&c, newDestinationOffset)
    }

    func retargetAnimatedScroll<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ newDestinationOffset: WebCore.FloatPoint
    ) -> Bool {
        guard currentAnimationType == .smooth else {
            return false
        }
        return smoothAnimation.retargetActiveAnimation(&c, self, ScrollPoint(newDestinationOffset))
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func retargetAnimatedScrollBy(client c: inout WebCore.ScrollPhysicsClient, _ offset: WebCore.FloatSize) -> Bool {
        return retargetAnimatedScrollBy(&c, offset)
    }

    func retargetAnimatedScrollBy<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ offset: WebCore.FloatSize) -> Bool {
        guard currentAnimationType == .smooth, smoothAnimation.isActive else {
            return false
        }
        return smoothAnimation.retargetActiveAnimation(&c, self, smoothAnimation.destinationOffset + ScrollSize(offset))
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func stopAnimatedNonRubberbandingScroll(client c: inout WebCore.ScrollPhysicsClient) {
        stopAnimatedNonRubberbandingScroll(&c)
    }

    func stopAnimatedNonRubberbandingScroll<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        guard let type = currentAnimationType else {
            return
        }

        if type == .rubberBand {
            return
        }

        if type == .momentum {
            // If the animation is currently triggering rubberbanding, let it run. Ideally we'd check if the animation will cause rubberbanding at any time in the future.
            let currentOffset = momentumAnimation.currentOffset
            let extents = ScrollPhysicsExtents(c.scrollExtents())
            let constrainedOffset = currentOffset.constrainedBetween(extents.minimumScrollOffset, extents.maximumScrollOffset)
            if currentOffset != constrainedOffset {
                return
            }
        }

        stopCurrentAnimation(&c)
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func stopAnimatedScroll(client c: inout WebCore.ScrollPhysicsClient) {
        stopAnimatedScroll(&c)
    }

    func stopAnimatedScroll<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        stopCurrentAnimation(&c)
    }

    func startMomentumScroll<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ initialOffset: ScrollPoint,
        _ initialVelocity: ScrollSize,
        _ initialDelta: ScrollSize,
        _ scrollSnapState: ScrollSnapAnimationState,
        _ snapInput: ScrollSnapModifierInput
    ) -> Bool {
        if currentAnimationType != nil {
            stopCurrentAnimation(&c)
            if currentAnimationType != .momentum {
                setCurrentAnimationType(nil)
            }
        }

        // A momentum animation that is current is started again in place.
        if currentAnimationType != .momentum {
            momentumAnimation.reset()
            setCurrentAnimationType(.momentum)
        }

        return momentumAnimation.startAnimatedScrollWithInitialVelocity(
            &c,
            self,
            initialOffset,
            initialVelocity,
            initialDelta,
            scrollSnapState,
            snapInput
        )
    }

    private func setIsAnimatingScrollSnap<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ value: Bool) {
        if value == isAnimatingScrollSnap {
            return
        }

        isAnimatingScrollSnap = value
        startOrStopAnimationCallbacks(&c)
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func contentsSizeChanged(client c: inout WebCore.ScrollPhysicsClient) {
        contentsSizeChanged(&c)
    }

    func contentsSizeChanged<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        switch currentAnimationType {
        case .smooth: smoothAnimation.updateScrollExtents(&c, self)
        case .momentum: momentumAnimation.updateScrollExtents(&c, self)
        // FIXME: If we're rubberbanding at the bottom and the content size changes we should fix up the target offset.
        case .keyboard, .rubberBand, nil: break
        }
    }

    // MARK: Scroll snap

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func setSnapOffsetsInfo(client c: inout WebCore.ScrollPhysicsClient, _ hasSnapOffsets: Bool) {
        setSnapOffsetsInfo(&c, hasSnapOffsets)
    }

    func setSnapOffsetsInfo<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ hasSnapOffsets: Bool) {
        if !hasSnapOffsets {
            scrollSnapState = nil
            return
        }

        let shouldComputeCurrentSnapIndices = scrollSnapState == nil
        if let scrollSnapState {
            scrollSnapState.setSnapOffsetInfo(&c)
        } else {
            scrollSnapState = ScrollSnapAnimationState(&c)
        }

        if shouldComputeCurrentSnapIndices {
            updateActiveScrollSnapIndexForClientOffset(&c)
        }
    }

    // -1 for no index.
    @_expose(Cxx)
    func activeScrollSnapIndexForAxis(_ axis: WebCore.ScrollEventAxis) -> Int64 {
        guard let scrollSnapState, let index = scrollSnapState.activeSnapIndexForAxis(axis) else {
            return -1
        }
        return Int64(index)
    }

    // index is -1 for no index.
    @_expose(Cxx)
    func setActiveScrollSnapIndexForAxis(_ axis: WebCore.ScrollEventAxis, _ index: Int64) {
        guard let scrollSnapState else {
            return
        }
        scrollSnapState.setActiveSnapIndexForAxis(axis, index < 0 ? nil : UInt32(truncatingIfNeeded: index))
    }

    @_expose(Cxx)
    func activeScrollSnapIndexDidChange() -> Bool {
        activeScrollSnapIndexDidChangeValue
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func adjustedScrollDestination(
        client c: inout WebCore.ScrollPhysicsClient,
        _ axis: WebCore.ScrollEventAxis,
        _ destinationOffset: WebCore.FloatPoint,
        _ velocity: Float,
        _ hasOriginalOffset: Bool,
        _ originalOffset: Float,
        _ selectionMethod: WebCore.ScrollSnapPointSelectionMethod
    ) -> Float {
        return adjustedScrollDestination(&c, axis, destinationOffset, velocity, hasOriginalOffset, originalOffset, selectionMethod)
    }

    func adjustedScrollDestination<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ axis: WebCore.ScrollEventAxis,
        _ destinationOffset: WebCore.FloatPoint,
        _ velocity: Float,
        _ hasOriginalOffset: Bool,
        _ originalOffset: Float,
        _ selectionMethod: WebCore.ScrollSnapPointSelectionMethod
    ) -> Float {
        guard let scrollSnapState else {
            return axis == .Horizontal ? destinationOffset.x() : destinationOffset.y()
        }

        let extents = ScrollPhysicsExtents(c.scrollExtents())
        let pageScale = c.pageScaleFactor()
        return scrollSnapState.adjustedScrollDestination(
            &c,
            axis,
            ScrollPoint(destinationOffset),
            velocity,
            hasOriginalOffset ? originalOffset : nil,
            extents,
            pageScale,
            selectionMethod
        )
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func updateActiveScrollSnapIndexForClientOffset(client c: inout WebCore.ScrollPhysicsClient) {
        updateActiveScrollSnapIndexForClientOffset(&c)
    }

    func updateActiveScrollSnapIndexForClientOffset<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        guard let scrollSnapState else {
            return
        }

        let offset = roundedIntPoint(ScrollPoint(c.scrollOffset()))
        let extents = ScrollPhysicsExtents(c.scrollExtents())
        let pageScale = c.pageScaleFactor()
        if scrollSnapState.setNearestScrollSnapIndexForOffset(&c, offset, extents, pageScale) {
            activeScrollSnapIndexDidChangeValue = true
        }
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func resnapAfterLayout(client c: inout WebCore.ScrollPhysicsClient) {
        resnapAfterLayout(&c)
    }

    func resnapAfterLayout<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        guard let scrollSnapState else {
            return
        }

        // If we are already snapped in a particular axis, maintain that. Otherwise, snap to the nearest eligible snap point.
        let offset = roundedIntPoint(ScrollPoint(c.scrollOffset()))
        let extents = ScrollPhysicsExtents(c.scrollExtents())
        let pageScale = c.pageScaleFactor()
        if scrollSnapState.resnapAfterLayout(&c, offset, extents, pageScale) {
            activeScrollSnapIndexDidChangeValue = true
        }
    }

    private func startScrollSnapAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        if isAnimatingScrollSnap {
            return
        }

        c.deferWheelEventTestCompletion(.ScrollSnapInProgress)
        c.willStartScrollSnapAnimation()
        setIsAnimatingScrollSnap(&c, true)
    }

    private func stopScrollSnapAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        if !isAnimatingScrollSnap {
            return
        }

        c.removeWheelEventTestCompletionDeferral(.ScrollSnapInProgress)
        c.didStopScrollSnapAnimation()

        setIsAnimatingScrollSnap(&c, false)
    }

    // MARK: Called by the animations

    func scrollAnimationDidUpdate<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ clamping: WebCore.ScrollClamping,
        _ scrollOffset: ScrollPoint
    ) {
        let currentOffset = ScrollPoint(c.scrollOffset())
        let scrollDelta = scrollOffset - currentOffset

        c.immediateScrollBy(scrollDelta.floatSize, clamping)
    }

    func scrollAnimationWillStart<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ type: ScrollPhysicsAnimationType) {
        if type == .rubberBand {
            willStartRubberBandAnimation(&c)
        }

        c.willStartAnimatedScroll()

        if type == .keyboard {
            setIsAnimatingKeyboardScrolling(&c, true)
            c.deferWheelEventTestCompletion(.ScrollAnimationInProgress)
            return
        }

        c.deferWheelEventTestCompletion(.ScrollAnimationInProgress)
        startOrStopAnimationCallbacks(&c)
    }

    func scrollAnimationDidEnd<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ type: ScrollPhysicsAnimationType) {
        if let scrollSnapState, isAnimatingScrollSnap {
            scrollSnapState.transitionToDestinationReachedState(&c, self)
            stopScrollSnapAnimation(&c)
        }

        if type == .rubberBand {
            didStopRubberBandAnimation(&c)
        }

        switch type {
        case .smooth, .keyboard:
            c.didStopAnimatedScroll()
        case .momentum, .rubberBand:
            break
        }

        if type == .keyboard {
            setIsAnimatingKeyboardScrolling(&c, false)
            c.removeWheelEventTestCompletionDeferral(.ScrollAnimationInProgress)
            return
        }

        startOrStopAnimationCallbacks(&c)
        c.removeWheelEventTestCompletionDeferral(.ScrollAnimationInProgress)
    }

    // MARK: Wheel events

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    ///
    /// `wheelEvent` is the caller's `const PlatformWheelEvent&` (ScrollAnimator, the scrolling tree's node delegates),
    /// live for the call. Swift passes it to the client's allowsHorizontalStretching() and allowsVerticalStretching()
    /// and to ScrollPhysicsClient::scrollingVelocity(), which only read it. Nothing else Swift calls (the other
    /// client members, AppKit) can reach it.
    ///
    /// The wheel event is borrowed in place, so the client's stretching checks get its address rather than a copy.
    /// A borrowed C++ value cannot be used in the right operand of || or &&, whose autoclosure would copy it, so
    /// conditions on it use ?: or commas.
    @_expose(Cxx)
    func handleWheelEvent(
        client c: inout WebCore.ScrollPhysicsClient,
        _ wheelEvent: borrowing @_addressable WebCore.PlatformWheelEvent,
        _ timestamp: Double
    ) -> Bool {
        return handleWheelEvent(&c, wheelEvent, timestamp)
    }

    // Inlined into each client's entry, so the body reads the caller's event in place: a specialization would take
    // it by value.
    @inline(always)
    func handleWheelEvent<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ wheelEvent: borrowing @_addressable WebCore.PlatformWheelEvent,
        _ timestamp: Double
    ) -> Bool {
        if processWheelEventForScrollSnap(&c, wheelEvent) {
            return true
        }

        if wheelEvent.phase() == .MayBegin ? true : wheelEvent.phase() == .Cancelled {
            return false
        }

        if wheelEvent.isEndOfNonMomentumScroll() ? true : wheelEvent.isEndOfMomentumScroll() {
            c.didStopWheelEventScroll()
        } else if wheelEvent.isGestureStart() ? true : wheelEvent.isTransitioningToMomentumScroll() {
            c.willStartWheelEventScroll()
        }

        let rawDelta = ScrollSize(wheelEvent.delta())

        if wheelEvent.phase() == .Began {
            // FIXME: Trying to decide if a gesture is horizontal or vertical at the "began" phase is very error-prone.
            let horizontalSide = targetSideForScrollDelta(-rawDelta, .Horizontal)
            let verticalSide = targetSideForScrollDelta(-rawDelta, .Vertical)

            if (horizontalSide != nil || verticalSide != nil) && !sideCanScrollOrStretch(&c, horizontalSide, rawDelta)
                && !sideCanScrollOrStretch(&c, verticalSide, rawDelta)
            {
                return false
            }

            momentumScrollInProgress = false
            ignoreMomentumScrolls = false
            lastMomentumScrollTimestamp = 0
            momentumVelocity = .zero
            cumulativeGestureDelta = .zero
            lastGestureEventTime = 0

            let stretchAmount = c.stretchAmount()
            stretchScrollForce.width = reboundDeltaForElasticDelta(Float(stretchAmount.width()))
            stretchScrollForce.height = reboundDeltaForElasticDelta(Float(stretchAmount.height()))
            unappliedOverscrollDelta = .zero

            stopRubberBandAnimation(&c)
            updateRubberBandingState(&c)
        }

        if wheelEvent.phase() == .Ended {
            // FIXME: This triggers the rubberband timer even when we don't start rubberbanding.
            startRubberBandAnimationIfNecessary(&c, wheelEvent)
            updateRubberBandingState(&c)
            return true
        }

        let isMomentumScrollEvent = wheelEvent.isMomentumEvent()
        if ignoreMomentumScrolls && (isMomentumScrollEvent || isAnimatingRubberBand) {
            if wheelEvent.momentumPhase() == .Ended {
                ignoreMomentumScrolls = false
                return true
            }

            if isMomentumScrollEvent && ignoreMomentumScrolls {
                return true
            }

            return false
        }

        let stretchAmount = c.stretchAmount()
        let isVerticallyStretched = stretchAmount.height() != 0
        let isHorizontallyStretched = stretchAmount.width() != 0

        // Much of this code, including this use of unaccelerated deltas when stretched, is based on AppKit behavior.
        let eventDelta =
            (isVerticallyStretched || isHorizontallyStretched) ? -ScrollSize(wheelEvent.unacceleratedScrollingDelta()) : -rawDelta

        // Reset unapplied overscroll because we may decide to remove delta at various points and put it into this value.
        var delta = unappliedOverscrollDelta
        unappliedOverscrollDelta = .zero
        delta += eventDelta

        if wheelEvent.isGestureEvent() {
            // Automation events are already directionally locked upstream in WKAppKitGestureController.
            let alreadyDirectionallyLocked = wheelEvent.inputSource() == .Automation

            // FIXME: This axis locking replicates what WheelEventDeltaFilter does. We should apply that to events in all phases, and remove axis locking here (webkit.org/b/231207).
            if !alreadyDirectionallyLocked {
                delta = deltaAlignedToPredominantGestureAxis(timestamp, delta)
            }
        }

        let momentumPhase = wheelEvent.momentumPhase()

        if momentumPhase == .Began {
            WebCore.ScrollPhysicsClient.momentumScrollBegan()
        }

        if !momentumScrollInProgress && (momentumPhase == .Began || momentumPhase == .Changed) {
            momentumScrollInProgress = true
        }

        var shouldStretch = false
        let timeDelta = timestamp - lastMomentumScrollTimestamp
        if inScrollGesture || momentumScrollInProgress {
            if lastMomentumScrollTimestamp != 0 && timeDelta > 0 && timeDelta < scrollVelocityZeroingTimeout {
                momentumVelocity = eventDelta / Float(timeDelta)
                lastMomentumScrollTimestamp = timestamp
            } else {
                lastMomentumScrollTimestamp = timestamp
                momentumVelocity = .zero
            }

            shouldStretch = modifyScrollDeltaForStretching(&c, wheelEvent, &delta, isHorizontallyStretched, isVerticallyStretched)
        }

        var handled = true

        if !delta.isZero {
            if shouldStretch || isVerticallyStretched || isHorizontallyStretched {
                if delta.width != 0, !c.allowsHorizontalStretching(wheelEvent) {
                    handled = false
                }

                if delta.height != 0, !c.allowsVerticalStretching(wheelEvent) {
                    handled = false
                }

                let canStartAnimation = applyScrollDeltaWithStretching(
                    &c,
                    wheelEvent,
                    delta,
                    isHorizontallyStretched,
                    isVerticallyStretched
                )
                if momentumScrollInProgress {
                    if canStartAnimation && lastMomentumScrollTimestamp != 0 {
                        ignoreMomentumScrolls = true
                        momentumScrollInProgress = false
                        startRubberBandAnimationIfNecessary(&c, wheelEvent)
                    }
                }
            } else {
                delta.scale(scrollWheelMultiplierValue)
                c.immediateScrollBy(delta.floatSize, .Clamped)
                if wheelEvent.phase() == .None, wheelEvent.momentumPhase() == .None {
                    c.startScrollendTimer()
                }
            }
        }

        if momentumScrollInProgress && momentumPhase == .Ended {
            WebCore.ScrollPhysicsClient.momentumScrollEnded()
            momentumScrollInProgress = false
            ignoreMomentumScrolls = false
            lastMomentumScrollTimestamp = 0
        }

        updateRubberBandingState(&c)

        return handled
    }

    private func sideCanScrollOrStretch<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ side: WebCore.BoxSide?,
        _ rawDelta: ScrollSize
    ) -> Bool {
        guard let side else {
            return false
        }
        return !c.isPinnedOnSide(side) || c.shouldRubberBandOnSide(side, rawDelta.floatSize)
    }

    private func deltaAlignedToPredominantGestureAxis(_ eventTime: Double, _ delta: ScrollSize) -> ScrollSize {
        if delta.isZero {
            return delta
        }

        // Bias the axis alignment to recent events by accumulating deltas in cumulativeGestureDelta,
        // decaying over time. This keeps gesture generally locked to an axis, but allows for
        // direction changes (e.g. an L-shaped scroll).
        // 120ms chosen empirically.
        if lastGestureEventTime != 0 {
            let decay = exp(-(eventTime - lastGestureEventTime) / gestureAxisDecayTimeConstant)
            cumulativeGestureDelta.scale(Float(stdMin(decay, 1.0)))
        }
        lastGestureEventTime = eventTime

        cumulativeGestureDelta.expand(abs(delta.width), abs(delta.height))

        if dominantAxisFavoringVertical(cumulativeGestureDelta) == .Vertical {
            return ScrollSize(width: 0, height: delta.height)
        }
        return deltaAlignedToHorizontalAxis(delta)
    }

    private func clampDeltaForAllowedAxes<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ wheelEvent: borrowing @_addressable WebCore.PlatformWheelEvent,
        _ delta: inout ScrollSize
    ) {
        if !c.allowsHorizontalStretching(wheelEvent) {
            delta.width = 0
        }

        if !c.allowsVerticalStretching(wheelEvent) {
            delta.height = 0
        }
    }

    private func modifyScrollDeltaForStretching<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ wheelEvent: borrowing @_addressable WebCore.PlatformWheelEvent,
        _ delta: inout ScrollSize,
        _ isHorizontallyStretched: Bool,
        _ isVerticallyStretched: Bool
    ) -> Bool {
        let allowsDiagonalRubberbanding = wheelEvent.inputSource() == .Automation

        let affectedSide = affectedSideOnDominantAxis(delta)
        let horizontalSide = targetSideForScrollDelta(delta, .Horizontal)
        let verticalSide = targetSideForScrollDelta(delta, .Vertical)

        if isVerticallyStretched {
            if !allowsDiagonalRubberbanding && !isHorizontallyStretched, let affectedSide, c.isPinnedOnSide(affectedSide) {
                // Stretching only in the vertical.
                if delta.height != 0 && abs(delta.width / delta.height) < rubberbandDirectionLockStretchRatio {
                    delta.width = 0
                } else if abs(delta.width) < rubberbandMinimumRequiredDeltaBeforeStretch {
                    unappliedOverscrollDelta.expand(delta.width, 0)
                    delta.width = 0
                } else {
                    unappliedOverscrollDelta.expand(delta.width, 0)
                }
            }

            return false
        }

        if isHorizontallyStretched {
            // Stretching only in the horizontal.
            if !allowsDiagonalRubberbanding, let affectedSide, c.isPinnedOnSide(affectedSide) {
                if delta.width != 0 && abs(delta.height / delta.width) < rubberbandDirectionLockStretchRatio {
                    delta.height = 0
                } else if abs(delta.height) < rubberbandMinimumRequiredDeltaBeforeStretch {
                    unappliedOverscrollDelta.expand(0, delta.height)
                    delta.height = 0
                } else {
                    unappliedOverscrollDelta.expand(0, delta.height)
                }
            }

            return false
        }

        let horizontalDeltaAffectsPinnedSide = horizontalSide.map { c.isPinnedOnSide($0) } ?? false
        let verticalDeltaAffectsPinnedSide = verticalSide.map { c.isPinnedOnSide($0) } ?? false

        if horizontalDeltaAffectsPinnedSide || verticalDeltaAffectsPinnedSide {
            if !allowsDiagonalRubberbanding && abs(delta.height) >= abs(delta.width) {
                if abs(delta.width) < rubberbandMinimumRequiredDeltaBeforeStretch {
                    unappliedOverscrollDelta.expand(delta.width, 0)
                    delta.width = 0
                } else {
                    unappliedOverscrollDelta.expand(delta.width, 0)
                }
            }

            if horizontalDeltaAffectsPinnedSide, !c.allowsHorizontalStretching(wheelEvent) {
                delta.width = 0
            }

            if verticalDeltaAffectsPinnedSide, !c.allowsVerticalStretching(wheelEvent) {
                delta.height = 0
            }

            return !delta.isZero
        }

        return false
    }

    private func adjustedForRefreshController<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ delta: ScrollSize,
        _ verticalDeltaOpposesStretch: Bool
    ) -> ScrollSize {
        // When pulling down to reveal a refresh control, reduce the rubber band stiffness
        // to make it easier to pull.

        if !c.hasRefreshController() {
            skipAdditionalDeltaAdjustments = false
            return delta
        }

        let stretchAmount = c.stretchAmount()
        var adjustedDelta = delta

        let refreshControlDynamicDampeningThreshold = c.refreshControllerSnappingThreshold()
        let minimumStiffnessFactor: Float = 0.1
        let stiffnessRange: Float = 0.9

        let verticalStretch = abs(Float(stretchAmount.height()))

        if verticalStretch < 1 {
            skipAdditionalDeltaAdjustments = false
        }

        if delta.height != 0 && stretchAmount.height() < 0 && !verticalDeltaOpposesStretch {
            if !skipAdditionalDeltaAdjustments && verticalStretch < refreshControlDynamicDampeningThreshold {
                let progress = verticalStretch / refreshControlDynamicDampeningThreshold

                // Quartic curve: starts at 10% stiffness, ramps up to 100%. The last multiply-add is fused,
                // as -ffp-contract=on fuses the C++ expression.
                let stiffnessRatio = minimumStiffnessFactor.addingProduct(stiffnessRange * progress * progress * progress, progress)
                adjustedDelta.height = delta.height / stiffnessRatio

                // Lock in full stiffness once the threshold is crossed to prevent oscillation.
                if verticalStretch >= refreshControlDynamicDampeningThreshold {
                    skipAdditionalDeltaAdjustments = true
                }
            } else {
                skipAdditionalDeltaAdjustments = true
            }
        }

        return adjustedDelta
    }

    private func shouldAttemptRubberbandingRestoration<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ state: WebCore.RubberbandingState
    ) -> Bool {
        let isTopStretched = state.rubberbandingEdges[.Top] || state.initialOverscroll.height() < 0
        let isValidState = !ScrollSize(state.initialOverscroll).isZero || !ScrollSize(state.initialVelocity).isZero
        return c.hasRefreshController() && isTopStretched && isValidState
    }

    private func applyScrollDeltaWithStretching<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ wheelEvent: borrowing @_addressable WebCore.PlatformWheelEvent,
        _ originalDelta: ScrollSize,
        _ isHorizontallyStretched: Bool,
        _ isVerticallyStretched: Bool
    ) -> Bool {
        var delta = originalDelta
        var eventDelta =
            (isVerticallyStretched || isHorizontallyStretched)
            ? -ScrollSize(wheelEvent.unacceleratedScrollingDelta()) : -ScrollSize(wheelEvent.delta())

        let horizontalSide = targetSideForScrollDelta(delta, .Horizontal)
        let verticalSide = targetSideForScrollDelta(delta, .Vertical)

        let horizontalDeltaOpposesStretch = isHorizontallyStretched && c.isScrollDeltaOpposingStretch(.Horizontal, delta.width)
        let verticalDeltaOpposesStretch = isVerticallyStretched && c.isScrollDeltaOpposingStretch(.Vertical, delta.height)

        let allowsDiagonalRubberbanding = wheelEvent.inputSource() == .Automation
        let canScrollHorizontally = !isHorizontallyStretched && (horizontalSide.map { !c.isPinnedOnSide($0) } ?? false)
        let canScrollVertically = !isVerticallyStretched && (verticalSide.map { !c.isPinnedOnSide($0) } ?? false)

        var deltaToScroll = ScrollSize.zero
        if delta.width != 0 {
            if canScrollHorizontally, allowsDiagonalRubberbanding ? true : c.allowsHorizontalStretching(wheelEvent) {
                delta.scale(scrollWheelMultiplierValue, 1)
                deltaToScroll += ScrollSize(width: delta.width, height: 0)
                delta.width = 0
            } else if !c.allowsHorizontalStretching(wheelEvent) {
                delta.width = 0
                eventDelta.width = 0
            }
        }

        if delta.height != 0 {
            if canScrollVertically, allowsDiagonalRubberbanding ? true : c.allowsVerticalStretching(wheelEvent) {
                delta.scale(1, scrollWheelMultiplierValue)
                deltaToScroll += ScrollSize(width: 0, height: delta.height)
                delta.height = 0
            } else if !c.allowsVerticalStretching(wheelEvent) {
                delta.height = 0
                eventDelta.height = 0
            }
        }

        if !deltaToScroll.isZero {
            c.immediateScrollBy(deltaToScroll.floatSize, .Unclamped)
        }

        var canStartAnimation = false
        if momentumScrollInProgress {
            // Compute canStartAnimation, which looks at isPinnedOnSide(), before applying the stretch delta.
            if let sideAffectedByEventDelta = affectedSideOnDominantAxis(eventDelta) {
                canStartAnimation = c.isPinnedOnSide(sideAffectedByEventDelta)
            } else {
                canStartAnimation = true
            }
        }

        if delta.isZero {
            return canStartAnimation
        }

        let stretchAmount = c.stretchAmount()

        let adjustedDelta = adjustedForRefreshController(&c, delta, verticalDeltaOpposesStretch)
        var stretchScrollForceDelta = adjustedDelta

        if horizontalDeltaOpposesStretch {
            stretchScrollForceDelta.width = 0
        }
        if verticalDeltaOpposesStretch {
            stretchScrollForceDelta.height = 0
        }

        stretchScrollForce += stretchScrollForceDelta

        var dampedDelta = ScrollSize.zero

        if horizontalDeltaOpposesStretch {
            dampedDelta.width = adjustedDelta.width
        } else if adjustedDelta.width != 0 {
            let dampedWidth = elasticDeltaForReboundDelta(stretchScrollForce.width).rounded(.up)
            dampedDelta.width = dampedWidth - Float(stretchAmount.width())
        }

        if verticalDeltaOpposesStretch {
            dampedDelta.height = adjustedDelta.height
        } else if adjustedDelta.height != 0 {
            let dampedHeight = elasticDeltaForReboundDelta(stretchScrollForce.height).rounded(.up)
            dampedDelta.height = dampedHeight - Float(stretchAmount.height())
        }

        clampDeltaForAllowedAxes(&c, wheelEvent, &dampedDelta)

        c.immediateScrollBy(dampedDelta.floatSize, .Unclamped)

        return canStartAnimation
    }

    // MARK: Rubber banding

    // Called every animation frame, and most frames are not rubber banding: test for it in the caller's frame.
    @inline(always)
    private func updateRubberBandAnimatingState<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        if !isAnimatingRubberBand {
            return
        }
        updateRubberBandAnimatingStateWhileAnimating(&c)
    }

    @inline(never)
    private func updateRubberBandAnimatingStateWhileAnimating<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        if usesScrollSnap && (inScrollGesture || momentumScrollInProgress || isAnimatingScrollSnap || c.isDiscreteSnapTimerActive()) {
            return
        }

        if momentumScrollInProgress && !ignoreMomentumScrolls {
            if !isRubberBandInProgressInternal(&c) {
                stopRubberBandAnimation(&c)
            }
        }

        updateRubberBandingState(&c)
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func scrollPositionChanged(client c: inout WebCore.ScrollPhysicsClient) {
        scrollPositionChanged(&c)
    }

    func scrollPositionChanged<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        updateRubberBandingState(&c)
    }

    @_expose(Cxx)
    func isUserScrollInProgress() -> Bool {
        inScrollGesture
    }

    @_expose(Cxx)
    func isRubberBandInProgress() -> Bool {
        isRubberBanding
    }

    @_expose(Cxx)
    func rubberBandingEdges() -> WebCore.RubberBandingEdges {
        var edges = WebCore.RubberBandingEdges()
        edges.setTop(rubberBandingEdgeTop)
        edges.setRight(rubberBandingEdgeRight)
        edges.setBottom(rubberBandingEdgeBottom)
        edges.setLeft(rubberBandingEdgeLeft)
        return edges
    }

    @_expose(Cxx)
    func isScrollSnapInProgress(_ discreteSnapTransitionTimerIsActive: Bool) -> Bool {
        if !usesScrollSnap {
            return false
        }

        if inScrollGesture || momentumScrollInProgress || isAnimatingScrollSnap {
            return true
        }

        return discreteSnapTransitionTimerIsActive
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func stopRubberBanding(client c: inout WebCore.ScrollPhysicsClient) {
        stopRubberBanding(&c)
    }

    func stopRubberBanding<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        stopRubberBandAnimation(&c)
        updateRubberBandingState(&c)
    }

    private func startRubberBandAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ initialVelocity: ScrollSize,
        _ initialOverscroll: ScrollSize
    ) -> Bool {
        stopCurrentAnimation(&c)

        rubberBandAnimation.reset()
        setCurrentAnimationType(.rubberBand)
        let targetOffset = ScrollSize(c.rubberBandTargetOffset())

        return rubberBandAnimation.startRubberBandAnimation(&c, self, initialVelocity, initialOverscroll, targetOffset)
    }

    private func startRubberBandAnimationWithElapsedTime<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ initialVelocity: ScrollSize,
        _ initialOverscroll: ScrollSize,
        _ alreadyElapsed: Double,
        _ targetOverscroll: ScrollSize
    ) -> Bool {
        stopCurrentAnimation(&c)

        rubberBandAnimation.reset()
        setCurrentAnimationType(.rubberBand)
        // The client is asked for its target offset, which the given target overrides.
        _ = c.rubberBandTargetOffset()
        let targetOffset = targetOverscroll

        return rubberBandAnimation.startRubberBandAnimationWithElapsedTime(
            &c,
            self,
            initialVelocity,
            initialOverscroll,
            alreadyElapsed,
            targetOffset
        )
    }

    private func stopRubberBandAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        if isAnimatingRubberBand {
            stopAnimatedScroll(&c)
        }

        stretchScrollForce = .zero
    }

    private func willStartRubberBandAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        isAnimatingRubberBand = true
        c.willStartRubberBandAnimation()
        c.deferWheelEventTestCompletion(.RubberbandInProgress)
    }

    private func didStopRubberBandAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        isAnimatingRubberBand = false
        c.didStopRubberBandAnimation()
        c.removeWheelEventTestCompletionDeferral(.RubberbandInProgress)
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func startRubberBandSnapBack(client c: inout WebCore.ScrollPhysicsClient) {
        startRubberBandSnapBack(&c)
    }

    func startRubberBandSnapBack<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        let stretchAmount = c.stretchAmount()
        if isZero(stretchAmount) {
            return
        }

        stopCurrentAnimation(&c)

        _ = startRubberBandAnimation(&c, .zero, ScrollSize(stretchAmount))
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func rubberBandTargetOffsetDidChange(client c: inout WebCore.ScrollPhysicsClient) {
        rubberBandTargetOffsetDidChange(&c)
    }

    func rubberBandTargetOffsetDidChange<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        if !isAnimatingRubberBand {
            return
        }

        let stretchAmount = c.stretchAmount()
        if isZero(stretchAmount) {
            return
        }

        _ = startRubberBandAnimation(&c, .zero, ScrollSize(stretchAmount))
    }

    private func startRubberBandAnimationIfNecessary<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ wheelEvent: WebCore.PlatformWheelEvent
    ) {
        let timeDelta = scrollPhysicsClockNow() - lastMomentumScrollTimestamp
        if lastMomentumScrollTimestamp != 0 && timeDelta >= scrollVelocityZeroingTimeout {
            momentumVelocity = .zero
        }

        if isAnimatingRubberBand {
            return
        }

        let extents = ScrollPhysicsExtents(c.scrollExtents())
        let targetOffset = ScrollPoint(c.scrollOffset())
        let constrainedOffset = targetOffset.constrainedBetween(extents.minimumScrollOffset, extents.maximumScrollOffset)
        let willOverscroll = targetOffset != constrainedOffset

        let stretchAmount = c.stretchAmount()
        if isZero(stretchAmount) && !willOverscroll && stretchScrollForce.isZero {
            return
        }

        var initialVelocity = momentumVelocity

        let allowsDiagonalRubberbanding = wheelEvent.inputSource() == .Automation
        if allowsDiagonalRubberbanding {
            let isHorizontallyStretched =
                stretchAmount.width() != 0 || targetOffset.x != constrainedOffset.x || stretchScrollForce.width != 0
            let isVerticallyStretched =
                stretchAmount.height() != 0 || targetOffset.y != constrainedOffset.y || stretchScrollForce.height != 0
            if !isHorizontallyStretched {
                initialVelocity.width = 0
            }
            if !isVerticallyStretched {
                initialVelocity.height = 0
            }
        }

        // Just like normal scrolling, prefer vertical rubberbanding
        if abs(initialVelocity.height) >= abs(initialVelocity.width) {
            initialVelocity.width = 0
        }

        // Don't rubber-band horizontally if it's not possible to scroll horizontally
        if !c.allowsHorizontalScrolling() {
            initialVelocity.width = 0
        }

        // Don't rubber-band vertically if it's not possible to scroll vertically
        if !c.allowsVerticalScrolling() {
            initialVelocity.height = 0
        }

        _ = startRubberBandAnimation(&c, initialVelocity, ScrollSize(stretchAmount))
    }

    private func isRubberBandInProgressInternal<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) -> Bool {
        if !inScrollGesture && !momentumScrollInProgress && !isAnimatingRubberBand {
            return false
        }

        return !isZero(c.stretchAmount())
    }

    // Called on every wheel event, and the rubber-banding state rarely changes: test for a change in the caller's frame.
    @inline(always)
    private func updateRubberBandingState<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        let isRubberBanding = isRubberBandInProgressInternal(&c)
        if isRubberBanding == self.isRubberBanding {
            return
        }

        rubberBandingStateDidChange(&c, isRubberBanding)
    }

    @inline(never)
    private func rubberBandingStateDidChange<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ isRubberBanding: Bool) {
        self.isRubberBanding = isRubberBanding
        if isRubberBanding {
            updateRubberBandingEdges(c.stretchAmount())
        } else {
            rubberBandingEdgeTop = false
            rubberBandingEdgeRight = false
            rubberBandingEdgeBottom = false
            rubberBandingEdgeLeft = false
        }

        c.rubberBandingStateChanged(isRubberBanding)
    }

    private func updateRubberBandingEdges(_ clientStretch: WebCore.IntSize) {
        rubberBandingEdgeLeft = clientStretch.width() < 0
        rubberBandingEdgeRight = clientStretch.width() > 0

        rubberBandingEdgeTop = clientStretch.height() < 0
        rubberBandingEdgeBottom = clientStretch.height() > 0
    }

    // MARK: Scroll snap from wheel events

    private func shouldOverrideMomentumScrolling() -> Bool {
        guard let scrollSnapState else {
            return false
        }

        let state = scrollSnapState.currentState
        return state == .gliding || state == .destinationReached
    }

    private func scheduleDiscreteScrollSnap<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ delta: ScrollSize) {
        stopScrollSnapAnimation(&c)
        if c.stopDiscreteSnapTimer() {
            recentDiscreteWheelDeltas.append(delta)
            if recentDiscreteWheelDeltas.count > numberOfDeltasToStoreForDiscreteScrollSnap {
                recentDiscreteWheelDeltas.removeFirst()
            }
        } else {
            recentDiscreteWheelDeltas = RecentWheelDeltas(delta)
        }

        if !usesScrollSnap {
            return
        }

        c.startDiscreteSnapTimer()
        c.deferWheelEventTestCompletion(.ScrollSnapInProgress)
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    @_expose(Cxx)
    func discreteSnapTransitionTimerFired(client c: inout WebCore.ScrollPhysicsClient) {
        discreteSnapTransitionTimerFired(&c)
    }

    func discreteSnapTransitionTimerFired<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        let recentDiscreteWheelDeltas = self.recentDiscreteWheelDeltas
        self.recentDiscreteWheelDeltas = RecentWheelDeltas()

        guard let scrollSnapState else {
            return
        }

        var wheelDeltaForGlideAnimation = ScrollSize.zero
        if !recentDiscreteWheelDeltas.isEmpty {
            for index in 0..<recentDiscreteWheelDeltas.count {
                wheelDeltaForGlideAnimation += recentDiscreteWheelDeltas.delta(at: index)
            }
            func signOf(_ value: Float) -> Float {
                value > 0 ? 1 : (value < 0 ? -1 : 0)
            }
            wheelDeltaForGlideAnimation.width = signOf(wheelDeltaForGlideAnimation.width)
            wheelDeltaForGlideAnimation.height = signOf(wheelDeltaForGlideAnimation.height)
        }

        let extents = ScrollPhysicsExtents(c.scrollExtents())
        let pageScale = c.pageScaleFactor()
        let scrollOffset = ScrollPoint(c.scrollOffset())
        let shouldStartScrollSnapAnimation: Bool
        if wheelDeltaForGlideAnimation.isZero {
            shouldStartScrollSnapAnimation = scrollSnapState.transitionToSnapAnimationState(&c, self, extents, pageScale, scrollOffset)
        } else {
            shouldStartScrollSnapAnimation = scrollSnapState.transitionToGlideAnimationState(
                &c,
                self,
                extents,
                pageScale,
                scrollOffset,
                -wheelDeltaForGlideAnimation,
                -wheelDeltaForGlideAnimation
            )
        }

        if shouldStartScrollSnapAnimation {
            startScrollSnapAnimation(&c)
        } else {
            c.removeWheelEventTestCompletionDeferral(.ScrollSnapInProgress)
            c.didStopScrollSnapAnimation()
        }
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    ///
    /// `wheelEvent` is the caller's `const PlatformWheelEvent&`, or handleWheelEvent()'s, live for the call. Swift
    /// passes it only to ScrollPhysicsClient::scrollingVelocity(), which reads it. No client member can reach it.
    ///
    /// Most scrollers have no snap state: test for it before setting up the frame the snapping work needs.
    @_expose(Cxx)
    func processWheelEventForScrollSnap(
        client c: inout WebCore.ScrollPhysicsClient,
        _ wheelEvent: borrowing @_addressable WebCore.PlatformWheelEvent
    ) -> Bool {
        return processWheelEventForScrollSnap(&c, wheelEvent)
    }

    @inline(always)
    func processWheelEventForScrollSnap<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ wheelEvent: borrowing @_addressable WebCore.PlatformWheelEvent
    ) -> Bool {
        guard let scrollSnapState else {
            return false
        }
        return processWheelEventForScrollSnap(&c, wheelEvent, scrollSnapState)
    }

    @inline(never)
    private func processWheelEventForScrollSnap<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ wheelEvent: borrowing @_addressable WebCore.PlatformWheelEvent,
        _ scrollSnapState: ScrollSnapAnimationState
    ) -> Bool {
        if !scrollSnapState.hasSnapOffsets(.Horizontal) && !scrollSnapState.hasSnapOffsets(.Vertical) {
            return false
        }

        let status = WheelEventStatus(wheelEvent.phase(), wheelEvent.momentumPhase())

        var isMomentumScrolling = false
        switch status {
        case .userScrollBegin, .userScrolling:
            stopScrollSnapAnimation(&c)
            scrollSnapState.transitionToUserInteractionState(&c, self)
            scrollingVelocityForScrollSnap = -ScrollSize(WebCore.ScrollPhysicsClient.scrollingVelocity(wheelEvent))
        case .userScrollEnd:
            let extents = ScrollPhysicsExtents(c.scrollExtents())
            let pageScale = c.pageScaleFactor()
            let scrollOffset = ScrollPoint(c.scrollOffset())
            if scrollSnapState.transitionToSnapAnimationState(&c, self, extents, pageScale, scrollOffset) {
                startScrollSnapAnimation(&c)
            }
        case .momentumScrollBegin:
            let extents = ScrollPhysicsExtents(c.scrollExtents())
            let pageScale = c.pageScaleFactor()
            let scrollOffset = ScrollPoint(c.scrollOffset())
            if scrollSnapState.transitionToGlideAnimationState(
                &c,
                self,
                extents,
                pageScale,
                scrollOffset,
                scrollingVelocityForScrollSnap,
                -ScrollSize(wheelEvent.delta())
            ) {
                startScrollSnapAnimation(&c)
                isMomentumScrolling = true
            }
            scrollingVelocityForScrollSnap = .zero
        case .momentumScrolling, .momentumScrollEnd:
            isMomentumScrolling = true
        case .discreteScrollEvent:
            scrollSnapState.transitionToUserInteractionState(&c, self)
            scheduleDiscreteScrollSnap(&c, ScrollSize(wheelEvent.delta()))
        case .momentumScrollWillBegin, .unknown:
            break
        }

        return isMomentumScrolling && shouldOverrideMomentumScrolling()
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    ///
    /// `wheelEvent` is the caller's `const PlatformWheelEvent&`. It is read before any client call, and no client
    /// member can reach it.
    @_expose(Cxx)
    func updateGestureInProgressState(client c: inout WebCore.ScrollPhysicsClient, _ wheelEvent: WebCore.PlatformWheelEvent) {
        updateGestureInProgressState(&c, wheelEvent)
    }

    func updateGestureInProgressState<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ wheelEvent: WebCore.PlatformWheelEvent) {
        if wheelEvent.isGestureStart() || wheelEvent.isTransitioningToMomentumScroll() {
            inScrollGesture = true
        } else if wheelEvent.isEndOfNonMomentumScroll() || wheelEvent.isGestureCancel() || wheelEvent.isEndOfMomentumScroll() {
            inScrollGesture = false
        }

        updateRubberBandingState(&c)
    }

    // MARK: Rubber banding state across a swap of scrolling trees

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    ///
    /// `state` is a local of ScrollingEffectsController::captureRubberbandingState(). The client members Swift calls
    /// (stretchAmount(), rubberBandTargetOffset()) and the clock cannot reach it.
    ///
    /// Returns false where ScrollingEffectsController::captureRubberbandingState() returns nullopt.
    @_expose(Cxx)
    func captureRubberbandingState(client c: inout WebCore.ScrollPhysicsClient, _ state: inout WebCore.RubberbandingState) -> Bool {
        return captureRubberbandingState(&c, &state)
    }

    func captureRubberbandingState<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ state: inout WebCore.RubberbandingState
    ) -> Bool {
        let stretchAmount = c.stretchAmount()

        if isZero(stretchAmount) {
            return false
        }

        state.captureTime = WebCore.scrollingEffectsClockNow()
        state.rubberbandingEdges.setTop(rubberBandingEdgeTop)
        state.rubberbandingEdges.setRight(rubberBandingEdgeRight)
        state.rubberbandingEdges.setBottom(rubberBandingEdgeBottom)
        state.rubberbandingEdges.setLeft(rubberBandingEdgeLeft)

        if currentAnimationType == .rubberBand, rubberBandAnimation.isActive {
            state.initialVelocity = rubberBandAnimation.initialVelocity.floatSize
            state.initialOverscroll = rubberBandAnimation.initialOverscroll.floatSize
            state.targetOverscroll = rubberBandAnimation.targetOverscroll.floatSize
            state.animationStartTime = WebCore.ScrollPhysicsClient.monotonicTime(rubberBandAnimation.startTime)
            return true
        }

        state.initialVelocity = ScrollSize.zero.floatSize
        state.initialOverscroll = ScrollSize(stretchAmount).floatSize
        state.targetOverscroll = c.rubberBandTargetOffset()
        state.animationStartTime = WebCore.scrollingEffectsClockNow()

        return true
    }

    /// `c` is made for this call on the calling ScrollingEffectsController member's stack; nothing else reaches it.
    ///
    /// `state` is the caller's `const RubberbandingState&`: ScrollingTreeScrollingNodeDelegateMac passes its
    /// pending state. Every read of it is done before startRubberBandAnimationWithElapsedTime() calls the client;
    /// the only client member called before then, hasRefreshController(), does not change it.
    @_expose(Cxx)
    func restoreRubberbandingState(client c: inout WebCore.ScrollPhysicsClient, _ state: WebCore.RubberbandingState) -> Bool {
        return restoreRubberbandingState(&c, state)
    }

    func restoreRubberbandingState<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ state: WebCore.RubberbandingState) -> Bool {
        if !shouldAttemptRubberbandingRestoration(&c, state) {
            return false
        }

        let now = scrollPhysicsClockNow()
        let captureTime = state.captureTime.secondsSinceEpoch().value()
        let timeSinceCapture = now - captureTime
        let totalElapsed = (captureTime - state.animationStartTime.secondsSinceEpoch().value()) + timeSinceCapture

        rubberBandingEdgeTop = state.rubberbandingEdges[.Top]
        rubberBandingEdgeRight = state.rubberbandingEdges[.Right]
        rubberBandingEdgeBottom = state.rubberbandingEdges[.Bottom]
        rubberBandingEdgeLeft = state.rubberbandingEdges[.Left]
        isRubberBanding = true

        let started = startRubberBandAnimationWithElapsedTime(
            &c,
            ScrollSize(state.initialVelocity),
            ScrollSize(state.initialOverscroll),
            totalElapsed,
            ScrollSize(state.targetOverscroll)
        )

        if let type = currentAnimationType, started {
            serviceAnimation(&c, type, now)
        }

        return started
    }
}

// A ScrollOffset (IntPoint), as roundedIntPoint(FloatPoint) makes it.
struct ScrollIntPoint: Equatable {
    var x: Int32
    var y: Int32
}

func roundedIntPoint(_ point: ScrollPoint) -> ScrollIntPoint {
    ScrollIntPoint(x: clampToInt32(point.x.rounded()), y: clampToInt32(point.y.rounded()))
}
