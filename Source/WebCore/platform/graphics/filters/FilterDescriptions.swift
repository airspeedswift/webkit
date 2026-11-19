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
//
// Copyright (C) 2011-2026 Apple Inc. All rights reserved.
// Copyright (C) 2013 Google Inc. All rights reserved.
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

// Span(_unsafeCxxSpan:). Xcode builds don't find it unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.ColorSpace
import WebCore_Private.Core.CSSFilterRendererView
import WebCore_Private.Core.FEImageParameters
import WebCore_Private.Core.FilterEffectView
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.FloatSize
import WebCore_Private.Core.GraphicsContextSwiftBridge
import WebCore_Private.Core.ImageBuffer
import WebCore_Private.Core.IntPoint
import WebCore_Private.Core.IntSize
import WebCore_Private.Core.NativeImage
import WebCore_Private.Core.SVGFilterRendererView
#if USE_CG
public import CoreGraphics
public import WebCore_Private.Core.CGRendererSwiftBridge
#endif

// The descriptions of filters that WebCore's Swift filter engine applies: Swift values, which the GPU process makes of
// the filters it decodes in Swift, and C++ makes of its filters for each apply (the `init(_:)`s of the views).

// FIXME: let, not var, for Windows thin LTO: a public var's _modify coroutine leaves its continuation prototype an
// undefined dllimport at the link.

// FEColorMatrix's parameters.
@_spi(WebKitGPU) public struct FEColorMatrixValues {
    public let type: WebCore.ColorMatrixType
    public let values: [Float]

    public init(type: WebCore.ColorMatrixType, values: [Float]) {
        self.type = type
        self.values = values
    }

    init(_ view: WebCore.FEColorMatrixParametersView) {
        type = view.type()
        values = floatArray(view.valueSpan())
    }
}

// A ComponentTransferFunction.
@_spi(WebKitGPU) public struct ComponentTransferFunctionValues {
    public let type: WebCore.ComponentTransferType
    public let slope: Float
    public let intercept: Float
    public let amplitude: Float
    public let exponent: Float
    public let offset: Float
    public let tableValues: [Float]

    public init(
        type: WebCore.ComponentTransferType,
        slope: Float,
        intercept: Float,
        amplitude: Float,
        exponent: Float,
        offset: Float,
        tableValues: [Float]
    ) {
        self.type = type
        self.slope = slope
        self.intercept = intercept
        self.amplitude = amplitude
        self.exponent = exponent
        self.offset = offset
        self.tableValues = tableValues
    }

    init(_ view: WebCore.ComponentTransferFunctionView) {
        type = view.type()
        slope = view.slope()
        intercept = view.intercept()
        amplitude = view.amplitude()
        exponent = view.exponent()
        offset = view.offset()
        tableValues = floatArray(view.tableValuesSpan())
    }
}

// FEComponentTransfer's parameters.
@_spi(WebKitGPU) public struct FEComponentTransferValues {
    public let red: ComponentTransferFunctionValues
    public let green: ComponentTransferFunctionValues
    public let blue: ComponentTransferFunctionValues
    public let alpha: ComponentTransferFunctionValues

    public init(
        red: ComponentTransferFunctionValues,
        green: ComponentTransferFunctionValues,
        blue: ComponentTransferFunctionValues,
        alpha: ComponentTransferFunctionValues
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ view: WebCore.FEComponentTransferParametersView) {
        red = ComponentTransferFunctionValues(view.red())
        green = ComponentTransferFunctionValues(view.green())
        blue = ComponentTransferFunctionValues(view.blue())
        alpha = ComponentTransferFunctionValues(view.alpha())
    }
}

// FEConvolveMatrix's parameters that its appliers read.
@_spi(WebKitGPU) public struct FEConvolveMatrixValues {
    public let kernelSize: WebCore.IntSize
    public let divisor: Float
    public let bias: Float
    public let targetOffset: WebCore.IntPoint
    public let edgeMode: WebCore.EdgeModeType
    public let preserveAlpha: Bool
    public let kernel: [Float]

    public init(
        kernelSize: WebCore.IntSize,
        divisor: Float,
        bias: Float,
        targetOffset: WebCore.IntPoint,
        edgeMode: WebCore.EdgeModeType,
        preserveAlpha: Bool,
        kernel: [Float]
    ) {
        self.kernelSize = kernelSize
        self.divisor = divisor
        self.bias = bias
        self.targetOffset = targetOffset
        self.edgeMode = edgeMode
        self.preserveAlpha = preserveAlpha
        self.kernel = kernel
    }

    // Whether the kernel has a value for each of its positive width by height, with the target inside it, as the IPC decoder
    // and the DOM require.
    var hasValidKernel: Bool {
        let width = Int(kernelSize.width())
        let height = Int(kernelSize.height())
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        return width > 0 && height > 0 && !overflow && count == kernel.count && (0..<width).contains(Int(targetOffset.x()))
            && (0..<height).contains(Int(targetOffset.y()))
    }

    init(_ view: WebCore.FEConvolveMatrixParametersView) {
        kernelSize = view.kernelSize()
        divisor = view.divisor()
        bias = view.bias()
        targetOffset = view.targetOffset()
        edgeMode = view.edgeMode()
        preserveAlpha = view.preserveAlpha()
        kernel = floatArray(view.kernelValues())
    }
}

// FEImage's source image (SourceImage): a native image, an image buffer, or neither (an image the GPU process didn't
// resolve).
@_spi(WebKitGPU) public enum FilterImageSource {
    case nativeImage(WebCore.NativeImage)
    case imageBuffer(WebCore.ImageBuffer)
    case none
}

// The parameters of an effect, by its type. The colors are in the effect's operating color space, with their opacities.
@_spi(WebKitGPU) public enum FilterEffectParameters {
    case sourceGraphic
    case sourceAlpha
    case blend(WebCore.FEBlendParameters)
    case colorMatrix(FEColorMatrixValues)
    case componentTransfer(FEComponentTransferValues)
    case composite(WebCore.FECompositeParameters)
    case convolveMatrix(FEConvolveMatrixValues)
    // FEDiffuseLighting or FESpecularLighting, by the parameters' type. The light source's positions are in primitive units.
    case lighting(WebCore.FELightingParameters, lightSource: WebCore.LightSourceParameters, lightingColor: WebCore.FilterColorComponents)
    case displacementMap(WebCore.FEDisplacementMapParameters)
    case dropShadow(WebCore.FEDropShadowParameters, shadowColor: WebCore.FilterColorComponents)
    case flood(WebCore.FEFloodParameters, floodColor: WebCore.FilterColorComponents)
    case gaussianBlur(WebCore.FEGaussianBlurParameters)
    case image(WebCore.FEImageParameters, FilterImageSource)
    case merge(inputCount: UInt32)
    case morphology(WebCore.FEMorphologyParameters)
    case offset(WebCore.FEOffsetParameters)
    case tile
    case turbulence(WebCore.FETurbulenceParameters)
}

// A filter effect (FilterEffect): its parameters and its operating color space.
@_spi(WebKitGPU) public struct FilterEffectDescription {
    public let parameters: FilterEffectParameters
    public let operatingColorSpace: WebCore.ColorSpace
    public let operatingColorSpaceIsSRGB: Bool

    public init(_ parameters: FilterEffectParameters, operatingColorSpace: WebCore.ColorSpace, operatingColorSpaceIsSRGB: Bool) {
        self.parameters = parameters
        self.operatingColorSpace = operatingColorSpace
        self.operatingColorSpaceIsSRGB = operatingColorSpaceIsSRGB
    }

    init(_ view: WebCore.FilterEffectView) {
        let parameters: FilterEffectParameters
        switch view.type() {
        case .SourceGraphic:
            parameters = .sourceGraphic
        case .SourceAlpha:
            parameters = .sourceAlpha
        case .FEBlend:
            parameters = .blend(view.blendParameters())
        case .FEColorMatrix:
            parameters = .colorMatrix(FEColorMatrixValues(view.colorMatrixParameters()))
        case .FEComponentTransfer:
            parameters = .componentTransfer(FEComponentTransferValues(view.componentTransferParameters()))
        case .FEComposite:
            parameters = .composite(view.compositeParameters())
        case .FEConvolveMatrix:
            parameters = .convolveMatrix(FEConvolveMatrixValues(view.convolveMatrixParameters()))
        case .FEDiffuseLighting, .FESpecularLighting:
            parameters = .lighting(view.lightingParameters(), lightSource: view.lightSource(), lightingColor: view.lightingColor())
        case .FEDisplacementMap:
            parameters = .displacementMap(view.displacementMapParameters())
        case .FEDropShadow:
            parameters = .dropShadow(view.dropShadowParameters(), shadowColor: view.dropShadowColor())
        case .FEFlood:
            parameters = .flood(view.floodParameters(), floodColor: view.floodColor())
        case .FEGaussianBlur:
            parameters = .gaussianBlur(view.gaussianBlurParameters())
        case .FEImage:
            let source: FilterImageSource
            if let nativeImage = view.imageSourceNativeImage().get() {
                source = .nativeImage(nativeImage)
            } else if let imageBuffer = view.imageSourceImageBuffer().get() {
                source = .imageBuffer(imageBuffer)
            } else {
                source = .none
            }
            parameters = .image(view.imageParameters(), source)
        case .FEMerge:
            parameters = .merge(inputCount: view.numberOfImageInputs())
        case .FEMorphology:
            parameters = .morphology(view.morphologyParameters())
        case .FEOffset:
            parameters = .offset(view.offsetParameters())
        case .FETile:
            parameters = .tile
        case .FETurbulence:
            parameters = .turbulence(view.turbulenceParameters())
        @unknown default:
            preconditionFailure()
        }
        self.init(parameters, operatingColorSpace: view.operatingColorSpace(), operatingColorSpaceIsSRGB: view.operatingColorSpaceIsSRGB())
    }

    var type: WebCore.FilterEffectType {
        switch parameters {
        case .sourceGraphic:
            return .SourceGraphic
        case .sourceAlpha:
            return .SourceAlpha
        case .blend:
            return .FEBlend
        case .colorMatrix:
            return .FEColorMatrix
        case .componentTransfer:
            return .FEComponentTransfer
        case .composite:
            return .FEComposite
        case .convolveMatrix:
            return .FEConvolveMatrix
        case .lighting(let lighting, _, _):
            return lighting.type == .Specular ? .FESpecularLighting : .FEDiffuseLighting
        case .displacementMap:
            return .FEDisplacementMap
        case .dropShadow:
            return .FEDropShadow
        case .flood:
            return .FEFlood
        case .gaussianBlur:
            return .FEGaussianBlur
        case .image:
            return .FEImage
        case .merge:
            return .FEMerge
        case .morphology:
            return .FEMorphology
        case .offset:
            return .FEOffset
        case .tile:
            return .FETile
        case .turbulence:
            return .FETurbulence
        }
    }

    // FilterEffect::numberOfImageInputs(): SourceGraphic's input is the source image.
    var numberOfImageInputs: Int {
        switch parameters {
        case .blend, .composite, .displacementMap:
            return 2
        case .flood, .image, .turbulence:
            return 0
        case .merge(let inputCount):
            return Int(inputCount)
        default:
            return 1
        }
    }
}

// The results of the effects of the filters that the GPU process applies with it, which it keeps in Swift: a FilterResults'
// state. FilterResultsImpl itself stays internal, so that its layout is the one FilterResults stores inline.
@_spi(WebKitGPU) public struct FilterResultsState {
    var impl = FilterResultsImpl()

    public init() {
    }

    // FilterResults::clearEffectResult().
    public mutating func clearEffectResult(_ renderer: UInt, _ index: UInt32) {
        impl.clearEffectResult(renderer, index)
    }
}

// A term of an SVG filter's expression: the index of its effect, and the primitive's x, y, width and height.
@_spi(WebKitGPU) public struct SVGFilterTermDescription {
    public let effectIndex: UInt32
    public let geometry: WebCore.FilterEffectGeometryValues

    public init(effectIndex: UInt32, geometry: WebCore.FilterEffectGeometryValues) {
        self.effectIndex = effectIndex
        self.geometry = geometry
    }
}

// An SVG filter (SVGFilterRenderer): its expression, a stack program over its effects, and what applying its effects
// takes. `identifier` identifies it to the FilterResults its results are cached in.
@_spi(WebKitGPU) public struct SVGFilterDescription {
    public let identifier: UInt
    public let renderer: WebCore.FilterRendererParameters
    public let terms: [SVGFilterTermDescription]
    public let effects: [FilterEffectDescription]

    public init(identifier: UInt, renderer: WebCore.FilterRendererParameters, terms: [SVGFilterTermDescription], effects: [FilterEffectDescription]) {
        self.identifier = identifier
        self.renderer = renderer
        self.terms = terms
        self.effects = effects
    }

    init(_ view: WebCore.SVGFilterRendererView) {
        var terms: [SVGFilterTermDescription] = []
        terms.reserveCapacity(Int(view.termCount()))
        for term in 0..<view.termCount() {
            terms.append(SVGFilterTermDescription(effectIndex: view.termEffectIndex(term), geometry: view.termGeometry(term)))
        }
        var effects: [FilterEffectDescription] = []
        effects.reserveCapacity(Int(view.effectCount()))
        for index in 0..<view.effectCount() {
            effects.append(FilterEffectDescription(view.effect(index)))
        }
        self.init(identifier: UInt(view.identifier()), renderer: view.parameters(), terms: terms, effects: effects)
    }
}

// A function of a CSS filter: an effect, or an SVG filter it references.
@_spi(WebKitGPU) public enum CSSFilterFunctionDescription {
    case effect(FilterEffectDescription)
    case svgFilter(SVGFilterDescription)
}

// A CSS filter (CSSFilterRenderer): its functions, applied in turn, and what applying its effects takes. Nil functions
// apply nothing, and make the filter fail.
@_spi(WebKitGPU) public struct CSSFilterDescription {
    public let identifier: UInt
    public let renderer: WebCore.FilterRendererParameters
    public let functions: [CSSFilterFunctionDescription?]

    public init(identifier: UInt, renderer: WebCore.FilterRendererParameters, functions: [CSSFilterFunctionDescription?]) {
        self.identifier = identifier
        self.renderer = renderer
        self.functions = functions
    }

    init(_ view: WebCore.CSSFilterRendererView) {
        var functions: [CSSFilterFunctionDescription?] = []
        functions.reserveCapacity(Int(view.functionCount()))
        for index in 0..<view.functionCount() {
            switch view.functionKind(index) {
            case .Effect:
                functions.append(.effect(FilterEffectDescription(view.effect(index))))
            case .SVGFilter:
                functions.append(.svgFilter(SVGFilterDescription(view.svgFilter(index))))
            default:
                functions.append(nil)
            }
        }
        self.init(identifier: UInt(view.identifier()), renderer: view.parameters(), functions: functions)
    }
}

@_spi(WebKitGPU) extension FilterEffectDescription {
    // FilterEffect::supportedFilterRenderingModes(): whether the effect can be applied in Accelerated mode.
    public var supportsAcceleratedRendering: Bool {
        #if USE_CORE_IMAGE
        switch parameters {
        case .colorMatrix(let colorMatrix):
            return feColorMatrixSupportsCoreImage(colorMatrix.type)
        case .convolveMatrix(let convolveMatrix):
            return feConvolveMatrixSupportsCoreImage(convolveMatrix.edgeMode)
        default:
            return true
        }
        #else
        return false
        #endif
    }

    // A color of an effect, in its operating color space (FilterEffectView's colors).
    public static func colorComponents(_ color: WebCore.Color, in colorSpace: WebCore.ColorSpace) -> WebCore.FilterColorComponents {
        WebCore.filterEffectColorComponents(color, colorSpace)
    }

    // A color of an effect with its opacity, in its operating color space (FEFlood's and FEDropShadow's).
    public static func colorComponents(_ color: WebCore.Color, opacity: Float, in colorSpace: WebCore.ColorSpace) -> WebCore.FilterColorComponents {
        WebCore.filterEffectColorComponents(color.colorWithAlphaMultipliedBy(opacity), colorSpace)
    }

    // sRGB, the operating color space of an effect that has none of its own (FEImage).
    public static var sRGBColorSpace: WebCore.ColorSpace {
        WebCore.GraphicsContextSwiftBridge.sRGBColorSpace()
    }

    // Whether an operating color space is sRGB.
    public static func colorSpaceIsSRGB(_ colorSpace: WebCore.ColorSpace) -> Bool {
        WebCore.filterEffectColorSpaceIsSRGB(colorSpace)
    }

    #if USE_CG
    // The operating color space of an effect whose color space is a CGColorSpace.
    public static func colorSpace(_ colorSpace: CGColorSpace) -> WebCore.ColorSpace {
        WebCore.filterEffectColorSpace(colorSpace)
    }

    // The Color of a color's data (CGRendererColorFromValue()).
    public static func color(_ data: CGRendererColorData) -> WebCore.Color {
        var value = CGRendererColorValue()
        value.data = data
        return CGRendererColorFromValue(value)
    }
    #endif
}

// What applying a filter's effects takes (filterRendererParameters()) of a filter that the GPU process describes in Swift,
// as the C++ filters derive it when IPC creates them. `clampsFilterScale`: a CSS filter's scale is clamped so that its
// scaled filter region doesn't need clamping (Filter::clampFilterRegionIfNeeded()). `enclosingFilterRegion`: the Core
// Image region of the filter, its filter region unless a CSS filter computed another. `effectsSupportAcceleratedRendering`:
// whether all the filter's effects and referenced SVG filters' effects can be applied in Accelerated mode, which they are
// if the preferred modes have it (Filter::setFilterRenderingModes()); a filter without any is.
@_spi(WebKitGPU) public func describedFilterRendererParameters(
    referenceBox: WebCore.FloatRect,
    filterRegion: WebCore.FloatRect,
    scale: WebCore.FloatSize,
    clampsFilterScale: Bool,
    enclosingFilterRegion: WebCore.FloatRect,
    preferredRenderingModes: UInt8,
    renderingOptions: UInt8,
    primitiveUnitsAreObjectBoundingBox: Bool,
    hasEffects: Bool,
    effectsSupportAcceleratedRendering: Bool
) -> WebCore.FilterRendererParameters {
    var filterScale = scale
    if clampsFilterScale {
        var scaledFilterRegion = filterRegion
        scaledFilterRegion.scale(scale)
        var clampingScale = WebCore.FloatSize(1, 1)
        if WebCore.ImageBuffer.sizeNeedsClamping(scaledFilterRegion.size(), &clampingScale) {
            filterScale = WebCore.FloatSize(scale.width() * clampingScale.width(), scale.height() * clampingScale.height())
        }
    }
    let accelerated = !hasEffects || (preferredRenderingModes & describedFilterRenderingModeAccelerated != 0 && effectsSupportAcceleratedRendering)
    var parameters = WebCore.FilterRendererParameters()
    parameters.filterScale = filterScale
    parameters.filterRegion = filterRegion
    parameters.referenceBox = referenceBox
    #if USE_CORE_IMAGE
    parameters.enclosingFilterRegion = enclosingFilterRegion
    #else
    parameters.enclosingFilterRegion = filterRegion
    #endif
    parameters.renderingMode = accelerated ? .Accelerated : .Unaccelerated
    parameters.primitiveUnitsAreObjectBoundingBox = primitiveUnitsAreObjectBoundingBox
    parameters.accelerated = accelerated
    parameters.fastAndLowQuality = renderingOptions & describedFilterRenderingOptionFastAndLowQuality != 0
    parameters.showDebugOverlay = renderingOptions & describedFilterRenderingOptionShowDebugOverlay != 0
    return parameters
}

// FilterRenderingMode::Accelerated, and FilterRenderingOption::ShowDebugOverlay and FastAndLowQuality.
private let describedFilterRenderingModeAccelerated: UInt8 = 1 << 1
private let describedFilterRenderingOptionShowDebugOverlay: UInt8 = 1 << 0
private let describedFilterRenderingOptionFastAndLowQuality: UInt8 = 1 << 1

#if USE_CORE_IMAGE
// CSSFilterRenderer::computeEnclosingFilterRegion() of a described CSS filter: the region that it and the SVG filters it
// references share.
@_spi(WebKitGPU) public func describedCSSFilterEnclosingFilterRegion(_ filterRegion: WebCore.FloatRect, _ svgFilterRegions: [WebCore.FloatRect]) -> WebCore.FloatRect {
    var enclosingFilterRegion = filterRegion
    for region in svgFilterRegions {
        enclosingFilterRegion.unite(region)
    }
    return enclosingFilterRegion
}
#endif

private func floatArray(_ values: Span<Float>) -> [Float] {
    var result: [Float] = []
    result.reserveCapacity(values.count)
    for index in values.indices {
        result.append(values[index])
    }
    return result
}

#endif // ENABLE_WEBCORE_SWIFT
