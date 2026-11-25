// Copyright (C) 2018 Apple Inc. All rights reserved.
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

// Swift operators import every visible C++ operator of the same name; these modules define reference types that some of
// them name (rdar://192229293).
#if canImport(JavaScriptCore_Private) // Not a module outside Apple platforms, where the headers are textual.
internal import JavaScriptCore_Private.Cxx.DOMJITCallDOMGetterSnippet
internal import JavaScriptCore_Private.Cxx.Snippet
internal import JavaScriptCore_Private.Cxx.WasmCalleeGroup
internal import JavaScriptCore_Private.Cxx.WasmInstanceAnchor
internal import JavaScriptCore_Private.Cxx.WasmModule
internal import JavaScriptCore_Private.Cxx.WasmModuleDebugInfo
#endif
internal import CxxStdlib
internal import WebCore_Private.Core.MessagePortChannel
internal import WebCore_Private.Core.MessagePortChannelRegistry
internal import wtf.Core.MainThread
internal import wtf.Core.MemberContainerOperations

extension WebCore.MessagePortChannelRegistry {
    /// Records a new channel under each of its two ports.
    @cxx
    @implementation
    public func messagePortChannelCreated(_ channel: WebCore.MessagePortChannel) {
        WTF.assertIsMainThread()

        let isNewEntryForPort1 = OpenChannelsOperations.add(self, channel.port1(), channel)
        assert(isNewEntryForPort1)

        let isNewEntryForPort2 = OpenChannelsOperations.add(self, channel.port2(), channel)
        assert(isNewEntryForPort2)
    }

    /// Entangles the local port with the process, if its channel is still open.
    @cxx
    @implementation
    public func didEntangleLocalToRemote(
        _ local: WebCore.MessagePortIdentifier,
        _ remote: WebCore.MessagePortIdentifier,
        _ process: WebCore.ProcessIdentifier
    ) {
        WTF.assertIsMainThread()

        // The channel might be gone if the remote side was closed.
        guard let channel = OpenChannelsOperations.get(self, local) else {
            return
        }

        assert(channel.includesPort(remote))

        channel.entanglePortWithProcess(local, process)
    }

    /// Disentangles the port from its process, if its channel is still open.
    @cxx
    @implementation
    public func didDisentangleMessagePort(_ port: WebCore.MessagePortIdentifier) {
        WTF.assertIsMainThread()

        // The channel might be gone if the remote side was closed.
        OpenChannelsOperations.get(self, port)?.disentanglePort(port)
    }

    /// Records the process a port is being transferred from.
    @cxx
    @implementation
    public func recordPendingTransferOrigin(_ port: WebCore.MessagePortIdentifier, _ origin: WebCore.ProcessIdentifier) {
        WTF.assertIsMainThread()
        PendingTransferOriginsOperations.set(self, port, origin)
    }
}
