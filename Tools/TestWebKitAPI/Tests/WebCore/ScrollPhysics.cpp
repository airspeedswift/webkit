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

// Each case's digest covers every call ScrollAnimator makes on its scrollable area and scrollbars controller, with
// arguments and return values, every clock read, every timer event and every member's return value.

namespace TestWebKitAPI {

using namespace ScrollPhysics;

static uint64_t digestForCase(Case (*make)())
{
    return unitCaseDigest(make());
}

TEST(ScrollPhysics, DiscreteWheelBurst3)
{
    EXPECT_EQ(unitCaseDigest(discreteWheelBurstCase(3)), 0x942afceb350bafe1ull);
}

TEST(ScrollPhysics, DiscreteWheelBurst4)
{
    EXPECT_EQ(unitCaseDigest(discreteWheelBurstCase(4)), 0x40fc3c6d61255221ull);
}

TEST(ScrollPhysics, DiscreteWheelBurst5)
{
    EXPECT_EQ(unitCaseDigest(discreteWheelBurstCase(5)), 0xf658a432e1e68d90ull);
}

TEST(ScrollPhysics, SnapGlide100)
{
    EXPECT_EQ(unitCaseDigest(snapGlideCase(100)), 0x2f06018dd4d65f7eull);
}

TEST(ScrollPhysics, SnapGlide1000)
{
    EXPECT_EQ(unitCaseDigest(snapGlideCase(1000)), 0xa9acd4b4e91e5cfeull);
}

TEST(ScrollPhysics, StopFromScroll)
{
    EXPECT_EQ(digestForCase(stopFromScrollCase), 0x4c22b3dd806dea8eull);
}

TEST(ScrollPhysics, RetargetToCurrentOffset)
{
    EXPECT_EQ(digestForCase(retargetToCurrentOffsetCase), 0x0b8a472b6385d221ull);
}

TEST(ScrollPhysics, MomentumContentsSizeChanged)
{
    EXPECT_EQ(digestForCase(momentumContentsSizeChangedCase), 0xcaf33faa54765c10ull);
}

TEST(ScrollPhysics, KeyboardSubpixelPosition)
{
    EXPECT_EQ(digestForCase(keyboardSubpixelPositionCase), 0x6beb92fdf89c593dull);
}

TEST(ScrollPhysics, KeyboardPositionBeyondInt32)
{
    EXPECT_EQ(digestForCase(keyboardPositionBeyondInt32Case), 0x4db1ff6ef0568005ull);
}

TEST(ScrollPhysics, KeyboardContentsSmallerThanViewport)
{
    EXPECT_EQ(digestForCase(keyboardContentsSmallerThanViewportCase), 0xde390505ae96a737ull);
}

TEST(ScrollPhysics, SnapPointSelection)
{
    EXPECT_EQ(snapPointSelectionDigest(), 0x89d21a3a67af4173ull);
}

TEST(ScrollPhysics, SnapOffsetsInfo)
{
    Trace trace(TraceLevel::Light);
    ScriptedClockScope clockScope(trace, caseStartTime);
    TimerRecorder timers(trace);
    TimerFactoryScope timerScope(timers);
    RecordingScrollableArea area(trace, unitConfig(), { 0, 0 });
    auto& animator = area.scrollAnimator();

    EXPECT_FALSE(animator.usesScrollSnap());
    EXPECT_EQ(animator.snapOffsetsInfo(), nullptr);

    SnapDescription snap;
    snap.offsets = evenlySpaced(0, 300, 10);
    auto info = snapInfo(snap);
    animator.setSnapOffsetsInfo(info);
    EXPECT_TRUE(animator.usesScrollSnap());
    auto* stored = animator.snapOffsetsInfo();
    ASSERT_NE(stored, nullptr);
    EXPECT_TRUE(stored->isEqual(info));
    EXPECT_EQ(animator.activeScrollSnapIndexForAxis(ScrollEventAxis::Vertical), 0u);

    // The same pointer until the next change.
    area.setPosition({ 0, 600 });
    EXPECT_EQ(animator.snapOffsetsInfo(), stored);
    EXPECT_EQ(animator.activeScrollSnapIndexForAxis(ScrollEventAxis::Vertical), 2u);

    animator.setSnapOffsetsInfo({ });
    EXPECT_FALSE(animator.usesScrollSnap());
    EXPECT_EQ(animator.snapOffsetsInfo(), nullptr);
    EXPECT_EQ(animator.activeScrollSnapIndexForAxis(ScrollEventAxis::Vertical), std::nullopt);
}

} // namespace TestWebKitAPI

#endif // PLATFORM(MAC)
