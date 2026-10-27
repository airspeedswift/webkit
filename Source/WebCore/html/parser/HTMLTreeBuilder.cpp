/*
 * Copyright (C) 2010-2016 Google, Inc. All rights reserved.
 * Copyright (C) 2011-2023 Apple Inc. All rights reserved.
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
#include "HTMLTreeBuilder.h"

#include "CSSTokenizerInputStream.h"
#include "CommonAtomStrings.h"
#include "ContainerNodeInlines.h"
#include "CustomElementRegistry.h"
#include "DocumentFragment.h"
#include "HTMLDocument.h"
#include "HTMLDocumentParser.h"
#include "HTMLFormControlElement.h"
#include "HTMLFormElement.h"
#include "HTMLInputElement.h"
#include "HTMLOptGroupElement.h"
#include "HTMLOptionElement.h"
#include "HTMLParserIdioms.h"
#include "HTMLScriptElement.h"
#include "HTMLTableElement.h"
#include "HTMLTemplateElement.h"
#include "JSCustomElementInterface.h"
#include "LocalizedStrings.h"
#include "MathMLNames.h"
#include "NotImplemented.h"
#include "SVGElementTypeHelpers.h"
#include "SVGScriptElement.h"
#include "XLinkNames.h"
#include "XMLNSNames.h"
#include "XMLNames.h"
#include <wtf/NeverDestroyed.h>
#include <wtf/RobinHoodHashMap.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/ParsingUtilities.h>
#include <wtf/unicode/CharacterNames.h>

#if ENABLE(TELEPHONE_NUMBER_DETECTION) && PLATFORM(IOS_FAMILY)
#include "TelephoneNumberDetector.h"
#endif

namespace WebCore {

using namespace ElementNames;
using namespace HTMLNames;

CustomElementConstructionData::CustomElementConstructionData(Ref<JSCustomElementInterface>&& customElementInterface, Ref<CustomElementRegistry>&& registry, const AtomString& name, Vector<Attribute>&& attributes)
    : elementInterface(WTF::move(customElementInterface))
    , registry(WTF::move(registry))
    , name(name)
    , attributes(WTF::move(attributes))
{
}

CustomElementConstructionData::~CustomElementConstructionData() = default;

}
