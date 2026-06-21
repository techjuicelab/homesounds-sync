# Security Policy

## Reporting a vulnerability

Please open a GitHub issue, or for sensitive reports email the maintainer
(TechJuicelab). Include steps to reproduce and the affected version/commit.

## Security model & hardening

HomeSounds Sync captures Apple Music's audio locally and drives OwnTone (a
separate process) to send it to AirPlay speakers. Notable points:

- **OwnTone is bound to loopback.** `setup.sh` sets `bind_address = "127.0.0.1"`
  and `trusted_networks = { "localhost" }`, so OwnTone's web UI/API on port 3689
  is reachable only from this Mac. If you customize `owntone.conf`, keep it
  loopback-only unless you understand the exposure.
- **HomePod transient pairing.** `setup.sh` patches OwnTone to use transient
  pairing (no PIN). Access is then governed by the HomePod's "Speakers & TV
  Access" setting. Use **"Same Network"** (recommended) on a trusted network;
  avoid **"Everyone"**. See the README "HomePod Pairing Patch" section.
- **System audio recording.** The app uses a Core Audio process tap, gated by the
  macOS TCC consent prompt ("System Audio Recording"). It records only Apple
  Music's process audio and never writes it to disk; audio stays in memory and is
  sent to the FIFO/local outputs in real time.
- **Supply chain.** `setup.sh` pins OwnTone/libinotify versions and verifies their
  SHA-256 before building, and aborts if the HomePod pairing patch fails to apply.
- **No telemetry / network calls** other than the localhost OwnTone API and the
  AirPlay traffic OwnTone itself generates.

## Distribution

Released builds should be signed with a Developer ID, use the Hardened Runtime,
and be notarized + stapled (see `RELEASE.md`). Ad-hoc builds from `build.sh` are
for local use only.
