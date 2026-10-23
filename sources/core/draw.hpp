//
//  draw.hpp
//  DFM TrollESP —— 绘制层接口
//

#pragma once

#include "debug.hpp"
#include "esp_core.hpp"

struct ImDrawList;
struct ImVec2;

namespace esp {

// 画骨骼 / 方框 / 文字（在 ImGui::NewFrame() 之后调用）
void DrawESP(ImDrawList *dl, const Snapshot &snap, const EspSettings &s, ImVec2 display);

struct MenuResult {
    bool reinit = false;
    bool save = false;
    bool close = false;
    bool exitApp = false;
};

// 菜单（会直接改 settings/offsets 的即时值，保存由调用方决定）
MenuResult DrawMenu(EspSettings &s, Offsets &o, const Snapshot &snap,
                    const std::string &bootLog, const std::string &probe,
                    bool engineReady, int targetPid, unsigned long long moduleBase,
                    DebugOptions &dbg);

} // namespace esp
