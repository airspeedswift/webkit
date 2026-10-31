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

#include "config.h"

#include <WebCore/KeyboardEvent.h>
#include <WebCore/KeyboardScrollingAnimator.h>
#include <WebCore/PlatformKeyboardEvent.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Vector.h>

// The key, modifier and event type combinations that scroll from the keyboard, as EventHandler reaches them: the
// direction and granularity for each key identifier the scrolling key table holds, for Space, and for identifiers and
// texts on either side of what the table accepts.

namespace TestWebKitAPI {

using namespace WebCore;

using Modifier = PlatformEvent::Modifier;

static String string16(std::initializer_list<char16_t> units)
{
    Vector<char16_t> characters(units);
    return String(characters.span());
}

static String string8(std::initializer_list<Latin1Character> units)
{
    Vector<Latin1Character> characters(units);
    return String(characters.span());
}

static String to16Bit(const String& string)
{
    Vector<char16_t> characters;
    for (auto character : string.span8())
        characters.append(character.value);
    return String(characters.span());
}

static Ref<KeyboardEvent> keyboardEvent(const String& identifier, const String& text = { }, OptionSet<Modifier> modifiers = { }, PlatformEvent::Type type = PlatformEvent::Type::RawKeyDown)
{
    return KeyboardEvent::create(PlatformKeyboardEvent(type, text, text, String(), String(), identifier, 0, false, false, false, modifiers, MonotonicTime()), nullptr);
}

struct Scroll {
    std::optional<ScrollDirection> direction;
    std::optional<ScrollGranularity> granularity;

    friend bool operator==(const Scroll&, const Scroll&) = default;
};

static Scroll scrollFor(KeyboardEvent& event)
{
    return { scrollDirectionForKeyboardEvent(event), scrollGranularityForKeyboardEvent(event) };
}

static Scroll scrollFor(const String& identifier, const String& text = { }, OptionSet<Modifier> modifiers = { }, PlatformEvent::Type type = PlatformEvent::Type::RawKeyDown)
{
    return scrollFor(keyboardEvent(identifier, text, modifiers, type));
}

static const Scroll none { };

TEST(KeyboardScrollingKeys, TableEntries)
{
    struct Entry {
        ASCIILiteral identifier;
        Scroll scroll;
    };
    const Entry entries[] = {
        { "Down"_s, { ScrollDirection::ScrollDown, ScrollGranularity::Line } },
        { "End"_s, { ScrollDirection::ScrollDown, ScrollGranularity::Document } },
        { "Home"_s, { ScrollDirection::ScrollUp, ScrollGranularity::Document } },
        { "Left"_s, { ScrollDirection::ScrollLeft, ScrollGranularity::Line } },
        { "PageDown"_s, { ScrollDirection::ScrollDown, ScrollGranularity::Page } },
        { "PageUp"_s, { ScrollDirection::ScrollUp, ScrollGranularity::Page } },
        { "Right"_s, { ScrollDirection::ScrollRight, ScrollGranularity::Line } },
        { "Up"_s, { ScrollDirection::ScrollUp, ScrollGranularity::Line } },
    };
    for (auto& entry : entries) {
        String identifier8 { entry.identifier };
        String identifier16 = to16Bit(identifier8);
        EXPECT_FALSE(identifier16.is8Bit());
        for (auto type : { PlatformEvent::Type::RawKeyDown, PlatformEvent::Type::Char }) {
            EXPECT_TRUE(scrollFor(identifier8, { }, { }, type) == entry.scroll) << entry.identifier.characters();
            EXPECT_TRUE(scrollFor(identifier16, { }, { }, type) == entry.scroll) << entry.identifier.characters();
        }
    }

    EXPECT_TRUE(scrollFor("U+0020"_s, " "_s) == Scroll({ ScrollDirection::ScrollDown, ScrollGranularity::Page }));
    EXPECT_TRUE(scrollFor("U+0020"_s, " "_s, { Modifier::ShiftKey }) == Scroll({ ScrollDirection::ScrollUp, ScrollGranularity::Page }));
}

TEST(KeyboardScrollingKeys, EventTypes)
{
    for (auto type : { PlatformEvent::Type::NoType, PlatformEvent::Type::KeyDown, PlatformEvent::Type::KeyUp, PlatformEvent::Type::MouseMoved, PlatformEvent::Type::Wheel }) {
        EXPECT_TRUE(scrollFor("Down"_s, { }, { }, type) == none);
        EXPECT_TRUE(scrollFor("U+0020"_s, " "_s, { }, type) == none);
    }

    // Without its platform event, the event has no scroll direction or granularity.
    auto event = keyboardEvent("Down"_s);
    event->initKeyboardEvent(AtomString("keydown"_s), true, true, nullptr, AtomString("Down"_s), 0, false, false, false, false);
    EXPECT_FALSE(event->underlyingPlatformEvent());
    EXPECT_TRUE(scrollFor(event.get()) == none);
}

TEST(KeyboardScrollingKeys, Modifiers)
{
    EXPECT_TRUE(scrollFor("Left"_s, { }, { Modifier::ShiftKey }) == Scroll({ ScrollDirection::ScrollLeft, std::nullopt }));
    EXPECT_TRUE(scrollFor("Right"_s, { }, { Modifier::MetaKey }) == Scroll({ ScrollDirection::ScrollRight, std::nullopt }));
    EXPECT_TRUE(scrollFor("Left"_s, { }, { Modifier::AltKey }) == Scroll({ ScrollDirection::ScrollLeft, ScrollGranularity::Page }));
    EXPECT_TRUE(scrollFor("Right"_s, { }, { Modifier::ControlKey }) == Scroll({ ScrollDirection::ScrollRight, ScrollGranularity::Line }));

    EXPECT_TRUE(scrollFor("Up"_s, { }, { Modifier::ShiftKey }) == Scroll({ ScrollDirection::ScrollUp, std::nullopt }));
    EXPECT_TRUE(scrollFor("Down"_s, { }, { Modifier::MetaKey }) == Scroll({ ScrollDirection::ScrollDown, ScrollGranularity::Document }));
    EXPECT_TRUE(scrollFor("Up"_s, { }, { Modifier::MetaKey, Modifier::AltKey }) == Scroll({ ScrollDirection::ScrollUp, std::nullopt }));
    EXPECT_TRUE(scrollFor("Up"_s, { }, { Modifier::MetaKey, Modifier::CapsLockKey }) == Scroll({ ScrollDirection::ScrollUp, std::nullopt }));
    EXPECT_TRUE(scrollFor("Down"_s, { }, { Modifier::MetaKey, Modifier::AltGraphKey }) == Scroll({ ScrollDirection::ScrollDown, std::nullopt }));
    EXPECT_TRUE(scrollFor("Down"_s, { }, { Modifier::AltKey }) == Scroll({ ScrollDirection::ScrollDown, ScrollGranularity::Page }));
    EXPECT_TRUE(scrollFor("Up"_s, { }, { Modifier::ControlKey, Modifier::CapsLockKey }) == Scroll({ ScrollDirection::ScrollUp, ScrollGranularity::Line }));

    OptionSet<Modifier> all { Modifier::AltKey, Modifier::ControlKey, Modifier::MetaKey, Modifier::ShiftKey, Modifier::CapsLockKey, Modifier::AltGraphKey };
    EXPECT_TRUE(scrollFor("PageUp"_s, { }, all) == Scroll({ ScrollDirection::ScrollUp, ScrollGranularity::Page }));
    EXPECT_TRUE(scrollFor("PageDown"_s, { }, all) == Scroll({ ScrollDirection::ScrollDown, ScrollGranularity::Page }));
    EXPECT_TRUE(scrollFor("Home"_s, { }, all) == Scroll({ ScrollDirection::ScrollUp, ScrollGranularity::Document }));
    EXPECT_TRUE(scrollFor("End"_s, { }, all) == Scroll({ ScrollDirection::ScrollDown, ScrollGranularity::Document }));
    EXPECT_TRUE(scrollFor("U+0020"_s, " "_s, all) == Scroll({ ScrollDirection::ScrollUp, ScrollGranularity::Page }));
}

TEST(KeyboardScrollingKeys, Identifiers)
{
    // At most 8 code units, compared exactly, with trailing NULs ignored.
    EXPECT_TRUE(scrollFor("PageDown"_s) == Scroll({ ScrollDirection::ScrollDown, ScrollGranularity::Page }));
    EXPECT_TRUE(scrollFor("PageDownX"_s) == none);
    EXPECT_TRUE(scrollFor(string8({ 'P', 'a', 'g', 'e', 'D', 'o', 'w', 'n', 0 })) == none);
    EXPECT_TRUE(scrollFor(string16({ 'P', 'a', 'g', 'e', 'D', 'o', 'w', 'n', 0 })) == none);
    EXPECT_TRUE(scrollFor(string8({ 'U', 'p', 0 })) == Scroll({ ScrollDirection::ScrollUp, ScrollGranularity::Line }));
    EXPECT_TRUE(scrollFor(string16({ 'H', 'o', 'm', 'e', 0, 0, 0, 0 })) == Scroll({ ScrollDirection::ScrollUp, ScrollGranularity::Document }));
    EXPECT_TRUE(scrollFor(string8({ 0, 'U', 'p' })) == none);
    EXPECT_TRUE(scrollFor(string8({ 'U', 0, 'p' })) == none);
    EXPECT_TRUE(scrollFor("down"_s) == none);
    EXPECT_TRUE(scrollFor("DOWN"_s) == none);
    EXPECT_TRUE(scrollFor("Dow"_s) == none);
    EXPECT_TRUE(scrollFor("Downs"_s) == none);
    EXPECT_TRUE(scrollFor(emptyString()) == none);
    EXPECT_TRUE(scrollFor(String()) == none);

    // Any unit outside ASCII rejects the identifier, whatever its low byte.
    EXPECT_TRUE(scrollFor(string16({ 'U', 'p', 0xE9 })) == none);
    EXPECT_TRUE(scrollFor(string8({ 'U', 'p', 0xE9 })) == none);
    EXPECT_TRUE(scrollFor(string16({ 0x155, 'p' })) == none);
    EXPECT_TRUE(scrollFor(string16({ 0xFF35, 'p' })) == none);
    EXPECT_TRUE(scrollFor(string16({ 'U', 'p', 0xD83D, 0xDE00 })) == none);
    EXPECT_TRUE(scrollFor(string16({ 'U', 0xD800 })) == none);
}

TEST(KeyboardScrollingKeys, Text)
{
    // Only the first code unit of the text is compared with a space, and only when the identifier is not in the table.
    auto space = Scroll({ ScrollDirection::ScrollDown, ScrollGranularity::Page });
    EXPECT_TRUE(scrollFor("x"_s, " "_s) == space);
    EXPECT_TRUE(scrollFor("x"_s, string16({ ' ' })) == space);
    EXPECT_TRUE(scrollFor("x"_s, " x"_s) == space);
    EXPECT_TRUE(scrollFor(String(), " "_s) == space);
    EXPECT_TRUE(scrollFor("x"_s, "x "_s) == none);
    EXPECT_TRUE(scrollFor("x"_s, "\t"_s) == none);
    EXPECT_TRUE(scrollFor("x"_s, emptyString()) == none);
    EXPECT_TRUE(scrollFor("x"_s, String()) == none);
    EXPECT_TRUE(scrollFor("x"_s, string16({ 0xA0 })) == none);
    EXPECT_TRUE(scrollFor("x"_s, string16({ 0x120 })) == none);
    EXPECT_TRUE(scrollFor("x"_s, string16({ 0xFF20 })) == none);
    EXPECT_TRUE(scrollFor("x"_s, string16({ 0xD800, 0xDC20 })) == none);
    EXPECT_TRUE(scrollFor("x"_s, string16({ 0xDC20, ' ' })) == none);
    EXPECT_TRUE(scrollFor("Up"_s, " "_s) == Scroll({ ScrollDirection::ScrollUp, ScrollGranularity::Line }));
}

} // namespace TestWebKitAPI
