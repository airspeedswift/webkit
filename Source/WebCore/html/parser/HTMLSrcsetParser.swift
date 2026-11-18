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

// WebCore_Private.Core's headers use types defined in these JavaScriptCore_Private.Cxx submodules and in
// wtf.Core.Stopwatch.
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import wtf.Core.Stopwatch
internal import wtf.Core.StdLibExtras
internal import WebCore_Private.Core.HTMLMicrosyntaxesSwiftTypes
internal import WebCore_Private.Core.HTMLSrcsetParser

// The functions exposed to C++ only make Spans of their arguments and call a function marked @inline(never). That
// keeps them small enough for link-time optimization to inline them into their C++ callers, where the std::span
// accessors they call are inlined too.

// MARK: Candidates

/// The first image candidate of a srcset attribute at or after `position`, as
/// parseImageCandidatesFromSrcsetAttribute() finds them, or one that is not `found` when there are no more, for an
/// 8-bit StringView.
///
/// A candidate that is found advances `position` to where the search for the next one starts.
/// `characters` are the characters of the caller's StringView. They stay allocated and unchanged for the call, since
/// the caller holds their string and this function only reads them, as does WTF::parseDouble(), the only C++ it passes
/// them to, and every value of a Latin-1 code unit is a valid character.
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxNextSrcsetCandidate8(
    _ characters: WebCore.HTMLMicrosyntaxSpan8,
    _ position: inout UInt32
) -> WebCore.HTMLMicrosyntaxSrcsetCandidate {
    let span = unsafe Span<WTF.Latin1Character>(_unsafeCxxSpan: characters)
    return nextSrcsetCandidate(span, &position)
}

/// htmlMicrosyntaxNextSrcsetCandidate8() for a 16-bit StringView, whose characters stay allocated and unchanged for
/// the call in the same way, and every value of a UTF-16 code unit is a valid character.
///
/// FIXME: Take the characters as Spans when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxNextSrcsetCandidate16(
    _ characters: WebCore.HTMLMicrosyntaxSpan16,
    _ position: inout UInt32
) -> WebCore.HTMLMicrosyntaxSrcsetCandidate {
    let span = unsafe Span<UInt16>(_unsafeCxxSpan: characters)
    return nextSrcsetCandidate(span, &position)
}

extension HTMLMicrosyntaxCodeUnit {
    @inline(always)
    fileprivate var isHTMLSpaceOrComma: Bool {
        htmlMicrosyntaxIsASCIIWhitespace || htmlMicrosyntaxMatches(",")
    }
}

// http://picture.responsiveimages.org/#parse-srcset-attr
@inline(never)
private func nextSrcsetCandidate<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>,
    _ next: inout UInt32
) -> WebCore.HTMLMicrosyntaxSrcsetCandidate {
    var position = Int(next)
    while position < characters.count {
        // 4. Splitting loop: Collect a sequence of characters that are space characters or U+002C COMMA characters.
        while position < characters.count, characters[position].isHTMLSpaceOrComma {
            position += 1
        }
        // Contrary to spec language - descriptor parsing happens on each candidate, so when we reach the end, we can exit.
        guard position < characters.count else {
            break
        }

        // 6. Collect a sequence of characters that are not space characters, and let that be url.
        let urlStart = position
        position = characters.htmlMicrosyntaxIndexOfASCIIWhitespace(from: position)
        var urlEnd = position

        var descriptors = SrcsetDescriptors()
        // 8. If url ends with a U+002C COMMA character (,), remove all trailing U+002C COMMA characters from url,
        // and leave its descriptors unparsed.
        // Cannot overflow: the scan stops after the url's first character, so urlEnd is above urlStart.
        if characters[urlEnd &- 1].htmlMicrosyntaxMatches(",") {
            // Cannot overflow here or in the loop condition: urlEnd is above urlStart, an index.
            urlEnd &-= 1
            while urlEnd > urlStart, characters[urlEnd &- 1].htmlMicrosyntaxMatches(",") {
                urlEnd -= 1
            }
            // If url is empty, then jump to the step labeled splitting loop.
            if urlEnd == urlStart {
                continue
            }
        } else {
            // Contrary to spec language - descriptor parsing happens on each candidate.
            position = tokenizeSrcsetDescriptors(
                characters,
                from: characters.htmlMicrosyntaxIndexAfterASCIIWhitespace(from: position),
                into: &descriptors
            )
            guard descriptors.isValid else {
                continue
            }
        }

        // The attribute's length, and so every index into it, fits in 32 bits.
        next = UInt32(truncatingIfNeeded: position)
        return WebCore.HTMLMicrosyntaxSrcsetCandidate(
            start: UInt32(truncatingIfNeeded: urlStart),
            // Cannot overflow: urlEnd is above urlStart, and both index the characters.
            length: UInt32(truncatingIfNeeded: urlEnd &- urlStart),
            density: descriptors.density,
            width: descriptors.width,
            found: true
        )
    }
    return WebCore.HTMLMicrosyntaxSrcsetCandidate(
        start: 0,
        length: 0,
        density: Float(WebCore.UninitializedDescriptor),
        width: WebCore.UninitializedDescriptor,
        found: false
    )
}

// MARK: Descriptors

/// The descriptors of an image candidate, as DescriptorParsingResult holds them: each is UninitializedDescriptor
/// until it is given.
///
/// A candidate whose descriptors are not valid is dropped.
private struct SrcsetDescriptors {
    var density = Float(WebCore.UninitializedDescriptor)
    var width = WebCore.UninitializedDescriptor
    var height = WebCore.UninitializedDescriptor
    var isValid = true

    var hasDensity: Bool { density >= 0 }
    var hasWidth: Bool { width >= 0 }
    var hasHeight: Bool { height >= 0 }

    /// Parses one descriptor token, as parseDescriptors() does each in turn: its last character names it and the
    /// characters before it are its value.
    ///
    /// Once one is not valid, the rest are not looked at.
    mutating func parse<CodeUnit: HTMLMicrosyntaxCodeUnit>(_ descriptor: Span<CodeUnit>) {
        guard isValid, !descriptor.isEmpty else {
            return
        }
        let name = descriptor[descriptor.count - 1]
        let value = descriptor.extracting(droppingLast: 1)
        if name.htmlMicrosyntaxMatches("x") {
            guard !hasDensity, !hasHeight, !hasWidth, let density = htmlMicrosyntaxParseValidHTMLFloatingPointNumber(value), density >= 0
            else {
                isValid = false
                return
            }
            self.density = Float(density)
        } else if name.htmlMicrosyntaxMatches("w") {
            guard !hasDensity, !hasWidth, let width = htmlMicrosyntaxParseValidHTMLNonNegativeInteger(value), width > 0 else {
                isValid = false
                return
            }
            self.width = width
        } else if name.htmlMicrosyntaxMatches("h") {
            // This is here only for future compat purposes. The value of the 'h' descriptor is not used.
            guard !hasDensity, !hasHeight, let height = htmlMicrosyntaxParseValidHTMLNonNegativeInteger(value), height > 0 else {
                isValid = false
                return
            }
            self.height = height
        } else {
            isValid = false
        }
    }

    /// Checks what parseDescriptors() checks once every descriptor is parsed.
    mutating func finish() {
        if hasHeight && !hasWidth {
            isValid = false
        }
    }
}

private enum SrcsetDescriptorTokenizerState {
    case initial
    case inParenthesis
    case afterToken
}

/// Splits the descriptors that start at `start` into tokens, as tokenizeDescriptors() does, keeping what is between
/// parentheses in one token, and parses each into `descriptors`.
///
/// Returns the index after them: past the comma that ends them, or the end of the characters.
private func tokenizeSrcsetDescriptors<CodeUnit: HTMLMicrosyntaxCodeUnit>(
    _ characters: Span<CodeUnit>,
    from start: Int,
    into descriptors: inout SrcsetDescriptors
) -> Int {
    var state = SrcsetDescriptorTokenizerState.initial
    var position = start
    var tokenStart = start
    while true {
        switch state {
        case .initial:
            guard position < characters.count else {
                descriptors.parse(characters.extracting(tokenStart..<position))
                descriptors.finish()
                return position
            }
            let character = characters[position]
            if character.htmlMicrosyntaxMatches(",") {
                descriptors.parse(characters.extracting(tokenStart..<position))
                descriptors.finish()
                return position + 1
            }
            if character.htmlMicrosyntaxIsASCIIWhitespace {
                descriptors.parse(characters.extracting(tokenStart..<position))
                tokenStart = position + 1
                state = .afterToken
            } else if character.htmlMicrosyntaxMatches("(") {
                state = .inParenthesis
            }
        case .inParenthesis:
            guard position < characters.count else {
                descriptors.parse(characters.extracting(tokenStart..<position))
                descriptors.finish()
                return position
            }
            if characters[position].htmlMicrosyntaxMatches(")") {
                state = .initial
            }
        case .afterToken:
            guard position < characters.count else {
                descriptors.finish()
                return position
            }
            if !characters[position].htmlMicrosyntaxIsASCIIWhitespace {
                // The next token starts here: read this character again in the initial state.
                state = .initial
                tokenStart = position
                continue
            }
        }
        position += 1
    }
}

// MARK: Picking a candidate

/// The candidate pickBestImageCandidate() picks, as an index into `keys`, which holds at least one key.
///
/// The candidate's key gets the density pickBestImageCandidate() gives that candidate.
/// `keys` holds one key per candidate, in storage the caller owns for the call. Nothing else reads or writes it while
/// this function reads it and writes the density, since it calls no C++ meanwhile, and every value of a key's fields
/// is a valid value.
/// FIXME: Take the keys as a MutableSpan when Swift can receive a std::span safely (rdar://186723514).
@_expose(Cxx)
func htmlMicrosyntaxPickBestSrcsetCandidate(
    _ deviceScaleFactor: Float,
    _ keys: WebCore.HTMLMicrosyntaxSrcsetPickKeys,
    _ sourceSize: Float,
    _ hasSourceSize: Bool
) -> UInt32 {
    let span = unsafe MutableSpan<WebCore.HTMLMicrosyntaxSrcsetPickKey>(_unsafeCxxSpan: keys)
    return pickBestSrcsetCandidate(deviceScaleFactor, span, hasSourceSize ? sourceSize : nil)
}

// http://picture.responsiveimages.org/#normalize-source-densities
extension WebCore.HTMLMicrosyntaxSrcsetPickKey {
    /// The candidate's density once normalized: a width descriptor's width over the source size, or the default
    /// density without a source size, and the default density for a candidate with no density.
    @inline(always)
    fileprivate func normalizedDensity(_ sourceSize: Float?) -> Float {
        if width > 0 {
            guard let sourceSize else {
                return WebCore.DefaultDensityValue
            }
            return Float(width) / sourceSize
        }
        return density < 0 ? WebCore.DefaultDensityValue : density
    }
}

@inline(never)
private func pickBestSrcsetCandidate(
    _ deviceScaleFactor: Float,
    _ keys: consuming MutableSpan<WebCore.HTMLMicrosyntaxSrcsetPickKey>,
    _ sourceSize: Float?
) -> UInt32 {
    guard !keys.isEmpty else {
        return 0
    }
    let winner = bestSrcsetCandidate(deviceScaleFactor, keys.span, sourceSize)
    // pickBestImageCandidate() returns the winner with its density normalized.
    let density = keys[winner].normalizedDensity(sourceSize)
    keys[winner].density = density
    // The keys' count, and so every index into them, fits in 32 bits.
    return UInt32(truncatingIfNeeded: winner)
}

// pickBestImageCandidate() sorts the candidates by density with std::ranges::stable_sort and scans them in that order.
// Without a NaN density, that order is by density, then by position among equal densities, and the scan's result is
// found without sorting: the first candidate in that order that the scan stops at, or else the last; and the earliest
// candidate with the winning density.
private func bestSrcsetCandidate(
    _ deviceScaleFactor: Float,
    _ keys: Span<WebCore.HTMLMicrosyntaxSrcsetPickKey>,
    _ sourceSize: Float?
) -> Int {
    var ignoreSrc = false
    var hasNaNDensity = false
    for index in keys.indices {
        let key = keys[index]
        if key.width > 0 {
            ignoreSrc = true
        }
        if key.normalizedDensity(sourceSize).isNaN {
            hasNaNDensity = true
        }
    }
    if hasNaNDensity {
        return pickBestSrcsetCandidateInKeyOrder(deviceScaleFactor, keys, sourceSize, ignoreSrc)
    }

    var first = -1
    var firstDensity: Float = 0
    var last = 0
    var lastDensity = keys[0].normalizedDensity(sourceSize)
    for index in keys.indices {
        let key = keys[index]
        let density = key.normalizedDensity(sourceSize)
        if density >= lastDensity {
            last = index
            lastDensity = density
        }
        if density >= deviceScaleFactor, !ignoreSrc || key.isSrc == 0, first < 0 || density < firstDensity {
            first = index
            firstDensity = density
        }
    }

    var picked = first < 0 ? last : first
    if ignoreSrc, keys[picked].isSrc != 0 {
        // An ignored src is never the first that the scan stops at, so it is the last candidate, and the one before
        // it is the last of the others. There is one, since some candidate has a width when src is ignored.
        var previous = -1
        var previousDensity: Float = 0
        for index in keys.indices where index != picked {
            let density = keys[index].normalizedDensity(sourceSize)
            if previous < 0 || density >= previousDensity {
                previous = index
                previousDensity = density
            }
        }
        picked = previous
    }
    let winningDensity = keys[picked].normalizedDensity(sourceSize)

    // 16. If an entry b in candidates has the same associated ... pixel density as an earlier entry a in candidates,
    // then remove entry b
    var winner = picked
    var index = 0
    while index < picked {
        if keys[index].normalizedDensity(sourceSize) == winningDensity {
            winner = index
            break
        }
        // Cannot overflow: index is below picked, an index of keys.
        index &+= 1
    }
    return winner
}

// A NaN density (a width over a NaN source size) is unordered, so the stable sort keeps the candidates in their
// order when the other densities are all equal. Otherwise the sort has no order to follow, and the candidates are
// taken in their order then too.
private func pickBestSrcsetCandidateInKeyOrder(
    _ deviceScaleFactor: Float,
    _ keys: Span<WebCore.HTMLMicrosyntaxSrcsetPickKey>,
    _ sourceSize: Float?,
    _ ignoreSrc: Bool
) -> Int {
    var index = 0
    while index < keys.count - 1 {
        let key = keys[index]
        if key.normalizedDensity(sourceSize) >= deviceScaleFactor, !ignoreSrc || key.isSrc == 0 {
            break
        }
        index += 1
    }
    if ignoreSrc, keys[index].isSrc != 0 {
        index -= 1
    }
    let winningDensity = keys[index].normalizedDensity(sourceSize)

    var winner = index
    while index > 0 {
        index -= 1
        guard keys[index].normalizedDensity(sourceSize) == winningDensity else {
            break
        }
        winner = index
    }
    return winner
}
