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

// The float arithmetic of FloatPoint, FloatSize, LayoutUnit, MathExtras.h and libc++ that ScrollingEffectsController
// and its animations use, with the same operations in the same order, so that results match bit for bit.

// WebCore_Private's headers reach JavaScriptCore and WTF types whose definitions are in these submodules. Swift can
// import those headers only when the submodules are loaded, and one file of the module importing them is enough.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import wtf.Core.Stopwatch
internal import WebCore_Private.Core.ScrollingEffectsClock
internal import WebCore_Private.ScrollPhysicsTypes

// std::min and std::max: the first argument is returned when the comparison fails, NaN included.
@inline(always)
func stdMin<T: Comparable>(_ a: T, _ b: T) -> T {
    b < a ? b : a
}

@inline(always)
func stdMax<T: Comparable>(_ a: T, _ b: T) -> T {
    a < b ? b : a
}

// clampTo<float>(float, min, max): NaN passes through.
@inline(always)
func clampTo(_ value: Float, _ minimum: Float, _ maximum: Float) -> Float {
    if value >= maximum {
        return maximum
    }
    if value <= minimum {
        return minimum
    }
    return value
}

// clampTo<int>(float): NaN and values at or below INT_MIN give INT_MIN.
@inline(always)
func clampToInt32(_ value: Float) -> Int32 {
    if value >= Float(Int32.max) {
        return .max
    }
    if !(value > Float(Int32.min)) {
        return .min
    }
    return Int32(value)
}

// clampTo<int>(double).
@inline(always)
func clampToInt32(_ value: Double) -> Int32 {
    if value >= Double(Int32.max) {
        return .max
    }
    if !(value > Double(Int32.min)) {
        return .min
    }
    return Int32(value)
}

// LayoutUnit(float) converts through LayoutUnit(double): clampTo<int>(value * kFixedPointDenominator).
@inline(always)
func layoutUnitRawValue(_ value: Float) -> Int32 {
    clampToInt32(Double(value) * 64)
}

// LayoutUnit::toFloat().
@inline(always)
func layoutUnitToFloat(_ rawValue: Int32) -> Float {
    Float(rawValue) / 64
}

// LayoutUnit's operator+: saturatingSum<int32_t>().
@inline(always)
func layoutUnitSum(_ a: Int32, _ b: Int32) -> Int32 {
    let (sum, overflow) = a.addingReportingOverflow(b)
    if overflow {
        return a < 0 ? .min : .max
    }
    return sum
}

// std::lerp(float, float, float) as libc++ implements it. The two multiply-adds are fused, as
// -ffp-contract=on fuses the C++ expressions.
@inline(always)
func libcxxLerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    if (a <= 0 && b >= 0) || (a >= 0 && b <= 0) {
        return ((1 - t) * a).addingProduct(t, b)
    }
    if t == 1 {
        return b
    }
    let x = a.addingProduct(t, b - a)
    if (t > 1) == (b > a) {
        return b < x ? x : b
    }
    return x < b ? x : b
}

struct ScrollSize: Equatable {
    var width: Float
    var height: Float

    static var zero: ScrollSize { ScrollSize(width: 0, height: 0) }

    init(width: Float, height: Float) {
        self.width = width
        self.height = height
    }

    // FloatSize::isZero().
    var isZero: Bool {
        abs(width) < Float.ulpOfOne && abs(height) < Float.ulpOfOne
    }

    // FloatSize::expand().
    mutating func expand(_ dw: Float, _ dh: Float) {
        width += dw
        height += dh
    }

    // FloatSize::scale().
    mutating func scale(_ s: Float) {
        width *= s
        height *= s
    }

    mutating func scale(_ sx: Float, _ sy: Float) {
        width *= sx
        height *= sy
    }

    func scaled(_ s: Float) -> ScrollSize {
        ScrollSize(width: width * s, height: height * s)
    }

    static prefix func - (size: ScrollSize) -> ScrollSize {
        ScrollSize(width: -size.width, height: -size.height)
    }

    static func + (a: ScrollSize, b: ScrollSize) -> ScrollSize {
        ScrollSize(width: a.width + b.width, height: a.height + b.height)
    }

    static func - (a: ScrollSize, b: ScrollSize) -> ScrollSize {
        ScrollSize(width: a.width - b.width, height: a.height - b.height)
    }

    static func += (a: inout ScrollSize, b: ScrollSize) {
        a = a + b
    }

    // Component-wise, as FloatSize's operator*(FloatSize, FloatSize).
    static func * (a: ScrollSize, b: ScrollSize) -> ScrollSize {
        ScrollSize(width: a.width * b.width, height: a.height * b.height)
    }

    static func / (a: ScrollSize, b: Float) -> ScrollSize {
        ScrollSize(width: a.width / b, height: a.height / b)
    }
}

struct ScrollPoint: Equatable {
    var x: Float
    var y: Float

    static var zero: ScrollPoint { ScrollPoint(x: 0, y: 0) }

    init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    // FloatPoint::constrainedBetween().
    func constrainedBetween(_ minimum: ScrollPoint, _ maximum: ScrollPoint) -> ScrollPoint {
        ScrollPoint(x: stdMax(minimum.x, stdMin(maximum.x, x)), y: stdMax(minimum.y, stdMin(maximum.y, y)))
    }

    static func + (point: ScrollPoint, size: ScrollSize) -> ScrollPoint {
        ScrollPoint(x: point.x + size.width, y: point.y + size.height)
    }

    static func + (a: ScrollPoint, b: ScrollPoint) -> ScrollPoint {
        ScrollPoint(x: a.x + b.x, y: a.y + b.y)
    }

    static func - (a: ScrollPoint, b: ScrollPoint) -> ScrollSize {
        ScrollSize(width: a.x - b.x, height: a.y - b.y)
    }
}

extension ScrollSize {
    init(_ size: WebCore.FloatSize) {
        self.init(width: size.width(), height: size.height())
    }

    init(_ size: WebCore.IntSize) {
        self.init(width: Float(size.width()), height: Float(size.height()))
    }

    var floatSize: WebCore.FloatSize {
        WebCore.FloatSize(width, height)
    }
}

extension ScrollPoint {
    init(_ point: WebCore.FloatPoint) {
        self.init(x: point.x(), y: point.y())
    }

    var floatPoint: WebCore.FloatPoint {
        WebCore.FloatPoint(x, y)
    }
}

// ScrollExtents, with minimumScrollOffset() and maximumScrollOffset().
struct ScrollPhysicsExtents {
    var contentsSize: ScrollSize
    var viewportSize: ScrollSize
    var snapportSize: ScrollSize

    init(_ extents: WebCore.ScrollExtents) {
        contentsSize = ScrollSize(extents.contentsSize)
        viewportSize = ScrollSize(extents.viewportSize)
        snapportSize = ScrollSize(extents.snapportSize)
    }

    var minimumScrollOffset: ScrollPoint { .zero }

    var maximumScrollOffset: ScrollPoint {
        let available = contentsSize - viewportSize
        return ScrollPoint(x: stdMax(available.width, 0), y: stdMax(available.height, 0))
    }
}

// IntSize::isZero().
@inline(always)
func isZero(_ size: WebCore.IntSize) -> Bool {
    size.width() == 0 && size.height() == 0
}

// scrollingEffectsClockNow(), in seconds.
@inline(always)
func scrollPhysicsClockNow() -> Double {
    WebCore.scrollingEffectsClockNow().secondsSinceEpoch().value()
}
