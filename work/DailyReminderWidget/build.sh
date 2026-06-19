#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT_ROOT="$ROOT/../../outputs"
APP_NAME="灵栖胶囊Capsule"
BUNDLE_ID="local.codex.lingqi-capsule"
APP_VERSION="1.2.6"
APP_BUILD="12"
APP="$OUT_ROOT/$APP_NAME.app"
DMG_ROOT="$ROOT/dmgroot"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
DEFAULT_ICON="$ROOT/Assets/AppIcon.png"
NOTIFICATION_ICON="$ROOT/Assets/NotificationIcon.png"

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
if [[ -f "$DEFAULT_ICON" ]]; then
  cp "$DEFAULT_ICON" "$RESOURCES/AppIcon.png"
fi
if [[ -f "$ROOT/Assets/InspirationPlantCapsule.png" ]]; then
  cp "$ROOT/Assets/InspirationPlantCapsule.png" "$RESOURCES/InspirationPlantCapsule.png"
fi
for BACKGROUND in "$ROOT"/Assets/ImmersiveVistaBackground*.jpg; do
  if [[ -f "$BACKGROUND" ]]; then
    cp "$BACKGROUND" "$RESOURCES/"
  fi
done

for ARCH in x86_64 arm64; do
  swiftc \
    -O \
    -target "$ARCH-apple-macos13.1" \
    -parse-as-library \
    "$ROOT/Sources/DailyReminderWidget.swift" \
    -o "$MACOS/DailyReminderWidget-$ARCH" \
    -framework SwiftUI \
    -framework AppKit \
    -framework UserNotifications
done

lipo -create \
  "$MACOS/DailyReminderWidget-x86_64" \
  "$MACOS/DailyReminderWidget-arm64" \
  -output "$MACOS/DailyReminderWidget"

rm "$MACOS/DailyReminderWidget-x86_64" "$MACOS/DailyReminderWidget-arm64"

chmod +x "$MACOS/DailyReminderWidget"
codesign --force --deep --sign - "$APP" >/dev/null

mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/应用程序"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$OUT_ROOT/$APP_NAME.dmg" >/dev/null

echo "$APP"
echo "$OUT_ROOT/$APP_NAME.dmg"
