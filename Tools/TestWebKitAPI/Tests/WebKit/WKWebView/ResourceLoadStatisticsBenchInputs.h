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

#pragma once

#include <array>
#include <cstdint>

// The one source of the benchmark's sizes and name pools. The memory probe and the oracle read this file, never a copy.
namespace TestWebKitAPI::ResourceLoadStatisticsBenchInputs {

// Registrable-domain suffixes, a mix of one-label and two-label public suffixes so the public-suffix lookup in
// RegistrableDomain is exercised, as the hosts a browsing session sees are.
inline constexpr std::array<const char*, 8> suffixes { "com", "org", "net", "co.uk", "example", "io", "de", "com.au" };

inline constexpr unsigned databaseDomains = 1000; // each testing-entry-point call is a round trip to the network process (~0.1-0.5 ms), which sets the size
inline constexpr unsigned topFrameDomains = 60; // first parties the third parties are seen under
inline constexpr unsigned mergeBatchSize = 250; // calls in flight before the shape waits
inline constexpr unsigned mergePasses = 2; // re-merges of the same domains (the update half of MergeBatches)
inline constexpr unsigned updatePasses = 3; // relation passes of UpdateBatches
inline constexpr unsigned classificationPasses = 4;
inline constexpr unsigned prevalentSeedEvery = 40; // every 40th domain is marked prevalent before classifying
inline constexpr unsigned redirectFanout = 1; // redirect edges per domain
inline constexpr unsigned storageAccessFrames = 24; // third-party subframes under one top frame
inline constexpr unsigned storageAccessChecksPerFrame = 700; // document.hasStorageAccess() calls per frame
inline constexpr unsigned deletePasses = 5;
inline constexpr unsigned dumpPasses = 5;

// Seconds a statistic is aged, kept away from the 24-hour boundary the dump prints ("within 24 hours"), so a dump
// is the same on every run.
inline constexpr double recentAgeSeconds = 3600;
inline constexpr double staleAgeSeconds = 60.0 * 24 * 3600 * 3;

} // namespace TestWebKitAPI::ResourceLoadStatisticsBenchInputs
