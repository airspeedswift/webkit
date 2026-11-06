// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.


import WebKit_Internal

/// What RemoteScrollingCoordinator::scrollUpdateForNode() does with a scroll update from the UI process: drop it, apply
/// it as it came, or apply it as a position update that sets the layer position, firing scrollend or not.
@_expose(Cxx)
struct RemoteScrollingCoordinatorScrollUpdateAction {
    // @used ensures these, and the type metadata, are retained even under -O -wmo: rdar://179098545
    @used
    static let cxxTypeMetadata: Any.Type = Self.self

    fileprivate var appliesUpdateValue = false
    fileprivate var appliesPositionUpdateValue = false
    fileprivate var firesScrollEndValue = false

    fileprivate init() {
    }

    @used
    func appliesUpdate() -> Bool { appliesUpdateValue }
    @used
    func appliesPositionUpdate() -> Bool { appliesPositionUpdateValue }
    @used
    func firesScrollEnd() -> Bool { firesScrollEndValue }
}

/// The scroll requests one RemoteScrollingCoordinator has sent to the UI process and not yet seen answered, by
/// scrolling node: the identifier of the latest one, and whether an answer to an earlier one asked for scrollend. Its
/// entries are called on the web process's main thread.
@_expose(Cxx)
final class RemoteScrollingCoordinatorPendingScrollRequests {
    // A ScrollingNodeID's process identifier and object identifier.
    fileprivate struct NodeKey: Hashable {
        let processIdentifier: UInt64
        let object: UInt64
    }

    private struct PendingResponse {
        // A ScrollRequestIdentifier's value.
        var identifier: UInt64
        var pendingScrollEnd = false
    }

    private var pendingResponses: [NodeKey: PendingResponse] = [:]

    // @used ensures these are retained even under -O -wmo: rdar://179098545
    @used
    init() {
    }

    fileprivate func willSendScrollPositionRequest(_ node: NodeKey, _ identifier: UInt64) {
        // This may clobber an older one, but that's OK.
        pendingResponses[node] = PendingResponse(identifier: identifier)
    }

    fileprivate func scrollUpdate(
        _ node: NodeKey,
        _ isResponse: Bool,
        _ responseIdentifier: UInt64,
        _ firesScrollEnd: Bool,
        _ responseUpdatesPosition: Bool
    ) -> RemoteScrollingCoordinatorScrollUpdateAction {
        var action = RemoteScrollingCoordinatorScrollUpdateAction()
        guard isResponse else {
            // A user scroll that overlaps a scroll request in flight would apply a stale position.
            action.appliesUpdateValue = pendingResponses[node] == nil
            return action
        }

        assert(responseIdentifier != 0)
        guard responseIdentifier != 0 else {
            return action
        }

        // We should at least be waiting for the identifier we've just received back.
        assert(pendingResponses[node] != nil)
        guard var pending = pendingResponses[node] else {
            return action
        }
        assert(responseIdentifier <= pending.identifier)

        pending.pendingScrollEnd = pending.pendingScrollEnd || firesScrollEnd
        guard pending.identifier == responseIdentifier else {
            // A response to an older request is stale; its scrollend fires with the latest one's.
            pendingResponses[node] = pending
            return action
        }
        pendingResponses[node] = nil

        if responseUpdatesPosition {
            action.appliesUpdateValue = true
            action.appliesPositionUpdateValue = true
            action.firesScrollEndValue = pending.pendingScrollEnd
        } else if pending.pendingScrollEnd {
            // This just ensures that the scrollend is fired.
            action.appliesUpdateValue = true
        }
        return action
    }
}

/// Called on the web process's main thread when RemoteScrollingCoordinator sends a scroll request for a node to the UI
/// process, with the node's ScrollingNodeID as its two identifiers and the request's ScrollRequestIdentifier value.
@_expose(Cxx)
@used
nonisolated func remoteScrollingCoordinatorWillSendScrollPositionRequest(
    _ requests: RemoteScrollingCoordinatorPendingScrollRequests,
    _ nodeProcessIdentifier: UInt64,
    _ nodeObjectIdentifier: UInt64,
    _ identifier: UInt64
) {
    requests.willSendScrollPositionRequest(
        .init(processIdentifier: nodeProcessIdentifier, object: nodeObjectIdentifier),
        identifier
    )
}

/// Called on the web process's main thread for each scroll update the UI process sends RemoteScrollingCoordinator, with
/// the node's ScrollingNodeID as its two identifiers; whether the update answers a scroll request; that answer's
/// ScrollRequestIdentifier value, or 0 if it has none; whether the update fires scrollend; and whether the answer is to
/// a position update the UI process did not discard.
@_expose(Cxx)
@used
nonisolated func remoteScrollingCoordinatorScrollUpdate(
    _ requests: RemoteScrollingCoordinatorPendingScrollRequests,
    _ nodeProcessIdentifier: UInt64,
    _ nodeObjectIdentifier: UInt64,
    _ isResponse: Bool,
    _ responseIdentifier: UInt64,
    _ firesScrollEnd: Bool,
    _ responseUpdatesPosition: Bool
) -> RemoteScrollingCoordinatorScrollUpdateAction {
    requests.scrollUpdate(
        .init(processIdentifier: nodeProcessIdentifier, object: nodeObjectIdentifier),
        isResponse,
        responseIdentifier,
        firesScrollEnd,
        responseUpdatesPosition
    )
}
