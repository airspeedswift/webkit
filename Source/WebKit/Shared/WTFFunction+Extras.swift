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

#if compiler(>=6.4) && !SWIFT_WEBKIT_TOOLCHAIN

import wtf.Core.Function

/// A `WTF::Function` specialization that takes no argument and returns `void`, which Swift can build from a closure.
protocol CxxVoidFunction: ~Copyable {
    /// Creates a function from the C ABI a Swift closure reduces to: a function pointer, an opaque context, and a
    /// destructor for that context.
    ///
    /// Every specialization of `WTF::Function` already has this constructor, so conformances never implement it
    /// themselves.
    ///
    /// - Important: Do not implement or call this yourself.
    init(invoke: WTF.SwiftClosureInvoke, destroy: WTF.SwiftClosureDestroy, context: UnsafeMutableRawPointer)
}

extension CxxVoidFunction where Self: ~Copyable {
    /// Creates a `WTF::Function` from a Swift closure.
    ///
    /// The closure is `@Sendable` because C++ may call a `WTF::Function`, and destroy it, on any thread (a work queue's
    /// `dispatch`, for one). It is the only way Swift makes a `WTF::Function`.
    ///
    /// - Parameter body: The Swift closure to call.
    @safe
    init(sendable body: @escaping @Sendable () -> Void) {
        // Safe because every use of the raw pointer is encapsulated here and in the C++ constructor: the context is
        // retained once here, released once by `destroy` (the C++ `unique_ptr` that owns it), and only read in between.
        unsafe self.init(
            invoke: { context, argument in
                unsafe precondition(argument == nil)
                unsafe Unmanaged<SwiftSendableVoidClosureBox>.fromOpaque(context).takeUnretainedValue().body()
            },
            destroy: { context in
                unsafe Unmanaged<SwiftSendableVoidClosureBox>.fromOpaque(context).release()
            },
            context: unsafe Unmanaged.passRetained(SwiftSendableVoidClosureBox(body)).toOpaque()
        )
    }
}

private final class SwiftSendableVoidClosureBox: Sendable {
    let body: @Sendable () -> Void

    init(_ body: @escaping @Sendable () -> Void) {
        self.body = body
    }
}

extension WTF.VoidFunction: @unsafe CxxVoidFunction {}

#endif // compiler(>=6.4) && !SWIFT_WEBKIT_TOOLCHAIN
