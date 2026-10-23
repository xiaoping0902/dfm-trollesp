//
//  HudApp.mm
//  DFM TrollESP —— HUD 进程（root）启动、跨 App 悬浮窗、HID 触摸
//
//  这一段是整个 TrollStore 方案的核心：
//    1) 主 App 用 posix_spawn + persona(uid 0) 把自己以 -hud 再拉起来；
//    2) HUD 进程自己 new 一个 UIApplication（非标准路径），窗口通过
//       SBSAccessibilityWindowHostingController 注册给 SpringBoard，
//       才能盖在游戏上面；
//    3) 触摸从 BKSHIDEvent 回调拿，转成 AX 事件再合成 UITouch 喂给 ImGui。
//
//  这套流程参考 TrollSpeed（MIT）。改游戏/改 UI 都很安全，机制不用动。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>

#include <cmath>
#include <cstdlib>
#include <cstring>

#import "PrivateApi.h"
#import "OverlayView.h"
#import "TouchInject.h"

#pragma mark - 私有声明

@interface UIApplication (ESPPrivate)
- (UIEvent *)_touchesEvent;
- (void)_accessibilityInit;
- (void)__completeAndRunAsPlugin;
- (void)terminateWithSuccess;
@end

@interface UIWindow (ESPPrivate)
- (unsigned int)_contextId;
@end

@interface UIEventDispatcher : NSObject
- (void)_installEventRunLoopSources:(CFRunLoopRef)runloop;
@end

@interface UIEventFetcher : NSObject
- (void)setEventFetcherSink:(UIEventDispatcher *)sink;
@end

@interface FBSOrientationUpdate : NSObject
- (long long)orientation;
- (unsigned long long)sequenceNumber;
- (long long)rotationDirection;
- (double)duration;
@end

@interface FBSOrientationObserver : NSObject
- (void)activeInterfaceOrientationWithCompletion:(void (^)(FBSOrientationUpdate *))completion;
- (void)setHandler:(void (^)(FBSOrientationUpdate *))handler;
- (void)invalidate;
@end

#pragma mark - 悬浮窗

@interface ESPHudWindow : UIWindow
@end

@implementation ESPHudWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
// 故意不用 secure window：MTKView(CAMetalLayer) 塞进 secure 窗口在部分系统上会整层不显示，
// 代价只是截图/录屏能看到 ESP，无所谓。
- (BOOL)_isSecure { return NO; }
- (BOOL)_shouldCreateContextAsSecure { return NO; }
// 菜单关着的时候整个窗口不吃触摸，全部穿透给游戏
- (BOOL)_ignoresHitTest { return !ESPHudMenuVisible(); }
@end

#pragma mark - 根控制器（带屏幕旋转）

@interface ESPHudRootViewController : UIViewController
@property (nonatomic, strong) OverlayView *overlay;
- (void)applyOrientation:(UIInterfaceOrientation)orientation;
@end

@implementation ESPHudRootViewController {
    FBSOrientationObserver *_orientationObserver;
    UIInterfaceOrientation _orientation;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];
    self.view.opaque = NO;

    _overlay = [[OverlayView alloc] initWithFrame:self.view.bounds];
    _overlay.autoresizingMask = UIViewAutoresizingNone;   // 自己管旋转，别让 autoresizing 打架
    [self.view addSubview:_overlay];
    [_overlay startEngine];

    [self startOrientationObserver];
    [self applyOrientation:UIInterfaceOrientationLandscapeRight];
}

- (void)startOrientationObserver {
    Class cls = objc_getClass("FBSOrientationObserver");
    if (!cls) {
        NSLog(@"[esp] FBSOrientationObserver 不可用，固定横屏");
        return;
    }
    _orientationObserver = [[cls alloc] init];
    __weak ESPHudRootViewController *weakSelf = self;
    [_orientationObserver setHandler:^(FBSOrientationUpdate *update) {
        ESPHudRootViewController *strongSelf = weakSelf;
        if (!strongSelf || !update) return;
        const long long o = [update orientation];
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf applyOrientation:(UIInterfaceOrientation)o];
        });
    }];
    [_orientationObserver activeInterfaceOrientationWithCompletion:^(FBSOrientationUpdate *update) {
        ESPHudRootViewController *strongSelf = weakSelf;
        if (!strongSelf || !update) return;
        const long long o = [update orientation];
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf applyOrientation:(UIInterfaceOrientation)o];
        });
    }];
}

- (void)applyOrientation:(UIInterfaceOrientation)orientation {
    if (orientation == UIInterfaceOrientationUnknown) return;

    const CGRect screen = [UIScreen mainScreen].bounds;      // 始终是竖屏坐标系
    const CGSize portrait = screen.size;

    CGFloat angle = 0.0;
    CGSize size = portrait;

    switch (orientation) {
        case UIInterfaceOrientationPortrait:
            angle = 0.0;
            size = portrait;
            break;
        case UIInterfaceOrientationPortraitUpsideDown:
            angle = M_PI;
            size = portrait;
            break;
        case UIInterfaceOrientationLandscapeLeft:
            angle = -M_PI_2;
            size = CGSizeMake(portrait.height, portrait.width);
            break;
        case UIInterfaceOrientationLandscapeRight:
            angle = M_PI_2;
            size = CGSizeMake(portrait.height, portrait.width);
            break;
        default:
            return;
    }

    if (orientation == _orientation) return;
    _orientation = orientation;

    // 只旋转 overlay 自己：窗口/根视图保持竖屏坐标系，命中测试会跟着 transform 走
    const CGPoint center = CGPointMake(CGRectGetMidX(self.view.bounds),
                                       CGRectGetMidY(self.view.bounds));

    _overlay.transform = CGAffineTransformIdentity;
    _overlay.bounds = CGRectMake(0, 0, size.width, size.height);
    _overlay.center = center;
    _overlay.transform = CGAffineTransformMakeRotation(angle);

    NSLog(@"[esp] orientation=%ld size=%.0fx%.0f", (long)orientation, size.width, size.height);
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

@end

#pragma mark - HUD 专用 UIApplication（装事件派发器）

// 把 UIApplication 的私有事件派发器接上主 runloop。
// 不做这一步，合成出来的 UITouch 进不了 responder 链（sendEvent 之后没人处理）。
static void ESPSetupEventDispatcher(UIApplication *app) {
    static BOOL done = NO;
    if (done || !app) return;
    done = YES;

    @try {
        UIEventDispatcher *dispatcher = (UIEventDispatcher *)[app valueForKey:@"eventDispatcher"];
        if (!dispatcher) {
            NSLog(@"[esp] 没拿到 eventDispatcher（触摸注入可能不完整）");
            return;
        }
        if ([dispatcher respondsToSelector:@selector(_installEventRunLoopSources:)]) {
            [dispatcher _installEventRunLoopSources:CFRunLoopGetMain()];
        }
        Class fetcherClass = NSClassFromString(@"UIEventFetcher");
        if (fetcherClass) {
            UIEventFetcher *fetcher = [[fetcherClass alloc] init];
            if ([fetcher respondsToSelector:@selector(setEventFetcherSink:)]) {
                [fetcher setEventFetcherSink:dispatcher];
            } else {
                [fetcher setValue:dispatcher forKey:@"eventFetcherSink"];
            }
            [app setValue:fetcher forKey:@"eventFetcher"];
        }
        NSLog(@"[esp] event dispatcher installed");
    } @catch (NSException *e) {
        NSLog(@"[esp] event dispatcher setup failed: %@", e);
    }
}

@interface ESPHudApplication : UIApplication
@end

@implementation ESPHudApplication

- (instancetype)init {
    if (self = [super init]) {
        ESPSetupEventDispatcher(self);
    }
    return self;
}

@end

#pragma mark - HUD 代理

@interface ESPHudApplicationDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation ESPHudApplicationDelegate {
    ESPHudWindow *_hudWindow;
    ESPHudRootViewController *_rootViewController;
    id _windowHostingController;
}

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    (void)application;
    (void)launchOptions;

    _rootViewController = [[ESPHudRootViewController alloc] init];

    _hudWindow = [[ESPHudWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _hudWindow.rootViewController = _rootViewController;
    _hudWindow.windowLevel = 10000010.0;
    _hudWindow.hidden = NO;
    self.window = _hudWindow;
    [_hudWindow makeKeyAndVisible];

    [self registerWithSpringBoard];
    return YES;
}

- (void)registerWithSpringBoard {
    Class hostingClass = hud::api().accessibilityWindowHostingClass;
    if (!hostingClass) {
        NSLog(@"[esp] 没有 SBSAccessibilityWindowHostingController，窗口盖不到游戏上");
        return;
    }

    _windowHostingController = [[hostingClass alloc] init];
    const unsigned contextId = [_hudWindow _contextId];
    const double level = _hudWindow.windowLevel;

    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation setTarget:_windowHostingController];
        [invocation setSelector:NSSelectorFromString(@"registerWindowWithContextID:atLevel:")];
        [invocation setArgument:&contextId atIndex:2];
        [invocation setArgument:&level atIndex:3];
        [invocation invoke];
        NSLog(@"[esp] window hosting registered (ctx=%u level=%.0f)", contextId, level);
    } @catch (NSException *e) {
        NSLog(@"[esp] registerWindow 失败: %@", e);
    }
}

@end

#pragma mark - HID 事件 -> 手势 / 注入

static CFTimeInterval gLastThreeFingerTap = 0.0;

static void ESPHandleHIDEvent(IOHIDEventRef event) {
    if (!event) return;

    Class repClass = hud::ESPAccessibilityEventClass();
    if (!repClass) return;

    ESPAXEventRepresentation *rep = nil;
    @try {
        rep = [repClass representationWithHIDEvent:event hidStreamIdentifier:@"UIApplicationEvents"];
    } @catch (NSException *e) {
        return;
    }
    if (!rep) return;

    NSArray *paths = [[rep handInfo] paths];
    const NSUInteger fingerCount = paths.count;

    // 三指双击 开/关菜单（游戏会照常收到这次点击，无所谓）
    if (fingerCount >= 3 && [rep isTouchDown]) {
        const CFTimeInterval now = CFAbsoluteTimeGetCurrent();
        if (now - gLastThreeFingerTap < 0.12) {
            // 同一批事件里的其它手指，忽略
        } else if (now - gLastThreeFingerTap < 0.6) {
            gLastThreeFingerTap = 0.0;
            ESPHudToggleMenu();
            return;
        } else {
            gLastThreeFingerTap = now;
        }
    }

    if (!ESPHudMenuVisible()) return;

    const CGPoint location = [rep location];
    UITouchPhase phase = UITouchPhaseEnded;
    if ([rep isTouchDown]) phase = UITouchPhaseBegan;
    else if ([rep isMove]) phase = UITouchPhaseMoved;
    else if ([rep isCancel]) phase = UITouchPhaseCancelled;
    else if ([rep isLift] || [rep isInRange] || [rep isInRangeLift]) phase = UITouchPhaseEnded;

    NSInteger pointerId = 1;
    if (paths.count > 0) {
        pointerId = (NSInteger)[[paths firstObject] pathIdentity];
    }
    if (pointerId < 1) pointerId = 1;
    if (pointerId > 98) pointerId = 98;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        if (!window) return;
        UIView *view = [window hitTest:location withEvent:nil];
        if (!view) view = window;
        [ESPTouchInjector injectPointId:pointerId location:location phase:phase window:window view:view];
    });
}

static void ESPHIDCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event) {
    (void)target;
    (void)refcon;
    (void)service;
    @autoreleasepool {
        ESPHandleHIDEvent(event);
    }
}

#pragma mark - HUD 入口

int ESPRunHUD(void) {
    @autoreleasepool {
        if (!hud::api().load()) {
            NSLog(@"[esp] 私有符号加载失败，HUD 无法启动");
            return 1;
        }

        [UIScreen class];
        CFRunLoopGetCurrent();

        hud::api().GSInitialize();
        hud::api().BKSDisplayServicesStart();
        if (hud::api().UIApplicationInitialize) {
            hud::api().UIApplicationInitialize();
        }

        // 实例化 UIApplication：优先用私有工厂（我们的子类），拿不到就退化成标准单例
        if (hud::api().UIApplicationInstantiateSingleton) {
            hud::api().UIApplicationInstantiateSingleton(objc_getClass("ESPHudApplication"));
        }
        UIApplication *app = [UIApplication sharedApplication];
        ESPSetupEventDispatcher(app);

        static ESPHudApplicationDelegate *delegate = nil;
        delegate = [[ESPHudApplicationDelegate alloc] init];
        [app setDelegate:delegate];

        if ([app respondsToSelector:@selector(_accessibilityInit)]) {
            [app _accessibilityInit];
        }

        [NSRunLoop currentRunLoop];
        hud::api().BKSHIDEventRegisterEventCallback(ESPHIDCallback);

        if (@available(iOS 15.0, *)) {
            if (hud::api().GSEventInitialize) hud::api().GSEventInitialize(0);
            if (hud::api().GSEventPushRunLoopMode) hud::api().GSEventPushRunLoopMode(kCFRunLoopDefaultMode);
        }

        // SpringBoard 重启后自己退出，避免窗口残留
        static int bootToken;
        notify_register_dispatch("SBSpringBoardDidLaunchNotification", &bootToken,
                                 dispatch_get_main_queue(), ^(int token) {
                                     notify_cancel(token);
                                     exit(0);
                                 });

        if ([app respondsToSelector:NSSelectorFromString(@"__completeAndRunAsPlugin")]) {
            [app __completeAndRunAsPlugin];
            CFRunLoopRun();
        } else if ([app respondsToSelector:@selector(_run)]) {
            [app _run];          // 老系统：直接进 UIApplication 主循环，不返回
        } else {
            CFRunLoopRun();
        }
        return 0;
    }
}
