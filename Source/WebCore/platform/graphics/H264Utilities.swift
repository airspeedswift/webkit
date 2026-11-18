// Copyright (C) 2025 Apple Inc. All rights reserved.
// Copyright (C) 2026 Apple Inc. All rights reserved.
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

private let h264NaluHeaderSize = 1

// See section 7.4.1 of the H.264 spec.
private let h264NaluTypeIdr: UInt8 = 5
private let h264NaluTypeSei: UInt8 = 6
private let h264NaluTypeSps: UInt8 = 7
private let h264NaluTypePps: UInt8 = 8
private let h264NaluTypeAud: UInt8 = 9
private let h264NaluTypeFiller: UInt8 = 12
private let h264NaluTypePrefix: UInt8 = 14

// See table 7-6 of the H.264 spec.
private let h264SliceTypeP: UInt32 = 0
private let h264SliceTypeB: UInt32 = 1
private let h264SliceTypeI: UInt32 = 2
private let h264SliceTypeSp: UInt32 = 3
private let h264SliceTypeSi: UInt32 = 4

// The failures H264Utilities.cpp logs, with the raw values of H264BitstreamParserLogEvent there.
private enum H264ParserLogEvent: UInt8 {
    case none
    case unsupportedNaluType
    case qpDeltaOutOfRange
    case missingInfo
    case invalidQP
}

private func h264NaluType(_ byte: UInt8) -> UInt8 {
    byte & 0x1F
}

// The type of the NAL unit whose payload starts at `offset`, read whatever the payload's size; nil if the offset is
// outside data.
private func h264NaluType(at offset: Int, in data: Span<UInt8>) -> UInt8? {
    guard offset >= 0, offset < data.count else {
        return nil
    }
    return h264NaluType(data[offset])
}

// The payload of a NAL unit; nil if it doesn't lie within data.
private func payload(of index: WebCore.NaluIndex, in data: Span<UInt8>) -> Span<UInt8>? {
    let start = index.payloadStartOffset
    let size = index.payloadSize
    guard start >= 0, start <= data.count, size >= 0, size <= data.count - start else {
        return nil
    }
    return data.extracting(start..<(start + size))
}

private func hasH264ChromaFormatFields(_ profileIDC: UInt32) -> Bool {
    switch profileIDC {
    case 100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134:
        true
    default:
        false
    }
}

// seq_scaling_matrix_present_flag and the scaling lists after it; false for an invalid delta_scale.
private func skipH264ScalingMatrix(_ reader: inout RbspBitReader, chromaFormatIDC: UInt32) -> Bool {
    // seq_scaling_matrix_present_flag: u(1)
    guard reader.readFlag() else {
        return true
    }
    let scalingListCount = chromaFormatIDC == 3 ? 12 : 8
    for i in 0..<scalingListCount {
        // seq_scaling_list_present_flag[i]: u(1)
        if !reader.readFlag() {
            continue
        }
        var lastScale = 8
        var nextScale = 8
        let sizeOfScalingList = i < 6 ? 16 : 64
        for _ in 0..<sizeOfScalingList {
            if nextScale != 0 {
                // delta_scale: se(v)
                let deltaScale = Int(reader.readSignedExpGolomb())
                guard reader.ok, deltaScale >= -128, deltaScale <= 127 else {
                    return false
                }
                nextScale = (lastScale + deltaScale + 256) % 256
            }
            if nextScale != 0 {
                lastScale = nextScale
            }
        }
    }
    return true
}

// Table A-1 of the H.264 spec: MaxDpbMbs for a given level.
private func maxDpbMbsFromLevelNumber(_ profileIDC: UInt32, _ levelIDC: UInt32, _ constraintSet3Flag: Bool) -> UInt64 {
    if (profileIDC == 66 || profileIDC == 77) && levelIDC == 11 && constraintSet3Flag {
        return 396 // Level 1b.
    }

    switch levelIDC {
    case 10: return 396
    case 11: return 900
    case 12, 13, 20: return 2376
    case 21: return 4752
    case 22, 30: return 8100
    case 31: return 18000
    case 32: return 20480
    case 40, 41: return 32768
    case 42: return 34816
    case 50: return 110400
    case 51, 52: return 184320
    default: return 0
    }
}

private func skipH264HRDParameters(_ reader: inout RbspBitReader) {
    // cpb_cnt_minus1: ue(v)
    let cpbCntMinus1 = UInt64(reader.readExpGolomb())
    // bit_rate_scale: u(4), cpb_size_scale: u(4)
    reader.consumeBits(8)
    var i: UInt64 = 0
    while i <= cpbCntMinus1 && reader.ok {
        // bit_rate_value_minus1[i], cpb_size_value_minus1[i]: ue(v) each.
        _ = reader.readExpGolomb()
        _ = reader.readExpGolomb()
        // cbr_flag[i]: u(1)
        reader.consumeBits(1)
        i += 1
    }
    // initial_cpb_removal_delay_length_minus1(5), cpb_removal_delay_length_minus1(5),
    // dpb_output_delay_length_minus1(5), time_offset_length(5).
    reader.consumeBits(20)
}

// H264BitstreamParser::parseSpsMaxNumReorderFrames(), ported from libwebrtc's nalu_rewriter.cc. Reads the RBSP of the
// SPS NAL unit (header included) without copying it.
private func h264SpsMaxNumReorderFrames(_ nalUnit: Span<UInt8>) -> UInt8? {
    guard nalUnit.count > h264NaluHeaderSize else {
        return nil
    }

    var reader = RbspBitReader(nalUnit.extracting(h264NaluHeaderSize..<nalUnit.count))

    // profile_idc: u(8)
    let profileIDC = reader.readBits(8)
    // constraint_set0_flag..constraint_set5_flag + reserved_zero_2bits: u(8)
    let constraintFlags = reader.readBits(8)
    let constraintSet3Flag = (constraintFlags >> 4) & 0x1 != 0
    // level_idc: u(8)
    let levelIDC = reader.readBits(8)
    // seq_parameter_set_id: ue(v)
    _ = reader.readExpGolomb()

    if hasH264ChromaFormatFields(profileIDC) {
        // chroma_format_idc: ue(v)
        let chromaFormatIDC = reader.readExpGolomb()
        if chromaFormatIDC == 3 {
            // separate_colour_plane_flag: u(1)
            reader.consumeBits(1)
        }
        // bit_depth_luma_minus8, bit_depth_chroma_minus8: ue(v) each.
        _ = reader.readExpGolomb()
        _ = reader.readExpGolomb()
        // qpprime_y_zero_transform_bypass_flag: u(1)
        reader.consumeBits(1)
        guard skipH264ScalingMatrix(&reader, chromaFormatIDC: chromaFormatIDC) else {
            return nil
        }
    }

    // log2_max_frame_num_minus4: ue(v)
    _ = reader.readExpGolomb()

    // pic_order_cnt_type: ue(v)
    let picOrderCntType = reader.readExpGolomb()
    if picOrderCntType == 0 {
        // log2_max_pic_order_cnt_lsb_minus4: ue(v)
        _ = reader.readExpGolomb()
    } else if picOrderCntType == 1 {
        // delta_pic_order_always_zero_flag: u(1)
        reader.consumeBits(1)
        // offset_for_non_ref_pic, offset_for_top_to_bottom_field: se(v) each.
        _ = reader.readSignedExpGolomb()
        _ = reader.readSignedExpGolomb()
        // num_ref_frames_in_pic_order_cnt_cycle: ue(v)
        let numRefFramesInPicOrderCntCycle = reader.readExpGolomb()
        for _ in 0..<numRefFramesInPicOrderCntCycle {
            // offset_for_ref_frame[i]: se(v)
            _ = reader.readSignedExpGolomb()
            guard reader.ok else {
                return nil
            }
        }
    }

    // max_num_ref_frames: ue(v) -- unused beyond consuming.
    _ = reader.readExpGolomb()
    // gaps_in_frame_num_value_allowed_flag: u(1)
    reader.consumeBits(1)
    // pic_width_in_mbs_minus1: ue(v)
    let picWidthInMbsMinus1 = reader.readExpGolomb()
    // pic_height_in_map_units_minus1: ue(v)
    let picHeightInMapUnitsMinus1 = reader.readExpGolomb()
    // frame_mbs_only_flag: u(1)
    let frameMbsOnlyFlag = reader.readFlag()
    if !frameMbsOnlyFlag {
        // mb_adaptive_frame_field_flag: u(1)
        reader.consumeBits(1)
    }
    // direct_8x8_inference_flag: u(1)
    reader.consumeBits(1)
    // frame_cropping_flag: u(1)
    if reader.readFlag() {
        // frame_crop_{left,right,top,bottom}_offset: ue(v) each -- unused for reorder computation.
        _ = reader.readExpGolomb()
        _ = reader.readExpGolomb()
        _ = reader.readExpGolomb()
        _ = reader.readExpGolomb()
    }
    // vui_parameters_present_flag: u(1)
    let vuiParamsPresentFlag = reader.readFlag()

    guard reader.ok else {
        return nil
    }

    if picOrderCntType == 2 {
        return 0
    }

    // uint32_t arithmetic, which wraps.
    let picWidthInMbs = picWidthInMbsMinus1 &+ 1
    let frameHeightInMbs = (frameMbsOnlyFlag ? 1 : 2) &* (picHeightInMapUnitsMinus1 &+ 1)
    guard picWidthInMbs != 0, frameHeightInMbs != 0 else {
        return nil
    }

    let maxDpbMbs = maxDpbMbsFromLevelNumber(profileIDC, levelIDC, constraintSet3Flag)
    let maxDpbFrames = UInt8(min(maxDpbMbs / (UInt64(picWidthInMbs) * UInt64(frameHeightInMbs)), 16))

    let isConstrainedHighProfile =
        constraintSet3Flag
        && (profileIDC == 44 || profileIDC == 86 || profileIDC == 100 || profileIDC == 110 || profileIDC == 122 || profileIDC == 244)

    if !vuiParamsPresentFlag {
        return isConstrainedHighProfile ? 0 : maxDpbFrames
    }

    // Walk vui_parameters() (Annex E.1.1 of the H.264 spec) up to bitstream_restriction_flag.
    // aspect_ratio_info_present_flag: u(1)
    if reader.readFlag() {
        let extendedSar: UInt32 = 255
        // aspect_ratio_idc: u(8)
        if reader.readBits(8) == extendedSar {
            // sar_width, sar_height: u(16) each.
            reader.consumeBits(32)
        }
    }
    // overscan_info_present_flag: u(1)
    if reader.readFlag() {
        // overscan_appropriate_flag: u(1)
        reader.consumeBits(1)
    }
    // video_signal_type_present_flag: u(1)
    if reader.readFlag() {
        // video_format: u(3), video_full_range_flag: u(1)
        reader.consumeBits(4)
        // colour_description_present_flag: u(1)
        if reader.readFlag() {
            // colour_primaries, transfer_characteristics, matrix_coefficients: u(8) each.
            reader.consumeBits(24)
        }
    }
    // chroma_loc_info_present_flag: u(1)
    if reader.readFlag() {
        // chroma_sample_loc_type_top_field, chroma_sample_loc_type_bottom_field: ue(v) each.
        _ = reader.readExpGolomb()
        _ = reader.readExpGolomb()
    }
    // timing_info_present_flag: u(1)
    if reader.readFlag() {
        // num_units_in_tick, time_scale: u(32) each; fixed_frame_rate_flag: u(1).
        reader.consumeBits(65)
    }
    // nal_hrd_parameters_present_flag: u(1)
    let nalHrdParametersPresentFlag = reader.readFlag()
    if nalHrdParametersPresentFlag {
        skipH264HRDParameters(&reader)
    }
    // vcl_hrd_parameters_present_flag: u(1)
    let vclHrdParametersPresentFlag = reader.readFlag()
    if vclHrdParametersPresentFlag {
        skipH264HRDParameters(&reader)
    }
    if nalHrdParametersPresentFlag || vclHrdParametersPresentFlag {
        // low_delay_hrd_flag: u(1)
        reader.consumeBits(1)
    }
    // pic_struct_present_flag: u(1)
    reader.consumeBits(1)
    // bitstream_restriction_flag: u(1)
    let bitstreamRestrictionFlag = reader.readFlag()
    var maxNumReorderFrames: UInt32 = 0
    if bitstreamRestrictionFlag {
        // motion_vectors_over_pic_boundaries_flag: u(1)
        reader.consumeBits(1)
        // max_bytes_per_pic_denom, max_bits_per_mb_denom: ue(v) each.
        _ = reader.readExpGolomb()
        _ = reader.readExpGolomb()
        // log2_max_mv_length_horizontal, log2_max_mv_length_vertical: ue(v) each.
        _ = reader.readExpGolomb()
        _ = reader.readExpGolomb()
        // max_num_reorder_frames: ue(v)
        maxNumReorderFrames = reader.readExpGolomb()
        // max_dec_frame_buffering: ue(v) -- unused.
        _ = reader.readExpGolomb()
    }

    guard reader.ok else {
        return nil
    }

    if bitstreamRestrictionFlag {
        return UInt8(min(maxNumReorderFrames, UInt32(maxDpbFrames)))
    }

    return isConstrainedHighProfile ? 0 : maxDpbFrames
}

// The position in `indices` of the first SPS NAL unit.
func findH264AnnexBSpsIndex(_ data: Span<UInt8>, _ indices: Span<WebCore.NaluIndex>) -> Int? {
    var position = 0
    while position < indices.count {
        guard let type = h264NaluType(at: indices[position].payloadStartOffset, in: data) else {
            return nil
        }
        if type == h264NaluTypeSps {
            return position
        }
        position += 1
    }
    return nil
}

private func findH264AnnexBMaxNumReorderFrames(_ data: Span<UInt8>, _ indices: Span<WebCore.NaluIndex>) -> UInt8? {
    guard let spsIndex = findH264AnnexBSpsIndex(data, indices) else {
        return nil
    }
    let index = indices[spsIndex]
    guard index.payloadSize != 0, let sps = payload(of: index, in: data) else {
        return nil
    }
    return h264SpsMaxNumReorderFrames(sps)
}

private func h264AnnexBSpsIsFollowedByPps(_ data: Span<UInt8>, _ indices: Span<WebCore.NaluIndex>, _ spsIndex: Int) -> Bool {
    guard spsIndex + 1 < indices.count else {
        return false
    }
    let ppsIndex = indices[spsIndex + 1]
    return ppsIndex.payloadSize != 0 && h264NaluType(at: ppsIndex.payloadStartOffset, in: data) == h264NaluTypePps
}

private func findAVCCMaxNumReorderFrames(_ avcC: Span<UInt8>) -> UInt8? {
    // Mirrors the avcC header walk in createVideoInfoFromAVCCImpl(), stopping as soon as the first SPS NAL unit has been
    // located.
    guard avcC.count >= 7 else {
        return nil
    }
    // configurationVersion, AVCProfileIndication, profile_compatibility, AVCLevelIndication: u(8) each.
    // bit(6) reserved = '111111'b;
    // unsigned int(2) lengthSizeMinusOne;
    // bit(3) reserved = '111'b;
    // unsigned int(5) numOfSequenceParameterSets;
    guard avcC[5] & 0x1F != 0, avcC.count >= 8 else {
        return nil
    }
    let size = Int(avcC[6]) << 8 | Int(avcC[7])
    let spsStart = 8
    guard size > h264NaluHeaderSize, size <= avcC.count - spsStart else {
        return nil
    }
    return h264SpsMaxNumReorderFrames(avcC.extracting(spsStart..<(spsStart + size)))
}

// One parameter set of an avcC record (a 16-bit size, then the NAL unit), appended to parameterSets with its header
// byte patched; false if it is truncated or isn't of `type`.
private func appendAVCCParameterSet(
    _ avcC: Span<UInt8>,
    _ position: inout Int,
    type: UInt8,
    patchHeader: (UInt8) -> UInt8,
    _ parameterSets: inout WebCore.MediaParserByteVector,
    _ parameterSetSizes: inout WebCore.MediaParserUInt32Vector
) -> Bool {
    guard avcC.count - position >= 2 else {
        return false
    }
    let size = Int(avcC[position]) << 8 | Int(avcC[position + 1])
    position += 2
    guard size >= h264NaluHeaderSize, position < avcC.count, h264NaluType(avcC[position]) == type, size <= avcC.count - position else {
        return false
    }
    parameterSets.append(consuming: patchHeader(avcC[position]))
    if size > h264NaluHeaderSize {
        WebCore.appendBytes(&parameterSets, avcC.extracting((position + h264NaluHeaderSize)..<(position + size)))
    }
    parameterSetSizes.append(consuming: UInt32(size))
    position += size
    return true
}

// The state of an H264BitstreamParser, which holds one through its Impl (H264Utilities.cpp). Ported from libwebrtc's
// common_video/h264/h264_bitstream_parser.cc, sps_parser.cc and pps_parser.cc.
@_expose(Cxx)
final class H264BitstreamParserState {
    // FIXME: Make this private once a private type links under ThinLTO on Windows ("Invalid weak external").
    struct SequenceParameterSet {
        var deltaPicOrderAlwaysZeroFlag = false
        var chromaFormatIDC: UInt32 = 1
        var separateColourPlaneFlag = false
        var frameMbsOnlyFlag = false
        var log2MaxFrameNum: UInt32 = 4
        var log2MaxPicOrderCntLsb: UInt32 = 4
        var picOrderCntType: UInt32 = 0
    }

    // FIXME: Make this private once a private type links under ThinLTO on Windows ("Invalid weak external").
    struct PictureParameterSet {
        var bottomFieldPicOrderInFramePresentFlag = false
        var weightedPredFlag = false
        var entropyCodingModeFlag = false
        var numRefIdxL0DefaultActiveMinus1: UInt32 = 0
        var numRefIdxL1DefaultActiveMinus1: UInt32 = 0
        var weightedBipredIDC: UInt32 = 0
        var redundantPicCntPresentFlag = false
        var picInitQPMinus26: Int32 = 0
    }

    private var sps: SequenceParameterSet?
    private var pps: PictureParameterSet?
    private var lastSliceQPDelta: Int32?

    @_expose(Cxx)
    init() {
    }

    // Parses each NAL unit of an Annex B stream. Appends to logEvents the raw H264ParserLogEvent of each failure that
    // H264Utilities.cpp logs.
    @_expose(Cxx)
    func parseBitstream(_ bitstream: borrowing WebCore.MediaParserBytes, _ logEvents: inout WebCore.MediaParserByteVector) {
        let bytes: Span<UInt8> = bitstream.span()
        var scanner = NaluIndexScanner(bytes)
        while let index = scanner.next() {
            parseNalUnit(bytes.extracting(index.payloadStartOffset..<(index.payloadStartOffset + index.payloadSize)), &logEvents)
        }
    }

    // The QP of the last slice parsed, or the raw H264ParserLogEvent of the failure if there is none.
    @_expose(Cxx)
    func lastSliceQP() -> WebCore.SliceQPResult {
        var result = WebCore.SliceQPResult()
        guard let lastSliceQPDelta, let pps else {
            result.status = H264ParserLogEvent.missingInfo.rawValue
            return result
        }
        let value = 26 + pps.picInitQPMinus26 + lastSliceQPDelta
        guard value >= 0, value <= 51 else {
            result.status = H264ParserLogEvent.invalidQP.rawValue
            return result
        }
        result.qp = value
        result.status = H264ParserLogEvent.none.rawValue
        return result
    }

    private func parseNalUnit(_ nalUnit: Span<UInt8>, _ logEvents: inout WebCore.MediaParserByteVector) {
        if nalUnit.isEmpty {
            return
        }

        let naluType = h264NaluType(nalUnit[0])
        switch naluType {
        case h264NaluTypeSps:
            if let sps = Self.parseSps(nalUnit.extracting(h264NaluHeaderSize..<nalUnit.count)) {
                self.sps = sps
            }
        case h264NaluTypePps:
            if let pps = Self.parsePps(nalUnit.extracting(h264NaluHeaderSize..<nalUnit.count)) {
                self.pps = pps
            }
        case h264NaluTypeAud, h264NaluTypeFiller, h264NaluTypeSei, h264NaluTypePrefix:
            break
        default:
            let event = parseNonParameterSetNalu(nalUnit, naluType)
            if event != .none {
                logEvents.append(consuming: event.rawValue)
            }
        }
    }

    private static func parseSps(_ data: Span<UInt8>) -> SequenceParameterSet? {
        var reader = RbspBitReader(data)
        var sps = SequenceParameterSet()

        // profile_idc: u(8)
        let profileIDC = reader.readBits(8)
        // constraint_set0_flag..constraint_set5_flag + reserved_zero_2bits + level_idc: u(16)
        reader.consumeBits(16)
        // seq_parameter_set_id: ue(v)
        _ = reader.readExpGolomb()

        if hasH264ChromaFormatFields(profileIDC) {
            // chroma_format_idc: ue(v)
            sps.chromaFormatIDC = reader.readExpGolomb()
            if sps.chromaFormatIDC == 3 {
                // separate_colour_plane_flag: u(1)
                sps.separateColourPlaneFlag = reader.readFlag()
            }
            // bit_depth_luma_minus8: ue(v)
            _ = reader.readExpGolomb()
            // bit_depth_chroma_minus8: ue(v)
            _ = reader.readExpGolomb()
            // qpprime_y_zero_transform_bypass_flag: u(1)
            reader.consumeBits(1)
            guard skipH264ScalingMatrix(&reader, chromaFormatIDC: sps.chromaFormatIDC) else {
                return nil
            }
        }

        let maxLog2Minus4: UInt32 = 12

        // log2_max_frame_num_minus4: ue(v)
        let log2MaxFrameNumMinus4 = reader.readExpGolomb()
        guard reader.ok, log2MaxFrameNumMinus4 <= maxLog2Minus4 else {
            return nil
        }
        sps.log2MaxFrameNum = log2MaxFrameNumMinus4 + 4

        // pic_order_cnt_type: ue(v)
        sps.picOrderCntType = reader.readExpGolomb()
        if sps.picOrderCntType == 0 {
            // log2_max_pic_order_cnt_lsb_minus4: ue(v)
            let log2MaxPicOrderCntLsbMinus4 = reader.readExpGolomb()
            guard reader.ok, log2MaxPicOrderCntLsbMinus4 <= maxLog2Minus4 else {
                return nil
            }
            sps.log2MaxPicOrderCntLsb = log2MaxPicOrderCntLsbMinus4 + 4
        } else if sps.picOrderCntType == 1 {
            // delta_pic_order_always_zero_flag: u(1)
            sps.deltaPicOrderAlwaysZeroFlag = reader.readFlag()
            // offset_for_non_ref_pic: se(v)
            _ = reader.readSignedExpGolomb()
            // offset_for_top_to_bottom_field: se(v)
            _ = reader.readSignedExpGolomb()
            // num_ref_frames_in_pic_order_cnt_cycle: ue(v)
            let numRefFramesInPicOrderCntCycle = reader.readExpGolomb()
            for _ in 0..<numRefFramesInPicOrderCntCycle {
                // offset_for_ref_frame[i]: se(v)
                _ = reader.readSignedExpGolomb()
                guard reader.ok else {
                    return nil
                }
            }
        }
        // max_num_ref_frames: ue(v)
        _ = reader.readExpGolomb()
        // gaps_in_frame_num_value_allowed_flag: u(1)
        reader.consumeBits(1)
        // pic_width_in_mbs_minus1: ue(v)
        _ = reader.readExpGolomb()
        // pic_height_in_map_units_minus1: ue(v)
        _ = reader.readExpGolomb()
        // frame_mbs_only_flag: u(1)
        sps.frameMbsOnlyFlag = reader.readFlag()

        guard reader.ok else {
            return nil
        }

        return sps
    }

    private static func parsePps(_ data: Span<UInt8>) -> PictureParameterSet? {
        var reader = RbspBitReader(data)
        var pps = PictureParameterSet()

        // pic_parameter_set_id: ue(v)
        _ = reader.readExpGolomb()
        // seq_parameter_set_id: ue(v)
        _ = reader.readExpGolomb()

        // entropy_coding_mode_flag: u(1)
        pps.entropyCodingModeFlag = reader.readFlag()
        // bottom_field_pic_order_in_frame_present_flag: u(1)
        pps.bottomFieldPicOrderInFramePresentFlag = reader.readFlag()

        // num_slice_groups_minus1: ue(v)
        let numSliceGroupsMinus1 = reader.readExpGolomb()
        if numSliceGroupsMinus1 > 0 {
            // slice_group_map_type: ue(v)
            let sliceGroupMapType = reader.readExpGolomb()
            if sliceGroupMapType == 0 {
                var i: UInt64 = 0
                while i <= UInt64(numSliceGroupsMinus1) && reader.ok {
                    // run_length_minus1[i]: ue(v)
                    _ = reader.readExpGolomb()
                    i += 1
                }
            } else if sliceGroupMapType == 2 {
                var i: UInt64 = 0
                while i <= UInt64(numSliceGroupsMinus1) && reader.ok {
                    // top_left[i]: ue(v)
                    _ = reader.readExpGolomb()
                    // bottom_right[i]: ue(v)
                    _ = reader.readExpGolomb()
                    i += 1
                }
            } else if sliceGroupMapType == 3 || sliceGroupMapType == 4 || sliceGroupMapType == 5 {
                // slice_group_change_direction_flag: u(1)
                reader.consumeBits(1)
                // slice_group_change_rate_minus1: ue(v)
                _ = reader.readExpGolomb()
            } else if sliceGroupMapType == 6 {
                // pic_size_in_map_units_minus1: ue(v)
                let picSizeInMapUnits = Int64(reader.readExpGolomb()) + 1
                let sliceGroupIdBits = Int64(1 + numSliceGroupsMinus1.bitWidth - numSliceGroupsMinus1.leadingZeroBitCount)
                let bitsToConsume = sliceGroupIdBits * picSizeInMapUnits
                guard reader.ok, bitsToConsume <= Int64(Int32.max) else {
                    return nil
                }
                reader.consumeBits(Int(bitsToConsume))
            }
            // slice_group_map_type == 1 (dispersed) is intentionally unsupported, matching upstream.
        }
        // num_ref_idx_l0_default_active_minus1: ue(v)
        pps.numRefIdxL0DefaultActiveMinus1 = reader.readExpGolomb()
        // num_ref_idx_l1_default_active_minus1: ue(v)
        pps.numRefIdxL1DefaultActiveMinus1 = reader.readExpGolomb()
        guard reader.ok, pps.numRefIdxL0DefaultActiveMinus1 <= 31, pps.numRefIdxL1DefaultActiveMinus1 <= 31 else {
            return nil
        }

        // weighted_pred_flag: u(1)
        pps.weightedPredFlag = reader.readFlag()
        // weighted_bipred_idc: u(2)
        pps.weightedBipredIDC = reader.readBits(2)

        // pic_init_qp_minus26: se(v)
        pps.picInitQPMinus26 = reader.readSignedExpGolomb()
        guard reader.ok, pps.picInitQPMinus26 <= 25, pps.picInitQPMinus26 >= -26 else {
            return nil
        }
        // pic_init_qs_minus26: se(v)
        _ = reader.readExpGolomb()
        // chroma_qp_index_offset: se(v)
        _ = reader.readExpGolomb()
        // deblocking_filter_control_present_flag: u(1)
        // constrained_intra_pred_flag: u(1)
        reader.consumeBits(2)
        // redundant_pic_cnt_present_flag: u(1)
        pps.redundantPicCntPresentFlag = reader.readFlag()

        guard reader.ok else {
            return nil
        }

        return pps
    }

    // The slice header of a NAL unit that isn't a parameter set, up to slice_qp_delta.
    private func parseNonParameterSetNalu(_ source: Span<UInt8>, _ naluType: UInt8) -> H264ParserLogEvent {
        guard let sps, let pps else {
            return .none
        }

        lastSliceQPDelta = nil

        var reader = RbspBitReader(source)
        guard reader.hasRbspSize(atLeast: h264NaluHeaderSize) else {
            return .none
        }
        reader.consumeBits(h264NaluHeaderSize * 8)

        let isIdr = naluType == h264NaluTypeIdr
        let nalRefIdc = (source[0] & 0x60) >> 5

        var numRefIdxL0ActiveMinus1 = pps.numRefIdxL0DefaultActiveMinus1
        var numRefIdxL1ActiveMinus1 = pps.numRefIdxL1DefaultActiveMinus1

        // first_mb_in_slice: ue(v)
        _ = reader.readExpGolomb()
        // slice_type: ue(v)
        let sliceType = reader.readExpGolomb() % 5
        // pic_parameter_set_id: ue(v)
        _ = reader.readExpGolomb()
        if sps.separateColourPlaneFlag {
            // colour_plane_id: u(2)
            reader.consumeBits(2)
        }
        // frame_num: u(v)
        reader.consumeBits(Int(sps.log2MaxFrameNum))
        var fieldPicFlag = false
        if !sps.frameMbsOnlyFlag {
            // field_pic_flag: u(1)
            fieldPicFlag = reader.readFlag()
            if fieldPicFlag {
                // bottom_field_flag: u(1)
                reader.consumeBits(1)
            }
        }
        if isIdr {
            // idr_pic_id: ue(v)
            _ = reader.readExpGolomb()
        }
        if sps.picOrderCntType == 0 {
            // pic_order_cnt_lsb: u(v)
            reader.consumeBits(Int(sps.log2MaxPicOrderCntLsb))
            if pps.bottomFieldPicOrderInFramePresentFlag && !fieldPicFlag {
                // delta_pic_order_cnt_bottom: se(v)
                _ = reader.readSignedExpGolomb()
            }
        }
        if sps.picOrderCntType == 1 && !sps.deltaPicOrderAlwaysZeroFlag {
            // delta_pic_order_cnt[0]: se(v)
            _ = reader.readSignedExpGolomb()
            if pps.bottomFieldPicOrderInFramePresentFlag && !fieldPicFlag {
                // delta_pic_order_cnt[1]: se(v)
                _ = reader.readSignedExpGolomb()
            }
        }
        if pps.redundantPicCntPresentFlag {
            // redundant_pic_cnt: ue(v)
            _ = reader.readExpGolomb()
        }
        if sliceType == h264SliceTypeB {
            // direct_spatial_mv_pred_flag: u(1)
            reader.consumeBits(1)
        }
        switch sliceType {
        case h264SliceTypeP, h264SliceTypeB, h264SliceTypeSp:
            // num_ref_idx_active_override_flag: u(1)
            if reader.readFlag() {
                // num_ref_idx_l0_active_minus1: ue(v)
                numRefIdxL0ActiveMinus1 = reader.readExpGolomb()
                guard reader.ok, numRefIdxL0ActiveMinus1 <= 31 else {
                    return .none
                }
                if sliceType == h264SliceTypeB {
                    // num_ref_idx_l1_active_minus1: ue(v)
                    numRefIdxL1ActiveMinus1 = reader.readExpGolomb()
                    guard reader.ok, numRefIdxL1ActiveMinus1 <= 31 else {
                        return .none
                    }
                }
            }
        default:
            break
        }
        guard reader.ok else {
            return .none
        }

        if naluType == 20 || naluType == 21 {
            return .unsupportedNaluType
        }

        // ref_pic_list_modification():
        if sliceType != h264SliceTypeI && sliceType != h264SliceTypeSi {
            // ref_pic_list_modification_flag_l0: u(1)
            if reader.readFlag() {
                skipH264PicNumsModifications(&reader)
            }
        }
        if sliceType == h264SliceTypeB {
            // ref_pic_list_modification_flag_l1: u(1)
            if reader.readFlag() {
                skipH264PicNumsModifications(&reader)
            }
        }
        guard reader.ok else {
            return .none
        }

        if (pps.weightedPredFlag && (sliceType == h264SliceTypeP || sliceType == h264SliceTypeSp))
            || (pps.weightedBipredIDC == 1 && sliceType == h264SliceTypeB)
        {
            // pred_weight_table()
            // luma_log2_weight_denom: ue(v)
            _ = reader.readExpGolomb()

            // ChromaArrayType, with chroma_format_idc truncated to 8 bits.
            let chromaArrayType = sps.separateColourPlaneFlag ? 0 : UInt8(truncatingIfNeeded: sps.chromaFormatIDC)
            if chromaArrayType != 0 {
                // chroma_log2_weight_denom: ue(v)
                _ = reader.readExpGolomb()
            }

            skipH264PredictionWeights(&reader, numRefIdxActiveMinus1: numRefIdxL0ActiveMinus1, hasChroma: chromaArrayType != 0)
            if sliceType == h264SliceTypeB {
                skipH264PredictionWeights(&reader, numRefIdxActiveMinus1: numRefIdxL1ActiveMinus1, hasChroma: chromaArrayType != 0)
            }
        }
        if nalRefIdc != 0 {
            // dec_ref_pic_marking():
            if isIdr {
                // no_output_of_prior_pics_flag: u(1)
                // long_term_reference_flag: u(1)
                reader.consumeBits(2)
            } else if reader.readFlag() {
                // adaptive_ref_pic_marking_mode_flag: u(1)
                skipH264MemoryManagementControlOperations(&reader)
            }
        }
        if pps.entropyCodingModeFlag && sliceType != h264SliceTypeI && sliceType != h264SliceTypeSi {
            // cabac_init_idc: ue(v)
            _ = reader.readExpGolomb()
        }

        // slice_qp_delta: se(v)
        let lastSliceQPDelta = reader.readSignedExpGolomb()
        guard reader.ok else {
            return .none
        }
        guard lastSliceQPDelta.magnitude <= 51 else {
            return .qpDeltaOutOfRange
        }

        self.lastSliceQPDelta = lastSliceQPDelta
        return .none
    }
}

// modification_of_pic_nums_idc and its operands, up to the closing 3.
private func skipH264PicNumsModifications(_ reader: inout RbspBitReader) {
    var modificationOfPicNumsIDC: UInt32
    repeat {
        // modification_of_pic_nums_idc: ue(v)
        modificationOfPicNumsIDC = reader.readExpGolomb()
        if modificationOfPicNumsIDC == 0 || modificationOfPicNumsIDC == 1 {
            // abs_diff_pic_num_minus1: ue(v)
            _ = reader.readExpGolomb()
        } else if modificationOfPicNumsIDC == 2 {
            // long_term_pic_num: ue(v)
            _ = reader.readExpGolomb()
        }
    } while modificationOfPicNumsIDC != 3 && reader.ok
}

// The luma and chroma weights and offsets of one reference picture list in pred_weight_table().
private func skipH264PredictionWeights(_ reader: inout RbspBitReader, numRefIdxActiveMinus1: UInt32, hasChroma: Bool) {
    for _ in 0...numRefIdxActiveMinus1 {
        // luma_weight_lX_flag: u(1)
        if reader.readFlag() {
            // luma_weight_lX[i]: se(v)
            _ = reader.readSignedExpGolomb()
            // luma_offset_lX[i]: se(v)
            _ = reader.readSignedExpGolomb()
        }
        if hasChroma {
            // chroma_weight_lX_flag: u(1)
            if reader.readFlag() {
                for _ in 0..<2 {
                    // chroma_weight_lX[i][j]: se(v)
                    _ = reader.readSignedExpGolomb()
                    // chroma_offset_lX[i][j]: se(v)
                    _ = reader.readSignedExpGolomb()
                }
            }
        }
    }
}

// memory_management_control_operation and its operands, up to the closing 0.
private func skipH264MemoryManagementControlOperations(_ reader: inout RbspBitReader) {
    var memoryManagementControlOperation: UInt32
    repeat {
        // memory_management_control_operation: ue(v)
        memoryManagementControlOperation = reader.readExpGolomb()
        if memoryManagementControlOperation == 1 || memoryManagementControlOperation == 3 {
            // difference_of_pic_nums_minus1: ue(v)
            _ = reader.readExpGolomb()
        }
        if memoryManagementControlOperation == 2 {
            // long_term_pic_num: ue(v)
            _ = reader.readExpGolomb()
        }
        if memoryManagementControlOperation == 3 || memoryManagementControlOperation == 6 {
            // long_term_frame_idx: ue(v)
            _ = reader.readExpGolomb()
        }
        if memoryManagementControlOperation == 4 {
            // max_long_term_frame_idx_plus1: ue(v)
            _ = reader.readExpGolomb()
        }
    } while memoryManagementControlOperation != 0 && reader.ok
}

// Entry points for H264Utilities.cpp and H264UtilitiesCocoa.mm.

@_expose(Cxx)
func parseH264SpsMaxNumReorderFramesImpl(_ nalUnit: borrowing WebCore.MediaParserBytes, _ maxNumReorderFrames: inout UInt8) -> Bool {
    let bytes: Span<UInt8> = nalUnit.span()
    guard let value = h264SpsMaxNumReorderFrames(bytes) else {
        return false
    }
    maxNumReorderFrames = value
    return true
}

@_expose(Cxx)
func findH264AnnexBMaxNumReorderFramesImpl(
    _ data: borrowing WebCore.MediaParserBytes,
    _ indices: borrowing WebCore.MediaParserNaluIndices,
    _ maxNumReorderFrames: inout UInt8
) -> Bool {
    let bytes: Span<UInt8> = data.span()
    let naluIndices: Span<WebCore.NaluIndex> = indices.span()
    guard let value = findH264AnnexBMaxNumReorderFrames(bytes, naluIndices) else {
        return false
    }
    maxNumReorderFrames = value
    return true
}

@_expose(Cxx)
func findAVCCMaxNumReorderFramesImpl(_ avcC: borrowing WebCore.MediaParserBytes, _ maxNumReorderFrames: inout UInt8) -> Bool {
    let bytes: Span<UInt8> = avcC.span()
    guard let value = findAVCCMaxNumReorderFrames(bytes) else {
        return false
    }
    maxNumReorderFrames = value
    return true
}

// The SPS and PPS NAL units of an avcC record, concatenated in parameterSets, with their sizes in parameterSetSizes: the
// SPS with its high bit cleared and the PPS with nal_ref_idc set to 3. Returns the NAL unit length size, 0 if the record
// is invalid.
@_expose(Cxx)
func createVideoInfoFromAVCCImpl(
    _ avcC: borrowing WebCore.MediaParserBytes,
    _ parameterSets: inout WebCore.MediaParserByteVector,
    _ parameterSetSizes: inout WebCore.MediaParserUInt32Vector
) -> Int {
    let bytes: Span<UInt8> = avcC.span()
    guard bytes.count >= 7 else {
        return 0
    }

    // configurationVersion, AVCProfileIndication, profile_compatibility, AVCLevelIndication: u(8) each.
    // bit(6) reserved = '111111'b;
    // unsigned int(2) lengthSizeMinusOne;
    let lengthSize = Int(bytes[4] & 0x3) + 1
    // bit(3) reserved = '111'b;
    // unsigned int(5) numOfSequenceParameterSets;
    let numOfSequenceParameterSets = Int(bytes[5] & 0x1F)
    guard numOfSequenceParameterSets != 0 else {
        return 0
    }

    let nalRefIdcSequenceParameterSet: UInt8 = 0x80
    let nalRefIdcPictureParameterSet: UInt8 = 0x60

    var position = 6
    for _ in 0..<numOfSequenceParameterSets {
        let appended = appendAVCCParameterSet(
            bytes,
            &position,
            type: h264NaluTypeSps,
            patchHeader: { $0 & ~nalRefIdcSequenceParameterSet },
            &parameterSets,
            &parameterSetSizes
        )
        guard appended else {
            return 0
        }
    }

    // unsigned int(8) numOfPictureParameterSets;
    guard position < bytes.count, bytes[position] != 0 else {
        return 0
    }
    let numOfPictureParameterSets = Int(bytes[position])
    position += 1
    for _ in 0..<numOfPictureParameterSets {
        let appended = appendAVCCParameterSet(
            bytes,
            &position,
            type: h264NaluTypePps,
            patchHeader: { $0 | nalRefIdcPictureParameterSet },
            &parameterSets,
            &parameterSetSizes
        )
        guard appended else {
            return 0
        }
    }

    return lengthSize
}

// The first SPS NAL unit of an Annex B stream and the PPS NAL unit after it. Fills sps whenever there is an SPS, and pps
// only if a PPS follows it, which is when this returns true.
@_expose(Cxx)
func createVideoInfoFromAVCAnnexBStreamImpl(
    _ data: borrowing WebCore.MediaParserBytes,
    _ indices: borrowing WebCore.MediaParserNaluIndices,
    _ sps: inout WebCore.ParameterSetRange,
    _ pps: inout WebCore.ParameterSetRange
) -> Bool {
    let bytes: Span<UInt8> = data.span()
    let naluIndices: Span<WebCore.NaluIndex> = indices.span()
    guard let spsIndex = findH264AnnexBSpsIndex(bytes, naluIndices) else {
        return false
    }
    sps.type = h264NaluTypeSps
    guard h264AnnexBSpsIsFollowedByPps(bytes, naluIndices, spsIndex) else {
        return false
    }

    let spsNalu = naluIndices[spsIndex]
    let ppsNalu = naluIndices[spsIndex + 1]
    guard payload(of: spsNalu, in: bytes) != nil, payload(of: ppsNalu, in: bytes) != nil else {
        sps = WebCore.ParameterSetRange()
        return false
    }
    sps.offset = spsNalu.payloadStartOffset
    sps.size = spsNalu.payloadSize
    pps.type = h264NaluTypePps
    pps.offset = ppsNalu.payloadStartOffset
    pps.size = ppsNalu.payloadSize
    return true
}

// Appends the NAL units of an Annex B stream to output, length-prefixed. Returns false if the stream has an SPS without
// a PPS after it.
@_expose(Cxx)
func convertAVCAnnexBToLengthPrefixedImpl(
    _ data: borrowing WebCore.MediaParserBytes,
    _ indices: borrowing WebCore.MediaParserNaluIndices,
    _ output: inout WebCore.MediaParserByteVector
) -> Bool {
    let bytes: Span<UInt8> = data.span()
    let naluIndices: Span<WebCore.NaluIndex> = indices.span()

    // FIXME: We basically assume that SPS is first and PPS is second. But there may be nalus between them, and SPS/PPS order is not guaranteed.
    // We also need to validate what to do for a frame with only one SPS or only one PPS.
    // For now, we skip all NAL units up to and including the SPS/PPS pair, if present, as parameter sets belong in the format description, not in the per-sample data.
    var startIndex = 0
    var spsIsFollowedByPps = true
    if let spsIndex = findH264AnnexBSpsIndex(bytes, naluIndices) {
        if h264AnnexBSpsIsFollowedByPps(bytes, naluIndices, spsIndex) {
            startIndex = spsIndex + 2
        } else {
            spsIsFollowedByPps = false
        }
    }

    appendLengthPrefixed(naluIndices.extracting(startIndex..<naluIndices.count), of: bytes, to: &output)
    return spsIsFollowedByPps
}

#endif // ENABLE_WEBCORE_SWIFT
