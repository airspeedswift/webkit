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

// Each case's digest covers every call ScrollingEffectsController makes on its client, with arguments and
// return values, every clock read, every timer event and every member's return value.

namespace TestWebKitAPI {

using namespace ScrollPhysics;

static uint64_t digestForCase(Case (*make)())
{
    return unitCaseDigest(make());
}

TEST(ScrollPhysics, DiscreteWheelBurst3)
{
    EXPECT_EQ(unitCaseDigest(discreteWheelBurstCase(3)), 0x4038fc6e8ca56527ull);
}

TEST(ScrollPhysics, DiscreteWheelBurst4)
{
    EXPECT_EQ(unitCaseDigest(discreteWheelBurstCase(4)), 0x75e91a62968e7fd4ull);
}

TEST(ScrollPhysics, DiscreteWheelBurst5)
{
    EXPECT_EQ(unitCaseDigest(discreteWheelBurstCase(5)), 0x3afd773cbbd07939ull);
}

TEST(ScrollPhysics, SnapGlide100)
{
    EXPECT_EQ(unitCaseDigest(snapGlideCase(100)), 0xbb7ecf4cc06cd31dull);
}

TEST(ScrollPhysics, SnapGlide1000)
{
    EXPECT_EQ(unitCaseDigest(snapGlideCase(1000)), 0x312c373776d75577ull);
}

TEST(ScrollPhysics, StopFromScroll)
{
    EXPECT_EQ(digestForCase(stopFromScrollCase), 0x331df019f5092657ull);
}

TEST(ScrollPhysics, RetargetToCurrentOffset)
{
    EXPECT_EQ(digestForCase(retargetToCurrentOffsetCase), 0x0976b01eb13e385dull);
}

TEST(ScrollPhysics, MomentumContentsSizeChanged)
{
    EXPECT_EQ(digestForCase(momentumContentsSizeChangedCase), 0xfb090a67a5a7c9bfull);
}

TEST(ScrollPhysics, KeyboardSubpixelPosition)
{
    EXPECT_EQ(digestForCase(keyboardSubpixelPositionCase), 0x6bf12e0e76b8e0a8ull);
}

TEST(ScrollPhysics, KeyboardPositionBeyondInt32)
{
    EXPECT_EQ(digestForCase(keyboardPositionBeyondInt32Case), 0x6c918a61adc7ba4aull);
}

TEST(ScrollPhysics, KeyboardContentsSmallerThanViewport)
{
    EXPECT_EQ(digestForCase(keyboardContentsSmallerThanViewportCase), 0xd85d669b24179788ull);
}

TEST(ScrollPhysics, SnapOffsetsInfo)
{
    Trace trace(TraceLevel::Light);
    ScriptedClockScope clockScope(trace, caseStartTime);
    RecordingClient client(trace, unitConfig(), { 0, 0 });
    ControllerHost host(client);
    auto& controller = host.controller();

    EXPECT_FALSE(controller.usesScrollSnap());
    EXPECT_EQ(controller.snapOffsetsInfo(), nullptr);

    SnapDescription snap;
    snap.offsets = evenlySpaced(0, 300, 10);
    auto info = snapInfo(snap);
    controller.setSnapOffsetsInfo(info);
    EXPECT_TRUE(controller.usesScrollSnap());
    auto* stored = controller.snapOffsetsInfo();
    ASSERT_NE(stored, nullptr);
    EXPECT_TRUE(stored->isEqual(info));
    EXPECT_EQ(controller.activeScrollSnapIndexForAxis(ScrollEventAxis::Vertical), 0u);

    // The same pointer until the next change.
    controller.updateActiveScrollSnapIndexForClientOffset();
    EXPECT_EQ(controller.snapOffsetsInfo(), stored);

    controller.setSnapOffsetsInfo({ });
    EXPECT_FALSE(controller.usesScrollSnap());
    EXPECT_EQ(controller.snapOffsetsInfo(), nullptr);
    EXPECT_EQ(controller.activeScrollSnapIndexForAxis(ScrollEventAxis::Vertical), std::nullopt);
}

} // namespace TestWebKitAPI

#endif // PLATFORM(MAC)
