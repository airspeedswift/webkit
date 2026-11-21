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

#import "Helpers/PlatformUtilities.h"
#import "Helpers/Test.h"
#import "Helpers/cocoa/HTTPServer.h"
#import "Helpers/cocoa/TestNavigationDelegate.h"
#import <WebKit/WKPagePrivate.h>
#import <WebKit/WKProcessPoolPrivate.h>
#import <WebKit/WKWebViewPrivate.h>
#import <WebKit/WKWebViewPrivateForTesting.h>
#import <WebKit/WKWebsiteDataRecordPrivate.h>
#import <WebKit/WKWebsiteDataStorePrivate.h>
#import <WebKit/_WKWebsiteDataStoreConfiguration.h>
#import <wtf/MonotonicTime.h>
#import <wtf/RetainPtr.h>
#import <wtf/text/MakeString.h>

// Benchmarks of the Private Click Measurement store, manager and database through the testing SPI. Each test is
// bound by IPC to the network process, so only coarse differences show; the checksum never covers a time or a send
// order.

namespace TestWebKitAPI {

namespace PCMStoreBench {

class Digest {
public:
    void add(uint64_t value)
    {
        for (unsigned i = 0; i < 8; ++i) {
            m_hash ^= (value >> (i * 8)) & 0xff;
            m_hash *= 0x100000001b3ull;
        }
    }
    void add(NSString *string)
    {
        add(static_cast<uint64_t>(string ? string.length : 0xffff));
        for (NSUInteger i = 0; i < string.length; ++i)
            add(static_cast<uint64_t>([string characterAtIndex:i]));
    }
    uint64_t value() const { return m_hash; }

private:
    uint64_t m_hash { 0xcbf29ce484222325ull };
};

// A fixed xorshift stream, so every run sees the same operations.
class Random {
public:
    uint32_t next()
    {
        m_state ^= m_state << 13;
        m_state ^= m_state >> 7;
        m_state ^= m_state << 17;
        return static_cast<uint32_t>(m_state >> 16);
    }
    unsigned below(unsigned limit) { return next() % limit; }

private:
    uint64_t m_state { 0x9e3779b97f4a7c15ull };
};

constexpr unsigned clickCount = 200;

static NSURL *sourceURL(unsigned i) { return [NSURL URLWithString:[NSString stringWithFormat:@"https://source%u.example/", i]]; }
// NetworkSession::simulatePrivateClickMeasurementConversion only converts for pcmdestination.example, one
// registrable domain: even indexes name it, so half of the conversions attribute a stored click and the others
// find none; odd indexes name a site of their own.
static NSURL *destinationURL(unsigned i)
{
    if (!(i % 2))
        return [NSURL URLWithString:@"https://pcmdestination.example/"];
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://destination%u.example/", i]];
}

static RetainPtr<SecTrustRef> trustFromCertificateChain(NSArray *chain)
{
    SecTrustRef trustRef = nullptr;
    if (SecTrustCreateWithCertificates((__bridge CFArrayRef)chain, nullptr, &trustRef) != noErr)
        return nullptr;
    return adoptCF(trustRef);
}

class Store {
public:
    enum class Kind : bool { Persistent, Ephemeral };

    explicit Store(Kind kind)
    {
        RetainPtr<WKWebsiteDataStore> dataStore;
        if (kind == Kind::Ephemeral)
            dataStore = [WKWebsiteDataStore nonPersistentDataStore];
        else {
            m_directory = adoptNS([[NSURL alloc] initFileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString] isDirectory:YES]);
            RetainPtr dataStoreConfiguration = adoptNS([[_WKWebsiteDataStoreConfiguration alloc] initWithDirectory:m_directory.get()]);
            dataStoreConfiguration.get()._resourceLoadStatisticsDirectory = m_directory.get();
            dataStoreConfiguration.get().pcmMachServiceName = nil;
            dataStore = adoptNS([[WKWebsiteDataStore alloc] _initWithConfiguration:dataStoreConfiguration.get()]);
        }
        RetainPtr configuration = adoptNS([WKWebViewConfiguration new]);
        configuration.get().websiteDataStore = dataStore.get();
        m_webView = adoptNS([[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) configuration:configuration.get()]);
        [dataStore _setResourceLoadStatisticsEnabled:YES];
        // An active network process is needed for any PCM operation.
        RetainPtr delegate = adoptNS([TestNavigationDelegate new]);
        [m_webView setNavigationDelegate:delegate.get()];
        [m_webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]]];
        [delegate waitForDidFinishNavigation];
        // Override timer: without it the dump prints random send delays.
        setOverrideTimer(true);
        setAppBundleID(@"test.bundle.id");
    }

    ~Store()
    {
        if (!m_directory)
            return;
        bool closed = false;
        [dataStore() _closeDatabases:[&] { closed = true; }];
        Util::run(&closed);
        [[NSFileManager defaultManager] removeItemAtURL:m_directory.get() error:nil];
    }

    WKWebsiteDataStore *dataStore() { return [m_webView configuration].websiteDataStore; }

    void setOverrideTimer(bool value)
    {
        bool done = false;
        [m_webView _setPrivateClickMeasurementOverrideTimerForTesting:value completionHandler:[&] {
            done = true;
        }];
        Util::run(&done);
    }

    void setAppBundleID(NSString *bundleID)
    {
        bool done = false;
        [m_webView _setPrivateClickMeasurementAppBundleIDForTesting:bundleID completionHandler:[&] {
            done = true;
        }];
        Util::run(&done);
    }

    void setReportURLs(NSURL *url)
    {
        bool done = false;
        [m_webView _setPrivateClickMeasurementAttributionReportURLsForTesting:url destinationURL:url completionHandler:[&] {
            done = true;
        }];
        Util::run(&done);
    }

    void storeUnattributed(unsigned sourceIndex, unsigned destinationIndex, uint8_t sourceID)
    {
        [m_webView _storePrivateClickMeasurementWithSourceID:sourceID destinationURL:destinationURL(destinationIndex) reportEndpoint:sourceURL(sourceIndex)];
    }

    // The SPI with ephemeral:YES only sets the page's pending measurement for a later navigation. This test never
    // navigates, so no click reaches the network session's store: it times the assignment in the UI process.
    void storeEphemeral(unsigned sourceIndex, unsigned destinationIndex, uint8_t sourceID)
    {
        [m_webView _addEventAttributionWithSourceID:sourceID destinationURL:destinationURL(destinationIndex) sourceDescription:@"source description" purchaser:@"purchaser" reportEndpoint:sourceURL(sourceIndex) optionalNonce:nil applicationBundleID:@"test.bundle.id" ephemeral:YES];
    }

    void convert(unsigned sourceIndex, unsigned destinationIndex, uint8_t priority, uint8_t triggerData)
    {
        [m_webView _storeSimulatedPrivateClickMeasurementConversionWithPriority:priority triggerData:triggerData sourceURL:sourceURL(sourceIndex) destinationURL:destinationURL(destinationIndex)];
    }

    // Every operation above is one way, in order, on one connection; the dump is the barrier that waits for them.
    RetainPtr<NSString> dump()
    {
        RetainPtr<NSString> result;
        [m_webView _dumpPrivateClickMeasurement:[&](NSString *dumped) { result = dumped; }];
        while (!result)
            Util::spinRunLoop();
        return result;
    }

    void markUnattributedExpired()
    {
        bool done = false;
        WKPageMarkPrivateClickMeasurementsAsExpiredForTesting([m_webView _pageRefForTransitionToWKWebView], [](void* context) { *static_cast<bool*>(context) = true; }, &done);
        Util::run(&done);
    }

    RetainPtr<NSArray<WKWebsiteDataRecord *>> fetchRecords()
    {
        RetainPtr<NSArray<WKWebsiteDataRecord *>> result;
        [dataStore() fetchDataRecordsOfTypes:[NSSet setWithObject:_WKWebsiteDataTypePrivateClickMeasurements] completionHandler:[&](NSArray<WKWebsiteDataRecord *> *records) { result = records; }];
        while (!result)
            Util::spinRunLoop();
        return result;
    }

    void clearAll()
    {
        bool done = false;
        [dataStore() removeDataOfTypes:[NSSet setWithObject:_WKWebsiteDataTypePrivateClickMeasurements] modifiedSince:[NSDate distantPast] completionHandler:[&] {
            done = true;
        }];
        Util::run(&done);
    }

    void clearRecords(NSArray<WKWebsiteDataRecord *> *records)
    {
        bool done = false;
        [dataStore() removeDataOfTypes:[NSSet setWithObject:_WKWebsiteDataTypePrivateClickMeasurements] forDataRecords:records completionHandler:[&] {
            done = true;
        }];
        Util::run(&done);
    }

private:
    RetainPtr<NSURL> m_directory;
    RetainPtr<WKWebView> m_webView;
};

static void digestRecords(Digest& digest, NSArray<WKWebsiteDataRecord *> *records)
{
    // The store returns records in its own order; the digest sorts them.
    RetainPtr names = adoptNS([NSMutableArray new]);
    for (WKWebsiteDataRecord *record in records)
        [names addObject:record.displayName];
    [names sortUsingSelector:@selector(compare:)];
    digest.add(static_cast<uint64_t>([names count]));
    for (NSString *name in names.get())
        digest.add(name);
}

static void fillUnattributed(Store& store, unsigned count = clickCount)
{
    Random random;
    for (unsigned i = 0; i < count; ++i)
        store.storeUnattributed(i % 50, random.below(40), random.below(256));
}

template<typename Pass>
static void run(ASCIILiteral name, uint64_t expectedChecksum, uint64_t operationsPerPass, unsigned passes, Pass&& pass)
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
    // The rate is in millions of operations per second, printed as MB/s like the WebCore benchmark.
    SAFE_PRINTF("%s: %.1f ms %.7f MB/s checksum=%016llx\n", name, milliseconds, static_cast<double>(operationsPerPass) * passes / milliseconds * 1000 / 1e6, static_cast<unsigned long long>(checksum));
}

} // namespace PCMStoreBench

using namespace PCMStoreBench;

// The empty test: the cost of starting the test process, which every test pays.
TEST(PrivateClickMeasurementStoreBench, StartUp)
{
}

// Store clicks that have no attribution yet (Database::insertPrivateClickMeasurement, unattributed, after the
// manager's clearExpired), clearing between passes so each pass inserts into an empty database.
TEST(PrivateClickMeasurementStoreBench, StoreUnattributed)
{
    Store store(Store::Kind::Persistent);
    run("StoreUnattributed"_s, 0x3cef02645eee11d5, clickCount, 95, [&] {
        store.clearAll();
        fillUnattributed(store);
        Digest digest;
        digest.add(store.dump().get());
        return digest.value();
    });
}

// A conversion for each stored click with nothing attributed before it (attributePrivateClickMeasurement's first path).
TEST(PrivateClickMeasurementStoreBench, AttributeFirst)
{
    Store store(Store::Kind::Persistent);
    run("AttributeFirst"_s, 0x89334938ebd74018, clickCount, 55, [&] {
        store.clearAll();
        Random random;
        for (unsigned i = 0; i < clickCount; ++i) {
            unsigned destination = random.below(40);
            store.storeUnattributed(i % 50, destination, random.below(256));
            store.convert(i % 50, destination, random.below(64), random.below(16));
        }
        Digest digest;
        digest.add(store.dump().get());
        return digest.value();
    });
}

// A second conversion for pairs already attributed: a lower, equal and higher priority (at 0 and 63 the lower or
// higher one is out of range).
TEST(PrivateClickMeasurementStoreBench, AttributeWithPrior)
{
    Store store(Store::Kind::Persistent);
    run("AttributeWithPrior"_s, 0x2402efb7044a638c, clickCount * 2, 30, [&] {
        store.clearAll();
        Random random;
        for (unsigned i = 0; i < clickCount; ++i) {
            unsigned destination = random.below(40);
            uint8_t priority = random.below(64);
            store.storeUnattributed(i % 50, destination, random.below(256));
            store.convert(i % 50, destination, priority, random.below(16));
            store.storeUnattributed(i % 50, destination, random.below(256));
            store.convert(i % 50, destination, !(i % 3) ? priority - 1 : i % 3 == 1 ? priority : priority + 1, random.below(16));
        }
        Digest digest;
        digest.add(store.dump().get());
        return digest.value();
    });
}

// clearPrivateClickMeasurement(): everything, unattributed and attributed.
TEST(PrivateClickMeasurementStoreBench, Clear)
{
    run("Clear"_s, 0xf81c177a1bf31c7a, clickCount, 7, [&] {
        // A fresh store per pass: a second pass on one store dumps differently.
        Store store(Store::Kind::Persistent);
        fillUnattributed(store);
        store.convert(0, 0, 1, 1);
        Digest digest;
        digest.add(store.dump().get());
        store.clearAll();
        digest.add(store.dump().get());
        digestRecords(digest, store.fetchRecords().get());
        return digest.value();
    });
}

// clearPrivateClickMeasurementForRegistrableDomain per fetched record, half of the records.
TEST(PrivateClickMeasurementStoreBench, ClearByDomain)
{
    Store store(Store::Kind::Persistent);
    run("ClearByDomain"_s, 0x4108495d1801527a, clickCount / 2, 80, [&] {
        store.clearAll();
        fillUnattributed(store);
        auto records = store.fetchRecords();
        RetainPtr selected = adoptNS([NSMutableArray new]);
        NSUInteger index = 0;
        for (WKWebsiteDataRecord *record in records.get()) {
            if (!(index++ % 2))
                [selected addObject:record];
        }
        Digest digest;
        digest.add(static_cast<uint64_t>(records.get().count));
        store.clearRecords(selected.get());
        digest.add(store.dump().get());
        digestRecords(digest, store.fetchRecords().get());
        return digest.value();
    });
}

// The fetch of the stored domains (allDomains and fetchRegistrableDomains) and the dump (toStringForTesting, which
// reads every row of both tables), on a database filled once.
TEST(PrivateClickMeasurementStoreBench, FetchAndDump)
{
    Store store(Store::Kind::Persistent);
    fillUnattributed(store);
    // No conversions: the override timer sends an attributed click (and removes it) at once, so a dump taken in a later
    // pass would differ from the first.
    store.dump();
    run("FetchAndDump"_s, 0x61d19e3aee0041c9, 20, 160, [&] {
        Digest digest;
        for (unsigned i = 0; i < 10; ++i) {
            digest.add(store.dump().get());
            digestRecords(digest, store.fetchRecords().get());
        }
        return digest.value();
    });
}

// Expired unattributed clicks, cleared by the manager's clearExpired before the next store and attribution
// (Database::clearExpiredPrivateClickMeasurement).
TEST(PrivateClickMeasurementStoreBench, ExpiredClear)
{
    Store store(Store::Kind::Persistent);
    run("ExpiredClear"_s, 0x17c2a387d12fd2f2, clickCount, 100, [&] {
        store.clearAll();
        fillUnattributed(store);
        store.markUnattributedExpired();
        // The store after the marking clears the expired rows first.
        store.storeUnattributed(1, 1, 7);
        Digest digest;
        digest.add(store.dump().get());
        return digest.value();
    });
}

// The timer path: with the override timer, each attributed click sends its two reports at once to a local server and
// is removed.
// The checksum is the count of requests and the dump afterwards, not the bodies' order.
TEST(PrivateClickMeasurementStoreBench, ExpiredTimerPath)
{
    // As EventAttribution.mm's runBasicPCMTest: the network process must not suspend while it waits for the timer.
    [WKWebsiteDataStore _setNetworkProcessSuspensionAllowedForTesting:NO];
    HTTPServer server({ { "/"_s, { } } }, HTTPServer::Protocol::Https);
    constexpr unsigned reportCount = 20;
    size_t requestsBefore = 0;
    run("ExpiredTimerPath"_s, 0xa7831661c0c3582b, reportCount, 1, [&] {
        Store store(Store::Kind::Persistent);
        [store.dataStore() _trustServerForLocalPCMTesting:trustFromCertificateChain(@[(id)testCertificate().get()]).get()];
        store.setReportURLs(server.request().URL);
        for (unsigned i = 0; i < reportCount; ++i) {
            store.storeUnattributed(i, 2 * i, i);
            store.convert(i, 2 * i, 1, 1);
        }
        store.dump();
        // Each attribution sends two reports (the source's and the destination's). Bounded (30 s): wait for every
        // report, then let a stray one arrive for half a second.
        auto deadline = MonotonicTime::now() + 30_s;
        size_t before = requestsBefore;
        while (server.totalRequests() - before < 2 * reportCount && MonotonicTime::now() < deadline)
            Util::runFor(0.01_s);
        Util::runFor(0.5_s);
        Digest digest;
        digest.add(static_cast<uint64_t>(server.totalRequests() - before));
        requestsBefore = server.totalRequests();
        digest.add(store.dump().get());
        return digest.value();
    });
}

// The same operations with a non-persistent data store and ephemeral:YES clicks. With no navigation the pending
// measurement is all it reaches: the dump, fetch and clear see an empty store.
TEST(PrivateClickMeasurementStoreBench, Ephemeral)
{
    Store store(Store::Kind::Ephemeral);
    run("Ephemeral"_s, 0x033bd8b4ac796545, clickCount, 2800, [&] {
        store.clearAll();
        Random random;
        for (unsigned i = 0; i < clickCount; ++i) {
            unsigned destination = random.below(40);
            // Only the click: a conversion would send its report (the override timer) while the dump is taken.
            store.storeEphemeral(i % 50, destination, random.below(256));
        }
        Digest digest;
        digest.add(store.dump().get());
        digestRecords(digest, store.fetchRecords().get());
        store.clearAll();
        digest.add(store.dump().get());
        return digest.value();
    });
}

} // namespace TestWebKitAPI

#endif // PLATFORM(MAC)
