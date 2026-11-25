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

extension WebKit.WebSharedWorkerServerToContextConnection {
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
        WebKit.LogChannel.SharedWorker().releaseLog
            .log(
                "\(self.releaseLogPrefix, privacy: .public)postErrorToWorkerObject: sharedWorkerIdentifier=\(sharedWorkerIdentifier.toUInt64())"
            )
        m_server.get()?.postErrorToWorkerObject(sharedWorkerIdentifier, errorMessage, lineNumber, columnNumber, sourceURL, isErrorEvent)
    }

    @cxx
    @implementation
    func sharedWorkerTerminated(_ sharedWorkerIdentifier: WebCore.SharedWorkerIdentifier) {
        WebKit.LogChannel.SharedWorker().releaseLog
            .log(
                "\(self.releaseLogPrefix, privacy: .public)sharedWorkerTerminated: sharedWorkerIdentifier=\(sharedWorkerIdentifier.toUInt64())"
            )
        m_server.get()?.sharedWorkerTerminated(sharedWorkerIdentifier)
    }

    private var releaseLogPrefix: Swift.String {
        let webProcessIdentifier = Optional(fromCxx: webProcessIdentifier())?.toUInt64() ?? 0
        return "\(logAddress().description) - [webProcessIdentifier=\(webProcessIdentifier)] WebSharedWorkerServerToContextConnection::"
    }
}
