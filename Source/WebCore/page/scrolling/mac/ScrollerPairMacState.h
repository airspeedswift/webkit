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

#include "WebCore-Swift.h"
#include <wtf/Lock.h>
#include <wtf/RetainPtr.h>
#include <wtf/TZoneMalloc.h>

OBJC_CLASS NSScrollerImpPair;

namespace WebCore {

// ScrollerPairMac's scrollers (ScrollerPairMac.swift) and its NSScrollerImpPair.
struct ScrollerPairMacState {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(ScrollerPairMacState);

    explicit ScrollerPairMacState(ScrollerPairMac& pair)
        : scrollers(MacScrollerPair::init(ScrollerPairMacWeakPtr { pair }))
    {
    }

    // Copies of one scroller's NSScrollerImp and host layer, which the scroller stores whenever it replaces either,
    // for hit testing, hover and animation progress. The lock is held only to copy or replace them; a replaced copy is
    // released after the lock is.
    struct References {
        RetainPtr<NSScrollerImp> scrollerImp;
        RetainPtr<CALayer> hostLayer;
    };
    References& references(ScrollbarOrientation orientation) { return orientation == ScrollbarOrientation::Vertical ? verticalReferences : horizontalReferences; }

    MacScrollerPair scrollers;
    RetainPtr<NSScrollerImpPair> scrollerImpPair;
    Lock referencesLock;
    References verticalReferences;
    References horizontalReferences;
};

} // namespace WebCore
