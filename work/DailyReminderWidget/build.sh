#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT_ROOT="$ROOT/../../outputs"
APP_NAME="灵栖胶囊Capsule"
BUNDLE_ID="local.codex.lingqi-capsule"
APP_VERSION="1.3.2"
APP_BUILD="18"
APP="$OUT_ROOT/$APP_NAME.app"
DMG_ROOT="$ROOT/dmgroot"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
DEFAULT_ICON="$ROOT/Assets/AppIcon.png"
NOTIFICATION_ICON="$ROOT/Assets/NotificationIcon.png"
MENU_BAR_ICON="$ROOT/Assets/MenuBarIconTemplate.png"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"

rm -rf "$APP" "$OUT_ROOT/$APP_NAME.dmg" "$ROOT/icon.iconset" "$DMG_ROOT"
mkdir -p "$MACOS" "$RESOURCES" "$ROOT/icon.iconset"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>DailyReminderWidget</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key>
    <string>Local app generated for personal productivity.</string>
    <key>NSUserNotificationAlertStyle</key>
    <string>alert</string>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

if [[ -f "$DEFAULT_ICON" ]]; then
  sips -z 16 16 "$DEFAULT_ICON" --out "$ROOT/icon.iconset/icon_16x16.png" >/dev/null
  sips -z 32 32 "$DEFAULT_ICON" --out "$ROOT/icon.iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$DEFAULT_ICON" --out "$ROOT/icon.iconset/icon_32x32.png" >/dev/null
  sips -z 64 64 "$DEFAULT_ICON" --out "$ROOT/icon.iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$DEFAULT_ICON" --out "$ROOT/icon.iconset/icon_128x128.png" >/dev/null
  sips -z 256 256 "$DEFAULT_ICON" --out "$ROOT/icon.iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$DEFAULT_ICON" --out "$ROOT/icon.iconset/icon_256x256.png" >/dev/null
  sips -z 512 512 "$DEFAULT_ICON" --out "$ROOT/icon.iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$DEFAULT_ICON" --out "$ROOT/icon.iconset/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$DEFAULT_ICON" --out "$ROOT/icon.iconset/icon_512x512@2x.png" >/dev/null
else
  swift "$ROOT/make_icon.swift" "$ROOT/icon.iconset"
fi
iconutil -c icns "$ROOT/icon.iconset" -o "$RESOURCES/AppIcon.icns"
if [[ -f "$NOTIFICATION_ICON" ]]; then
  cp "$NOTIFICATION_ICON" "$RESOURCES/NotificationIcon.png"
fi
if [[ -f "$MENU_BAR_ICON" ]]; then
  cp "$MENU_BAR_ICON" "$RESOURCES/MenuBarIconTemplate.png"
fi
if [[ -f "$DEFAULT_ICON" ]]; then
  cp "$DEFAULT_ICON" "$RESOURCES/AppIcon.png"
fi
if [[ -f "$ROOT/Assets/InspirationPlantCapsule.png" ]]; then
  cp "$ROOT/Assets/InspirationPlantCapsule.png" "$RESOURCES/InspirationPlantCapsule.png"
fi
for CAPSULE_STATE in "$ROOT"/Assets/CapsuleGrowthState*.png; do
  if [[ -f "$CAPSULE_STATE" ]]; then
    cp "$CAPSULE_STATE" "$RESOURCES/"
  fi
done
for BACKGROUND in "$ROOT"/Assets/ImmersiveVistaBackground*.jpg; do
  if [[ -f "$BACKGROUND" ]]; then
    cp "$BACKGROUND" "$RESOURCES/"
  fi
done

swiftc -Onone -target "$BUILD_ARCH-apple-macos13.1" -parse-as-library "$ROOT/Sources/KnowledgeBaseCore.swift" "$ROOT/Sources/DailyReminderWidget.swift" -o "$MACOS/DailyReminderWidget" -framework SwiftUI -framework AppKit -framework UserNotifications

chmod +x "$MACOS/DailyReminderWidget"
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$APP" >/dev/null
else
  codesign --force --deep --sign - "$APP" >/dev/null
fi

mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/应用程序"
cat > "$DMG_ROOT/首次打开修复.command" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="灵栖胶囊Capsule.app"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -d "/Applications/$APP_NAME" ]]; then
  TARGET="/Applications/$APP_NAME"
elif [[ -d "$SCRIPT_DIR/$APP_NAME" ]]; then
  TARGET="$SCRIPT_DIR/$APP_NAME"
else
  echo "未找到 $APP_NAME。请先将应用拖入“应用程序”文件夹，或把此脚本与 App 放在同一目录。"
  read -r -p "按回车退出..."
  exit 1
fi

echo "正在为本机移除下载隔离标记：$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
echo "完成。正在打开应用..."
open "$TARGET"
SCRIPT
chmod +x "$DMG_ROOT/首次打开修复.command"
cat > "$DMG_ROOT/首次打开说明.txt" <<'TEXT'
如果在新 Mac 上看到“Apple 无法验证是否包含恶意软件”的提示：

1. 先将“灵栖胶囊Capsule.app”拖到“应用程序”。
2. 双击运行“首次打开修复.command”。
3. 脚本只会移除本机下载隔离标记，然后打开应用。

正式对外分发版本应使用 Apple Developer ID 签名并完成公证。
TEXT

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$OUT_ROOT/$APP_NAME.dmg" >/dev/null

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$OUT_ROOT/$APP_NAME.dmg" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$OUT_ROOT/$APP_NAME.dmg"
fi

echo "$APP"
echo "$OUT_ROOT/$APP_NAME.dmg"
