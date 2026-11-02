/*
 * Copyright (C) 2006-2024 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. 
 */

#include "config.h"
#include "ScrollView.h"

#include "AccessibilityRegionContext.h"
#include "CornerRadii.h"
#include "FloatQuad.h"
#include "GraphicsContext.h"
#include "GraphicsLayer.h"
#include "HostWindow.h"
#include "Logging.h"
#include "NativeImage.h"
#include "PlatformMouseEvent.h"
#include "PlatformWheelEvent.h"
#include "ScrollAnimator.h"
#include "Scrollbar.h"
#include "ScrollbarTheme.h"
#include "StyleScrollbarGutter.h"
#include <wtf/HexNumber.h>
#include <wtf/SetForScope.h>
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/TextStream.h>

#if !defined(USE_SWIFT_SCROLL_VIEW)
#define USE_SWIFT_SCROLL_VIEW 0
#endif

#if USE_SWIFT_SCROLL_VIEW
#if !USE_SWIFT_SCROLLABLE_AREA
#error "USE_SWIFT_SCROLL_VIEW requires USE_SWIFT_SCROLLABLE_AREA"
#endif
#include "ScrollAnimatorScrollPhysicsClient.h"
#include "WebCore-Swift.h"
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollView);
WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollView::ProhibitScrollingWhenChangingContentSizeForScope);

#if USE_SWIFT_SCROLL_VIEW
bool ScrollAnimatorScrollPhysicsClient::hasPlatformWidget()
{
    return !!scrollView().platformWidget();
}
#endif

ScrollView::ScrollView() = default;

ScrollView::~ScrollView() = default;

void ScrollView::addChild(Widget& child)
{
    ASSERT(&child != this);
    ASSERT(!child.parent());
    child.setParent(this);
    m_children.add(child);
    if (child.platformWidget())
        platformAddChild(&child);
}

void ScrollView::removeChild(Widget& child)
{
    ASSERT(child.parent() == this);
    child.setParent(nullptr);
    m_children.remove(&child);
    if (child.platformWidget())
        platformRemoveChild(&child);
}

bool ScrollView::setHasHorizontalScrollbar(bool hasBar, bool* contentSizeAffected)
{
    return setHasScrollbarInternal(m_horizontalScrollbar, ScrollbarOrientation::Horizontal, hasBar, contentSizeAffected);
}

bool ScrollView::setHasVerticalScrollbar(bool hasBar, bool* contentSizeAffected)
{
    return setHasScrollbarInternal(m_verticalScrollbar, ScrollbarOrientation::Vertical, hasBar, contentSizeAffected);
}

bool ScrollView::setHasScrollbarInternal(RefPtr<Scrollbar>& scrollbar, ScrollbarOrientation orientation, bool hasBar, bool* contentSizeAffected)
{
#if !USE_SWIFT_SCROLL_VIEW
    if (hasBar && !scrollbar) {
        scrollbar = createScrollbar(orientation);
        addChild(*scrollbar);
        didAddScrollbar(scrollbar.get(), orientation);
        scrollbar->styleChanged();
        if (contentSizeAffected)
            *contentSizeAffected = !scrollbar->isOverlayScrollbar();
        return true;
    }
    
    if (!hasBar && scrollbar) {
        bool wasOverlayScrollbar = scrollbar->isOverlayScrollbar();
        willRemoveScrollbar(*scrollbar, orientation);
        removeChild(*scrollbar);
        scrollbar = nullptr;
        if (contentSizeAffected)
            *contentSizeAffected = !wasOverlayScrollbar;
        return true;
    }

    return false;
#else
    UNUSED_PARAM(scrollbar);
    bool ignored = false;
    return scrollViewSetHasScrollbar(ScrollAnimatorScrollPhysicsClientState(*this).facade(), orientation, hasBar, contentSizeAffected ? *contentSizeAffected : ignored);
#endif
}

Ref<Scrollbar> ScrollView::createScrollbar(ScrollbarOrientation orientation)
{
    return Scrollbar::createNativeScrollbar(*this, orientation, ScrollbarWidth::Auto);
}

void ScrollView::setScrollbarModes(ScrollbarMode horizontalMode, ScrollbarMode verticalMode,
                                   bool horizontalLock, bool verticalLock)
{
#if !USE_SWIFT_SCROLL_VIEW
    bool needsUpdate = false;

    if (horizontalMode != horizontalScrollbarMode() && !m_horizontalScrollbarLock) {
        m_horizontalScrollbarMode = horizontalMode;
        needsUpdate = true;
    }

    if (verticalMode != verticalScrollbarMode() && !m_verticalScrollbarLock) {
        m_verticalScrollbarMode = verticalMode;
        needsUpdate = true;
    }

    if (horizontalLock)
        setHorizontalScrollbarLock();

    if (verticalLock)
        setVerticalScrollbarLock();

    if (!needsUpdate)
        return;

    if (platformWidget())
        platformSetScrollbarModes();
    else
        updateScrollbars(scrollPosition());

    scrollbarModesDidChange();
#else
    auto currentHorizontalMode = horizontalScrollbarMode();
    auto currentVerticalMode = verticalScrollbarMode();
    if (!scrollViewSetScrollbarModesChangesAnything(horizontalMode, currentHorizontalMode, m_horizontalScrollbarLock, horizontalLock, verticalMode, currentVerticalMode, m_verticalScrollbarLock, verticalLock))
        return;
    scrollViewSetScrollbarModes(ScrollAnimatorScrollPhysicsClientState(*this).facade(), horizontalMode, currentHorizontalMode, m_horizontalScrollbarLock, horizontalLock, verticalMode, currentVerticalMode, m_verticalScrollbarLock, verticalLock);
#endif
}

void ScrollView::scrollbarModes(ScrollbarMode& horizontalMode, ScrollbarMode& verticalMode) const
{
    if (platformWidget()) {
        platformScrollbarModes(horizontalMode, verticalMode);
        return;
    }
    horizontalMode = m_horizontalScrollbarMode;
    verticalMode = m_verticalScrollbarMode;
}

void ScrollView::setCanHaveScrollbars(bool canScroll)
{
#if !USE_SWIFT_SCROLL_VIEW
    ScrollbarMode newHorizontalMode;
    ScrollbarMode newVerticalMode;
    
    scrollbarModes(newHorizontalMode, newVerticalMode);
    
    if (canScroll && newVerticalMode == ScrollbarMode::AlwaysOff)
        newVerticalMode = ScrollbarMode::Auto;
    else if (!canScroll)
        newVerticalMode = ScrollbarMode::AlwaysOff;
    
    if (canScroll && newHorizontalMode == ScrollbarMode::AlwaysOff)
        newHorizontalMode = ScrollbarMode::Auto;
    else if (!canScroll)
        newHorizontalMode = ScrollbarMode::AlwaysOff;
    
    setScrollbarModes(newHorizontalMode, newVerticalMode);
#else
    setScrollbarModes(scrollViewCanHaveScrollbarsMode(canScroll, horizontalScrollbarMode()), scrollViewCanHaveScrollbarsMode(canScroll, verticalScrollbarMode()));
#endif
}

void ScrollView::setCanBlitOnScroll(bool b)
{
    if (platformWidget()) {
        platformSetCanBlitOnScroll(b);
        return;
    }

    m_canBlitOnScroll = b;
}

bool ScrollView::canBlitOnScroll() const
{
    if (platformWidget())
        return platformCanBlitOnScroll();

    return m_canBlitOnScroll;
}

void ScrollView::setPaintsEntireContents(bool paintsEntireContents)
{
    m_paintsEntireContents = paintsEntireContents;
}

void ScrollView::setDelegatedScrollingMode(DelegatedScrollingMode delegatedScrollingMode)
{
    if (m_delegatedScrollingMode == delegatedScrollingMode)
        return;

    m_delegatedScrollingMode = delegatedScrollingMode;
    delegatedScrollingModeDidChange();
}

IntPoint ScrollView::contentsScrollPosition() const
{
#if PLATFORM(IOS_FAMILY)
    if (platformWidget())
        return actualScrollPosition();
#endif
    return scrollPosition();
}

void ScrollView::setContentsScrollPosition(const IntPoint& position, const ScrollPositionChangeOptions& options)
{
#if PLATFORM(IOS_FAMILY)
    if (platformWidget())
        setActualScrollPosition(position);
#endif
    setScrollPosition(position, options);
}

ViewFloatRect ScrollView::exposedViewRect() const
{
#if PLATFORM(IOS_FAMILY)
    if (platformWidget())
        return contentsToView(inContentsSpace(platformExposedContentRect()));
#endif

    RefPtr parent = this->parent();
    if (!parent)
        return m_delegatedScrollingGeometry ? m_delegatedScrollingGeometry->exposedViewRect : ViewFloatRect { };

    auto parentExposedRect = inContentsSpace(enclosingIntRect(parent->exposedContentRect().raw()));
    auto selfExposedContentsRect = rootViewToContents(parent->contentsToRootView(parentExposedRect));
    selfExposedContentsRect.intersect(viewToContents(inViewSpace(boundsRect())));
    return contentsToView(inContentsSpace(FloatRect { selfExposedContentsRect.raw() }));
}

ContentsFloatRect ScrollView::exposedContentRect() const
{
    return viewToContents(exposedViewRect());
}

void ScrollView::setExposedViewRect(const ViewFloatRect& rect)
{
    ASSERT(!platformWidget());

    if (!m_delegatedScrollingGeometry)
        m_delegatedScrollingGeometry = DelegatedScrollingGeometry();

    m_delegatedScrollingGeometry->exposedViewRect = rect;
}

void ScrollView::adjustExposedContentRectForProgrammaticScroll(ScrollPosition newPosition)
{
#if !USE_SWIFT_SCROLL_VIEW
    if (!m_delegatedScrollingGeometry)
        return;

    // The stored rect is in view space, which only moves with the scroll position when it's also contents space.
    if (!delegatesScrollingToNativeView())
        return;

    FloatSize delta = newPosition - scrollPosition();
    if (delta.isZero())
        return;

    auto movedRect = m_delegatedScrollingGeometry->exposedViewRect.raw();
    movedRect.move(delta);
    m_delegatedScrollingGeometry->exposedViewRect = inViewSpace(movedRect);
#else
    scrollViewAdjustExposedContentRect(ScrollAnimatorScrollPhysicsClientState(*this).facade(), newPosition);
#endif
}

FloatSize ScrollView::unobscuredContentSize() const
{
    ASSERT(m_delegatedScrollingGeometry);
    if (m_delegatedScrollingGeometry)
        return m_delegatedScrollingGeometry->unobscuredContentSize;
    return { };
}

void ScrollView::setUnobscuredContentSize(const FloatSize& size)
{
    ASSERT(!platformWidget());
    if (m_delegatedScrollingGeometry && size == m_delegatedScrollingGeometry->unobscuredContentSize)
        return;

    if (!m_delegatedScrollingGeometry)
        m_delegatedScrollingGeometry = DelegatedScrollingGeometry();

    m_delegatedScrollingGeometry->unobscuredContentSize = size;
    unobscuredContentSizeChanged();
}

IntRect ScrollView::unobscuredContentRect(VisibleContentRectIncludesScrollbars scrollbarInclusion) const
{
    if (platformWidget())
        return platformUnobscuredContentRect(scrollbarInclusion);

    if (m_delegatedScrollingGeometry)
        return IntRect(m_scrollPosition, roundedIntSize(m_delegatedScrollingGeometry->unobscuredContentSize));

    return unobscuredContentRectInternal(scrollbarInclusion);
}

IntRect ScrollView::unobscuredContentRectInternal(VisibleContentRectIncludesScrollbars scrollbarInclusion) const
{
#if !USE_SWIFT_SCROLL_VIEW
    FloatSize visibleContentSize = sizeForUnobscuredContent(scrollbarInclusion);
    visibleContentSize.scale(1 / visibleContentScaleFactor());
    return IntRect(m_scrollPosition, expandedIntSize(visibleContentSize));
#else
    return scrollViewUnobscuredContentRect(sizeForUnobscuredContent(scrollbarInclusion), visibleContentScaleFactor(), m_scrollPosition);
#endif
}

IntSize ScrollView::sizeForVisibleContent(VisibleContentRectIncludesScrollbars scrollbarInclusion) const
{
    if (platformWidget())
        return platformVisibleContentSizeIncludingObscuredArea(scrollbarInclusion == VisibleContentRectIncludesScrollbars::Yes);

    IntSize scrollbarSpace;
    if (!scrollbarGutterStyle().isAuto() && scrollbarInclusion == VisibleContentRectIncludesScrollbars::No)
        scrollbarSpace = totalScrollbarSpace();
    else if (scrollbarInclusion == VisibleContentRectIncludesScrollbars::No)
        scrollbarSpace = scrollbarIntrusion();

    return IntSize(width() - scrollbarSpace.width(), height() - scrollbarSpace.height()).expandedTo(IntSize());
}
    
IntSize ScrollView::sizeForUnobscuredContent(VisibleContentRectIncludesScrollbars scrollbarInclusion) const
{
    if (platformWidget())
        return platformVisibleContentSize(scrollbarInclusion == VisibleContentRectIncludesScrollbars::Yes);

#if !USE_SWIFT_SCROLL_VIEW
    auto obscuredContentInsets = this->obscuredContentInsets();
    return sizeForVisibleContent(scrollbarInclusion) - roundedIntSize(FloatSize {
        obscuredContentInsets.left() + obscuredContentInsets.right(),
        obscuredContentInsets.top() + obscuredContentInsets.bottom()
    });
#else
    return scrollViewSizeForUnobscuredContent(sizeForVisibleContent(scrollbarInclusion), obscuredContentInsets());
#endif
}

IntRect ScrollView::visibleContentRectInternal(VisibleContentRectIncludesScrollbars scrollbarInclusion, VisibleContentRectBehavior visibleContentRectBehavior) const
{
#if PLATFORM(IOS_FAMILY)
    if (visibleContentRectBehavior == LegacyIOSDocumentViewRect) {
        if (platformWidget())
            return platformVisibleContentRect(scrollbarInclusion == VisibleContentRectIncludesScrollbars::Yes);
    }
    
    if (platformWidget())
        return unobscuredContentRect(scrollbarInclusion);
#else
    UNUSED_PARAM(visibleContentRectBehavior);
#endif

    if (platformWidget())
        return platformVisibleContentRect(scrollbarInclusion == VisibleContentRectIncludesScrollbars::Yes);

    return unobscuredContentRect(scrollbarInclusion);
}

IntRect ScrollView::frameRectShrunkByInset() const
{
    FloatRect rect = frameRect();
    rect.contract(obscuredContentInsets());
    return roundedIntRect(rect);
}

CornerRadii ScrollView::scrollbarAvoidanceCornerRadii() const
{
    return { };
}

IntSize ScrollView::layoutSize() const
{
    return m_fixedLayoutSize.isEmpty() || !m_useFixedLayout ? sizeForUnobscuredContent() : m_fixedLayoutSize;
}

IntSize ScrollView::fixedLayoutSize() const
{
    return m_fixedLayoutSize;
}

void ScrollView::setFixedLayoutSize(const IntSize& newSize)
{
    if (fixedLayoutSize() == newSize)
        return;

    LOG_WITH_STREAM(Layout, stream << "ScrollView " << this << " setFixedLayoutSize " << newSize);
    m_fixedLayoutSize = newSize;
    if (m_useFixedLayout)
        availableContentSizeChanged(AvailableSizeChangeReason::AreaSizeChanged);
}

bool ScrollView::useFixedLayout() const
{
    return m_useFixedLayout;
}

void ScrollView::setUseFixedLayout(bool enable)
{
    if (useFixedLayout() == enable)
        return;
    m_useFixedLayout = enable;
    if (!m_fixedLayoutSize.isEmpty())
        availableContentSizeChanged(AvailableSizeChangeReason::AreaSizeChanged);
}

void ScrollView::availableContentSizeChanged(AvailableSizeChangeReason reason)
{
    ScrollableArea::availableContentSizeChanged(reason);

    if (platformWidget())
        return;

    if (reason != AvailableSizeChangeReason::ScrollbarsChanged)
        updateScrollbars(scrollPosition());
}

IntSize ScrollView::contentsSize() const
{
    return m_contentsSize;
}

void ScrollView::setContentsSize(const IntSize& newSize)
{
    if (contentsSize() == newSize)
        return;
    m_contentsSize = newSize;
    if (platformWidget())
        platformSetContentsSize();
    else if (!m_prohibitsScrollingWhenChangingContentSizeCount)
        updateScrollbars(scrollPosition());
    updateOverhangAreas();
}

ScrollPosition ScrollView::maximumScrollPosition() const
{
    ScrollPosition maximumPosition = ScrollableArea::maximumScrollPosition();
    // FIXME: can this be moved into the base class?
    maximumPosition.clampNegativeToZero();
    return maximumPosition;
}

ScrollPosition ScrollView::adjustScrollPositionWithinRange(const ScrollPosition& scrollPosition) const
{
    if (scrollClamping() == ScrollClamping::Unclamped || m_allowsUnclampedScrollPosition)
        return scrollPosition;

    return scrollPosition.constrainedBetween(minimumScrollPosition(), maximumScrollPosition());
}

void ScrollView::cacheCurrentScrollState()
{
    m_cachedScrollPosition = scrollPosition();
#if PLATFORM(IOS_FAMILY)
    m_cachedUnobscuredContentRect = unobscuredContentRect();
    m_cachedExposedContentRect = exposedContentRect().raw();
#endif
}

ScrollPosition ScrollView::documentScrollPositionRelativeToViewOrigin() const
{
#if !USE_SWIFT_SCROLL_VIEW
    auto obscuredContentInsets = this->obscuredContentInsets(InsetType::WebCoreOrPlatformInset);
    return scrollPosition() - IntSize(insetForLeftScrollbarSpace() + obscuredContentInsets.left(), headerHeight() + obscuredContentInsets.top());
#else
    return scrollViewDocumentScrollPositionRelativeToViewOrigin(scrollPosition(), viewToContentsInsetOffset());
#endif
}

ScrollPosition ScrollView::documentScrollPositionRelativeToScrollableAreaOrigin() const
{
    return scrollPosition() - IntSize(0, headerHeight());
}

void ScrollView::setScrollOffset(const ScrollOffset& offset)
{
#if !USE_SWIFT_SCROLL_VIEW
    LOG_WITH_STREAM(Scrolling, stream << "\nScrollView::setScrollOffset " << offset << " clamping " << scrollClamping());

    auto constrainedOffset = offset;
    if (scrollClamping() == ScrollClamping::Clamped)
        constrainedOffset = constrainedOffset.constrainedBetween(minimumScrollOffset(), maximumScrollOffset());

    scrollTo(scrollPositionFromOffset(constrainedOffset));
#else
    bool clamped = scrollClamping() == ScrollClamping::Clamped;
    auto totalContentsSize = clamped ? this->totalContentsSize() : IntSize { };
    auto visibleSize = clamped ? this->visibleSize() : IntSize { };
    scrollTo(scrollViewScrollOffsetTarget(offset, clamped, totalContentsSize, visibleSize, scrollOrigin()));
#endif
}

void ScrollView::scrollOffsetChangedViaPlatformWidget(const ScrollOffset& oldOffset, const ScrollOffset& newOffset)
{
#if !USE_SWIFT_SCROLL_VIEW
    // We should not attempt to actually modify (paint) platform widgets if the layout phase
    // is not complete. Instead, defer the scroll event until the layout finishes.
    if (shouldDeferScrollUpdateAfterContentSizeChange()) {
        // We only care about the most recent scroll position change request
        m_deferredScrollOffsets = std::make_pair(oldOffset, newOffset);
        return;
    }

    scrollOffsetChangedViaPlatformWidgetImpl(oldOffset, newOffset);
    scrollAnimator().setCurrentPosition(scrollPosition());
#else
    scrollViewScrollOffsetChangedViaPlatformWidget(ScrollAnimatorScrollPhysicsClientState(*this).facade(), oldOffset, newOffset);
#endif
}

void ScrollView::handleDeferredScrollUpdateAfterContentSizeChange()
{
#if !USE_SWIFT_SCROLL_VIEW
    ASSERT(!shouldDeferScrollUpdateAfterContentSizeChange());

    if (!m_deferredScrollDelta && !m_deferredScrollOffsets)
        return;

    ASSERT(static_cast<bool>(m_deferredScrollDelta) != static_cast<bool>(m_deferredScrollOffsets));

    if (m_deferredScrollDelta)
        completeUpdatesAfterScrollTo(m_deferredScrollDelta.value());
    else if (m_deferredScrollOffsets)
        scrollOffsetChangedViaPlatformWidgetImpl(m_deferredScrollOffsets.value().first, m_deferredScrollOffsets.value().second);
    
    m_deferredScrollDelta = std::nullopt;
    m_deferredScrollOffsets = std::nullopt;
#else
    scrollViewHandleDeferredScrollUpdate(ScrollAnimatorScrollPhysicsClientState(*this).facade());
#endif
}

void ScrollView::scrollTo(const ScrollPosition& newPosition)
{
#if !USE_SWIFT_SCROLL_VIEW
    LOG_WITH_STREAM(Scrolling, stream << "ScrollView::scrollTo " << newPosition << " min: " << minimumScrollPosition() << " max: " << maximumScrollPosition());

    IntSize scrollDelta = newPosition - m_scrollPosition;
    if (scrollDelta.isZero())
        return;

    if (platformWidget()) {
        platformSetScrollPosition(newPosition);
        return;
    }

    m_scrollPosition = newPosition;

    if (scrollbarsSuppressed())
        return;

    // We should not attempt to actually modify layer contents if the layout phase
    // is not complete. Instead, defer the scroll event until the layout finishes.
    if (shouldDeferScrollUpdateAfterContentSizeChange()) {
        m_deferredScrollDelta = m_deferredScrollDelta ? *m_deferredScrollDelta + scrollDelta : scrollDelta;
        return;
    }

    completeUpdatesAfterScrollTo(scrollDelta);
#else
    if (!scrollViewScrollToMoves(m_scrollPosition, newPosition))
        return;
    scrollViewScrollTo(ScrollAnimatorScrollPhysicsClientState(*this).facade(), newPosition);
#endif
}

#if !USE_SWIFT_SCROLL_VIEW
void ScrollView::completeUpdatesAfterScrollTo(const IntSize& scrollDelta)
{
    updateLayerPositionsAfterScrolling();
    scrollContents(scrollDelta);
    updateCompositingLayersAfterScrolling();
}
#endif

void ScrollView::setScrollPosition(const ScrollPosition& scrollPosition, const ScrollPositionChangeOptions& options)
{
#if !USE_SWIFT_SCROLL_VIEW
    LOG_WITH_STREAM(Scrolling, stream << "ScrollView::setScrollPosition " << scrollPosition);

    if (prohibitsScrolling())
        return;

    if (scrollAnimationStatus() == ScrollAnimationStatus::Animating) {
        scrollAnimator().cancelAnimations();
        stopAsyncAnimatedScroll();
    }

    if (platformWidget()) {
        platformSetScrollPosition(scrollPosition);
        return;
    }

    auto newScrollPosition = (!delegatesScrollingToNativeView() && options.clamping == ScrollClamping::Clamped) ? adjustScrollPositionWithinRange(scrollPosition) : scrollPosition;
    bool scrollPositionChanged = newScrollPosition != this->scrollPosition();

    if (currentScrollType() == ScrollType::User && !scrollPositionChanged) {
        LOG_WITH_STREAM(Scrolling, stream << "ScrollView::setScrollPosition " << scrollPosition << " return for no change");
        return;
    }

    if (!requestScrollToPosition(newScrollPosition, options))
        updateScrollbars(newScrollPosition);
#else
    if (!scrollViewSetScrollPositionProceeds(prohibitsScrolling()))
        return;
    scrollViewSetScrollPosition(ScrollAnimatorScrollPhysicsClientState(*this).facade(), scrollPosition, options.type, options.clamping, options.animated, options.snapPointSelectionMethod, options.originalScrollDelta.has_value(), options.originalScrollDelta.value_or(FloatSize { }), options.interruptsAnimation, options.animationCurve);
#endif
}

bool ScrollView::scroll(ScrollDirection direction, ScrollGranularity granularity)
{
    if (platformWidget())
        return platformScroll(direction, granularity);

    return ScrollableArea::scroll(direction, granularity);
}

bool ScrollView::logicalScroll(ScrollLogicalDirection direction, ScrollGranularity granularity)
{
    return scroll(logicalToPhysical(direction, isVerticalDocument(), isFlippedDocument()), granularity);
}

IntSize ScrollView::overhangAmount() const
{
#if !USE_SWIFT_SCROLL_VIEW
    IntSize stretch;

    // FIXME: use maximumScrollOffset()
    ScrollOffset scrollOffset = this->scrollOffset();
    if (scrollOffset.y() < 0)
        stretch.setHeight(scrollOffset.y());
    else if (totalContentsSize().height() && scrollOffset.y() > totalContentsSize().height() - visibleHeight())
        stretch.setHeight(scrollOffset.y() - (totalContentsSize().height() - visibleHeight()));

    if (scrollOffset.x() < 0)
        stretch.setWidth(scrollOffset.x());
    else if (contentsWidth() && scrollOffset.x() > contentsWidth() - visibleWidth())
        stretch.setWidth(scrollOffset.x() - (contentsWidth() - visibleWidth()));

    return stretch;
#else
    return scrollViewOverhangAmount(scrollOffset(), totalContentsSize(), visibleSize(), contentsWidth());
#endif
}

bool ScrollView::managesScrollbars() const
{
#if PLATFORM(IOS_FAMILY)
    // FIXME: We should be able to remove this. iOS should always hit the DelegatedToNativeScrollView condition below.
    return false;
#else
#if !USE_SWIFT_SCROLL_VIEW
    if (platformWidget())
        return false;

    if (delegatedScrollingMode() == DelegatedScrollingMode::DelegatedToNativeScrollView)
        return false;

    return true;
#else
    return scrollViewManagesScrollbars(!!platformWidget(), delegatedScrollingMode());
#endif
#endif
}

void ScrollView::updateScrollbars(const ScrollPosition& desiredPosition)
{
#if !USE_SWIFT_SCROLL_VIEW
    LOG_WITH_STREAM(Layout, stream << "ScrollView " << this << " updateScrollbars " << desiredPosition << " horizontalScrollbarMode " << m_horizontalScrollbarMode << " verticalScrollbarMode " << m_verticalScrollbarMode);

    if (m_inUpdateScrollbars || prohibitsScrolling() || platformWidget())
        return;
    
    auto scrollToPosition = [&](ScrollPosition desiredPosition) {
        auto adjustedScrollPosition = desiredPosition;
        if (!isRubberBandInProgress())
            adjustedScrollPosition = adjustScrollPositionWithinRange(adjustedScrollPosition);

        if (adjustedScrollPosition != scrollPosition() || scrollOriginChanged()) {
            ScrollableArea::scrollToPositionWithoutAnimation(adjustedScrollPosition);
            resetScrollOriginChanged();
        }
    };

    if (!managesScrollbars()) {
        scrollToPosition(desiredPosition);
        return;
    }

    bool scrollbarCanTakeSpace = canShowNonOverlayScrollbars();

    // If we came in here with the view already needing a layout then do that first.
    // (This will be the common case, e.g., when the page changes due to window resizing for example).
    // This layout will not re-enter updateScrollbars and does not count towards our max layout pass total.
    if (!m_scrollbarsSuppressed && scrollbarCanTakeSpace) {
        SetForScope inUpdateScrollbarsScope(m_inUpdateScrollbars, true, false);
        updateContentsSize();
    }

    IntRect oldScrollCornerRect = scrollCornerRect();

    bool hasHorizontalScrollbar = m_horizontalScrollbar;
    bool hasVerticalScrollbar = m_verticalScrollbar;
    
    bool newHasHorizontalScrollbar = hasHorizontalScrollbar;
    bool newHasVerticalScrollbar = hasVerticalScrollbar;
   
    ScrollbarMode hScroll = m_horizontalScrollbarMode;
    ScrollbarMode vScroll = m_verticalScrollbarMode;

    if (hScroll != ScrollbarMode::Auto)
        newHasHorizontalScrollbar = (hScroll == ScrollbarMode::AlwaysOn);
    if (vScroll != ScrollbarMode::Auto)
        newHasVerticalScrollbar = (vScroll == ScrollbarMode::AlwaysOn);

    bool scrollbarAddedOrRemoved = false;

    if (m_scrollbarsSuppressed || (hScroll != ScrollbarMode::Auto && vScroll != ScrollbarMode::Auto)) {
        if (hasHorizontalScrollbar != newHasHorizontalScrollbar) {
            if (setHasHorizontalScrollbar(newHasHorizontalScrollbar))
                scrollbarAddedOrRemoved = true;
        }

        if (hasVerticalScrollbar != newHasVerticalScrollbar) {
            if (setHasVerticalScrollbar(newHasVerticalScrollbar))
                scrollbarAddedOrRemoved = true;
        }
    } else {
        bool sendContentResizedNotification = false;
        
        IntSize docSize = totalContentsSize();
        IntSize fullVisibleSize = unobscuredContentRectIncludingScrollbars().size();

        LOG_WITH_STREAM(Layout, stream << "ScrollView " << this << " updateScrollbars - docSize " << docSize << " visible size " << visibleSize() << " fullVisibleSize " << fullVisibleSize);

        // These are in contents coordinates, so a zoomed-in page gets a scrollbar for the content the view no longer covers.
        if (hScroll == ScrollbarMode::Auto)
            newHasHorizontalScrollbar = docSize.width() > visibleWidth();
        if (vScroll == ScrollbarMode::Auto)
            newHasVerticalScrollbar = docSize.height() > visibleHeight();

        bool needAnotherPass = false;
        if (scrollbarCanTakeSpace) {
            // If we ever turn one scrollbar off, do not turn the other one on. Never ever
            // try to both gain/lose a scrollbar in the same pass.
            if (!m_updateScrollbarsPass && docSize.width() <= fullVisibleSize.width() && docSize.height() <= fullVisibleSize.height()) {
                if (hScroll == ScrollbarMode::Auto)
                    newHasHorizontalScrollbar = false;
                if (vScroll == ScrollbarMode::Auto)
                    newHasVerticalScrollbar = false;
            }
            if (!newHasHorizontalScrollbar && hasHorizontalScrollbar && vScroll != ScrollbarMode::AlwaysOn && !hasVerticalScrollbar) {
                newHasVerticalScrollbar = false;
                needAnotherPass = true;
            }
            if (!newHasVerticalScrollbar && hasVerticalScrollbar && hScroll != ScrollbarMode::AlwaysOn && !hasHorizontalScrollbar) {
                newHasHorizontalScrollbar = false;
                needAnotherPass = true;
            }
        }

        if (hasHorizontalScrollbar != newHasHorizontalScrollbar) {
            if (scrollOrigin().y() && !newHasHorizontalScrollbar)
                ScrollableArea::setScrollOrigin(IntPoint(scrollOrigin().x(), scrollOrigin().y() - protect(m_horizontalScrollbar)->occupiedHeight()));
            if (m_horizontalScrollbar)
                protect(m_horizontalScrollbar)->invalidate();

            bool changeAffectsContentSize = false;
            if (setHasHorizontalScrollbar(newHasHorizontalScrollbar, &changeAffectsContentSize)) {
                scrollbarAddedOrRemoved = true;
                sendContentResizedNotification |= changeAffectsContentSize;
            }
        }

        if (hasVerticalScrollbar != newHasVerticalScrollbar) {
            if (scrollOrigin().x() && !newHasVerticalScrollbar)
                ScrollableArea::setScrollOrigin(IntPoint(scrollOrigin().x() - protect(m_verticalScrollbar)->occupiedWidth(), scrollOrigin().y()));
            if (m_verticalScrollbar)
                protect(m_verticalScrollbar)->invalidate();

            bool changeAffectsContentSize = false;
            if (setHasVerticalScrollbar(newHasVerticalScrollbar, &changeAffectsContentSize)) {
                scrollbarAddedOrRemoved = true;
                sendContentResizedNotification |= changeAffectsContentSize;
            }
        }

        const unsigned cMaxUpdateScrollbarsPass = 3;
        if ((sendContentResizedNotification || needAnotherPass) && m_updateScrollbarsPass < cMaxUpdateScrollbarsPass) {
            m_updateScrollbarsPass++;
            availableContentSizeChanged(AvailableSizeChangeReason::ScrollbarsChanged);
            updateContentsSize();
            IntSize newDocSize = totalContentsSize();
            if (newDocSize == docSize) {
                // The layout with the new scroll state had no impact on
                // the document's overall size, so updateScrollbars didn't get called.
                // Recur manually.
                updateScrollbars(desiredPosition);
            }
            m_updateScrollbarsPass--;
        }
    }

    if (scrollbarAddedOrRemoved)
        addedOrRemovedScrollbar();

    // Set up the range (and page step/line step), but only do this if we're not in a nested call (to avoid
    // doing it multiple times).
    if (m_updateScrollbarsPass)
        return;

    SetForScope inUpdateScrollbarsScope(m_inUpdateScrollbars, true, false);

    auto needsLayersRepositioned = false;
    auto contentInsets = this->obscuredContentInsets();
    auto cornerRadii = this->scrollbarAvoidanceCornerRadii();

    if (m_horizontalScrollbar) {
        Ref horizontalScrollbar = *m_horizontalScrollbar;
        int clientWidth = visibleWidth();
        IntRect oldRect(horizontalScrollbar->frameRect());

        auto scrollerHalfHeight = horizontalScrollbar->height() / 2.f;
        auto scrollCornerWidth = m_verticalScrollbar ? static_cast<float>(protect(m_verticalScrollbar)->occupiedWidth()) : 0.f;
        auto leftOffset = std::max(0.f, cornerRadii.bottomLeft().width() - (shouldPlaceVerticalScrollbarOnLeft() ? scrollCornerWidth : 0.f));
        auto rightOffset = std::max(0.f, cornerRadii.bottomRight().width() - (shouldPlaceVerticalScrollbarOnLeft() ? 0.f : scrollCornerWidth));

        if (!m_horizontalScrollbar->isCustomScrollbar()) {
            leftOffset = std::max(0.f, leftOffset - scrollerHalfHeight);
            rightOffset = std::max(0.f, rightOffset - scrollerHalfHeight);
        }

        leftOffset = std::max(leftOffset, contentInsets.left());
        rightOffset = std::max(rightOffset, contentInsets.right());

        auto horizontalOffset = leftOffset + (shouldPlaceVerticalScrollbarOnLeft() && m_verticalScrollbar ? protect(m_verticalScrollbar)->occupiedWidth() : 0.f);
        auto barWidth = width() - (m_verticalScrollbar ? protect(m_verticalScrollbar)->occupiedWidth() : 0.f) - leftOffset - rightOffset;

        auto horizontalScrollbarY = height() - horizontalScrollbar->height() - contentInsets.bottom();

        horizontalScrollbar->setFrameRect(roundedIntRect({
            horizontalOffset,
            static_cast<float>(horizontalScrollbarY),
            barWidth,
            static_cast<float>(horizontalScrollbar->height())
        }));
        if (!m_scrollbarsSuppressed && oldRect != horizontalScrollbar->frameRect()) {
            horizontalScrollbar->invalidate();
            needsLayersRepositioned = true;
        }

        if (m_scrollbarsSuppressed)
            m_horizontalScrollbar->setSuppressInvalidation(true);
        horizontalScrollbar->setEnabled(contentsWidth() > clientWidth);
        horizontalScrollbar->setProportion(clientWidth, contentsWidth());
        if (m_scrollbarsSuppressed)
            m_horizontalScrollbar->setSuppressInvalidation(false);
    }

    if (m_verticalScrollbar) {
        Ref verticalScrollbar = *m_verticalScrollbar;
        int clientHeight = visibleHeight();
        IntRect oldRect(verticalScrollbar->frameRect());

        auto scrollerHalfWidth = verticalScrollbar->width() / 2.f;
        bool isRTL = shouldPlaceVerticalScrollbarOnLeft();

        auto upperCornerRadius = isRTL ? cornerRadii.topLeft().height() : cornerRadii.topRight().height();
        auto lowerCornerRadius = isRTL ? cornerRadii.bottomLeft().height() : cornerRadii.bottomRight().height();

        auto topOffset = std::max(0.f, upperCornerRadius);
        auto scrollCornerHeight = m_horizontalScrollbar ? static_cast<float>(protect(m_horizontalScrollbar)->occupiedHeight()) : 0.f;
        auto bottomOffset = std::max(0.f, lowerCornerRadius - scrollCornerHeight);

        if (!m_verticalScrollbar->isCustomScrollbar()) {
            topOffset = std::max(0.f, topOffset - scrollerHalfWidth);
            bottomOffset = std::max(0.f, bottomOffset - scrollerHalfWidth);
        }

        topOffset = std::max(topOffset, contentInsets.top());
        bottomOffset = std::max(bottomOffset, contentInsets.bottom());

        auto barHeight = height() - (m_horizontalScrollbar ? protect(m_horizontalScrollbar)->occupiedHeight() : 0) - topOffset - bottomOffset;

        auto verticalScrollbarX = isRTL ? contentInsets.left() : width() - verticalScrollbar->width() - contentInsets.right();

        verticalScrollbar->setFrameRect(roundedIntRect({
            verticalScrollbarX,
            topOffset,
            static_cast<float>(verticalScrollbar->width()),
            barHeight
        }));
        if (!m_scrollbarsSuppressed && oldRect != verticalScrollbar->frameRect()) {
            verticalScrollbar->invalidate();
            needsLayersRepositioned = true;
        }

        if (m_scrollbarsSuppressed)
            m_verticalScrollbar->setSuppressInvalidation(true);
        verticalScrollbar->setEnabled(totalContentsSize().height() > clientHeight);
        verticalScrollbar->setProportion(clientHeight, totalContentsSize().height());
        if (m_scrollbarsSuppressed)
            m_verticalScrollbar->setSuppressInvalidation(false);
    }

    updateScrollbarSteps();
    if (needsLayersRepositioned)
        positionScrollbarLayers();

    if (hasHorizontalScrollbar != newHasHorizontalScrollbar || hasVerticalScrollbar != newHasVerticalScrollbar) {
        // FIXME: Is frameRectsChanged really necessary here? Have any frame rects changed?
        frameRectsChanged();
        positionScrollbarLayers();
        updateScrollCorner();
        if (!m_horizontalScrollbar && !m_verticalScrollbar)
            invalidateScrollCornerRect(oldScrollCornerRect);
    }

    scrollToPosition(desiredPosition);

    // Make sure the scrollbar offsets are up to date.
    if (m_horizontalScrollbar)
        protect(m_horizontalScrollbar)->offsetDidChange();
    if (m_verticalScrollbar)
        protect(m_verticalScrollbar)->offsetDidChange();
#else
    scrollViewUpdateScrollbars(ScrollAnimatorScrollPhysicsClientState(*this).facade(), desiredPosition);
#endif
}

void ScrollView::updateScrollbarSteps()
{
#if !USE_SWIFT_SCROLL_VIEW
    if (m_horizontalScrollbar)
        m_horizontalScrollbar->setSteps(Scrollbar::pixelsPerLineStep(visibleWidth()), Scrollbar::pageStep(visibleWidth()));
    if (m_verticalScrollbar)
        m_verticalScrollbar->setSteps(Scrollbar::pixelsPerLineStep(visibleHeight()), Scrollbar::pageStep(visibleHeight()));
#else
    scrollViewUpdateScrollbarSteps(ScrollAnimatorScrollPhysicsClientState(*this).facade());
#endif
}

const int panIconSizeLength = 16;
#if USE_SWIFT_SCROLL_VIEW
// ScrollView.swift uses the same size.
static_assert(panIconSizeLength == 16);
#endif

#if !USE_SWIFT_SCROLL_VIEW
IntRect ScrollView::rectToCopyOnScroll() const
{
    IntRect scrollViewRect = convertToRootView(IntRect(0, 0, visibleWidth(), visibleHeight()));
    if (hasOverlayScrollbars()) {
        if (verticalScrollbar() && !hasLayerForVerticalScrollbar()) {
            if (shouldPlaceVerticalScrollbarOnLeft())
                scrollViewRect.shiftXEdgeBy(protect(verticalScrollbar())->width());
            else
                scrollViewRect.shiftMaxXEdgeBy(-protect(verticalScrollbar())->width());
        }
        if (horizontalScrollbar() && !hasLayerForHorizontalScrollbar())
            scrollViewRect.shiftMaxYEdgeBy(-protect(horizontalScrollbar())->height());
    }
    return scrollViewRect;
}
#endif

void ScrollView::scrollContents(const IntSize& scrollDelta)
{
#if !USE_SWIFT_SCROLL_VIEW
    HostWindow* window = hostWindow();
    if (!window)
        return;

    // Since scrolling is double buffered, we will be blitting the scroll view's intersection
    // with the clip rect every time to keep it smooth.
    IntRect clipRect = windowClipRect();
    IntRect scrollViewRect = rectToCopyOnScroll();    
    IntRect updateRect = clipRect;
    updateRect.intersect(scrollViewRect);

    // Invalidate the root view (not the backing store).
    window->invalidateRootView(updateRect);

    if (m_drawPanScrollIcon) {
        // FIXME: the pan icon is broken when accelerated compositing is on, since it will draw under the compositing layers.
        // https://bugs.webkit.org/show_bug.cgi?id=47837
        int panIconDirtySquareSizeLength = 2 * (panIconSizeLength + std::max(std::abs(scrollDelta.width()), std::abs(scrollDelta.height()))); // We only want to repaint what's necessary
        IntPoint panIconDirtySquareLocation = IntPoint(m_panScrollIconPoint.x() - (panIconDirtySquareSizeLength / 2), m_panScrollIconPoint.y() - (panIconDirtySquareSizeLength / 2));
        IntRect panScrollIconDirtyRect = IntRect(panIconDirtySquareLocation, IntSize(panIconDirtySquareSizeLength, panIconDirtySquareSizeLength));
        panScrollIconDirtyRect.intersect(clipRect);
        window->invalidateContentsAndRootView(panScrollIconDirtyRect);
    }

    if (canBlitOnScroll()) { // The main frame can just blit the WebView window
        // FIXME: Find a way to scroll subframes with this faster path
        if (!scrollContentsFastPath(-scrollDelta, scrollViewRect, clipRect))
            scrollContentsSlowPath(updateRect);
    } else { 
        // We need to repaint the entire backing store. Do it now before moving the windowed plugins.
        scrollContentsSlowPath(updateRect);
    }

    // Invalidate the overhang areas if they are visible.
    updateOverhangAreas();

    // This call will move children with native widgets (plugins) and invalidate them as well.
    frameRectsChanged();

    // Now blit the backingstore into the window which should be very fast.
    window->invalidateRootView(IntRect());
#else
    scrollViewScrollContents(ScrollAnimatorScrollPhysicsClientState(*this).facade(), scrollDelta);
#endif
}

void ScrollView::scrollContentsSlowPath(const IntRect& updateRect)
{
    hostWindow()->invalidateContentsForSlowScroll(updateRect);
}

// The insets and the header stay in view coordinates when the page scale is applied above the contents, while
// the scroll position scales, so the translation splits in two:
//     view = insetOffset + (contents - scrollPosition()) * scale
// At scale 1 this is just documentScrollPositionRelativeToViewOrigin().
IntSize ScrollView::viewToContentsInsetOffset() const
{
    auto obscuredContentInsets = this->obscuredContentInsets(InsetType::WebCoreOrPlatformInset);
    // The header sits above the document rather than in it, and isn't zoomed, so it belongs in this term.
    return IntSize(insetForLeftScrollbarSpace() + obscuredContentInsets.left(), obscuredContentInsets.top() + headerHeight());
}

IntPoint ScrollView::viewToContents(const IntPoint& point) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (delegatesScrollingToNativeView())
        return point;

    if (visibleContentScaleFactor() == 1)
        return point + toIntSize(documentScrollPositionRelativeToViewOrigin());

    return roundedIntPoint(viewToContents(FloatPoint { point }));
#else
    return scrollViewViewToContentsIntPoint(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), point);
#endif
}

IntPoint ScrollView::contentsToView(const IntPoint& point) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (delegatesScrollingToNativeView())
        return point;

    if (visibleContentScaleFactor() == 1)
        return point - toIntSize(documentScrollPositionRelativeToViewOrigin());

    return roundedIntPoint(contentsToView(FloatPoint { point }));
#else
    return scrollViewContentsToViewIntPoint(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), point);
#endif
}

FloatPoint ScrollView::viewToContents(const FloatPoint& point) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (delegatesScrollingToNativeView())
        return point;

    float scale = visibleContentScaleFactor();
    if (scale == 1)
        return point + toIntSize(documentScrollPositionRelativeToViewOrigin());

    auto contentsPoint = (point - FloatSize { viewToContentsInsetOffset() }).scaled(1 / scale);
    return contentsPoint + toFloatSize(scrollPosition());
#else
    return scrollViewViewToContentsFloatPoint(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), point);
#endif
}

DoublePoint ScrollView::viewToContents(const DoublePoint& point) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (delegatesScrollingToNativeView())
        return point;

    double scale = visibleContentScaleFactor();
    if (scale == 1)
        return point + toDoubleSize(documentScrollPositionRelativeToViewOrigin());

    auto insetOffset = viewToContentsInsetOffset();
    auto contentsPoint = DoublePoint { point.x() - insetOffset.width(), point.y() - insetOffset.height() }.scaled(1 / scale);
    return contentsPoint + toDoubleSize(scrollPosition());
#else
    return scrollViewViewToContentsDoublePoint(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), point);
#endif
}

FloatPoint ScrollView::contentsToView(const FloatPoint& point) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (delegatesScrollingToNativeView())
        return point;

    float scale = visibleContentScaleFactor();
    if (scale == 1)
        return point - toFloatSize(documentScrollPositionRelativeToViewOrigin());

    auto viewPoint = (point - toFloatSize(scrollPosition())).scaled(scale);
    return viewPoint + FloatSize { viewToContentsInsetOffset() };
#else
    return scrollViewContentsToViewFloatPoint(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), point);
#endif
}

DoublePoint ScrollView::contentsToView(const DoublePoint& point) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (delegatesScrollingToNativeView())
        return point;

    double scale = visibleContentScaleFactor();
    if (scale == 1)
        return point - toDoubleSize(documentScrollPositionRelativeToViewOrigin());

    auto insetOffset = viewToContentsInsetOffset();
    auto viewPoint = (point - toDoubleSize(scrollPosition())).scaled(scale);
    return viewPoint + DoubleSize { static_cast<double>(insetOffset.width()), static_cast<double>(insetOffset.height()) };
#else
    return scrollViewContentsToViewDoublePoint(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), point);
#endif
}

IntRect ScrollView::viewToContents(IntRect rect) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (delegatesScrollingToNativeView())
        return rect;

    if (visibleContentScaleFactor() == 1) {
        rect.moveBy(documentScrollPositionRelativeToViewOrigin());
        return rect;
    }

    return enclosingIntRect(viewToContents(FloatRect { rect }));
#else
    return scrollViewViewToContentsIntRect(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), rect);
#endif
}

FloatRect ScrollView::viewToContents(FloatRect rect) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (delegatesScrollingToNativeView())
        return rect;

    float scale = visibleContentScaleFactor();
    if (scale == 1) {
        rect.moveBy(documentScrollPositionRelativeToViewOrigin());
        return rect;
    }

    // The size scales along with the location, since a view pixel covers less content once it's magnified.
    rect.setLocation(viewToContents(rect.location()));
    rect.setSize(rect.size().scaled(1 / scale));
    return rect;
#else
    return scrollViewViewToContentsFloatRect(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), rect);
#endif
}

IntRect ScrollView::contentsToView(IntRect rect) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (delegatesScrollingToNativeView())
        return rect;

    if (visibleContentScaleFactor() == 1) {
        rect.moveBy(-documentScrollPositionRelativeToViewOrigin());
        return rect;
    }

    return enclosingIntRect(contentsToView(FloatRect { rect }));
#else
    return scrollViewContentsToViewIntRect(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), rect);
#endif
}

FloatRect ScrollView::contentsToView(FloatRect rect) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (delegatesScrollingToNativeView())
        return rect;

    float scale = visibleContentScaleFactor();
    if (scale == 1) {
        rect.moveBy(-documentScrollPositionRelativeToViewOrigin());
        return rect;
    }

    rect.setLocation(contentsToView(rect.location()));
    rect.setSize(rect.size().scaled(scale));
    return rect;
#else
    return scrollViewContentsToViewFloatRect(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), rect);
#endif
}

IntPoint ScrollView::contentsToContainingViewContents(const IntPoint& point) const
{
    if (const RefPtr parentScrollView = parent()) {
        IntPoint pointInContainingView = convertToContainingView(contentsToView(point));
        return parentScrollView->viewToContents(pointInContainingView);
    }

    return contentsToView(point);
}

IntRect ScrollView::contentsToContainingViewContents(IntRect rect) const
{
    if (const RefPtr parentScrollView = parent()) {
        IntRect rectInContainingView = convertToContainingView(contentsToView(rect));
        return parentScrollView->viewToContents(rectInContainingView);
    }

    return contentsToView(rect);
}

DoublePoint ScrollView::rootViewToContents(const DoublePoint& rootViewPoint) const
{
    return viewToContents(convertFromRootView(rootViewPoint));
}

FloatPoint ScrollView::rootViewToContents(const FloatPoint& rootViewPoint) const
{
    return viewToContents(convertFromRootView(rootViewPoint));
}

IntPoint ScrollView::rootViewToContents(const IntPoint& rootViewPoint) const
{
    return viewToContents(convertFromRootView(rootViewPoint));
}

IntPoint ScrollView::contentsToRootView(const IntPoint& contentsPoint) const
{
    return convertToRootView(contentsToView(contentsPoint));
}

FloatPoint ScrollView::contentsToRootView(const FloatPoint& contentsPoint) const
{
    return convertToRootView(contentsToView(contentsPoint));
}

DoublePoint ScrollView::contentsToRootView(const DoublePoint& contentsPoint) const
{
    return convertToRootView(contentsToView(contentsPoint));
}

IntRect ScrollView::rootViewToContents(const IntRect& rootViewRect) const
{
    return viewToContents(convertFromRootView(rootViewRect));
}

FloatRect ScrollView::rootViewToContents(const FloatRect& rootViewRect) const
{
    return viewToContents(convertFromRootView(rootViewRect));
}

FloatRect ScrollView::contentsToRootView(const FloatRect& contentsRect) const
{
    return convertToRootView(contentsToView(contentsRect));
}

FloatQuad ScrollView::rootViewToContents(const FloatQuad& quad) const
{
    // FIXME: This could be optimized by adding and adopting a version of rootViewToContents() that
    // maps multiple FloatPoints to content coordinates at the same time.
    auto result = quad;
    result.setP1(rootViewToContents(result.p1()));
    result.setP2(rootViewToContents(result.p2()));
    result.setP3(rootViewToContents(result.p3()));
    result.setP4(rootViewToContents(result.p4()));
    return result;
}

FloatQuad ScrollView::contentsToRootView(const FloatQuad& quad) const
{
    // FIXME: This could be optimized by adding and adopting a version of contentsToRootView() that
    // maps multiple FloatPoints to root view coordinates at the same time.
    auto result = quad;
    result.setP1(contentsToRootView(result.p1()));
    result.setP2(contentsToRootView(result.p2()));
    result.setP3(contentsToRootView(result.p3()));
    result.setP4(contentsToRootView(result.p4()));
    return result;
}

IntPoint ScrollView::rootViewToTotalContents(const IntPoint& rootViewPoint) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (delegatesScrollingToNativeView())
        return convertFromRootView(rootViewPoint);

    IntPoint viewPoint = convertFromRootView(rootViewPoint);
    // Like rootViewToContents(), but ignores headerHeight.
    auto obscuredContentInsets = this->obscuredContentInsets(InsetType::WebCoreOrPlatformInset);
    return viewPoint + toIntSize(scrollPosition()) - IntSize(obscuredContentInsets.left(), obscuredContentInsets.top());
#else
    return scrollViewRootViewToTotalContents(delegatesScrollingToNativeView(), convertFromRootView(rootViewPoint), scrollPosition(), obscuredContentInsets(InsetType::WebCoreOrPlatformInset));
#endif
}

IntRect ScrollView::contentsToRootView(const IntRect& contentsRect) const
{
    return convertToRootView(contentsToView(contentsRect));
}

// MARK: -

IntPoint ScrollView::windowToContents(IntPoint windowPoint) const
{
    return viewToContents(convertFromContainingWindow(windowPoint));
}

FloatPoint ScrollView::windowToContents(FloatPoint windowPoint) const
{
    return viewToContents(convertFromContainingWindow(windowPoint));
}

DoublePoint ScrollView::windowToContents(DoublePoint windowPoint) const
{
    return viewToContents(convertFromContainingWindow(windowPoint));
}

IntRect ScrollView::windowToContents(const IntRect& windowRect) const
{
    return viewToContents(convertFromContainingWindow(windowRect));
}

FloatRect ScrollView::windowToContents(const FloatRect& windowRect) const
{
    return viewToContents(convertFromContainingWindow(windowRect));
}

// MARK: -

IntPoint ScrollView::contentsToWindow(IntPoint contentsPoint) const
{
    return convertToContainingWindow(contentsToView(contentsPoint));
}

FloatPoint ScrollView::contentsToWindow(FloatPoint contentsPoint) const
{
    return convertToContainingWindow(contentsToView(contentsPoint));
}

IntRect ScrollView::contentsToWindow(const IntRect& contentsRect) const
{
    return convertToContainingWindow(contentsToView(contentsRect));
}

FloatRect ScrollView::contentsToWindow(const FloatRect& contentsRect) const
{
    return convertToContainingWindow(contentsToView(contentsRect));
}

// MARK: -

IntRect ScrollView::contentsToScreen(const IntRect& rect) const
{
    HostWindow* window = hostWindow();
    if (platformWidget())
        return platformContentsToScreen(rect);
    if (!window)
        return IntRect();
    return window->rootViewToScreen(contentsToRootView(rect));
}

IntPoint ScrollView::screenToContents(const IntPoint& point) const
{
    HostWindow* window = hostWindow();
    if (platformWidget())
        return platformScreenToContents(point);
    if (!window)
        return IntPoint();
    return rootViewToContents(window->screenToRootView(point));
}

void ScrollView::setScrollbarsSuppressed(bool suppressed, bool repaintOnUnsuppress)
{
#if !USE_SWIFT_SCROLL_VIEW
    if (suppressed == m_scrollbarsSuppressed)
        return;

    m_scrollbarsSuppressed = suppressed;

    if (platformWidget())
        platformSetScrollbarsSuppressed(repaintOnUnsuppress);
    else if (repaintOnUnsuppress && !suppressed) {
        if (m_horizontalScrollbar)
            protect(m_horizontalScrollbar)->invalidate();
        if (m_verticalScrollbar)
            protect(m_verticalScrollbar)->invalidate();

        // Invalidate the scroll corner too on unsuppress.
        invalidateRect(scrollCornerRect());
    }
#else
    if (!scrollViewSetScrollbarsSuppressedChanges(suppressed, m_scrollbarsSuppressed))
        return;
    scrollViewSetScrollbarsSuppressed(ScrollAnimatorScrollPhysicsClientState(*this).facade(), suppressed, repaintOnUnsuppress);
#endif
}

Scrollbar* ScrollView::scrollbarAtPoint(const IntPoint& windowPoint, ScrollbarHitTestTolerance tolerance)
{
    if (platformWidget())
        return nullptr;

#if !USE_SWIFT_SCROLL_VIEW
    // convertFromContainingWindow doesn't do what it sounds like it does. We need it here just to get this
    // point into the right coordinates if this is the ScrollView of a sub-frame.
    const auto convertedPoint = convertFromContainingWindow(windowPoint);

    if (RefPtr scrollbar = m_horizontalScrollbar; scrollbar && scrollbar->shouldParticipateInHitTesting()) {
        auto hitRect = scrollbar->frameRect();

        if (tolerance == ScrollbarHitTestTolerance::Expanded)
            hitRect.inflateY(scrollbar->expandedHitTestToleranceThreshold());

        if (hitRect.contains(convertedPoint))
            return m_horizontalScrollbar;
    }

    if (RefPtr scrollbar = m_verticalScrollbar; scrollbar && scrollbar->shouldParticipateInHitTesting()) {
        auto hitRect = scrollbar->frameRect();

        if (tolerance == ScrollbarHitTestTolerance::Expanded)
            hitRect.inflateX(scrollbar->expandedHitTestToleranceThreshold());

        if (hitRect.contains(convertedPoint))
            return m_verticalScrollbar;
    }

    return nullptr;
#else
    auto horizontalParticipates = m_horizontalScrollbar && protect(m_horizontalScrollbar)->shouldParticipateInHitTesting();
    auto verticalParticipates = m_verticalScrollbar && protect(m_verticalScrollbar)->shouldParticipateInHitTesting();
    auto orientation = scrollViewScrollbarAtPoint(convertFromContainingWindow(windowPoint), tolerance,
        horizontalParticipates, horizontalParticipates ? m_horizontalScrollbar->frameRect() : IntRect { }, horizontalParticipates ? m_horizontalScrollbar->expandedHitTestToleranceThreshold() : 0,
        verticalParticipates, verticalParticipates ? m_verticalScrollbar->frameRect() : IntRect { }, verticalParticipates ? m_verticalScrollbar->expandedHitTestToleranceThreshold() : 0);
    if (!orientation)
        return nullptr;
    return *orientation == ScrollbarOrientation::Horizontal ? m_horizontalScrollbar.get() : m_verticalScrollbar.get();
#endif
}

IntPoint ScrollView::convertChildToSelf(const Widget* child, IntPoint point) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (!isScrollViewScrollbar(child))
        point -= toIntSize(documentScrollPositionRelativeToViewOrigin());
    point.moveBy(child->location());
    return point;
#else
    return scrollViewConvertChildToSelfIntPoint(isScrollViewScrollbar(child), child->location(), documentScrollPositionRelativeToViewOrigin(), point);
#endif
}

FloatPoint ScrollView::convertChildToSelf(const Widget* child, FloatPoint point) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (!isScrollViewScrollbar(child))
        point -= toFloatSize(documentScrollPositionRelativeToViewOrigin());
    point.moveBy(child->location());
    return point;
#else
    return scrollViewConvertChildToSelfFloatPoint(isScrollViewScrollbar(child), child->location(), documentScrollPositionRelativeToViewOrigin(), point);
#endif
}

DoublePoint ScrollView::convertChildToSelf(const Widget* child, DoublePoint point) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (!isScrollViewScrollbar(child)) {
        FloatSize scrollPosition = toFloatSize(documentScrollPositionRelativeToViewOrigin());
        point.move(-scrollPosition.width(), -scrollPosition.height());
    }
    point.moveBy(child->location());
    return point;
#else
    return scrollViewConvertChildToSelfDoublePoint(isScrollViewScrollbar(child), child->location(), documentScrollPositionRelativeToViewOrigin(), point);
#endif
}

IntPoint ScrollView::convertSelfToChild(const Widget* child, IntPoint point) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (!isScrollViewScrollbar(child))
        point += toIntSize(documentScrollPositionRelativeToViewOrigin());
    point.moveBy(-child->location());
    return point;
#else
    return scrollViewConvertSelfToChildIntPoint(isScrollViewScrollbar(child), child->location(), documentScrollPositionRelativeToViewOrigin(), point);
#endif
}

FloatPoint ScrollView::convertSelfToChild(const Widget* child, FloatPoint point) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (!isScrollViewScrollbar(child))
        point += toIntSize(documentScrollPositionRelativeToViewOrigin());
    point.moveBy(-child->location());
    return point;
#else
    return scrollViewConvertSelfToChildFloatPoint(isScrollViewScrollbar(child), child->location(), documentScrollPositionRelativeToViewOrigin(), point);
#endif
}

DoublePoint ScrollView::convertSelfToChild(const Widget* child, DoublePoint point) const
{
#if !USE_SWIFT_SCROLL_VIEW
    if (!isScrollViewScrollbar(child))
        point.move(toIntSize(documentScrollPositionRelativeToViewOrigin()));
    point.moveBy(-child->location());
    return point;
#else
    return scrollViewConvertSelfToChildDoublePoint(isScrollViewScrollbar(child), child->location(), documentScrollPositionRelativeToViewOrigin(), point);
#endif
}

void ScrollView::setScrollbarOverlayStyle(ScrollbarOverlayStyle overlayStyle)
{
    ScrollableArea::setScrollbarOverlayStyle(overlayStyle);
    platformSetScrollbarOverlayStyle(overlayStyle);
}

void ScrollView::setFrameRect(const IntRect& newRect)
{
    Ref<ScrollView> protectedThis(*this);
    IntRect oldRect = frameRect();
    
    if (newRect == oldRect)
        return;

    Widget::setFrameRect(newRect);
    frameRectsChanged();

    if (oldRect.size() == newRect.size())
        return;

    if (!m_useFixedLayout)
        availableContentSizeChanged(AvailableSizeChangeReason::AreaSizeChanged);
    else
        updateScrollbars(scrollPosition());
}

void ScrollView::frameRectsChanged()
{
    if (platformWidget())
        return;
    for (auto& child : m_children)
        child->frameRectsChanged();
}

void ScrollView::clipRectChanged()
{
    for (auto& child : m_children)
        child->clipRectChanged();
}

static void positionScrollbarLayer(GraphicsLayer* graphicsLayer, Scrollbar* scrollbar)
{
    if (!graphicsLayer || !scrollbar)
        return;

    IntRect scrollbarRect = scrollbar->frameRect();
    graphicsLayer->setPosition(scrollbarRect.location());

    if (scrollbarRect.size() == graphicsLayer->size())
        return;

    graphicsLayer->setSize(scrollbarRect.size());

    if (graphicsLayer->usesContentsLayer()) {
        graphicsLayer->setContentsRect(IntRect(0, 0, scrollbarRect.width(), scrollbarRect.height()));
        return;
    }

    graphicsLayer->setDrawsContent(true);
    graphicsLayer->setNeedsDisplay();
}

static void positionScrollCornerLayer(GraphicsLayer* graphicsLayer, const IntRect& cornerRect)
{
    if (!graphicsLayer)
        return;
    graphicsLayer->setDrawsContent(!cornerRect.isEmpty());
    graphicsLayer->setPosition(cornerRect.location());
    if (cornerRect.size() != graphicsLayer->size())
        graphicsLayer->setNeedsDisplay();
    graphicsLayer->setSize(cornerRect.size());
}

void ScrollView::positionScrollbarLayers()
{
    positionScrollbarLayer(protect(layerForHorizontalScrollbar()), protect(horizontalScrollbar()));
    positionScrollbarLayer(protect(layerForVerticalScrollbar()), protect(verticalScrollbar()));
    positionScrollCornerLayer(protect(layerForScrollCorner()), scrollCornerRect());
}

void ScrollView::repaintContentRectangle(const IntRect& rect)
{
    IntRect paintRect = rect;
    if (!paintsEntireContents())
        paintRect.intersect(visibleContentRect(LegacyIOSDocumentVisibleRect));
    if (paintRect.isEmpty())
        return;

    if (platformWidget()) {
        platformRepaintContentRectangle(paintRect);
        return;
    }

    if (HostWindow* window = hostWindow())
        window->invalidateContentsAndRootView(contentsToWindow(paintRect));
}

IntRect ScrollView::scrollCornerRect() const
{
#if !USE_SWIFT_SCROLL_VIEW
    IntRect cornerRect;

    if (hasOverlayScrollbars())
        return cornerRect;

    if (!m_horizontalScrollbar || !m_verticalScrollbar)
        return cornerRect;

    cornerRect = IntRect(
        protect(m_verticalScrollbar)->x(),
        protect(m_horizontalScrollbar)->y(),
        protect(m_verticalScrollbar)->width(),
        protect(m_horizontalScrollbar)->height());

    return cornerRect;
#else
    return scrollViewScrollCornerRect(hasOverlayScrollbars(), m_horizontalScrollbar, m_horizontalScrollbar ? m_horizontalScrollbar->frameRect() : IntRect { }, m_verticalScrollbar, m_verticalScrollbar ? m_verticalScrollbar->frameRect() : IntRect { });
#endif
}

bool ScrollView::isScrollCornerVisible() const
{
    return !scrollCornerRect().isEmpty();
}

void ScrollView::scrollbarStyleChanged(ScrollbarStyle newStyle, bool forceUpdate)
{
    ScrollableArea::scrollbarStyleChanged(newStyle, forceUpdate);
    if (!forceUpdate)
        return;

    updateScrollbars(scrollPosition());
    positionScrollbarLayers();
}

void ScrollView::paintScrollCorner(GraphicsContext& context, const IntRect& cornerRect)
{
    ScrollbarTheme::theme().paintScrollCorner(*this, context, cornerRect);
}

void ScrollView::paintScrollbar(GraphicsContext& context, Scrollbar& bar, const IntRect& rect)
{
    bar.paint(context, rect);
}

void ScrollView::invalidateScrollCornerRect(const IntRect& rect)
{
    invalidateRect(rect);
}

void ScrollView::paintScrollbars(GraphicsContext& context, const IntRect& rect)
{
    if (m_horizontalScrollbar && !layerForHorizontalScrollbar())
        paintScrollbar(context, *m_horizontalScrollbar.get(), rect);
    if (m_verticalScrollbar && !layerForVerticalScrollbar())
        paintScrollbar(context, *m_verticalScrollbar.get(), rect);

    if (layerForScrollCorner())
        return;

    paintScrollCorner(context, scrollCornerRect());
}

void ScrollView::paintPanScrollIcon(GraphicsContext& context)
{
    static NeverDestroyed<RefPtr<NativeImage>> panScrollIcon = NativeImage::createFromPlatformResource("panIcon"_s);
    RefPtr icon = panScrollIcon.get();
    if (!icon)
        return;

    IntPoint iconGCPoint = m_panScrollIconPoint;
    if (parent())
        iconGCPoint = protect(parent())->windowToContents(iconGCPoint);

    context.drawNativeImage(*icon, iconGCPoint);
}

void ScrollView::paint(GraphicsContext& context, const IntRect& rect, SecurityOriginPaintPolicy securityOriginPaintPolicy, RegionContext* regionContext)
{
    if (platformWidget()) {
        Widget::paint(context, rect);
        return;
    }

    if (context.paintingDisabled() && !context.performingPaintInvalidation() && !regionContext)
        return;

    IntRect documentDirtyRect = rect;
    if (!paintsEntireContents()) {
        IntRect visibleAreaWithoutScrollbars(locationOfContents(), visibleContentRect(LegacyIOSDocumentVisibleRect).size());
        documentDirtyRect.intersect(visibleAreaWithoutScrollbars);
    }

    if (!documentDirtyRect.isEmpty()) {
        GraphicsContextStateSaver stateSaver(context);

        IntPoint locationOfContents = this->locationOfContents();
        context.translate(locationOfContents.x(), locationOfContents.y());
        documentDirtyRect.moveBy(-locationOfContents);

        if (!paintsEntireContents()) {
            context.translate(-scrollX(), -scrollY());
            documentDirtyRect.moveBy(scrollPosition());

            context.clip(visibleContentRect(LegacyIOSDocumentVisibleRect));
        }

        paintContents(context, documentDirtyRect, securityOriginPaintPolicy, regionContext);
    }

#if HAVE(RUBBER_BANDING)
    if (!layerForOverhangAreas())
        calculateAndPaintOverhangAreas(context, rect);
#else
    calculateAndPaintOverhangAreas(context, rect);
#endif

    // Now paint the scrollbars.
    if (!m_scrollbarsSuppressed && (m_horizontalScrollbar || m_verticalScrollbar)) {
        GraphicsContextStateSaver stateSaver(context);
        IntRect scrollViewDirtyRect = rect;
        IntRect visibleAreaWithScrollbars(location(), unobscuredContentRectIncludingScrollbars().size());
        scrollViewDirtyRect.intersect(visibleAreaWithScrollbars);
        context.translate(x(), y());
        scrollViewDirtyRect.moveBy(-location());
        context.clip(IntRect(IntPoint(), visibleAreaWithScrollbars.size()));

        paintScrollbars(context, scrollViewDirtyRect);
    }

    // Paint the panScroll Icon
    if (m_drawPanScrollIcon)
        paintPanScrollIcon(context);

    if (auto* axRegionContext = dynamicDowncast<AccessibilityRegionContext>(regionContext))
        axRegionContext->onPaint(*this);
}

void ScrollView::calculateOverhangAreasForPainting(IntRect& horizontalOverhangRect, IntRect& verticalOverhangRect)
{
#if !USE_SWIFT_SCROLL_VIEW
    IntSize scrollbarSpace = scrollbarIntrusion();

    // FIXME: use maximumScrollOffset().
    ScrollOffset scrollOffset = scrollOffsetFromPosition(scrollPosition());
    if (scrollOffset.y() < 0) {
        horizontalOverhangRect = frameRect();
        horizontalOverhangRect.setHeight(-scrollOffset.y());
        horizontalOverhangRect.setWidth(horizontalOverhangRect.width() - scrollbarSpace.width());
    } else if (totalContentsSize().height() && scrollOffset.y() > totalContentsSize().height() - visibleHeight()) {
        int height = scrollOffset.y() - (totalContentsSize().height() - visibleHeight());
        horizontalOverhangRect = frameRect();
        horizontalOverhangRect.setY(frameRect().maxY() - height - scrollbarSpace.height());
        horizontalOverhangRect.setHeight(height);
        horizontalOverhangRect.setWidth(horizontalOverhangRect.width() - scrollbarSpace.width());
    }

    if (scrollOffset.x() < 0) {
        verticalOverhangRect.setWidth(-scrollOffset.x());
        verticalOverhangRect.setHeight(frameRect().height() - horizontalOverhangRect.height() - scrollbarSpace.height());
        verticalOverhangRect.setX(frameRect().x());
        if (horizontalOverhangRect.y() == frameRect().y())
            verticalOverhangRect.setY(frameRect().y() + horizontalOverhangRect.height());
        else
            verticalOverhangRect.setY(frameRect().y());
    } else if (contentsWidth() && scrollOffset.x() > contentsWidth() - visibleWidth()) {
        int width = scrollOffset.x() - (contentsWidth() - visibleWidth());
        verticalOverhangRect.setWidth(width);
        verticalOverhangRect.setHeight(frameRect().height() - horizontalOverhangRect.height() - scrollbarSpace.height());
        verticalOverhangRect.setX(frameRect().maxX() - width - scrollbarSpace.width());
        if (horizontalOverhangRect.y() == frameRect().y())
            verticalOverhangRect.setY(frameRect().y() + horizontalOverhangRect.height());
        else
            verticalOverhangRect.setY(frameRect().y());
    }
#else
    scrollViewCalculateOverhangAreas(scrollbarIntrusion(), scrollOffsetFromPosition(scrollPosition()), frameRect(), totalContentsSize(), visibleSize(), contentsWidth(), horizontalOverhangRect, verticalOverhangRect);
#endif
}

void ScrollView::updateOverhangAreas()
{
#if !USE_SWIFT_SCROLL_VIEW
    HostWindow* window = hostWindow();
    if (!window)
        return;

    IntRect horizontalOverhangRect;
    IntRect verticalOverhangRect;
    calculateOverhangAreasForPainting(horizontalOverhangRect, verticalOverhangRect);
    if (!horizontalOverhangRect.isEmpty())
        window->invalidateContentsAndRootView(horizontalOverhangRect);
    if (!verticalOverhangRect.isEmpty())
        window->invalidateContentsAndRootView(verticalOverhangRect);
#else
    scrollViewUpdateOverhangAreas(ScrollAnimatorScrollPhysicsClientState(*this).facade());
#endif
}

void ScrollView::paintOverhangAreas(GraphicsContext& context, const IntRect& horizontalOverhangRect, const IntRect& verticalOverhangRect, const IntRect& dirtyRect)
{
    ScrollbarTheme::theme().paintOverhangAreas(*this, context, horizontalOverhangRect, verticalOverhangRect, dirtyRect);
}

void ScrollView::calculateAndPaintOverhangAreas(GraphicsContext& context, const IntRect& dirtyRect)
{
    IntRect horizontalOverhangRect;
    IntRect verticalOverhangRect;
    calculateOverhangAreasForPainting(horizontalOverhangRect, verticalOverhangRect);

    if (dirtyRect.intersects(horizontalOverhangRect) || dirtyRect.intersects(verticalOverhangRect))
        paintOverhangAreas(context, horizontalOverhangRect, verticalOverhangRect, dirtyRect);
}

bool ScrollView::isPointInScrollbarCorner(const IntPoint& windowPoint)
{
#if !USE_SWIFT_SCROLL_VIEW
    if (!scrollbarCornerPresent())
        return false;

    IntPoint viewPoint = convertFromContainingWindow(windowPoint);

    if (m_horizontalScrollbar) {
        Ref horizontalScrollbar = *m_horizontalScrollbar;
        int horizontalScrollbarYMin = horizontalScrollbar->frameRect().y();
        int horizontalScrollbarYMax = horizontalScrollbar->frameRect().y() + horizontalScrollbar->frameRect().height();
        int horizontalScrollbarXMin = horizontalScrollbar->frameRect().x() + horizontalScrollbar->frameRect().width();

        return viewPoint.y() > horizontalScrollbarYMin && viewPoint.y() < horizontalScrollbarYMax && viewPoint.x() > horizontalScrollbarXMin;
    }

    Ref verticalScrollbar = *m_verticalScrollbar;
    int verticalScrollbarXMin = verticalScrollbar->frameRect().x();
    int verticalScrollbarXMax = verticalScrollbar->frameRect().x() + verticalScrollbar->frameRect().width();
    int verticalScrollbarYMin = verticalScrollbar->frameRect().y() + verticalScrollbar->frameRect().height();
    
    return viewPoint.x() > verticalScrollbarXMin && viewPoint.x() < verticalScrollbarXMax && viewPoint.y() > verticalScrollbarYMin;
#else
    return scrollViewIsPointInScrollbarCorner(width(), height(), m_horizontalScrollbar, m_horizontalScrollbar ? m_horizontalScrollbar->frameRect() : IntRect { }, m_verticalScrollbar, m_verticalScrollbar ? m_verticalScrollbar->frameRect() : IntRect { }, convertFromContainingWindow(windowPoint));
#endif
}

bool ScrollView::scrollbarCornerPresent() const
{
#if !USE_SWIFT_SCROLL_VIEW
    return (m_horizontalScrollbar && width() - protect(m_horizontalScrollbar)->width() > 0)
        || (m_verticalScrollbar && height() - protect(m_verticalScrollbar)->height() > 0);
#else
    return scrollViewScrollbarCornerPresent(width(), height(), m_horizontalScrollbar, m_horizontalScrollbar ? m_horizontalScrollbar->frameRect() : IntRect { }, m_verticalScrollbar, m_verticalScrollbar ? m_verticalScrollbar->frameRect() : IntRect { });
#endif
}

IntRect ScrollView::convertFromScrollbarToContainingView(const Scrollbar& scrollbar, const IntRect& localRect) const
{
#if !USE_SWIFT_SCROLL_VIEW
    // Scrollbars won't be transformed within us
    IntRect newRect = localRect;
    newRect.moveBy(scrollbar.location());
    return newRect;
#else
    return scrollViewConvertFromScrollbarToContainingViewIntRect(scrollbar.location(), localRect);
#endif
}

IntRect ScrollView::convertFromContainingViewToScrollbar(const Scrollbar& scrollbar, const IntRect& parentRect) const
{
#if !USE_SWIFT_SCROLL_VIEW
    IntRect newRect = parentRect;
    // Scrollbars won't be transformed within us
    newRect.moveBy(-scrollbar.location());
    return newRect;
#else
    return scrollViewConvertFromContainingViewToScrollbarIntRect(scrollbar.location(), parentRect);
#endif
}

// FIXME: test these on windows
IntPoint ScrollView::convertFromScrollbarToContainingView(const Scrollbar& scrollbar, const IntPoint& localPoint) const
{
#if !USE_SWIFT_SCROLL_VIEW
    // Scrollbars won't be transformed within us
    IntPoint newPoint = localPoint;
    newPoint.moveBy(scrollbar.location());
    return newPoint;
#else
    return scrollViewConvertFromScrollbarToContainingViewIntPoint(scrollbar.location(), localPoint);
#endif
}

IntPoint ScrollView::convertFromContainingViewToScrollbar(const Scrollbar& scrollbar, const IntPoint& parentPoint) const
{
#if !USE_SWIFT_SCROLL_VIEW
    IntPoint newPoint = parentPoint;
    // Scrollbars won't be transformed within us
    newPoint.moveBy(-scrollbar.location());
    return newPoint;
#else
    return scrollViewConvertFromContainingViewToScrollbarIntPoint(scrollbar.location(), parentPoint);
#endif
}

void ScrollView::setParentVisible(bool visible)
{
    if (isParentVisible() == visible)
        return;
    
    Widget::setParentVisible(visible);

    if (!isSelfVisible())
        return;
        
    for (auto& child : m_children)
        child->setParentVisible(visible);
}

void ScrollView::show()
{
    if (!isSelfVisible()) {
        setSelfVisible(true);
        if (isParentVisible()) {
            for (auto& child : m_children)
                child->setParentVisible(true);
        }
    }

    Widget::show();
}

void ScrollView::hide()
{
    if (isSelfVisible()) {
        if (isParentVisible()) {
            for (auto& child : m_children)
                child->setParentVisible(false);
        }
        setSelfVisible(false);
    }

    Widget::hide();
}

bool ScrollView::isOffscreen() const
{
    if (platformWidget())
        return platformIsOffscreen();
    
    if (!isVisible())
        return true;
    
    // FIXME: Add a HostWindow::isOffscreen method here.  Since only Mac implements this method
    // currently, we can add the method when the other platforms decide to implement this concept.
    return false;
}


void ScrollView::addPanScrollIcon(const IntPoint& iconPosition)
{
    HostWindow* window = hostWindow();
    if (!window)
        return;
    m_drawPanScrollIcon = true;    
    m_panScrollIconPoint = IntPoint(iconPosition.x() - panIconSizeLength / 2 , iconPosition.y() - panIconSizeLength / 2) ;
    window->invalidateContentsAndRootView(IntRect(m_panScrollIconPoint, IntSize(panIconSizeLength, panIconSizeLength)));
}

void ScrollView::removePanScrollIcon()
{
    HostWindow* window = hostWindow();
    if (!window)
        return;
    m_drawPanScrollIcon = false; 
    window->invalidateContentsAndRootView(IntRect(m_panScrollIconPoint, IntSize(panIconSizeLength, panIconSizeLength)));
}

void ScrollView::setScrollOrigin(const IntPoint& origin, bool updatePositionAtAll, bool updatePositionSynchronously)
{
#if !USE_SWIFT_SCROLL_VIEW
    if (scrollOrigin() == origin)
        return;

    ScrollableArea::setScrollOrigin(origin);

    if (platformWidget()) {
        platformSetScrollOrigin(origin, updatePositionAtAll, updatePositionSynchronously);
        return;
    }
    
    // Update if the scroll origin changes, since our position will be different if the content size did not change.
    if (updatePositionAtAll && updatePositionSynchronously)
        updateScrollbars(scrollPosition());
#else
    if (!scrollViewSetScrollOriginChanges(scrollOrigin(), origin))
        return;
    scrollViewSetScrollOrigin(ScrollAnimatorScrollPhysicsClientState(*this).facade(), origin, updatePositionAtAll, updatePositionSynchronously);
#endif
}

void ScrollView::styleAndRenderTreeDidChange()
{
    if (m_horizontalScrollbar)
        protect(m_horizontalScrollbar)->styleChanged();

    if (m_verticalScrollbar)
        protect(m_verticalScrollbar)->styleChanged();
}

IntPoint ScrollView::locationOfContents() const
{
    IntPoint result = location();
    result.move(insetForLeftScrollbarSpace(), 0);
    return result;
}

std::unique_ptr<ScrollView::ProhibitScrollingWhenChangingContentSizeForScope> ScrollView::prohibitScrollingWhenChangingContentSizeForScope()
{
    return makeUnique<ProhibitScrollingWhenChangingContentSizeForScope>(*this);
}

ScrollView::ProhibitScrollingWhenChangingContentSizeForScope::ProhibitScrollingWhenChangingContentSizeForScope(ScrollView& scrollView)
    : m_scrollView(scrollView)
    , m_anchoringSuppressor(scrollView)
{
    scrollView.incrementProhibitsScrollingWhenChangingContentSizeCount();
}

ScrollView::ProhibitScrollingWhenChangingContentSizeForScope::~ProhibitScrollingWhenChangingContentSizeForScope()
{
    if (m_scrollView)
        protect(m_scrollView)->decrementProhibitsScrollingWhenChangingContentSizeCount();
}

String ScrollView::debugDescription() const
{
    return makeString("ScrollView 0x"_s, hex(reinterpret_cast<uintptr_t>(this), Lowercase));
}

#if !PLATFORM(COCOA)

void ScrollView::platformAddChild(Widget*)
{
}

void ScrollView::platformRemoveChild(Widget*)
{
}

void ScrollView::platformSetScrollbarsSuppressed(bool)
{
}

void ScrollView::platformSetScrollOrigin(const IntPoint&, bool, bool)
{
}

void ScrollView::platformSetScrollbarOverlayStyle(ScrollbarOverlayStyle)
{
}

void ScrollView::platformSetScrollbarModes()
{
}

void ScrollView::platformScrollbarModes(ScrollbarMode& horizontal, ScrollbarMode& vertical) const
{
    horizontal = ScrollbarMode::Auto;
    vertical = ScrollbarMode::Auto;
}

void ScrollView::platformSetCanBlitOnScroll(bool)
{
}

bool ScrollView::platformCanBlitOnScroll() const
{
    return false;
}

IntRect ScrollView::platformVisibleContentRect(bool) const
{
    return { };
}

FloatBoxExtent ScrollView::platformContentInsets() const
{
    return { };
}

void ScrollView::platformSetContentInsets(const FloatBoxExtent&)
{
}

IntSize ScrollView::platformVisibleContentSize(bool) const
{
    return { };
}

IntRect ScrollView::platformVisibleContentRectIncludingObscuredArea(bool) const
{
    return { };
}

IntSize ScrollView::platformVisibleContentSizeIncludingObscuredArea(bool) const
{
    return { };
}

IntRect ScrollView::platformUnobscuredContentRect(VisibleContentRectIncludesScrollbars) const
{
    return { };
}

FloatRect ScrollView::platformExposedContentRect() const
{
    return { };
}

void ScrollView::platformSetContentsSize()
{
}

IntRect ScrollView::platformContentsToScreen(const IntRect& rect) const
{
    return rect;
}

IntPoint ScrollView::platformScreenToContents(const IntPoint& point) const
{
    return point;
}

void ScrollView::platformSetScrollPosition(const IntPoint&)
{
}

bool ScrollView::platformScroll(ScrollDirection, ScrollGranularity)
{
    return true;
}

void ScrollView::platformRepaintContentRectangle(const IntRect&)
{
}

bool ScrollView::platformIsOffscreen() const
{
    return false;
}

#endif // !PLATFORM(COCOA)

}
