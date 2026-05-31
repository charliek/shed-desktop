# Releasing shed-desktop

shed-desktop follows the release-workflows convention. The single version manifest is the
top-level `VERSION` file (a pure-Swift package has no Cargo.toml/package.json to bump).

## Cut a release

1. Bump the version: `scripts/release/update-version.sh X.Y.Z`
2. Commit the changelog + version bump.
3. Tag `vX.Y.Z` and push with `--follow-tags`.

The `release` workflow (`.github/workflows/release.yml`) then:

- verifies the tag matches `VERSION`,
- builds + bundles `ShedDesktop.app`, runs unit tests,
- zips the app and attaches it to a GitHub release.

## Not yet wired (M4)

- Developer ID signing + notarization (set `SHED_DESKTOP_DEVELOPER_ID_IDENTITY` and the
  Apple notarization secrets).
- DMG packaging.
- Sparkle appcast (EdDSA-signed, published to `docs/appcast.xml` on GitHub Pages).

Until then, builds are ad-hoc signed: Gatekeeper warns on first launch (right-click →
Open).
