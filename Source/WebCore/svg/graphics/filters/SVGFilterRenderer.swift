// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
// Copyright (C) Research In Motion Limited 2010. All rights reserved.
// Copyright (C) 2013 Google Inc. All rights reserved.
// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
//
// You should have received a copy of the GNU Library General Public License
// along with this library; see the file COPYING.LIB.  If not, write to
// the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
// Boston, MA 02110-1301, USA.

#if ENABLE_WEBCORE_SWIFT

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import ucrt
#endif
// The safe Span overload Swift synthesizes for FilterOutsetsAtLevels.span() calls Cxx's Span(_unsafeCxxSpan:). Xcode
// builds don't find it unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.FilterEffectView
import WebCore_Private.Core.FilterGraphicsBridge
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatPoint
import WebCore_Private.Core.FloatPoint3D
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.FloatSize
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.SVGFilterRendererView

// SVGFilterRenderer::calculateResolvedSize(): a size given in primitive units, in user space. objectBoundingBox units
// are fractions of the target's bounding box.
@_expose(Cxx)
func svgFilterResolvedSize(
    _ size: WebCore.FloatSize,
    _ targetBoundingBox: WebCore.FloatRect,
    _ primitiveUnitsAreObjectBoundingBox: Bool
) -> WebCore.FloatSize {
    guard primitiveUnitsAreObjectBoundingBox else {
        return size
    }
    return WebCore.FloatSize(size.width() * targetBoundingBox.width(), size.height() * targetBoundingBox.height())
}

// SVGFilterRenderer's resolution of a light source position given in primitive units, in user space.
func svgFilterResolvedPoint3D(
    _ point: WebCore.FloatPoint3D,
    _ referenceBox: WebCore.FloatRect,
    _ primitiveUnitsAreObjectBoundingBox: Bool
) -> WebCore.FloatPoint3D {
    guard primitiveUnitsAreObjectBoundingBox else {
        return point
    }
    let x = referenceBox.x() + point.x() * referenceBox.width()
    let y = referenceBox.y() + point.y() * referenceBox.height()

    // https://www.w3.org/TR/SVG/filters.html#fePointLightZAttribute and https://www.w3.org/TR/SVG/coords.html#Units_viewport_percentage
    let minCorner = referenceBox.minXMinYCorner()
    let maxCorner = referenceBox.maxXMaxYCorner()
    let diagonal = hypotf(minCorner.x() - maxCorner.x(), minCorner.y() - maxCorner.y())
    let squareRootOfTwo: Float = 1.41421356237309504880
    let z = point.z() * diagonal / squareRootOfTwo

    return WebCore.FloatPoint3D(x, y, z)
}

// SVGFilterRenderer::calculateOutsets(): the outsets of an SVG filter, from those of its primitives in the order the
// primitive graph visits them (depth first from the last primitive). A primitive's outsets grow by the largest outsets
// of its inputs.
@_expose(Cxx)
func svgFilterOutsets(_ primitives: borrowing WebCore.FilterOutsetsAtLevels) -> WebCore.FilterOutsets {
    let primitiveOutsets: Span<WebCore.FilterOutsetsAtLevel> = primitives.span()
    var outsetsStack = ContiguousArray<WebCore.FilterOutsetsAtLevel>()
    outsetsStack.reserveCapacity(primitiveOutsets.count)

    for index in primitiveOutsets.indices {
        let primitive = primitiveOutsets[index]
        let lastLevel = outsetsStack.last?.level ?? 0

        // Expand the last outsets of this level with the maximum of the outsets of its children.
        if primitive.level < lastLevel {
            let childrenOutsets = takeLastLevelOutsets(&outsetsStack)
            expandLastOutsets(&outsetsStack, by: childrenOutsets)
        }

        outsetsStack.append(primitive)
    }

    // Calculate the whole filter outsets by going back to the last primitive of the graph.
    while outsetsStack.count > 1 {
        let childrenOutsets = takeLastLevelOutsets(&outsetsStack)
        expandLastOutsets(&outsetsStack, by: childrenOutsets)
    }

    return outsetsStack.removeLast().outsets
}

// Removes the outsets of the last level and returns their maximum. Like the C++ Vector::last(), indexing traps if no
// entry of a lower level remains; the depth first visit always leaves the last primitive, at level 0, first.
private func takeLastLevelOutsets(_ outsetsStack: inout ContiguousArray<WebCore.FilterOutsetsAtLevel>) -> WebCore.FilterOutsets {
    var lastLevelOutsets = WebCore.FilterOutsets()
    let lastLevel = outsetsStack[outsetsStack.count - 1].level
    while outsetsStack[outsetsStack.count - 1].level == lastLevel {
        let outsets = outsetsStack.removeLast().outsets
        lastLevelOutsets = WebCore.FilterOutsets(
            top: max(lastLevelOutsets.top, outsets.top),
            right: max(lastLevelOutsets.right, outsets.right),
            bottom: max(lastLevelOutsets.bottom, outsets.bottom),
            left: max(lastLevelOutsets.left, outsets.left)
        )
    }
    return lastLevelOutsets
}

// Adds outsets to those of the last entry, wrapping on overflow.
private func expandLastOutsets(_ outsetsStack: inout ContiguousArray<WebCore.FilterOutsetsAtLevel>, by outsets: WebCore.FilterOutsets) {
    let last = outsetsStack.count - 1
    let lastOutsets = outsetsStack[last].outsets
    outsetsStack[last].outsets = WebCore.FilterOutsets(
        top: lastOutsets.top &+ outsets.top,
        right: lastOutsets.right &+ outsets.right,
        bottom: lastOutsets.bottom &+ outsets.bottom,
        left: lastOutsets.left &+ outsets.left
    )
}

// SVGFilterRenderer::apply().
@_expose(Cxx)
func svgFilterApply(
    _ filter: WebCore.SVGFilterRendererView,
    _ sourceImage: WebCore.ImageBuffer?,
    _ sourceImageRect: WebCore.FloatRect,
    _ allocator: WebCore.FilterImageAllocator,
    _ results: inout FilterResultsImpl,
    _ rendersResult: Bool,
    _ absoluteImageRect: inout WebCore.IntRect
) -> WebCore.RefPtrImageBuffer {
    svgFilterResult(SVGFilterDescription(filter), sourceImage, sourceImageRect, allocator, &results, rendersResult, &absoluteImageRect)
}

// SVGFilterRenderer::apply() of a described SVG filter: its result, with its absolute image rect, or nil if it fails.
// `rendersResult`: as FilterEngine.finalResult() takes it.
@_spi(WebKitGPU) public func applySVGFilter(
    _ filter: borrowing SVGFilterDescription,
    _ sourceImage: WebCore.ImageBuffer?,
    _ sourceImageRect: WebCore.FloatRect,
    _ allocator: WebCore.FilterImageAllocator,
    _ results: inout FilterResultsState,
    _ rendersResult: Bool,
    _ absoluteImageRect: inout WebCore.IntRect
) -> WebCore.ImageBuffer? {
    svgFilterResult(filter, sourceImage, sourceImageRect, allocator, &results.impl, rendersResult, &absoluteImageRect).get()
}

private func svgFilterResult(
    _ filter: borrowing SVGFilterDescription,
    _ sourceImage: WebCore.ImageBuffer?,
    _ sourceImageRect: WebCore.FloatRect,
    _ allocator: WebCore.FilterImageAllocator,
    _ results: inout FilterResultsImpl,
    _ rendersResult: Bool,
    _ absoluteImageRect: inout WebCore.IntRect
) -> WebCore.RefPtrImageBuffer {
    let context = filterApplyContextOf(filter.renderer)
    return withFilterEngine(allocator, &results) { engine in
        var source = SVGFilterSourceImage(sourceImage, sourceImageRect)
        guard let result = engine.applySVGFilter(filter, context, &source) else {
            return WebCore.RefPtrImageBuffer()
        }
        return engine.finalResult(result, context, rendersResult, &absoluteImageRect)
    }
}

extension FilterEngine {
    // SVGFilterRenderer::apply(const Filter&, FilterImage&, FilterResults&): an SVG filter a CSS filter references, applied
    // to the result of the function before it.
    mutating func applyReferencedSVGFilter(_ filter: borrowing SVGFilterDescription, _ sourceImage: FilterImageBox) -> FilterImageBox? {
        let context = filterApplyContextOf(filter.renderer)
        if WebCore.areEssentiallyEqual(sourceImage.primitiveSubregion, context.filterRegion) {
            var source = SVGFilterSourceImage(sourceImage)
            return applySVGFilter(filter, context, &source)
        }
        // Per the SVG spec, standard inputs (SourceGraphic, SourceAlpha, etc.) use the filter region as their default
        // primitive subregion. The source image may come from an outer CSSFilterRenderer whose filter region is the
        // element's bounding box, which is smaller than this SVG filter's region. Adjust the primitive subregion to match
        // the SVG filter region so that downstream effects (e.g., feOffset) are not incorrectly clipped.
        guard let input = image(sharingImageBufferOf: sourceImage, primitiveSubregion: context.filterRegion) else {
            return nil
        }
        var source = SVGFilterSourceImage(input)
        return applySVGFilter(filter, context, &source)
    }

    // The expression: a stack program over the effects. Each term pushes its effect's result, made from the inputs it
    // takes off the stack. Fails for a term whose effect the filter doesn't have.
    mutating func applySVGFilter(
        _ filter: borrowing SVGFilterDescription,
        _ context: borrowing WebCore.FilterApplyContext,
        _ sourceImage: inout SVGFilterSourceImage
    ) -> FilterImageBox? {
        var stack = FilterImageStack()
        for term in filter.terms {
            let index = term.effectIndex
            guard Int(index) < filter.effects.count else {
                return nil
            }
            let effect = filter.effects[Int(index)]
            let key = FilterEffectKey(filter.identifier, index)

            if effect.type == .SourceGraphic {
                if let result = cachedResult(key) {
                    stack.push(result)
                    continue
                }
                guard let image = boxedSourceImage(&sourceImage, context) else {
                    return nil
                }
                // Add sourceImage as an input to the SourceGraphic.
                stack.push(image)
            }

            // Need to remove the inputs here in case the effect already has a result.
            let inputs = takeImageInputs(effect.numberOfImageInputs, &stack)
            guard let result = applyEffect(effect, key, context, filter.renderer, inputs, term.geometry) else {
                return nil
            }
            stack.push(result)
        }
        assert(stack.count == 1)
        return stack.pop()
    }

    private func boxedSourceImage(
        _ source: inout SVGFilterSourceImage,
        _ context: borrowing WebCore.FilterApplyContext
    ) -> FilterImageBox? {
        if source.image == nil {
            source.image = sourceImage(source.imageBuffer, source.imageBufferRect, context)
        }
        return source.image
    }
}

// An SVG filter's source image: the result of a CSS filter's previous function, or the image buffer being filtered,
// which the engine boxes when the filter's SourceGraphic first needs it.
struct SVGFilterSourceImage {
    fileprivate var image: FilterImageBox?
    fileprivate let imageBuffer: WebCore.ImageBuffer?
    fileprivate let imageBufferRect: WebCore.FloatRect

    init(_ image: FilterImageBox) {
        self.image = image
        imageBuffer = nil
        imageBufferRect = WebCore.FloatRect()
    }

    init(_ imageBuffer: WebCore.ImageBuffer?, _ imageBufferRect: WebCore.FloatRect) {
        image = nil
        self.imageBuffer = imageBuffer
        self.imageBufferRect = imageBufferRect
    }
}

#endif // ENABLE_WEBCORE_SWIFT
