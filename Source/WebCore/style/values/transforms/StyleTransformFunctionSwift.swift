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

// Operators that WebCore's headers declare use JavaScriptCore and WTF types that the JavaScriptCore_Private and wtf
// imports below define. Without their definitions, * and + do not typecheck in this file.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
internal import WebCore_Private.Core.StylePrimitiveNumericTypes_Blending
internal import WebCore_Private.Core.StyleTransformFunction
internal import WebCore_Private.Core.StyleTransformSwiftTypes
internal import WebCore_Private.Core.TransformationMatrix
internal import wtf.Core.Stopwatch

// The effect of a transform function on a matrix, for TransformList::apply() and the translate, rotate and scale
// properties.

// Multiplies matrix by the function's transform, with lengths resolved against the reference box's width and height
// and multiplied by zoom. The function is taken as a reference of its own, which keeps it alive for the call.
@_expose(Cxx)
func styleTransformFunctionApply(
    _ function: consuming WebCore.Style.TransformFunction,
    _ matrix: inout WebCore.TransformationMatrix,
    _ width: Float,
    _ height: Float,
    _ zoom: Float
) {
    applyStyleTransformFunction(function.value.get(), to: &matrix, width, height, zoom)
}

@inline(always)
func applyStyleTransformFunction(
    _ function: WebCore.Style.TransformFunctionBase,
    to matrix: inout WebCore.TransformationMatrix,
    _ width: Float,
    _ height: Float,
    _ zoom: Float
) {
    switch function.type() {
    case .TranslateX, .TranslateY, .TranslateZ, .Translate, .Translate3D:
        // Each length is resolved as a float, which a double holds exactly.
        let translate = WebCore.Style.styleTranslateValues(function, width, height, zoom)
        transformationMatrixTranslate3d(&matrix, translate.x, translate.y, translate.z)
    case .ScaleX, .ScaleY, .ScaleZ, .Scale, .Scale3D:
        let scale = WebCore.Style.styleScaleValues(function)
        transformationMatrixScale3d(&matrix, scale.x, scale.y, scale.z)
    case .RotateX, .RotateY, .RotateZ, .Rotate, .Rotate3D:
        // Rotations by multiples of 90 degrees are snapped, as TransformationMatrix::rotate() and rotate3d() do by
        // default.
        let rotate = WebCore.Style.styleRotateValues(function)
        if function.type() == .Rotate {
            transformationMatrixRotate(&matrix, rotate.angle, true)
        } else {
            transformationMatrixRotate3d(&matrix, rotate.x, rotate.y, rotate.z, rotate.angle, true)
        }
    case .SkewX, .SkewY, .Skew:
        let skew = WebCore.Style.styleSkewValues(function)
        transformationMatrixSkew(&matrix, skew.x, skew.y)
    case .Matrix:
        // The translation is a length, so it is zoomed.
        var product = WebCore.Style.styleAsMatrixTransformFunction(function)!.matrix()
        product.setM41(product.m41() * Double(zoom))
        product.setM42(product.m42() * Double(zoom))
        transformationMatrixMultiply(&matrix, product)
    case .Matrix3D:
        var product = WebCore.Style.styleAsMatrix3DTransformFunction(function)!.matrix()
        transformationMatrixZoom(&product, Double(zoom))
        transformationMatrixMultiply(&matrix, product)
    case .Perspective:
        // perspective(none) is the identity. A distance under 1px is clamped to 1px.
        let perspective = WebCore.Style.styleAsPerspectiveTransformFunction(function)!.perspective()
        if !perspective.isNone() {
            let distance = evaluatedStylePerspective(perspective, zoom)
            transformationMatrixApplyPerspective(&matrix, Double(1 < distance ? distance : 1))
        }
    @unknown default:
        fatalError("unknown transform function type")
    }
}

// Whether two functions are of the same type with equal parameters, for TransformFunctionBase::operator==.
@_expose(Cxx)
func styleTransformFunctionEqual(
    _ a: consuming WebCore.Style.TransformFunction,
    _ b: consuming WebCore.Style.TransformFunction
) -> Bool {
    equalStyleTransformFunctions(a.value.get(), b.value.get())
}

// Whether the functions at index of two lists are of the same type with equal parameters. Translations, scales,
// rotations and skews are read in place; matrix(), matrix3d() and perspective() are taken as references.
@inline(always)
func equalStyleTransformListFunctions(
    _ a: borrowing WebCore.Style.TransformList,
    _ b: borrowing WebCore.Style.TransformList,
    at index: Int
) -> Bool {
    let type = WebCore.Style.styleTransformFunctionTypeAt(a, index)
    if type != WebCore.Style.styleTransformFunctionTypeAt(b, index) {
        return false
    }
    switch type {
    case .TranslateX, .TranslateY, .TranslateZ, .Translate, .Translate3D:
        return WebCore.Style.styleEqualTranslate(a, b, index)
    case .ScaleX, .ScaleY, .ScaleZ, .Scale, .Scale3D:
        let lhs = WebCore.Style.styleScaleValues(a, index)
        let rhs = WebCore.Style.styleScaleValues(b, index)
        return lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z
    case .RotateX, .RotateY, .RotateZ, .Rotate, .Rotate3D:
        let lhs = WebCore.Style.styleRotateValues(a, index)
        let rhs = WebCore.Style.styleRotateValues(b, index)
        return lhs.angle == rhs.angle && lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z
    case .SkewX, .SkewY, .Skew:
        let lhs = WebCore.Style.styleSkewValues(a, index)
        let rhs = WebCore.Style.styleSkewValues(b, index)
        return lhs.x == rhs.x && lhs.y == rhs.y
    case .Matrix, .Matrix3D, .Perspective:
        return equalStyleTransformFunctions(a.function(index), b.function(index))
    @unknown default:
        fatalError("unknown transform function type")
    }
}

// Whether two functions are of the same type with equal parameters.
@inline(always)
private func equalStyleTransformFunctions(
    _ first: WebCore.Style.TransformFunctionBase,
    _ second: WebCore.Style.TransformFunctionBase
) -> Bool {
    if first.type() != second.type() {
        return false
    }
    switch first.type() {
    case .TranslateX, .TranslateY, .TranslateZ, .Translate, .Translate3D:
        return WebCore.Style.styleEqualTranslate(first, second)
    case .ScaleX, .ScaleY, .ScaleZ, .Scale, .Scale3D:
        let lhs = WebCore.Style.styleScaleValues(first)
        let rhs = WebCore.Style.styleScaleValues(second)
        return lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z
    case .RotateX, .RotateY, .RotateZ, .Rotate, .Rotate3D:
        let lhs = WebCore.Style.styleRotateValues(first)
        let rhs = WebCore.Style.styleRotateValues(second)
        return lhs.angle == rhs.angle && lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z
    case .SkewX, .SkewY, .Skew:
        let lhs = WebCore.Style.styleSkewValues(first)
        let rhs = WebCore.Style.styleSkewValues(second)
        return lhs.x == rhs.x && lhs.y == rhs.y
    case .Matrix:
        // The six parameters are the matrix's a to f.
        let lhs = WebCore.Style.styleAsMatrixTransformFunction(first)!.matrix()
        let rhs = WebCore.Style.styleAsMatrixTransformFunction(second)!.matrix()
        return lhs.a() == rhs.a() && lhs.b() == rhs.b() && lhs.c() == rhs.c() && lhs.d() == rhs.d()
            && lhs.e() == rhs.e() && lhs.f() == rhs.f()
    case .Matrix3D:
        return WebCore.Style.styleAsMatrix3DTransformFunction(first)!.matrix()
            == WebCore.Style.styleAsMatrix3DTransformFunction(second)!.matrix()
    case .Perspective:
        return equalStylePerspectives(
            WebCore.Style.styleAsPerspectiveTransformFunction(first)!.perspective(),
            WebCore.Style.styleAsPerspectiveTransformFunction(second)!.perspective()
        )
    @unknown default:
        fatalError("unknown transform function type")
    }
}

// The platform operation for the function, with lengths resolved against the reference box's width and height and
// multiplied by zoom.
@_expose(Cxx)
func styleTransformFunctionToPlatform(
    _ function: consuming WebCore.Style.TransformFunction,
    _ width: Float,
    _ height: Float,
    _ zoom: Float
) -> WebCore.Style.StyleTransformOperationRef {
    let base = function.value.get()
    switch base.type() {
    case .TranslateX, .TranslateY, .TranslateZ, .Translate, .Translate3D:
        // Each length was resolved as a float, so narrowing it back is exact.
        let translate = WebCore.Style.styleTranslateValues(base, width, height, zoom)
        return WebCore.Style.StyleTransformOperationRef(
            WebCore.TranslateTransformOperation
                .create(
                    Float(translate.x),
                    Float(translate.y),
                    Float(translate.z),
                    platformTransformOperationType(base.type())
                )
                .get()
        )
    case .ScaleX, .ScaleY, .ScaleZ, .Scale, .Scale3D:
        let scale = WebCore.Style.styleScaleValues(base)
        return WebCore.Style.StyleTransformOperationRef(
            WebCore.ScaleTransformOperation
                .create(
                    scale.x,
                    scale.y,
                    scale.z,
                    platformTransformOperationType(base.type())
                )
                .get()
        )
    case .RotateX, .RotateY, .RotateZ, .Rotate, .Rotate3D:
        let rotate = WebCore.Style.styleRotateValues(base)
        return WebCore.Style.StyleTransformOperationRef(
            WebCore.RotateTransformOperation
                .create(
                    rotate.x,
                    rotate.y,
                    rotate.z,
                    rotate.angle,
                    platformTransformOperationType(base.type())
                )
                .get()
        )
    case .SkewX, .SkewY, .Skew:
        let skew = WebCore.Style.styleSkewValues(base)
        return WebCore.Style.StyleTransformOperationRef(
            WebCore.SkewTransformOperation
                .create(
                    skew.x,
                    skew.y,
                    platformTransformOperationType(base.type())
                )
                .get()
        )
    case .Matrix:
        // The translation is a length, so it is zoomed.
        let matrix = WebCore.Style.styleAsMatrixTransformFunction(base)!.matrix()
        return WebCore.Style.StyleTransformOperationRef(
            WebCore.MatrixTransformOperation
                .create(
                    matrix.a(),
                    matrix.b(),
                    matrix.c(),
                    matrix.d(),
                    matrix.e() * Double(zoom),
                    matrix.f() * Double(zoom)
                )
                .get()
        )
    case .Matrix3D:
        var matrix = WebCore.Style.styleAsMatrix3DTransformFunction(base)!.matrix()
        transformationMatrixZoom(&matrix, Double(zoom))
        return WebCore.Style.StyleTransformOperationRef(WebCore.Matrix3DTransformOperation.create(matrix).get())
    case .Perspective:
        // Unlike apply(), the distance is not clamped.
        let perspective = WebCore.Style.styleAsPerspectiveTransformFunction(base)!.perspective()
        if perspective.isNone() {
            return WebCore.Style.StyleTransformOperationRef(WebCore.PerspectiveTransformOperation.create(nil).get())
        }
        return WebCore.Style.StyleTransformOperationRef(
            WebCore.PerspectiveTransformOperation.create(.init(evaluatedStylePerspective(perspective, zoom))).get()
        )
    @unknown default:
        fatalError("unknown transform function type")
    }
}

// Whether the function's effect depends on the reference box's width or height: a translation by a percentage.
@_expose(Cxx)
func styleTransformFunctionSizeDependencies(
    _ function: consuming WebCore.Style.TransformFunction
) -> WebCore.Style.TransformFunctionSizeDependencies {
    styleTransformFunctionSizeDependencies(of: function.value.get())
}

func styleTransformFunctionSizeDependencies(
    of function: WebCore.Style.TransformFunctionBase
) -> WebCore.Style.TransformFunctionSizeDependencies {
    var result = WebCore.Style.TransformFunctionSizeDependencies()
    if let translate = WebCore.Style.styleAsTranslateTransformFunction(function) {
        result.isWidthDependent = translate.xValue().isPercent()
        result.isHeightDependent = translate.yValue().isPercent()
    }
    return result
}

// Whether the function's matrix has no component on the z axis.
func styleTransformFunctionIsRepresentableIn2D(_ function: WebCore.Style.TransformFunctionBase) -> Bool {
    switch function.type() {
    case .TranslateX, .TranslateY, .TranslateZ, .Translate, .Translate3D:
        return WebCore.Style.styleAsTranslateTransformFunction(function)!.isRepresentableIn2D()
    case .ScaleX, .ScaleY, .ScaleZ, .Scale, .Scale3D:
        return WebCore.Style.styleScaleValues(function).z == 1
    case .RotateX, .RotateY, .RotateZ, .Rotate, .Rotate3D:
        // As RotateTransformFunction::isRepresentableIn2D(): isZero() is == 0, false for NaN.
        let rotate = WebCore.Style.styleRotateValues(function)
        return (rotate.x == 0 && rotate.y == 0) || rotate.angle == 0
    case .Matrix3D:
        return WebCore.Style.styleAsMatrix3DTransformFunction(function)!.matrix().isAffine()
    case .Perspective:
        return false
    case .SkewX, .SkewY, .Skew, .Matrix:
        return true
    @unknown default:
        fatalError("unknown transform function type")
    }
}

// Whether transform-origin changes the function's effect: it does for any kind but a translation, unless the
// function is the identity.
func styleTransformFunctionIsAffectedByTransformOrigin(_ function: WebCore.Style.TransformFunctionBase) -> Bool {
    switch function.type() {
    case .TranslateX, .TranslateY, .TranslateZ, .Translate, .Translate3D:
        return false
    // A scale, rotation or skew is affected unless it is the identity: factors of 1, or angles of 0.
    case .ScaleX, .ScaleY, .ScaleZ, .Scale, .Scale3D:
        let scale = WebCore.Style.styleScaleValues(function)
        return !(scale.x == 1 && scale.y == 1 && scale.z == 1)
    case .RotateX, .RotateY, .RotateZ, .Rotate, .Rotate3D:
        return !(WebCore.Style.styleRotateValues(function).angle == 0)
    case .SkewX, .SkewY, .Skew:
        let skew = WebCore.Style.styleSkewValues(function)
        return !(skew.x == 0 && skew.y == 0)
    // A matrix() is the identity when its six parameters are, which are the fixed entries' values in its matrix.
    case .Matrix:
        return !WebCore.Style.styleAsMatrixTransformFunction(function)!.matrix().isIdentity()
    case .Matrix3D:
        return !WebCore.Style.styleAsMatrix3DTransformFunction(function)!.matrix().isIdentity()
    // perspective(none) is the identity.
    case .Perspective:
        return !WebCore.Style.styleAsPerspectiveTransformFunction(function)!.perspective().isNone()
    @unknown default:
        fatalError("unknown transform function type")
    }
}

// Interpolation of transform functions, for Blending<TransformFunction>, Blending<TransformList> and the translate,
// rotate and scale properties.

// The function interpolated from from to to by the context's progress.
@_expose(Cxx)
func styleTransformFunctionBlend(
    _ from: consuming WebCore.Style.TransformFunction,
    _ to: consuming WebCore.Style.TransformFunction,
    _ context: WebCore.BlendingContext
) -> WebCore.Style.TransformFunction {
    blendStyleTransformFunction(to.value.get(), from: from.value.get(), context, toIdentity: false)
}

// The function interpolated from from, or from the identity when from is null, to function. With toIdentity, it is
// interpolated from function to the identity instead, and from must be null. A function that does not share a
// primitive with from is returned as it is.
@inline(always)
func blendStyleTransformFunction(
    _ function: WebCore.Style.TransformFunctionBase,
    from: WebCore.Style.TransformFunctionBase?,
    _ context: WebCore.BlendingContext,
    toIdentity: Bool
) -> WebCore.Style.TransformFunction {
    switch function.type() {
    case .TranslateX, .TranslateY, .TranslateZ, .Translate, .Translate3D:
        return blendedStyleTranslateTransformFunction(function, from: from, context, toIdentity: toIdentity)
    case .ScaleX, .ScaleY, .ScaleZ, .Scale, .Scale3D:
        return blendedStyleScaleTransformFunction(function, from: from, context, toIdentity: toIdentity)
    case .RotateX, .RotateY, .RotateZ, .Rotate, .Rotate3D:
        return blendedStyleRotateTransformFunction(function, from: from, context, toIdentity: toIdentity)
    case .SkewX, .SkewY, .Skew:
        return blendedStyleSkewTransformFunction(function, from: from, context, toIdentity: toIdentity)
    case .Matrix, .Matrix3D:
        return blendedStyleMatrixTransformFunction(function, from: from, context, toIdentity: toIdentity)
    case .Perspective:
        return blendedStylePerspectiveTransformFunction(function, from: from, context, toIdentity: toIdentity)
    @unknown default:
        fatalError("unknown transform function type")
    }
}

// A translation interpolated from from, or from zero when from is null, to function; with toIdentity, from function
// to zero.
@inline(never)
private func blendedStyleTranslateTransformFunction(
    _ function: WebCore.Style.TransformFunctionBase,
    from: WebCore.Style.TransformFunctionBase?,
    _ context: WebCore.BlendingContext,
    toIdentity: Bool
) -> WebCore.Style.TransformFunction {
    guard let type = toIdentity ? function.type() : styleTransformFunctionSharedPrimitiveType(function, from) else {
        return WebCore.Style.styleMakeTransformFunction(function)
    }
    let to = WebCore.Style.styleAsTranslateTransformFunction(function)!
    let zero = WebCore.Style.TranslateTransformFunction.X(WebCore.Style.TranslateTransformFunction.Z(0))
    if toIdentity {
        return WebCore.Style.styleMakeTransformFunction(
            WebCore.Style.TranslateTransformFunction
                .create(
                    blendStyleLengthPercentage(to.xValue(), zero, context),
                    blendStyleLengthPercentage(to.yValue(), zero, context),
                    blendStyleLength(to.z(), WebCore.Style.TranslateTransformFunction.Z(0), context),
                    type
                )
                .get()
        )
    }
    let fromTranslate = from.map { WebCore.Style.styleAsTranslateTransformFunction($0)! }
    return WebCore.Style.styleMakeTransformFunction(
        WebCore.Style.TranslateTransformFunction
            .create(
                blendStyleLengthPercentage(fromTranslate?.xValue() ?? zero, to.xValue(), context),
                blendStyleLengthPercentage(fromTranslate?.yValue() ?? zero, to.yValue(), context),
                blendStyleLength(fromTranslate?.z() ?? WebCore.Style.TranslateTransformFunction.Z(0), to.z(), context),
                type
            )
            .get()
    )
}

@inline(never)
private func blendedStyleScaleTransformFunction(
    _ function: WebCore.Style.TransformFunctionBase,
    from: WebCore.Style.TransformFunctionBase?,
    _ context: WebCore.BlendingContext,
    toIdentity: Bool
) -> WebCore.Style.TransformFunction {
    guard let type = toIdentity ? function.type() : styleTransformFunctionSharedPrimitiveType(function, from) else {
        return WebCore.Style.styleMakeTransformFunction(function)
    }
    let blended = blendedStyleScaleValues(
        WebCore.Style.styleScaleValues(function),
        from: from.map { WebCore.Style.styleScaleValues($0) },
        context,
        toIdentity: toIdentity
    )
    return WebCore.Style.styleMakeTransformFunction(
        WebCore.Style.ScaleTransformFunction.create(.init(blended.x), .init(blended.y), .init(blended.z), type).get()
    )
}

@inline(never)
private func blendedStyleRotateTransformFunction(
    _ function: WebCore.Style.TransformFunctionBase,
    from: WebCore.Style.TransformFunctionBase?,
    _ context: WebCore.BlendingContext,
    toIdentity: Bool
) -> WebCore.Style.TransformFunction {
    guard let type = toIdentity ? function.type() : styleTransformFunctionSharedPrimitiveType(function, from) else {
        return WebCore.Style.styleMakeTransformFunction(function)
    }
    let blended = blendedStyleRotateValues(
        WebCore.Style.styleRotateValues(function),
        of: function.type(),
        from: from.map { WebCore.Style.styleRotateValues($0) },
        context,
        toIdentity: toIdentity,
        type: type
    )
    return WebCore.Style.styleMakeTransformFunction(
        WebCore.Style.RotateTransformFunction
            .create(
                .init(blended.x),
                .init(blended.y),
                .init(blended.z),
                .init(blended.angle),
                blended.type
            )
            .get()
    )
}

@inline(never)
private func blendedStyleSkewTransformFunction(
    _ function: WebCore.Style.TransformFunctionBase,
    from: WebCore.Style.TransformFunctionBase?,
    _ context: WebCore.BlendingContext,
    toIdentity: Bool
) -> WebCore.Style.TransformFunction {
    guard let type = toIdentity ? function.type() : styleTransformFunctionSharedPrimitiveType(function, from) else {
        return WebCore.Style.styleMakeTransformFunction(function)
    }
    let to = WebCore.Style.styleSkewValues(function)
    let fromSkew = from.map { WebCore.Style.styleSkewValues($0) }
    let angleX: Double
    let angleY: Double
    if toIdentity {
        angleX = blendStyleAngle(to.x, 0, context)
        angleY = blendStyleAngle(to.y, 0, context)
    } else {
        angleX = blendStyleAngle(fromSkew?.x ?? 0, to.x, context)
        angleY = blendStyleAngle(fromSkew?.y ?? 0, to.y, context)
    }
    return WebCore.Style.styleMakeTransformFunction(
        WebCore.Style.SkewTransformFunction.create(.init(angleX), .init(angleY), type).get()
    )
}

@inline(never)
private func blendedStyleMatrixTransformFunction(
    _ function: WebCore.Style.TransformFunctionBase,
    from: WebCore.Style.TransformFunctionBase?,
    _ context: WebCore.BlendingContext,
    toIdentity: Bool
) -> WebCore.Style.TransformFunction {
    guard styleTransformFunctionSharedPrimitiveType(function, from) != nil else {
        return WebCore.Style.styleMakeTransformFunction(function)
    }
    if function.type() == .Matrix {
        let blended = blendedMatrix(
            WebCore.Style.styleAsMatrixTransformFunction(function)!.matrix(),
            from: from.map { WebCore.Style.styleAsMatrixTransformFunction($0)!.matrix() },
            context,
            toIdentity: toIdentity
        )
        return WebCore.Style.styleMakeTransformFunction(WebCore.Style.MatrixTransformFunction.create(blended).get())
    }
    let blended = blendedMatrix(
        WebCore.Style.styleAsMatrix3DTransformFunction(function)!.matrix(),
        from: from.map { WebCore.Style.styleAsMatrix3DTransformFunction($0)!.matrix() },
        context,
        toIdentity: toIdentity
    )
    return WebCore.Style.styleMakeTransformFunction(WebCore.Style.Matrix3DTransformFunction.create(blended).get())
}

@inline(never)
private func blendedStylePerspectiveTransformFunction(
    _ function: WebCore.Style.TransformFunctionBase,
    from: WebCore.Style.TransformFunctionBase?,
    _ context: WebCore.BlendingContext,
    toIdentity: Bool
) -> WebCore.Style.TransformFunction {
    guard styleTransformFunctionSharedPrimitiveType(function, from) != nil else {
        return WebCore.Style.styleMakeTransformFunction(function)
    }
    // The interpolation of the matrices, done directly: the inverse of the distance is interpolated, and a result that
    // is not a positive normal number is none.
    let inverse = perspectiveInverse(WebCore.Style.styleAsPerspectiveTransformFunction(function)!)
    let fromInverse: Double
    let toInverse: Double
    if toIdentity {
        fromInverse = inverse
        toInverse = 0
    } else {
        fromInverse = from.map { perspectiveInverse(WebCore.Style.styleAsPerspectiveTransformFunction($0)!) } ?? 0
        toInverse = inverse
    }
    let blended = WebCore.blend(fromInverse, toInverse, context)
    if blended > 0 && blended.isNormal {
        return WebCore.Style.styleMakeTransformFunction(
            WebCore.Style.styleMakePerspectiveTransformFunction(false, Float(1 / blended)).get()
        )
    }
    return WebCore.Style.styleMakeTransformFunction(WebCore.Style.styleMakePerspectiveTransformFunction(true, 0).get())
}

// A scale's factors interpolated from from, or from 1 when from is null, to to; with toIdentity, from to to 1.
func blendedStyleScaleValues(
    _ to: WebCore.Style.StyleTransformFunctionValues,
    from: WebCore.Style.StyleTransformFunctionValues?,
    _ context: WebCore.BlendingContext,
    toIdentity: Bool
) -> (x: Double, y: Double, z: Double) {
    // Addition multiplies the factors, and accumulation adds them less 1.
    func component(_ from: Double, _ to: Double) -> Double {
        switch context.compositeOperation {
        case .Replace:
            return blendStyleNumberOrPercentageResolvedToNumber(from, to, context)
        case .Add:
            assert(context.progress == 1)
            return from * to
        case .Accumulate:
            assert(context.progress == 1)
            return from + to - 1
        @unknown default:
            fatalError("unknown composite operation")
        }
    }
    if toIdentity {
        return (component(to.x, 1), component(to.y, 1), component(to.z, 1))
    }
    return (component(from?.x ?? 1, to.x), component(from?.y ?? 1, to.y), component(from?.z ?? 1, to.z))
}

// A rotation interpolated from from, or from no rotation about the z axis when from is null, to to; with toIdentity,
// its angle from to's to 0, unless the composite operation is accumulation.
func blendedStyleRotateValues(
    _ to: WebCore.Style.StyleTransformFunctionValues,
    of toType: WebCore.Style.TransformFunctionType,
    from: WebCore.Style.StyleTransformFunctionValues?,
    _ context: WebCore.BlendingContext,
    toIdentity: Bool,
    type: WebCore.Style.TransformFunctionType
) -> (x: Double, y: Double, z: Double, angle: Double, type: WebCore.Style.TransformFunctionType) {
    if toIdentity {
        let angle = to.angle
        if context.compositeOperation == .Accumulate {
            return (to.x, to.y, to.z, angle, toType)
        }
        let blendedAngle = contractedMultiplyAdd(angle, -angle, context.progress)
        return (to.x, to.y, to.z, blendedAngle, toType)
    }

    // https://drafts.csswg.org/css-transforms-2/#interpolation-of-transform-functions
    //
    // For interpolations with the primitive rotate3d(), the direction vectors of the transform functions get
    // normalized first. If the normalized vectors are not equal and both rotation angles are non-zero the transform
    // functions get converted into 4x4 matrices first and interpolated as defined in section Interpolation of Matrices
    // afterwards. Otherwise the rotation angle gets interpolated numerically and the rotation vector of the non-zero
    // angle is used or (0, 0, 1) if both angles are zero.

    // The axis as a FloatPoint3D: normalized in double, then each component narrowed to float.
    func normalizedAxis(_ rotation: WebCore.Style.StyleTransformFunctionValues) -> (x: Float, y: Float, z: Float) {
        let x = rotation.x
        let y = rotation.y
        let z = rotation.z
        let length = transformationMatrixHypot(x, y, z)
        if length != 0 {
            return (Float(x / length), Float(y / length), Float(z / length))
        }
        return (0, 0, 0)
    }

    let fromAngle = from?.angle ?? 0
    let toAngle = to.angle
    let fromAxis = from.map { normalizedAxis($0) } ?? (0, 0, 1)
    let toAxis = normalizedAxis(to)
    if fromAngle == 0 || toAngle == 0 || (fromAxis.x == toAxis.x && fromAxis.y == toAxis.y && fromAxis.z == toAxis.z) {
        let axis = fromAngle == 0 && toAngle != 0 ? toAxis : fromAxis
        return (
            Double(axis.x),
            Double(axis.y),
            Double(axis.z),
            blendStyleAngle(fromAngle, toAngle, context),
            type
        )
    }

    // Rotations by multiples of 90 degrees are snapped, as TransformationMatrix::rotate3d() does by default.
    var fromMatrix = WebCore.TransformationMatrix()
    var toMatrix = WebCore.TransformationMatrix()
    transformationMatrixRotate3d(
        &fromMatrix,
        from?.x ?? 0,
        from?.y ?? 0,
        from?.z ?? 1,
        from?.angle ?? 0,
        true
    )
    transformationMatrixRotate3d(&toMatrix, to.x, to.y, to.z, to.angle, true)
    toMatrix.blend(fromMatrix, context.progress, context.compositeOperation)

    // The blended matrix as a quaternion, then as an axis and an angle. When it cannot be decomposed, the result is
    // the nearer of the two functions; from is null only when its angle is 0, which is handled above.
    var decomposed = WebCore.TransformationMatrix.Decomposed4Type()
    if !transformationMatrixDecompose4(toMatrix, &decomposed) {
        let used = context.progress > 0.5 ? to : from!
        return (used.x, used.y, used.z, used.angle, .Rotate3D)
    }
    var x = decomposed.quaternion.x
    var y = decomposed.quaternion.y
    var z = decomposed.quaternion.z
    let length = transformationMatrixHypot(x, y, z)
    var angle = 0.0
    if length > 0.00001 {
        x /= length
        y /= length
        z /= length
        angle = wtf.rad2deg(acos(decomposed.quaternion.w) * 2)
    } else {
        x = 0
        y = 0
        z = 1
    }
    return (x, y, z, angle, .Rotate3D)
}

// The matrix interpolated from from, or from the identity when from is null, to to; with toIdentity, from to to the
// identity.
private func blendedMatrix(
    _ to: WebCore.TransformationMatrix,
    from: WebCore.TransformationMatrix?,
    _ context: WebCore.BlendingContext,
    toIdentity: Bool
) -> WebCore.TransformationMatrix {
    var toMatrix = to
    var fromMatrix = from ?? WebCore.TransformationMatrix()
    if toIdentity {
        fromMatrix.blend(toMatrix, context.progress, context.compositeOperation)
        return fromMatrix
    }
    toMatrix.blend(fromMatrix, context.progress, context.compositeOperation)
    return toMatrix
}

// A perspective's distance, which must not be none, resolved: the distance times zoom, in float, as evaluate<float>()
// resolves a length.
private func evaluatedStylePerspective(_ perspective: WebCore.Style.Perspective, _ zoom: Float) -> Float {
    WebCore.Style.styleUnresolvedPerspective(perspective) * zoom
}

// Whether two perspectives are equal: both none, or both distances, compared as floats.
@inline(never)
private func equalStylePerspectives(_ a: WebCore.Style.Perspective, _ b: WebCore.Style.Perspective) -> Bool {
    if a.isNone() || b.isNone() {
        return a.isNone() && b.isNone()
    }
    return WebCore.Style.styleUnresolvedPerspective(a) == WebCore.Style.styleUnresolvedPerspective(b)
}

// The primitive two functions interpolate through: against null (blending with the identity) or a function of the
// same type, the function's own type; otherwise TransformFunctionBase::sharedPrimitiveType(Type) of the other's
// primitive type, nil when they share none. Decided on the two types, as sharedPrimitiveType() decides it over each
// kind's primitiveType(): two rotations share rotate3d(); two scales share scale3d() if either is 3D, else scale();
// a skew, matrix(), matrix3d() or perspective() shares nothing with another type. Only two translations of different
// types depend on their values (whether z is zero), and ask the function.
@inline(always)
func styleTransformFunctionSharedPrimitiveType(
    _ function: WebCore.Style.TransformFunctionBase,
    _ other: WebCore.Style.TransformFunctionBase?
) -> WebCore.Style.TransformFunctionType? {
    guard let other else {
        return function.type()
    }
    let type = function.type()
    let otherType = other.type()
    if otherType == type {
        return type
    }
    switch type {
    case .RotateX, .RotateY, .RotateZ, .Rotate, .Rotate3D:
        switch otherType {
        case .RotateX, .RotateY, .RotateZ, .Rotate, .Rotate3D:
            return .Rotate3D
        default:
            return nil
        }
    case .ScaleX, .ScaleY, .ScaleZ, .Scale, .Scale3D:
        switch otherType {
        case .ScaleZ, .Scale3D:
            return .Scale3D
        case .ScaleX, .ScaleY, .Scale:
            return type == .ScaleZ || type == .Scale3D ? .Scale3D : .Scale
        default:
            return nil
        }
    case .TranslateX, .TranslateY, .TranslateZ, .Translate, .Translate3D:
        switch otherType {
        case .TranslateX, .TranslateY, .TranslateZ, .Translate, .Translate3D:
            return function.sharedPrimitiveType(other.primitiveType()).value
        default:
            return nil
        }
    default:
        return nil
    }
}

// The inverse of a perspective's distance, clamped to at least 1px, or 0 for perspective(none).
private func perspectiveInverse(_ function: WebCore.Style.PerspectiveTransformFunction) -> Double {
    let perspective = function.perspective()
    if perspective.isNone() {
        return 0
    }
    let distance = WebCore.Style.styleUnresolvedPerspective(perspective)
    return 1.0 / Double(1 < distance ? distance : 1)
}

// The interpolation of each parameter type, as its Blending<> specialization defines it.
func blendStyleLengthPercentage(
    _ from: WebCore.Style.TranslateTransformFunction.X,
    _ to: WebCore.Style.TranslateTransformFunction.X,
    _ context: WebCore.BlendingContext
) -> WebCore.Style.TranslateTransformFunction.X {
    var blending = WebCore.Style.BlendingLengthPercentage()
    return blending.blend(from, to, context)
}

func blendStyleLength(
    _ from: WebCore.Style.TranslateTransformFunction.Z,
    _ to: WebCore.Style.TranslateTransformFunction.Z,
    _ context: WebCore.BlendingContext
) -> WebCore.Style.TranslateTransformFunction.Z {
    var blending = WebCore.Style.BlendingLength()
    return blending.blend(from, to, context)
}

// Angles, and scale factors (NumberOrPercentageResolvedToNumber blends its number), are interpolated as
// Blending<Numeric> does for an unbounded range: from at progress 0 and to at progress 1 under replace, so that an
// infinite value is returned as it is rather than as inf + (x - inf) * 0, which is NaN; otherwise blend(), clamped to
// the finite doubles as CSS::clampToRange() clamps to them, with NaN passing through. min() and max() do not pass NaN
// through as clampTo() does.
@inline(always)
private func blendStyleNumber(_ from: Double, _ to: Double, _ context: WebCore.BlendingContext) -> Double {
    if context.progress == 0 && context.isReplace() {
        return from
    }
    if context.progress == 1 && context.isReplace() {
        return to
    }
    let value = WebCore.blend(from, to, context)
    if value >= Double.greatestFiniteMagnitude {
        return Double.greatestFiniteMagnitude
    }
    if value <= -Double.greatestFiniteMagnitude {
        return -Double.greatestFiniteMagnitude
    }
    return value
}

private func blendStyleAngle(_ from: Double, _ to: Double, _ context: WebCore.BlendingContext) -> Double {
    blendStyleNumber(from, to, context)
}

private func blendStyleNumberOrPercentageResolvedToNumber(
    _ from: Double,
    _ to: Double,
    _ context: WebCore.BlendingContext
) -> Double {
    blendStyleNumber(from, to, context)
}

// A function's type as its platform operation's: each type maps to the operation type of the same name.
private func platformTransformOperationType(_ type: WebCore.Style.TransformFunctionType) -> WebCore.TransformOperationType {
    switch type {
    case .ScaleX: return .ScaleX
    case .ScaleY: return .ScaleY
    case .Scale: return .Scale
    case .TranslateX: return .TranslateX
    case .TranslateY: return .TranslateY
    case .Translate: return .Translate
    case .RotateX: return .RotateX
    case .RotateY: return .RotateY
    case .Rotate: return .Rotate
    case .SkewX: return .SkewX
    case .SkewY: return .SkewY
    case .Skew: return .Skew
    case .Matrix: return .Matrix
    case .ScaleZ: return .ScaleZ
    case .Scale3D: return .Scale3D
    case .TranslateZ: return .TranslateZ
    case .Translate3D: return .Translate3D
    case .RotateZ: return .RotateZ
    case .Rotate3D: return .Rotate3D
    case .Matrix3D: return .Matrix3D
    case .Perspective: return .Perspective
    @unknown default: fatalError("unknown transform function type")
    }
}
