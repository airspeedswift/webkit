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

#include "ScrollAnimatorScrollPhysicsClient.h"
#include "WebCore-Swift.h"

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollView);
WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollView::ProhibitScrollingWhenChangingContentSizeForScope);

bool ScrollAnimatorScrollPhysicsClient::hasPlatformWidget()
{
    return !!scrollView().platformWidget();
}

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
    UNUSED_PARAM(scrollbar);
    bool ignored = false;
    return scrollViewSetHasScrollbar(ScrollAnimatorScrollPhysicsClientState(*this).facade(), orientation, hasBar, contentSizeAffected ? *contentSizeAffected : ignored);
}

Ref<Scrollbar> ScrollView::createScrollbar(ScrollbarOrientation orientation)
{
    return Scrollbar::createNativeScrollbar(*this, orientation, ScrollbarWidth::Auto);
}

void ScrollView::setScrollbarModes(ScrollbarMode horizontalMode, ScrollbarMode verticalMode,
                                   bool horizontalLock, bool verticalLock)
{
    auto currentHorizontalMode = horizontalScrollbarMode();
    auto currentVerticalMode = verticalScrollbarMode();
    if (!scrollViewSetScrollbarModesChangesAnything(horizontalMode, currentHorizontalMode, m_horizontalScrollbarLock, horizontalLock, verticalMode, currentVerticalMode, m_verticalScrollbarLock, verticalLock))
        return;
    scrollViewSetScrollbarModes(ScrollAnimatorScrollPhysicsClientState(*this).facade(), horizontalMode, currentHorizontalMode, m_horizontalScrollbarLock, horizontalLock, verticalMode, currentVerticalMode, m_verticalScrollbarLock, verticalLock);
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
    setScrollbarModes(scrollViewCanHaveScrollbarsMode(canScroll, horizontalScrollbarMode()), scrollViewCanHaveScrollbarsMode(canScroll, verticalScrollbarMode()));
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
    scrollViewAdjustExposedContentRect(ScrollAnimatorScrollPhysicsClientState(*this).facade(), newPosition);
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
    return scrollViewUnobscuredContentRect(sizeForUnobscuredContent(scrollbarInclusion), visibleContentScaleFactor(), m_scrollPosition);
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

    return scrollViewSizeForUnobscuredContent(sizeForVisibleContent(scrollbarInclusion), obscuredContentInsets());
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
    return scrollViewDocumentScrollPositionRelativeToViewOrigin(scrollPosition(), viewToContentsInsetOffset());
}

ScrollPosition ScrollView::documentScrollPositionRelativeToScrollableAreaOrigin() const
{
    return scrollPosition() - IntSize(0, headerHeight());
}

void ScrollView::setScrollOffset(const ScrollOffset& offset)
{
    bool clamped = scrollClamping() == ScrollClamping::Clamped;
    auto totalContentsSize = clamped ? this->totalContentsSize() : IntSize { };
    auto visibleSize = clamped ? this->visibleSize() : IntSize { };
    scrollTo(scrollViewScrollOffsetTarget(offset, clamped, totalContentsSize, visibleSize, scrollOrigin()));
}

void ScrollView::scrollOffsetChangedViaPlatformWidget(const ScrollOffset& oldOffset, const ScrollOffset& newOffset)
{
    scrollViewScrollOffsetChangedViaPlatformWidget(ScrollAnimatorScrollPhysicsClientState(*this).facade(), oldOffset, newOffset);
}

void ScrollView::handleDeferredScrollUpdateAfterContentSizeChange()
{
    scrollViewHandleDeferredScrollUpdate(ScrollAnimatorScrollPhysicsClientState(*this).facade());
}

void ScrollView::scrollTo(const ScrollPosition& newPosition)
{
    if (!scrollViewScrollToMoves(m_scrollPosition, newPosition))
        return;
    scrollViewScrollTo(ScrollAnimatorScrollPhysicsClientState(*this).facade(), newPosition);
}

void ScrollView::setScrollPosition(const ScrollPosition& scrollPosition, const ScrollPositionChangeOptions& options)
{
    if (!scrollViewSetScrollPositionProceeds(prohibitsScrolling()))
        return;
    scrollViewSetScrollPosition(ScrollAnimatorScrollPhysicsClientState(*this).facade(), scrollPosition, options.type, options.clamping, options.animated, options.snapPointSelectionMethod, options.originalScrollDelta.has_value(), options.originalScrollDelta.value_or(FloatSize { }), options.interruptsAnimation, options.animationCurve);
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
    return scrollViewOverhangAmount(scrollOffset(), totalContentsSize(), visibleSize(), contentsWidth());
}

bool ScrollView::managesScrollbars() const
{
#if PLATFORM(IOS_FAMILY)
    // FIXME: We should be able to remove this. iOS should always hit the DelegatedToNativeScrollView condition below.
    return false;
#else
    return scrollViewManagesScrollbars(!!platformWidget(), delegatedScrollingMode());
#endif
}

void ScrollView::updateScrollbars(const ScrollPosition& desiredPosition)
{
    scrollViewUpdateScrollbars(ScrollAnimatorScrollPhysicsClientState(*this).facade(), desiredPosition);
}

void ScrollView::updateScrollbarSteps()
{
    scrollViewUpdateScrollbarSteps(ScrollAnimatorScrollPhysicsClientState(*this).facade());
}

const int panIconSizeLength = 16;
// ScrollView.swift uses the same size.
static_assert(panIconSizeLength == 16);

void ScrollView::scrollContents(const IntSize& scrollDelta)
{
    scrollViewScrollContents(ScrollAnimatorScrollPhysicsClientState(*this).facade(), scrollDelta);
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
    return scrollViewViewToContentsIntPoint(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), point);
}

IntPoint ScrollView::contentsToView(const IntPoint& point) const
{
    return scrollViewContentsToViewIntPoint(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), point);
}

FloatPoint ScrollView::viewToContents(const FloatPoint& point) const
{
    return scrollViewViewToContentsFloatPoint(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), point);
}

DoublePoint ScrollView::viewToContents(const DoublePoint& point) const
{
    return scrollViewViewToContentsDoublePoint(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), point);
}

FloatPoint ScrollView::contentsToView(const FloatPoint& point) const
{
    return scrollViewContentsToViewFloatPoint(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), point);
}

DoublePoint ScrollView::contentsToView(const DoublePoint& point) const
{
    return scrollViewContentsToViewDoublePoint(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), point);
}

IntRect ScrollView::viewToContents(IntRect rect) const
{
    return scrollViewViewToContentsIntRect(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), rect);
}

FloatRect ScrollView::viewToContents(FloatRect rect) const
{
    return scrollViewViewToContentsFloatRect(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), rect);
}

IntRect ScrollView::contentsToView(IntRect rect) const
{
    return scrollViewContentsToViewIntRect(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), rect);
}

FloatRect ScrollView::contentsToView(FloatRect rect) const
{
    return scrollViewContentsToViewFloatRect(delegatesScrollingToNativeView(), visibleContentScaleFactor(), scrollPosition(), viewToContentsInsetOffset(), rect);
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
    return scrollViewRootViewToTotalContents(delegatesScrollingToNativeView(), convertFromRootView(rootViewPoint), scrollPosition(), obscuredContentInsets(InsetType::WebCoreOrPlatformInset));
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
    if (!scrollViewSetScrollbarsSuppressedChanges(suppressed, m_scrollbarsSuppressed))
        return;
    scrollViewSetScrollbarsSuppressed(ScrollAnimatorScrollPhysicsClientState(*this).facade(), suppressed, repaintOnUnsuppress);
}

Scrollbar* ScrollView::scrollbarAtPoint(const IntPoint& windowPoint, ScrollbarHitTestTolerance tolerance)
{
    if (platformWidget())
        return nullptr;

    auto horizontalParticipates = m_horizontalScrollbar && protect(m_horizontalScrollbar)->shouldParticipateInHitTesting();
    auto verticalParticipates = m_verticalScrollbar && protect(m_verticalScrollbar)->shouldParticipateInHitTesting();
    auto orientation = scrollViewScrollbarAtPoint(convertFromContainingWindow(windowPoint), tolerance,
        horizontalParticipates, horizontalParticipates ? m_horizontalScrollbar->frameRect() : IntRect { }, horizontalParticipates ? m_horizontalScrollbar->expandedHitTestToleranceThreshold() : 0,
        verticalParticipates, verticalParticipates ? m_verticalScrollbar->frameRect() : IntRect { }, verticalParticipates ? m_verticalScrollbar->expandedHitTestToleranceThreshold() : 0);
    if (!orientation)
        return nullptr;
    return *orientation == ScrollbarOrientation::Horizontal ? m_horizontalScrollbar.get() : m_verticalScrollbar.get();
}

IntPoint ScrollView::convertChildToSelf(const Widget* child, IntPoint point) const
{
    return scrollViewConvertChildToSelfIntPoint(isScrollViewScrollbar(child), child->location(), documentScrollPositionRelativeToViewOrigin(), point);
}

FloatPoint ScrollView::convertChildToSelf(const Widget* child, FloatPoint point) const
{
    return scrollViewConvertChildToSelfFloatPoint(isScrollViewScrollbar(child), child->location(), documentScrollPositionRelativeToViewOrigin(), point);
}

DoublePoint ScrollView::convertChildToSelf(const Widget* child, DoublePoint point) const
{
    return scrollViewConvertChildToSelfDoublePoint(isScrollViewScrollbar(child), child->location(), documentScrollPositionRelativeToViewOrigin(), point);
}

IntPoint ScrollView::convertSelfToChild(const Widget* child, IntPoint point) const
{
    return scrollViewConvertSelfToChildIntPoint(isScrollViewScrollbar(child), child->location(), documentScrollPositionRelativeToViewOrigin(), point);
}

FloatPoint ScrollView::convertSelfToChild(const Widget* child, FloatPoint point) const
{
    return scrollViewConvertSelfToChildFloatPoint(isScrollViewScrollbar(child), child->location(), documentScrollPositionRelativeToViewOrigin(), point);
}

DoublePoint ScrollView::convertSelfToChild(const Widget* child, DoublePoint point) const
{
    return scrollViewConvertSelfToChildDoublePoint(isScrollViewScrollbar(child), child->location(), documentScrollPositionRelativeToViewOrigin(), point);
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
    return scrollViewScrollCornerRect(hasOverlayScrollbars(), m_horizontalScrollbar, m_horizontalScrollbar ? m_horizontalScrollbar->frameRect() : IntRect { }, m_verticalScrollbar, m_verticalScrollbar ? m_verticalScrollbar->frameRect() : IntRect { });
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
    scrollViewCalculateOverhangAreas(scrollbarIntrusion(), scrollOffsetFromPosition(scrollPosition()), frameRect(), totalContentsSize(), visibleSize(), contentsWidth(), horizontalOverhangRect, verticalOverhangRect);
}

void ScrollView::updateOverhangAreas()
{
    scrollViewUpdateOverhangAreas(ScrollAnimatorScrollPhysicsClientState(*this).facade());
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
    return scrollViewIsPointInScrollbarCorner(width(), height(), m_horizontalScrollbar, m_horizontalScrollbar ? m_horizontalScrollbar->frameRect() : IntRect { }, m_verticalScrollbar, m_verticalScrollbar ? m_verticalScrollbar->frameRect() : IntRect { }, convertFromContainingWindow(windowPoint));
}

bool ScrollView::scrollbarCornerPresent() const
{
    return scrollViewScrollbarCornerPresent(width(), height(), m_horizontalScrollbar, m_horizontalScrollbar ? m_horizontalScrollbar->frameRect() : IntRect { }, m_verticalScrollbar, m_verticalScrollbar ? m_verticalScrollbar->frameRect() : IntRect { });
}

IntRect ScrollView::convertFromScrollbarToContainingView(const Scrollbar& scrollbar, const IntRect& localRect) const
{
    return scrollViewConvertFromScrollbarToContainingViewIntRect(scrollbar.location(), localRect);
}

IntRect ScrollView::convertFromContainingViewToScrollbar(const Scrollbar& scrollbar, const IntRect& parentRect) const
{
    return scrollViewConvertFromContainingViewToScrollbarIntRect(scrollbar.location(), parentRect);
}

// FIXME: test these on windows
IntPoint ScrollView::convertFromScrollbarToContainingView(const Scrollbar& scrollbar, const IntPoint& localPoint) const
{
    return scrollViewConvertFromScrollbarToContainingViewIntPoint(scrollbar.location(), localPoint);
}

IntPoint ScrollView::convertFromContainingViewToScrollbar(const Scrollbar& scrollbar, const IntPoint& parentPoint) const
{
    return scrollViewConvertFromContainingViewToScrollbarIntPoint(scrollbar.location(), parentPoint);
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
    if (!scrollViewSetScrollOriginChanges(scrollOrigin(), origin))
        return;
    scrollViewSetScrollOrigin(ScrollAnimatorScrollPhysicsClientState(*this).facade(), origin, updatePositionAtAll, updatePositionSynchronously);
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
