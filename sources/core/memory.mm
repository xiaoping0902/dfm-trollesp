//
//  memory.mm
//  DFM TrollESP —— 进程/内存访问层
//
//  外部模式（TrollStore 直装）：
//      task_for_pid(游戏 pid) -> mach_vm_read_overwrite
//      需要 entitlements: task_for_pid-allow / platform-application /
//      com.apple.private.security.no-sandbox，且进程以 root 运行（HUD 模式）。
//
//  内联模式（越狱或 TrollFools 注入，编译时 -DESP_INTERNAL）：
//      直接 mach_task_self()，模块基址取 _dyld_get_image_header(0)。
//
//  这里刻意不用 libproc.h（iPhoneOS SDK 里没有这个头）：
//    * 找 pid      -> sysctl(KERN_PROC_ALL) + kinfo_proc.p_comm
//    * 找镜像基址  -> mach_vm_region_recurse 遍历 + 读 Mach-O 头，filetype == MH_EXECUTE
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
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_region.h>
#include <sys/sysctl.h>
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
    // iOS 用户态指针范围（arm64 39 位用户空间）
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
#else
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
// 进程枚举（sysctl，不依赖 libproc）
// ---------------------------------------------------------------------------

bool FindPid(const char* exeName, pid_t* outPid) {
    if (!outPid) return false;

#ifdef ESP_INTERNAL
    // 注入模式：目标就是自己
    *outPid = getpid();
    return true;
#endif

    if (!exeName || !*exeName) return false;

    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, nullptr, &size, nullptr, 0) != 0 || size == 0) return false;

    // 进程数会变，留点余量
    std::vector<uint8_t> buffer(size + size / 2 + 4096);
    size = buffer.size();
    if (sysctl(mib, 4, buffer.data(), &size, nullptr, 0) != 0) return false;

    const size_t count = size / sizeof(struct kinfo_proc);
    const struct kinfo_proc* procs = reinterpret_cast<const struct kinfo_proc*>(buffer.data());
    const pid_t self = getpid();

    for (size_t i = 0; i < count; ++i) {
        const pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 0 || pid == self) continue;

        // p_comm 最多 16 个字符，长名字只能比前 16 位
        char comm[17] = {0};
        memcpy(comm, procs[i].kp_proc.p_comm, 16);
        if (strncasecmp(comm, exeName, 16) == 0) {
            *outPid = pid;
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// 主程序镜像基址：遍历区域，找 filetype == MH_EXECUTE 的 Mach-O
// ---------------------------------------------------------------------------

bool FindMainImageBase(pid_t pid, const char* exeName, uint64_t* outBase) {
    if (pid <= 0 || !outBase) return false;
    (void)exeName;

#ifdef ESP_INTERNAL
    if (pid == getpid()) {
        // 注入模式：主程序镜像头的运行时地址（不要用 slide，arm64 的 vmaddr 不是 0）
        const struct mach_header* header = _dyld_get_image_header(0);
        *outBase = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(header));
        return header != nullptr;
    }
#endif

    mach_port_t task = MACH_PORT_NULL;
    const bool ownTask = (pid == getpid());
    if (ownTask) {
        task = mach_task_self();
    } else {
        kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
        if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) return false;
    }

    // 复用已获得的端口来读 header：读完归还
    struct ScopedPort {
        mach_port_t port;
        bool owned;
        ScopedPort(mach_port_t p, bool o) : port(p), owned(o) {}
        ~ScopedPort() {
            if (owned && port != MACH_PORT_NULL && port != mach_task_self()) {
                mach_port_deallocate(mach_task_self(), port);
            }
        }
    } scoped(task, !ownTask);

    uint64_t addr = 0;
    bool found = false;

    for (int guard = 0; guard < 200000; ++guard) {
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t infoCount = VM_REGION_SUBMAP_INFO_COUNT_64;
        mach_vm_address_t regionAddr = addr;
        mach_vm_size_t regionSize = 0;
        natural_t depth = 0;

        kern_return_t kr = mach_vm_region_recurse(
            task, &regionAddr, &regionSize, &depth,
            reinterpret_cast<vm_region_recurse_info_t>(&info), &infoCount);
        if (kr != KERN_SUCCESS || regionSize == 0) break;

        const bool executable = (info.protection & VM_PROT_EXECUTE) != 0;
        if (executable && regionAddr != 0) {
            // 直接读目标内存里的 Mach-O 头（读自己时用 memcpy 更快，这里统一用 mach API）
            struct mach_header_64 header;
            mach_vm_size_t got = 0;
            uint32_t magic = 0;
            kr = mach_vm_read_overwrite(task, regionAddr, 4,
                                        reinterpret_cast<mach_vm_address_t>(&magic), &got);
            if (kr == KERN_SUCCESS && got == 4 && magic == MH_MAGIC_64) {
                got = 0;
                kr = mach_vm_read_overwrite(task, regionAddr, sizeof(header),
                                            reinterpret_cast<mach_vm_address_t>(&header), &got);
                if (kr == KERN_SUCCESS && got == sizeof(header) &&
                    header.filetype == MH_EXECUTE) {
                    *outBase = static_cast<uint64_t>(regionAddr);
                    found = true;
                    break;
                }
            }
        }

        addr = static_cast<uint64_t>(regionAddr) + static_cast<uint64_t>(regionSize);
    }

    return found;
}

} // namespace esp
