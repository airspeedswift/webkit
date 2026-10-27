/*
 * Copyright (C) 2010 Google, Inc. All rights reserved.
 * Copyright (C) 2011-2025 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY GOOGLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL GOOGLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"

#include "Comment.h"
#include "ContainerNodeInlines.h"
#include "CustomElementRegistry.h"
#include "Document.h"
#include "DocumentFragment.h"
#include "DocumentType.h"
#include "FrameDestructionObserverInlines.h"
#include "FrameLoader.h"
#include "HTMLElementFactory.h"
#include "HTMLFormControlElement.h"
#include "HTMLFormElement.h"
#include "HTMLHtmlElement.h"
#include "HTMLImageElement.h"
#include "HTMLMaybeFormAssociatedCustomElement.h"
#include "HTMLOptGroupElement.h"
#include "HTMLOptionElement.h"
#include "HTMLParserIdioms.h"
#include "HTMLPictureElement.h"
#include "HTMLScriptElement.h"
#include "HTMLTemplateElement.h"
#include "HTMLTreeBuilder.h"
#include "HTMLUnknownElement.h"
#include "JSCustomElementInterface.h"
#include "LocalDOMWindow.h"
#include "LocalFrame.h"
#include "LocalFrameLoaderClient.h"
#include "NodeName.h"
#include "NotImplemented.h"
#include "ProcessingInstruction.h"
#include "SVGElementInlines.h"
#include "Settings.h"
#include "ShadowRoot.h"
#include "ShadowRootMode.h"
#include "SlotAssignmentMode.h"
#include "Text.h"
#include "UserScriptTypes.h"
#include <unicode/ubrk.h>
#include <wtf/text/TextBreakIterator.h>

#include "HTMLTreeBuilderSwiftSupport.h"

namespace WebCore {

using namespace ElementNames;
using namespace HTMLNames;

static NEVER_INLINE unsigned findBreakIndexSlow(const String& string, unsigned currentPosition, unsigned proposedBreakIndex)
{
    unsigned stringLength = string.length();
    // Check that we are not on an unbreakable boundary.
    // Some text break iterator implementations work best if the passed buffer is as small as possible,
    // see <https://bugs.webkit.org/show_bug.cgi?id=29092>.
    // We need at least two characters look-ahead to account for UTF-16 surrogates.
    unsigned breakSearchLength = std::min(proposedBreakIndex - currentPosition + 2, stringLength - currentPosition);
    NonSharedCharacterBreakIterator it(StringView(string).substring(currentPosition, breakSearchLength));

    unsigned stringLengthLimit = proposedBreakIndex - currentPosition;
    if (ubrk_isBoundary(it, stringLengthLimit))
        return proposedBreakIndex;

    unsigned breakIndexInSubstring = ubrk_preceding(it, stringLengthLimit);
    return currentPosition + breakIndexInSubstring;
}

unsigned findBreakIndex(const String& string, unsigned currentPosition, unsigned proposedBreakIndex)
{
    ASSERT(currentPosition < proposedBreakIndex);
    ASSERT(proposedBreakIndex <= string.length());

    if (proposedBreakIndex == string.length() || string.is8Bit()) [[likely]]
        return proposedBreakIndex;

    return findBreakIndexSlow(string, currentPosition, proposedBreakIndex);
}

void injectDocumentStartUserScripts(Document& document)
{
    if (RefPtr frame = document.frame())
        frame->injectUserScripts(UserScriptInjectionTime::DocumentStart);
}

} // namespace WebCore
