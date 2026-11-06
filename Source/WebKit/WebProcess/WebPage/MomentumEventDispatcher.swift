// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_MOMENTUM_EVENT_DISPATCHER

import Darwin
import WebKit_Internal
internal import Synchronization
internal import os

private let deltaHistoryMaximumAge = 0.5
private let deltaHistoryMaximumInterval = 0.15
private let deltaHistoryQueueSize = 9
private let idealCurveFrameRate: Float = 60
private let idealCurveFrameInterval = 1.0 / 60.0
// The capacity a gesture's tables keep for the next gesture; above it, they are released when the gesture ends.
private let retainedTableCapacity = 256
// The tail deltas equalizeTailGaps() sorts with an insertion sort, at most; it sorts more with sort().
private let insertionSortMaximumCount = 64

private let scrollAnimationsLog = Logger(subsystem: "com.apple.WebKit", category: "ScrollAnimations")

// WebEventPhase and WebWheelEventMomentumEndType values; MomentumEventDispatcher.cpp static_asserts them.
private let phaseBegan: UInt8 = 1
private let phaseChanged: UInt8 = 3
private let phaseEnded: UInt8 = 4
private let momentumEndTypeInterrupted: UInt8 = 1
private let momentumEndTypeNatural: UInt8 = 2

private struct Size {
    var width: Float = 0
    var height: Float = 0

    static func + (a: Size, b: Size) -> Size { Size(width: a.width + b.width, height: a.height + b.height) }
    static func - (a: Size, b: Size) -> Size { Size(width: a.width - b.width, height: a.height - b.height) }
    static func * (a: Size, s: Float) -> Size { Size(width: a.width * s, height: a.height * s) }
    static prefix func - (a: Size) -> Size { Size(width: -a.width, height: -a.height) }

    // FloatSize::isZero().
    var isZero: Bool { abs(width) < Float.ulpOfOne && abs(height) < Float.ulpOfOne }
}

// clampTo<int>(roundf(value)), as roundedIntSize() does it: NaN clamps to the minimum.
private func roundedToClampedInt(_ value: Float) -> Float {
    let rounded = value.rounded(.toNearestOrAwayFromZero)
    if rounded >= 2_147_483_648 {
        return Float(Int32.max)
    }
    if !(rounded > -2_147_483_648) {
        return Float(Int32.min)
    }
    return Float(Int32(rounded))
}

private func roundedIntSize(_ size: Size) -> Size {
    Size(width: roundedToClampedInt(size.width), height: roundedToClampedInt(size.height))
}

// floor(value) converted to an unsigned long, saturating at both ends (0 for NaN).
private func saturatingUnsignedFloor(_ value: Float) -> UInt {
    let floored = value.rounded(.down)
    if !(floored > 0) {
        return 0
    }
    if floored >= 18_446_744_073_709_551_616 {
        return UInt.max
    }
    return UInt(floored)
}

private func interpolate(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a.addingProduct(t, b - a)
}

private func momentumDecayRate(_ delta: Size, _ frameInterval: Double) -> Float {
    let defaultDecay: Float = 0.975
    let tailVelocity: Float = 250
    let tailDecay: Float = 0.91
    var alpha = defaultDecay

    if frameInterval != 0 {
        let initialVelocity = Float(Double(hypotf(delta.width, delta.height)) / frameInterval)
        let momentumShare = (tailVelocity - initialVelocity) / tailVelocity
        let weakMomentum: Float = 0 < momentumShare ? momentumShare : 0
        alpha = defaultDecay.addingProduct(weakMomentum, -(defaultDecay - tailDecay))
    }

    return Float(pow(Double(alpha), frameInterval / Double(Float(0.008))))
}

private func fromFixedPoint(_ value: Float) -> Float {
    value / 65536
}

private struct Delta {
    var rawPlatformDelta: Float
    var frameInterval: Double
}

private struct DisplayProperties {
    var displayID: UInt32
    var nominalFrameRate: UInt32
}

private struct AccelerationCurveParameters: Sendable {
    var gainLinear: Float
    var gainParabolic: Float
    var gainCubic: Float
    var gainQuartic: Float
    var tangentSpeedLinear: Float
    var tangentSpeedParabolicRoot: Float
    var resolution: Float
    var frameRate: Float

    var curve: WebKit.ScrollingAccelerationCurve {
        WebKit.ScrollingAccelerationCurve(
            gainLinear,
            gainParabolic,
            gainCubic,
            gainQuartic,
            tangentSpeedLinear,
            tangentSpeedParabolicRoot,
            resolution,
            frameRate
        )
    }
}

private enum MomentumCurve {
    case standard
    case simple
}

// The newest deltaHistoryQueueSize deltas of one axis, newest first, like a Deque<Delta, deltaHistoryQueueSize>.
private struct DeltaHistory: ~Copyable {
    private static let capacity = 16
    private static let indexMask = capacity - 1

    private var deltas = InlineArray<16, Delta>(repeating: Delta(rawPlatformDelta: 0, frameInterval: 0))
    private var head = 0
    private(set) var count = 0

    var isEmpty: Bool { count == 0 }

    // The index'th newest delta; index is below count.
    subscript(index: Int) -> Delta {
        // head is below capacity and index below deltaHistoryQueueSize, so this cannot wrap.
        deltas[(head &+ index) & Self.indexMask]
    }

    mutating func removeAll() {
        count = 0
    }

    mutating func prepend(_ delta: Delta) {
        // head is below capacity, so this cannot wrap.
        head = (head &+ Self.indexMask) & Self.indexMask
        deltas[head] = delta
        // count is at most deltaHistoryQueueSize, so this cannot wrap.
        count = min(count &+ 1, deltaHistoryQueueSize)
    }

    // value accelerated by accelerationCurve at the velocity of these deltas.
    borrowing func accelerate(_ value: Float, _ accelerationCurve: inout WebKit.ScrollingAccelerationCurve) -> Float {
        var totalDelta: Float = 0
        var totalTime = 0.0
        var deltaCount: UInt32 = 0

        for index in 0..<self.count {
            let delta = self[index]
            totalDelta += abs(delta.rawPlatformDelta)
            // At most deltaHistoryQueueSize, so this cannot wrap.
            deltaCount &+= 1

            if delta.frameInterval > deltaHistoryMaximumInterval {
                totalTime += deltaHistoryMaximumInterval
                break
            }

            totalTime += delta.frameInterval

            if totalTime >= deltaHistoryMaximumAge {
                break
            }
        }

        let averageTime = totalTime / Double(deltaCount)
        let averageFrameInterval =
            averageTime < 0.001 ? 0.001 : (deltaHistoryMaximumInterval < averageTime ? deltaHistoryMaximumInterval : averageTime)
        let averageFrameIntervalMS = Float(averageFrameInterval * 1000)
        let averageDelta = totalDelta / Float(deltaCount)

        let velocityGainA = fromFixedPoint(2)
        let velocityGainB = fromFixedPoint(955)
        let velocityConstant = fromFixedPoint(98369)
        let minimumVelocity = fromFixedPoint(1)

        let gain = (averageFrameIntervalMS * -velocityGainB).addingProduct(velocityGainA * averageFrameIntervalMS, averageFrameIntervalMS)
        var velocity = (gain + velocityConstant) * averageDelta
        velocity = velocity < minimumVelocity ? minimumVelocity : velocity

        // FIXME: This math is incomplete if we need to support acceleration tables as well.
        let multiplier = accelerationCurve.accelerationFactor(velocity) / velocity
        return value * multiplier
    }
}

private struct Gesture {
    var active = false
    var momentumCurve = MomentumCurve.standard
    var pageIdentifier: UInt64?
    var accelerationCurve: WebKit.ScrollingAccelerationCurve?
    var initiatingEventDirectionInvertedFromDevice = false
    var currentOffset = Size()
    var startTime = 0.0
    var offsetTable: [Size] = [] // Always at 60Hz intervals.
    var tailDeltaTable: [Size] = [] // Always at event dispatch intervals.
    var tailStartDelay = 0.0
    var currentTailDeltaIndex: UInt32 = 0
    // The page's display properties, kept equal to its entry in displayProperties while the gesture is active.
    var displayProperties = DisplayProperties(displayID: 0, nominalFrameRate: 0)

    // Like assigning Gesture(), but the tables keep their capacity for the next gesture, up to retainedTableCapacity.
    mutating func reset() {
        active = false
        momentumCurve = .standard
        pageIdentifier = nil
        accelerationCurve = nil
        initiatingEventDirectionInvertedFromDevice = false
        currentOffset = Size()
        startTime = 0
        removeAllKeepingCapacityUpToRetained(&offsetTable)
        removeAllKeepingCapacityUpToRetained(&tailDeltaTable)
        tailStartDelay = 0
        currentTailDeltaIndex = 0
        displayProperties = DisplayProperties(displayID: 0, nominalFrameRate: 0)
    }
}

// Empties table, keeping its capacity unless that is above retainedTableCapacity.
private func removeAllKeepingCapacityUpToRetained<Element>(_ table: inout [Element]) {
    if table.capacity > retainedTableCapacity {
        table = []
    } else {
        table.removeAll(keepingCapacity: true)
    }
}

/// What the C++ MomentumEventDispatcher does with its client after an entry returns, in this order: an Ended event
/// and didEndSyntheticMomentumScrolling(), stopping the display link, starting a gesture (and with it the display
/// link and the Began event), and a Changed event.
@_expose(Cxx)
struct MomentumActions {
    // @used ensures these, and the type metadata, are retained even under -O -wmo: rdar://179098545
    @used
    static let cxxTypeMetadata: Any.Type = Self.self

    fileprivate static let endsGestureBit: UInt8 = 1 << 0
    fileprivate static let stopsDisplayLinkBit: UInt8 = 1 << 1
    fileprivate static let beginsGestureBit: UInt8 = 1 << 2
    fileprivate static let startsDisplayLinkBit: UInt8 = 1 << 3
    fileprivate static let dispatchesChangedEventBit: UInt8 = 1 << 4
    fileprivate static let ignoresEventBit: UInt8 = 1 << 5

    fileprivate var stepBits: UInt8 = 0
    fileprivate var endTypeValue: UInt8 = 0
    fileprivate var stopDisplayIDValue: UInt32 = 0
    fileprivate var startDisplayIDValue: UInt32 = 0
    fileprivate var changedDelta = Size()

    fileprivate init() {
    }

    @used
    func endsGesture() -> Bool { stepBits & Self.endsGestureBit != 0 }
    @used
    func stopsDisplayLink() -> Bool { stepBits & Self.stopsDisplayLinkBit != 0 }
    @used
    func beginsGesture() -> Bool { stepBits & Self.beginsGestureBit != 0 }
    @used
    func startsDisplayLink() -> Bool { stepBits & Self.startsDisplayLinkBit != 0 }
    @used
    func dispatchesChangedEvent() -> Bool { stepBits & Self.dispatchesChangedEventBit != 0 }
    @used
    func ignoresEvent() -> Bool { stepBits & Self.ignoresEventBit != 0 }
    @used
    func endType() -> UInt8 { endTypeValue }
    @used
    func stopDisplayID() -> UInt32 { stopDisplayIDValue }
    @used
    func startDisplayID() -> UInt32 { startDisplayIDValue }
    @used
    func changedDeltaWidth() -> Float { changedDelta.width }
    @used
    func changedDeltaHeight() -> Float { changedDelta.height }
}

private typealias AccelerationCurves = Mutex<[UInt64: AccelerationCurveParameters?]>

/// The state of one MomentumEventDispatcher. Every entry but the curve setter runs on the dispatcher's client's
/// thread, which serializes them: the web process's event dispatcher queue, or in the UI process the scrolling thread
/// or main thread under RemoteLayerTreeEventDispatcher's momentum dispatcher lock, or the main thread for the AppKit
/// gesture controller. The acceleration curves are set from other threads, so they have their own lock.
@_expose(Cxx)
final class MomentumEventDispatcherState {
    // No access to dispatcher makes a call that can release an object, so its exclusivity check need not record the access.
    private var dispatcher = MomentumDispatcher()
    private let accelerationCurves = AccelerationCurves([:])

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init() {
    }

    fileprivate func setScrollingAccelerationCurve(_ pageIdentifier: UInt64, _ curve: AccelerationCurveParameters?) {
        accelerationCurves.withLock { $0[pageIdentifier] = curve }
    }

    fileprivate func handleWheelEvent(
        _ pageIdentifier: UInt64,
        _ event: WheelEvent,
        _ now: Double,
        _ actions: inout MomentumActions
    ) {
        if dispatcher.swallowsMomentumChangedEvent(pageIdentifier, event) {
            actions.stepBits |= MomentumActions.ignoresEventBit
            return
        }
        dispatcher.handleWheelEvent(pageIdentifier, event, now, accelerationCurves, &actions)
    }

    fileprivate func displayDidRefresh(_ displayID: UInt32, _ now: Double, _ actions: inout MomentumActions) {
        if dispatcher.displayDidRefresh(displayID, now, &actions) {
            dispatcher.didEndMomentumPhase(momentumEndTypeNatural, &actions)
        }
    }

    fileprivate func pageScreenDidChange(
        _ pageIdentifier: UInt64,
        _ displayID: UInt32,
        _ nominalFramesPerSecond: UInt32,
        _ actions: inout MomentumActions
    ) {
        dispatcher.pageScreenDidChange(pageIdentifier, displayID, nominalFramesPerSecond, &actions)
    }

    fileprivate func stopDisplayLink(_ actions: inout MomentumActions) {
        dispatcher.stopDisplayLink(&actions)
    }
}

/// The client-thread state of a MomentumEventDispatcherState.
private struct MomentumDispatcher: ~Copyable {
    private var deltaHistoryX = DeltaHistory()
    private var deltaHistoryY = DeltaHistory()

    // Like Markable<MonotonicTime>, NaN is the empty value.
    private var lastScrollTimestamp = Double.nan
    private var isInOverriddenPlatformMomentumGesture = false
    private var currentGesture = Gesture()
    private var displayProperties: [UInt64: DisplayProperties] = [:]

    // Scratch for equalizeTailGaps(), which keeps its capacity across gestures.
    private var horizontalTail = Axis()
    private var verticalTail = Axis()

    private static func scrollingAccelerationCurveForPage(
        _ pageIdentifier: UInt64,
        _ curves: borrowing AccelerationCurves
    ) -> AccelerationCurveParameters? {
        curves.withLock { $0[pageIdentifier] ?? nil }
    }

    // The page's acceleration curve when event should start a synthetic momentum phase, else nil.
    private func curveToStartSyntheticMomentumPhase(
        _ pageIdentifier: UInt64,
        _ event: WheelEvent,
        _ curves: borrowing AccelerationCurves
    ) -> AccelerationCurveParameters? {
        if event.momentumPhase != phaseBegan {
            return nil
        }

        guard let curve = Self.scrollingAccelerationCurveForPage(pageIdentifier, curves) else {
            logNoAccelerationCurve()
            return nil
        }

        if !event.hasRawPlatformDelta {
            logNoRawPlatformDelta()
            return nil
        }

        return curve
    }

    // Whether handleWheelEvent() would only consume event: a momentum Changed event, with no scroll phase, for the
    // running gesture's page or for an overridden platform momentum phase after the gesture. It neither interrupts
    // the gesture, nor adds to the history, nor starts a gesture, nor ends the overridden phase.
    func swallowsMomentumChangedEvent(_ pageIdentifier: UInt64, _ event: WheelEvent) -> Bool {
        if !event.isMomentumEvent || event.momentumPhase != phaseChanged {
            return false
        }
        if event.phase == phaseBegan || event.phase == phaseChanged {
            return false
        }
        if currentGesture.active {
            return pageIdentifier == currentGesture.pageIdentifier
        }
        return isInOverriddenPlatformMomentumGesture
    }

    mutating func handleWheelEvent(
        _ pageIdentifier: UInt64,
        _ event: WheelEvent,
        _ now: Double,
        _ curves: borrowing AccelerationCurves,
        _ actions: inout MomentumActions
    ) {
        if currentGesture.active {
            let pageIdentifierChanged = pageIdentifier != currentGesture.pageIdentifier

            // Any incoming wheel event other than a changed event for the current gesture
            // should interrupt the animation; in the usual case, it will be
            // momentumPhase == PhaseEnded that interrupts.
            var eventShouldInterruptGesture = !event.isMomentumEvent || event.momentumPhase != phaseChanged

            // Ignore momentumPhase == PhaseEnded if it was due to the natural
            // end of the animation (as opposed to interruption by placing fingers
            // on the trackpad), so that our momentum is not cut short if the
            // deceleration runs longer than the system curve.
            if event.momentumPhase == phaseEnded && event.momentumEndType == momentumEndTypeNatural {
                eventShouldInterruptGesture = false
            }

            if pageIdentifierChanged || eventShouldInterruptGesture {
                logInterruptingGesture()
                didEndMomentumPhase(momentumEndTypeInterrupted, &actions)
            }
        }

        if event.phase == phaseBegan || event.phase == phaseChanged {
            didReceiveScrollEvent(event)
        }

        if let curve = curveToStartSyntheticMomentumPhase(pageIdentifier, event, curves) {
            didStartMomentumPhase(pageIdentifier, event, now, curve, &actions)
            isInOverriddenPlatformMomentumGesture = true
        }

        // Consume any incoming momentum events while we're generating a synthetic
        // momentum gesture *or* a platform momentum phase that was overridden
        // is still running after we finished the synthetic gesture.
        let shouldIgnoreIncomingPlatformEvent =
            event.isMomentumEvent && (isInOverriddenPlatformMomentumGesture || currentGesture.active)

        if event.momentumPhase == phaseEnded {
            isInOverriddenPlatformMomentumGesture = false
        }

        if shouldIgnoreIncomingPlatformEvent {
            actions.stepBits |= MomentumActions.ignoresEventBit
        }
    }

    private mutating func didStartMomentumPhase(
        _ pageIdentifier: UInt64,
        _ event: WheelEvent,
        _ now: Double,
        _ curve: AccelerationCurveParameters,
        _ actions: inout MomentumActions
    ) {
        guard let displayProperties = displayProperties[pageIdentifier] else {
            return
        }

        actions.stepBits |= MomentumActions.beginsGestureBit

        currentGesture.active = true
        currentGesture.momentumCurve = event.isAutomation ? .simple : .standard
        currentGesture.pageIdentifier = pageIdentifier
        currentGesture.initiatingEventDirectionInvertedFromDevice = event.directionInvertedFromDevice
        currentGesture.currentOffset = Size()
        currentGesture.startTime = now
        currentGesture.displayProperties = displayProperties
        currentGesture.accelerationCurve = curve.curve

        startDisplayLink(&actions)

        // FIXME: The system falls back from the table to just generating deltas
        // directly when the frame interval is within 20fps of idealCurveFrameRate;
        // we should perhaps do the same.
        // swift-format-ignore: NeverForceUnwrap
        let idealCurveMultiplier = currentGesture.accelerationCurve!.frameRate() / idealCurveFrameRate
        buildOffsetTableWithInitialDelta(
            event.rawPlatformDelta * idealCurveMultiplier * event.momentumFastScrollMultiplier
        )

        var consumedDelta = event.delta
        if currentGesture.initiatingEventDirectionInvertedFromDevice {
            consumedDelta = -consumedDelta
        }
        currentGesture.currentOffset = currentGesture.currentOffset + consumedDelta
    }

    mutating func didEndMomentumPhase(_ momentumEndType: UInt8, _ actions: inout MomentumActions) {
        actions.stepBits |= MomentumActions.endsGestureBit
        actions.endTypeValue = momentumEndType

        stopDisplayLink(&actions)

        currentGesture.reset()
    }

    // The gesture's page has display properties: the gesture starts only then, and they are never removed.
    private func startDisplayLink(_ actions: inout MomentumActions) {
        // FIXME: Switch down to lower-than-full-speed frame rates for the tail end of the curve.
        actions.stepBits |= MomentumActions.startsDisplayLinkBit
        actions.startDisplayIDValue = currentGesture.displayProperties.displayID
    }

    func stopDisplayLink(_ actions: inout MomentumActions) {
        if !currentGesture.active {
            return
        }

        // The gesture's page has display properties, which currentGesture holds; see startDisplayLink().
        actions.stepBits |= MomentumActions.stopsDisplayLinkBit
        actions.stopDisplayIDValue = currentGesture.displayProperties.displayID
    }

    mutating func pageScreenDidChange(
        _ pageIdentifier: UInt64,
        _ displayID: UInt32,
        _ nominalFramesPerSecond: UInt32,
        _ actions: inout MomentumActions
    ) {
        let affectsCurrentGesture = pageIdentifier == currentGesture.pageIdentifier
        if affectsCurrentGesture {
            stopDisplayLink(&actions)
        }

        let properties = DisplayProperties(displayID: displayID, nominalFrameRate: nominalFramesPerSecond)
        displayProperties[pageIdentifier] = properties

        if affectsCurrentGesture {
            currentGesture.displayProperties = properties
            startDisplayLink(&actions)
        }
    }

    // Once consumed, this delta *must* be dispatched in an event.
    private mutating func consumeDeltaForCurrentTime(_ now: Double) -> Size? {
        var delta: Size

        let animationTime = now - currentGesture.startTime
        if animationTime < currentGesture.tailStartDelay {
            let desiredOffset = offsetAtTime(animationTime)
            delta = roundedIntSize(desiredOffset - currentGesture.currentOffset)
        } else {
            let index = Int(currentGesture.currentTailDeltaIndex)
            guard index < currentGesture.tailDeltaTable.count else {
                return nil
            }
            delta = -currentGesture.tailDeltaTable[index]
            // Below the table's count, so this cannot wrap.
            currentGesture.currentTailDeltaIndex &+= 1
        }

        currentGesture.currentOffset = currentGesture.currentOffset + delta

        if currentGesture.initiatingEventDirectionInvertedFromDevice {
            delta = -delta
        }

        return delta
    }

    // Returns true when the gesture has run out; the caller ends it in a separate access.
    mutating func displayDidRefresh(_ displayID: UInt32, _ now: Double, _ actions: inout MomentumActions) -> Bool {
        if !currentGesture.active {
            return false
        }

        if displayID != currentGesture.displayProperties.displayID {
            return false
        }

        guard let delta = consumeDeltaForCurrentTime(now) else {
            return true
        }

        actions.stepBits |= MomentumActions.dispatchesChangedEventBit
        actions.changedDelta = delta
        return false
    }

    private static func push(_ deltas: inout DeltaHistory, _ newDelta: Delta) {
        let directionChanged = !deltas.isEmpty && (deltas[0].rawPlatformDelta > 0) != (newDelta.rawPlatformDelta > 0)
        if directionChanged || newDelta.frameInterval > deltaHistoryMaximumAge {
            deltas.removeAll()
        }

        deltas.prepend(newDelta)
    }

    private mutating func didReceiveScrollEventWithInterval(_ size: Size, _ frameInterval: Double) {
        Self.push(&deltaHistoryX, Delta(rawPlatformDelta: size.width, frameInterval: frameInterval))
        Self.push(&deltaHistoryY, Delta(rawPlatformDelta: size.height, frameInterval: frameInterval))
    }

    private mutating func didReceiveScrollEvent(_ event: WheelEvent) {
        if !event.hasRawPlatformDelta {
            return
        }

        let delta = event.rawPlatformDelta
        let time = event.ioHIDEventTimestamp

        if lastScrollTimestamp.isNaN {
            lastScrollTimestamp = time
            // FIXME: Check that this matches the system (they may go with 10ms for the first frame).
            return
        }

        let frameInterval = time - lastScrollTimestamp
        lastScrollTimestamp = time

        didReceiveScrollEventWithInterval(delta, frameInterval)
    }

    private mutating func buildOffsetTableWithInitialDelta(_ initialUnacceleratedDelta: Size) {
        currentGesture.offsetTable.removeAll(keepingCapacity: true)

        var accumulatedOffset = Size()
        var unacceleratedDelta = initialUnacceleratedDelta

        // Tail deltas will be dispatched at the screen refresh rate, not the momentum
        // dispatch rate, so we need to scale from 60Hz into screen refresh rate.
        let tailCurveMultiplier = idealCurveFrameRate / Float(currentGesture.displayProperties.nominalFrameRate)
        var inTail = false
        var tailCarry = Size()

        let useSimpleDeceleration = currentGesture.momentumCurve == .simple
        // Taken for the loop and put back after it, so the delta histories are read in place while it is updated.
        // swift-format-ignore: NeverForceUnwrap
        var curve = currentGesture.accelerationCurve.take()!

        repeat {
            let acceleratedDelta: Size
            (unacceleratedDelta, acceleratedDelta) =
                useSimpleDeceleration
                ? Self.computeNextDeltaSimple(unacceleratedDelta) : computeNextDelta(unacceleratedDelta, &curve)

            let tailStartUnacceleratedDelta: Float = 6
            if !inTail && abs(unacceleratedDelta.width) < tailStartUnacceleratedDelta
                && abs(unacceleratedDelta.height) < tailStartUnacceleratedDelta
            {
                inTail = true
                currentGesture.tailStartDelay = idealCurveFrameInterval * Double(currentGesture.offsetTable.count)
            }

            if inTail {
                let tailDelta = acceleratedDelta * tailCurveMultiplier
                let deltaWithCarry = tailDelta + tailCarry
                let quantizedDelta = roundedIntSize(deltaWithCarry)
                tailCarry = deltaWithCarry - quantizedDelta
                currentGesture.tailDeltaTable.append(quantizedDelta)
            }

            accumulatedOffset = accumulatedOffset + acceleratedDelta
            currentGesture.offsetTable.append(accumulatedOffset)
        } while abs(unacceleratedDelta.width) > 0.5 || abs(unacceleratedDelta.height) > 0.5

        currentGesture.accelerationCurve = consume curve

        equalizeTailGaps()
    }

    private mutating func equalizeTailGaps() {
        // Sort the deltas up until the first zero to ensure a lack of unexpected
        // perceptual acceleration, and then inject skipped frames in order to
        // ensure that frames that have effective scroll movement (non-zero deltas)
        // are always spaced equally-or-further apart than earlier ones, but
        // never closer together.

        let initialTableSize = currentGesture.tailDeltaTable.count
        if initialTableSize == 0 {
            return
        }

        horizontalTail.reset()
        verticalTail.reset()
        horizontalTail.deltas.append(contentsOf: currentGesture.tailDeltaTable.lazy.map(\.width))
        verticalTail.deltas.append(contentsOf: currentGesture.tailDeltaTable.lazy.map(\.height))
        horizontalTail.findFirstZero()
        verticalTail.findFirstZero()

        horizontalTail.sortDeltas()
        verticalTail.sortDeltas()

        var finalTableSize = 0
        currentGesture.tailDeltaTable.removeAll(keepingCapacity: true)

        while horizontalTail.originalTableIndex < initialTableSize || verticalTail.originalTableIndex < initialTableSize {
            let delta = Size(width: horizontalTail.takeNextDelta(), height: verticalTail.takeNextDelta())
            currentGesture.tailDeltaTable.append(delta)

            if !delta.isZero {
                finalTableSize = currentGesture.tailDeltaTable.count
            }
        }

        currentGesture.tailDeltaTable.removeSubrange(finalTableSize...)

        removeAllKeepingCapacityUpToRetained(&horizontalTail.deltas)
        removeAllKeepingCapacityUpToRetained(&verticalTail.deltas)
    }

    private func offsetAtTime(_ time: Double) -> Size {
        let count = currentGesture.offsetTable.count
        if count == 0 {
            return Size()
        }

        let fractionalFrameNumber = Float(time / idealCurveFrameInterval)
        let lastFrameNumber = UInt(count - 1)
        let lowerFrameNumber = min(lastFrameNumber, saturatingUnsignedFloor(fractionalFrameNumber))
        // At most the table's last index, so this cannot wrap.
        let upperFrameNumber = min(lastFrameNumber, lowerFrameNumber &+ 1)
        let amount = fractionalFrameNumber - Float(lowerFrameNumber)

        let lower = currentGesture.offsetTable[Int(lowerFrameNumber)]
        let upper = currentGesture.offsetTable[Int(upperFrameNumber)]
        return Size(
            width: -interpolate(lower.width, upper.width, amount),
            height: -interpolate(lower.height, upper.height, amount)
        )
    }

    private mutating func computeNextDelta(
        _ currentUnacceleratedDelta: Size,
        _ accelerationCurve: inout WebKit.ScrollingAccelerationCurve
    ) -> (Size, Size) {
        var unacceleratedDelta = currentUnacceleratedDelta

        let decayRate = momentumDecayRate(unacceleratedDelta, idealCurveFrameInterval)
        unacceleratedDelta = unacceleratedDelta * decayRate

        // The delta queue operates on pre-acceleration deltas, so insert the new event *before* accelerating.
        didReceiveScrollEventWithInterval(unacceleratedDelta, idealCurveFrameInterval)

        let acceleratedDelta = Size(
            width: deltaHistoryX.accelerate(unacceleratedDelta.width, &accelerationCurve),
            height: deltaHistoryY.accelerate(unacceleratedDelta.height, &accelerationCurve)
        )

        return (unacceleratedDelta, acceleratedDelta)
    }

    private static func computeNextDeltaSimple(_ currentUnacceleratedDelta: Size) -> (Size, Size) {
        let lnDecelerationRate: Float = -0.00200200267 // log(.998)

        let velocityFactor = Float(exp(Double(lnDecelerationRate) * (idealCurveFrameInterval * 1000)))
        let delta = currentUnacceleratedDelta * velocityFactor

        return (delta, delta)
    }
}

// The log messages, out of line so the entries that can log hold no Logger.
@inline(never)
private func logNoAccelerationCurve() {
    scrollAnimationsLog.log("MomentumEventDispatcher not using synthetic momentum phase: no acceleration curve")
}

@inline(never)
private func logNoRawPlatformDelta() {
    scrollAnimationsLog.log(
        "MomentumEventDispatcher not using synthetic momentum phase: no raw platform delta on start event"
    )
}

@inline(never)
private func logInterruptingGesture() {
    scrollAnimationsLog.log("MomentumEventDispatcher interrupting synthetic momentum phase")
}

// One axis of equalizeTailGaps().
private struct Axis {
    var deltas: [Float] = []
    var firstZeroIndex = 0

    // Counts of contiguous frames with zero deltas.
    var minimumGap: UInt32 = 0
    var currentGap: UInt32 = 0
    var remainingGapToGenerate: UInt32 = 0
    var originalTableIndex = 0

    // Like assigning Axis(), but the deltas keep their capacity.
    mutating func reset() {
        deltas.removeAll(keepingCapacity: true)
        firstZeroIndex = 0
        minimumGap = 0
        currentGap = 0
        remainingGapToGenerate = 0
        originalTableIndex = 0
    }

    // The index of the first zero delta after the first; 0 when there is none.
    mutating func findFirstZero() {
        firstZeroIndex = deltas.dropFirst().firstIndex { $0 == 0 } ?? 0
    }

    mutating func sortDeltas() {
        if firstZeroIndex == 0 {
            return
        }

        // A NaN delta goes after every number.
        if deltas[0] > 0 {
            sortDeltasBeforeFirstZero { $0 > $1 || (!$0.isNaN && $1.isNaN) }
        } else {
            sortDeltasBeforeFirstZero { $0 < $1 || (!$0.isNaN && $1.isNaN) }
        }
    }

    // Insertion sort, since the deltas are nearly in order; sort() above insertionSortMaximumCount of them.
    @inline(always)
    private mutating func sortDeltasBeforeFirstZero(_ areInIncreasingOrder: (Float, Float) -> Bool) {
        if firstZeroIndex > insertionSortMaximumCount {
            deltas[0..<firstZeroIndex].sort(by: areInIncreasingOrder)
            return
        }

        for i in 1..<firstZeroIndex {
            let value = deltas[i]
            var j = i
            // j > 0, so this cannot wrap.
            while j > 0 && areInIncreasingOrder(value, deltas[j &- 1]) {
                deltas[j] = deltas[j &- 1]
                j &-= 1
            }
            deltas[j] = value
        }
    }

    // The gap counters are bounded by the table's size, and remainingGapToGenerate is only decremented when nonzero
    // and only set to minimumGap - currentGap after minimumGap is raised to at least currentGap, so none wraps.
    mutating func takeNextDelta() -> Float {
        if originalTableIndex >= deltas.count {
            return 0
        }

        if remainingGapToGenerate != 0 {
            remainingGapToGenerate &-= 1
            currentGap &+= 1
            return 0
        }

        let value = deltas[originalTableIndex]
        if value != 0 {
            minimumGap = max(minimumGap, currentGap)
            remainingGapToGenerate = minimumGap &- currentGap
            if remainingGapToGenerate != 0 {
                remainingGapToGenerate &-= 1
                currentGap &+= 1
                return 0
            }

            currentGap = 0
        } else {
            currentGap &+= 1
        }

        originalTableIndex += 1

        return value
    }
}

// The fields of a WebWheelEvent the dispatcher reads.
private struct WheelEvent {
    var phase: UInt8
    var momentumPhase: UInt8
    var momentumEndType: UInt8
    var isMomentumEvent: Bool
    var hasRawPlatformDelta: Bool
    var rawPlatformDelta: Size
    var ioHIDEventTimestamp: Double
    var isAutomation: Bool
    var momentumFastScrollMultiplier: Float
    var delta: Size
    var directionInvertedFromDevice: Bool
}

/// Called on the client's thread (see MomentumEventDispatcherState), with the event's fields and the scrolling-effects
/// clock's time. Returns what to do with the client; the steps include ignoresEvent when the event is consumed.
@_expose(Cxx)
@used
nonisolated func momentumHandleWheelEvent(
    _ state: MomentumEventDispatcherState,
    _ pageIdentifier: UInt64,
    _ phase: UInt8,
    _ momentumPhase: UInt8,
    _ momentumEndType: UInt8,
    _ isMomentumEvent: Bool,
    _ hasRawPlatformDelta: Bool,
    _ rawPlatformDeltaWidth: Float,
    _ rawPlatformDeltaHeight: Float,
    _ ioHIDEventTimestamp: Double,
    _ isAutomation: Bool,
    _ momentumFastScrollMultiplier: Float,
    _ deltaWidth: Float,
    _ deltaHeight: Float,
    _ directionInvertedFromDevice: Bool,
    _ now: Double
) -> MomentumActions {
    let event = WheelEvent(
        phase: phase,
        momentumPhase: momentumPhase,
        momentumEndType: momentumEndType,
        isMomentumEvent: isMomentumEvent,
        hasRawPlatformDelta: hasRawPlatformDelta,
        rawPlatformDelta: Size(width: rawPlatformDeltaWidth, height: rawPlatformDeltaHeight),
        ioHIDEventTimestamp: ioHIDEventTimestamp,
        isAutomation: isAutomation,
        momentumFastScrollMultiplier: momentumFastScrollMultiplier,
        delta: Size(width: deltaWidth, height: deltaHeight),
        directionInvertedFromDevice: directionInvertedFromDevice
    )
    var actions = MomentumActions()
    state.handleWheelEvent(pageIdentifier, event, now, &actions)
    return actions
}

/// Called on the client's thread (see MomentumEventDispatcherState), with the scrolling-effects clock's time.
@_expose(Cxx)
@used
nonisolated func momentumDisplayDidRefresh(
    _ state: MomentumEventDispatcherState,
    _ displayID: UInt32,
    _ now: Double
) -> MomentumActions {
    var actions = MomentumActions()
    state.displayDidRefresh(displayID, now, &actions)
    return actions
}

/// Called on the client's thread (see MomentumEventDispatcherState).
@_expose(Cxx)
@used
nonisolated func momentumPageScreenDidChange(
    _ state: MomentumEventDispatcherState,
    _ pageIdentifier: UInt64,
    _ displayID: UInt32,
    _ nominalFramesPerSecond: UInt32
) -> MomentumActions {
    var actions = MomentumActions()
    state.pageScreenDidChange(pageIdentifier, displayID, nominalFramesPerSecond, &actions)
    return actions
}

/// Called from the MomentumEventDispatcher's destructor, on the thread that destroys it.
@_expose(Cxx)
@used
nonisolated func momentumStopDisplayLink(_ state: MomentumEventDispatcherState) -> MomentumActions {
    var actions = MomentumActions()
    state.stopDisplayLink(&actions)
    return actions
}

/// Called on any thread: the curves are behind their own lock. Takes the ScrollingAccelerationCurve's parameters.
@_expose(Cxx)
@used
nonisolated func momentumSetScrollingAccelerationCurve(
    _ state: MomentumEventDispatcherState,
    _ pageIdentifier: UInt64,
    _ gainLinear: Float,
    _ gainParabolic: Float,
    _ gainCubic: Float,
    _ gainQuartic: Float,
    _ tangentSpeedLinear: Float,
    _ tangentSpeedParabolicRoot: Float,
    _ resolution: Float,
    _ frameRate: Float
) {
    state.setScrollingAccelerationCurve(
        pageIdentifier,
        AccelerationCurveParameters(
            gainLinear: gainLinear,
            gainParabolic: gainParabolic,
            gainCubic: gainCubic,
            gainQuartic: gainQuartic,
            tangentSpeedLinear: tangentSpeedLinear,
            tangentSpeedParabolicRoot: tangentSpeedParabolicRoot,
            resolution: resolution,
            frameRate: frameRate
        )
    )
}

/// Called on any thread: the curves are behind their own lock.
@_expose(Cxx)
@used
nonisolated func momentumClearScrollingAccelerationCurve(_ state: MomentumEventDispatcherState, _ pageIdentifier: UInt64) {
    state.setScrollingAccelerationCurve(pageIdentifier, nil)
}

#endif
