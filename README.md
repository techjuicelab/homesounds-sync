# HomeSounds Sync

Languages: [English](#english) | [한국어](#korean)

---

## English

HomeSounds Sync is a free macOS tool that plays Apple Music through **HomePod/AirPlay speakers and local speakers connected to your Mac at the same time**, with per-device sync adjustment.

Created by **TechJuicelab**.

It was built for a simple home-listening problem: when a HomePod and a desk speaker play together, one side can arrive slightly late and sound like echo. HomeSounds Sync fixes that by delaying each local speaker until it lines up with the AirPlay timeline.

This started as a personal tool, but anyone with the same setup pain is welcome to use it. Please leave feedback, working device combinations, setup notes, or improvement ideas in issues.

**Multiple speakers are supported**: several HomePods/AirPlay speakers can play together, and several local speakers can each have their own delay.

### How It Works

On macOS 14.4+, Apple Music audio cannot be captured while Music itself is outputting directly to AirPlay. HomeSounds Sync keeps Music output on **Computer**, captures that local stream, then sends the HomePod/AirPlay side separately:

```text
Apple Music --(local output, Computer)--> [HomeSounds Sync: Core Audio process tap]
                                             |
                    +------------------------+------------------------+
                    v                        v                        v
              [Shared delay buffer]    [Shared delay buffer]     [PCM16 FIFO]
                reader A, 1.6 s          reader B, 2.1 s          real time
                    v                        v                        v
              Local speaker #1         Local speaker #2          [OwnTone] --> HomePod x N
              wired/USB/DAC            other Mac output          AirPlay 2 syncs them
```

- **HomeSounds Sync app (Swift)** captures Music with a process tap, plays delayed copies to local speakers, and sends real-time PCM16 to a FIFO.
- **OwnTone (free, open source)** reads the FIFO and sends it to HomePod/AirPlay speakers. AirPlay 2 keeps the AirPlay speakers synchronized with each other, so local speakers only need to align to that reference.

### HomePod Pairing Patch

Recent HomePod firmware can reject OwnTone's default PIN pairing flow. `setup.sh` applies a small patch that forces transient pairing, so OwnTone can connect without entering a PIN.

**Security trade-off (please read):** transient pairing relies on the HomePod's "Speakers & TV Access" setting in the Home app instead of a PIN. Recommended setting is **"Same Network"** (anyone already on your home Wi-Fi can stream — same trust level as normal AirPlay). **"Everyone" allows any nearby device to stream and is not recommended.** Use this only on a network you trust, and prefer "Same Network". OwnTone's web/API is bound to loopback (`127.0.0.1`) by `setup.sh`, so it is not reachable from other machines.

### Install

Requirements: Homebrew, Xcode Command Line Tools, macOS 15.0+ (Sequoia). The Core Audio process tap API is macOS 14.4+, but the app itself targets 15.0 (it uses the Swift `Synchronization` framework).

```bash
./setup.sh
```

The script installs dependencies, builds patched OwnTone, writes configuration, creates the FIFO, builds the app, and registers OwnTone as a login LaunchAgent. The first run can take a while because ffmpeg is built.

After installation, do this once: open [http://localhost:3689](http://localhost:3689), click the speaker icon, and select your HomePod. After that, use HomeSounds Sync to turn speakers on and off.

To replace the app icon, put a square PNG at `icon-source.png`, then run:

```bash
./makeicon.sh && ./build.sh
```

### Daily Use

1. Set **Apple Music output = Computer**. Do not select HomePod directly in Music.
2. In **HomeSounds Sync**:
   - Select HomePod/Apple TV devices in **AirPlay Speakers**.
   - Select wired, USB, DAC, monitor, or interface devices in **Local Speakers**.
3. Press **Turn On**, then play Apple Music.

Local speakers are not brand-specific. If a device appears as a macOS output device, it can be tuned the same way.

Device lists refresh automatically every 3 seconds. Make the app window taller to reveal more AirPlay and local devices.

### Tips

Start with **one AirPlay speaker and one local speaker**, tune them, then add more local speakers one by one.

Use music with clear timing, such as vocals, claps, or drums.

Per-device delay, volume, selection, and language are saved automatically.

Use the **Settings** button in the app to switch between English and Korean. The main window, settings guide, row labels, and alerts update immediately.

### Sync Tuning

Adjust each local speaker's **Delay** slider or number field. Most setups land around 1.5-2 seconds, but every device is different.

| What you hear | Adjustment |
| --- | --- |
| Local speaker plays first; HomePod echoes later | Increase Delay on that local row |
| HomePod plays first; local speaker trails | Decrease Delay on that local row |
| One clean sound image | Done |

AirPlay speakers are synchronized by AirPlay 2, so they do not need per-speaker delay.

### Files

| File | Role |
| --- | --- |
| `Sources/.../ProcessTapCapture.swift` | Captures Music with a macOS 14.4+ Core Audio process tap |
| `Sources/.../RingBuffer.swift` | Shared delay buffer with multiple independent readers |
| `Sources/.../OutputRenderer.swift` | One AUHAL local output per local speaker |
| `Sources/.../FifoFeed.swift` | Streams captured PCM16 to OwnTone through a FIFO |
| `Sources/.../OwnToneClient.swift` | OwnTone HTTP API client for AirPlay outputs and volume |
| `Sources/.../SyncEngine.swift` | Orchestrates capture, FIFO, and local outputs |
| `Sources/.../AppDelegate.swift` | AppKit window UI and controls |
| `Sources/.../Localization.swift` | English/Korean UI strings and help text |
| `setup.sh` | Recreates the full environment on another Mac |
| `Tests/ringtest.swift` | Delay buffer regression test |

Run the ring buffer test:

```bash
mkdir -p /tmp/rt && cp Tests/ringtest.swift /tmp/rt/main.swift && cp Sources/HomeSoundsSync/RingBuffer.swift /tmp/rt/
swiftc -O /tmp/rt/main.swift /tmp/rt/RingBuffer.swift -o /tmp/ringtest && /tmp/ringtest
```

- OwnTone data/binary: `~/owntone_data/`
- FIFO: `~/owntone_data/media/homesync.pipe`

### Known Limits

- **About 2 seconds of total latency**: the AirPlay 2 buffer cannot be removed. For music listening, relative sync between devices is what matters.
- **Each local speaker needs its own delay**: device latency differs, and the app saves each device's value.
- **AirPlay 2 compatibility can change**: OwnTone's AirPlay 2 support is reverse engineered, so Apple/HomePod updates can break it.
- **HomePod access**: Home app → Home Settings → Speakers & TV Access → "Everyone" or "Same Network".
- Diagnostics: run with `HSS_DEBUG=1` to write `/tmp/hss-debug.log`.

### Uninstall

```bash
launchctl bootout gui/$(id -u)/com.techjuice.owntone
rm -f ~/Library/LaunchAgents/com.techjuice.owntone.plist
rm -rf ~/owntone_data
```

### License

MIT. See `LICENSE`. OwnTone (GPLv2) is built and run as a separate process and is not included in this repository.

---

## Korean

HomeSounds Sync는 Apple Music을 **HomePod/AirPlay 스피커와 Mac에 연결된 로컬 스피커에서 동시에, 싱크를 맞춰** 들려주는 무료 macOS 도구입니다.

제작: **TechJuicelab**

집에서 HomePod과 책상 스피커를 같이 틀면 한쪽이 살짝 늦게 들려 **하울링/에코**처럼 느껴질 때가 있습니다. HomeSounds Sync는 이 어긋남을 로컬 출력 지연값으로 맞추기 위해 만들었습니다.

개인적인 불편에서 시작했지만, 같은 고민이 있는 분이라면 누구나 무료로 사용해 보셔도 좋습니다. 잘 맞는 조합, 어려웠던 설정, 개선 아이디어는 이슈나 후기로 남겨 주세요.

**여러 대 동시 지원**: HomePod/AirPlay 스피커 여러 대와 로컬 스피커 여러 대를 동시에 켤 수 있고, **로컬 스피커는 각자 지연을 따로** 맞춥니다.

### 동작 구조

macOS 14.4+에서는 Apple Music이 AirPlay로 직접 출력 중일 때 그 오디오를 캡처할 수 없습니다. 그래서 Music 출력은 **Computer**로 두고, HomePod/AirPlay 송신은 앱 쪽에서 별도로 맡습니다.

```text
Apple Music --(로컬 출력, Computer)--> [HomeSounds Sync: Core Audio 프로세스 탭]
                                             |
                    +------------------------+------------------------+
                    v                        v                        v
              [공유 지연 버퍼]          [공유 지연 버퍼]          [PCM16 FIFO]
                리더 A, 1.6초            리더 B, 2.1초             실시간
                    v                        v                        v
              로컬 스피커 #1           로컬 스피커 #2            [OwnTone] --> HomePod x N
              유선/USB/DAC             다른 Mac 출력 장치        AirPlay 2가 서로 동기화
```

- **HomeSounds Sync 앱(Swift)**은 Music을 프로세스 탭으로 캡처하고, 로컬 스피커마다 지연된 복사본을 재생하며, 실시간 PCM16을 FIFO로 보냅니다.
- **OwnTone(무료 오픈소스)**은 FIFO를 읽어 HomePod/AirPlay 스피커로 송신합니다. AirPlay 2가 AirPlay 스피커끼리는 서로 동기화하므로, 로컬 스피커만 그 기준에 맞추면 됩니다.

### HomePod 페어링 패치

최신 HomePod 펌웨어는 OwnTone의 기본 PIN 페어링을 거부할 수 있습니다. `setup.sh`는 transient 페어링을 강제하는 작은 패치를 적용해, PIN 입력 없이 OwnTone가 연결되게 합니다.

**보안 트레이드오프(꼭 읽으세요):** transient 페어링은 PIN 대신 홈 앱의 "스피커 및 TV 접근" 설정에 의존합니다. 권장값은 **"같은 네트워크"**입니다(집 Wi‑Fi에 이미 접속한 사람만 스트리밍 가능 — 일반 AirPlay와 같은 신뢰 수준). **"모든 사람"은 근처의 아무 기기나 스트리밍할 수 있어 권장하지 않습니다.** 신뢰하는 네트워크에서만 쓰고 가급적 "같은 네트워크"를 쓰세요. OwnTone 웹/API는 `setup.sh`가 루프백(`127.0.0.1`)에만 바인딩하므로 다른 기기에서 접근할 수 없습니다.

### 설치

요구사항: Homebrew, Xcode Command Line Tools, macOS 15.0+ (Sequoia). Core Audio 프로세스 탭 API는 14.4+이지만, 앱은 Swift `Synchronization` 프레임워크를 써서 15.0을 타깃으로 합니다.

```bash
./setup.sh
```

의존성 설치, 패치된 OwnTone 빌드, 설정 작성, FIFO 생성, 앱 빌드, OwnTone 로그인 자동시작 등록까지 한 번에 처리합니다. ffmpeg 빌드 때문에 처음에는 시간이 걸릴 수 있습니다.

설치 후 한 번만 [http://localhost:3689](http://localhost:3689)에 접속해 스피커 아이콘을 누르고 본인 HomePod을 선택하세요. 이후에는 HomeSounds Sync 앱에서 켜고 끄면 됩니다.

앱 아이콘을 교체하려면 정사각 PNG를 `icon-source.png`로 두고 실행하세요.

```bash
./makeicon.sh && ./build.sh
```

### 일상 사용

1. **Apple Music 출력 = Computer**로 둡니다. Music에서 HomePod을 직접 선택하지 마세요.
2. **HomeSounds Sync** 앱에서:
   - **AirPlay 스피커** 목록에서 HomePod/Apple TV를 선택합니다.
   - **로컬 스피커** 목록에서 유선, USB, DAC, 모니터, 오디오 인터페이스 장치를 선택합니다.
3. **켜기**를 누르고 Apple Music을 재생합니다.

로컬 스피커는 특정 브랜드 전용이 아닙니다. macOS 출력 장치로 보이는 기기라면 같은 방식으로 맞출 수 있습니다.

목록은 3초마다 자동 갱신됩니다. 앱 창을 세로로 늘리면 AirPlay/로컬 목록 영역도 함께 커져 더 많은 기기를 볼 수 있습니다.

### 잘 사용하는 방법

처음에는 **AirPlay 스피커 1대 + 로컬 스피커 1대**만 켜고 싱크를 맞춘 뒤, 로컬 스피커를 하나씩 추가하는 편이 쉽습니다.

보컬, 박수, 드럼처럼 타이밍이 또렷한 곡으로 맞추면 어긋남을 빨리 알아차릴 수 있습니다.

기기별 지연, 볼륨, 선택 상태, 언어 설정은 자동 저장됩니다.

앱의 **설정** 버튼에서 영어/한국어를 바꿀 수 있습니다. 메인창, 설정 안내, 행 라벨, 알림이 즉시 바뀝니다.

### 싱크 미세조정

각 로컬 스피커 행의 **지연** 슬라이더나 숫자칸으로 맞춥니다. 보통 1.5-2초 부근이지만 기기마다 다릅니다.

| 들리는 것 | 조정 |
| --- | --- |
| 로컬 스피커가 먼저 들리고 HomePod이 메아리처럼 뒤늦게 들림 | 그 로컬 행의 지연을 올리기 |
| HomePod이 먼저 들리고 로컬 스피커가 뒤늦게 들림 | 그 로컬 행의 지연을 내리기 |
| 메아리 없이 한 소리로 들림 | 완료 |

AirPlay 스피커끼리는 AirPlay 2가 자동 동기화하므로 따로 지연을 맞출 필요가 없습니다.

### 구성 파일

| 파일 | 역할 |
| --- | --- |
| `Sources/.../ProcessTapCapture.swift` | macOS 14.4+ Core Audio 프로세스 탭으로 Music 캡처 |
| `Sources/.../RingBuffer.swift` | 여러 독립 리더를 가진 공유 지연 버퍼 |
| `Sources/.../OutputRenderer.swift` | 로컬 스피커 1대당 AUHAL 로컬 출력 1개 |
| `Sources/.../FifoFeed.swift` | 캡처 PCM16을 FIFO로 OwnTone에 전송 |
| `Sources/.../OwnToneClient.swift` | AirPlay 출력과 볼륨을 다루는 OwnTone HTTP API 클라이언트 |
| `Sources/.../SyncEngine.swift` | 캡처, FIFO, 로컬 출력을 오케스트레이션 |
| `Sources/.../AppDelegate.swift` | AppKit 창 UI와 컨트롤 |
| `Sources/.../Localization.swift` | 영어/한국어 UI 문구와 도움말 |
| `setup.sh` | 다른 Mac에서 전체 환경 재현 |
| `Tests/ringtest.swift` | 지연 버퍼 회귀 테스트 |

링버퍼 테스트 실행:

```bash
mkdir -p /tmp/rt && cp Tests/ringtest.swift /tmp/rt/main.swift && cp Sources/HomeSoundsSync/RingBuffer.swift /tmp/rt/
swiftc -O /tmp/rt/main.swift /tmp/rt/RingBuffer.swift -o /tmp/ringtest && /tmp/ringtest
```

- OwnTone 데이터/바이너리: `~/owntone_data/`
- FIFO: `~/owntone_data/media/homesync.pipe`

### 알려진 한계

- **전체 지연 약 2초**: AirPlay 2 버퍼는 없앨 수 없습니다. 음악 감상에서는 기기 간 상대 싱크가 중요합니다.
- **로컬 스피커별 지연 필요**: 기기마다 지연 특성이 달라 각자 맞춰야 하며, 앱이 기기별 값을 저장합니다.
- **AirPlay 2 호환성 변경 가능성**: OwnTone의 AirPlay 2 지원은 리버스 엔지니어링 기반이라 Apple/HomePod 업데이트로 깨질 수 있습니다.
- **HomePod 접근 설정**: 홈 앱 → 홈 설정 → 스피커 및 TV 접근 → "모든 사람" 또는 "같은 네트워크".
- 진단 로그: `HSS_DEBUG=1`로 실행하면 `/tmp/hss-debug.log`에 기록됩니다.

### 제거

```bash
launchctl bootout gui/$(id -u)/com.techjuice.owntone
rm -f ~/Library/LaunchAgents/com.techjuice.owntone.plist
rm -rf ~/owntone_data
```

### 라이선스

MIT. `LICENSE`를 참고하세요. OwnTone(GPLv2)은 별도 프로세스로 빌드/실행하며 이 저장소에 포함되지 않습니다.
