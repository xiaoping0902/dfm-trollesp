//
//  FallbackOverlay.h
//  DFM TrollESP —— 无 Metal 时的 CoreGraphics/UIKit 兜底悬浮层
//

#pragma once

#import <UIKit/UIKit.h>

@interface ESPFallbackOverlay : UIView
- (instancetype)initWithFrame:(CGRect)frame;

- (void)startEngine;
- (void)stopEngine;

- (BOOL)menuVisible;
- (void)toggleMenu;
- (void)setMenuOpen:(BOOL)open;

// 悬浮球：0=按下 1=移动 2=抬起
- (BOOL)handleBallTouchAt:(CGPoint)point phase:(int)phase;
@end
