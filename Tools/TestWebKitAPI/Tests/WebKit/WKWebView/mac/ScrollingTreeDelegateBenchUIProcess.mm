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

#import "config.h"

#if PLATFORM(MAC)

#import "Helpers/PlatformUtilities.h"
#import "Helpers/Test.h"
#import "Helpers/cocoa/TestWKWebView.h"
#import <WebKit/WKWebViewPrivate.h>
#import <array>
#import <cstdlib>
#import <string>
#import <wtf/MonotonicTime.h>
#import <wtf/RetainPtr.h>

// The UI process's wheel-event entry: wheel events sent to a WKWebView reach RemoteLayerTreeEventDispatcher (every
// Mac WKWebView uses RemoteLayerTreeDrawingAreaProxyMac), which hands them to the remote scrolling tree on the
// scrolling thread, and, for momentum-phase events, to its MomentumEventDispatcher first. One test per shape, in the
// ScrollingTreeDelegateBench suite with the tree's own shapes. With WEBKIT_RUN_BENCHMARKS=1 each test repeats its
// pass and prints <Shape>: <ms> ms <rate> MB/s checksum=<hex>, where the rate is thousands of wheel events per
// second. The time includes the web process's work for each event; this process's cycle counts do not.
//
// The checksum holds only what does not depend on timing. How far a gesture scrolls does: the predominant-axis filter
// and the momentum path read event times, and a rubber band's animation, the latch timeout and event coalescing all
// run in real time. So the drive keeps every scroller well inside its range (no rubber band, and #b never comes under
// a target point), sends vertical deltas only, waits out the latch timeout after each gesture, and the checksum is an
// FNV-1a hash of the event count and, per gesture, the direction (-1, 0, +1) each scroller moved. Each pass checks it
// against the model the drive implies: each gesture moves the scroller it began over, in its direction, and no other.
// Every wait is bounded (stepTimeout, passTimeout): a step that does not complete fails the test instead of hanging it.
//
// What this does not reach: the momentum dispatcher's synthesized momentum (its offset table, tail and the events it
// dispatches on display refresh). It starts only for an event whose CGEvent carries an IOHIDEvent (rawPlatformDelta),
// and CGEventCreateScrollWheelEvent's do not, so RemoteMomentumSequence measures the dispatcher's per-event path and
// the tree's handling of platform momentum events.

namespace TestWebKitAPI {

static NSString *const scrollersMarkup = @""
    "<style>"
    "body { margin: 0; height: 9000px; }"
    ".scroller { position: absolute; width: 400px; height: 300px; overflow: scroll; }"
    ".tall { height: 4000px; }"
    "</style>"
    "<div id='a' class='scroller' style='position: fixed; left: 0; top: 0;'><div class='tall'></div>"
    "<div id='b' class='scroller' style='left: 20px; top: 1000px; width: 300px; height: 200px;'><div class='tall'></div></div></div>"
    "<div id='c' class='scroller' style='position: fixed; left: 420px; top: 0;'><div class='tall'></div></div>";

// #a and #c are fixed, so they stay under their target points while the page scrolls.
// Each pass starts from these positions, mid-range: the page's range is 8400, #a's and #c's 3700. #b lies under
// targets[0] only while #a's scrollTop is within about [900, 1100]. A pass moves one scroller at most 3 x 400 pixels
// (RemoteMomentumSequence: 15 x 12 gesture + 10 x 20 momentum, per gesture), so #a stays within [1250, 3650].
static NSString *const resetScript = @"window.scrollTo(0, 4200); a.scrollTop = 2450; b.scrollTop = 0; c.scrollTop = 1850; true";

static NSString *const positionsScript = @"[window.scrollY, a.scrollTop, b.scrollTop, c.scrollTop,"
    " (window.scrollY < 0 || window.scrollY > document.documentElement.scrollHeight - innerHeight"
    " || [a, b, c].some(e => e.scrollTop < 0 || e.scrollTop > e.scrollHeight - e.clientHeight)) ? 1 : 0].join(',')";

static constexpr auto noScrollPhase = static_cast<CGScrollPhase>(0);
static constexpr Seconds stepTimeout = 10_s;
static constexpr Seconds passTimeout = 120_s;
static constexpr Seconds latchTimeout = 150_ms; // The scrolling tree's is 100 ms after the latched scroller's last event.

// Points over #a, #c and the page outside both, in the web view's coordinates, and the index in positionsScript's
// result of the scroller under each.
static constexpr CGPoint targets[] = { { 100, 100 }, { 600, 100 }, { 300, 500 } };
static constexpr unsigned targetScroller[] = { 1, 3, 0 };
static constexpr unsigned scrollerCount = 4;

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

    int range(int low, int high) { return low + static_cast<int>(next() % static_cast<uint32_t>(high - low + 1)); }

private:
    uint64_t m_state;
};

struct Fnv {
    uint64_t value { 14695981039346656037ull };

    void hash(int64_t word)
    {
        for (unsigned i = 0; i < 8; ++i) {
            value ^= static_cast<uint8_t>(word >> (8 * i));
            value *= 1099511628211ull;
        }
    }
};

using Positions = std::array<int64_t, scrollerCount>;

static std::string describe(const Positions& positions)
{
    std::string result;
    for (auto position : positions)
        result += (result.empty() ? "" : ",") + std::to_string(position);
    return result;
}

struct Pass {
    Fnv checksum;
    Fnv expected;
    uint64_t events { 0 };
    Positions positions { };
    MonotonicTime deadline { MonotonicTime::now() + passTimeout };
    const char* failure { nullptr };
    std::string trace; // Per gesture: target, sign, settled positions. Printed when a pass fails.

    bool ok()
    {
        if (!failure && MonotonicTime::now() > deadline)
            failure = "pass took longer than passTimeout";
        return !failure;
    }
};

static bool presentationUpdate(TestWKWebView *webView)
{
    __block bool done = false;
    [webView _doAfterNextPresentationUpdate:^{
        done = true;
    }];
    return Util::runFor(&done, stepTimeout);
}

// nil when the script fails or does not complete within stepTimeout.
static RetainPtr<NSString> evaluate(TestWKWebView *webView, NSString *script)
{
    __block bool done = false;
    __block RetainPtr<NSString> result;
    [webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
        if (!error && value)
            result = [NSString stringWithFormat:@"%@", value];
        done = true;
    }];
    if (!Util::runFor(&done, stepTimeout))
        return nil;
    return result;
}

// Reads the scroll positions once they hold across two rendering updates with no scroller outside its range, and
// still hold after the latch timeout, so the next gesture latches to the scroller it begins over.
static bool readSettledPositions(TestWKWebView *webView, Pass& pass, Positions& positions)
{
    RetainPtr<NSString> last;
    for (unsigned attempt = 0; attempt < 200 && pass.ok(); ++attempt) {
        if (!presentationUpdate(webView)) {
            pass.failure = "no presentation update within stepTimeout";
            return false;
        }
        RetainPtr current = evaluate(webView, positionsScript);
        if (!current) {
            pass.failure = "reading scroll positions did not complete within stepTimeout";
            return false;
        }
        bool settled = last && [current isEqualToString:last.get()] && [current hasSuffix:@",0"];
        last = current;
        if (!settled)
            continue;
        Util::runFor(latchTimeout);
        RetainPtr confirmed = evaluate(webView, positionsScript);
        if (!confirmed || ![confirmed isEqualToString:last.get()]) {
            last = confirmed;
            continue;
        }
        NSArray<NSString *> *values = [last componentsSeparatedByString:@","];
        for (unsigned i = 0; i < scrollerCount; ++i)
            positions[i] = values[i].integerValue;
        return true;
    }
    if (!pass.failure)
        pass.failure = "scroll positions did not settle";
    return false;
}

static void begin(TestWKWebView *webView, Pass& pass)
{
    if (!evaluate(webView, resetScript)) {
        pass.failure = "resetting scroll positions did not complete within stepTimeout";
        return;
    }
    if (readSettledPositions(webView, pass, pass.positions))
        pass.trace = "start " + describe(pass.positions);
}

// Hashes the direction each scroller moved since the last gesture, and the direction the model expects: the
// scroller under the gesture's point moves down for a negative delta and up for a positive one, and no other moves.
static void settle(TestWKWebView *webView, Pass& pass, unsigned target, int sign)
{
    Positions now;
    if (!pass.ok() || !readSettledPositions(webView, pass, now))
        return;
    for (unsigned i = 0; i < scrollerCount; ++i) {
        int64_t moved = now[i] - pass.positions[i];
        pass.checksum.hash((moved > 0) - (moved < 0));
        pass.expected.hash(i == targetScroller[target] ? -sign : 0);
    }
    pass.positions = now;
    pass.trace += " [" + std::to_string(target) + (sign > 0 ? "+ " : "- ") + describe(now) + "]";
}

static void send(TestWKWebView *webView, Pass& pass, CGPoint point, int deltaY, CGScrollPhase phase, CGMomentumScrollPhase momentumPhase)
{
    [webView wheelEventAtPoint:[webView convertPoint:point toView:nil] wheelDelta:CGSizeMake(0, deltaY) phase:phase momentumPhase:momentumPhase];
    ++pass.events;
}

// Trackpad gestures, no momentum: MayBegin, Began, Changed..., Ended over each target in turn. Latching keeps each
// gesture on the scroller it began over.
static void remoteWheelEventPass(TestWKWebView *webView, Pass& pass)
{
    begin(webView, pass);
    Lcg random(21);
    for (unsigned gesture = 0; gesture < 12 && pass.ok(); ++gesture) {
        unsigned target = gesture % 3;
        CGPoint point = targets[target];
        int sign = gesture % 4 == 3 ? 1 : -1;
        unsigned count = random.range(10, 30);
        send(webView, pass, point, 0, kCGScrollPhaseMayBegin, kCGMomentumScrollPhaseNone);
        for (unsigned event = 0; event < count; ++event)
            send(webView, pass, point, sign * random.range(2, 12), event ? kCGScrollPhaseChanged : kCGScrollPhaseBegan, kCGMomentumScrollPhaseNone);
        send(webView, pass, point, 0, kCGScrollPhaseEnded, kCGMomentumScrollPhaseNone);
        settle(webView, pass, target, sign);
    }
}

// Gestures followed by a platform momentum phase (momentum Begin, Continue..., End), which the UI process gives to
// MomentumEventDispatcher before the tree.
static void remoteMomentumSequencePass(TestWKWebView *webView, Pass& pass)
{
    begin(webView, pass);
    Lcg random(22);
    for (unsigned gesture = 0; gesture < 9 && pass.ok(); ++gesture) {
        unsigned target = gesture % 3;
        CGPoint point = targets[target];
        int sign = gesture % 3 == 2 ? 1 : -1;
        unsigned count = random.range(5, 15);
        for (unsigned event = 0; event < count; ++event)
            send(webView, pass, point, sign * random.range(4, 12), event ? kCGScrollPhaseChanged : kCGScrollPhaseBegan, kCGMomentumScrollPhaseNone);
        send(webView, pass, point, 0, kCGScrollPhaseEnded, kCGMomentumScrollPhaseNone);
        int delta = random.range(10, 20);
        unsigned momentumCount = random.range(15, 40);
        for (unsigned event = 0; event < momentumCount; ++event) {
            send(webView, pass, point, sign * delta, noScrollPhase, event ? kCGMomentumScrollPhaseContinue : kCGMomentumScrollPhaseBegin);
            delta = delta * 9 / 10;
        }
        send(webView, pass, point, 0, noScrollPhase, kCGMomentumScrollPhaseEnd);
        settle(webView, pass, target, sign);
    }
}

static RetainPtr<TestWKWebView> makeWebView()
{
    RetainPtr webView = adoptNS([[TestWKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)]);
    [webView loadHTMLString:scrollersMarkup baseURL:nil];
    bool loaded = Util::waitFor([&] {
        RetainPtr state = evaluate(webView.get(), @"document.readyState == 'complete' && !!window.c");
        return [state isEqualToString:@"1"];
    });
    if (!loaded || !presentationUpdate(webView.get()))
        return nil;
    return webView;
}

static bool runPass(void (*shape)(TestWKWebView *, Pass&), TestWKWebView *webView, Pass& pass)
{
    shape(webView, pass);
    if (pass.failure) {
        ADD_FAILURE() << pass.failure << " after " << pass.events << " events; " << pass.trace;
        return false;
    }
    pass.checksum.hash(pass.events);
    pass.expected.hash(pass.events);
    EXPECT_EQ(pass.checksum.value, pass.expected.value) << pass.trace;
    return pass.checksum.value == pass.expected.value;
}

static void runRemoteShape(void (*shape)(TestWKWebView *, Pass&), const char* name, unsigned fullPasses)
{
    auto webView = makeWebView();
    if (!webView) {
        ADD_FAILURE() << "the page did not load within the step timeouts";
        return;
    }
    Pass first;
    if (!runPass(shape, webView.get(), first))
        return;

    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    uint64_t totalEvents = 0;
    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < fullPasses; ++i) {
        Pass pass;
        if (!runPass(shape, webView.get(), pass))
            return;
        totalEvents += pass.events;
    }
    double milliseconds = (MonotonicTime::now() - start).milliseconds();
    printf("%s: %.1f ms %.2f MB/s checksum=%016llx\n", name, milliseconds, totalEvents / milliseconds, static_cast<unsigned long long>(first.checksum.value));
}

TEST(ScrollingTreeDelegateBench, RemoteWheelEvent)
{
    runRemoteShape(remoteWheelEventPass, "RemoteWheelEvent", 1);
}

TEST(ScrollingTreeDelegateBench, RemoteMomentumSequence)
{
    runRemoteShape(remoteMomentumSequencePass, "RemoteMomentumSequence", 1);
}

} // namespace TestWebKitAPI

#endif // PLATFORM(MAC)
