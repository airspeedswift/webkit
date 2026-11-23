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

#include "config.h"
#include "NetworkCacheFileSystem.h"

#include "AuxiliaryProcess.h"
#include <wtf/StdFilesystem.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringToIntegerConversion.h>

#if USE(SOUP)
#include <gio/gio.h>
#include <wtf/glib/GLibExtras.h>
#include <wtf/glib/GRefPtr.h>
#endif

namespace WebKit::NetworkCache {

String makeCachePath(const String& baseCachePath)
{
#if PLATFORM(MAC)
    // Put development cache to a different directory to avoid affecting the system cache.
    if (!AuxiliaryProcess::isSystemWebKit())
        return FileSystem::pathByAppendingComponent(baseCachePath, "Development"_s);
#endif
    return baseCachePath;
}

struct DirectoryCursor::State {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(State);

    std::error_code error;
    std::filesystem::directory_iterator iterator;
    bool atEntry { false };
};

WTF_MAKE_TZONE_ALLOCATED_IMPL(DirectoryCursor::State);

// The spellings of WTF's toStdFileSystemPath and fromStdFileSystemPath, file-private there.
#if HAVE(MISSING_U8STRING)
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
static std::filesystem::path toStdPath(const String& path) { return std::filesystem::u8path(path.utf8().data()); }
ALLOW_DEPRECATED_DECLARATIONS_END
static String fromStdPath(const std::filesystem::path& path) { return String::fromUTF8(unsafeSpan(path.u8string().c_str())); }
#else
static std::filesystem::path toStdPath(const String& path) { return { std::u8string(path.utf8().data()) }; }
static String fromStdPath(const std::filesystem::path& path) { return String::fromUTF8(WTF::span(path.u8string())); }
#endif

// FileSystem::traverseDirectory's loop, a step per call: it advances past the entry it returned when asked for the next.
DirectoryCursor::DirectoryCursor(const String& path)
    : m_state(makeUniqueRef<State>())
{
    m_state->iterator = std::filesystem::directory_iterator(toStdPath(path), m_state->error);
}

DirectoryCursor::DirectoryCursor(DirectoryCursor&&) = default;
DirectoryCursor::~DirectoryCursor() = default;

std::optional<DirectoryEntry> DirectoryCursor::next()
{
    if (std::exchange(m_state->atEntry, false))
        m_state->iterator.increment(m_state->error);
    for (; !m_state->error && m_state->iterator != std::filesystem::directory_iterator(); m_state->iterator.increment(m_state->error)) {
        auto name = fromStdPath(m_state->iterator->path().filename());
        std::error_code statusError;
        auto type = name.isNull() ? std::filesystem::file_type::none : m_state->iterator->symlink_status(statusError).type();
        if (name.isNull() || statusError)
            continue;
        m_state->atEntry = true;
        return DirectoryEntry { WTF::move(name), type == std::filesystem::file_type::directory ? FileSystem::FileType::Directory : type == std::filesystem::file_type::symlink ? FileSystem::FileType::SymbolicLink : FileSystem::FileType::Regular };
    }
    return std::nullopt;
}

static constexpr auto networkCacheVersionDirectoryPrefix = "Version "_s;

String versionDirectoryName(unsigned version)
{
    return makeString(networkCacheVersionDirectoryPrefix, version);
}

std::optional<unsigned> versionOfDirectory(const String& directoryName)
{
    if (!directoryName.startsWith(networkCacheVersionDirectoryPrefix))
        return std::nullopt;
    return parseInteger<unsigned>(StringView { directoryName }.substring(networkCacheVersionDirectoryPrefix.length()));
}

GlibFileTimes glibFileTimes(const String& path)
{
#if USE(SOUP)
    // There's no st_birthtime in some operating systems like Linux, so we use xattrs to set/get the creation time.
    GRefPtr<GFile> file = gFileNewForPath(FileSystem::fileSystemRepresentation(path));
    GRefPtr<GFileInfo> fileInfo = adoptGRef(g_file_query_info(file.get(), "xattr::birthtime,time::modified", G_FILE_QUERY_INFO_NONE, nullptr, nullptr));
    if (!fileInfo)
        return { };
    const char* birthtimeString = g_file_info_get_attribute_string(fileInfo.get(), "xattr::birthtime");
    if (!birthtimeString)
        return { };
    return { WallTime::fromRawSeconds(g_ascii_strtoull(birthtimeString, nullptr, 10)),
        WallTime::fromRawSeconds(g_file_info_get_attribute_uint64(fileInfo.get(), "time::modified")) };
#else
    // A port with neither stat's st_birthtime, GIO nor the Windows file times: no times, as a failed query.
    UNUSED_PARAM(path);
    return { };
#endif
}

} // namespace WebKit::NetworkCache
