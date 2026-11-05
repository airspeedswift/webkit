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

#include <WebCore/CSSBorderImage.h>
#include <WebCore/CSSBorderImageOutset.h>
#include <WebCore/CSSBorderImageRepeat.h>
#include <WebCore/CSSBorderImageSlice.h>
#include <WebCore/CSSBorderImageSource.h>
#include <WebCore/CSSBorderImageWidth.h>
#include <WebCore/CSSBorderRadius.h>
#include <WebCore/CSSBoxShadowProperty.h>
#include <WebCore/CSSColor.h>
#include <WebCore/CSSColorInterpolationMethod.h>
#include <WebCore/CSSColorMix.h>
#include <WebCore/CSSColorScheme.h>
#include <WebCore/CSSContrastColor.h>
#include <WebCore/CSSDynamicRangeLimit.h>
#include <WebCore/CSSDynamicRangeLimitMix.h>
#include <WebCore/CSSGradient.h>
#include <WebCore/CSSLightDarkColor.h>
#include <WebCore/CSSPosition.h>
#include <WebCore/CSSPropertyConsumerSwiftTypes.h>
#include <WebCore/CSSPropertyParserConsumer+Image.h>
#include <WebCore/CSSWebkitBoxReflect.h>
#include <array>
#include <optional>
#include <wtf/UniqueRef.h>
#include <wtf/Variant.h>

#include <WebCore/CSSAppleColorFilter.h>
#include <WebCore/CSSCalcSizeFunction.h>
#include <WebCore/CSSFilter.h>
#include <WebCore/CSSGridAutoFlowValue.h>
#include <WebCore/CSSLinearEasingFunction.h>

namespace WebCore {

// Where a CSSPropertyConsumerSwiftConsumer puts the CSS:: value it consumes: Swift gives it to setUnresolvedResult,
// which emplaces it in the caller's std::optional<T> if T is the type that caller asked for, and drops it otherwise.
class CSSPropertyConsumerSwiftUnresolvedResult {
    WTF_MAKE_NONCOPYABLE(CSSPropertyConsumerSwiftUnresolvedResult);
    WTF_FORBID_HEAP_ALLOCATION;
public:
    template<typename T> explicit CSSPropertyConsumerSwiftUnresolvedResult(std::optional<T>& slot)
        : m_slot(&slot)
        , m_type(&typeTag<T>)
    {
    }

    template<typename T> static void set(const CSSPropertyConsumerSwiftValue& value, T&& result)
    {
        auto* unresolvedResult = static_cast<const CSSPropertyConsumerSwiftValueState&>(value).unresolvedResult;
        RELEASE_ASSERT(unresolvedResult);
        using Type = std::remove_cvref_t<T>;
        if (unresolvedResult->m_type == &typeTag<Type>)
            static_cast<std::optional<Type>*>(unresolvedResult->m_slot)->emplace(std::forward<T>(result));
    }

private:
    // One address per type. Not const: a linker may merge identical constants into one address.
    template<typename T> static inline char typeTag { };

    void* const m_slot;
    const void* const m_type;
};

void setUnresolvedResult(const CSSPropertyConsumerSwiftValue&, CSS::Color&&);
void setUnresolvedResult(const CSSPropertyConsumerSwiftValue&, CSS::DynamicRangeLimit&&);
#if ENABLE(DARK_MODE_CSS)
void setUnresolvedResult(const CSSPropertyConsumerSwiftValue&, CSS::ColorScheme&&);
#endif

// Consumes a value with the CSSPropertyConsumerSwiftConsumer `consumer` and its options through cssConsumeProperty,
// and advances range past what it consumed. Returns a CSSValue the consumer makes; one that consumes a CSS:: value
// returns null and gives it to unresolvedResult, which it must be given.
RefPtr<CSSValue> consumePropertyWithSwift(CSSParserTokenRange&, CSS::PropertyParserState&, CSSPropertyConsumerSwiftConsumer, uint8_t options = 0, CSSPropertyConsumerSwiftUnresolvedResult* = nullptr);

// MARK: - Colors

// The descriptors (CSSColorDescriptors.h) of the color functions Swift consumes.
enum class CSSColorSwiftDescriptor : uint8_t {
    RGBModernAbsolute,
    RGBLegacyNumber,
    RGBLegacyPercentage,
    RGBModernRelative,
    HSLModern,
    HSLLegacy,
    HWB,
    Lab,
    LCH,
    OKLab,
    OKLCH,
    A98RGB,
    DisplayP3,
    DisplayP3Linear,
    ProPhotoRGB,
    Rec2020,
    SRGB,
    SRGBLinear,
    XYZD50,
    XYZD65,
    Alpha,
};

template<typename F> constexpr decltype(auto) callWithColorSwiftDescriptor(uint8_t descriptor, const F& f)
{
    switch (static_cast<CSSColorSwiftDescriptor>(descriptor)) {
    case CSSColorSwiftDescriptor::RGBModernAbsolute: return f.template operator()<RGBFunctionModernAbsolute>();
    case CSSColorSwiftDescriptor::RGBLegacyNumber: return f.template operator()<RGBFunctionLegacy<CSS::Number<>>>();
    case CSSColorSwiftDescriptor::RGBLegacyPercentage: return f.template operator()<RGBFunctionLegacy<CSS::Percentage<>>>();
    case CSSColorSwiftDescriptor::RGBModernRelative: return f.template operator()<RGBFunctionModernRelative>();
    case CSSColorSwiftDescriptor::HSLModern: return f.template operator()<HSLFunctionModern>();
    case CSSColorSwiftDescriptor::HSLLegacy: return f.template operator()<HSLFunctionLegacy>();
    case CSSColorSwiftDescriptor::HWB: return f.template operator()<HWBFunction>();
    case CSSColorSwiftDescriptor::Lab: return f.template operator()<LabFunction>();
    case CSSColorSwiftDescriptor::LCH: return f.template operator()<LCHFunction>();
    case CSSColorSwiftDescriptor::OKLab: return f.template operator()<OKLabFunction>();
    case CSSColorSwiftDescriptor::OKLCH: return f.template operator()<OKLCHFunction>();
    case CSSColorSwiftDescriptor::A98RGB: return f.template operator()<ColorRGBFunction<ExtendedA98RGB<float>>>();
    case CSSColorSwiftDescriptor::DisplayP3: return f.template operator()<ColorRGBFunction<ExtendedDisplayP3<float>>>();
    case CSSColorSwiftDescriptor::DisplayP3Linear: return f.template operator()<ColorRGBFunction<ExtendedLinearDisplayP3<float>>>();
    case CSSColorSwiftDescriptor::ProPhotoRGB: return f.template operator()<ColorRGBFunction<ExtendedProPhotoRGB<float>>>();
    case CSSColorSwiftDescriptor::Rec2020: return f.template operator()<ColorRGBFunction<ExtendedRec2020<float>>>();
    case CSSColorSwiftDescriptor::SRGB: return f.template operator()<ColorRGBFunction<ExtendedSRGBA<float>>>();
    case CSSColorSwiftDescriptor::SRGBLinear: return f.template operator()<ColorRGBFunction<ExtendedLinearSRGBA<float>>>();
    case CSSColorSwiftDescriptor::XYZD50: return f.template operator()<ColorXYZFunction<XYZA<float, WhitePoint::D50>>>();
    case CSSColorSwiftDescriptor::XYZD65: return f.template operator()<ColorXYZFunction<XYZA<float, WhitePoint::D65>>>();
    case CSSColorSwiftDescriptor::Alpha: return f.template operator()<AlphaDescriptor>();
    }
    RELEASE_ASSERT_NOT_REACHED();
}

// The types a color function's channel takes.
enum : uint8_t {
    CSSColorSwiftChannelNone = 1 << 0,
    CSSColorSwiftChannelNumber = 1 << 1,
    CSSColorSwiftChannelPercentage = 1 << 2,
    CSSColorSwiftChannelAngle = 1 << 3,
    CSSColorSwiftChannelLengthPercentage = 1 << 4,
    CSSColorSwiftChannelLength = 1 << 5,
    CSSColorSwiftChannelAnglePercentage = 1 << 6,
    CSSColorSwiftChannelResolution = 1 << 7,
};

template<typename T> constexpr uint8_t colorSwiftChannelType()
{
    if constexpr (std::same_as<T, CSS::Keyword::None>)
        return CSSColorSwiftChannelNone;
    else if constexpr (T::category == CSS::Category::Number)
        return CSSColorSwiftChannelNumber;
    else if constexpr (T::category == CSS::Category::Percentage)
        return CSSColorSwiftChannelPercentage;
    else if constexpr (T::category == CSS::Category::LengthPercentage)
        return CSSColorSwiftChannelLengthPercentage;
    else if constexpr (T::category == CSS::Category::Length)
        return CSSColorSwiftChannelLength;
    else if constexpr (T::category == CSS::Category::AnglePercentage)
        return CSSColorSwiftChannelAnglePercentage;
    else if constexpr (T::category == CSS::Category::Resolution)
        return CSSColorSwiftChannelResolution;
    else {
        static_assert(T::category == CSS::Category::Angle);
        return CSSColorSwiftChannelAngle;
    }
}

// Swift tries a <percentage> or an <angle> before a <number>, as MetaConsumer does when it is listed first.
template<typename... Ts> constexpr uint8_t colorSwiftChannelTypes(brigand::list<Ts...>)
{
    bool numberSeen = false;
    bool numberLast = true;
    ((numberLast = numberLast && !(numberSeen && (colorSwiftChannelType<Ts>() & (CSSColorSwiftChannelPercentage | CSSColorSwiftChannelAngle))), numberSeen = numberSeen || colorSwiftChannelType<Ts>() == CSSColorSwiftChannelNumber), ...);
    return numberLast ? (colorSwiftChannelType<Ts>() | ...) : 0;
}

// Channel `index` of a color function: the CSSColorSwiftChannel types it takes, and its symbol in a relative color.
struct CSSColorSwiftChannel {
    uint8_t types;
    uint16_t symbol;
};

template<typename Descriptor, unsigned Index> constexpr CSSColorSwiftChannel colorSwiftChannelAt()
{
    constexpr auto types = colorSwiftChannelTypes(GetCSSColorParseTypeWithCalcComponentTypeList<Descriptor, Index> { });
    static_assert(types);
    return { types, std::to_underlying(std::get<Index>(Descriptor::components).symbol) };
}

template<typename Descriptor> constexpr std::array<CSSColorSwiftChannel, 4> colorSwiftChannelsOf()
{
    if constexpr (std::tuple_size_v<std::decay_t<decltype(Descriptor::components)>> == 1)
        return { colorSwiftChannelAt<Descriptor, 0>() };
    else
        return { colorSwiftChannelAt<Descriptor, 0>(), colorSwiftChannelAt<Descriptor, 1>(), colorSwiftChannelAt<Descriptor, 2>(), colorSwiftChannelAt<Descriptor, 3>() };
}

inline CSSColorSwiftChannel colorSwiftChannel(uint8_t descriptor, uint8_t index)
{
    // Channels a descriptor does not have are { 0, 0 }; those it has take at least one type.
    static constexpr auto channels = [] {
        std::array<std::array<CSSColorSwiftChannel, 4>, std::to_underlying(CSSColorSwiftDescriptor::Alpha) + 1> table { };
        for (uint8_t i = 0; i < table.size(); ++i)
            table[i] = callWithColorSwiftDescriptor(i, []<typename Descriptor>() { return colorSwiftChannelsOf<Descriptor>(); });
        return table;
    }();
    RELEASE_ASSERT(descriptor < channels.size() && index < 4 && channels[descriptor][index].types);
    return channels[descriptor][index];
}

// The channels of a color function, a percentage of color-mix() or dynamic-range-limit-mix() at index 0, or the
// components of a position, as Swift consumed them.
class CSSColorSwiftComponents {
public:
    CSSColorSwiftComponents() = default;

    // The CSSColorSwiftChannel type of channel `index`, or 0 if it is absent.
    uint8_t type(uint8_t index) const { return at(index).type; }
    ALWAYS_INLINE void setNone(uint8_t index) { set(index, CSSColorSwiftChannelNone, 0, 0, 0); }
    ALWAYS_INLINE void setSymbol(uint8_t index, uint16_t symbol) { set(index, CSSColorSwiftChannelNone, 0, symbol, 0); }
    // A number, percentage, angle or length-percentage token's value; an angle's unit is its CSSUnitType, a
    // length-percentage's its CSS::LengthPercentageUnit.
    ALWAYS_INLINE void setValue(uint8_t index, uint8_t type, uint8_t unit, double value) { set(index, type, unit, 0, value); }
    // UnevaluatedCalcBase::parseBase for channel `index` as `type`, on the arguments [argumentsStart, argumentsEnd) of
    // the math function `function`, with the channels' symbols of `descriptor` if `relative`.
    bool parseCalc(const CSSPropertyConsumerSwiftValue&, uint8_t index, uint8_t type, double rangeMin, double rangeMax, uint32_t argumentsStart, uint32_t argumentsEnd, uint16_t function, uint8_t descriptor, bool relative);

    struct Component {
        uint8_t type { 0 };
        uint8_t unit { 0 };
        uint16_t symbol { 0 }; // With type None, a symbol unless 0.
        double value { 0 };
        std::optional<CSS::UnevaluatedCalcBase> calc;
    };

    const Component& at(uint8_t index) const
    {
        RELEASE_ASSERT(index < m_components.size());
        return m_components[index];
    }
    const Component& operator[](size_t index) const
    {
        RELEASE_ASSERT(index < m_components.size());
        return m_components[index];
    }

private:
    // The four components of a position at `offset` among CSSImageSwiftParts's, for shape().
    friend CSSColorSwiftComponents makePositionSwiftComponents(const Vector<Component, 16>&, size_t offset);
    ALWAYS_INLINE void set(uint8_t index, uint8_t type, uint8_t unit, uint16_t symbol, double value)
    {
        auto& component = mutableAt(index);
        component.type = type;
        component.unit = unit;
        component.symbol = symbol;
        component.value = value;
        component.calc.reset();
    }

    Component& mutableAt(uint8_t index)
    {
        RELEASE_ASSERT(index < m_components.size());
        return m_components[index];
    }

    std::array<Component, 4> m_components;
};

// The colors of color-layers(), or the components and color interpolation method of color-mix().
class CSSColorSwiftList {
    WTF_MAKE_NONCOPYABLE(CSSColorSwiftList);
public:
    CSSColorSwiftList() = default;
    CSSColorSwiftList(CSSColorSwiftList&&) = default;
    ~CSSColorSwiftList();

    void append(CSS::Color&& color) { colors.append(WTF::move(color)); }
    // A color with the percentage at component 0, or none.
    void appendMixComponent(const CSSColorSwiftComponents& percentage, CSS::Color&&);
    void setColorInterpolationMethod(CSS::ColorInterpolationMethod&& method) { colorInterpolationMethod = WTF::move(method); }

private:
    friend CSS::Color makeColorLayers(CSSColorSwiftList&&);
    friend CSS::Color makeColorMix(CSSColorSwiftList&&);

    Vector<CSS::Color> colors;
    // Behind UniqueRef so that the percentages, which Swift imports as unsafe, do not make this type unsafe.
    Variant<std::monostate, UniqueRef<CommaSeparatedVector<CSS::ColorMix::Component>::Container>> mixComponents;
    std::optional<CSS::ColorInterpolationMethod> colorInterpolationMethod;
};

// The components of dynamic-range-limit-mix().
class CSSDynamicRangeLimitSwiftMix {
    WTF_MAKE_NONCOPYABLE(CSSDynamicRangeLimitSwiftMix);
public:
    CSSDynamicRangeLimitSwiftMix() = default;
    CSSDynamicRangeLimitSwiftMix(CSSDynamicRangeLimitSwiftMix&&) = default;
    ~CSSDynamicRangeLimitSwiftMix();

    // A limit with the percentage at component 0.
    void append(const CSSColorSwiftComponents& percentage, CSS::DynamicRangeLimit&&);
    size_t size() const;

private:
    friend CSS::DynamicRangeLimit makeDynamicRangeLimitMix(CSSDynamicRangeLimitSwiftMix&&);

    // Behind UniqueRef, as CSSColorSwiftList's components are.
    Variant<std::monostate, UniqueRef<CSS::DynamicRangeLimitMixParameters::Container>> components;
};

using CSSPropertyConsumerSwiftSRGBA8 = SRGBA<uint8_t>;

// Whether `id` is not a color keyword of the OptionSet<CSS::ColorType> `allowedColorTypes`, is one the context does
// not allow, or is one it allows.
enum : uint8_t {
    CSSColorSwiftNotAKeyword,
    CSSColorSwiftDisallowedKeyword,
    CSSColorSwiftAllowedKeyword,
};
uint8_t colorKeywordForSwift(const CSSPropertyConsumerSwiftValue&, uint16_t id, uint8_t allowedColorTypes);

// What the context and the property allow.
enum : uint8_t {
    CSSColorSwiftAcceptsQuirkyColor = 1 << 0, // HTMLQuirksMode and CSSProperty::acceptsQuirkyColor(currentProperty).
    CSSColorSwiftColorLayersEnabled = 1 << 1,
    CSSColorSwiftDynamicRangeLimitMixEnabled = 1 << 2,
    CSSColorSwiftConstrainedDynamicRangeLimitEnabled = 1 << 3,
    CSSColorSwiftAxisRelativePositionKeywordsEnabled = 1 << 4,
};
uint8_t colorContextForSwift(const CSSPropertyConsumerSwiftValue&);

// What the context enables for the consumers that are not of colors.
enum : uint32_t {
    CSSConsumerSwiftGridLanesEnabled = 1 << 0,
    CSSConsumerSwiftRubyDisplayTypesEnabled = 1 << 1,
    CSSConsumerSwiftSpringTimingFunctionEnabled = 1 << 2,
    CSSConsumerSwiftSymbolsFunctionEnabled = 1 << 3,
    CSSConsumerSwiftCalcSizeFunctionEnabled = 1 << 4,
    CSSConsumerSwiftLegacyFontFaceAttributeMode = 1 << 5,
    CSSConsumerSwiftFontPaletteMixFunctionEnabled = 1 << 6,
    CSSConsumerSwiftMeshGradientsEnabled = 1 << 7,
};
uint32_t consumerContextForSwift(const CSSPropertyConsumerSwiftValue&);

// The CSS::Color of a color function with `descriptor` (CSSColorSwiftDescriptor), as consumeAbsoluteFunctionParameters
// and consumeRelativeFunctionParameters make it, nested `nestingLevel` deep.
CSS::Color makeAbsoluteColor(const CSSPropertyConsumerSwiftValue&, uint8_t descriptor, const CSSColorSwiftComponents&, uint32_t nestingLevel);
CSS::Color makeRelativeColor(uint8_t descriptor, const CSSColorSwiftComponents&, CSS::Color&& origin);
CSS::Color makeRelativeAlphaColor(const CSSColorSwiftComponents&, CSS::Color&& origin);
CSS::Color makeColorLayers(CSSColorSwiftList&&);
CSS::Color makeColorMix(CSSColorSwiftList&&);
// consumeColor's CSSValue of a color.
Ref<CSSValue> makeColorValue(const CSSPropertyConsumerSwiftValue&, CSS::Color&&);
// consumeColor's CSSValue of a hex color.
Ref<CSSValue> makeHexColorValue(const CSSPropertyConsumerSwiftValue&, CSSPropertyConsumerSwiftSRGBA8);

// consumeColorInterpolationMethod on the tokens [start, end), at `in`, into `method`: the tokens it consumed, or
// UINT32_MAX if they do not begin one.
uint32_t consumeColorInterpolationMethodForSwift(const CSSPropertyConsumerSwiftValue&, uint32_t start, uint32_t end, CSS::ColorInterpolationMethod& method);

CSS::DynamicRangeLimit makeDynamicRangeLimitMix(CSSDynamicRangeLimitSwiftMix&&);

// Gives the CSS:: value of the position consumer `consumer` (Position for <position> and <bg-position>) to
// setUnresolvedResult. Bits 0-3 of `layout` index its horizontal keyword or offset in `components`, bits 4-7 the
// horizontal length, bits 8-11 and 12-15 the vertical ones; 0xf for none. Keywords are symbols.
void setPositionResult(const CSSPropertyConsumerSwiftValue&, uint16_t consumer, const CSSColorSwiftComponents&, uint16_t layout);

// MARK: - Images

// The color of a gradient's stop, a shadow or image() as Swift consumed it: none, the keyword color `keyword`, `hex`,
// the color setPendingColor gave, or the color function with `descriptor` (CSSColorSwiftDescriptor) nested
// `nestingLevel` deep, whose channels come with it.
enum : uint8_t {
    CSSColorSwiftNoColor,
    CSSColorSwiftKeywordColor,
    CSSColorSwiftHexColor,
    CSSColorSwiftPendingColor,
    CSSColorSwiftFunctionColor,
};
struct CSSColorSwiftStopColor {
    uint8_t kind { CSSColorSwiftNoColor };
    uint8_t descriptor { 0 };
    uint16_t keyword { 0 };
    CSSPropertyConsumerSwiftSRGBA8 hex { };
    uint32_t nestingLevel { 0 };
};

// The stops of the gradient being consumed, of the kind beginGradientStops gave, the color setPendingColor gave, and
// the stops of a linear() easing function, the functions of a filter or the <calc-sum>s of a calc-size(): on
// consumePropertyWithSwift's stack, for one call.
struct CSSGradientSwiftStops {
    template<typename Stop> using Stops = Vector<Stop, 16>;
    Variant<std::monostate, Stops<CSS::GradientLinearColorStop>, Stops<CSS::GradientAngularColorStop>, Stops<CSS::GradientDeprecatedColorStop>, Vector<CSS::LinearEasingParameters::Stop>, CSS::FilterValueList, CSS::AppleColorFilterValueList, Vector<CSS::CalcSizeCalculation>> stops;
    Markable<CSS::Color> pendingColor;

    WTF_FORBID_HEAP_ALLOCATION;
};

// The stops of a linear or radial, a conic, or a -webkit-gradient() gradient.
enum : uint8_t {
    CSSGradientSwiftLinearStops,
    CSSGradientSwiftAngularStops,
    CSSGradientSwiftDeprecatedStops,
};
// Begins the stops of a gradient of `kind`, dropping the stops before them and the pending color.
void beginGradientStops(const CSSPropertyConsumerSwiftValue&, uint8_t kind);
// A stop of `color` at component 0 of `positions` or without a position, or with `second`, stops of it at components
// 0 and 1; without a color, a hint at component 0.
void appendGradientStop(const CSSPropertyConsumerSwiftValue&, const CSSColorSwiftStopColor&, const CSSColorSwiftComponents& channels, const CSSColorSwiftComponents& positions, bool second);
// The color of CSSColorSwiftPendingColor.
void setPendingColor(const CSSPropertyConsumerSwiftValue&, CSS::Color&&);

// A gradient's color interpolation method, the colors and components of shadows or image(), or the images of an image
// function with a cross-fade() percentage each, as Swift consumed them.
class CSSImageSwiftParts {
    WTF_MAKE_NONCOPYABLE(CSSImageSwiftParts);
public:
    // Swift zero-fills an object before calling a constructor without arguments; it calls this one without the fill.
    explicit CSSImageSwiftParts(uint8_t) { }
    CSSImageSwiftParts(CSSImageSwiftParts&&) = default;
    ~CSSImageSwiftParts();

    // A shadow's or image()'s color or none, with component 0 of `components`, or an image with a percentage at
    // component 0 or none.
    void appendColor(const CSSPropertyConsumerSwiftValue&, const CSSColorSwiftStopColor&, const CSSColorSwiftComponents& channels, const CSSColorSwiftComponents& components);
    void appendImage(CSSValue& image, const CSSColorSwiftComponents& percentage) { images.append(image); positions.append(percentage.at(0)); }
    void append(const CSSColorSwiftComponents& components, uint8_t index) { positions.append(components.at(index)); }
    void setColorInterpolationMethod(CSS::ColorInterpolationMethod&& method) { colorInterpolationMethod = WTF::move(method); }

    template<typename Stops> CSS::GradientColorInterpolationMethod gradientColorInterpolationMethod(const Stops&) const;

private:
    friend Ref<CSSValue> makeImageValue(const CSSPropertyConsumerSwiftValue&, uint16_t, const CSSColorSwiftComponents&, const CSSColorSwiftComponents&, uint16_t, CSSImageSwiftParts&&);
    friend uint32_t setBorderResult(const CSSPropertyConsumerSwiftValue&, uint16_t, CSSImageSwiftParts&&, uint32_t);
    friend void setKeyframeKeyListResult(const CSSPropertyConsumerSwiftValue&, CSSImageSwiftParts&&);
    friend Ref<CSSValue> makeTextShadowValue(const CSSPropertyConsumerSwiftValue&, CSSImageSwiftParts&&);
    friend RefPtr<CSSValue> setEasingFunctionResult(const CSSPropertyConsumerSwiftValue&, uint16_t, uint16_t, uint16_t, const CSSColorSwiftComponents&, double, uint32_t, CSSImageSwiftParts&&);
    friend RefPtr<CSSValue> makeBasicShapeValue(const CSSPropertyConsumerSwiftValue&, uint16_t, uint16_t, uint32_t, bool, const CSSColorSwiftComponents&, uint16_t, CSSImageSwiftParts&&);
    friend CSS::MaskBorder makeMaskBorderSwift(CSSImageSwiftParts&, size_t);
    friend RefPtr<CSSValue> makeMaskingValue(const CSSPropertyConsumerSwiftValue&, uint16_t, CSSImageSwiftParts&&);

    // Inline, for three shadows or a border-image's 16 components.
    Vector<Markable<CSS::Color>, 3> colors;
    Vector<CSSColorSwiftComponents::Component, 16> positions;
    CSSValueListBuilder images;
    std::optional<CSS::ColorInterpolationMethod> colorInterpolationMethod;
};

// The `positionLayout` of makeImageValue without a position, and the CSSValueID of type(), which Swift cannot name.
constexpr uint16_t CSSImageSwiftNoPosition = 0xffff;
constexpr uint16_t CSSImageSwiftTypeFunction = std::to_underlying(CSSValueID::Type);

// A mesh-gradient() point's header: bits 0-1 its location, bit 2 whether it begins a row.
enum : uint16_t {
    CSSMeshGradientSwiftNoLocation,
    CSSMeshGradientSwiftAbsoluteLocation,
    CSSMeshGradientSwiftRelativeLocation,
    CSSMeshGradientSwiftBeginsRow = 1 << 2,
};

// The gradient, cross-fade(), image(), light-dark() or image-set() `function` (a CSSValueID). A gradient's line or
// size and shape (a symbol at component 3: circle or ellipse) are in `line`, its position (setPositionResult's layout)
// in `position`, or for -webkit-gradient(radial), its radii; -webkit-cross-fade()'s progress is at component 0 of
// `line`, and an image of none is the keyword. mesh-gradient()'s background color, or none, is the first color of
// `parts`, and each other color is a point's, whose component is its header (a symbol, CSSMeshGradientSwift bits); an
// absolute location follows it as a position (its layout as a symbol, then its four components), a relative one as a
// coordinate pair (two components), then its control points, each a position, or a coordinate pair and its anchor
// (origin as a symbol, or absent), then one absent component.
Ref<CSSValue> makeImageValue(const CSSPropertyConsumerSwiftValue&, uint16_t function, const CSSColorSwiftComponents& line, const CSSColorSwiftComponents& position, uint16_t positionLayout, CSSImageSwiftParts&&);
// The image of the string or url() among the tokens [start, end), as consumeImage and consumeURLRaw make it.
RefPtr<CSSValue> makeImageURLValue(const CSSPropertyConsumerSwiftValue&, uint32_t start, uint32_t end);
// -webkit-canvas(), -webkit-named-image() or paint() (`function`) of the identifier at `name`, paint() with the
// arguments [argumentsStart, argumentsEnd), or null for paint() without the CSS Painting API.
RefPtr<CSSValue> makeNamedImageValue(const CSSPropertyConsumerSwiftValue&, uint16_t function, uint32_t name, uint32_t argumentsStart, uint32_t argumentsEnd);
// An image-set() option: `image`, the resolution at component 0 or none, and type() of the string at `type`, or none
// for UINT32_MAX.
Ref<CSSValue> makeImageSetOptionValue(const CSSPropertyConsumerSwiftValue&, CSSValue& image, const CSSColorSwiftComponents& resolution, uint32_t type);

// MARK: - Borders, shadows and reflections

// Gives the CSS:: value of the border-radius, border-image, box-shadow or -webkit-box-reflect consumer `consumer` to
// setUnresolvedResult, from the components of `parts`: radii at 0-3 and 4-7 (BorderRadiusSide: 0-1, 2-3); edges at
// 0-3, then a slice's fill at 4 (a symbol, or absent); border-image rules at 0-1; for border-image, its slice at 0,
// width at 5, outset at 9, rules at 13 and a source at 15 (type None) if they are present. A source is the image of
// `parts`, or none without one. Shadow `i` is color `i` with inset at 5i, and x, y, blur and spread at 5i+1 to 5i+4;
// none without shadows. A reflection is its direction at 0 and offset at 1, or none without components, with the
// mask-border's parts, if any, from 2, laid out as a border-image's. Absent edges complete the present ones; absent
// optional parts stay absent. Returns 0; `maskStart` is unused.
uint32_t setBorderResult(const CSSPropertyConsumerSwiftValue&, uint16_t consumer, CSSImageSwiftParts&&, uint32_t maskStart);
// consumeRepeatStyle's CSSValue.
Ref<CSSValue> makeBackgroundRepeatValue(uint16_t horizontal, uint16_t vertical);

#if ENABLE(DARK_MODE_CSS)
// The color-scheme of the identifiers among the tokens [start, end).
CSS::ColorScheme makeColorScheme(const CSSPropertyConsumerSwiftValue&, uint32_t start, uint32_t end, bool only);
#endif

// MARK: - Keyframes, text shadows, position areas, link parameters and easing functions

// Whether the CSSValueID `id` is a <timeline-range-name>.
bool isTimelineRangeNameForSwift(uint16_t id);
// Gives consumeKeyframeKeyList's keys to setUnresolvedResult: key `i` is the CSSValueID symbol at component 2i of
// `parts`, Normal for from, to and a percentage alone, and the percentage at component 2i + 1.
void setKeyframeKeyListResult(const CSSPropertyConsumerSwiftValue&, CSSImageSwiftParts&&);
// The <keyframes-name> of the string token at `index`, or null if it is empty.
RefPtr<CSSValue> makeKeyframesNameValue(const CSSPropertyConsumerSwiftValue&, uint32_t index);
// The text-shadow of `parts`: shadow `i` is color `i` with x, y and blur at components 4i + 1 to 4i + 3; none
// without shadows.
Ref<CSSValue> makeTextShadowValue(const CSSPropertyConsumerSwiftValue&, CSSImageSwiftParts&&);
// The position-area of the identifiers `first` and `second` (CSSValueIDs), or of `first` alone if `second` is
// UINT32_MAX, or null if they are not one.
RefPtr<CSSValue> makePositionAreaValue(uint16_t first, uint32_t second);
// Gives the param() to setUnresolvedResult whose spec is the keyword `keyword`, or if it is Invalid, the dashed
// identifier at `name` and the <css-type> that starts the arguments [start, end), followed by a comma and the value.
// Returns false and gives nothing if they are not one.
bool setParamFunctionResult(const CSSPropertyConsumerSwiftValue&, uint16_t keyword, uint32_t name, uint32_t start, uint32_t end);
// The easing function of the EasingFunction or UnresolvedEasingFunction `consumer`: the keyword `keyword` if
// `function` is Invalid, else the function `function` (CSSValueIDs). cubic-bezier()'s and spring()'s numbers are
// components 0-3 of `numbers`; steps() has the position `keyword` and the integer `count`, or unless it is UINT32_MAX,
// the calc() at the token `countCalc`;
// linear()'s stops are those appendLinearEasingStop gave. Returns the CSSValue of an EasingFunction; gives an
// UnresolvedEasingFunction's to setUnresolvedResult and returns null.
RefPtr<CSSValue> setEasingFunctionResult(const CSSPropertyConsumerSwiftValue&, uint16_t consumer, uint16_t function, uint16_t keyword, const CSSColorSwiftComponents& numbers, double count, uint32_t countCalc, CSSImageSwiftParts&&);
// A linear() stop: its output at component 0 of `stop`, and its input at components 1 and 2 or none.
void appendLinearEasingStop(const CSSPropertyConsumerSwiftValue&, const CSSColorSwiftComponents& stop);

// MARK: - Counter styles, quotes, content, calc-size() and unicode-range

// The <counter-style-name> of the identifier at `index`: its keyword if it is a predefined counter style, else a
// <custom-ident>.
Ref<CSSValue> makeCounterStyleNameValue(const CSSPropertyConsumerSwiftValue&, uint32_t index);
// symbols() with the <symbols-type> at the token `system`, or none for UINT32_MAX, and the strings among the tokens
// [start, end), or null if `system` is not a <symbols-type>.
RefPtr<CSSValue> makeSymbolsFunctionValue(const CSSPropertyConsumerSwiftValue&, uint32_t system, uint32_t start, uint32_t end);
// The integer of the <integer> (<integer [0,∞]> if `nonnegative`) primitive `integer`, as the style builder resolves
// it: clamped to int, a calc() evaluated.
int counterStyleIntegerForSwift(CSSValue& integer, bool nonnegative);
// The <symbol> at the start of the tokens [start, end), and in `next` where it ends, or null if there is none.
RefPtr<CSSValue> consumeCounterStyleSymbolForSwift(const CSSPropertyConsumerSwiftValue&, uint32_t start, uint32_t end, uint32_t& next);

// quotes of the keyword `keyword` (a CSSValueID), or if it is Invalid, of the strings among the tokens [start, end).
Ref<CSSValue> makeQuotesValue(const CSSPropertyConsumerSwiftValue&, uint16_t keyword, uint32_t start, uint32_t end);

// The kinds of a content item.
enum : uint8_t {
    CSSContentSwiftText, // The string at `token`.
    CSSContentSwiftImage, // The next of the images.
    CSSContentSwiftKeyword, // The identifier at `token`: a quote, or a glyph in the UA sheet.
    CSSContentSwiftCounter, // counter() of the identifier at `token`.
    CSSContentSwiftCounters, // counters() of the identifier at `token` and the string at `separator`.
};

// The items of a content value as Swift consumed them, and its alternative text: the items from beginAltContent on.
class CSSContentSwiftParts {
    WTF_MAKE_NONCOPYABLE(CSSContentSwiftParts);
public:
    // Swift zero-fills an object before calling a constructor without arguments; it calls this one without the fill.
    explicit CSSContentSwiftParts(uint8_t) { }
    CSSContentSwiftParts(CSSContentSwiftParts&&) = default;
    ~CSSContentSwiftParts();

    // An item of `kind`. A counter's style is decimal if `style` is UINT32_MAX, else the identifier or the symbols()
    // at the token `style`, with the <symbols-type> at `system` and the strings among [start, end).
    void append(uint8_t kind, uint32_t token, uint32_t separator, uint32_t style, uint32_t system, uint32_t start, uint32_t end) { items.append({ kind, token, separator, style, system, start, end }); }
    void appendImage(CSSValue& image) { items.append({ CSSContentSwiftImage, 0, 0, 0, 0, 0, 0 }); images.append(image); }
    void beginAltContent() { altStart = items.size(); }

private:
    friend RefPtr<CSSValue> makeContentValue(const CSSPropertyConsumerSwiftValue&, uint16_t, CSSContentSwiftParts&&);

    struct Item {
        uint8_t kind;
        uint32_t token;
        uint32_t separator;
        uint32_t style;
        uint32_t system;
        uint32_t start;
        uint32_t end;
    };
    Vector<Item, 4> items;
    CSSValueListBuilder images;
    std::optional<size_t> altStart;
};

// content of the keyword `keyword` (a CSSValueID), or if it is Invalid, of `parts`, or null if an identifier or a
// counter style in them is not one.
RefPtr<CSSValue> makeContentValue(const CSSPropertyConsumerSwiftValue&, uint16_t keyword, CSSContentSwiftParts&&);

// The levels of a calc-size() as Swift consumed them, the innermost first: each level's basis. Their <calc-sum>s are
// in the state's CSSGradientSwiftStops, in the order they appear.
class CSSCalcSizeSwiftParts {
    WTF_MAKE_NONCOPYABLE(CSSCalcSizeSwiftParts);
public:
    // Swift zero-fills an object before calling a constructor without arguments; it calls this one without the fill.
    explicit CSSCalcSizeSwiftParts(uint8_t) { }
    CSSCalcSizeSwiftParts(CSSCalcSizeSwiftParts&&) = default;
    ~CSSCalcSizeSwiftParts();

    // A level whose basis is the keyword `basis` (a CSSValueID), CalcSize for the level before it, or Invalid for the
    // <calc-sum> before its calculation's.
    void appendLevel(uint16_t basis) { bases.append(basis); }

private:
    friend Ref<CSSValue> makeCalcSizeValue(const CSSPropertyConsumerSwiftValue&, CSSCalcSizeSwiftParts&&);

    Vector<uint16_t, 4> bases;
};

// The CSSPropertyID of the property being parsed.
uint16_t currentPropertyForSwift(const CSSPropertyConsumerSwiftValue&);
// Appends to the state's CSSGradientSwiftStops the <calc-sum> at the start of the tokens [start, end) as calc-size()
// parses it, allowing `size` if `allowsSize`, and gives in `next` where it ends; returns false if there is none.
bool consumeCalcSizeSumForSwift(const CSSPropertyConsumerSwiftValue&, uint32_t start, uint32_t end, bool allowsSize, uint32_t& next);
// The calc-size() of `parts` and the <calc-sum>s in the state's CSSGradientSwiftStops.
Ref<CSSValue> makeCalcSizeValue(const CSSPropertyConsumerSwiftValue&, CSSCalcSizeSwiftParts&&);

// MARK: - Fonts

// Whether the CSSValueID `id` names a generic font family, which a <family-name> of one identifier cannot be.
bool isGenericFontFamilyForSwift(uint16_t id);
// The font family name of the generic family `keyword` (a CSSValueID), or if it is Invalid, of the string token at
// `start` or of the identifiers and numbers among the tokens [start, end), joined by spaces.
Ref<CSSValue> makeFontFamilyNameValue(const CSSPropertyConsumerSwiftValue&, uint16_t keyword, uint32_t start, uint32_t end);
// Whether the angle `value` in the CSSUnitType `unit` is an oblique font style's angle, [-90deg, 90deg].
bool isObliqueAngleForSwift(double value, uint8_t unit);
// The oblique font style of the angle at component 0.
Ref<CSSValue> makeFontStyleWithAngleValue(const CSSColorSwiftComponents&);

struct CSSFontPaletteSwiftStack;

// The font palettes and the open palette-mix() functions of a font-palette, as Swift consumed them.
class CSSFontPaletteSwiftParts {
    WTF_MAKE_NONCOPYABLE(CSSFontPaletteSwiftParts);
public:
    // Swift zero-fills an object before calling a constructor without arguments; it calls this one without the fill.
    explicit CSSFontPaletteSwiftParts(uint8_t);
    CSSFontPaletteSwiftParts(CSSFontPaletteSwiftParts&&);
    ~CSSFontPaletteSwiftParts();

    // A palette: normal, light or dark (a CSSValueID), or the identifier token at `index`.
    void appendKeyword(uint16_t);
    void appendIdentifier(const CSSPropertyConsumerSwiftValue&, uint32_t index);
    // A palette-mix(), whose components are the palettes appended until endMix().
    void beginMix();
    void setColorInterpolationMethod(CSS::ColorInterpolationMethod&&);
    // Makes the last palette a component of the open palette-mix(), with the percentage at component 0 or none.
    void endMixComponent(const CSSColorSwiftComponents& percentage);
    void endMix();

private:
    friend Ref<CSSValue> makeFontPaletteValue(CSSFontPaletteSwiftParts&&);

    // Behind UniqueRef so that the percentages, which Swift imports as unsafe, do not make this type unsafe.
    UniqueRef<CSSFontPaletteSwiftStack> stack;
};

// The font-palette of the last palette of `parts`.
Ref<CSSValue> makeFontPaletteValue(CSSFontPaletteSwiftParts&&);
// The <feature-tag-value> of the tag `tag` (its four characters from the low byte up) and the integer `integer`, or
// if `calc` is not UINT32_MAX, the integer calc() at the token `calc`.
Ref<CSSValue> makeFontFeatureValue(const CSSPropertyConsumerSwiftValue&, uint32_t tag, double integer, uint32_t calc);
// The <variation-tag-value> of the tag `tag` and the number `number`.
Ref<CSSValue> makeFontVariationValue(uint32_t tag, CSSValue& number);

enum class FontTechnology : uint8_t;

// The families of a font, the technologies of a tech(), or the family names of a @font-feature-values prelude, as
// Swift consumed them.
class CSSFontSwiftParts {
    WTF_MAKE_NONCOPYABLE(CSSFontSwiftParts);
public:
    // Swift zero-fills an object before calling a constructor without arguments; it calls this one without the fill.
    explicit CSSFontSwiftParts(uint8_t) { }
    CSSFontSwiftParts(CSSFontSwiftParts&&) = default;
    ~CSSFontSwiftParts();

    // The generic family `keyword` (a CSSValueID), or if it is Invalid, the family name of the tokens [start, end).
    void appendFamily(uint16_t keyword, uint32_t start, uint32_t end) { families.append({ keyword, start, end }); }
    // The font technology the CSSValueID `id` names; false if it names none.
    bool appendTechnology(uint16_t id);

private:
    friend void setUnresolvedFontResult(const CSSPropertyConsumerSwiftValue&, const CSSColorSwiftComponents&, uint16_t, uint16_t, CSSFontSwiftParts&&);
    friend void setFontTechResult(const CSSPropertyConsumerSwiftValue&, CSSFontSwiftParts&&);
    friend RefPtr<CSSValue> makeFontFaceSrcResourceValue(const CSSPropertyConsumerSwiftValue&, uint32_t, uint32_t, uint32_t, CSSFontSwiftParts&&);
    friend void setFontFeatureValuesPreludeResult(const CSSPropertyConsumerSwiftValue&, CSSFontSwiftParts&&);

    struct Family {
        uint16_t keyword;
        uint32_t start;
        uint32_t end;
    };
    Vector<Family, 4> families;
    Vector<FontTechnology> technologies;
};

// The font of the style, weight, size and line height at components 0 to 3 (an absent one is normal), the
// font-variant-caps and font-width keywords `variantCaps` and `width` (CSSValueIDs), and the families of `parts`.
void setUnresolvedFontResult(const CSSPropertyConsumerSwiftValue&, const CSSColorSwiftComponents&, uint16_t variantCaps, uint16_t width, CSSFontSwiftParts&&);
// The technologies of `parts`.
void setFontTechResult(const CSSPropertyConsumerSwiftValue&, CSSFontSwiftParts&&);
// The text of the token `index`, a font format.
void setFontFormatResult(const CSSPropertyConsumerSwiftValue&, uint32_t index);
// The src resource of the URL of the tokens [urlStart, urlEnd), the format at the token `format` unless it is
// UINT32_MAX, and the technologies of `parts`; null if the URL does not parse.
RefPtr<CSSValue> makeFontFaceSrcResourceValue(const CSSPropertyConsumerSwiftValue&, uint32_t urlStart, uint32_t urlEnd, uint32_t format, CSSFontSwiftParts&&);
// The src local() of the family name of the string token at `start` or of the identifiers among the tokens [start, end).
Ref<CSSValue> makeFontFaceSrcLocalValue(const CSSPropertyConsumerSwiftValue&, uint32_t start, uint32_t end);
// The @font-face font-style `keyword` (a CSSValueID), and for oblique, its `angles` angles at components 0 and 1.
Ref<CSSValue> makeFontFaceFontStyleValue(uint16_t keyword, const CSSColorSwiftComponents&, uint8_t angles);
// The family names of `parts`.
void setFontFeatureValuesPreludeResult(const CSSPropertyConsumerSwiftValue&, CSSFontSwiftParts&&);

// MARK: - Grid

// The parts of a grid value, in the order Swift consumed them.
enum : uint8_t {
    CSSGridSwiftLineNames, // '[': the CSSGridSwiftLineName parts up to CSSGridSwiftLineNamesEnd.
    CSSGridSwiftLineName, // The <custom-ident> at `token`.
    CSSGridSwiftLineNamesEnd,
    CSSGridSwiftAreaName, // `length` characters from `offset` of the string at `token`, a grid-template-areas name.
    CSSGridSwiftAreaRowEnd,
    CSSGridSwiftBreadthKeyword, // The <track-breadth> `keyword`: MinContent, MaxContent or Auto.
    CSSGridSwiftFlex, // A <flex [0,∞]>: the number of fr, or unless `token` is UINT32_MAX, the calc() at `token`.
    CSSGridSwiftLengthPercentage, // A <length-percentage [0,∞]>.
    CSSGridSwiftMinMax, // minmax(): its two breadths follow.
    CSSGridSwiftFitContent, // fit-content(): its <length-percentage [0,∞]> follows.
    // A repeat() of tracks: `keyword` AutoFill or AutoFit, or the count in `component.value` or unless `token` is
    // UINT32_MAX the calc() at `token`; its line names and track sizes follow, up to CSSGridSwiftRepeatEnd.
    CSSGridSwiftRepeat,
    // A repeat() of line names: `keyword` AutoFill or a count as CSSGridSwiftRepeat's; line names follow, up to
    // CSSGridSwiftRepeatEnd.
    CSSGridSwiftNameRepeat,
    CSSGridSwiftRepeatEnd,
    CSSGridSwiftSubgrid, // subgrid: its line names and line-name repeats follow.
};

class CSSGridSwiftParts {
    WTF_MAKE_NONCOPYABLE(CSSGridSwiftParts);
public:
    // Swift zero-fills an object before calling a constructor without arguments; it calls this one without the fill.
    explicit CSSGridSwiftParts(uint8_t) { }
    CSSGridSwiftParts(CSSGridSwiftParts&&) = default;
    ~CSSGridSwiftParts();

    uint32_t size() const { return m_parts.size(); }
    // Drops the parts from `size` on, those of a nested grammar that did not parse.
    void shrink(uint32_t size) { m_parts.shrink(size); }
    void append(uint8_t kind, uint32_t token) { m_parts.append({ kind, 0, token, 0, 0, { } }); }
    void appendAreaName(uint32_t token, uint32_t offset, uint32_t length) { m_parts.append({ CSSGridSwiftAreaName, 0, token, offset, length, { } }); }
    void appendKeyword(uint8_t kind, uint16_t keyword) { m_parts.append({ kind, keyword, UINT32_MAX, 0, 0, { } }); }
    void appendFlex(double value, uint32_t calc) { m_parts.append({ CSSGridSwiftFlex, 0, calc, 0, 0, { .value = value } }); }
    void appendRepeat(uint8_t kind, uint16_t keyword, double count, uint32_t calc) { m_parts.append({ kind, keyword, calc, 0, 0, { .value = count } }); }
    // The <length-percentage> at component `index` of `components`.
    void appendLengthPercentage(const CSSColorSwiftComponents& components, uint8_t index) { m_parts.append({ CSSGridSwiftLengthPercentage, 0, UINT32_MAX, 0, 0, components.at(index) }); }

private:
    friend RefPtr<CSSValue> setGridResult(const CSSPropertyConsumerSwiftValue&, uint16_t, CSSGridSwiftParts&&);

    struct Part {
        uint8_t kind;
        uint16_t keyword; // A CSSValueID.
        uint32_t token; // A token index, or UINT32_MAX.
        uint32_t offset;
        uint32_t length;
        CSSColorSwiftComponents::Component component;
    };
    // Inline, for a 4x4 grid-template-areas (16 names and 4 row ends) or a template list of 12 tracks with names.
    Vector<Part, 32> m_parts;
};

// The grid value of `consumer` from `parts`: grid-template-areas' rows (null if CSS::addRow rejects one), a row of
// grid-template-areas or line names alone, a track size or sizes, an explicit track list, or a template list. Gives a
// typed consumer's value to setUnresolvedResult and returns null.
RefPtr<CSSValue> setGridResult(const CSSPropertyConsumerSwiftValue&, uint16_t consumer, CSSGridSwiftParts&&);

// The kinds of setGridLineResult's <grid-line>.
enum : uint8_t {
    CSSGridSwiftLineAuto,
    CSSGridSwiftLineCustomIdent,
    CSSGridSwiftLineExplicit,
    CSSGridSwiftLineSpan,
    CSSGridSwiftLineSpanOfInteger,
};
// The <grid-line> of `consumer` (GridLine or UnresolvedGridLine) of `kind`, with the integer `index` or unless it is
// UINT32_MAX the calc() at the token `indexCalc`, and the <custom-ident> at the token `name` unless it is UINT32_MAX:
// a span of an index read as an <integer> (SpanOfInteger) narrowed to [1, ∞]. Returns the CSSValue of a GridLine;
// gives an UnresolvedGridLine's to setUnresolvedResult and returns null.
RefPtr<CSSValue> setGridLineResult(const CSSPropertyConsumerSwiftValue&, uint16_t consumer, uint8_t kind, double index, uint32_t indexCalc, uint32_t name);

// MARK: - Shapes

// The basic shape `function` (a CSSValueID) Swift consumed, from `parts`: circle() radius 0 and ellipse() radii 0-1, each
// a symbol (an extent) or a length, with the position (setPositionResult's layout `positionLayout`, or
// CSSImageSwiftNoPosition for none); inset() insets 0-3 (absent ones completed), rect() edges 0-3, xywh() location 0-1
// and size 2-3, each with radii 4-11 (absent: the default); polygon() vertices, two components each; path() the string at
// the token `pathString`; shape() its starting point and commands, as makeShapeSwift reads them. `fillRule` is a
// CSSValueID, or Invalid for none. A path() is a CSSPathValue if `asPathValue`.
// Null if the path does not parse or is empty.
RefPtr<CSSValue> makeBasicShapeValue(const CSSPropertyConsumerSwiftValue&, uint16_t function, uint16_t fillRule, uint32_t pathString, bool asPathValue, const CSSColorSwiftComponents& position, uint16_t positionLayout, CSSImageSwiftParts&&);
// The CSSValue of clip, or for UnresolvedMaskBorder the CSS::MaskBorder given to setUnresolvedResult, of `consumer`,
// from `parts`: clip's rect() edges at 0-3, or auto as a symbol at 0 alone; a mask-border as makeMaskBorderSwift reads
// it.
RefPtr<CSSValue> makeMaskingValue(const CSSPropertyConsumerSwiftValue&, uint16_t consumer, CSSImageSwiftParts&&);
// The CSSValue of the mask-border longhand `consumer`: of mask-border-slice from the edges of `components` (absent ones
// completed), with fill if `countOrFill` is 1; of mask-border-width or mask-border-outset from its edges; of
// mask-border-repeat from its first rule and its second, or the first again if `countOrFill` is 1; of
// mask-border-source from `image`, or none if it is null.
Ref<CSSValue> makeMaskBorderLonghandValue(uint16_t consumer, const CSSColorSwiftComponents& components, uint8_t countOrFill, CSSValue* image);
// The url of the url token or url() among the tokens [start, end), as consumeURL makes it with no modifiers, or null.
RefPtr<CSSValue> makeURLValue(const CSSPropertyConsumerSwiftValue&, uint32_t start, uint32_t end);
// ray() of the angle at component 0 of `ray`, its size (a symbol, or absent for closest-side) at 1 and contain (a
// symbol, or absent) at 2, with the position of `position` at `positionLayout`, or none for CSSImageSwiftNoPosition.
Ref<CSSValue> makeRayValue(const CSSColorSwiftComponents& ray, const CSSColorSwiftComponents& position, uint16_t positionLayout);

// MARK: - Filters

// Begins the functions of a filter, or of an -apple-color-filter if `apple`, dropping what the state's
// CSSGradientSwiftStops held.
void beginFilterValues(const CSSPropertyConsumerSwiftValue&, bool apple);
// Appends the filter function `function` (a CSSValueID) other than drop-shadow(), of an -apple-color-filter if `apple`,
// with its argument at component 0 of `argument` (absent for none; -apple-invert-lightness() has none).
void appendFilterFunction(const CSSPropertyConsumerSwiftValue&, bool apple, uint16_t function, const CSSColorSwiftComponents& argument);
// Appends drop-shadow() of `color` (or none), with x, y and blur at components 0-2 of `lengths`.
void appendDropShadowFilter(const CSSPropertyConsumerSwiftValue&, const CSSColorSwiftStopColor&, const CSSColorSwiftComponents& channels, const CSSColorSwiftComponents& lengths);
// Appends the url of the url token or url() among the tokens [start, end), as consumeURLRaw makes it; false if it is not one.
bool appendFilterURL(const CSSPropertyConsumerSwiftValue&, uint32_t start, uint32_t end);
// The filter, or for AppleColorFilter the -apple-color-filter, of the functions since beginFilterValues, or none
// without one. Filter and AppleColorFilter return their CSSValue, UnresolvedFilter gives the CSS::Filter to
// setUnresolvedResult; with an `image`, the filter() image of it.
RefPtr<CSSValue> makeFilterValue(const CSSPropertyConsumerSwiftValue&, uint16_t consumer, CSSValue* image);

// The CSS:: value T a CSSPropertyConsumerSwiftConsumer consumes, if it consumes one.
template<typename T> std::optional<T> consumeUnresolvedWithSwift(CSSParserTokenRange& range, CSS::PropertyParserState& state, CSSPropertyConsumerSwiftConsumer consumer, uint8_t options = 0)
{
    std::optional<T> result;
    CSSPropertyConsumerSwiftUnresolvedResult unresolvedResult { result };
    consumePropertyWithSwift(range, state, consumer, options, &unresolvedResult);
    return result;
}

} // namespace WebCore
