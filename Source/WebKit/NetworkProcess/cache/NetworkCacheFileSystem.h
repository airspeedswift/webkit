/*
 * Copyright (C) 2015-2026 Apple Inc. All rights reserved.
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

#include <optional>
#include <utility>
#include <wtf/FileSystem.h>
#include <wtf/UniqueRef.h>
#include <wtf/WallTime.h>
#include <wtf/text/WTFString.h>

// The file system calls of the cache's storage (NetworkCacheFileSystem.swift).

namespace WebKit::NetworkCache {

// FileSystem takes StringViews, which Swift cannot hold safely.
inline String networkCachePathByAppendingComponent(const String& path, const String& component) { return FileSystem::pathByAppendingComponent(path, component); }

// FileSystem::traverseDirectory's entries one at a time, with the type the listing gives (a Function of two arguments
// Swift cannot build).
struct DirectoryEntry {
    String name;
    FileSystem::FileType type;
};
class DirectoryCursor {
public:
    explicit DirectoryCursor(const String& path);
    // Swift's zero init() would make a cursor with no state.
    DirectoryCursor() = delete;
    DirectoryCursor(DirectoryCursor&&);
    ~DirectoryCursor();

    // The next entry, skipping those traverseDirectory skips; none after the last or an error. A moved-from cursor has no
    // state and is not used (Swift cannot use one).
    std::optional<DirectoryEntry> next();

private:
    // A UniqueRef, which Swift knows owns what it points to: a std::unique_ptr of an incomplete type imports as unsafe.
    struct State;
    UniqueRef<State> m_state;
};

// Kept in C++: AuxiliaryProcess::isSystemWebKit() is outside the network cache.
String makeCachePath(const String& baseCachePath);
// Kept in C++: WTF's parseInteger grammar, which Swift's integer parsing does not match on signs and whitespace.
std::optional<unsigned> versionOfDirectory(const String& directoryName);
// The name versionOfDirectory reads, so the prefix is spelled once.
String versionDirectoryName(unsigned version);
// Kept in C++: Linux has no st_birthtime, so the cache keeps creation times in an xattr, read through GIO (USE(SOUP));
// elsewhere none.
struct GlibFileTimes {
    WallTime creation;
    WallTime modification;
};
GlibFileTimes glibFileTimes(const String& path);
// FileSystem takes a std::span<const uint8_t>; Swift passes a Span.
inline bool networkCacheOverwriteEntireFile(const String& path, NOESCAPE std::span<const uint8_t> data) { return !!FileSystem::overwriteEntireFile(path, data); }

} // namespace WebKit::NetworkCache
