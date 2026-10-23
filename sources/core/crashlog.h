//
//  crashlog.h
//  DFM TrollESP —— 启动面包屑 + 崩溃日志
//
//  闪退的时候最怕"什么都不知道"，所以：
//    * 每个启动阶段写一行面包屑（App / HUD 各自写）
//    * 未捕获异常 + 致命信号（SIGSEGV/SIGABRT/...）会写 backtrace
//  日志路径：/var/mobile/Library/Caches/dfm_crash.log
//  没有 root/沙盒限制时退回 /tmp/dfm_crash.log
//

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

void ESPInstallCrashLogger(const char *tag);
void ESPLogStep(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
const char *ESPCrashLogPath(void);
// 读日志到 malloc 的字符串（调用方 free）；没有日志返回 NULL
char *ESPCrashLogRead(void);

#ifdef __cplusplus
}
#endif
