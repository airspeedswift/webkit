// Copyright (C) 2018 Apple Inc. All rights reserved.
// Copyright (C) 2018-2021 Apple Inc. All rights reserved.
// Copyright (C) 2018-2026 Apple Inc. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

#if ENABLE_WEBCORE_SWIFT

// The safe Span overloads Swift synthesizes for the views' span() call a Span initializer from Cxx, which Xcode
// builds don't find unless this file imports Cxx.
private import Cxx
import WebCore_Private.Core.AnnexBUtilities
import WebCore_Private.Core.MediaParsersCxxBridging
import WebCore_Private.Core.VideoCodecParameterTypes

// The H.265 (https://www.itu.int/rec/T-REC-H.265) parsing behind HEVCBitstreamParser.cpp and HEVCUtilitiesCocoa.mm: the
// VPS reorder depth, the Annex B parameter set locators, and the SPS/PPS/slice header state that recovers the QP of the
// last slice. It matches libwebrtc's h265_bitstream_parser.cc bit for bit, including where that departs from the spec.
// NAL units are read through RbspBitReader, which skips emulation prevention bytes in place.

private let hevcNaluHeaderSize = 2

// Table 7-1, and RFC 7798 sections 4.4.2 and 4.4.3 for AP and FU.
private enum H265NaluType {
    static let blaWLp: UInt8 = 16
    static let idrWRadl: UInt8 = 19
    static let idrNLp: UInt8 = 20
    static let rsvIrapVcl23: UInt8 = 23
    static let vps: UInt8 = 32
    static let sps: UInt8 = 33
    static let pps: UInt8 = 34
    static let aud: UInt8 = 35
    static let prefixSei: UInt8 = 39
    static let suffixSei: UInt8 = 40
    static let ap: UInt8 = 48
    static let fu: UInt8 = 49
}

// Table 7-7.
private enum H265SliceType {
    static let b: UInt32 = 0
    static let p: UInt32 = 1
}

private let maxShortTermRefPicSets: UInt32 = 64
private let maxLongTermRefPicSets: UInt32 = 32
private let maxRefIdxActive: UInt32 = 15

private func hevcNaluType(_ firstByte: UInt8) -> UInt8 {
    (firstByte & 0x7E) >> 1
}

// UInt32.max for 0, like libwebrtc's H265::Log2Ceiling(0) == -1.
private func hevcLog2Ceiling(_ value: UInt32) -> UInt32 {
    if value == 0 {
        return .max
    }
    return 32 - UInt32((value - 1).leadingZeroBitCount)
}

// Table A.8. generalLevelIDC is 30 times the level.
private func hevcMaxLumaPs(_ generalLevelIDC: UInt32) -> UInt32 {
    switch generalLevelIDC {
    case ...30: 36864
    case ...60: 122880
    case ...63: 245760
    case ...90: 552960
    case ...93: 983040
    case ...123: 2_228_224
    case ...156: 8_912_896
    default: 35_651_584
    }
}

// A.4.2: the Main to High Throughput profiles are 1 to 5.
private func hevcDpbMaxPicBuf(_ generalProfileIDC: UInt32) -> UInt32 {
    (1...5).contains(generalProfileIDC) ? 6 : 7
}

// MARK: Profile, tier and level; scaling lists; reference picture sets

private struct HEVCProfileTierLevel {
    var generalProfileIDC: UInt32
    var generalLevelIDC: UInt32
}

// 7.3.3, always with profilePresentFlag set. Interlaced streams are rejected.
private func parseProfileTierLevel(maxNumSubLayersMinus1: UInt32, _ reader: inout RbspBitReader) -> HEVCProfileTierLevel? {
    // general_profile_space must be 0.
    if reader.readBits(2) != 0 {
        return nil
    }
    // general_tier_flag
    reader.consumeBits(1)
    let generalProfileIDC = reader.readBits(5)
    guard reader.ok, generalProfileIDC <= 11 else {
        return nil
    }
    // general_profile_compatibility_flag[32]
    reader.consumeBits(32)
    let generalProgressiveSourceFlag = reader.readFlag()
    let generalInterlacedSourceFlag = reader.readFlag()
    guard reader.ok, generalProgressiveSourceFlag || !generalInterlacedSourceFlag else {
        return nil
    }
    // general_non_packed_constraint_flag, general_frame_only_constraint_flag, general_reserved_zero_7bits,
    // general_one_picture_only_constraint_flag, general_reserved_zero_35bits, general_inbld_flag
    reader.consumeBits(2 + 7 + 1 + 35 + 1)
    let generalLevelIDC = reader.readBits(8)

    let subLayerCount = min(maxNumSubLayersMinus1, 8)
    var subLayerProfilePresentFlags: UInt8 = 0
    var subLayerLevelPresentFlags: UInt8 = 0
    for i in 0..<subLayerCount {
        if reader.readFlag() {
            subLayerProfilePresentFlags |= 1 << i
        }
        if reader.readFlag() {
            subLayerLevelPresentFlags |= 1 << i
        }
    }
    if maxNumSubLayersMinus1 > 0 && maxNumSubLayersMinus1 < 8 {
        // reserved_zero_2bits[i]
        reader.consumeBits(2 * Int(8 - maxNumSubLayersMinus1))
    }
    for i in 0..<subLayerCount {
        if subLayerProfilePresentFlags & (1 << i) != 0 {
            // sub_layer_profile_space, sub_layer_tier_flag, sub_layer_profile_idc, sub_layer_profile_compatibility_flag[32],
            // sub_layer_{progressive,interlaced,non_packed_constraint,frame_only_constraint}_flag, 43 reserved bits,
            // sub_layer_inbld_flag
            reader.consumeBits(2 + 1 + 5 + 32 + 2 + 2 + 43 + 1)
        }
        if subLayerLevelPresentFlags & (1 << i) != 0 {
            // sub_layer_level_idc
            reader.consumeBits(8)
        }
    }

    guard reader.ok else {
        return nil
    }
    return HEVCProfileTierLevel(generalProfileIDC: generalProfileIDC, generalLevelIDC: generalLevelIDC)
}

// 7.3.4; only checks the values' ranges.
private func parseScalingListData(_ reader: inout RbspBitReader) -> Bool {
    for sizeId in 0..<4 {
        var matrixId = 0
        while matrixId < 6 {
            let scalingListPredModeFlag = reader.readFlag()
            if !scalingListPredModeFlag {
                let scalingListPredMatrixIdDelta = reader.readExpGolomb()
                let maxDelta = UInt32(sizeId <= 2 ? matrixId : matrixId / 3)
                guard reader.ok, scalingListPredMatrixIdDelta <= maxDelta else {
                    return false
                }
            } else {
                let coefNum = min(64, 1 << (4 + (sizeId << 1)))
                if sizeId > 1 {
                    let scalingListDcCoefMinus8 = reader.readSignedExpGolomb()
                    guard reader.ok, (-7...247).contains(scalingListDcCoefMinus8) else {
                        return false
                    }
                }
                for _ in 0..<coefNum {
                    let scalingListDeltaCoef = reader.readSignedExpGolomb()
                    guard reader.ok, (-128...127).contains(scalingListDeltaCoef) else {
                        return false
                    }
                }
            }
            matrixId += sizeId == 3 ? 3 : 1
        }
    }
    return reader.ok
}

// FIXME: Make this private once a private type links under ThinLTO on Windows ("Invalid weak external").
struct HEVCReferencePicture {
    var deltaPoc: Int32
    var usedByCurrPic: Bool
}

// FIXME: Make this private once a private type links under ThinLTO on Windows ("Invalid weak external").
struct HEVCShortTermRefPicSet {
    var numNegativePics: UInt32 = 0
    var numPositivePics: UInt32 = 0
    // The numNegativePics pictures of S0, then the numPositivePics pictures of S1.
    var pictures: [HEVCReferencePicture] = []

    var numDeltaPocs: UInt32 {
        numNegativePics + numPositivePics
    }

    func negativePicture(_ index: UInt32) -> HEVCReferencePicture {
        pictures[Int(index)]
    }

    func positivePicture(_ index: UInt32) -> HEVCReferencePicture {
        pictures[Int(numNegativePics + index)]
    }
}

// 7.3.7 and 7.4.8. `sets` holds the sets parsed before this one: the SPS's so far, or for a slice all of them.
private func parseShortTermRefPicSet(
    _ stRpsIndex: UInt32,
    numShortTermRefPicSets: UInt32,
    _ sets: [HEVCShortTermRefPicSet],
    spsMaxDecPicBufferingMinus1: UInt32,
    _ reader: inout RbspBitReader
) -> HEVCShortTermRefPicSet? {
    var result = HEVCShortTermRefPicSet()

    var interRefPicSetPredictionFlag = false
    if stRpsIndex != 0 {
        interRefPicSetPredictionFlag = reader.readFlag()
    }

    if interRefPicSetPredictionFlag {
        var deltaIdxMinus1: UInt32 = 0
        if stRpsIndex == numShortTermRefPicSets {
            deltaIdxMinus1 = reader.readExpGolomb()
            guard reader.ok, deltaIdxMinus1 <= stRpsIndex - 1 else {
                return nil
            }
        }
        let deltaRpsSign = Int32(reader.readBits(1))
        let absDeltaRpsMinus1 = reader.readExpGolomb()
        guard reader.ok, absDeltaRpsMinus1 <= 0x7FFF else {
            return nil
        }
        let deltaRps = (1 - 2 * deltaRpsSign) * (Int32(absDeltaRpsMinus1) + 1)
        let refRpsIndex = Int(stRpsIndex - (deltaIdxMinus1 + 1))
        guard refRpsIndex < sets.count else {
            return nil
        }
        let refSet = sets[refRpsIndex]
        guard reader.ok, refSet.numDeltaPocs <= maxShortTermRefPicSets else {
            return nil
        }

        // Swift's 128-bit integers: WTF's UInt128, which the C++ global `using` puts in scope, is a class on Windows.
        // Bit j: used_by_curr_pic_flag[j], and use_delta_flag[j], which is 1 when absent.
        var usedByCurrPicFlags: Swift.UInt128 = 0
        var useDeltaFlags: Swift.UInt128 = ~0
        for j in 0...refSet.numDeltaPocs {
            if reader.readFlag() {
                usedByCurrPicFlags |= 1 << j
            } else if !reader.readFlag() {
                useDeltaFlags &= ~(1 << j)
            }
        }
        func usesDelta(_ j: UInt32) -> Bool {
            useDeltaFlags & (1 << j) != 0
        }
        func picture(_ deltaPoc: Int32, _ j: UInt32) -> HEVCReferencePicture {
            HEVCReferencePicture(deltaPoc: deltaPoc, usedByCurrPic: usedByCurrPicFlags & (1 << j) != 0)
        }

        // The sums can't overflow: each is |deltaRps| <= 2^15 more than a value of the reference set, and the sets
        // chain at most 65 deep.
        let numNegativePics = refSet.numNegativePics
        let numDeltaPocs = refSet.numDeltaPocs
        result.pictures.reserveCapacity(Int(numDeltaPocs) + 1)

        // Equation 7-61.
        for j in (0..<refSet.numPositivePics).reversed() {
            let dPoc = refSet.positivePicture(j).deltaPoc &+ deltaRps
            if dPoc < 0 && usesDelta(numNegativePics + j) {
                result.pictures.append(picture(dPoc, numNegativePics + j))
            }
        }
        if deltaRps < 0 && usesDelta(numDeltaPocs) {
            result.pictures.append(picture(deltaRps, numDeltaPocs))
        }
        for j in 0..<numNegativePics {
            let dPoc = refSet.negativePicture(j).deltaPoc &+ deltaRps
            if dPoc < 0 && usesDelta(j) {
                result.pictures.append(picture(dPoc, j))
            }
        }
        result.numNegativePics = UInt32(result.pictures.count)

        // Equation 7-62.
        for j in (0..<numNegativePics).reversed() {
            let dPoc = refSet.negativePicture(j).deltaPoc &+ deltaRps
            if dPoc > 0 && usesDelta(j) {
                result.pictures.append(picture(dPoc, j))
            }
        }
        if deltaRps > 0 && usesDelta(numDeltaPocs) {
            result.pictures.append(picture(deltaRps, numDeltaPocs))
        }
        for j in 0..<refSet.numPositivePics {
            let dPoc = refSet.positivePicture(j).deltaPoc &+ deltaRps
            if dPoc > 0 && usesDelta(numNegativePics + j) {
                result.pictures.append(picture(dPoc, numNegativePics + j))
            }
        }
        result.numPositivePics = UInt32(result.pictures.count) - result.numNegativePics

        guard reader.ok, result.numNegativePics <= spsMaxDecPicBufferingMinus1,
            result.numPositivePics <= spsMaxDecPicBufferingMinus1 - result.numNegativePics
        else {
            return nil
        }
    } else {
        let maxSPSPics: UInt32 = 16
        let numNegativePics = reader.readExpGolomb()
        let numPositivePics = reader.readExpGolomb()
        guard reader.ok, numNegativePics <= maxSPSPics, numPositivePics <= maxSPSPics, numNegativePics + numPositivePics <= maxSPSPics,
            numNegativePics <= spsMaxDecPicBufferingMinus1, numPositivePics <= spsMaxDecPicBufferingMinus1 - numNegativePics
        else {
            return nil
        }
        result.numNegativePics = numNegativePics
        result.numPositivePics = numPositivePics
        result.pictures.reserveCapacity(Int(numNegativePics + numPositivePics))

        var deltaPoc: Int32 = 0
        for _ in 0..<numNegativePics {
            let deltaPocS0Minus1 = reader.readExpGolomb()
            guard reader.ok, deltaPocS0Minus1 <= 0x7FFF else {
                return nil
            }
            deltaPoc -= Int32(deltaPocS0Minus1) + 1
            result.pictures.append(HEVCReferencePicture(deltaPoc: deltaPoc, usedByCurrPic: reader.readFlag()))
        }
        deltaPoc = 0
        for _ in 0..<numPositivePics {
            let deltaPocS1Minus1 = reader.readExpGolomb()
            guard reader.ok, deltaPocS1Minus1 <= 0x7FFF else {
                return nil
            }
            deltaPoc += Int32(deltaPocS1Minus1) + 1
            result.pictures.append(HEVCReferencePicture(deltaPoc: deltaPoc, usedByCurrPic: reader.readFlag()))
        }
    }

    guard reader.ok else {
        return nil
    }
    return result
}

// MARK: VPS

// The largest vps_max_num_reorder_pics of a VPS NAL unit, clamped to 16 like libwebrtc's ComputeH265ReorderSizeFromVPS.
func parseHEVCVpsMaxNumReorderPics(_ vps: Span<UInt8>) -> UInt8? {
    guard vps.count > hevcNaluHeaderSize else {
        return nil
    }
    var reader = RbspBitReader(vps.extracting(droppingFirst: hevcNaluHeaderSize))

    // vps_video_parameter_set_id, vps_base_layer_internal_flag, vps_base_layer_available_flag, vps_max_layers_minus1
    reader.consumeBits(4 + 1 + 1 + 6)
    let vpsMaxSubLayersMinus1 = reader.readBits(3)
    guard reader.ok, vpsMaxSubLayersMinus1 <= 6 else {
        return nil
    }
    // vps_temporal_id_nesting_flag, vps_reserved_0xffff_16bits
    reader.consumeBits(1 + 16)

    guard parseProfileTierLevel(maxNumSubLayersMinus1: vpsMaxSubLayersMinus1, &reader) != nil else {
        return nil
    }

    let vpsSubLayerOrderingInfoPresentFlag = reader.readFlag()
    var maxNumReorderPics: UInt32 = 0
    for _ in (vpsSubLayerOrderingInfoPresentFlag ? 0 : vpsMaxSubLayersMinus1)...vpsMaxSubLayersMinus1 {
        // vps_max_dec_pic_buffering_minus1
        _ = reader.readExpGolomb()
        let vpsMaxNumReorderPics = reader.readExpGolomb()
        // vps_max_latency_increase_plus1
        _ = reader.readExpGolomb()
        guard reader.ok else {
            return nil
        }
        maxNumReorderPics = max(maxNumReorderPics, vpsMaxNumReorderPics)
    }

    return UInt8(min(maxNumReorderPics, 16))
}

// MARK: SPS

// FIXME: Make this private once a private type links under ThinLTO on Windows ("Invalid weak external").
struct HEVCSpsState {
    var spsID: UInt32 = 0
    var chromaFormatIDC: UInt32 = 0
    var separateColourPlaneFlag = false
    var picWidthInLumaSamples: UInt32 = 0
    var picHeightInLumaSamples: UInt32 = 0
    var log2MaxPicOrderCntLsbMinus4: UInt32 = 0
    // sps_max_dec_pic_buffering_minus1[sps_max_sub_layers_minus1], the only one used after the SPS.
    var maxDecPicBufferingMinus1: UInt32 = 0
    var log2DiffMaxMinLumaCodingBlockSize: UInt32 = 0
    var ctbLog2SizeY: UInt32 = 0
    var sampleAdaptiveOffsetEnabledFlag = false
    var shortTermRefPicSets: [HEVCShortTermRefPicSet] = []
    var longTermRefPicsPresentFlag = false
    var numLongTermRefPicsSps: UInt32 = 0
    // Bit i: used_by_curr_pic_lt_sps_flag[i].
    var usedByCurrPicLtSpsFlags: UInt64 = 0
    var spsTemporalMvpEnabledFlag = false
    var picWidthInCtbsY: UInt32 = 0
    var picHeightInCtbsY: UInt32 = 0
    var bitDepthLumaMinus8: UInt32 = 0

    var numShortTermRefPicSets: UInt32 {
        UInt32(shortTermRefPicSets.count)
    }

    var chromaArrayType: UInt32 {
        separateColourPlaneFlag ? 0 : chromaFormatIDC
    }
}

// 7.3.2.2, from after the NAL unit header up to sps_temporal_mvp_enabled_flag.
private func parseSps(_ data: Span<UInt8>) -> HEVCSpsState? {
    var reader = RbspBitReader(data)
    var sps = HEVCSpsState()

    // sps_video_parameter_set_id
    reader.consumeBits(4)
    let spsMaxSubLayersMinus1 = reader.readBits(3)
    guard reader.ok, spsMaxSubLayersMinus1 <= 6 else {
        return nil
    }
    // sps_temporal_id_nesting_flag
    reader.consumeBits(1)

    guard let profileTierLevel = parseProfileTierLevel(maxNumSubLayersMinus1: spsMaxSubLayersMinus1, &reader) else {
        return nil
    }

    sps.spsID = reader.readExpGolomb()
    guard reader.ok, sps.spsID <= 15 else {
        return nil
    }
    sps.chromaFormatIDC = reader.readExpGolomb()
    guard reader.ok, sps.chromaFormatIDC <= 3 else {
        return nil
    }
    if sps.chromaFormatIDC == 3 {
        sps.separateColourPlaneFlag = reader.readFlag()
    }

    let picWidthInLumaSamples = reader.readExpGolomb()
    guard reader.ok, picWidthInLumaSamples != 0 else {
        return nil
    }
    let picHeightInLumaSamples = reader.readExpGolomb()
    guard reader.ok, picHeightInLumaSamples != 0 else {
        return nil
    }

    // Equation A-2.
    let maxLumaPs = UInt64(hevcMaxLumaPs(profileTierLevel.generalLevelIDC))
    let picSizeInSamplesY = UInt64(picWidthInLumaSamples) * UInt64(picHeightInLumaSamples)
    let maxDpbPicBuf = hevcDpbMaxPicBuf(profileTierLevel.generalProfileIDC)
    let maxDpbSize: UInt32
    if picSizeInSamplesY <= maxLumaPs >> 2 {
        maxDpbSize = min(4 * maxDpbPicBuf, 16)
    } else if picSizeInSamplesY <= maxLumaPs >> 1 {
        maxDpbSize = min(2 * maxDpbPicBuf, 16)
    } else if picSizeInSamplesY <= (3 * maxLumaPs) >> 2 {
        maxDpbSize = min((4 * maxDpbPicBuf) / 3, 16)
    } else {
        maxDpbSize = maxDpbPicBuf
    }

    let conformanceWindowFlag = reader.readFlag()
    let subWidthC: UInt64 = (sps.chromaFormatIDC == 1 || sps.chromaFormatIDC == 2) && !sps.separateColourPlaneFlag ? 2 : 1
    let subHeightC: UInt64 = sps.chromaFormatIDC == 1 && !sps.separateColourPlaneFlag ? 2 : 1
    if conformanceWindowFlag {
        let confWinLeftOffset = reader.readExpGolomb()
        let confWinRightOffset = reader.readExpGolomb()
        let confWinTopOffset = reader.readExpGolomb()
        let confWinBottomOffset = reader.readExpGolomb()
        let widthCrop = (UInt64(confWinLeftOffset) + UInt64(confWinRightOffset)) * subWidthC
        guard reader.ok, widthCrop < picWidthInLumaSamples else {
            return nil
        }
        let heightCrop = (UInt64(confWinTopOffset) + UInt64(confWinBottomOffset)) * subHeightC
        guard reader.ok, heightCrop < picHeightInLumaSamples else {
            return nil
        }
    }

    sps.bitDepthLumaMinus8 = reader.readExpGolomb()
    guard reader.ok, sps.bitDepthLumaMinus8 <= 8 else {
        return nil
    }
    let bitDepthChromaMinus8 = reader.readExpGolomb()
    guard reader.ok, bitDepthChromaMinus8 <= 8 else {
        return nil
    }
    sps.log2MaxPicOrderCntLsbMinus4 = reader.readExpGolomb()
    guard reader.ok, sps.log2MaxPicOrderCntLsbMinus4 <= 12 else {
        return nil
    }

    // Each sub-layer's values may not be below the previous sub-layer's; those before the first one read count as 0.
    let spsSubLayerOrderingInfoPresentFlag = reader.readFlag()
    var previousMaxDecPicBufferingMinus1: UInt32 = 0
    var previousMaxNumReorderPics: UInt32 = 0
    for _ in (spsSubLayerOrderingInfoPresentFlag ? 0 : spsMaxSubLayersMinus1)...spsMaxSubLayersMinus1 {
        let spsMaxDecPicBufferingMinus1 = reader.readExpGolomb()
        guard reader.ok, spsMaxDecPicBufferingMinus1 + 1 <= maxDpbSize else {
            return nil
        }
        let spsMaxNumReorderPics = reader.readExpGolomb()
        guard reader.ok, spsMaxNumReorderPics <= spsMaxDecPicBufferingMinus1,
            spsMaxDecPicBufferingMinus1 >= previousMaxDecPicBufferingMinus1, spsMaxNumReorderPics >= previousMaxNumReorderPics
        else {
            return nil
        }
        // sps_max_latency_increase_plus1
        _ = reader.readExpGolomb()
        previousMaxDecPicBufferingMinus1 = spsMaxDecPicBufferingMinus1
        previousMaxNumReorderPics = spsMaxNumReorderPics
    }
    sps.maxDecPicBufferingMinus1 = previousMaxDecPicBufferingMinus1

    let log2MinLumaCodingBlockSizeMinus3 = reader.readExpGolomb()
    guard reader.ok, log2MinLumaCodingBlockSizeMinus3 <= 27 else {
        return nil
    }
    sps.log2DiffMaxMinLumaCodingBlockSize = reader.readExpGolomb()
    let minCbLog2SizeY = log2MinLumaCodingBlockSizeMinus3 + 3
    // Wrapping arithmetic.
    sps.ctbLog2SizeY = minCbLog2SizeY &+ sps.log2DiffMaxMinLumaCodingBlockSize
    guard reader.ok, sps.ctbLog2SizeY <= 30 else {
        return nil
    }
    let minCbSizeY: UInt32 = 1 << minCbLog2SizeY
    let ctbSizeY: UInt32 = 1 << sps.ctbLog2SizeY
    // Wrapping arithmetic.
    sps.picWidthInCtbsY = (picWidthInLumaSamples &+ ctbSizeY &- 1) / ctbSizeY
    sps.picHeightInCtbsY = (picHeightInLumaSamples &+ ctbSizeY &- 1) / ctbSizeY
    guard picWidthInLumaSamples % minCbSizeY == 0, picHeightInLumaSamples % minCbSizeY == 0 else {
        return nil
    }

    let log2MinLumaTransformBlockSizeMinus2 = reader.readExpGolomb()
    guard reader.ok, log2MinLumaTransformBlockSizeMinus2 <= minCbLog2SizeY - 3 else {
        return nil
    }
    let minTbLog2SizeY = log2MinLumaTransformBlockSizeMinus2 + 2
    // These three limits use wrapping arithmetic.
    let log2DiffMaxMinLumaTransformBlockSize = reader.readExpGolomb()
    guard reader.ok, log2DiffMaxMinLumaTransformBlockSize <= min(sps.ctbLog2SizeY, 5) &- minTbLog2SizeY else {
        return nil
    }
    let maxTransformHierarchyDepthInter = reader.readExpGolomb()
    guard reader.ok, maxTransformHierarchyDepthInter <= sps.ctbLog2SizeY &- minTbLog2SizeY else {
        return nil
    }
    let maxTransformHierarchyDepthIntra = reader.readExpGolomb()
    guard reader.ok, maxTransformHierarchyDepthIntra <= sps.ctbLog2SizeY &- minTbLog2SizeY else {
        return nil
    }

    let scalingListEnabledFlag = reader.readFlag()
    if scalingListEnabledFlag {
        let spsScalingListDataPresentFlag = reader.readFlag()
        if spsScalingListDataPresentFlag && !parseScalingListData(&reader) {
            return nil
        }
    }

    // amp_enabled_flag
    reader.consumeBits(1)
    sps.sampleAdaptiveOffsetEnabledFlag = reader.readFlag()
    let pcmEnabledFlag = reader.readFlag()
    if pcmEnabledFlag {
        // pcm_sample_bit_depth_luma_minus1, pcm_sample_bit_depth_chroma_minus1
        reader.consumeBits(8)
        let log2MinPcmLumaCodingBlockSizeMinus3 = reader.readExpGolomb()
        guard reader.ok, log2MinPcmLumaCodingBlockSizeMinus3 <= 2 else {
            return nil
        }
        let log2MinIpcmCbSizeY = log2MinPcmLumaCodingBlockSizeMinus3 + 3
        guard reader.ok, log2MinIpcmCbSizeY >= min(minCbLog2SizeY, 5), log2MinIpcmCbSizeY <= min(sps.ctbLog2SizeY, 5) else {
            return nil
        }
        let log2DiffMaxMinPcmLumaCodingBlockSize = reader.readExpGolomb()
        guard reader.ok, log2DiffMaxMinPcmLumaCodingBlockSize <= min(sps.ctbLog2SizeY, 5) - log2MinIpcmCbSizeY else {
            return nil
        }
        // pcm_loop_filter_disabled_flag
        reader.consumeBits(1)
    }

    let numShortTermRefPicSets = reader.readExpGolomb()
    guard reader.ok, numShortTermRefPicSets <= maxShortTermRefPicSets else {
        return nil
    }
    sps.shortTermRefPicSets.reserveCapacity(Int(numShortTermRefPicSets))
    for stRpsIndex in 0..<numShortTermRefPicSets {
        guard
            let refPicSet = parseShortTermRefPicSet(
                stRpsIndex,
                numShortTermRefPicSets: numShortTermRefPicSets,
                sps.shortTermRefPicSets,
                spsMaxDecPicBufferingMinus1: sps.maxDecPicBufferingMinus1,
                &reader
            )
        else {
            return nil
        }
        sps.shortTermRefPicSets.append(refPicSet)
    }

    sps.longTermRefPicsPresentFlag = reader.readFlag()
    if sps.longTermRefPicsPresentFlag {
        sps.numLongTermRefPicsSps = reader.readExpGolomb()
        guard reader.ok, sps.numLongTermRefPicsSps <= maxLongTermRefPicSets else {
            return nil
        }
        for i in 0..<sps.numLongTermRefPicsSps {
            // lt_ref_pic_poc_lsb_sps[i]
            reader.consumeBits(Int(sps.log2MaxPicOrderCntLsbMinus4) + 4)
            if reader.readFlag() {
                sps.usedByCurrPicLtSpsFlags |= 1 << i
            }
        }
    }

    sps.spsTemporalMvpEnabledFlag = reader.readFlag()

    // The rest of the SPS isn't needed.
    sps.picWidthInLumaSamples = picWidthInLumaSamples
    sps.picHeightInLumaSamples = picHeightInLumaSamples

    guard reader.ok else {
        return nil
    }
    return sps
}

// MARK: PPS

// FIXME: Make this private once a private type links under ThinLTO on Windows ("Invalid weak external").
struct HEVCPpsState {
    var spsID: UInt32 = 0
    var dependentSliceSegmentsEnabledFlag = false
    var outputFlagPresentFlag = false
    var numExtraSliceHeaderBits: UInt32 = 0
    var cabacInitPresentFlag = false
    var numRefIdxL0DefaultActiveMinus1: UInt32 = 0
    var numRefIdxL1DefaultActiveMinus1: UInt32 = 0
    var initQPMinus26: Int32 = 0
    var qpBdOffsetY: Int32 = 0
    var weightedPredFlag = false
    var weightedBipredFlag = false
    var listsModificationPresentFlag = false
}

// column_width_minus1[] or row_height_minus1[]: each must leave at least one CTB for the last tile. The arithmetic is
// int32_t, wrapping.
private func parseTileSizes(count: UInt32, ctbs: UInt32, _ reader: inout RbspBitReader) -> Bool {
    var remaining = Int32(truncatingIfNeeded: ctbs) &- 1
    for _ in 0..<count {
        let sizeMinus1 = Int32(truncatingIfNeeded: reader.readExpGolomb())
        guard reader.ok, sizeMinus1 >= 0, sizeMinus1 <= remaining &- 1 else {
            return false
        }
        remaining = remaining &- (sizeMinus1 &+ 1)
    }
    return true
}

// 7.3.2.3.1, from after pps_seq_parameter_set_id up to lists_modification_present_flag.
private func parsePps(_ reader: inout RbspBitReader, sps: HEVCSpsState) -> HEVCPpsState? {
    var pps = HEVCPpsState()

    pps.dependentSliceSegmentsEnabledFlag = reader.readFlag()
    pps.outputFlagPresentFlag = reader.readFlag()
    pps.numExtraSliceHeaderBits = reader.readBits(3)
    guard reader.ok, pps.numExtraSliceHeaderBits <= 2 else {
        return nil
    }
    // sign_data_hiding_enabled_flag
    reader.consumeBits(1)
    pps.cabacInitPresentFlag = reader.readFlag()

    pps.numRefIdxL0DefaultActiveMinus1 = reader.readExpGolomb()
    guard reader.ok, pps.numRefIdxL0DefaultActiveMinus1 <= maxRefIdxActive - 1 else {
        return nil
    }
    pps.numRefIdxL1DefaultActiveMinus1 = reader.readExpGolomb()
    guard reader.ok, pps.numRefIdxL1DefaultActiveMinus1 <= maxRefIdxActive - 1 else {
        return nil
    }

    pps.initQPMinus26 = reader.readSignedExpGolomb()
    pps.qpBdOffsetY = 6 * Int32(sps.bitDepthLumaMinus8)
    guard reader.ok, pps.initQPMinus26 >= -(26 + pps.qpBdOffsetY), pps.initQPMinus26 <= 25 else {
        return nil
    }

    // constrained_intra_pred_flag, transform_skip_enabled_flag
    reader.consumeBits(2)
    let cuQpDeltaEnabledFlag = reader.readFlag()
    if cuQpDeltaEnabledFlag {
        let diffCuQpDeltaDepth = reader.readExpGolomb()
        guard reader.ok, diffCuQpDeltaDepth <= sps.log2DiffMaxMinLumaCodingBlockSize else {
            return nil
        }
    }
    let ppsCbQpOffset = reader.readSignedExpGolomb()
    guard reader.ok, (-12...12).contains(ppsCbQpOffset) else {
        return nil
    }
    let ppsCrQpOffset = reader.readSignedExpGolomb()
    guard reader.ok, (-12...12).contains(ppsCrQpOffset) else {
        return nil
    }
    // pps_slice_chroma_qp_offsets_present_flag
    reader.consumeBits(1)
    pps.weightedPredFlag = reader.readFlag()
    pps.weightedBipredFlag = reader.readFlag()
    // transquant_bypass_enabled_flag
    reader.consumeBits(1)
    let tilesEnabledFlag = reader.readFlag()
    // entropy_coding_sync_enabled_flag
    reader.consumeBits(1)
    if tilesEnabledFlag {
        let maxNumTileColumnWidth: UInt32 = 19
        let maxNumTileRowHeight: UInt32 = 21
        let numTileColumnsMinus1 = reader.readExpGolomb()
        guard reader.ok, sps.picWidthInCtbsY != 0, numTileColumnsMinus1 <= sps.picWidthInCtbsY - 1,
            numTileColumnsMinus1 < maxNumTileColumnWidth
        else {
            return nil
        }
        let numTileRowsMinus1 = reader.readExpGolomb()
        guard reader.ok, sps.picHeightInCtbsY != 0, numTileRowsMinus1 <= sps.picHeightInCtbsY - 1 else {
            return nil
        }
        guard numTileColumnsMinus1 != 0 || numTileRowsMinus1 != 0, numTileRowsMinus1 < maxNumTileRowHeight else {
            return nil
        }
        let uniformSpacingFlag = reader.readFlag()
        if !uniformSpacingFlag {
            guard parseTileSizes(count: numTileColumnsMinus1, ctbs: sps.picWidthInCtbsY, &reader),
                parseTileSizes(count: numTileRowsMinus1, ctbs: sps.picHeightInCtbsY, &reader)
            else {
                return nil
            }
            // loop_filter_across_tiles_enabled_flag, read only without uniform spacing.
            reader.consumeBits(1)
        }
    }
    // pps_loop_filter_across_slices_enabled_flag
    reader.consumeBits(1)
    let deblockingFilterControlPresentFlag = reader.readFlag()
    if deblockingFilterControlPresentFlag {
        // deblocking_filter_override_enabled_flag
        reader.consumeBits(1)
        let ppsDeblockingFilterDisabledFlag = reader.readFlag()
        if !ppsDeblockingFilterDisabledFlag {
            let ppsBetaOffsetDiv2 = reader.readSignedExpGolomb()
            guard reader.ok, (-6...6).contains(ppsBetaOffsetDiv2) else {
                return nil
            }
            let ppsTcOffsetDiv2 = reader.readSignedExpGolomb()
            guard reader.ok, (-6...6).contains(ppsTcOffsetDiv2) else {
                return nil
            }
        }
    }
    let ppsScalingListDataPresentFlag = reader.readFlag()
    if ppsScalingListDataPresentFlag && !parseScalingListData(&reader) {
        return nil
    }
    pps.listsModificationPresentFlag = reader.readFlag()

    guard reader.ok else {
        return nil
    }
    return pps
}

// MARK: Slice header

private func readWeightFlags(count: UInt32, _ reader: inout RbspBitReader) -> UInt16 {
    var flags: UInt16 = 0
    for i in 0..<count {
        flags |= reader.readFlag() ? 1 << i : 0
    }
    return flags
}

// The weights and offsets of one list, for the entries whose flag is set. WpOffsetHalfRangeY and WpOffsetHalfRangeC
// are 1 << 7: the range extension isn't supported.
private func parseWeights(lumaWeightFlags: UInt16, chromaWeightFlags: UInt16, count: UInt32, _ reader: inout RbspBitReader) -> Bool {
    let wpOffsetHalfRange: Int32 = 1 << 7
    for i in 0..<count {
        if lumaWeightFlags & (1 << i) != 0 {
            let deltaLumaWeight = reader.readSignedExpGolomb()
            guard reader.ok, (-128...127).contains(deltaLumaWeight) else {
                return false
            }
            let lumaOffset = reader.readSignedExpGolomb()
            guard reader.ok, (-wpOffsetHalfRange...(wpOffsetHalfRange - 1)).contains(lumaOffset) else {
                return false
            }
        }
        if chromaWeightFlags & (1 << i) != 0 {
            for _ in 0..<2 {
                let deltaChromaWeight = reader.readSignedExpGolomb()
                guard reader.ok, (-128...127).contains(deltaChromaWeight) else {
                    return false
                }
                let deltaChromaOffset = reader.readSignedExpGolomb()
                guard reader.ok, (-4 * wpOffsetHalfRange...(4 * wpOffsetHalfRange - 1)).contains(deltaChromaOffset) else {
                    return false
                }
            }
        }
    }
    return true
}

// 7.3.6.3; only checks the values' ranges. As in libwebrtc, luma_weight_l1_flag is read for one entry fewer than the
// spec says.
private func parsePredWeightTable(
    _ reader: inout RbspBitReader,
    chromaArrayType: UInt32,
    numRefIdxL0ActiveMinus1: UInt32,
    isBSlice: Bool,
    numRefIdxL1ActiveMinus1: UInt32
) -> Bool {
    guard numRefIdxL0ActiveMinus1 < maxRefIdxActive, !isBSlice || numRefIdxL1ActiveMinus1 < maxRefIdxActive else {
        return false
    }

    let lumaLog2WeightDenom = reader.readExpGolomb()
    guard reader.ok, lumaLog2WeightDenom <= 7 else {
        return false
    }
    var chromaLog2WeightDenom = Int32(lumaLog2WeightDenom)
    if chromaArrayType != 0 {
        let deltaChromaLog2WeightDenom = reader.readSignedExpGolomb()
        guard reader.ok, (-7...7).contains(deltaChromaLog2WeightDenom) else {
            return false
        }
        chromaLog2WeightDenom += deltaChromaLog2WeightDenom
    }
    guard reader.ok, (0...7).contains(chromaLog2WeightDenom) else {
        return false
    }

    let countL0 = numRefIdxL0ActiveMinus1 + 1
    let lumaWeightL0Flags = readWeightFlags(count: countL0, &reader)
    let chromaWeightL0Flags = chromaArrayType != 0 ? readWeightFlags(count: countL0, &reader) : 0
    guard parseWeights(lumaWeightFlags: lumaWeightL0Flags, chromaWeightFlags: chromaWeightL0Flags, count: countL0, &reader) else {
        return false
    }

    if isBSlice {
        let countL1 = numRefIdxL1ActiveMinus1 + 1
        let lumaWeightL1Flags = readWeightFlags(count: numRefIdxL1ActiveMinus1, &reader)
        let chromaWeightL1Flags = chromaArrayType != 0 ? readWeightFlags(count: countL1, &reader) : 0
        guard parseWeights(lumaWeightFlags: lumaWeightL1Flags, chromaWeightFlags: chromaWeightL1Flags, count: countL1, &reader) else {
            return false
        }
    }

    return true
}

// MARK: The stateful parser

// What lastSliceQP() found; HEVCBitstreamParser.cpp logs the failures.
private enum LastSliceQPResult: UInt8 {
    case found
    case missingInfo
    case missingPps
    case invalidQP
}

// HEVCBitstreamParser's state: the SPSs and PPSs seen so far, by id, and the last slice's QP delta and PPS.
@_expose(Cxx)
final class HEVCSliceQPParser {
    private var spsStates = [HEVCSpsState?](repeating: nil, count: 16)
    private var ppsStates = [HEVCPpsState?](repeating: nil, count: 64)
    private var lastSliceQPDelta: Int32?
    private var lastSlicePpsID: UInt32?

    @_expose(Cxx)
    init() {
    }

    @_expose(Cxx)
    func parseBitstream(_ bitstream: borrowing WebCore.MediaParserBytes) {
        let bytes: Span<UInt8> = bitstream.span()
        var scanner = NaluIndexScanner(bytes)
        while let index = scanner.next() {
            parseNalu(bytes.extracting(index.payloadStartOffset..<(index.payloadStartOffset + index.payloadSize)))
        }
    }

    // A LastSliceQPResult, and the QP when it is found.
    @_expose(Cxx)
    func lastSliceQP() -> WebCore.SliceQPResult {
        var result = WebCore.SliceQPResult()
        guard let lastSliceQPDelta, let lastSlicePpsID else {
            result.status = LastSliceQPResult.missingInfo.rawValue
            return result
        }
        guard let pps = ppsState(lastSlicePpsID) else {
            result.status = LastSliceQPResult.missingPps.rawValue
            return result
        }
        let parsedQP = 26 + pps.initQPMinus26 + lastSliceQPDelta
        guard (0...51).contains(parsedQP) else {
            result.status = LastSliceQPResult.invalidQP.rawValue
            return result
        }
        result.qp = parsedQP
        result.status = LastSliceQPResult.found.rawValue
        return result
    }

    private func spsState(_ id: UInt32) -> HEVCSpsState? {
        id < spsStates.count ? spsStates[Int(id)] : nil
    }

    private func ppsState(_ id: UInt32) -> HEVCPpsState? {
        id < ppsStates.count ? ppsStates[Int(id)] : nil
    }

    private func parseNalu(_ nalu: Span<UInt8>) {
        guard !nalu.isEmpty else {
            return
        }

        let naluType = hevcNaluType(nalu[0])
        switch naluType {
        case H265NaluType.sps:
            guard nalu.count >= hevcNaluHeaderSize, let sps = parseSps(nalu.extracting(droppingFirst: hevcNaluHeaderSize)) else {
                return
            }
            spsStates[Int(sps.spsID)] = sps
        case H265NaluType.pps:
            guard nalu.count >= hevcNaluHeaderSize else {
                return
            }
            var reader = RbspBitReader(nalu.extracting(droppingFirst: hevcNaluHeaderSize))
            let ppsID = reader.readExpGolomb()
            let spsID = reader.readExpGolomb()
            guard reader.ok, ppsID <= 63, spsID <= 15, let sps = spsState(spsID), var pps = parsePps(&reader, sps: sps) else {
                return
            }
            pps.spsID = spsID
            ppsStates[Int(ppsID)] = pps
        case H265NaluType.vps, H265NaluType.aud, H265NaluType.prefixSei, H265NaluType.suffixSei, H265NaluType.ap, H265NaluType.fu:
            break
        default:
            parseSliceHeader(nalu, naluType: naluType)
        }
    }

    // 7.3.6.1 up to slice_qp_delta, for every NAL unit type not handled above. Clears the last slice's QP unless this
    // one gives a valid one.
    private func parseSliceHeader(_ nalu: Span<UInt8>, naluType: UInt8) {
        lastSliceQPDelta = nil
        lastSlicePpsID = nil

        var reader = RbspBitReader(nalu)
        guard reader.hasRbspSize(atLeast: hevcNaluHeaderSize) else {
            return
        }
        reader.consumeBits(hevcNaluHeaderSize * 8)

        let firstSliceSegmentInPicFlag = reader.readFlag()
        if (H265NaluType.blaWLp...H265NaluType.rsvIrapVcl23).contains(naluType) {
            // no_output_of_prior_pics_flag
            reader.consumeBits(1)
        }
        let slicePicParameterSetID = reader.readExpGolomb()
        guard reader.ok, slicePicParameterSetID <= 63, let pps = ppsState(slicePicParameterSetID), let sps = spsState(pps.spsID) else {
            return
        }

        var dependentSliceSegmentFlag = false
        if !firstSliceSegmentInPicFlag {
            if pps.dependentSliceSegmentsEnabledFlag {
                dependentSliceSegmentFlag = reader.readFlag()
            }

            // slice_segment_address. The SPS checked that CtbLog2SizeY is at most 30.
            let ctbSizeY: UInt32 = 1 << sps.ctbLog2SizeY
            var picWidthInCtbsY = sps.picWidthInLumaSamples / ctbSizeY
            if sps.picWidthInLumaSamples % ctbSizeY != 0 {
                picWidthInCtbsY += 1
            }
            var picHeightInCtbsY = sps.picHeightInLumaSamples / ctbSizeY
            if sps.picHeightInLumaSamples % ctbSizeY != 0 {
                picHeightInCtbsY += 1
            }
            // Wrapping arithmetic.
            let sliceSegmentAddressBits = hevcLog2Ceiling(picHeightInCtbsY &* picWidthInCtbsY)
            guard reader.ok, sliceSegmentAddressBits != .max else {
                return
            }
            reader.consumeBits(Int(sliceSegmentAddressBits))
        }

        if !dependentSliceSegmentFlag {
            guard parseIndependentSliceSegmentHeader(&reader, naluType: naluType, pps: pps, sps: sps) else {
                return
            }
        }

        let sliceQPDelta = reader.readSignedExpGolomb()
        guard reader.ok, (-51...51).contains(sliceQPDelta) else {
            return
        }
        // Equation 7-54.
        let sliceQPY = 26 + pps.initQPMinus26 + sliceQPDelta
        guard sliceQPY >= -pps.qpBdOffsetY, sliceQPY <= 51 else {
            return
        }

        lastSliceQPDelta = sliceQPDelta
        lastSlicePpsID = slicePicParameterSetID
    }

    // From slice_reserved_flag up to five_minus_max_num_merge_cand.
    private func parseIndependentSliceSegmentHeader(
        _ reader: inout RbspBitReader,
        naluType: UInt8,
        pps: HEVCPpsState,
        sps: HEVCSpsState
    ) -> Bool {
        // slice_reserved_flag[i]
        reader.consumeBits(Int(pps.numExtraSliceHeaderBits))
        let sliceType = reader.readExpGolomb()
        guard reader.ok, sliceType <= 2 else {
            return false
        }
        if pps.outputFlagPresentFlag {
            // pic_output_flag
            reader.consumeBits(1)
        }
        if sps.separateColourPlaneFlag {
            // colour_plane_id
            reader.consumeBits(2)
        }

        var shortTermRefPicSetSpsFlag = false
        var shortTermRefPicSetIndex: UInt32 = 0
        var sliceShortTermRefPicSet = HEVCShortTermRefPicSet()
        var numLongTermSps: UInt32 = 0
        var numLongTermPics: UInt32 = 0
        // Bit i: UsedByCurrPicLt[i].
        var usedByCurrPicLtFlags: UInt64 = 0
        var sliceTemporalMvpEnabledFlag = false

        if naluType != H265NaluType.idrWRadl && naluType != H265NaluType.idrNLp {
            // slice_pic_order_cnt_lsb
            reader.consumeBits(Int(sps.log2MaxPicOrderCntLsbMinus4) + 4)
            shortTermRefPicSetSpsFlag = reader.readFlag()
            if !shortTermRefPicSetSpsFlag {
                guard
                    let refPicSet = parseShortTermRefPicSet(
                        sps.numShortTermRefPicSets,
                        numShortTermRefPicSets: sps.numShortTermRefPicSets,
                        sps.shortTermRefPicSets,
                        spsMaxDecPicBufferingMinus1: sps.maxDecPicBufferingMinus1,
                        &reader
                    )
                else {
                    return false
                }
                sliceShortTermRefPicSet = refPicSet
            } else if sps.numShortTermRefPicSets > 1 {
                var shortTermRefPicSetIndexBits = hevcLog2Ceiling(sps.numShortTermRefPicSets)
                if (1 << shortTermRefPicSetIndexBits) < sps.numShortTermRefPicSets {
                    shortTermRefPicSetIndexBits += 1
                }
                if shortTermRefPicSetIndexBits > 0 {
                    shortTermRefPicSetIndex = reader.readBits(Int(shortTermRefPicSetIndexBits))
                    guard reader.ok, shortTermRefPicSetIndex <= sps.numShortTermRefPicSets - 1 else {
                        return false
                    }
                }
            }
            if sps.longTermRefPicsPresentFlag {
                if sps.numLongTermRefPicsSps > 0 {
                    numLongTermSps = reader.readExpGolomb()
                    guard reader.ok, numLongTermSps <= sps.numLongTermRefPicsSps else {
                        return false
                    }
                }
                numLongTermPics = reader.readExpGolomb()
                guard reader.ok, numLongTermPics <= maxLongTermRefPicSets - numLongTermSps else {
                    return false
                }
                for i in 0..<(numLongTermSps + numLongTermPics) {
                    if i < numLongTermSps {
                        var ltIdxSps: UInt32 = 0
                        if sps.numLongTermRefPicsSps > 1 {
                            ltIdxSps = reader.readBits(Int(hevcLog2Ceiling(sps.numLongTermRefPicsSps)))
                            guard reader.ok, ltIdxSps <= sps.numLongTermRefPicsSps - 1 else {
                                return false
                            }
                        }
                        if ltIdxSps < sps.numLongTermRefPicsSps && sps.usedByCurrPicLtSpsFlags & (1 << ltIdxSps) != 0 {
                            usedByCurrPicLtFlags |= 1 << i
                        }
                    } else {
                        // poc_lsb_lt[i]
                        reader.consumeBits(Int(sps.log2MaxPicOrderCntLsbMinus4) + 4)
                        if reader.readFlag() {
                            usedByCurrPicLtFlags |= 1 << i
                        }
                    }
                    let deltaPocMsbPresentFlag = reader.readFlag()
                    if deltaPocMsbPresentFlag {
                        // delta_poc_msb_cycle_lt[i]
                        _ = reader.readExpGolomb()
                    }
                }
            }
            if sps.spsTemporalMvpEnabledFlag {
                sliceTemporalMvpEnabledFlag = reader.readFlag()
            }
        }

        if sps.sampleAdaptiveOffsetEnabledFlag {
            // slice_sao_luma_flag
            reader.consumeBits(1)
            if sps.chromaArrayType != 0 {
                // slice_sao_chroma_flag
                reader.consumeBits(1)
            }
        }

        guard sliceType == H265SliceType.p || sliceType == H265SliceType.b else {
            return true
        }
        let isBSlice = sliceType == H265SliceType.b

        var numRefIdxL0ActiveMinus1 = pps.numRefIdxL0DefaultActiveMinus1
        var numRefIdxL1ActiveMinus1 = pps.numRefIdxL1DefaultActiveMinus1
        let numRefIdxActiveOverrideFlag = reader.readFlag()
        if numRefIdxActiveOverrideFlag {
            numRefIdxL0ActiveMinus1 = reader.readExpGolomb()
            guard reader.ok, numRefIdxL0ActiveMinus1 <= maxRefIdxActive - 1 else {
                return false
            }
            if isBSlice {
                numRefIdxL1ActiveMinus1 = reader.readExpGolomb()
                guard reader.ok, numRefIdxL1ActiveMinus1 <= maxRefIdxActive - 1 else {
                    return false
                }
            }
        }

        // Equation 7-55.
        let currRpsIndex = shortTermRefPicSetSpsFlag ? shortTermRefPicSetIndex : sps.numShortTermRefPicSets
        let refPicSet = currRpsIndex < sps.numShortTermRefPicSets ? sps.shortTermRefPicSets[Int(currRpsIndex)] : sliceShortTermRefPicSet
        guard reader.ok, refPicSet.numNegativePics <= maxShortTermRefPicSets, refPicSet.numPositivePics <= maxShortTermRefPicSets else {
            return false
        }
        var numPicTotalCurr = UInt32(usedByCurrPicLtFlags.nonzeroBitCount)
        for picture in refPicSet.pictures where picture.usedByCurrPic {
            numPicTotalCurr += 1
        }

        if pps.listsModificationPresentFlag && numPicTotalCurr > 1 {
            // ref_pic_lists_modification(); as in libwebrtc, one list_entry fewer than the spec says.
            var listEntryBits = hevcLog2Ceiling(numPicTotalCurr)
            if (1 << listEntryBits) < numPicTotalCurr {
                listEntryBits += 1
            }
            let refPicListModificationFlagL0 = reader.readFlag()
            if refPicListModificationFlagL0 {
                // list_entry_l0[i]
                reader.consumeBits(Int(numRefIdxL0ActiveMinus1 * listEntryBits))
            }
            if isBSlice {
                let refPicListModificationFlagL1 = reader.readFlag()
                if refPicListModificationFlagL1 {
                    // list_entry_l1[i]
                    reader.consumeBits(Int(numRefIdxL1ActiveMinus1 * listEntryBits))
                }
            }
        }
        if isBSlice {
            // mvd_l1_zero_flag
            reader.consumeBits(1)
        }
        if pps.cabacInitPresentFlag {
            // cabac_init_flag
            reader.consumeBits(1)
        }
        if sliceTemporalMvpEnabledFlag {
            // As in libwebrtc, collocated_from_l0_flag is 0 when absent, where the spec infers 1.
            let collocatedFromL0Flag = isBSlice ? reader.readFlag() : false
            let numRefIdxActiveMinus1 = collocatedFromL0Flag ? numRefIdxL0ActiveMinus1 : numRefIdxL1ActiveMinus1
            if numRefIdxActiveMinus1 > 0 {
                let collocatedRefIdx = reader.readExpGolomb()
                guard reader.ok, collocatedRefIdx <= numRefIdxActiveMinus1 else {
                    return false
                }
            }
        }

        if (pps.weightedPredFlag && !isBSlice) || (pps.weightedBipredFlag && isBSlice) {
            guard
                parsePredWeightTable(
                    &reader,
                    chromaArrayType: sps.chromaArrayType,
                    numRefIdxL0ActiveMinus1: numRefIdxL0ActiveMinus1,
                    isBSlice: isBSlice,
                    numRefIdxL1ActiveMinus1: numRefIdxL1ActiveMinus1
                )
            else {
                return false
            }
        }

        let fiveMinusMaxNumMergeCand = reader.readExpGolomb()
        return reader.ok && fiveMinusMaxNumMergeCand <= 4
    }
}

// MARK: Annex B locators

// The NAL unit type in the first byte of `index`'s payload, read whatever payloadSize is; nil when that byte is outside
// `data`.
private func naluType(of index: WebCore.NaluIndex, in data: Span<UInt8>) -> UInt8? {
    guard index.payloadStartOffset < data.count else {
        return nil
    }
    return hevcNaluType(data[index.payloadStartOffset])
}

// Whether `index`'s payload is inside `data`.
private func payloadIsInside(_ index: WebCore.NaluIndex, _ data: Span<UInt8>) -> Bool {
    index.payloadStartOffset <= data.count && index.payloadSize <= data.count - index.payloadStartOffset
}

// The position of the first VPS in `indices`; nil if there is none, or if an index before it points past `data`.
func findHEVCAnnexBVpsIndex(_ data: Span<UInt8>, _ indices: Span<WebCore.NaluIndex>) -> Int? {
    var position = 0
    while position < indices.count {
        guard let type = naluType(of: indices[position], in: data) else {
            return nil
        }
        if type == H265NaluType.vps {
            return position
        }
        position += 1
    }
    return nil
}

private func hevcAnnexBVpsIsFollowedBySpsAndPps(_ data: Span<UInt8>, _ indices: Span<WebCore.NaluIndex>, vpsIndex: Int) -> Bool {
    guard vpsIndex < indices.count - 2 else {
        return false
    }
    let spsIndex = indices[vpsIndex + 1]
    let ppsIndex = indices[vpsIndex + 2]
    return spsIndex.payloadSize != 0 && naluType(of: spsIndex, in: data) == H265NaluType.sps
        && ppsIndex.payloadSize != 0 && naluType(of: ppsIndex, in: data) == H265NaluType.pps
}

// What findHEVCAnnexBParameterSetsImpl() found; HEVCUtilitiesCocoa.mm logs notFollowedBySpsAndPps.
private enum ParameterSetSearchResult: UInt8 {
    case notFound
    case notFollowedBySpsAndPps
    case found
}

private func parameterSetRange(_ index: WebCore.NaluIndex, type: UInt8) -> WebCore.ParameterSetRange {
    var range = WebCore.ParameterSetRange()
    range.type = type
    range.offset = index.payloadStartOffset
    range.size = index.payloadSize
    return range
}

// Entry points for HEVCBitstreamParser.cpp and HEVCUtilitiesCocoa.mm.

// `vps` is a whole VPS NAL unit.
@_expose(Cxx)
func parseHEVCVpsMaxNumReorderPicsImpl(_ vps: borrowing WebCore.MediaParserBytes, _ maxNumReorderPics: inout UInt8) -> Bool {
    let bytes: Span<UInt8> = vps.span()
    guard let value = parseHEVCVpsMaxNumReorderPics(bytes) else {
        return false
    }
    maxNumReorderPics = value
    return true
}

// The first VPS, and the SPS and PPS that must follow it. Returns a ParameterSetSearchResult; the ranges are set when
// they are found.
@_expose(Cxx)
func findHEVCAnnexBParameterSetsImpl(
    _ data: borrowing WebCore.MediaParserBytes,
    _ indices: borrowing WebCore.MediaParserNaluIndices,
    _ vps: inout WebCore.ParameterSetRange,
    _ sps: inout WebCore.ParameterSetRange,
    _ pps: inout WebCore.ParameterSetRange
) -> UInt8 {
    let bytes: Span<UInt8> = data.span()
    let naluIndices: Span<WebCore.NaluIndex> = indices.span()
    guard let vpsIndex = findHEVCAnnexBVpsIndex(bytes, naluIndices) else {
        return ParameterSetSearchResult.notFound.rawValue
    }
    guard hevcAnnexBVpsIsFollowedBySpsAndPps(bytes, naluIndices, vpsIndex: vpsIndex) else {
        return ParameterSetSearchResult.notFollowedBySpsAndPps.rawValue
    }
    let vpsIndexValue = naluIndices[vpsIndex]
    let spsIndexValue = naluIndices[vpsIndex + 1]
    let ppsIndexValue = naluIndices[vpsIndex + 2]
    guard payloadIsInside(vpsIndexValue, bytes), payloadIsInside(spsIndexValue, bytes), payloadIsInside(ppsIndexValue, bytes) else {
        return ParameterSetSearchResult.notFound.rawValue
    }
    vps = parameterSetRange(vpsIndexValue, type: H265NaluType.vps)
    sps = parameterSetRange(spsIndexValue, type: H265NaluType.sps)
    pps = parameterSetRange(ppsIndexValue, type: H265NaluType.pps)
    return ParameterSetSearchResult.found.rawValue
}

// The NAL units after the first VPS and the SPS and PPS that follow it, or all of them when there is no VPS or it isn't
// followed by an SPS and a PPS. Returns false in that last case.
@_expose(Cxx)
func convertHEVCAnnexBToLengthPrefixedImpl(
    _ data: borrowing WebCore.MediaParserBytes,
    _ indices: borrowing WebCore.MediaParserNaluIndices,
    _ output: inout WebCore.MediaParserByteVector
) -> Bool {
    let bytes: Span<UInt8> = data.span()
    let naluIndices: Span<WebCore.NaluIndex> = indices.span()
    var startIndex = 0
    var vpsIsFollowedBySpsAndPps = true
    if let vpsIndex = findHEVCAnnexBVpsIndex(bytes, naluIndices) {
        if hevcAnnexBVpsIsFollowedBySpsAndPps(bytes, naluIndices, vpsIndex: vpsIndex) {
            startIndex = vpsIndex + 3
        } else {
            vpsIsFollowedBySpsAndPps = false
        }
    }
    appendLengthPrefixed(naluIndices.extracting(startIndex..<naluIndices.count), of: bytes, to: &output)
    return vpsIsFollowedBySpsAndPps
}

#endif // ENABLE_WEBCORE_SWIFT
