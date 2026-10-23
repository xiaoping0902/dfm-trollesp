//
//  debug.hpp
//  DFM TrollESP —— ImGui 调试窗口（骨骼表 / 世界坐标 / 屏幕坐标 / 射线）
//

#pragma once

#include "esp_core.hpp"

struct ImDrawList;
struct ImVec2;

namespace esp {

struct DebugOptions {
    bool windowOpen   = false;   // 调试窗口
    bool boneLabels   = false;   // 屏幕上标 骨骼名(下标)
    bool boneRays     = false;   // 屏幕中心 -> 每根骨骼 的视线
    bool aimRay       = false;   // 准心前向射线（3D）
    bool showAllBones = false;   // 展开整套骨架名单
};

const char *BoneSlotName(int slot);

// 画调试窗口；targetIndex 可被界面改（选择第几个角色）
void DrawDebugWindow(const Snapshot &snap, DebugOptions &opt, int &targetIndex);

// 画到 ESP 层上面（骨骼标号 / 射线）
void DrawDebugOverlay(ImDrawList *dl, const Snapshot &snap, const DebugOptions &opt, ImVec2 display,
                      int targetIndex);

} // namespace esp
