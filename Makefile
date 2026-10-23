ARCHS := arm64
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES := DFMTrollESP

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := DFMTrollESP

# 注意：sources/dylib 是注入版专用，不算进 App（见 Makefile.dylib）
DFMTrollESP_FILES := $(shell find sources/core sources/hud sources/app -name '*.mm') $(shell find sources/core sources/hud sources/app -name '*.m')
# ImGui 源码统一按 ObjC++ 编（这样全局 -fobjc-arc 不会和纯 C++ 模式冲突）
DFMTrollESP_FILES += imgui/imgui.mm
DFMTrollESP_FILES += imgui/imgui_draw.mm
DFMTrollESP_FILES += imgui/imgui_tables.mm
DFMTrollESP_FILES += imgui/imgui_widgets.mm
DFMTrollESP_FILES += imgui/imgui_impl_metal.mm

DFMTrollESP_CFLAGS := -fobjc-arc -std=gnu++17 -DNDEBUG
DFMTrollESP_CFLAGS += -Iimgui -Isources -Isources/core -Isources/hud -Isources/app
DFMTrollESP_CFLAGS += -Wno-unused-parameter -Wno-unused-variable -Wno-deprecated-declarations
DFMTrollESP_CFLAGS += -Wno-nullability-completeness -Wno-shorten-64-to-32
DFMTrollESP_CFLAGS += -Wno-unused-command-line-argument

DFMTrollESP_FRAMEWORKS := Foundation UIKit Metal MetalKit QuartzCore CoreGraphics
DFMTrollESP_CODESIGN_FLAGS := -Ssupports/entitlements.plist

include $(THEOS_MAKE_PATH)/application.mk

after-package::
	@echo "==> 打包 TrollStore 用的 .tipa"
	@sh tools/package_tipa.sh "$(THEOS_STAGING_DIR)"

clean::
	@rm -rf .tipa_stage packages/*.tipa
