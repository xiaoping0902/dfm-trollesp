//
//  FallbackOverlay.mm
//  DFM TrollESP —— 没有 Metal 时的兜底悬浮层
//
//  HUD 是 root 守护进程，某些系统/机型上 MTLCreateSystemDefaultDevice() 会返回 nil
//  （我们实测 iPad14,4 / iOS 16.1 就是），这时候 ImGui 那条路整个走不了。
//  这一层用纯 UIKit + CoreGraphics：照样画骨骼/方框/距离，菜单用 UIKit 控件，
//  调试数据用等宽 UITextView 刷出来，保证"一定有那一层、一定能调"。
//

#import "FallbackOverlay.h"

#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "esp_core.hpp"
#include "debug.hpp"
#include "crashlog.h"
#include "HudBridge.h"

@implementation ESPFallbackOverlay {
    esp::Engine _engine;
    esp::Snapshot _snap;

    std::thread _worker;
    std::atomic<bool> _workerRunning;
    std::atomic<bool> _engineReady;
    std::atomic<bool> _reinitNeeded;

    std::mutex _cfgMu;
    esp::EspSettings _settings;
    esp::Offsets _offsets;

    std::mutex _logMu;
    std::string _bootLog;

    BOOL _menuOpen;
    BOOL _ballDragging;
    BOOL _ballMoved;
    CGPoint _ballDragStart;
    CGPoint _ballDragOffset;

    CADisplayLink *_link;
    NSTimer *_debugTimer;

    UIView *_panel;
    UITextView *_debugView;
    UISwitch *_swEnable;
    UISwitch *_swSkeleton;
    UISwitch *_swBox;
    UISwitch *_swDistance;
    UISwitch *_swSnapline;
    UISlider *_slDistance;
    UILabel *_slDistanceLabel;
    UILabel *_statusLabel;
}

#pragma mark - 生命周期

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = YES;
        self.multipleTouchEnabled = NO;

        _workerRunning = false;
        _engineReady = false;
        _reinitNeeded = true;
        _menuOpen = NO;
        _ballDragging = NO;

        {
            esp::EspSettings s;
            esp::Offsets o;
            if (!esp::LoadSettings(s, o)) {
                esp::SaveSettings(s, o);
            }
            std::lock_guard<std::mutex> lk(_cfgMu);
            _settings = s;
            _offsets = o;
        }

        [self buildPanel];

        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame)];
        _link.preferredFramesPerSecond = 60;
        [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

        _debugTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                       target:self
                                                     selector:@selector(refreshDebugText:)
                                                     userInfo:nil
                                                      repeats:YES];

        ESPHudSetActiveOverlay(self);
        ESPLogStep("fallback: overlay created %.0fx%.0f", frame.size.width, frame.size.height);
    }
    return self;
}

- (void)dealloc {
    ESPHudClearActiveOverlay(self);
    [_link invalidate];
    [_debugTimer invalidate];
    [self stopEngine];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    esp::SetViewportSize((int)self.bounds.size.width, (int)self.bounds.size.height);
    [self layoutPanel];
}

#pragma mark - 采样线程

- (void)startEngine {
    if (_workerRunning.exchange(true)) return;
    _reinitNeeded = true;

    __unsafe_unretained ESPFallbackOverlay *rawSelf = self;
    _worker = std::thread([rawSelf]() { [rawSelf workerLoop]; });
}

- (void)stopEngine {
    _workerRunning = false;
    if (_worker.joinable()) _worker.join();
    _engine.Shutdown();
    _engineReady = false;
}

- (void)bootstrapEngine {
    esp::EspSettings s;
    esp::Offsets o;
    {
        std::lock_guard<std::mutex> lk(_cfgMu);
        s = _settings;
        o = _offsets;
    }
    _engine.SetOffsets(o);
    std::string log;
    const bool ok = _engine.Bootstrap(s.moduleName, log);
    {
        std::lock_guard<std::mutex> lk(_logMu);
        _bootLog = log;
    }
    _engineReady = ok;
    if (!ok) _engine.Shutdown();
    ESPLogStep("fallback: bootstrap %s", ok ? "ok" : "failed");
}

- (void)workerLoop {
    while (_workerRunning.load()) {
        @autoreleasepool {
            if (_reinitNeeded.exchange(false)) {
                [self bootstrapEngine];
            }
            if (!_engineReady.load()) {
                for (int i = 0; i < 25 && _workerRunning.load(); ++i) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(100));
                }
                continue;
            }
            _engine.SetDebugTarget(0, true);
            _engine.Tick();
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
    }
}

- (esp::Snapshot)snapshotCopy {
    return _engine.CopySnapshot();
}

#pragma mark - 菜单

- (BOOL)menuVisible {
    return _menuOpen;
}

- (void)toggleMenu {
    [self setMenuOpen:!_menuOpen];
}

- (void)setMenuOpen:(BOOL)open {
    _menuOpen = open;
    _panel.hidden = !open;
    if (open) {
        esp::EspSettings s;
        esp::Offsets o;
        {
            std::lock_guard<std::mutex> lk(_cfgMu);
            s = _settings;
            o = _offsets;
        }
        esp::LoadSettings(s, o);
        {
            std::lock_guard<std::mutex> lk(_cfgMu);
            _settings = s;
            _offsets = o;
        }
        [self syncControls];
        [self refreshDebugText:nil];
    }
    [self setNeedsDisplay];
}

#pragma mark - 悬浮球（由 HID 回调驱动）

- (BOOL)handleBallTouchAt:(CGPoint)point phase:(int)phase {
    if (_menuOpen) return NO;

    esp::EspSettings s;
    {
        std::lock_guard<std::mutex> lk(_cfgMu);
        s = _settings;
    }
    if (!s.showBall) return NO;

    const CGFloat W = self.bounds.size.width;
    const CGFloat H = self.bounds.size.height;
    if (W < 10 || H < 10) return NO;

    const CGFloat r = s.ballRadius;
    const CGPoint center = CGPointMake(s.ballX * W, s.ballY * H);
    const CGFloat dx = point.x - center.x;
    const CGFloat dy = point.y - center.y;
    const CGFloat hitR = r + 14.0;

    if (phase == 0) {
        if (dx * dx + dy * dy > hitR * hitR) return NO;
        _ballDragging = YES;
        _ballMoved = NO;
        _ballDragStart = point;
        _ballDragOffset = CGPointMake(center.x - point.x, center.y - point.y);
        return YES;
    }
    if (!_ballDragging) return NO;

    if (phase == 1) {
        if (fabs(point.x - _ballDragStart.x) > 8 || fabs(point.y - _ballDragStart.y) > 8) {
            _ballMoved = YES;
        }
        CGFloat nx = point.x + _ballDragOffset.x;
        CGFloat ny = point.y + _ballDragOffset.y;
        nx = fmax(r + 4, fmin(W - r - 4, nx));
        ny = fmax(r + 4, fmin(H - r - 4, ny));
        {
            std::lock_guard<std::mutex> lk(_cfgMu);
            _settings.ballX = (float)(nx / W);
            _settings.ballY = (float)(ny / H);
        }
        [self setNeedsDisplay];
        return YES;
    }

    _ballDragging = NO;
    if (!_ballMoved) {
        [self setMenuOpen:YES];
    } else {
        esp::EspSettings s2;
        esp::Offsets o2;
        {
            std::lock_guard<std::mutex> lk(_cfgMu);
            s2 = _settings;
            o2 = _offsets;
        }
        esp::SaveSettings(s2, o2);
    }
    return YES;
}

#pragma mark - 帧回调 / 绘制

- (void)onFrame {
    if (!_menuOpen) [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    esp::EspSettings s;
    {
        std::lock_guard<std::mutex> lk(_cfgMu);
        s = _settings;
    }
    esp::SetViewportSize((int)self.bounds.size.width, (int)self.bounds.size.height);

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    const esp::Snapshot snap = [self snapshotCopy];

    if (s.enabled && snap.camera.valid && !snap.entities.empty()) {
        [self drawEntities:snap.camera snapshot:snap settings:s context:ctx];
    }

    if (!_menuOpen && s.showBall) {
        [self drawBallWithSettings:s];
    }
}

- (void)drawEntities:(const esp::Camera &)cam
            snapshot:(const esp::Snapshot &)snap
            settings:(const esp::EspSettings &)s
             context:(CGContextRef)ctx {
    CGContextSetLineWidth(ctx, s.lineThickness);
    CGContextSetRGBStrokeColor(ctx, s.colorSkeleton[0], s.colorSkeleton[1], s.colorSkeleton[2],
                               s.colorSkeleton[3]);

    for (const esp::Entity &e : snap.entities) {
        if (s.maxDistance > 0.f && e.distance > s.maxDistance) continue;

        std::array<CGPoint, esp::kB_Count> pts{};
        std::array<uint8_t, esp::kB_Count> ok{};
        float minX = 1e9f, maxX = -1e9f, minY = 1e9f, maxY = -1e9f;
        int onScreen = 0;

        for (int i = 0; i < esp::kB_Count; ++i) {
            if (!e.have[i]) continue;
            float sx = 0, sy = 0;
            if (!esp::WorldToScreen(cam, e.bones[i], sx, sy)) continue;
            pts[i] = CGPointMake(sx, sy);
            ok[i] = 1;
            ++onScreen;
            minX = std::min(minX, sx); maxX = std::max(maxX, sx);
            minY = std::min(minY, sy); maxY = std::max(maxY, sy);
        }
        if (onScreen < 3) continue;

        if (s.drawSkeleton) {
            for (int k = 0; k < esp::kSkeletonLinkCount; ++k) {
                const int a = esp::kSkeletonLinks[k].a;
                const int b = esp::kSkeletonLinks[k].b;
                if (!ok[a] || !ok[b]) continue;
                CGContextMoveToPoint(ctx, pts[a].x, pts[a].y);
                CGContextAddLineToPoint(ctx, pts[b].x, pts[b].y);
                CGContextStrokePath(ctx);
            }
        }

        if (s.drawBox) {
            const float boxH = std::max(8.f, maxY - minY);
            float boxW = (boxH) * 0.52f;
            if (ok[esp::kB_ClavL] && ok[esp::kB_ClavR]) {
                boxW = std::fabs(pts[esp::kB_ClavR].x - pts[esp::kB_ClavL].x) * 1.45f;
            }
            const float cx = (minX + maxX) * 0.5f;
            CGContextSetRGBStrokeColor(ctx, s.colorBox[0], s.colorBox[1], s.colorBox[2], s.colorBox[3]);
            CGContextSetLineWidth(ctx, s.boxThickness);
            CGContextStrokeRect(ctx, CGRectMake(cx - boxW * 0.5f, minY, boxW, boxH));
            CGContextSetRGBStrokeColor(ctx, s.colorSkeleton[0], s.colorSkeleton[1],
                                       s.colorSkeleton[2], s.colorSkeleton[3]);
            CGContextSetLineWidth(ctx, s.lineThickness);
        }

        if (s.drawDistance) {
            NSString *text = [NSString stringWithFormat:@"%.0fm", e.distance];
            [text drawAtPoint:CGPointMake((minX + maxX) * 0.5f - 12, maxY + 2)
               withAttributes:@{
                   NSFontAttributeName: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightBold],
                   NSForegroundColorAttributeName: [UIColor colorWithRed:s.colorText[0]
                                                                  green:s.colorText[1]
                                                                   blue:s.colorText[2]
                                                                  alpha:s.colorText[3]]
               }];
        }
    }
}

- (void)drawBallWithSettings:(const esp::EspSettings &)s {
    const CGFloat W = self.bounds.size.width;
    const CGFloat H = self.bounds.size.height;
    const CGPoint c = CGPointMake(s.ballX * W, s.ballY * H);
    const CGFloat r = s.ballRadius;

    UIBezierPath *circle = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - r, c.y - r, r * 2, r * 2)];
    [[UIColor colorWithRed:0.09 green:0.55 blue:0.34 alpha:0.85] setFill];
    [circle fill];
    [[UIColor colorWithRed:0.5 green:1.0 blue:0.7 alpha:0.9] setStroke];
    circle.lineWidth = 2.0;
    [circle stroke];

    NSString *label = @"ESP";
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    const CGSize ts = [label sizeWithAttributes:attrs];
    [label drawAtPoint:CGPointMake(c.x - ts.width * 0.5f, c.y - ts.height * 0.5f) withAttributes:attrs];
}

#pragma mark - 菜单 UI

- (void)buildPanel {
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 340, 460)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
    _panel.layer.cornerRadius = 12.0;
    _panel.layer.borderWidth = 1.0;
    _panel.layer.borderColor = [UIColor colorWithWhite:0.35 alpha:1.0].CGColor;
    _panel.hidden = YES;
    _panel.autoresizingMask = UIViewAutoresizingNone;
    [self addSubview:_panel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 10, 300, 22)];
    title.text = @"三角洲 TrollESP（兼容模式：无 Metal）";
    title.font = [UIFont boldSystemFontOfSize:13];
    title.textColor = [UIColor whiteColor];
    [_panel addSubview:title];

    CGFloat y = 40;
    _swEnable = [self addSwitchRow:@"总开关" y:&y action:@selector(onToggleChanged:)];
    _swSkeleton = [self addSwitchRow:@"骨骼" y:&y action:@selector(onToggleChanged:)];
    _swBox = [self addSwitchRow:@"方框" y:&y action:@selector(onToggleChanged:)];
    _swDistance = [self addSwitchRow:@"距离" y:&y action:@selector(onToggleChanged:)];
    _swSnapline = [self addSwitchRow:@"准心线" y:&y action:@selector(onToggleChanged:)];

    _slDistanceLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, y, 140, 20)];
    _slDistanceLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _slDistanceLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    [_panel addSubview:_slDistanceLabel];

    _slDistance = [[UISlider alloc] initWithFrame:CGRectMake(14, y + 20, 300, 24)];
    _slDistance.minimumValue = 20;
    _slDistance.maximumValue = 1500;
    [_slDistance addTarget:self action:@selector(onDistanceChanged:) forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:_slDistance];
    y += 52;

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, y, 310, 18)];
    _statusLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _statusLabel.textColor = [UIColor colorWithRed:0.5 green:1.0 blue:0.7 alpha:1];
    [_panel addSubview:_statusLabel];
    y += 22;

    _debugView = [[UITextView alloc] initWithFrame:CGRectMake(14, y, 312, 240)];
    _debugView.editable = NO;
    _debugView.scrollEnabled = YES;
    _debugView.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1.0];
    _debugView.textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    _debugView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    _debugView.layer.cornerRadius = 6.0;
    [_panel addSubview:_debugView];
    y += 248;

    UIButton *collapse = [UIButton buttonWithType:UIButtonTypeSystem];
    collapse.frame = CGRectMake(14, y, 312, 38);
    [collapse setTitle:@"● 收起成球" forState:UIControlStateNormal];
    [collapse setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    collapse.backgroundColor = [UIColor colorWithRed:0.16 green:0.45 blue:0.30 alpha:1.0];
    collapse.layer.cornerRadius = 8.0;
    [collapse addTarget:self action:@selector(onCollapse) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:collapse];

    [self syncControls];
}

- (UISwitch *)addSwitchRow:(NSString *)text y:(CGFloat *)y action:(SEL)action {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(14, *y, 160, 28)];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    [_panel addSubview:label];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(240, *y - 2, 60, 30)];
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:sw];

    *y += 36;
    return sw;
}

- (void)layoutPanel {
    const CGFloat W = self.bounds.size.width;
    const CGFloat H = self.bounds.size.height;
    const CGFloat pw = std::min<CGFloat>(340, W - 40);
    const CGFloat ph = std::min<CGFloat>(500, H - 60);
    _panel.frame = CGRectMake((W - pw) * 0.5f, (H - ph) * 0.5f, pw, ph);
    _debugView.frame = CGRectMake(14, _debugView.frame.origin.y, pw - 28,
                                  ph - (_debugView.frame.origin.y + 60));
}

- (void)syncControls {
    esp::EspSettings s;
    {
        std::lock_guard<std::mutex> lk(_cfgMu);
        s = _settings;
    }
    _swEnable.on = s.enabled;
    _swSkeleton.on = s.drawSkeleton;
    _swBox.on = s.drawBox;
    _swDistance.on = s.drawDistance;
    _swSnapline.on = s.drawSnapline;
    _slDistance.value = s.maxDistance;
    _slDistanceLabel.text = [NSString stringWithFormat:@"最大距离 %.0f m", s.maxDistance];
}

- (void)applyControls {
    esp::EspSettings s;
    esp::Offsets o;
    {
        std::lock_guard<std::mutex> lk(_cfgMu);
        _settings.enabled = _swEnable.isOn;
        _settings.drawSkeleton = _swSkeleton.isOn;
        _settings.drawBox = _swBox.isOn;
        _settings.drawDistance = _swDistance.isOn;
        _settings.drawSnapline = _swSnapline.isOn;
        _settings.maxDistance = _slDistance.value;
        s = _settings;
        o = _offsets;
    }
    esp::SaveSettings(s, o);
    [self setNeedsDisplay];
}

- (void)onToggleChanged:(id)sender {
    (void)sender;
    [self applyControls];
}

- (void)onDistanceChanged:(UISlider *)slider {
    _slDistanceLabel.text = [NSString stringWithFormat:@"最大距离 %.0f m", slider.value];
    [self applyControls];
}

- (void)onCollapse {
    [self setMenuOpen:NO];
}

#pragma mark - 调试文本

- (void)refreshDebugText:(NSTimer *)timer {
    if (!_menuOpen) return;
    (void)timer;

    const esp::Snapshot snap = [self snapshotCopy];
    const esp::Diag &d = snap.diag;

    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"pid=%d base=0x%llX\n", d.pid, (unsigned long long)d.base];
    [s appendFormat:@"GObj=0x%llX GNames=0x%llX\n", (unsigned long long)d.gobjects,
                    (unsigned long long)d.gnames];
    [s appendFormat:@"GWorld=0x%llX\n", (unsigned long long)d.gworld];
    [s appendFormat:@"obj C+0x%X N+0x%X pool+0x%X hdr%d x%d\n", d.objClass, d.objName,
                    d.nameBlocks, d.nameHeader, d.nameScale];
    [s appendFormat:@"CTW=+0x%X bone=+0x%X objs=%u\n", d.compToWorld, d.boneArray, d.numObjects];
    [s appendFormat:@"actors=%d chars=%d fail=%d tick=%.2fms\n", d.actorCount, d.charCount,
                    d.boneFail, d.tickMs];
    [s appendFormat:@"cam=%.0f,%.0f,%.0f P%.1f Y%.1f FOV%.0f\n", snap.camera.location.x,
                    snap.camera.location.y, snap.camera.location.z, snap.camera.rotation.pitch,
                    snap.camera.rotation.yaw, snap.camera.fovHorizontalDeg];
    [s appendFormat:@"draw=%zu\n", snap.entities.size()];

    for (size_t i = 0; i < snap.entities.size() && i < 6; ++i) {
        const esp::Entity &e = snap.entities[i];
        [s appendFormat:@" #%zu %.0fm %s bones=%d\n", i, e.distance,
                        e.className.empty() ? "?" : e.className.c_str(), e.resolvedBones];
    }

    if (!snap.debugBones.empty()) {
        [s appendString:@"-- target bones --\n"];
        for (const esp::BoneDebugRow &row : snap.debugBones) {
            float sx = 0, sy = 0;
            const bool on = esp::WorldToScreen(snap.camera, row.world, sx, sy);
            [s appendFormat:@"%-8s %-16s idx%-3d %s\n", esp::BoneSlotName(row.slot),
                            row.name.empty() ? "-" : row.name.c_str(), row.index,
                            on ? [NSString stringWithFormat:@"%.0f,%.0f", sx, sy].UTF8String : "off"];
        }
    } else {
        [s appendString:@"(no bone detail)\n"];
    }

    _debugView.text = s;
    _statusLabel.text = _engineReady.load() ? @"已连接游戏 ✔" : @"未连接（先把游戏开起来）";
}

#pragma mark - 触摸（菜单开着才吃）

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!_menuOpen) return nil;
    return [super hitTest:point withEvent:event];
}

@end
