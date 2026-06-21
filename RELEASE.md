# Releasing HomeSounds Sync

The default `./build.sh` produces an **ad-hoc signed** app, which is fine to run
locally but Gatekeeper will block it for other users (`spctl` shows `rejected`).
To distribute via GitHub Releases you need a Developer ID signature, the Hardened
Runtime, and notarization.

## Prerequisites

- Apple Developer Program membership.
- A **Developer ID Application** certificate in your login keychain.
- A notarytool keychain profile (one-time):

  ```bash
  xcrun notarytool store-credentials homesounds-notary \
    --apple-id "you@example.com" --team-id TEAMID --password <app-specific-password>
  ```

## Build, sign, notarize, staple

```bash
# 1) Build + Developer ID sign + Hardened Runtime
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh

# 2) Zip and submit for notarization
ditto -c -k --keepParent HomeSoundsSync.app HomeSoundsSync.zip
xcrun notarytool submit HomeSoundsSync.zip --keychain-profile homesounds-notary --wait

# 3) Staple the ticket so it validates offline
xcrun stapler staple HomeSoundsSync.app

# 4) Verify
spctl -a -vvv --type execute HomeSoundsSync.app   # should say: accepted, source=Notarized Developer ID
codesign -dvvv --verbose=4 HomeSoundsSync.app 2>&1 | grep -E "Authority|Runtime"
```

Then zip the stapled `.app` again for the GitHub Release asset.

## Distribution options (how should people install it?)

This app is unusual: it needs **OwnTone built locally** (`setup.sh`) and the
**System Audio Recording** permission, and an app downloaded from the internet is
quarantined by Gatekeeper unless it is **notarized**. So pick based on audience:

1. **Source + `setup.sh` (recommended, what works today).** Users `git clone` and
   run `./setup.sh`. Because the app is *built on the user's machine*, Gatekeeper
   does not quarantine it — no Apple Developer account or notarization needed. This
   is the simplest reliable path and is already documented in the README.

2. **Notarized `.dmg` (best for non-technical users).** Build a drag-to-install
   DMG with `./make-dmg.sh`. For others to open it without "unidentified
   developer"/"damaged" warnings, the app inside must be Developer-ID signed and
   notarized first (see above). OwnTone still has to be set up via `setup.sh`, so
   the DMG only covers the app half.

3. **Homebrew tap (nice for developers).** Publish a cask/formula in a personal
   tap so people can `brew install techjuicelab/tap/homesounds-sync`. The formula
   can run `setup.sh` for the OwnTone backend.

A plain **`.zip` of the `.app`** attached to a GitHub Release works too (same
notarization requirement as the DMG). `.dmg` is the most common for standalone
Mac apps, but for this project the source + `setup.sh` route is the smoothest
until you have a Developer ID to notarize with.

## Notes

- The app records **system audio** via a Core Audio process tap. This is gated by
  the macOS TCC prompt ("System Audio Recording"), driven by
  `NSAudioCaptureUsageDescription` in `Info.plist` — not by an entitlement.
- If you add entitlements, pass them with `ENTITLEMENTS=path/to.entitlements ./build.sh`.
- OwnTone is **not** part of the app bundle and is not signed/distributed here;
  end users build it with `setup.sh`.
- Distributing OwnTone binaries would bring its GPLv2 obligations; keep it a
  separate, user-built component.
