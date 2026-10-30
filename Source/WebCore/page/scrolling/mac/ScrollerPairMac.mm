/*
 * Copyright (C) 2019 Apple Inc. All rights reserved.
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
#import "ScrollerPairMac.h"

#if PLATFORM(MAC)

#import "Logging.h"
#import "ScrollTypesMac.h"
#import "ScrollingTreeFrameScrollingNode.h"
#import <QuartzCore/QuartzCore.h>
#import <WebCore/FloatPoint.h>
#import <WebCore/IntRect.h>
#import <WebCore/NSScrollerImpDetails.h>
#import <WebCore/PlatformWheelEvent.h>
#import <WebCore/ScrollTypes.h>
#import <WebCore/ScrollableArea.h>
#import <WebCore/ScrollingTreeScrollingNode.h>
#import <pal/spi/mac/NSScrollerImpSPI.h>
#import <wtf/BlockObjCExceptions.h>
#import <wtf/TZoneMallocInlines.h>

#import "ColorCocoa.h"
#import "ScrollerImpDelegateBinding.h"
#import "ScrollerPairMacState.h"
#import <wtf/BlockPtr.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollerPairMac);
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(ScrollerPairMacState);

ScrollerPairMac::ScrollerPairMac(ScrollingTreeScrollingNode& node)
    : m_scrollingNode(node)
    , m_state(makeUnique<ScrollerPairMacState>(*this))
{
}

void ScrollerPairMac::init()
{
    m_state->scrollerImpPair = adoptNS([[NSScrollerImpPair alloc] init]);
    m_state->scrollers.setUpScrollerImpPair(m_state->scrollerImpPair.get());
    m_state->scrollers.attachScrollers(this);
}

ScrollerPairMac::~ScrollerPairMac()
{
    m_state->scrollers.invalidate();
    if (RetainPtr scrollerImpPair = m_state->scrollerImpPair)
        bindScrollerImpPairDelegate(scrollerImpPair.get(), nil);

    m_state->scrollers.detachScrollers();

    ensureOnMainThread([scrollerImpPair = std::exchange(m_state->scrollerImpPair, nil)] { });

    // The scrollers and their NSScrollerImps are released on the main thread.
    ensureOnMainThread([state = WTF::move(m_state)] {
        RELEASE_ASSERT(isMainThread());
        state->scrollers.scrollersWillBeDestroyed();
    });
}

FloatSize ScrollerPairMac::visibleSize() const
{
    RefPtr node = m_scrollingNode.get();
    if (!node)
        return { };

    return node->scrollableAreaSize();
}

ScrollerPairMac::Values ScrollerPairMac::valuesForOrientation(ScrollbarOrientation orientation)
{
    RefPtr node = m_scrollingNode.get();
    if (!node)
        return { };

    float position;
    float totalSize;
    float visibleSize;
    if (orientation == ScrollbarOrientation::Vertical) {
        position = node->currentScrollOffset().y();
        totalSize = node->totalContentsSize().height();
        visibleSize = node->scrollableAreaSize().height();
    } else {
        position = node->currentScrollOffset().x();
        totalSize = node->totalContentsSize().width();
        visibleSize = node->scrollableAreaSize().width();
    }

    float value;
    float overhang;
    ScrollableArea::computeScrollbarValueAndOverhang(position, totalSize, visibleSize, value, overhang);

    float proportion = totalSize ? (visibleSize - overhang) / totalSize : 1;

    return { value, proportion };
}

MacScrollerPair& ScrollerPairMac::scrollers()
{
    return m_state->scrollers;
}

RetainPtr<CALayer> ScrollerPairMac::hostLayer(ScrollbarOrientation orientation) const
{
    Locker locker { m_state->referencesLock };
    return m_state->references(orientation).hostLayer;
}

RetainPtr<NSScrollerImp> ScrollerPairMac::scrollerImp(ScrollbarOrientation orientation) const
{
    Locker locker { m_state->referencesLock };
    return m_state->references(orientation).scrollerImp;
}

NSScrollerImp *ScrollerPairMac::retainedScrollerImp(ScrollbarOrientation orientation) const
{
    return scrollerImp(orientation).leakRef();
}

void ScrollerPairMac::ensureOnMainThreadWithScrollerImp(NSScrollerImp *scrollerImp, void (^task)(NSScrollerImpPair *, NSScrollerImp *)) const
{
    ensureOnMainThread([protectedThis = Ref { *this }, scrollerImp = RetainPtr { scrollerImp }, task = makeBlockPtr(task)] {
        RELEASE_ASSERT(isMainThread());
        task(protectedThis->m_state->scrollerImpPair.get(), scrollerImp.get());
    });
}

bool ScrollerPairMac::isHostLayer(ScrollbarOrientation orientation, CALayer *layer) const
{
    Locker locker { m_state->referencesLock };
    return m_state->references(orientation).hostLayer.get() == layer;
}

void ScrollerPairMac::setScrollerImpProgress(ScrollbarOrientation orientation, ScrollbarPartFeature feature, double value)
{
    RetainPtr scrollerImp = this->scrollerImp(orientation);
    switch (feature) {
    case ScrollbarPartFeature::KnobAlpha:
        [scrollerImp setKnobAlpha:value];
        break;
    case ScrollbarPartFeature::TrackAlpha:
        [scrollerImp setTrackAlpha:value];
        break;
    case ScrollbarPartFeature::UIStateTransition:
        [scrollerImp setUiStateTransitionProgress:value];
        break;
    case ScrollbarPartFeature::ExpansionTransition:
        [scrollerImp setExpansionTransitionProgress:value];
        break;
    }
}

void ScrollerPairMac::setScrollerReferences(ScrollbarOrientation orientation, NSScrollerImp *scrollerImp, CALayer *hostLayer)
{
    ScrollerPairMacState::References references { scrollerImp, hostLayer };
    Locker locker { m_state->referencesLock };
    std::swap(m_state->references(orientation), references);
}

} // namespace WebCore

#endif // PLATFORM(MAC)
