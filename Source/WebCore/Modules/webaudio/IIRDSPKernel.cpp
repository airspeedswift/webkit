/*
 * Copyright 2016 The Chromium Authors. All rights reserved.
 * Copyright (C) 2020 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1.  Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2.  Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
 * ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"

#if ENABLE(WEB_AUDIO)
#include "IIRDSPKernel.h"
#include <wtf/TZoneMallocInlines.h>

#include "IIRFilter.h"
#include "WebCore-Swift.h"
#include <limits>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(IIRDSPKernel);

// The Swift ring buffers have 32 entries.
static_assert(IIRFilter::maxOrder < 32);

IIRDSPKernel::IIRDSPKernel(IIRProcessor& processor, const IIRDSPKernel* tailTimeSource)
    : AudioDSPKernel(&processor)
{
    // NaN asks makeIIRKernel to compute the tail time itself.
    double knownTailTime = tailTimeSource ? tailTimeSource->tailTime() : std::numeric_limits<double>::quiet_NaN();
    m_swift = makeUnique<AudioDSPSwiftState<IIRKernel>>(makeIIRKernel(processor.feedforward().span(), processor.feedback().span(), processor.sampleRate(), processor.isFilterStable(), knownTailTime));
}

IIRDSPKernel::~IIRDSPKernel() = default;

void IIRDSPKernel::getFrequencyResponse(std::span<const float> frequencyHz, std::span<float> magResponse, std::span<float> phaseResponse)
{
    iirFrequencyResponse(m_swift->kernel, frequencyHz, magResponse, phaseResponse, nyquist());
}

void IIRDSPKernel::process(std::span<const float> source, std::span<float> destination)
{
    iirProcess(m_swift->kernel, inputUnlessOutput(source, destination), destination, source.size());
}

void IIRDSPKernel::reset()
{
    iirReset(m_swift->kernel);
}

double IIRDSPKernel::tailTime() const
{
    return iirTailTime(m_swift->kernel);
}

bool IIRDSPKernel::requiresTailProcessing() const
{
    // Always return true even if the tail time and latency might both be zero.
    return true;
}

} // namespace WebCore

#endif // ENABLE(WEB_AUDIO)
