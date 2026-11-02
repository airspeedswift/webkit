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

#include <wtf/ExportMacros.h>

#if __BLOCKS__

namespace WTF {

// Block versions of callOnMainThread() and ensureOnMainThread(), for Swift. Swift sees the
// block as a @Sendable closure, so it checks what the closure captures. The block, and what
// it captures, is released on whichever thread drops the last reference to it, which may be
// the calling thread.
WTF_EXPORT_PRIVATE void callOnMainThreadWithBlock(void (^ __attribute__((swift_attr("@Sendable"))) _Nonnull block)(void));
WTF_EXPORT_PRIVATE void ensureOnMainThreadWithBlock(void (^ __attribute__((swift_attr("@Sendable"))) _Nonnull block)(void));

} // namespace WTF

using WTF::callOnMainThreadWithBlock;
using WTF::ensureOnMainThreadWithBlock;

#endif // __BLOCKS__
