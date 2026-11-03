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

private:
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

// The stops of the gradient being consumed, of the kind beginGradientStops gave, and the color setPendingColor gave:
// on consumePropertyWithSwift's stack, for one call.
struct CSSGradientSwiftStops {
    template<typename Stop> using Stops = Vector<Stop, 16>;
    Variant<std::monostate, Stops<CSS::GradientLinearColorStop>, Stops<CSS::GradientAngularColorStop>, Stops<CSS::GradientDeprecatedColorStop>> stops;
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

    // Inline, for three shadows or a border-image's 16 components.
    Vector<Markable<CSS::Color>, 3> colors;
    Vector<CSSColorSwiftComponents::Component, 16> positions;
    CSSValueListBuilder images;
    std::optional<CSS::ColorInterpolationMethod> colorInterpolationMethod;
};

// The `positionLayout` of makeImageValue without a position, and the CSSValueID of type(), which Swift cannot name.
constexpr uint16_t CSSImageSwiftNoPosition = 0xffff;
constexpr uint16_t CSSImageSwiftTypeFunction = std::to_underlying(CSSValueID::Type);

// The gradient, cross-fade(), image(), light-dark() or image-set() `function` (a CSSValueID). A gradient's line or
// size and shape (a symbol at component 3: circle or ellipse) are in `line`, its position (setPositionResult's layout)
// in `position`, or for -webkit-gradient(radial), its radii; -webkit-cross-fade()'s progress is at component 0 of
// `line`, and an image of none is the keyword.
Ref<CSSValue> makeImageValue(const CSSPropertyConsumerSwiftValue&, uint16_t function, const CSSColorSwiftComponents& line, const CSSColorSwiftComponents& position, uint16_t positionLayout, CSSImageSwiftParts&&);
// The image of the string or url() among the tokens [start, end), as consumeImage and consumeURLRaw make it.
RefPtr<CSSValue> makeImageURLValue(const CSSPropertyConsumerSwiftValue&, uint32_t start, uint32_t end);
// filter() of `image` and the filter of all the tokens [start, end), or null if they are not one.
RefPtr<CSSValue> makeFilterImageValue(const CSSPropertyConsumerSwiftValue&, CSSValue& image, uint32_t start, uint32_t end);
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
// mask-border among the tokens from `maskStart` to the end unless it is UINT32_MAX. Absent edges complete the
// present ones; absent optional parts stay absent. Returns the tokens the mask-border consumed, or UINT32_MAX and
// gives nothing to setUnresolvedResult if they are not one.
uint32_t setBorderResult(const CSSPropertyConsumerSwiftValue&, uint16_t consumer, CSSImageSwiftParts&&, uint32_t maskStart);
// consumeRepeatStyle's CSSValue.
Ref<CSSValue> makeBackgroundRepeatValue(uint16_t horizontal, uint16_t vertical);

#if ENABLE(DARK_MODE_CSS)
// The color-scheme of the identifiers among the tokens [start, end).
CSS::ColorScheme makeColorScheme(const CSSPropertyConsumerSwiftValue&, uint32_t start, uint32_t end, bool only);
#endif

// The CSS:: value T a CSSPropertyConsumerSwiftConsumer consumes, if it consumes one.
template<typename T> std::optional<T> consumeUnresolvedWithSwift(CSSParserTokenRange& range, CSS::PropertyParserState& state, CSSPropertyConsumerSwiftConsumer consumer, uint8_t options = 0)
{
    std::optional<T> result;
    CSSPropertyConsumerSwiftUnresolvedResult unresolvedResult { result };
    consumePropertyWithSwift(range, state, consumer, options, &unresolvedResult);
    return result;
}

} // namespace WebCore
