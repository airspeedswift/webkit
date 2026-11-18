/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
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

// Anything in WebCore needing to use Swift types or functions should include
// this rather than WebCoreSwift-Generated.h directly.

#ifdef __swift__
#warning "You're including WebCore-Swift.h from a C++ header file - don't do that. This may cause circular Swift<->C++ dependencies and build problems."
#endif

// WebCoreSwift-Generated.h is emitted by WebCore's Swift compilation, so its
// includers must build in the sub-target ordered after it.
#if defined(BUILDING_WITH_CMAKE) && !defined(WEBCORE_COMPILING_SWIFT_INTEROP_SUBTARGET)
#error "This source includes WebCore-Swift.h; add it to WebCore_SWIFT_INTEROP_SOURCES in Source/WebCore/CMakeLists.txt."
#endif

// If Swift function parameters or return types depend on C++ types, the
// relevant headers must be included here.
#include "HTMLMicrosyntaxesSwiftTypes.h"

#include "TransformationMatrix.h"
#include "ContainerNode.h"
#include "Document.h"
#include "Element.h"
#include "HTMLFastPathParserTypes.h"

#include "HTMLEntityParser.h"
#include "HTMLTokenizer.h"
#include "SegmentedString.h"

#include "CustomElementRegistry.h"
#include "DocumentFragment.h"
#include "HTMLDocument.h"
#include "HTMLDocumentParser.h"
#include "HTMLParserOptions.h"
#include "HTMLTreeBuilderSwiftSupport.h"
#include "Document.h"
#include "HTMLPreloadScanner.h"

// The GIF, BMP and ICO decoders are Swift where they are built: the CMake ports that do not decode through ImageIO.
#if !PLATFORM(COCOA)
#include "ImageDecoderSwiftTypes.h"
#endif
#include "CSSTokenizerSwiftTypes.h"

#include "CSSParserFastPathsSwiftTypes.h"

#include "CSSCalcSwiftTypes.h"

#include "CSSNumericValueSwiftTypes.h"

#include "CSSPropertyConsumerSwiftTypes.h"

#include "ContentSecurityPolicySwift.h"

#include "CacheValidation.h"
#include "HTTPHeaderParsersTypes.h"
#include "LinkHeader.h"
#include "ParsedContentRange.h"
#include "SecurityPoliciesSwiftTypes.h"
#include "ServerTiming.h"

#include "ScrollAnimatorScrollPhysicsClient.h"
#include "ScrollPhysicsTypes.h"
#if PLATFORM(MAC) // In a directory only the Apple ports have.
#include "ScrollbarsControllerMacTypes.h"
#endif
#if PLATFORM(MAC) // In a directory only the Apple ports have.
#include "ScrollerPairMacTypes.h"
#endif
// ScrollingTree.swift's and ScrollingTreeLatchingController.swift's types, which ScrollingTreeScrollPhysicsClient.h
// includes only with the scrolling thread.
#include "ScrollingCoordinatorTypes.h"
#include "ScrollingStateNode.h"
#include "ScrollingTree.h"
#include "ScrollingTreeFrameHostingNode.h"
#include "ScrollingTreeScrollPhysicsClient.h"
#include "AffineTransform.h"
#if PLATFORM(COCOA) // In a directory only the Apple ports have.
#include "AudioCaptureControllerHandle.h"
#endif
#if PLATFORM(COCOA) // In a directory only the Apple ports have.
#include "AudioVideoRendererHost.h"
#endif
#if PLATFORM(COCOA) // In a directory only the Apple ports have.
#include "CARingBufferSwiftBridge.h"
#endif
#if PLATFORM(COCOA) // In a directory only the Apple ports have.
#include "CDMInstanceFairPlayStreamingHost.h"
#endif
#include "CDMPrivate.h"
#if PLATFORM(COCOA) // In a directory only the Apple ports have.
#include "CGRendererSwiftBridge.h"
#endif
#include "CaptureDevice.h"
#include "CSSFilterRendererView.h"
#include "FEBlendParameters.h"
#include "FEColorMatrixParameters.h"
#include "FEComponentTransferParameters.h"
#include "FECompositeParameters.h"
#include "FEConvolveMatrixParameters.h"
#include "FEDisplacementMapParameters.h"
#include "FEDropShadowParameters.h"
#include "FEFloodParameters.h"
#include "FEGaussianBlurParameters.h"
#include "FEImageParameters.h"
#include "FELightingParameters.h"
#include "FEMorphologyParameters.h"
#include "FEOffsetParameters.h"
#include "FETurbulenceParameters.h"
#if PLATFORM(COCOA) // In a directory only the Apple ports have.
#include "FilterCoreImageSwiftBridge.h"
#endif
#include "FilterEffectView.h"
#include "FilterGraphicsBridge.h"
#include "FilterSwiftBridge.h"
#include "FloatRect.h"
#include "GraphicsTypes.h"
#include "ImageBuffer.h"
#include "IntRect.h"
#include "IntSize.h"
#include "LightSourceParameters.h"
#include "MediaConstraintsSwiftBridge.h"
#if PLATFORM(COCOA) // In a directory only the Apple ports have.
#include "MediaPlayerAVFoundationHost.h"
#endif
#include "PixelBufferConversion.h"
#include "PixelBufferSwiftBridge.h"
#include "SVGFilterRendererView.h"
#include "ShadowBlurSwiftBridge.h"
#if PLATFORM(COCOA) // In a directory only the Apple ports have.
#include "DetectedShapes.h"
#endif
#include "ShareableBitmapSwiftBridge.h"
#if PLATFORM(COCOA) // In a directory only the Apple ports have.
#include "SharedVideoFrameSwiftBridge.h"
#endif
#include "SourceGraphicParameters.h"

#include "AV1CodecConfigurationRecord.h"
#include "AnnexBUtilities.h"
#include "CDMEncryptionScheme.h"
#include "CDMKeyStatus.h"
#include "CDMRequirement.h"
#include "CDMSessionType.h"
#if PLATFORM(COCOA) // In a directory only the Apple ports have.
#include "CMParsingTypes.h"
#endif
#include "EMEParseResults.h"
#include "ISOParseResults.h"
#include "MediaParsersCxxBridging.h"
#include "VPCodecConfigurationRecord.h"
#include "VideoCodecParameterTypes.h"

#include "StyleTransformFunction.h"
#include "StyleTransformList.h"
#include "StyleTransformSwiftTypes.h"
#include "ScrollingTreeScrollingNode.h"

#include "platform/audio/AudioDSPBoundaryTypes.h"

#include "BiquadFilterType.h"
#include "WebCoreSwift-Generated.h"
