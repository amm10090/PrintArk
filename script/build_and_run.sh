#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
# BINARY_NAME 是 SwiftPM 产物/可执行名（内部标识，跟随 Package executable 名）；
# APP_NAME 是 .app bundle 文件名（程序名）；DISPLAY_NAME 是用户可见显示名。
BINARY_NAME="PrintArk"
APP_NAME="PrintArk"
DISPLAY_NAME="印舟"
BUNDLE_ID="local.printark.app"
MIN_SYSTEM_VERSION="13.0"
# App 版本号：须与代码常量 AppInfo.version 字面对齐（单一数据源约定）。
APP_VERSION="1.1.13"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$BINARY_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
CREDENTIALS_RESOURCE="$APP_RESOURCES/CainiaoHandshake.plist"
PRIVATE_CREDENTIALS_FILE="${PRINTARK_CAINIAO_CREDENTIALS_FILE:-$HOME/Library/Application Support/PrintArk/build-secrets/CainiaoHandshake.plist}"
ICON_SOURCE="$ROOT_DIR/assets/AppIcon.png"
ICON_NAME="AppIcon"

cd "$ROOT_DIR"

pkill -x "$BINARY_NAME" >/dev/null 2>&1 || true
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$BINARY_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

# 远端握手凭据只从私有构建输入注入，不进入源码或构建日志。
CAINIAO_APP_KEY="${PRINTARK_CAINIAO_APP_KEY:-}"
CAINIAO_APP_SECRET="${PRINTARK_CAINIAO_APP_SECRET:-}"
if [[ (-z "$CAINIAO_APP_KEY" || -z "$CAINIAO_APP_SECRET") && -f "$PRIVATE_CREDENTIALS_FILE" ]]; then
  CAINIAO_APP_KEY="$(/usr/libexec/PlistBuddy -c 'Print :appKey' "$PRIVATE_CREDENTIALS_FILE" 2>/dev/null || true)"
  CAINIAO_APP_SECRET="$(/usr/libexec/PlistBuddy -c 'Print :appSecret' "$PRIVATE_CREDENTIALS_FILE" 2>/dev/null || true)"
fi

if [[ -n "$CAINIAO_APP_KEY" && -n "$CAINIAO_APP_SECRET" ]]; then
  mkdir -p "$APP_RESOURCES"
  /usr/bin/plutil -create xml1 "$CREDENTIALS_RESOURCE"
  /usr/bin/plutil -insert appKey -string "$CAINIAO_APP_KEY" "$CREDENTIALS_RESOURCE"
  /usr/bin/plutil -insert appSecret -string "$CAINIAO_APP_SECRET" "$CREDENTIALS_RESOURCE"
  chmod 600 "$CREDENTIALS_RESOURCE"
elif [[ "${PRINTARK_REQUIRE_CAINIAO_CREDENTIALS:-0}" == "1" ]]; then
  echo "missing PrintArk Cainiao handshake build credentials" >&2
  exit 1
else
  echo "warning: building without Cainiao handshake credentials; local listeners remain available" >&2
fi

# 由源 PNG 生成 .icns 并放入 Resources；缺源图时跳过（Dock 退回通用图标）。
HAS_ICON=0
if [[ -f "$ICON_SOURCE" ]]; then
  mkdir -p "$APP_RESOURCES"
  ICONSET_DIR="$(mktemp -d)/$ICON_NAME.iconset"
  mkdir -p "$ICONSET_DIR"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET_DIR" -o "$APP_RESOURCES/$ICON_NAME.icns"
  rm -rf "$(dirname "$ICONSET_DIR")"
  HAS_ICON=1
fi

ICON_PLIST_ENTRY=""
if [[ "$HAS_ICON" == "1" ]]; then
  ICON_PLIST_ENTRY="  <key>CFBundleIconFile</key>
  <string>$ICON_NAME</string>"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$BINARY_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>$BUNDLE_ID</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>cnprint</string>
      </array>
    </dict>
  </array>
$ICON_PLIST_ENTRY
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  build|--build)
    # 仅打包不运行:.app bundle 已在 case 之前构建完成,这里直接退出。
    # 供 CI 产出 artifact,避免在无头环境 open_app 启动 GUI。
    echo "$DISPLAY_NAME ($APP_NAME) bundle built at $APP_BUNDLE"
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$BINARY_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$BINARY_NAME" >/dev/null
    echo "$DISPLAY_NAME ($APP_NAME) launched"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
