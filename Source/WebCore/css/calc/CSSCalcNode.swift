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
internal import wtf.Core.MathExtras

internal import WebCore_Private.Core.CSSCalcSwiftTypes

// The C library's math functions (<cmath>).
#if canImport(Darwin)
internal import Darwin
#elseif canImport(ucrt)
internal import ucrt
#elseif canImport(Glibc)
internal import Glibc
#endif

// This file holds the calculation trees Swift owns while it works on a CSSCalc::Tree or a Style::Calculation::Tree,
// their conversion from and to the records those trees store (CSSCalcSwiftTypes.h), the records a CSSCalc::Tree is
// built in (CalcArena), and the math functions' executors.

// MARK: - CSSCalc::Type

/// `CSSCalc::Type`.
///
/// The backticks are required: unescaped, `WebCore.CSSCalc.Type` is the metatype of the namespace.
typealias CxxCalcType = WebCore.CSSCalc.`Type`

/// `CSSCalc::Type` as a record holds it: its seven exponents and its percent hint, one byte each, in the struct's
/// order from the low byte.
struct CalcType: BitwiseCopyable, Equatable {
    var bits: UInt64

    init(bits: UInt64) {
        self.bits = bits
    }

    init(_ type: CxxCalcType) {
        var bits = UInt64(UInt8(bitPattern: type.length))
        bits |= UInt64(UInt8(bitPattern: type.angle)) << 8
        bits |= UInt64(UInt8(bitPattern: type.time)) << 16
        bits |= UInt64(UInt8(bitPattern: type.frequency)) << 24
        bits |= UInt64(UInt8(bitPattern: type.resolution)) << 32
        bits |= UInt64(UInt8(bitPattern: type.flex)) << 40
        bits |= UInt64(UInt8(bitPattern: type.percent)) << 48
        bits |= UInt64(CalcType.rawValue(type.percentHint)) << 56
        self.bits = bits
    }

    /// The type of a number, `Type { }`.
    static var number: CalcType { CalcType(bits: 0) }

    /// `getType(const Percentage&)`: `percent` 1, with the percent hint applied when there is one.
    static func percentage(hint: UInt8) -> CalcType {
        var type = CxxCalcType()
        type.percent = 1
        if let percentHint = CalcType.percentHint(rawValue: hint) {
            type.applyPercentHint(percentHint)
        }
        return CalcType(type)
    }

    private func exponent(_ k: UInt64) -> Int8 {
        Int8(truncatingIfNeeded: bits >> (8 * k))
    }

    var cxx: CxxCalcType {
        var type = CxxCalcType()
        type.length = exponent(0)
        type.angle = exponent(1)
        type.time = exponent(2)
        type.frequency = exponent(3)
        type.resolution = exponent(4)
        type.flex = exponent(5)
        type.percent = exponent(6)
        if let percentHint = CalcType.percentHint(rawValue: UInt8(truncatingIfNeeded: bits >> 56)) {
            type.percentHint = CxxCalcType.PercentHintValue(percentHint)
        }
        return type
    }

    /// `Type::determineType`.
    static func determine(_ unit: WebCore.CSSUnitType) -> CalcType {
        CalcType(CxxCalcType.determineType(unit))
    }

    func adding(_ other: CalcType) -> CalcType? {
        CxxCalcType.add(cxx, other.cxx).value.map { CalcType($0) }
    }

    func multiplying(_ other: CalcType) -> CalcType? {
        CxxCalcType.multiply(cxx, other.cxx).value.map { CalcType($0) }
    }

    func inverted() -> CalcType? {
        CxxCalcType.invert(cxx).value.map { CalcType($0) }
    }

    func matches(_ category: WebCore.CSS.Category) -> Bool {
        cxx.matches(category)
    }

    func calculationCategory() -> WebCore.CSS.Category? {
        cxx.calculationCategory().value
    }

    static func percentHint(_ category: WebCore.CSS.Category) -> UInt8 {
        rawValue(CxxCalcType.determinePercentHint(category))
    }

    /// The PercentHint's raw value, or 0 for none.
    static func rawValue(_ hint: CxxCalcType.PercentHintValue) -> UInt8 {
        if hint == CxxCalcType.PercentHintValue(.Length) {
            return WebCore.CSSCalc.PercentHint.Length.rawValue
        }
        if hint == CxxCalcType.PercentHintValue(.Angle) {
            return WebCore.CSSCalc.PercentHint.Angle.rawValue
        }
        if hint == CxxCalcType.PercentHintValue(.Time) {
            return WebCore.CSSCalc.PercentHint.Time.rawValue
        }
        if hint == CxxCalcType.PercentHintValue(.Frequency) {
            return WebCore.CSSCalc.PercentHint.Frequency.rawValue
        }
        if hint == CxxCalcType.PercentHintValue(.Resolution) {
            return WebCore.CSSCalc.PercentHint.Resolution.rawValue
        }
        if hint == CxxCalcType.PercentHintValue(.Flex) {
            return WebCore.CSSCalc.PercentHint.Flex.rawValue
        }
        return 0
    }

    /// The PercentHint whose raw value this is, or nil for 0 and for a value that names none.
    static func percentHint(rawValue: UInt8) -> WebCore.CSSCalc.PercentHint? {
        guard rawValue >= WebCore.CSSCalc.PercentHint.Length.rawValue, rawValue <= WebCore.CSSCalc.PercentHint.Flex.rawValue else {
            return nil
        }
        return WebCore.CSSCalc.PercentHint(rawValue: rawValue)
    }
}

// MARK: - Record flags

/// The bits of a record's flags (CSSCalcSwiftTypes.h), shared by both kinds of record.
enum CalcNodeFlags {
    /// clamp()'s first argument is `none`, and has no child.
    static var minIsNone: UInt8 { UInt8(WebCore.CSSCalcNodeFlagMinIsNone) }
    /// clamp()'s last argument is `none`, and has no child.
    static var maxIsNone: UInt8 { UInt8(WebCore.CSSCalcNodeFlagMaxIsNone) }
    /// The optional last argument of round(), log(), random(), anchor() or anchor-size() is absent.
    static var optionalAbsent: UInt8 { UInt8(WebCore.CSSCalcNodeFlagOptionalAbsent) }
    /// A percentage's hint is present, in `unit`.
    static var percentHint: UInt8 { UInt8(WebCore.CSSCalcNodeFlagPercentHint) }
    /// anchor()'s side is its first child rather than the CSSValueID in `unit`.
    static var sideIsChild: UInt8 { UInt8(WebCore.CSSCalcNodeFlagSideIsChild) }
}

// MARK: - CSSCalc::Child

typealias CalcKind = WebCore.CSSCalcNodeKind

extension WebCore.CSSCalcNodeKind {
    /// A leaf alternative of `CSSCalc::Node`: Number, Percentage, CanonicalDimension, NonCanonicalDimension, Symbol,
    /// SiblingCount or SiblingIndex.
    var isLeaf: Bool { rawValue <= Self.SiblingIndex.rawValue }

    /// A `Numeric` leaf: Number, Percentage, CanonicalDimension or NonCanonicalDimension.
    var isNumeric: Bool { rawValue <= Self.NonCanonicalDimension.rawValue }

    /// One of round()'s four strategies.
    var isRound: Bool { rawValue >= Self.RoundNearest.rawValue && rawValue <= Self.RoundToZero.rawValue }

    /// Whether the kind names a node of a CSSCalc::Tree.
    static func isValid(_ rawValue: UInt8) -> Bool { rawValue <= Self.CalcMixItem.rawValue }
}

/// One node of a calculation tree, owning its children: `CSSCalc::Child`, or a calc-mix() item.
///
/// The fields are a record's (CSSCalcNodeRecord), with the children in place of the subtree size and child count.
/// By kind:
/// - Number: `value`; `unit` is CSSUnitType::Number.
/// - Percentage: `value`; `unit` is its PercentHint's raw value, with `CalcNodeFlags.percentHint`, or 0 without.
/// - CanonicalDimension: `value` in the canonical unit, which `unit` holds (px, deg, s, hz, dppx or fr).
/// - NonCanonicalDimension: `value` in `unit`.
/// - Symbol: `symbolID` is the symbol's CSSValueID, `unit` its CSSUnitType.
/// - SiblingCount, SiblingIndex: nothing.
/// - Sum, Product, Min, Max, Hypot: one child per operand. Negate, Invert, Deg2Rad, Sin, Cos, Tan, Asin, Acos, Atan,
///   Sqrt, Exp, Abs, Sign: one child. Mod, Rem, Atan2, Pow: two. Progress, ProgressNoClamp: value, start and end.
/// - Clamp: [min] value [max]; a bound that is `none` has no child and sets `minIsNone` or `maxIsNone`.
/// - RoundNearest, RoundUp, RoundDown, RoundToZero: the value and the optional interval. Log: the value and the
///   optional base. An absent optional argument sets `optionalAbsent`.
/// - Random: min, max and the optional step; `payload` names its sharing (auto, a key or a fixed value).
/// - CalcMix: one CalcMixItem child per item. CalcMixItem: one child, the item's value; `payload` names its weight,
///   or is `noPayload` when the weight is omitted.
/// - Anchor: the side child when `sideIsChild` (`unit` 0), else `unit` is the side's CSSValueID; then the optional
///   fallback. `payload` names the anchor name, or is `noPayload`.
/// - AnchorSize: the optional fallback; `unit` is the Style::AnchorSizeDimension's raw value, or `noDimension`;
///   `payload` names the anchor name, or is `noPayload`.
///
/// `type` is the node's CSSCalc::Type: `getType` of a leaf, the IndirectNode's type of an operation, 0 for a
/// calc-mix() item. Fields a kind does not use are 0 (`payload`: `noPayload`), so that two trees are equal exactly
/// when their records are, comparing the payloads the records name rather than their indices (TreeStorage's
/// operator==).
struct CalcNode: ~Copyable {
    var kind: CalcKind
    /// `CalcNodeFlags`.
    var flags: UInt8
    var unit: UInt16
    var payload: UInt32
    var symbolID: UInt16
    var type: CalcType
    var value: Double
    var children: UniqueArray<CalcNode>

    /// A record's payload when it names none.
    static var noPayload: UInt32 { UInt32.max }

    /// anchor-size()'s `unit` when it has no <anchor-size>.
    static var noDimension: UInt16 { UInt16(UInt8.max) }

    init(
        kind: CalcKind,
        type: CalcType,
        flags: UInt8 = 0,
        unit: UInt16 = 0,
        payload: UInt32 = CalcNode.noPayload,
        symbolID: UInt16 = 0,
        value: Double = 0,
        children: consuming UniqueArray<CalcNode> = UniqueArray()
    ) {
        self.kind = kind
        self.flags = flags
        self.unit = unit
        self.payload = payload
        self.symbolID = symbolID
        self.type = type
        self.value = value
        self.children = children
    }
}

// MARK: Reading

extension CalcNode {
    var minIsNone: Bool { flags & CalcNodeFlags.minIsNone != 0 }
    var maxIsNone: Bool { flags & CalcNodeFlags.maxIsNone != 0 }

    /// The child index of clamp()'s minimum, nil when it is `none`.
    var clampMinIndex: Int? { minIsNone ? nil : 0 }
    /// The child index of clamp()'s value.
    var clampValueIndex: Int { minIsNone ? 0 : 1 }
    /// The child index of clamp()'s maximum, nil when it is `none`.
    var clampMaxIndex: Int? { maxIsNone ? nil : clampValueIndex + 1 }

    /// The child index of the optional last argument (round()'s interval, log()'s base, random()'s step, the
    /// fallback of anchor() and anchor-size()), nil when it is absent.
    var optionalArgumentIndex: Int? {
        CalcNode.optionalArgumentIndex(kind, flags: flags, childCount: children.count)
    }

    /// `optionalArgumentIndex` of a node of `kind` with `flags` and `childCount` children.
    static func optionalArgumentIndex(_ kind: CalcKind, flags: UInt8, childCount: Int) -> Int? {
        let index: Int
        switch kind {
        case .RoundNearest, .RoundUp, .RoundDown, .RoundToZero, .Log:
            index = 1
        case .Random:
            index = 2
        case .Anchor:
            index = flags & CalcNodeFlags.sideIsChild != 0 ? 1 : 0
        case .AnchorSize:
            index = 0
        default:
            return nil
        }
        return index < childCount ? index : nil
    }

    /// `hasValidShape` of a node of `kind` with `flags`, `unit` and `childCount` children, which are all calc-mix()
    /// items when `onlyItems`.
    static func hasValidShape(_ kind: CalcKind, flags: UInt8, unit: UInt16, childCount count: Int, onlyItems: Bool) -> Bool {
        let minIsNone = flags & CalcNodeFlags.minIsNone != 0
        let maxIsNone = flags & CalcNodeFlags.maxIsNone != 0
        let anchorSideIsChild = flags & CalcNodeFlags.sideIsChild != 0
        let optionalAbsent = CalcNode.optionalArgumentIndex(kind, flags: flags, childCount: count) == nil ? CalcNodeFlags.optionalAbsent : 0
        // The flags a node of this kind and these children has: the contract's, which the constructors write.
        let canonicalFlags: UInt8
        switch kind {
        case .Percentage:
            canonicalFlags = CalcType.percentHint(rawValue: UInt8(truncatingIfNeeded: unit)) != nil ? CalcNodeFlags.percentHint : 0
        case .Clamp:
            canonicalFlags = flags & (CalcNodeFlags.minIsNone | CalcNodeFlags.maxIsNone)
        case .RoundNearest, .RoundUp, .RoundDown, .RoundToZero, .Log, .Random, .AnchorSize:
            canonicalFlags = optionalAbsent
        case .Anchor:
            canonicalFlags = (flags & CalcNodeFlags.sideIsChild) | optionalAbsent
        default:
            canonicalFlags = 0
        }
        let countMatches: Bool
        switch kind {
        case .Number, .Percentage, .CanonicalDimension, .NonCanonicalDimension, .Symbol, .SiblingCount, .SiblingIndex:
            countMatches = count == 0
        case .Negate, .Invert, .Deg2Rad, .Sin, .Cos, .Tan, .Asin, .Acos, .Atan, .Sqrt, .Exp, .Abs, .Sign, .CalcMixItem:
            countMatches = count == 1
        case .Mod, .Rem, .Atan2, .Pow:
            countMatches = count == 2
        case .RoundNearest, .RoundUp, .RoundDown, .RoundToZero, .Log:
            countMatches = count == 1 || count == 2
        case .Progress, .ProgressNoClamp:
            countMatches = count == 3
        case .Random:
            countMatches = count == 2 || count == 3
        case .Clamp:
            countMatches = count == 1 + (minIsNone ? 0 : 1) + (maxIsNone ? 0 : 1)
        case .Sum, .Product, .Min, .Max, .Hypot:
            countMatches = true
        case .CalcMix:
            countMatches = onlyItems
        case .Anchor:
            countMatches = count - (anchorSideIsChild ? 1 : 0) == 0 || count - (anchorSideIsChild ? 1 : 0) == 1
        case .AnchorSize:
            countMatches = count <= 1
        @unknown default:
            countMatches = false
        }
        return countMatches && flags == canonicalFlags
    }
}

// MARK: Records

extension CalcNode {
    /// The tree whose records, in pre-order, are `records`.
    ///
    /// The records are those of a CSSCalc::Tree, or of a tree being made, which keep the contract (`isCalcTree`).
    init(decoding records: Span<WebCore.CSSCalcNodeRecord>) {
        var index = 0
        self = CalcNode.decodeSubtree(records, at: &index)
        precondition(index == records.count)
    }

    private static func decodeSubtree(_ records: Span<WebCore.CSSCalcNodeRecord>, at index: inout Int) -> CalcNode {
        let node = records.calcNode(at: index)
        index &+= 1 // index < records.count: records[index] was read.
        var children = node.childCount == 0 ? UniqueArray<CalcNode>() : UniqueArray<CalcNode>(capacity: node.childCount)
        while index < node.end {
            children.append(decodeSubtree(records, at: &index))
        }
        return CalcNode(
            kind: node.kind,
            type: CalcType(bits: node.typeBits),
            flags: node.flags,
            unit: node.unit,
            payload: node.payload,
            symbolID: node.symbolID,
            value: node.value,
            children: children
        )
    }
}

// MARK: - Building a tree as records

typealias CalcRecord = WebCore.CSSCalcNodeRecord

extension WebCore.CSSCalcNodeRecord {
    /// The record of a leaf of `kind`, its fields as `CalcNode` gives them.
    static func leaf(_ kind: CalcKind, type: CalcType, flags: UInt8 = 0, unit: UInt16 = 0, value: Double = 0) -> CalcRecord {
        CalcRecord(
            kind: kind.rawValue,
            flags: flags,
            unit: unit,
            subtreeSize: 1,
            payload: CalcNode.noPayload,
            childCount: 0,
            typeBits: type.bits,
            value: value
        )
    }

    /// The record of an operation of `kind` with `childCount` children, whose subtree size `CalcArena.makeNode`
    /// writes.
    static func operation(
        _ kind: CalcKind,
        type: CalcType,
        childCount: Int,
        flags: UInt8 = 0,
        unit: UInt16 = 0,
        payload: UInt32 = CalcNode.noPayload,
        value: Double = 0
    ) -> CalcRecord {
        CalcRecord(
            kind: kind.rawValue,
            flags: flags,
            unit: unit,
            subtreeSize: 0,
            payload: payload,
            childCount: UInt32(truncatingIfNeeded: childCount), // A tree has far fewer than 2^32 nodes.
            typeBits: type.bits,
            value: value
        )
    }

    /// `Number { value }`.
    static func number(_ value: Double) -> CalcRecord {
        .leaf(.Number, type: .number, unit: UInt16(WebCore.CSSUnitType.Number.rawValue), value: value)
    }

    /// `Percentage { value, hint }`, where `hint` is a PercentHint's raw value, or 0 for none.
    static func percentage(_ value: Double, hint: UInt8 = 0) -> CalcRecord {
        let hasHint = CalcType.percentHint(rawValue: hint) != nil
        return .leaf(
            .Percentage,
            type: .percentage(hint: hint),
            flags: hasHint ? CalcNodeFlags.percentHint : 0,
            unit: hasHint ? UInt16(hint) : 0,
            value: value
        )
    }

    /// `CanonicalDimension { value, dimension }`, its dimension given by its canonical unit: px, deg, s, hz, dppx or fr.
    static func canonicalDimension(_ value: Double, unit: WebCore.CSSUnitType) -> CalcRecord {
        .leaf(.CanonicalDimension, type: .determine(unit), unit: UInt16(unit.rawValue), value: value)
    }

    /// `makeNumeric`: the numeric leaf a value in `unit` is. A unit that is not numeric gives `Number { 0 }`, which
    /// `makeNumeric` returns after its assertion.
    static func numeric(_ value: Double, unit: WebCore.CSSUnitType) -> CalcRecord {
        switch unit {
        case .Number, .Integer:
            return .number(value)
        case .Percentage:
            return .percentage(value)
        case .Px, .Deg, .S, .Hz, .Dppx, .Fr:
            return .canonicalDimension(value, unit: unit)
        case .Calc, .CalcPercentageWithAngle, .CalcPercentageWithLength, .QuirkyEm, .Unknown:
            return .number(0)
        default:
            return .leaf(.NonCanonicalDimension, type: .determine(unit), unit: UInt16(unit.rawValue), value: value)
        }
    }

    /// `makeChildWithValueBasedOn`: a numeric leaf like `leaf`, with `value`.
    static func numeric(_ value: Double, basedOn leaf: CalcRecord) -> CalcRecord {
        precondition(CalcKind(rawValue: leaf.kind)?.isNumeric ?? false)
        return CalcRecord(
            kind: leaf.kind,
            flags: leaf.flags,
            unit: leaf.unit,
            subtreeSize: 1,
            payload: CalcNode.noPayload,
            childCount: 0,
            typeBits: leaf.typeBits,
            value: value
        )
    }

    /// `Symbol { id, unit }`.
    static func symbol(_ valueID: UInt16, unit: WebCore.CSSUnitType) -> CalcRecord {
        var record = CalcRecord.leaf(.Symbol, type: .determine(unit), unit: UInt16(unit.rawValue))
        record.childCount = UInt32(valueID)
        return record
    }
}

/// The records of a tree being built, in pre-order, as a CSSCalc::Tree stores them.
///
/// A node is built after its children, which are the last subtrees: `makeNode` puts its record in front of them, or
/// `setNode` writes it where `reserveNode` kept its place.
/// Simplification works on a node that is the last subtree too, so what it replaces or removes is always at the
/// end. The records are held in the caller's buffer, on the stack, until there are more than it holds, and then on
/// the heap.
struct CalcArena: ~Copyable, ~Escapable {
    private var inline: MutableSpan<CalcRecord>
    /// Every record, once there are more than `inline` holds.
    private var heap = UniqueArray<CalcRecord>()
    private var onHeap = false
    private(set) var count = 0

    @_lifetime(copy buffer)
    init(_ buffer: consuming MutableSpan<CalcRecord>) {
        inline = buffer
    }

    /// The records.
    var span: Span<CalcRecord> {
        @_lifetime(borrow self)
        borrowing get {
            onHeap ? heap.span : inline.span.extracting(0..<count)
        }
    }

    subscript(_ index: Int) -> CalcRecord {
        get {
            precondition(index < count)
            return onHeap ? heap[index] : inline[index]
        }
        set {
            precondition(index < count)
            if onHeap {
                heap[index] = newValue
            } else {
                inline[index] = newValue
            }
        }
    }

    private mutating func withRecords(_ body: (inout MutableSpan<CalcRecord>) -> Void) {
        if onHeap {
            var records = heap.mutableSpan
            body(&records)
        } else {
            body(&inline)
        }
    }

    @inline(always)
    mutating func append(_ record: CalcRecord) {
        if !onHeap && count < inline.count {
            inline[count] = record
            count &+= 1 // count < inline.count.
        } else {
            appendOnHeap(record)
        }
    }

    /// `append` once the records are on the heap, or are about to be.
    @inline(never)
    private mutating func appendOnHeap(_ record: CalcRecord) {
        if !onHeap {
            var records = UniqueArray<CalcRecord>(capacity: 2 &* inline.count &+ 1) // A stack buffer is small.
            for i in 0..<count {
                records.append(inline[i])
            }
            heap = records
            onHeap = true
        }
        heap.append(record)
        count &+= 1 // At most the records of a parse.
    }

    /// Removes the records from `newCount` on.
    mutating func truncate(to newCount: Int) {
        precondition(newCount <= count)
        if onHeap {
            heap.removeLast(count &- newCount) // newCount <= count.
        }
        count = newCount
    }

    /// Inserts `record` at `index`, moving the records from `index` on one place up.
    mutating func insert(_ record: CalcRecord, at index: Int) {
        precondition(index <= count)
        append(record)
        let last = count &- 1 // count >= 1 after the append.
        withRecords { records in
            var i = last
            while i > index {
                records[i] = records[i &- 1] // i > index >= 0.
                i &-= 1 // i > index >= 0.
            }
            records[index] = record
        }
    }

    /// Removes the record at `index`, moving the records after it one place down.
    mutating func remove(at index: Int) {
        precondition(index < count)
        let last = count &- 1 // count > index >= 0.
        withRecords { records in
            for i in index..<last {
                records[i] = records[i &+ 1] // i < last < count.
            }
        }
        truncate(to: last)
    }

    /// Copies the `length` records at `source` to `destination`, which is not after `source`.
    mutating func moveDown(from source: Int, length: Int, to destination: Int) {
        precondition(destination <= source)
        withRecords { records in
            for i in 0..<length {
                records[destination &+ i] = records[source &+ i] // Both are indices the subtree at `source` holds.
            }
        }
    }

    // MARK: Nodes

    func kind(_ index: Int) -> CalcKind {
        guard let kind = CalcKind(rawValue: self[index].kind) else {
            preconditionFailure()
        }
        return kind
    }

    func value(_ index: Int) -> Double {
        self[index].value
    }

    func type(_ index: Int) -> CalcType {
        CalcType(bits: self[index].typeBits)
    }

    /// The index after the subtree of the node at `index`.
    func end(_ index: Int) -> Int {
        index &+ Int(self[index].subtreeSize) // index < count and the size < 2^32: no overflow.
    }

    /// The children of the operation at `index`.
    func childCount(_ index: Int) -> Int {
        precondition(!kind(index).isLeaf)
        return Int(self[index].childCount)
    }

    /// The index of child `k` of the node at `index`.
    func child(_ index: Int, _ k: Int) -> Int {
        var child = index &+ 1 // index < count.
        for _ in 0..<k {
            child = end(child)
        }
        return child
    }

    /// The child index of the optional last argument of the node at `index`, nil when it is absent.
    func optionalArgumentIndex(_ index: Int) -> Int? {
        let record = self[index]
        return CalcNode.optionalArgumentIndex(kind(index), flags: record.flags, childCount: Int(record.childCount))
    }

    /// Whether every child of the operation at `index` is a numeric leaf.
    func allChildrenNumeric(_ index: Int) -> Bool {
        var child = index &+ 1 // index < count.
        for _ in 0..<childCount(index) {
            guard kind(child).isNumeric else {
                return false
            }
            child = end(child)
        }
        return true
    }

    /// Makes the last records from `start` on the children of `record`, an operation, put in front of them. An
    /// operation whose kind, flags and child count a CSSCalc::Child cannot have stops the process.
    mutating func makeNode(at start: Int, _ record: CalcRecord) {
        insertNode(at: start, record)
        checkShape(at: start, kind(start), flags: record.flags, unit: record.unit, childCount: Int(record.childCount))
    }

    /// Appends a placeholder for the record of an operation whose children are appended after it, and returns its
    /// index, which `setNode` writes once they are.
    mutating func reserveNode() -> Int {
        let start = count
        append(CalcRecord())
        return start
    }

    /// Writes `record`, an operation, at `start`, reserved by `reserveNode`, making the records after it its
    /// children. An operation whose kind, flags and child count a CSSCalc::Child cannot have stops the process.
    mutating func setNode(at start: Int, _ record: CalcRecord) {
        var node = record
        node.subtreeSize = UInt32(truncatingIfNeeded: count &- start) // A tree has far fewer than 2^32 nodes.
        self[start] = node
        checkShape(at: start, kind(start), flags: record.flags, unit: record.unit, childCount: Int(record.childCount))
    }

    /// `makeNode` of an operation whose children are exactly its operands, with no flags.
    mutating func makeOperation(at start: Int, _ kind: CalcKind, type: CalcType, childCount: Int) {
        insertNode(at: start, .operation(kind, type: type, childCount: childCount))
        checkShape(at: start, kind, flags: 0, unit: 0, childCount: childCount)
    }

    private mutating func insertNode(at start: Int, _ record: CalcRecord) {
        var node = record
        node.subtreeSize = UInt32(truncatingIfNeeded: count &- start &+ 1) // A tree has far fewer than 2^32 nodes.
        insert(node, at: start)
    }

    /// Stops the process unless a CSSCalc::Child can have the operation at `start`, of `kind` with `flags`, `unit`
    /// and `childCount` children.
    @inline(always)
    private func checkShape(at start: Int, _ kind: CalcKind, flags: UInt8, unit: UInt16, childCount: Int) {
        var onlyItems = true
        if kind == .CalcMix {
            var child = start &+ 1 // start < count.
            for _ in 0..<childCount {
                onlyItems = onlyItems && self.kind(child) == .CalcMixItem
                child = end(child)
            }
        }
        precondition(CalcNode.hasValidShape(kind, flags: flags, unit: unit, childCount: childCount, onlyItems: onlyItems))
    }

    /// Replaces the node at `index`, the last subtree, with the leaf `record`.
    mutating func replace(_ index: Int, with record: CalcRecord) {
        truncate(to: index)
        append(record)
    }

    /// Replaces the node at `index`, the last subtree, with its descendant at `descendant`.
    mutating func replace(_ index: Int, withSubtreeAt descendant: Int) {
        let length = Int(self[descendant].subtreeSize)
        moveDown(from: descendant, length: length, to: index)
        truncate(to: index &+ length) // Within the node's subtree.
    }

    /// Writes the child count and subtree size of the node at `index`, the last subtree, after its children changed.
    mutating func setChildren(of index: Int, count childCount: Int) {
        self[index].childCount = UInt32(truncatingIfNeeded: childCount) // A tree has far fewer than 2^32 nodes.
        closeSubtree(index)
    }

    /// Writes the subtree size of the node at `index`, the last subtree.
    mutating func closeSubtree(_ index: Int) {
        self[index].subtreeSize = UInt32(truncatingIfNeeded: count &- index) // A tree has far fewer than 2^32 nodes.
    }

    /// Keeps the children of the node at `index`, the last subtree, that `keep` accepts, by child index and record,
    /// in order, and removes the rest.
    mutating func retainChildren(of index: Int, _ keep: (Int, CalcRecord) -> Bool) {
        let childCount = childCount(index)
        var child = index &+ 1 // index < count.
        var next = child
        var kept = 0
        for i in 0..<childCount {
            let record = self[child]
            let length = Int(record.subtreeSize)
            if keep(i, record) {
                if next != child {
                    moveDown(from: child, length: length, to: next)
                }
                next &+= length // Within the node's subtree.
                kept &+= 1 // At most childCount.
            }
            child &+= length // Within the node's subtree.
        }
        truncate(to: next)
        setChildren(of: index, count: kept)
    }

    /// Replaces each child of `kind` of the node at `index`, the last subtree, with its own children.
    mutating func flattenChildren(of index: Int, _ kind: CalcKind) {
        let childCount = childCount(index)
        var child = index &+ 1 // index < count.
        var flattened = 0
        for _ in 0..<childCount {
            if self.kind(child) == kind {
                let grandchildren = self.childCount(child)
                remove(at: child)
                for _ in 0..<grandchildren {
                    child = end(child)
                }
                flattened &+= grandchildren // At most the tree's nodes.
            } else {
                child = end(child)
                flattened &+= 1 // At most the tree's nodes.
            }
        }
        setChildren(of: index, count: flattened)
    }
}

/// Calls `body` with an empty arena whose stack buffer holds a tree of `count` records: 16 records, or 128 for a
/// larger tree.
func withCalcArena<Result>(holding count: Int, _ body: (inout CalcArena) -> Result) -> Result {
    if count <= 16 {
        var buffer = [16 of CalcRecord](repeating: CalcRecord())
        var arena = CalcArena(buffer.mutableSpan)
        return body(&arena)
    }
    return withLargeCalcArena(body)
}

@inline(never)
private func withLargeCalcArena<Result>(_ body: (inout CalcArena) -> Result) -> Result {
    var buffer = [128 of CalcRecord](repeating: CalcRecord())
    var arena = CalcArena(buffer.mutableSpan)
    return body(&arena)
}

extension CalcArena {
    /// Appends the subtree of `records` at `index`, each record checked as `calcNode(at:)` checks it, and advances
    /// `index` past it.
    mutating func append(_ records: Span<CalcRecord>, at index: inout Int) {
        let record = records[index]
        let node = records.calcNode(record, at: index)
        append(record)
        index &+= 1 // index < records.count: records[index] was read.
        while index < node.end {
            append(records, at: &index)
        }
    }
}

/// A node of a CSSCalc::Tree read from its record in place: the record's fields, where its subtree ends and how many
/// children it has.
struct CalcRecordNode {
    let kind: CalcKind
    let flags: UInt8
    let unit: UInt16
    let payload: UInt32
    let symbolID: UInt16
    let typeBits: UInt64
    let value: Double
    /// The index after the node's subtree.
    let end: Int
    let childCount: Int

    /// The CSSUnitType of a Number, CanonicalDimension, NonCanonicalDimension or Symbol.
    var unitType: WebCore.CSSUnitType {
        precondition(kind.isNumeric && kind != .Percentage || kind == .Symbol)
        guard let unitType = WebCore.CSSUnitType(rawValue: UInt8(truncatingIfNeeded: unit)) else {
            preconditionFailure()
        }
        return unitType
    }

    var minIsNone: Bool { flags & CalcNodeFlags.minIsNone != 0 }
    var maxIsNone: Bool { flags & CalcNodeFlags.maxIsNone != 0 }

    /// anchor()'s side is a calculation, its first child.
    var anchorSideIsChild: Bool { flags & CalcNodeFlags.sideIsChild != 0 }

    /// The optional last argument is present: the last child.
    var hasOptionalArgument: Bool {
        CalcNode.optionalArgumentIndex(kind, flags: flags, childCount: childCount) != nil
    }
}

extension Span where Element == WebCore.CSSCalcNodeRecord {
    /// The node whose record is `self[index]`, in the records of a CSSCalc::Tree, pre-order, from the record alone.
    /// A tree keeps the contract (`isCalcTree`) as it is made: `makeTree` builds it from a CSSCalc::Child, and
    /// `CalcArena` writes each subtree size and child count from the records it holds and checks each operation it
    /// makes. A record whose subtree size or kind is out of range stops the process. Every other read of the records
    /// is checked against their count, so a record that breaks the rest of the contract gives a wrong result or
    /// stops the process, and reads nothing outside the records.
    @inline(always)
    func calcNode(at index: Int) -> CalcRecordNode {
        calcNode(self[index], at: index)
    }

    /// `calcNode(at: index)` of `record`, which is `self[index]`.
    @inline(always)
    func calcNode(_ record: WebCore.CSSCalcNodeRecord, at index: Int) -> CalcRecordNode {
        // The caller read self[index], so this costs nothing; with it the subtraction does not wrap.
        precondition(index >= 0 && index < count)
        precondition(record.subtreeSize >= 1 && Int(record.subtreeSize) <= count &- index)
        precondition(CalcKind.isValid(record.kind))
        guard let kind = CalcKind(rawValue: record.kind) else {
            preconditionFailure()
        }
        var symbolID: UInt16 = 0
        if kind == .Symbol {
            guard let id = UInt16(exactly: record.childCount) else {
                preconditionFailure()
            }
            symbolID = id
        }
        return CalcRecordNode(
            kind: kind,
            flags: record.flags,
            unit: record.unit,
            payload: record.payload,
            symbolID: symbolID,
            typeBits: record.typeBits,
            value: record.value,
            end: index &+ Int(record.subtreeSize), // At most count, checked above.
            childCount: kind == .Symbol ? 0 : Int(record.childCount)
        )
    }

    /// Whether the records keep the contract of a CSSCalc::Tree's: the root's subtree is every record, and each node's
    /// children's subtrees follow it one after another and fill its own, as many as its child count, with the kind
    /// and flags a CSSCalc::Child can have.
    var isCalcTree: Bool {
        guard count >= 1 && Int(self[0].subtreeSize) == count else {
            return false
        }
        for index in 0..<count {
            let node = calcNode(at: index)
            var childCount = 0
            var onlyItems = true
            var child = index &+ 1 // index < count.
            while child < node.end {
                let childRecord = self[child]
                guard childRecord.subtreeSize >= 1 else {
                    return false
                }
                onlyItems = onlyItems && childRecord.kind == CalcKind.CalcMixItem.rawValue
                child &+= Int(childRecord.subtreeSize) // child < count and the size < 2^32: no overflow.
                childCount &+= 1 // At most count.
            }
            guard child == node.end && childCount == node.childCount,
                CalcNode.hasValidShape(node.kind, flags: node.flags, unit: node.unit, childCount: childCount, onlyItems: onlyItems)
            else {
                return false
            }
        }
        return true
    }
}

/// A node of a CSSCalc::Tree read in place from the tree's records, its record checked as `calcNode(at:)` checks it:
/// the parts of `CalcNode` the serializer and Typed OM read.
struct CalcNodeView: ~Escapable {
    let records: Span<WebCore.CSSCalcNodeRecord>
    /// The index of the node's record.
    let index: Int
    let node: CalcRecordNode

    @_lifetime(copy records)
    init(_ records: Span<WebCore.CSSCalcNodeRecord>, at index: Int) {
        self.records = records
        self.index = index
        node = records.calcNode(at: index)
    }

    var kind: CalcKind { node.kind }
    var flags: UInt8 { node.flags }
    var unit: UInt16 { node.unit }
    var payload: UInt32 { node.payload }
    var symbolID: UInt16 { node.symbolID }
    var value: Double { node.value }
    var childCount: Int { node.childCount }

    /// The index of the first child's record.
    var firstChild: Int { index &+ 1 } // index < records.count.

    /// The index of the record after the subtree whose record is at `child`.
    func end(_ child: Int) -> Int {
        child &+ Int(records[child].subtreeSize) // Within the node's subtree, as the tree keeps the contract.
    }

    /// Child `k`, read from where the children before it end.
    @_lifetime(copy self)
    func child(_ k: Int) -> CalcNodeView {
        var child = firstChild
        for _ in 0..<k {
            child = end(child)
        }
        return CalcNodeView(records, at: child)
    }

    /// The payload this node names, if it names one.
    var payloadIndex: UInt32? {
        payload == CalcNode.noPayload ? nil : payload
    }

    var minIsNone: Bool { node.minIsNone }

    /// The child index of clamp()'s minimum, nil when it is `none`.
    var clampMinIndex: Int? { minIsNone ? nil : 0 }
    /// The child index of clamp()'s value.
    var clampValueIndex: Int { minIsNone ? 0 : 1 }
    /// The child index of clamp()'s maximum, nil when it is `none`.
    var clampMaxIndex: Int? { node.maxIsNone ? nil : clampValueIndex + 1 }

    /// anchor()'s side is a calculation, its first child.
    var anchorSideIsChild: Bool { node.anchorSideIsChild }

    /// The child index of the optional last argument, nil when it is absent.
    var optionalArgumentIndex: Int? {
        CalcNode.optionalArgumentIndex(kind, flags: flags, childCount: childCount)
    }

    /// anchor-size()'s Style::AnchorSizeDimension raw value, nil for none.
    var anchorSizeDimension: UInt8? {
        unit == CalcNode.noDimension ? nil : UInt8(truncatingIfNeeded: unit)
    }
}

// MARK: - Style::Calculation::Child

typealias StyleCalcKind = WebCore.StyleCalcNodeKind

extension WebCore.StyleCalcNodeKind {
    /// A leaf alternative of `Style::Calculation::Node`: Number, Percentage, Dimension or Size.
    var isLeaf: Bool { rawValue <= Self.Size.rawValue }

    /// One of round()'s four strategies.
    var isRound: Bool { rawValue >= Self.RoundNearest.rawValue && rawValue <= Self.RoundToZero.rawValue }

    /// Whether the kind names a node of a Style::Calculation::Tree.
    static func isValid(_ rawValue: UInt8) -> Bool { rawValue <= Self.CalcMixItem.rawValue }
}

/// One node of a Style::Calculation tree, owning its children: `Style::Calculation::Child`, or a calc-mix() item.
///
/// The fields are a record's (StyleCalcNodeRecord), with the children in place of the subtree size. By kind:
/// - Number, Percentage, Dimension: `value` (a dimension is in px, unzoomed). Size: nothing.
/// - Sum, Product, Min, Max, Hypot: one child per operand. Negate, Invert, Sin, Cos, Tan, Asin, Acos, Atan, Sqrt, Exp,
///   Abs, Sign: one child. Mod, Rem, Atan2, Pow: two. Progress, ProgressNoClamp: progress, from and to.
/// - Clamp: [min] value [max]; a bound that is `none` has no child and sets `minIsNone` or `maxIsNone`.
/// - RoundNearest, RoundUp, RoundDown, RoundToZero: the value and the optional interval; Log: the value and the
///   optional base. An absent optional argument sets `optionalAbsent`.
/// - Random: min, max and the optional step (`optionalAbsent` without it); `value` is its fixed base value.
/// - CalcMix: one CalcMixItem child per item. CalcMixItem: one child, the item's value; `value` is its weight.
///
/// Fields a kind does not use are 0, so that two trees are equal exactly when their records are.
struct StyleCalcNode: ~Copyable {
    var kind: StyleCalcKind
    /// `CalcNodeFlags`: minIsNone, maxIsNone, optionalAbsent.
    var flags: UInt8
    var value: Double
    var children: UniqueArray<StyleCalcNode>

    init(kind: StyleCalcKind, flags: UInt8 = 0, value: Double = 0, children: consuming UniqueArray<StyleCalcNode> = UniqueArray()) {
        self.kind = kind
        self.flags = flags
        self.value = value
        self.children = children
    }
}

@inline(always)
private func appendIfPresent(_ children: inout UniqueArray<StyleCalcNode>, _ node: consuming StyleCalcNode?) -> Bool {
    switch consume node {
    case .some(let node):
        children.append(node)
        return true
    case .none:
        return false
    }
}

// MARK: Construction

extension StyleCalcNode {
    /// `Number { value }`.
    static func number(_ value: Double) -> StyleCalcNode {
        StyleCalcNode(kind: .Number, value: value)
    }

    /// `Percentage { value }`.
    static func percentage(_ value: Double) -> StyleCalcNode {
        StyleCalcNode(kind: .Percentage, value: value)
    }

    /// `Dimension { value }`.
    static func dimension(_ value: Double) -> StyleCalcNode {
        StyleCalcNode(kind: .Dimension, value: value)
    }

    /// `Size { }`.
    static func size() -> StyleCalcNode {
        StyleCalcNode(kind: .Size)
    }

    /// An operation whose children are exactly its operands: Sum, Product, Min, Max, Hypot, the one- and
    /// two-argument functions, Progress, ProgressNoClamp, and CalcMix over CalcMixItem children.
    static func operation(_ kind: StyleCalcKind, children: consuming UniqueArray<StyleCalcNode>) -> StyleCalcNode {
        let node = StyleCalcNode(kind: kind, children: children)
        precondition(node.hasValidShape)
        return node
    }

    /// A one-argument operation.
    static func operation(_ kind: StyleCalcKind, _ a: consuming StyleCalcNode) -> StyleCalcNode {
        var children = UniqueArray<StyleCalcNode>(capacity: 1)
        children.append(a)
        return .operation(kind, children: children)
    }

    /// A two-argument operation, or a Sum or Product of two.
    static func operation(_ kind: StyleCalcKind, _ a: consuming StyleCalcNode, _ b: consuming StyleCalcNode) -> StyleCalcNode {
        var children = UniqueArray<StyleCalcNode>(capacity: 2)
        children.append(a)
        children.append(b)
        return .operation(kind, children: children)
    }

    /// `Clamp { min, val, max }`, where a nil bound is `none`.
    static func clamp(min: consuming StyleCalcNode?, value: consuming StyleCalcNode, max: consuming StyleCalcNode?) -> StyleCalcNode {
        var children = UniqueArray<StyleCalcNode>(capacity: 3)
        let hasMin = appendIfPresent(&children, min)
        children.append(value)
        let hasMax = appendIfPresent(&children, max)
        let flags = (hasMin ? 0 : CalcNodeFlags.minIsNone) | (hasMax ? 0 : CalcNodeFlags.maxIsNone)
        return StyleCalcNode(kind: .Clamp, flags: flags, children: children)
    }

    /// `RoundNearest`, `RoundUp`, `RoundDown` or `RoundToZero { a, b }`.
    static func round(_ kind: StyleCalcKind, _ a: consuming StyleCalcNode, interval: consuming StyleCalcNode?) -> StyleCalcNode {
        precondition(kind.isRound)
        return .withOptionalLast(kind, a, interval)
    }

    /// `Log { a, b }`.
    static func log(_ a: consuming StyleCalcNode, base: consuming StyleCalcNode?) -> StyleCalcNode {
        .withOptionalLast(.Log, a, base)
    }

    private static func withOptionalLast(
        _ kind: StyleCalcKind,
        _ a: consuming StyleCalcNode,
        _ b: consuming StyleCalcNode?
    ) -> StyleCalcNode {
        var children = UniqueArray<StyleCalcNode>(capacity: 2)
        children.append(a)
        let hasB = appendIfPresent(&children, b)
        return StyleCalcNode(kind: kind, flags: hasB ? 0 : CalcNodeFlags.optionalAbsent, children: children)
    }

    /// `Random { fixed, min, max, step }`.
    static func random(
        baseValue: Double,
        min: consuming StyleCalcNode,
        max: consuming StyleCalcNode,
        step: consuming StyleCalcNode?
    ) -> StyleCalcNode {
        var children = UniqueArray<StyleCalcNode>(capacity: 3)
        children.append(min)
        children.append(max)
        let hasStep = appendIfPresent(&children, step)
        return StyleCalcNode(kind: .Random, flags: hasStep ? 0 : CalcNodeFlags.optionalAbsent, value: baseValue, children: children)
    }

    /// A calc-mix() item: its value and its weight.
    static func calcMixItem(_ value: consuming StyleCalcNode, weight: Double) -> StyleCalcNode {
        var children = UniqueArray<StyleCalcNode>(capacity: 1)
        children.append(value)
        return StyleCalcNode(kind: .CalcMixItem, value: weight, children: children)
    }
}

// MARK: Reading

extension StyleCalcNode {
    var minIsNone: Bool { flags & CalcNodeFlags.minIsNone != 0 }
    var maxIsNone: Bool { flags & CalcNodeFlags.maxIsNone != 0 }

    /// The child index of clamp()'s minimum, nil when it is `none`.
    var clampMinIndex: Int? { minIsNone ? nil : 0 }
    /// The child index of clamp()'s value.
    var clampValueIndex: Int { minIsNone ? 0 : 1 }
    /// The child index of clamp()'s maximum, nil when it is `none`.
    var clampMaxIndex: Int? { maxIsNone ? nil : clampValueIndex + 1 }

    /// The child index of round()'s interval, log()'s base or random()'s step, nil when it is absent.
    var optionalArgumentIndex: Int? {
        StyleCalcNode.optionalArgumentIndex(kind, childCount: children.count)
    }

    /// `optionalArgumentIndex` of a node of `kind` with `childCount` children.
    static func optionalArgumentIndex(_ kind: StyleCalcKind, childCount: Int) -> Int? {
        let index: Int
        switch kind {
        case .RoundNearest, .RoundUp, .RoundDown, .RoundToZero, .Log:
            index = 1
        case .Random:
            index = 2
        default:
            return nil
        }
        return index < childCount ? index : nil
    }

    /// Whether the node has as many children as its kind and flags say, the flags the contract gives it, and a value
    /// only where its kind has one.
    var hasValidShape: Bool {
        var onlyItems = true
        if kind == .CalcMix {
            for i in 0..<children.count where children[i].kind != .CalcMixItem {
                onlyItems = false
            }
        }
        return StyleCalcNode.hasValidShape(kind, flags: flags, value: value, childCount: children.count, onlyItems: onlyItems)
    }

    /// `hasValidShape` of a node of `kind` with `flags`, `value` and `childCount` children, which are all calc-mix()
    /// items when `onlyItems`.
    static func hasValidShape(_ kind: StyleCalcKind, flags: UInt8, value: Double, childCount count: Int, onlyItems: Bool) -> Bool {
        let minIsNone = flags & CalcNodeFlags.minIsNone != 0
        let maxIsNone = flags & CalcNodeFlags.maxIsNone != 0
        let canonicalFlags: UInt8
        switch kind {
        case .Clamp:
            canonicalFlags = flags & (CalcNodeFlags.minIsNone | CalcNodeFlags.maxIsNone)
        case .RoundNearest, .RoundUp, .RoundDown, .RoundToZero, .Log, .Random:
            canonicalFlags = StyleCalcNode.optionalArgumentIndex(kind, childCount: count) == nil ? CalcNodeFlags.optionalAbsent : 0
        default:
            canonicalFlags = 0
        }
        let countMatches: Bool
        switch kind {
        case .Number, .Percentage, .Dimension, .Size:
            countMatches = count == 0
        case .Negate, .Invert, .Sin, .Cos, .Tan, .Asin, .Acos, .Atan, .Sqrt, .Exp, .Abs, .Sign, .CalcMixItem:
            countMatches = count == 1
        case .Mod, .Rem, .Atan2, .Pow:
            countMatches = count == 2
        case .RoundNearest, .RoundUp, .RoundDown, .RoundToZero, .Log:
            countMatches = count == 1 || count == 2
        case .Progress, .ProgressNoClamp:
            countMatches = count == 3
        case .Random:
            countMatches = count == 2 || count == 3
        case .Clamp:
            countMatches = count == 1 + (minIsNone ? 0 : 1) + (maxIsNone ? 0 : 1)
        case .Sum, .Product, .Min, .Max, .Hypot:
            countMatches = true
        case .CalcMix:
            countMatches = onlyItems
        @unknown default:
            countMatches = false
        }
        let hasValue: Bool
        switch kind {
        case .Number, .Percentage, .Dimension, .Random, .CalcMixItem:
            hasValue = true
        default:
            hasValue = false
        }
        // A NaN value is a value too, and compares unequal to 0.
        return countMatches && flags == canonicalFlags && (hasValue || value.bitPattern == 0)
    }

    /// The nodes in the tree: its record count.
    var nodeCount: Int {
        var count = 1
        for i in 0..<children.count {
            count += children[i].nodeCount
        }
        return count
    }
}

// MARK: Records

extension StyleCalcNode {
    /// The tree whose records, in pre-order, are `records`: a Style::Calculation::Tree's. A record whose subtree size,
    /// kind or flags break the contract stops the process, as a malformed Style::Calculation::Child would.
    init(decoding records: Span<WebCore.StyleCalcNodeRecord>) {
        var index = 0
        self = StyleCalcNode.decodeSubtree(records, at: &index)
        precondition(index == records.count)
    }

    private static func decodeSubtree(_ records: Span<WebCore.StyleCalcNodeRecord>, at index: inout Int) -> StyleCalcNode {
        let node = records.styleCalcNode(at: index)
        index &+= 1 // index < records.count: records[index] was read.
        var children = node.childCount == 0 ? UniqueArray<StyleCalcNode>() : UniqueArray<StyleCalcNode>(capacity: node.childCount)
        while index < node.end {
            children.append(decodeSubtree(records, at: &index))
        }
        return StyleCalcNode(kind: node.kind, flags: node.flags, value: node.value, children: children)
    }

    /// Writes the tree's records, in pre-order, to `records` from `next` on, and advances `next` past them.
    private func encode(into records: inout MutableSpan<WebCore.StyleCalcNodeRecord>, at next: inout Int) {
        let start = next
        records[start] = WebCore.StyleCalcNodeRecord(kind: kind.rawValue, flags: flags, reserved: 0, subtreeSize: 1, value: value)
        next &+= 1 // next <= records.count: records[start] was written.
        for i in 0..<children.count {
            children[i].encode(into: &records, at: &next)
        }
        // A tree has far fewer than 2^32 records; next > start.
        records[start].subtreeSize = UInt32(truncatingIfNeeded: next &- start)
    }

    /// Gives `output` the tree's records, in pre-order: what a Style::Calculation::Tree stores for it. A tree of
    /// up to 16 records is written on the stack, a larger one into a heap buffer.
    func encode(into output: inout WebCore.StyleCalcSwiftOutput) {
        let count = nodeCount
        guard count <= 16 else {
            encodeOnHeap(count, into: &output)
            return
        }
        var scratch = [16 of WebCore.StyleCalcNodeRecord](repeating: WebCore.StyleCalcNodeRecord())
        do {
            var records = scratch.mutableSpan
            var next = 0
            encode(into: &records, at: &next)
        }
        output.adopt(scratch.span.extracting(0..<count))
    }

    @inline(never)
    private func encodeOnHeap(_ count: Int, into output: inout WebCore.StyleCalcSwiftOutput) {
        var storage = UniqueArray<WebCore.StyleCalcNodeRecord>(repeating: WebCore.StyleCalcNodeRecord(), count: count)
        do {
            var records = storage.mutableSpan
            var next = 0
            encode(into: &records, at: &next)
        }
        output.adopt(storage.span)
    }
}

/// A node of a Style::Calculation::Tree read from its record in place: the record's fields, where its subtree ends
/// and how many children it has.
struct StyleCalcRecordNode {
    let kind: StyleCalcKind
    let flags: UInt8
    let value: Double
    /// The index after the node's subtree.
    let end: Int
    let childCount: Int

    var minIsNone: Bool { flags & CalcNodeFlags.minIsNone != 0 }
    var maxIsNone: Bool { flags & CalcNodeFlags.maxIsNone != 0 }

    /// round()'s interval, log()'s base or random()'s step is present: the last child.
    var hasOptionalArgument: Bool {
        StyleCalcNode.optionalArgumentIndex(kind, childCount: childCount) != nil
    }
}

extension Span where Element == WebCore.StyleCalcNodeRecord {
    /// The node whose record is `self[index]`, in the records of a Style::Calculation::Tree, pre-order: its children's
    /// subtrees follow it one after another and fill its own. A record whose subtree size, kind or flags break the
    /// contract stops the process, as a malformed Style::Calculation::Child would.
    func styleCalcNode(at index: Int) -> StyleCalcRecordNode {
        let record = self[index]
        // self[index] was read, so index < count: the subtraction does not wrap.
        precondition(record.subtreeSize >= 1 && Int(record.subtreeSize) <= count &- index && record.reserved == 0)
        precondition(StyleCalcKind.isValid(record.kind))
        guard let kind = StyleCalcKind(rawValue: record.kind) else {
            preconditionFailure()
        }
        let end = index &+ Int(record.subtreeSize) // At most count, checked above.

        var childCount = 0
        var onlyItems = true
        var child = index &+ 1 // index < count.
        while child < end {
            let childRecord = self[child]
            precondition(childRecord.subtreeSize >= 1)
            onlyItems = onlyItems && childRecord.kind == StyleCalcKind.CalcMixItem.rawValue
            child &+= Int(childRecord.subtreeSize) // child < count and the size < 2^32: no overflow.
            childCount &+= 1 // At most count.
        }
        precondition(child == end)
        precondition(
            StyleCalcNode.hasValidShape(kind, flags: record.flags, value: record.value, childCount: childCount, onlyItems: onlyItems)
        )
        return StyleCalcRecordNode(kind: kind, flags: record.flags, value: record.value, end: end, childCount: childCount)
    }
}

// MARK: - Executors

/// round()'s rounding strategy: which of the four round kinds a node is.
enum CalcRoundingStrategy {
    case nearest
    case up
    case down
    case toZero

    init?(_ kind: CalcKind) {
        switch kind {
        case .RoundNearest: self = .nearest
        case .RoundUp: self = .up
        case .RoundDown: self = .down
        case .RoundToZero: self = .toZero
        default: return nil
        }
    }

    init?(_ kind: StyleCalcKind) {
        switch kind {
        case .RoundNearest: self = .nearest
        case .RoundUp: self = .up
        case .RoundDown: self = .down
        case .RoundToZero: self = .toZero
        default: return nil
        }
    }
}

/// The C library functions (<cmath>) the math functions compute with.
private enum CMath {
    #if canImport(Darwin)
    @inline(always)
    static func sin(_ x: Double) -> Double { Darwin.sin(x) }
    @inline(always)
    static func cos(_ x: Double) -> Double { Darwin.cos(x) }
    @inline(always)
    static func tan(_ x: Double) -> Double { Darwin.tan(x) }
    @inline(always)
    static func asin(_ x: Double) -> Double { Darwin.asin(x) }
    @inline(always)
    static func acos(_ x: Double) -> Double { Darwin.acos(x) }
    @inline(always)
    static func atan(_ x: Double) -> Double { Darwin.atan(x) }
    @inline(always)
    static func atan2(_ y: Double, _ x: Double) -> Double { Darwin.atan2(y, x) }
    @inline(always)
    static func pow(_ x: Double, _ y: Double) -> Double { Darwin.pow(x, y) }
    @inline(always)
    static func sqrt(_ x: Double) -> Double { Darwin.sqrt(x) }
    @inline(always)
    static func log(_ x: Double) -> Double { Darwin.log(x) }
    @inline(always)
    static func exp(_ x: Double) -> Double { Darwin.exp(x) }
    @inline(always)
    static func fabs(_ x: Double) -> Double { Darwin.fabs(x) }
    @inline(always)
    static func fmod(_ x: Double, _ y: Double) -> Double { Darwin.fmod(x, y) }
    @inline(always)
    static func floor(_ x: Double) -> Double { Darwin.floor(x) }
    #elseif canImport(ucrt)
    @inline(always)
    static func sin(_ x: Double) -> Double { ucrt.sin(x) }
    @inline(always)
    static func cos(_ x: Double) -> Double { ucrt.cos(x) }
    @inline(always)
    static func tan(_ x: Double) -> Double { ucrt.tan(x) }
    @inline(always)
    static func asin(_ x: Double) -> Double { ucrt.asin(x) }
    @inline(always)
    static func acos(_ x: Double) -> Double { ucrt.acos(x) }
    @inline(always)
    static func atan(_ x: Double) -> Double { ucrt.atan(x) }
    // WTF's MathExtras.h replaces atan2 on Windows, where atan2 of two infinities is NaN.
    @inline(always)
    static func atan2(_ y: Double, _ x: Double) -> Double { wtf_atan2(y, x) }
    @inline(always)
    static func pow(_ x: Double, _ y: Double) -> Double { ucrt.pow(x, y) }
    @inline(always)
    static func sqrt(_ x: Double) -> Double { ucrt.sqrt(x) }
    @inline(always)
    static func log(_ x: Double) -> Double { ucrt.log(x) }
    @inline(always)
    static func exp(_ x: Double) -> Double { ucrt.exp(x) }
    @inline(always)
    static func fabs(_ x: Double) -> Double { ucrt.fabs(x) }
    @inline(always)
    static func fmod(_ x: Double, _ y: Double) -> Double { ucrt.fmod(x, y) }
    @inline(always)
    static func floor(_ x: Double) -> Double { ucrt.floor(x) }
    #elseif canImport(Glibc)
    @inline(always)
    static func sin(_ x: Double) -> Double { Glibc.sin(x) }
    @inline(always)
    static func cos(_ x: Double) -> Double { Glibc.cos(x) }
    @inline(always)
    static func tan(_ x: Double) -> Double { Glibc.tan(x) }
    @inline(always)
    static func asin(_ x: Double) -> Double { Glibc.asin(x) }
    @inline(always)
    static func acos(_ x: Double) -> Double { Glibc.acos(x) }
    @inline(always)
    static func atan(_ x: Double) -> Double { Glibc.atan(x) }
    @inline(always)
    static func atan2(_ y: Double, _ x: Double) -> Double { Glibc.atan2(y, x) }
    @inline(always)
    static func pow(_ x: Double, _ y: Double) -> Double { Glibc.pow(x, y) }
    @inline(always)
    static func sqrt(_ x: Double) -> Double { Glibc.sqrt(x) }
    @inline(always)
    static func log(_ x: Double) -> Double { Glibc.log(x) }
    @inline(always)
    static func exp(_ x: Double) -> Double { Glibc.exp(x) }
    @inline(always)
    static func fabs(_ x: Double) -> Double { Glibc.fabs(x) }
    @inline(always)
    static func fmod(_ x: Double, _ y: Double) -> Double { Glibc.fmod(x, y) }
    @inline(always)
    static func floor(_ x: Double) -> Double { Glibc.floor(x) }
    #endif
}

/// The math functions' operations, each a fixed sequence of C library calls. min() and max() stop at the first NaN
/// after the first operand.
enum CalcExecutor {
    /// `a * b + c` written as one C++ expression, which clang contracts into a fused multiply-add where the target
    /// has one: always on arm64, never on x86_64 without FMA, which WebKit's Windows and Intel Mac targets lack.
    @inline(always)
    static func multiplyAdd(_ a: Double, _ b: Double, _ c: Double) -> Double {
        #if arch(arm64)
        c.addingProduct(a, b)
        #else
        a * b + c
        #endif
    }

    // MARK: Operators

    /// `Operator::Sum`.
    @inline(always)
    static func sum(count: Int, _ operand: (Int) -> Double) -> Double {
        var sum = 0.0
        for i in 0..<count {
            sum += operand(i)
        }
        return sum
    }

    static func sum(_ operands: Span<Double>) -> Double {
        sum(count: operands.count) { operands[$0] }
    }

    /// `a + b`, or `a` when it is NaN: which of two NaNs `+` gives is not specified, and the compiler may put either
    /// operand first.
    @inline(always)
    static func sum(_ a: Double, _ b: Double) -> Double {
        let sum = a + b
        return sum.isNaN && a.isNaN ? a : sum
    }

    /// `Operator::Product`.
    @inline(always)
    static func product(count: Int, _ operand: (Int) -> Double) -> Double {
        var product = 1.0
        for i in 0..<count {
            product *= operand(i)
        }
        return product
    }

    static func product(_ operands: Span<Double>) -> Double {
        product(count: operands.count) { operands[$0] }
    }

    @inline(always)
    static func product(_ a: Double, _ b: Double) -> Double {
        a * b
    }

    /// `Operator::Negate`.
    @inline(always)
    static func negate(_ a: Double) -> Double {
        -a
    }

    /// `Operator::Invert`.
    @inline(always)
    static func invert(_ a: Double) -> Double {
        1.0 / a
    }

    /// `deg2rad`: Deg2Rad's conversion of its child, in degrees, to radians.
    @inline(always)
    static func deg2rad(_ degrees: Double) -> Double {
        wtf.deg2rad(degrees)
    }

    // MARK: Comparison

    /// `std::min(a, b)`: `a` unless `b < a`.
    @inline(always)
    private static func standardMin(_ a: Double, _ b: Double) -> Double {
        b < a ? b : a
    }

    /// `std::max(a, b)`: `a` unless `a < b`.
    @inline(always)
    private static func standardMax(_ a: Double, _ b: Double) -> Double {
        a < b ? b : a
    }

    /// `minWithSignedZero`: -0 is less than +0.
    @inline(always)
    static func minWithSignedZero(_ a: Double, _ b: Double) -> Double {
        if a == b {
            return a.sign == .minus ? a : b
        }
        return standardMin(a, b)
    }

    /// `maxWithSignedZero`: +0 is greater than -0.
    @inline(always)
    static func maxWithSignedZero(_ a: Double, _ b: Double) -> Double {
        if a == b {
            return a.sign == .minus ? b : a
        }
        return standardMax(a, b)
    }

    /// `Operator::Min` over its operands; NaN for none.
    @inline(always)
    static func min(count: Int, _ operand: (Int) -> Double) -> Double {
        if count == 0 {
            return .nan
        }
        var minimum = operand(0)
        for i in 1..<count {
            let value = operand(i)
            if value.isNaN {
                return value
            }
            minimum = minWithSignedZero(minimum, value)
        }
        return minimum
    }

    static func min(_ operands: Span<Double>) -> Double {
        min(count: operands.count) { operands[$0] }
    }

    /// `Operator::Min` of two, as clamp() with a `none` minimum uses it.
    @inline(always)
    static func min(_ value: Double, _ minimum: Double) -> Double {
        if value.isNaN {
            return value
        }
        if minimum.isNaN {
            return minimum
        }
        return minWithSignedZero(value, minimum)
    }

    /// `Operator::Max` over its operands; NaN for none.
    @inline(always)
    static func max(count: Int, _ operand: (Int) -> Double) -> Double {
        if count == 0 {
            return .nan
        }
        var maximum = operand(0)
        for i in 1..<count {
            let value = operand(i)
            if value.isNaN {
                return value
            }
            maximum = maxWithSignedZero(maximum, value)
        }
        return maximum
    }

    static func max(_ operands: Span<Double>) -> Double {
        max(count: operands.count) { operands[$0] }
    }

    /// `Operator::Max` of two, as clamp() with a `none` maximum uses it.
    @inline(always)
    static func max(_ value: Double, _ maximum: Double) -> Double {
        if value.isNaN {
            return value
        }
        if maximum.isNaN {
            return maximum
        }
        return maxWithSignedZero(value, maximum)
    }

    /// `Operator::Clamp`.
    @inline(always)
    static func clamp(_ minimum: Double, _ value: Double, _ maximum: Double) -> Double {
        if minimum.isNaN || value.isNaN || maximum.isNaN {
            return .nan
        }
        return maxWithSignedZero(minimum, minWithSignedZero(value, maximum))
    }

    /// `Operator::Clamp` where a nil bound is `none`.
    @inline(always)
    static func clamp(_ minimum: Double?, _ value: Double, _ maximum: Double?) -> Double {
        switch (minimum, maximum) {
        case (nil, nil):
            return value
        case (nil, let maximum?):
            return min(value, maximum)
        case (let minimum?, nil):
            return max(minimum, value)
        case (let minimum?, let maximum?):
            return clamp(minimum, value, maximum)
        }
    }

    // MARK: Stepped values

    /// `getNearestMultiples`: the multiples of `b` either side of `a`, or `a` twice when `a` is one.
    @inline(always)
    static func nearestMultiples(_ a: Double, _ b: Double) -> (lower: Double, upper: Double) {
        if CMath.fmod(a, b) == 0 {
            return (a, a)
        }
        let lower = CMath.floor(a / CMath.fabs(b)) * CMath.fabs(b)
        let upper = lower + CMath.fabs(b)
        return (lower, upper)
    }

    /// `Operator::RoundNearest`.
    static func roundNearest(_ valueToRound: Double, _ roundingInterval: Double) -> Double {
        if !valueToRound.isInfinite && roundingInterval.isInfinite {
            return valueToRound.sign == .minus ? -0.0 : +0.0
        }
        let (lower, upper) = nearestMultiples(valueToRound, roundingInterval)
        return CMath.fabs(upper - valueToRound) <= CMath.fabs(roundingInterval) / 2 ? upper : lower
    }

    /// `Operator::RoundUp`.
    static func roundUp(_ valueToRound: Double, _ roundingInterval: Double) -> Double {
        if !valueToRound.isInfinite && roundingInterval.isInfinite {
            if valueToRound == 0 {
                return valueToRound
            }
            return valueToRound.sign == .minus ? -0.0 : .infinity
        }
        return nearestMultiples(valueToRound, roundingInterval).upper
    }

    /// `Operator::RoundDown`.
    static func roundDown(_ valueToRound: Double, _ roundingInterval: Double) -> Double {
        if !valueToRound.isInfinite && roundingInterval.isInfinite {
            if valueToRound == 0 {
                return valueToRound
            }
            return valueToRound.sign == .minus ? -.infinity : +0.0
        }
        return nearestMultiples(valueToRound, roundingInterval).lower
    }

    /// `Operator::RoundToZero`.
    static func roundToZero(_ valueToRound: Double, _ roundingInterval: Double) -> Double {
        if !valueToRound.isInfinite && roundingInterval.isInfinite {
            return valueToRound.sign == .minus ? -0.0 : +0.0
        }
        let (lower, upper) = nearestMultiples(valueToRound, roundingInterval)
        return CMath.fabs(upper) < CMath.fabs(lower) ? upper : lower
    }

    /// round() by `strategy`, with an interval of 1 when it has none.
    static func round(_ strategy: CalcRoundingStrategy, _ valueToRound: Double, _ roundingInterval: Double?) -> Double {
        let interval = roundingInterval ?? 1.0
        switch strategy {
        case .nearest:
            return roundNearest(valueToRound, interval)
        case .up:
            return roundUp(valueToRound, interval)
        case .down:
            return roundDown(valueToRound, interval)
        case .toZero:
            return roundToZero(valueToRound, interval)
        }
    }

    /// `Operator::Mod`.
    static func mod(_ a: Double, _ b: Double) -> Double {
        // In mod(A, B) only, if B is infinite and A has opposite sign to B (including an oppositely-signed zero), the
        // result is NaN. https://drafts.csswg.org/css-values/#round-infinities
        if b.isInfinite && (a.sign == .minus) != (b.sign == .minus) {
            return .nan
        }
        var result = CMath.fmod(a, b)
        // A zero remainder takes the sign of B. https://drafts.csswg.org/css-values/#round-func
        if result == 0 {
            return b.sign == .minus ? -0.0 : +0.0
        }
        // A result on the opposite side of zero from B is put between 0 and B.
        if (result.sign == .minus) != (b.sign == .minus) {
            result += b
        }
        return result
    }

    /// `Operator::Rem`.
    static func rem(_ a: Double, _ b: Double) -> Double {
        if b == 0 {
            return .nan
        }
        return CMath.fmod(a, b)
    }

    // MARK: Trigonometric

    /// `Operator::Sin`, of radians.
    @inline(always)
    static func sin(_ a: Double) -> Double {
        CMath.sin(a)
    }

    /// `Operator::Cos`, of radians.
    @inline(always)
    static func cos(_ a: Double) -> Double {
        CMath.cos(a)
    }

    /// `Operator::Tan`, of radians: infinite at the poles of the angle reduced to [0, 2pi].
    static func tan(_ a: Double) -> Double {
        let fullTurn = Double.pi * 2
        var x = CMath.fmod(a, fullTurn)
        // fmod can return negative values.
        x = x < 0 ? fullTurn + x : x
        if x == piOverTwoDouble {
            return .infinity
        }
        if x == 3 * piOverTwoDouble {
            return -.infinity
        }
        return CMath.tan(x)
    }

    /// `Operator::Asin`, in degrees.
    @inline(always)
    static func asin(_ a: Double) -> Double {
        rad2deg(CMath.asin(a))
    }

    /// `Operator::Acos`, in degrees.
    @inline(always)
    static func acos(_ a: Double) -> Double {
        rad2deg(CMath.acos(a))
    }

    /// `Operator::Atan`, in degrees.
    @inline(always)
    static func atan(_ a: Double) -> Double {
        rad2deg(CMath.atan(a))
    }

    /// `Operator::Atan2`, in degrees.
    @inline(always)
    static func atan2(_ a: Double, _ b: Double) -> Double {
        rad2deg(CMath.atan2(a, b))
    }

    // MARK: Exponential

    /// `Operator::Pow`.
    @inline(always)
    static func pow(_ a: Double, _ b: Double) -> Double {
        CMath.pow(a, b)
    }

    /// `Operator::Sqrt`.
    @inline(always)
    static func sqrt(_ a: Double) -> Double {
        CMath.sqrt(a)
    }

    /// `Operator::Hypot` over its operands; NaN for none.
    @inline(always)
    static func hypot(count: Int, _ operand: (Int) -> Double) -> Double {
        if count == 0 {
            return .nan
        }
        if count == 1 {
            return CMath.fabs(operand(0))
        }
        var sum = 0.0
        for i in 0..<count {
            let value = operand(i)
            sum = multiplyAdd(value, value, sum)
        }
        return CMath.sqrt(sum)
    }

    static func hypot(_ operands: Span<Double>) -> Double {
        hypot(count: operands.count) { operands[$0] }
    }

    /// `Operator::Log`: the natural logarithm.
    @inline(always)
    static func log(_ a: Double) -> Double {
        CMath.log(a)
    }

    /// `Operator::Log` to base `b`.
    @inline(always)
    static func log(_ a: Double, _ b: Double) -> Double {
        CMath.log(a) / CMath.log(b)
    }

    /// `Operator::Log` to base `b`, or the natural logarithm when it has none.
    @inline(always)
    static func log(_ a: Double, _ b: Double?) -> Double {
        if let b {
            return log(a, b)
        }
        return log(a)
    }

    /// `Operator::Exp`.
    @inline(always)
    static func exp(_ a: Double) -> Double {
        CMath.exp(a)
    }

    // MARK: Sign-related

    /// `Operator::Abs`.
    @inline(always)
    static func abs(_ a: Double) -> Double {
        CMath.fabs(a)
    }

    /// `Operator::Sign`: `a` itself for ±0 and NaN.
    @inline(always)
    static func sign(_ a: Double) -> Double {
        if a > 0 {
            return 1
        }
        if a < 0 {
            return -1
        }
        return a
    }

    // MARK: Progress, mixing and random

    /// `Operator::Progress`.
    static func progress(_ progress: Double, _ from: Double, _ to: Double) -> Double {
        if from == to {
            return 0.0
        }
        return clamp(0.0, (progress - from) / (to - from), 1.0)
    }

    /// `Operator::ProgressNoClamp`.
    static func progressNoClamp(_ progress: Double, _ from: Double, _ to: Double) -> Double {
        if from == to {
            if progress < from {
                return -.infinity
            }
            if progress > from {
                return .infinity
            }
            return 0.0
        }
        return (progress - from) / (to - from)
    }

    /// `Operator::CalcMix` over its items' values and percentages.
    @inline(always)
    static func calcMix(count: Int, _ item: (Int) -> (value: Double, percentage: Double)) -> Double {
        var total = 0.0
        for i in 0..<count {
            let (value, percentage) = item(i)
            total = multiplyAdd(value, percentage / 100, total)
        }
        return total
    }

    /// `Operator::Random`.
    static func random(_ randomBaseValue: Double, _ minimum: Double, _ maximum: Double, _ step: Double?) -> Double {
        if minimum.isNaN || maximum.isNaN {
            return .nan
        }

        if minimum.isInfinite {
            return minimum
        }

        // If the maximum value is less than the minimum value, it behaves as if it's equal to the minimum value.
        let maximum = maximum < minimum ? minimum : maximum

        let range = maximum - minimum
        if range.isInfinite {
            return .nan
        }

        guard let step else {
            return multiplyAdd(randomBaseValue, range, minimum)
        }

        if step.isNaN {
            return .nan
        }

        if step <= 0 {
            return multiplyAdd(randomBaseValue, range, minimum)
        }

        // Let epsilon be step / 1000, or the smallest representable value greater than zero in the numeric type
        // being used if epsilon would round to zero.
        let epsilon = step / 1000.0

        // Let N be the largest integer such that min + N * step is less than or equal to max.
        var n = CMath.floor(range / step)
        if n.isInfinite {
            return multiplyAdd(randomBaseValue, range, minimum)
        }

        // If N produces a value that is not within epsilon of max, but N+1 would produce a value within epsilon of
        // max, set N to N+1.
        let distanceToMax = maximum - multiplyAdd(n, step, minimum)
        if CMath.fabs(distanceToMax) > epsilon {
            let distanceToMaxPlus1 = maximum - multiplyAdd(n + 1, step, minimum)
            if CMath.fabs(distanceToMaxPlus1) < epsilon {
                n = n + 1
            }
        }

        // Let step index be a random integer less than N+1, given R.
        let stepIndex = roundDown(randomBaseValue * (n + 1.0), 1.0)

        // Let value be min + step index * step.
        let value = multiplyAdd(stepIndex, step, minimum)

        // If step index is N and value is within epsilon of max, return max.
        if stepIndex == n && CMath.fabs(maximum - value) < epsilon {
            return maximum
        }

        // Otherwise, return value.
        return value
    }
}
