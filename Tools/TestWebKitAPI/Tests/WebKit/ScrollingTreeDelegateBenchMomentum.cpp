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

#if ENABLE(MOMENTUM_EVENT_DISPATCHER)

#include "Helpers/Test.h"
#include "MomentumEventDispatcher.h"
#include <WebCore/RectEdges.h>
#include <WebCore/ScrollTypes.h>
#include <WebCore/ScrollingEffectsClock.h>
#include <bit>
#include <cstdlib>
#include <optional>
#include <wtf/MonotonicTime.h>

// The momentum dispatcher's synthesized momentum phase, the one RemoteLayerTreeEventDispatcher (UI process) and
// EventDispatcher (web process) put in place of the platform's: trackpad gestures as WebWheelEvents with raw
// platform deltas, then a platform momentum Began, which starts the dispatcher's offset table, and display refreshes
// at the display's rate on a replaced scrolling-effects clock until the dispatcher ends the phase. The gestures cover
// each way a phase ends: naturally on its table, by a platform momentum Ended of either end type, by a new gesture,
// and by another page's event. Its entries are handleWheelEvent and displayDidRefresh, on one thread with no page.
// The checksum is an FNV-1a hash of every synthesized event (phase, momentum phase, end type, deltas, wheel ticks,
// time) and every display start and stop, so it pins the offset table, the tail and the events built from them.
// With WEBKIT_RUN_BENCHMARKS=1 the test repeats its pass and prints
// SyntheticMomentum: <ms> ms <rate> MB/s checksum=<hex>, where the rate is thousands of dispatcher entries per
// second, as the tree's shapes report theirs.

namespace TestWebKitAPI {

namespace SyntheticMomentum {

using namespace WebKit;
using WebCore::FloatSize;
using WebCore::PageIdentifier;
using WebCore::PlatformDisplayID;
using WebCore::RectEdges;
using WebCore::RubberBandingBehavior;
using Phase = WebWheelEvent::Phase;
using EndType = WebWheelEvent::MomentumEndType;

class Digest {
public:
    void add(uint64_t value)
    {
        for (unsigned i = 0; i < 8; ++i) {
            m_hash ^= (value >> (i * 8)) & 0xff;
            m_hash *= 0x100000001b3ull;
        }
    }
    void add(float value) { add(static_cast<uint64_t>(std::bit_cast<uint32_t>(value))); }
    void add(double value) { add(std::bit_cast<uint64_t>(value)); }
    void add(FloatSize size)
    {
        add(size.width());
        add(size.height());
    }
    uint64_t value() const { return m_hash; }

private:
    uint64_t m_hash { 0xcbf29ce484222325ull };
};

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
    unsigned range(unsigned low, unsigned high) { return low + next() % (high - low + 1); }
    float between(float low, float high) { return low + (high - low) * (next() % 10000) / 10000.0f; }

private:
    uint64_t m_state;
};

// The scrolling-effects clock the dispatcher reads (it reads scrollingEffectsClockNow(), not
// MonotonicTime::now()), advanced by the pass.
static double& clockSeconds()
{
    static double seconds { 5000 };
    return seconds;
}

static MonotonicTime readClock() { return MonotonicTime::fromRawSeconds(clockSeconds()); }

static constexpr PlatformDisplayID display = 1;

class DigestingClient final : public MomentumEventDispatcher::Client {
public:
    explicit DigestingClient(Digest& digest)
        : m_digest(digest)
    {
    }

    bool displayRunning() const { return m_displayRunning; }
    unsigned synthesized() const { return m_synthesized; }

private:
    void handleSyntheticWheelEvent(PageIdentifier page, const WebWheelEvent& event, RectEdges<RubberBandingBehavior>) final
    {
        ++m_synthesized;
        m_digest.add(page.toUInt64());
        m_digest.add(static_cast<uint64_t>(event.phase()) | static_cast<uint64_t>(event.momentumPhase()) << 8 | static_cast<uint64_t>(event.momentumEndType()) << 16);
        m_digest.add(event.delta());
        m_digest.add(event.wheelTicks());
        m_digest.add(event.unacceleratedScrollingDelta());
        m_digest.add(event.timestamp().secondsSinceEpoch().seconds() - 5000);
    }

    void startDisplayDidRefreshCallbacks(PlatformDisplayID displayID) final
    {
        m_digest.add(static_cast<uint64_t>(0x5700 + displayID));
        m_displayRunning = true;
    }

    void stopDisplayDidRefreshCallbacks(PlatformDisplayID displayID) final
    {
        m_digest.add(static_cast<uint64_t>(0x5701 + displayID));
        m_displayRunning = false;
    }

    void didEndSyntheticMomentumScrolling() final { m_digest.add(static_cast<uint64_t>(0xe2d)); }

#if ENABLE(MOMENTUM_EVENT_DISPATCHER_TEMPORARY_LOGGING)
    void flushMomentumEventLoggingSoon() final { }
#endif

    Digest& m_digest;
    unsigned m_synthesized { 0 };
    bool m_displayRunning { false };
};

static PageIdentifier page(uint64_t number) { return PageIdentifier(ObjectIdentifier<WebCore::PageIdentifierType>(number)); }

// One pass: a dispatcher, its client and two pages on one display, and a seeded series of gestures.
class Pass {
public:
    Pass()
        : m_client(m_digest)
        , m_dispatcher(MomentumEventDispatcher::create(m_client))
    {
        clockSeconds() = 5000;
        WebCore::setScrollingEffectsClockForTesting(readClock);
        for (uint64_t number : { 1, 2 }) {
            m_dispatcher->setScrollingAccelerationCurve(page(number), ScrollingAccelerationCurve::fallbackCurve());
            m_dispatcher->pageScreenDidChange(page(number), display, 60);
        }
    }

    ~Pass()
    {
        m_dispatcher = nullptr;
        WebCore::setScrollingEffectsClockForTesting(nullptr);
    }

    // As WebKit's NSEvent conversion: delta is the accelerated one, unacceleratedScrollingDelta and the raw
    // platform delta the device's.
    void event(uint64_t pageNumber, Phase phase, Phase momentumPhase, FloatSize delta, double gap, EndType endType = EndType::Unknown, bool raw = true)
    {
        clockSeconds() += gap;
        auto time = readClock();
        constexpr float acceleration = 1.6f;
        bool handled = m_dispatcher->handleWheelEvent(page(pageNumber), WebWheelEvent::create({ WebEventType::Wheel, { }, time }, {
            .position = { 300, 200 },
            .globalPosition = { 300, 200 },
            .delta = delta.scaled(acceleration),
            .wheelTicks = delta.scaled(acceleration / 40),
            .granularity = WebWheelEvent::Granularity::ScrollByPixelWheelEvent,
            .directionInvertedFromDevice = false,
            .phase = phase,
            .momentumPhase = momentumPhase,
            .hasPreciseScrollingDeltas = true,
            .scrollCount = 0,
            .unacceleratedScrollingDelta = delta,
            .ioHIDEventTimestamp = time,
            .rawPlatformDelta = raw ? std::optional<FloatSize> { delta } : std::nullopt,
            .momentumEndType = endType,
            .inputSource = WebEventInputSource::UserDriven,
            .momentumFastScrollMultiplier = 1,
        }), { RubberBandingBehavior::Always, RubberBandingBehavior::Always, RubberBandingBehavior::Always, RubberBandingBehavior::Always });
        m_digest.add(static_cast<uint64_t>(handled));
        ++m_entries;
    }

    void refresh()
    {
        clockSeconds() += 1.0 / 60;
        m_dispatcher->displayDidRefresh(display);
        ++m_entries;
    }

    // A gesture's active phase, then the platform's momentum Began (which starts the synthesized phase).
    void gestureThenMomentum(uint64_t pageNumber, FloatSize first, unsigned count)
    {
        event(pageNumber, Phase::MayBegin, Phase::None, { }, 0.3);
        auto delta = first;
        for (unsigned i = 0; i < count; ++i) {
            event(pageNumber, i ? Phase::Changed : Phase::Began, Phase::None, delta, 1.0 / 60);
            delta = delta.scaled(0.97f);
        }
        event(pageNumber, Phase::Ended, Phase::None, { }, 1.0 / 60);
        event(pageNumber, Phase::None, Phase::Began, delta, 1.0 / 60);
    }

    // Display refreshes, with the platform's own momentum Changed events (which the dispatcher swallows) every
    // other frame, until the synthesized phase ends or after limit frames.
    void refreshFor(uint64_t pageNumber, unsigned limit, FloatSize platformDelta)
    {
        for (unsigned frame = 0; frame < limit && m_client.displayRunning(); ++frame) {
            refresh();
            if (frame % 2) {
                platformDelta = platformDelta.scaled(0.95f);
                event(pageNumber, Phase::None, Phase::Changed, platformDelta, 0);
            }
        }
    }

    void run()
    {
        Lcg random(31);
        for (unsigned gesture = 0; gesture < 24; ++gesture) {
            float sign = random.next() % 2 ? -1 : 1;
            FloatSize first { gesture % 4 ? 0 : random.between(-6, 6), sign * random.between(4, 40) };
            unsigned count = random.range(4, 14);
            gestureThenMomentum(1, first, count);
            switch (gesture % 6) {
            case 0:
            case 1:
                // To the end of the offset table and its tail; the platform's Ended (natural) comes after.
                refreshFor(1, 2000, first);
                event(1, Phase::None, Phase::Ended, { }, 1.0 / 60, EndType::Natural, false);
                break;
            case 2:
                // The platform's phase ends naturally first: the synthesized one runs on.
                refreshFor(1, random.range(10, 40), first);
                event(1, Phase::None, Phase::Ended, { }, 1.0 / 60, EndType::Natural, false);
                refreshFor(1, 2000, { });
                break;
            case 3:
                // Fingers back on the trackpad: the platform's Ended (interrupted).
                refreshFor(1, random.range(5, 30), first);
                event(1, Phase::None, Phase::Ended, { }, 1.0 / 60, EndType::Interrupted, false);
                break;
            case 4:
                // A new gesture mid-momentum.
                refreshFor(1, random.range(5, 30), first);
                event(1, Phase::MayBegin, Phase::None, { }, 1.0 / 60);
                event(1, Phase::Cancelled, Phase::None, { }, 1.0 / 60);
                break;
            case 5:
                // Another page's event mid-momentum.
                refreshFor(1, random.range(5, 30), first);
                event(2, Phase::MayBegin, Phase::None, { }, 1.0 / 60);
                event(2, Phase::Cancelled, Phase::None, { }, 1.0 / 60);
                break;
            }
            // Whatever is still running ends on the table.
            refreshFor(1, 2000, { });
        }
        m_digest.add(static_cast<uint64_t>(m_client.synthesized()));
    }

    uint64_t checksum() const { return m_digest.value(); }
    uint64_t entries() const { return m_entries; }

private:
    Digest m_digest;
    DigestingClient m_client;
    std::unique_ptr<MomentumEventDispatcher> m_dispatcher;
    uint64_t m_entries { 0 };
};

static std::pair<uint64_t, uint64_t> runPass()
{
    Pass pass;
    pass.run();
    return { pass.checksum(), pass.entries() };
}

} // namespace SyntheticMomentum

TEST(ScrollingTreeDelegateBench, SyntheticMomentum)
{
    constexpr uint64_t expectedChecksum = 0x38943e0a96d1619eull;
    constexpr unsigned fullPasses = 9000;

    auto [checksum, entries] = SyntheticMomentum::runPass();
    EXPECT_EQ(checksum, expectedChecksum);

    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    uint64_t totalEntries = 0;
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < fullPasses; ++pass) {
        auto [passChecksum, passEntries] = SyntheticMomentum::runPass();
        EXPECT_EQ(passChecksum, checksum);
        totalEntries += passEntries;
    }
    double milliseconds = (MonotonicTime::now() - start).milliseconds();
    printf("SyntheticMomentum: %.1f ms %.2f MB/s checksum=%016llx\n", milliseconds, totalEntries / milliseconds, static_cast<unsigned long long>(checksum));
}

} // namespace TestWebKitAPI

#endif // ENABLE(MOMENTUM_EVENT_DISPATCHER)
