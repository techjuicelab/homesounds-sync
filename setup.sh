#!/bin/bash
#
# HomeSounds Sync — 다른 Mac에서도 동일 환경을 재현하는 설치 스크립트.
#
# 하는 일:
#   1) Homebrew 의존성 설치
#   2) libinotify-kqueue 빌드 (user prefix, macOS 26 빌드 우회)
#   3) OwnTone 29.2 다운로드 → HomePod transient 페어링 패치 → 빌드/설치
#   4) owntone.conf 설정 (pipe 48000/16, autostart, start_buffer_ms)
#   5) FIFO 생성
#   6) HomeSounds Sync 앱 빌드 + .app 패키징
#   7) OwnTone 로그인 자동시작(LaunchAgent) 등록
#
# 요구사항: Homebrew, Xcode Command Line Tools(swift, clang), macOS 14.4+ (권장 15.2+).
#
set -euo pipefail

OWNTONE_VER="29.2"
LIBINOTIFY_VER="20240724"
DATA="$HOME/owntone_data"
PREFIX="$DATA/usr"
WORK="$HOME/.homesounds-build"
APP_SRC="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.techjuice.owntone"

say() { printf "\n\033[1;36m▶ %s\033[0m\n" "$1"; }

command -v brew >/dev/null || { echo "Homebrew가 필요합니다: https://brew.sh"; exit 1; }
command -v swift >/dev/null || { echo "Xcode Command Line Tools가 필요합니다: xcode-select --install"; exit 1; }

BREW="$(brew --prefix)"
export MACOSX_DEPLOYMENT_TARGET="$(sw_vers -productVersion)"

say "1/7  Homebrew 의존성 설치 (ffmpeg 등 — 시간이 걸릴 수 있습니다)"
brew install pkg-config gettext libunistring confuse libplist libwebsockets \
  libevent libgcrypt json-c protobuf-c libsodium gnutls openssl@3 ffmpeg sqlite

mkdir -p "$PREFIX" "$WORK" "$DATA/media" "$DATA/var/log" "$DATA/var/cache/owntone"

say "2/7  libinotify-kqueue 빌드"
cd "$WORK"
curl -fsSL -o libinotify.tar.gz \
  "https://github.com/libinotify-kqueue/libinotify-kqueue/releases/download/${LIBINOTIFY_VER}/libinotify-${LIBINOTIFY_VER}.tar.gz"
rm -rf "libinotify-${LIBINOTIFY_VER}"; tar xf libinotify.tar.gz
cd "libinotify-${LIBINOTIFY_VER}"
./configure --prefix="$PREFIX" CFLAGS="-g -O2 -Wno-error" >/dev/null
make >/dev/null && make install >/dev/null

say "3/7  OwnTone ${OWNTONE_VER} 다운로드 + HomePod 페어링 패치 + 빌드"
cd "$WORK"
curl -fsSL -o "owntone.tar.xz" \
  "https://github.com/owntone/owntone-server/releases/download/${OWNTONE_VER}/owntone-${OWNTONE_VER}.tar.xz"
rm -rf "owntone-${OWNTONE_VER}"; tar xf owntone.tar.xz
cd "owntone-${OWNTONE_VER}"
# HomePod( "Everyone" 접근 )의 transient 페어링을 강제 — PIN 없이 자동 페어링.
perl -0pi -e 's/if \(session->statusflags & AIRPLAY_FLAG_ONE_TIME_PAIRING_REQUIRED\)/if (0 \&\& (session->statusflags \& AIRPLAY_FLAG_ONE_TIME_PAIRING_REQUIRED))/' \
  src/outputs/airplay.c
SQLITE="$(brew --prefix sqlite)"; OSSL="$(brew --prefix openssl@3)"; GTXT="$(brew --prefix gettext)"
export CFLAGS="-I$BREW/include -I$SQLITE/include -I$OSSL/include -I$GTXT/include -I$PREFIX/include"
export LDFLAGS="-L$BREW/lib -L$SQLITE/lib -L$OSSL/lib -L$GTXT/lib -L$PREFIX/lib"
export PKG_CONFIG_PATH="$BREW/lib/pkgconfig:$SQLITE/lib/pkgconfig:$OSSL/lib/pkgconfig:$PREFIX/lib/pkgconfig"
./configure --prefix="$PREFIX" --sysconfdir="$DATA/etc" --localstatedir="$DATA/var" >/dev/null
make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null

say "4/7  owntone.conf 설정"
CONF="$DATA/etc/owntone.conf"
sed -i '' "s/uid = \"owntone\"/uid = \"$USER\"/" "$CONF"
sed -i '' "s|directories = { \"/srv/music\" }|directories = { \"$DATA/media\" }|" "$CONF"
python3 - "$CONF" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("#\tpipe_autostart = true",
              "\tpipe_autostart = true\n\tpipe_sample_rate = 48000\n\tpipe_bits_per_sample = 16", 1)
s = s.replace("#\tstart_buffer_ms = 2250", "\tstart_buffer_ms = 500", 1)
open(p, "w").write(s)
print("  pipe/버퍼 설정 적용됨")
PY

say "5/7  FIFO 생성"
rm -f "$DATA/media/homesync.pipe"; mkfifo "$DATA/media/homesync.pipe"
echo "  $DATA/media/homesync.pipe"

say "6/7  HomeSounds Sync 앱 빌드 + 패키징"
cd "$APP_SRC"; ./build.sh

say "7/7  OwnTone 로그인 자동시작 등록 (LaunchAgent)"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${PREFIX}/sbin/owntone</string>
    <string>-f</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DYLD_FALLBACK_LIBRARY_PATH</key>
    <string>${PREFIX}/lib:${BREW}/lib</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${DATA}/var/log/owntone.out.log</string>
  <key>StandardErrorPath</key><string>${DATA}/var/log/owntone.err.log</string>
</dict>
</plist>
PLISTEOF
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
echo "  OwnTone가 로그인 시 자동 실행됩니다 (지금도 시작됨)."

cat <<DONE

✅ 설치 완료.

다음 한 번만 해주세요:
  1) 브라우저로 http://localhost:3689 → 우측 스피커 아이콘 → 본인 HomePod 선택
     (페어링은 자동. HomePod의 '스피커 및 TV 액세스'가 "모든 사람/같은 네트워크"여야 함)
  2) HomeSounds Sync.app 실행 → '출력 스피커'에서 로컬 스피커 선택 → 켜기
     (처음 켤 때 '시스템 오디오 녹음' 권한 허용)
  3) Apple Music 출력 = Computer (HomePod 아님!) 로 두고 재생
  4) 앱의 '지연'을 조절해 두 스피커 싱크 맞추기 (보통 1.5~2초 부근)

제거: launchctl bootout gui/\$(id -u)/${LABEL}; rm -f "$PLIST"; rm -rf "$DATA"
DONE
