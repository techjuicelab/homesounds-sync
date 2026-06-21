#!/bin/bash
#
# 원본 PNG(정사각, 1024px 권장)를 macOS 앱 아이콘(AppIcon.icns)으로 변환.
# 사용:  ./makeicon.sh [원본.png]    (기본값: icon-source.png)
#
set -euo pipefail
cd "$(dirname "$0")"

SRC="${1:-icon-source.png}"
[ -f "$SRC" ] || { echo "❌ 원본 이미지가 없습니다: $SRC"; echo "   이미지를 이 경로에 저장한 뒤 다시 실행하세요."; exit 1; }

ISET="AppIcon.iconset"
rm -rf "$ISET"; mkdir "$ISET"

for s in 16 32 128 256 512; do
  sips -z "$s" "$s"           "$SRC" --out "$ISET/icon_${s}x${s}.png"    >/dev/null
  sips -z "$((s*2))" "$((s*2))" "$SRC" --out "$ISET/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns "$ISET" -o AppIcon.icns
rm -rf "$ISET"
echo "✅ AppIcon.icns 생성 완료 → ./build.sh 로 앱에 반영됩니다."
