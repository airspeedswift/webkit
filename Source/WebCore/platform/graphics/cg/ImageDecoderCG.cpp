/*
 * Copyright (C) 2016-2026 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "ImageDecoderCG.h"

#if USE(CG)

#include "ColorSpaceCG.h"
#include "FourCC.h"
#include "ImageFrame.h"
#include "Logging.h"
#include "MIMETypeRegistry.h"
#include "ProcessCapabilities.h"
#include "SharedBuffer.h"
#include "UTIRegistry.h"
#include <pal/spi/cg/ImageIOSPI.h>
#include <ImageIO/ImageIO.h>
#include <pal/spi/cg/CoreGraphicsSPI.h>
#include <wtf/FlipBytes.h>
#include <wtf/TZoneMallocInlines.h>
#include <wtf/cf/TypeCastsCF.h>

#include "WebCore-Swift.h"

#include "CoreVideoSoftLink.h"
#include "MediaAccessibilitySoftLink.h"

#if ENABLE(SPATIAL_IMAGE_DETECTION)
#include "PhotosFormatSoftLink.h"
#endif

WTF_DECLARE_CF_TYPE_TRAIT(CGImageMetadata)

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ImageDecoderCG);

#if ENABLE(SPATIAL_IMAGE_DETECTION)
#if HAVE(IMAGE_RESTRICTED_DECODING) && USE(APPLE_INTERNAL_SDK)
const CFStringRef kCGImageSourceEnableRestrictedDecoding = CFSTR("kCGImageSourceEnableRestrictedDecoding");
#endif

#if HAVE(IMAGEIO_CREATE_UNPREMULTIPLIED_PNG)
const CFStringRef kCGImageSourceCreateUnpremultipliedPNG = CFSTR("kCGImageSourceCreateUnpremultipliedPNG");
#endif
#endif

#if ENABLE(SPATIAL_IMAGE_DETECTION)
static RetainPtr<CFMutableDictionaryRef> createImageSourceOptions()
{
    RetainPtr<CFMutableDictionaryRef> options = adoptCF(CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    CFDictionarySetValue(options.get(), kCGImageSourceShouldCache, kCFBooleanTrue);
    CFDictionarySetValue(options.get(), kCGImageSourceShouldPreferRGB32, kCFBooleanTrue);
    CFDictionarySetValue(options.get(), kCGImageSourceSkipMetadata, kCFBooleanTrue);

    if (ProcessCapabilities::isHardwareAcceleratedDecodingDisabled())
        CFDictionarySetValue(options.get(), kCGImageSourceUseHardwareAcceleration, kCFBooleanFalse);

#if HAVE(IMAGE_RESTRICTED_DECODING) && USE(APPLE_INTERNAL_SDK)
    if (ProcessCapabilities::isHEICDecodingEnabled() || ProcessCapabilities::isAVIFDecodingEnabled())
        CFDictionarySetValue(options.get(), kCGImageSourceEnableRestrictedDecoding, kCFBooleanTrue);
#endif

#if HAVE(IMAGEIO_CREATE_UNPREMULTIPLIED_PNG)
    CFDictionarySetValue(options.get(), kCGImageSourceCreateUnpremultipliedPNG, kCFBooleanTrue);
#endif

    return options;
}
#endif

#if ENABLE(SPATIAL_IMAGE_DETECTION)
static RetainPtr<CFMutableDictionaryRef> imageSourceMetadataOptions()
{
    static NeverDestroyed<RetainPtr<CFMutableDictionaryRef>> options = [] {
        RetainPtr options = createImageSourceOptions();
        CFDictionarySetValue(options.get(), kCGImageSourceSkipMetadata, kCFBooleanFalse);
        return options;
    }();
    return options.get();
}
#endif

// The Swift decoder over the source the constructor created. It gets what createImageSourceOptions()
// and isSupportedImageType() read, as values: the SPI option keys, ProcessCapabilities, HAVE() flags
// and UTIRegistry's two sets.
static std::unique_ptr<AnyCGImageDecoder> createSwiftDecoder(CGImageSourceRef source)
{
    // Capacity 0: unbounded. A non-zero capacity is a hard maximum for CFArrayCreateMutable.
    RetainPtr supportedTypes = adoptCF(CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks));
    for (auto& type : supportedImageTypes())
        CFArrayAppendValue(supportedTypes.get(), type.createCFString().get());
    for (auto& type : additionalSupportedImageTypes())
        CFArrayAppendValue(supportedTypes.get(), type.createCFString().get());

    bool enableRestrictedDecoding = false;
#if HAVE(IMAGE_RESTRICTED_DECODING) && USE(APPLE_INTERNAL_SDK)
    enableRestrictedDecoding = ProcessCapabilities::isHEICDecodingEnabled() || ProcessCapabilities::isAVIFDecodingEnabled();
#endif
    bool createUnpremultipliedPNG = false;
#if HAVE(IMAGEIO_CREATE_UNPREMULTIPLIED_PNG)
    createUnpremultipliedPNG = true;
#endif

    // makeForImageSource takes `source` as `sending`, i.e. at +1, and its generated C++ thunk does not retain it.
    return makeUniqueWithoutFastMallocCheck<AnyCGImageDecoder>(AnyCGImageDecoder::makeForImageSource(retainPtr(source).leakRef(), supportedTypes.get(),
        kCGImageSourceShouldPreferRGB32, kCGImageSourceSkipMetadata, kCGImageSourceUseHardwareAcceleration,
        ProcessCapabilities::isHardwareAcceleratedDecodingDisabled(), enableRestrictedDecoding, createUnpremultipliedPNG));
}

ImageDecoderCG::ImageDecoderCG(FragmentedSharedBuffer& data, AlphaOption, GammaAndColorProfileOption)
{
    RetainPtr<CFStringRef> utiHint;
    if (data.size() >= 32)
        utiHint = CGImageSourceGetTypeWithData(data.makeContiguous()->createCFData().get(), nullptr, nullptr);

    if (utiHint) {
        const void* key = kCGImageSourceTypeIdentifierHint;
        const void* value = utiHint.get();
        RetainPtr options = adoptCF(CFDictionaryCreate(kCFAllocatorDefault, &key, &value, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
        lazyInitialize(m_nativeDecoder, adoptCF(CGImageSourceCreateIncremental(options.get())));
    } else
        lazyInitialize(m_nativeDecoder, adoptCF(CGImageSourceCreateIncremental(nullptr)));
    lazyInitialize(m_swiftDecoder, createSwiftDecoder(m_nativeDecoder.get()));
}

ImageDecoderCG::~ImageDecoderCG() = default;

size_t ImageDecoderCG::bytesDecodedToDetermineProperties() const
{
    // Measured by tracing malloc/calloc calls on Mac OS 10.6.6, x86_64.
    // A non-zero value ensures cached images with no decoded frames still enter
    // the live decoded resources list when the CGImageSource decodes image
    // properties, allowing the cache to prune the partially decoded image.
    // This value is likely to be inaccurate on other platforms, but the overall
    // behavior is unchanged.
    return 13088;
}

String ImageDecoderCG::filenameExtension() const
{
    return WebCore::preferredExtensionForImageType(uti());
}

String ImageDecoderCG::accessibilityDescription() const
{
    if (!MediaAccessibilityLibrary() || !canLoad_MediaAccessibility_MAImageCaptioningCopyCaptionWithSource())
        return { };
    
    RetainPtr description = adoptCF(MAImageCaptioningCopyCaptionWithSource(m_nativeDecoder.get(), nullptr));
    if (!description)
        return { };
    return description.get();
}

// The raw values the Swift mirrors in ImageDecoding.swift assume.
// Every enumerator, so a reordering in the middle is caught too, not only an insertion.
static_assert(static_cast<uint8_t>(EncodedDataStatus::Error) == 0);
static_assert(static_cast<uint8_t>(EncodedDataStatus::Unknown) == 1);
static_assert(static_cast<uint8_t>(EncodedDataStatus::TypeAvailable) == 2);
static_assert(static_cast<uint8_t>(EncodedDataStatus::SizeAvailable) == 3);
static_assert(static_cast<uint8_t>(EncodedDataStatus::Complete) == 4);
static_assert(static_cast<uint8_t>(DecodingStatus::Invalid) == 0);
static_assert(static_cast<uint8_t>(DecodingStatus::Partial) == 1);
static_assert(static_cast<uint8_t>(DecodingStatus::Complete) == 2);
static_assert(static_cast<uint8_t>(DecodingStatus::Decoding) == 3);
static_assert(static_cast<uint8_t>(DecodingMode::Auto) == 0);
static_assert(static_cast<uint8_t>(DecodingMode::Synchronous) == 1);
static_assert(static_cast<uint8_t>(DecodingMode::Asynchronous) == 2);
static_assert(static_cast<uint8_t>(DecodingDestination::Base) == 0);
static_assert(static_cast<uint8_t>(DecodingDestination::BaseAndGainMap) == 1);
static_assert(static_cast<uint8_t>(DecodingDestination::ShouldDecodeToHDR) == 2);
static_assert(static_cast<uint8_t>(ImageOrientation::Orientation::FromImage) == 0);
static_assert(static_cast<uint8_t>(ImageOrientation::Orientation::OriginTopLeft) == 1);
static_assert(static_cast<uint8_t>(ImageOrientation::Orientation::OriginTopRight) == 2);
static_assert(static_cast<uint8_t>(ImageOrientation::Orientation::OriginBottomRight) == 3);
static_assert(static_cast<uint8_t>(ImageOrientation::Orientation::OriginBottomLeft) == 4);
static_assert(static_cast<uint8_t>(ImageOrientation::Orientation::OriginLeftTop) == 5);
static_assert(static_cast<uint8_t>(ImageOrientation::Orientation::OriginRightTop) == 6);
static_assert(static_cast<uint8_t>(ImageOrientation::Orientation::OriginRightBottom) == 7);
static_assert(static_cast<uint8_t>(ImageOrientation::Orientation::OriginLeftBottom) == 8);
static_assert(static_cast<uint8_t>(ImageOrientation::Orientation::None) == 1);

static String fromSwift(const swift::String& string)
{
    std::string utf8 = string;
    return String::fromUTF8(std::span { utf8 });
}

static IntSize fromSwift(const ImageDecoderIntSize& size)
{
    return { size.getWidth(), size.getHeight() };
}

static uint8_t swiftDecodingDestination(const DecodingOptions& options)
{
#if HAVE(SUPPORT_HDR_DISPLAY_APIS)
    return static_cast<uint8_t>(options.decodingDestination());
#else
    // appendImageSourceOption(DecodingDestination) adds nothing without HAVE(SUPPORT_HDR_DISPLAY_APIS).
    UNUSED_PARAM(options);
    return static_cast<uint8_t>(DecodingDestination::Base);
#endif
}

static swift::Optional<ImageDecoderIntSize> swiftSizeForDrawing(const DecodingOptions& options)
{
    if (auto size = options.sizeForDrawing())
        return swift::Optional<ImageDecoderIntSize>::init(ImageDecoderIntSize::init(size->width(), size->height()));
    return swift::Optional<ImageDecoderIntSize>::none();
}

String ImageDecoderCG::uti() const
{
    return fromSwift(m_swiftDecoder->getDecoder().uti());
}

bool ImageDecoderCG::isAllDataReceived() const
{
    return m_swiftDecoder->getDecoder().isAllDataReceived();
}

EncodedDataStatus ImageDecoderCG::encodedDataStatus() const
{
    return static_cast<EncodedDataStatus>(m_swiftDecoder->getDecoder().encodedDataStatus());
}

bool ImageDecoderCG::hasHDRGainMap() const
{
#if HAVE(SUPPORT_HDR_DISPLAY)
    return m_swiftDecoder->getDecoder().hasHDRGainMap();
#else
    return false;
#endif
}

size_t ImageDecoderCG::frameCount() const
{
    return m_swiftDecoder->getDecoder().frameCount();
}

size_t ImageDecoderCG::primaryFrameIndex() const
{
    return m_swiftDecoder->getDecoder().primaryFrameIndex();
}

RepetitionCount ImageDecoderCG::repetitionCount() const
{
    return m_swiftDecoder->getDecoder().repetitionCount();
}

std::optional<IntPoint> ImageDecoderCG::hotSpot() const
{
    auto decoder = m_swiftDecoder->getDecoder();
    auto x = decoder.hotSpotX();
    auto y = decoder.hotSpotY();
    if (!x.isSome() || !y.isSome())
        return std::nullopt;
    return IntPoint(x.getSome(), y.getSome());
}

IntSize ImageDecoderCG::frameSizeAtIndex(size_t index, SubsamplingLevel subsamplingLevel) const
{
    return fromSwift(m_swiftDecoder->getDecoder().frameSizeAtIndex(index, static_cast<swift::Int>(subsamplingLevel)));
}

FloatSize ImageDecoderCG::frameDensityAtIndex(size_t index) const
{
    auto decoder = m_swiftDecoder->getDecoder();
    return { decoder.frameDensityWidthAtIndex(index), decoder.frameDensityHeightAtIndex(index) };
}

bool ImageDecoderCG::frameIsCompleteAtIndex(size_t index) const
{
    ASSERT(frameCount());
    return m_swiftDecoder->getDecoder().frameIsCompleteAtIndex(index);
}

ImageOrientation ImageDecoderCG::frameOrientationAtIndex(size_t index) const
{
    return static_cast<ImageOrientation::Orientation>(m_swiftDecoder->getDecoder().frameOrientationAtIndex(index));
}

std::optional<IntSize> ImageDecoderCG::frameDensityCorrectedSizeAtIndex(size_t index) const
{
    auto size = m_swiftDecoder->getDecoder().frameDensityCorrectedSizeAtIndex(index);
    if (!size.isSome())
        return std::nullopt;
    return fromSwift(size.getSome());
}

Seconds ImageDecoderCG::frameDurationAtIndex(size_t index) const
{
    return Seconds(m_swiftDecoder->getDecoder().frameDurationAtIndex(index));
}

bool ImageDecoderCG::frameHasAlphaAtIndex(size_t index) const
{
    return m_swiftDecoder->getDecoder().frameHasAlphaAtIndex(index);
}

bool ImageDecoderCG::fetchFrameMetaDataAtIndex(size_t index, SubsamplingLevel subsamplingLevel, const DecodingOptions& options, ImageFrame& frame) const
{
    auto fetched = m_swiftDecoder->getDecoder().fetchFrameMetaDataAtIndex(index, static_cast<swift::Int>(subsamplingLevel),
        static_cast<uint8_t>(options.decodingMode()), swiftDecodingDestination(options), swiftSizeForDrawing(options));
    if (!fetched.isSome())
        return false;
    auto metadata = fetched.getSome();

    frame.m_naturalSize = { metadata.getNaturalWidth(), metadata.getNaturalHeight() };
    if (options.hasSizeForDrawing()) {
        ASSERT(frame.hasNativeImage(options.decodingDestination()));
        frame.m_size = frame.nativeImage(options.decodingDestination())->size();
    } else
        frame.m_size = frame.m_naturalSize;

    if (metadata.hasDensity())
        frame.m_density = { metadata.getDensityWidth(), metadata.getDensityHeight() };
    auto densityCorrectedSize = metadata.getDensityCorrectedSize();
    frame.m_densityCorrectedSize = densityCorrectedSize.isSome() ? std::optional { fromSwift(densityCorrectedSize.getSome()) } : std::nullopt;
    frame.m_subsamplingLevel = subsamplingLevel;
    frame.m_hasAlpha = metadata.hasAlpha();
    frame.m_orientation = static_cast<ImageOrientation::Orientation>(metadata.getOrientation());
    frame.m_decodingStatus = static_cast<DecodingStatus>(metadata.getDecodingStatus());
    return true;
}

std::optional<GainMap> ImageDecoderCG::frameGainMapAtIndex(size_t index, const DecodingOptions& decodingOptions)
{
#if HAVE(SUPPORT_HDR_DISPLAY_APIS)
    if (decodingOptions.decodingDestination() != DecodingDestination::BaseAndGainMap)
        return std::nullopt;

    RetainPtr auxiliaryOptions = adoptCF(CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    CFDictionarySetValue(auxiliaryOptions.get(), kCGImageAuxiliaryDataRepresentation, kCGImageAuxiliaryDataRepresentationPixelBuffer);

    RetainPtr auxiliaryInfo = adoptCF(CGImageSourceCopyAuxiliaryDataInfoAtIndexWithOptions(m_nativeDecoder.get(), index, kCGImageAuxiliaryDataTypeISOGainMap, auxiliaryOptions.get()));
    if (!auxiliaryInfo)
        auxiliaryInfo = adoptCF(CGImageSourceCopyAuxiliaryDataInfoAtIndexWithOptions(m_nativeDecoder.get(), index, kCGImageAuxiliaryDataTypeHDRGainMap, auxiliaryOptions.get()));

    if (!auxiliaryInfo)
        return std::nullopt;

    RetainPtr metadata = dynamic_cf_cast<CGImageMetadataRef>(CFDictionaryGetValue(auxiliaryInfo.get(), kCGImageAuxiliaryDataInfoMetadata));
    RetainPtr gainMapPixelBuffer = dynamic_cf_cast<CVPixelBufferRef>(CFDictionaryGetValue(auxiliaryInfo.get(), kCGImageAuxiliaryDataInfoPixelBuffer));
    RetainPtr colorSpace = dynamic_cf_cast<CGColorSpaceRef>(CFDictionaryGetValue(auxiliaryInfo.get(), kCGImageAuxiliaryDataInfoColorSpace));

    if (!metadata || !gainMapPixelBuffer)
        return std::nullopt;

    return GainMap {
        WTF::move(metadata),
        WTF::move(gainMapPixelBuffer),
        colorSpace ? std::optional<ColorSpace> { ColorSpace(WTF::move(colorSpace)) } : std::nullopt
    };
#else
    UNUSED_PARAM(index);
    UNUSED_PARAM(decodingOptions);
    return std::nullopt;
#endif
}

PlatformImagePtr ImageDecoderCG::createFrameImageAtIndex(size_t index, SubsamplingLevel subsamplingLevel, const DecodingOptions& decodingOptions)
{
    LOG(Images, "ImageDecoder %p createFrameImageAtIndex %lu", this, index);
    ASSERT(decodingOptions.decodingMode() != DecodingMode::Auto);
    // Decoded on m_nativeDecoder (the source Swift was given) with no Swift lock held, so main-thread
    // calls are not blocked by a background decode. Returned at +1.
    RetainPtr image = adoptCF(m_swiftDecoder->createFrameImageAtIndex(m_nativeDecoder.get(), index, static_cast<swift::Int>(subsamplingLevel),
        static_cast<uint8_t>(decodingOptions.decodingMode()), swiftDecodingDestination(decodingOptions), swiftSizeForDrawing(decodingOptions)));
    
#if PLATFORM(IOS_FAMILY)
    // <rdar://problem/7371198> - CoreGraphics changed the default caching behaviour in iOS 4.0 to kCGImageCachingTransient
    // which caused a performance regression for us since the images had to be resampled/recreated every time we called
    // CGContextDrawImage. We now tell CG to cache the drawn images. See also <rdar://problem/14366755> -
    // CoreGraphics needs to un-deprecate kCGImageCachingTemporary since it's still not the default.
ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    CGImageSetCachingFlags(image.get(), kCGImageCachingTemporary);
ALLOW_DEPRECATED_DECLARATIONS_END
#endif // PLATFORM(IOS_FAMILY)

    if (!m_isXBitmapImage)
        return image;
    
    // If it is an xbm image, mask out all the white areas to render them transparent.
    const CGFloat maskingColors[6] = {255, 255,  255, 255, 255, 255};
    RetainPtr<CGImageRef> maskedImage = adoptCF(CGImageCreateWithMaskingColors(image.get(), maskingColors));
    return maskedImage ? maskedImage : image;
}

String ImageDecoderCG::decodeUTI(const SharedBuffer& data) const
{
    return decodeUTI(m_nativeDecoder.get(), data);
}

String ImageDecoderCG::decodeUTI(CGImageSourceRef imageSource, const SharedBuffer& data)
{
    auto uti = String(CGImageSourceGetType(imageSource));
    if (uti != "public.heif"_s && uti != "public.heic"_s && uti != "public.heics"_s)
        return uti;

    if (data.size() < sizeof(unsigned)) {
        ASSERT_NOT_REACHED();
        return uti;
    }

    static const FourCC ftypSignature = std::span { "ftyp" };
    static const FourCC avifBrand = std::span { "avif" };
    static const FourCC avisBrand = std::span { "avis" };

    auto boxUnsigned = [span = data.span()](unsigned index) -> unsigned {
        constexpr bool isLittleEndian = false;
        auto value = reinterpretCastSpanStartTo<const unsigned>(span.subspan(index * sizeof(unsigned)));
        // Numbers in the file are BigEndian.
        return flipBytesIfLittleEndian(value, isLittleEndian);
    };

    auto checkAVIFBrand = [](unsigned brand) -> std::optional<String> {
        if (brand == avifBrand)
            return "public.avif"_s;
        if (brand == avisBrand)
            return "public.avis"_s;
        return std::nullopt;
    };

    // HEIF/AVIF files start with an ftyp box
    //
    //  aligned(8) class GeneralTypeBox(code) extends Box(code) {
    //      unsigned int(32)    major_brand;
    //      unsigned int(32)    minor_version;
    //      unsigned int(32)    compatible_brands[];    // to end of the box
    //  }
    //
    // A box starts with 4 bytes for the size (including the length bytes).
    // An image is considered an AVIF if "avif" or "avis" is present in its
    // major_brand or in one of the compatible_brands.

    // Get the box size. This size includes the length bytes.
    unsigned boxUnsignedIndex = 0;
    unsigned boxByteSize = boxUnsigned(boxUnsignedIndex++);
    if (boxByteSize % 4 || boxByteSize > data.size())
        return uti;

    unsigned boxUnsignedSize = boxByteSize / sizeof(unsigned);
    if (boxUnsignedSize < 4)
        return uti;

    // Check the box type signature.
    if (boxUnsigned(boxUnsignedIndex++) != ftypSignature)
        return uti;

    // Check major_brand.
    if (auto avifUTI = checkAVIFBrand(boxUnsigned(boxUnsignedIndex++)))
        return *avifUTI;

    // Skip minor_version.
    ++boxUnsignedIndex;

    // 100 is reasonable limit for compatible_brands length.
    static constexpr unsigned maxBoxBrandCount = 100;
    auto boxBrandCount = std::min(maxBoxBrandCount, boxUnsignedSize - boxUnsignedIndex);

    // Check compatible_brands.
    while (boxBrandCount) {
        if (auto avifUTI = checkAVIFBrand(boxUnsigned(boxUnsignedIndex++)))
            return *avifUTI;
        --boxBrandCount;
    }

    return uti;
}

void ImageDecoderCG::setData(const FragmentedSharedBuffer& data, bool allDataReceived)
{
    // The CFData goes to CGImageSourceUpdateData unchanged (no copy of the bytes). Swift takes it as
    // `sending`, i.e. at +1, and its generated C++ thunk does not retain it.
    m_swiftDecoder->setData(data.makeContiguous()->createCFData().leakRef(), allDataReceived);
    m_isXBitmapImage = uti() == "public.xbitmap-image"_s;
}

bool ImageDecoderCG::canDecodeType(const String& mimeType)
{
    return MIMETypeRegistry::isSupportedImageMIMEType(mimeType);
}

#if ENABLE(QUICKLOOK_FULLSCREEN)
bool ImageDecoderCG::isMaybePanoramic() const
{
    return m_swiftDecoder->getDecoder().isMaybePanoramic();
}

bool ImageDecoderCG::isPanorama() const
{
    return m_swiftDecoder->getDecoder().isPanorama();
}
#endif

#if ENABLE(SPATIAL_IMAGE_DETECTION)
bool ImageDecoderCG::isSpatial() const
{
    CGImageSourceRef imageSource = m_nativeDecoder.get();

    if (!canLoad_PhotosFormats_PFMetadataImageSourceIsSpatialMedia())
        return false;

    return softLink_PhotosFormats_PFMetadataImageSourceIsSpatialMedia(imageSource);
}

std::optional<unsigned> ImageDecoderCG::spatialEyeFrameIndex(const CFStringRef groupImageIndex) const
{
    if (!isSpatial())
        return std::nullopt;

    CGImageSourceRef source = m_nativeDecoder.get();
    RetainPtr containerProps = adoptCF(CGImageSourceCopyProperties(source, nullptr));
    if (!containerProps)
        return std::nullopt;

    RetainPtr groupsArray = dynamic_cf_cast<CFArrayRef>(CFDictionaryGetValue(containerProps.get(), kCGImagePropertyGroups));
    if (!groupsArray || !CFArrayGetCount(groupsArray.get()))
        return std::nullopt;

    RetainPtr groupInfo = dynamic_cf_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(groupsArray.get(), 0));
    if (!groupInfo)
        return std::nullopt;

    if (RetainPtr num = dynamic_cf_cast<CFNumberRef>(CFDictionaryGetValue(groupInfo.get(), groupImageIndex))) {
        unsigned index;
        CFNumberGetValue(num.get(), kCFNumberIntType, &index);
        return index;
    }

    return std::nullopt;
}

std::optional<unsigned> ImageDecoderCG::spatialLeftEyeFrameIndex() const
{
    return spatialEyeFrameIndex(kCGImagePropertyGroupImageIndexLeft);
}

std::optional<unsigned> ImageDecoderCG::spatialRightEyeFrameIndex() const
{
    return spatialEyeFrameIndex(kCGImagePropertyGroupImageIndexRight);
}

static std::optional<SpatialImageEyeProperties> spatialImageEyePropertiesFromDictionary(CFDictionaryRef props, CFDictionaryRef groupInfo)
{
    if (!props || !groupInfo)
        return std::nullopt;

    SpatialImageEyeProperties result;

    if (RetainPtr groupIndex = dynamic_cf_cast<CFNumberRef>(CFDictionaryGetValue(groupInfo, kCGImagePropertyGroupIndex))) {
        unsigned index = 0;
        CFNumberGetValue(groupIndex.get(), kCFNumberIntType, &index);
        result.groupMetadata.groupIndex = index;
    }

    if (RetainPtr disparity = dynamic_cf_cast<CFNumberRef>(CFDictionaryGetValue(groupInfo, kCGImagePropertyGroupImageDisparityAdjustment))) {
        float value = 0.0f;
        CFNumberGetValue(disparity.get(), kCFNumberFloatType, &value);
        result.groupMetadata.disparityAdjustment = value;
    }

    if (RetainPtr heifDict = dynamic_cf_cast<CFDictionaryRef>(CFDictionaryGetValue(props, kCGImagePropertyHEIFDictionary))) {
        // Getting cameraMetadata.extrinsics.position.
        [&]() {
            RetainPtr extrinsicsDict = dynamic_cf_cast<CFDictionaryRef>(CFDictionaryGetValue(heifDict.get(), kIIOMetadata_CameraExtrinsicsKey));
            if (!extrinsicsDict)
                return;
            RetainPtr positionArray = dynamic_cf_cast<CFArrayRef>(CFDictionaryGetValue(extrinsicsDict.get(), kIIOCameraExtrinsics_Position));
            if (!positionArray)
                return;
            if (CFArrayGetCount(positionArray.get()) != 3)
                return;
            for (CFIndex i = 0; i < 3; ++i) {
                if (RetainPtr num = dynamic_cf_cast<CFNumberRef>(CFArrayGetValueAtIndex(positionArray.get(), i))) {
                    float value = 0.0f;
                    CFNumberGetValue(num.get(), kCFNumberFloatType, &value);
                    result.cameraMetadata.extrinsics.position[i] = value;
                }
            }
        }();

        // Getting cameraMetadata.extrinsics.rotation.
        [&]() {
            RetainPtr extrinsicsDict = dynamic_cf_cast<CFDictionaryRef>(CFDictionaryGetValue(heifDict.get(), kIIOMetadata_CameraExtrinsicsKey));
            if (!extrinsicsDict)
                return;
            RetainPtr rotationArray = dynamic_cf_cast<CFArrayRef>(CFDictionaryGetValue(extrinsicsDict.get(), kIIOCameraExtrinsics_Rotation));
            if (!rotationArray)
                return;
            if (CFArrayGetCount(rotationArray.get()) != 9)
                return;
            for (CFIndex i = 0; i < 9; ++i) {
                if (RetainPtr num = dynamic_cf_cast<CFNumberRef>(CFArrayGetValueAtIndex(rotationArray.get(), i))) {
                    float value = 0.0f;
                    CFNumberGetValue(num.get(), kCFNumberFloatType, &value);
                    result.cameraMetadata.extrinsics.rotation[i] = value;
                }
            }
        }();

        // Getting cameraMetadata.intrinsics.
        [&]() {
            RetainPtr modelDict = dynamic_cf_cast<CFDictionaryRef>(CFDictionaryGetValue(heifDict.get(), kIIOMetadata_CameraModelKey));
            if (!modelDict)
                return;
            RetainPtr intrinsicsArray = dynamic_cf_cast<CFArrayRef>(CFDictionaryGetValue(modelDict.get(), kIIOCameraModel_Intrinsics));
            if (!intrinsicsArray)
                return;
            if (CFArrayGetCount(intrinsicsArray.get()) != 9)
                return;
            for (CFIndex i = 0; i < 9; ++i) {
                if (RetainPtr num = dynamic_cf_cast<CFNumberRef>(CFArrayGetValueAtIndex(intrinsicsArray.get(), i))) {
                    float value = 0.0f;
                    CFNumberGetValue(num.get(), kCFNumberFloatType, &value);
                    result.cameraMetadata.intrinsics.matrix[i] = value;
                }
            }
        }();
    }

    return result;
}

std::optional<SpatialImageEyeProperties> ImageDecoderCG::spatialEyePropertiesAtIndex(unsigned index) const
{
    if (!isSpatial())
        return std::nullopt;

    CGImageSourceRef source = m_nativeDecoder.get();
    RetainPtr containerProps = adoptCF(CGImageSourceCopyProperties(source, nullptr));
    if (!containerProps)
        return std::nullopt;

    RetainPtr groupsArray = dynamic_cf_cast<CFArrayRef>(CFDictionaryGetValue(containerProps.get(), kCGImagePropertyGroups));
    if (!groupsArray || !CFArrayGetCount(groupsArray.get()))
        return std::nullopt;

    RetainPtr groupInfo = dynamic_cf_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(groupsArray.get(), 0));
    if (!groupInfo)
        return std::nullopt;

    RetainPtr props = adoptCF(CGImageSourceCopyPropertiesAtIndex(source, index, imageSourceMetadataOptions().get()));

    if (!props)
        return std::nullopt;

    return spatialImageEyePropertiesFromDictionary(props.get(), groupInfo.get());
}
#endif

} // namespace WebCore

#endif // USE(CG)
