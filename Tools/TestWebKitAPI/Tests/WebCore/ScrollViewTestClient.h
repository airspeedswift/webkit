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

// A ScrollView that answers from a scripted configuration and records every call ScrollView makes on its
// virtual members, and a HostWindow that records every invalidation and blit it is asked for. Layout is a
// "reflow" table: the contents size as a function of the width available to the contents, so a scrollbar
// that appears or disappears feeds back into the contents size as it does for a document. ScrollViewInputs.h
// drives it.

#include <WebCore/CornerRadii.h>
#include <WebCore/FloatPoint.h>
#include <WebCore/FloatQuad.h>
#include <WebCore/FloatRect.h>
#include <WebCore/FloatSize.h>
#include <WebCore/HostWindow.h>
#include <WebCore/IntPoint.h>
#include <WebCore/IntRect.h>
#include <WebCore/IntSize.h>
#include <WebCore/ScrollTypes.h>
#include <WebCore/ScrollView.h>
#include <WebCore/ScrollableArea.h>
#include <WebCore/Scrollbar.h>
#include <WebCore/StyleScrollbarGutter.h>
#include <bit>
#include <cstdint>
#include <cstring>
#include <optional>
#include <vector>
#include <wtf/Ref.h>
#include <wtf/SetForScope.h>
#include <wtf/TZoneMallocInlines.h>

namespace TestWebKitAPI {
namespace ScrollViewTesting {

using namespace WebCore;

// MARK: - Trace

// An FNV-1a digest over every recorded event: a call ScrollView makes on its subclass or host window (its kind
// 'C', its name and its arguments), or a value returned to the caller (a code naming the member, and the value), in
// order. Names are hashed a byte at a time and values a 64-bit word at a time.
class Trace {
public:
    uint64_t digest() const { return m_hash; }
    uint64_t events() const { return m_events; }
    void countEvent() { ++m_events; }

    void reset()
    {
        m_hash = initialHash;
        m_events = 0;
    }

    void bytes(const void* data, size_t size)
    {
        auto* p = static_cast<const uint8_t*>(data);
        for (size_t i = 0; i < size; ++i) {
            m_hash ^= p[i];
            m_hash *= prime;
        }
    }

    void word(uint64_t value)
    {
        m_hash ^= value;
        m_hash *= prime;
    }

private:
    static constexpr uint64_t initialHash = 14695981039346656037ull;
    static constexpr uint64_t prime = 1099511628211ull;
    uint64_t m_hash { initialHash };
    uint64_t m_events { 0 };
};

class TraceLine {
public:
    TraceLine(Trace& trace, char kind, const char* name)
        : m_trace(trace)
    {
        m_trace.countEvent();
        m_trace.bytes(&kind, 1);
        m_trace.bytes(name, std::strlen(name) + 1);
    }

    // A value returned to the caller, named by a code.
    TraceLine(Trace& trace, uint16_t code)
        : m_trace(trace)
    {
        m_trace.countEvent();
        m_trace.word(0x52000000u | code);
    }

    TraceLine& u(uint64_t value)
    {
        m_trace.word(value);
        return *this;
    }

    TraceLine& i(int value) { return u(static_cast<uint32_t>(value)); }
    TraceLine& b(bool value) { return u(value ? 1 : 0); }
    TraceLine& f(float value) { return u(std::bit_cast<uint32_t>(value)); }
    TraceLine& d(double value) { return u(std::bit_cast<uint64_t>(value)); }
    TraceLine& ipt(IntPoint value) { return u(static_cast<uint32_t>(value.x()) | static_cast<uint64_t>(static_cast<uint32_t>(value.y())) << 32); }
    TraceLine& isz(IntSize value) { return u(static_cast<uint32_t>(value.width()) | static_cast<uint64_t>(static_cast<uint32_t>(value.height())) << 32); }
    TraceLine& irect(const IntRect& value) { return ipt(value.location()).isz(value.size()); }
    TraceLine& pt(FloatPoint value) { return u(std::bit_cast<uint32_t>(value.x()) | static_cast<uint64_t>(std::bit_cast<uint32_t>(value.y())) << 32); }
    TraceLine& sz(FloatSize value) { return u(std::bit_cast<uint32_t>(value.width()) | static_cast<uint64_t>(std::bit_cast<uint32_t>(value.height())) << 32); }
    TraceLine& rect(const FloatRect& value) { return pt(value.location()).sz(value.size()); }
    TraceLine& dpt(DoublePoint value) { return d(value.x()).d(value.y()); }
    TraceLine& quad(const FloatQuad& value) { return pt(value.p1()).pt(value.p2()).pt(value.p3()).pt(value.p4()); }

private:
    Trace& m_trace;
};

// MARK: - Scripted configuration

// What a scripted call does to the view from inside one of the virtual members ScrollView calls.
enum class ReentryAction : uint8_t {
    None,
    SetContentsSize,
    ScrollbarModesAlwaysOff,
    SuppressScrollbars,
    UpdateScrollbars,
    ScrollTo,
};

enum class ReentryPoint : uint8_t {
    None,
    UpdateContentsSize,
    AvailableContentSizeChanged,
    DidAddScrollbar,
    WillRemoveScrollbar,
    ScrollTo,
};

enum class Gutter : uint8_t { Auto, Stable, StableBothEdges };

// One row of the reflow table: at an available width of at least minimumWidth, the contents are this size.
struct ReflowRow {
    int minimumWidth;
    IntSize contentsSize;
};

struct ScriptedConfig {
    float visibleContentScaleFactor { 1 };
    FloatBoxExtent obscuredContentInsets { 0.f, 0.f, 0.f, 0.f };
    int headerHeight { 0 };
    int footerHeight { 0 };
    int insetForLeftScrollbarSpace { 0 };
    IntSize totalScrollbarSpace;
    Gutter gutter { Gutter::Auto };
    bool rubberBandInProgress { false };
    bool canShowNonOverlayScrollbars { true };
    bool requestScrollToPositionHandles { false };
    bool verticalDocument { true };
    bool flippedDocument { false };
    bool placesVerticalScrollbarOnLeft { false };
    bool scrollContentsFastPathSucceeds { true };
    bool defersScrollUpdateAfterContentSizeChange { false };
    // Sorted by descending minimumWidth; empty means updateContentsSize() leaves the contents as they are.
    std::vector<ReflowRow> reflow;

    ReentryPoint reentryPoint { ReentryPoint::None };
    ReentryAction reentryAction { ReentryAction::None };
    // The call at reentryPoint (1-based) that performs reentryAction; 0 performs it on every call.
    unsigned reentryAtCall { 1 };
    IntSize reentryContentsSize;
    ScrollPosition reentryScrollPosition;
};

// MARK: - Recording host window

class RecordingHostWindow final : public HostWindow {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(RecordingHostWindow);
public:
    explicit RecordingHostWindow(Trace& trace)
        : m_trace(trace)
    {
    }

    // GraphicsClient
    PlatformDisplayID displayID() const final { return 0; }
#if ENABLE(WEBGL)
    RefPtr<GraphicsContextGL> createGraphicsContextGL(const GraphicsContextGLAttributes&) const final { return nullptr; }
#endif
#if HAVE(WEBGPU_IMPLEMENTATION)
    RefPtr<WebCore::WebGPUIntegration> createGPUForWebGPU() const final { return nullptr; }
#endif

    // HostWindow
    void invalidateRootView(const IntRect& rect) final { TraceLine(m_trace, 'C', "invalidateRootView").irect(rect); }
    void invalidateContentsAndRootView(const IntRect& rect) final { TraceLine(m_trace, 'C', "invalidateContentsAndRootView").irect(rect); }
    void invalidateContentsForSlowScroll(const IntRect& rect) final { TraceLine(m_trace, 'C', "invalidateContentsForSlowScroll").irect(rect); }

    void scroll(const IntSize& delta, const IntRect& rectToScroll, const IntRect& clipRect) final
    {
        TraceLine(m_trace, 'C', "hostScroll").isz(delta).irect(rectToScroll).irect(clipRect);
    }

    // The screen is the root view moved by screenOrigin.
    IntPoint screenToRootView(const IntPoint& point) const final { return point - screenOrigin; }
    IntPoint rootViewToScreen(const IntPoint& point) const final { return point + screenOrigin; }
    IntRect rootViewToScreen(const IntRect& rect) const final { return { rect.location() + screenOrigin, rect.size() }; }
    IntPoint accessibilityScreenToRootView(const IntPoint& point) const final { return screenToRootView(point); }
    IntRect rootViewToAccessibilityScreen(const IntRect& rect) const final { return rootViewToScreen(rect); }

    PlatformPageClient platformPageClient() const final { return nullptr; }
    void setCursor(const Cursor&) final { }
    void setCursorHiddenUntilMouseMoves(bool) final { }
    void windowScreenDidChange(PlatformDisplayID, std::optional<FramesPerSecond>) final { }
    FloatSize screenSize() const final { return { 1920, 1080 }; }
    FloatSize availableScreenSize() const final { return { 1920, 1050 }; }
    FloatSize overrideScreenSize() const final { return { }; }
    FloatSize overrideAvailableScreenSize() const final { return { }; }

    IntSize screenOrigin { 100, 50 };

private:
    RefPtr<ImageBuffer> createImageBuffer(const FloatSize&, RenderingMode, RenderingPurpose, float, const ColorSpace&, ImageBufferFormat) const final { return nullptr; }
    RefPtr<ImageBuffer> sinkIntoImageBuffer(std::unique_ptr<SerializedImageBuffer>) final { return nullptr; }
    RefPtr<ImageBuffer> createImageBufferFromTransferHandle(const ImageBufferTransferHandle&) final { return nullptr; }

    Trace& m_trace;
};

// MARK: - Recording scroll view

class RecordingScrollView final : public ScrollView {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(RecordingScrollView);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(RecordingScrollView);
public:
    static Ref<RecordingScrollView> create(Trace& trace, const ScriptedConfig& config, HostWindow* hostWindow)
    {
        return adoptRef(*new RecordingScrollView(trace, config, hostWindow));
    }

    ScriptedConfig& config() { return m_config; }
    unsigned maximumReentryDepth() const { return m_maximumReentryDepth; }

    // Protected and private members of ScrollView that the tests call directly, as LocalFrameView does.
    using ScrollView::handleDeferredScrollUpdateAfterContentSizeChange;
    using ScrollView::setHasHorizontalScrollbar;
    using ScrollView::setHasVerticalScrollbar;
    using ScrollView::setScrollOrigin;
    using ScrollView::sizeForUnobscuredContent;

    // ScrollView
    HostWindow* hostWindow() const final { return m_hostWindow; }
    IntRect windowClipRect() const final { return contentsToWindow(visibleContentRect(LegacyIOSDocumentVisibleRect)); }
    void paintContents(GraphicsContext&, const IntRect&, SecurityOriginPaintPolicy, RegionContext*) final { }
    void addedOrRemovedScrollbar() final { TraceLine(m_trace, 'C', "addedOrRemovedScrollbar"); }
    void delegatedScrollingModeDidChange() final { TraceLine(m_trace, 'C', "delegatedScrollingModeDidChange"); }
    void updateScrollCorner() final { TraceLine(m_trace, 'C', "updateScrollCorner"); }
    bool isVerticalDocument() const final { return m_config.verticalDocument; }
    bool isFlippedDocument() const final { return m_config.flippedDocument; }
    void unobscuredContentSizeChanged() final { TraceLine(m_trace, 'C', "unobscuredContentSizeChanged"); }
    void didFinishProhibitingScrollingWhenChangingContentSize() final { TraceLine(m_trace, 'C', "didFinishProhibitingScrollingWhenChangingContentSize"); }
    void updateLayerPositionsAfterScrolling() final { TraceLine(m_trace, 'C', "updateLayerPositionsAfterScrolling"); }
    void updateCompositingLayersAfterScrolling() final { TraceLine(m_trace, 'C', "updateCompositingLayersAfterScrolling"); }

    bool scrollContentsFastPath(const IntSize& delta, const IntRect& rectToScroll, const IntRect& clipRect) final
    {
        TraceLine(m_trace, 'C', "scrollContentsFastPath").isz(delta).irect(rectToScroll).irect(clipRect);
        return m_config.scrollContentsFastPathSucceeds;
    }

    bool shouldDeferScrollUpdateAfterContentSizeChange() final
    {
        TraceLine(m_trace, 'C', "shouldDeferScrollUpdateAfterContentSizeChange");
        return m_config.defersScrollUpdateAfterContentSizeChange;
    }

    void scrollOffsetChangedViaPlatformWidgetImpl(const ScrollOffset& oldOffset, const ScrollOffset& newOffset) final
    {
        TraceLine(m_trace, 'C', "scrollOffsetChangedViaPlatformWidgetImpl").ipt(oldOffset).ipt(newOffset);
    }

    float visibleContentScaleFactor() const final { return m_config.visibleContentScaleFactor; }
    FloatBoxExtent obscuredContentInsets(InsetType) const final { return m_config.obscuredContentInsets; }

    CornerRadii scrollbarAvoidanceCornerRadii() const final
    {
        TraceLine(m_trace, 'C', "scrollbarAvoidanceCornerRadii");
        return ScrollView::scrollbarAvoidanceCornerRadii();
    }

    Ref<Scrollbar> createScrollbar(ScrollbarOrientation orientation) final
    {
        TraceLine(m_trace, 'C', "createScrollbar").u(static_cast<uint8_t>(orientation));
        return ScrollView::createScrollbar(orientation);
    }

    void setScrollPosition(const ScrollPosition& position, const ScrollPositionChangeOptions& options) final
    {
        TraceLine(m_trace, 'C', "setScrollPosition").ipt(position).u(static_cast<uint8_t>(options.type)).u(static_cast<uint8_t>(options.clamping));
        ScrollView::setScrollPosition(position, options);
    }

    void scrollTo(const ScrollPosition& position) final
    {
        TraceLine(m_trace, 'C', "scrollTo").ipt(position);
        ReentryScope scope(*this);
        ScrollView::scrollTo(position);
        reenterAt(ReentryPoint::ScrollTo);
    }

    void setContentsSize(const IntSize& size) final
    {
        TraceLine(m_trace, 'C', "setContentsSize").isz(size);
        ScrollView::setContentsSize(size);
    }

    // ScrollableArea
    bool isActive() const final { return true; }
    bool forceUpdateScrollbarsOnMainThreadForPerformanceTesting() const final { return false; }
    ScrollableArea* enclosingScrollableArea() const final { return nullptr; }
    bool isScrollableOrRubberbandable() final { return true; }
    bool hasScrollableOrRubberbandableAncestor() final { return false; }
    IntRect scrollableAreaBoundingBox(bool* = nullptr) const final { return frameRect(); }
    bool shouldPlaceVerticalScrollbarOnLeft() const final { return m_config.placesVerticalScrollbarOnLeft; }
    String debugDescription() const final { return "RecordingScrollView"_s; }
    int headerHeight() const final { return m_config.headerHeight; }
    int footerHeight() const final { return m_config.footerHeight; }
    int insetForLeftScrollbarSpace() const final { return m_config.insetForLeftScrollbarSpace; }
    IntSize totalScrollbarSpace() const final { return m_config.totalScrollbarSpace; }
    bool isRubberBandInProgress() const final { return m_config.rubberBandInProgress; }
    bool canShowNonOverlayScrollbars() const final { return m_config.canShowNonOverlayScrollbars; }

    WebCore::Style::ScrollbarGutter scrollbarGutterStyle() const final
    {
        switch (m_config.gutter) {
        case Gutter::Auto:
            break;
        case Gutter::Stable:
            return { CSS::Keyword::Stable { } };
        case Gutter::StableBothEdges:
            return { CSS::Keyword::Stable { }, CSS::Keyword::BothEdges { } };
        }
        return { CSS::Keyword::Auto { } };
    }

    void invalidateScrollbarRect(Scrollbar& scrollbar, const IntRect& rect) final
    {
        TraceLine(m_trace, 'C', "invalidateScrollbarRect").u(static_cast<uint8_t>(scrollbar.orientation())).irect(rect);
    }

    bool requestScrollToPosition(const ScrollPosition& position, const ScrollPositionChangeOptions& options) final
    {
        TraceLine(m_trace, 'C', "requestScrollToPosition").ipt(position).u(static_cast<uint8_t>(options.type));
        return m_config.requestScrollToPositionHandles;
    }

    // Lays the contents out at the width now available to them, from the reflow table.
    void updateContentsSize() final
    {
        TraceLine(m_trace, 'C', "updateContentsSize").isz(visibleSize());
        ReentryScope scope(*this);
        if (!m_config.reflow.empty()) {
            int width = visibleSize().width();
            auto size = m_config.reflow.back().contentsSize;
            for (auto& row : m_config.reflow) {
                if (width >= row.minimumWidth) {
                    size = row.contentsSize;
                    break;
                }
            }
            if (size != contentsSize())
                ScrollView::setContentsSize(size);
        }
        reenterAt(ReentryPoint::UpdateContentsSize);
    }

    void availableContentSizeChanged(AvailableSizeChangeReason reason) final
    {
        TraceLine(m_trace, 'C', "availableContentSizeChanged").b(reason == AvailableSizeChangeReason::AreaSizeChanged);
        ReentryScope scope(*this);
        ScrollView::availableContentSizeChanged(reason);
        reenterAt(ReentryPoint::AvailableContentSizeChanged);
    }

    void didAddScrollbar(Scrollbar* scrollbar, ScrollbarOrientation orientation) final
    {
        TraceLine(m_trace, 'C', "didAddScrollbar").u(static_cast<uint8_t>(orientation));
        ScrollView::didAddScrollbar(scrollbar, orientation);
        ReentryScope scope(*this);
        reenterAt(ReentryPoint::DidAddScrollbar);
    }

    void willRemoveScrollbar(Scrollbar& scrollbar, ScrollbarOrientation orientation) final
    {
        TraceLine(m_trace, 'C', "willRemoveScrollbar").u(static_cast<uint8_t>(orientation));
        ReentryScope scope(*this);
        reenterAt(ReentryPoint::WillRemoveScrollbar);
        ScrollView::willRemoveScrollbar(scrollbar, orientation);
    }

    // Widget
    void invalidateRect(const IntRect& rect) final { TraceLine(m_trace, 'C', "invalidateRect").irect(rect); }

private:
    RecordingScrollView(Trace& trace, const ScriptedConfig& config, HostWindow* hostWindow)
        : m_trace(trace)
        , m_config(config)
        , m_hostWindow(hostWindow)
    {
    }

    class ReentryScope {
    public:
        explicit ReentryScope(RecordingScrollView& view)
            : m_view(view)
        {
            m_view.m_maximumReentryDepth = std::max(m_view.m_maximumReentryDepth, ++m_view.m_reentryDepth);
        }
        ~ReentryScope() { --m_view.m_reentryDepth; }

    private:
        RecordingScrollView& m_view;
    };

    void reenterAt(ReentryPoint point)
    {
        if (m_config.reentryPoint != point || m_reentering)
            return;
        ++m_reentryCalls;
        if (m_config.reentryAtCall && m_reentryCalls != m_config.reentryAtCall)
            return;
        TraceLine(m_trace, 'C', "reentry").u(static_cast<uint8_t>(point)).u(static_cast<uint8_t>(m_config.reentryAction));
        SetForScope reentering(m_reentering, true);
        switch (m_config.reentryAction) {
        case ReentryAction::None:
            break;
        case ReentryAction::SetContentsSize:
            ScrollView::setContentsSize(m_config.reentryContentsSize);
            break;
        case ReentryAction::ScrollbarModesAlwaysOff:
            setScrollbarModes(ScrollbarMode::AlwaysOff, ScrollbarMode::AlwaysOff);
            break;
        case ReentryAction::SuppressScrollbars:
            setScrollbarsSuppressed(true);
            break;
        case ReentryAction::UpdateScrollbars:
            updateScrollbars(scrollPosition());
            break;
        case ReentryAction::ScrollTo:
            ScrollView::scrollTo(m_config.reentryScrollPosition);
            break;
        }
    }

    Trace& m_trace;
    ScriptedConfig m_config;
    HostWindow* m_hostWindow;
    unsigned m_reentryCalls { 0 };
    unsigned m_reentryDepth { 0 };
    unsigned m_maximumReentryDepth { 0 };
    bool m_reentering { false };
};

} // namespace ScrollViewTesting
} // namespace TestWebKitAPI
