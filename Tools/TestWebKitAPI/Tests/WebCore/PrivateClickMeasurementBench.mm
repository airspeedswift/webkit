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

#include "ASN1Utilities.h"
#include "Helpers/Test.h"
#include <WebCore/PrivateClickMeasurement.h>
#include <WebCore/RegistrableDomain.h>
#include <wtf/MonotonicTime.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/URL.h>
#include <wtf/WallTime.h>
#include <wtf/text/Base64.h>
#include <wtf/text/MakeString.h>

#if HAVE(RSA_BSSA)
#include "CoreCryptoSPI.h"
#include <wtf/spi/cocoa/SecuritySPI.h>
#endif

// Benchmarks of WebCore's Private Click Measurement: trigger URL parsing, attribution, report and token JSON and
// URLs, and token crypto. Each test runs one pass and checks its checksum; with WEBKIT_RUN_BENCHMARKS=1 it then
// times its passes and prints "<Test>: <ms> ms <MB/s> MB/s checksum=<checksum>". PrivateClickMeasurementStoreBench
// covers the store and the database.

namespace TestWebKitAPI {

using namespace WebCore;

namespace PCMBench {

// The checksum covers the observable results only, in a fixed order. FNV-1a over 64 bits.
class Digest {
public:
    void add(uint64_t value)
    {
        for (unsigned i = 0; i < 8; ++i) {
            m_hash ^= (value >> (i * 8)) & 0xff;
            m_hash *= 0x100000001b3ull;
        }
    }
    void add(bool value) { add(static_cast<uint64_t>(value ? 1 : 2)); }
    void add(const String& string)
    {
        add(static_cast<uint64_t>(string.isNull() ? 3 : 4));
        add(static_cast<uint64_t>(string.length()));
        for (unsigned i = 0; i < string.length(); ++i)
            add(static_cast<uint64_t>(string[i]));
    }
    void add(const URL& url)
    {
        add(url.isValid());
        add(url.string());
    }
    void add(const std::optional<URL>& url)
    {
        add(url.has_value());
        if (url)
            add(*url);
    }
    uint64_t value() const { return m_hash; }

private:
    uint64_t m_hash { 0xcbf29ce484222325ull };
};

class Random {
public:
    uint64_t next()
    {
        m_state ^= m_state << 13;
        m_state ^= m_state >> 7;
        m_state ^= m_state << 17;
        return m_state;
    }
    unsigned below(unsigned limit) { return static_cast<unsigned>(next() % limit); }

private:
    uint64_t m_state { 0x9e3779b97f4a7c15ull };
};

static const Vector<String>& hosts()
{
    static NeverDestroyed<Vector<String>> hosts = Vector<String> { "webkit.org"_s, "www.example.com"_s, "ads.example.co.uk"_s, "shop.example.org"_s, "a.b.c.example.net"_s, "example.com"_s };
    return hosts;
}

static String nonce(Random& random)
{
    std::array<uint8_t, 16> bytes;
    for (auto& byte : bytes)
        byte = random.next() & 0xff;
    return base64URLEncodeToString(std::span<const uint8_t> { bytes });
}

static String twoDigits(unsigned value) { return makeString(value / 10, value % 10); }

static String triggerBase(Random& random, ASCIILiteral scheme = "https"_s)
{
    return makeString(scheme, "://"_s, hosts()[random.below(hosts().size())], "/.well-known/private-click-measurement/trigger-attribution/"_s);
}

struct Inputs {
    Vector<URL> urls;
    uint64_t bytes { 0 };

    void add(const String& string)
    {
        bytes += string.length();
        urls.append(URL { string });
    }
};

static Digest& digestParse(Digest& digest, const std::expected<PCM::AttributionTriggerData, String>& result)
{
    digest.add(result.has_value());
    if (result) {
        digest.add(static_cast<uint64_t>(result->data));
        digest.add(static_cast<uint64_t>(result->priority));
        digest.add(static_cast<uint64_t>(result->wasSent == PCM::WasSent::Yes));
        digest.add(result->sourceRegistrableDomain.has_value());
        if (result->sourceRegistrableDomain)
            digest.add(result->sourceRegistrableDomain->string());
        digest.add(result->ephemeralDestinationNonce.has_value());
        if (result->ephemeralDestinationNonce)
            digest.add(result->ephemeralDestinationNonce->nonce);
    } else
        digest.add(result.error());
    return digest;
}

static uint64_t parsePass(const Inputs& inputs)
{
    Digest digest;
    for (auto& url : inputs.urls)
        digestParse(digest, PrivateClickMeasurement::parseAttributionRequest(url));
    return digest.value();
}

// Pass counts are sized for about a second in a Release build.
template<typename Pass>
static void run(ASCIILiteral name, uint64_t expectedChecksum, uint64_t bytesPerPass, unsigned passes, Pass&& pass)
{
    uint64_t checksum = pass();
    EXPECT_EQ(checksum, expectedChecksum);
    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < passes; ++i) {
        auto passChecksum = pass();
        EXPECT_EQ(passChecksum, checksum);
    }
    double milliseconds = (MonotonicTime::now() - start).milliseconds();
    SAFE_PRINTF("%s: %.1f ms %.2f MB/s checksum=%016llx\n", name, milliseconds, static_cast<double>(bytesPerPass) * passes / milliseconds / 1000, static_cast<unsigned long long>(checksum));
}

static WallTime clickTime() { return WallTime::fromRawSeconds(1'700'000'000); }

static PrivateClickMeasurement makeClick(Random& random, bool validSites = true)
{
    URL source { makeString("https://"_s, hosts()[random.below(hosts().size())]) };
    URL destination { makeString("https://"_s, hosts()[random.below(hosts().size())]) };
    if (!validSites)
        source = { };
    return PrivateClickMeasurement { static_cast<PrivateClickMeasurement::SourceID>(random.below(256)), PCM::SourceSite { source }, PCM::AttributionDestinationSite { destination }, "test.bundle.identifier"_s, clickTime(), PCM::AttributionEphemeral::No };
}

static PCM::AttributionTriggerData makeTrigger(unsigned data, unsigned priority)
{
    PCM::AttributionTriggerData trigger { };
    trigger.data = data;
    trigger.priority = priority;
    return trigger;
}

static void digestClick(Digest& digest, const PrivateClickMeasurement& click)
{
    digest.add(click.attributionReportClickSourceURL());
    digest.add(click.attributionReportClickDestinationURL());
    digest.add(click.attributionReportJSON()->toJSONString());
    auto times = click.timesToSend();
    digest.add(times.sourceEarliestTimeToSend.has_value());
    digest.add(times.destinationEarliestTimeToSend.has_value());
    digest.add(click.attributionTriggerData().has_value());
}

} // namespace PCMBench

using namespace PCMBench;

// MARK: - Accepted trigger URLs

// The empty test: the cost of starting the process, which every test pays.
TEST(PrivateClickMeasurementBench, StartUp)
{
}

TEST(PrivateClickMeasurementBench, ParseAcceptData)
{
    Random random;
    Inputs inputs;
    for (unsigned i = 0; i < 2000; ++i)
        inputs.add(makeString(triggerBase(random), twoDigits(random.below(16))));
    run("ParseAcceptData"_s, 0x2649c75b2bb802ef, inputs.bytes, 10109, [&] {
        return parsePass(inputs);
    });
}

TEST(PrivateClickMeasurementBench, ParseAcceptDataPriority)
{
    Random random;
    Inputs inputs;
    for (unsigned i = 0; i < 2000; ++i)
        inputs.add(makeString(triggerBase(random), twoDigits(random.below(16)), '/', twoDigits(random.below(64))));
    run("ParseAcceptDataPriority"_s, 0x0dc831ae5f3f3efb, inputs.bytes, 9531, [&] {
        return parsePass(inputs);
    });
}

TEST(PrivateClickMeasurementBench, ParseAcceptQuery)
{
    Random random;
    Inputs inputs;
    for (unsigned i = 0; i < 2000; ++i) {
        auto path = makeString(triggerBase(random), twoDigits(random.below(16)), '/', twoDigits(random.below(64)));
        auto source = makeString("attributionSource=https%3A%2F%2F"_s, hosts()[random.below(hosts().size())]);
        auto destinationNonce = makeString("attributionDestinationNonce="_s, nonce(random));
        switch (random.below(4)) {
        case 0:
            inputs.add(makeString(path, '?', source));
            break;
        case 1:
            inputs.add(makeString(path, '?', destinationNonce));
            break;
        case 2:
            inputs.add(makeString(path, '?', source, '&', destinationNonce));
            break;
        default:
            inputs.add(makeString(path, '?', destinationNonce, '&', source));
            break;
        }
    }
    run("ParseAcceptQuery"_s, 0x4232ad74b189bc9c, inputs.bytes, 1001, [&] {
        return parsePass(inputs);
    });
}

// MARK: - Rejected trigger URLs

TEST(PrivateClickMeasurementBench, ParseRejectPath)
{
    Random random;
    Inputs inputs;
    for (unsigned i = 0; i < 2000; ++i) {
        switch (random.below(4)) {
        case 0:
            inputs.add(makeString("https://"_s, hosts()[random.below(hosts().size())], "/other/path/"_s, twoDigits(random.below(16))));
            break;
        case 1:
            inputs.add(makeString("https://"_s, hosts()[random.below(hosts().size())], "/.well-known/private-click-measurement/report-attribution/"_s));
            break;
        case 2:
            inputs.add(makeString("https://"_s, hosts()[random.below(hosts().size())]));
            break;
        default:
            inputs.add(makeString("https://"_s, hosts()[random.below(hosts().size())], "/.well-known/private-click-measurement/trigger-attributio"_s));
            break;
        }
    }
    run("ParseRejectPath"_s, 0x30fc04014b9dd625, inputs.bytes, 26000, [&] {
        return parsePass(inputs);
    });
}

TEST(PrivateClickMeasurementBench, ParseRejectProtocolOrCredentials)
{
    Random random;
    Inputs inputs;
    for (unsigned i = 0; i < 2000; ++i) {
        auto data = twoDigits(random.below(16));
        auto host = hosts()[random.below(hosts().size())];
        auto rest = makeString(host, "/.well-known/private-click-measurement/trigger-attribution/"_s, data);
        switch (random.below(6)) {
        case 0:
            inputs.add(makeString("http://"_s, rest));
            break;
        case 1:
            inputs.add(makeString("wss://"_s, rest));
            break;
        case 2:
            inputs.add(makeString("https://user@"_s, rest));
            break;
        case 3:
            inputs.add(makeString("https://:pwd@"_s, rest));
            break;
        case 4:
            inputs.add(makeString("https://user:pwd@"_s, rest));
            break;
        default:
            inputs.add(makeString("https://"_s, rest, "#fragment"_s));
            break;
        }
    }
    run("ParseRejectProtocolOrCredentials"_s, 0xd1ca81d10e708c25, inputs.bytes, 500, [&] {
        return parsePass(inputs);
    });
}

TEST(PrivateClickMeasurementBench, ParseRejectQueryString)
{
    Random random;
    Inputs inputs;
    for (unsigned i = 0; i < 2000; ++i) {
        auto path = makeString(triggerBase(random), twoDigits(random.below(16)));
        auto source = makeString("attributionSource=https%3A%2F%2F"_s, hosts()[random.below(hosts().size())]);
        auto destinationNonce = makeString("attributionDestinationNonce="_s, nonce(random));
        switch (random.below(12)) {
        case 0:
            inputs.add(makeString(path, '?'));
            break;
        case 1:
            inputs.add(makeString(path, "?extra=data"_s));
            break;
        case 2:
            inputs.add(makeString(path, '?', source, '&', destinationNonce, "&extra=data"_s));
            break;
        case 3:
            inputs.add(makeString(path, "?attributionSource="_s));
            break;
        case 4:
            inputs.add(makeString(path, '?', source, '&', source));
            break;
        case 5:
            inputs.add(makeString(path, "?attributionSource=https%3A%2F%2Fexample.com%2Fpath"_s));
            break;
        case 6:
            inputs.add(makeString(path, "?attributionSource=https%3A%2F%2Fuser%40example.com"_s));
            break;
        case 7:
            inputs.add(makeString(path, "?attributionSource=not-a-url"_s));
            break;
        case 8:
            inputs.add(makeString(path, "?attributionSource=https%3A%2F%2Flocalhost"_s));
            break;
        case 9:
            inputs.add(makeString(path, "?attributionDestinationNonce="_s));
            break;
        case 10:
            inputs.add(makeString(path, '?', destinationNonce, '&', destinationNonce));
            break;
        default:
            inputs.add(makeString(path, "?attributionSource=https%3A%2F%2Fexample.com%3Fa%3Db"_s));
            break;
        }
    }
    run("ParseRejectQueryString"_s, 0x98f97d5bb336db83, inputs.bytes, 450, [&] {
        return parsePass(inputs);
    });
}

TEST(PrivateClickMeasurementBench, ParseRejectDataValue)
{
    Random random;
    Inputs inputs;
    for (unsigned i = 0; i < 2000; ++i) {
        String data;
        switch (random.below(3)) {
        case 0:
            data = twoDigits(16 + random.below(84));
            break;
        case 1:
            data = makeString(random.below(10), static_cast<char>('a' + random.below(26)));
            break;
        default:
            data = makeString('-', random.below(10));
            break;
        }
        if (random.below(2))
            inputs.add(makeString(triggerBase(random), data));
        else
            inputs.add(makeString(triggerBase(random), data, '/', twoDigits(random.below(64))));
    }
    run("ParseRejectDataValue"_s, 0x337a9fdad61a7b25, inputs.bytes, 500, [&] {
        return parsePass(inputs);
    });
}

TEST(PrivateClickMeasurementBench, ParseRejectPriorityValue)
{
    Random random;
    Inputs inputs;
    for (unsigned i = 0; i < 2000; ++i) {
        String priority;
        switch (random.below(3)) {
        case 0:
            priority = twoDigits(64 + random.below(36));
            break;
        case 1:
            priority = makeString(random.below(10), static_cast<char>('a' + random.below(26)));
            break;
        default:
            priority = makeString('-', random.below(10));
            break;
        }
        inputs.add(makeString(triggerBase(random), twoDigits(random.below(16)), '/', priority));
    }
    run("ParseRejectPriorityValue"_s, 0xd6de4e9fa1d36125, inputs.bytes, 503, [&] {
        return parsePass(inputs);
    });
}

TEST(PrivateClickMeasurementBench, ParseRejectPathParts)
{
    Random random;
    Inputs inputs;
    for (unsigned i = 0; i < 2000; ++i) {
        auto base = triggerBase(random);
        auto data = twoDigits(random.below(16));
        auto priority = twoDigits(random.below(64));
        switch (random.below(7)) {
        case 0:
            inputs.add(makeString(base, random.below(10)));
            break;
        case 1:
            inputs.add(makeString(base, data, '/', random.below(10)));
            break;
        case 2:
            inputs.add(makeString(base, '/', data, '/', priority));
            break;
        case 3:
            inputs.add(makeString(base, data, '/', priority, '/'));
            break;
        case 4:
            inputs.add(makeString(base, data, '/', priority, "/extra"_s));
            break;
        case 5:
            inputs.add(makeString(base, data, priority));
            break;
        default:
            inputs.add(makeString(base, random.below(10), data));
            break;
        }
    }
    run("ParseRejectPathParts"_s, 0x3a21d64afa7a7a25, inputs.bytes, 667, [&] {
        return parsePass(inputs);
    });
}

// MARK: - Attribution and validity

static uint64_t attributionBytes(unsigned count) { return static_cast<uint64_t>(count) * 160; }

// An attribution with no prior one, made valid and invalid.
TEST(PrivateClickMeasurementBench, AttributeFirst)
{
    constexpr unsigned count = 1000;
    run("AttributeFirst"_s, 0xf4de5d7fa685a1f2, attributionBytes(count), 335, [&] {
        Random random;
        Digest digest;
        for (unsigned i = 0; i < count; ++i) {
            auto click = makeClick(random);
            digest.add(click.attributeAndGetEarliestTimeToSend(makeTrigger(random.below(16), random.below(64)), PrivateClickMeasurement::IsRunningLayoutTest::No).sourceSeconds.has_value());
            digestClick(digest, click);
        }
        return digest.value();
    });
}

// A second attribution on a click that has one: higher, equal and lower priority.
TEST(PrivateClickMeasurementBench, AttributeWithPrior)
{
    constexpr unsigned count = 1000;
    run("AttributeWithPrior"_s, 0xe870f55bead8e7f9, attributionBytes(count), 335, [&] {
        Random random;
        Digest digest;
        for (unsigned i = 0; i < count; ++i) {
            auto click = makeClick(random);
            click.attributeAndGetEarliestTimeToSend(makeTrigger(random.below(16), random.below(64)), PrivateClickMeasurement::IsRunningLayoutTest::Yes);
            auto result = click.attributeAndGetEarliestTimeToSend(makeTrigger(random.below(16), random.below(64)), PrivateClickMeasurement::IsRunningLayoutTest::Yes);
            digest.add(result.sourceSeconds.has_value());
            digestClick(digest, click);
        }
        return digest.value();
    });
}

// Trigger data or priority out of range in three of four attributions, and a third of the clicks with no source site.
TEST(PrivateClickMeasurementBench, AttributeInvalid)
{
    constexpr unsigned count = 1000;
    run("AttributeInvalid"_s, 0xf42150c43be71016, attributionBytes(count), 1095, [&] {
        Random random;
        Digest digest;
        for (unsigned i = 0; i < count; ++i) {
            auto click = makeClick(random, random.below(3));
            auto result = click.attributeAndGetEarliestTimeToSend(makeTrigger(random.below(2) ? 16 + random.below(200) : random.below(16), random.below(2) ? 64 + random.below(190) : random.below(64)), PrivateClickMeasurement::IsRunningLayoutTest::No);
            digest.add(result.sourceSeconds.has_value());
            digestClick(digest, click);
            digest.add(click.hasPreviouslyBeenReported());
        }
        return digest.value();
    });
}

TEST(PrivateClickMeasurementBench, HigherPriority)
{
    constexpr unsigned count = 200;
    Random setupRandom;
    Vector<PrivateClickMeasurement> clicks;
    for (unsigned i = 0; i < count; ++i) {
        auto click = makeClick(setupRandom);
        if (setupRandom.below(5))
            click.attributeAndGetEarliestTimeToSend(makeTrigger(setupRandom.below(16), setupRandom.below(64)), PrivateClickMeasurement::IsRunningLayoutTest::Yes);
        clicks.append(WTF::move(click));
    }
    run("HigherPriority"_s, 0x48d72bebf88e0be6, static_cast<uint64_t>(count) * count, 3904, [&] {
        Digest digest;
        for (auto& a : clicks) {
            for (auto& b : clicks)
                digest.add(a.hasHigherPriorityThan(b));
        }
        return digest.value();
    });
}

TEST(PrivateClickMeasurementBench, TriggerSiteCheck)
{
    constexpr unsigned count = 2000;
    Random setupRandom;
    Vector<PCM::AttributionTriggerData> triggers;
    Vector<RegistrableDomain> redirectDomains;
    Vector<URL> firstParties;
    for (unsigned i = 0; i < count; ++i) {
        auto trigger = makeTrigger(setupRandom.below(16), setupRandom.below(64));
        if (setupRandom.below(2))
            trigger.sourceRegistrableDomain = RegistrableDomain { URL { makeString("https://"_s, hosts()[setupRandom.below(hosts().size())]) } };
        triggers.append(WTF::move(trigger));
        redirectDomains.append(RegistrableDomain { URL { makeString("https://"_s, hosts()[setupRandom.below(hosts().size())]) } });
        firstParties.append(URL { makeString("https://"_s, hosts()[setupRandom.below(hosts().size())], "/page"_s) });
    }
    run("TriggerSiteCheck"_s, 0xfc7727eda49ee686, static_cast<uint64_t>(count) * 40, 1422, [&] {
        Random random;
        Digest digest;
        for (unsigned i = 0; i < count; ++i) {
            auto click = makeClick(random);
            digest.add(click.isNeitherSameSiteNorCrossSiteTriggeringEvent(redirectDomains[i], firstParties[i], triggers[i]));
        }
        return digest.value();
    });
}

// MARK: - Report and token JSON and URLs

static Vector<PrivateClickMeasurement> reportedClicks(unsigned count)
{
    Random random;
    Vector<PrivateClickMeasurement> clicks;
    for (unsigned i = 0; i < count; ++i) {
        auto click = makeClick(random);
        auto trigger = makeTrigger(random.below(16), random.below(64));
        if (random.below(2))
            trigger.destinationSecretToken = PCM::DestinationSecretToken { { "destinationToken"_s, "destinationSignature"_s, "destinationKeyID"_s } };
        click.attributeAndGetEarliestTimeToSend(WTF::move(trigger), PrivateClickMeasurement::IsRunningLayoutTest::Yes);
        if (random.below(2))
            click.setSourceSecretToken(PCM::SourceSecretToken { { "sourceToken"_s, "sourceSignature"_s, "sourceKeyID"_s } });
        clicks.append(WTF::move(click));
    }
    return clicks;
}

TEST(PrivateClickMeasurementBench, ReportJSON)
{
    constexpr unsigned count = 2000;
    auto clicks = reportedClicks(count);
    run("ReportJSON"_s, 0xf7aa453b798dbcc8, static_cast<uint64_t>(count) * 220, 259, [&] {
        Digest digest;
        for (auto& click : clicks)
            digest.add(click.attributionReportJSON()->toJSONString());
        return digest.value();
    });
}

TEST(PrivateClickMeasurementBench, TokenJSON)
{
    constexpr unsigned count = 2000;
    Random setupRandom;
    Vector<PrivateClickMeasurement> clicks;
    Vector<PCM::AttributionTriggerData> triggers;
    for (unsigned i = 0; i < count; ++i) {
        auto click = makeClick(setupRandom);
        if (setupRandom.below(4))
            click.setEphemeralSourceNonce(PCM::EphemeralNonce { nonce(setupRandom) });
        if (setupRandom.below(4))
            click.setSourceUnlinkableTokenValue(base64URLEncodeToString(std::span<const uint8_t> { reinterpret_cast<const uint8_t*>("0123456789abcdef0123456789abcdef"), 32 }));
        clicks.append(WTF::move(click));

        auto trigger = makeTrigger(setupRandom.below(16), setupRandom.below(64));
        if (setupRandom.below(4))
            trigger.ephemeralDestinationNonce = PCM::EphemeralNonce { nonce(setupRandom) };
        if (setupRandom.below(4))
            trigger.setDestinationUnlinkableTokenValue("destinationUnlinkableTokenValue"_s);
        triggers.append(WTF::move(trigger));
    }
    run("TokenJSON"_s, 0xf5e8ab96d8fe945a, static_cast<uint64_t>(count) * 200, 328, [&] {
        Digest digest;
        for (unsigned i = 0; i < count; ++i) {
            digest.add(clicks[i].tokenSignatureJSON()->toJSONString());
            digest.add(triggers[i].tokenSignatureJSON()->toJSONString());
        }
        return digest.value();
    });
}

TEST(PrivateClickMeasurementBench, URLs)
{
    constexpr unsigned count = 2000;
    Random setupRandom;
    Vector<PrivateClickMeasurement> clicks;
    Vector<RegistrableDomain> domains;
    for (unsigned i = 0; i < count; ++i) {
        auto click = makeClick(setupRandom, setupRandom.below(5));
        if (setupRandom.below(2))
            click.setEphemeralSourceNonce(PCM::EphemeralNonce { nonce(setupRandom) });
        click.attributeAndGetEarliestTimeToSend(makeTrigger(setupRandom.below(16), setupRandom.below(64)), PrivateClickMeasurement::IsRunningLayoutTest::Yes);
        clicks.append(WTF::move(click));
        domains.append(setupRandom.below(5) ? RegistrableDomain { URL { makeString("https://"_s, hosts()[setupRandom.below(hosts().size())]) } } : RegistrableDomain { });
    }
    run("URLs"_s, 0xcb99674fff708d2b, static_cast<uint64_t>(count) * 300, 250, [&] {
        Digest digest;
        for (unsigned i = 0; i < count; ++i) {
            digest.add(clicks[i].attributionReportClickSourceURL());
            digest.add(clicks[i].attributionReportClickDestinationURL());
            digest.add(clicks[i].tokenPublicKeyURL());
            digest.add(clicks[i].tokenSignatureURL());
            digest.add(PrivateClickMeasurement::tokenPublicKeyURL(domains[i]));
            digest.add(PrivateClickMeasurement::tokenSignatureURL(domains[i]));
        }
        return digest.value();
    });
}

// MARK: - Nonce and secret token validity

TEST(PrivateClickMeasurementBench, NonceAndTokenValidity)
{
    constexpr unsigned count = 4000;
    Random setupRandom;
    Vector<String> nonces;
    Vector<PCM::SecretToken> tokens;
    uint64_t bytes = 0;
    for (unsigned i = 0; i < count; ++i) {
        String candidate = nonce(setupRandom);
        switch (setupRandom.below(6)) {
        case 0:
            candidate = candidate.left(18);
            break;
        case 1:
            candidate = makeString(candidate, "ABCDEFGHI"_s);
            break;
        case 2:
            candidate = makeString(candidate.left(11), '/', candidate.substring(12));
            break;
        case 3:
            candidate = makeString(candidate.left(11), static_cast<char16_t>(0xe5), candidate.substring(12));
            break;
        case 4:
            candidate = emptyString();
            break;
        default:
            break;
        }
        bytes += candidate.length();
        nonces.append(candidate);
        tokens.append(PCM::SecretToken { setupRandom.below(5) ? String { "token"_s } : emptyString(), setupRandom.below(5) ? String { "signature"_s } : emptyString(), setupRandom.below(5) ? String { "keyID"_s } : emptyString() });
    }
    run("NonceAndTokenValidity"_s, 0x0ffc8bf9ad253b45, bytes, 718, [&] {
        Digest digest;
        for (unsigned i = 0; i < count; ++i) {
            digest.add(PCM::EphemeralNonce { nonces[i] }.isValid());
            // PCM::SecretToken::isValid is not exported from WebCore, so TestWebKitAPI cannot call it.
            auto click = PrivateClickMeasurement { 0, PCM::SourceSite { URL { "https://webkit.org"_s } }, PCM::AttributionDestinationSite { URL { "https://example.com"_s } }, { }, clickTime(), PCM::AttributionEphemeral::No };
            click.setEphemeralSourceNonce(PCM::EphemeralNonce { nonces[i] });
            digest.add(click.ephemeralSourceNonce().has_value());
            click.setSourceSecretToken(PCM::SourceSecretToken { { tokens[i].tokenBase64URL, tokens[i].signatureBase64URL, tokens[i].keyIDBase64URL } });
            digest.add(click.sourceSecretToken().has_value());
        }
        return digest.value();
    });
}

// MARK: - Token crypto

#if HAVE(RSA_BSSA)

// One server key pair for the process, made before any pass is timed.
class ServerKey {
public:
    static ServerKey& singleton()
    {
        static NeverDestroyed<ServerKey> key;
        return key;
    }

    ServerKey()
        : m_privateKey((ccrsa_full_ctx_size(ccn_sizeof(modulusNBits)) + sizeof(uint64_t) - 1) / sizeof(uint64_t))
    {
    }

    const String& publicKeyBase64URL()
    {
        generate();
        return m_publicKeyBase64URL;
    }

    // Signs a blinded message as the server would, returning the response in base64URL.
    String sign(const String& blindedMessageBase64URL)
    {
        generate();
        auto blindedMessage = base64URLDecode(blindedMessageBase64URL);
        if (!blindedMessage)
            return { };
        Vector<uint8_t> signature(m_modulusNBytes);
        int error = 0;
        ccrsabssa_sign_blinded_message(&ccrsabssa_ciphersuite_rsa4096_sha384, privateKey(), blindedMessage->span().data(), blindedMessage->size(), signature.mutableSpan().data(), signature.size(), ccrng(&error));
        return base64URLEncodeToString(signature.span());
    }

private:
    static constexpr size_t modulusNBits = 4096;

    ccrsa_full_ctx_t privateKey() { return reinterpret_cast<ccrsa_full_ctx_t>(m_privateKey.mutableSpan().data()); }

    void generate()
    {
        if (m_generated)
            return;
        m_generated = true;
        int error = 0;
        auto* rng = ccrng(&error);
        EXPECT_EQ(error, CCERR_OK);
        const uint8_t e[] = { 0x1, 0x00, 0x01 };
        error = ccrsa_generate_key(modulusNBits, privateKey(), sizeof(e), e, rng);
        EXPECT_EQ(error, CCERR_OK);

        ccrsa_pub_ctx_t publicKey = ccrsa_ctx_public(privateKey());
        m_modulusNBytes = cc_ceiling(ccrsa_pubkeylength(publicKey), 8);
        size_t exportSize = ccder_encode_rsa_pub_size(publicKey);
        Vector<uint8_t> rawKeyBytes(exportSize);
        ccder_encode_rsa_pub(publicKey, rawKeyBytes.begin(), rawKeyBytes.end());
        auto wrappedKeyBytes = wrapPublicKeyWithRSAPSSOID(WTF::move(rawKeyBytes));
        m_publicKeyBase64URL = base64URLEncodeToString(wrappedKeyBytes);
    }

    Vector<uint64_t> m_privateKey;
    String m_publicKeyBase64URL;
    size_t m_modulusNBytes { 0 };
    bool m_generated { false };
};

static void digestOptionalError(Digest& digest, const std::optional<String>& error)
{
    // Some error texts are the platform's NSError descriptions, so only whether there is one is observed.
    digest.add(error.has_value());
}

static PrivateClickMeasurement cryptoClick()
{
    PrivateClickMeasurement click { 0, PCM::SourceSite { URL { "https://webkit.org"_s } }, PCM::AttributionDestinationSite { URL { "https://example.com"_s } }, { }, clickTime(), PCM::AttributionEphemeral::No };
    click.setEphemeralSourceNonce(PCM::EphemeralNonce { "ABCDEFabcdef0123456789"_s });
    return click;
}

TEST(PrivateClickMeasurementBench, CryptoUnlinkableToken)
{
    auto publicKey = ServerKey::singleton().publicKeyBase64URL();
    constexpr unsigned count = 4;
    run("CryptoUnlinkableToken"_s, 0xcf738032cfcc9ae5, static_cast<uint64_t>(count) * 2 * 683, 362, [&] {
        Digest digest;
        for (unsigned i = 0; i < count; ++i) {
            auto click = cryptoClick();
            digestOptionalError(digest, click.calculateAndUpdateSourceUnlinkableToken(publicKey));
            // The blinded message is random; its length and the JSON's shape are not.
            digest.add(static_cast<uint64_t>(click.sourceUnlinkableToken().valueBase64URL.length()));
            digest.add(static_cast<uint64_t>(click.tokenSignatureJSON()->size()));
            auto destination = PrivateClickMeasurement::calculateAndUpdateDestinationUnlinkableToken(publicKey);
            digest.add(destination.has_value());
            if (destination)
                digest.add(static_cast<uint64_t>(destination->valueBase64URL.length()));
        }
        return digest.value();
    });
}

TEST(PrivateClickMeasurementBench, CryptoRejectPublicKey)
{
    constexpr unsigned count = 200;
    auto validKey = ServerKey::singleton().publicKeyBase64URL();
    Vector<String> keys { String { }, emptyString(), "!!!not base64!!!"_s, "AAAA"_s, validKey.left(validKey.length() / 2), makeString(validKey.left(100), "AAAA"_s, validKey.substring(104)) };
    uint64_t bytes = 0;
    for (auto& key : keys)
        bytes += key.length();
    run("CryptoRejectPublicKey"_s, 0x652c2e3eb13d7e25, bytes * count, 61, [&] {
        Digest digest;
        for (unsigned i = 0; i < count; ++i) {
            for (auto& key : keys) {
                auto click = cryptoClick();
                digestOptionalError(digest, click.calculateAndUpdateSourceUnlinkableToken(key));
                digest.add(static_cast<uint64_t>(click.tokenSignatureJSON()->size()));
                digest.add(PrivateClickMeasurement::calculateAndUpdateDestinationUnlinkableToken(key).has_value());
            }
        }
        return digest.value();
    });
}

TEST(PrivateClickMeasurementBench, CryptoSecretTokenAccept)
{
    auto& server = ServerKey::singleton();
    auto publicKey = server.publicKeyBase64URL();
    constexpr unsigned count = 4;
    run("CryptoSecretTokenAccept"_s, 0x838638f100354d35, static_cast<uint64_t>(count) * 2 * 683 * 2, 27, [&] {
        Digest digest;
        for (unsigned i = 0; i < count; ++i) {
            auto click = cryptoClick();
            digestOptionalError(digest, click.calculateAndUpdateSourceUnlinkableToken(publicKey));
            digestOptionalError(digest, click.calculateAndUpdateSourceSecretToken(server.sign(click.sourceUnlinkableToken().valueBase64URL)));
            auto& token = click.sourceSecretToken();
            digest.add(token.has_value());
            if (token) {
                digest.add(static_cast<uint64_t>(token->tokenBase64URL.length()));
                digest.add(static_cast<uint64_t>(token->keyIDBase64URL.length()));
                digest.add(static_cast<uint64_t>(token->signatureBase64URL.length()));
            }

            auto destination = PrivateClickMeasurement::calculateAndUpdateDestinationUnlinkableToken(publicKey);
            digest.add(destination.has_value());
            if (!destination)
                continue;
            auto secret = PrivateClickMeasurement::calculateAndUpdateDestinationSecretToken(server.sign(destination->valueBase64URL), *destination);
            digest.add(secret.has_value());
            if (secret) {
                digest.add(static_cast<uint64_t>(secret->tokenBase64URL.length()));
                digest.add(static_cast<uint64_t>(secret->keyIDBase64URL.length()));
                digest.add(static_cast<uint64_t>(secret->signatureBase64URL.length()));
            }
        }
        return digest.value();
    });
}

TEST(PrivateClickMeasurementBench, CryptoSecretTokenReject)
{
    auto& server = ServerKey::singleton();
    auto publicKey = server.publicKeyBase64URL();
    constexpr unsigned count = 4;

    // One unlinkable token and its genuine response, to damage.
    auto prepared = cryptoClick();
    EXPECT_FALSE(prepared.calculateAndUpdateSourceUnlinkableToken(publicKey));
    auto response = server.sign(prepared.sourceUnlinkableToken().valueBase64URL);
    Vector<String> responses { String { }, emptyString(), "!!!not base64!!!"_s, "AAAA"_s, response.left(response.length() / 2), makeString(response.left(40), "AAAA"_s, response.substring(44)) };
    uint64_t bytes = 0;
    for (auto& candidate : responses)
        bytes += candidate.length();

    run("CryptoSecretTokenReject"_s, 0xd567b1aa92abfa25, bytes * count, 116, [&] {
        Digest digest;
        for (unsigned i = 0; i < count; ++i) {
            // No waiting token yet.
            auto unprepared = cryptoClick();
            digestOptionalError(digest, unprepared.calculateAndUpdateSourceSecretToken(response));
            digest.add(unprepared.sourceSecretToken().has_value());
            for (auto& candidate : responses) {
                auto click = cryptoClick();
                digestOptionalError(digest, click.calculateAndUpdateSourceUnlinkableToken(publicKey));
                digestOptionalError(digest, click.calculateAndUpdateSourceSecretToken(candidate));
                digest.add(click.sourceSecretToken().has_value());
            }
        }
        return digest.value();
    });
}

#endif // HAVE(RSA_BSSA)

} // namespace TestWebKitAPI
