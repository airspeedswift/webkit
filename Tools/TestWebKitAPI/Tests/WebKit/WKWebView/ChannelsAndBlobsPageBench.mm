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

// Speed of the network process's broadcast-channel registry, shared-worker server, message-port routing and blob
// data task, driven from pages: they have no entry point a test process can call, so each workload is script in
// web views whose operations the network process carries out. One test per workload.
//
// Each pass runs the workload's script on deterministic inputs; the script folds everything it observes (messages
// received and their order per receiver, response status and headers, bytes, errors) into an FNV-1a digest it
// returns. By default a test runs one pass and EXPECT_EQs the digest against the workload's recorded checksum. With
// WEBKIT_RUN_BENCHMARKS set it then runs the workload's fixed number of passes (Passes::, sized so the passes take a
// second or more), checks every pass's digest, and prints
//     <Test>: <ms> ms <n> MB/s checksum=<digest>
// The number of passes never depends on time, so every build does the same work.
// The time includes the web and network processes' work and the IPC between them: these workloads are compared
// between builds run one after the other, not between copied frameworks.
//
// A suffix range of zero bytes ("Range: bytes=-0") is left out: it crashes the network process.

#import "config.h"

#import "Helpers/PlatformUtilities.h"
#import "Helpers/Test.h"
#import "Helpers/Utilities.h"
#import "Helpers/cocoa/HTTPServer.h"
#import "Helpers/cocoa/TestWKWebView.h"
#import <WebKit/WKWebViewConfiguration.h>
#import <WebKit/WKWebViewPrivate.h>
#import <cstdlib>
#import <wtf/MonotonicTime.h>
#import <wtf/RetainPtr.h>
#import <wtf/Seconds.h>

namespace TestWebKitAPI {

namespace ChannelsAndBlobsPageBenchmark {

// Recorded from the C++ build's first run.
namespace Recorded {
static constexpr auto broadcastChannelPostMessage = "a850a30061d5b369"_s;
static constexpr auto broadcastChannelRegisterUnregister = "179cca10aaf3e611"_s;
static constexpr auto messageChannelAcrossProcesses = "508aa71885a9db75"_s;
static constexpr auto sharedWorkerConnect = "60bede6e78a79865"_s;
static constexpr auto blobFetchRanges = "b86e0450a7c1506f"_s;
static constexpr auto blobFetchErrors = "f9b743450effbd25"_s;
}

// Each workload's number of passes under WEBKIT_RUN_BENCHMARKS, calibrated on the C++ build's timed run on an Apple M3
// so the passes take about a second and a half. The checksum is one pass's digest, so it does not depend on a count.
// A count never changes after this.
namespace Passes {
static constexpr unsigned broadcastChannelPostMessage = 8;
static constexpr unsigned broadcastChannelRegisterUnregister = 7;
static constexpr unsigned messageChannelAcrossProcesses = 70;
static constexpr unsigned sharedWorkerConnect = 90;
static constexpr unsigned blobFetchRanges = 12;
static constexpr unsigned blobFetchErrors = 220;
}

// Shared by every page: an FNV-1a digest over strings and numbers, as 16 hex digits.
static NSString *const digestScript = @R"JS(
class Digest {
    constructor() { this.value = 0xcbf29ce484222325n; }
    addByte(b) { this.value = ((this.value ^ BigInt(b & 0xff)) * 0x100000001b3n) & 0xffffffffffffffffn; }
    addNumber(n) { let v = BigInt.asUintN(64, BigInt(n)); for (let i = 0; i < 8; ++i) { this.addByte(Number(v & 0xffn)); v >>= 8n; } }
    addString(s) { if (s === null || s === undefined) { this.addByte(0); return; } this.addByte(1); this.addNumber(s.length); for (let i = 0; i < s.length; ++i) this.addNumber(s.charCodeAt(i)); }
    addBytes(u8) { this.addNumber(u8.length); for (const b of u8) this.addByte(b); }
    hex() { return this.value.toString(16).padStart(16, '0'); }
}
function pattern(size, seed) {
    const bytes = new Uint8Array(size);
    let state = BigInt(seed);
    for (let i = 0; i < size; ++i) {
        state = (state * 6364136223846793005n + 1442695040888963407n) & 0xffffffffffffffffn;
        bytes[i] = Number((state >> 33n) % 256n);
    }
    return bytes;
}
)JS";

static NSString *pageHTML()
{
    return [NSString stringWithFormat:@"<!DOCTYPE html><script>%@</script><body>bench</body>", digestScript];
}

static NSURL *pageURL()
{
    return [NSURL URLWithString:@"https://bench.example/"];
}

static RetainPtr<TestWKWebView> makeWebView(WKWebViewConfiguration *configuration)
{
    RetainPtr webView = adoptNS([[TestWKWebView alloc] initWithFrame:CGRectMake(0, 0, 100, 100) configuration:configuration]);
    [webView synchronouslyLoadHTMLString:pageHTML() baseURL:pageURL()];
    return webView;
}

struct PassResult {
    String digest;
    double bytes { 0 };
};

// The workload returns { digest, bytes }.
static PassResult callPass(TestWKWebView *webView, NSString *body, NSDictionary *arguments = @{ })
{
    NSError *error = nil;
    id result = [webView objectByCallingAsyncFunction:body withArguments:arguments error:&error];
    EXPECT_NULL(error);
    if (![result isKindOfClass:NSDictionary.class])
        return { };
    NSDictionary *dictionary = result;
    return { String(dictionary[@"digest"]), [dictionary[@"bytes"] doubleValue] };
}

template<typename Pass>
static void run(ASCIILiteral name, ASCIILiteral recorded, unsigned passes, const Pass& pass)
{
    auto first = pass();
    EXPECT_WK_STREQ(recorded, first.digest);
    if (first.digest != String(recorded))
        SAFE_PRINTF("%s: checksum=%s (recorded %s)\n", name, first.digest.utf8(), recorded);
    auto* benchmarks = getenv("WEBKIT_RUN_BENCHMARKS");
    if (!benchmarks || !*benchmarks || *benchmarks == '0')
        return;

    Seconds timed;
    double totalBytes = 0;
    unsigned mismatches = 0;
    for (unsigned i = 0; i < passes; ++i) {
        auto start = MonotonicTime::now();
        auto result = pass();
        timed += MonotonicTime::now() - start;
        totalBytes += result.bytes;
        mismatches += result.digest != first.digest;
    }
    EXPECT_EQ(0u, mismatches);
    SAFE_PRINTF("%s: %.1f ms %.3f MB/s checksum=%s\n", name, timed.milliseconds(), totalBytes / timed.microseconds(), first.digest.utf8());
    fflush(stdout);
}

// Broadcast channels between two web views of one origin (each in its own web content process), so every post is
// routed by the network process's registry. Receivers fold what they receive, per channel, in order.
static NSString *const broadcastPostMessageBody = @R"JS(
    // The receiver registers its channels with the network process over its own connection, which the network process
    // can read after this view's posts, and a post that arrives first is not delivered. So first ping on another
    // channel, which the receiver registers after the four, until it answers this pass's ping.
    const token = window.bench_syncToken = (window.bench_syncToken || 0) + 1;
    const sync = new BroadcastChannel('sync');
    await new Promise(resolve => {
        const timer = setInterval(() => sync.postMessage(token), 1);
        sync.onmessage = event => {
            if (event.data === token) {
                clearInterval(timer);
                resolve();
            }
        };
    });
    sync.close();
    const sizes = [0, 1, 16, 1000, 65536];
    const names = ['a', 'b', 'c', 'd'];
    let bytes = 0;
    const channels = names.map(name => new BroadcastChannel(name));
    for (let round = 0; round < rounds; ++round) {
        for (let n = 0; n < names.length; ++n) {
            for (const size of sizes) {
                const message = { round, name: names[n], data: pattern(size, round * 31 + size) };
                bytes += size;
                channels[n].postMessage(message);
            }
        }
    }
    channels.forEach(channel => channel.close());
    return { bytes };
)JS";

// The receiving view's script: listens on every channel and returns its digest once `expected` messages arrived; it
// answers the sender's pings on the sync channel.
static NSString *const broadcastReceiverBody = @R"JS(
    const names = ['a', 'b', 'c', 'd'];
    const digest = new Digest();
    let count = 0;
    const channels = names.map(name => new BroadcastChannel(name));
    // Registered after the four: the sender's ping on it is answered only once the four are registered.
    const sync = new BroadcastChannel('sync');
    sync.onmessage = event => sync.postMessage(event.data);
    const done = new Promise(resolve => {
        channels.forEach((channel, index) => {
            channel.onmessage = event => {
                digest.addNumber(index);
                digest.addNumber(event.data.round);
                digest.addString(event.data.name);
                digest.addBytes(event.data.data);
                if (++count == expected)
                    resolve();
            };
        });
    });
    window.bench_receiverReady = true;
    await done;
    sync.close();
    channels.forEach(channel => channel.close());
    return { digest: digest.hex(), bytes: 0 };
)JS";

static PassResult broadcastChannelPostMessage(TestWKWebView *sender, TestWKWebView *receiver)
{
    constexpr unsigned rounds = 20;
    __block bool received = false;
    __block PassResult receiverResult;
    [receiver callAsyncJavaScript:broadcastReceiverBody arguments:@{ @"expected": @(rounds * 4 * 5) } inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
        EXPECT_NULL(error);
        NSDictionary *dictionary = result;
        receiverResult = { String(dictionary[@"digest"]), 0 };
        received = true;
    }];
    while (![[receiver objectByEvaluatingJavaScript:@"window.bench_receiverReady === true"] boolValue])
        Util::spinRunLoop();
    auto sent = callPass(sender, broadcastPostMessageBody, @{ @"rounds": @(rounds) });
    Util::run(&received);
    [receiver objectByEvaluatingJavaScript:@"window.bench_receiverReady = false"];
    return { receiverResult.digest, 2 * sent.bytes };
}

// Channels registered and unregistered in bulk while a peer posts: delivery to channels open at the time, none after
// close, none to other names.
static NSString *const broadcastRegisterUnregisterBody = @R"JS(
    const digest = new Digest();
    let delivered = 0;
    for (let round = 0; round < rounds; ++round) {
        const listeners = [];
        for (let i = 0; i < 50; ++i) {
            const channel = new BroadcastChannel('ch' + (i % 10));
            const index = i;
            channel.onmessage = event => { digest.addNumber(index); digest.addString(event.data); ++delivered; };
            listeners.push(channel);
        }
        const poster = new BroadcastChannel('ch3');
        poster.postMessage('round' + round);
        await new Promise(resolve => setTimeout(resolve, 0));
        for (let i = 0; i < listeners.length; i += 2)
            listeners[i].close();
        poster.postMessage('after' + round);
        poster.close();
        await new Promise(resolve => setTimeout(resolve, 0));
        listeners.forEach(channel => channel.close());
    }
    // Delivery is asynchronous; wait for the counts the open channels imply, then fold the count.
    const expected = rounds * 5 + rounds * 2;
    while (delivered < expected)
        await new Promise(resolve => setTimeout(resolve, 1));
    digest.addNumber(delivered);
    return { digest: digest.hex(), bytes: rounds * 51 * 16 };
)JS";

// A MessageChannel port transferred to a cross-site iframe (127.0.0.1 and localhost on the test server; another web
// content process under site isolation), which echoes every message: the network process's message-port registry
// entangles the transferred port and routes every message.
static NSString *const echoFrameHTML = @"<script>onmessage = event => { const port = event.data.port; "
    "port.onmessage = message => port.postMessage(message.data); };</script>";

static NSString *const messageChannelBody = @R"JS(
    const frame = document.createElement('iframe');
    frame.src = frameURL;
    await new Promise(resolve => { frame.onload = resolve; document.body.appendChild(frame); });
    const digest = new Digest();
    let bytes = 0;
    for (let round = 0; round < rounds; ++round) {
        const channel = new MessageChannel();
        frame.contentWindow.postMessage({ port: channel.port2 }, '*', [channel.port2]);
        const echoes = new Promise(resolve => {
            let count = 0;
            channel.port1.onmessage = event => {
                digest.addNumber(event.data.index);
                digest.addBytes(event.data.data);
                if (++count == 8)
                    resolve();
            };
        });
        for (let i = 0; i < 8; ++i) {
            const data = pattern([0, 1, 100, 4096][i % 4], round * 8 + i);
            bytes += 2 * data.length;
            channel.port1.postMessage({ index: i, data });
        }
        await echoes;
        channel.port1.close();
    }
    frame.remove();
    return { digest: digest.hex(), bytes };
)JS";

// Shared workers: connect, message, disconnect, many clients of one worker and several workers; the worker counts its
// connections, so the server's reuse of a running worker is in the digest.
static NSString *const sharedWorkerBody = @R"JS(
    const source = `let connections = 0;
        onconnect = event => {
            const port = event.ports[0];
            const index = ++connections;
            port.onmessage = message => port.postMessage({ index, echo: message.data });
        };`;
    const scriptURL = URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));
    const digest = new Digest();
    for (let round = 0; round < rounds; ++round) {
        const workers = [];
        for (let i = 0; i < 6; ++i)
            workers.push(new SharedWorker(scriptURL, { name: 'worker' + (i % 3) }));
        for (const [i, worker] of workers.entries()) {
            const reply = new Promise(resolve => { worker.port.onmessage = event => resolve(event.data); });
            worker.port.postMessage('m' + i);
            const data = await reply;
            digest.addNumber(data.index);
            digest.addString(data.echo);
        }
        workers.forEach(worker => worker.port.close());
    }
    URL.revokeObjectURL(scriptURL);
    return { digest: digest.hex(), bytes: rounds * 6 * 64 };
)JS";

// Blob URLs fetched through the network process's blob data task: whole, sliced, closed, open and suffix ranges.
static NSString *const blobFetchRangesBody = @R"JS(
    const parts = [pattern(1000, 1), new Uint8Array(0), pattern(50000, 2), pattern(3, 3), pattern(3128, 4)];
    const blob = new Blob(parts, { type: 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const sliceURL = URL.createObjectURL(blob.slice(999, -100, 'application/x-slice'));
    const ranges = [null, 'bytes=0-0', 'bytes=999-1000', 'bytes=1000-51000', 'bytes=0-54131', 'bytes=54130-', 'bytes=0-',
        'bytes=-1', 'bytes=-3128', 'bytes=-54131', 'bytes=-99999999', 'bytes = 10 - 20'];
    const digest = new Digest();
    let bytes = 0;
    for (let round = 0; round < rounds; ++round) {
        for (const target of [url, sliceURL]) {
            for (const range of ranges) {
                try {
                    const response = await fetch(target, range ? { headers: { Range: range } } : { });
                    digest.addNumber(response.status);
                    digest.addString(response.headers.get('Content-Type'));
                    digest.addString(response.headers.get('Content-Length'));
                    digest.addString(response.headers.get('Content-Range'));
                    const body = new Uint8Array(await response.arrayBuffer());
                    digest.addBytes(body);
                    bytes += body.length;
                } catch (error) {
                    digest.addString(error.name);
                }
            }
        }
    }
    URL.revokeObjectURL(url);
    URL.revokeObjectURL(sliceURL);
    return { digest: digest.hex(), bytes };
)JS";

// Blob fetches that fail: unsatisfiable and malformed ranges, other methods, revoked URLs.
static NSString *const blobFetchErrorsBody = @R"JS(
    const blob = new Blob([pattern(5000, 9)], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const revoked = URL.createObjectURL(new Blob(['gone']));
    URL.revokeObjectURL(revoked);
    const digest = new Digest();
    const attempts = [
        [url, { headers: { Range: 'bytes=5-2' } }], [url, { headers: { Range: 'bytes=5000-' } }],
        [url, { headers: { Range: 'bytes=0-1,3-4' } }], [url, { headers: { Range: 'items=0-1' } }],
        [url, { method: 'POST' }], [url, { method: 'HEAD' }], [revoked, { }],
    ];
    for (let round = 0; round < rounds; ++round) {
        for (const [target, init] of attempts) {
            try {
                const response = await fetch(target, init);
                digest.addNumber(response.status);
                digest.addString(response.headers.get('Content-Range'));
                digest.addBytes(new Uint8Array(await response.arrayBuffer()));
            } catch (error) {
                digest.addString(error.name);
            }
        }
    }
    URL.revokeObjectURL(url);
    return { digest: digest.hex(), bytes: rounds * attempts.length * 64 };
)JS";

// The tests stay in this namespace: the file is a unified source, and a using-directive would reach the files
// compiled after it.
TEST(ChannelsAndBlobsPageBench, StartUp)
{
}

TEST(ChannelsAndBlobsPageBench, BroadcastChannelPostMessage)
{
    RetainPtr configuration = adoptNS([[WKWebViewConfiguration alloc] init]);
    auto sender = makeWebView(configuration.get());
    auto receiver = makeWebView(configuration.get());
    run("BroadcastChannelPostMessage"_s, Recorded::broadcastChannelPostMessage, Passes::broadcastChannelPostMessage, [&] {
        return broadcastChannelPostMessage(sender.get(), receiver.get());
    });
}

TEST(ChannelsAndBlobsPageBench, BroadcastChannelRegisterUnregister)
{
    RetainPtr configuration = adoptNS([[WKWebViewConfiguration alloc] init]);
    auto webView = makeWebView(configuration.get());
    run("BroadcastChannelRegisterUnregister"_s, Recorded::broadcastChannelRegisterUnregister, Passes::broadcastChannelRegisterUnregister, [&] {
        return callPass(webView.get(), broadcastRegisterUnregisterBody, @{ @"rounds": @20 });
    });
}

TEST(ChannelsAndBlobsPageBench, MessageChannelAcrossProcesses)
{
    HTTPServer server({
        { "/"_s, { String(pageHTML()) } },
        { "/echo"_s, { String(echoFrameHTML) } },
    });
    RetainPtr configuration = adoptNS([[WKWebViewConfiguration alloc] init]);
    RetainPtr webView = adoptNS([[TestWKWebView alloc] initWithFrame:CGRectMake(0, 0, 100, 100) configuration:configuration.get()]);
    [webView synchronouslyLoadRequest:server.request()];
    NSString *frameURL = server.requestWithLocalhost("/echo"_s).URL.absoluteString;
    run("MessageChannelAcrossProcesses"_s, Recorded::messageChannelAcrossProcesses, Passes::messageChannelAcrossProcesses, [&] {
        return callPass(webView.get(), messageChannelBody, @{ @"rounds": @20, @"frameURL": frameURL });
    });
}

TEST(ChannelsAndBlobsPageBench, SharedWorkerConnect)
{
    RetainPtr configuration = adoptNS([[WKWebViewConfiguration alloc] init]);
    auto webView = makeWebView(configuration.get());
    run("SharedWorkerConnect"_s, Recorded::sharedWorkerConnect, Passes::sharedWorkerConnect, [&] {
        return callPass(webView.get(), sharedWorkerBody, @{ @"rounds": @10 });
    });
}

TEST(ChannelsAndBlobsPageBench, BlobFetchRanges)
{
    RetainPtr configuration = adoptNS([[WKWebViewConfiguration alloc] init]);
    auto webView = makeWebView(configuration.get());
    run("BlobFetchRanges"_s, Recorded::blobFetchRanges, Passes::blobFetchRanges, [&] {
        return callPass(webView.get(), blobFetchRangesBody, @{ @"rounds": @5 });
    });
}

TEST(ChannelsAndBlobsPageBench, BlobFetchErrors)
{
    RetainPtr configuration = adoptNS([[WKWebViewConfiguration alloc] init]);
    auto webView = makeWebView(configuration.get());
    run("BlobFetchErrors"_s, Recorded::blobFetchErrors, Passes::blobFetchErrors, [&] {
        return callPass(webView.get(), blobFetchErrorsBody, @{ @"rounds": @10 });
    });
}

} // namespace ChannelsAndBlobsPageBenchmark

} // namespace TestWebKitAPI
