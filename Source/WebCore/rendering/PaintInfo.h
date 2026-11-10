/*
 * Copyright (C) 2000 Lars Knoll (knoll@kde.org)
 *           (C) 2000 Antti Koivisto (koivisto@kde.org)
 *           (C) 2000 Dirk Mueller (mueller@kde.org)
 *           (C) 2004 Allan Sandfeld Jensen (kde@carewolf.com)
 * Copyright (C) 2003, 2004, 2005, 2006, 2007, 2008, 2009 Apple Inc. All rights reserved.
 * Copyright (C) 2009 Google Inc. All rights reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 *
 */

#pragma once

#include <WebCore/AffineTransform.h>
#include <WebCore/EventRegion.h>
#include <WebCore/GraphicsContext.h>
#include <WebCore/IntRect.h>
#include <WebCore/LayoutRect.h>
#include <WebCore/PaintPhase.h>
#include <bit>
#include <limits>
#include <wtf/HashMap.h>
#include <wtf/OptionSet.h>
#include <wtf/WeakListHashSet.h>

namespace WebCore {

class AccessibilityRegionContext;
class OverlapTestRequestClient;
class RenderBoxModelObject;
class RenderLayer;
class RenderLayerModelObject;
class RenderObject;

#if ENABLE(AX_CUSTOM_COLOR_MODE)
class AXCustomColorBackdropContext;
#endif

typedef HashMap<OverlapTestRequestClient*, IntRect> OverlapTestRequestMap;

enum class StateSavedByCaller : bool { No, Yes };

/*
 * Paint the object and its children, clipped by (x|y|w|h).
 * (tx|ty) is the calculated position of the parent
 */
struct PaintInfo {
    SWIFT_UNAVAILABLE_IN_SWIFT __attribute__((swift_attr("@_lifetime(immortal)"))) PaintInfo(GraphicsContext& newContext, const LayoutRect& newRect, PaintPhase newPhase, OptionSet<PaintBehavior> newPaintBehavior,
        RenderObject* newSubtreePaintRoot = nullptr, SingleThreadWeakListHashSet<RenderBoxModelObject>* newOutlineObjects = nullptr,
        OverlapTestRequestMap* overlapTestRequests = nullptr, const RenderLayerModelObject* newPaintContainer = nullptr,
        const RenderLayer* enclosingSelfPaintingLayer = nullptr, bool newRequireSecurityOriginAccessForWidgets = false)
            : rect(newRect)
            , phase(newPhase)
            , requireSecurityOriginAccessForWidgets(newRequireSecurityOriginAccessForWidgets)
            , paintBehavior(newPaintBehavior)
            , subtreePaintRoot(newSubtreePaintRoot)
            , paintContainer(newPaintContainer)
            , m_enclosingSelfPaintingLayer(enclosingSelfPaintingLayer)
            , m_outlineObjects(std::bit_cast<uintptr_t>(newOutlineObjects))
            , m_overlapTestRequests(std::bit_cast<uintptr_t>(overlapTestRequests))
            , m_context(std::bit_cast<uintptr_t>(&newContext))
    {
    }

    // Not trivially copyable, so that Swift copies and destroys a PaintInfo as C++ does: the renderers and the
    // layer it points to are not references a PaintInfo owns.
    PaintInfo(const PaintInfo&) = default;
    PaintInfo& operator=(const PaintInfo&) = default;
    ~PaintInfo() { }

    PaintInfo(GraphicsContextView newContext LIFETIME_BOUND, const LayoutRect& newRect, PaintPhase newPhase, OptionSet<PaintBehavior> newPaintBehavior,
        RenderObject* newSubtreePaintRoot, const RenderLayerModelObject* newPaintContainer, const RenderLayer* enclosingSelfPaintingLayer, bool newRequireSecurityOriginAccessForWidgets)
            : PaintInfo(*newContext, newRect, newPhase, newPaintBehavior, newSubtreePaintRoot, nullptr, nullptr, newPaintContainer, enclosingSelfPaintingLayer, newRequireSecurityOriginAccessForWidgets)
    {
    }

    GraphicsContext& context() const LIFETIME_BOUND
    {
        ASSERT(m_context);
        return *std::bit_cast<GraphicsContext*>(m_context);
    }

    void setContext(GraphicsContext& context)
    {
        m_context = std::bit_cast<uintptr_t>(&context);
    }

    // Swift stores a reference type at +1 into a field, and C++ does not release it.
    void setRegionContext(RegionContext* context) { regionContext = context; }

    // Used to list outlines that should be painted by a block with inline children.
    SingleThreadWeakListHashSet<RenderBoxModelObject>* outlineObjects() const { return std::bit_cast<SingleThreadWeakListHashSet<RenderBoxModelObject>*>(m_outlineObjects); }
    void setOutlineObjects(SingleThreadWeakListHashSet<RenderBoxModelObject>* outlineObjects) { m_outlineObjects = std::bit_cast<uintptr_t>(outlineObjects); }

    OverlapTestRequestMap* overlapTestRequests() const { return std::bit_cast<OverlapTestRequestMap*>(m_overlapTestRequests); }
    void setOverlapTestRequests(OverlapTestRequestMap* overlapTestRequests) { m_overlapTestRequests = std::bit_cast<uintptr_t>(overlapTestRequests); }

    void updateSubtreePaintRootForChildren(const RenderObject* renderer)
    {
        if (!subtreePaintRoot)
            return;

        // If we're the painting root, kids draw normally, and see root of nullptr.
        if (subtreePaintRoot == renderer) {
            subtreePaintRoot = nullptr;
            return;
        }
    }

    bool shouldPaintWithinRoot(const RenderObject& renderer) const
    {
        return !subtreePaintRoot || subtreePaintRoot == &renderer;
    }

    bool forceTextColor() const { return forceBlackText() || forceWhiteText(); }
    bool forceBlackText() const { return paintBehavior.contains(PaintBehavior::ForceBlackText); }
    bool forceWhiteText() const { return paintBehavior.contains(PaintBehavior::ForceWhiteText); }
    Color forcedTextColor() const { return forceBlackText() ? Color::black : Color::white; }

    bool skipRootBackground() const { return paintBehavior.contains(PaintBehavior::SkipRootBackground); }
    bool paintRootBackgroundOnly() const { return paintBehavior.contains(PaintBehavior::RootBackgroundOnly); }

    const RenderLayer* enclosingSelfPaintingLayer() const { return m_enclosingSelfPaintingLayer; }

    void applyTransform(const AffineTransform& localToAncestorTransform)
    {
        if (localToAncestorTransform.isIdentity())
            return;

        context().concatCTM(localToAncestorTransform);

        if (rect.isInfinite())
            return;

        FloatRect tranformedRect(valueOrDefault(localToAncestorTransform.inverse()).mapRect(rect));
        rect.setLocation(LayoutPoint(tranformedRect.location()));
        rect.setSize(LayoutSize(tranformedRect.size()));
    }

    EventRegionContext* eventRegionContext() { return dynamicDowncast<EventRegionContext>(regionContext); }
    inline AccessibilityRegionContext* accessibilityRegionContext();
#if ENABLE(AX_CUSTOM_COLOR_MODE)
    inline AXCustomColorBackdropContext* axCustomColorBackdropContext();
#endif

    LayoutRect rect;
    PaintPhase phase;
    bool requireSecurityOriginAccessForWidgets { false };
    StateSavedByCaller stateSavedByCaller { StateSavedByCaller::No };
    OptionSet<PaintBehavior> paintBehavior;
    SUPPRESS_FORWARD_DECL_MEMBER RenderObject* subtreePaintRoot; // used to draw just one element and its visual children
    SUPPRESS_FORWARD_DECL_MEMBER const RenderLayerModelObject* paintContainer; // the layer object that originates the current painting
    SUPPRESS_FORWARD_DECL_MEMBER const RenderLayer* m_enclosingSelfPaintingLayer { nullptr };
    RegionContext* regionContext { nullptr }; // For PaintPhase::EventRegion and PaintPhase::Accessibility.

private:
    // Integers, so that Swift imports the struct as a view: it cannot track pointers to these.
    uintptr_t m_outlineObjects;
    uintptr_t m_overlapTestRequests;
    uintptr_t m_context;
} SWIFT_VIEW;

} // namespace WebCore
