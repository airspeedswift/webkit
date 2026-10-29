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

// Scrolling nodes with scrollbars, made as WebKit's UI process makes them: each node's delegate creates its
// scroller pair, and commits give it a host layer per scrollbar. A session lives on the main thread, where the UI
// process commits, and sends wheel events and display refreshes to the scrolling thread. After each commit, wheel
// event or display refresh it runs the work the scrollbars queued for the main thread, and digests each node's
// scrollbar state, its hit-testable scrollbar layers and the sublayers of its host layers. MacScrollersBench.mm
// uses it.

#import "ScrollingTreeDelegateRig.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <WebCore/Color.h>
#import <WebCore/NSScrollerImpDetails.h>
#import <WebCore/ScrollingTreeScrollingNodeDelegate.h>
#import <array>
#import <mutex>
#import <wtf/text/StringBuilder.h>
#import <wtf/text/StringView.h>

@interface CATransaction (MacScrollersRig)
+ (void)setDisableImplicitTransactionMainThreadAssert:(BOOL)disable;
+ (void)setDefaultDisableRunLoopObserverCommits:(BOOL)disable;
@end

namespace TestWebKitAPI {
namespace ScrollingTreeDelegate {

// MARK: - Threads

inline uint8_t threadTag()
{
    if (isMainThread())
        return 0;
    return ScrollingThread::isCurrentThread() ? 1 : 2;
}

// Runs the work the scrollbars queued for the main thread, in a run loop mode of its own: AppKit's animation
// timers run in the default modes and do not fire here, so a session sees the animations its scrollbars start
// but never their progress, which depends on time.
inline void runScrollbarTasks()
{
    static CFStringRef const mode = CFSTR("TestWebKitAPIScrollbarTasks");
    static std::once_flag once;
    std::call_once(once, [] {
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), mode);
    });
    while (CFRunLoopRunInMode(mode, 0, true) == kCFRunLoopRunHandledSource) { }
}

// MARK: - Nodes

// As WebKit's ScrollingTreeFrameScrollingNodeRemoteMac.
class RigFrameScrollingNodeWithScrollbars final : public ScrollingTreeFrameScrollingNodeMac {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(RigFrameScrollingNodeWithScrollbars);
public:
    static Ref<RigFrameScrollingNodeWithScrollbars> create(ScrollingTree& tree, ScrollingNodeType nodeType, ScrollingNodeID id)
    {
        return adoptRef(*new RigFrameScrollingNodeWithScrollbars(tree, nodeType, id));
    }

    Vector<RetainPtr<CALayer>, 2> scrollbarLayers() const { return m_delegate->hitTestableScrollbarLayers(); }

private:
    RigFrameScrollingNodeWithScrollbars(ScrollingTree& tree, ScrollingNodeType nodeType, ScrollingNodeID id)
        : ScrollingTreeFrameScrollingNodeMac(tree, nodeType, id)
    {
        m_delegate->initScrollbars();
    }

    void repositionRelatedLayers() final
    {
        ScrollingTreeFrameScrollingNodeMac::repositionRelatedLayers();
        m_delegate->updateScrollbarLayers();
    }

    void handleWheelEventPhase(const PlatformWheelEventPhase phase) final { m_delegate->handleWheelEventPhase(phase); }
    void viewWillStartLiveResize() final { m_delegate->viewWillStartLiveResize(); }
    void viewWillEndLiveResize() final { m_delegate->viewWillEndLiveResize(); }
    void viewSizeDidChange() final { m_delegate->viewSizeDidChange(); }
    String scrollbarStateForOrientation(ScrollbarOrientation orientation) const final { return m_delegate->scrollbarStateForOrientation(orientation); }
};

// As WebKit's ScrollingTreeOverflowScrollingNodeRemoteMac.
class RigOverflowScrollingNodeWithScrollbars final : public ScrollingTreeOverflowScrollingNodeMac {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(RigOverflowScrollingNodeWithScrollbars);
public:
    static Ref<RigOverflowScrollingNodeWithScrollbars> create(ScrollingTree& tree, ScrollingNodeID id)
    {
        return adoptRef(*new RigOverflowScrollingNodeWithScrollbars(tree, id));
    }

    Vector<RetainPtr<CALayer>, 2> scrollbarLayers() const { return m_delegate->hitTestableScrollbarLayers(); }

private:
    RigOverflowScrollingNodeWithScrollbars(ScrollingTree& tree, ScrollingNodeID id)
        : ScrollingTreeOverflowScrollingNodeMac(tree, id)
    {
        m_delegate->initScrollbars();
    }

    void repositionRelatedLayers() final
    {
        ScrollingTreeOverflowScrollingNodeMac::repositionRelatedLayers();
        m_delegate->updateScrollbarLayers();
    }

    void handleWheelEventPhase(const PlatformWheelEventPhase phase) final { m_delegate->handleWheelEventPhase(phase); }
    String scrollbarStateForOrientation(ScrollbarOrientation orientation) const final { return m_delegate->scrollbarStateForOrientation(orientation); }
};

inline Vector<RetainPtr<CALayer>, 2> scrollbarLayers(const ScrollingTreeScrollingNode& node)
{
    if (node.nodeType() == ScrollingNodeType::Overflow)
        return static_cast<const RigOverflowScrollingNodeWithScrollbars&>(node).scrollbarLayers();
    return static_cast<const RigFrameScrollingNodeWithScrollbars&>(node).scrollbarLayers();
}

// MARK: - Tree

// As RigScrollingTree, for a subclass to extend.
class UIProcessRigTree : public ScrollingTree {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(UIProcessRigTree);
public:

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
                node->startAnimatedScrollToPosition(request.destinationPosition(node->currentScrollPosition()));
        }
        auto keyboardScrolls = std::exchange(m_pendingKeyboardScrolls, { });
        for (auto& [id, request] : keyboardScrolls) {
            if (RefPtr node = dynamicDowncast<ScrollingTreeScrollingNode>(nodeForID(id)))
                node->handleKeyboardScrollRequest(request);
        }
    }

    // As ThreadedScrollingTree::displayDidRefreshOnScrollingThread() services animations.
    virtual void displayDidRefreshAt(MonotonicTime now)
    {
        Locker locker { m_treeLock };
        serviceScrollAnimations(now);
    }

    void disableLatching() { m_allowLatching = false; }

protected:
    explicit UIProcessRigTree(Digest& digest)
        : m_digest(digest)
    {
    }

    Digest& digest() { return m_digest; }

    Digest& record(TreeCall call, ScrollingNodeID id)
    {
        return m_digest.u(static_cast<uint8_t>(call)).u(id.object().toUInt64());
    }

    Ref<ScrollingTreeNode> createScrollingTreeNode(ScrollingNodeType nodeType, ScrollingNodeID id) override
    {
        if (nodeType == ScrollingNodeType::Overflow)
            return ScrollingTreeOverflowScrollingNodeMac::create(*this, id);
        return ScrollingTreeFrameScrollingNodeMac::create(*this, nodeType, id);
    }

    void handleWheelEventPhase(ScrollingNodeID id, PlatformWheelEventPhase phase) override { record(TreeCall::WheelEventPhase, id).u(static_cast<uint8_t>(phase)); }

private:
    RefPtr<ScrollingTreeNode> scrollingNodeForPoint(FloatPoint) final
    {
        if (m_wheelTarget)
            return nodeForID(*m_wheelTarget);
        return rootNode();
    }

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


// What a session digests. Where the scrollbars are shown and expanded, which hit-testing then follows, is
// AppKit's decision: with a window server it depends on the mouse and the system's pointing devices, so the
// benchmark leaves it out.
enum class ScrollbarObservation : bool {
    WebKitState,
    WebKitAndAppKitState,
};

// What the tree records of its nodes' scrollbar calls, after RigScrollingTree's tags.
enum class ScrollbarTreeCall : uint8_t {
    VisibilityDidChange = 64,
    MinimumThumbLengthDidChange,
};

// As WebKit's RemoteScrollingTreeMac: nodes with scrollbars, and wheel event phases sent to the node. As the UI
// process does, it applies the layer positions a scroll changed after each display refresh, on the scrolling
// thread, and after each commit, on the main thread.
class ScrollbarsRigTree final : public UIProcessRigTree {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(ScrollbarsRigTree);
public:
    static Ref<ScrollbarsRigTree> create(Digest& digest, ScrollbarObservation observation) { return adoptRef(*new ScrollbarsRigTree(digest, observation)); }

    void displayDidRefreshAt(MonotonicTime now) final
    {
        UIProcessRigTree::displayDidRefreshAt(now);
        applyLayerPositions();
    }

private:
    ScrollbarsRigTree(Digest& digest, ScrollbarObservation observation)
        : UIProcessRigTree(digest)
        , m_observation(observation)
    {
        onScrollingThread([] {
            if ([CATransaction respondsToSelector:@selector(setDisableImplicitTransactionMainThreadAssert:)])
                [CATransaction setDisableImplicitTransactionMainThreadAssert:YES];
            [CATransaction setDefaultDisableRunLoopObserverCommits:YES];
        });
    }

    Ref<ScrollingTreeNode> createScrollingTreeNode(ScrollingNodeType nodeType, ScrollingNodeID id) final
    {
        if (nodeType == ScrollingNodeType::Overflow)
            return RigOverflowScrollingNodeWithScrollbars::create(*this, id);
        return RigFrameScrollingNodeWithScrollbars::create(*this, nodeType, id);
    }

    void handleWheelEventPhase(ScrollingNodeID id, PlatformWheelEventPhase phase) final
    {
        UIProcessRigTree::handleWheelEventPhase(id, phase);
        if (RefPtr node = dynamicDowncast<ScrollingTreeScrollingNode>(nodeForID(id)))
            node->handleWheelEventPhase(phase);
    }

    void scrollingTreeNodeScrollbarVisibilityDidChange(ScrollingNodeID id, ScrollbarOrientation orientation, bool isVisible) final
    {
        if (m_observation == ScrollbarObservation::WebKitState)
            return;
        digest().u(static_cast<uint8_t>(ScrollbarTreeCall::VisibilityDidChange)).u(id.object().toUInt64()).u(static_cast<uint8_t>(orientation)).b(isVisible).u(threadTag());
    }

    void scrollingTreeNodeScrollbarMinimumThumbLengthDidChange(ScrollingNodeID id, ScrollbarOrientation orientation, int length) final
    {
        digest().u(static_cast<uint8_t>(ScrollbarTreeCall::MinimumThumbLengthDidChange)).u(id.object().toUInt64()).u(static_cast<uint8_t>(orientation)).u(static_cast<uint32_t>(length)).u(threadTag());
    }

    const ScrollbarObservation m_observation;
};

// The scrollbar state without the parts AppKit decides (expanded, visible_track, visible_thumb).
inline String webKitScrollbarState(const String& state)
{
    StringBuilder result;
    for (auto token : StringView(state).split(',')) {
        if (token == "expanded"_s || token == "visible_track"_s || token == "visible_thumb"_s)
            continue;
        if (!result.isEmpty())
            result.append(',');
        result.append(token);
    }
    return result.toString();
}

// MARK: - Session

// As Session, with a tree a subclass makes and hooks for running on the main thread.
class UIProcessSession {
public:
    static constexpr double frameInterval = 1.0 / 60;

    UIProcessSession(Digest& digest, Ref<UIProcessRigTree>&& tree, double startTime = 1000)
        : m_digest(digest)
        , m_tree(WTF::move(tree))
    {
        RigClock::now() = startTime;
        setScrollingEffectsClockForTesting(RigClock::read);
        m_tree->disableLatching();
    }

    ~UIProcessSession()
    {
        // Removing the nodes stops their timers.
        m_stateTree = makeUnique<ScrollingStateTree>();
        commit();
        setScrollingEffectsClockForTesting(nullptr);
    }

    // For a session on the main thread, as in the UI process: commits stay there, and wheel events and display
    // refreshes go to the scrolling thread. willCommit gets each committed state tree before the tree takes it and
    // didCommit runs after; runMainThreadTasks runs after each entry, and observe after its own observations.
    struct MainThreadHooks {
        Function<void()> runMainThreadTasks;
        Function<void(ScrollingStateTree&)> willCommit;
        Function<void()> didCommit;
        Function<void()> observe;
    };

    void setMainThreadHooks(MainThreadHooks&& hooks) { m_hooks = WTF::move(hooks); }

    UIProcessRigTree& tree() { return m_tree.get(); }
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

    Ref<ScrollingStateScrollingNode> state(unsigned index) { return downcast<ScrollingStateScrollingNode>(m_stateTree->stateNodeForID(m_nodes[index]).releaseNonNull()); }
    Ref<ScrollingStateFrameScrollingNode> rootState() { return m_stateTree->rootStateNode().releaseNonNull(); }

    RefPtr<ScrollingTreeScrollingNode> node(unsigned index) { return dynamicDowncast<ScrollingTreeScrollingNode>(m_tree->nodeForID(m_nodes[index])); }

    void commit()
    {
        auto stateTree = m_stateTree->commit(LayerRepresentation::PlatformLayerRepresentation);
        stateTree->setRootFrameIdentifier(FrameIdentifier(1));
        if (m_hooks.willCommit)
            m_hooks.willCommit(*stateTree);
        m_tree->commitTreeState(WTF::move(stateTree));
        if (m_hooks.didCommit)
            m_hooks.didCommit();
        if (m_hooks.runMainThreadTasks) {
            onScrollingThread([&] {
                m_tree->startPendingScrollAnimations();
            });
            m_hooks.runMainThreadTasks();
        } else
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
        WheelEventHandlingResult result;
        onEventThread([&] {
            auto steps = m_tree->determineWheelEventProcessing(event);
            result = m_tree->handleWheelEvent(event, steps);
        });
        ++m_entries;
        m_digest.u(result.steps.toRaw()).b(result.wasHandled);
        observe();
        return result;
    }

    void frame()
    {
        RigClock::now() += frameInterval;
        onEventThread([&] {
            m_tree->displayDidRefreshAt(RigClock::read());
        });
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
        if (m_hooks.observe)
            m_hooks.observe();
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

    ScrollingNodeID nodeIDAt(unsigned index) const { return m_nodes[index]; }

private:
    template<typename Work> void onEventThread(const Work& work)
    {
        if (!m_hooks.runMainThreadTasks) {
            work();
            return;
        }
        onScrollingThread([&] {
            work();
        });
        m_hooks.runMainThreadTasks();
    }

    Digest& m_digest;
    Ref<UIProcessRigTree> m_tree;
    MainThreadHooks m_hooks;
    std::unique_ptr<ScrollingStateTree> m_stateTree { makeUnique<ScrollingStateTree>() };
    std::vector<ScrollingNodeID> m_nodes;
    uint64_t m_nextID { 1 };
    uint64_t m_entries { 0 };
};


class ScrollbarsSession {
public:
    static constexpr float scrollbarThickness = 15;

    ScrollbarsSession(Digest& digest, bool overlayScrollbars, ScrollbarObservation observation = ScrollbarObservation::WebKitState, double startTime = 1000)
        : m_digest(digest)
        , m_observation(observation)
        , m_usedOverlayScrollbars(ScrollerStyle::recommendedScrollerStyle() == NSScrollerStyleOverlay)
    {
        ScrollerStyle::setUseOverlayScrollbars(overlayScrollbars);
        m_overlayScrollbars = overlayScrollbars;
        m_tree = ScrollbarsRigTree::create(digest, observation);
        m_session.emplace(digest, Ref { *m_tree }, startTime);
        m_session->setMainThreadHooks({
            [] { runScrollbarTasks(); },
            [this](ScrollingStateTree& stateTree) { connectHostLayers(stateTree); },
            [this] { m_tree->applyLayerPositions(); },
            [this] { observeScrollbars(); },
        });
    }

    ~ScrollbarsSession()
    {
        // Removing the nodes releases their scrollers; they are not observed after this.
        m_observing = false;
        m_session.reset();
        m_tree = nullptr;
        runScrollbarTasks();
        ScrollerStyle::setUseOverlayScrollbars(m_usedOverlayScrollbars);
    }

    UIProcessSession& session() { return *m_session; }
    ScrollingTree& tree() { return *m_tree; }

    // Nodes with both scrollbars enabled and a host layer for each.
    unsigned addRoot(const NodeSetup& setup)
    {
        auto index = m_session->addRoot(setup);
        m_hostLayers.clear();
        addScrollbars(index, setup.viewport);
        return index;
    }

    unsigned addOverflow(const NodeSetup& setup, unsigned parent = 0)
    {
        auto index = m_session->addOverflow(setup, parent);
        addScrollbars(index, setup.viewport);
        return index;
    }

    // The host layers the next commit gives node index; nil removes one.
    void setHostLayers(unsigned index, CALayer *vertical, CALayer *horizontal)
    {
        m_hostLayers[index] = { vertical, horizontal };
        m_pendingHostLayers.push_back(index);
    }

    CALayer *hostLayer(unsigned index, ScrollbarOrientation orientation) const
    {
        return m_hostLayers[index][orientation == ScrollbarOrientation::Vertical ? 0 : 1].get();
    }

    void observeScrollbars()
    {
        if (!m_observing)
            return;
        for (unsigned index = 0; index < m_session->nodeCount(); ++index) {
            RefPtr node = m_session->node(index);
            if (!node) {
                m_digest.u(0);
                continue;
            }
            bool appKitState = m_observation == ScrollbarObservation::WebKitAndAppKitState;
            for (auto orientation : { ScrollbarOrientation::Vertical, ScrollbarOrientation::Horizontal }) {
                auto fullState = node->scrollbarStateForOrientation(orientation);
                auto state = (appKitState ? fullState : webKitScrollbarState(fullState)).utf8();
                m_digest.u(state.length()).bytes(state.data(), state.length());
            }
            // Overlay scrollbars are hit-testable only while AppKit shows them.
            if (!appKitState && m_overlayScrollbars)
                continue;
            auto layers = scrollbarLayers(*node);
            m_digest.u(layers.size());
            for (auto& layer : layers) {
                auto* layerPointer = layer.get();
                m_digest.u(layerPointer == hostLayer(index, ScrollbarOrientation::Vertical) ? 1 : layerPointer == hostLayer(index, ScrollbarOrientation::Horizontal) ? 2 : 3);
            }
            if (appKitState && index < m_hostLayers.size()) {
                for (auto& layer : m_hostLayers[index])
                    m_digest.u(layer ? layer.get().sublayers.count + 1 : 0);
            }
        }
    }

private:
    void addScrollbars(unsigned index, FloatSize viewport)
    {
        Ref state = m_session->state(index);
        state->setScrollbarEnabledState(ScrollbarOrientation::Vertical, true);
        state->setScrollbarEnabledState(ScrollbarOrientation::Horizontal, true);
        if (m_hostLayers.size() <= index)
            m_hostLayers.resize(index + 1);
        RetainPtr vertical = adoptNS([[CALayer alloc] init]);
        [vertical setBounds:CGRectMake(0, 0, scrollbarThickness, viewport.height())];
        RetainPtr horizontal = adoptNS([[CALayer alloc] init]);
        [horizontal setBounds:CGRectMake(0, 0, viewport.width(), scrollbarThickness)];
        setHostLayers(index, vertical.get(), horizontal.get());
    }

    // As RemoteScrollingCoordinatorProxyMac connects a commit's layers before the tree takes it.
    void connectHostLayers(ScrollingStateTree& stateTree)
    {
        for (auto index : std::exchange(m_pendingHostLayers, { })) {
            RefPtr node = dynamicDowncast<ScrollingStateScrollingNode>(stateTree.stateNodeForID(m_session->nodeIDAt(index)));
            if (!node)
                continue;
            node->setVerticalScrollbarLayer(m_hostLayers[index][0].get());
            node->setHorizontalScrollbarLayer(m_hostLayers[index][1].get());
        }
    }

    Digest& m_digest;
    const ScrollbarObservation m_observation;
    bool m_overlayScrollbars { false };
    bool m_usedOverlayScrollbars;
    RefPtr<ScrollbarsRigTree> m_tree;
    std::optional<UIProcessSession> m_session;
    std::vector<std::array<RetainPtr<CALayer>, 2>> m_hostLayers;
    std::vector<unsigned> m_pendingHostLayers;
    bool m_observing { true };
};

// MARK: - Benchmark shapes
//
// Each shape is one pass with overlay scrollbars and one with legacy scrollbars, each on a new tree.

using ScrollbarsShape = void (*)(ScrollbarsSession&);

inline NodeSetup scrollbarsOverflowSetup(FloatPoint position, unsigned variant)
{
    NodeSetup setup;
    setup.viewport = { 400, 300 };
    setup.contents = { 400.0f + 300 * (variant % 2), 3000.0f + 1000 * variant };
    setup.position = position;
    return setup;
}

inline void requestPosition(UIProcessSession& session, unsigned index, FloatPoint position, ScrollbarRevealBehavior reveal = ScrollbarRevealBehavior::Default)
{
    session.state(index)->setRequestedScrollData({ ScrollRequestType::PositionUpdate, position, { }, ScrollType::Programmatic, ScrollClamping::Unclamped, reveal });
}

// Scroll position changes: trackpad gestures without momentum, which move the nodes on the scrolling thread, and
// programmatic scrolls before the top, inside and past the end, which move them on the main thread.
inline void scrollUpdatesShape(ScrollbarsSession& scrollbars)
{
    auto& session = scrollbars.session();
    scrollbars.addRoot(mainFrameSetup({ 0, 4000 }));
    scrollbars.addOverflow(scrollbarsOverflowSetup({ 0, 500 }, 1));
    session.commit();
    Lcg random(11);
    for (unsigned i = 0; i < 12; ++i) {
        unsigned target = i % 2;
        UIProcessSession::Gesture gesture;
        float sign = random.chance(50) ? -1 : 1;
        gesture.deltas = decayingDeltas({ random.between(-4, 4), sign * random.between(6, 30) }, 0.98f, random.range(10, 20));
        gesture.framesBetweenEvents = i % 3;
        gesture.mayBegin = i % 4;
        session.gesture(target, gesture);
        float contentsHeight = target ? 3000 + 1000 : 20000;
        static constexpr float positions[] = { -120, -1, 0, 0.5f, 0.97f, 1, 1.002f };
        float position = positions[i % std::size(positions)];
        float y = position < 0 ? position : position * contentsHeight;
        requestPosition(session, target, { 0, y }, i % 5 == 4 ? ScrollbarRevealBehavior::DontReveal : ScrollbarRevealBehavior::Default);
        session.commit();
        requestPosition(session, target, { 0, random.between(0, contentsHeight / 2) });
        session.commit();
    }
}

// Presentation values: trackpad gestures with momentum, with a display refresh after each event.
inline void momentumPresentationShape(ScrollbarsSession& scrollbars)
{
    auto& session = scrollbars.session();
    scrollbars.addRoot(mainFrameSetup({ 200, 8000 }));
    session.commit();
    Lcg random(12);
    for (unsigned i = 0; i < 6; ++i) {
        UIProcessSession::Gesture gesture;
        float sign = i % 2 ? -1 : 1;
        gesture.deltas = decayingDeltas({ random.between(-2, 2), sign * random.between(4, 30) }, 0.97f, random.range(5, 12));
        gesture.momentumDeltas = decayingDeltas({ 0, sign * random.between(10, 40) }, 0.92f, random.range(20, 40));
        session.gesture(0, gesture);
        session.framesUntilIdle();
    }
}

// Mouse notifications: entering and leaving the content area, moving over and off each scrollbar.
inline void hoverAndExitShape(ScrollbarsSession& scrollbars)
{
    auto& session = scrollbars.session();
    scrollbars.addRoot(mainFrameSetup({ 0, 1000 }));
    scrollbars.addOverflow(scrollbarsOverflowSetup({ 0, 0 }, 2));
    session.commit();
    Lcg random(13);
    for (unsigned i = 0; i < 60; ++i) {
        unsigned target = random.range(0, 1);
        Ref state = session.state(target);
        switch (i % 4) {
        case 0:
            state->setMouseIsOverContentArea(random.chance(70));
            break;
        case 1:
        case 3: {
            // Inside or outside each scrollbar's bounds, (-1, -1) as when the mouse leaves.
            auto location = [&](bool vertical) {
                if (random.chance(20))
                    return IntPoint { -1, -1 };
                if (vertical)
                    return IntPoint { random.range(-5, 20), random.range(-5, 320) };
                return IntPoint { random.range(-5, 420), random.range(-5, 20) };
            };
            state->setMouseMovedInContentArea({ location(false), location(true) });
            break;
        }
        case 2: {
            ScrollbarHoverState hover;
            hover.mouseIsOverHorizontalScrollbar = random.chance(40);
            hover.mouseIsOverVerticalScrollbar = random.chance(60);
            state->setScrollbarHoverState(hover);
            break;
        }
        }
        session.commit();
    }
}

// Scrollbar state changes: width, colors, dark appearance, layout direction, native visibility, enabled state,
// contents size and live resize.
inline void scrollbarStateCommitsShape(ScrollbarsSession& scrollbars)
{
    auto& session = scrollbars.session();
    scrollbars.addRoot(mainFrameSetup({ 0, 1000 }));
    scrollbars.addOverflow(scrollbarsOverflowSetup({ 0, 100 }, 1));
    session.commit();
    Lcg random(14);
    static constexpr NativeScrollbarVisibility visibilities[] = { NativeScrollbarVisibility::Visible, NativeScrollbarVisibility::HiddenByStyle, NativeScrollbarVisibility::ReplacedByCustomScrollbar };
    for (unsigned i = 0; i < 48; ++i) {
        unsigned target = random.range(0, 1);
        Ref state = session.state(target);
        switch (i % 8) {
        case 0:
            state->setScrollbarWidth(random.chance(50) ? ScrollbarWidth::Thin : ScrollbarWidth::Auto);
            break;
        case 1:
            if (random.chance(70))
                state->setScrollbarColor(ScrollbarColor { Color(SRGBA<uint8_t> { static_cast<uint8_t>(random.range(0, 255)), 40, 200, 255 }), Color(SRGBA<uint8_t> { 10, static_cast<uint8_t>(random.range(0, 255)), 30, 128 }) });
            else
                state->setScrollbarColor(std::nullopt);
            break;
        case 2:
            state->setUseDarkAppearanceForScrollbars(random.chance(50));
            break;
        case 3:
            state->setScrollbarLayoutDirection(random.chance(50) ? UserInterfaceLayoutDirection::RTL : UserInterfaceLayoutDirection::LTR);
            break;
        case 4: {
            auto parameters = scrollableParameters();
            parameters.verticalNativeScrollbarVisibility = visibilities[random.range(0, 2)];
            parameters.horizontalNativeScrollbarVisibility = visibilities[random.range(0, 2)];
            state->setScrollableAreaParameters(parameters);
            break;
        }
        case 5:
            state->setScrollbarEnabledState(ScrollbarOrientation::Vertical, random.chance(80));
            state->setScrollbarEnabledState(ScrollbarOrientation::Horizontal, random.chance(50));
            break;
        case 6:
            state->setTotalContentsSize({ random.chance(10) ? 0 : 1200.0f + random.range(0, 4) * 100, 20000.0f + random.range(0, 40) * 100 });
            break;
        case 7:
            scrollbars.tree().viewWillStartLiveResize();
            state->setScrollableAreaSize({ 800.0f - random.range(0, 4) * 50, 600.0f - random.range(0, 4) * 50 });
            session.commit();
            scrollbars.tree().viewSizeDidChange();
            scrollbars.tree().viewWillEndLiveResize();
            break;
        }
        session.commit();
    }
}

// AppKit decides the system's recommended scroller style once a process makes its first scrollers, and then tells
// every scroller pair, which would change the style of a session's scrollbars partway through. A first session,
// run once per process, lets that happen before any shape runs.
inline void settleRecommendedScrollerStyle()
{
    static std::once_flag once;
    std::call_once(once, [] {
        @autoreleasepool {
            Digest digest;
            ScrollbarsSession scrollbars(digest, true);
            scrollbars.addRoot(mainFrameSetup({ 0, 0 }));
            scrollbars.session().commit();
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.6, false);
    });
}

// One pass of a shape, with overlay then legacy scrollbars, on the main thread: its digest and how many entries
// (commits, wheel events, display refreshes) it made.
inline std::pair<uint64_t, uint64_t> runScrollbarsShape(ScrollbarsShape shape)
{
    settleRecommendedScrollerStyle();
    Digest digest;
    uint64_t entries = 0;
    for (bool overlay : { true, false }) @autoreleasepool {
        ScrollbarsSession scrollbars(digest, overlay);
        shape(scrollbars);
        entries += scrollbars.session().entries();
    }
    return { digest.value(), entries };
}

} // namespace ScrollingTreeDelegate
} // namespace TestWebKitAPI
