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

#include <optional>
#include <utility>
#include <wtf/HashSet.h>
#include <wtf/Ref.h>
#include <wtf/Vector.h>
#include <wtf/WeakRef.h>

namespace WTF {

// Operations on a container data member of a class that Swift imports as a shared reference.
// Swift cannot call container members that take a functor or use iterators, and passing the
// member itself either copies it (const reference) or claims exclusive access to it (inout)
// while the callee can reach it through its owner. Each operation takes the owner and returns
// a value, or a raw pointer to a reference-counted element. Declare the alias after the member:
//     using EntriesOperations = WTF::MemberHashMapOperations<Owner, decltype(m_entries), &Owner::m_entries>;
//
// Operations that take a key, or a value of a set, release-assert that the table can hash it:
// StringHash cannot hash a null String, the empty value of its table. For a hash function that
// is safe to compare to the empty and deleted values (integers, identifiers) the check is a
// compile-time true.

namespace Detail {

// How an element is passed: a value as itself, Ref<T> and WeakRef<T> as T& in; get() returns T*, copyValues() Ref<T>.
template<typename T> struct MemberContainerElement {
    using ArgumentType = const T&;
    using StrongType = T;
    static const T& wrap(const T& value) { return value; }
    static const T& strong(const T& element) { return element; }
};

template<typename T, typename PtrTraits, typename RefDerefTraits> struct MemberContainerElement<Ref<T, PtrTraits, RefDerefTraits>> {
    using ArgumentType = T&;
    using StrongType = Ref<T, PtrTraits, RefDerefTraits>;
    static StrongType wrap(T& value) { return StrongType { value }; }
    static StrongType strong(const StrongType& element) { return element; }
};

template<typename T, typename WeakPtrImpl> struct MemberContainerElement<WeakRef<T, WeakPtrImpl>> {
    using ArgumentType = T&;
    using StrongType = Ref<T>;
    static WeakRef<T, WeakPtrImpl> wrap(T& value) { return WeakRef<T, WeakPtrImpl> { value }; }
    static StrongType strong(const WeakRef<T, WeakPtrImpl>& element) { return element.get(); }
};

// HashSet and HashCountedSet have isValidValue(); a ListHashSet hashes as the HashSet of its value type.
// A hash that is safe to compare to the empty and deleted values needs no check, and is not given the
// value's HashTraits, which may be declared on the hash itself (SimpleClassHashTraits<Hash>).
template<typename Set> struct SetValueValidity {
    static bool isValid(const typename Set::ValueType& value) { return Set::isValidValue(value); }
};

template<typename Value, typename HashFunctions> struct SetValueValidity<ListHashSet<Value, HashFunctions>> {
    static bool isValid(const Value& value)
    {
        if constexpr (HashFunctions::safeToCompareToEmptyOrDeleted)
            return true;
        else
            return HashSet<Value, HashFunctions>::isValidValue(value);
    }
};

} // namespace Detail

// HashMap and its variants (MemoryCompactRobinHoodHashMap). get() returns what HashMap::get()
// does: the value, or for a Ref or WeakRef value a raw pointer, null if the key is absent.
// getOptional() is for values that are not a Ref or a WeakRef.
template<typename Owner, typename Map, Map Owner::*member>
struct MemberHashMapOperations {
    using KeyType = typename Map::KeyType;
    using MappedType = typename Map::MappedType;
    using MappedPeekType = decltype(std::declval<const Map&>().get(std::declval<const KeyType&>()));
    using Element = Detail::MemberContainerElement<MappedType>;
    using MappedArgumentType = typename Element::ArgumentType;
    using StrongMappedType = typename Element::StrongType;

    static bool contains(const Owner& owner, const KeyType& key)
    {
        RELEASE_ASSERT(Map::isValidKey(key));
        return (owner.*member).contains(key);
    }

    static MappedPeekType get(const Owner& owner, const KeyType& key)
    {
        RELEASE_ASSERT(Map::isValidKey(key));
        return (owner.*member).get(key);
    }

    static std::optional<MappedType> getOptional(const Owner& owner, const KeyType& key)
    {
        RELEASE_ASSERT(Map::isValidKey(key));
        return (owner.*member).getOptional(key);
    }

    static void set(Owner& owner, const KeyType& key, MappedArgumentType value)
    {
        RELEASE_ASSERT(Map::isValidKey(key));
        (owner.*member).set(key, Element::wrap(value));
    }

    // Returns whether the key was new.
    static bool add(Owner& owner, const KeyType& key, MappedArgumentType value)
    {
        RELEASE_ASSERT(Map::isValidKey(key));
        return (owner.*member).add(key, Element::wrap(value)).isNewEntry;
    }

    static bool remove(Owner& owner, const KeyType& key)
    {
        RELEASE_ASSERT(Map::isValidKey(key));
        return (owner.*member).remove(key);
    }

    // Ref and WeakRef values are copied out as Ref.
    static Vector<StrongMappedType> copyValues(const Owner& owner)
    {
        Vector<StrongMappedType> values;
        values.reserveInitialCapacity((owner.*member).size());
        for (auto& value : (owner.*member).values())
            values.append(Element::strong(value));
        return values;
    }
};

// A HashMap<Key, HashMap<InnerKey, Vector<Value>>>, as a two-level index.
template<typename Owner, typename Map, Map Owner::*member>
struct MemberNestedHashMapOperations {
    using KeyType = typename Map::KeyType;
    using InnerMapType = typename Map::MappedType;
    using InnerKeyType = typename InnerMapType::KeyType;
    using VectorType = typename InnerMapType::MappedType;
    using ValueType = typename VectorType::ValueType;

    static bool containsIn(const Owner& owner, const KeyType& key, const InnerKeyType& innerKey, const ValueType& value)
    {
        RELEASE_ASSERT(Map::isValidKey(key));
        RELEASE_ASSERT(InnerMapType::isValidKey(innerKey));
        auto iterator = (owner.*member).find(key);
        if (iterator == (owner.*member).end())
            return false;
        auto innerIterator = iterator->value.find(innerKey);
        return innerIterator != iterator->value.end() && innerIterator->value.contains(value);
    }

    // Adds both keys if they are absent, then appends the value to their vector.
    static void appendTo(Owner& owner, const KeyType& key, const InnerKeyType& innerKey, const ValueType& value)
    {
        RELEASE_ASSERT(Map::isValidKey(key));
        RELEASE_ASSERT(InnerMapType::isValidKey(innerKey));
        auto& innerMap = (owner.*member).add(key, InnerMapType { }).iterator->value;
        innerMap.add(innerKey, VectorType { }).iterator->value.append(value);
    }

    // Removes the first equal value from the keys' vector, leaving an emptied entry in place.
    static bool removeFirstFrom(Owner& owner, const KeyType& key, const InnerKeyType& innerKey, const ValueType& value)
    {
        RELEASE_ASSERT(Map::isValidKey(key));
        RELEASE_ASSERT(InnerMapType::isValidKey(innerKey));
        auto iterator = (owner.*member).find(key);
        if (iterator == (owner.*member).end())
            return false;
        auto innerIterator = iterator->value.find(innerKey);
        return innerIterator != iterator->value.end() && innerIterator->value.removeFirst(value);
    }

    // Removes the first equal value from every vector, then every entry left empty.
    static void removeFirstFromAllAndPrune(Owner& owner, const ValueType& value)
    {
        (owner.*member).removeIf([&](auto& entry) {
            entry.value.removeIf([&](auto& innerEntry) {
                innerEntry.value.removeFirst(value);
                return innerEntry.value.isEmpty();
            });
            return entry.value.isEmpty();
        });
    }
};

// HashSet, ListHashSet and HashCountedSet. On a HashCountedSet, add() adds one to the value's
// count and remove() takes one away, returning true when that removes the value.
template<typename Owner, typename Set, Set Owner::*member>
struct MemberHashSetOperations {
    using ValueType = typename Set::ValueType;

    // Returns whether the value was new.
    static bool add(Owner& owner, const ValueType& value)
    {
        RELEASE_ASSERT(Detail::SetValueValidity<Set>::isValid(value));
        return (owner.*member).add(value).isNewEntry;
    }

    static bool remove(Owner& owner, const ValueType& value)
    {
        RELEASE_ASSERT(Detail::SetValueValidity<Set>::isValid(value));
        return (owner.*member).remove(value);
    }

    static Vector<ValueType> copyValues(const Owner& owner) { return copyToVector(owner.*member); }
};

template<typename Owner, typename VectorType, VectorType Owner::*member>
struct MemberVectorOperations {
    using ValueType = typename VectorType::ValueType;

    static void append(Owner& owner, const ValueType& value) { (owner.*member).append(value); }

    // Appends the source's member to the owner's, as Vector::appendVector() does. The source may be the owner.
    static void appendAllFrom(Owner& owner, const Owner& source)
    {
        // Vector::appendVector() reads the source after reallocating, so a vector cannot append itself.
        if (std::addressof(owner) == std::addressof(source)) {
            auto copy = source.*member;
            (owner.*member).appendVector(WTF::move(copy));
            return;
        }
        (owner.*member).appendVector(source.*member);
    }
};

template<typename Owner, typename OptionalType, OptionalType Owner::*member>
struct MemberOptionalOperations {
    using ValueType = typename OptionalType::value_type;

    static void set(Owner& owner, const ValueType& value) { owner.*member = value; }
    static void reset(Owner& owner) { (owner.*member).reset(); }
};

} // namespace WTF

using WTF::MemberHashMapOperations;
using WTF::MemberHashSetOperations;
using WTF::MemberNestedHashMapOperations;
using WTF::MemberOptionalOperations;
using WTF::MemberVectorOperations;
