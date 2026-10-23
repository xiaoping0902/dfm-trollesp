//
//  PrivateApi.h
//  DFM TrollESP —— iOS 私有符号（全部运行时 dlsym，不在链接期依赖私有框架）
//

#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDNotification *IOHIDNotificationRef;
typedef struct __IOHIDService *IOHIDServiceRef;
typedef struct __GSEvent *GSEventRef;

// ---- 私有类的最小声明（类在 AccessibilityUtilities/SpringBoardServices 里，运行时加载）----
// 注意：@interface 必须在全局作用域，不能塞进 namespace。

@interface ESPAXEventPathInfoRepresentation : NSObject
@property (assign, nonatomic) unsigned char pathIdentity;
@end

@interface ESPAXEventHandInfoRepresentation : NSObject
- (NSArray<ESPAXEventPathInfoRepresentation *> *)paths;
@end

@interface ESPAXEventRepresentation : NSObject
@property (nonatomic, readonly) BOOL isTouchDown;
@property (nonatomic, readonly) BOOL isMove;
@property (nonatomic, readonly) BOOL isChordChange;
@property (nonatomic, readonly) BOOL isLift;
@property (nonatomic, readonly) BOOL isInRange;
@property (nonatomic, readonly) BOOL isInRangeLift;
@property (nonatomic, readonly) BOOL isCancel;
+ (instancetype)representationWithHIDEvent:(IOHIDEventRef)event hidStreamIdentifier:(NSString *)identifier;
- (ESPAXEventHandInfoRepresentation *)handInfo;
- (CGPoint)location;
@end

namespace hud {

struct PrivateApi {
    void  (*UIApplicationInitialize)();
    void  (*UIApplicationInstantiateSingleton)(id appClass);
    void  (*GSInitialize)();
    void  (*BKSDisplayServicesStart)();
    void  (*GSEventInitialize)(Boolean registerPurple);
    void  (*GSEventPushRunLoopMode)(CFStringRef mode);
    void *(*BKSHIDEventRegisterEventCallback)(void (*cb)(void *, void *, IOHIDServiceRef, IOHIDEventRef));

    Class accessibilityWindowHostingClass;   // SBSAccessibilityWindowHostingController

    bool load();
    bool valid() const {
        // UIApplicationInitialize / UIApplicationInstantiateSingleton 在部分系统上
        // 解析不到，可以退化成 [UIApplication sharedApplication]，所以不算硬性条件
        return GSInitialize && BKSDisplayServicesStart && BKSHIDEventRegisterEventCallback;
    }
};

PrivateApi &api();

// 运行时加载 AccessibilityUtilities 并取 AXEventRepresentation 类
Class ESPAccessibilityEventClass(void);

} // namespace hud
