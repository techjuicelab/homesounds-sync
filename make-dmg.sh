#!/bin/bash
#
# HomeSoundsSync.app → 배포용 DMG 생성 (드래그 설치).
# 사용:  ./build.sh && ./make-dmg.sh
#
# 참고: 다른 사람에게 배포하려면 앱이 Developer ID 서명 + notarization 돼 있어야
#       Gatekeeper가 막지 않습니다(RELEASE.md). ad-hoc 빌드의 DMG는 본인 테스트용입니다.
#
set -euo pipefail
cd "$(dirname "$0")"

APP="HomeSoundsSync.app"
VOL="HomeSounds Sync"
DMG="HomeSoundsSync.dmg"

[ -d "$APP" ] || { echo "❌ $APP 이 없습니다. 먼저 ./build.sh 를 실행하세요."; exit 1; }

rm -f "$DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"        # 드래그-투-Applications
cp README.md "$STAGE/README.md" 2>/dev/null || true

hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
  echo "  ✓ DMG 서명됨 ($CODESIGN_IDENTITY)"
fi

echo "✅ $DMG 생성 완료"
echo "   ⚠️  배포 전 앱 notarization 필요 (RELEASE.md). OwnTone는 setup.sh로 별도 설치."
