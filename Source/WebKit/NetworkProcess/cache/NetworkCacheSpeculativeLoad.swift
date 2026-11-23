// Copyright (C) 2015 Apple Inc. All rights reserved.
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

import WebKit_Internal.NetworkCacheCxx
import wtf

/// What a cache load passes on to the network load it starts.
struct NetworkCacheLoadOptions {
    let isNavigatingToAppBoundDomain: WebKit.NetworkCache.OptionalAppBoundDomain
    let allowPrivacyProxy: Bool
    let advancedPrivacyProtections: WebKit.NetworkCache.NetworkCacheAdvancedPrivacyProtections
}

/// A speculative load: loads or revalidates one subresource ahead of its request and hands the resulting cache entry
/// to its completion.
///
/// Main thread only. Its network load client is the C++ NetworkCache::SpeculativeLoad.
final class NetworkCacheSpeculativeLoad {
    private static let maximumCacheBufferSize = 10 * 1024 * 1024

    private let cache: NetworkDiskCache
    private let client: WebKit.NetworkCache.SpeculativeLoad
    private var networkLoad: WebKit.NetworkLoad?
    private var completionHandler: ((NetworkCacheEntry?) -> Void)?
    let originalRequest: WebCore.ResourceRequest
    private var response = WebCore.ResourceResponse()
    private var bufferedDataForCache: WebCore.SharedBufferBuilder
    private var cacheEntry: NetworkCacheEntry?
    private var didCompleteLoad = false
    private var privateRelayed: WebKit.PrivateRelayed = .No

    init(
        cache: NetworkDiskCache,
        frameID: WebKit.NetworkCache.GlobalFrameID,
        request: borrowing WebCore.ResourceRequest,
        entryForValidation: NetworkCacheEntry?,
        loadOptions: NetworkCacheLoadOptions,
        completionHandler: @escaping (NetworkCacheEntry?) -> Void
    ) {
        assert(entryForValidation?.needsValidation() ?? true)
        self.cache = cache
        self.client = WebKit.NetworkCache.SpeculativeLoad.create().get()
        self.completionHandler = completionHandler
        self.originalRequest = copy request
        // Empty, not null: a null builder is one that stopped buffering.
        var bufferedData = WebCore.SharedBufferBuilder()
        bufferedData.empty()
        self.bufferedDataForCache = bufferedData
        self.cacheEntry = entryForValidation

        setEventHandler()
        networkLoad =
            client.createNetworkLoad(
                frameID,
                originalRequest,
                loadOptions.isNavigatingToAppBoundDomain,
                loadOptions.allowPrivacyProxy,
                loadOptions.advancedPrivacyProtections,
                cache.sessionID
            )
            .get()
        // Stored before it starts: the start can deliver an event, which may complete and clear it.
        if let networkLoad {
            networkLoad.startWithScheduling()
        } else {
            let handler = self.completionHandler.take()
            WebKit.NetworkCache.dispatchOnMain(
                consuming: .init {
                    handler?(nil)
                }
            )
        }
    }

    deinit {
        // The client's handler for its next event goes with this load.
        client.setEventHandler(consuming: .init {})
    }

    func cancel() {
        guard let networkLoad = networkLoad.take() else {
            return
        }
        networkLoad.cancel()
        completionHandler.take()?(nil)
    }

    private func setEventHandler() {
        client.setEventHandler(
            consuming: .init { [weak self] in
                self?.handleEvent()
            }
        )
    }

    private func handleEvent() {
        let event = client.takeEvent()
        switch event.type {
        case .Redirect:
            willSendRedirectedRequest(event.request, event.redirectRequest, event.response)
        case .Response:
            didReceiveResponse(event.response, event.privateRelayed)
        case .Buffer:
            // NetworkCache::SpeculativeLoad sets a buffer on every Buffer event.
            guard let buffer = event.buffer.get() else {
                fatalError("A Buffer event without a buffer")
            }
            didReceiveBuffer(buffer)
        case .Finish:
            didFinishLoading()
        case .Fail:
            didFailLoading()
        default:
            break
        }
        setEventHandler()
    }

    private func willSendRedirectedRequest(
        _ request: WebCore.ResourceRequest,
        _ redirectRequest: WebCore.ResourceRequest,
        _ redirectResponse: WebCore.ResourceResponse
    ) {
        WebKit.LogChannel.NetworkCacheSpeculativePreloading().debugLog
            .log(
                "Speculative redirect \(request.urlCopy().stringCopy().description, privacy: .public) -> \(redirectRequest.urlCopy().stringCopy().description, privacy: .public)"
            )

        let maxAgeCap = WebKit.NetworkCache.SpeculativeLoad.maxAgeCap(cache.sessionID, request)
        cacheEntry = cache.storeRedirect(request, redirectResponse, redirectRequest, maxAgeCap)
        // Create a synthetic cache entry if we can't store.
        if cacheEntry == nil {
            cacheEntry = cache.makeRedirectEntry(request, redirectResponse, redirectRequest)
        }
        // Don't follow the redirect. The redirect target will be registered for speculative load when it is loaded.
        didComplete()
    }

    private func didReceiveResponse(_ receivedResponse: consuming WebCore.ResourceResponse, _ privateRelayed: WebKit.PrivateRelayed) {
        response = receivedResponse
        self.privateRelayed = privateRelayed

        if response.isMultipart() {
            bufferedDataForCache.reset()
        }

        if response.httpStatusCode() == WebCore.httpStatus304NotModified, let entry = cacheEntry {
            cacheEntry = cache.update(originalRequest, entry, response, privateRelayed)
        } else {
            cacheEntry = nil
        }
    }

    private func didReceiveBuffer(_ buffer: WebCore.FragmentedSharedBuffer) {
        assert(cacheEntry == nil)

        if !bufferedDataForCache.isNull() {
            // Prevent memory growth in case of streaming data.
            if bufferedDataForCache.size() + buffer.size() <= Self.maximumCacheBufferSize {
                bufferedDataForCache.append(buffer)
            } else {
                bufferedDataForCache.reset()
            }
        }
    }

    private func didFinishLoading() {
        if didCompleteLoad {
            return
        }
        if cacheEntry == nil && !bufferedDataForCache.isNull() {
            cacheEntry = cache.store(
                originalRequest,
                response,
                privateRelayed,
                WebKit.NetworkCache.FragmentedBufferPtr(bufferedDataForCache.buffer()),
                WebKit.NetworkCache.emptyMappedBodyHandler()
            )
            // Create a synthetic cache entry if we can't store.
            if cacheEntry == nil && WebCore.isStatusCodeCacheableByDefault(response.httpStatusCode()) {
                cacheEntry = cache.makeEntry(
                    originalRequest,
                    response,
                    privateRelayed,
                    WebKit.NetworkCache.FragmentedBufferPtr(bufferedDataForCache.takeBuffer().get())
                )
            }
        }
        didComplete()
    }

    private func didFailLoading() {
        if didCompleteLoad {
            return
        }
        cacheEntry = nil
        didComplete()
    }

    private func didComplete() {
        assert(WTF.RunLoop.isMain())
        if didCompleteLoad {
            return
        }
        didCompleteLoad = true
        networkLoad = nil

        // Make sure speculatively revalidated resources do not get validated by the NetworkResourceLoader again.
        cacheEntry?.setNeedsValidation(false)

        let entry = cacheEntry.take()
        completionHandler.take()?(entry)
    }
}
