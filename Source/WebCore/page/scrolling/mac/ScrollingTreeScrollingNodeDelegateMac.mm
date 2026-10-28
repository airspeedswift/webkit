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

#import "ScrollingTreeScrollPhysicsClient.h"
#import "ScrollingTreeScrollPhysicsDelegateHolder.h"

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

void ScrollingTreeScrollPhysicsClient::emitRubberBandSignpost(bool isRubberBanding, IntSize stretch, bool isMainFrame)
{
    WTFEmitSignpostAlways(&delegate(), ScrollingPerformanceTestRubberBand, "%{public}s; top=%d right=%d bottom=%d left=%d; stretch=%d,%d; isMainFrame=%d",
        isRubberBanding ? "started" : "ended",
        stretch.height() < 0, stretch.width() > 0, stretch.height() > 0, stretch.width() < 0,
        stretch.width(), stretch.height(),
        isMainFrame);
}

void ScrollingTreeScrollingNodeDelegateMac::nodeWillBeDestroyed()
{
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
}

void ScrollingTreeScrollingNodeDelegateMac::updateFromStateNode(const ScrollingStateScrollingNode& scrollingStateNode)
{
    Ref horizontalScroller = m_scrollerPair->horizontalScroller();
    Ref verticalScroller = m_scrollerPair->verticalScroller();

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::PainterForScrollbar)) {
        RetainPtr horizontalScrollbar = scrollingStateNode.horizontalScrollerImp();
        RetainPtr verticalScrollbar = scrollingStateNode.verticalScrollerImp();
        if (horizontalScrollbar || verticalScrollbar) {
            m_scrollerPair->releaseReferencesToScrollerImpsOnTheMainThread();
            horizontalScroller->setScrollerImp(horizontalScrollbar);
            verticalScroller->setScrollerImp(verticalScrollbar);
        }
    }

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::ScrollbarHoverState))
        m_scrollerPair->mouseIsInScrollbar(scrollingStateNode.scrollbarHoverState());

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::HorizontalScrollbarLayer))
        horizontalScroller->setHostLayer(protect(static_cast<CALayer*>(scrollingStateNode.horizontalScrollbarLayer())));

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::VerticalScrollbarLayer))
        verticalScroller->setHostLayer(protect(static_cast<CALayer*>(scrollingStateNode.verticalScrollbarLayer())));

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::ScrollableAreaParams)) {
        horizontalScroller->setHiddenByStyle(scrollingStateNode.scrollableAreaParameters().horizontalNativeScrollbarVisibility);
        verticalScroller->setHiddenByStyle(scrollingStateNode.scrollableAreaParameters().verticalNativeScrollbarVisibility);
    }

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::ScrollbarEnabledState)) {
        auto scrollbarEnabledState = scrollingStateNode.scrollbarEnabledState();
        m_scrollerPair->horizontalScroller().setEnabled(scrollbarEnabledState.horizontalScrollbarIsEnabled);
        m_scrollerPair->verticalScroller().setEnabled(scrollbarEnabledState.verticalScrollbarIsEnabled);
    }

    if (scrollingStateNode.hasChangedProperty(ScrollingStateNode::Property::ScrollbarLayoutDirection)) {
        auto scrollbarLayoutDirection = scrollingStateNode.scrollbarLayoutDirection();
        horizontalScroller->setScrollbarLayoutDirection(scrollbarLayoutDirection);
        verticalScroller->setScrollbarLayoutDirection(scrollbarLayoutDirection);
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

    ThreadedScrollingTreeScrollingNodeDelegate::updateFromStateNode(scrollingStateNode);

#if HAVE(RUBBER_BANDING)
    if (m_pendingRubberbandingState) {
        m_physics->delegate.restoreRubberbandingState(ScrollingTreeScrollPhysicsClientState(*this).facade(), *m_pendingRubberbandingState);
        m_pendingRubberbandingState = std::nullopt;
    }
#endif
}

bool ScrollingTreeScrollingNodeDelegateMac::handleWheelEvent(const PlatformWheelEvent& wheelEvent)
{
    return m_physics->delegate.handleWheelEvent(ScrollingTreeScrollPhysicsClientState(*this).facade(), m_scrollerPair.ptr(), wheelEvent, wheelEvent.timestamp().secondsSinceEpoch().value());
}

void ScrollingTreeScrollingNodeDelegateMac::willDoProgrammaticScroll(const FloatPoint& targetPosition)
{
    m_physics->delegate.willDoProgrammaticScroll(ScrollingTreeScrollPhysicsClientState(*this).facade(), targetPosition);
}

void ScrollingTreeScrollingNodeDelegateMac::currentScrollPositionChanged()
{
    m_physics->delegate.currentScrollPositionChanged(ScrollingTreeScrollPhysicsClientState(*this).facade());
}

bool ScrollingTreeScrollingNodeDelegateMac::isRubberBandInProgress() const
{
    return m_physics->delegate.isRubberBandInProgress();
}

void ScrollingTreeScrollingNodeDelegateMac::startRubberBandSnapBack()
{
    m_physics->delegate.startRubberBandSnapBack(ScrollingTreeScrollPhysicsClientState(*this).facade());
}

void ScrollingTreeScrollingNodeDelegateMac::rubberBandTargetOffsetDidChange()
{
    m_physics->delegate.rubberBandTargetOffsetDidChange(ScrollingTreeScrollPhysicsClientState(*this).facade());
}

#if HAVE(RUBBER_BANDING)
std::optional<RubberbandingState> ScrollingTreeScrollingNodeDelegateMac::captureRubberbandingState() const
{
    // scrollingNode() is const here; the scroller pair holds the same node.
    RefPtr node = m_scrollerPair->node();
    RELEASE_ASSERT(node);
    RubberbandingState state;
    if (!m_physics->delegate.captureRubberbandingState(ScrollingTreeScrollPhysicsClientState(node.releaseNonNull()).facade(), state))
        return std::nullopt;
    return state;
}
#endif

void ScrollingTreeScrollingNodeDelegateMac::updateScrollbarPainters()
{
    m_physics->delegate.updateScrollbarPainters(m_scrollerPair.ptr());
}

void ScrollingTreeScrollingNodeDelegateMac::initScrollbars()
{
    m_scrollerPair->init();
}

void ScrollingTreeScrollingNodeDelegateMac::updateScrollbarLayers()
{
    m_scrollerPair->updateValues();
}

void ScrollingTreeScrollingNodeDelegateMac::handleWheelEventPhase(const PlatformWheelEventPhase wheelEventPhase)
{
    m_scrollerPair->handleWheelEventPhase(wheelEventPhase);
}

void ScrollingTreeScrollingNodeDelegateMac::viewWillStartLiveResize()
{
    return m_scrollerPair->viewWillStartLiveResize();
}

void ScrollingTreeScrollingNodeDelegateMac::viewWillEndLiveResize()
{
    return m_scrollerPair->viewWillEndLiveResize();
}

void ScrollingTreeScrollingNodeDelegateMac::viewSizeDidChange()
{
    return m_scrollerPair->contentsSizeChanged();
}

String ScrollingTreeScrollingNodeDelegateMac::scrollbarStateForOrientation(ScrollbarOrientation orientation) const
{
    return m_scrollerPair->scrollbarStateForOrientation(orientation);
}

Vector<RetainPtr<CALayer>, 2> ScrollingTreeScrollingNodeDelegateMac::hitTestableScrollbarLayers() const
{
    Ref node = scrollingNode();
    bool usesOverlayScrollbars = m_scrollerPair->scrollbarStyle() == ScrollbarStyle::Overlay;

    Vector<RetainPtr<CALayer>, 2> layers;
    auto appendIfHitTestable = [&](ScrollerMac& scroller, NativeScrollbarVisibility visibility) {
        RetainPtr hostLayer = scroller.hostLayer();
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
            if (usesOverlayScrollbars && !scroller.isVisible())
                return;
            break;
        }

        layers.append(WTF::move(hostLayer));
    };

    appendIfHitTestable(m_scrollerPair->verticalScroller(), node->verticalNativeScrollbarVisibility());
    appendIfHitTestable(m_scrollerPair->horizontalScroller(), node->horizontalNativeScrollbarVisibility());
    return layers;
}

} // namespace WebCore

#endif // PLATFORM(MAC)
