//
//  HudControl.h
//  DFM TrollESP —— 主 App 用来拉起/停止 root 权限的 HUD 进程
//

#pragma once

#import <Foundation/Foundation.h>

bool ESPHudIsRunning(void);
bool ESPHudStart(void);
bool ESPHudStop(void);
NSString *ESPHudPidFilePath(void);
