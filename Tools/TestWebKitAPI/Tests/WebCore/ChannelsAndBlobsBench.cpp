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

// Speed of the network process's message-port registry, its blob registry and blob loads, and data: URL decoding,
// one test per workload, through the entry points the network process calls: MessagePortChannelRegistry's members,
// BlobRegistryImpl's members (asynchronous blob loads through BlobRegistryImpl::createResourceHandle, which runs the
// same BlobResourceHandleBase state machine as the network process's blob data task; synchronous loads through
// ResourceHandle::loadResourceSynchronously, which reaches the registry the platform strategies hold), and
// DataURLDecoder::decode.
//
// Each pass runs the workload's operations on deterministic inputs and feeds every observable result (return values,
// sizes, types, response status and headers, bytes read, error codes, decoded data) to an FNV-1a digest. Identifier
// values and file paths are never hashed, so the digest does not depend on the process. By default a test runs one
// pass and EXPECT_EQs the digest against the workload's recorded checksum. With WEBKIT_RUN_BENCHMARKS set it then runs
// the workload's fixed number of passes (Passes::, sized so the passes take a second or more), checks every pass's
// digest, and prints
//     <Test>: <ms> ms <n> MB/s checksum=<digest>
// where <n> counts the bytes the timed operations carried (message and blob bytes, encoded data: URL bytes, and for
// the registry workloads 16 bytes per port identifier passed). Set-up and tear-down inside a pass (writing and deleting
// files, building inputs) is measured and left out of the printed time. The number of passes never depends on time,
// so every build does the same work and a whole-process cycle count compares them.
//
// Everything runs on the main thread, as the registries require; blob loads and IndexedDB file writes hop through the
// main run loop, which each operation spins until its completion handler has run.
//
// Inputs that crash the C++ are left out and named where they would be: a suffix range of zero bytes
// ("Range: bytes=-0") overflows a Checked<uint64_t> in the range computation.

#include "config.h"

#include "Helpers/Test.h"
#include "Helpers/Utilities.h"
#include "TestPlatformStrategies.h"
#include <WebCore/BlobDataFileReference.h>
#include <WebCore/BlobPart.h>
#include <WebCore/BlobRegistry.h>
#include <WebCore/BlobRegistryImpl.h>
#include <WebCore/DataURLDecoder.h>
#include <WebCore/HTTPHeaderNames.h>
#include <WebCore/MessagePortChannel.h>
#include <WebCore/MessagePortChannelRegistry.h>
#include <WebCore/MessagePortIdentifier.h>
#include <WebCore/MessageWithMessagePorts.h>
#include <WebCore/NetworkLoadMetrics.h>
#include <WebCore/PolicyContainer.h>
#include <WebCore/ProcessIdentifier.h>
#include <WebCore/ResourceError.h>
#include <WebCore/ResourceHandle.h>
#include <WebCore/ResourceHandleClient.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/SecurityOriginData.h>
#include <WebCore/SerializedScriptValue.h>
#include <WebCore/SharedBuffer.h>
#include <WebCore/StoredCredentialsPolicy.h>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <wtf/CompletionHandler.h>
#include <wtf/FileHandle.h>
#include <wtf/FileSystem.h>
#include <wtf/HashMap.h>
#include <wtf/HexNumber.h>
#include <wtf/MonotonicTime.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/Seconds.h>
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>
#include <wtf/text/Base64.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

namespace TestWebKitAPI {

using namespace WebCore;

namespace ChannelsAndBlobsBenchmark {

// Each workload's expected checksum, the digest of one pass. A mismatch fails the test and prints the checksum
// ("<Test>: checksum=<digest> (recorded <value>)"). Recorded from the first run of the C++ build.
namespace Recorded {
constexpr uint64_t registerDataSmall = 0xae307c61b590292c;
constexpr uint64_t registerDataLarge = 0x2e8f10b922afe46c;
constexpr uint64_t registerMultipart = 0x75988369d52a34ea;
constexpr uint64_t registerNoFileDirectory = 0x8356643fc8826425;
constexpr uint64_t sliceChain = 0x7811147a4b4d5692;
constexpr uint64_t resolveHit = 0x57285f5e2af1a325;
constexpr uint64_t resolveMiss = 0x90f118f27830ae65;
constexpr uint64_t resolveWrongTopOrigin = 0x543f689bc3812325;
constexpr uint64_t sizeAndType = 0x7523e0dc872a71a5;
constexpr uint64_t handleRefcount = 0x0f60ca7cb7c5bfad;
constexpr uint64_t unregisterMix = 0xafa1bcc916f62928;
constexpr uint64_t rangeReadSmall = 0x4717a5256ab16c45;
constexpr uint64_t rangeReadSuffix = 0x4561bf6faad12ba7;
constexpr uint64_t fullRead1MiB = 0x0e37442a6fece4eb;
constexpr uint64_t rangeError = 0xc0905e281a654f05;
constexpr uint64_t methodNotAllowed = 0x13615d4e21493d4d;
constexpr uint64_t notFound = 0xe579dc0757867aa5;
constexpr uint64_t dataURLBase64_1K = 0xf1011444ab5d7f25;
constexpr uint64_t dataURLBase64_64K = 0x4ec8c58bf05e5b65;
constexpr uint64_t dataURLPercent_4K = 0x81438acff6e6bf25;
constexpr uint64_t dataURLMalformed = 0xd241b7e20ec10025;
constexpr uint64_t portLifecycle = 0xcced39bacadd9805;
constexpr uint64_t portTransferClaim = 0xa5a6b6a0c48bf384;
constexpr uint64_t portPostTake = 0x1c8810a9485db736;
constexpr uint64_t mappingFileDrain = 0xf34c100100044834;
constexpr uint64_t portErrorPaths = 0x116742c900844465;
constexpr uint64_t sliceBounds = 0x4d68f7883406d693;
constexpr uint64_t fullReadAsync = 0xbc60b924f5fa263d;
constexpr uint64_t rangeReadBoundaries = 0x3fa6e37220c04943;
constexpr uint64_t fileRead = 0x3bc9722a2c6fa790;
constexpr uint64_t writeForIndexedDB = 0x7e110516f6995121;
constexpr uint64_t dataURLBase64Mix = 0x0f044581072218d5;
constexpr uint64_t dataURLPercentMix = 0xcb288e47238ae425;
constexpr uint64_t realisticMix = 0x86765e99af67a0fd;
}

// Each workload's number of passes under WEBKIT_RUN_BENCHMARKS, calibrated from the C++ build's cycle counts on an
// Apple M3 so each workload's process takes about a second and a half. The checksum is one pass's digest, so it does
// not depend on a count. A count never changes after this.
namespace Passes {
constexpr unsigned registerDataSmall = 4;
constexpr unsigned registerDataLarge = 120;
constexpr unsigned registerMultipart = 700;
constexpr unsigned registerNoFileDirectory = 1800;
constexpr unsigned sliceChain = 560;
constexpr unsigned resolveHit = 270;
constexpr unsigned resolveMiss = 580;
constexpr unsigned resolveWrongTopOrigin = 80;
constexpr unsigned sizeAndType = 500;
constexpr unsigned handleRefcount = 420;
constexpr unsigned unregisterMix = 800;
constexpr unsigned rangeReadSmall = 300;
constexpr unsigned rangeReadSuffix = 270;
constexpr unsigned fullRead1MiB = 150;
constexpr unsigned rangeError = 1100;
constexpr unsigned methodNotAllowed = 520;
constexpr unsigned notFound = 530;
constexpr unsigned dataURLBase64_1K = 460;
constexpr unsigned dataURLBase64_64K = 140;
constexpr unsigned dataURLPercent_4K = 130;
constexpr unsigned dataURLMalformed = 60;
constexpr unsigned portLifecycle = 2900;
constexpr unsigned portTransferClaim = 90;
constexpr unsigned portPostTake = 18;
constexpr unsigned mappingFileDrain = 80;
constexpr unsigned portErrorPaths = 1300;
constexpr unsigned sliceBounds = 210;
constexpr unsigned fullReadAsync = 40;
constexpr unsigned rangeReadBoundaries = 260;
constexpr unsigned fileRead = 150;
constexpr unsigned writeForIndexedDB = 120;
constexpr unsigned dataURLBase64Mix = 32;
constexpr unsigned dataURLPercentMix = 45;
constexpr unsigned realisticMix = 170;
}

// Inputs and digest.

class Random {
public:
    explicit Random(uint64_t seed)
        : m_state(seed)
    {
    }

    unsigned below(unsigned bound)
    {
        m_state = m_state * 6364136223846793005ULL + 1442695040888963407ULL;
        return static_cast<unsigned>(m_state >> 33) % bound;
    }

private:
    uint64_t m_state;
};

class Digest {
public:
    void addByte(uint8_t byte)
    {
        m_value ^= byte;
        m_value *= 0x100000001b3ULL;
    }

    void addInteger(uint64_t value)
    {
        for (unsigned i = 0; i < 8; ++i)
            addByte(static_cast<uint8_t>(value >> (i * 8)));
    }

    void addBool(bool value) { addByte(value ? 1 : 0); }

    void addBytes(std::span<const uint8_t> bytes)
    {
        addInteger(bytes.size());
        for (auto byte : bytes)
            addByte(byte);
    }

    // Code units, so an 8-bit and a 16-bit string with the same code units agree; a null string differs from an empty one.
    void addString(const String& string)
    {
        addBool(string.isNull());
        addInteger(string.length());
        for (unsigned i = 0; i < string.length(); ++i)
            addInteger(string[i]);
    }

    uint64_t value() const { return m_value; }

private:
    uint64_t m_value { 0xcbf29ce484222325ULL };
};

// Time spent inside a pass that the pass leaves out of its timed total.
class Excluded {
public:
    template<typename Function>
    void measure(const Function& function)
    {
        auto start = MonotonicTime::now();
        function();
        m_total += MonotonicTime::now() - start;
    }

    Seconds total() const { return m_total; }

private:
    Seconds m_total;
};

static Vector<uint8_t> generatePatternBytes(size_t size, uint64_t seed)
{
    Random random(seed);
    Vector<uint8_t> bytes;
    bytes.reserveInitialCapacity(size);
    for (size_t i = 0; i < size; ++i)
        bytes.append(static_cast<uint8_t>(random.below(256)));
    return bytes;
}

// A copy of the deterministic bytes for (size, seed). Inputs of 512 bytes or more are generated once per process, so
// a pass after the first copies them instead of running the generator, whose cycles a whole-process count would
// otherwise add to every pass. The key is never HashMap's empty or deleted value: size is at least 512 and below
// UINT64_MAX.
static Vector<uint8_t> patternBytes(size_t size, uint64_t seed)
{
    if (size < 512)
        return generatePatternBytes(size, seed);
    static NeverDestroyed<HashMap<std::pair<uint64_t, uint64_t>, Vector<uint8_t>>> cache;
    return cache->ensure({ size, seed }, [&] {
        return generatePatternBytes(size, seed);
    }).iterator->value;
}

// Construction. These are the only places the tests make a registry. Both registries are reference-counted and made
// with create(), as the network process makes them.

static Ref<MessagePortChannelRegistry> makeMessagePortChannelRegistry()
{
    return MessagePortChannelRegistry::create();
}

static Ref<BlobRegistryImpl> makeBlobRegistry()
{
    return BlobRegistryImpl::create();
}

// The harness.

// `pass(digest, excluded)` returns the bytes its timed operations carried. `passes` is the workload's Passes:: count.
template<typename Pass>
static void run(ASCIILiteral name, uint64_t recorded, unsigned passes, const Pass& pass)
{
    Digest digest;
    Excluded excluded;
    pass(digest, excluded);
    auto checksum = digest.value();
    EXPECT_EQ(recorded, checksum);
    if (recorded != checksum)
        SAFE_PRINTF("%s: checksum=%016llx (recorded %016llx)\n", name, static_cast<unsigned long long>(checksum), static_cast<unsigned long long>(recorded));
    auto* benchmarks = getenv("WEBKIT_RUN_BENCHMARKS");
    if (!benchmarks || !*benchmarks || *benchmarks == '0')
        return;

    Seconds timed;
    double totalBytes = 0;
    unsigned mismatches = 0;
    for (unsigned i = 0; i < passes; ++i) {
        Digest passDigest;
        Excluded passExcluded;
        auto start = MonotonicTime::now();
        size_t passBytes = pass(passDigest, passExcluded);
        timed += (MonotonicTime::now() - start) - passExcluded.total();
        totalBytes += passBytes;
        mismatches += passDigest.value() != checksum;
    }
    EXPECT_EQ(0u, mismatches);
    SAFE_PRINTF("%s: %.1f ms %.3f MB/s checksum=%016llx\n", name, timed.milliseconds(),
        totalBytes / timed.microseconds(), static_cast<unsigned long long>(checksum));
    fflush(stdout);
}

// Message ports.

constexpr size_t identifierBytes = 16;

static MessagePortIdentifier portIdentifier(uint64_t process, uint64_t port)
{
    return { ProcessIdentifier(process), PortIdentifier(port) };
}

static void addChannelState(Digest& digest, MessagePortChannelRegistry& registry, const MessagePortIdentifier& port)
{
    // Only whether the registry still has a channel for the port: the channel's members are the implementation's.
    digest.addBool(!!registry.existingChannelContainingPort(port));
}

// Message bodies of every size class, made once per process outside any pass.
static const Vector<Ref<SerializedScriptValue>>& messageBodies()
{
    static NeverDestroyed<Vector<Ref<SerializedScriptValue>>> bodies([] {
        Vector<Ref<SerializedScriptValue>> result;
        uint64_t seed = 1;
        for (size_t size : { 0, 1, 15, 16, 17, 100, 1000, 4096, 65536 })
            result.append(SerializedScriptValue::createFromWireBytes(patternBytes(size, seed++)));
        return result;
    }());
    return bodies.get();
}

// Takes every message waiting for `port`, adds each message's bytes and transferred ports, and runs the batch's
// completion. Returns the bytes taken.
static size_t takeAll(Digest& digest, MessagePortChannelRegistry& registry, const MessagePortIdentifier& port, Vector<TransferredMessagePort>* transferred = nullptr)
{
    bool taken = false;
    size_t bytes = 0;
    registry.takeAllMessagesForPort(port, [&](Vector<MessageWithMessagePorts>&& messages, CompletionHandler<void()>&& completion) {
        digest.addInteger(messages.size());
        for (auto& message : messages) {
            digest.addBool(!!message.message);
            if (message.message) {
                digest.addBytes(message.message->wireBytes().span());
                bytes += message.message->wireBytes().size();
            }
            digest.addInteger(message.transferredPorts.size());
            if (transferred)
                transferred->appendVector(message.transferredPorts);
        }
        completion();
        taken = true;
    });
    if (!taken)
        Util::run(&taken);
    return bytes;
}

// Channels made, entangled, disentangled, re-entangled and closed in four orders; every step's effect on the registry.
static size_t messagePortCreateClose(Digest& digest, Excluded&)
{
    constexpr unsigned channelCount = 4000;
    auto registry = makeMessagePortChannelRegistry();
    size_t operations = 0;
    for (unsigned i = 0; i < channelCount; ++i) {
        auto port1 = portIdentifier(1, 2 * i + 1);
        auto port2 = portIdentifier(2, 2 * i + 2);
        registry->didCreateMessagePortChannel(port1, port2);
        addChannelState(digest, registry.get(), port1);
        addChannelState(digest, registry.get(), port2);
        switch (i % 4) {
        case 0:
            registry->didEntangleLocalToRemote(port1, port2, ProcessIdentifier(1));
            registry->didEntangleLocalToRemote(port2, port1, ProcessIdentifier(2));
            registry->didCloseMessagePort(port1, MessagePortStatus::Closed);
            addChannelState(digest, registry.get(), port2);
            registry->didCloseMessagePort(port2, MessagePortStatus::Closed);
            operations += 6;
            break;
        case 1:
            // An unclaimed port is claimed again by its process.
            registry->didCloseMessagePort(port2, MessagePortStatus::Unclaimed);
            addChannelState(digest, registry.get(), port2);
            registry->didEntangleLocalToRemote(port2, port1, ProcessIdentifier(3));
            registry->didCloseMessagePort(port1, MessagePortStatus::Closed);
            addChannelState(digest, registry.get(), port1);
            registry->didCloseMessagePort(port2, MessagePortStatus::Closed);
            operations += 8;
            break;
        case 2:
            // A port in transfer: disentangled, then entangled with another process.
            registry->didDisentangleMessagePort(port1);
            addChannelState(digest, registry.get(), port1);
            registry->didEntangleLocalToRemote(port1, port2, ProcessIdentifier(4));
            registry->didCloseMessagePort(port2, MessagePortStatus::Closed);
            registry->didCloseMessagePort(port1, MessagePortStatus::Closed);
            operations += 7;
            break;
        case 3:
            // Closing twice, and closing a port of a channel already gone.
            registry->didCloseMessagePort(port1, MessagePortStatus::Closed);
            registry->didCloseMessagePort(port1, MessagePortStatus::Closed);
            registry->didCloseMessagePort(port2, MessagePortStatus::Unclaimed);
            addChannelState(digest, registry.get(), port1);
            registry->didCloseMessagePort(port2, MessagePortStatus::Closed);
            operations += 6;
            break;
        }
        addChannelState(digest, registry.get(), port1);
        addChannelState(digest, registry.get(), port2);
    }
    return operations * identifierBytes;
}

// A scope that counts the times it ran in `count`.
static CompletionHandlerCallingScope countingScope(unsigned& count)
{
    return CompletionHandlerCallingScope { [&count] {
        ++count;
    } };
}

// Many live channels; messages of every size posted both ways in random batches, then taken. Carries pending messages
// and in-flight batches across calls.
static size_t messagePortPostTake(Digest& digest, Excluded&)
{
    constexpr unsigned channelCount = 64;
    constexpr unsigned roundCount = 60;
    auto& bodies = messageBodies();
    auto registry = makeMessagePortChannelRegistry();
    Random random(7);
    size_t bytes = 0;
    unsigned blobURLScopesRun = 0;

    for (unsigned i = 0; i < channelCount; ++i)
        registry->didCreateMessagePortChannel(portIdentifier(1, 2 * i + 1), portIdentifier(2, 2 * i + 2));

    for (unsigned round = 0; round < roundCount; ++round) {
        for (unsigned i = 0; i < channelCount; ++i) {
            auto target = random.below(4) ? portIdentifier(2, 2 * i + 2) : portIdentifier(1, 2 * i + 1);
            unsigned batch = random.below(6);
            for (unsigned m = 0; m < batch; ++m) {
                Ref body = bodies[random.below(bodies.size())];
                bytes += body->wireBytes().size();
                CompletionHandlerCallingScope blobURLsInFlight;
                if (!random.below(3))
                    blobURLsInFlight = countingScope(blobURLScopesRun);
                digest.addBool(registry->didPostMessageToRemote({ WTF::move(body), { } }, target, WTF::move(blobURLsInFlight)));
            }
        }
        for (unsigned i = 0; i < channelCount; ++i) {
            if (random.below(3))
                bytes += takeAll(digest, registry.get(), portIdentifier(2, 2 * i + 2));
            if (!random.below(4))
                bytes += takeAll(digest, registry.get(), portIdentifier(1, 2 * i + 1));
        }
        digest.addInteger(blobURLScopesRun);
    }

    // Closing a port drops what waits for it; the other side's messages are still taken.
    for (unsigned i = 0; i < channelCount; ++i) {
        registry->didCloseMessagePort(portIdentifier(2, 2 * i + 2), MessagePortStatus::Closed);
        bytes += takeAll(digest, registry.get(), portIdentifier(1, 2 * i + 1));
        registry->didCloseMessagePort(portIdentifier(1, 2 * i + 1), MessagePortStatus::Closed);
    }
    digest.addInteger(blobURLScopesRun);
    return bytes;
}

// Ports transferred in messages: origin and destination recorded and claimed (matching, mismatched, twice, never
// recorded, after the channel is gone), the transferred port disentangled and entangled in the receiving process.
static size_t messagePortTransfer(Digest& digest, Excluded&)
{
    constexpr unsigned transferCount = 2000;
    auto& bodies = messageBodies();
    auto registry = makeMessagePortChannelRegistry();
    size_t operations = 0;

    // The carrier channel: process 1 posts to process 2.
    auto carrier1 = portIdentifier(1, 1);
    auto carrier2 = portIdentifier(2, 2);
    registry->didCreateMessagePortChannel(carrier1, carrier2);

    for (unsigned i = 0; i < transferCount; ++i) {
        auto moving = portIdentifier(1, 1000 + 2 * i);
        auto staying = portIdentifier(1, 1001 + 2 * i);
        registry->didCreateMessagePortChannel(moving, staying);

        registry->recordPendingTransferOrigin(moving, ProcessIdentifier(1));
        registry->didDisentangleMessagePort(moving);
        Vector<TransferredMessagePort> sent { { moving, staying } };
        digest.addBool(registry->didPostMessageToRemote({ bodies[i % bodies.size()].copyRef(), WTF::move(sent) }, carrier2));

        Vector<TransferredMessagePort> received;
        takeAll(digest, registry.get(), carrier2, &received);
        for (auto& [port, remote] : received) {
            digest.addBool(port == moving);
            digest.addBool(remote == staying);
        }

        digest.addBool(registry->claimPendingTransferOrigin(moving, ProcessIdentifier(i % 5 ? 1 : 9)));
        digest.addBool(registry->claimPendingTransferOrigin(moving, ProcessIdentifier(1)));
        registry->recordPendingTransferDestination(moving, ProcessIdentifier(2));
        digest.addBool(registry->claimPendingTransferDestination(moving, ProcessIdentifier(i % 7 ? 2 : 8)));
        digest.addBool(registry->claimPendingTransferDestination(moving, ProcessIdentifier(2)));
        digest.addBool(registry->claimPendingTransferDestination(staying, ProcessIdentifier(1)));

        registry->didEntangleLocalToRemote(moving, staying, ProcessIdentifier(2));
        addChannelState(digest, registry.get(), moving);

        // A record left behind is dropped with its channel.
        registry->recordPendingTransferOrigin(staying, ProcessIdentifier(1));
        registry->didCloseMessagePort(moving, MessagePortStatus::Closed);
        registry->didCloseMessagePort(staying, MessagePortStatus::Closed);
        digest.addBool(registry->claimPendingTransferOrigin(staying, ProcessIdentifier(1)));
        operations += 17;
    }

    registry->didCloseMessagePort(carrier1, MessagePortStatus::Closed);
    registry->didCloseMessagePort(carrier2, MessagePortStatus::Closed);
    return operations * identifierBytes;
}

// Every operation on ports the registry does not know, and posts to closed ports.
static size_t messagePortErrorPaths(Digest& digest, Excluded&)
{
    constexpr unsigned roundCount = 4000;
    auto& bodies = messageBodies();
    auto registry = makeMessagePortChannelRegistry();
    size_t operations = 0;
    for (unsigned i = 0; i < roundCount; ++i) {
        auto unknown = portIdentifier(7, 500000 + i);
        auto port1 = portIdentifier(1, 2 * i + 1);
        auto port2 = portIdentifier(2, 2 * i + 2);

        digest.addBool(registry->didPostMessageToRemote({ bodies[1].copyRef(), { } }, unknown));
        takeAll(digest, registry.get(), unknown);
        registry->didEntangleLocalToRemote(unknown, port1, ProcessIdentifier(7));
        registry->didDisentangleMessagePort(unknown);
        registry->didCloseMessagePort(unknown, MessagePortStatus::Closed);
        digest.addBool(registry->claimPendingTransferOrigin(unknown, ProcessIdentifier(7)));
        digest.addBool(registry->claimPendingTransferDestination(unknown, ProcessIdentifier(7)));
        addChannelState(digest, registry.get(), unknown);

        registry->didCreateMessagePortChannel(port1, port2);
        takeAll(digest, registry.get(), port2);
        registry->didCloseMessagePort(port2, i % 2 ? MessagePortStatus::Closed : MessagePortStatus::Unclaimed);
        digest.addBool(registry->didPostMessageToRemote({ bodies[2].copyRef(), { } }, port2));
        digest.addBool(registry->didPostMessageToRemote({ bodies[2].copyRef(), { } }, port1));
        takeAll(digest, registry.get(), port1);
        registry->didCloseMessagePort(port1, MessagePortStatus::Closed);
        digest.addBool(registry->didPostMessageToRemote({ bodies[2].copyRef(), { } }, port1));
        addChannelState(digest, registry.get(), port1);
        operations += 16;
    }
    return operations * identifierBytes;
}

// Blobs.

static URL internalBlobURL(unsigned index)
{
    return URL { makeString("blob:blobinternal://"_s, index) };
}

static URL publicBlobURL(unsigned index)
{
    return URL { makeString("blob:https://a.example/"_s, index) };
}

static const SecurityOriginData& topOriginA()
{
    static NeverDestroyed<SecurityOriginData> origin { "https"_s, "a.example"_s, std::nullopt };
    return origin.get();
}

static const SecurityOriginData& topOriginB()
{
    static NeverDestroyed<SecurityOriginData> origin { "https"_s, "b.example"_s, std::nullopt };
    return origin.get();
}

static String contentTypeFor(unsigned index)
{
    switch (index % 4) {
    case 0:
        return emptyString();
    case 1:
        return "text/plain;charset=utf-8"_s;
    case 2:
        return "application/octet-stream"_s;
    default:
        return "image/png"_s;
    }
}

static void addBlobState(Digest& digest, BlobRegistryImpl& registry, const URL& url)
{
    digest.addBool(!!registry.blobDataFromURL(url));
    digest.addInteger(registry.blobSize(url));
    digest.addString(registry.blobType(url));
}

static Vector<BlobPart> dataParts(std::initializer_list<size_t> sizes, uint64_t seed)
{
    Vector<BlobPart> parts;
    for (size_t size : sizes)
        parts.append(BlobPart { patternBytes(size, seed++) });
    return parts;
}

// A blob load through the production loader; everything the client observes goes to the digest.
class BlobLoadClient final : public ResourceHandleClient {
public:
    explicit BlobLoadClient(Digest& digest)
        : m_digest(digest)
    {
    }

    bool done() const { return m_done; }
    bool* doneFlag() { return &m_done; }
    size_t bytes() const { return m_bytes; }

private:
    void willSendRequestAsync(ResourceHandle*, ResourceRequest&& request, ResourceResponse&&, CompletionHandler<void(ResourceRequest&&)>&& completion) final
    {
        m_digest.addByte('W');
        completion(WTF::move(request));
    }

    void didReceiveResponseAsync(ResourceHandle*, ResourceResponse&& response, CompletionHandler<void()>&& completion) final
    {
        m_digest.addByte('R');
        m_digest.addInteger(response.httpStatusCode());
        m_digest.addString(response.mimeType());
        m_digest.addInteger(static_cast<uint64_t>(response.expectedContentLength()));
        m_digest.addString(response.httpHeaderField(HTTPHeaderName::ContentType));
        m_digest.addString(response.httpHeaderField(HTTPHeaderName::ContentLength));
        m_digest.addString(response.httpHeaderField(HTTPHeaderName::ContentRange));
        completion();
    }

#if USE(PROTECTION_SPACE_AUTH_CALLBACK)
    void canAuthenticateAgainstProtectionSpaceAsync(ResourceHandle*, const ProtectionSpace&, CompletionHandler<void(bool)>&& completion) final
    {
        completion(false);
    }
#endif

    void didReceiveBuffer(ResourceHandle*, const FragmentedSharedBuffer& buffer, int) final
    {
        // The data, not how it was chunked: the split into reads is the implementation's.
        buffer.forEachSegment([&](std::span<const uint8_t> segment) {
            for (auto byte : segment)
                m_digest.addByte(byte);
            m_bytes += segment.size();
        });
    }

    void didFinishLoading(ResourceHandle*, const NetworkLoadMetrics&) final
    {
        m_digest.addByte('F');
        m_digest.addInteger(m_bytes);
        m_done = true;
    }

    void didFail(ResourceHandle*, const ResourceError& error) final
    {
        m_digest.addByte('E');
        m_digest.addString(error.domain());
        m_digest.addInteger(static_cast<uint64_t>(error.errorCode()));
        m_digest.addInteger(m_bytes);
        m_done = true;
    }

    Digest& m_digest;
    size_t m_bytes { 0 };
    bool m_done { false };
};

static size_t load(Digest& digest, BlobRegistryImpl& registry, const URL& url, const String& range = { }, const String& method = "GET"_s)
{
    ResourceRequest request { URL { url } };
    request.setHTTPMethod(method);
    if (!range.isNull())
        request.setHTTPHeaderField(HTTPHeaderName::Range, range);
    BlobLoadClient client(digest);
    Ref handle = registry.createResourceHandle(request, &client);
    Util::run(client.doneFlag());
    handle->clearClient();
    return client.bytes();
}

// The synchronous loader reaches the registry through the platform strategies, so the shapes that use it register
// their blobs there.
static BlobRegistryImpl& strategiesBlobRegistry()
{
    ensureTestPlatformStrategiesInstalled();
    return *blobRegistry()->blobRegistryImpl();
}

static size_t loadSynchronously(Digest& digest, const URL& url, const String& range = { }, const String& method = "GET"_s)
{
    ResourceRequest request { URL { url } };
    request.setHTTPMethod(method);
    if (!range.isNull())
        request.setHTTPHeaderField(HTTPHeaderName::Range, range);
    ResourceError error;
    ResourceResponse response;
    Vector<uint8_t> data;
    ResourceHandle::loadResourceSynchronously(nullptr, request, StoredCredentialsPolicy::DoNotUse, nullptr, error, response, data);
    digest.addBool(error.isNull());
    if (!error.isNull()) {
        digest.addString(error.domain());
        digest.addInteger(static_cast<uint64_t>(error.errorCode()));
    }
    digest.addInteger(response.httpStatusCode());
    digest.addString(response.mimeType());
    digest.addString(response.httpHeaderField(HTTPHeaderName::ContentLength));
    digest.addString(response.httpHeaderField(HTTPHeaderName::ContentRange));
    digest.addBytes(data.span());
    return data.size();
}

// The directory data parts are mapped into files in (the network process's blob directory); the mapping files
// themselves are deleted as soon as they are mapped.
static String mappingFileDirectory()
{
    static NeverDestroyed<String> directory([] {
        auto [path, handle] = FileSystem::openTemporaryFile("ChannelsAndBlobsBench"_s);
        FileSystem::deleteFile(path);
        return FileSystem::parentPath(path);
    }());
    return directory.get();
}

// The data segments a blob holds now. Reading BlobData's members is not the code being measured; only whether a
// segment was replaced (by its mapped copy) goes to the digest.
static Vector<const DataSegment*> dataSegments(BlobRegistryImpl& registry, const URL& url)
{
    Vector<const DataSegment*> segments;
    if (RefPtr data = registry.blobDataFromURL(url)) {
        for (auto& item : data->items()) {
            item.switchOn([&](const DataSegment& segment) {
                segments.append(&segment);
            }, [](const BlobDataFileReference&) { });
        }
    }
    return segments;
}

// Spins the run loop until every data segment of `urls` differs from `before`, for at most ten seconds.
static bool waitForMappedSegments(BlobRegistryImpl& registry, const Vector<URL>& urls, const Vector<Vector<const DataSegment*>>& before)
{
    auto deadline = MonotonicTime::now() + 10_s;
    while (MonotonicTime::now() < deadline) {
        bool allReplaced = true;
        for (size_t i = 0; i < urls.size() && allReplaced; ++i) {
            auto now = dataSegments(registry, urls[i]);
            for (size_t j = 0; j < now.size() && allReplaced; ++j)
                allReplaced = now[j] != before[i][j];
        }
        if (allReplaced)
            return true;
        Util::spinRunLoop();
    }
    return false;
}

// `count` blobs of one data part of `size` bytes each, registered with or without a mapping directory, measured,
// and unregistered. With a directory, the pass waits (untimed) until every part was mapped, so no mapping work
// crosses into the next pass.
static size_t registerData(Digest& digest, Excluded& excluded, unsigned count, size_t size, bool withFileDirectory)
{
    auto registry = makeBlobRegistry();
    if (withFileDirectory)
        registry->setFileDirectory(String { mappingFileDirectory() });
    Vector<URL> urls;
    Vector<Vector<uint8_t>> data;
    excluded.measure([&] {
        for (unsigned i = 0; i < count; ++i) {
            urls.append(internalBlobURL(i));
            data.append(patternBytes(size, i));
        }
    });
    Vector<Vector<const DataSegment*>> before;
    for (unsigned i = 0; i < count; ++i) {
        Vector<BlobPart> parts;
        parts.append(BlobPart { WTF::move(data[i]) });
        registry->registerInternalBlobURL(urls[i], WTF::move(parts), contentTypeFor(i));
        addBlobState(digest, registry.get(), urls[i]);
        if (withFileDirectory) {
            excluded.measure([&] {
                before.append(dataSegments(registry.get(), urls[i]));
            });
        }
    }
    if (withFileDirectory) {
        excluded.measure([&] {
            bool drained = waitForMappedSegments(registry.get(), urls, before);
            EXPECT_TRUE(drained);
            digest.addBool(drained);
        });
    }
    for (auto& url : urls)
        registry->unregisterBlobURL(url, std::nullopt);
    return count * size;
}

// Internal blobs of data parts and of other blobs (known, unknown, null), registered, measured, unregistered, with
// handles counted; registering over an existing URL; unregistering what is not there.
static size_t blobRegisterUnregister(Digest& digest, Excluded& excluded)
{
    constexpr unsigned blobCount = 3000;
    static NeverDestroyed<Vector<Vector<uint8_t>>> partData([] {
        Vector<Vector<uint8_t>> result;
        uint64_t seed = 11;
        for (size_t size : { 0, 1, 7, 64, 513, 4096, 20000 })
            result.append(patternBytes(size, seed++));
        return result;
    }());
    Vector<URL> urls;
    excluded.measure([&] {
        for (unsigned i = 0; i < blobCount; ++i)
            urls.append(internalBlobURL(i));
    });

    auto registry = makeBlobRegistry();
    Random random(13);
    size_t bytes = 0;
    for (unsigned i = 0; i < blobCount; ++i) {
        Vector<BlobPart> parts;
        unsigned partCount = random.below(5);
        for (unsigned p = 0; p < partCount; ++p) {
            switch (random.below(5)) {
            case 0:
                parts.append(BlobPart { i ? urls[random.below(i)] : urls[0] });
                break;
            case 1:
                parts.append(BlobPart { internalBlobURL(900000 + i) });
                break;
            case 2:
                parts.append(BlobPart { URL { } });
                break;
            default: {
                auto& data = partData.get()[random.below(partData->size())];
                bytes += data.size();
                parts.append(BlobPart { Vector<uint8_t> { data } });
                break;
            }
            }
        }
        registry->registerInternalBlobURL(urls[i], WTF::move(parts), contentTypeFor(i));
        addBlobState(digest, registry.get(), urls[i]);

        if (!(i % 7)) {
            // Registered again over itself: the first registration stays counted once.
            registry->registerInternalBlobURL(urls[i], dataParts({ 3 }, i), contentTypeFor(i + 1));
            addBlobState(digest, registry.get(), urls[i]);
        }
        if (!(i % 5)) {
            registry->registerBlobURLHandle(urls[i], std::nullopt);
            registry->unregisterBlobURL(urls[i], std::nullopt);
            addBlobState(digest, registry.get(), urls[i]);
            registry->unregisterBlobURLHandle(urls[i], std::nullopt);
            addBlobState(digest, registry.get(), urls[i]);
        }
    }

    // A fragment is ignored by lookups and handles but not by unregistering.
    URL withFragment { makeString(urls[1].string(), "#fragment"_s) };
    addBlobState(digest, registry.get(), withFragment);
    registry->unregisterBlobURL(withFragment, std::nullopt);
    addBlobState(digest, registry.get(), urls[1]);

    for (unsigned i = 0; i < blobCount; ++i) {
        registry->unregisterBlobURL(urls[i], std::nullopt);
        registry->unregisterBlobURL(urls[i], std::nullopt);
        addBlobState(digest, registry.get(), urls[i]);
    }
    return bytes;
}

// Public blob URLs partitioned by top origin: registered from internal blobs with the same and a different policy
// container, looked up, counted and unregistered with the right, the wrong and no top origin.
static size_t blobPartitionedURLs(Digest& digest, Excluded& excluded)
{
    constexpr unsigned blobCount = 2000;
    Vector<URL> internalURLs;
    Vector<URL> publicURLs;
    excluded.measure([&] {
        for (unsigned i = 0; i < blobCount; ++i) {
            internalURLs.append(internalBlobURL(i));
            publicURLs.append(publicBlobURL(i));
        }
    });
    PolicyContainer defaultPolicy;
    PolicyContainer noReferrerPolicy;
    noReferrerPolicy.referrerPolicy = ReferrerPolicy::NoReferrer;

    auto registry = makeBlobRegistry();
    size_t bytes = 0;
    for (unsigned i = 0; i < blobCount; ++i) {
        size_t size = 1 + (i * 37) % 2000;
        registry->registerInternalBlobURL(internalURLs[i], dataParts({ size }, i), contentTypeFor(i));
        bytes += size;

        auto& publicURL = publicURLs[i];
        registry->registerBlobURL(publicURL, i % 9 ? internalURLs[i] : internalBlobURL(900000 + i), i % 2 ? noReferrerPolicy : defaultPolicy, topOriginA());
        addBlobState(digest, registry.get(), publicURL);
        digest.addBool(!!registry->blobDataFromURL(publicURL, topOriginA()));
        digest.addBool(!!registry->blobDataFromURL(publicURL, topOriginB()));
        digest.addBool(!!registry->blobDataFromURL(publicURL, std::nullopt));
        digest.addInteger(registry->filesInBlob(publicURL, topOriginB()).size());

        registry->registerBlobURLHandle(publicURL, topOriginA());
        registry->registerBlobURLHandle(publicURL, topOriginB());
        registry->unregisterBlobURL(publicURL, topOriginB());
        addBlobState(digest, registry.get(), publicURL);
        registry->unregisterBlobURLHandle(publicURL, topOriginA());
        addBlobState(digest, registry.get(), publicURL);
        registry->unregisterBlobURL(publicURL, topOriginA());
        addBlobState(digest, registry.get(), publicURL);
        registry->unregisterBlobURLHandle(publicURL, topOriginA());

        // The internal blob outlives its public URL, and the public URL its internal blob.
        if (i % 3) {
            registry->registerBlobURL(publicURL, internalURLs[i], defaultPolicy, topOriginA());
            registry->unregisterBlobURL(internalURLs[i], std::nullopt);
            addBlobState(digest, registry.get(), publicURL);
            registry->unregisterBlobURL(publicURL, topOriginA());
        } else
            registry->unregisterBlobURL(internalURLs[i], std::nullopt);
        addBlobState(digest, registry.get(), internalURLs[i]);
        addBlobState(digest, registry.get(), publicURL);
    }
    return bytes;
}

// Slices of multi-part blobs at every boundary: negative, reversed, past the end, empty, of slices, of unknown
// blobs; each slice's size, type and contents.
static size_t blobSlice(Digest& digest, Excluded&)
{
    constexpr long long largest = LLONG_MAX;
    constexpr long long smallest = LLONG_MIN + 1;
    static const std::pair<long long, long long> bounds[] = {
        { 0, 0 }, { 0, 1 }, { 0, 7 }, { 0, 8 }, { 6, 8 }, { 7, 7 }, { 7, 307 }, { 306, 308 }, { 0, 4404 }, { 0, 4405 },
        { 4403, 4404 }, { 4404, 4405 }, { 100, 50 }, { -1, 4404 }, { -10, -1 }, { -4404, -4000 }, { -5000, 10 },
        { 10, -5000 }, { smallest, largest }, { largest, largest }, { 4404, largest }, { 1, -1 }, { 300, 4100 },
    };
    auto registry = makeBlobRegistry();
    size_t bytes = 0;

    // 7 + 0 + 300 + 4096 + 1 bytes in five parts, and the same through two levels of blob parts.
    auto source = internalBlobURL(1);
    registry->registerInternalBlobURL(source, dataParts({ 7, 0, 300, 4096, 1 }, 21), "text/plain"_s);
    auto nested = internalBlobURL(2);
    Vector<BlobPart> nestedParts;
    nestedParts.append(BlobPart { source });
    registry->registerInternalBlobURL(nested, WTF::move(nestedParts), "text/plain"_s);
    addBlobState(digest, registry.get(), nested);

    unsigned next = 100;
    for (unsigned round = 0; round < 4; ++round) {
        for (auto [start, end] : bounds) {
            for (auto& from : { source, nested, internalBlobURL(999999) }) {
                auto slice = internalBlobURL(next++);
                registry->registerInternalBlobURLForSlice(slice, from, start, end, contentTypeFor(next));
                addBlobState(digest, registry.get(), slice);
                bytes += load(digest, registry.get(), slice);

                // A slice of the slice.
                auto inner = internalBlobURL(next++);
                registry->registerInternalBlobURLForSlice(inner, slice, 1, -1, "application/x-slice"_s);
                addBlobState(digest, registry.get(), inner);
                bytes += load(digest, registry.get(), inner);

                registry->unregisterBlobURL(slice, std::nullopt);
                bytes += load(digest, registry.get(), inner);
                registry->unregisterBlobURL(inner, std::nullopt);
            }
        }
    }
    registry->unregisterBlobURL(nested, std::nullopt);
    registry->unregisterBlobURL(source, std::nullopt);
    return bytes;
}

// The fast path: whole reads of a 4 MB blob of 64 parts and of a 4 MB single part.
static size_t blobReadWhole(Digest& digest, Excluded&)
{
    constexpr size_t partSize = 64 * 1024;
    auto registry = makeBlobRegistry();
    Vector<BlobPart> parts;
    for (unsigned i = 0; i < 64; ++i)
        parts.append(BlobPart { patternBytes(partSize, 31 + i) });
    auto manyParts = internalBlobURL(1);
    registry->registerInternalBlobURL(manyParts, WTF::move(parts), "application/octet-stream"_s);
    auto onePart = internalBlobURL(2);
    registry->registerInternalBlobURL(onePart, dataParts({ 64 * partSize }, 97), "text/html"_s);

    size_t bytes = 0;
    for (unsigned i = 0; i < 4; ++i) {
        bytes += load(digest, registry.get(), manyParts);
        bytes += load(digest, registry.get(), onePart);
    }
    registry->unregisterBlobURL(manyParts, std::nullopt);
    registry->unregisterBlobURL(onePart, std::nullopt);
    return bytes;
}

// A multi-part blob of 54,131 bytes: closed and open ranges at every part boundary, whitespace, and the largest values.
static size_t blobReadRanges(Digest& digest, Excluded&)
{
    static const ASCIILiteral ranges[] = {
        "bytes=0-0"_s, "bytes=0-999"_s, "bytes=999-1000"_s, "bytes=1000-1000"_s, "bytes=1000-51000"_s,
        "bytes=50999-51002"_s, "bytes=51002-51002"_s, "bytes=0-54130"_s, "bytes=0-54131"_s, "bytes=0-99999999"_s,
        "bytes=54130-"_s, "bytes=0-"_s, "bytes=1000-"_s, "bytes=3-3"_s, "bytes = 10 - 20"_s, "bytes=\t5-6"_s,
        "BYTES=1-2"_s, "bytes=00000000000000000001-2"_s, "bytes=0-18446744073709551615"_s, "bytes=51003-54130"_s,
    };
    auto registry = makeBlobRegistry();
    auto url = internalBlobURL(1);
    registry->registerInternalBlobURL(url, dataParts({ 1000, 0, 50000, 3, 3128 }, 41), "text/plain;charset=utf-8"_s);
    size_t bytes = 0;
    for (unsigned round = 0; round < 10; ++round) {
        for (auto range : ranges)
            bytes += load(digest, registry.get(), url, range);
    }
    registry->unregisterBlobURL(url, std::nullopt);
    return bytes;
}

// Suffix ranges: shorter than, equal to and longer than the blob, on a multi-part blob and an empty one. A suffix of
// zero bytes ("bytes=-0") is left out: it overflows a Checked<uint64_t> and crashes.
static size_t blobReadSuffixRanges(Digest& digest, Excluded&)
{
    static const ASCIILiteral ranges[] = {
        "bytes=-1"_s, "bytes=-3"_s, "bytes=-4"_s, "bytes=-3128"_s, "bytes=-3131"_s, "bytes=-53131"_s, "bytes=-54130"_s,
        "bytes=-54131"_s, "bytes=-54132"_s, "bytes=-99999999"_s, "bytes= -7"_s, "bytes=-18446744073709551615"_s,
    };
    auto registry = makeBlobRegistry();
    auto url = internalBlobURL(1);
    registry->registerInternalBlobURL(url, dataParts({ 1000, 0, 50000, 3, 3128 }, 41), "text/plain;charset=utf-8"_s);
    auto empty = internalBlobURL(2);
    registry->registerInternalBlobURL(empty, { }, "text/plain"_s);
    size_t bytes = 0;
    for (unsigned round = 0; round < 10; ++round) {
        for (auto range : ranges) {
            bytes += load(digest, registry.get(), url, range);
            bytes += load(digest, registry.get(), empty, range);
        }
    }
    registry->unregisterBlobURL(url, std::nullopt);
    registry->unregisterBlobURL(empty, std::nullopt);
    return bytes;
}

static String writeTemporaryFile(const Vector<uint8_t>& contents)
{
    auto [path, handle] = FileSystem::openTemporaryFile("ChannelsAndBlobsBench"_s);
    RELEASE_ASSERT(handle);
    RELEASE_ASSERT(handle.write(contents.span()) == contents.size());
    return path;
}

// File-backed blobs: a 1 MB file alone, between data parts, sliced across the boundaries, read in ranges; a file that
// is missing; registration by file when the source is unknown, and with an empty path; the files a blob holds.
static size_t blobReadFile(Digest& digest, Excluded& excluded)
{
    constexpr size_t fileSize = 1024 * 1024;
    String path;
    excluded.measure([&] {
        path = writeTemporaryFile(patternBytes(fileSize, 51));
    });
    auto missingPath = makeString(path, ".missing"_s);

    auto registry = makeBlobRegistry();
    auto file = internalBlobURL(1);
    registry->registerInternalFileBlobURL(file, BlobDataFileReference::create(path), "application/octet-stream"_s);
    auto mixed = internalBlobURL(2);
    Vector<BlobPart> mixedParts = dataParts({ 100 }, 52);
    mixedParts.append(BlobPart { file });
    mixedParts.append(BlobPart { patternBytes(100, 53) });
    registry->registerInternalBlobURL(mixed, WTF::move(mixedParts), "text/plain"_s);
    auto missing = internalBlobURL(3);
    registry->registerInternalFileBlobURL(missing, BlobDataFileReference::create(missingPath), "text/plain"_s);
    auto byFile = internalBlobURL(4);
    registry->registerInternalBlobURLOptionallyFileBacked(byFile, internalBlobURL(999999), BlobDataFileReference::create(path), "image/png"_s, { });
    auto byEmptyPath = internalBlobURL(5);
    registry->registerInternalBlobURLOptionallyFileBacked(byEmptyPath, internalBlobURL(999999), BlobDataFileReference::create(emptyString()), "image/png"_s, { });
    auto fromSource = internalBlobURL(6);
    registry->registerInternalBlobURLOptionallyFileBacked(fromSource, mixed, BlobDataFileReference::create(missingPath), "image/png"_s, { });

    for (auto& url : { file, mixed, missing, byFile, byEmptyPath, fromSource }) {
        addBlobState(digest, registry.get(), url);
        digest.addInteger(registry->filesInBlob(url).size());
    }

    size_t bytes = 0;
    unsigned next = 100;
    static const std::pair<long long, long long> slices[] = { { 0, 100 }, { 99, 101 }, { 100, 1048676 }, { 1048675, 1048677 }, { 1048676, 1048776 }, { 50, -50 } };
    for (auto [start, end] : slices) {
        auto slice = internalBlobURL(next++);
        registry->registerInternalBlobURLForSlice(slice, mixed, start, end, "text/plain"_s);
        addBlobState(digest, registry.get(), slice);
        bytes += load(digest, registry.get(), slice);
        bytes += load(digest, registry.get(), slice, "bytes=1-10"_s);
        registry->unregisterBlobURL(slice, std::nullopt);
    }
    for (auto& url : { file, mixed, byFile, fromSource }) {
        bytes += load(digest, registry.get(), url);
        bytes += load(digest, registry.get(), url, "bytes=99-200"_s);
        bytes += load(digest, registry.get(), url, "bytes=-150"_s);
        bytes += load(digest, registry.get(), url, "bytes=1048600-"_s);
    }
    bytes += load(digest, registry.get(), missing);
    bytes += load(digest, registry.get(), missing, "bytes=0-1"_s);

    for (auto& url : { file, mixed, missing, byFile, byEmptyPath, fromSource })
        registry->unregisterBlobURL(url, std::nullopt);
    excluded.measure([&] {
        FileSystem::deleteFile(path);
    });
    return bytes;
}

// Blobs written to files for IndexedDB: whole, sliced, file-backed, composite, and a list holding an unknown URL.
static size_t blobWriteForIndexedDB(Digest& digest, Excluded& excluded)
{
    String path;
    excluded.measure([&] {
        path = writeTemporaryFile(patternBytes(256 * 1024, 61));
    });

    auto registry = makeBlobRegistry();
    auto whole = internalBlobURL(1);
    registry->registerInternalBlobURL(whole, dataParts({ 100000, 1, 28000 }, 62), "text/plain"_s);
    auto slice = internalBlobURL(2);
    registry->registerInternalBlobURLForSlice(slice, whole, 50000, 50100, "text/plain"_s);
    auto file = internalBlobURL(3);
    registry->registerInternalFileBlobURL(file, BlobDataFileReference::create(path), "application/octet-stream"_s);
    auto composite = internalBlobURL(4);
    Vector<BlobPart> compositeParts;
    compositeParts.append(BlobPart { slice });
    compositeParts.append(BlobPart { file });
    compositeParts.append(BlobPart { patternBytes(10, 63) });
    registry->registerInternalBlobURL(composite, WTF::move(compositeParts), "text/plain"_s);
    auto empty = internalBlobURL(5);
    registry->registerInternalBlobURL(empty, { }, "text/plain"_s);

    const Vector<Vector<String>> lists {
        { whole.string() }, { slice.string() }, { file.string() }, { composite.string() }, { empty.string() },
        { whole.string(), slice.string(), file.string(), composite.string(), empty.string() },
        { whole.string(), internalBlobURL(999999).string(), slice.string() }, { },
    };

    size_t bytes = 0;
    for (unsigned round = 0; round < 3; ++round) {
        for (auto& list : lists) {
            bool done = false;
            Vector<String> written;
            registry->writeBlobsToTemporaryFilesForIndexedDB(list, [&](Vector<String>&& filePaths) {
                written = WTF::move(filePaths);
                done = true;
            });
            Util::run(&done);
            digest.addInteger(written.size());
            excluded.measure([&] {
                for (auto& writtenPath : written) {
                    auto contents = FileSystem::readEntireFile(writtenPath);
                    digest.addBool(!!contents);
                    if (contents) {
                        digest.addBytes(contents->span());
                        bytes += contents->size();
                    }
                    FileSystem::deleteFile(writtenPath);
                }
            });
        }
    }

    for (auto& url : { whole, slice, file, composite, empty })
        registry->unregisterBlobURL(url, std::nullopt);
    excluded.measure([&] {
        FileSystem::deleteFile(path);
    });
    return bytes;
}

// 32 mixed parts per blob: data of every size class and references to earlier blobs. A blob part is flattened into
// the referenced blob's items, so only the first 16 blobs, which hold data alone, are referenced: a blob holds at most
// 32 x 32 items, where references to any earlier blob
// would grow the item count without bound (past 10^13 items by the 300th blob).
static size_t registerMultipart(Digest& digest, Excluded&)
{
    constexpr unsigned blobCount = 300;
    constexpr unsigned dataOnlyBlobCount = 16;
    auto registry = makeBlobRegistry();
    Random random(17);
    size_t bytes = 0;
    for (unsigned i = 0; i < blobCount; ++i) {
        Vector<BlobPart> parts;
        for (unsigned p = 0; p < 32; ++p) {
            if (i >= dataOnlyBlobCount && !random.below(4))
                parts.append(BlobPart { internalBlobURL(random.below(dataOnlyBlobCount)) });
            else {
                size_t size = std::array<size_t, 5> { 0, 1, 64, 1000, 8192 }[random.below(5)];
                bytes += size;
                parts.append(BlobPart { patternBytes(size, i * 32 + p) });
            }
        }
        registry->registerInternalBlobURL(internalBlobURL(i), WTF::move(parts), contentTypeFor(i));
        addBlobState(digest, registry.get(), internalBlobURL(i));
    }
    for (unsigned i = 0; i < blobCount; ++i)
        registry->unregisterBlobURL(internalBlobURL(i), std::nullopt);
    return bytes;
}

// Eight slices deep, each with negative bounds, then the deepest read.
static size_t sliceChain(Digest& digest, Excluded&)
{
    auto registry = makeBlobRegistry();
    registry->registerInternalBlobURL(internalBlobURL(0), dataParts({ 4096, 100, 0, 30000, 7 }, 3), "text/plain"_s);
    size_t bytes = 0;
    for (unsigned chain = 0; chain < 200; ++chain) {
        unsigned base = 1000 + chain * 8;
        for (unsigned depth = 0; depth < 8; ++depth) {
            auto from = depth ? internalBlobURL(base + depth - 1) : internalBlobURL(0);
            long long start = -static_cast<long long>(30000 - depth * 1000 - chain);
            long long end = -static_cast<long long>(1 + depth * 7 + chain % 5);
            registry->registerInternalBlobURLForSlice(internalBlobURL(base + depth), from, start, end, contentTypeFor(depth));
            addBlobState(digest, registry.get(), internalBlobURL(base + depth));
        }
        bytes += load(digest, registry.get(), internalBlobURL(base + 7), "bytes=0-99"_s);
        for (unsigned depth = 0; depth < 8; ++depth)
            registry->unregisterBlobURL(internalBlobURL(base + depth), std::nullopt);
    }
    registry->unregisterBlobURL(internalBlobURL(0), std::nullopt);
    return bytes;
}

// Lookups over 4,096 registered URLs: internal hits, public hits with the right and no top origin, with a fragment.
static size_t resolveHit(Digest& digest, Excluded& excluded)
{
    constexpr unsigned blobCount = 4096;
    auto registry = makeBlobRegistry();
    Vector<URL> internalURLs;
    Vector<URL> publicURLs;
    excluded.measure([&] {
        for (unsigned i = 0; i < blobCount; ++i) {
            internalURLs.append(internalBlobURL(i));
            publicURLs.append(URL { makeString(publicBlobURL(i).string(), i % 2 ? "#f"_s : ""_s) });
            registry->registerInternalBlobURL(internalURLs[i], dataParts({ 8 }, i), contentTypeFor(i));
            registry->registerBlobURL(publicBlobURL(i), internalURLs[i], { }, topOriginA());
        }
    });
    for (unsigned round = 0; round < 8; ++round) {
        for (unsigned i = 0; i < blobCount; ++i) {
            digest.addBool(!!registry->blobDataFromURL(internalURLs[i]));
            digest.addBool(!!registry->blobDataFromURL(publicURLs[i], topOriginA()));
            digest.addBool(!!registry->blobDataFromURL(publicURLs[i]));
        }
    }
    excluded.measure([&] {
        for (unsigned i = 0; i < blobCount; ++i) {
            registry->unregisterBlobURL(publicBlobURL(i), topOriginA());
            registry->unregisterBlobURL(internalURLs[i], std::nullopt);
        }
    });
    return 8 * blobCount * 3 * identifierBytes;
}

// Lookups that miss: unknown, unregistered, null and non-blob URLs, sizes and types of them.
static size_t resolveMiss(Digest& digest, Excluded& excluded)
{
    constexpr unsigned blobCount = 4096;
    auto registry = makeBlobRegistry();
    Vector<URL> missing;
    excluded.measure([&] {
        for (unsigned i = 0; i < blobCount; ++i) {
            registry->registerInternalBlobURL(internalBlobURL(i), dataParts({ 8 }, i), contentTypeFor(i));
            if (i % 3)
                missing.append(internalBlobURL(blobCount + i));
            else
                missing.constructAndAppend(makeString("https://a.example/"_s, i));
        }
        missing.constructAndAppend();
    });
    for (unsigned round = 0; round < 8; ++round) {
        for (auto& url : missing) {
            digest.addBool(!!registry->blobDataFromURL(url));
            digest.addInteger(registry->blobSize(url));
            digest.addString(registry->blobType(url));
        }
    }
    excluded.measure([&] {
        for (unsigned i = 0; i < blobCount; ++i)
            registry->unregisterBlobURL(internalBlobURL(i), std::nullopt);
    });
    return 8 * missing.size() * identifierBytes;
}

// Public URLs looked up, listed and counted with another partition's top origin: every one is refused.
static size_t resolveWrongTopOrigin(Digest& digest, Excluded& excluded)
{
    constexpr unsigned blobCount = 4096;
    auto registry = makeBlobRegistry();
    excluded.measure([&] {
        for (unsigned i = 0; i < blobCount; ++i) {
            registry->registerInternalBlobURL(internalBlobURL(i), dataParts({ 8 }, i), contentTypeFor(i));
            registry->registerBlobURL(publicBlobURL(i), internalBlobURL(i), { }, topOriginA());
        }
    });
    for (unsigned round = 0; round < 4; ++round) {
        for (unsigned i = 0; i < blobCount; ++i) {
            digest.addBool(!!registry->blobDataFromURL(publicBlobURL(i), topOriginB()));
            digest.addInteger(registry->filesInBlob(publicBlobURL(i), topOriginB()).size());
            registry->registerBlobURLHandle(publicBlobURL(i), topOriginB());
            registry->unregisterBlobURLHandle(publicBlobURL(i), topOriginB());
            registry->unregisterBlobURL(publicBlobURL(i), topOriginB());
            digest.addBool(!!registry->blobDataFromURL(publicBlobURL(i), topOriginA()));
        }
    }
    excluded.measure([&] {
        for (unsigned i = 0; i < blobCount; ++i) {
            registry->unregisterBlobURL(publicBlobURL(i), topOriginA());
            registry->unregisterBlobURL(internalBlobURL(i), std::nullopt);
        }
    });
    return 4 * blobCount * 6 * identifierBytes;
}

// Size and type of blobs of 32 items each.
static size_t sizeAndType(Digest& digest, Excluded& excluded)
{
    constexpr unsigned blobCount = 512;
    auto registry = makeBlobRegistry();
    excluded.measure([&] {
        for (unsigned i = 0; i < blobCount; ++i) {
            Vector<BlobPart> parts;
            for (unsigned p = 0; p < 32; ++p)
                parts.append(BlobPart { patternBytes((i + p) % 97, p) });
            registry->registerInternalBlobURL(internalBlobURL(i), WTF::move(parts), contentTypeFor(i));
        }
    });
    for (unsigned round = 0; round < 16; ++round) {
        for (unsigned i = 0; i < blobCount; ++i)
            addBlobState(digest, registry.get(), internalBlobURL(i));
    }
    excluded.measure([&] {
        for (unsigned i = 0; i < blobCount; ++i)
            registry->unregisterBlobURL(internalBlobURL(i), std::nullopt);
    });
    return 16 * blobCount * 32 * identifierBytes;
}

// The synchronous loader on 1 MiB: one data part, then the same bytes in a file, whole and in a range.
static size_t fullRead1MiB(Digest& digest, Excluded& excluded)
{
    constexpr size_t size = 1024 * 1024;
    auto& registry = strategiesBlobRegistry();
    String path;
    excluded.measure([&] {
        path = writeTemporaryFile(patternBytes(size, 5));
    });
    auto data = internalBlobURL(1);
    registry.registerInternalBlobURL(data, dataParts({ size }, 5), "application/octet-stream"_s);
    auto file = internalBlobURL(2);
    registry.registerInternalFileBlobURL(file, BlobDataFileReference::create(path), "application/octet-stream"_s);
    size_t bytes = 0;
    for (unsigned i = 0; i < 4; ++i) {
        bytes += loadSynchronously(digest, data);
        bytes += loadSynchronously(digest, file);
    }
    bytes += loadSynchronously(digest, data, "bytes=1000-"_s);
    bytes += loadSynchronously(digest, file, "bytes=-1000"_s);
    registry.unregisterBlobURL(data, std::nullopt);
    registry.unregisterBlobURL(file, std::nullopt);
    excluded.measure([&] {
        FileSystem::deleteFile(path);
    });
    return bytes;
}

// The first 100 bytes of a 4 KiB blob, asynchronously and synchronously.
static size_t rangeReadSmall(Digest& digest, Excluded&)
{
    auto registry = makeBlobRegistry();
    auto url = internalBlobURL(1);
    registry->registerInternalBlobURL(url, dataParts({ 4096 }, 7), "text/plain"_s);
    auto& strategies = strategiesBlobRegistry();
    auto syncURL = internalBlobURL(2);
    strategies.registerInternalBlobURL(syncURL, dataParts({ 4096 }, 7), "text/plain"_s);
    size_t bytes = 0;
    for (unsigned i = 0; i < 500; ++i) {
        bytes += load(digest, registry.get(), url, "bytes=0-99"_s);
        bytes += loadSynchronously(digest, syncURL, "bytes=0-99"_s);
    }
    registry->unregisterBlobURL(url, std::nullopt);
    strategies.unregisterBlobURL(syncURL, std::nullopt);
    return bytes;
}

static const ASCIILiteral unsatisfiableAndMalformedRanges[] = {
    "bytes=5-2"_s, "bytes=54131-"_s, "bytes=54131-54140"_s, "bytes=-"_s, "bytes="_s, "items=0-1"_s,
    "bytes=0-1,3-4"_s, "bytes=a-b"_s, "bytes=1-2-3"_s, "bytes=18446744073709551616-"_s, "bytes=--1"_s, ""_s,
};

// Ranges a blob cannot satisfy and ranges that do not parse, on both loaders.
static size_t rangeError(Digest& digest, Excluded&)
{
    auto registry = makeBlobRegistry();
    auto url = internalBlobURL(1);
    registry->registerInternalBlobURL(url, dataParts({ 1000, 0, 50000, 3, 3128 }, 41), "text/plain"_s);
    auto empty = internalBlobURL(2);
    registry->registerInternalBlobURL(empty, { }, "text/plain"_s);
    auto& strategies = strategiesBlobRegistry();
    strategies.registerInternalBlobURL(url, dataParts({ 1000, 0, 50000, 3, 3128 }, 41), "text/plain"_s);
    size_t bytes = 0;
    for (unsigned round = 0; round < 20; ++round) {
        for (auto range : unsatisfiableAndMalformedRanges) {
            bytes += load(digest, registry.get(), url, range);
            bytes += loadSynchronously(digest, url, range);
        }
        bytes += load(digest, registry.get(), empty, "bytes=0-"_s);
        bytes += load(digest, registry.get(), empty, "bytes=0-0"_s);
    }
    registry->unregisterBlobURL(url, std::nullopt);
    registry->unregisterBlobURL(empty, std::nullopt);
    strategies.unregisterBlobURL(url, std::nullopt);
    return bytes;
}

// Methods other than GET, on both loaders.
static size_t methodNotAllowed(Digest& digest, Excluded&)
{
    auto registry = makeBlobRegistry();
    auto url = internalBlobURL(1);
    registry->registerInternalBlobURL(url, dataParts({ 100 }, 43), "text/plain"_s);
    auto& strategies = strategiesBlobRegistry();
    strategies.registerInternalBlobURL(url, dataParts({ 100 }, 43), "text/plain"_s);
    size_t bytes = 0;
    for (unsigned round = 0; round < 100; ++round) {
        for (auto method : { "POST"_s, "HEAD"_s, "get"_s, "PUT"_s, "OPTIONS"_s }) {
            bytes += load(digest, registry.get(), url, { }, method);
            bytes += loadSynchronously(digest, url, { }, method);
        }
    }
    registry->unregisterBlobURL(url, std::nullopt);
    strategies.unregisterBlobURL(url, std::nullopt);
    return bytes;
}

// URLs with no blob: never registered, unregistered, public without a lookup origin; on both loaders.
static size_t notFound(Digest& digest, Excluded&)
{
    strategiesBlobRegistry();
    auto registry = makeBlobRegistry();
    auto gone = internalBlobURL(3);
    registry->registerInternalBlobURL(gone, dataParts({ 10 }, 5), "text/plain"_s);
    registry->unregisterBlobURL(gone, std::nullopt);
    size_t bytes = 0;
    for (unsigned round = 0; round < 200; ++round) {
        bytes += load(digest, registry.get(), gone);
        bytes += load(digest, registry.get(), internalBlobURL(999999), "bytes=0-1"_s);
        bytes += load(digest, registry.get(), publicBlobURL(1));
        bytes += loadSynchronously(digest, internalBlobURL(999998));
    }
    return bytes;
}

// 64 data parts registered with a mapping directory, and the time until every part has been replaced by its mapped
// copy: the work-queue round trip per part.
static size_t mappingFileDrain(Digest& digest, Excluded&)
{
    constexpr unsigned blobCount = 64;
    auto registry = makeBlobRegistry();
    registry->setFileDirectory(String { mappingFileDirectory() });
    Vector<URL> urls;
    Vector<Vector<const DataSegment*>> before;
    size_t bytes = 0;
    for (unsigned i = 0; i < blobCount; ++i) {
        urls.append(internalBlobURL(i));
        size_t size = 1 + i * 1024;
        bytes += size;
        registry->registerInternalBlobURL(urls[i], dataParts({ size }, i), "application/octet-stream"_s);
        before.append(dataSegments(registry.get(), urls[i]));
    }
    bool drained = waitForMappedSegments(registry.get(), urls, before);
    EXPECT_TRUE(drained);
    digest.addBool(drained);
    for (auto& url : urls) {
        addBlobState(digest, registry.get(), url);
        bytes += load(digest, registry.get(), url);
        registry->unregisterBlobURL(url, std::nullopt);
    }
    return bytes;
}

// data: URLs.

static void addDecodeResult(Digest& digest, const std::optional<DataURLDecoder::Result>& result)
{
    digest.addBool(!!result);
    if (!result)
        return;
    digest.addString(result->mimeType);
    digest.addString(result->charset);
    digest.addString(result->contentType);
    digest.addBytes(result->data.span());
}

static String base64Payload(size_t size, uint64_t seed)
{
    return base64EncodeToString(patternBytes(size, seed).span());
}

struct DataURLInput {
    URL url;
    size_t encodedLength;
};

static Vector<DataURLInput> dataURLInputs(const Vector<String>& strings)
{
    Vector<DataURLInput> inputs;
    for (auto& string : strings) {
        URL url { string };
        RELEASE_ASSERT(url.protocolIsData());
        inputs.append({ url, url.string().length() });
    }
    return inputs;
}

template<size_t rounds>
static size_t decodeAll(Digest& digest, const Vector<DataURLInput>& inputs)
{
    size_t bytes = 0;
    for (unsigned round = 0; round < rounds; ++round) {
        for (auto& input : inputs) {
            addDecodeResult(digest, DataURLDecoder::decode(input.url, DataURLDecoder::ShouldValidatePadding::Yes));
            addDecodeResult(digest, DataURLDecoder::decode(input.url, DataURLDecoder::ShouldValidatePadding::No));
            bytes += 2 * input.encodedLength;
        }
    }
    return bytes;
}

// Base64 bodies of every length modulo 3 and up to 1 MB, padded and unpadded, with whitespace and percent-escapes,
// under every header spelling.
static const Vector<DataURLInput>& base64Inputs()
{
    static NeverDestroyed<Vector<DataURLInput>> inputs([] {
        Vector<String> strings;
        uint64_t seed = 71;
        for (size_t size : { 0, 1, 2, 3, 4, 5, 57, 100, 4096, 65537, 1024 * 1024 }) {
            auto payload = base64Payload(size, seed++);
            strings.append(makeString("data:application/octet-stream;base64,"_s, payload));
            strings.append(makeString("data:;base64,"_s, payload));
            if (size < 5000) {
                strings.append(makeString("data:text/plain;charset=utf-8;base64,"_s, payload));
                strings.append(makeString("data:image/png; BASE64 ,"_s, payload));
                String unpadded = payload;
                while (unpadded.endsWith('='))
                    unpadded = unpadded.left(unpadded.length() - 1);
                strings.append(makeString("data:;base64,"_s, unpadded));
                StringBuilder spaced;
                for (unsigned i = 0; i < payload.length(); ++i) {
                    if (i && !(i % 76))
                        spaced.append("%20"_s);
                    auto character = payload[i];
                    if (character == '+')
                        spaced.append("%2B"_s);
                    else if (character == '/')
                        spaced.append("%2f"_s);
                    else
                        spaced.append(character);
                }
                strings.append(makeString("data:;base64,"_s, spaced.toString()));
            }
        }
        return dataURLInputs(strings);
    }());
    return inputs.get();
}

// Percent-encoded and plain bodies up to 1 MB, valid and invalid escapes, every media type spelling and the ones that
// keep a fragment.
static const Vector<DataURLInput>& percentInputs()
{
    static NeverDestroyed<Vector<DataURLInput>> inputs([] {
        Vector<String> strings {
            "data:,"_s, "data:,Hello%2C%20World!"_s, "data:text/html,%3Ch1%3EHi%3C%2Fh1%3E"_s, "data:text/plain;charset=iso-8859-1,caf%E9"_s,
            "data:text/plain;charset=UTF-8,%C3%A9%E2%82%AC%F0%9F%98%80"_s, "data:,%"_s, "data:,%4"_s, "data:,%G1%1G%%41"_s,
            "data:,%00%FF%7f"_s, "data:foo,abc"_s, "data:text/plain;a=b;charset=x,abc"_s, "data:;charset=utf-8,abc"_s,
            "data: text/plain ,abc"_s, "data:text/plain;base64x,abc"_s, "data:video/mpegurl,#EXTM3U%0A#EXT-X-VERSION:3"_s,
            "data:text/plain,abc#fragment"_s, "data:application/x-mpegurl,a#b#c"_s,
        };
        strings.append(String::fromUTF8("data:text/plain,\xC3\xA9 raw"));
        StringBuilder large;
        Random random(81);
        for (unsigned i = 0; i < 256 * 1024; ++i) {
            switch (random.below(4)) {
            case 0:
                large.append('%', hex(static_cast<uint8_t>(random.below(256)), 2));
                break;
            default:
                large.append(static_cast<char>('a' + random.below(26)));
                break;
            }
        }
        strings.append(makeString("data:text/plain;charset=utf-8,"_s, large.toString()));
        return dataURLInputs(strings);
    }());
    return inputs.get();
}

// Inputs the decoder rejects: no comma, a fragment in the header, bad base64 characters and padding.
static const Vector<DataURLInput>& invalidInputs()
{
    static NeverDestroyed<Vector<DataURLInput>> inputs([] {
        Vector<String> strings {
            "data:text/plain"_s, "data:"_s, "data:text/pl#ain,abc"_s, "data:;base64#x,abc"_s, "data:;base64,@@@@"_s,
            "data:;base64,abc="_s, "data:;base64,ab=c"_s, "data:;base64,a"_s, "data:;base64,abcde"_s, "data:;base64,ab%3D%3D%3D"_s,
            "data:;base64,===="_s, "data:;base64,YQ==YQ=="_s, "data:;base64,%ZZ"_s,
        };
        strings.append(String::fromUTF8("data:;base64,\xC3\xA9"));
        auto large = base64Payload(64 * 1024, 91);
        strings.append(makeString("data:;base64,"_s, large, "!"_s));
        strings.append(makeString("data:;base64,"_s, large.left(large.length() - 1)));
        return dataURLInputs(strings);
    }());
    return inputs.get();
}

static Vector<DataURLInput> sizedBase64Inputs(size_t size)
{
    auto payload = base64Payload(size, size);
    return dataURLInputs({ makeString("data:application/octet-stream;base64,"_s, payload), makeString("data:;base64,"_s, payload) });
}

static const Vector<DataURLInput>& base64Inputs1K()
{
    static NeverDestroyed<Vector<DataURLInput>> inputs(sizedBase64Inputs(1024));
    return inputs.get();
}

static const Vector<DataURLInput>& base64Inputs64K()
{
    static NeverDestroyed<Vector<DataURLInput>> inputs(sizedBase64Inputs(64 * 1024));
    return inputs.get();
}

// 4 KiB of text with every fourth character escaped.
static const Vector<DataURLInput>& percentInputs4K()
{
    static NeverDestroyed<Vector<DataURLInput>> inputs([] {
        StringBuilder body;
        Random random(83);
        for (unsigned i = 0; i < 4096; ++i) {
            if (!(i % 4))
                body.append('%', hex(static_cast<uint8_t>(random.below(256)), 2));
            else
                body.append(static_cast<char>('a' + random.below(26)));
        }
        return dataURLInputs({ makeString("data:text/plain;charset=utf-8,"_s, body.toString()) });
    }());
    return inputs.get();
}

} // namespace ChannelsAndBlobsBenchmark

using namespace ChannelsAndBlobsBenchmark;

// Not a workload: an empty test, whose process gives the start-up cost to subtract from the others.
TEST(ChannelsAndBlobsBench, StartUp)
{
}

TEST(ChannelsAndBlobsBench, RegisterDataSmall)
{
    run("RegisterDataSmall"_s, Recorded::registerDataSmall, Passes::registerDataSmall, [](Digest& digest, Excluded& excluded) {
        UNUSED_PARAM(excluded);
        return registerData(digest, excluded, 2000, 64, true);
    });
}

TEST(ChannelsAndBlobsBench, RegisterDataLarge)
{
    run("RegisterDataLarge"_s, Recorded::registerDataLarge, Passes::registerDataLarge, [](Digest& digest, Excluded& excluded) {
        UNUSED_PARAM(excluded);
        return registerData(digest, excluded, 16, 1024 * 1024, true);
    });
}

TEST(ChannelsAndBlobsBench, RegisterMultipart)
{
    run("RegisterMultipart"_s, Recorded::registerMultipart, Passes::registerMultipart, registerMultipart);
}

TEST(ChannelsAndBlobsBench, RegisterNoFileDirectory)
{
    run("RegisterNoFileDirectory"_s, Recorded::registerNoFileDirectory, Passes::registerNoFileDirectory, [](Digest& digest, Excluded& excluded) {
        UNUSED_PARAM(excluded);
        return registerData(digest, excluded, 2000, 64, false);
    });
}

TEST(ChannelsAndBlobsBench, SliceChain)
{
    run("SliceChain"_s, Recorded::sliceChain, Passes::sliceChain, sliceChain);
}

TEST(ChannelsAndBlobsBench, ResolveHit)
{
    run("ResolveHit"_s, Recorded::resolveHit, Passes::resolveHit, resolveHit);
}

TEST(ChannelsAndBlobsBench, ResolveMiss)
{
    run("ResolveMiss"_s, Recorded::resolveMiss, Passes::resolveMiss, resolveMiss);
}

TEST(ChannelsAndBlobsBench, ResolveWrongTopOrigin)
{
    run("ResolveWrongTopOrigin"_s, Recorded::resolveWrongTopOrigin, Passes::resolveWrongTopOrigin, resolveWrongTopOrigin);
}

TEST(ChannelsAndBlobsBench, SizeAndType)
{
    run("SizeAndType"_s, Recorded::sizeAndType, Passes::sizeAndType, sizeAndType);
}

TEST(ChannelsAndBlobsBench, HandleRefcount)
{
    run("HandleRefcount"_s, Recorded::handleRefcount, Passes::handleRefcount, blobPartitionedURLs);
}

TEST(ChannelsAndBlobsBench, UnregisterMix)
{
    run("UnregisterMix"_s, Recorded::unregisterMix, Passes::unregisterMix, blobRegisterUnregister);
}

TEST(ChannelsAndBlobsBench, RangeReadSmall)
{
    run("RangeReadSmall"_s, Recorded::rangeReadSmall, Passes::rangeReadSmall, rangeReadSmall);
}

TEST(ChannelsAndBlobsBench, RangeReadSuffix)
{
    run("RangeReadSuffix"_s, Recorded::rangeReadSuffix, Passes::rangeReadSuffix, blobReadSuffixRanges);
}

TEST(ChannelsAndBlobsBench, FullRead1MiB)
{
    run("FullRead1MiB"_s, Recorded::fullRead1MiB, Passes::fullRead1MiB, fullRead1MiB);
}

TEST(ChannelsAndBlobsBench, RangeError)
{
    run("RangeError"_s, Recorded::rangeError, Passes::rangeError, rangeError);
}

TEST(ChannelsAndBlobsBench, MethodNotAllowed)
{
    run("MethodNotAllowed"_s, Recorded::methodNotAllowed, Passes::methodNotAllowed, methodNotAllowed);
}

TEST(ChannelsAndBlobsBench, NotFound)
{
    run("NotFound"_s, Recorded::notFound, Passes::notFound, notFound);
}

TEST(ChannelsAndBlobsBench, DataURLBase64_1K)
{
    run("DataURLBase64_1K"_s, Recorded::dataURLBase64_1K, Passes::dataURLBase64_1K, [](Digest& digest, Excluded& excluded) {
        UNUSED_PARAM(excluded);
        return decodeAll<256>(digest, base64Inputs1K());
    });
}

TEST(ChannelsAndBlobsBench, DataURLBase64_64K)
{
    run("DataURLBase64_64K"_s, Recorded::dataURLBase64_64K, Passes::dataURLBase64_64K, [](Digest& digest, Excluded& excluded) {
        UNUSED_PARAM(excluded);
        return decodeAll<16>(digest, base64Inputs64K());
    });
}

TEST(ChannelsAndBlobsBench, DataURLPercent_4K)
{
    run("DataURLPercent_4K"_s, Recorded::dataURLPercent_4K, Passes::dataURLPercent_4K, [](Digest& digest, Excluded& excluded) {
        UNUSED_PARAM(excluded);
        return decodeAll<128>(digest, percentInputs4K());
    });
}

TEST(ChannelsAndBlobsBench, DataURLMalformed)
{
    run("DataURLMalformed"_s, Recorded::dataURLMalformed, Passes::dataURLMalformed, [](Digest& digest, Excluded& excluded) {
        UNUSED_PARAM(excluded);
        return decodeAll<64>(digest, invalidInputs());
    });
}

TEST(ChannelsAndBlobsBench, PortLifecycle)
{
    run("PortLifecycle"_s, Recorded::portLifecycle, Passes::portLifecycle, messagePortCreateClose);
}

TEST(ChannelsAndBlobsBench, PortTransferClaim)
{
    run("PortTransferClaim"_s, Recorded::portTransferClaim, Passes::portTransferClaim, messagePortTransfer);
}

TEST(ChannelsAndBlobsBench, PortPostTake)
{
    run("PortPostTake"_s, Recorded::portPostTake, Passes::portPostTake, messagePortPostTake);
}

TEST(ChannelsAndBlobsBench, MappingFileDrain)
{
    run("MappingFileDrain"_s, Recorded::mappingFileDrain, Passes::mappingFileDrain, mappingFileDrain);
}

// Further paths: error paths of the port registry, slice bounds, the asynchronous loader on large blobs, range
// boundaries, files, IndexedDB's writes, and the decoder's mixed inputs.

TEST(ChannelsAndBlobsBench, PortErrorPaths)
{
    run("PortErrorPaths"_s, Recorded::portErrorPaths, Passes::portErrorPaths, messagePortErrorPaths);
}

TEST(ChannelsAndBlobsBench, SliceBounds)
{
    run("SliceBounds"_s, Recorded::sliceBounds, Passes::sliceBounds, blobSlice);
}

TEST(ChannelsAndBlobsBench, FullReadAsync)
{
    run("FullReadAsync"_s, Recorded::fullReadAsync, Passes::fullReadAsync, blobReadWhole);
}

TEST(ChannelsAndBlobsBench, RangeReadBoundaries)
{
    run("RangeReadBoundaries"_s, Recorded::rangeReadBoundaries, Passes::rangeReadBoundaries, blobReadRanges);
}

TEST(ChannelsAndBlobsBench, FileRead)
{
    run("FileRead"_s, Recorded::fileRead, Passes::fileRead, blobReadFile);
}

TEST(ChannelsAndBlobsBench, WriteForIndexedDB)
{
    run("WriteForIndexedDB"_s, Recorded::writeForIndexedDB, Passes::writeForIndexedDB, blobWriteForIndexedDB);
}

TEST(ChannelsAndBlobsBench, DataURLBase64Mix)
{
    run("DataURLBase64Mix"_s, Recorded::dataURLBase64Mix, Passes::dataURLBase64Mix, [](Digest& digest, Excluded& excluded) {
        UNUSED_PARAM(excluded);
        return decodeAll<4>(digest, base64Inputs());
    });
}

TEST(ChannelsAndBlobsBench, DataURLPercentMix)
{
    run("DataURLPercentMix"_s, Recorded::dataURLPercentMix, Passes::dataURLPercentMix, [](Digest& digest, Excluded& excluded) {
        UNUSED_PARAM(excluded);
        return decodeAll<8>(digest, percentInputs());
    });
}

// A page's mix: a channel carrying blob URLs while the blobs are registered, sliced, read in ranges and revoked, and
// data: URLs decoded beside them.
TEST(ChannelsAndBlobsBench, RealisticMix)
{
    run("RealisticMix"_s, Recorded::realisticMix, Passes::realisticMix, [](Digest& digest, Excluded&) {
        auto ports = makeMessagePortChannelRegistry();
        auto blobs = makeBlobRegistry();
        auto port1 = portIdentifier(1, 1);
        auto port2 = portIdentifier(2, 2);
        ports->didCreateMessagePortChannel(port1, port2);
        auto& bodies = messageBodies();
        auto& decodes = base64Inputs();
        size_t bytes = 0;
        for (unsigned i = 0; i < 200; ++i) {
            auto url = internalBlobURL(i);
            size_t size = 1000 + (i * 131) % 30000;
            blobs->registerInternalBlobURL(url, dataParts({ size, 17 }, i), contentTypeFor(i));
            auto slice = internalBlobURL(10000 + i);
            blobs->registerInternalBlobURLForSlice(slice, url, i % 100, -static_cast<long long>(i % 50), "text/plain"_s);
            unsigned released = 0;
            digest.addBool(ports->didPostMessageToRemote({ bodies[i % bodies.size()].copyRef(), { } }, port2, countingScope(released)));
            bytes += takeAll(digest, ports.get(), port2);
            digest.addInteger(released);
            bytes += load(digest, blobs.get(), slice, i % 3 ? "bytes=10-500"_s : "bytes=-200"_s);
            auto& input = decodes[i % 12];
            addDecodeResult(digest, DataURLDecoder::decode(input.url));
            bytes += input.encodedLength;
            blobs->unregisterBlobURL(url, std::nullopt);
            bytes += load(digest, blobs.get(), slice);
            blobs->unregisterBlobURL(slice, std::nullopt);
        }
        ports->didCloseMessagePort(port1, MessagePortStatus::Closed);
        ports->didCloseMessagePort(port2, MessagePortStatus::Closed);
        return bytes;
    });
}

} // namespace TestWebKitAPI
