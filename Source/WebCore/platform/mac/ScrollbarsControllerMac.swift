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

// ScrollbarsControllerMac's state and the delegates of its NSScrollerImpPair, which drive a ScrollableArea's scrollbars
// through AppKit on the main thread.

// PLATFORM(MAC), as ScrollbarsControllerMac.mm, the C++ this replaces.
#if os(macOS)

internal import AppKit
internal import QuartzCore
internal import WebCore_Private.Core.FloatPoint
internal import WebCore_Private.Core.FloatRect
internal import WebCore_Private.Core.FloatSize
internal import WebCore_Private.Core.IntPoint
internal import WebCore_Private.Core.IntRect
internal import WebCore_Private.Core.IntSize
internal import WebCore_Private.Core.NSScrollerImpDetails
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.Core.TimingFunction
internal import WebCore_Private.ScrollbarsControllerMacTypes
internal import pal.spi.mac.NSScrollerImpSPI
internal import wtf.Core.text.Latin1Character
internal import wtf.Core.text.WTFString

private func nsPoint(_ point: WebCore.IntPoint) -> NSPoint {
    NSPoint(x: CGFloat(point.x()), y: CGFloat(point.y()))
}

/// The delegate of a ScrollbarsControllerMac's NSScrollerImpPair.
@objc(WebScrollerImpPairDelegate)
final class WebScrollerImpPairDelegate: NSObject, NSScrollerImpPairDelegate {
    /// The ScrollableArea, held weakly.
    ///
    /// The callbacks stop reading it once invalidate() has been called.
    private let area: WebCore.ScrollbarsControllerMacArea
    private var isInvalidated = false
    /// The state of the ScrollbarsControllerMac that holds this delegate, which its scrollbars' NSScrollerImp
    /// delegates also read.
    weak var controller: MacScrollbarsController?

    init(_ area: consuming WebCore.ScrollbarsControllerMacArea) {
        self.area = area
        super.init()
    }

    /// Called on the main thread by ScrollbarsControllerMac's destructor.
    func invalidate() {
        isInvalidated = true
    }

    /// AppKit calls this on the main thread.
    @objc(contentAreaRectForScrollerImpPair:)
    @inline(always)
    func contentAreaRect(for scrollerImpPair: NSScrollerImpPair!) -> NSRect {
        guard !isInvalidated, area.isLive() else {
            return .zero
        }

        let contentsSize = area.contentsSize()
        return NSRect(x: 0, y: 0, width: CGFloat(contentsSize.width()), height: CGFloat(contentsSize.height()))
    }

    /// AppKit calls this on the main thread.
    @objc(inLiveResizeForScrollerImpPair:)
    @inline(always)
    func inLiveResize(for scrollerImpPair: NSScrollerImpPair!) -> Bool {
        guard !isInvalidated else {
            return false
        }

        return area.inLiveResize()
    }

    /// AppKit calls this on the main thread.
    @objc(mouseLocationInContentAreaForScrollerImpPair:)
    @inline(always)
    func mouseLocationInContentArea(for scrollerImpPair: NSScrollerImpPair!) -> NSPoint {
        guard !isInvalidated, area.isLive() else {
            return .zero
        }

        // It's OK that this position isn't relative to this scroller (which might be an overflow scroller).
        // AppKit just takes the result and passes it back to -scrollerImpPair:convertContentPoint:toScrollerImp:.
        return nsPoint(area.lastKnownMousePositionInView())
    }

    /// AppKit calls this on the main thread.
    @inline(always)
    func scrollerImpPair(
        _ scrollerImpPair: NSScrollerImpPair!,
        convertContentPoint pointInContentArea: NSPoint,
        to scrollerImp: NSScrollerImp!
    ) -> NSPoint {
        guard !isInvalidated, area.isLive(), let scrollerImp else {
            return .zero
        }

        // The scrollbar can be null here: this can be called between the moment a scrollbar has been cleared and the
        // moment its destructor runs.
        let scrollbar = area.scrollbar(scrollerImp.isHorizontal ? .Horizontal : .Vertical)
        guard scrollbar.isLive() else {
            return .zero
        }

        return nsPoint(scrollbar.convertFromContainingView(WebCore.roundedIntPoint(pointInContentArea)))
    }

    /// AppKit calls this on the main thread.
    func scrollerImpPair(_ scrollerImpPair: NSScrollerImpPair!, setContentAreaNeedsDisplayIn rect: NSRect) {
        guard !isInvalidated, area.isLive() else {
            return
        }

        if scrollerImpPair?.overlayScrollerStateIsLocked() == true {
            return
        }

        controller?.contentAreaWillPaint()
    }

    /// AppKit calls this on the main thread.
    func scrollerImpPair(
        _ scrollerImpPair: NSScrollerImpPair!,
        updateScrollerStyleForNewRecommendedScrollerStyle newRecommendedScrollerStyle: NSScroller.Style
    ) {
        guard !isInvalidated, area.isLive() else {
            return
        }

        scrollerImpPair?.scrollerStyle = newRecommendedScrollerStyle
        controller?.updateScrollerStyle()
    }
}

/// The part of an NSScrollerImp a WebScrollbarPartAnimation animates.
private enum FeatureToAnimate {
    case thumbAlpha
    case trackAlpha
    case uiStateTransition
    case expansionTransition
}

/// Animates one part of a scrollbar's NSScrollerImp from 0 to 1, or from 1 to 0, on a timer on the main run loop.
@objc(WebScrollbarPartAnimation)
final class WebScrollbarPartAnimation: NSObject {
    private var scrollbar: Optional<WebCore.ScrollbarsControllerMacScrollbar>
    private var scrollerImp: NSScrollerImp?
    private let featureToAnimate: FeatureToAnimate
    var startValue: CGFloat
    var endValue: CGFloat
    var duration: TimeInterval
    private var timer: Timer?
    private var startDate: Date?
    private let timingFunction: WebCore.CubicBezierTimingFunction

    fileprivate init(
        scrollbar: consuming WebCore.ScrollbarsControllerMacScrollbar,
        featureToAnimate: FeatureToAnimate,
        animateFrom startValue: CGFloat,
        animateTo endValue: CGFloat,
        duration: TimeInterval
    ) {
        self.duration = duration
        timingFunction = WebCore.CubicBezierTimingFunction.create(.EaseInOut).get()
        self.scrollbar = scrollbar
        self.featureToAnimate = featureToAnimate
        self.startValue = startValue
        self.endValue = endValue
        super.init()
        timer = Timer(
            fireAt: Date(timeIntervalSinceNow: 0),
            interval: 0.01,
            target: self,
            selector: #selector(setCurrentProgress(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    /// Called on the main thread by the NSScrollerImp delegate.
    ///
    /// The timer is the one made by init, so once it has been invalidated, adding it to the run loop again does
    /// nothing.
    func startAnimation() {
        precondition(scrollbar?.isLive() == true)

        scrollerImp = scrollbar?.scrollerImp()

        if let timer {
            RunLoop.main.add(timer, forMode: .default)
        }
        startDate = Date(timeIntervalSinceNow: 0)
    }

    /// The main run loop calls this, in the default mode.
    @objc
    func setCurrentProgress(_ timer: Timer) {
        var progress: CGFloat = 0
        let now = Date(timeIntervalSinceNow: 0)
        let elapsed = now.timeIntervalSinceReferenceDate - (startDate?.timeIntervalSinceReferenceDate ?? 0)
        if elapsed > duration {
            progress = 1
            timer.invalidate()
        } else {
            var t: TimeInterval = 1
            if duration != 0 {
                t = elapsed / duration
            }
            progress = timingFunction.transformProgress(t, duration, .No)
        }
        precondition(scrollbar?.isLive() == true)

        let currentValue: CGFloat
        if startValue > endValue {
            currentValue = 1 - progress
        } else {
            currentValue = progress
        }

        switch featureToAnimate {
        case .thumbAlpha:
            scrollerImp?.knobAlpha = currentValue
        case .trackAlpha:
            scrollerImp?.trackAlpha = currentValue
        case .uiStateTransition:
            scrollerImp?.uiStateTransitionProgress = currentValue
        case .expansionTransition:
            scrollerImp?.expansionTransitionProgress = currentValue
        }

        if scrollbar?.supportsUpdateOnSecondaryThread() == false {
            scrollbar?.invalidate()
        }
    }

    /// Called on the main thread by the NSScrollerImp delegate.
    func invalidate() {
        stopAnimation()
        _ = scrollbar.take()
    }

    /// Called on the main thread by the NSScrollerImp delegate.
    func stopAnimation() {
        timer?.invalidate()
    }
}

/// The delegate of a scrollbar's NSScrollerImp, which runs its knob, track and transition animations.
@objc(WebScrollerImpDelegate)
final class WebScrollerImpDelegate: NSObject, NSAnimationDelegate, NSScrollerImpDelegate {
    private var scrollbar: Optional<WebCore.ScrollbarsControllerMacScrollbar>
    private let area: WebCore.ScrollbarsControllerMacArea
    /// The NSScrollerImpPair's delegate, through which this delegate reaches the ScrollbarsControllerMac's state.
    ///
    /// It holds no NSScrollerImp delegate, so holding it strongly makes no cycle.
    private let pairDelegate: WebScrollerImpPairDelegate

    private var knobAlphaAnimation: WebScrollbarPartAnimation?
    private var trackAlphaAnimation: WebScrollbarPartAnimation?
    private var uiStateTransitionAnimation: WebScrollbarPartAnimation?
    private var expansionTransitionAnimation: WebScrollbarPartAnimation?

    /// `area` is the scrollbar's ScrollableArea, and `pairDelegate` its ScrollbarsControllerMac's NSScrollerImpPair
    /// delegate.
    init(
        scrollbar: consuming WebCore.ScrollbarsControllerMacScrollbar,
        area: consuming WebCore.ScrollbarsControllerMacArea,
        pairDelegate: WebScrollerImpPairDelegate
    ) {
        self.scrollbar = scrollbar
        self.area = area
        self.pairDelegate = pairDelegate
        super.init()
    }

    /// Called on the main thread by ScrollbarsControllerMac.
    func cancelAnimations() {
        knobAlphaAnimation?.stopAnimation()
        trackAlphaAnimation?.stopAnimation()
        uiStateTransitionAnimation?.stopAnimation()
        expansionTransitionAnimation?.stopAnimation()
    }

    /// AppKit calls this on the main thread.
    @objc(convertRectToBacking:)
    func convertRectToBacking(_ aRect: NSRect) -> NSRect {
        aRect
    }

    /// AppKit calls this on the main thread.
    @objc(convertRectFromBacking:)
    func convertRectFromBacking(_ aRect: NSRect) -> NSRect {
        aRect
    }

    /// AppKit calls this on the main thread.
    @objc(layer)
    func layer() -> CALayer! {
        guard scrollbar?.isLive() == true else {
            return nil
        }

        let orientation = scrollbar?.orientation() ?? .Vertical
        return area.scrollerImpDelegateLayer(orientation)
    }

    /// AppKit calls this on the main thread.
    func mouseLocationInScroller(for scrollerImp: NSScrollerImp!) -> NSPoint {
        guard scrollbar?.isLive() == true else {
            return .zero
        }

        let positionInView = area.lastKnownMousePositionInView()
        return nsPoint(scrollbar?.convertFromContainingView(positionInView) ?? WebCore.IntPoint())
    }

    /// AppKit calls this on the main thread.
    @objc(convertRectToLayer:)
    func convertRect(toLayer rect: NSRect) -> NSRect {
        rect
    }

    /// AppKit calls this on the main thread.
    @objc(shouldUseLayerPerPartForScrollerImp:)
    func shouldUseLayerPerPart(for scrollerImp: NSScrollerImp!) -> Bool {
        scrollbar?.supportsUpdateOnSecondaryThread() ?? false
    }

    /// AppKit calls this on the main thread.
    func effectiveAppearance(for scrollerImp: NSScrollerImp!) -> NSAppearance! {
        guard scrollbar?.isLive() == true else {
            return NSAppearance.currentDrawing()
        }

        // Keep this in sync with LocalFrameView::paintScrollCorner.
        // The base system does not support dark Aqua, so we might get a null result.
        let name: NSAppearance.Name = area.useDarkAppearanceForScrollbars() ? .darkAqua : .aqua
        return NSAppearance(named: name) ?? NSAppearance.currentDrawing()
    }

    private func animation(_ feature: FeatureToAnimate) -> WebScrollbarPartAnimation? {
        switch feature {
        case .thumbAlpha: knobAlphaAnimation
        case .trackAlpha: trackAlphaAnimation
        case .uiStateTransition: uiStateTransitionAnimation
        case .expansionTransition: expansionTransitionAnimation
        }
    }

    private func setAnimation(_ feature: FeatureToAnimate, _ animation: WebScrollbarPartAnimation?) {
        switch feature {
        case .thumbAlpha: knobAlphaAnimation = animation
        case .trackAlpha: trackAlphaAnimation = animation
        case .uiStateTransition: uiStateTransitionAnimation = animation
        case .expansionTransition: expansionTransitionAnimation = animation
        }
    }

    private func setUpAlphaAnimation(
        _ feature: FeatureToAnimate,
        _ scrollbar: WebCore.ScrollbarsControllerMacScrollbar,
        scrollerPainter: NSScrollerImp?,
        animateAlphaTo newAlpha: CGFloat,
        duration: TimeInterval
    ) {
        // If the user has scrolled the page, then the scrollbars must be animated here.
        // This overrides the early returns.
        let mustAnimate = !area.scrollbarAnimationsUnsuspendedByUserInteraction()

        if area.scrollbarPaintTimerIsActive() && !mustAnimate {
            return
        }

        if area.shouldSuspendScrollbarAnimations() && !mustAnimate {
            area.startScrollbarPaintTimer()
            return
        }

        // At this point, we are definitely going to animate now, so stop the timer.
        area.stopScrollbarPaintTimer()

        // If we are currently animating, stop
        if let scrollbarPartAnimation = animation(feature) {
            scrollbarPartAnimation.stopAnimation()
            setAnimation(feature, nil)
        }

        scrollbar.setPaintCharacteristics()

        if feature == .thumbAlpha && scrollbar.orientation() == .Vertical {
            if newAlpha == 1 {
                let thumbRect = WebCore.IntRect(WebCore.FloatRect(scrollerPainter?.rect(for: .knob) ?? .zero))
                pairDelegate.controller?.setVisibleScrollerThumbRect(thumbRect)
            } else {
                pairDelegate.controller?.setVisibleScrollerThumbRect(WebCore.IntRect())
            }
        }

        setAnimation(
            feature,
            WebScrollbarPartAnimation(
                scrollbar: scrollbar,
                featureToAnimate: feature,
                animateFrom: (feature == .thumbAlpha ? scrollerPainter?.knobAlpha : scrollerPainter?.trackAlpha) ?? 0,
                animateTo: newAlpha,
                duration: duration
            )
        )
        animation(feature)?.startAnimation()
    }

    /// AppKit calls this on the main thread.
    func scrollerImp(_ scrollerImp: NSScrollerImp!, animateKnobAlphaTo newKnobAlpha: CGFloat, duration: TimeInterval) {
        guard let scrollbar, scrollbar.isLive() else {
            return
        }

        if pairDelegate.controller?.scrollbarsCanBeActive() != true {
            scrollerImp?.knobAlpha = 0
            scrollbar.invalidate()
            return
        }

        // If we are fading the scrollbar away, that is a good indication that we are no longer going to
        // be moving it around on the scrolling thread. Setting usePresentationValue to false
        // will pass that information on to the NSScrollerImp API.
        if newKnobAlpha == 0 && scrollbar.supportsUpdateOnSecondaryThread() {
            scrollerImp?.shouldUsePresentationValue = false
        }

        setUpAlphaAnimation(
            .thumbAlpha,
            scrollbar,
            scrollerPainter: scrollerImp,
            animateAlphaTo: newKnobAlpha,
            duration: duration
        )
    }

    /// AppKit calls this on the main thread.
    func scrollerImp(_ scrollerImp: NSScrollerImp!, animateTrackAlphaTo newTrackAlpha: CGFloat, duration: TimeInterval) {
        guard let scrollbar, scrollbar.isLive() else {
            return
        }

        setUpAlphaAnimation(
            .trackAlpha,
            scrollbar,
            scrollerPainter: scrollerImp,
            animateAlphaTo: newTrackAlpha,
            duration: duration
        )
    }

    /// AppKit calls this on the main thread.
    func scrollerImp(_ scrollerImp: NSScrollerImp!, animateUIStateTransitionWithDuration duration: TimeInterval) {
        guard let scrollbar, scrollbar.isLive() else {
            return
        }

        // UIStateTransition always animates to 1. In case an animation is in progress this avoids a hard transition.
        scrollerImp?.uiStateTransitionProgress = 1 - (scrollerImp?.uiStateTransitionProgress ?? 0)

        // If the UI state transition is happening, then we are no longer moving the scrollbar on the scrolling thread.
        if scrollbar.supportsUpdateOnSecondaryThread() {
            scrollerImp?.shouldUsePresentationValue = false
        }

        let startValue = scrollerImp?.uiStateTransitionProgress ?? 0
        if let uiStateTransitionAnimation {
            // If we don't need to initialize the animation, just reset the values in case they have changed.
            uiStateTransitionAnimation.startValue = startValue
            uiStateTransitionAnimation.endValue = 1
            uiStateTransitionAnimation.duration = duration
        } else {
            uiStateTransitionAnimation = WebScrollbarPartAnimation(
                scrollbar: scrollbar,
                featureToAnimate: .uiStateTransition,
                animateFrom: startValue,
                animateTo: 1,
                duration: duration
            )
        }
        uiStateTransitionAnimation?.startAnimation()
    }

    /// AppKit calls this on the main thread.
    func scrollerImp(_ scrollerImp: NSScrollerImp!, animateExpansionTransitionWithDuration duration: TimeInterval) {
        guard let scrollbar, scrollbar.isLive() else {
            return
        }

        // ExpansionTransition always animates to 1. In case an animation is in progress this avoids a hard transition.
        scrollerImp?.expansionTransitionProgress = 1 - (scrollerImp?.expansionTransitionProgress ?? 0)

        let startValue = scrollerImp?.expansionTransitionProgress ?? 0
        if let expansionTransitionAnimation {
            // If we don't need to initialize the animation, just reset the values in case they have changed.
            expansionTransitionAnimation.startValue = startValue
            expansionTransitionAnimation.endValue = 1
            expansionTransitionAnimation.duration = duration
        } else {
            expansionTransitionAnimation = WebScrollbarPartAnimation(
                scrollbar: scrollbar,
                featureToAnimate: .expansionTransition,
                animateFrom: startValue,
                animateTo: 1,
                duration: duration
            )
        }
        expansionTransitionAnimation?.startAnimation()
    }

    /// AppKit calls this on the main thread.
    func scrollerImp(
        _ scrollerImp: NSScrollerImp!,
        overlayScrollerStateChangedTo newOverlayScrollerState: NSOverlayScrollerState
    ) {
    }

    /// Called on the main thread by ScrollbarsControllerMac.
    func invalidate() {
        _ = scrollbar.take()
        knobAlphaAnimation?.invalidate()
        trackAlphaAnimation?.invalidate()
        uiStateTransitionAnimation?.invalidate()
        expansionTransitionAnimation?.invalidate()
    }
}

/// ScrollbarsControllerMac's state: its NSScrollerImpPair, the AppKit delegates and the pending scroll delta.
@_expose(Cxx)
final class MacScrollbarsController {
    private let area: WebCore.ScrollbarsControllerMacArea
    private let scrollerImpPair: NSScrollerImpPair
    private let pairDelegate: WebScrollerImpPairDelegate
    private var verticalScrollerImpDelegate: WebScrollerImpDelegate?
    private var horizontalScrollerImpDelegate: WebScrollerImpDelegate?
    private var contentAreaScrolledTimerScrollDelta = WebCore.FloatSize()
    private var visibleScrollerThumbRect = WebCore.IntRect()
    private var needsScrollerStyleUpdate = false

    /// Called on the main thread by ScrollbarsControllerMac's constructor.
    @_expose(Cxx)
    init(_ area: consuming WebCore.ScrollbarsControllerMacArea) {
        let pairArea = copy area
        self.area = area
        scrollerImpPair = NSScrollerImpPair()
        pairDelegate = WebScrollerImpPairDelegate(pairArea)
        pairDelegate.controller = self
        scrollerImpPair.delegate = pairDelegate
        scrollerImpPair.scrollerStyle = WebCore.ScrollerStyle.recommendedScrollerStyle()
    }

    /// Called on the main thread by ScrollbarsControllerMac's destructor.
    ///
    /// The scrollbars' NSScrollerImps can outlive this object. Their delegates are held only here, and an
    /// NSScrollerImp's delegate is weak, so once this object is gone it reads nil.
    @_expose(Cxx)
    func invalidate() {
        pairDelegate.invalidate()
        scrollerImpPair.delegate = nil
        horizontalScrollerImpDelegate?.invalidate()
        verticalScrollerImpDelegate?.invalidate()
    }

    /// Called on the main thread by the NSScrollerImp delegates.
    func setVisibleScrollerThumbRect(_ scrollerThumb: WebCore.IntRect) {
        var rectInViewCoordinates = scrollerThumb
        let verticalScrollbar = area.scrollbar(.Vertical)
        if verticalScrollbar.isLive() {
            rectInViewCoordinates = verticalScrollbar.convertToContainingView(scrollerThumb)
        }

        if rectInViewCoordinates == visibleScrollerThumbRect {
            return
        }

        area.setVisibleScrollerThumbRect(rectInViewCoordinates)
        visibleScrollerThumbRect = rectInViewCoordinates
    }

    /// Called on the main thread by ScrollableArea and ScrollAnimator.
    @_expose(Cxx)
    func cancelAnimations() {
        if area.scrollbarPaintTimerIsActive() {
            area.stopScrollbarPaintTimer()
        }
        horizontalScrollerImpDelegate?.cancelAnimations()
        verticalScrollerImpDelegate?.cancelAnimations()
    }

    /// Called on the main thread by ScrollAnimatorMac.
    ///
    /// Returns false when the overlay scroller state is locked.
    @_expose(Cxx)
    func didBeginScrollGesture() -> Bool {
        if scrollerImpPair.overlayScrollerStateIsLocked() {
            return false
        }

        scrollerImpPair.beginScrollGesture()
        area.deferContentScrollForTesting()
        return true
    }

    /// Called on the main thread by ScrollAnimatorMac.
    ///
    /// Returns false when the overlay scroller state is locked.
    @_expose(Cxx)
    func didEndScrollGesture() -> Bool {
        if scrollerImpPair.overlayScrollerStateIsLocked() {
            return false
        }

        scrollerImpPair.endScrollGesture()
        area.removeContentScrollDeferralForTesting()
        return true
    }

    /// Called on the main thread by ScrollAnimatorMac.
    ///
    /// Returns false when the overlay scroller state is locked.
    @_expose(Cxx)
    func mayBeginScrollGesture() -> Bool {
        if scrollerImpPair.overlayScrollerStateIsLocked() {
            return false
        }

        scrollerImpPair.beginScrollGesture()
        scrollerImpPair.contentAreaScrolled()
        return true
    }

    /// Called on the main thread by ScrollableArea and by the NSScrollerImpPair delegate.
    @_expose(Cxx)
    func contentAreaWillPaint() {
        if scrollerImpPair.overlayScrollerStateIsLocked() {
            return
        }

        scrollerImpPair.contentAreaWillDraw()
    }

    /// Called on the main thread by ScrollableArea.
    @_expose(Cxx)
    func mouseEnteredContentArea() {
        if scrollerImpPair.overlayScrollerStateIsLocked() {
            return
        }

        scrollerImpPair.mouseEnteredContentArea()
    }

    /// Called on the main thread by ScrollableArea.
    @_expose(Cxx)
    func mouseExitedContentArea() {
        if scrollerImpPair.overlayScrollerStateIsLocked() {
            return
        }

        scrollerImpPair.mouseExitedContentArea()
    }

    /// Called on the main thread by ScrollableArea.
    @_expose(Cxx)
    func mouseMovedInContentArea() {
        if scrollerImpPair.overlayScrollerStateIsLocked() {
            return
        }

        scrollerImpPair.mouseMovedInContentArea()
    }

    /// Called on the main thread by ScrollbarsControllerMac's mouseEnteredScrollbar() and mouseExitedScrollbar().
    ///
    /// Returns true when the recommended scroller style is legacy and the overlay scroller state is not locked.
    @_expose(Cxx)
    func scrollbarMouseNotificationsAreSent() -> Bool {
        // At this time, only legacy scrollbars needs to send notifications here.
        if WebCore.ScrollerStyle.recommendedScrollerStyle() != .legacy {
            return false
        }

        return !scrollerImpPair.overlayScrollerStateIsLocked()
    }

    /// Called on the main thread by Scrollbar, with the scrollbar's NSScrollerImp, when
    /// scrollbarMouseNotificationsAreSent() is true.
    @_expose(Cxx)
    func mouseEnteredScrollbar(_ scrollerImp: NSScrollerImp?) {
        scrollerImp?.mouseEnteredScroller()
    }

    /// Called on the main thread by Scrollbar, with the scrollbar's NSScrollerImp, when
    /// scrollbarMouseNotificationsAreSent() is true.
    @_expose(Cxx)
    func mouseExitedScrollbar(_ scrollerImp: NSScrollerImp?) {
        scrollerImp?.mouseExitedScroller()
    }

    /// Called on the main thread by Scrollbar, with the scrollbar's NSScrollerImp, when scrollbarsCanBeActive() is
    /// true.
    @_expose(Cxx)
    func mouseIsDownInScrollbar(_ scrollerImp: NSScrollerImp?, _ mouseIsDown: Bool) {
        if let painter = scrollerImp {
            painter.isTracking = mouseIsDown
            if mouseIsDown {
                scrollerImpPair.beginScrollGesture()
            } else {
                scrollerImpPair.endScrollGesture()
            }
        }
    }

    /// Called on the main thread by ScrollableArea.
    @_expose(Cxx)
    func willStartLiveResize() {
        if scrollerImpPair.overlayScrollerStateIsLocked() {
            return
        }

        scrollerImpPair.startLiveResize()
    }

    /// Called on the main thread by ScrollableArea.
    @_expose(Cxx)
    func contentsSizeChanged() {
        if scrollerImpPair.overlayScrollerStateIsLocked() {
            return
        }

        scrollerImpPair.contentAreaDidResize()
    }

    /// Called on the main thread by ScrollableArea, after ScrollbarsController's own work.
    @_expose(Cxx)
    func willEndLiveResize() {
        if scrollerImpPair.overlayScrollerStateIsLocked() {
            return
        }

        scrollerImpPair.endLiveResize()
    }

    /// Called on the main thread by ScrollableArea.
    @_expose(Cxx)
    func contentAreaDidShow() {
        if scrollerImpPair.overlayScrollerStateIsLocked() {
            return
        }

        scrollerImpPair.windowOrderedIn()
    }

    /// Called on the main thread by ScrollableArea.
    @_expose(Cxx)
    func contentAreaDidHide() {
        if scrollerImpPair.overlayScrollerStateIsLocked() {
            return
        }

        scrollerImpPair.windowOrderedOut()
    }

    /// Called on the main thread by ScrollableArea.
    @_expose(Cxx)
    func lockOverlayScrollbarStateToHidden(_ shouldLockState: Bool) {
        if shouldLockState {
            scrollerImpPair.lockOverlayScrollerState(NSOverlayScrollerState(NSOverlayScrollerStateHidden))
        } else {
            scrollerImpPair.unlockOverlayScrollerState()

            // We never update scroller style for PainterControllers that are locked. If we have a pending
            // need to update the style, do it once we've unlocked the scroller state.
            if needsScrollerStyleUpdate {
                updateScrollerStyle()
            }
        }
    }

    /// Called on the main thread by ScrollableArea, ScrollbarsControllerMac's mouseIsDownInScrollbar() and the
    /// NSScrollerImp delegates.
    @_expose(Cxx)
    func scrollbarsCanBeActive() -> Bool {
        !scrollerImpPair.overlayScrollerStateIsLocked()
    }

    /// Called on the main thread by ScrollableArea, with the scrollbar's NSScrollerImp.
    @_expose(Cxx)
    func didAddVerticalScrollbar(_ scrollerImp: NSScrollerImp?, _ scrollbar: consuming WebCore.ScrollbarsControllerMacScrollbar) {
        guard let painter = scrollerImp else {
            return
        }

        let delegate = WebScrollerImpDelegate(scrollbar: scrollbar, area: area, pairDelegate: pairDelegate)
        verticalScrollerImpDelegate = delegate

        painter.delegate = delegate
        var hasGraphicsLayer = false
        let layer = area.layerForScrollbar(.Vertical, &hasGraphicsLayer)
        if hasGraphicsLayer {
            painter.layer = layer
        }

        scrollerImpPair.verticalScrollerImp = painter
        if area.inLiveResize() {
            painter.knobAlpha = 1
        }
    }

    /// Called on the main thread by ScrollableArea, with the scrollbar's NSScrollerImp.
    @_expose(Cxx)
    func willRemoveVerticalScrollbar(_ scrollerImp: NSScrollerImp?) {
        guard let painter = scrollerImp else {
            return
        }

        verticalScrollerImpDelegate?.invalidate()
        verticalScrollerImpDelegate = nil

        painter.delegate = nil
        scrollerImpPair.verticalScrollerImp = nil
    }

    /// Called on the main thread by ScrollableArea, with the scrollbar's NSScrollerImp.
    @_expose(Cxx)
    func didAddHorizontalScrollbar(_ scrollerImp: NSScrollerImp?, _ scrollbar: consuming WebCore.ScrollbarsControllerMacScrollbar) {
        guard let painter = scrollerImp else {
            return
        }

        let delegate = WebScrollerImpDelegate(scrollbar: scrollbar, area: area, pairDelegate: pairDelegate)
        horizontalScrollerImpDelegate = delegate

        painter.delegate = delegate
        var hasGraphicsLayer = false
        let layer = area.layerForScrollbar(.Horizontal, &hasGraphicsLayer)
        if hasGraphicsLayer {
            painter.layer = layer
        }

        scrollerImpPair.horizontalScrollerImp = painter
        if area.inLiveResize() {
            painter.knobAlpha = 1
        }
    }

    /// Called on the main thread by ScrollableArea, with the scrollbar's NSScrollerImp.
    @_expose(Cxx)
    func willRemoveHorizontalScrollbar(_ scrollerImp: NSScrollerImp?) {
        guard let painter = scrollerImp else {
            return
        }

        horizontalScrollerImpDelegate?.invalidate()
        horizontalScrollerImpDelegate = nil

        painter.delegate = nil
        scrollerImpPair.horizontalScrollerImp = nil
    }

    /// Called on the main thread by ScrollableArea, with the scrollbar's NSScrollerImp.
    @_expose(Cxx)
    func invalidateScrollbarPartLayers(_ scrollerImp: NSScrollerImp?) {
        scrollerImp?.setNeedsDisplay(true)
    }

    /// Called on the main thread by ScrollableArea, with the vertical scrollbar's NSScrollerImp.
    @_expose(Cxx)
    func verticalScrollbarLayerDidChange(_ scrollerImp: NSScrollerImp?) {
        var hasGraphicsLayer = false
        let layer = area.layerForScrollbar(.Vertical, &hasGraphicsLayer)
        guard let painter = scrollerImp else {
            return
        }

        painter.layer = layer
    }

    /// Called on the main thread by ScrollableArea, with the horizontal scrollbar's NSScrollerImp.
    @_expose(Cxx)
    func horizontalScrollbarLayerDidChange(_ scrollerImp: NSScrollerImp?) {
        var hasGraphicsLayer = false
        let layer = area.layerForScrollbar(.Horizontal, &hasGraphicsLayer)
        guard let painter = scrollerImp else {
            return
        }

        painter.layer = layer
    }

    /// Called on the main thread by ScrollbarsControllerMac's shouldScrollbarParticipateInHitTesting(), for each hit
    /// test.
    @_expose(Cxx)
    func scrollbarsAlwaysParticipateInHitTesting() -> Bool {
        // Non-overlay scrollbars should always participate in hit testing.
        WebCore.ScrollerStyle.recommendedScrollerStyle() != .overlay
    }

    /// Called on the main thread by Scrollbar, for each hit test, with the scrollbar's NSScrollerImp, when
    /// scrollbarsAlwaysParticipateInHitTesting() is false.
    @_expose(Cxx)
    func shouldScrollbarParticipateInHitTesting(_ scrollerImp: NSScrollerImp?) -> Bool {
        // Overlay scrollbars should participate in hit testing whenever they are at all visible.
        guard let painter = scrollerImp else {
            return false
        }
        return painter.knobAlpha > 0
    }

    /// Called on the main thread by ScrollableArea.
    ///
    /// Returns true when ScrollbarsControllerMac is to start m_sendContentAreaScrolledTimer.
    @_expose(Cxx)
    func notifyContentAreaScrolled(_ delta: WebCore.FloatSize) -> Bool {
        // This function is called when a page is going into the back/forward cache, but the page
        // isn't really scrolling in that case. We should only pass the message on to the
        // ScrollerImpPair when we're really scrolling on an active page.
        if scrollerImpPair.overlayScrollerStateIsLocked() {
            return false
        }

        return notifyUnlockedContentAreaScrolled(delta)
    }

    // Out of line, so that notifyContentAreaScrolled() returns with no frame while the overlay scroller state is
    // locked.
    @inline(never)
    private func notifyUnlockedContentAreaScrolled(_ delta: WebCore.FloatSize) -> Bool {
        if area.isHandlingWheelEvent() {
            sendContentAreaScrolled(delta)
            return false
        }
        sendContentAreaScrolledSoon(delta)
        return true
    }

    /// Called on the main thread by ScrollableArea, Internals and the NSScrollerImpPair delegate.
    @_expose(Cxx)
    func updateScrollerStyle() {
        if scrollerImpPair.overlayScrollerStateIsLocked() {
            needsScrollerStyleUpdate = true
            return
        }

        if !area.macThemeUsesOverlayScrollbarsChanged() {
            needsScrollerStyleUpdate = false
            return
        }

        let newStyle = scrollerImpPair.scrollerStyle

        updateScrollerImps()

        // The different scrollbar styles have different thicknesses, so we must re-set the
        // frameRect to the new thickness, and the re-layout below will ensure the position
        // and length are properly updated.
        area.updateScrollbarsThickness()

        // If needsScrollerStyleUpdate is true, then the page is restoring from the back/forward cache, and
        // a relayout will happen on its own. Otherwise, we must initiate a re-layout ourselves.
        area.scrollbarStyleChanged(newStyle == .overlay ? .Overlay : .AlwaysVisible, !needsScrollerStyleUpdate)

        needsScrollerStyleUpdate = false
    }

    /// Called on the main thread by LocalFrameView.
    @_expose(Cxx)
    func scrollbarWidthChanged() {
        area.updateScrollbarsThickness()
        updateScrollerImps()
    }

    /// Called on the main thread by ScrollbarsControllerMac's m_initialScrollbarPaintTimer.
    @_expose(Cxx)
    func initialScrollbarPaintTimerFired() {
        // To force the scrollbars to flash, we have to call hide first. Otherwise, the ScrollerImpPair
        // might think that the scrollbars are already showing and bail early.
        scrollerImpPair.hideOverlayScrollers()
        scrollerImpPair.flashScrollers()
    }

    /// Called on the main thread by ScrollbarsControllerMac's m_sendContentAreaScrolledTimer.
    @_expose(Cxx)
    func sendContentAreaScrolledTimerFired() {
        sendContentAreaScrolled(contentAreaScrolledTimerScrollDelta)
        contentAreaScrolledTimerScrollDelta = WebCore.FloatSize()

        area.removeContentScrollDeferralForTesting()
    }

    /// Called on the main thread by Internals.
    @_expose(Cxx)
    func horizontalScrollbarStateForTesting() -> WTF.String {
        scrollbarState(area.scrollbar(.Horizontal))
    }

    /// Called on the main thread by Internals.
    @_expose(Cxx)
    func verticalScrollbarStateForTesting() -> WTF.String {
        scrollbarState(area.scrollbar(.Vertical))
    }
    private func updateScrollerImps() {
        let verticalScrollbar = area.scrollbar(.Vertical)
        if verticalScrollbar.isLive() && !verticalScrollbar.isCustomScrollbar() {
            verticalScrollbar.invalidate()

            let oldVerticalPainter = scrollerImpPair.verticalScrollerImp
            verticalScrollbar.createScrollerImp(oldVerticalPainter)
            scrollerImpPair.verticalScrollerImp = verticalScrollbar.scrollerImp()
        }

        let horizontalScrollbar = area.scrollbar(.Horizontal)
        if horizontalScrollbar.isLive() && !horizontalScrollbar.isCustomScrollbar() {
            horizontalScrollbar.invalidate()

            let oldHorizontalPainter = scrollerImpPair.horizontalScrollerImp
            horizontalScrollbar.createScrollerImp(oldHorizontalPainter)
            scrollerImpPair.horizontalScrollerImp = horizontalScrollbar.scrollerImp()
        }
    }

    // sendContentAreaScrolledSoon() does the same work as sendContentAreaScrolled(), but after a zero-delay timer
    // fires. This prevents updating overlay scrollbar information during layout.
    private func sendContentAreaScrolled(_ delta: WebCore.FloatSize) {
        scrollerImpPair.contentAreaScrolled(inDirection: NSPoint(x: CGFloat(delta.width()), y: CGFloat(delta.height())))
    }

    // ScrollbarsControllerMac starts the timer when notifyContentAreaScrolled() returns true.
    private func sendContentAreaScrolledSoon(_ delta: WebCore.FloatSize) {
        contentAreaScrolledTimerScrollDelta = delta
        area.deferContentScrollForTesting()
    }

    private func scrollbarState(_ scrollbar: WebCore.ScrollbarsControllerMacScrollbar) -> WTF.String {
        guard scrollbar.isLive() else {
            return testingString("none")
        }

        var result = scrollbar.enabled() ? "enabled" : "disabled"

        guard scrollbar.isOverlayScrollbar(), let scrollerImp = scrollbar.scrollerImp() else {
            return testingString(result)
        }

        if scrollerImp.isExpanded {
            result += ",expanded"
        }

        if scrollerImp.trackAlpha > 0 {
            result += ",visible_track"
        }

        if scrollerImp.knobAlpha > 0 {
            result += ",visible_thumb"
        }

        if scrollerImp.userInterfaceLayoutDirection == .rightToLeft {
            result += ",RTL"
        }

        if scrollerImp.controlSize != .regular {
            result += ",thin"
        }

        return testingString(result)
    }

    private func testingString(_ ascii: Swift.String) -> WTF.String {
        let characters: [WTF.Latin1Character] = ascii.utf8.map { byte in
            var character = WTF.Latin1Character()
            character.value = byte
            return character
        }
        return WTF.String(characters.span)
    }
}

#endif // os(macOS)
