/*
 * Copyright (C) 2018-2025 Apple Inc. All rights reserved.
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
#include "CtapHidDriver.h"

#if ENABLE(WEB_AUTHN)

#include <wtf/Assertions.h>
#include <wtf/RunLoop.h>

namespace WebKit {
using namespace fido;

Ref<CtapHidDriver> CtapHidDriver::create(Ref<HidConnection>&& connection)
{
    return adoptRef(*new CtapHidDriver(WTF::move(connection)));
}

CtapHidDriver::CtapHidDriver(Ref<HidConnection>&& connection)
    : CtapDriver(WebCore::AuthenticatorTransport::Usb)
    , m_connection(WTF::move(connection))
    , m_nonce(kHidInitNonceLength)
{
    m_connection->initialize();
}

CtapHidDriver::~CtapHidDriver()
{
    m_connection->terminate();
}

void CtapHidDriver::transact(Vector<uint8_t>&& data, ResponseCallback&& callback)
{
    m_requestData = WTF::move(data);
    m_responseCallback = WTF::move(callback);
    startTransaction();
}

void CtapHidDriver::sendPacket(Vector<uint8_t> packet)
{
    m_connection->send(WTF::move(packet), [weakThis = WeakPtr { *this }](HidConnection::DataSent sent) mutable {
        ASSERT(RunLoop::isMain());
        if (RefPtr protectedThis = weakThis)
            protectedThis->workerWrite(sent);
    });
}

void CtapHidDriver::listenForData()
{
    m_connection->registerDataReceivedCallback([weakThis = WeakPtr { *this }](Vector<uint8_t>&& data) mutable {
        ASSERT(RunLoop::isMain());
        if (RefPtr protectedThis = weakThis)
            protectedThis->workerRead(data);
    });
}

void CtapHidDriver::retryTransactionAsync()
{
    RunLoop::mainSingleton().dispatch([weakThis = WeakPtr { *this }, data = WTF::move(m_requestData), callback = WTF::move(m_responseCallback)]() mutable {
        if (RefPtr protectedThis = weakThis)
            protectedThis->transact(WTF::move(data), WTF::move(callback));
    });
}

void CtapHidDriver::returnResponse(Vector<uint8_t> response)
{
    // Reset state before calling the response callback to avoid being deleted.
    auto responseCallback = WTF::move(m_responseCallback);
    reset();
    responseCallback(WTF::move(response));
}

void CtapHidDriver::reset()
{
    m_responseCallback = nullptr;
    m_channelId = fido::kHidBroadcastChannel;
    m_state = State::Idle;
}

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
