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

// ScrollerPairMac's scrollers, the delegates of its NSScrollerImpPair and NSScrollerImps, and their knob, track and
// transition animations. Each scroller's lock and the AppKit objects used under it are a MacScrollerImpState;
// ScrollerPairMac keeps the NSScrollerImpPair, which no lock guards.

// PLATFORM(MAC), as ScrollerPairMac.mm and ScrollerMac.mm, the C++ this replaces.
#if os(macOS)

internal import AppKit
internal import QuartzCore
internal import Synchronization
internal import WebCore_Private.Core.FloatSize
internal import WebCore_Private.Core.IntPoint
internal import WebCore_Private.Core.NSScrollerImpDetails
internal import WebCore_Private.Core.PlatformWheelEvent
internal import WebCore_Private.Core.ScrollerPairMac
internal import WebCore_Private.Core.ScrollingStateScrollingNode
internal import WebCore_Private.Core.ScrollingTreeScrollingNode
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.Core.ScrollTypesMac
internal import WebCore_Private.Core.UserInterfaceLayoutDirection
internal import WebCore_Private.ScrollerImpDelegateBinding
internal import WebCore_Private.ScrollerPairMacTypes
internal import pal.spi.mac.NSScrollerImpSPI
internal import wtf.Core.text.Latin1Character
internal import wtf.Core.text.WTFString
internal import wtf.Core.MainThread
internal import wtf.Core.cocoa.MainThreadBlocks

// MARK: - MacScrollerPair

@_expose(Cxx)
final class MacScrollerPair: Sendable {
    fileprivate let pair: WebCore.ScrollerPairMacWeakPtr
    private let verticalScroller = MacScroller(orientation: .Vertical)
    private let horizontalScroller = MacScroller(orientation: .Horizontal)
    private let scrollerImpPairDelegate = Mutex<WebScrollerImpPairDelegateMac?>(nil)
    private let lastScrollOffset = Mutex<ScrollOffset?>(nil)
    private let isMouseOverVerticalScrollbar = Atomic<Bool>(false)
    private let isMouseOverHorizontalScrollbar = Atomic<Bool>(false)
    private let scrollbarWidth = Atomic<UInt8>(WebCore.ScrollbarWidth.Auto.rawValue)
    fileprivate let useDarkAppearance = Atomic<Bool>(false)
    fileprivate let inLiveResize = Atomic<Bool>(false)
    private let mouseInContentArea = Atomic<Bool>(false)
    private let style = Atomic<UInt8>(WebCore.ScrollbarStyle.AlwaysVisible.rawValue)
    private let usingPresentationValues = Atomic<Bool>(false)

    @_expose(Cxx)
    init(_ pair: consuming WebCore.ScrollerPairMacWeakPtr) {
        self.pair = pair
    }

    fileprivate func scroller(_ orientation: WebCore.ScrollbarOrientation) -> MacScroller {
        orientation == .Vertical ? verticalScroller : horizontalScroller
    }

    fileprivate var scrollbarWidthStyle: WebCore.ScrollbarWidth {
        WebCore.ScrollbarWidth(rawValue: scrollbarWidth.load(ordering: .relaxed)) ?? .Auto
    }

    /// Whether ScrollerPairMac is still alive.
    fileprivate var hasPair: Bool {
        pair.get().get() != nil
    }

    // MARK: Creation and teardown

    /// Gives the new NSScrollerImpPair its delegate and the recommended scroller style, and returns that style.
    @_expose(Cxx)
    func setUpScrollerImpPair(_ scrollerImpPair: NSScrollerImpPair) -> WebCore.ScrollbarStyle {
        let delegate = WebScrollerImpPairDelegateMac(scrollerPair: self)
        scrollerImpPairDelegate.withLock { $0 = delegate }
        WebCore.bindScrollerImpPairDelegate(scrollerImpPair, delegate)
        let style = WebCore.ScrollerStyle.recommendedScrollerStyle()
        scrollerImpPair.scrollerStyle = style
        self.style.store(WebCore.scrollbarStyle(style).rawValue, ordering: .sequentiallyConsistent)
        return WebCore.scrollbarStyle(style)
    }

    /// Attaches the vertical, then the horizontal scroller to a new NSScrollerImp.
    @_expose(Cxx)
    func attachScrollers(_ pair: WebCore.ScrollerPairMac) {
        verticalScroller.attach(self, pair)
        horizontalScroller.attach(self, pair)
    }

    /// Invalidates the NSScrollerImpPair's delegate.
    @_expose(Cxx)
    func invalidate() {
        scrollerImpPairDelegate.withLock { $0 }?.invalidate()
    }

    /// Detaches the vertical, then the horizontal scroller from its NSScrollerImp.
    @_expose(Cxx)
    func detachScrollers() {
        verticalScroller.detach()
        horizontalScroller.detach()
    }

    /// Invalidates the horizontal, then the vertical NSScrollerImp delegate, on the main thread.
    @_expose(Cxx)
    func scrollersWillBeDestroyed() {
        horizontalScroller.scrollerImpDelegate.withLock { $0 }?.invalidate()
        verticalScroller.scrollerImpDelegate.withLock { $0 }?.invalidate()
    }

    // MARK: Any thread

    /// Returns whether the value changed.
    func setInLiveResize(_ inLiveResize: Bool) -> Bool {
        self.inLiveResize.exchange(inLiveResize, ordering: .relaxed) != inLiveResize
    }

    /// Records the node's scroll offset, telling the NSScrollerImpPair on the main thread how far it moved, then
    /// updates the horizontal and the vertical scroller's values.
    @_expose(Cxx)
    func updateValues(_ pair: WebCore.ScrollerPairMac) {
        guard let node = pair.node().get() else {
            return
        }

        let currentOffset = node.currentScrollOffset()
        let offset = ScrollOffset(x: currentOffset.x(), y: currentOffset.y())
        let (offsetChanged, lastOffset) = lastScrollOffset.withLock { last in
            let lastOffset = last
            guard lastOffset.map({ !$0.isEqual(to: offset) }) ?? true else {
                return (false, lastOffset)
            }
            last = offset
            return (true, lastOffset)
        }
        if offsetChanged {
            let scrollbarRevealBehavior = node.takeScrollbarRevealBehaviorForNextScrollbarUpdate()
            if let lastOffset, scrollbarRevealBehavior == .Default {
                let width = offset.x - lastOffset.x
                let height = offset.y - lastOffset.y
                pair.ensureOnMainThreadWithScrollerImp(nil) { [self] scrollerImpPair, _ in
                    contentAreaScrolledInDirectionOnMainThread(scrollerImpPair, width, height)
                }
            }
        }

        horizontalScroller.updateValues(pair)
        verticalScroller.updateValues(pair)
    }

    func mouseExitedContentArea() {
        mouseInContentArea.store(false, ordering: .relaxed)
    }

    func mouseMovedInContentArea(_ state: WebCore.MouseLocationState) {
        mouseInContentArea.store(true, ordering: .relaxed)
        horizontalScroller.setLastKnownMousePositionInScrollbar(state.locationInHorizontalScrollbar)
        verticalScroller.setLastKnownMousePositionInScrollbar(state.locationInVerticalScrollbar)
    }

    /// Tells each scroller whose hover state changed, the vertical one first.
    func mouseIsInScrollbar(_ pair: WebCore.ScrollerPairMac, _ hoverState: WebCore.ScrollbarHoverState) {
        if isMouseOverVerticalScrollbar.load(ordering: .relaxed) != hoverState.mouseIsOverVerticalScrollbar {
            notifyScrollerImpOfMouse(pair, .Vertical, hoverState.mouseIsOverVerticalScrollbar)
        }
        if isMouseOverHorizontalScrollbar.load(ordering: .relaxed) != hoverState.mouseIsOverHorizontalScrollbar {
            notifyScrollerImpOfMouse(pair, .Horizontal, hoverState.mouseIsOverHorizontalScrollbar)
        }
        isMouseOverVerticalScrollbar.store(hoverState.mouseIsOverVerticalScrollbar, ordering: .relaxed)
        isMouseOverHorizontalScrollbar.store(hoverState.mouseIsOverHorizontalScrollbar, ordering: .relaxed)
    }

    func setUseDarkAppearance(_ useDarkAppearance: Bool) {
        if self.useDarkAppearance.exchange(useDarkAppearance, ordering: .relaxed) == useDarkAppearance {
            return
        }
        horizontalScroller.setNeedsDisplay()
        verticalScroller.setNeedsDisplay()
    }

    func setScrollbarWidth(_ pair: WebCore.ScrollerPairMac, _ scrollbarWidth: WebCore.ScrollbarWidth) {
        if self.scrollbarWidth.exchange(scrollbarWidth.rawValue, ordering: .relaxed) == scrollbarWidth.rawValue {
            return
        }
        horizontalScroller.updateScrollbarStyle(self, pair)
        verticalScroller.updateScrollbarStyle(self, pair)
    }

    func setEnabled(_ orientation: WebCore.ScrollbarOrientation, _ enabled: Bool) {
        scroller(orientation).isEnabled.store(enabled, ordering: .relaxed)
    }

    @_expose(Cxx)
    func isVisible(_ orientation: WebCore.ScrollbarOrientation) -> Bool {
        scroller(orientation).isVisible.load(ordering: .relaxed)
    }

    // MARK: Under one scroller's lock

    func setHostLayer(_ pair: WebCore.ScrollerPairMac, _ orientation: WebCore.ScrollbarOrientation, _ layer: CALayer?) {
        if pair.isHostLayer(orientation, layer) {
            return
        }
        scroller(orientation).setHostLayer(pair, layer)
    }

    func setHiddenByStyle(
        _ pair: WebCore.ScrollerPairMac,
        _ orientation: WebCore.ScrollbarOrientation,
        _ visibility: WebCore.NativeScrollbarVisibility
    ) {
        scroller(orientation).setHiddenByStyle(self, pair, visibility != .Visible)
    }

    func setScrollerImp(
        _ pair: WebCore.ScrollerPairMac,
        _ orientation: WebCore.ScrollbarOrientation,
        _ scrollerImp: NSScrollerImp?
    ) {
        scroller(orientation).setScrollerImp(pair, scrollerImp)
    }

    func setScrollbarLayoutDirection(
        _ pair: WebCore.ScrollerPairMac,
        _ orientation: WebCore.ScrollbarOrientation,
        _ direction: WebCore.UserInterfaceLayoutDirection
    ) {
        scroller(orientation).setScrollbarLayoutDirection(self, pair, direction)
    }

    /// Stores the scroller's colors, then updates its values.
    func scrollbarColorChanged(
        _ pair: WebCore.ScrollerPairMac,
        _ orientation: WebCore.ScrollbarOrientation,
        _ trackColor: NSColor?,
        _ thumbColor: NSColor?
    ) {
        scroller(orientation).scrollbarColorChanged(pair, trackColor, thumbColor)
    }

    /// Tells the horizontal, then the vertical NSScrollerImp.
    func setUsePresentationValues(_ inMomentumPhase: Bool) {
        usingPresentationValues.store(inMomentumPhase, ordering: .sequentiallyConsistent)
        horizontalScroller.setUsePresentationValue(inMomentumPhase)
        verticalScroller.setUsePresentationValue(inMomentumPhase)
    }

    func hasScrollerImp() -> Bool {
        verticalScroller.hasScrollerImp() || horizontalScroller.hasScrollerImp()
    }

    /// If either scroller has an NSScrollerImp, takes the vertical, then the horizontal one, keeping them for
    /// releaseTakenScrollerImpsOnMainThread, and returns true.
    func takeScrollerImps(_ pair: WebCore.ScrollerPairMac) -> Bool {
        if !hasScrollerImp() {
            return false
        }
        verticalScroller.takeScrollerImp(pair)
        horizontalScroller.takeScrollerImp(pair)
        return true
    }

    /// Releases the NSScrollerImps of the oldest takeScrollerImps call, the horizontal one first.
    func releaseTakenScrollerImpsOnMainThread() {
        horizontalScroller.releaseTakenScrollerImp()
        verticalScroller.releaseTakenScrollerImp()
    }

    func scrollbarState(_ orientation: WebCore.ScrollbarOrientation, _ style: WebCore.ScrollbarStyle) -> WTF.String {
        if orientation == .Vertical {
            return verticalScroller.scrollbarState(style).text
        }
        return horizontalScroller.scrollbarState(style).text
    }

    /// Sets one part of the scroller's NSScrollerImp from an animation's progress, using ScrollerPairMac's copy of it.
    fileprivate func updateProgress(
        _ orientation: WebCore.ScrollbarOrientation,
        _ featureToAnimate: WebCore.ScrollbarPartFeature,
        _ currentValue: CGFloat
    ) {
        guard let pair = pair.get().get() else {
            return
        }
        pair.setScrollerImpProgress(orientation, featureToAnimate, currentValue)
    }

    /// The scroller's last known mouse position, or (-1, -1) while the mouse is not known to be in the content area.
    fileprivate func lastKnownMousePositionInScrollbar(_ orientation: WebCore.ScrollbarOrientation) -> NSPoint {
        guard hasPair, mouseInContentArea.load(ordering: .relaxed) else {
            return NSPoint(x: -1, y: -1)
        }
        return scroller(orientation).lastKnownMousePositionInScrollbar
    }

    /// Records whether the scroller's knob is shown, telling the node when it changes.
    fileprivate func visibilityChanged(_ orientation: WebCore.ScrollbarOrientation, _ isVisible: Bool) {
        let scroller = scroller(orientation)
        if scroller.isVisible.load(ordering: .relaxed) == isVisible {
            return
        }
        scroller.isVisible.store(isVisible, ordering: .relaxed)

        guard let pair = pair.get().get() else {
            return
        }
        if let node = pair.node().get() {
            node.scrollbarVisibilityDidChange(orientation, isVisible)
        }
    }

    // MARK: Under both scrollers' locks

    /// Takes the horizontal, then the vertical scroller's lock, and turns each NSScrollerImp's presentation value on
    /// when its value is not zero.
    func updateScrollbarPainters(_ pair: WebCore.ScrollerPairMac) {
        horizontalScroller.state.withLock { _ in
            verticalScroller.state.withLock { _ in
                CATransaction.lock()

                let horizontalValues = pair.valuesForOrientation(.Horizontal)
                horizontalScroller.setUsePresentationValue(horizontalValues.value != 0)

                let verticalValues = pair.valuesForOrientation(.Vertical)
                verticalScroller.setUsePresentationValue(verticalValues.value != 0)

                CATransaction.unlock()
            }
        }
    }

    // MARK: Main-thread hops

    // Each hop runs on the main thread, synchronously if called on the main thread, and keeps ScrollerPairMac alive
    // until it has run.

    @_expose(Cxx)
    func handleWheelEventPhase(_ pair: WebCore.ScrollerPairMac, _ phase: WebCore.PlatformWheelEventPhase) {
        pair.ensureOnMainThreadWithScrollerImp(nil) { [self] scrollerImpPair, _ in
            handleWheelEventPhaseOnMainThread(scrollerImpPair, phase)
        }
    }

    @_expose(Cxx)
    func notifyScrollerImpPair(_ pair: WebCore.ScrollerPairMac, _ notification: WebCore.ScrollerImpPairNotification) {
        pair.ensureOnMainThreadWithScrollerImp(nil) { [self] scrollerImpPair, _ in
            notifyScrollerImpPairOnMainThread(scrollerImpPair, notification)
        }
    }

    @_expose(Cxx)
    func viewWillStartLiveResize(_ pair: WebCore.ScrollerPairMac) {
        if setInLiveResize(true) {
            notifyScrollerImpPair(pair, .StartLiveResize)
        }
    }

    @_expose(Cxx)
    func viewWillEndLiveResize(_ pair: WebCore.ScrollerPairMac) {
        if setInLiveResize(false) {
            notifyScrollerImpPair(pair, .EndLiveResize)
        }
    }

    /// Stores the style, then gives the scrollers new NSScrollerImps and the NSScrollerImpPair the style on the main
    /// thread.
    fileprivate func setScrollbarStyle(_ pair: WebCore.ScrollerPairMac, _ style: WebCore.ScrollbarStyle) {
        self.style.store(style.rawValue, ordering: .sequentiallyConsistent)
        pair.ensureOnMainThreadWithScrollerImp(nil) { [self] scrollerImpPair, _ in
            guard let pair = self.pair.get().get() else {
                return
            }
            updateScrollbarStyleOnMainThread(pair, scrollerImpPair, style)
        }
    }

    // FIXME: This is a workaround in place for the time being since NSScrollerImps cannot be deallocated
    // on a non-main thread. rdar://problem/24535055
    func releaseReferencesToScrollerImpsOnTheMainThread(_ pair: WebCore.ScrollerPairMac) {
        if takeScrollerImps(pair) {
            WTF.callOnMainThreadWithBlock { [self] in
                precondition(WTF.isMainThread())
                releaseTakenScrollerImpsOnMainThread()
            }
        }
    }

    /// Only legacy scrollbars tell their NSScrollerImp that the mouse entered or left it.
    private func notifyScrollerImpOfMouse(
        _ pair: WebCore.ScrollerPairMac,
        _ orientation: WebCore.ScrollbarOrientation,
        _ mouseEntered: Bool
    ) {
        pair.ensureOnMainThreadWithScrollerImp(pair.retainedScrollerImp(orientation)) { [self] scrollerImpPair, scrollerImp in
            notifyScrollerImpOfMouseOnMainThread(scrollerImpPair, scrollerImp, mouseEntered, scrollbarStyle())
        }
    }

    // MARK: Read by the node's delegate

    @_expose(Cxx)
    func scrollbarStyle() -> WebCore.ScrollbarStyle {
        WebCore.ScrollbarStyle(rawValue: style.load(ordering: .sequentiallyConsistent)) ?? .AlwaysVisible
    }

    @_expose(Cxx)
    func scrollbarStateForOrientation(_ orientation: WebCore.ScrollbarOrientation) -> WTF.String {
        scrollbarState(orientation, scrollbarStyle())
    }

    var isUsingPresentationValues: Bool {
        usingPresentationValues.load(ordering: .sequentiallyConsistent)
    }

    // MARK: Main thread

    // ScrollerPairMac's main-thread tasks call these, after checking that they run on the main thread.

    func handleWheelEventPhaseOnMainThread(_ scrollerImpPair: NSScrollerImpPair?, _ phase: WebCore.PlatformWheelEventPhase) {
        switch phase {
        case .Began:
            scrollerImpPair?.beginScrollGesture()
        case .Ended, .Cancelled:
            scrollerImpPair?.endScrollGesture()
        case .MayBegin:
            scrollerImpPair?.beginScrollGesture()
            scrollerImpPair?.contentAreaScrolled()
        default:
            break
        }
    }

    /// Tells the NSScrollerImpPair, unless its overlay scroller state is locked.
    func notifyScrollerImpPairOnMainThread(
        _ scrollerImpPair: NSScrollerImpPair?,
        _ notification: WebCore.ScrollerImpPairNotification
    ) {
        if scrollerImpPair?.overlayScrollerStateIsLocked() ?? false {
            return
        }
        switch notification {
        case .StartLiveResize:
            scrollerImpPair?.startLiveResize()
        case .EndLiveResize:
            scrollerImpPair?.endLiveResize()
        case .ContentAreaDidResize:
            scrollerImpPair?.contentAreaDidResize()
        case .MouseEnteredContentArea:
            scrollerImpPair?.mouseEnteredContentArea()
        case .MouseExitedContentArea:
            scrollerImpPair?.mouseExitedContentArea()
        case .MouseMovedInContentArea:
            scrollerImpPair?.mouseMovedInContentArea()
        @unknown default:
            break
        }
    }

    func contentAreaScrolledInDirectionOnMainThread(_ scrollerImpPair: NSScrollerImpPair?, _ width: Float, _ height: Float) {
        scrollerImpPair?.contentAreaScrolled(inDirection: NSPoint(x: CGFloat(width), y: CGFloat(height)))
    }

    /// Gives the horizontal, then the vertical scroller a new NSScrollerImp, then the NSScrollerImpPair the style.
    func updateScrollbarStyleOnMainThread(
        _ pair: WebCore.ScrollerPairMac,
        _ scrollerImpPair: NSScrollerImpPair?,
        _ style: WebCore.ScrollbarStyle
    ) {
        horizontalScroller.updateScrollbarStyle(self, pair)
        verticalScroller.updateScrollbarStyle(self, pair)
        scrollerImpPair?.scrollerStyle = WebCore.nsScrollerStyle(style)
    }

    /// Only legacy scrollbars tell their NSScrollerImp that the mouse entered or left it.
    func notifyScrollerImpOfMouseOnMainThread(
        _ scrollerImpPair: NSScrollerImpPair?,
        _ scrollerImp: NSScrollerImp?,
        _ mouseEntered: Bool,
        _ style: WebCore.ScrollbarStyle
    ) {
        if style != .AlwaysVisible {
            return
        }
        if scrollerImpPair?.overlayScrollerStateIsLocked() ?? false {
            return
        }
        if mouseEntered {
            scrollerImp?.mouseEnteredScroller()
        } else {
            scrollerImp?.mouseExitedScroller()
        }
    }
}

private struct ScrollOffset: Sendable {
    var x: Float
    var y: Float

    // FloatPoint's ==.
    func isEqual(to other: ScrollOffset) -> Bool {
        x == other.x && y == other.y
    }
}

// MARK: - MacScroller

/// One scrollbar.
private final class MacScroller: Sendable {
    let orientation: WebCore.ScrollbarOrientation
    let state = MacScrollerImpState()
    let scrollerImpDelegate = Mutex<WebScrollerImpDelegateMac?>(nil)
    let minimumKnobLength = Atomic<Int32>(0)
    let isEnabled = Atomic<Bool>(false)
    let isVisible = Atomic<Bool>(false)
    let isRightToLeft = Atomic<Bool>(false)
    // The x and y of the last known mouse position, in the high and low 32 bits.
    let lastKnownMousePosition = Atomic<UInt64>(0)

    init(orientation: WebCore.ScrollbarOrientation) {
        self.orientation = orientation
    }

    private var userInterfaceLayoutDirection: NSUserInterfaceLayoutDirection {
        isRightToLeft.load(ordering: .relaxed) ? .rightToLeft : .leftToRight
    }

    private func makeScrollerImp(_ scrollerPair: MacScrollerPair, _ pair: WebCore.ScrollerPairMac) -> NSScrollerImp? {
        NSScrollerImp(
            style: WebCore.nsScrollerStyle(scrollerPair.scrollbarStyle()),
            controlSize: WebCore.nsControlSizeFromScrollbarWidth(scrollerPair.scrollbarWidthStyle),
            horizontal: orientation == .Horizontal,
            replacingScrollerImp: nil
        )
    }

    /// Gives the scroller a new delegate and a new NSScrollerImp.
    func attach(_ scrollerPair: MacScrollerPair, _ pair: WebCore.ScrollerPairMac) {
        state.withLock { state in
            CATransaction.lock()

            scrollerImpDelegate.withLock { $0 }?.invalidate()
            let delegate = WebScrollerImpDelegateMac(scrollerPair: scrollerPair, orientation: orientation)
            scrollerImpDelegate.withLock { $0 = delegate }
            setScrollerImp(pair, makeScrollerImp(scrollerPair, pair))
            if let scrollerImp = state.scrollerImp {
                WebCore.bindScrollerImpDelegate(scrollerImp, delegate)
            }

            CATransaction.unlock()
        }
    }

    func detach() {
        state.withLock { state in
            scrollerImpDelegate.withLock { $0 }?.invalidate()
            if let scrollerImp = state.scrollerImp {
                WebCore.bindScrollerImpDelegate(scrollerImp, nil)
            }
        }
    }

    func setHostLayer(_ pair: WebCore.ScrollerPairMac, _ layer: CALayer?) {
        state.withLock { state in
            state.hostLayer = layer
            setReferences(pair, state)

            state.scrollerImp?.layer = layer

            updatePairScrollerImps(pair, state)
        }
    }

    func setHiddenByStyle(_ scrollerPair: MacScrollerPair, _ pair: WebCore.ScrollerPairMac, _ isHiddenByStyle: Bool) {
        state.withLock { state in
            CATransaction.lock()

            state.isHiddenByStyle = isHiddenByStyle
            if isHiddenByStyle {
                detach()
                setScrollerImp(pair, nil)
            } else {
                attach(scrollerPair, pair)
                state.scrollerImp?.layer = state.hostLayer
                updateValues(pair)
            }
            updatePairScrollerImps(pair, state)

            CATransaction.unlock()
        }
    }

    func updateValues(_ pair: WebCore.ScrollerPairMac) {
        state.withLock { state in
            let values = pair.valuesForOrientation(orientation)

            let enabled = isEnabled.load(ordering: .relaxed)
            let layoutDirection = userInterfaceLayoutDirection
            state.scrollerImp?.isEnabled = enabled
            state.scrollerImp?.userInterfaceLayoutDirection = layoutDirection
            let boundsSize = state.hostLayer?.bounds.size ?? .zero
            state.scrollerImp?.boundsSize = boundsSize
            state.scrollerImp?.doubleValue = Double(values.value)
            state.scrollerImp?.presentationValue = Double(values.value)
            state.scrollerImp?.knobProportion = CGFloat(values.proportion)
            state.scrollerImp?.trackColor = state.trackColor
            state.scrollerImp?.knobColor = state.thumbColor
        }
    }

    /// Gives the scroller a new NSScrollerImp, for a new scrollbar style or width.
    func updateScrollbarStyle(_ scrollerPair: MacScrollerPair, _ pair: WebCore.ScrollerPairMac) {
        state.withLock { state in
            CATransaction.lock()

            setScrollerImp(pair, makeScrollerImp(scrollerPair, pair))
            if let scrollerImp = state.scrollerImp {
                WebCore.bindScrollerImpDelegate(scrollerImp, scrollerImpDelegate.withLock { $0 })
            }

            state.scrollerImp?.layer = state.hostLayer

            updatePairScrollerImps(pair, state)
            updateValues(pair)

            CATransaction.unlock()
        }
    }

    /// Hands the scroller's NSScrollerImp to the NSScrollerImpPair, on the main thread.
    private func updatePairScrollerImps(_ pair: WebCore.ScrollerPairMac, _ state: borrowing MacScrollerImpState.Locked) {
        let orientation = orientation
        pair.ensureOnMainThreadWithScrollerImp(state.scrollerImp) { scrollerImpPair, scrollerImp in
            if orientation == .Vertical {
                scrollerImpPair?.verticalScrollerImp = scrollerImp
            } else {
                scrollerImpPair?.horizontalScrollerImp = scrollerImp
            }
        }
    }

    /// Gives ScrollerPairMac copies of the scroller's NSScrollerImp and host layer.
    ///
    /// The copies are for readers that do not take the scroller's lock. Every store to either calls this before the
    /// lock is released.
    private func setReferences(_ pair: WebCore.ScrollerPairMac, _ state: borrowing MacScrollerImpState.Locked) {
        pair.setScrollerReferences(orientation, state.scrollerImp, state.hostLayer)
    }

    func setScrollerImp(_ pair: WebCore.ScrollerPairMac, _ scrollerImp: NSScrollerImp?) {
        state.withLock { state in
            if state.isHiddenByStyle && scrollerImp != nil {
                return
            }
            state.scrollerImp = scrollerImp
            setReferences(pair, state)
            updateMinimumKnobLength(pair, knobLength(state.scrollerImp?.knobMinLength ?? 0))
        }
    }

    private func updateMinimumKnobLength(_ pair: WebCore.ScrollerPairMac, _ minimumKnobLength: Int32) {
        if self.minimumKnobLength.load(ordering: .relaxed) == minimumKnobLength {
            return
        }
        self.minimumKnobLength.store(minimumKnobLength, ordering: .relaxed)

        if let node = pair.node().get() {
            node.scrollbarMinimumThumbLengthDidChange(orientation, minimumKnobLength)
        }
    }

    func setScrollbarLayoutDirection(
        _ scrollerPair: MacScrollerPair,
        _ pair: WebCore.ScrollerPairMac,
        _ direction: WebCore.UserInterfaceLayoutDirection
    ) {
        state.withLock { state in
            let isRightToLeft = direction == .RTL
            if self.isRightToLeft.load(ordering: .relaxed) == isRightToLeft {
                return
            }

            self.isRightToLeft.store(isRightToLeft, ordering: .relaxed)
            updateScrollbarStyle(scrollerPair, pair)
            state.scrollerImp?.userInterfaceLayoutDirection = isRightToLeft ? .rightToLeft : .leftToRight
        }
    }

    func setNeedsDisplay() {
        state.withLock { state in
            state.scrollerImp?.setNeedsDisplay(true)
        }
    }

    func scrollbarColorChanged(_ pair: WebCore.ScrollerPairMac, _ trackColor: NSColor?, _ thumbColor: NSColor?) {
        state.withLock { state in
            state.trackColor = trackColor
            state.thumbColor = thumbColor
        }
        updateValues(pair)
    }

    /// Moves the NSScrollerImp, or nil, to the end of the ones waiting for releaseTakenScrollerImp.
    func takeScrollerImp(_ pair: WebCore.ScrollerPairMac) {
        state.withLock { state in
            state.appendScrollerImpToRelease(state.scrollerImp)
            state.scrollerImp = nil
            setReferences(pair, state)
        }
    }

    /// Releases the oldest NSScrollerImp takeScrollerImp kept.
    func releaseTakenScrollerImp() {
        state.withLock { state in
            _ = state.removeOldestScrollerImpToRelease()
        }
    }

    func setUsePresentationValue(_ inMomentumPhase: Bool) {
        state.withLock { state in
            state.scrollerImp?.shouldUsePresentationValue = inMomentumPhase
        }
    }

    func knobAlpha() -> CGFloat {
        state.withLock { state in
            state.scrollerImp?.knobAlpha ?? 0
        }
    }

    func trackAlpha() -> CGFloat {
        state.withLock { state in
            state.scrollerImp?.trackAlpha ?? 0
        }
    }

    func hasScrollerImp() -> Bool {
        state.withLock { state in
            state.scrollerImp != nil
        }
    }

    /// What layout tests read through internals: "none" without a host layer or NSScrollerImp, the enabled state, and
    /// for overlay scrollbars what is shown and how.
    func scrollbarState(_ style: WebCore.ScrollbarStyle) -> ScrollbarStateText {
        state.withLock { state in
            guard state.hostLayer != nil, state.scrollerImp != nil else {
                return ScrollbarStateText()
            }

            var text = ScrollbarStateText()
            text.hasScrollerImp = true
            text.isEnabled = state.scrollerImp?.isEnabled ?? false
            if style != .Overlay {
                return text
            }

            text.isOverlay = true
            text.isExpanded = state.scrollerImp?.isExpanded ?? false
            text.showsTrack = (state.scrollerImp?.trackAlpha ?? 0) > 0
            text.showsKnob = (state.scrollerImp?.knobAlpha ?? 0) > 0
            text.isRightToLeft = state.scrollerImp?.userInterfaceLayoutDirection == .rightToLeft
            text.isThin = (state.scrollerImp?.controlSize ?? .regular) != .regular
            text.trackColor = state.scrollerImp?.trackColor
            text.knobColor = state.scrollerImp?.knobColor
            return text
        }
    }

    func setLastKnownMousePositionInScrollbar(_ position: WebCore.IntPoint) {
        let x = UInt64(UInt32(bitPattern: position.x()))
        let y = UInt64(UInt32(bitPattern: position.y()))
        lastKnownMousePosition.store(x << 32 | y, ordering: .relaxed)
    }

    var lastKnownMousePositionInScrollbar: NSPoint {
        let position = lastKnownMousePosition.load(ordering: .relaxed)
        let x = Int32(bitPattern: UInt32(truncatingIfNeeded: position >> 32))
        let y = Int32(bitPattern: UInt32(truncatingIfNeeded: position))
        return NSPoint(x: CGFloat(x), y: CGFloat(y))
    }
}

// MARK: - ScrollbarStateText

/// A scroller's state as scrollbarState reads it under the lock.
///
/// The text is built in a 64-character buffer on the stack, or in an array when it is longer or a color's description
/// has 16-bit characters.
private struct ScrollbarStateText {
    var hasScrollerImp = false
    var isEnabled = false
    var isOverlay = false
    var isExpanded = false
    var showsTrack = false
    var showsKnob = false
    var isRightToLeft = false
    var isThin = false
    var trackColor: NSColor?
    var knobColor: NSColor?

    var text: WTF.String {
        let trackDescription = trackColor.map { WebCore.scrollbarColorDescription($0) }
        let knobDescription = knobColor.map { WebCore.scrollbarColorDescription($0) }
        var buffer = InlineScrollbarStateText()
        write(to: &buffer, trackColor: trackDescription, knobColor: knobDescription)
        if buffer.needsArray {
            return arrayText(trackColor: trackDescription, knobColor: knobDescription)
        }
        return WTF.String(buffer.characters.span.extracting(..<buffer.count))
    }

    @inline(never)
    private func arrayText(trackColor: WTF.String?, knobColor: WTF.String?) -> WTF.String {
        if trackColor?.is8Bit() ?? true, knobColor?.is8Bit() ?? true {
            var latin1 = ScrollbarStateTextArray<WTF.Latin1Character>()
            write(to: &latin1, trackColor: trackColor, knobColor: knobColor)
            return WTF.String(latin1.characters.span)
        }
        var utf16 = ScrollbarStateTextArray<UInt16>()
        write(to: &utf16, trackColor: trackColor, knobColor: knobColor)
        return WTF.String(utf16.characters.span)
    }

    private func write(to sink: inout some ScrollbarStateTextSink, trackColor: WTF.String?, knobColor: WTF.String?) {
        guard hasScrollerImp else {
            sink.append("none")
            return
        }
        sink.append(isEnabled ? "enabled" : "disabled")
        guard isOverlay else {
            return
        }
        if isExpanded {
            sink.append(",expanded")
        }
        if showsTrack {
            sink.append(",visible_track")
        }
        if showsKnob {
            sink.append(",visible_thumb")
        }
        if isRightToLeft {
            sink.append(",RTL")
        }
        if isThin {
            sink.append(",thin")
        }
        if let trackColor {
            sink.append(",trackColor:")
            sink.append(characters: trackColor)
        }
        if let knobColor {
            sink.append(",knobColor:")
            sink.append(characters: knobColor)
        }
    }
}

private protocol ScrollbarStateTextSink {
    mutating func append(_ ascii: Swift.String)
    mutating func append(characters string: borrowing WTF.String)
}

private struct InlineScrollbarStateText: ScrollbarStateTextSink {
    var characters = InlineArray<64, WTF.Latin1Character>(repeating: .fromCodeUnit(0))
    var count = 0
    // Set when the text does not fit or has a 16-bit character, so the text is built in an array instead.
    var needsArray = false

    mutating func append(_ ascii: Swift.String) {
        let bytes = ascii.utf8.span
        // count is at most 64 and the addend is a buffer's length, so neither this sum nor the two below can overflow.
        guard !needsArray, count &+ bytes.count <= characters.count else {
            needsArray = true
            return
        }
        var out = characters.mutableSpan
        for index in bytes.indices {
            out[count &+ index].value = bytes[index]
        }
        count &+= bytes.count
    }

    mutating func append(characters string: borrowing WTF.String) {
        guard string.is8Bit() else {
            needsArray = true
            return
        }
        let source: Span<WTF.Latin1Character> = string.span8()
        // count is at most 64 and the addend is a buffer's length, so neither this sum nor the two below can overflow.
        guard !needsArray, count &+ source.count <= characters.count else {
            needsArray = true
            return
        }
        var out = characters.mutableSpan
        for index in source.indices {
            out[count &+ index] = source[index]
        }
        count &+= source.count
    }
}

private protocol ScrollbarStateCharacter {
    static func fromCodeUnit(_ codeUnit: UInt16) -> Self
}

extension WTF.Latin1Character: ScrollbarStateCharacter {
    // The Latin-1 array is used only when every character fits in 8 bits.
    static func fromCodeUnit(_ codeUnit: UInt16) -> WTF.Latin1Character {
        var character = WTF.Latin1Character()
        character.value = UInt8(truncatingIfNeeded: codeUnit)
        return character
    }
}

extension UInt16: ScrollbarStateCharacter {
    static func fromCodeUnit(_ codeUnit: UInt16) -> UInt16 {
        codeUnit
    }
}

private struct ScrollbarStateTextArray<CodeUnit: ScrollbarStateCharacter>: ScrollbarStateTextSink {
    var characters: [CodeUnit] = []

    mutating func append(_ ascii: Swift.String) {
        for byte in ascii.utf8 {
            characters.append(.fromCodeUnit(UInt16(byte)))
        }
    }

    mutating func append(characters string: borrowing WTF.String) {
        if string.is8Bit() {
            let source: Span<WTF.Latin1Character> = string.span8()
            for index in source.indices {
                characters.append(.fromCodeUnit(UInt16(source[index].value)))
            }
        } else {
            let source: Span<UInt16> = string.span16()
            for index in source.indices {
                characters.append(.fromCodeUnit(source[index]))
            }
        }
    }
}

// NSScrollerImp's knobMinLength as an int: toward zero, saturating at the int range, and 0 for NaN, where the C++
// conversion is undefined.
private func knobLength(_ value: CGFloat) -> Int32 {
    if value.isNaN {
        return 0
    }
    if value >= CGFloat(Int32.max) {
        return .max
    }
    if value <= CGFloat(Int32.min) {
        return .min
    }
    return Int32(value)
}

// MARK: - WebScrollerImpPairDelegateMac

private final class WebScrollerImpPairDelegateMac: NSObject, NSScrollerImpPairDelegate, Sendable {
    private weak let scrollerPair: MacScrollerPair?
    private let isInvalidated = Atomic<Bool>(false)

    init(scrollerPair: MacScrollerPair) {
        self.scrollerPair = scrollerPair
    }

    func invalidate() {
        isInvalidated.store(true, ordering: .relaxed)
    }

    /// The pair, while ScrollerPairMac is alive and this is its delegate.
    private var liveScrollerPair: (MacScrollerPair, WebCore.ScrollerPairMac)? {
        guard !isInvalidated.load(ordering: .relaxed), let scrollerPair, let pair = scrollerPair.pair.get().get() else {
            return nil
        }
        return (scrollerPair, pair)
    }

    @objc(contentAreaRectForScrollerImpPair:)
    func contentAreaRect(for scrollerImpPair: NSScrollerImpPair!) -> NSRect {
        guard let (_, pair) = liveScrollerPair else {
            return .zero
        }

        let size = pair.visibleSize()
        return NSRect(x: 0, y: 0, width: CGFloat(size.width()), height: CGFloat(size.height()))
    }

    @objc(inLiveResizeForScrollerImpPair:)
    func inLiveResize(for scrollerImpPair: NSScrollerImpPair!) -> Bool {
        guard let (scrollerPair, _) = liveScrollerPair else {
            return false
        }

        return scrollerPair.inLiveResize.load(ordering: .relaxed)
    }

    // This location is only used when calling mouseLocationInScrollerForScrollerImp:, which uses the converted mouse
    // position from the web process.
    @objc(mouseLocationInContentAreaForScrollerImpPair:)
    func mouseLocationInContentArea(for scrollerImpPair: NSScrollerImpPair!) -> NSPoint {
        .zero
    }

    func scrollerImpPair(
        _ scrollerImpPair: NSScrollerImpPair!,
        convertContentPoint pointInContentArea: NSPoint,
        to scrollerImp: NSScrollerImp!
    ) -> NSPoint {
        guard let (scrollerPair, _) = liveScrollerPair, let scrollerImp else {
            return .zero
        }

        return scrollerPair.lastKnownMousePositionInScrollbar(scrollerImp.isHorizontal ? .Horizontal : .Vertical)
    }

    func scrollerImpPair(_ scrollerImpPair: NSScrollerImpPair!, setContentAreaNeedsDisplayIn rect: NSRect) {
    }

    func scrollerImpPair(
        _ scrollerImpPair: NSScrollerImpPair!,
        updateScrollerStyleForNewRecommendedScrollerStyle newRecommendedScrollerStyle: NSScroller.Style
    ) {
        guard let (scrollerPair, pair) = liveScrollerPair else {
            return
        }

        scrollerPair.setScrollbarStyle(pair, WebCore.scrollbarStyle(newRecommendedScrollerStyle))
    }
}

// MARK: - WebScrollerImpDelegateMac

/// One WebScrollerImpDelegateMac's knob, track and transition animations, reached only inside its animations lock.
private struct ScrollbarPartAnimations {
    var knobAlpha: WebScrollbarPartAnimationMac?
    var trackAlpha: WebScrollbarPartAnimationMac?
    var uiStateTransition: WebScrollbarPartAnimationMac?
    var expansionTransition: WebScrollbarPartAnimationMac?

    subscript(_ feature: WebCore.ScrollbarPartFeature) -> WebScrollbarPartAnimationMac? {
        get {
            switch feature {
            case .KnobAlpha: knobAlpha
            case .TrackAlpha: trackAlpha
            case .UIStateTransition: uiStateTransition
            case .ExpansionTransition: expansionTransition
            @unknown default: nil
            }
        }
        set {
            switch feature {
            case .KnobAlpha: knobAlpha = newValue
            case .TrackAlpha: trackAlpha = newValue
            case .UIStateTransition: uiStateTransition = newValue
            case .ExpansionTransition: expansionTransition = newValue
            @unknown default: break
            }
        }
    }
}

private final class WebScrollerImpDelegateMac: NSObject, NSAnimationDelegate, NSScrollerImpDelegate, Sendable {
    private weak let scrollerPair: MacScrollerPair?
    private let orientation: WebCore.ScrollbarOrientation
    private let isInvalidated = Atomic<Bool>(false)
    private let animations = Mutex(ScrollbarPartAnimations())

    init(scrollerPair: MacScrollerPair, orientation: WebCore.ScrollbarOrientation) {
        self.scrollerPair = scrollerPair
        self.orientation = orientation
    }

    /// The scroller's pair, until this delegate is invalidated.
    private var liveScrollerPair: MacScrollerPair? {
        isInvalidated.load(ordering: .relaxed) ? nil : scrollerPair
    }

    func invalidate() {
        isInvalidated.store(true, ordering: .relaxed)
        animations.withLock { animations in
            animations.knobAlpha?.invalidate()
            animations.trackAlpha?.invalidate()
            animations.uiStateTransition?.invalidate()
            animations.expansionTransition?.invalidate()
        }
    }

    @objc(convertRectToBacking:)
    func convertRectToBacking(_ aRect: NSRect) -> NSRect {
        aRect
    }

    @objc(convertRectFromBacking:)
    func convertRectFromBacking(_ aRect: NSRect) -> NSRect {
        aRect
    }

    @objc(layer)
    func layer() -> CALayer! {
        nil
    }

    func mouseLocationInScroller(for scrollerImp: NSScrollerImp!) -> NSPoint {
        guard let scrollerPair = liveScrollerPair else {
            return .zero
        }

        return scrollerPair.lastKnownMousePositionInScrollbar(orientation)
    }

    @objc(convertRectToLayer:)
    func convertRect(toLayer rect: NSRect) -> NSRect {
        rect
    }

    @objc(shouldUseLayerPerPartForScrollerImp:)
    func shouldUseLayerPerPart(for scrollerImp: NSScrollerImp!) -> Bool {
        true
    }

    func effectiveAppearance(for scrollerImp: NSScrollerImp!) -> NSAppearance! {
        guard let scrollerPair = liveScrollerPair, scrollerPair.hasPair else {
            return NSAppearance.currentDrawing()
        }

        // The base system does not support dark Aqua, so the named appearance can be nil.
        let name: NSAppearance.Name = scrollerPair.useDarkAppearance.load(ordering: .relaxed) ? .darkAqua : .aqua
        return NSAppearance(named: name) ?? NSAppearance.currentDrawing()
    }

    /// Replaces the knob or track alpha animation with one from the current alpha to newAlpha.
    private func setUpAlphaAnimation(
        _ featureToAnimate: WebCore.ScrollbarPartFeature,
        animateAlphaTo newAlpha: CGFloat,
        duration: TimeInterval
    ) {
        animations.withLock { animations in
            if let animation = animations[featureToAnimate] {
                animation.invalidate()
                animations[featureToAnimate] = nil
            }
        }

        guard let scrollerPair = liveScrollerPair else {
            return
        }
        let scroller = scrollerPair.scroller(orientation)
        let currentAlpha = featureToAnimate == .KnobAlpha ? scroller.knobAlpha() : scroller.trackAlpha()

        animations.withLock { animations in
            let animation = WebScrollbarPartAnimationMac(
                scrollerPair: scrollerPair,
                orientation: orientation,
                featureToAnimate: featureToAnimate,
                animateFrom: currentAlpha,
                animateTo: newAlpha,
                duration: duration
            )
            animations[featureToAnimate] = animation
            animation.start()
        }
    }

    /// Starts the UI state or expansion transition animation, which always animates to 1, from where the current one
    /// is, so that an animation in progress does not end in a hard transition.
    private func setUpTransitionAnimation(
        _ scrollerPair: MacScrollerPair,
        _ featureToAnimate: WebCore.ScrollbarPartFeature,
        startValue: CGFloat,
        duration: TimeInterval
    ) {
        animations.withLock { animations in
            if let animation = animations[featureToAnimate] {
                animation.setStartValue(startValue)
                animation.setEndValue(1)
                animation.duration = duration
                animation.start()
            } else {
                let animation = WebScrollbarPartAnimationMac(
                    scrollerPair: scrollerPair,
                    orientation: orientation,
                    featureToAnimate: featureToAnimate,
                    animateFrom: startValue,
                    animateTo: 1,
                    duration: duration
                )
                animations[featureToAnimate] = animation
                animation.start()
            }
        }
    }

    func scrollerImp(_ scrollerImp: NSScrollerImp!, animateKnobAlphaTo newKnobAlpha: CGFloat, duration: TimeInterval) {
        guard let scrollerPair = liveScrollerPair else {
            return
        }

        scrollerPair.visibilityChanged(orientation, newKnobAlpha > 0)
        setUpAlphaAnimation(.KnobAlpha, animateAlphaTo: newKnobAlpha, duration: duration)
    }

    func scrollerImp(_ scrollerImp: NSScrollerImp!, animateTrackAlphaTo newTrackAlpha: CGFloat, duration: TimeInterval) {
        guard liveScrollerPair != nil else {
            return
        }

        setUpAlphaAnimation(.TrackAlpha, animateAlphaTo: newTrackAlpha, duration: duration)
    }

    func scrollerImp(_ scrollerImp: NSScrollerImp!, animateUIStateTransitionWithDuration duration: TimeInterval) {
        guard let scrollerPair = liveScrollerPair else {
            return
        }

        let progress = scrollerImp?.uiStateTransitionProgress ?? 0
        scrollerImp?.uiStateTransitionProgress = 1 - progress
        setUpTransitionAnimation(
            scrollerPair,
            .UIStateTransition,
            startValue: scrollerImp?.uiStateTransitionProgress ?? 0,
            duration: duration
        )
    }

    func scrollerImp(_ scrollerImp: NSScrollerImp!, animateExpansionTransitionWithDuration duration: TimeInterval) {
        guard let scrollerPair = liveScrollerPair else {
            return
        }

        let progress = scrollerImp?.expansionTransitionProgress ?? 0
        scrollerImp?.expansionTransitionProgress = 1 - progress
        setUpTransitionAnimation(
            scrollerPair,
            .ExpansionTransition,
            startValue: scrollerImp?.expansionTransitionProgress ?? 0,
            duration: duration
        )
    }

    func scrollerImp(
        _ scrollerImp: NSScrollerImp!,
        overlayScrollerStateChangedTo newOverlayScrollerState: NSOverlayScrollerState
    ) {
    }
}

// MARK: - WebScrollbarPartAnimationMac

/// Animates one part of a scroller's NSScrollerImp.
///
/// NSAnimation is not Sendable, so an animation is reached only inside its delegate's animations lock and from AppKit's
/// progress callbacks.
private final class WebScrollbarPartAnimationMac: NSAnimation {
    private weak let scrollerPair: MacScrollerPair?
    private let orientation: WebCore.ScrollbarOrientation
    private let featureToAnimate: WebCore.ScrollbarPartFeature
    private let startValue: Atomic<UInt64>
    private let endValue: Atomic<UInt64>
    private let isInvalidated = Atomic<Bool>(false)

    init(
        scrollerPair: MacScrollerPair,
        orientation: WebCore.ScrollbarOrientation,
        featureToAnimate: WebCore.ScrollbarPartFeature,
        animateFrom startValue: CGFloat,
        animateTo endValue: CGFloat,
        duration: TimeInterval
    ) {
        self.scrollerPair = scrollerPair
        self.orientation = orientation
        self.featureToAnimate = featureToAnimate
        self.startValue = Atomic(Double(startValue).bitPattern)
        self.endValue = Atomic(Double(endValue).bitPattern)
        super.init(duration: duration, animationCurve: .easeInOut)
        animationBlockingMode = .nonblocking
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setStartValue(_ startValue: CGFloat) {
        self.startValue.store(Double(startValue).bitPattern, ordering: .relaxed)
    }

    func setEndValue(_ endValue: CGFloat) {
        self.endValue.store(Double(endValue).bitPattern, ordering: .relaxed)
    }

    /// Sets the part from the progress, which runs from 1 to 0 when the animation goes down.
    override var currentProgress: NSAnimation.Progress {
        get { super.currentProgress }
        set {
            super.currentProgress = newValue

            guard !isInvalidated.load(ordering: .relaxed), let scrollerPair else {
                return
            }

            let startValue = Double(bitPattern: startValue.load(ordering: .relaxed))
            let endValue = Double(bitPattern: endValue.load(ordering: .relaxed))
            let currentValue = startValue > endValue ? CGFloat(1 - newValue) : CGFloat(newValue)

            scrollerPair.updateProgress(orientation, featureToAnimate, currentValue)
        }
    }

    func invalidate() {
        stop()
        isInvalidated.store(true, ordering: .relaxed)
    }
}

#endif // os(macOS)
