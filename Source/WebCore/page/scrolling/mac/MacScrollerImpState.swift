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

// PLATFORM(MAC), as ScrollerMac.mm, the C++ this replaces.
#if os(macOS)

internal import AppKit
internal import QuartzCore
internal import Synchronization
internal import pal.spi.mac.NSScrollerImpSPI
internal import wtf.Core.CurrentThread

/// One scroller's NSScrollerImp and the objects used with it, behind the scroller's lock.
///
/// The lock is recursive because AppKit calls the delegates back while it is held, and the callbacks take it again.
/// scrollerImp is set while committing scrolling state, when the pair is created and on the main thread, and taken
/// while committing. It is also read on the scrolling and main threads, on the threads AppKit calls the delegates
/// on, and on the thread that destroys the pair.
final class MacScrollerImpState: @unchecked Sendable {
    /// WTF::RecursiveLock's algorithm.
    ///
    /// Only the thread that holds the lock finds its own ID in owner, so a nested withLock on that thread runs its
    /// body directly. Not inlined, so each region's body is emitted once.
    private struct RecursiveLock: ~Copyable, Sendable {
        private let mutex = Mutex<Void>(())
        private let owner = Atomic<UInt32>(0)

        @inline(never)
        borrowing func withLock<Result: Sendable>(_ body: () -> Result) -> Result {
            let currentThreadID = WTF.currentThreadID()
            if owner.load(ordering: .relaxed) == currentThreadID {
                return body()
            }
            return mutex.withLock { _ in
                owner.store(currentThreadID, ordering: .relaxed)
                defer { owner.store(0, ordering: .relaxed) }
                return body()
            }
        }
    }

    private let lock = RecursiveLock()
    private var scrollerImp: NSScrollerImp?
    private var hostLayer: CALayer?
    private var trackColor: NSColor?
    private var thumbColor: NSColor?
    private var isHiddenByStyle = false
    private var scrollerImpsToRelease: [NSScrollerImp?] = []

    /// The state, for the duration of one withLock call.
    struct Locked: ~Copyable, ~Sendable {
        private let state: MacScrollerImpState

        fileprivate static func withLock<Result: Sendable>(_ state: MacScrollerImpState, _ body: (borrowing Locked) -> Result) -> Result {
            state.lock.withLock { body(Locked(state: state)) }
        }

        var scrollerImp: NSScrollerImp? {
            get { state.scrollerImp }
            nonmutating set { state.scrollerImp = newValue }
        }
        var hostLayer: CALayer? {
            get { state.hostLayer }
            nonmutating set { state.hostLayer = newValue }
        }
        var trackColor: NSColor? {
            get { state.trackColor }
            nonmutating set { state.trackColor = newValue }
        }
        var thumbColor: NSColor? {
            get { state.thumbColor }
            nonmutating set { state.thumbColor = newValue }
        }
        var isHiddenByStyle: Bool {
            get { state.isHiddenByStyle }
            nonmutating set { state.isHiddenByStyle = newValue }
        }
        func appendScrollerImpToRelease(_ scrollerImp: NSScrollerImp?) {
            state.scrollerImpsToRelease.append(scrollerImp)
        }
        /// Removes the oldest entry, if any, and returns it.
        func removeOldestScrollerImpToRelease() -> NSScrollerImp? {
            state.scrollerImpsToRelease.isEmpty ? nil : state.scrollerImpsToRelease.removeFirst()
        }
    }

    func withLock<Result: Sendable>(_ body: (borrowing Locked) -> Result) -> Result {
        Locked.withLock(self, body)
    }
}

// Reflection would read the state without the lock.
extension MacScrollerImpState: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: [:]) }
}

#endif // os(macOS)
