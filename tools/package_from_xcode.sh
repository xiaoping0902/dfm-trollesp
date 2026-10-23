#!/bin/sh
#
# 把 xcodebuild 编出来的 .app 打成 TrollStore 能直装的 .tipa
#   sh tools/package_from_xcode.sh <路径/DFMTrollESP.app> [输出.tipa]
#
set -e

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-}"
OUT="${2:-$PROJECT_DIR/packages/DFMTrollESP.tipa}"

if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "!! 找不到 .app: '$APP'" >&2
    exit 1
fi

LDID_BIN="${LDID:-ldid}"
if ! command -v "$LDID_BIN" >/dev/null 2>&1; then
    for c in /opt/homebrew/bin/ldid /usr/local/bin/ldid "$THEOS/bin/ldid"; do
        [ -x "$c" ] && LDID_BIN="$c" && break
    done
fi
if ! command -v "$LDID_BIN" >/dev/null 2>&1 && [ ! -x "$LDID_BIN" ]; then
    echo "!! 找不到 ldid（brew install ldid）" >&2
    exit 1
fi

STAGE="$PROJECT_DIR/.tipa_stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload" "$(dirname "$OUT")"

cp -R "$APP" "$STAGE/Payload/"
APP_DIR="$STAGE/Payload/$(basename "$APP")"

BIN="$APP_DIR/DFMTrollESP"
[ -f "$BIN" ] || BIN="$(find "$APP_DIR" -maxdepth 1 -type f -perm +111 | head -n 1)"

chmod 0755 "$BIN"
chmod 0644 "$APP_DIR/Info.plist"

# TrollStore 走 CoreTrust，必须是 ldid + 自定义 entitlements
"$LDID_BIN" -S"$PROJECT_DIR/supports/entitlements.plist" "$BIN"

echo "== entitlements =="
"$LDID_BIN" -e "$BIN" | head -n 45 || true

rm -f "$OUT"
( cd "$STAGE" && zip -qry -X "$OUT" Payload )

echo "== tipa =="
echo "$OUT"
ls -lh "$OUT" 2>/dev/null || true
