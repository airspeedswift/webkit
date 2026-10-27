/*
 * Copyright (C) 2008, 2013 Apple Inc. All rights reserved.
 * Copyright (C) 2010-2020 Google Inc. All rights reserved.
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

#pragma once

#include "HTMLResourcePreloader.h"
#include "HTMLToken.h"
#include <wtf/Vector.h>

#include <wtf/SwiftBridging.h>

namespace WebCore {

class SWIFT_PRIVATE_FILEID("WebCore/HTMLPreloadScanner.swift") CSSPreloadScanner;

class CSSPreloadScanner {
    WTF_MAKE_NONCOPYABLE(CSSPreloadScanner);
public:
    NODELETE CSSPreloadScanner();
    ~CSSPreloadScanner();
    // Swift imports a class only if it can be moved.
    CSSPreloadScanner(CSSPreloadScanner&&) = default;

private:
    enum State {
        Initial,
        MaybeComment,
        Comment,
        MaybeCommentEnd,
        RuleStart,
        Rule,
        AfterRule,
        RuleValue,
        AfterRuleValue,
        RuleConditions,
        DoneParsingImportRules,
    };

    friend std::span<const char16_t> cssPreloadScannerBuffer(const CSSPreloadScanner& scanner LIFETIME_BOUND, unsigned index);

    [[maybe_unused]] State m_state; // Read and written by HTMLPreloadScanner.swift.
    Vector<char16_t> m_rule;
    Vector<char16_t> m_ruleValue;
    Vector<char16_t> m_ruleConditions;

};

// The characters of the scanner's rule (index 0), rule value (1) or rule conditions (2), for HTMLPreloadScanner.swift.
inline std::span<const char16_t> cssPreloadScannerBuffer(const CSSPreloadScanner& scanner LIFETIME_BOUND, unsigned index) { return (!index ? scanner.m_rule : index == 1 ? scanner.m_ruleValue : scanner.m_ruleConditions).span(); }

} // namespace WebCore
