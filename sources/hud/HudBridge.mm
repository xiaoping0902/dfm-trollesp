//
//  HudBridge.mm
//  DFM TrollESP
//

#import "HudBridge.h"

@protocol ESPHudOverlayProtocol <NSObject>
- (BOOL)menuVisible;
- (BOOL)handleBallTouchAt:(CGPoint)point phase:(int)phase;
- (void)toggleMenu;
- (void)stopEngine;
@end

static __weak id<ESPHudOverlayProtocol> gActiveOverlay = nil;

void ESPHudSetActiveOverlay(id overlay) {
    gActiveOverlay = (id<ESPHudOverlayProtocol>)overlay;
}

void ESPHudClearActiveOverlay(id overlay) {
    if (gActiveOverlay == overlay) gActiveOverlay = nil;
}

BOOL ESPHudMenuVisible(void) {
    id<ESPHudOverlayProtocol> o = gActiveOverlay;
    if (!o) return NO;
    return [o menuVisible];
}

BOOL ESPHudHandleBallTouch(CGPoint point, int phase) {
    id<ESPHudOverlayProtocol> o = gActiveOverlay;
    if (!o) return NO;
    return [o handleBallTouchAt:point phase:phase];
}

void ESPHudToggleMenu(void) {
    id<ESPHudOverlayProtocol> o = gActiveOverlay;
    if (o) [o toggleMenu];
}

void ESPHudShutdown(void) {
    id<ESPHudOverlayProtocol> o = gActiveOverlay;
    if (o) [o stopEngine];
    exit(0);
}
