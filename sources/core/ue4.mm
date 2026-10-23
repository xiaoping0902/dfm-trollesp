//
//  ue4.cpp
//  DFM TrollESP —— UE4 引擎对象遍历 / 骨骼解析 / 摄像机
//
//  链路（和 Reveal / Dolphins / Farlight 那套一模一样，只是偏移换成本游戏的）：
//      GWorld -> PersistentLevel -> ULevel::Actors
//      actor.Class -> 类名过滤 -> ACharacter::Mesh -> USkeletalMeshComponent
//      mesh.ComponentToWorld + mesh.CachedComponentSpaceTransforms[]
//      -> 每根骨骼世界坐标
//
//  关键点：骨骼索引不写死。先从 USkeletalMesh 里把 FReferenceSkeleton 的
//  骨骼名数组扫出来（APEX 数组结构自检），再按名字映射到语义槽位，
//  所以换皮肤 / 换骨架 / 换 UE4 游戏都能画，只要骨架是标准人形命名。
//

#include "esp_core.hpp"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <set>

namespace esp {

const BoneLink kSkeletonLinks[] = {
    {kB_Pelvis, kB_Spine1}, {kB_Spine1, kB_Spine2}, {kB_Spine2, kB_Spine3},
    {kB_Spine3, kB_Neck},   {kB_Neck,   kB_Head},
    {kB_Spine3, kB_ClavL},  {kB_ClavL,  kB_UpperArmL}, {kB_UpperArmL, kB_LowerArmL}, {kB_LowerArmL, kB_HandL},
    {kB_Spine3, kB_ClavR},  {kB_ClavR,  kB_UpperArmR}, {kB_UpperArmR, kB_LowerArmR}, {kB_LowerArmR, kB_HandR},
    {kB_Pelvis, kB_ThighL}, {kB_ThighL, kB_CalfL},     {kB_CalfL,     kB_FootL},
    {kB_Pelvis, kB_ThighR}, {kB_ThighR, kB_CalfR},     {kB_CalfR,     kB_FootR},
};
const int kSkeletonLinkCount = static_cast<int>(sizeof(kSkeletonLinks) / sizeof(kSkeletonLinks[0]));

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

namespace {

int g_viewW = 0;
int g_viewH = 0;

std::string Lower(std::string s) {
    for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

std::string Normalize(const std::string& raw) {
    std::string s = Lower(raw);
    for (char& c : s) {
        if (!std::isalnum(static_cast<unsigned char>(c))) c = ' ';
    }
    // 压掉连续空格，前后补一个空格，方便匹配 " l " / " left "
    std::string out = " ";
    bool prevSpace = true;
    for (char c : s) {
        if (c == ' ') {
            if (!prevSpace) { out.push_back(' '); prevSpace = true; }
        } else {
            out.push_back(c);
            prevSpace = false;
        }
    }
    out.push_back(' ');
    return out;
}

bool HasWord(const std::string& norm, const char* word) {
    return norm.find(std::string(" ") + word + " ") != std::string::npos;
}

bool HasSub(const std::string& norm, const char* sub) {
    return norm.find(sub) != std::string::npos;
}

bool IsLeftSide(const std::string& norm) {
    return HasWord(norm, "l") || HasWord(norm, "left") || HasWord(norm, "lf") || HasSub(norm, " left");
}

bool IsRightSide(const std::string& norm) {
    return HasWord(norm, "r") || HasWord(norm, "right") || HasWord(norm, "rt") || HasSub(norm, " right");
}

// 骨骼名 -> 语义槽位（不含 spine，spine 单独按顺序分配）
int SlotFromBoneName(const std::string& rawName) {
    const std::string n = Normalize(rawName);
    const bool left = IsLeftSide(n);
    const bool right = IsRightSide(n);

    if (HasSub(n, "head") && !HasSub(n, "headwear"))  return kB_Head;
    if (HasSub(n, "neck"))                            return kB_Neck;
    if (HasSub(n, "pelvis") || HasWord(n, "hips") || HasWord(n, "hip")) return kB_Pelvis;

    if (HasSub(n, "clavicle") || HasSub(n, "shoulder")) {
        if (left)  return kB_ClavL;
        if (right) return kB_ClavR;
        return -1;
    }
    if (HasSub(n, "forearm") || HasSub(n, "lowerarm") || HasSub(n, "lower arm") ||
        HasSub(n, "loarm") || HasSub(n, "elbow")) {
        if (left)  return kB_LowerArmL;
        if (right) return kB_LowerArmR;
        return -1;
    }
    if (HasSub(n, "upperarm") || HasSub(n, "uparm") || HasSub(n, "upper arm") ||
        HasWord(n, "arm") || HasSub(n, "arml") || HasSub(n, "armr")) {
        if (left)  return kB_UpperArmL;
        if (right) return kB_UpperArmR;
    }
    if (HasWord(n, "hand") || HasSub(n, "hand")) {
        if (left)  return kB_HandL;
        if (right) return kB_HandR;
    }
    if (HasSub(n, "thigh") || HasSub(n, "upleg") || HasSub(n, "up leg") ||
        HasSub(n, "thigh") || HasWord(n, "leg")) {
        if (left)  return kB_ThighL;
        if (right) return kB_ThighR;
    }
    if (HasSub(n, "calf") || HasSub(n, "shin") || HasSub(n, "lowleg") ||
        HasSub(n, "low leg") || HasSub(n, "crus")) {
        if (left)  return kB_CalfL;
        if (right) return kB_CalfR;
    }
    if (HasSub(n, "foot") || HasSub(n, "ball") || HasSub(n, "toe")) {
        if (left)  return kB_FootL;
        if (right) return kB_FootR;
    }
    return -1;
}

bool IsPrintableName(const std::string& s) {
    if (s.empty() || s.size() > 200) return false;
    for (unsigned char c : s) {
        if (c < 0x20 || c > 0x7E) return false;
    }
    return true;
}

// 逗号分隔列表里是否有任一子串命中
bool ListMatch(const std::string& loweredHaystack, const std::string& commaList) {
    size_t start = 0;
    while (start <= commaList.size()) {
        size_t end = commaList.find(',', start);
        if (end == std::string::npos) end = commaList.size();
        std::string item = commaList.substr(start, end - start);
        // 去空白
        item.erase(std::remove_if(item.begin(), item.end(),
                                  [](unsigned char c) { return std::isspace(c) != 0; }),
                   item.end());
        if (!item.empty()) {
            if (loweredHaystack.find(Lower(item)) != std::string::npos) return true;
        }
        start = end + 1;
    }
    return false;
}

bool PlausibleTransform(const FTransform& t) {
    if (!Finite(t.translation) || !Finite(t.rot.w) || !Finite(t.rot.x)) return false;
    const float qn = std::sqrt(t.rot.x * t.rot.x + t.rot.y * t.rot.y + t.rot.z * t.rot.z + t.rot.w * t.rot.w);
    if (!(qn > 0.5f && qn < 1.5f)) return false;
    if (!(std::fabs(t.scale3d.x) < 100.f && std::fabs(t.scale3d.y) < 100.f && std::fabs(t.scale3d.z) < 100.f)) return false;
    if (std::fabs(t.translation.x) > 5.0e6f || std::fabs(t.translation.y) > 5.0e6f ||
        std::fabs(t.translation.z) > 5.0e6f) return false;
    return true;
}

// 读 TArray<T*>（0x10 头）
bool ReadPointerArray(const Reader& r, uint64_t addr, std::vector<uint64_t>& out, int32_t cap) {
    out.clear();
    uint64_t data = 0;
    int32_t num = 0, max = 0;
    if (!r.Read(addr, &data, 8)) return false;
    if (!r.Read(addr + 8, &num, 4)) return false;
    if (!r.Read(addr + 12, &max, 4)) return false;
    if (!IsReadablePointer(data) || num <= 0 || num > max || num > cap) return false;

    out.resize(static_cast<size_t>(num));
    if (!r.Read(data, out.data(), static_cast<size_t>(num) * sizeof(uint64_t))) {
        out.clear();
        return false;
    }
    return true;
}

} // namespace

void SetViewportSize(int width, int height) {
    g_viewW = width;
    g_viewH = height;
}

void GetViewportSize(int* w, int* h) {
    if (w) *w = g_viewW;
    if (h) *h = g_viewH;
}

// ---------------------------------------------------------------------------
// 对象系统
// ---------------------------------------------------------------------------

uint32_t Engine::NumObjects() const {
    int32_t num = 0;
    if (!reader_.ReadT<int32_t>(gobjectsAddr_ + uobjNumOff_, num)) return 0;
    return num > 0 ? static_cast<uint32_t>(num) : 0;
}

uint64_t Engine::ObjectAt(uint32_t index) const {
    uint64_t objects = 0;
    if (!reader_.ReadPtr(gobjectsAddr_ + uobjObjectsOff_, objects)) return 0;
    if (!IsReadablePointer(objects)) return 0;

    const uint32_t chunkIdx = index >> 16;
    const uint32_t chunkOff = index & 0xFFFF;

    uint64_t chunk = 0;
    if (!reader_.ReadPtr(objects + static_cast<uint64_t>(chunkIdx) * 8, chunk)) return 0;
    if (!IsReadablePointer(chunk)) return 0;

    uint64_t obj = 0;
    if (!reader_.ReadPtr(chunk + static_cast<uint64_t>(chunkOff) * 0x18, obj)) return 0;
    return IsReadablePointer(obj) ? obj : 0;
}

bool Engine::DecodeName(uint32_t index, std::string& out) const {
    if (nameBlocksOffset_ < 0 || !IsReadablePointer(gnamesAddr_)) return false;

    uint64_t blocks = nameBlocksPtr_;
    if (!IsReadablePointer(blocks)) {
        if (!reader_.ReadPtr(gnamesAddr_ + nameBlocksOffset_, blocks)) return false;
        if (!IsReadablePointer(blocks)) return false;
        const_cast<Engine*>(this)->nameBlocksPtr_ = blocks;
    }

    const uint32_t blockIdx = index >> 16;
    const uint32_t byteOff = (index & 0xFFFF) * static_cast<uint32_t>(nameOffsetScale_);

    uint64_t block = 0;
    if (!reader_.ReadPtr(blocks + static_cast<uint64_t>(blockIdx) * 8, block)) return false;
    if (!IsReadablePointer(block)) return false;

    const uint64_t entry = block + byteOff;
    uint8_t header[4] = {0};
    if (!reader_.Read(entry, header, static_cast<size_t>(nameHeaderSize_))) return false;

    bool wide = false;
    uint32_t len = 0;
    if (nameHeaderSize_ == 2) {
        uint16_t h = 0;
        memcpy(&h, header, 2);
        wide = (h & 1u) != 0;
        len = static_cast<uint32_t>(h >> 1) & 0x7FFFu;
    } else {
        uint32_t h = 0;
        memcpy(&h, header, 4);
        wide = (h & 1u) != 0;
        len = (h >> 6) & 0x03FFFFFFu;     // UE4.22-：bIsWide:1 / ProbeHash:5 / Len:26
    }
    if (len == 0 || len > 512) return false;

    if (wide) {
        uint16_t buf[512] = {0};
        const size_t n = std::min<size_t>(len, 512);
        if (!reader_.Read(entry + static_cast<uint64_t>(nameHeaderSize_), buf, n * 2)) return false;
        out.clear();
        for (size_t i = 0; i < n; ++i) {
            if (buf[i] == 0) break;
            out.push_back(buf[i] < 0x80 ? static_cast<char>(buf[i]) : '?');
        }
    } else {
        char buf[513] = {0};
        const size_t n = std::min<size_t>(len, 512);
        if (!reader_.Read(entry + static_cast<uint64_t>(nameHeaderSize_), buf, n)) return false;
        out.assign(buf, n);
    }
    return !out.empty();
}

std::string Engine::NameByIndex(uint32_t index) const {
    {
        std::lock_guard<std::mutex> lock(nameMutex_);
        auto it = nameCache_.find(index);
        if (it != nameCache_.end()) return it->second;
    }
    std::string name;
    if (!DecodeName(index, name)) name.clear();
    {
        std::lock_guard<std::mutex> lock(nameMutex_);
        if (nameCache_.size() < 200000) nameCache_[index] = name;
    }
    return name;
}

std::string Engine::NameOfObject(uint64_t obj) const {
    if (!IsReadablePointer(obj) || objNameOff_ < 0) return {};
    int32_t index = 0;
    if (!reader_.ReadT<int32_t>(obj + objNameOff_, index)) return {};
    return NameByIndex(static_cast<uint32_t>(index));
}

std::string Engine::ObjectName(uint64_t obj) const {
    return NameOfObject(obj);
}

std::string Engine::ClassNameOf(uint64_t obj) const {
    if (!IsReadablePointer(obj) || objClassOff_ < 0) return {};
    uint64_t cls = 0;
    if (!reader_.ReadPtr(obj + objClassOff_, cls)) return {};
    return NameOfObject(cls);
}

// ---------------------------------------------------------------------------
// 启动流程
// ---------------------------------------------------------------------------

bool Engine::ResolveGNames(std::string& log) {
    gnamesAddr_ = base_ + off_.rvaGNames;
    nameBlocksOffset_ = -1;
    nameBlocksPtr_ = 0;

    // 只做一次粗筛；真正定名在 ResolveObjectLayout 里（结合对象名交叉验证）
    static const int kBlocksOffs[] = {0x10, 0x08, 0x18, 0x20, 0x28, 0x30, 0x38, 0x40, 0x48,
                                      0x50, 0x60, 0x68, 0x70, 0x78, 0x80, 0x88, 0x90, 0x98,
                                      0xA0, 0xB0, 0xC0, 0xC8, 0xD0, 0xD8, 0xE0, 0xE8, 0xF0};
    for (int off : kBlocksOffs) {
        uint64_t blocks = 0;
        if (!reader_.ReadPtr(gnamesAddr_ + off, blocks)) continue;
        if (!IsReadablePointer(blocks)) continue;
        uint64_t block0 = 0;
        if (!reader_.ReadPtr(blocks, block0)) continue;
        if (!IsReadablePointer(block0)) continue;
        char head[8] = {0};
        if (!reader_.Read(block0, head, sizeof(head))) continue;
        if (memcmp(head + 2, "None", 4) == 0 || memcmp(head + 4, "None", 4) == 0) {
            nameBlocksOffset_ = off;
            nameBlocksPtr_ = blocks;
            char buf[128];
            snprintf(buf, sizeof(buf), "GNames: FNamePool blocks@+0x%X\n", off);
            log += buf;
            return true;
        }
    }
    log += "GNames: 没找到 \"None\" 锚点（rvaGNames 可能过期）\n";
    return false;
}

bool Engine::ResolveGObjects(std::string& log) {
    gobjectsAddr_ = base_ + off_.rvaGObjects;

    struct Cand { int objects, num; };
    static const Cand kCands[] = {{0x20, 0x14}, {0x10, 0x0C}, {0x20, 0x0C}, {0x18, 0x14}, {0x10, 0x10}};

    char buf[192];
    for (const Cand& c : kCands) {
        uint64_t objects = 0;
        if (!reader_.ReadPtr(gobjectsAddr_ + c.objects, objects)) continue;
        if (!IsReadablePointer(objects)) continue;

        int32_t num = 0;
        if (!reader_.ReadT<int32_t>(gobjectsAddr_ + c.num, num)) continue;
        if (num < 1000 || num > 20000000) continue;

        uint64_t chunk0 = 0;
        if (!reader_.ReadPtr(objects, chunk0) || !IsReadablePointer(chunk0)) continue;
        uint64_t obj0 = 0;
        if (!reader_.ReadPtr(chunk0, obj0) || !IsReadablePointer(obj0)) continue;

        uobjObjectsOff_ = c.objects;
        uobjNumOff_ = c.num;
        snprintf(buf, sizeof(buf), "GObjects: NumElements=%d (Objects@+0x%X)\n", num, c.objects);
        log += buf;
        return true;
    }
    log += "GObjects: TUObjectArray 布局不匹配（rvaGObjects 可能过期）\n";
    return false;
}

bool Engine::ResolveObjectLayout(std::string& log) {
    struct NameCfg { int blocks; int hdr; int scale; };
    static const int kHdrSizes[] = {2, 4};
    static const int kScales[] = {2, 1};

    // UObject 布局候选：{Class, Name, Outer}
    struct ObjCfg { int cls, name, outer; };
    static const ObjCfg kObjCfgs[] = {
        {0x08, 0x1C, 0x10},   // 本游戏（MobileDumper-7 实测）
        {0x10, 0x18, 0x20},   // 标准 UE4
        {0x08, 0x18, 0x10},
        {0x10, 0x1C, 0x20},
        {0x10, 0x14, 0x18},
    };

    static const int kBlocksOffs[] = {0x10, 0x08, 0x18, 0x20, 0x28, 0x30, 0x38, 0x40, 0x48,
                                      0x50, 0x60, 0x68, 0x70, 0x78, 0x80, 0x88, 0x90, 0x98,
                                      0xA0, 0xB0, 0xC0, 0xC8, 0xD0, 0xD8, 0xE0, 0xE8, 0xF0};

    for (int blocksOff : kBlocksOffs) {
        uint64_t blocks = 0;
        if (!reader_.ReadPtr(gnamesAddr_ + blocksOff, blocks)) continue;
        if (!IsReadablePointer(blocks)) continue;
        uint64_t block0 = 0;
        if (!reader_.ReadPtr(blocks, block0)) continue;
        if (!IsReadablePointer(block0)) continue;

        uint8_t head[8] = {0};
        if (!reader_.Read(block0, head, sizeof(head))) continue;

        for (int hdr : kHdrSizes) {
            // 先用 "None"(index 0) 快速判定
            bool ok = false;
            if (hdr == 2) {
                uint16_t h = 0;
                memcpy(&h, head, 2);
                const uint32_t len = (h >> 1) & 0x7FFFu;
                ok = (h & 1u) == 0 && (memcmp(head + 2, "None", 4) == 0) &&
                     len >= 4 && len <= 64;
            } else {
                uint32_t h = 0;
                memcpy(&h, head, 4);
                const uint32_t len = (h >> 6) & 0x03FFFFFFu;
                ok = (h & 1u) == 0 && (memcmp(head + 4, "None", 4) == 0) &&
                     len >= 4 && len <= 64;
            }
            if (!ok) continue;

            for (int scale : kScales) {
                nameBlocksOffset_ = blocksOff;
                nameHeaderSize_ = hdr;
                nameOffsetScale_ = scale;
                nameBlocksPtr_ = blocks;
                {
                    std::lock_guard<std::mutex> lock(nameMutex_);
                    nameCache_.clear();
                }

                for (const ObjCfg& cfg : kObjCfgs) {
                    objClassOff_ = cfg.cls;
                    objNameOff_ = cfg.name;
                    objOuterOff_ = cfg.outer;

                    // 交叉验证：前 8 个对象里至少 2 个名字能对上已知锚点
                    int hits = 0;
                    bool printable = true;
                    for (uint32_t i = 0; i < 8; ++i) {
                        uint64_t obj = ObjectAt(i);
                        if (!obj) continue;
                        std::string nm = NameOfObject(obj);
                        if (!IsPrintableName(nm)) { printable = false; break; }
                        if (nm == "CoreUObject" || nm == "Object" || nm == "Class" ||
                            nm == "Package" || nm == "Engine" || nm == "None") {
                            ++hits;
                        }
                    }
                    if (!printable || hits < 2) continue;

                    char buf[256];
                    snprintf(buf, sizeof(buf),
                             "UObject 布局: Class+0x%X Name+0x%X Outer+0x%X | FName blocks+0x%X hdr=%d scale=%d\n",
                             cfg.cls, cfg.name, cfg.outer, blocksOff, hdr, scale);
                    log += buf;
                    return true;
                }
            }
        }
    }

    // 兜底：用 SDK 报告的布局
    objClassOff_ = (off_.objClass >= 0) ? off_.objClass : 0x08;
    objNameOff_  = (off_.objName  >= 0) ? off_.objName  : 0x1C;
    objOuterOff_ = (off_.objOuter >= 0) ? off_.objOuter : 0x10;
    if (nameBlocksOffset_ < 0) { nameBlocksOffset_ = 0x10; nameHeaderSize_ = 2; nameOffsetScale_ = 2; }
    log += "UObject/FName 布局自动探测失败，已回退到默认值（名字可能解不出来）\n";
    return true;
}

bool Engine::ResolveGWorld(std::string& log) {
    gworldAddr_ = 0;
    gworldSlotAddr_ = 0;

    if (off_.rvaGWorld != 0) {
        const uint64_t slot = base_ + off_.rvaGWorld;
        uint64_t world = 0;
        if (reader_.ReadPtr(slot, world) && IsReadablePointer(world)) {
            uint64_t level = 0;
            if (reader_.ReadPtr(world + off_.worldPersistentLevel, level) && IsReadablePointer(level)) {
                gworldAddr_ = world;
                gworldSlotAddr_ = slot;
                log += "GWorld: ok (rvaGWorld)\n";
                return true;
            }
        }
        log += "GWorld: rvaGWorld 指向的对象不像 UWorld，转去 GObjects 里找\n";
    }

    const uint32_t total = std::min<uint32_t>(NumObjects(), 300000u);
    for (uint32_t i = 0; i < total; ++i) {
        uint64_t obj = ObjectAt(i);
        if (!obj) continue;
        uint64_t cls = 0;
        if (!reader_.ReadPtr(obj + objClassOff_, cls) || !IsReadablePointer(cls)) continue;
        std::string cn = NameOfObject(cls);
        if (cn != "World") continue;

        uint64_t level = 0;
        if (!reader_.ReadPtr(obj + off_.worldPersistentLevel, level) || !IsReadablePointer(level)) continue;
        uint64_t actorsData = 0;
        int32_t num = 0;
        if (!reader_.ReadPtr(level + off_.levelActors, actorsData)) continue;
        if (!reader_.ReadT<int32_t>(level + off_.levelActors + 8, num)) continue;
        if (!IsReadablePointer(actorsData) || num < 1) continue;

        gworldAddr_ = obj;
        char buf[160];
        snprintf(buf, sizeof(buf), "GWorld: 扫描得到 0x%llX（Actors=%d）\n",
                 static_cast<unsigned long long>(obj), num);
        log += buf;
        return true;
    }

    log += "GWorld: 没找到，先把游戏进到对局/训练场再启动\n";
    return false;
}

// ComponentToWorld 不在 UPROPERTY 里（Dumper-7 导不出），只能运行时探：
// 在 USceneComponent 的隐藏填充区里找 FTransform，用四元数模长 / 缩放 / 与
// FBoxSphereBounds.Origin 的距离打分，选最像的那个。
bool Engine::ResolveComponentToWorld(std::string& log) {
    if (off_.sceneComponentToWorld > 0) {
        compToWorldOff_ = off_.sceneComponentToWorld;
        return true;
    }
    if (compToWorldOff_ > 0) return true;

    // 需要一个真实存在的角色 mesh
    uint64_t sampleMesh = 0;
    for (uint64_t actor : charActorList_) {
        if (!reader_.ReadPtr(actor + off_.characterMesh, sampleMesh)) continue;
        if (IsReadablePointer(sampleMesh)) break;
        sampleMesh = 0;
    }
    if (!sampleMesh) return false;

    // 参考值：mesh 的世界包围盒中心
    Vec3 boundsOrigin{};
    bool haveBounds = false;
    {
        // FBoxSphereBounds: Origin(FVector) / BoxExtent(FVector) / SphereRadius(float)
        struct Bounds { Vec3 origin, extent; float radius; } b{};
        if (reader_.Read(sampleMesh + off_.meshWorldBounds, &b, sizeof(b)) && Finite(b.origin) &&
            std::fabs(b.origin.z) < 5.0e6f && b.extent.z > 1.f && b.extent.z < 2000.f) {
            boundsOrigin = b.origin;
            haveBounds = true;
        }
    }

    int bestOff = -1;
    int bestScore = -1000;
    char dump[512] = {0};
    size_t dumpLen = 0;

    for (int off = 0x150; off <= 0x260; off += 0x10) {
        FTransform t{};
        if (!reader_.Read(sampleMesh + off, &t, sizeof(t))) continue;
        if (!PlausibleTransform(t)) continue;

        const float qn = std::sqrt(t.rot.x * t.rot.x + t.rot.y * t.rot.y +
                                   t.rot.z * t.rot.z + t.rot.w * t.rot.w);
        int score = 0;
        if (qn > 0.99f && qn < 1.01f) score += 4;
        if (t.scale3d.x > 0.9f && t.scale3d.x < 1.1f &&
            t.scale3d.y > 0.9f && t.scale3d.y < 1.1f &&
            t.scale3d.z > 0.9f && t.scale3d.z < 1.1f) score += 2;
        if (Length(t.translation) > 1.f) score += 1;
        if (haveBounds) {
            const Vec3 d = t.translation - boundsOrigin;
            const float dist = Length(d);
            if (dist < 200.f) score += 5;
            else if (dist < 1500.f) score += 2;
            else score -= 3;
        }

        if (dumpLen < sizeof(dump) - 96) {
            int n = snprintf(dump + dumpLen, sizeof(dump) - dumpLen,
                             "  +0x%03X score=%d t=(%.0f,%.0f,%.0f)\n",
                             off, score, t.translation.x, t.translation.y, t.translation.z);
            if (n > 0) dumpLen += static_cast<size_t>(n);
        }

        if (score > bestScore) { bestScore = score; bestOff = off; }
    }

    if (bestScore < 6 || bestOff < 0) {
        log += "ComponentToWorld: 还没定位到（进对局、有角色站你面前再点“重新初始化”）\n";
        if (dumpLen) log += dump;
        return false;
    }

    compToWorldOff_ = bestOff;
    char buf[192];
    snprintf(buf, sizeof(buf), "ComponentToWorld: +0x%X（score %d）\n", bestOff, bestScore);
    log += buf;
    return true;
}

bool Engine::Bootstrap(const std::string& moduleName, std::string& logOut) {
    ready_ = false;
    logOut.clear();

    // 每次重连都把上一轮的缓存清掉（游戏可能已经换了 pid，旧指针全部失效）
    classCache_.clear();
    skelCache_.clear();
    actorList_.clear();
    charActorList_.clear();
    {
        std::lock_guard<std::mutex> lock(nameMutex_);
        nameCache_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(snapMutex_);
        snap_ = Snapshot{};
    }
    nameBlocksPtr_ = 0;
    nameBlocksOffset_ = -1;
    gworldSlotAddr_ = 0;
    localController_ = 0;
    lastControllerScanMs_ = 0;
    lastCtwAttemptMs_ = 0;
    lastActorScanMs_ = 0;
    compToWorldOff_ = off_.sceneComponentToWorld > 0 ? off_.sceneComponentToWorld : -1;
    boneArrayOff_ = off_.meshBoneTransforms;

    const std::string exe = moduleName.empty() ? std::string("DeltaForceClient") : moduleName;

    pid_t pid = 0;
    if (!FindPid(exe.c_str(), &pid)) {
        logOut += "找不到进程 " + exe + "（先把游戏开到大厅/对局）\n";
        return false;
    }
    {
        char buf[128];
        snprintf(buf, sizeof(buf), "目标进程: %s pid=%d\n", exe.c_str(), pid);
        logOut += buf;
    }

    if (!reader_.Attach(pid)) {
        char buf[256];
        snprintf(buf, sizeof(buf), "task_for_pid 失败: %s (%d)\n",
                 mach_error_string(reader_.lastError), reader_.lastError);
        logOut += buf;
        logOut += "→ 需要 task_for_pid-allow 权限，并且 HUD 进程以 root 运行\n";
        return false;
    }

    if (!FindMainImageBase(pid, exe.c_str(), &base_)) {
        logOut += "找不到主程序镜像基址（模块名对不上？）\n";
        return false;
    }
    {
        char buf[128];
        snprintf(buf, sizeof(buf), "模块基址: 0x%llX\n", static_cast<unsigned long long>(base_));
        logOut += buf;
    }

    ResolveGNames(logOut);
    if (!ResolveGObjects(logOut)) return false;
    ResolveObjectLayout(logOut);
    if (objClassOff_ < 0 || objNameOff_ < 0) {
        logOut += "对象布局未知，停止初始化\n";
        return false;
    }
    if (!ResolveGWorld(logOut)) return false;

    // 世界先刷一遍，ComponentToWorld 探测需要有角色在场
    UpdateActorList();
    ResolveComponentToWorld(logOut);

    ready_ = true;
    logOut += "初始化完成\n";
    return true;
}

void Engine::Shutdown() {
    ready_ = false;
    actorList_.clear();
    classCache_.clear();
    skelCache_.clear();
    reader_.Detach();
    {
        std::lock_guard<std::mutex> lock(nameMutex_);
        nameCache_.clear();
    }
    std::lock_guard<std::mutex> lock(snapMutex_);
    snap_ = Snapshot{};
}

void Engine::SetOffsets(const Offsets& o) {
    off_ = o;
    // 手动改了 RVA 就要重新 Bootstrap
    compToWorldOff_ = o.sceneComponentToWorld > 0 ? o.sceneComponentToWorld : -1;
    boneArrayOff_ = o.meshBoneTransforms;
}

// ---------------------------------------------------------------------------
// 角色过滤
// ---------------------------------------------------------------------------

bool Engine::IsCharacterClass(uint64_t classPtr) {
    if (!IsReadablePointer(classPtr)) return false;
    auto it = classCache_.find(classPtr);
    if (it != classCache_.end()) return it->second;

    bool match = false;
    uint64_t cls = classPtr;
    for (int depth = 0; depth < 10 && IsReadablePointer(cls); ++depth) {
        const std::string raw = NameOfObject(cls);
        if (!raw.empty()) {
            const std::string lowered = Lower(raw);
            const bool excluded = ListMatch(lowered, off_.characterClassExcludes);
            if (!excluded && ListMatch(lowered, off_.characterClassIncludes)) {
                match = true;
                break;
            }
        }
        // UStruct::SuperStruct @ +0x40
        uint64_t super = 0;
        if (!reader_.ReadPtr(cls + 0x40, super)) break;
        cls = super;
    }

    if (classCache_.size() < 20000) classCache_[classPtr] = match;
    return match;
}

// ---------------------------------------------------------------------------
// 关卡 / Actor
// ---------------------------------------------------------------------------

bool Engine::UpdateActorList() {
    actorList_.clear();
    if (!gworldAddr_) return false;

    std::vector<uint64_t> levelPtrs;

    uint64_t persistent = 0;
    if (reader_.ReadPtr(gworldAddr_ + off_.worldPersistentLevel, persistent) && IsReadablePointer(persistent)) {
        levelPtrs.push_back(persistent);
    }

    std::vector<uint64_t> levels;
    if (ReadPointerArray(reader_, gworldAddr_ + off_.worldLevels, levels, 4096)) {
        for (uint64_t l : levels) {
            if (IsReadablePointer(l)) levelPtrs.push_back(l);
        }
    }

    std::set<uint64_t> seen;
    std::vector<uint64_t> actors;
    for (uint64_t level : levelPtrs) {
        std::vector<uint64_t> list;
        if (!ReadPointerArray(reader_, level + off_.levelActors, list, 200000)) continue;
        for (uint64_t a : list) {
            if (!IsReadablePointer(a)) continue;
            if (seen.insert(a).second) actors.push_back(a);
        }
    }

    if (actors == actorList_) {
        return !actorList_.empty();          // 没变化：不用重新跑类名过滤
    }

    actorList_ = std::move(actors);

    // 在这里一次性把"哪些 Actor 是角色"筛出来，后面每帧只处理这几十个，
    // 不然每帧几千次类名解析会把 CPU 吃满。
    charActorList_.clear();
    charActorList_.reserve(64);
    for (uint64_t actor : actorList_) {
        uint64_t cls = 0;
        if (!reader_.ReadPtr(actor + objClassOff_, cls)) continue;
        if (IsCharacterClass(cls)) charActorList_.push_back(actor);
    }
    return !actorList_.empty();
}

// ---------------------------------------------------------------------------
// 骨骼
// ---------------------------------------------------------------------------

bool Engine::ResolveSkeleton(uint64_t skeletalMesh) {
    if (!IsReadablePointer(skeletalMesh)) return false;

    auto cached = skelCache_.find(skeletalMesh);
    if (cached != skelCache_.end()) return cached->second.boneCount > 0;

    std::vector<uint8_t> buf(0x2000);
    size_t size = buf.size();
    if (!reader_.Read(skeletalMesh, buf.data(), size)) {
        size = 0x1000;
        buf.resize(size);
        if (!reader_.Read(skeletalMesh, buf.data(), size)) {
            skelCache_[skeletalMesh] = SkeletonMap{};
            return false;
        }
    }

    for (size_t h = 0; h + 0x10 <= size; h += 8) {
        uint64_t data = 0;
        int32_t num = 0, max = 0;
        memcpy(&data, buf.data() + h, 8);
        memcpy(&num, buf.data() + h + 8, 4);
        memcpy(&max, buf.data() + h + 12, 4);

        if (!IsReadablePointer(data) || num < 12 || num > 1024 || max < num || max > 4096) continue;

        // FMeshBoneInfo = { FName Name(8); int32 ParentIndex(4) }  => 0xC
        std::vector<uint8_t> elems(static_cast<size_t>(num) * 0xC);
        if (!reader_.Read(data, elems.data(), elems.size())) continue;

        bool layoutOK = true;
        for (int i = 0; i < num; ++i) {
            int32_t parent = 0;
            memcpy(&parent, elems.data() + static_cast<size_t>(i) * 0xC + 8, 4);
            if (parent < -1 || parent >= num || parent == i) { layoutOK = false; break; }
        }
        if (!layoutOK) continue;

        std::vector<std::string> names(static_cast<size_t>(num));
        int bad = 0;
        for (int i = 0; i < num; ++i) {
            int32_t nameIdx = 0;
            memcpy(&nameIdx, elems.data() + static_cast<size_t>(i) * 0xC, 4);
            std::string nm;
            if (!DecodeName(static_cast<uint32_t>(nameIdx), nm) || !IsPrintableName(nm)) {
                ++bad;
                if (bad > num / 20) break;
                continue;
            }
            names[static_cast<size_t>(i)] = nm;
        }
        if (bad > num / 20) continue;

        SkeletonMap map;
        map.boneCount = num;
        map.allNames = names;
        std::vector<int> spines;
        for (int i = 0; i < num; ++i) {
            const std::string& nm = names[static_cast<size_t>(i)];
            if (nm.empty()) continue;
            map.indexToName[i] = nm;
            const std::string norm = Normalize(nm);
            if (HasSub(norm, "spine") || HasSub(norm, "spn")) {
                spines.push_back(i);
            }
            const int slot = SlotFromBoneName(nm);
            if (slot >= 0 && map.slotToBone.find(slot) == map.slotToBone.end()) {
                map.slotToBone[slot] = i;
            }
        }
        if (!spines.empty()) {
            std::sort(spines.begin(), spines.end());
            map.slotToBone[kB_Spine1] = spines.front();
            if (spines.size() >= 2) map.slotToBone[kB_Spine2] = spines[spines.size() - 2];
            if (spines.size() >= 3) map.slotToBone[kB_Spine3] = spines.back();
        }

        // 至少要有头、骨盆、左右腿，才认为这套骨架可用
        if (map.slotToBone.count(kB_Head) == 0 || map.slotToBone.count(kB_Pelvis) == 0 ||
            (map.slotToBone.count(kB_ThighL) == 0 && map.slotToBone.count(kB_ThighR) == 0)) {
            continue;
        }

        for (int i = 0; i < num && i < 12; ++i) {
            if (!names[static_cast<size_t>(i)].empty()) {
                map.rawNameDump += names[static_cast<size_t>(i)] + " ";
            }
        }

        skelCache_[skeletalMesh] = map;
        return true;
    }

    skelCache_[skeletalMesh] = SkeletonMap{};
    return false;
}

bool Engine::SampleCharacter(uint64_t actor, Entity& out) {
    if (compToWorldOff_ < 0) return false;

    uint64_t mesh = 0;
    if (!reader_.ReadPtr(actor + off_.characterMesh, mesh) || !IsReadablePointer(mesh)) return false;

    FTransform cw{};
    if (!reader_.Read(mesh + compToWorldOff_, &cw, sizeof(cw))) return false;
    if (!PlausibleTransform(cw)) return false;

    // 骨骼数组（TArray<FTransform>）
    uint64_t bonesData = 0;
    int32_t num = 0, max = 0;
    if (!reader_.Read(mesh + boneArrayOff_, &bonesData, 8)) return false;
    if (!reader_.Read(mesh + boneArrayOff_ + 8, &num, 4)) return false;
    if (!reader_.Read(mesh + boneArrayOff_ + 12, &max, 4)) return false;
    if (!IsReadablePointer(bonesData) || num < 16 || num > 1024 || num > max) return false;

    const size_t stride = static_cast<size_t>(off_.boneStride > 0 ? off_.boneStride : 0x30);
    std::vector<uint8_t> raw(static_cast<size_t>(num) * stride);
    if (!reader_.Read(bonesData, raw.data(), raw.size())) return false;

    // 取 SkeletalMesh 拿骨骼名映射
    uint64_t skelMesh = 0;
    reader_.ReadPtr(mesh + off_.meshSkeletalMesh, skelMesh);
    if (!ResolveSkeleton(skelMesh)) return false;

    const SkeletonMap& skel = skelCache_[skelMesh];
    if (skel.boneCount <= 0) return false;

    out = Entity{};
    out.actor = actor;
    out.mesh = mesh;
    out.skeletalMesh = skelMesh;
    out.rawBoneCount = num;
    out.boneIdx.fill(-1);
    out.className = ClassNameOf(actor);

    for (const auto& kv : skel.slotToBone) {
        const int slot = kv.first;
        const int idx = kv.second;
        if (slot < 0 || slot >= kB_Count || idx < 0 || idx >= num) continue;

        FTransform local{};
        memcpy(&local, raw.data() + static_cast<size_t>(idx) * stride, sizeof(FTransform));

        const Vec3 world = TransformPosition(cw, local.translation);
        if (!Finite(world)) continue;
        if (std::fabs(world.x) > 5.0e6f || std::fabs(world.y) > 5.0e6f || std::fabs(world.z) > 5.0e6f) continue;

        out.bones[slot] = world;
        out.have[slot] = 1;
        out.boneIdx[slot] = static_cast<int16_t>(idx);
        ++out.resolvedBones;
    }

    if (out.resolvedBones < 6) return false;

    out.pelvis = out.have[kB_Pelvis] ? out.bones[kB_Pelvis] : cw.translation;
    if (out.have[kB_Head] && out.have[kB_FootL]) {
        out.worldHeight = std::fabs(out.bones[kB_Head].z - out.bones[kB_FootL].z);
    }
    return true;
}

// ---------------------------------------------------------------------------
// 摄像机
// ---------------------------------------------------------------------------

uint64_t Engine::FindLocalPlayerController() {
    // 首选：GWorld -> GameInstance -> LocalPlayers[0] -> PlayerController(+0x30)
    uint64_t gi = 0;
    if (reader_.ReadPtr(gworldAddr_ + off_.worldGameInstance, gi) && IsReadablePointer(gi)) {
        std::vector<uint64_t> locals;
        if (ReadPointerArray(reader_, gi + 0x38, locals, 16) && !locals.empty()) {
            uint64_t pc = 0;
            if (reader_.ReadPtr(locals[0] + 0x30, pc) && IsReadablePointer(pc)) return pc;
        }
    }

    // 兜底：在 GObjects 里找 PlayerController（数量很少，命中的类会被缓存）
    const uint32_t total = std::min<uint32_t>(NumObjects(), 300000u);
    for (uint32_t i = 0; i < total; ++i) {
        uint64_t obj = ObjectAt(i);
        if (!obj) continue;
        uint64_t cls = 0;
        if (!reader_.ReadPtr(obj + objClassOff_, cls) || !IsReadablePointer(cls)) continue;
        const std::string cn = NameOfObject(cls);
        if (cn.empty() || cn.find("PlayerController") == std::string::npos) continue;

        // bIsLocalPlayerController @ 0x6A4
        uint8_t isLocal = 0;
        if (!reader_.Read(obj + 0x6A4, &isLocal, 1) || isLocal == 0) continue;

        uint64_t camMgr = 0;
        if (!reader_.ReadPtr(obj + off_.controllerCameraManager, camMgr) || !IsReadablePointer(camMgr)) continue;
        return obj;
    }
    return 0;
}

bool Engine::UpdateCamera(Camera& cam) {
    cam = Camera{};
    GetViewportSize(&cam.screenW, &cam.screenH);
    if (cam.screenW <= 0 || cam.screenH <= 0) return false;

    const uint64_t now = NowMs();
    if (!IsReadablePointer(localController_) || now - lastControllerScanMs_ > 5000) {
        localController_ = FindLocalPlayerController();
        lastControllerScanMs_ = now;
    }
    if (!IsReadablePointer(localController_)) return false;

    Rot3 rot{};
    if (!reader_.Read(localController_ + off_.controllerControlRot, &rot, sizeof(rot))) return false;
    if (!Finite(rot.pitch) || std::fabs(rot.pitch) > 90.5f || std::fabs(rot.yaw) > 400.f) return false;
    cam.rotation = rot;

    uint64_t camMgr = 0;
    reader_.ReadPtr(localController_ + off_.controllerCameraManager, camMgr);

    // FOV 在 CameraCache.POV.FOV（POV 相对 CacheEntry 偏移 0x10），是明文 float
    float fov = 0.f;
    if (IsReadablePointer(camMgr)) {
        reader_.Read(camMgr + off_.camCache + 0x10 + off_.camPovFov, &fov, 4);
    }
    if (!(fov >= 30.f && fov <= 140.f)) fov = 90.f;
    cam.fovHorizontalDeg = fov;

    // 位置：优先摄像机管理器根组件，其次本地角色 Mesh + 眼睛高度
    Vec3 loc{};
    bool haveLoc = false;

    if (IsReadablePointer(camMgr) && compToWorldOff_ > 0) {
        uint64_t root = 0;
        if (reader_.ReadPtr(camMgr + off_.actorRootComponent, root) && IsReadablePointer(root)) {
            FTransform t{};
            if (reader_.Read(root + compToWorldOff_, &t, sizeof(t)) && PlausibleTransform(t)) {
                loc = t.translation;
                haveLoc = true;
            }
        }
        if (!haveLoc) {
            uint64_t tc = 0;
            if (reader_.ReadPtr(camMgr + off_.camTransformComp, tc) && IsReadablePointer(tc)) {
                FTransform t{};
                if (reader_.Read(tc + compToWorldOff_, &t, sizeof(t)) && PlausibleTransform(t)) {
                    loc = t.translation;
                    haveLoc = true;
                }
            }
        }
    }

    if (!haveLoc) {
        uint64_t pawn = 0;
        if (!reader_.ReadPtr(localController_ + off_.controllerPawn, pawn) || !IsReadablePointer(pawn)) return false;
        uint64_t mesh = 0;
        if (!reader_.ReadPtr(pawn + off_.characterMesh, mesh) || !IsReadablePointer(mesh)) return false;
        FTransform t{};
        if (!reader_.Read(mesh + compToWorldOff_, &t, sizeof(t)) || !PlausibleTransform(t)) return false;

        float eye = 0.f;
        reader_.Read(pawn + 0x37C, &eye, 4);      // APawn::BaseEyeHeight
        if (!(eye >= 20.f && eye <= 140.f)) eye = 64.f;

        loc = t.translation;
        loc.z += eye;
        haveLoc = true;
    }

    if (!haveLoc || !Finite(loc)) return false;
    cam.location = loc;
    cam.valid = true;
    return true;
}

// ---------------------------------------------------------------------------
// 每帧采样
// ---------------------------------------------------------------------------

void Engine::Tick() {
    if (!ready_) return;

    const uint64_t tickStart = NowMs();
    const uint64_t now = tickStart;

    // 大厅 -> 对局：GWorld 会换成另一个 UWorld，重新解引用，否则一直在读旧世界
    if (gworldSlotAddr_) {
        uint64_t live = 0;
        if (reader_.ReadPtr(gworldSlotAddr_, live) && IsReadablePointer(live) && live != gworldAddr_) {
            gworldAddr_ = live;
            actorList_.clear();
            charActorList_.clear();
            lastActorScanMs_ = 0;
            localController_ = 0;
            lastControllerScanMs_ = 0;
        }
    }

    if (now - lastActorScanMs_ > 250 || actorList_.empty()) {
        UpdateActorList();
        lastActorScanMs_ = now;
    }

    // ComponentToWorld 是懒探测：大厅里没角色探不到，进对局后自动补
    if (compToWorldOff_ < 0 && now - lastCtwAttemptMs_ > 2000) {
        lastCtwAttemptMs_ = now;
        std::string ignored;
        ResolveComponentToWorld(ignored);
    }

    Camera cam;
    const bool camOK = UpdateCamera(cam);

    // 自己的角色不画（本地 Pawn）
    uint64_t localPawn = 0;
    if (IsReadablePointer(localController_)) {
        reader_.ReadPtr(localController_ + off_.controllerPawn, localPawn);
    }

    std::vector<Entity> ents;
    const int chars = static_cast<int>(charActorList_.size());
    int fail = 0;

    for (uint64_t actor : charActorList_) {
        if (actor == localPawn) continue;
        Entity e;
        if (SampleCharacter(actor, e)) {
            if (camOK) {
                const Vec3 d = e.pelvis - cam.location;
                e.distance = Length(d) / 100.f;              // UE 单位 cm -> m
                // 距离过滤交给渲染层（菜单里拖动滑条要实时生效）
            }
            ents.push_back(e);
        } else {
            ++fail;
        }
    }

    if (camOK) {
        std::sort(ents.begin(), ents.end(), [](const Entity& a, const Entity& b) {
            return a.distance < b.distance;
        });
    }

    Snapshot s;
    s.camera = cam;
    s.entities = std::move(ents);
    s.scannedActors = static_cast<int>(actorList_.size());
    s.characterActors = chars;
    s.boneFailures = fail;
    s.stampMs = now;

    // ---- 调试数据 ----
    s.diag.pid = reader_.Pid();
    s.diag.base = base_;
    s.diag.gobjects = gobjectsAddr_;
    s.diag.gnames = gnamesAddr_;
    s.diag.gworld = gworldAddr_;
    s.diag.objClass = objClassOff_;
    s.diag.objName = objNameOff_;
    s.diag.nameBlocks = nameBlocksOffset_;
    s.diag.nameHeader = nameHeaderSize_;
    s.diag.nameScale = nameOffsetScale_;
    s.diag.compToWorld = compToWorldOff_;
    s.diag.boneArray = boneArrayOff_;
    s.diag.numObjects = NumObjects();
    s.diag.actorCount = s.scannedActors;
    s.diag.charCount = s.characterActors;
    s.diag.boneFail = s.boneFailures;
    s.diag.tickMs = static_cast<float>(NowMs() - tickStart);

    if (debugFill_.load() && !s.entities.empty()) {
        int idx = debugTarget_.load();
        if (idx < 0) idx = 0;
        if (idx >= static_cast<int>(s.entities.size())) idx = static_cast<int>(s.entities.size()) - 1;

        const Entity& e = s.entities[static_cast<size_t>(idx)];
        s.debugEntity = e.actor;
        s.debugEntityClass = e.className;

        auto skelIt = skelCache_.find(e.skeletalMesh);
        if (skelIt != skelCache_.end()) {
            s.debugSkeleton = skelIt->second.allNames;
            s.debugBones.reserve(kB_Count);
            for (int slot = 0; slot < kB_Count; ++slot) {
                if (!e.have[slot]) continue;
                BoneDebugRow row;
                row.slot = slot;
                row.index = e.boneIdx[slot];
                auto nameIt = skelIt->second.indexToName.find(row.index);
                if (nameIt != skelIt->second.indexToName.end()) row.name = nameIt->second;
                row.world = e.bones[slot];
                s.debugBones.push_back(std::move(row));
            }
        }
    }

    std::lock_guard<std::mutex> lock(snapMutex_);
    snap_ = std::move(s);
}

void Engine::SetDebugTarget(int entityIndex, bool fill) {
    debugTarget_ = entityIndex;
    debugFill_ = fill;
}

Snapshot Engine::CopySnapshot() const {
    std::lock_guard<std::mutex> lock(snapMutex_);
    return snap_;
}

std::string Engine::ProbeReport() {
    std::string out;
    char buf[256];

    snprintf(buf, sizeof(buf), "pid=%d base=0x%llX\n", reader_.Pid(),
             static_cast<unsigned long long>(base_));
    out += buf;
    snprintf(buf, sizeof(buf), "GObjects@0x%llX GNames@0x%llX GWorld=0x%llX\n",
             static_cast<unsigned long long>(gobjectsAddr_),
             static_cast<unsigned long long>(gnamesAddr_),
             static_cast<unsigned long long>(gworldAddr_));
    out += buf;
    snprintf(buf, sizeof(buf), "obj: Class+0x%X Name+0x%X | namePool blocks+0x%X hdr=%d scale=%d\n",
             objClassOff_, objNameOff_, nameBlocksOffset_, nameHeaderSize_, nameOffsetScale_);
    out += buf;
    snprintf(buf, sizeof(buf), "ComponentToWorld=+0x%X boneArray=+0x%X\n", compToWorldOff_, boneArrayOff_);
    out += buf;
    snprintf(buf, sizeof(buf), "objects=%u actors=%zu\n", NumObjects(), actorList_.size());
    out += buf;

    return out;
}

} // namespace esp
