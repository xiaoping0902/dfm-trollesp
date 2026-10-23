# DFM TrollESP — 三角洲行动 UE4 骨骼 ESP（TrollStore 直装）

> 目标：**不越狱、不改游戏包、不注入 dylib**，用 TrollStore 装一个 App，切回游戏就能看到人物骨骼透视。
> 实现路线：`root 权限 HUD 进程` + `task_for_pid 只读内存` + `Metal/ImGui 跨 App 悬浮窗`。
> 核心代码是通用 UE4 模板：偏移可配置、关键结构运行时自检，换游戏只改 `Offsets`。

---

## 0. 先看结论

| 你问的 | 答案 |
|---|---|
| 巨魔装上就能用？ | 能。打出来的 `DFMTrollESP.tipa` 用 TrollStore 安装，点开是配置界面，点「启动绘制」后 HUD 以 root 常驻 |
| 能画人物骨骼？ | 能，骨骼是按**骨骼名字**解析的（不是写死下标），换皮肤/换骨架都能画 |
| 要不要越狱？ | 不要。读内存走 `task_for_pid`，权限来自 TrollStore 的 CoreTrust 任意 entitlement 签名 |
| 会不会改游戏文件？ | 不会。纯外部只读，不 hook、不写内存、不动 IPA |
| 换版本怎么办？ | 重新 dump 一份 SDK，改 `sources/core/esp_core.hpp` 里 `Offsets` 的几个 RVA/字段偏移即可 |

---

## 1. 工作方式（为什么这套能跑起来）

```
┌──────────────────────────────┐        posix_spawn(-hud)         ┌─────────────────────────────┐
│ DFMTrollESP.app（普通 App）   │ ───────────────────────────────► │ 同一个二进制，persona 99      │
│  - 开关 / 设置 / 偏移编辑      │        persona uid=0 → root      │ uid=0（root）HUD 进程         │
└──────────────────────────────┘                                  │  - task_for_pid(游戏) 读内存   │
                                                                  │  - Metal + ImGui 全屏叠加层    │
                                                                  │  - 通过 accessibility window   │
                                                                  │    hosting 注册给 SpringBoard  │
                                                                  └──────────────┬──────────────┘
                                                                                 │ 盖在游戏上
                                                                  ┌──────────────▼──────────────┐
                                                                  │ DeltaForceClient（游戏进程）  │
                                                                  └─────────────────────────────┘
```

三个关键点，缺一不可：

1. **root**：HUD 必须 root，否则切后台/解锁时会被 SpringBoard 杀掉。靠 `posix_spawnattr_set_persona_np(99, OVERRIDE) + uid/gid 0`，需要 `com.apple.private.persona-mgmt`。
2. **task_for_pid-allow**：读别的进程内存必须有这个 entitlement，普通签名拿不到，TrollStore 能签。
3. **accessibility-window-hosting**：`SBSAccessibilityWindowHostingController registerWindowWithContextID:atLevel:` 把窗口交给 SpringBoard 托管，才能悬浮在**别的 App**（游戏）上。触摸靠 `BKSHIDEventRegisterEventCallback` 全局 HID 回调 + 合成 `UITouch` 喂进 ImGui。

这三招都是 MIT 的 [TrollSpeed](https://github.com/Lessica/TrollSpeed) 验证过的同一套机制，本工程只是把「显示网速」换成了「画骨骼」。

---

## 2. UE4 读取链路

和 Reveal / Dolphins / Farlight 那套一模一样，只是偏移换成本游戏的：

```
GWorld(UWorld*)
 └─ +0x0F8 PersistentLevel (ULevel*)
     └─ +0x098 Actors (TArray<AActor*>)
         └─ actor + 0x008 Class (UClass*)   → 类名匹配（沿 SuperStruct 往上找）
             └─ actor + 0x3D0 Mesh (USkeletalMeshComponent*)
                 ├─ +ComponentToWorld (FTransform, 非 UPROPERTY → 运行时探测)
                 └─ +0x0A18 CachedComponentSpaceTransforms (TArray<FTransform>)
                      └─ 每 0x30 字节一根骨骼 → TransformPosition(cw, bone.translation) = 世界坐标
```

摄像机：

```
PlayerController(本地)
 ├─ +0x3D8 ControlRotation (FRotator, 明文)
 └─ +0x408 PlayerCameraManager
      └─ +0x3E0 CameraCache → +0x10 POV → +0x1C FOV (float, 明文)
```

然后 `WorldToScreen` 用「控制器旋转 + 眼睛位置 + 水平 FOV + 宽高比」投影，
方框 / 骨骼线 / 距离 / 准心线全部用 ImGui `AddLine/AddRect` 画在背景层。

### 骨骼为什么不用写死索引

`USkeletalMesh` 里存着 `FReferenceSkeleton`（骨骼名数组 + 父索引）。程序启动时：

1. 把 `USkeletalMesh` 对象前 0x2000 字节读回来；
2. 按 8 字节步长扫 `TArray<FMeshBoneInfo{ FName Name; int32 ParentIndex }>`（步长 0xC）；
3. 用 GNames 把每个 `FName` 解成字符串，校验「父索引 < 自身索引」且名字是可打印 ASCII；
4. 名字映射到语义槽位（`pelvis / spine / neck / head / clavicle / upperarm / forearm / hand / thigh / calf / foot`，左右靠 `_l/_r/Left/Right/L/R` 判断）；
5. 结果按 `SkeletalMesh` 指针缓存，换皮肤只多一次解析。

所以：
- UE4 官方的 `head / neck_01 / upperarm_l` 命名 → 能画；
- 腾讯/国产常见的 3ds Max Biped 命名 `Bip001 Pelvis / Bip001 L Thigh / Bip001 Head` → 也能画。

---

## 3. 目录结构

```
dfm_troll_esp/
├── Makefile                     # Theos：编 App + 自动打 .tipa
├── control
├── supports/entitlements.plist   # 全套 TrollStore 权限（关键文件）
├── Resources/                    # 图标
├── headers/                      # 预留
├── imgui/                        # ImGui 1.87 WIP + Metal 后端（已内置）
├── tools/package_tipa.sh         # ldid 重签 + 写 Info.plist + zip 成 tipa
├── .github/workflows/build.yml   # 云端 macOS 一键出包
└── sources/
    ├── core/
    │   ├── esp_core.hpp          # 全部结构体/偏移/接口（**换游戏主要改这里**）
    │   ├── memory.mm             # task_for_pid / mach_vm_read / 找 pid、找模块基址
    │   ├── ue4.mm                # GObjects/GNames/GWorld、对象遍历、骨骼解析、摄像机
    │   ├── draw.mm               # ESP 绘制 + ImGui 菜单
    │   ├── draw.hpp
    │   └── config.mm             # 设置持久化（plist + notify）
    ├── hud/
    │   ├── main.mm               # 一个二进制两种身份（App / -hud）
    │   ├── HudControl.mm         # posix_spawn 提权拉 HUD
    │   ├── HudApp.mm             # HUD 进程启动、跨 App 窗口、HID 触摸
    │   ├── OverlayView.mm        # MTKView + ImGui + 采样线程
    │   ├── TouchInject.mm        # HID → 合成 UITouch
    │   └── PrivateApi.mm         # 私有符号 dlsym（不依赖私有框架 .tbd）
    └── app/AppDelegate.mm        # 主 App 界面（开关、状态、启动/停止）
```

---

## 4. 编译

### 4.1 本地 macOS（推荐）

```bash
# 依赖
brew install ldid xz
export THEOS=$HOME/theos
git clone --recursive https://github.com/theos/theos.git "$THEOS"
# 放一份 iOS SDK（16.5 足够）
# $THEOS/sdks/iPhoneOS16.5.sdk

cd dfm_troll_esp
make package FINALPACKAGE=1
# 产物：packages/DFMTrollESP.tipa
```

`Makefile` 干的事：
1. Theos 编出 `DFMTrollESP.app`；
2. `tools/package_tipa.sh` 把 App 拷贝成 `Payload/DFMTrollESP.app`；
3. 写一份固定 `Info.plist`（`MinimumOSVersion 15.0`、`CADisableMinimumFrameDurationOnPhone`、图标…）；
4. `ldid -S supports/entitlements.plist` 用我们的 entitlements **重签**；
5. `zip` 成 `.tipa`。

> 一定要用 `ldid` 签，不要用 `codesign`：TrollStore 走 CoreTrust，`ldid` 才能把 `task_for_pid-allow` 这类权限原样写进签名。

### 4.2 云端（没有 Mac，推荐）

跟你 `iOS打包演示` 那套一样，用 **GitHub 的 macOS 云机器**：

```
仓库：https://github.com/xiaoping0902/dfm-trollesp   （public，Actions 免费额度）
Actions → build-tipa → 最新一次 run → Artifacts → DFMTrollESP-tipa
```

工程里已经有：
- `project.yml`（XcodeGen 描述文件，不用手维护 `.xcodeproj`）
- `.github/workflows/build.yml`（`macos-15` + Xcode 16 → xcodebuild 无签名编译 → `ldid` 签 entitlements → 打 `.tipa` → 上传 artifact）
- `tools/package_from_xcode.sh`（本地也能用：`sh tools/package_from_xcode.sh <xxx.app> out.tipa`）

改代码后只要 `git push`，云端自动重编，2~3 分钟出新 `.tipa`。

> 踩过的两个坑（已写进代码）：
> 1. iPhoneOS SDK **没有 `libproc.h`**，所以进程枚举用 `sysctl(KERN_PROC_ALL)`、镜像基址用
>    `vm_region_recurse_64` + 读 Mach-O 头判 `MH_EXECUTE`；
> 2. iPhoneOS SDK 的 `<mach/mach_vm.h>` 是"unsupported"桩，读内存要用 `vm_read_overwrite`。
> 另外 XcodeGen 2.46 生成的是 objectVersion 77，**必须用 Xcode 16（macos-15 runner）** 才打得开。

---

## 5. 安装 & 使用

1. **装**：TrollStore → `+` → 选 `DFMTrollESP.tipa` → Install。
2. **开游戏**：正常打开三角洲，进到大厅/对局（让游戏进程活起来）。
3. **启动绘制**：切回本 App → 点「启动绘制 Start」。HUD 进程以 root 常驻。
4. **回游戏**：屏幕上应该已经出现人物骨骼。
5. **菜单**：**三指双击** 开/关（游戏也会收到这次点击，属于正常现象）。
6. **调参**：菜单里能改颜色、线宽、最大距离、采样率；「偏移 / 换游戏适配」里能改 RVA 和字段偏移。
7. **停**：App 里点「停止绘制」，或菜单里「退出 HUD」。

设置存在 `/var/mobile/Library/Preferences/com.dfm.trollesp.plist`，App 和 HUD 两个进程靠它 + `notify_post` 同步。

### 5.0 悬浮球（球 ⇄ 菜单）

- 菜单收起后，屏幕上常驻一个绿球（写着 ESP），**点一下球** → 菜单 + 调试窗口展开；
  菜单里点「● 收起成球 Collapse」或「关闭菜单 Close」→ 又缩回球。
- 球可以**拖动**（位置会记进 plist，下次还在那儿）；大小在菜单里「球大小」调，开关是「悬浮球 Ball」。
- 球是靠 HID 回调自己算坐标的：菜单关着的时候窗口仍然全穿透（_ignoresHitTest = YES），
  只有点在球半径内才被我们吃掉，所以走路/开镜不受影响。
  代价：点球那一下游戏也会收到一次真实触摸（iOS 层面拦不住），菜单一开就正常了。
- 三指双击 仍然可以开/关菜单，两条路都留着。
### 5.1 先点一次「诊断 Diagnose」

第一次用建议先别开 HUD：在 App 里点 **诊断 Diagnose**，它会在 App 进程里跑一遍完整链路
（找 pid → `task_for_pid` → 解 GNames → 解 GObjects → 找 GWorld → 采样 3 秒），日志直接贴在下面那个黑框里：

```
目标进程: DeltaForceClient pid=12345
模块基址: 0x1048C0000
GNames: FNamePool blocks@+0x10
GObjects: NumElements=114784 (Objects@+0x20)
UObject 布局: Class+0x8 Name+0x1C Outer+0x10 | FName blocks+0x10 hdr=2 scale=2
GWorld: ok (rvaGWorld)
ComponentToWorld: +0x1B0（score 12）
-------- probe --------
objects=114784 actors=8421
-------- snapshot --------
ok=1 actors=8421 chars=27 boneFail=0 draw=27 cam=1
```

`draw=27 cam=1` 说明整条链路通了；哪一行报错就照第 8 节排错表处理。

### 5.2 调试窗口（骨骼表 / 射线 / 引擎状态）

**打开方式有两条：**

1. **游戏里（HUD）**：三指双击 → 菜单 → 勾上「调试窗口 Debug」。
   HUD 起来后 **3 秒会自动把菜单 + 调试窗口弹出来**，45 秒内没人碰就自动收起，不会一直挡着游戏。
2. **App 里预览**：主界面点「调试预览 Preview」，直接在全屏窗口里跑同一套 ImGui（菜单和调试窗口默认打开），
   不用开 HUD、不用悬浮窗。数据是真的（App 进程自己 `task_for_pid` 读游戏）。

**调试窗口里有什么：**

| 区块 | 内容 |
|---|---|
| 引擎 / 连接 | pid、模块基址、GObjects、GNames、GWorld、UObject 布局（Class/Name 偏移）、FName 池（blocks/hdr/scale）、ComponentToWorld 偏移、骨骼数组偏移、UObject 总数 |
| 采样 / 摄像机 | Actor 数、角色数、骨骼采样失败数、**单次 Tick 耗时(ms)**、相机位置/旋转/FOV/视口 |
| 调试目标 | 下拉选第几个角色：actor 地址、mesh 地址、类名、SkeletalMesh 地址、骨骼总数/已映射数 |
| 骨骼表 | 每根语义骨骼：**槽位名 / 真实骨名 / 骨骼下标 idx / 世界 X,Y,Z / 屏幕 X,Y / depth** |
| 骨架名单 | 整套骨骼名（按 index 顺序），一眼看出是 `Bip001 L Thigh` 还是 `upperarm_l` |
| 叠加绘制 | 「骨骼标号」屏幕上每根骨骼打 `Head(6)` 这种标签；「骨骼射线」屏幕中心到每根骨骼的视线；「准心射线」相机前向 40m 的 3D 射线 |

调骨骼的典型用法：
1. 看「骨骼表」右侧 depth 是不是正数、屏幕 XY 是否落在画面内 → 判断 W2C 对不对；
2. 屏幕 XY 对了但形状歪 → 看「骨骼数组偏移」是不是 `0xA18`（试 `0xA08`）；
3. 世界坐标在飘 / 整块糊在一起 → 看「ComponentToWorld」选的候选对不对（换 `+0x1B0` / `+0x1A0` 试）；
4. 骨名对不上 → 看「骨架名单」，在 `SlotFromBoneName()` 里补关键字。

### 5.3 注入版（可选，兜底）

```bash
make -f Makefile.dylib
# 产物 .theos/obj/dfmesp.dylib
```
把它丢给 **TrollFools** 注进 `DeltaForceClient`：内存访问变成"读自己"，逻辑一行不改
（核心代码用 `-DESP_INTERNAL` 编译，`FindPid`/`FindMainImageBase`/`Reader::Attach` 自动走进程内分支）。

---

## 6. 本游戏的偏移（已内置默认值）

来自 `DeltaForce-iOS-SDK`（MobileDumper-7 实机 dump，1.201.37117，UE4.27 定制版）：

| 符号 | RVA（相对 `DeltaForceClient` `__TEXT` 起点） |
|---|---|
| `GObjects` | `0x1177A17B8` |
| `GNames` | `0x1173776C0` |
| `GWorld` | `0x1178B44E0` |
| `GEngine` | `0x1178B1C98` |

字段偏移（CppSDK 里 `// 0x....` 的原始值）：

| 结构 | 成员 | 偏移 |
|---|---|---|
| UObject | Class / Name / Outer | `+0x08` / `+0x1C` / `+0x10`（**非标准布局**，代码里还会自动探测） |
| UWorld | PersistentLevel / Levels / OwningGameInstance | `0x0F8` / `0x158` / `0x190` |
| ULevel | Actors | `0x098` |
| AActor | RootComponent | `0x180` |
| ACHARACTER | Mesh | `0x3D0` |
| APlayerController | AcknowledgedPawn / PlayerCameraManager / ControlRotation | `0x3F0` / `0x408` / `0x3D8` |
| APlayerCameraManager | CameraCache / DefaultFOV | `0x3E0` / `0x388` |
| FMinimalViewInfo | Rotation / FOV | `0x10` / `0x1C`（相对 POV） |
| USkinnedMeshComponent | SkeletalMesh | `0x718` |
| USkeletalMeshComponent | CachedComponentSpaceTransforms | `0x0A18` |
| USkeletalMeshComponent | CachedBoneSpaceTransforms | `0x0A08`（备选） |
| FTransform | Rotation(16) + Translation(12) + Scale(12) + pad | 总长 `0x30` |

> **注意**：`USceneComponent::ComponentToWorld` 在 UE4.27 不是 UPROPERTY，Dumper-7 导不出来，所以本工程做了**运行时打分探测**：在 `0x150~0x260` 每 0x10 步长找 FTransform，用「四元数模长≈1 + 缩放≈1 + 与 `CachedWorldSpaceBounds.Origin` 距离」打分，选最像的。菜单日志里会打印实际选中值，稳定后可以手填到「ComponentToWorld」框里固定下来。

---

## 7. 换游戏 / 换版本怎么改

1. 用 `MobileDumper-7`（或 PC 端 `UEDumper`）对新版本/新游戏 dump 一份 CppSDK；
2. 打开 `SDK/Basic.hpp` 拿 `GObjects / GNames / GWorld` 的 RVA；
3. 在 CppSDK 里搜这几个类的 `// 0x...`：
   - `UWorld`（PersistentLevel / Levels / OwningGameInstance）
   - `ULevel`（Actors）
   - 角色类（`Mesh` 字段；本游戏是 `ACHARACTER+0x3D0`）
   - `APlayerController`（AcknowledgedPawn / PlayerCameraManager / ControlRotation）
   - `APlayerCameraManager`（CameraCache）
   - `USkeletalMeshComponent`（`TArray<FTransform>` 那个数组，一般叫 `CachedComponentSpaceTransforms` 或 `SpaceBases`）
4. 改 `sources/core/esp_core.hpp` 的 `Offsets` 默认值（或直接在 App 的 plist / 游戏内菜单里改）；
5. 改 `characterClassIncludes`：把角色类名丢进去（也能沿 `SuperStruct` 匹配父类，所以填基类就行）；
6. 如果 `UObject` 是标准布局（Class@0x10、Name@0x18），不用改：`ResolveObjectLayout()` 会把 5 种布局 × FName 池 3 种参数全试一遍，用「对象名 == Object/CoreUObject」交叉验证挑对的那个。

**骨骼不用改**——名字匹配是通用的。只有当骨架是特殊命名（比如 `j_Head`、`Bip01 Head`）时才需要补规则：改 `SlotFromBoneName()` 里的关键字即可（已经兼容 `Bip001 L Thigh`、`upperarm_l`、`LeftArm` 这些写法）。

---

## 8. 排错表

| 现象 | 原因 / 处理 |
|---|---|
| 菜单显示「找不到进程」 | 游戏没开或没进对局；模块名对不上 → 改「主程序名」（默认 `DeltaForceClient`） |
| `task_for_pid 失败 (5)` | 权限没生效：确认是 TrollStore 装的（不是自签 sideload）、`task_for_pid-allow` 在签名里（`ldid -e` 能看到）、HUD 是 root（`ps -ef | grep DFMTrollESP` 看用户） |
| `task_for_pid 失败 (mac 5 / KERN_FAILURE)` | 游戏自己 `PT_DENY_ATTACH` 拒调试（ACE 常见）。先试几次；仍失败就走第 9 节备选方案 |
| `GNames: 没找到 "None" 锚点` | `rvaGNames` 过期（游戏更新了），重新 dump |
| `GObjects: 布局不匹配` | `rvaGObjects` 过期，同上 |
| 有 Actor、角色数 0 | `characterClassIncludes` 没命中 → 在菜单日志里看类名，补关键字 |
| 角色数正常但画不出来 | 看 `bonesFailures`：如果全是失败，说明 `ComponentToWorld` 没探到（大厅没角色）或骨骼数组偏移不对（试 `0xA08`） |
| 骨骼出来了但位置偏 / 抖动 | `ComponentToWorld` 选错候选，菜单里手填正确值 |
| 窗口不显示 | `SBSAccessibilityWindowHostingController` 注册失败（看 Console 日志 `[esp] window hosting registered`）；某些系统版本需要把 `windowLevel` 调低到 `10000000` |
| 屏幕转了但画面没转 | HUD 旋转方向反了：`HudApp.mm` 里 `LandscapeLeft/Right` 的 `±M_PI_2` 对调 |
| 菜单点不动 | HID → 合成触摸这条链失败（`[esp]` 日志 + `AccessibilityUtilities` 是否加载）；兜底：在 App 里改开关（App 写 plist → HUD 收 notify 重载） |

---

## 8.4 HUD 没层 / 秒退的真实原因（实测）

iPad14,4 / iPadOS 16.1 上实测到两件硬事实：

1. **HUD 是 root 守护进程，`MTLCreateSystemDefaultDevice()` 返回 nil**。
   ```
   frida: Module.load(Metal.framework) → MTLCreateSystemDefaultDevice() -> 0x0
   ```
   所以 ImGui + Metal 这条路在 **HUD 进程里根本走不通**（不是时序问题，重试也没用）。

2. 之前那句"兜底" `MTLCopyAllDevices()` **在 iOS 上会直接 SIGSEGV**（Chromium 的 iOS 移植也注明
   “Do not call MTLCopyAllDevices as there is only the default system device on iOS”），
   于是窗口还没建就崩了 → 表现就是"UI 没有那一层"。

对应修法：

- 删掉 `MTLCopyAllDevices`；
- 悬浮层改成**窗口上屏后再建**，Metal 拿不到就重试 4 次（0.8s 间隔）；
- 仍然拿不到 → 自动切 **`ESPFallbackOverlay`**：CoreGraphics 画骨骼/方框/距离 + UIKit 菜单 + 等宽
  调试文本（pid/基址/偏移/Actor/Tick/骨骼表），**不依赖 Metal**，保证一定有层；
- 想要 HUD 里也有完整 ImGui → 走注入版（`Makefile.dylib` + TrollFools），游戏进程本身有 Metal。
## 8.5 闪退怎么查（重要）

TrollStore 上"点开就秒退、连界面都看不到"，通常是**进程在 exec 阶段就被系统杀了**（AMFI/签名问题），
不是代码里崩的。这一版做了两件事：

1. **entitlements 瘦身**：删掉了 `com.apple.private.cs.debugger`、`dynamic-codesigning`、
   `run-unsigned-code`、`QuartzCore.secure-mode`（前几个很容易让 AMFI 直接 kill 进程，
   表现就是"秒闪退且没有任何日志"）。现在只留跑起来必须的那一组。
2. **崩溃日志 + 启动面包屑**：每个启动阶段往 `/var/mobile/Library/Caches/dfm_crash.log` 写一行；
   未捕获异常和 SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGTRAP/SIGFPE 会写 backtrace。

看日志的三条路：

- App 里点 **「崩溃日志 Crash log」**（能进界面就用这个，读的是同一个文件）；
- Filza / TrollStore 的文件管理打开 `/var/mobile/Library/Caches/dfm_crash.log`；
- 电脑上用爱思/SSH 把这个文件导出来。

如果**日志文件根本没被创建**，说明进程在 `main()` 之前就被杀了 → 基本是签名/entitlements 问题，
把 `ldid -e` 的输出发我，我按机型和 iOS 版本再裁一次。


## 9. 如果 `task_for_pid` 被拦（备选路线）

ACE 这类反作弊可能调用 `ptrace(PT_DENY_ATTACH)` 或检测调试端口。三条备选，核心代码不用重写：

1. **注入版（最稳，但要动游戏包）**
   ```bash
   make -f Makefile.dylib       # 产物 .theos/obj/dfmesp.dylib
   ```
   用 TrollFools 注进 `DeltaForceClient`（你 dump SDK 时用的就是这条路）。
   核心代码用 `-DESP_INTERNAL` 编：`FindPid()` 直接返回 `getpid()`、`FindMainImageBase()` 用
   `_dyld_get_image_header(0)`、`Reader::Attach()` 用 `mach_task_self()`，其它业务代码一行不用改。
2. **kfd / 内核读写**
   iOS 15.0–16.6.1 可用物理内存读写后端，把 `Reader::Read` 换成 kfd 的 `kfd_read` 即可（接口就这一个函数）。
3. **换 hook 点**：如果只是想拿相机/骨骼，注入后直接 hook `USkinnedMeshComponent::GetBoneMatrix` 更省事。

---

## 10. 参考来源

- 机制：`TrollSpeed`（Lessica，MIT）—— root HUD、跨 App 窗口、HID 触摸
- 骨骼链路：`shiedless/Reveal`、`rockfellerfx/iOS-PUBGM-ModMenu (Dolphins)`、`silentninjabee/Farlight_ue4_external`、PUBGM 2.2.1 泄露源码
- 触摸/穿透：`iOS-IMGUI-Mod-Menu-Templates`（x2niosvn）、`iOS-ImGui-ModMenu-Template`（silentninjabee/34306）
- SDK：`MobileDumper-7`（MJx0）+ `Dumper-7`（Encryqed）导出的 CppSDK
- 渲染：`ocornut/imgui` 1.87 WIP + `imgui_impl_metal`

---

## 11. 免责 & 现实提醒

- 这是**外部只读**工具：不改游戏、不写内存、不注入。但任何第三方工具都可能被反作弊判定，**用不用、用哪个号，自己决定**。
- 三角洲属于在线对抗游戏，ACE 会持续升级检测（窗口特征、HID 回调、task port 都可能成为特征）。这份代码是「能跑通的完整模板」，不是「永久免检测成品」。
- 代码里所有**偏移都是版本相关**的，游戏一更新就要重新 dump，这是 UE4 外部的固有限制，不是这份代码的问题。
