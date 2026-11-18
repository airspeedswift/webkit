// Copyright (C) 2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEB_AUTHN && HAVE_NEAR_FIELD

import WebCore_Private
import WebKit_Internal
import wtf

// CTAP2 over ISO 7816-4 APDUs, as for NFC.
// https://fidoalliance.org/specs/fido-v2.0-ps-20190130/fido-client-to-authenticator-protocol-v2.0-ps-20190130.html#nfc-command-framing

extension WebKit.CtapNfcDriver {
    @cxx @implementation
    func encodeCtap2Command(_ data: cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue {
        if !isValidSize(data.size()) {
            WebKit.LogChannel.WebAuthn().releaseLog.log(
                "CtapNfcDriver::transact Sending data larger than maxSize. msgSize=\(data.size())"
            )
        }
        return apdu.ApduCommand.encodeCommand(
            fido.kCtapNfcApduCla, fido.kCtapNfcApduIns, 0, 0, fido.apduMaxResponseLength(), data
        )
    }

    @cxx @implementation
    func ctap2Response(_ apduResponse: cbor.CBORValue.BinaryValue) -> cbor.CBORValue.BinaryValue {
        guard let response = Optional(fromCxx: apdu.ApduResponse.createFromMessage(apduResponse)) else {
            return cbor.CBORValue.BinaryValue()
        }
        if response.status() == .SW_INS_NOT_SUPPORTED {
            // Return kCtap1ErrInvalidCommand instead of an empty response to signal FidoService to create a U2F
            // authenticator for the getInfo stage.
            var invalidCommand = cbor.CBORValue.BinaryValue()
            invalidCommand.append(consuming: fido.CtapDeviceResponseCode.ctap1ErrInvalidCommand.rawValue)
            return invalidCommand
        }
        if response.status() != .SW_NO_ERROR {
            return cbor.CBORValue.BinaryValue()
        }
        return fido.apduResponseData(response)
    }
}

#endif // ENABLE_WEB_AUTHN && HAVE_NEAR_FIELD
