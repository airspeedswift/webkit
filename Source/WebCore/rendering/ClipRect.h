/*
 * Copyright (C) 2015 Apple Inc. All rights reserved.
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

#pragma once

#include <WebCore/LayoutRect.h>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>
#include <wtf/TZoneMallocInlines.h>

namespace WTF {
class TextStream;
}

namespace WebCore {

class HitTestLocation;

class ClipRect {
public:
    ClipRect() = default;
    
    ClipRect(const LayoutRect& rect)
        : m_rect(rect)
    {
    }
    
    const LayoutRect& rect() const LIFETIME_BOUND { return m_rect; }
    LayoutRect rectValue() const { return m_rect; }

    void reset() { m_rect = LayoutRect::infiniteRect(); }

    bool affectedByRadius() const { return m_affectedByRadius; }
    void setAffectedByRadius(bool affectedByRadius) { m_affectedByRadius = affectedByRadius; }
    
    friend bool operator==(const ClipRect&, const ClipRect&) = default;
    
    void intersect(const LayoutRect& other);
    void intersect(const ClipRect& other);
    void move(LayoutUnit x, LayoutUnit y) { m_rect.move(x, y); }
    void move(const LayoutSize& size) { m_rect.move(size); }
    void moveBy(const LayoutPoint& point) { m_rect.moveBy(point); }
    
    bool intersects(const LayoutRect&) const;
    bool LEGACY_NODELETE intersects(const HitTestLocation&) const;

    bool isEmpty() const { return m_rect.isEmpty(); }
    bool isInfinite() const { return m_rect.isInfinite(); }

    void inflateX(LayoutUnit dx) { m_rect.inflateX(dx); }
    void inflateY(LayoutUnit dy) { m_rect.inflateY(dy); }
    void inflate(LayoutUnit d) { inflateX(d); inflateY(d); }
    
private:
    LayoutRect m_rect;
    bool m_affectedByRadius = false;
};

inline void ClipRect::intersect(const LayoutRect& other)
{
    if (other.isInfinite())
        return;
    if (isInfinite())
        m_rect = other;
    else
        m_rect.intersect(other);
}

inline void ClipRect::intersect(const ClipRect& other)
{
    intersect(other.rect());
    if (other.affectedByRadius())
        m_affectedByRadius = true;
}
    
inline bool ClipRect::intersects(const LayoutRect& rect) const
{
    if (isInfinite() || rect.isInfinite())
        return true;
    return m_rect.intersects(rect);
}

inline ClipRect intersection(const ClipRect& a, const ClipRect& b)
{
    ClipRect c = a;
    c.intersect(b);
    return c;
}

WTF::TextStream& operator<<(WTF::TextStream&, const ClipRect&);

class ClipRects : public RefCounted<ClipRects> {
    WTF_MAKE_TZONE_ALLOCATED_INLINE(ClipRects);
public:
    static Ref<ClipRects> LEGACY_NODELETE create()
    {
        return adoptRef(*new ClipRects);
    }

    static Ref<ClipRects> LEGACY_NODELETE create(const ClipRects& other)
    {
        return adoptRef(*new ClipRects(other));
    }

    // A new object for Swift, which takes the reference that create() would return.
    static ClipRects& createForSwift() SWIFT_RETURNS_RETAINED { return create().leakRef(); }

    void LEGACY_NODELETE reset()
    {
        m_overflowClipRect.reset();
        m_fixedClipRect.reset();
        m_posClipRect.reset();
        m_fixed = false;
    }

    const ClipRect& LEGACY_NODELETE overflowClipRect() const { return m_overflowClipRect; }
    void LEGACY_NODELETE setOverflowClipRect(const ClipRect& clipRect) { m_overflowClipRect = clipRect; }

    const ClipRect& LEGACY_NODELETE fixedClipRect() const { return m_fixedClipRect; }
    void LEGACY_NODELETE setFixedClipRect(const ClipRect& clipRect) { m_fixedClipRect = clipRect; }

    const ClipRect& LEGACY_NODELETE posClipRect() const { return m_posClipRect; }
    void LEGACY_NODELETE setPosClipRect(const ClipRect& clipRect) { m_posClipRect = clipRect; }

    // The getters that Swift calls: it takes no reference results.
    ClipRect overflowClipRectForSwift() const SWIFT_NAME(overflowClipRect()) { return m_overflowClipRect; }
    ClipRect fixedClipRectForSwift() const SWIFT_NAME(fixedClipRect()) { return m_fixedClipRect; }
    ClipRect posClipRectForSwift() const SWIFT_NAME(posClipRect()) { return m_posClipRect; }

    bool LEGACY_NODELETE fixed() const { return m_fixed; }
    void LEGACY_NODELETE setFixed(bool fixed) { m_fixed = fixed; }

    void LEGACY_NODELETE setOverflowClipRectAffectedByRadius() { m_overflowClipRect.setAffectedByRadius(true); }

    bool LEGACY_NODELETE operator==(const ClipRects& other) const
    {
        return m_overflowClipRect == other.overflowClipRect()
            && m_fixedClipRect == other.fixedClipRect()
            && m_posClipRect == other.posClipRect()
            && m_fixed == other.fixed();
    }

    ClipRects& LEGACY_NODELETE operator=(const ClipRects& other)
    {
        m_overflowClipRect = other.overflowClipRect();
        m_fixedClipRect = other.fixedClipRect();
        m_posClipRect = other.posClipRect();
        m_fixed = other.fixed();
        return *this;
    }

private:
    ClipRects() = default;

    ClipRects(const LayoutRect& clipRect)
        : m_overflowClipRect(clipRect)
        , m_fixedClipRect(clipRect)
        , m_posClipRect(clipRect)
    {
    }

    ClipRects(const ClipRects& other)
        : RefCounted()
        , m_fixed(other.fixed())
        , m_overflowClipRect(other.overflowClipRect())
        , m_fixedClipRect(other.fixedClipRect())
        , m_posClipRect(other.posClipRect())
    {
    }

    bool m_fixed { false };
    ClipRect m_overflowClipRect;
    ClipRect m_fixedClipRect;
    ClipRect m_posClipRect;
};

} // namespace WebCore
