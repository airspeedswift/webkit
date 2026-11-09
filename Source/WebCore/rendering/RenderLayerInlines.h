/**
 * Copyright (C) 2003-2023 Apple Inc. All rights reserved.
 * Copyright (C) 2023 Igalia S.L.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 */

#pragma once

#include "RenderElementInlines.h"
#include "RenderElementStyleInlines.h"
#include "RenderLayer.h"
#include "RenderLayerStyleInlines.h"
#include "RenderObjectInlines.h"
#include "RenderSVGResourceClipper.h"
#include "RenderView.h"
#include "SVGGraphicsElement.h"
#include "Settings.h"
#include <wtf/CheckedPtr.h>

namespace WebCore {

inline bool RenderLayer::canPaintTransparencyWithSetOpacity() const { return isBitmapOnly() && !hasNonOpacityTransparency() && !hasFilter(); }

inline bool RenderLayer::paintsWithTransparency(OptionSet<PaintBehavior> paintBehavior) const
{
    if (!renderer().isTransparent() && !hasNonOpacityTransparency())
        return false;
    return (paintBehavior & PaintBehavior::FlattenCompositingLayers) || !isComposited();
}

inline bool RenderLayer::hasNonOpacityTransparency() const
{
    if (renderer().hasMask())
        return true;

    if (hasBlendMode() || isolatesBlending())
        return true;

    if (!renderer().document().settings().layerBasedSVGEngineEnabled())
        return false;

    // SVG clip-paths may use clipping masks, if so, flag this layer as transparent.
    if (CheckedPtr svgClipper = renderer().svgClipperResourceFromStyle(); svgClipper && !svgClipper->shouldApplyPathClipping())
        return true;

    return false;
}

enum class AncestorTraversal { Continue, Stop };

// This is a simplified version of containing block walking that only handles absolute and fixed position.
template<typename Function>
AncestorTraversal traverseAncestorLayers(const RenderLayer& layer, NOESCAPE const Function& function)
{
    auto positioningBehavior = layer.renderer().style().position();
    CheckedPtr nextPaintOrderParent = layer.paintOrderParent();

    for (CheckedPtr<const RenderLayer> ancestorLayer = layer.parent(); ancestorLayer; ancestorLayer = ancestorLayer->parent()) {
        bool inContainingBlockChain = true;

        switch (positioningBehavior) {
        case PositionType::Static:
        case PositionType::Relative:
        case PositionType::Sticky:
            break;
        case PositionType::Absolute:
            inContainingBlockChain = ancestorLayer->renderer().canContainAbsolutelyPositionedObjects();
            break;
        case PositionType::Fixed:
            inContainingBlockChain = ancestorLayer->renderer().canContainFixedPositionObjects();
            break;
        }

        if (function(*ancestorLayer, inContainingBlockChain, ancestorLayer == nextPaintOrderParent) == AncestorTraversal::Stop)
            return AncestorTraversal::Stop;

        if (inContainingBlockChain)
            positioningBehavior = ancestorLayer->renderer().style().position();

        if (ancestorLayer == nextPaintOrderParent)
            nextPaintOrderParent = ancestorLayer->paintOrderParent();
    }

    return AncestorTraversal::Continue;
}

inline bool ancestorLayerMayClip(const RenderLayer& layer, const RenderLayer& ancestorLayer, bool isContainingBlockChain)
{
    // Surprisingly, the deprecated CSS "clip" property on abspos ancestors of fixedpos elements clips them <https://github.com/w3c/csswg-drafts/issues/8336>.
    if (layer.renderer().isFixedPositioned() && ancestorLayer.renderer().hasClip())
        return true;

    return isContainingBlockChain && ancestorLayer.renderer().hasClipOrNonVisibleOverflow();
}

} // namespace WebCore
