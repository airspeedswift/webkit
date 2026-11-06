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

#include "ScrollingTreeDelegateRig.h"
#include <cstdlib>

// Scroll sessions through a scrolling tree of Mac frame and overflow nodes: one test per shape. Each test runs
// one pass on a new tree and checks its checksum, a hash of every scroll position and flag the nodes report
// after each commit, wheel event and display refresh, and of every call they make on the tree. With
// WEBKIT_RUN_BENCHMARKS=1 it runs the pass about a second's worth of times and prints
// <Shape>: <ms> ms <rate> MB/s checksum=<hex>, where the rate is thousands of commits, wheel events and
// display refreshes per second.

namespace TestWebKitAPI {

using namespace ScrollingTreeDelegate;

static void runScrollingTreeShape(Shape shape, const char* name, unsigned fullPasses, uint64_t expectedChecksum)
{
    auto [checksum, entries] = runShape(shape);
    EXPECT_EQ(checksum, expectedChecksum);

    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    uint64_t totalEntries = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < fullPasses; ++pass) {
        auto [passChecksum, passEntries] = runShape(shape);
        EXPECT_EQ(passChecksum, checksum);
        totalEntries += passEntries;
    }
    double milliseconds = (MonotonicTime::now() - start).milliseconds();
    printf("%s: %.1f ms %.2f MB/s checksum=%016llx\n", name, milliseconds, totalEntries / milliseconds, static_cast<unsigned long long>(checksum));
}

TEST(ScrollingTreeDelegateBench, TrackpadGesture)
{
    runScrollingTreeShape(trackpadGestureShape, "TrackpadGesture", 700, 0xc9f70fe4009accccull);
}

TEST(ScrollingTreeDelegateBench, RubberBandAtEdge)
{
    runScrollingTreeShape(rubberBandAtEdgeShape, "RubberBandAtEdge", 1700, 0x87a9f5f70f846096ull);
}

TEST(ScrollingTreeDelegateBench, ScrollSnapGesture)
{
    runScrollingTreeShape(scrollSnapGestureShape, "ScrollSnapGesture", 1450, 0x66842425ab9cfba3ull);
}

TEST(ScrollingTreeDelegateBench, StateCommits)
{
    runScrollingTreeShape(stateCommitsShape, "StateCommits", 1550, 0xd8ebae34bdfb5dc6ull);
}

TEST(ScrollingTreeDelegateBench, MixedSession)
{
    runScrollingTreeShape(mixedSessionShape, "MixedSession", 2000, 0x327f3ada241707d3ull);
}

TEST(ScrollingTreeDelegateBench, DiscreteWheelSnap)
{
    runScrollingTreeShape(discreteWheelSnapShape, "DiscreteWheelSnap", 4, 0xa42b68843454d307ull);
}

TEST(ScrollingTreeDelegateBench, SnapSelection)
{
    runScrollingTreeShape(snapSelectionShape, "SnapSelection", 1000, 0x9659dfc9a812ce66ull);
}

TEST(ScrollingTreeDelegateBench, CommitPerRenderingUpdate)
{
    runScrollingTreeShape(commitPerRenderingUpdateShape, "CommitPerRenderingUpdate", 370, 0x473161518922f079ull);
}

TEST(ScrollingTreeDelegateBench, WheelEvent)
{
    runScrollingTreeShape(wheelEventShape, "WheelEvent", 700, 0x76548ae512fd6fe6ull);
}

TEST(ScrollingTreeDelegateBench, DisplayRefresh)
{
    runScrollingTreeShape(displayRefreshShape, "DisplayRefresh", 2600, 0x599dab7d2ae56305ull);
}

TEST(ScrollingTreeDelegateBench, Latching)
{
    runScrollingTreeShape(latchingShape, "Latching", 1400, 0x6e4281951d5d5a23ull);
}

} // namespace TestWebKitAPI

#endif // PLATFORM(MAC)
