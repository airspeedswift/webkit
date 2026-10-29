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

#if USE_SWIFT_MAC_SCROLLERS
#import "ColorCocoa.h"
#import "ScrollerImpDelegateBinding.h"
#import "ScrollerPairMacState.h"
#endif

#if !USE_SWIFT_MAC_SCROLLERS
@interface WebScrollerImpPairDelegateMac : NSObject <NSScrollerImpPairDelegate> {
    ThreadSafeWeakPtr<WebCore::ScrollerPairMac> _scrollerPair;
}
- (id)initWithScrollerPair:(WebCore::ScrollerPairMac*)scrollerPair;
@end

@implementation WebScrollerImpPairDelegateMac

- (id)initWithScrollerPair:(WebCore::ScrollerPairMac*)scrollerPair
{
    self = [super init];
    if (!self)
        return nil;

    _scrollerPair = scrollerPair;
    return self;
}

- (void)invalidate
{
    _scrollerPair = nullptr;
}

- (NSRect)contentAreaRectForScrollerImpPair:(NSScrollerImpPair *)scrollerImpPair
{
    UNUSED_PARAM(scrollerImpPair);
    RefPtr scrollerPair = _scrollerPair.get();
    if (!scrollerPair)
        return NSZeroRect;

    auto size = scrollerPair->visibleSize();
    return NSMakeRect(0, 0, size.width(), size.height());
}

- (BOOL)inLiveResizeForScrollerImpPair:(NSScrollerImpPair *)scrollerImpPair
{
    RefPtr scrollerPair = _scrollerPair.get();
    if (!scrollerPair)
        return NO;

    return scrollerPair->inLiveResize();
}

- (NSPoint)mouseLocationInContentAreaForScrollerImpPair:(NSScrollerImpPair *)scrollerImpPair
{
    UNUSED_PARAM(scrollerImpPair);
    // This location is only used when calling mouseLocationInScrollerForScrollerImp,
    // where we will use the converted mouse position from the Web Process
    return NSZeroPoint;
}

- (NSPoint)scrollerImpPair:(NSScrollerImpPair *)scrollerImpPair convertContentPoint:(NSPoint)pointInContentArea toScrollerImp:(NSScrollerImp *)scrollerImp
{
    UNUSED_PARAM(scrollerImpPair);
    UNUSED_PARAM(pointInContentArea);

    RefPtr scrollerPair = _scrollerPair.get();
    if (!scrollerPair)
        return NSZeroPoint;

    if (!scrollerPair || !scrollerImp)
        return NSZeroPoint;

    Ref<WebCore::ScrollerMac> scroller = [scrollerImp isHorizontal] ? scrollerPair->horizontalScroller() : scrollerPair->verticalScroller();

    ASSERT(scroller->isScrollerFor(scrollerImp));

    return scroller->lastKnownMousePositionInScrollbar();
}

- (void)scrollerImpPair:(NSScrollerImpPair *)scrollerImpPair setContentAreaNeedsDisplayInRect:(NSRect)rect
{
    UNUSED_PARAM(scrollerImpPair);
    UNUSED_PARAM(rect);
}

- (void)scrollerImpPair:(NSScrollerImpPair *)scrollerImpPair updateScrollerStyleForNewRecommendedScrollerStyle:(NSScrollerStyle)newRecommendedScrollerStyle
{
    UNUSED_PARAM(scrollerImpPair);

    RefPtr scrollerPair = _scrollerPair.get();
    if (scrollerPair)
        scrollerPair->setScrollbarStyle(WebCore::scrollbarStyle(newRecommendedScrollerStyle));
}

@end
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollerPairMac);
#if USE_SWIFT_MAC_SCROLLERS
WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(ScrollerPairMacState);
#endif

ScrollerPairMac::ScrollerPairMac(ScrollingTreeScrollingNode& node)
    : m_scrollingNode(node)
#if !USE_SWIFT_MAC_SCROLLERS
    , m_verticalScroller(ScrollerMac::create(*this, ScrollbarOrientation::Vertical))
    , m_horizontalScroller(ScrollerMac::create(*this, ScrollbarOrientation::Horizontal))
#else
    , m_state(makeUnique<ScrollerPairMacState>(*this))
#endif
{
}

#if !USE_SWIFT_MAC_SCROLLERS
void ScrollerPairMac::init()
{
    lazyInitialize(m_scrollerImpPairDelegate, adoptNS([[WebScrollerImpPairDelegateMac alloc] initWithScrollerPair:this]));

    m_scrollerImpPair = adoptNS([[NSScrollerImpPair alloc] init]);
    [m_scrollerImpPair setDelegate:m_scrollerImpPairDelegate.get()];
    auto style = ScrollerStyle::recommendedScrollerStyle();
    m_scrollbarStyle = WebCore::scrollbarStyle(style);
    [m_scrollerImpPair setScrollerStyle:style];

    m_verticalScroller->attach();
    m_horizontalScroller->attach();
}

ScrollerPairMac::~ScrollerPairMac()
{
    [m_scrollerImpPairDelegate invalidate];
    [m_scrollerImpPair setDelegate:nil];

    m_verticalScroller->detach();
    m_horizontalScroller->detach();

    ensureOnMainThread([scrollerImpPair = std::exchange(m_scrollerImpPair, nil)] { });
}

void ScrollerPairMac::handleWheelEventPhase(PlatformWheelEventPhase phase)
{
    ensureOnMainThreadWithProtectedThis([phase](auto& scrollerPair) {
        switch (phase) {
        case PlatformWheelEventPhase::Began:
            [scrollerPair.m_scrollerImpPair beginScrollGesture];
            break;
        case PlatformWheelEventPhase::Ended:
        case PlatformWheelEventPhase::Cancelled:
            [scrollerPair.m_scrollerImpPair endScrollGesture];
            break;
        case PlatformWheelEventPhase::MayBegin:
            [scrollerPair.m_scrollerImpPair beginScrollGesture];
            [scrollerPair.m_scrollerImpPair contentAreaScrolled];
            break;
        default:
            break;
        }
    });
}

void ScrollerPairMac::viewWillStartLiveResize()
{
    if (m_inLiveResize)
        return;
    
    m_inLiveResize = true;

    ensureOnMainThreadWithProtectedThis([](auto& scrollerPair) {
        if ([scrollerPair.m_scrollerImpPair overlayScrollerStateIsLocked])
            return;

        [scrollerPair.m_scrollerImpPair startLiveResize];
    });
}

void ScrollerPairMac::viewWillEndLiveResize()
{
    if (!m_inLiveResize)
        return;
    
    m_inLiveResize = false;

    ensureOnMainThreadWithProtectedThis([](auto& scrollerPair) {
        if ([scrollerPair.m_scrollerImpPair overlayScrollerStateIsLocked])
            return;

        [scrollerPair.m_scrollerImpPair endLiveResize];
    });
}

void ScrollerPairMac::contentsSizeChanged()
{
    ensureOnMainThreadWithProtectedThis([](auto& scrollerPair) {
        if ([scrollerPair.m_scrollerImpPair overlayScrollerStateIsLocked])
            return;

        [scrollerPair.m_scrollerImpPair contentAreaDidResize];
    });
}

void ScrollerPairMac::setUsePresentationValues(bool inMomentumPhase)
{
    m_usingPresentationValues = inMomentumPhase;
    m_horizontalScroller->setUsePresentationValue(m_usingPresentationValues);
    m_verticalScroller->setUsePresentationValue(m_usingPresentationValues);
}

void ScrollerPairMac::setHorizontalScrollbarPresentationValue(float scrollbValue)
{
    m_horizontalScroller->setUsePresentationValue(scrollbValue);
}

void ScrollerPairMac::setVerticalScrollbarPresentationValue(float scrollbValue)
{
    m_verticalScroller->setUsePresentationValue(scrollbValue);
}

void ScrollerPairMac::updateValues()
{
    RefPtr node = m_scrollingNode.get();
    if (!node)
        return;

    auto offset = node->currentScrollOffset();

    if (offset != m_lastScrollOffset) {
        auto scrollbarRevealBehavior = node->takeScrollbarRevealBehaviorForNextScrollbarUpdate();

        if (m_lastScrollOffset && scrollbarRevealBehavior == ScrollbarRevealBehavior::Default) {
            ensureOnMainThreadWithProtectedThis([delta = offset - *m_lastScrollOffset](auto& scrollerPair) {
                [scrollerPair.m_scrollerImpPair contentAreaScrolledInDirection:NSMakePoint(delta.width(), delta.height())];
            });
        }
        m_lastScrollOffset = offset;
    }

    m_horizontalScroller->updateValues();
    m_verticalScroller->updateValues();
}

#else
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
#endif

FloatSize ScrollerPairMac::visibleSize() const
{
    RefPtr node = m_scrollingNode.get();
    if (!node)
        return { };

    return node->scrollableAreaSize();
}

#if !USE_SWIFT_MAC_SCROLLERS
bool ScrollerPairMac::useDarkAppearance() const
{
    return m_useDarkAppearance;
}

ScrollbarWidth ScrollerPairMac::scrollbarWidthStyle() const
{
    return m_scrollbarWidth;
}

#endif

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

#if !USE_SWIFT_MAC_SCROLLERS
bool ScrollerPairMac::hasScrollerImp()
{
    return m_verticalScroller->hasScrollerImp() || m_horizontalScroller->hasScrollerImp();
}

void ScrollerPairMac::releaseReferencesToScrollerImpsOnTheMainThread()
{
    if (hasScrollerImp()) {
        // FIXME: This is a workaround in place for the time being since NSScrollerImps cannot be deallocated
        // on a non-main thread. rdar://problem/24535055
        WTF::callOnMainThread([verticalScrollerImp = m_verticalScroller->takeScrollerImp(), horizontalScrollerImp = m_horizontalScroller->takeScrollerImp()] {
        });
    }
}

String ScrollerPairMac::scrollbarStateForOrientation(ScrollbarOrientation orientation) const
{
    return orientation == ScrollbarOrientation::Vertical ? m_verticalScroller->scrollbarState() : m_horizontalScroller->scrollbarState();
}

void ScrollerPairMac::setVerticalScrollerImp(NSScrollerImp *scrollerImp)
{
    ensureOnMainThreadWithProtectedThis([scrollerImp = RetainPtr { scrollerImp }](auto& srollerPair) {
        [srollerPair.m_scrollerImpPair setVerticalScrollerImp:scrollerImp.get()];
    });
}

void ScrollerPairMac::setHorizontalScrollerImp(NSScrollerImp *scrollerImp)
{
    ensureOnMainThreadWithProtectedThis([scrollerImp = RetainPtr { scrollerImp }](auto& scrollerPair) {
        [scrollerPair.m_scrollerImpPair setHorizontalScrollerImp:scrollerImp.get()];
    });
}

void ScrollerPairMac::setScrollbarStyle(ScrollbarStyle style)
{
    m_scrollbarStyle = style;

    ensureOnMainThreadWithProtectedThis([scrollerStyle = nsScrollerStyle(style)](auto& scrollerPair) {
        scrollerPair.m_horizontalScroller->updateScrollbarStyle();
        scrollerPair.m_verticalScroller->updateScrollbarStyle();
        [scrollerPair.m_scrollerImpPair setScrollerStyle:scrollerStyle];
    });
}

#else
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

#endif

void ScrollerPairMac::ensureOnMainThreadWithProtectedThis(Function<void(ScrollerPairMac&)>&& task)
{
    ensureOnMainThread([protectedThis = Ref { *this }, task = WTF::move(task)]() mutable {
#if USE_SWIFT_MAC_SCROLLERS
        RELEASE_ASSERT(isMainThread());
#endif
        task(protectedThis.get());
    });
}

#if !USE_SWIFT_MAC_SCROLLERS
void ScrollerPairMac::mouseEnteredContentArea()
{
    LOG_WITH_STREAM(OverlayScrollbars, stream << "ScrollerPairMac for [" << protect(m_scrollingNode)->scrollingNodeID() << "] mouseEnteredContentArea");

    ensureOnMainThreadWithProtectedThis([](auto& scrollerPair) {
        if ([scrollerPair.m_scrollerImpPair overlayScrollerStateIsLocked])
            return;

        [scrollerPair.m_scrollerImpPair mouseEnteredContentArea];
    });
}

void ScrollerPairMac::mouseExitedContentArea()
{
    m_mouseInContentArea = false;
    LOG_WITH_STREAM(OverlayScrollbars, stream << "ScrollerPairMac for [" << protect(m_scrollingNode)->scrollingNodeID() << "] mouseExitedContentArea");

    ensureOnMainThreadWithProtectedThis([](auto& scrollerPair) {
        if ([scrollerPair.m_scrollerImpPair overlayScrollerStateIsLocked])
            return;

        [scrollerPair.m_scrollerImpPair mouseExitedContentArea];
    });
}

void ScrollerPairMac::mouseMovedInContentArea(const MouseLocationState& state)
{
    m_mouseInContentArea = true;
    horizontalScroller().setLastKnownMousePositionInScrollbar(state.locationInHorizontalScrollbar);
    verticalScroller().setLastKnownMousePositionInScrollbar(state.locationInVerticalScrollbar);

    ensureOnMainThreadWithProtectedThis([](auto& scrollerPair) {
        if ([scrollerPair.m_scrollerImpPair overlayScrollerStateIsLocked])
            return;
        
        [scrollerPair.m_scrollerImpPair mouseMovedInContentArea];
    });
}

void ScrollerPairMac::mouseIsInScrollbar(ScrollbarHoverState hoverState)
{
    if (m_scrollbarHoverState.mouseIsOverVerticalScrollbar != hoverState.mouseIsOverVerticalScrollbar) {
        if (hoverState.mouseIsOverVerticalScrollbar)
            m_verticalScroller->mouseEnteredScrollbar();
        else
            m_verticalScroller->mouseExitedScrollbar();
    }

    if (m_scrollbarHoverState.mouseIsOverHorizontalScrollbar != hoverState.mouseIsOverHorizontalScrollbar) {
        if (hoverState.mouseIsOverHorizontalScrollbar)
            m_horizontalScroller->mouseEnteredScrollbar();
        else
            m_horizontalScroller->mouseExitedScrollbar();
    }
    m_scrollbarHoverState = hoverState;
}

void ScrollerPairMac::setUseDarkAppearance(bool useDarkAppearance)
{
    if (m_useDarkAppearance == useDarkAppearance)
        return;
    m_useDarkAppearance = useDarkAppearance;

    m_horizontalScroller->setNeedsDisplay();
    m_verticalScroller->setNeedsDisplay();
}

void ScrollerPairMac::setScrollbarWidth(ScrollbarWidth scrollbarWidth)
{
    if (m_scrollbarWidth == scrollbarWidth)
        return;
    m_scrollbarWidth = scrollbarWidth;

    m_horizontalScroller->updateScrollbarStyle();
    m_verticalScroller->updateScrollbarStyle();
}

void ScrollerPairMac::scrollbarColorChanged(const std::optional<ScrollbarColor>& scrollbarColor)
{
    m_horizontalScroller->scrollbarColorChanged(scrollbarColor);
    m_verticalScroller->scrollbarColorChanged(scrollbarColor);
}

void ScrollerPairMac::updateScrollbarPainters()
{
    Locker lockerHorizontal { horizontalScroller().scrollerImpLock() };
    Locker lockerVertical { verticalScroller().scrollerImpLock() };

    BEGIN_BLOCK_OBJC_EXCEPTIONS
    [CATransaction lock];

    auto horizontalValues = valuesForOrientation(ScrollbarOrientation::Horizontal);
    setHorizontalScrollbarPresentationValue(horizontalValues.value);

    auto verticalValues = valuesForOrientation(ScrollbarOrientation::Vertical);
    setVerticalScrollbarPresentationValue(verticalValues.value);

    [CATransaction unlock];
    END_BLOCK_OBJC_EXCEPTIONS
}

#else
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
#endif

} // namespace WebCore

#endif // PLATFORM(MAC)
