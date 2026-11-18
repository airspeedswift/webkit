// Copyright (C) 2004, 2005, 2006, 2007 Nikolas Zimmermann <zimmermann@kde.org>
// Copyright (C) 2004, 2005 Rob Buis <buis@kde.org>
// Copyright (C) 2005 Eric Seidel <eric@webkit.org>
// Copyright (C) 2009 Dirk Schulze <krit@webkit.org>
// Copyright (C) 2010 Renata Hodovan <reni@inf.u-szeged.hu>
// Copyright (C) 2011 Gabor Loki <loki@webkit.org>
// Copyright (C) 2017-2026 Apple Inc. All rights reserved.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
//
// You should have received a copy of the GNU Library General Public License
// along with this library; see the file COPYING.LIB.  If not, write to
// the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
// Boston, MA 02110-1301, USA.

#if ENABLE_WEBCORE_SWIFT

// The safe Span overload Swift synthesizes for PixelBufferAccess.mutableSpan() calls Cxx's
// MutableSpan(_unsafeCxxSpan:). Xcode builds don't find it unless this file imports Cxx.
private import Cxx
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import ucrt
#endif
#if arch(arm64)
import _Builtin_intrinsics.arm.neon
#endif
import WebCore_Private.Core.AlphaPremultiplication
import WebCore_Private.Core.FETurbulenceParameters
import WebCore_Private.Core.FilterSwiftBridge
import WebCore_Private.Core.FloatRect
import WebCore_Private.Core.FloatSize
import WebCore_Private.Core.IntRect
import WebCore_Private.Core.IntSize
import WebCore_Private.Core.PixelBuffer
import WebCore_Private.Core.PixelBufferSwiftBridge

// The turbulence calculation is an adapted version of what appears in the SVG 1.1 specification:
// http://www.w3.org/TR/SVG11/filters.html#feTurbulence

private let turbulenceBlockSize = 256
private let turbulenceLatticeSize = 2 * turbulenceBlockSize + 2
private let turbulencePerlinNoise: Int32 = 4096
private let turbulenceRandMaximum = 2_147_483_647 // 2**31 - 1

// The number of octaves is capped, which bounds the work per pixel. A single octave's noise is at most about 0.71
// (measured), so octave i adds at most 0.71 * 255 / 2^i to a channel; past the tenth that is below one 8-bit step, and
// no legitimate content uses more than a handful. Skia's SkPerlinNoiseShader caps at 255.
let turbulenceMaximumOctaves: Int32 = 10

// The random tables of the noise function for a seed (FETurbulenceSoftwareApplier::PaintingData), shared by the software
// and Core Image paths.
struct TurbulencePaintingData {
    // 2 * 256 + 2 entries, each in 0 ..< 256.
    var latticeSelector: ContiguousArray<Int32>
    // The unit gradients of the 256 lattice points, for the four channels at once: element 2 i holds the x components
    // of point i's red, green, blue and alpha gradients, element 2 i + 1 their y components. The C++ tables repeated
    // them at 256 + i.
    var gradients: ContiguousArray<SIMD4<Float>>

    init(seed seedValue: Float) {
        // float to long, then the seed is clamped to [1, randMaximum - 1].
        var seed = Int(arm64Truncating: seedValue)
        if seed <= 0 {
            seed = -(seed % (turbulenceRandMaximum - 1)) + 1
        }
        if seed > turbulenceRandMaximum - 1 {
            seed = turbulenceRandMaximum - 1
        }

        gradients = ContiguousArray(repeating: SIMD4<Float>(), count: 2 * turbulenceBlockSize)
        for channel in 0..<4 {
            for i in 0..<turbulenceBlockSize {
                var x: Float
                var y: Float
                repeat {
                    x = Float(turbulenceRandom(&seed) % (2 * turbulenceBlockSize) - turbulenceBlockSize) / Float(turbulenceBlockSize)
                    y = Float(turbulenceRandom(&seed) % (2 * turbulenceBlockSize) - turbulenceBlockSize) / Float(turbulenceBlockSize)
                } while x == 0 && y == 0
                let normalizationFactor = hypotf(x, y)
                gradients[2 * i][channel] = x / normalizationFactor
                gradients[2 * i + 1][channel] = y / normalizationFactor
            }
        }

        latticeSelector = ContiguousArray(repeating: 0, count: turbulenceLatticeSize)
        for i in 0..<turbulenceBlockSize {
            latticeSelector[i] = Int32(i)
        }
        for i in stride(from: turbulenceBlockSize - 1, to: 0, by: -1) {
            let k = latticeSelector[i]
            let j = turbulenceRandom(&seed) % turbulenceBlockSize
            latticeSelector[i] = latticeSelector[j]
            latticeSelector[j] = k
        }
        for i in 0..<turbulenceBlockSize + 2 {
            latticeSelector[turbulenceBlockSize + i] = latticeSelector[i]
        }
    }
}

// Produces results in the range [1, 2**31 - 2]. Algorithm is:
// r = (a * r) mod m where a = randAmplitude = 16807 and
// m = randMaximum = 2**31 - 1 = 2147483647, r = seed.
// See [Park & Miller], CACM vol. 31 no. 10 p. 1195, Oct. 1988
// To test: the algorithm should produce the result 1043618065
// as the 10,000th generated number if the original seed is 1.
private func turbulenceRandom(_ seed: inout Int) -> Int {
    let randAmplitude = 16807 // 7**5; primitive root of m
    let randQ = 127773 // m / a
    let randR = 2836 // m % a
    var result = randAmplitude * (seed % randQ) - randR * (seed / randQ)
    if result <= 0 {
        result += turbulenceRandMaximum
    }
    seed = result
    return result
}

// FETurbulenceSoftwareApplier::StitchData.
struct TurbulenceStitchData: Sendable {
    var width: Int32 = 0 // How much to subtract to wrap for stitching.
    var height: Int32 = 0
    var wrapX: Int32 = 0 // Minimum value to wrap.
    var wrapY: Int32 = 0
}

// FETurbulenceSoftwareApplier::computeStitching(): adjusts the base frequencies when stitching.
func turbulenceStitchData(
    tileSize: WebCore.IntSize,
    baseFrequencyX: inout Float,
    baseFrequencyY: inout Float,
    stitchTiles: Bool
) -> TurbulenceStitchData {
    if !stitchTiles {
        return TurbulenceStitchData()
    }

    let tileWidth = Float(tileSize.width())
    let tileHeight = Float(tileSize.height())
    assert(tileWidth > 0 && tileHeight > 0)

    // When stitching tiled turbulence, the frequencies must be adjusted
    // so that the tile borders will be continuous.
    if baseFrequencyX != 0 {
        let lowFrequency = (tileWidth * baseFrequencyX).rounded(.down) / tileWidth
        let highFrequency = (tileWidth * baseFrequencyX).rounded(.up) / tileWidth
        // BaseFrequency should be non-negative according to the standard.
        if baseFrequencyX / lowFrequency < highFrequency / baseFrequencyX {
            baseFrequencyX = lowFrequency
        } else {
            baseFrequencyX = highFrequency
        }
    }
    if baseFrequencyY != 0 {
        let lowFrequency = (tileHeight * baseFrequencyY).rounded(.down) / tileHeight
        let highFrequency = (tileHeight * baseFrequencyY).rounded(.up) / tileHeight
        if baseFrequencyY / lowFrequency < highFrequency / baseFrequencyY {
            baseFrequencyY = lowFrequency
        } else {
            baseFrequencyY = highFrequency
        }
    }

    var stitchData = TurbulenceStitchData()
    stitchData.width = Int32(arm64Truncating: (tileWidth * baseFrequencyX).rounded())
    stitchData.wrapX = turbulencePerlinNoise &+ stitchData.width
    stitchData.height = Int32(arm64Truncating: (tileHeight * baseFrequencyY).rounded())
    stitchData.wrapY = turbulencePerlinNoise &+ stitchData.height
    return stitchData
}

// FETurbulenceSoftwareApplier::apply().
func feTurbulenceApplySoftware(
    _ context: borrowing WebCore.FilterApplyContext,
    _ parameters: borrowing WebCore.FETurbulenceParameters,
    _ result: inout FilterImageImpl
) -> Bool {
    guard let destination = result.pixelBuffer(.Unpremultiplied).get() else {
        return false
    }

    let filterRegion = result.absoluteImageRect
    let resultSize = filterRegion.size()
    // The area must fit in 32 bits, as IntSize::area<RecordOverflow>() checks.
    let area = resultSize.unclampedArea()
    guard area <= UInt64(UInt32.max) else {
        return false
    }

    if resultSize.isEmpty() {
        destination.zeroFill()
        return true
    }

    let tileSize = WebCore.roundedIntSize(result.primitiveSubregion.size())

    var baseFrequencyX = parameters.baseFrequencyX
    var baseFrequencyY = parameters.baseFrequencyY
    let stitchTiles = parameters.stitchTiles
    let stitchData = turbulenceStitchData(
        tileSize: tileSize,
        baseFrequencyX: &baseFrequencyX,
        baseFrequencyY: &baseFrequencyY,
        stitchTiles: stitchTiles
    )
    let paintingData = TurbulencePaintingData(seed: parameters.seed)

    let width = filterRegion.width()
    let height = filterRegion.height()
    let filterScale = context.filterScale
    let kernel = TurbulenceKernel(
        regionX: filterRegion.x(),
        regionY: filterRegion.y(),
        width: Int(width),
        inverseScaleX: 1 / filterScale.width(),
        inverseScaleY: 1 / filterScale.height(),
        baseFrequencyX: baseFrequencyX,
        baseFrequencyY: baseFrequencyY,
        numOctaves: min(parameters.numOctaves, turbulenceMaximumOctaves),
        fractalNoise: parameters.type == .FractalNoise,
        stitchTiles: stitchTiles,
        stitchData: stitchData
    )

    // FETurbulenceSoftwareApplier::applyPlatform()'s job count; 100 * 100 is an empirical limit for parallel jobs.
    let maxNumThreads = UInt32(truncatingIfNeeded: height / 8)
    let optimalThreadNumber = min(UInt32(area) / (100 * 100), maxNumThreads)
    let jobs = optimalThreadNumber > 1 ? Int(optimalThreadNumber) : 1

    var destinationAccess = WebCore.PixelBufferAccess(destination)
    var destinationBytes: MutableSpan<UInt8> = destinationAccess.mutableSpan()
    let latticeSelector = paintingData.latticeSelector.span
    let gradients = paintingData.gradients.span
    // The destination holds exactly the result's rows, so this always runs.
    _ = parallelRows(height: Int(height), jobs: jobs, rowBytes: Int(width) * 4, into: &destinationBytes) { rows, output in
        turbulenceRows(kernel, latticeSelector, gradients, rows, &output)
    }
    return true
}

// What the noise function needs besides the painting data, for one apply.
private struct TurbulenceKernel: Sendable {
    var regionX: Int32
    var regionY: Int32
    var width: Int
    var inverseScaleX: Float
    var inverseScaleY: Float
    var baseFrequencyX: Float
    var baseFrequencyY: Float
    var numOctaves: Int32
    // Otherwise turbulence (TurbulenceType::Turbulence and Unknown).
    var fractalNoise: Bool
    var stitchTiles: Bool
    var stitchData: TurbulenceStitchData
}

// FETurbulenceSoftwareApplier::applyPlatformGeneric() for `rows`, which `output` holds. Pixel (x, y) takes the noise at
// ((x + 1) / scale, (y + 1) / scale) relative to the filter region's origin, accumulated in floats as in C++.
private func turbulenceRows(
    _ kernel: TurbulenceKernel,
    _ latticeSelector: Span<Int32>,
    _ gradients: Span<SIMD4<Float>>,
    _ rows: Range<Int>,
    _ output: inout MutableSpan<UInt8>
) {
    var bytes = output.mutableBytes
    var offset = 0
    var pointY = Float(kernel.regionY &+ Int32(truncatingIfNeeded: rows.lowerBound))
    for _ in rows {
        pointY += 1
        let noiseY = pointY * kernel.inverseScaleY * kernel.baseFrequencyY
        var pointX = Float(kernel.regionX)
        for _ in 0..<kernel.width {
            pointX += 1
            let noiseX = pointX * kernel.inverseScaleX * kernel.baseFrequencyX
            let pixel = turbulencePixel(kernel, latticeSelector, gradients, noiseX, noiseY)
            bytes.storeBytes(of: pixel.littleEndian, toByteOffset: offset, as: UInt32.self)
            offset += 4
        }
    }
}

// FETurbulenceSoftwareApplier::calculateTurbulenceValueForPoint(): the four channels in the bytes of a little-endian
// UInt32.
@inline(__always)
private func turbulencePixel(
    _ kernel: TurbulenceKernel,
    _ latticeSelector: Span<Int32>,
    _ gradients: Span<SIMD4<Float>>,
    _ noiseVectorX: Float,
    _ noiseVectorY: Float
) -> UInt32 {
    var noiseX = noiseVectorX
    var noiseY = noiseVectorY
    var stitchData = kernel.stitchData
    var ratio: Float = 1
    var result = SIMD4<Float>()
    var octave: Int32 = 0
    while octave < kernel.numOctaves {
        let noise = turbulenceNoise(latticeSelector, gradients, noiseX, noiseY, kernel.stitchTiles, stitchData)
        result += (kernel.fractalNoise ? noise : magnitude(noise)) / ratio

        noiseX *= 2
        noiseY *= 2
        ratio *= 2

        if kernel.stitchTiles {
            // Update stitch values. Subtracting perlinNoise before the multiplication and
            // adding it afterward simplifies to subtracting it once.
            stitchData.width = stitchData.width &* 2
            stitchData.wrapX = 2 &* stitchData.wrapX &- turbulencePerlinNoise
            stitchData.height = stitchData.height &* 2
            stitchData.wrapY = 2 &* stitchData.wrapY &- turbulencePerlinNoise
        }
        octave += 1
    }

    // The value of result comes from ((result * 255) + 255) / 2 by fractalNoise
    // and (result * 255) by turbulence.
    if kernel.fractalNoise {
        result = result * 0.5 + 0.5
    }

    return colorBytes(result * 255)
}

// FETurbulenceSoftwareApplier::noise2D(), for the four channels at once; taken 1:1 from the SVG spec:
// http://www.w3.org/TR/SVG11/filters.html#feTurbulenceElement.
@inline(__always)
private func turbulenceNoise(
    _ latticeSelector: Span<Int32>,
    _ gradients: Span<SIMD4<Float>>,
    _ noiseVectorX: Float,
    _ noiseVectorY: Float,
    _ stitchTiles: Bool,
    _ stitchData: TurbulenceStitchData
) -> SIMD4<Float> {
    //  t = vec[0] + PerlinN;
    //  bx0 = (int)t;
    //  bx1 = bx0+1;
    //  rx0 = t - (int)t;
    let positionX = noiseVectorX + Float(turbulencePerlinNoise)
    var indexX = Int32(arm64Truncating: positionX)
    var nextIndexX = indexX &+ 1
    let fractionX = positionX - Float(indexX)
    let positionY = noiseVectorY + Float(turbulencePerlinNoise)
    var indexY = Int32(arm64Truncating: positionY)
    var nextIndexY = indexY &+ 1
    let fractionY = positionY - Float(indexY)

    // If stitching, adjust lattice points accordingly.
    if stitchTiles {
        if indexX >= stitchData.wrapX {
            indexX = indexX &- stitchData.width
        }
        if nextIndexX >= stitchData.wrapX {
            nextIndexX = nextIndexX &- stitchData.width
        }
        if indexY >= stitchData.wrapY {
            indexY = indexY &- stitchData.height
        }
        if nextIndexY >= stitchData.wrapY {
            nextIndexY = nextIndexY &- stitchData.height
        }
    }

    // bx0 &= BM; bx1 &= BM; by0 &= BM; by1 &= BM;
    let blockMask = Int32(turbulenceBlockSize - 1)
    let maskedIndexY = Int(indexY & blockMask)
    let maskedNextIndexY = Int(nextIndexY & blockMask)

    // i = uLatticeSelector[bx0];
    // j = uLatticeSelector[bx1];
    let latticeIndex = Int(latticeSelector[Int(indexX & blockMask)])
    let nextLatticeIndex = Int(latticeSelector[Int(nextIndexX & blockMask)])

    // sx = double(s_curve(rx0));
    // sy = double(s_curve(ry0));
    let sx = smoothCurve(fractionX)
    let sy = smoothCurve(fractionY)

    // b00 = uLatticeSelector[i + by0]; b10 = uLatticeSelector[j + by0];
    // b01 = uLatticeSelector[i + by1]; b11 = uLatticeSelector[j + by1];
    let b00 = 2 * Int(latticeSelector[latticeIndex + maskedIndexY])
    let b10 = 2 * Int(latticeSelector[nextLatticeIndex + maskedIndexY])
    let b01 = 2 * Int(latticeSelector[latticeIndex + maskedNextIndexY])
    let b11 = 2 * Int(latticeSelector[nextLatticeIndex + maskedNextIndexY])

    // rx1 = rx0 - 1.0f; ry1 = ry0 - 1.0f;
    let nextFractionX = fractionX - 1
    let nextFractionY = fractionY - 1

    // q = fGradient[nColorChannel][b00]; u = rx0 * q[0] + ry0 * q[1];
    // q = fGradient[nColorChannel][b10]; v = rx1 * q[0] + ry0 * q[1];
    // a = lerp(sx, u, v);
    var u = fractionX * gradients[b00] + fractionY * gradients[b00 + 1]
    var v = nextFractionX * gradients[b10] + fractionY * gradients[b10 + 1]
    let a = lerp(u, v, sx)

    // q = fGradient[nColorChannel][b01]; u = rx0 * q[0] + ry1 * q[1];
    // q = fGradient[nColorChannel][b11]; v = rx1 * q[0] + ry1 * q[1];
    // b = lerp(sx, u, v);
    u = fractionX * gradients[b01] + nextFractionY * gradients[b01 + 1]
    v = nextFractionX * gradients[b11] + nextFractionY * gradients[b11 + 1]
    let b = lerp(u, v, sx)

    // return lerp(sy, a, b);
    return lerp(a, b, sy)
}

@inline(__always)
private func smoothCurve(_ t: Float) -> Float {
    t * t * (3 - 2 * t)
}

// std::lerp(a, b, t) of each component, as the C++ computed each channel.
@inline(__always)
private func lerp(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
    SIMD4(
        filterLerp(a[0], b[0], t),
        filterLerp(a[1], b[1], t),
        filterLerp(a[2], b[2], t),
        filterLerp(a[3], b[3], t)
    )
}

// std::abs of each component.
@inline(__always)
private func magnitude(_ components: SIMD4<Float>) -> SIMD4<Float> {
    #if arch(arm64)
    vabsq_f32(components)
    #else
    SIMD4(components[0].magnitude, components[1].magnitude, components[2].magnitude, components[3].magnitude)
    #endif
}

// FETurbulenceSoftwareApplier::toIntBasedColorComponents(): std::clamp<uint8_t>(static_cast<int>(c), 0, 255), whose
// conversion to uint8_t keeps the low byte before the clamp, so 300 becomes 44.
@inline(__always)
private func colorBytes(_ components: SIMD4<Float>) -> UInt32 {
    #if arch(arm64)
    let values = SIMD4<UInt32>(truncatingIfNeeded: vcvtq_s32_f32(components))
    #else
    let values = SIMD4<UInt32>(
        UInt32(truncatingIfNeeded: Int32(arm64Truncating: components[0])),
        UInt32(truncatingIfNeeded: Int32(arm64Truncating: components[1])),
        UInt32(truncatingIfNeeded: Int32(arm64Truncating: components[2])),
        UInt32(truncatingIfNeeded: Int32(arm64Truncating: components[3]))
    )
    #endif
    let bytes = values & 0xFF
    return bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24
}

#endif // ENABLE_WEBCORE_SWIFT
