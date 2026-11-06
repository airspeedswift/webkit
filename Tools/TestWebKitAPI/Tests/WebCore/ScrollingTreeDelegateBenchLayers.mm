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

#import "config.h"

#if PLATFORM(MAC)

#import "ScrollingTreeDelegateRig.h"
#import <QuartzCore/QuartzCore.h>
#import <WebCore/ScrollingStateFixedNode.h>
#import <WebCore/ScrollingStateOverflowScrollProxyNode.h>
#import <WebCore/ScrollingStatePositionedNode.h>
#import <WebCore/ScrollingStateStickyNode.h>
#import <cstdlib>
#import <wtf/RetainPtr.h>

// The commit and layer-position paths of the nodes that are not scrolling nodes: fixed, sticky (with and without
// a separate viewport anchor layer) and positioned nodes and overflow scroll proxies, in the root, in an overflow
// scroller and in a subframe, with each commit's layers connected as the UI process connects them. The checksum
// covers every layer's position and bounds after each step as well as the rig's digest. Same output and
// WEBKIT_RUN_BENCHMARKS=1 line as ScrollingTreeDelegateBench.cpp; the rate is thousands of entries per second.

namespace TestWebKitAPI {

using namespace ScrollingTreeDelegate;

namespace {

// The layers a pass gives the tree. State nodes name a layer by identifier, as a commit from the web process
// does, and connect() hands the committed tree the layers, as RemoteScrollingCoordinatorProxyMac does. A new
// layer starts at (-1, -1), which no node sets.
class Layers {
public:
    std::optional<PlatformLayerIdentifier> make(FloatSize size, bool centred = false)
    {
        CALayer *layer = [CALayer layer];
        layer.anchorPoint = centred ? CGPointMake(0.5, 0.5) : CGPointZero;
        layer.bounds = CGRectMake(0, 0, size.width(), size.height());
        layer.position = CGPointMake(-1, -1);
        m_layers.push_back(layer);
        return PlatformLayerIdentifier { ObjectIdentifier<PlatformLayerIdentifierType>(m_layers.size()), ProcessIdentifier(1) };
    }

    void connect(ScrollingStateTree& stateTree) const
    {
        using Property = ScrollingStateNode::Property;
        auto layer = [&](const LayerRepresentation& representation) -> LayerRepresentation {
            auto id = representation.layerID();
            if (!id || !id->object().toUInt64() || id->object().toUInt64() > m_layers.size())
                return static_cast<ScrollingPlatformLayer*>(nullptr);
            return m_layers[id->object().toUInt64() - 1].get();
        };
        for (auto& node : stateTree.nodeMap().values()) {
            if (node->hasChangedProperty(Property::Layer))
                node->setLayer(layer(node->layer()));
            if (RefPtr scrolling = dynamicDowncast<ScrollingStateScrollingNode>(node)) {
                if (scrolling->hasChangedProperty(Property::ScrollContainerLayer))
                    scrolling->setScrollContainerLayer(layer(scrolling->scrollContainerLayer()));
                if (scrolling->hasChangedProperty(Property::ScrolledContentsLayer))
                    scrolling->setScrolledContentsLayer(layer(scrolling->scrolledContentsLayer()));
            }
            if (RefPtr sticky = dynamicDowncast<ScrollingStateStickyNode>(node)) {
                if (sticky->hasChangedProperty(Property::ViewportAnchorLayer))
                    sticky->setViewportAnchorLayer(layer(sticky->viewportAnchorLayer()));
            }
        }
    }

    void digest(Digest& digest) const
    {
        for (auto& layer : m_layers) {
            auto position = [layer.get() position];
            auto bounds = [layer.get() bounds];
            digest.f(position.x).f(position.y).f(bounds.origin.x).f(bounds.origin.y);
        }
    }

private:
    std::vector<RetainPtr<CALayer>> m_layers;
};

using AE = ViewportConstraints;

void addScrollingLayers(Session& session, Layers& layers, unsigned index, const NodeSetup& setup)
{
    Ref state = session.state(index);
    state->setScrollContainerLayer(layers.make(setup.viewport));
    state->setScrolledContentsLayer(layers.make(setup.contents));
}

void addFixed(Session& session, Layers& layers, ScrollingNodeID parent, FloatRect viewportAtLayout, FloatRect box, ViewportConstraints::AnchorEdges edges, FloatSize alignment = { })
{
    Ref state = downcast<ScrollingStateFixedNode>(session.stateNode(session.addNode(ScrollingNodeType::Fixed, parent)));
    FixedPositionViewportConstraints constraints;
    constraints.setAnchorEdges(edges);
    constraints.setAlignmentOffset(alignment);
    constraints.setViewportRectAtLastLayout(viewportAtLayout);
    constraints.setLayerPositionAtLastLayout(box.location());
    state->updateConstraints(constraints);
    state->setLayer(layers.make(box.size(), alignment != FloatSize()));
}

void addSticky(Session& session, Layers& layers, ScrollingNodeID parent, FloatRect constrainingRect, ViewportConstraints::AnchorEdges edges, FloatRect containingBlock, FloatRect stickyBox, bool clippingLayer)
{
    Ref state = downcast<ScrollingStateStickyNode>(session.stateNode(session.addNode(ScrollingNodeType::Sticky, parent)));
    StickyPositionViewportConstraints constraints;
    constraints.setAnchorEdges(edges);
    constraints.setLeftOffset(4);
    constraints.setRightOffset(4);
    constraints.setTopOffset(10);
    constraints.setBottomOffset(10);
    constraints.setConstrainingRectAtLastLayout(constrainingRect);
    constraints.setContainingBlockRect(containingBlock);
    constraints.setStickyBoxRect(stickyBox);
    constraints.setViewportRectAtLastLayout(constrainingRect);
    constraints.setLayerPositionAtLastLayout(stickyBox.location());
    state->updateConstraints(constraints);
    auto layer = layers.make(stickyBox.size());
    state->setLayer(layer);
    state->setViewportAnchorLayer(clippingLayer ? layers.make(stickyBox.size()) : layer);
}

// One pass: a page with fixed, sticky and positioned nodes and a proxy, scrolled by commits (as a rendering update
// moves scrollers), by gestures and by an animated scroll, with layer positions applied after each step.
void positionedStickyCommitPass(Session& session, Layers& layers, Digest& digest)
{
    static constexpr ViewportConstraints::AnchorEdges fixedEdges[] = {
        AE::AnchorEdgeLeft | AE::AnchorEdgeTop,
        AE::AnchorEdgeRight | AE::AnchorEdgeTop,
        AE::AnchorEdgeLeft | AE::AnchorEdgeBottom,
        AE::AnchorEdgeRight | AE::AnchorEdgeBottom,
    };
    static constexpr ViewportConstraints::AnchorEdges stickyEdges[] = {
        AE::AnchorEdgeTop,
        AE::AnchorEdgeBottom,
        AE::AnchorEdgeTop | AE::AnchorEdgeBottom,
        AE::AnchorEdgeLeft,
        AE::AnchorEdgeLeft | AE::AnchorEdgeRight | AE::AnchorEdgeTop,
        AE::AnchorEdgeLeft | AE::AnchorEdgeRight | AE::AnchorEdgeTop | AE::AnchorEdgeBottom,
    };
    session.setLayerConnector([&layers](ScrollingStateTree& stateTree) { layers.connect(stateTree); });
    auto step = [&] {
        session.applyLayerPositions();
        layers.digest(digest);
    };

    auto rootSetup = mainFrameSetup({ 0, 0 });
    rootSetup.contents = { 1600, 8000 };
    session.addRoot(rootSetup);
    addScrollingLayers(session, layers, 0, rootSetup);
    auto rootID = session.scrollingNodeID(0);
    FloatRect rootVisible { rootSetup.position, rootSetup.viewport };

    auto overflow = overflowSetup({ 0, 0 }, 3);
    overflow.contents = { 800, 3000 };
    unsigned overflowIndex = session.addOverflow(overflow, 0);
    addScrollingLayers(session, layers, overflowIndex, overflow);
    auto overflowID = session.scrollingNodeID(overflowIndex);
    FloatRect overflowVisible { overflow.position, overflow.viewport };

    NodeSetup subframeSetup;
    subframeSetup.viewport = { 300, 240 };
    subframeSetup.contents = { 300, 1800 };
    unsigned subframeIndex = session.addSubframe(subframeSetup, rootID);
    addScrollingLayers(session, layers, subframeIndex, subframeSetup);
    auto subframeID = session.scrollingNodeID(subframeIndex);
    FloatRect subframeVisible { { }, subframeSetup.viewport };

    for (unsigned i = 0; i < 8; ++i) {
        addFixed(session, layers, rootID, rootVisible, { 10.0f + 90 * i, 10.0f + 60 * (i % 4), 80, 40 }, fixedEdges[i % 4], i % 2 ? FloatSize { 40, 20 } : FloatSize { });
        addSticky(session, layers, rootID, rootVisible, stickyEdges[i % 6], { 0, 400.0f + 800 * i, 800, 1600 }, { 20, 600.0f + 800 * i, 300, 50 }, i % 4 == 2);
    }
    for (unsigned i = 0; i < 4; ++i) {
        addSticky(session, layers, overflowID, overflowVisible, stickyEdges[(i + 2) % 6], { 0, 200.0f + 600 * i, 400, 1200 }, { 10, 400.0f + 600 * i, 380, 30 }, i % 2);
        // A fixed node inside the overflow is still fixed to the root's viewport.
        addFixed(session, layers, overflowID, rootVisible, { 300, 20.0f * i, 100, 20 }, fixedEdges[(i + 2) % 4]);
    }
    addFixed(session, layers, subframeID, subframeVisible, { 0, 200, 300, 40 }, fixedEdges[3]);
    addSticky(session, layers, subframeID, subframeVisible, stickyEdges[0], { 0, 100, 300, 1000 }, { 0, 150, 300, 20 }, false);
    // Absolutely positioned elements in the overflow whose containing block is the root, and proxies mirroring the
    // overflow's scrolling in other stacking contexts.
    for (unsigned i = 0; i < 4; ++i) {
        Ref positioned = downcast<ScrollingStatePositionedNode>(session.stateNode(session.addNode(ScrollingNodeType::Positioned, rootID)));
        positioned->setRelatedOverflowScrollingNodes({ overflowID });
        positioned->updateConstraints(AbsolutePositionConstraints(FloatSize(), FloatPoint { 50.0f + 70 * i, 120 }));
        positioned->setLayer(layers.make({ 60, 60 }));
        Ref proxy = downcast<ScrollingStateOverflowScrollProxyNode>(session.stateNode(session.addNode(ScrollingNodeType::OverflowProxy, rootID)));
        proxy->setOverflowScrollingNode(overflowID);
        proxy->setLayer(layers.make({ 400, 300 }));
    }
    session.commit();
    step();

    Lcg random(15);
    for (unsigned update = 0; update < 120; ++update) {
        unsigned target = update % 3 ? (update % 3 == 1 ? overflowIndex : subframeIndex) : 0;
        session.requestScroll(0, ScrollRequestType::PositionUpdate, FloatPoint { 0, random.between(0, 7400) });
        session.requestScroll(target, ScrollRequestType::PositionUpdate, FloatPoint { 0, random.between(0, 2700) });
        if (update % 10 == 5)
            session.rootState()->setLayoutViewport({ { 0, random.between(0, 7000) }, rootSetup.viewport });
        session.commit();
        step();
        if (update % 8 == 3) {
            Session::Gesture gesture;
            float sign = random.chance(50) ? -1 : 1;
            gesture.deltas = decayingDeltas({ 0, sign * random.between(4, 30) }, 0.96f, random.range(6, 12));
            gesture.momentumDeltas = decayingDeltas({ 0, sign * random.between(10, 30) }, 0.92f, random.range(6, 12));
            gesture.gapBefore = 0.2;
            session.gesture(update % 16 == 3 ? 0 : overflowIndex, gesture);
            step();
            session.framesUntilIdle();
            step();
        }
        if (update % 20 == 9) {
            session.requestScroll(0, ScrollRequestType::AnimatedPositionUpdate, FloatPoint { 300, random.between(0, 7000) });
            session.commit();
            for (unsigned frame = 0; frame < 10; ++frame) {
                session.frame();
                step();
            }
            session.framesUntilIdle();
            step();
        }
    }
}

std::pair<uint64_t, uint64_t> runPositionedStickyCommit()
{
    Digest digest;
    uint64_t entries = 0;
    onScrollingThread([&] {
        Layers layers;
        {
            Session session(digest);
            positionedStickyCommitPass(session, layers, digest);
            entries = session.entries();
        }
    });
    drainMainThreadTasks();
    return { digest.value(), entries };
}

} // namespace

TEST(ScrollingTreeDelegateBench, PositionedStickyCommit)
{
    auto [checksum, entries] = runPositionedStickyCommit();
    EXPECT_EQ(checksum, 0x777ec3cbbb43ecbcull);

    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    static constexpr unsigned fullPasses = 750;
    uint64_t totalEntries = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < fullPasses; ++pass) {
        auto [passChecksum, passEntries] = runPositionedStickyCommit();
        EXPECT_EQ(passChecksum, checksum);
        totalEntries += passEntries;
    }
    double milliseconds = (MonotonicTime::now() - start).milliseconds();
    printf("PositionedStickyCommit: %.1f ms %.2f MB/s checksum=%016llx\n", milliseconds, totalEntries / milliseconds, static_cast<unsigned long long>(checksum));
}

} // namespace TestWebKitAPI

#endif // PLATFORM(MAC)
