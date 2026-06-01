# Releasing shed-desktop

shed-desktop follows the release-workflows convention. The single version manifest is the
top-level `VERSION` file (a pure-Swift package has no Cargo.toml/package.json to bump).

## Auto-update (Sparkle)

The app embeds Sparkle 2 and checks for updates via the **menu → Check for Updates…**.
Update authenticity rests on Sparkle's **EdDSA signature** (`SUPublicEDKey` in
`Resources/Info.plist.template`), not Apple notarization — so ad-hoc builds auto-update
safely. The feed is the appcast on GitHub Pages
(`https://charliek.github.io/shed-desktop/appcast.xml`, served from `docs/appcast.xml`).

The signing key is **shared with roost** (Sparkle recommends one key across apps), so the
private key is the existing `SPARKLE_ED_PRIVATE_KEY` secret. To use a dedicated key, run
`.build/artifacts/sparkle/Sparkle/bin/generate_keys`, paste its public key into
`Info.plist.template`, and set a new `SPARKLE_ED_PRIVATE_KEY` secret.

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

## Remaining wiring (one-time setup)

The full release-workflows + Sparkle appcast pipeline needs three repo-level inputs that
are set once:

1. **release-bot GitHub App** installed on the repo + secrets `RELEASE_BOT_CLIENT_ID` /
   `RELEASE_BOT_APP_KEY` (so CI can push the signed appcast to `main`).
2. **`SPARKLE_ED_PRIVATE_KEY`** secret (base64 private key; reuse roost's or a dedicated one).
3. **Branch ruleset on `main`** requiring `ci-success`, with the App + admin as bypass actors.

Once those exist, `release.yml` gains a `sparkle-appcast` job: it `sign_update`s the DMG with
the secret, runs `scripts/update-appcast.py` to append the entry, and the bot pushes
`docs/appcast.xml` to `main` → `docs.yml` redeploys Pages → the appcast is live.

## Notarization (deferred)

Developer ID signing + notarization stay env-gated (`SHED_DESKTOP_DEVELOPER_ID_IDENTITY` +
Apple secrets) and inert until a certificate lands. Until then builds are ad-hoc signed:
Gatekeeper blocks the first launch — see the DMG's `FIRST-LAUNCH.txt`
(`xattr -dr com.apple.quarantine /Applications/ShedDesktop.app`).
