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
#include "ImageDecoderSwiftFrames.h"

#include <type_traits>

namespace WebCore {

// Swift receives ScalableImageDecoderFrames inout and must not copy, move or construct it: each member reaches
// the state through this.
template<typename Frames>
constexpr bool isFacadeShape = !std::is_polymorphic_v<Frames>
    && !std::is_default_constructible_v<Frames> && !std::is_copy_constructible_v<Frames>
    && !std::is_copy_assignable_v<Frames> && !std::is_move_assignable_v<Frames>
    && std::is_move_constructible_v<Frames> && !std::is_trivially_destructible_v<Frames>;
static_assert(isFacadeShape<ScalableImageDecoderFrames>);

// The Swift uses these raw values.
static_assert(static_cast<uint8_t>(DecodingStatus::Invalid) == 0 && static_cast<uint8_t>(DecodingStatus::Partial) == 1
    && static_cast<uint8_t>(DecodingStatus::Complete) == 2 && static_cast<uint8_t>(DecodingStatus::Decoding) == 3);
static_assert(static_cast<uint8_t>(EncodedDataStatus::Error) == 0 && static_cast<uint8_t>(EncodedDataStatus::SizeAvailable) == 3 && static_cast<uint8_t>(EncodedDataStatus::Complete) == 4);
static_assert(static_cast<uint8_t>(ScalableImageDecoderFrame::DisposalMethod::Unspecified) == 0
    && static_cast<uint8_t>(ScalableImageDecoderFrame::DisposalMethod::DoNotDispose) == 1
    && static_cast<uint8_t>(ScalableImageDecoderFrame::DisposalMethod::RestoreToBackground) == 2
    && static_cast<uint8_t>(ScalableImageDecoderFrame::DisposalMethod::RestoreToPrevious) == 3);

static ImageDecoderFramesState& state(ScalableImageDecoderFrames& frames)
{
    return static_cast<ImageDecoderFramesState&>(frames);
}

static ScalableImageDecoderFrame& frame(ScalableImageDecoderFrames& frames, size_t index)
{
    return state(frames).frames.at(index);
}

static ImageBackingStore& backingStore(ScalableImageDecoderFrames& frames, size_t index)
{
    auto* backingStore = frame(frames, index).backingStore();
    RELEASE_ASSERT(backingStore);
    return *backingStore;
}

static ImageDecoderSize imageDecoderSize(const IntSize& size)
{
    return { size.width(), size.height() };
}

// Copies the decoder's status and size into frames after a call that can change them, and returns result.
static bool updateStatus(ScalableImageDecoderFrames& frames, bool result)
{
    frames.encodedDataStatus = static_cast<uint8_t>(state(frames).decoder.encodedDataStatus());
    frames.size = imageDecoderSize(state(frames).decoder.ScalableImageDecoder::size());
    return result;
}

ScalableImageDecoderFrames::ScalableImageDecoderFrames(ScalableImageDecoderFrames&&)
{
    RELEASE_ASSERT_NOT_REACHED();
}

ScalableImageDecoderFrames::~ScalableImageDecoderFrames() = default;

bool ScalableImageDecoderFrames::setFailed()
{
    return updateStatus(*this, state(*this).decoder.setFailed());
}

bool ScalableImageDecoderFrames::setSize(ImageDecoderSize newSize)
{
    return updateStatus(*this, state(*this).decoder.ScalableImageDecoder::setSize({ newSize.width, newSize.height }));
}

size_t ScalableImageDecoderFrames::frameCount()
{
    return state(*this).frames.size();
}

void ScalableImageDecoderFrames::setFrameCount(size_t count)
{
    state(*this).frames.resize(count);
}

ImageDecoderCachedFrame ScalableImageDecoderFrames::frameInfo(size_t index)
{
    auto& cached = frame(*this, index);
    ImageDecoderCachedFrame info { static_cast<uint8_t>(cached.decodingStatus()), static_cast<uint8_t>(cached.disposalMethod()), cached.hasAlpha(), false, { }, { } };
    if (auto* store = cached.backingStore()) {
        auto& rect = store->frameRect();
        info.hasBackingStore = true;
        info.storeSize = imageDecoderSize(store->size());
        info.rect = { rect.x(), rect.y(), rect.width(), rect.height() };
    }
    return info;
}

void ScalableImageDecoderFrames::setDecodingStatus(size_t index, uint8_t status)
{
    RELEASE_ASSERT(status <= static_cast<uint8_t>(DecodingStatus::Complete));
    frame(*this, index).setDecodingStatus(static_cast<DecodingStatus>(status));
}

void ScalableImageDecoderFrames::completeFrame(size_t index, uint32_t durationInMilliseconds, uint8_t disposalMethod)
{
    RELEASE_ASSERT(disposalMethod <= static_cast<uint8_t>(ScalableImageDecoderFrame::DisposalMethod::RestoreToPrevious));
    auto& cached = frame(*this, index);
    cached.setDecodingStatus(DecodingStatus::Complete);
    cached.setDuration(Seconds::fromMilliseconds(durationInMilliseconds));
    cached.setDisposalMethod(static_cast<ScalableImageDecoderFrame::DisposalMethod>(disposalMethod));
}

void ScalableImageDecoderFrames::setHasAlpha(size_t index, bool hasAlpha)
{
    frame(*this, index).setHasAlpha(hasAlpha);
}

void ScalableImageDecoderFrames::setFrameRect(size_t index, ImageDecoderRect rect)
{
    backingStore(*this, index).setFrameRect({ rect.x, rect.y, rect.width, rect.height });
}

bool ScalableImageDecoderFrames::initialize(size_t index, ImageDecoderSize size)
{
    return frame(*this, index).initialize({ size.width, size.height }, state(*this).decoder.premultiplyAlpha());
}

bool ScalableImageDecoderFrames::initializeFromFrame(size_t index, size_t sourceIndex)
{
    return frame(*this, index).initialize(backingStore(*this, sourceIndex));
}

void ScalableImageDecoderFrames::clear(size_t index)
{
    frame(*this, index).clear();
}

std::span<uint32_t> framePixels(ScalableImageDecoderFrames& frames, size_t index)
{
    auto& store = backingStore(frames, index);
    return store.pixelsStartingAt(0, 0);
}

} // namespace WebCore
