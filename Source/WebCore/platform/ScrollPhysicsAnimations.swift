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

// The animations ScrollingEffectsController runs: smooth (programmatic) scrolls, keyboard scrolls,
// momentum after a gesture, and the rubber band's snap-back. The controller owns one of each for its
// life, resets one when it starts an animation of that kind, and passes itself and its client into each
// call; an animation keeps no reference to either.
//
// An animation's client call can replace the controller's current animation, possibly with a new
// animation of the same kind in the same object. The controller's animation generation then differs
// from the one it passed to serviceAnimation(), and the animation returns without touching its state.

#if USE_SWIFT_SCROLL_PHYSICS

internal import AppKit
internal import pal.spi.mac.NSScrollViewSPI
internal import pal.spi.mac.NSScrollingMomentumCalculatorSPI
internal import WebCore_Private.Core.KeyboardScroll
internal import WebCore_Private.Core.ScrollExtents
internal import WebCore_Private.Core.TimingFunction
internal import WebCore_Private.ScrollPhysicsTypes

enum ScrollPhysicsAnimationType {
    case smooth
    case momentum
    case rubberBand
    case keyboard
}

protocol ScrollPhysicsAnimationBase: AnyObject {
    static var animationType: ScrollPhysicsAnimationType { get }
    var isActive: Bool { get set }
    var startTime: Double { get set }
}

extension ScrollPhysicsAnimationBase {
    func didStart<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ controller: ScrollPhysicsController, _ currentTime: Double) {
        startTime = currentTime
        isActive = true
        controller.scrollAnimationWillStart(&c, Self.animationType)
    }

    func didEnd<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ controller: ScrollPhysicsController) {
        isActive = false
        controller.scrollAnimationDidEnd(&c, Self.animationType)
    }

    func stopIfActive<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ controller: ScrollPhysicsController) {
        if !isActive {
            return
        }
        didEnd(&c, controller)
    }
}

// MARK: Smooth

private let animationSpeed: Float = 1000
private let maxAnimationDuration = 0.2

// The end of the spring is imperceptible, so finish once the remaining distance is a fraction of a pixel.
private let springAnimationCompletionDistance: Float = 0.25

// DocumentEdgeScrollSpring (KeyboardScroll.h).
private let documentEdgeScrollSpringMass = WebCore.DocumentEdgeScrollSpring.mass
private let documentEdgeScrollSpringStiffness = WebCore.DocumentEdgeScrollSpring.stiffness
private let documentEdgeScrollSpringDuration = WebCore.DocumentEdgeScrollSpring.duration.value()
// DocumentEdgeScrollSpring::timingFunctionControlPoints, a std::array, which Swift cannot index.
private let documentEdgeScrollSpringTimingFunctionControlPoints: (Double, Double, Double, Double) = (0, 0.2, 1, 1)

extension Double {
    // self + b * c, rounded as clang compiles the same C++ expression: fused on arm64, where -ffp-contract=on contracts
    // it, and with the product rounded where the target has no fused multiply-add.
    @inline(always)
    fileprivate func addingProductAsCompiled(_ b: Double, _ c: Double) -> Double {
#if arch(arm64)
        addingProduct(b, c)
#else
        self + b * c
#endif
    }
}

// UnitBezier (UnitBezier.h), with its arithmetic rounded as the C++ is compiled.
private struct UnitBezier {
    static let bezierEpsilon = 1e-7
    static let bisectionEpsilon = 1e-10
    static let maxNewtonIterations = 4
    static let splineSampleCount = 11

    private let ax: Double
    private let bx: Double
    private let cx: Double

    private let ay: Double
    private let by: Double
    private let cy: Double

    private let startGradient: Double
    private let endGradient: Double

    private var splineSamples = InlineArray<11, Double>(repeating: 0)

    init(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double) {
        // Calculate the polynomial coefficients, implicit first and last control points are (0,0) and (1,1).
        cx = 3.0 * p1x
        bx = (-cx).addingProductAsCompiled(3.0, p2x - p1x)
        ax = 1.0 - cx - bx

        cy = 3.0 * p1y
        by = (-cy).addingProductAsCompiled(3.0, p2y - p1y)
        ay = 1.0 - cy - by

        // End-point gradients are used to calculate timing function results outside the range [0, 1].
        if p1x > 0 {
            startGradient = p1y / p1x
        } else if p1y == 0 && p2x > 0 {
            startGradient = p2y / p2x
        } else if p1y == 0 && p2y == 0 {
            startGradient = 1
        } else {
            startGradient = 0
        }
        if p2x < 1 {
            endGradient = (p2y - 1) / (p2x - 1)
        } else if p2y == 1 && p1x < 1 {
            endGradient = (p1y - 1) / (p1x - 1)
        } else if p2y == 1 && p1y == 1 {
            endGradient = 1
        } else {
            endGradient = 0
        }

        let deltaT = 1.0 / Double(Self.splineSampleCount - 1)
        for i in 0..<Self.splineSampleCount {
            splineSamples[i] = sampleCurveX(Double(i) * deltaT)
        }
    }

    func sampleCurveX(_ t: Double) -> Double {
        // `ax t^3 + bx t^2 + cx t' expanded using Horner's rule.
        cx.addingProductAsCompiled(bx.addingProductAsCompiled(ax, t), t) * t
    }

    func sampleCurveY(_ t: Double) -> Double {
        cy.addingProductAsCompiled(by.addingProductAsCompiled(ay, t), t) * t
    }

    func sampleCurveDerivativeX(_ t: Double) -> Double {
        cx.addingProductAsCompiled((2.0 * bx).addingProductAsCompiled(3.0 * ax, t), t)
    }

    // Given an x value, find a parametric value it came from.
    func solveCurveX(_ x: Double, _ epsilon: Double) -> Double {
        var t0 = 0.0
        var t1 = 0.0
        var t2 = x
        var x2 = 0.0
        var d2 = 0.0

        // Linear interpolation of spline curve for initial guess.
        let deltaT = 1.0 / Double(Self.splineSampleCount - 1)
        for i in 1..<Self.splineSampleCount where x <= splineSamples[i] {
            t1 = deltaT * Double(i)
            t0 = t1 - deltaT
            t2 = t0 + (t1 - t0) * (x - splineSamples[i - 1]) / (splineSamples[i] - splineSamples[i - 1])
            break
        }

        // Perform a few iterations of Newton's method -- normally very fast.
        let newtonEpsilon = stdMin(Self.bezierEpsilon, epsilon)
        for _ in 0..<Self.maxNewtonIterations {
            x2 = sampleCurveX(t2) - x
            if abs(x2) < newtonEpsilon {
                return t2
            }
            d2 = sampleCurveDerivativeX(t2)
            if abs(d2) < Self.bezierEpsilon {
                break
            }
            t2 = t2 - x2 / d2
        }
        if abs(x2) < epsilon {
            return t2
        }

        // Fall back to the bisection method for reliability.
        let bisectionEpsilon = stdMax(Self.bisectionEpsilon, epsilon)
        while t0 < t1 {
            x2 = sampleCurveX(t2)
            if abs(x2 - x) < bisectionEpsilon {
                return t2
            }
            if x > x2 {
                t0 = t2
            } else {
                t1 = t2
            }
            t2 = libcxxMidpoint(t0, t1)
        }

        // Failure.
        return t2
    }

    func solve(_ x: Double, _ epsilon: Double) -> Double {
        if x < 0.0 {
            return (0.0).addingProductAsCompiled(startGradient, x)
        }
        if x > 1.0 {
            return (1.0).addingProductAsCompiled(endGradient, x - 1.0)
        }
        return sampleCurveY(solveCurveX(x, epsilon))
    }
}

// std::midpoint() for double, as libc++ implements it.
private func libcxxMidpoint(_ a: Double, _ b: Double) -> Double {
    let lo = Double.leastNormalMagnitude * 2
    let hi = Double.greatestFiniteMagnitude / 2
    if abs(a) <= hi && abs(b) <= hi {
        return (a + b) / 2
    }
    if abs(a) < lo {
        return a + b / 2
    }
    if abs(b) < lo {
        return a / 2 + b
    }
    return a / 2 + b / 2
}

// SpringSolver (SpringSolver.h), with its arithmetic rounded as the C++ is compiled.
private struct SpringSolver {
    private let w0: Double
    private let zeta: Double
    private let wd: Double
    private let a: Double
    private let b: Double

    init(_ mass: Double, _ stiffness: Double, _ damping: Double, _ initialVelocity: Double) {
        w0 = (stiffness / mass).squareRoot()
        zeta = damping / (2 * (stiffness * mass).squareRoot())

        if zeta < 1 {
            // Under-damped.
            wd = w0 * (1.0).addingProductAsCompiled(-zeta, zeta).squareRoot()
            a = 1
            b = (-initialVelocity).addingProductAsCompiled(zeta, w0) / wd
        } else {
            // Critically damped (ignoring over-damped case for now). The damped frequency is not used.
            wd = 0
            a = 1
            b = -initialVelocity + w0
        }
    }

    func solve(_ time: Double) -> Double {
        let t: Double
        if zeta < 1 {
            // Under-damped
            t = exp(-time * zeta * w0) * (b * sin(wd * time)).addingProductAsCompiled(a, cos(wd * time))
        } else {
            // Critically damped (ignoring over-damped case for now).
            t = a.addingProductAsCompiled(b, time) * exp(-time * w0)
        }

        // Map range from [1..0] to [0..1].
        return 1 - t
    }
}

// Progress of the spring curve, from 0 to 1, at the given time in seconds since the start of the animation.
// ScrollAnimationSmooth::springProgress() calls it.
@_expose(Cxx)
func documentEdgeScrollSpringProgress(_ elapsedTime: Double) -> Double {
    // Computed the same way SpringSolver computes the damping ratio, so that the ratio is exactly 1.
    let damping = 2 * (documentEdgeScrollSpringStiffness * documentEdgeScrollSpringMass).squareRoot()

    // Like a CAMediaTimingFunction, the bezier warps time before the spring is evaluated. It removes the
    // initial ease-in of the spring, so that the curve resembles exponential decay.
    let controlPoints = documentEdgeScrollSpringTimingFunctionControlPoints
    let ratio = elapsedTime / documentEdgeScrollSpringDuration
    // std::clamp().
    let fractionComplete = ratio < 0.0 ? 0.0 : 1.0 < ratio ? 1.0 : ratio
    let bezier = UnitBezier(controlPoints.0, controlPoints.1, controlPoints.2, controlPoints.3)
    let warpedTime = bezier.solve(fractionComplete, UnitBezier.bezierEpsilon) * documentEdgeScrollSpringDuration

    return SpringSolver(documentEdgeScrollSpringMass, documentEdgeScrollSpringStiffness, damping, 0).solve(warpedTime)
}

final class SmoothScrollAnimation: ScrollPhysicsAnimationBase {
    static var animationType: ScrollPhysicsAnimationType { .smooth }

    var isActive = false
    var startTime: Double = 0
    private(set) var currentOffset = ScrollPoint.zero

    private var duration: Double = 0
    private var startOffset = ScrollPoint.zero
    private(set) var destinationOffset = ScrollPoint.zero
    private(set) var curve = WebCore.ScrollAnimationCurve.Default
    private var timingFunction: WebCore.CubicBezierTimingFunction

    init() {
        timingFunction = WebCore.CubicBezierTimingFunction.create().get()
    }

    // Puts the animation back in its initial state.
    func reset() {
        isActive = false
        startTime = 0
        currentOffset = .zero
        duration = 0
        startOffset = .zero
        destinationOffset = .zero
        curve = .Default
        timingFunction = WebCore.CubicBezierTimingFunction.create().get()
    }

    func startAnimatedScrollToDestination<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ fromOffset: ScrollPoint,
        _ destination: ScrollPoint,
        _ curve: WebCore.ScrollAnimationCurve
    ) -> Bool {
        let extents = ScrollPhysicsExtents(c.scrollExtents())

        self.curve = curve
        currentOffset = fromOffset
        startOffset = fromOffset
        destinationOffset = destination.constrainedBetween(extents.minimumScrollOffset, extents.maximumScrollOffset)

        if !isActive && fromOffset == destinationOffset {
            return false
        }

        duration = durationFromDistance(destinationOffset - startOffset)
        if duration == 0 {
            return false
        }

        timingFunction.setTimingFunctionPreset(.EaseInOut)

        if !isActive {
            didStart(&c, controller, scrollPhysicsClockNow())
        }

        return true
    }

    // Moves the start time and offset and replaces the timing function even when it returns false.
    func retargetActiveAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ newOffset: ScrollPoint,
        _ curve: WebCore.ScrollAnimationCurve
    ) -> Bool {
        if !isActive {
            return false
        }

        let extents = ScrollPhysicsExtents(c.scrollExtents())

        self.curve = curve
        startTime = scrollPhysicsClockNow()
        startOffset = currentOffset
        destinationOffset = newOffset.constrainedBetween(extents.minimumScrollOffset, extents.maximumScrollOffset)
        duration = durationFromDistance(destinationOffset - startOffset)
        timingFunction.setTimingFunctionPreset(.EaseOut)
        timingFunction = WebCore.CubicBezierTimingFunction.create(.EaseOut).get()

        if currentOffset == destinationOffset || duration == 0 {
            return false
        }

        return true
    }

    func updateScrollExtents<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ controller: ScrollPhysicsController) {
        let extents = ScrollPhysicsExtents(c.scrollExtents())
        // FIXME: Ideally fix up startOffset so currentOffset doesn't go backwards.
        destinationOffset = destinationOffset.constrainedBetween(extents.minimumScrollOffset, extents.maximumScrollOffset)
    }

    private func durationFromDistance(_ delta: ScrollSize) -> Double {
        let distance = hypotf(delta.width, delta.height)
        if curve == .Spring {
            return distance != 0 ? documentEdgeScrollSpringDuration : 0
        }
        return stdMin(Double(distance / animationSpeed), maxAnimationDuration)
    }

    func serviceAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ currentTime: Double,
        _ generation: UInt64
    ) {
        let animationActive = animateScroll(currentTime)
        controller.scrollAnimationDidUpdate(&c, .Clamped, currentOffset)
        if !controller.isCurrentAnimation(generation) {
            return
        }
        if !animationActive {
            didEnd(&c, controller)
        }
    }

    private func animateScroll(_ time: Double) -> Bool {
        let endTime = startTime + duration
        let currentTime = stdMin(time, endTime)

        let progress: Float
        if curve == .Spring {
            progress = Float(documentEdgeScrollSpringProgress(currentTime - startTime))
        } else {
            let fractionComplete = (currentTime - startTime) / duration
            progress = Float(timingFunction.transformProgress(fractionComplete, duration, .No))
        }

        currentOffset = ScrollPoint(
            x: libcxxLerp(startOffset.x, destinationOffset.x, progress),
            y: libcxxLerp(startOffset.y, destinationOffset.y, progress)
        )

        if curve == .Spring {
            let remaining = destinationOffset - currentOffset
            if currentTime == endTime || hypotf(remaining.width, remaining.height) < springAnimationCompletionDistance {
                currentOffset = destinationOffset
                return false
            }
        }

        return currentTime < endTime
    }
}

// MARK: Keyboard

private func perpendicularAbsoluteUnitVector(_ direction: WebCore.ScrollDirection) -> ScrollSize {
    switch direction {
    case .up, .down:
        return ScrollSize(width: 1, height: 0)
    case .left, .right:
        return ScrollSize(width: 0, height: 1)
    @unknown default:
        return .zero
    }
}

private func farthestPointInDirection(_ a: ScrollPoint, _ b: ScrollPoint, _ direction: WebCore.ScrollDirection) -> ScrollPoint {
    switch direction {
    case .up:
        return ScrollPoint(x: a.x, y: stdMin(a.y, b.y))
    case .down:
        return ScrollPoint(x: a.x, y: stdMax(a.y, b.y))
    case .left:
        return ScrollPoint(x: stdMin(a.x, b.x), y: a.y)
    case .right:
        return ScrollPoint(x: stdMax(a.x, b.x), y: a.y)
    @unknown default:
        return .zero
    }
}

final class KeyboardScrollAnimation: ScrollPhysicsAnimationBase {
    static var animationType: ScrollPhysicsAnimationType { .keyboard }

    var isActive = false
    var startTime: Double = 0
    private(set) var currentOffset = ScrollPoint.zero

    private var currentKeyboardScroll: WebCore.KeyboardScroll?
    private var velocity = ScrollSize.zero
    private var timeAtLastFrame: Double = 0
    private var idealPosition = ScrollPoint.zero
    private var idealPositionForMinimumTravel = ScrollSize.zero
    private var scrollTriggeringKeyIsPressed = false

    init() {}

    // Puts the animation back in its initial state.
    func reset() {
        isActive = false
        startTime = 0
        currentOffset = .zero
        currentKeyboardScroll = nil
        velocity = .zero
        timeAtLastFrame = 0
        idealPosition = .zero
        idealPositionForMinimumTravel = .zero
        scrollTriggeringKeyIsPressed = false
    }

    // RectEdges<bool> scrollableDirectionsFromPosition(), at one side.
    private func canScroll(from position: ScrollPoint, toward side: WebCore.BoxSide, _ extents: ScrollPhysicsExtents) -> Bool {
        let minimumScrollPosition = extents.minimumScrollOffset
        let maximumScrollPosition = extents.maximumScrollOffset
        switch side {
        case .Top: return position.y > minimumScrollPosition.y
        case .Bottom: return position.y < maximumScrollPosition.y
        case .Left: return position.x > minimumScrollPosition.x
        case .Right: return position.x < maximumScrollPosition.x
        @unknown default: return false
        }
    }

    func serviceAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ currentTime: Double,
        _ generation: UInt64
    ) {
        animateScroll(&c, controller, currentTime, generation)
    }

    func startKeyboardScroll<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ scrollData: WebCore.KeyboardScroll
    ) -> Bool {
        timeAtLastFrame = scrollPhysicsClockNow()
        currentKeyboardScroll = scrollData
        scrollTriggeringKeyIsPressed = true
        currentOffset = ScrollPoint(c.scrollOffset())
        let offset = ScrollSize(scrollData.offset)
        idealPositionForMinimumTravel = ScrollSize(width: (currentOffset + offset).x, height: (currentOffset + offset).y)

        if !isActive {
            didStart(&c, controller, scrollPhysicsClockNow())
        }

        return true
    }

    private func stopKeyboardScrollAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C) {
        guard let currentKeyboardScroll else {
            return
        }

        let params = WebCore.KeyboardScrollParameters.parameters()

        // Determine the settling position of the spring, conserving the system's current energy.
        // Kinetic = elastic potential
        // 1/2 * m * v^2 = 1/2 * k * x^2
        // x = sqrt(v^2 * m / k)
        let displacementMagnitudeSquared = (velocity * velocity).scaled(params.springMass / params.springStiffness)
        let displacement = ScrollPoint(
            x: Float(signOf: velocity.width, magnitudeOf: displacementMagnitudeSquared.width.squareRoot()),
            y: Float(signOf: velocity.height, magnitudeOf: displacementMagnitudeSquared.height.squareRoot())
        )

        // If the spring would settle before the minimum travel distance
        // for an instantaneous tap, move the settling position of the spring
        // out to that point.
        let farthestPoint = farthestPointInDirection(
            currentOffset + displacement,
            ScrollPoint(x: idealPositionForMinimumTravel.width, y: idealPositionForMinimumTravel.height),
            currentKeyboardScroll.direction
        )

        let extents = ScrollPhysicsExtents(c.scrollExtents())

        idealPosition = farthestPoint.constrainedBetween(extents.minimumScrollOffset, extents.maximumScrollOffset)

        self.currentKeyboardScroll = nil
    }

    func finishKeyboardScroll<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ immediate: Bool
    ) {
        if !scrollTriggeringKeyIsPressed && !immediate {
            return
        }

        if !immediate {
            stopKeyboardScrollAnimation(&c)
        }

        scrollTriggeringKeyIsPressed = false

        if immediate {
            velocity = .zero
            didEnd(&c, controller)
        }
    }

    private func animateScroll<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ currentTime: Double,
        _ generation: UInt64
    ) {
        var force = ScrollSize.zero
        var axesToApplySpring = ScrollSize(width: 1, height: 1)
        let parameters = WebCore.KeyboardScrollParameters.parameters()

        if let currentKeyboardScroll {
            let extents = ScrollPhysicsExtents(c.scrollExtents())
            let direction = currentKeyboardScroll.direction

            if canScroll(from: currentOffset, toward: WebCore.boxSideForDirection(direction), extents) {
                // Apply the scrolling force. Only apply the spring in the perpendicular axis,
                // otherwise it drags against the direction of motion.
                axesToApplySpring = perpendicularAbsoluteUnitVector(direction)
                force = ScrollSize(currentKeyboardScroll.force)
            } else {
                // The scroll view cannot scroll in this direction, and is rubber-banding.
                // Apply a constant and significant force; otherwise, the force for a
                // single-line increment is not strong enough to rubber-band perceptibly.
                force = ScrollSize(WebCore.unitVectorForScrollDirection(direction)).scaled(parameters.rubberBandForce)
            }

            if abs(velocity.width) >= abs(currentKeyboardScroll.maximumVelocity.width()) {
                force.width = 0
            }

            if abs(velocity.height) >= abs(currentKeyboardScroll.maximumVelocity.height()) {
                force.height = 0
            }
        }

        let extents = ScrollPhysicsExtents(c.scrollExtents())

        // FloatPoint(IntPoint(position).constrainedBetween(IntPoint(minimum), IntPoint(maximum))).
        let position = currentKeyboardScroll != nil ? currentOffset : idealPosition
        let integralPosition = integralPointConstrainedToScrollExtents(SIMD2(position.x, position.y), extents)
        let idealPosition = ScrollPoint(x: integralPosition.x, y: integralPosition.y)
        let displacement = currentOffset - idealPosition

        let springForce = -displacement.scaled(parameters.springStiffness) - velocity.scaled(parameters.springDamping)
        force += springForce * axesToApplySpring

        let frameDuration = Float(currentTime - timeAtLastFrame)
        timeAtLastFrame = currentTime

        let acceleration = force.scaled(Float(1.0 / Double(parameters.springMass)))
        velocity += acceleration.scaled(frameDuration)
        currentOffset = currentOffset + velocity.scaled(frameDuration)

        controller.scrollAnimationDidUpdate(&c, .Unclamped, currentOffset)
        if !controller.isCurrentAnimation(generation) {
            return
        }

        // Stop the spring if it reaches the ideal position.
        let newDisplacement = currentOffset - idealPosition

        if axesToApplySpring.width != 0 && displacement.width * newDisplacement.width < 0 {
            velocity.width = 0
        }
        if axesToApplySpring.height != 0 && displacement.height * newDisplacement.height < 0 {
            velocity.height = 0
        }

        // FloatSize::diagonalLengthSquared(), fused, as -ffp-contract=on fuses the C++ expression.
        let velocityLengthSquared = (velocity.height * velocity.height).addingProduct(velocity.width, velocity.width)
        if !scrollTriggeringKeyIsPressed && velocityLengthSquared < 1 {
            velocity = .zero
            didEnd(&c, controller)
        }
    }
}

// MARK: Momentum

final class MomentumScrollAnimation: ScrollPhysicsAnimationBase {
    static var animationType: ScrollPhysicsAnimationType { .momentum }

    var isActive = false
    var startTime: Double = 0
    private(set) var currentOffset = ScrollPoint.zero

    private var momentumCalculator: MomentumScrollCalculator?

    init() {}

    // Puts the animation back in its initial state.
    func reset() {
        isActive = false
        startTime = 0
        currentOffset = .zero
        momentumCalculator = nil
    }

    func startAnimatedScrollWithInitialVelocity<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ initialOffset: ScrollPoint,
        _ initialVelocity: ScrollSize,
        _ initialDelta: ScrollSize,
        _ scrollSnapState: ScrollSnapAnimationState,
        _ snapInput: ScrollSnapModifierInput
    ) -> Bool {
        let extents = ScrollPhysicsExtents(c.scrollExtents())
        currentOffset = initialOffset

        var calculator = MomentumScrollCalculator(extents, initialOffset, initialDelta, initialVelocity)
        var destinationScrollOffset = calculator.destinationScrollOffset

        // Scroll snapping picks the destination and records the snap indices. It reads only the snap offsets,
        // and calls no client member.
        let modifiedOffset = scrollSnapState.modifiedDestination(&c, snapInput, destinationScrollOffset)
        if modifiedOffset != destinationScrollOffset {
            destinationScrollOffset = modifiedOffset
            calculator.setRetargetedScrollOffset(destinationScrollOffset)
        }

        if destinationScrollOffset == initialOffset {
            momentumCalculator = nil
            return false
        }

        momentumCalculator = calculator
        didStart(&c, controller, scrollPhysicsClockNow())
        return true
    }

    // Ends the animation when the retargeted animation still has time to run, and returns false then.
    func retargetActiveAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ newDestination: ScrollPoint
    ) -> Bool {
        if momentumCalculator != nil, isActive {
            momentumCalculator!.setRetargetedScrollOffset(newDestination)
            let newDuration = momentumCalculator!.animationDuration()
            let animationComplete = newDuration > 0
            if animationComplete {
                didEnd(&c, controller)
            }

            return !animationComplete
        }

        return false
    }

    func stop<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ controller: ScrollPhysicsController) {
        momentumCalculator = nil
        stopIfActive(&c, controller)
    }

    // Out of line, so the registers the calculator needs are saved only on momentum frames.
    @inline(never)
    func serviceAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ currentTime: Double,
        _ generation: UInt64
    ) {
        if momentumCalculator == nil {
            return
        }

        // The calculator calls only AppKit, so no access to it is open across the client call below.
        let elapsedTime = currentTime - startTime
        let animationComplete = elapsedTime >= momentumCalculator!.animationDuration()
        currentOffset = momentumCalculator!.scrollOffsetAfterElapsedTime(elapsedTime)

        controller.scrollAnimationDidUpdate(&c, .Unclamped, currentOffset)
        if !controller.isCurrentAnimation(generation) {
            return
        }

        if animationComplete {
            didEnd(&c, controller)
        }
    }

    // Traps when the animation has stopped and has no calculator.
    func updateScrollExtents<C: ScrollPhysicsClientProtocol & ~Copyable>(_ c: inout C, _ controller: ScrollPhysicsController) {
        let extents = ScrollPhysicsExtents(c.scrollExtents())
        let predictedScrollOffset = momentumCalculator!.destinationScrollOffset
        let constrainedOffset = predictedScrollOffset.constrainedBetween(extents.minimumScrollOffset, extents.maximumScrollOffset)
        if constrainedOffset != predictedScrollOffset {
            _ = retargetActiveAnimation(&c, controller, constrainedOffset)
        }
    }
}

// ScrollingMomentumCalculatorMac: AppKit's _NSScrollingMomentumCalculator, or, with platform
// prediction turned off for testing, a fixed multiple of the initial wheel delta.
struct MomentumScrollCalculator {
    private let initialDelta: ScrollSize
    private let initialVelocity: ScrollSize
    private let initialScrollOffset: ScrollPoint
    private var initialDestinationOffset = ScrollPoint.zero
    private let scrollExtents: ScrollPhysicsExtents

    private var retargetedScrollOffset: ScrollPoint?
    private var platformMomentumCalculator: _NSScrollingMomentumCalculator?
    private var requiresMomentumScrollingValue: Bool?

    init(_ scrollExtents: ScrollPhysicsExtents, _ initialOffset: ScrollPoint, _ initialDelta: ScrollSize, _ initialVelocity: ScrollSize) {
        self.initialDelta = initialDelta
        self.initialVelocity = initialVelocity
        self.initialScrollOffset = initialOffset
        self.scrollExtents = scrollExtents
        initialDestinationOffset = predictedDestinationOffset()
        // We could compute requiresMomentumScrollingValue here, based on whether initialDelta is non-zero or we are in a rubber-banded state.
    }

    var destinationScrollOffset: ScrollPoint {
        retargetedScrollOffset ?? initialDestinationOffset
    }

    mutating func setRetargetedScrollOffset(_ target: ScrollPoint) {
        let currentDestination = destinationScrollOffset
        retargetedScrollOffset = target

        if currentDestination != destinationScrollOffset {
            setMomentumCalculatorDestinationOffset(destinationScrollOffset)
        }
    }

    mutating func scrollOffsetAfterElapsedTime(_ elapsedTime: Double) -> ScrollPoint {
        if !requiresMomentumScrolling() {
            return destinationScrollOffset
        }

        return ScrollPoint(ensurePlatformMomentumCalculator()?.position(afterDuration: elapsedTime) ?? .zero)
    }

    mutating func animationDuration() -> Double {
        if !requiresMomentumScrolling() {
            return 0
        }

        return ensurePlatformMomentumCalculator()?.durationUntilStop ?? 0
    }

    private mutating func predictedDestinationOffset() -> ScrollPoint {
        _ = ensurePlatformMomentumCalculator()

        if !WebCore.ScrollPhysicsClient.platformMomentumScrollingPredictionEnabled() {
            let nonPlatformPredictedOffset = deltaProjectedDestinationOffset()
            // We need to make sure the _NSScrollingMomentumCalculator has the same idea of what offset we're shooting for.
            if nonPlatformPredictedOffset != initialDestinationOffset {
                setMomentumCalculatorDestinationOffset(nonPlatformPredictedOffset)
            }

            return nonPlatformPredictedOffset
        }

        return initialDestinationOffset
    }

    // ScrollingMomentumCalculator::predictedDestinationOffset().
    private func deltaProjectedDestinationOffset() -> ScrollPoint {
        let minScrollOffset = scrollExtents.minimumScrollOffset
        let maxScrollOffset = scrollExtents.maximumScrollOffset

        // Without the platform calculator, approximate the destination by multiplying the initial wheel delta by a constant factor.
        func projectedInertialScrollDistance(_ initialWheelDelta: Float) -> Float {
            Float(16.7 * Double(initialWheelDelta))
        }

        let initialOffsetX = clampTo(
            initialScrollOffset.x + projectedInertialScrollDistance(initialDelta.width),
            minScrollOffset.x,
            maxScrollOffset.x
        )
        let initialOffsetY = clampTo(
            initialScrollOffset.y + projectedInertialScrollDistance(initialDelta.height),
            minScrollOffset.y,
            maxScrollOffset.y
        )
        return ScrollPoint(x: initialOffsetX, y: initialOffsetY)
    }

    private mutating func setMomentumCalculatorDestinationOffset(_ scrollOffset: ScrollPoint) {
        let calculator = ensurePlatformMomentumCalculator()
        calculator?.destinationOrigin = NSPoint(x: CGFloat(scrollOffset.x), y: CGFloat(scrollOffset.y))
        calculator?.calculateToReachDestination()
    }

    // Computed the first time it is needed, after any retargeting.
    private mutating func requiresMomentumScrolling() -> Bool {
        if let requiresMomentumScrollingValue {
            return requiresMomentumScrollingValue
        }
        let value = initialScrollOffset != destinationScrollOffset || initialVelocity.width * initialVelocity.height != 0
        requiresMomentumScrollingValue = value
        return value
    }

    // Making the platform calculator also replaces initialDestinationOffset with its destination.
    private mutating func ensurePlatformMomentumCalculator() -> _NSScrollingMomentumCalculator? {
        if let platformMomentumCalculator {
            return platformMomentumCalculator
        }

        let origin = NSPoint(x: CGFloat(initialScrollOffset.x), y: CGFloat(initialScrollOffset.y))
        let contentFrame = NSRect(
            x: 0,
            y: 0,
            width: CGFloat(scrollExtents.contentsSize.width),
            height: CGFloat(scrollExtents.contentsSize.height)
        )
        let velocity = NSPoint(x: CGFloat(initialVelocity.width), y: CGFloat(initialVelocity.height))
        let clippingSize = NSSize(width: CGFloat(scrollExtents.viewportSize.width), height: CGFloat(scrollExtents.viewportSize.height))
        platformMomentumCalculator = _NSScrollingMomentumCalculator(
            initialOrigin: origin,
            velocity: velocity,
            documentFrame: contentFrame,
            constrainedClippingOrigin: .zero,
            clippingSize: clippingSize,
            tolerance: NSSize(width: 1, height: 1)
        )
        initialDestinationOffset = ScrollPoint(platformMomentumCalculator?.destinationOrigin ?? .zero)
        return platformMomentumCalculator
    }
}

extension ScrollPoint {
    // FloatPoint(const CGPoint&).
    init(_ point: NSPoint) {
        self.init(x: Float(point.x), y: Float(point.y))
    }
}

// FloatPoint(IntPoint(position).constrainedBetween(IntPoint(), IntPoint(extents.maximumScrollOffset))), both coordinates
// at once: truncation toward zero, at most the truncated contentsSize - viewportSize where that is positive and 0 where
// it is not, and +0 for positions below 1 or NaN.
@inline(always)
private func integralPointConstrainedToScrollExtents(_ position: SIMD2<Float>, _ extents: ScrollPhysicsExtents) -> SIMD2<Float> {
    // The minimum is ScrollPhysicsExtents.minimumScrollOffset, which is zero, so it takes no part.
    let limit = SIMD2<Float>(repeating: 2_147_483_648)
    var result = position.rounded(.towardZero)
    result.replace(with: limit, where: position .>= limit)
    let available =
        SIMD2(extents.contentsSize.width, extents.contentsSize.height) - SIMD2(extents.viewportSize.width, extents.viewportSize.height)
    var high = available.rounded(.towardZero)
    high.replace(with: SIMD2(repeating: 0), where: .!(available .> 0))
    result.replace(with: high, where: high .< result)
    result.replace(with: SIMD2(repeating: 0), where: .!(position .>= 1))
    return result
}

// MARK: Rubber band

private func roundTowardZero(_ num: Float) -> Float {
    num > 0 ? (num - 0.5).rounded(.up) : (num + 0.5).rounded(.down)
}

private func roundToDevicePixelTowardZero(_ value: Float) -> Float {
    var num = value
    let roundedNum = num.rounded()
    if abs(num - roundedNum) < 0.125 {
        num = roundedNum
    }

    return roundTowardZero(num)
}

private func elasticDeltaForTimeDelta(_ initialPosition: Float, _ initialVelocity: Float, _ elapsedTime: Double) -> Float {
    Float(_NSElasticDeltaForTimeDelta(CGFloat(initialPosition), CGFloat(initialVelocity), CGFloat(elapsedTime)))
}

final class RubberBandScrollAnimation: ScrollPhysicsAnimationBase {
    static var animationType: ScrollPhysicsAnimationType { .rubberBand }

    var isActive = false
    var startTime: Double = 0
    private(set) var currentOffset = ScrollPoint.zero

    private(set) var initialVelocity = ScrollSize.zero
    private(set) var initialOverscroll = ScrollSize.zero
    private(set) var targetOverscroll = ScrollSize.zero

    init() {}

    // Puts the animation back in its initial state.
    func reset() {
        isActive = false
        startTime = 0
        currentOffset = .zero
        initialVelocity = .zero
        initialOverscroll = .zero
        targetOverscroll = .zero
    }

    // targetOverscroll is where the animation snaps to, which an NSRefreshController can move.
    func startRubberBandAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ initialVelocity: ScrollSize,
        _ initialOverscroll: ScrollSize,
        _ targetOverscroll: ScrollSize
    ) -> Bool {
        self.initialVelocity = initialVelocity
        self.initialOverscroll = initialOverscroll
        self.targetOverscroll = targetOverscroll

        didStart(&c, controller, scrollPhysicsClockNow())
        return true
    }

    func startRubberBandAnimationWithElapsedTime<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ initialVelocity: ScrollSize,
        _ initialOverscroll: ScrollSize,
        _ alreadyElapsed: Double,
        _ targetOverscroll: ScrollSize
    ) -> Bool {
        self.initialVelocity = initialVelocity
        self.initialOverscroll = initialOverscroll
        self.targetOverscroll = targetOverscroll

        didStart(&c, controller, scrollPhysicsClockNow() - alreadyElapsed)
        return true
    }

    func serviceAnimation<C: ScrollPhysicsClientProtocol & ~Copyable>(
        _ c: inout C,
        _ controller: ScrollPhysicsController,
        _ currentTime: Double,
        _ generation: UInt64
    ) {
        let elapsedTime = currentTime - startTime

        let relativeInitialOverscroll = initialOverscroll - targetOverscroll

        let relativeRubberBandOffset = ScrollSize(
            width: roundToDevicePixelTowardZero(
                elasticDeltaForTimeDelta(relativeInitialOverscroll.width, -initialVelocity.width, elapsedTime)
            ),
            height: roundToDevicePixelTowardZero(
                elasticDeltaForTimeDelta(relativeInitialOverscroll.height, -initialVelocity.height, elapsedTime)
            )
        )

        let rubberBandOffset = relativeRubberBandOffset + targetOverscroll

        // We might be rubberbanding away from an edge and back, so wait a frame or two before checking for completion.
        let animationComplete = relativeRubberBandOffset.isZero && elapsedTime > 0.024

        let scrollDelta = rubberBandOffset - ScrollSize(c.stretchAmount())
        currentOffset = ScrollPoint(c.scrollOffset()) + scrollDelta

        controller.scrollAnimationDidUpdate(&c, .Unclamped, currentOffset)
        if !controller.isCurrentAnimation(generation) {
            return
        }

        if animationComplete {
            didEnd(&c, controller)
        }
    }
}

#endif // USE_SWIFT_SCROLL_PHYSICS
