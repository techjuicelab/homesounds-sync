# HomeSounds Sync

Apple Music을 **로컬 유선 스피커(EDIFIER M60 등)와 HomePod에 동시에, 싱크를 맞춰** 들려주는 무료 macOS 도구. 유료 앱 **Airfoil($35)** 의 대체품입니다.

핵심 문제: HomePod(AirPlay)이 로컬 스피커보다 약간 늦게 나와 **하울링/에코**처럼 들리는 것. 이걸 로컬 출력을 지연시켜 맞춥니다.

**여러 대 동시 지원** — HomePod 여러 대(멀티룸)와 로컬 스피커 여러 대를 동시에 켤 수 있고, **로컬 스피커는 각자 지연을 따로** 맞춥니다.

## 동작 구조

macOS 14.4+에서 **Apple Music이 AirPlay로 출력하는 동안에는 그 오디오를 캡처할 수 없습니다.** 그래서 Airfoil과 동일한 방식을 씁니다 — Music은 로컬로만 출력하고, **HomePod 송신은 우리가 직접** 합니다:

```
Apple Music ──(로컬 출력, Computer)──▶ [내 앱: Core Audio 프로세스 탭]
                                          │
                  ┌───────────────────────┼───────────────────────┐
                  ▼                        ▼                       ▼
          [지연 링버퍼 · 공유]        [지연 링버퍼 · 공유]        [PCM16 FIFO]
            │ 리더 A (지연 1.6s)        │ 리더 B (지연 2.1s)         │ (실시간)
            ▼                          ▼                          ▼
      로컬 스피커 #1              로컬 스피커 #2            [OwnTone] ──▶ HomePod ×N
      (EDIFIER M60)              (다른 유선/USB)            (AirPlay 2, 서로 자동 동기화)
```

- **HomeSounds Sync 앱(Swift)** — Music을 프로세스 탭으로 캡처 → (1) 로컬 스피커마다 **독립 지연**으로 재생, (2) 실시간 PCM16을 FIFO로.
- **OwnTone(무료 오픈소스)** — FIFO를 읽어 HomePod에 AirPlay 2로 송신. AirPlay 2가 **여러 HomePod을 서로 샘플 단위로 동기화**하므로, HomePod 그룹은 하나의 "기준 타임라인"이 됩니다. 각 로컬 스피커를 그 기준에 맞추면 전부 정렬됩니다.

### HomePod 페어링 패치 (중요)
최신 HomePod 펌웨어는 OwnTone의 기본 PIN 페어링을 거부합니다. 그래서 OwnTone 소스에 **transient 페어링을 강제하는 1줄 패치**를 적용합니다(HomePod "스피커 및 TV 액세스 = 모든 사람/같은 네트워크"이면 코드 없이 자동 페어링). `setup.sh`가 자동 적용합니다.

## 설치 (새 Mac 포함)

요구사항: Homebrew, Xcode Command Line Tools, macOS 14.4+(권장 15.2+).

```bash
./setup.sh
```
의존성 설치 → libinotify/OwnTone(패치 포함) 빌드 → 설정 → FIFO → 앱 빌드 → OwnTone 로그인 자동시작까지 한 번에 처리합니다. (ffmpeg 빌드로 처음엔 시간이 걸립니다.)

설치 후 **한 번만**: http://localhost:3689 (OwnTone) → 스피커 아이콘 → **본인 HomePod 선택**(자동 페어링). 이후엔 앱에서 켜고 끕니다.

> 아이콘을 직접 교체하려면 정사각 PNG를 `icon-source.png`로 두고 `./makeicon.sh && ./build.sh`.

## 일상 사용

1. **Apple Music 출력 = Computer** — **HomePod은 Music에서 선택하지 않음** (OwnTone가 HomePod 담당)
2. **HomeSounds Sync** 앱에서:
   - **AirPlay 스피커** 목록에서 보낼 HomePod 체크 (여러 대 가능)
   - **로컬 스피커** 목록에서 보낼 유선 스피커 체크 (여러 대 가능)
3. **켜기** → 재생 → 모두 동기화 🎵

목록은 **새 기기가 켜지면 자동으로 늘어납니다**(3초마다 갱신).

## 싱크 미세조정

**로컬 스피커마다** 행의 **지연** 슬라이더/숫자칸으로 맞춥니다(보통 1.5~2초 부근, 기기마다 다름). 한 번 맞추면 기기별로 저장됩니다.

| 들리는 것 | 조정 |
|---|---|
| **로컬이 먼저**, HomePod이 메아리로 뒤늦게 | 그 로컬 행 지연 **↑ 올리기** |
| **HomePod이 먼저**, 로컬이 뒤늦게 | 그 로컬 행 지연 **↓ 내리기** |
| 메아리 없이 한 소리 | ✅ 완료 |

AirPlay 스피커끼리는 AirPlay 2가 자동 동기화하므로 따로 맞출 필요가 없습니다.

## 구성 파일

| 파일 | 역할 |
|---|---|
| `Sources/.../ProcessTapCapture.swift` | Music 프로세스 탭 캡처 (macOS 14.4+ CATap) → 공유 링버퍼 + FIFO |
| `Sources/.../RingBuffer.swift` | 단일 생산자 · **다중 리더** 지연 링버퍼 (`DelayRingBuffer` + 출력별 `DelayReader`) |
| `Sources/.../OutputRenderer.swift` | 로컬 출력 1대 = AUHAL 1개 + 자기 `DelayReader`·지연·볼륨 |
| `Sources/.../FifoFeed.swift` | 캡처 PCM16을 OwnTone FIFO로 실시간 전송 (AirPlay 기준) |
| `Sources/.../OwnToneClient.swift` | OwnTone HTTP API (AirPlay 출력 목록 · 다중 선택 · 볼륨) |
| `Sources/.../SyncEngine.swift` | 캡처 → 링버퍼/FIFO → **N개 로컬 출력** 오케스트레이션 |
| `Sources/.../AppDelegate.swift` | 창 UI (AirPlay/로컬 **동적 목록** · 기기별 지연·볼륨 · 켜기) |
| `setup.sh` | 다른 Mac에서 전체 환경 재현 |
| `Tests/ringtest.swift` | 링버퍼 회귀 + 다중 리더 테스트 |

링버퍼 테스트 실행:
```bash
mkdir -p /tmp/rt && cp Tests/ringtest.swift /tmp/rt/main.swift && cp Sources/HomeSoundsSync/RingBuffer.swift /tmp/rt/
swiftc -O /tmp/rt/main.swift /tmp/rt/RingBuffer.swift -o /tmp/ringtest && /tmp/ringtest
```

OwnTone 데이터/바이너리: `~/owntone_data/` · FIFO: `~/owntone_data/media/homesync.pipe`

## 알려진 한계 / 참고
- **절대 지연 ~2초**: AirPlay 2 버퍼는 줄일 수 없습니다(모두 ~2초 뒤). 음악 감상엔 안 느껴지고, 기기 간 상대 싱크만 맞추면 됩니다. (Airfoil도 동일.)
- **로컬 스피커별 지연**: 기기마다 지연 특성이 달라 각자 맞춰야 합니다(앱이 기기별로 저장).
- **취약성**: OwnTone의 AirPlay 2는 리버스 엔지니어링이라 애플/HomePod 업데이트로 깨질 수 있습니다.
- **HomePod 접근 설정**: 홈 앱 → 홈 설정 → 스피커 및 TV 액세스 = "모든 사람" 또는 "같은 네트워크".
- 진단 로그가 필요하면 `HSS_DEBUG=1`로 실행하면 `/tmp/hss-debug.log`에 기록됩니다(기본은 꺼짐).

## 제거
```bash
launchctl bootout gui/$(id -u)/com.techjuice.owntone
rm -f ~/Library/LaunchAgents/com.techjuice.owntone.plist
rm -rf ~/owntone_data
```

## 라이선스
MIT (`LICENSE` 참고). OwnTone(GPLv2)은 별도 프로세스로 빌드/실행하며 이 저장소에 포함되지 않습니다.
