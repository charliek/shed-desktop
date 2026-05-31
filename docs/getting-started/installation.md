# Installation

shed-desktop is an Apple Silicon (arm64) macOS app. It requires macOS 14 or newer.

## Build from source

Prerequisites: Xcode 16+ (Swift 6 toolchain).

```bash
git clone https://github.com/charliek/shed-desktop
cd shed-desktop
make bundle          # builds build/ShedDesktop.app (ad-hoc signed)
open build/ShedDesktop.app
```

The bundle embeds the `shedctl` CLI at
`build/ShedDesktop.app/Contents/Resources/bin/shedctl`.

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
