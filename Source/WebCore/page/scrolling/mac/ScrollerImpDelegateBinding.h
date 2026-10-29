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

#if PLATFORM(MAC)

#import <WebCore/ColorCocoa.h>
#import <WebCore/ScrollTypes.h>
#import <objc/runtime.h>
#import <pal/spi/mac/NSScrollerImpSPI.h>
#import <wtf/RetainPtr.h>

namespace WebCore {

// NSScrollerImp and NSScrollerImpPair do not retain their delegates. These set the delegate and make the scroller
// imp or the pair retain it until the delegate is replaced, so that a delegate outlives every object that calls it.

inline void bindScrollerImpDelegate(NSScrollerImp * _Nonnull scrollerImp, id<NSScrollerImpDelegate> _Nullable delegate)
{
    static char delegateKey;
    [scrollerImp setDelegate:delegate];
    objc_setAssociatedObject(scrollerImp, &delegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

inline void bindScrollerImpPairDelegate(NSScrollerImpPair * _Nonnull scrollerImpPair, id<NSScrollerImpPairDelegate> _Nullable delegate)
{
    static char delegateKey;
    [scrollerImpPair setDelegate:delegate];
    objc_setAssociatedObject(scrollerImpPair, &delegateKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// The color's description in ScrollerMac::scrollbarState().
inline String scrollbarColorDescription(NSColor * _Nonnull color)
{
    return colorFromCocoaColor(color).debugDescription();
}

} // namespace WebCore

#endif // PLATFORM(MAC)
