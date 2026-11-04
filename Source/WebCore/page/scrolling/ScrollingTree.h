/*
 * Copyright (C) 2012-2025 Apple Inc. All rights reserved.
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
#if ENABLE(ASYNC_SCROLLING)

#include <WebCore/BoxExtents.h>
#include <WebCore/EventTrackingRegions.h>
#include <WebCore/FrameIdentifier.h>
#include <WebCore/LayerHostingContextIdentifier.h>
#include <WebCore/PageIdentifier.h>
#include <WebCore/PlatformWheelEvent.h>
#include <WebCore/RectEdges.h>
#include <WebCore/Region.h>
#include <WebCore/RubberbandingState.h>
#include <WebCore/ScrollTypes.h>
#include <WebCore/ScrollingCoordinatorTypes.h>
#include <WebCore/ScrollingTreeGestureState.h>
#include <WebCore/ScrollingTreeLatchingController.h>
#include <WebCore/WheelEventTestMonitor.h>
#include <wtf/ForbidHeapAllocation.h>
#include <wtf/HashMap.h>
#include <wtf/Lock.h>
#include <wtf/MonotonicTime.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/ThreadSafeWeakHashSet.h>
#include <wtf/TypeCasts.h>

namespace WebCore {

class IntPoint;
class ScrollingStateTree;
class ScrollingStateNode;
class ScrollingTreeFrameScrollingNode;
class ScrollingTreeNode;
class ScrollingTreeOverflowScrollProxyNode;
class ScrollingTreePositionedNode;
class ScrollingTreeScrollingNode;
class ScrollingTreeFrameHostingNode;
class ScrollingTreeLockedAccess;

// Whether a ScrollingTreeLockedAccess was made for the commit of tree state, which may change the tree's structure.
enum class ScrollingTreeAccessMode : bool { Event, Commit };

enum class EventListenerRegionType : uint64_t;

using FramesPerSecond = unsigned;
using PlatformDisplayID = uint32_t;

enum class EventTargeting : uint8_t { NodeOnly, Propagate };

enum class RequestsScrollHandling : uint8_t {
    Unhandled,
    Handled,
    Delayed
};

class ScrollingTree : public ThreadSafeRefCountedAndCanMakeThreadSafeWeakPtr<ScrollingTree> {
    WTF_MAKE_TZONE_ALLOCATED_EXPORT(ScrollingTree, WEBCORE_EXPORT);
    friend class ScrollingTreeLatchingController;
    friend class ScrollingTreeLockedAccess;
public:
    WEBCORE_EXPORT ScrollingTree();
    WEBCORE_EXPORT virtual ~ScrollingTree();

    virtual bool isThreadedScrollingTree() const { return false; }
    virtual bool isScrollingTreeMac() const { return false; }
    virtual bool isRemoteScrollingTree() const { return false; }
    virtual bool isScrollingTreeIOS() const { return false; }
    virtual bool isScrollingTreeCoordinated() const { return false; }

    // This implies that we'll do hit-testing in the scrolling tree.
    bool asyncFrameOrOverflowScrollingEnabled() const { return m_asyncFrameOrOverflowScrollingEnabled; }
    void setAsyncFrameOrOverflowScrollingEnabled(bool value) { m_asyncFrameOrOverflowScrollingEnabled = value; }

    bool wheelEventGesturesBecomeNonBlocking() const { return m_wheelEventGesturesBecomeNonBlocking; }
    void setWheelEventGesturesBecomeNonBlocking(bool value) { m_wheelEventGesturesBecomeNonBlocking = value; }

    bool scrollingPerformanceTestingEnabled() const { return m_scrollingPerformanceTestingEnabled; }
    void setScrollingPerformanceTestingEnabled(bool value) { m_scrollingPerformanceTestingEnabled = value; }

    SWIFT_UNSAFE WEBCORE_EXPORT bool isUserScrollInProgressAtEventLocation(const PlatformWheelEvent&);
    SWIFT_UNSAFE WEBCORE_EXPORT OptionSet<WheelEventProcessingSteps> determineWheelEventProcessing(const PlatformWheelEvent&);
    WEBCORE_EXPORT virtual WheelEventHandlingResult handleWheelEvent(const PlatformWheelEvent&, OptionSet<WheelEventProcessingSteps> = { });
#if PLATFORM(MAC)
    // Stops spring animations in the scroller under the wheel event and in the scrollers that enclose it. This hit tests the
    // same way as handleWheelEvent(), so call it with the same locks held.
    WEBCORE_EXPORT void stopSpringAnimationsForWheelEvent(const PlatformWheelEvent&);
#endif

    NODELETE bool isRubberBandInProgressForNode(std::optional<ScrollingNodeID>);
    WEBCORE_EXPORT virtual void setRubberBandingInProgressForNode(ScrollingNodeID, bool);

#if HAVE(RUBBER_BANDING)
    NODELETE SWIFT_UNSAFE void setPendingMainFrameRubberbandingState(std::optional<RubberbandingState>&&) WTF_REQUIRES_LOCK(m_treeLock);
    NODELETE SWIFT_UNSAFE std::optional<RubberbandingState> takePendingMainFrameRubberbandingState() WTF_REQUIRES_LOCK(m_treeLock);
#endif

    NODELETE bool isUserScrollInProgressForNode(std::optional<ScrollingNodeID>);
    void setUserScrollInProgressForNode(ScrollingNodeID, bool);
    WEBCORE_EXPORT virtual void clearNodesWithUserScrollInProgress();

    NODELETE bool isScrollSnapInProgressForNode(std::optional<ScrollingNodeID>);
    void setNodeScrollSnapInProgress(ScrollingNodeID, bool);

    NODELETE bool isScrollAnimationInProgressForNode(std::optional<ScrollingNodeID>);
    void setScrollAnimationInProgressForNode(std::optional<ScrollingNodeID>, bool);

    NODELETE WEBCORE_EXPORT bool hasNodeWithActiveScrollAnimations();

    SWIFT_UNSAFE virtual void invalidate() { }
    WEBCORE_EXPORT bool commitTreeState(std::unique_ptr<ScrollingStateTree>&&, std::optional<LayerHostingContextIdentifier> = std::nullopt);
    SWIFT_UNSAFE bool commitTreeStateInternal(std::unique_ptr<ScrollingStateTree>&&, std::optional<LayerHostingContextIdentifier>) WTF_REQUIRES_LOCK(m_treeLock);

    WEBCORE_EXPORT virtual void applyLayerPositions();
    void setNeedsApplyLayerPositions() { m_needsApplyLayerPositions = true; }

    virtual Ref<ScrollingTreeNode> createScrollingTreeNode(ScrollingNodeType, ScrollingNodeID) = 0;
    
    SWIFT_UNSAFE WEBCORE_EXPORT ScrollingTreeNode* nodeForID(std::optional<ScrollingNodeID>) const;

    using VisitorFunction = Function<void(ScrollingNodeID, ScrollingNodeType, std::optional<FloatPoint> scrollPosition, std::optional<FloatPoint> layoutViewportOrigin, bool scrolledSinceLastCommit)>;
    void traverseScrollingTree(NOESCAPE const VisitorFunction&);

    // Called after a scrolling tree node has handled a scroll and updated its layers.
    // Updates FrameView/RenderLayer scrolling state and GraphicsLayers.
    WEBCORE_EXPORT virtual void scrollingTreeNodeDidScroll(ScrollingTreeScrollingNode&, ScrollingLayerPositionAction = ScrollingLayerPositionAction::Sync);
    virtual void scrollingTreeNodeWillStartAnimatedScroll(ScrollingTreeScrollingNode&) { }
    virtual void scrollingTreeNodeDidStopAnimatedScroll(ScrollingTreeScrollingNode&) { }
    virtual void scrollingTreeNodeWillStartWheelEventScroll(ScrollingTreeScrollingNode&) { }
    virtual void scrollingTreeNodeDidStopWheelEventScroll(ScrollingTreeScrollingNode&) { }

    // Called for requested scroll position updates. Returns true if handled.
    SWIFT_UNSAFE virtual RequestsScrollHandling scrollingTreeNodeRequestsScroll(ScrollingNodeID, const RequestedScrollData&) { return RequestsScrollHandling::Unhandled; }
    SWIFT_UNSAFE virtual bool scrollingTreeNodeRequestsKeyboardScroll(ScrollingNodeID, const RequestedKeyboardScrollData&) { return false; }

    virtual void didHandleScrollRequestForNode(ScrollingNodeID, ScrollRequestType, FloatPoint, ShouldFireScrollEnd, Markable<ScrollRequestIdentifier>) { }

    // Delegated scrolling/zooming has caused the viewport to change, so update viewport-constrained layers
    WEBCORE_EXPORT void mainFrameViewportChangedViaDelegatedScrolling(const FloatPoint& scrollPosition, const WebCore::FloatRect& layoutViewport, double scale);

    SWIFT_UNSAFE void notifyRelatedNodesAfterScrollPositionChange(ScrollingTreeScrollingNode& changedNode);

    virtual void reportSynchronousScrollingReasonsChanged(MonotonicTime, OptionSet<SynchronousScrollingReason>) { }
    virtual void reportExposedUnfilledArea(MonotonicTime, unsigned /* unfilledArea */) { }

#if PLATFORM(IOS_FAMILY)
    virtual void scrollingTreeNodeWillStartPanGesture(ScrollingNodeID) { }
#endif
    virtual void scrollingTreeNodeWillStartScroll(ScrollingNodeID) { }
    virtual void scrollingTreeNodeDidEndScroll(ScrollingNodeID) { }

    virtual void scrollingTreeNodeDidBeginScrollSnapping(ScrollingNodeID) { }
    virtual void scrollingTreeNodeDidEndScrollSnapping(ScrollingNodeID) { }

    virtual void stickyScrollingTreeNodeBeganSticking(ScrollingNodeID) { }
#if ENABLE(OVERLAY_REGIONS_REMOTE_EFFECT)
    virtual void stickyScrollingTreeNodeEndedSticking(ScrollingNodeID) { }
    virtual void scrollingTreeNodeWillBeRemoved(ScrollingNodeID) { }
#endif

    NODELETE WEBCORE_EXPORT TrackingType eventTrackingTypeForPoint(EventTrackingRegions::EventType, IntPoint);

    SWIFT_UNSAFE WEBCORE_EXPORT WebCore::RectEdges<bool> pinnedStateIncludingAncestorsAtPoint(FloatPoint);

    virtual void receivedWheelEventWithPhases(PlatformWheelEventPhase /* phase */, PlatformWheelEventPhase /* momentumPhase */) { }
    virtual void deferWheelEventTestCompletionForReason(ScrollingNodeID, WheelEventTestMonitor::DeferReason) { }
    virtual void removeWheelEventTestCompletionDeferralForReason(ScrollingNodeID, WheelEventTestMonitor::DeferReason) { }

#if PLATFORM(MAC)
    SWIFT_UNSAFE virtual void handleWheelEventPhase(ScrollingNodeID, PlatformWheelEventPhase) = 0;
#else
    SWIFT_UNSAFE void handleWheelEventPhase(ScrollingNodeID, PlatformWheelEventPhase) { }
#endif

    virtual void setActiveScrollSnapIndices(ScrollingNodeID, std::optional<unsigned> /*horizontalIndex*/, std::optional<unsigned> /*verticalIndex*/) { }

#if PLATFORM(COCOA)
    WEBCORE_EXPORT virtual void currentSnapPointIndicesDidChange(ScrollingNodeID, std::optional<unsigned> horizontal, std::optional<unsigned> vertical) = 0;
#endif

    NODELETE void setMainFramePinnedState(RectEdges<bool>);

    // Can be called from any thread. Will update what edges allow rubber-banding.
    NODELETE WEBCORE_EXPORT void setClientAllowedMainFrameRubberBandableEdges(RectEdges<RubberBandingBehavior>);
    NODELETE RubberBandingBehavior clientAllowsMainFrameRubberBandingOnSide(BoxSide);

    bool isHandlingProgrammaticScroll() const { return m_isHandlingProgrammaticScroll; }
    void setIsHandlingProgrammaticScroll(bool isHandlingProgrammaticScroll) { m_isHandlingProgrammaticScroll = isHandlingProgrammaticScroll; }

    NODELETE void setScrollPinningBehavior(ScrollPinningBehavior);
    NODELETE WEBCORE_EXPORT ScrollPinningBehavior scrollPinningBehavior();

    NODELETE WEBCORE_EXPORT bool willWheelEventStartSwipeGesture(const PlatformWheelEvent&);

    SWIFT_UNSAFE ScrollingTreeFrameScrollingNode* rootNode() const { return m_rootNode.get(); }
    NODELETE std::optional<ScrollingNodeID> latchedNodeID() const;
    NODELETE WEBCORE_EXPORT void clearLatchedNode();

    WEBCORE_EXPORT bool hasFixedOrSticky() const;
    void fixedOrStickyNodeAdded(ScrollingTreeNode&);

    // A map of overflow scrolling nodes to positioned nodes which need to be updated
    // when the scroller changes, but are not descendants.
    using RelatedNodesMap = HashMap<ScrollingNodeID, Vector<ScrollingNodeID>>;
    RelatedNodesMap& overflowRelatedNodes() LIFETIME_BOUND { return m_overflowRelatedNodesMap; }

    HashSet<Ref<ScrollingTreeOverflowScrollProxyNode>>& activeOverflowScrollProxyNodes() LIFETIME_BOUND { return m_activeOverflowScrollProxyNodes; }
    HashSet<Ref<ScrollingTreePositionedNode>>& activePositionedNodes() LIFETIME_BOUND { return m_activePositionedNodes; }

    SWIFT_UNSAFE WEBCORE_EXPORT String scrollingTreeAsText(OptionSet<ScrollingStateTreeAsTextBehavior> = { });

    SWIFT_UNSAFE WEBCORE_EXPORT float rubberbandHyperbolicCoefficientForTesting();

    bool isMonitoringWheelEvents() const { return m_isMonitoringWheelEvents; }
    void setIsMonitoringWheelEvents(bool b) { m_isMonitoringWheelEvents = b; }
    bool inCommitTreeState() const { return m_inCommitTreeState; }

    WEBCORE_EXPORT bool hasRecentActivity();

    void scrollBySimulatingWheelEventForTesting(ScrollingNodeID, FloatSize);

    SWIFT_UNSAFE virtual void lockLayersForHitTesting() { }
    SWIFT_UNSAFE virtual void unlockLayersForHitTesting() { }

    class HitTestLocker {
        WTF_MAKE_NONCOPYABLE(HitTestLocker);
    public:
        HitTestLocker(ScrollingTree& tree)
            : m_tree(tree)
        {
            m_tree->lockLayersForHitTesting();
        }
        ~HitTestLocker()
        {
            m_tree->unlockLayersForHitTesting();
        }
    private:
        const Ref<ScrollingTree> m_tree;
    };

    SWIFT_UNSAFE virtual bool isScrollingSynchronizedWithMainThread() WTF_REQUIRES_LOCK(m_treeLock) { return true; }

    Lock& treeLock() LIFETIME_BOUND WTF_RETURNS_LOCK(m_treeLock) { return m_treeLock; }

    NODELETE WEBCORE_EXPORT void windowScreenDidChange(PlatformDisplayID, std::optional<FramesPerSecond> nominalFramesPerSecond);
    NODELETE PlatformDisplayID displayID();
    WEBCORE_EXPORT virtual void displayDidRefresh(PlatformDisplayID) { }

    WEBCORE_EXPORT void willProcessWheelEvent();

    WEBCORE_EXPORT Vector<ScrollUpdate> takePendingScrollUpdates();
    NODELETE WEBCORE_EXPORT bool hasPendingScrollUpdates();

    SWIFT_UNSAFE virtual void removePendingScrollAnimationForNode(ScrollingNodeID) { }

    NODELETE SWIFT_UNSAFE WEBCORE_EXPORT FloatBoxExtent mainFrameObscuredContentInsets() const;

#if HAVE(NSREFRESHCONTROLLER)
    virtual float topScrollStretchForRefreshController() const { return 0; }
    virtual float refreshControllerSnappingThreshold() const { return 0; }
    virtual bool hasRefreshController() const { return false; }
#endif

    virtual void triggerMainFrameRubberBandSnapBack() { }
    virtual void mainFrameRubberBandTargetOffsetDidChange() { }

    NODELETE SWIFT_UNSAFE WEBCORE_EXPORT FloatPoint mainFrameScrollPosition() const;

    NODELETE WEBCORE_EXPORT ScrollbarWidth mainFrameScrollbarWidth() const;
    NODELETE WEBCORE_EXPORT std::optional<ScrollbarColor> mainFrameScrollbarColor() const;

    NODELETE WEBCORE_EXPORT OverscrollBehavior mainFrameHorizontalOverscrollBehavior() const;
    NODELETE WEBCORE_EXPORT OverscrollBehavior mainFrameVerticalOverscrollBehavior() const;
    
    NODELETE WEBCORE_EXPORT IntPoint mainFrameScrollOrigin() const;
    NODELETE WEBCORE_EXPORT int mainFrameHeaderHeight() const;
    NODELETE WEBCORE_EXPORT int mainFrameFooterHeight() const;
    NODELETE WEBCORE_EXPORT float mainFrameScaleFactor() const;
    // Used when the UI process owns the page scale but isn't sending a delegated viewport update.
    WEBCORE_EXPORT void setMainFrameDelegatedPageScaleFactor(float);
    NODELETE WEBCORE_EXPORT FloatSize totalContentsSize() const;
    NODELETE WEBCORE_EXPORT FloatRect layoutViewport() const;
    // The view size less the space the scrollbars take, in view coordinates, so it doesn't track the zoom.
    // See ScrollView::sizeForVisibleContent().
    WEBCORE_EXPORT FloatSize mainFrameSizeForVisibleContent() const;

    WEBCORE_EXPORT void viewWillStartLiveResize();
    WEBCORE_EXPORT void viewWillEndLiveResize();
    WEBCORE_EXPORT void viewSizeDidChange();
    NODELETE WEBCORE_EXPORT bool overlayScrollbarsEnabled();

    NODELETE WEBCORE_EXPORT Seconds frameDuration();
    NODELETE WEBCORE_EXPORT Seconds maxAllowableRenderingUpdateDurationForSynchronization();
    WEBCORE_EXPORT virtual void scrollingTreeNodeScrollbarVisibilityDidChange(ScrollingNodeID, ScrollbarOrientation, bool) { };
    WEBCORE_EXPORT virtual void scrollingTreeNodeScrollbarMinimumThumbLengthDidChange(WebCore::ScrollingNodeID, ScrollbarOrientation, int) { };

    SWIFT_UNSAFE void addScrollingNodeToHostedSubtreeMap(WebCore::LayerHostingContextIdentifier, Ref<ScrollingTreeFrameHostingNode>);
    SWIFT_UNSAFE void removeNode(ScrollingNodeID, ScrollingTreeFrameHostingNode* = nullptr);
    SWIFT_UNSAFE void removeFrameHostingNode(LayerHostingContextIdentifier);

    virtual void hostedSubtreeNeedsFullCommit(FrameIdentifier) { }

    NODELETE WEBCORE_EXPORT std::optional<FrameIdentifier> frameIDForScrollingNodeID(ScrollingNodeID);

protected:
    WEBCORE_EXPORT WheelEventHandlingResult handleWheelEventWithNode(const PlatformWheelEvent&, OptionSet<WheelEventProcessingSteps>, ScrollingTreeNode*, EventTargeting = EventTargeting::Propagate);

    NODELETE void setMainFrameScrollPosition(FloatPoint);

    NODELETE WEBCORE_EXPORT void setGestureState(std::optional<WheelScrollGestureState>);
    NODELETE WEBCORE_EXPORT std::optional<WheelScrollGestureState> gestureState();

    NODELETE std::optional<FramesPerSecond> nominalFramesPerSecond();

    WEBCORE_EXPORT virtual void applyLayerPositionsInternal() WTF_REQUIRES_LOCK(m_treeLock);
    WEBCORE_EXPORT void removeAllNodes() WTF_REQUIRES_LOCK(m_treeLock);
    void removeFromActiveNodes(ScrollingTreeNode&);

    virtual void hasNodeWithAnimatedScrollChanged(bool /* hasNodeWithAnimatedScroll */) { }

    bool hasProcessedWheelEventsRecently();

    HashSet<ScrollingNodeID> nodesWithActiveScrollAnimations();
    WEBCORE_EXPORT void serviceScrollAnimations(MonotonicTime) WTF_REQUIRES_LOCK(m_treeLock);

#if ENABLE(COORDINATED_TOUCH_EVENTS)
    std::optional<FloatSize> mainFrameScrollOffset() const;
#endif

    void addPendingScrollUpdateInternal(ScrollUpdate&&);
    WEBCORE_EXPORT void addPendingScrollUpdate(ScrollUpdate&&);
    virtual void didAddPendingScrollUpdate() { }

    mutable Lock m_treeLock; // Protects the scrolling tree.

private:
    bool updateTreeFromStateNodeRecursive(const ScrollingStateNode*, struct CommitTreeState&) WTF_REQUIRES_LOCK(m_treeLock);
    virtual void propagateSynchronousScrollingReasons(const HashSet<ScrollingNodeID>&) WTF_REQUIRES_LOCK(m_treeLock) { }

    void applyLayerPositionsRecursive(ScrollingTreeNode&) WTF_REQUIRES_LOCK(m_treeLock);
    void notifyRelatedNodesRecursive(ScrollingTreeNode&);
    void traverseScrollingTreeRecursive(ScrollingTreeNode&, NOESCAPE const VisitorFunction&) WTF_REQUIRES_LOCK(m_treeLock);
    
    NODELETE void setOverlayScrollbarsEnabled(bool);

    SWIFT_UNSAFE virtual void didCommitTree() { }

    SWIFT_UNSAFE WEBCORE_EXPORT virtual RefPtr<ScrollingTreeNode> scrollingNodeForPoint(FloatPoint);
#if ENABLE(WHEEL_EVENT_REGIONS)
    SWIFT_UNSAFE WEBCORE_EXPORT virtual OptionSet<EventListenerRegionType> eventListenerRegionTypesForPoint(FloatPoint) const;
#endif

    OptionSet<WheelEventProcessingSteps> computeWheelProcessingSteps(const PlatformWheelEvent&) WTF_REQUIRES_LOCK(m_treeStateLock);

    RefPtr<ScrollingTreeFrameScrollingNode> m_rootNode;

    using ScrollingTreeNodeMap = HashMap<ScrollingNodeID, Ref<ScrollingTreeNode>>;
    ScrollingTreeNodeMap m_nodeMap;

    Lock m_frameIDMapLock;
    HashMap<FrameIdentifier, HashSet<ScrollingNodeID>> m_nodeMapPerFrame WTF_GUARDED_BY_LOCK(m_frameIDMapLock);

    ScrollingTreeLatchingController m_latchingController;
    ScrollingTreeGestureState m_gestureState;

    RelatedNodesMap m_overflowRelatedNodesMap;

    HashSet<Ref<ScrollingTreeOverflowScrollProxyNode>> m_activeOverflowScrollProxyNodes;
    HashSet<Ref<ScrollingTreePositionedNode>> m_activePositionedNodes;

    struct TreeState {
        EventTrackingRegions eventTrackingRegions;
        FloatPoint mainFrameScrollPosition;
        PlatformDisplayID displayID { 0 };
        std::optional<FramesPerSecond> nominalFramesPerSecond;
        std::optional<WheelScrollGestureState> gestureState;
        HashSet<ScrollingNodeID> nodesWithActiveRubberBanding;
        HashSet<ScrollingNodeID> nodesWithActiveScrollSnap;
        HashSet<ScrollingNodeID> nodesWithActiveUserScrolls;
        HashSet<ScrollingNodeID> nodesWithActiveScrollAnimations;
    };
    
    mutable Lock m_treeStateLock;
    TreeState m_treeState WTF_GUARDED_BY_LOCK(m_treeStateLock);

    struct SwipeState {
        RectEdges<RubberBandingBehavior> clientAllowedRubberBandableEdges  { RubberBandingBehavior::Always, RubberBandingBehavior::Always, RubberBandingBehavior::Always, RubberBandingBehavior::Always };
        RectEdges<bool> mainFramePinnedState { true, true, true, true };
        ScrollPinningBehavior scrollPinningBehavior { ScrollPinningBehavior::DoNotPin };
    };

    Lock m_swipeStateLock;
    SwipeState m_swipeState WTF_GUARDED_BY_LOCK(m_swipeStateLock);

    Lock m_pendingScrollUpdatesLock;
    Vector<ScrollUpdate> m_pendingScrollUpdates WTF_GUARDED_BY_LOCK(m_pendingScrollUpdatesLock);

#if HAVE(RUBBER_BANDING)
    std::optional<RubberbandingState> m_pendingMainFrameRubberbandingState WTF_GUARDED_BY_LOCK(m_treeLock);
#endif

    Lock m_lastWheelEventTimeLock;
    MonotonicTime m_lastWheelEventTime WTF_GUARDED_BY_LOCK(m_lastWheelEventTimeLock);

    HashMap<LayerHostingContextIdentifier, Vector<std::unique_ptr<ScrollingStateTree>>> m_hostedSubtreesNeedingPairing;
    HashMap<LayerHostingContextIdentifier, Ref<ScrollingTreeFrameHostingNode>> m_hostedSubtrees;

protected:
    bool m_allowLatching { true };

private:
    bool m_hasLockedAccess WTF_GUARDED_BY_LOCK(m_treeLock) { false }; // Whether a ScrollingTreeLockedAccess for this tree exists.
    ThreadSafeWeakHashSet<ScrollingTreeNode> m_fixedOrStickyNodes;
    std::atomic<bool> m_isHandlingProgrammaticScroll { false };
    std::atomic<bool> m_needsApplyLayerPositions { false };
    bool m_isMonitoringWheelEvents { false };
    bool m_scrollingPerformanceTestingEnabled { false };
    bool m_overlayScrollbarsEnabled { false };
    bool m_asyncFrameOrOverflowScrollingEnabled { false };
    bool m_wheelEventGesturesBecomeNonBlocking { false };
    bool m_inCommitTreeState { false };
};

// Witness that a scrolling tree's m_treeLock is held, for Swift: Swift calls the members of the tree and of its nodes
// that need the lock through one of these, and cannot make one itself. Only code that holds the tree lock constructs
// one (the constructor requires the lock, and Swift may not call it), and the lock stays held until it is destroyed:
// it must not be constructed in a scope that drops the lock, such as the Condition waits on m_treeLock in
// ThreadedScrollingTree::waitForEventToBeProcessedByMainThread(),
// ThreadedScrollingTree::waitForRenderingUpdateCompletionOrTimeout() and
// RemoteScrollingTreeMac::waitForEventDefaultHandlingCompletion(). Only one exists for a tree at a time; constructing
// a second one while the first is alive crashes. The frame that declares the Locker holds a Ref to the tree declared
// before the Locker, and no frame from that one down to the witness holds a reference or iterator into the tree's or
// its nodes' storage.
// It cannot be copied, moved or put on the heap, so it lives in the frame that holds the lock, and Swift receives it
// borrowed for one call. Each member checks that the lock is locked and that the nodes it is given belong to its tree.
// The code that constructs it chooses its mode: ScrollingTreeAccessMode::Commit only in ScrollingTree::commitTreeState()
// and what it calls, the thread that writes the tree's structure, whose readers on that thread take no lock. The members
// that change the tree's structure (the root, the node map, the hosted subtrees, a node's parent, children and hosted
// children) and the node commit members crash on a witness of mode Event, such as one handed to the wheel event entries.
class SWIFT_NONCOPYABLE __attribute__((swift_attr("~Sendable"))) WEBCORE_EXPORT ScrollingTreeLockedAccess {
    WTF_MAKE_NONCOPYABLE(ScrollingTreeLockedAccess);
    WTF_FORBID_HEAP_ALLOCATION;
public:
    SWIFT_UNSAFE ScrollingTreeLockedAccess(ScrollingTree& tree, ScrollingTreeAccessMode) WTF_REQUIRES_LOCK(tree.treeLock());
    // Swift imports a noncopyable class only if it has a move constructor, so one is declared; it traps.
    [[noreturn]] ScrollingTreeLockedAccess(ScrollingTreeLockedAccess&&);
    ScrollingTreeLockedAccess& operator=(ScrollingTreeLockedAccess&&) = delete;
    // Swift would otherwise give the class an init() that zero-fills it.
    ScrollingTreeLockedAccess() = delete;
    ~ScrollingTreeLockedAccess();

    RefPtr<ScrollingTreeNode> nodeForID(ScrollingNodeID) const;
    RefPtr<ScrollingTreeFrameScrollingNode> rootNode() const;
    // On a RemoteScrollingTreeMac the caller must also hold the layer hit-test lock, which the witness does not show.
    SWIFT_UNSAFE RefPtr<ScrollingTreeNode> scrollingNodeForPoint(FloatPoint) const;
    void removeNode(ScrollingNodeID) const;
    void removeNode(ScrollingNodeID, ScrollingTreeFrameHostingNode&) const;
    void addScrollingNodeToHostedSubtreeMap(LayerHostingContextIdentifier, ScrollingTreeFrameHostingNode&) const;
    void removeFrameHostingNode(LayerHostingContextIdentifier) const;

    bool commitStateBeforeChildren(ScrollingTreeNode&, const ScrollingStateNode&) const;
    bool commitStateAfterChildren(ScrollingTreeNode&, const ScrollingStateNode&) const;
    void didCompleteCommitForNode(ScrollingTreeNode&) const;
    void willBeDestroyed(ScrollingTreeNode&) const;
    RefPtr<ScrollingTreeNode> parent(ScrollingTreeNode&) const;
    void setParent(ScrollingTreeNode&, ScrollingTreeNode* parent) const;
    void appendChild(ScrollingTreeNode& parent, ScrollingTreeNode& child) const;
    void removeChild(ScrollingTreeNode& parent, ScrollingTreeNode& child) const;
    void removeAllChildren(ScrollingTreeNode&) const;
    // The child at index of node, which must be less than childCount(node): an index past the end crashes. The result
    // is never null. Swift iterates by index, holding no iterator into the children across calls.
    size_t childCount(ScrollingTreeNode&) const;
    RefPtr<ScrollingTreeNode> childAt(ScrollingTreeNode&, size_t index) const;

    // The tree's root node; null is allowed. The node must belong to the tree.
    void setRootNode(ScrollingTreeFrameScrollingNode*) const;
    void removeAllNodes() const;
    // Adds node to the node map under its ID, replacing any node with that ID, and to the nodes of frameID.
    void addNode(ScrollingTreeNode&, FrameIdentifier) const;

    WheelEventHandlingResult handleWheelEvent(ScrollingTreeScrollingNode&, const PlatformWheelEvent&, EventTargeting) const;
    void stopSpringAnimation(ScrollingTreeScrollingNode&) const;
    void serviceScrollAnimation(ScrollingTreeScrollingNode&, MonotonicTime) const;
    void scrollTo(ScrollingTreeScrollingNode&, const FloatPoint&, ScrollType, ScrollClamping) const;
    void scrollBy(ScrollingTreeScrollingNode&, const FloatSize&, ScrollClamping) const;
    void handleWheelEventPhase(ScrollingNodeID, PlatformWheelEventPhase) const;

    void setLayerHostingContextIdentifier(ScrollingTreeFrameHostingNode&, std::optional<LayerHostingContextIdentifier>) const;
    void addHostedChild(ScrollingTreeFrameHostingNode&, ScrollingTreeNode& child) const;
    void removeHostedChildren(ScrollingTreeFrameHostingNode&) const;
    void removeHostedChild(ScrollingTreeFrameHostingNode&, ScrollingTreeNode& child) const;

private:
    ScrollingTree& tree() const;
    void checkNode(const ScrollingTreeNode&) const;
    void checkCommit() const;

    const Ref<ScrollingTree> m_tree;
    const ScrollingTreeAccessMode m_mode;
};

class ScrollingTreeWheelEventTestMonitorCompletionDeferrer {
public:
    ScrollingTreeWheelEventTestMonitorCompletionDeferrer(ScrollingTree& scrollingTree, ScrollingNodeID nodeID, WheelEventTestMonitor::DeferReason reason)
        : m_scrollingTree(scrollingTree)
        , m_scrollingNodeID(nodeID)
        , m_deferReason(reason)
    {
        m_scrollingTree->deferWheelEventTestCompletionForReason(m_scrollingNodeID, m_deferReason);
    }
    
    ~ScrollingTreeWheelEventTestMonitorCompletionDeferrer()
    {
        m_scrollingTree->removeWheelEventTestCompletionDeferralForReason(m_scrollingNodeID, m_deferReason);
    }

private:
    const Ref<ScrollingTree> m_scrollingTree;
    ScrollingNodeID m_scrollingNodeID;
    WheelEventTestMonitor::DeferReason m_deferReason;
};

} // namespace WebCore

#define SPECIALIZE_TYPE_TRAITS_SCROLLING_TREE(ToValueTypeName, predicate) \
SPECIALIZE_TYPE_TRAITS_BEGIN(ToValueTypeName) \
    static bool isType(const WebCore::ScrollingTree& tree) { return tree.predicate; } \
SPECIALIZE_TYPE_TRAITS_END()
#endif // ENABLE(ASYNC_SCROLLING)
