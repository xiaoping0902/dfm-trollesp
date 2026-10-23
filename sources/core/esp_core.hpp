//
//  esp_core.hpp
//  DFM TrollESP —— UE4 外部绘制核心（TrollStore 直装版）
//
//  设计目标：
//    * 只读内存，不写游戏进程，不做 hook；
//    * 引擎偏移全部可配置 + 关键结构运行时自动探测（换游戏/换版本只改 Offsets）；
//    * 骨骼不写死索引，按骨骼名字（FName）解析出语义骨骼，换皮肤/换骨架都能画；
//    * 一个 Engine 实例可以在任意线程跑，渲染线程只读 Snapshot 快照。
//

#pragma once

#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include <mach/mach.h>
#include <sys/types.h>

namespace esp {

// ---------------------------------------------------------------------------
// 基础数学（UE4 坐标系：X 前，Y 右，Z 上；单位 cm）
// ---------------------------------------------------------------------------

struct Vec3 {
    float x = 0.f, y = 0.f, z = 0.f;
};

struct Rot3 {           // UE4 FRotator（角度制）
    float pitch = 0.f, yaw = 0.f, roll = 0.f;
};

struct Quat {
    float x = 0.f, y = 0.f, z = 0.f, w = 1.f;
};

// 注意：UE4 的 FTransform 是 16 字节对齐、0x30 大小，
// 必须是这个尺寸，否则按骨骼下标取数组会整体错位。
struct alignas(16) FTransform {
    Quat  rot;
    Vec3  translation;
    Vec3  scale3d;
    uint8_t pad[8];
};
static_assert(sizeof(FTransform) == 0x30, "FTransform must stay 0x30");

inline Vec3 operator+(const Vec3& a, const Vec3& b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
inline Vec3 operator-(const Vec3& a, const Vec3& b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline Vec3 operator*(const Vec3& a, float s) { return {a.x * s, a.y * s, a.z * s}; }
inline float Dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline float Length(const Vec3& a) { return std::sqrt(Dot(a, a)); }
inline bool Finite(const Vec3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}
inline bool Finite(float v) { return std::isfinite(v); }

inline float Deg2Rad(float d) { return d * 3.14159265358979323846f / 180.f; }

// UE4 的 FRotator -> 三个轴（forward / right / up），行向量形式
inline void RotatorToAxes(const Rot3& r, Vec3& forward, Vec3& right, Vec3& up) {
    const float sp = std::sin(Deg2Rad(r.pitch)), cp = std::cos(Deg2Rad(r.pitch));
    const float sy = std::sin(Deg2Rad(r.yaw)),   cy = std::cos(Deg2Rad(r.yaw));
    const float sr = std::sin(Deg2Rad(r.roll)),  cr = std::cos(Deg2Rad(r.roll));

    forward = {cp * cy, cp * sy, sp};
    right   = {sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp};
    up      = {-(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp};
}

// 四元数旋转一个点（分量形式，避免用 SIMD）
inline Vec3 QuatRotate(const Quat& q, const Vec3& v) {
    const float x = q.x, y = q.y, z = q.z, w = q.w;
    const float tx = 2.f * (y * v.z - z * v.y);
    const float ty = 2.f * (z * v.x - x * v.z);
    const float tz = 2.f * (x * v.y - y * v.x);
    return {v.x + w * tx + (y * tz - z * ty),
            v.y + w * ty + (z * tx - x * tz),
            v.z + w * tz + (x * ty - y * tx)};
}

// ComponentToWorld 变换一个组件空间点
inline Vec3 TransformPosition(const FTransform& t, const Vec3& p) {
    const Vec3 scaled{p.x * t.scale3d.x, p.y * t.scale3d.y, p.z * t.scale3d.z};
    const Vec3 rotated = QuatRotate(t.rot, scaled);
    return {rotated.x + t.translation.x, rotated.y + t.translation.y, rotated.z + t.translation.z};
}

// 摄像机
struct Camera {
    Vec3  location;
    Rot3  rotation;
    float fovHorizontalDeg = 90.f;
    int   screenW = 0;
    int   screenH = 0;
    bool  valid = false;
};

// 世界坐标 -> 屏幕坐标（左上角原点，像素）
inline bool WorldToScreen(const Camera& cam, const Vec3& world, float& sx, float& sy, float* outDepth = nullptr) {
    if (!cam.valid || cam.screenW <= 0 || cam.screenH <= 0) return false;

    Vec3 fwd, right, up;
    RotatorToAxes(cam.rotation, fwd, right, up);

    const Vec3 d = world - cam.location;
    const float depth = Dot(d, fwd);
    if (outDepth) *outDepth = depth;
    if (depth < 1.f) return false;

    const float W = static_cast<float>(cam.screenW);
    const float H = static_cast<float>(cam.screenH);

    float tanH = std::tan(Deg2Rad(cam.fovHorizontalDeg) * 0.5f);
    if (!(tanH > 0.01f)) tanH = 1.f;                 // tan(45°)
    const float tanV = tanH * (H / W);               // 用宽高比推垂直半角

    const float invZ = 1.f / depth;
    sx = W * 0.5f + (Dot(d, right) * invZ) * (W * 0.5f) / tanH;
    sy = H * 0.5f - (Dot(d, up) * invZ) * (H * 0.5f) / tanV;

    if (!std::isfinite(sx) || !std::isfinite(sy)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// 骨骼语义槽位
// ---------------------------------------------------------------------------

enum BoneSlot : int {
    kB_Pelvis = 0,
    kB_Spine1,
    kB_Spine2,
    kB_Spine3,
    kB_Neck,
    kB_Head,
    kB_ClavL, kB_UpperArmL, kB_LowerArmL, kB_HandL,
    kB_ClavR, kB_UpperArmR, kB_LowerArmR, kB_HandR,
    kB_ThighL, kB_CalfL, kB_FootL,
    kB_ThighR, kB_CalfR, kB_FootR,
    kB_Count
};

// 画线用的骨骼连接表（语义槽位对）
struct BoneLink { int a; int b; };
extern const BoneLink kSkeletonLinks[];
extern const int kSkeletonLinkCount;

// ---------------------------------------------------------------------------
// 内存读取
// ---------------------------------------------------------------------------

class Reader {
public:
    bool Attach(pid_t pid);
    void Detach();
    bool Attached() const { return task_ != MACH_PORT_NULL; }
    pid_t Pid() const { return pid_; }

    bool Read(uint64_t addr, void* out, size_t len) const;
    template <class T>
    bool ReadT(uint64_t addr, T& out) const { return Read(addr, &out, sizeof(T)); }
    bool ReadPtr(uint64_t addr, uint64_t& out) const;

    // 最近一次读取错误（mach 返回值 / errno），用于界面诊断
    mutable int lastError = 0;

private:
    pid_t pid_ = 0;
    mach_port_t task_ = MACH_PORT_NULL;
};

bool FindPid(const char* exeName, pid_t* outPid);
bool FindMainImageBase(pid_t pid, const char* exeName, uint64_t* outBase);
bool IsReadablePointer(uint64_t p);

// ---------------------------------------------------------------------------
// 偏移配置（默认值 = 三角洲行动 1.201.37117 / UE4.27 定制版）
// ---------------------------------------------------------------------------

struct Offsets {
    // 引擎全局（RVA，相对主程序 __TEXT 起点）
    uint64_t rvaGObjects = 0x1177A17B8;
    uint64_t rvaGNames   = 0x1173776C0;
    uint64_t rvaGWorld   = 0x1178B44E0;   // 置 0 则自动从 GObjects 里找 UWorld

    // TUObjectArray（FChunkedFixedUObjectArray）
    int32_t uobjObjects = 0x20;
    int32_t uobjNum     = 0x14;
    int32_t uobjMax     = 0x38;
    int32_t uobjChunks  = 0x18;

    // UObject（-1 表示自动探测）
    int32_t objClass = -1;
    int32_t objName  = -1;
    int32_t objOuter = -1;

    // UWorld / ULevel / UGameInstance
    int32_t worldPersistentLevel = 0x0F8;
    int32_t worldLevels          = 0x158;
    int32_t worldGameInstance    = 0x190;
    int32_t levelActors          = 0x098;

    // AActor / APawn / ACharacter / AController / APlayerController
    int32_t actorRootComponent      = 0x180;
    int32_t characterMesh           = 0x3D0;
    int32_t controllerPawn          = 0x3F0;   // APlayerController::AcknowledgedPawn
    int32_t controllerCameraManager = 0x408;
    int32_t controllerControlRot    = 0x3D8;
    int32_t pawnPlayerState         = 0x390;

    // APlayerCameraManager
    int32_t camCache            = 0x3E0;   // FCameraCacheEntry{ float Timestamp; pad; FMinimalViewInfo POV }
    int32_t camPovFov           = 0x1C;    // FMinimalViewInfo::FOV（相对 POV 起点）
    int32_t camPovRotation      = 0x10;    // FMinimalViewInfo::Rotation
    int32_t camTransformComp    = 0x378;

    // USkeletalMeshComponent
    int32_t meshSkeletalMesh    = 0x718;
    int32_t meshBoneTransforms  = 0xA18;   // TArray<FTransform> CachedComponentSpaceTransforms
    int32_t meshBoneTransformsAlt = 0xA08; // TArray<FTransform> CachedBoneSpaceTransforms
    int32_t meshWorldBounds     = 0x8E8;   // FBoxSphereBounds（仅用于自检打分）
    int32_t sceneComponentToWorld = -1;    // -1 = 自动探测
    int32_t boneStride          = 0x30;

    // 角色类名过滤（逗号分隔，命中的 Class 才当成人）
    std::string characterClassIncludes =
        "DFMCharacter,DFMAICharacter,GPCharacter,CharacterBase,IntCharacter,"
        "AICharacter,PlayerCharacter,BP_Character,Soldier";
    // 排除（比如尸体、载具、观战摄像机）
    std::string characterClassExcludes =
        "AnimInstance,Component,Manager,Interface,Marker,Data,Fashion,Voic,Significance";

    // 采样参数
    int   sampleHz       = 60;
    float maxDistance    = 500.f;    // 米
    bool  requireVisible = true;     // 至少一个骨骼点能投影到屏幕内
};

// ---------------------------------------------------------------------------
// 运行时快照
// ---------------------------------------------------------------------------

struct Entity {
    uint64_t actor = 0;
    uint64_t mesh = 0;
    float    distance = 0.f;         // 米
    float    worldHeight = 0.f;      // 头到脚的世界高度（cm）
    Vec3     pelvis{};
    std::array<Vec3, kB_Count> bones{};      // 世界坐标
    std::array<uint8_t, kB_Count> have{};    // 1 = 有效
    int      resolvedBones = 0;

    // 调试用
    uint64_t skeletalMesh = 0;
    int      rawBoneCount = 0;
    std::string className;
    std::array<int16_t, kB_Count> boneIdx{}; // 语义槽位 -> 骨骼下标
};

// 引擎诊断（调试窗口显示）
struct Diag {
    int      pid = 0;
    uint64_t base = 0;
    uint64_t gobjects = 0;
    uint64_t gnames = 0;
    uint64_t gworld = 0;
    int      objClass = 0;
    int      objName = 0;
    int      nameBlocks = 0;
    int      nameHeader = 0;
    int      nameScale = 0;
    int      compToWorld = 0;
    int      boneArray = 0;
    uint32_t numObjects = 0;
    int      actorCount = 0;
    int      charCount = 0;
    int      boneFail = 0;
    float    tickMs = 0.f;
};

// 目标角色单根骨骼的明细（调试表格用）
struct BoneDebugRow {
    int         slot = -1;
    int         index = -1;
    std::string name;
    Vec3        world;
};

struct Snapshot {
    Camera camera;
    std::vector<Entity> entities;
    int scannedActors = 0;
    int characterActors = 0;
    int boneFailures = 0;
    std::string status;        // 启动/错误信息，直接显示在菜单里
    uint64_t stampMs = 0;

    // 调试数据（只在调试窗口打开时填）
    Diag diag;
    uint64_t debugEntity = 0;
    std::string debugEntityClass;
    std::vector<BoneDebugRow> debugBones;   // 目标角色的语义骨骼明细
    std::vector<std::string>  debugSkeleton; // 目标骨架的全部骨骼名（下标顺序）
};

// ---------------------------------------------------------------------------
// 引擎
// ---------------------------------------------------------------------------

class Engine {
public:
    bool Bootstrap(const std::string& moduleName, std::string& logOut);
    void Shutdown();
    void Tick();                                    // 采样一次世界（在工作线程里循环调用）
    Snapshot CopySnapshot() const;

    bool IsReady() const { return ready_; }
    Reader& Mem() { return reader_; }
    const Offsets& Off() const { return off_; }
    Offsets& OffMutable() { return off_; }
    void SetOffsets(const Offsets& o);
    pid_t TargetPid() const { return reader_.Pid(); }
    uint64_t ModuleBase() const { return base_; }

    // 诊断用
    std::string ProbeReport();

    // 对象系统（供界面/调试使用）
    uint32_t NumObjects() const;
    uint64_t ObjectAt(uint32_t index) const;
    std::string NameByIndex(uint32_t index) const;
    std::string ObjectName(uint64_t obj) const;

    // 调试：让采样线程把第 index 个角色的骨骼明细塞进 Snapshot
    void SetDebugTarget(int entityIndex, bool fill);

private:
    bool ResolveGNames(std::string& log);
    bool ResolveGObjects(std::string& log);
    bool ResolveObjectLayout(std::string& log);
    bool ResolveGWorld(std::string& log);
    bool ResolveComponentToWorld(std::string& log);

    bool DecodeName(uint32_t index, std::string& out) const;
    std::string NameOfObject(uint64_t obj) const;
    std::string ClassNameOf(uint64_t obj) const;

    bool IsCharacterClass(uint64_t classPtr);
    bool UpdateActorList();
    bool UpdateCamera(Camera& cam);
    bool SampleCharacter(uint64_t actor, Entity& out);
    bool ResolveSkeleton(uint64_t skeletalMesh);
    uint64_t FindLocalPlayerController();

    struct SkeletonMap {
        int boneCount = 0;
        std::unordered_map<int, int> slotToBone;   // 语义槽位 -> 骨骼下标
        std::unordered_map<int, std::string> indexToName;
        std::vector<std::string> allNames;         // 按骨骼下标顺序
        std::string rawNameDump;
    };

    mutable std::mutex snapMutex_;
    Snapshot snap_;

    Reader    reader_;
    Offsets   off_;
    uint64_t  base_ = 0;

    // 已探测到的运行时布局
    int  nameBlocksOffset_ = -1;
    int  nameHeaderSize_   = 2;
    int  nameOffsetScale_  = 1;
    int  uobjObjectsOff_   = 0x20;
    int  uobjNumOff_       = 0x14;
    int  objClassOff_      = 0x08;
    int  objNameOff_       = 0x1C;
    int  objOuterOff_      = 0x10;
    int  compToWorldOff_   = -1;
    int  boneArrayOff_     = 0xA18;

    uint64_t gnamesAddr_ = 0;
    uint64_t gobjectsAddr_ = 0;
    uint64_t gworldAddr_ = 0;
    uint64_t gworldSlotAddr_ = 0;     // &GWorld（大厅 -> 对局时 UWorld 会换对象，要重新解引用）
    uint64_t nameBlocksPtr_ = 0;

    mutable std::unordered_map<uint32_t, std::string> nameCache_;
    mutable std::mutex nameMutex_;

    std::unordered_map<uint64_t, bool> classCache_;       // UClass -> 是否角色
    std::unordered_map<uint64_t, SkeletonMap> skelCache_;

    std::vector<uint64_t> actorList_;
    std::vector<uint64_t> charActorList_;      // 过滤后的角色（每次 actor 列表变化才重建）
    uint64_t lastActorScanMs_ = 0;

    uint64_t localController_ = 0;
    uint64_t lastControllerScanMs_ = 0;
    uint64_t lastCtwAttemptMs_ = 0;

    std::atomic<int>  debugTarget_{0};
    std::atomic<bool> debugFill_{false};

    bool     ready_ = false;
};

uint64_t NowMs();

// 由渲染层每帧写入视口尺寸（像素），摄像机构图要用
void SetViewportSize(int width, int height);
void GetViewportSize(int* w, int* h);

// ---------------------------------------------------------------------------
// 显示设置（App 界面改，HUD 进程读）
// ---------------------------------------------------------------------------

struct EspSettings {
    bool  enabled       = true;
    bool  drawSkeleton  = true;
    bool  drawBox       = true;
    bool  drawHeadDot   = true;
    bool  drawDistance  = true;
    bool  drawSnapline  = false;
    bool  drawBoneJoints = false;
    bool  drawFilledBox = false;

    float maxDistance   = 500.f;      // 米
    float lineThickness = 1.4f;
    float boxThickness  = 1.4f;
    float textScale     = 1.0f;

    float colorSkeleton[4] = {0.25f, 1.00f, 0.45f, 1.0f};
    float colorBox[4]      = {1.00f, 1.00f, 1.00f, 1.0f};
    float colorSnapline[4] = {1.00f, 1.00f, 1.00f, 0.5f};
    float colorText[4]     = {1.00f, 1.00f, 1.00f, 1.0f};

    std::string moduleName = "DeltaForceClient";
    int  sampleHz          = 60;      // 采样线程频率
    bool verboseLog        = false;
};

bool LoadSettings(EspSettings& settings, Offsets& offsets);
void SaveSettings(const EspSettings& settings, const Offsets& offsets);
const char* SettingsPlistPath();
void PostReloadNotification();

} // namespace esp
