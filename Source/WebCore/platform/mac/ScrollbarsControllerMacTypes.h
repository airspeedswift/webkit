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

// The types of MacScrollbarsController's members in ScrollbarsControllerMac.swift.
#include <WebCore/FloatSize.h>
#include <WebCore/IntPoint.h>
#include <WebCore/IntRect.h>
#include <WebCore/ScrollAnimator.h>
#include <WebCore/ScrollTypes.h>
#include <WebCore/ScrollableArea.h>
#include <WebCore/Scrollbar.h>
#include <WebCore/ScrollbarsController.h>
#include <wtf/WeakPtr.h>

#ifdef __OBJC__
#import <QuartzCore/CALayer.h>
#import <pal/spi/mac/NSScrollerImpSPI.h>
#endif

namespace WebCore {

// The scrollbar an NSScrollerImp delegate and its animations draw for. Each member does nothing, or returns the
// default AppKit gets when the delegate has no scrollbar, once the scrollbar is gone.
struct __attribute__((swift_attr("~Sendable"))) ScrollbarsControllerMacScrollbar {
    explicit ScrollbarsControllerMacScrollbar(Scrollbar* scrollbar)
        : m_scrollbar(scrollbar)
    {
    }
#ifdef __swift__
    ScrollbarsControllerMacScrollbar() = delete;
#endif

    bool isLive() const { return !!m_scrollbar; }
    ScrollbarOrientation orientation() const
    {
        RefPtr scrollbar = m_scrollbar;
        return scrollbar ? scrollbar->orientation() : ScrollbarOrientation::Vertical;
    }
    bool supportsUpdateOnSecondaryThread() const
    {
        RefPtr scrollbar = m_scrollbar;
        return scrollbar && scrollbar->supportsUpdateOnSecondaryThread();
    }
    bool isCustomScrollbar() const
    {
        RefPtr scrollbar = m_scrollbar;
        return scrollbar && scrollbar->isCustomScrollbar();
    }
    bool enabled() const
    {
        RefPtr scrollbar = m_scrollbar;
        return scrollbar && scrollbar->enabled();
    }
    bool isOverlayScrollbar() const
    {
        RefPtr scrollbar = m_scrollbar;
        return scrollbar && scrollbar->isOverlayScrollbar();
    }
    void invalidate() const
    {
        if (RefPtr scrollbar = m_scrollbar)
            scrollbar->invalidate();
    }
    IntPoint convertFromContainingView(const IntPoint& point) const
    {
        RefPtr scrollbar = m_scrollbar;
        return scrollbar ? scrollbar->convertFromContainingView(point) : IntPoint();
    }
    IntRect convertToContainingView(const IntRect& rect) const
    {
        RefPtr scrollbar = m_scrollbar;
        return scrollbar ? scrollbar->convertToContainingView(rect) : IntRect();
    }
#ifdef __OBJC__
    NSScrollerImp *scrollerImp() const;
    void createScrollerImp(NSScrollerImp *) const;
#endif
    void setPaintCharacteristics() const;

private:
    SingleThreadWeakPtr<Scrollbar> m_scrollbar;
};

// The ScrollableArea a ScrollbarsControllerMac and its NSScrollerImpPair delegate work for.
struct __attribute__((swift_attr("~Sendable"))) ScrollbarsControllerMacArea {
    explicit ScrollbarsControllerMacArea(ScrollableArea& area)
        : m_area(area)
    {
    }
#ifdef __swift__
    ScrollbarsControllerMacArea() = delete;
#endif

    bool isLive() const { return !!m_area; }
    IntSize contentsSize() const
    {
        CheckedPtr area = m_area;
        return area ? area->contentsSize() : IntSize();
    }
    bool inLiveResize() const
    {
        CheckedPtr area = m_area;
        return area && area->inLiveResize();
    }
    IntPoint lastKnownMousePositionInView() const
    {
        CheckedPtr area = m_area;
        return area ? area->lastKnownMousePositionInView() : IntPoint();
    }
    ScrollbarsControllerMacScrollbar scrollbar(ScrollbarOrientation orientation) const
    {
        CheckedPtr area = m_area;
        return ScrollbarsControllerMacScrollbar { !area ? nullptr : orientation == ScrollbarOrientation::Vertical ? area->verticalScrollbar() : area->horizontalScrollbar() };
    }
#ifdef __OBJC__
    CALayer *layerForScrollbar(ScrollbarOrientation, bool& hasGraphicsLayer) const;
    CALayer *scrollerImpDelegateLayer(ScrollbarOrientation) const;
#endif
    bool useDarkAppearanceForScrollbars() const
    {
        CheckedPtr area = m_area;
        return area && area->useDarkAppearanceForScrollbars();
    }
    void setVisibleScrollerThumbRect(const IntRect& rect) const
    {
        if (CheckedPtr area = m_area)
            area->setVisibleScrollerThumbRect(rect);
    }
    bool shouldSuspendScrollbarAnimations() const
    {
        CheckedPtr area = m_area;
        return area && area->scrollbarsController().shouldSuspendScrollbarAnimations();
    }
    bool scrollbarAnimationsUnsuspendedByUserInteraction() const
    {
        CheckedPtr area = m_area;
        return area && area->scrollbarsController().scrollbarAnimationsUnsuspendedByUserInteraction();
    }
    void startScrollbarPaintTimer() const;
    void stopScrollbarPaintTimer() const;
    bool scrollbarPaintTimerIsActive() const;
    void updateScrollbarsThickness() const
    {
        if (CheckedPtr area = m_area)
            area->scrollbarsController().updateScrollbarsThickness();
    }
    void scrollbarStyleChanged(ScrollbarStyle style, bool forceUpdate) const
    {
        if (CheckedPtr area = m_area)
            area->scrollbarStyleChanged(style, forceUpdate);
    }
    bool isHandlingWheelEvent() const
    {
        CheckedPtr area = m_area;
        return area && area->isHandlingWheelEvent();
    }
    void deferContentScrollForTesting() const
    {
        if (CheckedPtr area = m_area; RefPtr monitor = area ? area->scrollAnimator().wheelEventTestMonitor() : nullptr)
            monitor->deferForReason(area->scrollingNodeIDForTesting(), WheelEventTestMonitor::DeferReason::ContentScrollInProgress);
    }
    void removeContentScrollDeferralForTesting() const
    {
        if (CheckedPtr area = m_area; RefPtr monitor = area ? area->scrollAnimator().wheelEventTestMonitor() : nullptr)
            monitor->removeDeferralForReason(area->scrollingNodeIDForTesting(), WheelEventTestMonitor::DeferReason::ContentScrollInProgress);
    }
    bool macThemeUsesOverlayScrollbarsChanged() const;

private:
    WeakPtr<ScrollableArea> m_area;
};

} // namespace WebCore

#endif // PLATFORM(MAC)
