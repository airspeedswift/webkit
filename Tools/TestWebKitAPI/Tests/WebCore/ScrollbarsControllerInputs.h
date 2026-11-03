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

// Deterministic sessions on a ScrollView with native scrollbars, through the members of its ScrollbarsController
// that WebKit calls: mouse notifications for the content area and the scrollbars, content-area scrolls during and
// outside wheel events, paints, live resize, scroll gestures, scroller style and width changes, and scrollbars
// added and removed. The view records what its controller asks of it, and each session digests that and the
// scrollbar state WebKit reports. ScrollbarsControllerBench.mm uses the shapes.

#include "ScrollViewInputs.h"
#include <AppKit/AppKit.h>
#include <CoreFoundation/CoreFoundation.h>
#include <WebCore/ScrollbarsController.h>
#include <mutex>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>

namespace TestWebKitAPI {
namespace ScrollbarsControllerTesting {

using namespace WebCore;
using ScrollViewTesting::Lcg;
using ScrollViewTesting::RecordingHostWindow;
using ScrollViewTesting::ScrollbarStyleScope;
using ScrollViewTesting::Trace;
using ScrollViewTesting::TraceLine;

// MARK: - Run loop

// Runs the main thread's timers (WebCore's timers among them) in a run loop mode of its own, until none is due
// within a millisecond. A timer that is due can take a few passes of the run loop to fire, so this keeps passing
// until it has. AppKit's own timers run in the default mode and do not fire here. Without a window, AppKit starts
// no scrollbar animation, so a session reaches the controller and the NSScrollerImpPair and NSScrollerImp calls it
// makes, but never the scrollbar delegates' animation callbacks.
inline void runScrollbarTasks()
{
    static CFStringRef const mode = CFSTR("TestWebKitAPIScrollbarsControllerTasks");
    static std::once_flag once;
    std::call_once(once, [] {
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), mode);
    });
    auto deadline = CFAbsoluteTimeGetCurrent() + 0.1;
    while (true) {
        CFRunLoopRunInMode(mode, 0, true);
        auto now = CFAbsoluteTimeGetCurrent();
        auto next = CFRunLoopGetNextTimerFireDate(CFRunLoopGetMain(), mode);
        if (!next || next > now + 0.001 || now > deadline)
            return;
    }
}

// MARK: - Recording scroll view

// A ScrollView whose scrollbars are native, answering its controller's questions from fields a session sets, and
// recording each call the controller makes on it.
class ScrollbarsTestView final : public ScrollView {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(ScrollbarsTestView);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(ScrollbarsTestView);
public:
    static Ref<ScrollbarsTestView> create(Trace& trace, HostWindow* hostWindow) { return adoptRef(*new ScrollbarsTestView(trace, hostWindow)); }

    using ScrollView::setHasHorizontalScrollbar;
    using ScrollView::setHasVerticalScrollbar;

    IntPoint mousePosition;
    ScrollbarWidth widthStyle { ScrollbarWidth::Auto };
    bool handlingWheelEvent { false };
    bool suspendsScrollAnimations { true };
    bool darkAppearance { false };
    // Whether lastKnownMousePositionInView() is recorded: AppKit asks for it when it decides to.
    bool recordsMouseQueries { false };

    // ScrollableArea, the members ScrollbarsControllerMac uses.
    IntPoint lastKnownMousePositionInView() const final
    {
        if (recordsMouseQueries)
            TraceLine(m_trace, 'C', "lastKnownMousePositionInView");
        return mousePosition;
    }

    bool isHandlingWheelEvent() const final { return handlingWheelEvent; }
    bool shouldSuspendScrollAnimations() const final { return suspendsScrollAnimations; }
    bool useDarkAppearance() const final { return darkAppearance; }
    ScrollbarWidth scrollbarWidthStyle() const final { return widthStyle; }
    void setVisibleScrollerThumbRect(const IntRect& rect) final { TraceLine(m_trace, 'C', "setVisibleScrollerThumbRect").irect(rect); }

    void scrollbarStyleChanged(ScrollbarStyle style, bool forceUpdate) final
    {
        TraceLine(m_trace, 'C', "scrollbarStyleChanged").u(static_cast<uint8_t>(style)).b(forceUpdate);
        ScrollView::scrollbarStyleChanged(style, forceUpdate);
    }

    void invalidateScrollbarRect(Scrollbar& scrollbar, const IntRect& rect) final
    {
        TraceLine(m_trace, 'C', "invalidateScrollbarRect").u(static_cast<uint8_t>(scrollbar.orientation())).irect(rect);
    }

    // ScrollView
    HostWindow* hostWindow() const final { return m_hostWindow; }
    IntRect windowClipRect() const final { return contentsToWindow(visibleContentRect(LegacyIOSDocumentVisibleRect)); }
    void paintContents(GraphicsContext&, const IntRect&, SecurityOriginPaintPolicy, RegionContext*) final { }
    void addedOrRemovedScrollbar() final { TraceLine(m_trace, 'C', "addedOrRemovedScrollbar"); }
    void delegatedScrollingModeDidChange() final { }
    void updateScrollCorner() final { }
    bool isVerticalDocument() const final { return true; }
    bool isFlippedDocument() const final { return false; }
    void unobscuredContentSizeChanged() final { }
    void didFinishProhibitingScrollingWhenChangingContentSize() final { }
    void updateLayerPositionsAfterScrolling() final { }
    void updateCompositingLayersAfterScrolling() final { }
    bool scrollContentsFastPath(const IntSize&, const IntRect&, const IntRect&) final { return true; }
    bool shouldDeferScrollUpdateAfterContentSizeChange() final { return false; }
    void scrollOffsetChangedViaPlatformWidgetImpl(const ScrollOffset&, const ScrollOffset&) final { }
    float visibleContentScaleFactor() const final { return 1; }
    FloatBoxExtent obscuredContentInsets(InsetType) const final { return { 0.f, 0.f, 0.f, 0.f }; }
    void updateContentsSize() final { }

    // ScrollableArea
    bool isActive() const final { return true; }
    bool forceUpdateScrollbarsOnMainThreadForPerformanceTesting() const final { return false; }
    ScrollableArea* enclosingScrollableArea() const final { return nullptr; }
    bool isScrollableOrRubberbandable() final { return true; }
    bool hasScrollableOrRubberbandableAncestor() final { return false; }
    IntRect scrollableAreaBoundingBox(bool* = nullptr) const final { return frameRect(); }
    bool shouldPlaceVerticalScrollbarOnLeft() const final { return false; }
    String debugDescription() const final { return "ScrollbarsTestView"_s; }
    bool requestScrollToPosition(const ScrollPosition&, const ScrollPositionChangeOptions&) final { return false; }

    // Widget
    void invalidateRect(const IntRect&) final { }

private:
    ScrollbarsTestView(Trace& trace, HostWindow* hostWindow)
        : m_trace(trace)
        , m_hostWindow(hostWindow)
    {
    }

    Trace& m_trace;
    HostWindow* m_hostWindow;
};

// MARK: - Session

// The scrollbar state without the parts AppKit decides from time and the pointing devices (expanded,
// visible_track, visible_thumb).
inline String webKitScrollbarState(const String& state)
{
    StringBuilder result;
    for (auto token : StringView(state).split(',')) {
        if (token == "expanded"_s || token == "visible_track"_s || token == "visible_thumb"_s)
            continue;
        if (!result.isEmpty())
            result.append(',');
        result.append(token);
    }
    return result.toString();
}

// AppKit decides the system's recommended scroller style once a process makes its first scrollers, and then tells
// every scroller pair, which would change the style of a session's scrollbars partway through. A first session,
// run once per process with AppleShowScrollBars pinned, lets that happen before any shape runs.
inline void settleRecommendedScrollerStyle();

class ScrollbarsSession {
public:
    explicit ScrollbarsSession(Trace& trace, bool overlayScrollbars)
        : m_trace(trace)
        , m_style(overlayScrollbars)
        , m_hostWindow(trace)
        , m_view(ScrollbarsTestView::create(trace, &m_hostWindow))
    {
        m_view->setFrameRect({ 0, 0, 800, 600 });
        m_view->setContentsSize({ 2400, 9000 });
        m_view->setHasVerticalScrollbar(true);
        m_view->setHasHorizontalScrollbar(true);
    }

    ~ScrollbarsSession()
    {
        m_view->setHasVerticalScrollbar(false);
        m_view->setHasHorizontalScrollbar(false);
        runScrollbarTasks();
    }

    ScrollbarsTestView& view() { return m_view.get(); }
    ScrollbarsController& controller() { return m_view->scrollbarsController(); }
    Trace& trace() { return m_trace; }
    uint64_t entries() const { return m_entries; }

    Scrollbar* scrollbar(bool vertical) { return vertical ? m_view->verticalScrollbar() : m_view->horizontalScrollbar(); }

    // Counts one call into the controller.
    void entry() { ++m_entries; }

    void observe()
    {
        for (bool vertical : { true, false }) {
            auto state = webKitScrollbarState(vertical ? m_view->verticalScrollbarStateForTesting() : m_view->horizontalScrollbarStateForTesting()).utf8();
            TraceLine(m_trace, 'S', vertical ? "vertical" : "horizontal").u(state.length());
            m_trace.bytes(state.data(), state.length());
            auto* bar = scrollbar(vertical);
            TraceLine(m_trace, 'S', "frame").irect(bar ? bar->frameRect() : IntRect { -1, -1, 0, 0 });
        }
        TraceLine(m_trace, 'R', "scrollbarsCanBeActive").b(controller().scrollbarsCanBeActive());
    }

private:
    Trace& m_trace;
    ScrollbarStyleScope m_style;
    RecordingHostWindow m_hostWindow;
    Ref<ScrollbarsTestView> m_view;
    uint64_t m_entries { 0 };
};

// MARK: - Shapes
//
// Each shape is one session with overlay scrollbars and one with legacy scrollbars, each on a new view.

using ScrollbarsShape = void (*)(ScrollbarsSession&);

// Entering the content area, moving in it, leaving it.
inline void mouseMovesOverContentShape(ScrollbarsSession& session)
{
    auto& view = session.view();
    Lcg random(21);
    for (unsigned visit = 0; visit < 2000; ++visit) {
        view.mousePosition = { random.range(0, 799), random.range(0, 599) };
        view.mouseEnteredContentArea();
        session.entry();
        unsigned moves = random.range(1, 32);
        for (unsigned i = 0; i < moves; ++i) {
            view.mousePosition = { random.range(-20, 820), random.range(-20, 620) };
            view.mouseMovedInContentArea();
            session.entry();
        }
        view.mouseExitedContentArea();
        session.entry();
        if (!(visit % 128))
            session.observe();
    }
    session.observe();
}

// Entering each scrollbar, moving over it with hit testing at each move, pressing and releasing in it, leaving it.
// AppKit starts a timer for each time the mouse enters or leaves a legacy scroller, and removing many at once
// takes time quadratic in their number, so with legacy scrollbars only some visits enter and leave.
inline void mouseMovesOverScrollbarsShape(ScrollbarsSession& session)
{
    auto& view = session.view();
    auto& controller = session.controller();
    bool legacy = ScrollerStyle::recommendedScrollerStyle() == NSScrollerStyleLegacy;
    Lcg random(22);
    for (unsigned visit = 0; visit < 300; ++visit) {
        bool vertical = random.chance(60);
        bool entersAndLeaves = !legacy || !(visit % 128);
        auto* scrollbar = session.scrollbar(vertical);
        view.mousePosition = vertical ? IntPoint { random.range(785, 799), random.range(0, 599) } : IntPoint { random.range(0, 799), random.range(585, 599) };
        if (entersAndLeaves) {
            view.mouseEnteredScrollbar(scrollbar);
            session.entry();
        }
        unsigned moves = random.range(1, 16);
        unsigned participating = 0;
        for (unsigned i = 0; i < moves; ++i) {
            participating += controller.shouldScrollbarParticipateInHitTesting(scrollbar);
            session.entry();
            if (random.chance(15)) {
                controller.mouseIsDownInScrollbar(scrollbar, true);
                controller.mouseIsDownInScrollbar(scrollbar, false);
                session.entry();
                session.entry();
            }
        }
        TraceLine(session.trace(), 'R', "participating").u(participating);
        if (entersAndLeaves) {
            controller.mouseExitedScrollbar(scrollbar);
            session.entry();
        }
        if (!(visit % 16))
            session.observe();
    }
    session.observe();
}

// Content-area scrolls while WebKit handles a wheel event: sent to AppKit at once.
inline void contentAreaScrolledDuringWheelShape(ScrollbarsSession& session)
{
    auto& view = session.view();
    auto& controller = session.controller();
    Lcg random(23);
    view.handlingWheelEvent = true;
    for (unsigned i = 0; i < 1000; ++i) {
        float sign = random.chance(50) ? -1 : 1;
        controller.notifyContentAreaScrolled({ random.chance(20) ? sign * random.range(1, 120) : 0.f, sign * random.range(1, 120) });
        session.entry();
        if (!(i % 256))
            session.observe();
    }
    view.handlingWheelEvent = false;
    session.observe();
}

// Content-area scrolls outside wheel events: bursts sent after a zero-delay timer, which keeps the last delta.
inline void contentAreaScrolledSoonShape(ScrollbarsSession& session)
{
    auto& controller = session.controller();
    Lcg random(24);
    for (unsigned burst = 0; burst < 400; ++burst) {
        unsigned count = random.range(1, 8);
        for (unsigned i = 0; i < count; ++i) {
            controller.notifyContentAreaScrolled({ 0, static_cast<float>(random.range(-60, 60)) });
            session.entry();
        }
        runScrollbarTasks();
        if (!(burst % 32))
            session.observe();
    }
    session.observe();
}

// A frame is a content-area scroll and a paint.
inline void contentAreaWillPaintFrames(ScrollbarsSession& session, unsigned seed, unsigned frames)
{
    auto& view = session.view();
    auto& controller = session.controller();
    Lcg random(seed);
    view.handlingWheelEvent = true;
    for (unsigned frame = 0; frame < frames; ++frame) {
        controller.notifyContentAreaScrolled({ 0, static_cast<float>(random.range(-40, 40)) });
        view.contentAreaWillPaint();
        session.entry();
        session.entry();
        if (!(frame % 1024))
            session.observe();
    }
    view.handlingWheelEvent = false;
    session.observe();
}

inline void contentAreaWillPaintShape(ScrollbarsSession& session)
{
    contentAreaWillPaintFrames(session, 25, 1000);
}

// The same frames with the overlay scrollbar state locked hidden, as for a page in the back/forward cache.
inline void contentAreaWillPaintLockedShape(ScrollbarsSession& session)
{
    auto& controller = session.controller();
    controller.lockOverlayScrollbarStateToHidden(true);
    TraceLine(session.trace(), 'R', "scrollbarsCanBeActive").b(controller.scrollbarsCanBeActive());
    contentAreaWillPaintFrames(session, 26, 30000);
    controller.lockOverlayScrollbarStateToHidden(false);
    TraceLine(session.trace(), 'R', "scrollbarsCanBeActive").b(controller.scrollbarsCanBeActive());
}

// Live resizes: a start, contents-size changes, an end.
inline void liveResizeShape(ScrollbarsSession& session)
{
    auto& view = session.view();
    Lcg random(27);
    for (unsigned resize = 0; resize < 300; ++resize) {
        view.willStartLiveResize();
        session.entry();
        unsigned steps = random.range(1, 16);
        for (unsigned i = 0; i < steps; ++i) {
            view.contentsResized();
            session.entry();
        }
        view.willEndLiveResize();
        session.entry();
        if (!(resize % 32))
            session.observe();
    }
    session.observe();
}

// Scroller style updates with the recommended style alternating, some while the overlay state is locked, which
// defers the update to the unlock.
inline void scrollerStyleChangeShape(ScrollbarsSession& session)
{
    auto& controller = session.controller();
    Lcg random(28);
    bool overlay = ScrollerStyle::recommendedScrollerStyle() == NSScrollerStyleOverlay;
    for (unsigned change = 0; change < 300; ++change) {
        overlay = random.chance(70) ? !overlay : overlay;
        ScrollerStyle::setUseOverlayScrollbars(overlay);
        bool locked = random.chance(25);
        if (locked)
            controller.lockOverlayScrollbarStateToHidden(true);
        controller.updateScrollerStyle();
        session.entry();
        if (locked) {
            controller.lockOverlayScrollbarStateToHidden(false);
            session.entry();
        }
        if (!(change % 8))
            session.observe();
    }
    session.observe();
}

// Scrollbar width changes, alternating auto and thin.
inline void scrollbarWidthChangeShape(ScrollbarsSession& session)
{
    auto& view = session.view();
    auto& controller = session.controller();
    Lcg random(29);
    for (unsigned change = 0; change < 600; ++change) {
        view.widthStyle = random.chance(60) ? (view.widthStyle == ScrollbarWidth::Auto ? ScrollbarWidth::Thin : ScrollbarWidth::Auto) : view.widthStyle;
        controller.scrollbarWidthChanged(view.widthStyle);
        session.entry();
        if (!(change % 8))
            session.observe();
    }
    session.observe();
    view.widthStyle = ScrollbarWidth::Auto;
    controller.scrollbarWidthChanged(ScrollbarWidth::Auto);
}

// Scroll gestures as the scroll animator reports them: may-begin, begin, content scrolls, end, and cancelled
// animations.
inline void scrollGesturesShape(ScrollbarsSession& session)
{
    auto& view = session.view();
    auto& controller = session.controller();
    Lcg random(30);
    for (unsigned gesture = 0; gesture < 300; ++gesture) {
        if (random.chance(80)) {
            controller.mayBeginScrollGesture();
            session.entry();
        }
        controller.didBeginScrollGesture();
        session.entry();
        view.handlingWheelEvent = true;
        unsigned scrolls = random.range(0, 4);
        for (unsigned i = 0; i < scrolls; ++i) {
            controller.notifyContentAreaScrolled({ 0, static_cast<float>(random.range(-30, 30)) });
            session.entry();
        }
        view.handlingWheelEvent = false;
        controller.didEndScrollGesture();
        session.entry();
        if (random.chance(30)) {
            controller.cancelAnimations();
            session.entry();
        }
        if (!(gesture % 64))
            session.observe();
    }
    session.observe();
}

// Scrollbars removed and added again, as when a document's overflow changes, with the content area shown and
// hidden, scrollbar layers changed and part layers invalidated between.
inline void scrollbarChurnShape(ScrollbarsSession& session)
{
    auto& view = session.view();
    auto& controller = session.controller();
    Lcg random(31);
    for (unsigned round = 0; round < 1500; ++round) {
        bool vertical = random.chance(50);
        if (vertical)
            view.setHasVerticalScrollbar(false);
        else
            view.setHasHorizontalScrollbar(false);
        session.entry();
        if (random.chance(30)) {
            controller.contentAreaDidHide();
            controller.contentAreaDidShow();
            session.entry();
            session.entry();
        }
        if (vertical)
            view.setHasVerticalScrollbar(true);
        else
            view.setHasHorizontalScrollbar(true);
        session.entry();
        if (vertical)
            controller.verticalScrollbarLayerDidChange();
        else
            controller.horizontalScrollbarLayerDidChange();
        controller.invalidateScrollbarPartLayers(session.scrollbar(vertical));
        session.entry();
        session.entry();
        if (!(round % 128))
            session.observe();
    }
    session.observe();
}

// MARK: - Running a shape

inline void settleRecommendedScrollerStyle()
{
    static std::once_flag once;
    std::call_once(once, [] {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        RetainPtr arguments = adoptNS([[defaults volatileDomainForName:NSArgumentDomain] mutableCopy] ?: [[NSMutableDictionary alloc] init]);
        [arguments setObject:@"WhenScrolling" forKey:@"AppleShowScrollBars"];
        [defaults setVolatileDomain:arguments.get() forName:NSArgumentDomain];
        @autoreleasepool {
            Trace trace;
            ScrollbarsSession session(trace, true);
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.6, false);
    });
}

// One pass of a shape, with overlay then legacy scrollbars, on the main thread: its digest and how many calls into
// the controller it made.
inline std::pair<uint64_t, uint64_t> runScrollbarsShape(ScrollbarsShape shape)
{
    settleRecommendedScrollerStyle();
    Trace trace;
    uint64_t entries = 0;
    for (bool overlay : { true, false }) @autoreleasepool {
        ScrollbarsSession session(trace, overlay);
        shape(session);
        session.observe();
        entries += session.entries();
    }
    TraceLine(trace, 'R', "entries").u(entries);
    return { trace.digest(), entries };
}

} // namespace ScrollbarsControllerTesting
} // namespace TestWebKitAPI
