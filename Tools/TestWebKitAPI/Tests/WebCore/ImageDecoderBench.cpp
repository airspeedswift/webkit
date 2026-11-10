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

#include "Helpers/Test.h"
#include <WebCore/GraphicsContext.h>
#include <WebCore/ImageBuffer.h>
#include <WebCore/ImageDecoder.h>
#include <WebCore/IntPoint.h>
#include <WebCore/IntSize.h>
#include <WebCore/NativeImage.h>
#include <WebCore/PixelBuffer.h>
#include <WebCore/SharedBuffer.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <wtf/MonotonicTime.h>
#include <wtf/Vector.h>
#include <wtf/text/StringView.h>

// Throughput of the GIF, BMP and ICO decoders behind ImageDecoder::create, one TEST per kind of input. Every input
// is generated here. Each image is decoded as a page decodes it: create a decoder, give it the data, ask for the
// frame count and then for every frame's image and metadata. By default each TEST decodes its input once, reads back
// every frame's pixels and checks the checksum of the pixels and metadata. With WEBKIT_RUN_BENCHMARKS=1 in the
// environment it then repeats the decoding (without the read-back) for about a second and prints
// "<Name>: <ms> ms <MB/s> MB/s checksum=<hex>", with the same checksum, where MB/s counts encoded bytes. Nothing
// asserts on time.

using namespace WebCore;

namespace TestWebKitAPI {

namespace {

class Generator {
public:
    explicit Generator(uint32_t seed)
        : m_state(seed)
    {
    }

    uint32_t next()
    {
        m_state ^= m_state << 13;
        m_state ^= m_state >> 17;
        m_state ^= m_state << 5;
        return m_state;
    }

    unsigned below(unsigned n) { return next() % n; }

private:
    uint32_t m_state;
};

struct Checksum {
    uint64_t value { 1469598103934665603ull };

    void add(uint64_t word)
    {
        value ^= word;
        value *= 1099511628211ull;
    }

    void add(std::span<const uint8_t> bytes)
    {
        add(bytes.size());
        size_t i = 0;
        for (; i + 8 <= bytes.size(); i += 8) {
            uint64_t word = 0;
            for (unsigned j = 0; j < 8; ++j)
                word |= static_cast<uint64_t>(bytes[i + j]) << (8 * j);
            add(word);
        }
        for (; i < bytes.size(); ++i)
            add(bytes[i]);
    }
};

struct EncodedImage {
    Ref<SharedBuffer> data;
    ASCIILiteral mimeType;
};

// The data a page receives for each image: either one buffer, or the growing prefixes of the file as network data
// arrives (the last one is the whole file).
struct Input {
    Vector<EncodedImage> images;
    Vector<Ref<SharedBuffer>> chunkedPrefixes;
    size_t bytes { 0 };
};

using PaletteColor = std::array<uint8_t, 3>;

static void appendBytes(Vector<uint8_t>& data, std::initializer_list<uint8_t> bytes)
{
    data.appendList(bytes);
}

static void append16(Vector<uint8_t>& data, uint32_t value)
{
    data.append(value & 0xff);
    data.append((value >> 8) & 0xff);
}

static void append32(Vector<uint8_t>& data, uint32_t value)
{
    append16(data, value & 0xffff);
    append16(data, value >> 16);
}

static void put16(Vector<uint8_t>& data, size_t offset, uint32_t value)
{
    data[offset] = value & 0xff;
    data[offset + 1] = (value >> 8) & 0xff;
}

static void put32(Vector<uint8_t>& data, size_t offset, uint32_t value)
{
    for (unsigned i = 0; i < 4; ++i)
        data[offset + i] = (value >> (8 * i)) & 0xff;
}

static Vector<PaletteColor> randomPalette(Generator& generator, unsigned size)
{
    Vector<PaletteColor> palette;
    for (unsigned i = 0; i < size; ++i)
        palette.append({ static_cast<uint8_t>(generator.next()), static_cast<uint8_t>(generator.next()), static_cast<uint8_t>(generator.next()) });
    return palette;
}

// GIF

// The LZW code stream of a GIF image: the minimum code size byte, then the codes in data sub-blocks. A clear code
// starts the stream and is sent again whenever the table fills.
static void appendLZW(Vector<uint8_t>& out, std::span<const uint8_t> indices, unsigned minimumCodeSize)
{
    const unsigned clearCode = 1u << minimumCodeSize;
    const unsigned endCode = clearCode + 1;
    constexpr unsigned tableSize = 1 << 14;
    Vector<uint32_t> keys(FillWith { }, tableSize, 0);
    Vector<uint16_t> codes(FillWith { }, tableSize, 0);

    Vector<uint8_t> packed;
    uint32_t bitBuffer = 0;
    unsigned bitCount = 0;
    auto emit = [&](unsigned code, unsigned size) {
        bitBuffer |= code << bitCount;
        bitCount += size;
        while (bitCount >= 8) {
            packed.append(bitBuffer & 0xff);
            bitBuffer >>= 8;
            bitCount -= 8;
        }
    };

    unsigned codeSize = minimumCodeSize + 1;
    unsigned nextCode = clearCode + 2;
    emit(clearCode, codeSize);
    if (!indices.empty()) {
        unsigned prefix = indices[0];
        for (size_t i = 1; i < indices.size(); ++i) {
            uint32_t key = ((prefix << 8) | indices[i]) + 1;
            unsigned slot = (key * 2654435761u) >> 18;
            while (keys[slot] && keys[slot] != key)
                slot = (slot + 1) & (tableSize - 1);
            if (keys[slot] == key) {
                prefix = codes[slot];
                continue;
            }
            emit(prefix, codeSize);
            keys[slot] = key;
            codes[slot] = static_cast<uint16_t>(nextCode++);
            // The decoder defines each code one code later, so it widens the code size one code later too.
            if (nextCode - 1 == (1u << codeSize) && codeSize < 12)
                ++codeSize;
            if (nextCode == 4096) {
                emit(clearCode, codeSize);
                keys.fill(0);
                codeSize = minimumCodeSize + 1;
                nextCode = clearCode + 2;
            }
            prefix = indices[i];
        }
        emit(prefix, codeSize);
        if (nextCode == (1u << codeSize) && codeSize < 12)
            ++codeSize;
    }
    emit(endCode, codeSize);
    if (bitCount)
        packed.append(bitBuffer & 0xff);

    out.append(minimumCodeSize);
    for (size_t offset = 0; offset < packed.size(); offset += 255) {
        size_t length = std::min<size_t>(255, packed.size() - offset);
        out.append(length);
        out.append(packed.subspan(offset, length));
    }
    out.append(0);
}

static unsigned colorTableBits(size_t size)
{
    unsigned bits = 1;
    while ((1u << bits) < size)
        ++bits;
    return bits;
}

static void appendColorTable(Vector<uint8_t>& data, const Vector<PaletteColor>& palette)
{
    for (auto& color : palette)
        appendBytes(data, { color[0], color[1], color[2] });
}

static void appendGIFHeader(Vector<uint8_t>& data, unsigned width, unsigned height, const Vector<PaletteColor>& palette)
{
    appendBytes(data, { 'G', 'I', 'F', '8', '9', 'a' });
    append16(data, width);
    append16(data, height);
    data.append(0x80 | 0x70 | (colorTableBits(palette.size()) - 1));
    data.append(0); // Background colour index.
    data.append(0); // Pixel aspect ratio.
    appendColorTable(data, palette);
}

static void appendLoopExtension(Vector<uint8_t>& data, unsigned loopCount)
{
    appendBytes(data, { 0x21, 0xff, 11, 'N', 'E', 'T', 'S', 'C', 'A', 'P', 'E', '2', '.', '0', 3, 1 });
    append16(data, loopCount);
    data.append(0);
}

struct GIFFrame {
    unsigned x { 0 };
    unsigned y { 0 };
    unsigned width { 0 };
    unsigned height { 0 };
    unsigned disposalMethod { 1 };
    unsigned delay { 0 };
    std::optional<uint8_t> transparentIndex;
    bool interlaced { false };
    Vector<PaletteColor> localPalette;
    // Colour indices, row by row from the top.
    Vector<uint8_t> indices;
};

static void appendGIFFrame(Vector<uint8_t>& data, const GIFFrame& frame, unsigned paletteSize)
{
    appendBytes(data, { 0x21, 0xf9, 4 });
    data.append((frame.disposalMethod << 2) | (frame.transparentIndex ? 1 : 0));
    append16(data, frame.delay);
    data.append(frame.transparentIndex.value_or(0));
    data.append(0);

    data.append(0x2c);
    append16(data, frame.x);
    append16(data, frame.y);
    append16(data, frame.width);
    append16(data, frame.height);
    uint8_t flags = frame.interlaced ? 0x40 : 0;
    if (!frame.localPalette.isEmpty()) {
        flags |= 0x80 | (colorTableBits(frame.localPalette.size()) - 1);
        paletteSize = frame.localPalette.size();
    }
    data.append(flags);
    appendColorTable(data, frame.localPalette);

    std::span<const uint8_t> indices = frame.indices.span();
    Vector<uint8_t> interlacedIndices;
    if (frame.interlaced) {
        static constexpr std::array<std::pair<unsigned, unsigned>, 4> passes { { { 0, 8 }, { 4, 8 }, { 2, 4 }, { 1, 2 } } };
        for (auto [start, step] : passes) {
            for (unsigned row = start; row < frame.height; row += step)
                interlacedIndices.append(frame.indices.subspan(row * frame.width, frame.width));
        }
        indices = interlacedIndices.span();
    }
    appendLZW(data, indices, std::max(2u, colorTableBits(paletteSize)));
}

// Indices that follow a gradient with some noise, so the LZW table holds a mix of short and long strings.
static Vector<uint8_t> gradientIndices(Generator& generator, unsigned width, unsigned height, unsigned paletteSize, unsigned noiseBits)
{
    Vector<uint8_t> indices;
    indices.reserveInitialCapacity(width * height);
    for (unsigned y = 0; y < height; ++y) {
        for (unsigned x = 0; x < width; ++x)
            indices.append(((x >> 3) + (y >> 3) + (generator.next() & ((1u << noiseBits) - 1))) % paletteSize);
    }
    return indices;
}

static Ref<SharedBuffer> makeGIF(unsigned width, unsigned height, const Vector<PaletteColor>& palette, const Vector<GIFFrame>& frames, std::optional<unsigned> loopCount)
{
    Vector<uint8_t> data;
    appendGIFHeader(data, width, height, palette);
    if (loopCount)
        appendLoopExtension(data, *loopCount);
    for (auto& frame : frames)
        appendGIFFrame(data, frame, palette.size());
    data.append(0x3b);
    return SharedBuffer::create(WTF::move(data));
}

static Input singleImage(Ref<SharedBuffer>&& data, ASCIILiteral mimeType)
{
    Input input;
    input.bytes = data->size();
    input.images.append({ WTF::move(data), mimeType });
    return input;
}

static Input largeGIFInput()
{
    Generator generator(0x4c474946);
    auto palette = randomPalette(generator, 256);
    GIFFrame frame;
    frame.width = 2048;
    frame.height = 2048;
    frame.indices = gradientIndices(generator, frame.width, frame.height, 256, 3);
    return singleImage(makeGIF(2048, 2048, palette, { WTF::move(frame) }, std::nullopt), "image/gif"_s);
}

// Sub-rectangle frames over a 512x512 canvas, cycling through the three disposal methods, with transparent pixels
// and a local colour table on every fourth frame.
static Input animatedGIFInput()
{
    Generator generator(0x414e494d);
    auto palette = randomPalette(generator, 256);
    Vector<GIFFrame> frames;
    for (unsigned i = 0; i < 40; ++i) {
        GIFFrame frame;
        if (!i) {
            frame.width = 512;
            frame.height = 512;
        } else {
            frame.width = 64 + generator.below(257);
            frame.height = 64 + generator.below(257);
            frame.x = generator.below(512 - frame.width + 1);
            frame.y = generator.below(512 - frame.height + 1);
            frame.disposalMethod = 1 + i % 3;
            frame.transparentIndex = 0;
        }
        frame.delay = 5 + generator.below(8);
        if (!(i % 4) && i)
            frame.localPalette = randomPalette(generator, 256);
        frame.indices = gradientIndices(generator, frame.width, frame.height, 256, 2);
        if (frame.transparentIndex) {
            for (auto& index : frame.indices) {
                if (!(generator.next() & 7))
                    index = *frame.transparentIndex;
            }
        }
        frames.append(WTF::move(frame));
    }
    return singleImage(makeGIF(512, 512, palette, frames, 0), "image/gif"_s);
}

// An interlaced GIF received 64 KB at a time, with frame 0 drawn after each chunk.
static Input interlacedGIFInput()
{
    Generator generator(0x494e544c);
    auto palette = randomPalette(generator, 256);
    GIFFrame frame;
    frame.width = 1024;
    frame.height = 1024;
    frame.interlaced = true;
    frame.indices = gradientIndices(generator, frame.width, frame.height, 256, 3);
    auto file = makeGIF(1024, 1024, palette, { WTF::move(frame) }, std::nullopt);

    Input input;
    input.bytes = file->size();
    constexpr size_t chunkSize = 64 * 1024;
    for (size_t end = chunkSize; end < file->size(); end += chunkSize)
        input.chunkedPrefixes.append(SharedBuffer::create(file->span().first(end)));
    input.chunkedPrefixes.append(WTF::move(file));
    return input;
}

// Small GIFs of assorted sizes and palettes, each a new decoder, as on a page of icons.
static Input manySmallGIFsInput()
{
    Generator generator(0x534d4c47);
    Input input;
    static constexpr std::array<unsigned, 4> paletteSizes { 2, 4, 16, 256 };
    for (unsigned i = 0; i < 2000; ++i) {
        unsigned width = 16 + generator.below(17);
        unsigned height = 16 + generator.below(17);
        auto palette = randomPalette(generator, paletteSizes[i % paletteSizes.size()]);
        GIFFrame frame;
        frame.width = width;
        frame.height = height;
        if (i % 3)
            frame.transparentIndex = 0;
        frame.indices = gradientIndices(generator, width, height, palette.size(), 1);
        auto data = makeGIF(width, height, palette, { WTF::move(frame) }, std::nullopt);
        input.bytes += data->size();
        input.images.append({ WTF::move(data), "image/gif"_s });
    }
    return input;
}

// BMP

static void appendBMPFileHeader(Vector<uint8_t>& data)
{
    appendBytes(data, { 'B', 'M' });
    append32(data, 0); // File size, filled in by finishBMPFile().
    append32(data, 0);
    append32(data, 0); // Pixel data offset, filled in by finishBMPFile().
}

static void finishBMPFile(Vector<uint8_t>& data, size_t pixelDataOffset)
{
    put32(data, 2, data.size());
    put32(data, 10, pixelDataOffset);
}

static void appendInfoHeader(Vector<uint8_t>& data, int32_t width, int32_t height, unsigned bitCount, unsigned compression, unsigned colorsUsed)
{
    append32(data, 40);
    append32(data, width);
    append32(data, height);
    append16(data, 1);
    append16(data, bitCount);
    append32(data, compression);
    append32(data, 0); // Image size.
    append32(data, 2835);
    append32(data, 2835);
    append32(data, colorsUsed);
    append32(data, 0);
}

static void appendBMPPalette(Vector<uint8_t>& data, const Vector<PaletteColor>& palette)
{
    for (auto& color : palette)
        appendBytes(data, { color[2], color[1], color[0], 0 });
}

static uint8_t gradientNoise(Generator& generator, unsigned x, unsigned y, unsigned scale)
{
    return ((x * scale) >> 4) + ((y * scale) >> 5) + (generator.next() & 15);
}

static Input bmp24Input()
{
    Generator generator(0x42323420);
    constexpr unsigned size = 2048;
    Vector<uint8_t> data;
    appendBMPFileHeader(data);
    appendInfoHeader(data, size, size, 24, 0, 0);
    size_t pixelDataOffset = data.size();
    data.reserveCapacity(pixelDataOffset + size * size * 3);
    for (unsigned y = 0; y < size; ++y) {
        for (unsigned x = 0; x < size; ++x)
            appendBytes(data, { gradientNoise(generator, x, y, 1), gradientNoise(generator, y, x, 3), gradientNoise(generator, x + y, y, 2) });
    }
    finishBMPFile(data, pixelDataOffset);
    return singleImage(SharedBuffer::create(WTF::move(data)), "image/bmp"_s);
}

// A top-down 32-bit BITFIELDS BMP with a V5 header, channel masks in R, G, B, A byte order, and partial alpha.
static Input bmp32BitmaskInput()
{
    Generator generator(0x42334d4b);
    constexpr unsigned size = 2048;
    Vector<uint8_t> data;
    appendBMPFileHeader(data);
    append32(data, 124);
    append32(data, size);
    append32(data, -static_cast<int32_t>(size));
    append16(data, 1);
    append16(data, 32);
    append32(data, 3); // BI_BITFIELDS.
    append32(data, size * size * 4);
    append32(data, 2835);
    append32(data, 2835);
    append32(data, 0);
    append32(data, 0);
    append32(data, 0x000000ff);
    append32(data, 0x0000ff00);
    append32(data, 0x00ff0000);
    append32(data, 0xff000000);
    append32(data, 0x73524742); // LCS_sRGB.
    for (unsigned i = 0; i < 12; ++i)
        append32(data, 0); // Endpoints and gamma.
    append32(data, 4); // LCS_GM_IMAGES.
    append32(data, 0);
    append32(data, 0);
    append32(data, 0);
    size_t pixelDataOffset = data.size();
    data.reserveCapacity(pixelDataOffset + size * size * 4);
    for (unsigned y = 0; y < size; ++y) {
        for (unsigned x = 0; x < size; ++x) {
            uint8_t alpha;
            switch (generator.below(4)) {
            case 0:
                alpha = 255;
                break;
            case 1:
                alpha = (x || y) ? 0 : 255;
                break;
            default:
                alpha = gradientNoise(generator, x, y, 1);
                break;
            }
            appendBytes(data, { gradientNoise(generator, x, y, 1), gradientNoise(generator, y, x, 3), gradientNoise(generator, x + y, y, 2), alpha });
        }
    }
    finishBMPFile(data, pixelDataOffset);
    return singleImage(SharedBuffer::create(WTF::move(data)), "image/bmp"_s);
}

// An RLE8 BMP whose rows mix encoded runs, absolute runs and deltas, each row ended by an end-of-line marker.
static Input bmpRLE8Input()
{
    Generator generator(0x524c4538);
    constexpr unsigned size = 2048;
    Vector<uint8_t> data;
    appendBMPFileHeader(data);
    appendInfoHeader(data, size, size, 8, 1, 256);
    appendBMPPalette(data, randomPalette(generator, 256));
    size_t pixelDataOffset = data.size();
    for (unsigned y = 0; y < size; ++y) {
        unsigned x = 0;
        while (x < size) {
            unsigned remaining = size - x;
            unsigned kind = generator.below(16);
            if (kind < 9) {
                unsigned length = std::min(remaining, 1 + generator.below(64));
                appendBytes(data, { static_cast<uint8_t>(length), static_cast<uint8_t>(((x + y) >> 4) + generator.below(4)) });
                x += length;
            } else if (kind < 15 && remaining >= 3) {
                unsigned length = std::min(remaining, 3 + generator.below(60));
                appendBytes(data, { 0, static_cast<uint8_t>(length) });
                for (unsigned i = 0; i < length; ++i)
                    data.append(((x + i + y) >> 4) + generator.below(8));
                if (length & 1)
                    data.append(0);
                x += length;
            } else {
                unsigned length = std::min(remaining, 1 + generator.below(16));
                appendBytes(data, { 0, 2, static_cast<uint8_t>(length), 0 });
                x += length;
            }
        }
        appendBytes(data, { 0, 0 });
    }
    appendBytes(data, { 0, 1 });
    finishBMPFile(data, pixelDataOffset);
    return singleImage(SharedBuffer::create(WTF::move(data)), "image/bmp"_s);
}

// ICO

// A BMP icon entry: the info header with the height of the colour and mask bitmaps together, the palette, the
// colour bitmap and a 1-bit AND mask, both bottom-up.
static Vector<uint8_t> makeIconBMP(Generator& generator, unsigned size, unsigned bitCount)
{
    Vector<uint8_t> data;
    unsigned colors = bitCount <= 8 ? 1u << bitCount : 0;
    appendInfoHeader(data, size, size * 2, bitCount, 0, colors);
    if (colors)
        appendBMPPalette(data, randomPalette(generator, colors));
    unsigned rowBytes = ((size * bitCount + 31) / 32) * 4;
    int center = size / 2;
    for (unsigned y = 0; y < size; ++y) {
        Vector<uint8_t> row;
        for (unsigned x = 0; x < size; ++x) {
            switch (bitCount) {
            case 1:
                if (!(x & 7))
                    row.append(0);
                row.last() |= (((x >> 2) + (y >> 2)) & 1) << (7 - (x & 7));
                break;
            case 4:
                if (!(x & 1))
                    row.append(((x + y) & 15) << 4);
                else
                    row.last() |= generator.below(16);
                break;
            case 8:
                row.append(((x + y) >> 1) + generator.below(4));
                break;
            case 24:
                appendBytes(row, { static_cast<uint8_t>(x * 255 / size), static_cast<uint8_t>(y * 255 / size), static_cast<uint8_t>(generator.next()) });
                break;
            case 32: {
                int dx = static_cast<int>(x) - center;
                int dy = static_cast<int>(y) - center;
                unsigned distance = dx * dx + dy * dy;
                unsigned radius = center * center;
                uint8_t alpha = distance >= radius ? 0 : 255 - distance * 255 / radius;
                appendBytes(row, { static_cast<uint8_t>(x * 255 / size), static_cast<uint8_t>(y * 255 / size), static_cast<uint8_t>(generator.next()), alpha });
                break;
            }
            }
        }
        row.resize(rowBytes);
        data.append(row.span());
    }
    unsigned maskRowBytes = ((size + 31) / 32) * 4;
    for (unsigned y = 0; y < size; ++y) {
        Vector<uint8_t> row(FillWith { }, maskRowBytes, 0);
        for (unsigned x = 0; x < size; ++x) {
            int dx = static_cast<int>(x) - center;
            int dy = static_cast<int>(y) - center;
            if (dx * dx + dy * dy >= center * center)
                row[x / 8] |= 0x80 >> (x % 8);
        }
        data.append(row.span());
    }
    return data;
}

static void appendBigEndian32(Vector<uint8_t>& data, uint32_t value)
{
    appendBytes(data, { static_cast<uint8_t>(value >> 24), static_cast<uint8_t>(value >> 16), static_cast<uint8_t>(value >> 8), static_cast<uint8_t>(value) });
}

static uint32_t pngCRC32(std::span<const uint8_t> data)
{
    uint32_t crc = 0xffffffff;
    for (auto byte : data) {
        crc ^= byte;
        for (int bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ (0xedb88320 & (~(crc & 1) + 1));
    }
    return crc ^ 0xffffffff;
}

static void appendPNGChunk(Vector<uint8_t>& data, const char (&type)[5], std::span<const uint8_t> payload)
{
    appendBigEndian32(data, payload.size());
    Vector<uint8_t> typed { static_cast<uint8_t>(type[0]), static_cast<uint8_t>(type[1]), static_cast<uint8_t>(type[2]), static_cast<uint8_t>(type[3]) };
    typed.append(payload);
    data.append(typed.span());
    appendBigEndian32(data, pngCRC32(typed.span()));
}

// A PNG icon entry: 8-bit RGBA in a zlib stream of stored blocks.
static Vector<uint8_t> makeIconPNG(Generator& generator, unsigned size)
{
    Vector<uint8_t> raw;
    for (unsigned y = 0; y < size; ++y) {
        raw.append(0);
        for (unsigned x = 0; x < size; ++x)
            appendBytes(raw, { static_cast<uint8_t>(x), static_cast<uint8_t>(y), static_cast<uint8_t>(generator.next()), static_cast<uint8_t>(x ^ y) });
    }

    Vector<uint8_t> stream { 0x78, 0x01 };
    for (size_t offset = 0; offset < raw.size(); offset += 65535) {
        size_t length = std::min<size_t>(65535, raw.size() - offset);
        stream.append(offset + length == raw.size() ? 1 : 0);
        appendBytes(stream, { static_cast<uint8_t>(length), static_cast<uint8_t>(length >> 8), static_cast<uint8_t>(~length), static_cast<uint8_t>(~length >> 8) });
        stream.append(raw.subspan(offset, length));
    }
    uint32_t s1 = 1, s2 = 0;
    for (auto byte : raw) {
        s1 = (s1 + byte) % 65521;
        s2 = (s2 + s1) % 65521;
    }
    appendBigEndian32(stream, (s2 << 16) | s1);

    Vector<uint8_t> data { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    Vector<uint8_t> header;
    appendBigEndian32(header, size);
    appendBigEndian32(header, size);
    appendBytes(header, { 8, 6, 0, 0, 0 });
    appendPNGChunk(data, "IHDR", header.span());
    appendPNGChunk(data, "IDAT", stream.span());
    appendPNGChunk(data, "IEND", { });
    return data;
}

// An icon with BMP entries of six sizes at 4, 8 and 32 bits, and a 256x256 PNG entry.
static Input icoMultiSizeInput()
{
    Generator generator(0x49434f4d);
    static constexpr std::array<std::pair<unsigned, unsigned>, 6> bmpEntries { { { 16, 4 }, { 24, 8 }, { 32, 32 }, { 48, 4 }, { 64, 8 }, { 128, 32 } } };
    Vector<std::tuple<unsigned, unsigned, Vector<uint8_t>>> entries;
    for (auto [size, bitCount] : bmpEntries)
        entries.append({ size, bitCount, makeIconBMP(generator, size, bitCount) });
    entries.append({ 256, 32, makeIconPNG(generator, 256) });

    Vector<uint8_t> data;
    append16(data, 0);
    append16(data, 1);
    append16(data, entries.size());
    size_t offset = 6 + 16 * entries.size();
    for (auto& [size, bitCount, bytes] : entries) {
        data.append(size & 0xff);
        data.append(size & 0xff);
        data.append(bitCount == 4 ? 16 : 0);
        data.append(0);
        append16(data, 1);
        append16(data, bitCount);
        append32(data, bytes.size());
        append32(data, offset);
        offset += bytes.size();
    }
    for (auto& entry : entries)
        data.append(std::get<2>(entry).span());
    return singleImage(SharedBuffer::create(WTF::move(data)), "image/x-icon"_s);
}

static void appendImage(Input& input, Vector<uint8_t>&& data, ASCIILiteral mimeType)
{
    input.bytes += data.size();
    input.images.append({ SharedBuffer::create(WTF::move(data)), mimeType });
}

// More BMP

static void padBMPRow(Vector<uint8_t>& data, size_t rowStart)
{
    while ((data.size() - rowStart) & 3)
        data.append(0);
}

// An uncompressed paletted BMP whose indices stay below colorsUsed. A negative height makes it top-down.
static Vector<uint8_t> makePalettedBMP(Generator& generator, unsigned width, int32_t height, unsigned bitCount, unsigned colorsUsed)
{
    Vector<uint8_t> data;
    appendBMPFileHeader(data);
    appendInfoHeader(data, width, height, bitCount, 0, colorsUsed);
    appendBMPPalette(data, randomPalette(generator, colorsUsed));
    size_t pixelDataOffset = data.size();
    unsigned rows = height < 0 ? -height : height;
    for (unsigned y = 0; y < rows; ++y) {
        size_t rowStart = data.size();
        unsigned bits = 0;
        uint8_t byte = 0;
        for (unsigned x = 0; x < width; ++x) {
            unsigned index = ((x >> 4) + (y >> 3) + generator.below(3)) % colorsUsed;
            byte = (byte << bitCount) | index;
            bits += bitCount;
            if (bits == 8) {
                data.append(byte);
                byte = 0;
                bits = 0;
            }
        }
        if (bits)
            data.append(byte << (8 - bits));
        padBMPRow(data, rowStart);
    }
    finishBMPFile(data, pixelDataOffset);
    return data;
}

// A 16-bit BMP: 5-5-5 with the default masks and noise in the unused top bit, or 5-6-5 with BITFIELDS masks after
// the info header.
static Vector<uint8_t> make16BitBMP(Generator& generator, unsigned width, unsigned height, bool rgb565)
{
    Vector<uint8_t> data;
    appendBMPFileHeader(data);
    appendInfoHeader(data, width, height, 16, rgb565 ? 3 : 0, 0);
    if (rgb565) {
        append32(data, 0xf800);
        append32(data, 0x07e0);
        append32(data, 0x001f);
    }
    size_t pixelDataOffset = data.size();
    for (unsigned y = 0; y < height; ++y) {
        size_t rowStart = data.size();
        for (unsigned x = 0; x < width; ++x) {
            unsigned red = gradientNoise(generator, x, y, 1) >> 3;
            unsigned green = gradientNoise(generator, y, x, 3) >> (rgb565 ? 2 : 3);
            unsigned blue = gradientNoise(generator, x + y, y, 2) >> 3;
            unsigned unused = generator.next() & 0x8000;
            append16(data, rgb565 ? ((red << 11) | (green << 5) | blue) : (unused | (red << 10) | (green << 5) | blue));
        }
        padBMPRow(data, rowStart);
    }
    finishBMPFile(data, pixelDataOffset);
    return data;
}

// An RLE4 BMP whose rows mix encoded runs of two alternating indices, absolute runs and deltas, each row ended by an
// end-of-line marker.
static Vector<uint8_t> makeRLE4BMP(Generator& generator, unsigned width, unsigned height)
{
    Vector<uint8_t> data;
    appendBMPFileHeader(data);
    appendInfoHeader(data, width, height, 4, 2, 16);
    appendBMPPalette(data, randomPalette(generator, 16));
    size_t pixelDataOffset = data.size();
    for (unsigned y = 0; y < height; ++y) {
        unsigned x = 0;
        while (x < width) {
            unsigned remaining = width - x;
            unsigned kind = generator.below(16);
            if (kind < 9) {
                unsigned length = std::min(remaining, 1 + generator.below(48));
                uint8_t first = ((x + y) >> 4) & 15;
                uint8_t second = generator.below(16);
                appendBytes(data, { static_cast<uint8_t>(length), static_cast<uint8_t>((first << 4) | second) });
                x += length;
            } else if (kind < 15 && remaining >= 3) {
                unsigned length = std::min(remaining, 3 + generator.below(40));
                appendBytes(data, { 0, static_cast<uint8_t>(length) });
                size_t runStart = data.size();
                for (unsigned i = 0; i < length; ++i) {
                    uint8_t index = (((x + i + y) >> 3) + generator.below(4)) & 15;
                    if (!(i & 1))
                        data.append(index << 4);
                    else
                        data.last() |= index;
                }
                if ((data.size() - runStart) & 1)
                    data.append(0);
                x += length;
            } else {
                unsigned length = std::min(remaining, 1 + generator.below(16));
                appendBytes(data, { 0, 2, static_cast<uint8_t>(length), 0 });
                x += length;
            }
        }
        appendBytes(data, { 0, 0 });
    }
    appendBytes(data, { 0, 1 });
    finishBMPFile(data, pixelDataOffset);
    return data;
}

// An RLE24 BMP (OS/2 2.x compression 4) with encoded BGR runs, absolute runs and deltas, which ends with an
// end-of-bitmap marker an eighth of the rows early.
static Vector<uint8_t> makeRLE24BMP(Generator& generator, unsigned width, unsigned height)
{
    Vector<uint8_t> data;
    appendBMPFileHeader(data);
    appendInfoHeader(data, width, height, 24, 4, 0);
    size_t pixelDataOffset = data.size();
    for (unsigned y = 0; y < height - height / 8; ++y) {
        unsigned x = 0;
        while (x < width) {
            unsigned remaining = width - x;
            unsigned kind = generator.below(16);
            if (kind < 9) {
                unsigned length = std::min(remaining, 1 + generator.below(64));
                appendBytes(data, { static_cast<uint8_t>(length), gradientNoise(generator, x, y, 1), gradientNoise(generator, y, x, 3), gradientNoise(generator, x + y, y, 2) });
                x += length;
            } else if (kind < 15 && remaining >= 3) {
                unsigned length = std::min(remaining, 3 + generator.below(40));
                appendBytes(data, { 0, static_cast<uint8_t>(length) });
                for (unsigned i = 0; i < length; ++i)
                    appendBytes(data, { gradientNoise(generator, x + i, y, 1), gradientNoise(generator, y, x + i, 3), gradientNoise(generator, x + i + y, y, 2) });
                if (length & 1)
                    data.append(0);
                x += length;
            } else {
                unsigned length = std::min(remaining, 1 + generator.below(16));
                appendBytes(data, { 0, 2, static_cast<uint8_t>(length), 0 });
                x += length;
            }
        }
        appendBytes(data, { 0, 0 });
    }
    appendBytes(data, { 0, 1 });
    finishBMPFile(data, pixelDataOffset);
    return data;
}

// Paletted 1-, 4- and 8-bit BMPs (the 8-bit one top-down, the 4-bit one with a short colour table), 16-bit 5-5-5
// and 5-6-5, RLE4 and RLE24.
static Input bmpOtherDepthsInput()
{
    Generator generator(0x424d4f44);
    Input input;
    appendImage(input, makePalettedBMP(generator, 1023, 700, 1, 2), "image/bmp"_s);
    appendImage(input, makePalettedBMP(generator, 1001, 650, 4, 12), "image/bmp"_s);
    appendImage(input, makePalettedBMP(generator, 777, -600, 8, 256), "image/bmp"_s);
    appendImage(input, make16BitBMP(generator, 900, 600, false), "image/bmp"_s);
    appendImage(input, make16BitBMP(generator, 899, 601, true), "image/bmp"_s);
    appendImage(input, makeRLE4BMP(generator, 1024, 700), "image/bmp"_s);
    appendImage(input, makeRLE24BMP(generator, 800, 600), "image/bmp"_s);
    return input;
}

// ICO and CUR files

struct IconEntry {
    unsigned size { 0 };
    unsigned colorCount { 0 };
    // Planes and bit count in an icon, the hot spot in a cursor.
    unsigned field1 { 0 };
    unsigned field2 { 0 };
    Vector<uint8_t> bytes;
    std::optional<uint32_t> offset;
};

static Vector<uint8_t> makeIconFile(unsigned type, const Vector<IconEntry>& entries)
{
    Vector<uint8_t> data;
    append16(data, 0);
    append16(data, type);
    append16(data, entries.size());
    size_t offset = 6 + 16 * entries.size();
    for (auto& entry : entries) {
        data.append(entry.size & 0xff);
        data.append(entry.size & 0xff);
        data.append(entry.colorCount);
        data.append(0);
        append16(data, entry.field1);
        append16(data, entry.field2);
        append32(data, entry.bytes.size());
        append32(data, entry.offset.value_or(offset));
        offset += entry.bytes.size();
    }
    for (auto& entry : entries)
        data.append(entry.bytes.span());
    return data;
}

// A cursor with BMP entries of five sizes at 1, 4, 8, 24 and 32 bits, each with its own hot spot.
static Input icoCursorInput()
{
    Generator generator(0x43555253);
    static constexpr std::array<std::tuple<unsigned, unsigned, unsigned, unsigned>, 5> cursorEntries { { { 32, 1, 3, 5 }, { 48, 4, 24, 24 }, { 64, 8, 0, 63 }, { 96, 24, 90, 7 }, { 128, 32, 64, 10 } } };
    Vector<IconEntry> entries;
    for (auto [size, bitCount, hotSpotX, hotSpotY] : cursorEntries)
        entries.append({ size, bitCount <= 8 ? (1u << bitCount) & 0xff : 0, hotSpotX, hotSpotY, makeIconBMP(generator, size, bitCount), std::nullopt });
    return singleImage(SharedBuffer::create(makeIconFile(2, entries)), "image/x-icon"_s);
}

// Malformed images

static Vector<uint8_t> prefixOf(const Vector<uint8_t>& data, size_t length)
{
    return Vector<uint8_t>(data.span().first(length));
}

static void appendMalformedGIFs(Input& input, Generator& generator)
{
    constexpr unsigned width = 192;
    constexpr unsigned height = 160;
    auto palette = randomPalette(generator, 16);
    GIFFrame first;
    first.width = width;
    first.height = height;
    first.delay = 4;
    first.indices = gradientIndices(generator, width, height, 16, 2);
    GIFFrame second;
    second.x = 40;
    second.y = 30;
    second.width = 64;
    second.height = 48;
    second.disposalMethod = 2;
    second.delay = 7;
    second.transparentIndex = 0;
    second.indices = gradientIndices(generator, second.width, second.height, 16, 2);

    Vector<uint8_t> gif;
    appendGIFHeader(gif, width, height, palette);
    size_t framesStart = gif.size();
    appendGIFFrame(gif, first, 16);
    size_t secondFrameStart = gif.size();
    appendGIFFrame(gif, second, 16);
    gif.append(0x3b);
    // The first frame's image descriptor follows its 8-byte graphic control extension.
    size_t descriptor = framesStart + 8;

    // Truncated twice in the colour table, in a graphic control extension, and in each frame's image data.
    appendImage(input, prefixOf(gif, 14), "image/gif"_s);
    appendImage(input, prefixOf(gif, 40), "image/gif"_s);
    appendImage(input, prefixOf(gif, framesStart + 5), "image/gif"_s);
    appendImage(input, prefixOf(gif, (framesStart + secondFrameStart) / 2), "image/gif"_s);
    appendImage(input, prefixOf(gif, gif.size() - 20), "image/gif"_s);

    // A GIF87a file, whose first frame sets the screen size.
    Vector<uint8_t> version87;
    appendGIFHeader(version87, width, height, palette);
    version87[4] = '7';
    appendGIFFrame(version87, second, 16);
    version87.append(0x3b);
    appendImage(input, WTF::move(version87), "image/gif"_s);

    // A zero-sized screen and first frame.
    auto zeroSize = gif;
    put32(zeroSize, 6, 0);
    put32(zeroSize, descriptor + 5, 0);
    appendImage(input, WTF::move(zeroSize), "image/gif"_s);

    // A minimum LZW code size of 12.
    auto badCodeSize = gif;
    badCodeSize[descriptor + 10] = 12;
    appendImage(input, WTF::move(badCodeSize), "image/gif"_s);

    // An unknown NETSCAPE2.0 sub-block.
    Vector<uint8_t> badLoop;
    appendGIFHeader(badLoop, width, height, palette);
    appendBytes(badLoop, { 0x21, 0xff, 11, 'N', 'E', 'T', 'S', 'C', 'A', 'P', 'E', '2', '.', '0', 3, 3, 0, 0, 0 });
    appendGIFFrame(badLoop, first, 16);
    badLoop.append(0x3b);
    appendImage(input, WTF::move(badLoop), "image/gif"_s);

    // An end-of-information code before the last row.
    GIFFrame shortFrame = first;
    shortFrame.indices.shrink(width * 100);
    Vector<uint8_t> earlyEnd;
    appendGIFHeader(earlyEnd, width, height, palette);
    appendGIFFrame(earlyEnd, shortFrame, 16);
    appendGIFFrame(earlyEnd, second, 16);
    earlyEnd.append(0x3b);
    appendImage(input, WTF::move(earlyEnd), "image/gif"_s);

    // Stray bytes between the frames, where the trailer ends the file.
    Vector<uint8_t> strayBytes;
    appendGIFHeader(strayBytes, width, height, palette);
    appendGIFFrame(strayBytes, first, 16);
    appendBytes(strayBytes, { 'x', 0, 0 });
    appendGIFFrame(strayBytes, second, 16);
    strayBytes.append(0x3b);
    appendImage(input, WTF::move(strayBytes), "image/gif"_s);

    // No colour table at all.
    Vector<uint8_t> noColorTable { 'G', 'I', 'F', '8', '9', 'a' };
    append16(noColorTable, width);
    append16(noColorTable, height);
    appendBytes(noColorTable, { 0, 0, 0 });
    appendGIFFrame(noColorTable, first, 16);
    noColorTable.append(0x3b);
    appendImage(input, WTF::move(noColorTable), "image/gif"_s);

    // A first frame larger than the screen, and a second frame that extends past it.
    GIFFrame outside = second;
    outside.x = width - 20;
    outside.y = height - 10;
    Vector<uint8_t> overflowingFrames;
    appendGIFHeader(overflowingFrames, 64, 64, palette);
    appendGIFFrame(overflowingFrames, first, 16);
    appendGIFFrame(overflowingFrames, outside, 16);
    overflowingFrames.append(0x3b);
    appendImage(input, WTF::move(overflowingFrames), "image/gif"_s);
}

// Uncompressed BMP header fields, as offsets into the file.
enum BMPField : size_t {
    BMPPixelDataOffset = 10,
    BMPHeaderSize = 14,
    BMPWidth = 18,
    BMPHeight = 22,
    BMPBitCount = 28,
    BMPCompression = 30,
    BMPColorsUsed = 46,
};

static Vector<uint8_t> withField32(const Vector<uint8_t>& data, size_t offset, uint32_t value)
{
    auto copy = data;
    put32(copy, offset, value);
    return copy;
}

// A 64-pixel-wide RLE BMP with the given rows of codes, and an end-of-bitmap marker unless the codes end without one.
static Vector<uint8_t> makeRLEBMP(int32_t height, unsigned bitCount, unsigned compression, unsigned colorsUsed, const Vector<uint8_t>& codes)
{
    Vector<uint8_t> data;
    appendBMPFileHeader(data);
    appendInfoHeader(data, 64, height, bitCount, compression, colorsUsed);
    for (unsigned i = 0; i < colorsUsed; ++i)
        appendBytes(data, { static_cast<uint8_t>(i * 16), static_cast<uint8_t>(255 - i * 16), static_cast<uint8_t>(i * 40), 0 });
    size_t pixelDataOffset = data.size();
    data.append(codes.span());
    finishBMPFile(data, pixelDataOffset);
    return data;
}

// Rows of 64 pixels as two encoded runs, the row given by badRow replaced by badCodes.
static Vector<uint8_t> rleRows(unsigned rows, unsigned badRow, std::initializer_list<uint8_t> badCodes, bool endOfBitmap)
{
    Vector<uint8_t> codes;
    for (unsigned y = 0; y < rows; ++y) {
        if (y == badRow)
            codes.appendList(badCodes);
        else
            appendBytes(codes, { 40, static_cast<uint8_t>(y & 3), 24, static_cast<uint8_t>((y + 1) & 3), 0, 0 });
    }
    if (endOfBitmap)
        appendBytes(codes, { 0, 1 });
    return codes;
}

static void appendMalformedBMPs(Input& input, Generator& generator)
{
    auto paletted = makePalettedBMP(generator, 200, 150, 8, 256);
    constexpr size_t colorTable = 14 + 40;

    // Truncated in the info header, the colour table and the pixel data.
    appendImage(input, prefixOf(paletted, BMPHeaderSize + 20), "image/bmp"_s);
    appendImage(input, prefixOf(paletted, colorTable + 500), "image/bmp"_s);
    appendImage(input, prefixOf(paletted, paletted.size() / 2 + 600), "image/bmp"_s);

    // Header values the decoder rejects.
    appendImage(input, withField32(paletted, BMPHeaderSize, 41), "image/bmp"_s);
    appendImage(input, withField32(paletted, BMPCompression, 7), "image/bmp"_s);
    appendImage(input, withField32(paletted, BMPWidth, 0), "image/bmp"_s);
    appendImage(input, withField32(paletted, BMPWidth, 70000), "image/bmp"_s);
    appendImage(input, withField32(paletted, BMPHeight, 0x80000000), "image/bmp"_s);
    auto badBitCount = paletted;
    put16(badBitCount, BMPBitCount, 7);
    appendImage(input, WTF::move(badBitCount), "image/bmp"_s);
    // Pixel data that starts inside the info header, and inside the colour table.
    appendImage(input, withField32(paletted, BMPPixelDataOffset, 30), "image/bmp"_s);
    appendImage(input, withField32(paletted, BMPPixelDataOffset, colorTable + 100), "image/bmp"_s);
    // A colour table shorter than the indices the upper rows use.
    appendImage(input, withField32(paletted, BMPColorsUsed, 16), "image/bmp"_s);
    // BITFIELDS with 1 bit (Huffman 1D) and 24 bits; JPEG compression.
    auto huffman = withField32(paletted, BMPCompression, 3);
    put16(huffman, BMPBitCount, 1);
    appendImage(input, WTF::move(huffman), "image/bmp"_s);
    auto bitfields24 = withField32(paletted, BMPCompression, 3);
    put16(bitfields24, BMPBitCount, 24);
    appendImage(input, WTF::move(bitfields24), "image/bmp"_s);
    auto jpeg = withField32(paletted, BMPCompression, 4);
    put16(jpeg, BMPBitCount, 0);
    appendImage(input, WTF::move(jpeg), "image/bmp"_s);

    // 5-6-5 BITFIELDS with overlapping and non-contiguous masks, and truncated in the masks.
    auto bitfields = make16BitBMP(generator, 64, 32, true);
    constexpr size_t masks = 14 + 40;
    appendImage(input, withField32(bitfields, masks + 4, 0x0fe0), "image/bmp"_s);
    appendImage(input, withField32(bitfields, masks + 8, 0x0015), "image/bmp"_s);
    appendImage(input, prefixOf(bitfields, masks + 6), "image/bmp"_s);

    // RLE8 with an index past the colour table, a delta and an absolute run past the end of a row, more rows than the
    // image has, codes that end early, and a top-down height.
    appendImage(input, makeRLEBMP(32, 8, 1, 16, rleRows(32, 10, { 8, 20, 0, 0 }, true)), "image/bmp"_s);
    appendImage(input, makeRLEBMP(32, 8, 1, 16, rleRows(32, 5, { 60, 1, 0, 2, 8, 0, 0, 0 }, true)), "image/bmp"_s);
    appendImage(input, makeRLEBMP(32, 8, 1, 16, rleRows(32, 5, { 60, 1, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0 }, true)), "image/bmp"_s);
    appendImage(input, makeRLEBMP(32, 8, 1, 16, rleRows(40, 40, { }, false)), "image/bmp"_s);
    appendImage(input, makeRLEBMP(32, 8, 1, 16, rleRows(20, 20, { }, false)), "image/bmp"_s);
    appendImage(input, makeRLEBMP(-32, 8, 1, 16, rleRows(32, 32, { }, true)), "image/bmp"_s);
    // RLE4 with an index past a four-colour table.
    appendImage(input, makeRLEBMP(32, 4, 2, 4, rleRows(32, 12, { 16, 0x37, 0, 0 }, true)), "image/bmp"_s);
}

static void appendMalformedICOs(Input& input, Generator& generator)
{
    auto bmp32 = makeIconBMP(generator, 32, 8);
    auto bmp16 = makeIconBMP(generator, 16, 4);
    auto png = makeIconPNG(generator, 48);
    auto icon = [&] {
        Vector<IconEntry> entries;
        entries.append({ 32, 0, 1, 8, bmp32, std::nullopt });
        entries.append({ 16, 16, 1, 4, bmp16, std::nullopt });
        entries.append({ 48, 0, 1, 32, png, std::nullopt });
        return entries;
    };

    // No entries.
    Vector<uint8_t> empty;
    append16(empty, 0);
    append16(empty, 1);
    append16(empty, 0);
    appendBytes(empty, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    appendImage(input, WTF::move(empty), "image/x-icon"_s);

    // Truncated in the directory, and in the pixel data of an icon's only BMP entry.
    auto whole = makeIconFile(1, icon());
    appendImage(input, prefixOf(whole, 6 + 16 + 8), "image/x-icon"_s);
    Vector<IconEntry> single;
    single.append({ 32, 0, 1, 8, bmp32, std::nullopt });
    appendImage(input, prefixOf(makeIconFile(1, single), 6 + 16 + bmp32.size() / 2), "image/x-icon"_s);

    // An entry inside the directory, and one past the end of the file.
    auto entries = icon();
    entries[1].offset = 10;
    appendImage(input, makeIconFile(1, entries), "image/x-icon"_s);
    entries = icon();
    entries[0].offset = 1 << 20;
    appendImage(input, makeIconFile(1, entries), "image/x-icon"_s);

    // A BMP entry with an unknown info header size, after a good one.
    entries = icon();
    put32(entries[1].bytes, 0, 41);
    appendImage(input, makeIconFile(1, entries), "image/x-icon"_s);

    // A PNG entry whose size differs from the directory's, one truncated in its image data, and one with a bad
    // header CRC.
    entries = icon();
    entries[2].size = 40;
    appendImage(input, makeIconFile(1, entries), "image/x-icon"_s);
    entries = icon();
    entries[2].bytes.shrink(png.size() / 2);
    appendImage(input, makeIconFile(1, entries), "image/x-icon"_s);
    entries = icon();
    entries[2].bytes[8 + 8 + 13] ^= 0xff;
    appendImage(input, makeIconFile(1, entries), "image/x-icon"_s);

    // A cursor truncated in its only entry.
    Vector<IconEntry> cursor;
    cursor.append({ 32, 0, 7, 9, bmp32, std::nullopt });
    appendImage(input, prefixOf(makeIconFile(2, cursor), 6 + 16 + bmp32.size() - 100), "image/x-icon"_s);
}

// Truncated and corrupt GIF, BMP, ICO and CUR files that take the decoders' failure paths, and some that each
// decoder tolerates.
static Input malformedImagesInput()
{
    Generator generator(0x4d414c46);
    Input input;
    appendMalformedGIFs(input, generator);
    appendMalformedBMPs(input, generator);
    appendMalformedICOs(input, generator);
    return input;
}

// Decoding

// The frame's premultiplied BGRA pixels, copied unchanged into an image buffer of the same size and read back.
static RefPtr<PixelBuffer> readPixels(const PlatformImagePtr& platformImage)
{
    RefPtr image = NativeImage::create(PlatformImagePtr { platformImage });
    if (!image)
        return nullptr;
    auto size = image->size();
    RefPtr buffer = ImageBuffer::create(size, RenderingMode::Unaccelerated, RenderingPurpose::Unspecified, 1, ColorSpace::SRGB(), PixelFormat::BGRA8);
    if (!buffer)
        return nullptr;
    buffer->context().drawNativeImage(*image, FloatRect { { }, size }, FloatRect { { }, size }, { CompositeOperator::Copy, InterpolationQuality::DoNotInterpolate });
    return buffer->getPixelBuffer({ AlphaPremultiplication::Premultiplied, PixelFormat::BGRA8, ColorSpace::SRGB() }, { { }, size });
}

static void addPixels(Checksum& checksum, const PlatformImagePtr& platformImage)
{
    RefPtr pixels = readPixels(platformImage);
    if (!pixels) {
        checksum.add(0);
        return;
    }
    checksum.add(pixels->size().width());
    checksum.add(pixels->size().height());
    checksum.add(pixels->bytes());
}

// What every pass must agree on, checked after each timed pass.
struct Summary {
    uint64_t frames { 0 };
    uint64_t images { 0 };
    uint64_t completeFrames { 0 };
    uint64_t framesWithAlpha { 0 };

    friend bool operator==(const Summary&, const Summary&) = default;
};

static void addFrame(ImageDecoder& decoder, size_t index, Checksum* checksum, Summary& summary)
{
    auto platformImage = decoder.createFrameImageAtIndex(index);
    bool complete = decoder.frameIsCompleteAtIndex(index);
    bool hasAlpha = decoder.frameHasAlphaAtIndex(index);
    ++summary.frames;
    summary.images += !!platformImage;
    summary.completeFrames += complete;
    summary.framesWithAlpha += hasAlpha;
    if (!checksum)
        return;
    auto size = decoder.frameSizeAtIndex(index);
    checksum->add(index);
    checksum->add(size.width());
    checksum->add(size.height());
    checksum->add(complete);
    checksum->add(hasAlpha);
    checksum->add(std::llround(decoder.frameDurationAtIndex(index).milliseconds()));
    if (platformImage)
        addPixels(*checksum, platformImage);
    else
        checksum->add(3);
}

static void addImageProperties(ImageDecoder& decoder, Checksum* checksum)
{
    if (!checksum)
        return;
    checksum->add(decoder.size().width());
    checksum->add(decoder.size().height());
    checksum->add(static_cast<int64_t>(decoder.repetitionCount()));
    auto hotSpot = decoder.hotSpot();
    checksum->add(hotSpot.has_value());
    if (hotSpot) {
        checksum->add(hotSpot->x());
        checksum->add(hotSpot->y());
    }
}

static void decodeOnePass(const Input& input, Checksum* checksum, Summary& summary)
{
    for (auto& image : input.images) {
        RefPtr decoder = ImageDecoder::create(image.data.get(), String(image.mimeType), AlphaOption::Premultiplied, GammaAndColorProfileOption::Applied);
        if (!decoder) {
            if (checksum)
                checksum->add(4);
            continue;
        }
        decoder->setData(image.data.get(), true);
        size_t frameCount = decoder->frameCount();
        if (checksum)
            checksum->add(frameCount);
        for (size_t index = 0; index < frameCount; ++index)
            addFrame(*decoder, index, checksum, summary);
        addImageProperties(*decoder, checksum);
    }

    if (input.chunkedPrefixes.isEmpty())
        return;
    RefPtr decoder = ImageDecoder::create(input.chunkedPrefixes.first().get(), "image/gif"_s, AlphaOption::Premultiplied, GammaAndColorProfileOption::Applied);
    if (!decoder) {
        if (checksum)
            checksum->add(4);
        return;
    }
    for (size_t i = 0; i < input.chunkedPrefixes.size(); ++i) {
        decoder->setData(input.chunkedPrefixes[i].get(), i + 1 == input.chunkedPrefixes.size());
        size_t frameCount = decoder->frameCount();
        if (checksum)
            checksum->add(frameCount);
        if (frameCount)
            addFrame(*decoder, 0, checksum, summary);
    }
    addImageProperties(*decoder, checksum);
}

static bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && StringView::fromLatin1(value) != "0"_s;
}

static void runBenchmark(ASCIILiteral name, const Input& input, unsigned iterations, uint64_t expectedChecksum)
{
    Checksum checksum;
    Summary summary;
    decodeOnePass(input, &checksum, summary);
    EXPECT_EQ(checksum.value, expectedChecksum) << "checksum=" << std::hex << std::setfill('0') << std::setw(16) << checksum.value;

    if (!runsBenchmarks())
        return;

    unsigned mismatches = 0;
    auto start = MonotonicTime::now();
    for (unsigned i = 0; i < iterations; ++i) {
        Summary iterationSummary;
        decodeOnePass(input, nullptr, iterationSummary);
        if (iterationSummary != summary)
            ++mismatches;
    }
    double seconds = (MonotonicTime::now() - start).seconds();
    EXPECT_EQ(mismatches, 0u);

    double bytes = static_cast<double>(input.bytes) * iterations;
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, seconds * 1000, bytes / seconds / 1e6, static_cast<unsigned long long>(checksum.value));
}

} // namespace

TEST(ImageDecoderBench, LargeGIF)
{
    runBenchmark("LargeGIF"_s, largeGIFInput(), 70, 0x2b0c705e118cbc0dull);
}

TEST(ImageDecoderBench, AnimatedGIF)
{
    runBenchmark("AnimatedGIF"_s, animatedGIFInput(), 105, 0x17d9d2b3e93054d5ull);
}

TEST(ImageDecoderBench, InterlacedGIF)
{
    runBenchmark("InterlacedGIF"_s, interlacedGIFInput(), 290, 0x70b1dc0334180699ull);
}

TEST(ImageDecoderBench, BMP24)
{
    runBenchmark("BMP24"_s, bmp24Input(), 115, 0x7990f29d08cfce0cull);
}

TEST(ImageDecoderBench, BMP32Bitmask)
{
    runBenchmark("BMP32Bitmask"_s, bmp32BitmaskInput(), 30, 0xf760a9398fd61d11ull);
}

TEST(ImageDecoderBench, BMPRLE8)
{
    runBenchmark("BMPRLE8"_s, bmpRLE8Input(), 140, 0x2e1955b328d4d2a6ull);
}

TEST(ImageDecoderBench, ICOMultiSize)
{
    runBenchmark("ICOMultiSize"_s, icoMultiSizeInput(), 3400, 0x7b2d6500208dc60dull);
}

TEST(ImageDecoderBench, ManySmallGIFs)
{
    runBenchmark("ManySmallGIFs"_s, manySmallGIFsInput(), 140, 0xe8cfe74447705994ull);
}

TEST(ImageDecoderBench, BMPOtherDepths)
{
    runBenchmark("BMPOtherDepths"_s, bmpOtherDepthsInput(), 140, 0x64f7490929f9d5b1ull);
}

TEST(ImageDecoderBench, ICOCursor)
{
    runBenchmark("ICOCursor"_s, icoCursorInput(), 8000, 0x77b30174482b2080ull);
}

TEST(ImageDecoderBench, MalformedImages)
{
    runBenchmark("MalformedImages"_s, malformedImagesInput(), 1600, 0x72bb99adb38e3db2ull);
}

} // namespace TestWebKitAPI
