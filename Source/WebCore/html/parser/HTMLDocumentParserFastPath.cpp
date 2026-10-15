/*
 * Copyright (C) 2023 The Chromium Authors.
 * Copyright (C) 2023 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 *    * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *    * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *    * Neither the name of Google LLC nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "HTMLDocumentParserFastPath.h"

#include "ContainerNode.h"
#include "Document.h"
#include "ElementAncestorIteratorInlines.h"
#include "ElementTraversal.h"
#include "HTMLAnchorElement.h"
#include "HTMLBRElement.h"
#include "HTMLBodyElement.h"
#include "HTMLButtonElement.h"
#include "HTMLDivElement.h"
#include "HTMLEntityParser.h"
#include "HTMLInputElement.h"
#include "HTMLLIElement.h"
#include "HTMLLabelElement.h"
#include "HTMLNameCache.h"
#include "HTMLNames.h"
#include "HTMLOListElement.h"
#include "HTMLParagraphElement.h"
#include "HTMLSelectElement.h"
#include "HTMLSpanElement.h"
#include "HTMLUListElement.h"
#include "NodeName.h"
#include "ParserContentPolicy.h"
#include "QualifiedName.h"
#include "Settings.h"
#include <span>
#include <wtf/CheckedRef.h>
#include <wtf/Vector.h>
#include <wtf/WeakRef.h>
#include <wtf/text/AtomString.h>
#include <wtf/text/FastCharacterComparison.h>
#include <wtf/text/ParsingUtilities.h>
#include <wtf/text/StringParsingBuffer.h>

#include "WebCore-Swift.h"

class NewlineThenWhitespaceStringsTable {
public:
    static constexpr unsigned maxSpaceCount = 32;

    ALWAYS_INLINE static String getCachedWhitespace(unsigned spaceCount)
    {
        ASSERT(spaceCount <= maxSpaceCount);
        auto& cache = whitespaceStringCache();
        return cache[spaceCount];
    }

private:
    using WhitespaceStringCache = std::array<String, maxSpaceCount + 1>;

    static WhitespaceStringCache& whitespaceStringCache()
    {
        static MainThreadNeverDestroyed<WhitespaceStringCache> cache { []() {
            WhitespaceStringCache stringsCache;
            Latin1Character chars[maxSpaceCount + 1] = { '\n' };
            std::ranges::fill(std::span(chars).subspan<1u>(), ' ');
            // Pre-populate the cache with \n + (' ' * spaceCount) strings
            for (unsigned spaceCount = 0; spaceCount <= maxSpaceCount; ++spaceCount)
                stringsCache[spaceCount] = String(std::span(chars).first(spaceCount + 1));
            return stringsCache;
        }() };
        return cache.get();
    }
};

namespace WebCore {

static constexpr unsigned s_maxCachedStringSize = 40000;

NODELETE unsigned maxCachedSetInnerHTMLStringSize()
{
    return s_maxCachedStringSize;
}

// HTMLFastPathParser.swift uses these values as literals.
static_assert(Settings::defaultMaximumHTMLParserDOMTreeDepth == 512);
static_assert(NewlineThenWhitespaceStringsTable::maxSpaceCount == 32);

[[clang::always_inline]] String newlineThenWhitespaceStringForFastPath(unsigned spaceCount)
{
    return NewlineThenWhitespaceStringsTable::getCachedWhitespace(spaceCount);
}

// Each Swift caller passes an empty span for the width it does not use.
[[clang::always_inline]] uint64_t consumeHTMLEntityForFastPath(HTMLFastPathLatin1Span latin1Source NOESCAPE, HTMLFastPathUTF16Span utf16Source NOESCAPE, char16_t additionalAllowedCharacter, std::span<char16_t> decoded NOESCAPE, size_t decodedOffset)
{
    auto consume = [&]<typename CharacterType>(std::span<const CharacterType> source) {
        StringParsingBuffer<CharacterType> buffer { source };
        auto entity = consumeHTMLEntity(buffer, additionalAllowedCharacter);
        auto characters = entity.span();
        std::ranges::copy(characters, decoded.subspan(decodedOffset, characters.size()).begin());
        return static_cast<uint64_t>(source.size() - buffer.lengthRemaining()) << 2 | characters.size();
    };
    return latin1Source.empty() ? consume(utf16Source) : consume(latin1Source);
}

enum class FragmentReuseResult : uint8_t {
    Success,
    CannotReuse,
    ParseFailure
};

ALWAYS_INLINE static bool isCachedSubtreeValid(Node& cachedContainer)
{
    return !cachedContainer.hasDidMutateSubtreeAfterSetInnerHTML();
}

template<typename CharacterType>
NODELETE static bool isCachedPrefixMatch(const CachedSetInnerHTML& cache, std::span<const CharacterType> source, const ElementName& elementName)
{
    if (cache.source.length() > source.size())
        return false;

    if (cache.contextElementName != elementName)
        return false;

    // Check if character types and prefix content match.
    StringView cachedStringView(cache.source);
    if (cachedStringView.is8Bit()) {
        if constexpr (std::is_same_v<CharacterType, Latin1Character>) {
            auto cachedSourceSpan = cachedStringView.span8();
            return std::equal(cachedSourceSpan.begin(), cachedSourceSpan.end(), source.begin());
        }
        return false;
    }
    if constexpr (std::is_same_v<CharacterType, char16_t>) {
        auto cachedSourceSpan = cachedStringView.span16();
        return std::equal(cachedSourceSpan.begin(), cachedSourceSpan.end(), source.begin());
    }
    return false;
}

template<typename CharacterType>
static FragmentReuseResult tryAvoidParsingByCloningExistingSubtree(std::span<const CharacterType> source, ContainerNode& destinationParent, Element& contextElement)
{
    Ref destinationParentDocument = destinationParent.document();
    auto& cache = destinationParentDocument->cachedSetInnerHTML();
    RefPtr cachedContainer = cache.cachedContainer.get();
    if (!cachedContainer)
        return FragmentReuseResult::CannotReuse;
    if (!isCachedSubtreeValid(*cachedContainer)) {
        destinationParentDocument->invalidateCachedSetInnerHTML();
        return FragmentReuseResult::CannotReuse;
    }

    if (!isCachedPrefixMatch<CharacterType>(cache, source, contextElement.elementName()))
        return FragmentReuseResult::CannotReuse;

    // Only allow prefix reuse if cached string ends with '>' or whitespace to avoid splitting text/entities.
    // Example: "<br>&apos", then "<br>&apos;" would incorrectly split the entity into "&apos" and ";".
    if (cache.source.length() < source.size() && !cache.source.isEmpty()) {
        char16_t lastChar = cache.source[cache.source.length() - 1];
        if (lastChar != '>' && !isASCIIWhitespace(lastChar))
            return FragmentReuseResult::CannotReuse;
    }

    auto unparsedSuffix = source.subspan(cache.source.length());
    return cloneCachedPrefixAndParseSuffix(unparsedSuffix, destinationParent, contextElement, cachedContainer.get());
}

template<typename CharacterType>
static FragmentReuseResult cloneCachedPrefixAndParseSuffix(std::span<const CharacterType> unparsedSuffix, ContainerNode& destinationParent, Element& contextElement, Node* cachedContainer)
{

    ASSERT(cachedContainer->hasChildNodes());

    for (RefPtr nodeToClone = cachedContainer->firstChild(); nodeToClone; nodeToClone = nodeToClone->nextSibling()) {
        Ref<Node> clonedChild = nodeToClone->cloneNodeInternal(protect(destinationParent.document()), Node::CloningOperation::SelfOnly, nullptr);
        if (RefPtr nodeToCloneAsContainer = dynamicDowncast<ContainerNode>(*nodeToClone))
            nodeToCloneAsContainer->cloneSubtreeForFastParser(protect(destinationParent.document()), nullptr, downcast<ContainerNode>(clonedChild.get()), 0);
        destinationParent.parserAppendChildIntoIsolatedTree(clonedChild.get());
    }

    if (unparsedSuffix.empty())
        return FragmentReuseResult::Success;

    if (!parseHTMLFragmentForFastPath(unparsedSuffix, protect(destinationParent.document()).ptr(), &destinationParent, &contextElement))
        return FragmentReuseResult::ParseFailure;
    return FragmentReuseResult::Success;
}

static bool canUseFastPath(Element& contextElement, OptionSet<ParserContentPolicy> policy)
{
    // We could probably allow other content policies too, as we do not support scripts or plugins anyway.
    if (!policy.contains(ParserContentPolicy::AllowScriptingContent))
        return false;

    // If we are within a form element, we would need to create associations, which we do not. Therefore, we do not
    // support this case. See HTMLConstructionSite::initFragmentParsing() and HTMLConstructionSite::createElement()
    // for the corresponding code on the slow-path.
    if (!contextElement.document().isTemplateDocument() && lineageOfType<HTMLFormElement>(contextElement).first())
        return false;

    return true;
}

template<typename CharacterType>
static bool tryFastParsingHTMLFragmentImpl(std::span<const CharacterType> source, Document& document, ContainerNode& destinationParent, Element& contextElement)
{
    auto reuseResult = tryAvoidParsingByCloningExistingSubtree(source, destinationParent, contextElement);
    if (reuseResult == FragmentReuseResult::Success)
        return true;
    if (reuseResult == FragmentReuseResult::ParseFailure)
        return false;

    return parseHTMLFragmentForFastPath(source, &document, &destinationParent, &contextElement);
}

bool tryFastParsingHTMLFragment(StringView source, Document& document, ContainerNode& destinationParent, Element& contextElement, OptionSet<ParserContentPolicy> policy)
{
    if (!canUseFastPath(contextElement, policy))
        return false;

    if (source.is8Bit())
        return tryFastParsingHTMLFragmentImpl(source.span8(), document, destinationParent, contextElement);
    return tryFastParsingHTMLFragmentImpl(source.span16(), document, destinationParent, contextElement);
}

#undef FOR_EACH_SUPPORTED_TAG

} // namespace WebCore
