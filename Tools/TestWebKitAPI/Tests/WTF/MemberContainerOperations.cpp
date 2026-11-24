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
#include <wtf/MemberContainerOperations.h>

#include "Helpers/Test.h"
#include <wtf/HashCountedSet.h>
#include <wtf/HashMap.h>
#include <wtf/ListHashSet.h>
#include <wtf/RefCounted.h>
#include <wtf/WeakPtr.h>
#include <wtf/text/StringHash.h>
#include <wtf/text/WTFString.h>

namespace TestWebKitAPI {

class MemberContainerItem : public RefCounted<MemberContainerItem>, public CanMakeWeakPtr<MemberContainerItem> {
public:
    static Ref<MemberContainerItem> create(int value) { return adoptRef(*new MemberContainerItem(value)); }
    int value() const { return m_value; }

private:
    explicit MemberContainerItem(int value)
        : m_value(value)
    {
    }

    int m_value;
};

// Its HashTraits are declared on its hash (SimpleClassHashTraits<Hash>), not on the value.
struct MemberContainerObject {
    uint64_t identifier;
    bool isSuspended;
};

} // namespace TestWebKitAPI

namespace WTF {

struct MemberContainerObjectHash {
    static unsigned hash(const TestWebKitAPI::MemberContainerObject& object) { return DefaultHash<uint64_t>::hash(object.identifier); }
    static bool equal(const TestWebKitAPI::MemberContainerObject& a, const TestWebKitAPI::MemberContainerObject& b) { return a.identifier == b.identifier; }
    static constexpr bool safeToCompareToEmptyOrDeleted = true;
};

template<> struct HashTraits<TestWebKitAPI::MemberContainerObject> : SimpleClassHashTraits<MemberContainerObjectHash> { };
template<> struct DefaultHash<TestWebKitAPI::MemberContainerObject> : MemberContainerObjectHash { };

} // namespace WTF

namespace TestWebKitAPI {

class MemberContainerOwner {
    HashMap<String, Ref<MemberContainerItem>> m_items;
    HashMap<int, WeakRef<MemberContainerItem>> m_weakItems;
    HashMap<int, int> m_values;
    HashMap<int, HashMap<String, Vector<int>>> m_index;
    HashCountedSet<String> m_counts;
    ListHashSet<int> m_list;
    ListHashSet<MemberContainerObject> m_objects;
    Vector<int> m_vector;
    std::optional<int> m_optional;

public:
    using ItemsOperations = WTF::MemberHashMapOperations<MemberContainerOwner, decltype(m_items), &MemberContainerOwner::m_items>;
    using WeakItemsOperations = WTF::MemberHashMapOperations<MemberContainerOwner, decltype(m_weakItems), &MemberContainerOwner::m_weakItems>;
    using ValuesOperations = WTF::MemberHashMapOperations<MemberContainerOwner, decltype(m_values), &MemberContainerOwner::m_values>;
    using IndexOperations = WTF::MemberNestedHashMapOperations<MemberContainerOwner, decltype(m_index), &MemberContainerOwner::m_index>;
    using CountsOperations = WTF::MemberHashSetOperations<MemberContainerOwner, decltype(m_counts), &MemberContainerOwner::m_counts>;
    using ListOperations = WTF::MemberHashSetOperations<MemberContainerOwner, decltype(m_list), &MemberContainerOwner::m_list>;
    using ObjectsOperations = WTF::MemberHashSetOperations<MemberContainerOwner, decltype(m_objects), &MemberContainerOwner::m_objects>;
    using VectorOperations = WTF::MemberVectorOperations<MemberContainerOwner, decltype(m_vector), &MemberContainerOwner::m_vector>;
    using OptionalOperations = WTF::MemberOptionalOperations<MemberContainerOwner, decltype(m_optional), &MemberContainerOwner::m_optional>;

    const Vector<int>& vector() const { return m_vector; }
    const std::optional<int>& optional() const { return m_optional; }
};

TEST(WTF_MemberContainerOperations, HashMapOfRef)
{
    MemberContainerOwner owner;
    using Operations = MemberContainerOwner::ItemsOperations;
    Ref item = MemberContainerItem::create(1);

    EXPECT_FALSE(Operations::contains(owner, "a"_s));
    EXPECT_NULL(Operations::get(owner, "a"_s));
    EXPECT_TRUE(Operations::add(owner, "a"_s, item));
    EXPECT_FALSE(Operations::add(owner, "a"_s, MemberContainerItem::create(2)));
    EXPECT_EQ(Operations::get(owner, "a"_s), item.ptr());

    Operations::set(owner, "b"_s, MemberContainerItem::create(3));
    EXPECT_TRUE(Operations::contains(owner, "b"_s));
    {
        auto values = Operations::copyValues(owner);
        EXPECT_EQ(values.size(), 2u);
        EXPECT_EQ(values[0]->value() + values[1]->value(), 4);
    }

    EXPECT_TRUE(Operations::remove(owner, "a"_s));
    EXPECT_FALSE(Operations::remove(owner, "a"_s));
    EXPECT_EQ(item->refCount(), 1u);
}

TEST(WTF_MemberContainerOperations, HashMapOfWeakRefAndValues)
{
    MemberContainerOwner owner;
    using WeakOperations = MemberContainerOwner::WeakItemsOperations;
    {
        Ref item = MemberContainerItem::create(5);
        WeakOperations::add(owner, 1, item);
        EXPECT_EQ(WeakOperations::get(owner, 1), item.ptr());
        EXPECT_EQ(WeakOperations::copyValues(owner)[0]->value(), 5);
    }
    EXPECT_NULL(WeakOperations::get(owner, 1));

    using ValuesOperations = MemberContainerOwner::ValuesOperations;
    EXPECT_EQ(ValuesOperations::getOptional(owner, 1), std::nullopt);
    ValuesOperations::set(owner, 1, 7);
    EXPECT_EQ(ValuesOperations::get(owner, 1), 7);
    EXPECT_EQ(ValuesOperations::getOptional(owner, 1), 7);
}

TEST(WTF_MemberContainerOperations, NestedHashMap)
{
    MemberContainerOwner owner;
    using Operations = MemberContainerOwner::IndexOperations;

    Operations::appendTo(owner, 1, "a"_s, 10);
    Operations::appendTo(owner, 1, "a"_s, 10);
    Operations::appendTo(owner, 1, "b"_s, 20);
    Operations::appendTo(owner, 2, "a"_s, 10);
    EXPECT_TRUE(Operations::containsIn(owner, 1, "a"_s, 10));
    EXPECT_FALSE(Operations::containsIn(owner, 1, "a"_s, 20));
    EXPECT_FALSE(Operations::containsIn(owner, 3, "a"_s, 10));

    EXPECT_TRUE(Operations::removeFirstFrom(owner, 1, "a"_s, 10));
    EXPECT_TRUE(Operations::containsIn(owner, 1, "a"_s, 10));
    EXPECT_TRUE(Operations::removeFirstFrom(owner, 1, "a"_s, 10));
    EXPECT_FALSE(Operations::removeFirstFrom(owner, 1, "a"_s, 10));

    Operations::removeFirstFromAllAndPrune(owner, 10);
    EXPECT_FALSE(Operations::containsIn(owner, 2, "a"_s, 10));
    EXPECT_TRUE(Operations::containsIn(owner, 1, "b"_s, 20));
    Operations::removeFirstFromAllAndPrune(owner, 20);
    EXPECT_FALSE(Operations::containsIn(owner, 1, "b"_s, 20));
}

TEST(WTF_MemberContainerOperations, Sets)
{
    MemberContainerOwner owner;
    using CountsOperations = MemberContainerOwner::CountsOperations;
    EXPECT_TRUE(CountsOperations::add(owner, "a"_s));
    EXPECT_FALSE(CountsOperations::add(owner, "a"_s));
    EXPECT_FALSE(CountsOperations::remove(owner, "a"_s));
    EXPECT_TRUE(CountsOperations::remove(owner, "a"_s));
    EXPECT_FALSE(CountsOperations::remove(owner, "a"_s));

    using ListOperations = MemberContainerOwner::ListOperations;
    ListOperations::add(owner, 3);
    ListOperations::add(owner, 1);
    ListOperations::add(owner, 2);
    EXPECT_TRUE(ListOperations::remove(owner, 1));
    EXPECT_EQ(ListOperations::copyValues(owner), Vector<int>({ 3, 2 }));
}

TEST(WTF_MemberContainerOperations, ListHashSetWithTraitsOfTheHash)
{
    MemberContainerOwner owner;
    using Operations = MemberContainerOwner::ObjectsOperations;
    constexpr auto maximum = std::numeric_limits<uint64_t>::max();
    EXPECT_TRUE(Operations::add(owner, { 0, false }));
    EXPECT_TRUE(Operations::add(owner, { maximum, true }));
    EXPECT_FALSE(Operations::add(owner, { 0, true }));
    EXPECT_TRUE(Operations::remove(owner, { 0, true }));
    EXPECT_FALSE(Operations::remove(owner, { 0, false }));

    auto objects = Operations::copyValues(owner);
    EXPECT_EQ(objects.size(), 1u);
    EXPECT_EQ(objects[0].identifier, maximum);
    EXPECT_TRUE(objects[0].isSuspended);
}

TEST(WTF_MemberContainerOperations, VectorAndOptional)
{
    MemberContainerOwner owner;
    using VectorOperations = MemberContainerOwner::VectorOperations;
    VectorOperations::append(owner, 4);
    VectorOperations::append(owner, 5);
    EXPECT_EQ(owner.vector(), Vector<int>({ 4, 5 }));

    MemberContainerOwner other;
    VectorOperations::append(other, 6);
    VectorOperations::appendAllFrom(other, owner);
    EXPECT_EQ(other.vector(), Vector<int>({ 6, 4, 5 }));
    EXPECT_EQ(owner.vector(), Vector<int>({ 4, 5 }));
    VectorOperations::appendAllFrom(owner, owner);
    EXPECT_EQ(owner.vector(), Vector<int>({ 4, 5, 4, 5 }));

    MemberContainerOwner many;
    for (int i = 0; i < 10; ++i)
        VectorOperations::append(many, i);
    VectorOperations::appendAllFrom(many, many);
    EXPECT_EQ(many.vector(), Vector<int>({ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }));

    using OptionalOperations = MemberContainerOwner::OptionalOperations;
    OptionalOperations::set(owner, 6);
    EXPECT_EQ(owner.optional(), 6);
    OptionalOperations::reset(owner);
    EXPECT_EQ(owner.optional(), std::nullopt);
}

#if !PLATFORM(PLAYSTATION)
TEST(WTF_MemberContainerOperationsDeathTest, NullStringKey)
{
    MemberContainerOwner owner;
    ASSERT_DEATH_IF_SUPPORTED(MemberContainerOwner::ItemsOperations::contains(owner, String()), "");
    ASSERT_DEATH_IF_SUPPORTED(MemberContainerOwner::CountsOperations::add(owner, String()), "");
    ASSERT_DEATH_IF_SUPPORTED(MemberContainerOwner::IndexOperations::appendTo(owner, 1, String(), 10), "");
}
#endif

} // namespace TestWebKitAPI
