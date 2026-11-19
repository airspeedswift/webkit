/*
 * Copyright (C) 2016-2019 Apple Inc. All rights reserved.
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

#include <memory>
#include <type_traits>
#include <wtf/Compiler.h>
#include <wtf/FastMalloc.h>
#include <wtf/Forward.h>
#include <wtf/SwiftBridging.h>

namespace WTF {

// Only the declarations Swift uses below have nullability annotations.
IGNORE_CLANG_WARNINGS_BEGIN("nullability-completeness")

// The C ABI a Swift closure reduces to, used by the `CxxCompletionHandler` and `CxxVoidFunction` Swift protocols to
// build a CompletionHandler or a Function out of a Swift closure.
using SwiftClosureInvoke = void (* WTF_NONNULL)(void* WTF_NONNULL context, void* WTF_NULLABLE argument);
using SwiftClosureDestroy = void (* WTF_NONNULL)(void* WTF_NONNULL context);

#ifdef __swift__
#define WTF_FUNCTION_SWIFT_UNAVAILABLE __attribute__((availability(swift, unavailable)))
#else
#define WTF_FUNCTION_SWIFT_UNAVAILABLE
#endif

namespace Detail {

class CallableWrapperAllocatorBase {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(CallableWrapperAllocatorBase);
public:
    virtual ~CallableWrapperAllocatorBase() { }
};

template<typename Out, typename... In>
class CallableWrapperBase : public CallableWrapperAllocatorBase {
public:
    virtual ~CallableWrapperBase() { }
    virtual Out call(In...) = 0;
};

template<typename, typename, typename...> class CallableWrapper;

template<typename CallableType, typename Out, typename... In>
class CallableWrapper : public CallableWrapperBase<Out, In...> {
public:
    explicit CallableWrapper(CallableType&& callable)
        : m_callable(WTF::move(callable)) { }
    CallableWrapper(const CallableWrapper&) = delete;
    CallableWrapper& operator=(const CallableWrapper&) = delete;
    // FIXME: Remove this suppression once rdar://190195858 is fixed.
    Out call(In... in) final { SUPPRESS_FORWARD_DECL_ARG return m_callable(std::forward<In>(in)...); }
private:
    CallableType m_callable;
};

} // namespace Detail

template<typename Out, typename... In> Function<Out(In...)> adopt(Detail::CallableWrapperBase<Out, In...>*);

template <typename Out, typename... In>
class Function<Out(In...)> {
    WTF_DEPRECATED_MAKE_FAST_ALLOCATED(Function);
public:
    using Impl = Detail::CallableWrapperBase<Out, In...>;

    // Swift makes a Function only with init(sendable:) (WTFFunction+Extras.swift): never an empty one, which cannot
    // be called, nor one from a closure that is not Sendable.
    WTF_FUNCTION_SWIFT_UNAVAILABLE Function() = default;
    WTF_FUNCTION_SWIFT_UNAVAILABLE Function(std::nullptr_t) { }

    template<typename CallableType>
        requires (!(std::is_pointer_v<CallableType> && std::is_function_v<typename std::remove_pointer_t<CallableType>>) && std::is_rvalue_reference_v<CallableType&&>)
    WTF_FUNCTION_SWIFT_UNAVAILABLE Function(CallableType&& callable)
        : m_callableWrapper(makeCallableWrapper(std::forward<CallableType>(callable))) { }

    template<typename FunctionType>
        requires (std::is_pointer_v<FunctionType> && std::is_function_v<typename std::remove_pointer_t<FunctionType>>)
    WTF_FUNCTION_SWIFT_UNAVAILABLE Function(FunctionType f)
        : m_callableWrapper(makeCallableWrapper(std::forward<FunctionType>(f))) { }

#if defined(__APPLE__)
    // Always use C++ lambdas to create a WTF::Function in Objective-C++.
    Function(Out (^block)(In... args)) = delete;
#endif // defined(__APPLE__)

#ifdef __swift__
    // This should only be called within the initializer of the `CxxVoidFunction` protocol
    // (Source/WebKit/Shared/WTFFunction+Extras.swift), which takes a `@Sendable` closure: a Function may be called
    // and destroyed on any thread.
    Function(SwiftClosureInvoke invoke, SwiftClosureDestroy destroy, void* WTF_NONNULL context) SWIFT_NAME(init(invoke:destroy:context:))
        : Function([invoke, owner = std::unique_ptr<void, SwiftClosureDestroy> { context, destroy }]() {
            invoke(owner.get(), nullptr);
        })
    {
        static_assert(std::is_void_v<Out> && !sizeof...(In), "Swift closures can only be used with functions that take no argument and return void.");
    }
#endif

    Out operator()(In... in) const
    {
        ASSERT(m_callableWrapper);
        // FIXME: Remove this suppression once rdar://190195858 is fixed.
        SUPPRESS_FORWARD_DECL_ARG return m_callableWrapper->call(std::forward<In>(in)...);
    }

    explicit operator bool() const { return !!m_callableWrapper; }

    template<typename CallableType>
        requires (!(std::is_pointer_v<CallableType> && std::is_function_v<typename std::remove_pointer_t<CallableType>>) && std::is_rvalue_reference_v<CallableType&&>)
    Function& operator=(CallableType&& callable)
    {
        m_callableWrapper = makeCallableWrapper(std::forward<CallableType>(callable));
        return *this;
    }

    template<typename FunctionType>
        requires (std::is_pointer_v<FunctionType> && std::is_function_v<typename std::remove_pointer_t<FunctionType>>)
    Function& operator=(FunctionType f)
    {
        m_callableWrapper = makeCallableWrapper(std::forward<FunctionType>(f));
        return *this;
    }

    Function& operator=(std::nullptr_t)
    {
        m_callableWrapper = nullptr;
        return *this;
    }

    [[nodiscard]] Impl* leak()
    {
        return m_callableWrapper.release();
    }

private:
    template<typename CallableType>
    static std::unique_ptr<Impl> makeCallableWrapper(CallableType&& callable)
    {
        using Wrapper = Detail::CallableWrapper<CallableType, Out, In...>;
        static_assert(std::is_same_v<typename Wrapper::WTFIsFastMallocAllocated, int>);
        // Construct the base unique_ptr directly so each callable type doesn't instantiate its own std::unique_ptr.
        return std::unique_ptr<Impl>(new Wrapper(std::forward<CallableType>(callable)));
    }

    enum AdoptTag { Adopt };
    Function(Impl* impl, AdoptTag)
        : m_callableWrapper(impl)
    {
    }

    friend Function adopt<Out, In...>(Impl*);

    std::unique_ptr<Impl> m_callableWrapper;
} SWIFT_SELF_CONTAINED;

template<typename Out, typename... In> Function<Out(In...)> adopt(Detail::CallableWrapperBase<Out, In...>* impl)
{
    return Function<Out(In...)>(impl, Function<Out(In...)>::Adopt);
}

using VoidFunction = Function<void()>;

IGNORE_CLANG_WARNINGS_END

} // namespace WTF
