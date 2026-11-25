// Copyright (C) 2022-2025 Apple Inc. All rights reserved.
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

extension WebKit.WebSharedWorkerServer {
    // A null worker logs as 0x0, as %p prints it.
    private static func formattedAddress(of sharedWorker: WebKit.WebSharedWorker?) -> Swift.String {
        sharedWorker?.logAddress().description ?? "0x0"
    }

    @cxx
    @implementation
    func needsContextConnectionForRegistrableDomain(_ registrableDomain: WebCore.RegistrableDomain) -> Bool {
        for sharedWorker in SharedWorkersOperations.copyValues(self)
        where registrableDomain == sharedWorker.ptr().topRegistrableDomain() {
            return true
        }
        return false
    }

    @cxx
    @implementation
    func sharedWorkerObjectIsGoingAway(
        _ sharedWorkerKey: WebCore.SharedWorkerKey,
        _ sharedWorkerObjectIdentifier: WebCore.SharedWorkerObjectIdentifier
    ) {
        let sharedWorker = SharedWorkersOperations.get(self, sharedWorkerKey)
        WebKit.LogChannel.SharedWorker().releaseLog
            .log(
                "WebSharedWorkerServer::sharedWorkerObjectIsGoingAway: sharedWorkerObjectIdentifier=\(sharedWorkerObjectIdentifier.toString().description, privacy: .public), sharedWorker=\(Self.formattedAddress(of: sharedWorker), privacy: .public)"
            )
        guard let sharedWorker else {
            return
        }

        sharedWorker.removeSharedWorkerObject(sharedWorkerObjectIdentifier)
        guard sharedWorker.sharedWorkerObjectsCount() == 0 else {
            return
        }

        shutDownSharedWorker(sharedWorkerKey)
    }

    @cxx
    @implementation
    func shutDownSharedWorker(_ key: WebCore.SharedWorkerKey) {
        let sharedWorker = SharedWorkersOperations.get(self, key)
        SharedWorkersOperations.remove(self, key)
        WebKit.LogChannel.SharedWorker().releaseLog
            .log(
                "WebSharedWorkerServer::shutDownSharedWorker: sharedWorkerIdentifier=\(sharedWorker?.sharedWorkerIdentifier().toUInt64() ?? 0), sharedWorker=\(Self.formattedAddress(of: sharedWorker), privacy: .public)"
            )
        guard let sharedWorker else {
            return
        }

        sharedWorker.contextConnection()?.terminateSharedWorker(sharedWorker)
    }

    @cxx
    @implementation
    func postErrorToWorkerObject(
        _ sharedWorkerIdentifier: WebCore.SharedWorkerIdentifier,
        _ errorMessage: WTF.String,
        _ lineNumber: Int32,
        _ columnNumber: Int32,
        _ sourceURL: WTF.String,
        _ isErrorEvent: Bool
    ) {
        let sharedWorker = WebKit.WebSharedWorker.fromIdentifier(sharedWorkerIdentifier)
        WebKit.LogChannel.SharedWorker().releaseLog
            .error(
                "WebSharedWorkerServer::postErrorToWorkerObject: sharedWorkerIdentifier=\(sharedWorkerIdentifier.toUInt64()), sharedWorker=\(Self.formattedAddress(of: sharedWorker), privacy: .public)"
            )
        guard let sharedWorker else {
            return
        }

        sharedWorker.forEachSharedWorkerObjectIdentifier { sharedWorkerObjectIdentifier in
            ConnectionsOperations.get(self, sharedWorkerObjectIdentifier.processIdentifier())?
                .postErrorToWorkerObject(sharedWorkerObjectIdentifier, errorMessage, lineNumber, columnNumber, sourceURL, isErrorEvent)
        }
    }
}
