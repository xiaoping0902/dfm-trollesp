//
//  HudBridge.mm
//  DFM TrollESP
//

#import "HudBridge.h"

static __weak id gActiveOverlay = nil;

void ESPHudSetActiveOverlay(id overlay) {
    gActiveOverlay = overlay;
}

void ESPHudClearActiveOverlay(id overlay) {
    if (gActiveOverlay == overlay) gActiveOverlay = nil;
}

BOOL ESPHudMenuVisible(void) {
    id o = gActiveOverlay;
    if (!o) return NO;
    return [o menuVisible];
}

BOOL ESPHudHandleBallTouch(CGPoint point, int phase) {
    id o = gActiveOverlay;
    if (!o) return NO;
    return [o handleBallTouchAt:point phase:phase];
}

void ESPHudToggleMenu(void) {
    id o = gActiveOverlay;
    if (o) [o toggleMenu];
}

void ESPHudShutdown(void) {
    id o = gActiveOverlay;
    if (o) [o stopEngine];
    exit(0);
}
