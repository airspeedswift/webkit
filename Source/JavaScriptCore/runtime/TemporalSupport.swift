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

// Shared helpers for JavaScriptCore's Temporal code in Swift: errors, results, string building and parsing.
// Every name at module scope starts with `Temporal` or `temporal`, because JSCSwift holds other code too.

internal import CxxStdlib
internal import JSCSwiftBoundary
// The boundary's headers reach JavaScriptCore classes that are defined in other private headers.
internal import JavaScriptCore_Private.Cxx

// MARK: - Namespaces

/// Swift counterparts of `JSC::ISO8601`'s functions, under their C++ names.
///
/// Each Swift file extends it.
enum TemporalISO8601 {}

/// Swift counterparts of `JSC::TemporalCore`'s functions, under their C++ names.
///
/// Each Swift file extends it.
enum TemporalOperations {}

// MARK: - Errors

/// A failed Temporal operation: the kind of exception it becomes, and its message.
///
/// A message is an ASCII literal or a `WTF::String` taken from a C++ `TemporalError`.
struct TemporalFailure {
    enum Message {
        case literal(Swift.String)
        case string(WTF.String)
    }

    var kind: JSC.TemporalErrorKind
    var message: Message

    static func range(_ message: Swift.String) -> TemporalFailure {
        TemporalFailure(kind: .RangeError, message: .literal(message))
    }

    static func type(_ message: Swift.String) -> TemporalFailure {
        TemporalFailure(kind: .TypeError, message: .literal(message))
    }

    /// The error a C++ function returned, unchanged.
    init(_ error: JSC.TemporalError) {
        self.kind = error.kind
        self.message = .string(error.message)
    }

    init(kind: JSC.TemporalErrorKind, message: Message) {
        self.kind = kind
        self.message = message
    }

    /// The message as a `WTF::String`.
    var messageString: WTF.String {
        switch message {
        case .literal(let text):
            temporalStringFromASCII(text)
        case .string(let string):
            string
        }
    }

    /// The `TemporalError` with the same kind and message.
    var temporalError: JSC.TemporalError {
        JSC.TemporalError(kind: kind, message: messageString)
    }
}

/// A `WTF::String` with the bytes of an ASCII literal.
///
/// Error paths only: it allocates.
func temporalStringFromASCII(_ text: Swift.String) -> WTF.String {
    WTF.String(WTF.latin1CharactersOfBytes(text.utf8Span.span))
}

/// The result of a Temporal operation in Swift.
///
/// C++ sees it only through `store(_:_:)`, in a function the C++ calls. (`Swift.Result` needs an `Error`, which must be
/// `Sendable`, and `WTF::String` is not.)
enum TemporalOutcome<Value> {
    case success(Value)
    case failure(TemporalFailure)

    /// Writes the value, or the error's kind, into a function's out-parameters, and returns the error's message: null
    /// on success, which `temporalResult` reads as success.
    @inline(always)
    consuming func store(_ value: inout Value, _ kind: inout JSC.TemporalErrorKind) -> WTF.String {
        switch consume self {
        case .success(let result):
            value = result
            return WTF.String()
        case .failure(let failure):
            kind = failure.kind
            return failure.messageString
        }
    }

    var failure: TemporalFailure? {
        if case .failure(let failure) = self {
            return failure
        }
        return nil
    }
}

extension TemporalOutcome where Value == Void {
    consuming func store(_ kind: inout JSC.TemporalErrorKind) -> WTF.String {
        switch consume self {
        case .success:
            return WTF.String()
        case .failure(let failure):
            kind = failure.kind
            return failure.messageString
        }
    }
}

// Functions that the C++ calls: an `inout` parameter after the others is the out-parameter of `temporalOutput`,
// `temporalOptionalOutput`, `temporalOptionalParse`, `temporalResult` or `temporalVoidResult`: a local of that helper,
// passed to this function alone, so it is exclusive for the call. Any other `inout` parameter is stated at its
// function. A parameter received by value (`const T&` in the generated header) is assumed unchanged for the call: it
// is the caller's argument, and the C++ that the Swift calls (the ICU bridge functions, WTF's date math,
// `epochCandidates`) is given values, not a reference to it.

/// Calendar fields and the error of the operation that made them, as one value for a function to return.
func temporalCalendarFieldsOutcome(
    _ fields: JSC.TemporalCore.CalendarFieldsIn,
    _ failure: TemporalFailure?
) -> JSC.TemporalCore.TemporalCalendarFieldsOutcome {
    var outcome = JSC.TemporalCore.TemporalCalendarFieldsOutcome()
    outcome.fields = fields
    if let failure {
        outcome.error = failure.temporalError
    }
    return outcome
}

/// The value of an optional that the caller has established is present.
///
/// Traps when it is empty.
func temporalValue<T>(_ optional: T?) -> T {
    guard let optional else {
        preconditionFailure()
    }
    return optional
}

/// Writes an optional's value into a function's out-parameter, and returns whether it has one; the out-parameter is
/// left as the caller made it when there is none.
func temporalStore<T>(_ optional: T?, _ value: inout T) -> Bool {
    guard let optional else {
        return false
    }
    value = optional
    return true
}

// MARK: - Building strings

/// A `WTF::String` built in fixed inline storage, for formatted output and messages.
///
/// Appending past `capacity` traps: each caller states the bound of what it writes.
struct TemporalStringBuilder: ~Copyable {
    static var capacity: Int { 128 }

    private var characters: [128 of WTF.Latin1Character]
    private(set) var count: Int

    init() {
        characters = .init(repeating: WTF.Latin1Character())
        count = 0
    }

    mutating func append(_ byte: UInt8) {
        characters[count].value = byte
        count += 1
    }

    /// Appends ASCII `text`, a literal.
    mutating func append(ascii text: Swift.String) {
        for byte in text.utf8 {
            append(byte)
        }
    }

    /// Appends `value` in decimal, as `makeString(value)` does.
    mutating func append<T: BinaryInteger>(decimal value: T) {
        append(decimal: value, paddedTo: 0)
    }

    /// Appends `value` in decimal after enough zeros to make at least `width` characters, as
    /// `makeString(pad('0', width, value))` does.
    ///
    /// The zeros go before a minus sign: (-5, 3) gives `0-5`.
    mutating func append<T: BinaryInteger>(decimal value: T, paddedTo width: Int) {
        var digits: [40 of UInt8] = .init(repeating: 0)
        var digitCount = 0
        var magnitude = value.magnitude
        repeat {
            // A digit 0-9 plus '0' is at most '9'.
            digits[digitCount] = UInt8(truncatingIfNeeded: magnitude % 10) &+ UInt8(ascii: "0")
            digitCount += 1
            magnitude /= 10
        } while magnitude != 0
        let isNegative = value < 0
        var padding = width - digitCount - (isNegative ? 1 : 0)
        while padding > 0 {
            append(UInt8(ascii: "0"))
            padding -= 1
        }
        if isNegative {
            append(UInt8(ascii: "-"))
        }
        while digitCount > 0 {
            digitCount -= 1
            append(digits[digitCount])
        }
    }

    /// The characters appended so far, as an 8-bit `WTF::String`.
    func makeString() -> WTF.String {
        WTF.String(characters.span.extracting(0..<count))
    }
}

// MARK: - Parsing

/// The code units of an 8-bit (`UInt8`, Latin-1) or 16-bit (`UInt16`, UTF-16) string.
protocol TemporalCodeUnit: FixedWidthInteger, UnsignedInteger, BitwiseCopyable {}
extension UInt8: TemporalCodeUnit {}
extension UInt16: TemporalCodeUnit {}

/// Whether `unit` is the ASCII character `ascii`.
///
/// The ASCII byte is widened, so a 16-bit unit such as U+0154 never matches `T`.
@inline(always)
func temporalIs<Unit: TemporalCodeUnit>(_ unit: Unit, _ ascii: UInt8) -> Bool {
    unit == Unit(ascii)
}

/// `isASCIIDigit`.
@inline(always)
func temporalIsASCIIDigit<Unit: TemporalCodeUnit>(_ unit: Unit) -> Bool {
    unit >= Unit(UInt8(ascii: "0")) && unit <= Unit(UInt8(ascii: "9"))
}

/// `isASCIIAlpha`.
@inline(always)
func temporalIsASCIIAlpha<Unit: TemporalCodeUnit>(_ unit: Unit) -> Bool {
    let lower = unit | 0x20
    return lower >= Unit(UInt8(ascii: "a")) && lower <= Unit(UInt8(ascii: "z"))
}

/// `toASCIIUpper`: ASCII letters only, every other unit unchanged.
@inline(always)
func temporalToASCIIUpper<Unit: TemporalCodeUnit>(_ unit: Unit) -> Unit {
    unit >= Unit(UInt8(ascii: "a")) && unit <= Unit(UInt8(ascii: "z")) ? unit & ~0x20 : unit
}

/// The value of an ASCII digit.
///
/// The caller has checked `temporalIsASCIIDigit`.
@inline(always)
func temporalDigitValue<Unit: TemporalCodeUnit>(_ unit: Unit) -> Int32 {
    // The caller has checked that the unit is at least '0'.
    Int32(truncatingIfNeeded: unit &- Unit(UInt8(ascii: "0")))
}

/// Whether `unit` is in the ASCII range `low`...`high`.
@inline(always)
func temporalIsInASCIIRange<Unit: TemporalCodeUnit>(_ unit: Unit, _ low: UInt8, _ high: UInt8) -> Bool {
    unit >= Unit(low) && unit <= Unit(high)
}

/// `isASCIILower`.
@inline(always)
func temporalIsASCIILower<Unit: TemporalCodeUnit>(_ unit: Unit) -> Bool {
    temporalIsInASCIIRange(unit, UInt8(ascii: "a"), UInt8(ascii: "z"))
}

/// A `Latin1Character` holding `unit`, narrowed as `Vector<Latin1Character>(span)` narrows.
///
/// Every caller passes an ASCII unit.
@inline(always)
func temporalLatin1Character<Unit: TemporalCodeUnit>(_ unit: Unit) -> WTF.Latin1Character {
    var character = WTF.Latin1Character()
    character.value = UInt8(truncatingIfNeeded: unit)
    return character
}

/// A position in a string's code units, as WTF's `StringParsingBuffer`: reading at or past the end traps,
/// as the hardened `std::span` under `StringParsingBuffer` does.
struct TemporalCursor<Unit: TemporalCodeUnit>: ~Escapable {
    let characters: Span<Unit>
    private(set) var position: Int

    @_lifetime(copy characters)
    init(_ characters: Span<Unit>) {
        self.characters = characters
        self.position = 0
    }

    var atEnd: Bool { position >= characters.count }
    var hasCharactersRemaining: Bool { position < characters.count }
    // Cannot overflow: position is never past the end, as every way of moving it checks.
    var lengthRemaining: Int { characters.count &- position }

    /// `*buffer`.
    var current: Unit { characters[position] }

    /// `buffer[offset]`.
    subscript(offset: Int) -> Unit { characters[position + offset] }

    /// `++buffer`.
    mutating func advance() {
        precondition(position < characters.count)
        position += 1
    }

    /// `buffer.advanceBy(count)`.
    mutating func advance(by count: Int) {
        precondition(count <= lengthRemaining)
        position += count
    }

    /// `buffer.advanceBy(count)` where the caller has checked `count <= lengthRemaining`.
    mutating func advance(checkedCount count: Int) {
        position &+= count // Cannot overflow: the caller's check keeps the sum at most characters.count.
    }

    /// `buffer.consume()`: the current unit, then advances.
    mutating func consume() -> Unit {
        let unit = characters[position]
        position += 1
        return unit
    }

    /// `buffer.consume(count)`: the next `count` units, then advances past them.
    @_lifetime(copy self)
    mutating func consume(_ count: Int) -> Span<Unit> {
        let consumed = characters.extracting(position..<position + count)
        position += count
        return consumed
    }

    /// Whether the current unit is the ASCII character `ascii`; false at the end.
    func at(_ ascii: UInt8) -> Bool {
        hasCharactersRemaining && temporalIs(current, ascii)
    }

    /// Consumes the current unit if it is `ascii`.
    mutating func skip(_ ascii: UInt8) -> Bool {
        guard at(ascii) else {
            return false
        }
        position += 1
        return true
    }
}

// MARK: - Constants of ExactTime

extension TemporalISO8601 {
    // Nanoseconds per unit as `Int64`: `ExactTime`'s constants below, each of which fits.
    static var nsPerHour: Int64 { Int64(truncatingIfNeeded: TemporalExactTime.nsPerHour) }
    static var nsPerMinute: Int64 { Int64(truncatingIfNeeded: TemporalExactTime.nsPerMinute) }
    static var nsPerSecond: Int64 { Int64(truncatingIfNeeded: TemporalExactTime.nsPerSecond) }
    static var nsPerMillisecond: Int64 { Int64(truncatingIfNeeded: TemporalExactTime.nsPerMillisecond) }
    static var nsPerMicrosecond: Int64 { Int64(truncatingIfNeeded: TemporalExactTime.nsPerMicrosecond) }
}

/// The values of `ExactTime`'s `static constexpr Int128` members, which the importer drops.
///
/// The first four are pinned by `static_assert`s in ISO8601.cpp, and the rest are derived from them as ISO8601.h
/// derives them.
enum TemporalExactTime {
    static var dayRangeSeconds: Int128 { 8_640_000_000_000 }
    static var nsPerMicrosecond: Int128 { 1_000 }
    static var nsPerMillisecond: Int128 { 1_000_000 }
    static var nsPerSecond: Int128 { 1_000_000_000 }
    static var nsPerMinute: Int128 { nsPerSecond * 60 }
    static var nsPerHour: Int128 { nsPerMinute * 60 }
    static var nsPerDay: Int128 { nsPerHour * 24 }
    static var minValue: Int128 { -dayRangeSeconds * nsPerSecond }
    static var maxValue: Int128 { dayRangeSeconds * nsPerSecond }
}

/// The value of `InternalDuration::maxTimeDuration`, 2^53 × 10^9 − 1.
enum TemporalInternalDuration {
    static var maxTimeDuration: Int128 { 9_007_199_254_740_991_999_999_999 }
}

/// `absInt128` (FractionToDouble.h, a `static constexpr` function, which does not import). `Int128.min` wraps
/// to itself.
@inline(always)
func temporalAbsInt128(_ value: Int128) -> Int128 {
    value < 0 ? 0 &- value : value // Wraps for Int128.min, as above.
}

// MARK: - Conversions from double

/// `static_cast<int64_t>(double)` as arm64 compiles it (`fcvtzs`): truncates toward zero, saturates out of range,
/// and gives 0 for NaN.
///
/// Its callers pass integral increments.
@inline(always)
func temporalTruncatingInt64(_ value: Double) -> Int64 {
    if value.isNaN {
        return 0
    }
    if value >= 9_223_372_036_854_775_808.0 {
        return .max
    }
    if value < -9_223_372_036_854_775_808.0 {
        return .min
    }
    return Int64(value)
}

/// `static_cast<Int128>(double)` as compiler-rt's `__fixdfti` computes it: truncates toward zero; gives the limit
/// of the input's sign for NaN, infinities and magnitudes from 2^128; and wraps magnitudes in [2^127, 2^128) (its
/// shift into the sign bit).
@inline(always)
func temporalTruncatingInt128(_ value: Double) -> Int128 {
    if value.magnitude < 0x1p63 {
        return Int128(Int64(value))
    }
    if value.isNaN || value.magnitude >= 0x1p128 {
        return value.sign == .minus ? .min : .max
    }
    if value.magnitude >= 0x1p127 {
        let wrapped = Int128(truncatingIfNeeded: UInt128(value.magnitude))
        return value.sign == .minus ? 0 &- wrapped : wrapped // Wraps as __fixdfti's negation does.
    }
    return Int128(value)
}

// MARK: - Conversions to double

/// `static_cast<double>(Int128)` as compiler-rt's `__floattidf` computes it: rounds to nearest, ties to even.
///
/// A value that fits in 64 bits converts directly. Otherwise the top 64 bits of the magnitude, with any lower bit
/// set folded into the lowest one, round to the same double as the whole magnitude, which is then scaled exactly by
/// a power of two.
@inline(always)
func temporalDouble(_ value: Int128) -> Double {
    let small = Int64(truncatingIfNeeded: value)
    if Int128(small) == value {
        return Double(small)
    }
    let magnitude = value.magnitude
    let high = UInt64(truncatingIfNeeded: magnitude &>> 64)
    // shift is in 0...64: the top 64 bits of the magnitude start at bit shift.
    let shift = 64 - high.leadingZeroBitCount
    var top = UInt64(truncatingIfNeeded: magnitude &>> shift)
    if shift > 0 && magnitude &<< (128 - shift) != 0 {
        top |= 1
    }
    // 2^shift, exactly: shift + 1023 is a normal exponent.
    let scale = Double(bitPattern: UInt64(shift + 1023) << 52)
    let result = Double(top) * scale
    return value < 0 ? -result : result
}

/// `a / b` and `a % b` on `Int128` as arm64 computes them (compiler-rt's `__divti3` and `__modti3`, whose `udiv`
/// does not trap): a zero divisor gives a quotient of 0 and a remainder of `a`, and `Int128.min / -1` gives
/// `Int128.min` with a remainder of 0.
@inline(always)
func temporalDivideInt128(_ a: Int128, _ b: Int128) -> (quotient: Int128, remainder: Int128) {
    // Both truncate toward zero, so where a and b fit in Int64 the 64-bit division gives the same quotient and
    // remainder, except for Int64.min / -1, whose quotient Int64 cannot hold.
    let a64 = Int64(truncatingIfNeeded: a)
    let b64 = Int64(truncatingIfNeeded: b)
    if Int128(a64) == a && Int128(b64) == b && b64 > 0 {
        let (quotient, remainder) = a64.quotientAndRemainder(dividingBy: b64)
        return (Int128(quotient), Int128(remainder))
    }
    return temporalDivideInt128Wide(a, b)
}

@inline(never)
private func temporalDivideInt128Wide(_ a: Int128, _ b: Int128) -> (quotient: Int128, remainder: Int128) {
    if b == 0 {
        return (0, a)
    }
    return (a.dividedReportingOverflow(by: b).partialValue, a.remainderReportingOverflow(dividingBy: b).partialValue)
}

// MARK: - Comparing and appending strings

/// The characters of `characters[positions]`, which are ASCII, as a `Vector<Latin1Character>`.
func temporalLatin1Vector<Unit: TemporalCodeUnit>(_ characters: Span<Unit>, _ positions: Range<Int>) -> JSC.TemporalLatin1Vector {
    let source = characters.extracting(positions)
    var vector = JSC.TemporalLatin1Vector(source.count)
    for i in source.indices {
        vector[i] = temporalLatin1Character(source[i])
    }
    return vector
}

/// `StringView == "literal"_s`: same length and the same characters, the ASCII byte widened as in `temporalIs`.
func temporalEquals<Unit: TemporalCodeUnit>(_ characters: Span<Unit>, ascii text: Swift.String) -> Bool {
    var index = 0
    for byte in text.utf8 {
        if index >= characters.count || !temporalIs(characters[index], byte) {
            return false
        }
        index += 1
    }
    return index == characters.count
}

extension TemporalStringBuilder {
    /// Appends Latin-1 `characters` (for example a `String`'s `span8()`).
    mutating func append(characters: Span<WTF.Latin1Character>) {
        for index in characters.indices {
            append(characters[index].value)
        }
    }
}

// MARK: - Checked Int128

/// `CheckedInt128` (`Checked<Int128, RecordOverflow>`): an `Int128` that records whether any operation that made
/// it overflowed.
///
/// Its value is meaningless once it has overflowed.
struct TemporalCheckedInt128 {
    private(set) var value: Int128
    private(set) var hasOverflowed: Bool

    init(_ value: Int128) {
        self.value = value
        self.hasOverflowed = false
    }

    /// The `CheckedInt128` that `checkedCastDoubleToInt128` returns: overflowed when the cast has no value.
    init(_ value: Int128?) {
        self.value = value ?? 0
        self.hasOverflowed = value == nil
    }

    /// `CheckedInt128(a) * b`.
    static func * (lhs: TemporalCheckedInt128, rhs: Int128) -> TemporalCheckedInt128 {
        var product = lhs
        let (value, overflow) = lhs.value.multipliedReportingOverflow(by: rhs)
        product.value = value
        product.hasOverflowed = lhs.hasOverflowed || overflow
        return product
    }

    /// `checked += other`: overflowed if either was, or if the sum overflows.
    static func += (lhs: inout TemporalCheckedInt128, rhs: TemporalCheckedInt128) {
        let (value, overflow) = lhs.value.addingReportingOverflow(rhs.value)
        lhs.value = value
        lhs.hasOverflowed = lhs.hasOverflowed || rhs.hasOverflowed || overflow
    }
}
