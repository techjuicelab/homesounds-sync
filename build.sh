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

# 배포용 서명: CODESIGN_IDENTITY 가 있으면 Developer ID + Hardened Runtime 로 서명
# (notarization 가능). 없으면 로컬 개발용 ad-hoc 서명.
#   예) CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
SIGN_ID="${CODESIGN_IDENTITY:-}"
if [ -n "$SIGN_ID" ]; then
  echo "▶ Developer ID 서명 + Hardened Runtime…"
  codesign --force --deep --options runtime --timestamp \
    ${ENTITLEMENTS:+--entitlements "$ENTITLEMENTS"} \
    --sign "$SIGN_ID" "$APP"
  echo "✅ 완료(배포 서명): $APP"
  echo "   notarize:"
  echo "     ditto -c -k --keepParent \"$APP\" \"$BIN.zip\""
  echo "     xcrun notarytool submit \"$BIN.zip\" --keychain-profile <프로필> --wait"
  echo "     xcrun stapler staple \"$APP\""
else
  echo "▶ ad-hoc 코드 서명 (로컬 실행용 — 배포 아님)…"
  codesign --force --sign - --timestamp=none "$APP"
  echo "✅ 완료: $APP   (실행: open ./$APP)"
  echo "   배포(GitHub Releases)용은 RELEASE.md 참고 — Developer ID 서명 + notarization 필요."
fi
