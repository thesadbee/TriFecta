#!/usr/bin/env bash
#
# build-app.sh — 构建 TriFectaSettings.app
#
# 用法：bash scripts/build-app.sh [release|debug]   （默认 release）
# 产物：settings/dist/TriFectaSettings.app（ad-hoc 签名）
#
# 说明：
#  - 主构建走 SwiftPM（Command Line Tools 环境也可构建；xcodeproj 供 Xcode 用户）。
#  - 仓库可能位于 iCloud 同步目录（~Documents）：codesign 拒绝 fileprovider/provenance
#    等扩展属性，因此构建与签名全部在 /tmp 完成后才拷贝回 dist/。
#
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcodebuild -version >/dev/null 2>&1; then
  if [ -d "/Applications/Xcode-beta.app/Contents/Developer" ]; then
    echo "==> 当前 xcode-select 未指向完整 Xcode，使用 Xcode-beta 工具链"
    export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
  else
    echo "未找到可用的 Xcode 工具链（需要完整 Xcode 或 Xcode-beta）" >&2
    exit 1
  fi
fi

CONFIG="${1:-release}"
ROOT="$(pwd)"
SCRATCH="${SCT_SCRATCH:-/tmp/trifecta-settings-build-$(id -u)}"
WORK="/tmp/TriFectaSettings-build-$(id -u)"
STAGE="$WORK/TriFectaSettings.app"

rm -rf "$WORK"
mkdir -p "$WORK" "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

swift build -c "$CONFIG" --scratch-path "$SCRATCH" >/dev/null
BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)/TriFectaSettings"

cp "$BIN" "$STAGE/Contents/MacOS/TriFectaSettings"
cp "Sources/TriFectaSettings/Resources/Info.plist" "$STAGE/Contents/Info.plist"

ICON_SRC="/Library/Input Methods/Squirrel.app/Contents/Resources/RimeIcon.icns"
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$STAGE/Contents/Resources/AppIcon.icns"
else
  echo "警告：未找到输入法包图标（/Library/Input Methods/Squirrel.app），跳过 AppIcon"
fi

# 在 /tmp 内完成签名（远离 iCloud 属性戳）
xattr -cr "$STAGE" 2>/dev/null || true
codesign --force -s - "$STAGE"
codesign --verify --deep "$STAGE"

# 同步回 dist/
OUT="$ROOT/dist/TriFectaSettings.app"
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -R "$STAGE" "$OUT"

echo "构建完成：$OUT"
echo "版本：$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$OUT/Contents/Info.plist")"
echo "签名：$(codesign -dv "$OUT" 2>&1 | grep -m1 'Authority\|Signature=' || echo 'ad-hoc')"
