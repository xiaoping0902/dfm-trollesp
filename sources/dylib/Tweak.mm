//
//  Tweak.mm
//  DFM TrollESP —— 注入版（可选）
//
//  用途：如果外部 task_for_pid 被拦（ACE 的 PT_DENY_ATTACH 之类），
//  用 TrollFools 把这个 dylib 注进 DeltaForceClient，内存访问变成读自己，
//  权限、偏移、渲染、ESP 代码全都不用改（核心代码用 -DESP_INTERNAL 编译）。
//
//  构建：make -f Makefile.dylib
//       产物 .theos/obj/dfmesp.dylib → 丢给 TrollFools 注入
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <dispatch/dispatch.h>
#include <unistd.h>

#import "OverlayView.h"

static UIWindow *gESPWindow = nil;
static OverlayView *gESPOverlay = nil;

static UIWindow *ESPMakeWindow(void) {
    // iOS 13+ 用 windowScene，拿不到就退回老接口
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            return [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
        }
    }
    return [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
}

static void ESPInstallOverlay(void) {
    if (gESPWindow) return;
    if (![UIApplication sharedApplication]) return;

    UIWindow *window = ESPMakeWindow();
    if (!window) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ESPInstallOverlay(); });
        return;
    }

    gESPWindow = window;
    gESPWindow.frame = [UIScreen mainScreen].bounds;
    gESPWindow.windowLevel = 1000000.0;            // 盖在游戏自身 UI 上面
    gESPWindow.backgroundColor = [UIColor clearColor];
    gESPWindow.opaque = NO;
    gESPWindow.hidden = NO;

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    root.view.opaque = NO;

    gESPOverlay = [[OverlayView alloc] initWithFrame:gESPWindow.bounds];
    gESPOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:gESPOverlay];

    gESPWindow.rootViewController = root;
    [gESPWindow makeKeyAndVisible];
    [gESPOverlay startEngine];

    NSLog(@"[esp] in-process overlay installed (pid=%d)", getpid());
}

__attribute__((constructor))
static void ESPTweakInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       ESPInstallOverlay();
                   });

    // 游戏切后台回来 / 旋转之后再确认一次
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
                                                      (void)note;
                                                      ESPInstallOverlay();
                                                  }];
}
