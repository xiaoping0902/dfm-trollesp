//
//  PrivateApi.mm
//  DFM TrollESP
//

#import "PrivateApi.h"

#import <dlfcn.h>
#import <objc/runtime.h>

namespace hud {

namespace {

void *gGraphicsServices = nullptr;
void *gBackBoard = nullptr;
void *gSpringBoard = nullptr;
void *gAccessibilityUtilities = nullptr;

void *LoadFramework(const char *path) {
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        NSLog(@"[esp] dlopen %s failed: %s", path, dlerror());
    }
    return h;
}

void *FindSymbol(const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;
    if (gGraphicsServices) { p = dlsym(gGraphicsServices, name); if (p) return p; }
    if (gBackBoard)        { p = dlsym(gBackBoard, name);        if (p) return p; }
    if (gSpringBoard)      { p = dlsym(gSpringBoard, name);      if (p) return p; }
    return nullptr;
}

PrivateApi gApi = {};

} // namespace

bool PrivateApi::load() {
    if (valid()) return true;

    gGraphicsServices = LoadFramework("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices");
    gBackBoard        = LoadFramework("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices");
    gSpringBoard      = LoadFramework("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices");

    UIApplicationInitialize            = (void (*)())FindSymbol("UIApplicationInitialize");
    UIApplicationInstantiateSingleton  = (void (*)(id))FindSymbol("UIApplicationInstantiateSingleton");
    GSInitialize                       = (void (*)())FindSymbol("GSInitialize");
    BKSDisplayServicesStart            = (void (*)())FindSymbol("BKSDisplayServicesStart");
    GSEventInitialize                  = (void (*)(Boolean))FindSymbol("GSEventInitialize");
    GSEventPushRunLoopMode             = (void (*)(CFStringRef))FindSymbol("GSEventPushRunLoopMode");
    BKSHIDEventRegisterEventCallback   = (void *(*)(void (*)(void *, void *, IOHIDServiceRef, IOHIDEventRef)))
                                             FindSymbol("BKSHIDEventRegisterEventCallback");

    accessibilityWindowHostingClass = objc_getClass("SBSAccessibilityWindowHostingController");

    NSLog(@"[esp] private api: appInit=%p instantiate=%p gs=%p bks=%p hid=%p hosting=%p",
          (void *)UIApplicationInitialize, (void *)UIApplicationInstantiateSingleton,
          (void *)GSInitialize, (void *)BKSDisplayServicesStart,
          (void *)BKSHIDEventRegisterEventCallback, (__bridge void *)accessibilityWindowHostingClass);

    return valid();
}

PrivateApi &api() {
    return gApi;
}

Class ESPAccessibilityEventClass(void) {
    static Class cls = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class existing = objc_getClass("AXEventRepresentation");
        if (!existing) {
            gAccessibilityUtilities = LoadFramework(
                "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities");
            existing = objc_getClass("AXEventRepresentation");
        }
        cls = existing;
    });
    return cls;
}

} // namespace hud
