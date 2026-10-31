/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
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
#include "KeyboardScrollingAnimator.h"

#include "EventNames.h"
#include "LocalFrameView.h"
#include "PlatformKeyboardEvent.h"
#include "ScrollAnimator.h"
#include "ScrollTypes.h"
#include <wtf/SortedArrayMap.h>
#include <wtf/TZoneMallocInlines.h>

#if USE_SWIFT_SCROLL_ANIMATOR
#include "ScrollAnimatorScrollPhysicsClient.h"
#include "ScrollPhysicsControllerHolder.h"

// KeyboardScrollingAnimator.swift accepts a key identifier unit as PackedASCIILiteral's parse() does: at most 0x7F.
static_assert(isASCII(char16_t { 0x7F }) && !isASCII(char16_t { 0x80 }));
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(KeyboardScrollingAnimator);

#if USE_SWIFT_SCROLL_ANIMATOR
static ScrollAnimator& owningScrollAnimator(ScrollableArea& scrollableArea)
{
    auto* animator = scrollableArea.existingScrollAnimator();
    RELEASE_ASSERT(animator);
    return *animator;
}
#endif

KeyboardScrollingAnimator::KeyboardScrollingAnimator(ScrollableArea& scrollableArea)
    : m_scrollableArea(scrollableArea)
{
}

#if !USE_SWIFT_SCROLL_ANIMATOR
const std::optional<KeyboardScrollingKey> keyboardScrollingKeyForKeyboardEvent(const KeyboardEvent& event)
{
    auto* platformEvent = event.underlyingPlatformEvent();
    if (!platformEvent)
        return { };

    // PlatformEvent::Type::Char is a "keypress" event.
    if (!(platformEvent->type() == PlatformEvent::Type::RawKeyDown || platformEvent->type() == PlatformEvent::Type::Char))
        return { };

    static constexpr SortedArrayMap map { WTF::toArray<std::pair<PackedASCIILiteral<uint64_t>, KeyboardScrollingKey>>({
        { "Down"_s, KeyboardScrollingKey::DownArrow },
        { "End"_s, KeyboardScrollingKey::End },
        { "Home"_s, KeyboardScrollingKey::Home },
        { "Left"_s, KeyboardScrollingKey::LeftArrow },
        { "PageDown"_s, KeyboardScrollingKey::PageDown },
        { "PageUp"_s, KeyboardScrollingKey::PageUp },
        { "Right"_s, KeyboardScrollingKey::RightArrow },
        { "Up"_s, KeyboardScrollingKey::UpArrow },
    }) };

    auto identifier = platformEvent->keyIdentifier();
    if (auto* result = map.tryGet(identifier))
        return *result;

    if (platformEvent->text().codePointAt(0) == ' ')
        return KeyboardScrollingKey::Space;

    return { };
}
#endif

const std::optional<ScrollDirection> scrollDirectionForKeyboardEvent(const KeyboardEvent& event)
{
#if !USE_SWIFT_SCROLL_ANIMATOR
    auto key = keyboardScrollingKeyForKeyboardEvent(event);
    if (!key)
        return { };

    // FIXME (bug 227459): This logic does not account for writing-mode.
    auto direction = [&] {
        switch (key.value()) {
        case KeyboardScrollingKey::LeftArrow:
            return ScrollDirection::ScrollLeft;
        case KeyboardScrollingKey::RightArrow:
            return ScrollDirection::ScrollRight;
        case KeyboardScrollingKey::UpArrow:
        case KeyboardScrollingKey::PageUp:
        case KeyboardScrollingKey::Home:
            return ScrollDirection::ScrollUp;
        case KeyboardScrollingKey::DownArrow:
        case KeyboardScrollingKey::PageDown:
        case KeyboardScrollingKey::End:
            return ScrollDirection::ScrollDown;
        case KeyboardScrollingKey::Space:
            return event.shiftKey() ? ScrollDirection::ScrollUp : ScrollDirection::ScrollDown;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }();

    return direction;
#else
    auto* platformEvent = event.underlyingPlatformEvent();
    return platformEvent ? keyboardScrollDirection(platformEvent->type(), platformEvent->keyIdentifier(), platformEvent->text(), event.modifierKeys().toRaw()) : std::nullopt;
#endif
}

const std::optional<ScrollGranularity> scrollGranularityForKeyboardEvent(const KeyboardEvent& event)
{
#if !USE_SWIFT_SCROLL_ANIMATOR
    auto key = keyboardScrollingKeyForKeyboardEvent(event);
    if (!key)
        return { };

    // FIXME (bug 227459): This logic does not account for writing-mode.
    switch (key.value()) {
    case KeyboardScrollingKey::LeftArrow:
    case KeyboardScrollingKey::RightArrow:
        if (event.shiftKey() || event.metaKey())
            return { };
        if (event.altKey())
            return ScrollGranularity::Page;
        return ScrollGranularity::Line;
    case KeyboardScrollingKey::UpArrow:
    case KeyboardScrollingKey::DownArrow:
        if (event.shiftKey())
            return { };
        if (event.metaKey()) {
            if (event.modifierKeys().hasExactlyOneBitSet())
                return ScrollGranularity::Document;
            return { };
        }
        if (event.altKey())
            return ScrollGranularity::Page;
        return ScrollGranularity::Line;
    case KeyboardScrollingKey::Space:
    case KeyboardScrollingKey::PageUp:
    case KeyboardScrollingKey::PageDown:
        return ScrollGranularity::Page;
    case KeyboardScrollingKey::Home:
    case KeyboardScrollingKey::End:
        return ScrollGranularity::Document;
    };

    RELEASE_ASSERT_NOT_REACHED();
    return { };
#else
    auto* platformEvent = event.underlyingPlatformEvent();
    return platformEvent ? keyboardScrollGranularity(platformEvent->type(), platformEvent->keyIdentifier(), platformEvent->text(), event.modifierKeys().toRaw()) : std::nullopt;
#endif
}

#if !USE_SWIFT_SCROLL_ANIMATOR
float KeyboardScrollingAnimator::scrollDistance(ScrollDirection direction, ScrollGranularity granularity) const
{
    CheckedRef scrollableArea = m_scrollableArea;
    RefPtr scrollbar = scrollableArea->scrollbarForDirection(direction);
    if (!scrollbar)
        return false;

    float step = 0;
    switch (granularity) {
    case ScrollGranularity::Line:
        step = scrollbar->lineStep();
        break;
    case ScrollGranularity::Page:
        step = scrollbar->pageStep();
        break;
    case ScrollGranularity::Document:
        step = scrollbar->totalSize();
        break;
    case ScrollGranularity::Pixel:
        step = scrollbar->pixelStep();
        break;
    }

    auto axis = axisFromDirection(direction);
    if (granularity == ScrollGranularity::Page && axis == ScrollEventAxis::Vertical)
        step = scrollableArea->adjustVerticalPageScrollStepForFixedContent(step);

    return step;
}

RectEdges<bool> KeyboardScrollingAnimator::scrollingDirections() const
{
    RectEdges<bool> edges;

    CheckedRef scrollableArea = m_scrollableArea;
    edges.setTop(scrollableArea->allowsVerticalScrolling());
    edges.setBottom(edges.top());
    edges.setLeft(scrollableArea->allowsHorizontalScrolling());
    edges.setRight(edges.left());

    return edges;
}

std::optional<KeyboardScroll> KeyboardScrollingAnimator::makeKeyboardScroll(ScrollDirection direction, ScrollGranularity granularity) const
{
    float distance = scrollDistance(direction, granularity);

    if (!distance)
        return std::nullopt;

    KeyboardScroll scroll;

    scroll.offset = unitVectorForScrollDirection(direction).scaled(distance);
    scroll.granularity = granularity;
    scroll.direction = direction;
    scroll.maximumVelocity = scroll.offset.scaled(KeyboardScrollParameters::parameters().maximumVelocityMultiplier);
    scroll.force = scroll.maximumVelocity.scaled(KeyboardScrollParameters::parameters().springMass / KeyboardScrollParameters::parameters().timeToMaximumVelocity);

    return scroll;
}
#endif

bool KeyboardScrollingAnimator::beginKeyboardScrollGesture(ScrollDirection direction, ScrollGranularity granularity, bool isKeyRepeat)
{
#if !USE_SWIFT_SCROLL_ANIMATOR
    auto scroll = makeKeyboardScroll(direction, granularity);
    if (!scroll)
        return false;

    CheckedRef scrollableArea = m_scrollableArea;
    if (scrollableArea->isUserScrollInProgress()) {
        m_scrollTriggeringKeyIsPressed = false;
        scrollableArea->endKeyboardScroll(true);
        return true;
    }

    if (m_scrollTriggeringKeyIsPressed)
        return true;

    if (!scrollingDirections().at(boxSideForDirection(direction)))
        return false;

#if PLATFORM(MAC)
    // Scroll to the edge of the document the same way as the Home and End keys.
    if (granularity == ScrollGranularity::Document) {
        scrollableArea->endKeyboardScroll(false);
        scrollableArea->scroll(direction, ScrollGranularity::Document);
        return true;
    }

    if (!isKeyRepeat && granularity == ScrollGranularity::Page) {
        scrollableArea->endKeyboardScroll(false);
        auto currentPosition = scrollableArea->scrollAnimator().currentPosition();
        auto newPosition = (currentPosition + scroll->offset).constrainedBetween(scrollableArea->minimumScrollPosition(), scrollableArea->maximumScrollPosition());
        if (newPosition != currentPosition) {
            // Request a delta rather than a position, so that the scroll starts from the latest position rather than from this one,
            // which may be out of date while an animation runs, such as one that scrolls to the edge of the document.
            auto options = ScrollPositionChangeOptions::createProgrammatic();
            options.originalScrollDelta = newPosition - currentPosition;
            scrollableArea->scrollToPositionWithAnimation(newPosition, options);
        }
        return true;
    }
#endif

    if (granularity == ScrollGranularity::Document || (!isKeyRepeat && granularity == ScrollGranularity::Page)) {
        scrollableArea->endKeyboardScroll(false);
        auto newPosition = IntPoint(scrollableArea->scrollAnimator().currentPosition() + scroll->offset);
        scrollableArea->scrollAnimator().scrollToPositionWithAnimation(newPosition);
        return true;
    }

    m_scrollTriggeringKeyIsPressed = true;

    scrollableArea->beginKeyboardScroll(*scroll);

    return true;
#else
    auto& animator = owningScrollAnimator(m_scrollableArea);
    return animator.m_physics->controller.keyboardScrollingAnimatorBeginKeyboardScrollGesture(ScrollAnimatorScrollPhysicsClientState(animator).facade(), direction, granularity, isKeyRepeat);
#endif
}

void KeyboardScrollingAnimator::handleKeyUpEvent()
{
#if !USE_SWIFT_SCROLL_ANIMATOR
    if (!m_scrollTriggeringKeyIsPressed)
        return;

    m_scrollTriggeringKeyIsPressed = false;

    protect(m_scrollableArea)->endKeyboardScroll(false);
#else
    auto& animator = owningScrollAnimator(m_scrollableArea);
    animator.m_physics->controller.keyboardScrollingAnimatorHandleKeyUpEvent(ScrollAnimatorScrollPhysicsClientState(animator).facade());
#endif
}

void KeyboardScrollingAnimator::stopScrollingImmediately()
{
#if !USE_SWIFT_SCROLL_ANIMATOR
    m_scrollTriggeringKeyIsPressed = false;
    protect(m_scrollableArea)->endKeyboardScroll(true);
#else
    auto& animator = owningScrollAnimator(m_scrollableArea);
    animator.m_physics->controller.keyboardScrollingAnimatorStopScrollingImmediately(ScrollAnimatorScrollPhysicsClientState(animator).facade());
#endif
}

} // namespace WebCore
