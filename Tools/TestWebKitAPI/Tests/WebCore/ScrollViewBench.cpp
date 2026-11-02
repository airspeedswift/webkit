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

#include "config.h"

#if PLATFORM(MAC)

#include "ScrollViewInputs.h"
#include <cstdlib>
#include <wtf/MonotonicTime.h>

// Sessions on nested ScrollViews: one test per shape. Each test runs one pass and checks its checksum, a hash of
// every call ScrollView makes on its subclass and host window and every member's return value. With
// WEBKIT_RUN_BENCHMARKS=1 it runs the pass about a second's worth of times and prints
// `<Shape>: <ms> ms <rate> MB/s checksum=<hex>`, where the rate is millions of member calls per second.

namespace TestWebKitAPI {

using namespace ScrollViewTesting;

static void runScrollViewShape(std::vector<Case> (*make)(), const char* name, unsigned fullPasses, uint64_t expectedChecksum)
{
    auto cases = make();
    Trace trace;
    uint64_t checksum = runCases(trace, cases);
    EXPECT_EQ(checksum, expectedChecksum);

    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    uint64_t entries = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < fullPasses; ++pass) {
        Trace passTrace;
        EXPECT_EQ(runCases(passTrace, cases), checksum);
        entries += passTrace.events();
    }
    double milliseconds = (MonotonicTime::now() - start).milliseconds();
    printf("%s: %.1f ms %.2f MB/s checksum=%016llx\n", name, milliseconds, entries / (milliseconds * 1000), static_cast<unsigned long long>(checksum));
}

TEST(ScrollViewBench, PointConversions)
{
    runScrollViewShape(pointConversionsShape, "PointConversions", 1400, 0xa140f930e74dddb0ull);
}

TEST(ScrollViewBench, RectConversions)
{
    runScrollViewShape(rectConversionsShape, "RectConversions", 1800, 0xf9e583397327feb8ull);
}

TEST(ScrollViewBench, RootViewChain)
{
    runScrollViewShape(rootViewChainShape, "RootViewChain", 1550, 0xdf97ac2a39ce8c57ull);
}

TEST(ScrollViewBench, VisibleRectQueries)
{
    runScrollViewShape(visibleRectQueriesShape, "VisibleRectQueries", 1050, 0x5ec957b98d7c97c1ull);
}

TEST(ScrollViewBench, UpdateScrollbarsNoChange)
{
    runScrollViewShape(contentSizeNoChangeShape, "UpdateScrollbarsNoChange", 1100, 0xbe379927b1ebd4e2ull);
}

TEST(ScrollViewBench, UpdateScrollbarsToggle)
{
    runScrollViewShape(contentSizeToggleShape, "UpdateScrollbarsToggle", 700, 0xb8d9babec4a0d60full);
}

TEST(ScrollViewBench, ScrollToStream)
{
    runScrollViewShape(scrollToStreamShape, "ScrollToStream", 540, 0x753e260b4bd7678aull);
}

TEST(ScrollViewBench, ScrollContents)
{
    runScrollViewShape(scrollContentsShape, "ScrollContents", 680, 0xf0b2610b911a131bull);
}

TEST(ScrollViewBench, OverhangQueries)
{
    runScrollViewShape(overhangShape, "OverhangQueries", 6900, 0x86a23061b9e53085ull);
}

TEST(ScrollViewBench, ScrollbarHitTesting)
{
    runScrollViewShape(hitTestShape, "ScrollbarHitTesting", 3500, 0x819aee2cbe6976c3ull);
}

TEST(ScrollViewBench, ScrollbarModes)
{
    runScrollViewShape(scrollbarModesShape, "ScrollbarModes", 9500, 0xc3ca999715c9ed2dull);
}

} // namespace TestWebKitAPI

#endif // PLATFORM(MAC)
