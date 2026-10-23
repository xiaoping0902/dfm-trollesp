//
//  draw.cpp
//  DFM TrollESP —— ESP 绘制 + ImGui 菜单
//

#include "draw.hpp"

#include <algorithm>
#include <cfloat>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "imgui.h"
#include "buildtag.h"

namespace esp {

namespace {

void DrawSkeletonLines(ImDrawList *dl, const std::array<Vec3, kB_Count> &bones,
                       const std::array<uint8_t, kB_Count> &have, const Camera &cam,
                       ImU32 color, float thickness) {
    for (int i = 0; i < kSkeletonLinkCount; ++i) {
        const int a = kSkeletonLinks[i].a;
        const int b = kSkeletonLinks[i].b;
        if (!have[a] || !have[b]) continue;

        float ax, ay, bx, by;
        if (!WorldToScreen(cam, bones[a], ax, ay)) continue;
        if (!WorldToScreen(cam, bones[b], bx, by)) continue;
        dl->AddLine(ImVec2(ax, ay), ImVec2(bx, by), color, thickness);
    }
}

} // namespace

void DrawESP(ImDrawList *dl, const Snapshot &snap, const EspSettings &s, ImVec2 display) {
    if (!dl || !snap.camera.valid) return;

    const Camera &cam = snap.camera;
    const float W = display.x;
    const float H = display.y;

    const ImU32 colSkeleton = ImGui::ColorConvertFloat4ToU32(
        ImVec4(s.colorSkeleton[0], s.colorSkeleton[1], s.colorSkeleton[2], s.colorSkeleton[3]));
    const ImU32 colBox = ImGui::ColorConvertFloat4ToU32(
        ImVec4(s.colorBox[0], s.colorBox[1], s.colorBox[2], s.colorBox[3]));
    const ImU32 colSnapline = ImGui::ColorConvertFloat4ToU32(
        ImVec4(s.colorSnapline[0], s.colorSnapline[1], s.colorSnapline[2], s.colorSnapline[3]));
    const ImU32 colText = ImGui::ColorConvertFloat4ToU32(
        ImVec4(s.colorText[0], s.colorText[1], s.colorText[2], s.colorText[3]));

    for (const Entity &e : snap.entities) {
        if (s.maxDistance > 0.f && e.distance > s.maxDistance) continue;

        // 先把所有骨骼投到屏幕
        std::array<ImVec2, kB_Count> pts{};
        std::array<uint8_t, kB_Count> ok{};
        float minX = FLT_MAX, maxX = -FLT_MAX, minY = FLT_MAX, maxY = -FLT_MAX;
        int onScreen = 0;

        for (int i = 0; i < kB_Count; ++i) {
            if (!e.have[i]) continue;
            float x, y;
            if (!WorldToScreen(cam, e.bones[i], x, y)) continue;
            pts[i] = ImVec2(x, y);
            ok[i] = 1;
            ++onScreen;
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
        }

        if (onScreen < 3) continue;
        // 整块都在屏幕外就不画（等价于旧版的 requireVisible）
        if (maxX < 0.f || minX > W || maxY < 0.f || minY > H) continue;

        // ---- 2D 方框 ----
        float boxTop = minY;
        float boxBottom = maxY;
        float boxW = 0.f;

        if (ok[kB_Head]) {
            const float headPad = std::max(6.f, (maxY - minY) * 0.06f);
            boxTop = std::min(boxTop, pts[kB_Head].y - headPad);
        }
        if (ok[kB_ClavL] && ok[kB_ClavR]) {
            boxW = std::fabs(pts[kB_ClavR].x - pts[kB_ClavL].x) * 1.45f;
        }
        if (boxW <= 1.f) {
            boxW = (boxBottom - boxTop) * 0.52f;
        }
        const float boxH = std::max(8.f, boxBottom - boxTop);
        const float boxCx = (ok[kB_Head] && ok[kB_Pelvis])
                                ? (pts[kB_Head].x + pts[kB_Pelvis].x) * 0.5f
                                : (minX + maxX) * 0.5f;

        if (s.drawFilledBox && s.drawBox) {
            dl->AddRectFilled(ImVec2(boxCx - boxW * 0.5f, boxTop),
                              ImVec2(boxCx + boxW * 0.5f, boxTop + boxH),
                              ImGui::ColorConvertFloat4ToU32(
                                  ImVec4(s.colorBox[0], s.colorBox[1], s.colorBox[2], 0.12f)));
        }
        if (s.drawBox) {
            dl->AddRect(ImVec2(boxCx - boxW * 0.5f, boxTop),
                        ImVec2(boxCx + boxW * 0.5f, boxTop + boxH),
                        colBox, 0.f, 0, s.boxThickness);
        }

        // ---- 骨骼 ----
        if (s.drawSkeleton) {
            DrawSkeletonLines(dl, e.bones, e.have, cam, colSkeleton, s.lineThickness);
        }

        if (s.drawBoneJoints) {
            for (int i = 0; i < kB_Count; ++i) {
                if (!ok[i]) continue;
                dl->AddCircleFilled(pts[i], std::max(1.5f, s.lineThickness), colSkeleton);
            }
        }

        // ---- 头 ----
        if (s.drawHeadDot && ok[kB_Head]) {
            const float r = std::max(3.f, boxW * 0.13f);
            dl->AddCircle(pts[kB_Head], r, colSkeleton, 0, s.lineThickness);
        }

        // ---- 准心连线 ----
        if (s.drawSnapline) {
            dl->AddLine(ImVec2(W * 0.5f, H), ImVec2(boxCx, boxTop + boxH), colSnapline,
                        std::max(1.f, s.lineThickness * 0.75f));
        }

        // ---- 距离 ----
        if (s.drawDistance) {
            char label[64];
            snprintf(label, sizeof(label), "%.0fm", e.distance * 1.f);
            const ImVec2 size = ImGui::CalcTextSize(label);
            const float tx = boxCx - size.x * 0.5f;
            const float ty = boxTop + boxH + 2.f;
            dl->AddText(ImVec2(tx + 1.f, ty + 1.f), IM_COL32(0, 0, 0, 200), label);
            dl->AddText(ImVec2(tx, ty), colText, label);
        }
    }
}

// ---------------------------------------------------------------------------
// 菜单
// ---------------------------------------------------------------------------

namespace {

struct OffsetBuffers {
    char gobjects[24] = {0};
    char gnames[24] = {0};
    char gworld[24] = {0};
    char characterMesh[12] = {0};
    char boneArray[12] = {0};
    char componentToWorld[12] = {0};
    bool inited = false;
};

OffsetBuffers gBuf;

void SyncOffsetBuffers(const Offsets &o) {
    snprintf(gBuf.gobjects, sizeof(gBuf.gobjects), "0x%llX", (unsigned long long)o.rvaGObjects);
    snprintf(gBuf.gnames, sizeof(gBuf.gnames), "0x%llX", (unsigned long long)o.rvaGNames);
    snprintf(gBuf.gworld, sizeof(gBuf.gworld), "0x%llX", (unsigned long long)o.rvaGWorld);
    snprintf(gBuf.characterMesh, sizeof(gBuf.characterMesh), "0x%X", o.characterMesh);
    snprintf(gBuf.boneArray, sizeof(gBuf.boneArray), "0x%X", o.meshBoneTransforms);
    snprintf(gBuf.componentToWorld, sizeof(gBuf.componentToWorld), "0x%X", o.sceneComponentToWorld);
    gBuf.inited = true;
}

unsigned long long ParseHex(const char *text, unsigned long long fallback) {
    if (!text || !*text) return fallback;
    char *end = nullptr;
    unsigned long long v = strtoull(text, &end, 0);
    return (end && end != text) ? v : fallback;
}

void HelpMarker(const char *text) {
    ImGui::SameLine();
    ImGui::TextDisabled("(?)");
    if (ImGui::IsItemHovered()) {
        ImGui::BeginTooltip();
        ImGui::PushTextWrapPos(ImGui::GetFontSize() * 28.f);
        ImGui::TextUnformatted(text);
        ImGui::PopTextWrapPos();
        ImGui::EndTooltip();
    }
}

} // namespace

MenuResult DrawMenu(EspSettings &s, Offsets &o, const Snapshot &snap, const std::string &bootLog,
                    const std::string &probe, bool engineReady, int targetPid,
                    unsigned long long moduleBase, DebugOptions &dbg) {
    MenuResult r;
    if (!gBuf.inited) SyncOffsetBuffers(o);

    ImGui::SetNextWindowSize(ImVec2(470, 620), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(60, 80), ImGuiCond_FirstUseEver);

    if (!ImGui::Begin(u8"三角洲 TrollESP  ·  " ESP_BUILD_TAG, nullptr,
                      ImGuiWindowFlags_NoCollapse)) {
        ImGui::End();
        return r;
    }

    // ---- 状态 ----
    if (engineReady) {
        ImGui::TextColored(ImVec4(0.3f, 1.f, 0.4f, 1.f),
                           u8"已连接  pid=%d  base=0x%llX", targetPid, moduleBase);
        ImGui::Text(u8"Actor %d | 角色 %d | 骨骼失败 %d | 绘制 %zu",
                    snap.scannedActors, snap.characterActors, snap.boneFailures,
                    snap.entities.size());
        if (snap.camera.valid) {
            ImGui::Text(u8"摄像机 (%.0f, %.0f, %.0f)  FOV %.0f  视口 %dx%d",
                        snap.camera.location.x, snap.camera.location.y, snap.camera.location.z,
                        snap.camera.fovHorizontalDeg, snap.camera.screenW, snap.camera.screenH);
        } else {
            ImGui::TextColored(ImVec4(1.f, 0.7f, 0.2f, 1.f), u8"摄像机构图不可用");
        }
    } else {
        ImGui::TextColored(ImVec4(1.f, 0.35f, 0.35f, 1.f), u8"未连接游戏");
    }

    if (ImGui::Button(u8"重新初始化 Reinit")) r.reinit = true;
    ImGui::SameLine();
    if (ImGui::Button(u8"保存 Save")) r.save = true;
    ImGui::SameLine();
    if (ImGui::Button(u8"关闭菜单 Close")) r.close = true;
    ImGui::SameLine();
    if (ImGui::Button(u8"● 收起成球 Collapse")) r.collapse = true;

    ImGui::Separator();

    // ---- 调试窗口入口 ----
    ImGui::Checkbox(u8"调试窗口 Debug", &dbg.windowOpen);
    ImGui::SameLine();
    HelpMarker(u8"引擎偏移、Actor/角色数、逐根骨骼的世界/屏幕坐标、骨架命名、"
               u8"Tick 耗时都在这。勾上后还能在屏幕上打骨骼标号、画视线/准心射线。");

    ImGui::Separator();

    // ---- 开关 ----
    ImGui::Checkbox(u8"总开关 Enable", &s.enabled);
    ImGui::SameLine();
    ImGui::Checkbox(u8"骨骼 Skeleton", &s.drawSkeleton);
    ImGui::SameLine();
    ImGui::Checkbox(u8"方框 Box", &s.drawBox);
    ImGui::Checkbox(u8"头部 Head", &s.drawHeadDot);
    ImGui::SameLine();
    ImGui::Checkbox(u8"距离 Distance", &s.drawDistance);
    ImGui::Checkbox(u8"准心线 Snapline", &s.drawSnapline);
    ImGui::SameLine();
    ImGui::Checkbox(u8"关节点 Joints", &s.drawBoneJoints);
    ImGui::Checkbox(u8"填充 Fill", &s.drawFilledBox);

    ImGui::SliderFloat(u8"最大距离 (m)", &s.maxDistance, 20.f, 1500.f, "%.0f");
    ImGui::SliderFloat(u8"线宽 Line", &s.lineThickness, 0.5f, 5.f, "%.1f");
    ImGui::SliderFloat(u8"框宽 Box", &s.boxThickness, 0.5f, 5.f, "%.1f");

    ImGui::ColorEdit4(u8"骨骼颜色", s.colorSkeleton);
    ImGui::ColorEdit4(u8"方框颜色", s.colorBox);
    ImGui::ColorEdit4(u8"准心颜色", s.colorSnapline);

    ImGui::SliderInt(u8"采样频率 Hz", &s.sampleHz, 15, 120);

    ImGui::Checkbox(u8"悬浮球 Ball", &s.showBall);
    ImGui::SameLine();
    ImGui::SetNextItemWidth(160);
    ImGui::SliderFloat(u8"球大小", &s.ballRadius, 16.f, 56.f, "%.0f");
    o.maxDistance = s.maxDistance;

    if (ImGui::CollapsingHeader(u8"偏移 / 换游戏适配")) {
        ImGui::TextUnformatted(u8"RVA 相对主程序 __TEXT 基址");
        ImGui::InputText(u8"GObjects", gBuf.gobjects, sizeof(gBuf.gobjects));
        ImGui::InputText(u8"GNames", gBuf.gnames, sizeof(gBuf.gnames));
        ImGui::InputText(u8"GWorld", gBuf.gworld, sizeof(gBuf.gworld));
        ImGui::TextUnformatted(u8"字段偏移（十六进制）");
        ImGui::InputText(u8"角色 Mesh", gBuf.characterMesh, sizeof(gBuf.characterMesh));
        ImGui::InputText(u8"骨骼数组", gBuf.boneArray, sizeof(gBuf.boneArray));
        ImGui::InputText(u8"ComponentToWorld", gBuf.componentToWorld, sizeof(gBuf.componentToWorld));
        HelpMarker(u8"ComponentToWorld 填 0 表示自动探测；骨骼数组默认 0xA18"
                   u8"（CachedComponentSpaceTransforms），失败时试 0xA08。");

        if (ImGui::Button(u8"应用偏移 Apply")) {
            o.rvaGObjects = ParseHex(gBuf.gobjects, o.rvaGObjects);
            o.rvaGNames = ParseHex(gBuf.gnames, o.rvaGNames);
            o.rvaGWorld = ParseHex(gBuf.gworld, o.rvaGWorld);
            o.characterMesh = (int32_t)ParseHex(gBuf.characterMesh, (unsigned long long)o.characterMesh);
            o.meshBoneTransforms = (int32_t)ParseHex(gBuf.boneArray, (unsigned long long)o.meshBoneTransforms);
            o.sceneComponentToWorld = (int32_t)ParseHex(gBuf.componentToWorld,
                                                        (unsigned long long)o.sceneComponentToWorld);
            r.reinit = true;
        }
        ImGui::SameLine();
        if (ImGui::Button(u8"恢复默认 Reset")) {
            Offsets def;
            o = def;
            SyncOffsetBuffers(o);
            r.reinit = true;
        }

        char module[128] = {0};
        snprintf(module, sizeof(module), "%s", s.moduleName.c_str());
        if (ImGui::InputText(u8"主程序名", module, sizeof(module),
                             ImGuiInputTextFlags_EnterReturnsTrue)) {
            s.moduleName = module;
        }

        char includes[512] = {0};
        char excludes[512] = {0};
        snprintf(includes, sizeof(includes), "%s", o.characterClassIncludes.c_str());
        snprintf(excludes, sizeof(excludes), "%s", o.characterClassExcludes.c_str());
        if (ImGui::InputText(u8"角色类名包含", includes, sizeof(includes),
                             ImGuiInputTextFlags_EnterReturnsTrue)) {
            o.characterClassIncludes = includes;
        }
        if (ImGui::InputText(u8"角色类名排除", excludes, sizeof(excludes),
                             ImGuiInputTextFlags_EnterReturnsTrue)) {
            o.characterClassExcludes = excludes;
        }
        HelpMarker(u8"逗号分隔，大小写不敏感，会沿 SuperStruct 往上匹配。");
    }

    if (ImGui::CollapsingHeader(u8"日志 / Logs")) {
        ImGui::BeginChild("log", ImVec2(0, 150), true, ImGuiWindowFlags_HorizontalScrollbar);
        ImGui::TextUnformatted(bootLog.empty() ? "(没有日志)" : bootLog.c_str());
        ImGui::EndChild();
        if (!probe.empty()) {
            ImGui::BeginChild("probe", ImVec2(0, 110), true, ImGuiWindowFlags_HorizontalScrollbar);
            ImGui::TextUnformatted(probe.c_str());
            ImGui::EndChild();
        }
    }

    ImGui::Separator();
    if (ImGui::Button(u8"退出 HUD Exit")) r.exitApp = true;

    ImGui::End();
    return r;
}

} // namespace esp
