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

#include "ScrollAnimatorScrollPhysicsClient.h"
#include "ScrollPhysicsControllerHolder.h"

// KeyboardScrollingAnimator.swift accepts a key identifier unit as PackedASCIILiteral's parse() does: at most 0x7F.
static_assert(isASCII(char16_t { 0x7F }) && !isASCII(char16_t { 0x80 }));

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(KeyboardScrollingAnimator);

static ScrollAnimator& owningScrollAnimator(ScrollableArea& scrollableArea)
{
    auto* animator = scrollableArea.existingScrollAnimator();
    RELEASE_ASSERT(animator);
    return *animator;
}

KeyboardScrollingAnimator::KeyboardScrollingAnimator(ScrollableArea& scrollableArea)
    : m_scrollableArea(scrollableArea)
{
}

const std::optional<ScrollDirection> scrollDirectionForKeyboardEvent(const KeyboardEvent& event)
{
    auto* platformEvent = event.underlyingPlatformEvent();
    return platformEvent ? keyboardScrollDirection(platformEvent->type(), platformEvent->keyIdentifier(), platformEvent->text(), event.modifierKeys().toRaw()) : std::nullopt;
}

const std::optional<ScrollGranularity> scrollGranularityForKeyboardEvent(const KeyboardEvent& event)
{
    auto* platformEvent = event.underlyingPlatformEvent();
    return platformEvent ? keyboardScrollGranularity(platformEvent->type(), platformEvent->keyIdentifier(), platformEvent->text(), event.modifierKeys().toRaw()) : std::nullopt;
}

bool KeyboardScrollingAnimator::beginKeyboardScrollGesture(ScrollDirection direction, ScrollGranularity granularity, bool isKeyRepeat)
{
    auto& animator = owningScrollAnimator(m_scrollableArea);
    return animator.m_physics->controller.keyboardScrollingAnimatorBeginKeyboardScrollGesture(ScrollAnimatorScrollPhysicsClientState(animator).facade(), direction, granularity, isKeyRepeat);
}

void KeyboardScrollingAnimator::handleKeyUpEvent()
{
    auto& animator = owningScrollAnimator(m_scrollableArea);
    animator.m_physics->controller.keyboardScrollingAnimatorHandleKeyUpEvent(ScrollAnimatorScrollPhysicsClientState(animator).facade());
}

void KeyboardScrollingAnimator::stopScrollingImmediately()
{
    auto& animator = owningScrollAnimator(m_scrollableArea);
    animator.m_physics->controller.keyboardScrollingAnimatorStopScrollingImmediately(ScrollAnimatorScrollPhysicsClientState(animator).facade());
}

} // namespace WebCore
