//
//  OverlayView.h
//  DFM TrollESP
//

#pragma once

#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>

@interface OverlayView : MTKView <MTKViewDelegate>
- (instancetype)initWithFrame:(CGRect)frame;

// preview=YES 时：菜单默认打开、调试窗口默认打开（给你在 App 里直接看数据用，不依赖 HUD 悬浮层）
- (instancetype)initWithFrame:(CGRect)frame preview:(BOOL)preview;

- (void)startEngine;
- (void)stopEngine;
- (void)toggleMenu;
- (BOOL)menuVisible;
- (void)setMenuOpen:(BOOL)open;
- (void)setDebugWindowOpen:(BOOL)open;
- (void)reloadSettingsFromDisk;

// 悬浮球：0=按下 1=移动 2=抬起；命中返回 YES（调用方就别再把这次触摸喂给游戏）
- (BOOL)handleBallTouchAt:(CGPoint)point phase:(int)phase;
@end

// C 接口统一在 HudBridge.h（那边是 extern "C"，避免 C++ 链接不一致）
