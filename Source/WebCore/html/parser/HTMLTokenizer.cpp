/*
 * Copyright (C) 2008-2016 Apple Inc. All rights reserved.
 * Copyright (C) 2009 Torch Mobile, Inc. http://www.torchmobile.com/
 * Copyright (C) 2010 Google, Inc. All rights reserved.
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
#include "HTMLTokenizer.h"

#include "CSSTokenizerInputStream.h"
#include "HTMLEntityParser.h"
#include "HTMLNames.h"
#include "MarkupTokenizerInlines.h"
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>

#include "WebCore-Swift.h"

#include <wtf/SetForScope.h>

namespace WebCore {

using namespace HTMLNames;

HTMLTokenizer::HTMLTokenizer(const HTMLParserOptions& options)
    : m_options(options)
{
}

bool HTMLTokenizer::processToken(SegmentedString& source)
{
    // HTMLTokenizer.swift's TokenizerState lists these states in this order.
    static_assert(CDATASectionDoubleRightSquareBracketState == 75);
    return processHTMLTokenizerToken(*this, source, m_additionalAllowedCharacter);
}

thread_local HTMLTokenAttributes* HTMLTokenizer::s_tokenAttributes { nullptr };

bool HTMLTokenizer::processToken(SegmentedString& source, HTMLTokenAttributes& attributes)
{
    static_assert(makesTokenAttributesBit == 0x8000, "HTMLTokenizer.swift has the same value");
    ASSERT(!(m_additionalAllowedCharacter & makesTokenAttributesBit));
    ASSERT(!s_tokenAttributes);
    SetForScope scope { s_tokenAttributes, &attributes };
    return processHTMLTokenizerToken(*this, source, m_additionalAllowedCharacter | makesTokenAttributesBit);
}

String HTMLTokenizer::bufferedCharacters() const
{
    // FIXME: Add an assert about m_state.
    return makeString("</"_s, m_temporaryBuffer);
}

void HTMLTokenizer::updateStateFor(const AtomString& tagName)
{
    if (textareaTag->hasLocalName(tagName) || titleTag->hasLocalName(tagName))
        m_state = RCDATAState;
    else if (plaintextTag->hasLocalName(tagName))
        m_state = PLAINTEXTState;
    else if (scriptTag->hasLocalName(tagName))
        m_state = ScriptDataState;
    else if (styleTag->hasLocalName(tagName)
        || iframeTag->hasLocalName(tagName)
        || xmpTag->hasLocalName(tagName)
        || noembedTag->hasLocalName(tagName)
        || noframesTag->hasLocalName(tagName)
        || (noscriptTag->hasLocalName(tagName) && m_options.scriptingFlag))
        m_state = RAWTEXTState;
}

}
