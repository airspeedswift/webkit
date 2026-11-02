/*
 * Copyright (C) 2011-2017 Apple Inc. All rights reserved.
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

#import "config.h"
#import "ScrollingEffectsController.h"

#import "Logging.h"
#import "PlatformWheelEvent.h"
#import "RubberbandingState.h"
#import "ScrollExtents.h"
#import "ScrollPhysicsControllerHolder.h"
#import "ScrollableArea.h"
#import "ScrollingEffectsClock.h"
#import <pal/spi/mac/NSScrollViewSPI.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#import <wtf/SystemTracing.h>
#import <wtf/text/TextStream.h>

#if USE(APPLE_INTERNAL_SDK)
#import <WebKitAdditions/ScrollingEffectsControllerAdditions.mm>
#endif

#if PLATFORM(MAC)

namespace WebCore {

NODELETE static ScrollEventAxis dominantAxisFavoringVertical(FloatSize delta)
{
    if (std::abs(delta.height()) >= std::abs(delta.width()))
        return ScrollEventAxis::Vertical;

    return ScrollEventAxis::Horizontal;
}

NODELETE static FloatSize deltaAlignedToAxis(FloatSize delta, ScrollEventAxis axis)
{
    switch (axis) {
    case ScrollEventAxis::Horizontal: return FloatSize { delta.width(), 0 };
    case ScrollEventAxis::Vertical: return FloatSize { 0, delta.height() };
    }

    return { };
}

NODELETE static FloatSize deltaAlignedToDominantAxis(FloatSize delta)
{
    auto dominantAxis = dominantAxisFavoringVertical(delta);
    return deltaAlignedToAxis(delta, dominantAxis);
}

#if HAVE(APPKIT_GESTURES_SUPPORT)
#endif

#if HAVE(APPKIT_GESTURES_SUPPORT)
#else
#endif

#if HAVE(APPKIT_GESTURES_SUPPORT)

#endif

FloatSize ScrollingEffectsController::wheelDeltaBiasingTowardsVertical(const FloatSize& wheelDelta)
{
    return deltaAlignedToDominantAxis(wheelDelta);
}

bool ScrollingEffectsController::isScrollDeltaOpposingStretch(IntSize stretch, ScrollEventAxis axis, float delta)
{
    auto stretchOnAxis = (axis == ScrollEventAxis::Horizontal) ? stretch.width() : stretch.height();
    if (!stretchOnAxis || !delta)
        return false;

    return (stretchOnAxis > 0 && delta < 0) || (stretchOnAxis < 0 && delta > 0);
}

WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN
void ScrollPhysicsClient::momentumScrollBegan()
{
#if HAVE(OS_SIGNPOST)
    SUPPRESS_UNRETAINED_ARG os_signpost_interval_begin(WTFSignpostLogHandle(), OS_SIGNPOST_ID_EXCLUSIVE, "Momentum scroll", "isAnimation=YES");
#endif
}

void ScrollPhysicsClient::momentumScrollEnded()
{
#if HAVE(OS_SIGNPOST)
    SUPPRESS_UNRETAINED_ARG os_signpost_interval_end(WTFSignpostLogHandle(), OS_SIGNPOST_ID_EXCLUSIVE, "Momentum scroll");
#endif
}
WTF_ALLOW_UNSAFE_BUFFER_USAGE_END

} // namespace WebCore

#endif // PLATFORM(MAC)
