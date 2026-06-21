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

## Notes

- The app records **system audio** via a Core Audio process tap. This is gated by
  the macOS TCC prompt ("System Audio Recording"), driven by
  `NSAudioCaptureUsageDescription` in `Info.plist` — not by an entitlement.
- If you add entitlements, pass them with `ENTITLEMENTS=path/to.entitlements ./build.sh`.
- OwnTone is **not** part of the app bundle and is not signed/distributed here;
  end users build it with `setup.sh`.
- Distributing OwnTone binaries would bring its GPLv2 obligations; keep it a
  separate, user-built component.
