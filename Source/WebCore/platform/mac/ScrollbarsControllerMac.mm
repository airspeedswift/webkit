/*
 * Copyright (C) 2021-2023 Apple Inc. All rights reserved.
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
#include "ScrollbarsControllerMac.h"

#if PLATFORM(MAC)

#import "GraphicsLayer.h"
#import "Logging.h"
#import "NSScrollerImpDetails.h"
#import "ScrollAnimator.h"
#import "ScrollableArea.h"
#import "ScrollbarInlines.h"
#import "ScrollbarMac.h"
#import "ScrollbarThemeMac.h"
#import "ScrollbarsControllerInlines.h"
#import "TimingFunction.h"
#import "WheelEventTestMonitor.h" // FIXME: This is  layering violation.

#import <pal/spi/mac/NSScrollerImpSPI.h>
#import <wtf/BlockObjCExceptions.h>
#import <wtf/NakedPtr.h>
#import <wtf/TZoneMallocInlines.h>
#import <wtf/text/TextStream.h>

#if USE_SWIFT_SCROLLBARS_CONTROLLER
#import "ScrollbarsControllerMacTypes.h"
#import "WebCore-Swift.h"
#import <wtf/NeverDestroyed.h>
#endif

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollbarsController);
WTF_MAKE_TZONE_ALLOCATED_IMPL(ScrollbarsControllerMac);

#if !USE_SWIFT_SCROLLBARS_CONTROLLER
static ScrollbarThemeMac* macScrollbarTheme()
{
    ScrollbarTheme& scrollbarTheme = ScrollbarTheme::theme();
    return !scrollbarTheme.isMockTheme() ? downcast<ScrollbarThemeMac>(&scrollbarTheme) : nullptr;
}

static NSScrollerImp *LEGACY_NODELETE scrollerImpForScrollbar(Scrollbar& scrollbar)
{
    return ScrollbarThemeMac::scrollerImpForScrollbar(scrollbar);
}
#endif

} // namespace WebCore

#if !USE_SWIFT_SCROLLBARS_CONTROLLER
@interface WebScrollerImpPairDelegate : NSObject <NSScrollerImpPairDelegate> {
    WeakPtr<WebCore::ScrollableArea> _scrollableArea;
}
- (id)initWithScrollableArea:(WebCore::ScrollableArea*)scrollableArea;

@end

@implementation WebScrollerImpPairDelegate

- (id)initWithScrollableArea:(WebCore::ScrollableArea*)scrollableArea
{
    self = [super init];
    if (!self)
        return nil;
    
    _scrollableArea = scrollableArea;
    return self;
}

- (void)invalidate
{
    _scrollableArea = nullptr;
}

- (NSRect)contentAreaRectForScrollerImpPair:(NSScrollerImpPair *)scrollerImpPair
{
    UNUSED_PARAM(scrollerImpPair);
    CheckedPtr scrollableArea = _scrollableArea.get();
    if (!scrollableArea)
        return NSZeroRect;

    WebCore::IntSize contentsSize = scrollableArea->contentsSize();
    return NSMakeRect(0, 0, contentsSize.width(), contentsSize.height());
}

- (BOOL)inLiveResizeForScrollerImpPair:(NSScrollerImpPair *)scrollerImpPair
{
    UNUSED_PARAM(scrollerImpPair);
    CheckedPtr scrollableArea = _scrollableArea.get();
    if (!scrollableArea)
        return NO;

    return scrollableArea->inLiveResize();
}

- (NSPoint)mouseLocationInContentAreaForScrollerImpPair:(NSScrollerImpPair *)scrollerImpPair
{
    UNUSED_PARAM(scrollerImpPair);
    CheckedPtr scrollableArea = _scrollableArea.get();
    if (!scrollableArea)
        return NSZeroPoint;

    // It's OK that this position isn't relative to this scroller (which might be an overflow scroller).
    // AppKit just takes the result and passes it back to -scrollerImpPair:convertContentPoint:toScrollerImp:.
    return scrollableArea->lastKnownMousePositionInView();
}

- (NSPoint)scrollerImpPair:(NSScrollerImpPair *)scrollerImpPair convertContentPoint:(NSPoint)pointInContentArea toScrollerImp:(NSScrollerImp *)scrollerImp
{
    UNUSED_PARAM(scrollerImpPair);

    CheckedPtr scrollableArea = _scrollableArea.get();
    if (!scrollableArea || !scrollerImp)
        return NSZeroPoint;

    RefPtr<WebCore::Scrollbar> scrollbar;
    if ([scrollerImp isHorizontal])
        scrollbar = scrollableArea->horizontalScrollbar();
    else
        scrollbar = scrollableArea->verticalScrollbar();

    // It is possible to have a null scrollbar here since it is possible for this delegate
    // method to be called between the moment when a scrollbar has been set to 0 and the
    // moment when its destructor has been called. We should probably de-couple some
    // of the clean-up work in ScrollbarThemeMac::unregisterScrollbar() to avoid this
    // issue.
    if (!scrollbar)
        return NSZeroPoint;

    ASSERT(scrollerImp == scrollerImpForScrollbar(*scrollbar));

    return scrollbar->convertFromContainingView(WebCore::roundedIntPoint(pointInContentArea));
}

- (void)scrollerImpPair:(NSScrollerImpPair *)scrollerImpPair setContentAreaNeedsDisplayInRect:(NSRect)rect
{
    UNUSED_PARAM(scrollerImpPair);
    UNUSED_PARAM(rect);

    CheckedPtr scrollableArea = _scrollableArea.get();
    if (!scrollableArea)
        return;

    if ([scrollerImpPair overlayScrollerStateIsLocked])
        return;

    scrollableArea->scrollbarsController().contentAreaWillPaint();
}

- (void)scrollerImpPair:(NSScrollerImpPair *)scrollerImpPair updateScrollerStyleForNewRecommendedScrollerStyle:(NSScrollerStyle)newRecommendedScrollerStyle
{
    CheckedPtr scrollableArea = _scrollableArea.get();
    if (!scrollableArea)
        return;

    [scrollerImpPair setScrollerStyle:newRecommendedScrollerStyle];

    CheckedRef scrollbarsController = downcast<WebCore::ScrollbarsControllerMac>(scrollableArea->scrollbarsController());
    scrollbarsController->updateScrollerStyle();
}

@end

enum FeatureToAnimate {
    ThumbAlpha,
    TrackAlpha,
    UIStateTransition,
    ExpansionTransition
};

#if !LOG_DISABLED
static TextStream& operator<<(TextStream& ts, FeatureToAnimate feature)
{
    switch (feature) {
    case ThumbAlpha: ts << "ThumbAlpha"_s ; break;
    case TrackAlpha: ts << "TrackAlpha"_s ; break;
    case UIStateTransition: ts << "UIStateTransition"_s ; break;
    case ExpansionTransition: ts << "ExpansionTransition"_s ; break;
    }
    return ts;
}

using WebCore::LogOverlayScrollbars;

#endif

@interface WebScrollbarPartAnimation : NSObject {
    SingleThreadWeakPtr<WebCore::Scrollbar> _scrollbar;
    RetainPtr<NSScrollerImp> _scrollerImp;
    FeatureToAnimate _featureToAnimate;
    CGFloat _startValue;
    CGFloat _endValue;
    NSTimeInterval _duration;
    RetainPtr<NSTimer> _timer;
    RetainPtr<NSDate> _startDate;
    const RefPtr<WebCore::CubicBezierTimingFunction> _timingFunction;
}
- (id)initWithScrollbar:(WebCore::Scrollbar*)scrollbar featureToAnimate:(FeatureToAnimate)featureToAnimate animateFrom:(CGFloat)startValue animateTo:(CGFloat)endValue duration:(NSTimeInterval)duration;
- (void)setCurrentProgress:(NSTimer *)timer;
- (void)setDuration:(NSTimeInterval)duration;
- (void)stopAnimation;
@end

@implementation WebScrollbarPartAnimation

- (id)initWithScrollbar:(WebCore::Scrollbar*)scrollbar featureToAnimate:(FeatureToAnimate)featureToAnimate animateFrom:(CGFloat)startValue animateTo:(CGFloat)endValue duration:(NSTimeInterval)duration
{
    self = [super init];
    if (!self)
        return nil;

    const NSTimeInterval timeInterval = 0.01;
    _timer = adoptNS([[NSTimer alloc] initWithFireDate:[NSDate dateWithTimeIntervalSinceNow:0] interval:timeInterval target:self selector:@selector(setCurrentProgress:) userInfo:nil repeats:YES]);
    _duration = duration;
    lazyInitialize(_timingFunction, WebCore::CubicBezierTimingFunction::create(WebCore::CubicBezierTimingFunction::TimingFunctionPreset::EaseInOut));

    LOG_WITH_STREAM(OverlayScrollbars, stream << "Creating WebScrollbarPartAnimation for " << featureToAnimate << " from " << startValue << " to " << endValue);

    _scrollbar = scrollbar;
    _featureToAnimate = featureToAnimate;
    _startValue = startValue;
    _endValue = endValue;

    return self;
}

- (void)startAnimation
{
    RefPtr scrollbar = _scrollbar.get();
    RELEASE_ASSERT(scrollbar);

    _scrollerImp = scrollerImpForScrollbar(*scrollbar);

    LOG_WITH_STREAM(OverlayScrollbars, stream << "-[WebScrollbarPartAnimation " << self << "startAnimation] for " << _featureToAnimate);

    [[NSRunLoop mainRunLoop] addTimer:_timer.get() forMode:NSDefaultRunLoopMode];
    _startDate = adoptNS([[NSDate alloc] initWithTimeIntervalSinceNow:0]);
}

- (void)setStartValue:(CGFloat)startValue
{
    _startValue = startValue;
}

- (void)setEndValue:(CGFloat)endValue
{
    _endValue = endValue;
}

- (void)setCurrentProgress:(NSTimer *)timer
{
    CGFloat progress = 0;
    NSDate *now = [NSDate dateWithTimeIntervalSinceNow:0];
    NSTimeInterval elapsed = [now timeIntervalSinceDate:_startDate.get()];
    if (elapsed > _duration) {
        progress = 1;
        [timer invalidate];
    } else {
        NSTimeInterval t = 1;
        if (_duration)
            t = elapsed / _duration;
        progress = _timingFunction->transformProgress(t, _duration);
    }
    RefPtr scrollbar = _scrollbar.get();
    RELEASE_ASSERT(scrollbar);

    LOG_WITH_STREAM(OverlayScrollbars, stream << "-[" << self << " setCurrentProgress: " << progress << "] for " << _featureToAnimate);

    CGFloat currentValue;
    if (_startValue > _endValue)
        currentValue = 1 - progress;
    else
        currentValue = progress;

    switch (_featureToAnimate) {
    case ThumbAlpha:
        [_scrollerImp setKnobAlpha:currentValue];
        break;
    case TrackAlpha:
        [_scrollerImp setTrackAlpha:currentValue];
        break;
    case UIStateTransition:
        [_scrollerImp setUiStateTransitionProgress:currentValue];
        break;
    case ExpansionTransition:
        [_scrollerImp setExpansionTransitionProgress:currentValue];
        break;
    }

    if (scrollbar && !scrollbar->supportsUpdateOnSecondaryThread())
        scrollbar->invalidate();
}

- (void)invalidate
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    [self stopAnimation];
    END_BLOCK_OBJC_EXCEPTIONS
    _scrollbar = nullptr;
}

- (void)setDuration:(NSTimeInterval)duration
{
    _duration = duration;
}

- (void)stopAnimation
{
    [_timer invalidate];
}

@end

@interface WebScrollerImpDelegate : NSObject<NSAnimationDelegate, NSScrollerImpDelegate> {
    SingleThreadWeakPtr<WebCore::Scrollbar> _scrollbar;

    RetainPtr<WebScrollbarPartAnimation> _knobAlphaAnimation;
    RetainPtr<WebScrollbarPartAnimation> _trackAlphaAnimation;
    RetainPtr<WebScrollbarPartAnimation> _uiStateTransitionAnimation;
    RetainPtr<WebScrollbarPartAnimation> _expansionTransitionAnimation;
}
- (id)initWithScrollbar:(WebCore::Scrollbar*)scrollbar;
- (void)cancelAnimations;
@end

@implementation WebScrollerImpDelegate

- (id)initWithScrollbar:(WebCore::Scrollbar*)scrollbar
{
    self = [super init];
    if (!self)
        return nil;
    
    _scrollbar = scrollbar;
    return self;
}

- (void)cancelAnimations
{
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    [_knobAlphaAnimation stopAnimation];
    [_trackAlphaAnimation stopAnimation];
    [_uiStateTransitionAnimation stopAnimation];
    [_expansionTransitionAnimation stopAnimation];
    END_BLOCK_OBJC_EXCEPTIONS
}

- (NakedPtr<WebCore::ScrollbarsControllerMac>)scrollbarsController
{
    return &downcast<WebCore::ScrollbarsControllerMac>(protect(_scrollbar->scrollableArea())->scrollbarsController());
}

- (NSRect)convertRectToBacking:(NSRect)aRect
{
    return aRect;
}

- (NSRect)convertRectFromBacking:(NSRect)aRect
{
    return aRect;
}

- (CALayer *)layer
{
    if (!_scrollbar)
        return nil;

    if (!WebCore::ScrollbarThemeMac::isCurrentlyDrawingIntoLayer())
        return nil;

    RefPtr<WebCore::GraphicsLayer> layer;
    if (_scrollbar->orientation() == WebCore::ScrollbarOrientation::Vertical)
        layer = protect(_scrollbar->scrollableArea())->layerForVerticalScrollbar();
    else
        layer = protect(_scrollbar->scrollableArea())->layerForHorizontalScrollbar();

    static NeverDestroyed<RetainPtr<CALayer>> dummyLayer = adoptNS([[CALayer alloc] init]);
    return layer ? layer->platformLayer() : dummyLayer.get().get();
}

- (NSPoint)mouseLocationInScrollerForScrollerImp:(NSScrollerImp *)scrollerImp
{
    RefPtr scrollbar = _scrollbar.get();
    if (!scrollbar)
        return NSZeroPoint;

    ASSERT_UNUSED(scrollerImp, scrollerImp == scrollerImpForScrollbar(*scrollbar));

    auto positionInView = protect(_scrollbar->scrollableArea())->lastKnownMousePositionInView();
    return scrollbar->convertFromContainingView(positionInView);
}

- (NSRect)convertRectToLayer:(NSRect)rect
{
    return rect;
}

- (BOOL)shouldUseLayerPerPartForScrollerImp:(NSScrollerImp *)scrollerImp
{
    UNUSED_PARAM(scrollerImp);

    RefPtr scrollbar = _scrollbar.get();
    return scrollbar && scrollbar->supportsUpdateOnSecondaryThread();
}

- (NSAppearance *)effectiveAppearanceForScrollerImp:(NSScrollerImp *)scrollerImp
{
    UNUSED_PARAM(scrollerImp);

    if (!_scrollbar)
        return [NSAppearance currentDrawingAppearance];

    // Keep this in sync with LocalFrameView::paintScrollCorner.
    // The base system does not support dark Aqua, so we might get a null result.
    bool useDarkAppearance = protect(_scrollbar->scrollableArea())->useDarkAppearanceForScrollbars();
    if (auto *appearance = [NSAppearance appearanceNamed:useDarkAppearance ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua])
        return appearance;
    return [NSAppearance currentDrawingAppearance];
}

- (void)setUpAlphaAnimation:(RetainPtr<WebScrollbarPartAnimation>&)scrollbarPartAnimation scrollerPainter:(NSScrollerImp *)scrollerPainter part:(WebCore::ScrollbarPart)part animateAlphaTo:(CGFloat)newAlpha duration:(NSTimeInterval)duration
{
    CheckedPtr scrollbarsController = [self scrollbarsController].get();

    // If the user has scrolled the page, then the scrollbars must be animated here.
    // This overrides the early returns.
    bool mustAnimate = !scrollbarsController->scrollbarAnimationsUnsuspendedByUserInteraction();

    RefPtr scrollbar = _scrollbar.get();
    LOG_WITH_STREAM(OverlayScrollbars, stream << "WebScrollerImpDelegate for [" << scrollbar->scrollableArea() << "] setUpAlphaAnimation: scrollbarAnimationsUnsuspendedByUserInteraction " << [self scrollbarsController]->scrollbarAnimationsUnsuspendedByUserInteraction() << " shouldSuspendScrollAnimations " << _scrollbar->scrollableArea().shouldSuspendScrollAnimations());

    if (scrollbarsController->scrollbarPaintTimerIsActive() && !mustAnimate)
        return;

    if (scrollbarsController->shouldSuspendScrollbarAnimations() && !mustAnimate) {
        scrollbarsController->startScrollbarPaintTimer();
        return;
    }

    // At this point, we are definitely going to animate now, so stop the timer.
    scrollbarsController->stopScrollbarPaintTimer();

    // If we are currently animating, stop
    if (scrollbarPartAnimation) {
        [scrollbarPartAnimation stopAnimation];
        scrollbarPartAnimation = nil;
    }

    if (auto* macTheme = WebCore::macScrollbarTheme())
        macTheme->setPaintCharacteristicsForScrollbar(*scrollbar);

    if (part == WebCore::ThumbPart && scrollbar->orientation() == WebCore::ScrollbarOrientation::Vertical) {
        if (newAlpha == 1) {
            auto thumbRect = WebCore::IntRect([scrollerPainter rectForPart:NSScrollerKnob]);
            scrollbarsController->setVisibleScrollerThumbRect(thumbRect);
        } else
            scrollbarsController->setVisibleScrollerThumbRect({ });
    }

    scrollbarPartAnimation = adoptNS([[WebScrollbarPartAnimation alloc] initWithScrollbar:scrollbar.get()
                                                                       featureToAnimate:part == WebCore::ThumbPart ? ThumbAlpha : TrackAlpha
                                                                            animateFrom:part == WebCore::ThumbPart ? [scrollerPainter knobAlpha] : [scrollerPainter trackAlpha]
                                                                              animateTo:newAlpha
                                                                               duration:duration]);
    [scrollbarPartAnimation startAnimation];
}

- (void)scrollerImp:(NSScrollerImp *)scrollerImp animateKnobAlphaTo:(CGFloat)newKnobAlpha duration:(NSTimeInterval)duration
{
    RefPtr scrollbar = _scrollbar.get();
    if (!scrollbar)
        return;

    ASSERT(scrollerImp == scrollerImpForScrollbar(*scrollbar));

    NSScrollerImp *scrollerPainter = (NSScrollerImp *)scrollerImp;
    if (!CheckedRef { *[self scrollbarsController] }->scrollbarsCanBeActive()) {
        [scrollerImp setKnobAlpha:0];
        scrollbar->invalidate();
        return;
    }

    // If we are fading the scrollbar away, that is a good indication that we are no longer going to
    // be moving it around on the scrolling thread. Calling [scrollerPainter setUsePresentationValue:NO]
    // will pass that information on to the NSScrollerImp API.
    if (!newKnobAlpha && scrollbar->supportsUpdateOnSecondaryThread())
        [scrollerPainter setUsePresentationValue:NO];

    [self setUpAlphaAnimation:_knobAlphaAnimation scrollerPainter:scrollerPainter part:WebCore::ThumbPart animateAlphaTo:newKnobAlpha duration:duration];
}

- (void)scrollerImp:(NSScrollerImp *)scrollerImp animateTrackAlphaTo:(CGFloat)newTrackAlpha duration:(NSTimeInterval)duration
{
    if (!_scrollbar)
        return;

    ASSERT(scrollerImp == scrollerImpForScrollbar(*_scrollbar));

    NSScrollerImp *scrollerPainter = (NSScrollerImp *)scrollerImp;
    [self setUpAlphaAnimation:_trackAlphaAnimation scrollerPainter:scrollerPainter part:WebCore::BackTrackPart animateAlphaTo:newTrackAlpha duration:duration];
}

- (void)scrollerImp:(NSScrollerImp *)scrollerImp animateUIStateTransitionWithDuration:(NSTimeInterval)duration
{
    RefPtr scrollbar = _scrollbar.get();
    if (!scrollbar)
        return;

    ASSERT(scrollerImp == scrollerImpForScrollbar(*scrollbar));

    // UIStateTransition always animates to 1. In case an animation is in progress this avoids a hard transition.
    [scrollerImp setUiStateTransitionProgress:1 - [scrollerImp uiStateTransitionProgress]];

    // If the UI state transition is happening, then we are no longer moving the scrollbar on the scrolling thread.
    if (scrollbar->supportsUpdateOnSecondaryThread())
        [scrollerImp setUsePresentationValue:NO];

    if (!_uiStateTransitionAnimation) {
        _uiStateTransitionAnimation = adoptNS([[WebScrollbarPartAnimation alloc] initWithScrollbar:scrollbar.get()
            featureToAnimate:UIStateTransition
            animateFrom:[scrollerImp uiStateTransitionProgress]
            animateTo:1.0
            duration:duration]);
    } else {
        // If we don't need to initialize the animation, just reset the values in case they have changed.
        [_uiStateTransitionAnimation setStartValue:[scrollerImp uiStateTransitionProgress]];
        [_uiStateTransitionAnimation setEndValue:1.0];
        [_uiStateTransitionAnimation setDuration:duration];
    }
    [_uiStateTransitionAnimation startAnimation];
}

- (void)scrollerImp:(NSScrollerImp *)scrollerImp animateExpansionTransitionWithDuration:(NSTimeInterval)duration
{
    RefPtr scrollbar = _scrollbar.get();
    if (!scrollbar)
        return;

    ASSERT(scrollerImp == scrollerImpForScrollbar(*scrollbar));

    // ExpansionTransition always animates to 1. In case an animation is in progress this avoids a hard transition.
    [scrollerImp setExpansionTransitionProgress:1 - [scrollerImp expansionTransitionProgress]];

    if (!_expansionTransitionAnimation) {
        _expansionTransitionAnimation = adoptNS([[WebScrollbarPartAnimation alloc] initWithScrollbar:scrollbar.get()
            featureToAnimate:ExpansionTransition
            animateFrom:[scrollerImp expansionTransitionProgress]
            animateTo:1.0
            duration:duration]);
    } else {
        // If we don't need to initialize the animation, just reset the values in case they have changed.
        [_expansionTransitionAnimation setStartValue:[scrollerImp expansionTransitionProgress]];
        [_expansionTransitionAnimation setEndValue:1.0];
        [_expansionTransitionAnimation setDuration:duration];
    }
    [_expansionTransitionAnimation startAnimation];
}

- (void)scrollerImp:(NSScrollerImp *)scrollerImp overlayScrollerStateChangedTo:(NSOverlayScrollerState)newOverlayScrollerState
{
    UNUSED_PARAM(scrollerImp);
    UNUSED_PARAM(newOverlayScrollerState);
}

- (void)invalidate
{
    _scrollbar = nullptr;
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    [_knobAlphaAnimation invalidate];
    [_trackAlphaAnimation invalidate];
    [_uiStateTransitionAnimation invalidate];
    [_expansionTransitionAnimation invalidate];
    END_BLOCK_OBJC_EXCEPTIONS
}

@end
#endif

namespace WebCore {

#if USE_SWIFT_SCROLLBARS_CONTROLLER
// ScrollbarsControllerMac's state and its AppKit delegates, which live in Swift (ScrollbarsControllerMac.swift).
struct ScrollbarsControllerMacHolder {
    WTF_MAKE_STRUCT_TZONE_ALLOCATED(ScrollbarsControllerMacHolder);

    explicit ScrollbarsControllerMacHolder(ScrollableArea& area)
        : controller(MacScrollbarsController::init(ScrollbarsControllerMacArea { area }))
    {
    }

    MacScrollbarsController controller;
};

WTF_MAKE_STRUCT_TZONE_ALLOCATED_IMPL(ScrollbarsControllerMacHolder);

NSScrollerImp *ScrollbarsControllerMacScrollbar::scrollerImp() const
{
    RefPtr scrollbar = m_scrollbar;
    return scrollbar ? ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar) : nil;
}

void ScrollbarsControllerMacScrollbar::createScrollerImp(NSScrollerImp *oldScrollerImp) const
{
    RefPtr scrollbar = dynamicDowncast<ScrollbarMac>(m_scrollbar);
    RELEASE_ASSERT(scrollbar);
    scrollbar->createScrollerImp(oldScrollerImp);
}

void ScrollbarsControllerMacScrollbar::setPaintCharacteristics() const
{
    RefPtr scrollbar = m_scrollbar;
    auto& theme = ScrollbarTheme::theme();
    if (!scrollbar || theme.isMockTheme())
        return;
    downcast<ScrollbarThemeMac>(theme).setPaintCharacteristicsForScrollbar(*scrollbar);
}

CALayer *ScrollbarsControllerMacArea::layerForScrollbar(ScrollbarOrientation orientation, bool& hasGraphicsLayer) const
{
    hasGraphicsLayer = false;
    CheckedPtr area = m_area;
    if (!area)
        return nil;
    RefPtr layer = orientation == ScrollbarOrientation::Vertical ? area->layerForVerticalScrollbar() : area->layerForHorizontalScrollbar();
    hasGraphicsLayer = !!layer;
    return layer ? layer->platformLayer() : nil;
}

CALayer *ScrollbarsControllerMacArea::scrollerImpDelegateLayer(ScrollbarOrientation orientation) const
{
    CheckedPtr area = m_area;
    if (!area || !ScrollbarThemeMac::isCurrentlyDrawingIntoLayer())
        return nil;
    RefPtr layer = orientation == ScrollbarOrientation::Vertical ? area->layerForVerticalScrollbar() : area->layerForHorizontalScrollbar();

    // The layer an NSScrollerImp draws into when its scrollbar has no GraphicsLayer: one for the process.
    static NeverDestroyed<RetainPtr<CALayer>> dummyLayer = adoptNS([[CALayer alloc] init]);
    return layer ? layer->platformLayer() : dummyLayer.get().get();
}

void ScrollbarsControllerMacArea::startScrollbarPaintTimer() const
{
    if (CheckedPtr area = m_area)
        downcast<ScrollbarsControllerMac>(area->scrollbarsController()).startScrollbarPaintTimer();
}

void ScrollbarsControllerMacArea::stopScrollbarPaintTimer() const
{
    if (CheckedPtr area = m_area)
        downcast<ScrollbarsControllerMac>(area->scrollbarsController()).stopScrollbarPaintTimer();
}

bool ScrollbarsControllerMacArea::scrollbarPaintTimerIsActive() const
{
    CheckedPtr area = m_area;
    return area && downcast<ScrollbarsControllerMac>(area->scrollbarsController()).scrollbarPaintTimerIsActive();
}

bool ScrollbarsControllerMacArea::macThemeUsesOverlayScrollbarsChanged() const
{
    auto& theme = ScrollbarTheme::theme();
    if (theme.isMockTheme())
        return false;
    downcast<ScrollbarThemeMac>(theme).usesOverlayScrollbarsChanged();
    return true;
}
#endif

std::unique_ptr<ScrollbarsController> ScrollbarsController::create(ScrollableArea& scrollableArea)
{
    return makeUnique<ScrollbarsControllerMac>(scrollableArea);
}

ScrollbarsControllerMac::ScrollbarsControllerMac(ScrollableArea& scrollableArea)
    : ScrollbarsController(scrollableArea)
    , m_initialScrollbarPaintTimer(*this, &ScrollbarsControllerMac::initialScrollbarPaintTimerFired)
    , m_sendContentAreaScrolledTimer(*this, &ScrollbarsControllerMac::sendContentAreaScrolledTimerFired)
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    , m_scrollerImpPair(adoptNS([[NSScrollerImpPair alloc] init]))
    , m_scrollerImpPairDelegate(adoptNS([[WebScrollerImpPairDelegate alloc] initWithScrollableArea:&scrollableArea]))
#else
    , m_swift(makeUnique<ScrollbarsControllerMacHolder>(scrollableArea))
#endif
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    [m_scrollerImpPair setDelegate:m_scrollerImpPairDelegate.get()];
    [m_scrollerImpPair setScrollerStyle:ScrollerStyle::recommendedScrollerStyle()];
#endif
}

ScrollbarsControllerMac::~ScrollbarsControllerMac()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    [m_scrollerImpPairDelegate invalidate];
    [m_scrollerImpPair setDelegate:nil];
    [m_horizontalScrollerImpDelegate invalidate];
    [m_verticalScrollerImpDelegate invalidate];
    END_BLOCK_OBJC_EXCEPTIONS
#else
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    m_swift->controller.invalidate();
    END_BLOCK_OBJC_EXCEPTIONS
#endif
}

void ScrollbarsControllerMac::cancelAnimations()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    LOG_WITH_STREAM(OverlayScrollbars, stream << "ScrollbarsControllerMac for [" << scrollableArea() << "] cancelAnimations");
    if (scrollbarPaintTimerIsActive())
        stopScrollbarPaintTimer();
    [m_horizontalScrollerImpDelegate cancelAnimations];
    [m_verticalScrollerImpDelegate cancelAnimations];

    ScrollbarsController::cancelAnimations();
#else
    BEGIN_BLOCK_OBJC_EXCEPTIONS
    m_swift->controller.cancelAnimations();
    END_BLOCK_OBJC_EXCEPTIONS

    ScrollbarsController::cancelAnimations();
#endif
}

#if !USE_SWIFT_SCROLLBARS_CONTROLLER
void ScrollbarsControllerMac::setVisibleScrollerThumbRect(const IntRect& scrollerThumb)
{
    auto rectInViewCoordinates = scrollerThumb;
    CheckedRef scrollableArea = this->scrollableArea();
    if (RefPtr verticalScrollbar = scrollableArea->verticalScrollbar())
        rectInViewCoordinates = verticalScrollbar->convertToContainingView(scrollerThumb);

    if (rectInViewCoordinates == m_visibleScrollerThumbRect)
        return;

    scrollableArea->setVisibleScrollerThumbRect(rectInViewCoordinates);
    m_visibleScrollerThumbRect = rectInViewCoordinates;
}
#endif


void ScrollbarsControllerMac::contentAreaWillPaint() const
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

ALLOW_DEPRECATED_DECLARATIONS_BEGIN
    [m_scrollerImpPair contentAreaWillDraw];
ALLOW_DEPRECATED_DECLARATIONS_END
#else
    m_swift->controller.contentAreaWillPaint();
#endif
}

void ScrollbarsControllerMac::mouseEnteredContentArea()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    LOG_WITH_STREAM(OverlayScrollbars, stream << "ScrollbarsControllerMac for [" << scrollableArea() << "] mouseEnteredContentArea");
    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

    [m_scrollerImpPair mouseEnteredContentArea];
#else
    m_swift->controller.mouseEnteredContentArea();
#endif
}

void ScrollbarsControllerMac::mouseExitedContentArea()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    LOG_WITH_STREAM(OverlayScrollbars, stream << "ScrollbarsControllerMac for [" << scrollableArea() << "] mouseExitedContentArea");
    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

    [m_scrollerImpPair mouseExitedContentArea];
#else
    m_swift->controller.mouseExitedContentArea();
#endif
}

void ScrollbarsControllerMac::mouseMovedInContentArea()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    LOG_WITH_STREAM(OverlayScrollbars, stream << "ScrollbarsControllerMac for [" << scrollableArea() << "] mouseMovedInContentArea");
    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

    [m_scrollerImpPair mouseMovedInContentArea];
#else
    m_swift->controller.mouseMovedInContentArea();
#endif
}

void ScrollbarsControllerMac::mouseEnteredScrollbar(Scrollbar* scrollbar) const
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    // At this time, only legacy scrollbars needs to send notifications here.
    if (ScrollerStyle::recommendedScrollerStyle() != NSScrollerStyleLegacy)
        return;

    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

    if (RetainPtr painter = scrollerImpForScrollbar(*scrollbar))
        [painter mouseEnteredScroller];
#else
    if (m_swift->controller.scrollbarMouseNotificationsAreSent())
        m_swift->controller.mouseEnteredScrollbar(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get());
#endif
}

void ScrollbarsControllerMac::mouseExitedScrollbar(Scrollbar* scrollbar) const
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    // At this time, only legacy scrollbars needs to send notifications here.
    if (ScrollerStyle::recommendedScrollerStyle() != NSScrollerStyleLegacy)
        return;

    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

    if (RetainPtr painter = scrollerImpForScrollbar(*scrollbar))
        [painter mouseExitedScroller];
#else
    if (m_swift->controller.scrollbarMouseNotificationsAreSent())
        m_swift->controller.mouseExitedScrollbar(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get());
#endif
}

void ScrollbarsControllerMac::mouseIsDownInScrollbar(Scrollbar* scrollbar, bool mouseIsDown) const
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

    if (RetainPtr painter = scrollerImpForScrollbar(*scrollbar)) {
        [painter setTracking:mouseIsDown];
        if (mouseIsDown)
            [m_scrollerImpPair beginScrollGesture];
        else
            [m_scrollerImpPair endScrollGesture];
    }
#else
    if (m_swift->controller.scrollbarsCanBeActive())
        m_swift->controller.mouseIsDownInScrollbar(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get(), mouseIsDown);
#endif
}

void ScrollbarsControllerMac::willStartLiveResize()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

    [m_scrollerImpPair startLiveResize];
#else
    m_swift->controller.willStartLiveResize();
#endif
}

void ScrollbarsControllerMac::contentsSizeChanged() const
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

    [m_scrollerImpPair contentAreaDidResize];
#else
    m_swift->controller.contentsSizeChanged();
#endif
}

void ScrollbarsControllerMac::willEndLiveResize()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    ScrollbarsController::willEndLiveResize();

    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

    [m_scrollerImpPair endLiveResize];
#else
    ScrollbarsController::willEndLiveResize();
    m_swift->controller.willEndLiveResize();
#endif
}

void ScrollbarsControllerMac::contentAreaDidShow()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

    [m_scrollerImpPair windowOrderedIn];
#else
    m_swift->controller.contentAreaDidShow();
#endif
}

void ScrollbarsControllerMac::contentAreaDidHide()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

    [m_scrollerImpPair windowOrderedOut];
#else
    m_swift->controller.contentAreaDidHide();
#endif
}

void ScrollbarsControllerMac::didBeginScrollGesture()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    LOG_WITH_STREAM(OverlayScrollbars, stream << "ScrollbarsControllerMac for [" << scrollableArea() << "] didBeginScrollGesture");

    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

    [m_scrollerImpPair beginScrollGesture];

    if (RefPtr monitor = wheelEventTestMonitor())
        monitor->deferForReason(protect(scrollableArea())->scrollingNodeIDForTesting(), WheelEventTestMonitor::DeferReason::ContentScrollInProgress);

    ScrollbarsController::didBeginScrollGesture();
#else
    if (m_swift->controller.didBeginScrollGesture())
        ScrollbarsController::didBeginScrollGesture();
#endif
}

void ScrollbarsControllerMac::didEndScrollGesture()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    LOG_WITH_STREAM(OverlayScrollbars, stream << "ScrollbarsControllerMac for [" << scrollableArea() << "] didEndScrollGesture");

    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

    [m_scrollerImpPair endScrollGesture];

    if (RefPtr monitor = wheelEventTestMonitor())
        monitor->removeDeferralForReason(protect(scrollableArea())->scrollingNodeIDForTesting(), WheelEventTestMonitor::DeferReason::ContentScrollInProgress);

    ScrollbarsController::didEndScrollGesture();
#else
    if (m_swift->controller.didEndScrollGesture())
        ScrollbarsController::didEndScrollGesture();
#endif
}

void ScrollbarsControllerMac::mayBeginScrollGesture()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    LOG_WITH_STREAM(OverlayScrollbars, stream << "ScrollbarsControllerMac for [" << scrollableArea() << "] mayBeginScrollGesture");

    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

    [m_scrollerImpPair beginScrollGesture];
    [m_scrollerImpPair contentAreaScrolled];

    ScrollbarsController::mayBeginScrollGesture();
#else
    if (m_swift->controller.mayBeginScrollGesture())
        ScrollbarsController::mayBeginScrollGesture();
#endif
}

void ScrollbarsControllerMac::lockOverlayScrollbarStateToHidden(bool shouldLockState)
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    if (shouldLockState)
        [m_scrollerImpPair lockOverlayScrollerState:NSOverlayScrollerStateHidden];
    else {
        [m_scrollerImpPair unlockOverlayScrollerState];

        // We never update scroller style for PainterControllers that are locked. If we have a pending
        // need to update the style, do it once we've unlocked the scroller state.
        if (m_needsScrollerStyleUpdate)
            updateScrollerStyle();
    }
#else
    m_swift->controller.lockOverlayScrollbarStateToHidden(shouldLockState);
#endif
}

bool ScrollbarsControllerMac::scrollbarsCanBeActive() const
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    return ![m_scrollerImpPair overlayScrollerStateIsLocked];
#else
    return m_swift->controller.scrollbarsCanBeActive();
#endif
}

void ScrollbarsControllerMac::didAddVerticalScrollbar(Scrollbar* scrollbar)
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    RetainPtr painter = scrollerImpForScrollbar(*scrollbar);
    if (!painter)
        return;

    ASSERT(!m_verticalScrollerImpDelegate);
    m_verticalScrollerImpDelegate = adoptNS([[WebScrollerImpDelegate alloc] initWithScrollbar:scrollbar]);

    [painter setDelegate:m_verticalScrollerImpDelegate.get()];
    if (RefPtr layer = protect(scrollbar->scrollableArea())->layerForVerticalScrollbar())
        [painter setLayer:protect(layer->platformLayer()).get()];

    [m_scrollerImpPair setVerticalScrollerImp:painter.get()];
    if (scrollableArea().inLiveResize())
        [painter setKnobAlpha:1];
#else
    m_swift->controller.didAddVerticalScrollbar(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get(), ScrollbarsControllerMacScrollbar { scrollbar });
#endif
}

void ScrollbarsControllerMac::willRemoveVerticalScrollbar(Scrollbar* scrollbar)
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    RetainPtr painter = scrollerImpForScrollbar(*scrollbar);
    if (!painter)
        return;

    ASSERT(m_verticalScrollerImpDelegate);
    [m_verticalScrollerImpDelegate invalidate];
    m_verticalScrollerImpDelegate = nullptr;

    [painter setDelegate:nil];
    [m_scrollerImpPair setVerticalScrollerImp:nil];
#else
    m_swift->controller.willRemoveVerticalScrollbar(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get());
#endif
}

void ScrollbarsControllerMac::didAddHorizontalScrollbar(Scrollbar* scrollbar)
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    RetainPtr painter = scrollerImpForScrollbar(*scrollbar);
    if (!painter)
        return;

    ASSERT(!m_horizontalScrollerImpDelegate);
    m_horizontalScrollerImpDelegate = adoptNS([[WebScrollerImpDelegate alloc] initWithScrollbar:scrollbar]);

    [painter setDelegate:m_horizontalScrollerImpDelegate.get()];
    if (RefPtr layer = protect(scrollbar->scrollableArea())->layerForHorizontalScrollbar())
        [painter setLayer:protect(layer->platformLayer()).get()];

    [m_scrollerImpPair setHorizontalScrollerImp:painter.get()];
    if (scrollableArea().inLiveResize())
        [painter setKnobAlpha:1];
#else
    m_swift->controller.didAddHorizontalScrollbar(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get(), ScrollbarsControllerMacScrollbar { scrollbar });
#endif
}

void ScrollbarsControllerMac::willRemoveHorizontalScrollbar(Scrollbar* scrollbar)
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    RetainPtr painter = scrollerImpForScrollbar(*scrollbar);
    if (!painter)
        return;

    [m_horizontalScrollerImpDelegate invalidate];
    m_horizontalScrollerImpDelegate = nullptr;

    [painter setDelegate:nil];
    [m_scrollerImpPair setHorizontalScrollerImp:nil];
#else
    m_swift->controller.willRemoveHorizontalScrollbar(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get());
#endif
}

void ScrollbarsControllerMac::invalidateScrollbarPartLayers(Scrollbar* scrollbar)
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    RetainPtr painter = scrollerImpForScrollbar(*scrollbar);
    [painter setNeedsDisplay:YES];
#else
    m_swift->controller.invalidateScrollbarPartLayers(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get());
#endif
}

void ScrollbarsControllerMac::verticalScrollbarLayerDidChange()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    CheckedRef scrollableArea = this->scrollableArea();
    RefPtr layer = scrollableArea->layerForVerticalScrollbar();
    RefPtr scrollbar = scrollableArea->verticalScrollbar();
    if (!scrollbar)
        return;

    RetainPtr painter = scrollerImpForScrollbar(*scrollbar);
    if (!painter)
        return;

    [painter setLayer:RetainPtr { layer ? layer->platformLayer() : nil }.get()];
#else
    RefPtr scrollbar = scrollableArea().verticalScrollbar();
    m_swift->controller.verticalScrollbarLayerDidChange(protect(scrollbar ? ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar) : nil).get());
#endif
}

void ScrollbarsControllerMac::horizontalScrollbarLayerDidChange()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    CheckedRef scrollableArea = this->scrollableArea();
    RefPtr layer = scrollableArea->layerForHorizontalScrollbar();
    RefPtr scrollbar = scrollableArea->horizontalScrollbar();
    if (!scrollbar)
        return;

    RetainPtr painter = scrollerImpForScrollbar(*scrollbar);
    if (!painter)
        return;

    [painter setLayer:RetainPtr { layer ? layer->platformLayer() : nil }.get()];
#else
    RefPtr scrollbar = scrollableArea().horizontalScrollbar();
    m_swift->controller.horizontalScrollbarLayerDidChange(protect(scrollbar ? ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar) : nil).get());
#endif
}

bool ScrollbarsControllerMac::shouldScrollbarParticipateInHitTesting(Scrollbar* scrollbar)
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    // Non-overlay scrollbars should always participate in hit testing.
    if (ScrollerStyle::recommendedScrollerStyle() != NSScrollerStyleOverlay)
        return true;

    // Overlay scrollbars should participate in hit testing whenever they are at all visible.
    RetainPtr painter = scrollerImpForScrollbar(*scrollbar);
    if (!painter)
        return false;
    return [painter knobAlpha] > 0;
#else
    if (m_swift->controller.scrollbarsAlwaysParticipateInHitTesting())
        return true;
    return m_swift->controller.shouldScrollbarParticipateInHitTesting(protect(ScrollbarThemeMac::scrollerImpForScrollbar(*scrollbar)).get());
#endif
}

void ScrollbarsControllerMac::notifyContentAreaScrolled(const FloatSize& delta)
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    // This function is called when a page is going into the back/forward cache, but the page
    // isn't really scrolling in that case. We should only pass the message on to the
    // ScrollerImpPair when we're really scrolling on an active page.
    if ([m_scrollerImpPair overlayScrollerStateIsLocked])
        return;

    if (protect(scrollableArea())->isHandlingWheelEvent())
        sendContentAreaScrolled(delta);
    else
        sendContentAreaScrolledSoon(delta);
#else
    if (m_swift->controller.notifyContentAreaScrolled(delta) && !m_sendContentAreaScrolledTimer.isActive())
        m_sendContentAreaScrolledTimer.startOneShot(0_s);
#endif
}

#if !USE_SWIFT_SCROLLBARS_CONTROLLER
void ScrollbarsControllerMac::updateScrollerImps()
{
    CheckedRef scrollableArea = this->scrollableArea();
    RefPtr verticalScrollbar = scrollableArea->verticalScrollbar();
    if (verticalScrollbar && !verticalScrollbar->isCustomScrollbar()) {
        verticalScrollbar->invalidate();

        RetainPtr<NSScrollerImp> oldVerticalPainter = [m_scrollerImpPair verticalScrollerImp];
        RefPtr verticalScrollbarMac = dynamicDowncast<ScrollbarMac>(verticalScrollbar);
        verticalScrollbarMac->createScrollerImp(oldVerticalPainter.get());
        [m_scrollerImpPair setVerticalScrollerImp:protect(verticalScrollbarMac->scrollerImp()).get()];
    }

    RefPtr horizontalScrollbar = scrollableArea->horizontalScrollbar();
    if (horizontalScrollbar && !horizontalScrollbar->isCustomScrollbar()) {
        horizontalScrollbar->invalidate();

        RetainPtr<NSScrollerImp> oldHorizontalPainter = [m_scrollerImpPair horizontalScrollerImp];
        RefPtr horizontalScrollbarMac = dynamicDowncast<ScrollbarMac>(horizontalScrollbar);
        horizontalScrollbarMac->createScrollerImp(oldHorizontalPainter.get());
        [m_scrollerImpPair setHorizontalScrollerImp:protect(horizontalScrollbarMac->scrollerImp()).get()];
    }
}
#endif

void ScrollbarsControllerMac::updateScrollerStyle()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    if ([m_scrollerImpPair overlayScrollerStateIsLocked]) {
        m_needsScrollerStyleUpdate = true;
        return;
    }

    auto* macTheme = macScrollbarTheme();
    if (!macTheme) {
        m_needsScrollerStyleUpdate = false;
        return;
    }

    macTheme->usesOverlayScrollbarsChanged();

    NSScrollerStyle newStyle = [m_scrollerImpPair scrollerStyle];

    updateScrollerImps();

    // The different scrollbar styles have different thicknesses, so we must re-set the
    // frameRect to the new thickness, and the re-layout below will ensure the position
    // and length are properly updated.
    updateScrollbarsThickness();

    // If m_needsScrollerStyleUpdate is true, then the page is restoring from the back/forward cache, and
    // a relayout will happen on its own. Otherwise, we must initiate a re-layout ourselves.
    protect(scrollableArea())->scrollbarStyleChanged(newStyle == NSScrollerStyleOverlay ? ScrollbarStyle::Overlay : ScrollbarStyle::AlwaysVisible, !m_needsScrollerStyleUpdate);

    m_needsScrollerStyleUpdate = false;
#else
    m_swift->controller.updateScrollerStyle();
#endif
}

void ScrollbarsControllerMac::startScrollbarPaintTimer()
{
    m_initialScrollbarPaintTimer.startOneShot(100_ms);
}

bool ScrollbarsControllerMac::scrollbarPaintTimerIsActive() const
{
    return m_initialScrollbarPaintTimer.isActive();
}

void ScrollbarsControllerMac::stopScrollbarPaintTimer()
{
    m_initialScrollbarPaintTimer.stop();
}

void ScrollbarsControllerMac::initialScrollbarPaintTimerFired()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    LOG_WITH_STREAM(OverlayScrollbars, stream << "WebScrollerImpDelegate for [" << scrollableArea() << "] initialScrollbarPaintTimerFired - flashing scrollers");

    // To force the scrollbars to flash, we have to call hide first. Otherwise, the ScrollerImpPair
    // might think that the scrollbars are already showing and bail early.
    [m_scrollerImpPair hideOverlayScrollers];
    [m_scrollerImpPair flashScrollers];
#else
    m_swift->controller.initialScrollbarPaintTimerFired();
#endif
}

void ScrollbarsControllerMac::sendContentAreaScrolledTimerFired()
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    sendContentAreaScrolled(m_contentAreaScrolledTimerScrollDelta);
    m_contentAreaScrolledTimerScrollDelta = { };

    if (RefPtr monitor = wheelEventTestMonitor())
        monitor->removeDeferralForReason(protect(scrollableArea())->scrollingNodeIDForTesting(), WheelEventTestMonitor::DeferReason::ContentScrollInProgress);
#else
    m_swift->controller.sendContentAreaScrolledTimerFired();
#endif
}

#if !USE_SWIFT_SCROLLBARS_CONTROLLER
void ScrollbarsControllerMac::sendContentAreaScrolledSoon(const FloatSize& delta)
{
    m_contentAreaScrolledTimerScrollDelta = delta;

    if (!m_sendContentAreaScrolledTimer.isActive())
        m_sendContentAreaScrolledTimer.startOneShot(0_s);

    if (RefPtr monitor = wheelEventTestMonitor())
        monitor->deferForReason(protect(scrollableArea())->scrollingNodeIDForTesting(), WheelEventTestMonitor::DeferReason::ContentScrollInProgress);
}
#endif

#if !USE_SWIFT_SCROLLBARS_CONTROLLER
void ScrollbarsControllerMac::sendContentAreaScrolled(const FloatSize& delta)
{
    [m_scrollerImpPair contentAreaScrolledInDirection:NSMakePoint(delta.width(), delta.height())];
}
#endif

void ScrollbarsControllerMac::scrollbarWidthChanged(WebCore::ScrollbarWidth)
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    updateScrollbarsThickness();
    updateScrollerImps();
#else
    m_swift->controller.scrollbarWidthChanged();
#endif
}

#if !USE_SWIFT_SCROLLBARS_CONTROLLER
static String scrollbarState(Scrollbar* scrollbar)
{
    if (!scrollbar)
        return "none"_s;

    StringBuilder result;
    result.append(scrollbar->enabled() ? "enabled"_s : "disabled"_s);

    if (!scrollbar->isOverlayScrollbar())
        return result.toString();

    RetainPtr scrollerImp = scrollerImpForScrollbar(*scrollbar);
    if (!scrollerImp)
        return result.toString();

    if (scrollerImp.get().expanded)
        result.append(",expanded"_s);

    if ([scrollerImp trackAlpha] > 0)
        result.append(",visible_track"_s);

    if ([scrollerImp knobAlpha] > 0)
        result.append(",visible_thumb"_s);

    if ([scrollerImp userInterfaceLayoutDirection] == NSUserInterfaceLayoutDirectionRightToLeft)
        result.append(",RTL"_s);

    if ([scrollerImp controlSize] != NSControlSizeRegular)
        result.append(",thin"_s);

    return result.toString();
}
#endif

String ScrollbarsControllerMac::horizontalScrollbarStateForTesting() const
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    return scrollbarState(protect(protect(scrollableArea())->horizontalScrollbar()).get());
#else
    return m_swift->controller.horizontalScrollbarStateForTesting();
#endif
}

String ScrollbarsControllerMac::verticalScrollbarStateForTesting() const
{
#if !USE_SWIFT_SCROLLBARS_CONTROLLER
    return scrollbarState(protect(protect(scrollableArea())->verticalScrollbar()).get());
#else
    return m_swift->controller.verticalScrollbarStateForTesting();
#endif
}

#if !USE_SWIFT_SCROLLBARS_CONTROLLER
WheelEventTestMonitor* ScrollbarsControllerMac::wheelEventTestMonitor() const
{
    return protect(scrollableArea())->scrollAnimator().wheelEventTestMonitor();
}
#endif


} // namespace WebCore

#endif // PLATFORM(MAC)
