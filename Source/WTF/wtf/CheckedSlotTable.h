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

#include <cstdint>
#include <limits>
#include <type_traits>
#include <wtf/Assertions.h>
#include <wtf/SwiftBridging.h>
#include <wtf/Vector.h>

namespace WTF {

// One slot per live T, named by a Handle (slot index plus generation) that can be held by code
// that cannot hold a T, such as Swift. A Handle is a value: it keeps nothing alive, and a stale one
// is detected, not followed. resolve() is the only place an integer becomes a pointer, and it
// checks. add() and remove() are unavailable in Swift: add() stores the address of the object it is
// given, which Swift could not keep alive, and the owner's C++ keeps the registrations in step with
// the objects' lifetimes. Everything else Swift can see is safe to call. SWIFT_SAFE because the
// pointers are held in private storage that only resolve() reads, and resolve() is SWIFT_UNSAFE.
//
// Slot 0 is never handed out, so Handle { 0, 0 } is the null handle: it is never live.
// Not thread-safe: the owner confines it to one thread.
// Outside the template so that Swift can name it (a type nested in a class template is not imported).
struct CheckedSlotHandle {
    uint32_t slot { 0 };
    uint32_t generation { 0 };
};

template<typename T>
class SWIFT_SAFE CheckedSlotTable {
public:
    using Handle = CheckedSlotHandle;

    // Every instantiation that is constructed checks the destructor: Swift relocates a non-copyable
    // type with a trivial destructor bitwise, so it must stay user-provided.
    CheckedSlotTable()
    {
        static_assert(!std::is_trivially_destructible_v<CheckedSlotTable>);
        m_slots.append(Slot { });
    }

    // Not WTF_MAKE_NONCOPYABLE: a class with a deleted copy and no move constructor is not imported by
    // Swift. The move constructor leaves the source an empty, valid table; handles stay valid in the target.
    CheckedSlotTable(const CheckedSlotTable&) = delete;
    CheckedSlotTable& operator=(const CheckedSlotTable&) = delete;
    CheckedSlotTable& operator=(CheckedSlotTable&&) = delete;
    CheckedSlotTable(CheckedSlotTable&& other)
        : m_slots(WTF::move(other.m_slots))
        , m_freeSlots(WTF::move(other.m_freeSlots))
        , m_removalEpoch(other.m_removalEpoch)
    {
        static_assert(!std::is_trivially_destructible_v<CheckedSlotTable>);
        other.m_slots.clear();
        other.m_freeSlots.clear();
        other.m_slots.append(Slot { });
    }

    // User-provided, never defaulted: a non-copyable type with a trivial destructor is relocated
    // bitwise by Swift (UNSAFETY.md).
    ~CheckedSlotTable() { }

    SWIFT_UNAVAILABLE_IN_SWIFT Handle add(T& object)
    {
        if (!m_freeSlots.isEmpty()) {
            uint32_t slot = m_freeSlots.takeLast();
            Slot& entry = m_slots[slot];
            ASSERT(!entry.pointer);
            entry.pointer = &object;
            return { slot, entry.generation };
        }
        RELEASE_ASSERT(m_slots.size() < std::numeric_limits<uint32_t>::max());
        uint32_t slot = static_cast<uint32_t>(m_slots.size());
        m_slots.append(Slot { &object, 1 });
        return { slot, 1 };
    }

    // A handle that is stale or null is ignored, so that removing twice is harmless.
    SWIFT_UNAVAILABLE_IN_SWIFT void remove(Handle handle)
    {
        if (!isLive(handle))
            return;
        Slot& entry = m_slots[handle.slot];
        entry.pointer = nullptr;
        // A generation that wraps to 0 is skipped, so a live slot never has generation 0.
        entry.generation = entry.generation + 1 ? entry.generation + 1 : 1;
        ++m_removalEpoch;
        m_freeSlots.append(handle.slot);
    }

    // The only place an integer becomes a pointer. A stale, null or out-of-range handle traps.
    SWIFT_UNSAFE T& resolve(Handle handle) const
    {
        RELEASE_ASSERT(handle.slot < m_slots.size());
        const Slot& entry = m_slots[handle.slot];
        RELEASE_ASSERT(entry.generation == handle.generation);
        RELEASE_ASSERT(entry.pointer);
        return *entry.pointer;
    }

    bool isLive(Handle handle) const
    {
        if (handle.slot >= m_slots.size())
            return false;
        const Slot& entry = m_slots[handle.slot];
        return entry.pointer && entry.generation == handle.generation;
    }

    // Counts removals, so that a walk can tell that something it holds may have gone. 64 bits, so
    // that it cannot wrap in practice.
    uint64_t removalEpoch() const { return m_removalEpoch; }

private:
    struct Slot {
        T* pointer { nullptr };
        uint32_t generation { 0 };
    };

    Vector<Slot> m_slots;
    Vector<uint32_t> m_freeSlots;
    uint64_t m_removalEpoch { 0 };
};

} // namespace WTF

using WTF::CheckedSlotTable;
