/*
 * Copyright (C) 2009-2024 Apple Inc. All rights reserved.
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

#include "ArgList.h"
#include "GetVM.h"
#include "Identifier.h"
#include "JSCJSValue.h"
#include "Strong.h"
#include <array>
#include <wtf/Range.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

#include "LiteralParserSwiftTypes.h"

WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN

namespace JSC {

class JSArray;
class JSONCache;

enum ParserMode : uint8_t { StrictJSON, SloppyJSON, JSONP };
enum class JSONReviverMode : uint8_t { Disabled, Enabled };

enum JSONPPathEntryType : uint8_t {
    JSONPPathEntryTypeDeclareVar, // var pathEntryName = JSON
    JSONPPathEntryTypeDot, // <prior entries>.pathEntryName = JSON
    JSONPPathEntryTypeLookup, // <prior entries>[pathIndex] = JSON
    JSONPPathEntryTypeCall // <prior entries>(JSON)
};

struct JSONPPathEntry {
    Identifier m_pathEntryName;
    int m_pathIndex;
    JSONPPathEntryType m_type;
};

struct JSONPData {
    Vector<JSONPPathEntry> m_path;
    Strong<Unknown> m_value;
};

class JSONRanges {
public:
    struct Entry;
    using Object = UncheckedKeyHashMap<RefPtr<UniquedStringImpl>, Entry, IdentifierRepHash>;
    using Array = Vector<Entry>;
    struct Entry {
        JSValue value;
        WTF::Range<unsigned> range;
        Variant<std::monostate, Object, Array> properties;
    };

    JSONRanges() = default;

    const Entry& root() const LIFETIME_BOUND { return m_root; }

    JSValue record(JSValue value)
    {
        m_values.appendWithCrashOnOverflow(value);
        return value;
    }

    void setRoot(Entry root)
    {
        m_root = WTF::move(root);
    }

private:
    Entry m_root { };
    MarkedArgumentBuffer m_values;
};


template<typename CharType, JSONReviverMode reviverMode>
class LiteralParser {
public:
    LiteralParser(JSGlobalObject* globalObject, std::span<const CharType> characters, ParserMode mode, CodeBlock* nullOrCodeBlock = nullptr)
        : m_globalObject(globalObject)
        , m_nullOrCodeBlock(nullOrCodeBlock)
        , m_characters(characters)
        , m_mode(mode)
    {
    }

    String getErrorMessage() const;

    JSValue tryLiteralParse() requires (reviverMode == JSONReviverMode::Disabled) { return parse(JSONParseEntry::Value); }
    JSValue tryLiteralParse(JSONRanges* sourceRanges) requires (reviverMode == JSONReviverMode::Enabled) { return parse(JSONParseEntry::Value, sourceRanges); }
    JSValue tryEval() requires (reviverMode == JSONReviverMode::Disabled) { return parse(JSONParseEntry::Eval); }
    JSValue tryLiteralParsePrimitiveValue() requires (reviverMode == JSONReviverMode::Disabled) { return parse(JSONParseEntry::PrimitiveValue); }
    bool tryJSONPParse(Vector<JSONPData>& results, bool needsFullSourceInfo) requires (reviverMode == JSONReviverMode::Disabled) { return !!parse(JSONParseEntry::Program, nullptr, &results, needsFullSourceInfo); }

private:
    JSValue parse(JSONParseEntry, JSONRanges* = nullptr, Vector<JSONPData>* = nullptr, bool needsFullSourceInfo = false);

    JSGlobalObject* const m_globalObject;
    CodeBlock* const m_nullOrCodeBlock;
    const std::span<const CharType> m_characters;
    const ParserMode m_mode;
    String m_errorMessage;
    JSONParseFailure m_failure { };
};

} // namespace JSC

WTF_ALLOW_UNSAFE_BUFFER_USAGE_END
