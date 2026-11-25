/*
 * Copyright (C) 2025 Apple Inc. All rights reserved.
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

// Add project-level C++ header files here to be able to access them from within Swift sources.

#if defined(_MSVC_STL_VERSION) || defined(_WIN32)
// With the MSVC STL, a header below compares iterators that involve coroutine_handle<> before any header includes
// <coroutine>, and the importer then finds its specialization unreachable ("must be imported from module
// 'std.coroutine' before it is required"). Import it first.
#include <coroutine>
#endif

#include "IPCSwiftStreamTesterCount.h"
#include "IPCSwiftStreamTesterMessages.h"
#include "IPCSwiftWorkQueueTesterMessages.h"
#include "IPCSwiftWorkQueueTesterSupport.h"
#include "IPCTesterReceiverMessages.h"
#include "NetworkBroadcastChannelRegistry.h"
#include "SecurityFlags.h"
#include "WebSharedWorker.h"
#include "WebSharedWorkerServer.h"
#include "WebSharedWorkerServerConnection.h"
#include "WebSharedWorkerServerToContextConnection.h"

#if ENABLE(GPU_PROCESS) && ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
#include "RemoteSampleBufferDisplayLayerManagerMessages.h"
#include "RemoteSampleBufferDisplayLayerMessages.h"
#include "SampleBufferDisplayLayerHost.h"
#endif

#if ENABLE(GPU_PROCESS_CORE_SWIFT)
#include "RemoteSnapshotPDFDrawingTask.h"
#include <WebCore/AV1UtilitiesCocoa.h>
#include <WebCore/CommonAtomStrings.h>
#include <WebCore/DeprecatedGlobalSettings.h>
#include <WebCore/IOSurface.h>
#include <WebCore/MemoryRelease.h>
#include <WebCore/VP9UtilitiesCocoa.h>
#include <wtf/Language.h>
#include <wtf/MemoryPressureHandler.h>
#if ENABLE(MEDIA_STREAM)
#include <WebCore/MockRealtimeMediaSourceCenter.h>
#endif
#endif

#if ENABLE(GPU_PROCESS)
#include "GPUConnectionToWebProcess.h"
#include "GPUConnectionToWebProcessMessages.h"
#include "GPUProcess.h"
#include "GPUProcessMessages.h"
#include "RemoteSharedResourceCache.h"
#include "RemoteSnapshotSink.h"
#include "SwiftReceiverRegistration.h"
#endif

#if ENABLE(GPU_PROCESS_CORE_SWIFT)
#include "LogInitialization.h"
#include <WebCore/LogInitialization.h>
#endif

#if ENABLE(GPU_PROCESS) && ENABLE(VIDEO)
#include "RemoteVideoFrameObjectHeap.h"
#include "RemoteVideoFrameObjectHeapMessages.h"
#endif

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT) && ENABLE(VIDEO)
#include "MediaPlayerPrivateRemoteMessages.h"
#include "RemoteMediaPlayerProxy.h"
#if ENABLE(WEB_AUDIO)
#include "RemoteAudioSourceProviderProxy.h"
#endif
#endif

#if USE(LIBWEBRTC) && PLATFORM(COCOA) && ENABLE(GPU_PROCESS)
#include "LibWebRTCCodecsProxyMessages.h"
#endif

#if ENABLE(GPU_PROCESS) && ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
#include "UserMediaCaptureManagerProxy.h"
#include "UserMediaCaptureManagerProxyMessages.h"
#endif

#if ENABLE(GPU_PROCESS_CDM_SWIFT)
#include "RemoteCDMFactoryProxyMessages.h"
#include "RemoteCDMInstanceMessages.h"
#include "RemoteCDMInstanceProxyMessages.h"
#include "RemoteCDMInstanceSessionProxyMessages.h"
#include "RemoteCDMProxyMessages.h"
#endif

#if ENABLE(GPU_PROCESS) && PLATFORM(COCOA)
#include "RemoteImageDecoderAVFProxyMessages.h"
#include "RemoteLegacyCDMFactoryProxyMessages.h"
#include "RemoteLegacyCDMProxyMessages.h"
#include "RemoteLegacyCDMSessionMessages.h"
#include "RemoteLegacyCDMSessionProxyMessages.h"
#include "RemoteMediaEngineConfigurationFactoryProxyMessages.h"
#include "RemoteMediaSwiftSupport.h"
#endif

#if ENABLE(GPU_PROCESS) && ENABLE(WEB_AUDIO) && PLATFORM(COCOA)
#include "RemoteAudioDestinationManagerMessages.h"
#endif

#if ENABLE(GPU_PROCESS_MEDIA_SWIFT)
#include <WebCore/AudioHardwareListener.h>
#endif

#if ENABLE(GPU_PROCESS) && ENABLE(ROUTING_ARBITRATION) && HAVE(AVAUDIO_ROUTING_ARBITER)
#include "LocalAudioSessionRoutingArbitrator.h"
#endif

#if ENABLE(GPU_PROCESS) && USE(AUDIO_SESSION)
#include <WebCore/AudioSession.h>
#if PLATFORM(IOS_FAMILY)
#include "RemoteAudioSessionIOS.h"
#endif
#include "RemoteAudioSessionProxyMessages.h"
#endif

#if ENABLE(GPU_PROCESS) && ENABLE(VIDEO) && PLATFORM(COCOA)
#include "RemoteAudioVideoRendererProxyManager.h"
#include "RemoteAudioVideoRendererProxyManagerMessages.h"
#endif

#if ENABLE(GPU_PROCESS) && ENABLE(VIDEO) && ENABLE(GPU_PROCESS_MEDIA_SWIFT)
#include "AudioTrackPrivateRemoteConfiguration.h"
#include "MediaPlayerPrivateRemoteMessages.h"
#include "RemoteMediaPlayerManagerProxy.h"
#include "RemoteMediaPlayerManagerProxyMessages.h"
#include "RemoteMediaPlayerProxyMessages.h"
#include "RemoteMediaPlayerProxy.h"
#include "RemoteMediaResource.h"
#include "RemoteMediaResourceLoader.h"
#include "RemoteMediaResourceLoaderMessages.h"
#include "ScopedRenderingResourcesRequest.h"
#include "TextTrackPrivateRemoteConfiguration.h"
#include "VideoTrackPrivateRemoteConfiguration.h"
#include <WebCore/AudioTrackPrivate.h>
#include <WebCore/InbandTextTrackPrivate.h>
#include <WebCore/VideoTrackPrivate.h>
#endif

#if ENABLE(GPU_PROCESS) && ENABLE(MEDIA_STREAM) && PLATFORM(COCOA)
#include "RemoteAudioMediaStreamTrackRendererInternalUnitManagerMessages.h"
#endif

#if ENABLE(GPU_PROCESS)
// GPUConnectionToWebProcess.swift holds the connection's rendering backends on every port with the GPU process.
#include "RemoteRenderingBackend.h"
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
#include "RemoteGraphicsContextGLShims.h"
#endif

#if ENABLE(GPU_PROCESS_CG_RENDERER_SWIFT)
#include "RemoteSnapshotPrintData.h"
#include "SharedFont.h"
#include <WebCore/Filter.h>
#include <WebCore/FloatSegment.h>
#include <WebCore/FontCustomPlatformData.h>
#include <WebCore/MeshGradient.h>
#include <WebCore/PathSegmentData.h>
#include "RemoteCGRendererMessages.h"
#include "RemoteImageBufferGraphicsContext.h"
#include "RemoteImageBufferMessages.h"
#include "RemoteImageBufferSet.h"
#include "RemoteImageBufferSetMessages.h"
#include "RemoteRenderingBackend.h"
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

// SuspendableWorkQueue is a foreign reference type, so Swift needs its definition before ResourceLoadStatisticsStore.h names it.
#include <wtf/SuspendableWorkQueue.h>
#include "ResourceLoadStatisticsStore.h"
