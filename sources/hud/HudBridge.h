//
//  HudBridge.h
//  DFM TrollESP —— 悬浮层统一入口
//
//  HUD 进程里可能有两种 overlay：
//    * OverlayView（Metal + ImGui）—— 正常情况
//    * ESPFallbackOverlay（CoreGraphics + UIKit）—— 拿不到 Metal 设备时兜底
//  HID 回调 / HUD 窗口都通过这里的函数问“当前是哪一层”。
//

#pragma once

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

void ESPHudSetActiveOverlay(id overlay);
void ESPHudClearActiveOverlay(id overlay);

BOOL ESPHudMenuVisible(void);
BOOL ESPHudHandleBallTouch(CGPoint point, int phase);
void ESPHudToggleMenu(void);
void ESPHudShutdown(void);

#ifdef __cplusplus
}
#endif
