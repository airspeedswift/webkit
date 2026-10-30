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

// What ScrollPhysicsController, its animations and its snap state call on their client: ScrollPhysicsClient's
// members. Each @_expose(Cxx) entry takes a ScrollPhysicsClient and calls the generic member of the same name.

internal import WebCore_Private.Core.PlatformWheelEvent
internal import WebCore_Private.Core.ScrollExtents
internal import WebCore_Private.Core.ScrollSnapOffsetsInfo
internal import WebCore_Private.ScrollPhysicsTypes

protocol ScrollPhysicsClientProtocol: ~Copyable {
    mutating func startAnimationCallback()
    mutating func stopAnimationCallback()

    mutating func allowsHorizontalScrolling() -> Bool
    mutating func allowsVerticalScrolling() -> Bool
    mutating func immediateScrollBy(_ delta: WebCore.FloatSize, _ clamping: WebCore.ScrollClamping)

    mutating func allowsHorizontalStretching(_ event: borrowing @_addressable WebCore.PlatformWheelEvent) -> Bool
    mutating func allowsVerticalStretching(_ event: borrowing @_addressable WebCore.PlatformWheelEvent) -> Bool
    mutating func stretchAmount() -> WebCore.IntSize
    mutating func isScrollDeltaOpposingStretch(_ axis: WebCore.ScrollEventAxis, _ delta: Float) -> Bool
    mutating func isPinnedOnSide(_ side: WebCore.BoxSide) -> Bool
    mutating func shouldRubberBandOnSide(_ side: WebCore.BoxSide, _ delta: WebCore.FloatSize) -> Bool
    mutating func willStartRubberBandAnimation()
    mutating func didStopRubberBandAnimation()
    mutating func rubberBandingStateChanged(_ isRubberBanding: Bool)
    mutating func rubberBandTargetOffset() -> WebCore.FloatSize
    mutating func hasRefreshController() -> Bool
    mutating func refreshControllerSnappingThreshold() -> Float

    mutating func deferWheelEventTestCompletion(_ reason: WebCore.WheelEventTestMonitorDeferReason)
    mutating func removeWheelEventTestCompletionDeferral(_ reason: WebCore.WheelEventTestMonitorDeferReason)

    mutating func scrollOffset() -> WebCore.FloatPoint
    mutating func willStartAnimatedScroll()
    mutating func didStopAnimatedScroll()
    mutating func willStartWheelEventScroll()
    mutating func didStopWheelEventScroll()
    mutating func willStartScrollSnapAnimation()
    mutating func didStopScrollSnapAnimation()
    mutating func pageScaleFactor() -> Float
    mutating func scrollExtents() -> WebCore.ScrollExtents

    mutating func snapOffsetCount(_ axis: WebCore.ScrollEventAxis) -> CUnsignedInt
    mutating func snapOffset(_ axis: WebCore.ScrollEventAxis, _ index: CUnsignedInt) -> WebCore.LayoutUnit
    mutating func snapOffsetIsFocused(_ axis: WebCore.ScrollEventAxis, _ index: CUnsignedInt) -> Bool
    mutating func snapOffsetIsTarget(_ axis: WebCore.ScrollEventAxis, _ index: CUnsignedInt) -> Bool
    mutating func snapOffsetTargetID(_ axis: WebCore.ScrollEventAxis, _ index: CUnsignedInt) -> UInt64
    mutating func snapOffsetAreaIndexCount(_ axis: WebCore.ScrollEventAxis, _ index: CUnsignedInt) -> CUnsignedInt
    mutating func snapOffsetAreaIndex(_ axis: WebCore.ScrollEventAxis, _ index: CUnsignedInt, _ areaIndex: CUnsignedInt) -> Int
    mutating func snapAreaCount() -> CUnsignedInt
    mutating func snapArea(_ index: CUnsignedInt) -> WebCore.LayoutRect
    mutating func snapAreaIDCount() -> CUnsignedInt
    mutating func snapAreaID(_ index: CUnsignedInt) -> UInt64
    mutating func scrollerHasVerticalWritingMode() -> Bool
    mutating func snapOffsetStopsAlways(_ axis: WebCore.ScrollEventAxis, _ index: CUnsignedInt) -> Bool
    mutating func snapOffsetHasSnapAreaLargerThanViewport(_ axis: WebCore.ScrollEventAxis, _ index: CUnsignedInt) -> Bool
    mutating func snapStrictnessIsProximity() -> Bool

    mutating func isDiscreteSnapTimerActive() -> Bool
    mutating func startDiscreteSnapTimer()
    mutating func stopDiscreteSnapTimer() -> Bool
    mutating func startScrollendTimer()
}
