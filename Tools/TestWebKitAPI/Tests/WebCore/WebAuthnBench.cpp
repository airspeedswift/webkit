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

#if ENABLE(WEB_AUTHN)

#include <wtf/StdLibExtras.h>

#include "FidoTestData.h"
#include "WebAuthnBenchInputs.h"
#include <WebCore/ApduCommand.h>
#include <WebCore/ApduResponse.h>
#include <WebCore/AuthenticationExtensionsClientInputs.h>
#include <WebCore/AuthenticatorAttachment.h>
#include <WebCore/AuthenticatorSelectionCriteria.h>
#include <WebCore/CBORReader.h>
#include <WebCore/CBORValue.h>
#include <WebCore/CBORWriter.h>
#include <WebCore/CryptoAlgorithmECDH.h>
#include <WebCore/CryptoKeyAES.h>
#include <WebCore/CryptoKeyEC.h>
#include <WebCore/CryptoKeyHMAC.h>
#include <WebCore/DeviceRequestConverter.h>
#include <WebCore/DeviceResponseConverter.h>
#include <WebCore/ExceptionOr.h>
#include <WebCore/FidoConstants.h>
#include <WebCore/FidoHidMessage.h>
#include <WebCore/FidoHidPacket.h>
#include <WebCore/Pin.h>
#include <WebCore/PublicKeyCredentialCreationOptions.h>
#include <WebCore/PublicKeyCredentialRequestOptions.h>
#include <WebCore/ScriptWrappableInlines.h>
#include <WebCore/U2fCommandConstructor.h>
#include <WebCore/U2fResponseConverter.h>
#include <WebCore/WebAuthenticationConstants.h>
#include <WebCore/WebAuthenticationUtils.h>
#include <cstdio>
#include <cstdlib>
#include <wtf/MonotonicTime.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

// One TEST per benchmark of the WebAuthn authenticator protocol code: the CBOR reader and writer, the CTAP and U2F
// response parsers, the request encoders, the APDU and HID framing, the PIN protocol. Each calls the production entry
// points and checks a digest of everything it observed (results, error codes, output bytes). With WEBKIT_RUN_BENCHMARKS
// set it then repeats the pass a fixed number of times and prints the time taken.
//
// The benchmark that drives CtapAuthenticator over the mock HID device is in Tests/WebKit/WKWebView/WebAuthnBenchMock.mm,
// since it needs the UI process.
//
// Each expected checksum is the digest of one pass's outputs. A test given kUnrecorded prints
// "<Name>: UNRECORDED checksum=<digest>" instead, to record a new one.

namespace TestWebKitAPI {

namespace WebAuthnBenchmark {

using namespace WebCore;
using namespace WebAuthnBenchInputs;

// Stands for a checksum not yet recorded.
static constexpr uint64_t kUnrecorded = 0;

template<typename Pass>
static void run(ASCIILiteral name, size_t bytes, uint64_t expected, unsigned passes, Pass&& pass)
{
    uint64_t checksum = pass();
    if (expected == kUnrecorded)
        SAFE_PRINTF("%s: UNRECORDED checksum=%016llx\n", name, static_cast<unsigned long long>(checksum));
    EXPECT_EQ(expected, checksum);
    if (!getenv("WEBKIT_RUN_BENCHMARKS"))
        return;

    unsigned mismatches = 0;
    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < passes; ++i) {
        if (pass() != checksum)
            ++mismatches;
    }
    Seconds elapsed = MonotonicTime::now() - start;
    EXPECT_EQ(0u, mismatches);
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, elapsed.milliseconds(),
        static_cast<double>(bytes) * passes / elapsed.microseconds(), static_cast<unsigned long long>(checksum));
}

using Bytes = std::span<const uint8_t>;

static void readAndHash(Hash& hash, Bytes bytes, int maxNesting = cbor::CBORReader::kCBORMaxDepth)
{
    auto error = cbor::CBORReader::DecoderError::CBORNoError;
    auto value = cbor::CBORReader::read(bytes, &error, maxNesting);
    hash.addFlag(!!value);
    hash.add(static_cast<uint64_t>(error));
    if (value)
        hashValue(hash, *value);
}

static void hashBuffer(Hash& hash, JSC::ArrayBuffer* buffer)
{
    hash.addFlag(!!buffer);
    if (buffer)
        hash.add(buffer->span());
}

static void hashAttestation(Hash& hash, const RefPtr<AuthenticatorAttestationResponse>& response)
{
    hash.addFlag(!!response);
    if (!response)
        return;
    hash.add(response->rawId().span());
    hash.add(response->attestationObject().span());
    hash.add(static_cast<uint64_t>(response->getTransports().size()));
}

static void hashAssertion(Hash& hash, const RefPtr<AuthenticatorAssertionResponse>& response)
{
    hash.addFlag(!!response);
    if (!response)
        return;
    hash.add(response->rawId().span());
    hashBuffer(hash, response->authenticatorData());
    hashBuffer(hash, response->signature());
    hashBuffer(hash, response->userHandle());
    hash.add(response->name());
    hash.add(static_cast<uint64_t>(response->numberOfCredentials()));
}

// Every prefix of the input, then seeded single-byte changes: the error paths of a parser.
template<typename Parse>
static void forEachCorruption(Bytes input, uint64_t seed, unsigned flips, Parse&& parse)
{
    for (size_t length = 0; length <= input.size(); ++length)
        parse(toVector(input.first(length)));
    Random random(seed);
    for (unsigned i = 0; i < flips; ++i) {
        auto copy = toVector(input);
        copy[random.below(copy.size())] ^= static_cast<uint8_t>(1 + random.below(255));
        parse(WTF::move(copy));
    }
}

// ---- CBOR reader ----

static uint64_t cborReadGetInfoPass()
{
    Hash hash;
    for (Bytes response : { Bytes { TestData::kTestAuthenticatorGetInfoResponse }, Bytes { TestData::kTestGetInfoResponsePlatformDevice }, Bytes { TestData::kTestGetInfoResponsePlatformDevice2 }, Bytes { TestData::kTestGetInfoResponseDeviceYubikey5c } })
        readAndHash(hash, response.subspan(1));
    return hash.value();
}

static size_t cborReadGetInfoBytes()
{
    return sizeof(TestData::kTestAuthenticatorGetInfoResponse) + sizeof(TestData::kTestGetInfoResponsePlatformDevice) + sizeof(TestData::kTestGetInfoResponsePlatformDevice2) + sizeof(TestData::kTestGetInfoResponseDeviceYubikey5c) - 4;
}

// An empty test, to measure the cost of starting the test process.
TEST(WebAuthnBench, StartUp)
{
}

TEST(WebAuthnBench, CBORReadGetInfo)
{
    run("CBORReadGetInfo"_s, cborReadGetInfoBytes(), 0x0c8318eda506c9cbULL, 193000u, cborReadGetInfoPass);
}

TEST(WebAuthnBench, CBORReadAttestation)
{
    // The attestation objects of the recorded makeCredential responses (packed attestation with a certificate, and
    // with the hmac-secret extension), and the get-assertion responses, whose authenticator data and signatures are the
    // byte strings the web process later parses.
    Bytes responses[] = {
        Bytes { TestData::kTestMakeCredentialResponse },
        Bytes { TestData::kTestMakeCredentialResponseWithHmacSecret },
        Bytes { TestData::kDeviceGetAssertionResponse },
        Bytes { TestData::kDeviceGetAssertionResponseLong },
    };
    size_t bytes = 0;
    for (auto response : responses)
        bytes += response.size() - 1;
    run("CBORReadAttestation"_s, bytes, 0xd574507737c0e9e7ULL, 299000u, [&] {
        Hash hash;
        for (auto response : responses)
            readAndHash(hash, response.subspan(1));
        return hash.value();
    });
}

static Vector<Vector<uint8_t>> readerErrorInputs()
{
    Vector<Vector<uint8_t>> inputs;
    auto add = [&](std::initializer_list<uint8_t> bytes) {
        Vector<uint8_t> vector;
        for (uint8_t byte : bytes)
            vector.append(byte);
        inputs.append(WTF::move(vector));
    };
    add({ });
    add({ 0xC0, 0x00 }); // tag: unsupported major type
    add({ 0xE0 }); // simple value 0
    add({ 0x1C }); // unknown additional info
    add({ 0x1F });
    add({ 0x18 }); // incomplete arguments
    add({ 0x19, 0x01 });
    add({ 0x1A, 0x01, 0x02, 0x03 });
    add({ 0x1B, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 });
    add({ 0x18, 0x00 }); // non-minimal arguments
    add({ 0x18, 0x17 });
    add({ 0x19, 0x00, 0xFF });
    add({ 0x1A, 0x00, 0x00, 0xFF, 0xFF });
    add({ 0x1B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF });
    add({ 0x1B, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }); // out of range
    add({ 0x3B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    add({ 0x3B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }); // the smallest negative
    add({ 0x1B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }); // the largest
    add({ 0x38, 0x00 });
    add({ 0x42, 0x01 }); // short byte string
    add({ 0x5B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    add({ 0x78, 0x20, 0x61 }); // short string
    add({ 0x7B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF });
    add({ 0x62, 0xC3, 0x28 }); // invalid UTF-8 sequences
    add({ 0x62, 0xC0, 0x80 });
    add({ 0x63, 0xED, 0xA0, 0x80 });
    add({ 0x64, 0xF4, 0x90, 0x80, 0x80 });
    add({ 0x61, 0x80 });
    add({ 0x64, 0xF0, 0x9F, 0x94, 0x91 }); // valid four-byte sequence
    add({ 0x00, 0x00 }); // extraneous data
    add({ 0x82, 0x01, 0x02, 0x03 });
    add({ 0x9A, 0x00, 0x01, 0x00, 0x00 }); // array longer than the data
    add({ 0xBA, 0x00, 0x01, 0x00, 0x00 });
    add({ 0xA2, 0x01, 0x01, 0x01, 0x02 }); // duplicate key
    add({ 0xA2, 0x61, 0x61, 0x01, 0x61, 0x61, 0x02 });
    add({ 0xA2, 0x02, 0x01, 0x01, 0x02 }); // out of order
    add({ 0xA2, 0x61, 0x61, 0x01, 0x01, 0x02 }); // string before integer
    add({ 0xA2, 0x01, 0x01, 0x61, 0x61, 0x02 }); // integer then string: in order
    add({ 0xA2, 0x61, 0x62, 0x01, 0x61, 0x61, 0x02 }); // strings out of order
    add({ 0xA2, 0x61, 0x62, 0x01, 0x62, 0x61, 0x61, 0x02 }); // length order
    add({ 0xA2, 0x20, 0x01, 0x00, 0x02 }); // negative key before unsigned
    add({ 0xA2, 0x00, 0x01, 0x20, 0x02 });
    add({ 0xA1, 0x80, 0x01 }); // array key
    add({ 0xA1, 0x41, 0x00, 0x01 }); // byte string key
    add({ 0xA1, 0xF5, 0x01 }); // simple value key
    add({ 0xA1, 0x01 }); // missing value
    add({ 0xF4 }); // simple values
    add({ 0xF5 });
    add({ 0xF6 });
    add({ 0xF7 });
    add({ 0xF0 });
    add({ 0xF8, 0x18 });
    add({ 0xF8, 0xFF });
    add({ 0xF9, 0x00, 0x00 }); // floating point
    add({ 0xFA, 0x00, 0x00, 0x00, 0x00 });
    add({ 0xFB, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
    add({ 0xFF }); // break
    // Deeply nested arrays and maps, either side of the depth limit.
    for (unsigned depth : { 1u, 15u, 16u, 17u, 18u, 40u })
        inputs.append(nestedArrayBytes(depth));
    for (unsigned depth : { 15u, 16u, 17u, 18u }) {
        Vector<uint8_t> map;
        for (unsigned i = 0; i < depth; ++i) {
            map.append(0xA1);
            map.append(0x01);
        }
        map.append(0x00);
        inputs.append(WTF::move(map));
    }
    return inputs;
}

TEST(WebAuthnBench, CBORReadErrors)
{
    auto inputs = readerErrorInputs();
    size_t bytes = 0;
    for (auto& input : inputs)
        bytes += input.size();
    run("CBORReadErrors"_s, bytes, 0xb483e44614e017c0ULL, 162000u, [&] {
        Hash hash;
        for (auto& input : inputs) {
            readAndHash(hash, input.span());
            readAndHash(hash, input.span(), 1);
            readAndHash(hash, input.span(), 0);
        }
        return hash.value();
    });
}

TEST(WebAuthnBench, CBORReadSmallExhaustive)
{
    // Every one-byte input and every two-byte input.
    run("CBORReadSmallExhaustive"_s, 256 + 2 * 65536, 0x21d2e8592dc71925ULL, 1210u, [] {
        Hash hash;
        for (unsigned first = 0; first < 256; ++first) {
            uint8_t one[] = { static_cast<uint8_t>(first) };
            readAndHash(hash, Bytes { one });
            for (unsigned second = 0; second < 256; ++second) {
                uint8_t two[] = { static_cast<uint8_t>(first), static_cast<uint8_t>(second) };
                readAndHash(hash, Bytes { two });
            }
        }
        return hash.value();
    });
}

static void readWithBytesConsumedAndHash(Hash& hash, Bytes bytes)
{
    auto error = cbor::CBORReader::DecoderError::CBORNoError;
    auto result = cbor::CBORReader::readWithBytesConsumed(bytes, &error);
    hash.addFlag(!!result);
    hash.add(static_cast<uint64_t>(error));
    if (result) {
        hashValue(hash, result->first);
        hash.add(static_cast<uint64_t>(result->second));
    }
}

TEST(WebAuthnBench, CBORReadWithBytesConsumed)
{
    // The authenticator-data extensions path: a COSE key followed by an extensions map, and the other prefixes.
    Vector<uint8_t> authDataTail = toVector(Bytes { TestData::kTestECPublicKeyCOSE });
    static constexpr uint8_t extensions[] = { 0xA1, 0x6B, 'h', 'm', 'a', 'c', '-', 's', 'e', 'c', 'r', 'e', 't', 0xF5 };
    authDataTail.append(Bytes { extensions });
    Vector<Vector<uint8_t>> inputs;
    inputs.append(WTF::move(authDataTail));
    inputs.append(toVector(Bytes { TestData::kTestECPublicKeyCOSE }));
    inputs.append(toVector(Bytes { extensions }));
    for (auto& input : readerErrorInputs())
        inputs.append(WTF::move(input));
    auto authData = Bytes { TestData::kCtap2MakeCredentialAuthData };
    if (authData.size() > 55) {
        size_t credentialIdLength = (static_cast<size_t>(authData[53]) << 8) | authData[54];
        if (55 + credentialIdLength <= authData.size())
            inputs.append(toVector(authData.subspan(55 + credentialIdLength)));
    }
    size_t bytes = 0;
    for (auto& input : inputs)
        bytes += input.size();
    run("CBORReadWithBytesConsumed"_s, bytes, 0x226102fd5a387c31ULL, 94400u, [&] {
        Hash hash;
        for (auto& input : inputs) {
            readWithBytesConsumedAndHash(hash, input.span());
            // Trailing bytes after a complete item.
            auto padded = input;
            padded.append(Bytes { extensions });
            readWithBytesConsumedAndHash(hash, padded.span());
        }
        return hash.value();
    });
}

// ---- CBOR writer ----

static void writeAndHash(Hash& hash, const cbor::CBORValue& value, size_t maxNesting = cbor::CBORWriter::kDefaultMaxNestingDepth)
{
    auto bytes = cbor::CBORWriter::write(value, maxNesting);
    hash.addFlag(!!bytes);
    if (bytes)
        hash.add(bytes->span());
}

TEST(WebAuthnBench, CBORWriteMakeCredential)
{
    auto value = makeMakeCredentialValue();
    auto size = cbor::CBORWriter::write(value);
    ASSERT_TRUE(size);
    run("CBORWriteMakeCredential"_s, size->size(), 0x71ff33e4925402deULL, 870000u, [&] {
        Hash hash;
        writeAndHash(hash, value);
        return hash.value();
    });
}

TEST(WebAuthnBench, CBORWriteScalars)
{
    auto value = makeScalarsValue();
    auto size = cbor::CBORWriter::write(value);
    ASSERT_TRUE(size);
    run("CBORWriteScalars"_s, size->size(), 0x0616c42b88ecd7abULL, 5050u, [&] {
        Hash hash;
        writeAndHash(hash, value);
        return hash.value();
    });
}

TEST(WebAuthnBench, CBORWriteDepth)
{
    // Nesting depths either side of the limit, with the default limit and with smaller ones.
    Vector<cbor::CBORValue> values;
    for (unsigned depth : { 0u, 1u, 2u, 15u, 16u, 17u, 18u })
        values.append(makeNestedArray(depth));
    run("CBORWriteDepth"_s, 64, 0xd56d0bddc97ca5f5ULL, 2360000u, [&] {
        Hash hash;
        for (auto& value : values) {
            writeAndHash(hash, value);
            writeAndHash(hash, value, 1);
            writeAndHash(hash, value, 0);
        }
        return hash.value();
    });
}

// ---- CTAP responses ----

TEST(WebAuthnBench, CtapGetInfoResponse)
{
    Bytes responses[] = {
        Bytes { TestData::kTestAuthenticatorGetInfoResponse },
        Bytes { TestData::kTestGetInfoResponsePlatformDevice },
        Bytes { TestData::kTestGetInfoResponsePlatformDevice2 },
        Bytes { TestData::kTestGetInfoResponseDeviceYubikey5c },
    };
    static constexpr uint8_t emptyMap[] = { 0x00, 0xA0 };
    static constexpr uint8_t notAMap[] = { 0x00, 0x01 };
    static constexpr uint8_t errorStatus[] = { 0x01 };
    size_t bytes = 0;
    for (auto response : responses)
        bytes += response.size();
    run("CtapGetInfoResponse"_s, bytes, 0x88ab29fdfa86f3c7ULL, 180000u, [&] {
        Hash hash;
        auto parse = [&](const Vector<uint8_t>& data) {
            auto info = fido::readCTAPGetInfoResponse(data);
            hash.addFlag(!!info);
            if (!info)
                return;
            hash.add(static_cast<uint64_t>(info->versions().size()));
            hash.add(info->aaguid().span());
            hash.addFlag(!!info->maxMsgSize());
            hash.add(static_cast<uint64_t>(info->maxMsgSize().value_or(0)));
            hash.add(fido::encodeAsCBOR(std::move(*info)).span());
        };
        for (auto response : responses)
            parse(toVector(response));
        parse(toVector(Bytes { emptyMap }));
        parse(toVector(Bytes { notAMap }));
        parse(toVector(Bytes { errorStatus }));
        parse({ });
        for (auto version : { fido::ProtocolVersion::kCtap2, fido::ProtocolVersion::kCtap21, fido::ProtocolVersion::kCtap21Pre, fido::ProtocolVersion::kU2f }) {
            hash.addFlag(fido::isCtap2Protocol(version));
            hash.add(fido::toString(version));
        }
        return hash.value();
    });
}

TEST(WebAuthnBench, CtapMakeCredentialResponse)
{
    Bytes responses[] = {
        Bytes { TestData::kTestMakeCredentialResponse },
        Bytes { TestData::kTestMakeCredentialResponseWithHmacSecret },
    };
    size_t bytes = 0;
    for (auto response : responses)
        bytes += response.size();
    run("CtapMakeCredentialResponse"_s, bytes, 0x80ee1f0c3f8049c9ULL, 142000u, [&] {
        Hash hash;
        for (auto response : responses) {
            for (auto preference : { AttestationConveyancePreference::None, AttestationConveyancePreference::Direct }) {
                for (auto attachment : { AuthenticatorAttachment::CrossPlatform, AuthenticatorAttachment::Platform })
                    hashAttestation(hash, fido::readCTAPMakeCredentialResponse(toVector(response), attachment, { }, preference));
            }
        }
        return hash.value();
    });
}

TEST(WebAuthnBench, CtapGetAssertionResponse)
{
    Bytes responses[] = {
        Bytes { TestData::kDeviceGetAssertionResponseShort },
        Bytes { TestData::kDeviceGetAssertionResponse },
        Bytes { TestData::kDeviceGetAssertionResponseLong },
        Bytes { TestData::kTestGetAssertionResponseWithHmacSecret },
        Bytes { TestData::kTestGetAssertionResponseWithHmacSecret64 },
    };
    size_t bytes = 0;
    for (auto response : responses)
        bytes += response.size();
    run("CtapGetAssertionResponse"_s, bytes, 0x0da89509b95c6095ULL, 166000u, [&] {
        Hash hash;
        for (auto response : responses) {
            hashAssertion(hash, fido::readCTAPGetAssertionResponse(toVector(response), AuthenticatorAttachment::CrossPlatform));
            hashAssertion(hash, fido::readCTAPGetAssertionResponse(toVector(response), AuthenticatorAttachment::Platform));
        }
        return hash.value();
    });
}

TEST(WebAuthnBench, CtapResponseCodes)
{
    run("CtapResponseCodes"_s, 257, 0xe941b8e5e13f66f0ULL, 277000u, [] {
        Hash hash;
        hash.add(static_cast<uint64_t>(fido::getResponseCode({ })));
        for (unsigned code = 0; code < 256; ++code) {
            Vector<uint8_t> response;
            response.append(static_cast<uint8_t>(code));
            hash.add(static_cast<uint64_t>(fido::getResponseCode(response)));
        }
        return hash.value();
    });
}

TEST(WebAuthnBench, CtapResponseCorruption)
{
    // Every prefix and 256 seeded byte changes of one response of each kind: the parsers' error paths.
    Bytes getInfo { TestData::kTestGetInfoResponsePlatformDevice };
    Bytes makeCredential { TestData::kTestMakeCredentialResponse };
    Bytes getAssertion { TestData::kDeviceGetAssertionResponse };
    run("CtapResponseCorruption"_s, getInfo.size() + makeCredential.size() + getAssertion.size(), 0xcbb93973ffee7c47ULL, 1320u, [&] {
        Hash hash;
        forEachCorruption(getInfo, 11, 256, [&](Vector<uint8_t>&& data) {
            auto info = fido::readCTAPGetInfoResponse(data);
            hash.addFlag(!!info);
            if (info)
                hash.add(fido::encodeAsCBOR(std::move(*info)).span());
        });
        forEachCorruption(makeCredential, 12, 256, [&](Vector<uint8_t>&& data) {
            hashAttestation(hash, fido::readCTAPMakeCredentialResponse(data, AuthenticatorAttachment::CrossPlatform, { }));
        });
        forEachCorruption(getAssertion, 13, 256, [&](Vector<uint8_t>&& data) {
            hashAssertion(hash, fido::readCTAPGetAssertionResponse(data, AuthenticatorAttachment::CrossPlatform));
        });
        return hash.value();
    });
}

// ---- U2F ----

static Vector<uint8_t> u2fRegisterResponse(size_t prefixSize, Bytes appendix)
{
    auto response = Bytes { TestData::kTestU2fRegisterResponse };
    Vector<uint8_t> result;
    result.append(response.first(prefixSize));
    result.append(appendix);
    return result;
}

TEST(WebAuthnBench, U2fRegisterResponse)
{
    constexpr size_t signatureSize = 71;
    constexpr size_t responseSize = sizeof(TestData::kTestU2fRegisterResponse);
    run("U2fRegisterResponse"_s, responseSize * 4, 0x630296fd4afddd96ULL, 1100u, [&] {
        Hash hash;
        auto parse = [&](const Vector<uint8_t>& data) {
            for (auto preference : { AttestationConveyancePreference::Direct, AttestationConveyancePreference::None })
                hashAttestation(hash, fido::readU2fRegisterResponse(TestData::kRelyingPartyId, data, AuthenticatorAttachment::CrossPlatform, { }, preference));
        };
        parse(toVector(Bytes { TestData::kTestU2fRegisterResponse }));
        // Every prefix: a truncated public key, key handle, certificate and signature.
        for (size_t length = 0; length <= responseSize; ++length)
            parse(u2fRegisterResponse(length, { }));
        // A key handle of every length byte.
        for (unsigned handleLength = 0; handleLength < 256; handleLength += 5) {
            auto data = toVector(Bytes { TestData::kTestU2fRegisterResponse });
            data[fido::kU2fKeyHandleLengthOffset] = static_cast<uint8_t>(handleLength);
            parse(data);
        }
        // Certificates that are not DER, and the shortest that are.
        const size_t prefix = fido::kU2fKeyHandleOffset + 64;
        const size_t suffix = responseSize - signatureSize;
        static constexpr uint8_t badCertificates[][4] = {
            { 0x40, 0, 0, 0 }, { 0x30, 0, 0, 0 }, { 0x30, 0x82, 0, 0 }, { 0x30, 0xC1, 0, 0 }, { 0x30, 0x82, 0x02, 0x4A }, { 0x30, 0x84, 0xFF, 0xFF },
        };
        for (auto& certificate : badCertificates)
            parse(u2fRegisterResponse(prefix, Bytes { certificate }));
        for (auto certificate : { Bytes { std::array<uint8_t, 3> { 0x30, 0x01, 0x00 } }, Bytes { std::array<uint8_t, 4> { 0x30, 0x81, 0x01, 0x00 } } }) {
            auto data = u2fRegisterResponse(prefix, certificate);
            data.append(Bytes { TestData::kTestU2fRegisterResponse }.subspan(suffix, signatureSize));
            parse(data);
        }
        return hash.value();
    });
}

TEST(WebAuthnBench, U2fSignResponse)
{
    Bytes response { TestData::kTestU2fSignResponse };
    run("U2fSignResponse"_s, response.size() * 3, 0xa9033f5f7f5c0f0aULL, 25700u, [&] {
        Hash hash;
        auto keyHandle = WebCore::toBufferSource(TestData::kU2fSignKeyHandle);
        for (size_t length = 0; length < response.size(); ++length)
            hashAssertion(hash, fido::readU2fSignResponse(TestData::kRelyingPartyId, keyHandle, toVector(response.first(length)), AuthenticatorAttachment::CrossPlatform));
        hashAssertion(hash, fido::readU2fSignResponse(TestData::kRelyingPartyId, keyHandle, toVector(response), AuthenticatorAttachment::CrossPlatform));
        hashAssertion(hash, fido::readU2fSignResponse(TestData::kRelyingPartyId, keyHandle, toVector(response), AuthenticatorAttachment::Platform));
        // An empty key handle.
        hashAssertion(hash, fido::readU2fSignResponse(TestData::kRelyingPartyId, BufferSource { JSC::ArrayBuffer::create(static_cast<size_t>(0U), 1) }, toVector(response), AuthenticatorAttachment::CrossPlatform));
        return hash.value();
    });
}

// ---- APDU ----

static void apduCommandAndHash(Hash& hash, Vector<uint8_t>&& message)
{
    auto command = apdu::ApduCommand::createFromMessage(message);
    hash.addFlag(!!command);
    if (!command)
        return;
    hash.add(static_cast<uint64_t>(command->cla()));
    hash.add(static_cast<uint64_t>(command->ins()));
    hash.add(static_cast<uint64_t>(command->p1()));
    hash.add(static_cast<uint64_t>(command->p2()));
    hash.add(static_cast<uint64_t>(command->responseLength()));
    hash.add(command->data().span());
    hash.add(command->getEncodedCommand().span());
}

TEST(WebAuthnBench, ApduCommand)
{
    Vector<Vector<uint8_t>> messages;
    messages.append(toVector(Bytes { TestData::kU2fRegisterCommandApdu }));
    messages.append(toVector(Bytes { TestData::kU2fRegisterCommandApduWithGoogleLegacyAppidSupport }));
    messages.append(toVector(Bytes { TestData::kU2fSignCommandApdu }));
    messages.append(toVector(Bytes { TestData::kU2fAppIDSignCommandApdu }));
    messages.append(toVector(Bytes { TestData::kU2fCheckOnlySignCommandApdu }));
    messages.append(toVector(Bytes { TestData::kU2fFakeRegisterCommand }));
    size_t bytes = 0;
    for (auto& message : messages)
        bytes += message.size();
    run("ApduCommand"_s, bytes + 2 * apdu::ApduCommand::kApduMaxLength, 0xb8355e0094a17fc8ULL, 662u, [&] {
        Hash hash;
        for (auto& message : messages) {
            for (size_t length = 0; length <= message.size(); ++length)
                apduCommandAndHash(hash, toVector(message.span().first(length)));
        }
        // Headers of every size, with and without data and a response length.
        for (size_t header = 0; header < 12; ++header)
            apduCommandAndHash(hash, patternBytes(header, 40 + header));
        for (unsigned dataLength : { 0u, 1u, 255u, 256u, 65534u, 65535u }) {
            for (unsigned responseBytes : { 0u, 1u, 2u, 3u }) {
                Vector<uint8_t> message { 0x00, 0xA4, 0x04, 0x00 };
                // Extended length: a zero byte, then the length of the data, the data, the response length.
                if (dataLength) {
                    message.append(0);
                    message.append(static_cast<uint8_t>(dataLength >> 8));
                    message.append(static_cast<uint8_t>(dataLength));
                    message.appendVector(patternBytes(dataLength, dataLength));
                }
                for (unsigned i = 0; i < responseBytes; ++i)
                    message.append(static_cast<uint8_t>(i * 0x55));
                apduCommandAndHash(hash, WTF::move(message));
            }
        }
        // The maximum encoded message, and one byte more.
        Vector<uint8_t> maximum { 0x00, 0xC2, 0x00, 0x00, 0x00, 0xFF, 0xFF };
        maximum.appendVector(patternBytes(apdu::ApduCommand::kApduMaxDataLength, 77));
        maximum.append(0);
        maximum.append(0);
        apduCommandAndHash(hash, Vector<uint8_t>(maximum));
        maximum.append(0);
        apduCommandAndHash(hash, WTF::move(maximum));
        // Commands built from fields, then encoded.
        for (size_t dataLength : { size_t(0), size_t(1), size_t(255), size_t(256), size_t(65535) }) {
            for (size_t responseLength : { size_t(0), size_t(1), size_t(255), size_t(256), size_t(65535), size_t(65536) }) {
                apdu::ApduCommand command;
                command.setCla(0x80);
                command.setIns(0x02);
                command.setP1(0x03);
                command.setP2(0x04);
                command.setData(patternBytes(dataLength, dataLength + responseLength));
                command.setResponseLength(responseLength);
                hash.add(command.getEncodedCommand().span());
            }
        }
        return hash.value();
    });
}

TEST(WebAuthnBench, ApduResponse)
{
    run("ApduResponse"_s, 4096, 0xf980e7af66cb5675ULL, 3540u, [] {
        Hash hash;
        for (size_t length : { size_t(0), size_t(1), size_t(2), size_t(3), size_t(64), size_t(257), size_t(65538), size_t(65539) }) {
            auto response = apdu::ApduResponse::createFromMessage(patternBytes(length, length));
            hash.addFlag(!!response);
            if (!response)
                continue;
            hash.add(static_cast<uint64_t>(response->status()));
            hash.add(response->data().span());
            hash.add(response->getEncodedResponse().span());
        }
        for (auto status : { apdu::ApduResponse::Status::SW_NO_ERROR, apdu::ApduResponse::Status::SW_CONDITIONS_NOT_SATISFIED, apdu::ApduResponse::Status::SW_WRONG_DATA, apdu::ApduResponse::Status::SW_WRONG_LENGTH, apdu::ApduResponse::Status::SW_INS_NOT_SUPPORTED }) {
            for (size_t length : { size_t(0), size_t(1), size_t(100) }) {
                apdu::ApduResponse response(patternBytes(length, length), status);
                hash.add(response.getEncodedResponse().span());
                auto parsed = apdu::ApduResponse::createFromMessage(response.getEncodedResponse());
                hash.addFlag(!!parsed);
                if (parsed)
                    hash.add(static_cast<uint64_t>(parsed->status()));
            }
        }
        return hash.value();
    });
}

// ---- Request encoders ----

static PublicKeyCredentialRpEntity testRp()
{
    return PublicKeyCredentialRpEntity {
        PublicKeyCredentialEntity { "Acme"_s, { } },
        "acme.com"_s
    };
}

static PublicKeyCredentialUserEntity testUser()
{
    return PublicKeyCredentialUserEntity {
        PublicKeyCredentialEntity { "johnpsmith@example.com"_s, "https://pics.acme.com/00/p/aBjjjpqPb.png"_s },
        WebCore::toBufferSource(TestData::kUserId),
        "John P. Smith"_s
    };
}

static BufferSource testChallenge()
{
    return BufferSource { JSC::ArrayBuffer::create(static_cast<size_t>(0U), 1) };
}

static PublicKeyCredentialDescriptor testDescriptor(Bytes id)
{
    return PublicKeyCredentialDescriptor {
        .type = PublicKeyCredentialType::PublicKey,
        .id = WebCore::toBufferSource(id),
        .transports = { },
    };
}

static PublicKeyCredentialCreationOptions creationOptions(const Vector<PublicKeyCredentialParameters>& parameters, const AuthenticatorSelectionCriteria& selection, const std::optional<AuthenticationExtensionsClientInputs>& extensions = std::nullopt)
{
    return PublicKeyCredentialCreationOptions { testRp(), testUser(), testChallenge(), parameters, std::nullopt, { }, selection, AttestationConveyancePreference::None, extensions };
}

static PublicKeyCredentialRequestOptions requestOptions(UserVerificationRequirement requirement)
{
    return PublicKeyCredentialRequestOptions {
        .challenge = testChallenge(),
        .timeout = { },
        .rpId = "acme.com"_s,
        .allowCredentials = { },
        .userVerification = requirement,
        .extensions = { },
        .authenticatorAttachment = { },
    };
}

TEST(WebAuthnBench, CtapRequests)
{
    Vector<uint8_t> clientDataHash = toVector(Bytes { TestData::kClientDataHash });
    Vector<PublicKeyCredentialParameters> parameters { { PublicKeyCredentialType::PublicKey, 7 }, { PublicKeyCredentialType::PublicKey, 257 } };
    Vector<PublicKeyCredentialParameters> trimmed { { PublicKeyCredentialType::PublicKey, -7 } };
    Vector<String> noExtensions;
    Vector<String> largeBlobExtension { "largeBlob"_s };
    Vector<String> allExtensions { "largeBlob"_s, "hmac-secret"_s, "credProps"_s };
    Vector<uint8_t> pinAuth = toVector(Bytes { TestData::kCtap2PinAuth });
    Vector<uint8_t> credentialId = patternBytes(64, 99);
    Vector<uint8_t> otherCredentialId = patternBytes(32, 98);

    AuthenticationExtensionsClientInputs largeBlobInputs = {
        .appid = WTF::nullString(),
        .credProps = false,
        .largeBlob = AuthenticationExtensionsClientInputs::LargeBlobInputs {
            .support = "required"_s,
            .read = std::nullopt,
            .write = std::nullopt,
        },
        .prf = std::nullopt,
    };
    AuthenticationExtensionsClientInputs credPropsInputs = {
        .appid = WTF::nullString(),
        .credProps = true,
        .largeBlob = std::nullopt,
        .prf = std::nullopt,
    };

    const uint8_t salt1Data[32] = { 0x00 };
    const uint8_t salt2Data[32] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    AuthenticationExtensionsClientInputs prfExtensions;
    AuthenticationExtensionsClientInputs::PRFInputs prfInputs;
    prfInputs.eval = AuthenticationExtensionsClientInputs::PRFValues {
        WebCore::toBufferSource(salt1Data),
        WebCore::toBufferSource(salt2Data),
    };
    prfExtensions.prf = WTF::move(prfInputs);

    run("CtapRequests"_s, 4096, 0x15a770e418cb69deULL, 20100u, [&] {
        Hash hash;
        using UVAvailability = fido::AuthenticatorSupportedOptions::UserVerificationAvailability;
        using RKAvailability = fido::AuthenticatorSupportedOptions::ResidentKeyAvailability;
        for (auto availability : { UVAvailability::kSupportedAndConfigured, UVAvailability::kSupportedButNotConfigured, UVAvailability::kNotSupported }) {
            for (auto requirement : { UserVerificationRequirement::Required, UserVerificationRequirement::Preferred, UserVerificationRequirement::Discouraged }) {
                for (auto residentKey : { RKAvailability::kSupported, RKAvailability::kNotSupported }) {
                    for (bool requireResidentKey : { true, false }) {
                        AuthenticatorSelectionCriteria selection { AuthenticatorAttachment::Platform, std::nullopt, requireResidentKey, requirement };
                        auto options = creationOptions(parameters, selection);
                        hash.add(fido::encodeMakeCredentialRequestAsCBORForTesting(clientDataHash, options, availability, requirement, residentKey, noExtensions).span());
                    }
                }
                auto options = requestOptions(requirement);
                options.allowCredentials.append(testDescriptor(credentialId.span()));
                options.allowCredentials.append(testDescriptor(otherCredentialId.span()));
                hash.add(fido::encodeGetAssertionRequestAsCBORForTesting(clientDataHash, options, availability, requirement, noExtensions).span());
                hash.add(fido::encodeGetAssertionRequestAsCBORForTesting(clientDataHash, requestOptions(requirement), availability, requirement, noExtensions).span());
            }
        }

        AuthenticatorSelectionCriteria selection { AuthenticatorAttachment::Platform, std::nullopt, true, UserVerificationRequirement::Preferred };
        fido::PinParameters pin;
        pin.protocol = fido::pin::kProtocolVersion;
        pin.auth.append(pinAuth.span());
        auto withPin = [&] {
            fido::PinParameters copy;
            copy.protocol = pin.protocol;
            copy.auth.append(pin.auth.span());
            return copy;
        };

        auto options = creationOptions(parameters, selection);
        hash.add(fido::encodeMakeCredentialRequestAsCBORForTesting(clientDataHash, options, UVAvailability::kSupportedAndConfigured, UserVerificationRequirement::Preferred, RKAvailability::kSupported, noExtensions, withPin()).span());
        // The trimmed parameters and an exclude list of the authenticator's choosing.
        Vector<PublicKeyCredentialDescriptor> excluded;
        excluded.append(testDescriptor(credentialId.span()));
        hash.add(fido::encodeMakeCredentialRequestAsCBORForTesting(clientDataHash, options, UVAvailability::kSupportedAndConfigured, UserVerificationRequirement::Preferred, RKAvailability::kSupported, noExtensions, std::nullopt, trimmed, WTF::move(excluded)).span());
        // Extensions.
        auto largeBlobOptions = creationOptions(parameters, selection, largeBlobInputs);
        hash.add(fido::encodeMakeCredentialRequestAsCBORForTesting(clientDataHash, largeBlobOptions, UVAvailability::kSupportedAndConfigured, UserVerificationRequirement::Preferred, RKAvailability::kSupported, largeBlobExtension).span());
        hash.add(fido::encodeMakeCredentialRequestAsCBORForTesting(clientDataHash, largeBlobOptions, UVAvailability::kSupportedAndConfigured, UserVerificationRequirement::Preferred, RKAvailability::kSupported, noExtensions).span());
        auto credPropsOptions = creationOptions(parameters, selection, credPropsInputs);
        hash.add(fido::encodeMakeCredentialRequestAsCBORForTesting(clientDataHash, credPropsOptions, UVAvailability::kSupportedAndConfigured, UserVerificationRequirement::Preferred, RKAvailability::kSupported, allExtensions).span());
        // Excluded credentials in the options.
        auto excludeOptions = creationOptions(parameters, selection);
        excludeOptions.excludeCredentials.append(testDescriptor(credentialId.span()));
        excludeOptions.excludeCredentials.append(testDescriptor(otherCredentialId.span()));
        hash.add(fido::encodeMakeCredentialRequestAsCBORForTesting(clientDataHash, excludeOptions, UVAvailability::kSupportedAndConfigured, UserVerificationRequirement::Preferred, RKAvailability::kSupported, noExtensions).span());

        auto assertion = requestOptions(UserVerificationRequirement::Preferred);
        assertion.allowCredentials.append(testDescriptor(credentialId.span()));
        hash.add(fido::encodeGetAssertionRequestAsCBORForTesting(clientDataHash, assertion, UVAvailability::kSupportedAndConfigured, UserVerificationRequirement::Preferred, noExtensions, withPin()).span());
        auto prfAssertion = requestOptions(UserVerificationRequirement::Preferred);
        prfAssertion.extensions = prfExtensions;
        hash.add(fido::encodeGetAssertionRequestAsCBORForTesting(clientDataHash, prfAssertion, UVAvailability::kSupportedButNotConfigured, UserVerificationRequirement::Preferred, Vector<String> { "hmac-secret"_s }).span());

        Vector<PublicKeyCredentialDescriptor> credentials;
        credentials.append(testDescriptor(credentialId.span()));
        credentials.append(testDescriptor(otherCredentialId.span()));
        hash.add(fido::encodeSilentGetAssertion("acme.com"_s, clientDataHash, credentials).span());
        hash.add(fido::encodeSilentGetAssertion("acme.com"_s, clientDataHash, credentials, withPin()).span());
        hash.add(fido::encodeBogusRequestForAuthenticatorSelection().span());
        for (auto command : { fido::CtapRequestCommand::kAuthenticatorGetInfo, fido::CtapRequestCommand::kAuthenticatorGetNextAssertion, fido::CtapRequestCommand::kAuthenticatorReset })
            hash.add(fido::encodeEmptyAuthenticatorRequest(command).span());
        return hash.value();
    });
}

static PublicKeyCredentialCreationOptions u2fCreationOptions(const Vector<PublicKeyCredentialParameters>& parameters, const std::optional<AuthenticatorSelectionCriteria>& selection)
{
    return PublicKeyCredentialCreationOptions {
        .rp = PublicKeyCredentialRpEntity {
            PublicKeyCredentialEntity { "acme.com"_s, { } },
            "acme.com"_s
        },
        .user = testUser(),
        .challenge = JSC::ArrayBuffer::create(static_cast<size_t>(0U), 1),
        .pubKeyCredParams = parameters,
        .timeout = { },
        .excludeCredentials = { },
        .authenticatorSelection = selection,
        .attestation = AttestationConveyancePreference::None,
        .extensions = { },
    };
}

TEST(WebAuthnBench, U2fCommands)
{
    Vector<uint8_t> clientDataHash = toVector(Bytes { TestData::kClientDataHash });
    run("U2fCommands"_s, 1024, 0xe800b9d0e85ccf95ULL, 128000u, [&] {
        Hash hash;
        Vector<PublicKeyCredentialParameters> es256 { PublicKeyCredentialParameters { PublicKeyCredentialType::PublicKey, COSE::ES256 } };
        Vector<PublicKeyCredentialParameters> rs256 { PublicKeyCredentialParameters { PublicKeyCredentialType::PublicKey, -257 } };
        Vector<PublicKeyCredentialParameters> both { PublicKeyCredentialParameters { PublicKeyCredentialType::PublicKey, -257 }, PublicKeyCredentialParameters { PublicKeyCredentialType::PublicKey, COSE::ES256 } };
        std::optional<AuthenticatorSelectionCriteria> residentKey = AuthenticatorSelectionCriteria { std::nullopt, std::nullopt, true, UserVerificationRequirement::Preferred };
        std::optional<AuthenticatorSelectionCriteria> required = AuthenticatorSelectionCriteria { std::nullopt, std::nullopt, false, UserVerificationRequirement::Required };
        std::optional<AuthenticatorSelectionCriteria> discouraged = AuthenticatorSelectionCriteria { std::nullopt, std::nullopt, false, UserVerificationRequirement::Discouraged };
        for (auto& parameters : { es256, rs256, both, Vector<PublicKeyCredentialParameters> { } }) {
            for (auto& selection : { std::optional<AuthenticatorSelectionCriteria> { }, residentKey, required, discouraged }) {
                auto options = u2fCreationOptions(parameters, selection);
                bool convertible = fido::isConvertibleToU2fRegisterCommand(options);
                hash.addFlag(convertible);
                auto command = fido::convertToU2fRegisterCommand(clientDataHash, options);
                hash.addFlag(!!command);
                if (command)
                    hash.add(command->span());
            }
        }
        auto options = u2fCreationOptions(es256, std::nullopt);
        for (auto type : { PublicKeyCredentialType::PublicKey, static_cast<PublicKeyCredentialType>(-1) }) {
            PublicKeyCredentialDescriptor descriptor {
                .type = type,
                .id = WebCore::toBufferSource(TestData::kU2fSignKeyHandle),
                .transports = { },
            };
            auto command = fido::convertToU2fCheckOnlySignCommand(clientDataHash, options, descriptor);
            hash.addFlag(!!command);
            if (command)
                hash.add(command->span());
        }
        for (auto requirement : { UserVerificationRequirement::Required, UserVerificationRequirement::Preferred, UserVerificationRequirement::Discouraged }) {
            auto request = requestOptions(requirement);
            hash.addFlag(fido::isConvertibleToU2fSignCommand(request));
            request.allowCredentials.append(testDescriptor(Bytes { TestData::kU2fSignKeyHandle }));
            hash.addFlag(fido::isConvertibleToU2fSignCommand(request));
            // The appid path reads the extension, so it must be present.
            AuthenticationExtensionsClientInputs appIdInputs;
            appIdInputs.appid = "https://acme.com/appid.json"_s;
            request.extensions = WTF::move(appIdInputs);
            for (bool isAppId : { false, true }) {
                auto command = fido::convertToU2fSignCommand(clientDataHash, request, WebCore::toBufferSource(TestData::kU2fSignKeyHandle), isAppId);
                hash.addFlag(!!command);
                if (command)
                    hash.add(command->span());
            }
            // A key handle too long for the one-byte length.
            Vector<uint8_t> longHandle = patternBytes(300, 5);
            auto command = fido::convertToU2fSignCommand(clientDataHash, request, WebCore::toBufferSource(longHandle.span()), false);
            hash.addFlag(!!command);
            if (command)
                hash.add(command->span());
        }
        hash.add(fido::constructBogusU2fRegistrationCommand().span());
        return hash.value();
    });
}

// ---- HID framing ----

static constexpr fido::FidoHidDeviceCommand allHidCommands[] = {
    fido::FidoHidDeviceCommand::kMsg, fido::FidoHidDeviceCommand::kCbor, fido::FidoHidDeviceCommand::kInit, fido::FidoHidDeviceCommand::kPing,
    fido::FidoHidDeviceCommand::kCancel, fido::FidoHidDeviceCommand::kError, fido::FidoHidDeviceCommand::kKeepAlive, fido::FidoHidDeviceCommand::kWink,
    fido::FidoHidDeviceCommand::kLock,
};

static void hashMessage(Hash& hash, std::optional<fido::FidoHidMessage>& message)
{
    hash.addFlag(!!message);
    if (!message)
        return;
    hash.add(static_cast<uint64_t>(message->channelId()));
    hash.add(static_cast<uint64_t>(message->cmd()));
    hash.add(static_cast<uint64_t>(message->numPackets()));
    hash.addFlag(message->messageComplete());
    hash.add(message->getMessagePayload().span());
}

// Splits into packets, then puts the packets back together as the driver does with what it reads from the device.
static void frameAndReassemble(Hash& hash, uint32_t channelId, fido::FidoHidDeviceCommand command, const Vector<uint8_t>& payload)
{
    auto message = fido::FidoHidMessage::create(channelId, command, payload);
    hash.addFlag(!!message);
    if (!message)
        return;
    hash.add(static_cast<uint64_t>(message->numPackets()));
    Vector<Vector<uint8_t>> packets;
    while (message->numPackets())
        packets.append(message->popNextPacket());
    for (auto& packet : packets)
        hash.add(packet.span());
    auto reassembled = fido::FidoHidMessage::createFromSerializedData(packets[0]);
    hash.addFlag(!!reassembled);
    if (!reassembled)
        return;
    for (size_t i = 1; i < packets.size(); ++i)
        hash.addFlag(reassembled->addContinuationPacket(packets[i]));
    hashMessage(hash, reassembled);
}

TEST(WebAuthnBench, HidFrameAndReassemble)
{
    // The largest message a device accepts: 57 bytes in the first packet and 59 in each of 128 more.
    auto payload = patternBytes(fido::kHidMaxMessageSize, 7);
    ASSERT_EQ(payload.size(), 7609u);
    run("HidFrameAndReassemble"_s, payload.size(), 0x6a5ab94f5b687263ULL, 54300u, [&] {
        Hash hash;
        frameAndReassemble(hash, 0x01020304, fido::FidoHidDeviceCommand::kCbor, payload);
        return hash.value();
    });
}

TEST(WebAuthnBench, HidMessageSizes)
{
    run("HidMessageSizes"_s, 9 * 8 * 1024, 0xfeff309850077a70ULL, 5050u, [] {
        Hash hash;
        for (size_t size : { size_t(0), size_t(1), size_t(2), size_t(56), size_t(57), size_t(58), size_t(59), size_t(115), size_t(116), size_t(117), size_t(1000), size_t(7608), size_t(7609), size_t(7610), size_t(65535) }) {
            auto payload = patternBytes(size, size);
            for (auto command : allHidCommands)
                frameAndReassemble(hash, 0xF5060708, command, payload);
        }
        // A one-byte lock message, as the lock command requires, and with seconds out of range.
        for (uint8_t seconds : { 0, 1, 10, 11, 255 }) {
            Vector<uint8_t> payload { seconds };
            frameAndReassemble(hash, 1, fido::FidoHidDeviceCommand::kLock, payload);
        }
        return hash.value();
    });
}

static Vector<uint8_t> hidInitPacket(uint32_t channelId, uint8_t command, unsigned payloadLength, size_t packetSize = fido::kHidMaxPacketSize)
{
    Vector<uint8_t> packet;
    packet.append(static_cast<uint8_t>(channelId >> 24));
    packet.append(static_cast<uint8_t>(channelId >> 16));
    packet.append(static_cast<uint8_t>(channelId >> 8));
    packet.append(static_cast<uint8_t>(channelId));
    packet.append(command);
    packet.append(static_cast<uint8_t>(payloadLength >> 8));
    packet.append(static_cast<uint8_t>(payloadLength));
    while (packet.size() < packetSize)
        packet.append(static_cast<uint8_t>(packet.size()));
    packet.shrink(packetSize);
    return packet;
}

static Vector<uint8_t> hidContinuationPacket(uint32_t channelId, uint8_t sequence, size_t packetSize = fido::kHidMaxPacketSize)
{
    Vector<uint8_t> packet;
    packet.append(static_cast<uint8_t>(channelId >> 24));
    packet.append(static_cast<uint8_t>(channelId >> 16));
    packet.append(static_cast<uint8_t>(channelId >> 8));
    packet.append(static_cast<uint8_t>(channelId));
    packet.append(sequence);
    while (packet.size() < packetSize)
        packet.append(static_cast<uint8_t>(0x80 + packet.size()));
    packet.shrink(packetSize);
    return packet;
}

TEST(WebAuthnBench, HidParseErrors)
{
    run("HidParseErrors"_s, 64 * 64, 0xedd3e4f45f4961a0ULL, 46300u, [] {
        Hash hash;
        constexpr uint32_t channel = 0x01020304;
        constexpr uint8_t cbor = static_cast<uint8_t>(fido::FidoHidDeviceCommand::kCbor) | 0x80;
        // Init packets that are too short, have no init bit, announce more than a message holds, or announce nothing.
        Vector<Vector<uint8_t>> initPackets;
        initPackets.append({ });
        for (size_t size : { size_t(1), size_t(4), size_t(5), size_t(6), size_t(7), size_t(8), size_t(63), size_t(64), size_t(65) })
            initPackets.append(hidInitPacket(channel, cbor, 10, size));
        initPackets.append(hidInitPacket(channel, static_cast<uint8_t>(fido::FidoHidDeviceCommand::kCbor), 10));
        initPackets.append(hidInitPacket(channel, 0x80, 10));
        for (unsigned length : { 0u, 1u, 57u, 58u, 7609u, 7610u, 65535u })
            initPackets.append(hidInitPacket(channel, cbor, length));
        for (auto command : allHidCommands)
            initPackets.append(hidInitPacket(channel, static_cast<uint8_t>(command) | 0x80, 20));
        for (auto& packet : initPackets) {
            auto message = fido::FidoHidMessage::createFromSerializedData(packet);
            hashMessage(hash, message);
            size_t remaining = 0xdead;
            auto init = fido::FidoHidInitPacket::createFromSerializedData(packet, &remaining);
            hash.addFlag(!!init);
            hash.add(static_cast<uint64_t>(remaining));
            if (init) {
                hash.add(static_cast<uint64_t>(init->channelId()));
                hash.add(static_cast<uint64_t>(init->command()));
                hash.add(static_cast<uint64_t>(init->payloadLength()));
                hash.add(init->getPacketPayload().span());
                hash.add(init->getSerializedData().span());
            }
        }
        // Continuation packets: wrong sequence, wrong channel, short, an init packet, and one after the message is complete.
        struct Sequence {
            uint32_t channel;
            uint8_t sequence;
            size_t size;
        };
        Vector<Vector<Sequence>> sequences {
            { { channel, 0, 64 }, { channel, 1, 64 }, { channel, 2, 64 } },
            { { channel, 0, 64 }, { channel, 2, 64 } },
            { { channel, 1, 64 } },
            { { channel, 0, 64 }, { channel, 0, 64 } },
            { { channel + 1, 0, 64 } },
            { { channel, 0, 63 } },
            { { channel, 0, 5 } },
            { { channel, 0, 4 } },
            { { channel, 0x80, 64 } },
            { { channel, 0xFF, 64 } },
            { { channel, 0, 64 }, { channel, 1, 64 }, { channel, 2, 64 }, { channel, 3, 64 } },
            { { channel, 0, 65 } },
        };
        for (auto& sequence : sequences) {
            auto message = fido::FidoHidMessage::createFromSerializedData(hidInitPacket(channel, cbor, 200));
            if (!message)
                continue;
            for (auto& step : sequence) {
                hash.addFlag(message->addContinuationPacket(hidContinuationPacket(step.channel, step.sequence, step.size)));
                hash.addFlag(message->messageComplete());
            }
            hash.add(static_cast<uint64_t>(message->numPackets()));
            hash.add(message->getMessagePayload().span());
        }
        for (uint8_t sequence : { 0, 1, 127, 128 }) {
            for (size_t remainingStart : { size_t(0), size_t(1), size_t(58), size_t(59), size_t(60), size_t(7609) }) {
                size_t remaining = remainingStart;
                auto packet = fido::FidoHidContinuationPacket::createFromSerializedData(hidContinuationPacket(channel, sequence), &remaining);
                hash.addFlag(!!packet);
                hash.add(static_cast<uint64_t>(remaining));
                if (packet) {
                    hash.add(static_cast<uint64_t>(packet->sequence()));
                    hash.add(packet->getPacketPayload().span());
                    hash.add(packet->getSerializedData().span());
                }
            }
        }
        // Packets made from fields: payloads of every length up to a full packet.
        for (size_t length = 0; length <= 64; ++length) {
            fido::FidoHidInitPacket init(channel, fido::FidoHidDeviceCommand::kMsg, patternBytes(std::min<size_t>(length, 57), length), length);
            hash.add(init.getSerializedData().span());
            fido::FidoHidContinuationPacket continuation(channel, static_cast<uint8_t>(length), patternBytes(std::min<size_t>(length, 59), length));
            hash.add(continuation.getSerializedData().span());
        }
        return hash.value();
    });
}

// ---- PIN protocol ----

struct PinKeys {
    RefPtr<CryptoKeyEC> peerKey;
};

static PinKeys makePinKeys()
{
    auto keyPairResult = CryptoKeyEC::generatePair(CryptoAlgorithmIdentifier::ECDH, "P-256"_s, true, CryptoKeyUsageDeriveBits);
    EXPECT_FALSE(keyPairResult.hasException());
    auto keyPair = keyPairResult.releaseReturnValue();
    return { downcast<CryptoKeyEC>(keyPair.publicKey.get()) };
}

TEST(WebAuthnBench, PinProtocol2Token)
{
    // A token response of the second protocol: the device encrypts the token with an IV in front. The request's own
    // ephemeral key gives a shared key to encrypt with; the plaintext, which the checksum observes, does not depend on it.
    auto keys = makePinKeys();
    auto token = patternBytes(32, 5);
    auto request = fido::pin::HmacSecretRequest::create(fido::PINUVAuthProtocol::kPinProtocol2, token, std::nullopt, keys.peerKey.copyRef());
    ASSERT_TRUE(request);
    auto encrypted = request->saltEnc();
    ASSERT_EQ(encrypted.size(), 48u);
    Vector<uint8_t> response { 0x00, 0xA1, 0x02, 0x58, static_cast<uint8_t>(encrypted.size()) };
    response.appendVector(encrypted);
    Vector<uint8_t> clientDataHash = toVector(Bytes { TestData::kClientDataHash });
    run("PinProtocol2Token"_s, response.size(), 0x9eaaf65fd7b18a09ULL, 708000u, [&] {
        Hash hash;
        auto parsed = fido::pin::TokenResponse::parse(fido::PINUVAuthProtocol::kPinProtocol2, request->sharedKey(), response);
        hash.addFlag(!!parsed);
        if (parsed) {
            hash.add(parsed->token().span());
            hash.add(parsed->pinAuth(fido::PINUVAuthProtocol::kPinProtocol2, clientDataHash).span());
            hash.add(parsed->pinAuth(fido::PINUVAuthProtocol::kPinProtocol1, clientDataHash).span());
        }
        return hash.value();
    });
}

TEST(WebAuthnBench, PinParsers)
{
    constexpr std::array<uint8_t, 32> sharedKeyData {
        0x29, 0x9E, 0x65, 0xB8, 0xE7, 0x71, 0xB8, 0x1D, 0xB1, 0xC4, 0x8D, 0xBE, 0xCE, 0x50, 0x2A, 0x84,
        0x05, 0x44, 0x7F, 0x46, 0x2D, 0xE6, 0x81, 0xFA, 0xEF, 0x0A, 0x6C, 0x67, 0xA7, 0x2B, 0xB5, 0x0F,
    };
    auto sharedKey = CryptoKeyAES::importRaw(CryptoAlgorithmIdentifier::AES_CBC, Bytes { sharedKeyData }, true, CryptoKeyUsageEncrypt | CryptoKeyUsageDecrypt);
    ASSERT_TRUE(sharedKey);
    static constexpr uint8_t wrongCode[] = { 0x05 };
    static constexpr uint8_t wrongMap[] = { 0x00, 0x00 };
    Bytes inputs[] = {
        { },
        Bytes { wrongCode },
        Bytes { wrongMap },
        Bytes { TestData::kCtapClientPinRetriesResponse },
        Bytes { TestData::kCtapClientPinTokenResponse },
        Bytes { TestData::kCtapClientPinKeyAgreementResponse },
        Bytes { TestData::kCtapClientPinInvalidKeyAgreementResponse },
    };
    size_t bytes = 0;
    for (auto input : inputs)
        bytes += input.size();
    Vector<uint8_t> clientDataHash = toVector(Bytes { TestData::kClientDataHash });
    run("PinParsers"_s, bytes, 0x70e030c05ba6a986ULL, 264000u, [&] {
        Hash hash;
        for (auto input : inputs) {
            auto data = toVector(input);
            auto retries = fido::pin::RetriesResponse::parse(data);
            hash.addFlag(!!retries);
            if (retries)
                hash.add(retries->retries);
            auto keyAgreement = fido::pin::KeyAgreementResponse::parse(data);
            hash.addFlag(!!keyAgreement);
            auto token = fido::pin::TokenResponse::parse(fido::PINUVAuthProtocol::kPinProtocol1, *sharedKey, data);
            hash.addFlag(!!token);
            if (token) {
                hash.add(token->token().span());
                hash.add(token->pinAuth(fido::PINUVAuthProtocol::kPinProtocol1, clientDataHash).span());
            }
        }
        for (String pin : { String(""_s), String("123"_s), String("1234"_s), String("123456781234567812345678123456781234567812345678123456781234567"_s), String("1234567812345678123456781234567812345678123456781234567812345678"_s), String::fromUTF8(u8"p\u00e4ssw\u00f6rd"_span) }) {
            auto utf8 = fido::pin::validateAndConvertToUTF8(pin);
            hash.addFlag(!!utf8);
            if (utf8)
                hash.add(String::fromUTF8(utf8->span()));
        }
        Vector<uint8_t> rawKey = patternBytes(65, 3);
        rawKey[0] = 0x04;
        hashValue(hash, cbor::CBORValue(fido::pin::encodeCOSEPublicKey(rawKey)));
        return hash.value();
    });
}

TEST(WebAuthnBench, PinRequests)
{
    auto keys = makePinKeys();
    auto salt1 = patternBytes(32, 1);
    auto salt2 = patternBytes(32, 2);
    auto shortSalt = patternBytes(16, 3);
    run("PinRequests"_s, 2048, 0x4c56a1b548f96c83ULL, 451u, [&] {
        Hash hash;
        for (auto protocol : { fido::PINUVAuthProtocol::kPinProtocol1, fido::PINUVAuthProtocol::kPinProtocol2 }) {
            hash.add(fido::pin::encodeAsCBOR(fido::pin::RetriesRequest { protocol }).span());
            hash.add(fido::pin::encodeAsCBOR(fido::pin::KeyAgreementRequest { protocol }).span());
            // Random ephemeral keys and IVs make the contents differ from run to run: only the size and the command are observed.
            auto setPin = fido::pin::SetPinRequest::tryCreate(protocol, "1234"_s, *keys.peerKey);
            hash.addFlag(!!setPin);
            if (setPin) {
                auto encoded = fido::pin::encodeAsCBOR(std::move(*setPin));
                hash.add(static_cast<uint64_t>(encoded.size()));
                hash.add(static_cast<uint64_t>(encoded[0]));
            }
            hash.addFlag(!!fido::pin::SetPinRequest::tryCreate(protocol, "123"_s, *keys.peerKey));
            hash.addFlag(!!fido::pin::SetPinRequest::tryCreate(protocol, "1234567812345678123456781234567812345678123456781234567812345678"_s, *keys.peerKey));
            auto pin = fido::pin::validateAndConvertToUTF8("1234"_s);
            auto tokenRequest = fido::pin::TokenRequest::tryCreate(protocol, *pin, *keys.peerKey);
            hash.addFlag(!!tokenRequest);
            if (tokenRequest) {
                auto encoded = fido::pin::encodeAsCBOR(*tokenRequest);
                hash.add(static_cast<uint64_t>(encoded.size()));
                hash.add(static_cast<uint64_t>(encoded[0]));
            }
            // The hmac-secret salts: encrypted, then decrypted by the response parser with the same shared key.
            for (auto* second : { static_cast<Vector<uint8_t>*>(nullptr), &salt2 }) {
                std::optional<Vector<uint8_t>> secondSalt;
                if (second)
                    secondSalt = *second;
                auto request = fido::pin::HmacSecretRequest::create(protocol, salt1, secondSalt, keys.peerKey.copyRef());
                hash.addFlag(!!request);
                if (!request)
                    continue;
                hash.add(static_cast<uint64_t>(request->saltEnc().size()));
                hash.add(static_cast<uint64_t>(request->saltAuth().size()));
                auto response = fido::pin::HmacSecretResponse::parse(protocol, request->sharedKey(), request->saltEnc());
                hash.addFlag(!!response);
                if (response)
                    hash.add(response->output().span());
                auto truncated = request->saltEnc();
                // A whole block shorter: a ciphertext that is not a block multiple is a precondition of the decryption.
                truncated.shrink(truncated.size() - 16);
                hash.addFlag(!!fido::pin::HmacSecretResponse::parse(protocol, request->sharedKey(), truncated));
            }
            hash.addFlag(!!fido::pin::HmacSecretRequest::create(protocol, shortSalt, std::nullopt, keys.peerKey.copyRef()));
            hash.addFlag(!!fido::pin::HmacSecretRequest::create(protocol, salt1, shortSalt, keys.peerKey.copyRef()));
        }
        return hash.value();
    });
}

} // namespace WebAuthnBenchmark

} // namespace TestWebKitAPI

#endif // ENABLE(WEB_AUTHN)
