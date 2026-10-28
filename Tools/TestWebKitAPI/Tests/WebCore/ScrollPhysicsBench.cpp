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

#include "ScrollPhysicsInputs.h"
#include <cstdlib>

// Scroll sessions through ScrollingEffectsController: one test per shape. Each test runs one pass and checks
// its checksum, a hash of every scroll the controller asks for and every member's return value. With
// WEBKIT_RUN_BENCHMARKS=1 it runs the pass about a second's worth of times and prints
// `<Shape>: <ms> ms <rate> MB/s checksum=<hex>`, where the rate is millions of controller calls per second.

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
    runScrollPhysicsShape(smoothScrollShape, "SmoothScroll", 16000, 0x56d947dc2bceeef8ull);
}

TEST(ScrollPhysicsBench, SmoothRetarget)
{
    runScrollPhysicsShape(smoothRetargetShape, "SmoothRetarget", 18000, 0xa223e45da716324dull);
}

TEST(ScrollPhysicsBench, KeyboardScroll)
{
    runScrollPhysicsShape(keyboardScrollShape, "KeyboardScroll", 19000, 0x656a5fb3c2419ca1ull);
}

TEST(ScrollPhysicsBench, TrackpadGesture)
{
    runScrollPhysicsShape(trackpadGestureShape, "TrackpadGesture", 11000, 0xaa13b0eb60fbf183ull);
}

TEST(ScrollPhysicsBench, RubberBand)
{
    runScrollPhysicsShape(rubberBandShape, "RubberBand", 17500, 0x9ecc024e503c6888ull);
}

TEST(ScrollPhysicsBench, ScrollSnapGesture)
{
    runScrollPhysicsShape(scrollSnapGestureShape, "ScrollSnapGesture", 500, 0x5defe3a339dede6bull);
}

TEST(ScrollPhysicsBench, DiscreteWheelSnap)
{
    runScrollPhysicsShape(discreteWheelSnapShape, "DiscreteWheelSnap", 500, 0xd567b575abc9c990ull);
}

TEST(ScrollPhysicsBench, MixedSession)
{
    runScrollPhysicsShape(mixedSessionShape, "MixedSession", 2500, 0x9f209150997892ccull);
}

} // namespace TestWebKitAPI

#endif // PLATFORM(MAC)
