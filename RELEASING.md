# Releasing shed-desktop

shed-desktop follows the release-workflows convention. The single version manifest is the
top-level `VERSION` file (a pure-Swift package has no Cargo.toml/package.json to bump).

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

1. Bump the version: `scripts/release/update-version.sh X.Y.Z`
2. Commit the changelog + version bump.
3. Tag `vX.Y.Z` and push with `--follow-tags`.

The `release` workflow (`.github/workflows/release.yml`) verifies the tag matches `VERSION`,
builds + bundles, and attaches the artifact to a GitHub release.

## Pipeline configuration (in place)

The release-workflows + Sparkle appcast pipeline is fully wired:

- **release-bot GitHub App** installed, with secrets `RELEASE_BOT_CLIENT_ID` /
  `RELEASE_BOT_APP_KEY` (CI mints a token to push the signed appcast to `main`).
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
