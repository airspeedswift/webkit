/*
 * Copyright (c) 2010-2023 Google Inc. All rights reserved.
 * Copyright (C) 2008-2026 Apple Inc. All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 * 
 *     * Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above
 * copyright notice, this list of conditions and the following disclaimer
 * in the documentation and/or other materials provided with the
 * distribution.
 *     * Neither the name of Google Inc. nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "ScrollableArea.h"

#include "Chrome.h"
#include "ChromeClient.h"
#include "FloatPoint.h"
#include "GraphicsContext.h"
#include "GraphicsLayer.h"
#include "LayoutRect.h"
#include "Logging.h"
#include "PlatformWheelEvent.h"
#include "ScrollAnchoringController.h"
#include "ScrollAnimator.h"
#include "ScrollbarTheme.h"
#include "ScrollbarsControllerMock.h"
#include "StyleScrollbarGutter.h"
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>

#include "ScrollAnimatorScrollPhysicsClient.h"
#include "WebCore-Swift.h"

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollableArea);

void ScrollAnimatorScrollPhysicsClient::createAnimator(ScrollableArea& area)
{
    auto& state = static_cast<ScrollAnimatorScrollPhysicsClientState&>(*this);
    state.m_constAnimator = state.m_animator = &area.scrollAnimator();
}

struct SameSizeAsScrollableArea : public CanMakeWeakPtr<SameSizeAsScrollableArea>, public AbstractCanMakeCheckedPtr {
    WTF_DEPRECATED_MAKE_STRUCT_FAST_ALLOCATED(SameSizeAsScrollableArea);

    virtual ~SameSizeAsScrollableArea() { }
    SameSizeAsScrollableArea() { }
    void* pointer[2];
    IntPoint scrollOrigin;
    bool scrollClamping;
    uint8_t scrollElasticity[2];
    uint8_t scrollbarOverlayStyle;
    bool currentScrollType;
    uint8_t scrollAnimationStatus;
    bool bytes[4];
    Markable<ScrollingNodeID> scrollingNodeIDForTesting;
};

#if CPU(ADDRESS64)
static_assert(sizeof(ScrollableArea) == sizeof(SameSizeAsScrollableArea), "ScrollableArea should stay small");
#endif

ScrollableArea::ScrollableArea() = default;
ScrollableArea::~ScrollableArea() = default;

ScrollAnimator& ScrollableArea::scrollAnimator() const
{
    if (!m_scrollAnimator) {
        m_scrollAnimator = ScrollAnimator::create(const_cast<ScrollableArea&>(*this));
    }

    return *m_scrollAnimator.get();
}

ScrollbarsController& ScrollableArea::scrollbarsController() const
{
    if (!m_scrollbarsController) {
        const_cast<ScrollableArea&>(*this).internalCreateScrollbarsController();
    }
    RELEASE_ASSERT(m_scrollbarsController);
    return *m_scrollbarsController.get();
}

void ScrollableArea::internalCreateScrollbarsController()
{
    if (mockScrollbarsControllerEnabled()) {
        auto mockController = makeUnique<ScrollbarsControllerMock>(const_cast<ScrollableArea&>(*this), [weakThis = WeakPtr { *this }](const String& message) {
            if (CheckedPtr protectedThis = weakThis)
                protectedThis->logMockScrollbarsControllerMessage(message);
        });
        setScrollbarsController(WTF::move(mockController));
    } else
        createScrollbarsController();
}

void ScrollableArea::createScrollbarsController()
{
    auto controller = ScrollbarsController::create(const_cast<ScrollableArea&>(*this));
    setScrollbarsController(WTF::move(controller));
}

void ScrollableArea::setScrollbarsController(std::unique_ptr<ScrollbarsController>&& scrollbarsController)
{
    m_scrollbarsController = WTF::move(scrollbarsController);
}

void ScrollableArea::setScrollOrigin(const IntPoint& origin)
{
    if (m_scrollOrigin != origin) {
        m_scrollOrigin = origin;
        m_scrollOriginChanged = true;
        scrollOriginDidChange();
    }
}

float ScrollableArea::adjustVerticalPageScrollStepForFixedContent(float step)
{
    return step;
}

bool ScrollableArea::scroll(ScrollDirection direction, ScrollGranularity granularity, unsigned stepCount)
{
    return scrollableAreaScroll(ScrollAnimatorScrollPhysicsClientState(*this).facade(), direction, granularity, stepCount);
}

void ScrollableArea::beginKeyboardScroll(const KeyboardScroll& scrollData)
{
    scrollableAreaBeginKeyboardScroll(ScrollAnimatorScrollPhysicsClientState(*this).facade(), scrollData);
}

void ScrollableArea::endKeyboardScroll(bool immediate)
{
    scrollableAreaEndKeyboardScroll(ScrollAnimatorScrollPhysicsClientState(*this).facade(), immediate);
}

bool ScrollableArea::scrollToPositionWithoutAnimation(const FloatPoint& position, ScrollClamping clamping)
{
    LOG_WITH_STREAM(Scrolling, stream << "ScrollableArea " << this << " scrollToPositionWithoutAnimation " << position);
    return scrollAnimator().scrollToPositionWithoutAnimation(position, clamping);
}

void ScrollableArea::scrollToPositionWithAnimation(const FloatPoint& position, const ScrollPositionChangeOptions& options)
{
    scrollableAreaScrollToPositionWithAnimation(ScrollAnimatorScrollPhysicsClientState(*this).facade(), position, options.type, options.clamping, options.snapPointSelectionMethod, options.originalScrollDelta.has_value(), options.originalScrollDelta.value_or(FloatSize { }), options.animationCurve);
}

void ScrollableArea::scrollToOffsetWithoutAnimation(const FloatPoint& offset, ScrollClamping clamping)
{
    scrollableAreaScrollToOffsetWithoutAnimation(ScrollAnimatorScrollPhysicsClientState(*this).facade(), offset, clamping);
}

void ScrollableArea::scrollToOffsetWithoutAnimation(ScrollbarOrientation orientation, float offset)
{
    scrollableAreaScrollToOffsetWithoutAnimationOnAxis(ScrollAnimatorScrollPhysicsClientState(*this).facade(), orientation, offset);
}

void ScrollableArea::notifyScrollPositionChanged(const ScrollPosition& position)
{
    scrollableAreaNotifyScrollPositionChanged(ScrollAnimatorScrollPhysicsClientState(*this).facade(), position);
}

void ScrollAnimatorScrollPhysicsClient::scrollAnchoringScrollPositionDidChange()
{
    if (CheckedPtr controller = mutableArea().scrollAnchoringController())
        controller->scrollPositionDidChange();
}

void ScrollableArea::willDispatchScrollEvent()
{
    if (CheckedPtr controller = scrollAnchoringController())
        controller->willDispatchScrollEvent();
}

void ScrollableArea::didDispatchScrollEvent()
{
    if (CheckedPtr controller = scrollAnchoringController())
        controller->didDispatchScrollEvent();
}

bool ScrollableArea::handleWheelEventForScrolling(const PlatformWheelEvent& wheelEvent, std::optional<WheelScrollGestureState>)
{
    if (!isScrollableOrRubberbandable())
        return false;

    bool handledEvent = scrollAnimator().handleWheelEvent(wheelEvent);
    
    LOG_WITH_STREAM(Scrolling, stream << "ScrollableArea (" << *this << ") handleWheelEvent - handled " << handledEvent);
    return handledEvent;
}

void ScrollableArea::stopKeyboardScrollAnimation()
{
    scrollAnimator().stopKeyboardScrollAnimation();
}

void ScrollableArea::clearScrollAnchor(IncludeAncestors includeAncestors)
{
    if (CheckedPtr controller = scrollAnchoringController())
        controller->clearAnchor(includeAncestors == IncludeAncestors::Yes);
}

void ScrollableArea::adjustScrollAnchoringPosition()
{
    if (CheckedPtr controller = scrollAnchoringController())
        controller->adjustScrollPositionForAnchoring();
}

#if ENABLE(TOUCH_EVENTS)
bool ScrollableArea::handleTouchEvent(const PlatformTouchEvent& touchEvent)
{
    return scrollAnimator().handleTouchEvent(touchEvent);
}
#endif

#if USE(COORDINATED_GRAPHICS_ASYNC_SCROLLBAR)
float ScrollableArea::scrollbarOpacity() const
{
    if (auto scrollbar = verticalScrollbar())
        return scrollbar->opacity();
    if (auto scrollbar = horizontalScrollbar())
        return scrollbar->opacity();
    return 1;
}
#endif

// NOTE: Only called from Internals for testing.
void ScrollableArea::setScrollOffsetFromInternals(const ScrollOffset& offset)
{
    setScrollPositionFromAnimation(scrollPositionFromOffset(offset));
}

void ScrollableArea::setScrollPositionFromAnimation(const ScrollPosition& position)
{
    scrollableAreaSetScrollPositionFromAnimation(ScrollAnimatorScrollPhysicsClientState(*this).facade(), position);
}

void ScrollableArea::willStartLiveResize()
{
    if (m_inLiveResize)
        return;

    m_inLiveResize = true;
    scrollbarsController().willStartLiveResize();
}

void ScrollableArea::willEndLiveResize()
{
    if (!m_inLiveResize)
        return;

    m_inLiveResize = false;
    scrollbarsController().willEndLiveResize();
    scrollAnimator().contentsSizeChanged();
}

void ScrollableArea::contentAreaWillPaint() const
{
    // This is used to flash overlay scrollbars in some circumstances.
    scrollbarsController().contentAreaWillPaint();
}

void ScrollableArea::mouseEnteredContentArea() const
{
    scrollbarsController().mouseEnteredContentArea();
}

void ScrollableArea::mouseExitedContentArea() const
{
    scrollbarsController().mouseExitedContentArea();
}

void ScrollableArea::mouseMovedInContentArea() const
{
    scrollbarsController().mouseMovedInContentArea();
}

void ScrollableArea::mouseEnteredScrollbar(Scrollbar* scrollbar) const
{
    scrollbarsController().mouseEnteredScrollbar(scrollbar);
}

void ScrollableArea::mouseExitedScrollbar(Scrollbar* scrollbar) const
{
    scrollbarsController().mouseExitedScrollbar(scrollbar);
}

void ScrollableArea::mouseIsDownInScrollbar(Scrollbar* scrollbar, bool mouseIsDown) const
{
    scrollbarsController().mouseIsDownInScrollbar(scrollbar, mouseIsDown);
}

void ScrollableArea::contentAreaDidShow() const
{
    scrollbarsController().contentAreaDidShow();
}

void ScrollableArea::contentAreaDidHide() const
{
    scrollbarsController().contentAreaDidHide();
}

void ScrollableArea::lockOverlayScrollbarStateToHidden(bool shouldLockState) const
{
    scrollbarsController().lockOverlayScrollbarStateToHidden(shouldLockState);
}

bool ScrollableArea::scrollbarsCanBeActive() const
{
    return scrollbarsController().scrollbarsCanBeActive();
}

void ScrollableArea::didAddScrollbar(Scrollbar* scrollbar, ScrollbarOrientation orientation)
{
    if (orientation == ScrollbarOrientation::Vertical)
        scrollbarsController().didAddVerticalScrollbar(scrollbar);
    else
        scrollbarsController().didAddHorizontalScrollbar(scrollbar);

    scrollAnimator().contentsSizeChanged();

    // <rdar://problem/9797253> AppKit resets the scrollbar's style when you attach a scrollbar
    setScrollbarOverlayStyle(scrollbarOverlayStyle());
}

void ScrollableArea::willRemoveScrollbar(Scrollbar& scrollbar, ScrollbarOrientation orientation)
{
    if (orientation == ScrollbarOrientation::Vertical)
        scrollbarsController().willRemoveVerticalScrollbar(&scrollbar);
    else
        scrollbarsController().willRemoveHorizontalScrollbar(&scrollbar);
}

void ScrollableArea::contentsResized()
{
    scrollAnimator().contentsSizeChanged();
    scrollbarsController().contentsSizeChanged();
}

void ScrollableArea::availableContentSizeChanged(AvailableSizeChangeReason)
{
    scrollAnimator().contentsSizeChanged();
    scrollbarsController().contentsSizeChanged(); // This flashes overlay scrollbars.
}

bool ScrollableArea::hasOverlayScrollbars() const
{
    return (verticalScrollbar() && protect(verticalScrollbar())->isOverlayScrollbar())
        || (horizontalScrollbar() && protect(horizontalScrollbar())->isOverlayScrollbar());
}

bool ScrollableArea::canShowNonOverlayScrollbars() const
{
    return canHaveScrollbars() && !ScrollbarTheme::theme().usesOverlayScrollbars();
}

void ScrollableArea::setScrollbarOverlayStyle(ScrollbarOverlayStyle overlayStyle)
{
    m_scrollbarOverlayStyle = overlayStyle;

    if (RefPtr scrollbar = horizontalScrollbar())
        ScrollbarTheme::theme().updateScrollbarOverlayStyle(*scrollbar);

    if (RefPtr scrollbar = verticalScrollbar())
        ScrollbarTheme::theme().updateScrollbarOverlayStyle(*scrollbar);

    invalidateScrollbars();
}

void ScrollableArea::invalidateScrollbars()
{
    invalidateScrollCorner(scrollCornerRect());

    if (RefPtr scrollbar = horizontalScrollbar()) {
        scrollbar->invalidate();
        scrollbarsController().invalidateScrollbarPartLayers(scrollbar.get());
    }

    if (RefPtr scrollbar = verticalScrollbar()) {
        scrollbar->invalidate();
        scrollbarsController().invalidateScrollbarPartLayers(scrollbar.get());
    }
}

bool ScrollableArea::useDarkAppearanceForScrollbars() const
{
    // If dark appearance is used or the overlay style is light (because of a dark page background), set the dark appearance.
    return useDarkAppearance() || scrollbarOverlayStyle() == WebCore::ScrollbarOverlayStyle::Light;
}

void ScrollableArea::invalidateScrollbar(Scrollbar& scrollbar, const IntRect& rect)
{
    if (!scrollbarsController().shouldDrawIntoScrollbarLayer(scrollbar))
        return;

    if (&scrollbar == horizontalScrollbar()) {
        if (RefPtr graphicsLayer = layerForHorizontalScrollbar()) {
            graphicsLayer->setNeedsDisplay();
            graphicsLayer->setContentsNeedsDisplay();
            return;
        }
    } else if (&scrollbar == verticalScrollbar()) {
        if (RefPtr graphicsLayer = layerForVerticalScrollbar()) {
            graphicsLayer->setNeedsDisplay();
            graphicsLayer->setContentsNeedsDisplay();
            return;
        }
    }

    invalidateScrollbarRect(scrollbar, rect);
}

void ScrollableArea::invalidateScrollCorner(const IntRect& rect)
{
    if (RefPtr graphicsLayer = layerForScrollCorner()) {
        graphicsLayer->setNeedsDisplay();
        return;
    }

    invalidateScrollCornerRect(rect);
}

void ScrollableArea::verticalScrollbarLayerDidChange()
{
    scrollbarsController().verticalScrollbarLayerDidChange();
}

void ScrollableArea::horizontalScrollbarLayerDidChange()
{
    scrollbarsController().horizontalScrollbarLayerDidChange();
}

bool ScrollableArea::hasLayerForHorizontalScrollbar() const
{
    return layerForHorizontalScrollbar();
}

bool ScrollableArea::hasLayerForVerticalScrollbar() const
{
    return layerForVerticalScrollbar();
}

bool ScrollableArea::hasLayerForScrollCorner() const
{
    return layerForScrollCorner();
}

bool ScrollableArea::allowsHorizontalScrolling() const
{
    RefPtr horizontalScrollbar = this->horizontalScrollbar();
    return horizontalScrollbar && horizontalScrollbar->enabled();
}

bool ScrollableArea::allowsVerticalScrolling() const
{
    RefPtr verticalScrollbar = this->verticalScrollbar();
    return verticalScrollbar && verticalScrollbar->enabled();
}

String ScrollableArea::horizontalScrollbarStateForTesting() const
{
    return scrollbarsController().horizontalScrollbarStateForTesting();
}

String ScrollableArea::verticalScrollbarStateForTesting() const
{
    return scrollbarsController().verticalScrollbarStateForTesting();
}

Color ScrollableArea::scrollbarThumbColorStyle() const
{
    return { };
}

Color ScrollableArea::scrollbarTrackColorStyle() const
{
    return { };
}

Style::ScrollbarGutter ScrollableArea::scrollbarGutterStyle() const
{
    return CSS::Keyword::Auto { };
}

const LayoutScrollSnapOffsetsInfo* ScrollableArea::snapOffsetsInfo() const
{
    return existingScrollAnimator() ? existingScrollAnimator()->snapOffsetsInfo() : nullptr;
}

void ScrollableArea::setScrollSnapOffsetInfo(const LayoutScrollSnapOffsetsInfo& info)
{
    if (info.isEmpty()) {
        clearSnapOffsets();
        return;
    }

    // Consider having a non-empty set of snap offsets as a cue to initialize the ScrollAnimator.
    scrollAnimator().setSnapOffsetsInfo(info);
}

void ScrollableArea::clearSnapOffsets()
{
    if (auto* scrollAnimator = existingScrollAnimator())
        return scrollAnimator->setSnapOffsetsInfo(LayoutScrollSnapOffsetsInfo());
}

std::optional<unsigned> ScrollableArea::currentHorizontalSnapPointIndex() const
{
    if (auto* scrollAnimator = existingScrollAnimator())
        return scrollAnimator->activeScrollSnapIndexForAxis(ScrollEventAxis::Horizontal);
    return std::nullopt;
}

std::optional<unsigned> ScrollableArea::currentVerticalSnapPointIndex() const
{
    if (auto* scrollAnimator = existingScrollAnimator())
        return scrollAnimator->activeScrollSnapIndexForAxis(ScrollEventAxis::Vertical);
    return std::nullopt;
}

void ScrollableArea::setCurrentHorizontalSnapPointIndex(std::optional<unsigned> index)
{
    scrollAnimator().setActiveScrollSnapIndexForAxis(ScrollEventAxis::Horizontal, index);
}

void ScrollableArea::setCurrentVerticalSnapPointIndex(std::optional<unsigned> index)
{
    scrollAnimator().setActiveScrollSnapIndexForAxis(ScrollEventAxis::Vertical, index);
}

void ScrollableArea::resnapAfterLayout()
{
    scrollableAreaResnapAfterLayout(ScrollAnimatorScrollPhysicsClientState(*this).facade());
}

void ScrollableArea::doPostThumbMoveSnapping(ScrollbarOrientation orientation)
{
    scrollableAreaDoPostThumbMoveSnapping(ScrollAnimatorScrollPhysicsClientState(*this).facade(), orientation);
}

bool ScrollableArea::isPinnedOnSide(BoxSide side) const
{
    switch (side) {
    case BoxSide::Top:
        if (!allowsVerticalScrolling())
            return true;
        return scrollPosition().y() <= minimumScrollPosition().y();
    case BoxSide::Bottom:
        if (!allowsVerticalScrolling())
            return true;
        return scrollPosition().y() >= maximumScrollPosition().y();
    case BoxSide::Left:
        if (!allowsHorizontalScrolling())
            return true;
        return scrollPosition().x() <= minimumScrollPosition().x();
    case BoxSide::Right:
        if (!allowsHorizontalScrolling())
            return true;
        return scrollPosition().x() >= maximumScrollPosition().x();
    }
    return false;
}

RectEdges<bool> ScrollableArea::edgePinnedState() const
{
    auto scrollPosition = this->scrollPosition();
    auto minScrollPosition = minimumScrollPosition();
    auto maxScrollPosition = maximumScrollPosition();

    bool horizontallyUnscrollable = !allowsHorizontalScrolling();
    bool verticallyUnscrollable = !allowsVerticalScrolling();

    // Top, right, bottom, left.
    return {
        verticallyUnscrollable || scrollPosition.y() <= minScrollPosition.y(),
        horizontallyUnscrollable || scrollPosition.x() >= maxScrollPosition.x(),
        verticallyUnscrollable || scrollPosition.y() >= maxScrollPosition.y(),
        horizontallyUnscrollable || scrollPosition.x() <= minScrollPosition.x()
    };
}

int ScrollableArea::horizontalScrollbarIntrusion() const
{
    return verticalScrollbar() ? protect(verticalScrollbar())->occupiedWidth() : 0;
}

int ScrollableArea::verticalScrollbarIntrusion() const
{
    return horizontalScrollbar() ? protect(horizontalScrollbar())->occupiedHeight() : 0;
}

IntSize ScrollableArea::scrollbarIntrusion() const
{
    return { horizontalScrollbarIntrusion(), verticalScrollbarIntrusion() };
}

ScrollOffset ScrollableArea::scrollOffset() const
{
    return scrollOffsetFromPosition(scrollPosition());
}

ScrollPosition ScrollableArea::minimumScrollPosition() const
{
    return scrollPositionFromOffset(ScrollPosition());
}

ScrollPosition ScrollableArea::maximumScrollPosition() const
{
    return scrollPositionFromOffset(ScrollPosition(totalContentsSize() - visibleSize()));
}

ScrollOffset ScrollableArea::maximumScrollOffset() const
{
    return ScrollOffset(totalContentsSize() - visibleSize());
}

ScrollPosition ScrollableArea::scrollPositionFromOffset(ScrollOffset offset) const
{
    return scrollPositionFromOffset(offset, toIntSize(m_scrollOrigin));
}

ScrollOffset ScrollableArea::scrollOffsetFromPosition(ScrollPosition position) const
{
    return scrollOffsetFromPosition(position, toIntSize(m_scrollOrigin));
}

bool ScrollableArea::scrolledToTop() const
{
    return scrollPosition().y() <= minimumScrollPosition().y();
}

bool ScrollableArea::scrolledToBottom() const
{
    return scrollPosition().y() >= maximumScrollPosition().y();
}

bool ScrollableArea::scrolledToLeft() const
{
    return scrollPosition().x() <= minimumScrollPosition().x();
}

bool ScrollableArea::scrolledToRight() const
{
    return scrollPosition().x() >= maximumScrollPosition().x();
}

void ScrollableArea::scrollbarStyleChanged(ScrollbarStyle, bool)
{
    availableContentSizeChanged(AvailableSizeChangeReason::ScrollbarsChanged);
}

IntSize ScrollableArea::reachableTotalContentsSize() const
{
    return totalContentsSize();
}

IntSize ScrollableArea::totalContentsSize() const
{
    IntSize totalContentsSize = contentsSize();
    totalContentsSize.setHeight(totalContentsSize.height() + headerHeight() + footerHeight());
    return totalContentsSize;
}

IntRect ScrollableArea::visibleContentRect(VisibleContentRectBehavior visibleContentRectBehavior) const
{
    return visibleContentRectInternal(VisibleContentRectIncludesScrollbars::No, visibleContentRectBehavior);
}

IntRect ScrollableArea::visibleContentRectIncludingScrollbars(VisibleContentRectBehavior visibleContentRectBehavior) const
{
    return visibleContentRectInternal(VisibleContentRectIncludesScrollbars::Yes, visibleContentRectBehavior);
}

IntRect ScrollableArea::visibleContentRectInternal(VisibleContentRectIncludesScrollbars scrollbarInclusion, VisibleContentRectBehavior) const
{
    int verticalScrollbarWidth = 0;
    int horizontalScrollbarHeight = 0;

    if (scrollbarInclusion == VisibleContentRectIncludesScrollbars::Yes) {
        if (RefPtr verticalBar = verticalScrollbar())
            verticalScrollbarWidth = verticalBar->occupiedWidth();
        if (RefPtr horizontalBar = horizontalScrollbar())
            horizontalScrollbarHeight = horizontalBar->occupiedHeight();
    }

    return IntRect(scrollPosition().x(),
                   scrollPosition().y(),
                   std::max(0, visibleWidth() + verticalScrollbarWidth),
                   std::max(0, visibleHeight() + horizontalScrollbarHeight));
}

LayoutPoint ScrollableArea::constrainScrollPositionForOverhang(const LayoutRect& visibleContentRect, const LayoutSize& totalContentsSize, const LayoutPoint& scrollPosition, const LayoutPoint& scrollOrigin, int headerHeight, int footerHeight)
{
    return scrollableAreaConstrainScrollPositionForOverhang(visibleContentRect, totalContentsSize, scrollPosition, scrollOrigin, headerHeight, footerHeight);
}

LayoutPoint ScrollableArea::constrainScrollPositionForOverhang(const LayoutPoint& scrollPosition)
{
    return constrainScrollPositionForOverhang(visibleContentRect(), totalContentsSize(), scrollPosition, scrollOrigin(), headerHeight(), footerHeight());
}

void ScrollableArea::computeScrollbarValueAndOverhang(float currentPosition, float totalSize, float visibleSize, float& scrollbarValue, float& overhangAmount)
{
    scrollableAreaComputeScrollbarValueAndOverhang(currentPosition, totalSize, visibleSize, scrollbarValue, overhangAmount);
}

std::optional<BoxSide> ScrollableArea::targetSideForScrollDelta(FloatSize delta, ScrollEventAxis axis)
{
    return scrollableAreaTargetSideForScrollDelta(delta, axis);
}

LayoutRect ScrollableArea::getRectToExposeForScrollIntoView(const LayoutRect& visibleBounds, const LayoutRect& exposeRect, const ScrollAlignment& alignX, const ScrollAlignment& alignY, const std::optional<LayoutRect> visibilityCheckRect) const
{
    return scrollableAreaRectToExposeForScrollIntoView(visibleBounds, exposeRect, alignX, alignY, visibilityCheckRect.has_value(), visibilityCheckRect.value_or(LayoutRect { }));
}

TextStream& operator<<(TextStream& ts, const ScrollableArea& scrollableArea)
{
    ts << scrollableArea.debugDescription();
    return ts;
}

FloatSize ScrollableArea::deltaForPropagation(const FloatSize& biasedDelta) const
{
    return scrollableAreaDeltaForPropagation(horizontalOverscrollBehavior(), verticalOverscrollBehavior(), biasedDelta);
}

bool ScrollableArea::shouldBlockScrollPropagation(const FloatSize& biasedDelta) const
{
    return scrollableAreaShouldBlockScrollPropagation(horizontalOverscrollBehavior(), verticalOverscrollBehavior(), biasedDelta);
}

ScrollingNodeID ScrollableArea::scrollingNodeIDForTesting()
{
    if (m_scrollingNodeIDForTesting)
        return *m_scrollingNodeIDForTesting;
    auto testingNodeID = scrollingNodeID();
    if (!testingNodeID)
        m_scrollingNodeIDForTesting = testingNodeID = ScrollingNodeID::generate();
    return *testingNodeID;
}

void ScrollableArea::scrollbarColorDidChange(std::optional<ScrollbarColor> scrollbarColor)
{
    scrollbarsController().scrollbarColorChanged(scrollbarColor);
}

// MARK: -

ScrollbarRevealBehaviorScope::ScrollbarRevealBehaviorScope(ScrollableArea& scrollableArea, ScrollbarRevealBehavior reveal)
    : m_scrollableArea(scrollableArea)
    , m_oldBehavior(scrollableArea.scrollbarRevealBehavior())
{
    scrollableArea.setScrollbarRevealBehavior(reveal);
}

ScrollbarRevealBehaviorScope::~ScrollbarRevealBehaviorScope()
{
    auto& scrollableArea = m_scrollableArea.get();
    scrollableArea.setScrollbarRevealBehavior(m_oldBehavior);
}

// MARK: -

ScrollAnchoringSuppressionScope::ScrollAnchoringSuppressionScope(ScrollableArea& scrollableArea)
    : m_scrollableArea(scrollableArea)
{
    if (CheckedPtr controller = scrollableArea.scrollAnchoringController())
        controller->startSuppressingScrollAnchoring();
}

ScrollAnchoringSuppressionScope::~ScrollAnchoringSuppressionScope()
{
    CheckedPtr scrollableArea = m_scrollableArea.get();
    if (!scrollableArea)
        return;

    if (CheckedPtr controller = scrollableArea->scrollAnchoringController())
        controller->stopSuppressingScrollAnchoring();
}

// MARK: -

ScrollTypeScope::ScrollTypeScope(ScrollableArea& scrollableArea, ScrollType newType)
    : m_scrollableArea(scrollableArea)
    , m_oldScrollType(scrollableArea.currentScrollType())
{
    scrollableArea.setCurrentScrollType(newType);
}

ScrollTypeScope::~ScrollTypeScope()
{
    restore();
}

void ScrollTypeScope::restore()
{
    if (!m_oldScrollType)
        return;

    auto& scrollableArea = m_scrollableArea.get();
    scrollableArea.setCurrentScrollType(*m_oldScrollType);
    m_oldScrollType = { };
}

} // namespace WebCore
