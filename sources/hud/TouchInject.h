//
//  TouchInject.h
//  DFM TrollESP —— 把 HID 事件合成为 UITouch 塞进自己的 UIApplication 事件流
//  （思路来自 TrollSpeed / FakeTouch / KIF，MIT）
//

#pragma once

#import <UIKit/UIKit.h>

@interface ESPTouchInjector : NSObject
+ (void)injectPointId:(NSInteger)pointId
             location:(CGPoint)location
                phase:(UITouchPhase)phase
               window:(UIWindow *)window
                 view:(UIView *)view;
+ (NSUInteger)activeTouchCount;
@end
