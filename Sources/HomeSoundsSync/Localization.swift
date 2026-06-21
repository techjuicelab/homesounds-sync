import Foundation

enum AppLanguage: String, CaseIterable {
    case ko
    case en

    init(defaultsValue: String?) {
        if let defaultsValue, let stored = AppLanguage(rawValue: defaultsValue) {
            self = stored
        } else {
            self = Locale.preferredLanguages.first?.hasPrefix("ko") == true ? .ko : .en
        }
    }

    var displayName: String {
        switch self {
        case .ko: return "한국어"
        case .en: return "English"
        }
    }

    var text: AppText { AppText(language: self) }
}

struct AppText {
    let language: AppLanguage

    var settingsButton: String {
        switch language {
        case .ko: return "설정"
        case .en: return "Settings"
        }
    }

    var turnOn: String {
        switch language {
        case .ko: return "켜기"
        case .en: return "Turn On"
        }
    }

    var turnOff: String {
        switch language {
        case .ko: return "끄기"
        case .en: return "Turn Off"
        }
    }

    var statusOn: String {
        switch language {
        case .ko: return "● 동기화 켜짐"
        case .en: return "● Sync On"
        }
    }

    var statusOff: String {
        switch language {
        case .ko: return "○ 동기화 꺼짐"
        case .en: return "○ Sync Off"
        }
    }

    var airPlaySection: String {
        switch language {
        case .ko: return "AirPlay 스피커 (HomePod·Apple TV) - 여러 대 동시"
        case .en: return "AirPlay Speakers (HomePod/Apple TV) - Multiple at once"
        }
    }

    var localSection: String {
        switch language {
        case .ko: return "로컬 스피커 (이 Mac) - 각자 지연 조절, 여러 대 동시"
        case .en: return "Local Speakers (This Mac) - Per-device delay, multiple at once"
        }
    }

    var airPlayEmpty: String {
        switch language {
        case .ko: return "OwnTone 미실행 또는 발견된 AirPlay 기기 없음"
        case .en: return "OwnTone is not running, or no AirPlay devices were found"
        }
    }

    var delayLabel: String {
        switch language {
        case .ko: return "지연"
        case .en: return "Delay"
        }
    }

    var secondsUnit: String {
        switch language {
        case .ko: return "초"
        case .en: return "sec"
        }
    }

    var volumeAccessibility: String {
        switch language {
        case .ko: return "볼륨"
        case .en: return "Volume"
        }
    }

    var alertOK: String {
        switch language {
        case .ko: return "확인"
        case .en: return "OK"
        }
    }

    var settingsTitle: String {
        switch language {
        case .ko: return "사용법 및 설정"
        case .en: return "Guide and Settings"
        }
    }

    var languageLabel: String {
        switch language {
        case .ko: return "언어"
        case .en: return "Language"
        }
    }

    var refreshDevices: String {
        switch language {
        case .ko: return "기기 새로고침"
        case .en: return "Refresh Devices"
        }
    }

    var refreshDone: String {
        switch language {
        case .ko: return "새로고침됨 ✓"
        case .en: return "Refreshed ✓"
        }
    }

    var musicTerminated: String {
        switch language {
        case .ko: return "Apple Music이 종료되어 동기화를 멈췄습니다."
        case .en: return "Apple Music quit, so sync has stopped."
        }
    }

    var startAfterTurnOn: String {
        switch language {
        case .ko: return "'켜기'를 누르면 선택한 스피커로 재생을 시작합니다."
        case .en: return "Press 'Turn On' to start playback through the selected speaker."
        }
    }

    var chooseSpeakerBeforeStart: String {
        switch language {
        case .ko:
            return "보낼 스피커를 한 개 이상 체크한 뒤 켜기를 누르세요.\n(AirPlay 또는 로컬 목록에서 선택)"
        case .en:
            return "Select at least one speaker, then press Turn On.\n(Choose from the AirPlay or Local list.)"
        }
    }

    var captureNotWorking: String {
        switch language {
        case .ko:
            return "오디오가 캡처되지 않고 있습니다.\n시스템 설정 → 개인정보 보호 및 보안 → 시스템 오디오 녹음에서 권한을 허용한 뒤, Apple Music을 재생하세요. 권한을 방금 허용했다면 끄기 후 다시 켜기를 눌러 주세요."
        case .en:
            return "Audio is not being captured.\nOpen System Settings → Privacy & Security → System Audio Recording, allow access, then play Apple Music. If you just allowed access, press Turn Off and Turn On again."
        }
    }

    func outputStartFailed(names: String) -> String {
        let deviceName: String
        switch language {
        case .ko:
            deviceName = names.isEmpty ? "(알 수 없는 장치)" : names
            return "이 스피커로 출력을 시작할 수 없어 해제했습니다: \(deviceName)\n다른 앱이 독점 사용 중이거나 포맷이 맞지 않을 수 있습니다."
        case .en:
            deviceName = names.isEmpty ? "(Unknown device)" : names
            return "Could not start output for this speaker, so it was unchecked: \(deviceName)\nAnother app may be using it exclusively, or the format may be incompatible."
        }
    }

    func startError(_ error: Error) -> String {
        if let captureError = error as? ProcessTapCapture.CaptureError {
            return captureErrorMessage(captureError)
        }
        switch language {
        case .ko: return "\(error)"
        case .en: return "Could not start audio sync.\n\(error)"
        }
    }

    private func captureErrorMessage(_ error: ProcessTapCapture.CaptureError) -> String {
        switch (language, error) {
        case (.ko, .musicNotRunning):
            return "Apple Music이 실행 중이 아닙니다. Music을 먼저 실행하세요."
        case (.en, .musicNotRunning):
            return "Apple Music is not running. Open Music first."
        case (.ko, .translateFailed(let status)):
            return "Music 오디오 객체를 찾지 못했습니다 (\(status))."
        case (.en, .translateFailed(let status)):
            return "Could not find the Music audio object (\(status))."
        case (.ko, .createTapFailed(let status)):
            return "오디오 탭 생성 실패 (\(status))."
        case (.en, .createTapFailed(let status)):
            return "Could not create the audio tap (\(status))."
        case (.ko, .formatFailed(let status)):
            return "탭 포맷 조회 실패 (\(status))."
        case (.en, .formatFailed(let status)):
            return "Could not read the tap format (\(status))."
        case (.ko, .aggregateFailed(let status)):
            return "집합 장치 생성 실패 (\(status))."
        case (.en, .aggregateFailed(let status)):
            return "Could not create the aggregate device (\(status))."
        case (.ko, .ioProcFailed(let status)):
            return "캡처 시작 실패 (\(status))."
        case (.en, .ioProcFailed(let status)):
            return "Could not start capture (\(status))."
        }
    }

    var helpText: String {
        switch language {
        case .ko:
            return """
            HomeSounds Sync 사용법 및 설정
            제작: TechJuicelab

            HomePod/AirPlay 스피커와 이 Mac에 연결된 로컬 스피커를 동시에 재생하면서
            기기 사이의 어긋남을 로컬 스피커별 지연값으로 맞춥니다.

            기본 설정
            1. Apple Music 출력은 'Computer'로 두세요.
               HomePod은 Music에서 직접 선택하지 마세요. 이 앱이 AirPlay 송신을 담당합니다.

            2. 홈 앱에서 HomePod 접근 권한을 확인하세요.
               홈 설정 → 스피커 및 TV 접근 → '같은 네트워크' 또는 '모든 사람'

            3. 앱에서 스피커를 선택하세요.
               - AirPlay 스피커: HomePod, Apple TV 등 AirPlay 출력
               - 로컬 스피커: 유선 스피커, USB DAC, 모니터 스피커 등 이 Mac의 출력 장치
               특정 브랜드 전용이 아닙니다. 로컬 목록에 보이는 장치라면 같은 방식으로 맞출 수 있습니다.

            4. '켜기'를 누르고 Apple Music을 재생하세요.

            잘 사용하는 방법
            - 처음에는 AirPlay 스피커 1대와 로컬 스피커 1대만 켜고 맞추세요.
            - 보컬, 박수, 드럼처럼 박자가 또렷한 곡으로 맞추면 쉽습니다.
            - 로컬이 먼저 들리고 HomePod이 메아리처럼 늦으면 그 로컬 행의 '지연'을 올리세요.
            - HomePod이 먼저 들리면 그 로컬 행의 '지연'을 내리세요.
            - 메아리 없이 하나의 소리로 들리면 저장된 값으로 다음 실행 때 자동 적용됩니다.
            - 로컬 스피커를 여러 대 쓰는 경우 하나씩 추가하면서 각 행을 따로 맞추세요.
            - 창을 아래로 늘리면 AirPlay/로컬 목록 영역이 함께 커져 더 많은 기기가 보입니다.

            볼륨
            각 행의 슬라이더로 스피커별 볼륨을 조절합니다.

            참고
            - AirPlay 스피커끼리는 AirPlay 2가 자동 동기화하므로 따로 맞출 필요가 없습니다.
            - 전체 지연은 약 2초입니다(AirPlay 2 버퍼). 음악 감상엔 크게 느껴지지 않고,
              기기 사이의 상대 싱크만 맞추면 됩니다.
            - 한 번 맞춘 지연, 볼륨, 선택은 기기별로 저장되어 다음에 자동 적용됩니다.
            """
        case .en:
            return """
            HomeSounds Sync Guide and Settings
            By TechJuicelab

            HomeSounds Sync plays Apple Music through HomePod/AirPlay speakers and
            local speakers connected to this Mac, then aligns them with per-device
            local delay.

            Basic Setup
            1. Set Apple Music output to 'Computer'.
               Do not select HomePod directly in Music. This app handles AirPlay output.

            2. Check HomePod access in the Home app.
               Home Settings → Speakers & TV Access → 'Same Network' or 'Everyone'

            3. Select speakers in the app.
               - AirPlay speakers: HomePod, Apple TV, or other AirPlay outputs
               - Local speakers: wired speakers, USB DACs, monitor speakers, or other Mac output devices
               This is not tied to a specific brand. If it appears as a macOS output device,
               you can align it the same way.

            4. Press 'Turn On' and play Apple Music.

            Tips
            - Start with one AirPlay speaker and one local speaker.
            - Use music with clear timing, such as vocals, claps, or drums.
            - If the local speaker plays first and HomePod echoes behind it, increase Delay on that local row.
            - If HomePod plays first, decrease Delay on that local row.
            - When the sound becomes one clean image, the saved value is reused next time.
            - Add multiple local speakers one by one and tune each row separately.
            - Make the window taller to reveal more AirPlay and local devices.

            Volume
            Use each row's slider to control that speaker's volume.

            Notes
            - AirPlay speakers are synchronized by AirPlay 2, so they do not need per-speaker delay.
            - Total playback latency is about 2 seconds because of the AirPlay 2 buffer.
              For music listening, only the relative sync between devices matters.
            - Per-device delay, volume, and selection are saved and restored automatically.
            """
        }
    }
}
