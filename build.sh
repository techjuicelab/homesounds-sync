#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="HomeSoundsSync.app"
BIN="HomeSoundsSync"

echo "▶ Swift 빌드 (release)…"
swift build -c release

echo "▶ .app 번들 구성…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$BIN" "$APP/Contents/MacOS/$BIN"
cp "Info.plist" "$APP/Contents/Info.plist"
if [ -f "AppIcon.icns" ]; then
  cp "AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "▶ ad-hoc 코드 서명…"
codesign --force --sign - --timestamp=none "$APP"

echo "✅ 완료: $APP"
echo "   실행:  open ./$APP   (또는 더블클릭)"
