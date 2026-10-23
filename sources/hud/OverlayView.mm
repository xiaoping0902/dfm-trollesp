//
//  OverlayView.mm
//  DFM TrollESP —— Metal + ImGui 叠加层 + 采样线程
//

#import "OverlayView.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <notify.h>
#import <time.h>

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <chrono>
#include <mutex>
#include <string>
#include <thread>

#include "esp_core.hpp"
#include "draw.hpp"
#include "imgui.h"
#include "imgui_impl_metal.h"
#include "HudBridge.h"
#include "crashlog.h"

static const char *kReloadNotification = "com.dfm.trollesp.reload";


// ---------------------------------------------------------------------------
// ImGui 样式 / 字体
// ---------------------------------------------------------------------------

static void ESPApplyStyle(void) {
    ImGuiStyle &style = ImGui::GetStyle();
    ImGui::StyleColorsDark();

    style.WindowRounding    = 10.f;
    style.ChildRounding     = 6.f;
    style.FrameRounding     = 5.f;
    style.GrabRounding      = 4.f;
    style.PopupRounding     = 6.f;
    style.ScrollbarRounding = 6.f;
    style.WindowBorderSize  = 1.f;
    style.FrameBorderSize   = 0.f;
    style.WindowPadding     = ImVec2(12, 12);
    style.FramePadding      = ImVec2(8, 5);
    style.ItemSpacing       = ImVec2(8, 7);

    ImVec4 *c = style.Colors;
    c[ImGuiCol_WindowBg]       = ImVec4(0.06f, 0.07f, 0.08f, 0.95f);
    c[ImGuiCol_ChildBg]        = ImVec4(0.10f, 0.11f, 0.12f, 0.90f);
    c[ImGuiCol_FrameBg]        = ImVec4(0.16f, 0.17f, 0.19f, 1.00f);
    c[ImGuiCol_FrameBgHovered] = ImVec4(0.24f, 0.26f, 0.29f, 1.00f);
    c[ImGuiCol_Button]         = ImVec4(0.18f, 0.22f, 0.26f, 1.00f);
    c[ImGuiCol_ButtonHovered]  = ImVec4(0.25f, 0.42f, 0.36f, 1.00f);
    c[ImGuiCol_ButtonActive]   = ImVec4(0.30f, 0.55f, 0.42f, 1.00f);
    c[ImGuiCol_Header]         = ImVec4(0.18f, 0.24f, 0.22f, 1.00f);
    c[ImGuiCol_HeaderHovered]  = ImVec4(0.24f, 0.36f, 0.30f, 1.00f);
    c[ImGuiCol_CheckMark]      = ImVec4(0.35f, 1.00f, 0.55f, 1.00f);
    c[ImGuiCol_SliderGrab]     = ImVec4(0.35f, 0.80f, 0.55f, 1.00f);
    c[ImGuiCol_Text]           = ImVec4(0.94f, 0.96f, 0.96f, 1.00f);
    c[ImGuiCol_Separator]      = ImVec4(0.30f, 0.34f, 0.34f, 0.60f);
}

static ImFont *ESPLoadFont(void) {
    ImGuiIO &io = ImGui::GetIO();
    const char *candidates[] = {
        "/System/Library/Fonts/LanguageSupport/PingFang.ttc",
        "/System/Library/Fonts/Core/PingFang.ttc",
        "/System/Library/Fonts/LanguageSupport/Hiragino Sans GB.ttc",
        "/System/Library/Fonts/Cache/STHeiti-Light.ttc",
        "/System/Library/Fonts/Core/STHeiti-Light.ttc",
    };

    ImFontConfig cfg;
    cfg.FontNo = 0;
    cfg.OversampleH = 2;
    cfg.OversampleV = 1;
    cfg.PixelSnapH = true;

    for (const char *path : candidates) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:[NSString stringWithUTF8String:path]]) {
            continue;
        }
        ImFont *font = io.Fonts->AddFontFromFileTTF(path, 15.0f, &cfg,
                                                    io.Fonts->GetGlyphRangesChineseFull());
        if (font) return font;
    }
    io.Fonts->AddFontDefault();
    return io.Fonts->Fonts.empty() ? nullptr : io.Fonts->Fonts[0];
}

// ---------------------------------------------------------------------------

@implementation OverlayView {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;

    std::thread _worker;
    std::atomic<bool> _workerRunning;
    std::atomic<bool> _engineReady;
    std::atomic<bool> _reinitNeeded;
    std::atomic<bool> _menuOpen;
    std::atomic<bool> _exiting;
    bool _imguiReady;

    std::mutex _cfgMu;
    esp::EspSettings _settings;
    esp::Offsets _offsets;

    std::mutex _logMu;
    std::string _bootLog;
    std::string _probe;

    esp::Engine _engine;
    esp::Snapshot _snap;

    esp::DebugOptions _debug;
    int _debugTarget;
    bool _previewMode;
    bool _autoOpened;
    std::atomic<bool> _userTouched;

    bool _ballDragging;
    bool _ballMoved;
    CGPoint _ballDragStart;
    CGPoint _ballDragOffset;

    double _lastFrameTime;
    int _notifyToken;
}

- (instancetype)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame preview:NO];
}

- (instancetype)initWithFrame:(CGRect)frame preview:(BOOL)preview {
    // 注意：iOS 上只有“默认设备”这一块 GPU，MTLCopyAllDevices() 在 iOS 不存在/会崩（实测 SIGSEGV）。
    // HUD 是 root 守护进程，默认设备有可能这时候还拿不到，由上层延迟重试。
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        ESPLogStep("metal: MTLCreateSystemDefaultDevice() 返回 nil（交由上层重试/兜底）");
        return nil;
    }
    ESPLogStep("metal: device ok (%s)", [[_device name] UTF8String] ?: "?");

    if (self = [super initWithFrame:frame device:_device]) {
        _workerRunning = false;
        _engineReady = false;
        _reinitNeeded = false;
        _menuOpen = preview;          // 预览模式直接开菜单，省得找不到入口
        _exiting = false;
        _lastFrameTime = 0.0;
        _notifyToken = -1;
        _previewMode = preview;
        _debugTarget = 0;
        _autoOpened = false;
        _userTouched = false;
        _debug.windowOpen = preview;
        _debug.boneLabels = preview;

        _queue = [_device newCommandQueue];

        self.delegate = self;
        self.preferredFramesPerSecond = 120;
        self.clearColor = MTLClearColorMake(0, 0, 0, 0);
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
        self.layer.opaque = NO;
        self.userInteractionEnabled = YES;
        self.multipleTouchEnabled = YES;
        self.autoResizeDrawable = YES;
        self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;

        // 默认设置
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

        ESPLogStep("overlay: init begin (preview=%d)", (int)preview);
        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ESPLogStep("overlay: ImGui ctx=%p", (void *)ImGui::GetCurrentContext());
        ImGuiIO &io = ImGui::GetIO();
        io.IniFilename = nullptr;
        io.LogFilename = nullptr;
        io.BackendPlatformName = "DFMTrollESP";
        ESPApplyStyle();
        ImFont *f = ESPLoadFont();
        ESPLogStep("overlay: font=%p fonts=%d", (void *)f, io.Fonts ? io.Fonts->Fonts.Size : -1);
        ImGui_ImplMetal_Init(_device);
        _imguiReady = (ImGui::GetCurrentContext() != nullptr && io.Fonts != nullptr &&
                       io.Fonts->Fonts.Size > 0);
        ESPLogStep("overlay: ready=%d", (int)_imguiReady);

        ESPHudSetActiveOverlay(self);

        __weak OverlayView *weakSelf = self;
        notify_register_dispatch(kReloadNotification, &_notifyToken, dispatch_get_main_queue(),
                                 ^(int token) {
                                     (void)token;
                                     [weakSelf reloadSettingsFromDisk];
                                 });
    }
    return self;
}

- (void)dealloc {
    [self stopEngine];
    if (_notifyToken >= 0) {
        notify_cancel(_notifyToken);
        _notifyToken = -1;
    }
    ESPHudClearActiveOverlay(self);
    // 只有真初始化过 Metal 后端才 Shutdown：拿不到设备时 init 会提前 return nil，
    // 这时无条件 Shutdown 会崩在 ImGui_ImplMetal_Shutdown（真机已确认 SIGSEGV）。
    if (_imguiReady) {
        ImGui_ImplMetal_Shutdown();
    }
    if (ImGui::GetCurrentContext()) ImGui::DestroyContext();
}

#pragma mark - 菜单

- (BOOL)menuVisible {
    // 调试窗口开着也算“占用触摸”，否则点不到它
    return _menuOpen.load() || _debug.windowOpen;
}

- (void)setMenuOpen:(BOOL)open {
    _menuOpen = open;
    if (open) {
        [self reloadSettingsFromDisk];
    }
}

- (void)setDebugWindowOpen:(BOOL)open {
    _debug.windowOpen = open;
    if (open) {
        _menuOpen = true;
    }
}

- (void)toggleMenu {
    const bool next = !_menuOpen.load();
    _menuOpen = next;
    if (next) {
        [self reloadSettingsFromDisk];
    }
}

#pragma mark - 悬浮球

- (BOOL)handleBallTouchAt:(CGPoint)point phase:(int)phase {
    if (_previewMode) return NO;
    if ([self menuVisible]) return NO;          // 菜单开着走正常触摸链路

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
    const CGFloat dist2 = dx * dx + dy * dy;
    const CGFloat hitR = r + 14.0;              // 手指比球粗，给点余量

    if (phase == 0) {                            // 按下
        if (dist2 > hitR * hitR) return NO;
        _ballDragging = YES;
        _ballMoved = NO;
        _ballDragStart = point;
        _ballDragOffset = CGPointMake(center.x - point.x, center.y - point.y);
        _userTouched = true;
        return YES;
    }

    if (!_ballDragging) return NO;

    if (phase == 1) {                            // 移动
        if (fabs(point.x - _ballDragStart.x) > 8 || fabs(point.y - _ballDragStart.y) > 8) {
            _ballMoved = YES;
        }
        CGFloat nx = point.x + _ballDragOffset.x;
        CGFloat ny = point.y + _ballDragOffset.y;
        nx = fmax(r + 4, fmin(W - r - 4, nx));
        ny = fmax(r + 4, fmin(H - r - 4, ny));

        std::lock_guard<std::mutex> lk(_cfgMu);
        _settings.ballX = (float)(nx / W);
        _settings.ballY = (float)(ny / H);
        return YES;
    }

    // phase == 2 抬起
    _ballDragging = NO;
    if (!_ballMoved) {
        // 单击球 -> 展开菜单（顺带把调试窗口也打开，方便看数据）
        _menuOpen = true;
        _debug.windowOpen = true;
        [self reloadSettingsFromDisk];
    } else {
        esp::EspSettings cur;
        esp::Offsets off;
        {
            std::lock_guard<std::mutex> lk(_cfgMu);
            cur = _settings;
            off = _offsets;
        }
        esp::SaveSettings(cur, off);           // 记住球的位置
    }
    return YES;
}

static bool ESPOffsetsDiffer(const esp::Offsets &a, const esp::Offsets &b) {
    return a.rvaGObjects != b.rvaGObjects || a.rvaGNames != b.rvaGNames ||
           a.rvaGWorld != b.rvaGWorld || a.characterMesh != b.characterMesh ||
           a.meshBoneTransforms != b.meshBoneTransforms ||
           a.sceneComponentToWorld != b.sceneComponentToWorld;
}

- (void)reloadSettingsFromDisk {
    esp::EspSettings s;
    esp::Offsets o;
    esp::EspSettings oldSettings;
    esp::Offsets oldOffsets;
    {
        std::lock_guard<std::mutex> lk(_cfgMu);
        oldSettings = _settings;
        oldOffsets = _offsets;
        s = _settings;
        o = _offsets;
    }
    if (!esp::LoadSettings(s, o)) return;

    const bool needReinit = ESPOffsetsDiffer(oldOffsets, o) ||
                            oldSettings.moduleName != s.moduleName;

    {
        std::lock_guard<std::mutex> lk(_cfgMu);
        _settings = s;
        _offsets = o;
    }
    if (needReinit) _reinitNeeded = true;
}

#pragma mark - 采样线程

- (void)startEngine {
    if (_workerRunning.exchange(true)) return;
    _reinitNeeded = true;

    // 用 __unsafe_unretained 捕获，避免 self 被线程一直强引用（dealloc 里会 join）
    __unsafe_unretained OverlayView *rawSelf = self;
    _worker = std::thread([rawSelf]() {
        [rawSelf workerLoop];
    });

    // 第一次进游戏先自动把菜单/调试窗口弹出来，避免"找不到 UI 窗口"
    if (!_previewMode && !_autoOpened) {
        _autoOpened = true;
        __weak OverlayView *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           OverlayView *strongSelf = weakSelf;
                           if (!strongSelf) return;
                           strongSelf->_menuOpen = true;
                           strongSelf->_debug.windowOpen = true;
                       });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           OverlayView *strongSelf = weakSelf;
                           if (!strongSelf) return;
                           // 45 秒内没人碰过就自动收起，把操作权还给游戏
                           if (!strongSelf->_userTouched.load()) {
                               strongSelf->_menuOpen = false;
                               strongSelf->_debug.windowOpen = false;
                           }
                       });
    }
}

- (void)stopEngine {
    _workerRunning = false;
    if (_worker.joinable()) {
        _worker.join();
    }
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
    if (!ok) {
        _engine.Shutdown();
    }
}

- (void)workerLoop {
    int tickCounter = 0;

    while (_workerRunning.load()) {
        @autoreleasepool {
            if (_reinitNeeded.exchange(false)) {
                [self bootstrapEngine];
            }

            if (!_engineReady.load()) {
                // 游戏没开 / 还没进对局，隔一会儿重试一次
                for (int i = 0; i < 25 && _workerRunning.load(); ++i) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(100));
                }
                continue;
            }

            _engine.Tick();

            if (++tickCounter % 30 == 0) {
                std::string probe = _engine.ProbeReport();
                std::lock_guard<std::mutex> lk(_logMu);
                _probe = std::move(probe);
            }

            int hz = 60;
            {
                std::lock_guard<std::mutex> lk(_cfgMu);
                hz = _settings.sampleHz;
            }
            hz = std::max(15, std::min(144, hz));
            std::this_thread::sleep_for(std::chrono::milliseconds(1000 / hz));
        }
    }
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    // 每帧都会用 bounds 重设，这里不需要做事
    (void)view;
    (void)size;
}

- (void)drawInMTKView:(MTKView *)view {
    if (_exiting.load()) return;

    const CGSize size = self.bounds.size;
    const CGFloat scale = self.contentScaleFactor > 0 ? self.contentScaleFactor
                                                      : (CGFloat)UIScreen.mainScreen.nativeScale;
    if (size.width < 2 || size.height < 2) return;

    if (!_imguiReady || ImGui::GetCurrentContext() == nullptr) return;
    static bool sFirstFrameLogged = false;
    if (!sFirstFrameLogged) {
        sFirstFrameLogged = true;
        ESPLogStep("overlay: first frame in");
    }
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)size.width, (float)size.height);
    io.DisplayFramebufferScale = ImVec2((float)scale, (float)scale);
    esp::SetViewportSize((int)size.width, (int)size.height);

    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    const double now = (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
    float dt = _lastFrameTime > 0.0 ? (float)(now - _lastFrameTime) : (1.f / 120.f);
    _lastFrameTime = now;
    io.DeltaTime = std::max(0.001f, std::min(dt, 0.25f));

    id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
    MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
    if (!rpd) {
        [commandBuffer commit];
        return;
    }

    ImGui_ImplMetal_NewFrame(rpd);
    ImGui::NewFrame();

    _snap = _engine.CopySnapshot();

    esp::EspSettings settings;
    esp::Offsets offsets;
    {
        std::lock_guard<std::mutex> lk(_cfgMu);
        settings = _settings;
        offsets = _offsets;
    }

    if (settings.enabled && _snap.camera.valid) {
        esp::DrawESP(ImGui::GetBackgroundDrawList(), _snap, settings, io.DisplaySize);
    }

    // 悬浮球：菜单关着的时候常驻，点一下展开
    if (![self menuVisible] && settings.showBall) {
        ImDrawList *dl = ImGui::GetBackgroundDrawList();
        const ImVec2 c(settings.ballX * io.DisplaySize.x, settings.ballY * io.DisplaySize.y);
        const float r = settings.ballRadius;
        dl->AddCircleFilled(ImVec2(c.x, c.y + 1.5f), r + 1.f, IM_COL32(0, 0, 0, 80));
        dl->AddCircleFilled(c, r, IM_COL32(24, 140, 88, 205));
        dl->AddCircle(c, r, IM_COL32(130, 255, 180, 235), 0, 2.0f);
        const char *label = "ESP";
        const ImVec2 ts = ImGui::CalcTextSize(label);
        dl->AddText(ImVec2(c.x - ts.x * 0.5f, c.y - ts.y * 0.5f), IM_COL32(255, 255, 255, 240), label);
    }

    // 调试数据：窗口开着 / 需要标号或射线时才让采样线程填骨骼明细
    const bool needDebugData =
        _debug.windowOpen || _debug.boneLabels || _debug.boneRays;
    _engine.SetDebugTarget(_debugTarget, needDebugData);

    if (_menuOpen.load()) {
        std::string bootLog, probe;
        {
            std::lock_guard<std::mutex> lk(_logMu);
            bootLog = _bootLog;
            probe = _probe;
        }

        esp::MenuResult result = esp::DrawMenu(settings, offsets, _snap, bootLog, probe,
                                               _engineReady.load(), _engine.TargetPid(),
                                               _engine.ModuleBase(), _debug);

        {
            std::lock_guard<std::mutex> lk(_cfgMu);
            _settings = settings;
            _offsets = offsets;
        }

        if (result.save) {
            esp::SaveSettings(settings, offsets);
        }
        if (result.reinit) {
            _reinitNeeded = true;
        }
        if (result.close || result.collapse) {
            _menuOpen = false;
            _debug.windowOpen = false;
        }
        if (result.exitApp) {
            _exiting = true;
            [self stopEngine];
            exit(0);
        }
    }

    // 调试窗口（独立于菜单：菜单关了但调试窗口还开着也要画）
    esp::DrawDebugWindow(_snap, _debug, _debugTarget);
    esp::DrawDebugOverlay(ImGui::GetBackgroundDrawList(), _snap, _debug, io.DisplaySize,
                          _debugTarget);

    ImGui::Render();
    ImDrawData *drawData = ImGui::GetDrawData();

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    ImGui_ImplMetal_RenderDrawData(drawData, commandBuffer, encoder);
    [encoder endEncoding];
    [commandBuffer presentDrawable:view.currentDrawable];
    [commandBuffer commit];
}

#pragma mark - 触摸 -> ImGui

- (void)feedTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)event {
    if (![self menuVisible]) return;    // 菜单/调试窗口都关着就不吃输入
    _userTouched = true;

    UITouch *any = touches.anyObject ?: event.allTouches.anyObject;
    if (!any) return;

    const CGPoint p = [any locationInView:self];
    ImGuiIO &io = ImGui::GetIO();
    io.AddMousePosEvent((float)p.x, (float)p.y);

    bool down = false;
    for (UITouch *t in event.allTouches) {
        if (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled) {
            down = true;
            break;
        }
    }
    io.AddMouseButtonEvent(0, down);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self feedTouches:touches event:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self feedTouches:touches event:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self feedTouches:touches event:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self feedTouches:touches event:event];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (![self menuVisible]) return nil;
    return [super hitTest:point withEvent:event];
}

@end
