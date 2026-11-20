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

// How Swift builds a `WTF::Function` from a closure.
//
// The protocols below are `fileprivate`, and every conformance to them is declared in this file, each with its
// `Output` and `Argument` stated equal to the C++ specialization's return and parameter types: the generic
// initializers write an `Output` into, and read an `Argument` from, C++ storage of those types, so a conformance
// with any other type would be a memory-safety hole. A conformance's `callAsFunction` requirement is witnessed by the
// imported C++ `operator()`, which makes the compiler check those types. Each conformer gets a non-generic
// `init(sendable:)` that forwards to the generic one; that is the only way the rest of the module makes a Function.
//
// A conformance also states the C++ shape it belongs to: a `Function<void(A)>` conforms only to `CxxArgumentFunction`,
// never to `CxxResultArgumentFunction` with `Output = Void`, because the two read a different argument frame.
//
// To let Swift build another specialization, add its conformance and its `init(sendable:)` here.

/// The machinery shared by ``CxxVoidFunction``, ``CxxResultFunction``, ``CxxArgumentFunction`` and
/// ``CxxResultArgumentFunction``.
fileprivate protocol CxxFunctionBase: ~Copyable {
    /// Creates a function from the C ABI a Swift closure reduces to: a function pointer, an opaque context, and a
    /// destructor for that context.
    ///
    /// Every specialization of `WTF::Function` already has this constructor, so conformances never implement it
    /// themselves.
    ///
    /// - Important: Do not implement or call this yourself.
    init(invoke: WTF.SwiftClosureInvoke, destroy: WTF.SwiftClosureDestroy, context: UnsafeMutableRawPointer)
}

/// A `WTF::Function` specialization that takes no argument and returns `void`, which Swift can build from a closure.
fileprivate protocol CxxVoidFunction: CxxFunctionBase, ~Copyable {}

/// A `WTF::Function<Output()>`, which Swift can build from a closure that returns the `Output` (move-only or not).
fileprivate protocol CxxResultFunction: CxxFunctionBase, ~Copyable {
    /// State this explicitly, matching the C++ return type: `typealias Output = Reply`.
    associatedtype Output: ~Copyable

    /// Calls the function. Implemented by the imported C++ `operator()`, which is what makes the compiler verify that
    /// `Output` matches the C++ return type.
    ///
    /// - Important: Do not implement this yourself.
    func callAsFunction() -> Output
}

/// A `WTF::Function<void(Argument)>` with a by-value, copyable argument, which Swift can build from a closure.
fileprivate protocol CxxArgumentFunction: CxxFunctionBase, ~Copyable {
    /// State this explicitly, matching the C++ parameter type: `typealias Argument = CInt`.
    associatedtype Argument: Copyable

    /// Calls the function. Implemented by the imported C++ `operator()`, which is what makes the compiler verify that
    /// `Argument` matches the C++ parameter type.
    ///
    /// - Important: Do not implement this yourself.
    func callAsFunction(_ argument: Argument)
}

/// A `WTF::Function<Output(Argument)>` with a by-value, copyable argument, which Swift can build from a closure that
/// returns the `Output` (move-only or not).
fileprivate protocol CxxResultArgumentFunction: CxxFunctionBase, ~Copyable {
    /// State this explicitly, matching the C++ parameter type.
    associatedtype Argument: Copyable

    /// State this explicitly, matching the C++ return type.
    associatedtype Output: ~Copyable

    /// Calls the function. Implemented by the imported C++ `operator()`, which is what makes the compiler verify that
    /// `Argument` and `Output` match the C++ types.
    ///
    /// - Important: Do not implement this yourself.
    func callAsFunction(_ argument: Argument) -> Output
}

extension CxxFunctionBase where Self: ~Copyable {
    /// Creates a function that owns `box` and dispatches to it.
    fileprivate init(box: SwiftSendableClosureBox) {
        // Safe because every use of the raw pointer is encapsulated here and in the C++ constructor: the context is
        // retained once here, released once by `destroy` (the C++ `unique_ptr` that owns it), and only read in between.
        unsafe self.init(
            invoke: { context, argument in
                unsafe Unmanaged<SwiftSendableClosureBox>.fromOpaque(context).takeUnretainedValue().body(argument)
            },
            destroy: { context in
                unsafe releaseSwiftSendableClosureBox(context)
            },
            context: unsafe Unmanaged.passRetained(box).toOpaque()
        )
    }
}

extension CxxVoidFunction where Self: ~Copyable {
    /// Creates a `WTF::Function` from a Swift closure.
    ///
    /// The closure is `@Sendable` because C++ may call a `WTF::Function`, and destroy it, on any thread (a work queue's
    /// `dispatch`, for one). It is the only way Swift makes a `WTF::Function`.
    ///
    /// - Parameter body: The Swift closure to call.
    @safe
    fileprivate init(cxxSendable body: @escaping @Sendable () -> Void) {
        self.init(box: unsafe SwiftSendableClosureBox { argument in
            unsafe precondition(argument == nil)
            body()
        })
    }
}

extension CxxResultFunction where Self: ~Copyable {
    /// Creates a `WTF::Function` from a Swift closure that returns its result.
    ///
    /// The closure builds the result on the calling thread and initializes the C++ caller's uninitialized storage once;
    /// C++ moves it out and destroys the storage, so the result is never shared with another thread.
    ///
    /// - Parameter body: The Swift closure to call.
    @safe
    fileprivate init(cxxSendable body: @escaping @Sendable () -> Output) {
        self.init(box: unsafe SwiftSendableClosureBox { argument in
            // Safe because the C++ caller passes non-nil, aligned, uninitialized storage for an `Output`, and the
            // closure is called once per call.
            unsafe precondition(argument != nil)
            unsafe argument.unsafelyUnwrapped.assumingMemoryBound(to: Output.self).initialize(to: body())
        })
    }
}

extension CxxArgumentFunction where Self: ~Copyable {
    /// Creates a `WTF::Function` from a Swift closure that takes the function's argument, copied.
    ///
    /// - Parameter body: The Swift closure to call.
    @safe
    fileprivate init(cxxSendable body: @escaping @Sendable (Argument) -> Void) {
        self.init(box: unsafe SwiftSendableClosureBox { argument in
            // Safe because the C++ caller passes the address of its live argument, which is only read here.
            unsafe precondition(argument != nil)
            body(unsafe argument.unsafelyUnwrapped.assumingMemoryBound(to: Argument.self).pointee)
        })
    }
}

extension CxxResultArgumentFunction where Self: ~Copyable {
    /// Creates a `WTF::Function` from a Swift closure that takes the function's argument, copied, and returns its result.
    ///
    /// As for ``CxxResultFunction``, the result is initialized once into the C++ caller's storage, which C++ moves out
    /// and destroys, so it is never shared with another thread.
    ///
    /// - Parameter body: The Swift closure to call.
    @safe
    fileprivate init(cxxSendable body: @escaping @Sendable (Argument) -> Output) {
        self.init(box: unsafe SwiftSendableClosureBox { argument in
            // Safe because the C++ caller passes a `WTF::SwiftClosureResultFrame` holding the address of its live
            // argument, which is only read here, and of non-nil, aligned, uninitialized storage for an `Output`; the
            // closure is called once per call.
            unsafe precondition(argument != nil)
            let frame = unsafe argument.unsafelyUnwrapped.assumingMemoryBound(to: WTF.SwiftClosureResultFrame.self).pointee
            let input = unsafe frame.argument.assumingMemoryBound(to: Argument.self).pointee
            unsafe frame.result.assumingMemoryBound(to: Output.self).initialize(to: body(input))
        })
    }
}

/// Releases the box a `WTF::Function` owns, when C++ destroys the function.
///
/// Never inlined, as a workaround: the C++ constructor's `unique_ptr` calls `destroy` from an exception cleanup, and with
/// the release inlined there, the optimizer's ARC pass moves it above the cleanup's `cleanuppad` on Windows, which fails
/// LLVM's IR verification.
@unsafe @inline(never)
private func releaseSwiftSendableClosureBox(_ context: UnsafeMutableRawPointer) {
    unsafe Unmanaged<SwiftSendableClosureBox>.fromOpaque(context).release()
}

@safe private final class SwiftSendableClosureBox: Sendable {
    @safe let body: @Sendable (UnsafeMutableRawPointer?) -> Void

    @unsafe init(_ body: @escaping @Sendable (UnsafeMutableRawPointer?) -> Void) {
        unsafe self.body = body
    }
}

// MARK: - Conformances

extension WTF.SpanApplyFunction: @unsafe CxxResultArgumentFunction {
    typealias Argument = WTF.SpanApplyArgument
    typealias Output = Bool

    /// Creates a span applier from a Swift closure that reads each span it is given; the span lives only for the call.
    init(sendable body: @escaping @Sendable (Span<UInt8>) -> Bool) {
        self.init(cxxSendable: { (span: WTF.SpanApplyArgument) -> Bool in
            // Safe because the C++ caller's span is live for the whole call, and the Span cannot escape the closure.
            body(unsafe Span(_unsafeCxxSpan: span))
        })
    }
}

extension WTF.VoidFunction: @unsafe CxxVoidFunction {}

extension WTF.VoidFunction {
    /// Creates a `WTF::Function<void()>` from a Swift closure.
    init(sendable body: @escaping @Sendable () -> Void) {
        self.init(cxxSendable: body)
    }
}

#endif // compiler(>=6.4) && !SWIFT_WEBKIT_TOOLCHAIN
