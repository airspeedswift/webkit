/*
 * Copyright (C) 2017 Caio Lima <ticaiolima@gmail.com>
 * Copyright (C) 2017-2024 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * Parts of the implementation below:
 *
 * Copyright 2017-2021 the V8 project authors. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE file.
 *
 *
 * Copyright (c) 2014 the Dart project authors.  Please see the AUTHORS file [1]
 * for details. All rights reserved. Use of this source code is governed by a
 * BSD-style license that can be found in the LICENSE file [2].
 *
 * [1] https://github.com/dart-lang/sdk/blob/master/AUTHORS
 * [2] https://github.com/dart-lang/sdk/blob/master/LICENSE
 *
 * Copyright 2009 The Go Authors. All rights reserved.
 * Use of this source code is governed by a BSD-style
 * license that can be found in the LICENSE file [3].
 *
 * [3] https://golang.org/LICENSE
 */

#include "config.h"
#include "JSBigInt.h"
#include "JSCJSValueBigInt.h"

#include "BigIntObject.h"
#include "JSCJSValueInlines.h"
#include "JSObjectInlines.h"
#include "MathCommon.h"
#include "ParseInt.h"
#include "StructureCreateInlines.h"
#include <algorithm>
#include <wtf/Hasher.h>
#include <wtf/Int128.h>
#include <wtf/MathExtras.h>

#include "JSBigIntSwiftDigits.h"
#include "JSCSwift-Swift.h"

WTF_ALLOW_UNSAFE_BUFFER_USAGE_BEGIN

namespace JSC {

const ClassInfo JSBigInt::s_info = { "BigInt"_s, nullptr, nullptr, nullptr, CREATE_METHOD_TABLE(JSBigInt) };

JSBigInt::JSBigInt(VM& vm, Structure* structure, unsigned length)
    : Base(vm, structure)
    , m_length(length)
{ }

void JSBigInt::initialize(InitializationType initType)
{
    if (initType == InitializationType::WithZero)
        zeroSpan(digits());
}

Structure* JSBigInt::createStructure(VM& vm, JSGlobalObject* globalObject, JSValue prototype)
{
    return Structure::create(vm, globalObject, prototype, TypeInfo(HeapBigIntType, StructureFlags), info());
}

inline JSBigInt* JSBigInt::createZero(VM& vm)
{
    JSBigInt* cached = vm.heapBigIntConstantZero.get();
    ASSERT(cached);
    return cached;
}

JSBigInt* JSBigInt::tryCreateZero(VM& vm)
{
    JSBigInt* cached = vm.heapBigIntConstantZero.get();
    ASSERT(cached);
    return cached;
}

inline JSBigInt* JSBigInt::createWithLength(JSGlobalObject* nullOrGlobalObjectForOOM, VM& vm, unsigned length)
{
    if (length > maxLength) [[unlikely]] {
        if (nullOrGlobalObjectForOOM) {
            auto scope = DECLARE_THROW_SCOPE(vm);
            throwOutOfMemoryError(nullOrGlobalObjectForOOM, scope, "BigInt generated from this operation is too big"_s);
        }
        return nullptr;
    }

    ASSERT(length <= maxLength);
    auto* cell = tryAllocateCell<JSBigInt>(vm, JSBigInt::allocationSize(length));
    if (!cell) [[unlikely]] {
        if (nullOrGlobalObjectForOOM) {
            auto scope = DECLARE_THROW_SCOPE(vm);
            throwOutOfMemoryError(nullOrGlobalObjectForOOM, scope);
        }
        return nullptr;
    }

    JSBigInt* bigInt = new (NotNull, cell) JSBigInt(vm, vm.bigIntStructure.get(), length);
    bigInt->finishCreation(vm);
    return bigInt;
}

JSBigInt* JSBigInt::tryCreateWithLength(VM& vm, unsigned length)
{
    return createWithLength(nullptr, vm, length);
}

JSBigInt* JSBigInt::createWithLength(JSGlobalObject* globalObject, unsigned length)
{
    return createWithLength(globalObject, globalObject->vm(), length);
}

inline JSBigInt* JSBigInt::createFrom(JSGlobalObject* nullOrGlobalObjectForOOM, VM& vm, int32_t value)
{
    if (!value)
        return createZero(vm);

    JSBigInt* bigInt = createWithLength(nullOrGlobalObjectForOOM, vm, 1);
    if (!bigInt) [[unlikely]]
        return nullptr;

    if (value < 0) {
        bigInt->setDigit(0, static_cast<Digit>(-1 * static_cast<int64_t>(value)));
        bigInt->setSign(true);
    } else
        bigInt->setDigit(0, static_cast<Digit>(value));

    return bigInt;
}

JSBigInt* JSBigInt::createFrom(JSGlobalObject* globalObject, int32_t value)
{
    return createFrom(globalObject, globalObject->vm(), value);
}

JSBigInt* JSBigInt::tryCreateFrom(VM& vm, int32_t value)
{
    return createFrom(nullptr, vm, value);
}

JSBigInt* JSBigInt::createFrom(JSGlobalObject* globalObject, uint32_t value)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!value)
        RELEASE_AND_RETURN(scope, createZero(vm));
    
    JSBigInt* bigInt = createWithLength(globalObject, 1);
    RETURN_IF_EXCEPTION(scope, nullptr);
    bigInt->setDigit(0, static_cast<Digit>(value));
    return bigInt;
}

inline JSBigInt* JSBigInt::tryCreateFromImpl(JSGlobalObject* globalObject, uint64_t value, bool sign)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!value)
        RELEASE_AND_RETURN(scope, createZero(vm));

    if (sizeof(Digit) == 8 || value <= UINT32_MAX) {
        JSBigInt* bigInt = createWithLength(globalObject, 1);
        RETURN_IF_EXCEPTION(scope, nullptr);
        bigInt->setDigit(0, static_cast<Digit>(value));
        bigInt->setSign(sign);
        return bigInt;
    }

    ASSERT(sizeof(Digit) == 4);
    JSBigInt* bigInt = createWithLength(globalObject, 2);
    RETURN_IF_EXCEPTION(scope, nullptr);
    Digit lowBits  = static_cast<Digit>(value & 0xffffffff);
    Digit highBits = static_cast<Digit>((value >> 32) & 0xffffffff);

    ASSERT(highBits);

    bigInt->setDigit(0, lowBits);
    bigInt->setDigit(1, highBits);
    bigInt->setSign(sign);

    return bigInt;
}

JSBigInt* JSBigInt::createFrom(JSGlobalObject* globalObject, uint64_t value)
{
    return tryCreateFromImpl(globalObject, value, false);
}

JSBigInt* JSBigInt::createFrom(JSGlobalObject* globalObject, int64_t value)
{
    uint64_t unsignedValue;
    bool sign = false;
    if (value < 0) {
        unsignedValue = static_cast<uint64_t>(-(value + 1)) + 1;
        sign = true;
    } else
        unsignedValue = value;
    return tryCreateFromImpl(globalObject, unsignedValue, sign);
}

JSBigInt* JSBigInt::createFrom(JSGlobalObject* globalObject, Int128 value)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!value)
        RELEASE_AND_RETURN(scope, createZero(vm));

    UInt128 unsignedValue;
    bool sign = false;
    if (value < 0) {
        unsignedValue = static_cast<UInt128>(-(value + 1)) + 1;
        sign = true;
    } else
        unsignedValue = value;

    if (unsignedValue <= UINT64_MAX)
        RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, static_cast<uint64_t>(unsignedValue), sign));

    if constexpr (sizeof(Digit) == 8) {
        JSBigInt* bigInt = createWithLength(globalObject, 2);
        RETURN_IF_EXCEPTION(scope, nullptr);

        Digit lowBits = static_cast<Digit>(static_cast<uint64_t>(unsignedValue));
        Digit highBits = static_cast<Digit>(static_cast<uint64_t>(unsignedValue >> 64));

        ASSERT(highBits);

        bigInt->setDigit(0, lowBits);
        bigInt->setDigit(1, highBits);
        bigInt->setSign(sign);
        return bigInt;
    }

    ASSERT(sizeof(Digit) == 4);

    Digit digit0 = static_cast<Digit>(static_cast<uint64_t>(unsignedValue));
    Digit digit1 = static_cast<Digit>(static_cast<uint64_t>(unsignedValue >> 32));
    Digit digit2 = static_cast<Digit>(static_cast<uint64_t>(unsignedValue >> 64));
    Digit digit3 = static_cast<Digit>(static_cast<uint64_t>(unsignedValue >> 96));

    ASSERT(digit2 || digit3);

    int length = digit3 ? 4 : 3;
    JSBigInt* bigInt = createWithLength(globalObject, length);
    RETURN_IF_EXCEPTION(scope, nullptr);

    bigInt->setDigit(0, digit0);
    bigInt->setDigit(1, digit1);
    bigInt->setDigit(2, digit2);
    if (digit3)
        bigInt->setDigit(3, digit3);
    bigInt->setSign(sign);
    return bigInt;
}

JSBigInt* JSBigInt::createFrom(JSGlobalObject* globalObject, bool value)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (!value)
        RELEASE_AND_RETURN(scope, createZero(vm));

    JSBigInt* bigInt = createWithLength(globalObject, 1);
    RETURN_IF_EXCEPTION(scope, nullptr);
    bigInt->setDigit(0, static_cast<Digit>(value));
    return bigInt;
}

JSBigInt* JSBigInt::createFrom(JSGlobalObject* globalObject, double value)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    ASSERT(isInteger(value));
    if (!value)
        RELEASE_AND_RETURN(scope, createZero(vm));

    bool sign = value < 0; // -0 was already handled above.
    uint64_t doubleBits = std::bit_cast<uint64_t>(value);
    int32_t rawExponent = static_cast<int32_t>(doubleBits >> doublePhysicalMantissaSize) & 0x7ff;
    // value is an integer, so rawExponent is neither below the bias (that would be a fraction) nor
    // the all-ones pattern that encodes infinity and NaN.
    RELEASE_ASSERT(rawExponent >= 0x3ff && rawExponent < 0x7ff);
    unsigned exponent = static_cast<unsigned>(rawExponent) - 0x3ff;
    size_t digits = exponent / digitBits + 1;
    Vector<Digit, 64> resultVector(FillWith { }, digits, 0);
    auto result = resultVector.mutableSpan();

    // We construct a BigInt from the double value by shifting its mantissa
    // according to its exponent and mapping the bit pattern onto digits.
    //
    //               <----------- bitlength = exponent + 1 ----------->
    //                <----- 52 ------> <------ trailing zeroes ------>
    // mantissa:     1yyyyyyyyyyyyyyyyy 0000000000000000000000000000000
    // digits:    0001xxxx xxxxxxxx xxxxxxxx xxxxxxxx xxxxxxxx xxxxxxxx
    //                <-->          <------>
    //           msdTopBit         digitBits
    //

    uint64_t mantissa = (doubleBits & doublePhysicalMantissaMask) | doubleMantissaHiddenBit;

    int32_t mantissaTopBit = doubleMantissaSize - 1; // 0-indexed.
    // 0-indexed position of most significant bit in the most significant digit.
    int32_t msdTopBit = static_cast<int32_t>(exponent % digitBits);
    // Number of unused bits in mantissa. We'll keep them shifted to the
    // left (i.e. most significant part) of the underlying uint64_t.
    int32_t remainingMantissaBits = 0;
    // Next digit under construction.
    Digit digit = 0;

    // First, build the MSD by shifting the mantissa appropriately.
    if (msdTopBit < mantissaTopBit) {
        remainingMantissaBits = mantissaTopBit - msdTopBit;
        digit = static_cast<Digit>(mantissa >> remainingMantissaBits);
        mantissa = mantissa << (64 - remainingMantissaBits);
    } else {
        ASSERT(msdTopBit >= mantissaTopBit);
        digit = static_cast<Digit>(mantissa << (msdTopBit - mantissaTopBit));
        mantissa = 0;
    }
    result[digits - 1] = digit;
    // Then fill in the rest of the digits.
    for (size_t digitIndex = digits - 1; digitIndex-- > 0;) {
        if (remainingMantissaBits > 0) {
            remainingMantissaBits -= digitBits;
            if constexpr (sizeof(Digit) == 4) {
                digit = mantissa >> 32;
                mantissa = mantissa << 32;
            } else {
                ASSERT(sizeof(Digit) == 8);
                digit = mantissa;
                mantissa = 0;
            }
        } else
            digit = 0;
        result[digitIndex] = digit;
    }
    RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, sign, result));
}

JSValue JSBigInt::toPrimitive(JSGlobalObject*, PreferredPrimitiveType) const
{
    return const_cast<JSBigInt*>(this);
}

unsigned JSBigInt::bitLength() const
{
    if (isZero())
        return 1;
    return m_length * digitBits - clz(digit(m_length - 1));
}

JSValue JSBigInt::parseInt(JSGlobalObject* globalObject, StringView s, ErrorParseMode parserMode)
{
    if (s.is8Bit())
        return parseInt(globalObject, s.span8(), parserMode);
    return parseInt(globalObject, s.span16(), parserMode);
}

JSValue JSBigInt::parseInt(JSGlobalObject* nullOrGlobalObjectForOOM, VM& vm, StringView s, uint8_t radix, ErrorParseMode parserMode, ParseIntSign sign)
{
    if (s.is8Bit())
        return parseInt(nullOrGlobalObjectForOOM, vm, s.span8(), 0, radix, parserMode, sign, ParseIntMode::DisallowEmptyString);
    return parseInt(nullOrGlobalObjectForOOM, vm, s.span16(), 0, radix, parserMode, sign, ParseIntMode::DisallowEmptyString);
}

JSValue JSBigInt::stringToBigInt(JSGlobalObject* globalObject, StringView s)
{
    return parseInt(globalObject, s, ErrorParseMode::IgnoreExceptions);
}

String JSBigInt::toString(JSGlobalObject* globalObject, unsigned radix)
{
    if (this->isZero())
        return globalObject->vm().smallStrings.singleCharacterStringRep('0');

    if (hasOneBitSet(radix))
        return toStringBasePowerOfTwo(globalObject->vm(), globalObject, this, radix);

    return toStringGeneric(globalObject->vm(), globalObject, this, radix);
}

String JSBigInt::tryGetString(VM& vm, JSBigInt* bigInt, unsigned radix)
{
    if (bigInt->isZero())
        return vm.smallStrings.singleCharacterStringRep('0');

    if (hasOneBitSet(radix))
        return toStringBasePowerOfTwo(vm, nullptr, bigInt, radix);

    return toStringGeneric(vm, nullptr, bigInt, radix);
}

class HeapBigIntImpl {
public:
    explicit HeapBigIntImpl(JSBigInt* bigInt)
        : m_bigInt(bigInt)
    { }

    ALWAYS_INLINE bool isZero() { return m_bigInt->isZero(); }
    ALWAYS_INLINE bool sign() { return m_bigInt->sign(); }
    ALWAYS_INLINE unsigned length() { return m_bigInt->length(); }
    ALWAYS_INLINE JSBigInt::Digit digit(unsigned i) { return m_bigInt->digit(i); }
    ALWAYS_INLINE std::span<const JSBigInt::Digit> digits() { return { m_bigInt->dataStorage(), m_bigInt->length() }; }
    ALWAYS_INLINE JSBigInt* toHeapBigInt(JSGlobalObject*, VM&) { return m_bigInt; }
    ALWAYS_INLINE JSBigInt* toHeapBigInt(JSGlobalObject*) { return m_bigInt; }

private:
    friend struct JSBigInt::ImplResult;
    JSBigInt* m_bigInt;
};

template<typename D>
NODELETE static std::span<D> normalize(std::span<D> x)
{
    while (!x.empty() && !x.back())
        x = x.first(x.size() - 1);
    return x;
}

class Int32BigIntImpl {
public:
    explicit Int32BigIntImpl(int32_t value)
        : m_value(value)
    {
        if (!isZero())
            m_digit = digit(0);
    }

    ALWAYS_INLINE bool isZero() { return !m_value; }
    ALWAYS_INLINE bool sign() { return m_value < 0; }
    ALWAYS_INLINE unsigned length() { return isZero() ? 0 : 1; }
    ALWAYS_INLINE JSBigInt::Digit digit(unsigned i)
    {
        ASSERT(length());
        ASSERT_UNUSED(i, i == 0);
        if (sign())
            return static_cast<JSBigInt::Digit>(WTF::negate(static_cast<int64_t>(m_value)));
        return m_value;
    }

    ALWAYS_INLINE std::span<const JSBigInt::Digit> digits() { return { &m_digit, length() }; }

    ALWAYS_INLINE JSBigInt* toHeapBigInt(JSGlobalObject* nullOrGlobalObjectForOOM, VM& vm)
    {
        return JSBigInt::createFrom(nullOrGlobalObjectForOOM, vm, m_value);
    }

    ALWAYS_INLINE JSBigInt* toHeapBigInt(JSGlobalObject* globalObject)
    {
        return JSBigInt::createFrom(globalObject, m_value);
    }

private:
    friend struct JSBigInt::ImplResult;
    int32_t m_value;
    JSBigInt::Digit m_digit { };
};

class Int64BigIntImpl {
public:
    static constexpr unsigned numDigits = isRegister64Bit() ? 1 : 2;

    explicit Int64BigIntImpl(int64_t value)
        : m_value(value)
        , m_sign(value < 0)
    {
#if CPU(REGISTER64)
        if (!isZero())
            m_digits[0] = digit(0);
#else
        for (unsigned i = 0; i < length(); ++i)
            m_digits[i] = digit(i);
#endif
    }

    explicit Int64BigIntImpl(uint64_t value)
        : m_value(value)
        , m_sign(false)
    {
#if CPU(REGISTER64)
        if (!isZero())
            m_digits[0] = digit(0);
#else
        for (unsigned i = 0; i < length(); ++i)
            m_digits[i] = digit(i);
#endif
    }

    ALWAYS_INLINE bool isZero() { return !m_value; }
    ALWAYS_INLINE bool sign() { return m_sign; }
    ALWAYS_INLINE unsigned length() { return isZero() ? 0 : numDigits; }
    ALWAYS_INLINE JSBigInt::Digit digit(unsigned i)
    {
        ASSERT_UNUSED(i, i < length());
#if CPU(REGISTER64)
        if (sign())
            return static_cast<JSBigInt::Digit>(WTF::negate(static_cast<int64_t>(m_value)));
        return m_value;
#else
        static_assert(sizeof(JSBigInt::Digit) == 4);
        if (sign())
            return static_cast<JSBigInt::Digit>(WTF::negate(static_cast<int64_t>(m_value)) >> (32 * i));
        return static_cast<JSBigInt::Digit>(m_value >> (32 * i));
#endif
    }

    ALWAYS_INLINE std::span<const JSBigInt::Digit> digits() { return { m_digits, length() }; }

private:
    friend struct JSBigInt::ImplResult;
    uint64_t m_value;
    JSBigInt::Digit m_digits[numDigits] { };
    bool m_sign;
};

ALWAYS_INLINE JSBigInt::ImplResult::ImplResult(HeapBigIntImpl& heapImpl)
    : payload(heapImpl.m_bigInt)
{ }

ALWAYS_INLINE JSBigInt::ImplResult::ImplResult(JSBigInt* heapBigInt)
    : payload(heapBigInt)
{ }

ALWAYS_INLINE JSBigInt::ImplResult::ImplResult(JSValue value)
    : payload(value)
{ }

static ALWAYS_INLINE JSBigInt::ImplResult zeroImpl(VM& vm)
{
    return vm.heapBigIntConstantZero.get();
}

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ImplResult JSBigInt::exponentiateImpl(JSGlobalObject* globalObject, BigIntImpl1 base, BigIntImpl2 exponent)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (exponent.sign()) {
        throwRangeError(globalObject, scope, "Negative exponent is not allowed"_s);
        return nullptr;
    }

    // 2. If base is 0n and exponent is 0n, return 1n.
    if (exponent.isZero())
        RELEASE_AND_RETURN(scope, JSBigInt::createFrom(globalObject, 1));
    
    // 3. Return a BigInt representing the mathematical value of base raised
    //    to the power exponent.
    if (base.isZero())
        return { base };

    if (base.length() == 1 && base.digit(0) == 1) {
        // (-1) ** even_number == 1.
        if (base.sign() && !(exponent.digit(0) & 1))
            RELEASE_AND_RETURN(scope, JSBigInt::unaryMinusImpl(globalObject, base));

        // (-1) ** odd_number == -1; 1 ** anything == 1.
        return { base };
    }

    // For all bases >= 2, very large exponents would lead to unrepresentable
    // results.
    static_assert(maxLengthBits < std::numeric_limits<Digit>::max(), "maxLengthBits needs to be less than digit::max()");
    if (exponent.length() > 1) {
        throwOutOfMemoryError(globalObject, scope, "BigInt generated from this operation is too big"_s);
        return nullptr;
    }

    Digit expValue = exponent.digit(0);
    if (expValue == 1)
        return { base };
    if (expValue >= maxLengthBits) {
        throwOutOfMemoryError(globalObject, scope, "BigInt generated from this operation is too big"_s);
        return nullptr;
    }

    static_assert(maxLengthBits <= maxInt, "maxLengthBits needs to be <= maxInt");
    int n = static_cast<int>(expValue);
    if (base.length() == 1 && base.digit(0) == 2) {
        // Fast path for 2^n.
        int neededDigits = 1 + (n / digitBits);

        Vector<Digit, 16> resultVector(FillWith { }, neededDigits, 0);
        auto result = resultVector.mutableSpan();

        // All bits are zero. Now set the n-th bit.
        Digit msd = static_cast<Digit>(1) << (n % digitBits);
        result[neededDigits - 1] = msd;

        // Result is negative for odd powers of -2n.
        bool sign = false;
        if (base.sign()) 
            sign = static_cast<bool>(n & 1);
        RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, sign, result));
    }

    JSBigInt* result = nullptr;
    JSBigInt* runningSquare = base.toHeapBigInt(globalObject);
    RETURN_IF_EXCEPTION(scope, nullptr);

    // This implicitly sets the result's sign correctly.
    if (n & 1) {
        result = base.toHeapBigInt(globalObject);
        RETURN_IF_EXCEPTION(scope, nullptr);
    }

    n >>= 1;
    for (; n; n >>= 1) {
        ImplResult temp = JSBigInt::multiplyImpl(globalObject, HeapBigIntImpl { runningSquare }, HeapBigIntImpl { runningSquare });
        RETURN_IF_EXCEPTION(scope, nullptr);
        ASSERT(temp.payload);
        ASSERT(temp.payload.isHeapBigInt());
        JSBigInt* maybeResult = temp.payload.asHeapBigInt();
        runningSquare = maybeResult;
        if (n & 1) {
            if (!result)
                result = runningSquare;
            else {
                temp = JSBigInt::multiplyImpl(globalObject, HeapBigIntImpl { result }, HeapBigIntImpl { runningSquare });
                RETURN_IF_EXCEPTION(scope, nullptr);
                ASSERT(temp.payload);
                ASSERT(temp.payload.isHeapBigInt());
                maybeResult = temp.payload.asHeapBigInt();
                result = maybeResult;
            }
        }
    }

    return { result };
}

JSValue JSBigInt::exponentiate(JSGlobalObject* globalObject, JSBigInt* base, JSBigInt* exponent)
{
    return exponentiateImpl(globalObject, HeapBigIntImpl { base }, HeapBigIntImpl { exponent }).payload;
}

#if CPU(REGISTER64)
using TwoDigit = UInt128;
#else
using TwoDigit = uint64_t;
#endif

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ImplResult JSBigInt::multiplyImpl(JSGlobalObject* globalObject, BigIntImpl1 x, BigIntImpl2 y)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (x.length() < y.length())
        RELEASE_AND_RETURN(scope, multiplyImpl(globalObject, y, x));

    ASSERT(x.length() >= y.length());

    if (y.isZero())
        return { y };

    unsigned resultLength = x.length() + y.length();
    bool resultSign = x.sign() != y.sign();

    if (y.length() == 1) {
        if (y.digit(0) == 1) {
            if (resultSign == x.sign())
                return { x };
            RELEASE_AND_RETURN(scope, JSBigInt::unaryMinusImpl(globalObject, x));
        }
    }

    // N * M result with non-zero digits N / M is guaranteed to be (N + M - 1) or (N + M) length.
    // It is not so wasteful if we just allocate JSBigInt with N + M here.
    // It is possible that we will hit the JSBigInt size limit, so let's validate it after all the computation.
    if (resultLength - 1 > maxLength) [[unlikely]] {
        throwOutOfMemoryError(globalObject, scope, "BigInt generated from this operation is too big"_s);
        return nullptr;
    }

    auto xSpan = x.digits();
    auto ySpan = y.digits();
    ASSERT(xSpan.size() >= 1);
    ASSERT(ySpan.size() >= 1);

    // Note that resultLength can be one-larger than maxLength.
    // We still accept. And if the adjusted result is still larger, we will throw an OOM error.
    auto* cell = tryAllocateCell<JSBigInt>(vm, JSBigInt::allocationSize(resultLength));
    if (!cell) [[unlikely]] {
        throwOutOfMemoryError(globalObject, scope, "BigInt generated from this operation is too big"_s);
        return nullptr;
    }

    JSBigInt* bigInt = new (NotNull, cell) JSBigInt(vm, vm.bigIntStructure.get(), resultLength);
    bigInt->finishCreation(vm);
    bigInt->setSign(resultSign);

    bool isSquare = xSpan.data() == ySpan.data() && xSpan.size() == ySpan.size();
    std::span<Digit> result = bigInt->digits().first(JSCSwift::jsBigIntMultiplyDigits(xSpan, isSquare ? std::span<const Digit> { } : ySpan, isSquare, bigInt->digits()));
    ASSERT(!result.empty());
    if (!result.back())
        result = result.first(result.size() - 1);

    if (result.size() > maxLength) [[unlikely]] {
        throwOutOfMemoryError(globalObject, scope, "BigInt generated from this operation is too big"_s);
        return nullptr;
    }
    bigInt->setLength(result.size());

    return bigInt;
}

JSValue JSBigInt::multiply(JSGlobalObject* globalObject, JSBigInt* x, JSBigInt* y)
{
    return multiplyImpl(globalObject, HeapBigIntImpl { x }, HeapBigIntImpl { y }).payload;
}

// Computes Q(uotient) and remainder for A/b, such that
// Q = (A - remainder) / b, with 0 <= remainder < b.
// If Q.len == 0, only the remainder will be returned.
// Q may be the same as A for an in-place division.
std::span<JSBigInt::Digit> JSBigInt::divideSingle(std::span<Digit> q, Digit& remainder, std::span<const Digit> a, Digit b)
{
    size_t quotientLength = a.back() >= b ? a.size() : a.size() - 1;
    if (q.data() == a.data())
        remainder = JSCSwift::jsBigIntDivideSingleInPlace(q.first(a.size()), b);
    else
        remainder = JSCSwift::jsBigIntDivideSingle(q, a, b);
    return q.empty() ? q : q.first(quotientLength);
}

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ImplResult JSBigInt::divideImpl(JSGlobalObject* globalObject, BigIntImpl1 x, BigIntImpl2 y)
{
    // 1. If y is 0n, throw a RangeError exception.
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (y.isZero()) {
        throwRangeError(globalObject, scope, "0 is an invalid divisor value."_s);
        return nullptr;
    }

    // 2. Let quotient be the mathematical value of x divided by y.
    // 3. Return a BigInt representing quotient rounded towards 0 to the next
    //    integral value.
    bool resultSign = x.sign() != y.sign();
    switch (absoluteCompare(x, y)) {
    case ComparisonResult::LessThan: {
        RELEASE_AND_RETURN(scope, zeroImpl(vm));
    }
    case ComparisonResult::Equal: {
        RELEASE_AND_RETURN(scope, createFrom(globalObject, vm, resultSign ? -1 : 1));
    }
    case ComparisonResult::GreaterThan:
    case ComparisonResult::Undefined:
        break;
    }

    auto xSpan = x.digits();
    auto ySpan = y.digits();
    size_t qLength = xSpan.size() - ySpan.size() + 1;
    if (ySpan.size() == 1) {
        Digit divisor = ySpan[0];
        if (divisor == 1) {
            if (resultSign == x.sign())
                return JSBigInt::ImplResult { x };
            RELEASE_AND_RETURN(scope, JSBigInt::unaryMinusImpl(globalObject, x));
        }

        Vector<Digit, 16> q(qLength);
        Digit remainder;
        RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, resultSign, divideSingle(q.mutableSpan(), remainder, xSpan, divisor)));
    }

    if (xSpan.size() == ySpan.size()) {
        auto quotientDigit = JSCSwift::jsBigIntDivideSameSize(xSpan, ySpan);
        if (!quotientDigit)
            RELEASE_AND_RETURN(scope, zeroImpl(vm));

        auto* quotient = createWithLength(globalObject, 1);
        RETURN_IF_EXCEPTION(scope, nullptr);

        quotient->setDigit(0, quotientDigit);
        quotient->setSign(resultSign);
        return quotient;
    }

    Vector<Digit, 16> q(qLength);
    // JSBigIntDigits*.swift copies these constants.
    static_assert(maxLength == 16384 && digitBits == 64 && halfDigitBits == 32);
    auto qSpan = q.mutableSpan().first(JSCSwift::jsBigIntDivideDigits(q.mutableSpan(), { }, xSpan, ySpan));
    RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, resultSign, qSpan));
}

JSValue JSBigInt::divide(JSGlobalObject* globalObject, JSBigInt* x, JSBigInt* y)
{
    return divideImpl(globalObject, HeapBigIntImpl { x }, HeapBigIntImpl { y }).payload;
}

template <typename BigIntImpl>
JSBigInt* JSBigInt::copy(JSGlobalObject* globalObject, BigIntImpl x)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    ASSERT(!x.isZero());

    JSBigInt* result = createWithLength(globalObject, x.length());
    RETURN_IF_EXCEPTION(scope, nullptr);
    memcpySpan(result->digits(), x.digits());
    result->setSign(x.sign());
    return result;
}

template <typename BigIntImpl>
JSBigInt::ImplResult JSBigInt::unaryMinusImpl(JSGlobalObject* globalObject, BigIntImpl x)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (x.isZero())
        RELEASE_AND_RETURN(scope, zeroImpl(vm));

    JSBigInt* result = copy(globalObject, x);
    RETURN_IF_EXCEPTION(scope, nullptr);

    result->setSign(!x.sign());
    return result;
}

JSValue JSBigInt::unaryMinus(JSGlobalObject* globalObject, JSBigInt* x)
{
    return unaryMinusImpl(globalObject, HeapBigIntImpl { x }).payload;
}

// https://tc39.es/proposal-bigint-math/#sec-bigint.sqrt
JSValue JSBigInt::sqrt(JSGlobalObject* globalObject, JSBigInt* bigInt)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    ASSERT(!bigInt->sign());

    if (bigInt->isZero())
        RELEASE_AND_RETURN(scope, bigInt);

    auto value = bigInt->digits();
    Vector<Digit, 16> resultStorage(value.size() + 2);
    auto result = resultStorage.mutableSpan().first(JSCSwift::jsBigIntSqrtDigits(value, resultStorage.mutableSpan()));

    RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, false, result));
}

// https://tc39.es/proposal-bigint-math/#sec-bigint.cbrt
JSValue JSBigInt::cbrt(JSGlobalObject* globalObject, JSBigInt* bigInt)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (bigInt->isZero())
        RELEASE_AND_RETURN(scope, bigInt);

    bool sign = bigInt->sign();
    auto value = bigInt->digits();
    Vector<Digit, 16> resultStorage(value.size() + 2);
    auto result = resultStorage.mutableSpan().first(JSCSwift::jsBigIntCbrtDigits(value, resultStorage.mutableSpan()));

    RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, sign, result));
}

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ImplResult JSBigInt::remainderImpl(JSGlobalObject* globalObject, BigIntImpl1 x, BigIntImpl2 y)
{
    // 1. If y is 0n, throw a RangeError exception.
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (y.isZero()) {
        throwRangeError(globalObject, scope, "0 is an invalid divisor value."_s);
        return nullptr;
    }

    // 2. Return the JSBigInt representing x modulo y.
    // See https://github.com/tc39/proposal-bigint/issues/84 though.
    switch (absoluteCompare(x, y)) {
    case ComparisonResult::LessThan: {
        return { x };
    }
    case ComparisonResult::Equal: {
        RELEASE_AND_RETURN(scope, zeroImpl(vm));
    }
    case ComparisonResult::GreaterThan:
    case ComparisonResult::Undefined:
        break;
    }

    auto xSpan = x.digits();
    auto ySpan = y.digits();
    if (ySpan.size() == 1) {
        Digit divisor = ySpan[0];
        if (divisor == 1)
            RELEASE_AND_RETURN(scope, zeroImpl(vm));

        Digit remainderDigit;
        divideSingle({ }, remainderDigit, xSpan, divisor);
        if (!remainderDigit)
            RELEASE_AND_RETURN(scope, zeroImpl(vm));

        auto* remainder = createWithLength(globalObject, 1);
        RETURN_IF_EXCEPTION(scope, nullptr);

        remainder->setDigit(0, remainderDigit);
        remainder->setSign(x.sign());
        return remainder;
    }

    // Cached multiplicative inverse optimization for repeated modulo with the same divisor.
    if constexpr (std::is_same_v<BigIntImpl2, HeapBigIntImpl>) {
        if (vm.m_cachedBigIntDivisor.get() == y.toHeapBigInt(globalObject)) {
            if (xSpan.size() <= 2 * ySpan.size()) {
                unsigned resultLength = ySpan.size();
                if (resultLength <= maxInPlaceCachedModSize) {
                    auto* cell = tryAllocateCell<JSBigInt>(vm, JSBigInt::allocationSize(resultLength));
                    if (!cell) [[unlikely]] {
                        throwOutOfMemoryError(globalObject, scope);
                        return nullptr;
                    }
                    JSBigInt* bigInt = new (NotNull, cell) JSBigInt(vm, vm.bigIntStructure.get(), resultLength);
                    bigInt->finishCreation(vm);
                    bigInt->setSign(x.sign());
                    // JSBigIntDigits*.swift copies these constants.
                    static_assert(maxCachedModDivisorSize == 32 && maxFixedCachedModDivisorSize == 4);
                    auto rSpan = normalize(bigInt->digits().first(JSCSwift::jsBigIntCachedMod(bigInt->digits(), xSpan, ySpan, vm.m_bigIntFoldFactor, vm.m_bigIntCachedInverse.span())));
                    if (rSpan.empty())
                        RELEASE_AND_RETURN(scope, zeroImpl(vm));
                    bigInt->setLength(rSpan.size());
                    return bigInt;
                }
                Vector<Digit, maxCachedModDivisorSize> r(resultLength);
                auto rSpan = r.mutableSpan().first(JSCSwift::jsBigIntCachedMod(r.mutableSpan(), xSpan, ySpan, vm.m_bigIntFoldFactor, vm.m_bigIntCachedInverse.span()));
                RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, x.sign(), rSpan));
            }
        } else if (vm.m_nextCachedBigIntDivisor.get() == y.toHeapBigInt(globalObject)) {
            if (++vm.m_bigIntDivisorCount >= 100) {
                vm.m_cachedBigIntDivisor.setWithoutWriteBarrier(y.toHeapBigInt(globalObject));
                vm.m_bigIntFoldFactor = JSCSwift::jsBigIntCachedModFoldFactor(ySpan);
                if (!vm.m_bigIntFoldFactor) {
                    vm.m_bigIntCachedInverse.resize(ySpan.size() + 1);
                    JSCSwift::jsBigIntCachedModMakeInverse(ySpan, vm.m_bigIntCachedInverse.mutableSpan());
                }
            }
        } else if (ySpan.size() >= 2 && ySpan.size() <= maxCachedModDivisorSize) {
            vm.m_nextCachedBigIntDivisor.setWithoutWriteBarrier(y.toHeapBigInt(globalObject));
            vm.m_bigIntDivisorCount = 1;
        }
    }

    Vector<Digit, 16> r(ySpan.size());
    std::span<const Digit> rSpan;
    if (xSpan.size() == ySpan.size())
        rSpan = r.mutableSpan().first(JSCSwift::jsBigIntRemainderSameSize(r.mutableSpan(), xSpan, ySpan));
    else
        rSpan = r.mutableSpan().first(JSCSwift::jsBigIntDivideDigits({ }, r.mutableSpan(), xSpan, ySpan));
    RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, x.sign(), rSpan));
}

JSValue JSBigInt::remainder(JSGlobalObject* globalObject, JSBigInt* x, JSBigInt* y)
{
    return remainderImpl(globalObject, HeapBigIntImpl { x }, HeapBigIntImpl { y }).payload;
}

JSBigInt::ImplResult JSBigInt::absoluteAddOne(JSGlobalObject* globalObject, std::span<const Digit> x, bool resultSign)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    unsigned resultLength = addOneLength(x);
    if (resultLength > maxLength) [[unlikely]] {
        Vector<Digit> scratch(resultLength);
        auto result = absoluteAddOne(x, scratch.mutableSpan());
        RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, resultSign, result));
    }

    auto* cell = tryAllocateCell<JSBigInt>(vm, JSBigInt::allocationSize(resultLength));
    if (!cell) [[unlikely]] {
        throwOutOfMemoryError(globalObject, scope);
        return nullptr;
    }

    JSBigInt* bigInt = new (NotNull, cell) JSBigInt(vm, vm.bigIntStructure.get(), resultLength);
    bigInt->finishCreation(vm);
    bigInt->setSign(resultSign);

    auto span = absoluteAddOne(x, bigInt->digits());
    ASSERT(!span.empty());
    ASSERT(span.back());
    if (span.size() < resultLength)
        bigInt->setLength(span.size());
    return bigInt;
}

JSBigInt::ImplResult JSBigInt::absoluteSubOne(JSGlobalObject* globalObject, std::span<const Digit> x, bool resultSign)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    ASSERT(!x.empty());
    unsigned resultLength = subOneLength(x);
    auto* cell = tryAllocateCell<JSBigInt>(vm, JSBigInt::allocationSize(resultLength));
    if (!cell) [[unlikely]] {
        throwOutOfMemoryError(globalObject, scope);
        return nullptr;
    }

    JSBigInt* bigInt = new (NotNull, cell) JSBigInt(vm, vm.bigIntStructure.get(), resultLength);
    bigInt->finishCreation(vm);
    bigInt->setSign(resultSign);

    auto span = normalize(absoluteSubOne(x, bigInt->digits()));
    if (span.empty())
        RELEASE_AND_RETURN(scope, zeroImpl(vm));
    if (span.size() < resultLength)
        bigInt->setLength(span.size());
    return bigInt;
}

template <typename BigIntImpl>
JSBigInt::ImplResult JSBigInt::incImpl(JSGlobalObject* globalObject, BigIntImpl x)
{
    auto xSpan = x.digits();
    if (!x.sign())
        return absoluteAddOne(globalObject, xSpan, false);
    return absoluteSubOne(globalObject, xSpan, true);
}

JSValue JSBigInt::inc(JSGlobalObject* globalObject, JSBigInt* x)
{
    return incImpl(globalObject, HeapBigIntImpl { x }).payload;
}

template <typename BigIntImpl>
JSBigInt::ImplResult JSBigInt::decImpl(JSGlobalObject* globalObject, BigIntImpl x)
{
    if (x.isZero())
        return createFrom(globalObject, -1);

    auto xSpan = x.digits();
    if (!x.sign())
        return absoluteSubOne(globalObject, xSpan, false);
    return absoluteAddOne(globalObject, xSpan, true);
}

JSValue JSBigInt::dec(JSGlobalObject* globalObject, JSBigInt* x)
{
    return decImpl(globalObject, HeapBigIntImpl { x }).payload;
}

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ImplResult JSBigInt::addImpl(JSGlobalObject* globalObject, BigIntImpl1 x, BigIntImpl2 y)
{
    bool xSign = x.sign();

    // x + y == x + y
    // -x + -y == -(x + y)
    if (xSign == y.sign())
        return absoluteAdd(globalObject, x, y, xSign);

    // x + -y == x - y == -(y - x)
    // -x + y == y - x == -(x - y)
    ComparisonResult comparisonResult = absoluteCompare(x, y);
    if (comparisonResult == ComparisonResult::Equal)
        return zeroImpl(globalObject->vm());
    if (comparisonResult == ComparisonResult::GreaterThan)
        return absoluteSub(globalObject, x, y, xSign);

    return absoluteSub(globalObject, y, x, !xSign);
}
JSValue JSBigInt::add(JSGlobalObject* globalObject, JSBigInt* x, JSBigInt* y)
{
    return addImpl(globalObject, HeapBigIntImpl { x }, HeapBigIntImpl { y }).payload;
}

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ImplResult JSBigInt::subImpl(JSGlobalObject* globalObject, BigIntImpl1 x, BigIntImpl2 y)
{
    bool xSign = x.sign();
    if (xSign != y.sign()) {
        // x - (-y) == x + y
        // (-x) - y == -(x + y)
        return absoluteAdd(globalObject, x, y, xSign);
    }
    // x - y == -(y - x)
    // (-x) - (-y) == y - x == -(x - y)
    ComparisonResult comparisonResult = absoluteCompare(x, y);
    if (comparisonResult == ComparisonResult::Equal)
        return zeroImpl(globalObject->vm());
    if (comparisonResult == ComparisonResult::GreaterThan)
        return absoluteSub(globalObject, x, y, xSign);

    return absoluteSub(globalObject, y, x, !xSign);
}

JSValue JSBigInt::sub(JSGlobalObject* globalObject, JSBigInt* x, JSBigInt* y)
{
    return subImpl(globalObject, HeapBigIntImpl { x }, HeapBigIntImpl { y }).payload;
}

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ImplResult JSBigInt::bitwiseAndImpl(JSGlobalObject* globalObject, BigIntImpl1 x, BigIntImpl2 y)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto xSpan = x.digits();
    auto ySpan = y.digits();
    if (!x.sign() && !y.sign()) {
        Vector<Digit, 16> resultVector(andLength(xSpan, ySpan));
        RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, false, absoluteAnd(xSpan, ySpan, resultVector.mutableSpan())));
    }

    if (x.sign() && y.sign()) {
        // (-x) & (-y) == ~(x-1) & ~(y-1) == ~((x-1) | (y-1))
        // == -(((x-1) | (y-1)) + 1)
        Vector<Digit, 16> resultXVector(subOneLength(xSpan));
        auto resultX = normalize(absoluteSubOne(xSpan, resultXVector.mutableSpan()));

        Vector<Digit, 16> resultYVector(subOneLength(ySpan));
        auto resultY = normalize(absoluteSubOne(ySpan, resultYVector.mutableSpan()));

        Vector<Digit, 16> resultVector(orLength(resultX, resultY));
        auto result = normalize(absoluteOr(resultX, resultY, resultVector.mutableSpan()));

        Vector<Digit, 16> finalResultVector(addOneLength(result));
        auto finalResult = absoluteAddOne(result, finalResultVector.mutableSpan());

        RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, true, finalResult));
    }

    ASSERT(x.sign() != y.sign());
    // x & (-y) == x & ~(y-1)
    auto computeResult = [&] (auto x, auto y) -> JSBigInt* {
        ASSERT(!x.sign()); 
        ASSERT(y.sign()); 
        auto xSpan = x.digits();
        auto ySpan = y.digits();
        Vector<Digit, 16> resultYVector(subOneLength(ySpan));
        auto resultY = normalize(absoluteSubOne(ySpan, resultYVector.mutableSpan()));

        Vector<Digit, 16> resultVector(andNotLength(xSpan, resultY));
        RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, false, absoluteAndNot(xSpan, resultY, resultVector.mutableSpan())));
    };
    if (x.sign())
        return computeResult(y, x);
    return computeResult(x, y);
}

JSValue JSBigInt::bitwiseAnd(JSGlobalObject* globalObject, JSBigInt* x, JSBigInt* y)
{
    return bitwiseAndImpl(globalObject, HeapBigIntImpl { x }, HeapBigIntImpl { y }).payload;
}

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ImplResult JSBigInt::bitwiseOrImpl(JSGlobalObject* globalObject, BigIntImpl1 x, BigIntImpl2 y)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto xSpan = x.digits();
    auto ySpan = y.digits();
    if (!x.sign() && !y.sign()) {
        Vector<Digit, 16> resultVector(orLength(xSpan, ySpan));
        RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, false, absoluteOr(xSpan, ySpan, resultVector.mutableSpan())));
    }
    
    if (x.sign() && y.sign()) {
        // (-x) | (-y) == ~(x-1) | ~(y-1) == ~((x-1) & (y-1))
        // == -(((x-1) & (y-1)) + 1)
        Vector<Digit, 16> resultXVector(subOneLength(xSpan));
        auto resultX = normalize(absoluteSubOne(xSpan, resultXVector.mutableSpan()));

        Vector<Digit, 16> resultYVector(subOneLength(ySpan));
        auto resultY = normalize(absoluteSubOne(ySpan, resultYVector.mutableSpan()));

        Vector<Digit, 16> resultVector(andLength(resultX, resultY));
        auto result = normalize(absoluteAnd(resultX, resultY, resultVector.mutableSpan()));

        Vector<Digit, 16> finalResultVector(addOneLength(result));
        auto finalResult = absoluteAddOne(result, finalResultVector.mutableSpan());

        RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, true, finalResult));
    }

    ASSERT(x.sign() != y.sign());

    // x | (-y) == x | ~(y-1) == ~((y-1) &~ x) == -(((y-1) &~ x) + 1)
    auto computeResult = [&] (auto x, auto y) -> JSBigInt* {
        ASSERT(!x.sign());
        ASSERT(y.sign());

        auto xSpan = x.digits();
        auto ySpan = y.digits();
        Vector<Digit, 16> resultYVector(subOneLength(ySpan));
        auto resultY = normalize(absoluteSubOne(ySpan, resultYVector.mutableSpan()));

        Vector<Digit, 16> resultVector(andNotLength(resultY, xSpan));
        auto result = normalize(absoluteAndNot(resultY, xSpan, resultVector.mutableSpan()));

        Vector<Digit, 16> finalResultVector(addOneLength(result));
        auto finalResult = absoluteAddOne(result, finalResultVector.mutableSpan());

        RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, true, finalResult));
    };

    if (x.sign())
        return computeResult(y, x);
    return computeResult(x, y);
}

JSValue JSBigInt::bitwiseOr(JSGlobalObject* globalObject, JSBigInt* x, JSBigInt* y)
{
    return bitwiseOrImpl(globalObject, HeapBigIntImpl { x }, HeapBigIntImpl { y }).payload;
}

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ImplResult JSBigInt::bitwiseXorImpl(JSGlobalObject* globalObject, BigIntImpl1 x, BigIntImpl2 y)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto xSpan = x.digits();
    auto ySpan = y.digits();
    if (!x.sign() && !y.sign()) {
        Vector<Digit, 16> resultVector(xorLength(xSpan, ySpan));
        RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, false, absoluteXor(xSpan, ySpan, resultVector.mutableSpan())));
    }

    if (x.sign() && y.sign()) {
        // (-x) ^ (-y) == ~(x-1) ^ ~(y-1) == (x-1) ^ (y-1)
        Vector<Digit, 16> resultXVector(subOneLength(xSpan));
        auto resultX = normalize(absoluteSubOne(xSpan, resultXVector.mutableSpan()));

        Vector<Digit, 16> resultYVector(subOneLength(ySpan));
        auto resultY = normalize(absoluteSubOne(ySpan, resultYVector.mutableSpan()));

        Vector<Digit, 16> resultVector(xorLength(resultX, resultY));
        RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, false, absoluteXor(resultX, resultY, resultVector.mutableSpan())));
    }
    ASSERT(x.sign() != y.sign());

    // x ^ (-y) == x ^ ~(y-1) == ~(x ^ (y-1)) == -((x ^ (y-1)) + 1)
    auto computeResult = [&] (auto x, auto y) -> JSBigInt* {
        ASSERT(!x.sign());
        ASSERT(y.sign());

        auto xSpan = x.digits();
        auto ySpan = y.digits();
        Vector<Digit, 16> resultYVector(subOneLength(ySpan));
        auto resultY = normalize(absoluteSubOne(ySpan, resultYVector.mutableSpan()));

        Vector<Digit, 16> resultVector(xorLength(resultY, xSpan));
        auto result = normalize(absoluteXor(resultY, xSpan, resultVector.mutableSpan()));

        Vector<Digit, 16> finalResultVector(addOneLength(result));
        auto finalResult = absoluteAddOne(result, finalResultVector.mutableSpan());

        RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, true, finalResult));
    };

    // Assume that x is the positive BigInt.
    if (x.sign())
        return computeResult(y, x);
    return computeResult(x, y);
}

JSValue JSBigInt::bitwiseXor(JSGlobalObject* globalObject, JSBigInt* x, JSBigInt* y)
{
    return bitwiseXorImpl(globalObject, HeapBigIntImpl { x }, HeapBigIntImpl { y }).payload;
}

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ImplResult JSBigInt::leftShiftImpl(JSGlobalObject* globalObject, BigIntImpl1 x, BigIntImpl2 y)
{
    if (x.isZero() || y.isZero())
        return { x };

    if (y.sign())
        return rightShiftByAbsolute(globalObject, x, y);

    return leftShiftByAbsolute(globalObject, x, y);
}

JSValue JSBigInt::leftShift(JSGlobalObject* globalObject, JSBigInt* x, JSBigInt* y)
{
    return leftShiftImpl(globalObject, HeapBigIntImpl { x }, HeapBigIntImpl { y }).payload;
}

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ImplResult JSBigInt::signedRightShiftImpl(JSGlobalObject* globalObject, BigIntImpl1 x, BigIntImpl2 y)
{
    if (x.isZero() || y.isZero())
        return { x };

    if (y.sign())
        return leftShiftByAbsolute(globalObject, x, y);

    return rightShiftByAbsolute(globalObject, x, y);
}

JSValue JSBigInt::signedRightShift(JSGlobalObject* globalObject, JSBigInt* x, JSBigInt* y)
{
    return signedRightShiftImpl(globalObject, HeapBigIntImpl { x }, HeapBigIntImpl { y }).payload;
}

template <typename BigIntImpl>
JSBigInt::ImplResult JSBigInt::bitwiseNotImpl(JSGlobalObject* globalObject, BigIntImpl x)
{
    VM& vm = globalObject->vm();
    auto xSpan = x.digits();
    if (x.sign()) {
        // ~(-x) == ~(~(x-1)) == x-1
        Vector<Digit, 16> resultVector(subOneLength(xSpan));
        return tryCreateFromImpl(globalObject, vm, false, absoluteSubOne(xSpan, resultVector.mutableSpan()));
    } 
    // ~x == -x-1 == -(x+1)
    Vector<Digit, 16> resultVector(addOneLength(xSpan));
    auto result = absoluteAddOne(xSpan, resultVector.mutableSpan());
    return tryCreateFromImpl(globalObject, vm, true, result);
}

JSValue JSBigInt::bitwiseNot(JSGlobalObject* globalObject, JSBigInt* x)
{
    return bitwiseNotImpl(globalObject, HeapBigIntImpl { x }).payload;
}

// {borrow} must point to an initialized Digit and will either be incremented
// by one or left alone.
inline JSBigInt::Digit JSBigInt::digitSub(Digit a, Digit b, Digit& borrow)
{
    auto result = static_cast<TwoDigit>(a) - b;
    borrow += static_cast<Digit>(result >> static_cast<int>(digitBits)) & 1;
    return static_cast<Digit>(result);
}

// Raises {base} to the power of {exponent}. Does not check for overflow.
inline JSBigInt::Digit JSBigInt::digitPow(Digit base, Digit exponent)
{
    Digit result = 1ull;
    while (exponent > 0) {
        if (exponent & 1)
            result *= base;

        exponent >>= 1;
        base *= base;
    }

    return result;
}

bool JSBigInt::equals(JSBigInt* x, JSBigInt* y)
{
    if (x->sign() != y->sign())
        return false;

    if (x->length() != y->length())
        return false;

    for (unsigned i = 0; i < x->length(); i++) {
        if (x->digit(i) != y->digit(i))
            return false;
    }

    return true;
}

template <typename BigIntImpl1, typename BigIntImpl2>
inline JSBigInt::ComparisonResult JSBigInt::absoluteCompare(BigIntImpl1 x, BigIntImpl2 y)
{
    ASSERT(!x.length() || x.digit(x.length() - 1));
    ASSERT(!y.length() || y.digit(y.length() - 1));

    int diff = x.length() - y.length();
    if (diff)
        return diff < 0 ? ComparisonResult::LessThan : ComparisonResult::GreaterThan;

    int i = x.length() - 1;
    while (i >= 0 && x.digit(i) == y.digit(i))
        i--;

    if (i < 0)
        return ComparisonResult::Equal;

    return x.digit(i) > y.digit(i) ? ComparisonResult::GreaterThan : ComparisonResult::LessThan;
}

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ComparisonResult JSBigInt::compareImpl(BigIntImpl1 x, BigIntImpl2 y)
{
    bool xSign = x.sign();

    if (xSign != y.sign())
        return xSign ? ComparisonResult::LessThan : ComparisonResult::GreaterThan;

    ComparisonResult result = absoluteCompare(x, y);
    if (result == ComparisonResult::GreaterThan)
        return xSign ? ComparisonResult::LessThan : ComparisonResult::GreaterThan;
    if (result == ComparisonResult::LessThan)
        return xSign ? ComparisonResult::GreaterThan : ComparisonResult::LessThan;

    return ComparisonResult::Equal; 
}

JSBigInt::ComparisonResult JSBigInt::compare(JSBigInt* x, JSBigInt* y)
{
    return compareImpl(HeapBigIntImpl { x }, HeapBigIntImpl { y });
}

JSBigInt::ComparisonResult JSBigInt::compare(int32_t x, JSBigInt* y)
{
    return compareImpl(Int32BigIntImpl { x }, HeapBigIntImpl { y });
}

JSBigInt::ComparisonResult JSBigInt::compare(JSBigInt* x, int32_t y)
{
    return compareImpl(HeapBigIntImpl { x }, Int32BigIntImpl { y });
}

JSBigInt::ComparisonResult JSBigInt::compare(JSBigInt* x, int64_t y)
{
    return compareImpl(HeapBigIntImpl { x }, Int64BigIntImpl { y });
}

JSBigInt::ComparisonResult JSBigInt::compare(JSValue x, int64_t y)
{
    ASSERT(x.isBigInt());
    return compare(x.asHeapBigInt(), y);
}

JSBigInt::ComparisonResult JSBigInt::compare(JSBigInt* x, uint64_t y)
{
    return compareImpl(HeapBigIntImpl { x }, Int64BigIntImpl { y });
}

JSBigInt::ComparisonResult JSBigInt::compare(JSValue x, uint64_t y)
{
    ASSERT(x.isBigInt());
    return compare(x.asHeapBigInt(), y);
}

JSBigInt::ComparisonResult JSBigInt::compare(JSValue x, JSValue y)
{
    ASSERT(x.isBigInt() && y.isBigInt());
    return compare(x.asHeapBigInt(), y.asHeapBigInt());
}

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ImplResult JSBigInt::absoluteAdd(JSGlobalObject* globalObject, BigIntImpl1 x, BigIntImpl2 y, bool resultSign)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (x.length() < y.length())
        RELEASE_AND_RETURN(scope, absoluteAdd(globalObject, y, x, resultSign));

    if (x.isZero()) {
        ASSERT(y.isZero());
        return { x };
    }

    if (y.isZero()) {
        if (resultSign == x.sign())
            return { x };
        RELEASE_AND_RETURN(scope, unaryMinusImpl(globalObject, x));
    }

    unsigned resultLength = x.length() + 1;
    if (resultLength > maxLength) [[unlikely]] {
        Vector<Digit> scratch(resultLength);
        auto span = scratch.mutableSpan().first(JSCSwift::jsBigIntAddDigits(x.digits(), y.digits(), scratch.mutableSpan()));
        RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, resultSign, span));
    }

    auto* cell = tryAllocateCell<JSBigInt>(vm, JSBigInt::allocationSize(resultLength));
    if (!cell) [[unlikely]] {
        throwOutOfMemoryError(globalObject, scope);
        return nullptr;
    }

    JSBigInt* bigInt = new (NotNull, cell) JSBigInt(vm, vm.bigIntStructure.get(), resultLength);
    bigInt->finishCreation(vm);
    bigInt->setSign(resultSign);

    auto span = bigInt->digits().first(JSCSwift::jsBigIntAddDigits(x.digits(), y.digits(), bigInt->digits()));
    ASSERT(!span.empty());
    if (!span.back())
        bigInt->setLength(span.size() - 1);

    return bigInt;
}

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ImplResult JSBigInt::absoluteSub(JSGlobalObject* globalObject, BigIntImpl1 x, BigIntImpl2 y, bool resultSign)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    // Callers fold the equal case into zero, so |x| > |y| here and neither x nor the difference is
    // zero.
    ASSERT(absoluteCompare(x, y) == ComparisonResult::GreaterThan);
    ASSERT(!x.isZero());

    if (y.isZero()) {
        if (resultSign == x.sign())
            return ImplResult { x };
        RELEASE_AND_RETURN(scope, JSBigInt::unaryMinusImpl(globalObject, x));
    }

    unsigned resultLength = x.length();
    if (resultLength > maxInPlaceSubSize) [[unlikely]] {
        Vector<Digit> scratch(resultLength);
        auto span = scratch.mutableSpan().first(JSCSwift::jsBigIntSubDigits(x.digits(), y.digits(), scratch.mutableSpan()));
        RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, resultSign, span));
    }

    auto* cell = tryAllocateCell<JSBigInt>(vm, JSBigInt::allocationSize(resultLength));
    if (!cell) [[unlikely]] {
        throwOutOfMemoryError(globalObject, scope);
        return nullptr;
    }

    JSBigInt* bigInt = new (NotNull, cell) JSBigInt(vm, vm.bigIntStructure.get(), resultLength);
    bigInt->finishCreation(vm);
    bigInt->setSign(resultSign);

    auto span = normalize(bigInt->digits().first(JSCSwift::jsBigIntSubDigits(x.digits(), y.digits(), bigInt->digits())));
    ASSERT(!span.empty());
    bigInt->setLength(span.size());
    return bigInt;
}

std::span<JSBigInt::Digit> JSBigInt::absoluteAnd(std::span<const Digit> x, std::span<const Digit> y, std::span<Digit> result)
{
    return result.first(JSCSwift::jsBigIntAndDigits(x, y, result));
}

std::span<JSBigInt::Digit> JSBigInt::absoluteOr(std::span<const Digit> x, std::span<const Digit> y, std::span<Digit> result)
{
    return result.first(JSCSwift::jsBigIntOrDigits(x, y, result));
}

std::span<JSBigInt::Digit> JSBigInt::absoluteAndNot(std::span<const Digit> x, std::span<const Digit> y, std::span<Digit> result)
{
    return result.first(JSCSwift::jsBigIntAndNotDigits(x, y, result));
}

std::span<JSBigInt::Digit> JSBigInt::absoluteXor(std::span<const Digit> x, std::span<const Digit> y, std::span<Digit> result)
{
    return result.first(JSCSwift::jsBigIntXorDigits(x, y, result));
}

std::span<JSBigInt::Digit> JSBigInt::absoluteAddOne(std::span<const Digit> x, std::span<Digit> result)
{
    return result.first(JSCSwift::jsBigIntAddOneDigits(x, result));
}

std::span<JSBigInt::Digit> JSBigInt::absoluteSubOne(std::span<const Digit> x, std::span<Digit> result)
{
    return result.first(JSCSwift::jsBigIntSubOneDigits(x, result));
}

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ImplResult JSBigInt::leftShiftByAbsolute(JSGlobalObject* globalObject, BigIntImpl1 x, BigIntImpl2 y)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto optionalShift = toShiftAmount(y);
    if (!optionalShift) {
        throwOutOfMemoryError(globalObject, scope, "BigInt generated from this operation is too big"_s);
        return nullptr;
    }

    Digit shift = *optionalShift;
    size_t digitShift = static_cast<size_t>(shift / digitBits);
    size_t bitsShift = static_cast<size_t>(shift % digitBits);
    auto xSpan = x.digits();
    size_t length = xSpan.size();
    bool grow = bitsShift && (xSpan[length - 1] >> (digitBits - bitsShift));
    size_t resultLength = length + digitShift + grow;
    if (resultLength > maxLength) {
        throwOutOfMemoryError(globalObject, scope, "BigInt generated from this operation is too big"_s);
        return nullptr;
    }

    Vector<Digit, 16> resultVector(resultLength);
    auto result = resultVector.mutableSpan();
    RELEASE_ASSERT(result.size() == resultLength);
    JSCSwift::jsBigIntShiftLeftDigits(xSpan, digitShift, bitsShift, result);

    RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, x.sign(), result));
}

template <typename BigIntImpl1, typename BigIntImpl2>
JSBigInt::ImplResult JSBigInt::rightShiftByAbsolute(JSGlobalObject* globalObject, BigIntImpl1 x, BigIntImpl2 y)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto xSpan = x.digits();
    size_t length = xSpan.size();
    bool sign = x.sign();
    auto optionalShift = toShiftAmount(y);
    if (!optionalShift)
        RELEASE_AND_RETURN(scope, rightShiftByMaximum(globalObject, sign));

    Digit shift = *optionalShift;
    size_t digitalShift = static_cast<size_t>(shift / digitBits);
    size_t bitsShift = static_cast<size_t>(shift % digitBits);
    if (length <= digitalShift)
        RELEASE_AND_RETURN(scope, rightShiftByMaximum(globalObject, sign));

    size_t resultLength = length - digitalShift;

    // For negative numbers, round down if any bit was shifted out (so that e.g.
    // -5n >> 1n == -3n and not -2n). Check now whether this will happen and
    // whether it can cause overflow into a new digit. If we allocate the result
    // large enough up front, it avoids having to do a second allocation later.
    bool mustRoundDown = false;
    if (sign) {
        const Digit mask = (static_cast<Digit>(1) << bitsShift) - 1;
        if (xSpan[digitalShift] & mask)
            mustRoundDown = true;
        else {
            for (size_t i = 0; i < digitalShift; i++) {
                if (xSpan[i]) {
                    mustRoundDown = true;
                    break;
                }
            }
        }
    }

    // If bitsShift is non-zero, it frees up bits, preventing overflow.
    if (mustRoundDown && !bitsShift) {
        // Overflow cannot happen if the most significant digit has unset bits.
        Digit msd = xSpan[length - 1];
        bool roundingCanOverflow = !static_cast<Digit>(~msd);
        if (roundingCanOverflow)
            resultLength++;
    }

    ASSERT(resultLength <= length);
    Vector<Digit, 16> resultVector(resultLength);
    auto result = resultVector.mutableSpan();
    RELEASE_ASSERT(result.size() == resultLength);
    RELEASE_ASSERT(resultLength >= 1);

    JSCSwift::jsBigIntShiftRightDigits(xSpan, digitalShift, bitsShift, mustRoundDown, result);

    RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, sign, result));
}

JSBigInt::ImplResult JSBigInt::rightShiftByMaximum(JSGlobalObject* globalObject, bool sign)
{
    if (sign)
        return createFrom(globalObject, -1);

    return createZero(globalObject->vm());
}

// Lookup table for the maximum number of bits required per character of a
// base-N string representation of a number. To increase accuracy, the array
// value is the actual value multiplied by 32. To generate this table:
// for (var i = 0; i <= 36; i++) { print(Math.ceil(Math.log2(i) * 32) + ","); }
constexpr auto maxBitsPerCharTable = WTF::toArray<uint8_t>({
    0,   0,   32,  51,  64,  75,  83,  90,  96, // 0..8
    102, 107, 111, 115, 119, 122, 126, 128,     // 9..16
    131, 134, 136, 139, 141, 143, 145, 147,     // 17..24
    149, 151, 153, 154, 156, 158, 159, 160,     // 25..32
    162, 163, 165, 166,                         // 33..36
});

static constexpr unsigned bitsPerCharTableShift = 5;
static constexpr size_t bitsPerCharTableMultiplier = 1u << bitsPerCharTableShift;

// Compute (an overapproximation of) the length of the resulting string:
// Divide bit length of the BigInt by bits representable per character.
uint64_t JSBigInt::calculateMaximumCharactersRequired(unsigned length, unsigned radix, Digit lastDigit, bool sign)
{
    unsigned leadingZeros = clz(lastDigit);

    size_t bitLength = length * digitBits - leadingZeros;

    // Maximum number of bits we can represent with one character. We'll use this
    // to find an appropriate chunk size below.
    uint8_t maxBitsPerChar = maxBitsPerCharTable[radix];

    // For estimating result length, we have to be pessimistic and work with
    // the minimum number of bits one character can represent.
    uint8_t minBitsPerChar = maxBitsPerChar - 1;

    // Perform the following computation with uint64_t to avoid overflows.
    uint64_t maximumCharactersRequired = bitLength;
    maximumCharactersRequired *= bitsPerCharTableMultiplier;

    // Round up.
    maximumCharactersRequired += minBitsPerChar - 1;
    maximumCharactersRequired /= minBitsPerChar;
    maximumCharactersRequired += sign;
    
    return maximumCharactersRequired;
}

String JSBigInt::toStringBasePowerOfTwo(VM& vm, JSGlobalObject* nullOrGlobalObjectForOOM, JSBigInt* x, unsigned radix)
{
    ASSERT(hasOneBitSet(radix));
    ASSERT(radix >= 2 && radix <= 32);
    ASSERT(!x->isZero());

    const unsigned length = x->length();
    const bool sign = x->sign();
    const unsigned bitsPerChar = ctz(radix);
    const unsigned charMask = radix - 1;
    // Compute the length of the resulting string: divide the bit length of the
    // BigInt by the number of bits representable per character (rounding up).
    const Digit msd = x->digit(length - 1);

    const unsigned msdLeadingZeros = clz(msd);

    const size_t bitLength = length * digitBits - msdLeadingZeros;
    const size_t charsRequired = (bitLength + bitsPerChar - 1) / bitsPerChar + sign;

    if (charsRequired > JSString::MaxLength) {
        if (nullOrGlobalObjectForOOM) {
            auto scope = DECLARE_THROW_SCOPE(vm);
            throwOutOfMemoryError(nullOrGlobalObjectForOOM, scope);
        }
        return String();
    }

    Vector<Latin1Character> resultString(charsRequired);
    Digit digit = 0;
    // Keeps track of how many unprocessed bits there are in {digit}.
    unsigned availableBits = 0;
    int pos = static_cast<int>(charsRequired - 1);
    for (unsigned i = 0; i < length - 1; i++) {
        Digit newDigit = x->digit(i);
        // Take any leftover bits from the last iteration into account.
        int current = (digit | (newDigit << availableBits)) & charMask;
        resultString[pos--] = radixDigits[current];
        int consumedBits = bitsPerChar - availableBits;
        digit = newDigit >> consumedBits;
        availableBits = digitBits - consumedBits;
        while (availableBits >= bitsPerChar) {
            resultString[pos--] = radixDigits[digit & charMask];
            digit >>= bitsPerChar;
            availableBits -= bitsPerChar;
        }
    }
    // Take any leftover bits from the last iteration into account.
    int current = (digit | (msd << availableBits)) & charMask;
    resultString[pos--] = radixDigits[current];
    digit = msd >> (bitsPerChar - availableBits);
    while (digit) {
        resultString[pos--] = radixDigits[digit & charMask];
        digit >>= bitsPerChar;
    }

    if (sign)
        resultString[pos--] = '-';

    ASSERT(pos == -1);
    return StringImpl::adopt(WTF::move(resultString));
}

// Divide-and-conquer conversion to string, ported from V8 [1]. The divisor of a level is the square
// of the divisor of the level below, so a division splits a chunk into two halves that produce the
// same number of characters.
//
// [1]: https://source.chromium.org/chromium/chromium/src/+/main:v8/src/bigint/tostring.cc
static constexpr size_t toStringDivideAndConquerThreshold = 12;

class JSBigInt::ToStringFormatter {
    WTF_MAKE_NONCOPYABLE(ToStringFormatter);
public:
    ToStringFormatter(unsigned radix, std::span<const Digit>, std::span<Latin1Character> out);

    size_t format() { return format(m_divisors.size(), m_digits, m_out.size(), m_scratch); }

private:
    size_t format(size_t depth, std::span<const Digit> chunk, size_t position, std::span<Digit> scratch);

    unsigned m_radix;
    size_t m_chunkChars;
    std::span<const Digit> m_digits;
    std::span<Latin1Character> m_out;
    Vector<Digit, 128> m_storage;
    Vector<std::span<const Digit>, 16> m_divisors;
    std::span<Digit> m_scratch;
};


JSBigInt::ComparisonResult JSBigInt::compareDigits(std::span<const Digit> x, std::span<const Digit> y)
{
    x = normalize(x);
    y = normalize(y);
    if (x.size() != y.size())
        return x.size() < y.size() ? ComparisonResult::LessThan : ComparisonResult::GreaterThan;
    for (size_t i = x.size(); i-- > 0;) {
        if (x[i] != y[i])
            return x[i] < y[i] ? ComparisonResult::LessThan : ComparisonResult::GreaterThan;
    }
    return ComparisonResult::Equal;
}

std::span<JSBigInt::Digit> JSBigInt::multiplyDigits(std::span<const Digit> x, std::span<const Digit> y, std::span<Digit> result)
{
    x = normalize(x);
    y = normalize(y);
    if (x.empty() || y.empty())
        return { };
    if (x.size() < y.size())
        std::swap(x, y);
    RELEASE_ASSERT(result.size() >= x.size() + y.size());
    bool isSquare = x.data() == y.data() && x.size() == y.size();
    return normalize(result.first(JSCSwift::jsBigIntMultiplyDigits(x, isSquare ? std::span<const Digit> { } : y, isSquare, result)));
}

std::tuple<std::span<JSBigInt::Digit>, std::span<JSBigInt::Digit>> JSBigInt::divideDigitsInto(std::span<Digit> q, std::span<Digit> r, std::span<const Digit> a, std::span<const Digit> b)
{
    RELEASE_ASSERT(b.size() >= 2);
    RELEASE_ASSERT(a.size() >= b.size());
    RELEASE_ASSERT(q.empty() || q.size() > a.size() - b.size());
    RELEASE_ASSERT(r.empty() || r.size() >= b.size());
    // JSBigIntDigits*.swift copies these constants.
    static_assert(maxLength == 16384 && digitBits == 64 && halfDigitBits == 32);
    size_t counts = JSCSwift::jsBigIntDivideDigitsInto(q, r, a, b);
    return { q.first(counts >> 32), r.first(counts & 0xffffffff) };
}

JSBigInt::ToStringFormatter::ToStringFormatter(unsigned radix, std::span<const Digit> digits, std::span<Latin1Character> out)
    : m_radix(radix)
    , m_chunkChars(digitBits * bitsPerCharTableMultiplier / maxBitsPerCharTable[radix])
    , m_digits(digits)
    , m_out(out)
{
    auto bitLength = [](std::span<const Digit> x) {
        return x.size() * digitBits - clz(x.back());
    };
    Vector<size_t, 16> sizes;
    sizes.append(1);
    m_storage.append(digitPow(radix, m_chunkChars));
    while (bitLength(m_storage.span().last(sizes.last())) * 2 - 1 <= bitLength(digits)) {
        size_t end = m_storage.size();
        m_storage.grow(end + sizes.last() * 2);
        auto storage = m_storage.mutableSpan();
        auto divisor = storage.subspan(end - sizes.last(), sizes.last());
        sizes.append(multiplyDigits(divisor, divisor, storage.subspan(end)).size());
        m_storage.shrink(end + sizes.last());
    }
    m_storage.grow(m_storage.size() * 2 + digits.size() + sizes.size() + 1);
    m_scratch = m_storage.mutableSpan();
    for (size_t size : sizes)
        m_divisors.constructAndAppend(consumeSpan(m_scratch, size));
}

size_t JSBigInt::ToStringFormatter::format(size_t depth, std::span<const Digit> chunk, size_t position, std::span<Digit> scratch)
{
    chunk = normalize(chunk);
    if (chunk.size() < toStringDivideAndConquerThreshold) {
        auto rest = scratch.first(chunk.size());
        while (chunk.size() > 1) {
            Digit remainder;
            chunk = normalize(divideSingle(rest, remainder, chunk, m_divisors[0][0]));
            for (size_t i = 0; i < m_chunkChars; ++i, remainder /= m_radix)
                m_out[--position] = radixDigits[remainder % m_radix];
        }
        for (Digit digit = chunk.empty() ? 0 : chunk[0]; digit; digit /= m_radix)
            m_out[--position] = radixDigits[digit % m_radix];
        return position;
    }

    auto divisor = m_divisors[depth - 1];
    if (compareDigits(chunk, divisor) == ComparisonResult::LessThan)
        return format(depth - 1, chunk, position, scratch);

    size_t chars = m_chunkChars << (depth - 1);
    size_t trailingZeroDigits = chars * ctz(m_radix) / digitBits;
    auto quotientStorage = consumeSpan(scratch, chunk.size() - divisor.size() + 1);
    auto remainderStorage = consumeSpan(scratch, divisor.size());
    memcpySpan(remainderStorage, chunk.first(trailingZeroDigits));
    auto [quotient, remainder] = divideDigitsInto(quotientStorage, remainderStorage.subspan(trailingZeroDigits), chunk.subspan(trailingZeroDigits), divisor.subspan(trailingZeroDigits));

    size_t start = position - chars;
    position = format(depth - 1, remainderStorage.first(trailingZeroDigits + remainder.size()), position, scratch);
    memsetSpan(m_out.subspan(start, position - start), '0');
    return format(depth - 1, quotient, start, scratch);
}

String JSBigInt::toStringGeneric(VM& vm, JSGlobalObject* nullOrGlobalObjectForOOM, JSBigInt* x, unsigned radix)
{
    // FIXME: [JSC] Revisit usage of Vector into JSBigInt::toString
    // https://bugs.webkit.org/show_bug.cgi?id=180671
    Vector<Latin1Character> resultString;

    RELEASE_ASSERT(radix >= 2 && radix <= 36);
    ASSERT(!x->isZero());

    unsigned length = x->length();
    bool sign = x->sign();

    uint8_t maxBitsPerChar = maxBitsPerCharTable[radix];
    uint64_t maximumCharactersRequired = calculateMaximumCharactersRequired(length, radix, x->digit(length - 1), sign);

    if (maximumCharactersRequired > JSString::MaxLength) {
        if (nullOrGlobalObjectForOOM) {
            auto scope = DECLARE_THROW_SCOPE(vm);
            throwOutOfMemoryError(nullOrGlobalObjectForOOM, scope);
        }
        return String();
    }

    if (length >= toStringDivideAndConquerThreshold) {
        resultString.grow(maximumCharactersRequired);
        ToStringFormatter formatter(radix, x->digits(), resultString.mutableSpan());
        size_t start = formatter.format();
        if (sign)
            resultString[--start] = '-';
        return StringImpl::create(resultString.span().subspan(start));
    }

    Digit lastDigit;
    if (length == 1)
        lastDigit = x->digit(0);
    else {
        unsigned chunkChars = digitBits * bitsPerCharTableMultiplier / maxBitsPerChar;
        Digit chunkDivisor = digitPow(radix, chunkChars);

        // By construction of chunkChars, there can't have been overflow.
        ASSERT(chunkDivisor);

        // {rest} holds the part of the BigInt that we haven't looked at yet.
        // Not to be confused with "remainder"!
        // In the first round, divide the input, allocating a new BigInt for
        // the result == rest; from then on divide the rest in-place.
        Vector<Digit, 16> rest(length);
        std::span<const Digit> dividend = x->digits();
        do {
            Digit chunk;
            std::span<Digit> quotient = divideSingle(rest.mutableSpan(), chunk, dividend, chunkDivisor);

            for (unsigned i = 0; i < chunkChars; i++) {
                resultString.append(radixDigits[chunk % radix]);
                chunk /= radix;
            }
            ASSERT(!chunk);

            // Update dividend to point to the quotient for next iteration.
            // The quotient.size() tells us how many digits are non-zero.
            dividend = normalize(quotient);
        } while (dividend.size() > 1);

        lastDigit = dividend.empty() ? 0 : dividend[0];
    }

    do {
        resultString.append(radixDigits[lastDigit % radix]);
        lastDigit /= radix;
    } while (lastDigit > 0);
    ASSERT(resultString.size());
    ASSERT(resultString.size() <= static_cast<size_t>(maximumCharactersRequired));

    {
        // Remove leading zeroes; the characters are still least-significant-first, so they trail.
        auto characters = resultString.span();
        while (characters.size() > 1 && characters.back() == '0')
            characters = characters.first(characters.size() - 1);
        resultString.shrink(characters.size());
    }

    if (sign)
        resultString.append('-');

    std::ranges::reverse(resultString);

    return StringImpl::adopt(WTF::move(resultString));
}

double JSBigInt::toNumber(JSGlobalObject* globalObject) const
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    throwTypeError(globalObject, scope, "Conversion from 'BigInt' to 'number' is not allowed."_s);
    return 0.0;
}

template <typename CharType>
JSValue JSBigInt::parseInt(JSGlobalObject* globalObject, std::span<const CharType> data, ErrorParseMode errorParseMode)
{
    VM& vm = globalObject->vm();

    size_t p = 0;
    while (p < data.size() && isStrWhiteSpace(data[p]))
        ++p;

    // Check Radix from first characters
    if (p + 1 < data.size() && data[p] == '0') {
        if (isASCIIAlphaCaselessEqual(data[p + 1], 'b'))
            return parseInt(globalObject, vm, data, p + 2, 2, errorParseMode, ParseIntSign::Unsigned, ParseIntMode::DisallowEmptyString);
        
        if (isASCIIAlphaCaselessEqual(data[p + 1], 'x'))
            return parseInt(globalObject, vm, data, p + 2, 16, errorParseMode, ParseIntSign::Unsigned, ParseIntMode::DisallowEmptyString);
        
        if (isASCIIAlphaCaselessEqual(data[p + 1], 'o'))
            return parseInt(globalObject, vm, data, p + 2, 8, errorParseMode, ParseIntSign::Unsigned, ParseIntMode::DisallowEmptyString);
    }

    ParseIntSign sign = ParseIntSign::Unsigned;
    ParseIntMode parseMode = ParseIntMode::AllowEmptyString;
    if (p < data.size()) {
        if (data[p] == '-') {
            sign = ParseIntSign::Signed;
            parseMode = ParseIntMode::DisallowEmptyString;
            ++p;
        } else if (data[p] == '+') {
            parseMode = ParseIntMode::DisallowEmptyString;
            ++p;
        }
    }

    return parseInt(globalObject, vm, data, p, 10, errorParseMode, sign, parseMode);
}

template <typename CharType>
JSValue JSBigInt::parseInt(JSGlobalObject* nullOrGlobalObjectForOOM, VM& vm, std::span<const CharType> data, unsigned startIndex, unsigned radix, ErrorParseMode errorParseMode, ParseIntSign sign, ParseIntMode parseMode)
{
    size_t p = startIndex;

    // Removing trailing spaces. Trimming the span itself rather than tracking an end index keeps
    // every read below provably within it, and nothing past the trailing spaces is read again.
    while (data.size() > p && isStrWhiteSpace(data.back()))
        data = data.first(data.size() - 1);
    size_t length = data.size();

    if (parseMode != ParseIntMode::AllowEmptyString && p == length) {
        ASSERT(nullOrGlobalObjectForOOM);
        if (errorParseMode == ErrorParseMode::ThrowExceptions) {
            auto scope = DECLARE_THROW_SCOPE(vm);
            throwVMError(nullOrGlobalObjectForOOM, scope, createSyntaxError(nullOrGlobalObjectForOOM, "Failed to parse String to BigInt"_s));
        }
        return JSValue();
    }

    // Skipping leading zeros
    while (p < length && data[p] == '0')
        ++p;

    if (p == length)
        return createZero(vm);

    unsigned lengthLimitForInt32;
    // The idea is to pick the largest limit such that:
    // radix ** lengthLimitForInt32 <= INT32_MAX
#if ASSERT_ENABLED
    auto limitWorks = [&] {
        double lengthLimit = lengthLimitForInt32;
        double valueLimit = pow(static_cast<double>(radix), lengthLimit);
        double overValueLimit = pow(static_cast<double>(radix), lengthLimit + 1);
        double target = std::numeric_limits<int32_t>::max();
        return valueLimit <= target && target < overValueLimit;
    };
#endif
    switch (radix) {
    case 2:
        lengthLimitForInt32 = 30;
        ASSERT(limitWorks());
        break;
    case 8:
        lengthLimitForInt32 = 10;
        ASSERT(limitWorks());
        break;
    case 10:
        lengthLimitForInt32 = 9;
        ASSERT(limitWorks());
        break;
    case 16:
        lengthLimitForInt32 = 7;
        ASSERT(limitWorks());
        break;
    default:
        lengthLimitForInt32 = 1;
        break;
    }

    unsigned limit0 = '0' + (radix < 10 ? radix : 10);
    unsigned limita = 'a' + (static_cast<int32_t>(radix) - 10);
    unsigned limitA = 'A' + (static_cast<int32_t>(radix) - 10);
    unsigned initialLength = length - p;
    ASSERT(2 <= radix && radix <= 36);
    size_t bitsPerChar = maxBitsPerCharTable[radix];
    Vector<Digit, 16> resultVector;
    while (p < length) {
        Checked<uint64_t, CrashOnOverflow> digit = 0;
        Checked<uint64_t, CrashOnOverflow> multiplier = 1;
        for (unsigned i = 0; i < lengthLimitForInt32 && p < length; ++i, ++p) {
            digit *= radix;
            multiplier *= radix;
            if (data[p] >= '0' && data[p] < limit0)
                digit += static_cast<uint64_t>(data[p] - '0');
            else if (data[p] >= 'a' && data[p] < limita)
                digit += static_cast<uint64_t>(data[p] - 'a' + 10);
            else if (data[p] >= 'A' && data[p] < limitA)
                digit += static_cast<uint64_t>(data[p] - 'A' + 10);
            else {
                if (errorParseMode == ErrorParseMode::ThrowExceptions) {
                    auto scope = DECLARE_THROW_SCOPE(vm);
                    ASSERT(nullOrGlobalObjectForOOM);
                    throwVMError(nullOrGlobalObjectForOOM, scope, createSyntaxError(nullOrGlobalObjectForOOM, "Failed to parse String to BigInt"_s));
                }
                return JSValue();
            }
        }

        if (resultVector.isEmpty()) {
            if (p == length) {
                ASSERT(digit <= static_cast<uint64_t>(std::numeric_limits<int64_t>::max()));
                int64_t maybeResult = digit;
                ASSERT(maybeResult >= 0);
                if (sign == ParseIntSign::Signed)
                    maybeResult *= -1;

                if (static_cast<int64_t>(static_cast<int32_t>(maybeResult)) == maybeResult)
                    return JSBigInt::createFrom(nullOrGlobalObjectForOOM, vm, static_cast<int32_t>(maybeResult));
            }

            auto computeLength = [](size_t bitsPerChar, unsigned charcount) -> std::optional<unsigned> {
                size_t chars = charcount;
                const unsigned roundup = bitsPerCharTableMultiplier - 1;
                if (chars <= (std::numeric_limits<size_t>::max() - roundup) / bitsPerChar) {
                    size_t bitsMin = bitsPerChar * chars;

                    // Divide by 32 (see table), rounding up.
                    bitsMin = (bitsMin + roundup) >> bitsPerCharTableShift;
                    if (bitsMin <= static_cast<size_t>(maxInt)) {
                        // Divide by kDigitsBits, rounding up.
                        unsigned length = (bitsMin + digitBits - 1) / digitBits;
                        if (length <= maxLength)
                            return length;
                    }
                }

                return std::nullopt;
            };

            auto length = computeLength(bitsPerChar, initialLength);
            if (!length) [[unlikely]] {
                if (nullOrGlobalObjectForOOM) {
                    auto scope = DECLARE_THROW_SCOPE(vm);
                    throwOutOfMemoryError(nullOrGlobalObjectForOOM, scope, "BigInt generated from this operation is too big"_s);
                }
                return JSValue();
            }

            resultVector.fill(0, length.value());
        }

        ASSERT(static_cast<uint64_t>(static_cast<Digit>(multiplier)) == multiplier);
        ASSERT(static_cast<uint64_t>(static_cast<Digit>(digit)) == digit);
        JSCSwift::jsBigIntMultiplyAddInPlace(resultVector.mutableSpan(), static_cast<Digit>(multiplier), static_cast<Digit>(digit));
    }

    return tryCreateFromImpl(nullOrGlobalObjectForOOM, vm, sign == ParseIntSign::Signed, resultVector.span());
}

JSObject* JSBigInt::toObject(JSGlobalObject* globalObject) const
{
    return BigIntObject::create(globalObject->vm(), globalObject, const_cast<JSBigInt*>(this));
}

bool JSBigInt::equalsToNumber(JSValue numValue)
{
    ASSERT(numValue.isNumber());
    
    if (numValue.isInt32())
        return equalsToInt32(numValue.asInt32());
    
    double value = numValue.asDouble();
    return compareToDouble(this, value) == ComparisonResult::Equal;
}

bool JSBigInt::equalsToInt32(int32_t value)
{
    if (!value)
        return this->isZero();
    return (this->length() == 1) && (this->sign() == (value < 0)) && (this->digit(0) == static_cast<Digit>(std::abs(static_cast<int64_t>(value))));
}

JSBigInt::ComparisonResult JSBigInt::compareToDouble(JSBigInt* x, double y)
{
    return compareToDouble(HeapBigIntImpl { x }, y);
}

JSBigInt::ComparisonResult JSBigInt::compareToDouble(double x, JSBigInt* y)
{
    return compareToDouble(x, HeapBigIntImpl { y });
}

template <typename BigIntImpl>
JSBigInt::ComparisonResult JSBigInt::compareToDouble(BigIntImpl x, double y)
{
    // This algorithm expect that the double format is IEEE 754

    uint64_t doubleBits = std::bit_cast<uint64_t>(y);
    int rawExponent = static_cast<int>(doubleBits >> 52) & 0x7FF;

    // Handle finite doubles for {y}.
    if (rawExponent == 0x7FF) {
        if (std::isnan(y))
            return ComparisonResult::Undefined;

        return (y == std::numeric_limits<double>::infinity()) ? ComparisonResult::LessThan : ComparisonResult::GreaterThan;
    }

    bool xSign = x.sign();
    
    // Note that this is different from the double's sign bit for -0. That's
    // intentional because -0 must be treated like 0.
    bool ySign = y < 0;
    if (xSign != ySign)
        return xSign ? ComparisonResult::LessThan : ComparisonResult::GreaterThan;

    if (!y) {
        // If {y} is zero, then ySign is false and xSign must be false.
        ASSERT(!xSign);
        return x.isZero() ? ComparisonResult::Equal : ComparisonResult::GreaterThan;
    }

    if (x.isZero()) {
        // If {x} is zero, then xSign is false and ySign must be false which indicates that {y} is greater than zero.
        ASSERT(!ySign && y > 0);
        return ComparisonResult::LessThan;
    }

    // Right now, only two cases left:
    //     {x} >= 1 and {y} > 0
    //     {x} <= -1 and {y} < 0

    // Non-finite doubles are handled above.
    ASSERT(rawExponent != 0x7FF);
    int exponent = rawExponent - 0x3FF;
    if (exponent < 0) {
        // The absolute value of the double is less than 1. Only 0n has an
        // absolute value smaller than that, but we've already covered that case.
        // Note that this also handles denormal doubles for {y}.
        return xSign ? ComparisonResult::LessThan : ComparisonResult::GreaterThan;
    }

    int xLength = x.length();
    Digit xMSD = x.digit(xLength - 1);
    int msdLeadingZeros = clz(xMSD);

    int xBitLength = xLength * digitBits - msdLeadingZeros;
    int yBitLength = exponent + 1;
    if (xBitLength < yBitLength)
        return xSign? ComparisonResult::GreaterThan : ComparisonResult::LessThan;

    if (xBitLength > yBitLength)
        return xSign ? ComparisonResult::LessThan : ComparisonResult::GreaterThan;
    
    // At this point, we know that signs and bit lengths (i.e. position of
    // the most significant bit in exponent-free representation) are identical.
    // {x} is not zero, {y} is finite and not denormal.
    // Now we virtually convert the double to an integer by shifting its
    // mantissa according to its exponent, so it will align with the BigInt {x},
    // and then we compare them bit for bit until we find a difference or the
    // least significant bit.
    //                    <----- 52 ------> <-- virtual trailing zeroes -->
    // y / mantissa:     1yyyyyyyyyyyyyyyyy 0000000000000000000000000000000
    // x / digits:    0001xxxx xxxxxxxx xxxxxxxx ...
    //                    <-->          <------>
    //              msdTopBit         digitBits
    //
    uint64_t mantissa = doubleBits & 0x000FFFFFFFFFFFFF;
    mantissa |= 0x0010000000000000;
    const int mantissaTopBit = 52; // 0-indexed.

    // 0-indexed position of {x}'s most significant bit within the {msd}.
    int msdTopBit = digitBits - 1 - msdLeadingZeros;
    ASSERT(msdTopBit == static_cast<int>((xBitLength - 1) % digitBits));
    
    // Shifted chunk of {mantissa} for comparing with {digit}.
    Digit compareMantissa;

    // Number of unprocessed bits in {mantissa}. We'll keep them shifted to
    // the left (i.e. most significant part) of the underlying uint64_t.
    int remainingMantissaBits = 0;
    
    // First, compare the most significant digit against the beginning of
    // the mantissa and then we align them.
    if (msdTopBit < mantissaTopBit) {
        remainingMantissaBits = (mantissaTopBit - msdTopBit);
        compareMantissa = static_cast<Digit>(mantissa >> remainingMantissaBits);
        mantissa = mantissa << (64 - remainingMantissaBits);
    } else {
        compareMantissa = static_cast<Digit>(mantissa << (msdTopBit - mantissaTopBit));
        mantissa = 0;
    }

    if (xMSD > compareMantissa)
        return xSign ? ComparisonResult::LessThan : ComparisonResult::GreaterThan;

    if (xMSD < compareMantissa)
        return xSign ? ComparisonResult::GreaterThan : ComparisonResult::LessThan;
    
    // Then, compare additional digits against any remaining mantissa bits.
    for (int digitIndex = xLength - 2; digitIndex >= 0; digitIndex--) {
        if (remainingMantissaBits > 0) {
            remainingMantissaBits -= digitBits;
            if (sizeof(mantissa) != sizeof(xMSD)) {
                compareMantissa = static_cast<Digit>(mantissa >> (64 - digitBits));
                // "& 63" to appease compilers. digitBits is 32 here anyway.
                mantissa = mantissa << (digitBits & 63);
            } else {
                compareMantissa = static_cast<Digit>(mantissa);
                mantissa = 0;
            }
        } else
            compareMantissa = 0;

        Digit digit = x.digit(digitIndex);
        if (digit > compareMantissa)
            return xSign ? ComparisonResult::LessThan : ComparisonResult::GreaterThan;
        if (digit < compareMantissa)
            return xSign ? ComparisonResult::GreaterThan : ComparisonResult::LessThan;
    }

    // Integer parts are equal; check whether {y} has a fractional part.
    if (mantissa) {
        ASSERT(remainingMantissaBits > 0);
        return xSign ? ComparisonResult::GreaterThan : ComparisonResult::LessThan;
    }

    return ComparisonResult::Equal;
}

JSBigInt::ComparisonResult JSBigInt::compareToDouble(int32_t x, double y)
{
    return compareToDouble(Int32BigIntImpl { x }, y);
}

JSBigInt::ComparisonResult JSBigInt::compareToDouble(int64_t x, double y)
{
    return compareToDouble(Int64BigIntImpl { x }, y);
}

JSBigInt::ComparisonResult JSBigInt::compareToDouble(uint64_t x, double y)
{
    return compareToDouble(Int64BigIntImpl { x }, y);
}

JSBigInt::ComparisonResult JSBigInt::compareToDouble(JSValue x, double y)
{
    ASSERT(x.isBigInt());
    return compareToDouble(x.asHeapBigInt(), y);
}

template <typename BigIntImpl>
std::optional<JSBigInt::Digit> JSBigInt::toShiftAmount(BigIntImpl x)
{
    if (x.length() > 1)
        return std::nullopt;
    
    Digit value = x.digit(0);
    static_assert(maxLengthBits < std::numeric_limits<Digit>::max(), "maxLengthBits needs to be less than digit");
    
    if (value > maxLengthBits)
        return std::nullopt;

    return value;
}

JSBigInt::RoundingResult JSBigInt::decideRounding(JSBigInt* bigInt, int32_t mantissaBitsUnset, int32_t digitIndex, uint64_t currentDigit)
{
    if (mantissaBitsUnset > 0)
        return RoundingResult::RoundDown;
    int32_t topUnconsumedBit = 0;
    if (mantissaBitsUnset < 0) {
        // There are unconsumed bits in currentDigit.
        topUnconsumedBit = -mantissaBitsUnset - 1;
    } else {
        ASSERT(mantissaBitsUnset == 0);
        // currentDigit fit the mantissa exactly; look at the next digit.
        if (digitIndex == 0)
            return RoundingResult::RoundDown;
        digitIndex--;
        currentDigit = static_cast<uint64_t>(bigInt->digit(digitIndex));
        topUnconsumedBit = digitBits - 1;
    }
    // If the most significant remaining bit is 0, round down.
    uint64_t bitmask = static_cast<uint64_t>(1) << topUnconsumedBit;
    if ((currentDigit & bitmask) == 0)
        return RoundingResult::RoundDown;
    // If any other remaining bit is set, round up.
    bitmask -= 1;
    if ((currentDigit & bitmask) != 0)
        return RoundingResult::RoundUp;
    while (digitIndex > 0) {
        digitIndex--;
        if (bigInt->digit(digitIndex) != 0)
            return RoundingResult::RoundUp;
    }
    return RoundingResult::Tie;
}

JSValue JSBigInt::toNumberHeap(JSBigInt* bigInt)
{
    if (bigInt->isZero())
        return jsNumber(0);
    ASSERT(bigInt->length());

    // Conversion mechanism is the following.
    //
    // 1. Get exponent bits.
    // 2. Collect mantissa 52 bits.
    // 3. Add rounding result of unused bits to mantissa and adjust mantissa & exponent bits.
    // 4. Generate double by combining (1) and (3).

    const unsigned length = bigInt->length();
    const bool sign = bigInt->sign();
    const Digit msd = bigInt->digit(length - 1);
    const unsigned msdLeadingZeros = clz(msd);
    const size_t bitLength = length * digitBits - msdLeadingZeros;
    // Double's exponent bits overflow.
    if (bitLength > 1024)
        return jsDoubleNumber(sign ? -std::numeric_limits<double>::infinity() : std::numeric_limits<double>::infinity());
    uint64_t exponent = bitLength - 1;
    uint64_t currentDigit = msd;
    int32_t digitIndex = length - 1;
    int32_t shiftAmount = msdLeadingZeros + 1 + (64 - digitBits);
    ASSERT(1 <= shiftAmount);
    ASSERT(shiftAmount <= 64);
    uint64_t mantissa = (shiftAmount == 64) ? 0 : currentDigit << shiftAmount;

    // unsetBits = 64 - setBits - 12 // 12 for non-mantissa bits
    //     setBits = 64 - (msdLeadingZeros + 1 + bitsNotAvailableDueToDigitSize);  // 1 for hidden mantissa bit.
    //                 = 64 - (msdLeadingZeros + 1 + (64 - digitBits))
    //                 = 64 - shiftAmount
    // Hence, unsetBits = 64 - (64 - shiftAmount) - 12 = shiftAmount - 12

    mantissa >>= 12; // (12 = 64 - 52), we shift 12 bits to put 12 zeros in uint64_t mantissa.
    int32_t mantissaBitsUnset = shiftAmount - 12;

    // If not all mantissa bits are defined yet, get more digits as needed.
    // Collect mantissa 52bits from several digits.

    if constexpr (digitBits < 64) {
        if (mantissaBitsUnset >= static_cast<int32_t>(digitBits) && digitIndex > 0) {
            digitIndex--;
            currentDigit = static_cast<uint64_t>(bigInt->digit(digitIndex));
            mantissa |= (currentDigit << (mantissaBitsUnset - digitBits));
            mantissaBitsUnset -= digitBits;
        }
    }

    if (mantissaBitsUnset > 0 && digitIndex > 0) {
        ASSERT(mantissaBitsUnset < static_cast<int32_t>(digitBits));
        digitIndex--;
        currentDigit = static_cast<uint64_t>(bigInt->digit(digitIndex));
        mantissa |= (currentDigit >> (digitBits - mantissaBitsUnset));
        mantissaBitsUnset -= digitBits;
    }

    // If there are unconsumed digits left, we may have to round.
    RoundingResult rounding = decideRounding(bigInt, mantissaBitsUnset, digitIndex, currentDigit);
    if (rounding == RoundingResult::RoundUp || (rounding == RoundingResult::Tie && (mantissa & 1) == 1)) {
        ++mantissa;
        // Incrementing the mantissa can overflow the mantissa bits. In that case the new mantissa will be all zero (plus hidden bit).
        if ((mantissa >> doublePhysicalMantissaSize) != 0) {
            mantissa = 0;
            exponent++;
            // Incrementing the exponent can overflow too.
            if (exponent > 1023)
                return jsDoubleNumber(sign ? -std::numeric_limits<double>::infinity() : std::numeric_limits<double>::infinity());
        }
    }

    uint64_t signBit = sign ? (static_cast<uint64_t>(1) << 63) : 0;
    exponent = (exponent + 0x3ff) << doublePhysicalMantissaSize; // 0x3ff is double exponent bias.
    uint64_t doubleBits = signBit | exponent | mantissa;
    ASSERT((doubleBits & (static_cast<uint64_t>(1) << 63)) == signBit);
    ASSERT((doubleBits & (static_cast<uint64_t>(0x7ff) << 52)) == exponent);
    ASSERT((doubleBits & ((static_cast<uint64_t>(1) << 52) - 1)) == mantissa);
    return jsNumber(std::bit_cast<double>(doubleBits));
}

template <typename BigIntImpl>
JSBigInt::ImplResult JSBigInt::asIntNImpl(JSGlobalObject* globalObject, uint64_t n, BigIntImpl bigInt)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (bigInt.isZero())
        return { bigInt };
    if (n == 0)
        RELEASE_AND_RETURN(scope, zeroImpl(vm));

    uint64_t neededLength = (n + digitBits - 1) / digitBits;
    uint64_t length = static_cast<uint64_t>(bigInt.length());
    // If bigInt has less than n bits, return it directly.
    if (length < neededLength)
        return { bigInt };
    ASSERT(neededLength <= INT32_MAX);
    Digit topDigit = bigInt.digit(static_cast<int32_t>(neededLength) - 1);
    Digit compareDigit = static_cast<Digit>(1) << ((n - 1) % digitBits);
    if (length == neededLength && topDigit < compareDigit)
        return { bigInt };

    // Otherwise we have to truncate (which is a no-op in the special case
    // of bigInt == -2^(n-1)), and determine the right sign. We also might have
    // to subtract from 2^n to simulate having two's complement representation.
    // In most cases, the result's sign is bigInt.sign() xor "(n-1)th bit present".
    // The only exception is when bigInt is negative, has the (n-1)th bit, and all
    // its bits below (n-1) are zero. In that case, the result is the minimum
    // n-bit integer (example: asIntN(3, -12n) => -4n).
    bool hasBit = (topDigit & compareDigit) == compareDigit;
    ASSERT(n <= maxLengthBits);
    unsigned N = static_cast<unsigned>(n);
    if (!hasBit)
        RELEASE_AND_RETURN(scope, truncateToNBits(globalObject, N, bigInt));
    if (!bigInt.sign())
        RELEASE_AND_RETURN(scope, truncateAndSubFromPowerOfTwo(globalObject, N, bigInt, true));

    // Negative numbers must subtract from 2^n, except for the special case
    // described above.
    if ((topDigit & (compareDigit - 1)) == 0) {
        for (int32_t i = static_cast<int32_t>(neededLength) - 2; i >= 0; i--) {
            if (bigInt.digit(i) != 0)
                RELEASE_AND_RETURN(scope, truncateAndSubFromPowerOfTwo(globalObject, N, bigInt, false));
        }
        // Truncation is no-op if bigInt == -2^(n-1).
        if (length == neededLength && topDigit == compareDigit)
            return { bigInt };
        RELEASE_AND_RETURN(scope, truncateToNBits(globalObject, N, bigInt));
    }
    RELEASE_AND_RETURN(scope, truncateAndSubFromPowerOfTwo(globalObject, N, bigInt, false));
}

template <typename BigIntImpl>
JSBigInt::ImplResult JSBigInt::asUintNImpl(JSGlobalObject* globalObject, uint64_t n, BigIntImpl bigInt)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    if (bigInt.isZero())
        return { bigInt };
    if (n == 0)
        RELEASE_AND_RETURN(scope, zeroImpl(vm));

    // If bigInt is negative, simulate two's complement representation.
    if (bigInt.sign()) {
        if (n > maxLengthBits) {
            throwOutOfMemoryError(globalObject, scope, "BigInt generated from this operation is too big"_s);
            return nullptr;
        }
        RELEASE_AND_RETURN(scope, truncateAndSubFromPowerOfTwo(globalObject, static_cast<unsigned>(n), bigInt, false));
    }

    // If bigInt is positive and has up to n bits, return it directly.
    if (n >= maxLengthBits)
        return { bigInt };
    static_assert(maxLengthBits < INT32_MAX - digitBits);
    int32_t neededLength = static_cast<int32_t>((n + digitBits - 1) / digitBits);
    if (static_cast<int32_t>(bigInt.length()) < neededLength)
        return { bigInt };

    int32_t bitsInTopDigit = n % digitBits;
    if (static_cast<int32_t>(bigInt.length()) == neededLength) {
        if (bitsInTopDigit == 0)
            return { bigInt };
        Digit topDigit = bigInt.digit(neededLength - 1);
        if ((topDigit >> bitsInTopDigit) == 0)
            return { bigInt };
    }

    // Otherwise, truncate.
    ASSERT(n < maxLengthBits);
    RELEASE_AND_RETURN(scope, truncateToNBits(globalObject, static_cast<unsigned>(n), bigInt));
}

template <typename BigIntImpl>
JSBigInt::ImplResult JSBigInt::truncateToNBits(JSGlobalObject* globalObject, unsigned n, BigIntImpl bigInt)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto span = bigInt.digits();

    ASSERT(span.size() > n / digitBits);

    // asIntNImpl and asUintNImpl both return early unless n names at least one and at most
    // maxLengthBits bits of bigInt, so neededDigits is between 1 and span.size().
    RELEASE_ASSERT(n > 0);
    size_t neededDigits = (static_cast<size_t>(n) + digitBits - 1) / digitBits;
    ASSERT(neededDigits <= span.size());

    Vector<Digit, 16> resultVector(neededDigits);
    auto result = resultVector.mutableSpan();

    // Copy all digits except the MSD.
    size_t last = neededDigits - 1;
    memcpySpan(result.first(last), span.first(last));

    // The MSD might contain extra bits that we don't want.
    Digit msd = span[last];
    if (n % digitBits != 0) {
        unsigned drop = digitBits - (n % digitBits);
        msd = (msd << drop) >> drop;
    }
    result[last] = msd;
    RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, bigInt.sign(), result));
}

// Subtracts the least significant n bits of abs(bigInt) from 2^n.
template <typename BigIntImpl>
JSBigInt::ImplResult JSBigInt::truncateAndSubFromPowerOfTwo(JSGlobalObject* globalObject, unsigned n, BigIntImpl bigInt, bool resultSign)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    ASSERT(n <= maxLengthBits);

    auto span = bigInt.digits();

    RELEASE_ASSERT(n > 0);
    size_t neededDigits = (static_cast<size_t>(n) + digitBits - 1) / digitBits;
    ASSERT(neededDigits <= maxLength); // Follows from n <= maxLengthBits.

    Vector<Digit, 16> resultVector(neededDigits);
    auto result = resultVector.mutableSpan();

    // Process all digits except the MSD.
    size_t i = 0;
    size_t last = neededDigits - 1;
    size_t length = span.size();
    Digit borrow = 0;
    // Take digits from bigInt unless its length is exhausted.
    size_t limit = std::min(last, length);
    for (; i < limit; i++) {
        Digit newBorrow = 0;
        Digit difference = digitSub(0, span[i], newBorrow);
        difference = digitSub(difference, borrow, newBorrow);
        result[i] = difference;
        borrow = newBorrow;
    }
    // Then simulate leading zeroes in {bigInt} as needed.
    for (; i < last; i++) {
        Digit newBorrow = 0;
        Digit difference = digitSub(0, borrow, newBorrow);
        result[i] = difference;
        borrow = newBorrow;
    }

    // The MSD might contain extra bits that we don't want.
    Digit msd = last < length ? span[last] : 0;
    unsigned msdBitsConsumed = n % digitBits;
    Digit resultMSD;
    if (msdBitsConsumed == 0) {
        Digit newBorrow = 0;
        resultMSD = digitSub(0, msd, newBorrow);
        resultMSD = digitSub(resultMSD, borrow, newBorrow);
    } else {
        unsigned drop = digitBits - msdBitsConsumed;
        msd = (msd << drop) >> drop;
        Digit minuendMSD = static_cast<Digit>(1) << (digitBits - drop);
        Digit newBorrow = 0;
        resultMSD = digitSub(minuendMSD, msd, newBorrow);
        resultMSD = digitSub(resultMSD, borrow, newBorrow);
        ASSERT(newBorrow == 0); // result < 2^n.
        // If all subtracted bits were zero, we have to get rid of the
        // materialized minuendMSD again.
        resultMSD &= (minuendMSD - 1);
    }
    result[last] = resultMSD;
    RELEASE_AND_RETURN(scope, tryCreateFromImpl(globalObject, vm, resultSign, result));
}

JSValue JSBigInt::asIntN(JSGlobalObject* globalObject, uint64_t n, JSBigInt* bigInt)
{
    return asIntNImpl(globalObject, n, HeapBigIntImpl { bigInt }).payload;
}

JSValue JSBigInt::asUintN(JSGlobalObject* globalObject, uint64_t n, JSBigInt* bigInt)
{
    return asUintNImpl(globalObject, n, HeapBigIntImpl { bigInt }).payload;
}

uint64_t JSBigInt::toBigUInt64Heap(JSBigInt* bigInt)
{
    auto length = bigInt->length();
    if (!length)
        return 0;
    uint64_t value = 0;
    if constexpr (sizeof(Digit) == 4) {
        value = static_cast<uint64_t>(bigInt->digit(0));
        if (length > 1)
            value |= static_cast<uint64_t>(bigInt->digit(1)) << 32;
    } else {
        ASSERT(sizeof(Digit) == 8);
        value = bigInt->digit(0);
    }
    if (!bigInt->sign())
        return value;
    return ~(value - 1); // To avoid undefined behavior, we compute two's compliment by hand in C while this is simply `-value`.
}

std::optional<uint64_t> JSBigInt::tryToBigUInt64(JSValue bigInt)
{
    ASSERT(bigInt.isBigInt());
    JSBigInt* heapBigInt = bigInt.asHeapBigInt();
    if (heapBigInt->sign())
        return std::nullopt;
    return heapBigInt->tryAbsoluteValueAsUInt64();
}

std::optional<int64_t> JSBigInt::tryToBigInt64(JSValue bigInt)
{
    ASSERT(bigInt.isBigInt());
    JSBigInt* heapBigInt = bigInt.asHeapBigInt();
    auto magnitude = heapBigInt->tryAbsoluteValueAsUInt64();
    if (!magnitude)
        return std::nullopt;
    uint64_t maxMagnitude = static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) + (heapBigInt->sign() ? 1 : 0);
    if (*magnitude > maxMagnitude)
        return std::nullopt;
    return static_cast<int64_t>(toBigUInt64Heap(heapBigInt));
}

NODELETE static ALWAYS_INLINE unsigned computeHash(JSBigInt::Digit* digits, unsigned length, bool sign)
{
    Hasher hasher;
    WTF::add(hasher, sign);
    for (unsigned index = 0; index < length; ++index)
        WTF::add(hasher, digits[index]);
    return hasher.hash();
}

std::optional<unsigned> JSBigInt::concurrentHash()
{
    // FIXME: Implement JSBigInt::concurrentHash by inserting right store barriers.
    // https://bugs.webkit.org/show_bug.cgi?id=216801
    return std::nullopt;
}

unsigned JSBigInt::hashSlow()
{
    ASSERT(!m_hash);
    m_hash = computeHash(dataStorage(), length(), sign());
    return m_hash;
}

JSBigInt* JSBigInt::tryCreateFromImpl(JSGlobalObject* nullOrGlobalObjectForOOM, VM& vm, bool sign, std::span<const Digit> digits)
{
    digits = normalize(digits);
    if (digits.empty())
        return createZero(vm);

    JSBigInt* result = createWithLength(nullOrGlobalObjectForOOM, vm, digits.size());
    if (!result) [[unlikely]]
        return nullptr;
    memcpySpan(result->digits(), digits);
    result->setSign(sign);
    return result;
}

JSBigInt* JSBigInt::tryCreateFrom(JSGlobalObject* nullOrGlobalObjectForOOM, VM& vm, bool sign, std::span<const Digit> digits)
{
    return tryCreateFromImpl(nullOrGlobalObjectForOOM, vm, sign, digits);
}

} // namespace JSC

WTF_ALLOW_UNSAFE_BUFFER_USAGE_END
