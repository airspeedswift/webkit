// Copyright (C) 2008 Alex Mathews <possessedpenguinbob@gmail.com>
// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
// Copyright (C) Research In Motion Limited 2010. All rights reserved.
// Copyright (C) 2012 University of Szeged
// Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
// Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
// Copyright (C) 2005 Eric Seidel <eric@webkit.org>
// Copyright (C) 2010 Igalia, S.L.
// Copyright (C) 2015 Google Inc. All rights reserved.
// Copyright (C) 2015-2026 Apple Inc. All rights reserved.
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
//
// Copyright (C) 2021-2026 Apple Inc. All rights reserved.
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
// THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT

private import Cxx
import WebCore_Private.Core.ColorSpace
import WebCore_Private.Core.FilterEffectView
import WebCore_Private.Core.FilterGraphicsBridge
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.GraphicsContextSwiftBridge
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.RenderingMode
#if USE_CORE_IMAGE
import WebCore_Private.Core.FilterCoreImageSwiftBridge
#endif

// An image of a filter being applied: its source image or an effect's result. The effects that read it and FilterResults
// share it, so the color space an effect transforms its inputs to changes the image for the others too. Its geometry and
// flags, which never change, are copies the engine reads without an access to the image (each access to a class's stored
// variable is checked for exclusivity at run time).
final class FilterImageBox {
    let primitiveSubregion: WebCore.FloatRect
    let imageRect: WebCore.FloatRect
    let absoluteImageRect: WebCore.IntRect
    let isAlphaImage: Bool
    let isValidPremultiplied: Bool
    var image: FilterImageImpl

    init(_ image: consuming FilterImageImpl) {
        primitiveSubregion = image.primitiveSubregion
        imageRect = image.imageRect
        absoluteImageRect = image.absoluteImageRect
        isAlphaImage = image.isAlphaImage
        isValidPremultiplied = image.isValidPremultiplied
        self.image = image
    }
}

// The inputs of an effect, in its order: the first two inline, more (FEMerge's) in an array.
struct FilterEffectInputs: Sequence {
    private(set) var count = 0
    private var first: FilterImageBox?
    private var second: FilterImageBox?
    private var more: [FilterImageBox] = []

    init() {
    }

    init(_ input: FilterImageBox) {
        append(input)
    }

    var isEmpty: Bool { count == 0 }

    mutating func append(_ input: FilterImageBox) {
        switch count {
        case 0:
            first = input
        case 1:
            second = input
        default:
            more.append(input)
        }
        count += 1
    }

    subscript(position: Int) -> FilterImageBox {
        precondition(position >= 0 && position < count)
        switch position {
        case 0:
            guard let first else {
                preconditionFailure()
            }
            return first
        case 1:
            guard let second else {
                preconditionFailure()
            }
            return second
        default:
            return more[position - 2]
        }
    }

    func makeIterator() -> Iterator {
        Iterator(inputs: self)
    }

    struct Iterator: IteratorProtocol {
        let inputs: FilterEffectInputs
        var position = 0

        mutating func next() -> FilterImageBox? {
            guard position < inputs.count else {
                return nil
            }
            defer { position += 1 }
            return inputs[position]
        }
    }
}

// The rects of an effect's inputs that its primitive subregion and image rect are made from: those of the engine's input
// images, or of the one input of a GraphicsContext filter style.
protocol FilterEffectInputRects {
    var count: Int { get }
    func primitiveSubregion(_ position: Int) -> WebCore.FloatRect
    func imageRect(_ position: Int) -> WebCore.FloatRect
}

extension FilterEffectInputs: FilterEffectInputRects {
    func primitiveSubregion(_ position: Int) -> WebCore.FloatRect {
        self[position].primitiveSubregion
    }

    func imageRect(_ position: Int) -> WebCore.FloatRect {
        self[position].imageRect
    }
}

private struct FilterStyleInputRects: FilterEffectInputRects {
    let inputPrimitiveSubregion: WebCore.FloatRect
    let inputImageRect: WebCore.FloatRect

    var count: Int { 1 }

    func primitiveSubregion(_ position: Int) -> WebCore.FloatRect {
        precondition(position == 0)
        return inputPrimitiveSubregion
    }

    func imageRect(_ position: Int) -> WebCore.FloatRect {
        precondition(position == 0)
        return inputImageRect
    }
}

// FilterEffect::createFilterStyle(): the primitive subregion and image rect of an effect a filter applies in GraphicsContext
// mode, to its one input.
@_expose(Cxx)
func filterEffectStyleRects(
    _ effectView: WebCore.FilterEffectView,
    _ renderer: borrowing WebCore.FilterRendererParameters,
    _ inputPrimitiveSubregion: WebCore.FloatRect,
    _ inputImageRect: WebCore.FloatRect,
    _ geometry: WebCore.FilterEffectGeometryValues
) -> WebCore.FilterStyleRects {
    let context = filterApplyContextOf(renderer)
    let inputs = FilterStyleInputRects(inputPrimitiveSubregion: inputPrimitiveSubregion, inputImageRect: inputImageRect)
    let effect = FilterEffectDescription(effectView)
    let type = effect.type
    var rects = WebCore.FilterStyleRects()
    rects.primitiveSubregion = filterEffectPrimitiveSubregion(type, context, inputs, geometry.hasGeometry ? geometry : nil)
    rects.imageRect = imageRectOfEffect(effect, type, context, inputs, rects.primitiveSubregion)
    return rects
}

// An effect of a renderer: the renderer's identifier and the effect's index in it (its function in a CSS filter, its
// effect in an SVG filter).
struct FilterEffectKey: Equatable {
    let renderer: UInt
    let index: UInt32

    init(_ renderer: UInt, _ index: UInt32) {
        self.renderer = renderer
        self.index = index
    }
}

// The state of a FilterResults, which it stores inline: each effect's result, by renderer and then by effect index, which
// later applies of the same filter reuse until an effect changes, and for each image the effects whose results were made
// from it.
@_expose(Cxx)
struct FilterResultsImpl {
    // FIXME: Make this private once a private type links under ThinLTO on Windows ("Invalid weak external").
    // Not for C++: internal, it would be printed in the generated header, which has no FilterImageBox.
    @_expose(!Cxx)
    struct CachedResult {
        let effect: FilterEffectKey
        let image: FilterImageBox
    }

    // An image and an effect whose result was made from it. Keeps the image while it is listed, so that it stays itself.
    // FIXME: Make this private once a private type links under ThinLTO on Windows ("Invalid weak external").
    // Not for C++: internal, it would be printed in the generated header, which has no FilterImageBox.
    @_expose(!Cxx)
    struct ResultReference {
        let image: FilterImageBox
        let effect: FilterEffectKey
    }

    private static let maxAllowedMemoryCost: UInt = 100 * 1024 * 1024

    // Enough for most filters, so that they allocate each array once.
    private static let initialCapacity = 8

    // Searched linearly: computing the memory cost of every cached result for each new one costs more anyway.
    private var results: [CachedResult] = []
    private var references: [ResultReference] = []

    // The C++ destructor of this struct reads its type metadata, whose accessor a Release build (-O -wmo) drops unless
    // Swift code uses it (rdar://179098545).
    @used
    private static let cxxTypeMetadata: Any.Type = Self.self

    @_expose(Cxx)
    init() {
    }

    // FilterResults::clearEffectResult(): forgets the effect's result, and those of the effects whose results were made
    // from it.
    @_expose(Cxx)
    mutating func clearEffectResult(_ renderer: UInt, _ index: UInt32) {
        clearResult(FilterEffectKey(renderer, index))
    }

    fileprivate func result(_ key: FilterEffectKey) -> FilterImageBox? {
        results.first { $0.effect == key }?.image
    }

    fileprivate mutating func setResult(_ key: FilterEffectKey, inputs: FilterEffectInputs, result: FilterImageBox, memoryCost: UInt) {
        guard canCacheResult(memoryCost) else {
            return
        }
        if let position = results.firstIndex(where: { $0.effect == key }) {
            results[position] = CachedResult(effect: key, image: result)
        } else {
            if results.isEmpty {
                results.reserveCapacity(Self.initialCapacity)
            }
            results.append(CachedResult(effect: key, image: result))
        }
        for input in inputs where !references.contains(where: { $0.image === input && $0.effect == key }) {
            if references.isEmpty {
                references.reserveCapacity(Self.initialCapacity)
            }
            references.append(ResultReference(image: input, effect: key))
        }
    }

    private mutating func clearResult(_ key: FilterEffectKey) {
        guard let position = results.firstIndex(where: { $0.effect == key }) else {
            return
        }
        let result = results.remove(at: position).image
        for reference in references where reference.image === result {
            clearResult(reference.effect)
        }
        references.removeAll { $0.image === result }
    }

    // The results' memory cost with a new one's at most 100 MB.
    private func canCacheResult(_ resultMemoryCost: UInt) -> Bool {
        var memoryCost: UInt = 0
        for cached in results {
            memoryCost += cached.image.image.memoryCost()
        }
        let (totalMemoryCost, overflow) = memoryCost.addingReportingOverflow(resultMemoryCost)
        return !overflow && totalMemoryCost <= Self.maxAllowedMemoryCost
    }
}

// The images on an SVG filter's expression stack: the bottom two inline, more in an array.
struct FilterImageStack {
    private(set) var count = 0
    private var bottom: FilterImageBox?
    private var second: FilterImageBox?
    private var more: [FilterImageBox] = []

    mutating func push(_ image: FilterImageBox) {
        switch count {
        case 0:
            bottom = image
        case 1:
            second = image
        default:
            more.append(image)
        }
        count += 1
    }

    // Traps on an empty stack.
    mutating func pop() -> FilterImageBox {
        precondition(count > 0)
        count -= 1
        switch count {
        case 0:
            defer { bottom = nil }
            guard let bottom else {
                preconditionFailure()
            }
            return bottom
        case 1:
            defer { second = nil }
            guard let second else {
                preconditionFailure()
            }
            return second
        default:
            return more.removeLast()
        }
    }
}

// Applies a filter's effects: the allocator of its images, and the FilterResults its effects' results are cached in.
struct FilterEngine {
    private let allocator: WebCore.FilterImageAllocator
    // The FilterResults' state while the engine applies a filter (`withFilterEngine`).
    fileprivate var results = FilterResultsImpl()

    fileprivate init(_ allocator: WebCore.FilterImageAllocator) {
        self.allocator = allocator
    }

    func cachedResult(_ key: FilterEffectKey) -> FilterImageBox? {
        results.result(key)
    }

    // Filter::apply(): the source image, in the filter region, at its rect scaled by the filter scale.
    func sourceImage(
        _ imageBuffer: WebCore.ImageBuffer?,
        _ sourceImageRect: WebCore.FloatRect,
        _ context: borrowing WebCore.FilterApplyContext
    ) -> FilterImageBox? {
        guard let imageBuffer else {
            return nil
        }
        let absoluteSourceImageRect = WebCore.enclosingIntRect(context.scaledByFilterScale(sourceImageRect))
        return FilterImageBox(FilterImageImpl(allocator, context.filterRegion, sourceImageRect, absoluteSourceImageRect, imageBuffer))
    }

    // An image with another's image buffer, rects and color space in another primitive subregion. Nil if the other image
    // has no image buffer and can't make one.
    func image(sharingImageBufferOf other: FilterImageBox, primitiveSubregion: WebCore.FloatRect) -> FilterImageBox? {
        guard let imageBuffer = other.image.imageBuffer().get() else {
            return nil
        }
        return FilterImageBox(
            FilterImageImpl(allocator, primitiveSubregion, other.imageRect, other.absoluteImageRect, imageBuffer)
        )
    }

    // Filter::apply(): the result in sRGB with valid premultiplied pixels, its absolute image rect, and its image buffer.
    // `rendersResult`: the buffer Core Image renders its result into, which GraphicsContext::drawFilteredImageBuffer()
    // draws; otherwise the result's own image buffer, which ImageBuffer::filteredNativeImage() copies.
    func finalResult(
        _ result: FilterImageBox,
        _ context: borrowing WebCore.FilterApplyContext,
        _ rendersResult: Bool,
        _ absoluteImageRect: inout WebCore.IntRect
    ) -> WebCore.RefPtrImageBuffer {
        absoluteImageRect = result.absoluteImageRect
        return finishResult(&result.image, context, rendersResult)
    }

    private func finishResult(
        _ image: inout FilterImageImpl,
        _ context: borrowing WebCore.FilterApplyContext,
        _ rendersResult: Bool
    ) -> WebCore.RefPtrImageBuffer {
        image.correctPremultipliedPixelBuffer()
        if FilterImageImpl.transformsColorSpace {
            image.transformToColorSpace(WebCore.GraphicsContextSwiftBridge.sRGBColorSpace())
        }
        #if USE_CORE_IMAGE
        if rendersResult {
            WebCore.FilterCoreImageSwiftBridge.beginFilterResultRender()
            defer { WebCore.FilterCoreImageSwiftBridge.endFilterResultRender() }
            return renderedFilterResultImageBuffer(
                &image,
                absoluteFilterRegion: context.absoluteEnclosingFilterRegion,
                showDebugOverlay: context.showDebugOverlay
            )
        }
        #endif
        return image.imageBuffer()
    }

    // FilterEffect::apply(): the effect's cached result, or a new image it writes from its inputs. `geometry`: the x, y,
    // width and height of an SVG filter primitive.
    mutating func applyEffect(
        _ effect: FilterEffectDescription,
        _ key: FilterEffectKey,
        _ context: borrowing WebCore.FilterApplyContext,
        _ renderer: borrowing WebCore.FilterRendererParameters,
        _ inputs: FilterEffectInputs,
        _ geometry: WebCore.FilterEffectGeometryValues? = nil
    ) -> FilterImageBox? {
        guard inputs.count == effect.numberOfImageInputs else {
            return nil
        }
        if let result = results.result(key) {
            return result
        }

        let type = effect.type
        let primitiveSubregion = filterEffectPrimitiveSubregion(type, context, inputs, geometry)
        let imageRect = imageRectOfEffect(effect, type, context, inputs, primitiveSubregion)
        let absoluteImageRect = WebCore.enclosingIntRect(context.scaledByFilterScale(imageRect))
        if absoluteImageRect.isEmpty() || WebCore.ImageBuffer.sizeNeedsClamping(WebCore.FloatSize(absoluteImageRect.size())) {
            return nil
        }

        let isAlphaImage = resultIsAlphaImage(effect, inputs)
        // Only the arithmetic composite can make invalid premultiplied pixels.
        var isValidPremultiplied = true
        if case .composite(let composite) = effect.parameters, composite.operation == .FECOMPOSITE_OPERATOR_ARITHMETIC {
            isValidPremultiplied = false
        }
        // FEDisplacementMap's result is a displacement of its first input, in that input's color space.
        let resultColorSpace = type == .FEDisplacementMap ? inputs[0].image.colorSpace : effect.operatingColorSpace
        // A local until the kernel has written it, so that the kernel's access to it is checked when compiled.
        var resultImage = FilterImageImpl(
            allocator,
            primitiveSubregion,
            imageRect,
            absoluteImageRect,
            isAlphaImage,
            isValidPremultiplied,
            renderer.renderingMode,
            consume resultColorSpace
        )

        // 'color-interpolation-filters' doesn't apply to FEDisplacementMap's first input, which stays in its color space.
        if FilterImageImpl.transformsColorSpace {
            let operatingColorSpace = effect.operatingColorSpace
            for position in 0..<inputs.count where type != .FEDisplacementMap || position == 1 {
                inputs[position].image.transformToColorSpace(operatingColorSpace)
            }
        }
        // Only an image that isn't valid premultiplied needs the correction.
        if isValidPremultiplied {
            for input in inputs where !input.isValidPremultiplied {
                input.image.correctPremultipliedPixelBuffer()
            }
        }

        guard applyKernel(effect, context, renderer, inputs, &resultImage) else {
            return nil
        }
        let memoryCost = resultImage.memoryCost()
        let result = FilterImageBox(consume resultImage)
        results.setResult(key, inputs: inputs, result: result, memoryCost: memoryCost)
        return result
    }
}

// FilterEffect::calculatePrimitiveSubregion(): the union of the inputs' subregions (not FETile's), or the filter region
// without inputs, clipped to the effect's geometry.
private func filterEffectPrimitiveSubregion(
    _ type: WebCore.FilterEffectType,
    _ context: borrowing WebCore.FilterApplyContext,
    _ inputs: some FilterEffectInputRects,
    _ geometry: WebCore.FilterEffectGeometryValues?
) -> WebCore.FloatRect {
    var subregion = WebCore.FloatRect()
    if inputs.count > 0 && type != .FETile {
        for position in 0..<inputs.count {
            subregion.unite(inputs.primitiveSubregion(position))
        }
    } else {
        subregion = context.filterRegion
    }
    guard let geometry, geometry.hasGeometry else {
        return subregion
    }
    // FilterEffectGeometry::primitiveSubregion().
    if geometry.hasX { subregion.setX(geometry.boundaries.x()) }
    if geometry.hasY { subregion.setY(geometry.boundaries.y()) }
    if geometry.hasWidth { subregion.setWidth(geometry.boundaries.width()) }
    if geometry.hasHeight { subregion.setHeight(geometry.boundaries.height()) }
    return subregion
}

// FilterEffect::calculateImageRect() of each effect type.
private func imageRectOfEffect(
    _ effect: FilterEffectDescription,
    _ type: WebCore.FilterEffectType,
    _ context: borrowing WebCore.FilterApplyContext,
    _ inputs: some FilterEffectInputRects,
    _ primitiveSubregion: WebCore.FloatRect
) -> WebCore.FloatRect {
    switch effect.parameters {
    case .composite(let parameters):
        return feCompositeImageRect(
            context,
            parameters,
            secondInputImageRect: inputs.imageRect(1),
            unitedInputImageRects: unitedImageRects(inputs),
            primitiveSubregion
        )
    case .dropShadow(let parameters, _):
        return feDropShadowImageRect(context, parameters, inputs.imageRect(0), primitiveSubregion)
    case .gaussianBlur(let parameters):
        return feGaussianBlurImageRect(context, parameters, inputs.imageRect(0), primitiveSubregion)
    case .morphology(let parameters):
        return feMorphologyImageRect(context, parameters, inputs.imageRect(0), primitiveSubregion)
    case .offset(let parameters):
        return feOffsetImageRect(context, parameters, inputs.imageRect(0), primitiveSubregion)
    case .convolveMatrix, .lighting, .displacementMap, .flood, .image, .tile, .turbulence:
        return context.maxEffectRect(primitiveSubregion)
    default:
        return filterEffectImageRect(
            context,
            unitedInputImageRects: inputs.count == 0 ? nil : unitedImageRects(inputs),
            primitiveSubregion
        )
    }
}

private func unitedImageRects(_ inputs: some FilterEffectInputRects) -> WebCore.FloatRect {
    var united = WebCore.FloatRect()
    for position in 0..<inputs.count {
        united.unite(inputs.imageRect(position))
    }
    return united
}

// Runs `body` with an engine that holds the FilterResults' state, moved in and back out so that the engine's arrays stay
// uniquely referenced.
func withFilterEngine<Result>(
    _ allocator: WebCore.FilterImageAllocator,
    _ results: inout FilterResultsImpl,
    _ body: (inout FilterEngine) -> Result
) -> Result {
    var engine = FilterEngine(allocator)
    swap(&engine.results, &results)
    defer { swap(&engine.results, &results) }
    return body(&engine)
}

// FilterEffect::takeImageInputs(): the top `count` images, the top one first, or none if the stack has fewer.
func takeImageInputs(_ count: Int, _ stack: inout FilterImageStack) -> FilterEffectInputs {
    var inputs = FilterEffectInputs()
    guard stack.count >= count else {
        return inputs
    }
    for _ in 0..<count {
        inputs.append(stack.pop())
    }
    return inputs
}

extension FilterEngine {
    // FilterEffect::resultIsAlphaImage() of each effect type.
    private func resultIsAlphaImage(
        _ effect: FilterEffectDescription,
        _ inputs: FilterEffectInputs
    ) -> Bool {
        switch effect.parameters {
        case .colorMatrix(let parameters):
            return parameters.type == .FECOLORMATRIX_TYPE_LUMINANCETOALPHA
        case .gaussianBlur, .morphology, .offset, .tile:
            return inputs[0].isAlphaImage
        default:
            return false
        }
    }
}

extension FilterEngine {
    // FilterEffect::applyEffect() of each effect type: writes the result in the filter's rendering mode (Accelerated if
    // it has it, otherwise Software). The two-input effects take another entry for one image twice: Swift takes the
    // inputs inout, which one image can't be twice.
    private func applyKernel(
        _ effect: FilterEffectDescription,
        _ context: borrowing WebCore.FilterApplyContext,
        _ renderer: borrowing WebCore.FilterRendererParameters,
        _ inputs: FilterEffectInputs,
        _ result: inout FilterImageImpl
    ) -> Bool {
        switch effect.parameters {
        case .sourceGraphic:
            if context.accelerated {
                #if USE_CORE_IMAGE
                return sourceGraphicApplyCoreImage(context, &inputs[0].image, &result)
                #elseif USE_SKIA
                // Skia draws the source graphic as the software path does.
                return sourceGraphicApplySoftware(&inputs[0].image, &result)
                #else
                return false
                #endif
            }
            return sourceGraphicApplySoftware(&inputs[0].image, &result)

        case .sourceAlpha:
            if context.accelerated {
                #if USE_CORE_IMAGE
                return sourceAlphaApplyCoreImage(inputs[0].image, &result)
                #else
                return false
                #endif
            }
            return sourceAlphaApplySoftware(&inputs[0].image, &result)

        case .blend(let parameters):
            if context.accelerated {
                #if USE_CORE_IMAGE
                return feBlendApplyCoreImage(parameters, inputs[0].image, inputs[1].image, &result)
                #else
                return false
                #endif
            }
            if inputs[0] === inputs[1] {
                return feBlendApplySoftwareWithSameInputs(parameters, &inputs[0].image, &result)
            }
            return feBlendApplySoftware(parameters, &inputs[0].image, &inputs[1].image, &result)

        case .colorMatrix(let parameters):
            #if USE_SKIA
            return feColorMatrixApplySkia(parameters, &inputs[0].image, &result)
            #else
            if context.accelerated {
                #if USE_CORE_IMAGE
                return feColorMatrixApplyCoreImage(context, parameters, inputs[0].image, &result)
                #else
                return false
                #endif
            }
            return feColorMatrixApplySoftware(parameters, &inputs[0].image, &result)
            #endif

        case .componentTransfer(let parameters):
            #if USE_SKIA
            return feComponentTransferApplySkia(parameters, &inputs[0].image, &result)
            #else
            if context.accelerated {
                #if USE_CORE_IMAGE
                return feComponentTransferApplyCoreImage(context, parameters, &inputs[0].image, &result)
                #else
                return false
                #endif
            }
            return feComponentTransferApplySoftware(parameters, &inputs[0].image, &result)
            #endif

        case .composite(let parameters):
            if context.accelerated {
                #if USE_CORE_IMAGE
                return feCompositeApplyCoreImage(context, parameters, inputs[0].image, inputs[1].image, &result)
                #else
                return false
                #endif
            }
            let sameInputs = inputs[0] === inputs[1]
            if parameters.operation == .FECOMPOSITE_OPERATOR_ARITHMETIC {
                if sameInputs {
                    return feCompositeApplySoftwareArithmeticWithSameInputs(
                        parameters,
                        effect.operatingColorSpace,
                        &inputs[0].image,
                        &result
                    )
                }
                return feCompositeApplySoftwareArithmetic(
                    parameters,
                    effect.operatingColorSpace,
                    &inputs[0].image,
                    &inputs[1].image,
                    &result
                )
            }
            if sameInputs {
                return feCompositeApplySoftwareWithSameInputs(parameters, &inputs[0].image, &result)
            }
            return feCompositeApplySoftware(parameters, &inputs[0].image, &inputs[1].image, &result)

        case .convolveMatrix(let parameters):
            if context.accelerated {
                #if USE_CORE_IMAGE
                return feConvolveMatrixApplyCoreImage(context, parameters, inputs[0].image, &result)
                #else
                return false
                #endif
            }
            return feConvolveMatrixApplySoftware(parameters, effect.operatingColorSpace, &inputs[0].image, &result)

        case .lighting(let parameters, let unresolvedLightSource, let lightingColor):
            let lightSource = resolvedLightSourceParameters(unresolvedLightSource, renderer)
            if context.accelerated {
                #if USE_CORE_IMAGE
                return feLightingApplyCoreImage(context, parameters, lightSource, lightingColor, inputs[0].image, &result)
                #else
                return false
                #endif
            }
            return feLightingApplySoftware(context, parameters, lightSource, lightingColor, &inputs[0].image, &result)

        case .displacementMap(let parameters):
            if context.accelerated {
                #if USE_CORE_IMAGE
                return feDisplacementMapApplyCoreImage(context, parameters, inputs[0].image, inputs[1].image, &result)
                #else
                return false
                #endif
            }
            if inputs[0] === inputs[1] {
                return feDisplacementMapApplySoftwareWithSameInputs(context, parameters, &inputs[0].image, &result)
            }
            return feDisplacementMapApplySoftware(context, parameters, &inputs[0].image, &inputs[1].image, &result)

        case .dropShadow(let parameters, let shadowColor):
            #if USE_SKIA
            _ = shadowColor
            return feDropShadowApplySkia(context, parameters, &inputs[0].image, &result)
            #else
            if context.accelerated {
                #if USE_CORE_IMAGE
                return feDropShadowApplyCoreImage(
                    context,
                    parameters,
                    shadowColor,
                    effect.operatingColorSpaceIsSRGB,
                    inputs[0].image,
                    &result
                )
                #else
                _ = shadowColor
                return false
                #endif
            }
            return feDropShadowApplySoftware(context, parameters, &inputs[0].image, &result)
            #endif

        case .flood(let parameters, let floodColor):
            if context.accelerated {
                #if USE_CORE_IMAGE
                return feFloodApplyCoreImage(context, floodColor, effect.operatingColorSpaceIsSRGB, &result)
                #else
                _ = floodColor
                return false
                #endif
            }
            return feFloodApplySoftware(parameters, &result)

        case .gaussianBlur(let parameters):
            if context.accelerated {
                #if USE_CORE_IMAGE
                return feGaussianBlurApplyCoreImage(context, parameters, inputs[0].image, &result)
                #elseif USE_SKIA
                return feGaussianBlurApplySkia(context, parameters, &inputs[0].image, &result)
                #else
                return false
                #endif
            }
            #if USE_SKIA
            if parameters.edgeMode == .None {
                return feGaussianBlurApplySkia(context, parameters, &inputs[0].image, &result)
            }
            #endif
            return feGaussianBlurApplySoftware(context, parameters, &inputs[0].image, &result)

        case .image(let parameters, let source):
            if context.accelerated {
                #if USE_CORE_IMAGE
                return feImageApplyCoreImage(context, parameters, source, &result)
                #else
                return false
                #endif
            }
            return feImageApplySoftware(context, parameters, source, &result)

        case .merge:
            // The inputs are merged one by one, each over those before it.
            if context.accelerated {
                #if USE_CORE_IMAGE
                for input in inputs {
                    feMergeAddCoreImageInput(input.image, &result)
                }
                return feMergeFinishCoreImage(context, !inputs.isEmpty, &result)
                #else
                return false
                #endif
            }
            guard feMergeBeginSoftware(&result) else {
                return false
            }
            for input in inputs {
                feMergeAddSoftwareInput(&input.image, &result)
            }
            return true

        case .morphology(let parameters):
            if context.accelerated {
                #if USE_CORE_IMAGE
                return feMorphologyApplyCoreImage(context, parameters, inputs[0].image, &result)
                #else
                return false
                #endif
            }
            return feMorphologyApplySoftware(context, parameters, effect.operatingColorSpace, &inputs[0].image, &result)

        case .offset(let parameters):
            if context.accelerated {
                #if USE_CORE_IMAGE
                return feOffsetApplyCoreImage(context, parameters, inputs[0].image, &result)
                #else
                return false
                #endif
            }
            return feOffsetApplySoftware(context, parameters, &inputs[0].image, &result)

        case .tile:
            if context.accelerated {
                #if USE_CORE_IMAGE
                return feTileApplyCoreImage(context, inputs[0].image, &result)
                #else
                return false
                #endif
            }
            return feTileApplySoftware(context, &inputs[0].image, &result)

        case .turbulence(let parameters):
            if context.accelerated {
                #if USE_CORE_IMAGE
                return feTurbulenceApplyCoreImage(context, parameters, &result)
                #else
                return false
                #endif
            }
            return feTurbulenceApplySoftware(context, parameters, &result)
        }
    }
}

#endif // ENABLE_WEBCORE_SWIFT
