// Copyright (C) 2021 Apple Inc. All rights reserved.
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

extension WebKit.NetworkBroadcastChannelRegistry {
    @cxx
    @implementation
    func registerChannel(_ connection: IPC.Connection, _ origin: WebCore.ClientOrigin, _ name: WTF.String) {
        dispatchMessage(on: connection) { () throws(InvalidMessage) in
            try checkChannelMessage(from: connection, origin: origin, name: name)

            let connectionID = connection.uniqueID()
            assert(!BroadcastChannelsOperations.containsIn(self, origin, name, connectionID))
            BroadcastChannelsOperations.appendTo(self, origin, name, connectionID)
        }
    }

    @cxx
    @implementation
    func unregisterChannel(_ connection: IPC.Connection, _ origin: WebCore.ClientOrigin, _ name: WTF.String) {
        dispatchMessage(on: connection) { () throws(InvalidMessage) in
            try checkChannelMessage(from: connection, origin: origin, name: name)

            let connectionID = connection.uniqueID()
            assert(BroadcastChannelsOperations.containsIn(self, origin, name, connectionID))
            BroadcastChannelsOperations.removeFirstFrom(self, origin, name, connectionID)
        }
    }

    @cxx
    @implementation
    func removeConnection(_ connection: IPC.Connection) {
        BroadcastChannelsOperations.removeFirstFromAllAndPrune(self, connection.uniqueID())
    }

    private func checkChannelMessage(
        from connection: IPC.Connection,
        origin: WebCore.ClientOrigin,
        name: WTF.String,
        function: StaticString = #function
    ) throws(InvalidMessage) {
        try messageCheck("isValidClientOrigin(origin)", function: function) {
            Self.isValidClientOrigin(origin)
        }
        try messageCheck("!name.isNull()", function: function) {
            !name.isNull()
        }
        try messageCheck("isOriginAllowedForConnection(connection, origin)", function: function) {
            isOriginAllowedForConnection(connection, origin)
        }
    }
}
