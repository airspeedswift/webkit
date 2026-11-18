/*
 * Copyright (C) 2019 Apple Inc. All rights reserved.
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

#if ENABLE(WEB_AUTHN)

#include "FidoAuthenticator.h"
#include <wtf/RunLoop.h>
#include <wtf/SwiftBridging.h>

namespace WebKit {

class CtapDriver;

class SWIFT_PRIVATE_FILEID("WebKit/U2fAuthenticator.swift") U2fAuthenticator final : public FidoAuthenticator {
public:
    static Ref<U2fAuthenticator> create(Ref<CtapDriver>&& driver)
    {
        return adoptRef(*new U2fAuthenticator(WTF::move(driver)));
    }
    ~U2fAuthenticator(); // The key function, kept in C++ so the vtable is emitted with the destructor.

    // Public: Swift crashes serializing a private nested C++ enum used in a Swift signature.
    enum class CommandType : uint8_t {
        RegisterCommand,
        CheckOnlyCommand,
        BogusCommandExcludeCredentialsMatch,
        BogusCommandNoCredentials,
        SignCommand
    };

private:
    explicit U2fAuthenticator(Ref<CtapDriver>&&);

    void makeCredential() final;
    void getAssertion() final;

    void retryLastCommand() { issueCommand(m_lastCommand, m_lastCommandType); }
    void scheduleRetry() { m_retryTimer.startOneShot(Seconds::fromMilliseconds(200)); }
    void issueCommand(Vector<uint8_t> command, CommandType);

    RunLoop::Timer m_retryTimer;
    Vector<uint8_t> m_lastCommand;
    CommandType m_lastCommandType;
    size_t m_nextListIndex { 0 };
    bool m_isAppId { false };
};

using WeakPtrU2fAuthenticator = WeakPtr<U2fAuthenticator>;

} // namespace WebKit

#endif // ENABLE(WEB_AUTHN)
