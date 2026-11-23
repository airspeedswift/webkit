// Copyright (C) 2015-2025 Apple Inc. All rights reserved.
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

import Synchronization
import WebKit_Internal.NetworkCacheCxx
import wtf

/// What a speculative load tells the diagnostic logging about a request it warmed up, or did not.
enum NetworkCacheSpeculativeLoadDiagnostic: CaseIterable {
    case successfulWarmupWithRevalidation
    case successfulWarmupWithoutRevalidation
    case wastedWarmupWithRevalidation
    case wastedWarmupWithoutRevalidation
    case entryRightlyNotWarmedUp
    case entryWronglyNotWarmedUp
    case unknownEntryRequest

    var message: WTF.String {
        switch self {
        case .successfulWarmupWithRevalidation: WebCore.DiagnosticLoggingKeys.successfulSpeculativeWarmupWithRevalidationKey()
        case .successfulWarmupWithoutRevalidation: WebCore.DiagnosticLoggingKeys.successfulSpeculativeWarmupWithoutRevalidationKey()
        case .wastedWarmupWithRevalidation: WebCore.DiagnosticLoggingKeys.wastedSpeculativeWarmupWithRevalidationKey()
        case .wastedWarmupWithoutRevalidation: WebCore.DiagnosticLoggingKeys.wastedSpeculativeWarmupWithoutRevalidationKey()
        case .entryRightlyNotWarmedUp: WebCore.DiagnosticLoggingKeys.entryRightlyNotWarmedUpKey()
        case .entryWronglyNotWarmedUp: WebCore.DiagnosticLoggingKeys.entryWronglyNotWarmedUpKey()
        case .unknownEntryRequest: WebCore.DiagnosticLoggingKeys.unknownEntryRequestKey()
        }
    }
}

/// How many times each diagnostic was logged while the speculative preloading channel was on, for its statistics.
private let speculativeLoadingDiagnosticMessageCounts = Mutex<[NetworkCacheSpeculativeLoadDiagnostic: UInt32]>([:])

/// Logs the statistics of the speculative preloading channel.
func printSpeculativeLoadingDiagnosticMessageCounts() {
    let channel = WebKit.LogChannel.NetworkCacheSpeculativePreloading()
    guard channel.state != .Off else {
        return
    }
    channel.debugLog.log("-- Speculative loading statistics --")
    let counts = speculativeLoadingDiagnosticMessageCounts.withLock { $0 }
    for diagnostic in NetworkCacheSpeculativeLoadDiagnostic.allCases {
        if let count = counts[diagnostic] {
            channel.debugLog.log("\(diagnostic.message.description, privacy: .public): \(count)")
        }
    }
}

func logSpeculativeLoadingDiagnosticMessage(
    _ frameID: borrowing WebKit.NetworkCache.GlobalFrameID,
    _ diagnostic: NetworkCacheSpeculativeLoadDiagnostic
) {
    let message = diagnostic.message
    if WebKit.NetworkCache.dryRunSpeculativeLoad(.Diagnostic, message) {
        return
    }
    if WebKit.LogChannel.NetworkCacheSpeculativePreloading().state != .Off {
        speculativeLoadingDiagnosticMessageCounts.withLock { counts in
            counts[diagnostic, default: 0] &+= 1
        }
    }
    WebKit.NetworkProcess.singleton()
        .logDiagnosticMessage(frameID.webPageProxyID, WebCore.DiagnosticLoggingKeys.networkCacheKey(), message, .Yes)
}
