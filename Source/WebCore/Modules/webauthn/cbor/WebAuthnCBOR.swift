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

// ENABLE(WEB_AUTHN) (PlatformEnableCocoa.h): every Cocoa platform but watchOS and Mac Catalyst.
#if !os(watchOS) && !targetEnvironment(macCatalyst)

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
internal import wtf
internal import WebCore_Private.Core.WebAuthnSwiftTypes

// The CBOR reader and writer (RFC 7049) for the CTAP2 messages, and `CBOR`, the value the Swift code builds and
// reads. `cbor::CBORValue` crosses only where C++ hands one over or keeps one: the reader's result, the writer's
// argument, and the C++ fields that hold one.

// The CBOR encoding's numbers, from CBORBinary.h (not importable: no header Swift sees includes it). Each literal is
// pinned by a static_assert in CBORWriter.cpp.
private let cborMajorTypeBitShift: UInt8 = 5 // constants::kMajorTypeBitShift
private let cborAdditionalInformationMask: UInt8 = 0x1F // constants::kAdditionalInformationMask
private let cborAdditionalInformation1Byte: UInt8 = 24 // constants::kAdditionalInformation1Byte
private let cborAdditionalInformation2Bytes: UInt8 = 25 // constants::kAdditionalInformation2Bytes
private let cborAdditionalInformation4Bytes: UInt8 = 26 // constants::kAdditionalInformation4Bytes
private let cborAdditionalInformation8Bytes: UInt8 = 27 // constants::kAdditionalInformation8Bytes

// Major types, the values of `CBORValue::Type` (pinned with the constants above).
private let cborMajorUnsigned: UInt8 = 0
private let cborMajorNegative: UInt8 = 1
private let cborMajorByteString: UInt8 = 2
private let cborMajorString: UInt8 = 3
private let cborMajorArray: UInt8 = 4
private let cborMajorMap: UInt8 = 5
private let cborMajorSimpleValue: UInt8 = 7

/// A CBOR data item as `cbor::CBORValue` models it: integers in the `int64_t` range, byte and text strings, arrays,
/// maps keyed by integers or text, the four simple values, and `none`, the `CBORValue()` that holds nothing (the
/// writer encodes it as an empty byte string).
enum CBOR: Equatable {
    /// `CBORValue(int64_t)`: an unsigned integer when not negative, a negative one otherwise.
    case integer(Int64)
    case byteString([UInt8])
    case string(Swift.String)
    case array([CBOR])
    case map(Map)
    case simple(SimpleValue)
    case none

    /// `CBORValue::SimpleValue`; the raw values are the encoding's (pinned in CBORWriter.cpp).
    enum SimpleValue: UInt8 {
        case falseValue = 20
        case trueValue = 21
        case nullValue = 22
        case undefined = 23
    }

    /// `CBORValue(bool)`.
    static func bool(_ value: Bool) -> CBOR {
        .simple(value ? .trueValue : .falseValue)
    }

    var isInteger: Bool {
        if case .integer = self { return true }
        return false
    }

    var isString: Bool {
        if case .string = self { return true }
        return false
    }

    var isMap: Bool {
        if case .map = self { return true }
        return false
    }

    /// The value of an unsigned or negative integer (`getInteger()`), else nil.
    var integerValue: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    /// The value of an unsigned integer (`getUnsigned()`), else nil.
    var unsignedValue: Int64? {
        if case .integer(let value) = self, value >= 0 { return value }
        return nil
    }

    var byteStringValue: [UInt8]? {
        if case .byteString(let value) = self { return value }
        return nil
    }

    var stringValue: Swift.String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var arrayValue: [CBOR]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var mapValue: Map? {
        if case .map(let value) = self { return value }
        return nil
    }

    /// `getBool()` of a value that `isBool()`, else nil.
    var boolValue: Bool? {
        switch self {
        case .simple(.trueValue): true
        case .simple(.falseValue): false
        default: nil
        }
    }

    /// The `CBORValue::Type` rank `CTAPLess` compares first (`None` is -1).
    fileprivate var ctapTypeRank: Int {
        switch self {
        case .integer(let value): value >= 0 ? Int(cborMajorUnsigned) : Int(cborMajorNegative)
        case .byteString: Int(cborMajorByteString)
        case .string: Int(cborMajorString)
        case .array: Int(cborMajorArray)
        case .map: Int(cborMajorMap)
        case .simple: Int(cborMajorSimpleValue)
        case .none: -1
        }
    }

    /// `CBORValue::MapValue`: entries kept sorted by `CTAPLess`, with no two keys equivalent under it. Keys are
    /// integers or strings (inserting any other key traps, as `CBORValue::mapInsert` does).
    struct Map: Equatable {
        struct Entry: Equatable {
            var key: CBOR
            var value: CBOR
        }

        /// The entries in `CTAPLess` order, the order the writer emits and `std::map` iterates.
        private(set) var entries: [Entry] = []

        init() {}

        /// An empty map with room for `minimumCapacity` entries.
        init(minimumCapacity: Int) {
            entries.reserveCapacity(minimumCapacity)
        }

        fileprivate mutating func reserveCapacity(_ minimumCapacity: Int) {
            entries.reserveCapacity(minimumCapacity)
        }

        var count: Int { entries.count }
        var isEmpty: Bool { entries.isEmpty }

        /// `CBORValue::CTAPLess`: major type first (unsigned, negative, ..., string), then unsigned ascending,
        /// negative descending, and strings by UTF-16 length, then by UTF-16 code unit (`codePointCompareLessThan`
        /// compares code units). Any other pair of equal types is not less.
        static func ctapLess(_ a: CBOR, _ b: CBOR) -> Bool {
            let aRank = a.ctapTypeRank
            let bRank = b.ctapTypeRank
            if aRank != bRank {
                return aRank < bRank
            }
            switch (a, b) {
            case (.integer(let x), .integer(let y)):
                return x >= 0 ? x < y : x > y
            case (.string(let x), .string(let y)):
                let xUTF8 = x.utf8
                let yUTF8 = y.utf8
                let xBytes: Span<UInt8> = xUTF8.span
                let yBytes: Span<UInt8> = yUTF8.span
                if isASCII(xBytes) && isASCII(yBytes) {
                    // ASCII: one UTF-16 code unit per byte, in byte order.
                    if xBytes.count != yBytes.count {
                        return xBytes.count < yBytes.count
                    }
                    for index in xBytes.indices where xBytes[index] != yBytes[index] {
                        return xBytes[index] < yBytes[index]
                    }
                    return false
                }
                let xLength = x.utf16.count
                let yLength = y.utf16.count
                if xLength != yLength {
                    return xLength < yLength
                }
                return x.utf16.lexicographicallyPrecedes(y.utf16)
            default:
                return false
            }
        }

        /// Whether every byte of `bytes` is below 0x80.
        fileprivate static func isASCII(_ bytes: Span<UInt8>) -> Bool {
            var bits: UInt8 = 0
            for index in bytes.indices {
                bits |= bytes[index]
            }
            return bits < 0x80
        }

        /// The first index whose key is not less than `key`, and whether that key is equivalent to `key`
        /// (`std::map::find`).
        private func search(_ key: CBOR) -> (index: Int, found: Bool) {
            if case .string(let probe) = key {
                let probeUTF8 = probe.utf8
                let probeBytes: Span<UInt8> = probeUTF8.span
                let probeIsASCII = Map.isASCII(probeBytes)
                var low = 0
                var high = entries.count
                while low < high {
                    let middle = low + (high - low) / 2
                    if Map.compare(entries[middle].key, toString: probe, probeBytes, probeIsASCII) < 0 {
                        low = middle + 1
                    } else {
                        high = middle
                    }
                }
                return (low, low < entries.count && Map.compare(entries[low].key, toString: probe, probeBytes, probeIsASCII) == 0)
            }
            var low = 0
            var high = entries.count
            while low < high {
                let middle = low + (high - low) / 2
                if Map.ctapLess(entries[middle].key, key) {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return (low, low < entries.count && !Map.ctapLess(key, entries[low].key))
        }

        /// `key` against the string `probe` under `ctapLess`: negative if `key` is less, zero if they are equivalent,
        /// positive if `probe` is less. `probeBytes` is `probe`'s UTF-8 and `probeIsASCII` whether it is all ASCII.
        private static func compare(_ key: CBOR, toString probe: Swift.String, _ probeBytes: Span<UInt8>, _ probeIsASCII: Bool) -> Int {
            let rank = key.ctapTypeRank
            let stringRank = Int(cborMajorString)
            if rank != stringRank {
                return rank < stringRank ? -1 : 1
            }
            if probeIsASCII, case .string(let x) = key {
                let xUTF8 = x.utf8
                let xBytes: Span<UInt8> = xUTF8.span
                if isASCII(xBytes) {
                    // ASCII: one UTF-16 code unit per byte, in byte order.
                    if xBytes.count != probeBytes.count {
                        return xBytes.count < probeBytes.count ? -1 : 1
                    }
                    for index in xBytes.indices where xBytes[index] != probeBytes[index] {
                        return xBytes[index] < probeBytes[index] ? -1 : 1
                    }
                    return 0
                }
            }
            if ctapLess(key, .string(probe)) {
                return -1
            }
            return ctapLess(.string(probe), key) ? 1 : 0
        }

        func contains(_ key: CBOR) -> Bool {
            search(key).found
        }

        /// `map.find(key)`'s value, or nil.
        subscript(_ key: CBOR) -> CBOR? {
            let (index, found) = search(key)
            return found ? entries[index].value : nil
        }

        subscript(_ key: Int64) -> CBOR? {
            self[.integer(key)]
        }

        subscript(_ key: Swift.String) -> CBOR? {
            self[.string(key)]
        }

        /// `map.emplace(key, value)` / `mapInsert`: inserts unless an equivalent key is there (the first value
        /// wins), and returns whether it inserted.
        @discardableResult
        mutating func insert(_ key: CBOR, _ value: CBOR) -> Bool {
            precondition(key.isInteger || key.isString, "CBOR map keys are integers or strings")
            let (index, found) = search(key)
            if found {
                return false
            }
            insertEntry(Entry(key: key, value: value), at: index)
            return true
        }

        /// `map[key] = value`: inserts, or replaces the value of an equivalent key (the last value wins).
        mutating func set(_ key: CBOR, _ value: CBOR) {
            precondition(key.isInteger || key.isString, "CBOR map keys are integers or strings")
            let (index, found) = search(key)
            if found {
                entries[index].value = value
            } else {
                insertEntry(Entry(key: key, value: value), at: index)
            }
        }

        /// `entries.insert(_:at:)`, except that an entry sorting last is appended (no copy of a tail).
        private mutating func insertEntry(_ entry: Entry, at index: Int) {
            if index == entries.count {
                entries.append(entry)
            } else {
                entries.insert(entry, at: index)
            }
        }

        mutating func set(_ key: Int64, _ value: CBOR) {
            set(.integer(key), value)
        }

        mutating func set(_ key: Swift.String, _ value: CBOR) {
            set(.string(key), value)
        }

        /// Appends an entry the caller has checked sorts after every key in the map.
        fileprivate mutating func appendInOrder(_ key: CBOR, _ value: CBOR) {
            entries.append(Entry(key: key, value: value))
        }
    }
}

// MARK: - Reader

extension CBOR {
    typealias DecoderError = cbor.CBORReader.DecoderError

    /// `CBORReader::kCBORMaxDepth`, the reader's default and largest nesting level (a class-scope constant does not
    /// import; pinned by a static_assert in CBORWriter.cpp).
    static var maxReadNestingLevel: Int32 { 16 }

    /// `CBORWriter::kDefaultMaxNestingDepth` (pinned by a static_assert in CBORWriter.cpp).
    static var defaultWriteNestingLevel: Int { 16 }

    /// What `cborReadResult` returns: the value when `error` is `CBORNoError`, else nil, and the bytes the
    /// reader advanced over.
    struct ReadOutcome {
        var value: CBOR?
        var error: DecoderError
        var bytesConsumed: Int
    }

    /// `cborReadResult`: decodes one data item from the start of `data`. With `allowExtraneousData` false,
    /// bytes after it are `ExtraneousData` (`read`); with it true they are left (`readWithBytesConsumed`).
    static func decode(_ data: Span<UInt8>, maxNestingLevel: Int32, allowExtraneousData: Bool) -> ReadOutcome {
        var reader = CBORDecoder()
        let value = reader.decode(data, maxNestingLevel)
        if value != nil && !allowExtraneousData && reader.position != data.count {
            reader.error = .ExtraneousData
        }
        return ReadOutcome(value: reader.error == .CBORNoError ? value : nil, error: reader.error, bytesConsumed: reader.position)
    }

    /// `CBORReader::read`: the data item `data` holds exactly, or nil.
    static func read(_ data: Span<UInt8>, maxNestingLevel: Int32 = maxReadNestingLevel) -> CBOR? {
        decode(data, maxNestingLevel: maxNestingLevel, allowExtraneousData: false).value
    }

    static func read(_ data: [UInt8], maxNestingLevel: Int32 = maxReadNestingLevel) -> CBOR? {
        read(data.span, maxNestingLevel: maxNestingLevel)
    }

    /// `CBORReader::readWithBytesConsumed`: the data item at the start of `data` and its length in bytes, or nil.
    static func readWithBytesConsumed(_ data: Span<UInt8>, maxNestingLevel: Int32 = maxReadNestingLevel) -> (value: CBOR, bytesConsumed: Int)? {
        let outcome = decode(data, maxNestingLevel: maxNestingLevel, allowExtraneousData: true)
        guard let value = outcome.value else {
            return nil
        }
        return (value, outcome.bytesConsumed)
    }
}

/// The decoder's state: the position and the last error set. When a check fails the position stays where it was: a
/// map still decodes the value after a failed key, from wherever the key's decoding stopped, and that value's error,
/// if any, replaces the key's.
private struct CBORDecoder {
    var position = 0
    var error = CBOR.DecoderError.CBORNoError

    mutating func canConsume(_ data: Span<UInt8>, _ count: UInt64) -> Bool {
        if UInt64(data.count - position) >= count {
            return true
        }
        error = .IncompleteCBORData
        return false
    }

    mutating func decode(_ data: Span<UInt8>, _ maxNestingLevel: Int32) -> CBOR? {
        if maxNestingLevel < 0 || maxNestingLevel > CBOR.maxReadNestingLevel {
            error = .TooMuchNesting
            return nil
        }
        guard canConsume(data, 1) else {
            return nil
        }
        let initialByte = data[position]
        position += 1
        let majorType = initialByte >> cborMajorTypeBitShift
        let additionalInfo = initialByte & cborAdditionalInformationMask
        guard let value = readVariadicLengthInteger(data, additionalInfo) else {
            return nil
        }
        switch majorType {
        case cborMajorUnsigned:
            if value > UInt64(Int64.max) {
                error = .OutOfRangeIntegerValue
                return nil
            }
            return .integer(Int64(value))
        case cborMajorNegative:
            if value > UInt64(Int64.max) {
                error = .OutOfRangeIntegerValue
                return nil
            }
            return .integer(~Int64(value)) // -value - 1
        case cborMajorByteString:
            return readBytes(data, value)
        case cborMajorString:
            return readString(data, value)
        case cborMajorArray:
            return readArray(data, value, maxNestingLevel)
        case cborMajorMap:
            return readMap(data, value, maxNestingLevel)
        case cborMajorSimpleValue:
            return readSimpleValue(additionalInfo, value)
        default:
            error = .UnsupportedMajorType
            return nil
        }
    }

    mutating func readVariadicLengthInteger(_ data: Span<UInt8>, _ additionalInfo: UInt8) -> UInt64? {
        if additionalInfo < cborAdditionalInformation1Byte {
            return UInt64(additionalInfo)
        }
        let additionalBytes: Int
        switch additionalInfo {
        case cborAdditionalInformation1Byte: additionalBytes = 1
        case cborAdditionalInformation2Bytes: additionalBytes = 2
        case cborAdditionalInformation4Bytes: additionalBytes = 4
        case cborAdditionalInformation8Bytes: additionalBytes = 8
        default:
            error = .UnknownAdditionalInfo
            return nil
        }
        guard canConsume(data, UInt64(additionalBytes)) else {
            return nil
        }
        var intData: UInt64 = 0
        for _ in 0..<additionalBytes {
            intData = intData << 8 | UInt64(data[position])
            position += 1
        }
        // Arguments use the shortest encoding.
        if (additionalBytes == 1 && intData < UInt64(cborAdditionalInformation1Byte)) || intData <= (UInt64(1) << (8 * (additionalBytes >> 1))) - 1 {
            error = .NonMinimalCBOREncoding
            return nil
        }
        return intData
    }

    mutating func readBytes(_ data: Span<UInt8>, _ count: UInt64) -> CBOR? {
        guard canConsume(data, count) else {
            return nil
        }
        let start = position
        position += Int(count)
        return .byteString(makeByteArray(data.extracting(start..<position)))
    }

    mutating func readString(_ data: Span<UInt8>, _ count: UInt64) -> CBOR? {
        guard canConsume(data, count) else {
            return nil
        }
        let start = position
        position += Int(count)
        if count == 0 {
            return .string("")
        }
        // String::fromUTF8 gives a null String for bytes that are not UTF-8, which hasValidUTF8Format rejects.
        guard let characters = try? UTF8Span(validating: data.extracting(start..<position)) else {
            error = .InvalidUTF8
            return nil
        }
        return .string(Swift.String(copying: characters))
    }

    mutating func readArray(_ data: Span<UInt8>, _ length: UInt64, _ maxNestingLevel: Int32) -> CBOR? {
        var array: [CBOR] = []
        var remaining = length
        while remaining > 0 {
            remaining -= 1
            guard let element = decode(data, maxNestingLevel - 1) else {
                return nil
            }
            array.append(element)
        }
        return .array(array)
    }

    mutating func readMap(_ data: Span<UInt8>, _ length: UInt64, _ maxNestingLevel: Int32) -> CBOR? {
        var map = CBOR.Map()
        var remaining = length
        while remaining > 0 {
            remaining -= 1
            let key = decode(data, maxNestingLevel - 1)
            let value = decode(data, maxNestingLevel - 1)
            guard let key, let value else {
                return nil
            }
            guard key.isString || key.isInteger else {
                error = .IncorrectMapKeyType
                return nil
            }
            // A duplicate key is reported before an out-of-order one; a key after the last one is neither.
            if let last = map.entries.last, CBOR.Map.ctapLess(last.key, key) {
                map.appendInOrder(key, value)
            } else {
                if map.contains(key) {
                    error = .DuplicateKey
                    return nil
                }
                if let last = map.entries.last, CBOR.Map.ctapLess(key, last.key) {
                    error = .OutOfOrderKey
                    return nil
                }
                map.appendInOrder(key, value)
            }
            if map.count == 1 && remaining > 0 {
                // The first entry read: the rest cannot be more than the input holds (an entry is two bytes or more).
                map.reserveCapacity(Int(min(length, UInt64(data.count / 2))))
            }
        }
        return .map(map)
    }

    mutating func readSimpleValue(_ additionalInfo: UInt8, _ value: UInt64) -> CBOR? {
        guard let simpleValue = readSimple(additionalInfo, value) else {
            return nil
        }
        return .simple(simpleValue)
    }

    mutating func readSimple(_ additionalInfo: UInt8, _ value: UInt64) -> CBOR.SimpleValue? {
        if additionalInfo > cborAdditionalInformation1Byte && additionalInfo <= cborAdditionalInformation8Bytes {
            error = .UnsupportedFloatingPointValue
            return nil
        }
        if value <= UInt64(UInt8.max), let simpleValue = CBOR.SimpleValue(rawValue: UInt8(value)) {
            return simpleValue
        }
        error = .UnsupportedSimpleValue
        return nil
    }

    // MARK: Decoding into cbor::CBORValue (cborReadResult)

    /// `decode`, building the `cbor::CBORValue` directly: the same checks in the same order, the same positions and
    /// errors, without a Swift tree in between.
    mutating func decodeValue(_ data: Span<UInt8>, _ maxNestingLevel: Int32) -> cbor.CBORValue? {
        if maxNestingLevel < 0 || maxNestingLevel > CBOR.maxReadNestingLevel {
            error = .TooMuchNesting
            return nil
        }
        guard canConsume(data, 1) else {
            return nil
        }
        let initialByte = data[position]
        position += 1
        let majorType = initialByte >> cborMajorTypeBitShift
        let additionalInfo = initialByte & cborAdditionalInformationMask
        guard let value = readVariadicLengthInteger(data, additionalInfo) else {
            return nil
        }
        switch majorType {
        case cborMajorUnsigned:
            if value > UInt64(Int64.max) {
                error = .OutOfRangeIntegerValue
                return nil
            }
            return cbor.CBORValue(Int64(value))
        case cborMajorNegative:
            if value > UInt64(Int64.max) {
                error = .OutOfRangeIntegerValue
                return nil
            }
            return cbor.CBORValue(~Int64(value)) // -value - 1
        case cborMajorByteString:
            guard canConsume(data, value) else {
                return nil
            }
            let start = position
            position += Int(value)
            return cbor.CBORValue.makeByteString(makeByteVector(data.extracting(start..<position)))
        case cborMajorString:
            return readStringValue(data, value)
        case cborMajorArray:
            var array = cbor.CBORValue(.Array)
            var remaining = value
            while remaining > 0 {
                remaining -= 1
                guard let element = decodeValue(data, maxNestingLevel - 1) else {
                    return nil
                }
                array.arrayAppend(element)
            }
            return array
        case cborMajorMap:
            return readMapValue(data, value, maxNestingLevel)
        case cborMajorSimpleValue:
            guard let simpleValue = readSimple(additionalInfo, value),
                let cxxSimpleValue = cbor.CBORValue.SimpleValue(rawValue: Int32(simpleValue.rawValue)) else {
                return nil
            }
            return cbor.CBORValue(cxxSimpleValue)
        default:
            error = .UnsupportedMajorType
            return nil
        }
    }

    /// The bytes of the last text string `decodeValue` read (a string item holds no other item, so after a key that
    /// is a string, they are the key's).
    private var lastStringRange = 0..<0

    mutating func readStringValue(_ data: Span<UInt8>, _ count: UInt64) -> cbor.CBORValue? {
        guard canConsume(data, count) else {
            return nil
        }
        let start = position
        position += Int(count)
        lastStringRange = start..<position
        if count == 0 {
            return cbor.CBORValue.makeString(fido.emptyWTFString())
        }
        let bytes = data.extracting(start..<position)
        if CBOR.Map.isASCII(bytes) {
            return cbor.CBORValue.makeString(WTF.String(WTF.latin1CharactersOfBytes(bytes)))
        }
        guard let characters = try? UTF8Span(validating: bytes) else {
            error = .InvalidUTF8
            return nil
        }
        return cbor.CBORValue.makeString(makeWTFString(Swift.String(copying: characters)))
    }

    /// A map key `readMapValue` has read: its integer, or the range of its string's UTF-8 in the input.
    private enum ReadMapKey {
        case integer(Int64)
        case string(Range<Int>)
    }

    /// `CBOR.Map.ctapLess` of two keys `readMapValue` has read from `data`.
    private static func readMapKeyLess(_ a: ReadMapKey, _ b: ReadMapKey, _ data: Span<UInt8>) -> Bool {
        switch (a, b) {
        case (.integer(let x), .integer(let y)):
            return CBOR.Map.ctapLess(.integer(x), .integer(y))
        case (.integer, .string):
            return true
        case (.string, .integer):
            return false
        case (.string(let x), .string(let y)):
            let xBytes = data.extracting(x)
            let yBytes = data.extracting(y)
            if CBOR.Map.isASCII(xBytes) && CBOR.Map.isASCII(yBytes) {
                // ASCII: one UTF-16 code unit per byte, in byte order.
                if xBytes.count != yBytes.count {
                    return xBytes.count < yBytes.count
                }
                for index in xBytes.indices where xBytes[index] != yBytes[index] {
                    return xBytes[index] < yBytes[index]
                }
                return false
            }
            guard let xCharacters = try? UTF8Span(validating: xBytes), let yCharacters = try? UTF8Span(validating: yBytes) else {
                preconditionFailure("decodeValue checked the key's UTF-8")
            }
            return CBOR.Map.ctapLess(.string(Swift.String(copying: xCharacters)), .string(Swift.String(copying: yCharacters)))
        }
    }

    /// `readMap` into a `cbor::CBORValue`: `mapInsert` is the duplicate check, and the last key is kept as its
    /// integer or its string's bytes for the order checks.
    mutating func readMapValue(_ data: Span<UInt8>, _ length: UInt64, _ maxNestingLevel: Int32) -> cbor.CBORValue? {
        var map = cbor.CBORValue(.Map)
        var lastKey: ReadMapKey?
        var remaining = length
        while remaining > 0 {
            remaining -= 1
            let key = decodeValue(data, maxNestingLevel - 1)
            let keyStrings = lastStringRange
            let value = decodeValue(data, maxNestingLevel - 1)
            guard let key, let value else {
                return nil
            }
            let keyScalar: ReadMapKey
            switch key.type() {
            case .Unsigned, .Negative:
                keyScalar = .integer(key.integerValue())
            case .String:
                keyScalar = .string(keyStrings)
            default:
                error = .IncorrectMapKeyType
                return nil
            }
            // A duplicate key is reported before an out-of-order one; a key after the last one is neither.
            if let lastKey, Self.readMapKeyLess(lastKey, keyScalar, data) {
                let inserted = map.mapInsert(key, value)
                precondition(inserted, "a key after the last one is new")
            } else {
                if !map.mapInsert(key, value) {
                    error = .DuplicateKey
                    return nil
                }
                if let lastKey, Self.readMapKeyLess(keyScalar, lastKey, data) {
                    error = .OutOfOrderKey
                    return nil
                }
            }
            lastKey = keyScalar
        }
        return map
    }
}

// MARK: - Writer

extension CBOR {
    /// `CBORWriter::write`: the encoding of `value`, or nil if it nests deeper than `maxNestingLevel` (arrays and maps
    /// count one level each; the level is truncated to `Int32`).
    static func write(_ value: CBOR, maxNestingLevel: Int = defaultWriteNestingLevel) -> [UInt8]? {
        var encoded: [UInt8] = []
        guard cborEncode(value, Int32(truncatingIfNeeded: maxNestingLevel), &encoded) else {
            return nil
        }
        return encoded
    }

    /// The byte `prefix`, then `write(value)` at the default nesting level, in one array with room for `capacity`
    /// bytes; nil if `value` nests deeper.
    static func write(_ value: CBOR, prefix: UInt8, reservingCapacity capacity: Int) -> [UInt8]? {
        var encoded: [UInt8] = []
        encoded.reserveCapacity(capacity)
        encoded.append(prefix)
        guard cborEncode(value, Int32(defaultWriteNestingLevel), &encoded) else {
            return nil
        }
        return encoded
    }

    /// `write(.map(["fmt": format, "attStmt": attStatement, "authData": .byteString(authData)]))` at the default
    /// nesting level, without building the map (CTAPLess order: "fmt", "attStmt", "authData"); nil if it nests deeper.
    static func writeAttestationObject(format: CBOR, attStatement: CBOR, authData: [UInt8]) -> [UInt8]? {
        let level = defaultWriteNestingLevel - 1
        var encoded: [UInt8] = []
        encoded.reserveCapacity(authData.count + 64)
        cborStartItem(cborMajorMap, 3, &encoded)
        guard cborEncode(.string("fmt"), Int32(level), &encoded), cborEncode(format, Int32(level), &encoded),
            cborEncode(.string("attStmt"), Int32(level), &encoded), cborEncode(attStatement, Int32(level), &encoded),
            cborEncode(.string("authData"), Int32(level), &encoded), cborEncode(.byteString(authData), Int32(level), &encoded) else {
            return nil
        }
        return encoded
    }
}

private func cborEncode(_ node: CBOR, _ maxNestingLevel: Int32, _ encoded: inout [UInt8]) -> Bool {
    if maxNestingLevel < 0 {
        return false
    }
    switch node {
    case .none:
        cborStartItem(cborMajorByteString, 0, &encoded)
    case .integer(let value):
        if value >= 0 {
            cborStartItem(cborMajorUnsigned, UInt64(value), &encoded)
        } else {
            cborStartItem(cborMajorNegative, UInt64(bitPattern: ~value), &encoded) // -(value + 1)
        }
    case .byteString(let bytes):
        cborStartItem(cborMajorByteString, UInt64(bytes.count), &encoded)
        encoded.append(contentsOf: bytes)
    case .string(let string):
        let utf8 = string.utf8
        cborStartItem(cborMajorString, UInt64(utf8.count), &encoded)
        encoded.append(contentsOf: utf8)
    case .array(let array):
        cborStartItem(cborMajorArray, UInt64(array.count), &encoded)
        for element in array {
            guard cborEncode(element, maxNestingLevel - 1, &encoded) else {
                return false
            }
        }
    case .map(let map):
        cborStartItem(cborMajorMap, UInt64(map.count), &encoded)
        for entry in map.entries {
            guard cborEncode(entry.key, maxNestingLevel - 1, &encoded), cborEncode(entry.value, maxNestingLevel - 1, &encoded) else {
                return false
            }
        }
    case .simple(let value):
        cborStartItem(cborMajorSimpleValue, UInt64(value.rawValue), &encoded)
    }
    return true
}

/// The most entries `cborEncode` walks in place in a C++ map: each map subscript costs O(index) (`std::next`), so a
/// larger map is walked as one flattened clone, keeping the walk linear.
private let cborMapInPlaceLimit = 16

/// Encodes the C++ value for `cborWrite`, walking `node` in place through its borrowing reads.
private func cborEncode(_ node: borrowing cbor.CBORValue, _ maxNestingLevel: Int32, _ sink: inout fido.WebAuthnByteSink) -> Bool {
    if maxNestingLevel < 0 {
        return false
    }
    switch node.type() {
    case .None:
        cborStartItem(cborMajorByteString, 0, &sink)
    case .Unsigned:
        cborStartItem(cborMajorUnsigned, UInt64(bitPattern: node.integerValue()), &sink)
    case .Negative:
        cborStartItem(cborMajorNegative, UInt64(bitPattern: ~node.integerValue()), &sink) // -(value + 1)
    case .ByteString:
        let bytes = node.byteStringValue()
        cborStartItem(cborMajorByteString, UInt64(bytes.size()), &sink)
        addBytes(&sink, bytes.span())
    case .String:
        cborEncodeString(node.stringValue(), &sink)
    case .Array:
        let count = node.arraySize()
        cborStartItem(cborMajorArray, UInt64(count), &sink)
        for index in 0..<count {
            guard cborEncode(node[index], maxNestingLevel - 1, &sink) else {
                return false
            }
        }
    case .Map:
        let count = node.mapSize()
        cborStartItem(cborMajorMap, UInt64(count), &sink)
        if count > cborMapInPlaceLimit {
            if maxNestingLevel == 0 {
                return false // The first key already exceeds the nesting level.
            }
            // takeMapEntries gives key, value, key, value, ... in CTAPLess order.
            var copy = node.clone()
            let flattened = copy.takeMapEntries()
            for index in 0..<flattened.arraySize() {
                guard cborEncode(flattened[index], maxNestingLevel - 1, &sink) else {
                    return false
                }
            }
            return true
        }
        for index in 0..<count {
            guard cborEncode(node[cbor.CBORValue.MapKeyAt(index: index)], maxNestingLevel - 1, &sink),
                cborEncode(node[cbor.CBORValue.MapValueAt(index: index)], maxNestingLevel - 1, &sink) else {
                return false
            }
        }
    case .SimpleValue:
        cborStartItem(cborMajorSimpleValue, UInt64(node.simpleValue().rawValue), &sink)
    default:
        return false // ASSERT_NOT_REACHED
    }
    return true
}

/// The major type, and `size` in the fewest bytes.
private func cborStartItem(_ majorType: UInt8, _ size: UInt64, _ encoded: inout [UInt8]) {
    let head = majorType << cborMajorTypeBitShift
    if size < UInt64(cborAdditionalInformation1Byte) {
        encoded.append(head | UInt8(size))
        return
    }
    let additionalInformation: UInt8
    let byteCount: Int
    if size <= 0xFF {
        additionalInformation = cborAdditionalInformation1Byte
        byteCount = 1
    } else if size <= 0xFFFF {
        additionalInformation = cborAdditionalInformation2Bytes
        byteCount = 2
    } else if size <= 0xFFFF_FFFF {
        additionalInformation = cborAdditionalInformation4Bytes
        byteCount = 4
    } else {
        additionalInformation = cborAdditionalInformation8Bytes
        byteCount = 8
    }
    encoded.append(head | additionalInformation)
    var shift = byteCount - 1
    while shift >= 0 {
        encoded.append(UInt8(truncatingIfNeeded: size >> UInt64(shift * 8)))
        shift -= 1
    }
}

/// `cborStartItem` into the output vector.
private func cborStartItem(_ majorType: UInt8, _ size: UInt64, _ sink: inout fido.WebAuthnByteSink) {
    let head = majorType << cborMajorTypeBitShift
    if size < UInt64(cborAdditionalInformation1Byte) {
        sink.addByte(head | UInt8(size))
        return
    }
    let additionalInformation: UInt8
    let byteCount: Int
    if size <= 0xFF {
        additionalInformation = cborAdditionalInformation1Byte
        byteCount = 1
    } else if size <= 0xFFFF {
        additionalInformation = cborAdditionalInformation2Bytes
        byteCount = 2
    } else if size <= 0xFFFF_FFFF {
        additionalInformation = cborAdditionalInformation4Bytes
        byteCount = 4
    } else {
        additionalInformation = cborAdditionalInformation8Bytes
        byteCount = 8
    }
    sink.addByte(head | additionalInformation)
    var shift = byteCount - 1
    while shift >= 0 {
        sink.addByte(UInt8(truncatingIfNeeded: size >> UInt64(shift * 8)))
        shift -= 1
    }
}

/// A text string item of `string.utf8()` (`utf8Bytes(of:)`) into the output vector: 8-bit strings without an
/// intermediate array.
private func cborEncodeString(_ string: borrowing WTF.String, _ sink: inout fido.WebAuthnByteSink) {
    if string.length() == 0 {
        cborStartItem(cborMajorString, 0, &sink)
        return
    }
    guard string.is8Bit() else {
        let utf8 = utf8Bytes(of: string)
        cborStartItem(cborMajorString, UInt64(utf8.count), &sink)
        addBytes(&sink, utf8.span)
        return
    }
    let characters: Span<WTF.Latin1Character> = string.span8()
    var utf8Count = characters.count
    for index in characters.indices where characters[index].value >= 0x80 {
        utf8Count += 1
    }
    cborStartItem(cborMajorString, UInt64(utf8Count), &sink)
    if utf8Count == characters.count {
        // ASCII Latin-1 bytes are their own UTF-8: one append.
        addBytes(&sink, WTF.bytesOfLatin1Characters(characters))
        return
    }
    for index in characters.indices {
        let character = characters[index].value
        if character < 0x80 {
            sink.addByte(character)
        } else {
            sink.addByte(0xC0 | character >> 6)
            sink.addByte(0x80 | character & 0x3F)
        }
    }
}

// MARK: - Crossing to and from C++

/// The bytes of `span` as an array.
func makeByteArray(_ span: Span<UInt8>) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: span.count)
    var destination = bytes.mutableSpan
    for index in span.indices {
        destination[index] = span[index]
    }
    return bytes
}

/// The bytes of `vector` as an array.
func makeByteArray(_ vector: borrowing cbor.CBORValue.BinaryValue) -> [UInt8] {
    makeByteArray(vector.span())
}

/// A `Vector<uint8_t>` of `bytes`.
func makeByteVector(_ bytes: [UInt8]) -> cbor.CBORValue.BinaryValue {
    makeByteVector(bytes.span)
}

/// A `Vector<uint8_t>` of `bytes`.
func makeByteVector(_ bytes: Span<UInt8>) -> cbor.CBORValue.BinaryValue {
    var sink = fido.WebAuthnByteSink()
    sink.reserve(bytes.count)
    addBytes(&sink, bytes)
    return sink.take()
}

/// Appends `bytes` to `sink` in one copy. An empty span is not passed on: it traps at a std::span parameter.
@inline(always)
func addBytes(_ sink: inout fido.WebAuthnByteSink, _ bytes: Span<UInt8>) {
    if bytes.isEmpty {
        return
    }
    sink.add(bytes)
}

/// `string.utf8()` (`LenientConversion`): its characters as UTF-8, each unpaired surrogate as U+FFFD.
func utf8Bytes(of string: borrowing WTF.String) -> [UInt8] {
    var bytes: [UInt8] = []
    let length = Int(string.length())
    if length == 0 {
        return bytes
    }
    if string.is8Bit() {
        let characters: Span<WTF.Latin1Character> = string.span8()
        bytes.reserveCapacity(length)
        for index in characters.indices {
            let character = characters[index].value
            if character < 0x80 {
                bytes.append(character)
            } else {
                bytes.append(0xC0 | character >> 6)
                bytes.append(0x80 | character & 0x3F)
            }
        }
        return bytes
    }
    let units: Span<UInt16> = string.span16()
    bytes.reserveCapacity(length)
    var index = 0
    while index < units.count {
        var scalar = UInt32(units[index])
        index += 1
        if scalar & 0xF800 == 0xD800 {
            if scalar < 0xDC00 && index < units.count && units[index] & 0xFC00 == 0xDC00 {
                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (UInt32(units[index]) - 0xDC00)
                index += 1
            } else {
                scalar = 0xFFFD
            }
        }
        if scalar < 0x80 {
            bytes.append(UInt8(scalar))
        } else if scalar < 0x800 {
            bytes.append(UInt8(0xC0 | scalar >> 6))
            bytes.append(UInt8(0x80 | scalar & 0x3F))
        } else if scalar < 0x10000 {
            bytes.append(UInt8(0xE0 | scalar >> 12))
            bytes.append(UInt8(0x80 | scalar >> 6 & 0x3F))
            bytes.append(UInt8(0x80 | scalar & 0x3F))
        } else {
            bytes.append(UInt8(0xF0 | scalar >> 18))
            bytes.append(UInt8(0x80 | scalar >> 12 & 0x3F))
            bytes.append(UInt8(0x80 | scalar >> 6 & 0x3F))
            bytes.append(UInt8(0x80 | scalar & 0x3F))
        }
    }
    return bytes
}

/// `string` as a Swift string, each unpaired surrogate as U+FFFD: the characters the writer encodes for it.
func makeSwiftString(_ string: borrowing WTF.String) -> Swift.String {
    let length = Int(string.length())
    if length != 0 {
        if string.is8Bit() {
            // ASCII Latin-1 bytes are their own UTF-8: the string is copied from them, with no temporary array.
            let bytes: Span<UInt8> = WTF.bytesOfLatin1Characters(string.span8())
            var combined: UInt8 = 0
            for index in bytes.indices {
                combined |= bytes[index]
            }
            if combined < 0x80, let characters = try? UTF8Span(validating: bytes) {
                return Swift.String(copying: characters)
            }
        }
    }
    return Swift.String(decoding: utf8Bytes(of: string), as: UTF8.self)
}

/// `string` as a WTF string (`emptyString()` when empty, as `String::fromUTF8` gives).
func makeWTFString(_ string: Swift.String) -> WTF.String {
    let utf8 = string.utf8
    if utf8.isEmpty {
        return fido.emptyWTFString()
    }
    let bytes: Span<UInt8> = utf8.span
    var isASCII = true
    for index in bytes.indices where bytes[index] >= 0x80 {
        isASCII = false
        break
    }
    if isASCII {
        return WTF.String(WTF.latin1CharactersOfBytes(bytes))
    }
    let units = Array(string.utf16)
    return WTF.String(units.span)
}

extension CBOR {
    /// The Swift value of `value`, whose parts this takes (it is left holding empty or `none` parts).
    init(taking value: inout cbor.CBORValue) {
        switch value.type() {
        case .Unsigned, .Negative:
            self = .integer(value.integerValue())
        case .ByteString:
            self = .byteString(makeByteArray(value.byteStringValue()))
        case .String:
            self = .string(makeSwiftString(value.stringValue()))
        case .Array:
            let count = value.arraySize()
            var array: [CBOR] = []
            array.reserveCapacity(count)
            for index in 0..<count {
                var element = value.takeArrayElement(index)
                array.append(CBOR(taking: &element))
            }
            self = .array(array)
        case .Map:
            // takeMapEntries gives key, value, key, value, ... in CTAPLess order, with unique keys.
            var flattened = value.takeMapEntries()
            let count = flattened.arraySize()
            var map = Map()
            var index = 0
            while index + 1 < count {
                var entryKey = flattened.takeArrayElement(index)
                var entryValue = flattened.takeArrayElement(index + 1)
                map.appendInOrder(CBOR(taking: &entryKey), CBOR(taking: &entryValue))
                index += 2
            }
            self = .map(map)
        case .SimpleValue:
            guard let simpleValue = SimpleValue(rawValue: UInt8(value.simpleValue().rawValue)) else {
                preconditionFailure("CBORValue::SimpleValue has four values")
            }
            self = .simple(simpleValue)
        default:
            self = .none
        }
    }

    /// The `CBORValue` of this value.
    func makeCBORValue() -> cbor.CBORValue {
        switch self {
        case .integer(let value):
            return cbor.CBORValue(value)
        case .byteString(let bytes):
            return cbor.CBORValue.makeByteString(makeByteVector(bytes))
        case .string(let string):
            return cbor.CBORValue.makeString(makeWTFString(string))
        case .array(let array):
            var result = cbor.CBORValue(.Array)
            for element in array {
                result.arrayAppend(element.makeCBORValue())
            }
            return result
        case .map(let map):
            var result = cbor.CBORValue(.Map)
            for entry in map.entries {
                let inserted = result.mapInsert(entry.key.makeCBORValue(), entry.value.makeCBORValue())
                precondition(inserted, "CBOR.Map keys are unique under CTAPLess")
            }
            return result
        case .simple(let value):
            guard let simpleValue = cbor.CBORValue.SimpleValue(rawValue: Int32(value.rawValue)) else {
                preconditionFailure("CBORValue::SimpleValue has four values")
            }
            return cbor.CBORValue(simpleValue)
        case .none:
            return cbor.CBORValue()
        }
    }

    /// The `CBORValue::MapValue` of a map (traps on any other value).
    func makeMapValue() -> cbor.CBORValue.MapValue {
        precondition(isMap, "not a CBOR map")
        var value = makeCBORValue()
        return value.takeMap()
    }
}

/// Decodes one data item from the start of `data`, the caller's `std::span` (`cbor::CBORReader::Bytes`). With
/// `allowExtraneousData` false, bytes after it are `ExtraneousData`. The value is a NONE value when the read fails.
///
/// The span is used only inside this call. The caller keeps the buffer alive and unwritten, and nothing called here reaches it.
/// `result` is filled in place so the generated thunk does not move it.
/// FIXME: Take a `Span<UInt8>` parameter once a `std::span` can cross safely (rdar://186723514).
@_expose(Cxx)
func cborReadResult(_ data: cbor.CBORReader.Bytes, _ maxNestingLevel: Int32, _ allowExtraneousData: Bool, _ result: inout cbor.CBORReader.ReadResult) {
    let bytes = unsafe Span<UInt8>(_unsafeCxxSpan: data)
    var reader = CBORDecoder()
    if let value = reader.decodeValue(bytes, maxNestingLevel) {
        if !allowExtraneousData && reader.position != bytes.count {
            reader.error = .ExtraneousData
        }
        if reader.error == .CBORNoError {
            result.value = value
        }
    }
    result.error = reader.error
    result.bytesConsumed = reader.position
}

/// The definition of `cbor::CBORWriter::write`, which forwards here; an empty result is its nullopt (an encoding is
/// never empty).
///
/// `node` is owned by the caller and only read here.
@_expose(Cxx)
func cborWrite(_ node: borrowing cbor.CBORValue, _ maxNestingLevel: Int) -> cbor.CBORValue.BinaryValue {
    var sink = fido.WebAuthnByteSink()
    sink.reserve(64)
    guard cborEncode(node, Int32(truncatingIfNeeded: maxNestingLevel), &sink) else {
        return cbor.CBORValue.BinaryValue()
    }
    return sink.take()
}

#endif // !os(watchOS) && !targetEnvironment(macCatalyst)
