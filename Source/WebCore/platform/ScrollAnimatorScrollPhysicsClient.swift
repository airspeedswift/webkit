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
}
