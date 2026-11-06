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

// A scrolling tree of Mac frame and overflow scrolling nodes, with fixed, sticky and positioned nodes and
// overflow scroll proxies, driven through the tree's own entry points: state-tree commits, wheel events and
// display refreshes, with the scroll-animation clock replaced so a session is repeatable. The tree records the
// calls its nodes make on it. ScrollingTreeDelegateBench.cpp uses it.

#include <CoreFoundation/CoreFoundation.h>
#include <WebCore/FloatPoint.h>
#include <WebCore/FloatSize.h>
#include <WebCore/KeyboardScroll.h>
#include <WebCore/PlatformWheelEvent.h>
#include <WebCore/ScrollSnapOffsetsInfo.h>
#include <WebCore/ScrollTypes.h>
#include <WebCore/ScrollingCoordinatorTypes.h>
#include <WebCore/ScrollingEffectsClock.h>
#include <WebCore/ScrollingStateFrameScrollingNode.h>
#include <WebCore/ScrollingStateOverflowScrollingNode.h>
#include <WebCore/ScrollingStateTree.h>
#include <WebCore/ScrollingThread.h>
#include <WebCore/ScrollingTree.h>
#include <WebCore/ScrollingTreeFixedNodeCocoa.h>
#include <WebCore/ScrollingTreeFrameScrollingNodeMac.h>
#include <WebCore/ScrollingTreeOverflowScrollProxyNodeCocoa.h>
#include <WebCore/ScrollingTreeOverflowScrollingNodeMac.h>
#include <WebCore/ScrollingTreePositionedNodeCocoa.h>
#include <WebCore/ScrollingTreeScrollingNode.h>
#include <WebCore/ScrollingTreeStickyNodeCocoa.h>
#include <WebCore/WheelEventTestMonitor.h>
#include <bit>
#include <cstdint>
#include <optional>
#include <vector>
#include <wtf/MonotonicTime.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/threads/BinarySemaphore.h>

namespace TestWebKitAPI {
namespace ScrollingTreeDelegate {

using namespace WebCore;

// MARK: - Digest

// FNV-1a over everything a session observes, in the order it observes it.
class Digest {
public:
    uint64_t value() const { return m_hash; }

    void bytes(const void* data, size_t size)
    {
        auto* p = static_cast<const uint8_t*>(data);
        for (size_t i = 0; i < size; ++i) {
            m_hash ^= p[i];
            m_hash *= 1099511628211ull;
        }
    }

    Digest& u(uint64_t value)
    {
        bytes(&value, sizeof(value));
        return *this;
    }

    Digest& f(float value) { return u(std::bit_cast<uint32_t>(value)); }
    Digest& b(bool value) { return u(value ? 1 : 0); }
    Digest& pt(FloatPoint value) { return f(value.x()).f(value.y()); }
    Digest& optu(std::optional<unsigned> value) { return value ? u(1).u(*value) : u(0); }

private:
    uint64_t m_hash { 14695981039346656037ull };
};

// MARK: - Inputs

class Lcg {
public:
    explicit Lcg(uint64_t seed)
        : m_state(seed * 6364136223846793005ull + 1442695040888963407ull)
    {
    }

    uint32_t next()
    {
        m_state = m_state * 6364136223846793005ull + 1442695040888963407ull;
        return static_cast<uint32_t>(m_state >> 33);
    }

    // [0, 1)
    float unit() { return static_cast<float>(next() >> 8) / static_cast<float>(1 << 23); }
    // [low, high]
    int range(int low, int high) { return low + static_cast<int>(next() % static_cast<uint32_t>(high - low + 1)); }
    float between(float low, float high) { return low + (high - low) * unit(); }
    bool chance(unsigned percent) { return next() % 100 < percent; }

private:
    uint64_t m_state;
};

struct WheelDescription {
    PlatformWheelEventPhase phase { PlatformWheelEventPhase::None };
    PlatformWheelEventPhase momentumPhase { PlatformWheelEventPhase::None };
    FloatSize delta;
    PlatformWheelEventGranularity granularity { PlatformWheelEventGranularity::ScrollByPixelWheelEvent };
    bool hasPreciseScrollingDeltas { true };
};

// Sets the fields WebKit's own event conversion sets.
class RigWheelEvent : public PlatformWheelEvent {
public:
    RigWheelEvent(const WheelDescription& description, MonotonicTime timestamp, double interval)
    {
        m_timestamp = timestamp;
        m_phase = description.phase;
        m_momentumPhase = description.momentumPhase;
        m_deltaX = description.delta.width();
        m_deltaY = description.delta.height();
        m_wheelTicksX = description.delta.width() * 0.1f;
        m_wheelTicksY = description.delta.height() * 0.1f;
        m_unacceleratedScrollingDeltaX = description.hasPreciseScrollingDeltas ? description.delta.width() * 0.75f : description.delta.width();
        m_unacceleratedScrollingDeltaY = description.hasPreciseScrollingDeltas ? description.delta.height() * 0.75f : description.delta.height();
        m_scrollingVelocity = interval > 0 ? description.delta.scaled(static_cast<float>(1 / interval)) : FloatSize();
        m_granularity = description.granularity;
        m_hasPreciseScrollingDeltas = description.hasPreciseScrollingDeltas;
        m_ioHIDEventTimestamp = m_timestamp;
        m_rawPlatformDelta = description.delta;
    }
};

inline ScrollingNodeID nodeID(uint64_t value)
{
    return ScrollingNodeID(ObjectIdentifier<ScrollingNodeIDType>(value), ProcessIdentifier(1));
}

inline ScrollableAreaParameters scrollableParameters(ScrollElasticity horizontal = ScrollElasticity::Allowed, ScrollElasticity vertical = ScrollElasticity::Allowed, bool allowsHorizontal = true, bool allowsVertical = true)
{
    ScrollableAreaParameters parameters;
    parameters.horizontalScrollElasticity = horizontal;
    parameters.verticalScrollElasticity = vertical;
    parameters.allowsHorizontalScrolling = allowsHorizontal;
    parameters.allowsVerticalScrolling = allowsVertical;
    return parameters;
}

struct SnapDescription {
    std::vector<float> horizontal;
    std::vector<float> vertical;
    float areaLength { 300 };
    ScrollSnapStrictness strictness { ScrollSnapStrictness::Mandatory };
    std::optional<unsigned> stopAlways;
    bool areasLargerThanViewport { false };
};

inline FloatScrollSnapOffsetsInfo snapOffsets(const SnapDescription& description)
{
    FloatScrollSnapOffsetsInfo info;
    info.strictness = description.strictness;
    auto append = [&](const std::vector<float>& offsets, ScrollEventAxis axis) {
        auto& list = axis == ScrollEventAxis::Vertical ? info.verticalSnapOffsets : info.horizontalSnapOffsets;
        for (unsigned i = 0; i < offsets.size(); ++i) {
            size_t areaIndex = info.snapAreas.size();
            float position = offsets[i];
            info.snapAreas.append(axis == ScrollEventAxis::Vertical ? FloatRect(0, position, 400, description.areaLength) : FloatRect(position, 0, description.areaLength, 400));
            info.snapAreasIDs.append(NodeIdentifier(areaIndex + 1));
            SnapOffset<float> offset { position, description.stopAlways && *description.stopAlways == i ? ScrollSnapStop::Always : ScrollSnapStop::Normal, false, false, false, NodeIdentifier(areaIndex + 1), { } };
            offset.hasSnapAreaLargerThanViewport = description.areasLargerThanViewport;
            offset.snapAreaIndices.append(areaIndex);
            list.append(WTF::move(offset));
        }
    };
    append(description.horizontal, ScrollEventAxis::Horizontal);
    append(description.vertical, ScrollEventAxis::Vertical);
    return info;
}

inline std::vector<float> evenlySpaced(float start, float spacing, unsigned count)
{
    std::vector<float> result;
    for (unsigned i = 0; i < count; ++i)
        result.push_back(start + spacing * i);
    return result;
}

inline std::vector<FloatSize> decayingDeltas(FloatSize first, float decay, unsigned count)
{
    std::vector<FloatSize> result;
    auto delta = first;
    for (unsigned i = 0; i < count; ++i) {
        result.push_back(delta);
        delta = delta.scaled(decay);
    }
    return result;
}

inline KeyboardScroll keyboardScroll(ScrollDirection direction, ScrollGranularity granularity, float distance)
{
    // As KeyboardScrollingAnimator::makeKeyboardScroll() builds it.
    KeyboardScroll scroll;
    scroll.offset = unitVectorForScrollDirection(direction).scaled(distance);
    scroll.granularity = granularity;
    scroll.direction = direction;
    scroll.maximumVelocity = scroll.offset.scaled(KeyboardScrollParameters::parameters().maximumVelocityMultiplier);
    scroll.force = scroll.maximumVelocity.scaled(KeyboardScrollParameters::parameters().springMass / KeyboardScrollParameters::parameters().timeToMaximumVelocity);
    return scroll;
}

// MARK: - Threads

// Wheel events and display refreshes reach the tree on the scrolling thread, and the timers its nodes' delegates
// create run on that thread's run loop, so a session runs there. Runs the function there and waits for it and for
// the tasks it queued there: a session's end queues its nodes' snap timer destructions and its tree's release (see
// ~Session), and the thread runs its tasks in order, so the signal goes in a task queued after them.
inline void onScrollingThread(Function<void()>&& function)
{
    BinarySemaphore done;
    ScrollingThread::dispatch([&] {
        function();
        ScrollingThread::dispatch([&] {
            done.signal();
        });
    });
    done.wait();
}

// Runs the work the scrollbars queued for the main thread.
inline void drainMainThreadTasks()
{
    while (CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true) == kCFRunLoopRunHandledSource) { }
}

// MARK: - Clock

struct RigClock {
    static double& now()
    {
        static double seconds { 1000 };
        return seconds;
    }

    static MonotonicTime read() { return MonotonicTime::fromRawSeconds(now()); }
};

// MARK: - Tree

// What the tree records of its nodes' calls, one tag per kind.
enum class TreeCall : uint8_t {
    ActiveSnapIndices = 1,
    SnapIndicesDidChange,
    DeferTestCompletion,
    RemoveTestCompletionDeferral,
    RubberBanding,
    DidScroll,
    AnimatedScrollChanged,
    WillStartAnimatedScroll,
    DidStopAnimatedScroll,
    WillStartWheelEventScroll,
    DidStopWheelEventScroll,
    WheelEventPhase,
    ScrollRequest,
    KeyboardScrollRequest,
    DidHandleScrollRequest,
    ReceivedPhases,
    BeginScrollSnapping,
    EndScrollSnapping,
};

class RigScrollingTree final : public ScrollingTree {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(RigScrollingTree);
public:
    static Ref<RigScrollingTree> create(Digest& digest) { return adoptRef(*new RigScrollingTree(digest)); }

    void setWheelTarget(std::optional<ScrollingNodeID> target) { m_wheelTarget = target; }

    void setRefreshController(bool hasRefreshController, float topScrollStretch, float snappingThreshold)
    {
        m_hasRefreshController = hasRefreshController;
        m_topScrollStretch = topScrollStretch;
        m_snappingThreshold = snappingThreshold;
    }

    // As ThreadedScrollingTree does on the scrolling thread after a commit.
    void startPendingScrollAnimations()
    {
        Locker locker { m_treeLock };
        auto animations = std::exchange(m_pendingScrollAnimations, { });
        for (auto& [id, request] : animations) {
            if (RefPtr node = dynamicDowncast<ScrollingTreeScrollingNode>(nodeForID(id)))
                node->startAnimatedScrollToPosition(request.destinationPosition(node->currentScrollPosition()), request.animationCurve);
        }
        auto keyboardScrolls = std::exchange(m_pendingKeyboardScrolls, { });
        for (auto& [id, request] : keyboardScrolls) {
            if (RefPtr node = dynamicDowncast<ScrollingTreeScrollingNode>(nodeForID(id)))
                node->handleKeyboardScrollRequest(request);
        }
    }

    // As ThreadedScrollingTree::displayDidRefreshOnScrollingThread() services animations.
    void displayDidRefreshAt(MonotonicTime now)
    {
        // As there, a Ref to the tree is taken before its lock.
        Ref protectedThis { *this };
        Locker locker { m_treeLock };
        serviceScrollAnimations(now);
    }

    void disableLatching() { m_allowLatching = false; }

private:
    explicit RigScrollingTree(Digest& digest)
        : m_digest(digest)
    {
    }

    Digest& record(TreeCall call, ScrollingNodeID id)
    {
        return m_digest.u(static_cast<uint8_t>(call)).u(id.object().toUInt64());
    }

    Ref<ScrollingTreeNode> createScrollingTreeNode(ScrollingNodeType nodeType, ScrollingNodeID id) final
    {
        switch (nodeType) {
        case ScrollingNodeType::Overflow:
            return ScrollingTreeOverflowScrollingNodeMac::create(*this, id);
        case ScrollingNodeType::OverflowProxy:
            return ScrollingTreeOverflowScrollProxyNodeCocoa::create(*this, id);
        case ScrollingNodeType::Fixed:
            return ScrollingTreeFixedNodeCocoa::create(*this, id);
        case ScrollingNodeType::Sticky:
            return ScrollingTreeStickyNodeCocoa::create(*this, id);
        case ScrollingNodeType::Positioned:
            return ScrollingTreePositionedNodeCocoa::create(*this, id);
        default:
            return ScrollingTreeFrameScrollingNodeMac::create(*this, nodeType, id);
        }
    }

    RefPtr<ScrollingTreeNode> scrollingNodeForPoint(FloatPoint) final
    {
        if (m_wheelTarget)
            return nodeForID(*m_wheelTarget);
        return rootNode();
    }

    void handleWheelEventPhase(ScrollingNodeID id, PlatformWheelEventPhase phase) final { record(TreeCall::WheelEventPhase, id).u(static_cast<uint8_t>(phase)); }
    void currentSnapPointIndicesDidChange(ScrollingNodeID id, std::optional<unsigned> horizontal, std::optional<unsigned> vertical) final { record(TreeCall::SnapIndicesDidChange, id).optu(horizontal).optu(vertical); }
    void setActiveScrollSnapIndices(ScrollingNodeID id, std::optional<unsigned> horizontal, std::optional<unsigned> vertical) final { record(TreeCall::ActiveSnapIndices, id).optu(horizontal).optu(vertical); }
    void deferWheelEventTestCompletionForReason(ScrollingNodeID id, WheelEventTestMonitor::DeferReason reason) final { record(TreeCall::DeferTestCompletion, id).u(static_cast<uint64_t>(reason)); }
    void removeWheelEventTestCompletionDeferralForReason(ScrollingNodeID id, WheelEventTestMonitor::DeferReason reason) final { record(TreeCall::RemoveTestCompletionDeferral, id).u(static_cast<uint64_t>(reason)); }

    void setRubberBandingInProgressForNode(ScrollingNodeID id, bool inProgress) final
    {
        record(TreeCall::RubberBanding, id).b(inProgress);
        ScrollingTree::setRubberBandingInProgressForNode(id, inProgress);
    }

    void scrollingTreeNodeDidScroll(ScrollingTreeScrollingNode& node, ScrollingLayerPositionAction action) final
    {
        record(TreeCall::DidScroll, node.scrollingNodeID()).pt(node.currentScrollPosition()).u(static_cast<uint8_t>(action));
        ScrollingTree::scrollingTreeNodeDidScroll(node, action);
    }

    void hasNodeWithAnimatedScrollChanged(bool hasNodeWithAnimatedScroll) final { m_digest.u(static_cast<uint8_t>(TreeCall::AnimatedScrollChanged)).b(hasNodeWithAnimatedScroll); }
    void scrollingTreeNodeWillStartAnimatedScroll(ScrollingTreeScrollingNode& node) final { record(TreeCall::WillStartAnimatedScroll, node.scrollingNodeID()); }
    void scrollingTreeNodeDidStopAnimatedScroll(ScrollingTreeScrollingNode& node) final { record(TreeCall::DidStopAnimatedScroll, node.scrollingNodeID()); }
    void scrollingTreeNodeWillStartWheelEventScroll(ScrollingTreeScrollingNode& node) final { record(TreeCall::WillStartWheelEventScroll, node.scrollingNodeID()); }
    void scrollingTreeNodeDidStopWheelEventScroll(ScrollingTreeScrollingNode& node) final { record(TreeCall::DidStopWheelEventScroll, node.scrollingNodeID()); }
    void scrollingTreeNodeDidBeginScrollSnapping(ScrollingNodeID id) final { record(TreeCall::BeginScrollSnapping, id); }
    void scrollingTreeNodeDidEndScrollSnapping(ScrollingNodeID id) final { record(TreeCall::EndScrollSnapping, id); }
    void receivedWheelEventWithPhases(PlatformWheelEventPhase phase, PlatformWheelEventPhase momentumPhase) final { m_digest.u(static_cast<uint8_t>(TreeCall::ReceivedPhases)).u(static_cast<uint8_t>(phase)).u(static_cast<uint8_t>(momentumPhase)); }

    // As ThreadedScrollingTree: animated scrolls and keyboard scrolls start after the commit.
    RequestsScrollHandling scrollingTreeNodeRequestsScroll(ScrollingNodeID id, const RequestedScrollData& request) final
    {
        record(TreeCall::ScrollRequest, id).u(static_cast<uint8_t>(request.requestType));
        if (!isAnimatedUpdate(request.requestType))
            return RequestsScrollHandling::Unhandled;
        for (auto& pending : m_pendingScrollAnimations) {
            if (pending.first == id) {
                pending.second = request;
                return RequestsScrollHandling::Handled;
            }
        }
        m_pendingScrollAnimations.emplace_back(id, request);
        return RequestsScrollHandling::Handled;
    }

    bool scrollingTreeNodeRequestsKeyboardScroll(ScrollingNodeID id, const RequestedKeyboardScrollData& request) final
    {
        record(TreeCall::KeyboardScrollRequest, id).u(static_cast<uint8_t>(request.action));
        for (auto& pending : m_pendingKeyboardScrolls) {
            if (pending.first == id) {
                pending.second = request;
                return true;
            }
        }
        m_pendingKeyboardScrolls.emplace_back(id, request);
        return true;
    }

    void didHandleScrollRequestForNode(ScrollingNodeID id, ScrollRequestType type, FloatPoint position, ShouldFireScrollEnd fireScrollEnd, Markable<ScrollRequestIdentifier>) final
    {
        record(TreeCall::DidHandleScrollRequest, id).u(static_cast<uint8_t>(type)).pt(position).u(static_cast<uint8_t>(fireScrollEnd));
    }

    float topScrollStretchForRefreshController() const final { return m_topScrollStretch; }
    float refreshControllerSnappingThreshold() const final { return m_snappingThreshold; }
    bool hasRefreshController() const final { return m_hasRefreshController; }

    Digest& m_digest;
    std::optional<ScrollingNodeID> m_wheelTarget;
    std::vector<std::pair<ScrollingNodeID, RequestedScrollData>> m_pendingScrollAnimations;
    std::vector<std::pair<ScrollingNodeID, RequestedKeyboardScrollData>> m_pendingKeyboardScrolls;
    bool m_hasRefreshController { false };
    float m_topScrollStretch { 0 };
    float m_snappingThreshold { 0 };
};

// MARK: - Session

struct NodeSetup {
    FloatSize viewport { 800, 600 };
    FloatSize contents { 1200, 20000 };
    FloatPoint position;
    IntPoint origin;
    ScrollableAreaParameters parameters { scrollableParameters() };
};

// One tree, its state tree and the clock, through one scroll session. Node 0 is the root. After each step it
// digests each node's scroll position and user-scroll and snap flags.
class Session {
public:
    static constexpr double frameInterval = 1.0 / 60;

    explicit Session(Digest& digest, double startTime = 1000)
        : m_digest(digest)
        , m_tree(RigScrollingTree::create(digest))
    {
        RigClock::now() = startTime;
        setScrollingEffectsClockForTesting(RigClock::read);
        m_tree->disableLatching();
    }

    ~Session()
    {
        // Removing the nodes does not stop their timers: each node's delegate hands its snap timer to
        // ScrollingThread::dispatch for destruction still armed (ThreadedScrollingTreeScrollingNodeDelegate::
        // destroyTimer), and a timer that comes due before its destruction runs, locking its node's tree. So the
        // tree is released by a task queued after those destructions, which onScrollingThread() waits for.
        m_stateTree = makeUnique<ScrollingStateTree>();
        commit();
        setScrollingEffectsClockForTesting(nullptr);
        ScrollingThread::dispatch([tree = WTF::move(m_tree)] { });
    }

    RigScrollingTree& tree() { return m_tree.get(); }

    // A session starts with latching off; a shape that measures latching starts again on a new tree, which allows
    // latching, before it adds any nodes.
    void enableLatching() { m_tree = RigScrollingTree::create(m_digest); }
    uint64_t entries() const { return m_entries; }
    size_t nodeCount() const { return m_nodes.size(); }

    unsigned addRoot(const NodeSetup& setup, ScrollingNodeType type = ScrollingNodeType::MainFrame)
    {
        auto id = nodeID(m_nextID++);
        m_stateTree->insertNode(type, id, std::nullopt, 0);
        m_nodes = { id };
        Ref root = rootState();
        root->setAsyncFrameOrOverflowScrollingEnabled(true);
        root->setFrameScaleFactor(1);
        root->setLayoutViewport(FloatRect(setup.position, setup.viewport));
        apply(0, setup);
        return 0;
    }

    unsigned addOverflow(const NodeSetup& setup, unsigned parent = 0)
    {
        auto id = nodeID(m_nextID++);
        m_stateTree->insertNode(ScrollingNodeType::Overflow, id, m_nodes[parent], notFound);
        m_nodes.push_back(id);
        apply(m_nodes.size() - 1, setup);
        return m_nodes.size() - 1;
    }

    void apply(unsigned index, const NodeSetup& setup)
    {
        Ref node = state(index);
        node->setScrollableAreaSize(setup.viewport);
        node->setTotalContentsSize(setup.contents);
        node->setReachableContentsSize(setup.contents);
        node->setScrollOrigin(setup.origin);
        node->setScrollPosition(setup.position);
        node->setScrollableAreaParameters(setup.parameters);
    }

    // A subframe's frame scrolling node under any node, as one of the session's scrolling nodes.
    unsigned addSubframe(const NodeSetup& setup, ScrollingNodeID parent)
    {
        auto id = nodeID(m_nextID++);
        m_stateTree->insertNode(ScrollingNodeType::Subframe, id, parent, notFound);
        m_nodes.push_back(id);
        Ref frame = downcast<ScrollingStateFrameScrollingNode>(stateNode(id));
        frame->setAsyncFrameOrOverflowScrollingEnabled(true);
        frame->setFrameScaleFactor(1);
        frame->setLayoutViewport(FloatRect(setup.position, setup.viewport));
        apply(m_nodes.size() - 1, setup);
        return m_nodes.size() - 1;
    }

    // A node that is not one of the session's scrolling nodes (a fixed, sticky or positioned node, or an overflow
    // scroll proxy) under any node, last among its siblings.
    ScrollingNodeID addNode(ScrollingNodeType type, ScrollingNodeID parent)
    {
        auto id = nodeID(m_nextID++);
        m_stateTree->insertNode(type, id, parent, notFound);
        return id;
    }

    // Moves a node and its descendants under another parent, as a layout that changes containing blocks does.
    void reparent(ScrollingNodeID id, ScrollingNodeID parent) { m_stateTree->insertNode(m_stateTree->stateNodeForID(id)->nodeType(), id, parent, notFound); }

    ScrollingNodeID scrollingNodeID(unsigned index) const { return m_nodes[index]; }
    Ref<ScrollingStateNode> stateNode(ScrollingNodeID id) { return m_stateTree->stateNodeForID(id).releaseNonNull(); }

    Ref<ScrollingStateScrollingNode> state(unsigned index) { return downcast<ScrollingStateScrollingNode>(m_stateTree->stateNodeForID(m_nodes[index]).releaseNonNull()); }
    Ref<ScrollingStateFrameScrollingNode> rootState() { return m_stateTree->rootStateNode().releaseNonNull(); }

    RefPtr<ScrollingTreeScrollingNode> node(unsigned index) { return dynamicDowncast<ScrollingTreeScrollingNode>(m_tree->nodeForID(m_nodes[index])); }

    // Called on each committed state tree before the tree takes it, as the UI process connects the layer identifiers
    // a commit carries to its layers. With a connector set, commits carry layer identifiers.
    void setLayerConnector(Function<void(ScrollingStateTree&)>&& connector) { m_layerConnector = WTF::move(connector); }

    void commit()
    {
        auto stateTree = m_stateTree->commit(m_layerConnector ? LayerRepresentation::PlatformLayerIDRepresentation : LayerRepresentation::PlatformLayerRepresentation);
        if (m_layerConnector)
            m_layerConnector(*stateTree);
        stateTree->setRootFrameIdentifier(FrameIdentifier(1));
        m_tree->commitTreeState(WTF::move(stateTree));
        m_tree->startPendingScrollAnimations();
        ++m_entries;
        observe();
    }

    void requestScroll(unsigned index, ScrollRequestType type, Variant<FloatPoint, FloatSize> positionOrDelta, ScrollType scrollType = ScrollType::Programmatic, ScrollClamping clamping = ScrollClamping::Clamped)
    {
        state(index)->setRequestedScrollData({ type, positionOrDelta, { }, scrollType, clamping, ScrollbarRevealBehavior::Default });
    }

    void requestKeyboardScroll(unsigned index, KeyboardScrollAction action, std::optional<KeyboardScroll> scroll = std::nullopt)
    {
        state(index)->setKeyboardScrollData({ action, scroll });
    }

    WheelEventHandlingResult wheel(unsigned target, const WheelDescription& description, double gap = 1.0 / 120)
    {
        RigClock::now() += gap;
        RigWheelEvent event(description, RigClock::read(), gap);
        m_tree->setWheelTarget(m_nodes[target]);
        auto steps = m_tree->determineWheelEventProcessing(event);
        auto result = m_tree->handleWheelEvent(event, steps);
        ++m_entries;
        m_digest.u(result.steps.toRaw()).b(result.wasHandled);
        observe();
        return result;
    }

    void frame()
    {
        RigClock::now() += frameInterval;
        m_tree->displayDidRefreshAt(RigClock::read());
        ++m_entries;
        observe();
    }

    // As the tree's owner does after a commit and on a display refresh: moves the nodes' layers.
    void applyLayerPositions() { m_tree->applyLayerPositions(); }

    // Runs the scrolling thread's run loop until the discrete scroll snap and scrollend timers the nodes started have
    // fired. Their 100 ms delay is in real time, not on RigClock, so this runs the run loop in 10 ms slices until no
    // timer due within 150 ms of the call remains. After 2 s it stops and records that in the digest.
    void fireDiscreteScrollTimers()
    {
        auto runLoop = CFRunLoopGetCurrent();
        auto start = CFAbsoluteTimeGetCurrent();
        auto due = start + 0.15;
        auto limit = start + 2;
        while (true) {
            auto next = CFRunLoopGetNextTimerFireDate(runLoop, kCFRunLoopDefaultMode);
            if (!next || next > due)
                break;
            if (CFAbsoluteTimeGetCurrent() >= limit) {
                m_digest.u(~0ull);
                break;
            }
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, false);
        }
        ++m_entries;
        observe();
    }

    // Frames until no node animates, at most limit of them.
    unsigned framesUntilIdle(unsigned limit = 600)
    {
        unsigned count = 0;
        while (count < limit && m_tree->hasNodeWithActiveScrollAnimations()) {
            frame();
            ++count;
        }
        m_digest.u(count);
        return count;
    }

    // A trackpad gesture: MayBegin, Began, Changed..., Ended, then momentum Began, Changed..., Ended.
    struct Gesture {
        std::vector<FloatSize> deltas;
        std::vector<FloatSize> momentumDeltas;
        double interval { 1.0 / 120 };
        double gapBefore { 0.3 };
        bool mayBegin { true };
        bool cancelled { false };
        bool framesBetweenEvents { true };
    };

    void gesture(unsigned target, const Gesture& gesture)
    {
        using Phase = PlatformWheelEventPhase;
        bool first = true;
        auto emit = [&](Phase phase, Phase momentumPhase, FloatSize delta) {
            wheel(target, { phase, momentumPhase, delta }, first ? gesture.gapBefore : gesture.interval);
            first = false;
            if (gesture.framesBetweenEvents)
                frame();
        };
        if (gesture.mayBegin)
            emit(Phase::MayBegin, Phase::None, { });
        for (size_t i = 0; i < gesture.deltas.size(); ++i)
            emit(i ? Phase::Changed : Phase::Began, Phase::None, gesture.deltas[i]);
        emit(gesture.cancelled ? Phase::Cancelled : Phase::Ended, Phase::None, { });
        if (gesture.cancelled || gesture.momentumDeltas.empty())
            return;
        for (size_t i = 0; i < gesture.momentumDeltas.size(); ++i)
            emit(Phase::None, i ? Phase::Changed : Phase::Began, gesture.momentumDeltas[i]);
        emit(Phase::None, Phase::Ended, { });
    }

    void observe()
    {
        for (auto id : m_nodes) {
            RefPtr node = dynamicDowncast<ScrollingTreeScrollingNode>(m_tree->nodeForID(id));
            if (!node) {
                m_digest.u(0);
                continue;
            }
            m_digest.pt(node->currentScrollPosition()).b(node->isUserScrollInProgress()).b(node->isScrollSnapInProgress());
        }
    }

    // Replaces the root with a new main frame node, as a navigation does, keeping the overflow nodes.
    void replaceRoot(const NodeSetup& rootSetup, const std::vector<NodeSetup>& overflowSetups)
    {
        auto overflowCount = m_nodes.size() - 1;
        auto oldOverflows = std::vector<ScrollingNodeID>(m_nodes.begin() + 1, m_nodes.end());
        addRoot(rootSetup);
        for (size_t i = 0; i < overflowCount; ++i) {
            m_stateTree->insertNode(ScrollingNodeType::Overflow, oldOverflows[i], m_nodes[0], notFound);
            m_nodes.push_back(oldOverflows[i]);
            apply(m_nodes.size() - 1, i < overflowSetups.size() ? overflowSetups[i] : NodeSetup { });
        }
    }

private:
    Digest& m_digest;
    Ref<RigScrollingTree> m_tree;
    std::unique_ptr<ScrollingStateTree> m_stateTree { makeUnique<ScrollingStateTree>() };
    std::vector<ScrollingNodeID> m_nodes;
    Function<void(ScrollingStateTree&)> m_layerConnector;
    uint64_t m_nextID { 1 };
    uint64_t m_entries { 0 };
};

// MARK: - Benchmark shapes
//
// Each shape is one pass of a session on a new tree. The benchmark runs it once by default and many times in
// its full run.

inline NodeSetup mainFrameSetup(FloatPoint position)
{
    NodeSetup setup;
    setup.position = position;
    return setup;
}

inline NodeSetup overflowSetup(FloatPoint position, unsigned variant)
{
    NodeSetup setup;
    setup.viewport = { 400, 300 };
    setup.contents = { 400.0f + 200 * (variant % 3), 3000.0f + 1000 * variant };
    setup.position = position;
    setup.parameters = scrollableParameters(ScrollElasticity::Automatic, variant % 2 ? ScrollElasticity::Allowed : ScrollElasticity::Automatic, variant % 3, true);
    return setup;
}

inline void trackpadGestureShape(Session& session)
{
    session.addRoot(mainFrameSetup({ 200, 8000 }));
    session.commit();
    Lcg random(4);
    for (unsigned i = 0; i < 24; ++i) {
        Session::Gesture gesture;
        float sign = i % 2 ? -1 : 1;
        gesture.deltas = decayingDeltas({ random.between(-2, 2), sign * random.between(4, 30) }, 0.97f, random.range(10, 30));
        gesture.momentumDeltas = decayingDeltas({ 0, sign * random.between(10, 40) }, 0.92f, random.range(20, 60));
        session.gesture(0, gesture);
        session.framesUntilIdle();
    }
}

inline void rubberBandAtEdgeShape(Session& session)
{
    auto setup = mainFrameSetup({ 0, 0 });
    session.addRoot(setup);
    session.commit();
    Lcg random(5);
    for (unsigned i = 0; i < 16; ++i) {
        // Alternate the elasticity, and every fourth pull has a refresh controller pulling too.
        setup.parameters = scrollableParameters(i % 2 ? ScrollElasticity::Automatic : ScrollElasticity::Allowed, i % 2 ? ScrollElasticity::Automatic : ScrollElasticity::Allowed);
        session.apply(0, setup);
        session.requestScroll(0, ScrollRequestType::PositionUpdate, FloatPoint { });
        session.commit();
        session.tree().setRefreshController(i % 4 == 3, i % 4 == 3 ? 40 : 0, i % 4 == 3 ? 60 : 0);
        Session::Gesture gesture;
        // Pulling down past the top edge, and every third pull also past the left edge.
        gesture.deltas = decayingDeltas({ i % 3 ? 0 : random.between(4, 12), random.between(8, 30) }, 0.95f, random.range(8, 20));
        gesture.gapBefore = 0.2;
        session.gesture(0, gesture);
        session.framesUntilIdle();
    }
    session.tree().setRefreshController(false, 0, 0);
}

inline void scrollSnapGestureShape(Session& session)
{
    auto setup = mainFrameSetup({ 0, 6000 });
    session.addRoot(setup);
    session.state(0)->setSnapOffsetsInfo(snapOffsets({ evenlySpaced(0, 300, 50), evenlySpaced(0, 300, 50), 300, ScrollSnapStrictness::Mandatory, std::nullopt }));
    session.commit();
    Lcg random(6);
    for (unsigned i = 0; i < 16; ++i) {
        Session::Gesture gesture;
        float sign = i % 2 ? -1 : 1;
        gesture.deltas = decayingDeltas({ random.between(-6, 6), sign * random.between(4, 24) }, 0.96f, random.range(8, 24));
        if (i % 4 != 3)
            gesture.momentumDeltas = decayingDeltas({ 0, sign * random.between(10, 30) }, 0.9f, random.range(10, 30));
        session.gesture(0, gesture);
        session.framesUntilIdle();
    }
}

inline void stateCommitsShape(Session& session)
{
    session.addRoot(mainFrameSetup({ 0, 1000 }));
    for (unsigned i = 0; i < 4; ++i)
        session.addOverflow(overflowSetup({ 0, 100.0f * i }, i));
    session.commit();
    Lcg random(7);
    for (unsigned round = 0; round < 40; ++round) {
        for (unsigned index = 0; index < session.nodeCount(); ++index) {
            Ref state = session.state(index);
            switch ((round + index) % 6) {
            case 0:
                state->setTotalContentsSize({ 1200.0f + random.range(0, 4) * 100, 20000.0f + random.range(0, 40) * 100 });
                break;
            case 1: {
                unsigned count = random.range(50, 200);
                state->setSnapOffsetsInfo(snapOffsets({ { }, evenlySpaced(0, 100, count), 300, round % 2 ? ScrollSnapStrictness::Proximity : ScrollSnapStrictness::Mandatory, std::nullopt }));
                break;
            }
            case 2:
                state->setCurrentVerticalSnapPointIndex(random.chance(80) ? std::optional<unsigned>(random.range(0, 49)) : std::nullopt);
                state->setCurrentHorizontalSnapPointIndex(random.chance(20) ? std::optional<unsigned>(random.range(0, 9)) : std::nullopt);
                break;
            case 3: {
                ScrollbarHoverState hover;
                hover.mouseIsOverHorizontalScrollbar = random.chance(50);
                hover.mouseIsOverVerticalScrollbar = random.chance(50);
                state->setScrollbarHoverState(hover);
                state->setScrollbarEnabledState(ScrollbarOrientation::Vertical, random.chance(80));
                state->setScrollbarEnabledState(ScrollbarOrientation::Horizontal, random.chance(50));
                break;
            }
            case 4:
                state->setScrollbarWidth(random.chance(50) ? ScrollbarWidth::Thin : ScrollbarWidth::Auto);
                state->setUseDarkAppearanceForScrollbars(random.chance(50));
                break;
            case 5:
                state->setMouseIsOverContentArea(random.chance(50));
                session.requestScroll(index, ScrollRequestType::PositionUpdate, FloatPoint { 0, random.between(0, 2000) });
                break;
            }
        }
        session.commit();
    }
}

inline void mixedSessionShape(Session& session)
{
    session.addRoot(mainFrameSetup({ 0, 2000 }));
    session.addOverflow(overflowSetup({ 0, 500 }, 1));
    session.addOverflow(overflowSetup({ 0, 0 }, 2));
    SnapDescription rootSnaps { { }, evenlySpaced(0, 600, 30), 600, ScrollSnapStrictness::Proximity, std::nullopt };
    SnapDescription overflowSnaps { { }, evenlySpaced(0, 300, 20), 300, ScrollSnapStrictness::Mandatory, std::nullopt };
    session.state(0)->setSnapOffsetsInfo(snapOffsets(rootSnaps));
    session.state(2)->setSnapOffsetsInfo(snapOffsets(overflowSnaps));
    session.commit();
    Lcg random(8);
    static constexpr ScrollDirection directions[] = { ScrollDirection::ScrollDown, ScrollDirection::ScrollUp, ScrollDirection::ScrollRight, ScrollDirection::ScrollLeft };
    for (unsigned i = 0; i < 24; ++i) {
        unsigned target = random.range(0, 2);
        switch (i % 6) {
        case 0:
        case 3: {
            Session::Gesture gesture;
            float sign = random.chance(50) ? -1 : 1;
            gesture.deltas = decayingDeltas({ random.between(-3, 3), sign * random.between(4, 30) }, 0.96f, random.range(8, 24));
            if (random.chance(70))
                gesture.momentumDeltas = decayingDeltas({ 0, sign * random.between(10, 40) }, 0.92f, random.range(10, 40));
            session.gesture(target, gesture);
            session.framesUntilIdle();
            break;
        }
        case 1:
            if (random.chance(50))
                session.requestScroll(target, ScrollRequestType::AnimatedPositionUpdate, FloatPoint { 0, random.between(0, 4000) });
            else
                session.requestScroll(target, ScrollRequestType::AnimatedDeltaUpdate, FloatSize { 0, random.between(-800, 800) });
            session.commit();
            for (unsigned frame = random.range(2, 30); frame; --frame)
                session.frame();
            session.requestScroll(target, ScrollRequestType::PositionUpdate, FloatPoint { 0, random.between(0, 2000) });
            session.commit();
            session.framesUntilIdle();
            break;
        case 2: {
            auto direction = directions[random.range(0, 3)];
            auto granularity = random.chance(60) ? ScrollGranularity::Line : ScrollGranularity::Page;
            session.requestKeyboardScroll(target, KeyboardScrollAction::StartAnimation, keyboardScroll(direction, granularity, granularity == ScrollGranularity::Line ? 40 : 540));
            session.commit();
            for (unsigned frame = random.range(4, 30); frame; --frame)
                session.frame();
            session.requestKeyboardScroll(target, random.chance(70) ? KeyboardScrollAction::StopWithAnimation : KeyboardScrollAction::StopImmediately);
            session.commit();
            session.framesUntilIdle();
            break;
        }
        case 4:
            // Discrete mouse-wheel ticks; on a node with snap offsets they arm the snap timers, which this pass never fires.
            for (unsigned tick = random.range(2, 8); tick; --tick) {
                session.wheel(target, { PlatformWheelEventPhase::None, PlatformWheelEventPhase::None, { 0, random.chance(50) ? -40.0f : 40.0f }, PlatformWheelEventGranularity::ScrollByPixelWheelEvent, false }, 0.05);
                session.frame();
            }
            session.framesUntilIdle();
            break;
        case 5: {
            // A pull past the top of the root, and a programmatic scroll while it snaps back. Once, with a refresh
            // controller, a new root replaces it first and takes over the rubber band, as after a navigation.
            session.requestScroll(0, ScrollRequestType::PositionUpdate, FloatPoint { });
            session.commit();
            session.tree().setRefreshController(i == 17, i == 17 ? 40 : 0, i == 17 ? 60 : 0);
            Session::Gesture gesture;
            gesture.deltas = decayingDeltas({ 0, random.between(8, 30) }, 0.95f, random.range(8, 16));
            session.gesture(0, gesture);
            if (i == 17) {
                session.replaceRoot(mainFrameSetup({ 0, 0 }), { overflowSetup({ 0, 500 }, 1), overflowSetup({ 0, 0 }, 2) });
                session.state(0)->setSnapOffsetsInfo(snapOffsets(rootSnaps));
                session.state(2)->setSnapOffsetsInfo(snapOffsets(overflowSnaps));
                session.commit();
            }
            session.requestScroll(0, ScrollRequestType::PositionUpdate, FloatPoint { 0, 300 });
            session.commit();
            session.framesUntilIdle();
            session.tree().setRefreshController(false, 0, 0);
            session.state(0)->setTotalContentsSize({ 1200, 20000.0f + 100 * i });
            session.commit();
            break;
        }
        }
    }
}

inline void discreteWheelSnapShape(Session& session)
{
    session.addRoot(mainFrameSetup({ 0, 3800 }));
    session.state(0)->setSnapOffsetsInfo(snapOffsets({ { }, evenlySpaced(0, 380, 50), 380, ScrollSnapStrictness::Mandatory, std::nullopt }));
    session.commit();
    // Two bursts, so a pass waits on the timers only twice: three ticks down, then one tick up.
    static constexpr struct {
        unsigned ticks;
        float delta;
    } bursts[] = { { 3, -40 }, { 1, 40 } };
    for (auto burst : bursts) {
        for (unsigned tick = 0; tick < burst.ticks; ++tick)
            session.wheel(0, { PlatformWheelEventPhase::None, PlatformWheelEventPhase::None, { 0, burst.delta }, PlatformWheelEventGranularity::ScrollByPixelWheelEvent, false }, tick ? 0.03 : 0.2);
        session.fireDiscreteScrollTimers();
        session.framesUntilIdle();
    }
}

// Snap offsets on one or both axes: none, one, two, a few or many, with snap areas smaller or larger than the
// snapport, either strictness, and a scroll-snap-stop: always offset in some.
inline SnapDescription snapSelectionOffsets(unsigned variant)
{
    static constexpr unsigned counts[] = { 0, 1, 2, 5, 50 };
    unsigned horizontalCount = counts[variant % 5];
    unsigned verticalCount = counts[(variant / 5) % 5];
    if (!horizontalCount && !verticalCount)
        verticalCount = 50;
    bool large = variant % 3 == 2;
    float spacing = large ? 1000 : 350.3f;
    SnapDescription description { evenlySpaced(0, spacing, horizontalCount), evenlySpaced(0, spacing, verticalCount), large ? 900.0f : 300.0f, variant % 2 ? ScrollSnapStrictness::Proximity : ScrollSnapStrictness::Mandatory, std::nullopt, large };
    if (variant % 7 == 3)
        description.stopAlways = 1;
    return description;
}

inline void snapSelectionShape(Session& session)
{
    auto setup = mainFrameSetup({ 0, 0 });
    setup.contents = { 60000, 60000 };
    session.addRoot(setup);
    session.commit();
    Lcg random(10);
    for (unsigned i = 0; i < 100; ++i) {
        auto description = snapSelectionOffsets(i);
        // A position at or near a snap offset on each axis: at one, a pixel or half a pixel off it, a proximity
        // threshold off it, or halfway to the next. The commit clamps it to the scroll range.
        auto positionNear = [&](const std::vector<float>& offsets, float viewportLength) {
            if (offsets.empty())
                return random.between(0, 2000);
            float offset = offsets[random.range(0, static_cast<int>(offsets.size()) - 1)];
            static constexpr float shifts[] = { 0, 0, 0.5f, -0.5f, 1, -1, 0.3f, -0.3f };
            unsigned kind = random.range(0, 8);
            float shift = kind < 8 ? shifts[kind] : 0.5f * (offsets.size() > 1 ? offsets[1] - offsets[0] : viewportLength);
            if (kind == 6 || kind == 7)
                shift *= viewportLength;
            return offset + shift;
        };
        FloatPoint destination { positionNear(description.horizontal, 800), positionNear(description.vertical, 600) };
        session.state(0)->setSnapOffsetsInfo(FloatScrollSnapOffsetsInfo { });
        session.requestScroll(0, ScrollRequestType::PositionUpdate, destination);
        session.commit();
        session.state(0)->setSnapOffsetsInfo(snapOffsets(description));
        session.commit();
        // A gesture that does not move: it reports the snap indices the commit chose, and its end chooses again.
        Session::Gesture gesture;
        gesture.gapBefore = 0.2;
        session.gesture(0, gesture);
        session.framesUntilIdle();
    }
}

// The three entries the tree has, one shape each, for their per-call cost: a commit per rendering update, a wheel
// event and a display refresh.

// A rendering update's commit on a page with many overflow scrollers: each commit moves a few of them and changes one
// node's contents size, as a page that scrolls and grows does.
inline void commitPerRenderingUpdateShape(Session& session)
{
    session.addRoot(mainFrameSetup({ 0, 1000 }));
    for (unsigned i = 0; i < 12; ++i)
        session.addOverflow(overflowSetup({ 0, 50.0f * i }, i), i % 3 ? 0 : session.nodeCount() - 1);
    session.commit();
    Lcg random(11);
    for (unsigned update = 0; update < 600; ++update) {
        for (unsigned moved = 0; moved < 3; ++moved) {
            unsigned index = random.range(0, session.nodeCount() - 1);
            session.requestScroll(index, ScrollRequestType::PositionUpdate, FloatPoint { 0, random.between(0, 2000) });
        }
        unsigned grown = update % session.nodeCount();
        session.state(grown)->setTotalContentsSize({ grown ? 600.0f : 1200.0f, 3000.0f + 10.0f * (update % 400) });
        session.commit();
        session.applyLayerPositions();
    }
}

// Trackpad gestures with momentum, wheel events only: no display refresh between them, so the cost is the event's.
inline void wheelEventShape(Session& session)
{
    session.addRoot(mainFrameSetup({ 0, 9000 }));
    session.addOverflow(overflowSetup({ 0, 1000 }, 1));
    session.addOverflow(overflowSetup({ 0, 500 }, 2), 1);
    session.commit();
    Lcg random(12);
    for (unsigned i = 0; i < 30; ++i) {
        Session::Gesture gesture;
        float sign = i % 2 ? -1 : 1;
        gesture.deltas = decayingDeltas({ random.between(-2, 2), sign * random.between(4, 30) }, 0.97f, random.range(20, 40));
        gesture.momentumDeltas = decayingDeltas({ 0, sign * random.between(10, 40) }, 0.94f, random.range(40, 80));
        gesture.framesBetweenEvents = false;
        session.gesture(i % 3, gesture);
    }
    session.framesUntilIdle();
}

// Display refreshes while animated and keyboard scrolls run on several nodes at once.
inline void displayRefreshShape(Session& session)
{
    session.addRoot(mainFrameSetup({ 0, 0 }));
    for (unsigned i = 0; i < 3; ++i)
        session.addOverflow(overflowSetup({ 0, 0 }, i + 1));
    session.commit();
    Lcg random(13);
    for (unsigned round = 0; round < 20; ++round) {
        for (unsigned index = 0; index < session.nodeCount(); ++index) {
            if ((round + index) % 3)
                session.requestScroll(index, ScrollRequestType::AnimatedPositionUpdate, FloatPoint { 0, random.between(0, 2500) });
            else
                session.requestKeyboardScroll(index, KeyboardScrollAction::StartAnimation, keyboardScroll(round % 2 ? ScrollDirection::ScrollUp : ScrollDirection::ScrollDown, ScrollGranularity::Line, 40));
        }
        session.commit();
        for (unsigned frame = 0; frame < 20; ++frame) {
            session.frame();
            session.applyLayerPositions();
        }
        for (unsigned index = 0; index < session.nodeCount(); ++index) {
            if (!((round + index) % 3))
                session.requestKeyboardScroll(index, KeyboardScrollAction::StopWithAnimation);
        }
        session.commit();
        session.framesUntilIdle();
    }
}

// Latching, which every other shape turns off: gestures that begin over a nested overflow scroller and keep
// going after it reaches its end, with the pointer moving over its parent and the root mid-gesture, so the latched
// node, not the node under the pointer, takes the rest of the gesture. Each gesture is short, so the latching
// controller's real-time timeout (scrollingTreeResetLatchedStateTimeout) does not expire inside one.
inline void latchingShape(Session& session)
{
    session.enableLatching();
    session.addRoot(mainFrameSetup({ 0, 4000 }));
    session.addOverflow(overflowSetup({ 0, 0 }, 1));
    session.addOverflow(overflowSetup({ 0, 0 }, 2), 1);
    session.addOverflow(overflowSetup({ 0, 200 }, 3));
    session.commit();
    Lcg random(14);
    using Phase = PlatformWheelEventPhase;
    for (unsigned i = 0; i < 40; ++i) {
        unsigned start = random.range(0, 3);
        float sign = random.chance(50) ? -1 : 1;
        unsigned count = random.range(10, 30);
        unsigned moveAt = random.range(2, count - 1);
        unsigned moveTo = random.range(0, 3);
        session.wheel(start, { Phase::MayBegin, Phase::None, { } }, 0.05);
        for (unsigned event = 0; event < count; ++event) {
            // Large deltas, so the starting scroller reaches its end and the gesture continues past it.
            FloatSize delta { i % 5 ? 0 : random.between(-4, 4), sign * random.between(20, 120) };
            session.wheel(event < moveAt ? start : moveTo, { event ? Phase::Changed : Phase::Began, Phase::None, delta });
        }
        session.wheel(moveTo, { Phase::Ended, Phase::None, { } });
        if (i % 3) {
            unsigned momentumCount = random.range(5, 20);
            for (unsigned event = 0; event < momentumCount; ++event)
                session.wheel(random.range(0, 3), { Phase::None, event ? Phase::Changed : Phase::Began, { 0, sign * random.between(5, 60) } });
            session.wheel(moveTo, { Phase::None, Phase::Ended, { } });
        }
        session.framesUntilIdle();
    }
}

using Shape = void (*)(Session&);

// One pass of a shape on a new tree, on the scrolling thread: its digest and how many entries (commits, wheel
// events, display refreshes) it made.
inline std::pair<uint64_t, uint64_t> runShape(Shape shape)
{
    Digest digest;
    uint64_t entries = 0;
    onScrollingThread([&] {
        Session session(digest);
        shape(session);
        entries = session.entries();
    });
    drainMainThreadTasks();
    return { digest.value(), entries };
}

} // namespace ScrollingTreeDelegate
} // namespace TestWebKitAPI
