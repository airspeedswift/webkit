// Copyright (C) 2022 Apple Inc. All rights reserved.
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

extension WebKit.WebSharedWorker {
    @cxx
    @implementation
    func didCreateContextConnection(_ contextConnection: WebKit.WebSharedWorkerServerToContextConnection) {
        forEachSharedWorkerObjectIdentifier { contextConnection.addSharedWorkerObject($0) }
        if didFinishFetching() {
            launch(contextConnection)
        }
    }

    @cxx
    @implementation
    func launch(_ connection: WebKit.WebSharedWorkerServerToContextConnection) {
        connection.launchSharedWorker(self)
        if m_isSuspended {
            connection.suspendSharedWorker(sharedWorkerIdentifier())
        }
    }

    @cxx
    @implementation
    func removeSharedWorkerObject(_ sharedWorkerObjectIdentifier: WebCore.SharedWorkerObjectIdentifier) {
        SharedWorkerObjectsOperations.remove(self, Object(identifier: sharedWorkerObjectIdentifier, state: SharedWorkerObjectState()))
        contextConnection()?.removeSharedWorkerObject(sharedWorkerObjectIdentifier)

        suspendIfNeeded()
    }

    @cxx
    @implementation
    func suspendIfNeeded() {
        guard !m_isSuspended else {
            return
        }

        for sharedWorkerObject in SharedWorkerObjectsOperations.copyValues(self) where !sharedWorkerObject.state.isSuspended {
            return
        }

        m_isSuspended = true
        contextConnection()?.suspendSharedWorker(sharedWorkerIdentifier())
    }

    @cxx
    @implementation
    func resumeIfNeeded() {
        guard m_isSuspended else {
            return
        }

        m_isSuspended = false
        contextConnection()?.resumeSharedWorker(sharedWorkerIdentifier())
    }

    // Swift cannot pass forEachSharedWorkerObject() a Function.
    func forEachSharedWorkerObjectIdentifier(_ body: (WebCore.SharedWorkerObjectIdentifier) -> Void) {
        for sharedWorkerObject in SharedWorkerObjectsOperations.copyValues(self) {
            body(sharedWorkerObject.identifier)
        }
    }
}
