//
//  memory.cpp
//  DFM TrollESP —— 进程/内存访问层
//
//  外部模式（TrollStore 直装）：
//      task_for_pid(游戏 pid) -> mach_vm_read_overwrite
//      需要 entitlements: task_for_pid-allow / platform-application /
//      com.apple.private.security.no-sandbox，且进程以 root 运行（HUD 模式）。
//
//  内联模式（越狱或 TrollFools 注入，编译时 -DESP_INTERNAL）：
//      直接 mach_task_self()，模块基址取 _dyld_get_image_vmaddr_slide(0)。
//

#include "esp_core.hpp"

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <strings.h>
#include <unistd.h>

#include <dlfcn.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/proc_info.h>
#include <sys/types.h>

// 某些 SDK 的 <mach/mach.h> 里没有 task_for_pid 的声明，自己补一份
extern "C" kern_return_t task_for_pid(mach_port_t target_tport, int pid, mach_port_t *tn);

namespace esp {

uint64_t NowMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000ull + static_cast<uint64_t>(ts.tv_nsec / 1000000);
}

bool IsReadablePointer(uint64_t p) {
    // iOS 用户态指针范围（arm64 关闭 4GB 以上的内核地址）
    return p >= 0x100000000ull && p < 0x8000000000ull;
}

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

bool Reader::Attach(pid_t pid) {
    Detach();
    if (pid <= 0) return false;
    pid_ = pid;

#ifdef ESP_INTERNAL
    if (pid == getpid()) {
        task_ = mach_task_self();
        return true;
    }
#endif

    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &port);
    lastError = kr;
    if (kr != KERN_SUCCESS || port == MACH_PORT_NULL) {
        fprintf(stderr, "[esp] task_for_pid(%d) failed: %s (%d)\n", pid, mach_error_string(kr), kr);
        task_ = MACH_PORT_NULL;
        return false;
    }
    task_ = port;
    return true;
}

void Reader::Detach() {
#ifndef ESP_INTERNAL
    if (task_ != MACH_PORT_NULL && task_ != mach_task_self()) {
        mach_port_deallocate(mach_task_self(), task_);
    }
#endif
    task_ = MACH_PORT_NULL;
    pid_ = 0;
}

bool Reader::Read(uint64_t addr, void* out, size_t len) const {
    if (task_ == MACH_PORT_NULL || out == nullptr || len == 0) return false;
    if (addr == 0) return false;

    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(task_, static_cast<mach_vm_address_t>(addr),
                                              static_cast<mach_vm_size_t>(len),
                                              reinterpret_cast<mach_vm_address_t>(out), &got);
    lastError = kr;
    return kr == KERN_SUCCESS && got == len;
}

bool Reader::ReadPtr(uint64_t addr, uint64_t& out) const {
    return ReadT(addr, out);
}

// ---------------------------------------------------------------------------
// 进程枚举 / 模块基址
// ---------------------------------------------------------------------------

bool FindPid(const char* exeName, pid_t* outPid) {
    if (!outPid) return false;

#ifdef ESP_INTERNAL
    // 注入模式：目标就是自己
    *outPid = getpid();
    return true;
#endif

    int bytes = proc_listpids(PROC_ALL_PIDS, 0, nullptr, 0);
    if (bytes <= 0) return false;

    std::vector<pid_t> pids(static_cast<size_t>(bytes) / sizeof(pid_t) + 64);
    bytes = proc_listpids(PROC_ALL_PIDS, 0, pids.data(), static_cast<int>(pids.size() * sizeof(pid_t)));
    if (bytes <= 0) return false;

    const size_t count = static_cast<size_t>(bytes) / sizeof(pid_t);
    const pid_t self = getpid();

    for (size_t i = 0; i < count; ++i) {
        pid_t pid = pids[i];
        if (pid <= 0 || pid == self) continue;

        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pid, path, sizeof(path)) <= 0) continue;

        const char* slash = strrchr(path, '/');
        const char* base = slash ? slash + 1 : path;
        if (strcasecmp(base, exeName) == 0) {
            *outPid = pid;
            return true;
        }
    }
    return false;
}

bool FindMainImageBase(pid_t pid, const char* exeName, uint64_t* outBase) {
    if (pid <= 0 || !outBase) return false;

#ifdef ESP_INTERNAL
    if (pid == getpid()) {
        // 注入模式：主程序镜像的运行时基址（不要用 slide，arm64 的 vmaddr 不是 0）
        const struct mach_header *header = _dyld_get_image_header(0);
        *outBase = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(header));
        return header != nullptr;
    }
#endif

    struct proc_regionwithpathinfo rw;
    uint64_t addr = 0;
    bool foundFallback = false;
    uint64_t fallbackBase = 0;

    for (int guard = 0; guard < 200000; ++guard) {
        memset(&rw, 0, sizeof(rw));
        int n = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, addr, &rw, sizeof(rw));
        if (n <= 0) break;

        const uint64_t start = rw.prp_prinfo.pri_address;
        const uint64_t size = rw.prp_prinfo.pri_size;
        const char* path = rw.prp_vip.vip_path;
        const uint64_t fileOff = static_cast<uint64_t>(rw.prp_prinfo.pri_file_offset);

        if (path[0] != '\0') {
            const char* slash = strrchr(path, '/');
            const char* baseName = slash ? slash + 1 : path;
            const bool nameMatch = exeName && strcasecmp(baseName, exeName) == 0;
            if (nameMatch) {
                if (fileOff == 0) {                     // __TEXT 段起点 = 镜像基址
                    *outBase = start;
                    return true;
                }
                if (!foundFallback) {
                    foundFallback = true;
                    fallbackBase = start;
                }
            }
        }

        if (size == 0) break;
        addr = start + size;
    }

    if (foundFallback) {
        *outBase = fallbackBase;
        return true;
    }
    return false;
}

} // namespace esp
