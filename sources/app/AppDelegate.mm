//
//  AppDelegate.mm
//  DFM TrollESP —— 主 App（TrollStore 里点开的那个界面）
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <unistd.h>

#import "HudControl.h"
#import "OverlayView.h"
#include "esp_core.hpp"

// App 内的调试预览：不走 HUD、不需要悬浮窗，直接在 App 窗口里跑同一套 ImGui 界面
@interface ESPPreviewViewController : UIViewController
@end

@implementation ESPPreviewViewController {
    OverlayView *_preview;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _preview = [[OverlayView alloc] initWithFrame:self.view.bounds preview:YES];
    if (!_preview) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 24, 120)];
        label.numberOfLines = 0;
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont systemFontOfSize:13];
        label.text = @"这台设备/这个进程拿不到 Metal 设备，预览不可用。\n"
                     @"真机 TrollStore 安装一般没问题，检查 entitlements 里的 "
                     @"com.apple.QuartzCore.displayable-context。";
        [self.view addSubview:label];
        return;
    }

    _preview.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_preview];
    [_preview startEngine];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"✕ 退出预览" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.9];
    close.layer.cornerRadius = 8.0;
    close.frame = CGRectMake(self.view.bounds.size.width - 132, 52, 116, 36);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [close addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];
}

- (void)onClose {
    [_preview stopEngine];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleIdentifier;
@end

@interface ESPApplication : UIApplication
@end

@implementation ESPApplication
@end

#pragma mark - 小控件

static UILabel *MakeTitle(NSString *text) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont boldSystemFontOfSize:15];
    label.textColor = [UIColor colorWithWhite:0.95 alpha:1.0];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

static UILabel *MakeBody(NSString *text) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

static UIButton *MakeButton(NSString *title, UIColor *color, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.backgroundColor = color;
    button.layer.cornerRadius = 9.0;
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintEqualToConstant:44].active = YES;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark - 主界面

@interface ESPRootViewController : UIViewController
@end

@implementation ESPRootViewController {
    UIScrollView *_scrollView;
    UIStackView *_stack;

    UILabel *_hudStatusLabel;
    UILabel *_gameStatusLabel;

    UIButton *_startButton;
    UIButton *_stopButton;
    UIButton *_openGameButton;
    UIButton *_diagButton;
    UIButton *_previewButton;
    UITextView *_logView;

    UISwitch *_enableSwitch;
    UISwitch *_skeletonSwitch;
    UISwitch *_boxSwitch;
    UISwitch *_distanceSwitch;

    esp::EspSettings _settings;
    esp::Offsets _offsets;
    NSTimer *_refreshTimer;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"三角洲 TrollESP";
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1.0];

    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_scrollView];

    _stack = [[UIStackView alloc] init];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 12;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scrollView addSubview:_stack];

    [NSLayoutConstraint activateConstraints:@[
        [_stack.leadingAnchor constraintEqualToAnchor:_scrollView.leadingAnchor constant:18],
        [_stack.trailingAnchor constraintEqualToAnchor:_scrollView.trailingAnchor constant:-18],
        [_stack.topAnchor constraintEqualToAnchor:_scrollView.topAnchor constant:18],
        [_stack.bottomAnchor constraintEqualToAnchor:_scrollView.bottomAnchor constant:-24],
        [_stack.widthAnchor constraintEqualToAnchor:_scrollView.widthAnchor constant:-36],
    ]];

    [self buildUI];
    [self reloadSettings];
    [self startRefreshTimer];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshStatus];
}

- (void)buildUI {
    [_stack addArrangedSubview:MakeTitle(@"状态 / Status")];

    _hudStatusLabel = MakeBody(@"HUD: 检查中…");
    _gameStatusLabel = MakeBody(@"游戏: 检查中…");
    [_stack addArrangedSubview:_hudStatusLabel];
    [_stack addArrangedSubview:_gameStatusLabel];

    _startButton = MakeButton(@"启动绘制 Start", [UIColor colorWithRed:0.16 green:0.55 blue:0.36 alpha:1], self, @selector(onStart));
    _stopButton = MakeButton(@"停止绘制 Stop", [UIColor colorWithRed:0.45 green:0.20 blue:0.20 alpha:1], self, @selector(onStop));
    _openGameButton = MakeButton(@"打开游戏 Launch Game", [UIColor colorWithRed:0.18 green:0.28 blue:0.45 alpha:1], self, @selector(onOpenGame));

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_startButton, _stopButton]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 10;
    row.distribution = UIStackViewDistributionFillEqually;
    [_stack addArrangedSubview:row];
    [_stack addArrangedSubview:_openGameButton];

    _diagButton = MakeButton(@"诊断 Diagnose（不开 HUD 直接试连一次）",
                             [UIColor colorWithRed:0.32 green:0.24 blue:0.45 alpha:1],
                             self, @selector(onDiagnose));
    [_stack addArrangedSubview:_diagButton];

    _previewButton = MakeButton(@"调试预览 Preview（App 内看 ImGui 菜单/骨骼表）",
                                [UIColor colorWithRed:0.20 green:0.38 blue:0.52 alpha:1],
                                self, @selector(onPreview));
    [_stack addArrangedSubview:_previewButton];

    _logView = [[UITextView alloc] init];
    _logView.editable = NO;
    _logView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1.0];
    _logView.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    _logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logView.layer.cornerRadius = 8.0;
    _logView.text = @"点「诊断」，这里会打印 pid / 模块基址 / GObjects / GNames / 骨骼探测结果。";
    NSLayoutConstraint *logHeight = [_logView.heightAnchor constraintEqualToConstant:200];
    logHeight.active = YES;
    [_stack addArrangedSubview:_logView];

    [_stack addArrangedSubview:MakeTitle(@"快捷开关 / Quick toggles")];
    _enableSwitch = [self addSwitchRow:@"总开关 Enable" action:@selector(onToggle:)];
    _skeletonSwitch = [self addSwitchRow:@"骨骼 Skeleton" action:@selector(onToggle:)];
    _boxSwitch = [self addSwitchRow:@"方框 Box" action:@selector(onToggle:)];
    _distanceSwitch = [self addSwitchRow:@"距离 Distance" action:@selector(onToggle:)];

    [_stack addArrangedSubview:MakeTitle(@"用法 / How to use")];
    [_stack addArrangedSubview:MakeBody(
        @"1) 先正常打开三角洲，进到大厅或对局；\n"
        @"2) 回到这里点「启动绘制」，HUD 会以 root 身份常驻；\n"
        @"3) 切回游戏，屏幕上出现透视；三指双击 开/关菜单；\n"
        @"4) 菜单里可以改颜色/距离/线宽，也能改引擎偏移（换版本时用）。\n\n"
        @"注意：这是外部读内存方案，不改游戏文件、不注入 dylib；\n"
        @"如果哪天真被 task_for_pid 拦住，菜单里会有明确报错，\n"
        @"可以改用注入版（同一套核心代码，见 README）。")];

    [_stack addArrangedSubview:MakeBody([NSString stringWithFormat:@"设置文件：%s", esp::SettingsPlistPath()])];
}

- (UISwitch *)addSwitchRow:(NSString *)title action:(SEL)action {
    UILabel *label = MakeBody(title);
    label.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, sw]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10;
    [_stack addArrangedSubview:row];
    return sw;
}

- (void)reloadSettings {
    if (!esp::LoadSettings(_settings, _offsets)) {
        esp::EspSettings s;
        esp::Offsets o;
        _settings = s;
        _offsets = o;
    }
    _enableSwitch.on = _settings.enabled;
    _skeletonSwitch.on = _settings.drawSkeleton;
    _boxSwitch.on = _settings.drawBox;
    _distanceSwitch.on = _settings.drawDistance;
}

- (void)saveSettings {
    esp::SaveSettings(_settings, _offsets);
}

#pragma mark 动作

- (void)onStart {
    if (ESPHudIsRunning()) {
        [self toast:@"HUD 已经在跑了"];
        return;
    }
    const bool ok = ESPHudStart();
    [self toast:ok ? @"已启动（切回游戏生效）" : @"启动失败，看控制台日志"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self refreshStatus]; });
}

- (void)onStop {
    ESPHudStop();
    [self toast:@"已停止"];
    [self refreshStatus];
}

- (void)onOpenGame {
    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    if (workspaceClass) {
        id workspace = [workspaceClass defaultWorkspace];
        BOOL opened = [workspace openApplicationWithBundleID:@"com.tencent.tmgp.dfm"];
        if (!opened) [self toast:@"调用失败，手动开游戏吧"];
        return;
    }
    [self toast:@"找不到 LSApplicationWorkspace"];
}

- (void)onToggle:(UISwitch *)sender {
    _settings.enabled = _enableSwitch.on;
    _settings.drawSkeleton = _skeletonSwitch.on;
    _settings.drawBox = _boxSwitch.on;
    _settings.drawDistance = _distanceSwitch.on;
    [self saveSettings];
}

// App 内直接看 ImGui：菜单 + 调试窗口（默认都打开）
- (void)onPreview {
    pid_t pid = 0;
    if (!esp::FindPid(_settings.moduleName.c_str(), &pid)) {
        [self toast:@"游戏没在跑，预览里只有界面没有数据"];
    }
    ESPPreviewViewController *vc = [[ESPPreviewViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:vc animated:YES completion:nil];
}

// 不开 HUD，直接用 App 进程跑一遍完整链路，把日志贴在界面上
- (void)onDiagnose {    _diagButton.enabled = NO;
    _diagButton.alpha = 0.5;
    _logView.text = @"正在连接游戏进程…";

    esp::EspSettings settings = _settings;
    esp::Offsets offsets = _offsets;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        esp::Engine engine;
        engine.SetOffsets(offsets);

        std::string log;
        const bool ok = engine.Bootstrap(settings.moduleName, log);
        log += "-------- probe --------\n";
        log += engine.ProbeReport();

        for (int i = 0; i < 30; ++i) {          // 采样 3 秒，看看到底能抓到什么
            engine.Tick();
            usleep(100 * 1000);
        }
        esp::Snapshot s = engine.CopySnapshot();
        char buf[256];
        snprintf(buf, sizeof(buf),
                 "\n-------- snapshot --------\n"
                 "ok=%d actors=%d chars=%d boneFail=%d draw=%zu cam=%d\n",
                 ok ? 1 : 0, s.scannedActors, s.characterActors, s.boneFailures,
                 s.entities.size(), s.camera.valid ? 1 : 0);
        log += buf;
        engine.Shutdown();

        NSString *text = [NSString stringWithUTF8String:log.c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_logView.text = text ?: @"(日志为空)";
            self->_diagButton.enabled = YES;
            self->_diagButton.alpha = 1.0;
        });
    });
}

#pragma mark 状态刷新

- (void)startRefreshTimer {
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                     target:self
                                                   selector:@selector(onTimer:)
                                                   userInfo:nil
                                                    repeats:YES];
}

- (void)onTimer:(NSTimer *)timer {
    (void)timer;
    [self refreshStatus];
}

- (void)refreshStatus {
    const bool hudRunning = ESPHudIsRunning();
    _hudStatusLabel.text = hudRunning ? @"HUD: 运行中 ✔" : @"HUD: 未运行";
    _hudStatusLabel.textColor = hudRunning ? [UIColor colorWithRed:0.4 green:1.0 blue:0.5 alpha:1]
                                           : [UIColor colorWithWhite:0.6 alpha:1];

    pid_t gamePid = 0;
    const bool gameRunning = esp::FindPid(_settings.moduleName.c_str(), &gamePid);
    _gameStatusLabel.text = gameRunning
        ? [NSString stringWithFormat:@"游戏: 运行中 (pid=%d)", gamePid]
        : @"游戏: 未运行";
    _gameStatusLabel.textColor = gameRunning ? [UIColor colorWithRed:0.45 green:0.85 blue:1.0 alpha:1]
                                             : [UIColor colorWithWhite:0.6 alpha:1];
}

- (void)toast:(NSString *)text {
    NSLog(@"[esp] %@", text);
    _hudStatusLabel.text = text;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self refreshStatus]; });
}

@end

#pragma mark - 代理

@interface ESPAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation ESPAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    (void)application;
    (void)launchOptions;

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    ESPRootViewController *root = [[ESPRootViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.navigationBar.barStyle = UIBarStyleBlack;
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
