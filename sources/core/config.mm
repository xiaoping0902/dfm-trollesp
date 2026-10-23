//
//  config.mm
//  DFM TrollESP —— 设置持久化
//
//  App 和 HUD 是同一个二进制、两个进程，靠一个固定路径的 plist 通信：
//      /var/mobile/Library/Preferences/com.dfm.trollesp.plist
//  App 写完 notify_post("com.dfm.trollesp.reload")，HUD 收到通知后重载。
//

#import <Foundation/Foundation.h>
#import <notify.h>

#include <cstdio>
#include <cstring>

#include "esp_core.hpp"

static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/com.dfm.trollesp.plist";
static const char *const kReloadNotification = "com.dfm.trollesp.reload";

const char *esp::SettingsPlistPath() {
    return kPrefsPath.UTF8String;
}

namespace {

bool GetBool(NSDictionary *d, NSString *key, bool def) {
    id v = d[key];
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : def;
}

float GetFloat(NSDictionary *d, NSString *key, float def) {
    id v = d[key];
    return [v isKindOfClass:[NSNumber class]] ? [v floatValue] : def;
}

int GetInt(NSDictionary *d, NSString *key, int def) {
    id v = d[key];
    return [v isKindOfClass:[NSNumber class]] ? [v intValue] : def;
}

unsigned long long GetULL(NSDictionary *d, NSString *key, unsigned long long def) {
    id v = d[key];
    return [v isKindOfClass:[NSNumber class]] ? [v unsignedLongLongValue] : def;
}

std::string GetStr(NSDictionary *d, NSString *key, const std::string &def) {
    id v = d[key];
    if (![v isKindOfClass:[NSString class]]) return def;
    const char *utf8 = [v UTF8String];
    return utf8 ? std::string(utf8) : def;
}

void GetColor(NSDictionary *d, NSString *key, float out[4]) {
    std::string s = GetStr(d, key, "");
    if (s.empty()) return;
    float r = 1.f, g = 1.f, b = 1.f, a = 1.f;
    if (sscanf(s.c_str(), "%f,%f,%f,%f", &r, &g, &b, &a) >= 3) {
        out[0] = r; out[1] = g; out[2] = b; out[3] = a;
    }
}

NSString *ColorString(const float c[4]) {
    return [NSString stringWithFormat:@"%.3f,%.3f,%.3f,%.3f", c[0], c[1], c[2], c[3]];
}

} // namespace

bool esp::LoadSettings(EspSettings &s, Offsets &o) {
    @autoreleasepool {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
        if (![d isKindOfClass:[NSDictionary class]]) return false;

        s.enabled        = GetBool(d, @"enabled", s.enabled);
        s.drawSkeleton   = GetBool(d, @"drawSkeleton", s.drawSkeleton);
        s.drawBox        = GetBool(d, @"drawBox", s.drawBox);
        s.drawHeadDot    = GetBool(d, @"drawHeadDot", s.drawHeadDot);
        s.drawDistance   = GetBool(d, @"drawDistance", s.drawDistance);
        s.drawSnapline   = GetBool(d, @"drawSnapline", s.drawSnapline);
        s.drawBoneJoints = GetBool(d, @"drawBoneJoints", s.drawBoneJoints);
        s.drawFilledBox  = GetBool(d, @"drawFilledBox", s.drawFilledBox);

        s.maxDistance    = GetFloat(d, @"maxDistance", s.maxDistance);
        s.lineThickness  = GetFloat(d, @"lineThickness", s.lineThickness);
        s.boxThickness   = GetFloat(d, @"boxThickness", s.boxThickness);
        s.textScale      = GetFloat(d, @"textScale", s.textScale);
        s.sampleHz       = GetInt(d, @"sampleHz", s.sampleHz);
        s.verboseLog     = GetBool(d, @"verboseLog", s.verboseLog);
        s.showBall       = GetBool(d, @"showBall", s.showBall);
        s.ballX          = GetFloat(d, @"ballX", s.ballX);
        s.ballY          = GetFloat(d, @"ballY", s.ballY);
        s.ballRadius     = GetFloat(d, @"ballRadius", s.ballRadius);

        GetColor(d, @"colorSkeleton", s.colorSkeleton);
        GetColor(d, @"colorBox", s.colorBox);
        GetColor(d, @"colorSnapline", s.colorSnapline);
        GetColor(d, @"colorText", s.colorText);

        s.moduleName     = GetStr(d, @"moduleName", s.moduleName);
        o.characterClassIncludes = GetStr(d, @"classIncludes", o.characterClassIncludes);
        o.characterClassExcludes = GetStr(d, @"classExcludes", o.characterClassExcludes);

        // 高级：手填偏移（换版本时只需要改这里）
        o.rvaGObjects = GetULL(d, @"rvaGObjects", o.rvaGObjects);
        o.rvaGNames   = GetULL(d, @"rvaGNames", o.rvaGNames);
        o.rvaGWorld   = GetULL(d, @"rvaGWorld", o.rvaGWorld);
        o.characterMesh = GetInt(d, @"offCharacterMesh", o.characterMesh);
        o.meshBoneTransforms = GetInt(d, @"offBoneTransforms", o.meshBoneTransforms);
        o.sceneComponentToWorld = GetInt(d, @"offComponentToWorld", o.sceneComponentToWorld);

        o.maxDistance = s.maxDistance;
        return true;
    }
}

void esp::SaveSettings(const EspSettings &s, const Offsets &o) {
    @autoreleasepool {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];

        d[@"enabled"]        = @(s.enabled);
        d[@"drawSkeleton"]   = @(s.drawSkeleton);
        d[@"drawBox"]        = @(s.drawBox);
        d[@"drawHeadDot"]    = @(s.drawHeadDot);
        d[@"drawDistance"]   = @(s.drawDistance);
        d[@"drawSnapline"]   = @(s.drawSnapline);
        d[@"drawBoneJoints"] = @(s.drawBoneJoints);
        d[@"drawFilledBox"]  = @(s.drawFilledBox);

        d[@"maxDistance"]    = @(s.maxDistance);
        d[@"lineThickness"]  = @(s.lineThickness);
        d[@"boxThickness"]   = @(s.boxThickness);
        d[@"textScale"]      = @(s.textScale);
        d[@"sampleHz"]       = @(s.sampleHz);
        d[@"verboseLog"]     = @(s.verboseLog);
        d[@"showBall"]       = @(s.showBall);
        d[@"ballX"]          = @(s.ballX);
        d[@"ballY"]          = @(s.ballY);
        d[@"ballRadius"]     = @(s.ballRadius);

        d[@"colorSkeleton"]  = ColorString(s.colorSkeleton);
        d[@"colorBox"]       = ColorString(s.colorBox);
        d[@"colorSnapline"]  = ColorString(s.colorSnapline);
        d[@"colorText"]      = ColorString(s.colorText);

        d[@"moduleName"]     = [NSString stringWithUTF8String:s.moduleName.c_str()];
        d[@"classIncludes"]  = [NSString stringWithUTF8String:o.characterClassIncludes.c_str()];
        d[@"classExcludes"]  = [NSString stringWithUTF8String:o.characterClassExcludes.c_str()];

        d[@"rvaGObjects"]    = @(o.rvaGObjects);
        d[@"rvaGNames"]      = @(o.rvaGNames);
        d[@"rvaGWorld"]      = @(o.rvaGWorld);
        d[@"offCharacterMesh"]      = @(o.characterMesh);
        d[@"offBoneTransforms"]     = @(o.meshBoneTransforms);
        d[@"offComponentToWorld"]   = @(o.sceneComponentToWorld);

        NSString *dir = [kPrefsPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions : @0755}
                                                        error:nil];
        [d writeToFile:kPrefsPath atomically:YES];
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0644}
                                         ofItemAtPath:kPrefsPath
                                                error:nil];

        notify_post(kReloadNotification);
    }
}

void esp::PostReloadNotification() {
    notify_post(kReloadNotification);
}
