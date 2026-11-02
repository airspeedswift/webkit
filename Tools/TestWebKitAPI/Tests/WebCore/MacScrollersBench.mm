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

#import "MacScrollersRig.h"
#import <cstdlib>

// Scroll sessions on scrolling nodes with overlay and legacy scrollbars: one test per shape. Each test runs one
// pass on new trees and checks its checksum, a hash of the scrollbar state WebKit sets on each node's scrollers
// after each commit, wheel event and display refresh, and of every call the nodes make on the tree. With
// WEBKIT_RUN_BENCHMARKS=1 it runs the pass about a second's worth of times and prints
// <Shape>: <ms> ms <rate> MB/s checksum=<hex>, where the rate is thousands of commits, wheel events and
// display refreshes per second.

namespace TestWebKitAPI {

using namespace ScrollingTreeDelegate;

static void runMacScrollersShape(ScrollbarsShape shape, const char* name, unsigned fullPasses, uint64_t expectedChecksum)
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

TEST(MacScrollersBench, ScrollUpdates)
{
    runMacScrollersShape(scrollUpdatesShape, "ScrollUpdates", 120, 0x174e2cf01d127275ull);
}

TEST(MacScrollersBench, MomentumPresentation)
{
    runMacScrollersShape(momentumPresentationShape, "MomentumPresentation", 90, 0xe4d8c54d1bb6ffc4ull);
}

TEST(MacScrollersBench, HoverAndExit)
{
    runMacScrollersShape(hoverAndExitShape, "HoverAndExit", 700, 0x33c988095c648e21ull);
}

TEST(MacScrollersBench, StateCommits)
{
    runMacScrollersShape(scrollbarStateCommitsShape, "StateCommits", 570, 0xb3c3baeb77441fe4ull);
}

TEST(MacScrollersBench, TeardownChurn)
{
    runMacScrollersShape(teardownChurnShape, "TeardownChurn", 500, 0x777fa77a6a055e15ull);
}

} // namespace TestWebKitAPI

#endif // PLATFORM(MAC)
