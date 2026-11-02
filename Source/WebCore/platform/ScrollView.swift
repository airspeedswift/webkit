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

// ScrollView's scrollbar update, coordinate conversions, visible rects, scroll position and overhang members on macOS.
// The functions that take a ScrollAnimatorScrollPhysicsClient take it inout; their caller made it on its own stack
// and does not store it, so nothing else reaches it while the function runs, and a call back into ScrollView makes
// its own. The others take only values. Main thread only, except for the functions that take only values.

#if USE_SWIFT_SCROLL_VIEW

internal import WebCore_Private.Core.BoxExtents
internal import WebCore_Private.Core.BoxSides
internal import WebCore_Private.Core.CornerRadii
internal import WebCore_Private.Core.DoublePoint
internal import WebCore_Private.Core.FloatPoint
internal import WebCore_Private.Core.FloatRect
internal import WebCore_Private.Core.FloatSize
internal import WebCore_Private.Core.IntPoint
internal import WebCore_Private.Core.IntRect
internal import WebCore_Private.Core.IntSize
internal import WebCore_Private.Core.RectEdges
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.Core.ScrollView
internal import WebCore_Private.ScrollAnimatorScrollPhysicsClient
internal import WebCore_Private.ScrollPhysicsTypes

// MARK: - Coordinate conversions

// Int sums and differences in these conversions wrap where IntPoint's and IntRect's int arithmetic would overflow,
// which is undefined in C++.

// documentScrollPositionRelativeToViewOrigin(): the scroll position less the view's inset offset. A difference
// outside the int range wraps (IntPoint's int arithmetic, undefined on overflow).
@inline(always)
private func documentPosition(_ scrollPosition: WebCore.IntPoint, _ insetOffset: WebCore.IntSize) -> WebCore.IntPoint {
    WebCore.IntPoint(scrollPosition.x() &- insetOffset.width(), scrollPosition.y() &- insetOffset.height())
}

// clampTo<int>() of a float already rounded to an integer (by roundf() or ceilf()): values above the int range give
// INT_MAX, and NaN and values below it give INT_MIN.
@inline(always)
private func clampRoundedToInt32(_ value: Float) -> Int32 {
    Int32(exactly: value) ?? (value > 0 ? .max : .min)
}

// roundedIntPoint(const FloatPoint&).
@inline(always)
private func roundedIntPoint(_ x: Float, _ y: Float) -> WebCore.IntPoint {
    WebCore.IntPoint(
        clampRoundedToInt32(x.rounded(.toNearestOrAwayFromZero)),
        clampRoundedToInt32(y.rounded(.toNearestOrAwayFromZero))
    )
}

// A float converted to int implicitly, as IntSize(int, int) takes it: undefined outside the int range, where arm64
// saturates and gives 0 for NaN.
@inline(always)
private func truncatedToInt32(_ value: Float) -> Int32 {
    if let truncated = Int32(exactly: value.rounded(.towardZero)) {
        return truncated
    }
    return value.isNaN ? 0 : (value > 0 ? .max : .min)
}

// viewToContents(const FloatPoint&) at a scale other than 1.
@inline(always)
private func viewToContentsScaled(
    _ scale: Float,
    _ scrollPosition: WebCore.IntPoint,
    _ insetOffset: WebCore.IntSize,
    _ x: Float,
    _ y: Float
) -> WebCore.FloatPoint {
    let inverse = 1 / scale
    let contentsX = (x - Float(insetOffset.width())) * inverse
    let contentsY = (y - Float(insetOffset.height())) * inverse
    return WebCore.FloatPoint(contentsX + Float(scrollPosition.x()), contentsY + Float(scrollPosition.y()))
}

// contentsToView(const FloatPoint&) at a scale other than 1.
@inline(always)
private func contentsToViewScaled(
    _ scale: Float,
    _ scrollPosition: WebCore.IntPoint,
    _ insetOffset: WebCore.IntSize,
    _ x: Float,
    _ y: Float
) -> WebCore.FloatPoint {
    let viewX = (x - Float(scrollPosition.x())) * scale
    let viewY = (y - Float(scrollPosition.y())) * scale
    return WebCore.FloatPoint(viewX + Float(insetOffset.width()), viewY + Float(insetOffset.height()))
}

@_expose(Cxx)
func scrollViewViewToContentsIntPoint(
    _ delegatesScrollingToNativeView: Bool,
    _ scale: Float,
    _ scrollPosition: WebCore.IntPoint,
    _ insetOffset: WebCore.IntSize,
    _ point: WebCore.IntPoint
) -> WebCore.IntPoint {
    if delegatesScrollingToNativeView {
        return point
    }
    if scale == 1 {
        let document = documentPosition(scrollPosition, insetOffset)
        return WebCore.IntPoint(point.x() &+ document.x(), point.y() &+ document.y())
    }
    let contents = viewToContentsScaled(scale, scrollPosition, insetOffset, Float(point.x()), Float(point.y()))
    return roundedIntPoint(contents.x(), contents.y())
}

@_expose(Cxx)
func scrollViewViewToContentsFloatPoint(
    _ delegatesScrollingToNativeView: Bool,
    _ scale: Float,
    _ scrollPosition: WebCore.IntPoint,
    _ insetOffset: WebCore.IntSize,
    _ point: WebCore.FloatPoint
) -> WebCore.FloatPoint {
    if delegatesScrollingToNativeView {
        return point
    }
    if scale == 1 {
        let document = documentPosition(scrollPosition, insetOffset)
        return WebCore.FloatPoint(point.x() + Float(document.x()), point.y() + Float(document.y()))
    }
    return viewToContentsScaled(scale, scrollPosition, insetOffset, point.x(), point.y())
}

@_expose(Cxx)
func scrollViewViewToContentsDoublePoint(
    _ delegatesScrollingToNativeView: Bool,
    _ scale: Float,
    _ scrollPosition: WebCore.IntPoint,
    _ insetOffset: WebCore.IntSize,
    _ point: WebCore.DoublePoint
) -> WebCore.DoublePoint {
    if delegatesScrollingToNativeView {
        return point
    }
    let scale = Double(scale)
    if scale == 1 {
        let document = documentPosition(scrollPosition, insetOffset)
        return WebCore.DoublePoint(point.x() + Double(document.x()), point.y() + Double(document.y()))
    }
    let inverse = 1 / scale
    let contentsX = (point.x() - Double(insetOffset.width())) * inverse
    let contentsY = (point.y() - Double(insetOffset.height())) * inverse
    return WebCore.DoublePoint(contentsX + Double(scrollPosition.x()), contentsY + Double(scrollPosition.y()))
}

@_expose(Cxx)
func scrollViewViewToContentsIntRect(
    _ delegatesScrollingToNativeView: Bool,
    _ scale: Float,
    _ scrollPosition: WebCore.IntPoint,
    _ insetOffset: WebCore.IntSize,
    _ rect: WebCore.IntRect
) -> WebCore.IntRect {
    if delegatesScrollingToNativeView {
        return rect
    }
    if scale == 1 {
        let document = documentPosition(scrollPosition, insetOffset)
        return WebCore.IntRect(rect.x() &+ document.x(), rect.y() &+ document.y(), rect.width(), rect.height())
    }
    let floatRect = WebCore.FloatRect(Float(rect.x()), Float(rect.y()), Float(rect.width()), Float(rect.height()))
    return WebCore.enclosingIntRect(scrollViewViewToContentsFloatRect(false, scale, scrollPosition, insetOffset, floatRect))
}

@_expose(Cxx)
func scrollViewViewToContentsFloatRect(
    _ delegatesScrollingToNativeView: Bool,
    _ scale: Float,
    _ scrollPosition: WebCore.IntPoint,
    _ insetOffset: WebCore.IntSize,
    _ rect: WebCore.FloatRect
) -> WebCore.FloatRect {
    if delegatesScrollingToNativeView {
        return rect
    }
    if scale == 1 {
        let document = documentPosition(scrollPosition, insetOffset)
        return WebCore.FloatRect(rect.x() + Float(document.x()), rect.y() + Float(document.y()), rect.width(), rect.height())
    }
    // The size scales along with the location, since a view pixel covers less content once it's magnified.
    let location = viewToContentsScaled(scale, scrollPosition, insetOffset, rect.x(), rect.y())
    let inverse = 1 / scale
    return WebCore.FloatRect(location.x(), location.y(), rect.width() * inverse, rect.height() * inverse)
}

@_expose(Cxx)
func scrollViewContentsToViewIntPoint(
    _ delegatesScrollingToNativeView: Bool,
    _ scale: Float,
    _ scrollPosition: WebCore.IntPoint,
    _ insetOffset: WebCore.IntSize,
    _ point: WebCore.IntPoint
) -> WebCore.IntPoint {
    if delegatesScrollingToNativeView {
        return point
    }
    if scale == 1 {
        let document = documentPosition(scrollPosition, insetOffset)
        return WebCore.IntPoint(point.x() &- document.x(), point.y() &- document.y())
    }
    let view = contentsToViewScaled(scale, scrollPosition, insetOffset, Float(point.x()), Float(point.y()))
    return roundedIntPoint(view.x(), view.y())
}

@_expose(Cxx)
func scrollViewContentsToViewFloatPoint(
    _ delegatesScrollingToNativeView: Bool,
    _ scale: Float,
    _ scrollPosition: WebCore.IntPoint,
    _ insetOffset: WebCore.IntSize,
    _ point: WebCore.FloatPoint
) -> WebCore.FloatPoint {
    if delegatesScrollingToNativeView {
        return point
    }
    if scale == 1 {
        let document = documentPosition(scrollPosition, insetOffset)
        return WebCore.FloatPoint(point.x() - Float(document.x()), point.y() - Float(document.y()))
    }
    return contentsToViewScaled(scale, scrollPosition, insetOffset, point.x(), point.y())
}

@_expose(Cxx)
func scrollViewContentsToViewDoublePoint(
    _ delegatesScrollingToNativeView: Bool,
    _ scale: Float,
    _ scrollPosition: WebCore.IntPoint,
    _ insetOffset: WebCore.IntSize,
    _ point: WebCore.DoublePoint
) -> WebCore.DoublePoint {
    if delegatesScrollingToNativeView {
        return point
    }
    let scale = Double(scale)
    if scale == 1 {
        let document = documentPosition(scrollPosition, insetOffset)
        return WebCore.DoublePoint(point.x() - Double(document.x()), point.y() - Double(document.y()))
    }
    let viewX = (point.x() - Double(scrollPosition.x())) * scale
    let viewY = (point.y() - Double(scrollPosition.y())) * scale
    return WebCore.DoublePoint(viewX + Double(insetOffset.width()), viewY + Double(insetOffset.height()))
}

@_expose(Cxx)
func scrollViewContentsToViewIntRect(
    _ delegatesScrollingToNativeView: Bool,
    _ scale: Float,
    _ scrollPosition: WebCore.IntPoint,
    _ insetOffset: WebCore.IntSize,
    _ rect: WebCore.IntRect
) -> WebCore.IntRect {
    if delegatesScrollingToNativeView {
        return rect
    }
    if scale == 1 {
        let document = documentPosition(scrollPosition, insetOffset)
        return WebCore.IntRect(rect.x() &- document.x(), rect.y() &- document.y(), rect.width(), rect.height())
    }
    let floatRect = WebCore.FloatRect(Float(rect.x()), Float(rect.y()), Float(rect.width()), Float(rect.height()))
    return WebCore.enclosingIntRect(scrollViewContentsToViewFloatRect(false, scale, scrollPosition, insetOffset, floatRect))
}

@_expose(Cxx)
func scrollViewContentsToViewFloatRect(
    _ delegatesScrollingToNativeView: Bool,
    _ scale: Float,
    _ scrollPosition: WebCore.IntPoint,
    _ insetOffset: WebCore.IntSize,
    _ rect: WebCore.FloatRect
) -> WebCore.FloatRect {
    if delegatesScrollingToNativeView {
        return rect
    }
    if scale == 1 {
        let document = documentPosition(scrollPosition, insetOffset)
        return WebCore.FloatRect(rect.x() - Float(document.x()), rect.y() - Float(document.y()), rect.width(), rect.height())
    }
    let location = contentsToViewScaled(scale, scrollPosition, insetOffset, rect.x(), rect.y())
    return WebCore.FloatRect(location.x(), location.y(), rect.width() * scale, rect.height() * scale)
}

@_expose(Cxx)
func scrollViewDocumentScrollPositionRelativeToViewOrigin(
    _ scrollPosition: WebCore.IntPoint,
    _ insetOffset: WebCore.IntSize
) -> WebCore.IntPoint {
    documentPosition(scrollPosition, insetOffset)
}

// Like rootViewToContents(), but ignores the header and the left scrollbar space. The insets convert to int by
// truncation, and the sums wrap (undefined on overflow).
@_expose(Cxx)
func scrollViewRootViewToTotalContents(
    _ delegatesScrollingToNativeView: Bool,
    _ viewPoint: WebCore.IntPoint,
    _ scrollPosition: WebCore.IntPoint,
    _ insets: WebCore.FloatBoxExtent
) -> WebCore.IntPoint {
    if delegatesScrollingToNativeView {
        return viewPoint
    }
    let x = viewPoint.x() &+ scrollPosition.x() &- truncatedToInt32(insets[.Left])
    let y = viewPoint.y() &+ scrollPosition.y() &- truncatedToInt32(insets[.Top])
    return WebCore.IntPoint(x, y)
}

// Scrollbars are positioned in the view's own coordinates; other children are in its contents. Int sums and
// differences wrap (undefined on overflow).
@_expose(Cxx)
func scrollViewConvertChildToSelfIntPoint(
    _ isScrollbar: Bool,
    _ childLocation: WebCore.IntPoint,
    _ documentScrollPosition: WebCore.IntPoint,
    _ point: WebCore.IntPoint
) -> WebCore.IntPoint {
    var x = point.x()
    var y = point.y()
    if !isScrollbar {
        x = x &- documentScrollPosition.x()
        y = y &- documentScrollPosition.y()
    }
    return WebCore.IntPoint(x &+ childLocation.x(), y &+ childLocation.y())
}

@_expose(Cxx)
func scrollViewConvertChildToSelfFloatPoint(
    _ isScrollbar: Bool,
    _ childLocation: WebCore.IntPoint,
    _ documentScrollPosition: WebCore.IntPoint,
    _ point: WebCore.FloatPoint
) -> WebCore.FloatPoint {
    var x = point.x()
    var y = point.y()
    if !isScrollbar {
        x -= Float(documentScrollPosition.x())
        y -= Float(documentScrollPosition.y())
    }
    return WebCore.FloatPoint(x + Float(childLocation.x()), y + Float(childLocation.y()))
}

// The scroll position is subtracted at float precision.
@_expose(Cxx)
func scrollViewConvertChildToSelfDoublePoint(
    _ isScrollbar: Bool,
    _ childLocation: WebCore.IntPoint,
    _ documentScrollPosition: WebCore.IntPoint,
    _ point: WebCore.DoublePoint
) -> WebCore.DoublePoint {
    var x = point.x()
    var y = point.y()
    if !isScrollbar {
        x += Double(-Float(documentScrollPosition.x()))
        y += Double(-Float(documentScrollPosition.y()))
    }
    return WebCore.DoublePoint(x + Double(childLocation.x()), y + Double(childLocation.y()))
}

@_expose(Cxx)
func scrollViewConvertSelfToChildIntPoint(
    _ isScrollbar: Bool,
    _ childLocation: WebCore.IntPoint,
    _ documentScrollPosition: WebCore.IntPoint,
    _ point: WebCore.IntPoint
) -> WebCore.IntPoint {
    var x = point.x()
    var y = point.y()
    if !isScrollbar {
        x = x &+ documentScrollPosition.x()
        y = y &+ documentScrollPosition.y()
    }
    return WebCore.IntPoint(x &+ (0 &- childLocation.x()), y &+ (0 &- childLocation.y()))
}

@_expose(Cxx)
func scrollViewConvertSelfToChildFloatPoint(
    _ isScrollbar: Bool,
    _ childLocation: WebCore.IntPoint,
    _ documentScrollPosition: WebCore.IntPoint,
    _ point: WebCore.FloatPoint
) -> WebCore.FloatPoint {
    var x = point.x()
    var y = point.y()
    if !isScrollbar {
        x += Float(documentScrollPosition.x())
        y += Float(documentScrollPosition.y())
    }
    return WebCore.FloatPoint(x + Float(0 &- childLocation.x()), y + Float(0 &- childLocation.y()))
}

@_expose(Cxx)
func scrollViewConvertSelfToChildDoublePoint(
    _ isScrollbar: Bool,
    _ childLocation: WebCore.IntPoint,
    _ documentScrollPosition: WebCore.IntPoint,
    _ point: WebCore.DoublePoint
) -> WebCore.DoublePoint {
    var x = point.x()
    var y = point.y()
    if !isScrollbar {
        x += Double(documentScrollPosition.x())
        y += Double(documentScrollPosition.y())
    }
    return WebCore.DoublePoint(x + Double(0 &- childLocation.x()), y + Double(0 &- childLocation.y()))
}

// Scrollbars are not transformed within the view. Int sums and differences wrap (undefined on overflow).
@_expose(Cxx)
func scrollViewConvertFromScrollbarToContainingViewIntRect(
    _ scrollbarLocation: WebCore.IntPoint,
    _ rect: WebCore.IntRect
) -> WebCore.IntRect {
    WebCore.IntRect(rect.x() &+ scrollbarLocation.x(), rect.y() &+ scrollbarLocation.y(), rect.width(), rect.height())
}

@_expose(Cxx)
func scrollViewConvertFromScrollbarToContainingViewIntPoint(
    _ scrollbarLocation: WebCore.IntPoint,
    _ point: WebCore.IntPoint
) -> WebCore.IntPoint {
    WebCore.IntPoint(point.x() &+ scrollbarLocation.x(), point.y() &+ scrollbarLocation.y())
}

@_expose(Cxx)
func scrollViewConvertFromContainingViewToScrollbarIntRect(
    _ scrollbarLocation: WebCore.IntPoint,
    _ rect: WebCore.IntRect
) -> WebCore.IntRect {
    WebCore.IntRect(rect.x() &- scrollbarLocation.x(), rect.y() &- scrollbarLocation.y(), rect.width(), rect.height())
}

@_expose(Cxx)
func scrollViewConvertFromContainingViewToScrollbarIntPoint(
    _ scrollbarLocation: WebCore.IntPoint,
    _ point: WebCore.IntPoint
) -> WebCore.IntPoint {
    WebCore.IntPoint(point.x() &- scrollbarLocation.x(), point.y() &- scrollbarLocation.y())
}

// MARK: - Rects, sizes and hit testing

@_expose(Cxx)
func scrollViewManagesScrollbars(
    _ hasPlatformWidget: Bool,
    _ mode: WebCore.DelegatedScrollingMode
) -> Bool {
    if hasPlatformWidget {
        return false
    }
    if mode == .DelegatedToNativeScrollView {
        return false
    }
    return true
}

@_expose(Cxx)
func scrollViewUnobscuredContentRect(
    _ unobscuredSize: WebCore.IntSize,
    _ scale: Float,
    _ scrollPosition: WebCore.IntPoint
) -> WebCore.IntRect {
    let inverse = 1 / scale
    let width = Float(unobscuredSize.width()) * inverse
    let height = Float(unobscuredSize.height()) * inverse
    let expandedWidth = clampRoundedToInt32(width.rounded(.up))
    let expandedHeight = clampRoundedToInt32(height.rounded(.up))
    return WebCore.IntRect(scrollPosition.x(), scrollPosition.y(), expandedWidth, expandedHeight)
}

@_expose(Cxx)
func scrollViewSizeForUnobscuredContent(
    _ visibleSize: WebCore.IntSize,
    _ insets: WebCore.FloatBoxExtent
) -> WebCore.IntSize {
    let insetWidth = clampRoundedToInt32((insets[.Left] + insets[.Right]).rounded(.toNearestOrAwayFromZero))
    let insetHeight = clampRoundedToInt32((insets[.Top] + insets[.Bottom]).rounded(.toNearestOrAwayFromZero))
    // The difference wraps (IntSize's int arithmetic, undefined on overflow).
    return WebCore.IntSize(visibleSize.width() &- insetWidth, visibleSize.height() &- insetHeight)
}

@_expose(Cxx)
func scrollViewScrollCornerRect(
    _ hasOverlayScrollbars: Bool,
    _ hasHorizontalScrollbar: Bool,
    _ horizontalFrame: WebCore.IntRect,
    _ hasVerticalScrollbar: Bool,
    _ verticalFrame: WebCore.IntRect
) -> WebCore.IntRect {
    if hasOverlayScrollbars || !hasHorizontalScrollbar || !hasVerticalScrollbar {
        return WebCore.IntRect()
    }
    return WebCore.IntRect(verticalFrame.x(), horizontalFrame.y(), verticalFrame.width(), horizontalFrame.height())
}

// IntRect::contains(const IntPoint&): half-open, with maxX() and maxY() wrapping (int arithmetic, undefined on
// overflow).
@inline(always)
private func rectContains(_ x: Int32, _ y: Int32, _ width: Int32, _ height: Int32, _ point: WebCore.IntPoint) -> Bool {
    point.x() >= x && point.x() < x &+ width && point.y() >= y && point.y() < y &+ height
}

// The horizontal scrollbar is tested first, and its rect grows vertically by its tolerance; the vertical one's grows
// horizontally. The growth wraps as IntRect's inflateX() and inflateY() do (undefined on overflow).
@_expose(Cxx)
func scrollViewScrollbarAtPoint(
    _ point: WebCore.IntPoint,
    _ tolerance: WebCore.ScrollbarHitTestTolerance,
    _ horizontalParticipates: Bool,
    _ horizontalFrame: WebCore.IntRect,
    _ horizontalThreshold: CInt,
    _ verticalParticipates: Bool,
    _ verticalFrame: WebCore.IntRect,
    _ verticalThreshold: CInt
) -> WebCore.OptionalScrollbarOrientation {
    if horizontalParticipates {
        var y = horizontalFrame.y()
        var height = horizontalFrame.height()
        if tolerance == .Expanded {
            y = y &- horizontalThreshold
            height = height &+ horizontalThreshold &+ horizontalThreshold
        }
        if rectContains(horizontalFrame.x(), y, horizontalFrame.width(), height, point) {
            return WebCore.OptionalScrollbarOrientation(.Horizontal)
        }
    }
    if verticalParticipates {
        var x = verticalFrame.x()
        var width = verticalFrame.width()
        if tolerance == .Expanded {
            x = x &- verticalThreshold
            width = width &+ verticalThreshold &+ verticalThreshold
        }
        if rectContains(x, verticalFrame.y(), width, verticalFrame.height(), point) {
            return WebCore.OptionalScrollbarOrientation(.Vertical)
        }
    }
    return WebCore.OptionalScrollbarOrientation()
}

// Only the horizontal scrollbar is tested when there is one, and the corner is taken to be to its right, also when
// the vertical scrollbar is on the left. The edges are excluded. The edge sums wrap (undefined on overflow).
@_expose(Cxx)
func scrollViewIsPointInScrollbarCorner(
    _ width: CInt,
    _ height: CInt,
    _ hasHorizontalScrollbar: Bool,
    _ horizontalFrame: WebCore.IntRect,
    _ hasVerticalScrollbar: Bool,
    _ verticalFrame: WebCore.IntRect,
    _ viewPoint: WebCore.IntPoint
) -> Bool {
    if !scrollViewScrollbarCornerPresent(width, height, hasHorizontalScrollbar, horizontalFrame, hasVerticalScrollbar, verticalFrame) {
        return false
    }
    if hasHorizontalScrollbar {
        let yMin = horizontalFrame.y()
        let yMax = horizontalFrame.y() &+ horizontalFrame.height()
        let xMin = horizontalFrame.x() &+ horizontalFrame.width()
        return viewPoint.y() > yMin && viewPoint.y() < yMax && viewPoint.x() > xMin
    }
    let xMin = verticalFrame.x()
    let xMax = verticalFrame.x() &+ verticalFrame.width()
    let yMin = verticalFrame.y() &+ verticalFrame.height()
    return viewPoint.x() > xMin && viewPoint.x() < xMax && viewPoint.y() > yMin
}

// The differences wrap (undefined on overflow).
@_expose(Cxx)
func scrollViewScrollbarCornerPresent(
    _ width: CInt,
    _ height: CInt,
    _ hasHorizontalScrollbar: Bool,
    _ horizontalFrame: WebCore.IntRect,
    _ hasVerticalScrollbar: Bool,
    _ verticalFrame: WebCore.IntRect
) -> Bool {
    (hasHorizontalScrollbar && width &- horizontalFrame.width() > 0) || (hasVerticalScrollbar && height &- verticalFrame.height() > 0)
}

// MARK: - Overhang

// The height is measured against totalContentsSize() and the width against contentsWidth(). Differences outside the
// int range wrap (int arithmetic, undefined on overflow).
@_expose(Cxx)
func scrollViewOverhangAmount(
    _ scrollOffset: WebCore.IntPoint,
    _ totalContentsSize: WebCore.IntSize,
    _ visibleSize: WebCore.IntSize,
    _ contentsWidth: CInt
) -> WebCore.IntSize {
    var stretchWidth: Int32 = 0
    var stretchHeight: Int32 = 0
    let totalHeight = totalContentsSize.height()
    if scrollOffset.y() < 0 {
        stretchHeight = scrollOffset.y()
    } else if totalHeight != 0 && scrollOffset.y() > totalHeight &- visibleSize.height() {
        stretchHeight = scrollOffset.y() &- (totalHeight &- visibleSize.height())
    }
    if scrollOffset.x() < 0 {
        stretchWidth = scrollOffset.x()
    } else if contentsWidth != 0 && scrollOffset.x() > contentsWidth &- visibleSize.width() {
        stretchWidth = scrollOffset.x() &- (contentsWidth &- visibleSize.width())
    }
    return WebCore.IntSize(stretchWidth, stretchHeight)
}

// Assigns each rect only where there is overhang on its axis, and reads the horizontal rect when placing the vertical
// one. Differences outside the int range wrap (int arithmetic, undefined on overflow).
@_expose(Cxx)
func scrollViewCalculateOverhangAreas(
    _ scrollbarSpace: WebCore.IntSize,
    _ scrollOffset: WebCore.IntPoint,
    _ frameRect: WebCore.IntRect,
    _ totalContentsSize: WebCore.IntSize,
    _ visibleSize: WebCore.IntSize,
    _ contentsWidth: CInt,
    _ horizontalOverhangRect: inout WebCore.IntRect,
    _ verticalOverhangRect: inout WebCore.IntRect
) {
    let totalHeight = totalContentsSize.height()
    if scrollOffset.y() < 0 {
        horizontalOverhangRect = frameRect
        horizontalOverhangRect.setHeight(0 &- scrollOffset.y())
        horizontalOverhangRect.setWidth(horizontalOverhangRect.width() &- scrollbarSpace.width())
    } else if totalHeight != 0 && scrollOffset.y() > totalHeight &- visibleSize.height() {
        let height = scrollOffset.y() &- (totalHeight &- visibleSize.height())
        horizontalOverhangRect = frameRect
        horizontalOverhangRect.setY((frameRect.y() &+ frameRect.height()) &- height &- scrollbarSpace.height())
        horizontalOverhangRect.setHeight(height)
        horizontalOverhangRect.setWidth(horizontalOverhangRect.width() &- scrollbarSpace.width())
    }

    let verticalWidth: Int32
    let verticalX: Int32
    if scrollOffset.x() < 0 {
        verticalWidth = 0 &- scrollOffset.x()
        verticalX = frameRect.x()
    } else if contentsWidth != 0 && scrollOffset.x() > contentsWidth &- visibleSize.width() {
        verticalWidth = scrollOffset.x() &- (contentsWidth &- visibleSize.width())
        verticalX = (frameRect.x() &+ frameRect.width()) &- verticalWidth &- scrollbarSpace.width()
    } else {
        return
    }
    verticalOverhangRect.setWidth(verticalWidth)
    verticalOverhangRect.setHeight(frameRect.height() &- horizontalOverhangRect.height() &- scrollbarSpace.height())
    verticalOverhangRect.setX(verticalX)
    if horizontalOverhangRect.y() == frameRect.y() {
        verticalOverhangRect.setY(frameRect.y() &+ horizontalOverhangRect.height())
    } else {
        verticalOverhangRect.setY(frameRect.y())
    }
}

// MARK: - The scrollbar update

// How many times updateScrollbars() lays out again for a scrollbar change before it settles for the result.
private let maximumUpdateScrollbarsPass: UInt32 = 3

@inline(always)
private func pointsEqual(_ a: WebCore.IntPoint, _ b: WebCore.IntPoint) -> Bool {
    a.x() == b.x() && a.y() == b.y()
}

@inline(always)
private func sizesEqual(_ a: WebCore.IntSize, _ b: WebCore.IntSize) -> Bool {
    a.width() == b.width() && a.height() == b.height()
}

@inline(always)
private func rectsEqual(_ a: WebCore.IntRect, _ b: WebCore.IntRect) -> Bool {
    a.x() == b.x() && a.y() == b.y() && a.width() == b.width() && a.height() == b.height()
}

@inline(always)
private func cornerRadius(_ radii: WebCore.CornerRadii, _ corner: WebCore.BoxCorner) -> WebCore.FloatSize {
    WebCore.ScrollAnimatorScrollPhysicsClient.cornerRadius(radii, corner)
}

// scrollCornerRect(), from the scrollbars the view has now.
private func currentScrollCornerRect(_ c: inout WebCore.ScrollAnimatorScrollPhysicsClient) -> WebCore.IntRect {
    let hasOverlayScrollbars = c.hasOverlayScrollbars()
    let hasHorizontalScrollbar = c.protectViewScrollbar(.Horizontal)
    let horizontalFrame = hasHorizontalScrollbar ? c.protectedScrollbarFrameRect(.Horizontal) : WebCore.IntRect()
    c.releaseProtectedScrollbar(.Horizontal)
    let hasVerticalScrollbar = c.protectViewScrollbar(.Vertical)
    let verticalFrame = hasVerticalScrollbar ? c.protectedScrollbarFrameRect(.Vertical) : WebCore.IntRect()
    c.releaseProtectedScrollbar(.Vertical)
    return scrollViewScrollCornerRect(hasOverlayScrollbars, hasHorizontalScrollbar, horizontalFrame, hasVerticalScrollbar, verticalFrame)
}

// The scrollbar's occupied width (vertical) or height (horizontal); traps if the view has no such scrollbar.
private func occupiedScrollbarSpace(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ orientation: WebCore.ScrollbarOrientation
) -> Int32 {
    _ = c.protectViewScrollbar(orientation)
    let space = orientation == .Vertical ? c.protectedScrollbarOccupiedWidth(orientation) : c.protectedScrollbarOccupiedHeight(orientation)
    c.releaseProtectedScrollbar(orientation)
    return space
}

private func invalidateScrollbarIfPresent(_ c: inout WebCore.ScrollAnimatorScrollPhysicsClient, _ orientation: WebCore.ScrollbarOrientation)
{
    if c.protectViewScrollbar(orientation) {
        c.protectedScrollbarInvalidate(orientation)
    }
    c.releaseProtectedScrollbar(orientation)
}

// Scrolls to the position, constrained unless rubber banding, if it differs from the current one or the origin
// changed.
private func scrollViewScrollToPositionAfterUpdate(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ desiredPosition: WebCore.IntPoint
) {
    var adjustedScrollPosition = desiredPosition
    if !c.isRubberBandInProgress() {
        adjustedScrollPosition = c.adjustScrollPositionWithinRange(adjustedScrollPosition)
    }

    if !pointsEqual(adjustedScrollPosition, c.scrollPosition()) || c.scrollOriginChanged() {
        c.scrollToPositionWithoutAnimation(WebCore.FloatPoint(Float(adjustedScrollPosition.x()), Float(adjustedScrollPosition.y())))
        c.resetScrollOriginChanged()
    }
}

// Places the horizontal scrollbar along the bottom, clear of the avoided corners and the obscured insets, and
// sets its range. Returns whether its frame changed while scrollbars were not suppressed.
private func scrollViewUpdateHorizontalScrollbar(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ contentInsets: WebCore.FloatBoxExtent,
    _ cornerRadii: WebCore.CornerRadii
) -> Bool {
    var frameChanged = false
    // The scrollbar is held for the whole update.
    _ = c.protectViewScrollbar(.Horizontal)
    let clientWidth = c.visibleSize().width()
    let oldRect = c.protectedScrollbarFrameRect(.Horizontal)

    let scrollerHalfHeight = Float(c.protectedScrollbarHeight(.Horizontal)) / 2
    let scrollCornerWidth: Float = c.hasViewScrollbar(.Vertical) ? Float(occupiedScrollbarSpace(&c, .Vertical)) : 0
    var leftOffset = stdMax(
        Float(0),
        cornerRadius(cornerRadii, .BottomLeft).width() - (c.shouldPlaceVerticalScrollbarOnLeft() ? scrollCornerWidth : 0)
    )
    var rightOffset = stdMax(
        Float(0),
        cornerRadius(cornerRadii, .BottomRight).width() - (c.shouldPlaceVerticalScrollbarOnLeft() ? 0 : scrollCornerWidth)
    )

    if !c.protectedScrollbarIsCustom(.Horizontal) {
        leftOffset = stdMax(Float(0), leftOffset - scrollerHalfHeight)
        rightOffset = stdMax(Float(0), rightOffset - scrollerHalfHeight)
    }

    leftOffset = stdMax(leftOffset, contentInsets[.Left])
    rightOffset = stdMax(rightOffset, contentInsets[.Right])

    let leftScrollbarSpace: Float =
        c.shouldPlaceVerticalScrollbarOnLeft() && c.hasViewScrollbar(.Vertical) ? Float(occupiedScrollbarSpace(&c, .Vertical)) : 0
    let horizontalOffset = leftOffset + leftScrollbarSpace
    let viewWidth = Float(c.frameRect().width())
    let barWidth = viewWidth - (c.hasViewScrollbar(.Vertical) ? Float(occupiedScrollbarSpace(&c, .Vertical)) : 0) - leftOffset - rightOffset

    // The difference wraps (int arithmetic, undefined on overflow) before the inset is subtracted in float.
    let horizontalScrollbarY = Float(c.frameRect().height() &- c.protectedScrollbarHeight(.Horizontal)) - contentInsets[.Bottom]

    c.protectedScrollbarSetFrameRect(
        .Horizontal,
        WebCore.roundedIntRect(
            WebCore.FloatRect(
                horizontalOffset,
                horizontalScrollbarY,
                barWidth,
                Float(c.protectedScrollbarHeight(.Horizontal))
            )
        )
    )
    if !c.scrollbarsSuppressed() && !rectsEqual(oldRect, c.protectedScrollbarFrameRect(.Horizontal)) {
        c.protectedScrollbarInvalidate(.Horizontal)
        frameChanged = true
    }

    if c.scrollbarsSuppressed() {
        c.protectedScrollbarSetSuppressInvalidation(.Horizontal, true)
    }
    c.protectedScrollbarSetEnabled(.Horizontal, c.contentsSize().width() > clientWidth)
    c.protectedScrollbarSetProportion(.Horizontal, clientWidth, c.contentsSize().width())
    if c.scrollbarsSuppressed() {
        c.protectedScrollbarSetSuppressInvalidation(.Horizontal, false)
    }
    c.releaseProtectedScrollbar(.Horizontal)
    return frameChanged
}

// Places the vertical scrollbar along the right edge, or the left one where it goes on the left, clear of the
// avoided corners and the obscured insets, and sets its range. Returns whether its frame changed while scrollbars
// were not suppressed.
private func scrollViewUpdateVerticalScrollbar(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ contentInsets: WebCore.FloatBoxExtent,
    _ cornerRadii: WebCore.CornerRadii
) -> Bool {
    var frameChanged = false
    // The scrollbar is held for the whole update.
    _ = c.protectViewScrollbar(.Vertical)
    let clientHeight = c.visibleSize().height()
    let oldRect = c.protectedScrollbarFrameRect(.Vertical)

    let scrollerHalfWidth = Float(c.protectedScrollbarWidth(.Vertical)) / 2
    let isRTL = c.shouldPlaceVerticalScrollbarOnLeft()

    let upperCornerRadius = isRTL ? cornerRadius(cornerRadii, .TopLeft).height() : cornerRadius(cornerRadii, .TopRight).height()
    let lowerCornerRadius = isRTL ? cornerRadius(cornerRadii, .BottomLeft).height() : cornerRadius(cornerRadii, .BottomRight).height()

    var topOffset = stdMax(Float(0), upperCornerRadius)
    let scrollCornerHeight: Float = c.hasViewScrollbar(.Horizontal) ? Float(occupiedScrollbarSpace(&c, .Horizontal)) : 0
    var bottomOffset = stdMax(Float(0), lowerCornerRadius - scrollCornerHeight)

    if !c.protectedScrollbarIsCustom(.Vertical) {
        topOffset = stdMax(Float(0), topOffset - scrollerHalfWidth)
        bottomOffset = stdMax(Float(0), bottomOffset - scrollerHalfWidth)
    }

    topOffset = stdMax(topOffset, contentInsets[.Top])
    bottomOffset = stdMax(bottomOffset, contentInsets[.Bottom])

    // The int differences wrap (int arithmetic, undefined on overflow) before the float offsets are subtracted.
    let viewHeight = c.frameRect().height()
    let horizontalScrollbarSpace: Int32 = c.hasViewScrollbar(.Horizontal) ? occupiedScrollbarSpace(&c, .Horizontal) : 0
    let barHeight = Float(viewHeight &- horizontalScrollbarSpace) - topOffset - bottomOffset

    let verticalScrollbarX: Float
    if isRTL {
        verticalScrollbarX = contentInsets[.Left]
    } else {
        verticalScrollbarX = Float(c.frameRect().width() &- c.protectedScrollbarWidth(.Vertical)) - contentInsets[.Right]
    }

    c.protectedScrollbarSetFrameRect(
        .Vertical,
        WebCore.roundedIntRect(
            WebCore.FloatRect(
                verticalScrollbarX,
                topOffset,
                Float(c.protectedScrollbarWidth(.Vertical)),
                barHeight
            )
        )
    )
    if !c.scrollbarsSuppressed() && !rectsEqual(oldRect, c.protectedScrollbarFrameRect(.Vertical)) {
        c.protectedScrollbarInvalidate(.Vertical)
        frameChanged = true
    }

    if c.scrollbarsSuppressed() {
        c.protectedScrollbarSetSuppressInvalidation(.Vertical, true)
    }
    c.protectedScrollbarSetEnabled(.Vertical, c.totalContentsSize().height() > clientHeight)
    c.protectedScrollbarSetProportion(.Vertical, clientHeight, c.totalContentsSize().height())
    if c.scrollbarsSuppressed() {
        c.protectedScrollbarSetSuppressInvalidation(.Vertical, false)
    }
    c.releaseProtectedScrollbar(.Vertical)
    return frameChanged
}

// ScrollView::updateScrollbars(). Lays out again with each scrollbar change, up to maximumUpdateScrollbarsPass times.
// The re-entry guard is held only for the first layout and the final placement, not across the passes; a nested call
// places nothing. While `c` is live this calls canShowNonOverlayScrollbars(), updateContentsSize(),
// availableContentSizeChanged(), what setHasScrollbarInternal() calls, addedOrRemovedScrollbar(),
// shouldPlaceVerticalScrollbarOnLeft(), the scrollbars' frame, range and offset setters, updateScrollbarSteps(),
// positionScrollbarLayers(), frameRectsChanged(), updateScrollCorner(), invalidateRect(),
// isRubberBandInProgress() and ScrollableArea::scrollToPositionWithoutAnimation(), which scrolls through the animator
// and scrollTo().
@_expose(Cxx)
func scrollViewUpdateScrollbars(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ desiredPosition: WebCore.IntPoint
) {
    if c.inUpdateScrollbars() || c.prohibitsScrolling() || c.hasPlatformWidget() {
        return
    }

    // managesScrollbars(); the platform widget case returned above.
    if c.delegatesScrollingToNativeView() {
        scrollViewScrollToPositionAfterUpdate(&c, desiredPosition)
        return
    }

    let scrollbarCanTakeSpace = c.canShowNonOverlayScrollbars()

    // If we came in here with the view already needing a layout then do that first.
    // (This will be the common case, e.g., when the page changes due to window resizing for example).
    // This layout will not re-enter updateScrollbars and does not count towards our max layout pass total.
    if !c.scrollbarsSuppressed() && scrollbarCanTakeSpace {
        c.setInUpdateScrollbars(true)
        defer { c.setInUpdateScrollbars(false) }
        c.updateContentsSize()
    }

    let oldScrollCornerRect = currentScrollCornerRect(&c)

    let hasHorizontalScrollbar = c.hasViewScrollbar(.Horizontal)
    let hasVerticalScrollbar = c.hasViewScrollbar(.Vertical)

    var newHasHorizontalScrollbar = hasHorizontalScrollbar
    var newHasVerticalScrollbar = hasVerticalScrollbar

    let hScroll = c.scrollbarModeValue(.Horizontal)
    let vScroll = c.scrollbarModeValue(.Vertical)

    if hScroll != .Auto {
        newHasHorizontalScrollbar = hScroll == .AlwaysOn
    }
    if vScroll != .Auto {
        newHasVerticalScrollbar = vScroll == .AlwaysOn
    }

    var scrollbarAddedOrRemoved = false

    if c.scrollbarsSuppressed() || (hScroll != .Auto && vScroll != .Auto) {
        var unusedContentSizeAffected = false
        if hasHorizontalScrollbar != newHasHorizontalScrollbar {
            if scrollViewSetHasScrollbar(&c, .Horizontal, newHasHorizontalScrollbar, &unusedContentSizeAffected) {
                scrollbarAddedOrRemoved = true
            }
        }

        if hasVerticalScrollbar != newHasVerticalScrollbar {
            if scrollViewSetHasScrollbar(&c, .Vertical, newHasVerticalScrollbar, &unusedContentSizeAffected) {
                scrollbarAddedOrRemoved = true
            }
        }
    } else {
        var sendContentResizedNotification = false

        let docSize = c.totalContentsSize()
        let fullVisibleRect = c.unobscuredContentRectIncludingScrollbars()
        let fullVisibleWidth = fullVisibleRect.width()
        let fullVisibleHeight = fullVisibleRect.height()

        // These are in contents coordinates, so a zoomed-in page gets a scrollbar for the content the view no longer covers.
        if hScroll == .Auto {
            newHasHorizontalScrollbar = docSize.width() > c.visibleSize().width()
        }
        if vScroll == .Auto {
            newHasVerticalScrollbar = docSize.height() > c.visibleSize().height()
        }

        var needAnotherPass = false
        if scrollbarCanTakeSpace {
            // If we ever turn one scrollbar off, do not turn the other one on. Never ever
            // try to both gain/lose a scrollbar in the same pass.
            if c.updateScrollbarsPass() == 0 && docSize.width() <= fullVisibleWidth && docSize.height() <= fullVisibleHeight {
                if hScroll == .Auto {
                    newHasHorizontalScrollbar = false
                }
                if vScroll == .Auto {
                    newHasVerticalScrollbar = false
                }
            }
            if !newHasHorizontalScrollbar && hasHorizontalScrollbar && vScroll != .AlwaysOn && !hasVerticalScrollbar {
                newHasVerticalScrollbar = false
                needAnotherPass = true
            }
            if !newHasVerticalScrollbar && hasVerticalScrollbar && hScroll != .AlwaysOn && !hasHorizontalScrollbar {
                newHasHorizontalScrollbar = false
                needAnotherPass = true
            }
        }

        if hasHorizontalScrollbar != newHasHorizontalScrollbar {
            // Removing the scrollbar moves a non-zero origin by its height. The difference wraps (int arithmetic,
            // undefined on overflow).
            if c.scrollOrigin().y() != 0 && !newHasHorizontalScrollbar {
                let originX = c.scrollOrigin().x()
                let originY = c.scrollOrigin().y()
                c.setAreaScrollOrigin(WebCore.IntPoint(originX, originY &- occupiedScrollbarSpace(&c, .Horizontal)))
            }
            invalidateScrollbarIfPresent(&c, .Horizontal)

            var changeAffectsContentSize = false
            if scrollViewSetHasScrollbar(&c, .Horizontal, newHasHorizontalScrollbar, &changeAffectsContentSize) {
                scrollbarAddedOrRemoved = true
                sendContentResizedNotification = sendContentResizedNotification || changeAffectsContentSize
            }
        }

        if hasVerticalScrollbar != newHasVerticalScrollbar {
            // Removing the scrollbar moves a non-zero origin by its width. The difference wraps (int arithmetic,
            // undefined on overflow).
            if c.scrollOrigin().x() != 0 && !newHasVerticalScrollbar {
                let originX = c.scrollOrigin().x()
                let space = occupiedScrollbarSpace(&c, .Vertical)
                let originY = c.scrollOrigin().y()
                c.setAreaScrollOrigin(WebCore.IntPoint(originX &- space, originY))
            }
            invalidateScrollbarIfPresent(&c, .Vertical)

            var changeAffectsContentSize = false
            if scrollViewSetHasScrollbar(&c, .Vertical, newHasVerticalScrollbar, &changeAffectsContentSize) {
                scrollbarAddedOrRemoved = true
                sendContentResizedNotification = sendContentResizedNotification || changeAffectsContentSize
            }
        }

        if (sendContentResizedNotification || needAnotherPass) && c.updateScrollbarsPass() < maximumUpdateScrollbarsPass {
            // Unsigned, as the C++ counter; the pass is below maximumUpdateScrollbarsPass.
            c.setUpdateScrollbarsPass(c.updateScrollbarsPass() &+ 1)
            c.availableContentSizeChangedByScrollbars()
            c.updateContentsSize()
            let newDocSize = c.totalContentsSize()
            if sizesEqual(newDocSize, docSize) {
                // The layout with the new scroll state had no impact on
                // the document's overall size, so updateScrollbars didn't get called.
                // Recur manually.
                scrollViewUpdateScrollbars(&c, desiredPosition)
            }
            // Wraps, as the C++ does, only if a nested call left the pass at 0.
            c.setUpdateScrollbarsPass(c.updateScrollbarsPass() &- 1)
        }
    }

    if scrollbarAddedOrRemoved {
        c.addedOrRemovedScrollbar()
    }

    // Set up the range (and page step/line step), but only do this if we're not in a nested call (to avoid
    // doing it multiple times).
    if c.updateScrollbarsPass() != 0 {
        return
    }

    c.setInUpdateScrollbars(true)
    defer { c.setInUpdateScrollbars(false) }

    var needsLayersRepositioned = false
    let contentInsets = c.obscuredContentInsets()
    let cornerRadii = c.scrollbarAvoidanceCornerRadii()

    if c.hasViewScrollbar(.Horizontal) {
        if scrollViewUpdateHorizontalScrollbar(&c, contentInsets, cornerRadii) {
            needsLayersRepositioned = true
        }
    }

    if c.hasViewScrollbar(.Vertical) {
        if scrollViewUpdateVerticalScrollbar(&c, contentInsets, cornerRadii) {
            needsLayersRepositioned = true
        }
    }

    c.updateScrollbarSteps()
    if needsLayersRepositioned {
        c.positionScrollbarLayers()
    }

    if hasHorizontalScrollbar != newHasHorizontalScrollbar || hasVerticalScrollbar != newHasVerticalScrollbar {
        // FIXME: Is frameRectsChanged really necessary here? Have any frame rects changed?
        c.frameRectsChanged()
        c.positionScrollbarLayers()
        c.updateScrollCorner()
        if !c.hasViewScrollbar(.Horizontal) && !c.hasViewScrollbar(.Vertical) {
            c.invalidateRect(oldScrollCornerRect)
        }
    }

    scrollViewScrollToPositionAfterUpdate(&c, desiredPosition)

    // Make sure the scrollbar offsets are up to date.
    if c.protectViewScrollbar(.Horizontal) {
        c.protectedScrollbarOffsetDidChange(.Horizontal)
    }
    c.releaseProtectedScrollbar(.Horizontal)
    if c.protectViewScrollbar(.Vertical) {
        c.protectedScrollbarOffsetDidChange(.Vertical)
    }
    c.releaseProtectedScrollbar(.Vertical)
}

// ScrollView::setHasScrollbarInternal(). Writes contentSizeAffected only when the scrollbar is added or removed. While
// `c` is live this calls createScrollbar(), addChild(), didAddScrollbar() and the scrollbar's styleChanged() when
// adding, and willRemoveScrollbar() and removeChild() when removing.
@_expose(Cxx)
func scrollViewSetHasScrollbar(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ orientation: WebCore.ScrollbarOrientation,
    _ hasBar: Bool,
    _ contentSizeAffected: inout Bool
) -> Bool {
    if hasBar && !c.hasViewScrollbar(orientation) {
        c.createScrollbarInto(orientation)
        c.addScrollbarChild(orientation)
        c.didAddScrollbar(orientation)
        _ = c.protectViewScrollbar(orientation)
        c.protectedScrollbarStyleChanged(orientation)
        contentSizeAffected = !c.protectedScrollbarIsOverlay(orientation)
        c.releaseProtectedScrollbar(orientation)
        return true
    }

    if !hasBar && c.hasViewScrollbar(orientation) {
        _ = c.protectViewScrollbar(orientation)
        let wasOverlayScrollbar = c.protectedScrollbarIsOverlay(orientation)
        c.releaseProtectedScrollbar(orientation)
        c.willRemoveScrollbar(orientation)
        c.removeScrollbarChild(orientation)
        c.clearScrollbar(orientation)
        contentSizeAffected = !wasOverlayScrollbar
        return true
    }

    return false
}

// Whether setScrollbarModes() changes a mode: the requested mode differs from the current one (the platform's, when
// there is a platform widget) and that orientation is not locked.
@inline(always)
private func scrollbarModeChanges(_ requested: WebCore.ScrollbarMode, _ current: WebCore.ScrollbarMode, _ locked: Bool) -> Bool {
    requested != current && !locked
}

// Whether setScrollbarModes() has anything to do: a mode changes, or a lock is requested that is not yet set.
@_expose(Cxx)
func scrollViewSetScrollbarModesChangesAnything(
    _ horizontalMode: WebCore.ScrollbarMode,
    _ currentHorizontalMode: WebCore.ScrollbarMode,
    _ horizontalLocked: Bool,
    _ horizontalLock: Bool,
    _ verticalMode: WebCore.ScrollbarMode,
    _ currentVerticalMode: WebCore.ScrollbarMode,
    _ verticalLocked: Bool,
    _ verticalLock: Bool
) -> Bool {
    scrollbarModeChanges(horizontalMode, currentHorizontalMode, horizontalLocked)
        || scrollbarModeChanges(verticalMode, currentVerticalMode, verticalLocked)
        || (horizontalLock && !horizontalLocked) || (verticalLock && !verticalLocked)
}

// ScrollView::setScrollbarModes(), given the current modes (the platform's, when there is a platform widget) and the
// view's own locks, once scrollViewSetScrollbarModesChangesAnything() has returned true. Sets the locks after the
// modes. While `c` is live this calls platformSetScrollbarModes() or what updateScrollbars() calls, and
// scrollbarModesDidChange().
@_expose(Cxx)
func scrollViewSetScrollbarModes(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ horizontalMode: WebCore.ScrollbarMode,
    _ currentHorizontalMode: WebCore.ScrollbarMode,
    _ horizontalLocked: Bool,
    _ horizontalLock: Bool,
    _ verticalMode: WebCore.ScrollbarMode,
    _ currentVerticalMode: WebCore.ScrollbarMode,
    _ verticalLocked: Bool,
    _ verticalLock: Bool
) {
    var needsUpdate = false

    if scrollbarModeChanges(horizontalMode, currentHorizontalMode, horizontalLocked) {
        c.setScrollbarModeValue(.Horizontal, horizontalMode)
        needsUpdate = true
    }

    if scrollbarModeChanges(verticalMode, currentVerticalMode, verticalLocked) {
        c.setScrollbarModeValue(.Vertical, verticalMode)
        needsUpdate = true
    }

    if horizontalLock {
        c.setScrollbarLock(.Horizontal)
    }

    if verticalLock {
        c.setScrollbarLock(.Vertical)
    }

    if !needsUpdate {
        return
    }

    if c.hasPlatformWidget() {
        c.platformSetScrollbarModes()
    } else {
        scrollViewUpdateScrollbars(&c, c.scrollPosition())
    }

    c.scrollbarModesDidChange()
}

// ScrollView::setCanHaveScrollbars()'s mode for one orientation, from the current one.
@_expose(Cxx)
func scrollViewCanHaveScrollbarsMode(
    _ canScroll: Bool,
    _ mode: WebCore.ScrollbarMode
) -> WebCore.ScrollbarMode {
    if canScroll && mode == .AlwaysOff {
        return .Auto
    }
    if !canScroll {
        return .AlwaysOff
    }
    return mode
}

// Whether setScrollbarsSuppressed() changes the view's state.
@_expose(Cxx)
func scrollViewSetScrollbarsSuppressedChanges(_ suppressed: Bool, _ currentlySuppressed: Bool) -> Bool {
    suppressed != currentlySuppressed
}

// ScrollView::setScrollbarsSuppressed(), once scrollViewSetScrollbarsSuppressedChanges() has returned true. While `c` is
// live this calls platformSetScrollbarsSuppressed(), or the scrollbars' invalidate() and invalidateRect().
@_expose(Cxx)
func scrollViewSetScrollbarsSuppressed(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ suppressed: Bool,
    _ repaintOnUnsuppress: Bool
) {
    c.setScrollbarsSuppressedValue(suppressed)

    if c.hasPlatformWidget() {
        c.platformSetScrollbarsSuppressed(repaintOnUnsuppress)
    } else if repaintOnUnsuppress && !suppressed {
        invalidateScrollbarIfPresent(&c, .Horizontal)
        invalidateScrollbarIfPresent(&c, .Vertical)

        // Invalidate the scroll corner too on unsuppress.
        c.invalidateRect(currentScrollCornerRect(&c))
    }
}

// ScrollView::handleDeferredScrollUpdateAfterContentSizeChange(). A pending scroll delta takes precedence over pending
// offsets, and both are cleared. The delta is read again after the layer positions update, as the stored value is what
// gets scrolled. While `c` is live this calls updateLayerPositionsAfterScrolling(), what scrollContents() calls and
// updateCompositingLayersAfterScrolling(), or scrollOffsetChangedViaPlatformWidgetImpl().
@_expose(Cxx)
func scrollViewHandleDeferredScrollUpdate(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient
) {
    if !c.hasDeferredScrollDelta() && !c.hasDeferredScrollOffsets() {
        return
    }

    if c.hasDeferredScrollDelta() {
        let scrollDelta = c.deferredScrollDelta()
        c.updateLayerPositionsAfterScrolling()
        scrollViewScrollContents(&c, c.hasDeferredScrollDelta() ? c.deferredScrollDelta() : scrollDelta)
        c.updateCompositingLayersAfterScrolling()
    } else if c.hasDeferredScrollOffsets() {
        c.scrollOffsetChangedViaPlatformWidgetImpl(c.deferredScrollOldOffset(), c.deferredScrollNewOffset())
    }

    c.clearDeferredScrollDelta()
    c.clearDeferredScrollOffsets()
}

// ScrollView::updateScrollbarSteps(). While `c` is live this calls visibleSize() and the scrollbars' setSteps().
@_expose(Cxx)
func scrollViewUpdateScrollbarSteps(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient
) {
    if c.protectViewScrollbar(.Horizontal) {
        let lineStep = WebCore.ScrollAnimatorScrollPhysicsClient.pixelsPerLineStep(c.visibleSize().width())
        let pageStep = WebCore.ScrollAnimatorScrollPhysicsClient.pageStep(c.visibleSize().width())
        c.protectedScrollbarSetSteps(.Horizontal, lineStep, pageStep)
    }
    c.releaseProtectedScrollbar(.Horizontal)
    if c.protectViewScrollbar(.Vertical) {
        let lineStep = WebCore.ScrollAnimatorScrollPhysicsClient.pixelsPerLineStep(c.visibleSize().height())
        let pageStep = WebCore.ScrollAnimatorScrollPhysicsClient.pageStep(c.visibleSize().height())
        c.protectedScrollbarSetSteps(.Vertical, lineStep, pageStep)
    }
    c.releaseProtectedScrollbar(.Vertical)
}

// MARK: - Scroll position

// The pan scroll icon's side; ScrollView.cpp static_asserts its panIconSizeLength is 16.
private let panIconSizeLength: Int32 = 16

// std::abs(int): abs(INT_MIN) is undefined, and wraps to INT_MIN here.
@inline(always)
private func wrappingAbs(_ value: Int32) -> Int32 {
    value < 0 ? 0 &- value : value
}

// scrollTo()'s delta. A delta outside the int range wraps (IntPoint's int arithmetic, undefined on overflow).
@inline(always)
private func scrollToDelta(_ current: WebCore.IntPoint, _ newPosition: WebCore.IntPoint) -> WebCore.IntSize {
    WebCore.IntSize(newPosition.x() &- current.x(), newPosition.y() &- current.y())
}

// Whether scrollTo() moves the view: its delta is not zero.
@_expose(Cxx)
func scrollViewScrollToMoves(_ current: WebCore.IntPoint, _ newPosition: WebCore.IntPoint) -> Bool {
    !isZero(scrollToDelta(current, newPosition))
}

// ScrollView::scrollTo(), once scrollViewScrollToMoves() has returned true. While `c` is live this calls
// platformSetScrollPosition(), shouldDeferScrollUpdateAfterContentSizeChange(), updateLayerPositionsAfterScrolling(),
// what scrollContents() calls and updateCompositingLayersAfterScrolling().
@_expose(Cxx)
func scrollViewScrollTo(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ newPosition: WebCore.IntPoint
) {
    let scrollDelta = scrollToDelta(c.scrollPositionValue(), newPosition)

    if c.hasPlatformWidget() {
        c.platformSetScrollPosition(newPosition)
        return
    }

    c.setScrollPositionValue(newPosition)

    if c.scrollbarsSuppressed() {
        return
    }

    // We should not attempt to actually modify layer contents if the layout phase
    // is not complete. Instead, defer the scroll event until the layout finishes.
    if c.shouldDeferScrollUpdateAfterContentSizeChange() {
        // The delta's sum with a deferred delta wraps (IntSize's int arithmetic, undefined on overflow).
        if c.hasDeferredScrollDelta() {
            let deferred = c.deferredScrollDelta()
            c.setDeferredScrollDelta(WebCore.IntSize(deferred.width() &+ scrollDelta.width(), deferred.height() &+ scrollDelta.height()))
        } else {
            c.setDeferredScrollDelta(scrollDelta)
        }
        return
    }

    scrollViewCompleteUpdatesAfterScrollTo(&c, scrollDelta)
}

private func scrollViewCompleteUpdatesAfterScrollTo(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ scrollDelta: WebCore.IntSize
) {
    c.updateLayerPositionsAfterScrolling()
    scrollViewScrollContents(&c, scrollDelta)
    c.updateCompositingLayersAfterScrolling()
}

// The view's visible rect in root view coordinates, less any overlay scrollbar drawn without its own layer.
private func scrollViewRectToCopyOnScroll(_ c: inout WebCore.ScrollAnimatorScrollPhysicsClient) -> WebCore.IntRect {
    let visibleSize = c.visibleSize()
    var rect = c.convertToRootView(WebCore.IntRect(0, 0, visibleSize.width(), visibleSize.height()))
    if c.hasOverlayScrollbars() {
        // IntRect's shiftXEdgeBy(), shiftMaxXEdgeBy() and shiftMaxYEdgeBy(); the sums wrap (undefined on overflow).
        if c.hasViewScrollbar(.Vertical) && !c.hasLayerForVerticalScrollbar() {
            let onLeft = c.shouldPlaceVerticalScrollbarOnLeft()
            _ = c.protectViewScrollbar(.Vertical)
            let width = c.protectedScrollbarWidth(.Vertical)
            c.releaseProtectedScrollbar(.Vertical)
            if onLeft {
                rect.setX(rect.x() &+ width)
                rect.setWidth(stdMax(0, rect.width() &- width))
            } else {
                rect.setWidth(stdMax(0, rect.width() &+ (0 &- width)))
            }
        }
        if c.hasViewScrollbar(.Horizontal) && !c.hasLayerForHorizontalScrollbar() {
            _ = c.protectViewScrollbar(.Horizontal)
            let height = c.protectedScrollbarHeight(.Horizontal)
            c.releaseProtectedScrollbar(.Horizontal)
            rect.setHeight(stdMax(0, rect.height() &+ (0 &- height)))
        }
    }
    return rect
}

// ScrollView::scrollContents(). The host window is read again for each call on it, since the calls in between can
// change it. While `c` is live this calls hostWindow(), windowClipRect(), convertToRootView(), the host window's
// invalidateRootView() and invalidateContentsAndRootView(), canBlitOnScroll(), scrollContentsFastPath() or
// scrollContentsSlowPath(), what updateOverhangAreas() calls, and frameRectsChanged().
@_expose(Cxx)
func scrollViewScrollContents(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ scrollDelta: WebCore.IntSize
) {
    if !c.hasHostWindow() {
        return
    }

    // Since scrolling is double buffered, we will be blitting the scroll view's intersection
    // with the clip rect every time to keep it smooth.
    let clipRect = c.windowClipRect()
    let scrollViewRect = scrollViewRectToCopyOnScroll(&c)
    var updateRect = clipRect
    updateRect.intersect(scrollViewRect)

    // Invalidate the root view (not the backing store).
    c.hostWindowInvalidateRootView(updateRect)

    if c.drawPanScrollIcon() {
        // FIXME: the pan icon is broken when accelerated compositing is on, since it will draw under the compositing layers.
        // https://bugs.webkit.org/show_bug.cgi?id=47837
        // We only want to repaint what's necessary. The size wraps (int arithmetic, undefined on overflow).
        let largestDelta = stdMax(wrappingAbs(scrollDelta.width()), wrappingAbs(scrollDelta.height()))
        let dirtySquareSizeLength = 2 &* (panIconSizeLength &+ largestDelta)
        let iconPoint = c.panScrollIconPoint()
        var dirtyRect = WebCore.IntRect(
            iconPoint.x() &- dirtySquareSizeLength / 2,
            iconPoint.y() &- dirtySquareSizeLength / 2,
            dirtySquareSizeLength,
            dirtySquareSizeLength
        )
        dirtyRect.intersect(clipRect)
        c.hostWindowInvalidateContentsAndRootView(dirtyRect)
    }

    if c.canBlitOnScroll() { // The main frame can just blit the WebView window
        // FIXME: Find a way to scroll subframes with this faster path
        let negatedDelta = WebCore.IntSize(0 &- scrollDelta.width(), 0 &- scrollDelta.height())
        if !c.scrollContentsFastPath(negatedDelta, scrollViewRect, clipRect) {
            c.scrollContentsSlowPath(updateRect)
        }
    } else {
        // We need to repaint the entire backing store. Do it now before moving the windowed plugins.
        c.scrollContentsSlowPath(updateRect)
    }

    // Invalidate the overhang areas if they are visible.
    scrollViewUpdateOverhangAreas(&c)

    // This call will move children with native widgets (plugins) and invalidate them as well.
    c.frameRectsChanged()

    // Now blit the backingstore into the window which should be very fast.
    c.hostWindowInvalidateRootView(WebCore.IntRect())
}

// Whether setScrollPosition() goes on: scrolling is not prohibited.
@_expose(Cxx)
func scrollViewSetScrollPositionProceeds(_ prohibitsScrolling: Bool) -> Bool {
    !prohibitsScrolling
}

// ScrollView::setScrollPosition(), once scrollViewSetScrollPositionProceeds() has returned true. While `c` is live this
// calls the animator's cancelAnimations(), stopAsyncAnimatedScroll(), platformSetScrollPosition(),
// adjustScrollPositionWithinRange(), requestScrollToPosition() and what updateScrollbars() calls.
@_expose(Cxx)
func scrollViewSetScrollPosition(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ position: WebCore.IntPoint,
    _ type: WebCore.ScrollType,
    _ clamping: WebCore.ScrollClamping,
    _ animated: WebCore.ScrollIsAnimated,
    _ snapPointSelectionMethod: WebCore.ScrollSnapPointSelectionMethod,
    _ hasOriginalScrollDelta: Bool,
    _ originalScrollDelta: WebCore.FloatSize,
    _ interruptsAnimation: WebCore.ScrollInterruptsAnimation,
    _ animationCurve: WebCore.ScrollAnimationCurve
) {
    if c.scrollAnimationStatus() == .Animating {
        c.animatorCancelAnimations()
        c.stopAsyncAnimatedScroll()
    }

    if c.hasPlatformWidget() {
        c.platformSetScrollPosition(position)
        return
    }

    let newScrollPosition =
        !c.delegatesScrollingToNativeView() && clamping == .Clamped ? c.adjustScrollPositionWithinRange(position) : position
    let currentScrollPosition = c.scrollPosition()
    let scrollPositionChanged = newScrollPosition.x() != currentScrollPosition.x() || newScrollPosition.y() != currentScrollPosition.y()

    if c.currentScrollType() == .User && !scrollPositionChanged {
        return
    }

    let handled = c.requestScrollViewScrollToPosition(
        newScrollPosition,
        type,
        clamping,
        animated,
        snapPointSelectionMethod,
        hasOriginalScrollDelta,
        originalScrollDelta,
        interruptsAnimation,
        animationCurve
    )
    if !handled {
        scrollViewUpdateScrollbars(&c, newScrollPosition)
    }
}

// The position ScrollView::setScrollOffset() scrolls to: the offset, constrained between zero and the maximum offset
// when `clamped`, from the scroll origin. The maximum offset and the position wrap (IntSize's and IntPoint's int
// arithmetic, undefined on overflow).
@_expose(Cxx)
func scrollViewScrollOffsetTarget(
    _ offset: WebCore.IntPoint,
    _ clamped: Bool,
    _ totalContentsSize: WebCore.IntSize,
    _ visibleSize: WebCore.IntSize,
    _ scrollOrigin: WebCore.IntPoint
) -> WebCore.IntPoint {
    var constrainedOffset = offset
    if clamped {
        let maximumX = totalContentsSize.width() &- visibleSize.width()
        let maximumY = totalContentsSize.height() &- visibleSize.height()
        constrainedOffset = WebCore.IntPoint(stdMax(0, stdMin(maximumX, offset.x())), stdMax(0, stdMin(maximumY, offset.y())))
    }
    return WebCore.IntPoint(constrainedOffset.x() &- scrollOrigin.x(), constrainedOffset.y() &- scrollOrigin.y())
}

// ScrollView::scrollOffsetChangedViaPlatformWidget(). While `c` is live this calls
// shouldDeferScrollUpdateAfterContentSizeChange(), scrollOffsetChangedViaPlatformWidgetImpl() and the animator's
// setCurrentPosition().
@_expose(Cxx)
func scrollViewScrollOffsetChangedViaPlatformWidget(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ oldOffset: WebCore.IntPoint,
    _ newOffset: WebCore.IntPoint
) {
    // We should not attempt to actually modify (paint) platform widgets if the layout phase
    // is not complete. Instead, defer the scroll event until the layout finishes.
    if c.shouldDeferScrollUpdateAfterContentSizeChange() {
        // We only care about the most recent scroll position change request
        c.setDeferredScrollOffsets(oldOffset, newOffset)
        return
    }

    c.scrollOffsetChangedViaPlatformWidgetImpl(oldOffset, newOffset)
    let position = c.scrollPosition()
    c.animatorSetCurrentPosition(WebCore.FloatPoint(Float(position.x()), Float(position.y())))
}

// Whether setScrollOrigin() changes the origin.
@_expose(Cxx)
func scrollViewSetScrollOriginChanges(_ currentOrigin: WebCore.IntPoint, _ origin: WebCore.IntPoint) -> Bool {
    currentOrigin.x() != origin.x() || currentOrigin.y() != origin.y()
}

// ScrollView::setScrollOrigin(), once scrollViewSetScrollOriginChanges() has returned true. While `c` is live this
// calls ScrollableArea::setScrollOrigin(), platformSetScrollOrigin() or what updateScrollbars() calls.
@_expose(Cxx)
func scrollViewSetScrollOrigin(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ origin: WebCore.IntPoint,
    _ updatePositionAtAll: Bool,
    _ updatePositionSynchronously: Bool
) {
    c.setAreaScrollOrigin(origin)

    if c.hasPlatformWidget() {
        c.platformSetScrollOrigin(origin, updatePositionAtAll, updatePositionSynchronously)
        return
    }

    // Update if the scroll origin changes, since our position will be different if the content size did not change.
    if updatePositionAtAll && updatePositionSynchronously {
        scrollViewUpdateScrollbars(&c, c.scrollPosition())
    }
}

// ScrollView::adjustExposedContentRectForProgrammaticScroll(). The stored rect is in view space, which only moves with
// the scroll position when it's also contents space. While `c` is live this calls delegatesScrollingToNativeView() and
// scrollPosition(), and writes only the view's delegated scrolling geometry.
@_expose(Cxx)
func scrollViewAdjustExposedContentRect(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient,
    _ newPosition: WebCore.IntPoint
) {
    if !c.hasDelegatedScrollingGeometry() {
        return
    }
    if !c.delegatesScrollingToNativeView() {
        return
    }

    // The delta is an IntSize converted to FloatSize; its difference wraps (undefined on overflow).
    let scrollPosition = c.scrollPosition()
    let delta = ScrollSize(width: Float(newPosition.x() &- scrollPosition.x()), height: Float(newPosition.y() &- scrollPosition.y()))
    if delta.isZero {
        return
    }

    let rect = c.delegatedExposedViewRect()
    c.setDelegatedExposedViewRect(WebCore.FloatRect(rect.x() + delta.width, rect.y() + delta.height, rect.width(), rect.height()))
}

// MARK: - Overhang invalidation

// ScrollView::updateOverhangAreas(). While `c` is live this calls hostWindow(), the scrollbars' occupiedWidth() and
// occupiedHeight(), the geometry getters calculateOverhangAreasForPainting() reads, and the host window's
// invalidateContentsAndRootView().
@_expose(Cxx)
func scrollViewUpdateOverhangAreas(
    _ c: inout WebCore.ScrollAnimatorScrollPhysicsClient
) {
    if !c.hasHostWindow() {
        return
    }

    // scrollbarIntrusion(): the vertical scrollbar's occupied width and the horizontal one's occupied height.
    var scrollbarSpaceWidth: Int32 = 0
    if c.protectViewScrollbar(.Vertical) {
        scrollbarSpaceWidth = c.protectedScrollbarOccupiedWidth(.Vertical)
    }
    c.releaseProtectedScrollbar(.Vertical)
    var scrollbarSpaceHeight: Int32 = 0
    if c.protectViewScrollbar(.Horizontal) {
        scrollbarSpaceHeight = c.protectedScrollbarOccupiedHeight(.Horizontal)
    }
    c.releaseProtectedScrollbar(.Horizontal)

    let scrollOffset = scrollableAreaScrollOffsetFromPosition(&c, c.scrollPosition())
    var horizontalOverhangRect = WebCore.IntRect()
    var verticalOverhangRect = WebCore.IntRect()
    scrollViewCalculateOverhangAreas(
        WebCore.IntSize(scrollbarSpaceWidth, scrollbarSpaceHeight),
        scrollOffset,
        c.frameRect(),
        c.totalContentsSize(),
        c.visibleSize(),
        c.contentsSize().width(),
        &horizontalOverhangRect,
        &verticalOverhangRect
    )
    if !horizontalOverhangRect.isEmpty() {
        c.hostWindowInvalidateContentsAndRootView(horizontalOverhangRect)
    }
    if !verticalOverhangRect.isEmpty() {
        c.hostWindowInvalidateContentsAndRootView(verticalOverhangRect)
    }
}

#endif // USE_SWIFT_SCROLL_VIEW
