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

#include <wtf/TZoneMallocInlines.h>
#include "ScrollPhysicsInputs.h"
#include <cstdlib>

// Scroll sessions through a scrollable area and its ScrollAnimator: one test per shape. Each test runs one pass and
// checks its checksum, a hash of every scroll the area makes and every member's return value. With
// WEBKIT_RUN_BENCHMARKS=1 it runs the pass about a second's worth of times and prints
// `<Shape>: <ms> ms <rate> MB/s checksum=<hex>`, where the rate is millions of member calls per second.

namespace TestWebKitAPI {

using namespace ScrollPhysics;

static void runScrollPhysicsShape(Case (*make)(), const char* name, unsigned fullPasses, uint64_t expectedChecksum)
{
    std::vector<Case> cases { make() };
    Trace trace(TraceLevel::Light);
    uint64_t checksum = runCases(trace, cases, false);
    EXPECT_EQ(checksum, expectedChecksum);

    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    uint64_t entries = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < fullPasses; ++pass) {
        Trace passTrace(TraceLevel::Light);
        EXPECT_EQ(runCases(passTrace, cases, false), checksum);
        entries += passTrace.entries();
    }
    double milliseconds = (MonotonicTime::now() - start).milliseconds();
    printf("%s: %.1f ms %.2f MB/s checksum=%016llx\n", name, milliseconds, entries / (milliseconds * 1000), static_cast<unsigned long long>(checksum));
}

TEST(ScrollPhysicsBench, SmoothScroll)
{
    runScrollPhysicsShape(smoothScrollShape, "SmoothScroll", 3000, 0xb6b169e9d2e062e1ull);
}

TEST(ScrollPhysicsBench, SmoothRetarget)
{
    runScrollPhysicsShape(smoothRetargetShape, "SmoothRetarget", 4000, 0xa59fb757e1c59ee1ull);
}

TEST(ScrollPhysicsBench, KeyboardScroll)
{
    runScrollPhysicsShape(keyboardScrollShape, "KeyboardScroll", 11000, 0x82aaca481b22653bull);
}

TEST(ScrollPhysicsBench, TrackpadGesture)
{
    runScrollPhysicsShape(trackpadGestureShape, "TrackpadGesture", 4000, 0x2760f553db787737ull);
}

TEST(ScrollPhysicsBench, RubberBand)
{
    runScrollPhysicsShape(rubberBandShape, "RubberBand", 8500, 0x1cb00a711dcd7538ull);
}

TEST(ScrollPhysicsBench, ScrollSnapGesture)
{
    runScrollPhysicsShape(scrollSnapGestureShape, "ScrollSnapGesture", 700, 0x237cc0f019572b8aull);
}

TEST(ScrollPhysicsBench, DiscreteWheelSnap)
{
    runScrollPhysicsShape(discreteWheelSnapShape, "DiscreteWheelSnap", 550, 0x10f1dd0bcc7c966dull);
}

TEST(ScrollPhysicsBench, MixedSession)
{
    runScrollPhysicsShape(mixedSessionShape, "MixedSession", 1500, 0xdc48f326f90b2c5cull);
}

TEST(ScrollPhysicsBench, ProgrammaticScroll)
{
    runScrollPhysicsShape(programmaticScrollShape, "ProgrammaticScroll", 1400, 0x01fcc8e14d521de7ull);
}

TEST(ScrollPhysicsBench, SteppedWheel)
{
    runScrollPhysicsShape(steppedWheelShape, "SteppedWheel", 7000, 0xacdd0876573a25c5ull);
}

TEST(ScrollPhysicsBench, ScrollIntoView)
{
    runScrollPhysicsShape(scrollIntoViewShape, "ScrollIntoView", 1500, 0x9b6cde8cdeca8312ull);
}

TEST(ScrollPhysicsBench, ResnapAfterLayout)
{
    runScrollPhysicsShape(resnapAfterLayoutShape, "ResnapAfterLayout", 600, 0xd54e0a8d278bdebeull);
}

TEST(ScrollPhysicsBench, AreaScrollTo)
{
    runScrollPhysicsShape(areaScrollToShape, "AreaScrollTo", 1000, 0x855aa786d0831594ull);
}

TEST(ScrollPhysicsBench, EdgeQueries)
{
    runScrollPhysicsShape(edgeQueriesShape, "EdgeQueries", 2500, 0xc989c009c01dbf03ull);
}

} // namespace TestWebKitAPI

#endif // PLATFORM(MAC)
