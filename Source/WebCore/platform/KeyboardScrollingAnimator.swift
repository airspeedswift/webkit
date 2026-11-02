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

// Helpers for KeyboardScrollingAnimator's members on macOS, which are ScrollPhysicsController methods, and the keyboard
// event's scroll direction and granularity functions EventHandler calls. Main thread only; the direction and
// granularity functions read only their arguments.

internal import WebCore_Private.Core.KeyboardScroll
internal import WebCore_Private.Core.PlatformEvent
internal import WebCore_Private.Core.ScrollTypes
internal import WebCore_Private.ScrollAnimatorScrollPhysicsClient
internal import WebCore_Private.ScrollPhysicsTypes
internal import wtf.Core.text.Latin1Character
internal import wtf.Core.text.WTFString

extension ScrollPhysicsController {
    func keyboardScrollingAnimatorMakeKeyboardScroll(
        _ c: inout MainThreadScrollPhysicsClient,
        _ direction: WebCore.ScrollDirection,
        _ granularity: WebCore.ScrollGranularity
    ) -> WebCore.KeyboardScroll? {
        let distance = keyboardScrollingAnimatorScrollDistance(&c, direction, granularity)

        if distance == 0 {
            return nil
        }

        let parameters = WebCore.KeyboardScrollParameters.parameters()
        let offset = ScrollSize(WebCore.unitVectorForScrollDirection(direction)).scaled(distance)
        let maximumVelocity = offset.scaled(parameters.maximumVelocityMultiplier)

        var scroll = WebCore.KeyboardScroll()
        scroll.offset = offset.floatSize
        scroll.granularity = granularity
        scroll.direction = direction
        scroll.maximumVelocity = maximumVelocity.floatSize
        scroll.force = maximumVelocity.scaled(parameters.springMass / parameters.timeToMaximumVelocity).floatSize
        return scroll
    }

    // Scrolls to the edge of the document the same way as the Home and End keys.
    func keyboardScrollingAnimatorScrollToDocumentEdge(_ c: inout MainThreadScrollPhysicsClient, _ direction: WebCore.ScrollDirection) {
        scrollableAreaEndKeyboardScroll(&c, false)
        _ = scrollableAreaScroll(&c, direction, .Document, 1)
    }

    // Requests a delta rather than a position, so that the scroll starts from the latest position rather than from this
    // one, which may be out of date while an animation runs, such as one that scrolls to the edge of the document.
    func keyboardScrollingAnimatorScrollByPage(_ c: inout MainThreadScrollPhysicsClient, _ offset: ScrollSize) {
        scrollableAreaEndKeyboardScroll(&c, false)
        let currentPosition = ScrollPoint(c.currentPosition())
        let minimum = ScrollPoint(c.minimumScrollPosition())
        let maximum = ScrollPoint(c.maximumScrollPosition())
        let newPosition = (currentPosition + offset).constrainedBetween(minimum, maximum)
        if newPosition != currentPosition {
            scrollableAreaScrollToPositionWithAnimation(&c, newPosition.floatPoint, options: .createProgrammaticWithOptions(.Clamped, .No, .Closest, .init((newPosition - currentPosition).floatSize)))
        }
    }

    // The scrollbar's step for the granularity; 0 with no scrollbar in the direction.
    private func keyboardScrollingAnimatorScrollDistance(
        _ c: inout MainThreadScrollPhysicsClient,
        _ direction: WebCore.ScrollDirection,
        _ granularity: WebCore.ScrollGranularity
    ) -> Float {
        let axis = WebCore.axisFromDirection(direction)
        let orientation: WebCore.ScrollbarOrientation = axis == .Horizontal ? .Horizontal : .Vertical
        if !c.hasScrollbar(orientation) {
            return 0
        }

        var step: Float = 0
        switch granularity {
        case .Line:
            step = Float(c.scrollbarLineStep(orientation))
        case .Page:
            step = Float(c.scrollbarPageStep(orientation))
        case .Document:
            step = Float(c.scrollbarTotalSize(orientation))
        case .Pixel:
            step = c.scrollbarPixelStep(orientation)
        @unknown default:
            break
        }

        if granularity == .Page && axis == .Vertical {
            step = c.adjustVerticalPageScrollStepForFixedContent(step)
        }

        return step
    }
}

// The keys KeyboardScrollingAnimator scrolls for.
private enum KeyboardScrollingKey {
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
    case space
    case pageUp
    case pageDown
    case home
    case end
}

private protocol KeyIdentifierCodeUnit {
    var keyIdentifierCodeUnit: UInt64 { get }
}

extension WTF.Latin1Character: KeyIdentifierCodeUnit {
    fileprivate var keyIdentifierCodeUnit: UInt64 { UInt64(value) }
}

extension UInt16: KeyIdentifierCodeUnit {
    fileprivate var keyIdentifierCodeUnit: UInt64 { UInt64(self) }
}

extension UInt8: KeyIdentifierCodeUnit {
    fileprivate var keyIdentifierCodeUnit: UInt64 { UInt64(self) }
}

// The identifier as PackedASCIILiteral<uint64_t>::parse() packs it: nil when longer than 8 code units or when any unit
// is not ASCII; otherwise the units from the high byte down, zero-filled, so trailing NULs are not told apart.
private func packedKeyIdentifier<Unit: KeyIdentifierCodeUnit>(_ units: Span<Unit>) -> UInt64? {
    let capacity = MemoryLayout<UInt64>.size
    if units.count > capacity {
        return nil
    }
    var result: UInt64 = 0
    for index in 0..<capacity {
        let code = index < units.count ? units[index].keyIdentifierCodeUnit : 0
        if code & ~0x7F != 0 {
            return nil
        }
        result = result << 8 | code
    }
    return result
}

private func packedKeyName(_ name: Swift.String, _ key: KeyboardScrollingKey) -> (UInt64, KeyboardScrollingKey) {
    let units = Array(name.utf8)
    // Every name is ASCII and at most 8 characters long, so it packs.
    guard let identifier = packedKeyIdentifier(units.span) else {
        preconditionFailure()
    }
    return (identifier, key)
}

private let keyboardScrollingKeyIdentifiers = [
    packedKeyName("Down", .downArrow),
    packedKeyName("End", .end),
    packedKeyName("Home", .home),
    packedKeyName("Left", .leftArrow),
    packedKeyName("PageDown", .pageDown),
    packedKeyName("PageUp", .pageUp),
    packedKeyName("Right", .rightArrow),
    packedKeyName("Up", .upArrow),
]

// keyboardScrollingKeyForKeyboardEvent(), from the platform event's type, key identifier and text.
private func keyboardScrollingKey(
    _ type: WebCore.PlatformEventType,
    _ keyIdentifier: borrowing WTF.String,
    _ text: borrowing WTF.String
) -> KeyboardScrollingKey? {
    // PlatformEvent::Type::Char is a "keypress" event.
    if !(type == .RawKeyDown || type == .Char) {
        return nil
    }

    let packedIdentifier: UInt64?
    if keyIdentifier.is8Bit() {
        let units: Span<WTF.Latin1Character> = keyIdentifier.span8()
        packedIdentifier = packedKeyIdentifier(units)
    } else {
        let units: Span<UInt16> = keyIdentifier.span16()
        packedIdentifier = packedKeyIdentifier(units)
    }
    if let packedIdentifier {
        for (identifier, key) in keyboardScrollingKeyIdentifiers where identifier == packedIdentifier {
            return key
        }
    }

    // String::codePointAt(0) == ' ': no other code point it returns starts with the unit 0x20.
    let firstCodeUnit: UInt16?
    if text.is8Bit() {
        let units: Span<WTF.Latin1Character> = text.span8()
        firstCodeUnit = units.isEmpty ? nil : UInt16(units[0].value)
    } else {
        let units: Span<UInt16> = text.span16()
        firstCodeUnit = units.isEmpty ? nil : units[0]
    }
    if firstCodeUnit == 0x20 {
        return .space
    }

    return nil
}

private func hasModifier(_ modifiers: UInt8, _ modifier: WebCore.PlatformEventModifier) -> Bool {
    modifiers & modifier.rawValue != 0
}

// scrollDirectionForKeyboardEvent(), from the platform event's type, key identifier and text and the DOM event's
// modifiers.
@_expose(Cxx)
func keyboardScrollDirection(
    _ type: WebCore.PlatformEventType,
    _ keyIdentifier: consuming WTF.String,
    _ text: consuming WTF.String,
    _ modifiers: UInt8
) -> WebCore.OptionalScrollDirection {
    guard let key = keyboardScrollingKey(type, keyIdentifier, text) else {
        return WebCore.OptionalScrollDirection()
    }

    // FIXME (bug 227459): This logic does not account for writing-mode.
    switch key {
    case .leftArrow:
        return WebCore.OptionalScrollDirection(.left)
    case .rightArrow:
        return WebCore.OptionalScrollDirection(.right)
    case .upArrow, .pageUp, .home:
        return WebCore.OptionalScrollDirection(.up)
    case .downArrow, .pageDown, .end:
        return WebCore.OptionalScrollDirection(.down)
    case .space:
        return WebCore.OptionalScrollDirection(hasModifier(modifiers, .ShiftKey) ? .up : .down)
    }
}

// scrollGranularityForKeyboardEvent(), from the same values.
@_expose(Cxx)
func keyboardScrollGranularity(
    _ type: WebCore.PlatformEventType,
    _ keyIdentifier: consuming WTF.String,
    _ text: consuming WTF.String,
    _ modifiers: UInt8
) -> WebCore.OptionalScrollGranularity {
    guard let key = keyboardScrollingKey(type, keyIdentifier, text) else {
        return WebCore.OptionalScrollGranularity()
    }

    // FIXME (bug 227459): This logic does not account for writing-mode.
    switch key {
    case .leftArrow, .rightArrow:
        if hasModifier(modifiers, .ShiftKey) || hasModifier(modifiers, .MetaKey) {
            return WebCore.OptionalScrollGranularity()
        }
        if hasModifier(modifiers, .AltKey) {
            return WebCore.OptionalScrollGranularity(.Page)
        }
        return WebCore.OptionalScrollGranularity(.Line)
    case .upArrow, .downArrow:
        if hasModifier(modifiers, .ShiftKey) {
            return WebCore.OptionalScrollGranularity()
        }
        if hasModifier(modifiers, .MetaKey) {
            // Meta is the only modifier, of all six.
            if modifiers.nonzeroBitCount == 1 {
                return WebCore.OptionalScrollGranularity(.Document)
            }
            return WebCore.OptionalScrollGranularity()
        }
        if hasModifier(modifiers, .AltKey) {
            return WebCore.OptionalScrollGranularity(.Page)
        }
        return WebCore.OptionalScrollGranularity(.Line)
    case .space, .pageUp, .pageDown:
        return WebCore.OptionalScrollGranularity(.Page)
    case .home, .end:
        return WebCore.OptionalScrollGranularity(.Document)
    }
}
