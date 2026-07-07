# Releasing shed-desktop

shed-desktop follows the release-workflows convention. `scripts/release/update-version.sh`
bumps two manifests in lockstep — the top-level `VERSION` (the macOS marketing version) and
the Rust workspace's `core/Cargo.toml` (regenerating `core/Cargo.lock`) — so one tag means
one version across the DMG, the Sparkle appcast, and the Linux `.deb`.

## Auto-update (Sparkle)

The app embeds Sparkle 2 and checks for updates via the **menu → Check for Updates…**.
Update authenticity rests on Sparkle's **EdDSA signature** (`SUPublicEDKey` in
`Resources/Info.plist.template`), not Apple notarization — so ad-hoc builds auto-update
safely. The feed is the appcast on GitHub Pages
(`https://charliek.github.io/shed-desktop/appcast.xml`, served from `docs/appcast.xml`).

shed-desktop uses its own **dedicated** EdDSA signing key (public key in
`Info.plist.template`; private key in the `SPARKLE_ED_PRIVATE_KEY` secret). To rotate, run
`.build/artifacts/sparkle/Sparkle/bin/generate_keys`, paste the new public key into
`Info.plist.template`, and update the secret.

## Build artifacts locally

```bash
make bundle   # build/ShedDesktop.app (ad-hoc signed, Sparkle.framework embedded)
make dmg      # build/ShedDesktop-<version>.dmg (drag-install + first-launch note)
```

## Cut a release

1. Bump the version: `scripts/release/update-version.sh X.Y.Z` (updates `VERSION` +
   `core/Cargo.toml` + `core/Cargo.lock`).
2. Commit the changelog + version bump.
3. Tag `vX.Y.Z` and push with `--follow-tags`.

The `release` workflow (`.github/workflows/release.yml`) cuts the GitHub Release up front (a
`create-release` job that first checks tag == `VERSION` == `core/Cargo.toml`), then two build
jobs upload to it in parallel:

- **macOS** builds + bundles, packages the DMG, EdDSA-signs it, and the bot pushes the
  Sparkle appcast to `main` (below).
- **Linux** builds `shed-desktop_<ver>_<arch>.deb` on native `amd64` + `arm64` runners and,
  on a stable tag, dispatches `charliek/apt-charliek` to pull it into the apt index (a
  prerelease `vX.Y.Z-suffix` tag skips the dispatch — the `.deb` still uploads to the
  Release). End users then `apt install shed-desktop` (see the apt-charliek README for the
  one-time repo setup).

> **Backend:** the shipped macOS app runs on the **Rust core by default**. `bundle.sh` builds the
> UniFFI `xcframework` and `SHED_DESKTOP_RUST_CORE` is left unset in the release build; the app
> treats anything but `=0` as on (`ShedBackend.swift`), so the DMG is the Rust-backed Swift app —
> the legacy Swift `URLSession` path is opt-out only. The macOS job's `make test` step exercises
> the Rust-FFI canary, so a broken core fails the release. Keep the release env free of
> `SHED_DESKTOP_RUST_CORE=0` (its only use is the `ci.yml` Swift-fallback *test* leg).

## Pipeline configuration (in place)

The release-workflows + Sparkle appcast pipeline is fully wired:

- **release-bot GitHub App** installed, with secrets `RELEASE_BOT_CLIENT_ID` /
  `RELEASE_BOT_APP_KEY` (CI mints a token to push the signed appcast to `main`, and a second
  token — scoped to `charliek/apt-charliek` — to dispatch the `.deb` publish). The App must
  be installed on **both** this repo and `apt-charliek`, and `shed-desktop` registered in
  `apt-charliek/packages.yaml`. `.github/workflows/sanity-check-app.yml` (Actions → Run
  workflow) verifies both reaches before a real release.
- **`SPARKLE_ED_PRIVATE_KEY`** secret (the dedicated key above).
- **`main-protection` ruleset**: requires `ci-success`, blocks force-push/deletion, with the
  release-bot App + repo admin as bypass actors (so the bot's appcast push and the
  maintainer's release commits land without waiting on their own `ci-success`).

On a tagged release, `release.yml` builds + attaches the DMG, then `sign_update`s it with the
secret, runs `scripts/update-appcast.py` to append the entry, and the bot pushes
`docs/appcast.xml` to `main` → `docs.yml` redeploys Pages → the appcast is live. First proven
by `v0.0.1`.

## Code signing + notarization

Developer ID signing + notarization are **wired and gated on the six Apple secrets below**
(all gated together as `CAN_NOTARIZE` — all-or-nothing, since a signed-but-un-notarized
DMG is still Gatekeeper-blocked). When all six are set, `release.yml`
imports the cert into a throwaway keychain, `bundle.sh` signs with
`SHED_DESKTOP_DEVELOPER_ID_IDENTITY` (hardened runtime + timestamp), and
`scripts/notarize.sh` submits the DMG to Apple and staples the ticket — so a downloaded
build opens with a normal double-click. When the secrets are absent the DMG ships
ad-hoc-signed and Gatekeeper blocks the first launch (the DMG's `FIRST-LAUNCH.txt` carries
the one-time `xattr -dr com.apple.quarantine /Applications/ShedDesktop.app`).

The release-note guidance is gated on the *real* artifact state (`xcrun stapler validate`),
not on cert presence — a Developer-ID-signed but un-notarized DMG is still blocked.

| Secret | Purpose | Required? |
|---|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | Developer ID Application cert+key, base64 of the `.p12` | required — part of the all-six `CAN_NOTARIZE` gate |
| `MACOS_CERTIFICATE_PASSWORD` | `.p12` export password | required — same |
| `SHED_DESKTOP_DEVELOPER_ID_IDENTITY` | codesign identity, e.g. `Developer ID Application: Name (TEAMID)` | required — same |
| `APPLE_ID` | Apple ID email for notarytool | required for notarization |
| `APPLE_TEAM_ID` | 10-char Apple team ID | required — same |
| `APPLE_APP_SPECIFIC_PASSWORD` | app-specific password (appleid.apple.com) | required — same |

The cert + Apple creds are also kept locally — git-ignored, synced across machines via
envsecrets (the `# envsecrets` marker in `.gitignore`) — at `.secrets/cert.p12` and
`.secrets/apple.env`. Source the latter for a local notarized build:
`set -a; . .secrets/apple.env; set +a`.
