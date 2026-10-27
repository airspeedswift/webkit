/*
 * Copyright (C) 2008-2025 Apple Inc. All rights reserved.
 * Copyright (C) 2009 Torch Mobile, Inc. http://www.torchmobile.com/
 * Copyright (C) 2010-2023 Google Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "HTMLPreloadScanner.h"

#include "HTMLImageElement.h"
#include "HTMLNames.h"
#include "HTMLSrcsetParser.h"
#include "HTMLTokenizer.h"
#include "InputTypeNames.h"
#include "JSRequestPriority.h"
#include "LazyLoading.h"
#include "LinkLoader.h"
#include "LinkRelAttribute.h"
#include "Logging.h"
#include "MIMETypeRegistry.h"
#include "MediaList.h"
#include "MediaQueryEvaluator.h"
#include "MediaQueryParser.h"
#include "RenderView.h"
#include "ScriptElement.h"
#include "SecurityPolicy.h"
#include "Settings.h"
#include "ShadowRootMode.h"
#include "SizesAttributeParser.h"
#include <wtf/MainThread.h>
#include <wtf/SortedArrayMap.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/WeakRef.h>
#include <wtf/text/StringBuilder.h>

#include "WebCore-Swift.h"
#include <wtf/SetForScope.h>

namespace WebCore {

RequestPriority preloadScannerFetchPriority(std::span<const char16_t> value NOESCAPE)
{
    return parseEnumerationFromString<RequestPriority>(StringView(value).toString()).value_or(RequestPriority::Auto);
}

WTF_MAKE_TZONE_ALLOCATED_IMPL(TokenPreloadScanner);
WTF_MAKE_TZONE_ALLOCATED_IMPL(HTMLPreloadScanner);

ASCIILiteral TokenPreloadScanner::initiatorFor(TagId tagId)
{
    switch (tagId) {
    case TagId::Source:
    case TagId::Img:
        return "img"_s;
    case TagId::Input:
        return "input"_s;
    case TagId::Link:
        return "link"_s;
    case TagId::Script:
        return "script"_s;
    case TagId::Video:
        return "video"_s;
    case TagId::Unknown:
    case TagId::Style:
    case TagId::Base:
    case TagId::Template:
    case TagId::Meta:
    case TagId::Picture:
    case TagId::Svg:
        ASSERT_NOT_REACHED();
        return "unknown"_s;
    }
    ASSERT_NOT_REACHED();
    return "unknown"_s;
}

TokenPreloadScanner::TokenPreloadScanner(const URL& documentURL, float deviceScaleFactor)
    : m_documentURL(documentURL)
    , m_deviceScaleFactor(deviceScaleFactor)
{
}

// The requests of the scan in progress on this thread (HTMLPreloadScanner::scanRequests).
static constinit thread_local PreloadRequestStream* requestsOfScanInProgress { nullptr };

void TokenPreloadScanner::appendRequest(uint8_t tagId, const String& url, const URL& baseURL, CachedResource::Type type, const String& media, ScriptType scriptType, ReferrerPolicy referrerPolicy, RequestPriority fetchPriority, const String& crossOriginMode, const String& nonce, const String& integrity, bool scriptIsAsync, const String& charset)
{
    // HTMLPreloadScanner.swift's PreloadScannerTagId lists the tags in TagId's order.
    static_assert(static_cast<uint8_t>(TagId::Svg) == 12);
    RELEASE_ASSERT(requestsOfScanInProgress && tagId <= static_cast<uint8_t>(TagId::Svg));
    auto request = makeUnique<PreloadRequest>(static_cast<TagId>(tagId) == TagId::Style ? "css"_s : initiatorFor(static_cast<TagId>(tagId)), url, baseURL, type, media, scriptType, referrerPolicy, fetchPriority);
    // An @import's request keeps these fields' defaults.
    if (static_cast<TagId>(tagId) != TagId::Style) {
        request->setCrossOriginMode(crossOriginMode);
        request->setNonce(nonce);
        request->setIntegrity(integrity);
        request->setScriptIsAsync(scriptIsAsync);
        request->setCharset(charset);
    }
    requestsOfScanInProgress->append(WTF::move(request));
}

bool TokenPreloadScanner::mediaMatches(Document& document, const String& media)
{
    auto mediaQueries = MQ::MediaQueryParser::parse(media, document.cssParserContext());
    return MQ::MediaQueryEvaluator { document.printing() ? printAtom() : screenAtom(), document }.evaluate(mediaQueries);
}

String TokenPreloadScanner::bestFitImageURL(Document& document, float deviceScaleFactor, const String& url, const String& srcset, const String& sizes, bool& hasCandidate)
{
    auto sourceSize = SizesAttributeParser(sizes, document).effectiveSize();
    ImageCandidate imageCandidate = bestFitSourceForImageAttributes(deviceScaleFactor, url, srcset, sourceSize);
    hasCandidate = !imageCandidate.isEmpty();
    auto trimmedURL = imageCandidate.string.view.trim(isASCIIWhitespace<char16_t>);
    return trimmedURL.isEmpty() ? String() : trimmedURL.toString();
}

void TokenPreloadScanner::updatePredictedBaseURL(const HTMLToken& token, bool shouldRestrictBaseURLSchemes)
{
    ASSERT(m_predictedBaseElementURL.isEmpty());
    static constexpr auto hrefAsUTF16 = WTF::toArray<char16_t>({ 'h', 'r', 'e', 'f' });
    auto* hrefAttribute = findAttribute(token.attributes(), hrefAsUTF16);
    if (!hrefAttribute)
        return;
    URL temp { m_documentURL, StringImpl::create8BitIfPossible(hrefAttribute->value) };
    if (temp.isValid() && (!shouldRestrictBaseURLSchemes || SecurityPolicy::isBaseURLSchemeAllowed(temp)))
        m_predictedBaseElementURL = WTF::move(temp);
}

HTMLPreloadScanner::HTMLPreloadScanner(const HTMLParserOptions& options, const URL& documentURL, float deviceScaleFactor)
    : m_scanner(documentURL, deviceScaleFactor)
    , m_tokenizer(options)
{
}

HTMLPreloadScanner::~HTMLPreloadScanner() = default;

void HTMLPreloadScanner::appendToEnd(const SegmentedString& source)
{
    m_source.append(source);
}

void HTMLPreloadScanner::scan(HTMLResourcePreloader& preloader, Document& document)
{
    preloader.preload(scanRequests(document));
}

PreloadRequestStream HTMLPreloadScanner::scanRequests(Document& document)
{
    ASSERT(isMainThread()); // HTMLTokenizer::updateStateFor only works on the main thread.

    const URL& startingBaseElementURL = document.baseElementURL();

    // When we start scanning, our best prediction of the baseElementURL is the real one!
    if (!startingBaseElementURL.isEmpty())
        m_scanner.setPredictedBaseElementURL(startingBaseElementURL);

    PreloadRequestStream requests;

    SetForScope scope { requestsOfScanInProgress, &requests };
    auto& settings = document.settings();
    scanHTMLPreloadScannerTokens(*this, &document, settings.lazyImageLoadingEnabled(), settings.lazyMediaLoadingEnabled(), settings.disabledAdaptationsMetaTagEnabled(), settings.shouldRestrictBaseURLSchemes());

    return requests;
}

bool TokenPreloadScanner::hasLazyLoadableAttributeValue(const String& value)
{
    return LazyLoading::hasLazyAttributeValue(value);
}

bool testPreloadScannerViewportSupport(Document* document)
{
    ASSERT(document);
    HTMLParserOptions options(*document);
    HTMLPreloadScanner scanner(options, document->url());
    Ref preloader = HTMLResourcePreloader::create(*document);
    scanner.appendToEnd(String("<meta name=viewport content='width=400'>"_s));
    scanner.scan(preloader, *document);
    return document->viewportArguments().width == 400;
}

String testPreloadScannerRequests(Document& document, std::span<const String> sources)
{
    HTMLParserOptions options(document);
    HTMLPreloadScanner scanner(options, document.url(), document.deviceScaleFactor());
    StringBuilder result;
    for (auto& source : sources) {
        scanner.appendToEnd(source);
        result.append("scan\n"_s);
        for (auto& request : scanner.scanRequests(document))
            result.append(request->descriptionForTesting(), '\n');
    }
    auto viewport = document.viewportArguments();
    result.append("viewport width="_s, viewport.width, " height="_s, viewport.height, " zoom="_s, viewport.zoom,
        " minZoom="_s, viewport.minZoom, " maxZoom="_s, viewport.maxZoom, " userZoom="_s, viewport.userZoom,
        " orientation="_s, viewport.orientation, " shrinkToFit="_s, viewport.shrinkToFit,
        " type="_s, static_cast<unsigned>(viewport.type), " viewportFit="_s, static_cast<unsigned>(viewport.viewportFit),
        " widthWasExplicit="_s, viewport.widthWasExplicit ? "1"_s : "0"_s,
        " interactiveWidget="_s, static_cast<unsigned>(viewport.interactiveWidgetValue),
        " disabledAdaptations="_s, static_cast<unsigned>(document.disabledAdaptations().toRaw()), '\n');
    return result.toString();
}

}
