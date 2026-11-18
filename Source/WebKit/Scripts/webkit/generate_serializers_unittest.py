# Copyright (C) 2026 Apple Inc. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1.  Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
# 2.  Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Tests the Swift forms of types marked [Swift] that generate-serializers.py generates. The other
# expected outputs in tests/ are checked by regenerating them (see tests/Makefile).
#
# Examples of how to run:
# python3 Source/WebKit/Scripts/webkit/generate_serializers_unittest.py
# cd Source/WebKit/Scripts && python3 -m unittest discover -p '*_unittest.py'

import importlib.util
import os
import re
import sys
import unittest

module_directory = os.path.dirname(os.path.abspath(__file__))
scripts_directory = os.path.abspath(os.path.join(module_directory, os.path.pardir))
sys.path.append(scripts_directory)

_specification = importlib.util.spec_from_file_location('generate_serializers', os.path.join(scripts_directory, 'generate-serializers.py'))
generate_serializers = importlib.util.module_from_spec(_specification)
_specification.loader.exec_module(generate_serializers)

from webkit import swift_types  # noqa: E402

tests_directory = os.path.join(module_directory, 'tests')

_identifiers = '''
template: struct WebCore::FrameIdentifierType
class WTF::ObjectIdentifier {
    uint64_t toUInt64()
}
'''


def generate_swift(source):
    serialized_types, serialized_enums, _, using_statements, _, _ = generate_serializers.parse_serialized_types(source.splitlines())
    serialized_types = generate_serializers.resolve_inheritance(serialized_types)
    return generate_serializers.generate_swift(serialized_types, serialized_enums, using_statements)


def enum_value_assertions(source):
    _, serialized_enums, _, _, _, _ = generate_serializers.parse_serialized_types(source.splitlines())
    return generate_serializers.swift_enum_value_assertions(serialized_enums[0])


class GeneratedSwiftTest(unittest.TestCase):
    def test_generated_file(self):
        with open(os.path.join(tests_directory, 'TestSerializedType.serialization.in')) as file:
            source = file.read()
        with open(os.path.join(tests_directory, 'GeneratedSerializers.swift')) as file:
            expected = file.read()
        self.assertEqual(generate_swift(source), expected)

    def test_lower_camel_case(self):
        for name, expected in [('FirstValue', 'firstValue'), ('HTTPSOnly', 'httpsOnly'), ('URL', 'url'), ('A', 'a'),
                               ('RGBA8', 'rgba8'), ('alreadyLower', 'alreadyLower'), ('IPCTesterInner', 'ipcTesterInner')]:
            self.assertEqual(generate_serializers.swift_lower_camel_case(name), expected)

    def test_variant_case_names(self):
        for cpp_type, expected in [('uint64_t', 'uint64'), ('String', 'string'), ('Vector<String>', 'vectorString'),
                                   ('Vector<uint8_t>', 'vectorUInt8'), ('WebKit::IPCTesterInner', 'ipcTesterInner'),
                                   ('Ref<WebKit::Node>', 'node'), ('RefPtr<WebKit::Node>', 'refPtrNode'),
                                   ('std::optional<WebCore::FrameIdentifier>', 'optionalFrameIdentifier')]:
            self.assertEqual(generate_serializers.swift_variant_case_name(cpp_type), expected)

    def test_no_swift_types(self):
        swift = generate_swift('struct WebKit::NotSwift {\n    uint32_t value;\n}\n')
        self.assertIn('#if ENABLE_SWIFT_IPC_RECEIVERS\n\nimport WebKit_Internal\n\n#endif\n', swift)
        self.assertNotIn('extension', swift)

    def test_same_type_under_exclusive_conditions(self):
        swift = generate_swift('''
#if ENABLE(A)
[Swift] struct WebKit::S {
    uint32_t value;
}
#else
[Swift] struct WebKit::S {
    uint32_t value;
}
#endif
''')
        self.assertIn('#if ENABLE_A\n', swift)
        self.assertIn('#if !(ENABLE_A)\n', swift)
        self.assertIn('        #if ENABLE_A\n        typealias WebKit_S = IPCTypes.S\n        #endif\n'
                      '        #if !(ENABLE_A)\n        typealias WebKit_S = IPCTypes.S\n        #endif\n', swift)
        for first, second in [('ENABLE(A)', '!ENABLE(A)'), ('!ENABLE(A) && ENABLE(B)', '!(!ENABLE(A) && ENABLE(B))')]:
            swift = generate_swift(f'''
#if {first}
[Swift] enum class WebKit::E : uint8_t {{
    A,
}}
#endif
#if {second}
[Swift] enum class WebKit::E : uint8_t {{
    A,
}}
#endif
''')
            self.assertEqual(swift.count('    enum E: UInt8, Sendable, Hashable {\n'), 2)
        swift = generate_swift('''
#if ENABLE(A)
#if ENABLE(B)
[Swift] enum class WebKit::E : uint8_t {
    A,
}
#else
[Swift] enum class WebKit::E : uint8_t {
    A,
}
#endif
#endif
''')
        self.assertIn('#if (ENABLE_A) && (ENABLE_B)\n', swift)
        self.assertIn('#if (ENABLE_A) && (!(ENABLE_B))\n', swift)

    def test_conditions_that_can_hold_together(self):
        for first, second, expected in [(None, None, True), ('ENABLE(A)', None, True), ('ENABLE(A)', 'ENABLE(B)', True),
                                        ('ENABLE(A)', 'ENABLE(A)', True), ('ENABLE(A)', '!(ENABLE(A))', False),
                                        ('ENABLE(A)', '!ENABLE(A)', False), ('(ENABLE(A)) && (ENABLE(B))', '(ENABLE(A)) && (!(ENABLE(B)))', False),
                                        ('ENABLE(A) && ENABLE(B)', '!(ENABLE(A) && ENABLE(B))', False), ('ENABLE(A) || ENABLE(B)', '!ENABLE(A)', True),
                                        ('((ENABLE(A)) && (ENABLE(B))) && (ENABLE(C))', '!(ENABLE(C))', False)]:
            self.assertEqual(generate_serializers.conditions_can_hold_together(first, second), expected, (first, second))
            self.assertEqual(generate_serializers.conditions_can_hold_together(second, first), expected, (second, first))

    def test_cxx_names(self):
        swift = generate_swift(_identifiers + '''
[Swift] struct WebKit::S {
    WebCore::FrameIdentifier frameID;
}
#if ENABLE(A)
[Swift, Nested] enum class WebKit::S::Kind : uint8_t {
    Value
}
#endif
''')
        self.assertIn('''    enum CxxName {
        typealias WebCore_FrameIdentifier = IPCTypes.FrameIdentifier
        typealias WebKit_S = IPCTypes.S
        #if ENABLE_A
        typealias WebKit_S_Kind = IPCTypes.Kind
        #endif
    }
''', swift)
        self.assertIn('        var frameID: IPCTypes.FrameIdentifier\n', swift)
        self.assertIn('        IPCTypes.FrameIdentifier.encode(value.frameID, to: encoder)\n', swift)

    def test_owned_forms(self):
        source = '''
[Swift] struct WebKit::Holder {
    WebCore::SharedMemoryHandle memory;
    uint64_t frameCount;
}
[Swift] using WebKit::Buffer = Variant<std::monostate, MachSendRight, uint32_t>
'''
        original = swift_types.OWNED_SERIALIZED_TYPES
        swift_types.OWNED_SERIALIZED_TYPES = frozenset(['WebKit::Holder', 'WebKit::Buffer'])
        try:
            swift = generate_swift(source)
        finally:
            swift_types.OWNED_SERIALIZED_TYPES = original
        self.assertIn('#if canImport(Darwin)\nextension IPCTypes {\n    struct Holder: ~Copyable, Sendable {\n        var memory: IPCTypes.SharedMemoryHandle\n        var frameCount: UInt64\n    }\n}\n', swift)
        self.assertIn('extension IPCTypes.Holder: IPCOwnedCoder {\n', swift)
        self.assertIn('        let memory = try IPCTypes.SharedMemoryHandle.decode(from: &decoder)\n        let frameCount = try UInt64.decode(from: &decoder)\n        self.memory = memory\n        self.frameCount = frameCount\n', swift)
        self.assertIn('    static func encode(_ value: consuming IPCTypes.Holder, to encoder: IPC.SwiftReplyEncoder) {\n        IPCTypes.SharedMemoryHandle.encode(value.memory, to: encoder)\n        UInt64.encode(value.frameCount, to: encoder)\n', swift)
        self.assertIn('    enum Buffer: ~Copyable, Sendable {\n        case empty\n        case machSendRight(IPCTypes.MachSendRight)\n        case uint32(UInt32)\n', swift)
        self.assertIn('        switch consume value {\n', swift)
        self.assertIn('        #if canImport(Darwin)\n        typealias WebKit_Holder = IPCTypes.Holder\n        #endif\n', swift)

    def test_forms_holding_conditional_hand_written_forms(self):
        source = '''
[Swift] struct WebKit::Tinted {
    WebCore::ColorSpace colorSpace;
    uint64_t value;
}
[Swift] struct WebKit::Outer {
    WebKit::Tinted tinted;
}
[Swift] struct WebKit::Plain {
    uint64_t value;
}
'''
        swift = generate_swift(source)
        # A form holding a hand-written form is under its condition, and so is a form holding that form.
        self.assertIn('#if canImport(CoreGraphics)\nextension IPCTypes {\n    struct Tinted: Sendable, Equatable {\n', swift)
        self.assertIn('#if canImport(CoreGraphics)\nextension IPCTypes {\n    struct Outer: Sendable, Equatable {\n', swift)
        self.assertIn('\nextension IPCTypes {\n    struct Plain: Sendable, Equatable {\n', swift)
        self.assertNotIn('#if canImport(CoreGraphics)\nextension IPCTypes {\n    struct Plain:', swift)
        self.assertIn('        #if canImport(CoreGraphics)\n        typealias WebKit_Tinted = IPCTypes.Tinted\n        #endif\n', swift)

    def test_types_described_alike(self):
        swift = generate_swift('''
[Swift, OptionSet] enum class WebKit::M : uint8_t {
    Read,
    Write,
};
[AdditionalEncoder=StreamConnectionEncoder] enum class WebKit::M : uint8_t {
    Read,
    Write,
};
[Swift] enum class WebKit::E : uint8_t {
    A,
};
using WebKit::E = WebKit::E
''')
        self.assertEqual(swift.count('    struct M: OptionSet, Sendable, Hashable {\n'), 1)
        self.assertEqual(swift.count('    enum E: UInt8, Sendable, Hashable {\n'), 1)

    def test_conditional_values(self):
        for condition in ['ENABLE(B)', '!RELEASE_LOG_DISABLED', 'defined(SOMETHING)']:
            swift = generate_swift(f'''
[Swift] enum class WebKit::E : uint8_t {{
    A,
#if {condition}
    B,
#endif
    C,
}}
[Swift, OptionSet] enum class WebKit::O : uint8_t {{
    A,
#if {condition}
    B,
#endif
}}
''')
            self.assertIn('        case a = 0\n        case b = 1\n        case c = 2\n    }\n', swift)
            self.assertIn('        static let a = O(rawValue: 1 << 0)\n        static let b = O(rawValue: 1 << 1)\n    }\n', swift)
            self.assertIn('        unknownValues.subtract(.a)\n        unknownValues.subtract(.b)\n', swift)
            self.assertNotRegex(swift, r'\n *#(?!if ' + re.escape(generate_serializers.SWIFT_FILE_CONDITION) + r'\n|endif\n$)')

    def test_enum_value_assertions(self):
        self.assertEqual(enum_value_assertions('''
[Swift] enum class WebKit::E : uint8_t {
    A,
#if ENABLE(B)
    B,
#endif
}
'''), [
            'static_assert(sizeof(std::underlying_type_t<WebKit::E>) == sizeof(uint8_t), "IPCTypes.E in GeneratedSerializers.swift has the size of the underlying type in .serialization.in");',
            'static_assert(!static_cast<uint8_t>(WebKit::E::A), "IPCTypes.E in GeneratedSerializers.swift numbers values in .serialization.in order");',
            '#if ENABLE(B)',
            'static_assert(static_cast<uint8_t>(WebKit::E::B) == 1, "IPCTypes.E in GeneratedSerializers.swift numbers values in .serialization.in order");',
            '#endif',
        ])
        self.assertEqual(enum_value_assertions('''
[Swift, OptionSet] enum class WebKit::E : uint32_t {
    A,
    B,
}
'''), [
            'static_assert(sizeof(std::underlying_type_t<WebKit::E>) == sizeof(uint32_t), "IPCTypes.E in GeneratedSerializers.swift has the size of the underlying type in .serialization.in");',
            'static_assert(static_cast<uint32_t>(WebKit::E::A) == (1ull << 0), "IPCTypes.E in GeneratedSerializers.swift numbers values in .serialization.in order");',
            'static_assert(static_cast<uint32_t>(WebKit::E::B) == (1ull << 1), "IPCTypes.E in GeneratedSerializers.swift numbers values in .serialization.in order");',
        ])
        self.assertEqual(enum_value_assertions('''
enum class WebKit::E : uint8_t {
    A,
}
'''), [])

    def test_enum_numbers(self):
        swift = generate_swift('''
[Swift] enum class WebKit::Rotation : uint16_t {
    None = 0,
    UpsideDown = 180,
    Right = 90,
    Left = 270,
}
''')
        self.assertIn('    enum Rotation: UInt16, Sendable, Hashable {\n'
                      '        case none = 0\n'
                      '        case upsideDown = 180\n'
                      '        case right = 90\n'
                      '        case left = 270\n'
                      '    }\n', swift)
        self.assertEqual(enum_value_assertions('''
[Swift] enum class WebKit::E : uint8_t {
    A = 4,
    B = 1,
}
'''), [
            'static_assert(sizeof(std::underlying_type_t<WebKit::E>) == sizeof(uint8_t), "IPCTypes.E in GeneratedSerializers.swift has the size of the underlying type in .serialization.in");',
            'static_assert(static_cast<uint8_t>(WebKit::E::A) == 4, "IPCTypes.E in GeneratedSerializers.swift numbers values as .serialization.in does");',
            'static_assert(static_cast<uint8_t>(WebKit::E::B) == 1, "IPCTypes.E in GeneratedSerializers.swift numbers values as .serialization.in does");',
        ])

    def test_ref_counted_type_without_members(self):
        swift = generate_swift('[Swift, RefCounted] class WebKit::Empty {\n}\n')
        self.assertIn('    struct Empty: Sendable, Equatable {\n    }\n', swift)


class SwiftErrorTest(unittest.TestCase):
    def assertGenerationFails(self, source, message):
        with self.assertRaisesRegex(Exception, message):
            generate_swift(source)

    def test_name_collisions(self):
        self.assertGenerationFails('''
[Swift] struct WebKit::Thing {
    uint32_t value;
}
[Swift] enum class WebCore::Thing : uint8_t {
    Value
}
''', r'WebCore::Thing and WebKit::Thing would both be IPCTypes\.Thing')
        self.assertGenerationFails(_identifiers + '''
[Swift] struct WebKit::FrameIdentifier {
    uint32_t value;
}
''', r'WebCore::FrameIdentifier and WebKit::FrameIdentifier would both be IPCTypes\.FrameIdentifier')
        self.assertGenerationFails('''
[Swift] enum class WebKit::Optional : bool {
    No,
    Yes
}
''', r'WebKit::Optional cannot have a Swift form, because IPCTypes\.Optional would hide the Swift type Optional')
        self.assertGenerationFails('''
[Swift, Nested] enum class WebCore::PlatformEvent::Type : uint8_t {
    Value
}
''', r'WebCore::PlatformEvent::Type cannot have a Swift form, because Swift does not allow a type named Type')
        self.assertGenerationFails('''
[Swift] struct WebKit::CxxName {
    uint32_t value;
}
''', r'WebKit::CxxName cannot have a Swift form, because IPCTypes\.CxxName is the generated index of Swift forms by C\+\+ name')
        self.assertGenerationFails('''
[Swift] struct WebKit::Inner_Thing {
    uint32_t value;
}
[Swift] struct WebKit_Inner::Thing {
    uint32_t value;
}
''', r'WebKit::Inner_Thing and WebKit_Inner::Thing would both be IPCTypes\.CxxName\.WebKit_Inner_Thing in Swift')

    def test_identifiers_described_as_other_types(self):
        source = '''
template: struct WebCore::FrameIdentifierType
template: struct WebCore::NavigationIdentifierType
template: struct WebCore::PageIdentifierType
class WTF::ObjectIdentifier {
    uint64_t toUInt64()
}
[Alias=class ProcessQualified<NavigationIdentifierID>, CustomHeader] alias WebCore::NavigationIdentifier {
    WebCore::NavigationIdentifierID object();
    WebCore::ProcessIdentifier processIdentifier();
};
using WebCore::PageIdentifier = Variant<uint32_t, uint64_t>;
'''
        swift = generate_swift(source)
        self.assertIn('    struct FrameIdentifier: IPCObjectIdentifier {\n        let value: IPCObjectIdentifierValue\n    }\n', swift)
        self.assertNotIn('NavigationIdentifier', swift)
        self.assertNotIn('PageIdentifier', swift)
        self.assertGenerationFails(source + '''
[Swift] struct WebKit::S {
    WebCore::NavigationIdentifier navigationID;
}
''', r'member navigationID: WebCore::NavigationIdentifier has no Swift form')
        self.assertGenerationFails(source + '''
[Swift] struct WebKit::S {
    std::optional<WebCore::PageIdentifier> pageID;
}
''', r'member pageID: WebCore::PageIdentifier has no Swift form')

    def test_disallowed_member_names(self):
        for name, swift_name in [('m_Type', 'Type'), ('Protocol()', 'Protocol'), ('m_self', 'self')]:
            self.assertGenerationFails(f'''
[Swift] struct WebKit::S {{
    uint32_t {name};
}}
''', rf'member {re.escape(name)}: it would be named {swift_name} in Swift, which cannot be the name of a property')

    def test_owned_forms_must_be_listed(self):
        self.assertGenerationFails('''
[Swift] struct WebKit::Holder {
    MachSendRight right;
}
''', r'\[Swift\] WebKit::Holder: it holds a type whose Swift form owns a resource, so its Swift form is ~Copyable, and it must be listed in OWNED_SERIALIZED_TYPES')

    def test_unmappable_member_type(self):
        self.assertGenerationFails('''
[Swift] struct WebKit::S {
    long value;
}
''', r"\[Swift\] WebKit::S: member value: 'long' has no Swift form")
        self.assertGenerationFails('''
[Swift] struct WebKit::S {
    HashMap<String, String> map;
}
''', r'member map: .*HashMap<> is not supported')

    def test_member_type_without_swift_form(self):
        self.assertGenerationFails('''
struct WebKit::NotSwift {
    uint32_t value;
}
[Swift] struct WebKit::S {
    Vector<WebKit::NotSwift> values;
}
''', r'member values: WebKit::NotSwift has no Swift form')
        self.assertGenerationFails(_identifiers + '''
[Swift] struct WebKit::S {
    WebCore::FrameIdentifierType tag;
}
''', r'member tag: WebCore::FrameIdentifierType has no Swift form')

    def test_member_type_in_another_namespace(self):
        self.assertGenerationFails('''
[Swift] struct WebKit::Inner {
    uint32_t value;
}
[Swift] struct WebKit::S {
    WebCore::Inner inner;
}
''', r'member inner: WebCore::Inner would be IPCTypes\.Inner in Swift, which is the Swift form of WebKit::Inner')

    def test_ref_counted_members(self):
        self.assertGenerationFails('''
[Swift] struct WebKit::Inner {
    uint32_t value;
}
[Swift] struct WebKit::S {
    Ref<WebKit::Inner> inner;
}
''', r'WebKit::Inner must be held in a Ref or RefPtr if, and only if, it is marked \[RefCounted\]')
        self.assertGenerationFails('''
[Swift, RefCounted] class WebKit::Node {
    uint32_t value;
}
[Swift] struct WebKit::S {
    Vector<WebKit::Node> nodes;
}
''', r'WebKit::Node must be held in a Ref or RefPtr if, and only if, it is marked \[RefCounted\]')

    def test_option_set_members(self):
        self.assertGenerationFails('''
[Swift] enum class WebKit::E : uint8_t {
    Value
}
[Swift] struct WebKit::S {
    OptionSet<WebKit::E> values;
}
''', r'WebKit::E must be held in an OptionSet if, and only if, it is marked \[OptionSet\]')
        self.assertGenerationFails('''
[Swift, OptionSet] enum class WebKit::E : uint8_t {
    Value
}
[Swift] struct WebKit::S {
    WebKit::E value;
}
''', r'WebKit::E must be held in an OptionSet if, and only if, it is marked \[OptionSet\]')

    def test_unsupported_member_attributes(self):
        for attribute in ["Precondition='isAvailable()'", 'EncodeRequestBody', 'OptionalTupleBits']:
            self.assertGenerationFails(f'''
[Swift] struct WebKit::S {{
    [{attribute}] uint32_t value;
}}
''', r'member value: types marked \[Swift\] do not support the member attribute ' + attribute.split('=')[0])
        self.assertGenerationFails('''
[Swift] struct WebKit::S {
    [OptionalTupleBit=WebKit::Change::Value] uint32_t value;
}
''', 'do not support the member attribute OptionalTupleBit')

    def test_enum_number_errors(self):
        self.assertGenerationFails('''
[Swift] enum class WebKit::E : uint8_t {
    A = 1,
    B,
}
''', r'either every value of an enum marked \[Swift\] gives its number, or none does')
        self.assertGenerationFails('''
[Swift] enum class WebKit::E : uint8_t {
    A = 1,
    B = 1,
}
''', r'more than one of its values has the same number')
        self.assertGenerationFails('''
[Swift] enum class WebKit::E : uint8_t {
    A = 256,
}
''', r'the number of one of its values does not fit in uint8_t')
        self.assertGenerationFails('''
[Swift] enum class WebKit::E : int8_t {
    A = 128,
}
''', r'the number of one of its values does not fit in int8_t')
        self.assertGenerationFails('''
[Swift, OptionSet] enum class WebKit::E : uint8_t {
    A = 1,
}
''', r'the values of an OptionSet or a bool enum marked \[Swift\] cannot give their numbers')
        self.assertGenerationFails('''
enum class WebKit::E : uint8_t {
    A = 1,
}
''', r'only enums marked \[Swift\] give the numbers of their values')

    def test_validators(self):
        swift = generate_swift('''
[Swift] struct WebKit::S {
    int32_t minimum;
    [Validator='*maximum >= *minimum', SwiftValidator='maximum >= minimum'] int32_t maximum;
}
''')
        self.assertIn('        self.minimum = try Int32.decode(from: &decoder)\n'
                      '        self.maximum = try Int32.decode(from: &decoder)\n'
                      '        guard maximum >= minimum else {\n'
                      '            throw IPCDecodingError()\n'
                      '        }\n'
                      '    }\n', swift)
        self.assertGenerationFails('''
[Swift] struct WebKit::S {
    [Validator='value > 1'] uint32_t value;
}
''', r'member value: in a type marked \[Swift\], a member with a Validator needs a SwiftValidator')
        self.assertGenerationFails('''
[Swift] struct WebKit::S {
    [SwiftValidator='value > 1'] uint32_t value;
}
''', r'member value: in a type marked \[Swift\], a member with a Validator needs a SwiftValidator, the same check in Swift, and a SwiftValidator needs a Validator')

    def test_unsupported_member_names(self):
        for name in ['functionCall().member', 'member.value', 'functionCall(argument)']:
            self.assertGenerationFails(f'''
[Swift] struct WebKit::S {{
    uint32_t {name};
}}
''', r'can only have members that are variables or member functions without arguments')

    def test_duplicate_member_names(self):
        self.assertGenerationFails('''
[Swift] struct WebKit::S {
    uint32_t m_value;
    uint32_t value();
}
''', r'\[Swift\] WebKit::S: more than one of its members would be named value in Swift')

    def test_aliases(self):
        swift = generate_swift('''
[Swift, Alias=class IPC::ObjectIdentifierReference<WebKit::RemoteVideoFrameIdentifier>, AdditionalEncoder=StreamConnectionEncoder, CustomHeader] alias WebKit::RemoteVideoFrameReference {
    uint64_t identifier();
    uint64_t version();
};
''')
        self.assertIn('    struct RemoteVideoFrameReference: Sendable, Equatable {\n'
                      '        var identifier: UInt64\n'
                      '        var version: UInt64\n'
                      '    }\n', swift)
        self.assertIn('        typealias WebKit_RemoteVideoFrameReference = IPCTypes.RemoteVideoFrameReference\n', swift)

    def test_vector_using_statements(self):
        swift = generate_swift('''
[Swift] struct WebKit::Term {
    uint32_t index;
};
using WebKit::Expression = Vector<WebKit::Term>;
[Swift] struct WebKit::Program {
    WebKit::Expression expression;
};
''')
        self.assertIn('        var expression: [IPCTypes.Term]\n', swift)

    def test_cxx_enum_validation(self):
        swift = generate_swift('''
enum class WebCore::StyleAppearance : uint8_t {
    None,
    Auto,
#if ENABLE(APPLE_PAY)
    ApplePayButton,
#endif
    Switch
}
''')
        self.assertIn('''extension WebCore.StyleAppearance: IPCCxxEnum {
    static func isDeclaredValue(_ value: Self) -> Bool {
        switch value {
        case .None:
            return true
        case .Auto:
            return true
        #if ENABLE_APPLE_PAY
        case .ApplePayButton:
            return true
        #endif
        case .Switch:
            return true
        default:
            return false
        }
    }
}''', swift)

    def test_unsupported_types(self):
        self.assertGenerationFails('''
[Swift, CustomEncoder] struct WebKit::S {
    uint32_t value;
}
''', r'types marked \[Swift\] do not support the attribute CustomEncoder')
        self.assertGenerationFails('''
[Swift, RefCounted] class WebCore::TimingFunction subclasses {
    WebCore::LinearTimingFunction,
}
''', r'subclass WebCore::LinearTimingFunction: WebCore::LinearTimingFunction has no Swift form')
        self.assertGenerationFails('''
[Swift, RefCounted] class WebCore::TimingFunction subclasses {
    WebCore::LinearTimingFunction,
}
[Swift, RefCounted] class WebCore::LinearTimingFunction {
    float value();
}
[Swift, RefCounted] class WebCore::Shape subclasses {
    WebCore::LinearTimingFunction,
    WebCore::LinearTimingFunction,
}
''', r'more than one of its subclasses would be named linearTimingFunction in Swift')
        self.assertGenerationFails('''
[Swift] CFFooRef wrapped by WebKit::FooWrapper {
}
''', r'wrapped CF types cannot be marked \[Swift\]')
        self.assertGenerationFails('''
[Swift] webkit_secure_coding NSSomeFoundationType {
    StringKey: String
}
''', r'webkit_secure_coding types cannot be marked \[Swift\]')
        self.assertGenerationFails('''
[Swift] class WebCore::RectEdges<bool> {
    bool top();
}
''', r'templates cannot be marked \[Swift\]')
        self.assertGenerationFails('''
template: class WebKit::Fabulous
[Swift] class WebKit::TemplateTest {
    bool value;
}
''', r'templates cannot be marked \[Swift\]')
        with self.assertRaisesRegex(Exception, r'\[Swift\] is not supported on wrapped types'):
            generate_swift('[Swift] NSNull wrapped by CoreIPCNull\n')
        self.assertGenerationFails('''
[Swift, CreateUsing=fromValue] struct WebKit::S {
    uint32_t value;
}
''', r'types marked \[Swift\] do not support the attribute CreateUsing, because Swift would not make the checks that the C\+\+ function may make')

    def test_parent_class(self):
        self.assertGenerationFails('''
[Swift] class WebKit::Derived : WebKit::Unknown {
    uint32_t value;
}
''', r'its parent class WebKit::Unknown is not described in a .serialization.in file')
        self.assertGenerationFails('''
class WebKit::Base {
    [Validator='value > 1'] uint32_t value;
}
[Swift] class WebKit::Derived : WebKit::Base {
    uint32_t otherValue;
}
''', r'\[Swift\] WebKit::Derived: member value: in a type marked \[Swift\], a member with a Validator needs a SwiftValidator')

    def test_conditions(self):
        self.assertGenerationFails('''
#if OS(WINDOWS)
[Swift] struct WebKit::S {
    uint32_t value;
}
#endif
''', r"\[Swift\] WebKit::S: 'OS\(WINDOWS\)' cannot be evaluated in Swift")
        for condition, name in [('CGFLOAT_IS_DOUBLE', 'CGFLOAT_IS_DOUBLE'), ('!RELEASE_LOG_DISABLED', 'RELEASE_LOG_DISABLED'), ('ENABLE(FOO) && LOG_DISABLED', 'LOG_DISABLED')]:
            self.assertGenerationFails(f'''
#if {condition}
[Swift] enum class WebKit::E : uint8_t {{
    A,
}}
#endif
''', rf'\[Swift\] WebKit::E: .*cannot be evaluated in Swift: {name} is not available there')
        # Swift does not see every macro that is true for C++, so conditions must not choose what is decoded.
        for condition in ['ENABLE(MODEL_ELEMENT_STAGE_MODE)', '!ENABLE(A)', 'defined(SOMETHING)']:
            self.assertGenerationFails(f'''
[Swift] struct WebKit::S {{
    uint32_t a;
#if {condition}
    uint32_t b;
#endif
}}
''', r'\[Swift\] WebKit::S: member b: types marked \[Swift\] cannot have conditional members')
            self.assertGenerationFails(f'''
class WebKit::Base {{
#if {condition}
    uint32_t b;
#endif
}}
[Swift] class WebKit::Derived : WebKit::Base {{
    uint32_t a;
}}
''', r'\[Swift\] WebKit::Derived: member b: types marked \[Swift\] cannot have conditional members')
        self.assertGenerationFails('''
#if ENABLE(A)
[Swift] struct WebKit::S {
    uint32_t value;
}
#else
[Swift] struct WebKit::S {
    uint64_t value;
}
#endif
''', r'WebKit::S cannot be marked \[Swift\] and be described more than once in different ways')
        self.assertGenerationFails('''
#if !ENABLE(A)
[Swift] struct WebKit::S {
    uint32_t value;
}
#else
struct WebKit::S {
    uint64_t value;
}
#endif
''', r'WebKit::S cannot be marked \[Swift\] and be described more than once in different ways')
        self.assertGenerationFails('''
[Swift, OptionSet] enum class WebKit::M : uint8_t {
    Read,
    Write,
};
[AdditionalEncoder=StreamConnectionEncoder] enum class WebKit::M : uint8_t {
    Read,
#if ENABLE(A)
    Write,
#endif
};
''', r'WebKit::M cannot be marked \[Swift\] and be described more than once in different ways')
        self.assertGenerationFails('''
[Swift] enum class WebKit::E : uint8_t {
    A,
};
using WebKit::E = uint8_t
''', r'WebKit::E cannot be marked \[Swift\] and be described more than once in different ways')
        for first, second in [(None, None), ('ENABLE(A)', 'ENABLE(B)'), ('ENABLE(A)', None), ('ENABLE(A) || ENABLE(B)', '!ENABLE(A)')]:
            source = ''
            for condition in [first, second]:
                description = '[Swift] struct WebKit::S {\n    uint32_t value;\n}\n'
                source += f'#if {condition}\n{description}#endif\n' if condition else description
            self.assertGenerationFails(source, r'WebKit::S cannot be marked \[Swift\] in more than one description unless their conditions cannot hold together')
        swift = generate_swift('''
[Swift] struct WebKit::S {
    uint32_t value;
#if ENABLE(A)
    [NotSerialized] uint32_t cache;
#endif
}
''')
        self.assertIn('    struct S: Sendable, Equatable {\n        var value: UInt32\n    }\n', swift)

    def test_enums(self):
        self.assertGenerationFails('''
[Swift] enum class WebKit::E : bool
''', r'an enum marked \[Swift\] must list its values')
        self.assertGenerationFails('''
[Swift] enum class WebKit::E : bool {
    No,
    Yes,
    Maybe
}
''', r'a bool enum marked \[Swift\] must have exactly two values')
        self.assertGenerationFails('''
[Swift, OptionSet] enum class WebKit::E : int8_t {
    A
}
''', r'the underlying type of an OptionSet marked \[Swift\] must be unsigned')
        self.assertGenerationFails('''
[Swift] enum class WebKit::E : uint8_t {
#if ENABLE(A)
    A,
#else
    A,
#endif
}
''', r'more than one of its values would be named a in Swift')
        self.assertGenerationFails('''
[Swift] enum class WebKit::E : bool {
    No,
#if ENABLE(A)
    Yes
#endif
}
''', r'a bool enum marked \[Swift\] must have exactly two values, which are not conditional')
        self.assertGenerationFails('''
[Swift] enum class WebKit::E : uint8_t {
    URL,
    Url
}
''', r'more than one of its values would be named url in Swift')
        self.assertGenerationFails('''
[Swift] enum class WebKit::E : uint8_t {
    RawValue
}
''', r'a value would be named rawValue in Swift')
        self.assertGenerationFails('''
[Swift, OptionSet] enum class WebKit::E : uint8_t {
''' + ''.join(f'    Value{index},\n' for index in range(9)) + '''}
''', r'it has more values than uint8_t has bits')
        self.assertGenerationFails('''
[Swift] enum class WebKit::E : long {
    A
}
''', r"'long' has no Swift form")
        self.assertGenerationFails('''
[Swift, Unknown] enum class WebKit::E : uint8_t {
    A
}
''', r'enums marked \[Swift\] do not support the attribute Unknown')

    def test_variants(self):
        self.assertGenerationFails('''
[Swift] using WebKit::V = Variant<
    uint32_t,
#if ENABLE(A)
    uint64_t,
#endif
    double
>;
''', r'a Variant marked \[Swift\] cannot have conditional alternatives')
        self.assertGenerationFails('''
[Swift] using WebKit::V = uint32_t;
''', r'only using statements of a Variant can be marked \[Swift\]')
        self.assertGenerationFails('''
[Swift] using WebKit::V = Variant<uint8_t, uint8_t>
''', r'more than one of its alternatives would be named uint8 in Swift')
        self.assertGenerationFails('''
[Swift] using WebKit::V = Variant<uint8_t, long>
''', r"alternative long: 'long' has no Swift form")

    def test_null_alternative(self):
        swift = generate_swift('''
[Swift] using WebKit::V = Variant<std::nullptr_t, uint32_t>
''')
        self.assertIn('    enum V: Sendable, Equatable {\n        case null\n        case uint32(UInt32)\n', swift)
        self.assertIn('        case 0:\n            return .null\n', swift)
        self.assertIn('        case .null:\n            UInt8.encode(0, to: encoder)\n', swift)


if __name__ == '__main__':
    unittest.main()
