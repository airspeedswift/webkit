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


// Without these, no operator in this file type-checks: WebCore's C++ operators name types these modules define.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch

internal import WebCore_Private.Core.CSSPropertyConsumerSwiftBuilders
internal import WebCore_Private.Core.CSSPropertyConsumerSwiftTypes

// The consumers of CSSPropertyParserConsumer+Easing.cpp: consumeEasingFunction and consumeUnresolvedEasingFunction.

extension NumericComponent {
    /// cubic-bezier()'s `CSS::Number<CSS::ClosedUnitRange>`.
    static var closedUnitNumber: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelNumber), min: 0, max: 1) }
    /// spring()'s `CSS::Number<CSS::SpringEasingParameters::Positive>`.
    static var positiveNumber: Self { Self(type: UInt8(WebCore.CSSColorSwiftChannelNumber), min: .leastNonzeroMagnitude) }
}

extension PropertyParser {
    // <easing-function> = linear | ease | ease-in | ease-out | ease-in-out | step-start | step-end | <linear()> | <cubic-bezier()> | <steps()>
    // NOTE: also includes non-standard <spring()>.
    // https://drafts.csswg.org/css-easing/#typedef-easing-function
    // `consumeEasingFunction` returns the five keywords that are not steps as keyword values; `unresolved`,
    // `consumeUnresolvedEasingFunction`, gives every easing function to setEasingFunctionResult.
    mutating func easingFunction(unresolved: Bool, _ calc: PropertyCalc) -> PropertyValue? {
        typealias Consumer = WebCore.CSSPropertyConsumerSwiftConsumer
        let consumer = unresolved ? Consumer.UnresolvedEasingFunction : Consumer.EasingFunction
        let id = peekIdent()
        switch id {
        case .Linear, .Ease, .EaseIn, .EaseOut, .EaseInOut:
            if !unresolved {
                return consumeKeyword(peeked: id)
            }
            consumeIncludingWhitespace()
            return setEasingFunctionResult(consumer, .Invalid, id, WebCore.CSSImageSwiftParts())
        case .StepStart, .StepEnd:
            consumeIncludingWhitespace()
            return setEasingFunctionResult(consumer, .Invalid, id, WebCore.CSSImageSwiftParts())
        default:
            break
        }

        switch peekFunction() {
        case .Linear:
            return linearEasingFunction(consumer)
        case .CubicBezier:
            return numbersEasingFunction(consumer, .CubicBezier)
        case .Steps:
            return stepsEasingFunction(consumer, calc)
        case .Spring:
            guard contextEnables(UInt32(WebCore.CSSConsumerSwiftSpringTimingFunctionEnabled)) else {
                return nil
            }
            return numbersEasingFunction(consumer, .Spring)
        default:
            return nil
        }
    }

    /// setEasingFunctionResult of the easing function `function`, or of the keyword `keyword` if it is Invalid.
    private func setEasingFunctionResult(
        _ consumer: WebCore.CSSPropertyConsumerSwiftConsumer,
        _ function: WebCore.CSSValueID,
        _ keyword: WebCore.CSSValueID,
        numbers: WebCore.CSSColorSwiftComponents = WebCore.CSSColorSwiftComponents(),
        count: Double = 0,
        countCalc: UInt32 = UInt32.max,
        _ parts: consuming WebCore.CSSImageSwiftParts
    ) -> PropertyValue? {
        WebCore.setEasingFunctionResult(
            tokens.value,
            consumer.rawValue,
            function.rawValue,
            keyword.rawValue,
            numbers,
            count,
            countCalc,
            consuming: consume parts
        ).get()
    }

    // MARK: - steps()

    // <steps-easing-function> = steps( <integer>, <steps-easing-function-position>? )
    // <steps-easing-function-position> = jump-start | jump-end | jump-none | jump-both | start | end
    //
    // with range constraints, this is:
    //
    // <steps-easing-function> = steps( <integer [1,∞]>, jump-start )
    //                         | steps( <integer [1,∞]>, jump-end )
    //                         | steps( <integer [1,∞]>, jump-both )
    //                         | steps( <integer [1,∞]>, start )
    //                         | steps( <integer [1,∞]>, end )
    //                         | steps( <integer [2,∞]>, jump-none )
    // https://drafts.csswg.org/css-easing-2/#funcdef-steps
    private mutating func stepsEasingFunction(_ consumer: WebCore.CSSPropertyConsumerSwiftConsumer, _ calc: PropertyCalc) -> PropertyValue? {
        guard let function = beginFunction(.Steps) else {
            return nil
        }
        let countStart = index
        var steps = integerOrCalc(min: 1, calc)
        var position = WebCore.CSSValueID.End
        if steps != nil && consumeComma() {
            // Whatever token follows the comma is consumed.
            position = peekIdent()
            consumeIncludingWhitespace()
            switch position {
            case .JumpStart, .JumpEnd, .JumpBoth, .Start, .End:
                break
            case .JumpNone:
                // "The first parameter specifies the number of intervals in the function. It must be a
                //  positive integer greater than 0 unless the second parameter is jump-none in which
                //  case it must be a positive integer greater than 1."
                // The count is read again for its range.
                let positionEnd = index
                index = countStart
                steps = integerOrCalc(min: 2, calc)
                index = positionEnd
            default:
                steps = nil
            }
        }
        let parsed = steps != nil && atEnd
        endColorFunction(function, parsed)
        guard parsed, let steps else {
            return nil
        }
        return setEasingFunctionResult(
            consumer,
            .Steps,
            position,
            count: steps.number,
            countCalc: steps.calc,
            WebCore.CSSImageSwiftParts()
        )
    }

    // MARK: - linear()

    // <linear()> = linear( [ <number> && <percentage>{0,2} ]# )
    // https://drafts.csswg.org/css-easing-2/#funcdef-linear
    // A stop that is not one keeps what it consumed and ends the stops.
    private mutating func linearEasingFunction(_ consumer: WebCore.CSSPropertyConsumerSwiftConsumer) -> PropertyValue? {
        guard let function = beginFunction(.Linear) else {
            return nil
        }
        var hasStop = false
        var hasStops = false
        repeat {
            guard linearStop() else {
                break
            }
            hasStops = hasStop
            hasStop = true
        } while consumeComma()
        let parsed = hasStops && atEnd
        endColorFunction(function, parsed)
        guard parsed else {
            return nil
        }
        return setEasingFunctionResult(consumer, .Linear, .Invalid, WebCore.CSSImageSwiftParts())
    }

    // <linear-easing-function-stop> = <number> && <percentage>{0,2}
    // Gives the stop to appendLinearEasingStop.
    private mutating func linearStop() -> Bool {
        var stop = WebCore.CSSColorSwiftComponents()
        if consumeNumeric(&stop, 0, .number) {
            if consumeNumeric(&stop, 1, .percentage) {
                _ = consumeNumeric(&stop, 2, .percentage)
            }
        } else {
            guard consumeNumeric(&stop, 1, .percentage) else {
                return false
            }
            _ = consumeNumeric(&stop, 2, .percentage)
            guard consumeNumeric(&stop, 0, .number) else {
                return false
            }
        }
        WebCore.appendLinearEasingStop(tokens.value, stop)
        return true
    }

    // MARK: - cubic-bezier() and spring()

    // <cubic-bezier()> = cubic-bezier( [ <number [0,1]>, <number> ]#{2} )
    // https://drafts.csswg.org/css-easing-2/#funcdef-cubic-bezier
    // <spring()> = spring( <number [>0,∞]> <number [>0,∞]> <number [0,∞]> <number> )
    // Non-standard
    private mutating func numbersEasingFunction(
        _ consumer: WebCore.CSSPropertyConsumerSwiftConsumer,
        _ name: WebCore.CSSValueID
    ) -> PropertyValue? {
        guard let function = beginFunction(name) else {
            return nil
        }
        var numbers = WebCore.CSSColorSwiftComponents()
        let parsed = name == .CubicBezier ? cubicBezierArguments(&numbers) : springArguments(&numbers)
        endColorFunction(function, parsed)
        guard parsed else {
            return nil
        }
        return setEasingFunctionResult(consumer, name, .Invalid, numbers: numbers, WebCore.CSSImageSwiftParts())
    }

    private mutating func cubicBezierArguments(_ numbers: inout WebCore.CSSColorSwiftComponents) -> Bool {
        guard consumeNumeric(&numbers, 0, .closedUnitNumber), consumeComma(),
            consumeNumeric(&numbers, 1, .number), consumeComma(),
            consumeNumeric(&numbers, 2, .closedUnitNumber), consumeComma(),
            consumeNumeric(&numbers, 3, .number)
        else {
            return false
        }
        return atEnd
    }

    private mutating func springArguments(_ numbers: inout WebCore.CSSColorSwiftComponents) -> Bool {
        guard consumeNumeric(&numbers, 0, .positiveNumber),
            consumeNumeric(&numbers, 1, .positiveNumber),
            consumeNumeric(&numbers, 2, .nonnegativeNumber),
            consumeNumeric(&numbers, 3, .number)
        else {
            return false
        }
        return atEnd
    }
}

// MARK: - Filters

extension PropertyParser {
    // <'filter'> = none | <filter-value-list>
    // <filter-value-list> = [ <filter-function> | <url> ]+
    // <'-apple-color-filter'> = none | <-apple-color-filter-function>+
    // https://drafts.fxtf.org/filter-effects/#FilterProperty
    mutating func filter(_ consumer: WebCore.CSSPropertyConsumerSwiftConsumer) -> PropertyValue? {
        guard filterList(apple: consumer == .AppleColorFilter) else {
            return nil
        }
        // Null for UnresolvedFilter, whose CSS::Filter goes to setUnresolvedResult.
        return WebCore.makeFilterValue(tokens.value, consumer.rawValue, nil).get()
    }

    /// none, or the functions of a filter or an -apple-color-filter (`apple`), given to beginFilterValues and the
    /// filter appenders. Consumes nothing if there is neither, or if a url is not one; tokens after none are left.
    mutating func filterList(apple: Bool) -> Bool {
        WebCore.beginFilterValues(tokens.value, apple)
        if peekIdent() == .None {
            consumeIncludingWhitespace()
            return true
        }
        let start = index
        repeat {
            guard filterFunction(apple: apple) else {
                index = start
                return false
            }
        } while !atEnd
        return true
    }

    /// A url (not for -apple-color-filter), whose validity appendFilterURL decides, or a filter function.
    private mutating func filterFunction(apple: Bool) -> Bool {
        if !apple, let next = urlEnd() {
            // Both at most the token count, an Int from a UInt32.
            guard WebCore.appendFilterURL(tokens.value, UInt32(truncatingIfNeeded: index), UInt32(truncatingIfNeeded: next)) else {
                return false
            }
            index = next
            consumeWhitespace()
            return true
        }
        let id = peekFunction()
        switch id {
        case .Blur, .DropShadow:
            guard !apple else {
                return false
            }
        case .AppleInvertLightness:
            guard apple else {
                return false
            }
        case .Brightness, .Contrast, .Grayscale, .HueRotate, .Invert, .Opacity, .Saturate, .Sepia:
            break
        default:
            return false
        }
        guard let function = beginFunction(id) else {
            return false
        }
        let parsed: Bool
        switch id {
        case .AppleInvertLightness:
            // -apple-invert-lightness() takes no argument.
            parsed = atEnd
            if parsed {
                WebCore.appendFilterFunction(tokens.value, apple, id.rawValue, WebCore.CSSColorSwiftComponents())
            }
        case .DropShadow:
            parsed = dropShadow()
        default:
            // Every other function's argument is optional.
            var argument = WebCore.CSSColorSwiftComponents()
            if atEnd {
                parsed = true
            } else {
                let consumed: Bool
                switch id {
                case .Blur:
                    consumed = consumeNumeric(&argument, 0, .nonnegativeLength)
                case .HueRotate:
                    // hue-rotate() takes a unitless zero angle.
                    consumed = consumeNumeric(&argument, 0, .angle)
                case .Brightness, .Contrast, .Saturate:
                    consumed = consumeNumeric(&argument, 0, .nonnegativeNumber) || consumeNumeric(&argument, 0, .nonnegativePercentage)
                default:
                    consumed = consumeNumeric(&argument, 0, .clampUpperUnitNumber) || consumeNumeric(&argument, 0, .clampUpperPercentage)
                }
                parsed = consumed && atEnd
            }
            if parsed {
                WebCore.appendFilterFunction(tokens.value, apple, id.rawValue, argument)
            }
        }
        endColorFunction(function, parsed)
        return parsed
    }

    /// The end of the url token or url() at the next token, or nil if there is none.
    private mutating func urlEnd() -> Int? {
        if peekType() == UInt8(WebCore.UrlToken.rawValue) {
            return index &+ 1 // Below end.
        }
        let start = index
        guard let function = beginFunction(.Url) else {
            return nil
        }
        end = function.end
        index = start
        return function.next
    }

    // drop-shadow() = drop-shadow( [ <color>? && [<length>{2} <length [0,∞]>?] ] )
    // https://drafts.fxtf.org/filter-effects/#funcdef-filter-drop-shadow
    // Gives its color, x, y and blur to appendDropShadowFilter; all the arguments must be consumed, and x and y are
    // required.
    private mutating func dropShadow() -> Bool {
        var state = gradientColorState()
        var color = WebCore.CSSColorSwiftStopColor()
        var channels = WebCore.CSSColorSwiftComponents()
        var lengths = WebCore.CSSColorSwiftComponents()
        var hasX = false
        var hasY = false
        while !atEnd {
            if color.kind == UInt8(WebCore.CSSColorSwiftNoColor) {
                color = consumeStopColor(&state, &channels)
                if color.kind != UInt8(WebCore.CSSColorSwiftNoColor) {
                    continue
                }
            }
            guard !hasX else {
                break
            }
            hasX = consumeNumeric(&lengths, 0, .length)
            guard hasX else {
                break
            }
            hasY = consumeNumeric(&lengths, 1, .length)
            guard hasY else {
                break
            }
            // A blur that is not a non-negative length is left, and fails the function.
            _ = consumeNumeric(&lengths, 2, .nonnegativeLength)
        }
        guard hasY, atEnd else {
            return false
        }
        WebCore.appendDropShadowFilter(tokens.value, color, channels, lengths)
        return true
    }
}

extension NumericComponent {
    /// grayscale(), invert(), opacity() and sepia()'s `CSS::Number<CSS::ClosedUnitRangeClampUpper>` and
    /// `CSS::Percentage<CSS::ClosedPercentageRangeClampUpper>`.
    static var clampUpperUnitNumber: Self {
        Self(type: UInt8(WebCore.CSSColorSwiftChannelNumber), min: 0, max: 1, maxBehavior: UInt8(WebCore.CSS.RangeParseTimeBehavior.Clamp.rawValue))
    }
    static var clampUpperPercentage: Self {
        Self(type: UInt8(WebCore.CSSColorSwiftChannelPercentage), min: 0, max: 100, maxBehavior: UInt8(WebCore.CSS.RangeParseTimeBehavior.Clamp.rawValue))
    }
}
