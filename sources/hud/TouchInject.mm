//
//  TouchInject.mm
//  DFM TrollESP
//
//  HUD 进程不是普通 App，拿不到系统的 UITouch，只能自己造：
//    HID 回调 -> AX 坐标 -> 合成 UITouch -> 走 UIApplication sendEvent
//  这样 ImGui 那条标准触摸链路（touchesBegan/Moved/Ended）就能直接用。
//

#import "TouchInject.h"

#import <objc/runtime.h>
#import <string.h>

// ---- 私有 API 声明 ----
@interface UITouch (ESPPrivate)
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setIsTap:(BOOL)isTap;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setPhase:(UITouchPhase)touchPhase;
- (void)setGestureView:(UIView *)view;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)resetPrevious;
- (void)_setIsFirstTouchForView:(BOOL)firstTouchForView;
- (void)_setIsTapToClick:(BOOL)isTapToClick;
@end

@interface UIEvent (ESPPrivate)
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
- (void)_clearTouches;
@end

@interface UIApplication (ESPPrivate)
- (UIEvent *)_touchesEvent;
@end

static NSArray *gSafeTouchAry = nil;
static NSMutableArray *gTouchSlots = nil;
static NSMutableArray *gLivingTouches = nil;
static CFRunLoopSourceRef gSource = NULL;
static UITouch *gPendingRemove = nil;
static UITouch *gPendingStationary = nil;

static void ESPInjectorFlush(void *info) {
    UIApplication *app = [UIApplication sharedApplication];
    UIEvent *event = [app _touchesEvent];
    [event _clearTouches];

    NSArray *touches = gSafeTouchAry;
    for (UITouch *touch in touches) {
        switch (touch.phase) {
            case UITouchPhaseEnded:
            case UITouchPhaseCancelled:
                gPendingRemove = touch;
                break;
            case UITouchPhaseBegan:
                gPendingStationary = touch;
                break;
            default:
                break;
        }
        [event _addTouch:touch forDelayedDelivery:NO];
    }
    [app sendEvent:event];
}

@implementation ESPTouchInjector

+ (void)load {
    gLivingTouches = [NSMutableArray array];
    gTouchSlots = [NSMutableArray array];

    for (NSInteger i = 0; i < 100; ++i) {
        UITouch *touch = [[UITouch alloc] init];
        [touch setPhase:UITouchPhaseEnded];
        [touch setTimestamp:[NSProcessInfo processInfo].systemUptime];
        [gTouchSlots addObject:touch];
    }

    CFRunLoopSourceContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.perform = ESPInjectorFlush;
    gSource = CFRunLoopSourceCreate(kCFAllocatorDefault, -2, &ctx);
    CFRunLoopAddSource(CFRunLoopGetMain(), gSource, kCFRunLoopCommonModes);
}

+ (NSUInteger)activeTouchCount {
    return gLivingTouches.count;
}

+ (UITouch *)makeTouchAt:(CGPoint)point window:(UIWindow *)window view:(UIView *)view {
    UITouch *touch = [[UITouch alloc] init];
    if (!touch) return nil;

    [touch setWindow:window];                       // 必须先设 window
    [touch _setLocationInWindow:point resetPrevious:YES];
    [touch setView:view];
    [touch setPhase:UITouchPhaseBegan];
    [touch _setIsTapToClick:NO];
    [touch setTimestamp:[NSProcessInfo processInfo].systemUptime];
    if ([touch respondsToSelector:@selector(setGestureView:)]) {
        [touch setGestureView:view];
    }
    return touch;
}

+ (void)injectPointId:(NSInteger)pointId
             location:(CGPoint)location
                phase:(UITouchPhase)phase
               window:(UIWindow *)window
                 view:(UIView *)view {
    if (!window || !view) return;

    NSInteger slotIndex = pointId - 1;
    if (slotIndex < 0) slotIndex = 0;
    if (slotIndex >= (NSInteger)gTouchSlots.count) slotIndex = gTouchSlots.count - 1;

    BOOL needsCopy = NO;

    if (gPendingRemove) {
        UITouch *dead = gPendingRemove;
        gPendingRemove = nil;
        [gLivingTouches removeObjectIdenticalTo:dead];
        needsCopy = YES;
    }
    if (gPendingStationary) {
        UITouch *touch = gPendingStationary;
        gPendingStationary = nil;
        if (touch.phase == UITouchPhaseBegan) {
            [touch setPhase:UITouchPhaseStationary];
            [touch setTimestamp:[NSProcessInfo processInfo].systemUptime];
        }
    }

    UITouch *touch = gTouchSlots[(NSUInteger)slotIndex];
    const BOOL isLiving = [gLivingTouches containsObject:touch];

    if (!isLiving) {
        if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) return;
        touch = [self makeTouchAt:location window:window view:view];
        if (!touch) return;
        [gLivingTouches addObject:touch];
        [gTouchSlots replaceObjectAtIndex:(NSUInteger)slotIndex withObject:touch];
        needsCopy = YES;
    } else {
        if (touch.phase == UITouchPhaseBegan && phase == UITouchPhaseMoved) return;
        [touch setTimestamp:[NSProcessInfo processInfo].systemUptime];
        [touch _setLocationInWindow:location resetPrevious:NO];
    }

    [touch setPhase:phase];
    [touch setTimestamp:[NSProcessInfo processInfo].systemUptime];

    if (needsCopy) {
        CFTypeRef keep = CFBridgingRetain(gSafeTouchAry);
        gSafeTouchAry = [NSArray arrayWithArray:gLivingTouches];
        CFBridgingRelease(keep);
    }

    CFRunLoopSourceSignal(gSource);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

@end
