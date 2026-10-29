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
    m_scrollbarStyle = m_state->scrollers.setUpScrollerImpPair(m_state->scrollerImpPair.get());
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

void ScrollerPairMac::handleWheelEventPhase(PlatformWheelEventPhase phase)
{
    ensureOnMainThreadWithProtectedThis([phase](auto& scrollerPair) {
        scrollerPair.m_state->scrollers.handleWheelEventPhaseOnMainThread(scrollerPair.m_state->scrollerImpPair.get(), phase);
    });
}

void ScrollerPairMac::notifyScrollerImpPair(ScrollerImpPairNotification notification)
{
    ensureOnMainThreadWithProtectedThis([notification](auto& scrollerPair) {
        scrollerPair.m_state->scrollers.notifyScrollerImpPairOnMainThread(scrollerPair.m_state->scrollerImpPair.get(), notification);
    });
}

void ScrollerPairMac::viewWillStartLiveResize()
{
    if (m_state->scrollers.setInLiveResize(true))
        notifyScrollerImpPair(ScrollerImpPairNotification::StartLiveResize);
}

void ScrollerPairMac::viewWillEndLiveResize()
{
    if (m_state->scrollers.setInLiveResize(false))
        notifyScrollerImpPair(ScrollerImpPairNotification::EndLiveResize);
}

void ScrollerPairMac::contentsSizeChanged()
{
    notifyScrollerImpPair(ScrollerImpPairNotification::ContentAreaDidResize);
}

void ScrollerPairMac::setUsePresentationValues(bool inMomentumPhase)
{
    m_usingPresentationValues = inMomentumPhase;
    m_state->scrollers.setUsePresentationValues(m_usingPresentationValues);
}

void ScrollerPairMac::updateValues()
{
    m_state->scrollers.updateValues(this);
}

void ScrollerPairMac::contentAreaScrolledInDirection(FloatSize delta)
{
    ensureOnMainThreadWithProtectedThis([delta](auto& scrollerPair) {
        scrollerPair.m_state->scrollers.contentAreaScrolledInDirectionOnMainThread(scrollerPair.m_state->scrollerImpPair.get(), delta.width(), delta.height());
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

bool ScrollerPairMac::hasScrollerImp()
{
    return m_state->scrollers.hasScrollerImp();
}

void ScrollerPairMac::releaseReferencesToScrollerImpsOnTheMainThread()
{
    // FIXME: This is a workaround in place for the time being since NSScrollerImps cannot be deallocated
    // on a non-main thread. rdar://problem/24535055
    if (m_state->scrollers.takeScrollerImps(this)) {
        WTF::callOnMainThread([scrollers = m_state->scrollers]() mutable {
            RELEASE_ASSERT(isMainThread());
            scrollers.releaseTakenScrollerImpsOnMainThread();
        });
    }
}

String ScrollerPairMac::scrollbarStateForOrientation(ScrollbarOrientation orientation) const
{
    return m_state->scrollers.scrollbarState(orientation, scrollbarStyle());
}

void ScrollerPairMac::setVerticalScrollerImp(NSScrollerImp *scrollerImp)
{
    ensureOnMainThreadWithProtectedThis([scrollerImp = RetainPtr { scrollerImp }](auto& scrollerPair) {
        scrollerPair.m_state->scrollers.setPairScrollerImpOnMainThread(scrollerPair.m_state->scrollerImpPair.get(), ScrollbarOrientation::Vertical, scrollerImp.get());
    });
}

void ScrollerPairMac::setHorizontalScrollerImp(NSScrollerImp *scrollerImp)
{
    ensureOnMainThreadWithProtectedThis([scrollerImp = RetainPtr { scrollerImp }](auto& scrollerPair) {
        scrollerPair.m_state->scrollers.setPairScrollerImpOnMainThread(scrollerPair.m_state->scrollerImpPair.get(), ScrollbarOrientation::Horizontal, scrollerImp.get());
    });
}

void ScrollerPairMac::setScrollbarStyle(ScrollbarStyle style)
{
    m_scrollbarStyle = style;

    ensureOnMainThreadWithProtectedThis([style](auto& scrollerPair) {
        scrollerPair.m_state->scrollers.updateScrollbarStyleOnMainThread(&scrollerPair, scrollerPair.m_state->scrollerImpPair.get(), style);
    });
}

void ScrollerPairMac::ensureOnMainThreadWithProtectedThis(Function<void(ScrollerPairMac&)>&& task)
{
    ensureOnMainThread([protectedThis = Ref { *this }, task = WTF::move(task)]() mutable {
        RELEASE_ASSERT(isMainThread());
        task(protectedThis.get());
    });
}

void ScrollerPairMac::mouseEnteredContentArea()
{
    LOG_WITH_STREAM(OverlayScrollbars, stream << "ScrollerPairMac for [" << protect(m_scrollingNode)->scrollingNodeID() << "] mouseEnteredContentArea");
    notifyScrollerImpPair(ScrollerImpPairNotification::MouseEnteredContentArea);
}

void ScrollerPairMac::mouseExitedContentArea()
{
    m_state->scrollers.mouseExitedContentArea();
    LOG_WITH_STREAM(OverlayScrollbars, stream << "ScrollerPairMac for [" << protect(m_scrollingNode)->scrollingNodeID() << "] mouseExitedContentArea");
    notifyScrollerImpPair(ScrollerImpPairNotification::MouseExitedContentArea);
}

void ScrollerPairMac::mouseMovedInContentArea(const MouseLocationState& state)
{
    m_state->scrollers.mouseMovedInContentArea(state);
    notifyScrollerImpPair(ScrollerImpPairNotification::MouseMovedInContentArea);
}

void ScrollerPairMac::mouseIsInScrollbar(ScrollbarHoverState hoverState)
{
    m_state->scrollers.mouseIsInScrollbar(this, hoverState);
}

void ScrollerPairMac::notifyScrollerImpOfMouse(ScrollbarOrientation orientation, bool mouseEntered)
{
    ensureOnMainThreadWithProtectedThis([scrollerImp = scrollerImp(orientation), mouseEntered](auto& scrollerPair) {
        scrollerPair.m_state->scrollers.notifyScrollerImpOfMouseOnMainThread(scrollerPair.m_state->scrollerImpPair.get(), scrollerImp.get(), mouseEntered, scrollerPair.scrollbarStyle());
    });
}

void ScrollerPairMac::setUseDarkAppearance(bool useDarkAppearance)
{
    m_state->scrollers.setUseDarkAppearance(useDarkAppearance);
}

void ScrollerPairMac::setScrollbarWidth(ScrollbarWidth scrollbarWidth)
{
    m_state->scrollers.setScrollbarWidth(this, scrollbarWidth);
}

void ScrollerPairMac::scrollbarColorChanged(const std::optional<ScrollbarColor>& scrollbarColor)
{
    for (auto orientation : { ScrollbarOrientation::Horizontal, ScrollbarOrientation::Vertical })
        m_state->scrollers.scrollbarColorChanged(this, orientation, scrollbarColor ? cocoaColor(scrollbarColor->trackColor).get() : nil, scrollbarColor ? cocoaColor(scrollbarColor->thumbColor).get() : nil);
}

void ScrollerPairMac::updateScrollbarPainters()
{
    m_state->scrollers.updateScrollbarPainters(this);
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
