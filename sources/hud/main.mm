//
//  main.mm
//  DFM TrollESP —— 一个二进制两种身份：
//    * 无参数        -> 普通 App（TrollStore 安装后点开就是配置界面）
//    * -hud          -> root 权限的 HUD 进程（悬浮窗 + 绘制 + 读内存）
//    * -exit / -check -> 给 App 用的进程控制
//

#import <UIKit/UIKit.h>

#include <cstring>
#include <unistd.h>

#import "HudControl.h"

int ESPRunHUD(void);

static void ESPWritePidFile(void) {
    NSString *text = [NSString stringWithFormat:@"%d", getpid()];
    [text writeToFile:ESPHudPidFilePath()
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "-hud") == 0) {
            ESPWritePidFile();
            return ESPRunHUD();
        }
        if (argc > 1 && strcmp(argv[1], "-exit") == 0) {
            ESPHudStop();
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "-check") == 0) {
            return ESPHudIsRunning() ? 1 : 0;
        }
        return UIApplicationMain(argc, argv, @"ESPApplication", @"ESPAppDelegate");
    }
}
