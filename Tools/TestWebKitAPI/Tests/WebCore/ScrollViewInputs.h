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

// Deterministic sessions on a stack of nested ScrollViews: geometry and contents-size changes, scrollbar modes,
// scrolls, and the conversions, rects and hit tests a document makes between them. Each step calls ScrollView's
// public members and records what they return. ScrollViewBench.cpp uses the shapes.

#include "ScrollViewTestClient.h"
#include <WebCore/NSScrollerImpDetails.h>
#include <WebCore/ScrollbarTheme.h>
#include <utility>
#include <wtf/Vector.h>

namespace TestWebKitAPI {
namespace ScrollViewTesting {

class Lcg {
public:
    explicit Lcg(uint64_t seed)
        : m_state(seed * 6364136223846793005ull + 1442695040888963407ull)
    {
    }

    uint32_t next()
    {
        m_state = m_state * 6364136223846793005ull + 1442695040888963407ull;
        return static_cast<uint32_t>(m_state >> 33);
    }

    // [0, 1)
    float unit() { return static_cast<float>(next() >> 8) / static_cast<float>(1 << 23); }
    // [low, high]
    int range(int low, int high) { return low + static_cast<int>(next() % static_cast<uint32_t>(high - low + 1)); }
    float between(float low, float high) { return low + (high - low) * unit(); }
    bool chance(unsigned percent) { return next() % 100 < percent; }

private:
    uint64_t m_state;
};

// MARK: - Steps

enum class Op : uint8_t {
    // Configuration and geometry.
    UseConfig, // configs[count]
    SetFrameRect, // r
    SetContentsSize, // s
    SetScrollbarModes, // mode: horizontal | vertical << 2 | horizontal lock << 4 | vertical lock << 5
    SetCanHaveScrollbars, // flag
    SetScrollbarsSuppressed, // flag, second: repaint on unsuppress
    SetScrollOrigin, // p, flag: update the position at all, second: synchronously
    SetHasHorizontalScrollbar, // flag
    SetHasVerticalScrollbar, // flag
    UpdateScrollbars, // p
    SetDelegatedScrollingMode, // mode
    SetExposedViewRect, // fr
    SetUnobscuredContentSize, // fr.size()
    SetCanBlitOnScroll, // flag
    AddPanScrollIcon, // p
    RemovePanScrollIcon,
    SetAllowsUnclamped, // flag
    SetProhibitsScrolling, // flag
    SetFixedLayout, // flag, s

    // Scrolls.
    SetScrollPosition, // p, mode: 0 programmatic, 1 user, 2 programmatic unclamped
    ScrollTo, // p
    SetScrollOffset, // p
    ScrollBy, // s
    HandleDeferredScrollUpdate,
    ScrollContents, // s
    ScrollOffsetChangedViaPlatformWidget, // p (old), s (new as a point)
    AdjustExposedContentRect, // p

    // Queries: each records what the members return.
    PointConversions, // p, fp, dp
    RectConversions, // r, fr
    RootViewConversions, // p, fp, dp, r, fr
    WindowConversions, // p, fp, dp, r, fr
    ChildConversions, // p, fp, dp, r (on the view and the one nested in it)
    VisibleRects,
    Overhang,
    HitTest, // p, mode: ScrollbarHitTestTolerance
    State,
};

// The codes naming each returned value in the trace, one per member and argument type.
enum class Ret : uint16_t {
    State = 1,
    ViewToContentsIntPoint,
    ContentsToViewIntPoint,
    ViewToContentsFloatPoint,
    ContentsToViewFloatPoint,
    ViewToContentsDoublePoint,
    ContentsToViewDoublePoint,
    ViewToContentsIntRect,
    ContentsToViewIntRect,
    ViewToContentsFloatRect,
    ContentsToViewFloatRect,
    ViewToContentsInsetOffset,
    RootViewToContentsIntPoint,
    ContentsToRootViewIntPoint,
    RootViewToContentsFloatPoint,
    ContentsToRootViewFloatPoint,
    RootViewToContentsDoublePoint,
    ContentsToRootViewDoublePoint,
    RootViewToContentsIntRect,
    ContentsToRootViewIntRect,
    RootViewToContentsFloatRect,
    ContentsToRootViewFloatRect,
    RootViewToContentsQuad,
    ContentsToRootViewQuad,
    RootViewToTotalContents,
    ContentsToContainingViewContentsIntPoint,
    ContentsToContainingViewContentsIntRect,
    WindowToContentsIntPoint,
    WindowToContentsFloatPoint,
    WindowToContentsDoublePoint,
    WindowToContentsIntRect,
    WindowToContentsFloatRect,
    ContentsToWindowIntPoint,
    ContentsToWindowFloatPoint,
    ContentsToWindowIntRect,
    ContentsToWindowFloatRect,
    ContentsToScreen,
    ScreenToContents,
    ConvertChildToSelfIntPoint,
    ConvertChildToSelfFloatPoint,
    ConvertChildToSelfDoublePoint,
    ConvertSelfToChildIntPoint,
    ConvertSelfToChildFloatPoint,
    ConvertSelfToChildDoublePoint,
    ScrollbarToContainingViewIntRect,
    ContainingViewToScrollbarIntRect,
    ScrollbarToContainingViewIntPoint,
    ContainingViewToScrollbarIntPoint,
    VisibleContentRect,
    VisibleContentRectIncludingScrollbars,
    UnobscuredContentRect,
    UnobscuredContentRectIncludingScrollbars,
    SizeForUnobscuredContent,
    SizeForVisibleContent,
    SizeForVisibleContentIncludingScrollbars,
    ExposedViewRect,
    LayoutSize,
    ScrollPositions,
    DocumentScrollPositions,
    TotalContentsSize,
    OverhangAmount,
    ScrollbarAtPoint,
    IsPointInScrollbarCorner,
    ScrollCornerRect,
    ManagesScrollbars,
    Last = ManagesScrollbars,
};

struct Step {
    Op op;
    uint8_t view { 0 };
    uint8_t mode { 0 };
    bool flag { false };
    bool second { false };
    unsigned count { 0 };
    IntPoint p;
    IntSize s;
    IntRect r;
    FloatPoint fp;
    FloatRect fr;
    DoublePoint dp;
};

struct Case {
    bool overlayScrollbars { false };
    bool hostWindow { true };
    // Views nested in one another, each a child of the one before; at least 1.
    unsigned depth { 1 };
    // configs[0] is every view's configuration at the start.
    std::vector<ScriptedConfig> configs { ScriptedConfig { } };
    std::vector<Step> steps;
};

inline Step step(Op op, uint8_t view = 0)
{
    Step result;
    result.op = op;
    result.view = view;
    return result;
}

inline Step useConfig(unsigned index, uint8_t view = 0)
{
    auto result = step(Op::UseConfig, view);
    result.count = index;
    return result;
}

inline Step frameRect(IntRect rect, uint8_t view = 0)
{
    auto result = step(Op::SetFrameRect, view);
    result.r = rect;
    return result;
}

inline Step contentsSize(IntSize size, uint8_t view = 0)
{
    auto result = step(Op::SetContentsSize, view);
    result.s = size;
    return result;
}

inline Step scrollbarModes(ScrollbarMode horizontal, ScrollbarMode vertical, bool horizontalLock = false, bool verticalLock = false, uint8_t view = 0)
{
    auto result = step(Op::SetScrollbarModes, view);
    result.mode = static_cast<uint8_t>(horizontal) | static_cast<uint8_t>(vertical) << 2 | horizontalLock << 4 | verticalLock << 5;
    return result;
}

inline Step flagStep(Op op, bool flag, uint8_t view = 0)
{
    auto result = step(op, view);
    result.flag = flag;
    return result;
}

inline Step scrollOrigin(IntPoint origin, bool updatePositionAtAll, bool updatePositionSynchronously, uint8_t view = 0)
{
    auto result = step(Op::SetScrollOrigin, view);
    result.p = origin;
    result.flag = updatePositionAtAll;
    result.second = updatePositionSynchronously;
    return result;
}

inline Step pointStep(Op op, IntPoint point, uint8_t view = 0)
{
    auto result = step(op, view);
    result.p = point;
    return result;
}

inline Step sizeStep(Op op, IntSize size, uint8_t view = 0)
{
    auto result = step(op, view);
    result.s = size;
    return result;
}

enum class PositionChange : uint8_t { Programmatic, User, ProgrammaticUnclamped };

inline Step scrollPosition(IntPoint position, PositionChange change = PositionChange::Programmatic, uint8_t view = 0)
{
    auto result = pointStep(Op::SetScrollPosition, position, view);
    result.mode = static_cast<uint8_t>(change);
    return result;
}

inline Step query(Op op, IntPoint p, FloatPoint fp, DoublePoint dp, IntRect r, FloatRect fr, uint8_t view = 0)
{
    auto result = step(op, view);
    result.p = p;
    result.fp = fp;
    result.dp = dp;
    result.r = r;
    result.fr = fr;
    return result;
}

inline Step hitTest(IntPoint point, ScrollbarHitTestTolerance tolerance, uint8_t view = 0)
{
    auto result = pointStep(Op::HitTest, point, view);
    result.mode = static_cast<uint8_t>(tolerance);
    return result;
}

// A random query input near the visible area, with sub-pixel values and values halfway between integers.
inline Step randomQuery(Lcg& random, Op op, IntSize extent, uint8_t view = 0)
{
    auto coordinate = [&](int limit) { return random.range(-limit / 4, limit + limit / 4); };
    auto fraction = [&] {
        static constexpr float fractions[] = { 0, 0.25f, 0.5f, 0.75f, 1.5f, -0.5f };
        return fractions[random.next() % std::size(fractions)];
    };
    IntPoint p { coordinate(extent.width()), coordinate(extent.height()) };
    FloatPoint fp { coordinate(extent.width()) + fraction(), coordinate(extent.height()) + fraction() };
    DoublePoint dp { coordinate(extent.width()) + fraction() / 3.0, coordinate(extent.height()) + fraction() / 7.0 };
    IntRect r { coordinate(extent.width()), coordinate(extent.height()), random.range(-8, extent.width() / 2), random.range(-8, extent.height() / 2) };
    FloatRect fr { coordinate(extent.width()) + fraction(), coordinate(extent.height()) + fraction(), random.range(0, extent.width() / 2) + fraction(), random.range(-4, extent.height() / 2) + fraction() };
    return query(op, p, fp, dp, r, fr, view);
}

// MARK: - Running a case

// Every case runs with the overlay or the legacy scrollbars it names, whatever the system prefers.
class ScrollbarStyleScope {
public:
    explicit ScrollbarStyleScope(bool overlayScrollbars)
        : m_previous(ScrollbarTheme::theme().usesOverlayScrollbars())
    {
        set(overlayScrollbars);
    }

    ~ScrollbarStyleScope() { set(m_previous); }

private:
    static void set(bool overlayScrollbars)
    {
        ScrollerStyle::setUseOverlayScrollbars(overlayScrollbars);
        ScrollbarTheme::theme().usesOverlayScrollbarsChanged();
    }

    bool m_previous;
};

inline uint8_t orientationCode(const ScrollView& view, const Scrollbar* scrollbar)
{
    if (!scrollbar)
        return 0;
    if (scrollbar == view.horizontalScrollbar())
        return 1;
    if (scrollbar == view.verticalScrollbar())
        return 2;
    return 3;
}

inline TraceLine ret(Trace& trace, Ret code)
{
    return TraceLine(trace, static_cast<uint16_t>(code));
}

inline void recordState(Trace& trace, ScrollView& view)
{
    auto* horizontal = view.horizontalScrollbar();
    auto* vertical = view.verticalScrollbar();
    ret(trace, Ret::State).ipt(view.scrollPosition()).isz(view.contentsSize()).ipt(view.scrollOrigin())
        .irect(horizontal ? horizontal->frameRect() : IntRect { -1, -1, 0, 0 })
        .irect(vertical ? vertical->frameRect() : IntRect { -1, -1, 0, 0 })
        .u(static_cast<uint8_t>(view.horizontalScrollbarMode()) | static_cast<uint8_t>(view.verticalScrollbarMode()) << 2 | view.scrollbarsSuppressed() << 4);
}

inline void runQuery(Trace& trace, const Step& step, RecordingScrollView& view, RecordingScrollView* child)
{
    switch (step.op) {
    case Op::PointConversions:
        ret(trace, Ret::ViewToContentsIntPoint).ipt(view.viewToContents(step.p));
        ret(trace, Ret::ContentsToViewIntPoint).ipt(view.contentsToView(step.p));
        ret(trace, Ret::ViewToContentsFloatPoint).pt(view.viewToContents(step.fp));
        ret(trace, Ret::ContentsToViewFloatPoint).pt(view.contentsToView(step.fp));
        ret(trace, Ret::ViewToContentsDoublePoint).dpt(view.viewToContents(step.dp));
        ret(trace, Ret::ContentsToViewDoublePoint).dpt(view.contentsToView(step.dp));
        return;
    case Op::RectConversions:
        ret(trace, Ret::ViewToContentsIntRect).irect(view.viewToContents(step.r));
        ret(trace, Ret::ContentsToViewIntRect).irect(view.contentsToView(step.r));
        ret(trace, Ret::ViewToContentsFloatRect).rect(view.viewToContents(step.fr));
        ret(trace, Ret::ContentsToViewFloatRect).rect(view.contentsToView(step.fr));
        ret(trace, Ret::ViewToContentsInsetOffset).isz(view.viewToContentsInsetOffset());
        return;
    case Op::RootViewConversions: {
        FloatQuad quad { step.fr };
        ret(trace, Ret::RootViewToContentsIntPoint).ipt(view.rootViewToContents(step.p));
        ret(trace, Ret::ContentsToRootViewIntPoint).ipt(view.contentsToRootView(step.p));
        ret(trace, Ret::RootViewToContentsFloatPoint).pt(view.rootViewToContents(step.fp));
        ret(trace, Ret::ContentsToRootViewFloatPoint).pt(view.contentsToRootView(step.fp));
        ret(trace, Ret::RootViewToContentsDoublePoint).dpt(view.rootViewToContents(step.dp));
        ret(trace, Ret::ContentsToRootViewDoublePoint).dpt(view.contentsToRootView(step.dp));
        ret(trace, Ret::RootViewToContentsIntRect).irect(view.rootViewToContents(step.r));
        ret(trace, Ret::ContentsToRootViewIntRect).irect(view.contentsToRootView(step.r));
        ret(trace, Ret::RootViewToContentsFloatRect).rect(view.rootViewToContents(step.fr));
        ret(trace, Ret::ContentsToRootViewFloatRect).rect(view.contentsToRootView(step.fr));
        ret(trace, Ret::RootViewToContentsQuad).quad(view.rootViewToContents(quad));
        ret(trace, Ret::ContentsToRootViewQuad).quad(view.contentsToRootView(quad));
        ret(trace, Ret::RootViewToTotalContents).ipt(view.rootViewToTotalContents(step.p));
        ret(trace, Ret::ContentsToContainingViewContentsIntPoint).ipt(view.contentsToContainingViewContents(step.p));
        ret(trace, Ret::ContentsToContainingViewContentsIntRect).irect(view.contentsToContainingViewContents(step.r));
        return;
    }
    case Op::WindowConversions:
        ret(trace, Ret::WindowToContentsIntPoint).ipt(view.windowToContents(step.p));
        ret(trace, Ret::WindowToContentsFloatPoint).pt(view.windowToContents(step.fp));
        ret(trace, Ret::WindowToContentsDoublePoint).dpt(view.windowToContents(step.dp));
        ret(trace, Ret::WindowToContentsIntRect).irect(view.windowToContents(step.r));
        ret(trace, Ret::WindowToContentsFloatRect).rect(view.windowToContents(step.fr));
        ret(trace, Ret::ContentsToWindowIntPoint).ipt(view.contentsToWindow(step.p));
        ret(trace, Ret::ContentsToWindowFloatPoint).pt(view.contentsToWindow(step.fp));
        ret(trace, Ret::ContentsToWindowIntRect).irect(view.contentsToWindow(step.r));
        ret(trace, Ret::ContentsToWindowFloatRect).rect(view.contentsToWindow(step.fr));
        ret(trace, Ret::ContentsToScreen).irect(view.contentsToScreen(step.r));
        ret(trace, Ret::ScreenToContents).ipt(view.screenToContents(step.p));
        return;
    case Op::ChildConversions:
        if (child) {
            ret(trace, Ret::ConvertChildToSelfIntPoint).ipt(view.convertChildToSelf(child, step.p));
            ret(trace, Ret::ConvertChildToSelfFloatPoint).pt(view.convertChildToSelf(child, step.fp));
            ret(trace, Ret::ConvertChildToSelfDoublePoint).dpt(view.convertChildToSelf(child, step.dp));
            ret(trace, Ret::ConvertSelfToChildIntPoint).ipt(view.convertSelfToChild(child, step.p));
            ret(trace, Ret::ConvertSelfToChildFloatPoint).pt(view.convertSelfToChild(child, step.fp));
            ret(trace, Ret::ConvertSelfToChildDoublePoint).dpt(view.convertSelfToChild(child, step.dp));
        }
        for (auto* scrollbar : { view.horizontalScrollbar(), view.verticalScrollbar() }) {
            if (!scrollbar)
                continue;
            ret(trace, Ret::ScrollbarToContainingViewIntRect).irect(view.convertFromScrollbarToContainingView(*scrollbar, step.r));
            ret(trace, Ret::ContainingViewToScrollbarIntRect).irect(view.convertFromContainingViewToScrollbar(*scrollbar, step.r));
            ret(trace, Ret::ScrollbarToContainingViewIntPoint).ipt(view.convertFromScrollbarToContainingView(*scrollbar, step.p));
            ret(trace, Ret::ContainingViewToScrollbarIntPoint).ipt(view.convertFromContainingViewToScrollbar(*scrollbar, step.p));
        }
        return;
    case Op::VisibleRects:
        ret(trace, Ret::VisibleContentRect).irect(view.visibleContentRect(ScrollableArea::LegacyIOSDocumentVisibleRect));
        ret(trace, Ret::VisibleContentRectIncludingScrollbars).irect(view.visibleContentRectIncludingScrollbars());
        ret(trace, Ret::UnobscuredContentRect).irect(view.unobscuredContentRect());
        ret(trace, Ret::UnobscuredContentRectIncludingScrollbars).irect(view.unobscuredContentRect(ScrollableArea::VisibleContentRectIncludesScrollbars::Yes));
        ret(trace, Ret::SizeForUnobscuredContent).isz(view.sizeForUnobscuredContent());
        ret(trace, Ret::SizeForVisibleContent).isz(view.sizeForVisibleContent());
        ret(trace, Ret::SizeForVisibleContentIncludingScrollbars).isz(view.sizeForVisibleContent(ScrollableArea::VisibleContentRectIncludesScrollbars::Yes));
        ret(trace, Ret::ExposedViewRect).rect(view.exposedViewRect().raw());
        ret(trace, Ret::LayoutSize).isz(view.layoutSize());
        ret(trace, Ret::ScrollPositions).ipt(view.scrollPosition()).ipt(view.minimumScrollPosition()).ipt(view.maximumScrollPosition()).ipt(view.contentsScrollPosition());
        ret(trace, Ret::DocumentScrollPositions).ipt(view.documentScrollPositionRelativeToViewOrigin()).ipt(view.documentScrollPositionRelativeToScrollableAreaOrigin());
        ret(trace, Ret::TotalContentsSize).isz(view.totalContentsSize()).isz(view.visibleSize());
        ret(trace, Ret::ManagesScrollbars).b(view.managesScrollbars());
        return;
    case Op::Overhang:
        ret(trace, Ret::OverhangAmount).isz(view.overhangAmount());
        return;
    case Op::HitTest: {
        auto tolerance = static_cast<ScrollbarHitTestTolerance>(step.mode);
        ret(trace, Ret::ScrollbarAtPoint).u(orientationCode(view, view.scrollbarAtPoint(step.p, tolerance)));
        ret(trace, Ret::IsPointInScrollbarCorner).b(view.isPointInScrollbarCorner(step.p)).b(view.scrollbarCornerPresent());
        ret(trace, Ret::ScrollCornerRect).irect(view.scrollCornerRect());
        return;
    }
    case Op::State:
        recordState(trace, view);
        return;
    default:
        return;
    }
}

inline void runStep(Trace& trace, const Case& testCase, const Step& step, Vector<Ref<RecordingScrollView>>& views)
{
    auto& view = views[step.view].get();
    auto* child = step.view + 1u < views.size() ? views[step.view + 1].ptr() : nullptr;
    switch (step.op) {
    case Op::UseConfig:
        view.config() = testCase.configs[step.count];
        return;
    case Op::SetFrameRect:
        view.setFrameRect(step.r);
        break;
    case Op::SetContentsSize:
        view.setContentsSize(step.s);
        break;
    case Op::SetScrollbarModes:
        view.setScrollbarModes(static_cast<ScrollbarMode>(step.mode & 3), static_cast<ScrollbarMode>((step.mode >> 2) & 3), step.mode & 0x10, step.mode & 0x20);
        break;
    case Op::SetCanHaveScrollbars:
        view.setCanHaveScrollbars(step.flag);
        break;
    case Op::SetScrollbarsSuppressed:
        view.setScrollbarsSuppressed(step.flag, step.second);
        break;
    case Op::SetScrollOrigin:
        view.setScrollOrigin(step.p, step.flag, step.second);
        break;
    case Op::SetHasHorizontalScrollbar: {
        bool contentSizeAffected = false;
        bool changed = view.setHasHorizontalScrollbar(step.flag, &contentSizeAffected);
        ret(trace, Ret::State).b(changed).b(contentSizeAffected);
        break;
    }
    case Op::SetHasVerticalScrollbar: {
        bool contentSizeAffected = false;
        bool changed = view.setHasVerticalScrollbar(step.flag, &contentSizeAffected);
        ret(trace, Ret::State).b(changed).b(contentSizeAffected);
        break;
    }
    case Op::UpdateScrollbars:
        view.updateScrollbars(step.p);
        break;
    case Op::SetDelegatedScrollingMode:
        view.setDelegatedScrollingMode(static_cast<DelegatedScrollingMode>(step.mode));
        break;
    case Op::SetExposedViewRect:
        view.setExposedViewRect(ViewFloatRect { step.fr });
        break;
    case Op::SetUnobscuredContentSize:
        view.setUnobscuredContentSize(step.fr.size());
        break;
    case Op::SetCanBlitOnScroll:
        view.setCanBlitOnScroll(step.flag);
        return;
    case Op::AddPanScrollIcon:
        view.addPanScrollIcon(step.p);
        return;
    case Op::RemovePanScrollIcon:
        view.removePanScrollIcon();
        return;
    case Op::SetAllowsUnclamped:
        view.setAllowsUnclampedScrollPositionForTesting(step.flag);
        return;
    case Op::SetProhibitsScrolling:
        view.setProhibitsScrolling(step.flag);
        return;
    case Op::SetFixedLayout:
        view.setFixedLayoutSize(step.s);
        view.setUseFixedLayout(step.flag);
        break;
    case Op::SetScrollPosition:
        switch (static_cast<PositionChange>(step.mode)) {
        case PositionChange::Programmatic:
            view.setScrollPosition(step.p, ScrollPositionChangeOptions::createProgrammatic());
            break;
        case PositionChange::User:
            view.setScrollPosition(step.p, ScrollPositionChangeOptions::createUser());
            break;
        case PositionChange::ProgrammaticUnclamped:
            view.setScrollPosition(step.p, ScrollPositionChangeOptions::createProgrammaticUnclamped());
            break;
        }
        break;
    case Op::ScrollTo:
        view.scrollTo(step.p);
        break;
    case Op::SetScrollOffset:
        view.setScrollOffset(step.p);
        break;
    case Op::ScrollBy:
        view.scrollBy(step.s);
        break;
    case Op::HandleDeferredScrollUpdate:
        view.handleDeferredScrollUpdateAfterContentSizeChange();
        break;
    case Op::ScrollContents:
        view.scrollContents(step.s);
        break;
    case Op::ScrollOffsetChangedViaPlatformWidget:
        view.scrollOffsetChangedViaPlatformWidget(step.p, IntPoint { step.s });
        break;
    case Op::AdjustExposedContentRect:
        view.adjustExposedContentRectForProgrammaticScroll(step.p);
        break;
    default:
        runQuery(trace, step, view, child);
        return;
    }
    recordState(trace, view);
}

inline void runCase(Trace& trace, const Case& testCase)
{
    ScrollbarStyleScope style(testCase.overlayScrollbars);
    RecordingHostWindow hostWindow(trace);
    auto* host = testCase.hostWindow ? &hostWindow : nullptr;
    Vector<Ref<RecordingScrollView>> views;
    views.append(RecordingScrollView::create(trace, testCase.configs[0], host));
    for (unsigned i = 1; i < testCase.depth; ++i) {
        auto child = RecordingScrollView::create(trace, testCase.configs[0], host);
        views.last()->addChild(child.get());
        views.append(WTF::move(child));
    }
    for (auto& step : testCase.steps)
        runStep(trace, testCase, step, views);
    unsigned maximumReentryDepth = 0;
    for (auto& view : views)
        maximumReentryDepth = std::max(maximumReentryDepth, view->maximumReentryDepth());
    TraceLine(trace, 'C', "maximumReentryDepth").u(maximumReentryDepth);
    for (size_t i = views.size(); i-- > 1;)
        views[i - 1]->removeChild(views[i].get());
}

inline uint64_t runCases(Trace& trace, const std::vector<Case>& cases)
{
    for (auto& testCase : cases)
        runCase(trace, testCase);
    return trace.digest();
}

// MARK: - Shapes

inline IntRect benchFrame()
{
    return { 0, 0, 1024, 768 };
}

inline ScriptedConfig scaledConfig(float scale, FloatBoxExtent insets, int headerHeight, int insetForLeftScrollbarSpace = 0)
{
    ScriptedConfig config;
    config.visibleContentScaleFactor = scale;
    config.obscuredContentInsets = insets;
    config.headerHeight = headerHeight;
    config.insetForLeftScrollbarSpace = insetForLeftScrollbarSpace;
    return config;
}

// The page scales, insets and headers a document sees.
inline std::vector<ScriptedConfig> conversionConfigs()
{
    return {
        scaledConfig(1, { 0.f, 0.f, 0.f, 0.f }, 0),
        scaledConfig(2, { 0.f, 0.f, 0.f, 0.f }, 0),
        scaledConfig(0.5f, { 10.25f, 0.f, 0.f, 0.f }, 0),
        scaledConfig(1, { 37.5f, 0.f, 0.f, 15.f }, 30),
        scaledConfig(1.25f, { 52.f, 0.f, 0.f, 0.f }, 0, 15),
    };
}

inline std::vector<Step> documentSetup(IntRect frame, IntSize contents, uint8_t view = 0)
{
    return { frameRect(frame, view), contentsSize(contents, view) };
}

inline std::vector<Case> conversionsShape(Op op, uint64_t seed)
{
    Case testCase;
    testCase.configs = conversionConfigs();
    testCase.steps = documentSetup(benchFrame(), { 4000, 12000 });
    Lcg random(seed);
    for (unsigned config = 0; config < testCase.configs.size(); ++config) {
        testCase.steps.push_back(useConfig(config));
        for (unsigned position = 0; position < 8; ++position) {
            testCase.steps.push_back(scrollPosition({ random.range(0, 3000), random.range(0, 11300) }));
            for (unsigned query = 0; query < 250; ++query)
                testCase.steps.push_back(randomQuery(random, op, benchFrame().size()));
        }
    }
    return { testCase };
}

inline std::vector<Case> pointConversionsShape()
{
    return conversionsShape(Op::PointConversions, 1);
}

inline std::vector<Case> rectConversionsShape()
{
    return conversionsShape(Op::RectConversions, 2);
}

// A document with three nested frames, each scrolled, converting between the innermost frames and the root view.
inline std::vector<Case> rootViewChainShape()
{
    Case testCase;
    testCase.depth = 4;
    testCase.steps = documentSetup(benchFrame(), { 2000, 8000 });
    const IntRect childFrames[] = { { 40, 120, 800, 600 }, { 25, 60, 600, 400 }, { 10, 30, 400, 300 } };
    for (uint8_t view = 1; view < 4; ++view) {
        for (auto& setupStep : documentSetup(childFrames[view - 1], { 1200 + 300 * view, 3000 }, view))
            testCase.steps.push_back(setupStep);
    }
    Lcg random(3);
    for (unsigned round = 0; round < 16; ++round) {
        for (uint8_t view = 0; view < 4; ++view)
            testCase.steps.push_back(scrollPosition({ random.range(0, 600), random.range(0, 2500) }, PositionChange::Programmatic, view));
        for (unsigned query = 0; query < 60; ++query) {
            uint8_t view = static_cast<uint8_t>(random.range(1, 3));
            auto op = query % 3 ? Op::RootViewConversions : (query % 2 ? Op::WindowConversions : Op::ChildConversions);
            if (op == Op::ChildConversions)
                view = static_cast<uint8_t>(random.range(0, 2));
            testCase.steps.push_back(randomQuery(random, op, childFrames[2].size(), view));
        }
    }
    return { testCase };
}

inline std::vector<Case> visibleRectQueriesShape()
{
    std::vector<Case> cases;
    for (bool overlay : { false, true }) {
        Case testCase;
        testCase.overlayScrollbars = overlay;
        testCase.configs = conversionConfigs();
        for (auto gutter : { Gutter::Stable, Gutter::StableBothEdges }) {
            auto config = scaledConfig(1, { 20.f, 0.f, 0.f, 0.f }, 0);
            config.gutter = gutter;
            testCase.configs.push_back(config);
        }
        testCase.steps = documentSetup(benchFrame(), { 3000, 9000 });
        Lcg random(overlay ? 5 : 4);
        for (unsigned config = 0; config < testCase.configs.size(); ++config) {
            testCase.steps.push_back(useConfig(config));
            for (unsigned position = 0; position < 40; ++position) {
                testCase.steps.push_back(scrollPosition({ random.range(0, 2500), random.range(0, 8500) }));
                for (unsigned query = 0; query < 8; ++query)
                    testCase.steps.push_back(step(Op::VisibleRects));
            }
        }
        // Delegated geometry.
        auto delegated = step(Op::SetDelegatedScrollingMode);
        delegated.mode = static_cast<uint8_t>(DelegatedScrollingMode::DelegatedToNativeScrollView);
        testCase.steps.push_back(delegated);
        for (unsigned round = 0; round < 40; ++round) {
            auto exposed = step(Op::SetExposedViewRect);
            exposed.fr = { random.between(0, 50), random.between(0, 80), random.between(200, 1024), random.between(200, 768) };
            testCase.steps.push_back(exposed);
            auto unobscured = step(Op::SetUnobscuredContentSize);
            unobscured.fr = { 0, 0, random.between(300, 1024), random.between(300, 768) };
            testCase.steps.push_back(unobscured);
            for (unsigned query = 0; query < 8; ++query)
                testCase.steps.push_back(step(Op::VisibleRects));
        }
        auto notDelegated = step(Op::SetDelegatedScrollingMode);
        notDelegated.mode = static_cast<uint8_t>(DelegatedScrollingMode::NotDelegated);
        testCase.steps.push_back(notDelegated);
        cases.push_back(WTF::move(testCase));
    }
    return cases;
}

// Contents-size changes that keep both scrollbars: the contents stay larger than the view in both directions.
inline std::vector<Case> contentSizeNoChangeShape()
{
    Case testCase;
    testCase.steps = documentSetup(benchFrame(), { 3000, 9000 });
    Lcg random(6);
    for (unsigned change = 0; change < 1500; ++change)
        testCase.steps.push_back(contentsSize({ random.range(1500, 5000), random.range(2000, 20000) }));
    return { testCase };
}

// Reflow tables: the contents' size at each available width, so that a scrollbar that appears or disappears
// changes the contents, as text that rewraps does.
inline ScriptedConfig reflowConfig(std::vector<ReflowRow> reflow)
{
    ScriptedConfig config;
    config.reflow = WTF::move(reflow);
    return config;
}

inline std::vector<ScriptedConfig> reflowConfigs()
{
    int width = benchFrame().width();
    int height = benchFrame().height();
    return {
        // Fits without scrollbars.
        reflowConfig({ { 0, { width - 100, height - 100 } } }),
        // Needs a vertical scrollbar.
        reflowConfig({ { 0, { width - 100, 4 * height } } }),
        // Needs both.
        reflowConfig({ { 0, { 2 * width, 4 * height } } }),
        // Taller only when the vertical scrollbar takes width: passes until the pass limit.
        reflowConfig({ { width, { width, height } }, { 0, { width - 30, height + 10 } } }),
        // Wider only without the vertical scrollbar, which then needs a horizontal one.
        reflowConfig({ { width, { width + 10, height - 5 } }, { 0, { width - 40, height + 40 } } }),
        // Shrinks when a scrollbar appears, so that it is no longer needed.
        reflowConfig({ { width, { width, height + 200 } }, { 0, { width - 20, height - 50 } } }),
    };
}

inline std::vector<Case> contentSizeToggleShape()
{
    std::vector<Case> cases;
    for (bool overlay : { false, true }) {
        Case testCase;
        testCase.overlayScrollbars = overlay;
        testCase.configs = reflowConfigs();
        testCase.steps = documentSetup(benchFrame(), { 500, 500 });
        Lcg random(overlay ? 8 : 7);
        static constexpr IntPoint origins[] = { { 0, 0 }, { -200, 0 }, { 0, -300 } };
        for (unsigned round = 0; round < 60; ++round) {
            testCase.steps.push_back(scrollOrigin(origins[round % 3], true, round % 2));
            for (unsigned config = 0; config < testCase.configs.size(); ++config) {
                testCase.steps.push_back(useConfig(config));
                int width = benchFrame().width() + random.range(-60, 60);
                int height = benchFrame().height() + random.range(-60, 60);
                testCase.steps.push_back(frameRect({ 0, 0, width, height }));
                testCase.steps.push_back(contentsSize({ random.range(width - 50, width + 50), random.range(height - 50, height + 50) }));
                testCase.steps.push_back(pointStep(Op::UpdateScrollbars, { random.range(0, 100), random.range(0, 100) }));
            }
            testCase.steps.push_back(flagStep(Op::SetHasHorizontalScrollbar, round % 2));
            testCase.steps.push_back(flagStep(Op::SetHasVerticalScrollbar, !(round % 3)));
            testCase.steps.push_back(pointStep(Op::UpdateScrollbars, { 0, 0 }));
        }
        cases.push_back(WTF::move(testCase));
    }
    return cases;
}

// Line and page scrolls, clamped and not, and scrolls deferred while the contents size changes.
inline std::vector<Case> scrollToStreamShape()
{
    Case testCase;
    testCase.hostWindow = false;
    auto deferring = ScriptedConfig { };
    deferring.defersScrollUpdateAfterContentSizeChange = true;
    testCase.configs.push_back(deferring);
    testCase.steps = documentSetup(benchFrame(), { 3000, 30000 });
    Lcg random(9);
    IntPoint position;
    for (unsigned round = 0; round < 40; ++round) {
        for (unsigned line = 0; line < 40; ++line) {
            position.move(0, 1 + (line % 3) * 40);
            testCase.steps.push_back(scrollPosition(position, line % 2 ? PositionChange::User : PositionChange::Programmatic));
        }
        for (unsigned page = 0; page < 10; ++page) {
            position = { random.range(-100, 2200), random.range(-100, 30000) };
            testCase.steps.push_back(scrollPosition(position, page % 3 == 2 ? PositionChange::ProgrammaticUnclamped : PositionChange::Programmatic));
            testCase.steps.push_back(pointStep(Op::ScrollTo, { random.range(0, 1900), random.range(0, 29000) }));
            testCase.steps.push_back(pointStep(Op::SetScrollOffset, { random.range(0, 1900), random.range(0, 29000) }));
            testCase.steps.push_back(sizeStep(Op::ScrollBy, { random.range(-40, 40), random.range(-400, 400) }));
        }
        // A scroll deferred during a contents-size change, delivered afterwards.
        testCase.steps.push_back(useConfig(1));
        for (unsigned deferred = 0; deferred < 4; ++deferred)
            testCase.steps.push_back(pointStep(Op::ScrollTo, { random.range(0, 1900), random.range(0, 29000) }));
        testCase.steps.push_back(useConfig(0));
        testCase.steps.push_back(step(Op::HandleDeferredScrollUpdate));
        if (round % 8 == 7) {
            testCase.steps.push_back(flagStep(Op::SetProhibitsScrolling, true));
            testCase.steps.push_back(scrollPosition({ 10, 10 }));
            testCase.steps.push_back(flagStep(Op::SetProhibitsScrolling, false));
        }
        position = { };
    }
    return { testCase };
}

// Scrolls that blit or repaint through the host window, with the pan scroll icon and without.
inline std::vector<Case> scrollContentsShape()
{
    std::vector<Case> cases;
    for (bool overlay : { false, true }) {
        Case testCase;
        testCase.overlayScrollbars = overlay;
        auto slowPath = ScriptedConfig { };
        slowPath.scrollContentsFastPathSucceeds = false;
        testCase.configs.push_back(slowPath);
        testCase.steps = documentSetup(benchFrame(), { 3000, 20000 });
        Lcg random(overlay ? 11 : 10);
        for (unsigned round = 0; round < 24; ++round) {
            testCase.steps.push_back(useConfig(round % 2));
            testCase.steps.push_back(flagStep(Op::SetCanBlitOnScroll, round % 3));
            if (round % 4 == 3)
                testCase.steps.push_back(pointStep(Op::AddPanScrollIcon, { random.range(0, 1000), random.range(0, 700) }));
            for (unsigned scroll = 0; scroll < 30; ++scroll)
                testCase.steps.push_back(scrollPosition({ random.range(0, 2000), random.range(0, 19000) }));
            for (unsigned delta = 0; delta < 10; ++delta)
                testCase.steps.push_back(sizeStep(Op::ScrollContents, { random.range(-50, 50), random.range(-500, 500) }));
            testCase.steps.push_back(step(Op::RemovePanScrollIcon));
        }
        cases.push_back(WTF::move(testCase));
    }
    return cases;
}

// Positions past each edge, as rubber-banding leaves them.
inline std::vector<Case> overhangShape()
{
    Case testCase;
    testCase.steps = documentSetup(benchFrame(), { 2000, 6000 });
    testCase.steps.push_back(flagStep(Op::SetAllowsUnclamped, true));
    Lcg random(12);
    for (unsigned round = 0; round < 300; ++round) {
        int maximumX = 2000 - benchFrame().width() + 15;
        int maximumY = 6000 - benchFrame().height() + 15;
        IntPoint position {
            round % 4 == 0 ? random.range(-120, 0) : round % 4 == 1 ? random.range(maximumX - 5, maximumX + 120) : random.range(0, maximumX),
            round % 3 == 0 ? random.range(-120, 0) : round % 3 == 1 ? random.range(maximumY - 5, maximumY + 120) : random.range(0, maximumY),
        };
        testCase.steps.push_back(pointStep(Op::ScrollTo, position));
        for (unsigned query = 0; query < 4; ++query)
            testCase.steps.push_back(step(Op::Overhang));
    }
    // No contents height.
    testCase.steps.push_back(contentsSize({ 2000, 0 }));
    for (unsigned round = 0; round < 20; ++round) {
        testCase.steps.push_back(pointStep(Op::ScrollTo, { random.range(-50, 1200), random.range(-50, 50) }));
        testCase.steps.push_back(step(Op::Overhang));
    }
    return { testCase };
}

// Points on and around both scrollbars and the corner, each edge included.
inline std::vector<Case> hitTestShape()
{
    std::vector<Case> cases;
    for (bool overlay : { false, true }) {
        Case testCase;
        testCase.overlayScrollbars = overlay;
        testCase.steps = documentSetup(benchFrame(), { 3000, 9000 });
        testCase.steps.push_back(scrollbarModes(ScrollbarMode::AlwaysOn, ScrollbarMode::AlwaysOn));
        for (int y = benchFrame().height() - 40; y <= benchFrame().height() + 2; y += 2) {
            for (int x = 0; x <= benchFrame().width() + 2; x += 16) {
                testCase.steps.push_back(hitTest({ x, y }, ScrollbarHitTestTolerance::None));
                testCase.steps.push_back(hitTest({ x, y }, ScrollbarHitTestTolerance::Expanded));
            }
        }
        for (int x = benchFrame().width() - 40; x <= benchFrame().width() + 2; x += 2) {
            for (int y = 0; y <= benchFrame().height() + 2; y += 16) {
                testCase.steps.push_back(hitTest({ x, y }, ScrollbarHitTestTolerance::None));
                testCase.steps.push_back(hitTest({ x, y }, ScrollbarHitTestTolerance::Expanded));
            }
        }
        // Only one scrollbar.
        testCase.steps.push_back(scrollbarModes(ScrollbarMode::AlwaysOff, ScrollbarMode::AlwaysOn));
        for (int x = benchFrame().width() - 30; x <= benchFrame().width(); ++x)
            testCase.steps.push_back(hitTest({ x, benchFrame().height() - 5 }, ScrollbarHitTestTolerance::Expanded));
        cases.push_back(WTF::move(testCase));
    }
    return cases;
}

// Mode, lock and suppression changes, many of which change nothing.
inline std::vector<Case> scrollbarModesShape()
{
    Case testCase;
    testCase.steps = documentSetup(benchFrame(), { 3000, 9000 });
    Lcg random(13);
    static constexpr ScrollbarMode modes[] = { ScrollbarMode::Auto, ScrollbarMode::AlwaysOff, ScrollbarMode::AlwaysOn };
    static constexpr IntPoint origins[] = { { 0, 0 }, { -200, 0 }, { 0, -300 } };
    for (unsigned round = 0; round < 500; ++round) {
        switch (random.next() % 6) {
        case 0:
        case 1:
            testCase.steps.push_back(scrollbarModes(modes[random.next() % 3], modes[random.next() % 3], random.chance(20), random.chance(20)));
            break;
        case 2:
            testCase.steps.push_back(flagStep(Op::SetCanHaveScrollbars, random.chance(70)));
            break;
        case 3: {
            auto suppress = flagStep(Op::SetScrollbarsSuppressed, random.chance(50));
            suppress.second = random.chance(50);
            testCase.steps.push_back(suppress);
            break;
        }
        case 4:
            testCase.steps.push_back(scrollOrigin(origins[random.next() % 3], random.chance(80), random.chance(50)));
            break;
        case 5:
            testCase.steps.push_back(contentsSize({ random.range(500, 3000), random.range(500, 9000) }));
            break;
        }
    }
    return { testCase };
}

} // namespace ScrollViewTesting
} // namespace TestWebKitAPI
