# 来源与许可 / Credits

本工程里直接复用或改写的第三方代码：

| 部分 | 来源 | 许可 |
|---|---|---|
| HUD 进程启动、跨 App 窗口（`HudApp.mm`、`PrivateApi.*`） | [TrollSpeed](https://github.com/Lessica/TrollSpeed)（Lessica） | MIT |
| HID → 合成 UITouch（`TouchInject.mm`） | TrollSpeed / FakeTouch (Watanabe Toshinori) / KIF (Square) | MIT |
| ImGui 1.87 WIP + Metal 后端（`imgui/`） | [ocornut/imgui](https://github.com/ocornut/imgui) | MIT |
| 骨骼链路 / W2S 思路 | [shiedless/Reveal](https://github.com/shiedless/Reveal)、[rockfellerfx/iOS-PUBGM-ModMenu](https://github.com/rockfellerfx/iOS-PUBGM-ModMenu)、silentninjabee/Farlight_ue4_external | MIT / 见各自仓库 |
| UE4 对象系统结构（TUObjectArray / FName / UObject 布局） | [MobileDumper-7](https://github.com/MJx0/MobileDumper-7) + [Dumper-7](https://github.com/Encryqed/Dumper-7) 生成的 CppSDK | 参考结构，非直接拷贝 |

游戏相关偏移来自本地 `DeltaForce-iOS-SDK`（本机 dump 产物，不随工程分发）。
