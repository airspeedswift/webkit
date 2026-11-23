/**
 * Copyright (C) 2025-2026 Apple Inc. All rights reserved.
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

// This file is a no-op unless we have a feature where C++ calls into Swift
// or uses Swift data types.

#ifdef __swift__
#warning "You're including WebKit-Swift.h from a C++ header file - don't do that. This may cause circular Swift<->C++ dependencies and build problems."
#endif

#if defined(BUILDING_WITH_CMAKE) && !defined(WK_COMPILING_SWIFT_INTEROP_SUBTARGET)
#error "This source includes WebKit-Swift.h; add it to WebKit_SWIFT_INTEROP_SOURCES in Source/WebKit/CMakeLists.txt."
#endif

// Anything needing to use Swift types or functions should include
// this rather than directly including WebKit-Swift-Generated.h. Its purposes:
// - include any pre-requisite headers
// - set up warnings suitably
// - select between the headers generated using built-in or custom build
//   actions on different SDK versions

#include <wtf/Platform.h>

// If Swift function parameters or return types depend on C++ types, the
// relevant headers must be included here. rdar://165068038
#include "APIArray.h"
#include "IPCSwiftStreamTesterMessages.h"
#include "IPCSwiftWorkQueueTesterMessages.h"
#include "IPCTesterReceiverMessages.h"
#include "NetworkCache.h"
#include "NetworkCacheDump.h"
#include "NetworkCacheFileSystem.h"
#include "NetworkCachePersistence.h"
#include "NetworkCacheStorageIO.h"
#include "NetworkCacheTestSupportInternal.h"
#include "NetworkCacheWTFInterop.h"
#include "StreamServerConnection.h"
#include "SwiftCoding.h"
#include "WebBackForwardListItem.h"
#include "WebBackForwardListMessages.h"
#include "WebBackForwardListSwiftUtilities.h"
#include "WebPageProxy.h"

#if ENABLE(GPU_PROCESS)
#include "GPUConnectionToWebProcess.h"
#include "GPUConnectionToWebProcessMessages.h"
#include "GPUProcess.h"
#include "GPUProcessMessages.h"
#include "RemoteSnapshotSink.h"
#include "SwiftReceiverRegistration.h"
#endif

#if ENABLE(GPU_PROCESS) && ENABLE(VIDEO)
#include "RemoteVideoFrameObjectHeap.h"
#include "RemoteVideoFrameObjectHeapMessages.h"
#endif

#if USE(LIBWEBRTC) && PLATFORM(COCOA) && ENABLE(GPU_PROCESS)
#include "LibWebRTCCodecsProxy.h"
#include "LibWebRTCCodecsProxyMessages.h"
#endif

#if ENABLE(GPU_PROCESS) && PLATFORM(COCOA) && ENABLE(VIDEO)
#include "SharedVideoFrameImplBridge.h"
#endif

#if ENABLE(GPU_PROCESS_CDM_SWIFT)
#include "RemoteCDMFactoryProxyMessages.h"
#include "RemoteCDMInstanceProxyMessages.h"
#include "RemoteCDMInstanceSessionProxyMessages.h"
#include "RemoteCDMProxyMessages.h"
#include "RemoteCDMSwiftSupport.h"
#endif

#if ENABLE(GPU_PROCESS) && ENABLE(WEB_AUDIO) && PLATFORM(COCOA)
#include "RemoteAudioDestinationManagerMessages.h"
#endif

#if ENABLE(GPU_PROCESS) && USE(AUDIO_SESSION)
#include "RemoteAudioSessionProxy.h"
#include "RemoteAudioSessionProxyManager.h"
#include "RemoteAudioSessionProxyMessages.h"
#endif

#if ENABLE(GPU_PROCESS) && ENABLE(VIDEO) && PLATFORM(COCOA)
#include "RemoteAudioVideoRendererProxyManager.h"
#include "RemoteAudioVideoRendererProxyManagerMessages.h"
#endif

#if ENABLE(GPU_PROCESS) && ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
#include "RemoteAudioMediaStreamTrackRendererInternalUnitManagerMessages.h"
#endif

#if ENABLE(GPU_PROCESS) && HAVE(SHAPE_DETECTION_API_IMPLEMENTATION)
#include "RemoteBarcodeDetectorMessages.h"
#include "RemoteFaceDetectorMessages.h"
#include "RemoteRenderingBackend.h"
#include "RemoteRenderingBackendMessages.h"
#include "RemoteTextDetectorMessages.h"
#endif
#if ENABLE(GPU_PROCESS) && ENABLE(WEBGL)
#include "RemoteGraphicsContextGLMessages.h"
#include "RemoteGraphicsContextGLResources.h"
#endif

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "RemoteCGRendererGlyphs.h"
#include "RemoteCGRendererLineDash.h"
#include "RemoteCGRendererLineSegments.h"
#include "RemoteCGRendererLineStrokes.h"
#include "RemoteCGRendererPathSegment.h"
#include "RemoteCGRendererResources.h"
#include "RemoteCGRendererShadow.h"
#include "RemoteCGRendererStyle.h"
#include "RemoteCGRendererMessages.h"
#include "RemoteImageBufferGraphicsContext.h"
#include "RemoteImageBufferMessages.h"
#include "RemoteRenderingBackend.h"
#include <WebCore/CGRendererSwiftBridge.h>
#endif

#if ENABLE(GPU_PROCESS_WEBGPU_SWIFT)
#include "RemoteAdapterMessages.h"
#include "RemoteBindGroupLayoutMessages.h"
#include "RemoteBindGroupMessages.h"
#include "RemoteBufferMessages.h"
#include "RemoteCommandBufferMessages.h"
#include "RemoteCommandEncoderMessages.h"
#include "RemoteCompositorIntegrationMessages.h"
#include "RemoteComputePassEncoderMessages.h"
#include "RemoteComputePipelineMessages.h"
#include "RemoteDeviceMessages.h"
#include "RemoteExternalTextureMessages.h"
#include "RemoteGPU.h"
#include "RemoteGPUMessages.h"
#include "RemotePipelineLayoutMessages.h"
#include "RemotePresentationContextMessages.h"
#include "RemoteQuerySetMessages.h"
#include "RemoteQueueMessages.h"
#include "RemoteRenderBundleEncoderMessages.h"
#include "RemoteRenderBundleMessages.h"
#include "RemoteRenderPassEncoderMessages.h"
#include "RemoteRenderPipelineMessages.h"
#include "RemoteSamplerMessages.h"
#include "RemoteShaderModuleMessages.h"
#include "RemoteTextureMessages.h"
#include "RemoteTextureViewMessages.h"
#include "RemoteXRBindingMessages.h"
#include "RemoteXRProjectionLayerMessages.h"
#include "RemoteXRSubImageMessages.h"
#include "RemoteXRViewMessages.h"
#endif

#if ENABLE(PHONE_NUMBER_POSSESSION)
#include "PhoneNumberPossessionTypes.h"
#endif

#if PLATFORM(COCOA)
#include "EventDispatcher.h"
#include "RemoteScrollingCoordinator.h"
#include "RemoteScrollingCoordinatorProxy.h"
#include "RemoteScrollingTree.h"
#include <WebCore/ScrollingTreeNode.h>
#if PLATFORM(MAC)
#include "RemoteLayerTreeEventDispatcher.h"
#include "RemoteScrollingCoordinatorProxyMac.h"
#include "RemoteScrollingTreeMac.h"
#endif
#endif

#ifdef __OBJC__
#include "WKHistoryDelegatePrivate.h"
#include "WKSeparatedImageView.h"
#include "WKUIDelegatePrivate.h"
#if PLATFORM(MAC) && HAVE(NSREFRESHCONTROLLER)
// Spells out the NSRefreshControlHosting protocol referenced by WKWebView extensions
// in WebKit-Swift-Generated.h. rdar://179255418
#include "AppKitSPI.h"
#endif
#endif

#if USE(APPLE_INTERNAL_SDK)
#include <WebKitAdditions/WebKit-Swift-Additions.h>
#endif

// rdar://165192318
IGNORE_CLANG_WARNINGS_BEGIN("arc-bridge-casts-disallowed-in-nonarc")
// rdar://171345626
IGNORE_CLANG_WARNINGS_BEGIN("objc-property-no-attribute")
// rdar://175148090
IGNORE_CLANG_WARNINGS_BEGIN("#warnings")
#include "WebKit-Swift-Generated.h"
IGNORE_CLANG_WARNINGS_END
IGNORE_CLANG_WARNINGS_END
IGNORE_CLANG_WARNINGS_END

