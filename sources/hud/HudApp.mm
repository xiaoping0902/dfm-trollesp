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
#import <objc/message.h>
#import <notify.h>

#include <cmath>
#include <cstdlib>
#include "crashlog.h"
#include <cstring>

#import "PrivateApi.h"
#import "OverlayView.h"
#import "FallbackOverlay.h"
#import "HudBridge.h"
#import "TouchInject.h"

#pragma mark - 私有声明

@interface UIApplication (ESPPrivate)
- (UIEvent *)_touchesEvent;
- (void)_accessibilityInit;
- (void)__completeAndRunAsPlugin;
- (void)_run;
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
// 对齐 TrollSpeed：secure window + secure context，这是跨进程托管能显示的前提之一
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
- (BOOL)_canBecomeKeyWindow { return YES; }
- (BOOL)_alwaysGetsContexts { return YES; }
// 菜单关着的时候整个窗口不吃触摸，全部穿透给游戏
- (BOOL)_ignoresHitTest { return !ESPHudMenuVisible(); }
@end

#pragma mark - 根控制器（带屏幕旋转）

@interface ESPHudRootViewController : UIViewController
@property (nonatomic, strong) UIView *overlay;          // 当前生效的悬浮层（Metal 或兜底）
- (void)applyOrientation:(UIInterfaceOrientation)orientation;
@end

@implementation ESPHudRootViewController {
    FBSOrientationObserver *_orientationObserver;
    UIInterfaceOrientation _orientation;
    BOOL _installing;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];
    self.view.opaque = NO;

    // 悬浮层在 viewDidLoad 就安排安装（不能等 viewDidAppear：窗口万一没上屏，那个回调永远不来）。
    // Metal 在 HUD 里大概率拿不到，所以先试两次，不成直接上 CoreGraphics 兜底。
    [self startOrientationObserver];

    __weak ESPHudRootViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       ESPHudRootViewController *s = weakSelf;
                       if (s) [s installOverlayWithRetry:0];
                   });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       ESPHudRootViewController *s = weakSelf;
                       if (s && !s.overlay) {
                           ESPLogStep("hud: 5s 还没装上，强制兜底层");
                           [s installFallbackOverlay];
                       }
                   });
}

- (void)installFallbackOverlay {
    if (self.overlay) return;
    ESPFallbackOverlay *fb = [[ESPFallbackOverlay alloc] initWithFrame:self.view.bounds];
    fb.autoresizingMask = UIViewAutoresizingNone;
    [self.view addSubview:fb];
    self.overlay = fb;
    [fb startEngine];
    [self reapplyOrientation];
    ESPLogStep("hud: CoreGraphics 兜底层已安装");
}

- (void)installOverlayWithRetry:(int)attempt {
    if (_installing) return;
    if (self.overlay) return;
    _installing = YES;

    ESPLogStep("hud: install overlay attempt %d", attempt);

    OverlayView *metal = [[OverlayView alloc] initWithFrame:self.view.bounds];
    _installing = NO;

    if (metal) {
        metal.autoresizingMask = UIViewAutoresizingNone;
        [self.view addSubview:metal];
        self.overlay = metal;
        [metal startEngine];
        ESPLogStep("hud: Metal overlay installed (attempt %d)", attempt);
        [self reapplyOrientation];
        return;
    }

    if (attempt < 2) {
        __weak ESPHudRootViewController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           ESPHudRootViewController *strongSelf = weakSelf;
                           if (strongSelf) [strongSelf installOverlayWithRetry:attempt + 1];
                       });
        return;
    }

    ESPLogStep("hud: Metal 不可用 -> CoreGraphics 兜底");
    [self installFallbackOverlay];
}

- (void)reapplyOrientation {
    const UIInterfaceOrientation keep = _orientation;
    _orientation = UIInterfaceOrientationUnknown;
    [self applyOrientation:(keep == UIInterfaceOrientationUnknown ? UIInterfaceOrientationLandscapeRight
                                                                 : keep)];
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

    UIView *content = self.overlay;
    content.transform = CGAffineTransformIdentity;
    content.bounds = CGRectMake(0, 0, size.width, size.height);
    content.center = center;
    content.transform = CGAffineTransformMakeRotation(angle);

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

    ESPLogStep("hud: window made key+visible");
    [self registerWithSpringBoard];
    return YES;
}

static id gOwnedCAContext = nil;      // 自造的 context 要保活

static unsigned ESPWindowContextId(UIWindow *w) {
    SEL sel = NSSelectorFromString(@"_contextId");
    if (![w respondsToSelector:sel]) return 0;
    return ((unsigned (*)(id, SEL))objc_msgSend)(w, sel);
}

// 按照对「查找」复刻版的勘探结论：posix_spawn 出来的进程常常没有 CAContext，
// 自己造一个再 _setBoundContext: 绑到窗口上，看能不能救回来。
static BOOL ESPTryBindOwnContext(UIWindow *w) {
    Class CA = objc_getClass("CAContext");
    if (!CA) {
        ESPLogStep("hud: 没有 CAContext 类");
        return NO;
    }

    id ctx = nil;
    SEL initWithOptions = NSSelectorFromString(@"initWithOptions:localContext:");
    if ([CA instancesRespondToSelector:initWithOptions]) {
        ctx = ((id (*)(id, SEL, id, BOOL))objc_msgSend)([CA alloc], initWithOptions, @{}, YES);
        ESPLogStep("hud: CAContext initWithOptions:localContext: ok");
    }
    if (!ctx) {
        SEL initRemote = NSSelectorFromString(@"initRemoteWithOptions:");
        if ([CA instancesRespondToSelector:initRemote]) {
            ctx = ((id (*)(id, SEL, id))objc_msgSend)([CA alloc], initRemote, @{});
            ESPLogStep("hud: CAContext initRemoteWithOptions: ok");
        }
    }
    if (!ctx) {
        ESPLogStep("hud: CAContext 造不出来");
        return NO;
    }
    gOwnedCAContext = ctx;

    SEL setLayer = NSSelectorFromString(@"setLayer:");
    if ([ctx respondsToSelector:setLayer]) {
        ((void (*)(id, SEL, id))objc_msgSend)(ctx, setLayer, w.layer);
    }
    SEL setLevel = NSSelectorFromString(@"setLevel:");
    if ([ctx respondsToSelector:setLevel]) {
        ((void (*)(id, SEL, double))objc_msgSend)(ctx, setLevel, w.windowLevel);
    }
    SEL setSecure = NSSelectorFromString(@"setSecure:");
    if ([ctx respondsToSelector:setSecure]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(ctx, setSecure, NO);
    }
    SEL bind = NSSelectorFromString(@"_setBoundContext:");
    if ([w respondsToSelector:bind]) {
        ((void (*)(id, SEL, id))objc_msgSend)(w, bind, ctx);
        ESPLogStep("hud: 已调用 _setBoundContext:");
    } else {
        ESPLogStep("hud: 窗口没有 _setBoundContext:");
    }
    SEL keep = NSSelectorFromString(@"setKeepContextInBackground:");
    if ([w respondsToSelector:keep]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(w, keep, YES);
    }

    return ESPWindowContextId(w) != 0;
}

- (void)registerWithSpringBoard {
    UIApplication *app = [UIApplication sharedApplication];
    Class hostingClass = hud::api().accessibilityWindowHostingClass;

    unsigned contextId = ESPWindowContextId(_hudWindow);
    double level = _hudWindow.windowLevel;
    UIWindowScene *ws = nil;
    if ([_hudWindow respondsToSelector:@selector(windowScene)]) ws = _hudWindow.windowScene;

    ESPLogStep("hud: 诊断 appState=%ld scenes=%lu windows=%lu level=%.0f hidden=%d ctx=0x%X scene=%s",
               (long)app.applicationState, (unsigned long)app.connectedScenes.count,
               (unsigned long)app.windows.count, level, (int)_hudWindow.isHidden, contextId,
               ws ? "yes" : "nil");

    if (contextId == 0) {
        ESPLogStep("hud: 窗口没有 CAContext，尝试自己造一个");
        ESPTryBindOwnContext(_hudWindow);
        contextId = ESPWindowContextId(_hudWindow);
        ESPLogStep("hud: 自造之后 ctx=0x%X", contextId);
    }

    if (!hostingClass) {
        ESPLogStep("hud: 没有 SBSAccessibilityWindowHostingController");
        return;
    }

    _windowHostingController = [[hostingClass alloc] init];
    ESPLogStep("hud: hostingController created");

    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation setTarget:_windowHostingController];
        [invocation setSelector:NSSelectorFromString(@"registerWindowWithContextID:atLevel:")];
        [invocation setArgument:(void *)&contextId atIndex:2];
        [invocation setArgument:(void *)&level atIndex:3];
        [invocation invoke];
        ESPLogStep("hud: registerWindowWithContextID(%u, %.0f) 已调用", contextId, level);
    } @catch (NSException *e) {
        ESPLogStep("hud: registerWindow 抛异常 %s", [[e description] UTF8String]);
    }

    if (contextId == 0) {
        ESPLogStep("hud: ★ ctx 仍然是 0 —— 这一版窗口注定不显示，需要走进程内注入方案");
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

    const CGPoint location = [rep location];

    // ---- 悬浮球优先：菜单关着的时候也能点/拖 ----
    {
        int ballPhase = -1;
        if ([rep isTouchDown]) ballPhase = 0;
        else if ([rep isMove]) ballPhase = 1;
        else if ([rep isLift] || [rep isCancel] || [rep isInRange] || [rep isInRangeLift]) ballPhase = 2;
        if (ballPhase >= 0 && ESPHudHandleBallTouch(location, ballPhase)) {
            return;      // 这一下是球的，不去点菜单
        }
    }

    if (!ESPHudMenuVisible()) return;

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
        ESPLogStep("hud: private api loading");
        if (!hud::api().load()) {
            NSLog(@"[esp] 私有符号加载失败，HUD 无法启动");
            return 1;
        }

        ESPLogStep("hud: private api ok");
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
        ESPLogStep("hud: UIApplication ready, delegate setup");
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
