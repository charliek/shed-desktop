# Installation

shed-desktop is an Apple Silicon (arm64) macOS app. It requires macOS 14 or newer.

## Download the DMG

Grab the latest `ShedDesktop-<version>.dmg` from the
[releases page](https://github.com/charliek/shed-desktop/releases), open it, and drag
**ShedDesktop.app** to Applications.

Builds are **ad-hoc signed but not yet notarized**, so Gatekeeper blocks the first launch.
Once, after copying it in:

```bash
xattr -dr com.apple.quarantine /Applications/ShedDesktop.app
```

(Or double-click it, dismiss the warning, then System Settings → Privacy & Security →
"Open Anyway". The DMG's `FIRST-LAUNCH.txt` explains this too.) After that the app
**auto-updates** via Sparkle — menu → **Check for Updates…** — verified by an EdDSA
signature, no notarization required. See [RELEASING.md](https://github.com/charliek/shed-desktop/blob/main/RELEASING.md).

## Build from source

Prerequisites: Xcode 16+ (Swift 6 toolchain).

```bash
git clone https://github.com/charliek/shed-desktop
cd shed-desktop
make bundle          # builds build/ShedDesktop.app (ad-hoc signed)
open build/ShedDesktop.app
```

The bundle embeds the `shedctl` CLI at
`build/ShedDesktop.app/Contents/Resources/bin/shedctl`. `make dmg` packages a release
bundle into `build/ShedDesktop-<version>.dmg`.

## Signed builds

Release builds are ad-hoc signed until a Developer ID certificate is configured. To
produce a notarizable build locally, set the signing identity:

```bash
SHED_DESKTOP_DEVELOPER_ID_IDENTITY="Developer ID Application: …" ./scripts/bundle.sh release
```

## What it needs at runtime

- `~/.shed/config.yaml` — the shed-server host list (created by the `shed` CLI). The app
  reads this read-only and watches it for changes.
- A reachable `shed-server` on at least one configured host. Unreachable hosts are shown
  as a degraded state, never a hard failure.
