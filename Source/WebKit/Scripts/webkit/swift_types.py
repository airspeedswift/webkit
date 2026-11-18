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

"""The Swift form of IPC types, for Swift receivers of messages that take Swift types.

A C++ type in a .messages.in or .serialization.in file maps to two Swift spellings: the
type a Swift handler sees, and the IPCCoder (SwiftCoding.swift) that decodes and encodes
it in the same wire format as the C++ ArgumentCoder. Types described by .serialization.in
and marked [Swift] are generated into the IPCTypes namespace, and are their own coders.
IPCTypes.CxxName gives each of them a second name made from its qualified C++ name, which
generated message receivers spell coders with, so that a message naming a C++ type that has
no Swift form does not compile, even if another C++ type with the same unqualified name has one.
"""

import re

SWIFT_TYPES_NAMESPACE = 'IPCTypes'
SWIFT_CXX_NAMES = 'CxxName'

_PRIMITIVE_TYPES = {
    'bool': 'Bool',
    'uint8_t': 'UInt8',
    'uint16_t': 'UInt16',
    'uint32_t': 'UInt32',
    # The Apple spelling, as in AudioStreamBasicDescription.
    'UInt32': 'UInt32',
    'uint64_t': 'UInt64',
    # unsigned is 32 bits on every platform WebKit supports, and is encoded as uint32_t.
    'unsigned': 'UInt32',
    # So is int, as int32_t.
    'int': 'Int32',
    'int8_t': 'Int8',
    'int16_t': 'Int16',
    'int32_t': 'Int32',
    'int64_t': 'Int64',
    'float': 'Float',
    'double': 'Double',
}

# Wire-compatible C++ templates of one type argument: (Swift value type format, coder format).
_SINGLE_ARGUMENT_TEMPLATES = {
    'Vector': ('[%s]', 'IPCCoding.Vector<%s>'),
    'std::optional': ('%s?', 'IPCCoding.StdOptional<%s>'),
    'Markable': ('%s?', 'IPCCoding.Markable<%s>'),
    # A RefPtr is encoded as a std::optional of its pointee.
    'RefPtr': ('%s?', 'IPCCoding.StdOptional<%s>'),
}

# Ref<T> is encoded as T, and OptionSet<E> is the Swift OptionSet generated for E.
_TRANSPARENT_TEMPLATES = ('Ref', 'OptionSet')

# A std::pair is its two members, in order.
_TWO_ARGUMENT_TEMPLATES = {
    'std::pair': ('(%s, %s)', 'IPCCoding.Pair<%s, %s>'),
}

# A pixel buffer, whose Swift form is the optional right to its IOSurface.
_PIXEL_BUFFER_TYPE = 'RetainPtr<CVPixelBufferRef>'

# Types marked [Swift] in a .serialization.in file whose C++ name has no namespace.
_GLOBAL_NAMESPACE_SWIFT_TYPES = frozenset(['AudioStreamBasicDescription', 'CGRendererColorData', 'CGRendererColorValue', 'WTFLogLevel'])

# Types marked [Swift] in a .serialization.in file that are in WTF, which .messages.in files name without it.
_WTF_SWIFT_TYPES = frozenset(['MediaTime'])

# C++-decoded values: types whose Swift form is the C++ object itself. Their C++ ArgumentCoder decodes and encodes
# them, through the helpers each coder in IPCCoding.CxxDecoded calls, so Swift accepts exactly what C++ does and
# copies nothing. Ref<T> and RefPtr<T> of them map to T and T?.
_CXX_DECODED_TYPES = {
    'WebCore::SharedBuffer': ('WebCore.SharedBuffer', 'IPCCoding.CxxDecoded.SharedBuffer'),
    'WebCore::VideoInfo': ('WebCore.VideoInfo', 'IPCCoding.CxxDecoded.VideoInfo'),
}


# Types whose Swift form SwiftCoding.swift writes by hand, because it is made of what C++ makes of the encoded value, like
# the CGColorSpace that a WebCore::ColorSpace is decoded into. The type is its own coder.
_HAND_WRITTEN_TYPES = {
    'WebCore::Color': 'IPCTypes.WebCoreColor',
    'WebCore::ColorSpace': 'IPCTypes.ColorSpace',
    'WebCore::Path': 'IPCTypes.Path',
}

# The Swift condition each hand-written form is under in SwiftCoding.swift, where it is not on every port. A generated
# form that holds one, directly or through another generated form, is under the same condition (generate-serializers.py).
HAND_WRITTEN_TYPE_CONDITIONS = {
    'WebCore::ColorSpace': 'canImport(CoreGraphics)',
    'WebCore::Path': 'ENABLE_GPU_PROCESS_CG_RENDERER_SWIFT',
}

# Hand-written forms whose coder also decodes with a context, decode(from:context:), which a lent-state dispatch asks its
# handler for ('SwiftDecodeContext='): what of the value the handler will use. A malformed message's dispatch calls its
# decodeFailed(context:).
_DECODE_CONTEXT_TYPES = frozenset(['WebCore::Path'])


def takes_decode_context(cpp_type):
    return strip_cpp_type_decorations(cpp_type) in _DECODE_CONTEXT_TYPES


def is_hand_written(cpp_type):
    """Whether the Swift form of a C++ IPC type is one that SwiftCoding.swift writes by hand, like IPCTypes.ColorSpace."""
    name = strip_cpp_type_decorations(cpp_type).removeprefix('::')
    return name in _HAND_WRITTEN_TYPES or name in CXX_ENUM_TYPES


# C++ enums whose Swift form is the enum that Swift imports: encoded as their underlying integer, and accepted where the value
# is one that .serialization.in lists, under its conditions, as WTF::isValidEnum() accepts it (generate-serializers.py generates
# the check: Swift's init?(rawValue:) of an imported enum accepts any value). For enums whose values are declared under
# conditions in their order, which a Swift form numbering them in .serialization.in order couldn't number as C++ does.
CXX_ENUM_TYPES = {
    'WebCore::StyleAppearance': 'WebCore.StyleAppearance',
    # The filter model's enums, which WebCore's Swift filter engine takes.
    'WebCore::BlendMode': 'WebCore.BlendMode',
    'WebCore::ChannelSelectorType': 'WebCore.ChannelSelectorType',
    'WebCore::ColorMatrixType': 'WebCore.ColorMatrixType',
    'WebCore::ComponentTransferType': 'WebCore.ComponentTransferType',
    'WebCore::CompositeOperationType': 'WebCore.CompositeOperationType',
    'WebCore::EdgeModeType': 'WebCore.EdgeModeType',
    'WebCore::MorphologyOperatorType': 'WebCore.MorphologyOperatorType',
    'WebCore::TurbulenceType': 'WebCore.TurbulenceType',
}


# Types whose Swift form owns a resource that a message carries, a send right on Darwin (SwiftCoding.swift). They are
# ~Copyable, so exactly one Swift value owns the resource and gives it back once, when it is destroyed or encoded into
# a reply. The type is its own coder.
_OWNED_TYPES = {
    'MachSendRight': 'IPCTypes.MachSendRight',
    'WTF::MachSendRight': 'IPCTypes.MachSendRight',
    'IPC::Semaphore': 'IPCTypes.Semaphore',
    'IPC::Signal': 'IPCTypes.Signal',
    'WebCore::SharedMemory::Handle': 'IPCTypes.SharedMemoryHandle',
    'WebCore::SharedMemoryHandle': 'IPCTypes.SharedMemoryHandle',
}

# Types marked [Swift] in a .serialization.in file that hold an owned type, so whose Swift forms are ~Copyable too.
# generate-serializers.py checks that this lists exactly those.
OWNED_SERIALIZED_TYPES = frozenset([
    'WebKit::ConsumerSharedCARingBufferHandle',
    'WebKit::PrepareForDisplayReply',
    'WebKit::SharedVideoFrame',
    'WebKit::SharedVideoFrame::Buffer',
])

# Swift Arrays can't hold ~Copyable elements, so the Vectors of owned types that messages carry have their own ~Copyable
# containers.
_OWNED_VECTOR_TYPES = {
    'IPCTypes.MachSendRight': 'IPCTypes.MachSendRightVector',
}


# The extents of the std::spans of const primitives of fixed extent that messages carry, each with its IPCCoding.ExtentN in
# SwiftCoding.swift: such a span is encoded as its elements, without a count, so Swift takes a copy of exactly that many.
_FIXED_SPAN_EXTENTS = frozenset([6])

# A [Lent] std::span<const uint8_t> message argument: its bytes are lent to the Swift handler during dispatch, as
# IPC::LentBytes (SwiftCoding.h), rather than copied into a [UInt8]. Generated Swift decodes past them, then lends them
# with the arguments after them decoded.
LENT_BYTES_TYPES = ('std::span<const uint8_t>',)
LENT_BYTES_SWIFT_TYPE = 'IPC.LentBytes'


class UnmappableSwiftType(Exception):
    pass


class UnmappableSwiftCondition(Exception):
    pass


def strip_cpp_type_decorations(cpp_type):
    return re.sub(r'^(?:const\s+|struct\s+|class\s+|enum\s+)+', '', cpp_type.strip()).rstrip('&').strip()


def is_lent_bytes(cpp_type):
    return strip_cpp_type_decorations(cpp_type) in LENT_BYTES_TYPES


# The C++ types that a [Lent] argument of a message taking C++ types may have: views into the message, which the Swift
# handler borrows for the dispatch. Each must be SWIFT_NONESCAPABLE, so that the handler can't keep it.
LENT_CXX_VIEW_TYPES = frozenset(['WebCore::PixelBufferSourceView'])


def is_lent_cxx_view(cpp_type):
    return strip_cpp_type_decorations(cpp_type).removeprefix('::') in LENT_CXX_VIEW_TYPES


def split_template_arguments(arguments):
    result = []
    depth = 0
    current = ''
    for character in arguments:
        if character == '<':
            depth += 1
        elif character == '>':
            depth -= 1
        if character == ',' and not depth:
            result.append(current.strip())
            current = ''
            continue
        current += character
    result.append(current.strip())
    return result


# Nested C++ types whose own names would say too little in IPCTypes, so whose Swift forms are named after the types they are
# nested in.
_NESTED_SWIFT_FORM_NAMES = {
    'WebCore::PathSegment::Data': 'PathSegmentData',
    'WebCore::PathRoundedRect::Strategy': 'PathRoundedRectStrategy',
    'WebCore::ControlStyle::State': 'ControlStyleState',
    'WebCore::MeterPart::GaugeRegion': 'MeterPartGaugeRegion',
    'WebCore::FilterEffectGeometry::Flags': 'FilterEffectGeometryFlags',
    'WebCore::SVGUnitTypes::SVGUnitType': 'SVGUnitType',
}


def swift_form_name(cpp_name):
    """The name in IPCTypes of the Swift form of a qualified C++ type: its unqualified name, like FrameIdentifier."""
    cpp_name = cpp_name.removeprefix('::')
    return _NESTED_SWIFT_FORM_NAMES.get(cpp_name, cpp_name.rsplit('::', 1)[-1])


def swift_cxx_name(cpp_name):
    """The name in IPCTypes.CxxName of the Swift form of a qualified C++ type, like WebCore_FrameIdentifier."""
    return cpp_name.removeprefix('::').replace('::', '_')


def is_owned_primitive(cpp_type):
    """Whether the Swift form of a C++ IPC type is one of SwiftCoding.swift's owned types, like IPCTypes.MachSendRight."""
    return strip_cpp_type_decorations(cpp_type).removeprefix('::') in _OWNED_TYPES


def is_owned_type(cpp_type):
    """Whether the Swift form of a C++ IPC type is ~Copyable: an owned type, or an optional or Vector of one."""
    cpp_type = strip_cpp_type_decorations(cpp_type)
    if is_owned_primitive(cpp_type) or cpp_type.removeprefix('::') in OWNED_SERIALIZED_TYPES or cpp_type == _PIXEL_BUFFER_TYPE:
        return True
    match = re.match(r'^(?:WTF::)?(?:Vector|std::optional)<(.+)>$', cpp_type)
    return bool(match) and is_owned_type(match.group(1))


def swift_type_and_coder(cpp_type, cxx_name_coders=True):
    """Returns (Swift value type, Swift IPCCoder type) for a C++ IPC type, or raises UnmappableSwiftType.

    With cxx_name_coders, the coder of a type in IPCTypes is spelled by its C++ name, as IPCTypes.CxxName.NS_T."""
    cpp_type = strip_cpp_type_decorations(cpp_type)

    if cpp_type in _PRIMITIVE_TYPES:
        swift_type = _PRIMITIVE_TYPES[cpp_type]
        return (swift_type, swift_type)

    # An AtomString is encoded as its String.
    if cpp_type in ('String', 'WTF::String', 'AtomString', 'WTF::AtomString'):
        return ('String?', 'IPCCoding.WTFString')

    # A Seconds is encoded as its value, a double, which Swift takes as the seconds it is.
    if cpp_type in ('Seconds', 'WTF::Seconds'):
        return ('Double', 'Double')

    # A WallTime is encoded as its seconds since the epoch, a double, which Swift takes as them.
    if cpp_type in ('WallTime', 'WTF::WallTime'):
        return ('Double', 'Double')

    # A GenericPromise::Result is encoded as whether the promise resolved, as its rejection carries no value.
    if cpp_type in ('GenericPromise::Result', 'WTF::GenericPromise::Result'):
        return ('Bool', 'Bool')

    # A RetainPtr<CVPixelBufferRef> is encoded as whether there is one, then a right to its IOSurface, which Swift takes as
    # the right, leaving the pixel buffer to C++.
    if cpp_type == _PIXEL_BUFFER_TYPE:
        return ('IPCTypes.MachSendRight?', 'IPCCoding.OwnedOptional<IPCTypes.MachSendRight>')

    # A UTF8CString is encoded as the span of its bytes, which Swift takes a copy of, as of a Vector of them.
    if cpp_type in ('UTF8CString', 'WTF::UTF8CString'):
        return ('[UInt8]', 'IPCCoding.Vector<UInt8>')

    if cpp_type.removeprefix('::') in _CXX_DECODED_TYPES:
        return _CXX_DECODED_TYPES[cpp_type.removeprefix('::')]

    if cpp_type.removeprefix('::') in _OWNED_TYPES:
        swift_type = _OWNED_TYPES[cpp_type.removeprefix('::')]
        return (swift_type, swift_type)

    if cpp_type.removeprefix('::') in _HAND_WRITTEN_TYPES:
        swift_type = _HAND_WRITTEN_TYPES[cpp_type.removeprefix('::')]
        return (swift_type, swift_type)

    if cpp_type.removeprefix('::') in CXX_ENUM_TYPES:
        swift_type = CXX_ENUM_TYPES[cpp_type.removeprefix('::')]
        return (swift_type, 'IPCCoding.CxxEnum<%s>' % swift_type)

    match = re.match(r'^([A-Za-z_][A-Za-z_0-9:]*)<(.+)>$', cpp_type)
    if match:
        template, arguments = match.group(1), split_template_arguments(match.group(2))
        template = re.sub(r'^WTF::', '', template)
        if any(is_owned_type(argument) for argument in arguments):
            owned_type = _OWNED_TYPES.get(strip_cpp_type_decorations(arguments[0]).removeprefix('::')) if len(arguments) == 1 else None
            # A std::optional of an owned type, but not of a container of one.
            if template == 'std::optional' and len(arguments) == 1 and not re.match(r'^(?:WTF::)?(?:Vector|std::optional)<', strip_cpp_type_decorations(arguments[0])):
                inner_type, inner_coder = swift_type_and_coder(arguments[0], cxx_name_coders)
                return ('%s?' % inner_type, 'IPCCoding.OwnedOptional<%s>' % inner_coder)
            if template == 'Vector' and owned_type in _OWNED_VECTOR_TYPES:
                return (_OWNED_VECTOR_TYPES[owned_type], _OWNED_VECTOR_TYPES[owned_type])
            raise UnmappableSwiftType("'%s' has no Swift form: of the types whose Swift form owns a resource, messages that take Swift types support each one, a std::optional of one, and %s." % (cpp_type, ', '.join('Vector<%s>' % name for name in sorted(_OWNED_VECTOR_TYPES))))
        # A std::expected is whether it has a value, then the value or the error. Swift takes it as a Result whose
        # failure wraps the error, and std::expected<void, E> as a Result whose success is ().
        if template == 'std::expected' and len(arguments) == 2:
            error_type, error_coder = swift_type_and_coder(arguments[1], cxx_name_coders)
            if strip_cpp_type_decorations(arguments[0]) == 'void':
                return ('Result<Void, IPCUnexpected<%s>>' % error_type, 'IPCCoding.ExpectedVoid<%s>' % error_coder)
            value_type, value_coder = swift_type_and_coder(arguments[0], cxx_name_coders)
            return ('Result<%s, IPCUnexpected<%s>>' % (value_type, error_type), 'IPCCoding.Expected<%s, %s>' % (value_coder, error_coder))
        if template in _TWO_ARGUMENT_TEMPLATES and len(arguments) == 2:
            value_format, coder_format = _TWO_ARGUMENT_TEMPLATES[template]
            first_type, first_coder = swift_type_and_coder(arguments[0], cxx_name_coders)
            second_type, second_coder = swift_type_and_coder(arguments[1], cxx_name_coders)
            return (value_format % (first_type, second_type), coder_format % (first_coder, second_coder))
        if template in _SINGLE_ARGUMENT_TEMPLATES and (len(arguments) == 1 or template == 'Markable'):
            value_format, coder_format = _SINGLE_ARGUMENT_TEMPLATES[template]
            inner_type, inner_coder = swift_type_and_coder(arguments[0], cxx_name_coders)
            return (value_format % inner_type, coder_format % inner_coder)
        if template in _TRANSPARENT_TEMPLATES and len(arguments) == 1:
            return swift_type_and_coder(arguments[0], cxx_name_coders)
        # A span of const primitives is encoded as a Vector of them is, so Swift takes a copy of its elements.
        if template == 'std::span' and len(arguments) == 1 and arguments[0].startswith('const ') and arguments[0].removeprefix('const ').strip() in _PRIMITIVE_TYPES:
            element = _PRIMITIVE_TYPES[arguments[0].removeprefix('const ').strip()]
            return ('[%s]' % element, 'IPCCoding.Vector<%s>' % element)
        if template == 'std::span' and len(arguments) == 2 and arguments[0].startswith('const ') and arguments[0].removeprefix('const ').strip() in _PRIMITIVE_TYPES:
            if not arguments[1].isdigit() or int(arguments[1]) not in _FIXED_SPAN_EXTENTS:
                raise UnmappableSwiftType("'%s' has no Swift form: messages that take Swift types support a std::span of const primitives of fixed extent %s." % (cpp_type, ', '.join(str(extent) for extent in sorted(_FIXED_SPAN_EXTENTS))))
            element = _PRIMITIVE_TYPES[arguments[0].removeprefix('const ').strip()]
            return ('[%s]' % element, 'IPCCoding.FixedSpan<%s, IPCCoding.Extent%s>' % (element, arguments[1]))
        raise UnmappableSwiftType("'%s' has no Swift form: %s<> is not supported in messages that take Swift types." % (cpp_type, template))

    if cpp_type.removeprefix('::').removeprefix('WTF::') in _WTF_SWIFT_TYPES:
        name = cpp_type.removeprefix('::').removeprefix('WTF::')
        swift_type = '%s.%s' % (SWIFT_TYPES_NAMESPACE, name)
        if not cxx_name_coders:
            return (swift_type, swift_type)
        return (swift_type, '%s.%s.%s' % (SWIFT_TYPES_NAMESPACE, SWIFT_CXX_NAMES, swift_cxx_name('WTF::' + name)))

    if cpp_type.removeprefix('::') in _GLOBAL_NAMESPACE_SWIFT_TYPES:
        swift_type = '%s.%s' % (SWIFT_TYPES_NAMESPACE, cpp_type.removeprefix('::'))
        if not cxx_name_coders:
            return (swift_type, swift_type)
        return (swift_type, '%s.%s.%s' % (SWIFT_TYPES_NAMESPACE, SWIFT_CXX_NAMES, swift_cxx_name(cpp_type)))

    # A leading :: qualifies a name from the global namespace, as .messages.in and .serialization.in files write the
    # types of namespaces that WebKit also has, like ::WebGPU.
    qualified_type = cpp_type.removeprefix('::')
    match = re.match(r'^(?:[A-Za-z_][A-Za-z_0-9]*::)+([A-Za-z_][A-Za-z_0-9]*)$', qualified_type)
    if match and not qualified_type.startswith('WTF::') and not qualified_type.startswith('std::'):
        swift_type = '%s.%s' % (SWIFT_TYPES_NAMESPACE, swift_form_name(qualified_type))
        if not cxx_name_coders:
            return (swift_type, swift_type)
        return (swift_type, '%s.%s.%s' % (SWIFT_TYPES_NAMESPACE, SWIFT_CXX_NAMES, swift_cxx_name(cpp_type)))

    raise UnmappableSwiftType("'%s' has no Swift form. Messages that take Swift types support integers, bool, float, "
                              "double, Seconds, WallTime, String, AtomString, MediaTime, GenericPromise::Result, Vector, std::span of const primitives (of dynamic extent, or of fixed extent %s), std::optional, std::pair, std::expected, Markable, Ref, RefPtr, OptionSet, RetainPtr<CVPixelBufferRef>, "
                              "types marked [Swift] in a .serialization.in file, the C++-decoded types %s, the owned types %s, and %s." % (cpp_type, ', '.join(str(extent) for extent in sorted(_FIXED_SPAN_EXTENTS)), ', '.join(sorted(_CXX_DECODED_TYPES)), ', '.join(sorted(_OWNED_TYPES)), ', '.join(sorted(_HAND_WRITTEN_TYPES))))


def swift_coder(cpp_type):
    return swift_type_and_coder(cpp_type)[1]


_SWIFT_CONDITION_MACROS = {
    'ENABLE': 'ENABLE_%s',
    'HAVE': 'HAVE_%s',
    'USE': 'USE_%s',
    'PLATFORM': 'WTF_PLATFORM_%s',
}

_SWIFT_CONDITION_MACRO_PREFIXES = ('ENABLE_', 'HAVE_', 'USE_', 'WTF_PLATFORM_', 'ASSERT_')


def swift_condition(cpp_condition):
    """Translates a preprocessor condition to a Swift #if condition, or raises UnmappableSwiftCondition.

    Swift sees only some of the HAVE_/USE_/ENABLE_/WTF_PLATFORM_/ASSERT_ macros that are true for C++
    (generate-platform-args), and nothing else, so a condition can differ between Swift and C++. Use it only where
    that difference fails to build, never to choose what is decoded."""
    def replace(match):
        macro, argument = match.group(1), match.group(2)
        if macro not in _SWIFT_CONDITION_MACROS:
            raise UnmappableSwiftCondition("'%s' cannot be evaluated in Swift: %s() is not available there." % (cpp_condition, macro))
        return _SWIFT_CONDITION_MACROS[macro] % argument

    result = re.sub(r'\b([A-Za-z_][A-Za-z_0-9]*)\(\s*([A-Za-z_0-9]+)\s*\)', replace, cpp_condition)
    if re.search(r'[A-Za-z_0-9]\s*\(', result):
        raise UnmappableSwiftCondition("'%s' cannot be evaluated in Swift." % cpp_condition)
    for token in re.findall(r'[A-Za-z_0-9]+|&&|\|\||[^\s]', result):
        if re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', token):
            if not token.startswith(_SWIFT_CONDITION_MACRO_PREFIXES):
                raise UnmappableSwiftCondition("'%s' cannot be evaluated in Swift: %s is not available there." % (cpp_condition, token))
        elif token not in ('!', '&&', '||', '(', ')'):
            raise UnmappableSwiftCondition("'%s' cannot be evaluated in Swift." % cpp_condition)
    return result
