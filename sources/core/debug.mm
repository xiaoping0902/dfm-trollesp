//
//  debug.mm
//  DFM TrollESP —— ImGui 调试窗口
//
//  这一屏就是给你“看着数字调试”用的：
//    * 连接信息：pid / 模块基址 / GObjects / GNames / 各字段偏移 / 对象数
//    * 采样信息：Actor 数 / 角色数 / 骨骼失败数 / 单次 Tick 耗时 / 摄像机
//    * 目标角色：地址 / 类名 / 骨骼数，逐根骨骼的「槽位 / 骨名 / 下标 / 世界坐标 / 屏幕坐标 / 深度」
//    * 整套骨架名单（看到底是 Bip001 还是 head/neck_01 命名）
//    * 辅助绘制：骨骼标号、屏幕中心到每根骨骼的视线、准心 3D 前向射线
//

#include "debug.hpp"

#include <cmath>
#include <cstdio>
#include <cstddef>
#include <string>

#include "imgui.h"

namespace esp {

namespace {

const char *const kSlotNames[kB_Count] = {
    "Pelvis", "Spine1", "Spine2", "Spine3", "Neck", "Head",
    "ClavL", "UpperArmL", "LowerArmL", "HandL",
    "ClavR", "UpperArmR", "LowerArmR", "HandR",
    "ThighL", "CalfL", "FootL",
    "ThighR", "CalfR", "FootR",
};

bool BeginTwoColumn(const char *id) {
    if (!ImGui::BeginTable(id, 2, ImGuiTableFlags_Borders | ImGuiTableFlags_RowBg)) return false;
    ImGui::TableSetupColumn("k", ImGuiTableColumnFlags_WidthFixed, 170.f);
    ImGui::TableSetupColumn("v");
    return true;
}

void KeyValue(const char *key, const char *value) {
    ImGui::TableNextRow();
    ImGui::TableSetColumnIndex(0);
    ImGui::TextUnformatted(key);
    ImGui::TableSetColumnIndex(1);
    ImGui::TextUnformatted(value);
}

} // namespace

const char *BoneSlotName(int slot) {
    if (slot < 0 || slot >= kB_Count) return "?";
    return kSlotNames[slot];
}

void DrawDebugWindow(const Snapshot &snap, DebugOptions &opt, int &targetIndex) {
    if (!opt.windowOpen) return;

    ImGui::SetNextWindowSize(ImVec2(560, 660), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(540, 50), ImGuiCond_FirstUseEver);

    if (!ImGui::Begin(u8"调试 Debug — 骨骼 / 射线 / 引擎状态", &opt.windowOpen)) {
        ImGui::End();
        return;
    }

    const Diag &d = snap.diag;

    // ---------------- 引擎状态 ----------------
    if (ImGui::CollapsingHeader(u8"引擎 / 连接", ImGuiTreeNodeFlags_DefaultOpen)) {
        if (BeginTwoColumn("diag_table")) {
            char buf[256];

            snprintf(buf, sizeof(buf), "%d", d.pid);
            KeyValue("pid", buf);
            snprintf(buf, sizeof(buf), "0x%llX", (unsigned long long)d.base);
            KeyValue("module base", buf);
            snprintf(buf, sizeof(buf), "0x%llX", (unsigned long long)d.gobjects);
            KeyValue("GObjects", buf);
            snprintf(buf, sizeof(buf), "0x%llX", (unsigned long long)d.gnames);
            KeyValue("GNames", buf);
            snprintf(buf, sizeof(buf), "0x%llX", (unsigned long long)d.gworld);
            KeyValue("GWorld", buf);
            snprintf(buf, sizeof(buf), "Class+0x%X  Name+0x%X", d.objClass, d.objName);
            KeyValue(u8"UObject 布局", buf);
            snprintf(buf, sizeof(buf), "blocks+0x%X  hdr=%d  scale=%d", d.nameBlocks, d.nameHeader,
                     d.nameScale);
            KeyValue(u8"FName 池", buf);
            snprintf(buf, sizeof(buf), "+0x%X", d.compToWorld);
            KeyValue(u8"ComponentToWorld", buf);
            snprintf(buf, sizeof(buf), "+0x%X", d.boneArray);
            KeyValue(u8"骨骼数组偏移", buf);
            snprintf(buf, sizeof(buf), "%u", d.numObjects);
            KeyValue(u8"UObject 总数", buf);

            ImGui::EndTable();
        }
    }

    // ---------------- 采样 / 摄像机 ----------------
    if (ImGui::CollapsingHeader(u8"采样 / 摄像机", ImGuiTreeNodeFlags_DefaultOpen)) {
        if (BeginTwoColumn("sample_table")) {
            char buf[256];

            snprintf(buf, sizeof(buf), "%d  (角色 %d)", d.actorCount, d.charCount);
            KeyValue("Actor 数", buf);
            snprintf(buf, sizeof(buf), "%d", d.boneFail);
            KeyValue(u8"骨骼采样失败", buf);
            snprintf(buf, sizeof(buf), "%.2f ms", d.tickMs);
            KeyValue(u8"Tick 耗时", buf);
            snprintf(buf, sizeof(buf), "%zu", snap.entities.size());
            KeyValue(u8"可绘制人数", buf);

            if (snap.camera.valid) {
                snprintf(buf, sizeof(buf), "%.1f, %.1f, %.1f", snap.camera.location.x,
                         snap.camera.location.y, snap.camera.location.z);
                KeyValue(u8"相机位置", buf);
                snprintf(buf, sizeof(buf), "P%.2f  Y%.2f  R%.2f", snap.camera.rotation.pitch,
                         snap.camera.rotation.yaw, snap.camera.rotation.roll);
                KeyValue(u8"相机旋转", buf);
                snprintf(buf, sizeof(buf), "%.1f°  (%dx%d)", snap.camera.fovHorizontalDeg,
                         snap.camera.screenW, snap.camera.screenH);
                KeyValue(u8"FOV / 视口", buf);
            } else {
                KeyValue(u8"相机", u8"不可用（没找到本地 PlayerController）");
            }

            ImGui::EndTable();
        }
    }

    // ---------------- 目标角色 ----------------
    ImGui::Separator();

    if (snap.entities.empty()) {
        ImGui::TextColored(ImVec4(1.f, 0.6f, 0.3f, 1.f), u8"当前没有可调试的角色");
        ImGui::End();
        return;
    }

    if (targetIndex < 0) targetIndex = 0;
    if (targetIndex >= static_cast<int>(snap.entities.size())) {
        targetIndex = static_cast<int>(snap.entities.size()) - 1;
    }

    char preview[160];
    snprintf(preview, sizeof(preview), "#%d  %.0fm  %s", targetIndex,
             snap.entities[(size_t)targetIndex].distance,
             snap.entities[(size_t)targetIndex].className.c_str());

    ImGui::SetNextItemWidth(340);
    if (ImGui::BeginCombo(u8"调试目标", preview)) {
        for (int i = 0; i < static_cast<int>(snap.entities.size()) && i < 64; ++i) {
            char item[160];
            snprintf(item, sizeof(item), "#%d  %.0fm  %s", i, snap.entities[(size_t)i].distance,
                     snap.entities[(size_t)i].className.c_str());
            if (ImGui::Selectable(item, i == targetIndex)) targetIndex = i;
        }
        ImGui::EndCombo();
    }

    const Entity &e = snap.entities[(size_t)targetIndex];
    ImGui::Text(u8"actor=0x%llX  mesh=0x%llX", (unsigned long long)e.actor,
                (unsigned long long)e.mesh);
    ImGui::Text(u8"class=%s  skel=0x%llX  bones=%d（已映射 %d）", e.className.c_str(),
                (unsigned long long)e.skeletalMesh, e.rawBoneCount, e.resolvedBones);

    ImGui::Checkbox(u8"骨骼标号", &opt.boneLabels);
    ImGui::SameLine();
    ImGui::Checkbox(u8"骨骼射线", &opt.boneRays);
    ImGui::SameLine();
    ImGui::Checkbox(u8"准心射线", &opt.aimRay);

    // 语义骨骼表
    if (ImGui::BeginTable("bones", 6,
                          ImGuiTableFlags_Borders | ImGuiTableFlags_RowBg | ImGuiTableFlags_ScrollY,
                          ImVec2(0, 230))) {
        ImGui::TableSetupColumn(u8"槽位", ImGuiTableColumnFlags_WidthFixed, 74.f);
        ImGui::TableSetupColumn(u8"骨名");
        ImGui::TableSetupColumn("idx", ImGuiTableColumnFlags_WidthFixed, 38.f);
        ImGui::TableSetupColumn(u8"世界 X/Y/Z");
        ImGui::TableSetupColumn(u8"屏幕 X/Y");
        ImGui::TableSetupColumn("depth", ImGuiTableColumnFlags_WidthFixed, 56.f);
        ImGui::TableHeadersRow();

        for (const BoneDebugRow &row : snap.debugBones) {
            ImGui::TableNextRow();

            ImGui::TableSetColumnIndex(0);
            ImGui::TextUnformatted(BoneSlotName(row.slot));

            ImGui::TableSetColumnIndex(1);
            ImGui::TextUnformatted(row.name.empty() ? "-" : row.name.c_str());

            ImGui::TableSetColumnIndex(2);
            ImGui::Text("%d", row.index);

            ImGui::TableSetColumnIndex(3);
            ImGui::Text("%.0f, %.0f, %.0f", row.world.x, row.world.y, row.world.z);

            ImGui::TableSetColumnIndex(4);
            float sx = 0.f, sy = 0.f, depth = 0.f;
            if (WorldToScreen(snap.camera, row.world, sx, sy, &depth)) {
                ImGui::Text("%.0f, %.0f", sx, sy);
            } else {
                ImGui::TextDisabled(u8"屏外");
            }

            ImGui::TableSetColumnIndex(5);
            ImGui::Text("%.0f", depth);
        }
        ImGui::EndTable();
    }

    if (snap.debugBones.empty()) {
        ImGui::TextColored(ImVec4(1.f, 0.55f, 0.35f, 1.f),
                           u8"没拿到骨骼明细：看上面 ComponentToWorld / 骨骼数组偏移是否正确");
    }

    // 整套骨架名单
    ImGui::Checkbox(u8"展开整套骨架名单", &opt.showAllBones);
    if (opt.showAllBones) {
        ImGui::BeginChild("allbones", ImVec2(0, 150), true, ImGuiWindowFlags_HorizontalScrollbar);
        for (size_t i = 0; i < snap.debugSkeleton.size(); ++i) {
            if (snap.debugSkeleton[i].empty()) continue;
            ImGui::Text("%3zu: %s", i, snap.debugSkeleton[i].c_str());
        }
        ImGui::EndChild();
    }

    ImGui::End();
}

void DrawDebugOverlay(ImDrawList *dl, const Snapshot &snap, const DebugOptions &opt, ImVec2 display,
                      int targetIndex) {
    if (!dl) return;
    if (!opt.boneLabels && !opt.boneRays && !opt.aimRay) return;
    if (!snap.camera.valid) return;

    const Camera &cam = snap.camera;
    const float W = display.x;
    const float H = display.y;

    const ImU32 colRay = IM_COL32(255, 210, 80, 110);
    const ImU32 colAim = IM_COL32(255, 90, 90, 200);
    const ImU32 colText = IM_COL32(255, 235, 150, 235);

    // 准心 3D 前向射线
    if (opt.aimRay) {
        Vec3 fwd, right, up;
        RotatorToAxes(cam.rotation, fwd, right, up);
        const Vec3 tip = cam.location + fwd * 4000.f;      // 40 米
        float sx = 0.f, sy = 0.f;
        if (WorldToScreen(cam, tip, sx, sy)) {
            dl->AddLine(ImVec2(W * 0.5f, H * 0.5f), ImVec2(sx, sy), colAim, 1.6f);
            dl->AddCircleFilled(ImVec2(sx, sy), 3.f, colAim);
        }
    }

    if (snap.entities.empty()) return;

    if (targetIndex < 0) targetIndex = 0;
    if (targetIndex >= static_cast<int>(snap.entities.size())) {
        targetIndex = static_cast<int>(snap.entities.size()) - 1;
    }
    const Entity &e = snap.entities[(size_t)targetIndex];

    for (int slot = 0; slot < kB_Count; ++slot) {
        if (!e.have[slot]) continue;
        float sx = 0.f, sy = 0.f;
        if (!WorldToScreen(cam, e.bones[slot], sx, sy)) continue;

        if (opt.boneRays) {
            dl->AddLine(ImVec2(W * 0.5f, H * 0.5f), ImVec2(sx, sy), colRay, 1.0f);
        }
        if (opt.boneLabels) {
            char label[64];
            snprintf(label, sizeof(label), "%s(%d)", BoneSlotName(slot), (int)e.boneIdx[slot]);
            dl->AddText(ImVec2(sx + 5.f, sy - 6.f), IM_COL32(0, 0, 0, 180), label);
            dl->AddText(ImVec2(sx + 4.f, sy - 7.f), colText, label);
        }
    }
}

} // namespace esp
