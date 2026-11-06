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

// The update of the scrolling tree from a scrolling state tree, and the walk over a node's ancestors that propagates
// synchronous scrolling reasons after a commit.

internal import WebCore_Private.Core.FloatPoint
internal import WebCore_Private.Core.FloatRect
internal import WebCore_Private.Core.FrameIdentifier
internal import WebCore_Private.Core.ProcessQualified
internal import WebCore_Private.Core.ScrollingCoordinatorTypes
internal import WebCore_Private.Core.ScrollingNodeID
internal import WebCore_Private.Core.ScrollingStateNode
internal import WebCore_Private.Core.ScrollingTree
internal import WebCore_Private.Core.ScrollingTreeFrameHostingNode
internal import WebCore_Private.Core.ScrollingTreeFrameScrollingNode
internal import WebCore_Private.Core.ScrollingTreeNode
internal import WebCore_Private.Core.ScrollingTreeOverflowScrollProxyNode
internal import WebCore_Private.Core.ScrollingTreeScrollingNode

/// ScrollingTree::commitTreeState()'s update of `tree` from the scrolling state tree, from `stateNode` down: a null
/// `stateNode` removes every node. Called on the thread that commits (the main thread of the web process or of the UI
/// process) with the tree's lock held, which `locked` shows, inside ScrollingTree::commitTreeState(), which owns the
/// state tree: no other thread reaches it. `tree` is the tree that created `locked`.
///
/// The nodes this calls node members on directly are `tree`'s: the ones its node map returns, the ones its
/// createScrollingTreeNode() makes, and their parents, which only this commit sets.
///
/// `frameID` is the frame the commit is for, and `frameHostingNode` the hosting node when it commits a hosted subtree.
/// `state` is the CommitTreeState on ScrollingTree::commitTreeStateInternal()'s stack, which only that function
/// constructs. What this calls reaches it only through `state`: `locked`'s members, the tree's
/// createScrollingTreeNode() and the nodes' getters do not refer to it. Returns false when the commit fails.
@_expose(Cxx)
nonisolated func updateScrollingTreeFromStateNode(
    _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ tree: WebCore.ScrollingTree,
    _ stateNode: WebCore.ScrollingStateNode?, _ frameID: WebCore.FrameIdentifier,
    _ frameHostingNode: WebCore.ScrollingTreeFrameHostingNode?, _ state: inout WebCore.ScrollingTreeCommitState
) -> Bool {
    guard let stateNode else {
        locked.removeAllNodes()
        locked.setRootNode(nil)
        return true
    }
    return updateScrollingTreeFromStateNode(locked, tree, stateNode, frameID, frameHostingNode, &state)
}

/// A node of the walk below whose children are being committed: its tree node and state node, and the index of the
/// next state child to commit, or nil when its children are not committed (the root of a hosted subtree).
private struct ScrollingTreeCommitFrame {
    let node: WebCore.ScrollingTreeNode
    let stateNode: WebCore.ScrollingStateNode
    var nextChildIndex: Int?
}

/// What visiting one state node did to the tree.
private enum ScrollingTreeCommitVisit {
    /// The node's commitStateBeforeChildren() failed; the commit stops.
    case failed
    /// The node's parent is not in the tree, so the node was removed and its children are not visited.
    case removed
    /// The node was committed before its children. The index of its first state child to commit, or nil when its
    /// children are not committed.
    case committing(WebCore.ScrollingTreeNode, Int?)
}

/// Creates `stateNode`'s tree node if the tree has none, makes it a child of its parent, and calls its
/// commitStateBeforeChildren().
@inline(always)
private func visitStateNode(
    _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ tree: WebCore.ScrollingTree,
    _ stateNode: WebCore.ScrollingStateNode, _ frameID: WebCore.FrameIdentifier,
    _ frameHostingNode: WebCore.ScrollingTreeFrameHostingNode?, _ state: inout WebCore.ScrollingTreeCommitState
) -> ScrollingTreeCommitVisit {
    let nodeID = stateNode.scrollingNodeID()
    var parentNodeID = Optional(fromCxx: stateNode.parentNodeID())
    if parentNodeID == nil, let frameHostingNode, stateNode.isFrameScrollingNode() {
        parentNodeID = frameHostingNode.scrollingNodeID()
    }

    let node: WebCore.ScrollingTreeNode
    if let existingNode = unsafe tree.nodeForID(.init(nodeID)) { // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope
        node = existingNode
        state.didVisitNode(nodeID)
    } else {
        node = tree.createScrollingTreeNode(stateNode.nodeType(), nodeID).get()
        if parentNodeID == nil {
            // This is the root node. Clear the node map.
            guard let frameScrollingNode = WebCore.asScrollingTreeFrameScrollingNode(node).get() else {
                return .failed
            }
            locked.setRootNode(frameScrollingNode)
            locked.removeAllNodes()
        }
        locked.addNode(node, frameID)
    }

    if let parentNodeID {
        if let parent = unsafe tree.nodeForID(.init(parentNodeID)) { // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope
            let oldParent = unsafe node.parent().get() // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope
            if let oldParent {
                unsafe oldParent.removeChild(node) // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope
            }
            // appendChild() sets the parent as well.
            if oldParent == nil || !oldParent!.scrollingNodeID().isEqual(parent.scrollingNodeID()) {
                unsafe node.setParentNode(parent) // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope; both nodes are this tree's: parent from its node map, node from its node map or its createScrollingTreeNode() above
            }
            unsafe parent.appendChild(node) // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope; both nodes are this tree's: parent from its node map, node from its node map or its createScrollingTreeNode() above
        } else {
            if let frameHostingNode {
                locked.removeNode(nodeID, frameHostingNode)
            } else {
                locked.removeNode(nodeID)
            }
            return .removed
        }
    }

    if unsafe !node.commitStateBeforeChildren(stateNode) { // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope
        return .failed
    }

    // The children of a hosted subtree's root are not in this state tree.
    if node.isRootOfHostedSubtree() {
        return .committing(node, nil)
    }
    // The children become orphans, which the commit keeps alive; the live ones are added back below.
    state.orphanChildren(node)
    return .committing(node, 0)
}

/// From `rootStateNode` down, in the order of a depth-first walk, each state node's tree node is created if the tree
/// has none, made a child of its parent, and committed with its children: commitStateBeforeChildren(), the
/// children, commitStateAfterChildren(), didCompleteCommitForNode(). A node whose parent is not in the tree is
/// removed, and its children are not visited. The node whose children are being committed is held in the
/// `current` locals, and `stack` holds its ancestors.
private func updateScrollingTreeFromStateNode(
    _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ tree: WebCore.ScrollingTree,
    _ rootStateNode: WebCore.ScrollingStateNode, _ frameID: WebCore.FrameIdentifier,
    _ frameHostingNode: WebCore.ScrollingTreeFrameHostingNode?, _ state: inout WebCore.ScrollingTreeCommitState
) -> Bool {
    var currentNode: WebCore.ScrollingTreeNode
    var currentStateNode = rootStateNode
    var currentNextChildIndex: Int?
    switch visitStateNode(locked, tree, rootStateNode, frameID, frameHostingNode, &state) {
    case .failed:
        return false
    case .removed:
        return true
    case .committing(let node, let nextChildIndex):
        currentNode = node
        currentNextChildIndex = nextChildIndex
    }

    var stack = UniqueArray<ScrollingTreeCommitFrame>(capacity: 8)
    while true {
        if let childIndex = currentNextChildIndex,
            let child = WebCore.scrollingStateChildAtIndex(currentStateNode, childIndex) {
            // childIndex is below the state node's child count, so this cannot wrap.
            currentNextChildIndex = childIndex &+ 1
            switch visitStateNode(locked, tree, child, frameID, frameHostingNode, &state) {
            case .failed:
                return false
            case .removed:
                break
            case .committing(let node, let nextChildIndex):
                stack.append(ScrollingTreeCommitFrame(
                    node: currentNode, stateNode: currentStateNode, nextChildIndex: currentNextChildIndex))
                currentNode = node
                currentStateNode = child
                currentNextChildIndex = nextChildIndex
            }
            continue
        }

        if unsafe !currentNode.commitStateAfterChildren(currentStateNode) { // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope
            return false
        }

        unsafe currentNode.didCompleteCommitForNode() // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope

        state.didCommitNode(currentNode)

        if stack.isEmpty {
            return true
        }
        let parentFrame = stack.removeLast()
        currentNode = parentFrame.node
        currentStateNode = parentFrame.stateNode
        currentNextChildIndex = parentFrame.nextChildIndex
    }
}

/// ThreadedScrollingTree::propagateSynchronousScrollingReasons() for one node with synchronous scrolling reasons:
/// unless `node` is a frame scrolling node, marks the scrolling nodes that enclose it, up to and including the
/// enclosing frame scrolling node, as having descendant scrollers with synchronous scrolling. An overflow scroll
/// proxy node is followed to its overflow scrolling node. Called on the thread that commits (the web process's main
/// thread) inside ScrollingTree::commitTreeState(), with the tree's lock held, which `locked` shows.
@_expose(Cxx)
nonisolated func propagateSynchronousScrollingReasonsToAncestors(
    _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ node: WebCore.ScrollingTreeNode
) {
    if node.isFrameScrollingNode() {
        return
    }

    // `node` is the caller's, so `locked` checks that it is this tree's; its ancestors are then this tree's too.
    var currentNode = locked.parent(node).get()
    while let current = currentNode {
        if let scrollingNode = WebCore.asScrollingTreeScrollingNode(current).get() {
            scrollingNode.addSynchronousScrollingReason(.DescendantScrollersHaveSynchronousScrolling)
        }

        if let proxyNode = WebCore.asScrollingTreeOverflowScrollProxyNode(current).get() {
            // A proxy node without an overflow scrolling node ends the walk.
            if let overflowScrollingNodeID = Optional(fromCxx: proxyNode.overflowScrollingNodeID()) {
                currentNode = locked.nodeForID(overflowScrollingNodeID).get()
            } else {
                currentNode = nil
            }
            continue
        }

        if current.isFrameScrollingNode() {
            break
        }

        currentNode = unsafe current.parent().get() // U5(m_treeLock): held by commitTreeState()'s Locker, which calls in; locked is in scope
    }
}

/// ScrollingTree::mainFrameViewportChangedViaDelegatedScrolling() once it holds the tree's lock: the root node takes
/// the page scale and is scrolled to `scrollPosition` with `layoutViewport`, and its scrolling layers are repositioned
/// when the scale changed. Called on the UI process's main thread (delegated scrolling) inside that member, which
/// takes a Ref to the tree, then the tree's lock, and creates `locked` for this call only.
@_expose(Cxx)
nonisolated func scrollingTreeMainFrameViewportChangedViaDelegatedScrolling(
    _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ scrollPosition: WebCore.FloatPoint,
    _ layoutViewport: WebCore.FloatRect, _ scale: Double
) {
    guard let rootNode = locked.rootNode().get() else {
        return
    }

    // wasScrolledByDelegatedScrolling() bails out when the position is unchanged, but the scrolled contents
    // layer's position is scaled by this, so a scale change on its own still needs a reposition.
    let scaleChanged = rootNode.delegatedPageScaleFactor() != Float(scale)
    rootNode.setDelegatedPageScaleFactor(Float(scale))
    unsafe rootNode.wasScrolledByDelegatedScrolling(scrollPosition, .init(layoutViewport), .Sync) // U5(m_treeLock): held by the C++ Locker in mainFrameViewportChangedViaDelegatedScrolling(), which calls in; locked is in scope
    if scaleChanged {
        unsafe rootNode.repositionScrollingLayersForDelegatedScaleChange() // U5(m_treeLock): held by the C++ Locker in mainFrameViewportChangedViaDelegatedScrolling(), which calls in; locked is in scope
    }
}

/// ScrollingTree::setMainFrameDelegatedPageScaleFactor() once it holds the tree's lock: when `scale` differs from
/// the root node's page scale, the root node takes it and its scrolling layers are repositioned. Called on the UI
/// process's main thread (delegated scrolling) inside that member, which takes a Ref to the tree, then the tree's
/// lock, and creates `locked` for this call only.
@_expose(Cxx)
nonisolated func scrollingTreeSetMainFrameDelegatedPageScaleFactor(
    _ locked: borrowing WebCore.ScrollingTreeLockedAccess, _ scale: Float
) {
    guard let rootNode = locked.rootNode().get(), rootNode.delegatedPageScaleFactor() != scale else {
        return
    }

    rootNode.setDelegatedPageScaleFactor(scale)
    unsafe rootNode.repositionScrollingLayersForDelegatedScaleChange() // U5(m_treeLock): held by the C++ Locker in setMainFrameDelegatedPageScaleFactor(), which calls in; locked is in scope
}
