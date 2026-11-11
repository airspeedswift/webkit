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
internal import WebCore_Private.Core.StyleTransformList
internal import WebCore_Private.Core.TransformationMatrix
internal import wtf.Core.Stopwatch

// Each entry below that takes a TransformList is given the list or lists that a TransformList member (*this, and the
// other operand of operator==()) or Blending<TransformList> (the from and to keyframe lists) is called with, passed by
// reference without a copy. A list is owned by a ComputedStyle (its transform), by a PortalTransform (one of its lists,
// or its static empty list, which is never destroyed), by the keyframe styles the animation holds or by a caller's
// local; two of the lists may be the same list. During the call an entry calls only the accessors of the lists and of
// their functions and what its own comment names. None of these reaches a list except through the arguments, and none
// calls back, runs script or drops a list's own references, so no list can change or be destroyed before the call
// returns. All of this runs on the main thread, and the functions are single-threaded RefCounted.

// Multiplies matrix by the transform of each function of the list from start on, in order, with lengths resolved
// against the reference box's width and height and multiplied by zoom.
// Also calls the downcasts to each function type, each function's parameter reads, length evaluation and
// TransformationMatrix's members, and retains a translation, matrix(), matrix3d() or perspective() function while it
// applies it.
@_expose(Cxx)
func styleTransformListApply(
    _ list: borrowing WebCore.Style.TransformList,
    _ matrix: inout WebCore.TransformationMatrix,
    _ width: Float,
    _ height: Float,
    _ zoom: Float,
    _ start: UInt32
) {
    applyStyleTransformList(list, from: Int(start), to: &matrix, width, height, zoom)
}

func applyStyleTransformList(
    _ list: borrowing WebCore.Style.TransformList,
    from start: Int,
    to matrix: inout WebCore.TransformationMatrix,
    _ width: Float,
    _ height: Float,
    _ zoom: Float
) {
    var index = start
    let count = list.size()
    while index < count {
        // Scales, rotations and skews are read in place, with no reference taken to them; translations, matrix(),
        // matrix3d() and perspective() are taken as references.
        let type = WebCore.Style.styleTransformFunctionTypeAt(list, index)
        switch type {
        case .ScaleX, .ScaleY, .ScaleZ, .Scale, .Scale3D:
            let scale = WebCore.Style.styleScaleValues(list, index)
            transformationMatrixScale3d(&matrix, scale.x, scale.y, scale.z)
        case .RotateX, .RotateY, .RotateZ, .Rotate, .Rotate3D:
            // Snapped as in applyStyleTransformFunction().
            let rotate = WebCore.Style.styleRotateValues(list, index)
            if type == .Rotate {
                transformationMatrixRotate(&matrix, rotate.angle, true)
            } else {
                transformationMatrixRotate3d(&matrix, rotate.x, rotate.y, rotate.z, rotate.angle, true)
            }
        case .SkewX, .SkewY, .Skew:
            let skew = WebCore.Style.styleSkewValues(list, index)
            transformationMatrixSkew(&matrix, skew.x, skew.y)
        default:
            applyStyleTransformFunction(list.function(index), to: &matrix, width, height, zoom)
        }
        index += 1
    }
}

// Whether the two lists have the same length and, at each position, the same function or functions of the same type
// with equal parameters.
// Also calls the downcasts to each function type, each function's parameter reads, operator==() of two translations'
// lengths (which compares their calc() trees) and TransformationMatrix's operator==(), and retains a matrix(),
// matrix3d() or perspective() function while it compares it.
@_expose(Cxx)
func styleTransformListEqual(
    _ a: borrowing WebCore.Style.TransformList,
    _ b: borrowing WebCore.Style.TransformList
) -> Bool {
    let count = a.size()
    if count != b.size() {
        return false
    }
    if count == 0 {
        return true
    }
    return equalStyleTransformListElements(a, b, count: count)
}

// Whether the two lists, each count long, hold at each position the same function or functions of the same type with
// equal parameters. Translations, scales, rotations and skews are read in place, with no reference taken to them.
@inline(never)
func equalStyleTransformListElements(
    _ a: borrowing WebCore.Style.TransformList,
    _ b: borrowing WebCore.Style.TransformList,
    count: Int
) -> Bool {
    var index = 0
    while index < count {
        // Two ifs: the right side of && is an autoclosure, which would copy the borrowed lists.
        if !WebCore.Style.styleIsSameTransformFunction(a, b, index) {
            if !equalStyleTransformListFunctions(a, b, at: index) {
                return false
            }
        }
        index += 1
    }
    return true
}

// Whether any function of the list is of a 3D type, even one whose values describe an affine transform.
// Also retains each function while it reads it.
@_expose(Cxx)
func styleTransformListHas3DOperation(_ list: borrowing WebCore.Style.TransformList) -> Bool {
    var index = 0
    while index < list.size() {
        if list[index].value.get().is3DOperation() {
            return true
        }
        index += 1
    }
    return false
}

// Whether every function of the list has no component on the z axis.
// Also calls the downcasts to each function type and each function's parameter reads, and retains each function while
// it reads it.
@_expose(Cxx)
func styleTransformListIsRepresentableIn2D(_ list: borrowing WebCore.Style.TransformList) -> Bool {
    var index = 0
    while index < list.size() {
        if !styleTransformFunctionIsRepresentableIn2D(list[index].value.get()) {
            return false
        }
        index += 1
    }
    return true
}

// Whether transform-origin changes the effect of any function of the list.
// Also calls the downcasts to each function type and each function's parameter reads, and retains each function while
// it reads it.
@_expose(Cxx)
func styleTransformListAffectedByTransformOrigin(_ list: borrowing WebCore.Style.TransformList) -> Bool {
    var index = 0
    while index < list.size() {
        if styleTransformFunctionIsAffectedByTransformOrigin(list[index].value.get()) {
            return true
        }
        index += 1
    }
    return false
}

// Whether the list's matrix, against a reference box of the given width and height, has an inverse.
// Also calls what styleTransformListApply() calls.
@_expose(Cxx)
func styleTransformListIsInvertible(
    _ list: borrowing WebCore.Style.TransformList,
    _ width: Float,
    _ height: Float,
    _ zoom: Float
) -> Bool {
    var matrix = WebCore.TransformationMatrix()
    applyStyleTransformList(list, from: 0, to: &matrix, width, height, zoom)
    return matrix.isInvertible()
}

// Whether the effect of any function of the list depends on the reference box's width or height.
// Also calls the downcast to a translation and isPercent() of its lengths, and retains each function it reads.
@_expose(Cxx)
func styleTransformListSizeDependencies(
    _ list: borrowing WebCore.Style.TransformList
) -> WebCore.Style.TransformFunctionSizeDependencies {
    var result = WebCore.Style.TransformFunctionSizeDependencies()
    var index = 0
    while index < list.size() {
        let dependencies = styleTransformFunctionSizeDependencies(of: list[index].value.get())
        if dependencies.isWidthDependent {
            result.isWidthDependent = true
        }
        if dependencies.isHeightDependent {
            result.isHeightDependent = true
        }
        index += 1
    }
    return result
}

// MARK: - Blending

// Whether the list has a matrix() or matrix3d() function whose matrix, against a reference box of the given width
// and height, has no inverse.
func styleTransformListContainsNonInvertibleMatrix(
    _ list: borrowing WebCore.Style.TransformList,
    _ width: Float,
    _ height: Float
) -> Bool {
    var hasMatrix = false
    var index = 0
    while index < list.size() {
        let type = list.function(index).type()
        if type == .Matrix || type == .Matrix3D {
            hasMatrix = true
            break
        }
        index += 1
    }
    if !hasMatrix {
        return false
    }
    return !styleTransformListIsInvertible(list, width, height, WebCore.Style.ZoomFactor.none().value)
}

// Whether two lists can be interpolated: with the replace composite operation, neither may hold a matrix with no
// inverse against an empty reference box.
// Also calls what styleTransformListApply() calls, and retains each function it reads.
@_expose(Cxx)
func styleTransformListCanBlend(
    _ from: borrowing WebCore.Style.TransformList,
    _ to: borrowing WebCore.Style.TransformList,
    _ compositeOperation: WebCore.CompositeOperation
) -> Bool {
    if compositeOperation == .Replace {
        if styleTransformListContainsNonInvertibleMatrix(from, 0, 0) {
            return false
        }
        return !styleTransformListContainsNonInvertibleMatrix(to, 0, 0)
    }
    return true
}

// The list interpolated from from to to, against a reference box of the given width and height. Addition concatenates
// the lists. Functions that share a primitive are interpolated pairwise, a missing function as the identity, up to the
// first pair that does not, or up to prefixLength when hasPrefixLength; the rest of both lists is interpolated as one
// matrix. A list holding a matrix with no inverse makes the interpolation discrete.
// Also calls what styleTransformListApply() calls, the downcasts, sharedPrimitiveType(), the Blending<> of lengths,
// angles and numbers (which copy calc() trees), the functions' and the list's constructors and Vector's append() and
// reserveCapacity(); a function it takes keeps its list's reference. The result is set on the style after this returns.
@_expose(Cxx)
func styleTransformListBlend(
    _ from: borrowing WebCore.Style.TransformList,
    _ to: borrowing WebCore.Style.TransformList,
    _ context: WebCore.BlendingContext,
    _ width: Float,
    _ height: Float,
    _ hasPrefixLength: Bool,
    _ prefixLength: UInt32
) -> WebCore.Style.TransformList {
    let fromLength = from.size()
    let toLength = to.size()
    let maxLength = max(fromLength, toLength)
    var functions = WebCore.Style.StyleTransformFunctionVector()

    if context.compositeOperation == .Add {
        assert(context.progress == 1)
        // The sum of two list sizes cannot overflow.
        functions.reserveCapacity(fromLength &+ toLength)
        var index = 0
        while index < fromLength {
            functions.append(consuming: from[index])
            index += 1
        }
        index = 0
        while index < toLength {
            functions.append(consuming: to[index])
            index += 1
        }
        return WebCore.Style.styleMakeTransformList(&functions)
    }

    var isDiscrete = styleTransformListContainsNonInvertibleMatrix(from, width, height)
    if !isDiscrete {
        isDiscrete = styleTransformListContainsNonInvertibleMatrix(to, width, height)
    }

    if isDiscrete {
        return WebCore.Style.TransformList(
            consuming: blendedStyleTransformListMatrix(from, to, start: 0, context, width, height, isDiscrete: isDiscrete)
        )
    }

    // There is no matrix interpolation against an empty list.
    var matrixStart = -1
    if fromLength != 0 && toLength != 0 {
        var index = 0
        while index < maxLength {
            if hasPrefixLength && index >= Int(prefixLength) {
                matrixStart = index
                break
            }
            // Two ifs: the right side of && is an autoclosure, which would copy the borrowed lists.
            // Functions of the same type share it; only functions of different types are taken as references.
            if index < fromLength && index < toLength {
                if WebCore.Style.styleTransformFunctionTypeAt(from, index)
                    != WebCore.Style.styleTransformFunctionTypeAt(to, index)
                {
                    let toFunction = to.function(index)
                    if styleTransformFunctionSharedPrimitiveType(from.function(index), toFunction) == nil {
                        matrixStart = index
                        break
                    }
                }
            }
            index += 1
        }
    }

    functions.reserveCapacity(matrixStart >= 0 ? matrixStart + 1 : maxLength)
    var index = 0
    while index < (matrixStart >= 0 ? matrixStart : maxLength) {
        functions.append(consuming: blendedStyleTransformListFunction(from, to, at: index, context))
        index += 1
    }
    if matrixStart >= 0 {
        functions.append(
            consuming: blendedStyleTransformListMatrix(
                from,
                to,
                start: matrixStart,
                context,
                width,
                height,
                isDiscrete: false
            )
        )
    }
    return WebCore.Style.styleMakeTransformList(&functions)
}

// The functions from start on of each list applied to a matrix, and the matrices interpolated; discretely, with the
// replace composite operation, when isDiscrete.
func blendedStyleTransformListMatrix(
    _ from: borrowing WebCore.Style.TransformList,
    _ to: borrowing WebCore.Style.TransformList,
    start: Int,
    _ context: WebCore.BlendingContext,
    _ width: Float,
    _ height: Float,
    isDiscrete: Bool
) -> WebCore.Style.TransformFunction {
    let zoom = WebCore.Style.ZoomFactor.none().value
    var fromMatrix = WebCore.TransformationMatrix()
    applyStyleTransformList(from, from: start, to: &fromMatrix, width, height, zoom)
    var toMatrix = WebCore.TransformationMatrix()
    applyStyleTransformList(to, from: start, to: &toMatrix, width, height, zoom)
    var progress = context.progress
    var compositeOperation = context.compositeOperation
    if isDiscrete {
        progress = progress < 0.5 ? 0 : 1
        compositeOperation = .Replace
    }
    toMatrix.blend(fromMatrix, progress, compositeOperation)
    return WebCore.Style.styleMakeTransformFunction(WebCore.Style.Matrix3DTransformFunction.create(toMatrix).get())
}

// The functions at index of each list interpolated, or the one present interpolated to or from the identity. The
// function missing from from is interpolated from the identity by 1 - progress, with the context's other fields at
// their defaults.
@inline(always)
func blendedStyleTransformListFunction(
    _ from: borrowing WebCore.Style.TransformList,
    _ to: borrowing WebCore.Style.TransformList,
    at index: Int,
    _ context: WebCore.BlendingContext
) -> WebCore.Style.TransformFunction {
    let fromLength = from.size()
    let toLength = to.size()
    if index < fromLength && index < toLength {
        return blendStyleTransformFunction(
            to.function(index),
            from: from.function(index),
            context,
            toIdentity: false
        )
    }
    if index >= fromLength {
        return blendStyleTransformFunction(
            to.function(index),
            from: nil,
            WebCore.BlendingContext(1 - context.progress, false, .Replace, .Replace, 0),
            toIdentity: true
        )
    }
    return blendStyleTransformFunction(
        from.function(index),
        from: nil,
        context,
        toIdentity: true
    )
}

// The translate property interpolated: none and none give none, a missing function is the identity of the other's
// type, and two functions of different types are interpolated as translate3d() if either is 3D, else as translate().
@_expose(Cxx)
func styleTranslateBlend(
    _ from: consuming WebCore.Style.Translate,
    _ to: consuming WebCore.Style.Translate,
    _ context: WebCore.BlendingContext
) -> WebCore.Style.Translate {
    let fromFunction = from.function()
    let toFunction = to.function()
    guard fromFunction != nil || toFunction != nil else {
        return WebCore.Style.Translate(WebCore.CSS.Keyword.None())
    }
    let zero = WebCore.Style.TranslateTransformFunction.X(WebCore.Style.TranslateTransformFunction.Z(0))
    let fromValue =
        fromFunction
        ?? WebCore.Style.TranslateTransformFunction
        .create(
            zero,
            zero,
            WebCore.Style.TranslateTransformFunction.Z(0),
            toFunction!.type()
        )
        .get()
    let toValue =
        toFunction
        ?? WebCore.Style.TranslateTransformFunction
        .create(
            zero,
            zero,
            WebCore.Style.TranslateTransformFunction.Z(0),
            fromFunction!.type()
        )
        .get()
    if !fromValue.isSameType(toValue) {
        let is3D = fromValue.is3DOperation() || toValue.is3DOperation()
        let type: WebCore.Style.TransformFunctionType = is3D ? .Translate3D : .Translate
        let fromZ = is3D ? fromValue.z() : WebCore.Style.TranslateTransformFunction.Z(0)
        let toZ = is3D ? toValue.z() : WebCore.Style.TranslateTransformFunction.Z(0)
        return styleTranslateBlend(
            WebCore.Style.Translate(
                consuming: WebCore.Style.TranslateTransformFunction.create(fromValue.xValue(), fromValue.yValue(), fromZ, type)
            ),
            WebCore.Style.Translate(
                consuming: WebCore.Style.TranslateTransformFunction.create(toValue.xValue(), toValue.yValue(), toZ, type)
            ),
            context
        )
    }
    return WebCore.Style.Translate(
        consuming: WebCore.Style.TranslateTransformFunction.create(
            blendStyleLengthPercentage(fromValue.xValue(), toValue.xValue(), context),
            blendStyleLengthPercentage(fromValue.yValue(), toValue.yValue(), context),
            blendStyleLength(fromValue.z(), toValue.z(), context),
            toValue.type()
        )
    )
}

// The rotate property interpolated: none and none give none, a missing function is the identity of the other's
// type, and two functions of different types are interpolated as rotate3d() if either is 3D, else as rotate().
@_expose(Cxx)
func styleRotateBlend(
    _ from: consuming WebCore.Style.Rotate,
    _ to: consuming WebCore.Style.Rotate,
    _ context: WebCore.BlendingContext
) -> WebCore.Style.Rotate {
    let fromFunction = from.function()
    let toFunction = to.function()
    guard fromFunction != nil || toFunction != nil else {
        return WebCore.Style.Rotate(WebCore.CSS.Keyword.None())
    }
    let fromValue =
        fromFunction
        ?? WebCore.Style.RotateTransformFunction.create(.init(0.0), .init(0.0), .init(1.0), .init(0.0), toFunction!.type()).get()
    let toValue =
        toFunction
        ?? WebCore.Style.RotateTransformFunction.create(.init(0.0), .init(0.0), .init(1.0), .init(0.0), fromFunction!.type()).get()
    if !fromValue.isSameType(toValue) {
        if fromValue.is3DOperation() || toValue.is3DOperation() {
            return styleRotateBlend(
                WebCore.Style.Rotate(
                    consuming: WebCore.Style.RotateTransformFunction.create(
                        fromValue.x(),
                        fromValue.y(),
                        fromValue.z(),
                        fromValue.angle(),
                        .Rotate3D
                    )
                ),
                WebCore.Style.Rotate(
                    consuming: WebCore.Style.RotateTransformFunction.create(
                        toValue.x(),
                        toValue.y(),
                        toValue.z(),
                        toValue.angle(),
                        .Rotate3D
                    )
                ),
                context
            )
        }
        return styleRotateBlend(
            WebCore.Style.Rotate(
                consuming: WebCore.Style.RotateTransformFunction.create(
                    .init(0.0),
                    .init(0.0),
                    .init(1.0),
                    fromValue.angle(),
                    .Rotate
                )
            ),
            WebCore.Style.Rotate(
                consuming: WebCore.Style.RotateTransformFunction.create(
                    .init(0.0),
                    .init(0.0),
                    .init(1.0),
                    toValue.angle(),
                    .Rotate
                )
            ),
            context
        )
    }
    let blended = blendedStyleRotateValues(
        styleRotateTransformFunctionValues(toValue),
        of: toValue.type(),
        from: styleRotateTransformFunctionValues(fromValue),
        context,
        toIdentity: false,
        type: toValue.type()
    )
    return WebCore.Style.Rotate(
        consuming: WebCore.Style.RotateTransformFunction.create(
            .init(blended.x),
            .init(blended.y),
            .init(blended.z),
            .init(blended.angle),
            blended.type
        )
    )
}

// The scale property interpolated: none and none give none, a missing function is the identity of the other's
// type, and two functions of different types are interpolated as scale3d() if either is 3D, else as scale().
@_expose(Cxx)
func styleScaleBlend(
    _ from: consuming WebCore.Style.Scale,
    _ to: consuming WebCore.Style.Scale,
    _ context: WebCore.BlendingContext
) -> WebCore.Style.Scale {
    let fromFunction = from.function()
    let toFunction = to.function()
    guard fromFunction != nil || toFunction != nil else {
        return WebCore.Style.Scale(WebCore.CSS.Keyword.None())
    }
    let fromValue =
        fromFunction ?? WebCore.Style.ScaleTransformFunction.create(.init(1.0), .init(1.0), .init(1.0), toFunction!.type()).get()
    let toValue = toFunction ?? WebCore.Style.ScaleTransformFunction.create(.init(1.0), .init(1.0), .init(1.0), fromFunction!.type()).get()
    if !fromValue.isSameType(toValue) {
        let is3D = fromValue.is3DOperation() || toValue.is3DOperation()
        let type: WebCore.Style.TransformFunctionType = is3D ? .Scale3D : .Scale
        return styleScaleBlend(
            WebCore.Style.Scale(
                consuming: WebCore.Style.ScaleTransformFunction.create(
                    fromValue.x(),
                    fromValue.y(),
                    is3D ? fromValue.z() : .init(1.0),
                    type
                )
            ),
            WebCore.Style.Scale(
                consuming: WebCore.Style.ScaleTransformFunction.create(
                    toValue.x(),
                    toValue.y(),
                    is3D ? toValue.z() : .init(1.0),
                    type
                )
            ),
            context
        )
    }
    let blended = blendedStyleScaleValues(
        styleScaleTransformFunctionValues(toValue),
        from: styleScaleTransformFunctionValues(fromValue),
        context,
        toIdentity: false
    )
    return WebCore.Style.Scale(
        consuming: WebCore.Style.ScaleTransformFunction.create(
            .init(blended.x),
            .init(blended.y),
            .init(blended.z),
            toValue.type()
        )
    )
}

// A rotation's axis and angle, and a scale's factors, as blendedStyleRotateValues() and blendedStyleScaleValues()
// take them.
func styleRotateTransformFunctionValues(
    _ rotate: WebCore.Style.RotateTransformFunction
) -> WebCore.Style.StyleTransformFunctionValues {
    .init(x: rotate.x().value, y: rotate.y().value, z: rotate.z().value, angle: rotate.angle().value)
}

func styleScaleTransformFunctionValues(
    _ scale: WebCore.Style.ScaleTransformFunction
) -> WebCore.Style.StyleTransformFunctionValues {
    .init(x: scale.x().value.value, y: scale.y().value.value, z: scale.z().value.value, angle: 0)
}
