//
//  HudControl.mm
//  DFM TrollESP
//
//  拉起 HUD 进程：posix_spawn 自己，persona 99 + uid/gid 0 提权到 root。
//  没 root 的话 SpringBoard 会在解锁/切后台时把 HUD 干掉。
//  需要的 entitlements：platform-application / no-sandbox / persona-mgmt /
//  task_for_pid-allow —— TrollStore 用 CoreTrust 签，全部生效。
//

#import "HudControl.h"

#import <spawn.h>
#import <signal.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

extern "C" char **environ;
extern "C" int posix_spawnattr_set_persona_np(const posix_spawnattr_t *attr, uid_t persona, uint32_t flags);
extern "C" int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *attr, uid_t uid);
extern "C" int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *attr, gid_t gid);

static const char *kPidFilePath = "/var/mobile/Library/Caches/com.dfm.trollesp.hud.pid";

NSString *ESPHudPidFilePath(void) {
    return @(kPidFilePath);
}

static NSString *ESPExecutablePath(void) {
    static char path[4096] = {0};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint32_t size = sizeof(path);
        if (_NSGetExecutablePath(path, &size) != 0) {
            path[0] = '\0';
        }
    });
    return path[0] ? @(path) : nil;
}

static pid_t ESPReadPidFile(void) {
    NSString *text = [NSString stringWithContentsOfFile:ESPHudPidFilePath()
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (!text) return 0;
    return (pid_t)text.intValue;
}

bool ESPHudIsRunning(void) {
    const pid_t pid = ESPReadPidFile();
    if (pid <= 0) return false;
    if (kill(pid, 0) == 0) return true;
    unlink(kPidFilePath);
    return false;
}

bool ESPHudStart(void) {
    NSString *exe = ESPExecutablePath();
    if (!exe) return false;

    const char *exePath = exe.UTF8String;
    const char *argv[] = {exePath, "-hud", nullptr};

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    // 提权到 root（persona 99 = POSIX_SPAWN_PERSONA_DEFAULT 之外的自定义 persona）
    posix_spawnattr_set_persona_np(&attr, 99, 1 /* OVERRIDE */);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

    pid_t pid = 0;
    const int rc = posix_spawn(&pid, exePath, nullptr, &attr, (char **)argv, environ);
    posix_spawnattr_destroy(&attr);

    if (rc != 0) {
        NSLog(@"[esp] posix_spawn(hud) failed: %s (%d)", strerror(rc), rc);
        return false;
    }

    // 不 waitpid，让 HUD 自己跑（wait 会让它变成僵尸/被回收）
    NSLog(@"[esp] HUD spawned pid=%d", pid);
    return true;
}

bool ESPHudStop(void) {
    const pid_t pid = ESPReadPidFile();
    if (pid > 0) {
        kill(pid, SIGKILL);
    }
    unlink(kPidFilePath);
    return true;
}
