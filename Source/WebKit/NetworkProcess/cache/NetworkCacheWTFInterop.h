/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#include "NetworkCacheForward.h"
#include <WebCore/HTTPHeaderNames.h>
#include <WebCore/SharedBuffer.h>
#include <span>
#include <wtf/StdLibExtras.h>
#include <wtf/URL.h>
#include <wtf/WallTime.h>
#include <wtf/text/AtomString.h>
#include <wtf/text/CString.h>
#include <wtf/text/WTFString.h>

// WTF's declarations reach Swift without the Span overloads (wtf is imported as another module), and URL's
// constructors and String::endsWith take pointers or StringViews, which strict Swift cannot pass; these take what it can.

namespace WebKit::NetworkCache {

// For Swift, which imports the const AtomString& as an unsafe pointer.
inline String recordTypeNameString(RecordType type) { return recordTypeName(type); }

// For Swift, which cannot read a RefPtr without an unsafe pointer.
inline bool bufferIsNull(const RefPtr<WebCore::FragmentedSharedBuffer>& buffer) { return !buffer; }
inline size_t networkCacheBufferSize(const RefPtr<WebCore::FragmentedSharedBuffer>& buffer) { return buffer ? buffer->size() : 0; }

// WallTime::fromRawSeconds is a static of the CRTP base GenericTimeMixin, which Swift does not import.
inline WallTime wallTimeFromRawSeconds(double seconds) { return WallTime::fromRawSeconds(seconds); }

// An 8-bit string's characters as bytes and back: Span<Latin1Character>.bytes is unsafe in Swift.
inline std::span<const uint8_t> latin1Bytes(const String& string LIFETIME_BOUND) { return byteCast<uint8_t>(string.span8()); }
inline String latin1String(std::span<const uint8_t> bytes NOESCAPE) { return String { byteCast<Latin1Character>(bytes) }; }
inline URL networkCacheURL(const String& absoluteURL) { return URL { absoluteURL }; }
inline bool networkCacheEndsWith(const String& string, const String& suffix) { return string.endsWith(suffix); }
inline String networkCacheHTTPHeaderNameString(WebCore::HTTPHeaderName name) { return WebCore::httpHeaderNameString(name); }
// A UTF8CString's bytes: Swift gets no Span from a member of a class template specialization.
inline std::span<const uint8_t> utf8Bytes(const UTF8CString& string LIFETIME_BOUND) { return byteCast<uint8_t>(string.span()); }

} // namespace WebKit::NetworkCache
