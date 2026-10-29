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

#include <wtf/Platform.h>

// The types of MacScrollerPair's members in ScrollerPairMac.swift.
#include <WebCore/FloatSize.h>
#include <WebCore/PlatformWheelEvent.h>
#include <WebCore/ScrollTypes.h>
#include <WebCore/ScrollerPairMac.h>
#include <WebCore/ScrollingStateScrollingNode.h>
#include <WebCore/UserInterfaceLayoutDirection.h>
#include <wtf/ThreadSafeWeakPtr.h>

#ifdef __OBJC__
#import <QuartzCore/CALayer.h>
#import <pal/spi/mac/NSScrollerImpSPI.h>
#endif

namespace WebCore {

// What ScrollerPairMac tells its NSScrollerImpPair on the main thread, unless the overlay scroller state is locked.
enum class ScrollerImpPairNotification : uint8_t {
    StartLiveResize,
    EndLiveResize,
    ContentAreaDidResize,
    MouseEnteredContentArea,
    MouseExitedContentArea,
    MouseMovedInContentArea,
};

// The part of an NSScrollerImp that one of its animations sets.
enum class ScrollbarPartFeature : uint8_t {
    KnobAlpha,
    TrackAlpha,
    UIStateTransition,
    ExpansionTransition,
};

using ScrollerPairMacWeakPtr = ThreadSafeWeakPtr<ScrollerPairMac>;

} // namespace WebCore
