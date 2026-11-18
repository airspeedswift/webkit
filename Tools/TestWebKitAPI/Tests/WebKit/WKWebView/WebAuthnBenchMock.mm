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

#if ENABLE(WEB_AUTHN) && HAVE(UNIFIED_ASC_AUTH_UI)

#import "Helpers/PlatformUtilities.h"
#import "Helpers/Test.h"
#import "Helpers/cocoa/TestWKWebView.h"
#import "Helpers/cocoa/WKWebViewConfigurationExtras.h"
#import <WebKit/WKWebViewConfigurationPrivate.h>
#import <wtf/MonotonicTime.h>
#import <wtf/RetainPtr.h>
#import <wtf/text/WTFString.h>

// The benchmark that drives CtapAuthenticator over the mock HID device in the UI process: a makeCredential ceremony
// whose device responses are canned, from the request encoder through the transport to the parsed attestation.
// The page reports "Succeeded!" when the ceremony completes. The checksum covers the number of ceremonies completed,
// since the response bytes are fixed by the page.

namespace TestWebKitAPI {

static constexpr uint64_t kUnrecorded = 0;
// A ceremony takes a few hundred milliseconds, so a fixed count, not a time limit, keeps the work the same from run to run.
static constexpr unsigned kBenchmarkCeremonies = 3;
static constexpr uint64_t kExpectedChecksum = 0x89cd31291d2aefa4ULL;

static RetainPtr<TestWKWebView> setUpBenchWebView()
{
    auto *configuration = [WKWebViewConfiguration _test_configurationWithTestPlugInClassName:@"WebProcessPlugInWithInternals" configureJSCForTesting:YES];
    [configuration _setAllowTestOnlyIPC:YES];
    return adoptNS([[TestWKWebView alloc] initWithFrame:NSZeroRect configuration:configuration]);
}

static uint64_t ceremony()
{
    RetainPtr<NSURL> testURL = [NSBundle.test_resourcesBundle URLForResource:@"web-authentication-bench-make-credential-hid" withExtension:@"html"];
    auto webView = setUpBenchWebView();
    [webView focus];
    [webView loadRequest:[NSURLRequest requestWithURL:testURL.get()]];
    [webView waitForMessage:@"Succeeded!"];
    // FNV-1a of one completed ceremony.
    uint64_t state = 0xcbf29ce484222325ULL;
    for (uint64_t i = 0; i < 8; ++i) {
        state ^= (i == 0) ? 1 : 0;
        state *= 0x100000001b3ULL;
    }
    return state;
}

TEST(WebAuthnBench, CtapMakeCredentialMock)
{
    uint64_t checksum = ceremony();
    if (kExpectedChecksum == kUnrecorded)
        SAFE_PRINTF("CtapMakeCredentialMock: UNRECORDED checksum=%016llx\n", static_cast<unsigned long long>(checksum));
    EXPECT_EQ(kExpectedChecksum, checksum);
    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    unsigned passes = 0;
    auto start = MonotonicTime::now();
    Seconds elapsed;
    do {
        if (ceremony() != checksum)
            ADD_FAILURE() << "checksum changed";
        ++passes;
        elapsed = MonotonicTime::now() - start;
    } while (passes < kBenchmarkCeremonies);
    SAFE_PRINTF("CtapMakeCredentialMock: %.1f ms %.1f MB/s checksum=%016llx\n", elapsed.milliseconds(),
        static_cast<double>(passes) * 2048 / elapsed.microseconds(), static_cast<unsigned long long>(checksum));
}

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUTHN) && HAVE(UNIFIED_ASC_AUTH_UI)
