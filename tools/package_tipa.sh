#!/bin/sh
#
# 把 Theos 编出来的 .app 重新包成 TrollStore 可以直装的 .tipa
#
# 用法: sh tools/package_tipa.sh <THEOS_STAGING_DIR>
#   THEOS_STAGING_DIR 形如 .../.theos/_ ，里面是 Applications/DFMTrollESP.app
#

set -e

APP_NAME="DFMTrollESP"
BUNDLE_ID="com.dfm.trollesp"
STAGING="${1:-}"

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$PROJECT_DIR/.tipa_stage"
OUT_DIR="$PROJECT_DIR/packages"

if [ -z "$STAGING" ] || [ ! -d "$STAGING" ]; then
    echo "!! 找不到 Theos staging 目录: '$STAGING'" >&2
    exit 1
fi

SRC_APP="$(find "$STAGING" -maxdepth 4 -type d -name "$APP_NAME.app" | head -n 1)"
if [ -z "$SRC_APP" ] || [ ! -d "$SRC_APP" ]; then
    echo "!! staging 里没有 $APP_NAME.app，先 make package" >&2
    exit 1
fi

echo "   source app: $SRC_APP"

rm -rf "$STAGE"
mkdir -p "$STAGE/Payload" "$OUT_DIR"
cp -R "$SRC_APP" "$STAGE/Payload/"
APP="$STAGE/Payload/$APP_NAME.app"

# --- Info.plist：直接写死一份，避免不同 Theos 版本生成的键不一致 ---
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>三角洲ESP</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>LSRequiresIPhoneOS</key>
	<true/>
	<key>MinimumOSVersion</key>
	<string>15.0</string>
	<key>UIRequiredDeviceCapabilities</key>
	<array>
		<string>arm64</string>
	</array>
	<key>UIDeviceFamily</key>
	<array>
		<integer>1</integer>
		<integer>2</integer>
	</array>
	<key>UISupportedInterfaceOrientations</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
	<key>UISupportedInterfaceOrientations~ipad</key>
	<array>
		<string>UIInterfaceOrientationPortrait</string>
		<string>UIInterfaceOrientationPortraitUpsideDown</string>
		<string>UIInterfaceOrientationLandscapeLeft</string>
		<string>UIInterfaceOrientationLandscapeRight</string>
	</array>
	<key>UIStatusBarHidden</key>
	<true/>
	<key>UIViewControllerBasedStatusBarAppearance</key>
	<false/>
	<key>CADisableMinimumFrameDurationOnPhone</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>CFBundleIcons</key>
	<dict>
		<key>CFBundlePrimaryIcon</key>
		<dict>
			<key>CFBundleIconFiles</key>
			<array>
				<string>AppIcon60x60</string>
			</array>
		</dict>
	</dict>
</dict>
</plist>
PLIST

chmod 0644 "$APP/Info.plist"

# --- 图标（有就带上） ---
for f in "$PROJECT_DIR/Resources/AppIcon60x60@2x.png" "$PROJECT_DIR/Resources/AppIcon60x60@3x.png"; do
    if [ -f "$f" ]; then
        cp "$f" "$APP/"
    fi
done

# --- 用 TrollStore 的签名方式（ldid + 任意 entitlements）---
LDID="$(command -v ldid || true)"
if [ -z "$LDID" ]; then
    for candidate in "$THEOS/bin/ldid" /opt/homebrew/bin/ldid /usr/local/bin/ldid; do
        if [ -x "$candidate" ]; then LDID="$candidate"; break; fi
    done
fi

if [ -z "$LDID" ]; then
    echo "!! 找不到 ldid，无法签 entitlements（TrollStore 会装不上）" >&2
    exit 1
fi

"$LDID" -S"$PROJECT_DIR/supports/entitlements.plist" "$APP/$APP_NAME"

echo "   entitlements:"
"$LDID" -e "$APP/$APP_NAME" | sed 's/^/     /' | head -n 40

# --- 打包 ---
TIP="$OUT_DIR/DFMTrollESP.tipa"
rm -f "$TIP"
( cd "$STAGE" && zip -qry -X "$TIP" Payload )

echo "   => $TIP"
echo "   安装：AirDrop / Filza / TrollStore 里点开这个 tipa 即可"
