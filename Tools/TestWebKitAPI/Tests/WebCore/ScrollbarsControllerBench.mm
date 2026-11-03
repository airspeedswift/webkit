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

#import "ScrollbarsControllerInputs.h"
#import <cstdlib>
#import <wtf/MonotonicTime.h>

// Sessions on a ScrollView with native scrollbars, through the ScrollbarsController members WebKit calls: one test
// per shape. Each test runs one pass, with overlay then legacy scrollbars, and checks its checksum, a hash of every
// call the controller makes on the view, the members' return values, and the scrollbar state and frames WebKit
// reports. With WEBKIT_RUN_BENCHMARKS=1 it runs the pass about a second's worth of times and prints
// `<Shape>: <ms> ms <rate> MB/s checksum=<hex>`, where the rate is thousands of calls into the controller per second.

namespace TestWebKitAPI {

using namespace ScrollbarsControllerTesting;

static void runScrollbarsControllerShape(ScrollbarsShape shape, const char* name, unsigned fullPasses, uint64_t expectedChecksum)
{
    auto [checksum, entries] = runScrollbarsShape(shape);
    EXPECT_EQ(checksum, expectedChecksum);

    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    uint64_t totalEntries = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < fullPasses; ++pass) {
        auto [passChecksum, passEntries] = runScrollbarsShape(shape);
        EXPECT_EQ(passChecksum, checksum);
        totalEntries += passEntries;
    }
    double milliseconds = (MonotonicTime::now() - start).milliseconds();
    printf("%s: %.1f ms %.2f MB/s checksum=%016llx\n", name, milliseconds, totalEntries / milliseconds, static_cast<unsigned long long>(checksum));
}

TEST(ScrollbarsControllerBench, MouseMovesOverContent)
{
    runScrollbarsControllerShape(mouseMovesOverContentShape, "MouseMovesOverContent", 2000, 0xcf7fb6b771e684c5ull);
}

TEST(ScrollbarsControllerBench, MouseMovesOverScrollbars)
{
    runScrollbarsControllerShape(mouseMovesOverScrollbarsShape, "MouseMovesOverScrollbars", 3600, 0x03c7e2aa18cceb61ull);
}

TEST(ScrollbarsControllerBench, ContentAreaScrolledDuringWheel)
{
    runScrollbarsControllerShape(contentAreaScrolledDuringWheelShape, "ContentAreaScrolledDuringWheel", 400, 0x789be2fe6258d63full);
}

TEST(ScrollbarsControllerBench, ContentAreaScrolledSoon)
{
    runScrollbarsControllerShape(contentAreaScrolledSoonShape, "ContentAreaScrolledSoon", 95, 0x73b777079ef68ad8ull);
}

TEST(ScrollbarsControllerBench, ContentAreaWillPaint)
{
    runScrollbarsControllerShape(contentAreaWillPaintShape, "ContentAreaWillPaint", 110, 0x2d1d0b6f191f7cfcull);
}

TEST(ScrollbarsControllerBench, ContentAreaWillPaintLocked)
{
    runScrollbarsControllerShape(contentAreaWillPaintLockedShape, "ContentAreaWillPaintLocked", 3000, 0x0180a9c0e7760dcbull);
}

TEST(ScrollbarsControllerBench, LiveResize)
{
    runScrollbarsControllerShape(liveResizeShape, "LiveResize", 450, 0x0feb1558b77497b1ull);
}

TEST(ScrollbarsControllerBench, ScrollerStyleChange)
{
    runScrollbarsControllerShape(scrollerStyleChangeShape, "ScrollerStyleChange", 600, 0x93a4eeb50077017full);
}

TEST(ScrollbarsControllerBench, ScrollbarWidthChange)
{
    runScrollbarsControllerShape(scrollbarWidthChangeShape, "ScrollbarWidthChange", 1400, 0x6334235d720f6627ull);
}

TEST(ScrollbarsControllerBench, ScrollGestures)
{
    runScrollbarsControllerShape(scrollGesturesShape, "ScrollGestures", 130, 0xeb4747eee247cd92ull);
}

TEST(ScrollbarsControllerBench, ScrollbarChurn)
{
    runScrollbarsControllerShape(scrollbarChurnShape, "ScrollbarChurn", 800, 0x14c95ef476c92f47ull);
}

} // namespace TestWebKitAPI

#endif // PLATFORM(MAC)
