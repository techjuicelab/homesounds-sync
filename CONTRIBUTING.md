# Contributing

Thanks for your interest! HomeSounds Sync is a small, free tool — issues, working
device combinations, and PRs are all welcome.

## Requirements

- macOS 15.0+ (Sequoia)
- Xcode Command Line Tools (`swift`, `clang`)
- Homebrew (for the OwnTone side, via `setup.sh`)

## Build & run

```bash
./build.sh          # SwiftPM release build + .app bundle (ad-hoc signed)
open ./HomeSoundsSync.app
```

OwnTone (the AirPlay 2 sender) is set up separately:

```bash
./setup.sh          # builds patched OwnTone, configures it loopback-only, registers a LaunchAgent
```

## Tests

The delay ring buffer (single-producer / multi-reader) has a standalone test:

```bash
mkdir -p /tmp/rt && cp Tests/ringtest.swift /tmp/rt/main.swift && cp Sources/HomeSoundsSync/RingBuffer.swift /tmp/rt/
swiftc -O /tmp/rt/main.swift /tmp/rt/RingBuffer.swift -o /tmp/ringtest && /tmp/ringtest
```

CI runs `swift build`, this test, `git diff --check`, and `shellcheck` on the
shell scripts. Please make sure those pass.

## Style

- Match the surrounding code (naming, comment density, idioms).
- Real-time code (render/IOProc callbacks) must not allocate, lock, or do I/O.
- Keep user-facing strings in `Localization.swift` (English + Korean).
- No trailing whitespace.

## Scope

This project deliberately stays minimal: capture Apple Music, delay local
speakers, and drive OwnTone for HomePod. Large new dependencies or features
outside that core are unlikely to be merged — open an issue to discuss first.
