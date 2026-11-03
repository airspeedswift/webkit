/*
 * Copyright (C) 2021-2023 Apple Inc. All rights reserved.
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
#include "ScrollbarsControllerMac.h"

#if PLATFORM(MAC)

#import "GraphicsLayer.h"
#import "Logging.h"
#import "NSScrollerImpDetails.h"
#import "ScrollAnimator.h"
#import "ScrollableArea.h"
#import "ScrollbarInlines.h"
#import "ScrollbarMac.h"
#import "ScrollbarThemeMac.h"
#import "ScrollbarsControllerInlines.h"
#import "TimingFunction.h"
#import "WheelEventTestMonitor.h" // FIXME: This is  layering violation.

#import <pal/spi/mac/NSScrollerImpSPI.h>
#import <wtf/BlockObjCExceptions.h>
#import <wtf/NakedPtr.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/text/TextStream.h>

#import "ScrollbarsControllerMacTypes.h"
#import "WebCore-Swift.h"
#import <wtf/NeverDestroyed.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollbarsController);
WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollbarsControllerMac);

} // namespace WebCore

namespace WebCore {

// ScrollbarsControllerMac's state and its AppKit delegates, which live in Swift (ScrollbarsControllerMac.swift).
struct ScrollbarsControllerMacHolder {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(ScrollbarsControllerMacHolder);

    explicit ScrollbarsControllerMacHolder(ScrollableArea& area)
        : controller(MacScrollbarsController::init(ScrollbarsControllerMacArea { area }))
    {
    }

    MacScrollbarsController controller;
};

WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(ScrollbarsControllerMacHolder);

NSScrollerImp *ScrollbarsControllerMacScrollbar::scrollerImp() const
{
    RefPtr scrollbar = m_scrollbar;
    return scrollbar ? ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar) : nil;
}

void ScrollbarsControllerMacScrollbar::createScrollerImp(NSScrollerImp *oldScrollerImp) const
{
    RefPtr scrollbar = dynamicDowncast<ScrollbarMac>(m_scrollbar);
    RELEASE_ASSERT(scrollbar);
    scrollbar->createScrollerImp(oldScrollerImp);
}

void ScrollbarsControllerMacScrollbar::setPaintCharacteristics() const
{
    RefPtr scrollbar = m_scrollbar;
    auto& theme = ScrollbarTheme::theme();
    if (!scrollbar || theme.isMockTheme())
        return;
    downcast<ScrollbarThemeMac>(theme).setPaintCharacteristicsForScrollbar(*scrollbar);
}

CALayer *ScrollbarsControllerMacArea::layerForScrollbar(ScrollbarOrientation orientation, bool& hasGraphicsLayer) const
{
    hasGraphicsLayer = false;
    CheckedPtr area = m_area;
    if (!area)
        return nil;
    RefPtr layer = orientation == ScrollbarOrientation::Vertical ? area->layerForVerticalScrollbar() : area->layerForHorizontalScrollbar();
    hasGraphicsLayer = !!layer;
    return layer ? layer->platformLayer() : nil;
}

CALayer *ScrollbarsControllerMacArea::scrollerImpDelegateLayer(ScrollbarOrientation orientation) const
{
    CheckedPtr area = m_area;
    if (!area || !ScrollbarThemeMac::isCurrentlyDrawingIntoLayer())
        return nil;
    RefPtr layer = orientation == ScrollbarOrientation::Vertical ? area->layerForVerticalScrollbar() : area->layerForHorizontalScrollbar();

    // The layer an NSScrollerImp draws into when its scrollbar has no GraphicsLayer: one for the process.
    static NeverDestroyed<RetainPtr<CALayer>> dummyLayer = adoptNS([[CALayer alloc] init]);
    return layer ? layer->platformLayer() : dummyLayer.get().get();
}

void ScrollbarsControllerMacArea::startScrollbarPaintTimer() const
{
    if (CheckedPtr area = m_area)
        downcast<ScrollbarsControllerMac>(area->scrollbarsController()).startScrollbarPaintTimer();
}

void ScrollbarsControllerMacArea::stopScrollbarPaintTimer() const
{
    if (CheckedPtr area = m_area)
        downcast<ScrollbarsControllerMac>(area->scrollbarsController()).stopScrollbarPaintTimer();
}

bool ScrollbarsControllerMacArea::scrollbarPaintTimerIsActive() const
{
    CheckedPtr area = m_area;
    return area && downcast<ScrollbarsControllerMac>(area->scrollbarsController()).scrollbarPaintTimerIsActive();
}

bool ScrollbarsControllerMacArea::macThemeUsesOverlayScrollbarsChanged() const
{
    auto& theme = ScrollbarTheme::theme();
    if (theme.isMockTheme())
        return false;
    downcast<ScrollbarThemeMac>(theme).usesOverlayScrollbarsChanged();
    return true;
}

std::unique_ptr<ScrollbarsController> ScrollbarsController::create(ScrollableArea& scrollableArea)
{
    return makeUnique<ScrollbarsControllerMac>(scrollableArea);
}

ScrollbarsControllerMac::ScrollbarsControllerMac(ScrollableArea& scrollableArea)
    : ScrollbarsController(scrollableArea)
    , m_initialScrollbarPaintTimer(*this, &ScrollbarsControllerMac::initialScrollbarPaintTimerFired)
    , m_sendContentAreaScrolledTimer(*this, &ScrollbarsControllerMac::sendContentAreaScrolledTimerFired)
    , m_swift(makeUnique<ScrollbarsControllerMacHolder>(scrollableArea))
{
}

ScrollbarsControllerMac::~ScrollbarsControllerMac()
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    m_swift->controller.invalidate();
    END_BLOCK_OBJC_EXCEPTIONS
}

void ScrollbarsControllerMac::cancelAnimations()
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    m_swift->controller.cancelAnimations();
    END_BLOCK_OBJC_EXCEPTIONS

    ScrollbarsController::cancelAnimations();
}

void ScrollbarsControllerMac::contentAreaWillPaint() const
{
    m_swift->controller.contentAreaWillPaint();
}

void ScrollbarsControllerMac::mouseEnteredContentArea()
{
    m_swift->controller.mouseEnteredContentArea();
}

void ScrollbarsControllerMac::mouseExitedContentArea()
{
    m_swift->controller.mouseExitedContentArea();
}

void ScrollbarsControllerMac::mouseMovedInContentArea()
{
    m_swift->controller.mouseMovedInContentArea();
}

void ScrollbarsControllerMac::mouseEnteredScrollbar(Scrollbar* scrollbar) const
{
    if (m_swift->controller.scrollbarMouseNotificationsAreSent())
        m_swift->controller.mouseEnteredScrollbar(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get());
}

void ScrollbarsControllerMac::mouseExitedScrollbar(Scrollbar* scrollbar) const
{
    if (m_swift->controller.scrollbarMouseNotificationsAreSent())
        m_swift->controller.mouseExitedScrollbar(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get());
}

void ScrollbarsControllerMac::mouseIsDownInScrollbar(Scrollbar* scrollbar, bool mouseIsDown) const
{
    if (m_swift->controller.scrollbarsCanBeActive())
        m_swift->controller.mouseIsDownInScrollbar(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get(), mouseIsDown);
}

void ScrollbarsControllerMac::willStartLiveResize()
{
    m_swift->controller.willStartLiveResize();
}

void ScrollbarsControllerMac::contentsSizeChanged() const
{
    m_swift->controller.contentsSizeChanged();
}

void ScrollbarsControllerMac::willEndLiveResize()
{
    ScrollbarsController::willEndLiveResize();
    m_swift->controller.willEndLiveResize();
}

void ScrollbarsControllerMac::contentAreaDidShow()
{
    m_swift->controller.contentAreaDidShow();
}

void ScrollbarsControllerMac::contentAreaDidHide()
{
    m_swift->controller.contentAreaDidHide();
}

void ScrollbarsControllerMac::didBeginScrollGesture()
{
    if (m_swift->controller.didBeginScrollGesture())
        ScrollbarsController::didBeginScrollGesture();
}

void ScrollbarsControllerMac::didEndScrollGesture()
{
    if (m_swift->controller.didEndScrollGesture())
        ScrollbarsController::didEndScrollGesture();
}

void ScrollbarsControllerMac::mayBeginScrollGesture()
{
    if (m_swift->controller.mayBeginScrollGesture())
        ScrollbarsController::mayBeginScrollGesture();
}

void ScrollbarsControllerMac::lockOverlayScrollbarStateToHidden(bool shouldLockState)
{
    m_swift->controller.lockOverlayScrollbarStateToHidden(shouldLockState);
}

bool ScrollbarsControllerMac::scrollbarsCanBeActive() const
{
    return m_swift->controller.scrollbarsCanBeActive();
}

void ScrollbarsControllerMac::didAddVerticalScrollbar(Scrollbar* scrollbar)
{
    m_swift->controller.didAddVerticalScrollbar(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get(), ScrollbarsControllerMacScrollbar { scrollbar });
}

void ScrollbarsControllerMac::willRemoveVerticalScrollbar(Scrollbar* scrollbar)
{
    m_swift->controller.willRemoveVerticalScrollbar(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get());
}

void ScrollbarsControllerMac::didAddHorizontalScrollbar(Scrollbar* scrollbar)
{
    m_swift->controller.didAddHorizontalScrollbar(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get(), ScrollbarsControllerMacScrollbar { scrollbar });
}

void ScrollbarsControllerMac::willRemoveHorizontalScrollbar(Scrollbar* scrollbar)
{
    m_swift->controller.willRemoveHorizontalScrollbar(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get());
}

void ScrollbarsControllerMac::invalidateScrollbarPartLayers(Scrollbar* scrollbar)
{
    m_swift->controller.invalidateScrollbarPartLayers(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get());
}

void ScrollbarsControllerMac::verticalScrollbarLayerDidChange()
{
    RefPtr scrollbar = scrollableArea().verticalScrollbar();
    m_swift->controller.verticalScrollbarLayerDidChange(protect(scrollbar ? ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar) : nil).get());
}

void ScrollbarsControllerMac::horizontalScrollbarLayerDidChange()
{
    RefPtr scrollbar = scrollableArea().horizontalScrollbar();
    m_swift->controller.horizontalScrollbarLayerDidChange(protect(scrollbar ? ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar) : nil).get());
}

bool ScrollbarsControllerMac::shouldScrollbarParticipateInHitTesting(Scrollbar* scrollbar)
{
    if (m_swift->controller.scrollbarsAlwaysParticipateInHitTesting())
        return true;
    return m_swift->controller.shouldScrollbarParticipateInHitTesting(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get());
}

void ScrollbarsControllerMac::notifyContentAreaScrolled(const FloatSize& delta)
{
    if (m_swift->controller.notifyContentAreaScrolled(delta) && !m_sendContentAreaScrolledTimer.isActive())
        m_sendContentAreaScrolledTimer.startOneShot(0_s);
}

void ScrollbarsControllerMac::updateScrollerStyle()
{
    m_swift->controller.updateScrollerStyle();
}

void ScrollbarsControllerMac::startScrollbarPaintTimer()
{
    m_initialScrollbarPaintTimer.startOneShot(100_ms);
}

bool ScrollbarsControllerMac::scrollbarPaintTimerIsActive() const
{
    return m_initialScrollbarPaintTimer.isActive();
}

void ScrollbarsControllerMac::stopScrollbarPaintTimer()
{
    m_initialScrollbarPaintTimer.stop();
}

void ScrollbarsControllerMac::initialScrollbarPaintTimerFired()
{
    m_swift->controller.initialScrollbarPaintTimerFired();
}

void ScrollbarsControllerMac::sendContentAreaScrolledTimerFired()
{
    m_swift->controller.sendContentAreaScrolledTimerFired();
}

void ScrollbarsControllerMac::scrollbarWidthChanged(WebCore::ScrollbarWidth)
{
    m_swift->controller.scrollbarWidthChanged();
}

String ScrollbarsControllerMac::horizontalScrollbarStateForTesting() const
{
    return m_swift->controller.horizontalScrollbarStateForTesting();
}

String ScrollbarsControllerMac::verticalScrollbarStateForTesting() const
{
    return m_swift->controller.verticalScrollbarStateForTesting();
}

} // namespace WebCore

#endif // PLATFORM(MAC)
