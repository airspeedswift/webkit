// Copyright (C) 2014-2025 Apple Inc. All rights reserved.
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

import WebKit_Internal.NetworkCacheCxx
import wtf

// The JSON dump of the cache's records (dump.json).
extension NetworkDiskCache {
    func dumpFilePath() -> WTF.String {
        networkCachePath(storage.versionPath, WTF.String("dump.json"))
    }

    func deleteDumpFile() {
        let path = NetworkCacheIsolatedString(dumpFilePath())
        WebKit.NetworkCache.makeDeleteQueue().get()
            .dispatch(
                // Captures only the path's Swift copy.
                consuming: .init(sendable: {
                    _ = WTF.FileSystemImpl.deleteFile(path.string)
                })
            )
    }
}

/// The dump's JSON, built from the traversal's handler and written to the dump file by `write()`.
final class NetworkCacheDumpJSON {
    private let file: WebKit.NetworkCache.DumpFile
    private var json = WTF.StringBuilder()

    init(_ file: WebKit.NetworkCache.DumpFile) {
        self.file = file
    }

    private func appendLiteral(_ string: WTF.String) {
        json.append(string)
    }

    private func appendLiteral(_ string: Swift.String) {
        json.append(WTF.String(string))
    }

    private func appendQuoted(_ string: WTF.String) {
        json.appendQuotedJSONString(string)
    }

    /// The shortest form that reads back as the same value.
    private func appendNumber(_ number: Double) {
        json.append(WTF.String.number(number))
    }

    private func appendInteger(_ number: UInt64) {
        json.append(WTF.String.number(number))
    }

    // Each field after the first of an object is on its own line.
    private func appendField(_ name: Swift.String, quoted value: WTF.String) {
        appendFieldName(name)
        appendQuoted(value)
    }

    private func appendField(_ name: Swift.String, number value: Double) {
        appendFieldName(name)
        appendNumber(value)
    }

    private func appendField(_ name: Swift.String, integer value: UInt64) {
        appendFieldName(name)
        appendInteger(value)
    }

    private func appendFieldName(_ name: Swift.String) {
        appendLiteral(",\n\"\(name)\": ")
    }

    // The fields every record has, from the opening brace to the URL.
    private func appendCommonFields(
        _ key: WebKit.NetworkCache.Key,
        _ info: borrowing WebKit.NetworkCache.Storage.RecordInfo,
        timeStamp: WTF.WallTime,
        url: WTF.String
    ) {
        appendLiteral("{\n\"hash\": ")
        appendQuoted(key.hashAsString())
        appendField("bodySize", integer: UInt64(info.bodySize))
        appendField("worth", number: info.worth)
        appendField("partition", quoted: key.partitionCopy())
        appendField("timestamp", number: timeStamp.secondsSinceEpoch().milliseconds())
        appendField("URL", quoted: url)
    }

    /// Two uppercase hexadecimal digits a byte.
    private func appendQuotedHex(_ hash: WebKit.NetworkCache.CompressionDictionaryHash) {
        var characters: [WTF.Latin1Character] = []
        characters.reserveCapacity(2 * Int(hash.size()))
        for byte in hash {
            characters.append(asciiHexDigit(byte >> 4))
            characters.append(asciiHexDigit(byte & 0xF))
        }
        appendQuoted(WTF.String(characters.span))
    }

    /// The fields in the map's iteration order: the common headers, then the others.
    private func appendHeaders(_ headers: borrowing WebCore.HTTPHeaderMap) {
        var firstHeader = true
        let commonHeaders: Span<WebCore.HTTPHeaderMap.CommonHeader> = headers.commonHeadersSpan()
        for index in commonHeaders.indices {
            appendHeader(
                &firstHeader,
                WebKit.NetworkCache.networkCacheHTTPHeaderNameString(commonHeaders[index].key),
                commonHeaders[index].value
            )
        }
        let uncommonHeaders: Span<WebCore.HTTPHeaderMap.UncommonHeader> = headers.uncommonHeadersSpan()
        for index in uncommonHeaders.indices {
            appendHeader(&firstHeader, uncommonHeaders[index].key, uncommonHeaders[index].value)
        }
    }

    private func appendHeader(_ firstHeader: inout Bool, _ name: WTF.String, _ value: WTF.String) {
        appendLiteral(firstHeader ? "    " : ",\n    ")
        firstHeader = false
        appendQuoted(name)
        appendLiteral(": ")
        appendQuoted(value)
    }

    /// Appends the JSON built since the last write to the file, as UTF-8.
    func write() {
        file.write(json)
        json.clear()
    }

    func close() {
        file.close()
    }
}

// The records' JSON, for NetworkDiskCache.dumpContentsToFile.
extension NetworkCacheDumpJSON {
    func append(
        _ entry: NetworkCacheCompressionDictionaryEntry,
        _ info: borrowing WebKit.NetworkCache.Storage.RecordInfo
    ) {
        let key = entry.key()
        let dictionaryInfo = entry.info()
        appendCommonFields(key, info, timeStamp: entry.timeStamp(), url: key.identifierCopy())
        appendField("bodyShareCount", integer: UInt64(info.bodyShareCount))
        appendField("match", quoted: dictionaryInfo.match)
        appendField("id", quoted: dictionaryInfo.id)
        appendLiteral(",\n\"dictionaryHash\": ")
        appendQuotedHex(entry.hash())
        appendField("expirationTime", number: dictionaryInfo.expirationTime.secondsSinceEpoch().milliseconds())
        appendLiteral(",\n\"matchDest\": [\n")
        appendLiteral(WebKit.NetworkCache.dumpMatchDestinations(dictionaryInfo.matchDest))
        appendLiteral("\n]\n}")
    }

    func append(
        _ entry: NetworkCacheEntry,
        _ info: borrowing WebKit.NetworkCache.Storage.RecordInfo
    ) {
        let response = entry.response()
        appendCommonFields(entry.key(), info, timeStamp: entry.timeStamp(), url: response.urlCopy().stringCopy())
        appendField("bodyHash", quoted: info.bodyHash)
        appendField("bodyShareCount", integer: UInt64(info.bodyShareCount))
        appendLiteral(",\n\"headers\": {\n")
        appendHeaders(response.httpHeaderFieldsCopy())
        appendLiteral("\n}\n}")
    }

    func appendPrologue() {
        appendLiteral("{\n\"entries\": [\n")
    }

    func appendEntrySeparator() {
        appendLiteral(",\n")
    }

    func appendTotals(capacity: UInt64, count: UInt64, bodySize: UInt64, averageWorth: Double) {
        appendLiteral("{}\n],\n\"totals\": {\n\"capacity\": ")
        appendInteger(capacity)
        appendField("count", integer: count)
        appendField("bodySize", integer: bodySize)
        appendField("averageWorth", number: averageWorth)
        appendLiteral("\n}\n}\n")
    }
}
