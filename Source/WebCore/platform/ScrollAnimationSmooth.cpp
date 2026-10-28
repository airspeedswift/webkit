/*
 * Copyright (C) 2016 Igalia S.L.
 * Copyright (C) 2015-2021 Apple Inc. All rights reserved.
 * Copyright (c) 2011 Google Inc. All rights reserved.
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
#include "ScrollAnimationSmooth.h"

#include "FloatPoint.h"
#include "GeometryUtilities.h"
#include "KeyboardScroll.h"
#include "ScrollExtents.h"
#include "ScrollableArea.h"
#include "ScrollingEffectsClock.h"
#include "SpringSolver.h"
#include "TimingFunction.h"
#include "UnitBezier.h"
#include <wtf/TZoneMallocInlines.h>
#include <wtf/text/TextStream.h>

namespace WebCore {

// ScrollPhysicsAnimations.swift uses these values of UnitBezier.h, which it cannot import.
static_assert(UnitBezier::kBezierEpsilon == 1e-7);
static_assert(UnitBezier::kBisectionEpsilon == 1e-10);
static_assert(UnitBezier::kMaxNewtonIterations == 4);
static_assert(CUBIC_BEZIER_SPLINE_SAMPLES == 11);

// ScrollPhysicsAnimations.swift copies this std::array, which it cannot index.
static_assert(DocumentEdgeScrollSpring::timingFunctionControlPoints == std::array<double, 4> { 0, 0.2, 1, 1 });

} // namespace WebCore
