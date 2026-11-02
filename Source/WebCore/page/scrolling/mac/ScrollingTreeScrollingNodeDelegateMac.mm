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
#import "ScrollingTreeScrollingNodeDelegateMac.h"

#if PLATFORM(MAC)

#import "Logging.h"
#import "RubberbandingState.h"
#import "ScrollExtents.h"
#import "ScrollingStateScrollingNode.h"
#import "ScrollingTree.h"
#import "ScrollingTreeFrameScrollingNode.h"
#import "ScrollingTreeScrollingNode.h"
#import <QuartzCore/QuartzCore.h>
#import <pal/spi/mac/NSScrollerImpSPI.h>
#import <wtf/BlockObjCExceptions.h>
#import <wtf/SystemTracing.h>
#import <wtf/TZoneMallocInlines.h>

#if USE_SWIFT_SCROLLING_TREE_DELEGATE
#import "ScrollingTreeScrollPhysicsClient.h"
#import "ScrollingTreeScrollPhysicsDelegateHolder.h"
#endif

#if USE_SWIFT_MAC_SCROLLERS
#import "WebCore-Swift.h"
#endif

#if USE_SWIFT_SCROLLERS_IN_DELEGATE
#import "ScrollerPairMacTypes.h"
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollingTreeScrollingNodeDelegateMac);

ScrollingTreeScrollingNodeDelegateMac::ScrollingTreeScrollingNodeDelegateMac(ScrollingTreeScrollingNode& scrollingNode)
    : ThreadedScrollingTreeScrollingNodeDelegate(scrollingNode)
    , m_scrollerPair(ScrollerPairMac::create(scrollingNode))
{
#if HAVE(RUBBER_BANDING)
    if (scrollingNode.nodeType() == ScrollingNodeType::MainFrame)
        m_pendingRubberbandingState = scrollingTree()->takePendingMainFrameRubberbandingState();
#endif
}

ScrollingTreeScrollingNodeDelegateMac::~ScrollingTreeScrollingNodeDelegateMac() = default;

#if USE_SWIFT_SCROLLING_TREE_DELEGATE
void ScrollingTreeScrollPhysicsClient::emitRubberBandSignpost(bool isRubberBanding, IntSize stretch, bool isMainFrame)
{
    WTFEmitSignpostAlways(&delegate(), ScrollingPerformanceTestRubberBand, "%{public}s; top=%d right=%d bottom=%d left=%d; stretch=%d,%d; isMainFrame=%d",
        isRubberBanding ? "started" : "ended",
        stretch.height() < 0, stretch.width() > 0, stretch.height() > 0, stretch.width() < 0,
        stretch.width(), stretch.height(),
        isMainFrame);
}
#endif

void ScrollingTreeScrollingNodeDelegateMac::nodeWillBeDestroyed()
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    // Hand the timers to destroyTimer() rather than stopping them here: they run on the scrolling thread, and the
    // node may be torn down on another.
    Ref scrollingNode = this->scrollingNode();
    if (m_discreteSnapTransitionTimer) {
        destroyTimer(WTF::move(m_discreteSnapTransitionTimer));
        scrollingNode->setScrollSnapInProgress(false);
        scrollingNode->didStopAnimatedScroll();
    }

    if (m_discreteScrollendTimer)
        destroyTimer(WTF::move(m_discreteScrollendTimer));
#else
    m_scrollController.stopAllTimers();
#endif
}

void ScrollingTreeScrollingNodeDelegateMac::updateFromStateNode(const ScrollingStateScrollingNode& scrollingStateNode)
{
#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
#if !USE_SWIFT_MAC_SCROLLERS
    Ref horizontalScroller = m_scrollerPair->horizontalScroller();
    Ref verticalScroller = m_scrollerPair->verticalScroller();
#endif

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::PainterForScrollbar)) {
        RetainPtr horizontalScrollbar = scrollingStateNode.horizontalScrollerImp();
        RetainPtr verticalScrollbar = scrollingStateNode.verticalScrollerImp();
        if (horizontalScrollbar || verticalScrollbar) {
            m_scrollerPair->releaseReferencesToScrollerImpsOnTheMainThread();
#if !USE_SWIFT_MAC_SCROLLERS
            horizontalScroller->setScrollerImp(horizontalScrollbar);
            verticalScroller->setScrollerImp(verticalScrollbar);
#else
            m_scrollerPair->scrollers().setScrollerImp(m_scrollerPair.ptr(), ScrollbarOrientation::Horizontal, horizontalScrollbar.get());
            m_scrollerPair->scrollers().setScrollerImp(m_scrollerPair.ptr(), ScrollbarOrientation::Vertical, verticalScrollbar.get());
#endif
        }
    }

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::ScrollbarHoverState))
        m_scrollerPair->mouseIsInScrollbar(scrollingStateNode.scrollbarHoverState());

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::HorizontalScrollbarLayer))
#if !USE_SWIFT_MAC_SCROLLERS
        horizontalScroller->setHostLayer(protect(static_cast<CALayer*>(scrollingStateNode.horizontalScrollbarLayer())));
#else
        m_scrollerPair->scrollers().setHostLayer(m_scrollerPair.ptr(), ScrollbarOrientation::Horizontal, protect(static_cast<CALayer*>(scrollingStateNode.horizontalScrollbarLayer())).get());
#endif

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::VerticalScrollbarLayer))
#if !USE_SWIFT_MAC_SCROLLERS
        verticalScroller->setHostLayer(protect(static_cast<CALayer*>(scrollingStateNode.verticalScrollbarLayer())));
#else
        m_scrollerPair->scrollers().setHostLayer(m_scrollerPair.ptr(), ScrollbarOrientation::Vertical, protect(static_cast<CALayer*>(scrollingStateNode.verticalScrollbarLayer())).get());
#endif

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::ScrollableAreaParams)) {
#if !USE_SWIFT_MAC_SCROLLERS
        horizontalScroller->setHiddenByStyle(scrollingStateNode.scrollableAreaParameters().horizontalNativeScrollbarVisibility);
        verticalScroller->setHiddenByStyle(scrollingStateNode.scrollableAreaParameters().verticalNativeScrollbarVisibility);
#else
        m_scrollerPair->scrollers().setHiddenByStyle(m_scrollerPair.ptr(), ScrollbarOrientation::Horizontal, scrollingStateNode.scrollableAreaParameters().horizontalNativeScrollbarVisibility);
        m_scrollerPair->scrollers().setHiddenByStyle(m_scrollerPair.ptr(), ScrollbarOrientation::Vertical, scrollingStateNode.scrollableAreaParameters().verticalNativeScrollbarVisibility);
#endif
    }

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::ScrollbarEnabledState)) {
        auto scrollbarEnabledState = scrollingStateNode.scrollbarEnabledState();
#if !USE_SWIFT_MAC_SCROLLERS
        m_scrollerPair->horizontalScroller().setEnabled(scrollbarEnabledState.horizontalScrollbarIsEnabled);
        m_scrollerPair->verticalScroller().setEnabled(scrollbarEnabledState.verticalScrollbarIsEnabled);
#else
        m_scrollerPair->scrollers().setEnabled(ScrollbarOrientation::Horizontal, scrollbarEnabledState.horizontalScrollbarIsEnabled);
        m_scrollerPair->scrollers().setEnabled(ScrollbarOrientation::Vertical, scrollbarEnabledState.verticalScrollbarIsEnabled);
#endif
    }

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::ScrollbarLayoutDirection)) {
        auto scrollbarLayoutDirection = scrollingStateNode.scrollbarLayoutDirection();
#if !USE_SWIFT_MAC_SCROLLERS
        horizontalScroller->setScrollbarLayoutDirection(scrollbarLayoutDirection);
        verticalScroller->setScrollbarLayoutDirection(scrollbarLayoutDirection);
#else
        m_scrollerPair->scrollers().setScrollbarLayoutDirection(m_scrollerPair.ptr(), ScrollbarOrientation::Horizontal, scrollbarLayoutDirection);
        m_scrollerPair->scrollers().setScrollbarLayoutDirection(m_scrollerPair.ptr(), ScrollbarOrientation::Vertical, scrollbarLayoutDirection);
#endif
    }

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::ScrollbarWidth)) {
        auto scrollbarWidth = scrollingStateNode.scrollbarWidth();
        m_scrollerPair->setScrollbarWidth(scrollbarWidth);
    }

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::UseDarkAppearanceForScrollbars))
        m_scrollerPair->setUseDarkAppearance(scrollingStateNode.useDarkAppearanceForScrollbars());

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::ContentAreaHoverState)) {
        if (scrollingStateNode.mouseIsOverContentArea())
            m_scrollerPair->mouseEnteredContentArea();
        else
            m_scrollerPair->mouseExitedContentArea();
    }
    
    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::MouseActivityState))
        m_scrollerPair->mouseMovedInContentArea(scrollingStateNode.mouseLocationState());

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::ScrollbarColor))
        m_scrollerPair->scrollbarColorChanged(scrollingStateNode.scrollbarColor());

    m_scrollerPair->updateValues();
#else
    m_physics->delegate.updateScrollbars(m_scrollerPair.ptr(), m_scrollerPair->scrollers(), scrollingStateNode.changedProperties().toRaw(),
        scrollingStateNode.horizontalScrollerImp(), scrollingStateNode.verticalScrollerImp(), scrollingStateNode.scrollbarHoverState(),
        scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::HorizontalScrollbarLayer) ? static_cast<CALayer*>(scrollingStateNode.horizontalScrollbarLayer()) : nil,
        scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::VerticalScrollbarLayer) ? static_cast<CALayer*>(scrollingStateNode.verticalScrollbarLayer()) : nil, scrollingStateNode.scrollableAreaParameters(),
        scrollingStateNode.scrollbarEnabledState(), scrollingStateNode.scrollbarLayoutDirection(), scrollingStateNode.scrollbarWidth(), scrollingStateNode.useDarkAppearanceForScrollbars(),
        scrollingStateNode.mouseIsOverContentArea(), scrollingStateNode.mouseLocationState(), scrollingStateNode.scrollbarColor());
#endif

    ThreadedScrollingTreeScrollingNodeDelegate::updateFromStateNode(scrollingStateNode);

#if HAVE(RUBBER_BANDING)
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    if (m_pendingRubberbandingState) {
        m_physics->delegate.restoreRubberbandingState(ScrollingTreeScrollPhysicsClientState(*this).facade(), *m_pendingRubberbandingState);
        m_pendingRubberbandingState = std::nullopt;
    }
#else
    if (m_pendingRubberbandingState) {
        LOG_WITH_STREAM(ScrollAnimations, stream << "ScrollingTreeScrollingNodeDelegateMac::updateFromStateNode - restoring rubberbanding state: initialOverscroll=" << m_pendingRubberbandingState->initialOverscroll);
        bool restored = m_scrollController.restoreRubberbandingState(WTF::move(*m_pendingRubberbandingState));
        m_pendingRubberbandingState = std::nullopt;
        if (restored)
            scrollingNode()->setRestoredRubberbandingInProgress(true);
        LOG_WITH_STREAM(ScrollAnimations, stream << "ScrollingTreeScrollingNodeDelegateMac::updateFromStateNode - restoreRubberbandingState returned " << restored);
    }
#endif
#endif
}

bool ScrollingTreeScrollingNodeDelegateMac::handleWheelEvent(const PlatformWheelEvent& wheelEvent)
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    return m_physics->delegate.handleWheelEvent(ScrollingTreeScrollPhysicsClientState(*this).facade(), m_scrollerPair.ptr(), wheelEvent, wheelEvent.timestamp().secondsSinceEpoch().value());
#else
    return m_physics->delegate.handleWheelEvent(ScrollingTreeScrollPhysicsClientState(*this).facade(), m_scrollerPair->scrollers(), wheelEvent, wheelEvent.timestamp().secondsSinceEpoch().value());
#endif
#else
    bool wasInMomentumPhase = m_inMomentumPhase;

    if (wheelEvent.momentumPhase() == PlatformWheelEventPhase::Began)
        m_inMomentumPhase = true;
    else if (wheelEvent.momentumPhase() == PlatformWheelEventPhase::Ended || wheelEvent.momentumPhase() == PlatformWheelEventPhase::Cancelled)
        m_inMomentumPhase = false;
    
    if (wasInMomentumPhase != m_inMomentumPhase)
        m_scrollerPair->setUsePresentationValues(m_inMomentumPhase);

    auto deferrer = ScrollingTreeWheelEventTestMonitorCompletionDeferrer { *scrollingTree(), scrollingNode()->scrollingNodeID(), WheelEventTestMonitor::DeferReason::HandlingWheelEvent };

    updateUserScrollInProgressForEvent(wheelEvent);
    m_scrollController.handleWheelEventDuringSpringAnimation(wheelEvent);

    // PlatformWheelEventPhase::MayBegin fires when two fingers touch the trackpad, and is used to flash overlay scrollbars.
    // We know we're scrollable at this point, so handle the event.
    if (wheelEvent.phase() == PlatformWheelEventPhase::MayBegin)
        return true;

    return m_scrollController.handleWheelEvent(wheelEvent);
#endif
}

void ScrollingTreeScrollingNodeDelegateMac::willDoProgrammaticScroll(const FloatPoint& targetPosition)
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    m_physics->delegate.willDoProgrammaticScroll(ScrollingTreeScrollPhysicsClientState(*this).facade(), targetPosition);
#else
    if (scrollPositionIsNotRubberbandingEdge(targetPosition)) {
        LOG(Scrolling, "ScrollingTreeScrollingNodeDelegateMac::willDoProgrammaticScroll() - scrolling away from rubberbanding edge so stopping rubberbanding");
        m_scrollController.stopRubberBanding();
    }
#endif
}

#if !USE_SWIFT_SCROLLING_TREE_DELEGATE
bool ScrollingTreeScrollingNodeDelegateMac::scrollPositionIsNotRubberbandingEdge(const FloatPoint& targetPosition) const
{
    if (!m_scrollController.isRubberBandInProgress())
        return false;

    auto rubberbandingEdges = m_scrollController.rubberBandingEdges();

    auto minimumScrollPosition = this->minimumScrollPosition();
    auto maximumScrollPosition = this->maximumScrollPosition();

    for (auto side : allBoxSides) {
        if (!rubberbandingEdges[side])
            continue;

        switch (side) {
        case BoxSide::Top:
            if (targetPosition.y() != minimumScrollPosition.y())
                return true;
            break;
        case BoxSide::Right:
            if (targetPosition.x() != maximumScrollPosition.x())
                return true;
            break;
        case BoxSide::Bottom:
            if (targetPosition.y() != maximumScrollPosition.y())
                return true;
            break;
        case BoxSide::Left:
            if (targetPosition.x() != minimumScrollPosition.x())
                return true;
            break;
        }
    }
    return false;
}
#endif

void ScrollingTreeScrollingNodeDelegateMac::currentScrollPositionChanged()
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    m_physics->delegate.currentScrollPositionChanged(ScrollingTreeScrollPhysicsClientState(*this).facade());
#else
    m_scrollController.scrollPositionChanged();
#endif
}

bool ScrollingTreeScrollingNodeDelegateMac::isRubberBandInProgress() const
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    return m_physics->delegate.isRubberBandInProgress();
#else
    return m_scrollController.isRubberBandInProgress();
#endif
}

void ScrollingTreeScrollingNodeDelegateMac::startRubberBandSnapBack()
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    m_physics->delegate.startRubberBandSnapBack(ScrollingTreeScrollPhysicsClientState(*this).facade());
#else
    m_scrollController.startRubberBandSnapBack();
#endif
}

void ScrollingTreeScrollingNodeDelegateMac::rubberBandTargetOffsetDidChange()
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    m_physics->delegate.rubberBandTargetOffsetDidChange(ScrollingTreeScrollPhysicsClientState(*this).facade());
#else
    m_scrollController.rubberBandTargetOffsetDidChange();
#endif
}

#if HAVE(RUBBER_BANDING)
std::optional<RubberbandingState> ScrollingTreeScrollingNodeDelegateMac::captureRubberbandingState() const
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
    // scrollingNode() is const here; the scroller pair holds the same node.
    RefPtr node = m_scrollerPair->node();
    RELEASE_ASSERT(node);
    RubberbandingState state;
    if (!m_physics->delegate.captureRubberbandingState(ScrollingTreeScrollPhysicsClientState(node.releaseNonNull()).facade(), state))
        return std::nullopt;
    return state;
#else
    return m_scrollController.captureRubberbandingState();
#endif
}
#endif

#if !USE_SWIFT_SCROLLING_TREE_DELEGATE
bool ScrollingTreeScrollingNodeDelegateMac::allowsHorizontalStretching(const PlatformWheelEvent& wheelEvent) const
{
    switch (horizontalScrollElasticity()) {
    case ScrollElasticity::Automatic: {
        bool scrollbarsAllowStretching = allowsHorizontalScrolling() || !allowsVerticalScrolling();
        auto relevantSide = ScrollableArea::targetSideForScrollDelta(-wheelEvent.delta(), ScrollEventAxis::Horizontal);
        bool eventPreventsStretching = wheelEvent.isGestureStart() && relevantSide && isPinnedOnSide(*relevantSide);
        return scrollbarsAllowStretching && !eventPreventsStretching;
    }
    case ScrollElasticity::None:
        return false;
    case ScrollElasticity::Allowed: {
        auto relevantSide = ScrollableArea::targetSideForScrollDelta(-wheelEvent.delta(), ScrollEventAxis::Horizontal);
        if (relevantSide)
            return shouldRubberBandOnSide(*relevantSide, wheelEvent.delta());
        return true;
    }
    }

    ASSERT_NOT_REACHED();
    return false;
}

bool ScrollingTreeScrollingNodeDelegateMac::allowsVerticalStretching(const PlatformWheelEvent& wheelEvent) const
{
    switch (verticalScrollElasticity()) {
    case ScrollElasticity::Automatic: {
        bool scrollbarsAllowStretching = allowsVerticalScrolling() || !allowsHorizontalScrolling();
        auto relevantSide = ScrollableArea::targetSideForScrollDelta(-wheelEvent.delta(), ScrollEventAxis::Vertical);
        bool eventPreventsStretching = wheelEvent.isGestureStart() && relevantSide && isPinnedOnSide(*relevantSide);
        return scrollbarsAllowStretching && !eventPreventsStretching;
    }
    case ScrollElasticity::None:
        return false;
    case ScrollElasticity::Allowed: {
        auto relevantSide = ScrollableArea::targetSideForScrollDelta(-wheelEvent.delta(), ScrollEventAxis::Vertical);
        if (relevantSide)
            return shouldRubberBandOnSide(*relevantSide, wheelEvent.delta());
        return true;
    }
    }

    ASSERT_NOT_REACHED();
    return false;
}

IntSize ScrollingTreeScrollingNodeDelegateMac::stretchAmount() const
{
    IntSize stretch;
    auto scrollPosition = currentScrollPosition();

    if (scrollPosition.y() < minimumScrollPosition().y())
        stretch.setHeight(scrollPosition.y() - minimumScrollPosition().y());
    else if (scrollPosition.y() > maximumScrollPosition().y())
        stretch.setHeight(scrollPosition.y() - maximumScrollPosition().y());

    if (scrollPosition.x() < minimumScrollPosition().x())
        stretch.setWidth(scrollPosition.x() - minimumScrollPosition().x());
    else if (scrollPosition.x() > maximumScrollPosition().x())
        stretch.setWidth(scrollPosition.x() - maximumScrollPosition().x());

    return stretch;
}

bool ScrollingTreeScrollingNodeDelegateMac::isScrollDeltaOpposingStretch(ScrollEventAxis axis, float delta) const
{
    return ScrollingEffectsController::isScrollDeltaOpposingStretch(stretchAmount(), axis, delta);
}

bool ScrollingTreeScrollingNodeDelegateMac::isPinnedOnSide(BoxSide side) const
{
    switch (side) {
    case BoxSide::Top:
        if (!allowsVerticalScrolling())
            return true;
        return currentScrollPosition().y() <= minimumScrollPosition().y();
    case BoxSide::Bottom:
        if (!allowsVerticalScrolling())
            return true;
        return currentScrollPosition().y() >= maximumScrollPosition().y();
    case BoxSide::Left:
        if (!allowsHorizontalScrolling())
            return true;
        return currentScrollPosition().x() <= minimumScrollPosition().x();
    case BoxSide::Right:
        if (!allowsHorizontalScrolling())
            return true;
        return currentScrollPosition().x() >= maximumScrollPosition().x();
    }
    return false;
}

RectEdges<bool> ScrollingTreeScrollingNodeDelegateMac::edgePinnedState() const
{
    return scrollingNode()->edgePinnedState();
}

bool ScrollingTreeScrollingNodeDelegateMac::shouldRubberBandOnSide(BoxSide side, FloatSize delta) const
{
    const auto axis = (side == BoxSide::Left || side == BoxSide::Right) ? ScrollEventAxis::Horizontal : ScrollEventAxis::Vertical;
    const auto deltaOnAxis = (axis == ScrollEventAxis::Horizontal) ? -delta.width() : -delta.height();
    if (isScrollDeltaOpposingStretch(axis, deltaOnAxis))
        return true;

    return scrollingNode()->shouldRubberBandOnSide(side, edgePinnedState());
}

void ScrollingTreeScrollingNodeDelegateMac::didStopRubberBandAnimation()
{
    // Since the rubberband timer has stopped, totalContentsSizeForRubberBand can be synchronized with totalContentsSize.
    scrollingNode()->setTotalContentsSizeForRubberBand(totalContentsSize());
}

void ScrollingTreeScrollingNodeDelegateMac::rubberBandingStateChanged(bool inRubberBand)
{
    if (scrollingTree()->scrollingPerformanceTestingEnabled()) {
        auto stretch = stretchAmount();
        WTFEmitSignpostAlways(this, ScrollingPerformanceTestRubberBand, "%{public}s; top=%d right=%d bottom=%d left=%d; stretch=%d,%d; isMainFrame=%d",
            inRubberBand ? "started" : "ended",
            stretch.height() < 0, stretch.width() > 0, stretch.height() > 0, stretch.width() < 0,
            stretch.width(), stretch.height(),
            scrollingNode()->nodeType() == ScrollingNodeType::MainFrame);
    }

    scrollingTree()->setRubberBandingInProgressForNode(scrollingNode()->scrollingNodeID(), inRubberBand);
#if HAVE(RUBBER_BANDING)
    if (!inRubberBand)
        scrollingNode()->setRestoredRubberbandingInProgress(false);
#endif
}

FloatSize ScrollingTreeScrollingNodeDelegateMac::rubberBandTargetOffset() const
{
#if HAVE(NSREFRESHCONTROLLER)
    // NSRefreshController will only affect the rubberbanding of the main frame.
    if (scrollingNode()->nodeType() == ScrollingNodeType::MainFrame) {
        auto topOffset = scrollingTree()->topScrollStretchForRefreshController();
        if (topOffset)
            return FloatSize(0, -topOffset);
    }
#endif
    return { };
}

#if HAVE(NSREFRESHCONTROLLER)

float ScrollingTreeScrollingNodeDelegateMac::refreshControllerSnappingThreshold() const
{
    if (scrollingNode()->nodeType() != ScrollingNodeType::MainFrame)
        return 0;

    return scrollingTree()->refreshControllerSnappingThreshold();
}

bool ScrollingTreeScrollingNodeDelegateMac::hasRefreshController() const
{
    return scrollingNode()->nodeType() == ScrollingNodeType::MainFrame && scrollingTree()->hasRefreshController();
}

#endif
#endif

void ScrollingTreeScrollingNodeDelegateMac::updateScrollbarPainters()
{
#if USE_SWIFT_SCROLLING_TREE_DELEGATE
#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    m_physics->delegate.updateScrollbarPainters(m_scrollerPair.ptr());
#else
    m_physics->delegate.updateScrollbarPainters(m_scrollerPair.ptr(), m_scrollerPair->scrollers());
#endif
#else
    if (m_inMomentumPhase && m_scrollerPair->hasScrollerImp() && m_scrollerPair->isUsingPresentationValues())
        m_scrollerPair->updateScrollbarPainters();
#endif
}

void ScrollingTreeScrollingNodeDelegateMac::initScrollbars()
{
    m_scrollerPair->init();
}

void ScrollingTreeScrollingNodeDelegateMac::updateScrollbarLayers()
{
#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    m_scrollerPair->updateValues();
#else
    m_scrollerPair->scrollers().updateValues(m_scrollerPair.ptr());
#endif
}

void ScrollingTreeScrollingNodeDelegateMac::handleWheelEventPhase(const PlatformWheelEventPhase wheelEventPhase)
{
#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    m_scrollerPair->handleWheelEventPhase(wheelEventPhase);
#else
    m_scrollerPair->scrollers().handleWheelEventPhase(m_scrollerPair.ptr(), wheelEventPhase);
#endif
}

void ScrollingTreeScrollingNodeDelegateMac::viewWillStartLiveResize()
{
#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    return m_scrollerPair->viewWillStartLiveResize();
#else
    m_scrollerPair->scrollers().viewWillStartLiveResize(m_scrollerPair.ptr());
#endif
}

void ScrollingTreeScrollingNodeDelegateMac::viewWillEndLiveResize()
{
#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    return m_scrollerPair->viewWillEndLiveResize();
#else
    m_scrollerPair->scrollers().viewWillEndLiveResize(m_scrollerPair.ptr());
#endif
}

void ScrollingTreeScrollingNodeDelegateMac::viewSizeDidChange()
{
#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    return m_scrollerPair->contentsSizeChanged();
#else
    m_scrollerPair->scrollers().notifyScrollerImpPair(m_scrollerPair.ptr(), ScrollerImpPairNotification::ContentAreaDidResize);
#endif
}

String ScrollingTreeScrollingNodeDelegateMac::scrollbarStateForOrientation(ScrollbarOrientation orientation) const
{
#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    return m_scrollerPair->scrollbarStateForOrientation(orientation);
#else
    return m_scrollerPair->scrollers().scrollbarStateForOrientation(orientation);
#endif
}

Vector<RetainPtr<CALayer>, 2> ScrollingTreeScrollingNodeDelegateMac::hitTestableScrollbarLayers() const
{
    Ref node = scrollingNode();
#if !USE_SWIFT_SCROLLERS_IN_DELEGATE
    bool usesOverlayScrollbars = m_scrollerPair->scrollbarStyle() == ScrollbarStyle::Overlay;
#else
    bool usesOverlayScrollbars = m_scrollerPair->scrollers().scrollbarStyle() == ScrollbarStyle::Overlay;
#endif

    Vector<RetainPtr<CALayer>, 2> layers;
#if !USE_SWIFT_MAC_SCROLLERS
    auto appendIfHitTestable = [&](ScrollerMac& scroller, NativeScrollbarVisibility visibility) {
        RetainPtr hostLayer = scroller.hostLayer();
#else
    auto appendIfHitTestable = [&](ScrollbarOrientation orientation, NativeScrollbarVisibility visibility) {
        RetainPtr hostLayer = m_scrollerPair->hostLayer(orientation);
#endif
        if (!hostLayer)
            return;

        switch (visibility) {
        case NativeScrollbarVisibility::HiddenByStyle:
            return;
        case NativeScrollbarVisibility::ReplacedByCustomScrollbar:
            // The web process paints custom scrollbars into the host layer, and they are never overlay scrollbars.
            break;
        case NativeScrollbarVisibility::Visible:
            // The web process only hit-tests an overlay scrollbar while it is shown, which it learns about
            // through ScrollerMac::visibilityChanged(), so consult the same state here.
#if !USE_SWIFT_MAC_SCROLLERS
            if (usesOverlayScrollbars && !scroller.isVisible())
#else
            if (usesOverlayScrollbars && !m_scrollerPair->scrollers().isVisible(orientation))
#endif
                return;
            break;
        }

        layers.append(WTF::move(hostLayer));
    };

#if !USE_SWIFT_MAC_SCROLLERS
    appendIfHitTestable(m_scrollerPair->verticalScroller(), node->verticalNativeScrollbarVisibility());
    appendIfHitTestable(m_scrollerPair->horizontalScroller(), node->horizontalNativeScrollbarVisibility());
#else
    appendIfHitTestable(ScrollbarOrientation::Vertical, node->verticalNativeScrollbarVisibility());
    appendIfHitTestable(ScrollbarOrientation::Horizontal, node->horizontalNativeScrollbarVisibility());
#endif
    return layers;
}

} // namespace WebCore

#endif // PLATFORM(MAC)
